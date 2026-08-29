# Domlight full module audit matrix

Date: 2026-08-29
Scope: v96/v104/v105/v106 through v140
Purpose: define safe recovery inputs before building the next candidate

Status legend:
- ACCEPTED = user-tested or byte-identical descendant of an accepted implementation.
- ACCEPTED_FIX = targeted repair with clear lineage and no business-semantic rewrite.
- CANDIDATE = useful newer implementation, but not allowed to define the stable baseline until full regression + user acceptance.
- RECOVERY_REQUIRED = known regression/rewrite/mismatch; cannot be used as stable implementation.
- LOCAL_PROTECTED = working local module intentionally preserved outside managed releases; recover exact pre-takeover copy when possible.

| Functional block | Files / contracts | Last safe source | Current v140 assessment | Status / recovery decision |
|---|---|---|---|---|
| Interactive cabinet, login, manual receipt sync | Domlight.ps1, session.dat, connection.json, AccountState | v106 behavior baseline | v140 Domlight SHA differs; later auth detection/other behavior changed | ACCEPTED baseline = v106. Later fixes only by explicit cherry-pick + regression. |
| Session storage | session.dat DPAPI cookie format, Save/Load Session | v96-v106 accepted contract | DomlightPortal and MeterStatus still consume same DPAPI cookie structure | ACCEPTED contract. Never migrate format during recovery. |
| Receipt download/check | Domlight.ps1 + portal receipt parsing | v96 -> v104 -> tested v105 -> v106 | v140 code changed from v106 | ACCEPTED baseline = v106 until later deltas are individually proven. |
| AutoCheck business logic | AutoCheck.ps1 + AccountState + organizer | v106 | v134/v140 differ from v106 | ACCEPTED baseline = v106; later changes must be reviewed/cherry-picked. |
| Hidden AutoCheck wrapper | RunAutoCheckHidden.ps1 + last_check.json.Result | v106 intent; later targeted fix needed | v106 incorrectly looked at payload.status while current wrapper looks at Result + freshness | ACCEPTED_FIX = later Result/freshness wrapper, because it repairs an explicit protocol mismatch without changing receipt logic. |
| Scheduled task control | ConfigureAutoCheckTask.ps1, ENABLE/DISABLE_AUTO_CHECK.bat | v106 | same SHAs carried into v140 for scheduler scripts | ACCEPTED by carry-forward. |
| Account lifecycle state | AccountState.ps1, accounts_state.json | v105 tested / v106 release | v140 AccountState SHA exactly equals v106 | ACCEPTED. Pin v106 SHA 0521a6bf852a201df5cf0986650939a52fa34c61. |
| Account status UI | AccountStatus.ps1 | v109 repaired UI | v140 SHA exactly equals v109 | ACCEPTED_FIX. Pin v109 SHA 7013dfd669d61603dc161d15692855bd36060422. |
| Account address/archive enrichment | OrganizeDownloadedAccount.ps1 | v109 | carried unchanged through v134; use v109 pin for recovery | ACCEPTED_FIX. Pin v109 SHA 21b465f17fc0632890195d43b2b0081ad65f81be. |
| Mailing / preparation / Gmail / WhatsApp | Mailing.ps1, Recipients.ps1, GmailApi.ps1, recipients.json, histories, outbox | working local stack present through v110 and preserved through v134 | v135 replaced it with new canonical Mailing; v140 inherits replacement and old Gmail/recipient behavior is missing | RECOVERY_REQUIRED. Restore full pre-v135 local stack; do not use v140 Mailing as stable. |
| Proxy settings UI | ConnectionSettings.ps1 | working local pre-v135 module | v135 first manages a rewritten ConnectionSettings despite v134 preservation rule; v140 descends from rewrite | LOCAL_PROTECTED / RECOVERY_REQUIRED. Recover pre-v135 UI if possible; preserve connection.json unchanged. |
| Proxy data contract | data/connection.json: useProxy, proxyUrl, proxyUser, proxyPassword | v106 consumers | v140 UI/shared helpers still use same shape | ACCEPTED contract. No schema change during recovery. |
| Proxy consumers | Get-ProxyArgs in Domlight/AutoCheck/MeterStatus/DomlightPortal | v106 Domlight+AutoCheck contract | v140 MeterStatus and DomlightPortal duplicate same schema but are separate implementations | CANDIDATE for new modules; accepted legacy consumers stay pinned until regression. |
| Main menu/dashboard | MENU_DOMLIGHT.ps1 | v110 had targeted launcher/menu integration | v140 menu equals v134 SHA and wires newer modules | CANDIDATE. Use as integration shell only after every button opens the protected module and business logic remains inside modules. |
| Child-window launcher | SingleWindowLauncher.ps1 | v110 | v140 adds smoke-test/error logging while preserving mutex/ESC design | CANDIDATE/likely safe targeted infrastructure improvement. Must regression-test every child launch. |
| Main VBS launcher | DomlightLauncher.vbs | later structural line | same SHA across v134/v140 | CANDIDATE infrastructure; low business risk, still test start/restart/update path. |
| Receipt archive location/data boundary | data/receipts, data/* | v96-v106 invariant | v140 updater explicitly refuses data paths | ACCEPTED invariant. Release must never replace/delete data. |
| PDF extraction engine | PdfEngine.ps1 | older working package had PdfEngine, but exact pre-v135 managed lineage not captured | no v106/v134 managed file; new PdfEngine appears in v135 and is unchanged in v140 | RECOVERY_REQUIRED/CANDIDATE. Treat v135+ implementation as unaccepted rewrite until tested against real archive PDFs. |
| Mailing outbox | data/outbox | working old mailing behavior: rebuild/replace prepared set without modifying source archive | v140 Mailing only copies/prepares and lacks previous send stack | Contract is ACCEPTED; v140 implementation RECOVERY_REQUIRED. |
| Meter reading UI | MeterStatus.ps1 | meter line developed separately; v138 last clearly working draft baseline, v140 repaired checkbox persistence | v140 useful and user reports meters work | CANDIDATE with strong evidence. Preserve separately, do not let it redefine legacy modules. |
| Meter draft storage | MeterDraftStore.ps1, data/meter_drafts.json | v138+ | v140 dedicated store | CANDIDATE; protect after recovery regression and user acceptance. |
| Meter grid checkbox/value persistence | MeterGridBehavior.ps1 | v140 targeted fix | current v140 | CANDIDATE; keep paired with v140 MeterStatus only. |
| Meter submission | /meter/value | deliberately disabled | disabled | ACCEPTED safety invariant: DO NOT ENABLE during recovery. |
| Shared portal helper | DomlightPortal.ps1 | introduced later for new work | v140 helper uses accepted session/proxy field contracts, but legacy modules still duplicate networking | CANDIDATE. Use for future modules only; do not migrate legacy Domlight/AutoCheck during recovery. |
| Updater | UpdateFromGitHub.ps1, latest.json | later infrastructure | v140 has checksum, stage, backup, rollback and blocks data paths | CANDIDATE infrastructure with good safeguards. Must not be allowed to manage LOCAL_PROTECTED files until captured/accepted. |
| Updater backups | data/update_backups | later infrastructure | v140 creates per-update backups before replacement | ACCEPTED safety mechanism; use as recovery evidence. |
| Self-check | SelfCheck.ps1 | introduced later | v140 SelfCheck still expects `Domlight v137 RELEASE` and therefore is stale inside v140 | RECOVERY_REQUIRED. Fix version coupling and expand to protected-module regression checks before next release. |
| Project structure contract | PROJECT_STRUCTURE.md | v134 correctly protected local Mailing/ConnectionSettings | later baseline changed them to canonical without capture | RECOVERY_REQUIRED as governance history; new architecture guard supersedes this error. |
| Version display | VERSION.txt | later rule: single displayed-version source | updater writes it | ACCEPTED design invariant; SelfCheck must read expected version dynamically, never hard-code an old release. |
| Installer / clean install | clean installer/build line v137 | later structural work | not enough evidence of user acceptance of all modules together | CANDIDATE. Recovery installer must not overwrite existing data or local protected credentials/history. |
| Reports/history | last_check.json, DOMLIGHT_REPORT.txt, logs | v106 behavior | later wrappers/readers changed | ACCEPTED data contract around Result/CheckedAt; verify exact UI/report behavior in regression. |

## Confirmed discipline violations

1. v134 explicitly said Mailing.ps1 and ConnectionSettings.ps1 were local protected modules and must be captured/audited before becoming managed.
2. v135 nevertheless introduced new managed Mailing.ps1 and ConnectionSettings.ps1. This is the primary confirmed governance breach.
3. PdfEngine.ps1 also appears as a new managed implementation in v135 without a verified lineage from the earlier working package; treat as unaccepted until tested.
4. v140 SelfCheck.ps1 is stale and hard-codes `Domlight v137 RELEASE`, proving the baseline can be internally inconsistent even while CI is green.
5. MeterStatus v140 still contains its own session/proxy/CSRF/account-switch implementation even though DomlightPortal exists. This duplication is technical debt, but recovery must NOT refactor it now because meters currently work.

## Recovery pin set

The next recovery candidate must start from module pins, not from a whole version number:

- AccountState.ps1: v106 SHA 0521a6bf852a201df5cf0986650939a52fa34c61.
- AccountStatus.ps1: v109 SHA 7013dfd669d61603dc161d15692855bd36060422.
- OrganizeDownloadedAccount.ps1: v109 SHA 21b465f17fc0632890195d43b2b0081ad65f81be.
- Domlight.ps1: v106 behavioral baseline; later changes reviewed separately.
- AutoCheck.ps1: v106 behavioral baseline; pair with the later targeted RunAutoCheckHidden Result/freshness fix.
- Mailing stack: restore complete pre-v135 working local implementation, not v140 Mailing.
- ConnectionSettings: restore/audit pre-v135 working local implementation; keep connection.json contract unchanged.
- MeterStatus + MeterDraftStore + MeterGridBehavior: preserve v140 meter candidate as an isolated feature bundle.
- Scheduled task scripts: carry forward unchanged v106-compatible versions.
- Updater: use safeguarded later updater only after manifest excludes unaccepted/local-protected replacements and the recovery candidate passes tests.
- SelfCheck: replace stale v140 check with a recovery-specific gate that checks exact protected pins and regression contracts.

## Required regression before USER_ACCEPTED=true

1. App starts normally and shows correct version.
2. Proxy OFF: login/session/manual receipt check works.
3. Proxy ON: same flows work with saved proxy credentials.
4. Existing session loads; expired session safely asks for login and can be restored.
5. Manual receipt check sees all current accounts and does not damage archive.
6. AutoCheck completes using fresh last_check.json.Result and scheduled wrapper exits cleanly.
7. Account lifecycle: 8->7->7->7 makes missing/missing/inactive; return to 8 restores active; failed portal read does not increment misses.
8. AccountStatus opens, displays full address, exclusion/restoration works, hidden/excluded display works.
9. Mailing opens old full chooser/table; recipients, Gmail, WhatsApp, PDF preview and histories are available; preparing a new set does not modify source receipts.
10. Meter window still reads meters; draft values and checkbox survive close/reopen; sending stays disabled.
11. Every child window is single-instance and Escape closes only the child.
12. Update/repair creates backup, never writes under data/, and rollback works on a forced failure test.
13. SelfCheck passes the actual candidate version and exact protected module pins.

No release can be labelled STABLE until all applicable automated checks pass AND the user confirms the real Windows regression run.
