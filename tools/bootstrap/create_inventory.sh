#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
EXPECTED_CSV_HEADER="current_alias,endpoint,connection,ansible_group,roles,root_password"
EXPECTED_STATE_CSV_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"

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
  sudo bash tools/bootstrap/create_inventory.sh \
    --nodes-file /opt/ai-service-platform/operator/nodes.csv \
    --include vps1,vps2,vps3 \
    --check

CSV header must be exactly:
  current_alias,endpoint,connection,ansible_group,roles,root_password

CSV example:
  vps1,vps01.example.com,ssh,prod,production+vpn-edge,
  vps2,vps02.example.com,ssh,backup,preprod+hot-standby+backup+vpn-edge,
  vps3,local,local,management,management+monitoring+orchestration+vpn-edge,

State CSV header must be exactly:
  kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state

State CSV example:
  role,production,prod,vps1,,,present
  role,orchestration,management,vps3,vps4,,present
  service,vpn,vpn_edges,vps1+vps2+vps3,,,present

Fallback without CSV:
  --active ROLE:NODE=ENDPOINT
  --candidate ROLE:NODE=ENDPOINT
  --old ROLE:NODE=ENDPOINT

Options:
  --nodes-file PATH  Operator CSV path. If omitted, fallback bindings are used.
  --state-file PATH  Optional operator state CSV. Groups come from state active/candidate/old aliases.
  --include LIST     Optional comma-separated aliases to include from CSV.
  --output PATH      Inventory output path. Default: /opt/ai-service-platform/inventory.ini
  --key-file PATH    Ansible private key path. Default: /home/ansible/.ssh/ansible_control
  --ansible-user     Managed nodes SSH user. Default: ansible
  --check            Run ansible -i <output> all -m ping after writing.
  -h, --help         Show this help.

Use connection=local for the management node when Ansible runs on that same node.
This script writes a real operator inventory. Do not commit the generated file.
USAGE
}

OUTPUT_PATH="/opt/ai-service-platform/inventory.ini"
KEY_FILE="/home/ansible/.ssh/ansible_control"
ANSIBLE_USER="ansible"
NODES_FILE=""
STATE_FILE=""
INCLUDE_ALIASES=""
RUN_CHECK="false"
BINDINGS=()

add_binding() {
    local state="$1"
    local binding="$2"
    BINDINGS+=("${state}:${binding}")
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
        --include)
            INCLUDE_ALIASES="${2:-}"
            shift 2
            ;;
        --active)
            add_binding "active" "${2:-}"
            shift 2
            ;;
        --candidate)
            add_binding "candidate" "${2:-}"
            shift 2
            ;;
        --old)
            add_binding "old" "${2:-}"
            shift 2
            ;;
        --output)
            OUTPUT_PATH="${2:-}"
            shift 2
            ;;
        --key-file)
            KEY_FILE="${2:-}"
            shift 2
            ;;
        --ansible-user)
            ANSIBLE_USER="${2:-}"
            shift 2
            ;;
        --check)
            RUN_CHECK="true"
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

require_value() {
    local value="$1"
    local option_name="$2"
    if [ -z "$value" ]; then
        print_error "$option_name is required."
        usage
        exit 1
    fi
    if printf '%s\n' "$value" | grep -Eq '[[:space:]]'; then
        print_error "$option_name must not contain whitespace: $value"
        exit 1
    fi
}

require_csv_value() {
    local value="$1"
    local field_name="$2"
    local line_number="$3"
    if [ -z "$value" ]; then
        print_error "nodes.csv line $line_number has empty required field: $field_name"
        exit 1
    fi
}

include_alias() {
    local alias="$1"
    if [ -z "$INCLUDE_ALIASES" ]; then
        return 0
    fi
    case ",$INCLUDE_ALIASES," in
        *",$alias,"*) return 0 ;;
        *) return 1 ;;
    esac
}

roles_have() {
    local roles="$1"
    local wanted="$2"
    case "+$roles+" in
        *"+$wanted+"*) return 0 ;;
        *) return 1 ;;
    esac
}

role_to_group() {
    case "$1" in
        production|production-runtime) echo "prod" ;;
        preprod-hot-standby-backup) echo "backup" ;;
        management-monitoring-orchestration) echo "management" ;;
        vpn-only-edge) echo "vpn_edges" ;;
        *)
            print_error "Unsupported platform role: $1"
            exit 1
            ;;
    esac
}

state_group_name() {
    local state="$1"
    local base_group="$2"
    if [ "$state" = "active" ]; then
        echo "$base_group"
    else
        echo "${state}_${base_group}"
    fi
}

node_to_host_alias() {
    printf '%s\n' "$1" | tr '-' '_'
}

validate_connection() {
    local connection="$1"
    local line_number="$2"
    case "$connection" in
        ssh|local) ;;
        *)
            print_error "nodes.csv line $line_number has unsupported connection: $connection"
            exit 1
            ;;
    esac
}

validate_group() {
    local group="$1"
    local line_number="$2"
    case "$group" in
        prod|backup|management|vpn_edges|candidate_prod|old_prod|candidate_backup|old_backup|candidate_management|old_management|candidate_vpn_edges|old_vpn_edges) ;;
        *)
            print_error "nodes.csv line $line_number has unsupported ansible_group: $group"
            exit 1
            ;;
    esac
}

validate_roles() {
    local roles="$1"
    local line_number="$2"
    local role
    local old_ifs="$IFS"
    IFS=+
    for role in $roles; do
        IFS="$old_ifs"
        case "$role" in
            production|production-runtime|preprod|hot-standby|backup|management|monitoring|orchestration|vpn-edge|vpn-cascade) ;;
            *)
                print_error "nodes.csv line $line_number has unsupported role: $role"
                exit 1
                ;;
        esac
        IFS=+
    done
    IFS="$old_ifs"
}

validate_state_kind() {
    local kind="$1"
    local line_number="$2"
    case "$kind" in
        role|service) ;;
        *)
            print_error "state.csv line $line_number has unsupported kind: $kind"
            exit 1
            ;;
    esac
}

validate_state_value() {
    local state="$1"
    local line_number="$2"
    case "$state" in
        present|absent|purged) ;;
        *)
            print_error "state.csv line $line_number has unsupported state: $state"
            exit 1
            ;;
    esac
}

split_aliases() {
    local aliases="$1"
    local old_ifs="$IFS"
    local alias_item
    IFS=+
    for alias_item in $aliases; do
        IFS="$old_ifs"
        if [ -n "$alias_item" ]; then
            printf '%s\n' "$alias_item"
        fi
        IFS=+
    done
    IFS="$old_ifs"
}

get_node_record() {
    local alias="$1"
    local record
    for record in "${NODE_RECORDS[@]}"; do
        IFS='|' read -r node_alias _endpoint _connection _ansible_group _roles <<< "$record"
        if [ "$node_alias" = "$alias" ]; then
            printf '%s\n' "$record"
            return 0
        fi
    done
    return 1
}

add_state_alias_binding() {
    local lifecycle="$1"
    local kind="$2"
    local name="$3"
    local ansible_group="$4"
    local alias="$5"
    local line_number="$6"

    if ! include_alias "$alias"; then
        return 0
    fi

    local record
    if ! record="$(get_node_record "$alias")"; then
        print_error "state.csv line $line_number references unknown alias: $alias"
        exit 1
    fi

    IFS='|' read -r node_alias endpoint connection _primary_group roles <<< "$record"
    local group
    group="$(state_group_name "$lifecycle" "$ansible_group")"
    PARSED_BINDINGS+=("$lifecycle|$kind:$name|$group|$node_alias|$node_alias|$endpoint|$connection")
}

read_nodes_file() {
    if [ ! -f "$NODES_FILE" ]; then
        print_error "nodes file not found: $NODES_FILE"
        exit 1
    fi

    local line_number=0
    local matched_count=0
    local matched_aliases=","
    local header_seen="false"
    local current_alias endpoint connection ansible_group roles root_password extra
    NODE_RECORDS=()

    while IFS=, read -r current_alias endpoint connection ansible_group roles root_password extra || [ -n "${current_alias:-}" ]; do
        line_number=$((line_number + 1))
        current_alias="${current_alias//$'\r'/}"
        endpoint="${endpoint//$'\r'/}"
        connection="${connection//$'\r'/}"
        ansible_group="${ansible_group//$'\r'/}"
        roles="${roles//$'\r'/}"
        root_password="${root_password//$'\r'/}"
        extra="${extra//$'\r'/}"

        if [ "$line_number" -eq 1 ]; then
            local header
            header="$current_alias,$endpoint,$connection,$ansible_group,$roles,$root_password"
            if [ "$header" != "$EXPECTED_CSV_HEADER" ] || [ -n "$extra" ]; then
                print_error "nodes.csv header must be exactly:"
                echo "$EXPECTED_CSV_HEADER"
                exit 1
            fi
            header_seen="true"
            continue
        fi

        if [ -z "$current_alias" ] && [ -z "$endpoint" ] && [ -z "$connection" ] && [ -z "$ansible_group" ] && [ -z "$roles" ] && [ -z "$root_password" ]; then
            continue
        fi
        if [ -n "$extra" ]; then
            print_error "nodes.csv line $line_number has too many columns"
            exit 1
        fi

        require_csv_value "$current_alias" "current_alias" "$line_number"
        require_csv_value "$endpoint" "endpoint" "$line_number"
        require_csv_value "$connection" "connection" "$line_number"
        require_csv_value "$ansible_group" "ansible_group" "$line_number"
        require_csv_value "$roles" "roles" "$line_number"
        validate_connection "$connection" "$line_number"
        validate_group "$ansible_group" "$line_number"
        validate_roles "$roles" "$line_number"

        if [ "$connection" = "local" ] && [ "$endpoint" != "local" ]; then
            print_error "nodes.csv line $line_number uses connection=local but endpoint is not local"
            exit 1
        fi

        if include_alias "$current_alias"; then
            matched_count=$((matched_count + 1))
            matched_aliases="${matched_aliases}${current_alias},"
            if [ -z "$STATE_FILE" ]; then
                PARSED_BINDINGS+=("active|$roles|$ansible_group|$current_alias|$current_alias|$endpoint|$connection")
                if roles_have "$roles" "vpn-edge" && [ "$ansible_group" != "vpn_edges" ]; then
                    PARSED_BINDINGS+=("active|$roles|vpn_edges|$current_alias|$current_alias|$endpoint|$connection")
                fi
            fi
        fi
        NODE_RECORDS+=("$current_alias|$endpoint|$connection|$ansible_group|$roles")
    done < "$NODES_FILE"

    if [ "$header_seen" != "true" ]; then
        print_error "nodes.csv is empty: $NODES_FILE"
        exit 1
    fi
    if [ "$matched_count" -eq 0 ]; then
        if [ -n "$INCLUDE_ALIASES" ]; then
            print_error "No aliases from --include matched nodes file: $INCLUDE_ALIASES"
        else
            print_error "nodes.csv has no node rows: $NODES_FILE"
        fi
        exit 1
    fi

    if [ -n "$INCLUDE_ALIASES" ]; then
        local include_alias_item
        local old_ifs="$IFS"
        IFS=,
        for include_alias_item in $INCLUDE_ALIASES; do
            IFS="$old_ifs"
            if [ -z "$include_alias_item" ]; then
                print_error "--include contains an empty alias: $INCLUDE_ALIASES"
                exit 1
            fi
            case "$matched_aliases" in
                *",$include_alias_item,"*) ;;
                *)
                    print_error "--include alias not found in nodes file: $include_alias_item"
                    exit 1
                    ;;
            esac
            IFS=,
        done
        IFS="$old_ifs"
    fi
}

read_state_file() {
    if [ ! -f "$STATE_FILE" ]; then
        print_error "state file not found: $STATE_FILE"
        exit 1
    fi

    local line_number=0
    local matched_count=0
    local header_seen="false"
    local kind name ansible_group active_aliases candidate_aliases old_aliases state extra

    while IFS=, read -r kind name ansible_group active_aliases candidate_aliases old_aliases state extra || [ -n "${kind:-}" ]; do
        line_number=$((line_number + 1))
        kind="${kind//$'\r'/}"
        name="${name//$'\r'/}"
        ansible_group="${ansible_group//$'\r'/}"
        active_aliases="${active_aliases//$'\r'/}"
        candidate_aliases="${candidate_aliases//$'\r'/}"
        old_aliases="${old_aliases//$'\r'/}"
        state="${state//$'\r'/}"
        extra="${extra//$'\r'/}"

        if [ "$line_number" -eq 1 ]; then
            local header
            header="$kind,$name,$ansible_group,$active_aliases,$candidate_aliases,$old_aliases,$state"
            if [ "$header" != "$EXPECTED_STATE_CSV_HEADER" ] || [ -n "$extra" ]; then
                print_error "state.csv header must be exactly:"
                echo "$EXPECTED_STATE_CSV_HEADER"
                exit 1
            fi
            header_seen="true"
            continue
        fi

        if [ -z "$kind" ] && [ -z "$name" ] && [ -z "$ansible_group" ] && [ -z "$active_aliases" ] && [ -z "$candidate_aliases" ] && [ -z "$old_aliases" ] && [ -z "$state" ]; then
            continue
        fi
        if [ -n "$extra" ]; then
            print_error "state.csv line $line_number has too many columns"
            exit 1
        fi

        require_csv_value "$kind" "kind" "$line_number"
        require_csv_value "$name" "name" "$line_number"
        require_csv_value "$ansible_group" "ansible_group" "$line_number"
        require_csv_value "$state" "state" "$line_number"
        validate_state_kind "$kind" "$line_number"
        validate_group "$ansible_group" "$line_number"
        validate_state_value "$state" "$line_number"

        local alias_item
        while IFS= read -r alias_item; do
            matched_count=$((matched_count + 1))
            add_state_alias_binding "active" "$kind" "$name" "$ansible_group" "$alias_item" "$line_number"
        done < <(split_aliases "$active_aliases")
        while IFS= read -r alias_item; do
            matched_count=$((matched_count + 1))
            add_state_alias_binding "candidate" "$kind" "$name" "$ansible_group" "$alias_item" "$line_number"
        done < <(split_aliases "$candidate_aliases")
        while IFS= read -r alias_item; do
            matched_count=$((matched_count + 1))
            add_state_alias_binding "old" "$kind" "$name" "$ansible_group" "$alias_item" "$line_number"
        done < <(split_aliases "$old_aliases")
    done < "$STATE_FILE"

    if [ "$header_seen" != "true" ]; then
        print_error "state.csv is empty: $STATE_FILE"
        exit 1
    fi
    if [ "$matched_count" -eq 0 ]; then
        print_error "state.csv has no active/candidate/old aliases: $STATE_FILE"
        exit 1
    fi
    if [ "${#PARSED_BINDINGS[@]}" -eq 0 ]; then
        print_error "state.csv aliases did not match selected --include aliases"
        exit 1
    fi
}

parse_fallback_binding() {
    local raw="$1"
    local state="${raw%%:*}"
    local rest="${raw#*:}"
    local role="${rest%%:*}"
    local node_and_endpoint="${rest#*:}"
    local node="${node_and_endpoint%%=*}"
    local endpoint="${node_and_endpoint#*=}"

    if [ "$rest" = "$raw" ] || [ "$node_and_endpoint" = "$rest" ] || [ "$endpoint" = "$node_and_endpoint" ]; then
        print_error "Invalid binding format: $raw"
        echo "Expected: STATE:ROLE:NODE=ENDPOINT"
        exit 1
    fi

    case "$state" in
        active|candidate|old) ;;
        *)
            print_error "Unsupported lifecycle state: $state"
            exit 1
            ;;
    esac

    require_value "$role" "ROLE in $raw"
    require_value "$node" "NODE in $raw"
    require_value "$endpoint" "ENDPOINT in $raw"

    local base_group
    local group
    local host_alias
    local connection
    base_group="$(role_to_group "$role")"
    group="$(state_group_name "$state" "$base_group")"
    host_alias="$(node_to_host_alias "$node")"
    connection="ssh"
    if [ "$endpoint" = "local" ]; then
        connection="local"
    fi

    PARSED_BINDINGS+=("$state|$role|$group|$node|$host_alias|$endpoint|$connection")
}

require_value "$OUTPUT_PATH" "--output"
require_value "$KEY_FILE" "--key-file"
require_value "$ANSIBLE_USER" "--ansible-user"
if [ -n "$INCLUDE_ALIASES" ] && printf '%s\n' "$INCLUDE_ALIASES" | grep -Eq '[[:space:]]'; then
    print_error "--include must be a comma-separated list without whitespace"
    exit 1
fi

PARSED_BINDINGS=()
if [ -n "$NODES_FILE" ]; then
    if [ "${#BINDINGS[@]}" -gt 0 ]; then
        print_error "--nodes-file cannot be combined with --active/--candidate/--old fallback bindings"
        exit 1
    fi
    read_nodes_file
    if [ -n "$STATE_FILE" ]; then
        read_state_file
    fi
else
    if [ -n "$STATE_FILE" ]; then
        print_error "--state-file requires --nodes-file"
        exit 1
    fi
    if [ -n "$INCLUDE_ALIASES" ]; then
        print_error "--include requires --nodes-file"
        exit 1
    fi
    if [ "${#BINDINGS[@]}" -eq 0 ]; then
        print_error "Either --nodes-file or at least one --active/--candidate/--old fallback binding is required."
        usage
        exit 1
    fi
    for binding in "${BINDINGS[@]}"; do
        parse_fallback_binding "$binding"
    done
fi

OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"

print_header "AI Service Platform Ansible inventory"

echo "Inventory bindings:"
for parsed in "${PARSED_BINDINGS[@]}"; do
    IFS='|' read -r state role group node host_alias endpoint connection <<< "$parsed"
    echo "  $state $role -> $host_alias ($group, $connection): $endpoint"
done
echo "  output:       $OUTPUT_PATH"
echo "  ansible user: $ANSIBLE_USER"
echo "  key file:     $KEY_FILE"
echo ""

mkdir -p "$OUTPUT_DIR"

tmp_file="$(mktemp)"
umask 077
{
    cat <<'EOF'
# AI Service Platform real Ansible inventory.
#
# Generated by tools/bootstrap/create_inventory.sh.
# Do not commit this file. It may contain real operator endpoints.

EOF

    for group in prod backup management vpn_edges candidate_prod old_prod candidate_backup old_backup candidate_management old_management candidate_vpn_edges old_vpn_edges; do
        echo "[$group]"
        printed_hosts=","
        for parsed in "${PARSED_BINDINGS[@]}"; do
            IFS='|' read -r state role parsed_group node host_alias endpoint connection <<< "$parsed"
            if [ "$parsed_group" != "$group" ]; then
                continue
            fi
            case "$printed_hosts" in
                *",$host_alias,"*) continue ;;
            esac
            printed_hosts="${printed_hosts}${host_alias},"
            if [ "$connection" = "local" ]; then
                echo "$host_alias ansible_connection=local"
            else
                echo "$host_alias ansible_host=$endpoint ansible_user=$ANSIBLE_USER ansible_ssh_private_key_file=$KEY_FILE"
            fi
        done
        echo ""
    done

    cat <<'EOF'
[platform_nodes:children]
prod
backup
management
vpn_edges

[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOF
} > "$tmp_file"

mv "$tmp_file" "$OUTPUT_PATH"
chmod 600 "$OUTPUT_PATH"
print_success "Inventory written: $OUTPUT_PATH"

if [ "$RUN_CHECK" = "true" ]; then
    if ! command -v ansible >/dev/null 2>&1; then
        print_error "ansible command not found; cannot run --check."
        exit 1
    fi
    print_header "Running Ansible connectivity check"
    ansible -i "$OUTPUT_PATH" all -m ping
    print_success "Ansible connectivity check completed"
fi

print_warning "Do not commit $OUTPUT_PATH. Real inventory belongs on VPS3/operator storage only."
