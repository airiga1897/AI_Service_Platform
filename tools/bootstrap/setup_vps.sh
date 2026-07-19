#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
EXPECTED_CSV_HEADER="current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
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
  sudo bash tools/bootstrap/setup_vps.sh --nodes-file /tmp/nodes.csv --state-file /tmp/state.csv --alias <orchestration-alias>
  sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash tools/bootstrap/setup_vps.sh --nodes-file /tmp/nodes.csv --state-file /tmp/state.csv --alias vps2
  sudo bash tools/bootstrap/setup_vps.sh --ssh-hardening-only

Fallback target mode:
  sudo bash tools/bootstrap/setup_vps.sh orchestration-management
  sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash tools/bootstrap/setup_vps.sh vps2-preprod
  sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash tools/bootstrap/setup_vps.sh vps1-prod

Environment overrides:
  DEPLOY_USER=depuser
  ADMIN_USER=useradmin
  ANSIBLE_USER=ansible
  ANSIBLE_AUTHORIZED_KEY='ssh-ed25519 ... ansible-control@orchestration'
  ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub
  APPLY_SSH_HARDENING=1
  FORCE_REGENERATE_KEYS=0
  SSH_PORT=22

Supported targets:
  orchestration-management First node to bootstrap. Ansible control/orchestration node.
  vps2-preprod          Managed preprod / hot-standby / backup node.
  vps1-prod             Managed production node.
  ai-retail-dev-preprod Temporary alias for GitHub Actions deploy access to VPS2.

CSV columns:
  current_alias,endpoint,expected_ip,connection,ssh_port,root_password

State CSV columns:
  kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
USAGE
}

NODES_FILE=""
STATE_FILE=""
NODE_ALIAS=""
TARGET=""
SSH_HARDENING_ONLY="false"

split_aliases_has() {
    local aliases="$1"
    local wanted="$2"
    case "+$aliases+" in
        *"+$wanted+"*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_expected_ip() {
    local alias="$1"
    local endpoint="$2"
    local expected_ip="$3"
    local line_number="$4"
    local resolved_ip

    [ -n "$expected_ip" ] || return 0
    [ "$endpoint" != "local" ] || return 0
    if command -v getent >/dev/null 2>&1; then
        resolved_ip="$(getent ahostsv4 "$endpoint" | awk '{print $1; exit}')"
    elif command -v python >/dev/null 2>&1; then
        resolved_ip="$(python -c 'import socket,sys; print(socket.gethostbyname(sys.argv[1]))' "$endpoint" 2>/dev/null || true)"
    elif command -v python3 >/dev/null 2>&1; then
        resolved_ip="$(python3 -c 'import socket,sys; print(socket.gethostbyname(sys.argv[1]))' "$endpoint" 2>/dev/null || true)"
    else
        print_warning "getent/python not found; skipping expected_ip check for $alias"
        return 0
    fi
    if [ -z "$resolved_ip" ]; then
        print_error "nodes.csv line $line_number could not resolve endpoint for expected_ip check: $endpoint"
        exit 1
    fi
    if [ "$resolved_ip" != "$expected_ip" ]; then
        print_error "nodes.csv line $line_number expected_ip mismatch for $alias: endpoint $endpoint resolved to $resolved_ip, expected $expected_ip"
        exit 1
    fi
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
        if { [ "$kind" = "platform_role" ] || [ "$kind" = "role" ]; } &&
            [ "$name" = "orchestration" ] &&
            [ "$state" = "present" ] &&
            { split_aliases_has "$active_aliases" "$NODE_ALIAS" || split_aliases_has "$candidate_aliases" "$NODE_ALIAS"; }; then
            NODE_ROLE="management"
            DEPLOY_DIR="/opt/ai-service-platform"
            RUNTIME_ENV_FILE=""
            GITHUB_ENVIRONMENT="$NODE_ALIAS"
            TARGET="$NODE_ALIAS"
            return
        fi
    done < "$STATE_FILE"

    NODE_ROLE="managed"
    DEPLOY_DIR="/opt/stacks"
    RUNTIME_ENV_FILE=""
    GITHUB_ENVIRONMENT="$NODE_ALIAS"
    TARGET="$NODE_ALIAS"
    if [ "$mentioned" != "true" ]; then
        print_warning "Alias $NODE_ALIAS is not referenced by state.csv; bootstrapping it as a managed platform node from nodes.csv."
    fi
    return
}

resolve_target_from_nodes_file() {
    if [ ! -f "$NODES_FILE" ]; then
        print_error "nodes file not found: $NODES_FILE"
        exit 1
    fi

    local line_number=0
    local header_seen="false"
    local current_alias endpoint expected_ip connection ssh_port root_password extra

    while IFS=, read -r current_alias endpoint expected_ip connection ssh_port root_password extra || [ -n "${current_alias:-}" ]; do
        line_number=$((line_number + 1))
        current_alias="${current_alias//$'\r'/}"
        endpoint="${endpoint//$'\r'/}"
        expected_ip="${expected_ip//$'\r'/}"
        connection="${connection//$'\r'/}"
        ssh_port="${ssh_port//$'\r'/}"
        root_password="${root_password//$'\r'/}"
        extra="${extra//$'\r'/}"

        if [ "$line_number" -eq 1 ]; then
            local header
            header="$current_alias,$endpoint,$expected_ip,$connection,$ssh_port,$root_password"
            if [ "$header" != "$EXPECTED_CSV_HEADER" ] || [ -n "$extra" ]; then
                print_error "nodes.csv header must be exactly:"
                echo "$EXPECTED_CSV_HEADER"
                exit 1
            fi
            header_seen="true"
            continue
        fi

        if [ "$current_alias" = "$NODE_ALIAS" ]; then
            validate_expected_ip "$current_alias" "$endpoint" "$expected_ip" "$line_number"
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
        --ssh-hardening-only)
            SSH_HARDENING_ONLY="true"
            shift
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

if [ -z "$TARGET" ] && [ "$SSH_HARDENING_ONLY" = "true" ]; then
    TARGET="ssh-hardening"
fi

if [ -z "$TARGET" ]; then
    usage
    exit 1
fi

if [ "$SSH_HARDENING_ONLY" != "true" ] && [ "$CSV_MODE" != "true" ]; then
    case "$TARGET" in
        orchestration-management)
            NODE_ROLE="management"
            DEPLOY_DIR="/opt/ai-service-platform"
            RUNTIME_ENV_FILE=""
            GITHUB_ENVIRONMENT="orchestration-management"
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
APPLY_SSH_HARDENING="${APPLY_SSH_HARDENING:-1}"
APT_LOCK_WAIT_SECONDS="${APT_LOCK_WAIT_SECONDS:-600}"
FORCE_REGENERATE_KEYS="${FORCE_REGENERATE_KEYS:-0}"
DEPLOY_KEY_NAME="github_deploy"
ADMIN_KEY_NAME="admin_key"
ANSIBLE_KEY_NAME="ansible_control"

if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root. Use sudo."
    exit 1
fi

ensure_command() {
    local command_name="$1"
    local package_name="$2"
    if command -v "$command_name" >/dev/null 2>&1; then
        return
    fi
    print_warning "$command_name not found; installing package $package_name"
    run_apt_get update -y
    run_apt_get install -y "$package_name"
}

docker_runtime_ready() {
    command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

docker_command_available() {
    command -v docker >/dev/null 2>&1
}

docker_compose_available() {
    docker compose version >/dev/null 2>&1
}

apt_lock_is_held() {
    local lock_file
    if ! command -v fuser >/dev/null 2>&1; then
        return 1
    fi

    for lock_file in \
        /var/lib/dpkg/lock-frontend \
        /var/lib/dpkg/lock \
        /var/lib/apt/lists/lock \
        /var/cache/apt/archives/lock
    do
        if [ -e "$lock_file" ] && fuser "$lock_file" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

print_apt_lock_holders() {
    local lock_file
    local printed="false"

    if command -v fuser >/dev/null 2>&1; then
        for lock_file in \
            /var/lib/dpkg/lock-frontend \
            /var/lib/dpkg/lock \
            /var/lib/apt/lists/lock \
            /var/cache/apt/archives/lock
        do
            if [ -e "$lock_file" ] && fuser "$lock_file" >/dev/null 2>&1; then
                echo "Apt lock holder for $lock_file:"
                fuser -v "$lock_file" 2>&1 || true
                printed="true"
            fi
        done
    fi

    echo "Apt/dpkg related processes:"
    ps -eo pid,ppid,stat,etime,comm,args | grep -E 'apt|apt-get|dpkg|unattended-upgr' | grep -v grep || true

    if [ "$printed" != "true" ]; then
        echo "No apt lock holder could be detected with fuser."
    fi
}

wait_for_apt_locks() {
    local waited=0
    local interval=5

    while apt_lock_is_held; do
        if [ "$waited" -ge "$APT_LOCK_WAIT_SECONDS" ]; then
            print_warning "Timed out waiting ${APT_LOCK_WAIT_SECONDS}s for apt/dpkg locks"
            print_apt_lock_holders
            print_error "VPS is busy with apt/dpkg or unattended upgrades. Retry bootstrap after package maintenance finishes."
            exit 1
        fi

        if [ "$waited" -eq 0 ] || [ $((waited % 30)) -eq 0 ]; then
            print_warning "Waiting for apt/dpkg lock holders to finish (${waited}/${APT_LOCK_WAIT_SECONDS}s)"
            print_apt_lock_holders
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done
}

run_apt_get() {
    wait_for_apt_locks
    DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C LANGUAGE=C apt-get -o "DPkg::Lock::Timeout=$APT_LOCK_WAIT_SECONDS" "$@"
}

apt_candidate() {
    local package_name="$1"
    LC_ALL=C LANG=C LANGUAGE=C apt-cache policy "$package_name" | awk '/Candidate:/ {print $2; exit}'
}

print_docker_package_diagnostics() {
    print_warning "Docker command status:"
    if docker_command_available; then
        docker --version || true
    else
        echo "docker: not found"
    fi

    print_warning "Docker Compose plugin status:"
    if docker_command_available; then
        docker compose version || true
    else
        echo "docker compose: docker command is not available"
    fi

    print_warning "Docker package candidates:"
    LC_ALL=C LANG=C LANGUAGE=C apt-cache policy docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-compose-v2 || true

    print_warning "Docker package installed state:"
    dpkg-query -W -f='${Package} ${Status} ${Version}\n' docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-compose-v2 2>/dev/null || true
}

enable_universe_if_available() {
    if command -v add-apt-repository >/dev/null 2>&1; then
        add-apt-repository -y universe >/dev/null 2>&1 || true
        return
    fi

    if run_apt_get install -y software-properties-common >/dev/null 2>&1; then
        add-apt-repository -y universe >/dev/null 2>&1 || true
    fi
}

try_install_official_docker() {
    local codename="$1"
    local official_candidate

    if [ -z "$codename" ]; then
        print_warning "Cannot detect Ubuntu codename; skipping Docker official repo"
        return 1
    fi

    install -d -m 0755 /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; then
            print_warning "Could not download Docker official repo GPG key; using distro packages"
            rm -f /etc/apt/keyrings/docker.asc
            return 1
        fi
        chmod 0644 /etc/apt/keyrings/docker.asc
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" > /etc/apt/sources.list.d/docker.list
    if ! run_apt_get update -y; then
        print_warning "Docker official repo update failed for Ubuntu codename '$codename'; using distro packages"
        return 1
    fi

    official_candidate="$(apt_candidate docker-ce)"
    if [ -z "$official_candidate" ] || [ "$official_candidate" = "(none)" ]; then
        print_warning "Docker official repo has no docker-ce candidate for Ubuntu codename '$codename'; using distro packages"
        return 1
    fi

    print_warning "Installing Docker from official Docker repo for Ubuntu codename '$codename'"
    if run_apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        return 0
    fi

    print_warning "Docker official package installation failed; using distro packages"
    return 1
}

install_distro_compose_plugin() {
    local compose_v2_candidate
    local compose_plugin_candidate

    if docker_compose_available; then
        return 0
    fi

    compose_v2_candidate="$(apt_candidate docker-compose-v2)"
    compose_plugin_candidate="$(apt_candidate docker-compose-plugin)"

    if [ -n "$compose_v2_candidate" ] && [ "$compose_v2_candidate" != "(none)" ]; then
        print_warning "Installing Docker Compose plugin from docker-compose-v2"
        if run_apt_get install -y docker-compose-v2 && docker_compose_available; then
            return 0
        fi
        print_warning "docker-compose-v2 installation did not provide a working 'docker compose'"
    fi

    if [ -n "$compose_plugin_candidate" ] && [ "$compose_plugin_candidate" != "(none)" ]; then
        print_warning "Installing Docker Compose plugin from docker-compose-plugin"
        if run_apt_get install -y docker-compose-plugin && docker_compose_available; then
            return 0
        fi
        print_warning "docker-compose-plugin installation did not provide a working 'docker compose'"
    fi

    print_warning "No Docker Compose plugin package candidate is available"
    return 1
}

try_install_distro_docker() {
    rm -f /etc/apt/sources.list.d/docker.list
    if ! run_apt_get update -y; then
        print_warning "apt-get update failed before distro Docker fallback"
        return 1
    fi
    enable_universe_if_available
    if ! run_apt_get update -y; then
        print_warning "apt-get update failed after enabling universe"
        return 1
    fi

    print_warning "Installing Docker from Ubuntu distro packages"
    if ! run_apt_get install -y docker.io; then
        print_warning "Ubuntu distro Docker package installation failed"
        print_docker_package_diagnostics
        return 1
    fi
    if ! docker_command_available; then
        print_warning "docker.io installed but docker CLI is still unavailable"
        print_docker_package_diagnostics
        return 1
    fi

    if ! install_distro_compose_plugin; then
        print_warning "Ubuntu distro Docker Compose plugin installation failed"
        print_docker_package_diagnostics
        return 1
    fi
}

install_docker_runtime() {
    local codename
    local os_id

    if docker_runtime_ready; then
        systemctl enable --now docker >/dev/null 2>&1 || true
        print_success "Docker runtime already available"
        return
    fi

    print_warning "Docker runtime is not available; installing it as bootstrap baseline"
    run_apt_get update -y
    run_apt_get install -y ca-certificates curl gnupg lsb-release

    os_id="$(
        . /etc/os-release
        printf '%s' "${ID:-}"
    )"
    if [ "$os_id" != "ubuntu" ]; then
        print_error "Docker bootstrap currently supports Ubuntu only; detected OS ID: ${os_id:-unknown}"
        exit 1
    fi

    codename="$(
        . /etc/os-release
        printf '%s' "${VERSION_CODENAME:-}"
    )"

    print_warning "Ubuntu Docker install strategy: try official Docker repo for '$codename', then Ubuntu distro packages if unavailable"
    if ! try_install_official_docker "$codename"; then
        if ! try_install_distro_docker; then
            print_error "Docker installation failed from both official and distro package sources"
            print_docker_package_diagnostics
            exit 1
        fi
    fi

    systemctl enable --now docker

    if docker_command_available && ! docker_compose_available; then
        print_warning "Docker daemon is available but Docker Compose plugin is missing; installing compose plugin"
        run_apt_get update -y
        enable_universe_if_available
        run_apt_get update -y
        install_distro_compose_plugin || true
    fi

    if ! docker_runtime_ready; then
        print_error "Docker runtime is still unavailable after installation"
        print_docker_package_diagnostics
        exit 1
    fi

    print_success "Docker runtime is ready"
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

append_ansible_authorized_key_line() {
    local public_key="$1"
    public_key="$(printf '%s' "$public_key" | tr -d '\r')"

    if [ -z "$public_key" ]; then
        return
    fi

    if ! printf '%s\n' "$public_key" | grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) '; then
        print_error "ANSIBLE_AUTHORIZED_KEY does not look like an SSH public key."
        exit 1
    fi

    if [ -z "$ANSIBLE_AUTHORIZED_KEYS" ]; then
        ANSIBLE_AUTHORIZED_KEYS="$public_key"
    else
        ANSIBLE_AUTHORIZED_KEYS="$ANSIBLE_AUTHORIZED_KEYS
$public_key"
    fi
}

install_authorized_keys() {
    local user_name="$1"
    local public_keys="$2"
    local home_dir
    local ssh_dir
    local authorized_keys
    local public_key

    home_dir="$(getent passwd "$user_name" | cut -d: -f6)"
    ssh_dir="$home_dir/.ssh"
    authorized_keys="$ssh_dir/authorized_keys"

    mkdir -p "$ssh_dir"
    touch "$authorized_keys"
    while IFS= read -r public_key || [ -n "$public_key" ]; do
        public_key="$(printf '%s' "$public_key" | tr -d '\r')"
        if [ -z "$public_key" ]; then
            continue
        fi
        if ! grep -Fxq "$public_key" "$authorized_keys"; then
            printf '%s\n' "$public_key" >> "$authorized_keys"
        fi
    done <<EOF
$public_keys
EOF
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

if [ "$SSH_HARDENING_ONLY" = "true" ]; then
    print_header "AI Service Platform SSH hardening"
    apply_ssh_hardening
    print_success "SSH hardening complete"
    exit 0
fi

resolve_ansible_authorized_key() {
    local key_line
    ANSIBLE_AUTHORIZED_KEYS=""

    if [ -n "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
        if [ ! -f "$ANSIBLE_AUTHORIZED_KEY_FILE" ]; then
            print_error "ANSIBLE_AUTHORIZED_KEY_FILE not found: $ANSIBLE_AUTHORIZED_KEY_FILE"
            exit 1
        fi
        while IFS= read -r key_line || [ -n "$key_line" ]; do
            append_ansible_authorized_key_line "$key_line"
        done < "$ANSIBLE_AUTHORIZED_KEY_FILE"
    fi

    if [ -n "$ANSIBLE_AUTHORIZED_KEY" ]; then
        while IFS= read -r key_line || [ -n "$key_line" ]; do
            append_ansible_authorized_key_line "$key_line"
        done <<EOF
$ANSIBLE_AUTHORIZED_KEY
EOF
    fi
}

resolve_ansible_authorized_key

if [ "$NODE_ROLE" = "managed" ] && [ -z "$ANSIBLE_AUTHORIZED_KEYS" ]; then
    print_error "Managed target $TARGET requires the orchestration Ansible control public key."
    echo ""
    echo "Copy this public key file from the active orchestration node to the managed VPS:"
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
        echo "  sudo ANSIBLE_AUTHORIZED_KEY='ssh-ed25519 ... ansible-control@orchestration' bash setup_vps.sh $TARGET"
    fi
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
echo "  SSH hardening:      $APPLY_SSH_HARDENING"
echo "  Regenerate keys:    $FORCE_REGENERATE_KEYS"
echo ""

print_header "1/7 - Base packages"
ensure_command sudo sudo
ensure_command ssh-keygen openssh-client
ensure_command curl curl
if [ "$NODE_ROLE" = "management" ]; then
    print_warning "Preparing Ubuntu apt sources for management packages"
    run_apt_get update -y
    enable_universe_if_available
    run_apt_get update -y
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
    if [ -n "$ANSIBLE_AUTHORIZED_KEYS" ]; then
        install_authorized_keys "$ANSIBLE_USER" "$ANSIBLE_AUTHORIZED_KEYS"
        print_success "orchestration Ansible trust public keys installed for $ANSIBLE_USER"
    fi
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
    if [ -n "$ANSIBLE_AUTHORIZED_KEYS" ]; then
        install_authorized_keys "$ANSIBLE_USER" "$ANSIBLE_AUTHORIZED_KEYS"
        print_success "orchestration Ansible control public keys installed for $ANSIBLE_USER"
    else
        mkdir -p "$ANSIBLE_HOME/.ssh"
        touch "$ANSIBLE_HOME/.ssh/authorized_keys"
        chown -R "$ANSIBLE_USER:$ANSIBLE_USER" "$ANSIBLE_HOME/.ssh"
        chmod 700 "$ANSIBLE_HOME/.ssh"
        chmod 600 "$ANSIBLE_HOME/.ssh/authorized_keys"
        print_warning "Add the orchestration Ansible control public key to this node after orchestration bootstrap."
        print_warning "Or rerun bootstrap with ANSIBLE_AUTHORIZED_KEY='ssh-ed25519 ...'."
    fi
    lock_user_password "$ANSIBLE_USER"
    print_warning "Ansible provisioning should run from the active orchestration node, not directly from GitHub Actions."
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

print_header "5/7 - Docker runtime baseline"
install_docker_runtime

print_header "6/7 - SSH hardening"
if [ "$APPLY_SSH_HARDENING" = "1" ]; then
    apply_ssh_hardening
else
    print_warning "SSH hardening deferred by APPLY_SSH_HARDENING=0"
fi

print_header "7/7 - Values for GitHub Environment"
SERVER_IP="$(curl -fsS https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
DEPLOY_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
ANSIBLE_HOME="$(getent passwd "$ANSIBLE_USER" | cut -d: -f6 2>/dev/null || true)"
DEPLOY_KEY_PATH="$DEPLOY_HOME/.ssh/$DEPLOY_KEY_NAME"
ADMIN_KEY_PATH="$ADMIN_HOME/.ssh/$ADMIN_KEY_NAME"
ANSIBLE_KEY_PATH="${ANSIBLE_HOME:-}/.ssh/$ANSIBLE_KEY_NAME"
RECOVERY_DIR="/root/ai-service-platform-bootstrap"
RECOVERY_FILE="$RECOVERY_DIR/$TARGET.keys.txt"

mkdir -p "$RECOVERY_DIR"
chmod 700 "$RECOVERY_DIR"

{
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
    echo "--- BEGIN SSH_KEY ---"
    cat "$DEPLOY_KEY_PATH"
    echo "--- END SSH_KEY ---"
    echo ""
    if [ "$NODE_ROLE" = "management" ]; then
        echo "--- BEGIN ANSIBLE CONTROL KEY ---"
        cat "$ANSIBLE_KEY_PATH"
        echo "--- END ANSIBLE CONTROL KEY ---"
        echo ""
        echo "__ANSIBLE_CONTROL_PUBLIC_KEY_BEGIN__"
        cat "$ANSIBLE_KEY_PATH.pub"
        echo "__ANSIBLE_CONTROL_PUBLIC_KEY_END__"
        echo ""
    fi
    echo "--- BEGIN ADMIN KEY ---"
    cat "$ADMIN_KEY_PATH"
    echo "--- END ADMIN KEY ---"
} > "$RECOVERY_FILE"
chmod 600 "$RECOVERY_FILE"

echo ""
echo -e "${YELLOW}IMPORTANT: private keys are printed for one-time copy only.${NC}"
echo -e "${YELLOW}Do not save them in repository files, docs, issues, or chat logs.${NC}"
echo -e "${YELLOW}Recovery copy on server: $RECOVERY_FILE${NC}"
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
    echo "  4. Run infra/ansible/site.yml from the active orchestration node."
else
    echo "  1. Add the orchestration Ansible control public key to this node."
    echo "  2. Run infra/ansible/site.yml from the active orchestration node to finish OS provisioning."
    echo "  3. For temporary GitHub deploy access, store SSH_HOST, SSH_USER, SSH_PORT, SSH_KEY in the relevant GitHub Environment."
    if [ -n "$RUNTIME_ENV_FILE" ]; then
        echo "  4. Fill runtime secrets in $RUNTIME_ENV_FILE on this VPS."
    fi
fi
