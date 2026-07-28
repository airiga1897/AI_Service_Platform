"""Static and unit tests for the MyCleanBot production operations contract."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import unittest
from pathlib import Path
from unittest import mock

import jinja2
import yaml


ROOT = Path(__file__).resolve().parents[3]
REMOTE = ROOT / "tools" / "deploy" / "mycleanbot_remote.sh"
BACKUP = ROOT / "tools" / "postgres-tenant" / "postgres_tenant_backup.py"
BACKUP_WRAPPER = (
    ROOT / "infra" / "stacks" / "mycleanbot" / "ai-service-mycleanbot-backup"
)
BACKUP_NETNS = (
    ROOT / "infra" / "stacks" / "mycleanbot" / "mycleanbot-backup-netns"
)
BACKUP_ROUTES = (
    ROOT / "infra" / "stacks" / "mycleanbot" / "mycleanbot-backup-routes"
)
BACKUP_SSHD = (
    ROOT / "infra" / "stacks" / "mycleanbot" / "sshd_config_mycleanbot_backup"
)
PROVISION = ROOT / "tools" / "postgres-tenant" / "provision_mycleanbot.py"
DEPLOY_WORKFLOW = ROOT / ".github" / "workflows" / "deploy.yml"
ROLLBACK_WORKFLOW = ROOT / ".github" / "workflows" / "rollback.yml"
ENV_SECRET_PS1 = ROOT / "tools" / "github" / "ensure_environment_secrets.ps1"
ENV_SECRET_SH = ROOT / "tools" / "github" / "ensure_environment_secrets.sh"
PUBLIC_CONFIG = ROOT / "infra" / "stacks" / "mycleanbot" / "mycleanbot.env"
SECRET_EXAMPLE = (
    ROOT / "infra" / "stacks" / "mycleanbot" / ".env.mycleanbot.secrets.example"
)
PROMETHEUS = (
    ROOT
    / "infra"
    / "ansible"
    / "roles"
    / "monitoring"
    / "templates"
    / "prometheus.yml.j2"
)
ALERTS = PROMETHEUS.with_name("mycleanbot-alert-rules.yml.j2")
BLACKBOX = PROMETHEUS.with_name("blackbox.yml.j2")
MONITORING_COMPOSE = PROMETHEUS.with_name("docker-compose.monitoring.yml.j2")

spec = importlib.util.spec_from_file_location("postgres_tenant_backup", BACKUP)
assert spec and spec.loader
backup_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup_module)
provision_spec = importlib.util.spec_from_file_location(
    "provision_mycleanbot", PROVISION
)
assert provision_spec and provision_spec.loader
provision_module = importlib.util.module_from_spec(provision_spec)
provision_spec.loader.exec_module(provision_module)


class BackupContractTests(unittest.TestCase):
    def test_restore_rehearsal_uses_and_removes_ephemeral_postgres(self) -> None:
        wrapper = BACKUP_WRAPPER.read_text(encoding="utf-8")
        self.assertIn("SCRATCH_POSTGRES_IMAGE", wrapper)
        self.assertIn("--name \"$scratch_container\"", wrapper)
        self.assertIn("--network ai_service_app_vps1", wrapper)
        self.assertIn("trap cleanup_scratch EXIT", wrapper)
        self.assertIn("docker rm -f \"$scratch_container\"", wrapper)
        self.assertNotIn("POSTGRES_SUPERUSER_PASSWORD", wrapper)

    def test_backup_sftp_is_bound_only_inside_private_namespace(self) -> None:
        netns = BACKUP_NETNS.read_text(encoding="utf-8")
        sshd = BACKUP_SSHD.read_text(encoding="utf-8")
        self.assertIn('namespace="mycleanbot-backup"', netns)
        self.assertIn('network="ai_service_data_vps5"', netns)
        self.assertIn('endpoint="172.30.5.10/24"', netns)
        self.assertIn('gateway="172.30.5.2"', netns)
        self.assertIn("ListenAddress 172.30.5.10", sshd)
        self.assertIn("Port 22", sshd)
        self.assertIn("PasswordAuthentication no", sshd)
        self.assertIn("AllowTcpForwarding no", sshd)
        self.assertNotIn("0.0.0.0", sshd)

    def test_backup_host_routes_use_only_platform_router(self) -> None:
        routes = BACKUP_ROUTES.read_text(encoding="utf-8")
        self.assertIn('router_ipv4="172.31.1.2"', routes)
        self.assertIn('"172.30.8.10/32" "172.30.5.10/32"', routes)
        self.assertIn('ip route replace "$destination" via "$router_ipv4"', routes)
        self.assertNotIn("89.125.250.123", routes)
        self.assertNotIn("138.16.224.181", routes)

    def test_env_parser_does_not_expand_or_log_values(self) -> None:
        path = mock.Mock()
        path.read_text.return_value = (
            "DATABASE_URL=postgresql://tenant:${PASSWORD}@db/mycleanbot\n"
            "RESTIC_REPOSITORY=/srv/restic\n"
        )
        values = backup_module.load_env(path)
        self.assertEqual(values["RESTIC_REPOSITORY"], "/srv/restic")
        self.assertEqual(
            values["DATABASE_URL"],
            "postgresql://tenant:${PASSWORD}@db/mycleanbot",
        )

    def test_database_rewrite_preserves_transport_and_query(self) -> None:
        result = backup_module.url_with_database(
            "postgresql://admin@db:5432/postgres?sslmode=require",
            "restore_mycleanbot_20260728010101",
        )
        self.assertEqual(
            result,
            "postgresql://admin@db:5432/restore_mycleanbot_20260728010101"
            "?sslmode=require",
        )

    def test_libpq_environment_keeps_password_out_of_command_arguments(self) -> None:
        env = backup_module.postgres_env(
            "postgresql://tenant:p%40ss@db:5433/mycleanbot?sslmode=require"
        )
        self.assertEqual(env["PGHOST"], "db")
        self.assertEqual(env["PGDATABASE"], "mycleanbot")
        self.assertEqual(env["PGPASSWORD"], "p@ss")
        self.assertEqual(env["PGSSLMODE"], "require")

    def test_provision_plan_requires_no_credentials(self) -> None:
        self.assertEqual(provision_module.main(["plan"]), 0)


class DeploymentContractTests(unittest.TestCase):
    def test_environment_secret_helpers_use_stdin_supported_by_gh(self) -> None:
        powershell = ENV_SECRET_PS1.read_text(encoding="utf-8")
        shell = ENV_SECRET_SH.read_text(encoding="utf-8")
        self.assertNotIn("--body-file", powershell)
        self.assertNotIn("--body-file", shell)
        self.assertIn("RedirectStandardInput = $true", powershell)
        self.assertIn("StandardInput.Write($Value)", powershell)
        self.assertIn('gh secret set "$name"', shell)
        self.assertIn('< "$SSH_KEY_FILE"', shell)

    def test_tracked_config_and_secret_contract_are_separated(self) -> None:
        public = PUBLIC_CONFIG.read_text(encoding="utf-8")
        secret = SECRET_EXAMPLE.read_text(encoding="utf-8")
        for name in (
            "DATABASE_URL",
            "DJANGO_SECRET_KEY",
            "MASTER_ENCRYPTION_KEY",
            "TELEGRAM_API_ID",
            "TELEGRAM_API_HASH",
        ):
            self.assertNotIn(f"{name}=", public)
            self.assertIn(f"{name}=", secret)
        self.assertIn("DJANGO_DEBUG=false", public)
        self.assertIn("DJANGO_ALLOWED_HOSTS=", public)
        self.assertIn("MINI_APP_RECONCILE_SECONDS=300", public)
        self.assertIn("MINI_APP_ADMIN_EMAILS=", public)

    def test_remote_script_has_valid_bash_syntax(self) -> None:
        if os.name == "nt":
            self.skipTest("bash syntax is verified by the Ubuntu GitHub Actions runner")
        result = subprocess.run(
            ["bash", "-n", str(REMOTE)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_remote_script_contains_required_safety_gates(self) -> None:
        text = REMOTE.read_text(encoding="utf-8")
        for required in (
            "flock -n",
            "ai-service-mycleanbot-backup backup",
            "migrate --noinput",
            "/livez",
            "/healthz",
            "WorkerHeartbeat",
            '"$STATE_DIR/previous"',
            "TELEGRAM_API_ID",
            "TELEGRAM_API_HASH",
            "docker login",
            "CONFIG_FILE",
            "env_value",
            "MYCLEANBOT_ROUTE_IMAGE",
            "docker network inspect ai_service_app_vps1",
            "platform route container is missing",
            "socket.create_connection(('172.30.8.10', 5432), 5)",
            "up -d mycleanbot-route",
        ):
            self.assertIn(required, text)
        self.assertNotIn("ssh-keyscan", text)

    def test_workflows_are_manual_for_rollout_and_pin_ssh_host(self) -> None:
        deploy = DEPLOY_WORKFLOW.read_text(encoding="utf-8")
        rollback = ROLLBACK_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("github.event_name == 'workflow_dispatch'", deploy)
        self.assertIn("github.ref == 'refs/heads/main'", deploy)
        self.assertIn("mycleanbot-awaiting-manual-approval", deploy)
        self.assertIn("mycleanbot-deployment-candidate", deploy)
        self.assertIn("SSH_KNOWN_HOSTS", deploy)
        self.assertIn("secrets.DATABASE_URL", deploy)
        self.assertIn("secrets.DJANGO_SECRET_KEY", deploy)
        self.assertIn("secrets.MASTER_ENCRYPTION_KEY", deploy)
        self.assertIn("secrets.TELEGRAM_API_ID", deploy)
        self.assertIn("secrets.TELEGRAM_API_HASH", deploy)
        self.assertIn("PUBLIC_ENV_FILE", deploy)
        self.assertIn("rollback-mycleanbot", rollback)
        self.assertIn("rollback-first-mycleanbot-deployment", rollback)
        self.assertNotIn("ssh-keyscan", deploy.split("deploy-mycleanbot:", 1)[1])
        self.assertNotIn("ssh-keyscan", rollback)

    def test_monitoring_contract_covers_runtime_backup_and_restore(self) -> None:
        prometheus = PROMETHEUS.read_text(encoding="utf-8")
        alerts = ALERTS.read_text(encoding="utf-8")
        self.assertIn("/livez", prometheus)
        self.assertIn("/healthz", prometheus)
        self.assertIn("blackbox-exporter:9115", prometheus)
        self.assertIn("mycleanbot_backup_last_success_timestamp_seconds", alerts)
        self.assertIn(
            "mycleanbot_restore_rehearsal_last_success_timestamp_seconds",
            alerts,
        )

    def test_monitoring_templates_render_to_valid_yaml(self) -> None:
        environment = jinja2.Environment(
            loader=jinja2.FileSystemLoader(str(PROMETHEUS.parent)),
            undefined=jinja2.StrictUndefined,
        )
        prometheus = environment.get_template(PROMETHEUS.name).render(
            prometheus_port=9090,
            alertmanager_port=9093,
            node_exporter_port=9100,
            mycleanbot_monitor_url="https://mycleanbot.vpn.invalid",
            groups={"prod": ["vps1"]},
            hostvars={
                "vps1": {
                    "node_exporter_port": 9100,
                    "postgres_exporter_port": 9187,
                    "nginx_exporter_port": 9113,
                    "haproxy_exporter_port": 9101,
                }
            },
        )
        compose = environment.get_template(MONITORING_COMPOSE.name).render(
            prometheus_port=9090,
            alertmanager_port=9093,
            loki_port=3100,
            grafana_port=3000,
            prometheus_retention="30d",
            grafana_admin_password="suppressed",
        )
        alerts = environment.get_template(ALERTS.name).render()
        for rendered in (
            prometheus,
            compose,
            alerts,
            BLACKBOX.read_text(encoding="utf-8"),
        ):
            self.assertIsInstance(yaml.safe_load(rendered), dict)


if __name__ == "__main__":
    unittest.main()
