#!/usr/bin/env python3
"""Encrypted PostgreSQL tenant backup and scratch-only restore rehearsal."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlsplit, urlunsplit


class BackupError(RuntimeError):
    pass


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise BackupError(f"invalid environment line for key {key!r}")
        values[key] = value
    return values


def checked(command: list[str], *, env: dict[str, str]) -> bytes:
    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        check=False,
    )
    if result.returncode:
        message = result.stderr.decode("utf-8", errors="replace").strip()
        raise BackupError(f"{command[0]} failed: {message[-500:]}")
    return result.stdout


def restic_env(config: dict[str, str]) -> dict[str, str]:
    env = os.environ.copy()
    for key in ("RESTIC_REPOSITORY", "RESTIC_PASSWORD_FILE"):
        value = config.get(key)
        if not value:
            raise BackupError(f"{key} is required")
        env[key] = value
    return env


def database_url(app_env: dict[str, str]) -> str:
    value = app_env.get("DATABASE_URL")
    if not value or not value.startswith(("postgresql://", "postgres://")):
        raise BackupError("DATABASE_URL must be a PostgreSQL URL")
    parts = urlsplit(value)
    if unquote(parts.path.lstrip("/")) != "mycleanbot":
        raise BackupError("DATABASE_URL must target only the mycleanbot database")
    if unquote(parts.username or "") != "mycleanbot":
        raise BackupError("DATABASE_URL must use only the mycleanbot tenant role")
    return value


def url_with_database(url: str, database: str) -> str:
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, parts.netloc, "/" + quote(database), parts.query, ""))


def url_with_host(url: str, hostname: str) -> str:
    parts = urlsplit(url)
    if parts.scheme not in ("postgresql", "postgres") or not parts.hostname:
        raise BackupError("invalid PostgreSQL URL")
    parsed_host = ipaddress.ip_address(hostname)
    if parsed_host.version != 4:
        raise BackupError("scratch PostgreSQL host must be an IPv4 address")
    userinfo = parts.netloc.rsplit("@", 1)[0] + "@" if "@" in parts.netloc else ""
    port = f":{parts.port}" if parts.port else ""
    netloc = f"{userinfo}{parsed_host}{port}"
    return urlunsplit((parts.scheme, netloc, parts.path, parts.query, ""))


def postgres_env(url: str, *, database: str | None = None) -> dict[str, str]:
    parts = urlsplit(url)
    if parts.scheme not in ("postgresql", "postgres") or not parts.hostname:
        raise BackupError("invalid PostgreSQL URL")
    env = os.environ.copy()
    env["PGHOST"] = parts.hostname
    env["PGPORT"] = str(parts.port or 5432)
    env["PGDATABASE"] = database or unquote(parts.path.lstrip("/"))
    if parts.username:
        env["PGUSER"] = unquote(parts.username)
    if parts.password:
        env["PGPASSWORD"] = unquote(parts.password)
    query = parse_qs(parts.query)
    if query.get("sslmode"):
        env["PGSSLMODE"] = query["sslmode"][0]
    return env


def write_metric(config: dict[str, str], name: str, value: int) -> None:
    raw_path = config.get("PROMETHEUS_TEXTFILE")
    if not raw_path:
        return
    path = Path(raw_path)
    existing: dict[str, str] = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            key, separator, metric_value = line.partition(" ")
            if separator:
                existing[key] = metric_value
    existing[name] = str(value)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".new")
    temporary.write_text(
        "".join(f"{key} {existing[key]}\n" for key in sorted(existing)),
        encoding="utf-8",
    )
    os.chmod(temporary, 0o644)
    temporary.replace(path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def init_repository(config: dict[str, str]) -> dict[str, object]:
    env = restic_env(config)
    result = subprocess.run(
        ["restic", "snapshots", "--json"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
        check=False,
    )
    if result.returncode:
        checked(["restic", "init"], env=env)
    checked(["restic", "check"], env=env)
    return {"action": "init", "repository_check": "succeeded"}


def backup(config: dict[str, str], app_env: dict[str, str]) -> dict[str, object]:
    env = restic_env(config)
    db_url = database_url(app_env)
    db_env = postgres_env(db_url)
    relation_count = checked(
        [
            "psql",
            "-Atc",
            "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace "
            "where c.relkind in ('r','p') and n.nspname not in "
            "('pg_catalog','information_schema') and n.nspname not like 'pg_toast%';",
        ],
        env=db_env,
    ).decode().strip()
    if not relation_count.isdigit():
        raise BackupError("could not determine production relation count")
    backup_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    with tempfile.TemporaryDirectory(prefix="mycleanbot-backup-") as temporary:
        root = Path(temporary) / backup_id
        root.mkdir(mode=0o700)
        dump = root / "database.dump"
        with dump.open("wb") as output:
            result = subprocess.run(
                ["pg_dump", "--format=custom", "--no-owner", "--no-privileges"],
                stdout=output,
                stderr=subprocess.PIPE,
                env=db_env,
                check=False,
            )
        if result.returncode:
            raise BackupError(
                "pg_dump failed: "
                + result.stderr.decode("utf-8", errors="replace").strip()[-500:]
            )
        manifest = {
            "schema_version": 1,
            "backup_id": backup_id,
            "database": "mycleanbot",
            "dump_size": dump.stat().st_size,
            "dump_sha256": sha256(dump),
            "relation_count": int(relation_count),
        }
        (root / "manifest.json").write_text(
            json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8"
        )
        checked(
            [
                "restic",
                "backup",
                str(root),
                "--tag",
                "tenant:mycleanbot",
                "--tag",
                f"backup:{backup_id}",
            ],
            env=env,
        )
    checked(
        [
            "restic",
            "forget",
            "--tag",
            "tenant:mycleanbot",
            "--keep-daily",
            "14",
            "--keep-weekly",
            "4",
            "--keep-monthly",
            "6",
            "--prune",
        ],
        env=env,
    )
    checked(["restic", "check"], env=env)
    write_metric(
        config, "mycleanbot_backup_last_success_timestamp_seconds", int(time.time())
    )
    return {"action": "backup", "backup_id": backup_id, "repository_check": "succeeded"}


def restore_rehearsal(config: dict[str, str], app_env: dict[str, str]) -> dict[str, object]:
    env = restic_env(config)
    admin_url = config.get("POSTGRES_ADMIN_URL", "")
    if not admin_url.startswith(("postgresql://", "postgres://")):
        raise BackupError("POSTGRES_ADMIN_URL is required for scratch restore")
    if unquote(urlsplit(admin_url).username or "") == "mycleanbot":
        raise BackupError("POSTGRES_ADMIN_URL must not use the tenant role")
    scratch_host = os.environ.get("MYCLEANBOT_SCRATCH_POSTGRES_HOST", "")
    if not scratch_host:
        raise BackupError("MYCLEANBOT_SCRATCH_POSTGRES_HOST is required")
    admin_url = url_with_host(admin_url, scratch_host)
    app_url = database_url(app_env)
    username = urlsplit(app_url).username
    if not username:
        raise BackupError("DATABASE_URL has no tenant username")
    scratch = "restore_mycleanbot_" + time.strftime("%Y%m%d%H%M%S", time.gmtime())
    admin_env = postgres_env(admin_url)
    scratch_env = postgres_env(admin_url, database=scratch)
    created = False
    with tempfile.TemporaryDirectory(prefix="mycleanbot-restore-") as temporary:
        try:
            checked(
                [
                    "createdb",
                    "--owner",
                    username,
                    scratch,
                ],
                env=admin_env,
            )
            created = True
            checked(
                [
                    "restic",
                    "restore",
                    "latest",
                    "--tag",
                    "tenant:mycleanbot",
                    "--target",
                    temporary,
                ],
                env=env,
            )
            dumps = list(Path(temporary).rglob("database.dump"))
            manifests = list(Path(temporary).rglob("manifest.json"))
            if len(dumps) != 1 or len(manifests) != 1:
                raise BackupError(
                    "restored snapshot must contain one database.dump and one manifest.json"
                )
            manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
            if (
                manifest.get("database") != "mycleanbot"
                or manifest.get("dump_size") != dumps[0].stat().st_size
                or manifest.get("dump_sha256") != sha256(dumps[0])
            ):
                raise BackupError("restored dump does not match the MyCleanBot manifest")
            checked(
                [
                    "pg_restore",
                    "--no-owner",
                    "--no-privileges",
                    "--dbname",
                    scratch,
                    str(dumps[0]),
                ],
                env=scratch_env,
            )
            relation_count = checked(
                [
                    "psql",
                    "-Atc",
                    "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace "
                    "where c.relkind in ('r','p') and n.nspname not in "
                    "('pg_catalog','information_schema') and n.nspname not like 'pg_toast%';",
                ],
                env=scratch_env,
            ).decode().strip()
            if (
                not relation_count.isdigit()
                or int(relation_count) != manifest.get("relation_count")
            ):
                raise BackupError(
                    "scratch restore relation count does not match the backup manifest"
                )
        finally:
            if created:
                checked(
                    ["dropdb", "--if-exists", scratch],
                    env=admin_env,
                )
    write_metric(
        config,
        "mycleanbot_restore_rehearsal_last_success_timestamp_seconds",
        int(time.time()),
    )
    return {
        "action": "restore-rehearsal",
        "production_unchanged": True,
        "scratch_removed": True,
        "database_nonempty": int(relation_count) > 0,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("init", "backup", "restore-rehearsal"))
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--app-env", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.config.stat().st_mode & 0o077:
            raise BackupError("backup config must not be accessible by group or others")
        if args.app_env.stat().st_mode & 0o077:
            raise BackupError("application env must not be accessible by group or others")
        config = load_env(args.config)
        app_env = load_env(args.app_env)
        password_file = Path(config.get("RESTIC_PASSWORD_FILE", ""))
        if not password_file.is_file() or password_file.stat().st_mode & 0o077:
            raise BackupError("Restic password file must exist with mode 0600")
        if args.action == "init":
            result = init_repository(config)
        elif args.action == "backup":
            result = backup(config, app_env)
        else:
            result = restore_rehearsal(config, app_env)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (BackupError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"postgres tenant backup error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
