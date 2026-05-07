#!/bin/zsh

set -euo pipefail

COMMON_SH="$(cd "$(dirname "$0")" && pwd)/src/sh/klms_common.sh"
source "$COMMON_SH"

klms_init_context "$0" "${1:-}"
klms_run_sync_scope_entrypoint notice
