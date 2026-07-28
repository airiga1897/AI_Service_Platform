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
import subprocess
import sys
import unittest
from pathlib import Path

import yaml

THIS_DIR = Path(__file__).resolve().parent
TOOL_DIR = THIS_DIR.parent
ROOT = TOOL_DIR.parent.parent
SERVICES_YML = ROOT / "services.yml"
FIXTURES_DIR = THIS_DIR / "fixtures"
VALIDATOR = TOOL_DIR / "validate_services_yml.py"

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
        # Real registry must pass --strict (no warnings).
        self.assertEqual(main([str(SERVICES_YML), "--strict"]), 0)


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
        self.data["runtime_instances"]["aromaflow-work"]["deploy"]["environments"]["prod"][
            "vps"
        ] = "VPS9"
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("VPS9" in e for e in errors),
            f"missing unknown-VPS error in: {errors}",
        )

    # ---------- platform roles / physical nodes ----------------------
    def test_physical_nodes_must_not_store_lifecycle_state(self) -> None:
        self.data["platform"]["physical_nodes"]["vps-nl-qupra-01"][
            "lifecycle_state"
        ] = "active"
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("lifecycle_state must not be stored" in e for e in errors),
            f"missing lifecycle_state error in: {errors}",
        )

    def test_role_candidate_must_reference_known_physical_node(self) -> None:
        self.data["platform"]["platform_roles"]["production-runtime"][
            "candidate_node"
        ] = "missing-node"
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("candidate_node references unknown physical node" in e for e in errors),
            f"missing unknown candidate_node error in: {errors}",
        )

    # ---------- deploy contract --------------------------------------
    def test_missing_allowed_image_ref_pattern_is_an_error(self) -> None:
        del self.data["runtime_instances"]["aromaflow-work"]["deploy"][
            "allowed_image_ref_pattern"
        ]
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("allowed_image_ref_pattern" in e for e in errors),
            f"missing allowed_image_ref_pattern error in: {errors}",
        )

    def test_invalid_image_ref_regex_is_an_error(self) -> None:
        self.data["runtime_instances"]["aromaflow-work"]["deploy"][
            "allowed_image_ref_pattern"
        ] = "[invalid"
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("not a valid regex" in e for e in errors),
            f"missing invalid-regex error in: {errors}",
        )

    def test_released_instance_requires_digest_only_pattern(self) -> None:
        self.data["runtime_instances"]["ai-retail-mvp"]["deploy"][
            "allowed_image_ref_pattern"
        ] = r"^ghcr\.io/airiga1897/ai_e_retail:latest$"
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("digest-only" in e for e in errors),
            f"missing digest-only pattern error in: {errors}",
        )

    def test_site_runtime_requires_all_storage_classes(self) -> None:
        del self.data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["storage"][
            "private_media"
        ]
        errors, _ = validate_data(self.data)
        self.assertTrue(any("storage должен содержать" in error for error in errors), errors)

    def test_site_runtime_rejects_wrong_storage_lifecycle(self) -> None:
        self.data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["storage"][
            "release_static"
        ]["lifecycle"] = "persistent"
        errors, _ = validate_data(self.data)
        self.assertTrue(any("release_static.lifecycle" in error for error in errors), errors)

    def test_site_runtime_rejects_duplicate_storage_volume_names(self) -> None:
        self.data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["storage"][
            "private_media"
        ]["volume"] = "ai_retail_mvp_media"
        errors, _ = validate_data(self.data)
        self.assertTrue(any("volume не должны совпадать" in error for error in errors), errors)

    def test_site_runtime_rejects_wrong_private_media_path(self) -> None:
        self.data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["storage"][
            "private_media"
        ]["container_path"] = "/app/media"
        errors, _ = validate_data(self.data)
        self.assertTrue(any("private_media.container_path" in error for error in errors), errors)

    def test_site_runtime_publication_requires_domain_match(self) -> None:
        self.data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["publication"][
            "domain"
        ] = "wrong.example"
        errors, _ = validate_data(self.data)
        self.assertTrue(any("domains.prod" in error for error in errors), errors)

    def test_site_runtime_publication_rejects_public_worker_health(self) -> None:
        self.data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["publication"][
            "external_health"
        ].append("/worker-healthz/")
        errors, _ = validate_data(self.data)
        self.assertTrue(any("только live и ready" in error for error in errors), errors)

    def test_site_runtime_publication_requires_site_nginx_tls(self) -> None:
        self.data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["publication"]["tls"][
            "termination"
        ] = "haproxy"
        errors, _ = validate_data(self.data)
        self.assertTrue(any("canonical TLS contract" in error for error in errors), errors)

    def test_site_runtime_publication_requires_acme_and_tls_storage(self) -> None:
        del self.data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["publication"][
            "storage"
        ]["tls"]
        errors, _ = validate_data(self.data)
        self.assertTrue(any("acme_webroot и tls" in error for error in errors), errors)

    def test_site_runtime_publication_storage_must_not_overlap_media(self) -> None:
        runtime = self.data["runtime_instances"]["ai-retail-mvp"]["site_runtime"]
        runtime["publication"]["storage"]["tls"]["volume"] = runtime["storage"][
            "public_media"
        ]["volume"]
        errors, _ = validate_data(self.data)
        self.assertTrue(any("storage volumes не должны совпадать" in error for error in errors), errors)

    def test_compose_file_must_be_under_instance_stack(self) -> None:
        self.data["runtime_instances"]["ai-retail-dev"]["deploy"]["environments"][
            "preprod"
        ]["compose_file"] = "infra/stacks/wrong/docker-compose.yml"
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("compose_file must start with" in e for e in errors),
            f"missing compose_file path error in: {errors}",
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

    # ---------- telegram-bot template key variants -------------------
    def test_telegram_bot_uses_short_bot_template_key(self) -> None:
        # Current services.yml uses future_service_template.bot.
        instance = self.data["runtime_instances"]["aromaflow-demo"]
        instance["type"] = "telegram-bot"
        # Required fields from .bot include webhook.preprod / webhook.prod.
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("webhook.preprod is required for type='telegram-bot'" in e for e in errors),
            f"missing telegram-bot template error in: {errors}",
        )

    def test_telegram_bot_also_accepts_long_template_key(self) -> None:
        # Forward-compat: future_service_template.telegram-bot must also work.
        self.data["future_service_template"]["telegram-bot"] = self.data[
            "future_service_template"
        ].pop("bot")
        instance = self.data["runtime_instances"]["aromaflow-demo"]
        instance["type"] = "telegram-bot"
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any(
                "is required for type='telegram-bot'" in e
                and "future_service_template.telegram-bot.required" in e
                for e in errors
            ),
            f"long-key template error not surfaced in: {errors}",
        )

    def test_telegram_client_requires_platform_database_contract(self) -> None:
        instance = self.data["runtime_instances"]["mycleanbot"]
        del instance["data"]["postgres"]["ownership"]
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any(
                "data.postgres.ownership is required for type='telegram-client'" in e
                for e in errors
            ),
            f"missing telegram-client template error in: {errors}",
        )

    def test_telegram_client_rejects_database_container_and_public_ingress(self) -> None:
        instance = self.data["runtime_instances"]["mycleanbot"]
        instance["data"]["postgres"]["container_in_stack"] = True
        instance["vpn"]["public_ingress"] = True
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any("data.postgres.container_in_stack must be false" in error for error in errors)
        )
        self.assertTrue(any("vpn.public_ingress must be false" in error for error in errors))

    def test_telegram_client_requires_canonical_platform_route(self) -> None:
        instance = self.data["runtime_instances"]["mycleanbot"]
        instance["data"]["postgres"]["router_ipv4"] = "172.31.1.99"
        errors, _ = validate_data(self.data)
        self.assertTrue(
            any(
                "data.postgres.router_ipv4 must be '172.31.1.2'" in error
                for error in errors
            ),
            errors,
        )

    def test_telegram_client_requires_scratch_restore_and_worker_heartbeat(self) -> None:
        instance = self.data["runtime_instances"]["mycleanbot"]
        instance["data"]["backup"]["restore_rehearsal"] = "none"
        instance["healthcheck"]["worker_heartbeat_max_age_seconds"] = 0
        errors, _ = validate_data(self.data)
        self.assertTrue(any("weekly-scratch-only" in error for error in errors))
        self.assertTrue(any("positive integer" in error for error in errors))

    # ---------- replit reserved port surfaces as a warning -----------
    def test_replit_reserved_port_is_a_warning_not_an_error(self) -> None:
        # Force a Replit-reserved port (5000) onto an instance and confirm
        # the validator surfaces it as a warning, not an error.
        self.data["runtime_instances"]["aromaflow-work"]["local"]["backend_port"] = 5000
        errors, warnings = validate_data(self.data)
        self.assertEqual(errors, [])
        self.assertTrue(
            any("5000" in w and "Replit" in w for w in warnings),
            f"missing Replit reserved-port warning in: {warnings}",
        )


class ValidatorCliFixtureTests(unittest.TestCase):
    """End-to-end CLI tests against committed YAML fixture files.

    Complements the in-memory mutation tests above with real subprocess
    invocations, asserting both exit codes and key error messages.
    """

    def _run(self, fixture_name: str, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(VALIDATOR), str(FIXTURES_DIR / fixture_name), *extra],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_cli_passes_on_real_services_yml(self) -> None:
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), str(SERVICES_YML)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("services.yml validation passed", result.stdout)

    def test_cli_fails_on_duplicate_port_fixture(self) -> None:
        result = self._run("broken_duplicate_port.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicates port 5170", result.stderr)

    def test_cli_fails_on_bad_env_prefix_fixture(self) -> None:
        result = self._run("broken_bad_env_prefix.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("env.prefix must be 'AROMAFLOW_WORK'", result.stderr)

    def test_cli_fails_on_unknown_vps_fixture(self) -> None:
        result = self._run("broken_unknown_vps.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VPS9", result.stderr)

    def test_cli_fails_on_missing_healthcheck_fixture(self) -> None:
        result = self._run("broken_missing_healthcheck.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("healthcheck.path is required", result.stderr)

    def test_cli_fails_on_missing_deploy_fixture(self) -> None:
        result = self._run("broken_deploy_missing.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deploy", result.stderr)

    def test_cli_fails_on_frozen_without_pattern_fixture(self) -> None:
        result = self._run("broken_frozen_no_pattern.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("frozen_image_ref_pattern", result.stderr)

    def test_cli_fails_on_invalid_regex_fixture(self) -> None:
        result = self._run("broken_pattern_invalid_regex.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a valid regex", result.stderr)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
