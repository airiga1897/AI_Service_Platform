#!/usr/bin/env python3
"""Вычисляет канонический контракт backup/restore для принятого site_runtime."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path
from typing import Any

import yaml

INSTANCE_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
VOLUME_RE = re.compile(r"[a-z0-9][a-z0-9_-]+")
CONTAINER_RE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]+")
SNAPSHOT_RE = re.compile(r"(?:latest|[0-9a-f]{8,64})")
REHEARSAL_RE = re.compile(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}")
REPOSITORY_RE = re.compile(r"/opt/backups/ai-service-platform/site-runtime/[a-z0-9-]+/restic")


class ContractError(ValueError):
    """Ошибка канонического backup-контракта."""


def _yaml(path: Path) -> dict[str, Any]:
    value = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(value, dict):
        raise ContractError(f"{path} должен содержать YAML mapping")
    return value


def _rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def _single_role(rows: list[dict[str, str]], name: str) -> str:
    matches = [
        row for row in rows
        if row.get("kind") in {"platform_role", "role"}
        and row.get("name") == name and row.get("state") == "present"
    ]
    if len(matches) != 1:
        raise ContractError(f"state.csv должен содержать ровно одну активную platform_role {name!r}")
    aliases = [item for item in (matches[0].get("active_aliases") or "").split("+") if item]
    if len(aliases) != 1:
        raise ContractError(f"platform_role {name!r} должна иметь ровно один active alias")
    return aliases[0]


def resolve_backup(
    *, registry_path: Path, instances_path: Path, state_path: Path,
    nodes_path: Path, postgres_config_path: Path, instance_name: str, limit: str,
    snapshot_id: str = "", rehearsal_id: str = "",
) -> dict[str, Any]:
    if not INSTANCE_RE.fullmatch(instance_name):
        raise ContractError("instance должен быть lowercase kebab-case")
    if not limit or "," in limit or "+" in limit:
        raise ContractError("site_runtime backup требует ровно один limit alias")
    if snapshot_id and not SNAPSHOT_RE.fullmatch(snapshot_id):
        raise ContractError("snapshot_id должен быть Restic short/full ID или latest")
    if rehearsal_id and not REHEARSAL_RE.fullmatch(rehearsal_id):
        raise ContractError("rehearsal_id должен точно соответствовать failed restore journal")

    registry = _yaml(registry_path)
    instances = _yaml(instances_path)
    postgres_config = _yaml(postgres_config_path).get("postgres_runtime") or {}
    if not isinstance(postgres_config, dict):
        raise ContractError("postgres_runtime config должен содержать YAML mapping")
    postgres_container = str(postgres_config.get("container_name") or "")
    if not CONTAINER_RE.fullmatch(postgres_container):
        raise ContractError("postgres_runtime container_name отсутствует или некорректен")
    placements = instances.get("instances") or {}
    profiles = registry.get("runtime_instances") or {}
    if instances.get("version") != 1 or instance_name not in placements or instance_name not in profiles:
        raise ContractError(f"неизвестный site_runtime instance: {instance_name}")
    placement = placements[instance_name]
    profile = profiles[instance_name]
    alias = str(placement.get("placement_alias") or "")
    if alias != limit:
        raise ContractError(f"limit {limit!r} не совпадает с placement alias {alias!r}")

    state_rows = _rows(state_path)
    service_rows = [
        row for row in state_rows
        if row.get("kind") == "service" and row.get("name") == "site_runtime"
        and row.get("state") == "present"
    ]
    allowed = [
        item for row in service_rows for field in ("active_aliases", "candidate_aliases")
        for item in (row.get(field) or "").split("+") if item
    ]
    if len(service_rows) != 1 or alias not in allowed:
        raise ContractError("placement instance не разрешён active site_runtime state")

    node_aliases = {row.get("current_alias") for row in _rows(nodes_path)}
    backup_cfg = placement.get("backup") or {}
    runtime_backup = (profile.get("site_runtime") or {}).get("backup") or {}
    target_role = str(backup_cfg.get("target_role") or "")
    target_alias = _single_role(state_rows, target_role)
    if target_alias not in node_aliases:
        raise ContractError(f"backup alias отсутствует в nodes.csv: {target_alias}")
    repository = str(backup_cfg.get("repository") or "")
    if not REPOSITORY_RE.fullmatch(repository) or f"/{instance_name}/" not in repository:
        raise ContractError("backup repository не соответствует закрытому instance path")
    secret_file = str(backup_cfg.get("secret_file") or "")
    expected_secret = f"/opt/ai-service-platform/operator/site_runtime/backup-secrets/{instance_name}.env"
    if secret_file != expected_secret:
        raise ContractError(f"backup secret_file должен быть {expected_secret}")

    expected_backup = {
        "engine": "restic", "transport": "sftp",
        "datasets": ["database", "public_media", "private_media"],
        "retention": {"daily": 7, "weekly": 4, "monthly": 6},
        "schedule": "manual", "restore_policy": "scratch-only",
    }
    if runtime_backup != expected_backup:
        raise ContractError("site_runtime backup contract должен точно соответствовать manual Restic policy")
    storage = (profile.get("site_runtime") or {}).get("storage") or {}
    public_volume = str((storage.get("public_media") or {}).get("volume") or "")
    private_volume = str((storage.get("private_media") or {}).get("volume") or "")
    if not VOLUME_RE.fullmatch(public_volume) or not VOLUME_RE.fullmatch(private_volume):
        raise ContractError("public/private media volumes должны быть нормализованными именами")

    postgres_rows = [
        row for row in state_rows if row.get("kind") == "service"
        and row.get("name") == "postgres_runtime" and row.get("state") == "present"
    ]
    if len(postgres_rows) != 1:
        raise ContractError("state.csv должен содержать один active postgres_runtime")
    primary_aliases = [item for item in (postgres_rows[0].get("active_aliases") or "").split("+") if item]
    standby_aliases = [item for item in (postgres_rows[0].get("candidate_aliases") or "").split("+") if item]
    if len(primary_aliases) != 1 or len(standby_aliases) != 2:
        raise ContractError("backup требует один PostgreSQL primary и две standby")

    return {
        "schema_version": 1,
        "instance": instance_name,
        "runtime_alias": alias,
        "backup_target": {"role": target_role, "alias": target_alias, "repository": repository},
        "secret_file": secret_file,
        "datasets": expected_backup["datasets"],
        "retention": expected_backup["retention"],
        "schedule": "manual",
        "restore_policy": "scratch-only",
        "database": instance_name.replace("-", "_"),
        "postgres": {
            "primary": primary_aliases[0],
            "standbys": standby_aliases,
            "container_name": postgres_container,
        },
        "volumes": {"public_media": public_volume, "private_media": private_volume},
        "current_receipt": f"/var/lib/ai-service-platform/site-runtime/deployments/{instance_name}/current.json",
        "runtime_root": f"/opt/ai-service-platform/site-runtime/{instance_name}",
        "snapshot_id": snapshot_id or None,
        "rehearsal_id": rehearsal_id or None,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--instances", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--nodes", type=Path, required=True)
    parser.add_argument("--postgres-config", type=Path, required=True)
    parser.add_argument("--instance", required=True)
    parser.add_argument("--limit", required=True)
    parser.add_argument("--snapshot-id", default="")
    parser.add_argument("--rehearsal-id", default="")
    args = parser.parse_args()
    try:
        model = resolve_backup(
            registry_path=args.registry, instances_path=args.instances,
            state_path=args.state, nodes_path=args.nodes,
            postgres_config_path=args.postgres_config,
            instance_name=args.instance, limit=args.limit, snapshot_id=args.snapshot_id,
            rehearsal_id=args.rehearsal_id,
        )
    except (ContractError, OSError, yaml.YAMLError) as exc:
        print(f"site_runtime backup contract error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(model, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
