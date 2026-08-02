from pathlib import Path
import unittest

import jinja2
import yaml


ROOT = Path(__file__).resolve().parents[3]


class L3VpnNodeAccessContractTests(unittest.TestCase):
    @staticmethod
    def _model() -> dict:
        return {
            "container_name": "platform-router",
            "transport_networks": [
                {
                    "compose_name": "l3_transport_node1",
                    "name": "ai_service_softether_l3_vps_node1_transport",
                    "subnet": "172.27.1.0/24",
                    "container_ipv4": "172.27.1.2",
                }
            ],
            "management_networks": [
                {
                    "compose_name": "l3_mgmt_node1",
                    "name": "ai_service_softether_l3_vps_node1_mgmt",
                    "subnet": "172.29.1.0/24",
                    "container_ipv4": "172.29.1.2",
                }
            ],
            "data_network_name": "ai_service_data_vps1",
            "data_ipv4": "172.30.1.2",
            "app_network_name": "ai_service_app_vps1",
            "app_ipv4": "172.31.1.2",
            "softether_clients": [],
            "softether_client_runtime": {
                "enabled": False,
            },
            "softether_server_runtime": {
                "enabled": True,
                "container_name": "platform-router-softether-server",
                "image": "ai-service-platform/softether-runtime:test",
                "data_dir": "softether_server_data",
                "logs_dir": "softether_server_logs",
                "adminip_file": "softether_server_adminip.txt",
            },
            "softether_servers": [
                {
                    "access_mode": "routed_tap",
                    "tap_name": "opmc1",
                    "tap_iface": "tap_opmc1",
                    "server_ip": "10.89.1.1",
                    "prefixlen": 24,
                    "client_pool_start": "10.89.1.10",
                    "client_pool_end": "10.89.1.20",
                    "netmask": "255.255.255.0",
                    "pushed_routes": ["172.31.1.11/32"],
                }
            ],
            "policies": [],
        }

    def test_routed_tap_is_isolated_from_secure_nat(self) -> None:
        tasks = (
            ROOT / "infra/ansible/roles/platform_router/tasks/main.yml"
        ).read_text(encoding="utf-8")

        self.assertIn('{"secure_nat", "routed_tap"}', tasks)
        self.assertIn("routed_tap requires at least one pushed route", tasks)
        self.assertIn("/CMD SecureNatDisable", tasks)
        self.assertIn('BridgeCreate "$hub" /DEVICE:"$tap_name" /TAP:yes', tasks)

    def test_router_owns_dhcp_and_only_pushes_declared_routes(self) -> None:
        dockerfile = (ROOT / "infra/docker/policy-router/Dockerfile").read_text(
            encoding="utf-8"
        )
        reconcile = (
            ROOT
            / "infra/ansible/roles/platform_router/templates/platform-router-reconcile.sh.j2"
        ).read_text(encoding="utf-8")

        self.assertIn("dnsmasq", dockerfile)
        self.assertIn("--dhcp-option=option:router", reconcile)
        self.assertIn("option:classless-static-route", reconcile)
        self.assertIn("server.pushed_routes", reconcile)

    def test_server_sidecar_can_create_linux_tap(self) -> None:
        compose = (
            ROOT
            / "infra/ansible/roles/platform_router/templates/docker-compose.platform-router.yml.j2"
        ).read_text(encoding="utf-8")

        self.assertIn("platform_router_model.softether_server_runtime", compose)
        self.assertIn("NET_ADMIN", compose)
        self.assertIn("/dev/net/tun:/dev/net/tun", compose)

    def test_routed_tap_templates_render(self) -> None:
        template_dir = (
            ROOT / "infra/ansible/roles/platform_router/templates"
        )
        environment = jinja2.Environment(
            loader=jinja2.FileSystemLoader(template_dir),
            undefined=jinja2.StrictUndefined,
            autoescape=False,
        )
        model = self._model()
        compose = environment.get_template(
            "docker-compose.platform-router.yml.j2"
        ).render(
            platform_router_model=model,
            platform_router_image="ai-service-platform/platform-router:test",
        )
        rendered = yaml.safe_load(compose)
        self.assertIn("platform-router-softether-server", rendered["services"])
        self.assertNotIn("ports", rendered["services"]["platform-router-softether-server"])

        reconcile = environment.get_template(
            "platform-router-reconcile.sh.j2"
        ).render(platform_router_model=model)
        self.assertIn("tap_opmc1", reconcile)
        self.assertIn("172.31.1.11/32", reconcile)

    def test_l3_edge_route_supports_per_node_networks_and_management_sni(self) -> None:
        tasks = (
            ROOT / "infra/ansible/roles/edge_haproxy/tasks/main.yml"
        ).read_text(encoding="utf-8")
        rollout = (ROOT / "tools/services/rollout_from_state.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn('per_alias.get("network")', tasks)
        self.assertIn('per_alias.get("management_network")', tasks)
        self.assertIn("management_sni", tasks)
        self.assertIn("ai_service_softether_l3_vps_node${nodeNumber}_transport", rollout)
        self.assertIn("ai_service_softether_l3_vps_node${nodeNumber}_mgmt", rollout)

    def test_l3_edge_route_publishes_candidates_without_changing_other_routes(self) -> None:
        tasks = (
            ROOT / "infra/ansible/roles/edge_haproxy/tasks/main.yml"
        ).read_text(encoding="utf-8")

        self.assertIn('name == "softether_l3_vps" and alias in candidate_aliases', tasks)
        self.assertIn('route_states[name] = "candidate"', tasks)
        self.assertIn('route_states[name] = "active"', tasks)
        self.assertNotIn('elif alias in candidate_aliases:', tasks)

    def test_l3_edge_route_requires_backend_and_local_sni_acceptance(self) -> None:
        tasks = (
            ROOT / "infra/ansible/roles/edge_haproxy/tasks/main.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("Verify edge_haproxy SoftEther L3 backend is UP", tasks)
        self.assertIn('row.get("status") == "UP"', tasks)
        self.assertIn("socket.AF_UNIX", tasks)
        self.assertIn("phase=backend_unavailable", tasks)
        self.assertIn("Verify edge_haproxy local SoftEther L3 SNI handshake", tasks)
        self.assertIn("context.wrap_socket", tasks)
        self.assertIn("phase=local_sni_unavailable", tasks)
        self.assertIn("route_state:", tasks)


if __name__ == "__main__":
    unittest.main()
