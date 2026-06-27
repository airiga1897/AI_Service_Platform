#!/usr/bin/env bash

set -euo pipefail

POLICY_FILE="./operator/egress_policy/profiles.json"
HISTORY_DIR="./operator/egress_policy/history"
PROPOSAL_DIR="./operator/egress_policy/proposals"
HISTORY_FILE=""
READINESS_HISTORY=false
DRY_RUN=false
FORCE=false

fail() {
    echo "[ERROR] $1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -PolicyFile|--policy-file) POLICY_FILE="${2:-}"; shift 2 ;;
        -HistoryDir|--history-dir) HISTORY_DIR="${2:-}"; shift 2 ;;
        -HistoryFile|--history-file) HISTORY_FILE="${2:-}"; shift 2 ;;
        -ProposalDir|--proposal-dir) PROPOSAL_DIR="${2:-}"; shift 2 ;;
        -ReadinessHistory|--readiness-history) READINESS_HISTORY=true; shift ;;
        -DryRun|--dry-run) DRY_RUN=true; shift ;;
        -Force|--force) FORCE=true; shift ;;
        -Latest|--latest) shift ;;
        *) fail "Unsupported suggest argument: $1" ;;
    esac
done

[ -f "$POLICY_FILE" ] || fail "egress policy registry not found: $POLICY_FILE"
[ -d "$HISTORY_DIR" ] || fail "egress policy history dir not found: $HISTORY_DIR"

python3 - "$POLICY_FILE" "$HISTORY_DIR" "$HISTORY_FILE" "$PROPOSAL_DIR" "$READINESS_HISTORY" "$DRY_RUN" "$FORCE" <<'PY'
import datetime as dt, glob, json, os, re, sys

policy_file, history_dir, history_file, proposal_dir, readiness_s, dry_run_s, force_s = sys.argv[1:]
readiness = readiness_s.lower() == "true"
dry_run = dry_run_s.lower() == "true"
force = force_s.lower() == "true"

def load_json(path):
    with open(path, encoding="utf-8-sig") as fh:
        return json.load(fh)

def safe(text):
    text = str(text or "unknown").lower()
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text or "unknown"

def target_key(t):
    return f"{t.get('type')}|{t.get('value')}|{t.get('protocol')}|{t.get('port')}"

def infra_ok(r):
    if r.get("path_mode") != "dataplane_readiness":
        return True
    return bool(
        r.get("policy_network_status", {}).get("edge_attached") and
        r.get("policy_network_status", {}).get("gateway_attached") and
        r.get("policy_network_status", {}).get("cascade_attached") and
        r.get("ingress_gateway_status", {}).get("ok") and
        r.get("ingress_cascade_status", {}).get("ok") and
        r.get("egress_cascade_status", {}).get("ok") and
        r.get("ingress_nat_status", {}).get("ok") and
        r.get("egress_nat_status", {}).get("ok") and
        r.get("cascade_transport_status", {}).get("reachable")
    )

def effective_status(r):
    if not readiness or r.get("path_mode") != "dataplane_readiness":
        return str(r.get("status") or "")
    if not infra_ok(r):
        return "probe_error"
    obs = r.get("target_status") or r.get("observation") or {}
    proto = (r.get("target") or {}).get("protocol")
    if proto in ("http", "https"):
        status = obs.get("http_status")
        if status is not None:
            status = int(status)
            if 200 <= status < 400:
                return "observed"
            if 400 <= status < 500:
                return "target_rejected"
        return "target_timeout"
    if proto == "tcp":
        return "observed" if obs.get("tcp_connect_ms") is not None else "target_timeout"
    if proto == "icmp":
        return "observed" if obs.get("icmp_ms") is not None else "target_timeout"
    return str(r.get("status") or "")

def recommendation(r):
    mode = "cascade" if r.get("path_mode") == "dataplane_readiness" else (r.get("path_mode") or "direct")
    status = effective_status(r)
    obs = r.get("target_status") or r.get("observation") or {}
    proto = (r.get("target") or {}).get("protocol")
    if mode == "cascade" and not infra_ok(r):
        return "fallback_unavailable"
    if status == "target_timeout":
        return "review"
    if status == "probe_error":
        return "fallback_unavailable" if mode == "cascade" else "probe_error"
    target_ok = False
    if proto in ("http", "https"):
        http = obs.get("http_status")
        target_ok = http is not None and 200 <= int(http) < 400
    elif proto == "tcp":
        target_ok = obs.get("tcp_connect_ms") is not None
    elif proto == "icmp":
        target_ok = obs.get("icmp_ms") is not None
    elif proto == "udp":
        return "route_review"
    if target_ok:
        return "fallback_available" if mode == "cascade" else "good_ingress_local"
    if mode == "cascade" and status == "target_rejected":
        return "fallback_available"
    return "review"

def response_ms(r):
    obs = r.get("target_status") or r.get("observation") or {}
    for key in ("http_total_ms", "tcp_connect_ms", "icmp_ms"):
        if obs.get(key) is not None:
            return obs.get(key)
    return None

def proposal_for(records):
    first = records[0]
    target = first.get("target") or {}
    profile = first.get("profile") or "unknown-profile"
    best = sorted(records, key=lambda r: (0 if recommendation(r) == "fallback_available" else 1, response_ms(r) if response_ms(r) is not None else 10**12))[0]
    rec = recommendation(best)
    if rec == "fallback_available":
        issue = "fallback_available"
    elif rec == "fallback_unavailable":
        issue = "fallback_unavailable"
    elif rec == "probe_error":
        issue = "probe_error"
    elif rec == "review":
        issue = "route_review"
    else:
        return None
    path_part = ""
    if best.get("ingress_alias") and best.get("egress_alias"):
        path_part = f"-{safe(best.get('ingress_alias'))}-to-{safe(best.get('egress_alias'))}"
    proposal_id = f"{safe(issue)}-{safe(profile)}-{safe(target.get('value'))}-{safe(target.get('port'))}{path_part}"
    status = "accepted" if issue == "fallback_available" else "suggested"
    obs = best.get("target_status") or best.get("observation") or {}
    return {
        "schema_version": 1,
        "id": proposal_id,
        "type": issue,
        "human_type": {
            "fallback_available": "Fallback available",
            "fallback_unavailable": "Fallback unavailable",
            "probe_error": "Probe error",
            "route_review": "Route review",
        }.get(issue, issue),
        "status": status,
        "human_status": "Принято" if status == "accepted" else "Предложено",
        "created_at_utc": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "source": "deterministic_probe",
        "generator": "suggest_egress_policy.sh",
        "profile": profile,
        "target": target,
        "recommended_path": {
            "mode": "cascade" if best.get("path_mode") == "dataplane_readiness" else best.get("path_mode"),
            "ingress_alias": best.get("ingress_alias"),
            "egress_alias": best.get("egress_alias"),
            "cascade_connection": best.get("cascade_connection"),
            "effective_country": best.get("effective_country"),
            "effective_ip": best.get("effective_ip"),
            "http_status": obs.get("http_status"),
            "response_ms": response_ms(best),
        },
        "reason": "Ingress-local egress did not produce a good stable result, and a cascade fallback candidate is available for operator review." if issue == "fallback_available" else "Readiness history needs operator review before selective fallback routing.",
        "human_summary": "Локальный egress не дал хорошего результата, но fallback через cascade доступен." if issue == "fallback_available" else "Нужен ручной просмотр readiness evidence.",
        "rollback": "This is proposal-only state. Delete or reject this proposal; no runtime route exists until an operator applies a separate approved policy.",
        "evidence": {
            "source_history_file": best.get("source_history_file"),
            "run_id": best.get("run_id"),
            "summary": "Generated from latest readiness history.",
            "observations": records[:5],
        },
        "ai_advisory": None,
    }

pattern = "selective-fallback-readiness-*.jsonl" if readiness else "egress-probes-*.jsonl"
if history_file:
    files = [history_file]
else:
    files = sorted(glob.glob(os.path.join(history_dir, pattern)), key=os.path.getmtime, reverse=True)[:1]
if not files:
    print(f"No {'selective fallback readiness' if readiness else 'egress probe'} history files found.")
    raise SystemExit(0)

records = []
for path in files:
    with open(path, encoding="utf-8-sig") as fh:
        for line in fh:
            if not line.strip():
                continue
            rec = json.loads(line)
            rec["source_history_file"] = path
            records.append(rec)

groups = {}
for rec in records:
    groups.setdefault((rec.get("profile"), target_key(rec.get("target") or {})), []).append(rec)

proposals = [p for p in (proposal_for(v) for v in groups.values()) if p]
if not proposals:
    print("No egress policy proposals generated.")
    raise SystemExit(0)

if dry_run:
    for p in proposals:
        rp = p.get("recommended_path") or {}
        print(f"{p['id']} {p['status']} {p['type']} {p['target'].get('value')}:{p['target'].get('port')} {rp.get('ingress_alias')}->{rp.get('egress_alias')}")
    print("Dry-run completed. No proposal files were written.")
    raise SystemExit(0)

os.makedirs(proposal_dir, exist_ok=True)
for proposal in proposals:
    path = os.path.join(proposal_dir, proposal["id"] + ".json")
    if os.path.exists(path) and not force:
        existing = load_json(path)
        if existing.get("status") in ("rejected", "ignored"):
            print(f"Skipping existing manually decided proposal: {path}")
            continue
        if existing.get("status") != "suggested" or proposal.get("status") != "accepted":
            print(f"Skipping existing proposal for the same profile/target/issue: {path}")
            continue
        print(f"Updating existing suggested proposal to accepted: {path}")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(proposal, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(f"[OK] Proposal written: {path}")
PY
