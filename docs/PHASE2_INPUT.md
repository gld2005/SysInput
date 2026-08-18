# SysInput v0.2 Phase 2: Input Correctness

Completed on 2026-08-18 on the `gld2005` branch. This phase changes only the
physical keyboard input, injected-event filtering, and internal input-state
synchronization paths. It does not implement later roadmap features.

## Changes

### Active keyboard-layout decoding

- Replaced direct `vkCode` to `u8` truncation with `GetKeyboardState` and
  `ToUnicodeEx`.
- Uses the foreground application's keyboard layout.
- Tracks left, right, and generic Shift/Ctrl/Alt states.
- Preserves Caps Lock behavior.
- Accepts printable ASCII only, matching the English-only product scope.
- Shortcut chords using Ctrl or Alt are not interpreted as typed text.
- Uses `TO_UNICODE_NO_STATE_CHANGE` so prediction does not consume dead-key
  state from the active application.

### Injected event filtering

- Events marked `LLKHF_INJECTED` or `LLKHF_LOWER_IL_INJECTED` are passed to the
  destination but skipped by SysInput's buffer, prediction, and learning path.
- This prevents accepted suggestions and other simulated input from feeding
  back into the physical-input pipeline.

### Input-state synchronization

- Focus resolution now uses `GetGUIThreadInfo` on the foreground application's
  GUI thread instead of relying only on `GetFocus` from SysInput's thread.
- Standard Edit/RichEdit synchronization restores the actual selection end as
  the internal cursor position.
- Mouse or keyboard caret movement in standard controls is detected through a
  lightweight `EM_GETSEL` check.
- Left and Right Arrow update the internal cursor locally.
- Navigation whose visual result cannot be inferred safely invalidates context
  and causes a fresh control read before the next printable key.
- Focus changes discard text belonging to the previous application.
- Physical character, Backspace, Delete, Return, and Ctrl+Backspace events now
  update only the internal buffer. They no longer rewrite the entire target
  text field before the original key reaches the application.
- The previous synchronous 5 ms and 20 ms sleeps were removed from regular
  Backspace and Ctrl+Backspace hook handling.
- Ctrl+Backspace reaches the destination exactly once.

### Buffer safety

- `TextBuffer.getCurrentWord` now returns a slice backed by the live continuous
  buffer instead of a local temporary array.
- Added absolute internal cursor positioning.
- Added internal Ctrl+Backspace behavior for word removal.

## Preserved behavior

The following behavior is intentionally unchanged because it belongs to later
phases:

- Existing suggestion-window design.
- Existing word-only candidate representation.
- Tab, Right Arrow, and Enter acceptance behavior while suggestions are open.
- Escape still exits the process.
- Prediction still runs synchronously after internal input changes.
- Personal vocabulary remains memory-only.
- No startup, tray, phrase, sentence, or password-field feature was added.

## Verification

Commands:

```powershell
zig build
zig build test
zig build baseline -Doptimize=ReleaseFast
```

Characterization result:

```text
SysInput characterization: 9/9 checks passed
```

The added checks cover injected-event classification, left/right modifier
state, active-layout case translation, cursor-aware word extraction, and
Ctrl+Backspace behavior in addition to the Phase 1 checks.

ReleaseFast hidden-start smoke sample:

```text
running=true
executable_bytes=675840
working_set_bytes=6803456
private_memory_bytes=2093056
cpu_seconds_over_500ms=0
threads=4
handles=60
```

The process installed its hook, remained alive for the sample, and was then
terminated by exact process ID. Build artifacts remain under the repository's
ignored build and cache directories.

## Remaining input risks

- Generic browser and Electron fields still depend on existing fallback text
  detection because UI Automation or browser-specific integration is outside
  this phase.
- Selecting a range in a standard control discards internal context before the
  replacement key rather than modeling the entire selection operation.
- Prediction and UI work still execute synchronously in the hook-triggered
  path. Moving those operations to a worker is a separate planned phase.
- Mouse caret changes in controls that do not support `EM_GETSEL` cannot be
  detected precisely by this phase.
