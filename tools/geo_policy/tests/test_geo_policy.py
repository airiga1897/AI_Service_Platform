from __future__ import annotations

import datetime as dt
import json
import pathlib
import tempfile
import unittest
from unittest import mock

from tools.geo_policy.geo_policy import (
    ContractError,
    atomic_write,
    build_dataset,
    classify_destination,
    rank_candidates,
    reconcile_health,
    render_nft,
    validate_config,
)
from tools.geo_policy.prepare_transport_secrets import PATHS
from tools.geo_policy.runtime import dataset_status, ensure_route_contract, safe_probe_path


class AtomicWriteTests(unittest.TestCase):
    def test_atomic_write_supports_the_operator_workstation(self) -> None:
        with tempfile.TemporaryDirectory(dir=pathlib.Path.cwd()) as directory:
            target = pathlib.Path(directory) / "data" / "receipt.json"
            atomic_write(target, '{"ok": true}\n', 0o600)

            self.assertEqual(target.read_text(encoding="utf-8"), '{"ok": true}\n')


def config() -> dict:
    return {
        "schema_version": 1,
        "geo_policy": {
            "name": "vps3-site-runtime-vpn",
            "state": "accepted",
            "ingress_alias": "vps3",
            "ipv4_only": True,
            "source_classes": {
                "site_runtime": ["172.31.3.10/32"],
                "vpn_ingress": ["172.20.0.2/32"],
            },
            "excluded_destinations": [
                "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
                "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24",
                "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24",
                "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
            ],
            "routing": {
                "ru_public": "direct",
                "non_ru_public": "egress",
                "unknown_public": "egress",
                "special_or_internal": "direct",
                "fail_closed": True,
            },
            "egress": {
                "approval_id": "approval-1",
                "openai_country_acceptance": {
                    "source_url": "https://help.openai.com/en/articles/5347006-openai-api-supported-countries-and-territories/",
                    "checked_at": "2026-07-28T00:00:00Z",
                    "supported_country_codes": ["NL", "KZ", "DE"],
                },
                "paths": [
                    {
                        "alias": "vps1",
                        "gateway_ipv4": "172.31.3.2",
                        "route_table": 5301,
                        "route_mark": "0x530003",
                        "country_code": "NL",
                    },
                    {
                        "alias": "vps2",
                        "gateway_ipv4": "172.31.3.2",
                        "route_table": 5302,
                        "route_mark": "0x530004",
                        "country_code": "KZ",
                    },
                    {
                        "alias": "vps4",
                        "gateway_ipv4": "172.31.3.2",
                        "route_table": 5303,
                        "route_mark": "0x530005",
                        "country_code": "DE",
                    },
                ],
            },
            "health": {
                "fail_after": 3,
                "recover_after": 5,
                "probe_interval_seconds": 15,
                "recovery_hold_seconds": 300,
                "country_probe_host": "api.country.is",
                "country_probe_path": "/",
                "openai_probe_host": "api.openai.com",
                "openai_probe_path": "/v1/models",
            },
            "dataset": {
                "max_age_hours": 72,
            },
        },
    }


class ConfigTests(unittest.TestCase):
    def test_accepts_exact_canary_contract(self) -> None:
        policy = validate_config(config(), "vps3")
        self.assertEqual(policy.sources, ("172.20.0.2/32", "172.31.3.10/32"))
        self.assertTrue(policy.fail_closed)
        self.assertEqual([item.alias for item in policy.paths], ["vps1", "vps2", "vps4"])

    def test_path_count_can_shrink_or_grow_without_schema_change(self) -> None:
        one = config()
        one["geo_policy"]["egress"]["paths"] = one["geo_policy"]["egress"]["paths"][:1]
        self.assertEqual(len(validate_config(one).paths), 1)
        four = config()
        four["geo_policy"]["egress"]["openai_country_acceptance"][
            "supported_country_codes"
        ].append("FI")
        four["geo_policy"]["egress"]["paths"].append({
            "alias": "vps5",
            "gateway_ipv4": "172.31.3.2",
            "route_table": 5304,
            "route_mark": "0x530006",
            "country_code": "FI",
        })
        self.assertEqual(len(validate_config(four).paths), 4)

    def test_rejects_ipv6_or_broad_source(self) -> None:
        document = config()
        document["geo_policy"]["source_classes"]["site_runtime"] = ["172.31.3.0/24"]
        with self.assertRaisesRegex(ContractError, "/32"):
            validate_config(document)

    def test_rejects_missing_special_exclusion(self) -> None:
        document = config()
        document["geo_policy"]["excluded_destinations"].remove("100.64.0.0/10")
        with self.assertRaisesRegex(ContractError, "100.64.0.0/10"):
            validate_config(document)

    def test_rejects_country_outside_openai_acceptance_receipt(self) -> None:
        document = config()
        document["geo_policy"]["egress"]["paths"][0]["country_code"] = "FR"
        with self.assertRaisesRegex(ContractError, "supported-country receipt"):
            validate_config(document)

    def test_route_mark_is_stable_when_ranking_changes(self) -> None:
        document = config()
        document["geo_policy"]["egress"]["paths"].reverse()
        policy = validate_config(document)
        self.assertEqual(
            {item.alias: item.route_mark for item in policy.paths},
            {"vps1": 0x530003, "vps2": 0x530004, "vps4": 0x530005},
        )

    def test_rejects_duplicate_route_mark(self) -> None:
        document = config()
        document["geo_policy"]["egress"]["paths"][1]["route_mark"] = "0x530003"
        with self.assertRaisesRegex(ContractError, "route marks must be unique"):
            validate_config(document)


class RoutingTests(unittest.TestCase):
    def test_destination_classification(self) -> None:
        ru = ["5.136.0.0/13"]
        exclusions = config()["geo_policy"]["excluded_destinations"]
        self.assertEqual(classify_destination("5.140.1.1", ru, exclusions), "direct")
        self.assertEqual(classify_destination("10.1.1.1", ru, exclusions), "direct")
        self.assertEqual(classify_destination("8.8.8.8", ru, exclusions), "egress")

    def test_nft_render_scopes_new_connections_and_restores_connmark(self) -> None:
        rendered = render_nft(validate_config(config()), ["5.136.0.0/13"], "vps1")
        self.assertIn("ct state established,related meta mark set ct mark", rendered)
        self.assertIn("ct state new ip saddr @scoped_sources jump classify_new", rendered)
        self.assertIn("172.20.0.2/32", rendered)
        self.assertIn("172.31.3.10/32", rendered)
        self.assertIn("ip daddr @ru_ipv4 return", rendered)

    def test_nft_fail_closed_only_after_exclusions_and_ru(self) -> None:
        rendered = render_nft(validate_config(config()), ["5.136.0.0/13"], "blocked")
        self.assertLess(rendered.index("ip daddr @excluded_ipv4 return"), rendered.index("drop"))
        self.assertLess(rendered.index("ip daddr @ru_ipv4 return"), rendered.index("drop"))

    def test_each_ranked_path_uses_a_distinct_connmark(self) -> None:
        policy = validate_config(config())
        first = render_nft(policy, ["5.136.0.0/13"], "vps1")
        second = render_nft(policy, ["5.136.0.0/13"], "vps2")
        third = render_nft(policy, ["5.136.0.0/13"], "vps4")
        self.assertIn("meta mark set 0x530003 ct mark set 0x530003", first)
        self.assertIn("meta mark set 0x530004 ct mark set 0x530004", second)
        self.assertIn("meta mark set 0x530005 ct mark set 0x530005", third)

    def test_transport_receipt_must_match_stable_path_contract(self) -> None:
        policy = validate_config(config())
        receipt = json.dumps({
            "final_status": "succeeded",
            "egress_paths": [{
                "alias": "vps1",
                "gateway_ipv4": "172.31.3.2",
                "route_table": 5301,
                "route_mark": "0xdead",
                "status": "ready",
            }],
        })
        with (
            mock.patch("pathlib.Path.is_file", return_value=True),
            mock.patch("pathlib.Path.read_text", return_value=receipt),
        ):
            with self.assertRaisesRegex(ContractError, "transport receipt"):
                ensure_route_contract(policy, False, "current.json")


class DatasetTests(unittest.TestCase):
    @staticmethod
    def dataset() -> tuple[list[str], list[str]]:
        ipdeny = [f"11.{index // 256}.{index % 256}.0/24" for index in range(5000)]
        ripe = ["ripencc|RU|ipv4|11.0.0.0|1310720|20260101|allocated"]
        return ipdeny, ripe

    def test_first_dataset_requires_acceptance(self) -> None:
        ipdeny, ripe = self.dataset()
        with self.assertRaisesRegex(ContractError, "explicit acceptance"):
            build_dataset(ipdeny, ripe)

    def test_builds_byte_stable_dataset_with_guard(self) -> None:
        ipdeny, ripe = self.dataset()
        content, metadata = build_dataset(ipdeny, ripe, accept_initial=True, fetched_at="2026-07-28T00:00:00Z")
        self.assertTrue(content.endswith("\n"))
        self.assertFalse(content.endswith("\n\n"))
        self.assertGreaterEqual(metadata["ripe_coverage"], 0.9)
        self.assertEqual(metadata["root_accepted_sha256"], metadata["sha256"])

    def test_rejects_large_change_from_last_known_good(self) -> None:
        ipdeny, ripe = self.dataset()
        with self.assertRaisesRegex(ContractError, "delta exceeds"):
            build_dataset(ipdeny, ripe, previous={"address_count": 100})

    def test_marks_stale_last_known_good_as_degraded(self) -> None:
        status = dataset_status({"fetched_at": "2020-01-01T00:00:00Z"}, 72)
        self.assertEqual(status["status"], "degraded")


class RankingTests(unittest.TestCase):
    def test_ranks_only_supported_successful_non_ru_candidates(self) -> None:
        def candidate(alias: str, country: str, latency: int, probe: str = "succeeded") -> dict:
            return {
                "alias": alias,
                "country": country,
                "external_ipv4": f"8.8.8.{len(alias)}",
                "openai_supported_country": country != "RU",
                "openai_probe": probe,
                "latency_ms": [latency] * 5,
            }

        result = rank_candidates({"candidates": [
            candidate("vps3", "RU", 1),
            candidate("vps2", "KZ", 50),
            candidate("vps1", "NL", 30),
            candidate("vps4", "DE", 40),
            candidate("vps9", "DE", 10, "failed"),
        ]})
        self.assertEqual([item["alias"] for item in result["paths"]], ["vps1", "vps4", "vps2"])
        self.assertEqual(result["redundancy"], "available")
        self.assertEqual(result["status"], "proposed")

    def test_accepts_one_path_and_reports_no_redundancy(self) -> None:
        result = rank_candidates({"candidates": [{
            "alias": "vps1",
            "country": "NL",
            "external_ipv4": "8.8.4.4",
            "openai_supported_country": True,
            "openai_probe": "succeeded",
            "latency_ms": [20] * 5,
        }]})
        self.assertEqual([item["alias"] for item in result["paths"]], ["vps1"])
        self.assertEqual(result["redundancy"], "unavailable")

    def test_rejects_candidate_without_public_external_ipv4(self) -> None:
        with self.assertRaisesRegex(ContractError, "public external_ipv4"):
            rank_candidates({"candidates": [{
                "alias": "vps1",
                "country": "NL",
                "external_ipv4": "10.0.0.1",
                "openai_supported_country": True,
                "openai_probe": "succeeded",
                "latency_ms": [20] * 5,
            }]})


class TransportSecretTests(unittest.TestCase):
    def test_contract_has_three_paths_and_reuses_vps1_server_runtime(self) -> None:
        self.assertEqual(
            set(PATHS),
            {
                "geo-egress-vps3-vps1",
                "geo-egress-vps3-vps2",
                "geo-egress-vps3-vps4",
            },
        )
        self.assertEqual(
            PATHS["geo-egress-vps3-vps1"],
            "mycleanbot-operator-vps1",
        )


class FailoverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = validate_config(config())
        self.now = dt.datetime(2026, 7, 28, tzinfo=dt.UTC)

    def test_switches_after_three_failures(self) -> None:
        state: dict = {"active_path": "vps1"}
        for offset in range(3):
            state = reconcile_health(
                self.policy,
                state,
                {"vps1": False, "vps2": True, "vps4": True},
                self.now + dt.timedelta(seconds=15 * offset),
            )
        self.assertEqual(state["active_path"], "vps2")

    def test_uses_third_path_when_first_two_fail(self) -> None:
        state: dict = {"active_path": "vps1"}
        for offset in range(3):
            state = reconcile_health(
                self.policy,
                state,
                {"vps1": False, "vps2": False, "vps4": True},
                self.now + dt.timedelta(seconds=15 * offset),
            )
        self.assertEqual(state["active_path"], "vps4")

    def test_second_path_fails_over_to_third(self) -> None:
        state: dict = {"active_path": "vps2"}
        for offset in range(3):
            state = reconcile_health(
                self.policy,
                state,
                {"vps1": False, "vps2": False, "vps4": True},
                self.now + dt.timedelta(seconds=15 * offset),
            )
        self.assertEqual(state["active_path"], "vps4")

    def test_fails_closed_when_all_paths_fail(self) -> None:
        state: dict = {"active_path": "vps1"}
        for offset in range(3):
            state = reconcile_health(
                self.policy,
                state,
                {"vps1": False, "vps2": False, "vps4": False},
                self.now + dt.timedelta(seconds=15 * offset),
            )
        self.assertEqual(state["active_path"], "blocked")

    def test_blocked_path_waits_for_preferred_path_hysteresis(self) -> None:
        state: dict = {
            "active_path": "blocked",
            "last_switch_at": "2026-07-27T23:59:00Z",
        }
        for offset in range(5):
            state = reconcile_health(
                self.policy,
                state,
                {"vps1": True, "vps2": False, "vps4": False},
                self.now + dt.timedelta(seconds=15 * offset),
            )
        self.assertEqual(state["active_path"], "blocked")

    def test_returns_after_hold_and_five_successes(self) -> None:
        state: dict = {"active_path": "vps4", "last_switch_at": "2026-07-27T23:50:00Z"}
        for offset in range(5):
            state = reconcile_health(
                self.policy,
                state,
                {"vps1": True, "vps2": True, "vps4": True},
                self.now + dt.timedelta(seconds=15 * offset),
            )
        self.assertEqual(state["active_path"], "vps1")

    @mock.patch(
        "tools.geo_policy.runtime.marked_https_get",
        side_effect=TimeoutError("probe timeout"),
    )
    def test_probe_exception_becomes_health_failure(self, _probe: mock.Mock) -> None:
        result = safe_probe_path(config(), self.policy, "vps1")
        self.assertEqual(result["openai_probe"], "failed")
        self.assertEqual(result["error_type"], "TimeoutError")
