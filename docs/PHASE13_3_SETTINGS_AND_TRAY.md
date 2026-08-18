# Phase 13.3 - Compact settings and tray controls

Phase 13.3 keeps the Windows-native, dependency-free UI while reducing the main settings window to a compact paged layout.

## Settings window

The `620 x 480` settings window has a narrow navigation list and displays only one page at a time:

- General
- Prediction
- Appearance
- Keyboard
- Applications
- Data
- About

Theme, accent, and density now live directly on the Appearance page. Abbreviation and corpus management remain separate on-demand windows so their tables do not make the main window crowded. Closing settings hides the window and leaves no repaint loop running.

## Tray menu

The native tray menu provides:

- Predictions enabled
- Settings
- Pause for 30 minutes
- Exclude current application
- Feedback placeholder (disabled)
- Start with Windows
- About
- Exit

The temporary pause uninstalls the keyboard hook, hides candidates, and clears the physical input context without changing the persisted enabled preference. The hook is restored after the timer expires, provided predictions are still enabled. Opening About routes directly to the About settings page.

## Manual verification

1. Launch `SysInput.exe --background --portable --no-startup-write`.
2. Right-click the tray icon and verify every item above appears; Feedback must be disabled.
3. Select About and confirm the compact settings window opens directly on About.
4. Navigate all seven pages and verify only the selected page is visible.
5. Change Theme, Accent, and Density and verify the next candidate uses the new appearance.
6. Select Pause for 30 minutes and verify the tray tooltip reports the paused state and no candidate appears.
7. Re-enable Predictions from the tray and verify input assistance resumes immediately.
8. Close settings and confirm the process remains idle with no persistent settings-window CPU activity.

Phase 14 remains frozen. Feedback navigation and installer behavior are intentionally not implemented here.
