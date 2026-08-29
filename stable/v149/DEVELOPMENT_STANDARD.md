# DML-ENG-STD-001 — Domlight Engineering Standard

Status: mandatory for all branches and modules. Baseline: v149 STABLE.

## 1. Non-negotiable rules
1. Every change starts from an explicitly named STABLE baseline.
2. Before code changes, create a Change Contract with: FEATURE, ALLOWED FILES, PROTECTED FILES, DATA IMPACT, UI IMPACT, ACCEPTANCE, REGRESSION SET, ROLLBACK.
3. A file outside ALLOWED FILES must not be changed. If scope must expand, stop and create a new explicit scope decision.
4. A new feature must be isolated. Unrelated working modules must not be replaced or rewritten.
5. User data under `Documents\\Domlight\\data` is protected. Any data migration requires backup, verification and rollback.
6. DEV/TEST is never a recovery baseline merely because it starts successfully.
7. Release flow is mandatory: CHANGE REQUEST -> DEV -> TEST -> REGRESSION -> RC -> explicit user acceptance -> STABLE.
8. On regression, stop new development, restore the last STABLE in isolation, and re-integrate only the problematic feature. Do not keep stacking patches on a damaged branch.

## 2. Protected module principle
Examples of independently protected areas include receipts/PDF, mailing/Gmail/recipients, proxy/gateway, account status/state, AutoCheck, meters, launcher/setup and data. A change in one area does not authorize replacement of another.

## 3. Pre-user build gate
Before a build is given to the user, changed files must pass: PowerShell parser, encoding compatibility with Windows PowerShell 5.1, dependency/path validation, launcher error handling, package integrity, diff-scope check and data-safety check. The user's computer must not be used to discover obvious syntax or packaging defects that can be caught before delivery.

## 4. Regression gate
Before RC, smoke/regression testing must cover: main window, receipt check, receipt archive, mailing, Gmail/recipients, proxy/gateway, account status, AutoCheck, meters, window close/single-instance behavior and data preservation. Any failure in an already working area blocks promotion.

## 5. UI contract
Service windows should size to actual content, avoid large empty regions, keep same-level buttons in a coherent horizontal group, prioritize readable address width, use single-instance behavior, and close correctly via window close controls. UI-only changes must not alter business handlers unless separately scoped.

## 6. v149 meter contract
`New Value` remains editable. Empty or invalid value means `Transfer` cannot be selected. Clearing the value clears `Transfer`. Existing draft logic and portal-transfer state are not changed by this UI rule.

## 7. Definition of Done
A change is done only when: Change Contract matches actual diff; changed scripts pass checks; feature acceptance criteria pass; protected modules remain intact or separately approved; full regression has no failures; rollback exists; RC manifest/hashes are recorded; user explicitly accepts the version as STABLE; previous STABLE is retained.

The full normative version is maintained in the Word document `Domlight_Development_Standard_v149_STABLE.docx` supplied with the project history.