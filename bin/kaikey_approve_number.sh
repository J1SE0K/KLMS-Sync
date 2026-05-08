#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KLMS_JS_DIR="$SCRIPT_DIR/src/js"
CONFIG_PATH="${CONFIG_PATH:-$SCRIPT_DIR/config.env}"

if [[ -f "$CONFIG_PATH" ]]; then
  source "$CONFIG_PATH"
fi

number=""
while (( $# > 0 )); do
  case "$1" in
    --number)
      number="${2:-}"
      shift 2
      ;;
    --number=*)
      number="${1#--number=}"
      shift
      ;;
    *)
      if [[ -z "$number" ]]; then
        number="$1"
        shift
      else
        print -r -- "unknown argument: $1" >&2
        exit 2
      fi
      ;;
  esac
done

if [[ ! "$number" =~ '^[0-9][0-9]$' ]]; then
  print -r -- "usage: ./kaikey_approve_number.sh NN" >&2
  exit 2
fi

KAIKEY_STATE_PATH="${KAIKEY_STATE_PATH:-$HOME/Library/Application Support/KLMSNotesSync/kaikey_state.json}"
export KAIKEY_STATE_PATH

resolve_node_bin() {
  if [[ -n "${KAIKEY_NODE_BIN:-}" && -x "$KAIKEY_NODE_BIN" ]]; then
    print -r -- "$KAIKEY_NODE_BIN"
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    command -v node
    return 0
  fi
  if [[ -x /opt/homebrew/bin/node ]]; then
    print -r -- /opt/homebrew/bin/node
    return 0
  fi
  if [[ -x /usr/local/bin/node ]]; then
    print -r -- /usr/local/bin/node
    return 0
  fi
  return 1
}

NODE_BIN="$(resolve_node_bin)" || {
  print -r -- "node executable not found; set KAIKEY_NODE_BIN in config.env" >&2
  exit 1
}

"$NODE_BIN" "$KLMS_JS_DIR/kaikey_cli.mjs" approve-number "--number=$number"
