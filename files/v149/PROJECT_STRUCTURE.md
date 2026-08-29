# Domlight canonical baseline structure

## Release goal
A release is valid only when it is a self-contained managed application snapshot. User data is never part of the release.

## Managed application modules
- MENU_DOMLIGHT.ps1 — dashboard and navigation only.
- SingleWindowLauncher.ps1 — single child instance, Escape handling, visible startup errors, window_errors.log.
- Domlight.ps1 — interactive cabinet/login/manual receipt sync. The form must become visible before any portal request.
- AutoCheck.ps1 — unattended receipt check.
- RunAutoCheckHidden.ps1 — wrapper; completion protocol uses last_check.json.Result with freshness validation.
- AccountState.ps1 — canonical account lifecycle state.
- AccountStatus.ps1 — account lifecycle UI.
- MeterStatus.ps1 — meter/readings UI. Sending /meter/value remains disabled.
- DomlightPortal.ps1 — shared portal/session/proxy/CSRF/account helpers for new portal work.
- ConnectionSettings.ps1 — canonical proxy settings UI.
- Mailing.ps1 — canonical receipt-preparation UI; copies files to data/outbox and never modifies source archive.
- OrganizeDownloadedAccount.ps1 — receipt archive normalization.
- PdfEngine.ps1 — PDF text dependency used by archive normalization.
- UpdateFromGitHub.ps1 — checksummed staged update with backup/rollback; never writes release content into data/.
- ConfigureAutoCheckTask.ps1, ENABLE_AUTO_CHECK.bat, DISABLE_AUTO_CHECK.bat — scheduled check control.
- DomlightLauncher.vbs — main dashboard launcher.
- SelfCheck.ps1 — release dependency, encoding and parser gate.

## User data boundary
Everything under data/ is local user/application state and is preserved across updates. This includes session.dat, connection.json, accounts_state.json, receipts, outbox, logs, progress files, update stage and backups.

## Mandatory release gates
1. Every managed .ps1 is UTF-8 with BOM and parses under Windows PowerShell 5.1.
2. Every local .ps1/.bat/.vbs dependency referenced by managed PowerShell files exists in the same release snapshot.
3. Domlight.ps1, ConnectionSettings.ps1 and Mailing.ps1 pass a Windows STA smoke test that constructs their UI without displaying it.
4. Child-window startup errors are shown to the user and written to data/window_errors.log.
5. Mailing uses explicit DataGridView.Rows.Add population, never array DataSource binding.
6. Domlight cabinet does not contact the portal before its first visible window.
7. Meter submission to /meter/value remains disabled until the dedicated send-stage work is approved and tested.
8. The updater never replaces anything under data/.
9. VERSION.txt is the installed displayed-version source and is written by the updater.
10. A release manifest contains a checksum for every managed release file.

## Account lifecycle invariants
- Portal disappearance never deletes an account.
- 1–2 successful misses => missing.
- 3+ successful misses => inactive.
- Return on portal => active immediately.
- Only explicit Exclude permanently removes an account from automatic checks.
- Excluded accounts can be restored explicitly.

## Release process
Build candidate -> normalize encoding -> parse all scripts with Windows PowerShell 5.1 -> run SelfCheck -> run UI smoke tests -> generate full manifest with git-blob hashes -> only then promote latest.json.
