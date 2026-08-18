# Phase 13.2: Windows-style candidate appearance

Phase 13.2 changes only candidate appearance and its bounded appearance
settings. It does not redesign the main settings window, add Feedback, or enter
Phase 13.3/14.

## Candidate surface

The existing vertical candidate layout remains because it can display long
phrase and sentence continuations without creating an excessively wide bar.
The drawing now uses a compact Windows-style surface:

- Segoe UI with DPI-scaled metrics;
- neutral light or dark background;
- subtle selected-row surface;
- a three-pixel accent indicator;
- Windows 11 DWM rounded corners when supported;
- a neutral fallback border on older Windows builds;
- ellipsis for text wider than the current monitor work area;
- double-buffered GDI drawing to avoid white flashes and selection flicker.

Win32 colors are created through an RGB-to-`COLORREF` helper. This fixes the
old byte-order error that rendered the intended blue selection as orange.

## Appearance settings

Open **Settings > Candidate appearance...**. The temporary compact appearance
dialog offers:

```text
Theme:  Follow Windows / Light / Dark
Accent: Windows accent / Blue / Teal / Purple
Density: Compact / Comfortable
```

The main settings layout is intentionally not restructured in this phase;
Phase 13.3 will integrate these controls into the final compact settings pages.

Settings are stored in settings format v3 with CRC and atomic replacement.
Existing v1 and v2 files remain readable and receive the safe defaults:

```text
Follow Windows + Windows accent + Compact
```

Windows High Contrast overrides custom theme colors. Follow Windows refreshes
when the candidate window receives a system settings-change notification.

## Runtime boundaries

- The keyboard hook does not resolve themes or read appearance settings files.
- Theme registry and DWM color queries run only on the UI/settings path.
- No image assets, web UI, framework, animation timer, or third-party runtime
  was added.
- The candidate window remains non-activating and cannot steal typing focus.

## Manual verification

1. Open **Settings > Candidate appearance...** and select Dark, Blue, Compact.
2. Type in Notepad under an English keyboard layout and verify a dark neutral
   candidate surface with a blue accent indicator.
3. Switch Light/Dark and all four accent options; verify the next candidate
   uses the new colors without restarting SysInput.
4. Switch Compact/Comfortable and verify row height changes while the popup
   stays anchored away from the input line.
5. Restart SysInput and verify the selected appearance remains active.
6. Select Follow Windows, change Windows app theme, then produce a new
   candidate and verify it follows the system theme.
7. Check 125%, 150%, and 200% DPI for readable text, correct spacing, rounded
   corners, and no clipped candidate rows.
8. Test a long phrase near the right screen edge and verify it is constrained
   to the monitor and ellipsized rather than extending off-screen.
9. Verify Tab, Ctrl+Right, Alt+Up/Down, mouse acceptance, English-only gating,
   and candidate positioning remain unchanged.
