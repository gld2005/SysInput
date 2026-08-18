# Phase 9.1: Interaction safety

Phase 9.1 prevents suggestion display and ordinary cursor navigation from
changing user text. It does not implement runtime settings or any later phase.

## Read-only candidate UI

Showing, refreshing, or highlighting a candidate is now a presentation-only
operation. The candidate window no longer calls direct or selection-based text
completion while it is displayed or navigated.

Text insertion has exactly three explicit entry points:

- `Tab` accepts the current word or chunk;
- `Ctrl+Right Arrow` accepts one word;
- clicking a candidate accepts its current chunk.

## Safe key contract

| Key | Behavior while candidates are visible |
| --- | --- |
| `Tab` | accept the selected word or chunk |
| `Ctrl+Right Arrow` | accept one word |
| `Alt+Up/Down` | change the highlighted candidate only |
| plain arrow keys | pass through to the target application |
| `Enter` | pass through |
| `Esc` | hide candidates |

Plain cursor movement hides the current candidate and invalidates its input
context. Modified navigation and application shortcuts are passed through and
discard the stale shadow context when their resulting caret position cannot be
predicted safely.

## Candidate lease

Every visible candidate is bound to:

- the latest submitted prediction version;
- the foreground application window;
- the focused input control;
- the control selection range;
- a real caret anchor when the control exposes one;
- the exact shadow text and current word.

Acceptance and candidate navigation revalidate the lease. A mismatch hides the
window without inserting text. Optimistically retained Phase 9 remainders are
rebound to the newly submitted background version, so repeated progressive
acceptance remains available without accepting an older result.

## Mouse behavior

The popup remains non-activating. A click updates the selected row and calls
the same lease-checked acceptance path as the keyboard. Hovering and repainting
do not modify the target application.

## Verification

The characterization suite covers safe modifier mappings and lease invalidation
for version, application, focused control, selection, and caret changes. The
full suite remains responsible for progressive acceptance, worker versioning,
input decoding, profiles, and prediction regressions.
