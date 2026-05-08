#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from html import escape
from pathlib import Path
from typing import Any
from urllib.parse import parse_qsl, urlencode, urljoin, urlparse, urlunparse

from bs4 import BeautifulSoup
from klms_transport import page_fingerprint

MARKER = "[[KLMS 자동 동기화]]"
SEOUL = timezone(timedelta(hours=9))
SUPPLEMENTAL_MODULES = {"courseboard", "folder", "resource", "page", "book", "url"}
PRIMARY_BOARD_KEYWORDS = ("notice", "공지", "announcement")
EXAM_KEYWORDS = ("midterm", "final", "exam", "시험", "중간", "기말")
HELP_DESK_KEYWORDS = ("help desk", "helpdesk", "헬프데스크")
EXAM_TITLE_KEYWORDS = ("midterm", "final", "exam", "중간", "기말", "시험")
CLASS_TIME_KEYWORDS = (
    "수업시간",
    "수업 시간",
    "강의시간",
    "강의 시간",
    "강의일시",
    "강의 일시",
    "class time",
    "lecture time",
    "meeting time",
)
WEEKDAY_TOKEN_PATTERN = (
    r"월(?:요일)?|화(?:요일)?|수(?:요일)?|목(?:요일)?|금(?:요일)?|토(?:요일)?|일(?:요일)?|"
    r"Mon(?:day)?|Tue(?:sday)?|Wed(?:nesday)?|Thu(?:rsday)?|Thur(?:sday)?|"
    r"Fri(?:day)?|Sat(?:urday)?|Sun(?:day)?"
)
EXAM_FALSE_POSITIVE_SOURCE_KEYWORDS = (
    "nano quiz",
    "quiz",
    "homework",
    "assignment",
    "숙제",
    "과제",
    "grading",
    "solution",
    "solutions",
    "score",
    "scores",
    "채점",
    "점수",
    "해설",
)
ASSIGNMENT_CANDIDATE_KEYWORDS = (
    "assignment",
    "homework",
    "project",
    "과제",
    "숙제",
    "프로젝트",
    "hw",
    "pa",
    "wa",
)
ASSIGNMENT_CANDIDATE_CONTEXT_KEYWORDS = (
    "release",
    "released",
    "posted",
    "deadline",
    "due",
    "submit by",
    "submission deadline",
    "마감",
    "제출",
    "업로드",
    "게시",
    "출제",
)
ASSIGNMENT_CANDIDATE_IGNORE_KEYWORDS = (
    "grading",
    "graded",
    "score",
    "scores",
    "solution",
    "solutions",
    "feedback",
    "claim",
    "appeal",
    "채점",
    "점수",
    "해설",
    "정답",
    "클레임",
)
NON_ASSIGNMENT_SCHEDULE_MODULES = {"url", "resource", "vod", "page", "book"}
NON_ASSIGNMENT_SCHEDULE_KEYWORDS = (
    "lecture video",
    "no lecture video",
    "will be recorded",
    "recorded and uploaded",
    "uploaded by",
    "to be uploaded",
    "available by",
)
COMPLETED_ASSIGNMENT_SUBMISSION_STATUSES = {
    "채점을 위해 제출되었습니다",
    "submitted for grading",
}
INFO_KEYWORDS = EXAM_KEYWORDS + (
    "syllabus",
    "course outline",
    "course schedule",
    "강의계획",
    "강의 계획",
    "계획서",
)
SUPPLEMENTAL_DETAIL_KEYWORDS = INFO_KEYWORDS + HELP_DESK_KEYWORDS
DOCUMENT_EXTENSIONS = (".pdf", ".doc", ".docx", ".hwp", ".hwpx")
IGNORED_COURSE_NAMES = ("기출문제은행", "조교 과정", "조교")
EXACT_IGNORED_COURSE_NAMES = {"klms"}
IGNORED_COURSE_IDS = {"147806", "178264"}
FILE_SEED_MODULE_PRIORITIES = {
    "courseboard": 1,
    "folder": 2,
    "resource": 2,
    "page": 2,
    "book": 2,
    "assign": 3,
    "quiz": 4,
    "url": 6,
    "lti": 7,
    "vod": 8,
}
LINKED_HTML_MODULE_PRIORITIES = {
    "courseboard": 0,
    "folder": 1,
    "resource": 1,
    "page": 1,
    "book": 1,
    "assign": 2,
    "quiz": 3,
    "url": 5,
    "lti": 6,
    "vod": 7,
}
FILE_SCAN_NESTED_ALLOWED_MODULES = {"courseboard", "folder", "resource", "assign", "page", "book"}
BOARD_ARTICLE_STATE_LIMIT = 40


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    course_urls_parser = subparsers.add_parser("list-course-urls")
    course_urls_parser.add_argument("--dashboard-json", required=True)
    course_urls_parser.set_defaults(func=cmd_list_course_urls)

    detail_urls_parser = subparsers.add_parser("list-detail-urls")
    detail_urls_parser.add_argument("--dashboard-json", required=True)
    detail_urls_parser.add_argument("--course-pages-json")
    detail_urls_parser.set_defaults(func=cmd_list_detail_urls)

    supplemental_urls_parser = subparsers.add_parser("list-supplemental-urls")
    supplemental_urls_parser.add_argument("--course-pages-json", required=True)
    supplemental_urls_parser.add_argument(
        "--tier", choices=("all", "primary", "secondary"), default="all"
    )
    supplemental_urls_parser.set_defaults(func=cmd_list_supplemental_urls)

    supplemental_detail_urls_parser = subparsers.add_parser("list-supplemental-detail-urls")
    supplemental_detail_urls_parser.add_argument("--supplemental-pages-json", required=True)
    supplemental_detail_urls_parser.add_argument("--board-article-state-json")
    supplemental_detail_urls_parser.add_argument("--existing-detail-pages-json")
    supplemental_detail_urls_parser.add_argument("--output-board-article-state-json")
    supplemental_detail_urls_parser.add_argument(
        "--include-non-relevant-primary",
        action="store_true",
    )
    supplemental_detail_urls_parser.set_defaults(func=cmd_list_supplemental_detail_urls)

    notice_article_urls_parser = subparsers.add_parser("list-notice-article-urls")
    notice_article_urls_parser.add_argument("--supplemental-primary-pages-json", required=True)
    notice_article_urls_parser.add_argument("--course-pages-json")
    notice_article_urls_parser.add_argument("--notice-board-state-json")
    notice_article_urls_parser.add_argument("--notice-summary-state-json")
    notice_article_urls_parser.add_argument("--output-notice-board-state-json")
    notice_article_urls_parser.set_defaults(func=cmd_list_notice_article_urls)

    notice_board_page_urls_parser = subparsers.add_parser("list-notice-board-page-urls")
    notice_board_page_urls_parser.add_argument("--supplemental-primary-pages-json", required=True)
    notice_board_page_urls_parser.set_defaults(func=cmd_list_notice_board_page_urls)

    notice_digest_parser = subparsers.add_parser("build-notice-digest")
    notice_digest_parser.add_argument("--notice-board-state-json", required=True)
    notice_digest_parser.add_argument("--notice-article-pages-json")
    notice_digest_parser.add_argument("--notice-summary-state-json")
    notice_digest_parser.add_argument("--course-file-manifest-json")
    notice_digest_parser.add_argument("--overrides-json")
    notice_digest_parser.add_argument("--auto-important-keywords-apply", action="store_true")
    notice_digest_parser.add_argument("--output-notice-summary-state-json", required=True)
    notice_digest_parser.add_argument("--output-notice-digest-json", required=True)
    notice_digest_parser.set_defaults(func=cmd_build_notice_digest)

    file_seed_urls_parser = subparsers.add_parser("list-file-seed-urls")
    file_seed_urls_parser.add_argument("--course-pages-json", required=True)
    file_seed_urls_parser.set_defaults(func=cmd_list_file_seed_urls)

    linked_html_urls_parser = subparsers.add_parser("list-linked-html-urls")
    linked_html_urls_parser.add_argument("--pages-json", required=True)
    linked_html_urls_parser.add_argument("--file-scan", action="store_true")
    linked_html_urls_parser.add_argument("--source-requested-url-file")
    linked_html_urls_parser.set_defaults(func=cmd_list_linked_html_urls)

    linked_html_index_parser = subparsers.add_parser("build-linked-html-index")
    linked_html_index_parser.add_argument("--pages-json", required=True)
    linked_html_index_parser.add_argument("--existing-index-json")
    linked_html_index_parser.add_argument("--changed-requested-url-file")
    linked_html_index_parser.add_argument("--output-index-json", required=True)
    linked_html_index_parser.add_argument("--output-urls-txt", required=True)
    linked_html_index_parser.add_argument("--file-scan", action="store_true")
    linked_html_index_parser.set_defaults(func=cmd_build_linked_html_index)

    login_status_parser = subparsers.add_parser("check-login-status")
    login_status_parser.add_argument("--pages-json", required=True)
    login_status_parser.set_defaults(func=cmd_check_login_status)

    build_parser_cmd = subparsers.add_parser("build-note")
    build_parser_cmd.add_argument("--dashboard-json", required=True)
    build_parser_cmd.add_argument("--course-pages-json")
    build_parser_cmd.add_argument("--details-json", required=True)
    build_parser_cmd.add_argument("--supplemental-pages-json")
    build_parser_cmd.add_argument("--supplemental-detail-pages-json")
    build_parser_cmd.add_argument("--notice-digest-json")
    build_parser_cmd.add_argument("--overrides-json")
    build_parser_cmd.add_argument("--state-json", required=True)
    build_parser_cmd.add_argument("--output-html", required=True)
    build_parser_cmd.add_argument("--output-state", required=True)
    build_parser_cmd.add_argument("--output-status", required=True)
    build_parser_cmd.set_defaults(func=cmd_build_note)

    return parser


def cmd_list_course_urls(args: argparse.Namespace) -> None:
    page = load_single_page(Path(args.dashboard_json))
    course_urls = parse_course_urls_from_dashboard(page)
    for url in course_urls:
        print(url)


def cmd_list_detail_urls(args: argparse.Namespace) -> None:
    page = load_single_page(Path(args.dashboard_json))
    course_pages = load_pages(Path(args.course_pages_json)) if args.course_pages_json else []
    dashboard = parse_dashboard_page(page)
    for item in collect_candidate_items(dashboard, course_pages):
        print(item.url)


def cmd_list_supplemental_urls(args: argparse.Namespace) -> None:
    course_pages = load_pages(Path(args.course_pages_json))
    for url in collect_supplemental_urls(course_pages, args.tier):
        print(url)


def cmd_list_supplemental_detail_urls(args: argparse.Namespace) -> None:
    supplemental_pages = load_pages(Path(args.supplemental_pages_json))
    board_article_state = (
        load_optional_json(Path(args.board_article_state_json))
        if args.board_article_state_json
        else {}
    )
    existing_detail_pages = (
        load_pages(Path(args.existing_detail_pages_json))
        if args.existing_detail_pages_json and Path(args.existing_detail_pages_json).exists()
        else []
    )
    urls, next_board_article_state = collect_supplemental_detail_urls(
        supplemental_pages,
        board_article_state,
        existing_detail_pages=existing_detail_pages,
        include_non_relevant_primary=args.include_non_relevant_primary,
    )
    if args.output_board_article_state_json:
        write_json(Path(args.output_board_article_state_json), next_board_article_state)
    for url in urls:
        print(url)


def cmd_list_notice_article_urls(args: argparse.Namespace) -> None:
    supplemental_primary_pages = load_pages(Path(args.supplemental_primary_pages_json))
    course_pages = load_pages(Path(args.course_pages_json)) if args.course_pages_json else []
    notice_board_state = (
        load_optional_json(Path(args.notice_board_state_json))
        if args.notice_board_state_json
        else {}
    )
    notice_summary_state = (
        load_optional_json(Path(args.notice_summary_state_json))
        if args.notice_summary_state_json
        else {}
    )
    urls, next_notice_board_state = collect_notice_article_urls(
        supplemental_primary_pages,
        notice_board_state,
        notice_summary_state,
        build_activity_course_lookup(course_pages),
    )
    if args.output_notice_board_state_json:
        write_json(Path(args.output_notice_board_state_json), next_notice_board_state)
    for url in urls:
        print(url)


def cmd_list_notice_board_page_urls(args: argparse.Namespace) -> None:
    supplemental_primary_pages = load_pages(Path(args.supplemental_primary_pages_json))
    for url in collect_notice_board_page_urls(supplemental_primary_pages):
        print(url)


def cmd_build_notice_digest(args: argparse.Namespace) -> None:
    notice_board_state = load_optional_json(Path(args.notice_board_state_json))
    notice_article_pages = (
        load_pages(Path(args.notice_article_pages_json))
        if args.notice_article_pages_json and Path(args.notice_article_pages_json).exists()
        else []
    )
    previous_notice_summary_state = (
        load_optional_json(Path(args.notice_summary_state_json))
        if args.notice_summary_state_json
        else {}
    )
    course_file_manifest = (
        load_optional_json(Path(args.course_file_manifest_json))
        if args.course_file_manifest_json and Path(args.course_file_manifest_json).exists()
        else []
    )
    override_document = load_override_document(Path(args.overrides_json)) if args.overrides_json else {
        "notice_filters": {}
    }
    next_notice_summary_state, notice_digest_json = build_notice_digest(
        notice_board_state,
        notice_article_pages,
        previous_notice_summary_state,
        course_file_manifest,
        override_document.get("notice_filters", {}),
        args.auto_important_keywords_apply,
    )
    write_json(Path(args.output_notice_summary_state_json), next_notice_summary_state)
    write_json(Path(args.output_notice_digest_json), notice_digest_json)


def cmd_list_file_seed_urls(args: argparse.Namespace) -> None:
    course_pages = load_pages(Path(args.course_pages_json))
    for url in collect_file_seed_urls(course_pages):
        print(url)


def cmd_list_linked_html_urls(args: argparse.Namespace) -> None:
    pages = load_pages(Path(args.pages_json))
    source_requested_urls = (
        load_requested_url_set(Path(args.source_requested_url_file))
        if args.source_requested_url_file
        else None
    )
    for url in collect_linked_html_urls(
        pages,
        file_scan_only=args.file_scan,
        source_requested_urls=source_requested_urls,
    ):
        print(url)


def cmd_check_login_status(args: argparse.Namespace) -> None:
    pages = load_pages(Path(args.pages_json))
    print(json.dumps(analyze_login_status(pages), ensure_ascii=False, separators=(",", ":")))


def cmd_build_linked_html_index(args: argparse.Namespace) -> None:
    pages = load_pages(Path(args.pages_json))
    existing_index = (
        load_optional_json(Path(args.existing_index_json))
        if args.existing_index_json
        else {}
    )
    changed_requested_urls = (
        load_requested_url_set(Path(args.changed_requested_url_file))
        if args.changed_requested_url_file
        else None
    )
    urls, next_index = build_linked_html_index(
        pages,
        existing_index=existing_index,
        changed_requested_urls=changed_requested_urls,
        file_scan_only=args.file_scan,
    )
    write_json(Path(args.output_index_json), next_index)
    write_text(Path(args.output_urls_txt), "\n".join(urls) + ("\n" if urls else ""))


def cmd_build_note(args: argparse.Namespace) -> None:
    dashboard_page = load_single_page(Path(args.dashboard_json))
    course_pages = load_pages(Path(args.course_pages_json)) if args.course_pages_json else []
    detail_pages = load_pages(Path(args.details_json))
    supplemental_pages = (
        load_pages(Path(args.supplemental_pages_json)) if args.supplemental_pages_json else []
    )
    supplemental_detail_pages = (
        load_pages(Path(args.supplemental_detail_pages_json))
        if args.supplemental_detail_pages_json
        else []
    )
    override_document = load_override_document(Path(args.overrides_json)) if args.overrides_json else {
        "assignments": {},
        "exams": {},
        "class_times": {},
    }
    overrides = override_document["assignments"]
    exam_overrides = override_document["exams"]
    class_time_overrides = override_document.get("class_times", {})
    previous_state = load_optional_json(Path(args.state_json))
    notice_digest = (
        load_optional_json(Path(args.notice_digest_json)) if args.notice_digest_json else {}
    )

    dashboard = parse_dashboard_page(dashboard_page)
    detail_lookup = {page["requestedUrl"]: parse_detail_page(page) for page in detail_pages}

    if dashboard.status != "ok":
        payload = build_error_payload(dashboard.error_message, previous_state)
    elif any(looks_like_login_page(page) for page in course_pages):
        payload = build_error_payload(
            "과목 페이지를 읽는 중 KLMS 로그인 세션이 풀렸어. 다시 로그인해 줘.",
            previous_state,
        )
    elif any(detail.get("status") == "error" for detail in detail_lookup.values()):
        payload = build_error_payload(
            "과제 상세 페이지를 읽는 중 KLMS 로그인 세션이 풀렸어. 다시 로그인해 줘.",
            previous_state,
        )
    elif any(looks_like_login_page(page) for page in supplemental_pages + supplemental_detail_pages):
        payload = build_error_payload(
            "시험/강의계획 정보를 읽는 중 KLMS 로그인 세션이 풀렸어. 다시 로그인해 줘.",
            previous_state,
        )
    else:
        assignments = []
        direct_exam_items = []
        for item in collect_candidate_items(dashboard, course_pages):
            detail = detail_lookup.get(item.url)
            assignment = merge_assignment(item, detail)
            if is_hidden_by_override(assignment, overrides):
                continue
            if assignment_should_be_exam_item(assignment):
                direct_exam_items.append(assignment_to_exam_item(assignment))
                continue
            if is_completed_assignment(assignment):
                continue
            assignments.append(assignment)

        supplemental_sources = supplemental_detail_pages + supplemental_pages
        notice_digest_pages = build_notice_digest_candidate_pages(notice_digest)
        course_lookup = build_activity_course_lookup(course_pages)
        class_time_lookup = merge_class_time_lookups(
            build_course_class_time_lookup(course_pages + supplemental_sources + notice_digest_pages),
            class_time_overrides,
        )
        resolved_exam_items = apply_exam_overrides(
            apply_exam_class_time_fallback(
                extract_exam_items(
                    supplemental_sources,
                    course_lookup,
                ),
                class_time_lookup,
            ),
            exam_overrides,
        )
        resolved_direct_exam_items = apply_exam_overrides(
            apply_exam_class_time_fallback(direct_exam_items, class_time_lookup),
            exam_overrides,
            default_status="approved",
        )
        assignment_candidates = extract_assignment_candidate_items(
            supplemental_sources + notice_digest_pages,
            assignments,
            course_lookup,
        )
        notice_assignments = [
            item
            for item in activate_notice_assignments(assignment_candidates)
            if not is_hidden_by_override(item, overrides)
        ]
        assignments.extend(notice_assignments)
        help_desk_items = extract_help_desk_items(supplemental_sources, course_lookup)
        approved_exam_items, exam_candidates = split_exam_items_for_confirmation(resolved_exam_items)
        direct_approved_exam_items, direct_exam_candidates = split_exam_items_for_confirmation(
            resolved_direct_exam_items
        )
        approved_exam_items = dedupe_sync_items(approved_exam_items + direct_approved_exam_items)
        exam_candidates = dedupe_sync_items(exam_candidates + direct_exam_candidates)
        payload = build_success_payload(
            assignments,
            approved_exam_items,
            exam_candidates,
            [],
            help_desk_items,
        )

    changed = payload.get("content") != previous_state.get("content")
    write_text(Path(args.output_html), payload["html"])
    write_json(Path(args.output_state), payload)
    write_json(
        Path(args.output_status),
        {
            "changed": changed,
            "status": payload["status"],
            "assignment_count": len(payload.get("content", {}).get("assignments", [])),
            "exam_count": len(payload.get("content", {}).get("exam_items", [])),
            "exam_candidate_count": len(payload.get("content", {}).get("exam_candidates", [])),
            "assignment_candidate_count": len(
                payload.get("content", {}).get("assignment_candidates", [])
            ),
            "help_desk_count": len(payload.get("content", {}).get("help_desk_items", [])),
        },
    )


def load_single_page(path: Path) -> dict[str, Any]:
    pages = load_pages(path)
    if len(pages) != 1:
        raise ValueError(f"Expected one page in {path}, found {len(pages)}")
    return pages[0]


def load_pages(path: Path) -> list[dict[str, Any]]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_optional_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def build_notice_digest_candidate_pages(notice_digest: dict[str, Any]) -> list[dict[str, Any]]:
    if not isinstance(notice_digest, dict):
        return []

    pages: list[dict[str, Any]] = []
    seen_urls: set[str] = set()
    for course_payload in notice_digest.get("courses", []):
        if not isinstance(course_payload, dict):
            continue
        course = normalize_whitespace(str(course_payload.get("course", "")))
        for notice in course_payload.get("notices", []):
            if not isinstance(notice, dict):
                continue
            raw_url = normalize_whitespace(str(notice.get("url", "")))
            url = canonicalize_crawl_url(raw_url)
            if not url or url in seen_urls:
                continue

            title = clean_title(normalize_whitespace(str(notice.get("title", ""))))
            body_text = normalize_whitespace(str(notice.get("body_text", "")))
            excerpt = normalize_whitespace(str(notice.get("excerpt", "")))
            summary = normalize_whitespace(str(notice.get("summary", "")))
            combined_text = "\n".join(
                value for value in (title, body_text or excerpt or summary) if value
            )
            if not combined_text:
                continue

            pages.append(
                {
                    "requestedUrl": url,
                    "url": url,
                    "title": title,
                    "course": course,
                    "text": combined_text,
                    "html": (
                        f"<html><body><h1>{escape(title)}</h1>"
                        f"<div class=\"courseboard content\">{escape(body_text or excerpt or summary)}</div>"
                        "</body></html>"
                    ),
                }
            )
            seen_urls.add(url)

    return pages


def load_override_document(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"assignments": {}, "exams": {}, "class_times": {}, "notice_filters": {}}

    payload = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(payload, dict):
        if isinstance(payload.get("assignments"), dict) or isinstance(payload.get("exams"), dict):
            return {
                "assignments": normalize_assignment_overrides(payload.get("assignments")),
                "exams": normalize_exam_overrides(payload.get("exams")),
                "class_times": normalize_class_time_overrides(payload.get("class_times")),
                "notice_filters": normalize_notice_filters(payload.get("notice_filters")),
            }
        return {
            "assignments": normalize_assignment_overrides(payload),
            "exams": {},
            "class_times": {},
            "notice_filters": {},
        }


def normalize_notice_filters(payload: Any) -> dict[str, list[str]]:
    if not isinstance(payload, dict):
        return {"ignored_courses": [], "ignored_keywords": [], "important_keywords": []}
    result: dict[str, list[str]] = {}
    for key in ("ignored_courses", "ignored_keywords", "important_keywords"):
        value = payload.get(key)
        if isinstance(value, list):
            result[key] = [str(item).strip() for item in value if str(item).strip()]
        elif isinstance(value, str) and value.strip():
            result[key] = [value.strip()]
        else:
            result[key] = []
    return result

    return {"assignments": {}, "exams": {}, "class_times": {}}


def normalize_assignment_overrides(payload: Any) -> dict[str, str]:
    if not isinstance(payload, dict):
        return {}

    return {
        str(key): str(value).strip().lower()
        for key, value in payload.items()
        if str(value).strip()
    }


def normalize_exam_overrides(payload: Any) -> dict[str, dict[str, str]]:
    if not isinstance(payload, dict):
        return {}

    normalized: dict[str, dict[str, str]] = {}
    for raw_key, raw_value in payload.items():
        key = str(raw_key).strip()
        if not key or not isinstance(raw_value, dict):
            continue

        item: dict[str, str] = {}
        for field in (
            "due",
            "timing_precision",
            "sync_start",
            "sync_due",
            "instructions_append",
            "status",
            "location",
            "coverage",
            "coverage_summary",
        ):
            value = raw_value.get(field)
            if value is None:
                continue
            text = str(value).strip()
            if text:
                item[field] = text

        if item:
            normalized[key] = item

    return normalized


def normalize_class_time_overrides(payload: Any) -> dict[str, list["ClassTimeRange"]]:
    if not isinstance(payload, dict):
        return {}

    normalized: dict[str, list[ClassTimeRange]] = {}
    for raw_course, raw_value in payload.items():
        course = normalize_whitespace(str(raw_course))
        if not course:
            continue

        ranges = class_time_ranges_from_override_value(raw_value)
        if ranges:
            normalized[course] = ranges

    return normalized


def class_time_ranges_from_override_value(value: Any) -> list["ClassTimeRange"]:
    if isinstance(value, str):
        return parse_weekly_class_time_ranges(value, source="override", require_keyword=False)

    if isinstance(value, dict):
        parsed = class_time_range_from_mapping(value)
        return parsed

    if isinstance(value, list):
        ranges: list[ClassTimeRange] = []
        for entry in value:
            if isinstance(entry, str):
                ranges.extend(parse_weekly_class_time_ranges(entry, source="override", require_keyword=False))
            elif isinstance(entry, dict):
                ranges.extend(class_time_range_from_mapping(entry))
        return dedupe_class_time_ranges(ranges)

    return []


def class_time_range_from_mapping(payload: dict[str, Any]) -> list["ClassTimeRange"]:
    raw_weekday = payload.get("weekday") or payload.get("day") or payload.get("days")
    raw_start = payload.get("start") or payload.get("start_time")
    raw_end = payload.get("end") or payload.get("end_time")
    if raw_weekday is None or raw_start is None or raw_end is None:
        return []

    weekdays = parse_weekday_tokens(str(raw_weekday))
    start_clock = parse_standalone_class_clock(str(raw_start))
    end_clock = parse_standalone_class_clock(str(raw_end))
    if not weekdays or not start_clock or not end_clock:
        return []

    start_hour, start_minute = start_clock
    end_hour, end_minute = end_clock
    return [
        ClassTimeRange(
            weekday=weekday,
            start_hour=start_hour,
            start_minute=start_minute,
            end_hour=end_hour,
            end_minute=end_minute,
            source="override",
        )
        for weekday in weekdays
    ]


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=str(path.parent),
            delete=False,
        ) as handle:
            handle.write(content)
            temp_path = Path(handle.name)
        os.replace(temp_path, path)
    finally:
        if temp_path is not None and temp_path.exists():
            temp_path.unlink(missing_ok=True)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    write_text(
        path,
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
    )


@dataclass
class DashboardItem:
    url: str
    title: str
    course: str
    schedule: str
    item_type: str


@dataclass
class DashboardParseResult:
    status: str
    items: list[DashboardItem]
    error_message: str | None = None


@dataclass
class CourseActivity:
    url: str
    title: str
    course: str
    module: str
    row_text: str


@dataclass(frozen=True)
class DateSnippet:
    text: str
    sort_due: datetime
    timing_precision: str
    start: int
    end: int


@dataclass(frozen=True)
class ClassTimeRange:
    weekday: int
    start_hour: int
    start_minute: int
    end_hour: int
    end_minute: int
    source: str = "page"


def collect_candidate_items(
    dashboard: DashboardParseResult, course_pages: list[dict[str, Any]]
) -> list[DashboardItem]:
    items = [
        item
        for item in dashboard.items
        if not should_ignore_course_name(item.course) and not should_ignore_course_url(item.url)
    ]
    seen_urls = {item.url for item in items}

    for page in course_pages:
        for item in parse_course_page(page):
            if item.url in seen_urls:
                continue
            seen_urls.add(item.url)
            items.append(item)

    return items


def collect_supplemental_urls(
    course_pages: list[dict[str, Any]], tier: str = "all"
) -> list[str]:
    urls: list[str] = []
    seen_urls: set[str] = set()

    for page in course_pages:
        for activity in iter_course_activities(page):
            activity_tier = supplemental_activity_tier(activity)
            if not activity_tier:
                continue
            if tier != "all" and activity_tier != tier:
                continue
            if activity.url in seen_urls:
                continue
            seen_urls.add(activity.url)
            urls.append(activity.url)

    return urls


def collect_supplemental_detail_urls(
    supplemental_pages: list[dict[str, Any]],
    board_article_state: dict[str, Any] | None = None,
    *,
    existing_detail_pages: list[dict[str, Any]] | None = None,
    include_non_relevant_primary: bool = True,
) -> tuple[list[str], dict[str, Any]]:
    urls: list[str] = []
    seen_urls: set[str] = set()
    available_detail_urls = {
        canonicalize_crawl_url(page_requested_url(page))
        for page in (existing_detail_pages or [])
        if canonicalize_crawl_url(page_requested_url(page))
    }
    previous_boards = (
        board_article_state.get("boards", {})
        if isinstance(board_article_state, dict) and isinstance(board_article_state.get("boards"), dict)
        else {}
    )
    next_state: dict[str, Any] = {"version": 1, "boards": {}}

    for page in supplemental_pages:
        current_url = canonicalize_crawl_url(page_requested_url(page))
        if (
            current_url
            and module_name_from_url(current_url) == "courseboard"
            and "/article.php" not in current_url.lower()
        ):
            board_urls, board_state = select_courseboard_detail_urls(
                page,
                previous_boards.get(current_url, {}),
                available_detail_urls=available_detail_urls,
                include_non_relevant_primary=include_non_relevant_primary,
            )
            next_state["boards"][current_url] = board_state
        else:
            board_urls = parse_supplemental_detail_urls(page)

        for url in board_urls:
            if url in seen_urls:
                continue
            seen_urls.add(url)
            urls.append(url)

    return urls, next_state


def select_courseboard_detail_urls(
    page: dict[str, Any],
    previous_board_state: dict[str, Any] | None = None,
    *,
    available_detail_urls: set[str] | None = None,
    include_non_relevant_primary: bool = True,
) -> tuple[list[str], dict[str, Any]]:
    current_url = canonicalize_crawl_url(page_requested_url(page))
    include_non_relevant = bool(include_non_relevant_primary) and is_primary_courseboard_title(
        str(page.get("title", ""))
    )
    available_detail_urls = available_detail_urls or set()
    previous_board_state = previous_board_state if isinstance(previous_board_state, dict) else {}
    previous_articles = sanitize_courseboard_article_state(
        previous_board_state.get("articles", {})
        if isinstance(previous_board_state.get("articles"), dict)
        else {},
        include_non_relevant=include_non_relevant,
    )
    articles = parse_courseboard_article_entries(page)
    selected_urls: list[str] = []
    board_has_history = bool(previous_articles)
    current_head_signature = article_head_signature(
        articles,
        relevant_only=not include_non_relevant,
    )
    previous_head_signature = str(
        previous_board_state.get("head_signature" if include_non_relevant else "relevant_head_signature", "")
    ).strip()

    if (
        board_has_history
        and current_head_signature
        and current_head_signature == previous_head_signature
    ):
        missing_urls = [
            article["url"]
            for article in articles
            if should_refetch_missing_courseboard_article(
                article,
                previous_articles.get(article.get("article_id", ""), {})
                if article.get("article_id", "")
                else {},
                available_detail_urls,
                include_non_relevant=include_non_relevant,
            )
        ]
        if missing_urls:
            return missing_urls, build_courseboard_article_state(
                page,
                articles,
                previous_articles,
                include_non_relevant=include_non_relevant,
            )
        return [], build_courseboard_article_state(
            page,
            articles,
            previous_articles,
            include_non_relevant=include_non_relevant,
        )

    for article in articles:
        article_id = article.get("article_id", "")
        previous_article = previous_articles.get(article_id, {}) if article_id else {}
        if should_fetch_courseboard_article(
            article,
            previous_article,
            board_has_history,
            include_non_relevant=include_non_relevant,
        ) or should_refetch_missing_courseboard_article(
            article,
            previous_article,
            available_detail_urls,
            include_non_relevant=include_non_relevant,
        ):
            selected_urls.append(article["url"])

    return selected_urls, build_courseboard_article_state(
        page,
        articles,
        previous_articles,
        include_non_relevant=include_non_relevant,
    )


def parse_courseboard_article_entries(page: dict[str, Any]) -> list[dict[str, str]]:
    html = page.get("html", "")
    if not html or looks_like_login_page(page):
        return []

    current_url = page_requested_url(page)
    if module_name_from_url(current_url) != "courseboard" or "/article.php" in current_url.lower():
        return []

    soup = BeautifulSoup(html, "html.parser")
    table = soup.select_one("table.courseboard_table")
    if table is None:
        return []

    entries: list[dict[str, str]] = []
    for index, row in enumerate(table.select("tbody tr")):
        link = row.select_one("a[href*='/mod/courseboard/article.php']")
        if link is None:
            continue
        url = normalize_url(link.get("href", ""))
        if not url or not is_same_klms_url(url):
            continue

        cells = [normalize_whitespace(cell.get_text(" ", strip=True)) for cell in row.select("td")]
        article_id = article_bwid(url)
        title = normalize_whitespace(link.get_text(" ", strip=True))
        row_text = normalize_whitespace(row.get_text(" ", strip=True))
        posted_at = cells[3] if len(cells) >= 4 else ""
        entries.append(
            {
                "article_id": article_id,
                "url": url,
                "title": title,
                "posted_at": posted_at,
                "row_text": row_text,
                "row_signature": normalize_whitespace(
                    " | ".join(value for value in (title, posted_at) if value)
                ),
                "order": str(index),
            }
        )

    return entries


def courseboard_article_is_relevant(article: dict[str, Any]) -> bool:
    combined = normalize_whitespace(
        " ".join(
        normalize_whitespace(str(article.get(field, "")))
        for field in ("title", "row_text", "url")
        )
    )
    if re.search(r"\bmidterm(?:\s+exam)?\b", combined, re.IGNORECASE):
        return True
    if re.search(r"\bfinal\s+exam\b", combined, re.IGNORECASE):
        return True
    if re.search(r"\bexam\b", combined, re.IGNORECASE):
        return True
    if re.search(r"\bhelp\s*desk\b", combined, re.IGNORECASE):
        return True
    if re.search(r"\bsyllabus\b", combined, re.IGNORECASE):
        return True
    if re.search(r"\bcourse\s+outline\b", combined, re.IGNORECASE):
        return True
    if re.search(r"\bcourse\s+schedule\b", combined, re.IGNORECASE):
        return True
    return contains_any_keyword(combined, ("시험", "중간", "기말", "헬프데스크", "강의계획", "강의 계획", "계획서"))


def article_head_signature(
    articles: list[dict[str, Any]],
    *,
    relevant_only: bool = False,
    limit: int = 8,
) -> str:
    selected: list[str] = []
    for article in articles:
        if relevant_only and not courseboard_article_is_relevant(article):
            continue
        article_id = str(article.get("article_id", "")).strip()
        if not article_id:
            continue
        selected.append(f"{article_id}:{str(article.get('row_signature', '')).strip()}")
        if len(selected) >= limit:
            break
    return "|".join(selected)


def sanitize_courseboard_article_state(
    previous_articles: dict[str, Any],
    *,
    include_non_relevant: bool = False,
) -> dict[str, dict[str, str]]:
    sanitized: dict[str, dict[str, str]] = {}

    for article_id, payload in previous_articles.items():
        if not isinstance(payload, dict):
            continue

        key = str(article_id).strip()
        if not key:
            continue

        article = {
            "url": str(payload.get("url", "")),
            "title": str(payload.get("title", "")),
            "posted_at": str(payload.get("posted_at", "")),
            "row_text": str(payload.get("row_text", "")),
            "row_signature": str(payload.get("row_signature", "")),
        }
        if not include_non_relevant and not courseboard_article_is_relevant(article):
            continue

        normalized_signature = normalize_whitespace(
            " | ".join(value for value in (article["title"], article["posted_at"]) if value)
        )
        article["row_signature"] = normalized_signature or article["row_signature"]
        sanitized[key] = article

    return sanitized


def should_fetch_courseboard_article(
    article: dict[str, str],
    previous_article: dict[str, Any] | None = None,
    board_has_history: bool = True,
    *,
    include_non_relevant: bool = False,
) -> bool:
    previous_article = previous_article if isinstance(previous_article, dict) else {}
    article_id = str(article.get("article_id", "")).strip()
    if not article_id:
        return False

    is_relevant = courseboard_article_is_relevant(article)
    if not include_non_relevant and not is_relevant and not previous_article:
        return False

    if not board_has_history:
        return include_non_relevant or is_relevant

    if not previous_article:
        return include_non_relevant or is_relevant

    return str(previous_article.get("row_signature", "")) != str(article.get("row_signature", ""))


def should_refetch_missing_courseboard_article(
    article: dict[str, str],
    previous_article: dict[str, Any] | None,
    available_detail_urls: set[str],
    *,
    include_non_relevant: bool = False,
) -> bool:
    previous_article = previous_article if isinstance(previous_article, dict) else {}
    if not previous_article:
        return False
    if not include_non_relevant and not courseboard_article_is_relevant(article):
        return False

    article_url = canonicalize_crawl_url(str(article.get("url", "")).strip())
    return bool(article_url and article_url not in available_detail_urls)


def build_courseboard_article_state(
    page: dict[str, Any],
    articles: list[dict[str, str]],
    previous_articles: dict[str, Any] | None = None,
    *,
    include_non_relevant: bool = False,
) -> dict[str, Any]:
    previous_articles = previous_articles if isinstance(previous_articles, dict) else {}
    merged_articles: dict[str, dict[str, str]] = {}

    for article_id, payload in previous_articles.items():
        if not isinstance(payload, dict):
            continue
        key = str(article_id).strip()
        if not key:
            continue
        if not include_non_relevant and not courseboard_article_is_relevant(payload):
            continue
        merged_articles[key] = {
            "url": str(payload.get("url", "")),
            "title": str(payload.get("title", "")),
            "posted_at": str(payload.get("posted_at", "")),
            "row_signature": str(payload.get("row_signature", "")),
        }

    for article in articles:
        article_id = str(article.get("article_id", "")).strip()
        if not article_id:
            continue
        if not include_non_relevant and not courseboard_article_is_relevant(article):
            continue
        merged_articles[article_id] = {
            "url": article.get("url", ""),
            "title": article.get("title", ""),
            "posted_at": article.get("posted_at", ""),
            "row_signature": article.get("row_signature", ""),
        }

    ordered_ids = sorted(
        merged_articles.keys(),
        key=lambda value: int(value) if value.isdigit() else -1,
        reverse=True,
    )[:BOARD_ARTICLE_STATE_LIMIT]
    trimmed_articles = {article_id: merged_articles[article_id] for article_id in ordered_ids}
    latest_article_id = ordered_ids[0] if ordered_ids else ""

    return {
        "title": str(page.get("title", "")),
        "latest_article_id": latest_article_id,
        "visible_article_count": len(articles),
        "head_signature": article_head_signature(articles),
        "relevant_head_signature": article_head_signature(articles, relevant_only=True),
        "articles": trimmed_articles,
    }


def article_bwid(url: str) -> str:
    parsed = urlparse(url)
    for key, value in parse_qsl(parsed.query, keep_blank_values=True):
        if key.lower() == "bwid":
            return str(value).strip()
    return ""


def collect_notice_article_urls(
    supplemental_primary_pages: list[dict[str, Any]],
    notice_board_state: dict[str, Any] | None = None,
    notice_summary_state: dict[str, Any] | None = None,
    course_lookup: dict[str, str] | None = None,
) -> tuple[list[str], dict[str, Any]]:
    urls: list[str] = []
    seen_urls: set[str] = set()
    previous_boards = (
        notice_board_state.get("boards", {})
        if isinstance(notice_board_state, dict) and isinstance(notice_board_state.get("boards"), dict)
        else {}
    )
    previous_summaries = (
        notice_summary_state.get("articles", {})
        if isinstance(notice_summary_state, dict)
        and isinstance(notice_summary_state.get("articles"), dict)
        else {}
    )
    next_state: dict[str, Any] = {"version": 1, "boards": {}}

    for page in supplemental_primary_pages:
        current_url = canonicalize_crawl_url(page_requested_url(page))
        if (
            not current_url
            or module_name_from_url(current_url) != "courseboard"
            or "/article.php" in current_url.lower()
            or not is_primary_courseboard_title(str(page.get("title", "")))
        ):
            continue

        board_urls, board_state = select_notice_article_urls(
            page,
            previous_boards.get(current_url, {}),
            previous_summaries,
            course_lookup or {},
        )
        next_state["boards"][current_url] = board_state
        for url in board_urls:
            if url in seen_urls:
                continue
            seen_urls.add(url)
            urls.append(url)

    return urls, next_state


def collect_notice_board_page_urls(supplemental_primary_pages: list[dict[str, Any]]) -> list[str]:
    urls: list[str] = []
    seen_urls: set[str] = set()

    for page in supplemental_primary_pages:
        current_url = canonicalize_crawl_url(page_requested_url(page))
        if (
            not current_url
            or module_name_from_url(current_url) != "courseboard"
            or "/article.php" in current_url.lower()
            or not is_primary_courseboard_title(str(page.get("title", "")))
        ):
            continue

        for url in parse_notice_board_page_urls(page):
            if url in seen_urls:
                continue
            seen_urls.add(url)
            urls.append(url)

    return urls


def select_notice_article_urls(
    page: dict[str, Any],
    previous_board_state: dict[str, Any] | None = None,
    previous_summaries: dict[str, Any] | None = None,
    course_lookup: dict[str, str] | None = None,
) -> tuple[list[str], dict[str, Any]]:
    previous_board_state = previous_board_state if isinstance(previous_board_state, dict) else {}
    previous_articles = (
        previous_board_state.get("articles", {})
        if isinstance(previous_board_state.get("articles"), dict)
        else {}
    )
    previous_summaries = previous_summaries if isinstance(previous_summaries, dict) else {}
    articles = parse_courseboard_article_entries(page)
    selected_urls: list[str] = []
    board_has_history = bool(previous_articles)
    current_head_signature = article_head_signature(articles)
    previous_head_signature = str(previous_board_state.get("head_signature", "")).strip()

    if (
        board_has_history
        and current_head_signature
        and current_head_signature == previous_head_signature
        and all(
            isinstance(previous_summaries.get(str(article.get("url", "")).strip()), dict)
            for article in articles
            if str(article.get("url", "")).strip()
        )
    ):
        return [], build_notice_board_state(page, articles, course_lookup or {})

    for article in articles:
        article_id = str(article.get("article_id", "")).strip()
        if not article_id:
            continue
        previous_article = previous_articles.get(article_id, {})
        previous_summary = previous_summaries.get(article.get("url", ""), {})
        if should_fetch_notice_article(
            article,
            previous_article,
            previous_summary,
            board_has_history,
        ):
            selected_urls.append(article["url"])

    return selected_urls, build_notice_board_state(page, articles, course_lookup or {})


def should_fetch_notice_article(
    article: dict[str, Any],
    previous_article: dict[str, Any] | None = None,
    previous_summary: dict[str, Any] | None = None,
    board_has_history: bool = True,
) -> bool:
    previous_article = previous_article if isinstance(previous_article, dict) else {}
    previous_summary = previous_summary if isinstance(previous_summary, dict) else {}

    if not board_has_history:
        return True
    if not previous_article:
        return True
    if str(previous_article.get("row_signature", "")) != str(article.get("row_signature", "")):
        return True
    return not previous_summary


def build_notice_board_state(
    page: dict[str, Any],
    articles: list[dict[str, str]],
    course_lookup: dict[str, str] | None = None,
) -> dict[str, Any]:
    soup = BeautifulSoup(page.get("html", ""), "html.parser")
    course_lookup = course_lookup if isinstance(course_lookup, dict) else {}
    course = course_lookup.get(url_query_id(page_requested_url(page)), "") or extract_course_name(page, soup)
    article_state: dict[str, dict[str, str]] = {}

    for article in articles:
        article_id = str(article.get("article_id", "")).strip()
        if not article_id:
            continue
        article_state[article_id] = {
            "url": article.get("url", ""),
            "title": article.get("title", ""),
            "posted_at": article.get("posted_at", ""),
            "row_signature": article.get("row_signature", ""),
            "order": article.get("order", ""),
        }

    latest_article_id = next(iter(article_state.keys()), "")
    return {
        "title": str(page.get("title", "")),
        "course": course,
        "latest_article_id": latest_article_id,
        "visible_article_count": len(articles),
        "head_signature": article_head_signature(articles),
        "articles": article_state,
    }


def parse_notice_board_page_urls(page: dict[str, Any]) -> list[str]:
    html = page.get("html", "")
    if not html or looks_like_login_page(page):
        return []

    current_url = canonicalize_crawl_url(page_requested_url(page))
    if not current_url:
        return []

    current_id = url_query_id(current_url)
    if not current_id:
        return []

    soup = BeautifulSoup(html, "html.parser")
    urls: list[str] = []
    seen_urls: set[str] = set()

    for link in soup.select(".pagination a[href], .paging a[href]"):
        url = canonicalize_crawl_url(normalize_url(link.get("href", "")))
        if not url or url in seen_urls or not is_same_klms_url(url):
            continue
        if module_name_from_url(url) != "courseboard" or "/article.php" in url.lower():
            continue
        if url_query_id(url) != current_id:
            continue

        page_number = url_query_page(url)
        if page_number <= 1:
            continue

        seen_urls.add(url)
        urls.append(url)

    return urls


def build_notice_digest(
    notice_board_state: dict[str, Any],
    notice_article_pages: list[dict[str, Any]],
    previous_notice_summary_state: dict[str, Any] | None = None,
    course_file_manifest: list[dict[str, Any]] | None = None,
    notice_filters: dict[str, list[str]] | None = None,
    auto_important_keywords_apply: bool = False,
) -> tuple[dict[str, Any], dict[str, Any]]:
    previous_notice_summary_state = (
        previous_notice_summary_state
        if isinstance(previous_notice_summary_state, dict)
        else {}
    )
    previous_articles = (
        previous_notice_summary_state.get("articles", {})
        if isinstance(previous_notice_summary_state.get("articles"), dict)
        else {}
    )
    page_lookup = {
        canonicalize_crawl_url(page_requested_url(page)): page for page in notice_article_pages
    }
    attachment_lookup = build_notice_attachment_lookup(course_file_manifest or [])
    next_articles: dict[str, dict[str, Any]] = {}
    current_entries: list[dict[str, Any]] = []
    ignored_entries: list[dict[str, Any]] = []
    important_candidate_urls: list[str] = []
    new_urls: list[str] = []
    updated_urls: list[str] = []

    boards = (
        notice_board_state.get("boards", {})
        if isinstance(notice_board_state, dict) and isinstance(notice_board_state.get("boards"), dict)
        else {}
    )

    for _board_url, board_payload in boards.items():
        if not isinstance(board_payload, dict):
            continue
        course = str(board_payload.get("course", "")).strip()
        board_title = str(board_payload.get("title", "")).strip()
        for meta in ordered_notice_article_metas(board_payload):
            url = canonicalize_crawl_url(str(meta.get("url", "")).strip())
            if not url:
                continue
            previous_entry = previous_articles.get(url, {}) if isinstance(previous_articles.get(url, {}), dict) else {}
            page = page_lookup.get(url)
            if page:
                entry = build_notice_article_entry(page, meta, course, board_title)
            elif previous_entry:
                entry = refresh_notice_article_entry(previous_entry, meta, course, board_title, url)
            else:
                entry = build_notice_article_placeholder(meta, course, board_title)
            entry = attach_notice_file_locations(entry, attachment_lookup)
            ignored_reason = notice_ignored_reason(entry, notice_filters or {})
            if ignored_reason:
                entry["ignored_reason"] = ignored_reason
                next_articles[url] = entry
                ignored_entries.append(entry)
                continue
            if notice_matches_keywords(entry, (notice_filters or {}).get("important_keywords", [])):
                entry["important_candidate"] = True
                important_candidate_urls.append(url)
                if auto_important_keywords_apply:
                    entry["auto_important"] = True
            change_state = "stable"
            if not previous_entry:
                change_state = "new"
                new_urls.append(url)
            else:
                previous_fingerprint = str(previous_entry.get("fingerprint", "")).strip()
                current_fingerprint = str(entry.get("fingerprint", "")).strip()
                if current_fingerprint and previous_fingerprint and current_fingerprint != previous_fingerprint:
                    change_state = "updated"
                    updated_urls.append(url)

            entry["change_state"] = change_state
            next_articles[url] = entry
            current_entries.append(entry)

    grouped_courses: dict[str, list[dict[str, Any]]] = {}
    for entry in current_entries:
        grouped_courses.setdefault(entry.get("course", "") or "기타", []).append(entry)

    generated_at = now_seoul()
    notice_digest_json = {
        "generated_at": generated_at,
        "notice_count": len(current_entries),
        "new_count": len(new_urls),
        "updated_count": len(updated_urls),
        "ignored_notice_count": len(ignored_entries),
        "important_candidate_count": len(important_candidate_urls),
        "new_urls": new_urls,
        "updated_urls": updated_urls,
        "important_candidate_urls": important_candidate_urls,
        "courses": [
            {
                "course": course,
                "notices": notices,
            }
            for course, notices in grouped_courses.items()
        ],
    }
    next_notice_summary_state = {
        "version": 2,
        "generated_at": generated_at,
        "articles": next_articles,
    }
    return next_notice_summary_state, notice_digest_json


def notice_filter_text(entry: dict[str, Any]) -> str:
    return " ".join(
        str(entry.get(key, ""))
        for key in ("course", "title", "summary", "body_text", "excerpt")
    ).casefold()


def notice_matches_keywords(entry: dict[str, Any], keywords: list[str]) -> bool:
    if not keywords:
        return False
    text = notice_filter_text(entry)
    return any(keyword.casefold() in text for keyword in keywords if keyword)


def notice_ignored_reason(entry: dict[str, Any], filters: dict[str, list[str]]) -> str:
    course = str(entry.get("course", "")).casefold()
    for ignored_course in filters.get("ignored_courses", []):
        if ignored_course.casefold() and ignored_course.casefold() in course:
            return f"ignored_course:{ignored_course}"
    for keyword in filters.get("ignored_keywords", []):
        if keyword.casefold() and keyword.casefold() in notice_filter_text(entry):
            return f"ignored_keyword:{keyword}"
    return ""


def build_notice_attachment_lookup(
    manifest_entries: list[dict[str, Any]],
) -> dict[str, dict[Any, list[dict[str, str]]]]:
    by_source_url: dict[str, list[dict[str, str]]] = {}
    by_course_filename: dict[tuple[str, str], list[dict[str, str]]] = {}

    for entry in manifest_entries:
        if not isinstance(entry, dict):
            continue
        source_url = canonicalize_crawl_url(str(entry.get("source_url", "")).strip())
        course = normalize_attachment_value(str(entry.get("course", "")))
        name = normalize_attachment_value(str(entry.get("filename", "")))
        relative_path = normalize_path_value(str(entry.get("relative_path", "")))
        absolute_path = normalize_path_value(str(entry.get("absolute_path", "")))
        if not name:
            fallback_name = relative_path or absolute_path
            name = normalize_attachment_value(Path(fallback_name).name) if fallback_name else ""
        if not name and not relative_path and not absolute_path:
            continue

        attachment_item = {
            "name": name,
            "relative_path": relative_path,
            "absolute_path": absolute_path,
        }
        if source_url:
            by_source_url.setdefault(source_url, []).append(attachment_item)
        if course and name:
            by_course_filename.setdefault((course, name), []).append(attachment_item)

    return {
        "by_source_url": {
            key: normalize_notice_attachment_items(value)
            for key, value in by_source_url.items()
        },
        "by_course_filename": {
            key: normalize_notice_attachment_items(value)
            for key, value in by_course_filename.items()
        },
    }


def attach_notice_file_locations(
    entry: dict[str, Any],
    attachment_lookup: dict[str, dict[Any, list[dict[str, str]]]],
) -> dict[str, Any]:
    normalized_entry = dict(entry)
    course = normalize_attachment_value(str(normalized_entry.get("course", "")))
    source_url = canonicalize_crawl_url(str(normalized_entry.get("url", "")).strip())
    attachment_names = [
        normalize_attachment_value(str(value))
        for value in normalized_entry.get("attachments", [])
        if normalize_attachment_value(str(value))
    ]

    by_source_url = attachment_lookup.get("by_source_url", {})
    by_course_filename = attachment_lookup.get("by_course_filename", {})
    resolved_items: list[dict[str, str]] = []

    def add_items(items: list[dict[str, str]]) -> None:
        for item in normalize_notice_attachment_items(items):
            if item not in resolved_items:
                resolved_items.append(item)

    source_matches = by_source_url.get(source_url, [])
    if source_matches and attachment_names:
        for attachment_name in attachment_names:
            matching_items = [
                item
                for item in source_matches
                if attachment_name_matches(attachment_name, str(item.get("name", "")))
            ]
            if matching_items:
                add_items(matching_items)
                continue
            if course:
                add_items(by_course_filename.get((course, attachment_name), []))
    elif source_matches:
        add_items(source_matches)

    if not resolved_items and course:
        for attachment_name in attachment_names:
            add_items(by_course_filename.get((course, attachment_name), []))

    if not resolved_items:
        add_items(normalize_notice_attachment_items(normalized_entry.get("attachment_items", [])))

    normalized_entry["attachment_items"] = resolved_items
    return normalized_entry


def normalize_notice_attachment_items(values: Any) -> list[dict[str, str]]:
    items: list[dict[str, str]] = []
    seen: set[tuple[str, str, str]] = set()

    for value in values if isinstance(values, list) else []:
        if not isinstance(value, dict):
            continue
        relative_path = normalize_path_value(str(value.get("relative_path", "")))
        absolute_path = normalize_path_value(str(value.get("absolute_path", "")))
        name = normalize_attachment_value(str(value.get("name", "")))
        fallback_name = relative_path or absolute_path
        if not name and fallback_name:
            name = normalize_attachment_value(Path(fallback_name).name)
        if not name and not relative_path and not absolute_path:
            continue
        key = (name, relative_path, absolute_path)
        if key in seen:
            continue
        seen.add(key)
        items.append(
            {
                "name": name,
                "relative_path": relative_path,
                "absolute_path": absolute_path,
            }
        )

    return items


def attachment_name_matches(left: str, right: str) -> bool:
    normalized_left = normalize_attachment_value(left)
    normalized_right = normalize_attachment_value(right)
    if not normalized_left or not normalized_right:
        return False
    if normalized_left == normalized_right:
        return True

    left_path = Path(normalized_left)
    right_path = Path(normalized_right)
    if left_path.name == right_path.name:
        return True
    return left_path.stem == right_path.stem


def normalize_attachment_value(value: str) -> str:
    return normalize_whitespace(unicodedata.normalize("NFC", value or ""))


def normalize_path_value(value: str) -> str:
    normalized = unicodedata.normalize("NFC", value or "")
    normalized = normalized.replace("\\", "/")
    return normalize_whitespace(normalized)


def ordered_notice_article_metas(board_payload: dict[str, Any]) -> list[dict[str, Any]]:
    articles = board_payload.get("articles", {})
    if not isinstance(articles, dict):
        return []

    def sort_key(item: dict[str, Any]) -> tuple[int, str]:
        order_text = str(item.get("order", "999")).strip()
        try:
            order_value = int(order_text)
        except ValueError:
            order_value = 999
        return (order_value, str(item.get("title", "")))

    return sorted(
        [payload for payload in articles.values() if isinstance(payload, dict)],
        key=sort_key,
    )


def build_notice_article_entry(
    page: dict[str, Any],
    meta: dict[str, Any],
    course: str,
    board_title: str,
) -> dict[str, Any]:
    soup = BeautifulSoup(page.get("html", ""), "html.parser")
    body_text = extract_notice_body_text(page, soup)
    compact_body_text = normalize_whitespace(body_text)
    attachments = extract_notice_attachment_names(soup)
    article_title = clean_title(
        normalize_whitespace(
            text_of_first(soup.select(".courseboard h2, .courseboard h1, #region-main h2, #region-main h1"))
        )
    ) or str(meta.get("title", "")).strip()
    posted_at = str(meta.get("posted_at", "")).strip()
    summary = summarize_notice_text(compact_body_text, attachments)
    fingerprint = notice_article_fingerprint(article_title, posted_at, compact_body_text, attachments)
    return {
        "url": canonicalize_crawl_url(page_requested_url(page)),
        "article_id": article_bwid(page_requested_url(page)),
        "course": course,
        "board_title": board_title,
        "title": article_title,
        "posted_at": posted_at,
        "attachments": attachments,
        "attachment_items": [],
        "summary": summary,
        "excerpt": summarize_instructions(compact_body_text, 320),
        "body_text": body_text,
        "fingerprint": fingerprint,
        "row_signature": str(meta.get("row_signature", "")).strip(),
        "order": str(meta.get("order", "")).strip(),
    }


def refresh_notice_article_entry(
    previous_entry: dict[str, Any],
    meta: dict[str, Any],
    course: str,
    board_title: str,
    url: str,
) -> dict[str, Any]:
    previous_entry = previous_entry if isinstance(previous_entry, dict) else {}
    attachments = [
        normalize_whitespace(str(value))
        for value in previous_entry.get("attachments", [])
        if normalize_whitespace(str(value))
    ]
    attachment_items = normalize_notice_attachment_items(previous_entry.get("attachment_items", []))
    title = clean_title(str(meta.get("title", "")).strip() or str(previous_entry.get("title", "")))
    posted_at = str(meta.get("posted_at", "")).strip() or str(previous_entry.get("posted_at", ""))
    body_text = format_notice_body_text(str(previous_entry.get("body_text", "")))
    compact_body_text = normalize_whitespace(body_text)
    summary = (
        summarize_notice_text(compact_body_text, attachments)
        if compact_body_text
        else "본문을 다시 불러와야 해서 다음 동기화 때 재확인 필요"
    )
    fingerprint = notice_article_fingerprint(title, posted_at, compact_body_text, attachments)
    return {
        "url": url,
        "article_id": article_bwid(url),
        "course": course or str(previous_entry.get("course", "")),
        "board_title": board_title or str(previous_entry.get("board_title", "")),
        "title": title,
        "posted_at": posted_at,
        "attachments": attachments,
        "attachment_items": attachment_items,
        "summary": summary or str(previous_entry.get("summary", "")),
        "excerpt": summarize_instructions(compact_body_text, 320) if compact_body_text else "",
        "body_text": body_text,
        "fingerprint": fingerprint,
        "row_signature": (
            str(meta.get("row_signature", "")).strip()
            or str(previous_entry.get("row_signature", ""))
        ),
        "order": str(meta.get("order", "")).strip() or str(previous_entry.get("order", "")),
    }


def build_notice_article_placeholder(
    meta: dict[str, Any],
    course: str,
    board_title: str,
) -> dict[str, Any]:
    title = str(meta.get("title", "")).strip()
    posted_at = str(meta.get("posted_at", "")).strip()
    fingerprint = notice_article_fingerprint(title, posted_at, "", [])
    return {
        "url": canonicalize_crawl_url(str(meta.get("url", "")).strip()),
        "article_id": article_bwid(str(meta.get("url", "")).strip()),
        "course": course,
        "board_title": board_title,
        "title": title,
        "posted_at": posted_at,
        "attachments": [],
        "attachment_items": [],
        "summary": "본문 캐시가 아직 없어 다음 fetch 때 요약이 채워질 예정이야.",
        "excerpt": "",
        "body_text": "",
        "fingerprint": fingerprint,
        "row_signature": str(meta.get("row_signature", "")).strip(),
        "order": str(meta.get("order", "")).strip(),
    }


def extract_notice_attachment_names(soup: BeautifulSoup) -> list[str]:
    attachments: list[str] = []
    seen: set[str] = set()

    for link in soup.select(".courseboard a[href], #region-main a[href]"):
        url = normalize_url(link.get("href", ""))
        if not url or not is_document_url(url):
            continue
        label = normalize_whitespace(link.get_text(" ", strip=True))
        if not label:
            label = Path(urlparse(url).path).name
        if not label or label in seen:
            continue
        seen.add(label)
        attachments.append(label)

    return attachments


def extract_notice_body_text(page: dict[str, Any], soup: BeautifulSoup) -> str:
    requested_url = page_requested_url(page).lower()
    if module_name_from_url(requested_url) == "courseboard" and (
        "/article.php" in requested_url or "bwid=" in requested_url
    ):
        article_body = text_of_first(
            soup.select(".courseboard .content, .courseboard .no-overflow"),
            separator="\n",
        )
        formatted = format_notice_body_text(article_body)
        if formatted:
            return formatted

    return format_notice_body_text(extract_page_text(page, soup))


def format_notice_body_text(text: str) -> str:
    cleaned_text = clean_notice_body_source_text(text)
    if not cleaned_text:
        return ""

    raw_lines = cleaned_text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    paragraphs: list[str] = []
    current: list[str] = []

    def flush_current() -> None:
        nonlocal current
        if not current:
            return
        paragraph = normalize_whitespace(" ".join(current))
        if paragraph:
            paragraphs.append(paragraph)
        current = []

    for raw_line in raw_lines:
        line = normalize_whitespace(raw_line)
        if not line:
            flush_current()
            continue
        if is_notice_structural_line(line):
            flush_current()
            paragraphs.append(line)
            continue
        current.append(line)
    flush_current()
    paragraphs = merge_notice_paragraphs(paragraphs)

    if not paragraphs:
        compact = normalize_whitespace(cleaned_text)
        return compact

    if len(paragraphs) == 1 and len(paragraphs[0]) >= 180:
        display_paragraphs = split_notice_display_paragraphs(paragraphs[0])
        if len(display_paragraphs) >= 2:
            return "\n\n".join(display_paragraphs)

    return "\n\n".join(paragraphs)


def clean_notice_body_source_text(text: str) -> str:
    raw = str(text or "").replace("\u200e", " ").replace("\u200f", " ").replace("\xa0", " ")
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    compact = normalize_whitespace(raw)
    if not compact:
        return ""
    if looks_like_notice_ui_noise(compact):
        return ""

    cleaned = raw
    cleaned = re.sub(r"\s*[•⦁]\s*", "\n\n• ", cleaned)
    cleaned = re.sub(
        r"\s+(?=(?:Date(?:\s*&\s*Time)?|Time|Location|Place|Venue|Room|Range|Coverage|Exam\s*Range)\s*:)",
        "\n\n",
        cleaned,
        flags=re.IGNORECASE,
    )
    cleaned = re.sub(r"\s+(?=##\s+)", "\n\n", cleaned)
    cleaned = re.sub(
        r"\s+(?=(?:Hello\b|Dear\b|Thank you\b|감사합니다\b|문의\b|클레임은\b|Nano Quiz Link\b|Link:\b|수업 안내\b|수업 전 준비사항\b|업로드:\b|제출 마감:\b))",
        "\n\n",
        cleaned,
    )
    cleaned = re.sub(
        r"(?<!## )\s+(?=(?:Requirements\b|Best regards\b|Original date\b|Original due date\b|New date\b|New due date\b|VPN 접속 링크\b|VPN 메뉴얼\b|KiteBoard 링크\b))",
        "\n\n",
        cleaned,
    )
    cleaned = re.sub(r"\s+(?=(?:[1-9]|1\d|20)\.\s+[A-Z가-힣])", "\n\n", cleaned)
    cleaned = re.sub(
        r"(?i)(Time:\s*[^\n]+)\n{2,}-\s+(\d{1,2}:\d{2}\s*(?:am|pm)?)",
        r"\1 - \2",
        cleaned,
    )
    cleaned = re.sub(r"\s+(?=(?:-\s+(?!\d{1,2}:\d{2}\b)|\(\d+\)\s+))", "\n\n", cleaned)
    cleaned = re.sub(r"\s+(?=-{20,})", "\n\n", cleaned)
    cleaned = re.sub(r"(https?://\S+)", r"\n\n\1", cleaned)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
    return cleaned.strip()


def is_notice_structural_line(line: str) -> bool:
    normalized = normalize_whitespace(line)
    if not normalized:
        return False

    if re.match(r"^(?:[•⦁]\s+|[-*]\s+|(?:[1-9]|1\d|20)[.)]\s+|\(\d+\)\s+)", normalized):
        return True

    labels = [
        "Coverage",
        "Date",
        "Deadline",
        "Details",
        "Due",
        "Exam Range",
        "Instructor",
        "Link",
        "Location",
        "Nano Quiz Link",
        "Notice",
        "Office hour",
        "Office Hours",
        "Question",
        "Range",
        "Room",
        "Submission",
        "TA",
        "Time",
        "Topic",
        "Venue",
        "Zoom",
        "기한",
        "내용",
        "링크",
        "마감",
        "문의",
        "비고",
        "시간",
        "수업",
        "수업 안내",
        "수업 전 준비사항",
        "업로드",
        "일시",
        "장소",
        "제출",
        "제출 마감",
        "주제",
        "준비물",
        "참고",
    ]
    label_pattern = "|".join(re.escape(label) for label in labels)
    return bool(re.match(rf"^(?:{label_pattern})\s*:\s*\S+", normalized))


def merge_notice_paragraphs(paragraphs: list[str]) -> list[str]:
    merged: list[str] = []
    for paragraph in paragraphs:
        if merged and should_merge_notice_paragraph(merged[-1], paragraph):
            merged[-1] = normalize_whitespace(f"{merged[-1]} {paragraph}")
            continue
        merged.append(paragraph)
    return merged


def should_merge_notice_paragraph(previous: str, current: str) -> bool:
    previous_normalized = normalize_whitespace(previous)
    current_normalized = normalize_whitespace(current)
    if not previous_normalized or not current_normalized:
        return False
    if is_notice_structural_line(previous_normalized) or is_notice_structural_line(current_normalized):
        return False
    if previous_normalized.endswith(":"):
        return False

    return bool(re.match(r"^\d{2,}\.\s+\S+", current_normalized))


def looks_like_notice_ui_noise(text: str) -> bool:
    compact = normalize_whitespace(text)
    if not compact:
        return False

    if compact.startswith("오류 메인 콘텐츠로 건너뛰기"):
        return True

    markers = [
        "강의실모바일메뉴",
        "KLMS 가이드",
        "친구목록 메시지 선택",
        "No contacts",
        "Personal space Save draft messages",
        "Notification preferences",
        "메시지 수락할 대상",
        "Use enter to send",
        "You are unable to message this user",
        "모두 보기 English",
        "로그아웃 닫기 나의 진도",
        "남은 영상 0 개 남은 과제 0 개 남은 퀴즈 0 개",
    ]
    marker_hits = sum(1 for marker in markers if marker in compact)
    if marker_hits >= 3:
        return True

    return False


def split_notice_display_paragraphs(text: str) -> list[str]:
    cleaned = clean_notice_body_source_text(text)
    if not cleaned:
        return []

    segments = [
        chunk.strip()
        for chunk in re.split(
            r"\n{2,}|(?=\n• )|(?<=감사합니다\.)\s+|(?<=Thank you\.)\s+|(?<=문의해 주세요\.)\s+",
            cleaned,
        )
        if chunk.strip()
    ]

    if len(segments) >= 2:
        expanded_segments: list[str] = []
        for segment in segments:
            sentences = split_summary_sentences(segment)
            if len(sentences) < 2:
                expanded_segments.append(segment)
                continue

            current: list[str] = []
            current_length = 0
            for sentence in sentences:
                extra = len(sentence) + (1 if current else 0)
                if current and (current_length + extra > 180 or len(current) >= 2):
                    expanded_segments.append(" ".join(current))
                    current = [sentence]
                    current_length = len(sentence)
                    continue
                current.append(sentence)
                current_length += extra
            if current:
                expanded_segments.append(" ".join(current))
        return expanded_segments

    normalized = normalize_whitespace(cleaned)
    sentences = split_summary_sentences(normalized)
    if len(sentences) < 2:
        return [normalized]

    chunks: list[str] = []
    current: list[str] = []
    current_length = 0

    for sentence in sentences:
        extra = len(sentence) + (1 if current else 0)
        if current and (current_length + extra > 180 or len(current) >= 2):
            chunks.append(" ".join(current))
            current = [sentence]
            current_length = len(sentence)
            continue
        current.append(sentence)
        current_length += extra

    if current:
        chunks.append(" ".join(current))

    return chunks


def summarize_notice_text(body_text: str, attachments: list[str]) -> str:
    sentences = split_summary_sentences(body_text)
    selected: list[str] = []
    total_length = 0

    for sentence in sentences:
        if not sentence:
            continue
        selected.append(sentence)
        total_length += len(sentence)
        if len(selected) >= 2 or total_length >= 220:
            break

    summary = normalize_whitespace(" ".join(selected))
    if not summary:
        summary = summarize_instructions(body_text, 220)
    if attachments:
        attachment_note = f"첨부 {len(attachments)}개"
        if attachment_note not in summary:
            summary = f"{summary} {attachment_note}".strip()
    return summary


def split_summary_sentences(text: str) -> list[str]:
    normalized = normalize_whitespace(text)
    if not normalized:
        return []
    parts = re.split(r"(?<=[.!?])\s+|(?<=다\.)\s+|(?<=요\.)\s+", normalized)
    return [normalize_whitespace(part) for part in parts if normalize_whitespace(part)]


def notice_article_fingerprint(
    title: str,
    posted_at: str,
    body_text: str,
    attachments: list[str],
) -> str:
    payload = "\n".join(
        [
            normalize_whitespace(title),
            normalize_whitespace(posted_at),
            normalize_whitespace(body_text),
            "\n".join(attachments),
        ]
    )
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()


def collect_file_seed_urls(course_pages: list[dict[str, Any]]) -> list[str]:
    candidates: list[tuple[int, int, str]] = []
    sequence = 0

    def add_candidate(raw_url: str, module: str = "") -> None:
        nonlocal sequence
        url = canonicalize_crawl_url(raw_url)
        if not url or not is_crawlable_klms_page_url(url):
            return
        candidates.append((file_seed_priority(url, module), sequence, url))
        sequence += 1

    for page in course_pages:
        for parser in (parse_assignment_index_urls, parse_resource_index_urls):
            for raw_url in parser(page):
                add_candidate(raw_url)

        for activity in iter_course_activities(page):
            add_candidate(activity.url, activity.module)

    return dedupe_ordered_urls(candidates)


def collect_linked_html_urls(
    pages: list[dict[str, Any]],
    file_scan_only: bool = False,
    source_requested_urls: set[str] | None = None,
) -> list[str]:
    candidates: list[tuple[int, int, str]] = []
    sequence = 0

    for page in pages:
        html = page.get("html", "")
        if not html or looks_like_login_page(page):
            continue

        current_url = canonicalize_crawl_url(page_requested_url(page))
        if source_requested_urls is not None and current_url not in source_requested_urls:
            continue
        if should_ignore_course_url(current_url):
            continue
        soup = BeautifulSoup(html, "html.parser")
        for link in iter_main_content_links(soup):
            url = canonicalize_crawl_url(resolve_page_link_url(current_url, link.get("href", "")))
            if not url or url == current_url:
                continue
            if "/course/view.php?id=" in url.lower():
                continue
            if not is_crawlable_klms_page_url(url):
                continue
            if file_scan_only and not is_file_scan_nested_url(url):
                continue
            if not should_follow_crawl_link(current_url, url):
                continue

            candidates.append((linked_html_priority(url), sequence, url))
            sequence += 1

    return dedupe_ordered_urls(candidates)


def sanitize_url_list(urls: Any) -> list[str]:
    sanitized: list[str] = []
    seen: set[str] = set()
    for value in urls if isinstance(urls, list) else []:
        url = canonicalize_crawl_url(str(value))
        if not url or url in seen:
            continue
        seen.add(url)
        sanitized.append(url)
    return sanitized


def build_linked_html_index(
    pages: list[dict[str, Any]],
    existing_index: dict[str, Any] | None = None,
    changed_requested_urls: set[str] | None = None,
    file_scan_only: bool = False,
) -> tuple[list[str], dict[str, Any]]:
    existing_index = existing_index if isinstance(existing_index, dict) else {}
    previous_sources = (
        existing_index.get("sources", {})
        if isinstance(existing_index.get("sources"), dict)
        else {}
    )

    seen_source_urls: set[str] = set()
    merged_candidates: list[tuple[int, int, str]] = []
    next_sources: dict[str, dict[str, Any]] = {}
    sequence = 0

    for page in pages:
        current_url = canonicalize_crawl_url(page_requested_url(page))
        if not current_url or current_url in seen_source_urls:
            continue
        seen_source_urls.add(current_url)

        previous_source = previous_sources.get(current_url, {})
        current_fingerprint = page_fingerprint(page)
        previous_fingerprint = (
            str(previous_source.get("page_fingerprint", ""))
            if isinstance(previous_source, dict)
            else ""
        )
        should_recompute = (
            not isinstance(previous_source, dict)
            or current_fingerprint != previous_fingerprint
        )
        if should_recompute:
            source_urls = collect_linked_html_urls(
                [page],
                file_scan_only=file_scan_only,
                source_requested_urls={current_url},
            )
        else:
            source_urls = sanitize_url_list(previous_source.get("urls", []))

        next_sources[current_url] = {
            "urls": source_urls,
            "title": str(page.get("title", "")),
            "page_fingerprint": current_fingerprint,
        }
        for url in source_urls:
            merged_candidates.append((linked_html_priority(url), sequence, url))
            sequence += 1

    return (
        dedupe_ordered_urls(merged_candidates),
        {
            "version": 1,
            "file_scan_only": bool(file_scan_only),
            "sources": next_sources,
        },
    )


def build_activity_course_lookup(course_pages: list[dict[str, Any]]) -> dict[str, str]:
    lookup: dict[str, str] = {}
    for page in course_pages:
        for activity in iter_course_activities(page):
            if should_ignore_course_name(activity.course):
                continue
            identifier = url_query_id(activity.url)
            if not identifier or identifier in lookup or not activity.course:
                continue
            lookup[identifier] = activity.course
    return lookup


def parse_dashboard_page(page: dict[str, Any]) -> DashboardParseResult:
    html = page.get("html", "")
    if not html:
        return DashboardParseResult(status="error", items=[], error_message="KLMS 페이지 HTML을 읽지 못했어.")

    if looks_like_login_page(page):
        return DashboardParseResult(
            status="error",
            items=[],
            error_message="KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘.",
        )

    soup = BeautifulSoup(html, "html.parser")
    boxes = soup.select("div.list-box")
    items: list[DashboardItem] = []
    seen_urls: set[str] = set()

    for box in boxes:
        link = box.select_one("a[href*='/mod/']")
        if not link:
            continue
        url = normalize_url(link.get("href", ""))
        if not url or url in seen_urls:
            continue
        seen_urls.add(url)

        texts = [normalize_whitespace(li.get_text(" ", strip=True)) for li in box.select("li")]
        schedule = texts[0] if len(texts) > 0 else ""
        title = texts[1] if len(texts) > 1 else normalize_whitespace(link.get_text(" ", strip=True))
        course = texts[2] if len(texts) > 2 else ""
        classes = box.get("class", [])
        item_type = next((cls for cls in classes if cls != "list-box"), "task")

        items.append(
            DashboardItem(
                url=url,
                title=title,
                course=course,
                schedule=schedule,
                item_type=item_type,
            )
        )

    if not items:
        return DashboardParseResult(
            status="error",
            items=[],
            error_message="대시보드에서 과제 목록을 찾지 못했어. KLMS 화면 구조가 바뀌었는지 한 번 확인이 필요해.",
        )

    return DashboardParseResult(status="ok", items=items)


def parse_course_urls_from_dashboard(page: dict[str, Any]) -> list[str]:
    html = page.get("html", "")
    if not html or looks_like_login_page(page):
        return []

    soup = BeautifulSoup(html, "html.parser")
    urls: list[str] = []
    seen_urls: set[str] = set()
    link_nodes = soup.select("ul.main-course-list.student a[href*='/course/view.php?id=']")

    if not link_nodes:
        link_nodes = soup.select("a[href*='/course/view.php?id=']")

    for link in link_nodes:
        url = normalize_url(link.get("href", ""))
        if not url or url in seen_urls:
            continue
        title = normalize_whitespace(link.get_text(" ", strip=True))
        if should_ignore_course_url(url) or should_ignore_course_name(title):
            continue
        seen_urls.add(url)
        urls.append(url)

    return urls


def parse_course_page(page: dict[str, Any]) -> list[DashboardItem]:
    items: list[DashboardItem] = []
    seen_urls: set[str] = set()

    for activity in iter_course_activities(page):
        if activity.url in seen_urls:
            continue

        schedule = extract_due_text(activity.row_text)
        if not should_track_course_item(activity.url, activity.title, schedule):
            continue

        seen_urls.add(activity.url)
        items.append(
            DashboardItem(
                url=activity.url,
                title=activity.title,
                course=activity.course,
                schedule=schedule,
                item_type=activity.module or "task",
            )
        )

    return items


def iter_course_activities(page: dict[str, Any]) -> list[CourseActivity]:
    html = page.get("html", "")
    if not html or looks_like_login_page(page):
        return []

    soup = BeautifulSoup(html, "html.parser")
    course = extract_course_name(page, soup)
    if should_ignore_course_name(course) or should_ignore_course_url(page.get("requestedUrl", "") or page.get("url", "")):
        return []
    activities: list[CourseActivity] = []
    seen_urls: set[str] = set()

    for activity in soup.select("li.activity"):
        link = activity.select_one(".activityinstance a[href*='/mod/']")
        if not link:
            continue

        url = normalize_url(link.get("href", ""))
        if not url or url in seen_urls:
            continue

        seen_urls.add(url)
        title = clean_title(normalize_whitespace(link.get_text(" ", strip=True)))
        row_text = normalize_whitespace(activity.get_text(" ", strip=True))
        activities.append(
            CourseActivity(
                url=url,
                title=title,
                course=course,
                module=extract_activity_type(activity, url),
                row_text=row_text,
            )
        )

    return activities


def supplemental_activity_tier(activity: CourseActivity) -> str:
    if should_ignore_course_name(activity.course):
        return ""
    if activity.module == "courseboard":
        return "primary" if is_primary_courseboard_title(activity.title) else "secondary"
    if activity.module == "folder":
        return "primary"
    if activity.module not in SUPPLEMENTAL_MODULES:
        return ""
    if contains_any_keyword(f"{activity.title} {activity.url}".lower(), INFO_KEYWORDS):
        return "primary"
    return ""


def is_primary_courseboard_title(title: str) -> bool:
    return contains_any_keyword(normalize_whitespace(title).lower(), PRIMARY_BOARD_KEYWORDS)


def parse_supplemental_detail_urls(page: dict[str, Any]) -> list[str]:
    html = page.get("html", "")
    if not html or looks_like_login_page(page):
        return []

    soup = BeautifulSoup(html, "html.parser")
    current_url = page.get("requestedUrl", "") or page.get("url", "")
    current_module = module_name_from_url(current_url)
    urls: list[str] = []
    seen_urls: set[str] = set()

    for link in soup.select("a[href]"):
        url = normalize_url(link.get("href", ""))
        if not url or url in seen_urls or not is_same_klms_url(url):
            continue
        if is_assignment_submission_file_url(url):
            continue
        if not should_follow_supplemental_detail_link(current_url, current_module, url):
            continue

        text = normalize_whitespace(link.get_text(" ", strip=True))
        context_text = link_context_text(link)
        combined = f"{text} {context_text} {url}".lower()
        has_keyword = contains_any_keyword(combined, INFO_KEYWORDS)

        if has_keyword and looks_like_html_page(url):
            seen_urls.add(url)
            urls.append(url)

    return urls


def parse_assignment_index_urls(page: dict[str, Any]) -> list[str]:
    html = page.get("html", "")
    if not html or looks_like_login_page(page):
        return []

    current_url = page.get("requestedUrl", "") or page.get("url", "")
    if should_ignore_course_url(current_url):
        return []

    soup = BeautifulSoup(html, "html.parser")
    course = extract_course_name(page, soup)
    if should_ignore_course_name(course):
        return []

    urls: list[str] = []
    seen_urls: set[str] = set()
    for link in soup.select("a[href*='/mod/assign/index.php?id=']"):
        url = normalize_url(link.get("href", ""))
        if not url or url in seen_urls or not is_same_klms_url(url):
            continue
        seen_urls.add(url)
        urls.append(url)

    return urls


def parse_resource_index_urls(page: dict[str, Any]) -> list[str]:
    html = page.get("html", "")
    if not html or looks_like_login_page(page):
        return []

    current_url = page_requested_url(page)
    if should_ignore_course_url(current_url):
        return []

    soup = BeautifulSoup(html, "html.parser")
    course = extract_course_name(page, soup)
    if should_ignore_course_name(course):
        return []

    urls: list[str] = []
    seen_urls: set[str] = set()
    for link in soup.select("a[href*='/mod/resource/index.php?id=']"):
        url = normalize_url(link.get("href", ""))
        if not url or url in seen_urls or not is_same_klms_url(url):
            continue
        seen_urls.add(url)
        urls.append(url)

    return urls


def normalize_course_link_title(text: str) -> str:
    candidate = clean_title(normalize_whitespace(text))
    if not candidate:
        return ""
    return normalize_whitespace(re.sub(r"\s*\([^)]+_20\d{2}_\d[^)]*\)\s*$", "", candidate))


def extract_course_name(page: dict[str, Any], soup: BeautifulSoup) -> str:
    title = normalize_whitespace(page.get("title", ""))
    if title.startswith("강좌:"):
        return normalize_whitespace(title.removeprefix("강좌:"))

    breadcrumb_links = soup.select(
        "nav a[href*='/course/view.php?id='], .breadcrumb a[href*='/course/view.php?id=']"
    )
    for link in breadcrumb_links:
        course_name = normalize_course_link_title(link.get_text(" ", strip=True))
        if course_name and course_name != "강의실 메인" and not should_ignore_course_name(course_name):
            return course_name

    generic_links = soup.select("a[href*='/course/view.php?id=']")
    for link in generic_links[:5]:
        course_name = normalize_course_link_title(link.get_text(" ", strip=True))
        if course_name and course_name != "강의실 메인" and not should_ignore_course_name(course_name):
            return course_name

    for link in generic_links[:5]:
        course_name = normalize_course_link_title(link.get_text(" ", strip=True))
        if course_name and course_name != "강의실 메인":
            return course_name

    heading = normalize_whitespace(text_of_first(soup.select("header h1, #page-header h1, h1")))
    if "/course/view.php" in (page.get("requestedUrl", "") or page.get("url", "")) and heading:
        return heading

    return ""


def build_course_class_time_lookup(pages: list[dict[str, Any]]) -> dict[str, list[ClassTimeRange]]:
    lookup: dict[str, list[ClassTimeRange]] = {}
    for page in pages:
        if looks_like_login_page(page):
            continue

        soup = BeautifulSoup(page.get("html", ""), "html.parser")
        course = (
            normalize_whitespace(str(page.get("course", "")))
            or extract_course_name(page, soup)
        )
        if not course or should_ignore_course_name(course) or should_ignore_course_url(page_requested_url(page)):
            continue

        page_text = extract_page_text(page, soup)
        ranges = parse_weekly_class_time_ranges(page_text, source="page", require_keyword=True)
        if ranges:
            merge_class_time_ranges_for_course(lookup, course, ranges)

    return lookup


def merge_class_time_lookups(
    *lookups: dict[str, list[ClassTimeRange]]
) -> dict[str, list[ClassTimeRange]]:
    merged: dict[str, list[ClassTimeRange]] = {}
    for lookup in lookups:
        for course, ranges in lookup.items():
            merge_class_time_ranges_for_course(merged, course, ranges)
    return merged


def merge_class_time_ranges_for_course(
    lookup: dict[str, list[ClassTimeRange]], course: str, ranges: list[ClassTimeRange]
) -> None:
    key = normalize_course_key(course)
    existing = lookup.setdefault(key, [])
    seen = {
        (
            item.weekday,
            item.start_hour,
            item.start_minute,
            item.end_hour,
            item.end_minute,
        )
        for item in existing
    }
    for item in ranges:
        item_key = (
            item.weekday,
            item.start_hour,
            item.start_minute,
            item.end_hour,
            item.end_minute,
        )
        if item_key in seen:
            continue
        existing.append(item)
        seen.add(item_key)


def normalize_course_key(course: str) -> str:
    return normalize_whitespace(course).casefold()


def parse_weekly_class_time_ranges(
    text: str, *, source: str, require_keyword: bool
) -> list[ClassTimeRange]:
    compact = normalize_whitespace(text)
    if not compact:
        return []

    windows = class_time_candidate_windows(compact) if require_keyword else [compact]
    ranges: list[ClassTimeRange] = []
    for window in windows:
        ranges.extend(parse_weekly_class_time_ranges_from_window(window, source=source))
    return dedupe_class_time_ranges(ranges)


def class_time_candidate_windows(text: str) -> list[str]:
    windows: list[str] = []
    for keyword in CLASS_TIME_KEYWORDS:
        for match in re.finditer(re.escape(keyword), text, re.IGNORECASE):
            start = max(0, match.start() - 80)
            end = min(len(text), match.end() + 240)
            windows.append(text[start:end])
    return windows


def parse_weekly_class_time_ranges_from_window(text: str, *, source: str) -> list[ClassTimeRange]:
    day_token = WEEKDAY_TOKEN_PATTERN
    pattern = re.compile(
        rf"(?P<days>{day_token}(?:\s*(?:/|,|&|and|및|와|과)\s*{day_token})*)"
        rf"[^\d]{{0,50}}"
        rf"(?P<start_prefix>오전|오후|AM|PM)?\s*"
        rf"(?P<start_hour>\d{{1,2}})(?:(?::|h)\s*(?P<start_minute>\d{{2}}))?"
        rf"\s*(?P<start_suffix>AM|PM|오전|오후)?\s*"
        rf"(?:부터|~|-|to|–|—)\s*"
        rf"(?P<end_prefix>오전|오후|AM|PM)?\s*"
        rf"(?P<end_hour>\d{{1,2}})(?:(?::|h)\s*(?P<end_minute>\d{{2}}))?"
        rf"\s*(?P<end_suffix>AM|PM|오전|오후)?",
        re.IGNORECASE,
    )

    ranges: list[ClassTimeRange] = []
    for match in pattern.finditer(text):
        weekdays = parse_weekday_tokens(match.group("days"))
        start_hour, start_minute = parse_class_clock_groups(
            match.group("start_hour"),
            match.group("start_minute"),
            match.group("start_prefix"),
            match.group("start_suffix"),
            text,
        )
        end_hour, end_minute = parse_class_clock_groups(
            match.group("end_hour"),
            match.group("end_minute"),
            match.group("end_prefix"),
            match.group("end_suffix"),
            text,
        )
        if not weekdays or not valid_clock(start_hour, start_minute) or not valid_clock(end_hour, end_minute):
            continue

        for weekday in weekdays:
            ranges.append(
                ClassTimeRange(
                    weekday=weekday,
                    start_hour=start_hour,
                    start_minute=start_minute,
                    end_hour=end_hour,
                    end_minute=end_minute,
                    source=source,
                )
            )

    return ranges


def parse_weekday_tokens(text: str) -> list[int]:
    weekdays: list[int] = []
    seen: set[int] = set()
    for match in re.finditer(WEEKDAY_TOKEN_PATTERN, text, re.IGNORECASE):
        weekday = weekday_token_to_index(match.group(0))
        if weekday is None or weekday in seen:
            continue
        weekdays.append(weekday)
        seen.add(weekday)
    return weekdays


def weekday_token_to_index(token: str) -> int | None:
    normalized = normalize_whitespace(token).casefold()
    if normalized.startswith("월") or normalized.startswith("mon"):
        return 0
    if normalized.startswith("화") or normalized.startswith("tue"):
        return 1
    if normalized.startswith("수") or normalized.startswith("wed"):
        return 2
    if normalized.startswith("목") or normalized.startswith("thu"):
        return 3
    if normalized.startswith("금") or normalized.startswith("fri"):
        return 4
    if normalized.startswith("토") or normalized.startswith("sat"):
        return 5
    if normalized.startswith("일") or normalized.startswith("sun"):
        return 6
    return None


def parse_class_clock_groups(
    hour_text: str | None,
    minute_text: str | None,
    prefix: str | None,
    suffix: str | None,
    context: str,
) -> tuple[int, int]:
    hour = int(hour_text or "0")
    minute = int(minute_text or "0")
    meridiem = normalize_whitespace(prefix or suffix or "").casefold()
    if meridiem in {"pm", "오후"}:
        hour = hour % 12 + 12
    elif meridiem in {"am", "오전"}:
        hour = hour % 12
    elif "afternoon" in context.casefold() and hour < 12:
        hour += 12
    return hour, minute


def parse_standalone_class_clock(text: str) -> tuple[int, int] | None:
    pattern = re.compile(
        r"^(?P<prefix>오전|오후|AM|PM)?\s*"
        r"(?P<hour>\d{1,2})(?:(?::|h)\s*(?P<minute>\d{2}))?"
        r"\s*(?P<suffix>AM|PM|오전|오후)?$",
        re.IGNORECASE,
    )
    match = pattern.match(normalize_whitespace(text))
    if not match:
        return None
    hour, minute = parse_class_clock_groups(
        match.group("hour"),
        match.group("minute"),
        match.group("prefix"),
        match.group("suffix"),
        text,
    )
    if not valid_clock(hour, minute):
        return None
    return hour, minute


def valid_clock(hour: int, minute: int) -> bool:
    return 0 <= hour <= 23 and 0 <= minute <= 59


def dedupe_class_time_ranges(ranges: list[ClassTimeRange]) -> list[ClassTimeRange]:
    deduped: list[ClassTimeRange] = []
    seen: set[tuple[int, int, int, int, int]] = set()
    for item in ranges:
        key = (
            item.weekday,
            item.start_hour,
            item.start_minute,
            item.end_hour,
            item.end_minute,
        )
        if key in seen:
            continue
        deduped.append(item)
        seen.add(key)
    return deduped


def should_track_course_item(url: str, title: str, schedule: str) -> bool:
    module = module_name_from_url(url)
    if module in {"assign", "quiz"}:
        return True
    if schedule:
        if looks_like_non_assignment_schedule_item(module, title):
            return False
        return True

    lowered_title = title.lower()
    return any(keyword in lowered_title for keyword in ("quiz", "assignment", "homework", "nano quiz"))


def looks_like_non_assignment_schedule_item(module: str, title: str) -> bool:
    if module not in NON_ASSIGNMENT_SCHEDULE_MODULES:
        return False

    lowered_title = normalize_whitespace(title).lower()
    if not lowered_title:
        return False

    task_keywords = (
        "quiz",
        "assignment",
        "homework",
        "project",
        "deadline",
        "due",
        "submit",
        "submission",
        "hw",
    )
    if contains_any_keyword(lowered_title, task_keywords):
        return False

    return contains_any_keyword(lowered_title, NON_ASSIGNMENT_SCHEDULE_KEYWORDS)


def extract_activity_type(activity: Any, url: str) -> str:
    classes = activity.get("class", [])
    for cls in classes:
        if cls.startswith("modtype_"):
            return cls.removeprefix("modtype_")
    return module_name_from_url(url) or "task"


def module_name_from_url(url: str) -> str:
    match = re.search(r"/mod/([^/]+)/", url)
    if match:
        return match.group(1)
    return ""


def looks_like_login_page(page: dict[str, Any]) -> bool:
    url = (page.get("url") or "").lower()
    title = (page.get("title") or "").lower()
    html = (page.get("html") or "").lower()
    return (
        "login" in url
        or "log in" in title
        or "portal.kaist.ac.kr" in url
        or 'name="username"' in html
        or "single sign on" in html
    )


def analyze_login_status(pages: list[dict[str, Any]]) -> dict[str, Any]:
    if not pages:
        return {
            "status": "error",
            "error": "empty_pages",
            "message": "KLMS 대시보드 확인에 실패했어. 다시 시도해 줘.",
            "url": "",
            "title": "",
        }

    page = pages[0] if isinstance(pages[0], dict) else {}
    url = str(page.get("url") or page.get("finalUrl") or page.get("requestedUrl") or "")
    title = str(page.get("title") or "")
    if looks_like_login_page(page):
        return {
            "status": "error",
            "error": "login_required",
            "message": "KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘.",
            "url": url,
            "title": title,
        }

    return {
        "status": "ok",
        "error": "",
        "message": "",
        "url": url,
        "title": title,
    }


def parse_detail_page(page: dict[str, Any]) -> dict[str, Any]:
    if looks_like_login_page(page):
        return {"status": "error", "error": "login_required", "url": page.get("requestedUrl", "")}

    soup = BeautifulSoup(page.get("html", ""), "html.parser")
    heading = normalize_whitespace(text_of_first(soup.select("h2")))
    intro = normalize_whitespace(
        text_of_first(
            soup.select("#urlintro .no-overflow")
            or soup.select("#intro .no-overflow")
            or soup.select("#intro")
            or soup.select(".activity-description")
            or soup.select(".generalbox")
        )
    )
    table_rows = {}
    for row in soup.select("table.generaltable tr"):
        header = normalize_whitespace(text_of_first(row.select("th")))
        value = normalize_whitespace(text_of_first(row.select("td")))
        if header:
            table_rows[header] = value

    due = table_rows.get("마감 일시") or table_rows.get("Due date") or extract_due_text(intro) or ""

    return {
        "status": "ok",
        "title": heading,
        "instructions": strip_due_text(intro),
        "due": due,
        "submission": table_rows.get("제출 상태") or "",
        "grading": table_rows.get("채점 상태") or "",
    }


def merge_assignment(item: DashboardItem, detail: dict[str, Any] | None) -> dict[str, Any]:
    detail = detail or {}
    instructions = detail.get("instructions") or ""
    title = clean_title(detail.get("title") or item.title)
    due = detail.get("due") or item.schedule
    submission = detail.get("submission") or ""
    sort_due = parse_due_datetime(due)

    return {
        "url": item.url,
        "type": item.item_type,
        "category": "assignment",
        "course": item.course,
        "title": title,
        "schedule": item.schedule,
        "due": due,
        "submission": submission,
        "instructions": instructions,
        "timing_precision": infer_timing_precision(due),
        "time_source": "notice" if infer_timing_precision(due) != "date" else "date_only",
        "sort_due": sort_due,
        "sync_due": sort_due.isoformat() if sort_due else "",
        "source_title": "",
    }


def assignment_should_be_exam_item(assignment: dict[str, Any]) -> bool:
    title = normalize_whitespace(str(assignment.get("title", "")))
    lowered_title = title.lower()
    if not title or not find_exam_label_matches(title):
        return False
    if contains_any_keyword(lowered_title, HELP_DESK_KEYWORDS):
        return False
    if contains_any_keyword(
        lowered_title,
        (
            "solution",
            "solutions",
            "answer",
            "answers",
            "score",
            "scores",
            "grading",
            "review",
            "해설",
            "정답",
            "답안",
            "점수",
            "채점",
        ),
    ):
        return False
    return True


def assignment_to_exam_item(assignment: dict[str, Any]) -> dict[str, Any]:
    exam_item = dict(assignment)
    exam_item["type"] = "exam"
    exam_item["category"] = "exam"
    exam_item["title"] = normalize_whitespace(str(assignment.get("title", ""))) or normalize_exam_title(
        str(assignment.get("title", ""))
    )
    exam_item["source_title"] = assignment.get("title", "")
    exam_item["submission"] = ""
    exam_item["location"] = resolve_exam_location_from_text(
        str(assignment.get("instructions", "")), str(assignment.get("url", ""))
    )
    coverage = extract_exam_coverage(str(assignment.get("instructions", "")))
    exam_item["coverage"] = coverage
    exam_item["coverage_summary"] = summarize_exam_coverage_for_calendar(coverage)
    exam_item["approval_status"] = "approved"
    return exam_item


def dedupe_sync_items(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[tuple[str, str, str, str]] = set()
    deduped: list[dict[str, Any]] = []
    for item in items:
        key = (
            normalize_whitespace(str(item.get("url", ""))),
            normalize_whitespace(str(item.get("title", ""))),
            normalize_whitespace(str(item.get("sync_due") or item.get("due", ""))),
            normalize_whitespace(str(item.get("category", ""))),
        )
        if key in seen:
            continue
        seen.add(key)
        deduped.append(item)
    return deduped


def is_hidden_by_override(assignment: dict[str, Any], overrides: dict[str, str]) -> bool:
    status = overrides.get(assignment["url"], "").strip().lower()
    return status in {"ignored", "completed"}


def is_completed_assignment(assignment: dict[str, Any]) -> bool:
    if assignment.get("category") == "exam":
        return False
    if assignment.get("auto_completed"):
        return True
    submission = " ".join(str(assignment.get("submission") or "").split()).strip().lower().rstrip(".")
    if submission in COMPLETED_ASSIGNMENT_SUBMISSION_STATUSES:
        return True
    sort_due = assignment.get("sort_due")
    if isinstance(sort_due, datetime) and sort_due <= datetime.now(SEOUL):
        return True
    return False


def extract_assignment_candidate_items(
    pages: list[dict[str, Any]],
    assignments: list[dict[str, Any]],
    course_lookup: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    items_by_key: dict[tuple[str, str, str], dict[str, Any]] = {}
    course_lookup = course_lookup or {}
    existing_labels = build_existing_assignment_candidate_labels(assignments)

    for page in pages:
        if looks_like_login_page(page):
            continue

        requested_url = page.get("requestedUrl", "") or page.get("url", "")
        page_identifier = url_query_id(requested_url)
        explicit_course = normalize_whitespace(str(page.get("course", "")))
        if course_lookup and page_identifier and page_identifier not in course_lookup and not explicit_course:
            continue
        if (
            module_name_from_url(requested_url) == "courseboard"
            and "/article.php" not in requested_url
            and "bwid=" not in requested_url
        ):
            continue
        if is_document_url(requested_url):
            continue

        soup = BeautifulSoup(page.get("html", ""), "html.parser")
        course = (
            course_lookup.get(url_query_id(requested_url), "")
            or explicit_course
            or extract_course_name(page, soup)
        )
        if should_ignore_course_name(course) or should_ignore_course_url(requested_url):
            continue

        page_title = clean_title(normalize_whitespace(page.get("title", "")))
        page_text = extract_page_text(page, soup)
        combined_index = f"{page_title}\n{page_text}".lower()
        if not contains_any_keyword(combined_index, ASSIGNMENT_CANDIDATE_KEYWORDS):
            continue

        source_title = determine_source_title(page_title, soup, course)
        if looks_like_assignment_resolution_notice(source_title, page_title, page_text):
            continue

        for chunk in candidate_assignment_chunks(page_title, page_text):
            if looks_like_assignment_resolution_notice(source_title, chunk):
                continue

            title = extract_assignment_candidate_title(source_title, page_title, chunk)
            if not title:
                continue
            if assignment_candidate_matches_existing_assignment(course, title, existing_labels):
                continue

            date_matches = find_date_snippets(chunk)
            if not date_matches:
                continue

            date_match = select_assignment_candidate_date_match(chunk, date_matches)
            if not date_match:
                continue

            assignment_schedule = resolve_assignment_candidate_schedule(date_match)
            key = (course, title, assignment_schedule["sync_due"])
            if key in items_by_key:
                continue

            items_by_key[key] = {
                "url": page.get("requestedUrl") or page.get("url") or "",
                "type": "assignment_candidate",
                "category": "assignment_candidate",
                "course": course,
                "title": title,
                "due": assignment_schedule["due"],
                "submission": "",
                "instructions": summarize_instructions(chunk),
                "timing_precision": assignment_schedule["timing_precision"],
                "time_source": assignment_schedule.get("time_source", ""),
                "sort_due": assignment_schedule["sort_due"],
                "sync_due": assignment_schedule["sync_due"],
                "source_title": source_title,
            }

    return sorted(items_by_key.values(), key=assignment_sort_key)


def activate_notice_assignments(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    active_items: list[dict[str, Any]] = []
    now = datetime.now(SEOUL)

    for item in items:
        normalized = dict(item)
        normalized["type"] = "assignment_notice"
        normalized["category"] = "assignment"
        sort_due = normalized.get("sort_due")
        if sort_due and sort_due <= now:
            normalized["auto_completed"] = True
            continue
        active_items.append(normalized)

    return sorted(active_items, key=assignment_sort_key)


def extract_exam_items(pages: list[dict[str, Any]], course_lookup: dict[str, str] | None = None) -> list[dict[str, Any]]:
    items_by_key: dict[tuple[str, str, str], dict[str, Any]] = {}
    course_lookup = course_lookup or {}

    for page in pages:
        if looks_like_login_page(page):
            continue

        requested_url = page.get("requestedUrl", "") or page.get("url", "")
        page_identifier = url_query_id(requested_url)
        if course_lookup and page_identifier and page_identifier not in course_lookup:
            continue
        if (
            module_name_from_url(requested_url) == "courseboard"
            and "/article.php" not in requested_url
            and "bwid=" not in requested_url
        ):
            continue
        if is_document_url(requested_url):
            continue

        soup = BeautifulSoup(page.get("html", ""), "html.parser")
        course = course_lookup.get(url_query_id(requested_url), "") or extract_course_name(page, soup)
        if should_ignore_course_name(course) or should_ignore_course_url(requested_url):
            continue
        page_title = clean_title(normalize_whitespace(page.get("title", "")))
        page_text = extract_page_text(page, soup)
        combined_index = f"{page_title}\n{page_text}".lower()
        if not contains_any_keyword(combined_index, INFO_KEYWORDS):
            continue

        source_title = determine_source_title(page_title, soup, course)
        if looks_like_exam_source_false_positive(page_title, source_title):
            continue
        for chunk in candidate_exam_chunks(page_title, page_text):
            if looks_like_help_desk_context(page_title, source_title, chunk):
                continue
            labels = list(find_exam_label_matches(chunk))
            if not labels:
                continue

            date_matches = find_date_snippets(chunk)
            if not date_matches:
                continue

            for label in labels:
                title = normalize_exam_title(f"{label.group(0)} {page_title} {source_title}")
                date_match = select_exam_date_match(chunk, label, date_matches)
                if not date_match:
                    continue
                exam_schedule = resolve_exam_schedule(chunk, date_match)
                key = (course, title, exam_schedule["sync_due"])
                if key in items_by_key:
                    continue
                instructions = normalize_whitespace(chunk)
                coverage = extract_exam_coverage(chunk)

                items_by_key[key] = {
                    "url": page.get("requestedUrl") or page.get("url") or "",
                    "type": "exam",
                    "category": "exam",
                    "course": course,
                    "title": title,
                    "due": exam_schedule["due"],
                    "submission": "",
                    "instructions": instructions,
                    "location": resolve_exam_location_from_text(chunk, requested_url),
                    "coverage": coverage,
                    "coverage_summary": summarize_exam_coverage_for_calendar(coverage),
                    "timing_precision": exam_schedule["timing_precision"],
                    "time_source": exam_schedule.get("time_source", ""),
                    "sort_due": exam_schedule["sort_due"],
                    "sync_start": exam_schedule.get("sync_start", ""),
                    "sync_due": exam_schedule["sync_due"],
                    "source_title": source_title,
                }

    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for item in items_by_key.values():
        grouped.setdefault((item["url"], item["title"]), []).append(item)

    resolved_items: list[dict[str, Any]] = []
    for group in grouped.values():
        if len(group) > 1:
            resolved_items.append(max(group, key=lambda item: item["sort_due"]))
            continue
        resolved_items.extend(group)

    return sorted(resolved_items, key=assignment_sort_key)


def extract_help_desk_items(
    pages: list[dict[str, Any]], course_lookup: dict[str, str] | None = None
) -> list[dict[str, Any]]:
    items_by_key: dict[tuple[str, str, str], dict[str, Any]] = {}
    course_lookup = course_lookup or {}

    for page in pages:
        if looks_like_login_page(page):
            continue

        requested_url = page.get("requestedUrl", "") or page.get("url", "")
        page_identifier = url_query_id(requested_url)
        if course_lookup and page_identifier and page_identifier not in course_lookup:
            continue
        if (
            module_name_from_url(requested_url) == "courseboard"
            and "/article.php" not in requested_url
            and "bwid=" not in requested_url
        ):
            continue
        if is_document_url(requested_url):
            continue

        soup = BeautifulSoup(page.get("html", ""), "html.parser")
        course = course_lookup.get(url_query_id(requested_url), "") or extract_course_name(page, soup)
        if should_ignore_course_name(course) or should_ignore_course_url(requested_url):
            continue
        page_title = clean_title(normalize_whitespace(page.get("title", "")))
        page_text = extract_page_text(page, soup)
        combined_index = f"{page_title}\n{page_text}".lower()
        if not contains_any_keyword(combined_index, HELP_DESK_KEYWORDS):
            continue

        source_title = determine_source_title(page_title, soup, course)
        for chunk in candidate_help_desk_chunks(page_title, page_text):
            labels = list(find_help_desk_label_matches(chunk))
            if not labels:
                continue

            date_matches = find_date_snippets(chunk)
            if not date_matches:
                continue

            for label in labels:
                date_match = select_help_desk_date_match(chunk, label, date_matches)
                if not date_match:
                    continue

                help_desk_schedule = resolve_help_desk_schedule(chunk, date_match)
                title = normalize_help_desk_title(label.group(0))
                key = (course, title, help_desk_schedule["sync_due"])
                if key in items_by_key:
                    continue

                items_by_key[key] = {
                    "url": page.get("requestedUrl") or page.get("url") or "",
                    "type": "help_desk",
                    "category": "help_desk",
                    "course": course,
                    "title": title,
                    "due": help_desk_schedule["due"],
                    "submission": "",
                    "instructions": summarize_instructions(chunk),
                    "timing_precision": help_desk_schedule["timing_precision"],
                    "time_source": help_desk_schedule.get("time_source", ""),
                    "sort_due": help_desk_schedule["sort_due"],
                    "sync_start": help_desk_schedule.get("sync_start", ""),
                    "sync_due": help_desk_schedule["sync_due"],
                    "source_title": source_title,
                }

    return sorted(items_by_key.values(), key=assignment_sort_key)


def apply_exam_overrides(
    items: list[dict[str, Any]],
    overrides: dict[str, dict[str, str]],
    *,
    default_status: str = "candidate",
) -> list[dict[str, Any]]:
    updated_items: list[dict[str, Any]] = []
    for item in items:
        override = resolve_exam_override(item, overrides)
        updated = dict(item)
        updated["approval_status"] = exam_approval_status(override, default_status=default_status)

        if not override:
            updated_items.append(updated)
            continue

        sync_start = parse_override_datetime(override.get("sync_start"))
        sync_due = parse_override_datetime(override.get("sync_due")) or updated.get("sort_due")

        if sync_start:
            updated["sync_start"] = sync_start.isoformat()
        if sync_due:
            updated["sort_due"] = sync_due
            updated["sync_due"] = sync_due.isoformat()

        if override.get("due"):
            updated["due"] = override["due"]
        elif sync_start and sync_due:
            updated["due"] = format_schedule_range(sync_start, sync_due)

        if override.get("timing_precision"):
            updated["timing_precision"] = override["timing_precision"]
        elif sync_start and sync_due:
            updated["timing_precision"] = "time-range"

        if sync_start and sync_due:
            updated["time_source"] = "override"

        if override.get("location"):
            updated["location"] = override["location"]
        if override.get("coverage"):
            updated["coverage"] = override["coverage"]
        if override.get("coverage_summary"):
            updated["coverage_summary"] = override["coverage_summary"]

        instructions_append = normalize_whitespace(override.get("instructions_append", ""))
        if instructions_append:
            instructions = normalize_whitespace(updated.get("instructions", ""))
            if instructions_append not in instructions:
                updated["instructions"] = (
                    f"{instructions}\n{instructions_append}" if instructions else instructions_append
                )
            if not updated.get("coverage"):
                updated["coverage"] = extract_exam_coverage(str(updated.get("instructions", "")))
            if not updated.get("coverage_summary"):
                updated["coverage_summary"] = summarize_exam_coverage_for_calendar(
                    str(updated.get("coverage", ""))
                )
            if not updated.get("location"):
                updated["location"] = resolve_exam_location_from_text(
                    str(updated.get("instructions", "")), str(updated.get("url", ""))
                )

        updated_items.append(updated)

    return sorted(updated_items, key=assignment_sort_key)


def split_exam_items_for_confirmation(
    items: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    approved: list[dict[str, Any]] = []
    candidates: list[dict[str, Any]] = []

    for item in items:
        normalized = dict(item)
        status = str(normalized.pop("approval_status", "candidate")).strip().lower()
        if status in {"ignored", "hidden", "skip", "completed"}:
            continue
        if status in {"approved", "confirmed", "active"}:
            normalized["category"] = "exam"
            approved.append(normalized)
            continue

        normalized["category"] = "exam_candidate"
        candidates.append(normalized)

    return approved, candidates


def resolve_exam_override(
    item: dict[str, Any], overrides: dict[str, dict[str, str]]
) -> dict[str, str] | None:
    url = str(item.get("url", "")).strip()
    title = normalize_whitespace(str(item.get("title", "")))
    course = normalize_whitespace(str(item.get("course", "")))
    due = normalize_whitespace(str(item.get("due", "")))

    candidate_keys = [
        f"{url}::{title}" if url and title else "",
        url,
        f"{course}::{title}::{due}" if course and title and due else "",
        f"{course}::{title}" if course and title else "",
    ]
    for key in candidate_keys:
        if key and key in overrides:
            return overrides[key]
    return None


def exam_approval_status(override: dict[str, str] | None, *, default_status: str = "candidate") -> str:
    if not override:
        return default_status

    status = normalize_whitespace(str(override.get("status", ""))).lower()
    if status:
        return status
    return "approved"


def parse_override_datetime(value: str | None) -> datetime | None:
    text = normalize_whitespace(value or "")
    if not text:
        return None

    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None

    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=SEOUL)
    return parsed.astimezone(SEOUL)


def determine_source_title(page_title: str, soup: BeautifulSoup, course: str) -> str:
    heading = normalize_whitespace(
        text_of_first(
            soup.select(
                ".courseboard .subject h3, .courseboard .subject, #region-main .subject h3, #region-main .subject, #page-header h1, header h1, h1, h2"
            )
        )
    )
    for candidate in (heading, page_title):
        cleaned = clean_title(candidate)
        if cleaned and cleaned != course:
            return cleaned
    return page_title or heading or ""


def extract_page_text(page: dict[str, Any], soup: BeautifulSoup) -> str:
    html = page.get("html", "")
    if not html:
        return ""

    text = page.get("text")
    if isinstance(text, str) and normalize_whitespace(text):
        return text

    requested_url = page_requested_url(page).lower()
    if module_name_from_url(requested_url) == "courseboard" and (
        "/article.php" in requested_url or "bwid=" in requested_url
    ):
        article_body = normalize_whitespace(
            text_of_first(soup.select(".courseboard .content, .courseboard .no-overflow"))
        )
        if article_body:
            return article_body

    return soup.get_text("\n", strip=True)


def candidate_exam_chunks(page_title: str, page_text: str) -> list[str]:
    chunks: list[str] = []
    seen: set[str] = set()

    def add(value: str) -> None:
        chunk = normalize_whitespace(value)
        if not chunk or chunk in seen:
            return
        if not contains_any_keyword(chunk.lower(), EXAM_KEYWORDS):
            return
        seen.add(chunk)
        chunks.append(chunk)

    add(page_title)
    lines = [normalize_whitespace(line) for line in page_text.splitlines() if normalize_whitespace(line)]
    for index, line in enumerate(lines):
        if not contains_any_keyword(line.lower(), EXAM_KEYWORDS):
            continue
        add(line)
        for span in range(2, 6):
            tail = lines[index : index + span]
            if len(tail) >= 2:
                add(" ".join(tail))

    return chunks


def candidate_help_desk_chunks(page_title: str, page_text: str) -> list[str]:
    chunks: list[str] = []
    seen: set[str] = set()

    def add(value: str) -> None:
        chunk = normalize_whitespace(value)
        if not chunk or chunk in seen:
            return
        if not contains_any_keyword(chunk.lower(), HELP_DESK_KEYWORDS):
            return
        seen.add(chunk)
        chunks.append(chunk)

    add(page_title)
    lines = [normalize_whitespace(line) for line in page_text.splitlines() if normalize_whitespace(line)]
    for index, line in enumerate(lines):
        if not contains_any_keyword(line.lower(), HELP_DESK_KEYWORDS):
            continue
        add(line)
        for span in range(2, 6):
            tail = lines[index : index + span]
            if len(tail) >= 2:
                add(" ".join(tail))

    return chunks


def candidate_assignment_chunks(page_title: str, page_text: str) -> list[str]:
    chunks: list[str] = []
    seen: set[str] = set()

    def add(value: str) -> None:
        chunk = normalize_whitespace(value)
        if not chunk or chunk in seen:
            return
        if not looks_like_assignment_candidate_context(chunk):
            return
        seen.add(chunk)
        chunks.append(chunk)

    lines = [normalize_whitespace(line) for line in page_text.splitlines() if normalize_whitespace(line)]
    add(page_title)
    if lines:
        add(" ".join([page_title] + lines[:4]))

    for index, line in enumerate(lines):
        lowered = line.lower()
        if not (
            contains_any_keyword(lowered, ASSIGNMENT_CANDIDATE_KEYWORDS)
            or contains_any_keyword(lowered, ASSIGNMENT_CANDIDATE_CONTEXT_KEYWORDS)
        ):
            continue

        for span in range(1, 6):
            tail = lines[index : index + span]
            if not tail:
                continue
            chunk_parts = [page_title] + tail
            add(" ".join(part for part in chunk_parts if part))

    return chunks


def looks_like_relative_exam_reference(chunk: str, label: re.Match[str]) -> bool:
    lowered_chunk = chunk.lower()
    window_start = max(0, label.start() - 32)
    window_end = min(len(lowered_chunk), label.end() + 48)
    window = lowered_chunk[window_start:window_end]

    if re.search(r"(중간(?:고사|시험)?|기말(?:고사|시험)?|시험)\s*(직전|직후|이전|이후)", window):
        return True
    if re.search(r"\b(?:before|after|prior to|following)\b.{0,16}\b(?:midterm|final)\s+exam\b", window):
        return True
    return False


def select_exam_date_match(
    chunk: str, label: re.Match[str], date_matches: list[DateSnippet]
) -> DateSnippet | None:
    lowered_chunk = chunk.lower()
    if looks_like_relative_exam_reference(chunk, label):
        return None

    trailing_dates = [item for item in date_matches if item.start >= label.start()]
    if not trailing_dates:
        return min(date_matches, key=lambda item: abs(item.start - label.start()))

    for marker in ("new date", "updated date", "변경 일정", "변경 일시", "new time", "변경 시간"):
        marker_index = lowered_chunk.find(marker)
        if marker_index >= 0:
            for item in trailing_dates:
                if item.start >= marker_index:
                    return item

    if any(keyword in lowered_chunk for keyword in ("reschedul", "postpon", "연기", "변경")):
        return trailing_dates[-1]

    return trailing_dates[0]


def looks_like_reschedule_notice(text: str) -> bool:
    lowered = text.lower()
    return any(keyword in lowered for keyword in ("reschedul", "postpon", "original date", "new date", "연기", "변경 일정", "기존 일정"))


def looks_like_help_desk_context(*values: str) -> bool:
    combined = " ".join(normalize_whitespace(value).lower() for value in values if value)
    return contains_any_keyword(combined, HELP_DESK_KEYWORDS)


def looks_like_exam_source_false_positive(*values: str) -> bool:
    combined = " ".join(normalize_whitespace(value).lower() for value in values if value)
    if contains_any_keyword(combined, EXAM_TITLE_KEYWORDS):
        return False
    return contains_any_keyword(combined, EXAM_FALSE_POSITIVE_SOURCE_KEYWORDS)


def looks_like_assignment_candidate_context(text: str) -> bool:
    compact = normalize_whitespace(text)
    lowered = compact.lower()
    if not contains_any_keyword(lowered, ASSIGNMENT_CANDIDATE_KEYWORDS):
        return False
    if contains_any_keyword(lowered, ASSIGNMENT_CANDIDATE_IGNORE_KEYWORDS):
        return False
    # Midterm/final notices often mention WA/PA ranges like "WA 1-2 and PA 1-2"
    # as coverage, which should not become assignment items on their own.
    if contains_any_keyword(lowered, EXAM_TITLE_KEYWORDS) and not contains_any_keyword(
        lowered, ASSIGNMENT_CANDIDATE_CONTEXT_KEYWORDS
    ):
        return False
    if contains_any_keyword(lowered, ASSIGNMENT_CANDIDATE_CONTEXT_KEYWORDS):
        return True
    return bool(find_assignment_label_matches(compact)) and bool(find_date_snippets(compact))


def looks_like_assignment_resolution_notice(*values: str) -> bool:
    normalized_values = [normalize_whitespace(value).lower() for value in values if value]
    if not normalized_values:
        return False

    # Keep resolution filtering title-centric. Project/assignment announcements often
    # mention "score" or grading semantics in the body, but the title still signals
    # that the notice is an active assignment release.
    title_candidates = normalized_values[:2]
    if any(
        contains_any_keyword(candidate, ASSIGNMENT_CANDIDATE_CONTEXT_KEYWORDS)
        for candidate in title_candidates
    ):
        return False

    return any(
        contains_any_keyword(candidate, ASSIGNMENT_CANDIDATE_KEYWORDS)
        and contains_any_keyword(candidate, ASSIGNMENT_CANDIDATE_IGNORE_KEYWORDS)
        for candidate in title_candidates
    )


def find_exam_label_matches(text: str) -> list[re.Match[str]]:
    pattern = re.compile(
        r"mid-?term(?:\s+exam)?|final(?:\s+exam)?|중간(?:고사|시험)?|기말(?:고사|시험)?|(?<![A-Za-z])exam(?![A-Za-z])|시험",
        re.IGNORECASE,
    )
    return list(pattern.finditer(text))


def find_help_desk_label_matches(text: str) -> list[re.Match[str]]:
    pattern = re.compile(
        r"midterm(?:\s+exam)?\s+help\s*desk|final(?:\s+exam)?\s+help\s*desk|help\s*desk\s+for\s+(?:the\s+)?midterm(?:\s+exam)?|help\s*desk\s+for\s+(?:the\s+)?final(?:\s+exam)?|중간(?:고사|시험)?\s*헬프데스크|기말(?:고사|시험)?\s*헬프데스크|헬프데스크",
        re.IGNORECASE,
    )
    return list(pattern.finditer(text))


def find_assignment_label_matches(text: str) -> list[re.Match[str]]:
    pattern = re.compile(
        r"programming\s+assignment\s*#?\s*\d+|written\s+assignment\s*#?\s*\d+|assignment\s*#?\s*\d+|homework\s*#?\s*\d+|hw\s*#?\s*\d+|pa\s*#?\s*\d+|wa\s*#?\s*\d+|project\s*#?\s*\d+|term\s+project|quiz\s*#?\s*\d+|\d+\s*주차\s*과제|과제\s*\d+|숙제\s*\d+|퀴즈\s*\d+",
        re.IGNORECASE,
    )
    return list(pattern.finditer(text))


def extract_assignment_candidate_title(*values: str) -> str:
    for value in values:
        matches = find_assignment_label_matches(value)
        if not matches:
            continue
        return normalize_assignment_candidate_title(matches[0].group(0))
    return ""


def normalize_exam_title(text: str) -> str:
    lowered = text.lower()
    if "midterm" in lowered or "중간" in text:
        return "중간고사"
    if "final" in lowered or "기말" in text:
        return "기말고사"
    return "시험"


def normalize_help_desk_title(text: str) -> str:
    lowered = text.lower()
    if "midterm" in lowered or "중간" in text:
        return "중간고사 헬프데스크"
    if "final" in lowered or "기말" in text:
        return "기말고사 헬프데스크"
    return "시험 헬프데스크"


def normalize_assignment_candidate_title(text: str) -> str:
    compact = normalize_whitespace(text)
    if not compact:
        return ""
    if re.fullmatch(r"(pa|wa|hw)\s*#?\s*\d+", compact, re.IGNORECASE):
        cleaned = re.sub(r"\s*#\s*", "", compact, flags=re.IGNORECASE)
        return cleaned.upper().replace(" ", "")
    return clean_title(compact)


def build_existing_assignment_candidate_labels(
    assignments: list[dict[str, Any]],
) -> dict[str, set[str]]:
    labels_by_course: dict[str, set[str]] = {}
    for item in assignments:
        course = normalize_whitespace(str(item.get("course", "")))
        title = extract_assignment_candidate_title(str(item.get("title", "")))
        if not course or not title:
            continue
        labels_by_course.setdefault(course, set()).add(title.lower())
    return labels_by_course


def assignment_candidate_matches_existing_assignment(
    course: str, title: str, labels_by_course: dict[str, set[str]]
) -> bool:
    normalized_course = normalize_whitespace(course)
    normalized_title = normalize_assignment_candidate_title(title).lower()
    if not normalized_course or not normalized_title:
        return False
    return normalized_title in labels_by_course.get(normalized_course, set())


def select_assignment_candidate_date_match(
    chunk: str, date_matches: list[DateSnippet]
) -> DateSnippet | None:
    lowered_chunk = normalize_whitespace(chunk).lower()
    markers = (
        "deadline",
        "due by",
        "due",
        "submit by",
        "submission deadline",
        "마감",
        "제출 마감",
        "제출",
    )

    for marker in markers:
        marker_index = lowered_chunk.find(marker)
        if marker_index < 0:
            continue
        trailing_dates = [item for item in date_matches if item.start >= marker_index]
        if trailing_dates:
            return trailing_dates[0]

    labels = find_assignment_label_matches(chunk)
    if labels:
        trailing_dates = [item for item in date_matches if item.start >= labels[-1].end()]
        if trailing_dates:
            return trailing_dates[0]

    return date_matches[0] if date_matches else None


def select_help_desk_date_match(
    chunk: str, label: re.Match[str], date_matches: list[DateSnippet]
) -> DateSnippet | None:
    trailing_dates = [item for item in date_matches if item.start >= label.end()]
    if not trailing_dates:
        return None

    first_date = trailing_dates[0]
    context = normalize_whitespace(chunk[label.end() : first_date.start]).lower()
    if len(context) > 180:
        return None
    if any(
        keyword in context
        for keyword in (
            "announced later",
            "will be announced later",
            "later",
            "추후",
            "이전글",
            "previous",
            "다음글",
            "next article",
        )
    ):
        return None

    return first_date


def resolve_help_desk_schedule(chunk: str, date_match: DateSnippet) -> dict[str, Any]:
    schedule = {
        "due": date_match.text,
        "timing_precision": date_match.timing_precision,
        "time_source": "notice" if date_match.timing_precision != "date" else "date_only",
        "sort_due": date_match.sort_due,
        "sync_due": date_match.sort_due.isoformat(),
    }

    time_range = find_time_range_after_date(chunk, date_match)
    if not time_range:
        return schedule

    start_at, end_at = time_range
    schedule["due"] = format_schedule_range(start_at, end_at)
    schedule["timing_precision"] = "time-range"
    schedule["time_source"] = "notice"
    schedule["sort_due"] = end_at
    schedule["sync_start"] = start_at.isoformat()
    schedule["sync_due"] = end_at.isoformat()
    return schedule


def resolve_assignment_candidate_schedule(date_match: DateSnippet) -> dict[str, Any]:
    return {
        "due": date_match.text,
        "timing_precision": date_match.timing_precision,
        "time_source": "notice" if date_match.timing_precision != "date" else "date_only",
        "sort_due": date_match.sort_due,
        "sync_due": date_match.sort_due.isoformat(),
    }


def resolve_exam_schedule(chunk: str, date_match: DateSnippet) -> dict[str, Any]:
    schedule = {
        "due": date_match.text,
        "timing_precision": date_match.timing_precision,
        "time_source": "notice" if date_match.timing_precision != "date" else "date_only",
        "sort_due": date_match.sort_due,
        "sync_due": date_match.sort_due.isoformat(),
    }

    time_range = find_time_range_after_date(chunk, date_match)
    if not time_range:
        return schedule

    start_at, end_at = time_range
    schedule["due"] = format_schedule_range(start_at, end_at)
    schedule["timing_precision"] = "time-range"
    schedule["time_source"] = "notice"
    schedule["sort_due"] = end_at
    schedule["sync_start"] = start_at.isoformat()
    schedule["sync_due"] = end_at.isoformat()
    return schedule


def apply_exam_class_time_fallback(
    items: list[dict[str, Any]], class_time_lookup: dict[str, list[ClassTimeRange]]
) -> list[dict[str, Any]]:
    if not class_time_lookup:
        return items

    updated_items: list[dict[str, Any]] = []
    for item in items:
        if not exam_item_needs_class_time_fallback(item):
            updated_items.append(item)
            continue

        sort_due = item.get("sort_due")
        if not isinstance(sort_due, datetime):
            updated_items.append(item)
            continue

        class_time = resolve_class_time_for_exam(item.get("course", ""), sort_due, class_time_lookup)
        if not class_time:
            updated_items.append(item)
            continue

        start_at, end_at = build_exam_range_from_class_time(sort_due, class_time)
        updated = dict(item)
        updated["due"] = format_schedule_range(start_at, end_at)
        updated["timing_precision"] = "class-time"
        updated["time_source"] = "class_time"
        updated["sort_due"] = end_at
        updated["sync_start"] = start_at.isoformat()
        updated["sync_due"] = end_at.isoformat()
        updated_items.append(updated)

    return updated_items


def exam_item_needs_class_time_fallback(item: dict[str, Any]) -> bool:
    if item.get("sync_start"):
        return False
    if item.get("timing_precision") == "date":
        return True
    sort_due = item.get("sort_due")
    if not isinstance(sort_due, datetime):
        return False
    return sort_due.hour == 0 and sort_due.minute == 0 and str(item.get("category")) == "exam"


def resolve_class_time_for_exam(
    course: str, exam_date: datetime, class_time_lookup: dict[str, list[ClassTimeRange]]
) -> ClassTimeRange | None:
    ranges = class_time_lookup.get(normalize_course_key(course), [])
    for class_time in ranges:
        if class_time.weekday == exam_date.astimezone(SEOUL).weekday():
            return class_time
    return None


def build_exam_range_from_class_time(
    exam_date: datetime, class_time: ClassTimeRange
) -> tuple[datetime, datetime]:
    local_date = exam_date.astimezone(SEOUL)
    start_at = datetime(
        local_date.year,
        local_date.month,
        local_date.day,
        class_time.start_hour,
        class_time.start_minute,
        tzinfo=SEOUL,
    )
    end_at = datetime(
        local_date.year,
        local_date.month,
        local_date.day,
        class_time.end_hour,
        class_time.end_minute,
        tzinfo=SEOUL,
    )
    if end_at <= start_at:
        end_at += timedelta(hours=12)
    return start_at, end_at


def find_time_range_after_date(chunk: str, date_match: DateSnippet) -> tuple[datetime, datetime] | None:
    tail = normalize_whitespace(chunk[date_match.end : date_match.end + 160])
    if not tail:
        return None

    patterns = [
        re.compile(
            r"from\s+(\d{1,2})(?::(\d{2}))?\s*(AM|PM)?\s*(?:to|-|~)\s*(\d{1,2})(?::(\d{2}))?\s*(AM|PM)?",
            re.IGNORECASE,
        ),
        re.compile(
            r"from\s+(\d{1,2})h\s*(\d{2})?\s*(?:to|-|~)\s*(\d{1,2})h\s*(\d{2})?",
            re.IGNORECASE,
        ),
        re.compile(
            r"(오전|오후)?\s*(\d{1,2}):(\d{2})\s*(?:부터|~|-|to)\s*(오전|오후)?\s*(\d{1,2}):(\d{2})",
            re.IGNORECASE,
        ),
    ]

    for pattern in patterns:
        match = pattern.search(tail)
        if not match:
            continue

        if "from" in pattern.pattern:
            if "h" in pattern.pattern:
                start_at = build_time_on_same_day(
                    date_match.sort_due,
                    int(match.group(1)),
                    int(match.group(2) or "0"),
                    None,
                    tail,
                )
                end_at = build_time_on_same_day(
                    date_match.sort_due,
                    int(match.group(3)),
                    int(match.group(4) or "0"),
                    None,
                    tail,
                )
            else:
                start_at = build_time_on_same_day(
                    date_match.sort_due,
                    int(match.group(1)),
                    int(match.group(2) or "0"),
                    match.group(3),
                    tail,
                )
                end_at = build_time_on_same_day(
                    date_match.sort_due,
                    int(match.group(4)),
                    int(match.group(5) or "0"),
                    match.group(6),
                    tail,
                )
        else:
            start_at = build_time_on_same_day(
                date_match.sort_due,
                int(match.group(2)),
                int(match.group(3)),
                match.group(1),
                tail,
            )
            end_at = build_time_on_same_day(
                date_match.sort_due,
                int(match.group(5)),
                int(match.group(6)),
                match.group(4),
                tail,
            )

        if end_at <= start_at:
            end_at += timedelta(hours=12)
        return start_at, end_at

    return None


def build_time_on_same_day(
    base_date: datetime, hour: int, minute: int, meridiem: str | None, context: str
) -> datetime:
    meridiem_text = normalize_whitespace(meridiem or "").lower()
    normalized_context = context.lower()

    if meridiem_text in {"pm", "오후"}:
        hour = hour % 12 + 12
    elif meridiem_text in {"am", "오전"}:
        hour = hour % 12
    elif "afternoon" in normalized_context and hour < 12:
        hour += 12

    return datetime(
        base_date.year,
        base_date.month,
        base_date.day,
        hour,
        minute,
        tzinfo=SEOUL,
    )


def find_date_snippets(text: str) -> list[DateSnippet]:
    patterns: list[tuple[str, str]] = [
        (
            "korean_year",
            r"(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일(?:\s*\([^)]+\))?(?:\s*(오전|오후)\s*(\d{1,2}):(\d{2}))?",
        ),
        (
            "korean_short",
            r"(?<!\d)(\d{1,2})월\s*(\d{1,2})일(?:\s*\([^)]+\))?(?:\s*(오전|오후)\s*(\d{1,2}):(\d{2}))?",
        ),
        (
            "ymd",
            r"(\d{4})[./-](\d{1,2})[./-](\d{1,2})(?:\s*\([^)]+\))?(?:\s*(\d{1,2}):(\d{2})(?:\s*(AM|PM))?)?",
        ),
        (
            "month_day",
            r"(?<!\d)(\d{1,2})/(\d{1,2})(?:\s*\([^)]+\))?(?:\s*(\d{1,2}):(\d{2})(?:\s*(AM|PM))?)?",
        ),
        (
            "english",
            r"\b([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:,\s*(\d{4}))?(?:(?:,\s*|\s+)(\d{1,2}):(\d{2})\s*(AM|PM))?",
        ),
        (
            "english_of",
            r"\b(\d{1,2})(?:st|nd|rd|th)?\s+of\s+([A-Za-z]{3,9})\.?(?:\s*,?\s*(\d{4}))?",
        ),
    ]

    results: list[DateSnippet] = []
    seen_spans: set[tuple[int, int]] = set()

    for kind, pattern in patterns:
        for match in re.finditer(pattern, text, re.IGNORECASE):
            span = match.span()
            if span in seen_spans:
                continue

            parsed = parse_date_match(kind, match)
            if not parsed:
                continue

            sort_due, precision = parsed
            results.append(
                DateSnippet(
                    text=normalize_whitespace(match.group(0)),
                    sort_due=sort_due,
                    timing_precision=precision,
                    start=span[0],
                    end=span[1],
                )
            )
            seen_spans.add(span)

    return results


def parse_date_match(kind: str, match: re.Match[str]) -> tuple[datetime, str] | None:
    if kind == "korean_year":
        year = int(match.group(1))
        month = int(match.group(2))
        day = int(match.group(3))
        meridiem = match.group(4)
        hour_text = match.group(5)
        minute_text = match.group(6)
        if meridiem and hour_text and minute_text:
            hour = int(hour_text) % 12
            if meridiem == "오후":
                hour += 12
            return build_schedule_datetime(year, month, day, hour, int(minute_text)), "datetime"
        return build_schedule_date(year, month, day), "date"

    if kind == "korean_short":
        month = int(match.group(1))
        day = int(match.group(2))
        year = infer_year(month, day)
        meridiem = match.group(3)
        hour_text = match.group(4)
        minute_text = match.group(5)
        if meridiem and hour_text and minute_text:
            hour = int(hour_text) % 12
            if meridiem == "오후":
                hour += 12
            return build_schedule_datetime(year, month, day, hour, int(minute_text)), "datetime"
        return build_schedule_date(year, month, day), "date"

    if kind == "ymd":
        year = int(match.group(1))
        month = int(match.group(2))
        day = int(match.group(3))
        hour_text = match.group(4)
        minute_text = match.group(5)
        meridiem = match.group(6)
        if hour_text and minute_text:
            hour = int(hour_text)
            if meridiem:
                hour %= 12
                if meridiem.upper() == "PM":
                    hour += 12
            return build_schedule_datetime(year, month, day, hour, int(minute_text)), "datetime"
        return build_schedule_date(year, month, day), "date"

    if kind == "month_day":
        month = int(match.group(1))
        day = int(match.group(2))
        year = infer_year(month, day)
        hour_text = match.group(3)
        minute_text = match.group(4)
        meridiem = match.group(5)
        if hour_text and minute_text:
            hour = int(hour_text)
            if meridiem:
                hour %= 12
                if meridiem.upper() == "PM":
                    hour += 12
            return build_schedule_datetime(year, month, day, hour, int(minute_text)), "datetime"
        return build_schedule_date(year, month, day), "date"

    if kind == "english":
        month = month_name_to_number(match.group(1))
        if not month:
            return None
        day = int(match.group(2))
        year = int(match.group(3)) if match.group(3) else infer_year(month, day)
        hour_text = match.group(4)
        minute_text = match.group(5)
        meridiem = match.group(6)
        if hour_text and minute_text:
            hour = int(hour_text)
            if meridiem:
                hour %= 12
                if meridiem.upper() == "PM":
                    hour += 12
            return build_schedule_datetime(year, month, day, hour, int(minute_text)), "datetime"
        return build_schedule_date(year, month, day), "date"

    if kind == "english_of":
        day = int(match.group(1))
        month = month_name_to_number(match.group(2))
        if not month:
            return None
        year = int(match.group(3)) if match.group(3) else infer_year(month, day)
        return build_schedule_date(year, month, day), "date"

    return None


def infer_year(month: int, day: int) -> int:
    now = datetime.now(SEOUL)
    candidate = datetime(now.year, month, day, 9, 0, tzinfo=SEOUL)
    if candidate < now - timedelta(days=180):
        return now.year + 1
    return now.year


def build_schedule_datetime(year: int, month: int, day: int, hour: int, minute: int) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=SEOUL)


def build_schedule_date(year: int, month: int, day: int) -> datetime:
    return datetime(year, month, day, 9, 0, tzinfo=SEOUL)


def format_schedule_range(start: datetime, end: datetime) -> str:
    start_local = start.astimezone(SEOUL)
    end_local = end.astimezone(SEOUL)
    start_label = format_korean_clock(start_local)
    end_label = format_korean_clock(end_local)
    if start_local.date() == end_local.date():
        weekday = korean_weekday_name(start_local)
        return (
            f"{start_local.year}년 {start_local.month}월 {start_local.day}일({weekday}) "
            f"{start_label} - {end_label}"
        )

    start_weekday = korean_weekday_name(start_local)
    end_weekday = korean_weekday_name(end_local)
    return (
        f"{start_local.year}년 {start_local.month}월 {start_local.day}일({start_weekday}) {start_label} - "
        f"{end_local.year}년 {end_local.month}월 {end_local.day}일({end_weekday}) {end_label}"
    )


def format_korean_clock(value: datetime) -> str:
    hour_12 = value.hour % 12 or 12
    meridiem = "오전" if value.hour < 12 else "오후"
    return f"{meridiem} {hour_12}:{value.minute:02d}"


def korean_weekday_name(value: datetime) -> str:
    names = ["월요일", "화요일", "수요일", "목요일", "금요일", "토요일", "일요일"]
    return names[value.weekday()]


def build_success_payload(
    assignments: list[dict[str, Any]],
    exam_items: list[dict[str, Any]],
    exam_candidates: list[dict[str, Any]],
    assignment_candidates: list[dict[str, Any]],
    help_desk_items: list[dict[str, Any]],
) -> dict[str, Any]:
    sorted_assignments = sorted(assignments, key=assignment_sort_key)
    sorted_exam_items = sorted(exam_items, key=assignment_sort_key)
    sorted_exam_candidates = sorted(exam_candidates, key=assignment_sort_key)
    sorted_assignment_candidates = sorted(assignment_candidates, key=assignment_sort_key)
    sorted_help_desk_items = sorted(help_desk_items, key=assignment_sort_key)
    generated_at = now_seoul()
    content = {
        "kind": "success",
        "assignments": [serialize_sync_item(item) for item in sorted_assignments],
        "exam_items": [serialize_sync_item(item) for item in sorted_exam_items],
        "exam_candidates": [serialize_sync_item(item) for item in sorted_exam_candidates],
        "assignment_candidates": [serialize_sync_item(item) for item in sorted_assignment_candidates],
        "help_desk_items": [serialize_sync_item(item) for item in sorted_help_desk_items],
    }
    html = render_success_html(
        sorted_assignments,
        sorted_exam_items,
        sorted_exam_candidates,
        sorted_assignment_candidates,
        sorted_help_desk_items,
        generated_at,
    )
    return {
        "status": "ok",
        "generated_at": generated_at,
        "content": content,
        "html": html,
    }


def serialize_sync_item(item: dict[str, Any]) -> dict[str, Any]:
    return {
        "url": item["url"],
        "type": item["type"],
        "category": item.get("category", "assignment"),
        "course": item["course"],
        "title": item["title"],
        "due": item["due"],
        "submission": item.get("submission", ""),
        "instructions": item["instructions"],
        "timing_precision": item.get("timing_precision", ""),
        "time_source": item.get("time_source", ""),
        "sync_start": item.get("sync_start", ""),
        "sync_due": item.get("sync_due", ""),
        "source_title": item.get("source_title", ""),
        "location": item.get("location", ""),
        "coverage": item.get("coverage", ""),
        "coverage_summary": exam_coverage_summary_for_item(item),
        "auto_completed": bool(item.get("auto_completed")),
    }


def build_error_payload(message: str | None, previous_state: dict[str, Any]) -> dict[str, Any]:
    last_success = previous_state.get("generated_at") if previous_state.get("status") == "ok" else None
    content = {
        "kind": "error",
        "message": message or "알 수 없는 오류가 발생했어.",
        "last_success_at": last_success,
    }
    return {
        "status": "error",
        "generated_at": now_seoul(),
        "content": content,
        "html": render_error_html(content["message"], last_success),
    }


def append_exam_scope_location_lines(lines: list[str], item: dict[str, Any]) -> None:
    coverage = exam_coverage_summary_for_item(item)
    location = exam_location_for_item(item)
    if coverage:
        lines.extend(format_exam_coverage_html_lines(coverage))
    if location:
        location_html = exam_location_display_html(item, location)
        lines.append(div(f"위치: {location_html}"))


def exam_coverage_for_item(item: dict[str, Any]) -> str:
    structured = normalize_whitespace(str(item.get("coverage") or ""))
    if structured:
        return structured
    return extract_exam_coverage(str(item.get("instructions") or ""))


def exam_coverage_summary_for_item(item: dict[str, Any]) -> str:
    structured = normalize_multiline_field(str(item.get("coverage_summary") or ""))
    if structured:
        return structured
    return summarize_exam_coverage_for_calendar(exam_coverage_for_item(item))


def format_exam_coverage_html_lines(coverage: str) -> list[str]:
    lines = [line for line in normalize_multiline_field(coverage).splitlines() if line]
    if not lines:
        return []
    if len(lines) == 1 and not lines[0].startswith("- "):
        return [div(f"시험 범위: {escape(lines[0])}")]
    return [div("시험 범위:")] + [div(escape(line)) for line in lines[:4]]


def exam_location_for_item(item: dict[str, Any]) -> str:
    structured = normalize_whitespace(str(item.get("location") or ""))
    if structured:
        return structured
    return resolve_exam_location_from_text(str(item.get("instructions") or ""), str(item.get("url") or ""))


def resolve_exam_location_from_text(text: str, url: str) -> str:
    explicit_location = extract_exam_location(text)
    if explicit_location:
        return explicit_location
    if is_online_klms_exam_url(url):
        return url
    return ""


def exam_location_display_html(item: dict[str, Any], location: str) -> str:
    url = str(item.get("url") or "")
    if location == url and is_online_klms_exam_url(url):
        return f'<a href="{escape(url, quote=True)}">KLMS 시험/제출 페이지</a>'
    return escape(location)


def extract_exam_location(text: str) -> str:
    compact = normalize_whitespace(text)
    return first_exam_field_capture(
        compact,
        [
            r"(?:시험\s*)?(?:장소|고사장)\s*[:：]\s*(.+?)(?=\s*(?:시험\s*범위|범위|Date\s*&\s*Time|Coverage|Range|Time|Place|Location|$))",
            r"\b(?:Location|Place|Venue|Room)\s*:\s*(.+?)(?=\s*(?:Range|Coverage|Exam\s*Range|Time|Date\s*&\s*Time|시험\s*범위|시험\s*일시|$))",
        ],
    )


def extract_exam_coverage(text: str) -> str:
    compact = normalize_whitespace(text)
    return first_exam_field_capture(
        compact,
        [
            r"(?:시험\s*)?범위\s*[:：]\s*(.+?)(?=\s*(?:Date\s*&\s*Time|Location|Place|Venue|Room|Coverage|Range|Time|시험\s*일시|시험\s*장소|$))",
            r"\b(?:Coverage|Range|Exam\s*Range)\s*:\s*(.+?)(?=\s*(?:[•⦁]|Time|Date\s*&\s*Time|Location|Place|Venue|Room|시험\s*일시|시험\s*장소|$))",
        ],
    )


def summarize_exam_coverage_for_calendar(text: str, *, max_lines: int = 4) -> str:
    coverage = cleanup_exam_field(text)
    if not coverage:
        return ""
    if exam_coverage_needs_manual_check(coverage):
        return "확인 필요 - 원문 참고"

    sections = categorize_exam_coverage(coverage)
    if should_keep_exam_coverage_one_line(coverage, sections):
        return coverage
    if not sections:
        return coverage if len(coverage) <= 140 else "확인 필요 - 원문 참고"

    lines: list[str] = []
    for label in ("강의", "과제", "읽기자료", "제외", "기타"):
        values = sections.get(label, [])
        if not values:
            continue
        lines.append(f"- {label}: {', '.join(values)}")
        if len(lines) >= max_lines:
            break

    return "\n".join(lines) if lines else "확인 필요 - 원문 참고"


def should_keep_exam_coverage_one_line(coverage: str, sections: dict[str, list[str]]) -> bool:
    if len(coverage) > 96:
        return False
    if "\n" in coverage:
        return False
    if len(sections) >= 3:
        return False
    return True


def exam_coverage_needs_manual_check(text: str) -> bool:
    lowered = normalize_whitespace(text).lower()
    return bool(
        re.search(
            r"\b(?:tba|tbd|to be announced|will be announced|to be determined)\b|"
            r"추후\s*공지|별도\s*공지|공지\s*예정|미정|확인\s*필요",
            lowered,
            re.IGNORECASE,
        )
    )


def categorize_exam_coverage(text: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    for segment in split_exam_coverage_segments(text):
        label, value = classify_exam_coverage_segment(segment)
        if not value:
            continue
        values = sections.setdefault(label, [])
        if value not in values:
            values.append(value)
    return sections


def split_exam_coverage_segments(text: str) -> list[str]:
    compact = cleanup_exam_field(text)
    if not compact:
        return []
    compact = re.sub(r"\s*[•⦁]\s*", "; ", compact)
    compact = re.sub(r"\s+/\s+", "; ", compact)
    parts = re.split(r"\s*;\s*|\n+", compact)
    return [cleanup_exam_field(part) for part in parts if cleanup_exam_field(part)]


def classify_exam_coverage_segment(segment: str) -> tuple[str, str]:
    raw = cleanup_exam_field(segment)
    explicit_label = explicit_exam_coverage_label(raw)
    value = strip_exam_coverage_label(raw)
    lowered = value.lower()
    if not value:
        return "기타", ""

    if explicit_label:
        return explicit_label, value
    if re.search(r"\b(?:excluding|excluded|exclude|except|not included)\b|제외|범위\s*외|이후", lowered):
        return "제외", value
    if re.search(r"\b(?:wa|pa|hw|homework|assignment|assignments|problem\s*set|ps)\s*\d", lowered) or "과제" in value:
        return "과제", value
    if re.search(r"\b(?:reading|readings|textbook|chapter|chapters|clrs|section|sections)\b", lowered) or re.search(
        r"읽기|교재|읽기자료", value
    ):
        return "읽기자료", value
    if re.search(r"\b(?:week|weeks|lecture|lectures|slides?)\b", lowered) or re.search(
        r"강의|수업|주차", value
    ):
        return "강의", value
    return "기타", value


def explicit_exam_coverage_label(text: str) -> str:
    label_match = re.match(
        r"^(강의|수업|주차|lecture(?:s)?|week(?:s)?|과제|assignment(?:s)?|homework|"
        r"읽기자료|읽기|reading(?:s)?|textbook|교재|제외|excluding|exclude|except)\s*[:：]",
        text,
        flags=re.IGNORECASE,
    )
    if not label_match:
        return ""
    label = label_match.group(1).lower()
    if label in {"강의", "수업", "주차", "lecture", "lectures", "week", "weeks"}:
        return "강의"
    if label in {"과제", "assignment", "assignments", "homework"}:
        return "과제"
    if label in {"읽기자료", "읽기", "reading", "readings", "textbook", "교재"}:
        return "읽기자료"
    return "제외"


def strip_exam_coverage_label(text: str) -> str:
    return cleanup_exam_field(
        re.sub(
            r"^(?:강의|수업|주차|lecture(?:s)?|week(?:s)?|과제|assignment(?:s)?|homework|"
            r"읽기자료|읽기|reading(?:s)?|textbook|교재|제외|excluding|exclude|except)\s*[:：]\s*",
            "",
            text,
            flags=re.IGNORECASE,
        )
    )


def first_exam_field_capture(text: str, patterns: list[str]) -> str:
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match and match.group(1):
            return cleanup_exam_field(match.group(1))
    return ""


def cleanup_exam_field(text: str) -> str:
    return normalize_whitespace(text).rstrip(" .;,")


def normalize_multiline_field(text: str) -> str:
    return "\n".join(
        line
        for line in (normalize_whitespace(part) for part in str(text or "").splitlines())
        if line
    ).strip()


def is_online_klms_exam_url(url: str) -> bool:
    return bool(re.search(r"/mod/(?:assign|quiz)/view\.php", url, re.IGNORECASE))


def render_success_html(
    assignments: list[dict[str, Any]],
    exam_items: list[dict[str, Any]],
    exam_candidates: list[dict[str, Any]],
    assignment_candidates: list[dict[str, Any]],
    help_desk_items: list[dict[str, Any]],
    generated_at: str,
) -> str:
    if (
        not assignments
        and not exam_items
        and not exam_candidates
        and not assignment_candidates
        and not help_desk_items
    ):
        return "\n".join(
            [
                div(f"마지막 반영: {escape(generated_at)}"),
                div("현재 확인된 과제, 확인 필요 후보, 시험 일정, 헬프데스크 안내가 없어."),
            ]
        )

    lines = [
        div(
            f"총 {len(assignments)}개 과제 / {len(exam_items)}개 시험 일정 / "
            f"{len(help_desk_items)}개 헬프데스크 안내 / {len(assignment_candidates)}개 과제 후보 / "
            f"{len(exam_candidates)}개 시험 후보"
        ),
        div(f"마지막 반영: {escape(generated_at)}"),
        div("과제, 확인 필요 후보, 시험 일정, 헬프데스크 안내를 함께 정리했어. 자세한 내용은 링크에서 바로 열 수 있어."),
        br(),
    ]

    if exam_candidates:
        lines.append(div("<b>시험 후보 (확인 필요)</b>"))
        for item in exam_candidates:
            lines.append(div(f"☐ <b>[후보] {escape(item['title'])}</b>"))
            lines.append(div(f"일정: {escape(normalize_whitespace(item['due']) or '확인 필요')}"))
            if item["course"]:
                lines.append(div(f"과목: {escape(item['course'])}"))
            if item.get("source_title"):
                lines.append(div(f"출처: {escape(item['source_title'])}"))
            if item.get("timing_precision") == "date":
                lines.append(div("시간: KLMS에서 날짜만 확인됨"))
            lines.append(div("상태: 시험 캘린더 반영 전 사용자 확인 필요"))
            append_exam_scope_location_lines(lines, item)
            if item["instructions"]:
                lines.append(div(f"메모: {escape(summarize_instructions(item['instructions']))}"))
            lines.append(div(f'링크: <a href="{escape(item["url"], quote=True)}">KLMS 열기</a>'))
            lines.append(br())

    if help_desk_items:
        lines.append(div("<b>헬프데스크</b>"))
        for item in help_desk_items:
            lines.append(div(f"☐ <b>[헬프데스크] {escape(item['title'])}</b>"))
            lines.append(div(f"일정: {escape(normalize_whitespace(item['due']) or '확인 필요')}"))
            if item["course"]:
                lines.append(div(f"과목: {escape(item['course'])}"))
            if item.get("source_title"):
                lines.append(div(f"출처: {escape(item['source_title'])}"))
            if item.get("timing_precision") == "date":
                lines.append(div("시간: KLMS에서 날짜만 확인됨"))
            lines.append(div("상태: 기타 캘린더에 반영"))
            if item["instructions"]:
                lines.append(div(f"메모: {escape(summarize_instructions(item['instructions']))}"))
            lines.append(div(f'링크: <a href="{escape(item["url"], quote=True)}">KLMS 열기</a>'))
            lines.append(br())

    if exam_items:
        lines.append(div("<b>시험 일정</b>"))
        for item in exam_items:
            lines.append(div(f"☐ <b>[시험] {escape(item['title'])}</b>"))
            lines.append(div(f"일정: {escape(normalize_whitespace(item['due']) or '확인 필요')}"))
            if item["course"]:
                lines.append(div(f"과목: {escape(item['course'])}"))
            if item.get("source_title"):
                lines.append(div(f"출처: {escape(item['source_title'])}"))
            if item.get("timing_precision") == "date":
                lines.append(div("시간: KLMS에서 날짜만 확인됨"))
            append_exam_scope_location_lines(lines, item)
            if item["instructions"]:
                lines.append(div(f"메모: {escape(summarize_instructions(item['instructions']))}"))
            lines.append(div(f'링크: <a href="{escape(item["url"], quote=True)}">KLMS 열기</a>'))
            lines.append(br())

    if assignments:
        lines.append(div("<b>과제</b>"))
        for item in assignments:
            lines.append(div(f"☐ <b>{escape(item['title'])}</b>"))
            lines.append(div(f"마감: {escape(display_due_text(item['due']))}"))
            if item["course"]:
                lines.append(div(f"과목: {escape(item['course'])}"))
            if item.get("source_title"):
                lines.append(div(f"출처: {escape(item['source_title'])}"))
            if item["instructions"]:
                lines.append(div(f"해야 할 일: {escape(summarize_instructions(item['instructions']))}"))
            lines.append(div(f'링크: <a href="{escape(item["url"], quote=True)}">KLMS 열기</a>'))
            lines.append(br())

    if assignment_candidates:
        lines.append(div("<b>과제 후보 (확인 필요)</b>"))
        for item in assignment_candidates:
            lines.append(div(f"☐ <b>[후보] {escape(item['title'])}</b>"))
            lines.append(div(f"마감: {escape(display_due_text(item['due']))}"))
            if item["course"]:
                lines.append(div(f"과목: {escape(item['course'])}"))
            if item.get("source_title"):
                lines.append(div(f"출처: {escape(item['source_title'])}"))
            lines.append(div("상태: 과제 동기화 반영 전 사용자 확인 필요"))
            if item["instructions"]:
                lines.append(div(f"메모: {escape(summarize_instructions(item['instructions']))}"))
            lines.append(div(f'링크: <a href="{escape(item["url"], quote=True)}">KLMS 열기</a>'))
            lines.append(br())

    return "\n".join(lines)


def render_error_html(message: str, last_success: str | None) -> str:
    lines = [
        div(MARKER),
        div("<b>KLMS 동기화</b>"),
        div(f"문제가 생겨서 이번 동기화는 반영하지 못했어: {escape(message)}"),
    ]
    if last_success:
        lines.append(div(f"마지막 정상 반영: {escape(last_success)}"))
    lines.append(div("KLMS에 다시 로그인한 뒤 다음 실행을 기다리면 돼."))
    return "\n".join(lines)


def div(inner_html: str) -> str:
    return f"<div>{inner_html}</div>"


def br() -> str:
    return "<div><br></div>"


def display_due_text(text: str) -> str:
    return format_short_due(text) or normalize_whitespace(text) or "마감 정보 없음"


def extract_due_text(text: str) -> str:
    compact = normalize_whitespace(text)
    if not compact:
        return ""

    for pattern in (
        r"(\d{4})년\s*\d{1,2}월\s*\d{1,2}일.*?(?:오전|오후)\s*\d{1,2}:\d{2}",
        r"(\d{4})\.(\d{1,2})\.(\d{1,2})\s*~\s*(\d{4})\.(\d{1,2})\.(\d{1,2})",
        r"(\d{4})\.(\d{1,2})\.(\d{1,2})",
        r"(?:Due(?: Date)?\s*:\s*)?(?:[A-Za-z]+,\s*)?[A-Za-z]+\s+\d{1,2},\s*(?:\d{4},\s*)?\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)\.?",
        r"(?:Due(?: Date)?\s*:\s*)?(?:[A-Za-z]+,\s*)?[A-Za-z]+\s+\d{1,2},\s*(?:\d{4},\s*)?\d{1,2}:\d{2}(?::\d{2})?",
        r"(?:Due(?: Date)?\s*:\s*)?\d{1,2}/\d{1,2}(?:/\d{4})?\s+\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)\.?",
        r"(?:Due(?: Date)?\s*:\s*)?\d{1,2}/\d{1,2}(?:/\d{4})?\s+\d{1,2}:\d{2}(?::\d{2})?",
    ):
        match = re.search(pattern, compact, re.IGNORECASE)
        if not match:
            continue

        due = normalize_due_text(match.group(0))
        if due:
            return due

    return ""


def strip_due_text(text: str) -> str:
    compact = normalize_whitespace(text)
    if not compact:
        return ""

    patterns = (
        r"(\d{4})년\s*\d{1,2}월\s*\d{1,2}일.*?(?:오전|오후)\s*\d{1,2}:\d{2}",
        r"(\d{4})\.(\d{1,2})\.(\d{1,2})\s*~\s*(\d{4})\.(\d{1,2})\.(\d{1,2})",
        r"(\d{4})\.(\d{1,2})\.(\d{1,2})",
        r"(?:Due(?: Date)?\s*:\s*)?(?:[A-Za-z]+,\s*)?[A-Za-z]+\s+\d{1,2},\s*(?:\d{4},\s*)?\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)\.?",
        r"(?:Due(?: Date)?\s*:\s*)?(?:[A-Za-z]+,\s*)?[A-Za-z]+\s+\d{1,2},\s*(?:\d{4},\s*)?\d{1,2}:\d{2}(?::\d{2})?",
        r"(?:Due(?: Date)?\s*:\s*)?\d{1,2}/\d{1,2}(?:/\d{4})?\s+\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)\.?",
        r"(?:Due(?: Date)?\s*:\s*)?\d{1,2}/\d{1,2}(?:/\d{4})?\s+\d{1,2}:\d{2}(?::\d{2})?",
    )

    stripped = compact
    for pattern in patterns:
        stripped = re.sub(pattern, " ", stripped, flags=re.IGNORECASE)

    stripped = normalize_whitespace(stripped)
    stripped = re.sub(r"^Due(?: Date)?\s*:\s*", "", stripped, flags=re.IGNORECASE).strip()
    return stripped


def normalize_due_text(text: str) -> str:
    compact = normalize_whitespace(text)
    if not compact:
        return ""

    if re.search(r"Due(?: Date)?\s*:", compact, re.IGNORECASE) or re.search(
        r"(?:[A-Za-z]+,\s*)?[A-Za-z]+\s+\d{1,2},\s*(?:\d{4},\s*)?\d{1,2}:\d{2}",
        compact,
    ) or re.search(r"\d{1,2}/\d{1,2}(?:/\d{4})?\s+\d{1,2}:\d{2}", compact):
        due = parse_due_datetime(compact)
        if due:
            return format_korean_due(due)

    return compact


def summarize_instructions(text: str, limit: int = 220) -> str:
    compact = normalize_whitespace(text)
    if len(compact) <= limit:
        return compact
    return f"{compact[: limit - 1].rstrip()}…"


def assignment_sort_key(item: dict[str, Any]) -> tuple[int, str, str]:
    due = item.get("sort_due")
    if due:
        return (0, due.isoformat(), item["title"])
    return (1, item.get("due", ""), item["title"])


def parse_due_datetime(text: str) -> datetime | None:
    english_match = re.search(
        r"(?:Due(?: Date)?\s*:\s*)?(?:[A-Za-z]+,\s*)?([A-Za-z]+)\s+(\d{1,2}),\s*(?:(\d{4}),\s*)?(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)\.?",
        text,
        re.IGNORECASE,
    )
    if english_match:
        month_name, day, year, hour, minute, _second, meridiem = english_match.groups()
        month_num = month_name_to_number(month_name)
        if month_num:
            reference_now = datetime.now(SEOUL)
            year_num = int(year) if year else reference_now.year
            hour_num = int(hour) % 12
            if meridiem.upper() == "PM":
                hour_num += 12

            due = datetime(
                year_num,
                month_num,
                int(day),
                hour_num,
                int(minute),
                tzinfo=SEOUL,
            )
            if not year and due < reference_now - timedelta(days=180):
                due = due.replace(year=due.year + 1)
            return due

    english_24h_match = re.search(
        r"(?:Due(?: Date)?\s*:\s*)?(?:[A-Za-z]+,\s*)?([A-Za-z]+)\s+(\d{1,2}),\s*(?:(\d{4}),\s*)?([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?",
        text,
        re.IGNORECASE,
    )
    if english_24h_match:
        month_name, day, year, hour, minute, _second = english_24h_match.groups()
        month_num = month_name_to_number(month_name)
        if month_num:
            reference_now = datetime.now(SEOUL)
            year_num = int(year) if year else reference_now.year
            due = datetime(
                year_num,
                month_num,
                int(day),
                int(hour),
                int(minute),
                tzinfo=SEOUL,
            )
            if not year and due < reference_now - timedelta(days=180):
                due = due.replace(year=due.year + 1)
            return due

    numeric_match = re.search(
        r"(?:Due(?: Date)?\s*:\s*)?(\d{1,2})/(\d{1,2})(?:/(\d{4}))?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)\.?",
        text,
        re.IGNORECASE,
    )
    if numeric_match:
        month, day, year, hour, minute, _second, meridiem = numeric_match.groups()
        reference_now = datetime.now(SEOUL)
        year_num = int(year) if year else reference_now.year
        hour_num = int(hour) % 12
        if meridiem.upper() == "PM":
            hour_num += 12

        due = datetime(
            year_num,
            int(month),
            int(day),
            hour_num,
            int(minute),
            tzinfo=SEOUL,
        )
        if not year and due < reference_now - timedelta(days=180):
            due = due.replace(year=due.year + 1)
        return due

    numeric_24h_match = re.search(
        r"(?:Due(?: Date)?\s*:\s*)?(\d{1,2})/(\d{1,2})(?:/(\d{4}))?\s+([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?",
        text,
        re.IGNORECASE,
    )
    if numeric_24h_match:
        month, day, year, hour, minute, _second = numeric_24h_match.groups()
        reference_now = datetime.now(SEOUL)
        year_num = int(year) if year else reference_now.year
        due = datetime(
            year_num,
            int(month),
            int(day),
            int(hour),
            int(minute),
            tzinfo=SEOUL,
        )
        if not year and due < reference_now - timedelta(days=180):
            due = due.replace(year=due.year + 1)
        return due

    korean_match = re.search(
        r"(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일.*?(오전|오후)\s*(\d{1,2}):(\d{2})",
        text,
    )
    if korean_match:
        year, month, day, meridiem, hour, minute = korean_match.groups()
        hour_num = int(hour) % 12
        if meridiem == "오후":
            hour_num += 12

        return datetime(
            int(year),
            int(month),
            int(day),
            hour_num,
            int(minute),
            tzinfo=SEOUL,
        )

    range_match = re.search(
        r"(\d{4})\.(\d{1,2})\.(\d{1,2})\s*~\s*(\d{4})\.(\d{1,2})\.(\d{1,2})",
        text,
    )
    if range_match:
        end_year, end_month, end_day = range_match.group(4), range_match.group(5), range_match.group(6)
        return datetime(
            int(end_year),
            int(end_month),
            int(end_day),
            23,
            59,
            tzinfo=SEOUL,
        )

    dotted_date_match = re.search(r"(\d{4})\.(\d{1,2})\.(\d{1,2})", text)
    if dotted_date_match:
        year, month, day = dotted_date_match.groups()
        return datetime(
            int(year),
            int(month),
            int(day),
            23,
            59,
            tzinfo=SEOUL,
        )

    return None


def infer_timing_precision(text: str) -> str:
    compact = normalize_whitespace(text)
    if not compact:
        return ""
    if re.search(r"(오전|오후)\s*\d{1,2}:\d{2}", compact):
        return "datetime"
    if re.search(r"\d{1,2}:\d{2}\s*(AM|PM)", compact, re.IGNORECASE):
        return "datetime"
    if parse_due_datetime(compact):
        return "date" if "~" in compact or re.fullmatch(r"\d{4}\.\d{1,2}\.\d{1,2}", compact) else "datetime"
    return ""


def format_short_due(text: str) -> str:
    due = parse_due_datetime(text)
    if not due:
        return ""
    weekdays = ["월", "화", "수", "목", "금", "토", "일"]
    weekday = weekdays[due.weekday()]
    return f"{due.month}/{due.day}({weekday}) {due.strftime('%H:%M')}"


def format_korean_due(due: datetime) -> str:
    meridiem = "오전" if due.hour < 12 else "오후"
    hour = due.hour % 12 or 12
    return f"{due.year}년 {due.month}월 {due.day}일 {meridiem} {hour}:{due.strftime('%M')}"


def month_name_to_number(month_name: str) -> int | None:
    months = {
        "jan": 1,
        "january": 1,
        "feb": 2,
        "february": 2,
        "mar": 3,
        "march": 3,
        "apr": 4,
        "april": 4,
        "may": 5,
        "jun": 6,
        "june": 6,
        "jul": 7,
        "july": 7,
        "aug": 8,
        "august": 8,
        "sep": 9,
        "sept": 9,
        "september": 9,
        "oct": 10,
        "october": 10,
        "nov": 11,
        "november": 11,
        "dec": 12,
        "december": 12,
    }
    return months.get(month_name.strip().lower().rstrip("."))


def text_of_first(nodes: list[Any], separator: str = " ") -> str:
    if not nodes:
        return ""
    return nodes[0].get_text(separator, strip=True)


def link_context_text(link: Any) -> str:
    if not link:
        return ""
    context_node = link.find_parent(["tr", "li", "article"])
    if context_node is not None:
        return normalize_whitespace(context_node.get_text(" ", strip=True))
    parent = getattr(link, "parent", None)
    if parent is not None:
        return normalize_whitespace(parent.get_text(" ", strip=True))
    return ""


def normalize_whitespace(text: str) -> str:
    text = text.replace("\xa0", " ")
    return re.sub(r"\s+", " ", text).strip()


def clean_title(title: str) -> str:
    title = normalize_whitespace(title)
    title = re.sub(r"^[A-Z0-9._-]+:\s*", "", title)
    return title


def page_requested_url(page: dict[str, Any]) -> str:
    return page.get("requestedUrl", "") or page.get("url", "") or ""


def canonicalize_crawl_url(url: str) -> str:
    normalized = normalize_url(url)
    if not normalized:
        return ""

    parsed = urlparse(normalized)
    query_items = [
        (key, value)
        for key, value in parse_qsl(parsed.query, keep_blank_values=True)
        if key.lower() in {"id", "bwid", "page", "chapterid", "section"}
    ]
    return urlunparse(parsed._replace(query=urlencode(query_items), fragment=""))


def dedupe_ordered_urls(candidates: list[tuple[int, int, str]]) -> list[str]:
    by_url: dict[str, tuple[int, int]] = {}
    for priority, sequence, url in candidates:
        rank = (priority, sequence)
        existing = by_url.get(url)
        if existing is None or rank < existing:
            by_url[url] = rank
    return [url for url, _rank in sorted(by_url.items(), key=lambda item: item[1])]


def load_requested_url_set(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {
        canonicalize_crawl_url(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if canonicalize_crawl_url(line)
    }


def file_seed_priority(url: str, module: str = "") -> int:
    lowered = url.lower()
    if "/mod/assign/index.php" in lowered or "/mod/resource/index.php" in lowered:
        return 0
    module_name = (module or module_name_from_url(url)).lower()
    return FILE_SEED_MODULE_PRIORITIES.get(module_name, 5)


def linked_html_priority(url: str) -> int:
    lowered = url.lower()
    if "/mod/courseboard/article.php" in lowered:
        return 0
    if "/mod/courseboard/" in lowered:
        return 1
    module_name = module_name_from_url(url).lower()
    return LINKED_HTML_MODULE_PRIORITIES.get(module_name, 4)


def is_file_scan_nested_url(url: str) -> bool:
    lowered = url.lower()
    if "/mod/courseboard/article.php" in lowered:
        return True
    module_name = module_name_from_url(url).lower()
    return module_name in FILE_SCAN_NESTED_ALLOWED_MODULES


def normalize_url(url: str) -> str:
    url = url.strip()
    if url.startswith("//"):
        return f"https:{url}"
    if url.startswith("/"):
        return f"https://klms.kaist.ac.kr{url}"
    return url


def resolve_page_link_url(base_url: str, href: str) -> str:
    normalized = normalize_url(href)
    if normalized.startswith("http://") or normalized.startswith("https://"):
        return normalized
    return normalize_url(urljoin(base_url, href))


def url_query_id(url: str) -> str:
    match = re.search(r"[?&]id=([^&#]+)", url)
    return match.group(1) if match else ""


def url_query_page(url: str) -> int:
    match = re.search(r"[?&]page=(\d+)", url)
    if not match:
        return 1
    try:
        return int(match.group(1))
    except ValueError:
        return 1


def should_ignore_course_name(name: str) -> bool:
    lowered = normalize_whitespace(name).lower()
    if not lowered:
        return False
    if lowered in EXACT_IGNORED_COURSE_NAMES:
        return True
    return any(keyword.lower() in lowered for keyword in IGNORED_COURSE_NAMES)


def should_ignore_course_url(url: str) -> bool:
    identifier = url_query_id(url)
    return bool(identifier and identifier in IGNORED_COURSE_IDS)


def contains_any_keyword(text: str, keywords: tuple[str, ...]) -> bool:
    lowered = text.lower()
    return any(keyword.lower() in lowered for keyword in keywords)


def is_same_klms_url(url: str) -> bool:
    lowered = url.lower()
    return lowered.startswith("https://klms.kaist.ac.kr/") or lowered.startswith("http://klms.kaist.ac.kr/")


def is_crawlable_klms_page_url(url: str) -> bool:
    lowered = normalize_url(url).lower()
    if is_direct_resource_view_url(lowered):
        return False
    if not is_same_klms_url(lowered) or is_document_url(lowered) or is_assignment_submission_file_url(lowered):
        return False
    if "/course/view.php?id=" in lowered:
        return True
    return bool(re.search(r"/mod/[^/]+/(?:view|index|article)\.php", lowered))


def iter_main_content_links(soup: BeautifulSoup) -> list[Any]:
    for selector in ("#region-main", "div[role='main']", "#page-content", "#region-main-box"):
        container = soup.select_one(selector)
        if container:
            return container.select("a[href]")
    return soup.select("a[href]")


def should_follow_crawl_link(current_url: str, target_url: str) -> bool:
    current_module = module_name_from_url(current_url)
    target_module = module_name_from_url(target_url)
    if current_module == "courseboard" and target_module == "courseboard":
        current_id = url_query_id(current_url)
        target_id = url_query_id(target_url)
        return bool(current_id and target_id and current_id == target_id)
    return True


def should_follow_supplemental_detail_link(current_url: str, current_module: str, target_url: str) -> bool:
    target_module = module_name_from_url(target_url)
    if current_module == "courseboard" and target_module == "courseboard":
        current_id = url_query_id(current_url)
        target_id = url_query_id(target_url)
        return bool(current_id and target_id and current_id == target_id)
    return True


def is_assignment_submission_file_url(url: str) -> bool:
    lowered = url.lower()
    return "/assignsubmission_" in lowered or "/submission_files/" in lowered


def is_direct_resource_view_url(url: str) -> bool:
    lowered = url.lower()
    return "/mod/resource/view.php" in lowered


def is_document_url(url: str) -> bool:
    if is_assignment_submission_file_url(url):
        return False
    lowered = url.lower()
    if "/pluginfile.php/" in lowered:
        return True
    path = lowered.split("?", 1)[0]
    return path.endswith(DOCUMENT_EXTENSIONS)


def looks_like_html_page(url: str) -> bool:
    lowered = url.lower()
    return is_same_klms_url(url) and not is_document_url(url) and not lowered.endswith((".zip", ".mp4", ".mp3"))


def now_seoul() -> str:
    return datetime.now(SEOUL).strftime("%Y-%m-%d %H:%M KST")


if __name__ == "__main__":
    raise SystemExit(main())
