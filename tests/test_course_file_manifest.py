import json
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import build_course_file_manifest  # noqa: E402
import klms_sync  # noqa: E402


class CourseFileManifestTests(unittest.TestCase):
    def test_resource_index_uses_course_id_mapping(self) -> None:
        course_page = {
            "requestedUrl": "https://klms.kaist.ac.kr/course/view.php?id=100001&section=0",
            "title": "강좌: Example Course",
            "html": """
            <html><body>
              <div role="main">
                <a href="https://klms.kaist.ac.kr/mod/resource/index.php?id=100001">강의 자료</a>
              </div>
            </body></html>
            """,
        }
        resource_index_page = {
            "requestedUrl": "https://klms.kaist.ac.kr/mod/resource/index.php?id=100001",
            "title": "EX.100_2026_1: 파일",
            "html": """
            <html><body>
              <nav>
                <a href="https://klms.kaist.ac.kr/course/view.php?id=100001">강의실 메인</a>
              </nav>
              <div role="main">
                <table class="generaltable mod_index"><tbody>
                  <tr>
                    <td>1주차</td>
                    <td>
                      <a href="view.php?id=200001">
                        <img class="icon" src="https://klms.kaist.ac.kr/theme/image.php/oklass39/core/1/f/pdf-24" />
                        Week 1 Notes
                      </a>
                    </td>
                    <td>2026년 3월 9일(월요일) 오후 2:29</td>
                  </tr>
                </tbody></table>
              </div>
            </body></html>
            """,
        }

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            course_pages_json = tmp_path / "course_pages.json"
            pages_json = tmp_path / "pages.json"
            course_pages_json.write_text(json.dumps([course_page]), encoding="utf-8")
            pages_json.write_text(json.dumps([resource_index_page]), encoding="utf-8")

            manifest, _state = build_course_file_manifest.build_manifest(
                course_pages_json=course_pages_json,
                page_sets=[pages_json],
                output_root=tmp_path / "course_files",
            )

        self.assertEqual(len(manifest), 1)
        self.assertEqual(manifest[0]["course"], "Example Course")
        self.assertEqual(manifest[0]["bucket"], "resources")
        self.assertEqual(manifest[0]["source_title"], "1주차")
        self.assertEqual(manifest[0]["section_title"], "1주차")
        self.assertEqual(manifest[0]["activity_title"], "Week 1 Notes")
        self.assertEqual(manifest[0]["filename"], "Week 1 Notes.pdf")
        self.assertEqual(
            manifest[0]["relative_path"],
            "Example Course/resources/1주차/Week 1 Notes.pdf",
        )

    def test_manifest_state_rebuilds_when_entry_style_changes(self) -> None:
        source_state = {
            "page_signature": "matching",
            "entries": [
                {
                    "course": "Example Course",
                    "bucket": "resources",
                    "filename": "wrong.pdf",
                    "relative_path": "Example Course/resources/강의 자료/wrong.pdf",
                    "url": "https://klms.kaist.ac.kr/mod/resource/view.php?id=200001",
                    "source_url": "https://klms.kaist.ac.kr/mod/resource/index.php?id=100001",
                    "source_title": "강의 자료",
                    "link_text": "Week 1 Notes",
                    "klms_timestamp": "",
                    "klms_timestamp_epoch": None,
                    "klms_timestamp_text": "",
                    "klms_timestamp_precision": "",
                    "klms_timestamp_label": "",
                    "klms_timestamp_source": "resource-index",
                    "klms_timestamp_basis": "klms_page",
                }
            ],
        }

        result = build_course_file_manifest.reusable_manifest_entries(
            source_state,
            "matching",
            {"Example Course": {"page_url": "https://klms.kaist.ac.kr/course/view.php?id=100001"}},
            Path("/tmp/course_files"),
        )

        self.assertIsNone(result)

    def test_file_scan_resolves_relative_resource_links(self) -> None:
        page = {
            "requestedUrl": "https://klms.kaist.ac.kr/mod/resource/index.php?id=100001",
            "title": "EX.100_2026_1: 파일",
            "html": """
            <html><body>
              <div role="main">
                <a href="view.php?id=200001">Week 1 Notes</a>
              </div>
            </body></html>
            """,
        }

        urls = klms_sync.collect_linked_html_urls([page], file_scan_only=True)

        self.assertEqual(
            urls,
            ["https://klms.kaist.ac.kr/mod/resource/view.php?id=200001"],
        )


if __name__ == "__main__":
    unittest.main()
