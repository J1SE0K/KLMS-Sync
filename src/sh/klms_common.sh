#!/bin/zsh

klms_default_runtime_namespace() {
  local entry_path="${1:-}"
  local entry_name="${entry_path:t}"

  case "$entry_name" in
    sync_klms_core.sh)
      print -r -- "core"
      ;;
    sync_klms_notice.sh)
      print -r -- "notice"
      ;;
    refresh_course_files.sh)
      print -r -- "files"
      ;;
    run_all.sh|run_all_full.sh|sync_klms_all.sh)
      print -r -- "all"
      ;;
    *)
      print -r -- "shared"
      ;;
  esac
}

klms_init_context() {
  local entry_path="${1:?missing entry path}"
  local config_path="${2:-}"
  local runtime_namespace=""
  local lock_name=""

  SCRIPT_DIR="$(cd "$(dirname "$entry_path")" && pwd)"
  KLMS_SRC_DIR="$SCRIPT_DIR/src"
  KLMS_SH_DIR="$KLMS_SRC_DIR/sh"
  KLMS_JS_DIR="$KLMS_SRC_DIR/js"
  KLMS_PYTHON_DIR="$KLMS_SRC_DIR/python"
  KLMS_SWIFT_DIR="$KLMS_SRC_DIR/swift"
  CONFIG_PATH="${config_path:-$SCRIPT_DIR/config.env}"

  local env_sync_mode_set="${+SYNC_MODE}"
  local env_sync_mode="${SYNC_MODE:-}"
  local env_file_refresh_mode_set="${+FILE_REFRESH_MODE}"
  local env_file_refresh_mode="${FILE_REFRESH_MODE:-}"
  local env_file_force_download_set="${+FILE_FORCE_DOWNLOAD}"
  local env_file_force_download="${FILE_FORCE_DOWNLOAD:-}"
  local env_file_keep_fresh_downloads_set="${+FILE_KEEP_FRESH_DOWNLOADS}"
  local env_file_keep_fresh_downloads="${FILE_KEEP_FRESH_DOWNLOADS:-}"

  if [[ -f "$CONFIG_PATH" ]]; then
    source "$CONFIG_PATH"
  fi
  (( env_sync_mode_set )) && SYNC_MODE="$env_sync_mode"
  (( env_file_refresh_mode_set )) && FILE_REFRESH_MODE="$env_file_refresh_mode"
  (( env_file_force_download_set )) && FILE_FORCE_DOWNLOAD="$env_file_force_download"
  (( env_file_keep_fresh_downloads_set )) && FILE_KEEP_FRESH_DOWNLOADS="$env_file_keep_fresh_downloads"

  runtime_namespace="${KLMS_RUNTIME_NAMESPACE:-$(klms_default_runtime_namespace "$entry_path")}"

  RUNTIME_DIR="$SCRIPT_DIR/runtime"
  CACHE_DIR="$RUNTIME_DIR/cache"
  WORK_CACHE_DIR="$CACHE_DIR/$runtime_namespace"
  TMP_ROOT_DIR="$RUNTIME_DIR/tmp"
  TMP_DIR="$TMP_ROOT_DIR/$runtime_namespace"
  AUTOMATION_DIR="$RUNTIME_DIR/automation"
  local preferred_lock_root
  local fallback_lock_root
  local lock_probe_dir
  preferred_lock_root="${KLMS_SHARED_SYNC_LOCK_ROOT:-$HOME/Library/Application Support/KLMSNotesSync/runtime/automation}"
  fallback_lock_root="$AUTOMATION_DIR/shared-locks"

  mkdir -p "$CACHE_DIR" "$WORK_CACHE_DIR" "$TMP_DIR" "$AUTOMATION_DIR"
  klms_configure_python_runtime
  lock_probe_dir="$preferred_lock_root/.lock-write-probe.$$"
  if ! mkdir -p "$preferred_lock_root" 2>/dev/null || ! mkdir "$lock_probe_dir" 2>/dev/null; then
    preferred_lock_root="$fallback_lock_root"
    mkdir -p "$preferred_lock_root"
  else
    rmdir "$lock_probe_dir" 2>/dev/null || true
  fi
  KLMS_SHARED_SYNC_LOCK_ROOT="$preferred_lock_root"

  KLMS_DASHBOARD_URL="${KLMS_DASHBOARD_URL:-https://klms.kaist.ac.kr/my/}"
  SAFARI_WAIT_SECONDS="${SAFARI_WAIT_SECONDS:-6}"
  FETCH_MIN_WAIT_SECONDS="${FETCH_MIN_WAIT_SECONDS:-1.5}"
  FETCH_STABLE_POLLS="${FETCH_STABLE_POLLS:-2}"
  FETCH_CACHE_STATE_PATH="${FETCH_CACHE_STATE_PATH:-$WORK_CACHE_DIR/fetch_state.json}"
  KLMS_LOGIN_STATUS_PATH="${KLMS_LOGIN_STATUS_PATH:-${KLMS_LOGIN_STATUS_CACHE_PATH:-$CACHE_DIR/login_status.json}}"
  KLMS_LOGIN_STATUS_CACHE_PATH="$KLMS_LOGIN_STATUS_PATH"
  KLMS_LOGIN_FAST_TAB_CHECK_ENABLED="${KLMS_LOGIN_FAST_TAB_CHECK_ENABLED:-1}"
  KLMS_LOGIN_URL="${KLMS_LOGIN_URL:-$KLMS_DASHBOARD_URL}"
  KLMS_LOGIN_OPEN_SAFARI_ON_FAILURE="${KLMS_LOGIN_OPEN_SAFARI_ON_FAILURE:-1}"
  KAIKEY_AUTO_LOGIN_ENABLED="${KAIKEY_AUTO_LOGIN_ENABLED:-0}"
  KAIKEY_STATE_PATH="${KAIKEY_STATE_PATH:-$HOME/Library/Application Support/KLMSNotesSync/kaikey_state.json}"
  lock_name="${KLMS_SYNC_LOCK_NAME:-$runtime_namespace}"
  KLMS_SHARED_SYNC_LOCK_DIR="${KLMS_SHARED_SYNC_LOCK_DIR:-$KLMS_SHARED_SYNC_LOCK_ROOT/${lock_name}.lock}"
  KLMS_SHARED_SYNC_LOCK_WAIT_SECONDS="${KLMS_SHARED_SYNC_LOCK_WAIT_SECONDS:-900}"
  KLMS_LOGIN_PREFETCH_READY=0
  KLMS_LAST_LOGIN_ERROR_MESSAGE=""
  export KLMS_SRC_DIR KLMS_SH_DIR KLMS_JS_DIR KLMS_PYTHON_DIR KLMS_SWIFT_DIR
}

klms_configure_python_runtime() {
  local python_bin="${KLMS_PYTHON_BIN:-}"
  local python_packages_dir="${KLMS_PYTHONPATH_DIR:-$RUNTIME_DIR/python-packages}"
  local joined_pythonpath=""

  if [[ -n "$python_bin" ]]; then
    if [[ -x "$python_bin" ]]; then
      PATH="${python_bin:h}:$PATH"
      export PATH
    else
      print -r -- "warning: KLMS_PYTHON_BIN is not executable: $python_bin" >&2
    fi
  fi

  local python_path_parts=()
  [[ -d "${KLMS_PYTHON_DIR:-}" ]] && python_path_parts+=("$KLMS_PYTHON_DIR")
  [[ -d "$python_packages_dir" ]] && python_path_parts+=("$python_packages_dir")

  if (( ${#python_path_parts[@]} > 0 )); then
    local part
    for part in "${python_path_parts[@]}"; do
      if [[ -z "$joined_pythonpath" ]]; then
        joined_pythonpath="$part"
      else
        joined_pythonpath="$joined_pythonpath:$part"
      fi
    done
    if [[ -n "${PYTHONPATH:-}" ]]; then
      PYTHONPATH="$joined_pythonpath:$PYTHONPATH"
    else
      PYTHONPATH="$joined_pythonpath"
    fi
    export PYTHONPATH
  fi
}

klms_shared_sync_lock_owner_pid() {
  local pid_file="${KLMS_SHARED_SYNC_LOCK_DIR}/pid"
  if [[ -f "$pid_file" ]]; then
    <"$pid_file"
  fi
}

klms_shared_sync_lock_owner_running() {
  local owner_pid="$1"
  [[ "$owner_pid" == <-> ]] || return 1
  kill -0 "$owner_pid" 2>/dev/null
}

klms_cleanup_stale_shared_sync_lock() {
  [[ -d "$KLMS_SHARED_SYNC_LOCK_DIR" ]] || return 0

  local owner_pid
  owner_pid="$(klms_shared_sync_lock_owner_pid)"
  if klms_shared_sync_lock_owner_running "$owner_pid"; then
    return 0
  fi

  rm -f "$KLMS_SHARED_SYNC_LOCK_DIR/pid" \
    "$KLMS_SHARED_SYNC_LOCK_DIR/command" \
    "$KLMS_SHARED_SYNC_LOCK_DIR/acquired_at"
  rmdir "$KLMS_SHARED_SYNC_LOCK_DIR" 2>/dev/null || true
}

klms_acquire_shared_sync_lock() {
  if [[ "${KLMS_SHARED_SYNC_LOCK_HELD:-0}" == "1" ]]; then
    local owner_pid
    owner_pid="$(klms_shared_sync_lock_owner_pid)"
    if [[ "$owner_pid" == "$$" ]]; then
      return 0
    fi
  fi

  local wait_seconds now_epoch deadline_epoch owner_pid
  wait_seconds="${KLMS_SHARED_SYNC_LOCK_WAIT_SECONDS:-900}"
  now_epoch="$(date +%s)"
  deadline_epoch="$(( now_epoch + wait_seconds ))"

  while ! mkdir "$KLMS_SHARED_SYNC_LOCK_DIR" 2>/dev/null; do
    klms_cleanup_stale_shared_sync_lock
    if mkdir "$KLMS_SHARED_SYNC_LOCK_DIR" 2>/dev/null; then
      break
    fi

    if (( $(date +%s) >= deadline_epoch )); then
      owner_pid="$(klms_shared_sync_lock_owner_pid)"
      if [[ "$owner_pid" == <-> ]]; then
        print -r -- "Another KLMS sync is still running (pid=$owner_pid)." >&2
      else
        print -r -- "Another KLMS sync is still running." >&2
      fi
      return 1
    fi

    sleep 1
  done

  print -r -- "$$" > "$KLMS_SHARED_SYNC_LOCK_DIR/pid"
  print -r -- "${0:-unknown}" > "$KLMS_SHARED_SYNC_LOCK_DIR/command"
  date '+%Y-%m-%d %H:%M:%S %Z' > "$KLMS_SHARED_SYNC_LOCK_DIR/acquired_at"
  export KLMS_SHARED_SYNC_LOCK_HELD=1
  export KLMS_SHARED_SYNC_LOCK_DIR
}

klms_release_shared_sync_lock() {
  [[ "${KLMS_SHARED_SYNC_LOCK_HELD:-0}" == "1" ]] || return 0
  [[ -d "$KLMS_SHARED_SYNC_LOCK_DIR" ]] || return 0

  local owner_pid
  owner_pid="$(klms_shared_sync_lock_owner_pid)"
  if [[ "$owner_pid" != "$$" ]]; then
    return 0
  fi

  rm -f "$KLMS_SHARED_SYNC_LOCK_DIR/pid" \
    "$KLMS_SHARED_SYNC_LOCK_DIR/command" \
    "$KLMS_SHARED_SYNC_LOCK_DIR/acquired_at"
  rmdir "$KLMS_SHARED_SYNC_LOCK_DIR" 2>/dev/null || true
}

klms_write_login_status_ok() {
  local now_epoch
  now_epoch="$(date +%s)"
  cat > "$KLMS_LOGIN_STATUS_PATH" <<EOF
{"checked_at_epoch":$now_epoch,"logged_in":true}
EOF
}

klms_clear_login_status() {
  rm -f "$KLMS_LOGIN_STATUS_PATH"
}

klms_open_login_page_if_enabled() {
  [[ "${KLMS_LOGIN_OPEN_SAFARI_ON_FAILURE:-1}" == "1" ]] || return 0

  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'set targetUrl to item 1 of argv' \
    -e 'tell application "Safari"' \
    -e 'set reusedTab to false' \
    -e 'repeat with w in windows' \
    -e 'repeat with t in tabs of w' \
    -e 'set tabUrl to ""' \
    -e 'try' \
    -e 'set tabUrl to URL of t' \
    -e 'end try' \
    -e 'if tabUrl contains "klms.kaist.ac.kr" or tabUrl contains "portal.kaist.ac.kr" then' \
    -e 'set current tab of w to t' \
    -e 'set URL of t to targetUrl' \
    -e 'set reusedTab to true' \
    -e 'exit repeat' \
    -e 'end if' \
    -e 'end repeat' \
    -e 'if reusedTab then exit repeat' \
    -e 'end repeat' \
    -e 'if reusedTab is false then' \
    -e 'if (count of windows) is 0 then' \
    -e 'make new document with properties {URL:targetUrl}' \
    -e 'else' \
    -e 'tell window 1 to set current tab to (make new tab at end of tabs with properties {URL:targetUrl})' \
    -e 'end if' \
    -e 'end if' \
    -e 'end tell' \
    -e 'end run' \
    "$KLMS_LOGIN_URL" >/dev/null 2>&1 || true
}

klms_try_kaikey_auto_login() {
  local login_assist_enabled="${KAIKEY_LOGIN_ASSIST_ENABLED:-${KAIKEY_AUTO_LOGIN_ENABLED:-0}}"
  [[ "$login_assist_enabled" == "1" ]] || return 1
  [[ -f "$SCRIPT_DIR/kaikey_auto_login.sh" ]] || return 1
  if [[ "${KAIKEY_AUTO_APPROVE_ENABLED:-1}" != "1" && "${KAIKEY_LOGIN_ASSIST_ALLOW_NONINTERACTIVE:-0}" != "1" && ! -t 1 ]]; then
    return 1
  fi

  if /bin/zsh "$SCRIPT_DIR/kaikey_auto_login.sh" "$CONFIG_PATH"; then
    print -r -- "KLMS 로그인 보조 완료" >&2
    return 0
  else
    print -r -- "KLMS 로그인 보조 실패" >&2
    return 1
  fi
}

klms_fast_tab_login_state() {
  if [[ "${KLMS_LOGIN_FAST_TAB_CHECK_ENABLED:-1}" != "1" ]]; then
    print -r -- "unknown"
    return 0
  fi

  local tabs_json
  tabs_json="$(cd "$SCRIPT_DIR" && /usr/bin/osascript -l JavaScript "$KLMS_JS_DIR/inspect_klms_tabs.js" 2>/dev/null)" || {
    print -r -- "unknown"
    return 0
  }

  python3 -c '
import json
import sys

def looks_like_login(url: str, title: str) -> bool:
    url_lower = (url or "").lower()
    title_lower = (title or "").lower()
    return (
        "login" in url_lower
        or "portal.kaist.ac.kr" in url_lower
        or "log in" in title_lower
        or "single sign on" in title_lower
    )

payload = json.load(sys.stdin)
tabs = payload.get("tabs") or []
has_authenticated = False
has_login = False

for tab in tabs:
    url = str(tab.get("url") or "")
    title = str(tab.get("title") or "")
    if "klms.kaist.ac.kr" not in url.lower():
        continue
    if looks_like_login(url, title):
        has_login = True
    else:
        has_authenticated = True

if has_login and not has_authenticated:
    print("login_required")
elif has_authenticated:
    print("authenticated")
else:
    print("unknown")
' <<< "$tabs_json"
}

klms_check_login_pages() {
  local pages_json="$1"
  local error_message="${2:-KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘.}"
  local report_failure="${3:-1}"
  local status_json login_result message

  status_json="$(cd "$SCRIPT_DIR" && /usr/bin/env python3 "$KLMS_PYTHON_DIR/klms_sync.py" check-login-status --pages-json "$pages_json")"
  login_result="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","error"))' <<< "$status_json")"

  if [[ "$login_result" == "ok" ]]; then
    klms_write_login_status_ok
    return 0
  fi

  klms_clear_login_status
  message="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("message",""))' <<< "$status_json")"
  if [[ -z "$message" ]]; then
    message="$error_message"
  fi
  KLMS_LAST_LOGIN_ERROR_MESSAGE="$message"
  if [[ "$report_failure" == "1" ]]; then
    klms_open_login_page_if_enabled
    print -r -- "$message" >&2
  fi
  return 1
}

klms_require_login() {
  if [[ "${KLMS_PARENT_LOGIN_PREFLIGHT_READY:-0}" == "1" && "${KLMS_USE_EXISTING_DASHBOARD:-0}" == "1" && -s "$WORK_CACHE_DIR/dashboard.json" ]]; then
    klms_check_login_pages "$WORK_CACHE_DIR/dashboard.json" || return 1
    KLMS_LOGIN_PREFETCH_READY=1
    return 0
  fi

  local fast_tab_state
  fast_tab_state="$(klms_fast_tab_login_state)"
  if [[ "$fast_tab_state" == "login_required" ]]; then
    klms_clear_login_status
    if ! klms_try_kaikey_auto_login; then
      klms_open_login_page_if_enabled
      print -r -- "KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘." >&2
      return 1
    fi
  fi

  local url_file="$TMP_DIR/klms_login_preflight_urls.txt"
  local pages_json="$CACHE_DIR/dashboard.json"

  printf '%s\n' "$KLMS_DASHBOARD_URL" > "$url_file"
  (
    cd "$SCRIPT_DIR"
    /usr/bin/env python3 "$KLMS_PYTHON_DIR/fetch_pages_backend.py" \
      --backend=safari \
      --mode=full \
      --context=klms-login-preflight \
      --wait="$SAFARI_WAIT_SECONDS" \
      --min-wait="$FETCH_MIN_WAIT_SECONDS" \
      --stable-polls="$FETCH_STABLE_POLLS" \
      --out="$pages_json" \
      --cache-state="$FETCH_CACHE_STATE_PATH" \
      --discard-previous \
      --allow-login-pages \
      --url-file="$url_file"
  )

  if ! klms_check_login_pages "$pages_json" "KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘." 0; then
    if klms_try_kaikey_auto_login; then
      (
        cd "$SCRIPT_DIR"
        /usr/bin/env python3 "$KLMS_PYTHON_DIR/fetch_pages_backend.py" \
          --backend=safari \
          --mode=full \
          --context=klms-login-preflight \
          --wait="$SAFARI_WAIT_SECONDS" \
          --min-wait="$FETCH_MIN_WAIT_SECONDS" \
          --stable-polls="$FETCH_STABLE_POLLS" \
          --out="$pages_json" \
          --cache-state="$FETCH_CACHE_STATE_PATH" \
          --discard-previous \
          --allow-login-pages \
          --url-file="$url_file"
      )
      klms_check_login_pages "$pages_json" || return 1
    else
      klms_open_login_page_if_enabled
      print -r -- "${KLMS_LAST_LOGIN_ERROR_MESSAGE:-KLMS 로그인이 풀린 것 같아. 다시 로그인해 줘.}" >&2
      return 1
    fi
  fi
  KLMS_LOGIN_PREFETCH_READY=1
  return 0
}

klms_run_sync_scope() {
  local scope="$1"
  local extra_args=()
  if [[ "${KLMS_LOGIN_PREFETCH_READY:-0}" == "1" ]]; then
    extra_args+=("--use-prefetched-dashboard")
  fi

  /usr/bin/osascript -l JavaScript \
    "$KLMS_JS_DIR/sync_klms_notes.js" \
    "$CONFIG_PATH" \
    "--scope=$scope" \
    "${extra_args[@]}"
}

klms_run_sync_scope_entrypoint() {
  local scope="$1"
  local sync_output

  klms_acquire_shared_sync_lock
  trap 'klms_release_shared_sync_lock' EXIT
  klms_require_login
  sync_output="$(klms_run_sync_scope "$scope")"
  print -r -- "$sync_output"
  if [[ "$sync_output" != status=ok* ]]; then
    return 1
  fi
  klms_cleanup_runtime_tmp_if_enabled
}

klms_export_shared_sync_cache_defaults() {
  export KLMS_RUN_STARTED_EPOCH="${KLMS_RUN_STARTED_EPOCH:-$(date +%s)}"
  export KLMS_SHARED_COURSE_PAGES_JSON="${KLMS_SHARED_COURSE_PAGES_JSON:-$CACHE_DIR/core/course_pages.json}"
  export KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON="${KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON:-$CACHE_DIR/core/all_week_course_pages.json}"
  export KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON="${KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON:-$CACHE_DIR/core/supplemental_primary_pages.json}"
}

klms_prepare_prefetched_dashboard_for_namespaces() {
  local prefetched_dashboard="$CACHE_DIR/dashboard.json"
  local namespace

  for namespace in "$@"; do
    mkdir -p "$CACHE_DIR/$namespace"
    if [[ -s "$prefetched_dashboard" ]]; then
      cp "$prefetched_dashboard" "$CACHE_DIR/$namespace/dashboard.json"
    fi
  done
}

klms_run_serial_child_job() {
  local job_name="$1"
  local script_path="$2"
  local started_epoch
  local finished_epoch
  local job_status=0

  started_epoch="$(date +%s)"
  print -r -- "== $job_name start $(date '+%Y-%m-%d %H:%M:%S %Z') =="
  (
    cd "$SCRIPT_DIR"
    /usr/bin/env -u KLMS_SHARED_SYNC_LOCK_HELD -u KLMS_SHARED_SYNC_LOCK_DIR \
      KLMS_USE_EXISTING_DASHBOARD=1 \
      KLMS_PARENT_LOGIN_PREFLIGHT_READY=1 \
      KLMS_RUN_STARTED_EPOCH="$KLMS_RUN_STARTED_EPOCH" \
      KLMS_SHARED_COURSE_PAGES_JSON="$KLMS_SHARED_COURSE_PAGES_JSON" \
      KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON="$KLMS_SHARED_ALL_WEEK_COURSE_PAGES_JSON" \
      KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON="$KLMS_SHARED_SUPPLEMENTAL_PRIMARY_PAGES_JSON" \
      /bin/zsh "$script_path" "$CONFIG_PATH"
  ) || job_status=$?
  finished_epoch="$(date +%s)"
  print -r -- "== $job_name finish $(date '+%Y-%m-%d %H:%M:%S %Z') status=$job_status duration_s=$((finished_epoch - started_epoch)) =="
  return "$job_status"
}

klms_cleanup_runtime_tmp_if_enabled() {
  if [[ "${KLMS_RUNTIME_TMP_CLEANUP_ENABLED:-1}" != "1" ]]; then
    return 0
  fi

  local max_age_hours="${KLMS_RUNTIME_TMP_MAX_AGE_HOURS:-24}"
  KLMS_RUNTIME_TMP_CLEANUP_TARGET="$TMP_DIR" \
    /bin/zsh "$KLMS_SH_DIR/cleanup_runtime_tmp.sh" --max-age-hours "$max_age_hours" >/dev/null 2>&1 || true
}

klms_cleanup_tmp_root_if_enabled() {
  if [[ "${KLMS_RUNTIME_TMP_CLEANUP_ENABLED:-1}" != "1" ]]; then
    return 0
  fi

  local max_age_hours="${KLMS_RUNTIME_TMP_MAX_AGE_HOURS:-24}"
  KLMS_RUNTIME_TMP_CLEANUP_TARGET="$TMP_ROOT_DIR" \
    /bin/zsh "$KLMS_SH_DIR/cleanup_runtime_tmp.sh" --max-age-hours "$max_age_hours" >/dev/null 2>&1 || true
}
