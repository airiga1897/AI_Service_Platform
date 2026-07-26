from __future__ import annotations

import json
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

import yaml

from tools.site_runtime import bootstrap_runtime, import_project_env
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

    def test_image_preparation_binds_validated_embedded_contract_to_manifest(self) -> None:
        prepare_script = (ROOT / "tools/site_runtime/prepare_image.ps1").read_text(encoding="utf-8")
        stage_tasks = (
            ROOT / "infra/ansible/roles/site_runtime_image_stage/tasks/main.yml"
        ).read_text(encoding="utf-8")
        self.assertIn('docker cp "${contractContainer}:${contractPathInImage}"', prepare_script)
        self.assertIn(
            '& python $contractValidator --contract $contractPath',
            prepare_script,
        )
        self.assertIn("schema_version = 2", prepare_script)
        self.assertIn("project_contract = [ordered]@{", prepare_script)
        self.assertIn(
            "site_runtime_manifest.project_contract.sha256 is match('^[0-9a-f]{64}$')",
            stage_tasks,
        )
        self.assertIn(
            "site_runtime_loaded_project_contract.stdout | trim == "
            "site_runtime_manifest.project_contract.sha256",
            stage_tasks,
        )

    def test_import_writes_bootstrap_secret_separately_without_printing_values(self) -> None:
        contract = load_in_memory(contract_document())
        source = {
            "SECRET_KEY": "application-secret",
            "DJANGO_SUPERUSER_PASSWORD": "bootstrap-secret",
        }
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
                    "--bootstrap-operation",
                    "superuser",
                    "--bootstrap-target",
                    "bootstrap.env",
                ],
            ),
            patch.object(import_project_env, "load_contract", return_value=contract),
            patch.object(
                import_project_env,
                "read_env",
                side_effect=[source, {}, {}],
            ),
            patch.object(Path, "exists", return_value=False),
            patch.object(import_project_env, "_write_atomic") as write_atomic,
            redirect_stdout(output),
        ):
            self.assertEqual(import_project_env.main(), 0)
        self.assertEqual(write_atomic.call_count, 2)
        bootstrap_call = write_atomic.call_args_list[1]
        self.assertEqual(
            bootstrap_call.args[1],
            {"DJANGO_SUPERUSER_PASSWORD": "bootstrap-secret"},
        )
        rendered = output.getvalue()
        self.assertNotIn("application-secret", rendered)
        self.assertNotIn("bootstrap-secret", rendered)
        report = json.loads(rendered)
        self.assertTrue(report["bootstrap"]["mutation_performed"])

    def test_bootstrap_check_validates_secret_without_invoking_superuser(self) -> None:
        contract = load_in_memory(contract_document())
        output = StringIO()
        with (
            patch.object(
                sys,
                "argv",
                [
                    "bootstrap_runtime.py",
                    "--action",
                    "check",
                    "--operation",
                    "superuser",
                    "--contract",
                    "contract.yml",
                    "--secret",
                    "bootstrap.env",
                    "--compose",
                    "docker-compose.yml",
                ],
            ),
            patch.object(bootstrap_runtime, "load_contract", return_value=contract),
            patch.object(
                bootstrap_runtime,
                "read_env",
                return_value={"DJANGO_SUPERUSER_PASSWORD": "bootstrap-secret"},
            ),
            patch.object(Path, "is_file", return_value=True),
            patch.object(bootstrap_runtime, "_run") as run,
            redirect_stdout(output),
        ):
            self.assertEqual(bootstrap_runtime.main(), 0)
        self.assertEqual(run.call_count, 1)
        self.assertIn("exec", run.call_args.args[0])
        report = json.loads(output.getvalue())
        self.assertFalse(report["command_invoked"])
        self.assertFalse(report["check_command_invoked"])

    def test_bootstrap_run_passes_secret_names_without_cli_values(self) -> None:
        contract = load_in_memory(contract_document())
        with (
            patch.object(
                sys,
                "argv",
                [
                    "bootstrap_runtime.py",
                    "--action",
                    "run",
                    "--operation",
                    "superuser",
                    "--contract",
                    "contract.yml",
                    "--secret",
                    "bootstrap.env",
                    "--compose",
                    "docker-compose.yml",
                ],
            ),
            patch.object(bootstrap_runtime, "load_contract", return_value=contract),
            patch.object(
                bootstrap_runtime,
                "read_env",
                return_value={"DJANGO_SUPERUSER_PASSWORD": "bootstrap-secret"},
            ),
            patch.object(Path, "is_file", return_value=True),
            patch.object(bootstrap_runtime, "_run") as run,
            redirect_stdout(StringIO()),
        ):
            self.assertEqual(bootstrap_runtime.main(), 0)
        bootstrap_command = run.call_args_list[0].args[0]
        self.assertIn("DJANGO_SUPERUSER_PASSWORD", bootstrap_command)
        self.assertNotIn("bootstrap-secret", bootstrap_command)
        self.assertEqual(
            run.call_args_list[0].kwargs["env"]["DJANGO_SUPERUSER_PASSWORD"],
            "bootstrap-secret",
        )

    def test_platform_exposes_serialized_contract_driven_bootstrap(self) -> None:
        shell = (ROOT / "tools/services/service.sh").read_text(encoding="utf-8")
        powershell = (ROOT / "tools/services/service_remote.ps1").read_text(
            encoding="utf-8"
        )
        tasks = (
            ROOT
            / "infra/ansible/roles/site_runtime_bootstrap/tasks/main.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("site_runtime bootstrap --instance NAME --operation NAME", shell)
        self.assertIn("site_runtime_bootstrap_operation=$OPERATION", shell)
        self.assertIn("site_runtime_bootstrap_runner_source=", shell)
        self.assertIn("site_runtime_bootstrap_project_contract_source=", shell)
        self.assertNotIn("site_runtime_bootstrap_runner=", shell)
        self.assertIn('[ "$ACTION" = "bootstrap" ]', shell)
        self.assertIn('"bootstrap"', powershell)
        self.assertIn("[string]$Operation", powershell)
        self.assertIn("--operation", powershell)
        self.assertIn("site_runtime operation is already active", shell)
        self.assertIn("project_contract.bootstrap_operations", tasks)
        defaults = (
            ROOT
            / "infra/ansible/roles/site_runtime_bootstrap/defaults/main.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("bootstrap_runtime.py", defaults)
        self.assertIn("project_contract.py", defaults)
        self.assertIn("delegate_to: localhost", tasks)
        self.assertIn("state: directory", tasks)
        self.assertIn("/tools/site_runtime/bootstrap_runtime.py", tasks)
        self.assertIn("/tools/site_runtime/project_contract.py", tasks)
        self.assertIn("import yaml; assert yaml.__version__", tasks)
        self.assertIn(
            "site_runtime_bootstrap_runner_target_stat.stat.checksum == "
            "site_runtime_bootstrap_runner_source_stat.stat.checksum",
            tasks,
        )
        self.assertNotIn(
            "'python3', site_runtime_bootstrap_runner,",
            tasks,
        )
        self.assertIn("no_log: true", tasks)
        self.assertIn("docker, ps, -aq", tasks)
        self.assertIn("check_mode_mutations: false", tasks)
        self.assertGreaterEqual(tasks.count("check_mode: false"), 20)
        self.assertGreaterEqual(tasks.count("changed_when: false"), 15)


if __name__ == "__main__":
    unittest.main()
