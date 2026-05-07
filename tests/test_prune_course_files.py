import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


class PruneCourseFilesTests(unittest.TestCase):
    def test_prune_removes_untracked_files_and_empty_dirs(self) -> None:
        script = PROJECT_DIR / "src" / "python" / "prune_course_files.py"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "archive"
            tracked_file = root / "Course" / "resources" / "Week Notes.pdf"
            stale_file = root / "Course" / "resources" / "강의 자료" / "Old.pdf"
            ds_store = root / ".DS_Store"
            tracked_file.parent.mkdir(parents=True)
            stale_file.parent.mkdir(parents=True)
            tracked_file.write_text("tracked", encoding="utf-8")
            stale_file.write_text("stale", encoding="utf-8")
            ds_store.write_text("finder", encoding="utf-8")

            manifest_path = tmp_path / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    [
                        {
                            "relative_path": "Course/resources/Week Notes.pdf",
                        }
                    ]
                ),
                encoding="utf-8",
            )

            dry_run = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--manifest-json",
                    str(manifest_path),
                    "--root",
                    str(root),
                    "--dry-run",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            dry_payload = json.loads(dry_run.stdout)
            self.assertEqual(dry_payload["deleted_file_count"], 2)
            self.assertTrue(stale_file.exists())
            self.assertTrue(ds_store.exists())

            applied = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--manifest-json",
                    str(manifest_path),
                    "--root",
                    str(root),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            applied_payload = json.loads(applied.stdout)

            self.assertEqual(applied_payload["actual_files_after"], 1)
            self.assertTrue(tracked_file.exists())
            self.assertFalse(stale_file.exists())
            self.assertFalse(ds_store.exists())
            self.assertFalse(stale_file.parent.exists())


if __name__ == "__main__":
    unittest.main()
