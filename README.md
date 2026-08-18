# SysInput

**SysInput** is a lightweight, local-only English input assistant for Windows, written in [Zig](https://ziglang.org/). It provides system-wide word completion, next-word and phrase prediction, abbreviation expansion, corpus-assisted suggestions, and bounded personalization.

> **Current release:** [`v0.2.0-rc.2`](https://github.com/gld2005/SysInput/releases/tag/v0.2.0-rc.2) on the `gld2005` branch. This is a release candidate and a substantial upgrade of [PeterM45/SysInput](https://github.com/PeterM45/SysInput), not an official upstream release. The original copyright and MIT license are preserved in [LICENSE](LICENSE); full attribution is in [NOTICE.md](NOTICE.md).

## Download v0.2.0-rc.2

- [Download the Windows installer](https://github.com/gld2005/SysInput/releases/download/v0.2.0-rc.2/SysInput-Setup-0.2.0-rc2.exe)
- [Download the SHA-256 checksum file](https://github.com/gld2005/SysInput/releases/download/v0.2.0-rc.2/SysInput-Setup-0.2.0-rc2.exe.sha256)
- [Open the GitHub Release page](https://github.com/gld2005/SysInput/releases/tag/v0.2.0-rc.2)

Installer SHA-256:

```text
0146b16d9905ea9f8d2062df8b8a4536239e99f3ff4244876bb0273fba81ae76
```

Verify it in PowerShell:

```powershell
(Get-FileHash .\SysInput-Setup-0.2.0-rc2.exe -Algorithm SHA256).Hash
```

The RC installer is not Authenticode-signed, so Windows may display an **Unknown publisher** warning. Verify the checksum before installation.

## What this version is for

SysInput is an input-assistance utility, not a grammar checker or language-learning tool. Its goal is to reduce English typing effort while remaining fast, private, and unobtrusive.

- Suggestions appear automatically near the active text caret.
- `Tab` accepts the next word or phrase chunk instead of inserting an entire sentence unexpectedly.
- `Ctrl+Right` accepts only one predicted word.
- Ordinary arrow keys remain available to the current application.
- Prediction and learning stop when a non-English keyboard layout is active.
- All prediction, learning, abbreviations, and imported corpus indexes stay on the local computer.
- No cloud model, account, synchronization, telemetry, or grammar correction is included.

## Main features

- **System-wide English suggestions:** Word completion across supported Windows text fields.
- **Context prediction:** Bounded next-word, phrase, and repeated-sentence continuation.
- **Progressive acceptance:** Accept one word or one phrase chunk at a time.
- **Personalization:** Deterministic local ranking based on typed and accepted suggestions.
- **Abbreviation expansion:** User-managed triggers and expansions.
- **Corpus-assisted prediction:** Import local UTF-8 `.txt` and `.md` material for phrase and sentence indexing.
- **English-layout gating:** Non-English layouts immediately disable prediction and learning.
- **Application exclusions:** Disable SysInput in selected programs.
- **Protected-input safeguards:** Password fields and unsupported protected targets fail closed.
- **Native Windows controls:** Tray menu, temporary pause, startup choice, compact settings, themes, accents, and density options.
- **Lightweight runtime:** Pure Zig and Win32 with no Electron, WebView, Qt, or third-party runtime.

## Installation

### Recommended: Windows installer

1. Download [`SysInput-Setup-0.2.0-rc2.exe`](https://github.com/gld2005/SysInput/releases/download/v0.2.0-rc.2/SysInput-Setup-0.2.0-rc2.exe).
2. Verify its SHA-256 checksum using the value above or the accompanying [checksum file](https://github.com/gld2005/SysInput/releases/download/v0.2.0-rc.2/SysInput-Setup-0.2.0-rc2.exe.sha256).
3. Run the installer and choose whether SysInput should start with Windows.
4. After launch, use the tray icon to open Settings, pause predictions, exclude an application, or exit.

The installer is per-user and does not require administrator privileges. User settings and learned data are preserved by default during uninstall. Selecting the data-removal option deletes SysInput-owned settings and indexes but never deletes the user's original corpus files.

### Build from source

Requirements:

- Windows 10 or Windows 11
- [Zig 0.14.0](https://ziglang.org/download/)
- Inno Setup 6 only when building the installer

```powershell
git clone --branch gld2005 https://github.com/gld2005/SysInput.git
cd SysInput
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast
```

Build the Windows installer:

```powershell
powershell -ExecutionPolicy Bypass -File tools\build_release.ps1
```

Release artifacts are written to `dist`.

## Usage

1. Start SysInput and switch to an English keyboard layout.
2. Type normally in a supported text field.
3. Suggestions appear near the caret without changing existing text.
4. Accept only when the suggestion is useful.

| Key | Action |
| --- | --- |
| `Tab` | Accept the current word or next phrase chunk |
| `Ctrl+Right Arrow` | Accept one predicted word |
| `Alt+Down Arrow` | Select the next suggestion |
| `Alt+Up Arrow` | Select the previous suggestion |
| Arrow keys | Normal application cursor movement |
| `Enter` | Normal application input |
| `Esc` | Hide suggestions |

## Runtime data and privacy

Installed mode stores SysInput-owned data under `%LOCALAPPDATA%\SysInput` by default. The **Settings > Data** page can select another writable local directory. A requested change is completed on the next launch, after the previous instance has saved its learning data; copying never deletes the previous directory. Portable mode always stores data in a `data` directory beside the executable and does not allow a separate custom location.

The data is separated into personal learning, imported-corpus indexes, abbreviations, exclusions, and settings. SysInput does not upload user input, corpus content, abbreviation content, diagnostics, or performance data.

The uninstaller preserves custom data directories. Remove a custom directory manually only after confirming that its learning data, abbreviations, and corpus indexes are no longer needed.

## Release-candidate validation

For `v0.2.0-rc.2`:

- 48 automated characterization and regression checks pass in `ReleaseFast`.
- Repeatable Hook and candidate benchmarks remain below the project targets of 1 ms P95 and 20 ms P95 respectively.
- Observed idle working set is approximately 14.5 MiB.
- The installer and matching SHA-256 file are generated from the verified `ReleaseFast` build.
- RC1 installation, startup, shutdown, shortcut, startup opt-out, and uninstall behavior remains covered by the release lifecycle baseline.

Before a stable `v0.2.0`, final interactive acceptance is still required across the complete application and system matrix listed in [CHANGELOG.md](CHANGELOG.md).

## Project structure

```text
SysInput/
├── .github/              CI and pull-request templates
├── docs/                 Design and validation records
├── installer/            Inno Setup release definition
├── resources/            Dictionary, icon, and Win32 resources
├── src/
│   ├── core/             Settings, profiles, buffer, and exclusions
│   ├── input/            Event decoding and language gating
│   ├── platform/windows/ Win32 lifecycle, safeguards, and insertion
│   ├── suggestion/       Worker, candidates, leases, and ranking
│   ├── text/             Prediction and local indexes
│   └── ui/               Candidate and management windows
├── tools/                Icon and release scripts
├── build.zig
└── build.zig.zon
```

## Documentation

- [Release history and known gates](CHANGELOG.md)
- [Installation and release validation](docs/PHASE14_INSTALL_AND_RELEASE.md)
- [RC2 release notes](docs/RELEASE_NOTES_0.2.0_RC2.md)
- [Custom data directory](docs/CUSTOM_DATA_DIRECTORY.md)
- [Abbreviation management](docs/PHASE12_ABBREVIATIONS.md)
- [Corpus import and prediction](docs/PHASE13_CORPUS.md)
- [Contribution guide](CONTRIBUTING.md)

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first. Changes should preserve the lightweight keyboard-Hook boundary, local-only privacy model, original MIT attribution, and relevant regression tests.

## License and attribution

This project is derived from [PeterM45/SysInput](https://github.com/PeterM45/SysInput) and remains licensed under the MIT License.

- Original author: PeterM45
- Original copyright: Copyright (c) 2025 PeterM45
- License: [MIT](LICENSE)
- Fork attribution and modification notice: [NOTICE.md](NOTICE.md)

The `gld2005` release is not presented as an official release of, or endorsement by, the original author.
