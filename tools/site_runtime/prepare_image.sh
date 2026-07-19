#!/usr/bin/env bash
set -euo pipefail

instance="${1:?instance is required}"
image_ref="${2:?image_ref is required}"
target_alias="${3:?target_alias is required}"
[[ "$image_ref" =~ ^([a-z0-9.-]+(/[a-z0-9._-]+)+)@sha256:([0-9a-f]{64})$ ]] || { echo "image_ref must be repository@sha256" >&2; exit 2; }
for command_name in gh docker python3; do command -v "$command_name" >/dev/null || { echo "$command_name not found" >&2; exit 2; }; done

temp_dir="$(mktemp -d -t ai-service-platform.site-runtime-image.XXXXXX)"
trap 'rc=$?; if [ -n "${transport_tag:-}" ]; then docker image rm "$transport_tag" >/dev/null 2>&1 || true; fi; rm -rf "$temp_dir/docker-config"; if [ "$rc" -ne 0 ]; then rm -rf "$temp_dir"; fi; exit "$rc"' EXIT
export DOCKER_CONFIG="$temp_dir/docker-config"
mkdir -p "$DOCKER_CONFIG"
gh auth status --hostname github.com >/dev/null
username="$(gh api user --jq .login)"
gh auth token --hostname github.com | docker login ghcr.io --username "$username" --password-stdin >/dev/null
docker image pull --platform linux/amd64 "$image_ref"
# Одноразовые данные авторизации больше не нужны после проверенного pull.
rm -rf "$DOCKER_CONFIG"
unset DOCKER_CONFIG
digest="${image_ref##*@sha256:}"
transport_tag="ai-service-platform/site-runtime-import:${instance}-sha256-${digest}"
docker image tag "$image_ref" "$transport_tag"
archive_path="$temp_dir/image.tar"
manifest_path="$temp_dir/manifest.json"
docker image save --output "$archive_path" "$transport_tag"
python3 - "$image_ref" "$instance" "$target_alias" "$transport_tag" "$archive_path" "$manifest_path" <<'PY'
import hashlib, json, subprocess, sys
image_ref, instance, alias, tag, archive, output = sys.argv[1:]
inspect = json.loads(subprocess.check_output(["docker", "image", "inspect", image_ref], text=True))[0]
if image_ref not in inspect.get("RepoDigests", []): raise SystemExit("requested RepoDigest missing")
if (inspect.get("Os"), inspect.get("Architecture")) != ("linux", "amd64"): raise SystemExit("platform must be linux/amd64")
h = hashlib.sha256()
with open(archive, "rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""): h.update(chunk)
labels = (inspect.get("Config") or {}).get("Labels") or {}
manifest = {"schema_version": 1, "instance": instance, "target_alias": alias,
 "image_ref": image_ref, "distribution_digest": image_ref.rsplit("@", 1)[1],
 "transport_tag": tag, "config_image_id": inspect["Id"], "platform": "linux/amd64",
 "archive_sha256": h.hexdigest(), "source_label": labels.get("org.opencontainers.image.source"),
 "revision_label": labels.get("org.opencontainers.image.revision"), "version_label": labels.get("org.opencontainers.image.version")}
with open(output, "w", encoding="utf-8") as stream: json.dump(manifest, stream, sort_keys=True)
print(json.dumps({"temp_dir": str(__import__('pathlib').Path(archive).parent), "archive_path": archive,
 "manifest_path": output, "transport_tag": tag, "config_image_id": inspect["Id"]}))
PY
