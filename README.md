# 🍃 LazyLite

LazyLite is a highly customized, portable configuration for [Lite-XL](https://lite-xl.com/). It transforms the lightweight editor into a modern, beautifully themed, VS Code-like powerhouse with an integrated terminal, a custom Git status bar, an incredibly powerful built-in AI coding assistant (Antigravity), and comprehensive GitHub Codespaces integration for remote development.

Built around a soothing **Everforest Light ("Mossy")** aesthetic, it is designed to be elegant, extremely fast, and easy to deploy across any OS.

---

## ✨ Features

- **Mossy Everforest Theme**: A curated, pixel-perfect sage green light theme that dynamically matches Light/Dark modes in real-time.
- **VS Code Layout**: Familiar panel arrangements with a left-side file explorer, bottom terminal, and right-side AI assistant.
- **Conversational AI Sidebar**: Native AI chat UI powered by the Antigravity CLI. Includes typewriter output streaming, `@`-mention file picker, multi-turn memory, and one-click quick action pills.
- **Smart Auto-Healer**: Intercepts Lua crashes in real-time and dispatches them to the AI for autonomous analysis and healing. 
- **Auto-Close Brackets**: Smart bracket auto-closing with selection wrapping and step-over support.
- **Integrated Terminal**: Native command runner featuring shell selector, VS Code-style history, and ultra-fast 64KB chunked IPC buffering.
- **Real-Time Resource Monitor**: Animated CPU and RAM sparkline chart injected directly into the titlebar (WMI on Windows, `/proc/stat` on Linux).
- **Native LeetCode Integration**: Browse, solve, run, and submit LeetCode problems entirely within the editor natively.
- **GitHub Codespaces Integration**: Comprehensive remote development environment with hybrid SSH + cache architecture.
- **Port Manager & Live Preview**: Multi-select active processes by port and kill them. Native live web preview server running in C with live-reload.
- **Framework Detection**: Status bar natively detects React, Node, Python, Vite, and Next.js for one-click startup.

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
| <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>L</kbd> | Toggle LeetCode Browser | Global |
| <kbd>Ctrl</kbd> + <kbd>R</kbd> | Run Test Cases | While in a LeetCode solution file |
| <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>S</kbd> | Submit Solution | While in a LeetCode solution file |
| <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>P</kbd> | Start Web Preview | Global |

---

## 🚀 Installation & Setup

LazyLite automatically provisions your `init.lua`, detects your package managers natively (supporting `apt`, `apk`, `dnf`, `pacman`), and pulls all dependencies including Python 3, GitHub CLI, and MongoDB tools.

### For Linux & macOS

```bash
# Clone the repository
git clone https://github.com/ojaswi1234/lazy_lite.git ~/.config/lite-xl

# Run the automated setup script
cd ~/.config/lite-xl
./install.sh
```

### For Windows

```powershell
# Clone the repository
git clone https://github.com/ojaswi1234/lazy_lite.git $env:USERPROFILE\.config\lite-xl

# Run the automated setup script
cd $env:USERPROFILE\.config\lite-xl
.\install.ps1
```

### Post-Installation
1. Restart Lite-XL.
2. Run `agy install` in your terminal to configure the AI backend if not already set up.
3. Enjoy your new powerhouse editor!
