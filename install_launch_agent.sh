#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_PATH="${CONFIG_PATH:-$SCRIPT_DIR/config.env}"
if [[ -f "$CONFIG_PATH" ]]; then
  source "$CONFIG_PATH"
else
  print -r -- "Missing config file: $CONFIG_PATH" >&2
  print -r -- "Copy examples/config.env.example to config.env and edit it first." >&2
  exit 1
fi

INSTALL_DIR="$HOME/Library/Application Support/KLMSNotesSync"
LABEL="${KLMS_LAUNCHD_LABEL:-com.local.klms-notes-sync}"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI_DOMAIN="gui/$(id -u)"

mkdir -p "$HOME/Library/LaunchAgents" "$INSTALL_DIR/runtime/logs"
mkdir -p "$INSTALL_DIR/runtime/automation"
mkdir -p "$INSTALL_DIR/src" "$INSTALL_DIR/bin"

cp -R "$SCRIPT_DIR/src/." "$INSTALL_DIR/src/"
cp -R "$SCRIPT_DIR/bin/." "$INSTALL_DIR/bin/"
cp "$SCRIPT_DIR/kaikey_auto_login.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/kaikey_approve_number.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/kaikey_setup.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/sync_klms_core.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/sync_klms_notice.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/sync_klms_all.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/run_all.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/run_all_full.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/refresh_course_files.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/run_all_parallel.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/verify_sync_state.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/doctor.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/sync_report.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/config.env" "$INSTALL_DIR/"
if [[ -f "$SCRIPT_DIR/manual_assignment_overrides.json" ]]; then
  cp "$SCRIPT_DIR/manual_assignment_overrides.json" "$INSTALL_DIR/"
fi

chmod +x \
  "$INSTALL_DIR/kaikey_auto_login.sh" \
  "$INSTALL_DIR/kaikey_approve_number.sh" \
  "$INSTALL_DIR/kaikey_setup.sh" \
  "$INSTALL_DIR/sync_klms_core.sh" \
  "$INSTALL_DIR/sync_klms_notice.sh" \
  "$INSTALL_DIR/sync_klms_all.sh" \
  "$INSTALL_DIR/run_all.sh" \
  "$INSTALL_DIR/run_all_full.sh" \
  "$INSTALL_DIR/run_all_parallel.sh" \
  "$INSTALL_DIR/refresh_course_files.sh" \
  "$INSTALL_DIR/verify_sync_state.sh" \
  "$INSTALL_DIR/doctor.sh" \
  "$INSTALL_DIR/sync_report.sh"

find "$INSTALL_DIR/src/sh" "$INSTALL_DIR/src/js" "$INSTALL_DIR/src/python" -type f \
  \( -name '*.sh' -o -name '*.js' -o -name '*.mjs' -o -name '*.py' \) \
  -exec chmod +x {} +
find "$INSTALL_DIR/bin" -type f -name '*.sh' -exec chmod +x {} +

rm -f "$INSTALL_DIR/inspect_klms_front_tab.js"
rm -f "$INSTALL_DIR/sync_klms_alert_calendar.swift"
rm -f "$INSTALL_DIR/launch_sync_if_idle.sh" \
  "$INSTALL_DIR/watch_klms_login_recovery.sh" \
  "$INSTALL_DIR/klms_common.sh" \
  "$INSTALL_DIR/kaikey_cli.mjs" \
  "$INSTALL_DIR/kaikey_safari_step.js" \
  "$INSTALL_DIR/decode_qr_image.swift" \
  "$INSTALL_DIR/notify_klms_reminders.js" \
  "$INSTALL_DIR/inspect_klms_tabs.js" \
  "$INSTALL_DIR/sync_klms_notes.js" \
  "$INSTALL_DIR/cleanup_runtime_tmp.sh" \
  "$INSTALL_DIR/sync_klms_calendar.swift" \
  "$INSTALL_DIR/sync_klms_calendar_suite.swift" \
  "$INSTALL_DIR/sync_klms_calendar_jxa.js" \
  "$INSTALL_DIR/fetch_pages_backend.py" \
  "$INSTALL_DIR/fetch_pages_with_safari.js" \
  "$INSTALL_DIR/klms_sync.py" \
  "$INSTALL_DIR/update_notice_native_note.sh" \
  "$INSTALL_DIR/update_notice_native_note.swift" \
  "$INSTALL_DIR/capture_notice_native_state.swift" \
  "$INSTALL_DIR/build_course_file_manifest.py" \
  "$INSTALL_DIR/download_klms_files.js" \
  "$INSTALL_DIR/prune_course_files.py" \
  "$INSTALL_DIR/cleanup_tracked_downloads.js" \
  "$INSTALL_DIR/build_pdf_from_images.py"

date +%s > "$INSTALL_DIR/runtime/automation/last_attempt_epoch"

cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$INSTALL_DIR/src/sh/launch_sync_if_idle.sh</string>
  </array>

  <key>WorkingDirectory</key>
  <string>$INSTALL_DIR</string>

  <key>RunAtLoad</key>
  <true/>

  <key>StartInterval</key>
  <integer>900</integer>

  <key>StandardOutPath</key>
  <string>$INSTALL_DIR/runtime/logs/launchd.stdout.log</string>

  <key>StandardErrorPath</key>
  <string>$INSTALL_DIR/runtime/logs/launchd.stderr.log</string>
</dict>
</plist>
EOF

launchctl bootout "$GUI_DOMAIN" "$PLIST_DST" >/dev/null 2>&1 || true
launchctl bootstrap "$GUI_DOMAIN" "$PLIST_DST"
launchctl enable "$GUI_DOMAIN/$LABEL"

echo "Installed $PLIST_DST"
echo "Automation files copied to $INSTALL_DIR"
launchctl print "$GUI_DOMAIN/$LABEL" | sed -n '1,20p'
