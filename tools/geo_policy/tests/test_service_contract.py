from __future__ import annotations

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]


def text(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class ServiceContractTests(unittest.TestCase):
    def test_service_runner_exposes_check_override_and_rollback(self) -> None:
        runner = text("tools/services/service.sh")
        self.assertIn("geo_policy apply --limit vps3", runner)
        self.assertIn("--geo-policy-active-path", runner)
        self.assertIn("geo_policy rollback --limit vps3", runner)
        self.assertIn('"geo_policy_active_path=$GEO_POLICY_ACTIVE_PATH"', runner)
        self.assertIn('GEO_POLICY_ACTIVE_PATH="auto"', runner)
        self.assertNotIn("primary|backup", runner)

    def test_operator_contract_uses_a_variable_ordered_path_list(self) -> None:
        config = text("operator/geo_policy/config.yml.example")
        self.assertIn("paths:", config)
        for alias in ("vps1", "vps2", "vps4"):
            self.assertIn(f"alias: {alias}", config)
        for mark in ("0x530003", "0x530004", "0x530005"):
            self.assertIn(f'route_mark: "{mark}"', config)
        self.assertNotIn("routing:\n    route_mark:", config)
        self.assertNotIn("primary:", config)
        self.assertNotIn("backup:", config)

    def test_remote_runner_bundles_geo_policy_tools_and_operator_intent(self) -> None:
        runner = text("tools/services/service_remote.ps1")
        self.assertIn('[string]$GeoPolicyToolsDir = "tools/geo_policy"', runner)
        self.assertIn('"geo_policy", "site_runtime"', runner)
        self.assertIn("GeoPolicyActivePath", runner)

    def test_ranking_records_validated_external_ipv4(self) -> None:
        collector = text("tools/geo_policy/collect_candidates.py")
        model = text("tools/geo_policy/geo_policy.py")

        self.assertIn('"external_ipv4": external_ipv4', collector)
        self.assertIn("returned no valid external IPv4", collector)
        self.assertIn("requires a public external_ipv4", model)

    def test_check_is_mutation_free_and_guards_ipv6(self) -> None:
        role = text("infra/ansible/roles/geo_policy/tasks/main.yml")
        self.assertIn("Run mutation-free GeoPolicy runtime preflight", role)
        self.assertIn("changed_when: false", role)
        self.assertIn("Global IPv6 bypass detected", role)
        self.assertIn("ipaddress.ip_address", role)
        self.assertIn("parsed.is_global", role)
        self.assertNotIn("grep -Eq '[0-9a-fA-F:]'", role)
        self.assertIn("--transport-receipt", role)
        self.assertIn("not ansible_check_mode", role)

    def test_refresh_uses_lock_atomic_moves_and_reapplies_dataset(self) -> None:
        refresh = text(
            "infra/ansible/roles/geo_policy/templates/refresh-dataset.sh.j2"
        )
        service = text(
            "infra/ansible/roles/geo_policy/templates/geo-policy-refresh.service.j2"
        )
        self.assertIn('mv -f "$tmp/ru_ipv4.cidrs"', refresh)
        self.assertIn('"$root/tools/geo_policy/runtime.py" apply', refresh)
        self.assertNotIn('"$root/tools/geo_policy/runtime.py" reconcile', refresh)
        self.assertIn("/usr/bin/flock", service)

    def test_operator_dataset_refresh_retries_transport_and_has_ripe_fallback(self) -> None:
        refresh = text("tools/geo_policy/refresh_dataset.ps1")

        self.assertIn("function Invoke-GeoPolicyDownload", refresh)
        self.assertIn("--retry 3", refresh)
        self.assertIn("--fail", refresh)
        self.assertIn("[Net.SecurityProtocolType]::Tls12", refresh)
        self.assertIn(
            "https://ftp.ripe.net/ripe/stats/delegated-ripencc-extended-latest",
            refresh,
        )
        self.assertIn("returned an empty file", refresh)

    def test_absent_removes_policy_but_preserves_transport_contract(self) -> None:
        role = text("infra/ansible/roles/geo_policy/tasks/main.yml")
        runtime = text("tools/geo_policy/runtime.py")
        self.assertIn("preserving platform_router transport", role)
        self.assertIn('"transport_contract_preserved": True', runtime)
        self.assertNotIn('"route", "flush", "table"', runtime)
        self.assertIn("Remove GeoPolicy systemd units", role)


if __name__ == "__main__":
    unittest.main()
