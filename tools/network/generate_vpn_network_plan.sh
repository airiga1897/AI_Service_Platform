#!/usr/bin/env bash

set -euo pipefail

NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
OVERRIDE_FILE="./operator/networks.override.csv"
OUTPUT_FILE="./operator/networks.csv"
CHECK_ONLY="false"

usage() {
    cat <<'USAGE'
Usage:
  bash tools/network/generate_vpn_network_plan.sh [options]

Options:
  --nodes-file PATH       Operator nodes.csv. Default: ./operator/nodes.csv
  --state-file PATH       Operator state.csv. Default: ./operator/state.csv
  --override-file PATH    Optional networks override CSV. Default: ./operator/networks.override.csv
  --output-file PATH      Generated networks.csv. Default: ./operator/networks.csv
  --check                 Validate only, do not write output.
  -h, --help              Show help.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --nodes-file)
            NODES_FILE="${2:-}"
            shift 2
            ;;
        --state-file)
            STATE_FILE="${2:-}"
            shift 2
            ;;
        --override-file)
            OVERRIDE_FILE="${2:-}"
            shift 2
            ;;
        --output-file)
            OUTPUT_FILE="${2:-}"
            shift 2
            ;;
        --check)
            CHECK_ONLY="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

python3 - "$NODES_FILE" "$STATE_FILE" "$OVERRIDE_FILE" "$OUTPUT_FILE" "$CHECK_ONLY" <<'PY'
import csv
import ipaddress
import re
import sys
from pathlib import Path

nodes_file, state_file, override_file, output_file, check_only = sys.argv[1:]
expected_nodes = "current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
expected_state = "kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
expected_networks = "alias,policy_subnet,edge_ip,cascade_ip,cascade_router_ip,policy_gateway_ip"


def fail(message):
    print(f"[ERROR] {message}", file=sys.stderr)
    raise SystemExit(1)


def require_header(path, expected):
    p = Path(path)
    if not p.is_file():
        fail(f"file not found: {path}")
    first = p.read_text(encoding="utf-8").splitlines()[0].rstrip("\r")
    if first != expected:
        fail(f"{p.name} header must be exactly: {expected}")


def split_aliases(value):
    return [item for item in (value or "").split("+") if item]


def read_csv(path, expected):
    require_header(path, expected)
    with open(path, newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


nodes = [row for row in read_csv(nodes_file, expected_nodes) if row.get("current_alias")]
state_rows = read_csv(state_file, expected_state)
node_aliases = {}
for row in nodes:
    alias = row["current_alias"]
    if alias in node_aliases:
        fail(f"nodes.csv has duplicate alias: {alias}")
    node_aliases[alias] = True

for row in state_rows:
    for field in ("active_aliases", "candidate_aliases", "old_aliases"):
        for alias in split_aliases(row.get(field)):
            if alias not in node_aliases:
                fail(f"state.csv references alias '{alias}' in {row.get('kind')}:{row.get('name')}, but nodes.csv has no such alias")

overrides = {}
override_path = Path(override_file)
if override_path.is_file():
    for row in read_csv(override_file, expected_networks):
        alias = row.get("alias")
        if not alias:
            continue
        if alias not in node_aliases:
            fail(f"networks override references unknown alias: {alias}")
        if alias in overrides:
            fail(f"networks override has duplicate alias: {alias}")
        overrides[alias] = row

plan = []
for row in sorted(nodes, key=lambda item: item["current_alias"]):
    alias = row["current_alias"]
    if alias in overrides:
        item = overrides[alias]
    else:
        match = re.fullmatch(r"vps([1-9][0-9]{0,2})", alias)
        if not match:
            fail(f"Alias '{alias}' is not vpsN. Add an explicit row to {override_file}")
        n = int(match.group(1))
        if n < 1 or n > 254:
            fail(f"Alias '{alias}' maps to unsupported VPS number {n}; expected 1..254")
        network_id = 255 - n
        item = {
            "alias": alias,
            "policy_subnet": f"172.22.{network_id}.0/24",
            "edge_ip": f"172.22.{network_id}.2",
            "cascade_ip": f"172.22.{network_id}.3",
            "cascade_router_ip": f"172.23.0.{network_id}",
            "policy_gateway_ip": f"172.22.{network_id}.4",
        }
    plan.append({key: item[key] for key in ("alias", "policy_subnet", "edge_ip", "cascade_ip", "cascade_router_ip", "policy_gateway_ip")})

reserved = [ipaddress.ip_network("172.20.0.0/24"), ipaddress.ip_network("172.21.0.0/24")]
seen_subnets = {}
seen_ips = {}
for row in plan:
    subnet = ipaddress.ip_network(row["policy_subnet"], strict=True)
    for reserved_net in reserved:
        if subnet.overlaps(reserved_net):
            fail(f"Policy subnet for {row['alias']} overlaps reserved network {reserved_net}: {subnet}")
    if str(subnet) in seen_subnets:
        fail(f"Duplicate policy_subnet {subnet} for {row['alias']} and {seen_subnets[str(subnet)]}")
    seen_subnets[str(subnet)] = row["alias"]
    for field in ("edge_ip", "cascade_ip", "policy_gateway_ip"):
        ip = ipaddress.ip_address(row[field])
        if ip not in subnet:
            fail(f"{row['alias']}.{field} {ip} is outside {subnet}")
    for field in ("edge_ip", "cascade_ip", "cascade_router_ip", "policy_gateway_ip"):
        ip = str(ipaddress.ip_address(row[field]))
        if ip in seen_ips:
            fail(f"Duplicate IP {ip} for {row['alias']}.{field} and {seen_ips[ip]}")
        seen_ips[ip] = f"{row['alias']}.{field}"

if check_only == "true":
    print(f"[OK] VPN network plan is valid for {len(plan)} aliases")
else:
    output = Path(output_file)
    output.parent.mkdir(parents=True, exist_ok=True)
    with open(output, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=expected_networks.split(","))
        writer.writeheader()
        writer.writerows(plan)
    print(f"[OK] VPN network plan written: {output_file}")
PY
