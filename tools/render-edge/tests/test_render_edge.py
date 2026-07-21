"""Smoke-тесты генератора edge-конфигов.

Тесты гоняют render-edge на канонический ``services.yml`` и проверяют:
- отсутствие падений на дефолтном реестре,
- наличие ключевых строк в HAProxy (SNI ACL для prod-домена,
  TCP-блок SoftEther, allowlist для management-порта),
- наличие nginx-файлов на каждый сайт,
- что флаг ``--check`` ловит дрейф (изменили реестр в tmp — ошибка),
- что некорректная структура реестра завершается кодом 2.
"""

from __future__ import annotations

import copy
import io
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
TOOL_DIR = THIS_DIR.parent
TOOLS_DIR = TOOL_DIR.parent
REPO_ROOT = TOOLS_DIR.parent

sys.path.insert(0, str(TOOLS_DIR))
from _lib.registry import load_registry  # noqa: E402

sys.path.insert(0, str(TOOL_DIR))
from render_edge import (  # noqa: E402
    _collect_sites,
    main,
    render_haproxy,
    render_nginx_site,
)


CANONICAL_REGISTRY = REPO_ROOT / "services.yml"


class RenderEdgeSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = load_registry(CANONICAL_REGISTRY)
        self.sites = _collect_sites(self.registry)

    def test_collects_all_four_sites(self) -> None:
        names = sorted(s["instance_name"] for s in self.sites)
        self.assertEqual(
            names,
            ["ai-retail-dev", "ai-retail-mvp", "aromaflow-demo", "aromaflow-work"],
        )

    def test_haproxy_contains_softether_block_and_real_sni(self) -> None:
        cfg = render_haproxy(self.registry, self.sites)
        # Реальный prod-домен aromaflow-work должен попасть в SNI ACL.
        self.assertIn("mine-craft.su", cfg)
        # TCP-порты SoftEther.
        self.assertIn("frontend softether_tcp_992", cfg)
        self.assertNotIn("frontend softether_tcp_" "11" "94", cfg)
        # Management-allowlist на 5555.
        self.assertIn("softether_mgmt", cfg)
        self.assertIn("vpn_mgmt_ips.lst", cfg)
        # Плейсхолдер-домены не должны попасть в маршрутизацию.
        self.assertNotIn("example.invalid", cfg)

    def test_planned_publication_is_absent_from_active_edge_render(self) -> None:
        site = next(s for s in self.sites if s["instance_name"] == "ai-retail-mvp")
        self.assertEqual("planned", site["publication_state"])
        self.assertEqual([], site["prod_domains"])
        self.assertNotIn("retail.travelltickets.ru", render_haproxy(self.registry, self.sites))
        self.assertNotIn("retail.travelltickets.ru", render_nginx_site(site))

    def test_active_publication_enters_edge_render(self) -> None:
        registry = copy.deepcopy(self.registry)
        registry["runtime_instances"]["ai-retail-mvp"]["site_runtime"]["publication"][
            "state"
        ] = "active"
        sites = _collect_sites(registry)
        site = next(s for s in sites if s["instance_name"] == "ai-retail-mvp")
        self.assertEqual(["retail.travelltickets.ru"], site["prod_domains"])
        self.assertIn("retail.travelltickets.ru", render_haproxy(registry, sites))
        self.assertIn("retail.travelltickets.ru", render_nginx_site(site))

    def test_nginx_site_proxies_to_backend_container(self) -> None:
        site = next(s for s in self.sites if s["instance_name"] == "aromaflow-work")
        rendered = render_nginx_site(site)
        self.assertIn("proxy_pass http://aromaflow-work-backend:8000", rendered)
        self.assertIn("/.well-known/acme-challenge/", rendered)
        self.assertIn("server_name", rendered)
        self.assertIn("X-Forwarded-Proto", rendered)

    def test_main_writes_all_four_nginx_files(self) -> None:
        tmpdir = Path(tempfile.mkdtemp())
        try:
            haproxy_out = tmpdir / "haproxy.cfg"
            sites_dir = tmpdir / "sites"
            rc = main([
                "--haproxy-out", str(haproxy_out),
                "--nginx-out-dir", str(sites_dir),
            ])
            self.assertEqual(rc, 0)
            self.assertTrue(haproxy_out.exists())
            files = sorted(p.name for p in sites_dir.glob("*.conf"))
            self.assertEqual(
                files,
                [
                    "ai-retail-dev.conf",
                    "ai-retail-mvp.conf",
                    "aromaflow-demo.conf",
                    "aromaflow-work.conf",
                ],
            )
        finally:
            shutil.rmtree(tmpdir)

    def test_check_detects_drift(self) -> None:
        tmpdir = Path(tempfile.mkdtemp())
        try:
            haproxy_out = tmpdir / "haproxy.cfg"
            sites_dir = tmpdir / "sites"
            haproxy_out.write_text("stale", encoding="utf-8")
            sites_dir.mkdir()
            buf = io.StringIO()
            with redirect_stderr(buf):
                rc = main([
                    "--haproxy-out", str(haproxy_out),
                    "--nginx-out-dir", str(sites_dir),
                    "--check",
                ])
            self.assertEqual(rc, 1)
            self.assertIn("drifted", buf.getvalue())
            # При check файлы НЕ перезаписываются.
            self.assertEqual(haproxy_out.read_text(encoding="utf-8"), "stale")
        finally:
            shutil.rmtree(tmpdir)

    def test_check_detects_orphan_nginx_conf(self) -> None:
        """`--check` должен падать при наличии orphan-конфига в sites/."""
        tmpdir = Path(tempfile.mkdtemp())
        try:
            haproxy_out = tmpdir / "haproxy.cfg"
            sites_dir = tmpdir / "sites"
            # Сначала рендерим без --check, чтобы каталог совпал с реестром.
            rc_write = main([
                "--haproxy-out", str(haproxy_out),
                "--nginx-out-dir", str(sites_dir),
            ])
            self.assertEqual(rc_write, 0)
            # Подкидываем orphan — инстанса с таким именем в services.yml нет.
            orphan = sites_dir / "stale-instance.conf"
            orphan.write_text("# orphan\n", encoding="utf-8")
            buf = io.StringIO()
            with redirect_stderr(buf):
                rc = main([
                    "--haproxy-out", str(haproxy_out),
                    "--nginx-out-dir", str(sites_dir),
                    "--check",
                ])
            self.assertEqual(rc, 1)
            self.assertIn("orphan", buf.getvalue())
            # При --check orphan-файл НЕ удаляется.
            self.assertTrue(orphan.exists())
        finally:
            shutil.rmtree(tmpdir)

    def test_write_removes_orphan_nginx_conf(self) -> None:
        """В write-режиме orphan-файлы удаляются."""
        tmpdir = Path(tempfile.mkdtemp())
        try:
            haproxy_out = tmpdir / "haproxy.cfg"
            sites_dir = tmpdir / "sites"
            sites_dir.mkdir()
            orphan = sites_dir / "stale-instance.conf"
            orphan.write_text("# orphan\n", encoding="utf-8")
            rc = main([
                "--haproxy-out", str(haproxy_out),
                "--nginx-out-dir", str(sites_dir),
            ])
            self.assertEqual(rc, 0)
            self.assertFalse(orphan.exists())
        finally:
            shutil.rmtree(tmpdir)

    def test_bad_registry_returns_exit_code_2(self) -> None:
        tmpdir = Path(tempfile.mkdtemp())
        try:
            bad = tmpdir / "bad.yml"
            bad.write_text("runtime_instances: not-a-mapping\n", encoding="utf-8")
            buf = io.StringIO()
            with redirect_stderr(buf):
                rc = main([
                    "--registry", str(bad),
                    "--haproxy-out", str(tmpdir / "h.cfg"),
                    "--nginx-out-dir", str(tmpdir / "sites"),
                ])
            self.assertEqual(rc, 2)
            self.assertIn("ERROR", buf.getvalue())
        finally:
            shutil.rmtree(tmpdir)


if __name__ == "__main__":
    unittest.main()
