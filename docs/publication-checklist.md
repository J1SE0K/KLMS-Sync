# Publication Checklist

Use this checklist before pushing the repository to a public GitHub repo.

## Files

- `config.env` is local only and ignored.
- `manual_assignment_overrides.json` is local only and ignored.
- `kaikey_state.json` is local only and ignored.
- `runtime/`, `course_files/`, `course_transcripts/`, and `course_videos/` are ignored.
- QR screenshots, cookies, logs, launchd plists, and downloaded KLMS files are not tracked.
- One-off scripts containing a real semester, course, student, assistant, or submission dataset are not tracked.

## Scans

Run these before publishing:

```sh
git status --short
git status --ignored --short
git ls-files | rg '(^|/)(config\.env|manual_assignment_overrides\.json|kaikey_state\.json)$|^(runtime|course_files|course_transcripts|course_videos)/'
git grep -n -E '(/Users/|bwid=[0-9]+|MoodleSession|MOODLEID_|[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,})' -- ':!docs/publication-checklist.md'
git grep -n -E '(학번|주민|전화|서지석|gs36212js)' -- ':!docs/publication-checklist.md'
```

The first command should show only intentional source/documentation changes. The ignored status may show local private files, but those files must not appear in `git status --short` as tracked or untracked commit candidates.

## Verification

Run syntax checks and focused tests:

```sh
python3 -m unittest discover -s tests
node --check src/js/kaikey_cli.mjs
node --check src/js/sync_klms_notes.js
node --check src/js/download_klms_files.js
node --check src/js/export_panopto_transcripts.js
zsh -n *.sh bin/*.sh src/sh/*.sh
swiftc -typecheck src/swift/decode_qr_image.swift
swiftc -typecheck src/swift/verify_calendar_counts.swift
swiftc -typecheck src/swift/notice_native_note_support.swift src/swift/update_notice_native_note.swift
```

Some runtime checks need Safari, macOS Automation permissions, Reminders, Calendar, Notes, and an active KLMS session. Do not record or publish outputs containing course pages or account data.

## GitHub

Create an empty public repository, then push only after the scans are clean:

```sh
git remote add origin git@github.com:<owner>/<repo>.git
git push -u origin main
```

After pushing, check the GitHub file list in the browser. If a secret or private artifact was pushed, remove the exposed credential or MFA registration first, then rewrite or delete the public history.
