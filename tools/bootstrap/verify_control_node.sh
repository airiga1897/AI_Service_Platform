#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="/opt/ai-service-platform"
INVENTORY_PATH="/opt/ai-service-platform/inventory.ini"
VERIFY_RETRIES=3
VERIFY_RETRY_DELAY=5
ANSIBLE_TIMEOUT=20

usage() {
    cat <<'USAGE'
Usage:
  sudo bash tools/bootstrap/verify_control_node.sh

Options:
  --repo-dir PATH       Repo/control dir. Default: /opt/ai-service-platform
  --inventory PATH      Inventory path. Default: /opt/ai-service-platform/inventory.ini
  --retries N           Attempts for each verification stage. Default: 3.
  --retry-delay SECONDS Delay between failed attempts. Default: 5.
  --ansible-timeout SECONDS
                        Ansible SSH/connect timeout. Default: 20.
  -h, --help            Show this help.
USAGE
}

fail() {
    echo "[ERROR] $1" >&2
    exit 1
}

print_header() {
    echo ""
    echo "========================================"
    echo "  $1"
    echo "========================================"
    echo ""
}

require_positive_int() {
    local value="$1"
    local label="$2"
    case "$value" in
        ''|*[!0-9]*) fail "$label must be a positive integer" ;;
        0) fail "$label must be greater than zero" ;;
    esac
}

run_with_retries() {
    local label="$1"
    shift
    local attempt
    local rc

    for attempt in $(seq 1 "$VERIFY_RETRIES"); do
        echo "Attempt $attempt/$VERIFY_RETRIES: $label"
        set +e
        "$@"
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then
            return 0
        fi
        if [ "$attempt" -lt "$VERIFY_RETRIES" ]; then
            echo "[WARN] $label failed on attempt $attempt/$VERIFY_RETRIES; retrying after short delay."
            sleep "$VERIFY_RETRY_DELAY"
        fi
    done

    fail "$label failed after $VERIFY_RETRIES attempts"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo-dir)
            REPO_DIR="${2:-}"
            shift 2
            ;;
        --inventory)
            INVENTORY_PATH="${2:-}"
            shift 2
            ;;
        --retries)
            VERIFY_RETRIES="${2:-}"
            shift 2
            ;;
        --retry-delay)
            VERIFY_RETRY_DELAY="${2:-}"
            shift 2
            ;;
        --ansible-timeout)
            ANSIBLE_TIMEOUT="${2:-}"
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

require_positive_int "$VERIFY_RETRIES" "--retries"
require_positive_int "$VERIFY_RETRY_DELAY" "--retry-delay"
require_positive_int "$ANSIBLE_TIMEOUT" "--ansible-timeout"

[ -d "$REPO_DIR" ] || fail "repo dir not found: $REPO_DIR"
[ -f "$INVENTORY_PATH" ] || fail "inventory not found: $INVENTORY_PATH"
command -v ansible >/dev/null 2>&1 || fail "ansible command not found"

if ! id ansible >/dev/null 2>&1; then
    fail "local ansible user not found"
fi

DEFAULT_ANSIBLE_SSH_COMMON_ARGS="-o BatchMode=yes -o KbdInteractiveAuthentication=no -o PasswordAuthentication=no -o PreferredAuthentications=publickey -o RequestTTY=no"
if [ -n "${ANSIBLE_SSH_COMMON_ARGS:-}" ]; then
    export ANSIBLE_SSH_COMMON_ARGS="$ANSIBLE_SSH_COMMON_ARGS $DEFAULT_ANSIBLE_SSH_COMMON_ARGS"
else
    export ANSIBLE_SSH_COMMON_ARGS="$DEFAULT_ANSIBLE_SSH_COMMON_ARGS"
fi

run_ansible() {
    if [ "$(id -u)" -eq 0 ]; then
        sudo -u ansible env ANSIBLE_TIMEOUT="$ANSIBLE_TIMEOUT" ANSIBLE_SSH_COMMON_ARGS="$ANSIBLE_SSH_COMMON_ARGS" ansible "$@"
    else
        ansible "$@"
    fi
}

cd "$REPO_DIR"
export ANSIBLE_TIMEOUT

print_header "Verify Ansible connectivity"
run_with_retries "Verify Ansible connectivity" run_ansible all -i "$INVENTORY_PATH" -T "$ANSIBLE_TIMEOUT" -m ping
echo "[OK] Ansible connectivity verified"

print_header "Verify SSH hardening on all nodes"
run_with_retries "Verify SSH hardening on all nodes" run_ansible all -i "$INVENTORY_PATH" -T "$ANSIBLE_TIMEOUT" --become -m shell -a 'set -e; effective="$(sshd -T)"; printf "%s\n" "$effective" | awk "/^(permitrootlogin|passwordauthentication) / {print}"; printf "%s\n" "$effective" | grep -qx "permitrootlogin no"; printf "%s\n" "$effective" | grep -qx "passwordauthentication no"'
echo "[OK] SSH hardening verified on all nodes"

echo "[OK] Control node verification completed"
