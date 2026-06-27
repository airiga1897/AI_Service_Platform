#!/usr/bin/env bash

set -euo pipefail

ALIAS=""
NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
OPERATOR_DIR="./operator"
CONTROL_ROLE="orchestration"
SYNC_SCRIPT="tools/bootstrap/sync_to_orchestration.sh"
SSH_USER="useradmin"
SSH_KEY_FILE=""
INCLUDE_ALIASES=""
REFRESH_KNOWN_HOSTS="false"
SKIP_VERIFY="false"
SKIP_SERVICE_PLAN="false"

EXPECTED_HEADER="current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
EXPECTED_STATE_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"

usage() {
    cat <<'USAGE'
Usage:
  bash tools/bootstrap/prepare_orchestration_standby.sh --alias vps5 [options]

Options:
  --alias ALIAS           Candidate orchestration alias to prepare.
  --nodes-file PATH       Operator nodes.csv. Default: ./operator/nodes.csv
  --state-file PATH       Operator state.csv. Default: ./operator/state.csv
  --operator-dir PATH     Operator directory. Default: ./operator
  --control-role NAME     Platform role to prepare. Default: orchestration
  --sync-script PATH      Sync helper. Default: tools/bootstrap/sync_to_orchestration.sh
  --ssh-user USER         SSH user. Default: useradmin
  --ssh-key-file PATH     SSH key override.
  --include LIST          Optional aliases to include when generating inventory.
  --refresh-known-hosts   Refresh standby ansible known_hosts during sync.
  --skip-verify           Skip remote verification.
  --skip-service-plan     Accepted for parity with PowerShell helper.
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

append_unique_alias() {
    local list="$1"
    local alias="$2"
    [ -n "$alias" ] || {
        printf '%s' "$list"
        return
    }
    if alias_in_list "$alias" "$list"; then
        printf '%s' "$list"
    elif [ -z "$list" ]; then
        printf '%s' "$alias"
    else
        printf '%s+%s' "$list" "$alias"
    fi
}

remove_alias_from_list() {
    local list="$1"
    local remove="$2"
    local result=""
    local item
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        [ "$item" = "$remove" ] && continue
        result="$(append_unique_alias "$result" "$item")"
    done < <(split_aliases_to_lines "$list")
    printf '%s' "$result"
}

default_standby_include() {
    local excluded_aliases="$1"
    local result=""
    local current_alias endpoint expected_ip connection ssh_port root_password extra
    while IFS=, read -r current_alias endpoint expected_ip connection ssh_port root_password extra || [ -n "${current_alias:-}" ]; do
        current_alias="${current_alias//$'\r'/}"
        extra="${extra//$'\r'/}"
        [ -n "$current_alias" ] || continue
        [ -z "$extra" ] || fail "nodes.csv row for $current_alias has too many columns"
        if alias_in_list "$current_alias" "$excluded_aliases"; then
            continue
        fi
        if [ -z "$result" ]; then
            result="$current_alias"
        else
            result="$result,$current_alias"
        fi
    done < <(tail -n +2 "$NODES_FILE")
    printf '%s' "$result"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --alias) ALIAS="${2:-}"; shift 2 ;;
        --nodes-file) NODES_FILE="${2:-}"; shift 2 ;;
        --state-file) STATE_FILE="${2:-}"; shift 2 ;;
        --operator-dir) OPERATOR_DIR="${2:-}"; shift 2 ;;
        --control-role) CONTROL_ROLE="${2:-}"; shift 2 ;;
        --sync-script) SYNC_SCRIPT="${2:-}"; shift 2 ;;
        --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
        --ssh-key-file) SSH_KEY_FILE="${2:-}"; shift 2 ;;
        --include) INCLUDE_ALIASES="${2:-}"; shift 2 ;;
        --refresh-known-hosts|--auto-accept-host-key) REFRESH_KNOWN_HOSTS="true"; shift ;;
        --skip-verify) SKIP_VERIFY="true"; shift ;;
        --skip-service-plan) SKIP_SERVICE_PLAN="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[ -n "$ALIAS" ] || fail "--alias is required"
require_file "$NODES_FILE" "--nodes-file"
require_file "$STATE_FILE" "--state-file"
require_file "$SYNC_SCRIPT" "--sync-script"

first_line="$(head -n 1 "$NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_HEADER"
state_first_line="$(head -n 1 "$STATE_FILE" | tr -d '\r')"
[ "$state_first_line" = "$EXPECTED_STATE_HEADER" ] || fail "state.csv header must be exactly: $EXPECTED_STATE_HEADER"

target_found="false"
target_endpoint=""
target_connection=""
while IFS=, read -r current_alias endpoint expected_ip connection _ssh_port _root_password extra || [ -n "${current_alias:-}" ]; do
    current_alias="${current_alias//$'\r'/}"
    endpoint="${endpoint//$'\r'/}"
    connection="${connection//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ -n "$current_alias" ] || continue
    [ -z "$extra" ] || fail "nodes.csv row for $current_alias has too many columns"
    if [ "$current_alias" = "$ALIAS" ]; then
        target_found="true"
        target_endpoint="$endpoint"
        target_connection="$connection"
        break
    fi
done < <(tail -n +2 "$NODES_FILE")

[ "$target_found" = "true" ] || fail "Standby orchestration alias '$ALIAS' is not present in nodes.csv"
[ "$target_connection" = "ssh" ] && [ "$target_endpoint" != "local" ] || fail "Standby orchestration alias '$ALIAS' must use connection=ssh and a real endpoint in nodes.csv"

role_rows=0
active_aliases=""
candidate_aliases=""
old_aliases=""
role_group=""
while IFS=, read -r kind name ansible_group row_active_aliases row_candidate_aliases row_old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    ansible_group="${ansible_group//$'\r'/}"
    row_active_aliases="${row_active_aliases//$'\r'/}"
    row_candidate_aliases="${row_candidate_aliases//$'\r'/}"
    row_old_aliases="${row_old_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ -n "$kind" ] || continue
    [ -z "$extra" ] || fail "state.csv row for $name has too many columns"
    if { [ "$kind" = "platform_role" ] || [ "$kind" = "role" ]; } && [ "$name" = "$CONTROL_ROLE" ] && [ "$row_state" = "present" ]; then
        role_rows=$((role_rows + 1))
        active_aliases="$row_active_aliases"
        candidate_aliases="$row_candidate_aliases"
        old_aliases="$row_old_aliases"
        role_group="$ansible_group"
    fi
done < <(tail -n +2 "$STATE_FILE")

[ "$role_rows" -eq 1 ] || fail "state.csv must contain exactly one present platform_role $CONTROL_ROLE row"
case "$active_aliases" in
    ""|*+*) fail "platform_role '$CONTROL_ROLE' must have exactly one active alias before preparing standby" ;;
esac
[ "$active_aliases" != "$ALIAS" ] || fail "Alias '$ALIAS' is already active for '$CONTROL_ROLE'; standby preparation expects a candidate alias"
alias_in_list "$ALIAS" "$candidate_aliases" || fail "Alias '$ALIAS' must be listed in candidate_aliases for platform_role '$CONTROL_ROLE'"
if [ -z "$INCLUDE_ALIASES" ]; then
    INCLUDE_ALIASES="$(default_standby_include "$old_aliases")"
    if [ -n "$INCLUDE_ALIASES" ]; then
        echo "Standby inventory include defaults to current aliases excluding old $CONTROL_ROLE aliases: $INCLUDE_ALIASES"
    fi
fi

temp_state="$(mktemp -t ai-service-platform.standby-state.XXXXXX.csv)"
trap 'rm -f "$temp_state"' EXIT

{
    echo "$EXPECTED_STATE_HEADER"
    while IFS=, read -r kind name ansible_group row_active_aliases row_candidate_aliases row_old_aliases row_state extra || [ -n "${kind:-}" ]; do
        kind="${kind//$'\r'/}"
        name="${name//$'\r'/}"
        ansible_group="${ansible_group//$'\r'/}"
        row_active_aliases="${row_active_aliases//$'\r'/}"
        row_candidate_aliases="${row_candidate_aliases//$'\r'/}"
        row_old_aliases="${row_old_aliases//$'\r'/}"
        row_state="${row_state//$'\r'/}"
        extra="${extra//$'\r'/}"
        [ -n "$kind" ] || continue
        [ -z "$extra" ] || fail "state.csv row for $name has too many columns"
        if { [ "$kind" = "platform_role" ] || [ "$kind" = "role" ]; } && [ "$name" = "$CONTROL_ROLE" ] && [ "$row_state" = "present" ]; then
            new_candidates="$(remove_alias_from_list "$candidate_aliases" "$ALIAS")"
            new_old="$(append_unique_alias "$old_aliases" "$active_aliases")"
            printf 'platform_role,%s,%s,%s,%s,%s,%s\n' "$name" "$role_group" "$ALIAS" "$new_candidates" "$new_old" "$row_state"
        else
            printf '%s,%s,%s,%s,%s,%s,%s\n' "$kind" "$name" "$ansible_group" "$row_active_aliases" "$row_candidate_aliases" "$row_old_aliases" "$row_state"
        fi
    done < <(tail -n +2 "$STATE_FILE")
} > "$temp_state"

echo "Preparing standby orchestration node '$ALIAS'"
echo "Current active orchestration remains local state: $active_aliases"
echo "Temporary promotion state will be synced only to standby: $ALIAS"

if [ -z "$SSH_KEY_FILE" ]; then
    SSH_KEY_FILE="$OPERATOR_DIR/$ALIAS/admin_key"
fi

args=(
    "--nodes-file" "$NODES_FILE"
    "--state-file" "$temp_state"
    "--control-role" "$CONTROL_ROLE"
    "--control-alias" "$ALIAS"
    "--ssh-user" "$SSH_USER"
    "--ssh-key-file" "$SSH_KEY_FILE"
    "--softether-dir" "$OPERATOR_DIR/softether"
    "--haproxy-dir" "$OPERATOR_DIR/haproxy"
)
[ -n "$INCLUDE_ALIASES" ] && args+=("--include" "$INCLUDE_ALIASES")
[ "$REFRESH_KNOWN_HOSTS" = "true" ] && args+=("--refresh-known-hosts")
[ "$SKIP_VERIFY" = "true" ] && args+=("--skip-verify")

bash "$SYNC_SCRIPT" "${args[@]}"

echo ""
echo "[OK] Standby orchestration node '$ALIAS' prepared"
echo "Local $STATE_FILE was not modified. To promote manually, set active_aliases=$ALIAS for platform_role '$CONTROL_ROLE'."
