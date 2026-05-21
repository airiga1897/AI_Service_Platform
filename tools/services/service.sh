#!/usr/bin/env bash

set -euo pipefail

SERVICE="${1:-}"
ACTION="${2:-}"
NODES_FILE="./operator/nodes.csv"
INVENTORY="inventory.ini"
PLAYBOOK="infra/ansible/vpn.yml"
LIMIT=""
CHECK="false"
CONFIRM_PURGE="false"
EXPECTED_HEADER="current_alias,endpoint,connection,ansible_group,roles,root_password"

usage() {
    cat <<'USAGE'
Usage:
  bash tools/services/service.sh vpn plan [options]
  bash tools/services/service.sh vpn apply [options]
  bash tools/services/service.sh vpn absent [options]
  bash tools/services/service.sh vpn purge --confirm-purge [options]

Options:
  --nodes-file PATH      Operator nodes.csv. Default: ./operator/nodes.csv
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

has_role() {
    local roles="$1"
    local wanted="$2"
    case "+$roles+" in
        *"+$wanted+"*) return 0 ;;
        *) return 1 ;;
    esac
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
first_line="$(head -n 1 "$NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_HEADER"

if [ "$ACTION" = "plan" ]; then
    echo "Service: vpn"
    echo "Desired role: vpn-edge"
    echo "Nodes file: $NODES_FILE"
    echo ""
    tail -n +2 "$NODES_FILE" | while IFS=, read -r current_alias _endpoint _connection _group roles _root_password extra || [ -n "${current_alias:-}" ]; do
        current_alias="${current_alias//$'\r'/}"
        roles="${roles//$'\r'/}"
        [ -n "$current_alias" ] || continue
        if has_role "$roles" "vpn-edge"; then
            echo "$current_alias: desired present"
        else
            echo "$current_alias: desired absent"
        fi
    done
    exit 0
fi

command -v ansible-playbook >/dev/null 2>&1 || fail "ansible-playbook not found in PATH"
[ -f "$INVENTORY" ] || fail "inventory not found: $INVENTORY"
[ -f "$PLAYBOOK" ] || fail "playbook not found: $PLAYBOOK"

if [ "$ACTION" = "purge" ] && [ "$CONFIRM_PURGE" != "true" ]; then
    fail "purge requires --confirm-purge"
fi

vpn_state="present"
vpn_purge_data="false"
if [ "$ACTION" = "absent" ] || [ "$ACTION" = "purge" ]; then
    vpn_state="absent"
fi
if [ "$ACTION" = "purge" ]; then
    vpn_purge_data="true"
fi

limit_args=(--limit "${LIMIT:-vpn_edges}")
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
