#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--script-dir", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--state-json", required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--write-json")
    return parser


def check(name: str, status: str, detail: str = "") -> dict[str, str]:
    return {"name": name, "status": status, "detail": detail}


def run_quick(argv: list[str], cwd: Path, timeout: int = 8) -> tuple[bool, str]:
    try:
        result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)
    text = (result.stderr or result.stdout or "").strip().splitlines()
    return result.returncode == 0, text[0] if text else f"exit={result.returncode}"


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def build_result(script_dir: Path, config: Path, cache_dir: Path, state_json: Path) -> dict[str, Any]:
    checks: list[dict[str, str]] = []
    checks.append(check("config.env", "ok" if config.exists() else "fail", str(config)))

    for name in ("python3", "node", "swift", "osascript"):
        found = shutil.which(name)
        checks.append(check(f"executable:{name}", "ok" if found else "fail", found or "not found"))

    swift_cache = script_dir / "runtime" / "tmp" / "doctor" / "swift-module-cache"
    clang_cache = script_dir / "runtime" / "tmp" / "doctor" / "clang-module-cache"
    try:
        swift_cache.mkdir(parents=True, exist_ok=True)
        clang_cache.mkdir(parents=True, exist_ok=True)
        probe = swift_cache / ".write-probe"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
        checks.append(check("swift-module-cache", "ok", str(swift_cache)))
    except Exception as exc:  # noqa: BLE001
        checks.append(check("swift-module-cache", "fail", str(exc)))

    manifest = load_json(cache_dir / "course_file_manifest.json", [])
    if isinstance(manifest, list) and manifest:
        missing = [
            item.get("relative_path", "")
            for item in manifest
            if isinstance(item, dict) and item.get("absolute_path") and not Path(item["absolute_path"]).is_file()
        ]
        checks.append(check("file-manifest", "ok" if not missing else "fail", f"tracked={len(manifest)} missing={len(missing)}"))
    else:
        checks.append(check("file-manifest", "warn", "manifest missing or empty"))

    downloads_root = Path.home() / "Downloads" / "KLMS Files"
    checks.append(check("downloads-mirror", "ok" if downloads_root.exists() else "warn", str(downloads_root)))
    checks.append(check("state-json", "ok" if state_json.exists() else "warn", str(state_json)))
    dashboard = load_json(cache_dir / "dashboard.json", [])
    if isinstance(dashboard, list) and dashboard:
        dashboard_text = json.dumps(dashboard[0], ensure_ascii=False).casefold()
        login_like = any(token in dashboard_text for token in ("login", "로그인", "sso"))
        checks.append(check("klms-login-cache", "warn" if login_like else "ok", "dashboard cache looks login-like" if login_like else "dashboard cache present"))
    else:
        checks.append(check("klms-login-cache", "warn", "dashboard cache missing"))
    for scope in ("core", "notice", "files"):
        timing = cache_dir / scope / "stage_timings.json"
        checks.append(check(f"stage-timing:{scope}", "ok" if timing.exists() else "warn", str(timing)))

    for app_name in ("Safari", "Notes", "Calendar", "Reminders"):
        ok, detail = run_quick(["/usr/bin/osascript", "-e", f'id of application "{app_name}"'], script_dir)
        checks.append(check(f"app-available:{app_name}", "ok" if ok else "warn", detail))

    overall = "fail" if any(item["status"] == "fail" for item in checks) else "ok"
    return {"status": overall, "checks": checks}


def print_text(result: dict[str, Any]) -> None:
    print(f"doctor_status={result['status']}")
    for item in result["checks"]:
        print(f"{item['status']}\t{item['name']}\t{item['detail']}")


def main() -> int:
    args = build_parser().parse_args()
    result = build_result(Path(args.script_dir), Path(args.config), Path(args.cache_dir), Path(args.state_json))
    if args.write_json:
        Path(args.write_json).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print_text(result)
    return 1 if result["status"] == "fail" else 0


if __name__ == "__main__":
    raise SystemExit(main())
