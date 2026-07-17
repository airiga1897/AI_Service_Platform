from __future__ import annotations

import copy
import csv
import importlib.util
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "site_runtime_resolve_backup", ROOT / "tools/site_runtime/resolve_backup.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BackupResolverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = ROOT / "services.yml"
        self.instances = ROOT / "operator/site_runtime/instances.yml"
        self.state = ROOT / "operator/state.csv"
        self.nodes = ROOT / "operator/nodes.csv"

    def resolve(self, **overrides: str):
        values = {
            "registry_path": self.registry,
            "instances_path": self.instances,
            "state_path": self.state,
            "nodes_path": self.nodes,
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

    def test_limit_must_match_runtime_placement(self) -> None:
        with self.assertRaisesRegex(MODULE.ContractError, "placement"):
            self.resolve(limit="vps5")

    def test_snapshot_id_is_strict(self) -> None:
        with self.assertRaisesRegex(MODULE.ContractError, "snapshot_id"):
            self.resolve(snapshot_id="../../production")
        self.assertEqual(self.resolve(snapshot_id="a" * 64)["snapshot_id"], "a" * 64)

    def test_backup_role_is_required(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
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
        with tempfile.TemporaryDirectory() as temp:
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

    def test_shared_lock_and_plaintext_cleanup_are_mandatory(self) -> None:
        self.assertIn("fcntl.flock(lock, fcntl.LOCK_EX)", self.runner)
        self.assertIn("shutil.rmtree(staging, ignore_errors=True)", self.runner)

    def test_backup_excludes_release_static_and_redis(self) -> None:
        self.assertIn('(\"database.dump\", \"public_media.tar\", \"private_media.tar\")', self.runner)
        self.assertNotIn("release_static.tar", self.runner)
        self.assertNotIn("redis.tar", self.runner)

    def test_restore_is_scratch_only_and_preserves_failures(self) -> None:
        self.assertIn("restore_ai_retail_", self.runner)
        self.assertIn('"scratch_preserved_for_diagnostics": not cleanup', self.runner)
        self.assertIn("manage.py migrate --check", self.runner)

    def test_cli_transfers_backup_secret_with_restricted_mode(self) -> None:
        self.assertIn("'*/secrets/*'", self.remote)
        self.assertIn("-SnapshotId", self.remote)
        self.assertIn("restore-rehearsal", self.remote)

    def test_check_mode_is_passed_to_non_mutating_runner(self) -> None:
        self.assertIn("site_runtime_backup_check", self.tasks)
        self.assertIn("['--check'] if site_runtime_backup_check", self.tasks)


if __name__ == "__main__":
    unittest.main()
