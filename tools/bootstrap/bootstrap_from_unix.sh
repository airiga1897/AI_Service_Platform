#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
EXPECTED_CSV_HEADER="current_alias,endpoint,connection,ansible_group,roles,root_password"

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
    --alias vps2 \
    --ansible-authorized-key-file ./operator/ansible_control.managed_nodes.pub

Options:
  --nodes-file PATH                  Real operator CSV with root_password.
  --alias VALUE                      current_alias to bootstrap.
  --setup-script PATH                setup_vps.sh path. Default: tools/bootstrap/setup_vps.sh
  --ansible-authorized-key-file PATH VPS3 public key for managed nodes.
  -h, --help                         Show this help.

Requires sshpass when root_password is present.
USAGE
}

NODES_FILE=""
NODE_ALIAS=""
SETUP_SCRIPT="tools/bootstrap/setup_vps.sh"
ANSIBLE_AUTHORIZED_KEY_FILE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --nodes-file)
            NODES_FILE="${2:-}"
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
        --ansible-authorized-key-file)
            ANSIBLE_AUTHORIZED_KEY_FILE="${2:-}"
            shift 2
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

has_role() {
    local roles="$1"
    local wanted="$2"
    case "+$roles+" in
        *"+$wanted+"*) return 0 ;;
        *) return 1 ;;
    esac
}

require_file "$NODES_FILE" "--nodes-file"
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
ansible_group=""
roles=""
root_password=""

while IFS=, read -r csv_alias csv_endpoint csv_connection csv_group csv_roles csv_root_password extra || [ -n "${csv_alias:-}" ]; do
    line_number=$((line_number + 1))
    csv_alias="${csv_alias//$'\r'/}"
    csv_endpoint="${csv_endpoint//$'\r'/}"
    csv_connection="${csv_connection//$'\r'/}"
    csv_group="${csv_group//$'\r'/}"
    csv_roles="${csv_roles//$'\r'/}"
    csv_root_password="${csv_root_password//$'\r'/}"
    extra="${extra//$'\r'/}"

    if [ "$line_number" -eq 1 ]; then
        header="$csv_alias,$csv_endpoint,$csv_connection,$csv_group,$csv_roles,$csv_root_password"
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
        ansible_group="$csv_group"
        roles="$csv_roles"
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

if ! has_role "$roles" management && ! has_role "$roles" orchestration && [ -z "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
    print_error "Managed node $NODE_ALIAS requires --ansible-authorized-key-file"
    exit 1
fi

sanitized_nodes="$(mktemp)"
trap 'rm -f "$sanitized_nodes"' EXIT
{
    echo "$EXPECTED_CSV_HEADER"
    tail -n +2 "$NODES_FILE" | while IFS=, read -r csv_alias csv_endpoint csv_connection csv_group csv_roles _csv_root_password extra || [ -n "${csv_alias:-}" ]; do
        csv_alias="${csv_alias//$'\r'/}"
        csv_endpoint="${csv_endpoint//$'\r'/}"
        csv_connection="${csv_connection//$'\r'/}"
        csv_group="${csv_group//$'\r'/}"
        csv_roles="${csv_roles//$'\r'/}"
        if [ -n "$csv_alias" ]; then
            printf '%s,%s,%s,%s,%s,\n' "$csv_alias" "$csv_endpoint" "$csv_connection" "$csv_group" "$csv_roles"
        fi
    done
} > "$sanitized_nodes"

remote="root@$endpoint"
ssh_base=(sshpass -p "$root_password" ssh -o StrictHostKeyChecking=accept-new "$remote")
scp_base=(sshpass -p "$root_password" scp -o StrictHostKeyChecking=accept-new)

print_header "Bootstrap $NODE_ALIAS from Unix runner"
"${scp_base[@]}" "$SETUP_SCRIPT" "$remote:/tmp/setup_vps.sh"
"${scp_base[@]}" "$sanitized_nodes" "$remote:/tmp/nodes.csv"
if [ -n "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
    "${scp_base[@]}" "$ANSIBLE_AUTHORIZED_KEY_FILE" "$remote:/tmp/ansible_control.managed_nodes.pub"
fi

if [ -n "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
    "${ssh_base[@]}" "ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --alias '$NODE_ALIAS'"
else
    "${ssh_base[@]}" "bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --alias '$NODE_ALIAS'"
fi

"${ssh_base[@]}" "rm -f /tmp/setup_vps.sh /tmp/nodes.csv /tmp/ansible_control.managed_nodes.pub"
print_success "Bootstrap completed for $NODE_ALIAS"
