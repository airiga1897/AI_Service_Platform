#!/usr/bin/env python3
"""Генератор per-stack docker-compose файлов из ``services.yml`` и шаблонов.

Использование::

    python3 tools/render-compose/render_compose.py --stack <name>
    python3 tools/render-compose/render_compose.py --stack all
    python3 tools/render-compose/render_compose.py --stack <name> --out path
    python3 tools/render-compose/render_compose.py --stack all --check

По умолчанию результат пишется в
``infra/stacks/<stack>/docker-compose.<stack>.yml``. Флаг ``--check``
рендерит файл в память и сравнивает его с тем, что лежит на диске; при
расхождении завершает процесс ненулевым кодом (используется в CI).

Шаблоны лежат в ``tools/render-compose/templates/`` и выбираются по полю
``type`` соответствующего проекта в ``services.yml`` (``django-site``,
``django-react-site``, ``telegram-bot``).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

import jinja2

THIS_DIR = Path(__file__).resolve().parent
TOOLS_DIR = THIS_DIR.parent
REPO_ROOT = TOOLS_DIR.parent
TEMPLATES_DIR = THIS_DIR / "templates"
STACKS_DIR = REPO_ROOT / "infra" / "stacks"

sys.path.insert(0, str(TOOLS_DIR))
from _lib.registry import load_registry, projects, runtime_instances  # noqa: E402

# Используем нестандартные разделители Jinja2, чтобы литеральные shell-
# подстановки ``${...}`` в шаблонах не приходилось экранировать.
_jinja_env = jinja2.Environment(
    loader=jinja2.FileSystemLoader(str(TEMPLATES_DIR)),
    keep_trailing_newline=True,
    undefined=jinja2.StrictUndefined,
    variable_start_string="<<",
    variable_end_string=">>",
    block_start_string="<%",
    block_end_string="%>",
    comment_start_string="<#",
    comment_end_string="#>",
)


class RenderError(RuntimeError):
    """Бросается, когда стек невозможно отрендерить (плохие данные / нет шаблона)."""


def _container_with_suffix(containers: list[str], suffix: str) -> str | None:
    """Вернуть первый контейнер из ``containers``, оканчивающийся на ``-<suffix>``."""
    needle = f"-{suffix}"
    for name in containers:
        if isinstance(name, str) and name.endswith(needle):
            return name
    return None


def _required(value: Any, field: str, instance_name: str) -> Any:
    if value in (None, "", [], {}):
        raise RenderError(
            f"runtime_instances.{instance_name}: missing required field '{field}'"
        )
    return value


def _build_context(
    instance_name: str,
    instance: dict[str, Any],
    project_type: str,
    project_name: str,
) -> dict[str, Any]:
    """Собрать контекст рендера для одного инстанса."""
    env = instance.get("env") or {}
    local = instance.get("local") or {}
    data = instance.get("data") or {}
    healthcheck = instance.get("healthcheck") or {}
    containers_future = (instance.get("containers") or {}).get("future") or []
    volumes = data.get("volumes") or {}

    ctx: dict[str, Any] = {
        "instance_name": instance_name,
        "project_name": project_name,
        "project_type": project_type,
        "env_prefix": _required(env.get("prefix"), "env.prefix", instance_name),
        "env_file": _required(env.get("file"), "env.file", instance_name),
        "healthcheck_path": _required(
            healthcheck.get("path"), "healthcheck.path", instance_name
        ),
        "healthcheck_timeout": _required(
            healthcheck.get("timeout_seconds"),
            "healthcheck.timeout_seconds",
            instance_name,
        ),
    }

    if project_type in ("django-site", "django-react-site"):
        ctx["db_name"] = _required(data.get("database"), "data.database", instance_name)
        ctx["backend_port"] = _required(
            local.get("backend_port"), "local.backend_port", instance_name
        )
        ctx["frontend_port"] = _required(
            local.get("frontend_port"), "local.frontend_port", instance_name
        )
        ctx["static_volume"] = _required(volumes.get("static"), "data.volumes.static", instance_name)
        ctx["media_volume"] = _required(volumes.get("media"), "data.volumes.media", instance_name)
        ctx["postgres_volume"] = _required(
            volumes.get("postgres"), "data.volumes.postgres", instance_name
        )
        ctx["redis_volume"] = _required(volumes.get("redis"), "data.volumes.redis", instance_name)
        ctx["db_name_service"] = _required(
            _container_with_suffix(containers_future, "db"),
            "containers.future[*-db]",
            instance_name,
        )
        ctx["redis_name_service"] = _required(
            _container_with_suffix(containers_future, "redis"),
            "containers.future[*-redis]",
            instance_name,
        )
        ctx["nginx_name"] = _required(
            _container_with_suffix(containers_future, "nginx"),
            "containers.future[*-nginx]",
            instance_name,
        )

    if project_type == "django-site":
        ctx["backend_name"] = _required(
            _container_with_suffix(containers_future, "backend"),
            "containers.future[*-backend]",
            instance_name,
        )
        ctx["frontend_name"] = _required(
            _container_with_suffix(containers_future, "frontend"),
            "containers.future[*-frontend]",
            instance_name,
        )
    elif project_type == "django-react-site":
        ctx["web_name"] = _required(
            _container_with_suffix(containers_future, "web"),
            "containers.future[*-web]",
            instance_name,
        )
        ctx["frontend_dev_name"] = _required(
            _container_with_suffix(containers_future, "frontend-dev"),
            "containers.future[*-frontend-dev]",
            instance_name,
        )
        ctx["vite_proxy_target"] = local.get("vite_proxy_target", "")
    elif project_type == "telegram-bot":
        webhook = instance.get("webhook") or {}
        ctx["bot_mode"] = (instance.get("bot") or {}).get("mode", "webhook")
        ctx["webhook_preprod"] = _required(
            webhook.get("preprod"), "webhook.preprod", instance_name
        )
        ctx["webhook_prod"] = _required(
            webhook.get("prod"), "webhook.prod", instance_name
        )
        ctx["bot_name"] = _required(
            _container_with_suffix(containers_future, "bot"),
            "containers.future[*-bot]",
            instance_name,
        )
        ctx["redis_name_service"] = _required(
            _container_with_suffix(containers_future, "redis"),
            "containers.future[*-redis]",
            instance_name,
        )
        ctx["redis_volume"] = _required(
            volumes.get("redis"), "data.volumes.redis", instance_name
        )
    else:
        raise RenderError(
            f"runtime_instances.{instance_name}: unsupported project type {project_type!r}"
        )

    return ctx


def render_stack(instance_name: str, registry: dict[str, Any]) -> str:
    """Отрендерить один стек в строку Compose YAML."""
    instances = runtime_instances(registry)
    if instance_name not in instances:
        raise RenderError(
            f"unknown stack {instance_name!r} (known: {sorted(instances)})"
        )
    instance = instances[instance_name]
    project_name = instance.get("project")
    project = projects(registry).get(project_name) if project_name else None
    if not isinstance(project, dict):
        raise RenderError(
            f"runtime_instances.{instance_name}.project={project_name!r} not found in projects"
        )
    project_type = project.get("type")
    if not isinstance(project_type, str):
        raise RenderError(
            f"projects.{project_name}.type is required and must be a string"
        )

    template_name = f"{project_type}.yml.j2"
    try:
        template = _jinja_env.get_template(template_name)
    except jinja2.TemplateNotFound as exc:
        raise RenderError(
            f"no template for project type {project_type!r}"
            f" (expected tools/render-compose/templates/{template_name})"
        ) from exc

    ctx = _build_context(instance_name, instance, project_type, project_name)
    return template.render(**ctx)


def stack_output_path(instance_name: str) -> Path:
    return STACKS_DIR / instance_name / f"docker-compose.{instance_name}.yml"


def _resolve_target_stacks(stack: str, registry: dict[str, Any]) -> list[str]:
    if stack == "all":
        return list(runtime_instances(registry).keys())
    if stack not in runtime_instances(registry):
        raise RenderError(
            f"unknown stack {stack!r} (known: {sorted(runtime_instances(registry))})"
        )
    return [stack]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render docker-compose files for runtime stacks from services.yml."
    )
    parser.add_argument(
        "--stack",
        required=True,
        help="Stack name from services.yml runtime_instances, or 'all'.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help=(
            "Optional output path. Ignored when --stack=all (each stack is "
            "always written under infra/stacks/<stack>/). Default for a "
            "single stack: infra/stacks/<stack>/docker-compose.<stack>.yml."
        ),
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Render in memory and diff against the on-disk file. Non-zero exit on mismatch.",
    )
    parser.add_argument(
        "--registry",
        type=Path,
        default=None,
        help="Optional path to an alternate services.yml (useful for tests).",
    )
    return parser.parse_args(argv)


def _check_stack(name: str, rendered: str) -> tuple[bool, str]:
    target = stack_output_path(name)
    if not target.exists():
        return False, f"missing on-disk file {target} — run without --check first"
    on_disk = target.read_text(encoding="utf-8")
    if on_disk != rendered:
        return False, (
            f"{target} is out of date with services.yml + templates."
            " Re-run `python3 tools/render-compose/render_compose.py"
            f" --stack {name}`."
        )
    return True, f"{target} is up to date"


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        registry = load_registry(args.registry)
    except (FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    try:
        targets = _resolve_target_stacks(args.stack, registry)
    except RenderError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    overall_ok = True
    for name in targets:
        try:
            rendered = render_stack(name, registry)
        except RenderError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            overall_ok = False
            continue

        if args.check:
            ok, message = _check_stack(name, rendered)
            stream = sys.stdout if ok else sys.stderr
            print(message, file=stream)
            overall_ok = overall_ok and ok
            continue

        if args.out is not None and args.stack != "all":
            out_path = args.out
        else:
            out_path = stack_output_path(name)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(rendered, encoding="utf-8")
        print(f"wrote {out_path}")

    return 0 if overall_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
