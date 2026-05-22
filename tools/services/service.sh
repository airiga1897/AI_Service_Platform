#!/usr/bin/env bash

set -euo pipefail

SERVICE="${1:-}"
ACTION="${2:-}"
NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
INVENTORY="inventory.ini"
PLAYBOOK="infra/ansible/vpn.yml"
LIMIT=""
CHECK="false"
CONFIRM_PURGE="false"
EXPECTED_HEADER="current_alias,endpoint,connection,ansible_group,roles,root_password"
EXPECTED_STATE_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"

usage() {
    cat <<'USAGE'
Usage:
  bash tools/services/service.sh vpn plan [options]
  bash tools/services/service.sh vpn apply [options]
  bash tools/services/service.sh vpn absent [options]
  bash tools/services/service.sh vpn purge --confirm-purge [options]

Options:
  --nodes-file PATH      Operator nodes.csv. Default: ./operator/nodes.csv
  --state-file PATH      Operator state.csv. Default: ./operator/state.csv
  --inventory PATH       Generated Ansible inventory. Default: inventory.ini
  --playbook PATH        Service playbook. Default: infra/ansible/vpn.yml
  --limit VALUE          Ansible --limit. Default: vpn_edges
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

if [ "$SERVICE" = "-h" ] || [ "$SERVICE" = "--help" ]; then
    usage
    exit 0
fi

[ "$SERVICE" = "vpn" ] || fail "Only service 'vpn' is supported now."
case "$ACTION" in
    plan|apply|absent|purge) ;;
    *) usage; fail "Action must be one of: plan, apply, absent, purge" ;;
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

vpn_found="false"
vpn_group=""
vpn_active_aliases=""
vpn_candidate_aliases=""
vpn_old_aliases=""
vpn_row_state=""
while IFS=, read -r kind name ansible_group active_aliases candidate_aliases old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    ansible_group="${ansible_group//$'\r'/}"
    active_aliases="${active_aliases//$'\r'/}"
    candidate_aliases="${candidate_aliases//$'\r'/}"
    old_aliases="${old_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ "$kind" = "service" ] && [ "$name" = "vpn" ] || continue
    [ -z "$extra" ] || fail "state.csv vpn row has too many columns"
    vpn_found="true"
    vpn_group="$ansible_group"
    vpn_active_aliases="$active_aliases"
    vpn_candidate_aliases="$candidate_aliases"
    vpn_old_aliases="$old_aliases"
    vpn_row_state="$row_state"
    break
done < <(tail -n +2 "$STATE_FILE")

[ "$vpn_found" = "true" ] || fail "state.csv must contain a service row for vpn"
case "$vpn_row_state" in
    present|absent|purged) ;;
    *) fail "vpn state must be one of: present, absent, purged" ;;
esac
[ -n "$vpn_group" ] || fail "vpn ansible_group is empty in state.csv"

if [ "$ACTION" = "plan" ]; then
    echo "Service: vpn"
    echo "State file: $STATE_FILE"
    echo "Service state: $vpn_row_state"
    echo "Ansible group: $vpn_group"
    echo "Nodes file: $NODES_FILE"
    echo ""
    tail -n +2 "$NODES_FILE" | while IFS=, read -r current_alias _endpoint _connection _group roles _root_password extra || [ -n "${current_alias:-}" ]; do
        current_alias="${current_alias//$'\r'/}"
        [ -n "$current_alias" ] || continue
        if [ "$vpn_row_state" = "present" ] && alias_in_list "$current_alias" "$vpn_active_aliases"; then
            echo "$current_alias: desired present"
        else
            echo "$current_alias: desired absent"
        fi
    done
    if [ -n "$vpn_candidate_aliases" ]; then
        echo ""
        echo "Candidates: $vpn_candidate_aliases"
    fi
    if [ -n "$vpn_old_aliases" ]; then
        echo "Old: $vpn_old_aliases"
    fi
    exit 0
fi

command -v ansible-playbook >/dev/null 2>&1 || fail "ansible-playbook not found in PATH"
[ -f "$INVENTORY" ] || fail "inventory not found: $INVENTORY"
[ -f "$PLAYBOOK" ] || fail "playbook not found: $PLAYBOOK"

if [ "$ACTION" = "purge" ] && [ "$CONFIRM_PURGE" != "true" ]; then
    fail "purge requires --confirm-purge"
fi
if [ "$ACTION" = "apply" ] && [ "$vpn_row_state" != "present" ]; then
    fail "vpn apply requires state=present in $STATE_FILE"
fi
if [ "$ACTION" = "apply" ] && [ -z "$vpn_active_aliases" ]; then
    fail "No active aliases for vpn found in $STATE_FILE"
fi

vpn_state="present"
vpn_purge_data="false"
if [ "$ACTION" = "absent" ] || [ "$ACTION" = "purge" ]; then
    vpn_state="absent"
fi
if [ "$ACTION" = "purge" ]; then
    vpn_purge_data="true"
fi

limit_args=(--limit "${LIMIT:-$vpn_group}")
check_args=()
if [ "$CHECK" = "true" ]; then
    check_args=(--check)
fi

set -x
ansible-playbook \
    -i "$INVENTORY" \
    "$PLAYBOOK" \
    -e "vpn_state=$vpn_state" \
    -e "vpn_purge_data=$vpn_purge_data" \
    "${limit_args[@]}" \
    "${check_args[@]}"
