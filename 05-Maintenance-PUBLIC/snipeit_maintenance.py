#!/usr/bin/env python3
"""Daily SnipeIT Inventory users deletion, cleanup, and weekly health reporting."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import logging
import re
import smtplib
import sqlite3
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from email.message import EmailMessage
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


VERSION = "1.3.3"
LOGGER = logging.getLogger("snipeit-maintenance")


class MaintenanceError(RuntimeError):
    pass


class OffboardingBlocked(MaintenanceError):
    pass


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def parse_datetime(value: Any) -> Optional[dt.datetime]:
    if isinstance(value, dict):
        for key in ("datetime", "date", "formatted", "value"):
            parsed = parse_datetime(value.get(key))
            if parsed:
                return parsed
        return None
    text = str(value or "").strip().replace("\r\n", "\n")
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(text)
    except ValueError:
        parsed = None
    if parsed is None:
        for fmt in (
            "%H:%M %d.%m.%Y",
            "%H:%M\n%d.%m.%Y",
            "%d.%m.%Y %H:%M",
            "%d.%m.%Y %H:%M:%S",
            "%Y-%m-%d %H:%M:%S",
        ):
            try:
                parsed = dt.datetime.strptime(text, fmt)
                break
            except ValueError:
                continue
    if parsed is None:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone(dt.timedelta(hours=3)))
    return parsed.astimezone(dt.timezone.utc)


def load_json(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8-sig") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise MaintenanceError(f"JSON root must be an object: {path}")
    return value


def load_config(path: str) -> Dict[str, Any]:
    config = load_json(path)
    relay_path = str(
        config.get("relay_config_path") or "/etc/snipeit-mail-relay/config.json"
    )
    relay = load_json(relay_path)
    merged = dict(relay)
    merged.update(config)
    merged["relay_config_path"] = relay_path

    required = (
        "snipe_url",
        "snipe_token",
        "ldap_helper_path",
        "snipe_app_path",
        "ldap_search_base",
    )
    for name in required:
        if not str(merged.get(name) or "").strip():
            raise MaintenanceError(f"Missing required config property: {name}")

    merged.setdefault("state_database_path", "/var/lib/snipeit-maintenance/state.sqlite3")
    merged.setdefault("log_path", "/var/log/snipeit-maintenance/maintenance.log")
    merged.setdefault("php_binary", "/usr/bin/php")
    merged.setdefault("verify_tls", False)
    merged.setdefault("api_timeout_seconds", 30)
    merged.setdefault("snipe_host_header", "")
    merged.setdefault("stock_status_id", 1)
    merged.setdefault("users_deletion_enabled", merged.get("offboarding_enabled", True))
    merged["offboarding_enabled"] = bool(merged.get("users_deletion_enabled"))
    merged.setdefault("offboarding_confirmation_runs", 2)
    # Deletion is intentionally delayed for a full 30-day continuous AD-disabled
    # period. The old hourly setting is retained only as a compatibility input.
    legacy_hours = max(0, int(merged.get("offboarding_minimum_age_hours") or 0))
    legacy_days = (legacy_hours + 23) // 24
    merged.setdefault("users_deletion_disabled_days", max(30, legacy_days))
    merged["users_deletion_disabled_days"] = max(
        30, int(merged.get("users_deletion_disabled_days") or 30)
    )
    merged["offboarding_minimum_age_hours"] = (
        int(merged["users_deletion_disabled_days"]) * 24
    )
    merged.setdefault("offboarding_confirmation_interval_hours", 12)
    merged.setdefault("offboarding_max_users_per_run", 10)
    merged.setdefault("offboarding_max_ldap_candidates", 500)
    merged.setdefault("offboarding_require_ldap_import", True)
    merged.setdefault("offboarding_protected_usernames", ["snipeit"])
    merged.setdefault("offboarding_digest_repeat_hours", 168)
    merged.setdefault("maintenance_database_retention_days", 365)
    merged.setdefault("product_name", "SnipeIT Inventory")
    merged.setdefault("mail_subject_prefix", "[SNIPEIT-INVENTORY]")
    # Legacy watchdog keys are read only as migration fallbacks. New output and
    # state always use the weekly_report namespace.
    merged.setdefault("weekly_report_enabled", merged.get("watchdog_enabled", True))
    merged.setdefault("weekly_report_weekday", 0)
    merged.setdefault("weekly_report_stale_days", merged.get("watchdog_stale_days", 7))
    merged.setdefault("weekly_report_critical_days", 14)
    merged.setdefault("weekly_report_category_ids", merged.get("watchdog_category_ids", [1]))
    merged.setdefault("weekly_report_max_rows", merged.get("watchdog_max_rows", 250))
    merged.setdefault("weekly_report_mail_to", merged.get("watchdog_mail_to") or merged.get("alert_mail_to") or "")
    merged.setdefault("weekly_report_subject_prefix", "[SNIPEIT-INVENTORY] REPORT:")
    merged.setdefault(
        "weekly_alert_subject_prefix",
        merged.get("human_alert_subject_prefix") or "[SNIPEIT-INVENTORY] ALERT:",
    )
    merged.setdefault("weekly_alert_mail_to", merged.get("weekly_report_mail_to") or "")
    merged.setdefault("weekly_report_timezone", merged.get("display_timezone") or "Europe/Moscow")
    merged.setdefault("weekly_report_send_when_empty", True)
    merged.setdefault(
        "users_deletion_mail_to",
        merged.get("offboarding_mail_to") or merged.get("alert_mail_to") or "",
    )
    merged.setdefault(
        "users_deletion_subject_prefix",
        merged.get("human_alert_subject_prefix") or "[SNIPEIT-INVENTORY] ALERT:",
    )
    # Keep legacy names available to existing deployments and command lines.
    merged["offboarding_mail_to"] = merged["users_deletion_mail_to"]
    merged["offboarding_subject_prefix"] = merged["users_deletion_subject_prefix"]
    return merged


def configure_logging(path: str, verbose: bool = False) -> None:
    handlers: List[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    if path:
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.FileHandler(target, encoding="utf-8"))
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=handlers,
    )


class SnipeApi:
    def __init__(self, config: Dict[str, Any], dry_run: bool = False) -> None:
        self.base_url = str(config["snipe_url"]).rstrip("/")
        self.token = str(config["snipe_token"])
        self.timeout = int(config.get("api_timeout_seconds") or 30)
        self.host_header = str(config.get("snipe_host_header") or "").strip()
        self.dry_run = dry_run
        self.ssl_context = ssl.create_default_context()
        if not bool(config.get("verify_tls")):
            self.ssl_context.check_hostname = False
            self.ssl_context.verify_mode = ssl.CERT_NONE

    def request(
        self,
        method: str,
        path: str,
        body: Optional[Dict[str, Any]] = None,
    ) -> Any:
        if self.dry_run and method.upper() not in ("GET", "HEAD"):
            LOGGER.info("DRY RUN: Would call %s %s body=%s", method, path, body or {})
            return {"status": "success", "dry_run": True}
        url = path if path.startswith("http") else f"{self.base_url}/{path.lstrip('/')}"
        data = None
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self.token}",
            "User-Agent": f"SnipeIT-Inventory-Maintenance/{VERSION}",
        }
        if data is not None:
            headers["Content-Type"] = "application/json"
        if self.host_header:
            headers["Host"] = self.host_header
        request = urllib.request.Request(url, data=data, headers=headers, method=method.upper())
        try:
            with urllib.request.urlopen(
                request,
                timeout=self.timeout,
                context=self.ssl_context,
            ) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:4000]
            raise MaintenanceError(f"Snipe API HTTP {exc.code} {method} {path}: {detail}") from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise MaintenanceError(f"Snipe API transport error {method} {path}: {exc}") from exc
        if not raw:
            return None
        result = json.loads(raw.decode("utf-8-sig"))
        if isinstance(result, dict) and str(result.get("status") or "").lower() == "error":
            raise MaintenanceError(
                f"Snipe API rejected {method} {path}: {result.get('messages') or result}"
            )
        return result

    @staticmethod
    def rows(response: Any) -> List[Dict[str, Any]]:
        if isinstance(response, dict) and isinstance(response.get("rows"), list):
            return [item for item in response["rows"] if isinstance(item, dict)]
        if isinstance(response, list):
            return [item for item in response if isinstance(item, dict)]
        return []

    def paginate(self, path: str, limit: int = 500) -> List[Dict[str, Any]]:
        rows: List[Dict[str, Any]] = []
        offset = 0
        separator = "&" if "?" in path else "?"
        while True:
            response = self.request("GET", f"{path}{separator}limit={limit}&offset={offset}")
            page = self.rows(response)
            rows.extend(page)
            total = int(response.get("total") or len(rows)) if isinstance(response, dict) else len(rows)
            if not page or len(rows) >= total or len(page) < limit:
                return rows
            offset += len(page)


class StateStore:
    def __init__(self, path: str) -> None:
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(str(target), timeout=30)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA busy_timeout=30000")
        self.connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS offboarding_candidates (
                username TEXT PRIMARY KEY COLLATE NOCASE,
                snipe_user_id INTEGER,
                first_seen_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                confirmation_runs INTEGER NOT NULL DEFAULT 1,
                reason TEXT NOT NULL,
                distinguished_name TEXT,
                status TEXT NOT NULL,
                last_action_at TEXT,
                last_error TEXT
            );
            CREATE TABLE IF NOT EXISTS maintenance_actions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at TEXT NOT NULL,
                username TEXT,
                snipe_user_id INTEGER,
                action TEXT NOT NULL,
                asset_id INTEGER,
                result TEXT NOT NULL,
                details TEXT
            );
            CREATE TABLE IF NOT EXISTS maintenance_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )
        self.connection.commit()

    def close(self) -> None:
        self.connection.close()

    def get_candidate(self, username: str) -> Optional[Dict[str, Any]]:
        row = self.connection.execute(
            "SELECT * FROM offboarding_candidates WHERE username = ?", (username,)
        ).fetchone()
        return dict(row) if row else None

    def observe_candidate(
        self,
        username: str,
        user_id: Optional[int],
        reason: str,
        distinguished_name: str,
        now: dt.datetime,
        minimum_interval_hours: int,
        dry_run: bool = False,
    ) -> Tuple[Dict[str, Any], bool]:
        current = self.get_candidate(username)
        timestamp = now.isoformat()
        reset = (
            current is None
            or current["status"] in ("cleared", "not_present")
            or (
                current["status"] == "completed"
                and user_id is not None
                and int(current.get("snipe_user_id") or 0) != int(user_id)
            )
        )
        if reset:
            candidate = {
                "username": username,
                "snipe_user_id": user_id,
                "first_seen_at": timestamp,
                "last_seen_at": timestamp,
                "confirmation_runs": 1,
                "reason": reason,
                "distinguished_name": distinguished_name,
                "status": "staged" if user_id is not None else "not_present",
                "last_action_at": None,
                "last_error": None,
            }
            if not dry_run:
                self.connection.execute(
                    """
                    INSERT INTO offboarding_candidates(
                        username, snipe_user_id, first_seen_at, last_seen_at,
                        confirmation_runs, reason, distinguished_name, status,
                        last_action_at, last_error
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                    ON CONFLICT(username) DO UPDATE SET
                        snipe_user_id=excluded.snipe_user_id,
                        first_seen_at=excluded.first_seen_at,
                        last_seen_at=excluded.last_seen_at,
                        confirmation_runs=excluded.confirmation_runs,
                        reason=excluded.reason,
                        distinguished_name=excluded.distinguished_name,
                        status=excluded.status,
                        last_action_at=NULL,
                        last_error=NULL
                    """,
                    (
                        username,
                        user_id,
                        timestamp,
                        timestamp,
                        1,
                        reason,
                        distinguished_name,
                        candidate["status"],
                    ),
                )
                self.connection.commit()
            return candidate, True

        candidate = dict(current)
        last_seen = parse_datetime(current["last_seen_at"]) or now
        runs = int(current["confirmation_runs"])
        confirmed_now = now - last_seen >= dt.timedelta(hours=max(1, minimum_interval_hours))
        if confirmed_now:
            runs += 1
        confirmation_timestamp = timestamp if confirmed_now else current["last_seen_at"]
        candidate.update(
            {
                "snipe_user_id": user_id,
                "last_seen_at": confirmation_timestamp,
                "confirmation_runs": runs,
                "reason": reason,
                "distinguished_name": distinguished_name,
            }
        )
        if not dry_run:
            self.connection.execute(
                """
                UPDATE offboarding_candidates
                SET snipe_user_id=?, last_seen_at=?, confirmation_runs=?, reason=?,
                    distinguished_name=?
                WHERE username=?
                """,
                (
                    user_id,
                    confirmation_timestamp,
                    runs,
                    reason,
                    distinguished_name,
                    username,
                ),
            )
            self.connection.commit()
        return candidate, False

    def set_candidate_status(
        self,
        username: str,
        status: str,
        error: str = "",
        dry_run: bool = False,
    ) -> None:
        if dry_run:
            return
        self.connection.execute(
            """
            UPDATE offboarding_candidates
            SET status=?, last_action_at=?, last_error=?
            WHERE username=?
            """,
            (status, utc_now().isoformat(), error[:4000], username),
        )
        self.connection.commit()

    def clear_absent(self, active_usernames: Iterable[str], dry_run: bool = False) -> int:
        active = {str(item).casefold() for item in active_usernames}
        rows = self.connection.execute(
            "SELECT username FROM offboarding_candidates WHERE status NOT IN ('completed', 'cleared')"
        ).fetchall()
        absent = [str(row[0]) for row in rows if str(row[0]).casefold() not in active]
        if absent and not dry_run:
            self.connection.executemany(
                "UPDATE offboarding_candidates SET status='cleared', last_error='' WHERE username=?",
                [(username,) for username in absent],
            )
            self.connection.commit()
        return len(absent)

    def log_action(
        self,
        username: str,
        user_id: Optional[int],
        action: str,
        result: str,
        details: str = "",
        asset_id: Optional[int] = None,
        dry_run: bool = False,
    ) -> None:
        if dry_run:
            return
        self.connection.execute(
            """
            INSERT INTO maintenance_actions(
                created_at, username, snipe_user_id, action, asset_id, result, details
            ) VALUES(?, ?, ?, ?, ?, ?, ?)
            """,
            (
                utc_now().isoformat(),
                username,
                user_id,
                action,
                asset_id,
                result,
                details[:4000],
            ),
        )
        self.connection.commit()

    def get_meta(self, key: str) -> str:
        row = self.connection.execute(
            "SELECT value FROM maintenance_meta WHERE key=?", (key,)
        ).fetchone()
        return str(row[0]) if row else ""

    def set_meta(self, key: str, value: str, dry_run: bool = False) -> None:
        if dry_run:
            return
        self.connection.execute(
            """
            INSERT INTO maintenance_meta(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """,
            (key, value),
        )
        self.connection.commit()

    def digest_due(
        self,
        key: str,
        digest: str,
        repeat_hours: int,
        now: dt.datetime,
    ) -> bool:
        raw = self.get_meta(key)
        if not raw:
            return True
        try:
            previous = json.loads(raw)
            sent_at = parse_datetime(previous.get("sent_at"))
            return previous.get("digest") != digest or sent_at is None or (
                now - sent_at >= dt.timedelta(hours=max(1, repeat_hours))
            )
        except (ValueError, TypeError, json.JSONDecodeError):
            return True

    def mark_digest(self, key: str, digest: str, now: dt.datetime, dry_run: bool = False) -> None:
        self.set_meta(
            key,
            json.dumps({"digest": digest, "sent_at": now.isoformat()}, separators=(",", ":")),
            dry_run=dry_run,
        )

    def cleanup(self, retention_days: int, now: Optional[dt.datetime] = None) -> int:
        if retention_days <= 0:
            return 0
        cutoff = ((now or utc_now()) - dt.timedelta(days=retention_days)).isoformat()
        actions = self.connection.execute(
            "DELETE FROM maintenance_actions WHERE created_at < ?", (cutoff,)
        ).rowcount
        candidates = self.connection.execute(
            """
            DELETE FROM offboarding_candidates
            WHERE last_seen_at < ?
              AND status IN ('completed', 'cleared', 'not_present')
            """,
            (cutoff,),
        ).rowcount
        removed = max(0, int(actions or 0)) + max(0, int(candidates or 0))
        self.connection.commit()
        if removed:
            self.connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            self.connection.execute("VACUUM")
        return removed


def run_ldap_helper(config: Dict[str, Any]) -> List[Dict[str, Any]]:
    command = [
        str(config.get("php_binary") or "/usr/bin/php"),
        str(config["ldap_helper_path"]),
        str(config["snipe_app_path"]),
        str(config["ldap_search_base"]),
    ]
    process = subprocess.run(
        command,
        cwd=str(config["snipe_app_path"]),
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=180,
        check=False,
    )
    if process.returncode != 0:
        raise MaintenanceError(
            f"LDAP helper exit={process.returncode}: {(process.stderr or process.stdout).strip()[:2000]}"
        )
    try:
        payload = json.loads(process.stdout)
    except json.JSONDecodeError as exc:
        raise MaintenanceError(f"LDAP helper returned invalid JSON: {process.stdout[:500]}") from exc
    users = payload.get("users") if isinstance(payload, dict) else None
    if not isinstance(users, list):
        raise MaintenanceError("LDAP helper JSON does not contain users array")
    limit = int(config.get("offboarding_max_ldap_candidates") or 500)
    if len(users) > limit:
        raise MaintenanceError(
            f"LDAP safety stop: {len(users)} terminated candidates exceeds configured limit {limit}"
        )
    return [item for item in users if isinstance(item, dict)]


def send_mail(config: Dict[str, Any], recipient: str, subject: str, html_body: str) -> None:
    host = str(config.get("smtp_host") or "").strip()
    user = str(config.get("smtp_user") or "").strip()
    password = str(config.get("smtp_password") or "")
    if not all((host, user, password, recipient)):
        raise MaintenanceError("SMTP settings are incomplete")
    message = EmailMessage()
    message["From"] = user
    message["To"] = recipient
    message["Subject"] = subject
    message.set_content(re.sub("<[^>]+>", " ", html_body))
    message.add_alternative(html_body, subtype="html")

    if bool(config.get("smtp_ssl")):
        with smtplib.SMTP_SSL(
            host,
            int(config.get("smtp_port") or 465),
            timeout=int(config.get("smtp_timeout_seconds") or 30),
            context=ssl.create_default_context(),
        ) as client:
            client.login(user, password)
            client.send_message(message)
        return
    with smtplib.SMTP(
        host,
        int(config.get("smtp_port") or 587),
        timeout=int(config.get("smtp_timeout_seconds") or 30),
    ) as client:
        if bool(config.get("smtp_starttls", True)):
            client.starttls(context=ssl.create_default_context())
        client.login(user, password)
        client.send_message(message)


def exact_username_map(users: Iterable[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    result: Dict[str, Dict[str, Any]] = {}
    for user in users:
        username = str(user.get("username") or "").strip()
        if username:
            result[username.casefold()] = user
    return result


def matches_any(value: str, patterns: Iterable[str]) -> bool:
    return any(re.search(str(pattern), value, re.IGNORECASE) for pattern in patterns)


def offboard_user(
    api: SnipeApi,
    store: StateStore,
    config: Dict[str, Any],
    username: str,
    user_id: int,
    reason: str,
    dry_run: bool = False,
) -> Dict[str, Any]:
    note = (
        f"Automatic Users Deletion by SnipeIT Inventory Maintenance {VERSION}. "
        f"Reason: {reason}"
    )
    assets = api.paginate(f"/api/v1/users/{user_id}/assets")
    checked_in: List[int] = []
    checked_in_accessories: List[int] = []
    checked_in_license_seats: List[int] = []
    for asset in assets:
        asset_id = int(asset.get("id") or 0)
        if asset_id <= 0:
            continue
        api.request("POST", f"/api/v1/hardware/{asset_id}/checkin", {"note": note})
        api.request(
            "PATCH",
            f"/api/v1/hardware/{asset_id}",
            {"status_id": int(config.get("stock_status_id") or 1)},
        )
        store.log_action(
            username,
            user_id,
            "hardware_checkin",
            "success",
            reason,
            asset_id=asset_id,
            dry_run=dry_run,
        )
        checked_in.append(asset_id)

    if not dry_run and api.paginate(f"/api/v1/users/{user_id}/assets"):
        raise MaintenanceError(f"hardware checkin verification failed for user_id={user_id}")

    for accessory in api.paginate(f"/api/v1/users/{user_id}/accessories"):
        accessory_id = int(accessory.get("id") or 0)
        if accessory_id <= 0:
            continue
        for checkout in api.paginate(f"/api/v1/accessories/{accessory_id}/checkedout"):
            assigned_to = checkout.get("assigned_to")
            assigned_id = (
                int(assigned_to.get("id") or 0) if isinstance(assigned_to, dict) else 0
            )
            checkout_id = int(checkout.get("id") or 0)
            if assigned_id != user_id or checkout_id <= 0:
                continue
            api.request(
                "POST",
                f"/api/v1/accessories/{checkout_id}/checkin",
                {"note": note},
            )
            store.log_action(
                username,
                user_id,
                "accessory_checkin",
                "success",
                f"accessory_id={accessory_id}; {reason}",
                asset_id=checkout_id,
                dry_run=dry_run,
            )
            checked_in_accessories.append(checkout_id)

    for license_item in api.paginate(f"/api/v1/users/{user_id}/licenses"):
        license_id = int(license_item.get("id") or 0)
        if license_id <= 0:
            continue
        for seat in api.paginate(f"/api/v1/licenses/{license_id}/seats"):
            assigned_user = seat.get("assigned_user")
            assigned_id = (
                int(assigned_user.get("id") or 0)
                if isinstance(assigned_user, dict)
                else 0
            )
            seat_id = int(seat.get("id") or 0)
            if assigned_id != user_id or seat_id <= 0:
                continue
            api.request(
                "PATCH",
                f"/api/v1/licenses/{license_id}/seats/{seat_id}",
                {"assigned_to": None, "asset_id": None, "notes": note},
            )
            store.log_action(
                username,
                user_id,
                "license_checkin",
                "success",
                f"license_id={license_id}; {reason}",
                asset_id=seat_id,
                dry_run=dry_run,
            )
            checked_in_license_seats.append(seat_id)

    remaining_accessories = (
        [] if dry_run else api.paginate(f"/api/v1/users/{user_id}/accessories")
    )
    remaining_licenses = (
        [] if dry_run else api.paginate(f"/api/v1/users/{user_id}/licenses")
    )
    if remaining_accessories or remaining_licenses:
        raise OffboardingBlocked(
            f"user still has accessories={len(remaining_accessories)} "
            f"licenses={len(remaining_licenses)}; user deletion deferred"
        )

    api.request("DELETE", f"/api/v1/users/{user_id}")
    store.log_action(
        username,
        user_id,
        "user_soft_delete",
        "success",
        reason,
        dry_run=dry_run,
    )
    return {
        "username": username,
        "user_id": user_id,
        "assets": checked_in,
        "accessory_checkouts": checked_in_accessories,
        "license_seats": checked_in_license_seats,
    }


def digest_text(items: Any) -> str:
    raw = json.dumps(items, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def offboarding_run(
    api: SnipeApi,
    store: StateStore,
    config: Dict[str, Any],
    dry_run: bool = False,
) -> Dict[str, Any]:
    terminated = run_ldap_helper(config)
    now = utc_now()
    users = exact_username_map(api.paginate("/api/v1/users"))
    protected_patterns = [str(item) for item in config.get("offboarding_protected_usernames") or []]
    confirmation_runs = max(2, int(config.get("offboarding_confirmation_runs") or 2))
    disabled_days = max(30, int(config.get("users_deletion_disabled_days") or 30))
    minimum_age = dt.timedelta(days=disabled_days)
    interval_hours = max(
        1, int(config.get("offboarding_confirmation_interval_hours") or 12)
    )
    max_actions = max(1, int(config.get("offboarding_max_users_per_run") or 10))
    staged: List[str] = []
    completed: List[Dict[str, Any]] = []
    blocked: List[Dict[str, str]] = []
    skipped: List[Dict[str, str]] = []
    not_present: List[str] = []
    action_count = 0

    for ad_user in terminated:
        username = str(ad_user.get("username") or "").strip()
        if not username:
            continue
        snipe_user = users.get(username.casefold())
        user_id = int(snipe_user.get("id") or 0) if snipe_user else None
        candidate, is_new = store.observe_candidate(
            username,
            user_id,
            str(ad_user.get("reason") or "ad_terminated"),
            str(ad_user.get("distinguished_name") or ""),
            now,
            interval_hours,
            dry_run=dry_run,
        )
        if user_id is None:
            not_present.append(username)
            continue
        if matches_any(username, protected_patterns):
            store.set_candidate_status(username, "protected", "protected username", dry_run=dry_run)
            skipped.append({"username": username, "reason": "protected username"})
            continue
        if bool(config.get("offboarding_require_ldap_import", True)) and not bool(
            snipe_user.get("ldap_import")
        ):
            error = "Snipe-IT user is local, not LDAP-imported"
            store.set_candidate_status(username, "protected", error, dry_run=dry_run)
            skipped.append({"username": username, "reason": error})
            continue
        if is_new:
            staged.append(username)
            LOGGER.info(
                "Users Deletion tracking started username=%s user_id=%s disabled_days=%d",
                username,
                user_id,
                disabled_days,
            )

        first_seen = parse_datetime(candidate["first_seen_at"]) or now
        due = (
            int(candidate["confirmation_runs"]) >= confirmation_runs
            and now - first_seen >= minimum_age
            and candidate.get("status") != "completed"
        )
        if not due or action_count >= max_actions:
            continue

        action_count += 1
        try:
            result = offboard_user(
                api,
                store,
                config,
                username,
                int(user_id),
                str(ad_user.get("reason") or "ad_terminated"),
                dry_run=dry_run,
            )
            store.set_candidate_status(username, "completed", dry_run=dry_run)
            completed.append(result)
            LOGGER.info(
                "%s username=%s user_id=%s assets=%s",
                "DRY RUN: Would delete user" if dry_run else "Users Deletion completed",
                username,
                user_id,
                result["assets"],
            )
        except Exception as exc:
            status = "blocked" if isinstance(exc, OffboardingBlocked) else "error"
            store.set_candidate_status(username, status, str(exc), dry_run=dry_run)
            store.log_action(
                username,
                user_id,
                "offboarding",
                status,
                str(exc),
                dry_run=dry_run,
            )
            blocked.append({"username": username, "error": str(exc)[:1000]})
            LOGGER.warning("Users Deletion %s username=%s: %s", status, username, exc)

    cleared = store.clear_absent(
        [str(item.get("username") or "") for item in terminated],
        dry_run=dry_run,
    )
    summary = {
        "ldap_terminated": len(terminated),
        "staged": sorted(staged, key=str.casefold),
        "completed": completed,
        "deleted": completed,
        "blocked": blocked,
        "skipped": skipped,
        "not_present_count": len(not_present),
        "cleared": cleared,
        "action_limit": max_actions,
        "disabled_days_required": disabled_days,
    }
    # Tracking a newly disabled user is intentionally quiet. Mail is sent only
    # after a deletion or when an action genuinely needs administrator attention.
    meaningful = completed or blocked
    if meaningful and not dry_run:
        digest = digest_text(summary)
        if store.digest_due(
            "users_deletion_digest",
            digest,
            int(config.get("offboarding_digest_repeat_hours") or 72),
            now,
        ):
            rows = []
            for item in completed:
                rows.append(
                    f"<tr><td>{html.escape(item['username'])}</td><td>deleted</td>"
                    f"<td>assets: {html.escape(str(item['assets']))}; "
                    f"accessories: {html.escape(str(item['accessory_checkouts']))}; "
                    f"license seats: {html.escape(str(item['license_seats']))}</td></tr>"
                )
            for item in blocked:
                rows.append(
                    f"<tr><td>{html.escape(item['username'])}</td><td>blocked</td>"
                    f"<td>{html.escape(item['error'])}</td></tr>"
                )
            body = (
                "<h2>SnipeIT Inventory Users Deletion</h2>"
                f"<p>Users are deleted only after being continuously disabled in AD "
                f"for {disabled_days} days.</p>"
                f"<p>AD disabled: {len(terminated)}; deleted: {len(completed)}; "
                f"blocked: {len(blocked)}; tracking: {len(staged)}.</p>"
                "<table border='1' cellpadding='6'><tr><th>User</th><th>Status</th><th>Details</th></tr>"
                + "".join(rows)
                + "</table>"
            )
            send_mail(
                config,
                str(config.get("users_deletion_mail_to") or ""),
                f"{config.get('users_deletion_subject_prefix')} USERS DELETION: "
                f"{len(completed)} deleted / {len(blocked)} blocked",
                body,
            )
            store.mark_digest("users_deletion_digest", digest, now)
    return summary


def custom_field_value(asset: Dict[str, Any], configured_name: str) -> str:
    fields = asset.get("custom_fields")
    if not isinstance(fields, dict):
        return ""
    wanted = configured_name.casefold()
    for label, field in fields.items():
        if not isinstance(field, dict):
            continue
        field_name = str(field.get("field") or "").casefold()
        if str(label).casefold() == wanted or field_name == wanted:
            return str(field.get("value") or "").strip()
    return ""


def compact_value(value: Any) -> str:
    if isinstance(value, dict):
        return str(value.get("name") or value.get("text") or value.get("id") or "")
    return str(value or "")


def report_timezone(config: Dict[str, Any]) -> dt.tzinfo:
    name = str(config.get("weekly_report_timezone") or "Europe/Moscow")
    try:
        return ZoneInfo(name)
    except ZoneInfoNotFoundError as exc:
        raise MaintenanceError(f"Unknown weekly report timezone: {name}") from exc


def format_report_datetime(value: Optional[dt.datetime], timezone: dt.tzinfo) -> str:
    if value is None:
        return "Never"
    return value.astimezone(timezone).strftime("%H:%M %d.%m.%Y")


def weekly_report_period(now: dt.datetime, timezone: dt.tzinfo) -> Tuple[str, dt.datetime]:
    local_now = now.astimezone(timezone)
    iso = local_now.isocalendar()
    return f"{iso.year}-W{iso.week:02d}", local_now


def weekly_report_run(
    api: SnipeApi,
    store: StateStore,
    config: Dict[str, Any],
    dry_run: bool = False,
    force: bool = False,
) -> Dict[str, Any]:
    now = utc_now()
    timezone = report_timezone(config)
    period, local_now = weekly_report_period(now, timezone)
    report_weekday = min(6, max(0, int(config.get("weekly_report_weekday") or 0)))
    report_already_sent = store.get_meta("weekly_report_last_period") == period
    legacy_alert_already_sent = store.get_meta("weekly_alert_last_period") == period
    already_sent = report_already_sent or legacy_alert_already_sent
    report_due = force or (
        local_now.weekday() >= report_weekday and not already_sent
    )
    if not report_due:
        LOGGER.info(
            "Weekly inventory report skipped: period=%s weekday=%d configured_weekday=%d already_sent=%s",
            period,
            local_now.weekday(),
            report_weekday,
            already_sent,
        )
        return {
            "period": period,
            "due": False,
            "sent": False,
            "total": 0,
            "current": 0,
            "overdue": 0,
            "warning": 0,
            "critical": 0,
            "never": 0,
            "alert_sent": False,
            "assets": [],
        }

    stale_days = max(1, int(config.get("weekly_report_stale_days") or 7))
    critical_days = max(
        stale_days + 1, int(config.get("weekly_report_critical_days") or 14)
    )
    category_ids = {int(item) for item in config.get("weekly_report_category_ids") or []}
    custom_fields = config.get("custom_fields") or {}
    last_success_field = str(
        custom_fields.get("last_success") or "_snipeit_last_successful_inventory_12"
    )
    agent_version_field = str(
        custom_fields.get("agent_version") or "_snipeit_agent_version_11"
    )
    last_error_field = str(custom_fields.get("last_error") or "_snipeit_last_error_13")

    assets: List[Dict[str, Any]] = []
    for asset in api.paginate("/api/v1/hardware"):
        category = asset.get("category") if isinstance(asset.get("category"), dict) else {}
        category_id = int(category.get("id") or 0)
        if category_ids and category_id not in category_ids:
            continue

        last_success_raw = custom_field_value(asset, last_success_field)
        last_success = parse_datetime(last_success_raw)
        created_at = parse_datetime(asset.get("created_at"))
        reference = last_success or created_at
        age_days = None
        if reference is not None:
            age_days = max(0, int((now - reference).total_seconds() // 86400))
        overdue = age_days is None or age_days >= stale_days
        critical = age_days is None or age_days >= critical_days
        never = last_success is None
        if never and critical:
            status = "Critical / never inventoried"
        elif critical:
            status = "Critical"
        elif never and overdue:
            status = "Overdue / never inventoried"
        elif never:
            status = "Never / new asset"
        elif overdue:
            status = "Overdue"
        else:
            status = "Current"

        assets.append(
            {
                "id": int(asset.get("id") or 0),
                "name": str(asset.get("name") or asset.get("asset_tag") or ""),
                "serial": str(asset.get("serial") or ""),
                "assigned_to": compact_value(asset.get("assigned_to")),
                "agent_version": custom_field_value(asset, agent_version_field),
                "last_success": format_report_datetime(last_success, timezone),
                "last_success_raw": last_success_raw,
                "last_error": custom_field_value(asset, last_error_field)[:500],
                "age_days": age_days,
                "overdue": overdue,
                "critical": critical,
                "never": never,
                "status": status,
            }
        )

    assets.sort(
        key=lambda item: (
            not item["critical"],
            not item["overdue"],
            not item["never"],
            -(item["age_days"] if item["age_days"] is not None else 10**9),
            item["name"].casefold(),
        )
    )
    overdue_count = sum(1 for item in assets if item["overdue"])
    critical_count = sum(1 for item in assets if item["critical"])
    warning_count = sum(
        1 for item in assets if item["overdue"] and not item["critical"]
    )
    never_count = sum(1 for item in assets if item["never"])
    current_count = len(assets) - overdue_count

    limit = max(1, int(config.get("weekly_report_max_rows") or 250))
    rows = []
    for item in assets[:limit]:
        age = "Unknown" if item["age_days"] is None else f"{item['age_days']} day(s)"
        rows.append(
            "<tr>"
            f"<td>{html.escape(item['name'])}</td>"
            f"<td>{html.escape(item['serial'])}</td>"
            f"<td>{html.escape(item['assigned_to'])}</td>"
            f"<td>{html.escape(item['agent_version'])}</td>"
            f"<td>{html.escape(item['last_success'])}</td>"
            f"<td>{html.escape(age)}</td>"
            f"<td>{html.escape(item['status'])}</td>"
            f"<td>{html.escape(item['last_error'])}</td>"
            "</tr>"
        )

    omitted = max(0, len(assets) - len(rows))
    body = (
        "<h2>SnipeIT Inventory Weekly Report</h2>"
        f"<p>Report date: {html.escape(local_now.strftime('%H:%M %d.%m.%Y'))}. "
        f"Inventory is overdue after {stale_days} days and critical after "
        f"{critical_days} days.</p>"
        f"<p><b>Total:</b> {len(assets)}; <b>Current:</b> {current_count}; "
        f"<b>Overdue 7-13 days:</b> {warning_count}; "
        f"<b>Critical 14+ days:</b> {critical_count}; "
        f"<b>Never inventoried:</b> {never_count}.</p>"
        "<table border='1' cellpadding='6'><tr><th>Computer</th><th>Serial</th>"
        "<th>Owner</th><th>Agent</th><th>Last inventory</th><th>Age</th>"
        "<th>Status</th><th>Last error</th></tr>"
        + "".join(rows)
        + "</table>"
        + (f"<p>{omitted} additional asset(s) omitted by row limit.</p>" if omitted else "")
    )

    should_send = bool(assets) or bool(config.get("weekly_report_send_when_empty", True))
    sent = False
    alert_sent = False
    if report_due and should_send:
        is_critical = critical_count > 0
        subject_prefix = (
            config.get("weekly_alert_subject_prefix")
            if is_critical
            else config.get("weekly_report_subject_prefix")
        )
        recipient = (
            config.get("weekly_alert_mail_to")
            if is_critical and config.get("weekly_alert_mail_to")
            else config.get("weekly_report_mail_to")
        )
        subject = (
            f"{subject_prefix} WEEKLY: "
            f"{critical_count} critical / {warning_count} overdue / {len(assets)} total"
        )
        if dry_run:
            LOGGER.info("DRY RUN: Would send %s", subject)
        else:
            send_mail(config, str(recipient or ""), subject, body)
            store.set_meta("weekly_report_last_period", period)
            # Keep the old marker synchronized so a downgrade cannot send a
            # second critical digest for the same ISO week.
            store.set_meta("weekly_alert_last_period", period)
            sent = True
            alert_sent = is_critical
    elif report_due and not dry_run:
        store.set_meta("weekly_report_last_period", period)
        store.set_meta("weekly_alert_last_period", period)

    LOGGER.info(
        "Weekly inventory report period=%s total=%d current=%d warning=%d critical=%d never=%d sent=%s alert_sent=%s dry_run=%s",
        period,
        len(assets),
        current_count,
        warning_count,
        critical_count,
        never_count,
        sent,
        alert_sent,
        dry_run,
    )
    return {
        "period": period,
        "due": True,
        "sent": sent,
        "total": len(assets),
        "current": current_count,
        "overdue": overdue_count,
        "warning": warning_count,
        "critical": critical_count,
        "never": never_count,
        "alert_sent": alert_sent,
        "assets": assets,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="/etc/snipeit-maintenance/config.json")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--check-config", action="store_true")
    parser.add_argument("--check-ldap", action="store_true")
    parser.add_argument("--check-snipe", action="store_true")
    parser.add_argument("--offboarding-only", action="store_true")
    parser.add_argument("--users-deletion-only", action="store_true")
    parser.add_argument("--weekly-report-only", action="store_true")
    parser.add_argument("--force-weekly-report", action="store_true")
    parser.add_argument("--watchdog-only", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    config = load_config(args.config)
    configure_logging(str(config.get("log_path") or ""), args.verbose)
    if args.check_config:
        LOGGER.info("Configuration is valid. Maintenance version=%s", VERSION)
        return 0
    if args.check_ldap:
        LOGGER.info("LDAP helper is valid: terminated users=%d", len(run_ldap_helper(config)))
        return 0
    api = SnipeApi(config, dry_run=args.dry_run)
    if args.check_snipe:
        api.request("GET", "/api/v1/statuslabels?limit=1")
        LOGGER.info("Snipe-IT API connection is valid")
        return 0

    store = StateStore(str(config["state_database_path"]))
    failures = 0
    users_deletion_only = bool(args.users_deletion_only or args.offboarding_only)
    weekly_only = bool(args.weekly_report_only or args.watchdog_only)
    try:
        if bool(config.get("offboarding_enabled")) and not weekly_only:
            try:
                offboarding_run(api, store, config, dry_run=args.dry_run)
            except Exception:
                failures += 1
                LOGGER.exception("Users Deletion run failed")
        if bool(config.get("weekly_report_enabled")) and not users_deletion_only:
            try:
                weekly_report_run(
                    api,
                    store,
                    config,
                    dry_run=args.dry_run,
                    force=args.force_weekly_report,
                )
            except Exception:
                failures += 1
                LOGGER.exception("Weekly inventory report run failed")
    finally:
        try:
            removed = store.cleanup(
                int(config.get("maintenance_database_retention_days") or 0)
            )
            if removed:
                LOGGER.info(
                    "Maintenance database retention removed %d old row(s)", removed
                )
        except Exception:
            failures += 1
            LOGGER.exception("Maintenance database retention failed")
        finally:
            store.close()
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception:
        LOGGER.exception("Maintenance fatal error")
        raise SystemExit(1)
