from __future__ import annotations

from pathlib import Path
import stat
import unittest
from unittest.mock import MagicMock

from tools.site_runtime.atomic_config import (
    AtomicConfigError,
    CANDIDATE_MODE,
    inspect_payload,
    inspect_regular_file,
    normalize_terminal_lf,
)


class AtomicConfigTests(unittest.TestCase):
    def test_adds_missing_terminal_lf(self) -> None:
        normalized = normalize_terminal_lf(b"frontend https\n  bind :443")
        self.assertEqual(normalized, b"frontend https\n  bind :443\n")
        self.assertEqual(set(inspect_payload(normalized)), {"sha256", "size"})

    def test_normalizes_crlf_and_terminal_lf_count(self) -> None:
        self.assertEqual(
            normalize_terminal_lf(b"frontend https\r\n  bind :443\r\n\r\n"),
            b"frontend https\n  bind :443\n",
        )

    def test_removes_multiple_terminal_lf(self) -> None:
        self.assertEqual(normalize_terminal_lf(b"frontend https\n\n\n"), b"frontend https\n")

    def test_rejects_literal_backslash_n_suffix(self) -> None:
        with self.assertRaisesRegex(AtomicConfigError, "literal backslash-n"):
            normalize_terminal_lf(b"frontend https\\n")
        with self.assertRaisesRegex(AtomicConfigError, "literal backslash-n"):
            inspect_payload(b"frontend https\\n\n")

    def test_ready_candidate_requires_mode_0644(self) -> None:
        candidate = MagicMock(spec=Path)
        candidate.lstat.return_value.st_mode = stat.S_IFREG | CANDIDATE_MODE
        candidate.read_bytes.return_value = b"frontend https\n"

        metadata = inspect_regular_file(candidate, 0o644)

        self.assertEqual(CANDIDATE_MODE, 0o644)
        self.assertEqual(set(metadata), {"sha256", "size"})

    def test_rejects_candidate_with_private_mode_after_write(self) -> None:
        candidate = MagicMock(spec=Path)
        candidate.lstat.return_value.st_mode = stat.S_IFREG | 0o600

        with self.assertRaisesRegex(AtomicConfigError, "expected 0644"):
            inspect_regular_file(candidate, CANDIDATE_MODE)

if __name__ == "__main__":
    unittest.main()
