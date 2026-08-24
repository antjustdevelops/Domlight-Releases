Domlight v104 STABLE BASELINE

Purpose
- This is the new stable release baseline captured from the working v96 installation verified on 2026-08-25.
- Manual receipt checking was verified successfully against 8 accounts.
- The missing RunAutoCheckHidden.ps1 launcher was restored.

Safety rules
- The data folder is never part of the release payload and must never be overwritten by updates.
- Receipts, session files, recipient data and local history remain local.
- Experimental builds must not be published through latest.json.
- latest.json must point only to a verified stable build.

Recovery
- Full pre-v97 setup remains available in Domlight_Setup.zip.
- This baseline adds the verified manual-check launcher and records checksums for the working program files.
