# 🍃 LazyLite

LazyLite is a highly customized, portable configuration for [Lite-XL](https://lite-xl.com/). It transforms the lightweight editor into a modern, beautifully themed, VS Code-like powerhouse with an integrated terminal, a custom Git status bar, and an incredibly powerful built-in AI coding assistant (Antigravity).

Built around a soothing **Everforest Light ("Mossy")** aesthetic, it is designed to be elegant, extremely fast, and easy to deploy across any OS.

---

## ✨ Features

- **Mossy Everforest Theme**: A curated, pixel-perfect sage green light theme. UI contrast dynamically adjusts luminance to perfectly match Light/Dark modes while retaining the same color hue.
- **VS Code Layout**: Familiar panel arrangements with a left-side file explorer, bottom terminal, and right-side AI assistant.
- **RAG-Powered AI Sidebar**: The AI Assistant now features a native VS Code style **`@`-mention** file picker. Typing `@` opens a live, fuzzy-searchable list of your project files. Selecting a file secretly bundles its *entire code content* directly into the AI's prompt payload (Retrieval-Augmented Generation) without any indexing overhead.
- **Zero-Touch Auto-Healer**: Intercepts native Lua editor crashes in real-time. If a plugin breaks, it automatically captures the stack trace and prompts you for permission via the Command Palette to let the AI fix it. If the UI is utterly broken, it falls back to a headless diagnostic mode and streams the fix directly into a new text document.
- **Integrated Terminal**: Native command runner featuring VS Code-style `Up`/`Down` command history, visual screen clearing (`cls`/`clear`), and ultra-fast 64KB chunked IPC buffering that will never lag the editor.
- **Real-Time Resource Monitor**: A gorgeous, animated CPU and RAM sparkline chart injected directly into the top-right of your window titlebar. Uses an asynchronous background WMI PowerShell loop to maintain a 60-second telemetry history at 0% CPU overhead.

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action | Context |
| :--- | :--- | :--- |
| <kbd>Ctrl</kbd> + <kbd>B</kbd> | Toggle File Explorer | Global |
| <kbd>Ctrl</kbd> + <kbd>`</kbd> | Toggle Terminal | Global |
| <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>A</kbd> | Toggle Antigravity AI | Global |
| <kbd>Ctrl</kbd> + <kbd>Enter</kbd> | Clear Chat History | While in AI Sidebar |
| <kbd>Up</kbd> / <kbd>Down</kbd> | Terminal Command History | While in Terminal |
| <kbd>Ctrl</kbd> + <kbd>C</kbd> | Kill Running Command | While in Terminal |
| <kbd>Ctrl</kbd> + <kbd>L</kbd> | Clear Output | While in Terminal |
| <kbd>PageUp</kbd> / <kbd>PageDn</kbd> | Scroll Output | While in Terminal |
| <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>L</kbd> | View Logs / Auto-Heal Status | Global |

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
