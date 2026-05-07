#!/bin/zsh

set -euo pipefail

COMMON_SH="$(cd "$(dirname "$0")" && pwd)/src/sh/klms_common.sh"
source "$COMMON_SH"

klms_init_context "$0" "${1:-}"
klms_acquire_shared_sync_lock
trap 'klms_release_shared_sync_lock' EXIT

WAIT_SECONDS="${SAFARI_WAIT_SECONDS:-6}"
FILE_REFRESH_MODE="${FILE_REFRESH_MODE:-auto}"
FILE_MINIMAL_EXPLORATION_ENABLED="${FILE_MINIMAL_EXPLORATION_ENABLED:-1}"
FETCH_MIN_WAIT_SECONDS="${FETCH_MIN_WAIT_SECONDS:-1.5}"
FETCH_STABLE_POLLS="${FETCH_STABLE_POLLS:-2}"
FILE_DOWNLOAD_TIMEOUT_SECONDS="${FILE_DOWNLOAD_TIMEOUT_SECONDS:-180}"
FILE_MAX_DOWNLOAD_ATTEMPTS="${FILE_MAX_DOWNLOAD_ATTEMPTS:-3}"
FILE_DOWNLOAD_RETRY_DELAY_SECONDS="${FILE_DOWNLOAD_RETRY_DELAY_SECONDS:-2}"
FILE_FORCE_DOWNLOAD="${FILE_FORCE_DOWNLOAD:-0}"
FILE_FULL_TTL_SECONDS="${FILE_FULL_TTL_SECONDS:-259200}"
FILE_COURSE_PAGE_STALE_SECONDS="${FILE_COURSE_PAGE_STALE_SECONDS:-43200}"
FILE_ALL_WEEK_COURSE_PAGE_STALE_SECONDS="${FILE_ALL_WEEK_COURSE_PAGE_STALE_SECONDS:-43200}"
FILE_SEED_QUICK_LIMIT_RAW="${FILE_SEED_QUICK_LIMIT:-}"
FILE_SEED_STALE_SECONDS="${FILE_SEED_STALE_SECONDS:-43200}"
FILE_NESTED_QUICK_LIMIT_RAW="${FILE_NESTED_QUICK_LIMIT:-}"
FILE_NESTED_STALE_SECONDS="${FILE_NESTED_STALE_SECONDS:-86400}"
FILE_NESTED2_QUICK_LIMIT_RAW="${FILE_NESTED2_QUICK_LIMIT:-}"
FILE_NESTED2_STALE_SECONDS="${FILE_NESTED2_STALE_SECONDS:-86400}"
FILE_NESTED_BACKGROUND_QUICK_LIMIT_RAW="${FILE_NESTED_BACKGROUND_QUICK_LIMIT:-}"
FILE_NESTED2_BACKGROUND_QUICK_LIMIT_RAW="${FILE_NESTED2_BACKGROUND_QUICK_LIMIT:-}"
FILE_KEEP_FRESH_DOWNLOADS="${FILE_KEEP_FRESH_DOWNLOADS:-1}"
FILE_WEEKLY_FOLDERS_ENABLED_RAW="${FILE_WEEKLY_FOLDERS_ENABLED:-1}"
case "${FILE_WEEKLY_FOLDERS_ENABLED_RAW:l}" in
  1|true|yes|on)
    FILE_WEEKLY_FOLDERS_ENABLED="1"
    ;;
  0|false|no|off)
    FILE_WEEKLY_FOLDERS_ENABLED="0"
    ;;
  *)
    print -u2 -- "Invalid FILE_WEEKLY_FOLDERS_ENABLED: $FILE_WEEKLY_FOLDERS_ENABLED_RAW"
    exit 1
    ;;
esac
FILE_PRIMARY_BOARD_ALWAYS_FETCH_ONLY="${FILE_PRIMARY_BOARD_ALWAYS_FETCH_ONLY:-1}"
FETCH_AUTO_FULL_MIN_COVERAGE_RAW="${FETCH_AUTO_FULL_MIN_COVERAGE:-}"
FETCH_AUTO_REQUIRE_LAST_FULL_RAW="${FETCH_AUTO_REQUIRE_LAST_FULL:-}"
FETCH_AUTO_FULL_ON_TTL_EXPIRE_RAW="${FETCH_AUTO_FULL_ON_TTL_EXPIRE:-}"

FETCH_CACHE_STATE_PATH="${FETCH_CACHE_STATE_PATH:-$WORK_CACHE_DIR/fetch_state.json}"

DASHBOARD_JSON="$WORK_CACHE_DIR/dashboard.json"
COURSE_URLS_TXT="$WORK_CACHE_DIR/course_urls.txt"
COURSE_PAGES_JSON="$WORK_CACHE_DIR/course_pages.json"
ALL_WEEK_COURSE_URLS_TXT="$WORK_CACHE_DIR/all_week_course_urls.txt"
ALL_WEEK_COURSE_PAGES_JSON="$WORK_CACHE_DIR/all_week_course_pages.json"
FILE_PRIMARY_SUPPLEMENTAL_URLS_TXT="$WORK_CACHE_DIR/file_primary_supplemental_urls.txt"
FILE_SEED_URLS_TXT="$WORK_CACHE_DIR/file_seed_urls.txt"
FILE_SEED_PAGES_JSON="$WORK_CACHE_DIR/file_seed_pages.json"
FILE_NESTED_URLS_TXT="$WORK_CACHE_DIR/file_nested_urls.txt"
FILE_NESTED_PAGES_JSON="$WORK_CACHE_DIR/file_nested_pages.json"
FILE_NESTED_INDEX_JSON="$WORK_CACHE_DIR/file_nested_index.json"
FILE_NESTED2_URLS_TXT="$WORK_CACHE_DIR/file_nested_round2_urls.txt"
FILE_NESTED2_PAGES_JSON="$WORK_CACHE_DIR/file_nested_round2_pages.json"
FILE_NESTED2_INDEX_JSON="$WORK_CACHE_DIR/file_nested_round2_index.json"
MANIFEST_JSON="$CACHE_DIR/course_file_manifest.json"
MANIFEST_MD="$CACHE_DIR/course_file_manifest.md"
MANIFEST_STATE_JSON="$CACHE_DIR/course_file_manifest_state.json"
DOWNLOAD_LOG_JSON="$CACHE_DIR/course_file_download_log.json"
DOWNLOAD_RESULT_JSON="$CACHE_DIR/course_file_download_result.json"
PRUNE_RESULT_JSON="$CACHE_DIR/course_file_prune_result.json"
CLEANUP_RESULT_JSON="$CACHE_DIR/course_file_cleanup_result.json"
SYNC_PREVIEW_JSON="$CACHE_DIR/course_file_sync_preview.json"
QUARANTINE_REPORT_JSON="$CACHE_DIR/course_file_quarantine_report.json"
FILE_SEED_FETCH_SUMMARY_JSON="$WORK_CACHE_DIR/file_seed_fetch_summary.json"
FILE_NESTED_FETCH_SUMMARY_JSON="$WORK_CACHE_DIR/file_nested_fetch_summary.json"
FILE_NESTED2_FETCH_SUMMARY_JSON="$WORK_CACHE_DIR/file_nested_round2_fetch_summary.json"
FILE_COURSE_FETCH_SUMMARY_JSON="$WORK_CACHE_DIR/course_fetch_summary.json"
FILE_ALL_WEEK_COURSE_FETCH_SUMMARY_JSON="$WORK_CACHE_DIR/all_week_course_fetch_summary.json"
OUTPUT_ROOT="$SCRIPT_DIR/course_files"
SHARED_COURSE_PAGES_JSON="${KLMS_SHARED_COURSE_PAGES_JSON:-$CACHE_DIR/core/course_pages.json}"
SHARED_ALL_WEEK_COURSE_PAGES_JSON="${KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON:-$CACHE_DIR/core/all_week_course_pages.json}"
SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON="${KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON:-$CACHE_DIR/core/supplemental_primary_pages.json}"
SHARED_SUPPLEMENTAL_SECONDARY_PAGES_JSON="${KLMS_SHARED_SUPPLEMENTAL_SECONDARY_PAGES_JSON:-$CACHE_DIR/core/supplemental_secondary_pages.json}"
SHARED_SUPPLEMENTAL_DETAIL_PAGES_JSON="${KLMS_SHARED_SUPPLEMENTAL_DETAIL_PAGES_JSON:-$CACHE_DIR/core/supplemental_detail_pages.json}"
SHARED_DETAIL_PAGES_JSON="${KLMS_SHARED_DETAIL_PAGES_JSON:-$CACHE_DIR/core/details.json}"

mkdir -p "$CACHE_DIR" "$WORK_CACHE_DIR" "$TMP_DIR"
FILES_TIMING_LOG="$WORK_CACHE_DIR/stage_timings.log"
: > "$FILES_TIMING_LOG"

log_files_timing() {
  local message="$1"
  local line
  line="[files $(date '+%Y-%m-%d %H:%M:%S %Z')] $message"
  print -r -- "$line" >> "$FILES_TIMING_LOG"
  print -r -- "$line" >&2
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_quick_limit() {
  local explicit_value="$1"
  local legacy_default="$2"
  local minimal_default="$3"

  if [[ -n "$explicit_value" ]]; then
    print -r -- "$explicit_value"
    return
  fi

  if is_truthy "$FILE_MINIMAL_EXPLORATION_ENABLED"; then
    print -r -- "$minimal_default"
  else
    print -r -- "$legacy_default"
  fi
}

resolve_mode_hint() {
  local explicit_value="$1"
  local legacy_default="$2"
  local minimal_default="$3"

  if [[ -n "$explicit_value" ]]; then
    print -r -- "$explicit_value"
    return
  fi

  if is_truthy "$FILE_MINIMAL_EXPLORATION_ENABLED"; then
    print -r -- "$minimal_default"
  else
    print -r -- "$legacy_default"
  fi
}

FILE_SEED_QUICK_LIMIT="$(resolve_quick_limit "$FILE_SEED_QUICK_LIMIT_RAW" "24" "0")"
FILE_NESTED_QUICK_LIMIT="$(resolve_quick_limit "$FILE_NESTED_QUICK_LIMIT_RAW" "24" "0")"
FILE_NESTED2_QUICK_LIMIT="$(resolve_quick_limit "$FILE_NESTED2_QUICK_LIMIT_RAW" "12" "0")"
FILE_NESTED_BACKGROUND_QUICK_LIMIT="$(resolve_quick_limit "$FILE_NESTED_BACKGROUND_QUICK_LIMIT_RAW" "4" "0")"
FILE_NESTED2_BACKGROUND_QUICK_LIMIT="$(resolve_quick_limit "$FILE_NESTED2_BACKGROUND_QUICK_LIMIT_RAW" "2" "0")"
FETCH_AUTO_FULL_MIN_COVERAGE="$(resolve_mode_hint "$FETCH_AUTO_FULL_MIN_COVERAGE_RAW" "0.5" "0.2")"
FETCH_AUTO_REQUIRE_LAST_FULL="$(resolve_mode_hint "$FETCH_AUTO_REQUIRE_LAST_FULL_RAW" "1" "0")"
FETCH_AUTO_FULL_ON_TTL_EXPIRE="$(resolve_mode_hint "$FETCH_AUTO_FULL_ON_TTL_EXPIRE_RAW" "1" "0")"

FILE_FETCH_ALWAYS_PATTERNS=(
  "/mod/courseboard/view\\.php"
  "/index\\.php\\?id="
)
FILE_SEED_INDEX_ALWAYS_PATTERNS=(
  "/mod/assign/index\\.php"
  "/mod/resource/index\\.php"
)
if is_truthy "$FILE_MINIMAL_EXPLORATION_ENABLED"; then
  FILE_FETCH_ALWAYS_PATTERNS=("/mod/courseboard/view\\.php")
fi

build_exact_courseboard_patterns() {
  local urls_txt="$1"

  python3 - "$urls_txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(0)

seen = set()
for raw_line in path.read_text(encoding="utf-8").splitlines():
    value = raw_line.strip()
    if not value or "/mod/courseboard/view.php" not in value.lower():
        continue
    if value in seen:
        continue
    seen.add(value)
    print("^" + re.escape(value) + "$")
PY
}

count_manifest_entries() {
  local manifest_json="$1"
  python3 - "$manifest_json" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
if not manifest_path.exists():
    print(0)
    raise SystemExit(0)

try:
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
except Exception:
    print(0)
    raise SystemExit(0)

print(len(payload) if isinstance(payload, list) else 0)
PY
}

count_tracked_output_files() {
  local output_root="$1"
  python3 - "$output_root" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
if not root.exists():
    print(0)
    raise SystemExit(0)

count = sum(
    1
    for path in root.rglob("*")
    if path.is_file() and path.name != "README.md"
)
print(count)
PY
}

run_fetch_backend() {
  local context="$1"
  local out_json="$2"
  local url_file="$3"
  local mode="$4"
  local quick_limit="$5"
  local stale_seconds="$6"
  local full_ttl_seconds="$7"
  local summary_json="$8"
  shift 8
  local always_patterns=("$@")
  local started_epoch
  local finished_epoch
  local fetch_status=0

  started_epoch="$(date +%s)"
  log_files_timing "fetch start context=$context mode=$mode quick_limit=$quick_limit stale_seconds=$stale_seconds"

  if [[ ! -s "$url_file" ]]; then
    printf '[]\n' > "$out_json"
    if [[ -n "$summary_json" ]]; then
      cat > "$summary_json" <<EOF
{"context":"$context","backend":"safari","requested_mode":"$mode","effective_mode":"$mode","total_urls":0,"fetched_urls":0,"reused_urls":0,"changed_urls":0,"fetched_url_list":[],"reused_url_list":[],"changed_url_list":[],"out_path":"$out_json","cache_state_path":"$FETCH_CACHE_STATE_PATH"}
EOF
    fi
    finished_epoch="$(date +%s)"
    log_files_timing "fetch finish context=$context status=0 duration_s=$((finished_epoch - started_epoch)) empty_url_file=1"
    return
  fi

  local argv=(
    /usr/bin/env
    python3
    "$KLMS_PYTHON_DIR/fetch_pages_backend.py"
    "--backend=safari"
    "--mode=$mode"
    "--context=$context"
    "--wait=$WAIT_SECONDS"
    "--min-wait=$FETCH_MIN_WAIT_SECONDS"
    "--stable-polls=$FETCH_STABLE_POLLS"
    "--out=$out_json"
    "--cache-state=$FETCH_CACHE_STATE_PATH"
    "--url-file=$url_file"
    "--quick-limit=$quick_limit"
    "--stale-seconds=$stale_seconds"
    "--full-ttl-seconds=$full_ttl_seconds"
    "--auto-full-min-coverage=$FETCH_AUTO_FULL_MIN_COVERAGE"
    "--auto-full-require-last-full=$FETCH_AUTO_REQUIRE_LAST_FULL"
    "--auto-full-on-ttl-expire=$FETCH_AUTO_FULL_ON_TTL_EXPIRE"
  )
	  [[ -n "$summary_json" ]] && argv+=("--summary-out=$summary_json")
	  local fallback_pages=()
	  local fallback_path
	  local fallback_added=0
	  case "$context" in
	    files-course-pages)
	      fallback_pages=("$SHARED_COURSE_PAGES_JSON")
	      ;;
	    files-all-week-course-pages)
	      fallback_pages=("$SHARED_ALL_WEEK_COURSE_PAGES_JSON")
	      ;;
	    files-seed-pages)
	      fallback_pages=(
	        "$SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON"
	        "$SHARED_SUPPLEMENTAL_SECONDARY_PAGES_JSON"
	        "$SHARED_SUPPLEMENTAL_DETAIL_PAGES_JSON"
	        "$SHARED_DETAIL_PAGES_JSON"
	      )
	      ;;
	  esac
	  for fallback_path in "${fallback_pages[@]}"; do
	    if shared_pages_fresh "$fallback_path"; then
	      argv+=("--fallback-pages-json=$fallback_path")
	      fallback_added=1
	    fi
	  done
	  if (( fallback_added )) && [[ "$context" != "files-seed-pages" ]]; then
	    argv+=("--reuse-fallback-always-fetch")
	  fi

  local pattern
  for pattern in "${always_patterns[@]}"; do
    [[ -n "$pattern" ]] && argv+=("--always-fetch-pattern=$pattern")
  done

  (
    cd "$SCRIPT_DIR"
    "${argv[@]}"
  ) || fetch_status=$?
  finished_epoch="$(date +%s)"
	  log_files_timing "fetch finish context=$context status=$fetch_status duration_s=$((finished_epoch - started_epoch))"
	  return "$fetch_status"
	}

summary_changed_count() {
  local summary_json="$1"
  python3 - "$summary_json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print(-1)
    raise SystemExit(0)

try:
    payload = json.loads(path.read_text(encoding="utf-8"))
    print(int(payload.get("changed_urls", -1)))
except Exception:
    print(-1)
PY
}

write_existing_download_result_if_complete() {
  local manifest_json="$1"
  local output_root="$2"
  local download_log_json="$3"
  local download_result_json="$4"
  local download_archive_root="$5"

  python3 - \
    "$manifest_json" \
    "$output_root" \
    "$download_log_json" \
    "$download_result_json" \
    "$download_archive_root" <<'PY'
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

manifest_path = Path(sys.argv[1])
output_root = Path(sys.argv[2])
download_log_path = Path(sys.argv[3])
download_result_path = Path(sys.argv[4])
archive_root = Path(sys.argv[5])

manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else []
if not isinstance(manifest, list):
    raise SystemExit(1)

previous_results = []
if download_log_path.exists():
    try:
        previous = json.loads(download_log_path.read_text(encoding="utf-8"))
        previous_results = previous.get("results") or []
    except Exception:
        previous_results = []

previous_by_url = {
    str(item.get("url") or ""): item
    for item in previous_results
    if isinstance(item, dict) and str(item.get("url") or "")
}
previous_by_relative = {
    str(item.get("relative_path") or ""): item
    for item in previous_results
    if isinstance(item, dict) and str(item.get("relative_path") or "")
}

timestamp_keys = [
    "klms_timestamp",
    "klms_timestamp_text",
    "klms_timestamp_precision",
    "klms_timestamp_label",
    "klms_timestamp_source",
    "klms_timestamp_basis",
    "klms_timestamp_epoch",
]
local_keys = [
    "local_downloaded_at",
    "local_downloaded_basis",
    "local_downloaded_epoch",
]

def kst_text(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, ZoneInfo("Asia/Seoul")).strftime("%Y-%m-%d %H:%M KST")

results = []
for index, entry in enumerate(manifest, start=1):
    relative_path = str(entry.get("relative_path") or entry.get("filename") or "").strip()
    filename = str(entry.get("filename") or Path(relative_path).name).strip()
    if not relative_path or not filename:
        raise SystemExit(1)

    destination_path = output_root / relative_path
    archive_path = archive_root / relative_path
    if not destination_path.is_file():
        raise SystemExit(1)
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    if not archive_path.is_file():
        shutil.copy2(destination_path, archive_path)

    previous = previous_by_url.get(str(entry.get("url") or "")) or previous_by_relative.get(relative_path) or {}
    local_epoch = previous.get("local_downloaded_epoch")
    try:
        local_epoch = int(local_epoch)
    except Exception:
        local_epoch = int(destination_path.stat().st_mtime)

    result = {
        "index": index,
        "course": entry.get("course") or "",
        "filename": filename,
        "relative_path": relative_path,
        "manifest_filename": filename,
        "manifest_relative_path": relative_path,
        "destination_path": str(destination_path),
        "downloads_root": str(archive_root),
        "downloads_relative_path": relative_path,
        "downloads_filename": archive_path.name,
        "downloads_path": str(archive_path),
        "bytes": destination_path.stat().st_size,
        "source_url": entry.get("source_url") or "",
        "url": entry.get("url") or "",
        "skipped_existing": True,
        "auxiliary_paths": [],
    }
    for key in timestamp_keys:
        if key in entry:
            result[key] = entry.get(key)
    for key in local_keys:
        if key in previous:
            result[key] = previous.get(key)
    result.setdefault("local_downloaded_at", kst_text(local_epoch))
    result.setdefault("local_downloaded_basis", previous.get("local_downloaded_basis") or "existing-file")
    result.setdefault("local_downloaded_epoch", local_epoch)
    results.append(result)

payload = {
    "manifestPath": str(manifest_path),
    "outputRoot": str(output_root),
    "downloadLogPath": str(download_log_path),
    "fileCount": len(results),
    "results": results,
}
download_result_path.parent.mkdir(parents=True, exist_ok=True)
download_log_path.parent.mkdir(parents=True, exist_ok=True)
download_result_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
download_log_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
PY
}

shared_pages_fresh() {
  local path="$1"
  local run_started="${KLMS_RUN_STARTED_EPOCH:-}"
  [[ -n "$run_started" && "$run_started" == <-> ]] || return 1
  [[ -s "$path" ]] || return 1
  (( $(/usr/bin/stat -f %m "$path" 2>/dev/null || print 0) >= run_started ))
}

filter_new_urls() {
  local raw_urls="$1"
  local out_urls="$2"
  shift 2

  if [[ ! -s "$raw_urls" ]]; then
    : > "$out_urls"
    return
  fi

  local seen_urls="$TMP_DIR/seen_urls.txt"
  if (( $# > 0 )); then
    cat "$@" | sed '/^[[:space:]]*$/d' | sort -u > "$seen_urls"
    comm -23 <(sed '/^[[:space:]]*$/d' "$raw_urls" | sort -u) "$seen_urls" > "$out_urls"
  else
    sed '/^[[:space:]]*$/d' "$raw_urls" | sort -u > "$out_urls"
  fi
}

write_changed_urls_from_summary() {
  local summary_json="$1"
  local out_txt="$2"

  python3 - "$summary_json" "$out_txt" <<'PY'
import json
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

urls = []
if summary_path.exists():
    try:
        payload = json.loads(summary_path.read_text(encoding="utf-8"))
        urls = payload.get("changed_url_list") or []
    except Exception:
        urls = []

out_path.write_text(
    "\n".join(str(url).strip() for url in urls if str(url).strip()) + ("\n" if urls else ""),
    encoding="utf-8",
)
PY
}

build_linked_html_index() {
  local pages_json="$1"
  local existing_index_json="$2"
  local changed_urls_txt="$3"
  local output_index_json="$4"
  local output_urls_txt="$5"
  local file_scan_flag="$6"

  local argv=(
    python3
    "$KLMS_PYTHON_DIR/klms_sync.py"
    build-linked-html-index
    --pages-json "$pages_json"
    --output-index-json "$output_index_json"
    --output-urls-txt "$output_urls_txt"
  )

  [[ -f "$existing_index_json" ]] && argv+=(--existing-index-json "$existing_index_json")
  [[ -s "$changed_urls_txt" ]] && argv+=(--changed-requested-url-file "$changed_urls_txt")
  [[ "$file_scan_flag" == "1" ]] && argv+=(--file-scan)

  (cd "$SCRIPT_DIR" && "${argv[@]}")
}

cd "$SCRIPT_DIR"
log_files_timing "refresh start output_root=$OUTPUT_ROOT mode=$FILE_REFRESH_MODE force_download=$FILE_FORCE_DOWNLOAD weekly_folders=$FILE_WEEKLY_FOLDERS_ENABLED"

PREVIOUS_MANIFEST_COUNT="$(count_manifest_entries "$MANIFEST_JSON")"
EXISTING_TRACKED_FILE_COUNT="$(count_tracked_output_files "$OUTPUT_ROOT")"

log_files_timing "login check start"
klms_require_login
log_files_timing "login check finish"
if [[ "${KLMS_LOGIN_PREFETCH_READY:-0}" == "1" ]]; then
  export KLMS_USE_EXISTING_DASHBOARD=1
fi

if [[ "${KLMS_USE_EXISTING_DASHBOARD:-0}" != "1" || ! -s "$DASHBOARD_JSON" ]]; then
  printf '%s\n' "https://klms.kaist.ac.kr/my/" > "$TMP_DIR/dashboard_urls.txt"
  run_fetch_backend \
    "files-dashboard" \
    "$DASHBOARD_JSON" \
    "$TMP_DIR/dashboard_urls.txt" \
    "full" \
    0 \
    0 \
    "$FILE_FULL_TTL_SECONDS" \
    ""
fi

klms_check_login_pages \
  "$DASHBOARD_JSON" \
  "KLMS login required before file refresh. Open Safari and sign in again."

python3 "$KLMS_PYTHON_DIR/klms_sync.py" list-course-urls --dashboard-json "$DASHBOARD_JSON" > "$COURSE_URLS_TXT"
run_fetch_backend \
  "files-course-pages" \
  "$COURSE_PAGES_JSON" \
  "$COURSE_URLS_TXT" \
  "$FILE_REFRESH_MODE" \
  0 \
  "$FILE_COURSE_PAGE_STALE_SECONDS" \
  "$FILE_FULL_TTL_SECONDS" \
  "$FILE_COURSE_FETCH_SUMMARY_JSON"

sed -E 's#(https://klms\.kaist\.ac\.kr/course/view\.php\?id=[0-9]+).*$#\1\&section=0#' \
  "$COURSE_URLS_TXT" \
  | sed '/^[[:space:]]*$/d' \
  | sort -u > "$ALL_WEEK_COURSE_URLS_TXT"
run_fetch_backend \
  "files-all-week-course-pages" \
  "$ALL_WEEK_COURSE_PAGES_JSON" \
  "$ALL_WEEK_COURSE_URLS_TXT" \
  "$FILE_REFRESH_MODE" \
  0 \
  "$FILE_ALL_WEEK_COURSE_PAGE_STALE_SECONDS" \
  "$FILE_FULL_TTL_SECONDS" \
  "$FILE_ALL_WEEK_COURSE_FETCH_SUMMARY_JSON"

python3 "$KLMS_PYTHON_DIR/klms_sync.py" list-supplemental-urls \
  --course-pages-json "$ALL_WEEK_COURSE_PAGES_JSON" \
  --tier=primary \
  > "$FILE_PRIMARY_SUPPLEMENTAL_URLS_TXT"

COURSE_CHANGED_COUNT="$(summary_changed_count "$FILE_COURSE_FETCH_SUMMARY_JSON")"
ALL_WEEK_COURSE_CHANGED_COUNT="$(summary_changed_count "$FILE_ALL_WEEK_COURSE_FETCH_SUMMARY_JSON")"
FILE_SEED_EFFECTIVE_STALE_SECONDS="$FILE_SEED_STALE_SECONDS"

FILE_SEED_FETCH_ALWAYS_PATTERNS=("${FILE_FETCH_ALWAYS_PATTERNS[@]}")
FILE_NESTED_FETCH_ALWAYS_PATTERNS=("${FILE_FETCH_ALWAYS_PATTERNS[@]}")
FILE_NESTED2_FETCH_ALWAYS_PATTERNS=("${FILE_FETCH_ALWAYS_PATTERNS[@]}")
if is_truthy "$FILE_MINIMAL_EXPLORATION_ENABLED" && is_truthy "$FILE_PRIMARY_BOARD_ALWAYS_FETCH_ONLY"; then
  FILE_SEED_FETCH_ALWAYS_PATTERNS=(
    "${(@f)$(build_exact_courseboard_patterns "$FILE_PRIMARY_SUPPLEMENTAL_URLS_TXT")}"
    "${FILE_SEED_INDEX_ALWAYS_PATTERNS[@]}"
  )
  FILE_NESTED_FETCH_ALWAYS_PATTERNS=()
  FILE_NESTED2_FETCH_ALWAYS_PATTERNS=()
fi

python3 "$KLMS_PYTHON_DIR/klms_sync.py" list-file-seed-urls --course-pages-json "$ALL_WEEK_COURSE_PAGES_JSON" > "$FILE_SEED_URLS_TXT"
run_fetch_backend \
  "files-seed-pages" \
  "$FILE_SEED_PAGES_JSON" \
  "$FILE_SEED_URLS_TXT" \
  "$FILE_REFRESH_MODE" \
  "$FILE_SEED_QUICK_LIMIT" \
  "$FILE_SEED_EFFECTIVE_STALE_SECONDS" \
  "$FILE_FULL_TTL_SECONDS" \
  "$FILE_SEED_FETCH_SUMMARY_JSON" \
  "${FILE_SEED_FETCH_ALWAYS_PATTERNS[@]}"

write_changed_urls_from_summary "$FILE_SEED_FETCH_SUMMARY_JSON" "$TMP_DIR/file_seed_changed_urls.txt"
build_linked_html_index \
  "$FILE_SEED_PAGES_JSON" \
  "$FILE_NESTED_INDEX_JSON" \
  "$TMP_DIR/file_seed_changed_urls.txt" \
  "$FILE_NESTED_INDEX_JSON" \
  "$TMP_DIR/file_nested_urls_all.txt" \
  "1"
filter_new_urls \
  "$TMP_DIR/file_nested_urls_all.txt" \
  "$TMP_DIR/file_nested_urls_current.txt" \
  "$COURSE_URLS_TXT" \
  "$ALL_WEEK_COURSE_URLS_TXT" \
  "$FILE_SEED_URLS_TXT"
python3 - "$TMP_DIR/file_nested_urls_current.txt" "$FILE_NESTED_URLS_TXT" > "$TMP_DIR/file_nested_urls_focus.txt" <<'PY'
import sys
from pathlib import Path

current_path = Path(sys.argv[1])
previous_path = Path(sys.argv[2])
previous = {
    line.strip()
    for line in previous_path.read_text(encoding="utf-8").splitlines()
    if line.strip()
} if previous_path.exists() else set()

for line in current_path.read_text(encoding="utf-8").splitlines():
    value = line.strip()
    if value and value not in previous:
        print(value)
PY
cp "$TMP_DIR/file_nested_urls_current.txt" "$FILE_NESTED_URLS_TXT"
FILE_NESTED_DYNAMIC_QUICK_LIMIT="$(wc -l < "$TMP_DIR/file_nested_urls_focus.txt" | tr -d '[:space:]')"
if [[ -z "$FILE_NESTED_DYNAMIC_QUICK_LIMIT" || "$FILE_NESTED_DYNAMIC_QUICK_LIMIT" -lt "$FILE_NESTED_BACKGROUND_QUICK_LIMIT" ]]; then
  FILE_NESTED_DYNAMIC_QUICK_LIMIT="$FILE_NESTED_BACKGROUND_QUICK_LIMIT"
fi
SEED_CHANGED_COUNT="$(summary_changed_count "$FILE_SEED_FETCH_SUMMARY_JSON")"
FILE_NESTED_EFFECTIVE_STALE_SECONDS="$FILE_NESTED_STALE_SECONDS"
run_fetch_backend \
  "files-nested-pages" \
  "$FILE_NESTED_PAGES_JSON" \
  "$FILE_NESTED_URLS_TXT" \
  "$FILE_REFRESH_MODE" \
  "$FILE_NESTED_DYNAMIC_QUICK_LIMIT" \
  "$FILE_NESTED_EFFECTIVE_STALE_SECONDS" \
  "$FILE_FULL_TTL_SECONDS" \
  "$FILE_NESTED_FETCH_SUMMARY_JSON" \
  "${FILE_NESTED_FETCH_ALWAYS_PATTERNS[@]}"

write_changed_urls_from_summary "$FILE_NESTED_FETCH_SUMMARY_JSON" "$TMP_DIR/file_nested_changed_urls.txt"
build_linked_html_index \
  "$FILE_NESTED_PAGES_JSON" \
  "$FILE_NESTED2_INDEX_JSON" \
  "$TMP_DIR/file_nested_changed_urls.txt" \
  "$FILE_NESTED2_INDEX_JSON" \
  "$TMP_DIR/file_nested_round2_urls_all.txt" \
  "1"
filter_new_urls \
  "$TMP_DIR/file_nested_round2_urls_all.txt" \
  "$TMP_DIR/file_nested_round2_urls_current.txt" \
  "$COURSE_URLS_TXT" \
  "$ALL_WEEK_COURSE_URLS_TXT" \
  "$FILE_SEED_URLS_TXT" \
  "$FILE_NESTED_URLS_TXT"
python3 - "$TMP_DIR/file_nested_round2_urls_current.txt" "$FILE_NESTED2_URLS_TXT" > "$TMP_DIR/file_nested_round2_urls_focus.txt" <<'PY'
import sys
from pathlib import Path

current_path = Path(sys.argv[1])
previous_path = Path(sys.argv[2])
previous = {
    line.strip()
    for line in previous_path.read_text(encoding="utf-8").splitlines()
    if line.strip()
} if previous_path.exists() else set()

for line in current_path.read_text(encoding="utf-8").splitlines():
    value = line.strip()
    if value and value not in previous:
        print(value)
PY
cp "$TMP_DIR/file_nested_round2_urls_current.txt" "$FILE_NESTED2_URLS_TXT"
FILE_NESTED2_DYNAMIC_QUICK_LIMIT="$(wc -l < "$TMP_DIR/file_nested_round2_urls_focus.txt" | tr -d '[:space:]')"
if [[ -z "$FILE_NESTED2_DYNAMIC_QUICK_LIMIT" || "$FILE_NESTED2_DYNAMIC_QUICK_LIMIT" -lt "$FILE_NESTED2_BACKGROUND_QUICK_LIMIT" ]]; then
  FILE_NESTED2_DYNAMIC_QUICK_LIMIT="$FILE_NESTED2_BACKGROUND_QUICK_LIMIT"
fi
NESTED_CHANGED_COUNT="$(summary_changed_count "$FILE_NESTED_FETCH_SUMMARY_JSON")"
FILE_NESTED2_EFFECTIVE_STALE_SECONDS="$FILE_NESTED2_STALE_SECONDS"
run_fetch_backend \
  "files-nested-round2-pages" \
  "$FILE_NESTED2_PAGES_JSON" \
  "$FILE_NESTED2_URLS_TXT" \
  "$FILE_REFRESH_MODE" \
  "$FILE_NESTED2_DYNAMIC_QUICK_LIMIT" \
  "$FILE_NESTED2_EFFECTIVE_STALE_SECONDS" \
  "$FILE_FULL_TTL_SECONDS" \
  "$FILE_NESTED2_FETCH_SUMMARY_JSON" \
  "${FILE_NESTED2_FETCH_ALWAYS_PATTERNS[@]}"

NESTED2_CHANGED_COUNT="$(summary_changed_count "$FILE_NESTED2_FETCH_SUMMARY_JSON")"
MANIFEST_LAYOUT_MATCHES="$(
  python3 - "$MANIFEST_STATE_JSON" "$FILE_WEEKLY_FOLDERS_ENABLED" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
expected = sys.argv[2] == "1"
if not state_path.exists():
    print("0")
    raise SystemExit

try:
    state = json.loads(state_path.read_text(encoding="utf-8"))
except Exception:
    print("0")
    raise SystemExit

layout = state.get("layout", {}) if isinstance(state, dict) else {}
print("1" if layout.get("weekly_folders_enabled") is expected else "0")
PY
)"
MANIFEST_REUSED=0
if [[ -s "$MANIFEST_JSON" \
  && "$MANIFEST_LAYOUT_MATCHES" == "1" \
  && "$SEED_CHANGED_COUNT" == "0" \
  && "$NESTED_CHANGED_COUNT" == "0" \
  && "$NESTED2_CHANGED_COUNT" == "0" ]]; then
  MANIFEST_REUSED=1
  log_files_timing "manifest build skipped reason=pages-unchanged"
else
  log_files_timing "manifest build start"
  manifest_started_epoch="$(date +%s)"
  python3 "$KLMS_PYTHON_DIR/build_course_file_manifest.py" \
    --course-pages-json "$ALL_WEEK_COURSE_PAGES_JSON" \
    --pages-json "$FILE_SEED_PAGES_JSON" \
    --pages-json "$FILE_NESTED_PAGES_JSON" \
    --pages-json "$FILE_NESTED2_PAGES_JSON" \
    --output-root "$OUTPUT_ROOT" \
    --manifest-state-json "$MANIFEST_STATE_JSON" \
    --output-manifest-state-json "$MANIFEST_STATE_JSON" \
    --weekly-folders "$FILE_WEEKLY_FOLDERS_ENABLED" \
    --output-json "$MANIFEST_JSON" \
    --output-markdown "$MANIFEST_MD"
  log_files_timing "manifest build finish duration_s=$(($(date +%s) - manifest_started_epoch))"
fi

CURRENT_MANIFEST_COUNT="$(count_manifest_entries "$MANIFEST_JSON")"
if [[ "${FILE_REFRESH_RECOVERY_REBUILD:-0}" != "1" ]]; then
  rebuild_reason="$(
    python3 - "$PREVIOUS_MANIFEST_COUNT" "$CURRENT_MANIFEST_COUNT" "$EXISTING_TRACKED_FILE_COUNT" <<'PY'
import sys

previous = int(sys.argv[1])
current = int(sys.argv[2])
existing = int(sys.argv[3])

if current == 0 and existing > 0:
    print("empty-manifest")
elif previous > 0 and current < previous and existing > 0:
    print(f"shrunk:{previous}->{current}")
PY
  )"

  if [[ -n "$rebuild_reason" ]]; then
    print -r -- "Detected incomplete incremental file refresh ($rebuild_reason). Retrying once in full mode." >&2
    export KLMS_USE_EXISTING_DASHBOARD=1
    export FILE_REFRESH_MODE=full
    export FILE_REFRESH_RECOVERY_REBUILD=1
    exec /bin/zsh "$0" "$CONFIG_PATH"
  fi
fi

python3 - "$MANIFEST_JSON" "$OUTPUT_ROOT" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
output_root = Path(sys.argv[2])
manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else []
tracked = len(manifest) if isinstance(manifest, list) else 0
actual_files = sum(1 for path in output_root.rglob("*") if path.is_file() and path.name != ".DS_Store")

if tracked == 0 and actual_files > 0:
    raise SystemExit(
        "Refusing to prune course files because the generated manifest is empty while existing files are present."
    )
PY

log_files_timing "file preview start"
preview_started_epoch="$(date +%s)"
python3 "$KLMS_PYTHON_DIR/build_course_file_sync_preview.py" \
  --manifest-json "$MANIFEST_JSON" \
  --output-root "$OUTPUT_ROOT" \
  --download-log-json "$DOWNLOAD_LOG_JSON" \
  --download-archive-root "$HOME/Downloads/KLMS Files" \
  --output-json "$SYNC_PREVIEW_JSON"
log_files_timing "file preview finish duration_s=$(($(date +%s) - preview_started_epoch))"

python3 - "$QUARANTINE_REPORT_JSON" "$MANIFEST_JSON" "$OUTPUT_ROOT" "$HOME/Downloads/KLMS Quarantine" <<'PY'
import json
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
payload = {
    "manifestPath": str(Path(sys.argv[2]).resolve()),
    "outputRoot": str(Path(sys.argv[3]).resolve()),
    "quarantineRoot": str(Path(sys.argv[4]).expanduser().resolve()),
    "quarantineCount": 0,
    "records": [],
}
report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
PY

log_files_timing "download start force_download=$FILE_FORCE_DOWNLOAD"
download_started_epoch="$(date +%s)"
if ! is_truthy "$FILE_FORCE_DOWNLOAD" \
  && write_existing_download_result_if_complete \
    "$MANIFEST_JSON" \
    "$OUTPUT_ROOT" \
    "$DOWNLOAD_LOG_JSON" \
    "$DOWNLOAD_RESULT_JSON" \
    "$HOME/Downloads/KLMS Files"; then
  log_files_timing "download skipped existing_complete=1 duration_s=$(($(date +%s) - download_started_epoch))"
else
  /bin/zsh "$KLMS_SH_DIR/run_download_files_step.sh" \
    "$KLMS_JS_DIR/download_klms_files.js" \
    "$MANIFEST_JSON" \
    "$OUTPUT_ROOT" \
    "$DOWNLOAD_LOG_JSON" \
    "$HOME/Downloads/KLMS Files" \
    "$DOWNLOAD_RESULT_JSON" \
    "$FILE_DOWNLOAD_TIMEOUT_SECONDS" \
    "$FILE_MAX_DOWNLOAD_ATTEMPTS" \
    "$FILE_DOWNLOAD_RETRY_DELAY_SECONDS" \
    "$FILE_FORCE_DOWNLOAD"
  log_files_timing "download finish duration_s=$(($(date +%s) - download_started_epoch))"
fi

if [[ "$MANIFEST_REUSED" == "1" && -s "$MANIFEST_MD" ]]; then
  log_files_timing "manifest markdown render skipped reason=manifest-reused"
else
  log_files_timing "manifest markdown render start"
  markdown_started_epoch="$(date +%s)"
  python3 - "$MANIFEST_JSON" "$MANIFEST_MD" <<'PY'
import json
import sys
from pathlib import Path

from build_course_file_manifest import render_markdown

manifest_path = Path(sys.argv[1])
markdown_path = Path(sys.argv[2])
manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else []
markdown_path.write_text(render_markdown(manifest), encoding="utf-8")
PY
  log_files_timing "manifest markdown render finish duration_s=$(($(date +%s) - markdown_started_epoch))"
fi

log_files_timing "prune start"
prune_started_epoch="$(date +%s)"
python3 "$KLMS_PYTHON_DIR/prune_course_files.py" \
  --manifest-json "$MANIFEST_JSON" \
  --root "$OUTPUT_ROOT" \
  > "$PRUNE_RESULT_JSON"
log_files_timing "prune finish duration_s=$(($(date +%s) - prune_started_epoch))"

cleanup_args=(
  /usr/bin/osascript
  -l
  JavaScript
  "$KLMS_JS_DIR/cleanup_tracked_downloads.js"
  "--manifest=$DOWNLOAD_LOG_JSON"
)
case "${FILE_KEEP_FRESH_DOWNLOADS:l}" in
  1|true|yes|on)
    cleanup_args+=("--keep-fresh-downloads")
    ;;
esac
log_files_timing "cleanup start keep_fresh=$FILE_KEEP_FRESH_DOWNLOADS"
cleanup_started_epoch="$(date +%s)"
"${cleanup_args[@]}" > "$CLEANUP_RESULT_JSON"
log_files_timing "cleanup finish duration_s=$(($(date +%s) - cleanup_started_epoch))"

python3 - "$DOWNLOAD_RESULT_JSON" "$PRUNE_RESULT_JSON" "$CLEANUP_RESULT_JSON" <<'PY'
import json
import sys
from pathlib import Path

download = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
results = download.get("results", [])
skipped_existing = sum(1 for item in results if item.get("skipped_existing"))
restored_from_archive = sum(1 for item in results if item.get("restored_from_archive"))
reused_logged_file = sum(1 for item in results if item.get("reused_logged_file"))
downloaded_fresh = max(0, len(results) - skipped_existing - restored_from_archive - reused_logged_file)
new_files_copied = sum(1 for item in results if item.get("copied_to_new_files_inbox"))
quarantine_count = int(download.get("quarantineCount", 0) or 0)
print(
    "download-summary "
    f"total={len(results)} "
    f"skipped_existing={skipped_existing} "
    f"restored_from_archive={restored_from_archive} "
    f"reused_logged_file={reused_logged_file} "
    f"downloaded_fresh={downloaded_fresh} "
    f"new_files_copied={new_files_copied} "
    f"quarantine={quarantine_count}"
)

prune = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
print(
    "prune-summary "
    f"tracked_files={prune.get('tracked_files', 0)} "
    f"actual_files_after={prune.get('actual_files_after', 0)} "
    f"deleted_file_count={prune.get('deleted_file_count', 0)} "
    f"deleted_dir_count={prune.get('deleted_dir_count', 0)}"
)

cleanup = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
actions = cleanup.get("actions", [])
deleted = sum(1 for item in actions if item.get("action") == "deleted")
restored = sum(1 for item in actions if item.get("action") == "restored")
already_missing = sum(1 for item in actions if item.get("action") == "already-missing")
kept_fresh = sum(1 for item in actions if item.get("action") == "kept-fresh")
print(
    "cleanup-summary "
    f"tracked_entries={cleanup.get('fileCount', 0)} "
    f"deleted={deleted} "
    f"kept_fresh={kept_fresh} "
    f"restored={restored} "
    f"already_missing={already_missing}"
)
PY
log_files_timing "refresh finish"
