from __future__ import annotations

import ast
import json
import tempfile
import textwrap
import unittest
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined
import yaml

from tools.site_runtime.resolve_env import resolve_env


ROOT = Path(__file__).resolve().parents[3]


class RuntimeEnvironmentTests(unittest.TestCase):
    def test_uses_only_product_password_from_postgres_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / "app.env"
            pg_config = root / "postgres.yml"
            pg_secrets = root / "postgres.env"
            app.write_text("SECRET_KEY=" + "x" * 64 + "\nOPENAI_API_KEY=optional\n", encoding="utf-8")
            pg_config.write_text(yaml.safe_dump({"managed_databases": {"ai-retail-mvp": {
                "database": "ai_retail_mvp", "owner_role": "ai_retail_mvp",
                "password_secret": "POSTGRES_PRODUCT_AI_RETAIL_MVP_PASSWORD"}}}), encoding="utf-8")
            pg_secrets.write_text(
                "POSTGRES_PRODUCT_AI_RETAIL_MVP_PASSWORD=product-password\n"
                "POSTGRES_SUPERUSER_PASSWORD=must-not-leak\n", encoding="utf-8")
            result = resolve_env(app, pg_config, pg_secrets, "ai-retail-mvp")
            self.assertEqual(result["DB_PASSWORD"], "product-password")
            self.assertNotIn("POSTGRES_SUPERUSER_PASSWORD", result)

    def test_reads_canonical_nested_postgres_config(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / "app.env"
            pg_config = root / "postgres.yml"
            pg_secrets = root / "postgres.env"
            app.write_text("SECRET_KEY=" + "x" * 64 + "\n", encoding="utf-8")
            pg_config.write_text(yaml.safe_dump({"postgres_runtime": {"managed_databases": {"ai-retail-mvp": {
                "database": "ai_retail_mvp", "owner_role": "ai_retail_mvp",
                "password_secret": "POSTGRES_PRODUCT_AI_RETAIL_MVP_PASSWORD"}}}}), encoding="utf-8")
            pg_secrets.write_text("POSTGRES_PRODUCT_AI_RETAIL_MVP_PASSWORD=product-password\n", encoding="utf-8")
            result = resolve_env(app, pg_config, pg_secrets, "ai-retail-mvp")
            self.assertEqual(result["DB_PASSWORD"], "product-password")

    def test_rejects_database_password_in_application_secret(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / "app.env"
            config = root / "config.yml"
            secrets = root / "secrets.env"
            app.write_text("SECRET_KEY=" + "x" * 64 + "\nDB_PASSWORD=duplicate\n", encoding="utf-8")
            config.write_text("managed_databases: {}\n", encoding="utf-8")
            secrets.write_text("X=y\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "не должен содержать"):
                resolve_env(app, config, secrets, "ai-retail-mvp")

    def test_rejects_superuser_or_seed_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / "app.env"
            config = root / "config.yml"
            secrets = root / "secrets.env"
            app.write_text("SECRET_KEY=" + "x" * 64 + "\nDJANGO_SUPERUSER_PASSWORD=forbidden\n", encoding="utf-8")
            config.write_text("managed_databases: {}\n", encoding="utf-8")
            secrets.write_text("X=y\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "не должен содержать"):
                resolve_env(app, config, secrets, "ai-retail-mvp")


class ComposeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.template = (ROOT / "infra/ansible/roles/site_runtime_apply/templates/docker-compose.yml.j2").read_text(encoding="utf-8")
        environment = Environment(undefined=StrictUndefined, autoescape=False)
        environment.filters["to_json"] = json.dumps
        environment.filters["bool"] = bool
        cls.render_environment = environment
        cls.render_context = {
            "site_runtime_publication_preserved": False,
            "site_runtime_anchor_image": "anchor@sha256:" + "a" * 64,
            "site_runtime_route_reconcile_seconds": 30,
            "site_runtime_support_images": {
                "redis": {"transport_tag": "support/redis:exact"},
                "nginx": {"transport_tag": "support/nginx:exact"},
            },
            "site_runtime_model": {
                "instance": "ai-retail-mvp",
                "transport_tag": "product/ai-retail-mvp:exact",
                "network": {
                    "anchor_ipv4": "172.31.3.10",
                    "app_network": "ai_service_app_vps3",
                    "postgres_route": {
                        "destination": "172.30.8.10/32",
                        "via": "172.31.3.2",
                    },
                },
                "runtime_contract": {
                    "volumes": {"redis": "ai_retail_mvp_redis"},
                    "storage": {
                        "release_static": {
                            "volume": "ai_retail_mvp_static_" + "b" * 64,
                            "container_path": "/app/staticfiles",
                        },
                        "public_media": {
                            "volume": "ai_retail_mvp_media",
                            "container_path": "/app/media",
                        },
                        "private_media": {
                            "volume": "ai_retail_mvp_private_media",
                            "container_path": "/app/private_media",
                        },
                    },
                    "components": {
                        "static": {"command": "python manage.py collectstatic --noinput"},
                        "migration": {"command": "python manage.py migrate --noinput"},
                        "web": {"command": "gunicorn app.wsgi:application"},
                        "worker": {"command": "python -m celery worker"},
                        "beat": {"command": "python -m celery beat"},
                    },
                },
            },
        }
        cls.rendered = environment.from_string(cls.template).render(**cls.render_context)
        cls.rendered_compose = yaml.safe_load(cls.rendered)

    def test_shared_namespace_and_single_net_admin(self) -> None:
        self.assertEqual(self.template.count("NET_ADMIN"), 1)
        self.assertGreaterEqual(self.template.count("network_mode: service:anchor"), 6)
        self.assertNotIn("ports:", self.template)

    def test_product_entrypoint_and_one_shot_migration(self) -> None:
        self.assertGreaterEqual(self.template.count("entrypoint: []"), 5)
        self.assertGreaterEqual(self.template.count('["/bin/sh", "-ec"'), 5)
        self.assertEqual(self.template.count("profiles: [deployment]"), 2)
        self.assertEqual(self.template.count("restart: \"no\""), 2)

    def test_frontend_static_is_prepared_by_one_shot_container(self) -> None:
        self.assertIn("  static:\n", self.template)
        self.assertIn("runtime_contract.components.static.command", self.template)
        static_block = self.template.split("  static:\n", 1)[1].split("\n  web:", 1)[0]
        self.assertIn("release_static_data:", static_block)
        self.assertNotIn("public_media_data:", static_block)
        self.assertNotIn("private_media_data:", static_block)
        self.assertNotIn("ports:", static_block)

    def test_static_preparation_precedes_migration(self) -> None:
        tasks = (ROOT / "infra/ansible/roles/site_runtime_apply/tasks/main.yml").read_text(encoding="utf-8")
        static_step = tasks.index("Подготовить frontend/static единственным one-shot контейнером")
        migration_step = tasks.index("Выполнить единственный migration step")
        self.assertLess(static_step, migration_step)

    def test_named_volumes_are_preserved(self) -> None:
        for name in (
            "redis_data",
            "release_static_data",
            "public_media_data",
            "private_media_data",
        ):
            self.assertIn(name, self.template)

    def test_storage_access_contract(self) -> None:
        migration = self.template.split("  migration:\n", 1)[1].split("\n  static:", 1)[0]
        static = self.template.split("  static:\n", 1)[1].split("\n  web:", 1)[0]
        web = self.template.split("  web:\n", 1)[1].split("\n  worker:", 1)[0]
        worker = self.template.split("  worker:\n", 1)[1].split("\n  beat:", 1)[0]
        nginx = self.template.split("  nginx:\n", 1)[1].split("\nnetworks:", 1)[0]

        self.assertNotIn("_data:", migration)
        self.assertIn("release_static_data:", static)
        self.assertIn("release_static_data:", web)
        self.assertIn("container_path }}:ro", web)
        for block in (web, worker):
            self.assertIn("public_media_data:", block)
            self.assertIn("private_media_data:", block)
        self.assertIn("release_static_data:/srv/static:ro", nginx)
        self.assertIn("public_media_data:/srv/media:ro", nginx)
        self.assertNotIn("private_media_data:", nginx)

    def test_rendered_storage_identities_and_mounts(self) -> None:
        compose = self.rendered_compose
        self.assertEqual(
            compose["volumes"]["release_static_data"]["name"],
            "ai_retail_mvp_static_" + "b" * 64,
        )
        self.assertEqual(
            compose["volumes"]["private_media_data"]["name"],
            "ai_retail_mvp_private_media",
        )
        self.assertNotIn("volumes", compose["services"]["migration"])
        self.assertEqual(
            compose["services"]["static"]["volumes"],
            ["release_static_data:/app/staticfiles"],
        )
        self.assertIn(
            "release_static_data:/app/staticfiles:ro",
            compose["services"]["web"]["volumes"],
        )
        for service in ("web", "worker"):
            self.assertIn(
                "private_media_data:/app/private_media",
                compose["services"][service]["volumes"],
            )
        self.assertNotIn(
            "private_media_data:/app/private_media",
            compose["services"]["nginx"]["volumes"],
        )

    def test_unmanaged_private_media_guard_precedes_snapshot_and_apply(self) -> None:
        tasks = (ROOT / "infra/ansible/roles/site_runtime_apply/tasks/main.yml").read_text(
            encoding="utf-8"
        )
        guard = tasks.index("Проверить unmanaged private media")
        snapshot = tasks.index("Сохранить предыдущие runtime artifacts")
        static = tasks.index("Подготовить frontend/static единственным one-shot контейнером")
        migration = tasks.index("Выполнить единственный migration step")
        health = tasks.index("Проверить private health endpoints")

        self.assertLess(guard, snapshot)
        self.assertLess(snapshot, static)
        self.assertLess(static, migration)
        self.assertLess(migration, health)
        self.assertIn("unmanaged_private_media_entries", tasks)
        self.assertIn('"docker", "compose", "-f", compose_file, "ps", "-aq", "web", "worker"', tasks)
        self.assertNotIn('"site-runtime-{{ site_runtime_instance }}-web"', tasks)
        self.assertIn("site_runtime_current_deployment.get('storage', {})", tasks)
        self.assertIn(
            "site_runtime_current_deployment.get('environment_checksum') == site_runtime_environment_checksum",
            tasks,
        )
        self.assertIn("'storage': site_runtime_storage_identity", tasks)
        self.assertIn("'environment_checksum': site_runtime_environment_checksum", tasks)

    def test_runtime_env_declares_postgresql_engine(self) -> None:
        env_template = (ROOT / "infra/ansible/roles/site_runtime_apply/templates/runtime.env.j2").read_text(encoding="utf-8")
        self.assertIn("DB_ENGINE=django.db.backends.postgresql", env_template)

    def test_publication_aware_artifacts_preserve_tls_and_public_hosts(self) -> None:
        self.assertIn("site_runtime_publication_preserved", self.template)
        self.assertIn("acme_webroot_data:", self.template)
        self.assertIn("tls_data:", self.template)
        self.assertNotIn("acme_webroot_data", self.rendered_compose["volumes"])
        self.assertNotIn("tls_data", self.rendered_compose["volumes"])

        env_template = (
            ROOT / "infra/ansible/roles/site_runtime_apply/templates/runtime.env.j2"
        ).read_text(encoding="utf-8")
        self.assertIn("runtime_contract.publication.allowed_hosts", env_template)
        self.assertIn("runtime_contract.publication.csrf_trusted_origins", env_template)

        public_context = json.loads(json.dumps(self.render_context))
        public_context["site_runtime_publication_preserved"] = True
        public_context["site_runtime_model"]["runtime_contract"]["publication"] = {
            "storage": {
                "acme_webroot": {
                    "volume": "ai_retail_mvp_acme_webroot",
                    "container_path": "/var/www/acme",
                },
                "tls": {
                    "volume": "ai_retail_mvp_tls",
                    "container_path": "/etc/letsencrypt",
                },
            }
        }
        public_compose = yaml.safe_load(
            self.render_environment.from_string(self.template).render(**public_context)
        )
        self.assertEqual(
            public_compose["volumes"]["acme_webroot_data"]["name"],
            "ai_retail_mvp_acme_webroot",
        )
        self.assertEqual(
            public_compose["volumes"]["tls_data"]["name"],
            "ai_retail_mvp_tls",
        )
        self.assertIn(
            "acme_webroot_data:/var/www/acme:ro",
            public_compose["services"]["nginx"]["volumes"],
        )
        self.assertIn(
            "tls_data:/etc/letsencrypt:ro",
            public_compose["services"]["nginx"]["volumes"],
        )

    def test_active_publication_is_fail_closed_before_runtime_render(self) -> None:
        tasks = (
            ROOT / "infra/ansible/roles/site_runtime_apply/tasks/main.yml"
        ).read_text(encoding="utf-8")
        preservation = tasks.index("include_tasks: publication_preservation.yml")
        render = tasks.index("site_runtime_compose_content:")
        mutation = tasks.index("Применить runtime после отдельного операторского разрешения")
        self.assertLess(preservation, render)
        self.assertLess(render, mutation)
        self.assertIn("site_runtime_publication_receipt.deployment_id", tasks)
        self.assertIn("site_runtime_publication_receipt.deployment_digest", tasks)
        self.assertIn("site_runtime_publication_receipt.compose_checksum", tasks)
        self.assertIn("site_runtime_apply_resume_failed", tasks)
        self.assertIn('resume_failed_deployment: "{{ site_runtime_apply_resume_failed }}"', tasks)
        self.assertIn("site_runtime_apply_failed_candidate.compose_checksum", tasks)
        self.assertIn("Проверить prospective public Nginx config", tasks)
        self.assertIn("site_runtime_apply_check_dir.path }}/nginx.conf", tasks)
        nginx_preflight = tasks.split(
            "Проверить prospective public Nginx config", 1
        )[1].split("Проверить PostgreSQL authentication", 1)[0]
        self.assertNotIn("runtime_contract.storage.release_static.volume", nginx_preflight)
        self.assertNotIn("runtime_contract.storage.public_media.volume", nginx_preflight)
        self.assertIn("runtime_contract.publication.storage.tls.volume", nginx_preflight)

        contract = (
            ROOT
            / "infra/ansible/roles/site_runtime_apply/tasks/publication_preservation.yml"
        ).read_text(encoding="utf-8")
        for required in (
            "environment_checksum",
            "nginx_checksum",
            "haproxy_checksum",
            "docker-compose.publication.yml",
            "docker volume, inspect",
            "publication_runtime_acceptance.yml",
        ):
            self.assertIn(required, contract.replace("[docker, volume, inspect", "docker volume, inspect"))
        self.assertIn("Apply остановлен до runtime mutations", contract)
        self.assertIn("Найти journal предыдущей попытки exact deployment", contract)
        self.assertIn("static_status", contract)
        self.assertIn("migration_status", contract)
        self.assertIn("site_runtime_product_receipt.config_image_id", contract)

    def test_publication_acceptance_wraps_real_runtime_update(self) -> None:
        tasks = (
            ROOT / "infra/ansible/roles/site_runtime_apply/tasks/main.yml"
        ).read_text(encoding="utf-8")
        start = tasks.index("Запустить product private runtime")
        nginx_recreate = tasks.index(
            "Пересоздать Nginx с актуальным file bind mount", start
        )
        external = tasks.index("include_tasks: publication_runtime_acceptance.yml", start)
        journal = tasks.index("Записать успешный deployment journal", external)
        final_acceptance = tasks.index("include_tasks: accept_runtime.yml", journal)
        receipt = tasks.index("Обновить publication receipt", final_acceptance)
        self.assertLess(start, nginx_recreate)
        self.assertLess(nginx_recreate, external)
        self.assertLess(external, journal)
        self.assertLess(journal, final_acceptance)
        self.assertLess(final_acceptance, receipt)
        nginx_command = tasks[nginx_recreate:external]
        self.assertIn("--no-deps", nginx_command)
        self.assertIn("--force-recreate", nginx_command)
        self.assertIn("- nginx", nginx_command)
        self.assertIn("site_runtime_environment_checksum", tasks)
        self.assertIn("site_runtime_nginx_checksum", tasks)
        self.assertIn("'runtime_nginx_checksum': site_runtime_nginx_checksum", tasks)
        self.assertIn("'nginx_checksum': site_runtime_public_nginx_checksum", tasks)

    def test_published_nginx_combines_private_and_public_configs(self) -> None:
        template_root = ROOT / "infra/ansible/roles/site_runtime_apply/templates"
        environment = Environment(
            loader=FileSystemLoader(template_root),
            undefined=StrictUndefined,
            autoescape=False,
            keep_trailing_newline=True,
        )
        public_fragment = (
            "server {\n"
            "    listen 8080;\n"
            "    server_name retail.travelltickets.ru;\n"
            "    location / { return 404; }\n"
            "}\n\n"
            "server {\n"
            "    listen 8443 ssl;\n"
            "    server_name retail.travelltickets.ru;\n"
            "    location / { proxy_pass http://127.0.0.1:8000; }\n"
            "}\n"
        )
        rendered = environment.get_template("nginx-published.conf.j2").render(
            site_runtime_public_nginx_content=public_fragment,
            site_runtime_model={
                "runtime_intent": {"internal_host": "ai-retail-mvp.internal"}
            },
        )
        payload = rendered.encode("utf-8")

        self.assertIn(b"server_name ai-retail-mvp.internal;", payload)
        self.assertIn(b"server_name retail.travelltickets.ru;", payload)
        self.assertRegex(payload, rb"}\n{1,2}server \{")
        self.assertNotIn(b"\\nserver", payload)
        self.assertTrue(payload.endswith(b"\n"))
        self.assertEqual(payload.count(b"server {"), 3)

        tasks = (
            ROOT / "infra/ansible/roles/site_runtime_apply/tasks/main.yml"
        ).read_text(encoding="utf-8")
        render = tasks.split("site_runtime_nginx_content:", 1)[1].split(
            "site_runtime_env_content:", 1
        )[0]
        self.assertIn("lookup('template', 'nginx-published.conf.j2')", render)
        self.assertNotIn("~ '\\n'", render)

        acceptance = (
            ROOT
            / "infra/ansible/roles/site_runtime_apply/tasks/publication_runtime_acceptance.yml"
        ).read_text(encoding="utf-8")
        for expected in (
            "/healthz/",
            "/readyz/",
            "/worker-healthz/",
            "/private_media/platform-apply-probe",
            "(5432, 6379, 8000)",
        ):
            self.assertIn(expected, acceptance)

    def test_apply_task_files_are_valid_yaml(self) -> None:
        task_root = ROOT / "infra/ansible/roles/site_runtime_apply/tasks"
        for path in task_root.glob("*.yml"):
            with self.subTest(path=path.name):
                self.assertIsInstance(yaml.safe_load(path.read_text(encoding="utf-8")), list)

    def test_apply_preflights_database_before_migration(self) -> None:
        tasks = (ROOT / "infra/ansible/roles/site_runtime_apply/tasks/main.yml").read_text(encoding="utf-8")
        preflight = tasks.index("Проверить PostgreSQL authentication до migration")
        migration = tasks.index("Выполнить единственный migration step")
        block = tasks[preflight:migration]

        self.assertLess(preflight, migration)
        self.assertIn("python manage.py showmigrations --plan", block)
        self.assertNotIn("--env-file", block)
        self.assertIn("json.loads(raw_value)", block)
        self.assertIn('command.extend(["--env", key])', block)

    def test_final_acceptance_covers_runtime_and_receipts(self) -> None:
        acceptance = (
            ROOT
            / "infra/ansible/roles/site_runtime_apply/tasks/accept_runtime.yml"
        ).read_text(encoding="utf-8")
        for service in ("anchor", "redis", "web", "worker", "beat", "nginx"):
            self.assertIn(f'"{service}"', acceptance)
        self.assertIn('("static", "migration")', acceptance)
        self.assertIn('get("PortBindings")', acceptance)
        self.assertIn("EXPECTED_PRODUCT_IMAGE_ID", acceptance)
        self.assertIn("storage_mounts_valid", acceptance)
        self.assertIn("Nginx не должен получать private_media", acceptance)
        self.assertIn("site_runtime_acceptance_current.digest", acceptance)
        self.assertIn("site_runtime_acceptance_journal.final_status == 'succeeded'", acceptance)
        self.assertIn("site_runtime_runtime_acceptance", acceptance)
        embedded_python = "    import json" + acceptance.split("    import json", 1)[1].split(
            "\n    PY", 1
        )[0]
        ast.parse(textwrap.dedent(embedded_python))

    def test_failed_final_acceptance_restores_previous_current_receipt(self) -> None:
        tasks = (
            ROOT / "infra/ansible/roles/site_runtime_apply/tasks/main.yml"
        ).read_text(encoding="utf-8")
        write_current = tasks.index("Обновить current deployment receipt")
        accept_new = tasks.index("Выполнить финальную приёмку нового private runtime")
        failed_journal = tasks.index("Записать failed deployment journal")
        restore_current = tasks.index("Восстановить предыдущий current receipt")
        self.assertLess(write_current, accept_new)
        self.assertLess(accept_new, failed_journal)
        self.assertLess(failed_journal, restore_current)
        self.assertIn("site_runtime_current_receipt_written", tasks)
        self.assertIn("Выполнить финальную приёмку уже принятого private runtime", tasks)
        self.assertIn('runtime_acceptance: "{{ site_runtime_runtime_acceptance }}"', tasks)


if __name__ == "__main__":
    unittest.main()
