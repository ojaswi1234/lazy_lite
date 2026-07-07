#!/usr/bin/env python3
"""
Remote LSP Proxy for lazy_lite GitHub Codespaces integration.

This proxy allows a local Lite-XL LSP client to communicate with a language server
running inside a GitHub Codespace over SSH.

Usage:
    python remote_lsp_proxy.py <codespace_name> <repo_name> <lsp_command> <userdir>

Arguments:
    codespace_name: Name of the GitHub Codespace
    repo_name:      Repository name (used for URI path construction)
    lsp_command:    The LSP server command (space-separated string)
    userdir:        Lite-XL user directory path (for local URI construction)

HOW IT WORKS (full architecture):
=================================
The Language Server Protocol (LSP) uses JSON-RPC over stdin/stdout.
Normally, Lite-XL spawns a *local* LSP binary and talks to it.
For Codespaces, the LSP binary must run *inside* the container so it can
access the real source files and dependencies (node_modules, venv, etc.)

This proxy intercepts the LSP conversation and:
  1. Receives JSON-RPC messages from Lite-XL on stdin
  2. Translates all local file:// URIs → remote file:// URIs in the JSON body
  3. Recalculates Content-Length header (since the body may grow/shrink)
  4. Forwards the translated message to the remote LSP via `gh cs ssh`
  5. Receives responses from the remote LSP
  6. Translates all remote file:// URIs → local file:// URIs in the JSON body
  7. Forwards the translated response to Lite-XL on stdout

URI Translation Example:
  Local:  file:///C:/Users/ojasw/.config/lite-xl/codespaces/mycs/src/main.py
  Remote: file:///workspaces/my-repo/src/main.py

The proxy runs two daemon threads (one for each direction) so the streams
are fully independent and neither can block the other.

CRITICAL FIXES IN THIS VERSION:
  [FIX-1]  partial reads: sys.stdin.buffer.read(N) can return < N bytes.
           Use exact_read() which loops until exactly N bytes are received.
  [FIX-2]  SSH MOTD/banner stripping: gh cs ssh may print banner text to
           stdout before the LSP server starts. We skip non-header lines
           until we see a valid 'Content-Length:' header.
  [FIX-3]  stderr deadlock: if we never drain gh_proc.stderr, the remote
           process blocks when its stderr buffer fills. A dedicated thread
           drains it continuously.
  [FIX-4]  TLS bypass: GH_INSECURE_SKIP_VERIFY_TLS=1 passed to subprocess
           to prevent x509 failures on corporate proxies/antiviruses.
  [FIX-5]  shlex splitting: cmd_str.split() breaks on paths with spaces.
           Use shlex.split() which respects quoting.
  [FIX-6]  rootUri translation: the LSP 'initialize' request contains
           'rootUri' and 'workspaceFolders' with local paths — translate them.
  [FIX-7]  atomic stdout writes: sys.stdout.buffer.write() is not thread-safe.
           Use a Lock to prevent interleaving of concurrent writes.
  [FIX-8]  thread coordination: use threading.Event so one thread dying
           properly signals the other to stop.
  [FIX-9]  percent-encoded URIs: translate %2F-encoded variants too.
"""

import sys
import os
import platform
import subprocess
import threading
import json
import atexit
import shlex
import urllib.parse
import re

# ── Argument parsing ─────────────────────────────────────────────────────────
if len(sys.argv) < 4:
    print("Usage: remote_lsp_proxy.py <codespace_name> <repo_name> <lsp_command> <userdir>",
          file=sys.stderr)
    sys.exit(1)

codespace_name = sys.argv[1]
repo_name      = sys.argv[2]
cmd_str        = sys.argv[3]

# Accept USERDIR as argv[4] or fall back to environment variables
if len(sys.argv) > 4:
    _userdir = sys.argv[4]
else:
    _home    = os.environ.get("USERPROFILE") or os.environ.get("HOME", "")
    _userdir = os.path.join(_home, ".config", "lite-xl")

# ── URI construction ──────────────────────────────────────────────────────────
# Construct the local shadow path URI (where Lite-XL thinks the files are)
_local_base = os.path.join(_userdir, "codespaces", codespace_name)
# Normalize to forward slashes and encode as file:// URI
_local_path_fwd = _local_base.replace("\\", "/")

# Build proper file:// URI (handles Windows drive letters like C:)
if platform.system() == "Windows" and len(_local_path_fwd) > 2 and _local_path_fwd[1] == ":":
    # C:/Users/... → file:///c:/Users/... (lowercase drive letter for LSP compat)
    drive = _local_path_fwd[0].lower()
    local_uri = "file:///" + drive + _local_path_fwd[1:]
else:
    local_uri = "file://" + _local_path_fwd

# The remote workspace URI inside the container
remote_uri = f"file:///workspaces/{repo_name}"

# Percent-encoded variants for URI replacement (handles spaces in paths)
local_uri_encoded  = urllib.parse.quote(local_uri,  safe=":/?#[]@!$&'()*+,;=")
remote_uri_encoded = urllib.parse.quote(remote_uri, safe=":/?#[]@!$&'()*+,;=")

print(f"[remote_lsp_proxy] Local URI:  {local_uri}",  file=sys.stderr)
print(f"[remote_lsp_proxy] Remote URI: {remote_uri}", file=sys.stderr)

# ── Subprocess (gh cs ssh + LSP binary) ──────────────────────────────────────
# FIX-5: use shlex.split() to correctly handle quoted arguments in the command
lsp_args = shlex.split(cmd_str)
gh_cmd   = ["gh", "cs", "ssh", "-c", codespace_name, "--"] + lsp_args
print(f"[remote_lsp_proxy] Starting: {' '.join(gh_cmd)}", file=sys.stderr)

# FIX-4: pass TLS bypass env so gh doesn't fail on corporate proxies
gh_env = os.environ.copy()
gh_env["GH_INSECURE_SKIP_VERIFY_TLS"] = "1"
gh_env["GH_NO_UPDATE_NOTIFIER"]       = "1"

gh_proc = subprocess.Popen(
    gh_cmd,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    env=gh_env,
    text=False  # always binary mode — LSP uses binary-safe Content-Length framing
)

# ── Threading coordination ────────────────────────────────────────────────────
# FIX-8: Event lets one thread signal the other to exit cleanly
_stop_event   = threading.Event()
# FIX-7: Lock prevents interleaved writes to sys.stdout.buffer from two threads
_stdout_lock  = threading.Lock()

# ── Cleanup ───────────────────────────────────────────────────────────────────
def cleanup():
    _stop_event.set()
    try:
        if gh_proc.poll() is None:
            gh_proc.kill()
    except Exception as e:
        print(f"[remote_lsp_proxy] Cleanup error: {e}", file=sys.stderr)

atexit.register(cleanup)

# ── Helpers ───────────────────────────────────────────────────────────────────
def exact_read(stream, n):
    """
    FIX-1: Python's stream.read(n) can return fewer than n bytes if the data
    arrives in multiple TCP segments or the pipe buffer has a partial write.
    This helper loops until exactly n bytes have been accumulated, which is
    required for correct LSP message framing.
    """
    buf = b""
    while len(buf) < n:
        if _stop_event.is_set():
            return None
        chunk = stream.read(n - len(buf))
        if not chunk:  # EOF or stream closed
            return None
        buf += chunk
    return buf

def translate_body(body_bytes):
    """
    Replace all local↔remote URI occurrences in a JSON body (bytes).
    Handles both plain and percent-encoded variants.
    """
    # Plain URI replacement (most common case)
    body_bytes = body_bytes.replace(
        local_uri.encode("utf-8"),
        remote_uri.encode("utf-8")
    )
    # FIX-9: also handle percent-encoded URIs (e.g. spaces in path → %20)
    if local_uri_encoded != local_uri:
        body_bytes = body_bytes.replace(
            local_uri_encoded.encode("utf-8"),
            remote_uri_encoded.encode("utf-8")
        )
    return body_bytes

def translate_body_reverse(body_bytes):
    """Reverse translation: remote URIs → local URIs."""
    body_bytes = body_bytes.replace(
        remote_uri.encode("utf-8"),
        local_uri.encode("utf-8")
    )
    if remote_uri_encoded != remote_uri:
        body_bytes = body_bytes.replace(
            remote_uri_encoded.encode("utf-8"),
            local_uri_encoded.encode("utf-8")
        )
    return body_bytes

def update_content_length(headers, new_len):
    return re.sub(rb"Content-Length: \d+", f"Content-Length: {new_len}".encode(), headers)

def read_lsp_message(stream, is_remote=False):
    """
    Read one complete LSP message (headers + body) from a binary stream.
    Returns (headers_bytes, body_bytes) or (None, None) on EOF/error.

    FIX-2: SSH sometimes emits MOTD / banner lines before the LSP server
    starts writing. We skip any line that doesn't look like a valid LSP
    header (i.e. doesn't start with 'Content-' or is just '\\r\\n').
    """
    headers = b""
    found_content_length = False

    while True:
        if _stop_event.is_set():
            return None, None
        line = stream.readline()
        if not line:
            return None, None

        # FIX-2: skip SSH banner lines that are not LSP headers
        if is_remote and not found_content_length:
            stripped = line.strip()
            # A valid LSP header line starts with "Content-" or is the blank separator
            if stripped and not stripped.startswith(b"Content-"):
                print(f"[remote_lsp_proxy] Skipping banner: {stripped[:80]}", file=sys.stderr)
                continue

        headers += line
        if b"Content-Length" in line:
            found_content_length = True
        if line == b"\r\n":  # blank line = end of headers
            break

    match = re.search(rb"Content-Length: (\d+)", headers)
    if not match:
        return None, None

    content_length = int(match.group(1))
    # FIX-1: use exact_read to handle fragmented delivery
    body = exact_read(stream, content_length)
    return headers, body

# ── FIX-3: stderr drainer ─────────────────────────────────────────────────────
def drain_stderr():
    """
    Continuously read and log gh_proc stderr.
    Without this, the remote process blocks when its stderr buffer fills,
    causing a deadlock where nothing is written to stdout either.
    """
    try:
        for line in gh_proc.stderr:
            if _stop_event.is_set():
                break
            print(f"[remote_lsp] {line.decode('utf-8', errors='replace').rstrip()}", file=sys.stderr)
    except Exception:
        pass

# ── FIX-6: rootUri translation ────────────────────────────────────────────────
def patch_initialize_params(body_bytes):
    """
    The LSP 'initialize' request contains 'rootUri', 'rootPath', and
    'workspaceFolders' with the local shadow path. The remote server must
    receive the actual remote workspace path so it indexes the right directory.
    We do a JSON-level patch for the initialize request specifically.
    """
    try:
        msg = json.loads(body_bytes.decode("utf-8"))
        if msg.get("method") != "initialize":
            return body_bytes
        params = msg.get("params", {})
        changed = False

        # Translate rootUri
        if params.get("rootUri", "").startswith(local_uri):
            params["rootUri"] = params["rootUri"].replace(local_uri, remote_uri)
            changed = True

        # Translate rootPath (deprecated but still sent by many clients)
        if params.get("rootPath", ""):
            local_path = _local_base.replace("\\", "/")
            remote_path = f"/workspaces/{repo_name}"
            if local_path in params["rootPath"]:
                params["rootPath"] = params["rootPath"].replace(local_path, remote_path)
                changed = True

        # Translate workspaceFolders
        for folder in params.get("workspaceFolders", []):
            if folder.get("uri", "").startswith(local_uri):
                folder["uri"] = folder["uri"].replace(local_uri, remote_uri)
                changed = True

        if changed:
            return json.dumps(msg).encode("utf-8")
    except Exception as e:
        print(f"[remote_lsp_proxy] Warning: could not patch initialize: {e}", file=sys.stderr)
    return body_bytes

# ── Streaming threads ─────────────────────────────────────────────────────────
def stream_local_to_remote():
    """Read LSP requests from Lite-XL (stdin), translate URIs, forward to remote."""
    try:
        while not _stop_event.is_set():
            headers, body = read_lsp_message(sys.stdin.buffer, is_remote=False)
            if headers is None or body is None:
                break

            # FIX-6: special handling for initialize to translate rootUri
            body = patch_initialize_params(body)
            # Translate all other local URIs in the body
            body = translate_body(body)
            # Recalculate Content-Length (body may have grown/shrunk)
            headers = update_content_length(headers, len(body))

            try:
                gh_proc.stdin.write(headers + body)
                gh_proc.stdin.flush()
            except (BrokenPipeError, OSError):
                break

    except Exception as e:
        print(f"[remote_lsp_proxy] local→remote error: {e}", file=sys.stderr)
    finally:
        _stop_event.set()
        try:
            gh_proc.stdin.close()
        except Exception:
            pass

def stream_remote_to_local():
    """Read LSP responses from remote, translate URIs, forward to Lite-XL (stdout)."""
    try:
        while not _stop_event.is_set():
            # FIX-2: pass is_remote=True to skip SSH banner lines
            headers, body = read_lsp_message(gh_proc.stdout, is_remote=True)
            if headers is None or body is None:
                break

            # Translate remote URIs back to local URIs
            body = translate_body_reverse(body)
            headers = update_content_length(headers, len(body))

            # FIX-7: lock around stdout write to prevent interleaving
            with _stdout_lock:
                try:
                    sys.stdout.buffer.write(headers + body)
                    sys.stdout.buffer.flush()
                except (BrokenPipeError, OSError):
                    break

    except Exception as e:
        print(f"[remote_lsp_proxy] remote→local error: {e}", file=sys.stderr)
    finally:
        _stop_event.set()
        # Send a final window/showMessage so the user knows LSP disconnected
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
            with _stdout_lock:
                sys.stdout.buffer.write(hdr.encode() + note.encode())
                sys.stdout.buffer.flush()
        except Exception:
            pass

# ── Launch all threads ────────────────────────────────────────────────────────
t_l2r    = threading.Thread(target=stream_local_to_remote, daemon=True, name="l2r")
t_r2l    = threading.Thread(target=stream_remote_to_local, daemon=True, name="r2l")
t_stderr = threading.Thread(target=drain_stderr,           daemon=True, name="stderr")

t_l2r.start()
t_r2l.start()
t_stderr.start()

# Wait for both main streams to finish (stderr drainer is daemon, auto-exits)
t_l2r.join()
t_r2l.join()

print("[remote_lsp_proxy] Proxy shutting down", file=sys.stderr)
