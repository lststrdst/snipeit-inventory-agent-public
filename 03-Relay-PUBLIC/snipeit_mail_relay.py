#!/usr/bin/env python3
"""Import signed offline inventory envelopes from IMAP into Snipe-IT."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import email
import hashlib
import hmac
import imaplib
import json
import logging
import os
import re
import smtplib
import sqlite3
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from email.message import EmailMessage, Message
from email.policy import default as email_policy
from email.utils import parseaddr
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


LOGGER = logging.getLogger("snipeit-mail-relay")
RELAY_VERSION = "1.3.3"


class RelayError(RuntimeError):
    pass


class TransientRelayError(RelayError):
    pass


class StaleEvent(RelayError):
    pass


class IgnoredEvent(RelayError):
    """A valid signed event that must not mutate Snipe-IT."""


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def parse_datetime(value: Any) -> Optional[dt.datetime]:
    if value is None:
        return None
    if isinstance(value, dict):
        for key in ("datetime", "date", "formatted", "value"):
            parsed = parse_datetime(value.get(key))
            if parsed:
                return parsed
        return None
    text = str(value).strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(text)
    except ValueError:
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
            try:
                parsed = dt.datetime.strptime(text, fmt)
                break
            except ValueError:
                parsed = None
        if parsed is None:
            return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def format_inventory_display_time(
    value: Any,
    timezone_name: str = "Europe/Moscow",
) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    normalized = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError:
        parsed = parse_datetime(text)
    if parsed is None:
        return text
    try:
        timezone = ZoneInfo(timezone_name)
    except ZoneInfoNotFoundError:
        timezone = dt.timezone(dt.timedelta(hours=3))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone)
    else:
        parsed = parsed.astimezone(timezone)
    return parsed.strftime("%H:%M %d.%m.%Y")


def parse_inventory_display_time(value: Any, timezone_name: str = "Europe/Moscow") -> Optional[dt.datetime]:
    text = str(value or "").strip().replace("\r\n", "\n")
    if not text:
        return None
    parsed: Optional[dt.datetime] = None
    for fmt in (
        "%H:%M\n%d.%m.%Y",
        "%H:%M %d.%m.%Y",
        "%d.%m.%Y %H:%M",
        "%d.%m.%Y %H:%M:%S",
    ):
        try:
            parsed = dt.datetime.strptime(text, fmt)
            break
        except ValueError:
            continue
    if parsed is None:
        return None
    try:
        timezone = ZoneInfo(timezone_name)
    except ZoneInfoNotFoundError:
        timezone = dt.timezone(dt.timedelta(hours=3))
    return parsed.replace(tzinfo=timezone).astimezone(dt.timezone.utc)


def format_inventory_notes_time(
    value: Any,
    timezone_name: str = "Europe/Moscow",
) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    normalized = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError:
        parsed = parse_datetime(text)
    if parsed is None:
        return text
    try:
        timezone = ZoneInfo(timezone_name)
    except ZoneInfoNotFoundError:
        timezone = dt.timezone(dt.timedelta(hours=3))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone)
    else:
        parsed = parsed.astimezone(timezone)
    return parsed.strftime("%d.%m.%Y %H:%M:%S")


def require_text(value: Any, name: str, max_length: int = 4096) -> str:
    text = str(value or "").strip()
    if not text:
        raise RelayError(f"Missing required field: {name}")
    if len(text) > max_length:
        raise RelayError(f"Field is too long: {name}")
    return text


SID_RE = re.compile(r"^S-\d+-\d+(?:-\d+)+$", re.IGNORECASE)
GUID_RE = re.compile(
    r"^\{?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}?$",
    re.IGNORECASE,
)
SYSTEM_IDENTITIES = {
    "system",
    "local service",
    "network service",
    "anonymous logon",
    "local system",
    "font driver host",
    "window manager",
    ".default",
    "defaultuser0",
    "wdagutilityaccount",
}


def valid_identity_username(value: Any) -> bool:
    login = str(value or "").strip().rsplit("\\", 1)[-1]
    if not login or login.endswith("$"):
        return False
    if SID_RE.fullmatch(login) or GUID_RE.fullmatch(login):
        return False
    if login.casefold() in SYSTEM_IDENTITIES:
        return False
    if re.fullmatch(r"(?:DWM|UMFD)-\d+", login, re.IGNORECASE):
        return False
    return not any(ord(character) < 32 for character in login)


def invalid_identity_payload_reason(payload: Dict[str, Any]) -> str:
    identity = payload.get("identity") or {}
    disposition = payload.get("disposition") or {}
    username = str(identity.get("detected_username") or "").strip()
    reason = str(disposition.get("reason") or "").strip()
    requested = str(disposition.get("requested") or "assigned").strip().lower()

    if username and not valid_identity_username(username):
        return f"invalid_identity_username:{username}"
    sid_in_reason = re.search(r"(?i)(?:^|[:\\|>])(?P<sid>S-\d+-\d+(?:-\d+)+)(?:$|\s)", reason)
    if sid_in_reason:
        return f"invalid_identity_reason:{sid_in_reason.group('sid')}"
    if requested == "assigned" and not username:
        return "assigned_identity_empty"
    return ""


def text_list(value: Any) -> List[str]:
    values = value if isinstance(value, (list, tuple, set)) else [value]
    result: List[str] = []
    seen = set()
    for item in values:
        text = str(item or "").strip()
        key = text.casefold()
        if text and key not in seen:
            seen.add(key)
            result.append(text)
    return result


def configured_prefixes(
    config: Dict[str, Any],
    primary_key: str,
    legacy_key: str,
    defaults: Iterable[str],
) -> List[str]:
    values: List[str] = []
    values.extend(text_list(config.get(primary_key)))
    values.extend(text_list(config.get(legacy_key)))
    values.extend(text_list(list(defaults)))
    return text_list(values)


def load_config(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8-sig") as handle:
        config = json.load(handle)
    required = ("imap_host", "imap_user", "imap_password", "hmac_secret", "snipe_url", "snipe_token")
    for name in required:
        require_text(config.get(name), name)
    config.setdefault("imap_port", 993)
    config.setdefault("product_name", "SnipeIT Inventory")
    config.setdefault("mail_subject_prefix", "[SNIPEIT-INVENTORY]")
    config.setdefault("imap_parent_folder", "SnipeIT Inventory")
    config.setdefault("imap_folder", "Offline Relay")
    config.setdefault("inbox_folder", "INBOX")
    config.setdefault("processed_folder", "Processed Events")
    config.setdefault("rejected_folder", "Rejected Events")
    config.setdefault("weekly_reports_folder", "! Weekly Reports")
    config.setdefault("reports_folder", config.get("inventory_folder") or "Reports")
    config.setdefault("alerts_folder", "Alerts")
    config.setdefault("warnings_folder", "Warnings")
    config.setdefault("errors_folder", "Errors")

    canonical_folders = {
        "imap_folder": ("Offline Relay", {"relay", "snipeit relay"}),
        "processed_folder": ("Processed Events", {"processed", "snipeit processed"}),
        "rejected_folder": ("Rejected Events", {"rejected", "snipeit rejected"}),
        "weekly_reports_folder": ("! Weekly Reports", {"weekly reports"}),
        "reports_folder": ("Reports", {"inventory"}),
        "alerts_folder": ("Alerts", set()),
        "warnings_folder": ("Warnings", set()),
        "errors_folder": ("Errors", {"inventory reports", "snipeit error/warn"}),
    }
    for key, (canonical, legacy_names) in canonical_folders.items():
        current = str(config.get(key) or "").strip()
        if not current or current.casefold() in legacy_names:
            config[key] = canonical
    # Keep the old property names available to callers during the transition.
    config["inventory_folder"] = config["reports_folder"]
    config["inventory_reports_folder"] = config["errors_folder"]
    config.setdefault("create_imap_folders", True)
    config.setdefault("migrate_legacy_folders", True)
    config.setdefault("delete_empty_legacy_folders", True)
    config.setdefault("legacy_imap_parent_folders", ["SNIPEIT Autoinv", "SNIPEIT Inventory"])
    config.setdefault("legacy_relay_folders", ["Relay", "SnipeIT Relay"])
    config.setdefault("legacy_processed_folders", ["Processed", "SnipeIT Processed"])
    config.setdefault("legacy_rejected_folders", ["Rejected", "SnipeIT Rejected"])
    config.setdefault("legacy_weekly_reports_folders", ["Weekly Reports"])
    config.setdefault("legacy_reports_folders", ["Inventory"])
    config.setdefault("legacy_warning_folders", [])
    config.setdefault(
        "legacy_error_folders",
        ["Inventory Reports", "SnipeIT ERROR/WARN"],
    )
    config.setdefault("legacy_root_error_folders", ["SNIPEIT Inventory"])
    legacy_lists = {
        "legacy_relay_folders": ["Relay", "SnipeIT Relay"],
        "legacy_processed_folders": ["Processed", "SnipeIT Processed"],
        "legacy_rejected_folders": ["Rejected", "SnipeIT Rejected"],
        "legacy_weekly_reports_folders": ["Weekly Reports"],
        "legacy_reports_folders": ["Inventory"],
        "legacy_error_folders": ["Inventory Reports", "SnipeIT ERROR/WARN"],
        "legacy_root_error_folders": ["SNIPEIT Inventory"],
    }
    for key, defaults in legacy_lists.items():
        config[key] = text_list(text_list(config.get(key)) + defaults)
    config.setdefault("legacy_migration_max_messages_per_run", 1000)
    config.setdefault("imap_timeout_seconds", 30)
    config.setdefault("imap_command_retries", 3)
    config.setdefault("imap_retry_delay_seconds", 1)
    config.setdefault("max_messages_per_run", 200)
    config.setdefault("allowed_from", [config["imap_user"]])
    config.setdefault("sort_human_reports", True)
    # Yandex IMAP returns no matches for SUBJECT searches that begin with an
    # opening square bracket even though the same message is found without it.
    # Search broadly here and keep the exact prefix/sender checks after FETCH.
    config["human_report_search_terms"] = text_list(
        [
            item
            for item in text_list(config.get("human_report_search_terms"))
            if not item.startswith("[")
        ]
        + ["SNIPEIT-INVENTORY", "PCINV", "PC Inventory"]
    )
    config.setdefault("report_subject_prefix", "[SNIPEIT-INVENTORY] REPORT:")
    config.setdefault("legacy_report_subject_prefixes", ["[PCINV-REPORT]"])
    config["weekly_report_subject_prefixes"] = text_list(
        text_list(config.get("weekly_report_subject_prefixes"))
        + [
            "[SNIPEIT-INVENTORY] REPORT: WEEKLY:",
            "[SNIPEIT-INVENTORY] ALERT: WEEKLY:",
            "[PCINV-REPORT] WEEKLY:",
            "[PCINV-ALERT] WEEKLY:",
            "[PCINV-ALERT] WATCHDOG:",
        ]
    )
    config["weekly_report_search_terms"] = text_list(
        text_list(config.get("weekly_report_search_terms"))
        + ["WEEKLY", "WATCHDOG"]
    )
    config.setdefault("warning_subject_prefix", "[SNIPEIT-INVENTORY] WARNING:")
    config.setdefault(
        "legacy_warning_subject_prefixes",
        [
            "[SNIPEIT-INVENTORY] REPORT: WARNING:",
            "[PCINV-REPORT] WARNING:",
            "PC Inventory WARNING",
        ],
    )
    config.setdefault("error_subject_prefix", "[SNIPEIT-INVENTORY] ERROR:")
    config.setdefault("human_alert_subject_prefix", "[SNIPEIT-INVENTORY] ALERT:")
    config.setdefault("human_alert_subject_prefixes", ["[PCINV-ALERT]"])
    config.setdefault(
        "legacy_error_subject_prefixes",
        [
            "PC Inventory ERROR",
        ],
    )
    config["legacy_warning_subject_prefixes"] = text_list(
        text_list(config.get("legacy_warning_subject_prefixes"))
        + [
            "[SNIPEIT-INVENTORY] REPORT: WARNING:",
            "[PCINV-REPORT] WARNING:",
            "PC Inventory WARNING",
        ]
    )
    config["legacy_error_subject_prefixes"] = text_list(
        text_list(config.get("legacy_error_subject_prefixes"))
        + ["PC Inventory ERROR"]
    )
    config.setdefault("report_allowed_from", config["allowed_from"])
    config.setdefault("subject_prefix", "[SNIPEIT-INVENTORY] RELAY:")
    config.setdefault("legacy_relay_subject_prefixes", ["[SNIPEIT-RELAY]"])
    config["relay_search_terms"] = text_list(
        [
            item
            for item in text_list(config.get("relay_search_terms"))
            if not item.startswith("[")
        ]
        # Yandex intermittently returns no matches for punctuation-heavy
        # searches such as SNIPEIT-RELAY or RELAY:. Keep broad terms and
        # confirm the exact subject/header locally after FETCH.
        + ["SNIPEIT", "RELAY"]
    )
    config.setdefault("verify_tls", False)
    config.setdefault("snipe_host_header", "")
    config.setdefault("api_timeout_seconds", 30)
    config.setdefault("max_message_bytes", 2 * 1024 * 1024)
    config.setdefault("stale_grace_seconds", 5)
    config.setdefault("display_timezone", "Europe/Moscow")
    config.setdefault("database_path", "/var/lib/snipeit-mail-relay/events.sqlite3")
    config.setdefault("log_path", "/var/log/snipeit-mail-relay/relay.log")
    config.setdefault("default_status_id", 8)
    config.setdefault("stock_status_id", 1)
    config.setdefault("default_category_id", 1)
    config.setdefault("default_manufacturer_id", 1)
    config.setdefault("default_fieldset_id", 2)
    config.setdefault("custom_fields", {})
    config.setdefault("ldap_sync_command", [])
    config.setdefault("ldap_sync_cwd", "/var/www/snipe-it")
    config.setdefault("smtp_host", "")
    config.setdefault("smtp_port", 587)
    config.setdefault("smtp_user", "")
    config.setdefault("smtp_password", "")
    config.setdefault("smtp_starttls", True)
    config.setdefault("smtp_ssl", False)
    config.setdefault("smtp_timeout_seconds", 30)
    config.setdefault("alert_mail_to", "")
    config.setdefault("alert_subject_prefix", config["error_subject_prefix"])
    if str(config.get("alert_subject_prefix") or "").strip() in {
        "[SNIPEIT-INVENTORY] ALERT:",
        "[PCINV-ALERT]",
    }:
        config["alert_subject_prefix"] = config["error_subject_prefix"]
    config.setdefault("alert_after_hours", 24)
    config.setdefault("cleanup_interval_hours", 24)
    config.setdefault("processed_retention_days", 30)
    config.setdefault("rejected_retention_days", 60)
    config.setdefault("weekly_reports_retention_days", 365)
    config.setdefault("reports_retention_days", config.get("inventory_retention_days", 180))
    config.setdefault("alerts_retention_days", 365)
    config.setdefault("warnings_retention_days", 180)
    config.setdefault(
        "errors_retention_days",
        config.get("alerts_retention_days", config.get("inventory_reports_retention_days", 365)),
    )
    config.setdefault("database_retention_days", 365)
    config.setdefault("cleanup_max_messages_per_folder", 1000)
    return config


def configure_logging(path: str, verbose: bool = False) -> None:
    handlers: List[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    if path:
        log_path = Path(path)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.FileHandler(log_path, encoding="utf-8"))
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=handlers,
    )


class EventStore:
    def __init__(self, path: str) -> None:
        db_path = Path(path)
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(str(db_path), timeout=30)
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA synchronous=NORMAL")
        self.connection.execute("PRAGMA busy_timeout=30000")
        self.connection.execute(
            """
            CREATE TABLE IF NOT EXISTS relay_events (
                event_id TEXT PRIMARY KEY,
                computer_name TEXT NOT NULL,
                observed_at TEXT NOT NULL,
                status TEXT NOT NULL,
                asset_id INTEGER,
                result TEXT,
                updated_at TEXT NOT NULL,
                first_seen_at TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                alert_sent_at TEXT,
                source_uid TEXT,
                message_id TEXT
            )
            """
        )
        self.connection.execute(
            """
            CREATE TABLE IF NOT EXISTS relay_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )
        self._ensure_column("first_seen_at", "TEXT")
        self._ensure_column("attempts", "INTEGER NOT NULL DEFAULT 0")
        self._ensure_column("alert_sent_at", "TEXT")
        self._ensure_column("source_uid", "TEXT")
        self._ensure_column("message_id", "TEXT")
        self.connection.execute(
            """
            UPDATE relay_events
            SET first_seen_at = COALESCE(NULLIF(first_seen_at, ''), updated_at)
            WHERE first_seen_at IS NULL OR first_seen_at = ''
            """
        )
        self.connection.commit()

    def _ensure_column(self, name: str, definition: str) -> None:
        columns = {
            str(row[1]).lower()
            for row in self.connection.execute("PRAGMA table_info(relay_events)").fetchall()
        }
        if name.lower() not in columns:
            self.connection.execute(
                f"ALTER TABLE relay_events ADD COLUMN {name} {definition}"
            )

    def close(self) -> None:
        self.connection.close()

    def completed(self, event_id: str) -> bool:
        row = self.connection.execute(
            "SELECT status FROM relay_events WHERE event_id = ?", (event_id,)
        ).fetchone()
        return bool(row and row[0] in ("processed", "stale", "duplicate", "ignored"))

    def mark(
        self,
        event_id: str,
        computer_name: str,
        observed_at: str,
        status: str,
        result: str,
        asset_id: Optional[int] = None,
        source_uid: str = "",
        message_id: str = "",
    ) -> None:
        now = utc_now().isoformat()
        attempt_increment = 1 if status == "processing" else 0
        self.connection.execute(
            """
            INSERT INTO relay_events(
                event_id, computer_name, observed_at, status, asset_id, result,
                updated_at, first_seen_at, attempts, source_uid, message_id
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(event_id) DO UPDATE SET
                status = excluded.status,
                asset_id = excluded.asset_id,
                result = excluded.result,
                updated_at = excluded.updated_at,
                attempts = relay_events.attempts + excluded.attempts,
                source_uid = COALESCE(NULLIF(excluded.source_uid, ''), relay_events.source_uid),
                message_id = COALESCE(NULLIF(excluded.message_id, ''), relay_events.message_id)
            """,
            (
                event_id,
                computer_name,
                observed_at,
                status,
                asset_id,
                result[:4000],
                now,
                now,
                attempt_increment,
                source_uid,
                message_id,
            ),
        )
        self.connection.commit()

    def alerts_due(self, cutoff: dt.datetime) -> List[Dict[str, Any]]:
        rows = self.connection.execute(
            """
            SELECT event_id, computer_name, observed_at, status, result,
                   first_seen_at, attempts
            FROM relay_events
            WHERE status = 'failed'
              AND alert_sent_at IS NULL
              AND first_seen_at <= ?
            ORDER BY first_seen_at
            """,
            (cutoff.astimezone(dt.timezone.utc).isoformat(),),
        ).fetchall()
        names = (
            "event_id",
            "computer_name",
            "observed_at",
            "status",
            "result",
            "first_seen_at",
            "attempts",
        )
        return [dict(zip(names, row)) for row in rows]

    def mark_alert_sent(self, event_id: str) -> None:
        self.connection.execute(
            "UPDATE relay_events SET alert_sent_at = ?, updated_at = ? WHERE event_id = ?",
            (utc_now().isoformat(), utc_now().isoformat(), event_id),
        )
        self.connection.commit()

    def cleanup_due(self, interval_hours: int, now: Optional[dt.datetime] = None) -> bool:
        if interval_hours <= 0:
            return False
        current = now or utc_now()
        row = self.connection.execute(
            "SELECT value FROM relay_meta WHERE key = 'last_cleanup_at'"
        ).fetchone()
        if not row:
            return True
        last_cleanup = parse_datetime(row[0])
        return last_cleanup is None or current - last_cleanup >= dt.timedelta(hours=interval_hours)

    def mark_cleanup(self, now: Optional[dt.datetime] = None) -> None:
        timestamp = (now or utc_now()).astimezone(dt.timezone.utc).isoformat()
        self.connection.execute(
            """
            INSERT INTO relay_meta(key, value) VALUES('last_cleanup_at', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            (timestamp,),
        )
        self.connection.commit()

    def cleanup(self, retention_days: int, now: Optional[dt.datetime] = None) -> int:
        if retention_days <= 0:
            return 0
        cutoff = (now or utc_now()) - dt.timedelta(days=retention_days)
        cursor = self.connection.execute(
            """
            DELETE FROM relay_events
            WHERE updated_at < ?
              AND (
                    status IN ('processed', 'stale', 'duplicate', 'ignored')
                    OR (status = 'failed' AND alert_sent_at IS NOT NULL)
                  )
            """,
            (cutoff.astimezone(dt.timezone.utc).isoformat(),),
        )
        removed = max(0, int(cursor.rowcount or 0))
        self.connection.commit()
        if removed:
            self.connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            self.connection.execute("VACUUM")
        return removed


def send_alert(config: Dict[str, Any], event: Dict[str, Any]) -> None:
    host = str(config.get("smtp_host") or "").strip()
    user = str(config.get("smtp_user") or "").strip()
    password = str(config.get("smtp_password") or "")
    recipient = str(config.get("alert_mail_to") or "").strip()
    if not all((host, user, password, recipient)):
        raise RelayError("SMTP alert settings are incomplete")

    message = EmailMessage()
    message["From"] = user
    message["To"] = recipient
    message["Subject"] = (
        f"{config['alert_subject_prefix']} "
        f"RELAY FAILED 24H: {event['computer_name']}"
    )
    message.set_content(
        "\n".join(
            (
                "SnipeIT Inventory relay event requires attention.",
                "",
                f"Computer: {event['computer_name']}",
                f"Event ID: {event['event_id']}",
                f"Observed at: {event['observed_at']}",
                f"First seen: {event['first_seen_at']}",
                f"Attempts: {event['attempts']}",
                f"Status: {event['status']}",
                f"Last error: {event['result']}",
            )
        )
    )

    timeout = int(config.get("smtp_timeout_seconds") or 30)
    port = int(config.get("smtp_port") or 587)
    context = ssl.create_default_context()
    if bool(config.get("smtp_ssl")):
        client: Any = smtplib.SMTP_SSL(host, port, timeout=timeout, context=context)
    else:
        client = smtplib.SMTP(host, port, timeout=timeout)
    try:
        client.ehlo()
        if bool(config.get("smtp_starttls")) and not bool(config.get("smtp_ssl")):
            client.starttls(context=context)
            client.ehlo()
        client.login(user, password)
        client.send_message(message)
    finally:
        try:
            client.quit()
        except Exception:
            client.close()


def send_due_alerts(
    config: Dict[str, Any],
    store: EventStore,
    dry_run: bool = False,
) -> int:
    hours = int(config.get("alert_after_hours") or 0)
    if hours <= 0:
        return 0
    if not str(config.get("alert_mail_to") or "").strip():
        return 0
    cutoff = utc_now() - dt.timedelta(hours=hours)
    failures = 0
    for event in store.alerts_due(cutoff):
        try:
            if dry_run:
                LOGGER.info(
                    "DRY RUN: Would send alert for event_id=%s computer=%s",
                    event["event_id"],
                    event["computer_name"],
                )
                continue
            send_alert(config, event)
            store.mark_alert_sent(str(event["event_id"]))
            LOGGER.warning(
                "Sent delayed relay alert event_id=%s computer=%s",
                event["event_id"],
                event["computer_name"],
            )
        except Exception as exc:
            failures += 1
            LOGGER.exception(
                "Could not send delayed relay alert event_id=%s: %s",
                event["event_id"],
                exc,
            )
    return failures


class SnipeApi:
    def __init__(self, config: Dict[str, Any], dry_run: bool = False) -> None:
        self.base_url = str(config["snipe_url"]).rstrip("/")
        self.token = str(config["snipe_token"])
        self.timeout = int(config["api_timeout_seconds"])
        self.verify_tls = bool(config["verify_tls"])
        self.dry_run = dry_run
        self.config = config

    def request(
        self,
        method: str,
        path: str,
        body: Optional[Dict[str, Any]] = None,
        form: bool = False,
    ) -> Any:
        method = method.upper()
        if self.dry_run and method != "GET":
            LOGGER.info("DRY RUN: Would %s %s body=%s", method, path, body)
            return {"status": "success", "dry_run": True, "payload": {"id": -1}}
        data = None
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
            "User-Agent": f"SnipeIT-Inventory-Relay/{RELAY_VERSION}",
        }
        if str(self.config.get("snipe_host_header") or "").strip():
            headers["Host"] = str(self.config["snipe_host_header"]).strip()
        if body is not None:
            if form:
                data = urllib.parse.urlencode({k: str(v) for k, v in body.items()}).encode("utf-8")
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                data = json.dumps(body, ensure_ascii=False).encode("utf-8")
                headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers, method=method)
        context = None
        if self.base_url.lower().startswith("https") and not self.verify_tls:
            context = ssl._create_unverified_context()
        try:
            with urllib.request.urlopen(request, timeout=self.timeout, context=context) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            response_text = exc.read().decode("utf-8", errors="replace")
            error = f"Snipe API HTTP {exc.code} {method} {path}: {response_text[:1000]}"
            if exc.code in (408, 429) or exc.code >= 500:
                raise TransientRelayError(error) from exc
            raise RelayError(error) from exc
        except urllib.error.URLError as exc:
            raise TransientRelayError(f"Snipe API transport error {method} {path}: {exc}") from exc
        if not raw:
            return None
        result = json.loads(raw.decode("utf-8-sig"))
        if isinstance(result, dict) and str(result.get("status", "")).lower() == "error":
            raise RelayError(f"Snipe API error {method} {path}: {result.get('messages') or result}")
        return result

    @staticmethod
    def rows(response: Any) -> List[Dict[str, Any]]:
        if response is None:
            return []
        if isinstance(response, list):
            return response
        if isinstance(response, dict) and isinstance(response.get("rows"), list):
            return response["rows"]
        return [response] if isinstance(response, dict) else []

    @staticmethod
    def payload(response: Any) -> Any:
        if isinstance(response, dict) and response.get("payload") is not None:
            return response["payload"]
        return response

    def find_user(self, username: str) -> Optional[Dict[str, Any]]:
        if not username:
            return None
        path = "/api/v1/users?" + urllib.parse.urlencode({"search": username, "limit": 50})
        rows = self.rows(self.request("GET", path))
        username_lower = username.strip().lower()
        for row in rows:
            active = row.get("activated", row.get("active", True))
            if str(active).lower() in ("0", "false", "no"):
                continue
            names = (row.get("username"), row.get("employee_num"))
            if any(str(item or "").strip().lower() == username_lower for item in names):
                return row
        return None

    def run_ldap_sync(self) -> None:
        command = self.config.get("ldap_sync_command") or []
        if not command or self.dry_run:
            return
        LOGGER.info("Running LDAP sync before the second user lookup")
        completed = subprocess.run(
            [str(part) for part in command],
            cwd=str(self.config.get("ldap_sync_cwd") or "/var/www/snipe-it"),
            timeout=180,
            check=False,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            LOGGER.warning(
                "LDAP sync failed rc=%s: %s",
                completed.returncode,
                (completed.stderr or completed.stdout)[-2000:],
            )

    def find_asset(self, serial: str, computer_name: str) -> Optional[Dict[str, Any]]:
        for value, keys in ((serial, ("serial",)), (computer_name, ("name", "asset_tag"))):
            if not value:
                continue
            path = "/api/v1/hardware?" + urllib.parse.urlencode({"search": value, "limit": 50})
            for row in self.rows(self.request("GET", path)):
                for key in keys:
                    if str(row.get(key) or "").strip().lower() == value.strip().lower():
                        return row
        return None

    def get_asset(self, asset_id: int) -> Dict[str, Any]:
        return self.payload(self.request("GET", f"/api/v1/hardware/{asset_id}")) or {}

    def manufacturer_id(self, name: str) -> int:
        if not name:
            return int(self.config["default_manufacturer_id"])
        path = "/api/v1/manufacturers?" + urllib.parse.urlencode({"search": name, "limit": 50})
        for row in self.rows(self.request("GET", path)):
            if str(row.get("name") or "").strip().lower() == name.strip().lower():
                return int(row["id"])
        created = self.payload(self.request("POST", "/api/v1/manufacturers", {"name": name}))
        return int((created or {}).get("id") or self.config["default_manufacturer_id"])

    def model_id(self, model: str, manufacturer: str) -> int:
        model = model or "Unknown model"
        path = "/api/v1/models?" + urllib.parse.urlencode({"search": model, "limit": 50})
        for row in self.rows(self.request("GET", path)):
            if str(row.get("name") or "").strip().lower() == model.strip().lower():
                model_id = int(row["id"])
                self.ensure_model_fieldset(model_id)
                return model_id
        body = {
            "name": model,
            "category_id": int(self.config["default_category_id"]),
            "manufacturer_id": self.manufacturer_id(manufacturer),
            "model_number": model,
            "fieldset_id": int(self.config["default_fieldset_id"]),
        }
        created = self.payload(self.request("POST", "/api/v1/models", body)) or {}
        model_id = int(created.get("id") or -1)
        if model_id <= 0 and not self.dry_run:
            raise RelayError(f"Model was created without an id: {model}")
        return model_id

    def ensure_model_fieldset(self, model_id: int) -> None:
        fieldset = int(self.config.get("default_fieldset_id") or 0)
        if fieldset <= 0:
            return
        try:
            self.request("PATCH", f"/api/v1/models/{model_id}", {"fieldset_id": fieldset})
        except RelayError as exc:
            LOGGER.warning("Could not set fieldset on model %s: %s", model_id, exc)


def assigned_user_id(asset: Dict[str, Any]) -> Optional[int]:
    for name in ("assigned_to", "assigned_user", "assigned_to_user", "user"):
        value = asset.get(name)
        if isinstance(value, dict) and value.get("id"):
            return int(value["id"])
    for name in ("assigned_to_id", "assigned_user_id"):
        if asset.get(name):
            return int(asset[name])
    return None


def asset_status_id(asset: Dict[str, Any]) -> Optional[int]:
    for name in ("status_label", "status"):
        value = asset.get(name)
        if isinstance(value, dict) and value.get("id"):
            return int(value["id"])
    return int(asset["status_id"]) if asset.get("status_id") else None


def extract_asset_latest_time(
    asset: Dict[str, Any],
    last_success_field: str,
    display_timezone: str = "Europe/Moscow",
) -> Optional[dt.datetime]:
    inventory_times: List[dt.datetime] = []
    notes = str(asset.get("notes") or "")
    for line in notes.splitlines():
        marker = re.match(r"^(?:Inventory timestamp|Observed|Updated):\s*(.+)$", line.strip(), re.IGNORECASE)
        if marker:
            parsed = parse_datetime(marker.group(1))
            if not parsed:
                parsed = parse_inventory_display_time(marker.group(1), display_timezone)
            if parsed:
                inventory_times.append(parsed)

    custom_fields = asset.get("custom_fields")
    if isinstance(custom_fields, dict):
        for key, item in custom_fields.items():
            item_field = item.get("field") if isinstance(item, dict) else ""
            item_value = item.get("value") if isinstance(item, dict) else item
            if key == last_success_field or item_field == last_success_field or "last successful" in key.lower():
                parsed = parse_datetime(item_value)
                if not parsed:
                    parsed = parse_inventory_display_time(item_value, display_timezone)
                if parsed:
                    inventory_times.append(parsed)

    # A relay PUT changes updated_at before checkout/checkin has necessarily
    # completed. Prefer the inventory timestamp so a retry can finish safely.
    if inventory_times:
        return max(inventory_times)
    return parse_datetime(asset.get("updated_at"))


def validate_payload(payload: Dict[str, Any]) -> None:
    if payload.get("payload_schema") != "snipeit.inventory.payload/v1":
        raise RelayError("Unsupported payload_schema")
    if int(payload.get("schema_version") or 0) != 1:
        raise RelayError("Unsupported payload schema_version")
    if str(payload.get("snipeit_avail") or "").lower() != "no":
        raise RelayError("Relay payload must contain snipeit_avail=no")
    require_text(payload.get("event_id"), "event_id", 128)
    require_text(payload.get("computer_name"), "computer_name", 255)
    require_text(payload.get("observed_at"), "observed_at", 128)
    if parse_datetime(payload.get("observed_at")) is None:
        raise RelayError("observed_at is invalid")
    if not isinstance(payload.get("hardware"), dict):
        raise RelayError("hardware object is missing")
    if not isinstance(payload.get("identity"), dict):
        raise RelayError("identity object is missing")
    if not isinstance(payload.get("disposition"), dict):
        raise RelayError("disposition object is missing")


def decode_envelope(envelope_text: str, secret: str) -> Dict[str, Any]:
    envelope = json.loads(envelope_text.lstrip("\ufeff"))
    if envelope.get("envelope_schema") != "snipeit.inventory.relay/v1":
        raise RelayError("Unsupported envelope_schema")
    if int(envelope.get("schema_version") or 0) != 1:
        raise RelayError("Unsupported envelope schema_version")
    try:
        payload_bytes = base64.b64decode(str(envelope["payload"]), validate=True)
    except Exception as exc:
        raise RelayError("Invalid base64 payload") from exc
    expected = hmac.new(secret.encode("utf-8"), payload_bytes, hashlib.sha256).hexdigest()
    supplied = str(envelope.get("hmac_sha256") or "").lower()
    if not hmac.compare_digest(expected, supplied):
        raise RelayError("HMAC verification failed")
    payload = json.loads(payload_bytes.decode("utf-8-sig"))
    validate_payload(payload)
    return payload


def relay_attachment(message: Message) -> str:
    for part in message.walk():
        filename = str(part.get_filename() or "")
        if filename.lower().endswith(".snipeit-relay.json"):
            content = part.get_payload(decode=True)
            if content is None:
                raise RelayError("Relay attachment is empty")
            return content.decode("utf-8-sig")
    raise RelayError("Relay JSON attachment was not found")


def normalize_header_token(value: Any) -> str:
    return "".join(str(value or "").split())


def normalize_os_summary(
    value: Any,
    os_name: Any = "",
    os_build: Any = "",
) -> str:
    text = re.sub(r"\s+", " ", str(value or os_name or "")).strip()
    windows_at = text.lower().find("windows")
    if windows_at > 0:
        text = text[windows_at:]
    text = re.sub(r"[^\x20-\x7e]", " ", text)
    text = re.sub(r"\?+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    build = str(os_build or "").strip()
    if build and text and not re.search(r"\bbuild\s+\d+", text, re.IGNORECASE):
        text = f"{text} (build {build})"
    return text


def build_notes(
    payload: Dict[str, Any],
    effective_username: str,
    display_timezone: str = "Europe/Moscow",
) -> str:
    hardware = payload["hardware"]
    observed_display = format_inventory_notes_time(payload["observed_at"], display_timezone)
    os_summary = normalize_os_summary(
        hardware.get("os_summary"),
        hardware.get("os_name"),
        hardware.get("os_build"),
    )
    return "\n".join(
        (
            "Auto inventory by SnipeIT Inventory Relay",
            f"Observed: {observed_display}",
            f"Computer: {payload['computer_name']}",
            f"Serial: {payload.get('serial_number') or ''}",
            f"Manufacturer: {hardware.get('manufacturer') or ''}",
            f"Model: {hardware.get('model') or ''}",
            f"CPU: {hardware.get('cpu_summary') or hardware.get('cpu_name') or ''}",
            f"RAM: {hardware.get('ram_summary') or ''}",
            f"OS: {os_summary}",
            f"Storage: {hardware.get('storage_summary') or ''}",
            f"Detected user: {effective_username}",
            f"Relay event: {payload['event_id']}",
        )
    )


def apply_payload(api: SnipeApi, payload: Dict[str, Any]) -> Tuple[str, Optional[int]]:
    invalid_reason = invalid_identity_payload_reason(payload)
    if invalid_reason:
        raise IgnoredEvent(invalid_reason)

    config = api.config
    computer_name = require_text(payload.get("computer_name"), "computer_name", 255)
    serial = str(payload.get("serial_number") or "").strip()
    observed_at = parse_datetime(payload["observed_at"])
    assert observed_at is not None
    hardware = payload["hardware"]
    identity = payload["identity"]
    disposition = payload["disposition"]
    requested_disposition = str(disposition.get("requested") or "assigned").lower()
    if requested_disposition not in {"assigned", "stock", "preserve"}:
        raise RelayError(f"Unsupported disposition: {requested_disposition}")
    disposition_reason = str(disposition.get("reason") or "mail_relay")

    asset = api.find_asset(serial, computer_name)
    custom_fields = config.get("custom_fields") or {}
    last_success_field = str(custom_fields.get("last_success") or "")
    if asset:
        fresh_asset = api.get_asset(int(asset["id"]))
        latest = extract_asset_latest_time(
            fresh_asset,
            last_success_field,
            str(config.get("display_timezone") or "Europe/Moscow"),
        )
        grace = dt.timedelta(seconds=int(config.get("stale_grace_seconds") or 0))
        if latest and latest > observed_at + grace:
            raise StaleEvent(
                f"Payload observed_at={observed_at.isoformat()} is older than asset update={latest.isoformat()}"
            )
        asset = fresh_asset

    username = str(identity.get("detected_username") or "").strip()
    user = None
    effective_disposition = requested_disposition
    effective_reason = disposition_reason
    if effective_disposition == "assigned" and username:
        user = api.find_user(username)
        if not user:
            api.run_ldap_sync()
            user = api.find_user(username)
        if not user:
            effective_disposition = "stock"
            effective_reason = f"snipe_user_missing:{username}"
    elif effective_disposition == "assigned":
        raise IgnoredEvent("assigned_identity_empty")

    model_id = api.model_id(str(hardware.get("model") or "Unknown model"), str(hardware.get("manufacturer") or ""))
    if effective_disposition == "assigned":
        effective_username = username
    elif effective_disposition == "preserve":
        effective_username = "PRESERVE CURRENT ASSIGNMENT"
    else:
        effective_username = f"UNASSIGNED ({effective_reason})"
    body: Dict[str, Any] = {
        "name": computer_name,
        "serial": serial,
        "model_id": model_id,
        "notes": build_notes(
            payload,
            effective_username,
            str(config.get("display_timezone") or "Europe/Moscow"),
        ),
    }
    field_values = {
        "ram": hardware.get("ram_summary") or "",
        "cpu": hardware.get("cpu_summary") or hardware.get("cpu_name") or "",
        "os": normalize_os_summary(
            hardware.get("os_summary"),
            hardware.get("os_name"),
            hardware.get("os_build"),
        ),
        "storage": hardware.get("storage_summary") or "",
        "agent_version": payload.get("agent_version") or "",
        "last_success": format_inventory_display_time(
            payload.get("observed_at"),
            str(config.get("display_timezone") or "Europe/Moscow"),
        ),
        "last_error": "" if effective_disposition in {"assigned", "preserve"} else effective_reason,
    }
    for logical_name, value in field_values.items():
        field = str(custom_fields.get(logical_name) or "")
        if field:
            body[field] = value

    if asset:
        asset_id = int(asset["id"])
        api.request("PUT", f"/api/v1/hardware/{asset_id}", body)
    else:
        create_body = dict(body)
        create_body["status_id"] = int(
            config["stock_status_id"] if effective_disposition in {"stock", "preserve"} else config["default_status_id"]
        )
        created = api.payload(api.request("POST", "/api/v1/hardware", create_body)) or {}
        asset_id = int(created.get("id") or -1)
        if asset_id <= 0 and not api.dry_run:
            raise RelayError("Asset was created without an id")

    fresh = api.get_asset(asset_id) if asset_id > 0 else {}
    assigned_id = assigned_user_id(fresh)
    if effective_disposition == "stock":
        if assigned_id:
            api.request(
                "POST",
                f"/api/v1/hardware/{asset_id}/checkin",
                {"note": f"SnipeIT Inventory Relay checkin to stock. Reason: {effective_reason}"},
            )
        if asset_status_id(fresh) != int(config["stock_status_id"]):
            api.request("PATCH", f"/api/v1/hardware/{asset_id}", {"status_id": int(config["stock_status_id"])})
        return f"stock:{effective_reason}", asset_id

    if effective_disposition == "preserve":
        return "preserve:identity_unresolved", asset_id

    target_user_id = int(user["id"])
    if assigned_id != target_user_id:
        if assigned_id:
            api.request(
                "POST",
                f"/api/v1/hardware/{asset_id}/checkin",
                {"note": f"SnipeIT Inventory Relay checkin before reassignment to {username}"},
            )
        api.request(
            "POST",
            f"/api/v1/hardware/{asset_id}/checkout",
            {
                "checkout_to_type": "user",
                "assigned_user": target_user_id,
                "note": f"SnipeIT Inventory Relay checkout. Computer: {computer_name}. User: {username}",
            },
            form=True,
        )
    if asset_status_id(fresh) != int(config["default_status_id"]):
        api.request("PATCH", f"/api/v1/hardware/{asset_id}", {"status_id": int(config["default_status_id"])})
    return f"assigned:{username}", asset_id


_IMAP_LIST_RE = re.compile(
    r'^\((?P<flags>[^)]*)\)\s+(?P<delimiter>NIL|"(?:\\.|[^"])*")\s+(?P<name>.+)$'
)


def _imap_unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
        value = value[1:-1]
        value = value.replace(r"\\", "\\").replace(r"\"", '"')
    return value


def _imap_quote(value: str) -> str:
    escaped = value.replace("\\", r"\\").replace('"', r"\"")
    return f'"{escaped}"'


def parse_imap_list_line(raw: bytes) -> Tuple[str, str]:
    text = raw.decode("ascii", errors="replace")
    match = _IMAP_LIST_RE.match(text)
    if not match:
        raise RelayError(f"Cannot parse IMAP LIST response: {text}")
    delimiter_token = match.group("delimiter")
    delimiter = "" if delimiter_token.upper() == "NIL" else _imap_unquote(delimiter_token)
    return delimiter, _imap_unquote(match.group("name"))


class ImapMailbox:
    def __init__(self, config: Dict[str, Any]) -> None:
        self.config = config
        self.client = self.open_client()
        self.delimiter = "/"
        self.folders: Dict[str, str] = {}
        self.refresh_folders()

        parent = str(config.get("imap_parent_folder") or "").strip()
        create = bool(config.get("create_imap_folders"))
        if parent:
            parent = self.resolve_folder(parent, "", create=create)
        self.parent_folder = parent
        self.source_folder = self.resolve_folder(
            str(config["imap_folder"]), parent, create=create
        )
        self.inbox_folder = self.resolve_folder(
            str(config["inbox_folder"]), "", create=False
        )
        self.processed_folder = self.resolve_folder(
            str(config["processed_folder"]), parent, create=create
        )
        self.rejected_folder = self.resolve_folder(
            str(config["rejected_folder"]), parent, create=create
        )
        self.weekly_reports_folder = self.resolve_folder(
            str(config["weekly_reports_folder"]), parent, create=create
        )
        self.reports_folder = self.resolve_folder(
            str(config["reports_folder"]), parent, create=create
        )
        self.alerts_folder = self.resolve_folder(
            str(config["alerts_folder"]), parent, create=create
        )
        self.warnings_folder = self.resolve_folder(
            str(config["warnings_folder"]), parent, create=create
        )
        self.errors_folder = self.resolve_folder(
            str(config["errors_folder"]), parent, create=create
        )
        self.inventory_folder = self.reports_folder
        self.inventory_reports_folder = self.errors_folder

        self.selected_folder = ""
        self.select(self.source_folder)
        LOGGER.info(
            "SnipeIT Inventory folders inbox=%s weekly=%s offline_relay=%s processed=%s rejected=%s reports=%s alerts=%s warnings=%s errors=%s",
            self.inbox_folder,
            self.weekly_reports_folder,
            self.source_folder,
            self.processed_folder,
            self.rejected_folder,
            self.reports_folder,
            self.alerts_folder,
            self.warnings_folder,
            self.errors_folder,
        )

    def open_client(self) -> imaplib.IMAP4_SSL:
        client = imaplib.IMAP4_SSL(
            str(self.config["imap_host"]),
            int(self.config["imap_port"]),
            ssl_context=ssl.create_default_context(),
            timeout=int(self.config.get("imap_timeout_seconds") or 30),
        )
        client.login(str(self.config["imap_user"]), str(self.config["imap_password"]))
        return client

    def reconnect(self) -> None:
        try:
            self.client.close()
        except Exception:
            pass
        try:
            self.client.logout()
        except Exception:
            pass
        self.client = self.open_client()
        self.selected_folder = ""
        self.refresh_folders()

    def select(self, folder: str) -> None:
        status, _ = self.client.select(_imap_quote(folder), readonly=False)
        if status != "OK":
            raise RelayError(f"Cannot select IMAP folder {folder}")
        self.selected_folder = folder

    def refresh_folders(self) -> None:
        status, data = self.client.list()
        if status != "OK":
            raise RelayError("Cannot list IMAP folders")
        folders: Dict[str, str] = {}
        folder_names: List[str] = []
        delimiters: List[str] = []
        for item in data or []:
            if not isinstance(item, bytes) or not item.strip():
                continue
            delimiter, name = parse_imap_list_line(item)
            if delimiter:
                delimiters.append(delimiter)
            folder_names.append(name)
            folders[name.casefold()] = name
        if delimiters:
            self.delimiter = delimiters[0]
        self.folders = folders
        self.folder_names = folder_names

    def find_existing_folder(self, candidate: str) -> str:
        names = list(getattr(self, "folder_names", self.folders.values()))
        for name in names:
            if name == candidate:
                return name
        matches = [name for name in names if name.casefold() == candidate.casefold()]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise RelayError(f"IMAP folder name differs only by case and is ambiguous: {candidate}")
        return ""

    def resolve_folder(self, leaf: str, parent: str = "", create: bool = False) -> str:
        leaf = leaf.strip()
        if not leaf:
            raise RelayError("IMAP folder name is empty")

        candidates = [leaf]
        if parent:
            candidates.insert(0, f"{parent}{self.delimiter}{leaf}")
        for candidate in candidates:
            existing = self.find_existing_folder(candidate)
            if existing:
                return existing

        suffix = f"{self.delimiter}{leaf}".casefold()
        matches = [
            name
            for name in getattr(self, "folder_names", self.folders.values())
            if name.casefold().endswith(suffix)
        ]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise RelayError(f"IMAP folder name is ambiguous: {leaf}")
        if not create:
            raise RelayError(f"IMAP folder does not exist: {leaf}")

        target = candidates[0]
        status, _ = self.client.create(_imap_quote(target))
        if status != "OK":
            raise RelayError(f"Cannot create IMAP folder: {target}")
        self.refresh_folders()
        existing = self.find_existing_folder(target)
        if not existing:
            raise RelayError(f"IMAP folder was created but cannot be listed: {target}")
        LOGGER.info("Created IMAP folder: %s", existing)
        return existing

    def existing_folder(self, leaf: str, parent: str = "") -> str:
        leaf = str(leaf or "").strip()
        parent = str(parent or "").strip()
        if not leaf:
            return ""
        candidate = f"{parent}{self.delimiter}{leaf}" if parent else leaf
        return self.find_existing_folder(candidate)

    def existing_folder_exact(self, leaf: str, parent: str = "") -> str:
        leaf = str(leaf or "").strip()
        parent = str(parent or "").strip()
        if not leaf:
            return ""
        candidate = f"{parent}{self.delimiter}{leaf}" if parent else leaf
        for name in getattr(self, "folder_names", self.folders.values()):
            if name == candidate:
                return name
        return ""

    def delete_empty_folder(self, folder: str) -> bool:
        if self.search_uids("ALL", folder):
            return False
        child_prefix = f"{folder}{self.delimiter}"
        if any(
            name.startswith(child_prefix)
            for name in getattr(self, "folder_names", self.folders.values())
        ):
            LOGGER.info("Kept legacy IMAP parent with child folders: %s", folder)
            return False
        try:
            self.client.close()
        except Exception:
            pass
        status, _ = self.client.delete(_imap_quote(folder))
        if status != "OK":
            raise RelayError(f"Cannot delete empty legacy IMAP folder: {folder}")
        self.selected_folder = ""
        self.refresh_folders()
        LOGGER.info("Deleted empty legacy IMAP folder: %s", folder)
        return True

    def close(self) -> None:
        try:
            self.client.close()
        except Exception:
            pass
        try:
            self.client.logout()
        except Exception:
            pass

    def search_raw(self, criteria: str, folder: str = "") -> List[bytes]:
        target_folder = folder or getattr(self, "selected_folder", "")
        retries = max(1, int(self.config.get("imap_command_retries") or 3))
        delay = max(0.0, float(self.config.get("imap_retry_delay_seconds") or 1))
        last_error: Optional[BaseException] = None
        for attempt in range(1, retries + 1):
            try:
                if target_folder and target_folder != getattr(self, "selected_folder", ""):
                    self.select(target_folder)
                status, data = self.client.uid("search", None, criteria)
                if status == "OK":
                    return list((data[0] or b"").split())
                last_error = RelayError(f"IMAP returned {status}: {data!r}")
            except (imaplib.IMAP4.error, OSError, ssl.SSLError, RelayError) as exc:
                last_error = exc

            if attempt >= retries:
                break
            LOGGER.warning(
                "IMAP search attempt %d/%d failed in %s; reconnecting: %s",
                attempt,
                retries,
                target_folder or "<current>",
                last_error,
            )
            if delay:
                time.sleep(delay)
            self.reconnect()

        raise RelayError(
            f"IMAP search failed in {target_folder or getattr(self, 'selected_folder', '')} "
            f"after {retries} attempt(s): {last_error}"
        ) from last_error

    def search_uids(self, criteria: str, folder: str = "") -> List[bytes]:
        uids = self.search_raw(criteria, folder)
        uids.sort(key=lambda value: int(value), reverse=True)
        limit = max(1, int(self.config.get("max_messages_per_run") or 200))
        return uids[:limit]

    def relay_uids(self, folder: str = "") -> List[bytes]:
        search_terms = text_list(
            self.config.get("relay_search_terms")
            or ["SNIPEIT", "RELAY"]
        )
        uids = set()
        # The custom marker is the most reliable Yandex IMAP query and avoids
        # depending on punctuation in an encoded subject. Subject searches
        # remain as a compatibility fallback; every result is verified by
        # is_relay_candidate() before processing or moving the message.
        uids.update(self.search_uids('(HEADER X-SnipeIT-Relay "1")', folder))
        for term in search_terms:
            escaped_term = term.replace("\\", r"\\").replace('"', r'\"')
            uids.update(self.search_uids(f'(SUBJECT "{escaped_term}")', folder))
        ordered = sorted(uids, key=lambda value: int(value), reverse=True)
        limit = max(1, int(self.config.get("max_messages_per_run") or 200))
        return ordered[:limit]

    def relay_items(self) -> List[Tuple[str, bytes]]:
        items: List[Tuple[str, bytes]] = []
        for folder in dict.fromkeys((self.inbox_folder, self.source_folder)):
            if folder == self.source_folder and folder != self.inbox_folder:
                # Yandex IMAP can return no matches for SUBJECT searches after a
                # server-side rule moves the message. The staging folder is
                # scanned by UID and every message is still verified locally
                # by is_relay_candidate() before it can be processed or moved.
                uids = self.search_uids("ALL", folder)
            else:
                uids = self.relay_uids(folder)
            items.extend((folder, uid) for uid in uids)
        return items

    def fetch(self, uid: bytes, folder: str = "") -> bytes:
        if folder and folder != self.selected_folder:
            self.select(folder)
        status, data = self.client.uid("fetch", uid, "(BODY.PEEK[])")
        if status != "OK":
            raise RelayError(f"IMAP fetch failed for UID {uid.decode()}")
        for item in data:
            if isinstance(item, tuple) and isinstance(item[1], bytes):
                return item[1]
        raise RelayError(f"IMAP message body missing for UID {uid.decode()}")

    def move(self, uid: bytes, folder: str, source_folder: str = "") -> None:
        if source_folder and source_folder != self.selected_folder:
            self.select(source_folder)
        copy_status, _ = self.client.uid("copy", uid, _imap_quote(folder))
        if copy_status != "OK":
            raise RelayError(f"IMAP copy to {folder} failed for UID {uid.decode()}")
        store_status, _ = self.client.uid("store", uid, "+FLAGS", "(\\Seen \\Deleted)")
        if store_status != "OK":
            raise RelayError(f"IMAP delete flag failed for UID {uid.decode()}")
        self.client.expunge()

    def delete_before(self, folder: str, cutoff: dt.datetime, dry_run: bool = False) -> int:
        months = (
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        )
        cutoff_date = cutoff.astimezone(dt.timezone.utc).date()
        imap_date = f"{cutoff_date.day:02d}-{months[cutoff_date.month - 1]}-{cutoff_date.year:04d}"
        uids = self.search_raw(f"BEFORE {imap_date}", folder)
        limit = max(1, int(self.config.get("cleanup_max_messages_per_folder") or 1000))
        uids = uids[:limit]
        if dry_run:
            return len(uids)
        for uid in uids:
            store_status, _ = self.client.uid("store", uid, "+FLAGS.SILENT", "(\\Deleted)")
            if store_status != "OK":
                raise RelayError(f"IMAP retention delete flag failed for UID {uid.decode()}")
        if uids:
            self.client.expunge()
        return len(uids)


def migrate_legacy_folders(
    mailbox: ImapMailbox,
    config: Dict[str, Any],
    dry_run: bool = False,
) -> int:
    if not bool(config.get("migrate_legacy_folders")):
        return 0

    # Yandex allows folders that differ only by case. Preserve both exact parent
    # names during migration instead of case-folding them into one entry.
    parents: List[str] = []
    parent_values = text_list(config.get("legacy_imap_parent_folders"))
    parent_values.extend(text_list(config.get("imap_parent_folder")))
    for parent in parent_values:
        if parent and parent not in parents:
            parents.append(parent)
    warnings_folder = getattr(mailbox, "warnings_folder", mailbox.reports_folder)
    alerts_folder = getattr(mailbox, "alerts_folder", mailbox.reports_folder)
    legacy_errors_folder = getattr(mailbox, "inventory_reports_folder", mailbox.reports_folder)
    errors_folder = getattr(mailbox, "errors_folder", legacy_errors_folder)
    mappings = (
        ("legacy_relay_folders", mailbox.source_folder),
        ("legacy_processed_folders", mailbox.processed_folder),
        ("legacy_rejected_folders", mailbox.rejected_folder),
        (
            "legacy_weekly_reports_folders",
            getattr(mailbox, "weekly_reports_folder", mailbox.reports_folder),
        ),
        ("legacy_reports_folders", mailbox.reports_folder),
        ("legacy_warning_folders", warnings_folder),
        ("legacy_error_folders", errors_folder),
        ("legacy_alerts_folders", alerts_folder),
    )
    sources: List[Tuple[str, str]] = []
    seen_sources = set()
    for config_key, target in mappings:
        for parent in parents:
            for leaf in text_list(config.get(config_key)):
                source = mailbox.existing_folder(leaf, parent)
                key = source.casefold()
                if source and source != target and key not in seen_sources:
                    seen_sources.add(key)
                    sources.append((source, target))

    for leaf in text_list(config.get("legacy_root_error_folders")):
        exact_lookup = getattr(mailbox, "existing_folder_exact", mailbox.existing_folder)
        source = exact_lookup(leaf)
        key = source.casefold()
        if source and source != errors_folder and key not in seen_sources:
            seen_sources.add(key)
            sources.append((source, errors_folder))

    moved = 0
    migration_limit = max(1, int(config.get("legacy_migration_max_messages_per_run") or 1000))
    for source, target in sources:
        uids = mailbox.search_uids("ALL", source)[:migration_limit]
        for uid in uids:
            if dry_run:
                LOGGER.info(
                    "DRY RUN: Would migrate legacy UID=%s from %s to %s",
                    uid.decode(),
                    source,
                    target,
                )
            else:
                mailbox.move(uid, target, source_folder=source)
            moved += 1

        if (
            not dry_run
            and bool(config.get("delete_empty_legacy_folders"))
            and not mailbox.search_uids("ALL", source)
        ):
            mailbox.delete_empty_folder(source)

    if moved:
        LOGGER.info("Migrated %d message(s) from legacy SnipeIT Inventory folders", moved)
    return moved


def run_retention_cleanup(
    mailbox: ImapMailbox,
    store: EventStore,
    config: Dict[str, Any],
    dry_run: bool = False,
) -> int:
    interval_hours = int(config.get("cleanup_interval_hours") or 24)
    if not store.cleanup_due(interval_hours):
        return 0

    now = utc_now()
    reports_folder = getattr(mailbox, "reports_folder", mailbox.inventory_folder)
    weekly_reports_folder = getattr(mailbox, "weekly_reports_folder", reports_folder)
    alerts_folder = getattr(mailbox, "alerts_folder", "")
    warnings_folder = getattr(mailbox, "warnings_folder", "")
    legacy_errors_folder = getattr(mailbox, "inventory_reports_folder", "")
    errors_folder = getattr(mailbox, "errors_folder", legacy_errors_folder)
    policies = (
        (mailbox.processed_folder, int(config.get("processed_retention_days") or 0)),
        (mailbox.rejected_folder, int(config.get("rejected_retention_days") or 0)),
        (
            weekly_reports_folder,
            int(config.get("weekly_reports_retention_days") or 0),
        ),
        (reports_folder, int(config.get("reports_retention_days") or 0)),
        (alerts_folder, int(config.get("alerts_retention_days") or 0)),
        (
            warnings_folder,
            int(config.get("warnings_retention_days") or 0),
        ),
        (
            errors_folder,
            int(config.get("errors_retention_days") or config.get("alerts_retention_days") or 0),
        ),
    )
    removed_mail = 0
    seen_folders: set[str] = set()
    for folder, days in policies:
        if not folder or days <= 0 or folder.casefold() in seen_folders:
            continue
        seen_folders.add(folder.casefold())
        count = mailbox.delete_before(folder, now - dt.timedelta(days=days), dry_run=dry_run)
        removed_mail += count
        if count:
            prefix = "DRY RUN: Would remove" if dry_run else "Removed"
            LOGGER.info("%s %d old message(s) from %s", prefix, count, folder)

    removed_db = 0
    if not dry_run:
        removed_db = store.cleanup(int(config.get("database_retention_days") or 0), now=now)
        store.mark_cleanup(now)
    LOGGER.info(
        "Retention cleanup complete: mail=%d database=%d dry_run=%s",
        removed_mail,
        removed_db,
        dry_run,
    )
    return removed_mail + removed_db


def weekly_report_prefixes(config: Dict[str, Any]) -> List[str]:
    return text_list(
        text_list(config.get("weekly_report_subject_prefixes"))
        + [
            "[SNIPEIT-INVENTORY] REPORT: WEEKLY:",
            "[SNIPEIT-INVENTORY] ALERT: WEEKLY:",
            "[PCINV-REPORT] WEEKLY:",
            "[PCINV-ALERT] WEEKLY:",
            "[PCINV-ALERT] WATCHDOG:",
        ]
    )


def sort_weekly_reports(mailbox: ImapMailbox, config: Dict[str, Any], dry_run: bool) -> int:
    """Move current and legacy weekly health mail into its dedicated folder."""
    if not bool(config.get("sort_human_reports")):
        return 0

    reports_folder = getattr(mailbox, "reports_folder", mailbox.inventory_folder)
    weekly_folder = getattr(mailbox, "weekly_reports_folder", reports_folder)
    alerts_folder = getattr(mailbox, "alerts_folder", reports_folder)
    source_folders = list(
        dict.fromkeys(
            folder
            for folder in (mailbox.inbox_folder, reports_folder, alerts_folder)
            if folder and folder != weekly_folder
        )
    )
    allowed = {
        str(item).strip().lower()
        for item in config.get("report_allowed_from") or config.get("allowed_from") or []
        if str(item).strip()
    }
    prefixes = weekly_report_prefixes(config)
    search_terms = text_list(
        config.get("weekly_report_search_terms") or ["WEEKLY", "WATCHDOG"]
    )
    limit = max(1, int(config.get("max_messages_per_run") or 200))
    failures = 0

    for source_folder in source_folders:
        candidate_uids: set[bytes] = set()
        for term in search_terms:
            escaped_term = term.replace("\\", r"\\").replace('"', r'\"')
            try:
                candidate_uids.update(
                    mailbox.search_uids(
                        f'(SUBJECT "{escaped_term}")',
                        source_folder,
                    )
                )
            except Exception as exc:
                LOGGER.warning(
                    "Deferred weekly report search folder=%s term=%s: %s",
                    source_folder,
                    term,
                    exc,
                )

        ordered_uids = sorted(candidate_uids, key=lambda value: int(value), reverse=True)
        for uid in ordered_uids[:limit]:
            try:
                raw = mailbox.fetch(uid, source_folder)
                message = email.message_from_bytes(raw, policy=email_policy)
                subject = str(message.get("Subject") or "")
                sender = parseaddr(str(message.get("From") or ""))[1].lower()
                if allowed and sender not in allowed:
                    continue
                if not any(subject.startswith(prefix) for prefix in prefixes):
                    continue
                if dry_run:
                    LOGGER.info(
                        "DRY RUN: Would move weekly report UID=%s subject=%s from %s to %s",
                        uid.decode(),
                        subject,
                        source_folder,
                        weekly_folder,
                    )
                else:
                    mailbox.move(uid, weekly_folder, source_folder=source_folder)
                    LOGGER.info(
                        "Sorted weekly report UID=%s subject=%s from %s to %s",
                        uid.decode(),
                        subject,
                        source_folder,
                        weekly_folder,
                    )
            except Exception as exc:
                failures += 1
                LOGGER.warning(
                    "Could not sort weekly report folder=%s UID=%s: %s",
                    source_folder,
                    uid.decode(),
                    exc,
                )
    return failures


def sort_human_reports(mailbox: ImapMailbox, config: Dict[str, Any], dry_run: bool) -> int:
    if not bool(config.get("sort_human_reports")):
        return 0

    report_prefixes = configured_prefixes(
        config,
        "report_subject_prefix",
        "legacy_report_subject_prefixes",
        (
            "[SNIPEIT-INVENTORY] REPORT:",
            "[PCINV-REPORT]",
            "PC Inventory FORCED",
            "PC Inventory USER CHANGE",
            "PC Inventory STOCK",
            "PC Inventory:",
        ),
    )
    warning_prefixes = configured_prefixes(
        config,
        "warning_subject_prefix",
        "legacy_warning_subject_prefixes",
        (
            "[SNIPEIT-INVENTORY] WARNING:",
            "[SNIPEIT-INVENTORY] REPORT: WARNING:",
            "[PCINV-REPORT] WARNING:",
            "PC Inventory WARNING",
        ),
    )
    alert_prefixes = text_list(
        [config.get("human_alert_subject_prefix")]
        + text_list(config.get("human_alert_subject_prefixes"))
    )
    error_prefixes = configured_prefixes(
        config,
        "error_subject_prefix",
        "legacy_error_subject_prefixes",
        (
            "[SNIPEIT-INVENTORY] ERROR:",
            "PC Inventory ERROR",
        ),
    )
    allowed = {
        str(item).strip().lower()
        for item in config.get("report_allowed_from") or config.get("allowed_from") or []
        if str(item).strip()
    }
    failures = 0
    reports_folder = getattr(mailbox, "reports_folder", mailbox.inventory_folder)
    weekly_folder = getattr(mailbox, "weekly_reports_folder", reports_folder)
    alerts_folder = getattr(mailbox, "alerts_folder", reports_folder)
    warnings_folder = getattr(mailbox, "warnings_folder", reports_folder)
    legacy_errors_folder = getattr(mailbox, "inventory_reports_folder", reports_folder)
    errors_folder = getattr(mailbox, "errors_folder", legacy_errors_folder)
    # Specific routes must precede generic REPORT/ALERT prefixes.
    routes = [(prefix, weekly_folder) for prefix in weekly_report_prefixes(config)]
    routes.extend((prefix, warnings_folder) for prefix in warning_prefixes)
    routes.extend((prefix, alerts_folder) for prefix in alert_prefixes)
    routes.extend((prefix, errors_folder) for prefix in error_prefixes)
    routes.extend((prefix, reports_folder) for prefix in report_prefixes)
    search_terms = text_list(
        config.get("human_report_search_terms")
        or ["SNIPEIT-INVENTORY", "PCINV", "PC Inventory"]
    )
    candidate_uids: set[bytes] = set()
    for term in search_terms:
        escaped_term = term.replace("\\", r"\\").replace('"', r"\"")
        try:
            candidate_uids.update(
                mailbox.search_uids(
                    f'(SUBJECT "{escaped_term}")',
                    mailbox.inbox_folder,
                )
            )
        except Exception as exc:
            # Human-readable mail remains in INBOX and is retried next cycle.
            # A temporary Yandex search failure must not block offline events.
            LOGGER.warning("Deferred human report search term=%s: %s", term, exc)

    ordered_uids = sorted(candidate_uids, key=lambda value: int(value), reverse=True)
    limit = max(1, int(config.get("max_messages_per_run") or 200))
    for uid in ordered_uids[:limit]:
        try:
            raw = mailbox.fetch(uid, mailbox.inbox_folder)
            message = email.message_from_bytes(raw, policy=email_policy)
            subject = str(message.get("Subject") or "")
            sender = parseaddr(str(message.get("From") or ""))[1].lower()
            if allowed and sender not in allowed:
                continue
            target = next(
                (folder for prefix, folder in routes if subject.startswith(prefix)),
                "",
            )
            if not target:
                continue
            if dry_run:
                LOGGER.info(
                    "DRY RUN: Would move report UID=%s subject=%s to %s",
                    uid.decode(),
                    subject,
                    target,
                )
            else:
                mailbox.move(uid, target, source_folder=mailbox.inbox_folder)
                LOGGER.info(
                    "Sorted report UID=%s subject=%s to %s",
                    uid.decode(),
                    subject,
                    target,
                )
        except Exception as exc:
            failures += 1
            LOGGER.warning("Could not sort report UID=%s: %s", uid.decode(), exc)
    return failures


def process_message(
    raw_message: bytes,
    config: Dict[str, Any],
    api: SnipeApi,
    store: EventStore,
    source_uid: str = "",
) -> Tuple[str, str]:
    if len(raw_message) > int(config["max_message_bytes"]):
        raise RelayError("Message exceeds max_message_bytes")
    message = email.message_from_bytes(raw_message, policy=email_policy)
    sender = parseaddr(str(message.get("From") or ""))[1].lower()
    allowed = {str(item).lower() for item in config.get("allowed_from") or []}
    if sender not in allowed:
        raise RelayError(f"Sender is not allowed: {sender}")
    if str(message.get("X-SnipeIT-Relay") or "") != "1":
        raise RelayError("X-SnipeIT-Relay header is missing")
    relay_prefixes = configured_prefixes(
        config,
        "subject_prefix",
        "legacy_relay_subject_prefixes",
        ("[SNIPEIT-INVENTORY] RELAY:", "[SNIPEIT-RELAY]"),
    )
    if not any(str(message.get("Subject") or "").startswith(prefix) for prefix in relay_prefixes):
        raise RelayError("Unexpected relay subject")

    payload = decode_envelope(relay_attachment(message), str(config["hmac_secret"]))
    event_id = require_text(payload["event_id"], "event_id", 128)
    header_event_id = normalize_header_token(message.get("X-SnipeIT-Event-ID"))
    if header_event_id and header_event_id != event_id:
        raise RelayError("Event id does not match the mail header")
    computer_name = require_text(payload["computer_name"], "computer_name", 255)
    observed_at = require_text(payload["observed_at"], "observed_at", 128)
    message_id = str(message.get("Message-ID") or "")

    if store.completed(event_id):
        return "duplicate", event_id
    store.mark(
        event_id,
        computer_name,
        observed_at,
        "processing",
        "started",
        source_uid=source_uid,
        message_id=message_id,
    )
    try:
        result, asset_id = apply_payload(api, payload)
        store.mark(event_id, computer_name, observed_at, "processed", result, asset_id)
        return "processed", event_id
    except IgnoredEvent as exc:
        store.mark(event_id, computer_name, observed_at, "ignored", str(exc))
        return "ignored", event_id
    except StaleEvent as exc:
        store.mark(event_id, computer_name, observed_at, "stale", str(exc))
        return "stale", event_id
    except Exception as exc:
        store.mark(event_id, computer_name, observed_at, "failed", str(exc))
        raise


def is_relay_candidate(raw_message: bytes, config: Dict[str, Any]) -> bool:
    """Confirm an IMAP search hit before any message can be moved."""
    message = email.message_from_bytes(raw_message, policy=email_policy)
    subject = str(message.get("Subject") or "")
    marker = str(message.get("X-SnipeIT-Relay") or "")
    prefixes = configured_prefixes(
        config,
        "subject_prefix",
        "legacy_relay_subject_prefixes",
        ("[SNIPEIT-INVENTORY] RELAY:", "[SNIPEIT-RELAY]"),
    )
    return any(subject.startswith(prefix) for prefix in prefixes) or marker == "1"


def process_imap(config: Dict[str, Any], dry_run: bool = False) -> int:
    store = EventStore(":memory:" if dry_run else str(config["database_path"]))
    api = SnipeApi(config, dry_run=dry_run)
    mailbox: Optional[ImapMailbox] = None
    failures = 0
    try:
        mailbox = ImapMailbox(config)
        try:
            migrate_legacy_folders(mailbox, config, dry_run=dry_run)
        except Exception as exc:
            failures += 1
            LOGGER.warning("Legacy folder migration failed: %s", exc)
        relay_items = mailbox.relay_items()
        LOGGER.info("Found %d relay message(s)", len(relay_items))
        for source_folder, uid in relay_items:
            relay_candidate = False
            try:
                raw = mailbox.fetch(uid, source_folder)
                relay_candidate = is_relay_candidate(raw, config)
                if not relay_candidate:
                    LOGGER.warning(
                        "folder=%s UID=%s ignored after false-positive IMAP search",
                        source_folder,
                        uid.decode(),
                    )
                    continue
                status, event_id = process_message(
                    raw,
                    config,
                    api,
                    store,
                    source_uid=uid.decode(),
                )
                LOGGER.info(
                    "folder=%s UID=%s event_id=%s status=%s",
                    source_folder,
                    uid.decode(),
                    event_id,
                    status,
                )
                if not dry_run:
                    mailbox.move(uid, mailbox.processed_folder, source_folder=source_folder)
            except TransientRelayError as exc:
                failures += 1
                LOGGER.warning(
                    "folder=%s UID=%s deferred after transient error: %s",
                    source_folder,
                    uid.decode(),
                    exc,
                )
                if not dry_run and source_folder != mailbox.source_folder:
                    try:
                        mailbox.move(uid, mailbox.source_folder, source_folder=source_folder)
                    except Exception:
                        LOGGER.exception("Could not stage UID=%s in relay folder", uid.decode())
            except Exception as exc:
                failures += 1
                LOGGER.exception(
                    "folder=%s UID=%s rejected: %s", source_folder, uid.decode(), exc
                )
                if not dry_run and relay_candidate:
                    try:
                        mailbox.move(uid, mailbox.rejected_folder, source_folder=source_folder)
                    except Exception:
                        LOGGER.exception("Could not move UID=%s to rejected folder", uid.decode())
                elif not relay_candidate:
                    LOGGER.warning(
                        "folder=%s UID=%s left untouched because relay markers were not confirmed",
                        source_folder,
                        uid.decode(),
                    )
        failures += sort_weekly_reports(mailbox, config, dry_run)
        failures += sort_human_reports(mailbox, config, dry_run)
        try:
            run_retention_cleanup(mailbox, store, config, dry_run=dry_run)
        except Exception as exc:
            failures += 1
            LOGGER.warning("Retention cleanup failed: %s", exc)
    finally:
        if mailbox:
            mailbox.close()
        failures += send_due_alerts(config, store, dry_run=dry_run)
        store.close()
    return 1 if failures else 0


def process_file(path: str, config: Dict[str, Any], dry_run: bool = False) -> int:
    raw = Path(path).read_bytes()
    store = EventStore(":memory:" if dry_run else str(config["database_path"]))
    try:
        status, event_id = process_message(raw, config, SnipeApi(config, dry_run=dry_run), store)
        LOGGER.info("File event_id=%s status=%s", event_id, status)
    finally:
        store.close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="/etc/snipeit-mail-relay/config.json")
    parser.add_argument("--process-file", help="Process a saved RFC822 .eml file instead of IMAP")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--check-config", action="store_true")
    parser.add_argument("--check-imap", action="store_true")
    parser.add_argument("--check-snipe", action="store_true")
    parser.add_argument("--list-folders", action="store_true")
    args = parser.parse_args()

    config = load_config(args.config)
    configure_logging(str(config.get("log_path") or ""), args.verbose)
    if args.check_config:
        LOGGER.info("Configuration is valid. Relay version=%s", RELAY_VERSION)
        return 0
    if args.check_imap or args.list_folders:
        mailbox = ImapMailbox(config)
        try:
            if args.list_folders:
                for folder in sorted(mailbox.folders.values(), key=str.casefold):
                    print(folder)
            LOGGER.info("IMAP connection and folder resolution are valid")
        finally:
            mailbox.close()
        return 0
    if args.check_snipe:
        api = SnipeApi(config)
        response = api.request("GET", "/api/v1/statuslabels?limit=1")
        LOGGER.info("Snipe-IT API connection is valid: rows=%d", len(api.rows(response)))
        return 0
    if args.process_file:
        return process_file(args.process_file, config, dry_run=args.dry_run)
    return process_imap(config, dry_run=args.dry_run)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as exc:
        LOGGER.exception("Fatal relay error: %s", exc)
        raise SystemExit(1)
