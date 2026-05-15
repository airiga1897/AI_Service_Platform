"""Smoke-тесты для tools/healthcheck с моками urllib."""

from __future__ import annotations

import io
import json
import socket
import sys
import unittest
from pathlib import Path
from unittest import mock
from urllib import error as urlerror

THIS_DIR = Path(__file__).resolve().parent
TOOL_DIR = THIS_DIR.parent
TOOLS_DIR = TOOL_DIR.parent
REPO_ROOT = TOOLS_DIR.parent

sys.path.insert(0, str(TOOLS_DIR))
sys.path.insert(0, str(TOOL_DIR))
import healthcheck as hc  # noqa: E402
from _lib.registry import load_registry, runtime_instances  # noqa: E402


REGISTRY = load_registry()


def _fake_response(status: int) -> mock.MagicMock:
    """Мок ответа urlopen с заданным HTTP-статусом."""
    resp = mock.MagicMock()
    resp.status = status
    resp.getcode.return_value = status
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False
    return resp


class BuildTargetsTests(unittest.TestCase):
    def test_local_targets_use_existing_scheme_and_port(self) -> None:
        targets, skipped = hc.build_targets(REGISTRY, "local", None, None)
        # У всех инстансов в local есть один localhost-домен, ни одного skipped.
        self.assertEqual(len(skipped), 0)
        urls = {t.instance: t.url for t in targets}
        self.assertEqual(urls["aromaflow-work"], "http://localhost:5000/health/")
        self.assertEqual(urls["aromaflow-demo"], "http://localhost:5010/health/")
        self.assertEqual(urls["ai-retail-mvp"], "http://localhost:5173/health/")
        self.assertEqual(urls["ai-retail-dev"], "http://localhost:5174/health/")

    def test_preprod_placeholder_domains_are_skipped(self) -> None:
        targets, skipped = hc.build_targets(REGISTRY, "preprod", None, None)
        # aromaflow-work имеет реальный preprod-домен; demo/mvp/dev — заглушки.
        target_urls = [t.url for t in targets]
        self.assertIn("https://site.mine-craft.su/health/", target_urls)

        skipped_by_instance = {r.instance: r for r in skipped}
        for name in ("aromaflow-demo", "ai-retail-mvp", "ai-retail-dev"):
            self.assertEqual(skipped_by_instance[name].status, "skipped")
            self.assertEqual(skipped_by_instance[name].reason, hc.PLACEHOLDER_REASON)

    def test_prod_instances_without_domains_are_skipped(self) -> None:
        _, skipped = hc.build_targets(REGISTRY, "prod", None, None)
        skipped_by_instance = {r.instance: r for r in skipped}
        # У трёх инстансов prod-доменов нет → no-domains skipped.
        for name in ("aromaflow-demo", "ai-retail-mvp", "ai-retail-dev"):
            self.assertIn(name, skipped_by_instance)
            self.assertEqual(skipped_by_instance[name].reason, "no-domains")

    def test_unknown_instance_raises(self) -> None:
        with self.assertRaises(hc.HealthcheckConfigError):
            hc.build_targets(REGISTRY, "preprod", ["does-not-exist"], None)

    def test_unknown_env_raises(self) -> None:
        with self.assertRaises(hc.HealthcheckConfigError):
            hc.build_targets(REGISTRY, "staging", None, None)

    def test_timeout_override_applied(self) -> None:
        targets, _ = hc.build_targets(REGISTRY, "local", ["aromaflow-work"], 1.5)
        self.assertEqual(targets[0].timeout_seconds, 1.5)


class ProbeTests(unittest.TestCase):
    def _target(self, expected: int = 200, timeout: float = 5.0) -> hc.Target:
        return hc.Target(
            instance="aromaflow-work",
            env="preprod",
            domain="site.mine-craft.su",
            url="https://site.mine-craft.su/health/",
            expected_status=expected,
            timeout_seconds=timeout,
        )

    def test_ok_when_status_matches(self) -> None:
        with mock.patch.object(hc.urlrequest, "urlopen", return_value=_fake_response(200)):
            result = hc.probe(self._target())
        self.assertEqual(result.status, "ok")
        self.assertEqual(result.http_status, 200)
        self.assertIsNone(result.error)

    def test_fail_on_unexpected_status(self) -> None:
        with mock.patch.object(hc.urlrequest, "urlopen", return_value=_fake_response(500)):
            result = hc.probe(self._target(expected=200))
        self.assertEqual(result.status, "fail")
        self.assertEqual(result.http_status, 500)
        self.assertIn("unexpected-status", result.error or "")

    def test_http_error_recorded_with_code(self) -> None:
        err = urlerror.HTTPError(
            url="https://x", code=503, msg="x", hdrs=None, fp=io.BytesIO(b"")
        )
        with mock.patch.object(hc.urlrequest, "urlopen", side_effect=err):
            result = hc.probe(self._target(expected=200))
        self.assertEqual(result.status, "fail")
        self.assertEqual(result.http_status, 503)

    def test_dns_failure_recorded_as_fail(self) -> None:
        with mock.patch.object(
            hc.urlrequest,
            "urlopen",
            side_effect=urlerror.URLError("Name or service not known"),
        ):
            result = hc.probe(self._target())
        self.assertEqual(result.status, "fail")
        self.assertIsNone(result.http_status)
        self.assertIn("url-error", result.error or "")

    def test_timeout_recorded_as_fail(self) -> None:
        with mock.patch.object(
            hc.urlrequest, "urlopen", side_effect=urlerror.URLError(socket.timeout())
        ):
            result = hc.probe(self._target(timeout=2.0))
        self.assertEqual(result.status, "fail")
        self.assertIn("timeout", (result.error or "").lower())


class RunCliTests(unittest.TestCase):
    def test_run_returns_exit_0_when_all_ok_or_skipped(self) -> None:
        # preprod: один реальный target + три placeholder skipped. Мок 200.
        with mock.patch.object(hc.urlrequest, "urlopen", return_value=_fake_response(200)):
            args = hc.parse_args(["--env", "preprod", "--json"])
            exit_code, output = hc.run(args)
        self.assertEqual(exit_code, 0)
        report = json.loads(output)
        self.assertEqual(report["env"], "preprod")
        self.assertEqual(report["summary"]["fail"], 0)
        self.assertEqual(report["summary"]["ok"], 1)
        self.assertEqual(report["summary"]["skipped"], 3)

    def test_run_returns_exit_1_on_any_fail(self) -> None:
        with mock.patch.object(hc.urlrequest, "urlopen", return_value=_fake_response(503)):
            args = hc.parse_args(["--env", "preprod"])
            exit_code, output = hc.run(args)
        self.assertEqual(exit_code, 1)
        self.assertIn("FAIL", output)
        self.assertIn("summary:", output)

    def test_main_returns_exit_2_on_config_error(self) -> None:
        rc = hc.main(["--env", "preprod", "--instance", "does-not-exist"])
        self.assertEqual(rc, 2)

    def test_main_returns_exit_2_on_invalid_timeout(self) -> None:
        rc = hc.main(["--env", "local", "--timeout", "-1"])
        self.assertEqual(rc, 2)
        rc_zero = hc.main(["--env", "local", "--timeout", "0"])
        self.assertEqual(rc_zero, 2)

    def test_main_returns_exit_2_on_malformed_registry(self) -> None:
        import tempfile
        with tempfile.NamedTemporaryFile(
            "w", suffix=".yml", delete=False, encoding="utf-8"
        ) as fh:
            fh.write("runtime_instances: not-a-mapping\n")
            path = fh.name
        try:
            rc = hc.main(["--env", "local", "--registry", path])
            self.assertEqual(rc, 2)
        finally:
            Path(path).unlink(missing_ok=True)

    def test_preprod_url_forces_https_even_if_registry_has_http(self) -> None:
        # Сцена: в реестре в preprod-домене кто-то ошибочно поставил http://.
        # _build_url должен всё равно построить https://.
        url = hc._build_url("preprod", "http://site.example.com", "/health/")
        self.assertEqual(url, "https://site.example.com/health/")
        url2 = hc._build_url("prod", "https://site.example.com", "/health/")
        self.assertEqual(url2, "https://site.example.com/health/")
        url3 = hc._build_url("preprod", "site.example.com", "/health/")
        self.assertEqual(url3, "https://site.example.com/health/")

    def test_json_output_is_valid_and_includes_url(self) -> None:
        with mock.patch.object(hc.urlrequest, "urlopen", return_value=_fake_response(200)):
            args = hc.parse_args(
                ["--env", "local", "--instance", "aromaflow-work", "--json"]
            )
            exit_code, output = hc.run(args)
        self.assertEqual(exit_code, 0)
        report = json.loads(output)
        self.assertEqual(len(report["results"]), 1)
        result = report["results"][0]
        self.assertEqual(result["url"], "http://localhost:5000/health/")
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["http_status"], 200)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
