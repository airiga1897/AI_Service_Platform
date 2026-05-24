#!/usr/bin/env bash

set -euo pipefail

EXPECTED_CSV_HEADER="current_alias,endpoint,connection,root_password"
EXPECTED_STATE_CSV_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
REPO_DIR="/opt/ai-service-platform"
SOURCE_NODES_FILE=""
SOURCE_STATE_FILE=""
TARGET_NODES_FILE="/opt/ai-service-platform/operator/nodes.csv"
TARGET_STATE_FILE="/opt/ai-service-platform/operator/state.csv"
INVENTORY_OUTPUT="/opt/ai-service-platform/inventory.ini"
INCLUDE_ALIASES=""
MANAGEMENT_ALIAS=""
RUN_CHECK="true"
REFRESH_KNOWN_HOSTS="false"

usage() {
    cat <<'USAGE'
Usage:
  sudo bash tools/bootstrap/prepare_orchestration_inventory.sh \
    --source-nodes-file /tmp/nodes.csv

This script runs on the active orchestration node after bootstrap. It:
  1. verifies that /opt/ai-service-platform exists;
  2. writes sanitized /opt/ai-service-platform/operator/nodes.csv;
  3. generates /opt/ai-service-platform/inventory.ini;
  4. runs ansible ping by default.

Options:
  --source-nodes-file PATH   Source nodes.csv. It may contain root_password.
  --source-state-file PATH   Optional source state.csv.
  --repo-dir PATH            Repo dir. Default: /opt/ai-service-platform
  --target-nodes-file PATH   Sanitized target CSV path.
  --target-state-file PATH   Target state CSV path.
  --inventory-output PATH    Generated inventory path.
  --include LIST             Aliases to include. Default: all nodes from nodes.csv
  --management-alias ALIAS   Compatibility override. By default active orchestration from state.csv is local/local.
  --skip-check               Generate inventory without ansible ping.
  --refresh-known-hosts      Refresh known_hosts for ssh endpoints before checks.
  -h, --help                 Show help.
USAGE
}

fail() {
    echo "[ERROR] $1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source-nodes-file)
            SOURCE_NODES_FILE="${2:-}"
            shift 2
            ;;
        --source-state-file)
            SOURCE_STATE_FILE="${2:-}"
            shift 2
            ;;
        --repo-dir)
            REPO_DIR="${2:-}"
            shift 2
            ;;
        --target-nodes-file)
            TARGET_NODES_FILE="${2:-}"
            shift 2
            ;;
        --target-state-file)
            TARGET_STATE_FILE="${2:-}"
            shift 2
            ;;
        --inventory-output)
            INVENTORY_OUTPUT="${2:-}"
            shift 2
            ;;
        --include)
            INCLUDE_ALIASES="${2:-}"
            shift 2
            ;;
        --management-alias)
            MANAGEMENT_ALIAS="${2:-}"
            shift 2
            ;;
        --skip-check)
            RUN_CHECK="false"
            shift
            ;;
        --refresh-known-hosts)
            REFRESH_KNOWN_HOSTS="true"
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

[ -n "$SOURCE_NODES_FILE" ] || fail "--source-nodes-file is required"
[ -f "$SOURCE_NODES_FILE" ] || fail "source nodes file not found: $SOURCE_NODES_FILE"
[ -d "$REPO_DIR" ] || fail "repo dir not found: $REPO_DIR"
[ -f "$REPO_DIR/tools/bootstrap/create_inventory.sh" ] || fail "create_inventory.sh not found in repo dir: $REPO_DIR"

first_line="$(head -n 1 "$SOURCE_NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_CSV_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_CSV_HEADER"

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

resolve_management_alias_from_state() {
    [ -n "$MANAGEMENT_ALIAS" ] && return 0
    [ -n "$SOURCE_STATE_FILE" ] || fail "--source-state-file is required to choose the active orchestration alias"
    [ -f "$SOURCE_STATE_FILE" ] || fail "source state file not found: $SOURCE_STATE_FILE"

    local line_number=0
    local matched_alias=""
    local matched_rows=0
    local kind name ansible_group active_aliases candidate_aliases old_aliases state extra
    while IFS=, read -r kind name ansible_group active_aliases candidate_aliases old_aliases state extra || [ -n "${kind:-}" ]; do
        line_number=$((line_number + 1))
        kind="${kind//$'\r'/}"
        name="${name//$'\r'/}"
        active_aliases="${active_aliases//$'\r'/}"
        state="${state//$'\r'/}"
        extra="${extra//$'\r'/}"
        [ "$line_number" -eq 1 ] && continue
        [ -z "$kind" ] && continue
        [ -z "$extra" ] || fail "state.csv line $line_number has too many columns"
        if { [ "$kind" = "platform_role" ] || [ "$kind" = "role" ]; } && [ "$name" = "orchestration" ] && [ "$state" = "present" ]; then
            matched_rows=$((matched_rows + 1))
            local alias_count=0
            local alias_item
            while IFS= read -r alias_item; do
                alias_count=$((alias_count + 1))
                matched_alias="$alias_item"
            done < <(split_aliases "$active_aliases")
            [ "$alias_count" -eq 1 ] || fail "orchestration must have exactly one active alias in state.csv"
        fi
    done < "$SOURCE_STATE_FILE"
    [ "$matched_rows" -eq 1 ] || fail "state.csv must contain exactly one present platform_role/role orchestration row"
    MANAGEMENT_ALIAS="$matched_alias"
}

resolve_include_aliases() {
    [ -n "$INCLUDE_ALIASES" ] && return 0
    INCLUDE_ALIASES="$(
        tail -n +2 "$SOURCE_NODES_FILE" |
            while IFS=, read -r current_alias _endpoint _connection _root_password extra || [ -n "${current_alias:-}" ]; do
                current_alias="${current_alias//$'\r'/}"
                [ -n "$current_alias" ] || continue
                printf '%s\n' "$current_alias"
            done |
            paste -sd, -
    )"
    [ -n "$INCLUDE_ALIASES" ] || fail "nodes.csv has no node rows"
}

resolve_management_alias_from_state
resolve_include_aliases

target_dir="$(dirname "$TARGET_NODES_FILE")"
state_target_dir="$(dirname "$TARGET_STATE_FILE")"
inventory_dir="$(dirname "$INVENTORY_OUTPUT")"
mkdir -p "$target_dir" "$state_target_dir" "$inventory_dir"

tmp_nodes="$(mktemp)"
trap 'rm -f "$tmp_nodes"' EXIT

{
    echo "$EXPECTED_CSV_HEADER"
    tail -n +2 "$SOURCE_NODES_FILE" | while IFS=, read -r current_alias endpoint connection _root_password extra || [ -n "${current_alias:-}" ]; do
        current_alias="${current_alias//$'\r'/}"
        endpoint="${endpoint//$'\r'/}"
        connection="${connection//$'\r'/}"
        extra="${extra//$'\r'/}"

        [ -n "$current_alias" ] || continue
        [ -z "$extra" ] || fail "nodes.csv row for $current_alias has too many columns"

        if [ "$current_alias" = "$MANAGEMENT_ALIAS" ]; then
            endpoint="local"
            connection="local"
        fi

        printf '%s,%s,%s,\n' "$current_alias" "$endpoint" "$connection"
    done
} > "$tmp_nodes"

install -m 600 "$tmp_nodes" "$TARGET_NODES_FILE"
echo "[OK] Sanitized nodes.csv written: $TARGET_NODES_FILE"

refresh_ansible_known_hosts() {
    local nodes_file="$1"
    local ssh_dir="/home/ansible/.ssh"
    local known_hosts="$ssh_dir/known_hosts"

    command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen command not found"
    command -v ssh-keyscan >/dev/null 2>&1 || fail "ssh-keyscan command not found"
    id ansible >/dev/null 2>&1 || fail "ansible user not found"

    install -d -m 700 -o ansible -g ansible "$ssh_dir"
    touch "$known_hosts"
    chown ansible:ansible "$known_hosts"
    chmod 600 "$known_hosts"

    tail -n +2 "$nodes_file" | while IFS=, read -r current_alias endpoint connection _root_password extra || [ -n "${current_alias:-}" ]; do
        current_alias="${current_alias//$'\r'/}"
        endpoint="${endpoint//$'\r'/}"
        connection="${connection//$'\r'/}"
        extra="${extra//$'\r'/}"

        [ -n "$current_alias" ] || continue
        [ -z "$extra" ] || fail "nodes.csv row for $current_alias has too many columns"
        [ "$connection" = "ssh" ] || continue
        [ "$endpoint" != "local" ] || continue

        echo "Refreshing ansible known_hosts for $current_alias: $endpoint"
        sudo -u ansible ssh-keygen -R "$endpoint" -f "$known_hosts" >/dev/null 2>&1 || true
        if ! ssh-keyscan -T 10 -H "$endpoint" >> "$known_hosts" 2>/dev/null; then
            fail "ssh-keyscan failed for $current_alias endpoint: $endpoint"
        fi
    done

    sort -u "$known_hosts" -o "$known_hosts"
    chown ansible:ansible "$known_hosts"
    chmod 600 "$known_hosts"
    echo "[OK] ansible known_hosts refreshed"
}

if [ "$REFRESH_KNOWN_HOSTS" = "true" ]; then
    refresh_ansible_known_hosts "$TARGET_NODES_FILE"
fi

state_args=()
if [ -n "$SOURCE_STATE_FILE" ]; then
    [ -f "$SOURCE_STATE_FILE" ] || fail "source state file not found: $SOURCE_STATE_FILE"
    first_state_line="$(head -n 1 "$SOURCE_STATE_FILE" | tr -d '\r')"
    [ "$first_state_line" = "$EXPECTED_STATE_CSV_HEADER" ] || fail "state.csv header must be exactly: $EXPECTED_STATE_CSV_HEADER"
    install -m 600 "$SOURCE_STATE_FILE" "$TARGET_STATE_FILE"
    echo "[OK] state.csv written: $TARGET_STATE_FILE"
    state_args=(--state-file "$TARGET_STATE_FILE")
fi

ensure_ansible_repo_access() {
    id ansible >/dev/null 2>&1 || fail "ansible user not found"
    chown -R ansible:ansible "$REPO_DIR"
}

ensure_ansible_repo_access

create_args=(
    "$REPO_DIR/tools/bootstrap/create_inventory.sh"
    --nodes-file "$TARGET_NODES_FILE"
    "${state_args[@]}"
    --include "$INCLUDE_ALIASES"
    --output "$INVENTORY_OUTPUT"
)

if [ "$RUN_CHECK" = "true" ]; then
    create_args+=(--check)
fi

cd "$REPO_DIR"
bash "${create_args[@]}"

echo "[OK] Orchestration inventory prepared: $INVENTORY_OUTPUT"
