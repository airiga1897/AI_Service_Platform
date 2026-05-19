#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
EXPECTED_CSV_HEADER="current_alias,endpoint,connection,ansible_group,roles,root_password"
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
    --alias vps2 \
    --ansible-authorized-key-file ./operator/ansible_control.managed_nodes.pub

Options:
  --nodes-file PATH                  Real operator CSV with root_password.
  --alias VALUE                      current_alias to bootstrap.
  --setup-script PATH                setup_vps.sh path. Default: tools/bootstrap/setup_vps.sh
  --ansible-authorized-key-file PATH VPS3 public key for managed nodes.
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
NODE_ALIAS=""
SETUP_SCRIPT="tools/bootstrap/setup_vps.sh"
ANSIBLE_AUTHORIZED_KEY_FILE=""
OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE="./operator/ansible_control.managed_nodes.pub"
FORCE_OVERWRITE="false"
REGENERATE_REMOTE_KEYS="false"

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

if ! has_role "$roles" management && ! has_role "$roles" orchestration && [ -z "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
    print_error "Managed node $NODE_ALIAS requires --ansible-authorized-key-file"
    exit 1
fi

is_management_node="false"
if has_role "$roles" management || has_role "$roles" orchestration; then
    is_management_node="true"
fi
if [ "$REGENERATE_REMOTE_KEYS" = "true" ] &&
    [ "$is_management_node" = "true" ] &&
    [ "$FORCE_OVERWRITE" != "true" ]; then
    print_error "--regenerate-remote-keys for a management node requires --force so the local Ansible public key file is refreshed explicitly."
    exit 1
fi
if [ "$is_management_node" = "true" ] &&
    [ -f "$OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE" ] &&
    [ "$FORCE_OVERWRITE" != "true" ]; then
    print_error "Output Ansible public key file already exists: $OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE"
    print_error "Use --force to overwrite it."
    exit 1
fi

sanitized_nodes="$(mktemp)"
remote_log="$(mktemp)"
trap 'rm -f "$sanitized_nodes" "$remote_log"' EXIT
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
echo "Step 1/4: copy setup_vps.sh"
"${scp_base[@]}" "$SETUP_SCRIPT" "$remote:/tmp/setup_vps.sh"
echo "Step 2/4: copy sanitized nodes.csv"
"${scp_base[@]}" "$sanitized_nodes" "$remote:/tmp/nodes.csv"
if [ -n "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
    echo "Step 2b/4: copy Ansible control public key"
    "${scp_base[@]}" "$ANSIBLE_AUTHORIZED_KEY_FILE" "$remote:/tmp/ansible_control.managed_nodes.pub"
fi

if [ -n "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
    setup_command="ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --alias '$NODE_ALIAS'"
else
    setup_command="bash /tmp/setup_vps.sh --nodes-file /tmp/nodes.csv --alias '$NODE_ALIAS'"
fi
if [ "$REGENERATE_REMOTE_KEYS" = "true" ]; then
    setup_command="FORCE_REGENERATE_KEYS=1 $setup_command"
fi

if [ "$is_management_node" = "true" ]; then
    emit_key_command="if [ \$rc -eq 0 ]; then echo $PUBLIC_KEY_BEGIN_MARKER; cat /home/ansible/.ssh/ansible_control.managed_nodes.pub; echo $PUBLIC_KEY_END_MARKER; fi"
else
    emit_key_command=":"
fi
remote_command="set +e; $setup_command; rc=\$?; $emit_key_command; rm -f /tmp/setup_vps.sh /tmp/nodes.csv /tmp/ansible_control.managed_nodes.pub; exit \$rc"

echo "Step 3/4: run remote bootstrap"
echo "Expected next output: AI Service Platform VPS bootstrap"
echo "If this step stays silent for a long time, check SSH host key prompts, SSH banner prompts, and root password auth."
"${ssh_base[@]}" "$remote_command" 2>&1 | tee "$remote_log"

if [ "$is_management_node" = "true" ]; then
    echo "Step 4/4: save Ansible control public key"
    output_dir="$(dirname "$OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE")"
    mkdir -p "$output_dir"
    if [ -f "$OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE" ] && [ "$FORCE_OVERWRITE" = "true" ]; then
        rm -f "$OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE"
    fi

    public_key="$(
        awk -v begin="$PUBLIC_KEY_BEGIN_MARKER" -v end="$PUBLIC_KEY_END_MARKER" '
            $0 == begin { capture=1; next }
            $0 == end { capture=0; next }
            capture { print }
        ' "$remote_log"
    )"
    if [ "$(printf '%s\n' "$public_key" | sed '/^$/d' | wc -l | tr -d ' ')" -ne 1 ]; then
        print_error "Could not capture exactly one Ansible control public key from remote bootstrap output."
        exit 1
    fi
    printf '%s\n' "$public_key" > "$OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE"
    print_success "Saved Ansible control public key: $OUTPUT_ANSIBLE_AUTHORIZED_KEY_FILE"
else
    echo "Step 4/4: no Ansible public key download needed for managed node"
fi
print_success "Bootstrap completed for $NODE_ALIAS"
