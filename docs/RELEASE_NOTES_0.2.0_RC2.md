# SysInput v0.2.0-rc.2 release notes

## Summary

RC2 adds a user-selectable data directory for installed mode while preserving
SysInput's local-only storage and non-destructive migration guarantees.

## What's new

- **Settings > Data** now provides a path field, Unicode folder browser,
  **Copy existing data**, **Restore default**, and **Apply** controls.
- Directory changes are staged and completed on the next launch, after the old
  process has saved its final personal-learning profile.
- Copying requires an empty destination. The old directory is never deleted or
  merged into another non-empty directory.
- Portable mode remains fixed to `data` beside `SysInput.exe`.
- Unavailable custom locations fall back to `%LOCALAPPDATA%\SysInput` instead of
  preventing SysInput from starting.

## Upgrade notes

Install RC2 over RC1 normally. The installer stops the running instance before
replacing program files and preserves settings, abbreviations, exclusions,
corpus indexes, and learned profiles.

To move data after upgrading:

1. Open **SysInput Settings > Data**.
2. Enter a directory or choose **Browse...**.
3. Leave **Copy existing data** selected for a new empty directory.
4. Choose **Apply**, exit SysInput normally, and launch it again.
5. Confirm the new directory in **Settings > Data** before manually removing any
   old copy.

The uninstaller never recursively deletes an arbitrary custom directory.

## Artifacts

- `SysInput-Setup-0.2.0-rc2.exe`
- `SysInput-Setup-0.2.0-rc2.exe.sha256`

SHA-256: `0146b16d9905ea9f8d2062df8b8a4536239e99f3ff4244876bb0273fba81ae76`

The installer is not Authenticode-signed. Windows may show an unknown-publisher
or SmartScreen warning; verify the SHA-256 value before installation.

## Validation

- Zig 0.14.0 `ReleaseSafe`: 48/48 automated checks passed.
- Zig 0.14.0 `ReleaseFast`: 48/48 automated checks passed.
- `ReleaseFast` executable and Inno Setup installer compilation passed.
- Copy migration, source preservation, Unicode paths, restoring the default,
  non-empty destination rejection, and nested destination rejection are covered
  by automated tests.
