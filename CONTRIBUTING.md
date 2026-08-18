# Contributing to SysInput

Thank you for improving SysInput. This branch is intended to remain a small native Windows input assistant rather than a general writing suite.

## Before changing code

- Keep the original MIT license and PeterM45 copyright notice intact.
- Keep the keyboard Hook non-blocking: no prediction, disk I/O, process-path lookup, network access, waits, or sleeps in the Hook callback.
- Do not introduce cloud inference, telemetry, grammar correction, Electron, WebView, Qt, or a resident third-party runtime.
- Preserve ordinary arrow-key behavior and the candidate lease checks.
- Fail closed for passwords, protected surfaces, higher-integrity windows, and unknown targets.

## Build and test

Requirements:

- Windows 10 or 11
- Zig 0.14.0

Run:

```powershell
zig fmt src build.zig
zig build test -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast
zig build baseline -Doptimize=ReleaseFast
```

Installer changes additionally require Inno Setup 6:

```powershell
powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -InnoCompiler "C:\path\to\ISCC.exe"
```

## Pull requests

- Keep each commit focused and use an imperative summary.
- Describe the user impact, root cause for fixes, privacy implications, and performance implications.
- Add or update regression tests for behavior changes.
- Report automatic checks and the applications used for manual testing.
- Do not commit `zig-out`, caches, local profiles, imported corpora, installers, signing material, or diagnostic logs.
- Do not claim upstream endorsement. Branch-specific branding should be clearly identified.

By contributing, you agree that your contribution is provided under the repository's MIT license.
