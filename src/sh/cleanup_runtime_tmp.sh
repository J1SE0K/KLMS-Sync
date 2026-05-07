#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="${KLMS_RUNTIME_TMP_CLEANUP_TARGET:-$SCRIPT_DIR/runtime/tmp}"
MAX_AGE_HOURS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-age-hours)
      MAX_AGE_HOURS="${2:-}"
      shift 2
      ;;
    *)
      print -u2 -- "Unknown argument: $1"
      exit 1
      ;;
  esac
done

mkdir -p "$TMP_DIR"

python3 - "$TMP_DIR" "$MAX_AGE_HOURS" <<'PY'
from __future__ import annotations

import math
import shutil
import sys
import time
from pathlib import Path

tmp_dir = Path(sys.argv[1])
max_age_hours_raw = sys.argv[2] if len(sys.argv) > 2 else ""
max_age_hours = None
if max_age_hours_raw:
    max_age_hours = float(max_age_hours_raw)
    if not math.isfinite(max_age_hours) or max_age_hours < 0:
        raise SystemExit("invalid --max-age-hours")
cutoff_epoch = None if max_age_hours is None else time.time() - (max_age_hours * 3600)

remove_names = {
    ".DS_Store",
    "__pycache__",
    "pycache",
    "swift-module-cache",
    "download_test_archive",
    "download_test_output",
    "download_backups",
}

remove_globs = [
    "*.pyc",
    "*.pyo",
    "*-urls.txt",
    "*test*.txt",
    "dashboard_urls.txt",
    "file_nested*_urls*.txt",
    "file_seed_changed_urls.txt",
    "file_nested_changed_urls.txt",
    "klms_login_preflight_urls.txt",
    "klms_single_manifest.json",
    "nano_quiz_pages.json",
    "notice_digest_note.html",
    "notice_note_title.txt",
    "seen_urls.txt",
    "seen_round2_urls.txt",
    "notice_user_state.json",
    "notice_note_render_state.json",
    "test_generated_section.html",
    "verify*_notice_render_state.json",
    "verify*_notice_user_state.json",
    "verify_http_dashboard*.json",
    "*test*.json",
    "direct_fetch_test.json",
    "db_*_live.json",
    "abs_test_dashboard.json",
]

deleted_files = 0
deleted_dirs = 0

for child in list(tmp_dir.rglob("*")):
    if child.name in remove_names and child.exists():
        if child.is_dir():
            shutil.rmtree(child)
            deleted_dirs += 1
        else:
            child.unlink()
            deleted_files += 1

for pattern in remove_globs:
    for path in list(tmp_dir.glob(pattern)):
        if not path.exists():
            continue
        if path.is_dir():
            shutil.rmtree(path)
            deleted_dirs += 1
        else:
            path.unlink()
            deleted_files += 1

if cutoff_epoch is not None:
    for path in sorted(tmp_dir.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        if not path.exists():
            continue
        try:
            modified_epoch = path.stat().st_mtime
        except FileNotFoundError:
            continue
        if modified_epoch >= cutoff_epoch:
            continue
        if path.is_dir():
            shutil.rmtree(path)
            deleted_dirs += 1
        else:
            path.unlink()
            deleted_files += 1

print(f"cleanup_runtime_tmp deleted_files={deleted_files} deleted_dirs={deleted_dirs}")
PY
