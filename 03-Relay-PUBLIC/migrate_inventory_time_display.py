#!/usr/bin/env python3
"""Convert SnipeIT Inventory timestamps to a compact one-line display."""

from __future__ import annotations

import argparse
import json
import re
import time
import urllib.parse
from pathlib import Path
from typing import Any, Dict, Optional

from snipeit_mail_relay import (
    SnipeApi,
    TransientRelayError,
    format_inventory_display_time,
    load_config,
    parse_datetime,
    parse_inventory_display_time,
)


DISPLAY_PATTERN = re.compile(r"^\d{2}:\d{2} \d{2}\.\d{2}\.\d{4}$")


def field_value(asset: Dict[str, Any], field_name: str) -> str:
    custom_fields = asset.get("custom_fields")
    if not isinstance(custom_fields, dict):
        return ""
    for label, item in custom_fields.items():
        item_field = item.get("field") if isinstance(item, dict) else ""
        value = item.get("value") if isinstance(item, dict) else item
        if label == field_name or item_field == field_name or "last successful" in str(label).lower():
            return str(value or "").strip()
    return ""


def migration_body(
    asset: Dict[str, Any],
    field_name: str,
    display_timezone: str = "Europe/Moscow",
) -> Optional[Dict[str, str]]:
    current = field_value(asset, field_name)
    if not current or DISPLAY_PATTERN.fullmatch(current.replace("\r\n", "\n")):
        return None
    parsed = parse_datetime(current)
    if parsed is None:
        parsed = parse_inventory_display_time(current, display_timezone)
    if parsed is None:
        return None

    display = format_inventory_display_time(parsed, display_timezone)
    return {field_name: display}


def request_with_retry(
    api: SnipeApi,
    method: str,
    path: str,
    body: Optional[Dict[str, Any]] = None,
    attempts: int = 6,
) -> Any:
    for attempt in range(1, attempts + 1):
        try:
            return api.request(method, path, body)
        except TransientRelayError as exc:
            message = str(exc)
            if "HTTP 429" not in message or attempt == attempts:
                raise
            retry_match = re.search(r'"retryAfter"\s*:\s*(\d+)', message)
            retry_after = int(retry_match.group(1)) if retry_match else 30
            time.sleep(max(1, retry_after + 1))
    raise RuntimeError(f"Request retry loop exhausted: {method} {path}")


def run(
    config_path: str,
    apply: bool,
    limit: int,
    backup_path: str = "",
    delay_seconds: float = 1.0,
) -> Dict[str, int]:
    config = load_config(config_path)
    api = SnipeApi(config)
    field_name = str((config.get("custom_fields") or {}).get("last_success") or "")
    display_timezone = str(config.get("display_timezone") or "Europe/Moscow")
    if not field_name:
        raise RuntimeError("custom_fields.last_success is not configured")

    summary = {
        "scanned": 0,
        "would_update": 0,
        "updated": 0,
        "already_formatted_or_empty": 0,
        "unparseable": 0,
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
            current = field_value(row, field_name)
            if not current or DISPLAY_PATTERN.fullmatch(current.replace("\r\n", "\n")):
                summary["already_formatted_or_empty"] += 1
                continue
            asset = SnipeApi.payload(request_with_retry(api, "GET", f"/api/v1/hardware/{asset_id}")) or {}
            if delay_seconds > 0:
                time.sleep(delay_seconds)
            current = field_value(asset, field_name)
            if not current or DISPLAY_PATTERN.fullmatch(current.replace("\r\n", "\n")):
                summary["already_formatted_or_empty"] += 1
                continue
            body = migration_body(asset, field_name, display_timezone)
            if body is None:
                summary["unparseable"] += 1
                continue
            summary["would_update"] += 1
            plans.append(
                {
                    "id": asset_id,
                    "name": asset.get("name"),
                    "asset_tag": asset.get("asset_tag"),
                    "previous_last_success": current,
                    "previous_notes": asset.get("notes"),
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
    parser.add_argument("--delay", type=float, default=1.0)
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
