#!/usr/bin/env bash

set -euo pipefail

POLICY_FILE="./operator/egress_policy/profiles.json"
NODES_FILE="./operator/nodes.csv"
OPERATOR_DIR="./operator"
OUTPUT_DIR="./operator/egress_policy/history"
CASCADE_SECRET_DIR="./operator/softether/cascade/secrets"
SSH_USER="useradmin"
PROFILE_NAMES=()
ALIASES=()
INCLUDE_CASCADE=false
TIMEOUT_SECONDS=5
PROBE_ATTEMPTS=2
PROBE_RETRY_DELAY_SECONDS=2

fail() {
    echo "[ERROR] $1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -PolicyFile|--policy-file) POLICY_FILE="${2:-}"; shift 2 ;;
        -NodesFile|--nodes-file) NODES_FILE="${2:-}"; shift 2 ;;
        -OperatorDir|--operator-dir) OPERATOR_DIR="${2:-}"; shift 2 ;;
        -OutputDir|--output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
        -CascadeSecretDir|--cascade-secret-dir) CASCADE_SECRET_DIR="${2:-}"; shift 2 ;;
        -SshUser|--ssh-user) SSH_USER="${2:-}"; shift 2 ;;
        -Profile|-ProfileName|--profile|--profile-name) PROFILE_NAMES+=("${2:-}"); shift 2 ;;
        -Alias|--alias) ALIASES+=("${2:-}"); shift 2 ;;
        -IncludeCascade|--include-cascade) INCLUDE_CASCADE=true; shift ;;
        -TimeoutSeconds|--timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
        -ProbeAttempts|--probe-attempts) PROBE_ATTEMPTS="${2:-}"; shift 2 ;;
        -ProbeRetryDelaySeconds|--probe-retry-delay-seconds) PROBE_RETRY_DELAY_SECONDS="${2:-}"; shift 2 ;;
        -DryRun|--dry-run|-CascadeOnly|--cascade-only|-PreferCascade|--prefer-cascade|-AutoAcceptHostKey|--auto-accept-host-key)
            shift
            ;;
        *) fail "Unsupported probe argument: $1" ;;
    esac
done

[ -f "$POLICY_FILE" ] || fail "egress policy registry not found: $POLICY_FILE"
[ -f "$NODES_FILE" ] || fail "nodes.csv not found: $NODES_FILE"
mkdir -p "$OUTPUT_DIR"

PROFILE_FILTER="$(IFS=,; printf '%s' "${PROFILE_NAMES[*]:-}")"
ALIAS_FILTER="$(IFS=,; printf '%s' "${ALIASES[*]:-}")"

python3 - "$POLICY_FILE" "$NODES_FILE" "$OPERATOR_DIR" "$OUTPUT_DIR" "$CASCADE_SECRET_DIR" "$SSH_USER" "$PROFILE_FILTER" "$ALIAS_FILTER" "$INCLUDE_CASCADE" "$TIMEOUT_SECONDS" "$PROBE_ATTEMPTS" "$PROBE_RETRY_DELAY_SECONDS" <<'PY'
import base64, csv, datetime as dt, http.client, json, os, socket, ssl, subprocess, sys, time, urllib.request

policy_file, nodes_file, operator_dir, output_dir, cascade_secret_dir, ssh_user, profile_filter, alias_filter, include_cascade, timeout_s, attempts_s, retry_delay_s = sys.argv[1:]
include_cascade = include_cascade.lower() == "true"
timeout = max(1, int(timeout_s))
attempts = max(1, int(attempts_s))
retry_delay = max(0, int(retry_delay_s))
profile_names = {x for x in profile_filter.split(",") if x}
alias_names = {x for x in alias_filter.split(",") if x}
run_id = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
history_path = os.path.join(output_dir, f"egress-probes-{run_id}.jsonl")

def utc_now():
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def load_nodes(path):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        rows = list(csv.DictReader(fh))
    expected = ["current_alias", "endpoint", "connection", "ssh_port", "root_password"]
    if rows and list(rows[0].keys()) != expected:
        raise SystemExit(f"[ERROR] nodes.csv header must be exactly: {','.join(expected)}")
    return {row["current_alias"]: row for row in rows if row.get("current_alias")}

def load_json(path, default=None):
    if not os.path.exists(path):
        return default
    with open(path, encoding="utf-8-sig") as fh:
        return json.load(fh)

nodes = load_nodes(nodes_file)
policy = load_json(policy_file)
cascade = load_json(os.path.join(cascade_secret_dir, "lab-cascade.json"), {"links": []}) or {"links": []}

def run_ssh_command(args, alias):
    hard_timeout = max(timeout + 5, 5)
    try:
        return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=hard_timeout)
    except subprocess.TimeoutExpired as exc:
        output = (exc.stdout or "")
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        message = output.strip()
        suffix = f" after {hard_timeout}s"
        if message:
            message = f"{message}\nssh command timed out for {alias}{suffix}"
        else:
            message = f"ssh command timed out for {alias}{suffix}"
        return subprocess.CompletedProcess(args, 124, stdout=message)

def ssh_json(alias, command):
    node = nodes[alias]
    key = os.path.join(operator_dir, alias, "admin_key")
    if not os.path.isfile(key):
        return False, f"admin key not found: {key}", None
    port = str(node.get("ssh_port") or "22")
    remote = f"{ssh_user}@{node['endpoint']}"
    args = ["ssh", "-n", "-T", "-p", port, "-i", key, "-o", "BatchMode=yes", "-o", f"ConnectTimeout={min(timeout, 10)}", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR", remote, command]
    proc = run_ssh_command(args, alias)
    if proc.returncode != 0:
        return False, proc.stdout.strip(), None
    text = proc.stdout.strip()
    try:
        return True, None, json.loads(text)
    except Exception:
        return False, text, None

def ssh_text(alias, command):
    node = nodes[alias]
    key = os.path.join(operator_dir, alias, "admin_key")
    port = str(node.get("ssh_port") or "22")
    remote = f"{ssh_user}@{node['endpoint']}"
    args = ["ssh", "-n", "-T", "-p", port, "-i", key, "-o", "BatchMode=yes", "-o", f"ConnectTimeout={min(timeout, 10)}", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR", remote, command]
    proc = run_ssh_command(args, alias)
    return proc.returncode == 0, proc.returncode, proc.stdout

def remote_python_command(script, *args):
    payload = base64.b64encode(script.encode()).decode()
    wrapper = "import base64,sys; code=base64.b64decode(sys.argv[1]); sys.argv=[sys.argv[0]]+sys.argv[2:]; exec(code)"
    return "python3 -c " + json.dumps(wrapper) + " " + json.dumps(payload) + "".join(" " + json.dumps(str(arg)) for arg in args)

def target_label(target):
    return f"{target.get('protocol')}://{target.get('value')}:{target.get('port')}{target.get('path') or '/'}"

remote_probe_py = r'''
import json, socket, ssl, sys, time, urllib.error, urllib.request
target=json.loads(sys.argv[1]); timeout=float(sys.argv[2])
started=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
host=target["value"]; port=int(target["port"]); protocol=target.get("protocol","https"); path=target.get("path") or "/"
result={"started_at_utc":started,"target":target,"dns_addresses":[],"dns_ms":None,"tcp_connect_ms":None,"tls_handshake_ms":None,"http_status":None,"http_final_url":None,"http_first_byte_ms":None,"http_total_ms":None,"external_ip":None,"external_country":"","errors":[]}
t=time.monotonic()
try:
    infos=socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    result["dns_addresses"]=sorted({i[4][0] for i in infos})
    result["dns_ms"]=round((time.monotonic()-t)*1000,2)
except Exception as e:
    result["errors"].append({"stage":"dns","message":str(e)})
try:
    t=time.monotonic(); sock=socket.create_connection((host, port), timeout=timeout); result["tcp_connect_ms"]=round((time.monotonic()-t)*1000,2)
    if protocol=="https":
        t=time.monotonic(); sock=ssl.create_default_context().wrap_socket(sock, server_hostname=host); result["tls_handshake_ms"]=round((time.monotonic()-t)*1000,2)
    sock.close()
except Exception as e:
    result["errors"].append({"stage":"tcp_tls","message":str(e)})
if protocol in ("http","https"):
    url=f"{protocol}://{host}{path}" if (protocol,port) in (("https",443),("http",80)) else f"{protocol}://{host}:{port}{path}"
    try:
        req=urllib.request.Request(url, headers={"User-Agent":"ai-service-platform-egress-probe/1"})
        t=time.monotonic()
        with urllib.request.urlopen(req, timeout=timeout) as r:
            result["http_status"]=r.status; result["http_final_url"]=r.geturl(); r.read(1024); result["http_total_ms"]=round((time.monotonic()-t)*1000,2)
    except urllib.error.HTTPError as e:
        result["http_status"]=e.code; result["http_final_url"]=e.geturl()
    except Exception as e:
        result["errors"].append({"stage":"http","message":str(e)})
try:
    with urllib.request.urlopen("https://ifconfig.me/ip", timeout=min(timeout,5)) as r:
        result["external_ip"]=r.read(128).decode().strip()
except Exception:
    pass
print(json.dumps(result, sort_keys=True, separators=(",",":")))
'''

def probe_target(alias, target, path_label):
    payload = json.dumps(target, separators=(",", ":"))
    command = remote_python_command(remote_probe_py, payload, str(timeout))
    last = None
    retry_errors = []
    for attempt in range(1, attempts + 1):
        print(f"    attempt {attempt}/{attempts}: {path_label} via {alias} (hard timeout {timeout + 5}s)...", flush=True)
        ok, err, data = ssh_json(alias, command)
        last = (ok, err, data, attempt)
        should_retry = (not ok) or (data and target.get("protocol") in ("https", "http") and data.get("http_status") is None)
        if ok and data:
            status = data.get("http_status")
            tcp_ms = data.get("tcp_connect_ms")
            total_ms = data.get("http_total_ms")
            print(f"    attempt {attempt}/{attempts}: ok http_status={status} tcp_ms={tcp_ms} total_ms={total_ms}", flush=True)
        else:
            print(f"    attempt {attempt}/{attempts}: failed {err}", flush=True)
        if not should_retry or attempt == attempts:
            if should_retry:
                retry_errors.append({"attempt": attempt, "reason": "retry_exhausted", "error": err, "http_status": data.get("http_status") if data else None, "errors": data.get("errors") if data else None})
            break
        retry_errors.append({"attempt": attempt, "reason": "probe_error" if not ok else "empty_http_status", "error": err, "http_status": data.get("http_status") if data else None, "errors": data.get("errors") if data else None})
        if retry_delay:
            time.sleep(retry_delay)
    ok, err, data, used = last
    return ok, err, data, used, retry_errors

def cascade_links_for(alias):
    return [l for l in cascade.get("links", []) if l.get("state") == "active" and l.get("ingress_alias") == alias and l.get("egress_alias") in nodes]

def transport_status(link):
    py = 'import json,socket,sys,time\nh=sys.argv[1]; p=int(sys.argv[2]); t=float(sys.argv[3]); s=time.monotonic(); r={"host":h,"port":p,"reachable":False,"tcp_connect_ms":None,"error":None}\ntry:\n c=socket.create_connection((h,p),timeout=t); c.close(); r["reachable"]=True; r["tcp_connect_ms"]=round((time.monotonic()-s)*1000,2)\nexcept Exception as e: r["error"]=str(e)\nprint(json.dumps(r,separators=(",",":")))\n'
    command = remote_python_command(py, link["egress_host"], str(link["egress_port"]), str(timeout))
    print(f"    checking cascade transport {link['ingress_alias']}->{link['egress_alias']} {link['egress_host']}:{link['egress_port']}...", flush=True)
    ok, err, data = ssh_json(link["ingress_alias"], command)
    print(f"    cascade transport reachable={bool(ok and data and data.get('reachable'))} error={None if ok else err}", flush=True)
    return data if ok else {"host": link["egress_host"], "port": link["egress_port"], "reachable": False, "error": err}

def cascade_status(link):
    server_password = cascade.get("server_password", "")
    hub = cascade.get("hub_name", "CascadeLab")
    name = link.get("connection_name")
    cmd = "tmp=$(mktemp); printf 'Hub %s\\nCascadeStatusGet %s\\n' " + shq(hub) + " " + shq(name) + " > \"$tmp\"; timeout " + str(timeout + 5) + "s sudo docker exec -i -e SERVER_PASSWORD=" + shq(server_password) + " softether-cascade sh -c 'in=/tmp/ai-sp-cascade-status.$$; cat > \"$in\"; vpncmd localhost:5555 /SERVER /PASSWORD:\"$SERVER_PASSWORD\" /IN:\"$in\"; rc=$?; rm -f \"$in\"; exit $rc' < \"$tmp\"; rc=$?; rm -f \"$tmp\"; exit $rc"
    print(f"    checking cascade status {link['ingress_alias']}->{link['egress_alias']} via {name}...", flush=True)
    ok, code, output = ssh_text(link["ingress_alias"], cmd)
    online = ok and any(x in output for x in ["Connection Completed", "Session Established", "Online", "Connected"])
    print(f"    cascade status online={online} exit_code={code}", flush=True)
    return {"online": online, "exit_code": code, "matched_online_text": any(x in output for x in ["Connection Completed", "Session Established", "Online", "Connected"]), "output_excerpt": output[:1000]}

def shq(text):
    return "'" + str(text).replace("'", "'\\''") + "'"

records = []
for profile in policy.get("profiles", []):
    if profile_names and profile.get("name") not in profile_names:
        continue
    if profile.get("state") != "probe":
        continue
    direct_probe = profile.get("direct_probe", True) is not False
    anchors = profile.get("ingress_anchor_aliases") or profile.get("candidate_ingress_aliases") or []
    for ingress_alias in anchors:
        if alias_names and ingress_alias not in alias_names:
            continue
        if ingress_alias not in nodes:
            print(f"[WARN] ingress alias not in nodes.csv: {ingress_alias}")
            continue
        for target in profile.get("targets", []):
            label = target_label(target)
            print(f"Target {label}", flush=True)
            if direct_probe:
                print(f"  probing direct {ingress_alias}...", flush=True)
                ok, err, obs, used, retries = probe_target(ingress_alias, target, "direct")
                record = {"schema_version":1,"run_id":run_id,"observed_at_utc":utc_now(),"path_mode":"direct","profile":profile.get("name"),"behavior":profile.get("behavior"),"direct_probe_skipped":False,"candidate_alias":ingress_alias,"ingress_alias":ingress_alias,"egress_alias":ingress_alias,"cascade_connection":None,"cascade_transport_status":None,"cascade_connection_status":None,"endpoint":nodes[ingress_alias]["endpoint"],"target":target,"status":"observed" if ok else "probe_error","observation":obs,"target_status":obs,"effective_country":(obs or {}).get("external_country"),"effective_ip":(obs or {}).get("external_ip"),"attempts_used":used,"attempts_total":attempts,"retry_errors":retries,"error":err,"raw":None}
                records.append(record)
            else:
                print(f"  skipping direct {ingress_alias}; profile direct_probe=false", flush=True)
            if include_cascade:
                for link in cascade_links_for(ingress_alias):
                    egress_alias = link["egress_alias"]
                    cascade_label = f"cascade {ingress_alias}->{egress_alias}"
                    print(f"  probing {cascade_label} via {link.get('connection_name')}...", flush=True)
                    transport = transport_status(link)
                    status = cascade_status(link)
                    ok, err, obs, used, retries = probe_target(egress_alias, target, cascade_label)
                    records.append({"schema_version":1,"run_id":run_id,"observed_at_utc":utc_now(),"path_mode":"cascade","profile":profile.get("name"),"behavior":profile.get("behavior"),"direct_probe_skipped":not direct_probe,"candidate_alias":egress_alias,"ingress_alias":ingress_alias,"egress_alias":egress_alias,"cascade_connection":link.get("connection_name"),"cascade_link_state":link.get("state"),"cascade_transport_status":transport,"cascade_connection_status":status,"endpoint":nodes[egress_alias]["endpoint"],"target":target,"status":"observed" if ok else "probe_error","observation":obs,"target_status":obs,"effective_country":(obs or {}).get("external_country"),"effective_ip":(obs or {}).get("external_ip"),"attempts_used":used,"attempts_total":attempts,"retry_errors":retries,"error":err,"raw":None})

with open(history_path, "w", encoding="utf-8") as fh:
    for rec in records:
        fh.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
print(f"[OK] probe history written: {history_path}")
PY
