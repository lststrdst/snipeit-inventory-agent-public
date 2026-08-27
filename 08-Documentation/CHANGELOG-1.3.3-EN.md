# Snipeit Inventory Agent - Change log v1.3.3

Released: 14 August 2026

This is the final self-contained Snipeit Inventory Agent release before the
planned Snipeit Gateway Release.

## Unified product naming

The system uses one naming family:

- **Snipeit Inventory Agent**: Windows collection and synchronization;
- **Snipeit Inventory Relay**: offline SMTP/IMAP delivery;
- **Snipeit Inventory Maintenance**: user deletion, retention and weekly
  control;
- **Snipeit Inventory Weekly Report**: weekly data freshness report.

New mail subjects use `[SNIPEIT-INVENTORY] REPORT`, `ALERT`, `WARNING`,
`ERROR`, and `RELAY`. Legacy PCINV/SNIPEIT subject prefixes continue to be
accepted during migration.

## Safe offboarding

Automatic offboarding uses only the Active Directory `disabled` state as the
action trigger. A description or organisational-unit name can be logged as
diagnostic information but cannot delete an active account or return its
equipment to stock.

Maintenance requires repeated observation and 30 full days of continuous
disabled status. It checks in assigned hardware, moves it to stock, unassigns
accessories and licences, verifies that assignments are gone, and performs a
soft delete through the Snipe-IT API. Deletion is limited per run and protected
accounts are excluded. A re-enabled account resets the countdown.

On the endpoint, a disabled current owner is returned to stock immediately. A
later inventory run checks equipment out to a new valid interactive user.
Shared and system accounts, including `transcom`, `defaultuser*`, guest and
Windows service identities, cannot become asset owners or trigger false LDAP
sync warnings.

## Weekly health control

Daily watchdog email was replaced with one ISO-weekly report. Data is checked
daily but a full message is sent once per week. Devices are marked `Current`,
`Overdue` after 7 days, `Critical` after 14 days, or `Never`. SMTP failures are
retried without duplicate reports.

## Quiet, idempotent deployment

The GPO installer runs via the hidden VBS wrapper under `SYSTEM`; an hourly
installer repeat is no longer required. A global mutex prevents concurrent
installations, duplicate copying, and duplicate forced reports. The permanent
scheduled task has a single Snipeit Inventory name and obsolete tasks are
removed after successful migration.

Protected configuration and the private SSH key are copied only from the secure
share, stored under ProgramData with SYSTEM/Administrators ACLs, and migrated
safely. A missing new key never causes the existing key to be deleted.

## Retention and relay hardening

The release limits local logs, mail queues, processed/rejected events, weekly
reports, human reports, alerts, warnings, errors, relay/maintenance SQLite data
and server update backups.

The IMAP relay only handles messages that pass sender, subject/header, HMAC,
JSON-schema and attachment checks. Unrelated mail stays untouched. Temporary
IMAP search failures are retried with reconnects, and report sorting no longer
interrupts offline event processing. Relay Dry Run uses an in-memory SQLite
database and cannot mark a real event as processed.

## Validation

Release validation covered agent and installer PowerShell suites, relay and
maintenance unit tests, PowerShell/Python/PHP syntax, safe LDAP/API checks,
disabled-only offboarding, the 30-day delay and reset on re-enable, shared
account exclusion, safe SSH-key migration, mail routing, relay deduplication,
stale-event protection and hidden SYSTEM launch paths.
