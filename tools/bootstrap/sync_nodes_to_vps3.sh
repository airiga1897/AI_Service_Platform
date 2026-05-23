#!/usr/bin/env bash

set -euo pipefail

EXPECTED_CSV_HEADER="current_alias,endpoint,connection,ansible_group,roles,root_password"
EXPECTED_STATE_CSV_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
VPS3_ALIAS="vps3"
SSH_USER="useradmin"
SSH_KEY_FILE="./operator/vps3/admin_key"
REMOTE_NODES_FILE="/tmp/ai-service-platform.nodes.csv"
REMOTE_STATE_FILE="/tmp/ai-service-platform.state.csv"
SOFTETHER_DIR="./operator/softether"
REMOTE_SOFTETHER_DIR="/tmp/ai-service-platform.softether"
REMOTE_PREPARE_SCRIPT="/opt/ai-service-platform/tools/bootstrap/prepare_vps3_inventory.sh"
VERIFY_CONTROL_SCRIPT="tools/bootstrap/verify_control_node.sh"
REMOTE_VERIFY_SCRIPT="/opt/ai-service-platform/tools/bootstrap/verify_control_node.sh"
REMOTE_VERIFY_TEMP="/tmp/ai-service-platform.verify_control_node.sh"
INCLUDE_ALIASES=""
RUN_VERIFY="true"

usage() {
    cat <<'USAGE'
Usage:
  bash tools/bootstrap/sync_nodes_to_vps3.sh \
    --nodes-file ./operator/nodes.csv \
    --ssh-key-file ./operator/vps3/admin_key

Options:
  --nodes-file PATH          Operator nodes.csv. Default: ./operator/nodes.csv
  --state-file PATH          Operator state.csv. Default: ./operator/state.csv
  --vps3-alias VALUE         Alias for management VPS. Default: vps3
  --ssh-user VALUE           SSH user for VPS3 sync. Default: useradmin
  --ssh-key-file PATH        SSH private key for SSH user. Default: ./operator/vps3/admin_key
  --remote-nodes-file PATH   Remote temporary CSV path. Default: /tmp/ai-service-platform.nodes.csv
  --softether-dir PATH       Optional operator SoftEther secret directory.
                             Default: ./operator/softether
  --remote-prepare-script PATH
                             Remote prepare script path.
  --verify-control-script PATH
                             Local verify_control_node.sh path.
                             Default: tools/bootstrap/verify_control_node.sh
  --remote-verify-script PATH
                             Remote verify script path.
  --skip-verify              Sync and inventory only; do not run post-bootstrap verify.
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
        --state-file)
            STATE_FILE="${2:-}"
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
        --softether-dir)
            SOFTETHER_DIR="${2:-}"
            shift 2
            ;;
        --remote-prepare-script)
            REMOTE_PREPARE_SCRIPT="${2:-}"
            shift 2
            ;;
        --verify-control-script)
            VERIFY_CONTROL_SCRIPT="${2:-}"
            shift 2
            ;;
        --remote-verify-script)
            REMOTE_VERIFY_SCRIPT="${2:-}"
            shift 2
            ;;
        --skip-verify)
            RUN_VERIFY="false"
            shift
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
if [ -n "$STATE_FILE" ]; then
    require_file "$STATE_FILE" "--state-file"
fi
if [ "$RUN_VERIFY" = "true" ]; then
    require_file "$VERIFY_CONTROL_SCRIPT" "--verify-control-script"
fi

first_line="$(head -n 1 "$NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_CSV_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_CSV_HEADER"
if [ -n "$STATE_FILE" ]; then
    state_first_line="$(head -n 1 "$STATE_FILE" | tr -d '\r')"
    [ "$state_first_line" = "$EXPECTED_STATE_CSV_HEADER" ] || fail "state.csv header must be exactly: $EXPECTED_STATE_CSV_HEADER"
fi

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
if [ -n "$STATE_FILE" ]; then
    echo "Syncing state.csv to $remote"
    scp -i "$SSH_KEY_FILE" "$STATE_FILE" "$remote:$REMOTE_STATE_FILE"
fi
if [ -d "$SOFTETHER_DIR" ]; then
    echo "Syncing SoftEther operator secret directory to $remote"
    ssh -i "$SSH_KEY_FILE" "$remote" "rm -rf '$REMOTE_SOFTETHER_DIR'"
    scp -r -i "$SSH_KEY_FILE" "$SOFTETHER_DIR" "$remote:$REMOTE_SOFTETHER_DIR"
fi
if [ "$RUN_VERIFY" = "true" ]; then
    echo "Syncing verify_control_node.sh to $remote"
    scp -i "$SSH_KEY_FILE" "$VERIFY_CONTROL_SCRIPT" "$remote:$REMOTE_VERIFY_TEMP"
fi

prepare_command="sudo bash '$REMOTE_PREPARE_SCRIPT' --source-nodes-file '$REMOTE_NODES_FILE' --skip-check"
if [ -n "$STATE_FILE" ]; then
    prepare_command="$prepare_command --source-state-file '$REMOTE_STATE_FILE'"
fi
if [ -n "$INCLUDE_ALIASES" ]; then
    prepare_command="$prepare_command --include '$INCLUDE_ALIASES'"
fi
remote_command="set -e; $prepare_command; rm -f '$REMOTE_NODES_FILE' '$REMOTE_STATE_FILE'"
if [ -d "$SOFTETHER_DIR" ]; then
    softether_command="sudo mkdir -p /opt/ai-service-platform/operator; if [ -d '$REMOTE_SOFTETHER_DIR/softether' ]; then sudo rm -rf /opt/ai-service-platform/operator/softether && sudo cp -a '$REMOTE_SOFTETHER_DIR/softether' /opt/ai-service-platform/operator/softether; else sudo rm -rf /opt/ai-service-platform/operator/softether && sudo cp -a '$REMOTE_SOFTETHER_DIR' /opt/ai-service-platform/operator/softether; fi;"
    remote_command="set -e; $softether_command $prepare_command; rm -rf '$REMOTE_SOFTETHER_DIR'; rm -f '$REMOTE_NODES_FILE' '$REMOTE_STATE_FILE'"
fi
if [ "$RUN_VERIFY" = "true" ]; then
    verify_command="sudo mkdir -p \"\$(dirname '$REMOTE_VERIFY_SCRIPT')\"; sudo install -m 700 '$REMOTE_VERIFY_TEMP' '$REMOTE_VERIFY_SCRIPT'; sudo bash '$REMOTE_VERIFY_SCRIPT';"
    if [ -d "$SOFTETHER_DIR" ]; then
        remote_command="set -e; $softether_command $prepare_command; $verify_command rm -rf '$REMOTE_SOFTETHER_DIR'; rm -f '$REMOTE_NODES_FILE' '$REMOTE_STATE_FILE' '$REMOTE_VERIFY_TEMP'"
    else
        remote_command="set -e; $prepare_command; $verify_command rm -f '$REMOTE_NODES_FILE' '$REMOTE_STATE_FILE' '$REMOTE_VERIFY_TEMP'"
    fi
fi

echo "Running VPS3 inventory preparation"
ssh -i "$SSH_KEY_FILE" "$remote" "$remote_command"
if [ "$RUN_VERIFY" = "true" ]; then
    echo "[OK] VPS3 nodes.csv, inventory.ini, and verification are complete"
else
    echo "[OK] VPS3 nodes.csv and inventory.ini are in sync; verify skipped"
fi
