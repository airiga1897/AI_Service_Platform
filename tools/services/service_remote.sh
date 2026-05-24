#!/usr/bin/env bash

set -euo pipefail

SERVICE="${1:-}"
ACTION="${2:-}"
NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
CONTROL_ROLE="orchestration"
CONTROL_ALIAS=""
OPERATOR_DIR="./operator"
SSH_USER="useradmin"
SSH_KEY_FILE=""
REMOTE_REPO_DIR="/opt/ai-service-platform"
REMOTE_NODES_FILE="/opt/ai-service-platform/operator/nodes.csv"
REMOTE_STATE_FILE="/opt/ai-service-platform/operator/state.csv"
REMOTE_INVENTORY="/opt/ai-service-platform/inventory.ini"
SERVICE_RUNNER_SCRIPT="tools/services/service.sh"
ANSIBLE_DIR="infra/ansible"
LIMIT=""
CHECK="false"
CONFIRM_PURGE="false"

EXPECTED_HEADER="current_alias,endpoint,connection,root_password"
EXPECTED_STATE_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"

usage() {
    cat <<'USAGE'
Usage:
  bash tools/services/service_remote.sh <service> <plan|apply|absent|purge> [options]

Options:
  --nodes-file PATH       Operator nodes.csv. Default: ./operator/nodes.csv
  --state-file PATH       Operator state.csv. Default: ./operator/state.csv
  --control-role NAME     Platform role to use as orchestration. Default: orchestration
  --control-alias ALIAS   Optional explicit orchestration alias.
  --operator-dir PATH     Operator directory. Default: ./operator
  --ssh-user USER         SSH user on orchestration node. Default: useradmin
  --ssh-key-file PATH     SSH private key. Default: ./operator/<control-alias>/admin_key
  --remote-repo-dir PATH  Repo path on orchestration node. Default: /opt/ai-service-platform
  --limit ALIAS           Service target alias.
  --check                 Pass --check to service.sh apply.
  --confirm-purge         Pass --confirm-purge to service.sh purge.
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

quote_bash_arg() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\\\'\'}"
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

invoke_retry_transport() {
    local label="$1"
    shift
    local attempt
    local exit_code
    for attempt in 1 2 3; do
        if "$@"; then
            return 0
        fi
        exit_code=$?
        if [ "$exit_code" -ne 255 ] || [ "$attempt" -eq 3 ]; then
            fail "$label failed with exit code $exit_code"
        fi
        echo "$label hit SSH transport reset (exit 255), retrying $attempt/3..."
        sleep 2
    done
}

if [ "$SERVICE" = "-h" ] || [ "$SERVICE" = "--help" ]; then
    usage
    exit 0
fi
case "$ACTION" in
    plan|apply|absent|purge) ;;
    *) usage; fail "Action must be one of: plan, apply, absent, purge" ;;
esac
if [ "$SERVICE" = "vpn" ]; then
    fail "Unsupported service 'vpn'. Use canonical service name: vpn_edge"
fi
if [ "$SERVICE" = "vpn_cascade" ]; then
    fail "Service 'vpn_cascade' is reserved for future site-to-site/cascade rollout and is not implemented yet."
fi

shift 2
while [ "$#" -gt 0 ]; do
    case "$1" in
        --nodes-file) NODES_FILE="${2:-}"; shift 2 ;;
        --state-file) STATE_FILE="${2:-}"; shift 2 ;;
        --control-role) CONTROL_ROLE="${2:-}"; shift 2 ;;
        --control-alias) CONTROL_ALIAS="${2:-}"; shift 2 ;;
        --operator-dir) OPERATOR_DIR="${2:-}"; shift 2 ;;
        --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
        --ssh-key-file) SSH_KEY_FILE="${2:-}"; shift 2 ;;
        --remote-repo-dir) REMOTE_REPO_DIR="${2:-}"; shift 2 ;;
        --limit) LIMIT="${2:-}"; shift 2 ;;
        --check) CHECK="true"; shift ;;
        --confirm-purge) CONFIRM_PURGE="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

require_file "$NODES_FILE" "--nodes-file"
require_file "$STATE_FILE" "--state-file"
require_file "$SERVICE_RUNNER_SCRIPT" "--service-runner-script"
[ -d "$ANSIBLE_DIR" ] || fail "Ansible directory not found: $ANSIBLE_DIR"
command -v ssh >/dev/null 2>&1 || fail "ssh not found in PATH"
command -v scp >/dev/null 2>&1 || fail "scp not found in PATH"
command -v tar >/dev/null 2>&1 || fail "tar not found in PATH"

first_line="$(head -n 1 "$NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_HEADER"
state_first_line="$(head -n 1 "$STATE_FILE" | tr -d '\r')"
[ "$state_first_line" = "$EXPECTED_STATE_HEADER" ] || fail "state.csv header must be exactly: $EXPECTED_STATE_HEADER"

control_rows=0
active_aliases=""
while IFS=, read -r kind name _ansible_group row_active_aliases _candidate_aliases _old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    row_active_aliases="${row_active_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ -z "$kind" ] && continue
    [ -z "$extra" ] || fail "state.csv row has too many columns"
    if { [ "$kind" = "platform_role" ] || [ "$kind" = "role" ]; } && [ "$name" = "$CONTROL_ROLE" ] && [ "$row_state" = "present" ]; then
        control_rows=$((control_rows + 1))
        active_aliases="$row_active_aliases"
    fi
done < <(tail -n +2 "$STATE_FILE")

[ "$control_rows" -eq 1 ] || fail "state.csv must contain exactly one present platform_role $CONTROL_ROLE row"
if [ -n "$CONTROL_ALIAS" ]; then
    found_explicit="false"
    while IFS= read -r alias_item; do
        [ "$alias_item" = "$CONTROL_ALIAS" ] && found_explicit="true"
    done < <(split_aliases_to_lines "$active_aliases")
    [ "$found_explicit" = "true" ] || fail "Control alias $CONTROL_ALIAS is not active for role '$CONTROL_ROLE' in state.csv."
    active_aliases="$CONTROL_ALIAS"
fi
case "$active_aliases" in
    "") fail "Control role '$CONTROL_ROLE' must have exactly one active alias in state.csv." ;;
    *+*) fail "Control role '$CONTROL_ROLE' has multiple active aliases in state.csv. Keep one active alias and put reserve nodes in candidate_aliases." ;;
esac

control_endpoint=""
control_connection=""
while IFS=, read -r current_alias endpoint connection _root_password extra || [ -n "${current_alias:-}" ]; do
    current_alias="${current_alias//$'\r'/}"
    endpoint="${endpoint//$'\r'/}"
    connection="${connection//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ -z "$current_alias" ] && continue
    [ -z "$extra" ] || fail "nodes.csv row for $current_alias has too many columns"
    if [ "$current_alias" = "$active_aliases" ]; then
        control_endpoint="$endpoint"
        control_connection="$connection"
        break
    fi
done < <(tail -n +2 "$NODES_FILE")

[ -n "$control_endpoint" ] || fail "Control alias from state.csv not found in nodes.csv: $active_aliases"
[ "$control_connection" = "ssh" ] && [ "$control_endpoint" != "local" ] || fail "Control node $active_aliases must use connection=ssh and a real endpoint for remote service execution."
if [ -z "$SSH_KEY_FILE" ]; then
    SSH_KEY_FILE="$OPERATOR_DIR/$active_aliases/admin_key"
fi
require_file "$SSH_KEY_FILE" "--ssh-key-file"

remote="$SSH_USER@$control_endpoint"
remote_bundle_dir="/tmp/ai-service-platform.service-remote.$(date +%s).$$"
remote_bundle_archive="$remote_bundle_dir.tar.gz"
remote_service_runner_temp="$remote_bundle_dir/service.sh"
remote_ansible_temp="$remote_bundle_dir/ansible"
archive_path="$(mktemp -t ai-service-platform.service-remote.XXXXXX.tar.gz)"
staging_dir="$(mktemp -d -t ai-service-platform.service-remote.XXXXXX)"

cleanup() {
    rm -rf "$archive_path" "$staging_dir"
    ssh -i "$SSH_KEY_FILE" -o IdentitiesOnly=yes "$remote" "rm -rf $(quote_bash_arg "$remote_bundle_dir") $(quote_bash_arg "$remote_bundle_archive")" >/dev/null 2>&1 || true
}
trap cleanup EXIT

remote_args=(
    "$(quote_bash_arg "$SERVICE")"
    "$(quote_bash_arg "$ACTION")"
    "--nodes-file" "$(quote_bash_arg "$REMOTE_NODES_FILE")"
    "--state-file" "$(quote_bash_arg "$REMOTE_STATE_FILE")"
    "--inventory" "$(quote_bash_arg "$REMOTE_INVENTORY")"
)
[ -n "$LIMIT" ] && remote_args+=("--limit" "$(quote_bash_arg "$LIMIT")")
[ "$CHECK" = "true" ] && remote_args+=("--check")
[ "$CONFIRM_PURGE" = "true" ] && remote_args+=("--confirm-purge")

service_command="set -e; cd $(quote_bash_arg "$REMOTE_REPO_DIR"); bash tools/services/service.sh ${remote_args[*]}"
install_and_run_command="set -e; sudo mkdir -p $(quote_bash_arg "$REMOTE_REPO_DIR/tools/services") $(quote_bash_arg "$REMOTE_REPO_DIR/infra"); sudo install -m 700 $(quote_bash_arg "$remote_service_runner_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/tools/services/service.sh"); sudo rm -rf $(quote_bash_arg "$REMOTE_REPO_DIR/infra/ansible"); sudo cp -a $(quote_bash_arg "$remote_ansible_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/infra/ansible"); sudo bash -lc $(quote_bash_arg "$service_command"); rm -rf $(quote_bash_arg "$remote_bundle_dir")"

echo "Control node: $active_aliases via role '$CONTROL_ROLE'"
echo "Remote:       $remote"
echo "Service:      $SERVICE"
echo "Action:       $ACTION"
[ -n "$LIMIT" ] && echo "Limit:        $LIMIT"
[ "$CHECK" = "true" ] && echo "Check:        true"

echo "Preparing local service bundle..."
cp "$SERVICE_RUNNER_SCRIPT" "$staging_dir/service.sh"
cp -a "$ANSIBLE_DIR" "$staging_dir/ansible"
tar -czf "$archive_path" -C "$staging_dir" .

echo "Creating remote temporary bundle directory..."
invoke_retry_transport "remote service bundle directory creation" ssh -i "$SSH_KEY_FILE" -o IdentitiesOnly=yes "$remote" "mkdir -p $(quote_bash_arg "$remote_bundle_dir")"

echo "Uploading service bundle archive..."
scp -i "$SSH_KEY_FILE" -o IdentitiesOnly=yes "$archive_path" "$remote:$remote_bundle_archive"

extract_command="set -e; rm -rf $(quote_bash_arg "$remote_bundle_dir"); mkdir -p $(quote_bash_arg "$remote_bundle_dir"); tar -xzf $(quote_bash_arg "$remote_bundle_archive") -C $(quote_bash_arg "$remote_bundle_dir"); test -f $(quote_bash_arg "$remote_service_runner_temp"); test -d $(quote_bash_arg "$remote_ansible_temp")"
echo "Extracting service bundle on orchestration node..."
invoke_retry_transport "remote service bundle extract" ssh -i "$SSH_KEY_FILE" -o IdentitiesOnly=yes "$remote" "$extract_command"

echo "Installing service bundle and running remote service command..."
ssh -i "$SSH_KEY_FILE" -o IdentitiesOnly=yes "$remote" "$install_and_run_command"

echo "Cleaning remote temporary service bundle..."
