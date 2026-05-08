#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KLMS_JS_DIR="$SCRIPT_DIR/src/js"
CONFIG_PATH="${1:-$SCRIPT_DIR/config.env}"

if [[ -f "$CONFIG_PATH" ]]; then
  source "$CONFIG_PATH"
fi

KLMS_LOGIN_URL="${KLMS_LOGIN_URL:-${KLMS_DASHBOARD_URL:-https://klms.kaist.ac.kr/my/}}"
KAIKEY_AUTO_LOGIN_TIMEOUT_SECONDS="${KAIKEY_AUTO_LOGIN_TIMEOUT_SECONDS:-90}"
KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS="${KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS:-300}"
KAIKEY_AUTO_LOGIN_POLL_SECONDS="${KAIKEY_AUTO_LOGIN_POLL_SECONDS:-1}"
KAIKEY_APPROVE_ATTEMPTS="${KAIKEY_APPROVE_ATTEMPTS:-5}"
KAIKEY_APPROVE_INTERVAL_MS="${KAIKEY_APPROVE_INTERVAL_MS:-1500}"
KAIKEY_AUTO_APPROVE_ENABLED="${KAIKEY_AUTO_APPROVE_ENABLED:-1}"
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

json_get() {
  local json="$1"
  local key="$2"
  local python_bin="${KLMS_PYTHON_BIN:-python3}"
  printf '%s' "$json" | "$python_bin" -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$key"
}

NODE_BIN=""
if NODE_BIN="$(resolve_node_bin 2>/dev/null)"; then
  :
else
  NODE_BIN=""
fi

load_display_name() {
  if [[ -n "${KLMS_SSO_LOGIN_ID:-}" ]]; then
    print -r -- "$KLMS_SSO_LOGIN_ID"
    return 0
  fi
  if [[ -n "${KAIST_SSO_LOGIN_ID:-}" ]]; then
    print -r -- "$KAIST_SSO_LOGIN_ID"
    return 0
  fi
  if [[ -n "$NODE_BIN" ]] && "$NODE_BIN" "$KLMS_JS_DIR/kaikey_cli.mjs" status >/dev/null 2>&1; then
    "$NODE_BIN" "$KLMS_JS_DIR/kaikey_cli.mjs" identity
    return 0
  fi
  return 1
}

DISPLAY_NAME="$(load_display_name)" || {
  print -r -- "status=skipped reason=missing-login-id"
  print -r -- "KLMS_SSO_LOGIN_ID 또는 KAIST_SSO_LOGIN_ID를 config.env에 설정해 줘." >&2
  exit 2
}

if [[ "$KAIKEY_AUTO_APPROVE_ENABLED" == "1" ]]; then
  [[ -n "$NODE_BIN" ]] || {
    print -r -- "status=skipped reason=node-not-found"
    exit 2
  }
  "$NODE_BIN" "$KLMS_JS_DIR/kaikey_cli.mjs" status >/dev/null 2>&1 || {
    print -r -- "status=skipped reason=kaikey-not-registered"
    exit 2
  }
fi

if [[ "$KAIKEY_AUTO_APPROVE_ENABLED" == "1" ]]; then
  deadline_epoch="$(( $(date +%s) + KAIKEY_AUTO_LOGIN_TIMEOUT_SECONDS ))"
else
  deadline_epoch="$(( $(date +%s) + KAIKEY_MANUAL_APPROVAL_TIMEOUT_SECONDS ))"
fi
last_status=""
last_digits=""

while (( $(date +%s) < deadline_epoch )); do
  step_json="$(/usr/bin/osascript -l JavaScript "$KLMS_JS_DIR/kaikey_safari_step.js" \
    "--url=$KLMS_LOGIN_URL" \
    "--display-name=$DISPLAY_NAME" 2>/dev/null || true)"

  if [[ -z "$step_json" ]]; then
    sleep "$KAIKEY_AUTO_LOGIN_POLL_SECONDS"
    continue
  fi

  step_status="$(json_get "$step_json" status 2>/dev/null || true)"
  last_status="$step_status"

  case "$step_status" in
    authenticated)
      print -r -- "status=ok stage=authenticated"
      exit 0
      ;;
    twofactor_digits)
      digits="$(json_get "$step_json" digits 2>/dev/null || true)"
      if [[ "$digits" == <-> && "${#digits}" == "2" ]]; then
        if [[ "$digits" != "$last_digits" ]]; then
          last_digits="$digits"
          print -r -- "KAIST 인증 번호: $digits"
          if [[ "$KAIKEY_AUTO_APPROVE_ENABLED" != "1" ]]; then
            print -r -- "휴대폰 인증 화면에서 같은 번호를 선택하면 동기화를 계속 진행해."
          fi
        fi
        if [[ "$KAIKEY_AUTO_APPROVE_ENABLED" == "1" ]]; then
          approve_json="$("$NODE_BIN" "$KLMS_JS_DIR/kaikey_cli.mjs" approve-if-match \
            "--digits=$digits" \
            "--attempts=$KAIKEY_APPROVE_ATTEMPTS" \
            "--interval-ms=$KAIKEY_APPROVE_INTERVAL_MS" 2>/dev/null || true)"
          approved="$(json_get "$approve_json" approved 2>/dev/null || true)"
          if [[ "$approved" == "True" || "$approved" == "true" ]]; then
            sleep 4
          else
            reason="$(json_get "$approve_json" reason 2>/dev/null || true)"
            print -r -- "status=failed stage=approve reason=${reason:-unknown}"
            exit 1
          fi
        else
          sleep "$KAIKEY_AUTO_LOGIN_POLL_SECONDS"
        fi
      fi
      ;;
    navigated|klms_redirect_clicked|login_submitted|waiting)
      ;;
    error)
      reason="$(json_get "$step_json" error 2>/dev/null || true)"
      print -r -- "status=failed stage=safari reason=${reason:-unknown}"
      exit 1
      ;;
  esac

  sleep "$KAIKEY_AUTO_LOGIN_POLL_SECONDS"
done

if [[ -n "$last_digits" ]]; then
  print -r -- "status=timeout last_status=${last_status:-unknown} digits=$last_digits"
else
  print -r -- "status=timeout last_status=${last_status:-unknown}"
fi
exit 1
