#!/usr/bin/env python3
import argparse
import datetime as dt
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


TABLES = ("st_http_rates", "st_tcp_rates")
STATE_RETENTION_AFTER_EXPIRY = dt.timedelta(days=30)


def utcnow():
    return dt.datetime.now(dt.timezone.utc)


def parse_time(value):
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def iso(value):
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_networks(path):
    networks = []
    if not path or not Path(path).exists():
        return networks
    for raw in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        try:
            networks.append(ipaddress.ip_network(line, strict=False))
        except ValueError:
            try:
                networks.append(ipaddress.ip_network(ipaddress.ip_address(line).exploded))
            except ValueError:
                continue
    return networks


def is_excluded(ip, excluded_networks):
    try:
        address = ipaddress.ip_address(ip)
    except ValueError:
        return True
    return any(address in network for network in excluded_networks)


def run_socat(socket_path, command):
    if not shutil.which("socat"):
        raise RuntimeError("socat is not installed")
    socket = Path(socket_path)
    if not socket.exists():
        raise RuntimeError(f"HAProxy admin socket is missing: {socket_path}")
    if not socket.is_socket():
        raise RuntimeError(f"HAProxy admin socket path is not a socket: {socket_path}")
    proc = subprocess.run(
        ["socat", "-", f"UNIX-CONNECT:{socket_path}"],
        input=f"{command}\n",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"socat failed for {command}: {proc.stderr.strip()}")
    return proc.stdout


def parse_table(output):
    rows = []
    for line in output.splitlines():
        if " key=" not in line:
            continue
        key_match = re.search(r"\bkey=([^\s]+)", line)
        if not key_match:
            continue
        values = {}
        for name, value in re.findall(r"([A-Za-z0-9_()]+)=([0-9]+)", line):
            values[name] = int(value)
        rows.append((key_match.group(1), values))
    return rows


def candidate_reasons(table, values, args):
    reasons = []
    if table == "st_http_rates":
        if values.get("gpc0", 0) > 0:
            reasons.append("http_scanner_or_error")
        for key, value in values.items():
            if key.startswith("http_req_rate(") and value >= args.http_req_rate_threshold:
                reasons.append(f"http_req_rate={value}")
            if key.startswith("http_err_rate(") and value >= args.http_err_rate_threshold:
                reasons.append(f"http_err_rate={value}")
    elif table == "st_tcp_rates":
        for key, value in values.items():
            if key.startswith("conn_rate(") and value >= args.tcp_conn_rate_threshold:
                reasons.append(f"tcp_conn_rate={value}")
            if key == "conn_cur" and value >= args.tcp_conn_cur_threshold:
                reasons.append(f"tcp_conn_cur={value}")
    return reasons


def load_state(path):
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def calculate_ttl_seconds(count, base_ttl_seconds, max_ttl_seconds):
    count = max(1, int(count))
    base_ttl_seconds = max(1, int(base_ttl_seconds))
    max_ttl_seconds = max(base_ttl_seconds, int(max_ttl_seconds))
    ttl = base_ttl_seconds * (2 ** (count - 1))
    return min(ttl, max_ttl_seconds)


def prune_state(bans, now, excluded_networks, candidate_ips, retention_after_expiry=STATE_RETENTION_AFTER_EXPIRY):
    active = {}
    history = {}
    for ip, info in bans.items():
        if is_excluded(ip, excluded_networks):
            continue
        expires_at = parse_time(info.get("expires_at"))
        if not expires_at:
            continue
        if expires_at > now:
            active[ip] = info
            history[ip] = info
            continue
        if ip in candidate_ips or expires_at + retention_after_expiry > now:
            history[ip] = info
    return active, history


def build_ban_record(ip, previous, reasons, now, base_ttl_seconds, max_ttl_seconds, mode):
    first_seen = previous.get("first_seen") or iso(now)
    count = int(previous.get("count", 0)) + 1
    ttl_seconds = calculate_ttl_seconds(count, base_ttl_seconds, max_ttl_seconds)
    combined_reasons = sorted(set(previous.get("reasons", [])) | set(reasons))
    return {
        "ip": ip,
        "first_seen": first_seen,
        "last_seen": iso(now),
        "expires_at": iso(now + dt.timedelta(seconds=ttl_seconds)),
        "count": count,
        "reasons": combined_reasons,
        "ttl_seconds": ttl_seconds,
        "mode": mode,
    }


def write_lines(path, lines):
    path.parent.mkdir(parents=True, exist_ok=True)
    content = "".join(f"{line}\n" for line in lines)
    old = path.read_text(encoding="utf-8", errors="replace") if path.exists() else None
    if old == content:
        return False
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(content, encoding="ascii")
    os.replace(tmp, path)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("observe", "enforce"), required=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--log-file", required=True)
    parser.add_argument("--manual-blocked-file", required=True)
    parser.add_argument("--generated-blocked-file", required=True)
    parser.add_argument("--mgmt-allowlist-file", required=True)
    parser.add_argument("--reload-command", default="")
    parser.add_argument("--ban-ttl-seconds", type=int, default=3600)
    parser.add_argument("--max-ban-ttl-seconds", type=int, default=86400)
    parser.add_argument("--min-score", type=int, default=1)
    parser.add_argument("--http-req-rate-threshold", type=int, default=50)
    parser.add_argument("--http-err-rate-threshold", type=int, default=5)
    parser.add_argument("--tcp-conn-rate-threshold", type=int, default=60)
    parser.add_argument("--tcp-conn-cur-threshold", type=int, default=80)
    parser.add_argument("--never-ban-cidr", action="append", default=[])
    args = parser.parse_args()

    now = utcnow()
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    log_path = Path(args.log_file)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    state_path = state_dir / "bans.json"
    generated_path = Path(args.generated_blocked_file)

    excluded = [ipaddress.ip_network(cidr, strict=False) for cidr in args.never_ban_cidr]
    excluded += read_networks(args.mgmt_allowlist_file)
    excluded += read_networks(args.manual_blocked_file)

    candidates = {}
    errors = []
    for table in TABLES:
        try:
            rows = parse_table(run_socat(args.socket, f"show table {table}"))
        except Exception as exc:
            error = {"table": table, "error": str(exc)}
            errors.append(error)
            print(f"edge_banlist_error table={table} error={exc}", file=sys.stderr)
            continue
        for ip, values in rows:
            if is_excluded(ip, excluded):
                continue
            reasons = candidate_reasons(table, values, args)
            if not reasons:
                continue
            item = candidates.setdefault(ip, {"score": 0, "reasons": set()})
            item["score"] += len(reasons)
            item["reasons"].update(reasons)

    candidate_ips = set(candidates)
    bans = load_state(state_path)
    active, history = prune_state(bans, now, excluded, candidate_ips)
    candidate_details = {}

    for ip, item in sorted(candidates.items()):
        if item["score"] < args.min_score:
            continue
        previous = history.get(ip, {})
        updated = build_ban_record(
            ip,
            previous,
            item["reasons"],
            now,
            args.ban_ttl_seconds,
            args.max_ban_ttl_seconds,
            args.mode,
        )
        active[ip] = updated
        history[ip] = updated
        candidate_details[ip] = {
            "count": updated["count"],
            "ttl_seconds": updated["ttl_seconds"],
        }

    state_path.write_text(json.dumps(history, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    desired_ips = sorted(active) if args.mode == "enforce" else []
    changed = write_lines(generated_path, desired_ips)
    if changed and args.mode == "enforce" and args.reload_command:
        subprocess.run(args.reload_command, shell=True, check=False)

    with log_path.open("a", encoding="utf-8") as log:
        event = {
            "ts": iso(now),
            "mode": args.mode,
            "candidate_count": len(candidates),
            "active_ban_count": len(active),
            "generated_count": len(desired_ips),
            "generated_changed": changed,
            "max_ban_ttl_seconds": args.max_ban_ttl_seconds,
            "errors": errors,
            "candidates": {
                ip: {
                    "score": data["score"],
                    "reasons": sorted(data["reasons"]),
                    "count": candidate_details.get(ip, {}).get("count"),
                    "ttl_seconds": candidate_details.get(ip, {}).get("ttl_seconds"),
                }
                for ip, data in sorted(candidates.items())
            },
        }
        log.write(json.dumps(event, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
