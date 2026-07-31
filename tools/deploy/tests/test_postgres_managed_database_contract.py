from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
POSTGRES_RUNTIME_TASKS = (
    ROOT / "infra" / "ansible" / "roles" / "postgres_runtime" / "tasks" / "main.yml"
)


class PostgresManagedDatabaseContractTests(unittest.TestCase):
    def test_product_database_may_have_no_extensions(self) -> None:
        tasks = POSTGRES_RUNTIME_TASKS.read_text(encoding="utf-8")

        self.assertIn(
            'if not isinstance(extensions, list):\n'
            '            fail(f"{path}.extensions must be a list")',
            tasks,
        )
        self.assertNotIn("extensions must be a non-empty list", tasks)

    def test_configured_extensions_remain_constrained_by_image_contract(self) -> None:
        tasks = POSTGRES_RUNTIME_TASKS.read_text(encoding="utf-8")

        self.assertIn("if extension not in normalized_extensions:", tasks)
        self.assertIn(
            "postgres_runtime image contract does not declare it",
            tasks,
        )


if __name__ == "__main__":
    unittest.main()
