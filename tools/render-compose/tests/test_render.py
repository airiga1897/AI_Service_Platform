"""Smoke-тесты для инструмента render-compose."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

import yaml

THIS_DIR = Path(__file__).resolve().parent
TOOL_DIR = THIS_DIR.parent
TOOLS_DIR = TOOL_DIR.parent
REPO_ROOT = TOOLS_DIR.parent
RENDERER = TOOL_DIR / "render_compose.py"

sys.path.insert(0, str(TOOLS_DIR))
from _lib.registry import load_registry, runtime_instances  # noqa: E402

sys.path.insert(0, str(TOOL_DIR))
from render_compose import (  # noqa: E402
    RenderError,
    main,
    render_stack,
    stack_output_path,
)


REGISTRY = load_registry()
EXPECTED_STACKS = list(runtime_instances(REGISTRY).keys())
GENERATED_MARKER = "СГЕНЕРИРОВАННЫЙ ФАЙЛ"


class RenderHappyPathTests(unittest.TestCase):
    """Каждый runtime-инстанс должен рендериться в валидный Compose YAML."""

    def test_every_instance_renders_to_valid_yaml(self) -> None:
        for name in EXPECTED_STACKS:
            with self.subTest(stack=name):
                rendered = render_stack(name, REGISTRY)
                self.assertIn(GENERATED_MARKER, rendered)
                doc = yaml.safe_load(rendered)
                self.assertIsInstance(doc, dict)
                self.assertIn("services", doc)
                self.assertIn("volumes", doc)

    def test_rendered_services_match_containers_future(self) -> None:
        for name in EXPECTED_STACKS:
            with self.subTest(stack=name):
                instance = runtime_instances(REGISTRY)[name]
                expected = set(instance["containers"]["future"])
                doc = yaml.safe_load(render_stack(name, REGISTRY))
                self.assertEqual(set(doc["services"]), expected)

    def test_rendered_compose_includes_env_file_and_healthcheck(self) -> None:
        for name in EXPECTED_STACKS:
            with self.subTest(stack=name):
                instance = runtime_instances(REGISTRY)[name]
                rendered = render_stack(name, REGISTRY)
                self.assertIn(f"../../{instance['env']['file']}", rendered)
                self.assertIn(instance["healthcheck"]["path"], rendered)

    def test_mycleanbot_uses_platform_postgres_without_database_container(self) -> None:
        doc = yaml.safe_load(render_stack("mycleanbot", REGISTRY))
        self.assertEqual(
            set(doc["services"]),
            {"mycleanbot-web", "mycleanbot-worker"},
        )
        self.assertNotIn("postgres", str(doc).lower())
        self.assertEqual(
            doc["services"]["mycleanbot-worker"]["command"],
            ["python", "manage.py", "run_telegram_worker"],
        )
        self.assertNotIn("ports", doc["services"]["mycleanbot-worker"])
        self.assertIn(
            "WorkerHeartbeat",
            " ".join(doc["services"]["mycleanbot-worker"]["healthcheck"]["test"]),
        )
        self.assertIn(
            "/livez",
            " ".join(doc["services"]["mycleanbot-web"]["healthcheck"]["test"]),
        )


class RenderErrorTests(unittest.TestCase):
    def test_unknown_stack_raises(self) -> None:
        with self.assertRaises(RenderError):
            render_stack("does-not-exist", REGISTRY)

    def test_unknown_project_type_raises(self) -> None:
        import copy
        registry = copy.deepcopy(REGISTRY)
        registry["projects"]["aromaflowai"]["type"] = "no-such-type"
        with self.assertRaises(RenderError):
            render_stack("aromaflow-work", registry)


class CheckModeCliTests(unittest.TestCase):
    """End-to-end CLI-тесты для --check на зафиксированных compose-файлах."""

    def _run(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(RENDERER), *args],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_check_all_passes_when_in_sync(self) -> None:
        result = self._run("--stack", "all", "--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in EXPECTED_STACKS:
            self.assertIn("up to date", result.stdout)

    def test_check_fails_when_file_drifts(self) -> None:
        # Меняем один файл стека, запускаем --check, восстанавливаем.
        target = stack_output_path("aromaflow-work")
        original = target.read_text(encoding="utf-8")
        try:
            target.write_text(original + "\n# tampered\n", encoding="utf-8")
            result = self._run("--stack", "aromaflow-work", "--check")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("out of date", result.stderr)
        finally:
            target.write_text(original, encoding="utf-8")

    def test_main_writes_to_custom_out(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "compose.yml"
            rc = main(["--stack", "aromaflow-demo", "--out", str(out)])
            self.assertEqual(rc, 0)
            self.assertTrue(out.exists())
            self.assertIn("aromaflow-demo-backend", out.read_text(encoding="utf-8"))


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
