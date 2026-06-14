#!/usr/bin/env python3
"""Collect sanitized edge route/egress candidate evidence from local logs.

The collector intentionally emits only normalized target facts and aggregate
counts. It does not preserve raw log lines, request payloads, tokens, keys, or
VPN configuration fragments.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable
from urllib.parse import urlparse


ERROR_RE = re.compile(
    r"\b(reject(?:ed)?|den(?:y|ied)|timeout|timed\s*out|fail(?:ed|ure)?|"
    r"unreachable|no\s+route|connection\s+refused|connect(?:ion)?\s+error|"
    r"backend|sni|rate[-_ ]?limit|fallback|probe|cascade)\b",
    re.IGNORECASE,
)
URL_RE = re.compile(r"\bhttps?://[A-Za-z0-9._~%-]+(?::\d{1,5})?(?:/[^\s\"'<>]*)?", re.IGNORECASE)
KEY_VALUE_RE = re.compile(
    r"\b(?:sni|host|target|domain|dst|destination|backend|server|upstream|addr)="
    r"(?P<value>[A-Za-z0-9._~%-]+|\[[0-9a-fA-F:.]+\])(?::(?P<port>\d{1,5}))?",
    re.IGNORECASE,
)
HOST_PORT_RE = re.compile(
    r"(?<![A-Za-z0-9._~%-])(?P<value>[A-Za-z0-9][A-Za-z0-9._-]{1,253}|\d{1,3}(?:\.\d{1,3}){3}):(?P<port>\d{1,5})(?![A-Za-z0-9._~-])"
)
SENSITIVE_RE = re.compile(
    r"(password|passwd|pwd|secret|token|authorization|private[_-]?key|vpn_server\.config|cookie|set-cookie)",
    re.IGNORECASE,
)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_port(protocol: str, port: int | None) -> int:
    if port and 0 <= port <= 65535:
        return port
    if protocol == "https":
        return 443
    if protocol == "http":
        return 80
    return 0


def target_type(value: str) -> str:
    stripped = value.strip("[]")
    try:
        ipaddress.ip_address(stripped)
        return "ip"
    except ValueError:
        return "domain"


def protocol_from_port(port: int | None, default: str = "tcp") -> str:
    if port == 443:
        return "https"
    if port == 80:
        return "http"
    return default


def clean_value(value: str) -> str:
    return value.strip().strip("[]").strip(".").lower()


def valid_host_or_ip(value: str) -> bool:
    value = clean_value(value)
    if not value or len(value) > 253:
        return False
    if "." not in value and target_type(value) != "ip":
        return False
    if value in {"localhost", "docker", "haproxy", "policy-gateway"}:
        return False
    return bool(re.match(r"^[a-z0-9._-]+$", value))


def build_target(value: str, protocol: str, port: int | None, path: str = "/") -> dict | None:
    normalized = clean_value(value)
    if not valid_host_or_ip(normalized):
        return None
    normalized_port = normalize_port(protocol, port)
    return {
        "type": target_type(normalized),
        "value": normalized,
        "protocol": protocol,
        "port": normalized_port,
        "path": path or "/",
    }


def candidate_type_for(source: str, line: str) -> str:
    text = line.lower()
    if source == "haproxy":
        if "rate" in text and "limit" in text:
            return "route_review"
        if "backend" in text or "sni" in text or "reject" in text or "deny" in text:
            return "missing_route"
        return "route_review"
    if "fallback" in text or "probe" in text:
        return "fallback_probe_error"
    if "cascade" in text or "transport" in text:
        return "egress_candidate"
    return "route_review"


def extract_targets(line: str) -> Iterable[dict]:
    for match in URL_RE.finditer(line):
        parsed = urlparse(match.group(0))
        if not parsed.hostname:
            continue
        protocol = parsed.scheme.lower()
        yield from maybe_target(parsed.hostname, protocol, parsed.port, parsed.path or "/")

    for match in KEY_VALUE_RE.finditer(line):
        value = match.group("value")
        port = int(match.group("port")) if match.group("port") else None
        protocol = protocol_from_port(port)
        yield from maybe_target(value, protocol, port)

    for match in HOST_PORT_RE.finditer(line):
        value = match.group("value")
        port = int(match.group("port"))
        protocol = protocol_from_port(port)
        yield from maybe_target(value, protocol, port)


def maybe_target(value: str, protocol: str, port: int | None, path: str = "/") -> Iterable[dict]:
    target = build_target(value, protocol, port, path)
    if target:
        yield target


def read_lines(path: Path, max_lines: int) -> Iterable[str]:
    if not path.exists() or not path.is_file():
        return []
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if max_lines > 0:
        lines = lines[-max_lines:]
    return lines


def source_summary(source: str, candidate_type: str, target: dict) -> str:
    return (
        f"{source} observed {candidate_type} symptoms for "
        f"{target['protocol']}://{target['value']}:{target['port']}"
    )


def collect_from_file(source_alias: str, source: str, path: Path, max_lines: int) -> list[dict]:
    counts: Counter[tuple] = Counter()
    observed_at = utc_now()
    for line in read_lines(path, max_lines):
        if not line or SENSITIVE_RE.search(line) or not ERROR_RE.search(line):
            continue
        candidate_type = candidate_type_for(source, line)
        for target in extract_targets(line):
            key = (
                source,
                candidate_type,
                target["type"],
                target["value"],
                target["protocol"],
                target["port"],
                target["path"],
            )
            counts[key] += 1

    records = []
    for key, count in sorted(counts.items()):
        source, candidate_type, typ, value, protocol, port, path_value = key
        target = {
            "type": typ,
            "value": value,
            "protocol": protocol,
            "port": port,
            "path": path_value,
        }
        records.append(
            {
                "schema_version": 1,
                "observed_at_utc": observed_at,
                "source_alias": source_alias,
                "source": source,
                "candidate_type": candidate_type,
                "target": target,
                "evidence": {
                    "summary": source_summary(source, candidate_type, target),
                    "count": count,
                    "sample_window": path.name,
                },
            }
        )
    return records


def write_jsonl(records: list[dict], output: Path, append: bool) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    mode = "a" if append else "w"
    with output.open(mode, encoding="utf-8", newline="\n") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Collect sanitized edge candidate evidence.")
    parser.add_argument("--source-alias", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--haproxy-log", action="append", default=[])
    parser.add_argument("--policy-log", action="append", default=[])
    parser.add_argument("--cascade-log", action="append", default=[])
    parser.add_argument("--max-lines", type=int, default=5000)
    parser.add_argument("--append", action="store_true")
    args = parser.parse_args()

    sources = [
        ("haproxy", args.haproxy_log),
        ("policy_gateway", args.policy_log),
        ("vpn_cascade", args.cascade_log),
    ]
    records: list[dict] = []
    for source, paths in sources:
        for raw_path in paths:
            records.extend(collect_from_file(args.source_alias, source, Path(raw_path), args.max_lines))

    write_jsonl(records, Path(args.output), args.append)
    print(f"edge_candidate_collector wrote {len(records)} candidate records to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
