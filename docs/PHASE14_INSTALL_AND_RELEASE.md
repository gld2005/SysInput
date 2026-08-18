# Phase 14 - Installation, upgrade, uninstall, and RC1 release

## Release outcome

Phase 14 produces the `v0.2.0-rc1` installer. It is an RC build, not the final stable release: interactive application compatibility and code signing remain explicit release gates.

Artifacts are generated under the ignored `dist` directory:

- `SysInput-Setup-0.2.0-rc1.exe`
- `SysInput-Setup-0.2.0-rc1.exe.sha256`

## Installation behavior

- Current-user installation; administrator rights are not required.
- Default directory: `%LOCALAPPDATA%\Programs\SysInput`.
- The user may select another directory.
- Start Menu shortcuts are created.
- Desktop shortcut is optional and disabled by default.
- `Start SysInput with Windows` is visible and selected by default on a fresh interactive installation.
- Inno Setup remembers the task selection during an upgrade.
- Silent setup supports `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`.

## Upgrade behavior

The installer locates the hidden `SysInputLifecycleWindow`, requests `WM_CLOSE`, and waits up to five seconds before replacing files. Current builds also expose `SysInput.exe --shutdown` for uninstall and automation. Normal shutdown runs Profile and background-worker cleanup.

Program files are separate from `%LOCALAPPDATA%\SysInput`, so settings, abbreviations, exclusions, imported corpus indexes, and learned profiles survive an upgrade. Existing startup selection is retained.

## Uninstall behavior

- Stops SysInput normally.
- Removes program files, shortcuts, uninstaller metadata, and the HKCU Run value.
- Preserves `%LOCALAPPDATA%\SysInput` by default.
- Interactive uninstall asks whether SysInput-owned local data should also be deleted.
- Silent uninstall preserves data unless `/DELETEUSERDATA` is explicitly supplied.
- Original corpus source files are never deleted.

## Verified lifecycle matrix

| Check | Result |
|---|---|
| ReleaseFast build and 47 automated checks | Pass |
| Fresh silent current-user install to a selected G: directory | Pass |
| Executable, dictionary, uninstaller, and Start Menu shortcut | Pass |
| Desktop shortcut remains optional | Pass |
| Startup task disabled leaves HKCU Run absent | Pass |
| Startup task enabled writes the quoted absolute command | Pass |
| Running-process upgrade requests normal exit | Pass |
| Upgrade preserves user data and startup selection | Pass |
| Default uninstall preserves user data | Pass |
| `/DELETEUSERDATA` removes SysInput-owned local data | Pass |
| Uninstall removes startup value and shortcuts | Pass |
| `--shutdown` exits an active instance normally | Pass |

## Performance acceptance

- Hook submission remains far below 1 ms.
- Candidate queries remain far below 20 ms in the repeatable benchmark.
- Idle CPU remains approximately zero.
- Observed idle working set remains below 25 MiB.
- No runtime dependency is added by the installer.

## Manual RC1 compatibility gate

The following must be tested interactively before renaming RC1 to stable:

- Notepad
- Word
- Outlook
- Chrome
- Edge
- VS Code
- An Electron application
- Win32 Edit/RichEdit controls
- Password fields and Windows security surfaces
- Excluded applications and elevated applications
- Caret movement, selection, clipboard restoration, and insertion failure
- 100%, 125%, 150%, and 200% DPI across available monitors
- Full-screen applications, sleep/wake, and sign-out/sign-in

Record failures before building `v0.2.0`; do not bypass this gate.

## Signing status

The RC1 artifact is not Authenticode-signed because no project signing certificate is configured. Windows may display an unknown-publisher or SmartScreen warning. A trusted signing certificate is required before the stable public release.
