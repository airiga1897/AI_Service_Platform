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
        self.assertEqual("airiga1897@gmail.com", model["acme"]["contact_email"])
        self.assertEqual(
            "certbot/certbot@sha256:"
            "34ee91d2f43008eb78a007d22f23ed4b2eaa9a454cb27ca2c042b49527a695b4",
            model["acme"]["source_ref"],
        )
        self.assertFalse(model["edge"]["public_route_enabled"])
        self.assertFalse(model["check_mode_mutations"])
        self.assertEqual(["/healthz/", "/readyz/"], model["health"]["external"])
        self.assertEqual(["/worker-healthz/"], model["health"]["private"])
        self.assertEqual("webroot", model["acme"]["issuance"]["mode"])
        self.assertEqual(
            "container:site-runtime-ai-retail-mvp-anchor",
            model["acme"]["issuance"]["network_mode"],
        )
        self.assertEqual(
            "/var/www/acme", model["acme"]["issuance"]["webroot_path"]
        )
        self.assertTrue(model["acme"]["issuance"]["non_interactive"])
        self.assertTrue(model["acme"]["issuance"]["agree_tos"])
        self.assertTrue(model["acme"]["issuance"]["keep_until_expiring"])

    def test_render_keeps_tls_on_site_nginx(self) -> None:
        model = self.call()
        https = model["render"]["documents"]["haproxy_https_fragment"]
        nginx = model["render"]["documents"]["nginx_public_fragment"]
        self.assertIn("req_ssl_sni -i retail.travelltickets.ru", https)
        self.assertIn("172.31.3.10:8443", https)
        self.assertIn("listen 8443 ssl", nginx)
        self.assertIn("X-Forwarded-Proto https", nginx)

    def test_https_preflight_extends_fail_closed_sni_contract(self) -> None:
        model = self.call()
        https = model["render"]["https"]
        self.assertEqual(
            "    tcp-request content silent-drop unless ",
            https["allow_condition_prefix"],
        )
        self.assertEqual(
            "    tcp-request content accept if { req_ssl_hello_type 1 }",
            https["accept_anchor"],
        )
        self.assertEqual("sni_site_ai_retail_mvp", https["sni_acl"])
        self.assertIn(
            "acl sni_site_ai_retail_mvp req_ssl_sni -i retail.travelltickets.ru",
            https["documents"]["haproxy_frontend_acl"],
        )
        self.assertIn(
            "use_backend be_site_ai_retail_mvp_https if sni_site_ai_retail_mvp",
            https["documents"]["haproxy_frontend_use_backend"],
        )
        self.assertIn("172.31.3.10:8443", https["documents"]["haproxy_backend"])

    def test_https_preflight_resolves_production_environment(self) -> None:
        application = self.call()["application"]
        self.assertEqual(
            [
                "ai-retail-mvp.internal",
                "retail.travelltickets.ru",
                "localhost",
                "127.0.0.1",
            ],
            application["runtime_allowed_hosts"],
        )
        self.assertEqual(
            "ai-retail-mvp.internal,retail.travelltickets.ru,localhost,127.0.0.1",
            application["environment"]["ALLOWED_HOSTS"],
        )
        self.assertEqual(
            "https://retail.travelltickets.ru",
            application["environment"]["CSRF_TRUSTED_ORIGINS"],
        )

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

    def test_rejects_invalid_acme_contact_email(self) -> None:
        registry = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
        instances = yaml.safe_load(self.instances.read_text(encoding="utf-8"))
        instances["instances"]["ai-retail-mvp"]["publication"]["acme_contact_email"] = "invalid"
        with self.assertRaisesRegex(PublicationContractError, "acme_contact_email"):
            self.call_data(registry, instances)

    def test_certbot_uses_existing_exact_support_image_pipeline(self) -> None:
        prepare = (ROOT / "tools/site_runtime/prepare_support_images.ps1").read_text(
            encoding="utf-8"
        )
        stage = (
            ROOT / "infra/ansible/roles/site_runtime_support_images_stage/tasks/main.yml"
        ).read_text(encoding="utf-8")
        apply = (
            ROOT / "infra/ansible/roles/site_runtime_apply/tasks/main.yml"
        ).read_text(encoding="utf-8")
        self.assertIn(
            'certbot = "certbot/certbot@sha256:'
            '34ee91d2f43008eb78a007d22f23ed4b2eaa9a454cb27ca2c042b49527a695b4"',
            prepare,
        )
        self.assertIn("site_runtime_support_model.images | length == 3", stage)
        self.assertIn("['certbot', 'nginx', 'redis']", stage)
        self.assertIn("site_runtime_support_images.certbot.source_ref", apply)

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
        self.assertNotIn("site_runtime publication-certificate requires --check", service)
        self.assertNotIn("site_runtime publication-certificate requires -Check", remote)
        self.assertIn(
            '[ "$ACTION" = "publication-http01" ] || [ "$ACTION" = "publication-certificate" ]',
            service,
        )
        self.assertIn("site_runtime publication-https --instance NAME --limit ALIAS [--check]", service)
        self.assertNotIn("site_runtime publication-https requires --check", service)
        self.assertNotIn("site_runtime publication-https requires -Check", remote)
        self.assertIn('"publication-certificate" ] || [ "$ACTION" = "publication-https"', service)

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

    def test_certificate_preflight_is_read_only_and_exact(self) -> None:
        tasks = (
            ROOT
            / "infra/ansible/roles/site_runtime_publication_check/tasks/certificate_check.yml"
        ).read_text(encoding="utf-8")
        main = (
            ROOT / "infra/ansible/roles/site_runtime_publication_check/tasks/main.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("Выполнить read-only preflight выпуска TLS-сертификата", main)
        self.assertIn("publication-certificate", main)
        self.assertIn("site_runtime_certificate_support", tasks)
        self.assertIn("site_runtime_certificate_certbot.config_image_id", tasks)
        self.assertIn("site_runtime_certificate_certbot.transport_tag", tasks)
        self.assertIn("site_runtime_certificate_nginx_acme_mounts", tasks)
        self.assertIn("site_runtime_certificate_nginx_tls_mounts", tasks)
        self.assertIn("site_runtime_certificate_haproxy.count", tasks)
        self.assertIn("platform-certificate-preflight", tasks)
        self.assertIn("NoRedirect", tasks)
        self.assertIn('root_location == "https://" + domain + "/"', tasks)
        self.assertIn("external_root_status", tasks)
        self.assertIn("external_root_redirect", tasks)
        self.assertIn("external_challenge_status", tasks)
        self.assertIn("certificate_requested: false", tasks)
        self.assertIn("mutation_performed: false", tasks)
        self.assertIn("containers_changed: false", tasks)
        self.assertIn("volumes_changed: false", tasks)
        self.assertIn("current.json, Compose или HAProxy", tasks)
        self.assertNotIn("docker\n      - run", tasks)
        self.assertNotIn("certonly", tasks)
        self.assertNotIn("state: touch", tasks)

    def test_certificate_apply_is_exact_journaled_and_does_not_publish_https(self) -> None:
        tasks = (
            ROOT
            / "infra/ansible/roles/site_runtime_publication_check/tasks/certificate_apply.yml"
        ).read_text(encoding="utf-8")
        main = (
            ROOT / "infra/ansible/roles/site_runtime_publication_check/tasks/main.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("Выпустить и принять TLS-сертификат без публикации приложения", main)
        self.assertIn("not ansible_check_mode", main)
        self.assertIn("--pull", tasks)
        self.assertIn("- never", tasks)
        self.assertIn("site_runtime_certificate_certbot.transport_tag", tasks)
        self.assertIn("site_runtime_publication_model.acme.issuance.network_mode", tasks)
        self.assertIn("--cap-drop", tasks)
        self.assertIn("no-new-privileges:true", tasks)
        self.assertIn("--webroot", tasks)
        self.assertIn("--keep-until-expiring", tasks)
        self.assertIn("no_log: true", tasks)
        self.assertIn("ssl._ssl._test_decode_cert", tasks)
        self.assertIn("days_remaining >= 14", tasks)
        self.assertIn("Записать успешный certificate journal", tasks)
        self.assertIn("Записать failed certificate journal без секретов", tasks)
        self.assertIn("tls_preserved_for_diagnostics", tasks)
        self.assertIn("https_route_enabled", tasks)
        self.assertIn("'application_published': false", tasks)
        self.assertNotIn("docker compose", tasks)
        self.assertNotIn("network\n          - connect", tasks)
        self.assertNotIn("haproxy -c", tasks)

    def test_https_preflight_is_read_only_and_checks_future_configs(self) -> None:
        tasks = (
            ROOT
            / "infra/ansible/roles/site_runtime_publication_check/tasks/https_check.yml"
        ).read_text(encoding="utf-8")
        main = (
            ROOT / "infra/ansible/roles/site_runtime_publication_check/tasks/main.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("Проверить будущую HTTPS/SNI публикацию без изменений", main)
        self.assertIn("publication-https", main)
        self.assertIn("prospective fail-closed HAProxy config", tasks)
        self.assertIn('"frontend https_in"', tasks)
        self.assertIn("future_section", tasks)
        self.assertIn("allow_condition_prefix", tasks)
        self.assertIn("existing HTTPS/SNI ACL is outside fail-closed allow condition", tasks)
        self.assertIn("site_runtime_publication_https_route_already_applied", tasks)
        self.assertIn("site_runtime_publication_https_haproxy_metadata", tasks)
        self.assertIn("Подготовить byte-exact HAProxy preflight candidate", tasks)
        self.assertIn("stdin_add_newline: false", tasks)
        self.assertIn("Проверить exact HAProxy candidate через bind-mounted каталог", tasks)
        self.assertIn("Удалить временный HAProxy preflight candidate", tasks)
        self.assertIn("Publication receipt и фактический HTTPS/SNI route расходятся", tasks)
        self.assertIn("haproxy", tasks)
        self.assertIn("- /dev/stdin", tasks)
        self.assertIn("prospective Nginx TLS config с гарантированной очисткой", tasks)
        self.assertIn("trap cleanup EXIT HUP INT TERM", tasks)
        self.assertIn("Подтвердить удаление временного prospective Nginx config", tasks)
        self.assertIn("events {}", tasks)
        self.assertIn("runtime.env", tasks)
        self.assertIn("CSRF_TRUSTED_ORIGINS", tasks)
        self.assertIn("other_keys_unchanged", tasks)
        self.assertIn("certificate_accepted", tasks)
        self.assertIn(
            "Прочитать канонический application current перед HTTPS/SNI preflight",
            tasks,
        )
        self.assertIn(
            "site_runtime_publication_https_current.compose_checksum",
            tasks,
        )
        self.assertIn("sni_route_applied:", tasks)
        self.assertIn("application_published:", tasks)
        self.assertIn("mutation_performed: false", tasks)
        self.assertIn("Доставить byte-exact writer для HAProxy preflight", tasks)
        self.assertNotIn(
            'dest: "{{ site_runtime_publication_edge_config }}"',
            tasks,
        )
        self.assertNotIn("docker compose", tasks)
        self.assertNotIn("network\n      - connect", tasks)
        self.assertNotIn("certonly", tasks)

    def test_https_apply_is_transactional_and_keeps_backend_private(self) -> None:
        tasks = (
            ROOT
            / "infra/ansible/roles/site_runtime_publication_check/tasks/https_apply.yml"
        ).read_text(encoding="utf-8")
        resolver = (
            ROOT / "tools/site_runtime/resolve_publication.py"
        ).read_text(encoding="utf-8")
        main = (
            ROOT / "infra/ansible/roles/site_runtime_publication_check/tasks/main.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("Применить и принять HTTPS/SNI публикацию", main)
        self.assertIn("not ansible_check_mode", main)
        self.assertIn("Сохранить закрытый snapshot production environment", tasks)
        self.assertIn("Сохранить snapshot Nginx перед HTTPS publication", tasks)
        self.assertIn("Сохранить snapshot HAProxy перед SNI route", tasks)
        self.assertIn("Атомарно применить production host и CSRF environment", tasks)
        self.assertIn("--force-recreate", tasks)
        self.assertIn("- web", tasks)
        self.assertIn("- worker", tasks)
        self.assertIn("- beat", tasks)
        self.assertIn("- nginx", tasks)
        self.assertIn("Дождаться private health до открытия SNI route", tasks)
        self.assertIn("Принять локальный TLS endpoint до открытия SNI route", tasks)
        self.assertIn("Атомарно активировать проверенный HAProxy SNI candidate", tasks)
        self.assertIn("Принять запущенный HAProxy после применения SNI route", tasks)
        self.assertIn("docker port", tasks)
        self.assertIn("site_runtime_publication_https_haproxy_metadata.sha256", tasks)
        self.assertIn("prepare", tasks)
        self.assertIn("activate", tasks)
        self.assertIn("--expected-sha256", tasks)
        self.assertIn("stdin_add_newline: false", tasks)
        self.assertIn("Проверить внешний HTTPS health и закрытые endpoints", tasks)
        self.assertIn("5432, 6379, 8000", tasks)
        self.assertIn("Записать успешный HTTPS/SNI journal", tasks)
        self.assertIn(
            "'compose_checksum': site_runtime_publication_https_current.compose_checksum",
            tasks,
        )
        self.assertIn(
            "'deployment_digest': site_runtime_publication_https_current.digest",
            tasks,
        )
        self.assertNotIn(
            "site_runtime_publication_https_receipt.compose_checksum",
            tasks,
        )
        self.assertIn("Записать failed HTTPS/SNI journal", tasks)
        self.assertIn("Восстановить закрытый production environment после ошибки", tasks)
        self.assertIn("Восстановить ACME-only Nginx config после ошибки", tasks)
        self.assertIn("Восстановить HAProxy config после ошибки HTTPS/SNI", tasks)
        self.assertIn("Принять private health после аварийного восстановления", tasks)
        self.assertIn("Принять HAProxy после аварийного восстановления", tasks)
        self.assertIn("'rollback_status': site_runtime_publication_https_rollback_status", tasks)
        self.assertIn(
            "ansible_failed_task | default({'name': 'unknown'})",
            tasks,
        )
        self.assertIn("Удалить HAProxy candidate после HTTPS/SNI transaction", tasks)
        self.assertIn("location /static/", resolver)
        self.assertIn("location /media/", resolver)
        self.assertIn("location ^~ /private_media/", resolver)
        self.assertIn("location = /worker-healthz/", resolver)
        self.assertIn("proxy_pass http://127.0.0.1:8000", resolver)
        self.assertNotIn("ports:", tasks)
        self.assertNotIn("certbot", tasks.lower())


if __name__ == "__main__":
    unittest.main()
