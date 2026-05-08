import sys
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import klms_sync  # noqa: E402


class NoticeFilterTests(unittest.TestCase):
    def test_notice_digest_filters_ignored_and_marks_important_candidates(self) -> None:
        board_state = {
            "boards": {
                "board": {
                    "course": "Example Course",
                    "title": "Notice",
                    "articles": {
                        "1": {
                            "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=1",
                            "title": "시험 안내",
                            "summary": "중간고사 범위 안내",
                            "order": "1",
                        },
                        "2": {
                            "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2",
                            "title": "설문 안내",
                            "summary": "강의 설문",
                            "order": "2",
                        },
                    },
                }
            }
        }

        _state, digest = klms_sync.build_notice_digest(
            board_state,
            [],
            {},
            [],
            {
                "ignored_courses": [],
                "ignored_keywords": ["설문"],
                "important_keywords": ["시험"],
            },
            False,
        )

        self.assertEqual(digest["notice_count"], 1)
        self.assertEqual(digest["ignored_notice_count"], 1)
        self.assertEqual(digest["important_candidate_count"], 1)
        self.assertIn("bwid=1", digest["important_candidate_urls"][0])


if __name__ == "__main__":
    unittest.main()
