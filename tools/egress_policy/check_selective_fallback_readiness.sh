#!/usr/bin/env bash

set -euo pipefail

POLICY_FILE="./operator/egress_policy/profiles.json"
NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
NETWORKS_FILE="./operator/networks.csv"
OPERATOR_DIR="./operator"
OUTPUT_DIR="./operator/egress_policy/history"
CASCADE_SECRET_DIR="./operator/softether/cascade/secrets"
SSH_USER="useradmin"
PROFILE_NAMES=()
ALIASES=()
TIMEOUT_SECONDS=10
TARGET_TIMEOUT_SECONDS=10
DRY_RUN=false
JSON_OUTPUT=false

fail() {
    echo "[ERROR] $1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -PolicyFile|--policy-file) POLICY_FILE="${2:-}"; shift 2 ;;
        -NodesFile|--nodes-file) NODES_FILE="${2:-}"; shift 2 ;;
        -StateFile|--state-file) STATE_FILE="${2:-}"; shift 2 ;;
        -NetworksFile|--networks-file) NETWORKS_FILE="${2:-}"; shift 2 ;;
        -OperatorDir|--operator-dir) OPERATOR_DIR="${2:-}"; shift 2 ;;
        -OutputDir|--output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
        -CascadeSecretDir|--cascade-secret-dir) CASCADE_SECRET_DIR="${2:-}"; shift 2 ;;
        -SshUser|--ssh-user) SSH_USER="${2:-}"; shift 2 ;;
        -ProfileName|-Profile|--profile-name|--profile) PROFILE_NAMES+=("${2:-}"); shift 2 ;;
        -Alias|--alias) ALIASES+=("${2:-}"); shift 2 ;;
        -TimeoutSeconds|--timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
        -TargetTimeoutSeconds|--target-timeout-seconds) TARGET_TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
        -DryRun|--dry-run) DRY_RUN=true; shift ;;
        -Json|--json) JSON_OUTPUT=true; shift ;;
        -SshPath|--ssh-path|-AutoAcceptHostKey|--auto-accept-host-key)
            if [ "${2:-}" != "" ] && [[ "$1" == *Path ]]; then shift 2; else shift; fi
            ;;
        *) fail "Unsupported readiness argument: $1" ;;
    esac
done

[ -f "$POLICY_FILE" ] || fail "egress policy registry not found: $POLICY_FILE"
[ -f "$NODES_FILE" ] || fail "nodes.csv not found: $NODES_FILE"
[ -f "$STATE_FILE" ] || fail "state.csv not found: $STATE_FILE"
[ -f "$NETWORKS_FILE" ] || fail "networks.csv not found: $NETWORKS_FILE"
[ -d "$CASCADE_SECRET_DIR" ] || fail "cascade secret directory not found: $CASCADE_SECRET_DIR"
mkdir -p "$OUTPUT_DIR"

PROFILE_FILTER="$(IFS=,; printf '%s' "${PROFILE_NAMES[*]:-}")"
ALIAS_FILTER="$(IFS=,; printf '%s' "${ALIASES[*]:-}")"

python3 - "$POLICY_FILE" "$NODES_FILE" "$STATE_FILE" "$NETWORKS_FILE" "$OPERATOR_DIR" "$OUTPUT_DIR" "$CASCADE_SECRET_DIR" "$SSH_USER" "$PROFILE_FILTER" "$ALIAS_FILTER" "$TIMEOUT_SECONDS" "$TARGET_TIMEOUT_SECONDS" "$DRY_RUN" "$JSON_OUTPUT" <<'PY'
import base64, csv, datetime as dt, json, os, queue, re, socket, ssl, subprocess, sys, urllib.error, urllib.request

policy_file, nodes_file, state_file, networks_file, operator_dir, output_dir, cascade_secret_dir, ssh_user, profile_filter, alias_filter, timeout_s, target_timeout_s, dry_run_s, json_output_s = sys.argv[1:]
timeout = max(1, int(timeout_s))
target_timeout = max(1, int(target_timeout_s))
dry_run = dry_run_s.lower() == "true"
json_output = json_output_s.lower() == "true"
profile_names = {x for x in profile_filter.split(",") if x}
alias_names = {x for x in alias_filter.split(",") if x}
run_id = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")

def utc_now():
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def load_csv(path):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        return list(csv.DictReader(fh))

def load_json(path):
    with open(path, encoding="utf-8-sig") as fh:
        return json.load(fh)

def split_aliases(value):
    return [x for x in (value or "").split("+") if x]

def node_port(node):
    return str(node.get("ssh_port") or "22")

nodes = {r["current_alias"]: r for r in load_csv(nodes_file) if r.get("current_alias")}
states = load_csv(state_file)
networks = {r["alias"]: r for r in load_csv(networks_file) if r.get("alias")}
policy = load_json(policy_file)
cascade_doc = load_json(os.path.join(cascade_secret_dir, "lab-cascade.json"))

def ssh_text(alias, command):
    node = nodes.get(alias)
    if not node:
        return False, f"unknown node alias: {alias}"
    key = os.path.join(operator_dir, alias, "admin_key")
    if not os.path.isfile(key):
        return False, f"admin key not found: {key}"
    remote = f"{ssh_user}@{node['endpoint']}"
    args = ["ssh", "-n", "-T", "-p", node_port(node), "-i", key, "-o", "BatchMode=yes", "-o", f"ConnectTimeout={min(timeout, 10)}", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR", remote, command]
    proc = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return proc.returncode == 0, proc.stdout.strip()

def ssh_json(alias, command):
    ok, text = ssh_text(alias, command)
    if not ok:
        return False, text, None
    try:
        return True, None, json.loads(text)
    except Exception:
        return False, text, None

def state_expanded_aliases(kind, name, anchors):
    out = []
    rows = [r for r in states if r.get("kind") == kind and r.get("name") == name and r.get("state") == "present"]
    active = []
    candidates = []
    for row in rows:
        active += split_aliases(row.get("active_aliases"))
        candidates += split_aliases(row.get("candidate_aliases"))
    for anchor in anchors:
        if anchor in active or anchor in candidates:
            out.append(anchor)
    return sorted(set(out))

def fallback_egress_aliases(ingress_aliases):
    out = []
    for row in states:
        if row.get("kind") != "cascade_topology" or row.get("state") != "present":
            continue
        for edge in split_aliases(row.get("active_aliases")):
            if ">" not in edge:
                continue
            left, right = edge.split(">", 1)
            if left in ingress_aliases:
                out.append(right)
    return sorted(set(out))

def load_links():
    items = cascade_doc.get("links") if isinstance(cascade_doc, dict) and "links" in cascade_doc else [cascade_doc]
    links = []
    for link in items or []:
        state = link.get("state", "active")
        if state == "disabled":
            continue
        for field in ("connection_name", "ingress_alias", "egress_alias", "egress_host", "egress_port"):
            if not link.get(field):
                raise SystemExit(f"[ERROR] cascade secret missing field: {field}")
        if link["ingress_alias"] not in nodes or link["egress_alias"] not in nodes:
            continue
        links.append(link)
    return links

links = load_links()

def find_path(start, goal):
    q = queue.Queue()
    q.put((start, []))
    seen = {start}
    while not q.empty():
        alias, path = q.get()
        for link in [x for x in links if x["ingress_alias"] == alias]:
            nxt = link["egress_alias"]
            if nxt in seen:
                continue
            new_path = path + [link]
            if nxt == goal:
                return new_path
            seen.add(nxt)
            q.put((nxt, new_path))
    return []

def parse_flags(text):
    flags = {}
    for line in (text or "").splitlines():
        if "=" in line:
            k, v = line.strip().split("=", 1)
            if v in ("true", "false"):
                flags[k] = (v == "true")
    return flags

def shell_script_command(script):
    payload = base64.b64encode(script.encode()).decode()
    return "printf %s " + json.dumps(payload) + " | base64 -d | sh"

def policy_network(alias):
    net = networks.get(alias)
    if not net:
        raise SystemExit(f"[ERROR] networks.csv has no row for alias: {alias}")
    ok, text = ssh_text(alias, "sudo docker network inspect ai_service_vpn_policy --format '{{json .Containers}}'")
    return {
        "ok": ok,
        "edge_attached": ok and "softether-edge" in text and net["edge_ip"] in text,
        "gateway_attached": ok and "policy-gateway" in text and net["policy_gateway_ip"] in text,
        "cascade_attached": ok and "softether-cascade" in text and net["cascade_ip"] in text,
        "expected_edge_ip": net["edge_ip"],
        "expected_gateway_ip": net["policy_gateway_ip"],
        "expected_cascade_ip": net["cascade_ip"],
        "error": None if ok else text,
    }

def policy_gateway(alias):
    net = networks.get(alias)
    expected = net["policy_gateway_ip"]
    script = f'''set +e
container_present=false
gateway_ip_present=false
ip_forward=false
route_table_available=false
nat_available=false
pid=$(sudo docker inspect -f '{{{{.State.Pid}}}}' policy-gateway 2>/dev/null)
[ -n "$pid" ] && container_present=true
sudo docker exec -u 0 policy-gateway sh -c 'ip addr 2>/dev/null | grep -q "{expected}/"' && gateway_ip_present=true
sudo docker exec -u 0 policy-gateway sh -c 'test "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = 1' && ip_forward=true
sudo docker exec -u 0 policy-gateway sh -c 'ip route >/dev/null 2>&1' && route_table_available=true
sudo docker exec -u 0 policy-gateway sh -c 'iptables -t nat -S POSTROUTING >/dev/null 2>&1 && iptables -t nat -L POSTROUTING -v -n -x >/dev/null 2>&1' && nat_available=true
printf 'container_present=%s\\ngateway_ip_present=%s\\nip_forward=%s\\nroute_table_available=%s\\nnat_available=%s\\n' "$container_present" "$gateway_ip_present" "$ip_forward" "$route_table_available" "$nat_available"
[ "$container_present" = true ] && [ "$gateway_ip_present" = true ] && [ "$route_table_available" = true ] && [ "$nat_available" = true ]
'''
    ok, text = ssh_text(alias, shell_script_command(script))
    f = parse_flags(text)
    return {"ok": ok, "container_present": f.get("container_present", False), "gateway_ip_present": f.get("gateway_ip_present", False), "ip_forward": f.get("ip_forward", False), "route_table_available": f.get("route_table_available", False), "nat_available": f.get("nat_available", False), "container": "policy-gateway", "expected_gateway_ip": expected, "error": None if ok else text}

def cascade_dataplane(alias):
    net = networks.get(alias)
    expected = net["cascade_router_ip"]
    script = f'''set +e
container_present=false
tap_present=false
router_ip_present=false
route_table_available=false
nat_available=false
pid=$(sudo docker inspect -f '{{{{.State.Pid}}}}' softether-cascade 2>/dev/null)
[ -n "$pid" ] && container_present=true
sudo docker exec -u 0 softether-cascade sh -c 'ip link show tap_vpnpolicy >/dev/null 2>&1' && tap_present=true
sudo docker exec -u 0 softether-cascade sh -c 'ip addr 2>/dev/null | grep -q "{expected}/"' && router_ip_present=true
sudo docker exec -u 0 softether-cascade sh -c 'ip route >/dev/null 2>&1' && route_table_available=true
sudo docker exec -u 0 softether-cascade sh -c 'iptables -t nat -S POSTROUTING >/dev/null 2>&1 && iptables -t nat -L POSTROUTING -v -n -x >/dev/null 2>&1' && nat_available=true
printf 'container_present=%s\\ntap_present=%s\\nrouter_ip_present=%s\\nroute_table_available=%s\\nnat_available=%s\\n' "$container_present" "$tap_present" "$router_ip_present" "$route_table_available" "$nat_available"
[ "$container_present" = true ] && [ "$tap_present" = true ] && [ "$router_ip_present" = true ] && [ "$route_table_available" = true ] && [ "$nat_available" = true ]
'''
    ok, text = ssh_text(alias, shell_script_command(script))
    f = parse_flags(text)
    return {"ok": ok, "container_present": f.get("container_present", False), "tap_present": f.get("tap_present", False), "router_ip_present": f.get("router_ip_present", False), "route_table_available": f.get("route_table_available", False), "nat_available": f.get("nat_available", False), "container": "softether-cascade", "interface": "tap_vpnpolicy", "expected_router_ip": expected, "error": None if ok else text}

def gateway_nat(alias):
    ok, text = ssh_text(alias, "sudo docker exec -u 0 policy-gateway sh -c 'iptables -t nat -S POSTROUTING >/dev/null && iptables -t nat -L POSTROUTING -v -n -x >/dev/null'")
    return {"ok": ok, "postrouting_available": ok, "counters_available": ok, "error": None if ok else text}

def cascade_tcp(link):
    py = "import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=float(sys.argv[3])).close()"
    cmd = "python3 -c " + json.dumps(py) + " " + json.dumps(str(link["egress_host"])) + " " + json.dumps(str(link["egress_port"])) + " " + json.dumps(str(timeout))
    ok, text = ssh_text(link["ingress_alias"], cmd)
    return {"reachable": ok, "error": None if ok else text}

target_probe_py = r'''
import base64,json,re,socket,ssl,subprocess,sys,time,urllib.error,urllib.request
target=json.loads(base64.b64decode(sys.argv[1]).decode("utf-8")); timeout=float(sys.argv[2])
host=target["value"]; port=int(target.get("port") or 0); protocol=target["protocol"]; path=target.get("path") or "/"
r={"http_status":None,"tcp_connect_ms":None,"http_total_ms":None,"icmp_ms":None,"errors":[]}
if protocol=="udp":
    r["errors"].append({"stage":"udp","message":"generic UDP readiness requires protocol-specific probe"}); print(json.dumps(r,separators=(",",":"))); raise SystemExit(0)
if protocol=="icmp":
    try:
        s=time.monotonic(); p=subprocess.run(["ping","-c","1","-W",str(max(1,int(timeout))),host],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout+1)
        out=(p.stdout or "")+"\n"+(p.stderr or ""); m=re.search(r"time[=<]([0-9.]+)\s*ms",out)
        if p.returncode==0: r["icmp_ms"]=round(float(m.group(1)),2) if m else round((time.monotonic()-s)*1000,2)
        else: r["errors"].append({"stage":"icmp","message":out.strip() or f"ping exited {p.returncode}"})
    except Exception as e: r["errors"].append({"stage":"icmp","message":str(e)})
    print(json.dumps(r,separators=(",",":"))); raise SystemExit(0)
try:
    s=time.monotonic(); sock=socket.create_connection((host,port),timeout=timeout); r["tcp_connect_ms"]=round((time.monotonic()-s)*1000,2)
    if protocol=="https": ssl.create_default_context().wrap_socket(sock,server_hostname=host).close()
    else: sock.close()
except Exception as e: r["errors"].append({"stage":"tcp_tls","message":str(e)})
if protocol in ("http","https"):
    url=f"{protocol}://{host}:{port}{path}" if (protocol,port) not in (("https",443),("http",80)) else f"{protocol}://{host}{path}"
    try:
        s=time.monotonic()
        with urllib.request.urlopen(urllib.request.Request(url,headers={"User-Agent":"ai-service-platform-fallback-readiness/1"}),timeout=timeout) as resp:
            r["http_status"]=resp.status; resp.read(1024); r["http_total_ms"]=round((time.monotonic()-s)*1000,2)
    except urllib.error.HTTPError as e: r["http_status"]=e.code
    except Exception as e: r["errors"].append({"stage":"http","message":str(e)})
print(json.dumps(r,separators=(",",":")))
'''

def target_from_egress(alias, target):
    payload = base64.b64encode(json.dumps({"type": target.get("type"), "value": target.get("value"), "protocol": target.get("protocol"), "port": int(target.get("port")), "path": target.get("path") or "/"}, separators=(",", ":")).encode()).decode()
    cmd = "python3 -c " + json.dumps("import base64,sys; exec(base64.b64decode(%r))" % base64.b64encode(target_probe_py.encode()).decode()) + " " + json.dumps(payload) + " " + json.dumps(str(target_timeout))
    ok, err, data = ssh_json(alias, cmd)
    return {"ok": ok, "error": err, "result": data}

def target_status_name(infra_ok, target, target_status):
    if not infra_ok:
        return "fallback_unavailable"
    if not target_status["ok"] or not target_status.get("result"):
        return "target_timeout"
    result = target_status["result"]
    proto = target.get("protocol")
    if proto in ("http", "https"):
        status = result.get("http_status")
        if status is not None and int(status) < 500:
            return "observed" if int(status) < 400 else "target_rejected"
        return "target_timeout"
    if proto == "tcp":
        return "observed" if result.get("tcp_connect_ms") is not None else "target_timeout"
    if proto == "icmp":
        return "observed" if result.get("icmp_ms") is not None else "target_timeout"
    return "route_review"

def target_display(t):
    return f"{t.get('protocol')}://{t.get('value')}:{t.get('port')}"

records = []
profiles = [p for p in policy.get("profiles", []) if p.get("state") == "probe" and (not profile_names or p.get("name") in profile_names)]
if not profiles:
    print("No enabled egress policy profiles selected.")
    raise SystemExit(0)

for profile in profiles:
    if profile.get("behavior") != "fallback_on_ingress_egress_failure":
        raise SystemExit(f"[ERROR] profile {profile.get('name')} behavior is not supported by readiness check: {profile.get('behavior')}")
    direct_probe_skipped = profile.get("direct_probe", True) is False
    anchors = profile.get("ingress_anchor_aliases") or []
    ingress_aliases = [x for x in state_expanded_aliases("edge_route", "vpn_ingress", anchors) if not alias_names or x in alias_names]
    egress_aliases = fallback_egress_aliases(ingress_aliases)
    if not egress_aliases:
        raise SystemExit(f"[ERROR] profile {profile.get('name')} must derive fallback egress aliases from state.csv cascade_topology")
    for target in profile.get("targets", []):
        for ingress in ingress_aliases:
            for egress in egress_aliases:
                path = find_path(ingress, egress)
                if not path:
                    print(f"No cascade path for readiness {profile.get('name')}: {ingress} -> {egress}")
                    continue
                if dry_run:
                    print(f"[dry-run] readiness {profile.get('name')}: {ingress} edge->policy-gateway -> {'->'.join(x['connection_name'] for x in path)} -> {target_display(target)}")
                    continue
                pn = policy_network(ingress)
                ig = policy_gateway(ingress)
                ic = cascade_dataplane(ingress)
                ec = cascade_dataplane(egress)
                inat = gateway_nat(ingress)
                enat = {"ok": ec["nat_available"], "postrouting_available": ec["nat_available"], "counters_available": ec["nat_available"], "error": ec["error"]}
                tcp_hops = [cascade_tcp(x) for x in path]
                tcp = {"reachable": all(x["reachable"] for x in tcp_hops), "hops": tcp_hops}
                ts = target_from_egress(egress, target)
                infra_ok = pn["edge_attached"] and pn["gateway_attached"] and pn["cascade_attached"] and ig["ok"] and ic["ok"] and ec["ok"] and inat["ok"] and enat["ok"] and tcp["reachable"]
                status = target_status_name(infra_ok, target, ts)
                rec = {
                    "schema_version": 1, "run_id": run_id, "observed_at_utc": utc_now(), "path_mode": "dataplane_readiness",
                    "profile": profile.get("name"), "behavior": profile.get("behavior"), "direct_probe_skipped": direct_probe_skipped, "ingress_alias": ingress, "egress_alias": egress,
                    "cascade_connection": "->".join(x["connection_name"] for x in path), "cascade_connections": [x["connection_name"] for x in path],
                    "cascade_path": [{"connection": x["connection_name"], "ingress_alias": x["ingress_alias"], "egress_alias": x["egress_alias"]} for x in path],
                    "target": target, "policy_network_status": pn, "ingress_gateway_status": ig, "ingress_cascade_status": ic,
                    "egress_cascade_status": ec, "ingress_nat_status": inat, "egress_nat_status": enat, "cascade_transport_status": tcp,
                    "target_status": ts["result"] if ts["ok"] else None, "status": status, "error": None if ts["ok"] else ts["error"],
                }
                records.append(rec)
                target_result = "OK" if status == "observed" else ("REJECTED" if status == "target_rejected" else "FAIL")
                print(f"[{profile.get('name')}] {ingress} -> {egress} via {rec['cascade_connection']} | target {target_display(target)} | infra={'OK' if infra_ok else 'FAIL'} target={target_result} status={status}")

if dry_run:
    print("Dry-run completed. No readiness records were written.")
    raise SystemExit(0)
if not records:
    print("No readiness records produced.")
    raise SystemExit(0)

out = os.path.join(output_dir, f"selective-fallback-readiness-{run_id}.jsonl")
with open(out, "w", encoding="utf-8") as fh:
    for rec in records:
        fh.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
if json_output:
    print(json.dumps(records, ensure_ascii=False))
else:
    print(f"[OK] Selective fallback readiness history written: {out}")
PY
