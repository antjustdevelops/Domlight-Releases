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

## Account lifecycle / status lineage

This is a composite protected block, not a single file. It consists of at least:
- AccountState.ps1 — lifecycle state and transitions.
- AccountStatus.ps1 — status UI and manual actions.
- OrganizeDownloadedAccount.ps1 — address/apartment enrichment used by the status UI.
- AutoCheck.ps1 / Domlight.ps1 — producers/consumers of accounts_state.json.
- MENU_DOMLIGHT.ps1 / SingleWindowLauncher.ps1 — launch integration only; must not change business semantics.

### Accepted lifecycle core
The v105 test sequence established the accepted semantics and v106 formalized them. AccountState.ps1 in v106 has blob SHA 0521a6bf852a201df5cf0986650939a52fa34c61.

Important evidence: v134 AccountState.ps1 has the exact same blob SHA 0521a6bf852a201df5cf0986650939a52fa34c61. Therefore the accepted lifecycle core from v106 survived unchanged through v134.

Protected semantics:
- current successful portal snapshot is authoritative for presence, but disappearance never deletes local account history;
- 1-2 successful misses => missing;
- 3rd successful miss => inactive;
- portal/parse/auth failure does not increment the miss counter;
- return on a successful snapshot => active immediately and miss counter resets;
- manual Excluded is independent from temporary missing/inactive and only changes by explicit user action;
- restoring an excluded account makes it eligible for checks again;
- local archive/state survives disappearance.

### AccountStatus UI repair sequence
v106 AccountStatus.ps1 blob SHA: bd721bb0138d6f2e4dbc1f3a3ed8bbc79aae0f1e.

v107/v108 were compatibility repairs for Windows PowerShell 5.1. v108 AccountStatus.ps1 blob SHA: 48948eb422e46456b8fe22083b0ef442319fc9d3e.

v109 then repaired address display/integration. v109 AccountStatus.ps1 blob SHA: 7013dfd669d61603dc161d15692855bd36060422.

Important evidence: v134 AccountStatus.ps1 has the exact same blob SHA 7013dfd669d61603dc161d15692855bd36060422. Therefore the v109 AccountStatus implementation is the last clearly traceable repaired UI carried unchanged into the v134 structural baseline.

v109 also shipped OrganizeDownloadedAccount.ps1 blob SHA 21b465f17fc0632890195d43b2b0081ad65f81be, and v134 carries the same blob SHA. The address/apartment enrichment pair is therefore consistent: AccountStatus v109 + OrganizeDownloadedAccount v109, both unchanged in v134.

### Correct protected combination for recovery
For the account-status block, do NOT mix arbitrary latest files. The current protected recovery combination is:
- AccountState.ps1 = v106 implementation (unchanged through v134).
- AccountStatus.ps1 = v109 repaired implementation (unchanged through v134).
- OrganizeDownloadedAccount.ps1 = v109 implementation (unchanged through v134).
- lifecycle semantics = v105 user-tested / v106 released contract.
- menu/window launch behavior may use v110 SingleWindowLauncher only as a wrapper; it must not alter lifecycle/UI behavior.

AutoCheck and Domlight must be audited as dependencies before a recovery package is labelled stable, because both read/write account state and later versions may contain targeted unrelated fixes. They cannot be replaced merely because their version number is newer.

### Discipline failure pattern
The defect here is the same architectural pattern as Mailing: later full-baseline/canonical builds could combine files from different historical stages without proving that the combination had been accepted together. A green parser/smoke test cannot prove the account lifecycle, UI, address enrichment and AutoCheck integration remain behaviorally compatible.

Therefore the account-status block is treated as a protected composite module with pinned compatible implementations and a behavioral regression contract, not as independent latest-file selection.

## Other module lineage

### Receipt portal/download/archive
Protected lineage: v96 working baseline -> v104 frozen baseline -> v105 tested integration -> v106 release. Later changes must be treated as targeted fixes only unless explicitly accepted.

### Window/menu launcher
v110 targeted SingleWindowLauncher/menu work is a later accepted structural improvement candidate. It must not change business behavior of child modules.

### Meter module
Meter work was initially correctly isolated. v140 meter UI/draft behavior is useful but remains CANDIDATE until full regression against all previously accepted modules passes and the user accepts it.

## Mandatory release gate
Every candidate release must declare:
1. CHANGE_TARGET: exact module(s) intentionally changed.
2. PROTECTED_MODULES: all previously accepted modules, including composite module pin sets.
3. DEPENDENCY_IMPACT: shared dependencies touched by the change.
4. REGRESSION_CONTRACT: executable/smoke/manual checks for every affected protected module.
5. USER_ACCEPTED: false until explicit user confirmation after real Windows test.

Any candidate that changes a protected module outside CHANGE_TARGET, replaces a protected implementation without lineage evidence, mixes incompatible versions of a composite module, or has USER_ACCEPTED=false must not be labelled STABLE.

## Current recovery direction
Build the next recovery candidate by:
1. preserving the useful meter implementation separately as CANDIDATE;
2. restoring the complete working mailing behavior from the verified pre-v135 lineage;
3. pinning the account-status composite block to AccountState v106 + AccountStatus v109 + OrganizeDownloadedAccount v109, then auditing AutoCheck/Domlight dependencies;
4. not modifying other protected modules as part of this recovery.
