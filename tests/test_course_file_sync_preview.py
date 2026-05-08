import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import build_course_file_sync_preview  # noqa: E402


class CourseFileSyncPreviewTests(unittest.TestCase):
    def test_preview_reports_fresh_prune_and_type_mismatch_candidates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output_root = root / "course_files"
            archive_root = root / "archive"
            output_root.mkdir()
            (output_root / "Course").mkdir()
            (output_root / "Course" / "old.pdf").write_text("old", encoding="utf-8")

            manifest = [
                {
                    "course": "Course",
                    "filename": "new.pdf",
                    "relative_path": "Course/new.pdf",
                    "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=1",
                },
                {
                    "course": "Course",
                    "filename": "slides.pptx",
                    "relative_path": "Course/slides.pptx",
                    "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=2",
                },
            ]
            previous_log = {
                "results": [
                    {
                        "filename": "slides.pdf",
                        "relative_path": "Course/slides.pdf",
                        "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=2",
                    }
                ]
            }
            manifest_path = root / "manifest.json"
            log_path = root / "download_log.json"
            preview_path = root / "preview.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            log_path.write_text(json.dumps(previous_log), encoding="utf-8")

            with redirect_stdout(StringIO()):
                rc = build_course_file_sync_preview.main_with_args(
                    [
                        "--manifest-json",
                        str(manifest_path),
                        "--output-root",
                        str(output_root),
                        "--download-log-json",
                        str(log_path),
                        "--download-archive-root",
                        str(archive_root),
                        "--output-json",
                        str(preview_path),
                    ]
                )

            payload = json.loads(preview_path.read_text(encoding="utf-8"))

        self.assertEqual(rc, 0)
        self.assertEqual(payload["new_url_count"], 1)
        self.assertEqual(payload["fresh_download_candidate_count"], 2)
        self.assertEqual(payload["prune_candidate_count"], 1)
        self.assertEqual(payload["type_mismatch_candidate_count"], 1)
        self.assertIn("Course/slides.pptx", payload["tracked_relative_paths"])

    def test_preview_reuses_previous_weekly_layout_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output_root = root / "course_files"
            archive_root = root / "archive"
            old_output_path = output_root / "Course" / "resources" / "1주차" / "Week Notes.pdf"
            old_archive_path = archive_root / "Course" / "resources" / "2주차" / "Lab.pdf"
            old_output_path.parent.mkdir(parents=True)
            old_archive_path.parent.mkdir(parents=True)
            old_output_path.write_text("old output", encoding="utf-8")
            old_archive_path.write_text("old archive", encoding="utf-8")

            manifest = [
                {
                    "course": "Course",
                    "filename": "Week Notes.pdf",
                    "relative_path": "Course/resources/Week Notes.pdf",
                    "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=1",
                },
                {
                    "course": "Course",
                    "filename": "Lab.pdf",
                    "relative_path": "Course/resources/Lab.pdf",
                    "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=2",
                },
            ]
            previous_log = {
                "results": [
                    {
                        "filename": "Week Notes.pdf",
                        "relative_path": "Course/resources/1주차/Week Notes.pdf",
                        "downloads_relative_path": "Course/resources/1주차/Week Notes.pdf",
                        "manifest_relative_path": "Course/resources/1주차/Week Notes.pdf",
                        "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=1",
                    },
                    {
                        "filename": "Lab.pdf",
                        "relative_path": "Course/resources/2주차/Lab.pdf",
                        "downloads_relative_path": "Course/resources/2주차/Lab.pdf",
                        "manifest_relative_path": "Course/resources/2주차/Lab.pdf",
                        "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=2",
                    },
                ]
            }
            manifest_path = root / "manifest.json"
            log_path = root / "download_log.json"
            preview_path = root / "preview.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            log_path.write_text(json.dumps(previous_log), encoding="utf-8")

            with redirect_stdout(StringIO()):
                rc = build_course_file_sync_preview.main_with_args(
                    [
                        "--manifest-json",
                        str(manifest_path),
                        "--output-root",
                        str(output_root),
                        "--download-log-json",
                        str(log_path),
                        "--download-archive-root",
                        str(archive_root),
                        "--output-json",
                        str(preview_path),
                    ]
                )

            payload = json.loads(preview_path.read_text(encoding="utf-8"))

        self.assertEqual(rc, 0)
        self.assertEqual(payload["new_url_count"], 0)
        self.assertEqual(payload["moved_count"], 2)
        self.assertEqual(payload["fresh_download_candidate_count"], 0)
        self.assertEqual(payload["prune_candidate_count"], 1)
        self.assertIn("Course/resources/Week Notes.pdf", payload["tracked_relative_paths"])


if __name__ == "__main__":
    unittest.main()
