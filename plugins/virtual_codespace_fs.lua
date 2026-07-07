-- mod-version:3
-- Virtual File System for GitHub Codespaces
-- Hybrid approach: creates local file structure (empty files) but fetches content on-demand
-- This allows the treeview to show files while still being fast like VS Code

local core = require "core"
local config = require "core.config"
local style = require "core.style"
local process = require "process"
local system = require "system"

local VFS = {
  active = false,
  codespace_name = nil,
  remote_dir = nil,   -- absolute remote path e.g. /workspaces/my-repo
  local_dir = nil,    -- absolute local path  e.g. C:\Users\...\codespaces\cs-name
  cache = {
    files = {},       -- [local_path] = { content, mtime }
    directories = {}, -- [local_path] = { entries={name,type,...}, mtime }
  },
  cache_ttl = 300,    -- 5 minutes TTL
  request_queue = {}, -- in-flight guards: [key] = true
}

-- ── Path helpers ────────────────────────────────────────────────────────────────

-- Normalize path separators to forward slashes for reliable cross-platform comparison.
-- On Windows, Lite-XL's system.absolute_path() may return forward slashes while
-- PATHSEP-joined paths use backslashes. We normalize both sides before comparing.
local function normalize_path(p)
  return (p or ""):gsub("\\", "/")
end

-- Safe plain-string prefix strip on normalized paths.
local function strip_prefix(str, prefix)
  if str:sub(1, #prefix) == prefix then
    return str:sub(#prefix + 1)
  end
  return str
end

-- Convert a local absolute path to a remote absolute path.
-- Works regardless of whether paths use forward or backslashes.
local function local_to_remote(local_path)
  local np = normalize_path(local_path)
  local nl = normalize_path(VFS.local_dir)
  local rel = strip_prefix(np, nl)
  rel = rel:gsub("^/+", "")   -- strip leading slash
  if rel == "" then
    return VFS.remote_dir
  end
  return VFS.remote_dir .. "/" .. rel
end

-- ── Cache helpers ────────────────────────────────────────────────────────────────

local function cache_get(tbl, key)
  local entry = tbl[key]
  if entry and entry.mtime then
    if system.get_time() - entry.mtime < VFS.cache_ttl then
      return entry
    end
    tbl[key] = nil
  end
  return nil
end

local function cache_set(tbl, key, data_table)
  -- data_table is a plain table of fields; we just stamp mtime on it
  data_table.mtime = system.get_time()
  tbl[key] = data_table
end

-- ── SSH helpers ──────────────────────────────────────────────────────────────────

-- Run a shell command on the remote codespace and return (ok, output_string).
-- Works whether called inside a coroutine (yields) or from the main thread (busy-waits).
local function run_ssh_command(cs_name, shell_cmd, timeout)
  timeout = timeout or 30
  -- Double-wrap in single quotes so Windows CreateProcess doesn't strip the outer quotes.
  local safe_cmd = "'" .. shell_cmd:gsub("'", "'\\''") .. "'"
  -- Environment passed to every gh subprocess.
  -- GH_INSECURE_SKIP_VERIFY_TLS=1 silences x509/TLS cert errors (common with antivirus/proxies).
  local GH_ENV = { GH_INSECURE_SKIP_VERIFY_TLS = "1", GH_NO_UPDATE_NOTIFIER = "1" }
  local p = process.start(
    {"gh", "cs", "ssh", "-c", cs_name, "--", "sh", "-c", safe_cmd},
    {stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE, env = GH_ENV}
  )
  if not p then return false, "Failed to start gh process" end

  local out = ""
  local start = system.get_time()
  -- Lua 5.4: coroutine.running() returns (co, isMain). isMain=true means main thread.
  -- Lua 5.1: coroutine.running() returns nil in main thread.
  -- Only yield if we're in a real coroutine (not main thread).
  local co, is_main = coroutine.running()
  local in_coro = co ~= nil and not is_main

  while p:returncode() == nil do
    if system.get_time() - start > timeout then
      p:kill()
      return false, "Timeout after " .. timeout .. "s"
    end
    out = out .. (p:read_stdout(16384) or "")
    out = out .. (p:read_stderr(16384)  or "")
    if in_coro then
      coroutine.yield(0.01) -- 10ms yield for smooth 60fps UI
    end
  end
  -- Drain remaining output
  out = out .. (p:read_stdout(65536) or "") .. (p:read_stderr(65536) or "")
  return p:returncode() == 0, out
end

-- ── Public API ───────────────────────────────────────────────────────────────────

-- Read remote file content (lazy, on-demand, cached).
-- Returns content_string or nil, error_string.
function VFS.read_file(local_path)
  if not VFS.active then return nil, "VFS not active" end

  -- Cache hit?
  local cached = cache_get(VFS.cache.files, local_path)
  if cached then return cached.content end

  -- Deduplicate in-flight requests for the same file
  local queue_key = "read:" .. local_path
  if VFS.request_queue[queue_key] then
    -- Another coroutine is already fetching; spin-wait for it
    local waited = 0
    while VFS.request_queue[queue_key] and waited < 30 do
      if coroutine.running() then
        coroutine.yield(0.1)
      end
      waited = waited + 0.1
    end
    cached = cache_get(VFS.cache.files, local_path)
    return cached and cached.content or nil, "Concurrent fetch timed out"
  end

  VFS.request_queue[queue_key] = true

  local remote_path = local_to_remote(local_path)
  core.log_quiet("[VFS] Fetching: %s → %s", local_path, remote_path)

  -- Use a sentinel that cannot appear in normal file content so we can detect errors
  local sentinel = "__VFS_ERR_8f3a9b2c__"
  local ok, out = run_ssh_command(
    VFS.codespace_name,
    "cat '" .. remote_path:gsub("'", "'\\''") .. "' 2>/dev/null || echo '" .. sentinel .. "'",
    30
  )

  VFS.request_queue[queue_key] = nil

  if not ok or out:find(sentinel, 1, true) then
    core.warn("[VFS] Failed to read remote file: %s", remote_path)
    return nil, "Remote read failed"
  end

  -- Store in cache
  cache_set(VFS.cache.files, local_path, {content = out})

  return out
end

-- List the children of a remote directory (lazy, cached).
-- local_dir_path is an absolute local path to a directory in the shadow tree.
-- Returns an array of { name=string, type="file"|"dir" } or empty table.
function VFS.readdir(local_dir_path)
  if not VFS.active then return {} end

  -- Cache hit?
  local cached = cache_get(VFS.cache.directories, local_dir_path)
  if cached then return cached.entries end

  local queue_key = "dir:" .. local_dir_path
  if VFS.request_queue[queue_key] then
    local waited = 0
    while VFS.request_queue[queue_key] and waited < 30 do
      if coroutine.running() then coroutine.yield(0.1) end
      waited = waited + 0.1
    end
    cached = cache_get(VFS.cache.directories, local_dir_path)
    return cached and cached.entries or {}
  end

  VFS.request_queue[queue_key] = true

  local remote_path = local_to_remote(local_dir_path)
  core.log_quiet("[VFS] readdir: %s", remote_path)

  -- Use `ls -la` to get type info (d = dir, - = file, l = symlink treated as file)
  local ok, out = run_ssh_command(
    VFS.codespace_name,
    "ls -la '" .. remote_path:gsub("'", "'\\''") .. "' 2>/dev/null",
    20
  )

  VFS.request_queue[queue_key] = nil

  local entries = {}
  if ok and out then
    for line in out:gmatch("[^\r\n]+") do
      -- ls -la format: drwxr-xr-x 2 user group 4096 Jul 5 12:00 name
      local perm, name = line:match("^([dlrwx%-]+)%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$")
      if perm and name and name ~= "." and name ~= ".." then
        local entry_type = perm:sub(1, 1) == "d" and "dir" or "file"
        table.insert(entries, {name = name, type = entry_type})
      end
    end
  end

  -- Sort: dirs first, then files, both alphabetically
  table.sort(entries, function(a, b)
    if a.type ~= b.type then return a.type == "dir" end
    return a.name < b.name
  end)

  cache_set(VFS.cache.directories, local_dir_path, {entries = entries})

  return entries
end

-- Write local file content back to remote (triggered on Doc:save).
function VFS.write_file(local_path, content)
  if not VFS.active then return false, "VFS not active" end

  local remote_path = local_to_remote(local_path)
  local remote_escaped = remote_path:gsub("'", "'\\''")
  
  -- Create a temporary batch script to run the SSH command with stdin redirection.
  -- This bypasses Windows CreateProcess quoting bugs and avoids editor hangs from p:write() on full OS pipes.
  local script_path = local_path .. ".upload.bat"
  local fd = io.open(script_path, "w")
  if not fd then return false, "Failed to create upload script" end
  fd:write("@echo off\r\n")
  fd:write("set GH_INSECURE_SKIP_VERIFY_TLS=1\r\n")
  fd:write("set GH_NO_UPDATE_NOTIFIER=1\r\n")
  fd:write(string.format('gh cs ssh -c "%s" -- sh -c "cat > \'%s\'" < "%s"\r\n', VFS.codespace_name, remote_escaped, local_path))
  fd:write('del "%~f0"\r\n')
  fd:close()

  local p = process.start(
    {"cmd.exe", "/c", script_path},
    {stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE}
  )
  if not p then return false, "Failed to start file upload" end

  local out_t = {}
  local start = system.get_time()
  while p:returncode() == nil do
    if system.get_time() - start > 60 then p:kill(); return false, "Timeout" end
    local chunk = p:read_stdout(65536)
    if chunk and #chunk > 0 then out_t[#out_t + 1] = chunk end
    local echk = p:read_stderr(65536)
    if echk and #echk > 0 then out_t[#out_t + 1] = echk end
    if coroutine.running() then coroutine.yield(0.05) end
  end

  -- Invalidate both caches on successful write
  if p:returncode() == 0 then
    VFS.cache.files[local_path] = nil
    local parent = local_path:match("^(.*)[/\\][^/\\]+$")
    if parent then VFS.cache.directories[parent] = nil end
    return true
  end
  local out = table.concat(out_t)
  core.warn("[VFS] Write failed: %s", out)
  return false, out
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────────

-- Recursively create directories
local function mkdir_recursive(path)
  local sep = package.config:sub(1,1)
  local current = ""
  for dir in path:gmatch("[^/\\]+") do
    current = current .. dir .. sep
    -- On Windows, the first part could be "C:", which we don't want to mkdir on its own
    if current:match("^[A-Za-z]:" .. sep .. "$") then
      -- Skip creating the drive letter directory
    else
      system.mkdir(current)
    end
  end
end

-- Create local skeleton directory structure (empty placeholder files) from remote.
-- This is called during activate() in a coroutine, so run_ssh_command can yield.
local function build_shadow_structure(cs_name, remote_dir, local_dir, on_progress)
  if on_progress then on_progress("Scanning remote filesystem...", 30) end

  -- Ensure the root local directory exists
  mkdir_recursive(local_dir)

  -- Single combined find: emits dirs+files in ONE SSH round trip.
  -- Format: "d <path>" for directories, "f <path>" for files.
  -- Capped at 6000 entries to prevent runaway builds on huge monorepos.
  local quoted_dir = "'" .. remote_dir:gsub("'", "'\\''" ) .. "'"
  local common_args = " -maxdepth 6 -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*'"
  local combined_cmd = 
    "find " .. quoted_dir .. common_args .. " -type d 2>/dev/null | sed 's/^/d /' | head -n 2000; " ..
    "find " .. quoted_dir .. common_args .. " -type f 2>/dev/null | sed 's/^/f /' | head -n 6000 || true"

  local ok, out = run_ssh_command(cs_name, combined_cmd, 240)

  local dir_count = 0
  local file_count = 0

  if out then
    -- First pass: create all directories
    for line in out:gmatch("[^\r\n]+") do
      local kind, path = line:match("^([df]) (.+)$")
      if kind == "d" and path and path ~= "" and path:sub(1, #remote_dir) == remote_dir then
        local rel = strip_prefix(path, remote_dir):gsub("/", package.config:sub(1,1))
        if rel ~= "" then
          mkdir_recursive(local_dir .. rel)
          dir_count = dir_count + 1
        end
      end
    end

    if on_progress then on_progress(string.format("Creating placeholder files (%d dirs)...", dir_count), 60) end

    -- Second pass: create 0-byte file placeholders
    for line in out:gmatch("[^\r\n]+") do
      local kind, path = line:match("^([df]) (.+)$")
      if kind == "f" and path and path ~= "" and path:sub(1, #remote_dir) == remote_dir then
        local rel = strip_prefix(path, remote_dir):gsub("/", package.config:sub(1,1))
        if rel ~= "" then
          local local_path = local_dir .. rel
          local fh = io.open(local_path, "wb")
          if fh then fh:close() end
          file_count = file_count + 1
        end
      end
    end
  end

  if file_count == 0 and not ok then
    return false, "Could not list remote files"
  end

  core.log_quiet("[VFS] Shadow: %d dirs, %d placeholders", dir_count, file_count)
  if on_progress then on_progress(string.format("Ready (%d files)", file_count), 80) end
  return true
end

-- Activate VFS for a connected codespace.
-- Called from github_codespaces.lua inside a core.add_thread() coroutine.
function VFS.activate(cs_name, remote_dir, local_dir, on_progress)
  VFS.active        = true
  VFS.codespace_name = cs_name
  VFS.remote_dir    = remote_dir
  VFS.local_dir     = local_dir
  VFS.cache.files   = {}
  VFS.cache.directories = {}
  VFS.request_queue = {}

  local ok, err = build_shadow_structure(cs_name, remote_dir, local_dir, on_progress)
  if not ok then
    core.warn("[VFS] Shadow build failed: %s", tostring(err))
  end

  core.log_quiet("[VFS] Activated: %s → %s", cs_name, remote_dir)
  return ok, err
end

-- Deactivate and clear all state.
function VFS.deactivate()
  VFS.active         = false
  VFS.codespace_name = nil
  VFS.remote_dir     = nil
  VFS.local_dir      = nil
  VFS.cache.files    = {}
  VFS.cache.directories = {}
  VFS.request_queue  = {}
  core.log_quiet("[VFS] Deactivated")
end

-- Returns true if the given path is inside the VFS shadow directory.
-- Normalizes separators before comparing so forward/backslash mismatches don't matter.
function VFS.is_virtual_path(path)
  if not VFS.active or not VFS.local_dir then return false end
  local np = normalize_path(path)
  local nl = normalize_path(VFS.local_dir)
  -- Must start with local_dir followed by a separator (or be exactly local_dir)
  if np == nl then return true end
  return np:sub(1, #nl + 1) == nl .. "/"
end

-- Expose local→remote helper so github_codespaces.lua can use it directly.
VFS.local_to_remote = local_to_remote

return VFS