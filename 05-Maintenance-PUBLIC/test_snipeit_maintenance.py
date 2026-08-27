#!/usr/bin/env python3

import datetime as dt
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("snipeit_maintenance.py")
SPEC = importlib.util.spec_from_file_location("snipeit_maintenance", MODULE_PATH)
maintenance = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(maintenance)


class FakeStore:
    def __init__(self):
        self.actions = []

    def log_action(self, *args, **kwargs):
        self.actions.append((args, kwargs))


class FakeApi:
    def __init__(self, stubborn_accessory=False):
        self.calls = []
        self.hardware_done = False
        self.accessory_done = False
        self.license_done = False
        self.deleted = False
        self.stubborn_accessory = stubborn_accessory

    def paginate(self, path, limit=500):
        if path == "/api/v1/users":
            return [{"id": 42, "username": "i.ivanov", "ldap_import": True}]
        if path == "/api/v1/users/42/assets":
            return [] if self.hardware_done else [{"id": 101}]
        if path == "/api/v1/users/42/accessories":
            return [] if self.accessory_done else [{"id": 201}]
        if path == "/api/v1/accessories/201/checkedout":
            return [{"id": 501, "assigned_to": {"id": 42}}]
        if path == "/api/v1/users/42/licenses":
            return [] if self.license_done else [{"id": 301}]
        if path == "/api/v1/licenses/301/seats":
            return [{"id": 401, "assigned_user": {"id": 42}}]
        if path == "/api/v1/hardware":
            return []
        return []

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        if path == "/api/v1/hardware/101/checkin":
            self.hardware_done = True
        elif path == "/api/v1/accessories/501/checkin" and not self.stubborn_accessory:
            self.accessory_done = True
        elif path == "/api/v1/licenses/301/seats/401":
            self.license_done = True
        elif method == "DELETE" and path == "/api/v1/users/42":
            self.deleted = True
        return {"status": "success"}


class MaintenanceTests(unittest.TestCase):
    def test_full_offboarding_checks_everything_in_before_soft_delete(self):
        api = FakeApi()
        store = FakeStore()
        result = maintenance.offboard_user(
            api,
            store,
            {"stock_status_id": 1},
            "i.ivanov",
            42,
            "ad_disabled",
        )

        mutation_paths = [(item[0], item[1]) for item in api.calls]
        self.assertEqual(
            mutation_paths,
            [
                ("POST", "/api/v1/hardware/101/checkin"),
                ("PATCH", "/api/v1/hardware/101"),
                ("POST", "/api/v1/accessories/501/checkin"),
                ("PATCH", "/api/v1/licenses/301/seats/401"),
                ("DELETE", "/api/v1/users/42"),
            ],
        )
        self.assertTrue(api.deleted)
        self.assertEqual(result["assets"], [101])
        self.assertEqual(result["accessory_checkouts"], [501])
        self.assertEqual(result["license_seats"], [401])

    def test_remaining_assignment_blocks_user_delete(self):
        api = FakeApi(stubborn_accessory=True)
        with self.assertRaises(maintenance.OffboardingBlocked):
            maintenance.offboard_user(
                api,
                FakeStore(),
                {"stock_status_id": 1},
                "i.ivanov",
                42,
                "ad_disabled",
            )
        self.assertFalse(api.deleted)
        self.assertNotIn(("DELETE", "/api/v1/users/42"), [(a, b) for a, b, _ in api.calls])

    def test_candidate_requires_separated_confirmations(self):
        with tempfile.TemporaryDirectory() as directory:
            store = maintenance.StateStore(str(Path(directory) / "state.sqlite3"))
            try:
                start = dt.datetime(2026, 8, 11, 3, 0, tzinfo=dt.timezone.utc)
                first, created = store.observe_candidate(
                    "i.ivanov", 42, "ad_disabled", "CN=User", start, 12
                )
                early, _ = store.observe_candidate(
                    "i.ivanov",
                    42,
                    "ad_disabled",
                    "CN=User",
                    start + dt.timedelta(hours=1),
                    12,
                )
                confirmed, _ = store.observe_candidate(
                    "i.ivanov",
                    42,
                    "ad_disabled",
                    "CN=User",
                    start + dt.timedelta(hours=13),
                    12,
                )
            finally:
                store.close()

        self.assertTrue(created)
        self.assertEqual(first["confirmation_runs"], 1)
        self.assertEqual(early["confirmation_runs"], 1)
        self.assertEqual(confirmed["confirmation_runs"], 2)

    def test_continuous_30_day_disable_triggers_users_deletion(self):
        with tempfile.TemporaryDirectory() as directory:
            store = maintenance.StateStore(str(Path(directory) / "state.sqlite3"))
            api = FakeApi()
            config = {
                "offboarding_confirmation_runs": 2,
                "users_deletion_disabled_days": 30,
                "offboarding_confirmation_interval_hours": 12,
                "offboarding_max_users_per_run": 10,
                "offboarding_protected_usernames": ["^snipeit$"],
                "offboarding_digest_repeat_hours": 72,
                "users_deletion_mail_to": "it@example.com",
                "users_deletion_subject_prefix": "[SNIPEIT-INVENTORY] ALERT:",
                "stock_status_id": 1,
            }
            terminated = [
                {
                    "username": "i.ivanov",
                    "reason": "ad_disabled",
                    "distinguished_name": "CN=User,DC=example,DC=internal",
                }
            ]
            first_time = dt.datetime(2026, 8, 11, 3, 0, tzinfo=dt.timezone.utc)
            try:
                with mock.patch.object(maintenance, "run_ldap_helper", return_value=terminated), mock.patch.object(
                    maintenance, "send_mail"
                ), mock.patch.object(maintenance, "utc_now", return_value=first_time):
                    first = maintenance.offboarding_run(api, store, config)
                self.assertFalse(api.deleted)
                self.assertEqual(first["staged"], ["i.ivanov"])

                with mock.patch.object(maintenance, "run_ldap_helper", return_value=terminated), mock.patch.object(
                    maintenance, "send_mail"
                ), mock.patch.object(
                    maintenance,
                    "utc_now",
                    return_value=first_time + dt.timedelta(days=29),
                ):
                    second = maintenance.offboarding_run(api, store, config)
                self.assertFalse(api.deleted)

                with mock.patch.object(maintenance, "run_ldap_helper", return_value=terminated), mock.patch.object(
                    maintenance, "send_mail"
                ), mock.patch.object(
                    maintenance,
                    "utc_now",
                    return_value=first_time + dt.timedelta(days=30, hours=1),
                ):
                    third = maintenance.offboarding_run(api, store, config)
            finally:
                store.close()

        self.assertTrue(api.deleted)
        self.assertEqual([item["username"] for item in third["deleted"]], ["i.ivanov"])

    def test_reenabled_ad_user_resets_30_day_clock(self):
        with tempfile.TemporaryDirectory() as directory:
            store = maintenance.StateStore(str(Path(directory) / "state.sqlite3"))
            api = FakeApi()
            config = {
                "users_deletion_disabled_days": 30,
                "offboarding_confirmation_runs": 2,
                "offboarding_confirmation_interval_hours": 12,
                "offboarding_max_users_per_run": 10,
                "offboarding_protected_usernames": [],
                "offboarding_digest_repeat_hours": 168,
                "stock_status_id": 1,
            }
            terminated = [{"username": "i.ivanov", "reason": "ad_disabled"}]
            start = dt.datetime(2026, 8, 1, tzinfo=dt.timezone.utc)
            try:
                with mock.patch.object(maintenance, "run_ldap_helper", return_value=terminated), mock.patch.object(
                    maintenance, "utc_now", return_value=start
                ):
                    maintenance.offboarding_run(api, store, config)
                with mock.patch.object(maintenance, "run_ldap_helper", return_value=[]), mock.patch.object(
                    maintenance, "utc_now", return_value=start + dt.timedelta(days=10)
                ):
                    maintenance.offboarding_run(api, store, config)
                with mock.patch.object(maintenance, "run_ldap_helper", return_value=terminated), mock.patch.object(
                    maintenance, "utc_now", return_value=start + dt.timedelta(days=31)
                ):
                    result = maintenance.offboarding_run(api, store, config)
            finally:
                store.close()
        self.assertFalse(api.deleted)
        self.assertEqual(result["staged"], ["i.ivanov"])

    def test_local_snipe_user_is_never_offboarded_from_ad_match(self):
        class LocalUserApi(FakeApi):
            def paginate(self, path, limit=500):
                if path == "/api/v1/users":
                    return [{"id": 42, "username": "i.ivanov", "ldap_import": False}]
                return super().paginate(path, limit)

        with tempfile.TemporaryDirectory() as directory:
            store = maintenance.StateStore(str(Path(directory) / "state.sqlite3"))
            api = LocalUserApi()
            terminated = [{"username": "i.ivanov", "reason": "ad_disabled"}]
            try:
                with mock.patch.object(maintenance, "run_ldap_helper", return_value=terminated), mock.patch.object(
                    maintenance, "send_mail"
                ):
                    summary = maintenance.offboarding_run(
                        api,
                        store,
                        {
                            "offboarding_confirmation_runs": 2,
                            "offboarding_minimum_age_hours": 20,
                            "offboarding_confirmation_interval_hours": 12,
                            "offboarding_max_users_per_run": 10,
                            "offboarding_require_ldap_import": True,
                            "offboarding_protected_usernames": [],
                            "offboarding_digest_repeat_hours": 72,
                            "offboarding_mail_to": "it@example.com",
                            "offboarding_subject_prefix": "[SNIPEIT-INVENTORY] REPORT:",
                        },
                    )
            finally:
                store.close()
        self.assertFalse(api.deleted)
        self.assertEqual(summary["skipped"][0]["reason"], "Snipe-IT user is local, not LDAP-imported")

    def test_weekly_report_marks_only_old_assets_overdue(self):
        now = dt.datetime(2026, 8, 11, 9, 0, tzinfo=dt.timezone.utc)

        class WeeklyReportApi:
            def paginate(self, path, limit=500):
                self_path = "_snipeit_last_successful_inventory_12"
                return [
                    {
                        "id": 1,
                        "name": "OLD-PC",
                        "serial": "OLD",
                        "category": {"id": 1},
                        "created_at": "2026-01-01T00:00:00+00:00",
                        "custom_fields": {"Last success": {"field": self_path, "value": "01:00 01.08.2026"}},
                    },
                    {
                        "id": 2,
                        "name": "FRESH-PC",
                        "serial": "NEW",
                        "category": {"id": 1},
                        "created_at": "2026-01-01T00:00:00+00:00",
                        "custom_fields": {"Last success": {"field": self_path, "value": "10:00 10.08.2026"}},
                    },
                ]

        with tempfile.TemporaryDirectory() as directory:
            store = maintenance.StateStore(str(Path(directory) / "state.sqlite3"))
            try:
                with mock.patch.object(maintenance, "utc_now", return_value=now):
                    summary = maintenance.weekly_report_run(
                        WeeklyReportApi(),
                        store,
                        {
                            "weekly_report_stale_days": 7,
                            "weekly_report_critical_days": 14,
                            "weekly_report_category_ids": [1],
                            "weekly_report_max_rows": 150,
                            "weekly_report_timezone": "Europe/Moscow",
                            "custom_fields": {
                                "last_success": "_snipeit_last_successful_inventory_12"
                            },
                        },
                        dry_run=True,
                    )
            finally:
                store.close()
        overdue = [item["name"] for item in summary["assets"] if item["overdue"]]
        self.assertEqual(overdue, ["OLD-PC"])
        self.assertEqual(summary["total"], 2)
        self.assertEqual(summary["current"], 1)
        self.assertEqual(summary["warning"], 1)
        self.assertEqual(summary["critical"], 0)

    def test_weekly_critical_assets_send_one_full_alert_per_week(self):
        now = dt.datetime(2026, 8, 10, 6, 30, tzinfo=dt.timezone.utc)

        class CriticalApi:
            def paginate(self, path, limit=500):
                return [{
                    "id": 9,
                    "name": "STALE-PC",
                    "serial": "STALE",
                    "category": {"id": 1},
                    "created_at": "2026-01-01T00:00:00+00:00",
                    "custom_fields": {
                        "Last success": {
                            "field": "_snipeit_last_successful_inventory_12",
                            "value": "08:00 20.07.2026",
                        }
                    },
                }]

        config = {
            "weekly_report_weekday": 0,
            "weekly_report_stale_days": 7,
            "weekly_report_critical_days": 14,
            "weekly_report_category_ids": [1],
            "weekly_report_timezone": "Europe/Moscow",
            "weekly_report_send_when_empty": True,
            "weekly_report_mail_to": "it@example.com",
            "weekly_report_subject_prefix": "[SNIPEIT-INVENTORY] REPORT:",
            "weekly_alert_mail_to": "it@example.com",
            "weekly_alert_subject_prefix": "[SNIPEIT-INVENTORY] ALERT:",
            "custom_fields": {"last_success": "_snipeit_last_successful_inventory_12"},
        }
        with tempfile.TemporaryDirectory() as directory:
            store = maintenance.StateStore(str(Path(directory) / "state.sqlite3"))
            try:
                with mock.patch.object(maintenance, "utc_now", return_value=now), mock.patch.object(
                    maintenance, "send_mail"
                ) as send_mail:
                    first = maintenance.weekly_report_run(CriticalApi(), store, config)
                    second = maintenance.weekly_report_run(CriticalApi(), store, config)
            finally:
                store.close()
        self.assertEqual(first["critical"], 1)
        self.assertTrue(first["alert_sent"])
        self.assertFalse(second["due"])
        send_mail.assert_called_once()
        self.assertIn("ALERT: WEEKLY:", send_mail.call_args.args[2])
        self.assertIn("STALE-PC", send_mail.call_args.args[3])

    def test_weekly_report_is_sent_once_per_iso_week(self):
        now = dt.datetime(2026, 8, 10, 6, 30, tzinfo=dt.timezone.utc)

        class EmptyApi:
            def paginate(self, path, limit=500):
                return []

        config = {
            "weekly_report_weekday": 0,
            "weekly_report_stale_days": 7,
            "weekly_report_category_ids": [1],
            "weekly_report_max_rows": 250,
            "weekly_report_timezone": "Europe/Moscow",
            "weekly_report_send_when_empty": True,
            "weekly_report_mail_to": "it@example.com",
            "weekly_report_subject_prefix": "[SNIPEIT-INVENTORY] REPORT:",
            "custom_fields": {},
        }
        with tempfile.TemporaryDirectory() as directory:
            store = maintenance.StateStore(str(Path(directory) / "state.sqlite3"))
            try:
                with mock.patch.object(maintenance, "utc_now", return_value=now), mock.patch.object(
                    maintenance, "send_mail"
                ) as send_mail:
                    first = maintenance.weekly_report_run(EmptyApi(), store, config)
                    second = maintenance.weekly_report_run(EmptyApi(), store, config)
            finally:
                store.close()

        self.assertTrue(first["sent"])
        self.assertFalse(second["due"])
        send_mail.assert_called_once()
        self.assertIn("WEEKLY", send_mail.call_args.args[2])

    def test_weekly_report_retries_after_monday_failure(self):
        monday = dt.datetime(2026, 8, 10, 6, 30, tzinfo=dt.timezone.utc)
        tuesday = monday + dt.timedelta(days=1)

        class EmptyApi:
            def paginate(self, path, limit=500):
                return []

        config = {
            "weekly_report_weekday": 0,
            "weekly_report_timezone": "Europe/Moscow",
            "weekly_report_send_when_empty": True,
            "weekly_report_mail_to": "it@example.com",
            "weekly_report_subject_prefix": "[SNIPEIT-INVENTORY] REPORT:",
            "custom_fields": {},
        }
        with tempfile.TemporaryDirectory() as directory:
            store = maintenance.StateStore(str(Path(directory) / "state.sqlite3"))
            try:
                with mock.patch.object(maintenance, "utc_now", return_value=monday), mock.patch.object(
                    maintenance, "send_mail", side_effect=maintenance.MaintenanceError("smtp down")
                ):
                    with self.assertRaises(maintenance.MaintenanceError):
                        maintenance.weekly_report_run(EmptyApi(), store, config)
                with mock.patch.object(maintenance, "utc_now", return_value=tuesday), mock.patch.object(
                    maintenance, "send_mail"
                ) as send_mail:
                    result = maintenance.weekly_report_run(EmptyApi(), store, config)
            finally:
                store.close()

        self.assertTrue(result["sent"])
        send_mail.assert_called_once()

    def test_database_cleanup_preserves_active_candidates(self):
        with tempfile.TemporaryDirectory() as directory:
            store = maintenance.StateStore(str(Path(directory) / "state.sqlite3"))
            now = dt.datetime(2026, 8, 11, tzinfo=dt.timezone.utc)
            old = (now - dt.timedelta(days=400)).isoformat()
            try:
                store.connection.execute(
                    "INSERT INTO maintenance_actions(created_at, action, result) VALUES(?, 'test', 'ok')",
                    (old,),
                )
                store.connection.execute(
                    """
                    INSERT INTO offboarding_candidates(
                        username, first_seen_at, last_seen_at, reason, status
                    ) VALUES('old.done', ?, ?, 'ad_disabled', 'completed')
                    """,
                    (old, old),
                )
                store.connection.execute(
                    """
                    INSERT INTO offboarding_candidates(
                        username, first_seen_at, last_seen_at, reason, status
                    ) VALUES('old.pending', ?, ?, 'ad_disabled', 'staged')
                    """,
                    (old, old),
                )
                store.connection.commit()
                removed = store.cleanup(365, now)
                pending = store.get_candidate("old.pending")
                completed = store.get_candidate("old.done")
            finally:
                store.close()
        self.assertEqual(removed, 2)
        self.assertIsNotNone(pending)
        self.assertIsNone(completed)


if __name__ == "__main__":
    unittest.main()
