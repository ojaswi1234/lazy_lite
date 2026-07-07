-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"
local process = require "process"
local system = require "system"
local PATHSEP = PATHSEP or package.config:sub(1,1)
local USERDIR = USERDIR or core.userdir or (os.getenv("USERPROFILE") or os.getenv("HOME")) .. "/.config/lite-xl"
local STOP_ICON = "ï"

-- Lazy load loader_games to avoid circular dependency issues
local loader_games = nil
local function get_loader()
  if not loader_games then
    local ok, loader = pcall(require, "plugins.loader_games")
    if ok then
      loader_games = loader
    else
      core.error("Failed to load loader_games: %s", tostring(loader))
    end
  end
  return loader_games
end

-- Virtual File System for codespaces (VS Code-style approach)
local VFS = nil
local function get_vfs()
  if not VFS then
    local ok, vfs = pcall(require, "plugins.virtual_codespace_fs")
    if ok then
      VFS = vfs
    end
  end
  return VFS
end


local state = {
  codespace_name = nil,
  cache = {
    file_tree = {},      -- { "/path": { name, type, mtime, children } }
    file_content = {},   -- { "/path": { content, mtime, size } }
    connection = { connected = false, last_sync = 0, pending_ops = {} }
  },
  metrics = {
    latency = 0,
    last_check = 0,
    poll_interval = 10,
    sync_queue = {},
    offline_mode = false,
    resources = { cpu = 0, memory = 0, disk = 0 }, -- Remote resource usage
    git_status = { branch = "", changed_files = 0, ahead = 0, behind = 0 }
  }
}

local old_set_project_dir = core.set_project_dir
function core.set_project_dir(...)
  state.codespace_name = nil
  return old_set_project_dir(...)
end

local function resolve_active_codespace(basename)
  if state.codespace_name then return state.codespace_name end
  -- Note: run_cmd_sync is defined later in the file, so this needs to be called carefully
  -- This function is currently not used in the main flow, so we'll keep it for future use
  return nil
end

local modal = {
  active = false,
  state = "auth", -- "auth", "loading", "list"
  loading_msg = "",
  token_input = "",
  codespaces = {},
  selected_index = 1,
}

core.active_codespace = nil

local function restart_resource_monitor()
  local rm_ok, rm = pcall(require, "plugins.resource_monitor")
  if rm_ok and type(rm) == "table" and type(rm.restart) == "function" then
    rm.restart()
  end
end

local function hook_lsp_for_codespace(cs_name, repo_name)
  local lsp_ok, lsp = pcall(require, "plugins.lsp")
  if not lsp_ok then return end
  for key, cfg in pairs(lsp.servers) do
    if type(cfg) == "table" and cfg.command then
      -- Restore original before re-hooking (handles reconnect to different codespace)
      if cfg.orig_command then
        cfg.command = cfg.orig_command
      end
      local proxy_script = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "remote_lsp_proxy.py"
      if system.get_file_info(proxy_script) then
        cfg.orig_command = cfg.command
        local cmd_str = table.concat(cfg.orig_command, " ")
        cfg.command = { "python", proxy_script, cs_name, repo_name, cmd_str, USERDIR }
      else
        core.error("Missing LSP proxy: %s", proxy_script)
      end
    end
  end
  pcall(function() command.perform("lsp:restart") end)
end

local function unhook_lsp()
  local lsp_ok, lsp = pcall(require, "plugins.lsp")
  if not lsp_ok then return end
  for name, cfg in pairs(lsp.servers) do
    if type(cfg) == "table" and cfg.orig_command then
      cfg.command = cfg.orig_command
      cfg.orig_command = nil
    end
  end
  pcall(function() command.perform("lsp:restart") end)
end

local GH_ASYNC_TIMEOUT = 30

-- Environment passed to every gh subprocess.
-- GH_INSECURE_SKIP_VERIFY_TLS=1 silences x509/TLS cert errors that occur
-- when a corporate proxy or antivirus intercepts HTTPS (very common on Windows).
local GH_ENV = { GH_INSECURE_SKIP_VERIFY_TLS = "1", GH_NO_UPDATE_NOTIFIER = "1" }

local function run_gh_async(args, on_complete)
  core.add_thread(function()
    local p = process.start(args, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      env    = GH_ENV,
    })
    if not p then
      if on_complete then on_complete(false, "Failed to start gh process") end
      return
    end
    local out_t = {}
    local started = system.get_time()
    while p:returncode() == nil do
      local chunk = p:read_stdout(65536)
      if chunk and #chunk > 0 then out_t[#out_t + 1] = chunk end
      local echk = p:read_stderr(65536)
      if echk and #echk > 0 then out_t[#out_t + 1] = echk end
      if system.get_time() - started > GH_ASYNC_TIMEOUT then
        pcall(function() p:kill() end)
        if on_complete then on_complete(false, "gh command timed out after " .. GH_ASYNC_TIMEOUT .. "s") end
        return
      end
      coroutine.yield(0.01)
    end
    local chunk = p:read_stdout(65536)
    if chunk and #chunk > 0 then out_t[#out_t + 1] = chunk end
    local echk = p:read_stderr(65536)
    if echk and #echk > 0 then out_t[#out_t + 1] = echk end
    if on_complete then on_complete(p:returncode() == 0, table.concat(out_t)) end
  end)
end

local function fetch_codespaces()
  modal.state = "fetching"
  modal.loading_msg = "Fetching your active Codespaces..."
  core.redraw = true
  run_gh_async({"gh", "cs", "list", "--json", "name,repository,state"}, function(success, out)
    if success then
      modal.codespaces = {}
      -- Flatten newlines so patterns match across lines; %b{} handles nested braces
      local flat = out:gsub("[\r\n]", " ")
      for obj in flat:gmatch("%b{}") do
        local name  = obj:match('"name"%s*:%s*"([^"]+)"')
        local repo  = obj:match('"repository"%s*:%s*"([^"]+)"')
        local state = obj:match('"state"%s*:%s*"([^"]+)"')
        if name and repo then
          table.insert(modal.codespaces, {name=name, repo=repo, state=state or "Unknown"})
        end
      end
      if #modal.codespaces > 0 then
        modal.state = "list"
        modal.selected_index = 1
      else
        modal.state = "auth"
        modal.token_input = "No codespaces found."
      end
    else
      modal.state = "auth"
    end
    core.redraw = true
  end)
end

local function check_auth()
  modal.state = "fetching"
  modal.loading_msg = "Checking GitHub Authentication..."
  core.redraw = true
  run_gh_async({"gh", "auth", "token"}, function(success, out)
    -- gh auth token is much faster as it only checks the local keyring,
    -- bypassing network requests and avoiding flakiness
    if success and out and (out:match("gh[opsu]_[%a%d]+") or out:match("gh[a-zA-Z0-9_]+")) then
      fetch_codespaces()
    else
      modal.state = "auth"
      core.redraw = true
    end
  end)
end
local function stop_codespace(cs)
  if cs.state ~= "Available" then
    core.log_quiet("Codespace is already offline.")
    return
  end
  
  modal.state = "fetching"
  modal.loading_msg = "Shutting down " .. cs.name .. "..."
  core.redraw = true
  
  run_gh_async({"gh", "cs", "stop", "-c", cs.name}, function(success, out)
    if success or (out and out:find("is not running")) then
      if core.active_codespace and core.active_codespace.name == cs.name then
        local orig = core.active_codespace.original_dir
        core.active_codespace = nil
        unhook_lsp()
        restart_resource_monitor()
        if orig then
          if type(core.open_project) == "function" then
            core.open_project(orig)
          else
            -- Manual project switch: Close all open documents first
            for _, node in ipairs(core.root_view.root_node:get_children()) do
              if node.doc then
                pcall(function() node:close() end)
              end
            end
            -- Clear existing project directories
            if core.project_directories then
              for i = #core.project_directories, 1, -1 do
                pcall(function()
                  local pd = core.project_directories[i]
                  if type(pd) == "table" then
                    core.remove_project_directory(pd.name or pd)
                  elseif type(pd) == "string" then
                    core.remove_project_directory(pd)
                  end
                end)
              end
            end
            core.set_project_dir(orig)
            core.add_project_directory(orig)
          end
        end
      end
      fetch_codespaces()
    else
      -- Demote to a quiet warning so the xpcall chain doesn't propagate
      -- a modal error for transient TLS / network issues.
      core.log_quiet("[Codespaces] stop failed: %s", tostring(out))
      core.warn("Failed to stop Codespace (network/TLS issue). It may already be stopped.")
      modal.state = "list"
      core.redraw = true
    end
  end)
end

local function run_cmd_sync(args, timeout)
  timeout = timeout or 30 -- Default 30 second timeout
  local p = process.start(args, {stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE, env = GH_ENV})
  if not p then return false, "Failed to start process" end
  local out = ""
  local start_time = system.get_time()
  
  while p:returncode() == nil do
    local elapsed = system.get_time() - start_time
    if elapsed > timeout then
      p:kill()
      return false, "Command timeout after " .. timeout .. " seconds"
    end
    
    while true do
      local chunk = p:read_stdout(4096)
      if not chunk or chunk == "" then break end
      out = out .. chunk
    end
    while true do
      local chunk = p:read_stderr(4096)
      if not chunk or chunk == "" then break end
      out = out .. chunk
    end
    coroutine.yield(0.01) -- 10ms yield to allow 60FPS+ for game loader
  end
  while true do
    local chunk = p:read_stdout(4096)
    if not chunk or chunk == "" then break end
    out = out .. chunk
  end
  while true do
    local chunk = p:read_stderr(4096)
    if not chunk or chunk == "" then break end
    out = out .. chunk
  end
  return p:returncode() == 0, out
end

-- Blocking version of run_cmd_sync — no coroutine.yield, safe to call from
-- the main thread (e.g. Doc:load). Busy-waits but only for individual file
-- fetches which are typically fast (<500ms).
local function run_cmd_blocking(args, timeout)
  timeout = timeout or 30
  local p = process.start(args, {stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE, env = GH_ENV})
  if not p then return false, "Failed to start process" end
  local out = ""
  local start_time = system.get_time()
  while p:returncode() == nil do
    if system.get_time() - start_time > timeout then
      p:kill()
      return false, "Timeout"
    end
    out = out .. (p:read_stdout(16384) or "") .. (p:read_stderr(16384) or "")
  end
  out = out .. (p:read_stdout(65536) or "") .. (p:read_stderr(65536) or "")
  return p:returncode() == 0, out
end

-- Auto-selects yielding vs blocking based on whether we're in a coroutine.
local function run_cmd_auto(args, timeout)
  if coroutine.running() then
    return run_cmd_sync(args, timeout)
  else
    return run_cmd_blocking(args, timeout)
  end
end

local function shell_quote(value)
  value = tostring(value or "")
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function build_remote_workdir_command(remote_dir, cmd)
  local inner_cmd = string.format("cd '%s' && %s", remote_dir, cmd)
  return "'" .. inner_cmd:gsub("'", "'\\''") .. "'"
end

-- Cache functions for SSH file operations
local function get_remote_file_list(remote_path, cs_name)
  -- Use simple ls -1 for just file names, no directory detection for speed
  local success, out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "ls", "-1", remote_path}, 45) -- 45 second timeout for cold SSH
  if not success then return nil, out end
  
  local files = {}
  for line in out:gmatch("[^\r\n]+") do
    if line ~= "" and line ~= "." and line ~= ".." then
      -- Assume files for now, directory detection can be lazy-loaded
      table.insert(files, { name = line, type = "file" })
    end
  end
  return files
end

local function get_remote_file_content(remote_path, cs_name)
  -- Uses run_cmd_auto so it works both inside coroutines and from Doc:load
  local success, out = run_cmd_auto({"gh", "cs", "ssh", "-c", cs_name, "--", "cat", remote_path}, 30)
  if not success then return nil, out end
  return out
end

local function write_remote_file(remote_path, local_path, cs_name)
  -- Use gh cs cp for reliable file transfer
  local success, out = run_cmd_sync({"gh", "cs", "cp", local_path, "remote:" .. remote_path, "-c", cs_name})
  return success, out
end

-- VS Code-style approach: instead of bulk-downloading the workspace, we
-- just create a skeleton of directories + empty placeholder files locally
-- so the treeview can show the tree. File content is fetched on-demand
-- when the user opens a file (see Doc:load hook below).
local function populate_shadow_structure(cs_name, remote_dir, local_dir, on_progress)
  -- Windows' scp.exe (used by `gh cs cp --recursive`) cannot resolve Linux
  -- remote directory paths. We work around this with a 3-step tar approach:
  --   1. tar the workspace on the remote into a single .tar.gz in /tmp
  --   2. gh cs cp to pull that one file (single-file scp works fine)
  --   3. Extract locally with Windows' built-in tar (ships with Win10+)

  -- Step 1: get all directories (fast — just mkdir locally, no content)
  if on_progress then on_progress("Scanning remote directories...", 30) end
  local ok_d, out_d = run_cmd_sync(
    {"gh", "cs", "ssh", "-c", cs_name, "--", "sh", "-c",
     "find '" .. remote_dir .. "' -maxdepth 6 -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*' -type d 2>/dev/null || true"},
    240
  )

  local dir_count = 0
  if out_d then
    for path in out_d:gmatch("[^\r\n]+") do
      if path ~= "" and path:find(remote_dir, 1, true) == 1 then
        local rel = path:sub(#remote_dir + 1):gsub("/", PATHSEP)
        if rel ~= "" then
          system.mkdir(local_dir .. rel)
          dir_count = dir_count + 1
        end
      end
    end
  end

  -- Step 2: get all files — create empty placeholder files (0 bytes)
  -- Content is fetched on-demand when the user opens the file.
  if on_progress then on_progress(string.format("Creating %d placeholder files...", dir_count), 60) end
  local ok_f, out_f = run_cmd_sync(
    {"gh", "cs", "ssh", "-c", cs_name, "--", "sh", "-c",
     "find '" .. remote_dir .. "' -maxdepth 6 -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*' -type f 2>/dev/null || true"},
    240
  )

  local file_count = 0
  if out_f then
    for path in out_f:gmatch("[^\r\n]+") do
      if path ~= "" and path:find(remote_dir, 1, true) == 1 then
        local rel = path:sub(#remote_dir + 1):gsub("/", PATHSEP)
        if rel ~= "" then
          local local_path = local_dir .. rel
          -- Empty placeholder — content fetched on open
          local f = io.open(local_path, "wb")
          if f then f:close() end
          -- Store remote path in cache for on-demand lookup
          state.cache.file_tree[local_path] = path  -- local → remote
          file_count = file_count + 1
        end
      end
    end
  end

  if file_count == 0 and not ok_d then
    return false, "Could not read remote directory (dirs): " .. tostring(out_d) .. " (files): " .. tostring(out_f)
  end

  core.log_quiet("[Codespaces] Shadow: %d dirs, %d placeholder files", dir_count, file_count)
  return true
end

local function sync_file_tree(remote_path, cs_name, depth)
  depth = depth or 0
  if depth > 1 then return true end -- Limit to just top-level directory initially
  
  local files, err = get_remote_file_list(remote_path, cs_name)
  if not files then 
    core.log_quiet("Failed to get file list for %s: %s", remote_path, tostring(err))
    return false, err 
  end
  
  state.cache.file_tree[remote_path] = {
    children = {},
    mtime = system.get_time()
  }
  
  for idx, file in ipairs(files) do
    local full_path = remote_path .. (remote_path:sub(-1) == "/" and "" or "/") .. file.name
    state.cache.file_tree[full_path] = {
      name = file.name,
      type = file.type,
      mtime = system.get_time(),
      parent = remote_path
    }
    table.insert(state.cache.file_tree[remote_path].children, full_path)
    
    -- Skip recursive sync for now - do lazy loading instead
    -- if file.type == "dir" and file.name ~= "." and file.name ~= ".." then
    --   sync_file_tree(full_path, cs_name, depth + 1)
    -- end
  end
  
  return true
end

local function check_connection(cs_name)
  if not cs_name then return false end
  local start_time = system.get_time()
  local success, out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "echo", "connected"}, 30) -- 30 second timeout for cold SSH
  local end_time = system.get_time()
  
  state.cache.connection.connected = success
  state.cache.connection.last_sync = system.get_time()
  state.metrics.latency = (end_time - start_time) * 1000 -- Convert to ms
  state.metrics.last_check = system.get_time()
  
  -- Check if we're in offline mode (consecutive failures)
  if not success then
    state.metrics.offline_mode = true
    core.log_quiet("Connection check failed: %s", tostring(out))
  else
    state.metrics.offline_mode = false
  end
  
  return success
end

local function auto_reconnect()
  if not core.active_codespace then return end
  
  -- Check every 30 seconds
  local time_since_check = system.get_time() - state.metrics.last_check
  if time_since_check > 30 then
    local ok = check_connection(core.active_codespace.name)
    if not ok then
      core.log_quiet("Attempting auto-reconnect...")
      -- Clear connection state and retry
      state.cache.connection.connected = false
      local retry_ok = check_connection(core.active_codespace.name)
      if retry_ok then
        core.log_quiet("Auto-reconnect successful")
      else
        core.warn("Auto-reconnect failed, offline mode active")
      end
    end
  end
end

local function process_sync_queue()
  if not core.active_codespace then return end
  if #state.metrics.sync_queue == 0 then return end
  
  for idx = #state.metrics.sync_queue, 1, -1 do
    local op = state.metrics.sync_queue[idx]
    if op.type == "write" then
      local success, err = write_remote_file(op.remote_path, op.local_path, core.active_codespace.name)
      if success then
        core.log_quiet("Synced queued file: %s", op.remote_path)
        table.remove(state.metrics.sync_queue, idx)
      else
        core.warn("Failed to sync queued file: %s (keeping in queue)", op.remote_path)
      end
    end
  end
end

local function invalidate_cache(path)
  if path then
    state.cache.file_tree[path] = nil
    state.cache.file_content[path] = nil
  else
    state.cache.file_tree = {}
    state.cache.file_content = {}
  end
end

-- Remote resource monitoring — ONE SSH connection for all 3 metrics
local function get_remote_resources(cs_name)
  if not cs_name then return end
  -- Combined command: outputs 3 lines: cpu%, mem%, disk%
  local cmd = [[printf '%s\n' "$(top -bn1 | awk '/Cpu/{gsub(/[^0-9.]/," ",$0); print $1}')" "$(free | awk '/Mem/{printf "%.1f", $3/$2*100}')" "$(df /workspaces 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}')"]]
  local ok, out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "sh", "-c", cmd})
  if ok and out then
    local lines = {}
    for l in out:gmatch("[^\r\n]+") do lines[#lines + 1] = l end
    state.metrics.resources.cpu    = tonumber(lines[1]) or 0
    state.metrics.resources.memory = tonumber(lines[2]) or 0
    state.metrics.resources.disk   = tonumber(lines[3]) or 0
  else
    state.metrics.resources.cpu    = 0
    state.metrics.resources.memory = 0
    state.metrics.resources.disk   = 0
  end
end

-- Git status monitoring — ONE SSH connection for all 4 metrics
local function get_git_status(cs_name, remote_dir)
  if not cs_name or not remote_dir then return end
  -- Combined: outputs 4 lines: branch, changed_count, ahead, behind
  local rd = remote_dir:gsub("'", "'\\''")
  local cmd = string.format(
    "cd '%s' && git branch --show-current && git status --porcelain | wc -l && git rev-list --count @{u}..HEAD 2>/dev/null || echo 0 && git rev-list --count HEAD..@{u} 2>/dev/null || echo 0",
    rd
  )
  local ok, out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "sh", "-c", cmd})
  if ok and out then
    local lines = {}
    for l in out:gmatch("[^\r\n]+") do lines[#lines + 1] = l end
    state.metrics.git_status.branch        = lines[1] and lines[1]:gsub("%s+", "") or ""
    state.metrics.git_status.changed_files = tonumber(lines[2]) or 0
    state.metrics.git_status.ahead         = tonumber(lines[3]) or 0
    state.metrics.git_status.behind        = tonumber(lines[4]) or 0
  else
    state.metrics.git_status.branch        = ""
    state.metrics.git_status.changed_files = 0
    state.metrics.git_status.ahead         = 0
    state.metrics.git_status.behind        = 0
  end
end


local function connect_codespace(cs)
  if cs.state ~= "Available" then
    modal.state = "loading"
    modal.loading_msg = "Waking up " .. cs.name .. " (takes 30-60s)..."
    core.redraw = true
  else
    modal.state = "loading"
    modal.loading_msg = "Connecting to codespace..."
    core.redraw = true
  end

  local repo_name = cs.repo:match("[^/]+$") or cs.repo
  local original_dir = core.project_dir

  core.add_thread(function()
    -- Step 0: Get remote workspace directory.
    -- This is the ONLY initial SSH probe — it also acts as the wake-up call
    -- for sleeping codespaces. Timeout is 240s so cold starts (60s+ wake time)
    -- have enough budget. All other steps piggyback on the now-open connection.
    modal.loading_msg = "Waking up codespace / connecting..."
    local loader = get_loader()
    if loader then loader.start(modal.loading_msg) end
    core.redraw = true
    local remote_dir = "/workspaces/" .. repo_name
    local probe_success = false
    local start = system.get_time()
    
    while system.get_time() - start < 180 do
      -- The first time this runs, it acts as a wake-up call to the codespace.
      local dir_success, dir_out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs.name, "--", "pwd"}, 30)
      if dir_success and dir_out and dir_out ~= "" then
        remote_dir = dir_out:gsub("[\r\n%s]+", "")
        if not remote_dir:match("^/workspaces") then
          remote_dir = "/workspaces/" .. repo_name
        end
        probe_success = true
        break
      end
      
      -- If it timed out, query the actual Codespace state using VS Code's technique
      local st_ok, st_out = run_cmd_sync({"gh", "cs", "view", "-c", cs.name, "--json", "state", "-q", ".state"}, 10)
      local state = (st_ok and st_out) and st_out:gsub("[\r\n%s]+", "") or "Starting"
      
      if loader then loader.update_progress("Codespace is " .. state .. ", waiting...", 20) end
      core.redraw = true
      
      -- Sleep briefly before retrying
      local wait_until = system.get_time() + 5
      while system.get_time() < wait_until do
        coroutine.yield(0.1)
      end
    end
    
    if not probe_success then
      core.warn("[Codespaces] Initial SSH probe timed out entirely — using default path and hoping for the best...")
      if loader then loader.update_progress("Probe timeout, using default...", 10) end
    end

    core.log_quiet("Remote directory: %s", remote_dir)

    -- NEW: VS Code-style approach - use Virtual File System
    -- Hybrid: creates local file structure quickly (empty files) but fetches content on-demand
    -- Much faster than the old find-based approach
    
    local loader = get_loader()
    if loader then loader.update_progress("Activating virtual filesystem...", 40) end
    
    -- Activate VFS with progress callback
    local vfs = get_vfs()
    if vfs then
      local local_dir = USERDIR .. PATHSEP .. "codespaces" .. PATHSEP .. cs.name
      system.mkdir(local_dir)
      
      local function set_progress(msg, pct)
        modal.loading_msg = msg
        if loader then loader.update_progress(msg, pct) end
        core.redraw = true
      end
      
      local vfs_ok, vfs_err = vfs.activate(cs.name, remote_dir, local_dir, set_progress)
      
      if not vfs_ok and not dir_success then
        core.log_quiet("[Codespaces] Deadlock detected. Codespace is stuck in 'Starting'. Auto-rebuilding...")
        modal.loading_msg = "Deadlock detected! Auto-rebuilding Codespace..."
        if loader then loader.update_progress(modal.loading_msg, 0) end
        core.redraw = true
        
        local success, out = run_cmd_sync({"gh", "cs", "rebuild", "-c", cs.name}, 600)
        
        if success then
          core.log_quiet("[Codespaces] Successfully auto-rebuilt! Retrying connection...")
          core.command_view:enter("Rebuild Complete! Press Enter to reconnect.", {
            submit = function() command.perform("codespaces:open") end
          })
        else
          core.warn("Failed to auto-rebuild: %s", tostring(out))
        end
        
        if loader then loader.stop() end
        modal.active = false
        core.redraw = true
        return
      end
      
      if loader then loader.update_progress("Connected! (Virtual FS active)", 100) end
      -- No artificial delay — proceed immediately
    else
      core.error("Failed to load Virtual File System")
      if loader then loader.set_error("VFS initialization failed") end
      coroutine.yield(2)
    end

    if loader then loader.stop() end
    modal.active = false

    -- Switch to local directory (for compatibility, but operations go through VFS)
    local local_dir = USERDIR .. PATHSEP .. "codespaces" .. PATHSEP .. cs.name
    if type(core.open_project) == "function" then
      core.open_project(local_dir)
    else
      -- Manual project switch for older Lite-XL builds
      -- Close all open documents first
      for _, node in ipairs(core.root_view.root_node:get_children()) do
        if node.doc then
          pcall(function() node:close() end)
        end
      end
      -- Clear existing project directories (use pcall since the API varies)
      if core.project_directories then
        for i = #core.project_directories, 1, -1 do
          pcall(function()
            local pd = core.project_directories[i]
            if type(pd) == "table" then
              core.remove_project_directory(pd.name or pd)
            elseif type(pd) == "string" then
              core.remove_project_directory(pd)
            end
          end)
        end
      end
      core.set_project_dir(local_dir)
      core.add_project_directory(local_dir)
    end

    core.active_codespace = {
      name = cs.name,
      repo = repo_name,
      remote_dir = remote_dir,
      start_time = system.get_time(),
      local_dir = local_dir,
      original_dir = original_dir
    }

    core.log_quiet("Connected to codespace: %s", cs.name)
    core.log_quiet("Remote directory: %s", remote_dir)
    core.log_quiet("Local directory: %s (Virtual FS active)", local_dir)

    -- Make treeview visible and force a full refresh so it shows the new files
    core.add_thread(function()
      coroutine.yield(0.1) -- let the project switch settle
      -- Show treeview
      pcall(function()
        command.perform("treeview:toggle")
        command.perform("treeview:refresh")
      end)
    end)

    -- Hook LSP for codespace
    hook_lsp_for_codespace(cs.name, repo_name)
    
    -- Restart resource monitor
    restart_resource_monitor()
  end)
end

-- ── VS Code-style on-demand file fetching via VFS ─────────────────────────────
-- When the user opens a file that is an empty placeholder (0 bytes), we fetch the real
-- content on-demand over SSH — exactly like VS Code's readFile RPC.
--
-- CRITICAL: Doc:load(filename) is called with a RELATIVE path (e.g. "fix_db.py").
-- Lite-XL's core.open_doc() calls Doc:new(relative, abs_filename) which:
--   1. calls self:set_filename(relative, absolute)  ← sets self.abs_filename
--   2. calls self:load(relative)                    ← OUR HOOK fires here
-- So self.abs_filename is already populated when our hook runs.
-- We must use self.abs_filename (absolute) for VFS path checks, NOT the
-- filename argument (which is project-relative and will never match VFS.local_dir).
local Doc = require "core.doc"
local _orig_doc_load = Doc.load
function Doc:load(filename)
  local vfs = get_vfs()
  -- Use the absolute path that was already set by Doc:new → set_filename
  -- Fall back to filename only if abs_filename isn't set yet (edge case)
  local abs_path = self.abs_filename or filename

  if vfs and vfs.active and abs_path and vfs.is_virtual_path(abs_path) then
    local info = system.get_file_info(abs_path)
    -- Only fetch if this is still a 0-byte placeholder
    if info and info.size == 0 then
      if not self._vfs_fetching then
        self._vfs_fetching = true
        core.log_quiet("[VFS] Async fetch started: %s", abs_path)
        
        -- Run the fetch in a coroutine so the UI doesn't freeze
        core.add_thread(function()
          local content = vfs.read_file(abs_path)
          if content and #content > 0 then
            -- Write fetched bytes to the local placeholder so the editor reads real content
            local fh = io.open(abs_path, "wb")
            if fh then
              fh:write(content)
              fh:close()
              core.log_quiet("[VFS] Wrote %d bytes for: %s", #content, abs_path)
            end
            -- Reload the document content in the editor
            self:reload()
          else
            core.warn("[VFS] Failed to fetch (or empty file): %s", abs_path)
          end
          self._vfs_fetching = false
        end)
      end
      -- Fall through immediately so the UI doesn't block. 
      -- The file will open empty, and populate once the async fetch finishes.
    end
  end
  return _orig_doc_load(self, filename)
end

-- Hook saving to auto-sync to codespace via VFS
local old_save = Doc.save
function Doc:save(...)
  if self._vfs_fetching then
    core.warn("[VFS] Cannot save while still fetching file from Codespace.")
    return false
  end
  local res = old_save(self, ...)
  local vfs = get_vfs()
  if vfs and vfs.active and self.abs_filename and vfs.is_virtual_path(self.abs_filename) then
    if self._codespace_syncing then return res end
    self._codespace_syncing = true

    core.add_thread(function()
      core.log_quiet("[VFS] Syncing %s to remote...", self.abs_filename)
      local ok, err = vfs.write_file(self.abs_filename, nil)
      -- write_file now reads local file internally via gh cs cp
      if ok then
        core.log_quiet("[VFS] Sync successful")
      else
        core.warn("[VFS] Sync failed: %s", tostring(err))
      end
      self._codespace_syncing = false
    end)
  end
  return res
end

-- Add GitHub button to status bar
local status_view = require "core.statusview"
if status_view then
  core.status_view:add_item({
    name = "codespaces",
    alignment = status_view.Item.RIGHT,
    get_item = function()
      local color = core.active_codespace and {100, 255, 100, 255} or (modal.active and style.accent or style.text)
      local text = core.active_codespace and (" " .. core.active_codespace.name) or " GitHub Codespaces"
      
      if core.active_codespace then
        local is_lsp_active = false
        local lsp_ok, lsp = pcall(require, "plugins.lsp")
        if lsp_ok and core.active_view and core.active_view.doc and core.active_view.doc.filename then
          is_lsp_active = #lsp.get_active_servers(core.active_view.doc.filename, true) > 0
        end
        local dot_color
        if is_lsp_active then
          local alpha = 155 + math.floor(100 * math.sin(system.get_time() * 4))
          dot_color = {100, 255, 100, alpha}
        else
          dot_color = {255, 100, 100, 255}
        end
        return { color, style.icon_font, "", style.font, text, dot_color, style.font, " ●" }
      end
      
      return { color, style.icon_font, "", style.font, text }
    end,
    command = function()
      modal.active = not modal.active
      if modal.active then
        check_auth()
      end
    end
  })
end

-- Hook drawing to render the floating modal
local old_root_draw = core.root_view.draw
function core.root_view:draw()
  old_root_draw(self)
  
  if not modal.active then return end
  
  local max_w = 600 * SCALE
  local max_h = 400 * SCALE
  
  if modal.state == "loading" then
    -- Make the popup larger and more flexible for games
    max_w = math.max(max_w, math.min(self.size.x - 100 * SCALE, 800 * SCALE))
    max_h = math.max(max_h, math.min(self.size.y - 100 * SCALE, 600 * SCALE))
  elseif modal.state == "list" then
    for idx, cs in ipairs(modal.codespaces) do
      local txt_w = style.font:get_width(cs.name .. " (" .. cs.repo .. ")")
      max_w = math.max(max_w, txt_w + 200 * SCALE)
    end
    max_h = math.max(max_h, 120 * SCALE + #modal.codespaces * 40 * SCALE)
  end
  
  -- Prevent modal from exceeding window size
  local w = math.max(400 * SCALE, math.min(max_w, self.size.x - 40 * SCALE))
  local h = math.max(250 * SCALE, math.min(max_h, self.size.y - 40 * SCALE))
  local x = (self.size.x - w) / 2
  local y = (self.size.y - h) / 2
  
  renderer.draw_rect(0, 0, self.size.x, self.size.y, { 10, 10, 15, 180 })
  renderer.draw_rect(x, y, w, h, style.background)
  
  local border = 2 * SCALE
  local accent = { 100, 200, 150, 255 }
  renderer.draw_rect(x, y, w, border, accent)
  renderer.draw_rect(x, y + h - border, w, border, accent)
  renderer.draw_rect(x, y, border, h, accent)
  renderer.draw_rect(x + w - border, y, border, h, accent)
  
  local title_font = style.big_font or style.font
  renderer.draw_text(title_font, "GitHub Codespaces Integration", x + 30 * SCALE, y + 20 * SCALE, style.text)
  
  if modal.state == "loading" then
      local loader = get_loader()
      if loader and loader.active then 
        local pad = 10 * SCALE
        local title_h = 50 * SCALE
        loader.draw(x + pad, y + title_h, w - pad*2, h - title_h - pad) 
      end
  
  elseif modal.state == "fetching" then
    local text = modal.loading_msg or "Loading..."
    local dots = string.rep(".", math.floor(system.get_time() * 3) % 4)
    local display_text = text .. dots
    local t_w = style.font:get_width(display_text)
    renderer.draw_text(style.font, display_text, x + (w - t_w) / 2, y + h / 2, style.text)
    core.redraw = true -- Keep animating dots
  elseif modal.state == "auth" then
    renderer.draw_text(style.font, "Please authenticate with GitHub to view your codespaces.", x + 30 * SCALE, y + 60 * SCALE, style.dim)
    local iw = w - 60 * SCALE
    local ix = x + 30 * SCALE
    local iy = y + 100 * SCALE
    renderer.draw_rect(ix, iy, iw, 35 * SCALE, style.background2 or {20, 20, 25, 255})
    renderer.draw_rect(ix, iy, iw, 1 * SCALE, style.dim)
    
    local display = #modal.token_input > 0 and string.rep("*", #modal.token_input) or "Paste Personal Access Token here..."
    local color = #modal.token_input > 0 and {255, 255, 255, 255} or {100, 100, 110, 255}
    renderer.draw_text(style.font, display, ix + 10 * SCALE, iy + 10 * SCALE, color)
    renderer.draw_text(style.font, "Press ENTER to login or ESC to cancel.", ix, iy + 50 * SCALE, { 150, 150, 160, 255 })
  
  elseif modal.state == "list" then
    renderer.draw_text(style.font, "Select a Codespace to connect:", x + 30 * SCALE, y + 60 * SCALE, style.dim)
    for i, cs in ipairs(modal.codespaces) do
      local iy = y + 90 * SCALE + (i - 1) * 40 * SCALE
      local bg = (i == modal.selected_index) and style.line_highlight or style.background
      renderer.draw_rect(x + 30 * SCALE, iy, w - 60 * SCALE, 35 * SCALE, bg)
      renderer.draw_text(style.font, cs.name .. " (" .. cs.repo .. ")", x + 40 * SCALE, iy + 10 * SCALE, style.text)
      
      local state_text = cs.state
      local state_color = (state_text == "Available") and { 100, 255, 100, 255 } or { 150, 150, 150, 255 }
      
      local icon_font = style.icon_font or style.font
      local stop_icon = ""
      local stop_w = icon_font:get_width(stop_icon)
      local stop_x = x + w - 40 * SCALE - stop_w
      renderer.draw_text(icon_font, stop_icon, stop_x, iy + 10 * SCALE, { 255, 80, 80, 255 })
      
      local state_x = stop_x - style.font:get_width(state_text) - 15 * SCALE
      renderer.draw_text(style.font, state_text, state_x, iy + 10 * SCALE, state_color)
      
      -- Add connection status indicator if connected
      if core.active_codespace and core.active_codespace.name == cs.name then
        local conn_color = state.metrics.offline_mode and { 255, 150, 50, 255 } or { 100, 255, 100, 255 }
        local conn_text = state.metrics.offline_mode and "OFFLINE" or "CONNECTED"
        local conn_x = state_x - style.font:get_width(conn_text) - 15 * SCALE
        renderer.draw_text(style.font, conn_text, conn_x, iy + 10 * SCALE, conn_color)
      end
    end
  end
end

-- Cache management commands
command.add(nil, {
  ["codespaces:refresh-cache"] = function()
    if not core.active_codespace then
      core.warn("No codespace connected")
      return
    end
    core.add_thread(function()
      core.log_quiet("Refreshing file tree cache...")
      local ok = sync_file_tree(core.active_codespace.remote_dir, core.active_codespace.name)
      if ok then
        core.log_quiet("Cache refreshed successfully")
      else
        core.error("Cache refresh failed")
      end
    end)
  end,
  
  ["codespaces:clear-cache"] = function()
    invalidate_cache()
    core.log_quiet("Cache cleared")
  end,
  
  ["codespaces:connection-status"] = function()
    if not core.active_codespace then
      core.log_quiet("No codespace connected")
      return
    end
    core.add_thread(function()
      get_remote_resources(core.active_codespace.name)
      get_git_status(core.active_codespace.name, core.active_codespace.remote_dir)
      local ok = check_connection(core.active_codespace.name)
      if ok then
        core.log_quiet("SSH connection: OK (latency: %.0fms)", state.metrics.latency)
      else
        core.log_quiet("SSH connection: FAILED")
      end
      core.log_quiet("Cache size: %d files, %d content entries", 
        #state.cache.file_tree, #state.cache.file_content)
      core.log_quiet("Sync queue: %d pending operations", #state.metrics.sync_queue)
      core.log_quiet("Offline mode: %s", state.metrics.offline_mode and "YES" or "NO")
      core.log_quiet("Remote Resources:")
      core.log_quiet("  CPU: %.1f%%", state.metrics.resources.cpu)
      core.log_quiet("  Memory: %.1f%%", state.metrics.resources.memory)
      core.log_quiet("  Disk: %d%%", state.metrics.resources.disk)
      core.log_quiet("Git Status:")
      core.log_quiet("  Branch: %s", state.metrics.git_status.branch)
      core.log_quiet("  Changed: %d files", state.metrics.git_status.changed_files)
      core.log_quiet("  Ahead: %d, Behind: %d", state.metrics.git_status.ahead, state.metrics.git_status.behind)
      if core.active_codespace.start_time then
        local elapsed = system.get_time() - core.active_codespace.start_time
        core.log_quiet("Session uptime: %.0fs", elapsed)
      end
    end)
  end,
  
  ["codespaces:process-sync-queue"] = function()
    if not core.active_codespace then
      core.warn("No codespace connected")
      return
    end
    core.log_quiet("Processing sync queue...")
    process_sync_queue()
  end,
  
  ["codespaces:force-reconnect"] = function()
    if not core.active_codespace then
      core.warn("No codespace connected")
      return
    end
    core.add_thread(function()
      core.log_quiet("Forcing reconnection...")
      state.cache.connection.connected = false
      local ok = check_connection(core.active_codespace.name)
      if ok then
        core.log_quiet("Reconnection successful")
      else
        core.warn("Reconnection failed")
      end
    end)
  end,
  
  ["codespaces:disconnect"] = function()
    if not core.active_codespace then
      core.warn("No codespace connected")
      return
    end
    core.log_quiet("Disconnecting from Codespace...")
    local orig = core.active_codespace.original_dir
    core.active_codespace = nil
    unhook_lsp()
    restart_resource_monitor()
    if orig then
      if type(core.open_project) == "function" then
        core.open_project(orig)
      else
        -- Manual project switch: Close all open documents first
        for _, node in ipairs(core.root_view.root_node:get_children()) do
          if node.doc then
            pcall(function() node:close() end)
          end
        end
        -- Clear existing project directories
        if core.project_directories then
          for i = #core.project_directories, 1, -1 do
            pcall(function()
              local pd = core.project_directories[i]
              if type(pd) == "table" then
                core.remove_project_directory(pd.name or pd)
              elseif type(pd) == "string" then
                core.remove_project_directory(pd)
              end
            end)
          end
        end
        core.set_project_dir(orig)
        core.add_project_directory(orig)
      end
    end
  end,
  
  ["codespaces:open-remote-terminal"] = function()
    if not core.active_codespace then
      core.warn("No codespace connected")
      return
    end
    core.log_quiet("Opening remote terminal...")
    if PLATFORM == "Windows" then
      process.start({ "cmd.exe", "/c", "start", "cmd.exe", "/k", "gh codespace ssh -c " .. core.active_codespace.name })
    elseif PLATFORM == "Mac OS X" then
      process.start({ "osascript", "-e", 'tell app "Terminal" to do script "gh codespace ssh -c ' .. core.active_codespace.name .. '"' })
    else
      process.start({ "x-terminal-emulator", "-e", "gh codespace ssh -c " .. core.active_codespace.name })
    end
  end,
  
  ["codespaces:open-in-browser"] = function()
    if not core.active_codespace then
      core.warn("No codespace connected")
      return
    end
    core.log_quiet("Opening codespace in browser...")
    -- Wrap in core.add_thread to avoid yielding from the main thread (Lua 5.1 crash)
    core.add_thread(function()
      run_cmd_sync({"gh", "cs", "code", "-c", core.active_codespace.name})
    end)
  end,
  
  ["codespaces:show-resources"] = function()
    if not core.active_codespace then
      core.warn("No codespace connected")
      return
    end
    core.add_thread(function()
      get_remote_resources(core.active_codespace.name)
      core.log_quiet("Remote Resources:")
      core.log_quiet("  CPU: %.1f%%", state.metrics.resources.cpu)
      core.log_quiet("  Memory: %.1f%%", state.metrics.resources.memory)
      core.log_quiet("  Disk: %d%%", state.metrics.resources.disk)
    end)
  end,
  
  ["codespaces:refresh-git-status"] = function()
    if not core.active_codespace then
      core.warn("No codespace connected")
      return
    end
    core.add_thread(function()
      core.log_quiet("Refreshing git status...")
      get_git_status(core.active_codespace.name, core.active_codespace.remote_dir)
      core.log_quiet("Git Status:")
      core.log_quiet("  Branch: %s", state.metrics.git_status.branch)
      core.log_quiet("  Changed files: %d", state.metrics.git_status.changed_files)
      core.log_quiet("  Ahead: %d commits", state.metrics.git_status.ahead)
      core.log_quiet("  Behind: %d commits", state.metrics.git_status.behind)
    end)
  end,
  
  ["codespaces:git-pull"] = function()
    if not core.active_codespace then
      core.warn("No codespace connected")
      return
    end
    core.add_thread(function()
      core.log_quiet("Pulling from remote...")
      local success, out = run_cmd_sync({
        "gh", "cs", "ssh", "-c", core.active_codespace.name, "--", "sh", "-c",
        build_remote_workdir_command(core.active_codespace.remote_dir, "git pull")
      })
      if success then
        core.log_quiet("Pull successful")
        get_git_status(core.active_codespace.name, core.active_codespace.remote_dir)
      else
        core.warn("Pull failed: %s", tostring(out))
      end
    end)
  end,
  
  ["codespaces:git-push"] = function()
    if not core.active_codespace then
      core.warn("No codespace connected")
      return
    end
    core.add_thread(function()
      core.log_quiet("Pushing to remote...")
      local success, out = run_cmd_sync({
        "gh", "cs", "ssh", "-c", core.active_codespace.name, "--", "sh", "-c",
        build_remote_workdir_command(core.active_codespace.remote_dir, "git push")
      })
      if success then
        core.log_quiet("Push successful")
        get_git_status(core.active_codespace.name, core.active_codespace.remote_dir)
      else
        core.warn("Push failed: %s", tostring(out))
      end
    end)
  end,
  
  ["codespaces:run-command"] = function()
    if not core.active_codespace then
      core.warn("No codespace connected")
      return
    end
    core.command_view:enter("Run Remote Command", {
      submit = function(text)
        local cmd = (text or ""):match("^%s*(.-)%s*$")
        if cmd == "" then return end
        core.log_quiet("[codespaces] Running: %s", cmd)
        core.add_thread(function()
          local success, out = run_cmd_sync({
            "gh", "cs", "ssh", "-c", core.active_codespace.name, "--", "sh", "-c",
            build_remote_workdir_command(core.active_codespace.remote_dir, cmd)
          }, 120)
          if success then
            core.log_quiet("[codespaces] Command completed.")
            if out and out:match("%S") then
              local shown = 0
              for line in out:gmatch("[^\r\n]+") do
                core.log_quiet("%s", line)
                shown = shown + 1
                if shown >= 40 then
                  core.log_quiet("... output truncated ...")
                  break
                end
              end
            end
          else
            core.warn("Remote command failed: %s", tostring(out))
          end
        end)
      end
    })
  end,
  
  ["codespaces:rebuild-codespace"] = function()
    -- Useful for fixing deadlocked codespaces stuck in "Starting" state
    core.command_view:enter("Rebuild Codespace (Enter name)", {
      submit = function(name)
        local cs_name = (name or ""):match("^%s*(.-)%s*$")
        if cs_name == "" then return end
        core.log_quiet("[codespaces] Force rebuilding %s...", cs_name)
        
        modal.active = true
        modal.state = "loading"
        modal.loading_msg = "Rebuilding Codespace (This will take a few minutes)..."
        local loader = get_loader()
        if loader then loader.start(modal.loading_msg) end
        core.redraw = true
        
        core.add_thread(function()
          local success, out = run_cmd_sync({"gh", "cs", "rebuild", "-c", cs_name}, 600)
          
          if loader then loader.stop() end
          modal.active = false
          core.redraw = true
          
          if success then
            core.log_quiet("[codespaces] Successfully rebuilt %s! You can now reconnect.", cs_name)
            core.command_view:enter("Rebuild Complete! Press Enter to dismiss.", {
              submit = function() end
            })
          else
            core.warn("Failed to rebuild %s: %s", cs_name, tostring(out))
          end
        end)
      end
    })
  end,
})

-- Intercept Events
local old_on_event = core.on_event
function core.on_event(type, ...)
  if modal.active then
    if type == "resized" then core.redraw = true end
    if type == "textinput" and modal.state == "auth" then
      modal.token_input = modal.token_input .. (...)
      core.redraw = true; return true
    elseif type == "keypressed" then
      local key = ...
      
      -- Let the loader handle keypresses if active
      local loader = get_loader()
      if loader and loader.active and loader.on_keypressed(key) then
        return true
      end
      
      if key == "escape" then
        modal.active = false
        core.redraw = true; return true
      elseif key == "up" and modal.state == "list" then
        modal.selected_index = math.max(1, modal.selected_index - 1)
        core.redraw = true; return true
      elseif key == "down" and modal.state == "list" then
        modal.selected_index = math.min(#modal.codespaces, modal.selected_index + 1)
        core.redraw = true; return true
      elseif key == "backspace" and modal.state == "auth" then
        local text = modal.token_input
        if #text > 0 then
          local i = #text
          while i > 0 and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do
            i = i - 1
          end
          modal.token_input = text:sub(1, math.max(0, i - 1))
        end
        core.redraw = true; return true
      elseif key == "return" then
        if modal.state == "auth" and #modal.token_input > 0 then
          modal.state = "loading"
          modal.loading_msg = "Logging in..."
          core.redraw = true
          core.add_thread(function()
            local p = process.start({"gh", "auth", "login", "--with-token"}, { stdin = process.REDIRECT_PIPE, stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE, env = GH_ENV })
            if not p then modal.state = "auth"; core.error("Failed to start gh auth login"); return end
            p:write(modal.token_input .. "\n")
            p:close_stream(process.STREAM_STDIN)
            local out = ""
            while p:returncode() == nil do
              out = out .. (p:read_stdout(4096) or "")
              out = out .. (p:read_stderr(4096) or "")
              coroutine.yield(0.1)
            end
            if p:returncode() == 0 then fetch_codespaces() else modal.state = "auth"; modal.token_input = ""; core.error("GitHub Login Failed. Invalid token.") end
          end)
        elseif modal.state == "list" and modal.codespaces[modal.selected_index] then
          connect_codespace(modal.codespaces[modal.selected_index])
        end
        return true
      end
    elseif type == "mousepressed" then
      local button, mx, my = ...
      local max_w = 600 * SCALE
      local max_h = 400 * SCALE
      if modal.state == "list" then
        for idx, cs in ipairs(modal.codespaces) do
          local txt_w = style.font:get_width(cs.name .. " (" .. cs.repo .. ")")
          max_w = math.max(max_w, txt_w + 200 * SCALE)
        end
        max_h = math.max(max_h, 120 * SCALE + #modal.codespaces * 40 * SCALE)
      end
      local w, h = max_w, max_h
      local px = (core.root_view.size.x - w) / 2
      local py = (core.root_view.size.y - h) / 2
      
      if mx < px or mx > px + w or my < py or my > py + h then
        modal.active = false
        core.redraw = true
      elseif modal.state == "list" then
        local list_y = py + 90 * SCALE
        for i, cs in ipairs(modal.codespaces) do
          local iy = list_y + (i - 1) * 40 * SCALE
          if my >= iy and my <= iy + 35 * SCALE and mx >= px + 30 * SCALE and mx <= px + w - 30 * SCALE then
            modal.selected_index = i
            
            local stop_w = (style.icon_font or style.font):get_width("")
            local stop_x = px + w - 40 * SCALE - stop_w
            if mx >= stop_x - 10 * SCALE and mx <= stop_x + stop_w + 10 * SCALE then
              stop_codespace(cs)
            else
              connect_codespace(cs)
            end
            return true
          end
        end
      end
      return true
    end
    return true -- Consume all unhandled events
  end
  return old_on_event(type, ...)
end

local gh_check = process.start({"gh", "--version"}, {stdout = process.REDIRECT_DISCARD, stderr = process.REDIRECT_DISCARD})
if not gh_check then
  core.error("GitHub CLI (gh) not found. Please install it from https://cli.github.com/")
  return { name = "GitHub Codespaces", description = "gh CLI not installed" }
end

return {
  name = "GitHub Codespaces",
  description = "A massive integration for cloud development."
}
