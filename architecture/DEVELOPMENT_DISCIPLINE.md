# Domlight non-regression development discipline

## Prime rule
Every capability accepted by the user is protected. Adding or repairing one capability must not silently rewrite, replace, refactor, or change the behavior of another accepted capability.

This rule applies to every module, shared helper, launcher, updater, data format, portal integration and UI path.

## Acceptance states
- CANDIDATE: implemented or CI-tested, but not yet accepted by the user on the real Windows/portal environment.
- ACCEPTED: explicitly verified by the user. Its behavior becomes protected.
- RECOVERY_REQUIRED: previously accepted behavior is known to have regressed. No later release may be called stable until it is recovered and re-accepted.

CI success never promotes CANDIDATE to ACCEPTED.

## Change isolation
Every development task must declare a CHANGE_TARGET before code changes.

Allowed changes:
1. the declared target module;
2. a shared dependency only when strictly necessary and explicitly declared;
3. tests/contracts needed for the target.

A change to a shared dependency expands the regression scope to every protected consumer of that dependency.

Unrelated cleanup, refactoring, canonicalization, renaming or modernization is forbidden inside a feature change.

## No replacement by reconstruction
A working local/legacy module may not be replaced by a newly written equivalent merely because the new implementation appears cleaner.

Before a protected module becomes managed/canonical:
1. capture the actually accepted implementation;
2. archive its exact source/hash;
3. document its behavioral contract;
4. run its regression test against representative local data;
5. obtain user acceptance after any behavior-changing migration.

The v134 -> v135 Mailing incident is the reference failure: v134 explicitly required capture/audit of the deployed local Mailing module, but v135 created a new Mailing.ps1 from scratch and called it canonical. This is prohibited.

## Stable release gate
A release may be called STABLE only when all conditions are true:
1. all previously ACCEPTED contracts pass;
2. all protected local data boundaries pass;
3. the new capability's automated tests pass;
4. the user has verified the new/changed behavior in the real environment;
5. no RECOVERY_REQUIRED module remains;
6. the accepted baseline registry is updated only after that verification.

If any old capability fails, the candidate is rejected. The old capability is not rewritten to fit the candidate.

## Data boundary
Everything under data/ is user state. Release generation, installation, update, rollback and feature development must never replace or delete it. Any deliberate data migration requires a backup, reversible migration and a dedicated acceptance test.

## Release construction rule
Future releases are composed from the last accepted implementation of each protected capability plus the isolated candidate change. A numerically newest release is not automatically the baseline.

## Current recovery state
- v106 is the strongest verified legacy reference for the pre-meter core.
- v140 contains useful meter work but is not a stable application baseline.
- receipt_mailing is RECOVERY_REQUIRED.
- No meter submission work may proceed until the protected pre-meter regression set is recovered.
