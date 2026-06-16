import importlib.util
import shutil
import uuid
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "edge_candidate_collector.py"
SPEC = importlib.util.spec_from_file_location("edge_candidate_collector", MODULE_PATH)
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)
TEST_TMP_ROOT = Path.cwd() / ".tmp" / "edge-candidate-tests"


def make_test_dir():
    path = TEST_TMP_ROOT / uuid.uuid4().hex
    path.mkdir(parents=True, exist_ok=False)
    return path


class EdgeCandidateCollectorTcpdumpTests(unittest.TestCase):
    def collect(self, text):
        tmp = make_test_dir()
        try:
            path = tmp / "tcpdump.log"
            path.write_text(text, encoding="utf-8")
            return collector.collect_from_tcpdump("vps4", path, 5000, "172.20.0.2")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_collects_tcp_from_secure_nat_to_public_ip(self):
        records = self.collect(
            "1781633427.944801 vethdd98d4d P   IP 172.20.0.2.64464 > 77.88.44.55.443: tcp 0\n"
        )

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["source"], "tcpdump_sampler")
        self.assertEqual(records[0]["candidate_type"], "egress_candidate")
        self.assertEqual(records[0]["target"]["value"], "77.88.44.55")
        self.assertEqual(records[0]["target"]["protocol"], "tcp")
        self.assertEqual(records[0]["target"]["port"], 443)

    def test_collects_udp_from_secure_nat_to_public_ip(self):
        records = self.collect(
            "1781633427.986423 vethdd98d4d P   IP 172.20.0.2.63513 > 172.217.17.206.443: UDP, length 1160\n"
        )

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["target"]["value"], "172.217.17.206")
        self.assertEqual(records[0]["target"]["protocol"], "udp")
        self.assertEqual(records[0]["target"]["port"], 443)

    def test_ignores_inbound_client_to_edge(self):
        records = self.collect(
            "1781633427.932696 ens18 In  IP 95.31.25.30.16527 > 185.170.144.219.443: tcp 0\n"
        )

        self.assertEqual(records, [])

    def test_ignores_haproxy_to_softether(self):
        records = self.collect(
            "1781633427.941780 veth68cfe58 P   IP 172.20.0.3.59246 > 172.20.0.2.443: tcp 96\n"
        )

        self.assertEqual(records, [])

    def test_ignores_private_destination_from_secure_nat(self):
        records = self.collect(
            "1781633427.941780 veth68cfe58 P   IP 172.20.0.2.59246 > 172.20.0.3.443: tcp 96\n"
        )

        self.assertEqual(records, [])

    def test_threshold_emits_candidate_after_five_observations(self):
        tmp = make_test_dir()
        try:
            state_path = tmp / "observations.json"
            record = self.collect(
                "1781633427.944801 vethdd98d4d P   IP 172.20.0.2.64464 > 77.88.44.55.443: tcp 0\n"
            )[0]

            for _ in range(4):
                candidates = collector.accumulate_tcpdump_records([record], state_path, 24, 5)
            self.assertEqual(candidates, [])

            candidates = collector.accumulate_tcpdump_records([record], state_path, 24, 5)
            self.assertEqual(len(candidates), 1)
            self.assertEqual(candidates[0]["evidence"]["count"], 5)
            self.assertEqual(candidates[0]["evidence"]["sample_window"], "rolling-24h")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_duplicate_observation_in_same_run_counts_once(self):
        tmp = make_test_dir()
        try:
            state_path = tmp / "observations.json"
            records = self.collect(
                "\n".join(
                    [
                        "1781633427.944801 vethdd98d4d P   IP 172.20.0.2.64464 > 77.88.44.55.443: tcp 0",
                        "1781633427.944913 br-a4f259055e54 In IP 172.20.0.2.64464 > 77.88.44.55.443: tcp 0",
                    ]
                )
                + "\n"
            )
            self.assertEqual(len(records), 1)

            candidates = collector.accumulate_tcpdump_records(records, state_path, 24, 2)

            self.assertEqual(candidates, [])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
