# Domlight module lineage audit

Date: 2026-08-29
Status: audit evidence, not a stable release

## Core rule
A module becomes protected after user acceptance. New work must not replace or refactor a protected module unless that module itself is the declared change target and its full regression contract is rerun.

## Receipt mailing lineage

### Proven working origin
The final Windows prototype package dated 2026-08-21 was built from the v60 line and included the complete mailing stack: Mailing.ps1, Recipients.ps1, GmailApi.ps1, Gmail API OAuth, ABRENTALS sender, email/WhatsApp history, PDF preview and replace-on-new-build outbox behavior.

The working UI was visibly present in the v90 release: mailing mode chooser (ЖКХ / капремонт / все), and the per-apartment ЖКХ table with period, recipient, e-mail, WhatsApp, Mail, WhatsApp, PDF filename and preview controls.

### Carry-forward behavior
The v105 development line explicitly preserves Gmail OAuth, recipients and email/WhatsApp history when the receipt archive is rebuilt. Therefore the mailing stack was still part of the working local installation during the v105 tests.

v106 added account lifecycle/status behavior and AutoCheck hardening. It did not replace the mailing stack.

v107-v110 were targeted changes (AccountStatus compatibility, menu/window launcher behavior). The v110 release directory contains only MENU_DOMLIGHT.ps1 and SingleWindowLauncher.ps1, so the local working mailing stack was carried forward unchanged.

From the meter-development period through v131, meter work remained isolated in MeterStatus.ps1 and did not require replacement of the mailing stack.

### Explicit protection at v134
v134 PROJECT_STRUCTURE.md correctly classified Mailing.ps1 as a local optional module that must be preserved if present and must not become a managed release file until the deployed working copy is captured and audited.

### Regression point
The first confirmed discipline violation is v135: a new Mailing.ps1 was created from scratch and labelled canonical instead of capturing the deployed working mailing stack. This new implementation only prepares/copies PDFs to outbox and omits the previously working recipient/Gmail/WhatsApp behavior.

Therefore:
- v140 Mailing.ps1 is NOT an accepted descendant of the working mailing module.
- v140 as a whole is NOT a stable baseline.
- the effective last accepted application state for the mailing block is the locally carried-forward working stack present at v110 (and preserved through v134), whose implementation lineage originates in the final 2026-08-21 package.

## Other module lineage

### Receipt portal/download/archive
Protected lineage: v96 working baseline -> v104 frozen baseline -> v105 tested integration -> v106 release. Later changes must be treated as targeted fixes only unless explicitly accepted.

### Account lifecycle
Accepted from v105 test sequence and formalized in v106: active -> missing after successful absence checks -> inactive after third successful miss -> active immediately on return; manual exclusion/restoration; local history preserved.

### AccountStatus UI
v106 behavior accepted conceptually; v107-v109 fixed PowerShell 5.1 encoding/address UI regression. Later work may use these fixes but may not change lifecycle semantics.

### Window/menu launcher
v110 targeted SingleWindowLauncher/menu work is a later accepted structural improvement candidate. It must not change business behavior of child modules.

### Meter module
Meter work was initially correctly isolated. v140 meter UI/draft behavior is useful but remains CANDIDATE until full regression against all previously accepted modules passes and the user accepts it.

## Mandatory release gate
Every candidate release must declare:
1. CHANGE_TARGET: exact module(s) intentionally changed.
2. PROTECTED_MODULES: all previously accepted modules.
3. DEPENDENCY_IMPACT: shared dependencies touched by the change.
4. REGRESSION_CONTRACT: executable/smoke/manual checks for every affected protected module.
5. USER_ACCEPTED: false until explicit user confirmation after real Windows test.

Any candidate that changes a protected module outside CHANGE_TARGET, replaces a protected implementation without lineage evidence, or has USER_ACCEPTED=false must not be labelled STABLE.

## Current recovery direction
Build the next recovery candidate by preserving the current useful meter implementation separately while restoring the complete working mailing behavior (Mailing + Recipients + GmailApi + recipient/history data contracts) from the verified pre-v135 lineage. Do not modify other protected modules as part of that recovery.
