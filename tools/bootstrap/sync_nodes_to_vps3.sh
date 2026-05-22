#!/usr/bin/env bash

set -euo pipefail

EXPECTED_CSV_HEADER="current_alias,endpoint,connection,ansible_group,roles,root_password"
NODES_FILE="./operator/nodes.csv"
VPS3_ALIAS="vps3"
SSH_USER="useradmin"
SSH_KEY_FILE="./operator/vps3/admin_key"
REMOTE_NODES_FILE="/tmp/ai-service-platform.nodes.csv"
REMOTE_PREPARE_SCRIPT="/opt/ai-service-platform/tools/bootstrap/prepare_vps3_inventory.sh"
INCLUDE_ALIASES=""

usage() {
    cat <<'USAGE'
Usage:
  bash tools/bootstrap/sync_nodes_to_vps3.sh \
    --nodes-file ./operator/nodes.csv \
    --ssh-key-file ./operator/vps3/admin_key

Options:
  --nodes-file PATH          Operator nodes.csv. Default: ./operator/nodes.csv
  --vps3-alias VALUE         Alias for management VPS. Default: vps3
  --ssh-user VALUE           SSH user for VPS3 sync. Default: useradmin
  --ssh-key-file PATH        SSH private key for SSH user. Default: ./operator/vps3/admin_key
  --remote-nodes-file PATH   Remote temporary CSV path. Default: /tmp/ai-service-platform.nodes.csv
  --remote-prepare-script PATH
                             Remote prepare script path.
  --include LIST             Optional aliases to include when generating inventory.
  -h, --help                 Show this help.
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

while [ "$#" -gt 0 ]; do
    case "$1" in
        --nodes-file)
            NODES_FILE="${2:-}"
            shift 2
            ;;
        --vps3-alias)
            VPS3_ALIAS="${2:-}"
            shift 2
            ;;
        --ssh-user)
            SSH_USER="${2:-}"
            shift 2
            ;;
        --ssh-key-file)
            SSH_KEY_FILE="${2:-}"
            shift 2
            ;;
        --remote-nodes-file)
            REMOTE_NODES_FILE="${2:-}"
            shift 2
            ;;
        --remote-prepare-script)
            REMOTE_PREPARE_SCRIPT="${2:-}"
            shift 2
            ;;
        --include)
            INCLUDE_ALIASES="${2:-}"
            shift 2
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

require_file "$NODES_FILE" "--nodes-file"
require_file "$SSH_KEY_FILE" "--ssh-key-file"

first_line="$(head -n 1 "$NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_CSV_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_CSV_HEADER"

vps3_endpoint=""
vps3_connection=""
while IFS=, read -r current_alias endpoint connection _ansible_group _roles _root_password extra || [ -n "${current_alias:-}" ]; do
    current_alias="${current_alias//$'\r'/}"
    endpoint="${endpoint//$'\r'/}"
    connection="${connection//$'\r'/}"
    extra="${extra//$'\r'/}"

    [ "$current_alias" != "$EXPECTED_CSV_HEADER" ] || continue
    [ -z "$extra" ] || fail "nodes.csv row for $current_alias has too many columns"

    if [ "$current_alias" = "$VPS3_ALIAS" ]; then
        vps3_endpoint="$endpoint"
        vps3_connection="$connection"
        break
    fi
done < "$NODES_FILE"

[ -n "$vps3_endpoint" ] || fail "VPS3 alias not found in nodes file: $VPS3_ALIAS"
if [ "$vps3_endpoint" = "local" ] || [ "$vps3_connection" = "local" ]; then
    fail "Cannot sync to VPS3 when endpoint/connection is local in operator nodes.csv: $VPS3_ALIAS"
fi

sanitized_nodes="$(mktemp)"
trap 'rm -f "$sanitized_nodes"' EXIT

{
    echo "$EXPECTED_CSV_HEADER"
    tail -n +2 "$NODES_FILE" | while IFS=, read -r current_alias endpoint connection ansible_group roles _root_password extra || [ -n "${current_alias:-}" ]; do
        current_alias="${current_alias//$'\r'/}"
        endpoint="${endpoint//$'\r'/}"
        connection="${connection//$'\r'/}"
        ansible_group="${ansible_group//$'\r'/}"
        roles="${roles//$'\r'/}"
        extra="${extra//$'\r'/}"

        [ -n "$current_alias" ] || continue
        [ -z "$extra" ] || fail "nodes.csv row for $current_alias has too many columns"
        printf '%s,%s,%s,%s,%s,\n' "$current_alias" "$endpoint" "$connection" "$ansible_group" "$roles"
    done
} > "$sanitized_nodes"

remote="$SSH_USER@$vps3_endpoint"
echo "Syncing sanitized nodes.csv to $remote"
scp -i "$SSH_KEY_FILE" "$sanitized_nodes" "$remote:$REMOTE_NODES_FILE"

prepare_command="sudo bash '$REMOTE_PREPARE_SCRIPT' --source-nodes-file '$REMOTE_NODES_FILE'"
if [ -n "$INCLUDE_ALIASES" ]; then
    prepare_command="$prepare_command --include '$INCLUDE_ALIASES'"
fi
remote_command="set -e; $prepare_command; rm -f '$REMOTE_NODES_FILE'"

echo "Running VPS3 inventory preparation"
ssh -i "$SSH_KEY_FILE" "$remote" "$remote_command"
echo "[OK] VPS3 nodes.csv and inventory.ini are in sync"
