#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--state-json", required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--write-json")
    return parser


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def stage_summary(cache_dir: Path, scope: str) -> dict[str, Any]:
    path = cache_dir / scope / "stage_timings.json"
    data = load_json(path, {})
    return {
        "scope": scope,
        "status": data.get("status", "missing"),
        "completed_at": data.get("completed_at", ""),
        "elapsed_ms": data.get("elapsed_ms", 0),
        "slowest_stages": data.get("slowest_stages", [])[:5],
    }


def calendar_command_summary(calendar_result: dict[str, Any]) -> dict[str, int]:
    created = updated = deleted = 0
    for item in calendar_result.get("summaries", []):
        created += int(item.get("created", 0) or 0)
        updated += int(item.get("updated", 0) or 0)
        deleted += int(item.get("deleted", 0) or 0)
    return {"created": created, "updated": updated, "deleted": deleted}


def build_report(cache_dir: Path, state_json: Path) -> dict[str, Any]:
    state = load_json(state_json, {})
    content = state.get("content", {}) if isinstance(state, dict) else {}
    notice_digest = load_json(cache_dir / "notice_digest.json", {})
    download = load_json(cache_dir / "course_file_download_result.json", {})
    prune = load_json(cache_dir / "course_file_prune_result.json", {})
    archive_prune = load_json(cache_dir / "course_file_archive_prune_result.json", {})
    core_timing = load_json(cache_dir / "core" / "stage_timings.json", {})
    notice_timing = load_json(cache_dir / "notice" / "stage_timings.json", {})
    files_timing = load_json(cache_dir / "files" / "stage_timings.json", {})
    calendar_result = load_json(cache_dir / "core" / "calendar_sync_result.json", {})

    results = download.get("results", [])
    new_files = int(download.get("newFilesCopiedCount", 0) or 0)
    if not new_files and isinstance(results, list):
        new_files = sum(1 for item in results if item.get("copied_to_new_files_inbox"))

    return {
        "status": "ok",
        "runs": {
            "core": stage_summary(cache_dir, "core"),
            "notice": stage_summary(cache_dir, "notice"),
            "files": stage_summary(cache_dir, "files"),
        },
        "state": {
            "assignments": len(content.get("assignments", [])) if isinstance(content, dict) else 0,
            "exams": len(content.get("exam_items", [])) if isinstance(content, dict) else 0,
            "helpdesk": len(content.get("help_desk_items", [])) if isinstance(content, dict) else 0,
        },
        "notices": {
            "total": int(notice_digest.get("notice_count", 0) or 0),
            "new": int(notice_digest.get("new_count", 0) or 0),
            "updated": int(notice_digest.get("updated_count", 0) or 0),
            "ignored": int(notice_digest.get("ignored_notice_count", 0) or 0),
        },
        "files": {
            "total": int(download.get("fileCount", 0) or 0),
            "new_files": new_files,
            "quarantine": int(download.get("quarantineCount", 0) or 0),
            "pruned": int(prune.get("deleted_file_count", 0) or 0),
            "archive_pruned": int(archive_prune.get("deleted_file_count", 0) or 0),
        },
        "calendar": calendar_command_summary(calendar_result),
        "slowest": (core_timing.get("slowest_stages", []) + notice_timing.get("slowest_stages", []) + files_timing.get("slowest_stages", []))[:5],
    }


def print_text(report: dict[str, Any]) -> None:
    runs = report["runs"]
    print("KLMS sync report")
    for name in ("core", "notice", "files"):
        run = runs[name]
        print(f"{name}: status={run['status']} completed_at={run['completed_at']} elapsed_ms={run['elapsed_ms']}")
    print(
        "state: "
        f"assignments={report['state']['assignments']} "
        f"exams={report['state']['exams']} "
        f"helpdesk={report['state']['helpdesk']}"
    )
    print(
        "notices: "
        f"total={report['notices']['total']} "
        f"new={report['notices']['new']} "
        f"updated={report['notices']['updated']} "
        f"ignored={report['notices']['ignored']}"
    )
    print(
        "files: "
        f"total={report['files']['total']} "
        f"new={report['files']['new_files']} "
        f"quarantine={report['files']['quarantine']} "
        f"pruned={report['files']['pruned']} "
        f"archive_pruned={report['files']['archive_pruned']}"
    )
    print(
        "calendar: "
        f"created={report['calendar']['created']} "
        f"updated={report['calendar']['updated']} "
        f"deleted={report['calendar']['deleted']}"
    )
    for item in report["slowest"]:
        print(f"slowest={item.get('name', '')} duration_ms={item.get('duration_ms', 0)} status={item.get('status', '')}")


def main() -> int:
    args = build_parser().parse_args()
    report = build_report(Path(args.cache_dir), Path(args.state_json))
    if args.write_json:
        Path(args.write_json).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print_text(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
    calendar_result = load_json(cache_dir / "core" / "calendar_sync_result.json", {})
