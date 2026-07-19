#!/usr/bin/env python3
"""Вычисление generic site_runtime без использования устаревших VPS-полей."""

from __future__ import annotations

import argparse
import copy
import csv
import json
import re
import sys
from pathlib import Path
from typing import Any

import yaml


INSTANCE_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
DIGEST_REF_RE = re.compile(r"(?P<repository>[a-z0-9.-]+(?:/[a-z0-9._-]+)+)@sha256:(?P<digest>[0-9a-f]{64})")
VOLUME_RE = re.compile(r"[a-z0-9][a-z0-9_-]+")


class ContractError(ValueError):
    pass


def _load_yaml(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        value = yaml.safe_load(handle) or {}
    if not isinstance(value, dict):
        raise ContractError(f"{path} must contain a YAML mapping")
    return value


def resolve(
    *, registry_path: Path, instances_path: Path, state_path: Path,
    nodes_path: Path, instance_name: str, image_ref: str, limit: str,
) -> dict[str, Any]:
    if not INSTANCE_RE.fullmatch(instance_name):
        raise ContractError("instance must be lowercase kebab-case")
    if not limit or "," in limit or "+" in limit:
        raise ContractError("site_runtime requires exactly one limit alias")

    registry = _load_yaml(registry_path)
    instance_doc = _load_yaml(instances_path)
    profiles = registry.get("runtime_instances") or {}
    placements = instance_doc.get("instances") or {}
    if instance_doc.get("version") != 1 or not isinstance(placements, dict):
        raise ContractError("site_runtime instances.yml must use version: 1 and an instances map")
    if instance_name not in placements:
        raise ContractError(f"unknown site_runtime instance: {instance_name}")
    if instance_name not in profiles:
        raise ContractError(f"services.yml has no runtime profile for {instance_name}")

    placement = placements[instance_name]
    profile = profiles[instance_name]
    if not isinstance(placement, dict) or not isinstance(profile, dict):
        raise ContractError("site_runtime placement and profile must be mappings")
    runtime = profile.get("site_runtime") or {}
    if not isinstance(runtime, dict):
        raise ContractError(f"runtime_instances.{instance_name}.site_runtime must be a map")

    alias = str(placement.get("placement_alias") or "").strip()
    if alias != limit:
        raise ContractError(f"limit {limit!r} does not match placement alias {alias!r}")
    aliases = [str(item.get("placement_alias") or "").strip() for item in placements.values() if isinstance(item, dict)]
    if aliases.count(alias) != 1:
        raise ContractError(f"site_runtime v1 permits only one instance on alias {alias}")

    with nodes_path.open(newline="", encoding="utf-8-sig") as handle:
        nodes = {row["current_alias"] for row in csv.DictReader(handle)}
    if alias not in nodes:
        raise ContractError(f"placement alias is absent from nodes.csv: {alias}")
    with state_path.open(newline="", encoding="utf-8-sig") as handle:
        rows = [row for row in csv.DictReader(handle) if row.get("kind") == "service" and row.get("name") == "site_runtime" and row.get("state") == "present"]
    if len(rows) != 1:
        raise ContractError("state.csv requires exactly one present site_runtime service row")
    allowed = [item for field in ("active_aliases", "candidate_aliases") for item in (rows[0].get(field) or "").split("+") if item]
    if alias not in allowed:
        raise ContractError(f"placement alias {alias} is not allowed by site_runtime state")

    image_match = DIGEST_REF_RE.fullmatch(image_ref)
    if not image_match:
        raise ContractError("image_ref must be an immutable repository@sha256 digest")
    repository = str(runtime.get("image_repository") or "")
    if image_match.group("repository") != repository:
        raise ContractError(f"image repository must be {repository}")
    allowed_pattern = str((profile.get("deploy") or {}).get("allowed_image_ref_pattern") or "")
    if not allowed_pattern or re.fullmatch(allowed_pattern, image_ref) is None:
        raise ContractError("image_ref is rejected by the services.yml release policy")
    if runtime.get("release_guard") != "immutable-released-image":
        raise ContractError("site_runtime release_guard must be immutable-released-image")
    if runtime.get("platform") != "linux/amd64":
        raise ContractError("site_runtime v1 supports only linux/amd64")
    support_images = runtime.get("support_images") or {}
    if support_images != {"redis": "redis:7-alpine", "nginx": "nginx:alpine"}:
        raise ContractError("site_runtime support_images must declare redis:7-alpine and nginx:alpine")
    volumes = runtime.get("volumes") or {}
    if not isinstance(volumes, dict) or set(volumes) != {"redis"}:
        raise ContractError("site_runtime volumes должен содержать только redis")
    if not VOLUME_RE.fullmatch(str(volumes.get("redis") or "")):
        raise ContractError("site_runtime volumes.redis должен быть нормализованным именем Docker volume")

    storage = runtime.get("storage") or {}
    expected_storage = {"release_static", "public_media", "private_media"}
    if not isinstance(storage, dict) or set(storage) != expected_storage:
        raise ContractError(
            "site_runtime storage должен содержать release_static, public_media и private_media"
        )
    storage_contract = {
        "release_static": {
            "lifecycle": "release",
            "container_path": "/app/staticfiles",
            "runtime_access": "read-only",
            "nginx": True,
            "name_field": "volume_prefix",
        },
        "public_media": {
            "lifecycle": "persistent",
            "container_path": "/app/media",
            "runtime_access": "read-write",
            "nginx": True,
            "name_field": "volume",
        },
        "private_media": {
            "lifecycle": "persistent",
            "container_path": "/app/private_media",
            "runtime_access": "read-write",
            "nginx": False,
            "name_field": "volume",
        },
    }
    storage_names: list[str] = [str(volumes["redis"])]
    for class_name, expected in storage_contract.items():
        storage_class = storage.get(class_name)
        if not isinstance(storage_class, dict):
            raise ContractError(f"site_runtime storage.{class_name} должен быть mapping")
        expected_fields = {
            "lifecycle", "container_path", "runtime_access", "nginx", expected["name_field"]
        }
        if set(storage_class) != expected_fields:
            raise ContractError(
                f"site_runtime storage.{class_name} должен содержать только поля: "
                + ", ".join(sorted(expected_fields))
            )
        for field in ("lifecycle", "container_path", "runtime_access", "nginx"):
            if storage_class.get(field) != expected[field]:
                raise ContractError(
                    f"site_runtime storage.{class_name}.{field} должен быть {expected[field]!r}"
                )
        storage_name = str(storage_class.get(expected["name_field"]) or "")
        if not VOLUME_RE.fullmatch(storage_name):
            raise ContractError(
                f"site_runtime storage.{class_name}.{expected['name_field']} "
                "должен быть нормализованным именем Docker volume"
            )
        storage_names.append(storage_name)
    if len(storage_names) != len(set(storage_names)):
        raise ContractError("Имена site_runtime storage и Redis volume не должны совпадать")
    components = runtime.get("components") or {}
    expected_components = {"static", "migration", "web", "worker", "beat"}
    if not isinstance(components, dict) or set(components) != expected_components:
        raise ContractError(
            "site_runtime components must declare static, migration, web, worker, and beat"
        )
    for component_name, component in components.items():
        if not isinstance(component, dict) or not str(component.get("command") or "").strip():
            raise ContractError(f"site_runtime component {component_name} must declare a command")

    network = placement.get("network") or {}
    route = network.get("postgres_route") or {}
    expected_network = f"ai_service_app_{alias}"
    if network.get("app_network") != expected_network:
        raise ContractError(f"app_network must be {expected_network}")
    for field in ("anchor_ipv4", "router_ipv4"):
        if not re.fullmatch(r"172\.31\.[0-9]{1,3}\.[0-9]{1,3}", str(network.get(field) or "")):
            raise ContractError(f"network.{field} must be an application-network IPv4 address")
    if route.get("destination") != "172.30.8.10/32" or route.get("via") != network.get("router_ipv4"):
        raise ContractError("postgres_route must target 172.30.8.10/32 through router_ipv4")
    runtime_intent = placement.get("runtime") or {}
    if runtime_intent.get("internal_host") != f"{instance_name}.internal":
        raise ContractError(f"runtime.internal_host must be {instance_name}.internal")
    if runtime_intent.get("postgres_managed_database") != instance_name:
        raise ContractError("runtime.postgres_managed_database must match instance")
    secret_file = str(runtime_intent.get("application_secret_file") or "")
    expected_secret = f"/opt/ai-service-platform/operator/site_runtime/secrets/{instance_name}.env"
    if secret_file != expected_secret:
        raise ContractError(f"runtime.application_secret_file must be {expected_secret}")

    digest = image_match.group("digest")
    release_static_volume = f"{storage['release_static']['volume_prefix']}_{digest}"
    persistent_volume_names = {
        str(volumes["redis"]),
        str(storage["public_media"]["volume"]),
        str(storage["private_media"]["volume"]),
    }
    if release_static_volume in persistent_volume_names:
        raise ContractError("Вычисленное имя release static не должно совпадать с persistent volume")
    resolved_runtime = copy.deepcopy(runtime)
    resolved_runtime["storage"]["release_static"]["volume"] = release_static_volume
    return {
        "instance": instance_name,
        "profile": str(placement.get("profile") or instance_name),
        "target_alias": alias,
        "ansible_group": rows[0]["ansible_group"],
        "image_ref": image_ref,
        "image_repository": repository,
        "distribution_digest": f"sha256:{digest}",
        "platform": "linux/amd64",
        "transport_tag": f"ai-service-platform/site-runtime-import:{instance_name}-sha256-{digest}",
        "network": network,
        "runtime_intent": runtime_intent,
        "runtime_contract": resolved_runtime,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", required=True, type=Path)
    parser.add_argument("--instances", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--nodes", required=True, type=Path)
    parser.add_argument("--instance", required=True)
    parser.add_argument("--image-ref", required=True)
    parser.add_argument("--limit", required=True)
    args = parser.parse_args(argv)
    try:
        model = resolve(
            registry_path=args.registry, instances_path=args.instances,
            state_path=args.state, nodes_path=args.nodes,
            instance_name=args.instance, image_ref=args.image_ref, limit=args.limit,
        )
    except (ContractError, OSError, yaml.YAMLError, re.error) as exc:
        print(f"site_runtime contract error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(model, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
