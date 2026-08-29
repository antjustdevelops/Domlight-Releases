# Domlight v150 DEV — Change Contract

Baseline: `main` = v149 STABLE
Branch: `dev/v150`
Feature: Meter readings submission to Domlight portal

## Allowed files
- `files/v149/MeterStatus.ps1`
- `files/v149/MeterGridBehavior.ps1`
- new meter-submission helper module(s) under `files/v150/`
- DEV-only test/diagnostic files under `dev/v150/`

## Protected files / modules
Do not change without a new explicit scope decision:
- receipt checking and receipt archive
- `Mailing.ps1`
- Gmail/recipient logic
- `ConnectionSettings.ps1`
- `AccountState.ps1`
- accepted `AccountStatus.ps1`
- AutoCheck / scheduled task behavior
- updater / `latest.json`
- installer / STABLE release files
- user `data` other than meter draft/status records explicitly required by this feature

## Required behavior
1. v149 UI and draft behavior remain unchanged until submission is explicitly invoked.
2. Only rows with `Transfer` selected and a valid new reading may be submitted.
3. A meter already marked as submitted for the current month must never be sent again automatically.
4. Submission must be performed account-by-account using the authenticated Domlight session.
5. Before any POST, the code must obtain the current portal form/action parameters and CSRF token from the live page; no guessed endpoint or guessed payload is allowed.
6. A failed meter must not mark other meters as successfully sent.
7. Success must be confirmed from the portal response and/or a fresh read-back of the meter page before local state is updated.
8. Drafts are removed only for readings confirmed as accepted by the portal.
9. Partial failure must show exactly which account/meter succeeded and which failed.
10. No silent retry loop that could duplicate a submission.

## Data impact
- Existing `meter_drafts.json` is preserved.
- Any new submission log must be append-only and contain no credentials/session cookies.
- `session.dat`, proxy credentials and other secrets must never be committed.

## Acceptance gate
- Dry-run/inspection proves exact portal submission endpoint and field names.
- One-meter DEV submission succeeds and is confirmed by fresh read-back.
- Multi-meter submission handles partial success correctly.
- Reopening the meter window shows the portal-confirmed state.
- Full regression: receipts, mailing, proxy, accounts status, AutoCheck, meters, single-instance windows, data preservation.
- Only after explicit user acceptance may v150 be promoted to RC/STABLE.

## Rollback
Delete/discard `dev/v150` changes and return to `main` / `stable-v149`. v149 STABLE must remain untouched throughout development.
