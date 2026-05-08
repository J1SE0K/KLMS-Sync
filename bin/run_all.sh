#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMON_SH="$SCRIPT_DIR/src/sh/klms_common.sh"
source "$COMMON_SH"

klms_parse_entry_args "$@"
klms_init_context "$SCRIPT_DIR/run_all.sh" "$KLMS_ENTRY_CONFIG_ARG"
klms_acquire_shared_sync_lock
trap 'klms_release_shared_sync_lock' EXIT
klms_require_login

klms_export_shared_sync_cache_defaults
klms_prepare_prefetched_dashboard_for_namespaces core notice

klms_run_serial_child_job core ./sync_klms_core.sh "${KLMS_ENTRY_EXTRA_ARGS[@]}"
klms_run_serial_child_job notice ./sync_klms_notice.sh "${KLMS_ENTRY_EXTRA_ARGS[@]}"
klms_cleanup_tmp_root_if_enabled
