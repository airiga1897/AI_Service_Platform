from __future__ import annotations

import copy
import csv
import importlib.util
import json
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
            "rehearsal_id": "",
        }
        values.update(overrides)
        return MODULE.resolve_backup(**values)

    def test_resolves_exact_target_datasets_and_retention(self) -> None:
        model = self.resolve()
        self.assertEqual(model["backup_target"]["alias"], "vps5")
        self.assertEqual(model["datasets"], ["database", "public_media", "private_media"])
        self.assertEqual(model["retention"], {"daily": 7, "weekly": 4, "monthly": 6})
        self.assertEqual(model["schedule"]["on_calendar"], "*-*-* 03:30:00 Europe/Moscow")
        self.assertEqual(model["schedule"]["randomized_delay_sec"], 900)
        self.assertTrue(model["schedule"]["persistent"])
        self.assertEqual(model["restore_policy"], "scratch-only")
        self.assertEqual(model["postgres"]["container_name"], "ai-service-postgres")

    def test_limit_must_match_runtime_placement(self) -> None:
        with self.assertRaisesRegex(MODULE.ContractError, "placement"):
            self.resolve(limit="vps5")

    def test_snapshot_id_is_strict(self) -> None:
        with self.assertRaisesRegex(MODULE.ContractError, "snapshot_id"):
            self.resolve(snapshot_id="../../production")
        self.assertEqual(self.resolve(snapshot_id="a" * 64)["snapshot_id"], "a" * 64)

    def test_rehearsal_id_is_strict(self) -> None:
        with self.assertRaisesRegex(MODULE.ContractError, "rehearsal_id"):
            self.resolve(rehearsal_id="../../production")
        value = "20260719T113907Z-9c54c8a30d25"
        self.assertEqual(self.resolve(rehearsal_id=value)["rehearsal_id"], value)

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
            changed["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["backup"]["schedule"]["persistent"] = False
            target.write_text(yaml.safe_dump(changed, sort_keys=False), encoding="utf-8")
            with self.assertRaisesRegex(MODULE.ContractError, "scheduled Restic"):
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
        cls.timer = (
            ROOT / "infra/ansible/roles/site_runtime_backup/templates/site-runtime-backup.timer.j2"
        ).read_text(encoding="utf-8")
        cls.systemd_service = (
            ROOT / "infra/ansible/roles/site_runtime_backup/templates/site-runtime-backup.service.j2"
        ).read_text(encoding="utf-8")

    def test_shared_lock_and_plaintext_cleanup_are_mandatory(self) -> None:
        self.assertIn("fcntl.flock(lock, fcntl.LOCK_EX)", self.runner)
        self.assertIn("shutil.rmtree(staging, ignore_errors=True)", self.runner)
        self.assertIn('snapshot_accepted = snapshot_id is not None and health == "succeeded"', self.runner)
        self.assertIn("raise health_error", self.runner)
        self.assertIn("flock -n 9", self.service)
        self.assertIn('"--lock-held"', self.runner)
        self.assertIn("site_runtime_lock_held", self.tasks)

    def test_backup_excludes_release_static_and_redis(self) -> None:
        self.assertIn('(\"database.dump\", \"public_media.tar\", \"private_media.tar\")', self.runner)
        self.assertNotIn("release_static.tar", self.runner)
        self.assertNotIn("redis.tar", self.runner)

    def test_restore_is_scratch_only_and_preserves_failures(self) -> None:
        self.assertIn("restore_ai_retail_", self.runner)
        self.assertIn('"scratch_preserved_for_diagnostics": not cleanup_succeeded', self.runner)
        self.assertNotIn("manage.py migrate --check", self.runner)
        self.assertIn("_migration_ledger", self.runner)
        self.assertIn('"migration_ledger_match": True', self.runner)
        self.assertIn("_postgres_shell(", self.runner)
        self.assertIn('"database_nonempty": True', self.runner)
        self.assertIn("В scratch DB отсутствуют пользовательские таблицы", self.runner)

    def test_cli_transfers_backup_secret_with_restricted_mode(self) -> None:
        self.assertIn("'*/secrets/*'", self.remote)
        self.assertIn("'*/backup-secrets/*'", self.remote)
        self.assertIn("-SnapshotId", self.remote)
        self.assertIn("restore-rehearsal", self.remote)
        self.assertIn("backup-schedule", self.remote)

    def test_systemd_schedule_uses_canonical_service_path(self) -> None:
        self.assertIn("OnCalendar={{ site_runtime_backup_model.schedule.on_calendar }}", self.timer)
        self.assertIn("RandomizedDelaySec={{ site_runtime_backup_model.schedule.randomized_delay_sec }}", self.timer)
        self.assertIn("Persistent={{ site_runtime_backup_model.schedule.persistent | lower }}", self.timer)
        self.assertIn("site_runtime backup --instance", self.systemd_service)
        self.assertIn("--services-registry {{ site_runtime_services_registry }}", self.systemd_service)
        self.assertIn("--site-runtime-instances {{ site_runtime_instances_file }}", self.systemd_service)
        self.assertIn(
            "--site-runtime-resolver /opt/ai-service-platform/tools/site_runtime/resolve.py",
            self.systemd_service,
        )
        self.assertIn("TimeoutStartSec=1h", self.systemd_service)
        stamp = self.tasks.index("site_runtime_backup_systemd_stamp")
        enable = self.tasks.index("Включить автоматический backup без немедленного запуска")
        self.assertLess(stamp, enable)

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

    def test_retention_is_scoped_to_instance_and_exact_policy(self) -> None:
        self.backup_model.update({
            "instance": "ai-retail-mvp",
            "retention": {"daily": 7, "weekly": 4, "monthly": 6},
        })
        responses = [
            SimpleNamespace(stdout='[{"id":"one"},{"id":"two"}]'),
            SimpleNamespace(stdout="[]"),
            SimpleNamespace(stdout='[{"id":"two"}]'),
        ]
        with mock.patch.object(RUNTIME, "_restic", side_effect=responses) as restic:
            result = RUNTIME._apply_retention(self.backup_model, "suppressed")
        self.assertEqual(result["retention_status"], "succeeded")
        self.assertEqual(result["retained_snapshots"], 1)
        self.assertEqual(result["removed_snapshots"], 1)
        forget = restic.call_args_list[1].args[2:]
        self.assertEqual(forget[0], "forget")
        self.assertIn("site-runtime:ai-retail-mvp", forget)
        self.assertIn("--group-by", forget)
        self.assertIn("host", forget)
        self.assertIn("--keep-daily", forget)
        self.assertIn("--keep-weekly", forget)
        self.assertIn("--keep-monthly", forget)
        self.assertIn("--prune", forget)

    def test_backup_schedule_is_read_only_preflight(self) -> None:
        self.backup_model.update({
            "schedule": {
                "enabled": True,
                "on_calendar": "*-*-* 03:30:00 Europe/Moscow",
                "randomized_delay_sec": 900,
                "persistent": True,
            },
            "retention": {"daily": 7, "weekly": 4, "monthly": 6},
        })
        with mock.patch.object(
            RUNTIME,
            "_preflight",
            return_value={"current": {"deployment_id": "accepted-deployment"}},
        ):
            result = RUNTIME.backup_schedule(self.backup_model, "suppressed")
        self.assertFalse(result["check_mode_mutations"])
        self.assertTrue(result["repository_ready"])

    def test_restore_cleanup_check_only_inventories_failed_rehearsal(self) -> None:
        rehearsal_id = "20260719T113907Z-9c54c8a30d25"
        self.backup_model.update({
            "rehearsal_id": rehearsal_id,
            "runtime_alias": "vps3",
            "postgres": {
                "primary": "vps8",
                "container_name": "ai-service-postgres",
            },
        })
        with tempfile.TemporaryDirectory(dir=ROOT) as temp:
            root = Path(temp)
            journal_root = root / "restore-journal"
            journal_root.mkdir()
            (journal_root / f"{rehearsal_id}.json").write_text(
                json.dumps({
                    "rehearsal_id": rehearsal_id,
                    "final_status": "failed",
                    "production_unchanged": True,
                    "scratch_preserved_for_diagnostics": True,
                }),
                encoding="utf-8",
            )
            staging = root / "restore-20260719t113907z9c54c8a30d25-test"
            staging.mkdir()
            with (
                mock.patch.object(RUNTIME, "_control_root", return_value=root),
                mock.patch.object(RUNTIME, "_preflight"),
                mock.patch.object(
                    RUNTIME, "_ssh", return_value=SimpleNamespace(stdout=b"1"),
                ),
                mock.patch.object(
                    RUNTIME, "_ssh_result", return_value=SimpleNamespace(returncode=0),
                ),
            ):
                result = RUNTIME.restore_cleanup(
                    self.backup_model, "suppressed", check=True,
                )
        self.assertFalse(result["cleanup_performed"])
        self.assertTrue(result["scratch_database_present"])
        self.assertEqual(result["scratch_volumes_present"], 2)
        self.assertEqual(result["staging_directories_present"], 1)



if __name__ == "__main__":
    unittest.main()
