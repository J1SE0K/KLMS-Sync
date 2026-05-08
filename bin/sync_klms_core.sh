#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMON_SH="$SCRIPT_DIR/src/sh/klms_common.sh"
source "$COMMON_SH"

klms_parse_entry_args "$@"
klms_init_context "$SCRIPT_DIR/sync_klms_core.sh" "$KLMS_ENTRY_CONFIG_ARG"
klms_run_sync_scope_entrypoint core "${KLMS_ENTRY_EXTRA_ARGS[@]}"
