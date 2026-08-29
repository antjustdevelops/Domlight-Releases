# Domlight v149 STABLE

Accepted: 2026-08-29

This branch is a recovery anchor for the user-accepted v149 behavior. It must not be used for experimental development.

## Accepted functional baseline

- Restored pre-meter application behavior remains the base.
- Receipt mailing remains part of the protected legacy base.
- Account status window keeps the five accepted actions and is single-instance.
- Meter feature is integrated as an isolated feature.
- Meter `New Value` remains editable.
- `Transfer` cannot be selected when the new value is empty or invalid.
- Clearing the new value automatically clears `Transfer`.

## Architecture rule

Future features must be developed on a DEV/TEST branch and must not replace unrelated working modules. A new stable baseline is created only after full regression and explicit user acceptance.

## Recovery artifacts

Canonical user-side recovery artifact: `SETUP_DOMLIGHT_v149_STABLE.cmd`.

SHA-256: `37d08dca87f1049bac2e57978c04fa1d2d74ca5c0bd585f3e812566183392b92`

The installer preserves `Documents\\Domlight\\data`, creates a pre-install safety backup of program files, installs the accepted baseline, retrieves the three pinned meter modules from `main/files/v140`, applies the accepted meter checkbox rule, validates PowerShell syntax, and creates a desktop shortcut.

Do not move `main` or `latest.json` merely because this recovery branch exists.