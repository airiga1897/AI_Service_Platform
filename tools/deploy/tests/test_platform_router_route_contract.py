from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[3]
PLATFORM_ROUTER_TASKS = (
    ROOT / "infra" / "ansible" / "roles" / "platform_router" / "tasks" / "main.yml"
)
PLATFORM_ROUTER_CONFIG = ROOT / "operator" / "platform_router" / "config.yml"
SERVICE_RUNNER = ROOT / "tools" / "services" / "service.sh"
REMOTE_RUNNER = ROOT / "tools" / "services" / "service_remote.ps1"
HOST_ROUTE_TEMPLATE = (
    ROOT
    / "infra"
    / "ansible"
    / "roles"
    / "platform_router"
    / "templates"
    / "platform-router-host-routes.sh.j2"
)
ROUTE_RECONCILER = (
    ROOT
    / "infra"
    / "ansible"
    / "roles"
    / "platform_router"
    / "templates"
    / "platform-router-reconcile.sh.j2"
)
TRANSPORT_EXAMPLE = ROOT / "docs" / "examples" / "geo-egress-vps3-transports.example.yml"


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

    def test_geo_egress_paths_have_stable_explicit_marks(self) -> None:
        document = yaml.safe_load(PLATFORM_ROUTER_CONFIG.read_text(encoding="utf-8"))
        paths = document["platform_router"]["egress_paths"]
        self.assertEqual(
            {
                item["alias"]: (item["route_mark"], item["route_table"])
                for item in paths
            },
            {
                "vps1": ("0x530003", 5301),
                "vps2": ("0x530004", 5302),
                "vps4": ("0x530005", 5303),
            },
        )
        self.assertEqual({item["source_gateway_ipv4"] for item in paths}, {"172.31.3.2"})
        self.assertEqual(len({item["route_mark"] for item in paths}), len(paths))
        self.assertEqual(len({item["route_table"] for item in paths}), len(paths))
        self.assertEqual(len({item["l3_vps_link"] for item in paths}), len(paths))

    def test_tracked_transport_example_has_three_isolated_routed_taps(self) -> None:
        example = yaml.safe_load(TRANSPORT_EXAMPLE.read_text(encoding="utf-8"))
        links = example["l3_links"]
        self.assertEqual([item["hub"] for item in links], [
            "GeoEgressVps3Vps1",
            "GeoEgressVps3Vps2",
            "GeoEgressVps3Vps4",
        ])
        self.assertEqual({item["tap_name"] for item in links}, {"ge31", "ge32", "ge34"})
        self.assertEqual(len({item["subnet"] for item in links}), 3)
        self.assertFalse(example["defaults"]["dhcp_enabled"])
        self.assertEqual(example["defaults"]["access_mode"], "routed_tap")

    def test_canary_cli_supports_cumulative_egress_path_selection(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")
        service = SERVICE_RUNNER.read_text(encoding="utf-8")
        remote = REMOTE_RUNNER.read_text(encoding="utf-8")

        self.assertIn("platform_router_egress_path_aliases", tasks)
        self.assertIn('os.environ.get("EGRESS_PATH_ALIASES", "")', tasks)
        self.assertIn("unknown platform_router egress aliases", tasks)
        self.assertIn("--platform-router-egress-paths", service)
        self.assertIn("PlatformRouterEgressPaths", remote)
        self.assertIn("Show safe platform_router preflight contract", tasks)
        self.assertIn("check_mode_mutations: false", tasks)
        self.assertIn("receipt_written: false", tasks)

    def test_host_and_router_tables_use_the_same_mark_contract(self) -> None:
        host = HOST_ROUTE_TEMPLATE.read_text(encoding="utf-8")
        router = ROUTE_RECONCILER.read_text(encoding="utf-8")
        self.assertIn("ip rule add fwmark {{ path.route_mark }}", host)
        self.assertIn("ip -4 route replace table {{ path.route_table }} default", host)
        self.assertIn("ip rule add fwmark {{ path.route_mark }}", router)
        self.assertIn("dev \"{{ path.tunnel_iface }}\" onlink", router)

    def test_host_routes_remove_stale_dynamic_path_state(self) -> None:
        host = HOST_ROUTE_TEMPLATE.read_text(encoding="utf-8")
        router = ROUTE_RECONCILER.read_text(encoding="utf-8")
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")

        self.assertIn('state_file="$state_dir/host-routes.state"', host)
        self.assertIn('ip rule del fwmark "$old_mark"', host)
        self.assertIn('ip -4 route flush table "$old_table"', host)
        self.assertIn("Disable stale platform_router host marked routes", tasks)
        self.assertIn("Disable platform_router host marked routes during removal", tasks)
        self.assertIn("platform-router-egress-routes.state", router)
        self.assertIn('ip rule del fwmark "$old_mark"', router)
        self.assertIn('ip -4 route flush table "$old_table"', router)

    def test_remote_egress_nat_is_scoped_to_source_cidrs_and_tap(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")
        self.assertIn('-i "$vpn_iface" -s "$source_cidr" -j SNAT', tasks)
        self.assertIn('"source_cidrs": [str(value) for value in source_cidrs]', tasks)
        self.assertIn('accepted["status"] = "ready"', tasks)
        self.assertIn("iptables -t nat -C PLATFORM_ROUTER_POSTROUTING", tasks)
        self.assertNotIn(
            'grep -F -- "-i $vpn_iface -s $source_cidr -j SNAT',
            tasks,
        )

    def test_multiple_hubs_require_one_server_runtime_credential(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")
        self.assertIn(
            "all hubs in one per-node SoftEther server runtime must share its server_password",
            tasks,
        )
        self.assertIn("unique_networks(transport_networks", tasks)
        self.assertIn("dhcp_enabled must be boolean", tasks)

    def test_client_configuration_reports_only_safe_failure_phase(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")

        self.assertIn("set_phase account_create", tasks)
        self.assertIn("set_phase account_connect", tasks)
        self.assertIn("set_phase interface_wait", tasks)
        self.assertIn("set_phase address", tasks)
        self.assertIn("Accept safe platform_router SoftEther client configure phases", tasks)
        self.assertIn("client=${client_name}, phase=${phase}", tasks)
        self.assertIn("no_log: true", tasks)


if __name__ == "__main__":
    unittest.main()
