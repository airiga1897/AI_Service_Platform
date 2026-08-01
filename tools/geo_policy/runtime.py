#!/usr/bin/env python3
"""Privileged VPS3 GeoPolicy preflight, apply, rollback, and health reconcile."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import pathlib
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from typing import Any

from tools.geo_policy.geo_policy import (
    ContractError,
    atomic_write,
    load_yaml,
    reconcile_health,
    render_nft,
    parse_cidrs,
    validate_config,
)


SO_MARK = 36
TABLE_NAME = "ai_sp_geo_egress"


def run(command: list[str], *, check: bool = True, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        input=input_text,
        text=True,
        capture_output=True,
        encoding="utf-8",
    )


def marked_https_get(
    host: str,
    path: str,
    mark: int,
    timeout: float = 10.0,
    network_container: str = "",
) -> tuple[int, bytes, float]:
    if network_container:
        inspected = run(
            ["docker", "inspect", network_container, "--format", "{{.State.Pid}}"],
            check=False,
        )
        pid = inspected.stdout.strip()
        if inspected.returncode != 0 or not pid.isdigit() or int(pid) < 1:
            raise ContractError(
                f"probe network container is not running: {network_container}"
            )
        probe_script = (
            "import base64,json,sys;"
            "from tools.geo_policy.runtime import marked_https_get;"
            "status,body,latency=marked_https_get("
            "sys.argv[1],sys.argv[2],int(sys.argv[3]),float(sys.argv[4]));"
            "print(json.dumps({'status':status,'body':base64.b64encode(body).decode(),"
            "'latency_ms':latency}))"
        )
        completed = run(
            [
                "nsenter",
                "--target",
                pid,
                "--net",
                sys.executable,
                "-c",
                probe_script,
                host,
                path,
                str(mark),
                str(timeout),
            ],
            check=False,
        )
        if completed.returncode != 0:
            raise ContractError(
                f"marked HTTPS probe failed in network namespace of {network_container}"
            )
        try:
            payload = json.loads(completed.stdout)
            return (
                int(payload["status"]),
                base64.b64decode(payload["body"], validate=True),
                float(payload["latency_ms"]),
            )
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise ContractError("network namespace probe returned invalid JSON") from exc

    started = time.monotonic()
    addresses = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)
    if not addresses:
        raise ContractError(f"no IPv4 address resolved for {host}")
    raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        raw.settimeout(timeout)
        raw.setsockopt(socket.SOL_SOCKET, SO_MARK, mark)
        raw.connect(addresses[0][4])
        context = ssl.create_default_context()
        with context.wrap_socket(raw, server_hostname=host) as tls:
            request = (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {host}\r\n"
                "User-Agent: ai-service-platform-geo-policy/1\r\n"
                "Connection: close\r\n\r\n"
            )
            tls.sendall(request.encode("ascii"))
            response = bytearray()
            while len(response) < 65536:
                chunk = tls.recv(8192)
                if not chunk:
                    break
                response.extend(chunk)
    finally:
        raw.close()
    head, _, body = bytes(response).partition(b"\r\n\r\n")
    first = head.splitlines()[0].decode("ascii", errors="replace") if head else ""
    parts = first.split()
    if len(parts) < 2 or not parts[1].isdigit():
        raise ContractError(f"invalid HTTPS response from {host}")
    return int(parts[1]), body, (time.monotonic() - started) * 1000


def path_mark(policy: Any, path: str) -> int:
    for item in policy.paths:
        if item.alias == path:
            return item.route_mark
    raise ContractError("path must be a configured egress alias")


def probe_path(config: dict[str, Any], policy: Any, path: str) -> dict[str, Any]:
    health = config["geo_policy"]["health"]
    mark = path_mark(policy, path)
    network_container = str(health.get("probe_network_container") or "").strip()
    country_status, country_body, country_latency = marked_https_get(
        str(health["country_probe_host"]),
        str(health["country_probe_path"]),
        mark,
        network_container=network_container,
    )
    country = ""
    if country_status == 200:
        try:
            country = str(json.loads(country_body.decode("utf-8")).get("country") or "").upper()
        except (UnicodeDecodeError, json.JSONDecodeError):
            country = ""
    openai_status, openai_body, openai_latency = marked_https_get(
        str(health["openai_probe_host"]),
        str(health["openai_probe_path"]),
        mark,
        network_container=network_container,
    )
    unsupported = b"unsupported_country_region_territory" in openai_body
    openai_ok = openai_status in {200, 401} and not unsupported
    return {
        "path": path,
        "country": country,
        "country_status": country_status,
        "openai_status": openai_status,
        "openai_probe": "succeeded" if openai_ok else "failed",
        "unsupported_country": unsupported,
        "latency_ms": round(max(country_latency, openai_latency), 3),
    }


def safe_probe_path(config: dict[str, Any], policy: Any, path: str) -> dict[str, Any]:
    try:
        return probe_path(config, policy, path)
    except (ContractError, OSError, ssl.SSLError) as exc:
        return {
            "path": path,
            "country": "",
            "country_status": None,
            "openai_status": None,
            "openai_probe": "failed",
            "unsupported_country": False,
            "latency_ms": None,
            "error_type": type(exc).__name__,
        }


def render_transaction(nft_table: str) -> str:
    lines = nft_table.splitlines()
    if not lines or lines[0] != f"table inet {TABLE_NAME} {{":
        raise ContractError("unexpected nft table render")
    body = "\n".join(lines[1:-1])
    return f"flush table inet {TABLE_NAME}\ntable inet {TABLE_NAME} {{\n{body}\n}}\n"


def ensure_route_contract(
    policy: Any,
    mutate: bool,
    transport_receipt_path: str | None = None,
) -> list[dict[str, Any]]:
    transport_paths: dict[str, dict[str, Any]] = {}
    if transport_receipt_path:
        receipt_file = pathlib.Path(transport_receipt_path)
        if not receipt_file.is_file():
            raise ContractError("accepted platform_router transport receipt is absent")
        receipt = json.loads(receipt_file.read_text(encoding="utf-8"))
        if receipt.get("final_status") != "succeeded":
            raise ContractError("platform_router transport receipt is not accepted")
        transport_paths = {
            str(item.get("alias") or ""): item
            for item in receipt.get("egress_paths") or []
        }
    result = []
    for item in policy.paths:
        name = item.alias
        mark = item.route_mark
        if transport_paths:
            accepted = transport_paths.get(name)
            expected = {
                "gateway_ipv4": item.gateway_ipv4,
                "route_table": item.route_table,
                "route_mark": f"0x{mark:x}",
                "status": "ready",
            }
            if not accepted or any(
                accepted.get(key) != value for key, value in expected.items()
            ):
                raise ContractError(
                    f"{name} does not match the accepted platform_router transport receipt"
                )
        route_get = run(["ip", "-4", "route", "get", item.gateway_ipv4])
        if "unreachable" in route_get.stdout:
            raise ContractError(f"{name} gateway is unreachable: {item.gateway_ipv4}")
        table_routes = run(
            ["ip", "-4", "route", "show", "table", str(item.route_table)],
            check=False,
        ).stdout
        expected_default = f"default via {item.gateway_ipv4}"
        if expected_default not in table_routes:
            raise ContractError(
                f"{name} transport table {item.route_table} does not contain "
                f"the accepted default via {item.gateway_ipv4}"
            )
        existing = run(["ip", "-4", "rule", "show"], check=True).stdout
        signature = f"fwmark 0x{mark:x} lookup {item.route_table}"
        if signature not in existing:
            raise ContractError(
                f"{name} transport rule for mark 0x{mark:x} and table "
                f"{item.route_table} is absent"
            )
        marked_route = run(
            ["ip", "-4", "route", "get", "1.1.1.1", "mark", str(mark)],
            check=False,
        )
        if marked_route.returncode != 0 or f"via {item.gateway_ipv4}" not in marked_route.stdout:
            raise ContractError(f"{name} marked transport route is not active")
        result.append({
            "path": name,
            "alias": item.alias,
            "gateway_ipv4": item.gateway_ipv4,
            "route_table": item.route_table,
            "mark": f"0x{mark:x}",
        })
    return result


def nft_check(transaction: str) -> None:
    # nft -c still requires an existing table because the transaction flushes it.
    current = run(["nft", "list", "table", "inet", TABLE_NAME], check=False)
    if current.returncode == 0:
        run(["nft", "-c", "-f", "-"], input_text=transaction)
        return
    fresh = transaction.replace(f"flush table inet {TABLE_NAME}\n", "", 1)
    run(["nft", "-c", "-f", "-"], input_text=fresh)


def nft_apply(transaction: str) -> None:
    current = run(["nft", "list", "table", "inet", TABLE_NAME], check=False)
    candidate = transaction
    if current.returncode != 0:
        candidate = transaction.replace(f"flush table inet {TABLE_NAME}\n", "", 1)
    run(["nft", "-f", "-"], input_text=candidate)


def receipt_payload(policy: Any, dataset: str, active_path: str, routes: list[dict[str, Any]]) -> dict[str, Any]:
    active_alias = None if active_path == "blocked" else active_path
    return {
        "schema_version": 1,
        "policy": policy.name,
        "ingress_alias": policy.ingress_alias,
        "approval_id": policy.approval_id,
        "active_path": active_path,
        "active_egress_alias": active_alias,
        "switch_reason": "operator_apply",
        "dataset_sha256": hashlib.sha256(dataset.encode("ascii")).hexdigest(),
        "routes": routes,
        "applied_at": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }


def dataset_status(metadata: dict[str, Any], max_age_hours: int) -> dict[str, Any]:
    raw = str(metadata.get("fetched_at") or "")
    try:
        fetched_at = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ContractError("dataset fetched_at is invalid") from exc
    if fetched_at.tzinfo is None:
        raise ContractError("dataset fetched_at must include a timezone")
    age_seconds = (
        dt.datetime.now(dt.UTC) - fetched_at.astimezone(dt.UTC)
    ).total_seconds()
    if age_seconds < -300:
        raise ContractError("dataset fetched_at is unexpectedly in the future")
    age_hours = max(0.0, age_seconds / 3600)
    return {
        "status": "degraded" if age_hours > max_age_hours else "current",
        "age_hours": round(age_hours, 3),
        "max_age_hours": max_age_hours,
        "fetched_at": raw,
    }


def apply_policy(
    config_path: str,
    dataset_path: str,
    receipt_path: str,
    active_path: str,
    check_only: bool,
    probe_scope: str = "all",
    transport_receipt_path: str | None = None,
) -> dict[str, Any]:
    document = load_yaml(config_path)
    policy = validate_config(document)
    if policy.state != "accepted":
        raise ContractError("apply requires an accepted GeoPolicy")
    dataset = pathlib.Path(dataset_path).read_text(encoding="ascii")
    canonical_dataset = "".join(
        f"{network}\n" for network in parse_cidrs(dataset.splitlines(), "RU dataset")
    )
    if dataset != canonical_dataset:
        raise ContractError("RU dataset must be canonical ASCII with exactly one final LF")
    metadata_path = pathlib.Path(dataset_path).with_suffix(".json")
    if metadata_path.exists():
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        actual = hashlib.sha256(dataset.encode("ascii")).hexdigest()
        accepted = str(document["geo_policy"]["dataset"].get("accepted_sha256") or "")
        if (
            metadata.get("sha256") != actual
            or not accepted
            or metadata.get("root_accepted_sha256") != accepted
        ):
            raise ContractError("dataset checksum is not accepted by operator contract")
        freshness = dataset_status(metadata, policy.dataset_max_age_hours)
    else:
        raise ContractError("dataset metadata is required")
    aliases = tuple(item.alias for item in policy.paths)
    receipt_file = pathlib.Path(receipt_path)
    current_receipt: dict[str, Any] = {}
    if receipt_file.exists():
        current_receipt = json.loads(receipt_file.read_text(encoding="utf-8"))
        if current_receipt.get("policy") != policy.name:
            raise ContractError("current GeoPolicy receipt belongs to another policy")
    if active_path == "auto":
        current_path = str(current_receipt.get("active_path") or "")
        active_path = current_path if current_path in {*aliases, "blocked"} else aliases[0]
    if active_path not in {*aliases, "blocked"}:
        raise ContractError("active_path must be auto, blocked, or a configured egress alias")
    routes = ensure_route_contract(
        policy,
        mutate=False,
        transport_receipt_path=transport_receipt_path,
    )
    if probe_scope not in {"all", "active", "none"}:
        raise ContractError("probe_scope must be all, active, or none")
    probe_names: tuple[str, ...]
    if probe_scope == "all":
        probe_names = aliases
    elif probe_scope == "active" and active_path in aliases:
        probe_names = (active_path,)
    else:
        probe_names = ()
    probes = {
        name: safe_probe_path(document, policy, name)
        for name in probe_names
    }
    for name, probe in probes.items():
        expected_country = next(item.country_code for item in policy.paths if item.alias == name)
        if (
            probe["country"] != expected_country
            or probe["openai_probe"] != "succeeded"
        ):
            raise ContractError(
                f"{name} egress failed country/OpenAI acceptance: "
                f"country={probe['country'] or 'unknown'}, "
                f"expected_country={expected_country}, "
                f"openai={probe['openai_probe']}"
            )
    rendered = render_nft(policy, dataset.splitlines(), active_path)
    transaction = render_transaction(rendered)
    table_present = run(
        ["nft", "list", "table", "inet", TABLE_NAME],
        check=False,
    ).returncode == 0
    if table_present and not receipt_file.exists():
        raise ContractError("managed nftables table exists without a GeoPolicy receipt")
    nft_check(transaction)
    result = receipt_payload(policy, dataset, active_path, routes)
    result.update({
        "action": "check" if check_only else "apply",
        "check_mode_mutations": False,
        "mutation_performed": False,
        "nft_config_valid": True,
        "dataset": freshness,
        "egress_probes": probes,
        "runtime_state": {
            "nft_table_present": table_present,
            "receipt_present": receipt_file.exists(),
            "approval_matches": (
                not receipt_file.exists()
                or current_receipt.get("approval_id") == policy.approval_id
            ),
        },
    })
    if check_only:
        return result
    previous = receipt_file
    if previous.exists():
        atomic_write(str(previous) + ".previous", previous.read_text(encoding="utf-8"))
    nft_apply(transaction)
    result["mutation_performed"] = True
    atomic_write(receipt_path, json.dumps(result, sort_keys=True, indent=2) + "\n", 0o600)
    return result


def remove_policy(policy: Any, receipt_path: str) -> dict[str, Any]:
    run(["nft", "delete", "table", "inet", TABLE_NAME], check=False)
    return {
        "action": "remove",
        "check_mode_mutations": False,
        "mutation_performed": True,
        "receipt_present": pathlib.Path(receipt_path).exists(),
        "transport_contract_preserved": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check", "apply", "rollback", "probe", "reconcile", "remove"))
    parser.add_argument("--config", required=True)
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--active-path", default="auto")
    parser.add_argument("--probe-scope", choices=("all", "active", "none"), default="all")
    parser.add_argument("--transport-receipt")
    args = parser.parse_args()
    document = load_yaml(args.config)
    policy = validate_config(document)
    if args.action in {"check", "apply"}:
        result = apply_policy(
            args.config,
            args.dataset,
            args.receipt,
            args.active_path,
            args.action == "check",
            args.probe_scope,
            args.transport_receipt,
        )
    elif args.action == "probe":
        routes = ensure_route_contract(
            policy,
            mutate=False,
            transport_receipt_path=args.transport_receipt,
        )
        result = {
            "action": "probe",
            "routes": routes,
            "paths": {
                item.alias: safe_probe_path(document, policy, item.alias)
                for item in policy.paths
            },
        }
    elif args.action == "reconcile":
        receipt = json.loads(pathlib.Path(args.receipt).read_text(encoding="utf-8"))
        probes = {
            item.alias: safe_probe_path(document, policy, item.alias)
            for item in policy.paths
        }
        next_state = reconcile_health(
            policy,
            receipt,
            {
                item.alias: (
                    probes[item.alias]["openai_probe"] == "succeeded"
                    and probes[item.alias]["country"] == item.country_code
                )
                for item in policy.paths
            },
            dt.datetime.now(dt.UTC),
        )
        if next_state["active_path"] != receipt.get("active_path"):
            result = apply_policy(
                args.config,
                args.dataset,
                args.receipt,
                next_state["active_path"],
                False,
                "none",
                args.transport_receipt,
            )
            result.update({
                key: next_state[key]
                for key in (
                    "active_path",
                    "health_counters",
                    "last_switch_at",
                    "switch_reason",
                )
            })
            result["active_egress_alias"] = (
                None if next_state["active_path"] == "blocked"
                else next_state["active_path"]
            )
        else:
            receipt.update(next_state)
            metadata = json.loads(
                pathlib.Path(args.dataset).with_suffix(".json").read_text(encoding="utf-8")
            )
            receipt["dataset"] = dataset_status(metadata, policy.dataset_max_age_hours)
            atomic_write(args.receipt, json.dumps(receipt, sort_keys=True, indent=2) + "\n", 0o600)
            result = receipt
            result["mutation_performed"] = False
        result["probes"] = probes
        atomic_write(args.receipt, json.dumps(result, sort_keys=True, indent=2) + "\n", 0o600)
    elif args.action == "rollback":
        previous = pathlib.Path(args.receipt + ".previous")
        if not previous.exists():
            raise ContractError("rollback receipt is absent")
        rollback = json.loads(previous.read_text(encoding="utf-8"))
        result = apply_policy(
            args.config,
            args.dataset,
            args.receipt,
            rollback["active_path"],
            False,
            "active",
            args.transport_receipt,
        )
        result["action"] = "rollback"
        result["rollback_status"] = "succeeded"
    else:
        result = remove_policy(policy, args.receipt)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
