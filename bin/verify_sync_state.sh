#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMON_SH="$SCRIPT_DIR/src/sh/klms_common.sh"
source "$COMMON_SH"

OUTPUT_JSON=0
CONFIG_ARG=""
for arg in "$@"; do
  case "$arg" in
    --json)
      OUTPUT_JSON=1
      ;;
    --text)
      OUTPUT_JSON=0
      ;;
    *)
      CONFIG_ARG="$arg"
      ;;
  esac
done

klms_init_context "$SCRIPT_DIR/verify_sync_state.sh" "$CONFIG_ARG"
STATE_JSON="$SCRIPT_DIR/runtime/state/state.json"
CALENDAR_COUNTS_TXT="$TMP_DIR/verify_calendar_counts.txt"
VERIFY_JSON="$CACHE_DIR/verify_sync_state.json"

SWIFT_MODULE_CACHE_DIR="$TMP_DIR/swift-module-cache"
CLANG_MODULE_CACHE_DIR="$TMP_DIR/clang-module-cache"
mkdir -p "$SWIFT_MODULE_CACHE_DIR" "$CLANG_MODULE_CACHE_DIR"

SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_DIR" \
/usr/bin/swift -module-cache-path "$SWIFT_MODULE_CACHE_DIR" \
  "$SCRIPT_DIR/src/swift/verify_calendar_counts.swift" \
  "--exam-calendar=${EXAM_CALENDAR_NAME:-시험}" \
  "--helpdesk-calendar=${HELP_DESK_CALENDAR_NAME:-기타}" \
  > "$CALENDAR_COUNTS_TXT"

verify_args=(
  "$KLMS_PYTHON_BIN"
  "$KLMS_PYTHON_DIR/verify_sync_state.py"
  --cache-dir "$CACHE_DIR"
  --state-json "$STATE_JSON"
  --calendar-lines "$CALENDAR_COUNTS_TXT"
  --write-json "$VERIFY_JSON"
)
if (( OUTPUT_JSON )); then
  verify_args+=(--json)
fi
"${verify_args[@]}"
