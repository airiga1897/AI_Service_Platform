#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-}"
IMAGE_REF="${2:-}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/stacks/mycleanbot-prod}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
ENV_FILE="${ENV_FILE:-.env.mycleanbot.secrets}"
CONFIG_FILE="${CONFIG_FILE:-mycleanbot.env}"
STATE_DIR="${STATE_DIR:-.deploy-state}"
BACKUP_COMMAND="${BACKUP_COMMAND:-sudo -n /usr/local/bin/ai-service-mycleanbot-backup backup}"
IMAGE_PATTERN='^ghcr\.io/airiga1897/mycleanbot@sha256:[0-9a-f]{64}$'
ROUTE_CONTAINER="${ROUTE_CONTAINER:-platform-router}"

fail() {
  printf 'mycleanbot deploy error: %s\n' "$*" >&2
  exit 2
}

env_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$CONFIG_FILE" "$ENV_FILE" | tail -n 1
}

require_digest() {
  [[ "$1" =~ $IMAGE_PATTERN ]] || fail "only the approved immutable GHCR digest is accepted"
}

compose() {
  MYCLEANBOT_IMAGE="$1" docker compose \
    --env-file .env.deploy \
    -f "$COMPOSE_FILE" "${@:2}"
}

write_deploy_env() {
  local image_ref="$1"
  local route_image
  local temporary
  route_image="$(docker inspect "$ROUTE_CONTAINER" --format '{{.Config.Image}}')" ||
    fail "platform route container is not available"
  [[ -n "$route_image" ]] || fail "platform route image is empty"
  docker image inspect "$route_image" >/dev/null ||
    fail "platform route image is not present locally"
  temporary="$(mktemp "${DEPLOY_DIR}/.env.deploy.XXXXXX")"
  chmod 600 "$temporary"
  {
    printf 'MYCLEANBOT_IMAGE=%s\n' "$image_ref"
    printf 'MYCLEANBOT_ROUTE_IMAGE=%s\n' "$route_image"
  } >"$temporary"
  mv -f "$temporary" .env.deploy
}

verify_postgres_route() {
  local image_ref="$1"
  local expected_route_image
  local configured_route_image
  expected_route_image="$(docker inspect "$ROUTE_CONTAINER" --format '{{.Config.Image}}')"
  configured_route_image="$(
    compose "$image_ref" ps -q mycleanbot-route |
      xargs -r docker inspect --format '{{.Config.Image}}'
  )"
  [[ -n "$expected_route_image" && "$configured_route_image" == "$expected_route_image" ]] ||
    fail "mycleanbot-route does not use the accepted platform route image"
  compose "$image_ref" exec -T mycleanbot-route \
    sh -ec "ip route show 172.30.8.10/32 | grep -F 'via 172.31.1.2'" >/dev/null ||
    fail "MyCleanBot PostgreSQL route is not ready"
  compose "$image_ref" run --rm --no-deps mycleanbot-web \
    python -c \
    "import socket; socket.create_connection(('172.30.8.10', 5432), 5).close()" ||
    fail "MyCleanBot PostgreSQL TCP path is not ready"
}

verify_runtime() {
  local image_ref="$1"
  local configured
  verify_postgres_route "$image_ref"
  for service in mycleanbot-web mycleanbot-worker; do
    configured="$(compose "$image_ref" ps -q "$service" | xargs -r docker inspect --format '{{.Config.Image}}')"
    [[ "$configured" == "$image_ref" ]] || fail "$service does not use the accepted digest"
  done

  local attempt
  for attempt in $(seq 1 20); do
    if compose "$image_ref" exec -T mycleanbot-web \
      python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/livez', timeout=10)" &&
      compose "$image_ref" exec -T mycleanbot-web \
        python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=10)" &&
      compose "$image_ref" exec -T mycleanbot-web python manage.py shell -c \
        "from datetime import timedelta; from django.utils import timezone; from core.models import WorkerHeartbeat; h=WorkerHeartbeat.objects.filter(name='telegram-supervisor').first(); assert h and h.updated_at >= timezone.now()-timedelta(seconds=45)"; then
      return
    fi
    sleep 3
  done
  return 1
}

restore_previous_runtime() {
  local previous_ref="$1"
  if [[ -n "$previous_ref" ]]; then
    write_deploy_env "$previous_ref"
    compose "$previous_ref" pull mycleanbot-web mycleanbot-worker
    compose "$previous_ref" up -d --remove-orphans
    verify_runtime "$previous_ref"
  else
    docker compose --env-file .env.deploy -f "$COMPOSE_FILE" stop \
      mycleanbot-web mycleanbot-worker
  fi
}

docker_login() {
  local docker_config
  docker_config="$(mktemp -d "${DEPLOY_DIR}/.docker-config.XXXXXX")"
  [[ "$docker_config" == "${DEPLOY_DIR}/.docker-config."* ]] ||
    fail "temporary Docker config escaped deploy directory"
  chmod 700 "$docker_config"
  export DOCKER_CONFIG="$docker_config"
  IFS= read -r ghcr_token || [[ -n "$ghcr_token" ]]
  [[ -n "${GHCR_USERNAME:-}" && -n "$ghcr_token" ]] ||
    fail "GHCR credentials are required"
  printf '%s' "$ghcr_token" |
    docker login ghcr.io --username "$GHCR_USERNAME" --password-stdin >/dev/null
  unset ghcr_token
  trap 'rm -rf -- "${DOCKER_CONFIG:?}"' EXIT
}

deploy() {
  local image_ref="$1"
  local previous_ref=""
  local config_mode
  require_digest "$image_ref"
  [[ -f "$CONFIG_FILE" ]] || fail "tracked configuration file is missing"
  config_mode="$(stat -c '%a' "$CONFIG_FILE")"
  (( (8#$config_mode & 0022) == 0 )) ||
    fail "$CONFIG_FILE must not be group- or world-writable"
  [[ -f "$ENV_FILE" ]] || fail "protected environment file is missing"
  [[ "$(stat -c '%a' "$ENV_FILE")" == "600" ]] || fail "$ENV_FILE must have mode 0600"
  local required_key
  for required_key in \
    DATABASE_URL DJANGO_SECRET_KEY MASTER_ENCRYPTION_KEY DJANGO_ALLOWED_HOSTS \
    DJANGO_CSRF_TRUSTED_ORIGINS CSRF_TRUSTED_ORIGINS; do
    [[ -n "$(env_value "$required_key")" ]] ||
      fail "$required_key is required in the combined environment"
  done
  [[ "$(env_value DATABASE_URL)" =~ ^postgres(ql)?://.+/mycleanbot(\?.*)?$ ]] ||
    fail "DATABASE_URL must target the isolated mycleanbot database"
  [[ "$(env_value DJANGO_DEBUG)" == "false" ]] ||
    fail "DJANGO_DEBUG=false is required"
  local django_csrf
  local image_csrf
  django_csrf="$(env_value DJANGO_CSRF_TRUSTED_ORIGINS)"
  image_csrf="$(env_value CSRF_TRUSTED_ORIGINS)"
  [[ "$django_csrf" == "$image_csrf" ]] ||
    fail "the canonical and image-compatible CSRF origins must match"
  unset django_csrf image_csrf
  [[ "$(env_value TELEGRAM_API_ID)" =~ ^[1-9][0-9]*$ ]] ||
    fail "valid TELEGRAM_API_ID is required before worker startup"
  [[ -n "$(env_value TELEGRAM_API_HASH)" ]] ||
    fail "valid TELEGRAM_API_HASH is required before worker startup"

  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  if [[ -f "$STATE_DIR/current" ]]; then
    previous_ref="$(<"$STATE_DIR/current")"
    require_digest "$previous_ref"
  fi

  docker network inspect ai_service_app_vps1 >/dev/null ||
    fail "platform application network is missing"
  docker inspect "$ROUTE_CONTAINER" >/dev/null ||
    fail "platform route container is missing"
  write_deploy_env "$image_ref"
  compose "$image_ref" config --quiet

  # The platform backup command owns its credentials and must complete before
  # any migration. It must not print DATABASE_URL or passwords.
  bash -c "$BACKUP_COMMAND"

  docker_login

  compose "$image_ref" pull mycleanbot-web mycleanbot-worker
  compose "$image_ref" up -d mycleanbot-route
  verify_postgres_route "$image_ref"
  compose "$image_ref" run --rm --no-deps mycleanbot-web \
    python manage.py migrate --noinput
  compose "$image_ref" up -d --remove-orphans

  if ! verify_runtime "$image_ref"; then
    if ! restore_previous_runtime "$previous_ref"; then
      docker compose --env-file .env.deploy -f "$COMPOSE_FILE" stop \
        mycleanbot-web mycleanbot-worker
      fail "acceptance failed and previous image is schema-incompatible; application containers were stopped"
    fi
    fail "acceptance failed; previous runtime was restored"
  fi

  if [[ -n "$previous_ref" && "$previous_ref" != "$image_ref" ]]; then
    printf '%s\n' "$previous_ref" >"$STATE_DIR/previous.new"
    chmod 600 "$STATE_DIR/previous.new"
    mv -f "$STATE_DIR/previous.new" "$STATE_DIR/previous"
  fi
  printf '%s\n' "$image_ref" >"$STATE_DIR/current.new"
  chmod 600 "$STATE_DIR/current.new"
  mv -f "$STATE_DIR/current.new" "$STATE_DIR/current"
}

rollback() {
  local target_ref="$1"
  if [[ "$target_ref" == "undeployed" ]]; then
    [[ ! -f "$STATE_DIR/previous" ]] ||
      fail "undeployed rollback is allowed only when no previous digest exists"
    docker compose --env-file .env.deploy -f "$COMPOSE_FILE" stop \
      mycleanbot-web mycleanbot-worker
    return
  fi
  require_digest "$target_ref"
  docker_login
  local current_ref=""
  [[ -f "$STATE_DIR/current" ]] && current_ref="$(<"$STATE_DIR/current")"
  require_digest "$current_ref"
  write_deploy_env "$target_ref"
  compose "$target_ref" pull mycleanbot-web mycleanbot-worker
  compose "$target_ref" up -d --remove-orphans
  if ! verify_runtime "$target_ref"; then
    write_deploy_env "$current_ref"
    compose "$current_ref" up -d --remove-orphans
    verify_runtime "$current_ref" ||
      fail "rollback and recovery both failed; database was not modified"
    fail "rollback target failed acceptance; current runtime was restored"
  fi
  printf '%s\n' "$current_ref" >"$STATE_DIR/previous.new"
  chmod 600 "$STATE_DIR/previous.new"
  mv -f "$STATE_DIR/previous.new" "$STATE_DIR/previous"
  printf '%s\n' "$target_ref" >"$STATE_DIR/current.new"
  chmod 600 "$STATE_DIR/current.new"
  mv -f "$STATE_DIR/current.new" "$STATE_DIR/current"
}

[[ "$ACTION" =~ ^(deploy|rollback|verify)$ ]] ||
  fail "usage: mycleanbot_remote.sh deploy|rollback|verify [image-ref]"
mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"
exec 9>"$STATE_DIR.lock"
flock -n 9 || fail "another MyCleanBot operation is running"

case "$ACTION" in
  deploy) deploy "$IMAGE_REF" ;;
  rollback) rollback "$IMAGE_REF" ;;
  verify)
    [[ -f "$STATE_DIR/current" ]] || fail "no accepted deployment state"
    IMAGE_REF="$(<"$STATE_DIR/current")"
    require_digest "$IMAGE_REF"
    verify_runtime "$IMAGE_REF"
    ;;
esac
