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

    def test_preparation_contract_declares_persistent_acme_and_tls_storage(self) -> None:
        model = self.call()
        self.assertEqual("ai_retail_mvp_acme_webroot", model["storage"]["acme_webroot"]["volume"])
        self.assertEqual("ai_retail_mvp_tls", model["storage"]["tls"]["volume"])
        override = model["render"]["preparation"]["documents"]["compose_override_fragment"]
        compose = yaml.safe_load(override)
        self.assertEqual(
            [
                "./nginx-publication-acme.conf:/etc/nginx/conf.d/publication-acme.conf:ro",
                "acme_webroot_data:/var/www/acme:ro",
                "tls_data:/etc/letsencrypt:ro",
            ],
            compose["services"]["nginx"]["volumes"],
        )
        self.assertEqual(
            "ai_retail_mvp_acme_webroot", compose["volumes"]["acme_webroot_data"]["name"]
        )
        self.assertEqual("ai_retail_mvp_tls", compose["volumes"]["tls_data"]["name"])

    def test_preparation_http_server_does_not_publish_application(self) -> None:
        model = self.call()
        nginx = model["render"]["preparation"]["documents"]["nginx_acme_fragment"]
        self.assertIn("/.well-known/acme-challenge/", nginx)
        self.assertIn("location / { return 404; }", nginx)
        self.assertNotIn("proxy_pass", nginx)

    def test_http01_contract_is_host_scoped_and_preserves_placeholder(self) -> None:
        http01 = self.call()["render"]["http01"]
        rules = http01["documents"]["haproxy_frontend_rules"]
        backend = http01["documents"]["haproxy_backend"]
        self.assertIn("hdr(host) -i retail.travelltickets.ru", rules)
        self.assertIn("path_beg /.well-known/acme-challenge/", rules)
        self.assertIn("use_backend be_site_ai_retail_mvp_http", rules)
        self.assertIn("172.31.3.10:8080", backend)
        self.assertTrue(backend.startswith("\nbackend be_site_ai_retail_mvp_http"))
        self.assertNotIn("\\nbackend", backend)
        self.assertEqual(
            "    use_backend be_acme_placeholder if is_acme",
            http01["insertion_anchor"],
        )

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

    def test_rejects_duplicate_publication_storage_volume(self) -> None:
        data = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
        runtime = data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]
        runtime["publication"]["storage"]["tls"]["volume"] = runtime["storage"][
            "public_media"
        ]["volume"]
        with self.assertRaisesRegex(PublicationContractError, "не должны совпадать"):
            self.call_data(data)

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

    def test_service_interface_keeps_check_strict_and_allows_real_publication_steps(self) -> None:
        service = (ROOT / "tools/services/service.sh").read_text(encoding="utf-8")
        remote = (ROOT / "tools/services/service_remote.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("site_runtime_publication_check.yml", service)
        self.assertIn("site_runtime publication-check requires --check", service)
        self.assertNotIn("site_runtime publication-prepare requires --check", service)
        self.assertIn('"apply" ] || [ "$ACTION" = "publication-prepare"', service)
        self.assertIn("site_runtime publication-check requires -Check", remote)
        self.assertNotIn("site_runtime publication-prepare requires -Check", remote)
        self.assertNotIn("site_runtime publication-http01 requires --check", service)
        self.assertNotIn("site_runtime publication-http01 requires -Check", remote)
        self.assertIn('"publication-prepare" ] || [ "$ACTION" = "publication-http01"', service)

    def test_ansible_role_guards_real_mutations_from_check_mode(self) -> None:
        tasks = (
            ROOT / "infra/ansible/roles/site_runtime_publication_check/tasks/main.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("ansible_check_mode", tasks)
        self.assertIn("check_mode_mutations: false", tasks)
        self.assertIn("- docker\n      - volume\n      - inspect", tasks)
        self.assertIn("not ansible_check_mode", tasks)
        self.assertIn("Создать persistent ACME webroot volume", tasks)
        self.assertIn("ai-service-platform.storage=acme_webroot", tasks)
        self.assertIn("ai-service-platform.storage=tls", tasks)
        self.assertIn("автоматическое подключение или перезапись запрещены", tasks)
        self.assertIn("Пересоздать только Nginx с ACME/TLS mounts", tasks)
        self.assertIn("--no-deps", tasks)
        self.assertIn("application_current_unchanged", tasks)
        self.assertIn("base_compose_unchanged", tasks)
        self.assertIn("site_runtime_publication_edge_networks_after.stdout", tasks)
        self.assertIn("selectattr('Type', 'equalto', 'volume')", tasks)
        self.assertIn("application current.json изменился во время preparation", tasks)
        self.assertIn("базовый Compose изменился во время preparation", tasks)
        self.assertIn("site_runtime_publication_already_prepared", tasks)
        self.assertIn("Записать failed publication preparation journal", tasks)
        self.assertIn("Восстановить предыдущую конфигурацию Nginx", tasks)
        self.assertIn("volumes_preserved_for_diagnostics", tasks)
        self.assertIn("Сформировать prospective HAProxy config в памяти", tasks)
        self.assertIn("haproxy -c -f /dev/stdin", tasks)
        self.assertIn("current_external_status", tasks)
        self.assertIn("application_published", tasks)
        self.assertIn("Подключить edge HAProxy к private application network", tasks)
        self.assertIn("docker\n          - network\n          - connect", tasks)
        self.assertIn("Атомарно записать принятый HTTP-01 HAProxy config", tasks)
        self.assertIn("Сохранить snapshot HAProxy перед HTTP-01 route", tasks)
        self.assertIn("Восстановить предыдущий HAProxy config после ошибки", tasks)
        self.assertIn("Вернуть исходное network attachment после ошибки", tasks)
        self.assertIn("Проверить применённый HTTP-01 route извне", tasks)
        self.assertIn("site_runtime_publication_http01_route_already_applied", tasks)
        self.assertIn("mutation_performed", tasks)
        for forbidden in (
            "docker compose up",
            "certbot certonly",
        ):
            self.assertNotIn(forbidden, tasks)


if __name__ == "__main__":
    unittest.main()
