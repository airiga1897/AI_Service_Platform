#!/usr/bin/env python3
"""Разрешение безопасного контракта будущей публикации site_runtime."""

from __future__ import annotations

import argparse
import csv
import hashlib
import ipaddress
import json
import re
from pathlib import Path
from typing import Any

import yaml


class PublicationContractError(ValueError):
    """Нарушение canonical publication contract."""


DOMAIN_RE = re.compile(r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}")


def _load_yaml(path: Path) -> dict[str, Any]:
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(data, dict):
        raise PublicationContractError(f"{path} должен содержать YAML mapping")
    return data


def _active_aliases(state_path: Path, kind: str, name: str) -> set[str]:
    with state_path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    matches = [
        row
        for row in rows
        if row.get("kind") == kind and row.get("name") == name and row.get("state") == "present"
    ]
    if len(matches) != 1:
        raise PublicationContractError(
            f"state.csv должен содержать ровно одну present-запись {kind}/{name}"
        )
    return {item for item in (matches[0].get("active_aliases") or "").split("+") if item}


def _render_contract(instance: str, domain: str, backend: str, http_port: int, https_port: int) -> dict[str, Any]:
    backend_name = f"be_site_{instance.replace('-', '_')}"
    acl_name = f"site_{instance.replace('-', '_')}"
    haproxy_http = f"""acl host_{acl_name} hdr(host) -i {domain}
acl acme_{acl_name} path_beg /.well-known/acme-challenge/
use_backend {backend_name}_http if host_{acl_name} acme_{acl_name}

backend {backend_name}_http
    mode http
    server {instance}-nginx {backend}:{http_port} check inter 5s fall 3 rise 2
"""
    haproxy_https = f"""acl sni_{acl_name} req_ssl_sni -i {domain}
use_backend {backend_name}_https if sni_{acl_name}

backend {backend_name}_https
    mode tcp
    option tcp-check
    server {instance}-nginx-tls {backend}:{https_port} check inter 5s fall 3 rise 2
"""
    nginx = f"""server {{
    listen {http_port};
    server_name {domain};
    location ^~ /.well-known/acme-challenge/ {{ root /var/www/acme; }}
    location / {{ return 404; }}
}}

server {{
    listen {https_port} ssl;
    server_name {domain};
    ssl_certificate /etc/letsencrypt/live/{domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;
    location / {{
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:8000;
    }}
}}
"""
    documents = {
        "haproxy_http_fragment": haproxy_http,
        "haproxy_https_fragment": haproxy_https,
        "nginx_public_fragment": nginx,
    }
    checksums = {
        name: hashlib.sha256(content.encode("utf-8")).hexdigest()
        for name, content in documents.items()
    }
    combined = "\n".join(documents[name] for name in sorted(documents))
    checksums["publication_bundle"] = hashlib.sha256(combined.encode("utf-8")).hexdigest()
    return {"documents": documents, "checksums": checksums}


def resolve(
    registry_path: Path,
    instances_path: Path,
    state_path: Path,
    instance_name: str,
    limit: str,
) -> dict[str, Any]:
    registry = _load_yaml(registry_path)
    placements = _load_yaml(instances_path)
    profiles = registry.get("runtime_instances") or {}
    instances = placements.get("instances") or {}
    if placements.get("version") != 1 or not isinstance(instances, dict):
        raise PublicationContractError("instances.yml должен использовать version: 1 и instances mapping")
    profile = profiles.get(instance_name) if isinstance(profiles, dict) else None
    placement = instances.get(instance_name)
    if not isinstance(profile, dict) or not isinstance(placement, dict):
        raise PublicationContractError(f"Неизвестный site_runtime instance: {instance_name}")
    if limit != placement.get("placement_alias"):
        raise PublicationContractError("-Limit должен совпадать с placement_alias")

    runtime = profile.get("site_runtime") or {}
    publication = runtime.get("publication") or {}
    operator_publication = placement.get("publication") or {}
    domain = str(publication.get("domain") or "")
    if publication.get("state") != "planned":
        raise PublicationContractError("publication.state должен оставаться planned до отдельного apply")
    if not DOMAIN_RE.fullmatch(domain):
        raise PublicationContractError("publication.domain должен быть нормализованным DNS-именем")
    if (profile.get("domains") or {}).get("prod") != [domain]:
        raise PublicationContractError("domains.prod должен содержать только publication.domain")
    if publication.get("allowed_hosts") != [domain]:
        raise PublicationContractError("publication.allowed_hosts должен содержать только публичный домен")
    if publication.get("csrf_trusted_origins") != [f"https://{domain}"]:
        raise PublicationContractError("publication.csrf_trusted_origins должен содержать только HTTPS origin")
    if publication.get("tls") != {
        "termination": "site-nginx",
        "edge_mode": "sni-passthrough",
        "provider": "letsencrypt",
        "challenge": "http-01",
    }:
        raise PublicationContractError("publication.tls не соответствует canonical TLS contract")
    health = runtime.get("health") or {}
    if publication.get("external_health") != [health.get("live"), health.get("ready")]:
        raise PublicationContractError("Снаружи разрешены только live и ready endpoints")
    if publication.get("private_endpoints") != [health.get("worker")]:
        raise PublicationContractError("worker health должен оставаться private")

    ingress_alias = str(operator_publication.get("ingress_alias") or "")
    backend = str(operator_publication.get("backend_ipv4") or "")
    if ingress_alias != limit:
        raise PublicationContractError("publication.ingress_alias должен совпадать с placement и -Limit")
    if operator_publication.get("dns_cname") != f"{limit}.mine-craft.su":
        raise PublicationContractError("publication.dns_cname должен указывать на ingress alias")
    try:
        ipaddress.IPv4Address(backend)
    except ipaddress.AddressValueError as exc:
        raise PublicationContractError("publication.backend_ipv4 должен быть IPv4") from exc
    if backend != (placement.get("network") or {}).get("anchor_ipv4"):
        raise PublicationContractError("publication.backend_ipv4 должен совпадать с anchor_ipv4")
    http_port = operator_publication.get("http_port")
    https_port = operator_publication.get("https_port")
    if http_port != 8080 or https_port != 8443 or http_port == https_port:
        raise PublicationContractError("publication ports должны быть 8080/http и 8443/https")
    if operator_publication.get("public_route_enabled") is not False:
        raise PublicationContractError("public_route_enabled должен оставаться false на check-only рубеже")
    if ingress_alias not in _active_aliases(state_path, "service", "site_runtime"):
        raise PublicationContractError("site_runtime отсутствует на ingress alias")
    if ingress_alias not in _active_aliases(state_path, "service", "edge_haproxy"):
        raise PublicationContractError("edge_haproxy отсутствует на ingress alias")

    rendered = _render_contract(instance_name, domain, backend, http_port, https_port)
    return {
        "instance": instance_name,
        "placement_alias": limit,
        "state": "planned",
        "check_mode_mutations": False,
        "domain": domain,
        "dns": {"type": "CNAME", "expected_target": operator_publication["dns_cname"]},
        "edge": {
            "ingress_alias": ingress_alias,
            "mode": "tcp-sni-passthrough",
            "application_network": placement["network"]["app_network"],
            "http_acme_backend": f"{backend}:{http_port}",
            "https_backend": f"{backend}:{https_port}",
            "public_route_enabled": False,
        },
        "application": {
            "allowed_hosts": publication["allowed_hosts"],
            "csrf_trusted_origins": publication["csrf_trusted_origins"],
        },
        "health": {
            "external": publication["external_health"],
            "private": publication["private_endpoints"],
        },
        "security": {
            "public_component": "nginx",
            "gunicorn_public": False,
            "redis_public": False,
            "postgres_public": False,
            "private_media_public": False,
        },
        "tls": publication["tls"],
        "render": rendered,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--instances", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--instance", required=True)
    parser.add_argument("--limit", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        model = resolve(args.registry, args.instances, args.state, args.instance, args.limit)
    except (OSError, yaml.YAMLError, PublicationContractError) as exc:
        print(f"site_runtime publication contract error: {exc}")
        return 2
    payload = json.dumps(model, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(payload, encoding="utf-8")
    else:
        print(payload, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
