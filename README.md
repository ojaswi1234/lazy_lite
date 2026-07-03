# 🍃 LazyLite

LazyLite is a highly customized, portable configuration for [Lite-XL](https://lite-xl.com/). It transforms the lightweight editor into a modern, beautifully themed, VS Code-like powerhouse with an integrated terminal, a custom Git status bar, and an incredibly powerful built-in AI coding assistant (Antigravity).

Built around a soothing **Everforest Light ("Mossy")** aesthetic, it is designed to be elegant, extremely fast, and easy to deploy across any OS.

---

## ✨ Features

- **Mossy Everforest Theme**: A curated, pixel-perfect sage green light theme. UI contrast dynamically adjusts luminance to perfectly match Light/Dark modes while retaining the same color hue. *All panels (Statusbar, File Explorer, Terminal, and AI Sidebar) seamlessly inherit and shift these colors dynamically in real-time.*
- **VS Code Layout**: Familiar panel arrangements with a left-side file explorer, bottom terminal, and right-side AI assistant.
- **Conversational AI Sidebar**: A native AI chat UI powered by the [Antigravity CLI](https://antigravity.dev/). Features:
  - **Typewriter Output Streaming** — intercepts large piped buffers and smoothly reveals the LLM's response character-by-character with auto-scroll for a seamless streaming experience.
  - **`@`-mention file picker** — type `@` to fuzzy-search and attach any project file. The CLI reads it natively via `--add-dir`, no manual embedding.
  - **Multi-turn memory** — uses `-c` (`--continue`) automatically after the first message so the AI remembers the full conversation.
  - **Model switcher** — a `[M]` pill button in the header opens a live dropdown. Fetches the real model list via `agy models` in the background. Models with exhausted quotas are flagged with a red `(L)`. Switching models resets the session cleanly.
  - **Quick-action pills** — one-click Explain / Refactor / Fix / Tests / Docs actions.
  - **Conversation reset** — `Ctrl+Enter` clears history and starts a fresh session.
- **Smart Auto-Healer**: Intercepts Lua crashes in real-time and dispatches them to the AI for analysis. Features error debouncing to prevent spam and true autonomous healing (the AI applies fixes directly without waiting for manual approval). It also has a `KNOWN_PATTERNS` registry for common, diagnosable issues that get targeted instant fixes — *without wasting AI tokens*. Currently registered patterns:
  - **`agy` CLI timeout** — detected automatically after 60 seconds of silence. Prompts you to run `agy install` via a single `y` in the Command Palette, which opens the integrated terminal and runs it for you.
  - Falls back to the generic AI healer for any unknown error.
- **Auto-Close Brackets**: Automatically closes `{}`, `[]`, `()`, `""`, `''`, and ` `` `. Steps over existing closing pairs instead of duplicating them, wraps highlighted selections when you type a bracket, and smart-deletes empty pairs on Backspace.
- **Integrated Terminal**: Native command runner featuring a shell selector dropdown (cmd/powershell/bash), bold headlined titles, robust cursor movement, full text selection with the mouse, clipboard copying via `Ctrl+Shift+C`, VS Code-style `Up`/`Down` command history, visual screen clearing (`cls`/`clear`), and ultra-fast 64KB chunked IPC buffering that will never lag the editor.
- **Real-Time Resource Monitor**: A gorgeous, animated CPU and RAM sparkline chart injected directly into the top-right of your window titlebar. Cross-platform: uses PowerShell WMI on Windows and `/proc/stat` + `free` on Linux.

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action | Context |
| :--- | :--- | :--- |
| <kbd>Ctrl</kbd> + <kbd>B</kbd> | Toggle File Explorer | Global |
| <kbd>Ctrl</kbd> + <kbd>`</kbd> | Toggle Terminal | Global |
| <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>A</kbd> | Toggle Antigravity AI | Global |
| <kbd>Ctrl</kbd> + <kbd>Enter</kbd> | Clear Chat / New Session | While in AI Sidebar |
| <kbd>Up</kbd> / <kbd>Down</kbd> | Terminal Command History | While in Terminal |
| <kbd>Ctrl</kbd> + <kbd>C</kbd> | Kill Running Command | While in Terminal |
| <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>C</kbd> | Copy Selected Text | While in Terminal |
| <kbd>Ctrl</kbd> + <kbd>L</kbd> | Clear Output | While in Terminal |
| <kbd>PageUp</kbd> / <kbd>PageDn</kbd> | Scroll Output | While in Terminal |
| <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>L</kbd> | View Logs / Auto-Heal Status | Global |

### Command Palette Actions

| Command | Action |
| :--- | :--- |
| `Auto Healer: Approve Fix` | Sends approval to the AI to apply the suggested fix |
| `Auto Healer: Run agy install` | Opens terminal and runs `agy install` to set up the CLI |

---

## ⚙️ Prerequisites

LazyLite's AI features require the **Antigravity CLI (`agy`)** to be installed and configured. The setup scripts will automatically prompt you to install Lite-XL (v2.1.8) and the Antigravity CLI using official installers if they are not detected on your system.

**First-time setup (required before the AI sidebar will respond):**
```bash
agy install
```
Run this once in a real terminal (or the integrated terminal). After that, reload Lite-XL and the AI sidebar will work.

---

## 🚀 Installation & Setup

You can effortlessly install LazyLite by pulling the repository and running the setup scripts. The installer safely provisions your `init.lua` and copies all necessary plugins.

### Windows (PowerShell)
To download and install the setup using `irm` (no Git required), open PowerShell and run:
```powershell
irm https://github.com/ojaswi1234/lazy_lite/archive/refs/heads/main.zip -OutFile lazy_lite.zip
Expand-Archive lazy_lite.zip -Force
cd lazy_lite\lazy_lite-main
.\install.ps1
```
*(Alternatively, if you cloned the repo via git, just run `.\install.ps1` manually)*

### Linux / macOS (Bash)
To download and install the setup using `curl` and `bash` (no Git required), open your terminal and run:
```bash
curl -L -o lazy_lite.zip https://github.com/ojaswi1234/lazy_lite/archive/refs/heads/main.zip
unzip -o lazy_lite.zip
cd lazy_lite-main
bash ./install.sh
```

Restart Lite-XL once the script completes.

---

## 🗑️ Uninstallation

If you wish to remove LazyLite and revert to the default Lite-XL experience, navigate back to the downloaded repository and run the uninstall commands:

- **Windows (PowerShell)**:
  ```powershell
  irm .\uninstall.ps1 | iex
  ```
- **Linux / macOS (Bash)**:
  ```bash
  bash ./uninstall.sh
  ```

*After running the uninstall script, you will need to manually open your `init.lua` (`~/.config/lite-xl/init.lua`) and delete the 6 lines under the `-- [[ LazyLite Configuration ]]` block.*

## Remote Dev

New commands added for Codespaces:
- **Connect / Start**: Auto-resolves workspace directory by basename match and extracts archive securely.
- **LSP Bridge**: Features deep SSH tunnel translation for local-to-remote LSP communication.

