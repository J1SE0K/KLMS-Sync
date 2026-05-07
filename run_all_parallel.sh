#!/bin/zsh

set -euo pipefail
unsetopt bg_nice

COMMON_SH="$(cd "$(dirname "$0")" && pwd)/src/sh/klms_common.sh"
source "$COMMON_SH"

klms_init_context "$0" "${1:-}"
klms_acquire_shared_sync_lock
trap 'klms_release_shared_sync_lock' EXIT
klms_require_login

run_id="$(date +%Y%m%d-%H%M%S)"
log_dir="$TMP_DIR/run-all-$run_id"
mkdir -p "$log_dir"

klms_export_shared_sync_cache_defaults
klms_prepare_prefetched_dashboard_for_namespaces core notice files

core_log="$log_dir/core.log"
notice_log="$log_dir/notice.log"
files_log="$log_dir/files.log"

(
  cd "$SCRIPT_DIR"
  /usr/bin/env -u KLMS_SHARED_SYNC_LOCK_HELD -u KLMS_SHARED_SYNC_LOCK_DIR \
    KLMS_USE_EXISTING_DASHBOARD=1 \
    KLMS_PARENT_LOGIN_PREFLIGHT_READY=1 \
    /bin/zsh ./sync_klms_core.sh "$CONFIG_PATH"
) >"$core_log" 2>&1 &
core_pid=$!

(
  cd "$SCRIPT_DIR"
  /usr/bin/env -u KLMS_SHARED_SYNC_LOCK_HELD -u KLMS_SHARED_SYNC_LOCK_DIR \
    KLMS_USE_EXISTING_DASHBOARD=1 \
    KLMS_PARENT_LOGIN_PREFLIGHT_READY=1 \
    /bin/zsh ./sync_klms_notice.sh "$CONFIG_PATH"
) >"$notice_log" 2>&1 &
notice_pid=$!

(
  cd "$SCRIPT_DIR"
  /usr/bin/env -u KLMS_SHARED_SYNC_LOCK_HELD -u KLMS_SHARED_SYNC_LOCK_DIR \
    KLMS_USE_EXISTING_DASHBOARD=1 \
    KLMS_PARENT_LOGIN_PREFLIGHT_READY=1 \
    /bin/zsh ./refresh_course_files.sh "$CONFIG_PATH"
) >"$files_log" 2>&1 &
files_pid=$!

overall_exit=0
if wait "$core_pid"; then
  core_exit=0
else
  core_exit=$?
  overall_exit=1
fi

if wait "$notice_pid"; then
  notice_exit=0
else
  notice_exit=$?
  overall_exit=1
fi

if wait "$files_pid"; then
  files_exit=0
else
  files_exit=$?
  overall_exit=1
fi

print -r -- "== core (exit=$core_exit) =="
[[ -s "$core_log" ]] && cat "$core_log"

print -r -- "== notice (exit=$notice_exit) =="
[[ -s "$notice_log" ]] && cat "$notice_log"

print -r -- "== files (exit=$files_exit) =="
[[ -s "$files_log" ]] && cat "$files_log"

if (( overall_exit != 0 )); then
  exit 1
fi

klms_cleanup_tmp_root_if_enabled
