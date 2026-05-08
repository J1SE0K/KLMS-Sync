import sys
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import sync_report  # noqa: E402


class SyncReportTests(unittest.TestCase):
    def test_combined_slowest_stages_are_sorted_across_scopes(self) -> None:
        stages = sync_report.combined_slowest_stages(
            {"slowest_stages": [{"name": "core", "duration_ms": 1000}]},
            {"slowest_stages": [{"name": "notice", "duration_ms": 3000}]},
            {"slowest_stages": [{"name": "files", "duration_ms": 5000}]},
        )

        self.assertEqual([item["name"] for item in stages], ["files", "notice", "core"])


if __name__ == "__main__":
    unittest.main()
