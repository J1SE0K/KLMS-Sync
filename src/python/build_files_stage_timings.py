#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any


KST = timezone(timedelta(hours=9))
LOG_PATTERN = re.compile(r"^\[files (?P<ts>[^]]+)\] (?P<message>.*)$")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--status", default="ok")
    parser.add_argument("--error", default="")
    return parser


def main_with_args(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    log_path = Path(args.log)
    output_path = Path(args.output_json)
    records = parse_log(log_path.read_text(encoding="utf-8") if log_path.exists() else "")
    payload = build_payload(records, args.status, args.error)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


def parse_log(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line in text.splitlines():
        match = LOG_PATTERN.match(line)
        if not match:
            continue
        records.append(
            {
                "timestamp": parse_timestamp(match.group("ts")),
                "message": match.group("message"),
            }
        )
    return records


def parse_timestamp(value: str) -> datetime:
    if value.endswith(" KST"):
        return datetime.strptime(value.removesuffix(" KST"), "%Y-%m-%d %H:%M:%S").replace(tzinfo=KST)
    return datetime.strptime(value, "%Y-%m-%d %H:%M:%S %Z").replace(tzinfo=KST)


def build_payload(records: list[dict[str, Any]], status: str, error: str) -> dict[str, Any]:
    start_at = records[0]["timestamp"] if records else datetime.now(tz=KST)
    completed_at = records[-1]["timestamp"] if records else start_at
    starts: dict[str, datetime] = {}
    stages: list[dict[str, Any]] = []
    events: list[dict[str, Any]] = []

    for record in records:
        message = str(record["message"])
        timestamp = record["timestamp"]
        events.append(
            {
                "group": "log",
                "name": stage_name_from_message(message),
                "stage": "",
                "message": message,
                "started_at": iso(timestamp),
                "finished_at": iso(timestamp),
                "duration_ms": 0,
                "status": "ok",
                "error": "",
            }
        )

        start_name = start_stage_name(message)
        if start_name:
            starts[start_name] = timestamp
            continue

        finish_name = finish_stage_name(message)
        if not finish_name:
            continue
        if finish_name == "refresh":
            continue

        duration_ms = duration_from_message(message)
        started_at = starts.get(finish_name, timestamp)
        if duration_ms is None:
            duration_ms = max(0, int((timestamp - started_at).total_seconds() * 1000))
        else:
            started_at = timestamp - timedelta(milliseconds=duration_ms)

        stages.append(
            {
                "name": finish_name,
                "started_at": iso(started_at),
                "finished_at": iso(timestamp),
                "duration_ms": duration_ms,
                "status": "ok",
                "error": "",
            }
        )

    elapsed_ms = max(0, int((completed_at - start_at).total_seconds() * 1000))
    slowest = sorted(stages, key=lambda item: int(item.get("duration_ms", 0)), reverse=True)[:5]
    return {
        "version": 1,
        "scope": "files",
        "run_started_at": iso(start_at),
        "completed_at": iso(completed_at),
        "elapsed_ms": elapsed_ms,
        "status": status,
        "failed_stage": "",
        "error": error,
        "events": events,
        "stages": stages,
        "slowest_stages": slowest,
    }


def stage_name_from_message(message: str) -> str:
    return start_stage_name(message) or finish_stage_name(message) or message.split(" ", 1)[0]


def start_stage_name(message: str) -> str:
    if message.startswith("fetch start "):
        return field_value(message, "context") or "fetch"
    if message.endswith(" start"):
        return message.removesuffix(" start")
    if " start " in message:
        return message.split(" start ", 1)[0]
    return ""


def finish_stage_name(message: str) -> str:
    if message.startswith("fetch finish "):
        return field_value(message, "context") or "fetch"
    for marker in (" finish", " skipped"):
        if marker in message:
            return message.split(marker, 1)[0]
    return ""


def duration_from_message(message: str) -> int | None:
    raw = field_value(message, "duration_s")
    if raw is None:
        return None
    try:
        return int(float(raw) * 1000)
    except ValueError:
        return None


def field_value(message: str, key: str) -> str | None:
    prefix = f"{key}="
    for part in message.split():
        if part.startswith(prefix):
            return part[len(prefix) :]
    return None


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


if __name__ == "__main__":
    raise SystemExit(main_with_args())
