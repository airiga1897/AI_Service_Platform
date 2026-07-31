#!/usr/bin/env python3
"""Create or audit the isolated platform-owned MyCleanBot PostgreSQL tenant."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import subprocess
import sys
from urllib.parse import parse_qs, unquote, urlsplit


class ProvisionError(RuntimeError):
    pass


def postgres_env(url: str) -> dict[str, str]:
    parts = urlsplit(url)
    if parts.scheme not in ("postgresql", "postgres") or not parts.hostname:
        raise ProvisionError("POSTGRES_ADMIN_URL must be a PostgreSQL URL")
    env = os.environ.copy()
    env.update(
        {
            "PGHOST": parts.hostname,
            "PGPORT": str(parts.port or 5432),
            "PGDATABASE": unquote(parts.path.lstrip("/")) or "postgres",
        }
    )
    if parts.username:
        env["PGUSER"] = unquote(parts.username)
    if parts.password:
        env["PGPASSWORD"] = unquote(parts.password)
    query = parse_qs(parts.query)
    if query.get("sslmode"):
        env["PGSSLMODE"] = query["sslmode"][0]
    return env


def psql(env: dict[str, str], sql: str) -> str:
    result = subprocess.run(
        ["psql", "-X", "-v", "ON_ERROR_STOP=1", "-At"],
        input=sql.encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        check=False,
    )
    if result.returncode:
        raise ProvisionError(
            "psql failed: " + result.stderr.decode(errors="replace").strip()[-500:]
        )
    return result.stdout.decode().strip()


def audit(env: dict[str, str]) -> dict[str, object]:
    role = psql(
        env,
        "select count(*) from pg_roles where rolname='mycleanbot' and not rolsuper "
        "and not rolcreatedb and not rolcreaterole and not rolreplication;\n",
    )
    database = psql(
        env,
        "select count(*) from pg_database d join pg_roles r on r.oid=d.datdba "
        "where d.datname='mycleanbot' and r.rolname='mycleanbot';\n",
    )
    memberships = psql(
        env,
        "select count(*) from pg_auth_members m join pg_roles r on r.oid=m.member "
        "where r.rolname='mycleanbot';\n",
    )
    return {
        "role_is_restricted": role == "1",
        "database_owned_by_tenant": database == "1",
        "role_memberships": int(memberships or "0"),
    }


def apply(env: dict[str, str], password: str) -> dict[str, object]:
    existing = psql(
        env,
        "select (select count(*) from pg_roles where rolname='mycleanbot') || ':' || "
        "(select count(*) from pg_database where datname='mycleanbot');\n",
    )
    if existing != "0:0":
        raise ProvisionError("mycleanbot role or database already exists; refusing overwrite")
    escaped = password.replace("'", "''")
    psql(
        env,
        "CREATE ROLE mycleanbot LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE "
        f"NOREPLICATION PASSWORD '{escaped}';\n",
    )
    try:
        psql(env, "CREATE DATABASE mycleanbot OWNER mycleanbot;\n")
    except ProvisionError:
        psql(env, "DROP ROLE mycleanbot;\n")
        raise
    result = audit(env)
    if result != {
        "role_is_restricted": True,
        "database_owned_by_tenant": True,
        "role_memberships": 0,
    }:
        raise ProvisionError("tenant audit failed after creation")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("plan", "audit", "apply"))
    args = parser.parse_args(argv)
    try:
        if args.action == "plan":
            result: dict[str, object] = {
                "action": "plan",
                "database": "mycleanbot",
                "role": "mycleanbot",
                "mutations": False,
            }
        else:
            admin_url = os.environ.get("POSTGRES_ADMIN_URL", "")
            env = postgres_env(admin_url)
            if args.action == "audit":
                result = {"action": "audit", **audit(env)}
            else:
                password = getpass.getpass("New MyCleanBot database password: ")
                if len(password) < 24:
                    raise ProvisionError(
                        "database password must contain at least 24 characters"
                    )
                result = {"action": "apply", **apply(env, password)}
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ValueError, ProvisionError) as exc:
        print(f"postgres tenant provision error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
