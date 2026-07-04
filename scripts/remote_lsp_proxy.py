#!/usr/bin/env python3
"""
Remote LSP Proxy for lazy_lite GitHub Codespaces integration.

This proxy allows a local Lite-XL LSP client to communicate with a language server
running inside a GitHub Codespace over SSH.

Usage:
    python remote_lsp_proxy.py <codespace_name> <repo_name> <lsp_command> <userdir>

Arguments:
    codespace_name: Name of the GitHub Codespace
    repo_name: Repository name (used for URI path construction)
    lsp_command: The original LSP server command (space-separated string)
    userdir: Lite-XL user directory path (for local URI construction)

The proxy translates between local file:// URIs and remote URIs, and handles
bidirectional JSON-RPC communication over the SSH tunnel.
"""

import sys
import os
import platform
import subprocess
import threading
import json
import atexit
import signal
import re

# Parse command line arguments
if len(sys.argv) < 4:
    print("Usage: remote_lsp_proxy.py <codespace_name> <repo_name> <lsp_command> <userdir>", file=sys.stderr)
    sys.exit(1)

codespace_name = sys.argv[1]
repo_name = sys.argv[2]
cmd_str = sys.argv[3]

# BUG-05 FIX: Accept USERDIR as argv[4] instead of hardcoding
if len(sys.argv) > 4:
    _userdir = sys.argv[4]
else:
    # Fallback to environment variables
    _home = os.environ.get("USERPROFILE") or os.environ.get("HOME", "")
    _userdir = os.path.join(_home, ".config", "lite-xl")

# Construct local and remote URIs
# BUG-05 FIX: Use dynamic USERDIR instead of hardcoded path
local_uri = ("file:///" + _userdir.replace("\\", "/") + "/codespaces/" + codespace_name).replace("//", "/").replace("file:/", "file:///")

# BUG-12 FIX: Normalize drive letter to lowercase on Windows
# Windows LSP clients emit file:///c:/Users/... (lowercase c:)
# But our constructed path might have uppercase C:
if platform.system() == "Windows" and len(local_uri) > 11:
    local_uri = local_uri[:8] + local_uri[8].lower() + local_uri[9:]

remote_uri = f"file:///workspaces/{repo_name}"

print(f"[remote_lsp_proxy] Local URI: {local_uri}", file=sys.stderr)
print(f"[remote_lsp_proxy] Remote URI: {remote_uri}", file=sys.stderr)

# Start the SSH process to run the LSP server remotely
gh_cmd = ["gh", "cs", "ssh", "-c", codespace_name, "--"] + cmd_str.split()
print(f"[remote_lsp_proxy] Starting remote LSP: {' '.join(gh_cmd)}", file=sys.stderr)

gh_proc = subprocess.Popen(
    gh_cmd,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=False
)

def replace_content_length(header_block, new_body_len):
    return re.sub(rb"Content-Length: \d+", f"Content-Length: {new_body_len}".encode(), header_block)

# BUG-13 FIX: Add cleanup handler
def cleanup():
    try:
        if gh_proc.poll() is None:
            gh_proc.kill()
            print("[remote_lsp_proxy] Killed remote LSP process on cleanup", file=sys.stderr)
    except Exception as e:
        print(f"[remote_lsp_proxy] Cleanup error: {e}", file=sys.stderr)

atexit.register(cleanup)

def stream_local_to_remote():
    """Read LSP requests from stdin, translate URIs, forward to remote server."""
    try:
        while True:
            headers = b""
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return
                headers += line
                if line == b"\r\n":
                    break
            
            match = re.search(rb"Content-Length: (\d+)", headers)
            if not match:
                continue
            
            content_length = int(match.group(1))
            
            # Read JSON body
            body = sys.stdin.buffer.read(content_length)
            
            # BUG-12 FIX: Translate local URI to remote URI (case-sensitive)
            body = body.replace(local_uri.encode('utf-8'), remote_uri.encode('utf-8'))
            
            # Recalculate Content-Length
            headers = replace_content_length(headers, len(body))
            
            # Forward to remote process
            gh_proc.stdin.write(headers + body)
            gh_proc.stdin.flush()
            
    except Exception as e:
        print(f"[remote_lsp_proxy] Error in local->remote stream: {e}", file=sys.stderr)
    finally:
        cleanup()

def stream_remote_to_local():
    """Read LSP responses from remote, translate URIs, forward to local client."""
    try:
        while True:
            headers = b""
            while True:
                line = gh_proc.stdout.readline()
                if not line:
                    return
                headers += line
                if line == b"\r\n":
                    break
            
            match = re.search(rb"Content-Length: (\d+)", headers)
            if not match:
                continue
            
            content_length = int(match.group(1))
            
            # Read JSON body
            body = gh_proc.stdout.read(content_length)
            
            # BUG-12 FIX: Translate remote URI back to local URI (case-sensitive)
            body = body.replace(remote_uri.encode('utf-8'), local_uri.encode('utf-8'))
            
            # Recalculate Content-Length
            headers = replace_content_length(headers, len(body))
            
            # Forward to local client
            sys.stdout.buffer.write(headers + body)
            sys.stdout.buffer.flush()
            
    except Exception as e:
        print(f"[remote_lsp_proxy] Error in remote->local stream: {e}", file=sys.stderr)
    finally:
        # BUG-13 FIX: Send LSP notification when remote disconnects
        try:
            note = json.dumps({
                "jsonrpc": "2.0",
                "method": "window/showMessage",
                "params": {
                    "type": 1,
                    "message": "[lazy_lite] Remote LSP session ended. Reconnect your Codespace."
                }
            })
            hdr = f"Content-Length: {len(note)}\r\n\r\n"
            sys.stdout.buffer.write(hdr.encode() + note.encode())
            sys.stdout.buffer.flush()
        except Exception:
            pass
        cleanup()

# Start streaming threads
t1 = threading.Thread(target=stream_local_to_remote, daemon=True)
t2 = threading.Thread(target=stream_remote_to_local, daemon=True)

t1.start()
t2.start()

# Wait for both threads to complete
t1.join()
t2.join()

print("[remote_lsp_proxy] Proxy shutting down", file=sys.stderr)
