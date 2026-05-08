import sys
import unittest
from datetime import datetime
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import klms_sync  # noqa: E402


class CalendarExamFieldTests(unittest.TestCase):
    def test_class_time_override_fills_date_only_exam_time(self) -> None:
        lookup = klms_sync.merge_class_time_lookups(
            {
                "Example Course": [
                    klms_sync.ClassTimeRange(
                        weekday=2,
                        start_hour=10,
                        start_minute=30,
                        end_hour=12,
                        end_minute=0,
                        source="override",
                    )
                ]
            }
        )
        items = [
            {
                "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2",
                "type": "exam",
                "category": "exam",
                "course": "Example Course",
                "title": "중간고사",
                "due": "2026년 4월 8일",
                "instructions": "",
                "timing_precision": "date",
                "time_source": "date_only",
                "sort_due": datetime(2026, 4, 8, 9, 0, tzinfo=klms_sync.SEOUL),
                "sync_due": "2026-04-08T09:00:00+09:00",
            }
        ]

        updated = klms_sync.apply_exam_class_time_fallback(items, lookup)

        self.assertEqual(updated[0]["timing_precision"], "class-time")
        self.assertEqual(updated[0]["time_source"], "class_time")
        self.assertEqual(updated[0]["sync_start"], "2026-04-08T10:30:00+09:00")
        self.assertEqual(updated[0]["sync_due"], "2026-04-08T12:00:00+09:00")
        self.assertIn("오전 10:30 - 오후 12:00", updated[0]["due"])

    def test_class_time_override_string_is_parsed(self) -> None:
        lookup = klms_sync.normalize_class_time_overrides(
            {"Example Course": "수요일 10:30-12:00"}
        )

        self.assertEqual(len(lookup["Example Course"]), 1)
        self.assertEqual(lookup["Example Course"][0].weekday, 2)
        self.assertEqual(lookup["Example Course"][0].start_hour, 10)
        self.assertEqual(lookup["Example Course"][0].end_hour, 12)

    def test_exam_location_and_coverage_are_serialized(self) -> None:
        item = {
            "url": "https://klms.kaist.ac.kr/mod/courseboard/article.php?id=1&bwid=2",
            "type": "exam",
            "category": "exam",
            "course": "Example Course",
            "title": "Midterm",
            "due": "2026년 4월 8일(수요일) 오전 10:30 - 오후 12:00",
            "submission": "",
            "instructions": "Place: E3-5 Room 210 Range: Week 1-7",
            "timing_precision": "time-range",
            "time_source": "notice",
            "sync_start": "2026-04-08T10:30:00+09:00",
            "sync_due": "2026-04-08T12:00:00+09:00",
            "source_title": "Midterm notice",
            "location": "E3-5 Room 210",
            "coverage": "Week 1-7",
            "coverage_summary": "Week 1-7",
        }

        serialized = klms_sync.serialize_sync_item(item)

        self.assertEqual(serialized["location"], "E3-5 Room 210")
        self.assertEqual(serialized["coverage"], "Week 1-7")
        self.assertEqual(serialized["coverage_summary"], "Week 1-7")
        self.assertEqual(serialized["time_source"], "notice")

    def test_short_exam_coverage_summary_stays_inline(self) -> None:
        summary = klms_sync.summarize_exam_coverage_for_calendar(
            "Week 1-7 lectures / WA 1-2 / PA 1-2"
        )

        self.assertEqual(summary, "Week 1-7 lectures / WA 1-2 / PA 1-2")

    def test_long_exam_coverage_summary_is_structured(self) -> None:
        summary = klms_sync.summarize_exam_coverage_for_calendar(
            "Lectures: Week 1-7; Assignments: WA 1-2, PA 1-2; "
            "Readings: CLRS 15.2-15.5; Excluding: Week 8 이후"
        )

        self.assertEqual(
            summary,
            "\n".join(
                [
                    "- 강의: Week 1-7",
                    "- 과제: WA 1-2, PA 1-2",
                    "- 읽기자료: CLRS 15.2-15.5",
                    "- 제외: Week 8 이후",
                ]
            ),
        )

    def test_ambiguous_exam_coverage_requires_source_check(self) -> None:
        summary = klms_sync.summarize_exam_coverage_for_calendar("추후 공지 예정")

        self.assertEqual(summary, "확인 필요 - 원문 참고")

    def test_calendar_notes_do_not_repeat_location_line(self) -> None:
        for relative_path in (
            "src/swift/sync_klms_calendar_suite.swift",
            "src/swift/sync_klms_calendar.swift",
            "src/js/sync_klms_calendar_jxa.js",
        ):
            source = (PROJECT_DIR / relative_path).read_text(encoding="utf-8")
            self.assertNotIn("위치:", source)

    def test_calendar_sources_use_coverage_summary(self) -> None:
        for relative_path in (
            "src/swift/sync_klms_calendar_suite.swift",
            "src/swift/sync_klms_calendar.swift",
            "src/js/sync_klms_calendar_jxa.js",
        ):
            source = (PROJECT_DIR / relative_path).read_text(encoding="utf-8")
            self.assertIn("coverage_summary", source)

    def test_calendar_suite_existing_event_lookup_is_not_nested(self) -> None:
        source = (PROJECT_DIR / "src" / "swift" / "sync_klms_calendar_suite.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn("    let existingEvents = managedEvents(", source)
        self.assertNotIn("        let existingEvents = managedEvents(", source)


if __name__ == "__main__":
    unittest.main()
