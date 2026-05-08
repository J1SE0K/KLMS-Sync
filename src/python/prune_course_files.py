#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any
import unicodedata


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-json", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--backup-manifest")
    parser.add_argument("--tracked-relative-paths-json")
    return parser


def canonical_relative_path(value: str) -> str:
    return unicodedata.normalize("NFC", value).casefold()


def main() -> int:
    args = build_parser().parse_args()
    manifest_path = Path(args.manifest_json)
    root = Path(args.root).resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, list):
        raise SystemExit(f"Manifest must be a JSON array: {manifest_path}")

    tracked_paths = load_tracked_paths(args, manifest)

    deleted_files: list[str] = []
    deleted_file_entries: list[dict[str, Any]] = []
    actual_files_before = 0

    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        relative_path = path.relative_to(root).as_posix()
        if relative_path == "README.md":
            continue
        actual_files_before += 1
        if canonical_relative_path(relative_path) in tracked_paths:
            continue
        deleted_files.append(relative_path)
        try:
            stat = path.stat()
            deleted_file_entries.append(
                {
                    "relative_path": relative_path,
                    "absolute_path": str(path),
                    "size": stat.st_size,
                    "mtime": stat.st_mtime,
                }
            )
        except OSError:
            deleted_file_entries.append({"relative_path": relative_path, "absolute_path": str(path)})
        if not args.dry_run:
            path.unlink()

    deleted_dirs: list[str] = []
    if not args.dry_run:
        for directory in sorted((path for path in root.rglob("*") if path.is_dir()), reverse=True):
            try:
                directory.relative_to(root)
            except ValueError:
                continue
            if directory == root:
                continue
            if any(directory.iterdir()):
                continue
            deleted_dirs.append(directory.relative_to(root).as_posix())
            directory.rmdir()

    actual_files_after = sum(
        1
        for path in root.rglob("*")
        if path.is_file() and path.relative_to(root).as_posix() != "README.md"
    )

    backup_manifest_path = ""
    if args.backup_manifest:
        backup_path = Path(args.backup_manifest)
        backup_path.parent.mkdir(parents=True, exist_ok=True)
        backup_payload = {
            "manifest_path": str(manifest_path.resolve()),
            "root": str(root),
            "dry_run": args.dry_run,
            "deleted_file_count": len(deleted_files),
            "deleted_files": deleted_file_entries,
        }
        backup_path.write_text(json.dumps(backup_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        backup_manifest_path = str(backup_path)

    payload: dict[str, Any] = {
        "manifest_path": str(manifest_path.resolve()),
        "root": str(root),
        "tracked_files": len(tracked_paths),
        "actual_files_before": actual_files_before,
        "actual_files_after": actual_files_after,
        "deleted_files": deleted_files,
        "deleted_file_count": len(deleted_files),
        "backup_manifest_path": backup_manifest_path,
        "deleted_dirs": deleted_dirs,
        "deleted_dir_count": len(deleted_dirs),
        "dry_run": args.dry_run,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def load_tracked_paths(args: argparse.Namespace, manifest: list[Any]) -> set[str]:
    if args.tracked_relative_paths_json:
        preview_path = Path(args.tracked_relative_paths_json)
        preview = json.loads(preview_path.read_text(encoding="utf-8"))
        values = preview.get("tracked_relative_paths") if isinstance(preview, dict) else None
        if not isinstance(values, list):
            raise SystemExit(f"tracked_relative_paths must be a list: {preview_path}")
        return {
            canonical_relative_path(Path(str(value)).as_posix())
            for value in values
            if str(value or "").strip()
        }

    return {
        canonical_relative_path(Path(str(item["relative_path"])).as_posix())
        for item in manifest
        if isinstance(item, dict) and item.get("relative_path")
    }


if __name__ == "__main__":
    raise SystemExit(main())
