#!/usr/bin/env bash

set -euo pipefail

REPO="airiga1897/AI_Service_Platform"
ENVIRONMENT="ai-retail-dev-preprod"
SSH_HOST=""
SSH_USER="depuser"
SSH_PORT="22"
SSH_KEY_FILE=""
NODES_FILE=""
NODE_ALIAS=""

usage() {
    cat <<'USAGE'
Usage:
  bash tools/github/ensure_environment_secrets.sh \
    --ssh-host vps02.example.com \
    --ssh-key-file ./operator/ai-retail-dev-preprod.deploy_key

Options:
  --repo OWNER/REPO          GitHub repository. Default: airiga1897/AI_Service_Platform
  --env NAME                 GitHub Environment. Default: ai-retail-dev-preprod
  --ssh-host VALUE           SSH_HOST secret value.
  --ssh-user VALUE           SSH_USER secret value. Default: depuser
  --ssh-port VALUE           SSH_PORT secret value. Default: 22
  --ssh-key-file PATH        File with private SSH key for SSH_KEY.
  --nodes-file PATH          Optional operator nodes.csv source.
  --alias VALUE              Optional current_alias to resolve SSH_HOST from nodes.csv.
  -h, --help                 Show this help.
USAGE
}

fail() {
    echo "[ERROR] $1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 not found in PATH"
}

require_gh_auth() {
    if ! gh auth status >/tmp/ai_service_platform_gh_auth_status.log 2>&1; then
        cat /tmp/ai_service_platform_gh_auth_status.log >&2 || true
        rm -f /tmp/ai_service_platform_gh_auth_status.log
        cat >&2 <<EOF
[ERROR] GitHub CLI is not authenticated.

Run:
  gh auth login

Use an account with repo access to $REPO, then re-run this script.
EOF
        exit 1
    fi
    rm -f /tmp/ai_service_platform_gh_auth_status.log
}

write_secret_from_string() {
    local name="$1"
    local value="$2"
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' RETURN
    printf '%s' "$value" > "$tmp"
    gh secret set "$name" --repo "$REPO" --env "$ENVIRONMENT" --body-file "$tmp"
    rm -f "$tmp"
    trap - RETURN
    echo "Secret ensured: $name"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)
            REPO="${2:-}"
            shift 2
            ;;
        --env)
            ENVIRONMENT="${2:-}"
            shift 2
            ;;
        --ssh-host)
            SSH_HOST="${2:-}"
            shift 2
            ;;
        --ssh-user)
            SSH_USER="${2:-}"
            shift 2
            ;;
        --ssh-port)
            SSH_PORT="${2:-}"
            shift 2
            ;;
        --ssh-key-file)
            SSH_KEY_FILE="${2:-}"
            shift 2
            ;;
        --nodes-file)
            NODES_FILE="${2:-}"
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
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

require_command gh
require_gh_auth

[ -n "$REPO" ] || fail "--repo is required"
[ -n "$ENVIRONMENT" ] || fail "--env is required"
[ -n "$SSH_USER" ] || fail "--ssh-user is required"
[ -n "$SSH_PORT" ] || fail "--ssh-port is required"
[ -n "$SSH_KEY_FILE" ] || fail "--ssh-key-file is required"
[ -f "$SSH_KEY_FILE" ] || fail "SSH key file not found: $SSH_KEY_FILE"

if [ -n "$NODES_FILE" ] || [ -n "$NODE_ALIAS" ]; then
    [ -n "$NODES_FILE" ] && [ -n "$NODE_ALIAS" ] || fail "--nodes-file and --alias must be provided together"
    [ -f "$NODES_FILE" ] || fail "nodes file not found: $NODES_FILE"
    line_number=0
    found="false"
    while IFS=, read -r csv_alias csv_endpoint csv_expected_ip csv_connection csv_ssh_port _csv_root_password extra || [ -n "${csv_alias:-}" ]; do
        line_number=$((line_number + 1))
        csv_alias="${csv_alias//$'\r'/}"
        csv_endpoint="${csv_endpoint//$'\r'/}"
        csv_connection="${csv_connection//$'\r'/}"
        csv_ssh_port="${csv_ssh_port//$'\r'/}"
        _csv_root_password="${_csv_root_password//$'\r'/}"
        extra="${extra//$'\r'/}"
        if [ "$line_number" -eq 1 ]; then
            header="$csv_alias,$csv_endpoint,$csv_connection,$csv_ssh_port,$_csv_root_password"
            expected_header="current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
            [ "$header" = "$expected_header" ] && [ -z "$extra" ] || fail "nodes.csv header must be exactly: $expected_header"
            continue
        fi
        if [ "$csv_alias" = "$NODE_ALIAS" ]; then
            [ "$csv_endpoint" != "local" ] && [ "$csv_connection" != "local" ] || fail "Alias $NODE_ALIAS uses local endpoint; GitHub SSH secrets require a public DNS/IP endpoint"
            if [ -z "$SSH_HOST" ]; then
                SSH_HOST="$csv_endpoint"
            fi
            if [ -z "$SSH_PORT" ]; then
                SSH_PORT="${csv_ssh_port:-22}"
            fi
            found="true"
            break
        fi
    done < "$NODES_FILE"
    [ "$found" = "true" ] || fail "Alias not found in nodes file: $NODE_ALIAS"
fi

[ -n "$SSH_HOST" ] || fail "--ssh-host is required, or provide --nodes-file and --alias"

env_path="repos/$REPO/environments/$ENVIRONMENT"

echo "Checking GitHub Environment: $REPO / $ENVIRONMENT"
if gh api "$env_path" --silent >/dev/null 2>&1; then
    echo "GitHub Environment already exists: $ENVIRONMENT"
else
    echo "GitHub Environment not found; creating: $ENVIRONMENT"
    gh api --method PUT "$env_path" --silent
    echo "GitHub Environment created: $ENVIRONMENT"
fi

echo "Ensuring Environment secrets for $ENVIRONMENT"
write_secret_from_string "SSH_HOST" "$SSH_HOST"
write_secret_from_string "SSH_USER" "$SSH_USER"
write_secret_from_string "SSH_PORT" "$SSH_PORT"
gh secret set SSH_KEY --repo "$REPO" --env "$ENVIRONMENT" --body-file "$SSH_KEY_FILE"
echo "Secret ensured: SSH_KEY"

echo "GitHub Environment secrets are ready: $ENVIRONMENT"
