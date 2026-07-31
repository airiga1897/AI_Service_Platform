from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
PLATFORM_ROUTER_TASKS = (
    ROOT / "infra" / "ansible" / "roles" / "platform_router" / "tasks" / "main.yml"
)


class PlatformRouterRouteContractTests(unittest.TestCase):
    def test_softether_route_marks_gateway_onlink(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")

        self.assertIn("VPN route interface did not become ready", tasks)
        self.assertIn("for _attempt in $(seq 1 30)", tasks)
        self.assertIn(
            'ip route replace "$destination_ipv4/32" via "$vpn_next_hop" '
            'dev "$vpn_iface" onlink',
            tasks,
        )

    def test_non_vpn_route_does_not_force_onlink(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")

        self.assertIn(
            'ip route replace "$destination_ipv4/32" via "$next_hop"',
            tasks,
        )
        self.assertNotIn(
            'ip route replace "$destination_ipv4/32" via "$next_hop" onlink',
            tasks,
        )

    def test_client_to_client_route_uses_target_client_as_next_hop(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")
        reconcile = (
            ROOT
            / "infra"
            / "ansible"
            / "roles"
            / "platform_router"
            / "templates"
            / "platform-router-reconcile.sh.j2"
        ).read_text(encoding="utf-8")

        self.assertIn("peer_clients = l3_link.get(\"standby_clients\") or {}", tasks)
        self.assertIn('"softether_client_next_hop": policy_vpn_next_hop', tasks)
        self.assertIn(
            'via "{{ policy.softether_client_next_hop }}"',
            reconcile,
        )
        self.assertIn('"softether_return_cidr": return_route_cidr', tasks)
        self.assertIn(
            'via "{{ policy.softether_return_next_hop }}"',
            reconcile,
        )

    def test_target_source_nat_is_explicit_and_policy_scoped(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")

        self.assertIn('policy.get("target_snat_ipv4")', tasks)
        self.assertIn('"target_snat_ipv4": target_snat_ipv4', tasks)
        self.assertIn("-j SNAT --to-source \"$target_snat_ipv4\"", tasks)
        self.assertIn(
            '-s "$source_cidr" -d "$destination_ipv4/32" '
            '--dport "$destination_port"',
            tasks,
        )


if __name__ == "__main__":
    unittest.main()
