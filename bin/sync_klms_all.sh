#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_PATH="$SCRIPT_DIR/config.env"
MODE=""

usage() {
  cat <<'EOF'
Usage: sync_klms_all.sh [mode] [config_path]

Modes:
  --basic   Run the default sync (core + notice)
  --core    Run only the KLMS core sync
  --notice  Run only the notice sync
  --files   Run only the course file refresh
  --full    Run the full sync (core + notice + files)
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --basic|--default)
      MODE="basic"
      shift
      ;;
    --core)
      MODE="core"
      shift
      ;;
    --notice)
      MODE="notice"
      shift
      ;;
    --files)
      MODE="files"
      shift
      ;;
    --full)
      MODE="full"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      if [[ "$CONFIG_PATH" == "$SCRIPT_DIR/config.env" ]]; then
        CONFIG_PATH="$1"
        shift
      else
        print -r -- "Unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

prompt_for_mode() {
  local selection

  while true; do
    cat <<'EOF'
어떤 KLMS 동기화를 실행할까?
  1) 기본 동기화 (core + notice)
  2) KLMS 동기화만 (core)
  3) 공지 정리만 (notice)
  4) 파일 정리만 (files)
  5) 전체 동기화 (core + notice + files)
EOF
    printf '> '
    read -r selection

    case "$selection" in
      ""|1|basic)
        MODE="basic"
        return 0
        ;;
      2|core)
        MODE="core"
        return 0
        ;;
      3|notice)
        MODE="notice"
        return 0
        ;;
      4|files)
        MODE="files"
        return 0
        ;;
      5|full)
        MODE="full"
        return 0
        ;;
      *)
        print -r -- "선택을 다시 입력해 줘." >&2
        ;;
    esac
  done
}

dispatch() {
  case "$MODE" in
    basic)
      exec /bin/zsh "$SCRIPT_DIR/run_all.sh" "$CONFIG_PATH"
      ;;
    core)
      exec /bin/zsh "$SCRIPT_DIR/sync_klms_core.sh" "$CONFIG_PATH"
      ;;
    notice)
      exec /bin/zsh "$SCRIPT_DIR/sync_klms_notice.sh" "$CONFIG_PATH"
      ;;
    files)
      exec /bin/zsh "$SCRIPT_DIR/refresh_course_files.sh" "$CONFIG_PATH"
      ;;
    full)
      exec /bin/zsh "$SCRIPT_DIR/run_all_full.sh" "$CONFIG_PATH"
      ;;
    *)
      print -r -- "Unknown sync mode: ${MODE:-<empty>}" >&2
      exit 1
      ;;
  esac
}

if [[ -z "$MODE" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    prompt_for_mode
  else
    MODE="basic"
  fi
fi

dispatch
