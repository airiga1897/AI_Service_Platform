#!/usr/bin/env python3
"""Формирует минимальное production-окружение site_runtime без утечки PG-секретов."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import yaml


def read_env(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"{path}:{number}: ожидается KEY=VALUE")
        key, value = line.split("=", 1)
        result[key.strip()] = value.strip()
    return result


def resolve_env(app_secret: Path, postgres_config: Path, postgres_secrets: Path, instance: str) -> dict[str, str]:
    app = read_env(app_secret)
    secret_key = app.pop("SECRET_KEY", "")
    if len(secret_key) < 50 or "change" in secret_key.lower() or "placeholder" in secret_key.lower():
        raise ValueError("SECRET_KEY должен быть уникальным production-секретом длиной не менее 50 символов")
    forbidden = {
        key for key in app
        if key == "DATABASE_URL" or key.startswith("DB_") or key.startswith("POSTGRES_")
        or key.startswith("DJANGO_SUPERUSER_")
    }
    if forbidden:
        raise ValueError("application secret не должен содержать пароль PostgreSQL: " + ", ".join(sorted(forbidden)))
    document = yaml.safe_load(postgres_config.read_text(encoding="utf-8")) or {}
    config = document.get("postgres_runtime") if isinstance(document.get("postgres_runtime"), dict) else document
    managed = (config.get("managed_databases") or {}).get(instance) or {}
    if managed.get("database") != instance.replace("-", "_") or managed.get("owner_role") != instance.replace("-", "_"):
        raise ValueError("managed PostgreSQL database/role не соответствует instance")
    password_key = managed.get("password_secret")
    pg_secrets = read_env(postgres_secrets)
    password = pg_secrets.get(str(password_key), "")
    if not password:
        raise ValueError(f"в postgres secrets отсутствует {password_key}")
    return {
        "SECRET_KEY": secret_key,
        "DB_PASSWORD": password,
        **app,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-secret", required=True, type=Path)
    parser.add_argument("--postgres-config", required=True, type=Path)
    parser.add_argument("--postgres-secrets", required=True, type=Path)
    parser.add_argument("--instance", required=True)
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    try:
        result = resolve_env(args.app_secret, args.postgres_config, args.postgres_secrets, args.instance)
    except (OSError, ValueError, yaml.YAMLError) as exc:
        print(f"site_runtime secret contract error: {exc}", file=__import__('sys').stderr)
        return 2
    if args.validate_only:
        print("site_runtime secret contract valid")
    else:
        print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
