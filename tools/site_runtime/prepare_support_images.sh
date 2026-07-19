#!/usr/bin/env bash
set -euo pipefail

target_alias="${1:?target alias is required}"
command -v docker >/dev/null || { echo "docker не найден в PATH" >&2; exit 2; }
temp_dir="$(mktemp -d -t ai-service-platform.site-runtime-support.XXXXXX)"
transport_tags=()
cleanup() {
    rc=$?
    for tag in "${transport_tags[@]:-}"; do [ -z "$tag" ] || docker image rm "$tag" >/dev/null 2>&1 || true; done
    if [ "$rc" -ne 0 ]; then rm -rf "$temp_dir"; fi
    exit "$rc"
}
trap cleanup EXIT

manifest_rows=()
for spec in redis=redis:7-alpine nginx=nginx:alpine; do
    name="${spec%%=*}"
    source_ref="${spec#*=}"
    docker image pull --platform linux/amd64 "$source_ref"
    row="$(python3 - "$name" "$source_ref" <<'PY'
import json, subprocess, sys
name, source = sys.argv[1:]
item = json.loads(subprocess.check_output(["docker", "image", "inspect", source], text=True))[0]
if (item.get("Os"), item.get("Architecture")) != ("linux", "amd64"):
    raise SystemExit(f"{source} должен иметь platform linux/amd64")
resolved = next((value for value in item.get("RepoDigests", []) if "@sha256:" in value), None)
if not resolved:
    raise SystemExit(f"У {source} отсутствует immutable RepoDigest")
digest = resolved.rsplit("@sha256:", 1)[1]
tag = f"ai-service-platform/site-runtime-support:{name}-sha256-{digest}"
subprocess.check_call(["docker", "image", "tag", source, tag])
print(json.dumps({"name": name, "source_ref": source, "resolved_ref": resolved,
 "distribution_digest": f"sha256:{digest}", "transport_tag": tag,
 "config_image_id": item["Id"], "platform": "linux/amd64"}, sort_keys=True))
PY
)"
    manifest_rows+=("$row")
    transport_tags+=("$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["transport_tag"])' "$row")")
done

archive_path="$temp_dir/support-images.tar"
manifest_path="$temp_dir/support-images-manifest.json"
docker image save --output "$archive_path" "${transport_tags[@]}"
python3 - "$target_alias" "$archive_path" "$manifest_path" "${manifest_rows[@]}" <<'PY'
import hashlib, json, sys
alias, archive, output, *rows = sys.argv[1:]
h = hashlib.sha256()
with open(archive, "rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""): h.update(chunk)
manifest = {"schema_version": 1, "kind": "site-runtime-support-images",
 "target_alias": alias, "platform": "linux/amd64", "archive_sha256": h.hexdigest(),
 "images": [json.loads(row) for row in rows]}
with open(output, "w", encoding="utf-8") as stream: json.dump(manifest, stream, sort_keys=True)
print(json.dumps({"temp_dir": str(__import__('pathlib').Path(archive).parent),
 "archive_path": archive, "manifest_path": output}))
PY
