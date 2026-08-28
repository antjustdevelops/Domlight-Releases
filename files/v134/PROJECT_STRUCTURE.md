# Domlight v134 baseline structure

## Managed application files
- MENU_DOMLIGHT.ps1 — main dashboard and navigation.
- Domlight.ps1 — interactive cabinet/login/receipt sync.
- AutoCheck.ps1 — unattended receipt check.
- RunAutoCheckHidden.ps1 — process wrapper and completion protocol.
- MeterStatus.ps1 — meter/readings UI; submission remains disabled.
- AccountState.ps1 — canonical account lifecycle model.
- AccountStatus.ps1 — account lifecycle UI.
- DomlightPortal.ps1 — canonical portal helpers for all new integrations.
- OrganizeDownloadedAccount.ps1 — receipt archive normalization.
- SingleWindowLauncher.ps1 — one-window-per-module plus Escape handling.
- UpdateFromGitHub.ps1 — staged/checksummed updater with rollback.
- ConfigureAutoCheckTask.ps1 / ENABLE_AUTO_CHECK.bat / DISABLE_AUTO_CHECK.bat — scheduler control.
- DomlightLauncher.vbs — dashboard launcher.
- SelfCheck.ps1 — baseline integrity/dependency check.

## User data
Everything under data/ is local state and must never be replaced by an application release. This includes session.dat, connection.json, accounts_state.json, receipts, logs, progress snapshots, updater backups and staging directories.

## Local optional modules
Mailing.ps1, ConnectionSettings.ps1 and Domlight.ico are preserved if present. They are not deleted by the updater. They can become managed only after the currently deployed local copies are captured and audited.

## Invariants
1. Portal disappearance never deletes an account.
2. 1-2 successful misses => missing; 3+ => inactive; return => active immediately.
3. Only explicit Exclude permanently removes an account from checks.
4. Meter submission stays disabled until persistent drafts and a one-meter send test are complete.
5. Updates never write inside data/.
6. Every managed release file has a checksum in the release manifest.
7. Child windows are single-instance and Escape closes only the child.
8. VERSION.txt is the only displayed-version source.
9. AutoCheck completion uses last_check.json.Result and a fresh timestamp, never stale status fields.

## Portal architecture
DomlightPortal.ps1 is the canonical shared portal layer for all new work: session loading, proxy, CSRF, account parsing, authentication verification and account switching. Existing legacy networking inside Domlight.ps1 / AutoCheck.ps1 / MeterStatus.ps1 is frozen for compatibility and must be migrated module-by-module rather than changed independently in three places.
