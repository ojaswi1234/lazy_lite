---
name: Remote LSP Bridge (SSH)
description: Implements a bidirectional JSON-RPC proxy to connect a local text editor to a cloud container's Language Server.
---

# Remote LSP Bridge

When connecting a lightweight local text editor (like Lite XL, Neovim, or Helix) to a cloud container (like GitHub Codespaces), local autocomplete engines often fail because the local environment lacks the project's dependencies (e.g., `node_modules`, `venv`).

To solve this, we can deploy a **Remote LSP Bridge**.

## The Architecture
The Language Server Protocol (LSP) communicates purely over `stdin` and `stdout` using JSON-RPC. Instead of the editor launching a local binary (e.g., `pyright`), it executes a bridge script.

The bridge script:
1. Shells out to `gh cs ssh -- <lsp-binary>` (or standard `ssh`).
2. Pipes standard input and output bidirectionally between the local IDE and the remote SSH session.
3. **Crucially**, it acts as a man-in-the-middle to rewrite File URIs in the JSON payloads on the fly, translating the local shadow workspace paths (e.g., `file:///C:/Users/name/...`) to the remote container paths (e.g., `file:///workspaces/repo/...`), ensuring the language server processes the files correctly and returns diagnostics with matching local paths for the UI to highlight.

## Implementation Details
A Python implementation (`remote_lsp_proxy.py`) handles this perfectly using `threading` to concurrently stream `sys.stdin` to `gh_proc.stdin` and `gh_proc.stdout` to `sys.stdout`. It intercepts the `Content-Length` headers, searches and replaces the URIs in the JSON body, dynamically calculates the new body length, and rewrites the headers on the fly.

## When to use this skill
- When requested to set up autocomplete for cloud environments.
- When adapting local editors to remote development servers.
- When an architecture requires decoupling the Language Server's filesystem environment from the UI's filesystem environment.
