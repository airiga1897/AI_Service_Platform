#!/usr/bin/env python3
"""Проверка read-only отчёта PostgreSQL по canonical operator model."""

from __future__ import annotations

import argparse
import csv
import ipaddress
import json
from pathlib import Path
import re
from typing import Any

import yaml


def _split_aliases(value: str | None) -> list[str]:
    return [item.strip() for item in (value or "").split("+") if item.strip()]


def _normalized_cidr(rule: dict[str, Any]) -> str | None:
    address = rule.get("address")
    netmask = rule.get("netmask")
    if not address or not netmask:
        return None
    return str(ipaddress.ip_network(f"{address}/{netmask}", strict=False))


def _slot_name(prefix: str, alias: str) -> str:
    value = re.sub(r"[^A-Za-z0-9_]", "_", f"{prefix}_{alias}")
    if not re.match(r"^[A-Za-z_]", value):
        value = "_" + value
    return value[:60]


def validate_report(
    report: dict[str, Any], config_document: dict[str, Any], state_rows: list[dict[str, str]]
) -> dict[str, Any]:
    errors: list[str] = []
    config = config_document.get("postgres_runtime") or {}
    state = next(
        (
            row
            for row in state_rows
            if row.get("kind") == "service" and row.get("name") == "postgres_runtime"
        ),
        None,
    )
    if state is None:
        return {"ok": False, "errors": ["В state.csv отсутствует postgres_runtime"]}

    primary_aliases = _split_aliases(state.get("active_aliases"))
    standby_aliases = _split_aliases(state.get("candidate_aliases"))
    if len(primary_aliases) != 1:
        errors.append("Canonical model должен содержать ровно один PostgreSQL primary")
        primary_alias = primary_aliases[0] if primary_aliases else ""
    else:
        primary_alias = primary_aliases[0]

    reports = {str(item.get("alias")): item for item in report.get("nodes", [])}
    expected_aliases = [primary_alias, *standby_aliases]
    for alias in expected_aliases:
        if alias and alias not in reports:
            errors.append(f"В audit отсутствует обязательный узел {alias}")

    replication_user = str(config.get("replication_user") or "ai_sp_replicator")
    slot_prefix = str(config.get("replication_slot_prefix") or "ai_sp")
    expected_slots = {_slot_name(slot_prefix, alias) for alias in standby_aliases}
    managed = config.get("managed_databases") or {}
    expected_products = {
        (
            str(item.get("database")),
            str(item.get("owner_role")),
            str(cidr),
            "scram-sha-256",
        )
        for item in managed.values()
        for cidr in item.get("allowed_cidrs", [])
    }
    product_identities = {(item[0], item[1]) for item in expected_products}
    replication_cidrs = list(config.get("replication_cidrs") or [])
    replication_cidrs.extend(
        (config.get("replication_hba_cidrs_by_alias") or {}).get(primary_alias, []) or []
    )
    expected_replication_hba = {
        (str(cidr), "scram-sha-256") for cidr in dict.fromkeys(replication_cidrs)
    }

    primary_postgres: dict[str, Any] = {}
    if primary_alias in reports:
        primary_postgres = reports[primary_alias].get("postgres") or {}
        if not primary_postgres.get("present"):
            errors.append(f"{primary_alias}: PostgreSQL container отсутствует")
        if primary_postgres.get("error"):
            errors.append(f"{primary_alias}: {primary_postgres['error']}")
        if primary_postgres.get("pg_is_in_recovery") != "f":
            errors.append(f"{primary_alias}: узел не подтверждён как primary")
        if primary_postgres.get("hba_file") != "/etc/postgresql/pg_hba.conf":
            errors.append(f"{primary_alias}: активен неожиданный hba_file")

        hba_rules = primary_postgres.get("hba_rules") or []
        if any(rule.get("error") for rule in hba_rules):
            errors.append(f"{primary_alias}: pg_hba_file_rules содержит ошибки")
        actual_products = {
            (
                rule["database"][0],
                rule["user_name"][0],
                _normalized_cidr(rule),
                rule.get("auth_method"),
            )
            for rule in hba_rules
            if rule.get("type") == "host"
            and len(rule.get("database") or []) == 1
            and len(rule.get("user_name") or []) == 1
            and (rule["database"][0], rule["user_name"][0]) in product_identities
        }
        if actual_products != expected_products:
            errors.append(f"{primary_alias}: продуктовые HBA-правила не соответствуют модели")
        actual_replication_hba = {
            (_normalized_cidr(rule), rule.get("auth_method"))
            for rule in hba_rules
            if rule.get("type") == "host"
            and "replication" in (rule.get("database") or [])
            and replication_user in (rule.get("user_name") or [])
        }
        if actual_replication_hba != expected_replication_hba:
            errors.append(f"{primary_alias}: replication HBA-правила не соответствуют модели")

        replication = primary_postgres.get("replication") or []
        actual_slots = {str(item.get("application_name")) for item in replication}
        if actual_slots != expected_slots:
            errors.append(f"{primary_alias}: набор streaming standby не соответствует модели")
        for item in replication:
            if item.get("state") != "streaming" or item.get("sync_state") != "async":
                errors.append(
                    f"{primary_alias}: {item.get('application_name')} не streaming/async"
                )
            client = item.get("client_addr")
            if expected_replication_hba and not any(
                ipaddress.ip_address(client) in ipaddress.ip_network(cidr)
                for cidr, _method in expected_replication_hba
                if client
            ):
                errors.append(
                    f"{primary_alias}: {item.get('application_name')} подключён не через platform_router"
                )

    for alias in standby_aliases:
        if alias not in reports:
            continue
        postgres = reports[alias].get("postgres") or {}
        if not postgres.get("present"):
            errors.append(f"{alias}: PostgreSQL container отсутствует")
            continue
        if postgres.get("error"):
            errors.append(f"{alias}: {postgres['error']}")
        if postgres.get("pg_is_in_recovery") != "t":
            errors.append(f"{alias}: узел не подтверждён как standby")
        receivers = postgres.get("wal_receivers") or []
        expected_slot = _slot_name(slot_prefix, alias)
        if len(receivers) != 1:
            errors.append(f"{alias}: ожидается ровно один WAL receiver")
        elif receivers[0].get("status") != "streaming":
            errors.append(f"{alias}: WAL receiver не в состоянии streaming")
        elif receivers[0].get("slot_name") != expected_slot:
            errors.append(f"{alias}: WAL receiver использует неожиданный slot")

    expected_cidrs = sorted({cidr for cidr, _method in expected_replication_hba})
    return {
        "ok": not errors,
        "primary_alias": primary_alias,
        "standby_aliases": standby_aliases,
        "expected_replication_cidrs": expected_cidrs,
        "expected_streaming_slots": sorted(expected_slots),
        "errors": errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    args = parser.parse_args()

    report = json.loads(args.report.read_text(encoding="utf-8-sig"))
    config = yaml.safe_load(args.config.read_text(encoding="utf-8")) or {}
    with args.state.open(encoding="utf-8-sig", newline="") as stream:
        state_rows = list(csv.DictReader(stream))
    result = validate_report(report, config, state_rows)
    # ASCII JSON исключает зависимость от активной code page Windows PowerShell.
    print(json.dumps(result, ensure_ascii=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
