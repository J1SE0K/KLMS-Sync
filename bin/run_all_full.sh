#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMON_SH="$SCRIPT_DIR/src/sh/klms_common.sh"
source "$COMMON_SH"

klms_init_context "$SCRIPT_DIR/run_all_full.sh" "${1:-}"
klms_acquire_shared_sync_lock
trap 'klms_release_shared_sync_lock' EXIT
klms_require_login

klms_export_shared_sync_cache_defaults
klms_prepare_prefetched_dashboard_for_namespaces core notice files

klms_run_serial_child_job core ./sync_klms_core.sh
klms_run_serial_child_job notice ./sync_klms_notice.sh
klms_run_serial_child_job files ./refresh_course_files.sh
klms_cleanup_tmp_root_if_enabled
