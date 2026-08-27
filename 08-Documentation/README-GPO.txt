Snipeit Inventory Agent 1.3.3

PUBLIC SHARE
  \\AD-SERVER\snipeit_auto$

Copy only:
  install_snipeit_auto.ps1
  install_snipeit_auto.vbs
  install_snipeit_manual.cmd
  install_snipeit_manual.ps1
  snipeit_inventory.ps1
  snipeit_auto.vbs
  snipeit_manual.cmd
  snipeit_dry_run.cmd

SECURE SHARE
  \\AD-SERVER\snipeit_auto_secure$\snipeit_inventory.local.json
  \\AD-SERVER\snipeit_auto_secure$\snipeit_ldap_sync_ed25519
  \\AD-SERVER\snipeit_auto_secure$\snipeit_ldap_sync_ed25519.pub

The protected JSON must use:
  "SnipeSshKeyPath": "C:\\ProgramData\\snipeit_auto\\Config\\snipeit_ldap_sync_ed25519"

The private key is installed only under the protected Config directory. After
the replacement exists and its ACL is verified, the installer removes the old
ProgramData-root copy and legacy LOCALAPPDATA copies from local profiles.

The secure JSON must contain the real API/SMTP secrets plus:
  "InventoryRelayEnabled": true
  "InventoryRelayFailureThreshold": 1
  "InventoryRelayMailTo": "it@example.com"
  "InventoryRelayHmacSecret": "<same random secret as server relay>"

Production mail identity:
  Account: it@example.com
  Yandex app-password name: Snipeit imap collector
  Yandex app-password type: Mail (IMAP, POP3, SMTP)
  SmtpUser and MailFrom must both be it@example.com.
  SmtpPass is the same app password used by Relay IMAP/SMTP.

Never put the secure JSON or server-relay/config.json on the public share.
The installer fails closed if the protected config is missing, contains
placeholders, reuses the SMTP password as the relay HMAC secret, or if local
ACL configuration fails.
An old 1.2.2 config without InventoryRelayEnabled/InventoryRelayHmacSecret is
rejected; deploy the protected 1.3.x JSON from the SECURE package.

GPO INSTALLER TASK
  Computer Configuration
  Preferences
  Control Panel Settings
  Scheduled Tasks
  New -> Scheduled Task (At least Windows 7)

General:
  Action: Update
  Account: NT AUTHORITY\SYSTEM
  Run whether user is logged on or not
  Run with highest privileges
  Hidden

Action:
  Program:
    wscript.exe
  Arguments:
    "\\AD-SERVER\snipeit_auto$\install_snipeit_auto.vbs"

Do not run powershell.exe directly from an InteractiveToken GPO task. That is
what opens Windows Terminal for the signed-in user. The VBS bootstrap starts
PowerShell invisibly and waits for one serialized installer instance.
The installer also starts the first forced inventory through the hidden VBS
launcher; no direct interactive PowerShell process is used at any stage.

Recommended GPO installer triggers:
  At startup, delay 5 minutes
  Daily at 11:00, random delay 1 hour

Conditions:
  Do not require idle
  Do not require AC power
  Do not require a specific network profile

Settings:
  Run as soon as possible after a missed start
  Stop after 1 hour
  Do not start a new instance
  Do not delete the task

Do not configure hourly repetition for the installer. Startup plus one daily
retry is enough; the local inventory task handles the normal 3-times-per-day
collection schedule.

LOCAL TASK CREATED BY THE INSTALLER
  \SnipeIT Inventory\Inventory Agent

Runs hidden as SYSTEM:
  startup + 5 minutes
  every user logon + 2 minutes
  daily at 08:00, 14:00 and 20:00, each with random delay up to 1 hour

The agent itself gates Snipe-IT work. Normally it writes to Snipe-IT once per day,
or immediately when the owner/disposition changes. Extra task starts only retry
the local SMTP queue and do not create duplicate Snipe-IT events.

INSTALL/UPDATE BEHAVIOR
The installer compares SHA-256 hashes.
Parallel GPO/immediate launches are suppressed by a global installer mutex.
install.log is limited to 30 days and 60 installer runs.
  Unchanged files do not trigger a forced report.
  First install or a real file/config update starts one hidden run with:
    -DeploymentRun -ForceInventory -ForceEmailReport

MANUAL INSTALLATION
  Run install_snipeit_manual.cmd from the public share or from a local copy.
  Accept the UAC prompt. The launcher creates one temporary SYSTEM task, so the
  protected JSON and LDAP SSH key are read with the computer account. It waits
  for installation, verifies \SnipeIT Inventory\Inventory Agent, then removes
  the temporary task and bootstrap file. Log:
    C:\ProgramData\snipeit_auto\Logs\manual-install.log

  snipeit_manual.cmd is different: it only forces an already installed agent
  run and does not install or repair the scheduled task.

FAST ROLLOUT
  Use a temporary Immediate Task with the same action and SYSTEM account.
  Do not enable "Apply once": an offline computer must retry at a later GPO refresh.
  Remove the Immediate Task after rollout. Keep the regular installer task for
  new computers and future updates.

MAIL ROUTING
  WEEKLY report/alert subjects        -> SnipeIT Inventory/! Weekly Reports
  [SNIPEIT-INVENTORY] REPORT: -> SnipeIT Inventory/Reports
  [SNIPEIT-INVENTORY] ALERT:  -> SnipeIT Inventory/Alerts
  [SNIPEIT-INVENTORY] WARNING: -> SnipeIT Inventory/Warnings
  [SNIPEIT-INVENTORY] ERROR:   -> SnipeIT Inventory/Errors
  [SNIPEIT-INVENTORY] RELAY:   -> SnipeIT Inventory/Offline Relay

  Processed Events -> successfully applied, duplicate, or safely stale relay events
  Rejected Events  -> invalid sender, signature, schema, or attachment

The server collector also sorts these messages from INBOX, so Yandex mail rules
are not required. During rollout it still accepts [PCINV-REPORT], [PCINV-ALERT],
[SNIPEIT-INVENTORY] ALERT:, PC Inventory ERROR, and [SNIPEIT-RELAY]. Remove
old Yandex sorting rules after the collector update; the collector migrates
known legacy folders and deletes them only after every message is moved.
