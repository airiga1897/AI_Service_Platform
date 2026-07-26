from __future__ import annotations

import copy
import csv
import tempfile
import unittest
from pathlib import Path

import yaml

from tools.site_runtime.resolve import ContractError, resolve


ROOT = Path(__file__).resolve().parents[3]
IMAGE = "ghcr.io/airiga1897/ai_e_retail@sha256:" + "b" * 64


class ResolverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = ROOT / "services.yml"
        self.instances = ROOT / "operator/site_runtime/instances.yml"
        self.state = ROOT / "operator/state.csv"
        self.nodes = ROOT / "operator/nodes.csv"

    def call(self, **overrides):
        args = {
            "registry_path": self.registry,
            "instances_path": self.instances,
            "state_path": self.state,
            "nodes_path": self.nodes,
            "instance_name": "ai-retail-mvp",
            "image_ref": IMAGE,
            "limit": "vps3",
        }
        args.update(overrides)
        return resolve(**args)

    def test_resolves_canonical_model(self) -> None:
        model = self.call()
        self.assertEqual(model["target_alias"], "vps3")
        self.assertEqual(model["distribution_digest"], "sha256:" + "b" * 64)
        self.assertEqual(model["platform"], "linux/amd64")
        self.assertEqual(model["runtime_intent"]["internal_host"], "ai-retail-mvp.internal")
        self.assertEqual(
            model["runtime_contract"]["support_images"]["redis"],
            "redis@sha256:"
            "6ab0b6e7381779332f97b8ca76193e45b0756f38d4c0dcda72dbb3c32061ab99",
        )
        self.assertEqual(
            model["runtime_contract"]["support_images"]["nginx"],
            "nginx@sha256:"
            "54f2a904c251d5a34adf545a72d32515a15e08418dae0266e23be2e18c66fefa",
        )
        self.assertEqual(
            model["runtime_contract"]["support_images"]["certbot"],
            "certbot/certbot@sha256:"
            "34ee91d2f43008eb78a007d22f23ed4b2eaa9a454cb27ca2c042b49527a695b4",
        )
        self.assertEqual(
            model["runtime_contract"]["components"]["static"]["command"],
            "python manage.py collectstatic --noinput",
        )
        storage = model["runtime_contract"]["storage"]
        self.assertEqual(
            storage["release_static"]["volume"],
            "ai_retail_mvp_static_" + "b" * 64,
        )
        self.assertEqual(storage["public_media"]["volume"], "ai_retail_mvp_media")
        self.assertEqual(storage["private_media"]["volume"], "ai_retail_mvp_private_media")
        self.assertNotIn("environments", model)

    def test_release_static_changes_with_digest_but_persistent_storage_does_not(self) -> None:
        first = self.call()
        second = self.call(
            image_ref="ghcr.io/airiga1897/ai_e_retail@sha256:" + "c" * 64
        )
        self.assertNotEqual(
            first["runtime_contract"]["storage"]["release_static"]["volume"],
            second["runtime_contract"]["storage"]["release_static"]["volume"],
        )
        for storage_class in ("public_media", "private_media"):
            self.assertEqual(
                first["runtime_contract"]["storage"][storage_class]["volume"],
                second["runtime_contract"]["storage"][storage_class]["volume"],
            )

    def test_rejects_missing_storage_class(self) -> None:
        data = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
        del data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["storage"]["private_media"]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "services.yml"
            path.write_text(yaml.safe_dump(data), encoding="utf-8")
            with self.assertRaisesRegex(ContractError, "storage должен содержать"):
                self.call(registry_path=path)

    def test_rejects_invalid_storage_lifecycle(self) -> None:
        data = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
        data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["storage"][
            "release_static"
        ]["lifecycle"] = "persistent"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "services.yml"
            path.write_text(yaml.safe_dump(data), encoding="utf-8")
            with self.assertRaisesRegex(ContractError, "lifecycle"):
                self.call(registry_path=path)

    def test_rejects_duplicate_storage_volume_name(self) -> None:
        data = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
        data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["storage"][
            "private_media"
        ]["volume"] = "ai_retail_mvp_media"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "services.yml"
            path.write_text(yaml.safe_dump(data), encoding="utf-8")
            with self.assertRaisesRegex(ContractError, "не должны совпадать"):
                self.call(registry_path=path)

    def test_rejects_wrong_private_media_path(self) -> None:
        data = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
        data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["storage"][
            "private_media"
        ]["container_path"] = "/app/media"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "services.yml"
            path.write_text(yaml.safe_dump(data), encoding="utf-8")
            with self.assertRaisesRegex(ContractError, "container_path"):
                self.call(registry_path=path)

    def test_rejects_resolved_release_static_collision(self) -> None:
        data = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
        data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["storage"][
            "public_media"
        ]["volume"] = "ai_retail_mvp_static_" + "b" * 64
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "services.yml"
            path.write_text(yaml.safe_dump(data), encoding="utf-8")
            with self.assertRaisesRegex(ContractError, "Вычисленное имя release static"):
                self.call(registry_path=path)

    def test_rejects_missing_static_component(self) -> None:
        data = yaml.safe_load(self.registry.read_text(encoding="utf-8"))
        del data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["components"]["static"]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "services.yml"
            path.write_text(yaml.safe_dump(data), encoding="utf-8")
            with self.assertRaisesRegex(ContractError, "components must declare"):
                self.call(registry_path=path)

    def test_rejects_invalid_secret_reference(self) -> None:
        data = yaml.safe_load(self.instances.read_text(encoding="utf-8"))
        data["instances"]["ai-retail-mvp"]["runtime"]["application_secret_file"] = "/tmp/secret.env"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "instances.yml"
            path.write_text(yaml.safe_dump(data), encoding="utf-8")
            with self.assertRaisesRegex(ContractError, "application_secret_file"):
                self.call(instances_path=path)

    def test_rejects_mutable_tag(self) -> None:
        with self.assertRaisesRegex(ContractError, "immutable"):
            self.call(image_ref="ghcr.io/airiga1897/ai_e_retail:latest")

    def test_rejects_wrong_repository(self) -> None:
        with self.assertRaisesRegex(ContractError, "repository"):
            self.call(image_ref="ghcr.io/airiga1897/other@sha256:" + "b" * 64)

    def test_rejects_limit_mismatch(self) -> None:
        with self.assertRaisesRegex(ContractError, "does not match"):
            self.call(limit="vps4")

    def test_rejects_duplicate_alias(self) -> None:
        data = yaml.safe_load(self.instances.read_text(encoding="utf-8"))
        data["instances"]["another-site"] = copy.deepcopy(data["instances"]["ai-retail-mvp"])
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "instances.yml"
            path.write_text(yaml.safe_dump(data), encoding="utf-8")
            with self.assertRaisesRegex(ContractError, "only one instance"):
                self.call(instances_path=path)

    def test_rejects_state_without_placement(self) -> None:
        with self.state.open(newline="", encoding="utf-8-sig") as handle:
            rows = list(csv.DictReader(handle))
            fields = list(rows[0])
        for row in rows:
            if row["kind"] == "service" and row["name"] == "site_runtime":
                row["active_aliases"] = "vps4"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.csv"
            with path.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(handle, fieldnames=fields)
                writer.writeheader()
                writer.writerows(rows)
            with self.assertRaisesRegex(ContractError, "not allowed"):
                self.call(state_path=path)


if __name__ == "__main__":
    unittest.main()
