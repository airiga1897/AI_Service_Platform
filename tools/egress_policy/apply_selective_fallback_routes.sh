#!/usr/bin/env bash

set -euo pipefail

python3 - "$@" <<'PY'
import argparse
import base64
import csv
import datetime as dt
import hashlib
import ipaddress
import json
import os
import shlex
import socket
import struct
import subprocess
import sys
import time
from collections import defaultdict

EXPECTED_NODES_HEADER = ["current_alias", "endpoint", "connection", "ssh_port", "root_password"]
EXPECTED_STATE_HEADER = ["kind", "name", "ansible_group", "active_aliases", "candidate_aliases", "old_aliases", "state"]
EXPECTED_NETWORKS_HEADER = ["alias", "policy_subnet", "edge_ip", "cascade_ip", "cascade_router_ip", "policy_gateway_ip"]

POLICY_GATEWAY_CONTAINER = "policy-gateway"
CASCADE_CONTAINER = "softether-cascade"
EDGE_CONTAINER = "softether-edge"
TAP_INTERFACE = "tap_vpnpolicy"
ROUTE_MODE = "hybrid_cascade_canary"


def fail(message):
    print(f"[ERROR] {message}", file=sys.stderr)
    raise SystemExit(1)


def add_bool(parser, ps_name, cli_name, dest, default=False):
    parser.add_argument(ps_name, cli_name, action="store_true", dest=dest, default=default)


def parse_args():
    parser = argparse.ArgumentParser(description="Apply selective egress fallback routes from an orchestration node.")
    parser.add_argument("-Action", "--action", choices=["plan", "apply", "verify", "rollback", "cleanup", "refresh", "counters"], default="plan")
    parser.add_argument("-ProposalDir", "--proposal-dir", default="./operator/egress_policy/proposals")
    parser.add_argument("-AppliedRoutesDir", "--applied-routes-dir", default="./operator/egress_policy/applied_routes")
    parser.add_argument("-NodesFile", "--nodes-file", default="./operator/nodes.csv")
    parser.add_argument("-StateFile", "--state-file", default="./operator/state.csv")
    parser.add_argument("-NetworksFile", "--networks-file", default="./operator/networks.csv")
    parser.add_argument("-CascadeConfigFile", "--cascade-config-file", default="./operator/softether/cascade/secrets/lab-cascade.json")
    parser.add_argument("-OperatorDir", "--operator-dir", default="./operator")
    parser.add_argument("-Id", "--id", action="append", default=[])
    parser.add_argument("-Profile", "--profile", action="append", default=[])
    parser.add_argument("-IngressAlias", "--ingress-alias", action="append", default=[])
    parser.add_argument("-EgressAlias", "--egress-alias", action="append", default=[])
    parser.add_argument("-TargetIp", "--target-ip", action="append", default=[])
    parser.add_argument("-SshUser", "--ssh-user", default="useradmin")
    parser.add_argument("-EdgeSourceIp", "--edge-source-ip", default="172.20.0.2")
    parser.add_argument("-TimeoutSeconds", "--timeout-seconds", type=int, default=10)
    parser.add_argument("-SshRetries", "--ssh-retries", type=int, default=3)
    parser.add_argument("-PreflightRetries", "--preflight-retries", type=int, default=6)
    add_bool(parser, "-SkipVerify", "--skip-verify", "skip_verify")
    add_bool(parser, "-TrafficProbe", "--traffic-probe", "traffic_probe")
    add_bool(parser, "-Json", "--json", "json_output")
    return parser.parse_args()


args = parse_args()
if args.timeout_seconds < 1:
    fail("-TimeoutSeconds must be at least 1")
if args.ssh_retries < 1:
    fail("-SshRetries must be at least 1")
if args.preflight_retries < 1:
    fail("-PreflightRetries must be at least 1")

PROFILE_FILTER = {x for x in args.profile if x}
INGRESS_ALIAS_FILTER = {x for x in args.ingress_alias if x}
EGRESS_ALIAS_FILTER = {x for x in args.egress_alias if x}


def require_file(path, label):
    if not os.path.isfile(path):
        fail(f"{label} not found: {path}")


def load_csv_map(path, expected_header, key_field, label):
    require_file(path, label)
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames != expected_header:
            fail(f"{label} header must be exactly: {','.join(expected_header)}")
        result = {}
        for row in reader:
            key = row.get(key_field, "")
            if not key:
                continue
            if key in result:
                fail(f"{label} has duplicate {key_field}: {key}")
            result[key] = row
        return result


def load_state_rows():
    require_file(args.state_file, "state.csv")
    with open(args.state_file, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames != EXPECTED_STATE_HEADER:
            fail(f"state.csv header must be exactly: {','.join(EXPECTED_STATE_HEADER)}")
        return list(reader)


def read_json(path, label):
    try:
        with open(path, encoding="utf-8-sig") as fh:
            return json.load(fh)
    except Exception as exc:
        fail(f"Failed to parse {label}: {path}: {exc}")


def write_json_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}.{int(time.time() * 1000)}"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        os.replace(tmp, path)
    except Exception as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        fail(f"failed to write applied route state via temp file: {path}; runtime route changes may already be applied. Error: {exc}")


nodes = load_csv_map(args.nodes_file, EXPECTED_NODES_HEADER, "current_alias", "nodes.csv")
networks = load_csv_map(args.networks_file, EXPECTED_NETWORKS_HEADER, "alias", "networks.csv")
state_rows = load_state_rows()


def split_alias_list(value):
    return [x.strip() for x in str(value or "").split("+") if x.strip()]


def active_cascade_aliases():
    aliases = set()
    for row in state_rows:
        if row.get("kind") == "service" and row.get("name") == "vpn_cascade" and row.get("state") == "present":
            aliases.update(split_alias_list(row.get("active_aliases")))
    return aliases


def orchestration_aliases():
    aliases = set()
    for row in state_rows:
        if row.get("kind") in ("platform_role", "role") and row.get("name") == "orchestration" and row.get("state") == "present":
            aliases.update(split_alias_list(row.get("active_aliases")))
            aliases.update(split_alias_list(row.get("candidate_aliases")))
    return aliases


def cascade_topology_active_edges():
    rows = [r for r in state_rows if r.get("kind") == "cascade_topology" and r.get("state") == "present"]
    if len(rows) > 1:
        fail("state.csv has multiple present cascade_topology rows; keep exactly one")
    if not rows:
        return None
    active = set()
    for edge in split_alias_list(rows[0].get("active_aliases")):
        if ">" not in edge:
            fail(f"cascade_topology {rows[0].get('name')} has invalid active edge '{edge}'; expected alias>alias")
        active.add(edge)
    return rows[0].get("name"), active


def load_active_cascade_links():
    if not os.path.isfile(args.cascade_config_file):
        return []
    config = read_json(args.cascade_config_file, "cascade config")
    return [x for x in config.get("links", []) if x.get("state") == "active"]


ACTIVE_CASCADE_ALIASES = active_cascade_aliases()
ORCHESTRATION_ALIASES = orchestration_aliases()
CASCADE_TOPOLOGY = cascade_topology_active_edges()
ACTIVE_CASCADE_LINKS = load_active_cascade_links()


def valid_ipv4(value):
    try:
        ipaddress.ip_address(str(value))
        return "." in str(value)
    except ValueError:
        return False


def valid_cidr(value):
    try:
        ipaddress.ip_network(str(value), strict=False)
        return "/" in str(value)
    except ValueError:
        return False


def node_ssh_port(alias):
    raw = str(nodes[alias].get("ssh_port") or "22")
    try:
        port = int(raw)
    except ValueError:
        fail(f"Invalid ssh_port for {alias}: {raw}")
    if port < 1 or port > 65535:
        fail(f"Invalid ssh_port for {alias}: {raw}")
    return str(port)


def ssh_args(alias, command):
    if alias not in nodes:
        fail(f"Unknown node alias: {alias}")
    key = os.path.join(args.operator_dir, alias, "admin_key")
    require_file(key, f"admin key for {alias}")
    node = nodes[alias]
    remote = f"{args.ssh_user}@{node['endpoint']}"
    return [
        "ssh", "-n", "-T", "-p", node_ssh_port(alias), "-i", key,
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={min(args.timeout_seconds, 10)}",
        "-o", "IdentitiesOnly=yes",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PasswordAuthentication=no",
        "-o", "PreferredAuthentications=publickey",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "LogLevel=ERROR",
        remote,
        command,
    ]


def run_ssh(alias, command, attempts=None, fail_on_error=True):
    attempts = attempts or args.ssh_retries
    last = None
    hard_timeout = max(args.timeout_seconds + 8, 10)
    for attempt in range(1, attempts + 1):
        try:
            proc = subprocess.run(ssh_args(alias, command), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=hard_timeout)
        except subprocess.TimeoutExpired as exc:
            output = exc.stdout or ""
            if isinstance(output, bytes):
                output = output.decode(errors="replace")
            proc = subprocess.CompletedProcess([], 124, stdout=(output.strip() + f"\nssh command timed out for {alias} after {hard_timeout}s").strip())
        last = proc
        text = proc.stdout or ""
        transport = proc.returncode in (124, 255) and any(x in text for x in ["timed out", "banner exchange", "Connection closed", "Connection reset", "Connection timed out"])
        if proc.returncode == 0 or not transport or attempt == attempts:
            break
        print(f"[WARN] SSH transport timeout on {alias}; retrying {attempt}/{attempts}...", flush=True)
        time.sleep(2)
    if fail_on_error and last.returncode != 0:
        fail(f"SSH command failed on {alias}: {(last.stdout or '').strip()}")
    return last


def run_ssh_text(alias, command):
    return run_ssh(alias, command, fail_on_error=True).stdout or ""


def test_remote_command(alias, command):
    proc = run_ssh(alias, command, attempts=args.preflight_retries, fail_on_error=False)
    text = proc.stdout or ""
    transport = proc.returncode in (124, 255) and any(x in text for x in ["timed out", "banner exchange", "Connection closed", "Connection reset", "Connection timed out"])
    return {"ok": proc.returncode == 0, "exit_code": proc.returncode, "output": text, "transport_error": transport}


def b64_text(text):
    return base64.b64encode(str(text).encode()).decode()


def remote_python_command(script, *script_args):
    payload = b64_text(script)
    wrapper = "import base64,sys; code=base64.b64decode(sys.argv[1]); sys.argv=[sys.argv[0]]+sys.argv[2:]; exec(code)"
    return "python3 -c " + shlex.quote(wrapper) + " " + shlex.quote(payload) + "".join(" " + shlex.quote(str(x)) for x in script_args)


def resolve_target_ips(target, ingress_alias):
    if target.get("type") == "ip":
        return [target.get("value")]
    host = target.get("value")
    found = set()
    try:
        for info in socket.getaddrinfo(host, None, family=socket.AF_INET, type=socket.SOCK_STREAM):
            found.add(info[4][0])
    except Exception as exc:
        print(f"[WARN] local orchestration DNS resolve failed for {host}: {exc}", flush=True)
    py = r'''
import socket, sys, time
host=sys.argv[1]
attempts=int(sys.argv[2])
ips=set()
for _ in range(attempts):
    try:
        ips.update(info[4][0] for info in socket.getaddrinfo(host, None, family=socket.AF_INET, type=socket.SOCK_STREAM))
    except Exception:
        pass
    time.sleep(0.2)
print("\n".join(sorted(ips)))
'''
    output = run_ssh_text(ingress_alias, remote_python_command(py, host, 12))
    for line in output.splitlines():
        line = line.strip()
        if valid_ipv4(line):
            found.add(line)
    ips = sorted(found)
    if not ips:
        fail(f"Failed to resolve target {host} from orchestration/ingress alias {ingress_alias}")
    return ips


def stable_route_ids(proposal_id, target_ip, protocol, port):
    digest = hashlib.sha256(f"{proposal_id}|{target_ip}|{protocol}|{port}".encode()).digest()
    value = struct.unpack("<I", digest[:4])[0]
    return {"mark": f"0x{1048576 + (value % 15728639):x}", "table": 0, "priority": 0}


def route_protocol(protocol):
    return "tcp" if protocol in ("http", "https") else protocol


def iptables_match(step):
    proto = route_protocol(step["protocol"])
    if proto in ("tcp", "udp"):
        return f"-p {proto} -d {step['target_ip']}/32 --dport {int(step['port'])}"
    if proto == "icmp":
        return f"-p icmp -d {step['target_ip']}/32"
    fail(f"Unsupported route protocol for apply: {step['protocol']}")


def assert_current_cascade_egress(proposal, label):
    path = proposal.get("recommended_path") or {}
    if path.get("mode") != "cascade":
        fail(f"{label} is not a cascade fallback proposal")
    ingress = path.get("ingress_alias")
    egress = path.get("egress_alias")
    if ingress in ORCHESTRATION_ALIASES or egress in ORCHESTRATION_ALIASES:
        fail(f"{label} targets orchestration alias as managed node: {ingress}->{egress}. Operator/orchestration nodes are transport-only for egress apply.")
    if CASCADE_TOPOLOGY:
        topology_name, edges = CASCADE_TOPOLOGY
        hops = path.get("cascade_path") or [{"ingress_alias": ingress, "egress_alias": egress}]
        for hop in hops:
            edge = f"{hop.get('ingress_alias')}>{hop.get('egress_alias')}"
            if edge not in edges:
                fail(f"stale selective fallback proposal: {edge} is not active in cascade_topology {topology_name}")
    else:
        matched = any(link.get("ingress_alias") == ingress and link.get("egress_alias") == egress and (not path.get("cascade_connection") or link.get("connection_name") == path.get("cascade_connection")) for link in ACTIVE_CASCADE_LINKS)
        if not matched:
            fail(f"{label} points to stale cascade path {ingress}->{egress}: no active link in {args.cascade_config_file}")
    if ingress not in ACTIVE_CASCADE_ALIASES or egress not in ACTIVE_CASCADE_ALIASES:
        fail(f"{label} points to inactive cascade alias: {ingress}->{egress}")
    if egress not in nodes or egress not in networks:
        fail(f"{label} points to unknown egress alias: {egress}")


def proposal_files():
    selected = {x for x in args.id if x}
    if not os.path.isdir(args.proposal_dir):
        return []
    result = []
    for name in sorted(os.listdir(args.proposal_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(args.proposal_dir, name)
        proposal = read_json(path, "proposal")
        if selected and proposal.get("id") not in selected:
            continue
        if PROFILE_FILTER and proposal.get("profile") not in PROFILE_FILTER:
            continue
        if proposal.get("status") != "accepted" or proposal.get("type") != "fallback_available":
            continue
        recommended_path = proposal.get("recommended_path") or {}
        if recommended_path.get("mode") != "cascade":
            continue
        if INGRESS_ALIAS_FILTER and recommended_path.get("ingress_alias") not in INGRESS_ALIAS_FILTER:
            continue
        if EGRESS_ALIAS_FILTER and recommended_path.get("egress_alias") not in EGRESS_ALIAS_FILTER:
            continue
        result.append({"proposal": proposal, "path": path})
    return result


def new_step(proposal, target_ip):
    path = proposal.get("recommended_path") or {}
    ingress = path.get("ingress_alias")
    egress = path.get("egress_alias")
    if ingress not in networks:
        fail(f"networks.csv has no row for ingress alias: {ingress}")
    if egress not in networks:
        fail(f"networks.csv has no row for egress alias: {egress}")
    target = proposal.get("target") or {}
    ids = stable_route_ids(proposal["id"], target_ip, target.get("protocol"), target.get("port"))
    return {
        "id": proposal["id"],
        "profile": proposal.get("profile"),
        "target_type": target.get("type"),
        "target": target.get("value"),
        "path": target.get("path") or "/",
        "target_ip": target_ip,
        "protocol": target.get("protocol"),
        "port": int(target.get("port")),
        "ingress_alias": ingress,
        "egress_alias": egress,
        "ingress_gateway_ip": networks[ingress]["policy_gateway_ip"],
        "ingress_cascade_ip": networks[ingress]["cascade_ip"],
        "ingress_edge_ip": networks[ingress]["edge_ip"],
        "edge_source_ip": args.edge_source_ip,
        "ingress_policy_subnet": networks[ingress]["policy_subnet"],
        "egress_policy_subnet": networks[egress]["policy_subnet"],
        "ingress_router_ip": networks[ingress]["cascade_router_ip"],
        "egress_router_ip": networks[egress]["cascade_router_ip"],
        "tunnel_source_ip": networks[ingress]["policy_gateway_ip"],
        "tunnel_destination_ip": networks[egress]["cascade_router_ip"],
        "mode": ROUTE_MODE,
        "iptables_comment": f"ai-sp:{proposal['id']}:{target_ip}",
        "ingress_nat_comment": f"ai-sp:{proposal['id']}:{target_ip}:ingress-snat",
        "egress_nat_comment": f"ai-sp:{proposal['id']}:{target_ip}:egress-masq",
        "route_mark": ids["mark"],
        "route_table": ids["table"],
        "route_priority": ids["priority"],
    }


def assert_step_valid(step, label):
    required = ["id", "target", "target_ip", "protocol", "ingress_alias", "egress_alias", "ingress_gateway_ip", "ingress_cascade_ip", "ingress_edge_ip", "edge_source_ip", "ingress_policy_subnet", "egress_policy_subnet", "ingress_router_ip", "egress_router_ip", "tunnel_source_ip", "tunnel_destination_ip", "iptables_comment", "ingress_nat_comment", "egress_nat_comment"]
    for field in required:
        if not str(step.get(field) or "").strip():
            fail(f"{label} is missing required field: {field}")
    if step.get("ingress_alias") in ORCHESTRATION_ALIASES or step.get("egress_alias") in ORCHESTRATION_ALIASES:
        fail(f"{label} uses orchestration alias as managed node: {step.get('ingress_alias')}->{step.get('egress_alias')}")
    for field in ["target_ip", "ingress_gateway_ip", "ingress_cascade_ip", "ingress_edge_ip", "edge_source_ip", "ingress_router_ip", "egress_router_ip", "tunnel_source_ip", "tunnel_destination_ip"]:
        if not valid_ipv4(step.get(field)):
            fail(f"{label} has invalid IPv4 field {field}: {step.get(field)}")
    for field in ["ingress_policy_subnet", "egress_policy_subnet"]:
        if not valid_cidr(step.get(field)):
            fail(f"{label} has invalid CIDR field {field}: {step.get(field)}")


def step_display(step):
    keys = ["id", "profile", "target", "target_ip", "protocol", "port", "ingress_alias", "egress_alias", "ingress_gateway_ip", "ingress_cascade_ip", "egress_router_ip", "ingress_policy_subnet", "edge_source_ip"]
    return {k: step.get(k) for k in keys}


def print_steps(steps):
    if args.json_output:
        print(json.dumps([step_display(s) for s in steps], ensure_ascii=False, indent=2))
    else:
        for step in steps:
            print(json.dumps(step_display(step), ensure_ascii=False, sort_keys=True))


def applied_route_states():
    selected = {x for x in args.id if x}
    if not os.path.isdir(args.applied_routes_dir):
        return []
    result = []
    for name in sorted(os.listdir(args.applied_routes_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(args.applied_routes_dir, name)
        state = read_json(path, "applied route state")
        if selected and state.get("proposal_id") not in selected:
            continue
        steps = state.get("steps", [])
        if PROFILE_FILTER and not any(step.get("profile") in PROFILE_FILTER for step in steps):
            continue
        if INGRESS_ALIAS_FILTER and not any(step.get("ingress_alias") in INGRESS_ALIAS_FILTER for step in steps):
            continue
        if EGRESS_ALIAS_FILTER and not any(step.get("egress_alias") in EGRESS_ALIAS_FILTER for step in steps):
            continue
        result.append({"state": state, "path": path})
    return result


def applied_route_steps(states):
    steps = []
    for item in states:
        for step in item["state"].get("steps", []):
            steps.append(step)
    return steps


def write_applied_route_states(steps):
    grouped = defaultdict(list)
    for step in steps:
        grouped[step["id"]].append(step)
    for proposal_id, group in grouped.items():
        path = os.path.join(args.applied_routes_dir, proposal_id + ".json")
        state = {
            "schema_version": 4,
            "mode": ROUTE_MODE,
            "proposal_id": proposal_id,
            "applied_at_utc": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "steps": group,
        }
        write_json_atomic(path, state)
        print(f"[OK] applied route state written: {path}", flush=True)


def docker_exec(container, command):
    return "sudo docker exec -u 0 " + shlex.quote(container) + " sh -c " + shlex.quote(command)


def assert_apply_prerequisites(step):
    checks = [
        (step["ingress_alias"], EDGE_CONTAINER, "ingress edge"),
        (step["ingress_alias"], POLICY_GATEWAY_CONTAINER, "ingress policy gateway"),
        (step["ingress_alias"], CASCADE_CONTAINER, "ingress cascade"),
        (step["egress_alias"], CASCADE_CONTAINER, "egress cascade"),
    ]
    for alias, container, label in checks:
        result = test_remote_command(alias, "sudo docker inspect " + shlex.quote(container) + " >/dev/null 2>&1")
        if not result["ok"]:
            if result["transport_error"]:
                fail(f"SSH transport failed during preflight for {step['id']} -> {step['target_ip']}: {label} '{container}' on {alias}. Output: {result['output']}")
            fail(f"Required container missing for {step['id']} -> {step['target_ip']}: {label} '{container}' on {alias}.")


def invoke_step_apply(step):
    match = iptables_match(step)
    ingress_comment = step["ingress_nat_comment"]
    egress_comment = step["egress_nat_comment"]
    run_ssh_text(step["ingress_alias"], "set -euo pipefail; " + docker_exec(EDGE_CONTAINER, f"ip route replace {step['target_ip']}/32 via {step['ingress_gateway_ip']}"))
    ingress_gateway = (
        "sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true; "
        f"ip route replace {step['edge_source_ip']}/32 via {step['ingress_edge_ip']}; "
        f"ip route replace {step['target_ip']}/32 via {step['ingress_cascade_ip']}; "
        f"iptables -t nat -C POSTROUTING -s {step['edge_source_ip']}/32 {match} -m comment --comment {shlex.quote(ingress_comment)} -j SNAT --to-source {step['tunnel_source_ip']} 2>/dev/null || "
        f"iptables -t nat -I POSTROUTING 1 -s {step['edge_source_ip']}/32 {match} -m comment --comment {shlex.quote(ingress_comment)} -j SNAT --to-source {step['tunnel_source_ip']}"
    )
    run_ssh_text(step["ingress_alias"], "set -euo pipefail; " + docker_exec(POLICY_GATEWAY_CONTAINER, ingress_gateway))
    run_ssh_text(step["ingress_alias"], "set -euo pipefail; " + docker_exec(CASCADE_CONTAINER, f"ip route replace {step['target_ip']}/32 via {step['egress_router_ip']} dev {TAP_INTERFACE}"))
    egress = (
        f"ip route replace {step['ingress_policy_subnet']} via {step['ingress_router_ip']} dev {TAP_INTERFACE}; "
        f"iptables -t nat -C POSTROUTING {match} -m comment --comment {shlex.quote(egress_comment)} -j MASQUERADE 2>/dev/null || "
        f"iptables -t nat -I POSTROUTING 1 {match} -m comment --comment {shlex.quote(egress_comment)} -j MASQUERADE"
    )
    run_ssh_text(step["egress_alias"], "set -euo pipefail; " + docker_exec(CASCADE_CONTAINER, egress))


def invoke_step_rollback(step):
    match = iptables_match(step)
    run_ssh_text(step["ingress_alias"], "sudo docker exec -u 0 " + shlex.quote(EDGE_CONTAINER) + " ip route del " + shlex.quote(step["target_ip"] + "/32") + " 2>/dev/null || true")
    ingress = (
        f"ip route del {step['target_ip']}/32 2>/dev/null || true; "
        f"iptables -t nat -D POSTROUTING -s {step['edge_source_ip']}/32 {match} -m comment --comment {shlex.quote(step['ingress_nat_comment'])} -j SNAT --to-source {step['tunnel_source_ip']} 2>/dev/null || true"
    )
    run_ssh_text(step["ingress_alias"], docker_exec(POLICY_GATEWAY_CONTAINER, ingress) + " 2>/dev/null || true")
    run_ssh_text(step["ingress_alias"], docker_exec(CASCADE_CONTAINER, f"ip route del {step['target_ip']}/32 2>/dev/null || true") + " 2>/dev/null || true")
    if step["egress_alias"] in nodes:
        egress = (
            f"iptables -t nat -D POSTROUTING {match} -m comment --comment {shlex.quote(step['egress_nat_comment'])} -j MASQUERADE 2>/dev/null || true; "
            f"iptables -t nat -D POSTROUTING {match} -m comment --comment {shlex.quote(step['iptables_comment'])} -j MASQUERADE 2>/dev/null || true"
        )
        run_ssh_text(step["egress_alias"], docker_exec(CASCADE_CONTAINER, egress) + " 2>/dev/null || true")
    else:
        print(f"[WARN] skipping egress cleanup for retired alias {step['egress_alias']}", flush=True)


def nat_packet_count(text, comment):
    for line in text.splitlines():
        if comment in line:
            parts = line.split()
            if len(parts) >= 2 and parts[0].isdigit():
                return int(parts[0])
    return 0


def get_counters(step):
    ingress = run_ssh_text(step["ingress_alias"], "sudo docker exec -u 0 " + shlex.quote(POLICY_GATEWAY_CONTAINER) + " iptables -t nat -L POSTROUTING -v -n -x 2>/dev/null || true")
    egress = run_ssh_text(step["egress_alias"], "sudo docker exec -u 0 " + shlex.quote(CASCADE_CONTAINER) + " iptables -t nat -L POSTROUTING -v -n -x 2>/dev/null || true")
    return {
        "ingress_nat_packets": nat_packet_count(ingress, step["ingress_nat_comment"]),
        "egress_nat_packets": nat_packet_count(egress, step["egress_nat_comment"]),
    }


TRAFFIC_PY = r'''
import base64, json, socket, ssl, subprocess, sys, time
payload = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
host = payload["host"]
target_ip = payload["target_ip"]
protocol = payload["protocol"]
port = int(payload["port"])
path = payload.get("path") or "/"
timeout = float(payload["timeout"])
result = {"ok": False, "protocol": protocol, "http_status": None, "target_status": None, "first_line": None, "elapsed_ms": None, "error": None}
start = time.monotonic()
try:
    if protocol in ("http", "https"):
        sock = socket.create_connection((target_ip, port), timeout=timeout)
        if protocol == "https":
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
        request = f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: ai-service-platform-selective-fallback-verify/1\r\nConnection: close\r\n\r\n"
        sock.sendall(request.encode("ascii", "ignore"))
        data = b""
        while b"\r\n" not in data and len(data) < 4096:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        sock.close()
        first = data.split(b"\r\n", 1)[0].decode("iso-8859-1", "replace")
        result["first_line"] = first
        parts = first.split()
        if len(parts) >= 2 and parts[0].startswith("HTTP/"):
            result["http_status"] = int(parts[1])
            if 200 <= result["http_status"] < 400:
                result["ok"] = True
                result["target_status"] = "observed"
            elif 400 <= result["http_status"] < 500:
                result["ok"] = True
                result["target_status"] = "target_rejected"
            else:
                result["target_status"] = "target_error"
        else:
            result["error"] = "response did not start with HTTP status line"
    elif protocol == "tcp":
        sock = socket.create_connection((target_ip, port), timeout=timeout)
        sock.close()
        result["ok"] = True
    elif protocol == "icmp":
        proc = subprocess.run(["ping", "-c", "1", "-W", str(max(1, int(timeout))), target_ip], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout + 1)
        result["ok"] = proc.returncode == 0
        if proc.returncode != 0:
            result["error"] = ((proc.stdout or "") + "\n" + (proc.stderr or "")).strip() or f"ping exited {proc.returncode}"
    else:
        result["error"] = f"unsupported protocol: {protocol}"
except Exception as exc:
    result["error"] = str(exc)
finally:
    result["elapsed_ms"] = round((time.monotonic() - start) * 1000, 2)
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
'''


def traffic_check(step):
    if step["protocol"] == "udp":
        return {"ok": True, "skipped": True, "reason": "generic UDP verification is route-only without protocol-specific probe"}
    payload = {
        "host": step["target"],
        "target_ip": step["target_ip"],
        "protocol": step["protocol"],
        "port": step["port"],
        "path": step.get("path") or "/",
        "timeout": args.timeout_seconds,
    }
    payload_b64 = b64_text(json.dumps(payload, separators=(",", ":")))
    py_b64 = b64_text(TRAFFIC_PY)
    remote = (
        "set -euo pipefail; "
        f"pid=$(sudo docker inspect -f '{{{{.State.Pid}}}}' {shlex.quote(EDGE_CONTAINER)}); "
        f"printf %s {shlex.quote(py_b64)} | base64 -d | sudo nsenter -t \"$pid\" -n python3 - {shlex.quote(payload_b64)}"
    )
    output = run_ssh_text(step["ingress_alias"], remote)
    try:
        return json.loads(output)
    except Exception:
        return {"ok": False, "error": f"traffic verification returned non-JSON output: {output}"}


def test_step_applied(step):
    target = step["target_ip"]
    edge_routes = run_ssh_text(step["ingress_alias"], "sudo docker exec -u 0 " + shlex.quote(EDGE_CONTAINER) + " ip route 2>/dev/null || true")
    gateway_routes = run_ssh_text(step["ingress_alias"], "sudo docker exec -u 0 " + shlex.quote(POLICY_GATEWAY_CONTAINER) + " ip route 2>/dev/null || true")
    ingress_cascade_routes = run_ssh_text(step["ingress_alias"], "sudo docker exec -u 0 " + shlex.quote(CASCADE_CONTAINER) + " ip route 2>/dev/null || true")
    egress_cascade_routes = run_ssh_text(step["egress_alias"], "sudo docker exec -u 0 " + shlex.quote(CASCADE_CONTAINER) + " ip route 2>/dev/null || true")
    ingress_nat = run_ssh_text(step["ingress_alias"], "sudo docker exec -u 0 " + shlex.quote(POLICY_GATEWAY_CONTAINER) + " iptables -t nat -S POSTROUTING 2>/dev/null || true")
    egress_nat = run_ssh_text(step["egress_alias"], "sudo docker exec -u 0 " + shlex.quote(CASCADE_CONTAINER) + " iptables -t nat -S POSTROUTING 2>/dev/null || true")
    if args.traffic_probe:
        before = get_counters(step)
        traffic = traffic_check(step)
        after = get_counters(step)
    else:
        before = {"ingress_nat_packets": None, "egress_nat_packets": None}
        traffic = {"ok": True, "skipped": True, "reason": "traffic probe skipped; pass -TrafficProbe for dataplane target check"}
        after = {"ingress_nat_packets": None, "egress_nat_packets": None}
    result = {
        "id": step["id"],
        "target_ip": target,
        "edge_route": target in edge_routes and step["ingress_gateway_ip"] in edge_routes,
        "ingress_gateway_route": target in gateway_routes and step["ingress_cascade_ip"] in gateway_routes,
        "ingress_cascade_route": target in ingress_cascade_routes and step["egress_router_ip"] in ingress_cascade_routes,
        "egress_return_route": step["ingress_policy_subnet"] in egress_cascade_routes and step["ingress_router_ip"] in egress_cascade_routes,
        "ingress_nat": step["ingress_nat_comment"] in ingress_nat,
        "egress_nat": step["egress_nat_comment"] in egress_nat,
        "traffic": traffic,
        "ingress_nat_packets_before": before["ingress_nat_packets"],
        "ingress_nat_packets_after": after["ingress_nat_packets"],
        "egress_nat_packets_before": before["egress_nat_packets"],
        "egress_nat_packets_after": after["egress_nat_packets"],
    }
    result["ok"] = all(result[k] for k in ["edge_route", "ingress_gateway_route", "ingress_cascade_route", "egress_return_route", "ingress_nat", "egress_nat"]) and bool(traffic.get("ok"))
    return result


def traffic_summary(traffic):
    if not traffic:
        return "traffic=UNKNOWN"
    parts = ["traffic=OK" if traffic.get("ok") else "traffic=FAIL"]
    if traffic.get("skipped"):
        parts.append("skipped=true")
        if traffic.get("reason"):
            parts.append("reason=" + json.dumps(traffic["reason"], ensure_ascii=False))
        return " ".join(parts)
    if traffic.get("http_status") is not None:
        parts.append(f"http={traffic['http_status']}")
    if traffic.get("target_status"):
        parts.append(f"target={traffic['target_status']}")
    if traffic.get("elapsed_ms") is not None:
        parts.append(f"elapsed_ms={traffic['elapsed_ms']}")
    if traffic.get("error"):
        parts.append("error=" + json.dumps(traffic["error"], ensure_ascii=False))
    return " ".join(parts)


def write_verify_summary(result):
    status = "[OK]" if result["ok"] else "[FAIL]"
    parts = [
        f"{status} verified selective fallback route {result['id']} -> {result['target_ip']}",
        traffic_summary(result["traffic"]),
    ]
    if result["ingress_nat_packets_before"] is not None:
        parts.append(f"ingress_nat={result['ingress_nat_packets_before']}->{result['ingress_nat_packets_after']}")
    if result["egress_nat_packets_before"] is not None:
        parts.append(f"egress_nat={result['egress_nat_packets_before']}->{result['egress_nat_packets_after']}")
    print(" ".join(parts), flush=True)


def test_step_absent(step):
    target = step["target_ip"]
    edge_routes = run_ssh_text(step["ingress_alias"], "sudo docker exec -u 0 " + shlex.quote(EDGE_CONTAINER) + " ip route 2>/dev/null || true")
    gateway_routes = run_ssh_text(step["ingress_alias"], "sudo docker exec -u 0 " + shlex.quote(POLICY_GATEWAY_CONTAINER) + " ip route 2>/dev/null || true")
    ingress_cascade_routes = run_ssh_text(step["ingress_alias"], "sudo docker exec -u 0 " + shlex.quote(CASCADE_CONTAINER) + " ip route 2>/dev/null || true")
    ingress_nat = run_ssh_text(step["ingress_alias"], "sudo docker exec -u 0 " + shlex.quote(POLICY_GATEWAY_CONTAINER) + " iptables -t nat -S POSTROUTING 2>/dev/null || true")
    egress_nat = ""
    if step["egress_alias"] in nodes:
        egress_nat = run_ssh_text(step["egress_alias"], "sudo docker exec -u 0 " + shlex.quote(CASCADE_CONTAINER) + " iptables -t nat -S POSTROUTING 2>/dev/null || true")
    ok = target not in edge_routes and target not in gateway_routes and target not in ingress_cascade_routes and step["ingress_nat_comment"] not in ingress_nat and step["egress_nat_comment"] not in egress_nat
    return {"ok": ok, "id": step["id"], "target_ip": target}


def make_steps_from_proposals():
    proposals = proposal_files()
    if not proposals:
        print("No accepted fallback_available proposals selected.")
        return []
    explicit_ips = [x for x in args.target_ip if x]
    for ip in explicit_ips:
        if not valid_ipv4(ip):
            fail(f"Invalid explicit target IP: {ip}")
    steps = []
    for item in proposals:
        if args.action in ("apply", "refresh"):
            assert_current_cascade_egress(item["proposal"], f"proposal {item['proposal'].get('id')}")
        ingress = item["proposal"]["recommended_path"]["ingress_alias"]
        candidate_ips = explicit_ips or resolve_target_ips(item["proposal"].get("target") or {}, ingress)
        for ip in candidate_ips:
            steps.append(new_step(item["proposal"], ip))
    for step in steps:
        assert_step_valid(step, f"planned route step {step['id']} -> {step['target_ip']}")
    return steps


def verify_applied(steps):
    results = []
    for step in steps:
        result = test_step_applied(step)
        results.append(result)
        if not args.json_output:
            write_verify_summary(result)
    if args.json_output:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    if any(not r["ok"] for r in results):
        fail("selective fallback verification failed; inspect failed stages above and run rollback for the affected proposal")


def counter_snapshot(steps):
    results = []
    for step in steps:
        c = get_counters(step)
        row = {"id": step["id"], "target_ip": step["target_ip"], **c}
        results.append(row)
        if not args.json_output:
            print(f"[COUNTERS] {step['id']} -> {step['target_ip']} ingress_nat={c['ingress_nat_packets']} egress_nat={c['egress_nat_packets']}", flush=True)
    if args.json_output:
        print(json.dumps(results, ensure_ascii=False, indent=2))


def verify_absent(steps):
    results = []
    for step in steps:
        result = test_step_absent(step)
        results.append(result)
        if result["ok"]:
            print(f"[OK] verified selective fallback route removed {step['id']} -> {step['target_ip']}", flush=True)
        else:
            print(f"[FAIL] selective fallback rollback verification failed for {step['id']} -> {step['target_ip']}", flush=True)
    if args.json_output:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    if any(not r["ok"] for r in results):
        fail("selective fallback rollback verification failed; exact route or NAT state is still present")


if args.action in ("verify", "rollback", "counters"):
    states = applied_route_states()
    if not states:
        print("No applied selective fallback route state selected.")
        raise SystemExit(0)
    steps = applied_route_steps(states)
    for step in steps:
        assert_step_valid(step, f"applied route state {step['id']} -> {step['target_ip']}")
    if args.action == "verify":
        if not args.json_output:
            print_steps(steps)
        verify_applied(steps)
        raise SystemExit(0)
    if args.action == "counters":
        counter_snapshot(steps)
        raise SystemExit(0)
    print_steps(steps)
    for step in steps:
        invoke_step_rollback(step)
        print(f"[OK] rolled back selective fallback route {step['id']} -> {step['target_ip']}", flush=True)
    verify_absent(steps)
    for item in states:
        os.unlink(item["path"])
        print(f"[OK] removed applied route state: {item['path']}", flush=True)
    raise SystemExit(0)


planned_steps = make_steps_from_proposals()
if not planned_steps:
    raise SystemExit(0)
print_steps(planned_steps)

if args.action == "plan":
    raise SystemExit(0)

if args.action == "cleanup":
    for step in planned_steps:
        invoke_step_rollback(step)
        print(f"[OK] cleaned selective fallback route candidate {step['id']} -> {step['target_ip']}", flush=True)
    if not args.skip_verify:
        verify_absent(planned_steps)
    raise SystemExit(0)

selected_ids = {step["id"] for step in planned_steps}
existing_states = [item for item in applied_route_states() if item["state"].get("proposal_id") in selected_ids]

if args.action == "apply" and existing_states:
    fail("applied route state already exists for selected proposal; use verify, rollback, cleanup, or refresh.")

old_steps = []
old_backups = []
if args.action == "refresh":
    if existing_states:
        old_steps = applied_route_steps(existing_states)
        for step in old_steps:
            assert_step_valid(step, f"applied route state {step['id']} -> {step['target_ip']}")
        old_backups = [{"path": item["path"], "state": item["state"]} for item in existing_states]
        print("[INFO] refreshing selective fallback route state; rolling back persisted step(s) first", flush=True)
        print_steps(old_steps)
        for step in old_steps:
            invoke_step_rollback(step)
            print(f"[OK] rolled back stale selective fallback route {step['id']} -> {step['target_ip']}", flush=True)
        if not args.skip_verify:
            verify_absent(old_steps)
    else:
        print("[INFO] no existing applied route state found; refresh will apply current planned step(s)", flush=True)

try:
    for step in planned_steps:
        assert_apply_prerequisites(step)
        invoke_step_apply(step)
        print(f"[OK] applied selective fallback route {step['id']} -> {step['target_ip']}", flush=True)
except Exception:
    if args.action == "refresh":
        for backup in old_backups:
            if not os.path.exists(backup["path"]):
                write_json_atomic(backup["path"], backup["state"])
                print(f"[WARN] restored stale applied route state after refresh failure: {backup['path']}", flush=True)
    raise

write_applied_route_states(planned_steps)
if args.action == "refresh":
    new_by_id = defaultdict(set)
    for step in planned_steps:
        new_by_id[step["id"]].add(step["target_ip"])
    for backup in old_backups:
        if os.path.exists(backup["path"]):
            current = read_json(backup["path"], "applied route state")
            current_ips = {s.get("target_ip") for s in current.get("steps", [])}
            if current_ips != new_by_id.get(current.get("proposal_id"), set()):
                os.unlink(backup["path"])
                print(f"[OK] removed stale applied route state after successful refresh: {backup['path']}", flush=True)

if not args.skip_verify:
    verify_applied(planned_steps)
PY
