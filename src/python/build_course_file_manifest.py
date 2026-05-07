#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import re
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import parse_qsl, unquote, urlencode, urljoin, urlparse, urlunparse

from bs4 import BeautifulSoup
from klms_transport import write_json, write_text

COURSE_CODE_MAP: dict[str, str] = {}

IGNORED_COURSE_CODES = {"KLMS", "오류"}
IGNORED_COURSE_NAMES = {"기출문제은행", "공개강좌", "조교 과정", "조교"}
GENERIC_COURSE_NAMES = {"강의실 메인", "course home"}
IGNORED_ACTIVITY_IDS: set[str] = set()
COURSE_MATERIAL_BUCKETS = {"folders", "resources"}
MANIFEST_SOURCE_ENTRY_STYLE_VERSION = "2026-05-08-resource-section-source-title-v2"
INVALID_FS_CHARS = r'[:/\n\r\t]'
COURSEBOARD_INLINE_MEDIA_SELECTOR = (
    ".courseboard_view .content img[src], "
    ".courseboard_view .content source[src], "
    ".courseboard_view .content video[src], "
    ".courseboard_view .content audio[src]"
)
RESOURCE_ICON_EXTENSION_MAP = {
    "pdf": ".pdf",
    "powerpoint": ".ppt",
    "presentation": ".ppt",
    "word": ".doc",
    "document": ".doc",
    "excel": ".xls",
    "spreadsheet": ".xls",
    "archive": ".zip",
    "compressed": ".zip",
    "zip": ".zip",
    "audio": ".mp3",
    "video": ".mp4",
    "text": ".txt",
}
IGNORED_MEDIA_EXTENSIONS = {".mp4", ".m4v", ".mov", ".avi", ".mkv", ".mp3", ".wav", ".m4a"}
DOCUMENT_EXTENSIONS = (".pdf", ".doc", ".docx", ".hwp", ".hwpx")
KNOWN_FILE_EXTENSIONS = (
    set(DOCUMENT_EXTENSIONS)
    | set(RESOURCE_ICON_EXTENSION_MAP.values())
    | IGNORED_MEDIA_EXTENSIONS
    | {".zip", ".xls", ".xlsx", ".ppt", ".pptx", ".doc", ".docx", ".csv", ".txt"}
)
SEOUL = timezone(timedelta(hours=9))
REUSABLE_MANIFEST_ENTRY_FIELDS = (
    "klms_timestamp",
    "klms_timestamp_epoch",
    "klms_timestamp_text",
    "klms_timestamp_precision",
    "klms_timestamp_label",
    "klms_timestamp_source",
    "klms_timestamp_basis",
)
LOCAL_DOWNLOAD_FIELDS = (
    "local_downloaded_at",
    "local_downloaded_epoch",
    "local_downloaded_basis",
)


@dataclass
class ParsedPage:
    payload: dict[str, Any]
    source_url: str
    soup: BeautifulSoup


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    previous_state = (
        load_optional_json(Path(args.manifest_state_json))
        if args.manifest_state_json
        else {}
    )
    manifest, manifest_state = build_manifest(
        course_pages_json=Path(args.course_pages_json),
        page_sets=[Path(path) for path in args.pages_json],
        output_root=Path(args.output_root),
        previous_state=previous_state,
    )

    output_json = Path(args.output_json)
    write_json(output_json, manifest)

    if args.output_markdown:
        output_markdown = Path(args.output_markdown)
        write_text(output_markdown, render_markdown(manifest))

    if args.output_manifest_state_json:
        output_manifest_state = Path(args.output_manifest_state_json)
        write_json(output_manifest_state, manifest_state)

    print(f"manifest={output_json}")
    print(f"files={len(manifest)}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--course-pages-json", required=True)
    parser.add_argument("--pages-json", action="append", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--output-markdown")
    parser.add_argument("--manifest-state-json")
    parser.add_argument("--output-manifest-state-json")
    return parser


def build_manifest(
    course_pages_json: Path,
    page_sets: list[Path],
    output_root: Path,
    previous_state: dict[str, Any] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    course_pages = load_pages(course_pages_json)
    prepared_course_pages = prepare_pages(course_pages)
    current_courses = {
        normalize_course_name(page.payload.get("title", "").removeprefix("강좌:")): {
            "page_url": page.source_url
        }
        for page in prepared_course_pages
        if normalize_course_name(page.payload.get("title", "").removeprefix("강좌:"))
    }
    pages: list[dict[str, Any]] = []
    for path in page_sets:
        pages.extend(load_pages(path))
    prepared_pages = unique_prepared_pages(prepare_pages(pages))
    previous_sources = (
        previous_state.get("sources", {})
        if isinstance(previous_state, dict) and isinstance(previous_state.get("sources"), dict)
        else {}
    )

    activity_lookup = build_activity_lookup(prepared_course_pages + prepared_pages)
    manifest: list[dict[str, Any]] = []
    seen_urls: set[str] = set()
    seen_paths: set[str] = set()
    next_sources: dict[str, dict[str, Any]] = {}

    for parsed_page in prepared_pages:
        page = parsed_page.payload
        soup = parsed_page.soup
        source_url = parsed_page.source_url
        if is_downloadable_file_url(source_url):
            continue
        course = determine_course_name(page, soup, activity_lookup)
        if not course or course not in current_courses:
            continue

        previous_source_state = (
            previous_sources.get(source_url, {})
            if isinstance(previous_sources.get(source_url, {}), dict)
            else {}
        )
        page_signature = source_page_signature(page)
        page_entries = reusable_manifest_entries(
            previous_source_state,
            page_signature,
            current_courses,
            output_root,
        )
        if page_entries is None or entries_conflict(page_entries, seen_urls, seen_paths):
            page_entries = build_manifest_entries_for_page(
                parsed_page,
                output_root,
                activity_lookup,
                current_courses,
                seen_urls,
                seen_paths,
            )
        else:
            register_entries(page_entries, seen_urls, seen_paths)

        manifest.extend(page_entries)
        next_sources[source_url] = {
            "entry_style_version": MANIFEST_SOURCE_ENTRY_STYLE_VERSION,
            "page_signature": page_signature,
            "entries": page_entries,
        }

    manifest.sort(key=lambda item: (item["course"], item["bucket"], item["relative_path"]))
    return manifest, {"version": 1, "sources": next_sources}


def load_pages(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    return json.loads(path.read_text(encoding="utf-8"))


def load_optional_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def prepare_pages(pages: list[dict[str, Any]]) -> list[ParsedPage]:
    return [
        ParsedPage(
            payload=page,
            source_url=page.get("requestedUrl") or page.get("url") or "",
            soup=BeautifulSoup(page.get("html", ""), "html.parser"),
        )
        for page in pages
    ]


def unique_prepared_pages(pages: list[ParsedPage]) -> list[ParsedPage]:
    seen_urls: set[str] = set()
    unique_pages: list[ParsedPage] = []
    for parsed_page in pages:
        source_url = parsed_page.source_url
        if not source_url or source_url in seen_urls:
            continue
        seen_urls.add(source_url)
        unique_pages.append(parsed_page)
    return unique_pages


def source_page_signature(page: dict[str, Any]) -> str:
    payload = "\n".join(
        [
            str(page.get("requestedUrl") or page.get("url") or ""),
            str(page.get("title") or ""),
            str(page.get("html") or ""),
        ]
    )
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()


def reusable_manifest_entries(
    previous_source_state: dict[str, Any],
    page_signature: str,
    current_courses: dict[str, Any],
    output_root: Path,
) -> list[dict[str, Any]] | None:
    if str(previous_source_state.get("page_signature", "")) != page_signature:
        return None
    if str(previous_source_state.get("entry_style_version", "")) != MANIFEST_SOURCE_ENTRY_STYLE_VERSION:
        return None

    entries = previous_source_state.get("entries", [])
    if not isinstance(entries, list):
        return None

    reusable: list[dict[str, Any]] = []
    for item in entries:
        if not isinstance(item, dict):
            return None
        if any(field not in item for field in REUSABLE_MANIFEST_ENTRY_FIELDS):
            return None
        course = normalize_course_name(str(item.get("course", "")))
        bucket = str(item.get("bucket", ""))
        relative_path = str(item.get("relative_path", "")).strip()
        url = canonicalize_file_url(str(item.get("url", "")))
        if not course or course not in current_courses or not relative_path or not url:
            return None
        if bucket not in COURSE_MATERIAL_BUCKETS:
            continue
        reusable.append(
            {
                "course": course,
                "bucket": bucket,
                "filename": str(item.get("filename", "")),
                "relative_path": relative_path,
                "absolute_path": str(output_root / relative_path),
                "url": url,
                "source_url": str(item.get("source_url", "")),
                "source_title": str(item.get("source_title", "")),
                "link_text": normalize_whitespace(str(item.get("link_text", ""))),
                "section_title": normalize_whitespace(str(item.get("section_title", ""))),
                "activity_title": normalize_whitespace(str(item.get("activity_title", ""))),
                **copy_klms_timestamp_fields(item),
                **copy_local_download_fields(item),
            }
        )
    return reusable


def entries_conflict(
    entries: list[dict[str, Any]], seen_urls: set[str], seen_paths: set[str]
) -> bool:
    local_urls: set[str] = set()
    local_paths: set[str] = set()
    for item in entries:
        url = canonicalize_file_url(str(item.get("url", "")))
        relative_path = str(item.get("relative_path", "")).strip()
        if (
            not url
            or not relative_path
            or url in seen_urls
            or relative_path in seen_paths
            or url in local_urls
            or relative_path in local_paths
        ):
            return True
        local_urls.add(url)
        local_paths.add(relative_path)
    return False


def register_entries(entries: list[dict[str, Any]], seen_urls: set[str], seen_paths: set[str]) -> None:
    for item in entries:
        seen_urls.add(canonicalize_file_url(str(item.get("url", ""))))
        seen_paths.add(str(item.get("relative_path", "")).strip())


def build_manifest_entries_for_page(
    parsed_page: ParsedPage,
    output_root: Path,
    activity_lookup: dict[str, dict[str, str]],
    current_courses: dict[str, Any],
    seen_urls: set[str],
    seen_paths: set[str],
) -> list[dict[str, Any]]:
    page = parsed_page.payload
    soup = parsed_page.soup
    source_url = parsed_page.source_url
    course = determine_course_name(page, soup, activity_lookup)
    if not course or course not in current_courses:
        return []

    source_title = determine_source_title(page, soup, activity_lookup)
    bucket = determine_bucket(source_url)
    if bucket not in COURSE_MATERIAL_BUCKETS:
        return []
    inline_media_urls = inline_courseboard_media_urls(source_url, soup)
    timestamp_lookup = build_klms_timestamp_lookup(parsed_page, bucket)
    page_entries: list[dict[str, Any]] = []

    for target in candidate_file_targets(page, source_url, soup):
        raw_url = target["url"]
        link_text = target["link_text"]
        if not is_downloadable_file_url(raw_url):
            continue
        canonical_url = canonicalize_file_url(raw_url)
        if canonical_url in inline_media_urls:
            continue
        if canonical_url in seen_urls:
            continue

        filename = target.get("filename_hint") or filename_from_url(canonical_url or raw_url)
        if not filename or ignored_media_filename(filename):
            continue

        target_source_title = normalize_whitespace(target.get("source_title", "")) or source_title
        section_title = normalize_whitespace(target.get("section_title", ""))
        activity_title = normalize_whitespace(target.get("activity_title", "")) or normalize_whitespace(link_text)
        course_dir = sanitize_path_component(course)
        bucket_dir = sanitize_path_component(bucket)
        source_dir = sanitize_path_component(target_source_title or "untitled")
        relative_path = make_unique_relative_path(
            seen_paths,
            course_dir,
            bucket_dir,
            source_dir,
            filename,
        )
        timestamp_metadata = resolve_klms_timestamp_metadata(
            lookup=timestamp_lookup,
            canonical_url=canonical_url,
            filename=filename,
            link_text=link_text,
        )

        entry = {
            "course": course,
            "bucket": bucket,
            "filename": filename,
            "relative_path": relative_path,
            "absolute_path": str(output_root / relative_path),
            "url": canonical_url or raw_url,
            "source_url": source_url,
            "source_title": target_source_title,
            "link_text": normalize_whitespace(link_text),
            "section_title": section_title,
            "activity_title": activity_title,
            **timestamp_metadata,
        }
        page_entries.append(entry)
        seen_urls.add(canonical_url)

    return page_entries


def copy_klms_timestamp_fields(item: dict[str, Any]) -> dict[str, Any]:
    epoch_value = item.get("klms_timestamp_epoch")
    try:
        epoch_value = int(epoch_value) if epoch_value is not None else None
    except (TypeError, ValueError):
        epoch_value = None
    timestamp_value = str(item.get("klms_timestamp", ""))
    timestamp_text = str(item.get("klms_timestamp_text", ""))
    timestamp_source = str(item.get("klms_timestamp_source", ""))
    if not timestamp_value and not timestamp_text and timestamp_source == "folders-page":
        return missing_klms_timestamp_metadata(timestamp_source)

    return {
        "klms_timestamp": timestamp_value,
        "klms_timestamp_epoch": epoch_value,
        "klms_timestamp_text": timestamp_text,
        "klms_timestamp_precision": str(item.get("klms_timestamp_precision", "")),
        "klms_timestamp_label": str(item.get("klms_timestamp_label", "")),
        "klms_timestamp_source": timestamp_source,
        "klms_timestamp_basis": str(item.get("klms_timestamp_basis", "klms_page")),
    }


def copy_local_download_fields(item: dict[str, Any]) -> dict[str, Any]:
    copied: dict[str, Any] = {}
    for field in LOCAL_DOWNLOAD_FIELDS:
        if field not in item:
            continue
        value = item.get(field)
        if field == "local_downloaded_epoch":
            try:
                copied[field] = int(value) if value is not None else None
            except (TypeError, ValueError):
                copied[field] = None
        else:
            copied[field] = str(value or "")
    return copied


def build_klms_timestamp_lookup(parsed_page: ParsedPage, bucket: str) -> dict[str, Any]:
    source_url = parsed_page.source_url
    soup = parsed_page.soup

    if bucket == "resources":
        return {
            "by_url": extract_resource_timestamp_by_url(source_url, soup),
            "by_name": {},
            "default": empty_klms_timestamp_metadata("resource-index"),
        }
    if bucket == "assignment-attachments":
        return extract_assignment_timestamp_lookup(source_url, soup)
    if bucket == "board-attachments":
        return {
            "by_url": {},
            "by_name": {},
            "default": extract_board_timestamp_metadata(soup),
        }
    if bucket == "folders":
        return {
            "by_url": {},
            "by_name": {},
            "default": missing_klms_timestamp_metadata("folders-page"),
        }
    return {
        "by_url": {},
        "by_name": {},
        "default": empty_klms_timestamp_metadata(f"{bucket}-page"),
    }


def resolve_klms_timestamp_metadata(
    lookup: dict[str, Any],
    canonical_url: str,
    filename: str,
    link_text: str,
) -> dict[str, Any]:
    by_url = lookup.get("by_url", {})
    metadata = by_url.get(canonical_url)
    if metadata:
        return metadata

    by_name = lookup.get("by_name", {})
    for candidate in (
        normalize_whitespace(link_text),
        normalize_whitespace(filename),
        normalize_whitespace(Path(filename).stem),
    ):
        if candidate and candidate in by_name:
            return by_name[candidate]

    return lookup.get("default", empty_klms_timestamp_metadata("unknown"))


def extract_resource_timestamp_by_url(
    source_url: str, soup: BeautifulSoup
) -> dict[str, dict[str, Any]]:
    mapping: dict[str, dict[str, Any]] = {}
    for row in soup.select("table.mod_index tbody tr"):
        link = row.select_one("a[href]")
        cells = row.select("td")
        if not link or len(cells) < 4:
            continue
        url = canonicalize_file_url(resolve_link_url(source_url, link.get("href", "")))
        timestamp_text = normalize_whitespace(cells[-1].get_text(" ", strip=True))
        if not url:
            continue
        mapping[url] = make_klms_timestamp_metadata(
            timestamp_text=timestamp_text,
            timestamp_label="마감 일시",
            timestamp_source="resource-index",
        )
    return mapping


def extract_assignment_timestamp_lookup(source_url: str, soup: BeautifulSoup) -> dict[str, Any]:
    by_url: dict[str, dict[str, Any]] = {}
    by_name: dict[str, dict[str, Any]] = {}

    for container in soup.select("#intro li, #intro .fileuploadsubmission"):
        link = container.select_one("a[href]")
        if not link:
            continue

        wrapper = container
        if container.parent and getattr(container.parent, "name", "") in {"div", "li"}:
            wrapper = container.parent

        timestamp_node = wrapper.select_one(".fileuploadsubmissiontime") or container.select_one(
            ".fileuploadsubmissiontime"
        )
        timestamp_text = normalize_whitespace(
            timestamp_node.get_text(" ", strip=True) if timestamp_node else ""
        )
        metadata = make_klms_timestamp_metadata(
            timestamp_text=timestamp_text,
            timestamp_label="첨부 시각",
            timestamp_source="assignment-intro",
        )
        url = canonicalize_file_url(resolve_link_url(source_url, link.get("href", "")))
        if url:
            by_url[url] = metadata

        for key in (
            normalize_whitespace(link.get_text(" ", strip=True)),
            normalize_whitespace(link.get("title", "")),
        ):
            if key:
                by_name[key] = metadata

    return {
        "by_url": by_url,
        "by_name": by_name,
        "default": empty_klms_timestamp_metadata("assignment-intro"),
    }


def extract_board_timestamp_metadata(soup: BeautifulSoup) -> dict[str, Any]:
    timestamp_node = soup.select_one(".courseboard_view .info .date, .info .date")
    timestamp_text = normalize_whitespace(
        timestamp_node.get_text(" ", strip=True) if timestamp_node else ""
    )
    if ":" in timestamp_text:
        timestamp_text = timestamp_text.split(":", 1)[1].strip()
    return make_klms_timestamp_metadata(
        timestamp_text=timestamp_text,
        timestamp_label="작성일",
        timestamp_source="courseboard-article",
    )


def empty_klms_timestamp_metadata(timestamp_source: str) -> dict[str, Any]:
    return {
        "klms_timestamp": "",
        "klms_timestamp_epoch": None,
        "klms_timestamp_text": "",
        "klms_timestamp_precision": "",
        "klms_timestamp_label": "",
        "klms_timestamp_source": timestamp_source,
        "klms_timestamp_basis": "klms_page",
    }


def missing_klms_timestamp_metadata(timestamp_source: str) -> dict[str, Any]:
    return {
        "klms_timestamp": "KLMS 페이지에 시각 정보 없음",
        "klms_timestamp_epoch": None,
        "klms_timestamp_text": "KLMS 페이지에 시각 정보 없음",
        "klms_timestamp_precision": "missing",
        "klms_timestamp_label": "기준 시각",
        "klms_timestamp_source": timestamp_source,
        "klms_timestamp_basis": "klms_page_missing",
    }


def make_klms_timestamp_metadata(
    timestamp_text: str,
    timestamp_label: str,
    timestamp_source: str,
) -> dict[str, Any]:
    normalized_text = normalize_whitespace(timestamp_text)
    parsed = parse_klms_timestamp_text(normalized_text)
    metadata = {
        "klms_timestamp": "",
        "klms_timestamp_epoch": None,
        "klms_timestamp_text": normalized_text,
        "klms_timestamp_precision": "",
        "klms_timestamp_label": timestamp_label,
        "klms_timestamp_source": timestamp_source,
        "klms_timestamp_basis": "klms_page",
    }
    if parsed is None:
        return metadata

    timestamp_dt, precision = parsed
    metadata["klms_timestamp"] = format_klms_timestamp(timestamp_dt, precision)
    metadata["klms_timestamp_epoch"] = int(timestamp_dt.timestamp())
    metadata["klms_timestamp_precision"] = precision
    return metadata


def parse_klms_timestamp_text(text: str) -> tuple[datetime, str] | None:
    normalized = normalize_whitespace(text)
    if not normalized:
        return None

    match = re.search(
        r"(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일(?:\([^)]*\))?\s*(오전|오후)?\s*(\d{1,2})[:시]\s*(\d{2})?",
        normalized,
    )
    if match:
        year_text, month_text, day_text, meridiem, hour_text, minute_text = match.groups()
        hour = int(hour_text)
        minute = int(minute_text or 0)
        if meridiem == "오전" and hour == 12:
            hour = 0
        elif meridiem == "오후" and hour != 12:
            hour += 12
        return (
            datetime(int(year_text), int(month_text), int(day_text), hour, minute, tzinfo=SEOUL),
            "datetime",
        )

    match = re.search(r"(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일", normalized)
    if match:
        year_text, month_text, day_text = match.groups()
        return (
            datetime(int(year_text), int(month_text), int(day_text), 0, 0, tzinfo=SEOUL),
            "date",
        )

    match = re.search(r"(\d{4})-(\d{2})-(\d{2})", normalized)
    if match:
        year_text, month_text, day_text = match.groups()
        return (
            datetime(int(year_text), int(month_text), int(day_text), 0, 0, tzinfo=SEOUL),
            "date",
        )

    match = re.search(r"(\d{4})\.(\d{1,2})\.(\d{1,2})", normalized)
    if match:
        year_text, month_text, day_text = match.groups()
        return (
            datetime(int(year_text), int(month_text), int(day_text), 0, 0, tzinfo=SEOUL),
            "date",
        )

    return None


def format_klms_timestamp(value: datetime, precision: str) -> str:
    local_value = value.astimezone(SEOUL)
    if precision == "date":
        return local_value.strftime("%Y-%m-%d")
    return local_value.strftime("%Y-%m-%d %H:%M KST")


def build_activity_lookup(pages: list[ParsedPage]) -> dict[str, dict[str, str]]:
    lookup: dict[str, dict[str, str]] = {}
    for parsed_page in pages:
        page = parsed_page.payload
        soup = parsed_page.soup
        course = infer_course_name(page, soup)
        if not course:
            continue
        for link in scoped_activity_links(soup):
            url = normalize_url(link.get("href", ""))
            identifier = query_id(url)
            if identifier in IGNORED_ACTIVITY_IDS:
                continue
            if identifier and identifier not in lookup:
                lookup[identifier] = {
                    "course": course,
                    "title": normalize_whitespace(link.get_text(" ", strip=True)),
                }
    register_course_page_ids(lookup, pages)
    return lookup


def register_course_page_ids(
    lookup: dict[str, dict[str, str]], pages: list[ParsedPage]
) -> None:
    for parsed_page in pages:
        if "/course/view.php" not in parsed_page.source_url:
            continue
        course = infer_course_name(parsed_page.payload, parsed_page.soup)
        if not course:
            continue
        identifier = query_id(parsed_page.source_url)
        if not identifier:
            continue

        existing = lookup.get(identifier, {})
        title = normalize_whitespace(existing.get("title", "")) if existing else ""
        lookup[identifier] = {
            "course": course,
            "title": title or "course-home",
        }


def determine_course_name(
    page: dict[str, Any], soup: BeautifulSoup, activity_lookup: dict[str, dict[str, str]]
) -> str:
    inferred = infer_course_name(page, soup)
    requested_url = page.get("requestedUrl") or page.get("url") or ""
    identifier = query_id(requested_url)
    if identifier and identifier in activity_lookup:
        mapped_course = normalize_course_name(activity_lookup[identifier].get("course", ""))
        if mapped_course and mapped_course.lower() not in GENERIC_COURSE_NAMES:
            return mapped_course

    if inferred:
        return inferred

    if identifier and identifier in activity_lookup:
        return normalize_course_name(activity_lookup[identifier].get("course", ""))

    return ""


def infer_course_name(page: dict[str, Any], soup: BeautifulSoup) -> str:
    title = normalize_whitespace(page.get("title", ""))
    if title.startswith("강좌:"):
        return normalize_course_name(title.removeprefix("강좌:"))

    course_code, _ = split_page_title(title)
    if course_code:
        if course_code in IGNORED_COURSE_CODES:
            return ""
        mapped = COURSE_CODE_MAP.get(course_code)
        if mapped:
            return normalize_course_name(mapped)

    course_links = soup.select("a[href*='/course/view.php?id=']")
    for link in course_links[:5]:
        course_name = normalize_course_name(link.get_text(" ", strip=True))
        if course_name and course_name.lower() not in GENERIC_COURSE_NAMES:
            return course_name

    return ""


def determine_source_title(
    page: dict[str, Any], soup: BeautifulSoup, activity_lookup: dict[str, dict[str, str]]
) -> str:
    requested_url = page.get("requestedUrl") or page.get("url") or ""
    identifier = query_id(requested_url)
    if identifier and identifier in activity_lookup and activity_lookup[identifier].get("title"):
        return activity_lookup[identifier]["title"]

    subject = soup.select_one(".courseboard_view .subject h3")
    if subject:
        return normalize_whitespace(subject.get_text(" ", strip=True))

    title = normalize_whitespace(page.get("title", ""))
    if title.startswith("강좌:"):
        return "course-home"
    _, title_suffix = split_page_title(title)
    if title_suffix and title_suffix != title:
        return title_suffix
    return title or "untitled"


def split_page_title(title: str) -> tuple[str, str]:
    normalized = normalize_whitespace(title)
    if not normalized:
        return "", ""

    for separator in (" : ", ": "):
        if separator in normalized:
            left, right = normalized.split(separator, 1)
            return left.strip(), right.strip()

    if ":" in normalized:
        left, right = normalized.split(":", 1)
        return left.strip(), right.strip()

    return "", normalized


def determine_bucket(source_url: str) -> str:
    module = module_name_from_url(source_url)
    if module == "folder":
        return "folders"
    if module == "courseboard":
        return "board-attachments"
    if module == "resource":
        return "resources"
    if module == "assign":
        return "assignment-attachments"
    if module == "page":
        return "page-attachments"
    if module:
        return module
    return "misc"


def make_unique_relative_path(
    seen_paths: set[str],
    course_dir: str,
    bucket_dir: str,
    source_dir: str,
    filename: str,
) -> str:
    filename_path = Path(filename)
    stem = sanitize_path_component(filename_path.stem)
    suffix = filename_path.suffix
    counter = 1

    while True:
        candidate_name = f"{stem}{suffix}" if counter == 1 else f"{stem} ({counter}){suffix}"
        relative_path = str(Path(course_dir) / bucket_dir / source_dir / candidate_name)
        if relative_path not in seen_paths:
            seen_paths.add(relative_path)
            return relative_path
        counter += 1


def render_markdown(manifest: list[dict[str, Any]]) -> str:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for item in manifest:
        grouped.setdefault(item["course"], []).append(item)

    lines = ["# Course Files", ""]
    total = sum(len(items) for items in grouped.values())
    lines.append(f"- Total files: {total}")
    lines.append("")

    for course in sorted(grouped):
        lines.append(f"## {course}")
        for item in grouped[course]:
            klms_time = (
                str(item.get("klms_timestamp") or item.get("klms_timestamp_text") or "").strip()
                or "unknown"
            )
            local_time = str(item.get("local_downloaded_at") or "").strip() or "unknown"
            lines.append(
                f"- `{item['relative_path']}` <- {item['source_title']} ({item['source_url']}) "
                f"(KLMS: {klms_time}; local: {local_time})"
            )
        lines.append("")

    return "\n".join(lines)


def normalize_course_name(name: str) -> str:
    value = normalize_whitespace(name)
    value = re.sub(
        r"\s*\([A-Z]{1,8}[A-Z0-9._() -]*_20\d{2}_\d[A-Z0-9._() -]*\)\s*$",
        "",
        value,
    ).strip()
    if not value or any(keyword in value for keyword in IGNORED_COURSE_NAMES):
        return ""
    return value


def normalize_whitespace(text: str) -> str:
    return re.sub(r"\s+", " ", (text or "").replace("\xa0", " ")).strip()


def candidate_file_targets(
    page: dict[str, Any], source_url: str, soup: BeautifulSoup
) -> list[dict[str, str]]:
    targets: list[dict[str, str]] = []
    resource_index_targets = resource_index_file_targets(source_url, soup)
    if resource_index_targets:
        targets.extend(resource_index_targets)
    elif is_courseboard_article(source_url):
        links = soup.select(".files a[href]")
        targets.extend(link_targets(source_url, links))
    else:
        links = soup.select("a[href]")
        targets.extend(link_targets(source_url, links))

    direct_url = direct_download_url_from_page(page)
    if direct_url:
        targets.append({"url": direct_url, "link_text": "", "filename_hint": ""})

    deduped: list[dict[str, str]] = []
    seen: set[str] = set()
    for target in targets:
        raw_url = target["url"]
        canonical_url = canonicalize_file_url(raw_url)
        if canonical_url in seen:
            continue
        seen.add(canonical_url)
        deduped.append(target)
    return deduped


def link_targets(source_url: str, links: list[Any]) -> list[dict[str, str]]:
    targets: list[dict[str, str]] = []
    for link in links:
        raw_url = resolve_link_url(source_url, link.get("href", ""))
        link_text = normalize_whitespace(link.get_text(" ", strip=True))
        targets.append(
            {
                "url": raw_url,
                "link_text": link_text,
                "filename_hint": hinted_filename_for_link(raw_url, link, link_text),
            }
        )
    return targets


def resource_index_file_targets(source_url: str, soup: BeautifulSoup) -> list[dict[str, str]]:
    if module_name_from_url(source_url) != "resource":
        return []

    targets: list[dict[str, str]] = []
    rows = soup.select("table.mod_index tbody tr") or soup.select("table.mod_index tr")
    for row in rows:
        link = row.select_one("a[href]")
        if not link:
            continue

        cells = row.select("td")
        link_cell_index = next((index for index, cell in enumerate(cells) if cell.select_one("a[href]")), -1)
        section_title = resource_row_section_title(cells, link_cell_index)
        raw_url = resolve_link_url(source_url, link.get("href", ""))
        link_text = normalize_whitespace(link.get_text(" ", strip=True))
        targets.append(
            {
                "url": raw_url,
                "link_text": link_text,
                "filename_hint": hinted_filename_for_link(raw_url, link, link_text),
                "source_title": section_title,
                "section_title": section_title,
                "activity_title": link_text,
            }
        )
    return targets


def resource_row_section_title(cells: list[Any], link_cell_index: int) -> str:
    if link_cell_index <= 0:
        return ""

    candidates = cells[:link_cell_index]
    if len(candidates) >= 2 and looks_like_row_number(normalize_whitespace(candidates[0].get_text(" ", strip=True))):
        candidates = candidates[1:]

    for cell in reversed(candidates):
        text = normalize_whitespace(cell.get_text(" ", strip=True))
        if text and not looks_like_row_number(text):
            return text
    return ""


def looks_like_row_number(text: str) -> bool:
    return bool(re.fullmatch(r"\d+", normalize_whitespace(text)))


def inline_courseboard_media_urls(source_url: str, soup: BeautifulSoup) -> set[str]:
    if not is_courseboard_article(source_url):
        return set()
    urls: set[str] = set()
    for node in soup.select(COURSEBOARD_INLINE_MEDIA_SELECTOR):
        raw_url = normalize_url(node.get("src", ""))
        if not raw_url:
            continue
        urls.add(canonicalize_file_url(raw_url))
    return urls


def normalize_url(url: str) -> str:
    url = (url or "").strip()
    if url.startswith("//"):
        return f"https:{url}"
    if url.startswith("/"):
        return f"https://klms.kaist.ac.kr{url}"
    return url


def resolve_link_url(source_url: str, href: str) -> str:
    normalized = normalize_url(href)
    if normalized.startswith("http://") or normalized.startswith("https://"):
        return normalized
    return normalize_url(urljoin(source_url, href))


def direct_download_url_from_page(page: dict[str, Any]) -> str:
    requested_url = page.get("requestedUrl") or page.get("url") or ""
    if "/mod/resource/view.php" in requested_url:
        return ""
    title = normalize_url(page.get("title", ""))
    if is_downloadable_file_url(title):
        return title
    return ""


def canonicalize_file_url(url: str) -> str:
    normalized = normalize_url(url)
    if not normalized:
        return ""
    parsed = urlparse(normalized)
    query_items = [
        (key, value)
        for key, value in parse_qsl(parsed.query, keep_blank_values=True)
        if key.lower() != "forcedownload"
    ]
    return urlunparse(parsed._replace(query=urlencode(query_items), fragment=""))


def query_id(url: str) -> str:
    match = re.search(r"[?&]id=([^&#]+)", url)
    return match.group(1) if match else ""


def is_courseboard_article(url: str) -> bool:
    return "/mod/courseboard/article.php" in url


def module_name_from_url(url: str) -> str:
    match = re.search(r"/mod/([^/]+)/", url)
    return match.group(1) if match else ""


def is_downloadable_file_url(url: str) -> bool:
    lowered = url.lower()
    if not lowered.startswith("https://klms.kaist.ac.kr/"):
        return False
    if "pluginfile.php" in lowered:
        if "/assignsubmission_" in lowered or "/submission_files/" in lowered:
            return False
        return True
    if "/mod/resource/view.php" in lowered and "id=" in lowered:
        return True
    return False


def filename_from_url(url: str) -> str:
    parsed = urlparse(url)
    name = unquote(PurePosixPath(parsed.path).name)
    if name in {"view.php", "index.php", "article.php"}:
        return ""
    return sanitize_filename(name)


def scoped_activity_links(soup: BeautifulSoup) -> list[Any]:
    for selector in ("#region-main", "div[role='main']", "#page-content", "#region-main-box"):
        container = soup.select_one(selector)
        if container:
            return container.select("a[href*='/mod/'], a[href*='/course/view.php?id=']")
    return soup.select("a[href*='/mod/'], a[href*='/course/view.php?id=']")


def hinted_filename_for_link(url: str, link: Any, link_text: str) -> str:
    if not is_resource_view_url(url):
        return ""
    base = sanitize_filename(link_text)
    if not base:
        return ""
    if has_known_extension(base):
        return base
    extension = resource_extension_from_link(link)
    if not extension:
        return ""
    return sanitize_filename(f"{base}{extension}")


def is_resource_view_url(url: str) -> bool:
    lowered = (url or "").lower()
    return lowered.startswith("https://klms.kaist.ac.kr/mod/resource/view.php")


def resource_extension_from_link(link: Any) -> str:
    icon = link.select_one("img.icon[src]")
    if not icon:
        return ""
    source = normalize_url(icon.get("src", "")).lower()
    match = re.search(r"/f/([a-z0-9]+)-\d+$", source)
    if not match:
        return ""
    icon_type = match.group(1)
    return RESOURCE_ICON_EXTENSION_MAP.get(icon_type, "")


def sanitize_filename(name: str) -> str:
    value = unicodedata.normalize("NFC", normalize_whitespace(name))
    value = re.sub(INVALID_FS_CHARS, "_", value)
    return value.strip(" .")


def sanitize_path_component(name: str) -> str:
    value = sanitize_filename(name) or "untitled"
    return value


def has_known_extension(name: str) -> bool:
    return Path(name).suffix.lower() in KNOWN_FILE_EXTENSIONS


def ignored_media_filename(name: str) -> bool:
    return Path(name).suffix.lower() in IGNORED_MEDIA_EXTENSIONS


if __name__ == "__main__":
    raise SystemExit(main())
