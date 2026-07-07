---
name: lite_xl_codespaces
description: Diagnostics and architecture guide for Lite-XL GitHub Codespaces integration and Remote LSP.
---

# Lite XL Codespaces & Remote LSP Guide

This skill contains the full architectural knowledge base for the user's custom GitHub Codespaces and Remote LSP integration in Lite XL. 
**When healing or debugging Lite-XL errors, use this guide to determine if the issue is a local editor bug or a remote Codespaces/LSP bug.**

## 1. Determining Local vs. Remote Issues
If an error traceback originates from or involves any of these files, you are dealing with a **Remote Codespace** issue:
- `plugins/github_codespaces.lua` (The main bridge plugin)
- `plugins/virtual_codespace_fs.lua` (The Virtual Filesystem / Shadow Builder)
- `scripts/remote_lsp_proxy.py` (The Python translation proxy for LSP)
- `plugins/toggle_terminal.lua` (If the error relates to persistent SSH terminal connections)

If the error originates in other core plugins (e.g., `core/init.lua`, `plugins/lsp/init.lua`, UI rendering), it is likely a **Local Development** editor bug.

## 2. Remote LSP Architecture
Normally, Lite-XL launches an LSP binary locally. In a Codespace environment, the binary must run *inside* the remote container.
- **The Proxy:** `scripts/remote_lsp_proxy.py` sits between Lite XL and the `gh cs ssh` process. 
- **URI Translation:** It intercepts JSON-RPC messages and translates local shadow URIs (e.g., `file:///C:/Users/.../codespaces/repo/main.py`) into remote container URIs (`file:///workspaces/repo/main.py`), and vice-versa for incoming responses.
- **Auto-Installer:** The proxy automatically detects missing language servers (e.g., `pyright`, `gopls`, `clangd`) on the remote container and installs them via `npm`, `pip`, `go`, etc., before launching the server. It pushes UI notifications back to Lite XL using `window/showMessage`.

### Common Remote LSP Pitfalls:
- **SSH MOTD Banners:** Remote servers often emit banner text on connection. The proxy MUST strip non-LSP headers (anything not matching `Content-Length`) to prevent JSON parsing crashes.
- **TCP Fragmentation:** `stdin.read()` may not return the full JSON payload at once. The proxy must use an `exact_read` loop.
- **Stderr Deadlocks:** If `stderr` of the SSH process is not continuously drained in a background thread, the remote process will eventually block when its buffer fills up, causing a complete deadlock.
- **Timeout Limitations:** Auto-installing servers (like `pyright`) can take 30+ seconds. The local LSP plugin (`lsp/server.lua`) must have an increased `timeout` (e.g., 60s) for the `initialize` request to prevent the local client from aborting early.

## 3. Virtual File System (VFS) Architecture
To make remote files accessible to local Lite XL features, `virtual_codespace_fs.lua` creates 0-byte "placeholder" or "shadow" files locally. When a file is opened, it is asynchronously fetched via `gh cs cp`.

### Common VFS Pitfalls:
- **BusyBox/Alpine Compatibility:** When indexing remote files, GNU `find -printf` will fail silently on Alpine Linux devcontainers (which use BusyBox). The correct POSIX-compliant approach is chaining two `find` commands piped through `sed` to format directories vs files.
- **Corporate Proxies (TLS Errors):** All `gh` commands spawned by the plugins or proxy MUST include `GH_INSECURE_SKIP_VERIFY_TLS=1` in their environment variables to prevent SSL/x509 handshake failures on corporate networks.
- **Space Escaping:** Remote bash commands injected into `run_cmd_sync` or SSH must be carefully constructed using Lua's long brackets (`[[...]]`) to prevent unescaped double-quotes from breaking the Lua AST.

## 4. Healing Protocol for Remote Issues
1. **Identify the subsystem:** Is it failing during shadow build (VFS)? During autocomplete/LSP (Proxy)? Or during terminal launch?
2. **Check the quoting:** If a shell command is malformed, rewrite it using `[[...]]`.
3. **Check the environment:** Ensure `GH_INSECURE_SKIP_VERIFY_TLS=1` is present in the subprocess environment map.
4. **Check the remote OS compatibility:** If a standard Linux utility fails, assume it's a BusyBox container and rewrite the command to be strict POSIX.
