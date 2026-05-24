#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
EXPECTED_CSV_HEADER="current_alias,endpoint,connection,root_password"
EXPECTED_STATE_CSV_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
PUBLIC_KEY_BEGIN_MARKER="__ANSIBLE_CONTROL_PUBLIC_KEY_BEGIN__"
PUBLIC_KEY_END_MARKER="__ANSIBLE_CONTROL_PUBLIC_KEY_END__"

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}[OK] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[!] $1${NC}"
}

print_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

usage() {
    cat <<'USAGE'
Usage:
  bash tools/bootstrap/bootstrap_from_unix.sh \
    --nodes-file ./operator/nodes.csv \
    --state-file ./operator/state.csv \
    --alias vps2 \
    --ansible-authorized-key-file ./operator/ansible_control.managed_nodes.pub

Options:
  --nodes-file PATH                  Real operator CSV with root_password.
  --state-file PATH                  Operator state.csv. Required with nodes.csv.
  --alias VALUE                      current_alias to bootstrap.
  --setup-script PATH                setup_vps.sh path. Default: tools/bootstrap/setup_vps.sh
  --create-inventory-script PATH     create_inventory.sh path. Default: tools/bootstrap/create_inventory.sh
  --prepare-inventory-script PATH    prepare_vps3_inventory.sh path. Default: tools/bootstrap/prepare_vps3_inventory.sh
  --verify-control-script PATH       verify_control_node.sh path. Default: tools/bootstrap/verify_control_node.sh
  --ansible-authorized-key-file PATH VPS3 public key for managed nodes.
  --operator-dir PATH                Where to save extracted bootstrap keys.
                                     Default: ./operator
  --output-ansible-authorized-key-file PATH
                                     Where to save the VPS3 public key after management bootstrap.
                                     Default: ./operator/ansible_control.managed_nodes.pub
  --force                            Overwrite output public key file when it already exists.
  --regenerate-remote-keys           Set FORCE_REGENERATE_KEYS=1 for remote setup_vps.sh.
                                     For management nodes this also requires --force.
  -h, --help                         Show this help.

Requires sshpass when root_password is present.
USAGE
}

NODES_FILE=""
STATE_FILE=""
NODE_ALIAS=""
SETUP_SCRIPT="tools/bootstrap/setup_vps.sh"
CREATE_INVENTORY_SCRIPT="tools/bootstrap/create_inventory.sh"
PREPARE_INVENTORY_SCRIPT="tools/bootstrap/prepare_vps3_inventory.sh"
VERIFY_CONTROL_SCRIPT="tools/bootstrap/verify_control_node.sh"
ANSIBLE_AUTHORIZED_KEY_FILE=""
OPERATOR_DIR="./operator"
OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE="./operator/ansible_control.managed_nodes.pub"
FORCE_OVERWRITE="false"
REGENERATE_REMOTE_KEYS="false"

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
        --alias)
            NODE_ALIAS="${2:-}"
            shift 2
            ;;
        --setup-script)
            SETUP_SCRIPT="${2:-}"
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
        --verify-control-script)
            VERIFY_CONTROL_SCRIPT="${2:-}"
            shift 2
            ;;
        --ansible-authorized-key-file)
            ANSIBLE_AUTHORIZED_KEY_FILE="${2:-}"
            shift 2
            ;;
        --operator-dir)
            OPERATOR_DIR="${2:-}"
            shift 2
            ;;
        --output-ansible-authorized-key-file)
            OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE="${2:-}"
            shift 2
            ;;
        --force)
            FORCE_OVERWRITE="true"
            shift
            ;;
        --regenerate-remote-keys)
            REGENERATE_REMOTE_KEYS="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

require_file() {
    local path="$1"
    local label="$2"
    if [ ! -f "$path" ]; then
        print_error "$label not found: $path"
        exit 1
    fi
}

alias_list_has() {
    local aliases="$1"
    local wanted="$2"
    case "+$aliases+" in
        *"+$wanted+"*) return 0 ;;
        *) return 1 ;;
    esac
}

clear_root_password_for_alias() {
    local path="$1"
    local alias_to_clear="$2"
    local tmp_file
    local line_number=0
    local found_alias="false"

    tmp_file="$(mktemp)"
    while IFS=, read -r csv_alias csv_endpoint csv_connection csv_root_password extra || [ -n "${csv_alias:-}" ]; do
        line_number=$((line_number + 1))
        csv_alias="${csv_alias//$'\r'/}"
        csv_endpoint="${csv_endpoint//$'\r'/}"
        csv_connection="${csv_connection//$'\r'/}"
        csv_root_password="${csv_root_password//$'\r'/}"
        extra="${extra//$'\r'/}"

        if [ "$line_number" -eq 1 ]; then
            local header
            header="$csv_alias,$csv_endpoint,$csv_connection,$csv_root_password"
            if [ "$header" != "$EXPECTED_CSV_HEADER" ] || [ -n "$extra" ]; then
                rm -f "$tmp_file"
                print_error "nodes.csv header must be exactly:"
                echo "$EXPECTED_CSV_HEADER"
                exit 1
            fi
            echo "$EXPECTED_CSV_HEADER" > "$tmp_file"
            continue
        fi

        [ -n "$csv_alias" ] || continue
        if [ -n "$extra" ]; then
            rm -f "$tmp_file"
            print_error "nodes.csv row for $csv_alias has too many columns"
            exit 1
        fi
        if [ "$csv_alias" = "$alias_to_clear" ]; then
            csv_root_password=""
            found_alias="true"
        fi
        printf '%s,%s,%s,%s\n' "$csv_alias" "$csv_endpoint" "$csv_connection" "$csv_root_password" >> "$tmp_file"
    done < "$path"

    if [ "$found_alias" != "true" ]; then
        rm -f "$tmp_file"
        print_error "Alias not found while clearing root_password: $alias_to_clear"
        exit 1
    fi

    mv "$tmp_file" "$path"
    print_success "Cleared root_password in local nodes.csv for $alias_to_clear"
}

extract_marked_block() {
    local log_path="$1"
    local begin_marker="$2"
    local end_marker="$3"
    local label="$4"
    local output

    output="$(
        awk -v begin="$begin_marker" -v end="$end_marker" '
            {
                line=$0
                gsub(/\033\[[0-9;]*m/, "", line)
            }
            line == begin {
                if (capture || seen) {
                    duplicate=1
                }
                capture=1
                seen=1
                next
            }
            line == end {
                if (!capture) {
                    stray_end=1
                }
                capture=0
                next
            }
            capture { print line }
            END {
                if (!seen || capture || duplicate || stray_end) {
                    exit 2
                }
            }
        ' "$log_path"
    )" || {
        print_error "Could not capture $label from remote bootstrap output."
        exit 1
    }

    if [ "$(printf '%s\n' "$output" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 0 ]; then
        print_error "Captured empty $label from remote bootstrap output."
        exit 1
    fi

    printf '%s\n' "$output"
}

write_key_file() {
    local path="$1"
    local content="$2"
    local mode="$3"
    local output_dir

    if [ -f "$path" ] && [ "$FORCE_OVERWRITE" != "true" ]; then
        print_error "Output key file already exists: $path"
        print_error "Use --force to overwrite it."
        exit 1
    fi

    output_dir="$(dirname "$path")"
    mkdir -p "$output_dir"
    printf '%s\n' "$content" > "$path"
    chmod "$mode" "$path"
}

assert_output_key_path_available() {
    local path="$1"
    if [ -f "$path" ] && [ "$FORCE_OVERWRITE" != "true" ]; then
        print_error "Output key file already exists: $path"
        print_error "Use --force to overwrite it."
        exit 1
    fi
}

assert_bootstrap_key_paths_available() {
    local alias_to_save="$1"
    local is_management="$2"
    local alias_dir="$OPERATOR_DIR/$alias_to_save"

    assert_output_key_path_available "$alias_dir/deploy_key"
    assert_output_key_path_available "$alias_dir/admin_key"

    if [ "$is_management" = "true" ]; then
        assert_output_key_path_available "$alias_dir/ansible_control_key"
        assert_output_key_path_available "$alias_dir/ansible_control.managed_nodes.pub"
        assert_output_key_path_available "$OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE"
    fi
}

save_bootstrap_keys() {
    local alias_to_save="$1"
    local is_management="$2"
    local alias_dir="$OPERATOR_DIR/$alias_to_save"
    local deploy_key
    local admin_key
    local ansible_key
    local public_key

    mkdir -p "$alias_dir"

    deploy_key="$(extract_marked_block "$remote_log" "--- BEGIN SSH_KEY ---" "--- END SSH_KEY ---" "deploy private key")"
    admin_key="$(extract_marked_block "$remote_log" "--- BEGIN ADMIN KEY ---" "--- END ADMIN KEY ---" "admin private key")"

    write_key_file "$alias_dir/deploy_key" "$deploy_key" 600
    write_key_file "$alias_dir/admin_key" "$admin_key" 600
    print_success "Saved bootstrap keys: $alias_dir"

    if [ "$is_management" = "true" ]; then
        ansible_key="$(extract_marked_block "$remote_log" "--- BEGIN ANSIBLE CONTROL KEY ---" "--- END ANSIBLE CONTROL KEY ---" "Ansible control private key")"
        public_key="$(extract_marked_block "$remote_log" "$PUBLIC_KEY_BEGIN_MARKER" "$PUBLIC_KEY_END_MARKER" "Ansible control public key")"
        if [ "$(printf '%s\n' "$public_key" | sed '/^$/d' | wc -l | tr -d ' ')" -ne 1 ]; then
            print_error "Could not capture exactly one Ansible control public key from remote bootstrap output."
            exit 1
        fi

        write_key_file "$alias_dir/ansible_control_key" "$ansible_key" 600
        write_key_file "$alias_dir/ansible_control.managed_nodes.pub" "$public_key" 644
        write_key_file "$OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE" "$public_key" 644
        print_success "Saved Ansible control public key: $OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE"
    fi
}

require_file "$NODES_FILE" "--nodes-file"
[ -n "$STATE_FILE" ] || {
    print_error "--state-file is required. nodes.csv is only an address book; bootstrap behavior is selected from state.csv."
    exit 1
}
require_file "$STATE_FILE" "--state-file"
require_file "$SETUP_SCRIPT" "--setup-script"
if [ -n "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
    require_file "$ANSIBLE_AUTHORIZED_KEY_FILE" "--ansible-authorized-key-file"
fi
if [ -z "$NODE_ALIAS" ]; then
    print_error "--alias is required"
    usage
    exit 1
fi

line_number=0
found="false"
current_alias=""
endpoint=""
connection=""
root_password=""

while IFS=, read -r csv_alias csv_endpoint csv_connection csv_root_password extra || [ -n "${csv_alias:-}" ]; do
    line_number=$((line_number + 1))
    csv_alias="${csv_alias//$'\r'/}"
    csv_endpoint="${csv_endpoint//$'\r'/}"
    csv_connection="${csv_connection//$'\r'/}"
    csv_root_password="${csv_root_password//$'\r'/}"
    extra="${extra//$'\r'/}"

    if [ "$line_number" -eq 1 ]; then
        header="$csv_alias,$csv_endpoint,$csv_connection,$csv_root_password"
        if [ "$header" != "$EXPECTED_CSV_HEADER" ] || [ -n "$extra" ]; then
            print_error "nodes.csv header must be exactly:"
            echo "$EXPECTED_CSV_HEADER"
            exit 1
        fi
        continue
    fi

    if [ "$csv_alias" = "$NODE_ALIAS" ]; then
        current_alias="$csv_alias"
        endpoint="$csv_endpoint"
        connection="$csv_connection"
        root_password="$csv_root_password"
        found="true"
        break
    fi
done < "$NODES_FILE"

if [ "$found" != "true" ]; then
    print_error "Alias not found in nodes file: $NODE_ALIAS"
    exit 1
fi
if [ "$connection" = "local" ] || [ "$endpoint" = "local" ]; then
    print_error "Cannot bootstrap remote VPS with endpoint=local: $NODE_ALIAS"
    print_error "For first bootstrap from this runner, set endpoint to the VPS public DNS/IP and connection=ssh."
    print_error "Use local only later in the VPS3 inventory CSV if needed."
    exit 1
fi
if [ -z "$root_password" ]; then
    print_error "root_password is required for first remote bootstrap from Unix runner: $NODE_ALIAS"
    exit 1
fi
if ! command -v sshpass >/dev/null 2>&1; then
    print_error "sshpass is required for password bootstrap. Install sshpass or run bootstrap manually."
    exit 1
fi

is_management_node="false"
state_first_line="$(head -n 1 "$STATE_FILE" | tr -d '\r')"
[ "$state_first_line" = "$EXPECTED_STATE_CSV_HEADER" ] || {
    print_error "state.csv header must be exactly: $EXPECTED_STATE_CSV_HEADER"
    exit 1
}
orchestration_rows=0
while IFS=, read -r kind name _ansible_group active_aliases _candidate_aliases _old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    active_aliases="${active_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ "$kind" = "$EXPECTED_STATE_CSV_HEADER" ] && continue
    [ -z "$kind" ] && continue
    [ -z "$extra" ] || {
        print_error "state.csv orchestration row has too many columns"
        exit 1
    }
    if { [ "$kind" = "platform_role" ] || [ "$kind" = "role" ]; } && [ "$name" = "orchestration" ] && [ "$row_state" = "present" ]; then
        orchestration_rows=$((orchestration_rows + 1))
        if alias_list_has "$active_aliases" "$NODE_ALIAS"; then
            is_management_node="true"
        fi
    fi
done < "$STATE_FILE"
[ "$orchestration_rows" -eq 1 ] || {
    print_error "state.csv must contain exactly one present platform_role orchestration row"
    exit 1
}
if [ "$is_management_node" != "true" ] && [ -z "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
    print_error "Managed node $NODE_ALIAS requires --ansible-authorized-key-file"
    exit 1
fi
if [ "$is_management_node" = "true" ]; then
    require_file "$CREATE_INVENTORY_SCRIPT" "--create-inventory-script"
    require_file "$PREPARE_INVENTORY_SCRIPT" "--prepare-inventory-script"
    require_file "$VERIFY_CONTROL_SCRIPT" "--verify-control-script"
fi
if [ "$REGENERATE_REMOTE_KEYS" = "true" ] &&
    [ "$is_management_node" = "true" ] &&
    [ "$FORCE_OVERWRITE" != "true" ]; then
    print_error "--regenerate-remote-keys for a management node requires --force so the local Ansible public key file is refreshed explicitly."
    exit 1
fi
assert_bootstrap_key_paths_available "$NODE_ALIAS" "$is_management_node"
sanitized_nodes="$(mktemp)"
remote_log="$(mktemp)"
trap 'rm -f "$sanitized_nodes" "$remote_log"' EXIT
{
    echo "$EXPECTED_CSV_HEADER"
    tail -n +2 "$NODES_FILE" | while IFS=, read -r csv_alias csv_endpoint csv_connection _csv_root_password extra || [ -n "${csv_alias:-}" ]; do
        csv_alias="${csv_alias//$'\r'/}"
        csv_endpoint="${csv_endpoint//$'\r'/}"
        csv_connection="${csv_connection//$'\r'/}"
        if [ -n "$csv_alias" ]; then
            printf '%s,%s,%s,\n' "$csv_alias" "$csv_endpoint" "$csv_connection"
        fi
    done
} > "$sanitized_nodes"

remote="root@$endpoint"
ssh_base=(sshpass -p "$root_password" ssh -o StrictHostKeyChecking=accept-new "$remote")
scp_base=(sshpass -p "$root_password" scp -o StrictHostKeyChecking=accept-new)

print_header "Bootstrap $NODE_ALIAS from Unix runner"
echo "Step 1/4: copy setup_vps.sh"
"${scp_base[@]}" "$SETUP_SCRIPT" "$remote:/tmp/setup_vps.sh"
echo "Step 2/4: copy sanitized nodes.csv"
"${scp_base[@]}" "$sanitized_nodes" "$remote:/tmp/nodes.csv"
if [ -n "$STATE_FILE" ]; then
    echo "Step 2a/4: copy state.csv"
    "${scp_base[@]}" "$STATE_FILE" "$remote:/tmp/state.csv"
fi
if [ "$is_management_node" = "true" ]; then
    echo "Step 2b/4: copy control inventory helpers"
    "${scp_base[@]}" "$CREATE_INVENTORY_SCRIPT" "$remote:/tmp/create_inventory.sh"
    "${scp_base[@]}" "$PREPARE_INVENTORY_SCRIPT" "$remote:/tmp/prepare_vps3_inventory.sh"
    "${scp_base[@]}" "$VERIFY_CONTROL_SCRIPT" "$remote:/tmp/verify_control_node.sh"
fi
if [ -n "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
    echo "Step 2c/4: copy Ansible control public key"
    "${scp_base[@]}" "$ANSIBLE_AUTHORIZED_KEY_FILE" "$remote:/tmp/ansible_control.managed_nodes.pub"
fi

if [ -n "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
    setup_command="ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --state-file /tmp/state.csv --alias '$NODE_ALIAS'"
else
    setup_command="bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --state-file /tmp/state.csv --alias '$NODE_ALIAS'"
fi
if [ "$REGENERATE_REMOTE_KEYS" = "true" ]; then
    setup_command="FORCE_REGENERATE_KEYS=1 $setup_command"
fi

if [ "$is_management_node" = "true" ]; then
    if [ -n "$STATE_FILE" ]; then
        state_arg="--source-state-file /tmp/state.csv"
    else
        state_arg=""
    fi
    prepare_inventory_command="if [ \$rc -eq 0 ]; then mkdir -p /opt/ai-service-platform/tools/bootstrap; install -m 700 /tmp/create_inventory.sh /opt/ai-service-platform/tools/bootstrap/create_inventory.sh; install -m 700 /tmp/prepare_vps3_inventory.sh /opt/ai-service-platform/tools/bootstrap/prepare_vps3_inventory.sh; install -m 700 /tmp/verify_control_node.sh /opt/ai-service-platform/tools/bootstrap/verify_control_node.sh; bash /opt/ai-service-platform/tools/bootstrap/prepare_vps3_inventory.sh --source-nodes-file /tmp/nodes.csv $state_arg --skip-check; fi"
    emit_key_command="if [ \$rc -eq 0 ]; then echo $PUBLIC_KEY_BEGIN_MARKER; cat /home/ansible/.ssh/ansible_control.managed_nodes.pub; echo $PUBLIC_KEY_END_MARKER; fi"
else
    prepare_inventory_command=":"
    emit_key_command=":"
fi
remote_command="set +e; $setup_command; rc=\$?; $prepare_inventory_command; $emit_key_command; rm -f /tmp/setup_vps.sh /tmp/nodes.csv /tmp/state.csv /tmp/ansible_control.managed_nodes.pub /tmp/create_inventory.sh /tmp/prepare_vps3_inventory.sh /tmp/verify_control_node.sh; exit \$rc"

echo "Step 3/4: run remote bootstrap"
echo "Expected next output: AI Service Platform VPS bootstrap"
echo "If this step stays silent for a long time, check SSH host key prompts, SSH banner prompts, and root password auth."
set +e
"${ssh_base[@]}" "$remote_command" 2>&1 | tee "$remote_log"
remote_exit_code="${PIPESTATUS[0]}"
set -e
if [ "$remote_exit_code" -ne 0 ]; then
    print_error "remote setup_vps.sh failed"
    exit 1
fi

echo "Step 4/4: save bootstrap keys"
save_bootstrap_keys "$NODE_ALIAS" "$is_management_node"
clear_root_password_for_alias "$NODES_FILE" "$NODE_ALIAS"
print_success "Bootstrap completed for $NODE_ALIAS"
