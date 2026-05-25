#!/usr/bin/env bash

set -euo pipefail

SERVICE="${1:-}"
ACTION="${2:-}"
NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
INVENTORY="inventory.ini"
PLAYBOOK=""
LIMIT=""
CHECK="false"
CONFIRM_PURGE="false"
EXPECTED_HEADER="current_alias,endpoint,connection,root_password"
EXPECTED_STATE_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"

usage() {
    cat <<'USAGE'
Usage:
  bash tools/services/service.sh edge_haproxy plan [options]
  bash tools/services/service.sh edge_haproxy apply [options]
  bash tools/services/service.sh edge_haproxy absent [options]
  bash tools/services/service.sh edge_haproxy purge --confirm-purge [options]
  bash tools/services/service.sh vpn_edge plan [options]
  bash tools/services/service.sh vpn_edge apply [options]
  bash tools/services/service.sh vpn_edge absent [options]
  bash tools/services/service.sh vpn_edge purge --confirm-purge [options]
  bash tools/services/service.sh vpn_edge reseed --limit ALIAS [options]

Options:
  --nodes-file PATH      Operator nodes.csv. Default: ./operator/nodes.csv
  --state-file PATH      Operator state.csv. Default: ./operator/state.csv
  --inventory PATH       Generated Ansible inventory. Default: inventory.ini
  --playbook PATH        Override service playbook.
  --limit VALUE          Ansible --limit. Default: service ansible_group.
  --check                Pass --check to ansible-playbook.
  --confirm-purge        Required for purge.
  -h, --help             Show help.
USAGE
}

fail() {
    echo "[ERROR] $1" >&2
    exit 1
}

split_aliases_to_lines() {
    local aliases="$1"
    local old_ifs="$IFS"
    local alias_item
    IFS=+
    for alias_item in $aliases; do
        IFS="$old_ifs"
        if [ -n "$alias_item" ]; then
            printf '%s\n' "$alias_item"
        fi
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

service_playbook() {
    case "$1" in
        edge_haproxy) echo "infra/ansible/edge_haproxy.yml" ;;
        vpn_edge) echo "infra/ansible/vpn.yml" ;;
        *) return 1 ;;
    esac
}

service_extra_vars() {
    local service="$1"
    local state="$2"
    local purge="$3"
    local reseed="${4:-false}"
    case "$service" in
        edge_haproxy)
            printf '%s\n' "-e" "edge_haproxy_state=$state" "-e" "edge_haproxy_purge_data=$purge"
            ;;
        vpn_edge)
            printf '%s\n' "-e" "vpn_state=$state" "-e" "vpn_purge_data=$purge" "-e" "vpn_reseed_config=$reseed"
            ;;
        *)
            return 1
            ;;
    esac
}

run_ansible_playbook() {
    if [ "$(id -u)" -eq 0 ]; then
        sudo -u ansible ansible-playbook "$@"
    else
        ansible-playbook "$@"
    fi
}

if [ "$SERVICE" = "-h" ] || [ "$SERVICE" = "--help" ]; then
    usage
    exit 0
fi

if [ "$SERVICE" = "vpn" ]; then
    fail "Unsupported service 'vpn'. Use canonical service name: vpn_edge"
fi
if [ "$SERVICE" = "vpn_cascade" ]; then
    fail "Service 'vpn_cascade' is reserved for future site-to-site/cascade rollout and is not implemented yet."
fi
case "$SERVICE" in
    edge_haproxy|vpn_edge) ;;
    *) fail "Unsupported service '$SERVICE'. Supported now: edge_haproxy, vpn_edge. Reserved: vpn_cascade." ;;
esac
case "$ACTION" in
    plan|apply|absent|purge|reseed) ;;
    *) usage; fail "Action must be one of: plan, apply, absent, purge, reseed" ;;
esac
shift 2

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
        --inventory)
            INVENTORY="${2:-}"
            shift 2
            ;;
        --playbook)
            PLAYBOOK="${2:-}"
            shift 2
            ;;
        --limit)
            LIMIT="${2:-}"
            shift 2
            ;;
        --check)
            CHECK="true"
            shift
            ;;
        --confirm-purge)
            CONFIRM_PURGE="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

[ -f "$NODES_FILE" ] || fail "nodes file not found: $NODES_FILE"
[ -f "$STATE_FILE" ] || fail "state file not found: $STATE_FILE"
first_line="$(head -n 1 "$NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_HEADER"
state_first_line="$(head -n 1 "$STATE_FILE" | tr -d '\r')"
[ "$state_first_line" = "$EXPECTED_STATE_HEADER" ] || fail "state.csv header must be exactly: $EXPECTED_STATE_HEADER"

service_found="false"
service_group=""
service_active_aliases=""
service_candidate_aliases=""
service_old_aliases=""
service_row_state=""
service_match_count=0
service_total_count=0
service_plan_rows=()
while IFS=, read -r kind name ansible_group active_aliases candidate_aliases old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    ansible_group="${ansible_group//$'\r'/}"
    active_aliases="${active_aliases//$'\r'/}"
    candidate_aliases="${candidate_aliases//$'\r'/}"
    old_aliases="${old_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ "$kind" = "service" ] && [ "$name" = "$SERVICE" ] || continue
    [ -z "$extra" ] || fail "state.csv $SERVICE row has too many columns"
    service_total_count=$((service_total_count + 1))
    service_plan_rows+=("$ansible_group|$active_aliases|$candidate_aliases|$old_aliases|$row_state")

    if [ -n "$LIMIT" ]; then
        alias_in_list "$LIMIT" "$active_aliases" || continue
    elif [ "$service_total_count" -gt 1 ]; then
        continue
    fi

    service_found="true"
    service_match_count=$((service_match_count + 1))
    service_group="$ansible_group"
    service_active_aliases="$active_aliases"
    service_candidate_aliases="$candidate_aliases"
    service_old_aliases="$old_aliases"
    service_row_state="$row_state"
done < <(tail -n +2 "$STATE_FILE")

if [ "$ACTION" = "plan" ] && [ -z "$LIMIT" ]; then
    [ "$service_total_count" -gt 0 ] || fail "state.csv must contain a service row for $SERVICE"
    echo "Service: $SERVICE"
    echo "State file: $STATE_FILE"
    echo "Nodes file: $NODES_FILE"
    echo ""
    for row in "${service_plan_rows[@]}"; do
        IFS='|' read -r plan_group plan_active_aliases plan_candidate_aliases plan_old_aliases plan_row_state <<< "$row"
        echo "Service state: $plan_row_state"
        echo "Ansible group: $plan_group"
        tail -n +2 "$NODES_FILE" | while IFS=, read -r current_alias _endpoint _connection _root_password _extra || [ -n "${current_alias:-}" ]; do
            current_alias="${current_alias//$'\r'/}"
            [ -n "$current_alias" ] || continue
            if [ "$plan_row_state" = "present" ] && alias_in_list "$current_alias" "$plan_active_aliases"; then
                echo "$current_alias: desired present"
            else
                echo "$current_alias: desired absent"
            fi
        done
        if [ -n "$plan_candidate_aliases" ]; then
            echo "Candidates: $plan_candidate_aliases"
        fi
        if [ -n "$plan_old_aliases" ]; then
            echo "Old: $plan_old_aliases"
        fi
        echo ""
    done
    exit 0
fi

[ "$service_total_count" -gt 0 ] || fail "state.csv must contain a service row for $SERVICE"
[ "$service_found" = "true" ] || fail "state.csv must contain a service row for $SERVICE matching --limit ${LIMIT:-<none>}"
[ "$service_match_count" -eq 1 ] || fail "state.csv has multiple $SERVICE rows matching --limit ${LIMIT:-<none>}; keep one target row per alias"
case "$service_row_state" in
    present|absent|purged) ;;
    *) fail "$SERVICE state must be one of: present, absent, purged" ;;
esac
[ -n "$service_group" ] || fail "$SERVICE ansible_group is empty in state.csv"

if [ "$ACTION" = "plan" ]; then
    echo "Service: $SERVICE"
    echo "State file: $STATE_FILE"
    echo "Service state: $service_row_state"
    echo "Ansible group: $service_group"
    echo "Nodes file: $NODES_FILE"
    echo ""
    tail -n +2 "$NODES_FILE" | while IFS=, read -r current_alias _endpoint _connection _root_password _extra || [ -n "${current_alias:-}" ]; do
        current_alias="${current_alias//$'\r'/}"
        [ -n "$current_alias" ] || continue
        if [ "$service_row_state" = "present" ] && alias_in_list "$current_alias" "$service_active_aliases"; then
            echo "$current_alias: desired present"
        else
            echo "$current_alias: desired absent"
        fi
    done
    if [ -n "$service_candidate_aliases" ]; then
        echo ""
        echo "Candidates: $service_candidate_aliases"
    fi
    if [ -n "$service_old_aliases" ]; then
        echo "Old: $service_old_aliases"
    fi
    exit 0
fi

command -v ansible-playbook >/dev/null 2>&1 || fail "ansible-playbook not found in PATH"
[ -f "$INVENTORY" ] || fail "inventory not found: $INVENTORY"
if [ -z "$PLAYBOOK" ]; then
    PLAYBOOK="$(service_playbook "$SERVICE")" || fail "No default playbook for service: $SERVICE"
fi
[ -f "$PLAYBOOK" ] || fail "playbook not found: $PLAYBOOK"

if [ "$ACTION" = "purge" ] && [ "$CONFIRM_PURGE" != "true" ]; then
    fail "purge requires --confirm-purge"
fi
if [ "$ACTION" = "reseed" ] && [ "$SERVICE" != "vpn_edge" ]; then
    fail "reseed is supported only for vpn_edge"
fi
if [ "$ACTION" = "reseed" ] && [ -z "$LIMIT" ]; then
    fail "vpn_edge reseed requires --limit ALIAS"
fi
if [ "$ACTION" = "reseed" ] && [ "$service_row_state" != "present" ]; then
    fail "vpn_edge reseed requires state=present in $STATE_FILE"
fi
if [ "$ACTION" = "apply" ] && [ "$service_row_state" != "present" ]; then
    fail "$SERVICE apply requires state=present in $STATE_FILE"
fi
if [ "$ACTION" = "apply" ] && [ -z "$service_active_aliases" ]; then
    fail "No active aliases for $SERVICE found in $STATE_FILE"
fi

service_state="present"
service_purge_data="false"
service_reseed_config="false"
if [ "$ACTION" = "absent" ] || [ "$ACTION" = "purge" ]; then
    service_state="absent"
fi
if [ "$ACTION" = "purge" ]; then
    service_purge_data="true"
fi
if [ "$ACTION" = "reseed" ]; then
    service_reseed_config="true"
fi

limit_args=(--limit "${LIMIT:-$service_group}")
check_args=()
if [ "$CHECK" = "true" ]; then
    check_args=(--check)
fi

mapfile -t extra_vars < <(service_extra_vars "$SERVICE" "$service_state" "$service_purge_data" "$service_reseed_config")

set -x
run_ansible_playbook \
    -i "$INVENTORY" \
    "$PLAYBOOK" \
    "${extra_vars[@]}" \
    "${limit_args[@]}" \
    "${check_args[@]}"
