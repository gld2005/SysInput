# Phase 11: Settings window, tray control, and application exclusions

Phase 11 adds only runtime control and application safety. Abbreviation editing,
corpus import, and installation remain reserved for later phases.

## Native settings window

The notification-area icon opens an English Win32 settings window on either a
single or double click. The window is created only when first opened and is
hidden, rather than destroyed, when closed. A hidden window performs no drawing
or polling.

Available controls:

- enable or pause predictions;
- start with Windows;
- word, next-word, phrase, and sentence prediction;
- personal learning;
- safe or classic arrow-key mode;
- application exclusion list;
- data directory and version information.

The Abbreviations and Corpus sections are visible placeholders and remain
disabled until phases 12 and 13. Functional settings are written immediately to
the versioned `settings.bin` store. Prediction changes hide old candidates and
invalidate the previous input context.

## Tray behavior

The tray menu is now:

```text
✓ Predictions enabled
  Settings...
  Exclude current application
✓ Start with Windows
  Exit
```

The application captured for `Exclude current application` is the last external
foreground application immediately before the tray menu opens. Opening the
settings window does not replace that captured target.

Pause unloads the keyboard hook, hides candidates, and prevents learning.
Resume reinstalls the hook and begins with an empty input context.

## Application exclusions

`exclusions.bin` uses a version, bounded record count, CRC32, and atomic file
replacement. Paths are normalized case-insensitively and limited to 128 EXE
entries. The settings window supports:

- adding the captured current application;
- browsing for an EXE;
- enabling or disabling an entry;
- removing an entry;
- viewing the complete normalized path.

Process paths are resolved on the prediction worker and cached by PID and
exclusion generation. The keyboard hook only compares window handles; it never
opens a process, reads a file, or waits for exclusion resolution.

## Forced protection

Prediction and learning are suppressed for:

- standard controls carrying `ES_PASSWORD`;
- password elements exposed through Windows UI Automation, including browser
  and Electron controls that publish `IsPassword` correctly;
- Windows credential, consent, and logon processes;
- processes whose executable path cannot be safely resolved;
- processes running at a higher integrity level than SysInput;
- SysInput's own settings window.

These protections cannot be overridden by a normal feature checkbox.

## Verification

```powershell
$env:ZIG_GLOBAL_CACHE_DIR = 'G:\SysInput\.zig-global-cache'
.\.tools\zig-windows-x86_64-0.14.0\zig.exe build test -Doptimize=ReleaseSafe --global-cache-dir $env:ZIG_GLOBAL_CACHE_DIR
.\.tools\zig-windows-x86_64-0.14.0\zig.exe build -Doptimize=ReleaseFast --global-cache-dir $env:ZIG_GLOBAL_CACHE_DIR
.\zig-out\bin\SysInput.exe --background --portable --no-startup-write
```

Manual checks should cover opening and closing Settings repeatedly, changing
each prediction switch, pause/resume, adding Notepad or another disposable test
application to the exclusion list, leaving that application, and testing a
standard password edit plus a browser password field.
