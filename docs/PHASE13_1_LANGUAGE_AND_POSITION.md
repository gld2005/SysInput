# Phase 13.1: English input gate and safe popup placement

Phase 13.1 is a release prerequisite. It does not change the candidate visual
theme or settings-window layout and does not enter Phase 14.

## English-layout gate

SysInput now runs only when the foreground GUI thread owns an English keyboard
layout. The check uses the Windows keyboard-layout language ID; English regional
layouts such as United States, United Kingdom, and Australia are accepted.

When a Chinese or other non-English layout is active:

- the candidate window is hidden;
- physical keys are not added to the SysInput buffer;
- prediction and personal learning do not run;
- abbreviation expansion does not run;
- imported-corpus prediction does not run;
- stale candidates cannot be accepted by keyboard or mouse.

Switching languages invalidates the buffer, candidate lease, and cached caret
position. The hook performs no allocation, disk access, process-path lookup, or
prediction while checking the layout. The prediction worker repeats the gate
before any learning as a safety boundary.

Chinese IME English-character mode remains disabled in this version. The user
must switch to a Windows English keyboard layout to enable SysInput.

## Popup placement

The candidate popup is anchored to a real screen-space caret rectangle:

1. `GetGUIThreadInfo` system caret;
2. attached GUI-thread caret;
3. `EM_POSFROMCHAR` for Win32 Edit/RichEdit controls.

There is no mouse-cursor fallback. If no reliable caret or non-overlapping
placement is available, the popup remains hidden.

Placement rules:

- prefer 6 DPI-scaled pixels below the caret line;
- flip above the caret when the lower area is too small;
- never overlap the active input line;
- clamp horizontally to the current monitor work area;
- support monitors with negative desktop coordinates;
- calculate spacing and bounds using the focused window DPI.

## Manual verification

1. Select an English keyboard layout and type `conf` in Notepad. Verify a
   candidate appears close below the caret without covering the current line.
2. Move the Notepad window near the bottom of the monitor and type again. Verify
   the candidate flips above the input line.
3. Move the window to a secondary monitor, including one positioned left of the
   primary monitor, and repeat the test.
4. Repeat at 100%, 125%, 150%, and 200% display scaling where available.
5. With a candidate visible, switch to Microsoft Pinyin. Verify the candidate
   hides and typing produces no SysInput candidate.
6. Type a repeated Chinese/ASCII sequence under Microsoft Pinyin, return to the
   English layout, and verify the Chinese-layout input was not learned.
7. Switch back to English and verify prediction resumes from a clean context.
8. Repeat in Word, Chrome, and VS Code. If an application exposes no reliable
   system caret, verify SysInput suppresses the popup instead of showing it at
   the mouse pointer.
