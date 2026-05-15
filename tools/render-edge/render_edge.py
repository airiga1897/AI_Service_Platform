#!/usr/bin/env python3
"""Генератор edge-конфигов (HAProxy + per-site Nginx) из ``services.yml``.

Использование::

    python3 tools/render-edge/render_edge.py
    python3 tools/render-edge/render_edge.py --check
    python3 tools/render-edge/render_edge.py --haproxy-out path
    python3 tools/render-edge/render_edge.py --nginx-out-dir path
    python3 tools/render-edge/render_edge.py --registry path

По умолчанию генерируются:

* ``infra/edge/haproxy/haproxy.cfg`` — единый файл с HTTP/HTTPS
  frontend'ами с SNI-маршрутизацией по доменам и блок TCP-портов
  SoftEther (443/992/1194/5555).
* ``infra/edge/nginx/sites/<instance>.conf`` — по одному файлу на каждый
  инстанс типа ``site``. Reverse-proxy на backend-контейнер, ACME-локация
  и стандартные ``X-Forwarded-*`` заголовки.

Флаг ``--check`` рендерит результат в память и сравнивает с тем, что
лежит на диске; при расхождении завершает процесс ненулевым кодом
(используется в CI и pre-commit).

Шаблоны лежат в ``tools/render-edge/templates/``. Используются те же
нестандартные jinja-разделители (``<<`` / ``>>``), что и в
``render-compose``, чтобы литеральные ``${...}``-подстановки в шаблонах
не приходилось экранировать.
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
DEFAULT_HAPROXY_OUT = REPO_ROOT / "infra" / "edge" / "haproxy" / "haproxy.cfg"
DEFAULT_NGINX_OUT_DIR = REPO_ROOT / "infra" / "edge" / "nginx" / "sites"

sys.path.insert(0, str(TOOLS_DIR))
from _lib.registry import load_registry, projects, runtime_instances  # noqa: E402

SITE_TYPES = {"django-site", "django-react-site"}

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
    """Бросается, когда edge-конфиг невозможно отрендерить."""


def _container_with_suffix(containers: list[str], *suffixes: str) -> str | None:
    """Вернуть первый контейнер из ``containers`` с одним из суффиксов."""
    for name in containers:
        if not isinstance(name, str):
            continue
        for suffix in suffixes:
            if name.endswith(f"-{suffix}"):
                return name
    return None


def _is_placeholder_domain(domain: str) -> bool:
    """Плейсхолдер-домены из services.yml (`*.example.invalid`) не маршрутизируются."""
    return domain.endswith(".example.invalid")


def _collect_sites(registry: dict[str, Any]) -> list[dict[str, Any]]:
    """Собрать данные по всем рантайм-инстансам типа ``site``.

    Возвращает список словарей-контекстов, отсортированных по имени
    инстанса, чтобы вывод был детерминированным.
    """
    proj = projects(registry)
    instances = runtime_instances(registry)
    sites: list[dict[str, Any]] = []

    for instance_name in sorted(instances.keys()):
        instance = instances[instance_name]
        if not isinstance(instance, dict):
            raise RenderError(f"runtime_instances.{instance_name}: not a mapping")
        project_key = instance.get("project")
        if not project_key or project_key not in proj:
            raise RenderError(
                f"runtime_instances.{instance_name}: unknown project '{project_key}'"
            )
        project_type = proj[project_key].get("type")
        if project_type not in SITE_TYPES:
            # Telegram-боты и прочие не-сайтовые типы на edge не публикуются.
            continue

        containers = (instance.get("containers") or {}).get("future") or []
        if not isinstance(containers, list):
            raise RenderError(
                f"runtime_instances.{instance_name}.containers.future: must be a list"
            )

        backend_container = _container_with_suffix(containers, "backend", "web")
        nginx_container = _container_with_suffix(containers, "nginx")
        if backend_container is None:
            raise RenderError(
                f"runtime_instances.{instance_name}: cannot find backend container "
                "(expected name ending with '-backend' or '-web' in containers.future)"
            )
        if nginx_container is None:
            raise RenderError(
                f"runtime_instances.{instance_name}: cannot find nginx container "
                "(expected name ending with '-nginx' in containers.future)"
            )

        domains_block = instance.get("domains") or {}
        prod_domains = [
            d for d in (domains_block.get("prod") or [])
            if isinstance(d, str) and not _is_placeholder_domain(d)
        ]
        preprod_domains = [
            d for d in (domains_block.get("preprod") or [])
            if isinstance(d, str) and not _is_placeholder_domain(d)
        ]
        all_server_names = sorted(set(prod_domains + preprod_domains))

        sites.append(
            {
                "instance_name": instance_name,
                "project_type": project_type,
                "backend_container": backend_container,
                "backend_internal_port": 8000,  # все django-* шаблоны слушают 8000
                "nginx_container": nginx_container,
                "prod_domains": prod_domains,
                "preprod_domains": preprod_domains,
                "all_server_names": all_server_names,
                "haproxy_backend_name": f"be_{instance_name.replace('-', '_')}",
            }
        )

    return sites


def _build_haproxy_context(registry: dict[str, Any], sites: list[dict[str, Any]]) -> dict[str, Any]:
    """Собрать контекст для шаблона haproxy.cfg.j2."""
    edge_vpn = ((registry.get("platform") or {}).get("edge_vpn")) or {}
    ports = (edge_vpn.get("ports") or {}).get("tcp") or []
    if not isinstance(ports, list):
        raise RenderError("platform.edge_vpn.ports.tcp must be a list")
    security = edge_vpn.get("security") or {}
    mgmt_port = security.get("management_port", 5555)

    # Frontend SNI-список — только реальные prod-домены сайтов.
    sni_routes: list[dict[str, Any]] = []
    for site in sites:
        if site["prod_domains"]:
            sni_routes.append(
                {
                    "instance_name": site["instance_name"],
                    "backend_name": site["haproxy_backend_name"],
                    "nginx_container": site["nginx_container"],
                    "prod_domains": site["prod_domains"],
                }
            )

    return {
        "sni_routes": sni_routes,
        "softether_tcp_ports": [p for p in ports if isinstance(p, int) and p not in (443, mgmt_port)],
        "softether_mgmt_port": mgmt_port,
        "softether_https_port": 443 if 443 in ports else None,
    }


def render_haproxy(registry: dict[str, Any], sites: list[dict[str, Any]] | None = None) -> str:
    if sites is None:
        sites = _collect_sites(registry)
    template = _jinja_env.get_template("haproxy.cfg.j2")
    return template.render(**_build_haproxy_context(registry, sites))


def render_nginx_site(site: dict[str, Any]) -> str:
    template = _jinja_env.get_template("site.nginx.conf.j2")
    return template.render(**site)


def _write_if_diff(path: Path, content: str, *, check: bool) -> bool:
    """Записать ``content`` в ``path`` или (в режиме check) сравнить.

    Возвращает True, если содержимое совпадает с диском.
    """
    existing = path.read_text(encoding="utf-8") if path.exists() else None
    if existing == content:
        return True
    if check:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    print(f"wrote {path}")
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Render edge configs (HAProxy + Nginx).")
    parser.add_argument("--registry", type=Path, default=None, help="Путь до services.yml")
    parser.add_argument("--haproxy-out", type=Path, default=DEFAULT_HAPROXY_OUT)
    parser.add_argument("--nginx-out-dir", type=Path, default=DEFAULT_NGINX_OUT_DIR)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Не писать на диск; завершиться кодом 1 при дрейфе.",
    )
    args = parser.parse_args(argv)

    try:
        registry = load_registry(args.registry)
        sites = _collect_sites(registry)
        haproxy_text = render_haproxy(registry, sites)
        nginx_files: list[tuple[Path, str]] = [
            (args.nginx_out_dir / f"{site['instance_name']}.conf", render_nginx_site(site))
            for site in sites
        ]
    except (RenderError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except FileNotFoundError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    drift: list[Path] = []
    if not _write_if_diff(args.haproxy_out, haproxy_text, check=args.check):
        drift.append(args.haproxy_out)
    for path, text in nginx_files:
        if not _write_if_diff(path, text, check=args.check):
            drift.append(path)

    # Поиск orphan-конфигов: реальные `*.conf` в каталоге nginx,
    # которых не должно быть согласно services.yml. Без этой проверки
    # удаление/переименование инстанса оставит мёртвый vhost на edge.
    expected_nginx = {path for path, _ in nginx_files}
    orphans: list[Path] = []
    if args.nginx_out_dir.is_dir():
        for existing in sorted(args.nginx_out_dir.glob("*.conf")):
            if existing not in expected_nginx:
                orphans.append(existing)

    if orphans and not args.check:
        for path in orphans:
            path.unlink()
            print(f"removed orphan {path}")

    if drift or (orphans and args.check):
        print(
            "ERROR: edge configs drifted from services.yml. "
            "Run `python3 tools/render-edge/render_edge.py` to regenerate.",
            file=sys.stderr,
        )
        for path in drift:
            print(f"  drift: {path}", file=sys.stderr)
        for path in orphans:
            print(f"  orphan: {path}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
