from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
ROLLOUT = ROOT / "tools" / "geo_policy" / "rollout_transport.ps1"


class GeoPolicyTransportRolloutContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.script = ROLLOUT.read_text(encoding="utf-8")

    def test_uses_canonical_remote_batch_runner(self) -> None:
        self.assertIn("service_remote.ps1", self.script)
        self.assertIn("-BatchPlanFile $batchPlan", self.script)
        self.assertIn("finally {", self.script)
        self.assertIn("Remove-Item -LiteralPath $batchPlan", self.script)

    def test_targets_are_variable_and_must_be_selected_paths(self) -> None:
        self.assertIn("[string]$EgressPaths", self.script)
        self.assertIn("[string]$TargetAliases", self.script)
        self.assertIn("$unknownTargets", self.script)
        self.assertIn("TargetAliases must be a subset of EgressPaths", self.script)

    def test_real_workflow_orders_transport_publication_before_source_acceptance(self) -> None:
        target = self.script.index("Preflight target platform_router transport servers")
        edge = self.script.index("Preflight target edge_haproxy SNI publication")
        source = self.script.index("Preflight source platform_router clients")
        geo = self.script.index("Run mutation-free GeoPolicy acceptance")
        self.assertLess(target, edge)
        self.assertLess(edge, source)
        self.assertLess(source, geo)

    def test_geo_policy_is_check_only(self) -> None:
        self.assertIn("Add-Step 'geo_policy' 'apply' $SourceAlias $true", self.script)
        self.assertNotIn("Add-Step 'geo_policy' 'apply' $SourceAlias $false", self.script)


if __name__ == "__main__":
    unittest.main()
