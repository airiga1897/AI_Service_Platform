#!/usr/bin/env python3
"""Ручной Restic backup и изолированная репетиция восстановления site_runtime."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


PASSWORD_RE = re.compile(r"RESTIC_PASSWORD=(\S{24,})")
HEX_RE = re.compile(r"[0-9a-f]{8,64}")
ANSIBLE_SSH_KEY = "/home/ansible/.ssh/ansible_control"
ANSIBLE_KNOWN_HOSTS = "/home/ansible/.ssh/known_hosts"


class BackupError(RuntimeError):
    pass


def _run(argv: list[str], *, env: dict[str, str] | None = None, cwd: Path | None = None,
         stdin: bytes | None = None, text: bool = True) -> subprocess.CompletedProcess[Any]:
    return subprocess.run(
        argv, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        check=False, env=env, cwd=cwd, text=text,
    )


def _checked(argv: list[str], **kwargs: Any) -> subprocess.CompletedProcess[Any]:
    result = _run(argv, **kwargs)
    if result.returncode:
        stderr = result.stderr if isinstance(result.stderr, str) else result.stderr.decode("utf-8", "replace")
        raise BackupError(f"Команда завершилась с кодом {result.returncode}: {argv[0]}: {stderr.strip()}")
    return result


def _ssh(model: dict[str, Any], alias: str, command: str, *, stdin: bytes | None = None,
         text: bool = True) -> subprocess.CompletedProcess[Any]:
    endpoint = model["nodes"][alias]
    return _checked([
        "ssh", "-i", ANSIBLE_SSH_KEY, "-o", "BatchMode=yes",
        "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", f"UserKnownHostsFile={ANSIBLE_KNOWN_HOSTS}",
        f"ansible@{endpoint}", command,
    ], stdin=stdin, text=text)


def _ssh_result(model: dict[str, Any], alias: str, command: str) -> subprocess.CompletedProcess[str]:
    endpoint = model["nodes"][alias]
    return _run([
        "ssh", "-i", ANSIBLE_SSH_KEY, "-o", "BatchMode=yes",
        "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", f"UserKnownHostsFile={ANSIBLE_KNOWN_HOSTS}",
        f"ansible@{endpoint}", command,
    ])


def _read_json_remote(model: dict[str, Any], alias: str, path: str) -> dict[str, Any]:
    raw = _ssh(model, alias, f"sudo -n cat {shlex_quote(path)}").stdout
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise BackupError(f"JSON receipt {path} должен содержать object")
    return value


def shlex_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _secret(path: Path) -> str:
    lines = path.read_text(encoding="utf-8-sig").splitlines()
    meaningful = [line.strip() for line in lines if line.strip() and not line.lstrip().startswith("#")]
    if len(meaningful) != 1:
        raise BackupError("backup secret должен содержать только RESTIC_PASSWORD")
    match = PASSWORD_RE.fullmatch(meaningful[0])
    if not match:
        raise BackupError("RESTIC_PASSWORD отсутствует или недостаточно длинный")
    return match.group(1)


def _restic_env(model: dict[str, Any], password: str) -> dict[str, str]:
    env = os.environ.copy()
    target = model["backup_target"]
    endpoint = model["nodes"][target["alias"]]
    env.update({
        "RESTIC_PASSWORD": password,
        "RESTIC_REPOSITORY": f"sftp:ansible@{endpoint}:{target['repository']}",
    })
    return env


def _restic(model: dict[str, Any], password: str, *args: str,
            cwd: Path | None = None, checked: bool = True) -> subprocess.CompletedProcess[str]:
    target = model["backup_target"]
    endpoint = model["nodes"][target["alias"]]
    if re.fullmatch(r"[A-Za-z0-9.-]+", endpoint) is None:
        raise BackupError("Недопустимый endpoint backup target для Restic SFTP")
    sftp_command = (
        f"ssh -i {ANSIBLE_SSH_KEY} "
        "-o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes "
        f"-o UserKnownHostsFile={ANSIBLE_KNOWN_HOSTS} "
        f"ansible@{endpoint} -s sftp"
    )
    command = [
        "restic", "-o",
        f"sftp.command={sftp_command}",
        *args,
    ]
    return _checked(command, env=_restic_env(model, password), cwd=cwd) if checked else _run(
        command, env=_restic_env(model, password), cwd=cwd,
    )


def _repository_state(model: dict[str, Any]) -> str:
    target = model["backup_target"]
    repository = shlex_quote(target["repository"])
    command = (
        f"repository={repository}; "
        "if [ ! -d \"$repository\" ]; then printf missing; "
        "elif [ \"$(stat -c %U \"$repository\")\" != ansible ]; then printf invalid_owner; "
        "elif [ \"$(stat -c %a \"$repository\")\" != 700 ]; then printf invalid_mode; "
        "elif [ -f \"$repository/config\" ]; then printf initialized; "
        "elif find \"$repository\" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; "
        "then printf nonempty_without_config; else printf empty; fi"
    )
    state = _ssh(model, target["alias"], command).stdout.strip()
    allowed = {"missing", "invalid_owner", "invalid_mode", "initialized", "nonempty_without_config", "empty"}
    if state not in allowed:
        raise BackupError("Backup target вернул неизвестное состояние Restic repository")
    return state


def _postgres_container(model: dict[str, Any]) -> str:
    container = str(model["postgres"]["container_name"])
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]+", container) is None:
        raise BackupError("Некорректное имя контейнера PostgreSQL в backup-модели")
    return container


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _tar_count(path: Path) -> int:
    with tarfile.open(path, "r:") as archive:
        return sum(1 for member in archive if member.isfile() or member.issym())


def _utc_id() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def _control_root(model: dict[str, Any]) -> Path:
    return Path(f"/var/lib/ai-service-platform/site-runtime-backup/{model['instance']}")


def _preflight(model: dict[str, Any], password: str, *, require_repository: bool) -> dict[str, Any]:
    runtime = model["runtime_alias"]
    postgres_container = shlex_quote(_postgres_container(model))
    current = _read_json_remote(model, runtime, model["current_receipt"])
    required = {"deployment_id", "digest", "compose_checksum", "storage"}
    if not required.issubset(current) or not str(current["digest"]).startswith("sha256:"):
        raise BackupError("current.json не соответствует принятому deployment contract")
    storage = current["storage"]
    for key, expected in model["volumes"].items():
        if storage.get(key) != expected:
            raise BackupError(f"current.json содержит неожиданный storage identity: {key}")
        _ssh(model, runtime, f"sudo -n docker volume inspect {shlex_quote(expected)} >/dev/null")

    runtime_services = ("anchor", "redis", "web", "worker", "beat", "nginx")
    for service in runtime_services:
        container = _runtime_container(model, service)
        running = _ssh(
            model,
            runtime,
            "sudo -n docker inspect --format '{{.State.Running}}' " + shlex_quote(container),
        ).stdout.strip()
        if running != "true":
            raise BackupError(f"Обязательный runtime-контейнер {service} не запущен")
    if not _private_health(model, attempts=1, delay_seconds=0):
        raise BackupError("Private runtime не прошёл health preflight")

    primary = model["postgres"]["primary"]
    primary_state = _ssh(
        model, primary,
        f"sudo -n docker exec {postgres_container} sh -ec 'psql -U \"$POSTGRES_USER\" -d postgres -Atqc \"select not pg_is_in_recovery()\"'",
    ).stdout.strip()
    if primary_state != "t":
        raise BackupError("PostgreSQL primary находится в recovery")
    replication = _ssh(
        model, primary,
        f"sudo -n docker exec -i {postgres_container} sh -ec 'psql -U \"$POSTGRES_USER\" -d postgres -At'",
        stdin=b"select count(*) from pg_stat_replication where state='streaming' and sync_state='async';\n",
        text=False,
    ).stdout.decode().strip()
    if replication != "2":
        raise BackupError("PostgreSQL contract требует две streaming/async реплики")
    for standby in model["postgres"]["standbys"]:
        state = _ssh(
            model, standby,
            f"sudo -n docker exec -i {postgres_container} sh -ec 'psql -U \"$POSTGRES_USER\" -d postgres -At'",
            stdin=b"select pg_is_in_recovery() and exists(select 1 from pg_stat_wal_receiver where status='streaming');\n",
            text=False,
        ).stdout.decode().strip()
        if state != "t":
            raise BackupError(f"PostgreSQL standby {standby} не принимает WAL")

    target = model["backup_target"]
    capacity = _ssh(
        model, target["alias"],
        f"df -Pk {shlex_quote(str(Path(target['repository']).parent))} | awk 'NR==2 {{print $4 * 1024}}'",
    ).stdout.strip()
    if not capacity.isdigit() or int(capacity) < 2 * 1024**3:
        raise BackupError("На backup target осталось менее 2 GiB")
    if require_repository:
        _restic(model, password, "snapshots", "--json")
    return {
        "current": current,
        "target_free_bytes": int(capacity),
        "postgres_streaming_standbys": 2,
        "runtime_containers_running": len(runtime_services),
        "private_health": "succeeded",
    }


def backup_init(model: dict[str, Any], password: str, *, check: bool) -> dict[str, Any]:
    target = model["backup_target"]
    if check:
        return {"action": "backup-init", "check_mode_mutations": False, "repository_initialized": None,
                "target_alias": target["alias"], "repository": target["repository"]}
    state = _repository_state(model)
    if state == "missing":
        raise BackupError("Каталог Restic repository отсутствует на backup target")
    if state == "invalid_owner":
        raise BackupError("Каталог Restic repository должен принадлежать пользователю ansible")
    if state == "invalid_mode":
        raise BackupError("Каталог Restic repository должен иметь режим доступа 0700")
    if state == "nonempty_without_config":
        raise BackupError("Непустой каталог Restic repository не содержит config; инициализация запрещена")

    initialized = state == "initialized"
    if initialized:
        snapshots = _restic(model, password, "snapshots", "--json", checked=False)
        if snapshots.returncode != 0:
            raise BackupError(f"Не удалось проверить существующий Restic repository: {snapshots.stderr.strip()}")
    else:
        _restic(model, password, "init")
    _restic(model, password, "check")
    return {"action": "backup-init", "check_mode_mutations": False,
            "repository_initialized": True, "already_initialized": initialized,
            "target_alias": target["alias"], "repository": target["repository"]}


def _media_archive(model: dict[str, Any], volume: str, image_id: str, destination: Path) -> int:
    script = "import sys,tarfile; t=tarfile.open(fileobj=sys.stdout.buffer,mode='w|'); t.add('/data',arcname='.'); t.close()"
    result = _ssh(
        model, model["runtime_alias"],
        "sudo -n docker run --rm --pull never "
        f"-v {shlex_quote(volume + ':/data:ro')} --entrypoint python {shlex_quote(image_id)} "
        f"-c {shlex_quote(script)}", text=False,
    )
    destination.write_bytes(result.stdout)
    return _tar_count(destination)


def _runtime_container(model: dict[str, Any], service: str) -> str:
    instance = str(model["instance"])
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", instance):
        raise BackupError("Некорректный instance в backup-модели")
    if service == "anchor":
        return f"site-runtime-{instance}-anchor"
    if service not in {"redis", "web", "worker", "beat", "nginx"}:
        raise BackupError("Неизвестный сервис site_runtime в backup-модели")
    return f"{instance}-{service}-1"


def _private_health(model: dict[str, Any], *, attempts: int, delay_seconds: int) -> bool:
    runtime = model["runtime_alias"]
    compose = f"{model['runtime_root']}/docker-compose.yml"
    health_cmd = (
        f"sudo -n docker compose -f {shlex_quote(compose)} exec -T web python -c "
        + shlex_quote(
            "import urllib.request; "
            "[urllib.request.urlopen('http://127.0.0.1:8080'+p,timeout=5).read() "
            "for p in ('/healthz/','/readyz/','/worker-healthz/')]"
        )
    )
    for attempt in range(attempts):
        if _ssh_result(model, runtime, health_cmd).returncode == 0:
            return True
        if attempt + 1 < attempts:
            time.sleep(delay_seconds)
    return False


def _postgres_shell(model: dict[str, Any], command: str, *arguments: str,
                    stdin: bytes | None = None) -> str:
    interactive = " -i" if stdin is not None else ""
    quoted_arguments = "".join(f" {shlex_quote(argument)}" for argument in arguments)
    return (
        f"sudo -n docker exec{interactive} {shlex_quote(_postgres_container(model))} "
        f"sh -ec {shlex_quote(command)} sh"
        f"{quoted_arguments}"
    )


def _migration_ledger(model: dict[str, Any], database: str) -> str:
    query = (
        b"select app || E'\\t' || name from django_migrations "
        b"order by app, name;\n"
    )
    return _ssh(
        model,
        model["postgres"]["primary"],
        _postgres_shell(
            model, 'psql -U "$POSTGRES_USER" -d "$1" -At', database, stdin=b"",
        ),
        stdin=query,
        text=False,
    ).stdout.decode().strip()


def backup(model: dict[str, Any], password: str, *, check: bool) -> dict[str, Any]:
    preflight = _preflight(model, password, require_repository=True)
    if check:
        return {"action": "backup", "check_mode_mutations": False, "snapshot_created": False,
                "deployment_id": preflight["current"]["deployment_id"],
                "datasets": model["datasets"], "target_free_bytes": preflight["target_free_bytes"],
                "runtime_containers_running": preflight["runtime_containers_running"],
                "private_health": preflight["private_health"]}

    backup_id = _utc_id()
    control_root = _control_root(model)
    journal_root = control_root / "journal"
    journal_root.mkdir(parents=True, exist_ok=True, mode=0o750)
    staging = Path(tempfile.mkdtemp(prefix=f"backup-{backup_id}-", dir=control_root))
    runtime = model["runtime_alias"]
    compose = f"{model['runtime_root']}/docker-compose.yml"
    final_status = "failed"
    snapshot_id: str | None = None
    writers_restart_required = False
    output: dict[str, Any] | None = None
    health = "not_checked"
    health_error: BackupError | None = None
    try:
        writers_restart_required = True
        _ssh(model, runtime, f"sudo -n docker compose -f {shlex_quote(compose)} stop web worker beat")
        database_path = staging / "database.dump"
        dump = _ssh(
            model, model["postgres"]["primary"],
            f"sudo -n docker exec {shlex_quote(_postgres_container(model))} "
            "sh -ec 'pg_dump -U \"$POSTGRES_USER\" -d " + model["database"] + " -Fc'",
            text=False,
        )
        database_path.write_bytes(dump.stdout)
        image_id = _ssh(
            model, runtime,
            f"sudo -n docker inspect --format '{{{{.Image}}}}' "
            f"{shlex_quote(_runtime_container(model, 'web'))}",
        ).stdout.strip()
        counts = {
            "database_objects": None,
            "public_media": _media_archive(model, model["volumes"]["public_media"], image_id, staging / "public_media.tar"),
            "private_media": _media_archive(model, model["volumes"]["private_media"], image_id, staging / "private_media.tar"),
        }
        files = {}
        for name in ("database.dump", "public_media.tar", "private_media.tar"):
            path = staging / name
            files[name] = {"size": path.stat().st_size, "sha256": _sha256(path)}
        current = preflight["current"]
        manifest = {
            "schema_version": 1, "backup_id": backup_id,
            "created_at": datetime.now(UTC).isoformat(), "instance": model["instance"],
            "deployment_id": current["deployment_id"], "digest": current["digest"],
            "compose_checksum": current["compose_checksum"], "storage": current["storage"],
            "datasets": model["datasets"], "counts": counts, "files": files,
        }
        (staging / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        result = _restic(
            model, password, "backup", staging.name, "--json",
            "--tag", f"site-runtime:{model['instance']}",
            "--tag", f"deployment:{current['deployment_id']}", cwd=staging.parent,
        )
        for line in result.stdout.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("message_type") == "summary":
                snapshot_id = event.get("snapshot_id")
        if not snapshot_id or not HEX_RE.fullmatch(snapshot_id):
            raise BackupError("Restic не вернул корректный snapshot ID")
        final_status = "succeeded"
        output = {"action": "backup", "snapshot_id": snapshot_id, "backup_id": backup_id,
                  "deployment_id": current["deployment_id"], "final_status": final_status,
                  "writers_restarted": False, "private_health": "pending"}
    finally:
        if writers_restart_required:
            restart = _ssh_result(model, runtime, f"sudo -n docker compose -f {shlex_quote(compose)} up -d --no-build --pull never web worker beat")
            if restart.returncode == 0:
                health = (
                    "succeeded"
                    if _private_health(model, attempts=20, delay_seconds=3)
                    else "failed"
                )
            else:
                health = "failed"
        if output is not None:
            output["private_health"] = health
            output["writers_restarted"] = health == "succeeded"
            if health != "succeeded":
                output["final_status"] = "failed"
                final_status = "failed"
                health_error = BackupError("После backup не пройдена проверка private runtime")
        journal = {"backup_id": backup_id, "snapshot_id": snapshot_id, "final_status": final_status,
                   "snapshot_accepted": final_status == "succeeded",
                   "health_after_restart": health, "plaintext_staging_removed": True}
        try:
            (journal_root / f"{backup_id}.json").write_text(
                json.dumps(journal, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
            )
        finally:
            shutil.rmtree(staging, ignore_errors=True)
    if health_error is not None:
        raise health_error
    if output is None:
        raise BackupError("Backup завершился без результата")
    return output


def _verify_restored(root: Path) -> tuple[dict[str, Any], Path]:
    manifests = list(root.rglob("manifest.json"))
    if len(manifests) != 1:
        raise BackupError("В snapshot должен находиться ровно один manifest.json")
    manifest_path = manifests[0]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for name, expected in manifest["files"].items():
        path = manifest_path.parent / name
        if not path.is_file() or path.stat().st_size != expected["size"] or _sha256(path) != expected["sha256"]:
            raise BackupError(f"Checksum восстановленного файла не совпадает: {name}")
    return manifest, manifest_path.parent


def restore_rehearsal(model: dict[str, Any], password: str, *, check: bool) -> dict[str, Any]:
    preflight = _preflight(model, password, require_repository=True)
    snapshot = str(model.get("snapshot_id") or "")
    if not snapshot:
        raise BackupError("restore-rehearsal требует snapshot ID")
    _restic(model, password, "snapshots", snapshot, "--json")
    if check:
        return {"action": "restore-rehearsal", "snapshot_id": snapshot,
                "check_mode_mutations": False, "scratch_created": False,
                "production_unchanged": True, "deployment_id": preflight["current"]["deployment_id"]}

    rehearsal_id = f"{_utc_id()}-{snapshot[:12]}"
    safe_id = re.sub(r"[^a-z0-9]", "", rehearsal_id.lower())[-32:]
    scratch_db = f"restore_ai_retail_{safe_id}"
    scratch_volumes = {
        "public_media": f"ai_retail_mvp_restore_{safe_id}_public",
        "private_media": f"ai_retail_mvp_restore_{safe_id}_private",
    }
    root = _control_root(model)
    journal_root = root / "restore-journal"
    journal_root.mkdir(parents=True, exist_ok=True, mode=0o750)
    restored = Path(tempfile.mkdtemp(prefix=f"restore-{safe_id}-", dir=root))
    status = "failed"
    cleanup_requested = False
    cleanup_succeeded = False
    cleanup_error: BackupError | None = None
    output: dict[str, Any] | None = None
    try:
        _restic(model, password, "restore", snapshot, "--target", str(restored))
        manifest, data = _verify_restored(restored)
        if manifest["instance"] != model["instance"]:
            raise BackupError("Snapshot принадлежит другому instance")
        current = preflight["current"]
        for field in ("deployment_id", "digest", "compose_checksum", "storage"):
            if manifest.get(field) != current.get(field):
                raise BackupError(
                    f"Snapshot {field} не совпадает с текущим принятым deployment"
                )
        primary = model["postgres"]["primary"]
        _ssh(
            model, primary,
            _postgres_shell(
                model,
                'dropdb -U "$POSTGRES_USER" --if-exists "$1"; '
                'createdb -U "$POSTGRES_USER" -O "$2" "$1"',
                scratch_db, model["database"],
            ),
        )
        dump = (data / "database.dump").read_bytes()
        _ssh(
            model, primary,
            _postgres_shell(
                model,
                'pg_restore -U "$POSTGRES_USER" --no-owner --no-privileges -d "$1"', scratch_db,
                stdin=dump,
            ),
            stdin=dump, text=False,
        )
        vector = _ssh(
            model, primary,
            _postgres_shell(model, 'psql -U "$POSTGRES_USER" -d "$1" -At', scratch_db, stdin=b""),
            stdin=b"select count(*) from pg_extension where extname='vector';\n", text=False,
        ).stdout.decode().strip()
        if vector != "1":
            raise BackupError("В scratch DB отсутствует extension vector")
        relation_count = _ssh(
            model,
            primary,
            _postgres_shell(
                model, 'psql -U "$POSTGRES_USER" -d "$1" -At', scratch_db, stdin=b"",
            ),
            stdin=(
                b"select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace "
                b"where c.relkind in ('r','p') and n.nspname not in "
                b"('pg_catalog','information_schema') and n.nspname not like 'pg_toast%';\n"
            ),
            text=False,
        ).stdout.decode().strip()
        if not relation_count.isdigit() or int(relation_count) < 1:
            raise BackupError("В scratch DB отсутствуют пользовательские таблицы")
        scratch_migrations = _migration_ledger(model, scratch_db)
        production_migrations = _migration_ledger(model, model["database"])
        if not scratch_migrations or scratch_migrations != production_migrations:
            raise BackupError("Migration ledger scratch DB не совпадает с production DB")
        runtime = model["runtime_alias"]
        image_id = _ssh(
            model, runtime,
            f"sudo -n docker inspect --format '{{{{.Image}}}}' "
            f"{shlex_quote(_runtime_container(model, 'web'))}",
        ).stdout.strip()
        for key, volume in scratch_volumes.items():
            _ssh(model, runtime, f"sudo -n docker volume create {shlex_quote(volume)} >/dev/null")
            script = "import sys,tarfile; tarfile.open(fileobj=sys.stdin.buffer,mode='r|').extractall('/data',filter='data')"
            _ssh(model, runtime, "sudo -n docker run -i --rm --pull never " + f"-v {shlex_quote(volume + ':/data')} --entrypoint python {shlex_quote(image_id)} -c {shlex_quote(script)}", stdin=(data / f"{key}.tar").read_bytes(), text=False)
            count_script = "import os; print(sum(len(f) for _,_,f in os.walk('/data')))"
            count = int(_ssh(model, runtime, "sudo -n docker run --rm --pull never " + f"-v {shlex_quote(volume + ':/data:ro')} --entrypoint python {shlex_quote(image_id)} -c {shlex_quote(count_script)}").stdout.strip())
            if count != int(manifest["counts"][key]):
                raise BackupError(f"Количество объектов scratch {key} не совпадает с manifest")
        status = "succeeded"
        cleanup_requested = True
        output = {"action": "restore-rehearsal", "snapshot_id": snapshot, "rehearsal_id": rehearsal_id,
                  "final_status": status, "vector": True, "migrations": "current",
                  "database_nonempty": True, "database_relations": int(relation_count),
                  "migration_ledger_match": True,
                  "storage_counts_valid": True, "production_unchanged": True, "scratch_removed": True}
    finally:
        if cleanup_requested:
            try:
                _ssh(
                    model, model["postgres"]["primary"],
                    _postgres_shell(
                        model, 'dropdb -U "$POSTGRES_USER" --if-exists "$1"', scratch_db,
                    ),
                )
                for volume in scratch_volumes.values():
                    _ssh(model, model["runtime_alias"], f"sudo -n docker volume rm {shlex_quote(volume)} >/dev/null")
                shutil.rmtree(restored, ignore_errors=True)
                cleanup_succeeded = True
            except BackupError as exc:
                status = "failed"
                cleanup_error = BackupError(f"Не удалось удалить scratch-объекты: {exc}")
        journal = {"rehearsal_id": rehearsal_id, "snapshot_id": snapshot, "final_status": status,
                   "production_unchanged": True,
                   "scratch_preserved_for_diagnostics": not cleanup_succeeded}
        (journal_root / f"{rehearsal_id}.json").write_text(json.dumps(journal, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if cleanup_error is not None:
        raise cleanup_error
    if output is None:
        raise BackupError("Restore rehearsal завершился без результата")
    return output


def restore_cleanup(model: dict[str, Any], password: str, *, check: bool) -> dict[str, Any]:
    _preflight(model, password, require_repository=False)
    rehearsal_id = str(model.get("rehearsal_id") or "")
    if re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}", rehearsal_id) is None:
        raise BackupError("restore-cleanup требует точный rehearsal ID")

    root = _control_root(model)
    journal_path = root / "restore-journal" / f"{rehearsal_id}.json"
    journal = json.loads(journal_path.read_text(encoding="utf-8"))
    if (
        journal.get("rehearsal_id") != rehearsal_id
        or journal.get("final_status") != "failed"
        or journal.get("production_unchanged") is not True
        or journal.get("scratch_preserved_for_diagnostics") is not True
    ):
        raise BackupError("restore-cleanup разрешён только для подтверждённого failed journal")

    safe_id = re.sub(r"[^a-z0-9]", "", rehearsal_id.lower())[-32:]
    scratch_db = f"restore_ai_retail_{safe_id}"
    scratch_volumes = (
        f"ai_retail_mvp_restore_{safe_id}_public",
        f"ai_retail_mvp_restore_{safe_id}_private",
    )
    database_present = _ssh(
        model,
        model["postgres"]["primary"],
        _postgres_shell(
            model, 'psql -U "$POSTGRES_USER" -d postgres -At', stdin=b"",
        ),
        stdin=(
            "select count(*) from pg_database where datname="
            f"'{scratch_db}';\n"
        ).encode(),
        text=False,
    ).stdout.decode().strip() == "1"
    volumes_present = [
        volume
        for volume in scratch_volumes
        if _ssh_result(
            model,
            model["runtime_alias"],
            f"sudo -n docker volume inspect {shlex_quote(volume)} >/dev/null",
        ).returncode == 0
    ]
    root_resolved = root.resolve()
    staging = [
        path
        for path in root.glob(f"restore-{safe_id}-*")
        if path.is_dir() and path.resolve().parent == root_resolved
    ]
    inventory = {
        "scratch_database_present": database_present,
        "scratch_volumes_present": len(volumes_present),
        "staging_directories_present": len(staging),
    }
    if check:
        return {
            "action": "restore-cleanup",
            "rehearsal_id": rehearsal_id,
            "check_mode_mutations": False,
            "cleanup_performed": False,
            **inventory,
        }

    cleanup_id = _utc_id()
    cleanup_root = root / "restore-cleanup-journal"
    cleanup_root.mkdir(parents=True, exist_ok=True, mode=0o750)
    removed_database = False
    removed_volumes = 0
    removed_staging = 0
    final_status = "failed"
    try:
        if database_present:
            _ssh(
                model,
                model["postgres"]["primary"],
                _postgres_shell(
                    model, 'dropdb -U "$POSTGRES_USER" --if-exists "$1"', scratch_db,
                ),
            )
            removed_database = True
        for volume in volumes_present:
            _ssh(
                model,
                model["runtime_alias"],
                f"sudo -n docker volume rm {shlex_quote(volume)} >/dev/null",
            )
            removed_volumes += 1
        for path in staging:
            shutil.rmtree(path)
            removed_staging += 1
        final_status = "succeeded"
    finally:
        cleanup_journal = {
            "cleanup_id": cleanup_id,
            "rehearsal_id": rehearsal_id,
            "final_status": final_status,
            "production_unchanged": True,
            "scratch_database_removed": removed_database,
            "scratch_volumes_removed": removed_volumes,
            "staging_directories_removed": removed_staging,
        }
        (cleanup_root / f"{cleanup_id}-{rehearsal_id}.json").write_text(
            json.dumps(cleanup_journal, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    return {
        "action": "restore-cleanup",
        "rehearsal_id": rehearsal_id,
        "final_status": final_status,
        "production_unchanged": True,
        "scratch_database_removed": removed_database,
        "scratch_volumes_removed": removed_volumes,
        "staging_directories_removed": removed_staging,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--action",
        choices=("backup-init", "backup", "restore-rehearsal", "restore-cleanup"),
        required=True,
    )
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--secret", type=Path, required=True)
    parser.add_argument("--nodes", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        model = json.loads(args.model.read_text(encoding="utf-8"))
        with args.nodes.open(newline="", encoding="utf-8-sig") as handle:
            import csv
            model["nodes"] = {row["current_alias"]: row["endpoint"] for row in csv.DictReader(handle)}
        password = _secret(args.secret)
        lock_path = Path(f"/var/lock/ai-service-platform-site-runtime-{model['instance']}.lock")
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open("w", encoding="utf-8") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if args.action == "backup-init":
                result = backup_init(model, password, check=args.check)
            elif args.action == "backup":
                result = backup(model, password, check=args.check)
            elif args.action == "restore-rehearsal":
                result = restore_rehearsal(model, password, check=args.check)
            else:
                result = restore_cleanup(model, password, check=args.check)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except (BackupError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"site_runtime backup error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
