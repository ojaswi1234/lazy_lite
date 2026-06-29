# 🍃 LazyLite

LazyLite is a highly customized, portable configuration for [Lite-XL](https://lite-xl.com/). It transforms the lightweight editor into a modern, beautifully themed, VS Code-like powerhouse with an integrated terminal, a custom Git status bar, and a built-in AI coding assistant (Antigravity).

Built around a soothing **Everforest Light ("Mossy")** aesthetic, it is designed to be elegant, extremely fast, and easy to deploy across any OS.

---

## ✨ Features

- **Mossy Everforest Theme**: A curated, pixel-perfect sage green light theme that is easy on the eyes.
- **VS Code Layout**: Familiar panel arrangements with a left-side file explorer, bottom terminal, and right-side AI assistant.
- **Modern Status Bar**: A fully styled bottom bar featuring an asynchronous, non-blocking Git branch indicator.
- **Fluid UI**: Smooth slide-in/out size animations for all panels, with fully draggable and resizable window dividers.
- **Integrated Terminal**: Native command runner that uses `cmd.exe` on Windows and `sh` on Linux, complete with colored output and scrolling.
- **Antigravity AI**: A sleek, modern chat UI for your AI pair programmer, featuring quick-action pills, live text streaming, and conversational memory.

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action | Context |
| :--- | :--- | :--- |
| <kbd>Ctrl</kbd> + <kbd>B</kbd> | Toggle File Explorer | Global |
| <kbd>Ctrl</kbd> + <kbd>`</kbd> | Toggle Terminal | Global |
| <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>A</kbd> | Toggle Antigravity AI | Global |
| <kbd>Ctrl</kbd> + <kbd>Enter</kbd> | Clear Chat History | While in AI Sidebar |
| <kbd>Ctrl</kbd> + <kbd>C</kbd> | Kill Running Command | While in Terminal |
| <kbd>Ctrl</kbd> + <kbd>L</kbd> | Clear Output | While in Terminal |
| <kbd>PageUp</kbd> / <kbd>PageDn</kbd> | Scroll Output | While in Terminal |

---

## 🚀 Installation

LazyLite is designed to be fully portable. Just copy this folder to any machine and run the installer for your OS.

### Windows
1. Right-click on `install.ps1` and select **"Run with PowerShell"**.
2. If prompted by Execution Policy, type `Y` to allow the script to run.
3. Restart Lite-XL.

*(Alternatively, open PowerShell, navigate to this folder, and run `.\install.ps1`)*

### Linux / macOS
1. Open your terminal and navigate to this folder.
2. Make the script executable: `chmod +x install.sh`
3. Run the installer: `./install.sh`
4. Restart Lite-XL.

> **Note:** The install scripts will automatically copy the required plugins and safely append the LazyLite load commands to your existing `init.lua`.

---

## 🗑️ Uninstallation

If you wish to remove LazyLite and revert to the default Lite-XL experience:

- **Windows**: Run `uninstall.ps1` via PowerShell.
- **Linux/macOS**: Run `./uninstall.sh` via terminal.

*After running the uninstall script, you will need to manually open your `init.lua` (`~/.config/lite-xl/init.lua`) and delete the 6 lines under the `-- [[ Mossy Configuration ]]` block.*
