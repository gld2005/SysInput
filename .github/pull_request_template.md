## Summary

<!-- What changed and why? -->

## User impact

<!-- Describe visible behavior, compatibility changes, and migration impact. -->

## Technical notes

<!-- Include the root cause for fixes and key design constraints. -->

## Privacy and safety

- [ ] No input content, corpus content, abbreviations, or diagnostics are uploaded.
- [ ] Password/protected-window and application-exclusion behavior remains fail-closed.
- [ ] Ordinary arrow keys remain owned by the target application.

## Performance

- [ ] No disk I/O, prediction, waiting, or process lookup was added to the keyboard Hook.
- [ ] Hook P95 remains below 1 ms.
- [ ] Candidate P95 remains below 20 ms.
- [ ] Idle CPU and memory were checked when relevant.

## Validation

- [ ] `zig build test -Doptimize=ReleaseFast`
- [ ] `zig build -Doptimize=ReleaseFast`
- [ ] Relevant manual Windows application checks

Manual applications and results:

<!-- Notepad, Word, Outlook, Chrome, Edge, VS Code, Electron, Win32 Edit/RichEdit, DPI, etc. -->

## Attribution

- [ ] The original PeterM45 copyright and MIT license remain intact.
- [ ] New third-party code or assets are identified with compatible licensing.
