#!/usr/bin/env python3
"""Privileged VPS3 GeoPolicy preflight, apply, rollback, and health reconcile."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import ipaddress
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


def network_namespace_prefix(network_container: str) -> list[str]:
    inspected = run(
        ["docker", "inspect", network_container, "--format", "{{.State.Pid}}"],
        check=False,
    )
    pid = inspected.stdout.strip()
    if inspected.returncode != 0 or not pid.isdigit() or int(pid) < 1:
        raise ContractError(
            f"network namespace container is not running: {network_container}"
        )
    return ["nsenter", "--target", pid, "--net"]


def namespaced_command(command: list[str], network_container: str = "") -> list[str]:
    if not network_container:
        return command
    return [*network_namespace_prefix(network_container), *command]


def marked_https_get(
    host: str,
    path: str,
    mark: int,
    timeout: float = 10.0,
    network_container: str = "",
    source_ipv4: str = "",
) -> tuple[int, bytes, float]:
    if network_container:
        probe_script = (
            "import base64,json,sys;"
            "from tools.geo_policy.runtime import marked_https_get;"
            "status,body,latency=marked_https_get("
            "sys.argv[1],sys.argv[2],int(sys.argv[3]),float(sys.argv[4]),"
            "source_ipv4=sys.argv[5]);"
            "print(json.dumps({'status':status,'body':base64.b64encode(body).decode(),"
            "'latency_ms':latency}))"
        )
        completed = run(
            [
                *network_namespace_prefix(network_container),
                sys.executable,
                "-c",
                probe_script,
                host,
                path,
                str(mark),
                str(timeout),
                source_ipv4,
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
        if source_ipv4:
            raw.bind((source_ipv4, 0))
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


def marked_route_decision(
    host: str,
    mark: int,
    *,
    network_container: str = "",
    source_ipv4: str = "",
) -> str:
    addresses = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)
    if not addresses:
        raise ContractError(f"no IPv4 address resolved for {host}")
    destination = str(addresses[0][4][0])
    command = ["ip", "-4", "route", "get", destination, "mark", str(mark)]
    if source_ipv4:
        command.extend(["from", source_ipv4])
    if network_container:
        command = namespaced_command(command, network_container)
    completed = run(command, check=False)
    if completed.returncode != 0:
        raise ContractError("marked probe route lookup failed")
    decision = " ".join(completed.stdout.split())
    if not decision:
        raise ContractError("marked probe route lookup returned no route")
    return decision[:512]


def probe_path(config: dict[str, Any], policy: Any, path: str) -> dict[str, Any]:
    health = config["geo_policy"]["health"]
    mark = path_mark(policy, path)
    network_container = str(health.get("probe_network_container") or "").strip()
    source_ipv4 = str(health.get("probe_source_ipv4") or "").strip()
    route_decision = marked_route_decision(
        str(health["country_probe_host"]),
        mark,
        network_container=network_container,
        source_ipv4=source_ipv4,
    )
    country_status, country_body, country_latency = marked_https_get(
        str(health["country_probe_host"]),
        str(health["country_probe_path"]),
        mark,
        network_container=network_container,
        source_ipv4=source_ipv4,
    )
    country = ""
    external_ipv4 = ""
    if country_status == 200:
        try:
            country_payload = json.loads(country_body.decode("utf-8"))
            country = str(country_payload.get("country") or "").upper()
            observed_ip = ipaddress.ip_address(str(country_payload.get("ip") or ""))
            if observed_ip.version == 4 and observed_ip.is_global:
                external_ipv4 = str(observed_ip)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
            country = ""
    openai_status, openai_body, openai_latency = marked_https_get(
        str(health["openai_probe_host"]),
        str(health["openai_probe_path"]),
        mark,
        network_container=network_container,
        source_ipv4=source_ipv4,
    )
    unsupported = b"unsupported_country_region_territory" in openai_body
    openai_ok = openai_status in {200, 401} and not unsupported
    return {
        "path": path,
        "country": country,
        "external_ipv4": external_ipv4,
        "country_status": country_status,
        "openai_status": openai_status,
        "openai_probe": "succeeded" if openai_ok else "failed",
        "unsupported_country": unsupported,
        "latency_ms": round(max(country_latency, openai_latency), 3),
        "route_decision": route_decision,
    }


def safe_probe_path(config: dict[str, Any], policy: Any, path: str) -> dict[str, Any]:
    try:
        return probe_path(config, policy, path)
    except (ContractError, OSError, ssl.SSLError) as exc:
        return {
            "path": path,
            "country": "",
            "external_ipv4": "",
            "country_status": None,
            "openai_status": None,
            "openai_probe": "failed",
            "unsupported_country": False,
            "latency_ms": None,
            "route_decision": "unavailable",
            "error_type": type(exc).__name__,
        }


def application_https_get(
    container: str,
    host: str,
    path: str,
    timeout: float = 10.0,
) -> tuple[int, bytes, float]:
    probe_script = r'''
import base64
import json
import socket
import ssl
import sys
import time

host, path, timeout_text = sys.argv[1:4]
timeout = float(timeout_text)
started = time.monotonic()
addresses = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)
if not addresses:
    raise RuntimeError("no IPv4 address resolved")
raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    raw.settimeout(timeout)
    raw.connect(addresses[0][4])
    context = ssl.create_default_context()
    with context.wrap_socket(raw, server_hostname=host) as tls:
        tls.sendall((
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            "User-Agent: ai-service-platform-geo-policy-application/1\r\n"
            "Connection: close\r\n\r\n"
        ).encode("ascii"))
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
    raise RuntimeError("invalid HTTPS response")
print(json.dumps({
    "status": int(parts[1]),
    "body": base64.b64encode(body).decode("ascii"),
    "latency_ms": (time.monotonic() - started) * 1000,
}))
'''
    completed = run(
        [
            "docker",
            "exec",
            container,
            "python",
            "-c",
            probe_script,
            host,
            path,
            str(timeout),
        ],
        check=False,
    )
    if completed.returncode != 0:
        raise ContractError(f"application HTTPS probe failed in {container}")
    try:
        payload = json.loads(completed.stdout)
        return (
            int(payload["status"]),
            base64.b64decode(payload["body"], validate=True),
            float(payload["latency_ms"]),
        )
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise ContractError("application HTTPS probe returned invalid JSON") from exc


def probe_application_path(
    config: dict[str, Any],
    policy: Any,
    active_path: str,
) -> dict[str, Any]:
    health = config["geo_policy"]["health"]
    container = str(health["application_probe_container"])
    country_status, country_body, country_latency = application_https_get(
        container,
        str(health["country_probe_host"]),
        str(health["country_probe_path"]),
    )
    country = ""
    external_ipv4 = ""
    if country_status == 200:
        try:
            payload = json.loads(country_body.decode("utf-8"))
            country = str(payload.get("country") or "").upper()
            observed_ip = ipaddress.ip_address(str(payload.get("ip") or ""))
            if observed_ip.version == 4 and observed_ip.is_global:
                external_ipv4 = str(observed_ip)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
            pass
    openai_status, openai_body, openai_latency = application_https_get(
        container,
        str(health["openai_probe_host"]),
        str(health["openai_probe_path"]),
    )
    unsupported = b"unsupported_country_region_territory" in openai_body
    expected_country = next(
        item.country_code for item in policy.paths if item.alias == active_path
    )
    accepted = (
        country == expected_country
        and openai_status in {200, 401}
        and not unsupported
    )
    result = {
        "performed": True,
        "container": container,
        "path": active_path,
        "country": country,
        "expected_country": expected_country,
        "external_ipv4": external_ipv4,
        "country_status": country_status,
        "openai_status": openai_status,
        "openai_probe": "succeeded" if accepted else "failed",
        "unsupported_country": unsupported,
        "latency_ms": round(max(country_latency, openai_latency), 3),
    }
    if not accepted:
        raise ContractError(
            f"application egress failed after GeoPolicy apply: "
            f"container={container}, path={active_path}, "
            f"country={country or 'unknown'}, expected_country={expected_country}, "
            f"external_ipv4={external_ipv4 or 'unknown'}, "
            f"openai_status={openai_status}"
        )
    return result


def verify_source_gateway(container: str, gateway: str) -> str:
    completed = run(
        namespaced_command(["ip", "-4", "route", "show", "default"], container),
        check=False,
    )
    if completed.returncode != 0 or f"default via {gateway}" not in completed.stdout:
        raise ContractError(
            f"source gateway is not active: container={container}, gateway={gateway}"
        )
    return " ".join(completed.stdout.split())[:256]


def probe_vpn_path(
    config: dict[str, Any],
    policy: Any,
    active_path: str,
) -> dict[str, Any]:
    health = config["geo_policy"]["health"]
    container = str(health["vpn_probe_network_container"])
    source_ipv4 = str(health["vpn_probe_source_ipv4"])
    country_status, country_body, country_latency = marked_https_get(
        str(health["country_probe_host"]),
        str(health["country_probe_path"]),
        0,
        network_container=container,
        source_ipv4=source_ipv4,
    )
    country = ""
    external_ipv4 = ""
    if country_status == 200:
        try:
            payload = json.loads(country_body.decode("utf-8"))
            country = str(payload.get("country") or "").upper()
            observed_ip = ipaddress.ip_address(str(payload.get("ip") or ""))
            if observed_ip.version == 4 and observed_ip.is_global:
                external_ipv4 = str(observed_ip)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
            pass
    openai_status, openai_body, openai_latency = marked_https_get(
        str(health["openai_probe_host"]),
        str(health["openai_probe_path"]),
        0,
        network_container=container,
        source_ipv4=source_ipv4,
    )
    unsupported = b"unsupported_country_region_territory" in openai_body
    expected_country = next(
        item.country_code for item in policy.paths if item.alias == active_path
    )
    accepted = (
        country == expected_country
        and openai_status in {200, 401}
        and not unsupported
    )
    result = {
        "performed": True,
        "container": container,
        "source_ipv4": source_ipv4,
        "path": active_path,
        "country": country,
        "expected_country": expected_country,
        "external_ipv4": external_ipv4,
        "country_status": country_status,
        "openai_status": openai_status,
        "openai_probe": "succeeded" if accepted else "failed",
        "unsupported_country": unsupported,
        "latency_ms": round(max(country_latency, openai_latency), 3),
    }
    if not accepted:
        raise ContractError(
            f"VPN ingress egress failed after GeoPolicy apply: "
            f"container={container}, path={active_path}, "
            f"country={country or 'unknown'}, expected_country={expected_country}, "
            f"external_ipv4={external_ipv4 or 'unknown'}, "
            f"openai_status={openai_status}"
        )
    return result


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
    network_container: str = "",
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
                "route_scope": "platform_router_netns",
                "status": "ready",
            }
            if not accepted or any(
                accepted.get(key) != value for key, value in expected.items()
            ):
                raise ContractError(
                    f"{name} does not match the accepted platform_router transport receipt"
                )
        tunnel_next_hop = str(accepted.get("tunnel_next_hop") or "") if transport_paths else ""
        tunnel_iface = str(accepted.get("tunnel_iface") or "") if transport_paths else ""
        if not tunnel_next_hop or not tunnel_iface:
            raise ContractError(f"{name} accepted transport tunnel identity is incomplete")
        table_routes = run(
            namespaced_command(
                ["ip", "-4", "route", "show", "table", str(item.route_table)],
                network_container,
            ),
            check=False,
        ).stdout
        expected_default = f"default via {tunnel_next_hop} dev {tunnel_iface}"
        if expected_default not in " ".join(table_routes.split()):
            raise ContractError(
                f"{name} transport table {item.route_table} does not contain "
                f"the accepted tunnel default via {tunnel_next_hop} dev {tunnel_iface}"
            )
        existing = run(
            namespaced_command(["ip", "-4", "rule", "show"], network_container),
            check=True,
        ).stdout
        signature = f"fwmark 0x{mark:x} lookup {item.route_table}"
        if signature not in existing:
            raise ContractError(
                f"{name} transport rule for mark 0x{mark:x} and table "
                f"{item.route_table} is absent"
            )
        marked_route = run(
            namespaced_command(
                [
                    "ip", "-4", "route", "get", "1.1.1.1",
                    "mark", str(mark), "from", item.gateway_ipv4,
                ],
                network_container,
            ),
            check=False,
        )
        decision = " ".join(marked_route.stdout.split())
        if (
            marked_route.returncode != 0
            or f"via {tunnel_next_hop}" not in decision
            or f"dev {tunnel_iface}" not in decision
        ):
            raise ContractError(f"{name} marked transport route is not active")
        result.append({
            "path": name,
            "alias": item.alias,
            "gateway_ipv4": item.gateway_ipv4,
            "route_table": item.route_table,
            "mark": f"0x{mark:x}",
            "tunnel_iface": tunnel_iface,
            "tunnel_next_hop": tunnel_next_hop,
            "route_scope": "platform_router_netns",
        })
    return result


def ensure_source_gateway_contract(
    config: dict[str, Any],
    transport_receipt_path: str | None,
) -> list[dict[str, Any]]:
    if not transport_receipt_path:
        raise ContractError("accepted platform_router transport receipt is required")
    receipt_file = pathlib.Path(transport_receipt_path)
    if not receipt_file.is_file():
        raise ContractError("accepted platform_router transport receipt is absent")
    receipt = json.loads(receipt_file.read_text(encoding="utf-8"))
    if receipt.get("final_status") != "succeeded":
        raise ContractError("platform_router transport receipt is not accepted")
    health = config["geo_policy"]["health"]
    expected = {
        "site_runtime": {
            "source_cidr": "172.31.3.10/32",
            "router_ipv4": str(health["application_gateway_ipv4"]),
            "source_container": str(health["application_gateway_container"]),
        },
        "vpn_ingress": {
            "source_cidr": f"{health['vpn_probe_source_ipv4']}/32",
            "router_ipv4": str(health["vpn_gateway_ipv4"]),
            "source_container": str(health["vpn_probe_network_container"]),
        },
    }
    accepted = {
        str(item.get("source_class") or ""): item
        for item in receipt.get("source_gateways") or []
    }
    result = []
    for source_class, contract in expected.items():
        item = accepted.get(source_class)
        if not item or any(item.get(key) != value for key, value in contract.items()):
            raise ContractError(
                f"{source_class} does not match accepted platform_router source gateway"
            )
        route = verify_source_gateway(item["source_container"], item["router_ipv4"])
        result.append({
            "source_class": source_class,
            **contract,
            "route": route,
        })
    return result


def nft_snapshot(network_container: str = "") -> str:
    current = run(
        namespaced_command(
            ["nft", "list", "table", "inet", TABLE_NAME],
            network_container,
        ),
        check=False,
    )
    return current.stdout if current.returncode == 0 else ""


def nft_check(transaction: str, network_container: str = "") -> None:
    # nft -c still requires an existing table because the transaction flushes it.
    current = nft_snapshot(network_container)
    command = namespaced_command(["nft", "-c", "-f", "-"], network_container)
    if current:
        run(command, input_text=transaction)
        return
    fresh = transaction.replace(f"flush table inet {TABLE_NAME}\n", "", 1)
    run(command, input_text=fresh)


def nft_apply(transaction: str, network_container: str = "") -> None:
    current = nft_snapshot(network_container)
    candidate = transaction
    if not current:
        candidate = transaction.replace(f"flush table inet {TABLE_NAME}\n", "", 1)
    run(
        namespaced_command(["nft", "-f", "-"], network_container),
        input_text=candidate,
    )


def nft_delete(network_container: str = "") -> None:
    run(
        namespaced_command(
            ["nft", "delete", "table", "inet", TABLE_NAME],
            network_container,
        ),
        check=False,
    )


def nft_restore(snapshot: str, network_container: str = "") -> None:
    nft_delete(network_container)
    if snapshot:
        run(
            namespaced_command(["nft", "-f", "-"], network_container),
            input_text=snapshot,
        )


def apply_and_accept_router_policy(
    transaction: str,
    router_container: str,
    config: dict[str, Any],
    policy: Any,
    active_path: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    snapshot = nft_snapshot(router_container)
    try:
        nft_apply(transaction, router_container)
        if active_path == "blocked":
            skipped = {"performed": False, "reason": "fail_closed_active"}
            return skipped, dict(skipped)
        application = probe_application_path(config, policy, active_path)
        vpn_ingress = probe_vpn_path(config, policy, active_path)
        return application, vpn_ingress
    except Exception:
        nft_restore(snapshot, router_container)
        raise


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
    router_container = str(
        document["geo_policy"]["health"]["probe_network_container"]
    )
    routes = ensure_route_contract(
        policy,
        mutate=False,
        transport_receipt_path=transport_receipt_path,
        network_container=router_container,
    )
    source_gateways = ensure_source_gateway_contract(
        document,
        transport_receipt_path,
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
                f"external_ipv4={probe['external_ipv4'] or 'unknown'}, "
                f"openai={probe['openai_probe']}, "
                f"openai_status={probe['openai_status']}, "
                f"route={probe['route_decision']}"
            )
    rendered = render_nft(policy, dataset.splitlines(), active_path)
    transaction = render_transaction(rendered)
    table_present = bool(nft_snapshot(router_container))
    host_table_present = bool(nft_snapshot())
    if host_table_present:
        raise ContractError(
            "legacy host GeoPolicy nftables table must be removed before apply"
        )
    if table_present and not receipt_file.exists():
        raise ContractError(
            "managed router nftables table exists without a GeoPolicy receipt"
        )
    nft_check(transaction, router_container)
    result = receipt_payload(policy, dataset, active_path, routes)
    result.update({
        "action": "check" if check_only else "apply",
        "check_mode_mutations": False,
        "mutation_performed": False,
        "nft_config_valid": True,
        "dataset": freshness,
        "egress_probes": probes,
        "source_gateways": source_gateways,
        "application_probe": {
            "performed": False,
            "reason": "check_mode" if check_only else "pending_apply",
        },
        "vpn_ingress_probe": {
            "performed": False,
            "reason": "check_mode" if check_only else "pending_apply",
        },
        "runtime_state": {
            "nft_scope": "platform_router_netns",
            "router_nft_table_present": table_present,
            "host_nft_table_present": host_table_present,
            "receipt_present": receipt_file.exists(),
            "approval_matches": (
                not receipt_file.exists()
                or current_receipt.get("approval_id") == policy.approval_id
            ),
        },
    })
    if check_only:
        return result
    application_probe, vpn_ingress_probe = apply_and_accept_router_policy(
        transaction,
        router_container,
        document,
        policy,
        active_path,
    )
    result["application_probe"] = application_probe
    result["vpn_ingress_probe"] = vpn_ingress_probe
    previous = receipt_file
    if previous.exists():
        atomic_write(str(previous) + ".previous", previous.read_text(encoding="utf-8"))
    result["mutation_performed"] = True
    atomic_write(receipt_path, json.dumps(result, sort_keys=True, indent=2) + "\n", 0o600)
    return result


def remove_policy(config: dict[str, Any], policy: Any, receipt_path: str) -> dict[str, Any]:
    router_container = str(
        config["geo_policy"]["health"]["probe_network_container"]
    )
    router_present = bool(nft_snapshot(router_container))
    nft_delete(router_container)
    return {
        "action": "remove",
        "check_mode_mutations": False,
        "mutation_performed": router_present,
        "nft_scope": "platform_router_netns",
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
            network_container=str(
                document["geo_policy"]["health"]["probe_network_container"]
            ),
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
        result = remove_policy(document, policy, args.receipt)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
