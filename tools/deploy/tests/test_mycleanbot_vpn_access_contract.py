from __future__ import annotations

import pathlib
import re
import unittest

import yaml

from tools._lib.registry import load_registry, runtime_instances


ROOT = pathlib.Path(__file__).resolve().parents[3]


class MyCleanBotVpnAccessContractTests(unittest.TestCase):
    def test_registry_declares_private_hosts_endpoint(self) -> None:
        vpn = runtime_instances(load_registry())["mycleanbot"]["vpn"]

        self.assertFalse(vpn["public_ingress"])
        self.assertEqual("mycleanbot.mine-craft.su", vpn["hostname"])
        self.assertEqual("ai_service_vpn_policy", vpn["policy_network"])
        self.assertEqual("172.22.254.10", vpn["private_endpoint_ipv4"])
        self.assertEqual("172.31.1.10", vpn["backend_ipv4"])
        self.assertTrue(vpn["hosts_bootstrap"])

    def test_ingress_compose_has_no_host_port_and_uses_digest(self) -> None:
        compose = (
            ROOT
            / "infra/ansible/roles/mycleanbot_vpn_access/templates/docker-compose.yml.j2"
        ).read_text(encoding="utf-8")
        defaults = yaml.safe_load(
            (
                ROOT
                / "infra/ansible/roles/mycleanbot_vpn_access/defaults/main.yml"
            ).read_text(encoding="utf-8")
        )

        self.assertNotRegex(compose, r"(?m)^\s+ports:")
        self.assertIn("expose:", compose)
        self.assertIn("name: {{ mycleanbot_vpn_access_policy_network_name }}", compose)
        self.assertIn("name: {{ mycleanbot_vpn_access_app_network_name }}", compose)
        self.assertRegex(
            defaults["mycleanbot_vpn_access_image"],
            r"^docker\.io/library/nginx@sha256:[0-9a-f]{64}$",
        )

    def test_nginx_allows_only_edge_and_proxies_private_backend(self) -> None:
        nginx = (
            ROOT
            / "infra/ansible/roles/mycleanbot_vpn_access/templates/nginx.conf.j2"
        ).read_text(encoding="utf-8")

        self.assertIn("allow {{ mycleanbot_vpn_access_edge_ipv4 }};", nginx)
        self.assertIn("deny all;", nginx)
        self.assertIn(
            "proxy_pass http://{{ mycleanbot_vpn_access_backend_ipv4 }}:"
            "{{ mycleanbot_vpn_access_backend_port }};",
            nginx,
        )
        self.assertNotIn("0.0.0.0", nginx)

    def test_role_requires_approval_existing_network_and_tls(self) -> None:
        tasks = (
            ROOT / "infra/ansible/roles/mycleanbot_vpn_access/tasks/main.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("mycleanbot_vpn_access_change_approved | bool", tasks)
        self.assertIn("docker network inspect", tasks)
        self.assertIn("softether-edge is not attached", tasks)
        self.assertIn("Require protected MyCleanBot TLS files", tasks)
        self.assertNotIn("ssh-keyscan", tasks)
        self.assertNotIn("0.0.0.0", tasks)

    def test_windows_hosts_helper_manages_only_one_private_entry(self) -> None:
        helper = (ROOT / "tools/mycleanbot/manage_hosts.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn('[ValidateSet("plan", "apply", "verify", "remove")]', helper)
        self.assertIn('Address = "172.22.254.10"', helper)
        self.assertIn('Hostname = "mycleanbot.mine-craft.su"', helper)
        self.assertIn("# ai-service-platform:mycleanbot", helper)
        self.assertIn("requires an elevated PowerShell session", helper)
        self.assertIn("an unmanaged hosts entry already references", helper)
        self.assertNotIn("Set-DnsClientServerAddress", helper)
        self.assertNotIn("Remove-Item", helper)


if __name__ == "__main__":
    unittest.main()
