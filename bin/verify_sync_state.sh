#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMON_SH="$SCRIPT_DIR/src/sh/klms_common.sh"
source "$COMMON_SH"

klms_init_context "$SCRIPT_DIR/verify_sync_state.sh" "${1:-}"
STATE_JSON="$SCRIPT_DIR/runtime/state/state.json"

python3 - "$CACHE_DIR" "$STATE_JSON" <<'PY'
import json
import os
import sys
from pathlib import Path

cache_dir = Path(sys.argv[1])
state_json = Path(sys.argv[2])

notice_digest = json.loads((cache_dir / "notice_digest.json").read_text())
notice_primary = json.loads((cache_dir / "notice_note_render_state.json").read_text())
notice_archive = json.loads((cache_dir / "notice_archive_note_render_state.json").read_text())
state = json.loads(state_json.read_text())
manifest = json.loads((cache_dir / "course_file_manifest.json").read_text())

digest_urls = []
for course in notice_digest.get("courses", []):
    for notice in course.get("notices", []):
        url = notice.get("url")
        if url:
            digest_urls.append(url)

rendered_urls = set()
for render_state in (notice_primary, notice_archive):
    for item in render_state.get("rendered_notices", []):
        url = item.get("notice_id")
        if url:
            rendered_urls.add(url)

missing_notice_urls = sorted(set(digest_urls) - rendered_urls)

missing_files = []
for item in manifest:
    absolute_path = item.get("absolute_path")
    relative_path = item.get("relative_path", "")
    if not absolute_path or not os.path.isfile(absolute_path):
        missing_files.append(relative_path or absolute_path or "<unknown>")

content = state.get("content", {}) if isinstance(state, dict) else {}
exam_items = content.get("exam_items", []) if isinstance(content, dict) else []
helpdesk_items = content.get("help_desk_items", []) if isinstance(content, dict) else []
assignments = content.get("assignments", []) if isinstance(content, dict) else []

print(f"notice_digest_count={len(digest_urls)}")
print(f"notice_rendered_count={len(rendered_urls)}")
print(f"notice_missing_count={len(missing_notice_urls)}")
for url in missing_notice_urls:
    print(f"notice_missing_url={url}")

print(f"manifest_file_count={len(manifest)}")
print(f"manifest_missing_file_count={len(missing_files)}")
for path in missing_files:
    print(f"manifest_missing_file={path}")

print(f"state_assignment_count={len(assignments)}")
print(f"state_exam_count={len(exam_items)}")
for item in exam_items:
    print(f"state_exam={item.get('course','')} | {item.get('title','')} | {item.get('due','')}")
print(f"state_helpdesk_count={len(helpdesk_items)}")
for item in helpdesk_items:
    print(f"state_helpdesk={item.get('course','')} | {item.get('title','')} | {item.get('due','')}")
PY

SWIFT_MODULE_CACHE_DIR="$TMP_DIR/swift-module-cache"
CLANG_MODULE_CACHE_DIR="$TMP_DIR/clang-module-cache"
mkdir -p "$SWIFT_MODULE_CACHE_DIR" "$CLANG_MODULE_CACHE_DIR"

SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_DIR" \
/usr/bin/swift -module-cache-path "$SWIFT_MODULE_CACHE_DIR" \
  "$SCRIPT_DIR/src/swift/verify_calendar_counts.swift" \
  "--exam-calendar=${EXAM_CALENDAR_NAME:-시험}" \
  "--helpdesk-calendar=${HELP_DESK_CALENDAR_NAME:-기타}"
