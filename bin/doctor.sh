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

klms_init_context "$SCRIPT_DIR/doctor.sh" "$CONFIG_ARG"
RESULT_JSON="$CACHE_DIR/doctor_result.json"
args=(
  "$KLMS_PYTHON_BIN"
  "$KLMS_PYTHON_DIR/doctor.py"
  --script-dir "$SCRIPT_DIR"
  --config "$CONFIG_PATH"
  --cache-dir "$CACHE_DIR"
  --state-json "$SCRIPT_DIR/runtime/state/state.json"
  --write-json "$RESULT_JSON"
)
if (( OUTPUT_JSON )); then
  args+=(--json)
fi
"${args[@]}"
