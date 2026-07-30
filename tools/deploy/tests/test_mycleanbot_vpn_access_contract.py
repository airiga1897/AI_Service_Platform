from __future__ import annotations

import pathlib
import re
import json
import subprocess
import sys
import tempfile
import unittest

import yaml

from tools._lib.registry import load_registry, runtime_instances


ROOT = pathlib.Path(__file__).resolve().parents[3]


class MyCleanBotVpnAccessContractTests(unittest.TestCase):
    def test_registry_declares_private_hosts_endpoint(self) -> None:
        vpn = runtime_instances(load_registry())["mycleanbot"]["vpn"]

        self.assertFalse(vpn["public_ingress"])
        self.assertEqual("mycleanbot.mine-craft.su", vpn["hostname"])
        self.assertEqual("softether_l3_vps", vpn["transport"])
        self.assertEqual("l3-vps1.mine-craft.su", vpn["server_sni"])
        self.assertEqual("MyCleanBotOperatorVps1", vpn["hub"])
        self.assertEqual("10.89.1.0/24", vpn["client_subnet"])
        self.assertEqual("172.31.1.11", vpn["private_endpoint_ipv4"])
        self.assertEqual("172.31.1.10", vpn["backend_ipv4"])
        self.assertTrue(vpn["hosts_bootstrap"])
        self.assertEqual("10.89.1.10", vpn["client_pool_start"])
        self.assertEqual("10.89.1.20", vpn["client_pool_end"])
        self.assertTrue(vpn["per_invitation_accounts"])
        self.assertEqual("mcb_user_", vpn["managed_user_prefix"])
        self.assertEqual(["operator_arm"], vpn["protected_users"])
        self.assertEqual(9, vpn["managed_user_limit"])

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

        self.assertIn("allow {{ mycleanbot_vpn_access_operator_cidr }};", nginx)
        self.assertIn("allow {{ mycleanbot_vpn_access_router_ipv4 }};", nginx)
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
        defaults = yaml.safe_load(
            (
                ROOT
                / "infra/ansible/roles/mycleanbot_vpn_access/defaults/main.yml"
            ).read_text(encoding="utf-8")
        )

        self.assertIn("mycleanbot_vpn_access_change_approved | bool", tasks)
        self.assertIn("docker network inspect", tasks)
        self.assertIn("unexpected MyCleanBot app subnet or endpoint", tasks)
        self.assertIn("Require protected MyCleanBot TLS files", tasks)
        self.assertIn(
            "python3 -c 'import json, os, sys; data = json.load(sys.stdin)[0];",
            tasks,
        )
        self.assertNotIn(
            'NETWORK="{{ mycleanbot_vpn_access_app_network_name }}" '
            "python3 -c '\n",
            tasks,
        )
        self.assertNotIn("ssh-keyscan", tasks)
        self.assertNotIn("0.0.0.0", tasks)
        self.assertEqual(
            "/usr/local/bin/ai-service-mycleanbot-backup backup",
            defaults["mycleanbot_vpn_access_backup_command"],
        )
        self.assertEqual(
            "/etc/sudoers.d/depuser-mycleanbot",
            defaults["mycleanbot_vpn_access_deploy_sudoers_file"],
        )
        self.assertIn("validate: /usr/sbin/visudo -cf %s", tasks)
        self.assertIn("ALL=(root) NOPASSWD:", tasks)
        self.assertNotIn("NOPASSWD: ALL", tasks)
        self.assertIn("up -d --force-recreate", tasks)

    def test_windows_hosts_helper_manages_only_one_private_entry(self) -> None:
        helper = (ROOT / "tools/mycleanbot/manage_hosts.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn('[ValidateSet("plan", "apply", "verify", "remove")]', helper)
        self.assertIn('Address = "172.31.1.11"', helper)
        self.assertIn('Hostname = "mycleanbot.mine-craft.su"', helper)
        self.assertIn("# ai-service-platform:mycleanbot", helper)
        self.assertIn("requires an elevated PowerShell session", helper)
        self.assertIn("an unmanaged hosts entry already references", helper)
        self.assertNotIn("Set-DnsClientServerAddress", helper)
        self.assertNotIn("Remove-Item", helper)

    def test_platform_router_reconciles_only_explicit_managed_users(self) -> None:
        tasks = (
            ROOT / "infra/ansible/roles/platform_router/tasks/main.yml"
        ).read_text(encoding="utf-8")
        example = (
            ROOT / "docs/examples/l3-vps1-mycleanbot.example.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("managed_client_user_prefix", tasks)
        self.assertIn("protected_client_users", tasks)
        self.assertIn("SessionDisconnect", tasks)
        self.assertIn("UserDelete", tasks)
        self.assertIn("no_log:", tasks)
        self.assertIn("managed_client_user_prefix: mcb_user_", example)
        self.assertIn("- operator_arm", example)

    def test_per_invitation_helper_never_prints_passwords(self) -> None:
        helper = ROOT / "tools/mycleanbot/manage_vpn_users.py"
        temporary_base = (
            ROOT.parent.parent if ROOT.parent.name == ".codex-worktrees" else ROOT
        )
        with tempfile.TemporaryDirectory(dir=temporary_base) as temporary:
            operator_dir = pathlib.Path(temporary) / "operator"
            secret_path = operator_dir / "softether-secret.json"
            registry_path = operator_dir / "vpn-users.json"
            delivery_dir = operator_dir / "vpn-delivery"
            secret_path.parent.mkdir(parents=True)
            initial = {
                "server_password": "server-secret",
                "hub_password": "hub-secret",
                "client_users": {
                    "operator-arm": {
                        "client_user": "operator_arm",
                        "client_password": "operator-secret",
                    }
                },
            }
            secret_path.write_text(json.dumps(initial), encoding="utf-8")

            plan = subprocess.run(
                [
                    sys.executable,
                    str(helper),
                    "issue",
                    "--invitation-id",
                    "42",
                    "--operator-dir",
                    str(operator_dir),
                    "--secret-path",
                    str(secret_path),
                    "--registry-path",
                    str(registry_path),
                    "--delivery-dir",
                    str(delivery_dir),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn('"mutations": false', plan.stdout)
            self.assertFalse(registry_path.exists())

            issued = subprocess.run(
                [
                    sys.executable,
                    str(helper),
                    "issue",
                    "--invitation-id",
                    "42",
                    "--operator-dir",
                    str(operator_dir),
                    "--secret-path",
                    str(secret_path),
                    "--registry-path",
                    str(registry_path),
                    "--delivery-dir",
                    str(delivery_dir),
                    "--apply",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            secret = json.loads(secret_path.read_text(encoding="utf-8"))
            generated_password = secret["client_users"]["invitation-42"][
                "client_password"
            ]
            self.assertNotIn(generated_password, issued.stdout)
            self.assertEqual(
                "operator_arm",
                secret["client_users"]["operator-arm"]["client_user"],
            )
            delivery_path = delivery_dir / "invitation-42.json"
            delivery = json.loads(delivery_path.read_text(encoding="utf-8"))
            self.assertEqual(generated_password, delivery["password"])
            self.assertEqual(
                "172.31.1.11 mycleanbot.mine-craft.su",
                delivery["hosts_entry"],
            )

            revoked = subprocess.run(
                [
                    sys.executable,
                    str(helper),
                    "revoke",
                    "--invitation-id",
                    "42",
                    "--operator-dir",
                    str(operator_dir),
                    "--secret-path",
                    str(secret_path),
                    "--registry-path",
                    str(registry_path),
                    "--delivery-dir",
                    str(delivery_dir),
                    "--apply",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertNotIn(generated_password, revoked.stdout)
            secret = json.loads(secret_path.read_text(encoding="utf-8"))
            self.assertNotIn("invitation-42", secret["client_users"])
            self.assertFalse(delivery_path.exists())
            registry = json.loads(
                registry_path.read_text(encoding="utf-8")
            )
            self.assertEqual("revoked", registry["entries"]["42"]["status"])
            self.assertIn("tombstone_until", registry["entries"]["42"])


if __name__ == "__main__":
    unittest.main()
