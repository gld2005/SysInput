# SysInput

**SysInput** is a lightweight Windows utility written in [Zig](https://ziglang.org/download/). It provides system-wide autocomplete and spell checking across all applications by capturing keystrokes and displaying suggestions near your cursor.

## Demo

![SysInput Demo](https://github.com/user-attachments/assets/95c258c5-f25d-4a10-8337-2f7532c056e5)

## Features

- **System-wide suggestions:** Works in any standard text field.
- **Intelligent autocomplete:** Learns from your typing.
- **Low resource usage:** Efficiently built in Zig ⚡
- **Adaptive learning:** Optimizes insertion methods per application

## Installation

### Prerequisites

- Windows 10 or 11
- [Zig 0.14.0](https://ziglang.org/download/) (or later)

### Building from Source

```bash
git clone https://github.com/PeterM45/SysInput.git
cd SysInput
zig build
zig build run
```

The application runs in the background. Type in any text field and press **Tab** to see suggestions.

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

- **Core:** Text buffer, configuration, and debugging.
- **Input:** Keyboard hooks and text field detection.
- **Text:** Autocomplete engine, dictionary management, and spell checking.
- **UI:** Suggestion overlay and window management.
- **Win32:** Windows API bindings and hook implementations.

## Project Structure

```
SysInput/
├── build.zig             - Build configuration
├── resources/
│   └── dictionary.txt    - Word dictionary for suggestions
└── src/
    ├── buffer_controller.zig - Text buffer management
    ├── core/               - Core functionality
    │   ├── buffer.zig      - Text buffer implementation
    │   ├── config.zig      - Configuration
    │   └── debug.zig       - Debugging utilities
    ├── input/             - Input handling
    │   ├── keyboard.zig    - Keyboard hook and processing
    │   ├── text_field.zig  - Text field detection
    │   └── window_detection.zig  - Window detection
    ├── main.zig           - Application entry point
    ├── module_exports.zig    - Main module imports
    ├── suggestion/        - Suggestion handling
    │   ├── manager.zig     - Suggestion manager
    │   └── stats.zig       - Statistics tracking
    ├── text/              - Text processing
    │   ├── autocomplete.zig - Autocomplete engine
    │   ├── dictionary.zig   - Dictionary loading/management
    │   ├── edit_distance.zig - Text similarity algorithms
    │   ├── insertion.zig     - Text insertion methods
    │   └── spellcheck.zig    - Spell checking
    ├── ui/                - User interface
    │   ├── position.zig    - UI positioning logic
    │   ├── suggestion_ui.zig - Suggestion UI
    │   └── window.zig      - Window management
    └── win32/             - Windows API bindings
        ├── api.zig         - Windows API definitions
        ├── hook.zig        - Hook implementation
        └── text_inject.zig - Text injection utilities
```

## Contributing

Contributions are welcome! To get started:

1. Fork the repository.
2. Clone your fork.
3. Create a branch for your changes.
4. Submit a pull request.

Check out our contribution guidelines for more details.

## Troubleshooting

Stage 12 abbreviation setup and verification are described in
[docs/PHASE12_ABBREVIATIONS.md](docs/PHASE12_ABBREVIATIONS.md).

**No suggestions?**

- Ensure SysInput is running.
- Type in a standard text field (minimum 2 characters).

**Text insertion issues?**

- Try a different insertion method; some applications may have restrictions.

## License

This project is licensed under the MIT License – see the [LICENSE](LICENSE) file for details.

---

Feel free to tweak as needed. Happy coding! 👍
