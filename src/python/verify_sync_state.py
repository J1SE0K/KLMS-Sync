#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--state-json", required=True)
    parser.add_argument("--calendar-lines")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--write-json")
    return parser


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def parse_calendar_lines(path: Path | None) -> dict[str, Any]:
    result: dict[str, Any] = {}
    if path is None or not path.exists():
        return result
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if value.isdigit():
            result[key.strip()] = int(value)
        elif value in {"true", "false"}:
            result[key.strip()] = value == "true"
        else:
            result[key.strip()] = value
    return result


def ok_check(name: str, ok: bool, detail: str = "") -> dict[str, Any]:
    return {"name": name, "status": "ok" if ok else "fail", "detail": detail}


def build_payload(cache_dir: Path, state_json: Path, calendar_lines: Path | None) -> dict[str, Any]:
    notice_digest = load_json(cache_dir / "notice_digest.json", {})
    notice_primary = load_json(cache_dir / "notice_note_render_state.json", {})
    notice_archive = load_json(cache_dir / "notice_archive_note_render_state.json", {})
    state = load_json(state_json, {})
    manifest = load_json(cache_dir / "course_file_manifest.json", [])
    if not isinstance(manifest, list):
        manifest = []

    digest_urls: list[str] = []
    for course in notice_digest.get("courses", []):
        for notice in course.get("notices", []):
            url = notice.get("url")
            if url:
                digest_urls.append(url)

    rendered_urls: set[str] = set()
    for render_state in (notice_primary, notice_archive):
        for item in render_state.get("rendered_notices", []):
            url = item.get("notice_id")
            if url:
                rendered_urls.add(url)

    missing_notice_urls = sorted(set(digest_urls) - rendered_urls)

    missing_files: list[str] = []
    for item in manifest:
        if not isinstance(item, dict):
            continue
        absolute_path = item.get("absolute_path")
        relative_path = item.get("relative_path", "")
        if not absolute_path or not os.path.isfile(absolute_path):
            missing_files.append(relative_path or absolute_path or "<unknown>")

    content = state.get("content", {}) if isinstance(state, dict) else {}
    exam_items = content.get("exam_items", []) if isinstance(content, dict) else []
    helpdesk_items = content.get("help_desk_items", []) if isinstance(content, dict) else []
    assignments = content.get("assignments", []) if isinstance(content, dict) else []

    calendar = parse_calendar_lines(calendar_lines)
    calendar_exam_count = int(calendar.get("calendar_exam_count", 0) or 0)
    calendar_helpdesk_count = int(calendar.get("calendar_helpdesk_count", 0) or 0)
    legacy_assignment = bool(calendar.get("legacy_calendar_assignment_exists", False))
    legacy_alert = bool(calendar.get("legacy_calendar_alert_exists", False))

    checks = [
        ok_check("notice_render_complete", len(missing_notice_urls) == 0, f"missing={len(missing_notice_urls)}"),
        ok_check("manifest_files_exist", len(missing_files) == 0, f"missing={len(missing_files)}"),
        ok_check("calendar_exam_count_matches_state", calendar_exam_count == len(exam_items), f"calendar={calendar_exam_count} state={len(exam_items)}"),
        ok_check("calendar_helpdesk_count_matches_state", calendar_helpdesk_count == len(helpdesk_items), f"calendar={calendar_helpdesk_count} state={len(helpdesk_items)}"),
        ok_check("legacy_calendars_absent", not legacy_assignment and not legacy_alert, f"assignment={legacy_assignment} alert={legacy_alert}"),
    ]
    status = "ok" if all(item["status"] == "ok" for item in checks) else "fail"

    return {
        "status": status,
        "notices": {
            "digest_count": len(digest_urls),
            "rendered_count": len(rendered_urls),
            "missing_count": len(missing_notice_urls),
            "missing_urls": missing_notice_urls,
        },
        "files": {
            "manifest_file_count": len(manifest),
            "missing_file_count": len(missing_files),
            "missing_files": missing_files,
        },
        "state": {
            "assignment_count": len(assignments),
            "exam_count": len(exam_items),
            "helpdesk_count": len(helpdesk_items),
            "exam_items": [
                {"course": item.get("course", ""), "title": item.get("title", ""), "due": item.get("due", "")}
                for item in exam_items
            ],
            "helpdesk_items": [
                {"course": item.get("course", ""), "title": item.get("title", ""), "due": item.get("due", "")}
                for item in helpdesk_items
            ],
        },
        "calendar": {
            "exam_count": calendar_exam_count,
            "helpdesk_count": calendar_helpdesk_count,
            "legacy_assignment_exists": legacy_assignment,
            "legacy_alert_exists": legacy_alert,
        },
        "checks": checks,
    }


def print_text(payload: dict[str, Any]) -> None:
    notices = payload["notices"]
    files = payload["files"]
    state = payload["state"]
    calendar = payload["calendar"]
    print(f"notice_digest_count={notices['digest_count']}")
    print(f"notice_rendered_count={notices['rendered_count']}")
    print(f"notice_missing_count={notices['missing_count']}")
    for url in notices["missing_urls"]:
        print(f"notice_missing_url={url}")
    print(f"manifest_file_count={files['manifest_file_count']}")
    print(f"manifest_missing_file_count={files['missing_file_count']}")
    for path in files["missing_files"]:
        print(f"manifest_missing_file={path}")
    print(f"state_assignment_count={state['assignment_count']}")
    print(f"state_exam_count={state['exam_count']}")
    for item in state["exam_items"]:
        print(f"state_exam={item['course']} | {item['title']} | {item['due']}")
    print(f"state_helpdesk_count={state['helpdesk_count']}")
    for item in state["helpdesk_items"]:
        print(f"state_helpdesk={item['course']} | {item['title']} | {item['due']}")
    print(f"calendar_exam_count={calendar['exam_count']}")
    print(f"calendar_helpdesk_count={calendar['helpdesk_count']}")
    print(f"legacy_calendar_assignment_exists={'true' if calendar['legacy_assignment_exists'] else 'false'}")
    print(f"legacy_calendar_alert_exists={'true' if calendar['legacy_alert_exists'] else 'false'}")


def main() -> int:
    args = build_parser().parse_args()
    payload = build_payload(
        Path(args.cache_dir),
        Path(args.state_json),
        Path(args.calendar_lines) if args.calendar_lines else None,
    )
    if args.write_json:
        Path(args.write_json).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print_text(payload)
    return 0 if payload["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
