# SysInput

**SysInput** is a lightweight Windows utility written in [Zig](https://ziglang.org/download/). It provides English autocomplete, next-word prediction, phrase completion, abbreviations, and local personalization across Windows applications.

> **Release status:** `v0.2.0-rc.1`. This branch is a substantial, privacy-focused upgrade of [PeterM45/SysInput](https://github.com/PeterM45/SysInput). The original copyright and MIT license are preserved in [LICENSE](LICENSE); attribution details are in [NOTICE.md](NOTICE.md).

## Demo

![SysInput Demo](https://github.com/user-attachments/assets/95c258c5-f25d-4a10-8337-2f7532c056e5)

## Features

- **English-layout gating:** Prediction and learning stop when a non-English keyboard layout is active.
- **System-wide suggestions:** Compact Windows-style candidates near the active caret.
- **Progressive acceptance:** `Tab` accepts the next phrase chunk; `Ctrl+Right` accepts one word.
- **Local personalization:** Bounded word, context, phrase, and repeated-sentence learning.
- **Abbreviations and corpus import:** User-managed expansions plus local `.txt` and `.md` corpus indexes.
- **Runtime control:** Native tray menu, compact settings, temporary pause, startup choice, and application exclusions.
- **Privacy and efficiency:** No cloud model, telemetry, or grammar correction; idle CPU remains near zero.

## Installation

### Prerequisites

- Windows 10 or 11
- [Zig 0.14.0](https://ziglang.org/download/) for source builds

### Building from Source

```bash
git clone https://github.com/PeterM45/SysInput.git
cd SysInput
zig build
zig build run
```

### Windows installer

Release builds use Inno Setup 6 and install per-user without administrator privileges:

```powershell
powershell -ExecutionPolicy Bypass -File tools\build_release.ps1
```

The RC installer and SHA-256 checksum are written to `dist`. Standard Inno Setup options such as `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` are supported. User settings and learned data are preserved by default when uninstalling; automated removals may explicitly add `/DELETEUSERDATA` to remove SysInput-owned local data.

The application runs in the background. Type in any text field and press **Tab** to see suggestions.

For the complete release scope, migration behavior, validation results, and known release gates, see [CHANGELOG.md](CHANGELOG.md) and [docs/PHASE14_INSTALL_AND_RELEASE.md](docs/PHASE14_INSTALL_AND_RELEASE.md).

## Usage

1. Start typing in any text field (at least 2 characters).
2. Suggestions appear near your cursor.
3. Press **Tab** to accept the selected word or phrase chunk.
4. Use **Alt+Up/Down** to navigate suggestions without changing text.

### Keyboard Shortcuts

| Key         | Action              |
| ----------- | ------------------- |
| **Tab**              | Accept current word or chunk |
| **Ctrl+Right Arrow** | Accept one predicted word    |
| **Alt+Down Arrow**   | Next suggestion              |
| **Alt+Up Arrow**     | Previous suggestion          |
| **Arrow keys**       | Normal application movement  |
| **Enter**            | Normal application input     |
| **Esc**              | Hide suggestions             |

## Architecture

- **Core:** Text state, settings, data paths, exclusions, and diagnostics.
- **Input:** Lightweight keyboard event capture, layout gating, and text-field detection.
- **Suggestion:** Background worker, structured candidates, leases, ranking, and feedback.
- **Text:** Dictionary, personal profile, context, sentence, abbreviation, and corpus indexes.
- **UI:** Candidate overlay, placement, appearance, settings, abbreviation, and corpus windows.
- **Platform:** Win32 API bindings, protected-target guard, lifecycle, insertion, and text injection.

## Project Structure

```
SysInput/
├── .github/              - CI and pull-request template
├── docs/                 - Phase design and validation records
├── installer/            - Inno Setup release definition
├── resources/            - Dictionary, icon, and Win32 resources
├── src/
│   ├── core/             - Settings, profiles, buffer, and exclusions
│   ├── input/            - Hook-facing event decoding and language gate
│   ├── platform/windows/ - Win32 lifecycle, safety guard, and insertion
│   ├── suggestion/       - Worker, candidate model, leases, and manager
│   ├── text/             - Prediction and local-learning indexes
│   └── ui/               - Candidate, settings, abbreviation, and corpus UI
├── tools/                - Reproducible icon and release scripts
├── build.zig
└── build.zig.zon
```

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request. Changes must preserve the lightweight Hook boundary, local-only privacy model, original MIT attribution, and relevant regression tests.

## Troubleshooting

Stage 12 abbreviation setup and verification are described in
[docs/PHASE12_ABBREVIATIONS.md](docs/PHASE12_ABBREVIATIONS.md).
Local corpus import and prediction are described in
[docs/PHASE13_CORPUS.md](docs/PHASE13_CORPUS.md).

**No suggestions?**

- Ensure SysInput is running.
- Type in a standard text field (minimum 2 characters).

**Text insertion issues?**

- Try a different insertion method; some applications may have restrictions.

## License

This project is derived from [PeterM45/SysInput](https://github.com/PeterM45/SysInput) and remains licensed under the MIT License. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).

---

Feel free to tweak as needed. Happy coding! 👍
