#!/usr/bin/env bash

set -euo pipefail

NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
OPERATOR_DIR="./operator"
CONTROL_ROLE="orchestration"
CONTROL_ALIAS=""
SYNC_SCRIPT="tools/bootstrap/sync_to_orchestration.sh"
SERVICE_REMOTE_SCRIPT="tools/services/service_remote.sh"
AUTO_ACCEPT_HOST_KEY="false"
SKIP_SYNC="false"
SKIP_POSTCHECK="false"

EXPECTED_HEADER="current_alias,endpoint,connection,root_password"
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
  --auto-accept-host-key  Refresh known_hosts during sync.
  --skip-sync             Skip sync/verify step.
  --skip-postcheck        Skip service postcheck placeholders.
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
    bash "$SERVICE_REMOTE_SCRIPT" "${args[@]}"
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
            echo "[OK] edge_haproxy postcheck placeholder completed for $alias"
            ;;
        edge_haproxy:absent)
            echo "[OK] edge_haproxy absent requested for $alias; config/data should remain on target"
            ;;
        edge_haproxy:purged)
            echo "[OK] edge_haproxy purge requested for $alias; runtime directory removal is handled by the role"
            ;;
        *)
            echo "No postcheck implemented yet for $service on $alias"
            ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --nodes-file) NODES_FILE="${2:-}"; shift 2 ;;
        --state-file) STATE_FILE="${2:-}"; shift 2 ;;
        --operator-dir) OPERATOR_DIR="${2:-}"; shift 2 ;;
        --control-role) CONTROL_ROLE="${2:-}"; shift 2 ;;
        --control-alias) CONTROL_ALIAS="${2:-}"; shift 2 ;;
        --sync-script) SYNC_SCRIPT="${2:-}"; shift 2 ;;
        --service-remote-script) SERVICE_REMOTE_SCRIPT="${2:-}"; shift 2 ;;
        --auto-accept-host-key|--refresh-known-hosts) AUTO_ACCEPT_HOST_KEY="true"; shift ;;
        --skip-sync) SKIP_SYNC="true"; shift ;;
        --skip-postcheck) SKIP_POSTCHECK="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

require_file "$NODES_FILE" "--nodes-file"
require_file "$STATE_FILE" "--state-file"
require_file "$SYNC_SCRIPT" "--sync-script"
require_file "$SERVICE_REMOTE_SCRIPT" "--service-remote-script"

first_line="$(head -n 1 "$NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_HEADER"
state_first_line="$(head -n 1 "$STATE_FILE" | tr -d '\r')"
[ "$state_first_line" = "$EXPECTED_STATE_HEADER" ] || fail "state.csv header must be exactly: $EXPECTED_STATE_HEADER"

edge_haproxy_aliases=""
vpn_edge_aliases=""
while IFS=, read -r kind name _ansible_group active_aliases _candidate_aliases _old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    active_aliases="${active_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ -z "$kind" ] && continue
    [ -z "$extra" ] || fail "state.csv row for $name has too many columns"
    if [ "$kind" = "service" ] && [ "$row_state" = "present" ]; then
        [ "$name" = "edge_haproxy" ] && edge_haproxy_aliases="$active_aliases"
        [ "$name" = "vpn_edge" ] && vpn_edge_aliases="$active_aliases"
    fi
done < <(tail -n +2 "$STATE_FILE")

edge_route_apply_aliases=()
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
    [ "$row_state" = "present" ] || continue
    mapfile -t route_aliases < <(split_aliases_to_lines "$active_aliases")
    [ "${#route_aliases[@]}" -gt 0 ] || fail "edge_route $name has state=present but active_aliases is empty"
    for alias in "${route_aliases[@]}"; do
        alias_in_list "$alias" "$edge_haproxy_aliases" || fail "edge_route $name is present on $alias, but service edge_haproxy is not present on the same alias"
        if [ "$name" = "vpn_ingress" ]; then
            alias_in_list "$alias" "$vpn_edge_aliases" || fail "edge_route vpn_ingress is present on $alias, but service vpn_edge is not present on the same alias"
        fi
        add_unique_alias "$alias"
    done
done < <(tail -n +2 "$STATE_FILE")

if [ "$SKIP_SYNC" = "false" ]; then
    echo "Step 1/3: sync operator state to active orchestration node"
    invoke_sync
else
    echo "Step 1/3: sync skipped by --skip-sync"
fi

echo ""
echo "Step 2/3: rollout services from state.csv"
summary=()
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
    case "$name" in
        vpn_cascade)
            echo "$name: reserved/not implemented; skipped"
            summary+=("$name: skipped reserved")
            continue
            ;;
        edge_haproxy|vpn_edge) ;;
        *)
            echo "$name: not implemented yet; skipped"
            summary+=("$name: skipped not implemented")
            continue
            ;;
    esac

    echo ""
    echo "Service: $name"
    echo "State:   $row_state"
    invoke_service_remote "$name" plan ""

    mapfile -t aliases < <(split_aliases_to_lines "$active_aliases")
    if [ "${#aliases[@]}" -eq 0 ]; then
        if [ "$row_state" = "present" ]; then
            fail "$name has state=present but active_aliases is empty"
        fi
        echo "$name: no active_aliases for state=$row_state; no-op"
        summary+=("$name: no-op")
        continue
    fi

    for alias in "${aliases[@]}"; do
        case "$row_state" in
            present)
                echo "$name on $alias: dry-run"
                invoke_service_remote "$name" apply "$alias" true
                echo "$name on $alias: apply"
                invoke_service_remote "$name" apply "$alias"
                invoke_postcheck "$name" "$row_state" "$alias"
                summary+=("$name $alias: present")
                ;;
            absent)
                echo "$name on $alias: absent"
                invoke_service_remote "$name" absent "$alias"
                invoke_postcheck "$name" "$row_state" "$alias"
                summary+=("$name $alias: absent")
                ;;
            purged)
                echo "$name on $alias: purge"
                invoke_service_remote "$name" purge "$alias" false true
                invoke_postcheck "$name" "$row_state" "$alias"
                summary+=("$name $alias: purged")
                ;;
        esac
    done
done < <(tail -n +2 "$STATE_FILE")

if [ "${#edge_route_apply_aliases[@]}" -gt 0 ]; then
    echo ""
    echo "Step 2b/3: apply edge route rendering through edge_haproxy"
    for alias in "${edge_route_apply_aliases[@]}"; do
        echo "edge_haproxy routes on $alias: dry-run"
        invoke_service_remote "edge_haproxy" apply "$alias" true
        echo "edge_haproxy routes on $alias: apply"
        invoke_service_remote "edge_haproxy" apply "$alias"
        summary+=("edge_haproxy routes $alias: applied")
    done
fi

echo ""
echo "Step 3/3: summary"
for item in "${summary[@]}"; do
    echo "  $item"
done
echo "Rollout from state completed."
