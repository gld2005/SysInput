# Phase 10: Runtime settings, data directories, and application icon

Phase 10 adds the runtime foundation only. It does not add the settings window,
application exclusions, abbreviations, corpus import, or an installer.

## Runtime settings

`settings.bin` is a bounded binary record with a magic value, format version,
payload length, CRC32, and a fixed feature bit set. Updates use an atomic hot
read and a temporary-file + rename save. Invalid or unsupported files fall back
to the safe defaults and are repaired on startup.

Defaults:

- enabled: on
- start with Windows: on
- word, next-word, phrase, and sentence prediction: on
- personal learning: on
- safe arrow mode: on
- abbreviation and corpus prediction: off until their later phases

The tray's pause/resume and startup choices update the same settings store.
Prediction and learning code reads one settings snapshot per worker request;
the keyboard hook only performs an atomic read for arrow-key mode.

## Data modes

Standard mode uses `%LOCALAPPDATA%\SysInput`:

```text
SysInput\
├── settings.bin
├── profiles\
│   ├── profile.bin
│   ├── context.bin
│   └── sentences.bin
└── corpus\
```

Portable mode is selected with `--portable` and uses `data` beside the EXE.
Its startup registry command retains `--portable`.

Legacy profile files beside the EXE are copied into `profiles` only when the
destination is absent. The source is never deleted, so an interrupted or failed
migration cannot destroy the old learning data.

## Icon

`resources/sysinput-source.png` is an unchanged copy of the supplied artwork.
`tools/generate_icon.py` creates `resources/sysinput.ico` with 16, 20, 24, 32,
48, 64, 128, and 256 pixel entries. The ICO is embedded as the EXE icon and is
also loaded by the hidden lifecycle window and notification-area icon. Later
settings and installer phases can reuse the same resource.

## Verification

Run all generated files and caches on the G drive:

```powershell
$env:ZIG_GLOBAL_CACHE_DIR = 'G:\SysInput\.zig-global-cache'
.\.tools\zig-windows-x86_64-0.14.0\zig.exe build test -Doptimize=ReleaseSafe --global-cache-dir $env:ZIG_GLOBAL_CACHE_DIR
.\.tools\zig-windows-x86_64-0.14.0\zig.exe build -Doptimize=ReleaseFast --global-cache-dir $env:ZIG_GLOBAL_CACHE_DIR
```

For a non-invasive manual run that does not write standard-mode data to C:

```powershell
.\zig-out\bin\SysInput.exe --background --portable --no-startup-write
```

Check that the supplied icon appears in the tray and EXE properties, pause and
resume still work, ordinary arrow keys remain safe by default, and the old
`data\*.bin` files still exist after their copies appear in `data\profiles`.
