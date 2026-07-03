import datetime as dt
import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parent / "files" / "edge_banlist.py"
SPEC = importlib.util.spec_from_file_location("edge_banlist", MODULE_PATH)
edge_banlist = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(edge_banlist)


class EdgeBanlistTtlTests(unittest.TestCase):
    def test_new_ip_gets_base_ttl(self):
        self.assertEqual(edge_banlist.calculate_ttl_seconds(1, 3600, 86400), 3600)

    def test_repeat_ip_doubles_ttl(self):
        self.assertEqual(edge_banlist.calculate_ttl_seconds(2, 3600, 86400), 7200)
        self.assertEqual(edge_banlist.calculate_ttl_seconds(3, 3600, 86400), 14400)

    def test_ttl_is_capped(self):
        self.assertEqual(edge_banlist.calculate_ttl_seconds(20, 3600, 86400), 86400)

    def test_expired_history_is_kept_for_future_repeat(self):
        now = dt.datetime(2026, 7, 3, tzinfo=dt.timezone.utc)
        first_seen = edge_banlist.iso(now - dt.timedelta(days=1))
        bans = {
            "203.0.113.10": {
                "ip": "203.0.113.10",
                "first_seen": first_seen,
                "expires_at": edge_banlist.iso(now - dt.timedelta(hours=1)),
                "count": 3,
                "reasons": ["http_scanner_or_error"],
            }
        }
        active, history = edge_banlist.prune_state(bans, now, [], {"203.0.113.10"})
        self.assertNotIn("203.0.113.10", active)
        self.assertEqual(history["203.0.113.10"]["count"], 3)
        updated = edge_banlist.build_ban_record(
            "203.0.113.10",
            history["203.0.113.10"],
            {"http_scanner_or_error"},
            now,
            3600,
            86400,
            "enforce",
        )
        self.assertEqual(updated["first_seen"], first_seen)
        self.assertEqual(updated["count"], 4)
        self.assertEqual(updated["ttl_seconds"], 28800)

    def test_old_expired_history_is_pruned(self):
        now = dt.datetime(2026, 7, 3, tzinfo=dt.timezone.utc)
        bans = {
            "203.0.113.10": {
                "ip": "203.0.113.10",
                "expires_at": edge_banlist.iso(now - dt.timedelta(days=31)),
                "count": 3,
            }
        }
        active, history = edge_banlist.prune_state(bans, now, [], set())
        self.assertEqual(active, {})
        self.assertEqual(history, {})


if __name__ == "__main__":
    unittest.main()
