"""Tests for tools/deploy/preflight.py."""

from __future__ import annotations

import copy
import json
import subprocess
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
SERVICES_YML = ROOT / "services.yml"
PREFLIGHT = ROOT / "tools" / "deploy" / "preflight.py"

sys.path.insert(0, str(ROOT / "tools" / "deploy"))
from preflight import PreflightError, resolve_preflight  # noqa: E402

sys.path.insert(0, str(ROOT / "tools" / "_lib"))
from registry import load_registry  # noqa: E402


def load_real() -> dict:
    return load_registry(SERVICES_YML)


VALID_DEV_REF = (
    "ghcr.io/airiga1897/ai_e_retail:"
    "abc123def4567890abc123def4567890abcdef12"
)
VALID_MVP_REF = "ghcr.io/airiga1897/ai_e_retail@sha256:" + "a" * 64
INVALID_DEV_REF = "ghcr.io/airiga1897/ai_e_retail:wrong-tag"


class PreflightResolveTests(unittest.TestCase):
    def test_ai_retail_dev_preprod_resolves_metadata(self) -> None:
        registry = load_real()
        metadata = resolve_preflight(registry, "ai-retail-dev", "preprod", VALID_DEV_REF)
        self.assertEqual(metadata["instance"], "ai-retail-dev")
        self.assertEqual(metadata["environment"], "preprod")
        self.assertEqual(metadata["vps"], "VPS2")
        self.assertEqual(
            metadata["compose_file"],
            "infra/stacks/ai-retail-dev/docker-compose.ai-retail-dev.yml",
        )
        self.assertEqual(metadata["env_file"], ".env.ai-retail.dev")
        self.assertEqual(metadata["deploy_dir"], "/opt/stacks/ai-retail-dev-preprod")
        self.assertEqual(
            metadata["deploy_state_tag_prefix"], "deploy/ai-retail-dev/preprod/"
        )

    def test_invalid_image_ref_rejected(self) -> None:
        registry = load_real()
        with self.assertRaises(PreflightError) as ctx:
            resolve_preflight(registry, "ai-retail-dev", "preprod", INVALID_DEV_REF)
        self.assertIn("does not match", str(ctx.exception))

    def test_unqualified_image_ref_rejected(self) -> None:
        registry = load_real()
        with self.assertRaises(PreflightError) as ctx:
            resolve_preflight(
                registry,
                "ai-retail-dev",
                "preprod",
                "ghcr.io/airiga1897/ai_e_retailwhatever",
            )
        self.assertIn("does not match", str(ctx.exception))

    def test_mvp_requires_immutable_digest(self) -> None:
        registry = load_real()
        with self.assertRaises(PreflightError):
            resolve_preflight(registry, "ai-retail-mvp", "preprod", VALID_DEV_REF)
        metadata = resolve_preflight(registry, "ai-retail-mvp", "preprod", VALID_MVP_REF)
        self.assertEqual(metadata["image_ref"], VALID_MVP_REF)

    def test_unknown_environment_rejected(self) -> None:
        registry = load_real()
        with self.assertRaises(PreflightError) as ctx:
            resolve_preflight(registry, "ai-retail-dev", "prod", VALID_DEV_REF)
        self.assertIn("not configured", str(ctx.exception))

    def test_missing_deploy_block_rejected(self) -> None:
        registry = copy.deepcopy(load_real())
        del registry["runtime_instances"]["ai-retail-dev"]["deploy"]
        with self.assertRaises(PreflightError):
            resolve_preflight(registry, "ai-retail-dev", "preprod", VALID_DEV_REF)


class PreflightCliTests(unittest.TestCase):
    def test_cli_emits_json(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(PREFLIGHT),
                "--instance",
                "ai-retail-dev",
                "--environment",
                "preprod",
                "--image-ref",
                VALID_DEV_REF,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["vps"], "VPS2")

    def test_cli_fails_on_invalid_ref(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(PREFLIGHT),
                "--instance",
                "ai-retail-dev",
                "--environment",
                "preprod",
                "--image-ref",
                INVALID_DEV_REF,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
