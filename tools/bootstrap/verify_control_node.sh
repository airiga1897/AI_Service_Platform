#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="/opt/ai-service-platform"
INVENTORY_PATH="/opt/ai-service-platform/inventory.ini"

usage() {
    cat <<'USAGE'
Usage:
  sudo bash tools/bootstrap/verify_control_node.sh

Options:
  --repo-dir PATH       Repo/control dir. Default: /opt/ai-service-platform
  --inventory PATH      Inventory path. Default: /opt/ai-service-platform/inventory.ini
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
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

[ -d "$REPO_DIR" ] || fail "repo dir not found: $REPO_DIR"
[ -f "$INVENTORY_PATH" ] || fail "inventory not found: $INVENTORY_PATH"
command -v ansible >/dev/null 2>&1 || fail "ansible command not found"

cd "$REPO_DIR"

print_header "Verify Ansible connectivity"
ansible all -i "$INVENTORY_PATH" -m ping
echo "[OK] Ansible connectivity verified"

print_header "Verify SSH hardening on all nodes"
ansible all -i "$INVENTORY_PATH" --become -m shell -a 'set -e; effective="$(sshd -T)"; printf "%s\n" "$effective" | awk "/^(permitrootlogin|passwordauthentication) / {print}"; printf "%s\n" "$effective" | grep -qx "permitrootlogin no"; printf "%s\n" "$effective" | grep -qx "passwordauthentication no"'
echo "[OK] SSH hardening verified on all nodes"

echo "[OK] Control node verification completed"
