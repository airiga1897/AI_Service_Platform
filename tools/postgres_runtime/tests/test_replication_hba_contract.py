from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
TASKS = ROOT / "infra" / "ansible" / "roles" / "postgres_runtime" / "tasks" / "main.yml"
COMPOSE = (
    ROOT
    / "infra"
    / "ansible"
    / "roles"
    / "postgres_runtime"
    / "templates"
    / "docker-compose.postgres.yml.j2"
)


class ReplicationHbaContractTests(unittest.TestCase):
    def test_explicit_empty_replication_cidrs_disable_public_ip_fallback(self):
        text = TASKS.read_text(encoding="utf-8")

        explicit_branch = text.index('elif replication_cidrs_are_explicit:')
        public_fallback = text.index('elif node_role == "primary":', explicit_branch)
        assignment = text.index(
            "replication_cidrs = configured_replication_cidrs",
            explicit_branch,
            public_fallback,
        )

        self.assertLess(explicit_branch, assignment)
        self.assertLess(assignment, public_fallback)
        self.assertIn(
            'replication_hba_cidrs_by_alias.get(alias, [])',
            text,
        )

    def test_compose_mounts_configuration_directory_read_only(self):
        text = COMPOSE.read_text(encoding="utf-8")

        self.assertIn(
            '"{{ postgres_runtime_config_dir }}:/etc/postgresql:ro"',
            text,
        )
        self.assertNotIn(
            ":/etc/postgresql/postgresql.conf:ro",
            text,
        )
        self.assertNotIn(
            ":/etc/postgresql/pg_hba.conf:ro",
            text,
        )

    def test_active_hba_is_checked_after_start_readiness_and_reload(self):
        text = TASKS.read_text(encoding="utf-8")

        compose_up = text.index("- name: Запустить контейнер postgres_runtime")
        readiness = text.index("- name: Дождаться готовности postgres_runtime")
        reload_hba = text.index("- name: Перезагрузить HBA-конфигурацию postgres_runtime")
        mount_check = text.index(
            "- name: Проверить активный mount каталога конфигурации postgres_runtime"
        )
        hba_check = text.index("- name: Проверить активные правила HBA postgres_runtime")

        self.assertLess(compose_up, readiness)
        self.assertLess(readiness, reload_hba)
        self.assertLess(reload_hba, mount_check)
        self.assertLess(mount_check, hba_check)
        self.assertIn("pg_hba_file_rules", text[hba_check:])
        self.assertIn('rule.get("netmask")', text[hba_check:])
        self.assertIn("ipaddress.ip_network", text[hba_check:])
        self.assertIn("postgres_runtime_primary_streaming_standbys", text[hba_check:])
        self.assertIn(
            "not (postgres_runtime_primary_compose_up.changed | default(false))",
            text,
        )


if __name__ == "__main__":
    unittest.main()
