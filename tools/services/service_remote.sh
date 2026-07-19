#!/usr/bin/env bash

set -euo pipefail

SERVICE="${1:-}"
ACTION="${2:-}"
NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
CONTROL_ROLE="orchestration"
CONTROL_ALIAS=""
OPERATOR_DIR="./operator"
SSH_USER="useradmin"
SSH_KEY_FILE=""
REMOTE_REPO_DIR="/opt/ai-service-platform"
REMOTE_NODES_FILE="/opt/ai-service-platform/operator/nodes.csv"
REMOTE_STATE_FILE="/opt/ai-service-platform/operator/state.csv"
REMOTE_INVENTORY="/opt/ai-service-platform/inventory.ini"
SERVICE_RUNNER_SCRIPT="tools/services/service.sh"
CREATE_INVENTORY_SCRIPT="tools/bootstrap/create_inventory.sh"
ANSIBLE_DIR="infra/ansible"
POLICY_ROUTER_DOCKER_DIR="infra/docker/policy-router"
POLICY_GATEWAY_DOCKER_DIR="infra/docker/policy-gateway"
SOFTETHER_VPNCLIENT_DOCKER_DIR="infra/docker/softether-vpnclient"
EGRESS_POLICY_TOOLS_DIR="tools/egress_policy"
SERVICES_REGISTRY_FILE="services.yml"
SITE_RUNTIME_TOOLS_DIR="tools/site_runtime"
SITE_RUNTIME_PREPARE_SCRIPT="tools/site_runtime/prepare_image.sh"
SITE_RUNTIME_SUPPORT_PREPARE_SCRIPT="tools/site_runtime/prepare_support_images.sh"
LIMIT=""
INSTANCE=""
IMAGE_REF=""
BUILD_POLICY_ROUTER_IMAGE="false"
PLATFORM_ROUTER_SOFTETHER_DEBUG="false"
CHECK="false"
CONFIRM_PURGE="false"
DETACHED_REMOTE_JOB="false"
REMOTE_JOB_POLL_SECONDS=2
REMOTE_JOB_RECONNECT_ATTEMPTS=30
REMOTE_JOB_HEARTBEAT_SECONDS=10

EXPECTED_HEADER="current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
EXPECTED_STATE_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"

usage() {
    cat <<'USAGE'
Usage:
  bash tools/services/service_remote.sh <service> <plan|apply|absent|purge|reseed|probe|stage-image|stage-support-images> [options]

Options:
  --nodes-file PATH       Operator nodes.csv. Default: ./operator/nodes.csv
  --state-file PATH       Operator state.csv. Default: ./operator/state.csv
  --control-role NAME     Platform role to use as orchestration. Default: orchestration
  --control-alias ALIAS   Optional explicit orchestration alias.
  --operator-dir PATH     Operator directory. Default: ./operator
  --ssh-user USER         SSH user on orchestration node. Default: useradmin
  --ssh-key-file PATH     SSH private key. Default: ./operator/<control-alias>/admin_key
  --remote-repo-dir PATH  Repo path on orchestration node. Default: /opt/ai-service-platform
  --limit ALIAS           Service target alias.
  --instance NAME         site_runtime instance name.
  --image-ref REF         site_runtime immutable repository@sha256 reference.
  --build-policy-router-image
                        vpn_cascade only: force rebuild instead of reusing a matching local image.
  --platform-router-softether-debug
                        platform_router only: show SoftEther server configure task output for diagnostics.
  --check                 Pass --check to service.sh apply.
  --confirm-purge         Pass --confirm-purge to service.sh purge.
  --detached-remote-job   Run service command as a detached job and poll its log.
  --remote-job-poll-seconds SECONDS
                          Poll interval for detached remote jobs. Default: 2.
  --remote-job-reconnect-attempts COUNT
                          SSH reconnect attempts while polling remote jobs. Default: 30.
  --remote-job-heartbeat-seconds SECONDS
                          Print a progress heartbeat when the remote log is quiet. Default: 10.
  -h, --help              Show help.
USAGE
}

fail() {
    echo "[ERROR] $1" >&2
    exit 1
}

require_file() {
    local path="$1"
    local label="$2"
    [ -f "$path" ] || fail "$label not found: $path"
}

quote_bash_arg() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\\\'\'}"
}

split_aliases_to_lines() {
    local aliases="$1"
    local old_ifs="$IFS"
    local alias_item
    IFS=+
    for alias_item in $aliases; do
        IFS="$old_ifs"
        [ -n "$alias_item" ] && printf '%s\n' "$alias_item"
        IFS=+
    done
    IFS="$old_ifs"
}

invoke_retry_transport() {
    local label="$1"
    shift
    local attempt
    local exit_code
    for attempt in 1 2 3; do
        if "$@"; then
            return 0
        fi
        exit_code=$?
        if [ "$exit_code" -ne 255 ] || [ "$attempt" -eq 3 ]; then
            fail "$label failed with exit code $exit_code"
        fi
        echo "$label hit SSH transport reset (exit 255), retrying $attempt/3..."
        sleep 2
    done
}

run_cleanup_ssh() {
    local cleanup_command
    if [ "${DETACHED_REMOTE_JOB:-false}" = "true" ] && [ "${remote_job_completed_successfully:-false}" != "true" ]; then
        cleanup_command="rm -rf $(quote_bash_arg "$remote_bundle_dir") $(quote_bash_arg "$remote_bundle_archive")"
        echo "Preserving failed remote job state: $remote_job_dir and log: $remote_job_log" >&2
    else
        cleanup_command="rm -rf $(quote_bash_arg "$remote_bundle_dir") $(quote_bash_arg "$remote_bundle_archive") $(quote_bash_arg "$remote_job_dir")"
    fi
    if ! ssh "${ssh_common_args[@]}" "$remote" "$cleanup_command" >/dev/null 2>&1; then
        echo "[!] remote service bundle/job cleanup failed; continuing because cleanup is best-effort" >&2
    fi
}

wait_remote_service_job() {
    local printed_lines=0
    local transport_failures=0
    local started_at
    local last_heartbeat_at
    local poll_command
    local output
    local exit_code
    local line
    local seen_done
    local remote_exit_code
    local printed_this_poll
    local now
    local current_step="remote job"
    local last_task=""

    started_at="$(date +%s)"
    last_heartbeat_at="$started_at"

    while true; do
        poll_command="if [ -f $(quote_bash_arg "$remote_job_log") ]; then tail -n +$((printed_lines + 1)) $(quote_bash_arg "$remote_job_log"); fi; if [ -f $(quote_bash_arg "$remote_job_done") ]; then echo __SERVICE_JOB_DONE__; cat $(quote_bash_arg "$remote_job_exit_code"); fi"
        set +e
        output="$(ssh "${ssh_common_args[@]}" "$remote" "$poll_command" 2>&1)"
        exit_code=$?
        set -e

        if [ "$exit_code" -eq 255 ]; then
            transport_failures=$((transport_failures + 1))
            if [ "$transport_failures" -gt "$REMOTE_JOB_RECONNECT_ATTEMPTS" ]; then
                fail "remote job status unavailable after $REMOTE_JOB_RECONNECT_ATTEMPTS reconnect attempts"
            fi
            echo "remote job polling hit SSH transport reset (exit 255), reconnecting $transport_failures/$REMOTE_JOB_RECONNECT_ATTEMPTS..."
            sleep "$REMOTE_JOB_POLL_SECONDS"
            continue
        fi
        [ "$exit_code" -eq 0 ] || fail "remote job status check failed with exit code $exit_code"

        transport_failures=0
        seen_done="false"
        remote_exit_code=""
        printed_this_poll=0
        if [ -n "$output" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                if [ "$seen_done" = "true" ]; then
                    remote_exit_code="$line"
                    break
                fi
                if [ "$line" = "__SERVICE_JOB_DONE__" ]; then
                    seen_done="true"
                    continue
                fi
                printf '%s\n' "$line"
                case "$line" in
                    "[batch] Step "*)
                        current_step="${line#"[batch] "}"
                        ;;
                    "TASK ["*)
                        last_task="${line#TASK [}"
                        last_task="${last_task%%]*}"
                        ;;
                    "[remote-job]"*"running service command: "*)
                        current_step="${line#*running service command: }"
                        ;;
                esac
                printed_lines=$((printed_lines + 1))
                printed_this_poll=$((printed_this_poll + 1))
            done <<< "$output"
        fi

        if [ "$seen_done" = "true" ]; then
            case "$remote_exit_code" in
                ''|*[!0-9]*) fail "remote job completed but exit_code is invalid: ${remote_exit_code:-<empty>}" ;;
            esac
            [ "$remote_exit_code" -eq 0 ] || fail "remote service command failed with exit code $remote_exit_code"
            now="$(date +%s)"
            printf 'remote job completed successfully after %02d:%02d:%02d\n' "$(((now - started_at) / 3600))" "$((((now - started_at) % 3600) / 60))" "$(((now - started_at) % 60))"
            return 0
        fi

        now="$(date +%s)"
        if [ "$printed_this_poll" -eq 0 ] && [ "$REMOTE_JOB_HEARTBEAT_SECONDS" -gt 0 ] && [ $((now - last_heartbeat_at)) -ge "$REMOTE_JOB_HEARTBEAT_SECONDS" ]; then
            if [ -n "$last_task" ]; then
                printf '[WAIT] %s is still running; last task: %s; remote log: %s\n' "$current_step" "$last_task" "$remote_job_log"
            else
                printf '[WAIT] %s is still running; remote log: %s\n' "$current_step" "$remote_job_log"
            fi
            last_heartbeat_at="$now"
        fi
        sleep "$REMOTE_JOB_POLL_SECONDS"
    done
}

if [ "$SERVICE" = "-h" ] || [ "$SERVICE" = "--help" ]; then
    usage
    exit 0
fi
case "$ACTION" in
    plan|apply|absent|purge|reseed|probe|stage-image|stage-support-images) ;;
    *) usage; fail "Action must be one of: plan, apply, absent, purge, reseed, probe, stage-image, stage-support-images" ;;
esac
if [ "$SERVICE" = "vpn" ]; then
    fail "Unsupported service 'vpn'. Use canonical service name: vpn_edge"
fi

shift 2
while [ "$#" -gt 0 ]; do
    case "$1" in
        --nodes-file) NODES_FILE="${2:-}"; shift 2 ;;
        --state-file) STATE_FILE="${2:-}"; shift 2 ;;
        --control-role) CONTROL_ROLE="${2:-}"; shift 2 ;;
        --control-alias) CONTROL_ALIAS="${2:-}"; shift 2 ;;
        --operator-dir) OPERATOR_DIR="${2:-}"; shift 2 ;;
        --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
        --ssh-key-file) SSH_KEY_FILE="${2:-}"; shift 2 ;;
        --remote-repo-dir) REMOTE_REPO_DIR="${2:-}"; shift 2 ;;
        --limit) LIMIT="${2:-}"; shift 2 ;;
        --instance) INSTANCE="${2:-}"; shift 2 ;;
        --image-ref) IMAGE_REF="${2:-}"; shift 2 ;;
        --build-policy-router-image) BUILD_POLICY_ROUTER_IMAGE="true"; shift ;;
        --platform-router-softether-debug) PLATFORM_ROUTER_SOFTETHER_DEBUG="true"; shift ;;
        --check) CHECK="true"; shift ;;
        --confirm-purge) CONFIRM_PURGE="true"; shift ;;
        --detached-remote-job) DETACHED_REMOTE_JOB="true"; shift ;;
        --remote-job-poll-seconds) REMOTE_JOB_POLL_SECONDS="${2:-}"; shift 2 ;;
        --remote-job-reconnect-attempts) REMOTE_JOB_RECONNECT_ATTEMPTS="${2:-}"; shift 2 ;;
        --remote-job-heartbeat-seconds) REMOTE_JOB_HEARTBEAT_SECONDS="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

if [ "$SERVICE" = "host_resources" ] && [ "$ACTION" != "plan" ] && [ "$ACTION" != "apply" ]; then
    fail "host_resources v1 supports only plan and apply; absent/purge/reseed are intentionally disabled"
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" != "plan" ] && [ "$ACTION" != "probe" ] && [ "$ACTION" != "stage-image" ] && [ "$ACTION" != "stage-support-images" ] && [ "$ACTION" != "apply" ]; then
    fail "site_runtime action is not supported"
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "probe" ] && [ "$LIMIT" != "vps3" ]; then
    fail "site_runtime probe requires exactly --limit vps3"
fi
if [ "$SERVICE" = "site_runtime" ] && [ -z "$LIMIT" ]; then
    fail "site_runtime requires exactly one --limit alias"
fi
if [ "$SERVICE" = "site_runtime" ] && { [ "$ACTION" = "plan" ] || [ "$ACTION" = "stage-image" ] || [ "$ACTION" = "apply" ]; } && { [ -z "$INSTANCE" ] || [ -z "$IMAGE_REF" ] || [ -z "$LIMIT" ]; }; then
    fail "site_runtime $ACTION requires --instance, --image-ref, and exactly one --limit alias"
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" != "probe" ] && [ "$DETACHED_REMOTE_JOB" != "true" ]; then
    fail "site_runtime plan/staging/apply requires --detached-remote-job in the Bash remote wrapper"
fi
if [ "$SERVICE" != "site_runtime" ] && [ "$ACTION" = "probe" ]; then
    fail "probe is supported only for site_runtime"
fi

require_file "$NODES_FILE" "--nodes-file"
require_file "$STATE_FILE" "--state-file"
require_file "$SERVICE_RUNNER_SCRIPT" "--service-runner-script"
require_file "$CREATE_INVENTORY_SCRIPT" "--create-inventory-script"
NETWORKS_FILE="$(dirname "$STATE_FILE")/networks.csv"
require_file "$NETWORKS_FILE" "networks.csv"
[ -d "$ANSIBLE_DIR" ] || fail "Ansible directory not found: $ANSIBLE_DIR"
[ -d "$POLICY_ROUTER_DOCKER_DIR" ] || fail "Policy-router Docker context not found: $POLICY_ROUTER_DOCKER_DIR"
[ -d "$POLICY_GATEWAY_DOCKER_DIR" ] || fail "Policy-gateway Docker context not found: $POLICY_GATEWAY_DOCKER_DIR"
[ -d "$SOFTETHER_VPNCLIENT_DOCKER_DIR" ] || fail "SoftEther vpnclient Docker context not found: $SOFTETHER_VPNCLIENT_DOCKER_DIR"
[ -d "$EGRESS_POLICY_TOOLS_DIR" ] || fail "Egress policy tools directory not found: $EGRESS_POLICY_TOOLS_DIR"
require_file "$SERVICES_REGISTRY_FILE" "services registry"
[ -d "$SITE_RUNTIME_TOOLS_DIR" ] || fail "site_runtime tools directory not found: $SITE_RUNTIME_TOOLS_DIR"
[ "$SERVICE" != "site_runtime" ] || [ "$ACTION" != "stage-image" ] || require_file "$SITE_RUNTIME_PREPARE_SCRIPT" "site_runtime prepare script"
[ "$SERVICE" != "site_runtime" ] || [ "$ACTION" != "stage-support-images" ] || require_file "$SITE_RUNTIME_SUPPORT_PREPARE_SCRIPT" "site_runtime support prepare script"
if [ "$BUILD_POLICY_ROUTER_IMAGE" = "true" ] && [ "$SERVICE" != "vpn_cascade" ]; then
    fail "--build-policy-router-image is supported only for service vpn_cascade"
fi
if [ "$PLATFORM_ROUTER_SOFTETHER_DEBUG" = "true" ] && [ "$SERVICE" != "platform_router" ]; then
    fail "--platform-router-softether-debug is supported only for service platform_router"
fi
command -v ssh >/dev/null 2>&1 || fail "ssh not found in PATH"
command -v scp >/dev/null 2>&1 || fail "scp not found in PATH"
command -v tar >/dev/null 2>&1 || fail "tar not found in PATH"

first_line="$(head -n 1 "$NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_HEADER"
state_first_line="$(head -n 1 "$STATE_FILE" | tr -d '\r')"
[ "$state_first_line" = "$EXPECTED_STATE_HEADER" ] || fail "state.csv header must be exactly: $EXPECTED_STATE_HEADER"

control_rows=0
active_aliases=""
while IFS=, read -r kind name _ansible_group row_active_aliases _candidate_aliases _old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    row_active_aliases="${row_active_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ -z "$kind" ] && continue
    [ -z "$extra" ] || fail "state.csv row has too many columns"
    if { [ "$kind" = "platform_role" ] || [ "$kind" = "role" ]; } && [ "$name" = "$CONTROL_ROLE" ] && [ "$row_state" = "present" ]; then
        control_rows=$((control_rows + 1))
        active_aliases="$row_active_aliases"
    fi
done < <(tail -n +2 "$STATE_FILE")

[ "$control_rows" -eq 1 ] || fail "state.csv must contain exactly one present platform_role $CONTROL_ROLE row"
if [ -n "$CONTROL_ALIAS" ]; then
    found_explicit="false"
    while IFS= read -r alias_item; do
        [ "$alias_item" = "$CONTROL_ALIAS" ] && found_explicit="true"
    done < <(split_aliases_to_lines "$active_aliases")
    [ "$found_explicit" = "true" ] || fail "Control alias $CONTROL_ALIAS is not active for role '$CONTROL_ROLE' in state.csv."
    active_aliases="$CONTROL_ALIAS"
fi
case "$active_aliases" in
    "") fail "Control role '$CONTROL_ROLE' must have exactly one active alias in state.csv." ;;
    *+*) fail "Control role '$CONTROL_ROLE' has multiple active aliases in state.csv. Keep one active alias and put reserve nodes in candidate_aliases." ;;
esac

control_endpoint=""
control_connection=""
control_ssh_port="22"
while IFS=, read -r current_alias endpoint expected_ip connection ssh_port _root_password extra || [ -n "${current_alias:-}" ]; do
    current_alias="${current_alias//$'\r'/}"
    endpoint="${endpoint//$'\r'/}"
    connection="${connection//$'\r'/}"
    ssh_port="${ssh_port//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ -z "$current_alias" ] && continue
    [ -z "$extra" ] || fail "nodes.csv row for $current_alias has too many columns"
    if [ "$current_alias" = "$active_aliases" ]; then
        control_endpoint="$endpoint"
        control_connection="$connection"
        control_ssh_port="${ssh_port:-22}"
        break
    fi
done < <(tail -n +2 "$NODES_FILE")

[ -n "$control_endpoint" ] || fail "Control alias from state.csv not found in nodes.csv: $active_aliases"
[ "$control_connection" = "ssh" ] && [ "$control_endpoint" != "local" ] || fail "Control node $active_aliases must use connection=ssh and a real endpoint for remote service execution."
if [ -z "$SSH_KEY_FILE" ]; then
    SSH_KEY_FILE="$OPERATOR_DIR/$active_aliases/admin_key"
fi
require_file "$SSH_KEY_FILE" "--ssh-key-file"

remote="$SSH_USER@$control_endpoint"
remote_bundle_dir="/tmp/ai-service-platform.service-remote.$(date +%s).$$"
remote_bundle_archive="$remote_bundle_dir.tar.gz"
remote_service_runner_temp="$remote_bundle_dir/service.sh"
remote_create_inventory_temp="$remote_bundle_dir/tools/bootstrap/create_inventory.sh"
remote_ansible_temp="$remote_bundle_dir/ansible"
remote_policy_router_docker_temp="$remote_bundle_dir/docker/policy-router"
remote_policy_gateway_docker_temp="$remote_bundle_dir/docker/policy-gateway"
remote_softether_vpnclient_docker_temp="$remote_bundle_dir/docker/softether-vpnclient"
remote_egress_policy_tools_temp="$remote_bundle_dir/tools/egress_policy"
remote_site_runtime_tools_temp="$remote_bundle_dir/tools/site_runtime"
remote_services_registry_temp="$remote_bundle_dir/services.yml"
remote_operator_temp="$remote_bundle_dir/operator"
remote_site_runtime_image_archive="$remote_bundle_dir/site-runtime-image.tar"
remote_site_runtime_image_manifest="$remote_bundle_dir/site-runtime-image-manifest.json"
remote_site_runtime_support_archive="$remote_bundle_dir/site-runtime-support-images.tar"
remote_site_runtime_support_manifest="$remote_bundle_dir/site-runtime-support-images-manifest.json"
remote_operator_dir="$(dirname "$REMOTE_STATE_FILE")"
remote_nodes_dir="$(dirname "$REMOTE_NODES_FILE")"
remote_networks_file="$remote_operator_dir/networks.csv"
remote_job_id="service-$(date -u +%Y%m%dT%H%M%SZ)-$$"
remote_job_log_dir="/var/log/ai-service-platform/jobs"
remote_job_state_root="/var/lib/ai-service-platform/jobs"
remote_job_dir="$remote_job_state_root/$remote_job_id"
remote_job_script="$remote_job_dir/run.sh"
remote_job_log="$remote_job_log_dir/$remote_job_id.log"
remote_job_pid="$remote_job_dir/pid"
remote_job_exit_code="$remote_job_dir/exit_code"
remote_job_done="$remote_job_dir/done"
remote_job_completed_successfully="false"
archive_path="$(mktemp -t ai-service-platform.service-remote.XXXXXX.tar.gz)"
staging_dir="$(mktemp -d -t ai-service-platform.service-remote.XXXXXX)"
run_script_path="$(mktemp -t ai-service-platform.service-job.XXXXXX.sh)"
site_runtime_image_temp_dir=""
site_runtime_image_archive=""
site_runtime_image_manifest=""
ssh_common_args=(
    -n
    -T
    -p "$control_ssh_port"
    -i "$SSH_KEY_FILE"
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o IdentitiesOnly=yes
    -o RequestTTY=no
    -o KbdInteractiveAuthentication=no
    -o PasswordAuthentication=no
    -o PreferredAuthentications=publickey
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=2
)
scp_common_args=(
    -B
    -P "$control_ssh_port"
    -i "$SSH_KEY_FILE"
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o IdentitiesOnly=yes
    -o KbdInteractiveAuthentication=no
    -o PasswordAuthentication=no
    -o PreferredAuthentications=publickey
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=2
)

cleanup() {
    rm -rf "$archive_path" "$staging_dir" "$run_script_path"
    [ -z "$site_runtime_image_temp_dir" ] || rm -rf "$site_runtime_image_temp_dir"
    run_cleanup_ssh
}
trap cleanup EXIT

remote_args=(
    "$(quote_bash_arg "$SERVICE")"
    "$(quote_bash_arg "$ACTION")"
    "--nodes-file" "$(quote_bash_arg "$REMOTE_NODES_FILE")"
    "--state-file" "$(quote_bash_arg "$REMOTE_STATE_FILE")"
    "--inventory" "$(quote_bash_arg "$REMOTE_INVENTORY")"
)
[ -n "$LIMIT" ] && remote_args+=("--limit" "$(quote_bash_arg "$LIMIT")")
[ -n "$INSTANCE" ] && remote_args+=("--instance" "$(quote_bash_arg "$INSTANCE")")
[ -n "$IMAGE_REF" ] && remote_args+=("--image-ref" "$(quote_bash_arg "$IMAGE_REF")")
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "stage-image" ]; then
    remote_args+=("--image-archive" "$(quote_bash_arg "$remote_site_runtime_image_archive")")
    remote_args+=("--image-manifest" "$(quote_bash_arg "$remote_site_runtime_image_manifest")")
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "stage-support-images" ]; then
    remote_args+=("--support-archive" "$(quote_bash_arg "$remote_site_runtime_support_archive")")
    remote_args+=("--support-manifest" "$(quote_bash_arg "$remote_site_runtime_support_manifest")")
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" != "probe" ]; then
    remote_args+=("--services-registry" "$(quote_bash_arg "$REMOTE_REPO_DIR/services.yml")")
    remote_args+=("--site-runtime-instances" "$(quote_bash_arg "$REMOTE_REPO_DIR/operator/site_runtime/instances.yml")")
    remote_args+=("--site-runtime-resolver" "$(quote_bash_arg "$REMOTE_REPO_DIR/tools/site_runtime/resolve.py")")
fi
[ "$BUILD_POLICY_ROUTER_IMAGE" = "true" ] && remote_args+=("--build-policy-router-image")
[ "$PLATFORM_ROUTER_SOFTETHER_DEBUG" = "true" ] && remote_args+=("--platform-router-softether-debug")
[ "$CHECK" = "true" ] && remote_args+=("--check")
[ "$CONFIRM_PURGE" = "true" ] && remote_args+=("--confirm-purge")

service_command="set -e; cd $(quote_bash_arg "$REMOTE_REPO_DIR"); if command -v stdbuf >/dev/null 2>&1; then stdbuf -oL -eL bash tools/services/service.sh ${remote_args[*]}; else bash tools/services/service.sh ${remote_args[*]}; fi"
refresh_known_hosts_script="$(cat <<EOF
set -e
nodes_file=$(quote_bash_arg "$REMOTE_NODES_FILE")
control_alias=$(quote_bash_arg "$active_aliases")
ssh_dir=/home/ansible/.ssh
known_hosts="\$ssh_dir/known_hosts"
command -v ssh-keygen >/dev/null 2>&1
command -v ssh-keyscan >/dev/null 2>&1
id ansible >/dev/null 2>&1
install -d -m 700 -o ansible -g ansible "\$ssh_dir"
touch "\$known_hosts"
chown ansible:ansible "\$known_hosts"
chmod 600 "\$known_hosts"
tail -n +2 "\$nodes_file" | while IFS=, read -r current_alias endpoint expected_ip connection ssh_port _root_password extra || [ -n "\${current_alias:-}" ]; do
    current_alias="\${current_alias//$'\r'/}"
    endpoint="\${endpoint//$'\r'/}"
    connection="\${connection//$'\r'/}"
    ssh_port="\${ssh_port//$'\r'/}"
    extra="\${extra//$'\r'/}"
    [ -n "\$current_alias" ] || continue
    [ "\$current_alias" != "\$control_alias" ] || continue
    [ -z "\$extra" ] || { echo "[ERROR] nodes.csv row for \$current_alias has too many columns" >&2; exit 1; }
    [ "\$connection" = "ssh" ] || continue
    [ "\$endpoint" != "local" ] || continue
    [ -n "\$ssh_port" ] || ssh_port=22
    known_host="\$endpoint"
    if [ "\$ssh_port" != "22" ]; then known_host="[\$endpoint]:\$ssh_port"; fi
    echo "Refreshing ansible known_hosts for \$current_alias: \$endpoint:\$ssh_port"
    sudo -u ansible ssh-keygen -R "\$known_host" -f "\$known_hosts" >/dev/null 2>&1 || true
    ssh-keyscan -T 10 -p "\$ssh_port" -H "\$endpoint" >> "\$known_hosts" 2>/dev/null || { echo "[ERROR] ssh-keyscan failed for \$current_alias endpoint: \$endpoint" >&2; exit 1; }
done
sort -u "\$known_hosts" -o "\$known_hosts"
chown ansible:ansible "\$known_hosts"
chmod 600 "\$known_hosts"
echo "[OK] ansible known_hosts refreshed"
EOF
)"
refresh_known_hosts_command="sudo bash -lc $(quote_bash_arg "$refresh_known_hosts_script")"
install_and_run_command="set -e; sudo mkdir -p $(quote_bash_arg "$REMOTE_REPO_DIR/tools/services") $(quote_bash_arg "$REMOTE_REPO_DIR/tools/bootstrap") $(quote_bash_arg "$REMOTE_REPO_DIR/tools") $(quote_bash_arg "$REMOTE_REPO_DIR/infra") $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker"); sudo install -m 700 $(quote_bash_arg "$remote_service_runner_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/tools/services/service.sh"); sudo install -m 700 $(quote_bash_arg "$remote_create_inventory_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/tools/bootstrap/create_inventory.sh"); sudo rm -rf $(quote_bash_arg "$REMOTE_REPO_DIR/tools/egress_policy"); sudo cp -a $(quote_bash_arg "$remote_egress_policy_tools_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/tools/egress_policy"); sudo rm -rf $(quote_bash_arg "$REMOTE_REPO_DIR/infra/ansible"); sudo cp -a $(quote_bash_arg "$remote_ansible_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/infra/ansible"); sudo rm -rf $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker/policy-router"); sudo cp -a $(quote_bash_arg "$remote_policy_router_docker_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker/policy-router"); sudo rm -rf $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker/policy-gateway"); sudo cp -a $(quote_bash_arg "$remote_policy_gateway_docker_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker/policy-gateway"); sudo rm -rf $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker/softether-vpnclient"); sudo cp -a $(quote_bash_arg "$remote_softether_vpnclient_docker_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker/softether-vpnclient"); sudo mkdir -p $(quote_bash_arg "$remote_nodes_dir") $(quote_bash_arg "$remote_operator_dir"); sudo install -o ansible -g ansible -m 600 $(quote_bash_arg "$remote_operator_temp/nodes.csv") $(quote_bash_arg "$REMOTE_NODES_FILE"); sudo install -o ansible -g ansible -m 600 $(quote_bash_arg "$remote_operator_temp/state.csv") $(quote_bash_arg "$REMOTE_STATE_FILE"); sudo install -o ansible -g ansible -m 600 $(quote_bash_arg "$remote_operator_temp/networks.csv") $(quote_bash_arg "$remote_networks_file"); printf '%s\n' 'Refreshing ansible known_hosts from operator nodes'; $refresh_known_hosts_command; for d in haproxy softether edge_banlist postgres platform_networks host_resources platform_router; do if [ -d $(quote_bash_arg "$remote_operator_temp")/\$d ]; then sudo rm -rf $(quote_bash_arg "$remote_operator_dir")/\$d; sudo cp -a $(quote_bash_arg "$remote_operator_temp")/\$d $(quote_bash_arg "$remote_operator_dir")/\$d; sudo chown -R ansible:ansible $(quote_bash_arg "$remote_operator_dir")/\$d; fi; done; sudo bash $(quote_bash_arg "$REMOTE_REPO_DIR/tools/bootstrap/create_inventory.sh") --nodes-file $(quote_bash_arg "$REMOTE_NODES_FILE") --state-file $(quote_bash_arg "$REMOTE_STATE_FILE") --output $(quote_bash_arg "$REMOTE_INVENTORY"); sudo bash -lc $(quote_bash_arg "$service_command")"
remote_service_display="${remote_args[*]}"

echo "Control node: $active_aliases via role '$CONTROL_ROLE'"
echo "Remote:       $remote"
echo "Service:      $SERVICE"
echo "Action:       $ACTION"
[ -n "$LIMIT" ] && echo "Limit:        $LIMIT"
[ -n "$INSTANCE" ] && echo "Instance:     $INSTANCE"
[ -n "$IMAGE_REF" ] && echo "Image:        $IMAGE_REF"
[ "$BUILD_POLICY_ROUTER_IMAGE" = "true" ] && echo "Build policy image: true"
[ "$CHECK" = "true" ] && echo "Check:        true"
if [ "$DETACHED_REMOTE_JOB" = "true" ]; then
    echo "Mode:         detached remote job"
    echo "Job id:       $remote_job_id"
    echo "Remote log:   $remote_job_log"
else
    echo "Mode:         direct SSH stream"
fi

echo "Preparing local service bundle..."
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "stage-image" ]; then
    echo "Preparing exact private image archive on workstation..."
    prepare_output="$(bash "$SITE_RUNTIME_PREPARE_SCRIPT" "$INSTANCE" "$IMAGE_REF" "$LIMIT")"
    prepared_json="$(printf '%s\n' "$prepare_output" | tail -n 1)"
    site_runtime_image_temp_dir="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["temp_dir"])' "$prepared_json")"
    site_runtime_image_archive="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["archive_path"])' "$prepared_json")"
    site_runtime_image_manifest="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["manifest_path"])' "$prepared_json")"
    require_file "$site_runtime_image_archive" "prepared site_runtime archive"
    require_file "$site_runtime_image_manifest" "prepared site_runtime manifest"
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "stage-support-images" ]; then
    echo "Preparing exact Redis/Nginx archives on workstation..."
    prepare_output="$(bash "$SITE_RUNTIME_SUPPORT_PREPARE_SCRIPT" "$LIMIT")"
    prepared_json="$(printf '%s\n' "$prepare_output" | tail -n 1)"
    site_runtime_image_temp_dir="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["temp_dir"])' "$prepared_json")"
    site_runtime_image_archive="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["archive_path"])' "$prepared_json")"
    site_runtime_image_manifest="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["manifest_path"])' "$prepared_json")"
    require_file "$site_runtime_image_archive" "prepared site_runtime support archive"
    require_file "$site_runtime_image_manifest" "prepared site_runtime support manifest"
fi
cp "$SERVICE_RUNNER_SCRIPT" "$staging_dir/service.sh"
mkdir -p "$staging_dir/tools/bootstrap"
cp "$CREATE_INVENTORY_SCRIPT" "$staging_dir/tools/bootstrap/create_inventory.sh"
cp -a "$ANSIBLE_DIR" "$staging_dir/ansible"
mkdir -p "$staging_dir/tools"
cp -a "$EGRESS_POLICY_TOOLS_DIR" "$staging_dir/tools/egress_policy"
cp -a "$SITE_RUNTIME_TOOLS_DIR" "$staging_dir/tools/site_runtime"
cp "$SERVICES_REGISTRY_FILE" "$staging_dir/services.yml"
mkdir -p "$staging_dir/docker"
cp -a "$POLICY_ROUTER_DOCKER_DIR" "$staging_dir/docker/policy-router"
cp -a "$POLICY_GATEWAY_DOCKER_DIR" "$staging_dir/docker/policy-gateway"
cp -a "$SOFTETHER_VPNCLIENT_DOCKER_DIR" "$staging_dir/docker/softether-vpnclient"
mkdir -p "$staging_dir/operator"
cp "$NODES_FILE" "$staging_dir/operator/nodes.csv"
cp "$STATE_FILE" "$staging_dir/operator/state.csv"
cp "$NETWORKS_FILE" "$staging_dir/operator/networks.csv"
operator_source_dir="$(dirname "$NODES_FILE")"
for operator_subdir in haproxy softether edge_banlist postgres platform_networks host_resources platform_router site_runtime; do
    if [ -d "$operator_source_dir/$operator_subdir" ]; then
        cp -a "$operator_source_dir/$operator_subdir" "$staging_dir/operator/$operator_subdir"
    fi
done
tar -czf "$archive_path" -C "$staging_dir" .
if [ "$DETACHED_REMOTE_JOB" = "true" ]; then
    cat > "$run_script_path" <<EOF
#!/usr/bin/env bash
set +e
export PYTHONUNBUFFERED=1
export ANSIBLE_FORCE_COLOR=0
export ANSIBLE_DISPLAY_SKIPPED_HOSTS=true
exec > $(quote_bash_arg "$remote_job_log") 2>&1
log_stage() { printf '[remote-job] %s %s\n' "\$(date -u '+%H:%M:%S')" "\$*"; }
finish_job() { rc="\$1"; printf '%s\n' "\$rc" > $(quote_bash_arg "$remote_job_exit_code"); touch $(quote_bash_arg "$remote_job_done"); exit "\$rc"; }
run_stage() { label="\$1"; shift; log_stage "\$label"; "\$@"; rc="\$?"; if [ "\$rc" -ne 0 ]; then log_stage "failed: \$label (rc=\$rc)"; finish_job "\$rc"; fi; }
run_stage $(quote_bash_arg "prepare repo directories") sudo mkdir -p $(quote_bash_arg "$REMOTE_REPO_DIR/tools/services") $(quote_bash_arg "$REMOTE_REPO_DIR/tools/bootstrap") $(quote_bash_arg "$REMOTE_REPO_DIR/tools") $(quote_bash_arg "$REMOTE_REPO_DIR/infra") $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker")
run_stage $(quote_bash_arg "install service runner") sudo install -m 700 $(quote_bash_arg "$remote_service_runner_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/tools/services/service.sh")
run_stage $(quote_bash_arg "install inventory generator") sudo install -m 700 $(quote_bash_arg "$remote_create_inventory_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/tools/bootstrap/create_inventory.sh")
run_stage $(quote_bash_arg "remove previous egress policy tools") sudo rm -rf $(quote_bash_arg "$REMOTE_REPO_DIR/tools/egress_policy")
run_stage $(quote_bash_arg "install egress policy tools") sudo cp -a $(quote_bash_arg "$remote_egress_policy_tools_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/tools/egress_policy")
run_stage $(quote_bash_arg "remove previous site_runtime tools") sudo rm -rf $(quote_bash_arg "$REMOTE_REPO_DIR/tools/site_runtime")
run_stage $(quote_bash_arg "install site_runtime tools") sudo cp -a $(quote_bash_arg "$remote_site_runtime_tools_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/tools/site_runtime")
run_stage $(quote_bash_arg "install services registry") sudo install -m 644 $(quote_bash_arg "$remote_services_registry_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/services.yml")
run_stage $(quote_bash_arg "remove previous Ansible bundle") sudo rm -rf $(quote_bash_arg "$REMOTE_REPO_DIR/infra/ansible")
run_stage $(quote_bash_arg "install Ansible bundle") sudo cp -a $(quote_bash_arg "$remote_ansible_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/infra/ansible")
run_stage $(quote_bash_arg "remove previous policy-router Docker context") sudo rm -rf $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker/policy-router")
run_stage $(quote_bash_arg "install policy-router Docker context") sudo cp -a $(quote_bash_arg "$remote_policy_router_docker_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker/policy-router")
run_stage $(quote_bash_arg "remove previous policy-gateway Docker context") sudo rm -rf $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker/policy-gateway")
run_stage $(quote_bash_arg "install policy-gateway Docker context") sudo cp -a $(quote_bash_arg "$remote_policy_gateway_docker_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker/policy-gateway")
run_stage $(quote_bash_arg "remove previous softether-vpnclient Docker context") sudo rm -rf $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker/softether-vpnclient")
run_stage $(quote_bash_arg "install softether-vpnclient Docker context") sudo cp -a $(quote_bash_arg "$remote_softether_vpnclient_docker_temp") $(quote_bash_arg "$REMOTE_REPO_DIR/infra/docker/softether-vpnclient")
run_stage $(quote_bash_arg "prepare operator CSV directory") sudo mkdir -p $(quote_bash_arg "$remote_nodes_dir") $(quote_bash_arg "$remote_operator_dir")
run_stage $(quote_bash_arg "install operator nodes.csv") sudo install -o ansible -g ansible -m 600 $(quote_bash_arg "$remote_operator_temp/nodes.csv") $(quote_bash_arg "$REMOTE_NODES_FILE")
run_stage $(quote_bash_arg "install operator state.csv") sudo install -o ansible -g ansible -m 600 $(quote_bash_arg "$remote_operator_temp/state.csv") $(quote_bash_arg "$REMOTE_STATE_FILE")
run_stage $(quote_bash_arg "install operator networks.csv") sudo install -o ansible -g ansible -m 600 $(quote_bash_arg "$remote_operator_temp/networks.csv") $(quote_bash_arg "$remote_networks_file")
run_stage $(quote_bash_arg "refresh ansible known_hosts") bash -lc $(quote_bash_arg "$refresh_known_hosts_command")
if [ -d $(quote_bash_arg "$remote_operator_temp/haproxy") ]; then run_stage $(quote_bash_arg "sync operator haproxy config") sudo bash -lc $(quote_bash_arg "rm -rf $(quote_bash_arg "$remote_operator_dir/haproxy"); cp -a $(quote_bash_arg "$remote_operator_temp/haproxy") $(quote_bash_arg "$remote_operator_dir/haproxy"); chown -R ansible:ansible $(quote_bash_arg "$remote_operator_dir/haproxy")"); fi
if [ -d $(quote_bash_arg "$remote_operator_temp/softether") ]; then run_stage $(quote_bash_arg "sync operator softether config") sudo bash -lc $(quote_bash_arg "rm -rf $(quote_bash_arg "$remote_operator_dir/softether"); cp -a $(quote_bash_arg "$remote_operator_temp/softether") $(quote_bash_arg "$remote_operator_dir/softether"); chown -R ansible:ansible $(quote_bash_arg "$remote_operator_dir/softether")"); fi
if [ -d $(quote_bash_arg "$remote_operator_temp/edge_banlist") ]; then run_stage $(quote_bash_arg "sync operator edge_banlist config") sudo bash -lc $(quote_bash_arg "rm -rf $(quote_bash_arg "$remote_operator_dir/edge_banlist"); cp -a $(quote_bash_arg "$remote_operator_temp/edge_banlist") $(quote_bash_arg "$remote_operator_dir/edge_banlist"); chown -R ansible:ansible $(quote_bash_arg "$remote_operator_dir/edge_banlist")"); fi
if [ -d $(quote_bash_arg "$remote_operator_temp/postgres") ]; then run_stage $(quote_bash_arg "sync operator postgres config") sudo bash -lc $(quote_bash_arg "rm -rf $(quote_bash_arg "$remote_operator_dir/postgres"); cp -a $(quote_bash_arg "$remote_operator_temp/postgres") $(quote_bash_arg "$remote_operator_dir/postgres"); chown -R ansible:ansible $(quote_bash_arg "$remote_operator_dir/postgres")"); fi
if [ -d $(quote_bash_arg "$remote_operator_temp/platform_networks") ]; then run_stage $(quote_bash_arg "sync operator platform_networks config") sudo bash -lc $(quote_bash_arg "rm -rf $(quote_bash_arg "$remote_operator_dir/platform_networks"); cp -a $(quote_bash_arg "$remote_operator_temp/platform_networks") $(quote_bash_arg "$remote_operator_dir/platform_networks"); chown -R ansible:ansible $(quote_bash_arg "$remote_operator_dir/platform_networks")"); fi
if [ -d $(quote_bash_arg "$remote_operator_temp/host_resources") ]; then run_stage $(quote_bash_arg "sync operator host_resources config") sudo bash -lc $(quote_bash_arg "rm -rf $(quote_bash_arg "$remote_operator_dir/host_resources"); cp -a $(quote_bash_arg "$remote_operator_temp/host_resources") $(quote_bash_arg "$remote_operator_dir/host_resources"); chown -R ansible:ansible $(quote_bash_arg "$remote_operator_dir/host_resources")"); fi
if [ -d $(quote_bash_arg "$remote_operator_temp/platform_router") ]; then run_stage $(quote_bash_arg "sync operator platform_router config") sudo bash -lc $(quote_bash_arg "rm -rf $(quote_bash_arg "$remote_operator_dir/platform_router"); cp -a $(quote_bash_arg "$remote_operator_temp/platform_router") $(quote_bash_arg "$remote_operator_dir/platform_router"); chown -R ansible:ansible $(quote_bash_arg "$remote_operator_dir/platform_router")"); fi
if [ -d $(quote_bash_arg "$remote_operator_temp/site_runtime") ]; then run_stage $(quote_bash_arg "sync operator site_runtime config") sudo bash -lc $(quote_bash_arg "rm -rf $(quote_bash_arg "$remote_operator_dir/site_runtime"); cp -a $(quote_bash_arg "$remote_operator_temp/site_runtime") $(quote_bash_arg "$remote_operator_dir/site_runtime"); chown -R ansible:ansible $(quote_bash_arg "$remote_operator_dir/site_runtime"); if [ -d $(quote_bash_arg "$remote_operator_dir/site_runtime/secrets") ]; then find $(quote_bash_arg "$remote_operator_dir/site_runtime/secrets") -type f -exec chmod 600 {} +; fi"); fi
run_stage $(quote_bash_arg "regenerate Ansible inventory") sudo bash $(quote_bash_arg "$REMOTE_REPO_DIR/tools/bootstrap/create_inventory.sh") --nodes-file $(quote_bash_arg "$REMOTE_NODES_FILE") --state-file $(quote_bash_arg "$REMOTE_STATE_FILE") --output $(quote_bash_arg "$REMOTE_INVENTORY")
log_stage $(quote_bash_arg "running service command: $remote_service_display")
sudo bash -lc $(quote_bash_arg "$service_command")
rc=\$?
log_stage "service command finished with rc=\$rc"
printf '%s\n' "\$rc" > $(quote_bash_arg "$remote_job_exit_code")
touch $(quote_bash_arg "$remote_job_done")
exit "\$rc"
EOF
fi

if [ "$DETACHED_REMOTE_JOB" = "true" ]; then
    echo "Creating remote temporary bundle and durable job directories..."
    create_remote_job_dirs="set -e; mkdir -p $(quote_bash_arg "$remote_bundle_dir"); sudo mkdir -p $(quote_bash_arg "$remote_job_log_dir") $(quote_bash_arg "$remote_job_dir"); sudo chown \"\$(id -u):\$(id -g)\" $(quote_bash_arg "$remote_job_log_dir") $(quote_bash_arg "$remote_job_dir"); chmod 750 $(quote_bash_arg "$remote_job_dir")"
    invoke_retry_transport "remote service bundle and job directory creation" ssh "${ssh_common_args[@]}" "$remote" "$create_remote_job_dirs"
else
    echo "Creating remote temporary bundle directory..."
    invoke_retry_transport "remote service bundle directory creation" ssh "${ssh_common_args[@]}" "$remote" "mkdir -p $(quote_bash_arg "$remote_bundle_dir")"
fi

echo "Uploading service bundle archive..."
scp "${scp_common_args[@]}" "$archive_path" "$remote:$remote_bundle_archive"

if [ "$DETACHED_REMOTE_JOB" = "true" ]; then
    echo "Uploading remote job runner..."
    scp "${scp_common_args[@]}" "$run_script_path" "$remote:$remote_job_script"
fi

extract_command="set -e; rm -rf $(quote_bash_arg "$remote_bundle_dir"); mkdir -p $(quote_bash_arg "$remote_bundle_dir"); tar -xzf $(quote_bash_arg "$remote_bundle_archive") -C $(quote_bash_arg "$remote_bundle_dir"); test -f $(quote_bash_arg "$remote_service_runner_temp"); test -f $(quote_bash_arg "$remote_create_inventory_temp"); test -d $(quote_bash_arg "$remote_egress_policy_tools_temp"); test -d $(quote_bash_arg "$remote_site_runtime_tools_temp"); test -f $(quote_bash_arg "$remote_services_registry_temp"); test -d $(quote_bash_arg "$remote_ansible_temp"); test -d $(quote_bash_arg "$remote_policy_router_docker_temp"); test -d $(quote_bash_arg "$remote_policy_gateway_docker_temp"); test -d $(quote_bash_arg "$remote_softether_vpnclient_docker_temp"); test -f $(quote_bash_arg "$remote_operator_temp/nodes.csv"); test -f $(quote_bash_arg "$remote_operator_temp/state.csv"); test -f $(quote_bash_arg "$remote_operator_temp/networks.csv")"
echo "Extracting service bundle on orchestration node..."
invoke_retry_transport "remote service bundle extract" ssh "${ssh_common_args[@]}" "$remote" "$extract_command"

if [ -n "$site_runtime_image_archive" ]; then
    if [ "$ACTION" = "stage-support-images" ]; then
        remote_prepared_archive="$remote_site_runtime_support_archive"
        remote_prepared_manifest="$remote_site_runtime_support_manifest"
    else
        remote_prepared_archive="$remote_site_runtime_image_archive"
        remote_prepared_manifest="$remote_site_runtime_image_manifest"
    fi
    echo "Uploading verified image archive to orchestration node..."
    scp "${scp_common_args[@]}" "$site_runtime_image_archive" "$remote:$remote_prepared_archive"
    scp "${scp_common_args[@]}" "$site_runtime_image_manifest" "$remote:$remote_prepared_manifest"
    image_permissions_command="chmod 0644 $(quote_bash_arg "$remote_prepared_archive") $(quote_bash_arg "$remote_prepared_manifest")"
    invoke_retry_transport "site_runtime image permissions" ssh "${ssh_common_args[@]}" "$remote" "$image_permissions_command"
fi

if [ "$DETACHED_REMOTE_JOB" = "true" ]; then
    start_job_command="set -e; chmod 700 $(quote_bash_arg "$remote_job_script"); rm -f $(quote_bash_arg "$remote_job_log") $(quote_bash_arg "$remote_job_exit_code") $(quote_bash_arg "$remote_job_done") $(quote_bash_arg "$remote_job_pid"); nohup bash $(quote_bash_arg "$remote_job_script") </dev/null >/dev/null 2>&1 & echo \$! > $(quote_bash_arg "$remote_job_pid")"
    echo "Starting remote service job..."
    invoke_retry_transport "remote service job start" ssh "${ssh_common_args[@]}" "$remote" "$start_job_command"

    echo "Following remote service job log..."
    wait_remote_service_job
    remote_job_completed_successfully="true"
else
    echo "Installing service bundle and running remote service command..."
    ssh "${ssh_common_args[@]}" "$remote" "$install_and_run_command" || fail "remote service command failed with exit code $?"
fi

if [ "$DETACHED_REMOTE_JOB" = "true" ]; then
    echo "Cleaning remote temporary service bundle and completed job state; preserving rotated job log: $remote_job_log"
else
    echo "Cleaning remote temporary service bundle..."
fi
