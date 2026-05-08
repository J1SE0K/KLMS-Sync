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

klms_init_context "$SCRIPT_DIR/sync_report.sh" "$CONFIG_ARG"
RESULT_JSON="$CACHE_DIR/sync_report.json"
args=(
  "$KLMS_PYTHON_BIN"
  "$KLMS_PYTHON_DIR/sync_report.py"
  --cache-dir "$CACHE_DIR"
  --state-json "$SCRIPT_DIR/runtime/state/state.json"
  --write-json "$RESULT_JSON"
)
if (( OUTPUT_JSON )); then
  args+=(--json)
fi
"${args[@]}"
