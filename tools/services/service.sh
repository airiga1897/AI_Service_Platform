#!/usr/bin/env bash

set -euo pipefail

SERVICE="${1:-}"
ACTION="${2:-}"
NODES_FILE="./operator/nodes.csv"
STATE_FILE="./operator/state.csv"
INVENTORY="inventory.ini"
PLAYBOOK=""
LIMIT=""
POLICY_ROUTER_IMAGE_REF=""
BUILD_POLICY_ROUTER_IMAGE="false"
CHECK="false"
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

Options:
  --nodes-file PATH      Operator nodes.csv. Default: ./operator/nodes.csv
  --state-file PATH      Operator state.csv. Default: ./operator/state.csv
  --inventory PATH       Generated Ansible inventory. Default: inventory.ini
  --playbook PATH        Override service playbook.
  --limit VALUE          Ansible --limit. Default: service ansible_group.
  --policy-router-image-ref REF
                        vpn_cascade only: pin policy-router image and skip cache/build.
  --build-policy-router-image
                        vpn_cascade only: force rebuild instead of reusing a matching local image.
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
        *)
            return 1
            ;;
    esac
}

run_ansible_playbook() {
    if [ "$(id -u)" -eq 0 ]; then
        sudo -u ansible env ANSIBLE_SSH_COMMON_ARGS="$ANSIBLE_SSH_COMMON_ARGS" ansible-playbook "$@"
    else
        ansible-playbook "$@"
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
    edge_haproxy|vpn_edge|vpn_cascade|policy_gateway|edge_candidate_collector) ;;
    *) fail "Unsupported service '$SERVICE'. Supported now: edge_haproxy, vpn_edge, vpn_cascade, policy_gateway, edge_candidate_collector." ;;
esac
case "$ACTION" in
    plan|apply|absent|purge|reseed) ;;
    *) usage; fail "Action must be one of: plan, apply, absent, purge, reseed" ;;
esac
shift 2

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
        --policy-router-image-ref)
            POLICY_ROUTER_IMAGE_REF="${2:-}"
            shift 2
            ;;
        --build-policy-router-image)
            BUILD_POLICY_ROUTER_IMAGE="true"
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

if [ -n "$POLICY_ROUTER_IMAGE_REF" ] && [ "$SERVICE" != "vpn_cascade" ]; then
    fail "--policy-router-image-ref is supported only for service vpn_cascade"
fi
if [ "$BUILD_POLICY_ROUTER_IMAGE" = "true" ] && [ "$SERVICE" != "vpn_cascade" ]; then
    fail "--build-policy-router-image is supported only for service vpn_cascade"
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
if [ "$SERVICE" = "vpn_edge" ] || [ "$SERVICE" = "vpn_cascade" ] || [ "$SERVICE" = "policy_gateway" ]; then
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
while IFS=, read -r kind name ansible_group active_aliases candidate_aliases old_aliases row_state extra || [ -n "${kind:-}" ]; do
    kind="${kind//$'\r'/}"
    name="${name//$'\r'/}"
    ansible_group="${ansible_group//$'\r'/}"
    active_aliases="${active_aliases//$'\r'/}"
    candidate_aliases="${candidate_aliases//$'\r'/}"
    old_aliases="${old_aliases//$'\r'/}"
    row_state="${row_state//$'\r'/}"
    extra="${extra//$'\r'/}"
    [ "$kind" = "service" ] && [ "$name" = "$SERVICE" ] || continue
    [ -z "$extra" ] || fail "state.csv $SERVICE row has too many columns"
    service_total_count=$((service_total_count + 1))
    service_plan_rows+=("$ansible_group|$active_aliases|$candidate_aliases|$old_aliases|$row_state")

    if [ -n "$LIMIT" ]; then
        selected_aliases="$(limit_aliases_in_row "$LIMIT" "$active_aliases")"
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
    while IFS= read -r limit_alias; do
        [ -n "$limit_alias" ] || continue
        alias_in_list "$limit_alias" "$service_active_aliases" || fail "state.csv must contain a service row for $SERVICE alias $limit_alias matching --limit $(limit_display_for_error "$LIMIT")"
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
    echo "Service: $SERVICE"
    echo "State file: $STATE_FILE"
    echo "Service state: $service_row_state"
    echo "Ansible group: $service_group"
    echo "Nodes file: $NODES_FILE"
    echo ""
    tail -n +2 "$NODES_FILE" | while IFS=, read -r current_alias _endpoint _expected_ip _connection _ssh_port _root_password _extra || [ -n "${current_alias:-}" ]; do
        current_alias="${current_alias//$'\r'/}"
        [ -n "$current_alias" ] || continue
        if [ "$service_row_state" = "present" ] && alias_in_list "$current_alias" "$service_active_aliases"; then
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
if [ "$ACTION" = "apply" ] && [ "$service_row_state" != "present" ]; then
    fail "$SERVICE apply requires state=present in $STATE_FILE"
fi
if [ "$ACTION" = "apply" ] && [ -z "$service_active_aliases" ]; then
    fail "No active aliases for $SERVICE found in $STATE_FILE"
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
else
    limit_args=(--limit "$service_group")
fi
check_args=()
if [ "$CHECK" = "true" ]; then
    check_args=(--check)
fi
mapfile -t extra_vars < <(service_extra_vars "$SERVICE" "$service_state" "$service_purge_data" "$service_reseed_config" "$POLICY_ROUTER_IMAGE_REF" "$BUILD_POLICY_ROUTER_IMAGE")

list_hosts_output="$(
    run_ansible_playbook \
        -i "$INVENTORY" \
        "$PLAYBOOK" \
        "${extra_vars[@]}" \
        "${limit_args[@]}" \
        --list-hosts 2>&1
)"
list_hosts_rc=$?
printf '%s\n' "$list_hosts_output"
if [ "$list_hosts_rc" -ne 0 ]; then
    fail "ansible --list-hosts failed before $SERVICE $ACTION with exit code $list_hosts_rc"
fi
list_hosts_count="$(printf '%s\n' "$list_hosts_output" | sed -n 's/.*hosts (\([0-9][0-9]*\)).*/\1/p' | head -n 1)"
[ -n "$list_hosts_count" ] || fail "Could not determine Ansible host count before $SERVICE $ACTION"
[ "$list_hosts_count" -gt 0 ] || fail "Ansible selected 0 hosts for $SERVICE $ACTION with limit $(limit_display_for_error "$LIMIT"). Regenerate inventory from nodes.csv/state.csv."

set -x
run_ansible_playbook \
    -i "$INVENTORY" \
    "$PLAYBOOK" \
    "${extra_vars[@]}" \
    "${limit_args[@]}" \
    "${check_args[@]}"
