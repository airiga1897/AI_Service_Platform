#!/usr/bin/env bash

set -euo pipefail

EXPECTED_CSV_HEADER="current_alias,endpoint,connection,root_password"
EXPECTED_STATE_CSV_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
CONTROL_ROLE="orchestration"
CONTROL_ALIAS=""
SSH_USER="useradmin"
SSH_KEY_FILE=""
REMOTE_NODES_FILE="/tmp/ai-service-platform.nodes.csv"
REMOTE_STATE_FILE="/tmp/ai-service-platform.state.csv"
SOFTETHER_DIR="./operator/softether"
REMOTE_SOFTETHER_DIR="/tmp/ai-service-platform.softether"
HAPROXY_DIR="./operator/haproxy"
REMOTE_HAPROXY_DIR="/tmp/ai-service-platform.haproxy"
REMOTE_PREPARE_SCRIPT="/opt/ai-service-platform/tools/bootstrap/prepare_orchestration_inventory.sh"
CREATE_INVENTORY_SCRIPT="tools/bootstrap/create_inventory.sh"
PREPARE_INVENTORY_SCRIPT="tools/bootstrap/prepare_orchestration_inventory.sh"
VERIFY_CONTROL_SCRIPT="tools/bootstrap/verify_control_node.sh"
REMOTE_VERIFY_SCRIPT="/opt/ai-service-platform/tools/bootstrap/verify_control_node.sh"
REMOTE_CREATE_INVENTORY_TEMP="/tmp/ai-service-platform.create_inventory.sh"
REMOTE_PREPARE_INVENTORY_TEMP="/tmp/ai-service-platform.prepare_orchestration_inventory.sh"
REMOTE_VERIFY_TEMP="/tmp/ai-service-platform.verify_control_node.sh"
INCLUDE_ALIASES=""
RUN_VERIFY="true"
REFRESH_KNOWN_HOSTS="false"
VERIFY_RETRIES=3
VERIFY_RETRY_DELAY=5
VERIFY_ANSIBLE_TIMEOUT=20
SSH_COMMON_ARGS=()
SCP_COMMON_ARGS=()
RSYNC_SSH_COMMAND=""

usage() {
    cat <<'USAGE'
Usage:
  bash tools/bootstrap/sync_to_orchestration.sh \
    --nodes-file ./operator/nodes.csv \
    --ssh-key-file ./operator/<orchestration-alias>/admin_key

Options:
  --nodes-file PATH          Operator nodes.csv. Default: ./operator/nodes.csv
  --state-file PATH          Operator state.csv. Default: ./operator/state.csv
  --control-role VALUE       Platform role to use as orchestration. Default: orchestration
  --control-alias VALUE      Optional explicit orchestration alias.
  --ssh-user VALUE           SSH user for orchestration sync. Default: useradmin
  --ssh-key-file PATH        SSH private key for SSH user. Default: ./operator/<orchestration-alias>/admin_key
  --remote-nodes-file PATH   Remote temporary CSV path. Default: /tmp/ai-service-platform.nodes.csv
  --softether-dir PATH       Optional operator SoftEther secret directory.
                             Default: ./operator/softether
  --haproxy-dir PATH         Optional operator HAProxy directory.
                             Default: ./operator/haproxy
  --remote-prepare-script PATH
                             Remote prepare script path.
  --create-inventory-script PATH
                             Local create_inventory.sh path.
                             Default: tools/bootstrap/create_inventory.sh
  --prepare-inventory-script PATH
                             Local prepare_orchestration_inventory.sh path.
                             Default: tools/bootstrap/prepare_orchestration_inventory.sh
  --verify-control-script PATH
                             Local verify_control_node.sh path.
                             Default: tools/bootstrap/verify_control_node.sh
  --remote-verify-script PATH
                             Remote verify script path.
  --verify-retries N         Attempts for each remote verification stage. Default: 3.
  --verify-retry-delay SECONDS
                             Delay between failed verify attempts. Default: 5.
  --verify-ansible-timeout SECONDS
                             Ansible SSH/connect timeout for verify. Default: 20.
  --skip-verify              Sync and inventory only; do not run post-bootstrap verify.
  --refresh-known-hosts      Refresh control-node ansible known_hosts for SSH endpoints.
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

require_positive_int() {
    local value="$1"
    local label="$2"
    case "$value" in
        ''|*[!0-9]*) fail "$label must be a positive integer" ;;
        0) fail "$label must be greater than zero" ;;
    esac
}

remote_has_command() {
    local remote="$1"
    local command_name="$2"
    ssh "${SSH_COMMON_ARGS[@]}" "$remote" "command -v '$command_name' >/dev/null 2>&1"
}

sync_directory() {
    local source_dir="$1"
    local remote="$2"
    local remote_dir="$3"
    local label="$4"

    if command -v rsync >/dev/null 2>&1 && remote_has_command "$remote" rsync; then
        echo "Syncing $label to $remote with rsync"
        ssh "${SSH_COMMON_ARGS[@]}" "$remote" "mkdir -p '$remote_dir'"
        rsync -az --delete -e "$RSYNC_SSH_COMMAND" "$source_dir/" "$remote:$remote_dir/"
        return
    fi

    echo "Syncing $label to $remote with scp fallback"
    ssh "${SSH_COMMON_ARGS[@]}" "$remote" "rm -rf '$remote_dir'"
    scp -r "${SCP_COMMON_ARGS[@]}" "$source_dir" "$remote:$remote_dir"
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
        --control-role)
            CONTROL_ROLE="${2:-}"
            shift 2
            ;;
        --control-alias)
            CONTROL_ALIAS="${2:-}"
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
        --create-inventory-script)
            CREATE_INVENTORY_SCRIPT="${2:-}"
            shift 2
            ;;
        --prepare-inventory-script)
            PREPARE_INVENTORY_SCRIPT="${2:-}"
            shift 2
            ;;
        --haproxy-dir)
            HAPROXY_DIR="${2:-}"
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
        --verify-retries)
            VERIFY_RETRIES="${2:-}"
            shift 2
            ;;
        --verify-retry-delay)
            VERIFY_RETRY_DELAY="${2:-}"
            shift 2
            ;;
        --verify-ansible-timeout)
            VERIFY_ANSIBLE_TIMEOUT="${2:-}"
            shift 2
            ;;
        --skip-verify)
            RUN_VERIFY="false"
            shift
            ;;
        --refresh-known-hosts)
            REFRESH_KNOWN_HOSTS="true"
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
require_file "$CREATE_INVENTORY_SCRIPT" "--create-inventory-script"
require_file "$PREPARE_INVENTORY_SCRIPT" "--prepare-inventory-script"
require_file "$VERIFY_CONTROL_SCRIPT" "--verify-control-script"
require_file "$STATE_FILE" "--state-file"
require_positive_int "$VERIFY_RETRIES" "--verify-retries"
require_positive_int "$VERIFY_RETRY_DELAY" "--verify-retry-delay"
require_positive_int "$VERIFY_ANSIBLE_TIMEOUT" "--verify-ansible-timeout"

first_line="$(head -n 1 "$NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_CSV_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_CSV_HEADER"
state_first_line="$(head -n 1 "$STATE_FILE" | tr -d '\r')"
[ "$state_first_line" = "$EXPECTED_STATE_CSV_HEADER" ] || fail "state.csv header must be exactly: $EXPECTED_STATE_CSV_HEADER"

if [ -z "$CONTROL_ALIAS" ]; then
    control_rows=0
    while IFS=, read -r kind name _ansible_group active_aliases _candidate_aliases _old_aliases state extra || [ -n "${kind:-}" ]; do
        kind="${kind//$'\r'/}"
        name="${name//$'\r'/}"
        active_aliases="${active_aliases//$'\r'/}"
        state="${state//$'\r'/}"
        extra="${extra//$'\r'/}"
        [ "$kind" = "$EXPECTED_STATE_CSV_HEADER" ] && continue
        [ -z "$kind" ] && continue
        [ -z "$extra" ] || fail "state.csv row has too many columns"
        if { [ "$kind" = "platform_role" ] || [ "$kind" = "role" ]; } && [ "$name" = "$CONTROL_ROLE" ] && [ "$state" = "present" ]; then
            control_rows=$((control_rows + 1))
            case "$active_aliases" in
                *+*) fail "$CONTROL_ROLE must have exactly one active alias in state.csv" ;;
            esac
            CONTROL_ALIAS="$active_aliases"
        fi
    done < "$STATE_FILE"
    [ "$control_rows" -eq 1 ] || fail "state.csv must contain exactly one present platform_role $CONTROL_ROLE row"
fi

control_endpoint=""
control_connection=""
while IFS=, read -r current_alias endpoint connection _root_password extra || [ -n "${current_alias:-}" ]; do
    current_alias="${current_alias//$'\r'/}"
    endpoint="${endpoint//$'\r'/}"
    connection="${connection//$'\r'/}"
    extra="${extra//$'\r'/}"

    [ "$current_alias" != "$EXPECTED_CSV_HEADER" ] || continue
    [ -z "$extra" ] || fail "nodes.csv row for $current_alias has too many columns"

    if [ "$current_alias" = "$CONTROL_ALIAS" ]; then
        control_endpoint="$endpoint"
        control_connection="$connection"
        break
    fi
done < "$NODES_FILE"

[ -n "$control_endpoint" ] || fail "Control alias not found in nodes file: $CONTROL_ALIAS"
if [ "$control_endpoint" = "local" ] || [ "$control_connection" = "local" ]; then
    fail "Cannot sync to orchestration node when endpoint/connection is local in operator nodes.csv: $CONTROL_ALIAS"
fi
if [ -z "$SSH_KEY_FILE" ]; then
    SSH_KEY_FILE="./operator/$CONTROL_ALIAS/admin_key"
fi
require_file "$SSH_KEY_FILE" "--ssh-key-file"
SSH_COMMON_ARGS=(
    -n
    -T
    -i "$SSH_KEY_FILE"
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o IdentitiesOnly=yes
    -o RequestTTY=no
    -o KbdInteractiveAuthentication=no
    -o PasswordAuthentication=no
    -o PreferredAuthentications=publickey
    -o StrictHostKeyChecking=accept-new
)
SCP_COMMON_ARGS=(
    -B
    -i "$SSH_KEY_FILE"
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o IdentitiesOnly=yes
    -o KbdInteractiveAuthentication=no
    -o PasswordAuthentication=no
    -o PreferredAuthentications=publickey
    -o StrictHostKeyChecking=accept-new
)
RSYNC_SSH_COMMAND="ssh -n -T -i '$SSH_KEY_FILE' -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -o RequestTTY=no -o KbdInteractiveAuthentication=no -o PasswordAuthentication=no -o PreferredAuthentications=publickey -o StrictHostKeyChecking=accept-new"

sanitized_nodes="$(mktemp)"
trap 'rm -f "$sanitized_nodes"' EXIT

{
    echo "$EXPECTED_CSV_HEADER"
    tail -n +2 "$NODES_FILE" | while IFS=, read -r current_alias endpoint connection _root_password extra || [ -n "${current_alias:-}" ]; do
        current_alias="${current_alias//$'\r'/}"
        endpoint="${endpoint//$'\r'/}"
        connection="${connection//$'\r'/}"
        extra="${extra//$'\r'/}"

        [ -n "$current_alias" ] || continue
        [ -z "$extra" ] || fail "nodes.csv row for $current_alias has too many columns"
        printf '%s,%s,%s,\n' "$current_alias" "$endpoint" "$connection"
    done
} > "$sanitized_nodes"

remote="$SSH_USER@$control_endpoint"
echo "Syncing sanitized nodes.csv to $remote"
scp "${SCP_COMMON_ARGS[@]}" "$sanitized_nodes" "$remote:$REMOTE_NODES_FILE"
if [ -n "$STATE_FILE" ]; then
    echo "Syncing state.csv to $remote"
    scp "${SCP_COMMON_ARGS[@]}" "$STATE_FILE" "$remote:$REMOTE_STATE_FILE"
fi
if [ -d "$SOFTETHER_DIR" ]; then
    sync_directory "$SOFTETHER_DIR" "$remote" "$REMOTE_SOFTETHER_DIR" "SoftEther operator secret directory"
fi
if [ -d "$HAPROXY_DIR" ]; then
    sync_directory "$HAPROXY_DIR" "$remote" "$REMOTE_HAPROXY_DIR" "HAProxy operator directory"
fi
if [ "$RUN_VERIFY" = "true" ]; then
    :
fi
echo "Syncing bootstrap helper scripts to $remote"
scp "${SCP_COMMON_ARGS[@]}" "$CREATE_INVENTORY_SCRIPT" "$remote:$REMOTE_CREATE_INVENTORY_TEMP"
scp "${SCP_COMMON_ARGS[@]}" "$PREPARE_INVENTORY_SCRIPT" "$remote:$REMOTE_PREPARE_INVENTORY_TEMP"
scp "${SCP_COMMON_ARGS[@]}" "$VERIFY_CONTROL_SCRIPT" "$remote:$REMOTE_VERIFY_TEMP"

prepare_command="sudo bash '$REMOTE_PREPARE_SCRIPT' --source-nodes-file '$REMOTE_NODES_FILE' --skip-check"
if [ "$REFRESH_KNOWN_HOSTS" = "true" ]; then
    prepare_command="$prepare_command --refresh-known-hosts"
fi
if [ -n "$STATE_FILE" ]; then
    prepare_command="$prepare_command --source-state-file '$REMOTE_STATE_FILE'"
fi
if [ -n "$INCLUDE_ALIASES" ]; then
    prepare_command="$prepare_command --include '$INCLUDE_ALIASES'"
fi
remote_command="set -e; $prepare_command; rm -f '$REMOTE_NODES_FILE' '$REMOTE_STATE_FILE'"
softether_command=""
if [ -d "$SOFTETHER_DIR" ]; then
    softether_command="sudo mkdir -p /opt/ai-service-platform/operator; if [ -d '$REMOTE_SOFTETHER_DIR/softether' ]; then sudo rm -rf /opt/ai-service-platform/operator/softether && sudo cp -a '$REMOTE_SOFTETHER_DIR/softether' /opt/ai-service-platform/operator/softether; else sudo rm -rf /opt/ai-service-platform/operator/softether && sudo cp -a '$REMOTE_SOFTETHER_DIR' /opt/ai-service-platform/operator/softether; fi;"
    remote_command="set -e; $softether_command $prepare_command; rm -rf '$REMOTE_SOFTETHER_DIR'; rm -f '$REMOTE_NODES_FILE' '$REMOTE_STATE_FILE'"
fi
haproxy_command=""
if [ -d "$HAPROXY_DIR" ]; then
    haproxy_command="sudo mkdir -p /opt/ai-service-platform/operator; if [ -d '$REMOTE_HAPROXY_DIR/haproxy' ]; then sudo rm -rf /opt/ai-service-platform/operator/haproxy && sudo cp -a '$REMOTE_HAPROXY_DIR/haproxy' /opt/ai-service-platform/operator/haproxy; else sudo rm -rf /opt/ai-service-platform/operator/haproxy && sudo cp -a '$REMOTE_HAPROXY_DIR' /opt/ai-service-platform/operator/haproxy; fi;"
    remote_command="set -e; $softether_command $haproxy_command $prepare_command; rm -rf '$REMOTE_SOFTETHER_DIR' '$REMOTE_HAPROXY_DIR'; rm -f '$REMOTE_NODES_FILE' '$REMOTE_STATE_FILE'"
fi
if [ "$RUN_VERIFY" = "true" ]; then
    verify_command="sudo mkdir -p \"\$(dirname '$REMOTE_VERIFY_SCRIPT')\"; sudo install -m 700 '$REMOTE_VERIFY_TEMP' '$REMOTE_VERIFY_SCRIPT'; sudo bash '$REMOTE_VERIFY_SCRIPT' --retries '$VERIFY_RETRIES' --retry-delay '$VERIFY_RETRY_DELAY' --ansible-timeout '$VERIFY_ANSIBLE_TIMEOUT';"
    remote_command="set -e; sudo mkdir -p /opt/ai-service-platform/tools/bootstrap; sudo install -m 700 '$REMOTE_CREATE_INVENTORY_TEMP' /opt/ai-service-platform/tools/bootstrap/create_inventory.sh; sudo install -m 700 '$REMOTE_PREPARE_INVENTORY_TEMP' '$REMOTE_PREPARE_SCRIPT'; sudo install -m 700 '$REMOTE_VERIFY_TEMP' '$REMOTE_VERIFY_SCRIPT'; $softether_command $haproxy_command $prepare_command; $verify_command rm -rf '$REMOTE_SOFTETHER_DIR' '$REMOTE_HAPROXY_DIR'; rm -f '$REMOTE_NODES_FILE' '$REMOTE_STATE_FILE' '$REMOTE_CREATE_INVENTORY_TEMP' '$REMOTE_PREPARE_INVENTORY_TEMP' '$REMOTE_VERIFY_TEMP'"
else
    remote_command="set -e; sudo mkdir -p /opt/ai-service-platform/tools/bootstrap; sudo install -m 700 '$REMOTE_CREATE_INVENTORY_TEMP' /opt/ai-service-platform/tools/bootstrap/create_inventory.sh; sudo install -m 700 '$REMOTE_PREPARE_INVENTORY_TEMP' '$REMOTE_PREPARE_SCRIPT'; sudo install -m 700 '$REMOTE_VERIFY_TEMP' '$REMOTE_VERIFY_SCRIPT'; $softether_command $haproxy_command $prepare_command; rm -rf '$REMOTE_SOFTETHER_DIR' '$REMOTE_HAPROXY_DIR'; rm -f '$REMOTE_NODES_FILE' '$REMOTE_STATE_FILE' '$REMOTE_CREATE_INVENTORY_TEMP' '$REMOTE_PREPARE_INVENTORY_TEMP' '$REMOTE_VERIFY_TEMP'"
fi

echo "Running orchestration inventory preparation"
ssh "${SSH_COMMON_ARGS[@]}" "$remote" "$remote_command"
if [ "$RUN_VERIFY" = "true" ]; then
    echo "[OK] Orchestration node nodes.csv, inventory.ini, and verification are complete"
else
    echo "[OK] Orchestration node nodes.csv and inventory.ini are in sync; verify skipped"
fi
