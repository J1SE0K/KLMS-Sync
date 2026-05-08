#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KLMS_JS_DIR="$SCRIPT_DIR/src/js"
KLMS_SWIFT_DIR="$SCRIPT_DIR/src/swift"
CONFIG_PATH="$SCRIPT_DIR/config.env"
QR_IMAGE=""
QR_JSON=""
QR_JSON_FILE=""

while (( $# > 0 )); do
  case "$1" in
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --config=*)
      CONFIG_PATH="${1#--config=}"
      shift
      ;;
    --qr-image)
      QR_IMAGE="$2"
      shift 2
      ;;
    --qr-image=*)
      QR_IMAGE="${1#--qr-image=}"
      shift
      ;;
    --qr-json)
      QR_JSON="$2"
      shift 2
      ;;
    --qr-json=*)
      QR_JSON="${1#--qr-json=}"
      shift
      ;;
    --qr-json-file)
      QR_JSON_FILE="$2"
      shift 2
      ;;
    --qr-json-file=*)
      QR_JSON_FILE="${1#--qr-json-file=}"
      shift
      ;;
    *)
      print -r -- "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -f "$CONFIG_PATH" ]]; then
  source "$CONFIG_PATH"
fi

KAIKEY_STATE_PATH="${KAIKEY_STATE_PATH:-$HOME/Library/Application Support/KLMSNotesSync/kaikey_state.json}"
export KAIKEY_STATE_PATH
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/klms-notes-sync-swift-module-cache}"
export CLANG_MODULE_CACHE_PATH

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

if [[ -n "$QR_IMAGE" ]]; then
  QR_JSON="$(/usr/bin/swift "$KLMS_SWIFT_DIR/decode_qr_image.swift" "$QR_IMAGE")"
fi

if [[ -n "$QR_JSON_FILE" ]]; then
  "$NODE_BIN" "$KLMS_JS_DIR/kaikey_cli.mjs" register --qr-json-file "$QR_JSON_FILE"
elif [[ -n "$QR_JSON" ]]; then
  "$NODE_BIN" "$KLMS_JS_DIR/kaikey_cli.mjs" register --qr-json "$QR_JSON"
else
  print -r -- "usage: ./kaikey_setup.sh --qr-image /path/to/screenshot.png" >&2
  print -r -- "   or: ./kaikey_setup.sh --qr-json-file /path/to/qr.json" >&2
  exit 2
fi
