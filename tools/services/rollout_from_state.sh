#!/usr/bin/env bash

set -euo pipefail

NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
OPERATOR_DIR="./operator"
CONTROL_ROLE="orchestration"
CONTROL_ALIAS=""
SYNC_SCRIPT="tools/bootstrap/sync_to_orchestration.sh"
STANDBY_PREPARE_SCRIPT="tools/bootstrap/prepare_orchestration_standby.sh"
SERVICE_REMOTE_SCRIPT="tools/services/service_remote.sh"
OPERATOR_BACKUP_SCRIPT="tools/operator_backup/backup_operator.sh"
OPERATOR_BACKUP_DIR="${AI_SP_OPERATOR_BACKUP_DIR:-$HOME/ai-service-platform-backups/operator}"
OPERATOR_BACKUP_REMOTE_DIR="/opt/backups/ai-service-platform/operator"
AUTO_ACCEPT_HOST_KEY="false"
SKIP_SYNC="false"
SKIP_STANDBY_SYNC="false"
SKIP_POSTCHECK="false"
SKIP_DRY_RUN="false"
SKIP_OPERATOR_BACKUP="false"
PLATFORM_ROUTER_SOFTETHER_DEBUG="false"
RESEED_VPN_EDGE=""
ONLY_SERVICE=""

EXPECTED_HEADER="current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
EXPECTED_STATE_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"

usage() {
    cat <<'USAGE'
Usage:
  bash tools/services/rollout_from_state.sh [options]

Options:
  --nodes-file PATH       Operator nodes.csv. Default: ./operator/nodes.csv
  --state-file PATH       Operator state.csv. Default: ./operator/state.csv
  --operator-dir PATH     Operator directory. Default: ./operator
  --control-role NAME     Platform role to use as orchestration. Default: orchestration
  --control-alias ALIAS   Optional explicit orchestration alias.
  --operator-backup-script PATH
                         Operator backup script. Default: tools/operator_backup/backup_operator.sh
  --operator-backup-dir PATH
                         Local encrypted operator backup dir.
  --operator-backup-remote-dir PATH
                         Remote encrypted operator backup dir.
  --auto-accept-host-key  Refresh known_hosts during sync.
  --reseed-vpn-edge ALIASES
                         Explicitly reseed SoftEther config for aliases.
  --only-service NAME    Roll out only one service: edge_haproxy, vpn_edge, vpn_cascade, policy_gateway, or edge_candidate_collector.
  --platform-router-softether-debug
                         platform_router only: show SoftEther server configure task output for diagnostics.
  --skip-sync             Skip sync/verify step.
  --skip-standby-sync     Skip automatic sync of orchestration candidates.
  --skip-postcheck        Skip service postcheck placeholders.
  --skip-dry-run          Skip pre-apply Ansible check runs.
  --skip-operator-backup  Skip mandatory backup before local operator mutations.
  -h, --help              Show help.
USAGE
}

fail() {
    echo "[ERROR] $1" >&2
    exit 1
}

require_file() {
    local path="$1"
    local label="$2"
    [ -f "$path" ] || fail "$label not found: $path"
}

split_aliases_to_lines() {
    local aliases="$1"
    local old_ifs="$IFS"
    local alias_item
    IFS=+
    for alias_item in $aliases; do
        IFS="$old_ifs"
        [ -n "$alias_item" ] && printf '%s\n' "$alias_item"
        IFS=+
    done
    IFS="$old_ifs"
}

split_operator_aliases_to_lines() {
    local aliases="$1"
    aliases="${aliases//,/+}"
    split_aliases_to_lines "$aliases"
}

alias_in_list() {
    local alias="$1"
    local aliases="$2"
    local item
    while IFS= read -r item; do
        [ "$item" = "$alias" ] && return 0
    done < <(split_aliases_to_lines "$aliases")
    return 1
}

add_unique_alias() {
    local alias="$1"
    local existing
    for existing in "${edge_route_apply_aliases[@]}"; do
        [ "$existing" = "$alias" ] && return
    done
    edge_route_apply_aliases+=("$alias")
}

add_unique_to_array() {
    local array_name="$1"
    local value="$2"
    local existing
    eval "local current_values=(\"\${${array_name}[@]}\")"
    for existing in "${current_values[@]}"; do
        [ "$existing" = "$value" ] && return
    done
    eval "$array_name+=(\"\$value\")"
}

OPERATOR_BACKUP_COMPLETED="false"
invoke_operator_backup_if_needed() {
    local reason="$1"
    if [ "$OPERATOR_BACKUP_COMPLETED" = "true" ]; then
        return
    fi
    if [ "$SKIP_OPERATOR_BACKUP" = "true" ]; then
        echo "[WARN] Operator backup skipped before local mutation: $reason" >&2
        OPERATOR_BACKUP_COMPLETED="true"
        return
    fi
    require_file "$OPERATOR_BACKUP_SCRIPT" "--operator-backup-script"
    echo "Operator backup before local mutation: $reason"
    local args=(
        "--nodes-file" "$NODES_FILE"
        "--state-file" "$STATE_FILE"
        "--operator-dir" "$OPERATOR_DIR"
        "--control-role" "$CONTROL_ROLE"
        "--backup-dir" "$OPERATOR_BACKUP_DIR"
        "--remote-backup-dir" "$OPERATOR_BACKUP_REMOTE_DIR"
    )
    [ "$AUTO_ACCEPT_HOST_KEY" = "true" ] && args+=("--auto-accept-host-key")
    bash "$OPERATOR_BACKUP_SCRIPT" "${args[@]}"
    OPERATOR_BACKUP_COMPLETED="true"
}

array_contains() {
    local array_name="$1"
    local value="$2"
    local existing
    eval "local current_values=(\"\${${array_name}[@]}\")"
    for existing in "${current_values[@]}"; do
        [ "$existing" = "$value" ] && return 0
    done
    return 1
}

append_aliases_to_var() {
    local var_name="$1"
    local aliases="$2"
    local alias current
    while IFS= read -r alias; do
        [ -n "$alias" ] || continue
        eval "current=\"\${$var_name}\""
        if ! alias_in_list "$alias" "$current"; then
            if [ -z "$current" ]; then
                eval "$var_name=\"\$alias\""
            else
                eval "$var_name=\"\$current+\$alias\""
            fi
        fi
    done < <(split_aliases_to_lines "$aliases")
}

vpn_cascade_link_secret_path() {
    printf '%s\n' "$OPERATOR_DIR/softether/cascade/secrets/lab-vps5-vps4.json"
}

order_vpn_cascade_aliases() {
    local aliases="$1"
    local secret_path
    secret_path="$(vpn_cascade_link_secret_path)"
    [ -f "$secret_path" ] || fail "vpn_cascade requires link secret JSON before rollout: $secret_path"
    python3 - "$secret_path" "$aliases" <<'PY'
import json
import sys

secret_path, aliases_text = sys.argv[1], sys.argv[2]
aliases = [item for item in aliases_text.split("+") if item]
try:
    with open(secret_path, encoding="utf-8") as handle:
        link = json.load(handle)
except Exception as exc:
    raise SystemExit(f"vpn_cascade link secret JSON is not valid: {secret_path}: {exc}")

ordered = []
for alias in (link.get("egress_alias"), link.get("ingress_alias")):
    if alias in aliases and alias not in ordered:
        ordered.append(alias)
for alias in aliases:
    if alias not in ordered:
        ordered.append(alias)
print("+".join(ordered))
PY
}

ensure_service_plan() {
    local service="$1"
    local planned
    for planned in "${planned_services[@]}"; do
        [ "$planned" = "$service" ] && return
    done
    invoke_service_remote "$service" plan ""
    planned_services+=("$service")
}

invoke_service_remote() {
    local service="$1"
    local action="$2"
    local limit="${3:-}"
    local check="${4:-false}"
    local confirm_purge="${5:-false}"
    local args=(
        "$service" "$action"
        "--nodes-file" "$NODES_FILE"
        "--state-file" "$STATE_FILE"
        "--operator-dir" "$OPERATOR_DIR"
        "--control-role" "$CONTROL_ROLE"
    )
    [ -n "$CONTROL_ALIAS" ] && args+=("--control-alias" "$CONTROL_ALIAS")
    [ -n "$limit" ] && args+=("--limit" "$limit")
    [ "$check" = "true" ] && args+=("--check")
    [ "$confirm_purge" = "true" ] && args+=("--confirm-purge")
    if [ "$PLATFORM_ROUTER_SOFTETHER_DEBUG" = "true" ] && [ "$service" = "platform_router" ]; then
        args+=("--platform-router-softether-debug")
    fi
    bash "$SERVICE_REMOTE_SCRIPT" "${args[@]}"
}

invoke_service_apply_dry_run() {
    local service="$1"
    local limit="$2"
    local label="$3"
    if [ "$SKIP_DRY_RUN" = "true" ]; then
        echo "$label: dry-run skipped"
        echo "Dry-run: skipped by operator request"
        return
    fi
    echo "$label: dry-run queued"
    invoke_service_remote "$service" apply "$limit" true
}

invoke_vpn_edge_reseed() {
    local alias="$1"
    if array_contains reseeded_vpn_edge_aliases "$alias"; then
        return
    fi
    echo "vpn_edge on $alias: reseed queued"
    invoke_service_remote "vpn_edge" reseed "$alias"
    reseeded_vpn_edge_aliases+=("$alias")
    summary+=("vpn_edge $alias: reseeded")
}

invoke_sync() {
    local args=(
        "--nodes-file" "$NODES_FILE"
        "--state-file" "$STATE_FILE"
        "--control-role" "$CONTROL_ROLE"
    )
    [ -n "$CONTROL_ALIAS" ] && args+=("--control-alias" "$CONTROL_ALIAS")
    [ "$AUTO_ACCEPT_HOST_KEY" = "true" ] && args+=("--refresh-known-hosts")
    bash "$SYNC_SCRIPT" "${args[@]}"
}

invoke_standby_sync() {
    local aliases="$1"
    local alias
    [ -n "$aliases" ] || return

    echo ""
    echo "Step 1b/3: sync standby orchestration candidate nodes"
    while IFS= read -r alias; do
        [ -n "$alias" ] || continue
        echo "Preparing standby orchestration node $alias"
        local args=(
            "--alias" "$alias"
            "--nodes-file" "$NODES_FILE"
            "--state-file" "$STATE_FILE"
            "--operator-dir" "$OPERATOR_DIR"
            "--control-role" "$CONTROL_ROLE"
            "--sync-script" "$SYNC_SCRIPT"
            "--skip-service-plan"
        )
        [ "$AUTO_ACCEPT_HOST_KEY" = "true" ] && args+=("--refresh-known-hosts")
        bash "$STANDBY_PREPARE_SCRIPT" "${args[@]}"
    done < <(split_aliases_to_lines "$aliases")
}

invoke_postcheck() {
    local service="$1"
    local state="$2"
    local alias="$3"
    if [ "$SKIP_POSTCHECK" = "true" ]; then
        echo "Postcheck skipped for $service on $alias"
        return
    fi
    case "$service:$state" in
        edge_haproxy:present)
            invoke_service_remote "$service" plan "$alias"
            echo "edge_haproxy postcheck queued for $alias"
            ;;
        edge_haproxy:absent)
            echo "Postcheck note: edge_haproxy absent requested for $alias; config/data should remain on target"
            ;;
        edge_haproxy:purged)
            echo "Postcheck note: edge_haproxy purge requested for $alias; runtime directory removal is handled by the role"
            ;;
        *)
            return
            ;;
    esac
}

update_vpn_management_allowlist() {
    local allowlist_path="$1"
    local begin_marker="# BEGIN AI_SP_NODE_ENDPOINTS"
    local end_marker="# END AI_SP_NODE_ENDPOINTS"
    local allowlist_dir
    allowlist_dir="$(dirname "$allowlist_path")"
    if [ ! -d "$allowlist_dir" ]; then
        invoke_operator_backup_if_needed "create VPN management allowlist directory"
        mkdir -p "$allowlist_dir"
    fi

    local tmp_file
    tmp_file="$(mktemp)"
    python3 - "$NODES_FILE" "$allowlist_path" "$begin_marker" "$end_marker" > "$tmp_file" <<'PY'
import csv
import ipaddress
import socket
import sys

nodes_file, allowlist_path, begin_marker, end_marker = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

manual_lines = []
try:
    with open(allowlist_path, encoding="ascii") as handle:
        inside_generated = False
        for raw in handle:
            line = raw.rstrip("\n")
            item = line.strip()
            if item == begin_marker:
                inside_generated = True
                continue
            if item == end_marker:
                inside_generated = False
                continue
            if inside_generated:
                continue
            if line not in manual_lines:
                manual_lines.append(line)
except FileNotFoundError:
    pass

resolved = []
with open(nodes_file, newline="", encoding="ascii") as handle:
    for row in csv.DictReader(handle):
        alias = row.get("current_alias", "")
        endpoint = row.get("endpoint", "")
        if not endpoint:
            continue
        try:
            ip = ipaddress.ip_address(endpoint)
            if ip.version == 4 and str(ip) not in resolved:
                resolved.append(str(ip))
            continue
        except ValueError:
            pass
        try:
            infos = socket.getaddrinfo(endpoint, None, socket.AF_INET, socket.SOCK_STREAM)
        except OSError as exc:
            raise SystemExit(f"Could not resolve endpoint {endpoint!r} for alias {alias!r}: {exc}")
        for info in infos:
            ip = info[4][0]
            if ip not in resolved:
                resolved.append(ip)

manual_entries = sorted({item.strip() for item in manual_lines if item.strip() and not item.strip().startswith("#")})
generated_entries = sorted(item for item in set(resolved) if item not in manual_entries)

while manual_lines and not manual_lines[-1].strip():
    manual_lines.pop()

for line in manual_lines:
    print(line)
if manual_lines:
    print()
print(begin_marker)
for item in generated_entries:
    print(item)
print(end_marker)
PY

    local current_file
    current_file="$(mktemp)"
    if [ -f "$allowlist_path" ]; then
        cat "$allowlist_path" > "$current_file"
    else
        : > "$current_file"
    fi

    if cmp -s "$current_file" "$tmp_file"; then
        rm -f "$tmp_file" "$current_file"
        return
    fi

    invoke_operator_backup_if_needed "refresh VPN management allowlist from nodes.csv"
    cp "$tmp_file" "$allowlist_path"
    echo "Updated VPN management allowlist with node endpoint IPs"
    rm -f "$tmp_file" "$current_file"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --nodes-file) NODES_FILE="${2:-}"; shift 2 ;;
        --state-file) STATE_FILE="${2:-}"; shift 2 ;;
        --operator-dir) OPERATOR_DIR="${2:-}"; shift 2 ;;
        --control-role) CONTROL_ROLE="${2:-}"; shift 2 ;;
        --control-alias) CONTROL_ALIAS="${2:-}"; shift 2 ;;
        --sync-script) SYNC_SCRIPT="${2:-}"; shift 2 ;;
        --standby-prepare-script) STANDBY_PREPARE_SCRIPT="${2:-}"; shift 2 ;;
        --service-remote-script) SERVICE_REMOTE_SCRIPT="${2:-}"; shift 2 ;;
        --operator-backup-script) OPERATOR_BACKUP_SCRIPT="${2:-}"; shift 2 ;;
        --operator-backup-dir) OPERATOR_BACKUP_DIR="${2:-}"; shift 2 ;;
        --operator-backup-remote-dir) OPERATOR_BACKUP_REMOTE_DIR="${2:-}"; shift 2 ;;
        --auto-accept-host-key|--refresh-known-hosts) AUTO_ACCEPT_HOST_KEY="true"; shift ;;
        --reseed-vpn-edge) RESEED_VPN_EDGE="${2:-}"; shift 2 ;;
        --only-service) ONLY_SERVICE="${2:-}"; shift 2 ;;
        --platform-router-softether-debug) PLATFORM_ROUTER_SOFTETHER_DEBUG="true"; shift ;;
        --skip-sync) SKIP_SYNC="true"; shift ;;
        --skip-standby-sync) SKIP_STANDBY_SYNC="true"; shift ;;
        --skip-postcheck) SKIP_POSTCHECK="true"; shift ;;
        --skip-dry-run) SKIP_DRY_RUN="true"; shift ;;
        --skip-operator-backup) SKIP_OPERATOR_BACKUP="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

require_file "$NODES_FILE" "--nodes-file"
require_file "$STATE_FILE" "--state-file"
require_file "$SYNC_SCRIPT" "--sync-script"
if [ "$SKIP_STANDBY_SYNC" = "false" ]; then
    require_file "$STANDBY_PREPARE_SCRIPT" "--standby-prepare-script"
fi
require_file "$SERVICE_REMOTE_SCRIPT" "--service-remote-script"

case "$ONLY_SERVICE" in
    ""|edge_haproxy|vpn_edge|vpn_cascade|policy_gateway|edge_candidate_collector|edge_banlist|postgres_runtime|softether_l3_vps|platform_networks|host_resources|platform_router) ;;
    *) fail "--only-service must be one of: edge_haproxy, vpn_edge, vpn_cascade, policy_gateway, edge_candidate_collector, edge_banlist, postgres_runtime, softether_l3_vps, platform_networks, host_resources, platform_router" ;;
esac
if [ "$PLATFORM_ROUTER_SOFTETHER_DEBUG" = "true" ] && [ -n "$ONLY_SERVICE" ] && [ "$ONLY_SERVICE" != "platform_router" ]; then
    fail "--platform-router-softether-debug is supported only for platform_router rollouts"
fi

first_line="$(head -n 1 "$NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_HEADER"
state_first_line="$(head -n 1 "$STATE_FILE" | tr -d '\r')"
[ "$state_first_line" = "$EXPECTED_STATE_HEADER" ] || fail "state.csv header must be exactly: $EXPECTED_STATE_HEADER"

update_vpn_management_allowlist "$OPERATOR_DIR/haproxy/lists/vpn_mgmt_ips.lst"

node_aliases=""
while IFS=, read -r current_alias _endpoint _expected_ip _connection _ssh_port _root_password extra || [ -n "${current_alias:-}" ]; do
    current_alias="${current_alias//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ -z "$current_alias" ] && continue
    [ -z "$extra" ] || fail "nodes.csv row for $current_alias has too many columns"
    append_aliases_to_var node_aliases "$current_alias"
done < <(tail -n +2 "$NODES_FILE")

edge_haproxy_aliases=""
vpn_edge_aliases=""
vpn_cascade_aliases=""
vpn_ingress_aliases=""
present_edge_route_aliases=""
standby_orchestration_aliases=""
while IFS=, read -r kind name _ansible_group active_aliases _candidate_aliases _old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    active_aliases="${active_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ -z "$kind" ] && continue
    [ -z "$extra" ] || fail "state.csv row for $name has too many columns"
    if [ "$kind" = "service" ] && [ "$row_state" = "present" ]; then
        [ "$name" = "edge_haproxy" ] && append_aliases_to_var edge_haproxy_aliases "$active_aliases"
        [ "$name" = "vpn_edge" ] && append_aliases_to_var vpn_edge_aliases "$active_aliases"
        [ "$name" = "vpn_cascade" ] && append_aliases_to_var vpn_cascade_aliases "$active_aliases"
    fi
    if { [ "$kind" = "platform_role" ] || [ "$kind" = "role" ]; } && [ "$name" = "$CONTROL_ROLE" ] && [ "$row_state" = "present" ]; then
        append_aliases_to_var standby_orchestration_aliases "$_candidate_aliases"
    fi
done < <(tail -n +2 "$STATE_FILE")

if [ -n "$ONLY_SERVICE" ]; then
    only_service_found="false"
    while IFS=, read -r kind name _ansible_group _active_aliases _candidate_aliases _old_aliases _row_state _extra || [ -n "${kind:-}" ]; do
        kind="${kind//$'\r'/}"
        name="${name//$'\r'/}"
        if [ "$kind" = "service" ] && [ "$name" = "$ONLY_SERVICE" ]; then
            only_service_found="true"
            break
        fi
    done < <(tail -n +2 "$STATE_FILE")
    [ "$only_service_found" = "true" ] || fail "--only-service $ONLY_SERVICE was requested, but state.csv has no service row with that name"
    echo "OnlyService: $ONLY_SERVICE"
fi

reseed_vpn_edge_aliases=()
while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    if ! alias_in_list "$alias" "$node_aliases"; then
        fail "reseed-vpn-edge alias '$alias' is not present in nodes.csv"
    fi
    if ! alias_in_list "$alias" "$vpn_edge_aliases"; then
        fail "reseed-vpn-edge alias '$alias' requires service vpn_edge present on the same alias in state.csv"
    fi
    add_unique_to_array reseed_vpn_edge_aliases "$alias"
done < <(split_operator_aliases_to_lines "$RESEED_VPN_EDGE")

edge_route_apply_aliases=()
edge_route_removal_aliases=()
while IFS=, read -r kind name _ansible_group active_aliases _candidate_aliases _old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    active_aliases="${active_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ "$kind" = "edge_route" ] || continue
    [ -z "$extra" ] || fail "state.csv row for edge_route $name has too many columns"
    case "$row_state" in
        present|absent|purged) ;;
        *) fail "$name edge_route state must be one of: present, absent, purged" ;;
    esac
    if [ "$row_state" != "present" ]; then
        while IFS= read -r alias; do
            [ -n "$alias" ] || continue
            if alias_in_list "$alias" "$edge_haproxy_aliases"; then
                add_unique_to_array edge_route_removal_aliases "$alias"
            fi
        done < <(split_aliases_to_lines "$active_aliases")
        continue
    fi
    append_aliases_to_var present_edge_route_aliases "$active_aliases"
    [ "$name" = "vpn_ingress" ] && append_aliases_to_var vpn_ingress_aliases "$active_aliases"
    mapfile -t route_aliases < <(split_aliases_to_lines "$active_aliases")
    [ "${#route_aliases[@]}" -gt 0 ] || fail "edge_route $name has state=present but active_aliases is empty"
    for alias in "${route_aliases[@]}"; do
        alias_in_list "$alias" "$edge_haproxy_aliases" || fail "edge_route $name is present on $alias, but service edge_haproxy is not present on the same alias"
        if [ "$name" = "vpn_ingress" ]; then
            alias_in_list "$alias" "$vpn_edge_aliases" || fail "edge_route vpn_ingress is present on $alias, but service vpn_edge is not present on the same alias"
        fi
        if [ "$name" = "vpn_cascade" ]; then
            alias_in_list "$alias" "$vpn_cascade_aliases" || fail "edge_route vpn_cascade is present on $alias, but service vpn_cascade is not present on the same alias"
        fi
        add_unique_alias "$alias"
    done
done < <(tail -n +2 "$STATE_FILE")

while IFS=, read -r kind name _ansible_group active_aliases _candidate_aliases _old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    active_aliases="${active_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ "$kind" = "service" ] || continue
    [ -z "$extra" ] || fail "state.csv row for service $name has too many columns"
    case "$row_state" in
        present|absent|purged) ;;
        *) fail "$name state must be one of: present, absent, purged" ;;
    esac
    if [ "$name" = "host_resources" ] && [ "$row_state" != "present" ]; then
        fail "host_resources v1 requires state=present; absent/purged are intentionally disabled"
    fi
    while IFS= read -r alias; do
        [ -n "$alias" ] || continue
        if [ "$name" = "vpn_edge" ] && [ "$row_state" = "present" ] && ! alias_in_list "$alias" "$vpn_ingress_aliases"; then
            fail "service vpn_edge is present on $alias, but edge_route vpn_ingress is not present on the same alias"
        fi
        if [ "$name" = "vpn_edge" ] && { [ "$row_state" = "absent" ] || [ "$row_state" = "purged" ]; } && alias_in_list "$alias" "$vpn_ingress_aliases"; then
            fail "service vpn_edge is $row_state on $alias, but edge_route vpn_ingress is still present on the same alias"
        fi
        if [ "$name" = "edge_haproxy" ] && { [ "$row_state" = "absent" ] || [ "$row_state" = "purged" ]; } && alias_in_list "$alias" "$present_edge_route_aliases"; then
            fail "service edge_haproxy is $row_state on $alias, but an edge_route is still present on the same alias"
        fi
    done < <(split_aliases_to_lines "$active_aliases")
done < <(tail -n +2 "$STATE_FILE")

if [ "$SKIP_SYNC" = "false" ]; then
    echo "Step 1/3: sync operator state to active orchestration node"
    invoke_sync
    if [ "$SKIP_STANDBY_SYNC" = "false" ]; then
        invoke_standby_sync "$standby_orchestration_aliases"
    else
        echo "Step 1b/3: standby orchestration sync skipped by --skip-standby-sync"
    fi
else
    echo "Step 1/3: sync skipped by --skip-sync"
    echo "Step 1b/3: standby orchestration sync skipped because sync is skipped"
fi

echo ""
echo "Step 2/3: rollout services from state.csv"
summary=()
planned_services=()
processed_service_actions=()
reseeded_vpn_edge_aliases=()

if [ "${#edge_route_removal_aliases[@]}" -gt 0 ]; then
    echo ""
    echo "Step 2a/3: remove absent edge routes through edge_haproxy before stopping backends"
    if [ -n "$ONLY_SERVICE" ] && [ "$ONLY_SERVICE" != "edge_haproxy" ]; then
        echo "Skipped edge route removal because --only-service $ONLY_SERVICE was requested"
    else
        ensure_service_plan "edge_haproxy"
        for alias in "${edge_route_removal_aliases[@]}"; do
            invoke_service_apply_dry_run "edge_haproxy" "$alias" "edge_haproxy route removal on $alias"
            echo "edge_haproxy route removal on $alias: apply queued"
            invoke_service_remote "edge_haproxy" apply "$alias"
            add_unique_to_array processed_service_actions "edge_haproxy|present|$alias"
            summary+=("edge_haproxy routes $alias: removed absent routes")
        done
    fi
fi

process_service_rows() {
    local desired_state="$1"
    local service_filter="$2"
    while IFS=, read -r kind name _ansible_group active_aliases candidate_aliases _old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    active_aliases="${active_aliases//$'\r'/}"
    candidate_aliases="${candidate_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ "$kind" = "service" ] || continue
    [ "$row_state" = "$desired_state" ] || continue
    if [ -n "$ONLY_SERVICE" ] && [ "$name" != "$ONLY_SERVICE" ]; then
        continue
    fi
    case "$service_filter" in
        all) ;;
        non-edge-haproxy) [ "$name" != "edge_haproxy" ] || continue ;;
        edge-haproxy) [ "$name" = "edge_haproxy" ] || continue ;;
        *) fail "Unknown service filter: $service_filter" ;;
    esac
    [ -z "$extra" ] || fail "state.csv row for service $name has too many columns"

    case "$row_state" in
        present|absent|purged) ;;
        *) fail "$name state must be one of: present, absent, purged" ;;
    esac
    case "$name" in
        edge_haproxy|vpn_edge|vpn_cascade|policy_gateway|edge_candidate_collector|edge_banlist|postgres_runtime|softether_l3_vps|platform_networks|host_resources|platform_router) ;;
        *)
            echo "$name: not implemented yet; skipped"
            summary+=("$name: skipped not implemented")
            continue
            ;;
    esac

    echo ""
    echo "Service: $name"
    echo "State:   $row_state"
    ensure_service_plan "$name"

    if [ "$name" = "vpn_cascade" ] && [ "$row_state" = "present" ]; then
        active_aliases="$(order_vpn_cascade_aliases "$active_aliases")"
    fi

    target_aliases="$active_aliases"
    if { [ "$name" = "postgres_runtime" ] || [ "$name" = "softether_l3_vps" ] || [ "$name" = "platform_networks" ] || [ "$name" = "platform_router" ]; } && [ -n "$candidate_aliases" ]; then
        target_aliases="$(append_aliases_unique "$target_aliases" "$candidate_aliases")"
    fi

    mapfile -t aliases < <(split_aliases_to_lines "$target_aliases")
    if [ "${#aliases[@]}" -eq 0 ]; then
        if [ "$row_state" = "present" ]; then
            fail "$name has state=present but active_aliases is empty"
        fi
        echo "$name: no active_aliases for state=$row_state; no-op"
        summary+=("$name: no-op")
        continue
    fi

    for alias in "${aliases[@]}"; do
        action_key="$name|$row_state|$alias"
        for processed in "${processed_service_actions[@]}"; do
            if [ "$processed" = "$action_key" ]; then
                echo "$name on $alias: duplicate state row for state=$row_state; skipped"
                continue 2
            fi
        done
        processed_service_actions+=("$action_key")
        case "$row_state" in
            present)
                invoke_service_apply_dry_run "$name" "$alias" "$name on $alias"
                echo "$name on $alias: apply queued"
                invoke_service_remote "$name" apply "$alias"
                invoke_postcheck "$name" "$row_state" "$alias"
                summary+=("$name $alias: present")
                if [ "$name" = "vpn_edge" ] && array_contains reseed_vpn_edge_aliases "$alias"; then
                    invoke_vpn_edge_reseed "$alias"
                fi
                ;;
            absent)
                echo "$name on $alias: absent queued"
                invoke_service_remote "$name" absent "$alias"
                invoke_postcheck "$name" "$row_state" "$alias"
                summary+=("$name $alias: absent")
                ;;
            purged)
                echo "$name on $alias: purge queued"
                invoke_service_remote "$name" purge "$alias" false true
                invoke_postcheck "$name" "$row_state" "$alias"
                summary+=("$name $alias: purged")
                ;;
        esac
    done
done < <(tail -n +2 "$STATE_FILE")
}

process_service_rows present non-edge-haproxy
process_service_rows present edge-haproxy
process_service_rows absent non-edge-haproxy
process_service_rows purged non-edge-haproxy
process_service_rows absent edge-haproxy
process_service_rows purged edge-haproxy

if [ "${#edge_route_apply_aliases[@]}" -gt 0 ]; then
    echo ""
    echo "Step 2b/3: apply edge route rendering through edge_haproxy"
    if [ -n "$ONLY_SERVICE" ] && [ "$ONLY_SERVICE" != "edge_haproxy" ]; then
        echo "Skipped edge route apply because --only-service $ONLY_SERVICE was requested"
    else
        for alias in "${edge_route_apply_aliases[@]}"; do
            already_applied="false"
            for processed in "${processed_service_actions[@]}"; do
                if [ "$processed" = "edge_haproxy|present|$alias" ]; then
                    already_applied="true"
                    break
                fi
            done
            if [ "$already_applied" = "true" ]; then
                echo "edge_haproxy routes on $alias: already applied by edge_haproxy service apply"
                continue
            fi
            invoke_service_apply_dry_run "edge_haproxy" "$alias" "edge_haproxy routes on $alias"
            echo "edge_haproxy routes on $alias: apply queued"
            invoke_service_remote "edge_haproxy" apply "$alias"
            summary+=("edge_haproxy routes $alias: applied")
        done
    fi
fi

if [ -z "$ONLY_SERVICE" ] || [ "$ONLY_SERVICE" = "vpn_edge" ]; then
    for alias in "${reseed_vpn_edge_aliases[@]}"; do
        invoke_vpn_edge_reseed "$alias"
    done
elif [ "${#reseed_vpn_edge_aliases[@]}" -gt 0 ]; then
    echo "Skipped vpn_edge reseed because --only-service $ONLY_SERVICE was requested"
fi

echo ""
echo "Step 3/3: summary"
for item in "${summary[@]}"; do
    echo "  $item"
done
echo "Rollout from state completed."
