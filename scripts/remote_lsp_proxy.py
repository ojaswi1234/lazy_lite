import sys
import subprocess
import threading
import re

if len(sys.argv) < 4:
    print("Usage: python remote_lsp_proxy.py <codespace_name> <repo_name> <lsp_cmd>")
    sys.exit(1)

codespace_name = sys.argv[1]
repo_name = sys.argv[2]
lsp_cmd = sys.argv[3]

import os, platform
if len(sys.argv) > 4:
    _userdir = sys.argv[4]
else:
    _home = os.environ.get("USERPROFILE") or os.environ.get("HOME", "")
    _userdir = os.path.join(_home, ".config", "lite-xl")
local_uri = ("file:///" + _userdir.replace("\\", "/") + "/codespaces/" + codespace_name).replace("//", "/").replace("file:/", "file:///")
# Normalise drive letter to lowercase on Windows (LSP clients emit lowercase)
if platform.system() == "Windows" and len(local_uri) > 11:
    local_uri = local_uri[:8] + local_uri[8].lower() + local_uri[9:]
remote_uri = f"file:///workspaces/{repo_name}"

# Spawn the Language Server remotely via GitHub CLI
gh_proc = subprocess.Popen(
    ["gh", "cs", "ssh", "-c", codespace_name, "--", lsp_cmd],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=sys.stderr
)

def replace_content_length(header_block, new_body_len):
    return re.sub(rb"Content-Length: \d+", f"Content-Length: {new_body_len}".encode(), header_block)

def stream_local_to_remote():
    """Reads JSON-RPC from the local IDE, translates Windows URIs to Linux URIs, and sends to the Codespace."""
    try:
        while True:
            headers = b""
            while True:
                line = sys.stdin.buffer.readline()
                if not line: return
                headers += line
                if line == b"\r\n": break
            
            match = re.search(rb"Content-Length: (\d+)", headers)
            if not match: continue
            length = int(match.group(1))
            
            body = sys.stdin.buffer.read(length)
            
            # Map Local Windows URI -> Remote Linux URI
            body = body.replace(local_uri.encode('utf-8'), remote_uri.encode('utf-8'))
            
            headers = replace_content_length(headers, len(body))
            gh_proc.stdin.write(headers + body)
            gh_proc.stdin.flush()
    except Exception:
        pass

def stream_remote_to_local():
    """Reads JSON-RPC from the remote LSP, translates Linux URIs back to Windows URIs, and sends to the local IDE."""
    try:
        while True:
            headers = b""
            while True:
                line = gh_proc.stdout.readline()
                if not line: return
                headers += line
                if line == b"\r\n": break
            
            match = re.search(rb"Content-Length: (\d+)", headers)
            if not match: continue
            length = int(match.group(1))
            
            body = gh_proc.stdout.read(length)
            
            # Map Remote Linux URI -> Local Windows URI
            body = body.replace(remote_uri.encode('utf-8'), local_uri.encode('utf-8'))
            
            headers = replace_content_length(headers, len(body))
            sys.stdout.buffer.write(headers + body)
            sys.stdout.buffer.flush()
    except Exception:
        pass

import json, atexit

def _kill_gh():
    try:
        gh_proc.kill()
    except Exception:
        pass

atexit.register(_kill_gh)

# Wrap stream_remote_to_local to notify IDE on disconnect
_orig_s2l = stream_remote_to_local
def stream_remote_to_local():
    _orig_s2l()
    # Server died — send a window/showMessage so the LSP client knows
    try:
        note = json.dumps({"jsonrpc":"2.0","method":"window/showMessage",
                           "params":{"type":1,"message":"[lazy_lite] Remote LSP session ended. Reconnect your Codespace."}})
        hdr = f"Content-Length: {len(note)}\r\n\r\n"
        sys.stdout.buffer.write(hdr.encode() + note.encode())
        sys.stdout.buffer.flush()
    except Exception:
        pass
    _kill_gh()

t1 = threading.Thread(target=stream_local_to_remote, daemon=True)
t2 = threading.Thread(target=stream_remote_to_local, daemon=True)
t1.start()
t2.start()
t1.join()
t2.join()
