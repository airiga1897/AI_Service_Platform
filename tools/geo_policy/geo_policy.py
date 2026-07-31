#!/usr/bin/env python3
"""Build and validate GeoPolicy data, renders, ranking, and failover state."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import statistics
import tempfile
from dataclasses import dataclass
from typing import Any, Iterable

try:
    import yaml
except ImportError:  # pragma: no cover - handled by CLI validation
    yaml = None


SCHEMA_VERSION = 1
SPECIAL_IPV4 = tuple(
    ipaddress.ip_network(item)
    for item in (
        "0.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.0.0.0/24",
        "192.0.2.0/24",
        "192.168.0.0/16",
        "198.18.0.0/15",
        "198.51.100.0/24",
        "203.0.113.0/24",
        "224.0.0.0/4",
        "240.0.0.0/4",
    )
)


class ContractError(ValueError):
    """Raised when operator input is unsafe or internally inconsistent."""


def _require_mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be a mapping")
    return value


def _require_bool(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise ContractError(f"{label} must be boolean")
    return value


def _ipv4_network(value: Any, label: str) -> ipaddress.IPv4Network:
    try:
        network = ipaddress.ip_network(str(value), strict=True)
    except ValueError as exc:
        raise ContractError(f"{label} must be a canonical CIDR: {value}") from exc
    if not isinstance(network, ipaddress.IPv4Network):
        raise ContractError(f"{label} must be IPv4")
    return network


def _ipv4_address(value: Any, label: str) -> ipaddress.IPv4Address:
    try:
        address = ipaddress.ip_address(str(value))
    except ValueError as exc:
        raise ContractError(f"{label} must be an IP address: {value}") from exc
    if not isinstance(address, ipaddress.IPv4Address):
        raise ContractError(f"{label} must be IPv4")
    return address


def _mark(value: Any, label: str) -> int:
    text = str(value).strip().lower()
    try:
        result = int(text, 16) if text.startswith("0x") else int(text)
    except ValueError as exc:
        raise ContractError(f"{label} must be an integer or hexadecimal mark") from exc
    if result < 1 or result > 0xFFFFFFFF:
        raise ContractError(f"{label} must be between 1 and 0xffffffff")
    return result


def load_yaml(path: os.PathLike[str] | str) -> dict[str, Any]:
    if yaml is None:
        raise ContractError("PyYAML is required")
    with open(path, encoding="utf-8") as handle:
        return _require_mapping(yaml.safe_load(handle) or {}, str(path))


@dataclass(frozen=True)
class EgressPath:
    alias: str
    gateway_ipv4: str
    route_table: int
    route_mark: int
    country_code: str


@dataclass(frozen=True)
class GeoPolicy:
    name: str
    ingress_alias: str
    state: str
    sources: tuple[str, ...]
    source_classes: dict[str, tuple[str, ...]]
    excluded_destinations: tuple[str, ...]
    paths: tuple[EgressPath, ...]
    fail_closed: bool
    approval_id: str
    fail_after: int
    recover_after: int
    probe_interval_seconds: int
    recovery_hold_seconds: int
    dataset_max_age_hours: int


def validate_config(document: dict[str, Any], alias: str | None = None) -> GeoPolicy:
    if document.get("schema_version") != SCHEMA_VERSION:
        raise ContractError(f"schema_version must be {SCHEMA_VERSION}")
    policy = _require_mapping(document.get("geo_policy"), "geo_policy")
    name = str(policy.get("name") or "").strip()
    ingress_alias = str(policy.get("ingress_alias") or "").strip()
    state = str(policy.get("state") or "").strip()
    if not name:
        raise ContractError("geo_policy.name is required")
    if not ingress_alias:
        raise ContractError("geo_policy.ingress_alias is required")
    if alias and ingress_alias != alias:
        raise ContractError(f"GeoPolicy ingress {ingress_alias} does not match target {alias}")
    if state not in {"proposed", "accepted"}:
        raise ContractError("geo_policy.state must be proposed or accepted")
    if policy.get("ipv4_only") is not True:
        raise ContractError("GeoPolicy canary must set ipv4_only=true")

    classes_doc = _require_mapping(policy.get("source_classes"), "geo_policy.source_classes")
    expected_classes = {"site_runtime", "vpn_ingress"}
    if set(classes_doc) != expected_classes:
        raise ContractError("source_classes must contain exactly site_runtime and vpn_ingress")
    source_classes: dict[str, tuple[str, ...]] = {}
    all_sources: list[ipaddress.IPv4Network] = []
    for class_name in sorted(classes_doc):
        values = classes_doc[class_name]
        if not isinstance(values, list) or not values:
            raise ContractError(f"source_classes.{class_name} must be a non-empty list")
        parsed = tuple(_ipv4_network(item, f"source_classes.{class_name}") for item in values)
        for network in parsed:
            if network.prefixlen != 32:
                raise ContractError(f"source_classes.{class_name} must use /32 sources")
        source_classes[class_name] = tuple(str(item) for item in parsed)
        all_sources.extend(parsed)
    if len(set(all_sources)) != len(all_sources):
        raise ContractError("source classes must not overlap")

    routing = _require_mapping(policy.get("routing"), "geo_policy.routing")
    expected_actions = {
        "ru_public": "direct",
        "non_ru_public": "egress",
        "unknown_public": "egress",
        "special_or_internal": "direct",
    }
    for key, expected in expected_actions.items():
        if routing.get(key) != expected:
            raise ContractError(f"routing.{key} must be {expected}")
    fail_closed = _require_bool(routing.get("fail_closed"), "routing.fail_closed")
    if not fail_closed:
        raise ContractError("routing.fail_closed must be true for this canary")

    exclusions = policy.get("excluded_destinations") or []
    if not isinstance(exclusions, list):
        raise ContractError("excluded_destinations must be a list")
    parsed_exclusions = [_ipv4_network(item, "excluded_destinations") for item in exclusions]
    for required in SPECIAL_IPV4:
        if not any(required.subnet_of(candidate) for candidate in parsed_exclusions):
            raise ContractError(f"excluded_destinations must cover {required}")

    egress = _require_mapping(policy.get("egress"), "geo_policy.egress")
    approval_id = str(egress.get("approval_id") or "").strip()
    if state == "accepted" and not approval_id:
        raise ContractError("accepted GeoPolicy requires egress.approval_id")

    support = _require_mapping(
        egress.get("openai_country_acceptance"),
        "egress.openai_country_acceptance",
    )
    official_source = str(support.get("source_url") or "").strip()
    checked_at = str(support.get("checked_at") or "").strip()
    supported_codes_value = support.get("supported_country_codes") or []
    if not isinstance(supported_codes_value, list):
        raise ContractError("supported_country_codes must be a list")
    supported_codes = {
        str(item).strip().upper() for item in supported_codes_value if str(item).strip()
    }
    if state == "accepted":
        if official_source.rstrip("/") != (
            "https://help.openai.com/en/articles/"
            "5347006-openai-api-supported-countries-and-territories"
        ):
            raise ContractError("accepted GeoPolicy requires the official OpenAI country-list URL")
        try:
            checked = dt.datetime.fromisoformat(checked_at.replace("Z", "+00:00"))
        except ValueError as exc:
            raise ContractError("OpenAI country acceptance checked_at is invalid") from exc
        if checked.tzinfo is None:
            raise ContractError("OpenAI country acceptance checked_at requires timezone")

    paths_value = egress.get("paths")
    if not isinstance(paths_value, list) or not paths_value:
        raise ContractError("egress.paths must be a non-empty ordered list")

    def path(item_value: Any, index: int) -> EgressPath:
        label = f"paths[{index}]"
        item = _require_mapping(item_value, f"egress.{label}")
        path_alias = str(item.get("alias") or "").strip()
        if not path_alias:
            raise ContractError(f"egress.{label}.alias is required")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", path_alias):
            raise ContractError(f"egress.{label}.alias is invalid")
        if path_alias in {"auto", "blocked"}:
            raise ContractError(f"egress.{label}.alias is reserved")
        if path_alias == ingress_alias:
            raise ContractError(f"egress.{label}.alias must not equal ingress_alias")
        gateway = _ipv4_address(item.get("gateway_ipv4"), f"egress.{label}.gateway_ipv4")
        table = int(item.get("route_table") or 0)
        if table < 1 or table > 0x7FFFFFFF:
            raise ContractError(f"egress.{label}.route_table is invalid")
        route_mark = _mark(item.get("route_mark"), f"egress.{label}.route_mark")
        country_code = str(item.get("country_code") or "").strip().upper()
        if state == "accepted" and country_code not in supported_codes:
            raise ContractError(
                f"egress.{label}.country_code must be present in the accepted "
                "OpenAI supported-country receipt"
            )
        if country_code == "RU":
            raise ContractError(f"egress.{label}.country_code must not be RU")
        return EgressPath(path_alias, str(gateway), table, route_mark, country_code)

    paths = tuple(path(item, index) for index, item in enumerate(paths_value))
    if len({item.alias for item in paths}) != len(paths):
        raise ContractError("egress path aliases must be unique")
    if len({item.route_table for item in paths}) != len(paths):
        raise ContractError("egress path route tables must be unique")
    if len({item.route_mark for item in paths}) != len(paths):
        raise ContractError("egress path route marks must be unique")

    health = _require_mapping(policy.get("health"), "geo_policy.health")
    fail_after = int(health.get("fail_after") or 0)
    recover_after = int(health.get("recover_after") or 0)
    interval = int(health.get("probe_interval_seconds") or 0)
    hold = int(health.get("recovery_hold_seconds") or 0)
    if fail_after != 3 or recover_after != 5 or interval != 15 or hold != 300:
        raise ContractError("health must be fail_after=3, recover_after=5, interval=15, hold=300")
    for key in ("country_probe_host", "openai_probe_host"):
        value = str(health.get(key) or "").strip()
        if not value or "/" in value or ":" in value:
            raise ContractError(f"health.{key} must be a hostname")
    for key in ("country_probe_path", "openai_probe_path"):
        value = str(health.get(key) or "").strip()
        if not value.startswith("/") or "\r" in value or "\n" in value:
            raise ContractError(f"health.{key} must be an absolute HTTP path")
    dataset = _require_mapping(policy.get("dataset"), "geo_policy.dataset")
    max_age_hours = int(dataset.get("max_age_hours") or 0)
    if max_age_hours != 72:
        raise ContractError("dataset.max_age_hours must be 72")

    return GeoPolicy(
        name=name,
        ingress_alias=ingress_alias,
        state=state,
        sources=tuple(str(item) for item in sorted(all_sources)),
        source_classes=source_classes,
        excluded_destinations=tuple(str(item) for item in parsed_exclusions),
        paths=paths,
        fail_closed=fail_closed,
        approval_id=approval_id,
        fail_after=fail_after,
        recover_after=recover_after,
        probe_interval_seconds=interval,
        recovery_hold_seconds=hold,
        dataset_max_age_hours=max_age_hours,
    )


def parse_cidrs(lines: Iterable[str], label: str) -> tuple[ipaddress.IPv4Network, ...]:
    result: list[ipaddress.IPv4Network] = []
    for number, raw in enumerate(lines, 1):
        text = raw.split("#", 1)[0].strip()
        if not text:
            continue
        network = _ipv4_network(text, f"{label}:{number}")
        if network.prefixlen == 0:
            raise ContractError(f"{label}:{number} must not contain a default route")
        if any(network.overlaps(special) for special in SPECIAL_IPV4):
            raise ContractError(f"{label}:{number} overlaps special range: {network}")
        result.append(network)
    if not result:
        raise ContractError(f"{label} contains no IPv4 CIDRs")
    return tuple(ipaddress.collapse_addresses(result))


def parse_ripe_ru_allocations(lines: Iterable[str]) -> tuple[ipaddress.IPv4Network, ...]:
    networks: list[ipaddress.IPv4Network] = []
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("|")
        if len(fields) < 7 or fields[1].upper() != "RU" or fields[2] != "ipv4":
            continue
        if fields[6] not in {"allocated", "assigned"}:
            continue
        start = _ipv4_address(fields[3], "RIPE allocation start")
        try:
            count = int(fields[4])
        except ValueError as exc:
            raise ContractError(f"RIPE allocation has invalid count: {fields[4]}") from exc
        if count < 1:
            raise ContractError("RIPE allocation count must be positive")
        last = ipaddress.IPv4Address(int(start) + count - 1)
        networks.extend(ipaddress.summarize_address_range(start, last))
    if not networks:
        raise ContractError("RIPE guard contains no RU IPv4 allocations")
    return tuple(ipaddress.collapse_addresses(networks))


def address_count(networks: Iterable[ipaddress.IPv4Network]) -> int:
    return sum(item.num_addresses for item in networks)


def covered_address_count(
    candidate: Iterable[ipaddress.IPv4Network],
    reference: Iterable[ipaddress.IPv4Network],
) -> int:
    candidate_items = tuple(candidate)
    reference_items = tuple(reference)
    covered = 0
    left = 0
    right = 0
    while left < len(candidate_items) and right < len(reference_items):
        candidate_network = candidate_items[left]
        reference_network = reference_items[right]
        start = max(
            int(candidate_network.network_address),
            int(reference_network.network_address),
        )
        end = min(
            int(candidate_network.broadcast_address),
            int(reference_network.broadcast_address),
        )
        if start <= end:
            covered += end - start + 1
        if candidate_network.broadcast_address < reference_network.broadcast_address:
            left += 1
        else:
            right += 1
    return covered


def build_dataset(
    ipdeny_lines: Iterable[str],
    ripe_lines: Iterable[str],
    *,
    previous: dict[str, Any] | None = None,
    accept_initial: bool = False,
    fetched_at: str | None = None,
) -> tuple[str, dict[str, Any]]:
    ipdeny_raw = list(ipdeny_lines)
    source_prefix_count = sum(
        1 for raw in ipdeny_raw if raw.split("#", 1)[0].strip()
    )
    networks = parse_cidrs(ipdeny_raw, "IPdeny")
    ripe = parse_ripe_ru_allocations(ripe_lines)
    if source_prefix_count < 5000 or source_prefix_count > 20000:
        raise ContractError(
            f"IPdeny RU source prefix count outside safety bounds: {source_prefix_count}"
        )
    ripe_total = address_count(ripe)
    coverage = covered_address_count(networks, ripe) / ripe_total
    if coverage < 0.90:
        raise ContractError(f"IPdeny covers only {coverage:.3%} of RIPE RU allocations")
    total = address_count(networks)
    if previous:
        previous_total = int(previous.get("address_count") or 0)
        if previous_total:
            delta = abs(total - previous_total) / previous_total
            if delta > 0.20:
                raise ContractError(f"dataset address-count delta exceeds 20%: {delta:.3%}")
    elif not accept_initial:
        raise ContractError("first dataset requires explicit acceptance")
    content = "".join(f"{item}\n" for item in networks)
    checksum = hashlib.sha256(content.encode("ascii")).hexdigest()
    timestamp = fetched_at or dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    metadata = {
        "schema_version": SCHEMA_VERSION,
        "country": "RU",
        "family": "ipv4",
        "source": "https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone",
        "guard": "https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-extended-latest",
        "fetched_at": timestamp,
        "sha256": checksum,
        "prefix_count": len(networks),
        "source_prefix_count": source_prefix_count,
        "address_count": total,
        "ripe_coverage": round(coverage, 6),
        "previous_sha256": str((previous or {}).get("sha256") or ""),
        "root_accepted_sha256": str(
            (previous or {}).get("root_accepted_sha256")
            or (checksum if accept_initial else "")
        ),
    }
    return content, metadata


def _nft_elements(values: Iterable[str]) -> str:
    return ", ".join(values)


def render_nft(policy: GeoPolicy, ru_cidrs: Iterable[str], active_path: str) -> str:
    aliases = tuple(item.alias for item in policy.paths)
    if active_path not in {*aliases, "blocked"}:
        raise ContractError("active_path must be a configured egress alias or blocked")
    ru = tuple(str(item) for item in parse_cidrs(ru_cidrs, "RU dataset"))
    sources = _nft_elements(policy.sources)
    exclusions = _nft_elements(policy.excluded_destinations)
    ru_values = _nft_elements(ru)
    active_mark = next(
        (item.route_mark for item in policy.paths if item.alias == active_path),
        policy.paths[0].route_mark,
    )
    mark = f"0x{active_mark:x}"
    classify_action = "drop" if active_path == "blocked" else f"meta mark set {mark} ct mark set {mark}"
    return (
        "table inet ai_sp_geo_egress {\n"
        "  set scoped_sources { type ipv4_addr; flags interval; "
        f"elements = {{ {sources} }} }}\n"
        "  set excluded_ipv4 { type ipv4_addr; flags interval; "
        f"elements = {{ {exclusions} }} }}\n"
        "  set ru_ipv4 { type ipv4_addr; flags interval; "
        f"elements = {{ {ru_values} }} }}\n"
        "  chain classify_new {\n"
        "    ip daddr @excluded_ipv4 return\n"
        "    ip daddr @ru_ipv4 return\n"
        f"    {classify_action}\n"
        "  }\n"
        "  chain prerouting {\n"
        "    type filter hook prerouting priority mangle; policy accept;\n"
        "    ct state established,related meta mark set ct mark\n"
        "    ct state new ip saddr @scoped_sources jump classify_new\n"
        "  }\n"
        "}\n"
    )


def classify_destination(address: str, ru_cidrs: Iterable[str], exclusions: Iterable[str]) -> str:
    value = _ipv4_address(address, "destination")
    if any(value in _ipv4_network(item, "excluded destination") for item in exclusions):
        return "direct"
    if any(value in _ipv4_network(item, "RU dataset") for item in ru_cidrs):
        return "direct"
    return "egress"


def rank_candidates(document: dict[str, Any]) -> dict[str, Any]:
    candidates = document.get("candidates")
    if not isinstance(candidates, list):
        raise ContractError("candidates must be a list")
    accepted: list[tuple[float, str, dict[str, Any]]] = []
    seen_aliases: set[str] = set()
    for item in candidates:
        item = _require_mapping(item, "candidate")
        alias = str(item.get("alias") or "").strip()
        samples = item.get("latency_ms")
        if not alias or not isinstance(samples, list) or len(samples) != 5:
            raise ContractError("each candidate requires alias and five latency_ms samples")
        if alias in seen_aliases:
            raise ContractError(f"candidate alias is duplicated: {alias}")
        seen_aliases.add(alias)
        if item.get("country") == "RU":
            continue
        if item.get("openai_supported_country") is not True:
            continue
        if item.get("openai_probe") != "succeeded":
            continue
        median = statistics.median(float(value) for value in samples)
        accepted.append((median, alias, item))
    accepted.sort(key=lambda item: (item[0], item[1]))
    if not accepted:
        raise ContractError("at least one accepted non-RU OpenAI-capable candidate is required")
    ranked = [item[2] for item in accepted]
    payload = {
        "schema_version": SCHEMA_VERSION,
        "status": "proposed",
        "paths": ranked,
        "redundancy": "available" if len(ranked) > 1 else "unavailable",
        "ranking": [{"alias": item[1], "median_latency_ms": item[0]} for item in accepted],
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    payload["proposal_id"] = hashlib.sha256(canonical).hexdigest()[:24]
    return payload


def reconcile_health(
    policy: GeoPolicy,
    state: dict[str, Any],
    probes: dict[str, bool],
    now: dt.datetime,
) -> dict[str, Any]:
    aliases = tuple(item.alias for item in policy.paths)
    current = str(state.get("active_path") or aliases[0])
    if current not in {*aliases, "blocked"}:
        raise ContractError("state.active_path is invalid")
    previous_counters = state.get("health_counters") or {}
    if not isinstance(previous_counters, dict):
        raise ContractError("state.health_counters must be a mapping")
    result = {
        "schema_version": SCHEMA_VERSION,
        "active_path": current,
        "health_counters": {},
        "last_switch_at": state.get("last_switch_at"),
        "switch_reason": "unchanged",
    }
    for path_alias in aliases:
        old = previous_counters.get(path_alias) or {}
        if not isinstance(old, dict):
            raise ContractError(f"state.health_counters.{path_alias} must be a mapping")
        ok = bool(probes.get(path_alias))
        result["health_counters"][path_alias] = {
            "failures": 0 if ok else int(old.get("failures") or 0) + 1,
            "successes": int(old.get("successes") or 0) + 1 if ok else 0,
        }

    def switch(target: str, reason: str) -> None:
        result["active_path"] = target
        result["last_switch_at"] = now.astimezone(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        result["switch_reason"] = reason

    def recovery_hold_elapsed() -> bool:
        switched = state.get("last_switch_at")
        if not switched:
            return False
        switched_at = dt.datetime.fromisoformat(str(switched).replace("Z", "+00:00"))
        return (
            now.astimezone(dt.UTC) - switched_at
        ).total_seconds() >= policy.recovery_hold_seconds

    def healthy(path_alias: str) -> bool:
        return bool(probes.get(path_alias))

    def recovered(path_alias: str) -> bool:
        return (
            healthy(path_alias)
            and result["health_counters"][path_alias]["successes"] >= policy.recover_after
            and recovery_hold_elapsed()
        )

    if current == "blocked":
        target = next((item for item in aliases if recovered(item)), None)
        if target:
            switch(target, f"{target}_recovered")
        return result

    current_index = aliases.index(current)
    higher_priority = aliases[:current_index]
    recovered_higher = next((item for item in higher_priority if recovered(item)), None)
    if recovered_higher:
        switch(recovered_higher, f"{recovered_higher}_recovered")
        return result

    if result["health_counters"][current]["failures"] >= policy.fail_after:
        lower_healthy = next((item for item in aliases[current_index + 1 :] if healthy(item)), None)
        higher_recovered = next((item for item in higher_priority if recovered(item)), None)
        target = lower_healthy or higher_recovered
        switch(target or "blocked", f"{current}_failed" if target else "all_egress_failed")
    return result


def atomic_write(path: os.PathLike[str] | str, content: str, mode: int = 0o644) -> None:
    destination = pathlib.Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, destination)
        directory_fd = os.open(destination.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _json(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        return _require_mapping(json.load(handle), path)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate-config")
    validate.add_argument("--config", required=True)
    validate.add_argument("--alias")
    dataset = subparsers.add_parser("build-dataset")
    dataset.add_argument("--ipdeny-file", required=True)
    dataset.add_argument("--ripe-file", required=True)
    dataset.add_argument("--previous-metadata")
    dataset.add_argument("--accept-initial", action="store_true")
    dataset.add_argument("--output-cidrs")
    dataset.add_argument("--output-metadata")
    render = subparsers.add_parser("render-nft")
    render.add_argument("--config", required=True)
    render.add_argument("--dataset", required=True)
    render.add_argument("--active-path", required=True)
    render.add_argument("--output")
    rank = subparsers.add_parser("rank")
    rank.add_argument("--probe-results", required=True)
    rank.add_argument("--output")
    args = parser.parse_args()
    if args.command == "validate-config":
        policy = validate_config(load_yaml(args.config), args.alias)
        print(json.dumps({"name": policy.name, "ingress_alias": policy.ingress_alias, "state": policy.state}, sort_keys=True))
    elif args.command == "build-dataset":
        with open(args.ipdeny_file, encoding="utf-8") as handle:
            ipdeny_lines = list(handle)
        with open(args.ripe_file, encoding="utf-8") as handle:
            ripe_lines = list(handle)
        previous = _json(args.previous_metadata) if args.previous_metadata else None
        content, metadata = build_dataset(ipdeny_lines, ripe_lines, previous=previous, accept_initial=args.accept_initial)
        if args.output_cidrs:
            atomic_write(args.output_cidrs, content)
        if args.output_metadata:
            atomic_write(args.output_metadata, json.dumps(metadata, sort_keys=True, indent=2) + "\n")
        print(json.dumps(metadata, sort_keys=True))
    elif args.command == "render-nft":
        policy = validate_config(load_yaml(args.config))
        with open(args.dataset, encoding="utf-8") as handle:
            rendered = render_nft(policy, handle, args.active_path)
        if args.output:
            atomic_write(args.output, rendered)
        else:
            print(rendered, end="")
    elif args.command == "rank":
        result = rank_candidates(_json(args.probe_results))
        rendered = json.dumps(result, sort_keys=True, indent=2) + "\n"
        if args.output:
            atomic_write(args.output, rendered)
        else:
            print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
