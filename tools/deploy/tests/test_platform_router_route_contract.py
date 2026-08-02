from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[3]
PLATFORM_ROUTER_TASKS = (
    ROOT / "infra" / "ansible" / "roles" / "platform_router" / "tasks" / "main.yml"
)
PLATFORM_ROUTER_CONFIG = ROOT / "operator" / "platform_router" / "config.yml"
VPN_EDGE_CONFIG = ROOT / "operator" / "softether" / "edge" / "config.yml"
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
HOST_ROUTE_UNIT = (
    ROOT
    / "infra"
    / "ansible"
    / "roles"
    / "platform_router"
    / "templates"
    / "platform-router-host-routes.service.j2"
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
COMPOSE_TEMPLATE = (
    ROOT
    / "infra"
    / "ansible"
    / "roles"
    / "platform_router"
    / "templates"
    / "docker-compose.platform-router.yml.j2"
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
        self.assertEqual(
            {item["probe_source_cidr"] for item in paths},
            {"172.31.3.2/32"},
        )
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
        gateways = {
            item["source_class"]: item for item in example["source_gateways"]
        }
        self.assertEqual(gateways["site_runtime"]["router_ipv4"], "172.31.3.2")
        self.assertEqual(gateways["vpn_ingress"]["router_ipv4"], "172.22.252.4")

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

    def test_marks_and_egress_tables_exist_only_in_router_namespace(self) -> None:
        host = HOST_ROUTE_TEMPLATE.read_text(encoding="utf-8")
        router = ROUTE_RECONCILER.read_text(encoding="utf-8")
        self.assertNotIn("ip rule add fwmark {{ path.route_mark }}", host)
        self.assertNotIn("ip -4 route replace table {{ path.route_table }} default", host)
        self.assertIn("ip rule add fwmark {{ path.route_mark }}", router)
        self.assertIn("dev \"{{ path.tunnel_iface }}\" onlink", router)

    def test_host_reconciler_owns_source_gateways_and_direct_egress_guard(self) -> None:
        host = HOST_ROUTE_TEMPLATE.read_text(encoding="utf-8")
        router = ROUTE_RECONCILER.read_text(encoding="utf-8")
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")
        unit = HOST_ROUTE_UNIT.read_text(encoding="utf-8")

        self.assertIn("ai_sp_source_gateway_guard", host)
        self.assertIn('nsenter --target "$pid" --net ip -4 route replace default', host)
        self.assertIn("prevent_direct_public_egress", host)
        self.assertIn("ip daddr @internal_destinations accept", host)
        self.assertIn("ip saddr @scoped_sources drop", host)
        self.assertIn("remove_legacy_host_marks", host)
        self.assertIn("Restart=always", unit)
        self.assertIn("AI_SP_SOURCE_GATEWAY=1", unit)
        self.assertIn("source_gateway_state == 'preserve'", tasks)
        self.assertIn("source gateway address {router_ip} is occupied", tasks)
        self.assertIn("source gateway network creation and attachment planned", tasks)
        self.assertIn("source gateway container attachment planned", tasks)
        self.assertIn("network_items = json.loads(network_raw) if network_raw.strip() else []", tasks)
        self.assertIn("Disable stale platform_router source gateways", tasks)
        self.assertIn("Disable platform_router source gateways during removal", tasks)
        self.assertIn("Check live platform_router source gateways", tasks)
        self.assertIn("platform_router_source_gateways_live.rc", tasks)
        self.assertIn("'restarted', 'started'", tasks)
        self.assertIn("platform-router-egress-routes.state", router)
        self.assertIn('ip rule del fwmark "$old_mark"', router)
        self.assertIn('ip -4 route flush table "$old_table"', router)

    def test_remote_egress_nat_is_scoped_to_source_cidrs_and_tap(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")
        self.assertIn('-i "$vpn_iface" -s "$source_cidr" -j SNAT', tasks)
        self.assertIn('"source_cidrs": [str(value) for value in source_cidrs]', tasks)
        self.assertIn(
            '"transport_source_cidrs": [str(value) for value in transport_source_cidrs]',
            tasks,
        )
        self.assertIn('json.dumps(item["transport_source_cidrs"]', tasks)
        self.assertIn('accepted["status"] = "ready"', tasks)
        self.assertIn("iptables -t nat -C PLATFORM_ROUTER_POSTROUTING", tasks)
        self.assertNotIn(
            'grep -F -- "-i $vpn_iface -s $source_cidr -j SNAT',
            tasks,
        )
        self.assertIn("path=${path_alias}, role=${role}, phase=$1", tasks)
        for phase in (
            "router_rule",
            "router_route",
            "router_route_get",
            "marked_route_fail_closed",
            "tunnel_interface_unavailable",
            "target_interface",
            "target_return_route",
            "target_snat",
        ):
            self.assertIn(f"fail_phase {phase}", tasks)

    def test_egress_target_persists_reverse_routes_to_scoped_sources(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")
        reconciler = ROUTE_RECONCILER.read_text(encoding="utf-8")

        self.assertIn('"tunnel_peer_ipv4": str(matching_l3["client_ip"])', tasks)
        self.assertIn(
            'ip route replace "$source_cidr" \\\n            via "$vpn_peer" dev "$vpn_iface" onlink',
            tasks,
        )
        self.assertIn("path.transport_source_cidrs", reconciler)
        self.assertIn('via "{{ path.tunnel_peer_ipv4 }}"', reconciler)

    def test_route_reconciler_does_not_remove_live_mark_rules_each_cycle(self) -> None:
        reconciler = ROUTE_RECONCILER.read_text(encoding="utf-8")

        configure = reconciler.index(
            "ip -4 route replace table {{ path.route_table }} unreachable default metric 32767"
        )
        stale_cleanup = reconciler.index('old_signature="$old_mark|$old_table|$old_priority"')
        self.assertLess(configure, stale_cleanup)
        self.assertIn('grep -Fqx "$old_signature" "$egress_state_next"', reconciler)
        self.assertIn("if ! ip -4 rule show", reconciler)
        self.assertNotIn(
            "while ip rule del fwmark {{ path.route_mark }}/0xffffffff",
            reconciler,
        )
        self.assertIn('mark "$route_mark_decimal" from "$gateway"', PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8"))

    def test_router_namespace_anchor_waits_for_a_strict_successful_reconcile(self) -> None:
        reconciler = ROUTE_RECONCILER.read_text(encoding="utf-8")
        compose = COMPOSE_TEMPLATE.read_text(encoding="utf-8")
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")

        self.assertIn("reconcile_once() (\n  set -e", reconciler)
        self.assertIn('rm -f "$ready_file"', reconciler)
        self.assertIn("reconcile_once\n  reconcile_status=$?", reconciler)
        self.assertIn('touch "$ready_file"', reconciler)
        self.assertIn('if [ -n "$app_iface" ]; then\n    :', reconciler)
        self.assertIn("awk -v wanted='{{ platform_router_model.app_ipv4 }}'", reconciler)
        self.assertIn('address[1] == wanted', reconciler)
        self.assertNotIn('replace(".", "\\\\.")', reconciler)
        self.assertIn("awk -v wanted='{{ platform_router_model.app_ipv4 }}'", tasks)
        self.assertIn('test -f /run/platform-router-reconcile.ready', compose)
        self.assertEqual(compose.count("condition: service_healthy"), 2)
        self.assertIn("until: platform_router_compose_up.rc == 0", tasks)
        self.assertIn("retries: 4", tasks)

    def test_source_paths_remain_fail_closed_while_tunnel_interface_flaps(self) -> None:
        host = HOST_ROUTE_TEMPLATE.read_text(encoding="utf-8")
        router = ROUTE_RECONCILER.read_text(encoding="utf-8")
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")

        self.assertNotIn("unreachable default metric 32767", host)
        self.assertIn("unreachable default metric 32767", router)
        self.assertIn("metric 10", router)
        desired_rule = router.index(
            "ip rule add fwmark {{ path.route_mark }}/0xffffffff"
        )
        runtime_interface = router.index(
            'if ip link show "{{ path.tunnel_iface }}"'
        )
        self.assertLess(desired_rule, runtime_interface)
        self.assertIn(
            "ip -4 route del table {{ path.route_table }} default metric 10",
            router,
        )
        self.assertIn("fail_phase marked_route_fail_closed", tasks)
        self.assertIn("fail_phase tunnel_interface_unavailable", tasks)

    def test_removed_alias_cleans_only_stale_signature_and_unused_table(self) -> None:
        rendered = ROUTE_RECONCILER.read_text(encoding="utf-8")
        self.assertIn('grep -Fqx "$old_signature"', rendered)
        self.assertIn("$2 == table { found = 1 }", rendered)
        self.assertIn('ip -4 route flush table "$old_table"', rendered)

    def test_vps3_source_gateways_use_isolated_vpn_policy_handoff(self) -> None:
        config = yaml.safe_load(PLATFORM_ROUTER_CONFIG.read_text(encoding="utf-8"))[
            "platform_router"
        ]
        gateways = {item["source_class"]: item for item in config["source_gateways"]}
        self.assertEqual(gateways["site_runtime"]["source_ipv4"], "172.31.3.10")
        self.assertEqual(gateways["site_runtime"]["router_ipv4"], "172.31.3.2")
        self.assertEqual(gateways["vpn_ingress"]["source_ipv4"], "172.22.252.2")
        self.assertEqual(gateways["vpn_ingress"]["router_ipv4"], "172.22.252.4")
        self.assertEqual(gateways["vpn_ingress"]["network_name"], "ai_service_vpn_policy")
        self.assertNotIn("172.20.0.0/24", str(gateways))
        self.assertNotIn("ai_service_edge", COMPOSE_TEMPLATE.read_text(encoding="utf-8"))

        vpn_edge = yaml.safe_load(VPN_EDGE_CONFIG.read_text(encoding="utf-8"))
        disabled = vpn_edge["disable_policy_network_aliases"]
        self.assertNotIn("vps3", disabled)
        self.assertIn("vps1", disabled)
        self.assertIn("vps2", disabled)
        self.assertIn("vps4", disabled)
        self.assertIn(
            "platform_router must not attach the shared edge network",
            PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8"),
        )

    def test_multiple_hubs_require_one_server_runtime_credential(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")
        self.assertIn(
            "all hubs in one per-node SoftEther server runtime must share its server_password",
            tasks,
        )
        self.assertIn("unique_networks(transport_networks", tasks)
        self.assertIn("dhcp_enabled must be boolean", tasks)

    def test_sidecar_external_networks_are_checked_before_compose(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")

        self.assertIn('"subnet": str(l3_network_subnet)', tasks)
        self.assertIn("Ensure platform_router external Docker networks exist", tasks)
        self.assertIn('docker network create --subnet "$subnet" "$name"', tasks)
        self.assertIn("external Docker network creation planned", tasks)
        self.assertIn("has subnet $current; expected $subnet", tasks)
        self.assertIn("Show safe platform_router external network preflight", tasks)

    def test_client_configuration_reports_only_safe_failure_phase(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")

        self.assertIn("set_phase account_preserved", tasks)
        self.assertIn("set_phase public_transport_probe", tasks)
        self.assertIn("set_phase public_transport_unavailable", tasks)
        self.assertIn('openssl s_client -connect "$server" -servername "$server_host" -brief', tasks)
        self.assertIn('NicCreate "$nic" >/dev/null 2>&1 || true', tasks)
        self.assertIn("set_phase account_create", tasks)
        self.assertIn("set_phase account_retry", tasks)
        self.assertIn(
            'AccountRetrySet "$account" /NUM:999 /INTERVAL:5',
            tasks,
        )
        self.assertIn("set_phase account_startup", tasks)
        self.assertIn('AccountStartupSet "$account"', tasks)
        self.assertIn("set_phase account_connect", tasks)
        self.assertIn("set_phase account_session_wait", tasks)
        self.assertIn('AccountStatusGet "$account"', tasks)
        self.assertIn("Connection Completed|Session Established", tasks)
        self.assertIn("set_phase authentication_failed", tasks)
        self.assertIn("set_phase session_not_established", tasks)
        self.assertLess(
            tasks.index("set_phase account_session_wait"),
            tasks.index("set_phase interface_wait"),
        )
        self.assertIn("set_phase interface_wait", tasks)
        self.assertIn("set_phase address", tasks)
        self.assertNotIn('AccountDisconnect "$account"', tasks)
        self.assertNotIn('AccountDelete "$account"', tasks)
        self.assertIn("Accept safe platform_router SoftEther client configure phases", tasks)
        self.assertIn("client=${client_name}, phase=${phase}", tasks)
        self.assertIn("no_log: true", tasks)

    def test_one_softether_client_daemon_owns_all_accounts_per_router(self) -> None:
        tasks = PLATFORM_ROUTER_TASKS.read_text(encoding="utf-8")
        compose = COMPOSE_TEMPLATE.read_text(encoding="utf-8")

        self.assertIn('"softether_client_runtime": softether_client_runtime', tasks)
        self.assertIn('"account_count": len(softether_clients)', tasks)
        self.assertIn(
            '"container_name": os.environ["SOFTETHER_CLIENT_CONTAINER"]',
            tasks,
        )
        self.assertIn('"data_dir": "softether_client_data"', tasks)
        self.assertIn("SoftEther client account names must be unique", tasks)
        self.assertIn("SoftEther client NIC names must be unique", tasks)
        self.assertNotIn(
            "{% for client in platform_router_model.softether_clients",
            compose,
        )
        self.assertEqual(compose.count('softether-entrypoint.sh", "client"'), 1)
        self.assertIn(
            "platform_router_model.softether_client_runtime.container_name",
            compose,
        )

    def test_only_vps3_currently_requires_multi_account_client_runtime(self) -> None:
        config = yaml.safe_load(PLATFORM_ROUTER_CONFIG.read_text(encoding="utf-8"))[
            "platform_router"
        ]
        links_document = yaml.safe_load(
            (ROOT / "operator" / "softether" / "l3-vps" / "links.yml").read_text(
                encoding="utf-8"
            )
        )
        links = {item["name"]: item for item in links_document["links"]}
        accounts: dict[str, set[str]] = {}
        for link in config["links"]:
            l3_link = links[link["l3_vps_link"]]
            if l3_link.get("runtime_mode") != "platform_router_sidecar":
                continue
            aliases = set(link.get("source_aliases") or [])
            aliases.add(link.get("source_alias"))
            for alias in aliases - {None, ""}:
                accounts.setdefault(alias, set()).add(link["name"])
        for path in config["egress_paths"]:
            accounts.setdefault(path["source_alias"], set()).add(
                path["l3_vps_link"]
            )

        self.assertEqual(len(accounts["vps3"]), 4)
        self.assertTrue(all(len(items) == 1 for alias, items in accounts.items() if alias != "vps3"))


if __name__ == "__main__":
    unittest.main()
