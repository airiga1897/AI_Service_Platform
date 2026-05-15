"""Smoke tests for the services.yml validator.

These tests load the real ``services.yml`` and mutate the parsed dict
in-memory to produce intentionally broken fixtures. Each test then calls
``validate_data`` directly and asserts that the right error (or warning)
is raised. This keeps fixtures DRY and always in sync with the real
contract — no separate copy of services.yml to drift.

Run with:

    python3 -m unittest discover -s tools/validate-services-yml/tests -t .

or:

    pytest tools/validate-services-yml/tests
"""

from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

import yaml

THIS_DIR = Path(__file__).resolve().parent
TOOL_DIR = THIS_DIR.parent
ROOT = TOOL_DIR.parent.parent
SERVICES_YML = ROOT / "services.yml"

sys.path.insert(0, str(TOOL_DIR))
from validate_services_yml import (  # noqa: E402  (sys.path tweak above)
    main,
    validate_data,
)


def load_real() -> dict:
    with SERVICES_YML.open("r", encoding="utf-8-sig") as handle:
        return yaml.safe_load(handle)


class ValidatorBaselineTests(unittest.TestCase):
    """The real services.yml must validate cleanly (no errors)."""

    def test_real_services_yml_has_no_errors(self) -> None:
        data = load_real()
        errors, _warnings = validate_data(data)
        self.assertEqual(errors, [], f"unexpected errors: {errors}")

    def test_main_exits_zero_on_real_file(self) -> None:
        self.assertEqual(main([str(SERVICES_YML)]), 0)

    def test_strict_flags_replit_port_warning_as_error(self) -> None:
        # aromaflow-work.local.backend_port == 5000 collides with Replit preview.
        # Default mode tolerates it; --strict must fail.
        self.assertEqual(main([str(SERVICES_YML), "--strict"]), 1)


class ValidatorBrokenFixtureTests(unittest.TestCase):
    """Each test mutates a known-good registry into a known-bad shape."""

    def setUp(self) -> None:
        self.data = copy.deepcopy(load_real())

    # ---------- duplicate local port ---------------------------------
    def test_duplicate_local_port_is_an_error(self) -> None:
        # aromaflow-work.frontend_port=5170, force a collision from another instance.
        self.data["runtime_instances"]["aromaflow-demo"]["local"]["backend_port"] = 5170
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("duplicates port 5170" in e for e in errors),
            f"missing duplicate-port error in: {errors}",
        )

    # ---------- bad env.prefix ---------------------------------------
    def test_env_prefix_must_match_instance_name(self) -> None:
        self.data["runtime_instances"]["aromaflow-work"]["env"]["prefix"] = "WRONG_PREFIX"
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("env.prefix must be 'AROMAFLOW_WORK'" in e for e in errors),
            f"missing env.prefix error in: {errors}",
        )

    # ---------- unknown VPS deploy target ----------------------------
    def test_deploy_target_must_be_known_vps(self) -> None:
        self.data["runtime_instances"]["aromaflow-work"]["deploy"]["environments"]["prod"] = "VPS9"
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("VPS9" in e for e in errors),
            f"missing unknown-VPS error in: {errors}",
        )

    # ---------- missing healthcheck.path -----------------------------
    def test_missing_healthcheck_path_is_an_error(self) -> None:
        del self.data["runtime_instances"]["aromaflow-work"]["healthcheck"]["path"]
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("healthcheck.path is required" in e for e in errors),
            f"missing healthcheck.path error in: {errors}",
        )

    # ---------- bad expected_status ----------------------------------
    def test_healthcheck_expected_status_out_of_range(self) -> None:
        self.data["runtime_instances"]["aromaflow-work"]["healthcheck"]["expected_status"] = 999
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("expected_status must be between 100 and 599" in e for e in errors),
            f"missing expected_status range error in: {errors}",
        )

    # ---------- duplicate domain across instances --------------------
    def test_duplicate_domain_across_instances_is_an_error(self) -> None:
        self.data["runtime_instances"]["aromaflow-demo"]["domains"]["preprod"] = [
            "site.mine-craft.su"  # already used by aromaflow-work.preprod
        ]
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("duplicates domain 'site.mine-craft.su'" in e for e in errors),
            f"missing duplicate-domain error in: {errors}",
        )

    # ---------- bad postgres database name ---------------------------
    def test_database_name_must_match_pattern(self) -> None:
        self.data["runtime_instances"]["aromaflow-work"]["data"]["database"] = "Bad-Name"
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("data.database must match" in e for e in errors),
            f"missing database name pattern error in: {errors}",
        )

    # ---------- duplicate database name ------------------------------
    def test_duplicate_database_name_is_an_error(self) -> None:
        self.data["runtime_instances"]["aromaflow-demo"]["data"]["database"] = "aromaflow_work"
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("duplicates database 'aromaflow_work'" in e for e in errors),
            f"missing duplicate-database error in: {errors}",
        )

    # ---------- future_service_template conditional check ------------
    def test_future_service_template_required_fields_for_typed_instance(self) -> None:
        # Promote aromaflow-demo to type=site and drop a required template field.
        instance = self.data["runtime_instances"]["aromaflow-demo"]
        instance["type"] = "site"
        del instance["data"]["database"]
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any(
                "data.database is required for type='site'" in e
                for e in errors
            ),
            f"missing future_service_template required-field error in: {errors}",
        )

    # ---------- replit reserved port surfaces as a warning -----------
    def test_replit_reserved_port_is_a_warning_not_an_error(self) -> None:
        errors, warnings = validate_data(self.data)
        self.assertEqual(errors, [])
        self.assertTrue(
            any("5000" in w and "Replit" in w for w in warnings),
            f"missing Replit reserved-port warning in: {warnings}",
        )


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
