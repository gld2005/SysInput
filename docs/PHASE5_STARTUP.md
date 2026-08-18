# SysInput v0.2 Phase 5: Silent Startup and Lifecycle

Completed on 2026-08-18 on the `gld2005` branch. This is the formal Phase 5
from the approved engineering roadmap. It adds Windows lifecycle integration
without changing prediction ranking, personal-word persistence, or candidate
presentation.

## Silent application model

The production executable now uses the Windows GUI subsystem. Starting it does
not create a console window or a normal application window. `--background` is
accepted for the Windows login launch path; normal and background launches both
remain tray-only.

A named current-session Mutex is acquired before dictionaries, UI, the worker,
or the keyboard hook are initialized. If the Mutex already exists, the second
process exits successfully without creating another tray icon or hook.

## Startup registration

SysInput uses the current-user Run key and does not require administrator
rights:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
SysInput="C:\Path\To\SysInput.exe" --background
```

The command always quotes the absolute executable path. A missing Run value is
never created merely because SysInput launches. The installer exposes an
explicit startup task, and the user can change the same preference from the
tray or Settings. Upgrades preserve the existing selection and refresh an
enabled installed-mode path when necessary.

`--no-startup-write` is available for automated diagnostics so tests can run
without changing the user's startup preference.

## Tray controls

The tray icon owns only a hidden Win32 message window and uses the existing
message loop. Its menu contains:

- `Pause predictions` / `Enable predictions`: uninstalls or reinstalls the
  keyboard hook while leaving the idle message-driven process alive.
- `Start with Windows`: toggles the HKCU Run entry and preserves that choice.
- `Exit`: posts the normal quit message so hooks, the tray icon, the worker,
  windows, and the Mutex are released in order.

The tray tooltip reports whether SysInput is enabled or paused. No polling
thread, framework, third-party runtime, or administrator service was added.

## Keyboard lifecycle behavior

- `Esc` no longer terminates SysInput. It hides an active candidate window and
  continues to the target application.
- `Enter` is no longer treated as candidate acceptance. It continues through
  the normal input path.
- Tab and Right Arrow retain the Phase 4 word-completion behavior.

## Verification

```text
Debug build: passed
Debug characterization checks: 13/13 passed
ReleaseSafe characterization checks: 13/13 passed
PE optional-header subsystem: 2 (Windows GUI)
git diff --check: passed
```

The new lifecycle characterization check covers argument parsing, quoted Run
commands, named-Mutex duplicate rejection, and the frozen Esc/Enter/Tab/Right
key classification.

ReleaseFast prediction baseline remained:

```text
dictionary_words=9974
dictionary_load_ms=1.307
learn_1000_words_ms=0.145
suggestion_queries=1000
suggestion_avg_ms=0.020
suggestion_min_ms=0.003
suggestion_max_ms=0.141
working_set_mib=5.270
```

ReleaseFast live lifecycle sample:

```text
executable_bytes=686592
first_instance_running=true
second_instance_exited=true
second_exit_code=0
main_window_title=(empty)
working_set_bytes=12005376
private_memory_bytes=19812352
cpu_seconds_over_500ms=0
threads=5
handles=136
```

The higher idle handle and working-set sample relative to Phase 4 includes the
Shell tray integration and Windows GUI lifecycle resources. The process was
terminated by exact process ID after sampling; the requested current-user Run
entry remains enabled.
