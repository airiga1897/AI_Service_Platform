from __future__ import annotations

import unittest
from pathlib import Path

from tools.postgres_runtime.validate_audit import validate_report


ROOT = Path(__file__).resolve().parents[3]


def hba_rule(database: str, user: str, address: str) -> dict[str, object]:
    return {
        "type": "host",
        "database": [database],
        "user_name": [user],
        "address": address,
        "netmask": "255.255.255.255",
        "auth_method": "scram-sha-256",
        "error": None,
    }


class PostgresAuditContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = {
            "postgres_runtime": {
                "replication_mode": "async_standby",
                "replication_user": "ai_sp_replicator",
                "replication_slot_prefix": "ai_sp",
                "replication_cidrs": [],
                "replication_hba_cidrs_by_alias": {"vps8": ["172.30.8.2/32"]},
                "managed_databases": {
                    "ai-retail-mvp": {
                        "database": "ai_retail_mvp",
                        "owner_role": "ai_retail_mvp",
                        "allowed_cidrs": ["172.30.8.2/32"],
                    }
                },
            }
        }
        self.state = [
            {
                "kind": "service",
                "name": "postgres_runtime",
                "active_aliases": "vps8",
                "candidate_aliases": "vps4+vps9",
            }
        ]
        rules = [
            hba_rule("ai_retail_mvp", "ai_retail_mvp", "172.30.8.2"),
            hba_rule("replication", "ai_sp_replicator", "172.30.8.2"),
        ]
        self.report = {
            "nodes": [
                {
                    "alias": "vps8",
                    "postgres": {
                        "present": True,
                        "pg_is_in_recovery": "f",
                        "hba_file": "/etc/postgresql/pg_hba.conf",
                        "hba_rules": rules,
                        "replication": [
                            {
                                "application_name": "ai_sp_vps4",
                                "client_addr": "172.30.8.2",
                                "state": "streaming",
                                "sync_state": "async",
                            },
                            {
                                "application_name": "ai_sp_vps9",
                                "client_addr": "172.30.8.2",
                                "state": "streaming",
                                "sync_state": "async",
                            },
                        ],
                        "wal_receivers": [],
                    },
                },
                {
                    "alias": "vps4",
                    "postgres": {
                        "present": True,
                        "pg_is_in_recovery": "t",
                        "wal_receivers": [
                            {"status": "streaming", "slot_name": "ai_sp_vps4"}
                        ],
                    },
                },
                {
                    "alias": "vps9",
                    "postgres": {
                        "present": True,
                        "pg_is_in_recovery": "t",
                        "wal_receivers": [
                            {"status": "streaming", "slot_name": "ai_sp_vps9"}
                        ],
                    },
                },
            ]
        }

    def test_accepts_platform_router_only_cluster(self) -> None:
        result = validate_report(self.report, self.config, self.state)
        self.assertTrue(result["ok"], result["errors"])
        self.assertEqual(result["expected_replication_cidrs"], ["172.30.8.2/32"])

    def test_rejects_public_replication_hba(self) -> None:
        self.report["nodes"][0]["postgres"]["hba_rules"].append(
            hba_rule("replication", "ai_sp_replicator", "161.104.47.37")
        )
        result = validate_report(self.report, self.config, self.state)
        self.assertFalse(result["ok"])
        self.assertTrue(any("replication HBA" in item for item in result["errors"]))

    def test_rejects_missing_streaming_standby(self) -> None:
        self.report["nodes"][0]["postgres"]["replication"].pop()
        result = validate_report(self.report, self.config, self.state)
        self.assertFalse(result["ok"])
        self.assertTrue(any("набор streaming standby" in item for item in result["errors"]))

    def test_rejects_non_streaming_wal_receiver(self) -> None:
        self.report["nodes"][1]["postgres"]["wal_receivers"][0]["status"] = "stopped"
        result = validate_report(self.report, self.config, self.state)
        self.assertFalse(result["ok"])
        self.assertTrue(any("WAL receiver" in item for item in result["errors"]))

    def test_runtime_cleanup_audit_invokes_canonical_validator(self) -> None:
        script = (ROOT / "tools/services/audit_runtime_cleanup.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("validate_audit.py", script)
        self.assertIn("--report $jsonPath --config $PostgresConfig --state $StateFile", script)
        self.assertIn("pg_hba_file_rules", script)
        self.assertIn("pg_stat_replication", script)
        self.assertIn("pg_stat_wal_receiver", script)
        self.assertIn("canonical PostgreSQL contract audit failed", script)


if __name__ == "__main__":
    unittest.main()
