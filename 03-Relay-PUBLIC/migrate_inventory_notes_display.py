#!/usr/bin/env python3
"""Normalize timestamps and OS text in agent-managed Snipe-IT notes."""

from __future__ import annotations

import argparse
import json
import re
import time
import urllib.parse
from pathlib import Path
from typing import Any, Dict, Optional

from migrate_inventory_time_display import field_value, request_with_retry
from snipeit_mail_relay import (
    SnipeApi,
    format_inventory_notes_time,
    load_config,
    normalize_os_summary,
    parse_datetime,
    parse_inventory_display_time,
)


AGENT_HEADER = "Auto inventory by SnipeIT Inventory Agent"
LEGACY_AGENT_HEADER = "Auto inventory by PCInventoryAgent"
RELAY_HEADER = "Auto inventory by SnipeIT Inventory Relay"
LEGACY_RELAY_HEADER = "Auto inventory imported from signed mail relay."
TIME_LINE = re.compile(r"^(Updated|Observed|Inventory timestamp):\s*(.*)$", re.IGNORECASE)


def human_notes_time(value: str, timezone_name: str) -> str:
    parsed = parse_datetime(value)
    if parsed is None:
        parsed = parse_inventory_display_time(value, timezone_name)
    if parsed is None:
        return ""
    return format_inventory_notes_time(parsed.isoformat(), timezone_name)


def sanitize_auto_notes(
    notes: Any,
    os_summary: Any,
    timezone_name: str = "Europe/Moscow",
) -> Optional[str]:
    original = str(notes or "").replace("\r\n", "\n").strip()
    if not original:
        return None
    lines = original.split("\n")
    header = lines[0].strip()
    if header not in (AGENT_HEADER, LEGACY_AGENT_HEADER, RELAY_HEADER, LEGACY_RELAY_HEADER):
        return None

    label = "Observed" if header in (RELAY_HEADER, LEGACY_RELAY_HEADER) else "Updated"
    timestamp = ""
    for line in lines[1:]:
        match = TIME_LINE.match(line.strip())
        if not match:
            continue
        candidate = human_notes_time(match.group(2), timezone_name)
        if candidate:
            timestamp = candidate
            if match.group(1).lower() != "inventory timestamp":
                break

    clean_os = normalize_os_summary(os_summary)
    normalized_header = {
        LEGACY_AGENT_HEADER: AGENT_HEADER,
        LEGACY_RELAY_HEADER: RELAY_HEADER,
    }.get(header, header)
    rebuilt = [normalized_header]
    if timestamp:
        rebuilt.append(f"{label}: {timestamp}")

    for line in lines[1:]:
        stripped = line.strip()
        if TIME_LINE.match(stripped):
            continue
        if stripped.lower().startswith("os:"):
            current_os = stripped.split(":", 1)[1].strip()
            value = clean_os or normalize_os_summary(current_os)
            rebuilt.append(f"OS: {value}" if value else "OS:")
            continue
        rebuilt.append(line.rstrip())

    while len(rebuilt) > 1 and not rebuilt[-1].strip():
        rebuilt.pop()
    normalized = "\n".join(rebuilt)
    return normalized if normalized != original else None


def migration_body(
    asset: Dict[str, Any],
    os_field: str,
    timezone_name: str,
) -> Optional[Dict[str, str]]:
    previous_notes = str(asset.get("notes") or "")
    previous_os = field_value(asset, os_field) if os_field else ""
    clean_os = normalize_os_summary(previous_os)
    body: Dict[str, str] = {}
    replacement_notes = sanitize_auto_notes(previous_notes, clean_os, timezone_name)
    if replacement_notes is not None:
        body["notes"] = replacement_notes
    if os_field and clean_os and clean_os != previous_os:
        body[os_field] = clean_os
    return body or None


def run(
    config_path: str,
    apply: bool,
    limit: int,
    backup_path: str = "",
    delay_seconds: float = 0.5,
) -> Dict[str, int]:
    config = load_config(config_path)
    api = SnipeApi(config)
    timezone_name = str(config.get("display_timezone") or "Europe/Moscow")
    os_field = str((config.get("custom_fields") or {}).get("os") or "")
    summary = {
        "scanned": 0,
        "would_update": 0,
        "updated": 0,
        "unchanged_or_manual": 0,
    }
    plans = []
    offset = 0

    while True:
        query = urllib.parse.urlencode({"limit": limit, "offset": offset, "sort": "id", "order": "asc"})
        response = request_with_retry(api, "GET", f"/api/v1/hardware?{query}")
        rows = api.rows(response)
        if not rows:
            break

        for row in rows:
            summary["scanned"] += 1
            asset_id = int(row["id"])
            asset = SnipeApi.payload(request_with_retry(api, "GET", f"/api/v1/hardware/{asset_id}")) or {}
            if delay_seconds > 0:
                time.sleep(delay_seconds)
            previous = str(asset.get("notes") or "")
            previous_os = field_value(asset, os_field) if os_field else ""
            body = migration_body(asset, os_field, timezone_name)
            if body is None:
                summary["unchanged_or_manual"] += 1
                continue
            summary["would_update"] += 1
            plans.append(
                {
                    "id": asset_id,
                    "name": asset.get("name"),
                    "asset_tag": asset.get("asset_tag"),
                    "previous_notes": previous,
                    "previous_os": previous_os,
                    "body": body,
                }
            )

        offset += len(rows)
        total = int(response.get("total") or 0) if isinstance(response, dict) else 0
        if len(rows) < limit or (total and offset >= total):
            break

    if backup_path:
        destination = Path(backup_path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        backup = [{key: value for key, value in plan.items() if key != "body"} for plan in plans]
        destination.write_text(json.dumps(backup, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        summary["backup_records"] = len(backup)

    if apply:
        for plan in plans:
            request_with_retry(api, "PATCH", f"/api/v1/hardware/{plan['id']}", plan["body"])
            summary["updated"] += 1
            if delay_seconds > 0:
                time.sleep(delay_seconds)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--backup", default="")
    parser.add_argument("--delay", type=float, default=0.5)
    args = parser.parse_args()
    print(
        json.dumps(
            run(
                args.config,
                args.apply,
                max(1, min(args.limit, 500)),
                args.backup,
                max(0.0, args.delay),
            ),
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
