#!/usr/bin/env bash

set -euo pipefail

EXPECTED_CSV_HEADER="current_alias,endpoint,connection,ansible_group,roles,root_password"
EXPECTED_STATE_CSV_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
REPO_DIR="/opt/ai-service-platform"
SOURCE_NODES_FILE=""
SOURCE_STATE_FILE=""
TARGET_NODES_FILE="/opt/ai-service-platform/operator/nodes.csv"
TARGET_STATE_FILE="/opt/ai-service-platform/operator/state.csv"
INVENTORY_OUTPUT="/opt/ai-service-platform/inventory.ini"
INCLUDE_ALIASES="vps1,vps2,vps3"
MANAGEMENT_ALIAS="vps3"
RUN_CHECK="true"

usage() {
    cat <<'USAGE'
Usage:
  sudo bash tools/bootstrap/prepare_vps3_inventory.sh \
    --source-nodes-file /tmp/nodes.csv

This script runs on VPS3 after bootstrap. It:
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
  --include LIST             Aliases to include. Default: vps1,vps2,vps3
  --management-alias ALIAS   Alias converted to local/local. Default: vps3
  --skip-check               Generate inventory without ansible ping.
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

target_dir="$(dirname "$TARGET_NODES_FILE")"
state_target_dir="$(dirname "$TARGET_STATE_FILE")"
inventory_dir="$(dirname "$INVENTORY_OUTPUT")"
mkdir -p "$target_dir" "$state_target_dir" "$inventory_dir"

tmp_nodes="$(mktemp)"
trap 'rm -f "$tmp_nodes"' EXIT

{
    echo "$EXPECTED_CSV_HEADER"
    tail -n +2 "$SOURCE_NODES_FILE" | while IFS=, read -r current_alias endpoint connection ansible_group roles _root_password extra || [ -n "${current_alias:-}" ]; do
        current_alias="${current_alias//$'\r'/}"
        endpoint="${endpoint//$'\r'/}"
        connection="${connection//$'\r'/}"
        ansible_group="${ansible_group//$'\r'/}"
        roles="${roles//$'\r'/}"
        extra="${extra//$'\r'/}"

        [ -n "$current_alias" ] || continue
        [ -z "$extra" ] || fail "nodes.csv row for $current_alias has too many columns"

        if [ "$current_alias" = "$MANAGEMENT_ALIAS" ]; then
            endpoint="local"
            connection="local"
        fi

        printf '%s,%s,%s,%s,%s,\n' "$current_alias" "$endpoint" "$connection" "$ansible_group" "$roles"
    done
} > "$tmp_nodes"

install -m 600 "$tmp_nodes" "$TARGET_NODES_FILE"
echo "[OK] Sanitized nodes.csv written: $TARGET_NODES_FILE"

state_args=()
if [ -n "$SOURCE_STATE_FILE" ]; then
    [ -f "$SOURCE_STATE_FILE" ] || fail "source state file not found: $SOURCE_STATE_FILE"
    first_state_line="$(head -n 1 "$SOURCE_STATE_FILE" | tr -d '\r')"
    [ "$first_state_line" = "$EXPECTED_STATE_CSV_HEADER" ] || fail "state.csv header must be exactly: $EXPECTED_STATE_CSV_HEADER"
    install -m 600 "$SOURCE_STATE_FILE" "$TARGET_STATE_FILE"
    echo "[OK] state.csv written: $TARGET_STATE_FILE"
    state_args=(--state-file "$TARGET_STATE_FILE")
fi

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

echo "[OK] VPS3 inventory prepared: $INVENTORY_OUTPUT"
