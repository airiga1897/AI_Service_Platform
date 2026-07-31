#!/usr/bin/env python3
"""Collect safe direct-egress probes and produce a GeoPolicy ranking proposal."""

from __future__ import annotations

import argparse
import base64
import csv
import json
import os
import pathlib
import subprocess
import sys

from tools.geo_policy.geo_policy import ContractError, atomic_write, rank_candidates


REMOTE_PROBE = r"""
import json
import time
import urllib.error
import urllib.request

def request(url):
    started = time.monotonic()
    try:
        with urllib.request.urlopen(
            urllib.request.Request(url, headers={"User-Agent": "ai-service-platform-geo-policy/1"}),
            timeout=10,
        ) as response:
            return response.status, response.read(65536), (time.monotonic() - started) * 1000
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(65536), (time.monotonic() - started) * 1000

country_status, country_body, _ = request("https://api.country.is/")
try:
    country = json.loads(country_body.decode("utf-8")).get("country", "").upper()
except Exception:
    country = ""
latencies = []
statuses = []
unsupported = False
for _ in range(5):
    status, body, latency = request("https://api.openai.com/v1/models")
    statuses.append(status)
    latencies.append(round(latency, 3))
    unsupported = unsupported or b"unsupported_country_region_territory" in body
print(json.dumps({
    "country": country,
    "country_status": country_status,
    "latency_ms": latencies,
    "openai_statuses": statuses,
    "openai_probe": "succeeded" if all(item in (200, 401) for item in statuses) and not unsupported else "failed",
    "openai_supported_country": all(item in (200, 401) for item in statuses) and not unsupported,
    "unsupported_country": unsupported,
}, sort_keys=True))
"""


def load_nodes(path: str) -> dict[str, dict[str, str]]:
    with open(path, newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    required = {"current_alias", "endpoint", "connection", "ssh_port"}
    if not rows or not required.issubset(rows[0]):
        raise ContractError("nodes.csv does not match the operator contract")
    return {row["current_alias"]: row for row in rows}


def collect(alias: str, node: dict[str, str], operator_dir: str, ssh_user: str) -> dict:
    if node["connection"] != "ssh":
        raise ContractError(f"{alias} is not an SSH node")
    key = pathlib.Path(operator_dir) / alias / "admin_key"
    if not key.is_file():
        raise ContractError(f"SSH key is absent for {alias}: {key}")
    encoded = base64.b64encode(REMOTE_PROBE.encode()).decode()
    remote_command = (
        "python3 -c \"import base64;"
        f"exec(base64.b64decode('{encoded}'))\""
    )
    command = [
        "ssh", "-T", "-n",
        "-i", str(key),
        "-p", str(node.get("ssh_port") or "22"),
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        f"{ssh_user}@{node['endpoint']}",
        remote_command,
    ]
    completed = subprocess.run(
        command,
        text=True,
        capture_output=True,
        encoding="utf-8",
        timeout=90,
    )
    if completed.returncode != 0:
        raise ContractError(f"{alias} probe failed with rc={completed.returncode}")
    try:
        result = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise ContractError(f"{alias} returned invalid probe JSON") from exc
    result["alias"] = alias
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nodes", default="operator/nodes.csv")
    parser.add_argument("--operator-dir", default="operator")
    parser.add_argument("--aliases", required=True, help="Comma-separated candidate aliases")
    parser.add_argument("--ssh-user", default="useradmin")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    aliases = [item.strip() for item in args.aliases.split(",") if item.strip()]
    if not aliases or len(set(aliases)) != len(aliases):
        raise ContractError("one or more unique candidate aliases are required")
    nodes = load_nodes(args.nodes)
    candidates = []
    for alias in aliases:
        if alias not in nodes:
            raise ContractError(f"candidate alias is absent from nodes.csv: {alias}")
        candidates.append(collect(alias, nodes[alias], args.operator_dir, args.ssh_user))
    proposal = rank_candidates({"candidates": candidates})
    atomic_write(args.output, json.dumps(proposal, sort_keys=True, indent=2) + "\n", 0o600)
    print(json.dumps({
        "proposal_id": proposal["proposal_id"],
        "status": proposal["status"],
        "paths": [item["alias"] for item in proposal["paths"]],
        "redundancy": proposal["redundancy"],
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, subprocess.TimeoutExpired) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(2)
