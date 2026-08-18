# Changelog

This changelog describes changes on the `gld2005` branch relative to the original upstream project. The project follows semantic versioning for release labels.

## 0.2.0-rc.1 - 2026-08-18

### Release intent

This release candidate turns SysInput into a lightweight, local-only English input assistant. It deliberately does not add grammar correction, language-learning lessons, cloud inference, synchronization, or telemetry.

### Added

- Correct Windows keyboard-state and active-layout decoding with injected-event filtering.
- Fixed-capacity event handoff and background prediction with generation checks that discard stale results.
- Structured word, next-word, phrase, repeated-sentence, abbreviation, and corpus candidates.
- Progressive acceptance: `Tab` accepts a word or phrase chunk and `Ctrl+Right` accepts one predicted word.
- Ranked English dictionary lookup, bounded personal word preferences, and deterministic scoring.
- Bounded 2-5 word context learning plus repeated-sentence continuation and confidence suppression.
- Versioned, CRC-protected local settings and profile persistence with atomic replacement.
- English keyboard-layout gating: non-English layouts disable prediction, learning, abbreviations, and corpus lookup.
- Native tray controls, single-instance lifecycle, temporary pause, application exclusions, compact paged settings, and startup choice.
- User-managed abbreviations and background `.txt`/`.md` corpus indexing.
- Windows-style candidate themes, accents, density options, caret-relative multi-monitor placement, and high-contrast precedence.
- Current-user Inno Setup installer, normal shutdown protocol, upgrade preservation, selectable startup and shortcuts, and optional data removal.

### Changed

- Candidate navigation is read-only. Ordinary arrow keys always remain with the target application.
- `Enter` no longer accepts candidates; `Esc` only hides them.
- Prediction, disk access, process lookup, and waits are kept outside the low-level keyboard Hook.
- Runtime data is separated from program files and uses `%LOCALAPPDATA%\SysInput` in installed mode or `data` beside a portable executable.
- Candidate display remains a vertical list to keep long phrases readable while adopting a compact Windows visual style.

### Privacy and safety

- No user input, corpus content, abbreviations, diagnostics, or performance data are uploaded.
- Password controls, protected security processes, higher-integrity windows, excluded applications, and unsupported targets fail closed.
- Imported source files are never deleted by SysInput or its uninstaller.
- Feedback remains a disabled placeholder in this RC.

### Validation

- 47 automated characterization and regression checks pass in `ReleaseFast`.
- Repeatable benchmarks remain below the project limits of 1 ms Hook P95 and 20 ms candidate P95.
- Observed idle working set is approximately 14.5 MiB with zero CPU growth during the sampling window.
- Fresh install, selected-directory install, startup opt-in/out, running upgrade, preserved-data uninstall, explicit full-data uninstall, shortcuts, and normal shutdown were exercised successfully.

### Known release gates

- The RC installer is not Authenticode-signed and may display an unknown-publisher warning.
- Notepad, Word, Outlook, Chrome, Edge, VS Code, Electron, Win32 Edit/RichEdit, password fields, elevated windows, multi-monitor DPI, full-screen, sleep/wake, and sign-in flows require final interactive acceptance before a stable `0.2.0` release.

## Upstream baseline

All work remains subject to the upstream MIT license and copyright notice. See [NOTICE.md](NOTICE.md) for attribution.
