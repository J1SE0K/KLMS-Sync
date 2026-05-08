#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview-json", required=True)
    parser.add_argument("--prune-result-json", required=True)
    parser.add_argument("--archive-prune-result-json", required=True)
    parser.add_argument("--output-json", required=True)
    return parser


def main_with_args(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    preview = load_json(Path(args.preview_json), {})
    prune = load_json(Path(args.prune_result_json), {})
    archive_prune = load_json(Path(args.archive_prune_result_json), {})

    course_prune_count = int(prune.get("deleted_file_count", 0) or 0)
    archive_prune_count = int(archive_prune.get("deleted_file_count", 0) or 0)
    total_prune_count = course_prune_count + archive_prune_count
    would_download = int(
        preview.get(
            "fresh_download_candidate_count",
            len(preview.get("fresh_download_candidates") or []),
        )
        or 0
    )

    payload = {
        "dry_run": True,
        "scope": "files",
        "would_create": 0,
        "would_update": int(preview.get("moved_count", 0) or 0)
        + int(preview.get("type_mismatch_candidate_count", 0) or 0),
        "would_delete": total_prune_count,
        "would_download": would_download,
        "would_prune": total_prune_count,
        "would_prune_course_files": course_prune_count,
        "would_prune_archive": archive_prune_count,
        "skipped_side_effects": [
            "download",
            "copy",
            "prune-delete",
            "downloads-cleanup",
        ],
        "prune_backup_manifest": prune.get("backup_manifest_path", ""),
        "archive_prune_backup_manifest": archive_prune.get("backup_manifest_path", ""),
    }

    output_path = Path(args.output_json).expanduser().resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        f"dry-run-report path={output_path} "
        f"would_download={payload['would_download']} "
        f"would_delete={payload['would_delete']}"
    )
    return 0


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    raise SystemExit(main_with_args())
