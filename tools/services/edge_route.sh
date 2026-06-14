#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  bash tools/services/edge_route.sh <vpn_ingress|minecraft> <present|absent|purged> --alias <alias> [--state-file PATH]

Updates operator/state.csv desired state only. It does not run sync or Ansible.
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

split_aliases() {
    local value="${1//,/+}"
    IFS='+' read -ra parts <<< "$value"
    local part
    for part in "${parts[@]}"; do
        part="${part//[$'\t\r\n ']}"
        [ -n "$part" ] && printf '%s\n' "$part"
    done
}

[ "$#" -ge 2 ] || { usage; exit 2; }

route="$1"
state="$2"
shift 2

case "$route" in
    vpn_ingress) route_group="vpn_ingress" ;;
    minecraft) route_group="minecraft_edge" ;;
    *) fail "route must be one of: vpn_ingress, minecraft" ;;
esac

case "$state" in
    present|absent|purged) ;;
    *) fail "state must be one of: present, absent, purged" ;;
esac

state_file="./operator/state.csv"
alias=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --alias)
            alias="${2:-}"
            shift 2
            ;;
        --state-file)
            state_file="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[ -n "$alias" ] || fail "--alias is required"
[[ "$alias" =~ ^[A-Za-z0-9_-]+$ ]] || fail "alias must contain only letters, digits, underscore or dash: $alias"
[ -f "$state_file" ] || fail "state.csv not found: $state_file"

expected_header="kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state"
first_line="$(head -n 1 "$state_file" | tr -d '\r')"
[ "$first_line" = "$expected_header" ] || fail "state.csv header must be exactly: $expected_header"

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

alias_known="false"
updated="false"
line_number=0

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line="${raw_line%$'\r'}"
    line_number=$((line_number + 1))

    if [ "$line_number" -eq 1 ]; then
        printf '%s\n' "$line" >> "$tmp_file"
        continue
    fi

    [ -n "${line// }" ] || continue
    IFS=',' read -r kind name ansible_group active_aliases candidate_aliases old_aliases row_state extra <<< "$line"
    [ -z "${extra:-}" ] || fail "state.csv row $line_number must have exactly 7 columns"

    for field in "$active_aliases" "$candidate_aliases" "$old_aliases"; do
        while IFS= read -r existing_alias; do
            [ "$existing_alias" = "$alias" ] && alias_known="true"
        done < <(split_aliases "$field")
    done

    if [ "$kind" = "edge_route" ] && [ "$name" = "$route" ] && [ "$active_aliases" = "$alias" ]; then
        printf 'edge_route,%s,%s,%s,,,%s\n' "$route" "$route_group" "$alias" "$state" >> "$tmp_file"
        updated="true"
    else
        printf '%s\n' "$line" >> "$tmp_file"
    fi
done < "$state_file"

[ "$alias_known" = "true" ] || fail "alias '$alias' is not referenced in state.csv"

if [ "$updated" != "true" ]; then
    printf 'edge_route,%s,%s,%s,,,%s\n' "$route" "$route_group" "$alias" "$state" >> "$tmp_file"
fi

cp "$tmp_file" "$state_file"
echo "edge_route $route on $alias set to $state in $state_file"
