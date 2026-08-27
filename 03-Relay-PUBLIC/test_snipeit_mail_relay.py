#!/usr/bin/env python3

import base64
import datetime as dt
import email.policy
import hashlib
import hmac
import importlib.util
import json
import sys
import tempfile
import unittest
from email.message import EmailMessage
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("snipeit_mail_relay.py")
SPEC = importlib.util.spec_from_file_location("snipeit_mail_relay", MODULE_PATH)
relay = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules["snipeit_mail_relay"] = relay
SPEC.loader.exec_module(relay)

MIGRATION_PATH = Path(__file__).with_name("migrate_inventory_time_display.py")
MIGRATION_SPEC = importlib.util.spec_from_file_location("migrate_inventory_time_display", MIGRATION_PATH)
migration = importlib.util.module_from_spec(MIGRATION_SPEC)
assert MIGRATION_SPEC.loader
MIGRATION_SPEC.loader.exec_module(migration)

NOTES_MIGRATION_PATH = Path(__file__).with_name("migrate_inventory_notes_display.py")
NOTES_MIGRATION_SPEC = importlib.util.spec_from_file_location(
    "migrate_inventory_notes_display",
    NOTES_MIGRATION_PATH,
)
notes_migration = importlib.util.module_from_spec(NOTES_MIGRATION_SPEC)
assert NOTES_MIGRATION_SPEC.loader
NOTES_MIGRATION_SPEC.loader.exec_module(notes_migration)


SECRET = "test-relay-secret"


def sample_payload(disposition="assigned"):
    return {
        "payload_schema": "snipeit.inventory.payload/v1",
        "schema_version": 1,
        "event_id": "a" * 64,
        "snipeit_avail": "no",
        "observed_at": "2026-07-21T10:00:00+03:00",
        "report_date": "2026-07-21 10:00:00 +03:00",
        "agent_version": "1.3.1",
        "computer_name": "LAPTOP-045",
        "domain": "ad.example.internal",
        "serial_number": "MP2FL58C",
        "identity": {
            "raw_username": "userold",
            "detected_username": "u.user",
            "observed_account": "EXAMPLE\\u.user",
            "source": "Win32_ComputerSystem.UserName",
            "confidence": 90,
            "resolution_method": "old_format",
        },
        "hardware": {
            "manufacturer": "LENOVO",
            "model": "21DH",
            "cpu_name": "CPU",
            "cpu_summary": "CPU (12C/16T)",
            "ram_summary": "2 x 8 GB, 6400 MT/s (3200 MHz clock)",
            "os_summary": "Windows 11 Pro (build 26200)",
            "storage_summary": "SSD 477 GB",
        },
        "disposition": {"requested": disposition, "reason": "user_checkout"},
    }


def envelope_text(payload):
    payload_bytes = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return json.dumps(
        {
            "envelope_schema": "snipeit.inventory.relay/v1",
            "schema_version": 1,
            "payload_encoding": "base64-json-utf8",
            "payload": base64.b64encode(payload_bytes).decode("ascii"),
            "hmac_sha256": hmac.new(SECRET.encode(), payload_bytes, hashlib.sha256).hexdigest(),
        },
        separators=(",", ":"),
    )


def mail_bytes(payload, subject_prefix="[SNIPEIT-RELAY]"):
    message = EmailMessage()
    message["From"] = "inventory@example.com"
    message["To"] = "inventory@example.com"
    message["Subject"] = f"{subject_prefix} LAPTOP-045 aaaaaaaaaaaaaaaa"
    message["X-SnipeIT-Relay"] = "1"
    message["X-SnipeIT-Avail"] = "no"
    message["X-SnipeIT-Event-ID"] = payload["event_id"]
    message.set_content("relay")
    message.add_attachment(
        envelope_text(payload).encode("utf-8"),
        maintype="application",
        subtype="json",
        filename="LAPTOP-045.snipeit-relay.json",
    )
    return message.as_bytes(policy=email.policy.default)


class FakeApi:
    payload = staticmethod(relay.SnipeApi.payload)

    def __init__(self, disposition="assigned"):
        self.config = {
            "default_status_id": 8,
            "stock_status_id": 1,
            "default_category_id": 1,
            "default_manufacturer_id": 1,
            "default_fieldset_id": 2,
            "stale_grace_seconds": 5,
            "display_timezone": "Europe/Moscow",
            "custom_fields": {
                "ram": "ram_field",
                "cpu": "cpu_field",
                "os": "os_field",
                "storage": "storage_field",
                "agent_version": "agent_field",
                "last_success": "success_field",
                "last_error": "error_field",
            },
        }
        self.dry_run = False
        self.calls = []
        self.existing = disposition == "stock"
        self.assigned = 77 if self.existing else None

    def find_asset(self, serial, computer_name):
        if self.existing:
            return {"id": 55, "assigned_to": {"id": self.assigned}, "status_label": {"id": 8}}
        return None

    def get_asset(self, asset_id):
        return {
            "id": asset_id,
            "assigned_to": {"id": self.assigned} if self.assigned else None,
            "status_label": {"id": 8},
            "updated_at": "2026-07-20T10:00:00+03:00",
        }

    def find_user(self, username):
        return {"id": 99, "username": username, "activated": True}

    def run_ldap_sync(self):
        self.calls.append(("LDAP", "", None, False))

    def model_id(self, model, manufacturer):
        return 7

    def request(self, method, path, body=None, form=False):
        self.calls.append((method, path, body, form))
        if path == "/api/v1/hardware" and method == "POST":
            return {"status": "success", "payload": {"id": 55}}
        if path.endswith("/checkin"):
            self.assigned = None
        if path.endswith("/checkout"):
            self.assigned = int(body["assigned_user"])
        return {"status": "success"}


class RelayTests(unittest.TestCase):
    def test_sid_identity_is_ignored_without_snipe_api_calls(self):
        payload = sample_payload()
        sid = "S-1-5-21-695948987-2019328260-3510634645-2110"
        payload["identity"]["raw_username"] = sid
        payload["identity"]["detected_username"] = sid
        payload["identity"]["observed_account"] = sid
        api = FakeApi(disposition="stock")

        with self.assertRaisesRegex(relay.IgnoredEvent, "invalid_identity_username"):
            relay.apply_payload(api, payload)

        self.assertEqual(api.calls, [])

    def test_sid_in_stock_reason_is_ignored_without_snipe_api_calls(self):
        payload = sample_payload(disposition="stock")
        payload["identity"]["detected_username"] = ""
        payload["disposition"]["reason"] = (
            "snipe_user_missing:S-1-5-21-695948987-2019328260-3510634645-2110"
        )
        api = FakeApi(disposition="stock")

        with self.assertRaisesRegex(relay.IgnoredEvent, "invalid_identity_reason"):
            relay.apply_payload(api, payload)

        self.assertEqual(api.calls, [])

    def test_preserve_disposition_updates_inventory_without_reassignment(self):
        payload = sample_payload(disposition="preserve")
        payload["identity"]["raw_username"] = ""
        payload["identity"]["detected_username"] = ""
        payload["disposition"]["reason"] = "identity_unresolved_preserve_assignment"
        api = FakeApi(disposition="stock")

        result, asset_id = relay.apply_payload(api, payload)

        self.assertEqual((result, asset_id), ("preserve:identity_unresolved", 55))
        paths = [call[1] for call in api.calls]
        self.assertIn("/api/v1/hardware/55", paths)
        self.assertFalse(any(path.endswith("/checkin") for path in paths))
        self.assertFalse(any(path.endswith("/checkout") for path in paths))

    def test_sid_message_is_completed_as_ignored(self):
        payload = sample_payload()
        payload["identity"]["detected_username"] = (
            "S-1-5-21-695948987-2019328260-3510634645-2110"
        )
        with tempfile.TemporaryDirectory() as directory:
            store = relay.EventStore(str(Path(directory) / "events.sqlite3"))
            try:
                status, event_id = relay.process_message(
                    mail_bytes(payload),
                    {
                        "allowed_from": ["inventory@example.com"],
                        "subject_prefix": "[SNIPEIT-RELAY]",
                        "legacy_relay_subject_prefixes": [],
                        "hmac_secret": SECRET,
                        "max_message_bytes": 2 * 1024 * 1024,
                    },
                    FakeApi(disposition="stock"),
                    store,
                )
                self.assertEqual(status, "ignored")
                self.assertTrue(store.completed(event_id))
            finally:
                store.close()

    def test_os_summary_normalization_removes_localized_and_broken_text(self):
        self.assertEqual(
            relay.normalize_os_summary(
                "?????????? Windows 11 Pro ??? ??????? ????????",
                os_build="26200",
            ),
            "Windows 11 Pro (build 26200)",
        )
        self.assertEqual(
            relay.normalize_os_summary(
                "Windows 11 Pro для рабочих станций (build 26200)",
            ),
            "Windows 11 Pro (build 26200)",
        )

    def test_agent_notes_migration_removes_broken_text_and_iso(self):
        notes = "\n".join(
            (
                "Auto inventory by PCInventoryAgent",
                "Updated: 2026-07-27T16:54:38.1950637+03:00",
                "Inventory timestamp: 2026-07-27T16:54:38.1950637+03:00",
                "",
                "Computer: LAPTOP-001",
                "OS: ?????????? Windows 11 Pro ??? ??????? ????????",
            )
        )
        migrated = notes_migration.sanitize_auto_notes(
            notes,
            "Windows 11 Pro (build 26200)",
        )
        self.assertIsNotNone(migrated)
        self.assertTrue(migrated.startswith("Auto inventory by SnipeIT Inventory Agent"))
        self.assertIn("Updated: 27.07.2026 16:54:38", migrated)
        self.assertIn("OS: Windows 11 Pro (build 26200)", migrated)
        self.assertNotIn("Inventory timestamp:", migrated)
        self.assertNotIn("????", migrated)
        self.assertNotIn("+03:00", migrated)
        self.assertIsNone(
            notes_migration.sanitize_auto_notes(
                migrated,
                "Windows 11 Pro (build 26200)",
            )
        )
        asset = {
            "notes": migrated,
            "custom_fields": {
                "OS": {
                    "field": "os_field",
                    "value": "Windows 11 Pro ??? ??????? ??????? (build 26200)",
                }
            },
        }
        self.assertEqual(
            notes_migration.migration_body(asset, "os_field", "Europe/Moscow"),
            {"os_field": "Windows 11 Pro (build 26200)"},
        )

    def test_hmac_envelope(self):
        payload = sample_payload()
        decoded = relay.decode_envelope(envelope_text(payload), SECRET)
        self.assertEqual(decoded["event_id"], payload["event_id"])
        self.assertEqual(decoded["snipeit_avail"], "no")

    def test_folded_event_id_header_is_normalized(self):
        self.assertEqual(
            relay.normalize_header_token("aaaa\n bbbb\tcccc"),
            "aaaabbbbcccc",
        )

    def test_bad_hmac_rejected(self):
        wrapper = json.loads(envelope_text(sample_payload()))
        wrapper["hmac_sha256"] = "0" * 64
        with self.assertRaises(relay.RelayError):
            relay.decode_envelope(json.dumps(wrapper), SECRET)

    def test_assigned_asset_creation(self):
        api = FakeApi("assigned")
        result, asset_id = relay.apply_payload(api, sample_payload("assigned"))
        self.assertEqual(asset_id, 55)
        self.assertEqual(result, "assigned:u.user")
        self.assertTrue(any(method == "POST" and path == "/api/v1/hardware" for method, path, _, _ in api.calls))
        create_call = next(call for call in api.calls if call[0:2] == ("POST", "/api/v1/hardware"))
        self.assertNotIn("asset_tag", create_call[2])
        self.assertEqual(create_call[2]["os_field"], "Windows 11 Pro (build 26200)")
        self.assertTrue(any(path.endswith("/checkout") and form for _, path, _, form in api.calls))

    def test_stock_checkin(self):
        api = FakeApi("stock")
        payload = sample_payload("stock")
        payload["disposition"]["reason"] = "ad_description_terminated:user"
        result, asset_id = relay.apply_payload(api, payload)
        self.assertEqual(asset_id, 55)
        self.assertTrue(result.startswith("stock:"))
        self.assertTrue(any(path.endswith("/checkin") for _, path, _, _ in api.calls))

    def test_stale_time_extraction(self):
        asset = {
            "updated_at": {"datetime": "2026-07-21T09:00:00+03:00"},
            "custom_fields": {
                "Last successful inventory": {
                    "field": "success_field",
                    "value": "2026-07-21T10:00:00+03:00",
                }
            },
        }
        latest = relay.extract_asset_latest_time(asset, "success_field")
        self.assertEqual(latest, dt.datetime(2026, 7, 21, 7, 0, tzinfo=dt.timezone.utc))

    def test_human_inventory_timestamp_format(self):
        self.assertEqual(
            relay.format_inventory_display_time("2026-07-27T16:54:38.1950637+03:00"),
            "16:54 27.07.2026",
        )
        self.assertEqual(
            relay.format_inventory_display_time("2026-07-27T13:54:38Z"),
            "16:54 27.07.2026",
        )
        self.assertEqual(
            relay.format_inventory_notes_time("2026-07-27T13:54:38Z"),
            "27.07.2026 16:54:38",
        )

        notes = relay.build_notes(
            {
                "observed_at": "2026-07-27T13:54:38Z",
                "computer_name": "LAPTOP-001",
                "serial_number": "SERIAL-001",
                "event_id": "event-001",
                "hardware": {},
            },
            "o.kokoreva",
        )
        self.assertIn("Observed: 27.07.2026 16:54:38", notes)
        self.assertNotIn("T13:54:38", notes)
        self.assertNotIn("+03:00", notes)

    def test_note_timestamp_preserves_exact_stale_comparison(self):
        asset = {
            "updated_at": {"datetime": "2026-07-27T16:55:00+03:00"},
            "notes": "Auto inventory\nInventory timestamp: 2026-07-27T16:54:38.1950637+03:00",
            "custom_fields": {
                "Last successful inventory": {
                    "field": "success_field",
                    "value": "16:54\n27.07.2026",
                }
            },
        }
        latest = relay.extract_asset_latest_time(asset, "success_field")
        self.assertEqual(
            latest,
            dt.datetime(2026, 7, 27, 13, 54, 38, 195063, tzinfo=dt.timezone.utc),
        )

        human_asset = {
            "notes": "Auto inventory\nUpdated: 27.07.2026 16:54:38",
            "custom_fields": {},
        }
        human_latest = relay.extract_asset_latest_time(human_asset, "success_field")
        self.assertEqual(
            human_latest,
            dt.datetime(2026, 7, 27, 13, 54, 38, tzinfo=dt.timezone.utc),
        )

    def test_timestamp_migration_writes_compact_display_only(self):
        asset = {
            "notes": "Legacy asset",
            "custom_fields": {
                "Last successful inventory": {
                    "field": "success_field",
                    "value": "2026-07-27T16:54:38.1950637+03:00",
                }
            },
        }
        body = migration.migration_body(asset, "success_field")
        self.assertEqual(body, {"success_field": "16:54 27.07.2026"})

    def test_timestamp_migration_is_idempotent(self):
        asset = {
            "custom_fields": {
                "Last successful inventory": {
                    "field": "success_field",
                    "value": "16:54 27.07.2026",
                }
            }
        }
        self.assertIsNone(migration.migration_body(asset, "success_field"))

    def test_timestamp_migration_converts_intermediate_two_line_display(self):
        asset = {
            "custom_fields": {
                "Last successful inventory": {
                    "field": "success_field",
                    "value": "16:54\n27.07.2026",
                }
            }
        }
        self.assertEqual(
            migration.migration_body(asset, "success_field"),
            {"success_field": "16:54 27.07.2026"},
        )

    def test_inventory_time_wins_over_partial_relay_update(self):
        asset = {
            "updated_at": {"datetime": "2026-07-21T10:05:00+03:00"},
            "custom_fields": {
                "Last successful inventory": {
                    "field": "success_field",
                    "value": "2026-07-21T10:00:00+03:00",
                }
            },
        }
        latest = relay.extract_asset_latest_time(asset, "success_field")
        self.assertEqual(latest, dt.datetime(2026, 7, 21, 7, 0, tzinfo=dt.timezone.utc))

    def test_partial_relay_retry_can_finish_checkout(self):
        class PartialRetryApi(FakeApi):
            def __init__(self):
                super().__init__("stock")
                self.assigned = None

            def get_asset(self, asset_id):
                return {
                    "id": asset_id,
                    "assigned_to": None,
                    "status_label": {"id": 8},
                    "updated_at": "2026-07-21T10:05:00+03:00",
                    "custom_fields": {
                        "Last successful inventory": {
                            "field": "success_field",
                            "value": "2026-07-21T10:00:00+03:00",
                        }
                    },
                }

        api = PartialRetryApi()
        result, _ = relay.apply_payload(api, sample_payload("assigned"))
        self.assertEqual(result, "assigned:u.user")
        self.assertTrue(any(path.endswith("/checkout") for _, path, _, _ in api.calls))

    def test_newer_direct_inventory_makes_relay_stale(self):
        class NewerInventoryApi(FakeApi):
            def __init__(self):
                super().__init__("stock")

            def get_asset(self, asset_id):
                return {
                    "id": asset_id,
                    "assigned_to": {"id": 77},
                    "status_label": {"id": 8},
                    "custom_fields": {
                        "Last successful inventory": {
                            "field": "success_field",
                            "value": "2026-07-21T11:00:00+03:00",
                        }
                    },
                }

        with self.assertRaises(relay.StaleEvent):
            relay.apply_payload(NewerInventoryApi(), sample_payload("assigned"))

    def test_message_idempotency(self):
        payload = sample_payload()
        config = {
            "max_message_bytes": 2 * 1024 * 1024,
            "allowed_from": ["inventory@example.com"],
            "subject_prefix": "[SNIPEIT-RELAY]",
            "hmac_secret": SECRET,
        }
        with tempfile.TemporaryDirectory() as directory:
            store = relay.EventStore(str(Path(directory) / "events.sqlite3"))
            api = FakeApi("assigned")
            first, event_id = relay.process_message(mail_bytes(payload), config, api, store)
            second, duplicate_id = relay.process_message(mail_bytes(payload), config, api, store)
            store.close()
        self.assertEqual(first, "processed")
        self.assertEqual(second, "duplicate")
        self.assertEqual(event_id, duplicate_id)

    def test_canonical_relay_subject_is_accepted(self):
        payload = sample_payload()
        config = {
            "max_message_bytes": 2 * 1024 * 1024,
            "allowed_from": ["inventory@example.com"],
            "subject_prefix": "[SNIPEIT-INVENTORY] RELAY:",
            "hmac_secret": SECRET,
        }
        with tempfile.TemporaryDirectory() as directory:
            store = relay.EventStore(str(Path(directory) / "events.sqlite3"))
            try:
                status, _ = relay.process_message(
                    mail_bytes(payload, "[SNIPEIT-INVENTORY] RELAY:"),
                    config,
                    FakeApi("assigned"),
                    store,
                )
            finally:
                store.close()
        self.assertEqual(status, "processed")

    def test_old_config_is_normalized_to_clear_folder_names(self):
        config = {
            "imap_host": "imap.example.com",
            "imap_user": "inventory@example.com",
            "imap_password": "password",
            "hmac_secret": SECRET,
            "snipe_url": "https://127.0.0.1",
            "snipe_token": "token",
            "imap_folder": "Relay",
            "processed_folder": "Processed",
            "rejected_folder": "Rejected",
            "reports_folder": "Reports",
            "alerts_folder": "Alerts",
            "alert_subject_prefix": "[SNIPEIT-INVENTORY] ALERT:",
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(config), encoding="utf-8")
            loaded = relay.load_config(str(path))

        self.assertEqual(loaded["imap_folder"], "Offline Relay")
        self.assertEqual(loaded["processed_folder"], "Processed Events")
        self.assertEqual(loaded["rejected_folder"], "Rejected Events")
        self.assertEqual(loaded["weekly_reports_folder"], "! Weekly Reports")
        self.assertEqual(loaded["warnings_folder"], "Warnings")
        self.assertEqual(loaded["errors_folder"], "Errors")
        self.assertEqual(loaded["alerts_folder"], "Alerts")
        self.assertEqual(loaded["alert_subject_prefix"], "[SNIPEIT-INVENTORY] ERROR:")
        self.assertNotIn("Alerts", loaded["legacy_error_folders"])
        self.assertIn("[PCINV-ALERT]", loaded["human_alert_subject_prefixes"])
        self.assertNotIn("[PCINV-ALERT]", loaded["legacy_error_subject_prefixes"])

    def test_nested_imap_folder_parsing(self):
        delimiter, name = relay.parse_imap_list_line(
            b'(\\HasNoChildren) "|" "SNIPEIT Autoinv|SnipeIT Relay"'
        )
        self.assertEqual(delimiter, "|")
        self.assertEqual(name, "SNIPEIT Autoinv|SnipeIT Relay")

    def test_imap_folder_refresh_ignores_empty_list_items(self):
        class FakeImapClient:
            def list(self):
                return "OK", [
                    b"",
                    b'(\\HasNoChildren) "|" "SNIPEIT Autoinv|SnipeIT Relay"',
                ]

        mailbox = object.__new__(relay.ImapMailbox)
        mailbox.client = FakeImapClient()
        mailbox.delimiter = "/"
        mailbox.folders = {}
        mailbox.refresh_folders()

        self.assertEqual(mailbox.delimiter, "|")
        self.assertEqual(
            mailbox.folders["snipeit autoinv|snipeit relay"],
            "SNIPEIT Autoinv|SnipeIT Relay",
        )

    def test_exact_folder_case_wins_when_yandex_has_case_duplicates(self):
        mailbox = object.__new__(relay.ImapMailbox)
        mailbox.delimiter = "|"
        mailbox.folder_names = ["SNIPEIT Inventory", "SnipeIT Inventory"]
        mailbox.folders = {"snipeit inventory": "SnipeIT Inventory"}

        self.assertEqual(
            mailbox.existing_folder("SNIPEIT Inventory"),
            "SNIPEIT Inventory",
        )
        self.assertEqual(
            mailbox.existing_folder("SnipeIT Inventory"),
            "SnipeIT Inventory",
        )
        self.assertEqual(
            mailbox.existing_folder_exact("SNIPEIT Inventory"),
            "SNIPEIT Inventory",
        )
        mailbox.folder_names = ["SnipeIT Inventory"]
        self.assertEqual(mailbox.existing_folder_exact("SNIPEIT Inventory"), "")

    def test_parent_folder_with_children_is_never_deleted(self):
        mailbox = object.__new__(relay.ImapMailbox)
        mailbox.delimiter = "|"
        mailbox.folder_names = [
            "SnipeIT Inventory",
            "SnipeIT Inventory|Reports",
        ]
        mailbox.folders = {
            name.casefold(): name for name in mailbox.folder_names
        }
        mailbox.search_uids = lambda criteria, folder="": []

        self.assertFalse(mailbox.delete_empty_folder("SnipeIT Inventory"))

    def test_relay_search_uses_header_when_yandex_subject_search_misses(self):
        class FakeImapClient:
            def __init__(self):
                self.args = []

            def uid(self, *args):
                self.args.append(args)
                if "HEADER X-SnipeIT-Relay" in str(args):
                    return "OK", [b"2 10 3"]
                return "OK", [b""]

        mailbox = object.__new__(relay.ImapMailbox)
        mailbox.client = FakeImapClient()
        mailbox.config = {
            "max_messages_per_run": 2,
            "subject_prefix": "[SNIPEIT-RELAY]",
        }
        uids = mailbox.relay_uids()
        self.assertEqual(uids, [b"10", b"3"])
        self.assertNotIn("UNSEEN", str(mailbox.client.args))
        self.assertIn("X-SnipeIT-Relay", str(mailbox.client.args))
        self.assertIn("SNIPEIT", str(mailbox.client.args))
        self.assertIn("RELAY", str(mailbox.client.args))
        self.assertNotIn('(SUBJECT "[SNIPEIT-RELAY]"', str(mailbox.client.args))

    def test_imap_search_reconnects_after_transient_failure(self):
        class FakeImapClient:
            def __init__(self):
                self.calls = 0

            def uid(self, *args):
                self.calls += 1
                if self.calls == 1:
                    return "NO", [b"temporary server error"]
                return "OK", [b"12 7"]

        mailbox = object.__new__(relay.ImapMailbox)
        mailbox.client = FakeImapClient()
        mailbox.config = {
            "max_messages_per_run": 10,
            "imap_command_retries": 3,
            "imap_retry_delay_seconds": 0,
        }
        mailbox.selected_folder = "INBOX"
        reconnects = []
        mailbox.reconnect = lambda: reconnects.append(True)

        self.assertEqual(mailbox.search_uids("ALL", "INBOX"), [b"12", b"7"])
        self.assertEqual(len(reconnects), 1)

    def test_unrelated_imap_false_positive_is_not_relay_candidate(self):
        unrelated = EmailMessage()
        unrelated["From"] = "person@example.com"
        unrelated["Subject"] = "Quarterly meeting"
        unrelated.set_content("ordinary mail")

        malformed_relay = EmailMessage()
        malformed_relay["From"] = "inventory@example.com"
        malformed_relay["Subject"] = "[SNIPEIT-RELAY] LAPTOP-001 event"
        malformed_relay.set_content("broken relay")

        config = {"subject_prefix": "[SNIPEIT-RELAY]"}
        self.assertFalse(
            relay.is_relay_candidate(
                unrelated.as_bytes(policy=email.policy.default), config
            )
        )
        self.assertTrue(
            relay.is_relay_candidate(
                malformed_relay.as_bytes(policy=email.policy.default), config
            )
        )

    def test_process_imap_leaves_unrelated_false_positive_untouched(self):
        unrelated = EmailMessage()
        unrelated["From"] = "person@example.com"
        unrelated["Subject"] = "Quarterly meeting"
        unrelated.set_content("ordinary mail")

        class FakeMailbox:
            inbox_folder = "INBOX"
            source_folder = "SNIPEIT Autoinv|SnipeIT Relay"
            processed_folder = "SNIPEIT Autoinv|SnipeIT Processed"
            rejected_folder = "SNIPEIT Autoinv|SnipeIT Rejected"

            def __init__(self):
                self.moves = []

            def relay_items(self):
                return [(self.inbox_folder, b"123")]

            def fetch(self, uid, folder):
                return unrelated.as_bytes(policy=email.policy.default)

            def move(self, uid, target, source_folder=""):
                self.moves.append((uid, target, source_folder))

            def close(self):
                pass

        class FakeStore:
            def cleanup_due(self, interval_hours):
                return False

            def close(self):
                pass

        mailbox = FakeMailbox()
        config = {
            "database_path": "unused.sqlite3",
            "subject_prefix": "[SNIPEIT-RELAY]",
        }
        with (
            mock.patch.object(relay, "ImapMailbox", return_value=mailbox),
            mock.patch.object(relay, "EventStore", return_value=FakeStore()),
            mock.patch.object(relay, "SnipeApi", return_value=object()),
            mock.patch.object(relay, "sort_human_reports", return_value=0),
            mock.patch.object(relay, "send_due_alerts", return_value=0),
        ):
            result = relay.process_imap(config, dry_run=False)

        self.assertEqual(result, 0)
        self.assertEqual(mailbox.moves, [])

    def test_process_file_dry_run_does_not_create_or_update_event_database(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            message_path = root / "relay.eml"
            database_path = root / "events.sqlite3"
            message_path.write_bytes(mail_bytes(sample_payload()))
            config = {
                "database_path": str(database_path),
                "allowed_from": ["inventory@example.com"],
                "subject_prefix": "[SNIPEIT-RELAY]",
                "legacy_relay_subject_prefixes": [],
                "hmac_secret": SECRET,
                "max_message_bytes": 2 * 1024 * 1024,
            }

            with mock.patch.object(
                relay,
                "SnipeApi",
                return_value=FakeApi(disposition="stock"),
            ):
                result = relay.process_file(str(message_path), config, dry_run=True)

            self.assertEqual(result, 0)
            self.assertFalse(database_path.exists())

    def test_relay_scans_inbox_and_staging_folder(self):
        mailbox = object.__new__(relay.ImapMailbox)
        mailbox.inbox_folder = "INBOX"
        mailbox.source_folder = "SNIPEIT Autoinv|SnipeIT Relay"
        searches = []
        mailbox.relay_uids = lambda folder="": [b"10"]
        mailbox.search_uids = lambda criteria, folder="": (
            searches.append((criteria, folder)) or [b"20"]
        )
        self.assertEqual(
            mailbox.relay_items(),
            [
                ("INBOX", b"10"),
                ("SNIPEIT Autoinv|SnipeIT Relay", b"20"),
            ],
        )
        self.assertEqual(
            searches,
            [("ALL", "SNIPEIT Autoinv|SnipeIT Relay")],
        )

    def test_human_report_sorting(self):
        report = EmailMessage()
        report["From"] = "inventory@example.com"
        report["Subject"] = "[PCINV-REPORT] FORCED: LAPTOP-045"
        report.set_content("report")

        warning = EmailMessage()
        warning["From"] = "inventory@example.com"
        warning["Subject"] = "[SNIPEIT-INVENTORY] WARNING: LAPTOP-046"
        warning.set_content("warning")

        error = EmailMessage()
        error["From"] = "inventory@example.com"
        error["Subject"] = "PC Inventory ERROR: LAPTOP-047"
        error.set_content("error")

        class FakeMailbox:
            inbox_folder = "INBOX"
            inventory_folder = "SNIPEIT Autoinv|Inventory"
            inventory_reports_folder = "SNIPEIT Autoinv|Inventory Reports"
            reports_folder = "SnipeIT Inventory|Reports"
            weekly_reports_folder = "SnipeIT Inventory|! Weekly Reports"
            warnings_folder = "SnipeIT Inventory|Warnings"
            alerts_folder = "SnipeIT Inventory|Alerts"
            errors_folder = "SnipeIT Inventory|Errors"

            def __init__(self):
                self.moves = []

            def search_uids(self, criteria, folder):
                if "PCINV" in criteria:
                    return [b"1"]
                if "SNIPEIT-INVENTORY" in criteria:
                    return [b"2"]
                if "PC Inventory" in criteria:
                    return [b"3"]
                return []

            def fetch(self, uid, folder):
                messages = {b"1": report, b"2": warning, b"3": error}
                return messages[uid].as_bytes(policy=email.policy.default)

            def move(self, uid, target, source_folder=""):
                self.moves.append((uid, target, source_folder))

        mailbox = FakeMailbox()
        failures = relay.sort_human_reports(
            mailbox,
            {
                "sort_human_reports": True,
                "report_subject_prefix": "[PCINV-REPORT]",
                "warning_subject_prefix": "[SNIPEIT-INVENTORY] WARNING:",
                "error_subject_prefix": "[SNIPEIT-INVENTORY] ERROR:",
                "report_allowed_from": ["inventory@example.com"],
            },
            dry_run=False,
        )
        self.assertEqual(failures, 0)
        self.assertEqual(
            mailbox.moves,
            [
                (b"3", mailbox.errors_folder, "INBOX"),
                (b"2", mailbox.warnings_folder, "INBOX"),
                (b"1", mailbox.reports_folder, "INBOX"),
            ],
        )

    def test_yandex_safe_search_terms_do_not_depend_on_square_brackets(self):
        config = {
            "imap_host": "imap.example.com",
            "imap_user": "inventory@example.com",
            "imap_password": "password",
            "hmac_secret": SECRET,
            "snipe_url": "https://127.0.0.1",
            "snipe_token": "token",
            "human_report_search_terms": ["[PCINV-"],
            "relay_search_terms": ["[SNIPEIT-RELAY]"],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(config), encoding="utf-8")
            loaded = relay.load_config(str(path))

        self.assertIn("PCINV", loaded["human_report_search_terms"])
        self.assertIn("SNIPEIT-INVENTORY", loaded["human_report_search_terms"])
        self.assertIn("SNIPEIT", loaded["relay_search_terms"])
        self.assertIn("RELAY", loaded["relay_search_terms"])
        self.assertFalse(
            any(item.startswith("[") for item in loaded["human_report_search_terms"])
        )
        self.assertFalse(any(item.startswith("[") for item in loaded["relay_search_terms"]))

    def test_human_alert_sorting_is_separate_from_errors(self):
        alert = email.message.EmailMessage()
        alert["From"] = "inventory@example.com"
        alert["Subject"] = "[SNIPEIT-INVENTORY] ALERT: USERS DELETION: 3 deleted"

        class FakeMailbox:
            inbox_folder = "INBOX"
            inventory_folder = "SnipeIT Inventory|Reports"
            inventory_reports_folder = "SnipeIT Inventory|Errors"
            reports_folder = "SnipeIT Inventory|Reports"
            weekly_reports_folder = "SnipeIT Inventory|! Weekly Reports"
            alerts_folder = "SnipeIT Inventory|Alerts"
            warnings_folder = "SnipeIT Inventory|Warnings"
            errors_folder = "SnipeIT Inventory|Errors"

            def __init__(self):
                self.moves = []

            def search_uids(self, criteria, folder):
                return [b"7"] if "SNIPEIT-INVENTORY" in criteria else []

            def fetch(self, uid, folder):
                return alert.as_bytes(policy=email.policy.default)

            def move(self, uid, target, source_folder=""):
                self.moves.append((uid, target, source_folder))

        mailbox = FakeMailbox()
        failures = relay.sort_human_reports(
            mailbox,
            {
                "sort_human_reports": True,
                "human_alert_subject_prefix": "[SNIPEIT-INVENTORY] ALERT:",
                "error_subject_prefix": "[SNIPEIT-INVENTORY] ERROR:",
                "report_allowed_from": ["inventory@example.com"],
            },
            dry_run=False,
        )
        self.assertEqual(failures, 0)
        self.assertEqual(
            mailbox.moves,
            [(b"7", mailbox.alerts_folder, "INBOX")],
        )

    def test_weekly_reports_are_moved_from_inbox_reports_and_alerts(self):
        subjects = {
            b"11": "[SNIPEIT-INVENTORY] REPORT: WEEKLY: 4 overdue / 120 total",
            b"12": "[SNIPEIT-INVENTORY] ALERT: WEEKLY: 2 critical",
            b"13": "[PCINV-ALERT] WATCHDOG: 8 computer(s) stale",
        }

        class FakeMailbox:
            inbox_folder = "INBOX"
            inventory_folder = "SnipeIT Inventory|Reports"
            reports_folder = "SnipeIT Inventory|Reports"
            alerts_folder = "SnipeIT Inventory|Alerts"
            weekly_reports_folder = "SnipeIT Inventory|! Weekly Reports"

            def __init__(self):
                self.moves = []

            def search_uids(self, criteria, folder):
                if "WEEKLY" in criteria:
                    return {
                        self.inbox_folder: [b"11"],
                        self.reports_folder: [],
                        self.alerts_folder: [b"12"],
                    }.get(folder, [])
                if "WATCHDOG" in criteria:
                    return [b"13"] if folder == self.reports_folder else []
                return []

            def fetch(self, uid, folder):
                message = EmailMessage()
                message["From"] = "inventory@example.com"
                message["Subject"] = subjects[uid]
                message.set_content("weekly")
                return message.as_bytes(policy=email.policy.default)

            def move(self, uid, target, source_folder=""):
                self.moves.append((uid, target, source_folder))

        mailbox = FakeMailbox()
        failures = relay.sort_weekly_reports(
            mailbox,
            {
                "sort_human_reports": True,
                "report_allowed_from": ["inventory@example.com"],
                "weekly_report_search_terms": ["WEEKLY", "WATCHDOG"],
                "max_messages_per_run": 200,
            },
            dry_run=False,
        )
        self.assertEqual(failures, 0)
        self.assertEqual(
            mailbox.moves,
            [
                (b"11", mailbox.weekly_reports_folder, mailbox.inbox_folder),
                (b"13", mailbox.weekly_reports_folder, mailbox.reports_folder),
                (b"12", mailbox.weekly_reports_folder, mailbox.alerts_folder),
            ],
        )

    def test_human_report_search_failure_is_deferred_without_failing_cycle(self):
        class FakeMailbox:
            inbox_folder = "INBOX"
            inventory_folder = "SnipeIT Inventory|Reports"
            inventory_reports_folder = "SnipeIT Inventory|Errors"
            reports_folder = "SnipeIT Inventory|Reports"
            warnings_folder = "SnipeIT Inventory|Warnings"
            errors_folder = "SnipeIT Inventory|Errors"

            def search_uids(self, criteria, folder):
                raise relay.RelayError("temporary Yandex search error")

        failures = relay.sort_human_reports(
            FakeMailbox(),
            {
                "sort_human_reports": True,
                "report_allowed_from": ["inventory@example.com"],
                "max_messages_per_run": 200,
            },
            dry_run=False,
        )
        self.assertEqual(failures, 0)

    def test_legacy_folder_migration_moves_only_known_exact_folders(self):
        class FakeMailbox:
            source_folder = "SnipeIT Inventory|Offline Relay"
            processed_folder = "SnipeIT Inventory|Processed Events"
            rejected_folder = "SnipeIT Inventory|Rejected Events"
            reports_folder = "SnipeIT Inventory|Reports"
            warnings_folder = "SnipeIT Inventory|Warnings"
            errors_folder = "SnipeIT Inventory|Errors"

            def __init__(self):
                self.messages = {
                    "SNIPEIT Inventory|Inventory": [b"1", b"2"],
                    "SNIPEIT Inventory|SnipeIT ERROR/WARN": [b"3"],
                    "SnipeIT Inventory|Alerts": [b"4"],
                    "SNIPEIT Inventory": [b"5"],
                }
                self.moves = []
                self.deleted = []

            def existing_folder(self, leaf, parent=""):
                candidate = f"{parent}|{leaf}" if parent else leaf
                return candidate if candidate in self.messages else ""

            def search_uids(self, criteria, folder=""):
                return list(self.messages.get(folder, []))

            def move(self, uid, target, source_folder=""):
                self.moves.append((uid, target, source_folder))
                self.messages[source_folder].remove(uid)

            def delete_empty_folder(self, folder):
                self.deleted.append(folder)
                return True

        mailbox = FakeMailbox()
        moved = relay.migrate_legacy_folders(
            mailbox,
            {
                "migrate_legacy_folders": True,
                "delete_empty_legacy_folders": True,
                "imap_parent_folder": "SnipeIT Inventory",
                "legacy_imap_parent_folders": ["SNIPEIT Inventory"],
                "legacy_relay_folders": ["SnipeIT Relay"],
                "legacy_processed_folders": ["SnipeIT Processed"],
                "legacy_rejected_folders": ["SnipeIT Rejected"],
                "legacy_reports_folders": ["Inventory"],
                "legacy_warning_folders": [],
                "legacy_error_folders": ["Alerts", "Inventory Reports", "SnipeIT ERROR/WARN"],
                "legacy_root_error_folders": ["SNIPEIT Inventory"],
                "legacy_migration_max_messages_per_run": 1000,
            },
        )
        self.assertEqual(moved, 5)
        self.assertEqual(
            mailbox.moves,
            [
                (b"1", mailbox.reports_folder, "SNIPEIT Inventory|Inventory"),
                (b"2", mailbox.reports_folder, "SNIPEIT Inventory|Inventory"),
                (b"3", mailbox.errors_folder, "SNIPEIT Inventory|SnipeIT ERROR/WARN"),
                (b"4", mailbox.errors_folder, "SnipeIT Inventory|Alerts"),
                (b"5", mailbox.errors_folder, "SNIPEIT Inventory"),
            ],
        )
        self.assertEqual(
            mailbox.deleted,
            [
                "SNIPEIT Inventory|Inventory",
                "SNIPEIT Inventory|SnipeIT ERROR/WARN",
                "SnipeIT Inventory|Alerts",
                "SNIPEIT Inventory",
            ],
        )

    def test_delayed_alert_is_only_due_once(self):
        with tempfile.TemporaryDirectory() as directory:
            store = relay.EventStore(str(Path(directory) / "events.sqlite3"))
            store.mark(
                "b" * 64,
                "LAPTOP-045",
                "2026-07-21T10:00:00+03:00",
                "processing",
                "started",
            )
            store.mark(
                "b" * 64,
                "LAPTOP-045",
                "2026-07-21T10:00:00+03:00",
                "failed",
                "temporary failure",
            )
            due = store.alerts_due(relay.utc_now() + dt.timedelta(seconds=1))
            self.assertEqual(len(due), 1)
            self.assertEqual(due[0]["attempts"], 1)
            store.mark_alert_sent("b" * 64)
            self.assertEqual(
                store.alerts_due(relay.utc_now() + dt.timedelta(days=1)),
                [],
            )
            store.close()

    def test_event_store_cleanup_keeps_unalerted_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            store = relay.EventStore(str(Path(directory) / "events.sqlite3"))
            old = (relay.utc_now() - dt.timedelta(days=400)).isoformat()
            rows = (
                ("c" * 64, "processed", "2026-01-01T00:00:00+00:00"),
                ("d" * 64, "failed", "2026-01-01T00:00:00+00:00"),
            )
            for event_id, status, observed_at in rows:
                store.mark(event_id, "LAPTOP-001", observed_at, status, status)
                store.connection.execute(
                    "UPDATE relay_events SET updated_at = ?, first_seen_at = ? WHERE event_id = ?",
                    (old, old, event_id),
                )
            store.connection.commit()

            self.assertEqual(store.cleanup(365), 1)
            remaining = store.connection.execute(
                "SELECT event_id FROM relay_events ORDER BY event_id"
            ).fetchall()
            self.assertEqual(remaining, [("d" * 64,)])
            store.close()

    def test_imap_retention_deletes_only_selected_old_messages(self):
        class FakeImapClient:
            def __init__(self):
                self.calls = []

            def select(self, folder, readonly=False):
                self.calls.append(("select", folder, readonly))
                return "OK", [b"2"]

            def uid(self, *args):
                self.calls.append(("uid",) + args)
                if args[0] == "search":
                    return "OK", [b"10 11"]
                return "OK", [b""]

            def expunge(self):
                self.calls.append(("expunge",))
                return "OK", []

        mailbox = object.__new__(relay.ImapMailbox)
        mailbox.client = FakeImapClient()
        mailbox.config = {"cleanup_max_messages_per_folder": 1000}
        mailbox.selected_folder = "SnipeIT Relay"
        count = mailbox.delete_before(
            "SnipeIT Processed",
            dt.datetime(2026, 7, 1, tzinfo=dt.timezone.utc),
        )
        self.assertEqual(count, 2)
        calls = mailbox.client.calls
        self.assertIn(("uid", "search", None, "BEFORE 01-Jul-2026"), calls)
        self.assertEqual(sum(1 for call in calls if call[:2] == ("uid", "store")), 2)
        self.assertNotIn("INBOX", str(calls))


if __name__ == "__main__":
    unittest.main()
