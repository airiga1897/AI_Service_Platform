from __future__ import annotations

import json
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

import yaml

from tools.site_runtime import import_project_env
from tools.site_runtime.project_contract import (
    ProjectContractError,
    load_contract,
    read_env,
    resolve_application_environment,
)


ROOT = Path(__file__).resolve().parents[3]
AI_RETAIL_CONTRACT = Path(r"D:\Projects\Codex\AI_E_Retail\deploy\site-runtime.contract.yml")


def contract_document() -> dict:
    return {
        "schema_version": 1,
        "application": {
            "environment": {
                "runtime": ["ENABLE_DEMO_MODE"],
                "secrets": ["SECRET_KEY"],
                "platform_owned": ["DATABASE_URL"],
                "local_only": ["VITE_DEV_PROXY_TARGET"],
                "bootstrap": {
                    "superuser": {
                        "command": "python manage.py create_superuser",
                        "environment": ["DJANGO_SUPERUSER_PASSWORD"],
                    }
                },
            },
            "frontend": {
                "configuration": "runtime",
                "public_endpoint": "/runtime-config.js",
            },
            "components": {
                "static": "python manage.py collectstatic --noinput",
                "migration": "python manage.py migrate --noinput",
                "web": "gunicorn app.wsgi",
                "worker": "celery worker",
                "beat": "celery beat",
            },
            "health": {
                "live": "/healthz/",
                "ready": "/readyz/",
                "worker": "/worker-healthz/",
            },
        },
    }


def load_in_memory(document: dict):
    with patch.object(Path, "read_text", return_value=yaml.safe_dump(document)):
        return load_contract(Path("contract.yml"))


class ProjectContractTests(unittest.TestCase):
    def test_ai_retail_contract_is_valid_when_checkout_is_available(self) -> None:
        if not AI_RETAIL_CONTRACT.exists():
            self.skipTest("AI_E_Retail checkout is not available")
        contract = load_contract(AI_RETAIL_CONTRACT)
        self.assertEqual(contract.frontend_endpoint, "/runtime-config.js")
        self.assertIn("ENABLE_DEMO_MODE", contract.runtime)
        self.assertIn("DATABASE_URL", contract.platform_owned)
        self.assertEqual(contract.bootstrap["superuser"]["command"], "python manage.py create_superuser")
        self.assertEqual(
            contract.bootstrap["demo_data"]["check_command"],
            "python manage.py load_demo_data --dry-run",
        )

    def test_environment_classes_must_be_disjoint(self) -> None:
        document = contract_document()
        document["application"]["environment"]["platform_owned"].append("ENABLE_DEMO_MODE")
        with self.assertRaisesRegex(ProjectContractError, "belongs to both"):
            load_in_memory(document)

    def test_existing_secret_wins_and_runtime_comes_from_source(self) -> None:
        contract = load_in_memory(contract_document())
        result = resolve_application_environment(
            contract,
            {
                "SECRET_KEY": "development-secret",
                "ENABLE_DEMO_MODE": "True",
                "DATABASE_URL": "postgresql://local",
                "DJANGO_SUPERUSER_PASSWORD": "bootstrap",
            },
            {"SECRET_KEY": "production-secret"},
        )
        self.assertEqual(result["SECRET_KEY"], "production-secret")
        self.assertEqual(result["ENABLE_DEMO_MODE"], "True")
        self.assertNotIn("DATABASE_URL", result)
        self.assertNotIn("DJANGO_SUPERUSER_PASSWORD", result)

    def test_env_reader_accepts_utf8_bom(self) -> None:
        with patch.object(Path, "read_text", return_value="\ufeffENABLE_DEMO_MODE=True\n"):
            self.assertEqual(read_env(Path("profile.env")), {"ENABLE_DEMO_MODE": "True"})

    def test_import_rejects_unclassified_source_key(self) -> None:
        contract = load_in_memory(contract_document())
        error = StringIO()
        with (
            patch.object(
                sys,
                "argv",
                [
                    "import_project_env.py",
                    "--contract",
                    "contract.yml",
                    "--source-env",
                    "source.env",
                    "--target",
                    "target.env",
                    "--check",
                ],
            ),
            patch.object(import_project_env, "load_contract", return_value=contract),
            patch.object(
                import_project_env,
                "read_env",
                side_effect=[{"UNDECLARED_FEATURE": "True"}, {}],
            ),
            patch.object(Path, "exists", return_value=True),
            redirect_stderr(error),
        ):
            self.assertEqual(import_project_env.main(), 2)
        self.assertIn("UNDECLARED_FEATURE", error.getvalue())

    def test_check_does_not_write_and_does_not_print_values(self) -> None:
        contract = load_in_memory(contract_document())
        source = {
            "SECRET_KEY": "development-secret",
            "ENABLE_DEMO_MODE": "True",
            "DATABASE_URL": "postgresql://local-secret",
            "DJANGO_SUPERUSER_PASSWORD": "bootstrap-secret",
        }
        current = {"SECRET_KEY": "production-secret"}
        output = StringIO()
        with (
            patch.object(
                sys,
                "argv",
                [
                    "import_project_env.py",
                    "--contract",
                    "contract.yml",
                    "--source-env",
                    "source.env",
                    "--target",
                    "target.env",
                    "--check",
                ],
            ),
            patch.object(import_project_env, "load_contract", return_value=contract),
            patch.object(import_project_env, "read_env", side_effect=[source, current]),
            patch.object(Path, "exists", return_value=True),
            patch.object(import_project_env, "_write_atomic") as write_atomic,
            redirect_stdout(output),
        ):
            self.assertEqual(import_project_env.main(), 0)
        rendered = output.getvalue()
        report = json.loads(rendered)
        self.assertFalse(report["mutation_performed"])
        self.assertIn("DATABASE_URL", report["ignored_platform_owned_keys"])
        self.assertIn("DJANGO_SUPERUSER_PASSWORD", report["ignored_bootstrap_keys"])
        self.assertNotIn("development-secret", rendered)
        self.assertNotIn("production-secret", rendered)
        self.assertNotIn("bootstrap-secret", rendered)
        write_atomic.assert_not_called()


if __name__ == "__main__":
    unittest.main()
