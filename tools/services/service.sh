#!/usr/bin/env bash

set -euo pipefail

SERVICE="${1:-}"
ACTION="${2:-}"
NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
INVENTORY="inventory.ini"
PLAYBOOK=""
LIMIT=""
INSTANCE=""
IMAGE_REF=""
SNAPSHOT_ID=""
REHEARSAL_ID=""
SERVICES_REGISTRY="./services.yml"
SITE_RUNTIME_INSTANCES="./operator/site_runtime/instances.yml"
SITE_RUNTIME_RESOLVER="./tools/site_runtime/resolve.py"
IMAGE_ARCHIVE=""
IMAGE_MANIFEST=""
SUPPORT_ARCHIVE=""
SUPPORT_MANIFEST=""
POLICY_ROUTER_IMAGE_REF=""
BUILD_POLICY_ROUTER_IMAGE="false"
REINIT_STANDBY="false"
PLATFORM_ROUTER_SOFTETHER_DEBUG="false"
CHECK="false"
SITE_RUNTIME_LOCK_HELD="false"
CONFIRM_PURGE="false"
EXPECTED_HEADER="current_alias,endpoint,expected_ip,connection,ssh_port,root_password"
EXPECTED_STATE_HEADER="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
EXPECTED_NETWORKS_HEADER="alias,policy_subnet,edge_ip,cascade_ip,cascade_router_ip,policy_gateway_ip"
NETWORKS_FILE="$(dirname "$STATE_FILE")/networks.csv"
DEFAULT_ANSIBLE_SSH_COMMON_ARGS="-o BatchMode=yes -o KbdInteractiveAuthentication=no -o PasswordAuthentication=no -o PreferredAuthentications=publickey -o RequestTTY=no"
if [ -n "${ANSIBLE_SSH_COMMON_ARGS:-}" ]; then
    export ANSIBLE_SSH_COMMON_ARGS="$ANSIBLE_SSH_COMMON_ARGS $DEFAULT_ANSIBLE_SSH_COMMON_ARGS"
else
    export ANSIBLE_SSH_COMMON_ARGS="$DEFAULT_ANSIBLE_SSH_COMMON_ARGS"
fi

usage() {
    cat <<'USAGE'
Usage:
  bash tools/services/service.sh edge_haproxy plan [options]
  bash tools/services/service.sh edge_haproxy apply [options]
  bash tools/services/service.sh edge_haproxy absent [options]
  bash tools/services/service.sh edge_haproxy purge --confirm-purge [options]
  bash tools/services/service.sh vpn_edge plan [options]
  bash tools/services/service.sh vpn_edge apply [options]
  bash tools/services/service.sh vpn_edge absent [options]
  bash tools/services/service.sh vpn_edge purge --confirm-purge [options]
  bash tools/services/service.sh vpn_edge reseed --limit ALIAS [options]
  bash tools/services/service.sh site_runtime probe --limit vps3 [options]
  bash tools/services/service.sh site_runtime plan --instance NAME --image-ref REF --limit ALIAS
  bash tools/services/service.sh site_runtime stage-image --instance NAME --image-ref REF --limit ALIAS [internal archive options]
  bash tools/services/service.sh site_runtime stage-support-images --limit ALIAS [internal archive options]
  bash tools/services/service.sh site_runtime apply --instance NAME --image-ref REF --limit ALIAS [--check]
  bash tools/services/service.sh site_runtime publication-check --instance NAME --limit ALIAS --check
  bash tools/services/service.sh site_runtime publication-prepare --instance NAME --limit ALIAS --check
  bash tools/services/service.sh site_runtime backup-init --instance NAME --limit ALIAS [--check]
  bash tools/services/service.sh site_runtime backup-schedule --instance NAME --limit ALIAS [--check]
  bash tools/services/service.sh site_runtime backup --instance NAME --limit ALIAS [--check]
  bash tools/services/service.sh site_runtime restore-rehearsal --instance NAME --snapshot-id ID --limit ALIAS [--check]
  bash tools/services/service.sh site_runtime restore-cleanup --instance NAME --rehearsal-id ID --limit ALIAS [--check]
  bash tools/services/service.sh vpn_cascade plan [options]
  bash tools/services/service.sh vpn_cascade apply [options]
  bash tools/services/service.sh vpn_cascade absent [options]
  bash tools/services/service.sh vpn_cascade purge --confirm-purge [options]
  bash tools/services/service.sh policy_gateway plan [options]
  bash tools/services/service.sh policy_gateway apply [options]
  bash tools/services/service.sh policy_gateway absent [options]
  bash tools/services/service.sh policy_gateway purge --confirm-purge [options]
  bash tools/services/service.sh edge_candidate_collector plan [options]
  bash tools/services/service.sh edge_candidate_collector apply [options]
  bash tools/services/service.sh edge_candidate_collector absent [options]
  bash tools/services/service.sh edge_candidate_collector purge --confirm-purge [options]
  bash tools/services/service.sh edge_banlist plan [options]
  bash tools/services/service.sh edge_banlist apply [options]
  bash tools/services/service.sh edge_banlist absent [options]
  bash tools/services/service.sh edge_banlist purge --confirm-purge [options]
  bash tools/services/service.sh postgres_runtime plan [options]
  bash tools/services/service.sh postgres_runtime apply [options]
  bash tools/services/service.sh postgres_runtime absent [options]
  bash tools/services/service.sh postgres_runtime purge --confirm-purge [options]
  bash tools/services/service.sh softether_l3_vps plan [options]
  bash tools/services/service.sh softether_l3_vps apply [options]
  bash tools/services/service.sh softether_l3_vps absent [options]
  bash tools/services/service.sh softether_l3_vps purge --confirm-purge [options]
  bash tools/services/service.sh platform_networks plan [options]
  bash tools/services/service.sh platform_networks apply [options]
  bash tools/services/service.sh platform_networks absent [options]
  bash tools/services/service.sh platform_router plan [options]
  bash tools/services/service.sh platform_router apply [options]
  bash tools/services/service.sh platform_router absent [options]
  bash tools/services/service.sh platform_router purge --confirm-purge [options]

Options:
  --nodes-file PATH      Operator nodes.csv. Default: ./operator/nodes.csv
  --state-file PATH      Operator state.csv. Default: ./operator/state.csv
  --inventory PATH       Generated Ansible inventory. Default: inventory.ini
  --playbook PATH        Override service playbook.
  --limit VALUE          Ansible --limit. Default: service ansible_group.
  --instance NAME        site_runtime instance name.
  --image-ref REF        site_runtime immutable repository@sha256 reference.
  --snapshot-id ID       Restic snapshot для site_runtime restore-rehearsal.
  --rehearsal-id ID      Точный failed rehearsal для site_runtime restore-cleanup.
  --policy-router-image-ref REF
                        vpn_cascade only: pin policy-router image and skip cache/build.
  --build-policy-router-image
                        vpn_cascade only: force rebuild instead of reusing a matching local image.
  --reinit-standby      postgres_runtime only: destructively reinitialize a target standby volume from primary.
  --platform-router-softether-debug
                        platform_router only: show SoftEther server configure task output for diagnostics.
  --check                Pass --check to ansible-playbook.
  --confirm-purge        Required for purge.
  -h, --help             Show help.
USAGE
}

fail() {
    echo "[ERROR] $1" >&2
    exit 1
}

split_aliases_to_lines() {
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

alias_in_list() {
    local alias="$1"
    local aliases="$2"
    local item
    while IFS= read -r item; do
        [ "$item" = "$alias" ] && return 0
    done < <(split_aliases_to_lines "$aliases")
    return 1
}

split_limit_to_lines() {
    local limit="$1"
    limit="${limit//,/:}"
    limit="${limit//+/:}"
    local old_ifs="$IFS"
    local alias_item
    IFS=:
    for alias_item in $limit; do
        IFS="$old_ifs"
        if [ -n "$alias_item" ]; then
            printf '%s\n' "$alias_item"
        fi
        IFS=:
    done
    IFS="$old_ifs"
}

ansible_limit_pattern() {
    local limit="$1"
    local first="true"
    local alias_item
    while IFS= read -r alias_item; do
        [ -n "$alias_item" ] || continue
        if [ "$first" = "true" ]; then
            printf '%s' "$alias_item"
            first="false"
        else
            printf ':%s' "$alias_item"
        fi
    done < <(split_limit_to_lines "$limit")
}

limit_matches_aliases() {
    local limit="$1"
    local aliases="$2"
    local alias_item
    while IFS= read -r alias_item; do
        [ -n "$alias_item" ] || continue
        alias_in_list "$alias_item" "$aliases" || return 1
    done < <(split_limit_to_lines "$limit")
    return 0
}

append_aliases_unique() {
    local current="$1"
    local aliases="$2"
    local alias_item
    while IFS= read -r alias_item; do
        [ -n "$alias_item" ] || continue
        if ! alias_in_list "$alias_item" "$current"; then
            if [ -n "$current" ]; then
                current="$current+$alias_item"
            else
                current="$alias_item"
            fi
        fi
    done < <(split_aliases_to_lines "$aliases")
    printf '%s\n' "$current"
}

limit_aliases_in_row() {
    local limit="$1"
    local aliases="$2"
    local selected=""
    local alias_item
    while IFS= read -r alias_item; do
        [ -n "$alias_item" ] || continue
        if alias_in_list "$alias_item" "$aliases"; then
            if [ -n "$selected" ]; then
                selected="$selected+$alias_item"
            else
                selected="$alias_item"
            fi
        fi
    done < <(split_limit_to_lines "$limit")
    printf '%s\n' "$selected"
}

limit_display_for_error() {
    local limit="$1"
    if [ -n "$limit" ]; then
        printf '%s\n' "$limit"
    else
        printf '<none>\n'
    fi
}

service_playbook() {
    case "$1" in
        edge_haproxy) echo "infra/ansible/edge_haproxy.yml" ;;
        vpn_edge) echo "infra/ansible/vpn.yml" ;;
        vpn_cascade) echo "infra/ansible/vpn_cascade.yml" ;;
        policy_gateway) echo "infra/ansible/policy_gateway.yml" ;;
        edge_candidate_collector) echo "infra/ansible/edge_candidate_collector.yml" ;;
        edge_banlist) echo "infra/ansible/edge_banlist.yml" ;;
        postgres_runtime) echo "infra/ansible/postgres_runtime.yml" ;;
        softether_l3_vps) echo "infra/ansible/softether_l3_vps.yml" ;;
        platform_networks) echo "infra/ansible/platform_networks.yml" ;;
        host_resources) echo "infra/ansible/host_resources.yml" ;;
        platform_router) echo "infra/ansible/platform_router.yml" ;;
        site_runtime)
            if [ "$ACTION" = "probe" ]; then
                echo "infra/ansible/site_runtime_network_probe.yml"
            elif [ "$ACTION" = "stage-image" ]; then
                echo "infra/ansible/site_runtime_image_stage.yml"
            elif [ "$ACTION" = "stage-support-images" ]; then
                echo "infra/ansible/site_runtime_support_images_stage.yml"
            elif [ "$ACTION" = "publication-check" ] || [ "$ACTION" = "publication-prepare" ]; then
                echo "infra/ansible/site_runtime_publication_check.yml"
            elif [ "$ACTION" = "backup-init" ] || [ "$ACTION" = "backup-schedule" ] || [ "$ACTION" = "backup" ] || [ "$ACTION" = "restore-rehearsal" ] || [ "$ACTION" = "restore-cleanup" ]; then
                echo "infra/ansible/site_runtime_backup.yml"
            else
                echo "infra/ansible/site_runtime_apply.yml"
            fi
            ;;
        *) return 1 ;;
    esac
}

service_extra_vars() {
    local service="$1"
    local state="$2"
    local purge="$3"
    local reseed="${4:-false}"
    local policy_router_image_ref="${5:-}"
    local build_policy_router_image="${6:-false}"
    case "$service" in
        edge_haproxy)
            printf '%s\n' "-e" "edge_haproxy_state=$state" "-e" "edge_haproxy_purge_data=$purge"
            ;;
        vpn_edge)
            printf '%s\n' "-e" "vpn_state=$state" "-e" "vpn_purge_data=$purge" "-e" "vpn_reseed_config=$reseed"
            ;;
        vpn_cascade)
            printf '%s\n' "-e" "vpn_cascade_state=$state" "-e" "vpn_cascade_purge_data=$purge" "-e" "vpn_cascade_reseed_config=$reseed"
            if [ -n "$policy_router_image_ref" ]; then
                printf '%s\n' "-e" "vpn_cascade_policy_router_image=$policy_router_image_ref" "-e" "vpn_cascade_policy_router_image_explicit=true"
            fi
            if [ "$build_policy_router_image" = "true" ]; then
                printf '%s\n' "-e" "vpn_cascade_build_policy_router_image=true" "-e" "vpn_cascade_policy_router_image_mode=always"
            fi
            ;;
        policy_gateway)
            printf '%s\n' "-e" "policy_gateway_state=$state" "-e" "policy_gateway_purge_data=$purge"
            ;;
        edge_candidate_collector)
            printf '%s\n' "-e" "edge_candidate_collector_state=$state" "-e" "edge_candidate_collector_purge_data=$purge"
            ;;
        edge_banlist)
            printf '%s\n' "-e" "edge_banlist_state=$state" "-e" "edge_banlist_purge_data=$purge"
            ;;
        postgres_runtime)
            printf '%s\n' "-e" "postgres_runtime_state=$state" "-e" "postgres_runtime_purge_data=$purge" "-e" "postgres_runtime_reinit_standby=$REINIT_STANDBY"
            ;;
        softether_l3_vps)
            printf '%s\n' "-e" "softether_l3_vps_state=$state" "-e" "softether_l3_vps_purge_data=$purge"
            ;;
        platform_networks)
            printf '%s\n' "-e" "platform_networks_state=$state"
            ;;
        host_resources)
            printf '%s\n' "-e" "host_resources_state=$state"
            ;;
        platform_router)
            printf '%s\n' "-e" "platform_router_state=$state" "-e" "platform_router_purge_data=$purge"
            if [ "$PLATFORM_ROUTER_SOFTETHER_DEBUG" = "true" ]; then
                printf '%s\n' "-e" "platform_router_softether_debug_no_log=false"
            fi
            ;;
        site_runtime)
            if [ "$ACTION" = "probe" ]; then
                printf '%s\n' "-e" "site_runtime_network_probe_state=present"
            elif [ "$ACTION" = "stage-support-images" ]; then
                printf '%s\n' \
                    "-e" "site_runtime_support_state=present" \
                    "-e" "site_runtime_support_archive=$SUPPORT_ARCHIVE" \
                    "-e" "site_runtime_support_manifest=$SUPPORT_MANIFEST"
            elif [ "$ACTION" = "apply" ]; then
                printf '%s\n' \
                    "-e" "site_runtime_apply_state=present" \
                    "-e" "site_runtime_instance=$INSTANCE" \
                    "-e" "site_runtime_image_ref=$IMAGE_REF" \
                    "-e" "site_runtime_services_registry=$SERVICES_REGISTRY" \
                    "-e" "site_runtime_instances_file=$SITE_RUNTIME_INSTANCES" \
                    "-e" "site_runtime_nodes_file=$NODES_FILE" \
                    "-e" "site_runtime_state_file=$STATE_FILE" \
                    "-e" "site_runtime_resolver=$SITE_RUNTIME_RESOLVER" \
                    "-e" "site_runtime_env_resolver=$(dirname "$SITE_RUNTIME_RESOLVER")/resolve_env.py"
            elif [ "$ACTION" = "backup-init" ] || [ "$ACTION" = "backup-schedule" ] || [ "$ACTION" = "backup" ] || [ "$ACTION" = "restore-rehearsal" ] || [ "$ACTION" = "restore-cleanup" ]; then
                printf '%s\n' \
                    "-e" "site_runtime_backup_action=$ACTION" \
                    "-e" "site_runtime_instance=$INSTANCE" \
                    "-e" "site_runtime_snapshot_id=$SNAPSHOT_ID" \
                    "-e" "site_runtime_rehearsal_id=$REHEARSAL_ID" \
                    "-e" "site_runtime_backup_check=$CHECK" \
                    "-e" "site_runtime_lock_held=$SITE_RUNTIME_LOCK_HELD" \
                    "-e" "site_runtime_services_registry=$SERVICES_REGISTRY" \
                    "-e" "site_runtime_instances_file=$SITE_RUNTIME_INSTANCES" \
                    "-e" "site_runtime_nodes_file=$NODES_FILE" \
                    "-e" "site_runtime_state_file=$STATE_FILE" \
                    "-e" "site_runtime_backup_resolver=$(dirname "$SITE_RUNTIME_RESOLVER")/resolve_backup.py" \
                    "-e" "site_runtime_backup_runner=$(dirname "$SITE_RUNTIME_RESOLVER")/backup_runtime.py"
            elif [ "$ACTION" = "publication-check" ] || [ "$ACTION" = "publication-prepare" ]; then
                printf '%s\n' \
                    "-e" "site_runtime_publication_action=$ACTION" \
                    "-e" "site_runtime_instance=$INSTANCE" \
                    "-e" "site_runtime_services_registry=$SERVICES_REGISTRY" \
                    "-e" "site_runtime_instances_file=$SITE_RUNTIME_INSTANCES" \
                    "-e" "site_runtime_state_file=$STATE_FILE" \
                    "-e" "site_runtime_publication_resolver=$(dirname "$SITE_RUNTIME_RESOLVER")/resolve_publication.py"
            else
                printf '%s\n' \
                    "-e" "site_runtime_stage_state=present" \
                    "-e" "site_runtime_instance=$INSTANCE" \
                    "-e" "site_runtime_image_ref=$IMAGE_REF" \
                    "-e" "site_runtime_image_archive=$IMAGE_ARCHIVE" \
                    "-e" "site_runtime_image_manifest=$IMAGE_MANIFEST" \
                    "-e" "site_runtime_services_registry=$SERVICES_REGISTRY" \
                    "-e" "site_runtime_instances_file=$SITE_RUNTIME_INSTANCES" \
                    "-e" "site_runtime_nodes_file=$NODES_FILE" \
                    "-e" "site_runtime_state_file=$STATE_FILE" \
                    "-e" "site_runtime_resolver=$SITE_RUNTIME_RESOLVER"
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

run_ansible_playbook() {
    if [ "$(id -u)" -eq 0 ]; then
        sudo -u ansible env LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONIOENCODING=utf-8 ANSIBLE_SSH_COMMON_ARGS="$ANSIBLE_SSH_COMMON_ARGS" ansible-playbook "$@"
    else
        env LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONIOENCODING=utf-8 ansible-playbook "$@"
    fi
}

if [ "$SERVICE" = "-h" ] || [ "$SERVICE" = "--help" ]; then
    usage
    exit 0
fi

if [ "$SERVICE" = "vpn" ]; then
    fail "Unsupported service 'vpn'. Use canonical service name: vpn_edge"
fi
case "$SERVICE" in
    edge_haproxy|vpn_edge|vpn_cascade|policy_gateway|edge_candidate_collector|edge_banlist|postgres_runtime|softether_l3_vps|platform_networks|host_resources|platform_router|site_runtime) ;;
    *) fail "Unsupported service '$SERVICE'. Supported now: edge_haproxy, vpn_edge, vpn_cascade, policy_gateway, edge_candidate_collector, edge_banlist, postgres_runtime, softether_l3_vps, platform_networks, host_resources, platform_router, site_runtime." ;;
esac
case "$ACTION" in
    plan|apply|absent|purge|reseed|probe|stage-image|stage-support-images|publication-check|publication-prepare|backup-init|backup-schedule|backup|restore-rehearsal|restore-cleanup) ;;
    *) usage; fail "Action must be one of: plan, apply, absent, purge, reseed, probe, stage-image, stage-support-images, publication-check, publication-prepare, backup-init, backup-schedule, backup, restore-rehearsal, restore-cleanup" ;;
esac
shift 2

if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" != "plan" ] && [ "$ACTION" != "probe" ] && [ "$ACTION" != "stage-image" ] && [ "$ACTION" != "stage-support-images" ] && [ "$ACTION" != "publication-check" ] && [ "$ACTION" != "publication-prepare" ] && [ "$ACTION" != "apply" ] && [ "$ACTION" != "backup-init" ] && [ "$ACTION" != "backup-schedule" ] && [ "$ACTION" != "backup" ] && [ "$ACTION" != "restore-rehearsal" ] && [ "$ACTION" != "restore-cleanup" ]; then
    fail "site_runtime action is not supported"
fi
if [ "$SERVICE" != "site_runtime" ] && [ "$ACTION" = "probe" ]; then
    fail "probe is supported only for site_runtime"
fi

if [ "$SERVICE" = "host_resources" ] && [ "$ACTION" != "plan" ] && [ "$ACTION" != "apply" ]; then
    fail "host_resources v1 supports only plan and apply; absent/purge/reseed are intentionally disabled"
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --nodes-file)
            NODES_FILE="${2:-}"
            shift 2
            ;;
        --state-file)
            STATE_FILE="${2:-}"
            NETWORKS_FILE="$(dirname "$STATE_FILE")/networks.csv"
            shift 2
            ;;
        --inventory)
            INVENTORY="${2:-}"
            shift 2
            ;;
        --playbook)
            PLAYBOOK="${2:-}"
            shift 2
            ;;
        --limit)
            LIMIT="${2:-}"
            shift 2
            ;;
        --instance)
            INSTANCE="${2:-}"
            shift 2
            ;;
        --image-ref)
            IMAGE_REF="${2:-}"
            shift 2
            ;;
        --snapshot-id)
            SNAPSHOT_ID="${2:-}"
            shift 2
            ;;
        --rehearsal-id)
            REHEARSAL_ID="${2:-}"
            shift 2
            ;;
        --services-registry)
            SERVICES_REGISTRY="${2:-}"
            shift 2
            ;;
        --site-runtime-instances)
            SITE_RUNTIME_INSTANCES="${2:-}"
            shift 2
            ;;
        --site-runtime-resolver)
            SITE_RUNTIME_RESOLVER="${2:-}"
            shift 2
            ;;
        --image-archive)
            IMAGE_ARCHIVE="${2:-}"
            shift 2
            ;;
        --image-manifest)
            IMAGE_MANIFEST="${2:-}"
            shift 2
            ;;
        --support-archive)
            SUPPORT_ARCHIVE="${2:-}"
            shift 2
            ;;
        --support-manifest)
            SUPPORT_MANIFEST="${2:-}"
            shift 2
            ;;
        --policy-router-image-ref)
            POLICY_ROUTER_IMAGE_REF="${2:-}"
            shift 2
            ;;
        --build-policy-router-image)
            BUILD_POLICY_ROUTER_IMAGE="true"
            shift
            ;;
        --reinit-standby)
            REINIT_STANDBY="true"
            shift
            ;;
        --platform-router-softether-debug)
            PLATFORM_ROUTER_SOFTETHER_DEBUG="true"
            shift
            ;;
        --check)
            CHECK="true"
            shift
            ;;
        --confirm-purge)
            CONFIRM_PURGE="true"
            shift
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

if [ "$SERVICE" = "site_runtime" ] && [ -z "$LIMIT" ]; then
    fail "site_runtime requires exactly one --limit alias"
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "probe" ] && [ "$LIMIT" != "vps3" ]; then
    fail "site_runtime probe requires exactly --limit vps3"
fi
if [ "$SERVICE" = "site_runtime" ] && { [ "$ACTION" = "plan" ] || [ "$ACTION" = "stage-image" ] || [ "$ACTION" = "apply" ]; } && { [ -z "$INSTANCE" ] || [ -z "$IMAGE_REF" ]; }; then
    fail "site_runtime $ACTION requires --instance and --image-ref"
fi
if [ "$SERVICE" = "site_runtime" ] && { [ "$ACTION" = "backup-init" ] || [ "$ACTION" = "backup-schedule" ] || [ "$ACTION" = "backup" ] || [ "$ACTION" = "restore-rehearsal" ] || [ "$ACTION" = "restore-cleanup" ]; } && [ -z "$INSTANCE" ]; then
    fail "site_runtime $ACTION requires --instance"
fi
if [ "$SERVICE" = "site_runtime" ] && { [ "$ACTION" = "publication-check" ] || [ "$ACTION" = "publication-prepare" ]; }; then
    [ -n "$INSTANCE" ] || fail "site_runtime $ACTION requires --instance"
    [ "$CHECK" = "true" ] || fail "site_runtime $ACTION requires --check"
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "restore-rehearsal" ] && [ -z "$SNAPSHOT_ID" ]; then
    fail "site_runtime restore-rehearsal requires --snapshot-id"
fi
if [ -n "$SNAPSHOT_ID" ] && { [ "$SERVICE" != "site_runtime" ] || [ "$ACTION" != "restore-rehearsal" ]; }; then
    fail "--snapshot-id is supported only for site_runtime restore-rehearsal"
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "restore-cleanup" ] && [ -z "$REHEARSAL_ID" ]; then
    fail "site_runtime restore-cleanup requires --rehearsal-id"
fi
if [ -n "$REHEARSAL_ID" ] && { [ "$SERVICE" != "site_runtime" ] || [ "$ACTION" != "restore-cleanup" ]; }; then
    fail "--rehearsal-id is supported only for site_runtime restore-cleanup"
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "stage-support-images" ] && { [ -z "$SUPPORT_ARCHIVE" ] || [ -z "$SUPPORT_MANIFEST" ]; }; then
    fail "site_runtime stage-support-images requires internal --support-archive and --support-manifest inputs"
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "stage-image" ] && { [ -z "$IMAGE_ARCHIVE" ] || [ -z "$IMAGE_MANIFEST" ]; }; then
    fail "site_runtime stage-image requires internal --image-archive and --image-manifest inputs"
fi

if [ -n "$POLICY_ROUTER_IMAGE_REF" ] && [ "$SERVICE" != "vpn_cascade" ]; then
    fail "--policy-router-image-ref is supported only for service vpn_cascade"
fi
if [ "$BUILD_POLICY_ROUTER_IMAGE" = "true" ] && [ "$SERVICE" != "vpn_cascade" ]; then
    fail "--build-policy-router-image is supported only for service vpn_cascade"
fi
if [ "$REINIT_STANDBY" = "true" ] && [ "$SERVICE" != "postgres_runtime" ]; then
    fail "--reinit-standby is supported only for service postgres_runtime"
fi
if [ "$REINIT_STANDBY" = "true" ] && [ "$ACTION" != "apply" ]; then
    fail "--reinit-standby requires action apply"
fi
if [ "$REINIT_STANDBY" = "true" ] && [ -z "$LIMIT" ]; then
    fail "--reinit-standby requires --limit for the intended standby alias"
fi
if [ "$PLATFORM_ROUTER_SOFTETHER_DEBUG" = "true" ] && [ "$SERVICE" != "platform_router" ]; then
    fail "--platform-router-softether-debug is supported only for service platform_router"
fi
if [ "$BUILD_POLICY_ROUTER_IMAGE" = "true" ] && [ -n "$POLICY_ROUTER_IMAGE_REF" ]; then
    fail "--build-policy-router-image and --policy-router-image-ref are mutually exclusive"
fi
[ -f "$NODES_FILE" ] || fail "nodes file not found: $NODES_FILE"
[ -f "$STATE_FILE" ] || fail "state file not found: $STATE_FILE"
first_line="$(head -n 1 "$NODES_FILE" | tr -d '\r')"
[ "$first_line" = "$EXPECTED_HEADER" ] || fail "nodes.csv header must be exactly: $EXPECTED_HEADER"
state_first_line="$(head -n 1 "$STATE_FILE" | tr -d '\r')"
[ "$state_first_line" = "$EXPECTED_STATE_HEADER" ] || fail "state.csv header must be exactly: $EXPECTED_STATE_HEADER"
if [ "$SERVICE" = "vpn_edge" ] || [ "$SERVICE" = "vpn_cascade" ] || [ "$SERVICE" = "policy_gateway" ] || [ "$SERVICE" = "softether_l3_vps" ]; then
    [ -f "$NETWORKS_FILE" ] || fail "networks.csv not found next to state.csv: $NETWORKS_FILE. Run sync_to_orchestration before $SERVICE $ACTION."
    networks_first_line="$(head -n 1 "$NETWORKS_FILE" | tr -d '\r')"
    [ "$networks_first_line" = "$EXPECTED_NETWORKS_HEADER" ] || fail "networks.csv header must be exactly: $EXPECTED_NETWORKS_HEADER. Run sync_to_orchestration before $SERVICE $ACTION."
fi

service_found="false"
service_group=""
service_active_aliases=""
service_candidate_aliases=""
service_old_aliases=""
service_row_state=""
service_match_count=0
service_total_count=0
service_plan_rows=()
state_lookup_service="$SERVICE"
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "probe" ]; then
    state_lookup_service="platform_router"
fi
while IFS=, read -r kind name ansible_group active_aliases candidate_aliases old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    ansible_group="${ansible_group//$'\r'/}"
    active_aliases="${active_aliases//$'\r'/}"
    candidate_aliases="${candidate_aliases//$'\r'/}"
    old_aliases="${old_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ "$kind" = "service" ] && [ "$name" = "$state_lookup_service" ] || continue
    [ -z "$extra" ] || fail "state.csv $SERVICE row has too many columns"
    service_total_count=$((service_total_count + 1))
    service_plan_rows+=("$ansible_group|$active_aliases|$candidate_aliases|$old_aliases|$row_state")

    if [ -n "$LIMIT" ]; then
        target_aliases="$active_aliases"
        if { [ "$SERVICE" = "postgres_runtime" ] || [ "$SERVICE" = "softether_l3_vps" ] || [ "$SERVICE" = "platform_networks" ] || [ "$SERVICE" = "platform_router" ] || [ "$SERVICE" = "site_runtime" ]; } && [ -n "$candidate_aliases" ]; then
            target_aliases="$(append_aliases_unique "$target_aliases" "$candidate_aliases")"
        fi
        selected_aliases="$(limit_aliases_in_row "$LIMIT" "$target_aliases")"
        [ -n "$selected_aliases" ] || continue

        while IFS= read -r selected_alias; do
            [ -n "$selected_alias" ] || continue
            if alias_in_list "$selected_alias" "$service_active_aliases"; then
                fail "state.csv has multiple $SERVICE rows covering alias $selected_alias for --limit $(limit_display_for_error "$LIMIT")"
            fi
        done < <(split_aliases_to_lines "$selected_aliases")

        if [ -n "$service_group" ] && [ "$service_group" != "$ansible_group" ]; then
            fail "state.csv has multiple ansible groups for $SERVICE matching --limit $(limit_display_for_error "$LIMIT")"
        fi
        if [ -n "$service_row_state" ] && [ "$service_row_state" != "$row_state" ]; then
            fail "state.csv has mixed states for $SERVICE matching --limit $(limit_display_for_error "$LIMIT")"
        fi

        service_found="true"
        service_match_count=$((service_match_count + 1))
        service_group="$ansible_group"
        service_active_aliases="$(append_aliases_unique "$service_active_aliases" "$selected_aliases")"
        service_candidate_aliases="$(append_aliases_unique "$service_candidate_aliases" "$candidate_aliases")"
        service_old_aliases="$(append_aliases_unique "$service_old_aliases" "$old_aliases")"
        service_row_state="$row_state"
        continue
    elif [ "$service_total_count" -gt 1 ]; then
        continue
    fi

    service_found="true"
    service_match_count=$((service_match_count + 1))
    service_group="$ansible_group"
    service_active_aliases="$active_aliases"
    service_candidate_aliases="$candidate_aliases"
    service_old_aliases="$old_aliases"
    service_row_state="$row_state"
done < <(tail -n +2 "$STATE_FILE")

if [ "$ACTION" = "plan" ] && [ -z "$LIMIT" ]; then
    [ "$service_total_count" -gt 0 ] || fail "state.csv must contain a service row for $SERVICE"
    echo "Service: $SERVICE"
    echo "State file: $STATE_FILE"
    echo "Nodes file: $NODES_FILE"
    echo ""
    for row in "${service_plan_rows[@]}"; do
        IFS='|' read -r plan_group plan_active_aliases plan_candidate_aliases plan_old_aliases plan_row_state <<< "$row"
        echo "Service state: $plan_row_state"
        echo "Ansible group: $plan_group"
        tail -n +2 "$NODES_FILE" | while IFS=, read -r current_alias _endpoint _expected_ip _connection _ssh_port _root_password _extra || [ -n "${current_alias:-}" ]; do
            current_alias="${current_alias//$'\r'/}"
            [ -n "$current_alias" ] || continue
            if [ "$plan_row_state" = "present" ] && alias_in_list "$current_alias" "$plan_active_aliases"; then
                echo "$current_alias: desired present"
            else
                echo "$current_alias: desired absent"
            fi
        done
        if [ -n "$plan_candidate_aliases" ]; then
            echo "Candidates: $plan_candidate_aliases"
        fi
        if [ -n "$plan_old_aliases" ]; then
            echo "Old: $plan_old_aliases"
        fi
        echo ""
    done
    exit 0
fi

[ "$service_total_count" -gt 0 ] || fail "state.csv must contain a service row for $SERVICE"
[ "$service_found" = "true" ] || fail "state.csv must contain a service row for $SERVICE matching --limit $(limit_display_for_error "$LIMIT")"
if [ -n "$LIMIT" ]; then
    limit_match_aliases="$service_active_aliases"
    if { [ "$SERVICE" = "postgres_runtime" ] || [ "$SERVICE" = "softether_l3_vps" ] || [ "$SERVICE" = "platform_networks" ] || [ "$SERVICE" = "platform_router" ] || [ "$SERVICE" = "site_runtime" ]; } && [ -n "$service_candidate_aliases" ]; then
        limit_match_aliases="$(append_aliases_unique "$limit_match_aliases" "$service_candidate_aliases")"
    fi
    while IFS= read -r limit_alias; do
        [ -n "$limit_alias" ] || continue
        alias_in_list "$limit_alias" "$limit_match_aliases" || fail "state.csv must contain a service row for $SERVICE alias $limit_alias matching --limit $(limit_display_for_error "$LIMIT")"
    done < <(split_limit_to_lines "$LIMIT")
else
    [ "$service_match_count" -eq 1 ] || fail "state.csv has multiple $SERVICE rows matching --limit $(limit_display_for_error "$LIMIT"); keep one target row per alias group"
fi
case "$service_row_state" in
    present|absent|purged) ;;
    *) fail "$SERVICE state must be one of: present, absent, purged" ;;
esac

[ -n "$service_group" ] || fail "$SERVICE ansible_group is empty in state.csv"

if [ "$ACTION" = "plan" ]; then
    if [ "$SERVICE" = "site_runtime" ]; then
        site_runtime_python="python3"
        if ! python3 -c 'import sys' >/dev/null 2>&1; then
            site_runtime_python="python"
        fi
        "$site_runtime_python" -c 'import sys' >/dev/null 2>&1 || fail "python3/python not found in PATH"
        [ -f "$SERVICES_REGISTRY" ] || fail "services registry not found: $SERVICES_REGISTRY"
        [ -f "$SITE_RUNTIME_INSTANCES" ] || fail "site_runtime instances not found: $SITE_RUNTIME_INSTANCES"
        [ -f "$SITE_RUNTIME_RESOLVER" ] || fail "site_runtime resolver not found: $SITE_RUNTIME_RESOLVER"
        "$site_runtime_python" "$SITE_RUNTIME_RESOLVER" \
            --registry "$SERVICES_REGISTRY" \
            --instances "$SITE_RUNTIME_INSTANCES" \
            --state "$STATE_FILE" \
            --nodes "$NODES_FILE" \
            --instance "$INSTANCE" \
            --image-ref "$IMAGE_REF" \
            --limit "$LIMIT"
        exit $?
    fi
    echo "Service: $SERVICE"
    echo "State file: $STATE_FILE"
    echo "Service state: $service_row_state"
    echo "Ansible group: $service_group"
    echo "Nodes file: $NODES_FILE"
    echo ""
    tail -n +2 "$NODES_FILE" | while IFS=, read -r current_alias _endpoint _expected_ip _connection _ssh_port _root_password _extra || [ -n "${current_alias:-}" ]; do
        current_alias="${current_alias//$'\r'/}"
        [ -n "$current_alias" ] || continue
        plan_present_aliases="$service_active_aliases"
        if { [ "$SERVICE" = "postgres_runtime" ] || [ "$SERVICE" = "softether_l3_vps" ] || [ "$SERVICE" = "platform_networks" ] || [ "$SERVICE" = "platform_router" ] || [ "$SERVICE" = "site_runtime" ]; } && [ -n "$service_candidate_aliases" ]; then
            plan_present_aliases="$(append_aliases_unique "$plan_present_aliases" "$service_candidate_aliases")"
        fi
        if [ "$service_row_state" = "present" ] && alias_in_list "$current_alias" "$plan_present_aliases"; then
            echo "$current_alias: desired present"
        else
            echo "$current_alias: desired absent"
        fi
    done
    if [ -n "$service_candidate_aliases" ]; then
        echo ""
        echo "Candidates: $service_candidate_aliases"
    fi
    if [ -n "$service_old_aliases" ]; then
        echo "Old: $service_old_aliases"
    fi
    exit 0
fi

command -v ansible-playbook >/dev/null 2>&1 || fail "ansible-playbook not found in PATH"
[ -f "$INVENTORY" ] || fail "inventory not found: $INVENTORY"
if [ -z "$PLAYBOOK" ]; then
    PLAYBOOK="$(service_playbook "$SERVICE")" || fail "No default playbook for service: $SERVICE"
fi
[ -f "$PLAYBOOK" ] || fail "playbook not found: $PLAYBOOK"

if [ "$ACTION" = "purge" ] && [ "$CONFIRM_PURGE" != "true" ]; then
    fail "purge requires --confirm-purge"
fi
if [ "$ACTION" = "reseed" ] && [ "$SERVICE" != "vpn_edge" ] && [ "$SERVICE" != "vpn_cascade" ]; then
    fail "reseed is supported only for vpn_edge and vpn_cascade"
fi
if [ "$ACTION" = "reseed" ] && [ -z "$LIMIT" ]; then
    fail "$SERVICE reseed requires --limit ALIAS"
fi
if [ "$ACTION" = "reseed" ] && [ "$service_row_state" != "present" ]; then
    fail "$SERVICE reseed requires state=present in $STATE_FILE"
fi
if { [ "$ACTION" = "apply" ] || [ "$ACTION" = "probe" ] || [ "$ACTION" = "stage-image" ] || [ "$ACTION" = "stage-support-images" ] || [ "$ACTION" = "publication-check" ] || [ "$ACTION" = "publication-prepare" ] || [ "$ACTION" = "backup-init" ] || [ "$ACTION" = "backup-schedule" ] || [ "$ACTION" = "backup" ] || [ "$ACTION" = "restore-rehearsal" ] || [ "$ACTION" = "restore-cleanup" ]; } && [ "$service_row_state" != "present" ]; then
    fail "$SERVICE $ACTION requires state=present in $STATE_FILE"
fi
service_target_aliases="$service_active_aliases"
if { [ "$SERVICE" = "postgres_runtime" ] || [ "$SERVICE" = "softether_l3_vps" ] || [ "$SERVICE" = "platform_networks" ] || [ "$SERVICE" = "platform_router" ] || [ "$SERVICE" = "site_runtime" ]; } && [ -n "$service_candidate_aliases" ]; then
    service_target_aliases="$(append_aliases_unique "$service_target_aliases" "$service_candidate_aliases")"
fi
if { [ "$ACTION" = "apply" ] || [ "$ACTION" = "probe" ] || [ "$ACTION" = "stage-image" ] || [ "$ACTION" = "stage-support-images" ] || [ "$ACTION" = "publication-check" ] || [ "$ACTION" = "publication-prepare" ] || [ "$ACTION" = "backup-init" ] || [ "$ACTION" = "backup-schedule" ] || [ "$ACTION" = "backup" ] || [ "$ACTION" = "restore-rehearsal" ] || [ "$ACTION" = "restore-cleanup" ]; } && [ -z "$service_target_aliases" ]; then
    fail "No active/candidate aliases for $SERVICE found in $STATE_FILE"
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "stage-image" ]; then
    [ -f "$IMAGE_ARCHIVE" ] || fail "site_runtime image archive not found: $IMAGE_ARCHIVE"
    [ -f "$IMAGE_MANIFEST" ] || fail "site_runtime image manifest not found: $IMAGE_MANIFEST"
fi
if [ "$SERVICE" = "site_runtime" ] && [ "$ACTION" = "stage-support-images" ]; then
    [ -f "$SUPPORT_ARCHIVE" ] || fail "site_runtime support archive not found: $SUPPORT_ARCHIVE"
    [ -f "$SUPPORT_MANIFEST" ] || fail "site_runtime support manifest not found: $SUPPORT_MANIFEST"
fi

service_state="present"
service_purge_data="false"
service_reseed_config="false"
if [ "$ACTION" = "absent" ] || [ "$ACTION" = "purge" ]; then
    service_state="absent"
fi
if [ "$ACTION" = "purge" ]; then
    service_purge_data="true"
fi
if [ "$ACTION" = "reseed" ]; then
    service_reseed_config="true"
fi

if [ -n "$LIMIT" ]; then
    limit_args=(--limit "$(ansible_limit_pattern "$LIMIT")")
elif { [ "$SERVICE" = "postgres_runtime" ] || [ "$SERVICE" = "softether_l3_vps" ] || [ "$SERVICE" = "platform_networks" ] || [ "$SERVICE" = "platform_router" ] || [ "$SERVICE" = "site_runtime" ]; } && [ -n "$service_candidate_aliases" ]; then
    limit_args=(--limit "$service_group:candidate_$service_group")
else
    limit_args=(--limit "$service_group")
fi
check_args=()
if [ "$CHECK" = "true" ]; then
    check_args=(--check)
fi
if [ "$SERVICE" = "site_runtime" ] && { [ "$ACTION" = "apply" ] || [ "$ACTION" = "backup-init" ] || [ "$ACTION" = "backup-schedule" ] || [ "$ACTION" = "backup" ] || [ "$ACTION" = "restore-rehearsal" ] || [ "$ACTION" = "restore-cleanup" ]; }; then
    [[ "$INSTANCE" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail "site_runtime instance is not normalized"
    command -v flock >/dev/null 2>&1 || fail "flock not found in PATH"
    site_runtime_lock="/var/lock/ai-service-platform-site-runtime-$INSTANCE.lock"
    exec 9>"$site_runtime_lock"
    flock -n 9 || fail "site_runtime operation is already active for instance $INSTANCE"
    SITE_RUNTIME_LOCK_HELD="true"
fi
mapfile -t extra_vars < <(service_extra_vars "$SERVICE" "$service_state" "$service_purge_data" "$service_reseed_config" "$POLICY_ROUTER_IMAGE_REF" "$BUILD_POLICY_ROUTER_IMAGE")

set +e
list_hosts_output="$(
    run_ansible_playbook \
        -i "$INVENTORY" \
        "$PLAYBOOK" \
        "${extra_vars[@]}" \
        "${limit_args[@]}" \
        --list-hosts 2>&1
)"
list_hosts_rc=$?
set -e
printf '%s\n' "$list_hosts_output"
if [ "$list_hosts_rc" -ne 0 ]; then
    fail "ansible --list-hosts failed before $SERVICE $ACTION with exit code $list_hosts_rc"
fi
list_hosts_count=0
list_hosts_seen="false"
while IFS= read -r list_hosts_line; do
    if [[ "$list_hosts_line" =~ hosts[[:space:]]+\(([0-9]+)\) ]]; then
        list_hosts_count=$((list_hosts_count + BASH_REMATCH[1]))
        list_hosts_seen="true"
    fi
done <<< "$list_hosts_output"
[ "$list_hosts_seen" = "true" ] || fail "Could not determine Ansible host count before $SERVICE $ACTION"
[ "$list_hosts_count" -gt 0 ] || fail "Ansible selected 0 hosts for $SERVICE $ACTION with limit $(limit_display_for_error "$LIMIT"). Regenerate inventory from nodes.csv/state.csv."

set -x
run_ansible_playbook \
    -i "$INVENTORY" \
    "$PLAYBOOK" \
    "${extra_vars[@]}" \
    "${limit_args[@]}" \
    "${check_args[@]}"
