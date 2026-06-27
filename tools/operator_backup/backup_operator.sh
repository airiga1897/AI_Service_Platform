#!/usr/bin/env bash

set -euo pipefail

NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
OPERATOR_DIR="./operator"
CONTROL_ROLE="orchestration"
LOCAL_BACKUP_DIR="${AI_SP_OPERATOR_BACKUP_DIR:-$HOME/ai-service-platform-backups/operator}"
REMOTE_BACKUP_DIR="/opt/backups/ai-service-platform/operator"
ADMIN_USER="useradmin"
AUTO_ACCEPT_HOST_KEY="false"

EXPECTED_NODES_HEADER="current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
EXPECTED_STATE_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"

usage() {
    cat <<'USAGE'
Usage:
  bash tools/operator_backup/backup_operator.sh [options]

Options:
  --nodes-file PATH       Operator nodes.csv. Default: ./operator/nodes.csv
  --state-file PATH       Operator state.csv. Default: ./operator/state.csv
  --operator-dir PATH     Operator directory. Default: ./operator
  --control-role NAME     Platform role to use as orchestration. Default: orchestration
  --backup-dir PATH       Local encrypted backup dir. Default: $AI_SP_OPERATOR_BACKUP_DIR or $HOME/ai-service-platform-backups/operator
  --remote-backup-dir PATH
                         Remote encrypted backup dir. Default: /opt/backups/ai-service-platform/operator
  --admin-user USER       Admin SSH user. Default: useradmin
  --auto-accept-host-key  Use StrictHostKeyChecking=accept-new for ssh/scp.
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

require_dir() {
    local path="$1"
    local label="$2"
    [ -d "$path" ] || fail "$label not found: $path"
}

quote_bash_arg() {
    local value="$1"
    printf "'"
    printf '%s' "$value" | sed "s/'/'\\\\''/g"
    printf "'"
}

split_aliases() {
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

ssh_common_args() {
    local key_file="$1"
    local args=(-i "$key_file" -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes)
    if [ "$AUTO_ACCEPT_HOST_KEY" = "true" ]; then
        args+=(-o StrictHostKeyChecking=accept-new)
    fi
    printf '%s\0' "${args[@]}"
}

invoke_ssh_key() {
    local key_file="$1"
    local port="$2"
    local remote="$3"
    local command="$4"
    local label="$5"
    local args=()
    mapfile -d '' -t args < <(ssh_common_args "$key_file")
    ssh -n -p "$port" "${args[@]}" "$remote" "$command" || fail "$label failed"
}

invoke_scp_key() {
    local key_file="$1"
    local port="$2"
    local source="$3"
    local target="$4"
    local label="$5"
    local args=()
    mapfile -d '' -t args < <(ssh_common_args "$key_file")
    scp -P "$port" "${args[@]}" "$source" "$target" || fail "$label failed"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --nodes-file) NODES_FILE="${2:-}"; shift 2 ;;
        --state-file) STATE_FILE="${2:-}"; shift 2 ;;
        --operator-dir) OPERATOR_DIR="${2:-}"; shift 2 ;;
        --control-role) CONTROL_ROLE="${2:-}"; shift 2 ;;
        --backup-dir) LOCAL_BACKUP_DIR="${2:-}"; shift 2 ;;
        --remote-backup-dir) REMOTE_BACKUP_DIR="${2:-}"; shift 2 ;;
        --admin-user) ADMIN_USER="${2:-}"; shift 2 ;;
        --auto-accept-host-key|--refresh-known-hosts) AUTO_ACCEPT_HOST_KEY="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[ -n "${AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT:-}" ] || fail "AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT is not set"
command -v age >/dev/null 2>&1 || fail "age not found in PATH"
command -v tar >/dev/null 2>&1 || fail "tar not found in PATH"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum not found in PATH"
command -v ssh >/dev/null 2>&1 || fail "ssh not found in PATH"
command -v scp >/dev/null 2>&1 || fail "scp not found in PATH"

require_file "$NODES_FILE" "--nodes-file"
require_file "$STATE_FILE" "--state-file"
require_dir "$OPERATOR_DIR" "--operator-dir"

first_line="$(head -n 1 "$NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_NODES_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_NODES_HEADER"
state_first_line="$(head -n 1 "$STATE_FILE" | tr -d '\r')"
[ "$state_first_line" = "$EXPECTED_STATE_HEADER" ] || fail "state.csv header must be exactly: $EXPECTED_STATE_HEADER"

standby_aliases=()
role_rows=0
while IFS=, read -r kind name _ansible_group _active_aliases candidate_aliases _old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    candidate_aliases="${candidate_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ -z "$kind" ] && continue
    [ -z "$extra" ] || fail "state.csv row for $name has too many columns"
    if { [ "$kind" = "platform_role" ] || [ "$kind" = "role" ]; } && [ "$name" = "$CONTROL_ROLE" ] && [ "$row_state" = "present" ]; then
        role_rows=$((role_rows + 1))
        while IFS= read -r alias; do
            [ -n "$alias" ] && standby_aliases+=("$alias")
        done < <(split_aliases "$candidate_aliases")
    fi
done < <(tail -n +2 "$STATE_FILE")

[ "$role_rows" -eq 1 ] || fail "state.csv must contain exactly one present platform_role $CONTROL_ROLE row"
[ "${#standby_aliases[@]}" -gt 0 ] || fail "state.csv has no standby orchestration candidate aliases for platform_role $CONTROL_ROLE"

operator_path="$(cd "$OPERATOR_DIR" && pwd -P)"
operator_parent="$(dirname "$operator_path")"
operator_leaf="$(basename "$operator_path")"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
artifact_base="operator-backup-$timestamp.tar.gz"
raw_archive="$(mktemp -t "ai-service-platform.$artifact_base.XXXXXX")"
encrypted_name="$artifact_base.age"
checksum_name="$encrypted_name.sha256"
local_encrypted="$LOCAL_BACKUP_DIR/$encrypted_name"
local_checksum="$LOCAL_BACKUP_DIR/$checksum_name"

cleanup() {
    rm -f "$raw_archive"
}
trap cleanup EXIT

mkdir -p "$LOCAL_BACKUP_DIR"

echo "Creating temporary operator archive: $raw_archive"
tar -czf "$raw_archive" -C "$operator_parent" "$operator_leaf"

echo "Encrypting operator backup: $local_encrypted"
age -r "$AI_SP_OPERATOR_BACKUP_AGE_RECIPIENT" -o "$local_encrypted" "$raw_archive"
sha256sum "$local_encrypted" | sed "s#  .*#  $encrypted_name#" > "$local_checksum"
echo "Wrote checksum: $local_checksum"

for alias in "${standby_aliases[@]}"; do
    node_line="$(awk -F, -v alias="$alias" 'NR > 1 && $1 == alias { print; exit }' "$NODES_FILE")"
    [ -n "$node_line" ] || fail "Standby orchestration alias not found in nodes.csv: $alias"
    IFS=, read -r _current_alias endpoint _expected_ip connection ssh_port _root_password _extra <<< "$node_line"
    endpoint="${endpoint//$'\r'/}"
    connection="${connection//$'\r'/}"
    ssh_port="${ssh_port//$'\r'/}"
    [ -n "$ssh_port" ] || ssh_port="22"
    [ "$connection" = "ssh" ] && [ "$endpoint" != "local" ] || fail "Standby orchestration alias $alias must use connection=ssh and a real endpoint"
    admin_key="$OPERATOR_DIR/$alias/admin_key"
    require_file "$admin_key" "admin key for standby orchestration alias $alias"

    remote="$ADMIN_USER@$endpoint"
    remote_temp_dir="/tmp/ai-service-platform.operator-backup.$(date -u +%Y%m%dT%H%M%SZ).$$.$alias"
    echo "Uploading encrypted operator backup to standby orchestration alias $alias: $REMOTE_BACKUP_DIR"
    invoke_ssh_key "$admin_key" "$ssh_port" "$remote" "mkdir -p $(quote_bash_arg "$remote_temp_dir")" "remote temp backup dir create"
    invoke_scp_key "$admin_key" "$ssh_port" "$local_encrypted" "$remote:$remote_temp_dir/$encrypted_name" "scp encrypted operator backup"
    invoke_scp_key "$admin_key" "$ssh_port" "$local_checksum" "$remote:$remote_temp_dir/$checksum_name" "scp encrypted operator backup checksum"
    install_command="set -e; sudo mkdir -p $(quote_bash_arg "$REMOTE_BACKUP_DIR"); sudo install -m 600 $(quote_bash_arg "$remote_temp_dir/$encrypted_name") $(quote_bash_arg "$REMOTE_BACKUP_DIR/$encrypted_name"); sudo install -m 600 $(quote_bash_arg "$remote_temp_dir/$checksum_name") $(quote_bash_arg "$REMOTE_BACKUP_DIR/$checksum_name"); rm -rf $(quote_bash_arg "$remote_temp_dir")"
    invoke_ssh_key "$admin_key" "$ssh_port" "$remote" "$install_command" "remote encrypted operator backup install"
done

echo "[OK] Encrypted operator backup completed: $local_encrypted"
