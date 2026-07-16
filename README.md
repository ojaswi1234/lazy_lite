# 🍃 LazyLite

LazyLite is a highly customized, portable configuration for [Lite-XL](https://lite-xl.com/). It transforms the lightweight editor into a modern, beautifully themed, VS Code-like powerhouse with an integrated terminal, a custom Git status bar, an incredibly powerful built-in AI coding assistant (Antigravity), and comprehensive GitHub Codespaces integration for remote development.

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
- **Native LeetCode Integration**: Browse, solve, run, and submit LeetCode problems entirely within the editor. 
  - **Live Problem Browser**: Hit `Ctrl+Shift+L` to search problems, filter by difficulty, and see acceptance rates.
  - **One-Click Setup**: Automatically creates a local file with the correct language starter code and problem description in comments.
  - **Integrated Execution**: Hit `Ctrl+R` to run against test cases, or `Ctrl+Shift+S` to submit directly to LeetCode's judging servers with full real-time results inside a stunning GUI modal.
- **GitHub Codespaces Integration**: Comprehensive remote development environment with hybrid SSH + cache architecture, real-time resource monitoring, git integration, and offline resilience.

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

### Command Palette Actions

| Command | Action |
| :--- | :--- |
| `Auto Healer: Approve Fix` | Sends approval to the AI to apply the suggested fix |
| `Auto Healer: Run agy install` | Opens terminal and runs `agy install` to set up the CLI |
| `codespaces:refresh-cache` | Refresh file tree cache from remote |
| `codespaces:clear-cache` | Clear all cached data |
| `codespaces:connection-status` | Show detailed connection metrics and resources |
| `codespaces:process-sync-queue` | Manually process queued sync operations |
| `codespaces:force-reconnect` | Force reconnection attempt |
| `codespaces:open-remote-terminal` | Open SSH terminal to codespace |
| `codespaces:open-in-browser` | Open codespace in VS Code web |
| `codespaces:show-resources` | Display remote resource usage |
| `codespaces:refresh-git-status` | Refresh git status manually |
| `codespaces:git-pull` | Pull from remote repository |
| `codespaces:git-push` | Push to remote repository |

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

---

## 💻 LeetCode Integration

LazyLite includes a fully native, blazingly fast LeetCode integration that connects directly to LeetCode's GraphQL API. 

### Features
- **Browse & Search**: Filter problems by difficulty, search by keyword, and view acceptance rates directly inside Lite-XL.
- **Auto-Scaffolding**: Clicking a language (Python, C++, Java, JS, etc.) automatically creates a local solution file pre-filled with the starter code and problem description.
- **In-Editor Judging**: Run your code (`Ctrl+R`) against example test cases or Submit (`Ctrl+Shift+S`) to LeetCode. The results (Accepted, Wrong Answer, Runtime Error) and your performance percentiles stream directly back into the UI.

### Setup Instructions
1. Press `Ctrl+Shift+L` to open the LeetCode menu.
2. Open your web browser, log in to [leetcode.com](https://leetcode.com).
3. Open Developer Tools (<kbd>F12</kbd>) → navigate to the **Application** tab (or **Storage** tab on Firefox).
4. Expand **Cookies** → `https://leetcode.com`.
5. Copy the values for `LEETCODE_SESSION` and `csrftoken`.
6. Paste them into the LazyLite LeetCode modal (using `Ctrl+V`) and click **Connect**.

---

## Remote Development with GitHub Codespaces

LazyLite features a comprehensive GitHub Codespaces integration that transforms your local Lite-XL editor into a powerful remote development environment.

### Core Architecture

**Hybrid SSH + Cache System:**
- **Instant Connection**: No more slow tar downloads - uses direct SSH operations with intelligent caching
- **File Tree Caching**: Remote directory structure cached locally for instant file explorer navigation
- **Content Caching**: Recently accessed files cached for instant read operations
- **Background Refresh**: Automatic cache updates every 30 seconds
- **Offline Resilience**: Operation queuing when connection drops, automatic sync on reconnection

**Connection Management:**
- **Auto-Reconnect**: Automatically recovers from SSH connection drops
- **Latency Monitoring**: Real-time connection latency tracking
- **Connection Health**: Background health checks every 30 seconds
- **Offline Mode**: Graceful degradation with queued operations

### Remote Resource Monitoring

**Real-Time Resource Tracking:**
- **CPU Usage**: Monitor remote codespace CPU utilization
- **Memory Usage**: Track remote memory consumption  
- **Disk Usage**: Monitor workspace disk space
- **Status Bar Integration**: Real-time resource widgets in status bar
- **Automatic Updates**: Background monitoring every 30 seconds

### Git Integration

**Remote Git Operations:**
- **Branch Tracking**: Real-time current branch display
- **Changed Files**: Count of modified files in working directory
- **Sync Status**: Ahead/behind commit tracking
- **Git Pull/Push**: Direct remote git operations via commands
- **Status Bar Widget**: Live git status with branch and sync indicators

### Workflow Features

**Session Tracking:**
- **Session Timer**: Track work duration in status bar
- **Connection Status**: Visual indicators (Connected/Offline)
- **Sync Queue**: Pending operation counter
- **Latency Display**: Real-time connection speed

**File Sync:**
- **Automatic Sync**: Files automatically synced to codespace on save
- **Queue System**: Failed operations queued for retry
- **Conflict Resolution**: Smart handling of sync conflicts
- **Progress Indicators**: Visual feedback during sync operations

### LSP Integration

**Remote LSP Proxy:**
- **SSH Tunnel**: LSP communication routed through SSH to remote codespace
- **Path Translation**: Automatic local-to-remote path conversion
- **Language Servers**: Uses codespace's own language servers
- **IntelliSense**: Full remote code completion and diagnostics
- **Error Handling**: Graceful handling of LSP connection issues

### Status Bar Widgets

When connected to a codespace, the status bar displays:
- **Connection Status**: "✓ Connected" or "⚠ OFFLINE" with latency
- **Resource Monitor**: CPU and memory usage percentages
- **Git Status**: Branch name with changed files count and sync status
- **Sync Queue**: Pending operations counter (when queue has items)
- **Session Timer**: Work duration tracking

### Benefits

- **Instant Connection**: No waiting for large file downloads
- **Always Fresh**: Direct access to latest remote files
- **Offline Capability**: Continue working during connection drops
- **Resource Awareness**: Monitor codespace performance
- **Git Awareness**: Real-time git status without terminal
- **Seamless Integration**: Works with existing Lite-XL features including LSP and AI sidebar
- **Antigravity Compatibility**: AI CLI works perfectly with remote files via path translation
## lazy-lite Web Preview

The web_preview plugin launches a fast, native C-based local web server to preview static sites (HTML/CSS/JS) directly from your Lite-XL project directory. It supports live-reloading and SPA fallback routing.

### Keybindings
- Ctrl+Alt+P : Start Web Preview (launches server and opens default browser)
- Ctrl+Alt+Shift+P : Stop Web Preview

### Commands
- web-preview:start - Starts the server and opens the browser.
- web-preview:stop - Stops the preview server.
- web-preview:restart - Restarts the preview server.
- web-preview:copy-url - Copies the current preview URL to your clipboard.

### Configuration
You can configure the plugin in your init.lua by modifying config.plugins.web_preview:
\\\lua
config.plugins.web_preview = {
  port = 8080,                -- Preferred port
  spa_fallback = false,       -- Enable SPA fallback to index.html for 404s
  live_reload = true,         -- Auto-reload on file changes
  ignore_dirs = { ".git", "node_modules" }, -- Dirs to ignore for live reload
  bind_host = "127.0.0.1",    -- Host IP to bind to
  keybind_start = "ctrl+alt+p",
  keybind_stop = "ctrl+alt+shift+p",
}
\\\

### Building the Server
The plugin requires the native server binary. Source code and a Makefile are located in the preview_server directory.
Run make windows (or make mac, make linux) and ensure the resulting executable (lazy_lite_preview_server.exe) is copied to your plugins directory.
