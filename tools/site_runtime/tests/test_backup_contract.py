from __future__ import annotations

import copy
import csv
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "site_runtime_resolve_backup", ROOT / "tools/site_runtime/resolve_backup.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
RUNTIME_SPEC = importlib.util.spec_from_file_location(
    "site_runtime_backup_runtime", ROOT / "tools/site_runtime/backup_runtime.py"
)
assert RUNTIME_SPEC and RUNTIME_SPEC.loader
RUNTIME = importlib.util.module_from_spec(RUNTIME_SPEC)
with mock.patch.dict(sys.modules, {"fcntl": SimpleNamespace(LOCK_EX=1, flock=lambda *_args: None)}):
    RUNTIME_SPEC.loader.exec_module(RUNTIME)


class BackupResolverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = ROOT / "services.yml"
        self.instances = ROOT / "operator/site_runtime/instances.yml"
        self.state = ROOT / "operator/state.csv"
        self.nodes = ROOT / "operator/nodes.csv"
        self.postgres_config = ROOT / "operator/postgres/config.yml"

    def resolve(self, **overrides: str):
        values = {
            "registry_path": self.registry,
            "instances_path": self.instances,
            "state_path": self.state,
            "nodes_path": self.nodes,
            "postgres_config_path": self.postgres_config,
            "instance_name": "ai-retail-mvp",
            "limit": "vps3",
            "snapshot_id": "",
        }
        values.update(overrides)
        return MODULE.resolve_backup(**values)

    def test_resolves_exact_target_datasets_and_retention(self) -> None:
        model = self.resolve()
        self.assertEqual(model["backup_target"]["alias"], "vps5")
        self.assertEqual(model["datasets"], ["database", "public_media", "private_media"])
        self.assertEqual(model["retention"], {"daily": 7, "weekly": 4, "monthly": 6})
        self.assertEqual(model["restore_policy"], "scratch-only")
        self.assertEqual(model["postgres"]["container_name"], "ai-service-postgres")

    def test_limit_must_match_runtime_placement(self) -> None:
        with self.assertRaisesRegex(MODULE.ContractError, "placement"):
            self.resolve(limit="vps5")

    def test_snapshot_id_is_strict(self) -> None:
        with self.assertRaisesRegex(MODULE.ContractError, "snapshot_id"):
            self.resolve(snapshot_id="../../production")
        self.assertEqual(self.resolve(snapshot_id="a" * 64)["snapshot_id"], "a" * 64)

    def test_backup_role_is_required(self) -> None:
        with tempfile.TemporaryDirectory(dir=ROOT) as temp:
            target = Path(temp) / "state.csv"
            with self.state.open(newline="", encoding="utf-8-sig") as source:
                rows = list(csv.DictReader(source))
                fields = source.readline if False else rows[0].keys()
            rows = [row for row in rows if row.get("name") != "backup"]
            with target.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(handle, fieldnames=fields)
                writer.writeheader()
                writer.writerows(rows)
            with self.assertRaisesRegex(MODULE.ContractError, "platform_role"):
                self.resolve(state_path=target)

    def test_backup_policy_cannot_be_weakened(self) -> None:
        with tempfile.TemporaryDirectory(dir=ROOT) as temp:
            target = Path(temp) / "services.yml"
            data = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
            changed = copy.deepcopy(data)
            changed["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["backup"]["schedule"] = "nightly"
            target.write_text(yaml.safe_dump(changed, sort_keys=False), encoding="utf-8")
            with self.assertRaisesRegex(MODULE.ContractError, "manual Restic"):
                self.resolve(registry_path=target)


class BackupRenderContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.runner = (ROOT / "tools/site_runtime/backup_runtime.py").read_text(encoding="utf-8")
        cls.tasks = (
            ROOT / "infra/ansible/roles/site_runtime_backup/tasks/main.yml"
        ).read_text(encoding="utf-8")
        cls.remote = (ROOT / "tools/services/service_remote.ps1").read_text(encoding="utf-8")
        cls.service = (ROOT / "tools/services/service.sh").read_text(encoding="utf-8")

    def test_shared_lock_and_plaintext_cleanup_are_mandatory(self) -> None:
        self.assertIn("fcntl.flock(lock, fcntl.LOCK_EX)", self.runner)
        self.assertIn("shutil.rmtree(staging, ignore_errors=True)", self.runner)
        self.assertIn('"snapshot_accepted": final_status == "succeeded"', self.runner)
        self.assertIn("raise health_error", self.runner)

    def test_backup_excludes_release_static_and_redis(self) -> None:
        self.assertIn('(\"database.dump\", \"public_media.tar\", \"private_media.tar\")', self.runner)
        self.assertNotIn("release_static.tar", self.runner)
        self.assertNotIn("redis.tar", self.runner)

    def test_restore_is_scratch_only_and_preserves_failures(self) -> None:
        self.assertIn("restore_ai_retail_", self.runner)
        self.assertIn('"scratch_preserved_for_diagnostics": not cleanup_succeeded', self.runner)
        self.assertIn("manage.py migrate --check", self.runner)
        self.assertIn("-e DB_NAME=", self.runner)
        self.assertIn("_postgres_shell(", self.runner)

    def test_cli_transfers_backup_secret_with_restricted_mode(self) -> None:
        self.assertIn("'*/secrets/*'", self.remote)
        self.assertIn("'*/backup-secrets/*'", self.remote)
        self.assertIn("-SnapshotId", self.remote)
        self.assertIn("restore-rehearsal", self.remote)

    def test_check_mode_is_passed_to_non_mutating_runner(self) -> None:
        self.assertIn("site_runtime_backup_check", self.tasks)
        self.assertIn("['--check'] if site_runtime_backup_check", self.tasks)
        self.assertIn("always:", self.tasks)
        self.assertIn("site_runtime_backup_secret_stat.stat.mode == '0600'", self.tasks)
        self.assertIn("argv: [restic, version]", self.tasks)
        self.assertNotIn("ansible.builtin.command: [restic, version]", self.tasks)

    def test_list_hosts_error_is_printed_before_service_exits(self) -> None:
        start = self.service.index('set +e\nlist_hosts_output="$(')
        capture = self.service.index("list_hosts_rc=$?", start)
        restore = self.service.index("set -e", capture)
        output = self.service.index("printf '%s\\n' \"$list_hosts_output\"", restore)
        failure = self.service.index('if [ "$list_hosts_rc" -ne 0 ]', output)
        self.assertLess(start, capture)
        self.assertLess(capture, restore)
        self.assertLess(restore, output)
        self.assertLess(output, failure)


class BackupRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.backup_model = {
            "instance": "ai-retail-mvp",
            "backup_target": {
                "alias": "vps5",
                "repository": "/opt/backups/ai-service-platform/site-runtime/ai-retail-mvp/restic",
            },
            "postgres": {"container_name": "ai-service-postgres"},
            "nodes": {"vps5": "vps5.mine-craft.su"},
        }

    def test_runtime_container_names_match_compose_contract(self) -> None:
        self.assertEqual(
            RUNTIME._runtime_container(self.backup_model, "anchor"),
            "site-runtime-ai-retail-mvp-anchor",
        )
        self.assertEqual(
            RUNTIME._runtime_container(self.backup_model, "web"),
            "ai-retail-mvp-web-1",
        )
        with self.assertRaisesRegex(RUNTIME.BackupError, "Неизвестный сервис"):
            RUNTIME._runtime_container(self.backup_model, "migration")

    def test_private_health_retries_until_runtime_is_ready(self) -> None:
        self.backup_model.update({
            "runtime_alias": "vps3",
            "runtime_root": "/opt/ai-service-platform/site-runtime/ai-retail-mvp",
        })
        responses = [
            SimpleNamespace(returncode=1),
            SimpleNamespace(returncode=1),
            SimpleNamespace(returncode=0),
        ]
        with (
            mock.patch.object(RUNTIME, "_ssh_result", side_effect=responses) as ssh_result,
            mock.patch.object(RUNTIME.time, "sleep") as sleep,
        ):
            healthy = RUNTIME._private_health(
                self.backup_model, attempts=20, delay_seconds=3,
            )
        self.assertTrue(healthy)
        self.assertEqual(ssh_result.call_count, 3)
        self.assertEqual(sleep.call_count, 2)
        sleep.assert_called_with(3)

    def test_postgres_scratch_command_uses_positional_arguments(self) -> None:
        command = RUNTIME._postgres_shell(
            self.backup_model,
            'createdb -U "$POSTGRES_USER" -O "$2" "$1"',
            "restore_safe",
            "owner'; touch /tmp/unexpected; #",
        )
        self.assertIn('"$1"', command)
        self.assertIn('"$2"', command)
        self.assertIn("docker exec 'ai-service-postgres'", command)
        self.assertNotIn("touch /tmp/unexpected;", command.split(" sh", 1)[0])

    def test_restic_sftp_command_contains_target_and_subsystem(self) -> None:
        completed = SimpleNamespace(returncode=0, stdout="", stderr="")
        with mock.patch.object(RUNTIME, "_run", return_value=completed) as run:
            RUNTIME._restic(self.backup_model, "suppressed", "snapshots", "--json", checked=False)
        command = run.call_args.args[0]
        self.assertIn(
            "sftp.command=ssh -i /home/ansible/.ssh/ansible_control "
            "-o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes "
            "-o UserKnownHostsFile=/home/ansible/.ssh/known_hosts "
            "ansible@vps5.mine-craft.su -s sftp",
            command,
        )

    def test_regular_ssh_uses_ansible_known_hosts(self) -> None:
        model = {"nodes": {"vps5": "vps5.mine-craft.su"}}
        completed = SimpleNamespace(returncode=0, stdout="", stderr="")
        with mock.patch.object(RUNTIME, "_run", return_value=completed) as run:
            RUNTIME._ssh_result(model, "vps5", "true")
        command = run.call_args.args[0]
        self.assertIn("UserKnownHostsFile=/home/ansible/.ssh/known_hosts", command)
        self.assertIn("IdentitiesOnly=yes", command)

    def test_backup_init_initializes_empty_repository(self) -> None:
        completed = SimpleNamespace(returncode=0, stdout="[]", stderr="")
        with (
            mock.patch.object(RUNTIME, "_repository_state", return_value="empty"),
            mock.patch.object(RUNTIME, "_restic", return_value=completed) as restic,
        ):
            result = RUNTIME.backup_init(self.backup_model, "suppressed", check=False)
        self.assertTrue(result["repository_initialized"])
        self.assertFalse(result["already_initialized"])
        self.assertEqual([call.args[2:] for call in restic.call_args_list], [("init",), ("check",)])

    def test_backup_init_accepts_existing_repository(self) -> None:
        completed = SimpleNamespace(returncode=0, stdout="[]", stderr="")
        with (
            mock.patch.object(RUNTIME, "_repository_state", return_value="initialized"),
            mock.patch.object(RUNTIME, "_restic", return_value=completed) as restic,
        ):
            result = RUNTIME.backup_init(self.backup_model, "suppressed", check=False)
        self.assertTrue(result["repository_initialized"])
        self.assertTrue(result["already_initialized"])
        self.assertEqual(
            [call.args[2:] for call in restic.call_args_list],
            [("snapshots", "--json"), ("check",)],
        )

    def test_backup_init_rejects_nonempty_repository_without_config(self) -> None:
        with (
            mock.patch.object(RUNTIME, "_repository_state", return_value="nonempty_without_config"),
            mock.patch.object(RUNTIME, "_restic") as restic,
            self.assertRaisesRegex(RUNTIME.BackupError, "Непустой каталог"),
        ):
            RUNTIME.backup_init(self.backup_model, "suppressed", check=False)
        restic.assert_not_called()

    def test_backup_init_propagates_existing_repository_error(self) -> None:
        failed = SimpleNamespace(returncode=1, stdout="", stderr="wrong password or no key found")
        with (
            mock.patch.object(RUNTIME, "_repository_state", return_value="initialized"),
            mock.patch.object(RUNTIME, "_restic", return_value=failed) as restic,
            self.assertRaisesRegex(RUNTIME.BackupError, "существующий Restic repository"),
        ):
            RUNTIME.backup_init(self.backup_model, "suppressed", check=False)
        restic.assert_called_once_with(
            self.backup_model, "suppressed", "snapshots", "--json", checked=False,
        )



if __name__ == "__main__":
    unittest.main()
