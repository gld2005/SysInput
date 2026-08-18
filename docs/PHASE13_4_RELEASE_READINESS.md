# Phase 13.4 - Release readiness

Phase 14 remains frozen. This phase closes pre-release interaction and startup-policy gaps, then records the remaining manual acceptance checks.

## Tray reliability

`NOTIFYICON_VERSION_4` packs the mouse event into the low word of `lParam` and the icon identifier into the high word. SysInput now decodes the low word before dispatching clicks, so right-click opens the native menu and left-click opens Settings.

The menu includes a final `Exit SysInput` command. Exit posts the normal application quit message so profile shutdown and registered cleanup handlers run.

## Startup policy

- A missing setting or registry entry never silently enables startup.
- Portable mode never writes or refreshes a startup entry merely because the program launched.
- An existing installed-mode startup choice is retained and its executable path may be refreshed after an upgrade.
- The user can still change startup from Settings or the tray menu.
- The phase 14 installer will own the initial opt-in checkbox.

## Automated acceptance

- English-layout gating and stale-context invalidation.
- Candidate placement against caret rectangles, monitor work areas, and representative DPI scales.
- Theme, accent, density, and high-contrast precedence.
- Safe arrow-key behavior and candidate leases.
- Tray version-4 event decoding, tooltip state, and startup policy.
- Prediction and Hook-path performance baselines.

## Manual acceptance checklist

1. Right-click the tray icon; verify the menu opens and `Exit SysInput` is the final command.
2. Left-click the tray icon; verify Settings opens.
3. Select Exit; verify the icon and process disappear normally.
4. Switch between English and Microsoft Pinyin; verify candidates appear only on the English layout.
5. Check candidate placement in Notepad, Word, Chrome, Edge, and VS Code.
6. Repeat placement checks at 100%, 125%, 150%, and 200% DPI on each available monitor.
7. Verify Light, Dark, and Follow Windows plus all accents and densities.
8. Verify the compact Settings window is not clipped at 100% and 150% DPI.
9. Relaunch portable mode with no existing startup entry and verify it does not create one.

Any failed manual item blocks phase 14.
