#!/usr/bin/env python3
"""CLI для опроса healthcheck-эндпойнтов рантайм-инстансов из ``services.yml``.

Использование::

    python3 tools/healthcheck/healthcheck.py --env <local|preprod|prod>
        [--instance <name> ...] [--timeout <sec>] [--json]
        [--registry <path>]

Без ``--instance`` опрашиваются все инстансы, у которых в выбранном
окружении есть домены. Для каждой пары (инстанс, домен) формируется
URL по `healthcheck.path` и сравнивается фактический HTTP-статус с
`healthcheck.expected_status`.

Exit-коды:
  0 — все цели либо ``ok``, либо ``skipped``;
  1 — есть хотя бы одна цель со статусом ``fail``;
  2 — ошибка конфигурации (нет такого инстанса, нет окружения, и т. п.).

Зависимости: только стандартная библиотека (``urllib``) и ``pyyaml``
(для общего загрузчика реестра ``tools/_lib/registry.py``).
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any
from urllib import error as urlerror
from urllib import request as urlrequest
from urllib.parse import urlsplit, urlunsplit

THIS_DIR = Path(__file__).resolve().parent
TOOLS_DIR = THIS_DIR.parent

sys.path.insert(0, str(TOOLS_DIR))
from _lib.registry import load_registry, runtime_instances  # noqa: E402


SUPPORTED_ENVS = ("local", "preprod", "prod")
PLACEHOLDER_REASON = "placeholder-domain"


class HealthcheckConfigError(Exception):
    """Ошибка конфигурации (некорректный CLI-ввод или неполный реестр)."""


@dataclass
class Target:
    """Одна цель опроса: (инстанс, окружение, домен) → URL и параметры."""

    instance: str
    env: str
    domain: str
    url: str
    expected_status: int
    timeout_seconds: float


@dataclass
class Result:
    """Результат опроса одной цели."""

    instance: str
    env: str
    url: str
    status: str  # "ok" | "fail" | "skipped"
    http_status: int | None = None
    expected_status: int | None = None
    latency_ms: float | None = None
    error: str | None = None
    reason: str | None = None  # для skipped: почему пропущено


# ---------------------------------------------------------------------------
# Сборка целей
# ---------------------------------------------------------------------------


def _is_placeholder_domain(domain: str) -> bool:
    """Любой домен из reserved TLD ``.invalid`` (RFC 6761) — заглушка."""
    host = domain
    if "://" in domain:
        host = urlsplit(domain).hostname or ""
    host = host.split(":", 1)[0].rstrip(".").lower()
    return host == "invalid" or host.endswith(".invalid")


def _build_url(env: str, domain: str, path: str) -> str:
    """Собрать URL для опроса.

    Для ``env='local'`` домен уже содержит схему и порт
    (``http://localhost:5000``); просто подменяем path. Для остальных
    окружений домен — голый хост, и мы строим ``https://<host><path>``.
    """
    if "://" in domain:
        parts = urlsplit(domain)
        return urlunsplit((parts.scheme, parts.netloc, path, "", ""))
    return f"https://{domain}{path}"


def build_targets(
    registry: dict[str, Any],
    env: str,
    instance_filter: list[str] | None,
    timeout_override: float | None,
) -> tuple[list[Target], list[Result]]:
    """Собрать список целей для опроса и сразу — список ``skipped``-результатов.

    Returns
    -------
    targets:
        Цели, по которым реально нужно ходить по сети.
    skipped:
        Результаты со статусом ``skipped`` (placeholder-домены и инстансы
        без доменов в выбранном окружении).
    """
    if env not in SUPPORTED_ENVS:
        raise HealthcheckConfigError(
            f"unknown env {env!r}, expected one of {list(SUPPORTED_ENVS)}"
        )

    instances = runtime_instances(registry)
    if instance_filter:
        unknown = [name for name in instance_filter if name not in instances]
        if unknown:
            raise HealthcheckConfigError(
                f"unknown instance(s): {unknown}; known: {sorted(instances)}"
            )
        selected = {name: instances[name] for name in instance_filter}
    else:
        selected = dict(instances)

    targets: list[Target] = []
    skipped: list[Result] = []

    for name, instance in selected.items():
        healthcheck = instance.get("healthcheck") or {}
        path = healthcheck.get("path")
        expected_status = healthcheck.get("expected_status")
        timeout_seconds = (
            timeout_override
            if timeout_override is not None
            else healthcheck.get("timeout_seconds")
        )
        if not path or expected_status is None or timeout_seconds is None:
            raise HealthcheckConfigError(
                f"runtime_instances.{name}.healthcheck is incomplete"
                " (path/expected_status/timeout_seconds required)"
            )

        domains = ((instance.get("domains") or {}).get(env)) or []
        if not isinstance(domains, list) or not domains:
            skipped.append(
                Result(
                    instance=name,
                    env=env,
                    url="",
                    status="skipped",
                    expected_status=expected_status,
                    reason="no-domains",
                )
            )
            continue

        for domain in domains:
            if not isinstance(domain, str) or not domain:
                continue
            url = _build_url(env, domain, path)
            if _is_placeholder_domain(domain):
                skipped.append(
                    Result(
                        instance=name,
                        env=env,
                        url=url,
                        status="skipped",
                        expected_status=expected_status,
                        reason=PLACEHOLDER_REASON,
                    )
                )
                continue
            targets.append(
                Target(
                    instance=name,
                    env=env,
                    domain=domain,
                    url=url,
                    expected_status=int(expected_status),
                    timeout_seconds=float(timeout_seconds),
                )
            )

    return targets, skipped


# ---------------------------------------------------------------------------
# Опрос
# ---------------------------------------------------------------------------


def probe(target: Target) -> Result:
    """Сходить HTTP GET по ``target.url`` с таймаутом и собрать результат."""
    req = urlrequest.Request(target.url, method="GET", headers={"User-Agent": "ai-platform-healthcheck/1"})
    start = time.monotonic()
    http_status: int | None = None
    error_message: str | None = None
    try:
        with urlrequest.urlopen(req, timeout=target.timeout_seconds) as response:
            http_status = int(getattr(response, "status", response.getcode()))
    except urlerror.HTTPError as exc:
        # 4xx/5xx тоже даёт нам код — это валидный результат проверки.
        http_status = int(exc.code)
    except urlerror.URLError as exc:
        reason = exc.reason
        if isinstance(reason, socket.timeout):
            error_message = f"timeout after {target.timeout_seconds}s"
        else:
            error_message = f"url-error: {reason}"
    except socket.timeout:
        error_message = f"timeout after {target.timeout_seconds}s"
    except OSError as exc:
        error_message = f"os-error: {exc}"
    latency_ms = round((time.monotonic() - start) * 1000.0, 1)

    if error_message is not None:
        return Result(
            instance=target.instance,
            env=target.env,
            url=target.url,
            status="fail",
            expected_status=target.expected_status,
            latency_ms=latency_ms,
            error=error_message,
        )

    status = "ok" if http_status == target.expected_status else "fail"
    return Result(
        instance=target.instance,
        env=target.env,
        url=target.url,
        status=status,
        http_status=http_status,
        expected_status=target.expected_status,
        latency_ms=latency_ms,
        error=None
        if status == "ok"
        else f"unexpected-status: got {http_status}, expected {target.expected_status}",
    )


# ---------------------------------------------------------------------------
# Отчёт
# ---------------------------------------------------------------------------


@dataclass
class Report:
    env: str
    results: list[Result] = field(default_factory=list)

    @property
    def summary(self) -> dict[str, int]:
        counts = {"total": len(self.results), "ok": 0, "fail": 0, "skipped": 0}
        for r in self.results:
            counts[r.status] = counts.get(r.status, 0) + 1
        return counts

    def to_json_dict(self) -> dict[str, Any]:
        return {
            "env": self.env,
            "summary": self.summary,
            "results": [asdict(r) for r in self.results],
        }


def _format_table(report: Report) -> str:
    headers = ("INSTANCE", "ENV", "STATUS", "HTTP", "LATENCY", "URL", "DETAIL")
    rows: list[tuple[str, ...]] = [headers]
    for r in report.results:
        http = str(r.http_status) if r.http_status is not None else "-"
        latency = f"{r.latency_ms}ms" if r.latency_ms is not None else "-"
        detail = r.error or r.reason or ""
        rows.append((r.instance, r.env, r.status.upper(), http, latency, r.url or "-", detail))

    widths = [max(len(row[i]) for row in rows) for i in range(len(headers))]
    lines = []
    for row in rows:
        lines.append("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)).rstrip())
    summary = report.summary
    lines.append("")
    lines.append(
        f"summary: total={summary['total']} ok={summary['ok']}"
        f" fail={summary['fail']} skipped={summary['skipped']}"
    )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Probe healthcheck endpoints declared in services.yml.",
    )
    parser.add_argument(
        "--env",
        required=True,
        choices=list(SUPPORTED_ENVS),
        help="Which domain set to probe.",
    )
    parser.add_argument(
        "--instance",
        action="append",
        default=None,
        help="Limit to one or more runtime instances. Can be repeated.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=None,
        help=(
            "Override per-target timeout in seconds. By default the value"
            " from services.yml runtime_instances.<name>.healthcheck.timeout_seconds"
            " is used."
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit a structured JSON report instead of a human-readable table.",
    )
    parser.add_argument(
        "--registry",
        type=Path,
        default=None,
        help="Optional path to an alternate services.yml (useful for tests).",
    )
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> tuple[int, str]:
    """Главная точка входа без печати; возвращает (exit_code, output)."""
    try:
        registry = load_registry(args.registry)
    except (FileNotFoundError, ValueError) as exc:
        raise HealthcheckConfigError(str(exc)) from exc

    targets, skipped = build_targets(
        registry=registry,
        env=args.env,
        instance_filter=args.instance,
        timeout_override=args.timeout,
    )

    results: list[Result] = list(skipped)
    for target in targets:
        results.append(probe(target))

    # Стабильный порядок: сначала по имени инстанса, затем по URL.
    results.sort(key=lambda r: (r.instance, r.url))

    report = Report(env=args.env, results=results)
    output = (
        json.dumps(report.to_json_dict(), ensure_ascii=False, indent=2)
        if args.json
        else _format_table(report)
    )
    exit_code = 1 if report.summary["fail"] else 0
    return exit_code, output


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        exit_code, output = run(args)
    except HealthcheckConfigError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    print(output)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
