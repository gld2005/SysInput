# SysInput v0.2 Phase 1 Baseline

Recorded on 2026-08-18 from commit `e909192251444242ee63119b8ee6ab0db5c0adeb`
on the `gld2005` branch. No product behavior was intentionally changed during
this phase.

## Environment

- OS: Microsoft Windows NT 10.0.26200.0, 64-bit
- Logical processors: 22
- Zig: 0.14.0 portable toolchain under `G:\SysInput\.tools`
- Build mode used for measurements: `ReleaseFast`
- Bundled dictionary entries loaded: 9,974

The project-local Zig global cache is `G:\SysInput\.zig-global-cache`. This
keeps project-generated tool, cache, test, and build data on the G drive.

## Repeatable commands

Run these commands from `G:\SysInput` in PowerShell:

```powershell
$env:ZIG_GLOBAL_CACHE_DIR = 'G:\SysInput\.zig-global-cache'
.\.tools\zig-windows-x86_64-0.14.0\zig.exe build
.\.tools\zig-windows-x86_64-0.14.0\zig.exe build test
.\.tools\zig-windows-x86_64-0.14.0\zig.exe build baseline -Doptimize=ReleaseFast
```

`zig build test` is a characterization executable instead of Zig's default
test runner because the existing modules resolve shared imports through
`@import("root").sysinput`. This preserves the current module contract without
requiring a product-code refactor in the baseline phase.

## Automated characterization

The current suite covers six behavior groups:

1. Text-buffer insertion and backspace.
2. Current word-character classification.
3. Edit-distance and completion scoring.
4. In-memory usage-stat calculations.
5. Bundled dictionary loading and case-insensitive lookup.
6. Personal word-frequency priority over dictionary fallback.

Result:

```text
SysInput baseline characterization: 6/6 checks passed
```

## Prediction microbenchmark

The benchmark loads the real bundled dictionary, learns 1,000 synthetic user
words, and performs 1,000 prefix queries while rotating prefixes to avoid
measuring only an immediate cache hit.

```text
dictionary_words=9974
dictionary_load_ms=1.417
learn_1000_words_ms=0.132
suggestion_queries=1000
suggestion_avg_ms=0.020
suggestion_min_ms=0.003
suggestion_max_ms=0.137
working_set_mib=5.270
```

These numbers are a local comparison point, not a cross-machine performance
guarantee. The benchmark does not install the global keyboard hook or render
the suggestion window.

## Release executable idle sample

The `ReleaseFast` executable was started hidden, allowed to settle for three
seconds, sampled, and then the exact test process was terminated.

```text
executable_bytes=673792
working_set_bytes=7380992
private_memory_bytes=2072576
cpu_seconds_over_500ms=0
threads=4
handles=60
```

Equivalent rounded values:

- Executable: 658 KiB
- Working set: 7.04 MiB
- Private memory: 1.98 MiB
- Observed idle CPU during the 500 ms sample: 0 seconds

## Compatibility baseline

Phase 1 does not automate typing into user applications. Doing so could modify
an active document or browser field. The following matrix records the current
code paths and the manual checks required before a stable release.

| Application class | Existing path | Automated status |
| --- | --- | --- |
| Win32 Edit / Notepad | Dedicated key-simulation and insertion handling | Build verified; interactive behavior not automated |
| RichEdit | Window-class positioning adjustment | Build verified; interactive behavior not automated |
| Word / Outlook | Generic detection and insertion fallback | Not verified automatically |
| Chrome / Edge | Generic detection and insertion fallback | Not verified automatically |
| VS Code / Electron | Generic detection and insertion fallback | Not verified automatically |
| Password fields | No explicit exclusion found | Protection not established |

Manual checks for a future compatibility run:

- Suggestions appear after the configured two-character threshold.
- Up/Down changes selection without moving the application caret.
- Tab, Right Arrow, and Enter follow the current acceptance behavior.
- Accepted text replaces the partial word exactly once.
- Clipboard content is restored after clipboard-based insertion.
- Backspace, Delete, Ctrl+Backspace, focus changes, and caret movement resync.
- Suggestion position remains usable at screen edges and non-100% DPI.

## Existing risks captured by the baseline

These are observations only; they were not fixed in Phase 1.

- The keyboard hook converts a virtual key code directly to `u8`, so Shift,
  Caps Lock, punctuation, and keyboard-layout behavior are not reliable.
- The hook path includes synchronous sleeps and suggestion work.
- Escape exits the process globally instead of only hiding suggestions.
- Enter consumption is hard-coded in the keyboard handler.
- `TextBuffer.getCurrentWord` returns a slice backed by a local temporary
  buffer, creating a lifetime risk.
- The suggestion cache stores borrowed result slices that may be freed before
  a later cache hit.
- Base dictionary candidates come from hash-map iteration and therefore do not
  have a stable frequency-based order.
- Personal word frequencies and statistics are memory-only.
- The transposition branch in edit distance is bypassed by an earlier prefix
  check for `teh`/`the`; the characterized current result is distance 3.
- No explicit password-field prediction guard was found.

These findings define the starting point for later phases. They are not an
authorization to begin those phases.
