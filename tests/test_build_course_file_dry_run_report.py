import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class BuildCourseFileDryRunReportTests(unittest.TestCase):
    def test_would_download_uses_fresh_preview_candidates_not_manifest_total(self) -> None:
        script = PROJECT_DIR / "src" / "python" / "build_course_file_dry_run_report.py"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            preview_path = tmp_path / "preview.json"
            prune_path = tmp_path / "prune.json"
            archive_prune_path = tmp_path / "archive-prune.json"
            output_path = tmp_path / "dry-run-report.json"

            preview_path.write_text(
                json.dumps(
                    {
                        "manifest_count": 68,
                        "fresh_download_candidate_count": 0,
                        "moved_count": 1,
                        "type_mismatch_candidate_count": 2,
                    }
                ),
                encoding="utf-8",
            )
            prune_path.write_text(
                json.dumps(
                    {
                        "deleted_file_count": 52,
                        "backup_manifest_path": str(tmp_path / "course-backup.json"),
                    }
                ),
                encoding="utf-8",
            )
            archive_prune_path.write_text(
                json.dumps(
                    {
                        "deleted_file_count": 52,
                        "backup_manifest_path": str(tmp_path / "archive-backup.json"),
                    }
                ),
                encoding="utf-8",
            )

            subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--preview-json",
                    str(preview_path),
                    "--prune-result-json",
                    str(prune_path),
                    "--archive-prune-result-json",
                    str(archive_prune_path),
                    "--output-json",
                    str(output_path),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            payload = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(payload["would_download"], 0)
            self.assertEqual(payload["would_update"], 3)
            self.assertEqual(payload["would_delete"], 104)
            self.assertEqual(payload["would_prune"], 104)
            self.assertEqual(payload["would_prune_course_files"], 52)
            self.assertEqual(payload["would_prune_archive"], 52)


if __name__ == "__main__":
    unittest.main()
