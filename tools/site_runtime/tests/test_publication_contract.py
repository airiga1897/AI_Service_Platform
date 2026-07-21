from __future__ import annotations

import unittest
from pathlib import Path
from unittest import mock

import yaml

from tools.site_runtime import resolve_publication as publication
from tools.site_runtime.resolve_publication import PublicationContractError, resolve


ROOT = Path(__file__).resolve().parents[3]


class PublicationContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = ROOT / "services.yml"
        self.instances = ROOT / "operator/site_runtime/instances.yml"
        self.state = ROOT / "operator/state.csv"

    def call(self, registry: Path | None = None, instances: Path | None = None, limit: str = "vps3"):
        return resolve(
            registry or self.registry,
            instances or self.instances,
            self.state,
            "ai-retail-mvp",
            limit,
        )

    def call_data(self, registry: dict, instances: dict | None = None):
        placement_data = instances or yaml.safe_load(self.instances.read_text(encoding="utf-8"))
        with (
            mock.patch.object(publication, "_load_yaml", side_effect=[registry, placement_data]),
            mock.patch.object(publication, "_active_aliases", return_value={"vps3"}),
        ):
            return resolve(Path("registry.yml"), Path("instances.yml"), Path("state.csv"), "ai-retail-mvp", "vps3")

    def test_resolves_check_only_publication(self) -> None:
        model = self.call()
        self.assertEqual("retail.travelltickets.ru", model["domain"])
        self.assertEqual("vps3.mine-craft.su", model["dns"]["expected_target"])
        self.assertFalse(model["edge"]["public_route_enabled"])
        self.assertFalse(model["check_mode_mutations"])
        self.assertEqual(["/healthz/", "/readyz/"], model["health"]["external"])
        self.assertEqual(["/worker-healthz/"], model["health"]["private"])

    def test_render_keeps_tls_on_site_nginx(self) -> None:
        model = self.call()
        https = model["render"]["documents"]["haproxy_https_fragment"]
        nginx = model["render"]["documents"]["nginx_public_fragment"]
        self.assertIn("req_ssl_sni -i retail.travelltickets.ru", https)
        self.assertIn("172.31.3.10:8443", https)
        self.assertIn("listen 8443 ssl", nginx)
        self.assertIn("X-Forwarded-Proto https", nginx)

    def test_http_exposes_only_acme_challenge(self) -> None:
        model = self.call()
        nginx = model["render"]["documents"]["nginx_public_fragment"]
        self.assertIn("/.well-known/acme-challenge/", nginx)
        self.assertIn("location / { return 404; }", nginx)

    def test_security_contract_keeps_internal_services_private(self) -> None:
        security = self.call()["security"]
        for field in ("gunicorn_public", "redis_public", "postgres_public", "private_media_public"):
            self.assertFalse(security[field])

    def test_rejects_domain_drift(self) -> None:
        data = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
        data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["publication"]["domain"] = "wrong.example"
        with self.assertRaisesRegex(PublicationContractError, "domains.prod"):
            self.call_data(data)

    def test_rejects_public_worker_health(self) -> None:
        data = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
        publication = data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["publication"]
        publication["external_health"].append("/worker-healthz/")
        with self.assertRaisesRegex(PublicationContractError, "только live и ready"):
            self.call_data(data)

    def test_rejects_tls_termination_on_haproxy(self) -> None:
        data = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
        data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["publication"]["tls"][
            "termination"
        ] = "haproxy"
        with self.assertRaisesRegex(PublicationContractError, "TLS contract"):
            self.call_data(data)

    def test_rejects_enabled_route_on_check_only_milestone(self) -> None:
        data = yaml.safe_load(self.instances.read_text(encoding="utf-8"))
        data["instances"]["ai-retail-mvp"]["publication"]["public_route_enabled"] = True
        with self.assertRaisesRegex(PublicationContractError, "должен оставаться false"):
            registry = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
            self.call_data(registry, data)

    def test_rejects_limit_mismatch(self) -> None:
        with self.assertRaisesRegex(PublicationContractError, "placement_alias"):
            self.call(limit="vps4")

    def test_requires_edge_haproxy_on_ingress(self) -> None:
        registry = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
        instances = yaml.safe_load(self.instances.read_text(encoding="utf-8"))
        with (
            mock.patch.object(publication, "_load_yaml", side_effect=[registry, instances]),
            mock.patch.object(publication, "_active_aliases", side_effect=[{"vps3"}, set()]),
            self.assertRaisesRegex(PublicationContractError, "edge_haproxy отсутствует"),
        ):
            resolve(Path("registry.yml"), Path("instances.yml"), Path("state.csv"), "ai-retail-mvp", "vps3")

    def test_service_interface_requires_check_mode(self) -> None:
        service = (ROOT / "tools/services/service.sh").read_text(encoding="utf-8")
        remote = (ROOT / "tools/services/service_remote.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("site_runtime_publication_check.yml", service)
        self.assertIn('publication-check requires --check', service)
        self.assertIn('publication-check requires -Check', remote)

    def test_ansible_check_role_contains_no_mutating_runtime_commands(self) -> None:
        tasks = (
            ROOT / "infra/ansible/roles/site_runtime_publication_check/tasks/main.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("ansible_check_mode", tasks)
        self.assertIn("check_mode_mutations: false", tasks)
        for forbidden in ("docker compose up", "docker network connect", "certbot certonly"):
            self.assertNotIn(forbidden, tasks)


if __name__ == "__main__":
    unittest.main()
