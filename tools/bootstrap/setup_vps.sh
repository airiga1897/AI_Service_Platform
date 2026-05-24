#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
EXPECTED_CSV_HEADER="current_alias,endpoint,connection,root_password"
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
  sudo bash tools/bootstrap/setup_vps.sh --nodes-file /tmp/nodes.csv --state-file /tmp/state.csv --alias vps3
  sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash tools/bootstrap/setup_vps.sh --nodes-file /tmp/nodes.csv --state-file /tmp/state.csv --alias vps2

Fallback target mode:
  sudo bash tools/bootstrap/setup_vps.sh vps3-management
  sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash tools/bootstrap/setup_vps.sh vps2-preprod
  sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash tools/bootstrap/setup_vps.sh vps1-prod

Environment overrides:
  DEPLOY_USER=depuser
  ADMIN_USER=useradmin
  ANSIBLE_USER=ansible
  ANSIBLE_AUTHORIZED_KEY='ssh-ed25519 ... ansible-control@vps3-management'
  ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub
  FORCE_REGENERATE_KEYS=0
  SSH_PORT=22

Supported targets:
  vps3-management       First node to bootstrap. Ansible control/management node.
  vps2-preprod          Managed preprod / hot-standby / backup node.
  vps1-prod             Managed production node.
  ai-retail-dev-preprod Temporary alias for GitHub Actions deploy access to VPS2.

CSV columns:
  current_alias,endpoint,connection,root_password

State CSV columns:
  kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
USAGE
}

NODES_FILE=""
STATE_FILE=""
NODE_ALIAS=""
TARGET=""

split_aliases_has() {
    local aliases="$1"
    local wanted="$2"
    case "+$aliases+" in
        *"+$wanted+"*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_behavior_from_state() {
    [ -n "$STATE_FILE" ] || {
        print_error "--state-file is required with --nodes-file/--alias. nodes.csv is only an address book."
        exit 1
    }
    [ -f "$STATE_FILE" ] || {
        print_error "state file not found: $STATE_FILE"
        exit 1
    }

    local first_state_line
    first_state_line="$(head -n 1 "$STATE_FILE" | tr -d '\r')"
    [ "$first_state_line" = "$EXPECTED_STATE_CSV_HEADER" ] || {
        print_error "state.csv header must be exactly:"
        echo "$EXPECTED_STATE_CSV_HEADER"
        exit 1
    }

    local line_number=0
    local mentioned="false"
    local kind name ansible_group active_aliases candidate_aliases old_aliases state extra
    while IFS=, read -r kind name ansible_group active_aliases candidate_aliases old_aliases state extra || [ -n "${kind:-}" ]; do
        line_number=$((line_number + 1))
        kind="${kind//$'\r'/}"
        name="${name//$'\r'/}"
        active_aliases="${active_aliases//$'\r'/}"
        candidate_aliases="${candidate_aliases//$'\r'/}"
        old_aliases="${old_aliases//$'\r'/}"
        state="${state//$'\r'/}"
        extra="${extra//$'\r'/}"
        [ "$line_number" -eq 1 ] && continue
        [ -z "$kind" ] && continue
        [ -z "$extra" ] || {
            print_error "state.csv line $line_number has too many columns"
            exit 1
        }
        if split_aliases_has "$active_aliases" "$NODE_ALIAS" || split_aliases_has "$candidate_aliases" "$NODE_ALIAS" || split_aliases_has "$old_aliases" "$NODE_ALIAS"; then
            mentioned="true"
        fi
        if { [ "$kind" = "platform_role" ] || [ "$kind" = "role" ]; } && [ "$name" = "orchestration" ] && [ "$state" = "present" ] && split_aliases_has "$active_aliases" "$NODE_ALIAS"; then
            NODE_ROLE="management"
            DEPLOY_DIR="/opt/ai-service-platform"
            RUNTIME_ENV_FILE=""
            GITHUB_ENVIRONMENT="$NODE_ALIAS"
            TARGET="$NODE_ALIAS"
            return
        fi
    done < "$STATE_FILE"

    if [ "$mentioned" = "true" ]; then
        NODE_ROLE="managed"
        DEPLOY_DIR="/opt/stacks"
        RUNTIME_ENV_FILE=""
        GITHUB_ENVIRONMENT="$NODE_ALIAS"
        TARGET="$NODE_ALIAS"
        return
    fi

    print_error "Alias $NODE_ALIAS is not referenced by state.csv. Add it to platform_role/service active/candidate/old aliases before bootstrap."
    exit 1
}

resolve_target_from_nodes_file() {
    if [ ! -f "$NODES_FILE" ]; then
        print_error "nodes file not found: $NODES_FILE"
        exit 1
    fi

    local line_number=0
    local header_seen="false"
    local current_alias endpoint connection root_password extra

    while IFS=, read -r current_alias endpoint connection root_password extra || [ -n "${current_alias:-}" ]; do
        line_number=$((line_number + 1))
        current_alias="${current_alias//$'\r'/}"
        endpoint="${endpoint//$'\r'/}"
        connection="${connection//$'\r'/}"
        root_password="${root_password//$'\r'/}"
        extra="${extra//$'\r'/}"

        if [ "$line_number" -eq 1 ]; then
            local header
            header="$current_alias,$endpoint,$connection,$root_password"
            if [ "$header" != "$EXPECTED_CSV_HEADER" ] || [ -n "$extra" ]; then
                print_error "nodes.csv header must be exactly:"
                echo "$EXPECTED_CSV_HEADER"
                exit 1
            fi
            header_seen="true"
            continue
        fi

        if [ "$current_alias" = "$NODE_ALIAS" ]; then
            resolve_behavior_from_state
            return
        fi
    done < "$NODES_FILE"

    if [ "$header_seen" != "true" ]; then
        print_error "nodes.csv is empty: $NODES_FILE"
        exit 1
    fi

    print_error "Alias not found in nodes file: $NODE_ALIAS"
    exit 1
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
        --alias)
            NODE_ALIAS="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [ -n "$TARGET" ]; then
                print_error "Only one fallback target can be provided."
                usage
                exit 1
            fi
            TARGET="$1"
            shift
            ;;
    esac
done

CSV_MODE="false"
if [ -n "$NODES_FILE" ] || [ -n "$NODE_ALIAS" ]; then
    if [ -z "$NODES_FILE" ] || [ -z "$NODE_ALIAS" ]; then
        print_error "--nodes-file and --alias must be used together."
        usage
        exit 1
    fi
    if [ -n "$TARGET" ]; then
        print_error "Use either --nodes-file/--alias or fallback target mode, not both."
        usage
        exit 1
    fi
    CSV_MODE="true"
    resolve_target_from_nodes_file
fi

if [ -z "$TARGET" ]; then
    usage
    exit 1
fi

if [ "$CSV_MODE" != "true" ]; then
    case "$TARGET" in
        vps3-management)
            NODE_ROLE="management"
            DEPLOY_DIR="/opt/ai-service-platform"
            RUNTIME_ENV_FILE=""
            GITHUB_ENVIRONMENT="vps3-management"
            ;;
        vps2-preprod)
            NODE_ROLE="managed"
            DEPLOY_DIR="/opt/stacks"
            RUNTIME_ENV_FILE=""
            GITHUB_ENVIRONMENT="vps2-preprod"
            ;;
        vps1-prod)
            NODE_ROLE="managed"
            DEPLOY_DIR="/opt/stacks"
            RUNTIME_ENV_FILE=""
            GITHUB_ENVIRONMENT="vps1-prod"
            ;;
        ai-retail-dev-preprod)
            NODE_ROLE="deploy-access"
            DEPLOY_DIR="/opt/stacks/ai-retail-dev-preprod"
            RUNTIME_ENV_FILE="${DEPLOY_DIR}/.env.ai-retail.dev"
            GITHUB_ENVIRONMENT="ai-retail-dev-preprod"
            ;;
        *)
            print_error "Unsupported bootstrap target: $TARGET"
            usage
            exit 1
            ;;
    esac
fi

DEPLOY_USER="${DEPLOY_USER:-depuser}"
ADMIN_USER="${ADMIN_USER:-useradmin}"
ANSIBLE_USER="${ANSIBLE_USER:-ansible}"
ANSIBLE_AUTHORIZED_KEY="${ANSIBLE_AUTHORIZED_KEY:-}"
ANSIBLE_AUTHORIZED_KEY_FILE="${ANSIBLE_AUTHORIZED_KEY_FILE:-}"
SSH_PORT="${SSH_PORT:-22}"
FORCE_REGENERATE_KEYS="${FORCE_REGENERATE_KEYS:-0}"
DEPLOY_KEY_NAME="github_deploy"
ADMIN_KEY_NAME="admin_key"
ANSIBLE_KEY_NAME="ansible_control"

if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root. Use sudo."
    exit 1
fi

print_header "AI Service Platform VPS bootstrap: $TARGET"

echo "Parameters:"
echo "  GitHub Environment: $GITHUB_ENVIRONMENT"
echo "  Node role:          $NODE_ROLE"
echo "  Deploy directory:   $DEPLOY_DIR"
echo "  Runtime env file:   ${RUNTIME_ENV_FILE:-not applicable}"
echo "  Deploy user:        $DEPLOY_USER"
echo "  Admin user:         $ADMIN_USER"
echo "  Ansible user:       $ANSIBLE_USER"
echo "  SSH port:           $SSH_PORT"
echo "  Regenerate keys:    $FORCE_REGENERATE_KEYS"
echo ""

ensure_command() {
    local command_name="$1"
    local package_name="$2"
    if command -v "$command_name" >/dev/null 2>&1; then
        return
    fi
    print_warning "$command_name not found; installing package $package_name"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "$package_name"
}

create_user() {
    local user_name="$1"
    if getent passwd "$user_name" >/dev/null 2>&1; then
        print_success "User $user_name already exists"
    else
        adduser --disabled-password --gecos "" "$user_name"
        print_success "User $user_name created"
    fi
}

setup_ssh_key() {
    local user_name="$1"
    local key_name="$2"
    local key_comment="$3"
    local home_dir
    local ssh_dir
    local key_path
    local authorized_keys

    home_dir="$(getent passwd "$user_name" | cut -d: -f6)"
    if [ -z "$home_dir" ]; then
        print_error "Cannot resolve home directory for $user_name"
        exit 1
    fi

    ssh_dir="$home_dir/.ssh"
    key_path="$ssh_dir/$key_name"
    authorized_keys="$ssh_dir/authorized_keys"

    mkdir -p "$ssh_dir"
    touch "$authorized_keys"

    if [ "$FORCE_REGENERATE_KEYS" = "1" ]; then
        print_warning "FORCE_REGENERATE_KEYS=1; regenerating key for $user_name: $key_path"
        rm -f "$key_path" "$key_path.pub"
    fi

    if [ -f "$key_path" ] && [ ! -f "$key_path.pub" ]; then
        print_warning "Public key is missing for $user_name; deriving it from existing private key"
        ssh-keygen -y -f "$key_path" > "$key_path.pub"
    fi

    if [ ! -f "$key_path" ]; then
        ssh-keygen -t ed25519 -C "$key_comment" -f "$key_path" -N ""
        print_success "SSH key generated for $user_name"
    else
        print_success "SSH key already exists for $user_name; keeping it unchanged"
    fi

    if ! grep -Fxq "$(cat "$key_path.pub")" "$authorized_keys"; then
        cat "$key_path.pub" >> "$authorized_keys"
        print_success "Public key added to authorized_keys for $user_name"
    else
        print_success "Public key already present in authorized_keys for $user_name"
    fi

    chown -R "$user_name:$user_name" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$authorized_keys" "$key_path"
    chmod 644 "$key_path.pub"
}

lock_user_password() {
    local user_name="$1"
    passwd -l "$user_name" >/dev/null 2>&1 || true
    print_success "Password login locked for $user_name"
}

install_authorized_key() {
    local user_name="$1"
    local public_key="$2"
    local home_dir
    local ssh_dir
    local authorized_keys

    home_dir="$(getent passwd "$user_name" | cut -d: -f6)"
    ssh_dir="$home_dir/.ssh"
    authorized_keys="$ssh_dir/authorized_keys"

    mkdir -p "$ssh_dir"
    touch "$authorized_keys"
    if ! grep -Fxq "$public_key" "$authorized_keys"; then
        printf '%s\n' "$public_key" >> "$authorized_keys"
    fi
    chown -R "$user_name:$user_name" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$authorized_keys"
}

apply_ssh_hardening() {
    local sshd_config="/etc/ssh/sshd_config"
    local dropin_dir="/etc/ssh/sshd_config.d"
    local dropin_file="$dropin_dir/00-ai-service-platform-hardening.conf"
    local old_dropin_file="$dropin_dir/99-ai-service-platform-hardening.conf"
    local managed_begin="# BEGIN AI Service Platform SSH hardening"
    local managed_end="# END AI Service Platform SSH hardening"
    local hardening_directives
    local effective_config
    local permit_root
    local password_auth

    if ! command -v sshd >/dev/null 2>&1; then
        print_warning "sshd command not found. Configure SSH hardening manually."
        return
    fi

    hardening_directives="$(cat <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
EOF
)"

    normalize_ssh_hardening_file() {
        local config_file="$1"
        if [ ! -f "$config_file" ]; then
            return
        fi
        while IFS= read -r directive; do
            local key
            key="${directive%% *}"
            if grep -Eiq "^[[:space:]]*${key}[[:space:]]+" "$config_file"; then
                sed -i -E "s|^[[:space:]]*${key}[[:space:]].*|${directive}|I" "$config_file"
            else
                printf '%s\n' "$directive" >> "$config_file"
            fi
        done <<EOF
$hardening_directives
EOF
    }

    if [ -f "$sshd_config" ]; then
        if grep -qF "$managed_begin" "$sshd_config"; then
            sed -i "/$managed_begin/,/$managed_end/d" "$sshd_config"
        fi
        normalize_ssh_hardening_file "$sshd_config"
        print_success "SSH hardening normalized in $sshd_config"
    fi

    if [ -d "$dropin_dir" ] || mkdir -p "$dropin_dir" 2>/dev/null; then
        local existing_dropin
        for existing_dropin in "$dropin_dir"/*.conf; do
            [ -e "$existing_dropin" ] || continue
            normalize_ssh_hardening_file "$existing_dropin"
        done
        rm -f "$old_dropin_file"
        printf '%s\n' "$hardening_directives" > "$dropin_file"
        chmod 644 "$dropin_file"
        print_success "SSH hardening drop-in written: $dropin_file"
    elif [ -f "$sshd_config" ]; then
        if grep -qF "$managed_begin" "$sshd_config"; then
            sed -i "/$managed_begin/,/$managed_end/d" "$sshd_config"
        fi
        cat >> "$sshd_config" <<EOF

$managed_begin
$hardening_directives
$managed_end
EOF
        print_success "SSH hardening managed block written to $sshd_config"
    else
        print_warning "$sshd_config not found. Configure SSH hardening manually."
        return
    fi

    if ! sshd -t; then
        print_error "sshd config validation failed after hardening changes."
        exit 1
    fi

    if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
        print_success "SSH service restarted"
    else
        print_error "Could not restart SSH automatically. Run: systemctl restart ssh || systemctl restart sshd"
        exit 1
    fi

    effective_config="$(sshd -T 2>/dev/null || true)"
    permit_root="$(printf '%s\n' "$effective_config" | awk '$1 == "permitrootlogin" {print $2; exit}')"
    password_auth="$(printf '%s\n' "$effective_config" | awk '$1 == "passwordauthentication" {print $2; exit}')"

    echo "Effective SSH hardening:"
    echo "  permitrootlogin ${permit_root:-unknown}"
    echo "  passwordauthentication ${password_auth:-unknown}"

    if [ "$permit_root" != "no" ] || [ "$password_auth" != "no" ]; then
        echo ""
        echo "Active SSH directives found in config files:"
        grep -RniE '^[[:space:]]*(Include|PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication)[[:space:]]+' \
            "$sshd_config" "$dropin_dir"/*.conf 2>/dev/null || true
        echo ""
        print_error "SSH hardening did not take effect. Expected: permitrootlogin no, passwordauthentication no."
        exit 1
    fi

    print_success "Root SSH login and password authentication are disabled"
}

resolve_ansible_authorized_key() {
    if [ -n "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
        if [ ! -f "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
            print_error "ANSIBLE_AUTHORIZED_KEY_FILE not found: $ANSIBLE_AUTHORIZED_KEY_FILE"
            exit 1
        fi
        ANSIBLE_AUTHORIZED_KEY="$(tr -d '\r\n' < "$ANSIBLE_AUTHORIZED_KEY_FILE")"
    fi

    if [ -n "$ANSIBLE_AUTHORIZED_KEY" ] &&
        ! printf '%s\n' "$ANSIBLE_AUTHORIZED_KEY" | grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) '; then
        print_error "ANSIBLE_AUTHORIZED_KEY does not look like an SSH public key."
        exit 1
    fi
}

resolve_ansible_authorized_key

if [ "$NODE_ROLE" = "managed" ] && [ -z "$ANSIBLE_AUTHORIZED_KEY" ]; then
    print_error "Managed target $TARGET requires the VPS3 Ansible control public key."
    echo ""
    echo "Copy this public key file from VPS3 to the managed VPS:"
    echo "  /home/ansible/.ssh/ansible_control.managed_nodes.pub -> /tmp/ansible_control.managed_nodes.pub"
    echo ""
    echo "Then run:"
    if [ "$CSV_MODE" = "true" ]; then
        echo "  sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash setup_vps.sh --nodes-file $NODES_FILE --state-file $STATE_FILE --alias $NODE_ALIAS"
    else
        echo "  sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash setup_vps.sh $TARGET"
    fi
    echo ""
    echo "String fallback:"
    if [ "$CSV_MODE" = "true" ]; then
        echo "  sudo ANSIBLE_AUTHORIZED_KEY='ssh-ed25519 ... ansible-control@orchestration' bash setup_vps.sh --nodes-file $NODES_FILE --state-file $STATE_FILE --alias $NODE_ALIAS"
    else
        echo "  sudo ANSIBLE_AUTHORIZED_KEY='ssh-ed25519 ... ansible-control@vps3-management' bash setup_vps.sh $TARGET"
    fi
    exit 1
fi

print_header "1/7 - Base packages"
ensure_command sudo sudo
ensure_command ssh-keygen openssh-client
ensure_command curl curl
if [ "$NODE_ROLE" = "management" ]; then
    ensure_command git git
    ensure_command ansible ansible
fi
print_success "Required base commands are available"

print_header "2/7 - Admin user"
create_user "$ADMIN_USER"
usermod -aG sudo "$ADMIN_USER"
ADMIN_SUDOERS_FILE="/etc/sudoers.d/$ADMIN_USER"
echo "$ADMIN_USER ALL=(ALL) NOPASSWD: ALL" > "$ADMIN_SUDOERS_FILE"
chmod 440 "$ADMIN_SUDOERS_FILE"
visudo -cf "$ADMIN_SUDOERS_FILE" >/dev/null
setup_ssh_key "$ADMIN_USER" "$ADMIN_KEY_NAME" "$ADMIN_USER@$(hostname)"
lock_user_password "$ADMIN_USER"
print_success "Admin user is ready"

print_header "3/7 - Deploy user"
create_user "$DEPLOY_USER"
if ! getent group docker >/dev/null 2>&1; then
    groupadd --system docker
fi
usermod -aG docker "$DEPLOY_USER"

DEPLOY_SUDOERS_FILE="/etc/sudoers.d/$DEPLOY_USER"
cat > "$DEPLOY_SUDOERS_FILE" <<'SUDOERS'
Cmnd_Alias PLATFORM_DIRS = /bin/mkdir -p *, /usr/bin/mkdir -p *, /bin/chown -R *, /usr/bin/chown -R *
Cmnd_Alias PLATFORM_DOCKER = /usr/bin/docker *, /usr/local/bin/docker *
Cmnd_Alias PLATFORM_SYSTEMCTL = /usr/bin/systemctl start docker, /usr/bin/systemctl enable docker, /usr/bin/systemctl restart docker
SUDOERS
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD: PLATFORM_DIRS, PLATFORM_DOCKER, PLATFORM_SYSTEMCTL" >> "$DEPLOY_SUDOERS_FILE"
chmod 440 "$DEPLOY_SUDOERS_FILE"
visudo -cf "$DEPLOY_SUDOERS_FILE" >/dev/null
setup_ssh_key "$DEPLOY_USER" "$DEPLOY_KEY_NAME" "github-actions-deploy@$TARGET"
lock_user_password "$DEPLOY_USER"
print_success "Deploy user is ready"

if [ "$NODE_ROLE" = "management" ]; then
    print_header "3b/7 - Ansible control user"
    create_user "$ANSIBLE_USER"
    usermod -aG sudo "$ANSIBLE_USER"
    ANSIBLE_SUDOERS_FILE="/etc/sudoers.d/$ANSIBLE_USER"
    echo "$ANSIBLE_USER ALL=(ALL) NOPASSWD: ALL" > "$ANSIBLE_SUDOERS_FILE"
    chmod 440 "$ANSIBLE_SUDOERS_FILE"
    visudo -cf "$ANSIBLE_SUDOERS_FILE" >/dev/null
    setup_ssh_key "$ANSIBLE_USER" "$ANSIBLE_KEY_NAME" "ansible-control@$TARGET"
    lock_user_password "$ANSIBLE_USER"
    print_success "Ansible control user is ready"
else
    print_header "3b/7 - Ansible managed user"
    create_user "$ANSIBLE_USER"
    usermod -aG sudo "$ANSIBLE_USER"
    ANSIBLE_SUDOERS_FILE="/etc/sudoers.d/$ANSIBLE_USER"
    echo "$ANSIBLE_USER ALL=(ALL) NOPASSWD: ALL" > "$ANSIBLE_SUDOERS_FILE"
    chmod 440 "$ANSIBLE_SUDOERS_FILE"
    visudo -cf "$ANSIBLE_SUDOERS_FILE" >/dev/null
    ANSIBLE_HOME="$(getent passwd "$ANSIBLE_USER" | cut -d: -f6)"
    if [ -n "$ANSIBLE_AUTHORIZED_KEY" ]; then
        install_authorized_key "$ANSIBLE_USER" "$ANSIBLE_AUTHORIZED_KEY"
        print_success "VPS3 Ansible control public key installed for $ANSIBLE_USER"
    else
        mkdir -p "$ANSIBLE_HOME/.ssh"
        touch "$ANSIBLE_HOME/.ssh/authorized_keys"
        chown -R "$ANSIBLE_USER:$ANSIBLE_USER" "$ANSIBLE_HOME/.ssh"
        chmod 700 "$ANSIBLE_HOME/.ssh"
        chmod 600 "$ANSIBLE_HOME/.ssh/authorized_keys"
        print_warning "Add the VPS3 Ansible control public key to this node after VPS3 bootstrap."
        print_warning "Or rerun bootstrap with ANSIBLE_AUTHORIZED_KEY='ssh-ed25519 ...'."
    fi
    lock_user_password "$ANSIBLE_USER"
    print_warning "Ansible provisioning should run from VPS3, not directly from GitHub Actions."
fi

print_header "4/7 - Deploy directory and runtime env placeholder"
mkdir -p "$DEPLOY_DIR"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_DIR"
chmod 750 "$DEPLOY_DIR"

if [ -n "$RUNTIME_ENV_FILE" ] && [ ! -f "$RUNTIME_ENV_FILE" ]; then
    cat > "$RUNTIME_ENV_FILE" <<'ENVEOF'
# AI Service Platform runtime env placeholder.
# Fill this file on the VPS. Do not commit real values to the repository.

# Required application secrets and settings go here.
# Example names only:
# DJANGO_SECRET_KEY=
# DATABASE_URL=
# REDIS_URL=
# ALLOWED_HOSTS=
ENVEOF
    chown "$DEPLOY_USER:$DEPLOY_USER" "$RUNTIME_ENV_FILE"
    chmod 640 "$RUNTIME_ENV_FILE"
    print_success "Runtime env placeholder created: $RUNTIME_ENV_FILE"
elif [ -n "$RUNTIME_ENV_FILE" ]; then
    print_warning "Runtime env file already exists; keeping it unchanged: $RUNTIME_ENV_FILE"
else
    print_success "No runtime env placeholder is required for target $TARGET"
fi

print_header "5/7 - SSH hardening"
apply_ssh_hardening

print_header "6/7 - Docker readiness note"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    print_success "Docker Compose plugin is available"
else
    print_warning "Docker Compose plugin is not available yet."
    print_warning "Install it with the Ansible docker role before running predeploy-check."
fi

print_header "7/7 - Values for GitHub Environment"
SERVER_IP="$(curl -fsS https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
DEPLOY_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
ANSIBLE_HOME="$(getent passwd "$ANSIBLE_USER" | cut -d: -f6 2>/dev/null || true)"
DEPLOY_KEY_PATH="$DEPLOY_HOME/.ssh/$DEPLOY_KEY_NAME"
ADMIN_KEY_PATH="$ADMIN_HOME/.ssh/$ADMIN_KEY_NAME"
ANSIBLE_KEY_PATH="${ANSIBLE_HOME:-}/.ssh/$ANSIBLE_KEY_NAME"

echo ""
echo -e "${YELLOW}IMPORTANT: private keys are printed for one-time copy only.${NC}"
echo -e "${YELLOW}Do not save them in repository files, docs, issues, or chat logs.${NC}"
echo ""

echo "GitHub Environment: $GITHUB_ENVIRONMENT"
echo "-------------------------------------"
echo "SSH_HOST=$SERVER_IP"
echo "SSH_USER=$DEPLOY_USER"
echo "SSH_PORT=$SSH_PORT"
echo "SSH_KEY=(copy private deploy key below)"
if [ "$NODE_ROLE" = "management" ]; then
    echo "ANSIBLE_CONTROL_HOST=$SERVER_IP"
    echo "ANSIBLE_CONTROL_USER=$ANSIBLE_USER"
    echo "ANSIBLE_CONTROL_KEY=(copy private Ansible control key below)"
fi
echo ""

echo -e "${BLUE}=== SSH_KEY for GitHub Environment ($DEPLOY_USER) ===${NC}"
echo -e "${GREEN}--- BEGIN SSH_KEY ---${NC}"
cat "$DEPLOY_KEY_PATH"
echo -e "${GREEN}--- END SSH_KEY ---${NC}"
echo ""

if [ "$NODE_ROLE" = "management" ]; then
    cp "$ANSIBLE_KEY_PATH.pub" "$ANSIBLE_HOME/.ssh/${ANSIBLE_KEY_NAME}.managed_nodes.pub"
    chown "$ANSIBLE_USER:$ANSIBLE_USER" "$ANSIBLE_HOME/.ssh/${ANSIBLE_KEY_NAME}.managed_nodes.pub"
    chmod 644 "$ANSIBLE_HOME/.ssh/${ANSIBLE_KEY_NAME}.managed_nodes.pub"
    echo -e "${BLUE}=== Ansible control key ($ANSIBLE_USER) ===${NC}"
    echo -e "${GREEN}--- BEGIN ANSIBLE CONTROL KEY ---${NC}"
    cat "$ANSIBLE_KEY_PATH"
    echo -e "${GREEN}--- END ANSIBLE CONTROL KEY ---${NC}"
    echo ""
    echo -e "${BLUE}=== Ansible control public key for VPS1/VPS2 authorized_keys ===${NC}"
    cat "$ANSIBLE_KEY_PATH.pub"
    echo ""
    echo "Saved public key file for managed nodes:"
    echo "$ANSIBLE_HOME/.ssh/${ANSIBLE_KEY_NAME}.managed_nodes.pub"
    echo ""
fi

echo -e "${BLUE}=== Admin SSH key ($ADMIN_USER) ===${NC}"
echo -e "${GREEN}--- BEGIN ADMIN KEY ---${NC}"
cat "$ADMIN_KEY_PATH"
echo -e "${GREEN}--- END ADMIN KEY ---${NC}"
echo ""

print_success "Bootstrap complete for $TARGET"
echo ""
echo "Next steps:"
if [ "$NODE_ROLE" = "management" ]; then
    echo "  1. Bootstrap VPS1/VPS2 as managed nodes."
    echo "  2. Add the Ansible control public key above to managed nodes."
    echo "  3. Prepare encrypted inventory/vault outside the repository."
    echo "  4. Run infra/ansible/site.yml from VPS3."
else
    echo "  1. Add the VPS3 Ansible control public key to this node."
    echo "  2. Run infra/ansible/site.yml from VPS3 to finish OS provisioning."
    echo "  3. For temporary GitHub deploy access, store SSH_HOST, SSH_USER, SSH_PORT, SSH_KEY in the relevant GitHub Environment."
    if [ -n "$RUNTIME_ENV_FILE" ]; then
        echo "  4. Fill runtime secrets in $RUNTIME_ENV_FILE on this VPS."
    fi
fi
