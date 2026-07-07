#!/usr/bin/env python3
"""
Remote LSP Proxy for lazy_lite GitHub Codespaces integration.

This proxy allows a local Lite-XL LSP client to communicate with a language server
running inside a GitHub Codespace over SSH.
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
import time

if len(sys.argv) < 4:
    print("Usage: remote_lsp_proxy.py <codespace_name> <repo_name> <lsp_command> <userdir>", file=sys.stderr)
    sys.exit(1)

codespace_name = sys.argv[1]
repo_name      = sys.argv[2]
cmd_str        = sys.argv[3]

if len(sys.argv) > 4:
    _userdir = sys.argv[4]
else:
    _home    = os.environ.get("USERPROFILE") or os.environ.get("HOME", "")
    _userdir = os.path.join(_home, ".config", "lite-xl")

_local_base = os.path.join(_userdir, "codespaces", codespace_name)
_local_path_fwd = _local_base.replace("\\", "/")

if platform.system() == "Windows" and len(_local_path_fwd) > 2 and _local_path_fwd[1] == ":":
    drive = _local_path_fwd[0].lower()
    local_uri = "file:///" + drive + _local_path_fwd[1:]
else:
    local_uri = "file://" + _local_path_fwd

remote_uri = f"file:///workspaces/{repo_name}"

local_uri_encoded  = urllib.parse.quote(local_uri,  safe=":/?#[]@!$&'()*+,;=")
remote_uri_encoded = urllib.parse.quote(remote_uri, safe=":/?#[]@!$&'()*+,;=")

gh_env = os.environ.copy()
gh_env["GH_INSECURE_SKIP_VERIFY_TLS"] = "1"
gh_env["GH_NO_UPDATE_NOTIFIER"]       = "1"

_stop_event   = threading.Event()
_stdout_lock  = threading.Lock()
gh_proc = None

def cleanup():
    _stop_event.set()
    try:
        if gh_proc and gh_proc.poll() is None:
            gh_proc.kill()
    except Exception:
        pass

atexit.register(cleanup)

def exact_read(stream, n):
    buf = b""
    while len(buf) < n:
        if _stop_event.is_set(): return None
        chunk = stream.read(n - len(buf))
        if not chunk: return None
        buf += chunk
    return buf

def translate_body(body_bytes):
    body_bytes = body_bytes.replace(local_uri.encode("utf-8"), remote_uri.encode("utf-8"))
    if local_uri_encoded != local_uri:
        body_bytes = body_bytes.replace(local_uri_encoded.encode("utf-8"), remote_uri_encoded.encode("utf-8"))
    return body_bytes

def translate_body_reverse(body_bytes):
    body_bytes = body_bytes.replace(remote_uri.encode("utf-8"), local_uri.encode("utf-8"))
    if remote_uri_encoded != remote_uri:
        body_bytes = body_bytes.replace(remote_uri_encoded.encode("utf-8"), local_uri_encoded.encode("utf-8"))
    return body_bytes

def update_content_length(headers, new_len):
    return re.sub(rb"Content-Length: \d+", f"Content-Length: {new_len}".encode(), headers)

def read_lsp_message(stream, is_remote=False):
    headers = b""
    found_content_length = False
    while True:
        if _stop_event.is_set(): return None, None
        line = stream.readline()
        if not line: return None, None
        if is_remote and not found_content_length:
            stripped = line.strip()
            if stripped and not stripped.startswith(b"Content-"):
                continue
        headers += line
        if b"Content-Length" in line:
            found_content_length = True
        if line == b"\r\n":
            break
    match = re.search(rb"Content-Length: (\d+)", headers)
    if not match: return None, None
    content_length = int(match.group(1))
    body = exact_read(stream, content_length)
    return headers, body

def drain_stderr():
    try:
        for line in gh_proc.stderr:
            if _stop_event.is_set(): break
            print(f"[remote_lsp] {line.decode('utf-8', errors='replace').rstrip()}", file=sys.stderr)
    except Exception:
        pass

def patch_initialize_params(body_bytes):
    try:
        msg = json.loads(body_bytes.decode("utf-8"))
        if msg.get("method") != "initialize":
            return body_bytes
        params = msg.get("params", {})
        changed = False
        if params.get("rootUri", "").startswith(local_uri):
            params["rootUri"] = params["rootUri"].replace(local_uri, remote_uri)
            changed = True
        if params.get("rootPath", ""):
            local_path = _local_base.replace("\\", "/")
            remote_path = f"/workspaces/{repo_name}"
            if local_path in params["rootPath"]:
                params["rootPath"] = params["rootPath"].replace(local_path, remote_path)
                changed = True
        for folder in params.get("workspaceFolders", []):
            if folder.get("uri", "").startswith(local_uri):
                folder["uri"] = folder["uri"].replace(local_uri, remote_uri)
                changed = True
        if changed:
            return json.dumps(msg).encode("utf-8")
    except Exception:
        pass
    return body_bytes

def send_lsp_message(msg_type, text):
    """Send a window/showMessage JSON-RPC payload to local Lite XL."""
    payload = json.dumps({
        "jsonrpc": "2.0",
        "method": "window/showMessage",
        "params": {
            "type": msg_type,
            "message": f"[Codespaces LSP] {text}"
        }
    })
    hdr = f"Content-Length: {len(payload)}\r\n\r\n"
    with _stdout_lock:
        try:
            sys.stdout.buffer.write(hdr.encode("utf-8") + payload.encode("utf-8"))
            sys.stdout.buffer.flush()
        except Exception:
            pass

def ensure_remote_binary(binary_name):
    """Auto-install language servers if they are missing on the remote container."""
    AUTO_INSTALLERS = {
        "pyright-langserver": "npm install -g pyright",
        "typescript-language-server": "npm install -g typescript-language-server typescript",
        "bash-language-server": "npm install -g bash-language-server",
        "vscode-html-language-server": "npm install -g vscode-langservers-extracted",
        "vscode-css-language-server": "npm install -g vscode-langservers-extracted",
        "vscode-json-language-server": "npm install -g vscode-langservers-extracted",
        "vscode-eslint-language-server": "npm install -g vscode-langservers-extracted",
        "yaml-language-server": "npm install -g yaml-language-server",
        "docker-langserver": "npm install -g dockerfile-language-server-nodejs",
        "pylsp": "pip install python-lsp-server",
        "gopls": "go install golang.org/x/tools/gopls@latest",
        "clangd": "sudo apt-get update && sudo apt-get install -y clangd",
        "rust-analyzer": "rustup component add rust-analyzer || (curl -L https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-x86_64-unknown-linux-gnu.gz | gunzip -c > /tmp/ra && sudo mv /tmp/ra /usr/local/bin/rust-analyzer && sudo chmod +x /usr/local/bin/rust-analyzer)",
        "jdtls": "mkdir -p ~/.local/bin ~/.local/share/jdtls && curl -sL https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz | tar -xz -C ~/.local/share/jdtls && echo '#!/bin/bash\njava -Declipse.application=org.eclipse.jdt.ls.core.id1 -Dosgi.bundles.defaultStartLevel=4 -Declipse.product=org.eclipse.jdt.ls.core.product -Dlog.level=ALL -noverify -Xmx1G -jar $(find ~/.local/share/jdtls/plugins -name \"org.eclipse.equinox.launcher_*.jar\") -configuration ~/.local/share/jdtls/config_linux -data ~/.cache/jdtls-workspace' > ~/.local/bin/jdtls && chmod +x ~/.local/bin/jdtls"
    }
    
    check_cmd = ["gh", "cs", "ssh", "-c", codespace_name, "--", "command", "-v", binary_name]
    res = subprocess.run(check_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=gh_env)
    
    if res.returncode == 0:
        return True
        
    installer = AUTO_INSTALLERS.get(binary_name)
    if not installer:
        send_lsp_message(2, f"Language server '{binary_name}' is missing on the codespace, and no auto-installer is known. Please install it manually.")
        return False
        
    send_lsp_message(3, f"Auto-installing {binary_name} on the remote codespace. This may take a minute...")
    print(f"[remote_lsp_proxy] Auto-installing {binary_name} with: {installer}", file=sys.stderr)
    
    install_cmd = ["gh", "cs", "ssh", "-c", codespace_name, "--", "sh", "-c", installer]
    inst_res = subprocess.run(install_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=gh_env, text=True)
    
    if inst_res.returncode == 0:
        send_lsp_message(3, f"Successfully installed {binary_name}! Starting server...")
        return True
    else:
        send_lsp_message(1, f"Failed to install {binary_name}. Check logs.")
        print(f"[remote_lsp_proxy] Install failed:\n{inst_res.stdout}", file=sys.stderr)
        return False

# Extract the binary name (first word) from the command
lsp_args = shlex.split(cmd_str)
binary_name = lsp_args[0]
ensure_remote_binary(binary_name)

gh_cmd = ["gh", "cs", "ssh", "-c", codespace_name, "--"] + lsp_args
gh_proc = subprocess.Popen(
    gh_cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    env=gh_env, text=False
)

def stream_local_to_remote():
    try:
        while not _stop_event.is_set():
            headers, body = read_lsp_message(sys.stdin.buffer, is_remote=False)
            if headers is None or body is None: break
            body = patch_initialize_params(body)
            body = translate_body(body)
            headers = update_content_length(headers, len(body))
            try:
                gh_proc.stdin.write(headers + body)
                gh_proc.stdin.flush()
            except (BrokenPipeError, OSError): break
    except Exception: pass
    finally:
        _stop_event.set()
        try: gh_proc.stdin.close()
        except Exception: pass

def stream_remote_to_local():
    try:
        while not _stop_event.is_set():
            headers, body = read_lsp_message(gh_proc.stdout, is_remote=True)
            if headers is None or body is None: break
            body = translate_body_reverse(body)
            headers = update_content_length(headers, len(body))
            with _stdout_lock:
                try:
                    sys.stdout.buffer.write(headers + body)
                    sys.stdout.buffer.flush()
                except (BrokenPipeError, OSError): break
    except Exception: pass
    finally:
        _stop_event.set()
        try:
            note = json.dumps({
                "jsonrpc": "2.0",
                "method": "window/showMessage",
                "params": {"type": 1, "message": "[Codespaces LSP] Remote session ended."}
            })
            hdr = f"Content-Length: {len(note)}\r\n\r\n"
            with _stdout_lock:
                sys.stdout.buffer.write(hdr.encode() + note.encode())
                sys.stdout.buffer.flush()
        except Exception: pass

t_l2r = threading.Thread(target=stream_local_to_remote, daemon=True)
t_r2l = threading.Thread(target=stream_remote_to_local, daemon=True)
t_stderr = threading.Thread(target=drain_stderr, daemon=True)

t_l2r.start(); t_r2l.start(); t_stderr.start()
t_l2r.join(); t_r2l.join()
