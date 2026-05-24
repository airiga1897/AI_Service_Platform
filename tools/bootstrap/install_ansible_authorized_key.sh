#!/usr/bin/env bash

set -euo pipefail

ANSIBLE_USER="${ANSIBLE_USER:-ansible}"
PUBLIC_KEY="${ANSIBLE_AUTHORIZED_KEY:-}"
PUBLIC_KEY_FILE="${ANSIBLE_AUTHORIZED_KEY_FILE:-}"

usage() {
    cat <<'USAGE'
Usage:
  sudo ANSIBLE_AUTHORIZED_KEY='ssh-ed25519 ...' bash tools/bootstrap/install_ansible_authorized_key.sh
  sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash tools/bootstrap/install_ansible_authorized_key.sh

Environment overrides:
  ANSIBLE_USER=ansible
  ANSIBLE_AUTHORIZED_KEY='ssh-ed25519 ... ansible-control@orchestration'
  ANSIBLE_AUTHORIZED_KEY_FILE=/path/to/public/key.pub
USAGE
}

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root. Use sudo." >&2
    exit 1
fi

if [ -n "$PUBLIC_KEY_FILE" ]; then
    if [ ! -f "$PUBLIC_KEY_FILE" ]; then
        echo "[ERROR] Public key file not found: $PUBLIC_KEY_FILE" >&2
        exit 1
    fi
    PUBLIC_KEY="$(tr -d '\r\n' < "$PUBLIC_KEY_FILE")"
fi

if [ -z "$PUBLIC_KEY" ]; then
    usage
    exit 1
fi

if ! printf '%s\n' "$PUBLIC_KEY" | grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) '; then
    echo "[ERROR] ANSIBLE_AUTHORIZED_KEY does not look like an SSH public key." >&2
    exit 1
fi

if ! getent passwd "$ANSIBLE_USER" >/dev/null 2>&1; then
    echo "[ERROR] User $ANSIBLE_USER does not exist. Run setup_vps.sh first." >&2
    exit 1
fi

ANSIBLE_HOME="$(getent passwd "$ANSIBLE_USER" | cut -d: -f6)"
SSH_DIR="$ANSIBLE_HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

install -d -m 700 -o "$ANSIBLE_USER" -g "$ANSIBLE_USER" "$SSH_DIR"
touch "$AUTHORIZED_KEYS"

if ! grep -Fxq "$PUBLIC_KEY" "$AUTHORIZED_KEYS"; then
    printf '%s\n' "$PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
fi

chown "$ANSIBLE_USER:$ANSIBLE_USER" "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
passwd -l "$ANSIBLE_USER" >/dev/null 2>&1 || true

echo "[OK] Installed orchestration Ansible control public key for $ANSIBLE_USER"
echo "[OK] Password login locked for $ANSIBLE_USER"
