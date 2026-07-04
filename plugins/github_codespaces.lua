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

local function hook_lsp_for_codespace(cs_name, repo_name)
  local lspconfig_ok, lspconfig = pcall(require, "plugins.lsp.config")
  if not lspconfig_ok then return end
  for key, cfg in pairs(lspconfig) do
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
  local lspconfig_ok, lspconfig = pcall(require, "plugins.lsp.config")
  if not lspconfig_ok then return end
  for name, config in pairs(lspconfig) do
    if type(config) == "table" and config.orig_command then
      config.command = config.orig_command
      config.orig_command = nil
    end
  end
  pcall(function() command.perform("lsp:restart") end)
end

local GH_ASYNC_TIMEOUT = 30

local function run_gh_async(args, on_complete)
  core.add_thread(function()
    local p = process.start(args, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE
    })
    if not p then
      if on_complete then on_complete(false, "Failed to start gh process") end
      return
    end
    local out = ""
    local started = system.get_time()
    while p:returncode() == nil do
      out = out .. (p:read_stdout(2048) or "")
      out = out .. (p:read_stderr(2048) or "")
      if system.get_time() - started > GH_ASYNC_TIMEOUT then
        pcall(function() p:kill() end)
        if on_complete then on_complete(false, "gh command timed out after " .. GH_ASYNC_TIMEOUT .. "s") end
        return
      end
      coroutine.yield(0.1)
    end
    out = out .. (p:read_stdout(2048) or "") .. (p:read_stderr(2048) or "")
    if on_complete then on_complete(p:returncode() == 0, out) end
  end)
end

local function fetch_codespaces()
  modal.state = "loading"
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
  modal.state = "loading"
  modal.loading_msg = "Checking GitHub Authentication..."
  core.redraw = true
  run_gh_async({"gh", "auth", "status"}, function(success, out)
    if success then
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
  
  modal.state = "loading"
  modal.loading_msg = "Shutting down " .. cs.name .. "..."
  core.redraw = true
  
  run_gh_async({"gh", "cs", "stop", "-c", cs.name}, function(success, out)
    if success or (out and out:find("is not running")) then
      if core.active_codespace and core.active_codespace.name == cs.name then
        core.active_codespace = nil
        unhook_lsp()
      end
      fetch_codespaces()
    else
      core.error("%s", "Failed to stop Codespace: " .. tostring(out))
      modal.state = "list"
      core.redraw = true
    end
  end)
end

local function run_cmd_sync(args, timeout)
  timeout = timeout or 30 -- Default 30 second timeout
  local p = process.start(args, {stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE})
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
    coroutine.yield(0.05) -- Reduced yield time for faster response
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

-- Cache functions for SSH file operations
local function get_remote_file_list(remote_path, cs_name)
  -- Use simple ls -1 for just file names, no directory detection for speed
  local success, out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "ls", "-1", remote_path}, 15) -- 15 second timeout
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
  local success, out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "cat", remote_path})
  if not success then return nil, out end
  return out
end

local function write_remote_file(remote_path, local_path, cs_name)
  -- Use gh cs cp for reliable file transfer
  local success, out = run_cmd_sync({"gh", "cs", "cp", local_path, "remote:" .. remote_path, "-c", cs_name})
  return success, out
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
  local success, out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "echo", "connected"}, 10) -- 10 second timeout for connection test
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
  
  for idx, op in ipairs(state.metrics.sync_queue) do
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

-- Remote resource monitoring
local function get_remote_resources(cs_name)
  if not cs_name then return end
  
  -- Get CPU usage (simplified)
  local cpu_success, cpu_out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "sh", "-c", "top -bn1 | grep 'Cpu(s)' | awk '{print $2}'"})
  if cpu_success and cpu_out then
    local cpu_val = cpu_out:match("(%d+%.?%d*)")
    state.metrics.resources.cpu = tonumber(cpu_val) or 0
  end
  
  -- Get memory usage
  local mem_success, mem_out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "sh", "-c", "free | grep Mem | awk '{print $3/$2 * 100.0}'"})
  if mem_success and mem_out then
    local mem_val = mem_out:match("(%d+%.?%d*)")
    state.metrics.resources.memory = tonumber(mem_val) or 0
  end
  
  -- Get disk usage
  local disk_success, disk_out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "sh", "-c", "df -h /workspaces | tail -1 | awk '{print $5}'"})
  if disk_success and disk_out then
    local disk_val = disk_out:match("(%d+)")
    state.metrics.resources.disk = tonumber(disk_val) or 0
  end
end

-- Git status monitoring
local function get_git_status(cs_name, remote_dir)
  if not cs_name or not remote_dir then return end
  
  -- Get current branch
  local branch_success, branch_out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "sh", "-c", "cd " .. remote_dir .. " && git branch --show-current"})
  if branch_success and branch_out then
    state.metrics.git_status.branch = branch_out:gsub("[\r\n%s]+", "")
  end
  
  -- Get changed files count
  local changed_success, changed_out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "sh", "-c", "cd " .. remote_dir .. " && git status --porcelain | wc -l"})
  if changed_success and changed_out then
    local changed_val = changed_out:match("(%d+)")
    state.metrics.git_status.changed_files = tonumber(changed_val) or 0
  end
  
  -- Get ahead/behind status
  local ahead_success, ahead_out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "sh", "-c", "cd " .. remote_dir .. " && git rev-list --count @{u}..HEAD"})
  if ahead_success and ahead_out then
    state.metrics.git_status.ahead = tonumber(ahead_out:gsub("[\r\n%s]+", "")) or 0
  end
  
  local behind_success, behind_out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs_name, "--", "sh", "-c", "cd " .. remote_dir .. " && git rev-list --count HEAD..@{u}"})
  if behind_success and behind_out then
    state.metrics.git_status.behind = tonumber(behind_out:gsub("[\r\n%s]+", "")) or 0
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

  core.add_thread(function()
    -- 0. Get remote workspace directory
    local dir_success, dir_out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs.name, "--", "pwd"})
    local remote_dir = "/workspaces/" .. repo_name
    if dir_success and dir_out and dir_out ~= "" then
      -- Clean up the path, remove newlines and extra spaces
      remote_dir = dir_out:gsub("[\r\n%s]+", "")
      -- If it doesn't start with /workspaces, use the default
      if not remote_dir:match("^/workspaces") then
        remote_dir = "/workspaces/" .. repo_name
      end
    end

    core.log_quiet("Remote directory: %s", remote_dir)
    
    -- 1. Test connection with fallback
    modal.loading_msg = "Testing SSH connection..."
    core.redraw = true
    local conn_ok = check_connection(cs.name)
    if not conn_ok then
      core.warn("SSH connection test failed, but continuing...")
      -- Don't fail hard on connection test - try to proceed anyway
      -- modal.state = "list"
      -- core.redraw = true
      -- return
    end

    -- 2. Sync file tree (cache population) - only top level for speed
    modal.loading_msg = "Caching file tree (top level)..."
    core.redraw = true
    local sync_ok = sync_file_tree(remote_dir, cs.name)
    if not sync_ok then
      core.warn("File tree sync had issues, but connection established")
    else
      core.log_quiet("Cached %d files in top-level directory", #state.cache.file_tree[remote_dir].children)
    end

    -- 3. Set up local shadow directory (for compatibility)
    local local_dir = USERDIR .. PATHSEP .. "codespaces"
    system.mkdir(local_dir)
    local_dir = local_dir .. PATHSEP .. cs.name
    system.mkdir(local_dir)

    modal.active = false
    if #core.project_directories > 0 then
      for i = #core.project_directories, 1, -1 do core.remove_project_directory(core.project_directories[i]) end
    end
    core.add_project_directory(local_dir)
    core.set_project_dir(local_dir)
    core.active_codespace = { 
      name = cs.name, 
      repo = repo_name, 
      remote_dir = remote_dir, 
      start_time = system.get_time(),
      local_dir = local_dir
    }
    
    core.log_quiet("Connected to codespace: %s", cs.name)
    core.log_quiet("Remote directory: %s", remote_dir)
    core.log_quiet("Local shadow: %s", local_dir)
    
    local rm_ok, rm = pcall(require, "plugins.resource_monitor")
    if rm_ok and type(rm) == "table" and type(rm.restart) == "function" then rm.restart() end
    hook_lsp_for_codespace(cs.name, repo_name)
    core.redraw = true
    
    -- Start background maintenance tasks
    core.add_thread(function()
      while core.active_codespace and core.active_codespace.name == cs.name do
        auto_reconnect()
        process_sync_queue()
        get_remote_resources(cs.name)
        get_git_status(cs.name, core.active_codespace.remote_dir)
        coroutine.yield(30) -- Check every 30 seconds
      end
    end)
  end)
end

-- Hook saving to auto-sync to codespace
local Doc = require "core.doc"
local old_save = Doc.save
function Doc:save(...)
  local res = old_save(self, ...)
  if core.active_codespace and core.project_dir and self.abs_filename and self.abs_filename:find(core.project_dir, 1, true) == 1 then
    local rel_path = self.abs_filename:sub(#core.project_dir + 2)
    rel_path = rel_path:gsub("\\", "/")
    if self._codespace_syncing then return res end
    self._codespace_syncing = true
    core.add_thread(function()
      core.log_quiet("Syncing %s to Codespace...", rel_path)
      local remote_path = core.active_codespace.remote_dir and (core.active_codespace.remote_dir.."/"..rel_path) or ("/workspaces/"..core.active_codespace.repo.."/"..rel_path)
      
      -- If offline, add to sync queue
      if state.metrics.offline_mode then
        table.insert(state.metrics.sync_queue, {
          type = "write",
          remote_path = remote_path,
          local_path = self.abs_filename,
          timestamp = system.get_time()
        })
        core.log_quiet("Added to sync queue (offline mode): %s", rel_path)
        self._codespace_syncing = false
        return
      end
      
      -- Write directly to remote via gh cs cp
      local success, err = write_remote_file(remote_path, self.abs_filename, core.active_codespace.name)
      if success then
        core.log_quiet("Successfully synced %s", rel_path)
        -- Update cache
        local f = io.open(self.abs_filename, "r")
        if f then
          local content = f:read("*a")
          f:close()
          state.cache.file_content[remote_path] = {
            content = content,
            mtime = system.get_time(),
            size = #content
          }
        end
      else
        core.error("Failed to sync %s to Codespace: %s", rel_path, tostring(err))
        -- Add to sync queue on failure
        table.insert(state.metrics.sync_queue, {
          type = "write",
          remote_path = remote_path,
          local_path = self.abs_filename,
          timestamp = system.get_time()
        })
        core.log_quiet("Added to sync queue (will retry): %s", rel_path)
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
  if modal.state == "list" then
    for idx, cs in ipairs(modal.codespaces) do
      local txt_w = style.font:get_width(cs.name .. " (" .. cs.repo .. ")")
      max_w = math.max(max_w, txt_w + 200 * SCALE)
    end
    max_h = math.max(max_h, 120 * SCALE + #modal.codespaces * 40 * SCALE)
  end
  
  local w = max_w
  local h = max_h
  local x = (self.size.x - w) / 2
  local y = (self.size.y - h) / 2
  
  renderer.draw_rect(0, 0, self.size.x, self.size.y, { 10, 10, 15, 180 })
  renderer.draw_rect(x, y, w, h, { 30, 30, 35, 255 })
  
  local border = 2 * SCALE
  local accent = { 100, 200, 150, 255 }
  renderer.draw_rect(x, y, w, border, accent)
  renderer.draw_rect(x, y + h - border, w, border, accent)
  renderer.draw_rect(x, y, border, h, accent)
  renderer.draw_rect(x + w - border, y, border, h, accent)
  
  local title_font = style.big_font or style.font
  renderer.draw_text(title_font, "GitHub Codespaces Integration", x + 30 * SCALE, y + 20 * SCALE, { 255, 255, 255, 255 })
  
  if modal.state == "loading" then
      local t = system.get_time()
      local cx, cy = x + w / 2, y + h / 2
      
      -- Pulse effect on GitHub icon
      local pulse = (math.sin(t * 5) + 1) / 2
      local alpha = 100 + (155 * pulse)
      local icon_font = style.icon_big_font or style.big_font or style.font
      local iw = icon_font:get_width("")
      renderer.draw_text(icon_font, "", cx - iw/2, cy - 40 * SCALE, {style.accent[1], style.accent[2], style.accent[3], alpha})
      
      -- Loading text with animated dots
      local dots = string.rep(".", math.floor(t * 3) % 4)
      local msg = (modal.loading_msg or "Loading") .. dots
      local tw = style.font:get_width(msg)
      renderer.draw_text(style.font, msg, cx - tw/2, cy + 20 * SCALE, {220, 220, 220, 255})
      
      -- Sleek indeterminate progress bar
      local bar_w = 200 * SCALE
      local bar_h = 2 * SCALE
      local bar_x = cx - bar_w / 2
      local bar_y = cy + 50 * SCALE
      renderer.draw_rect(bar_x, bar_y, bar_w, bar_h, {40, 40, 45, 255})
      
      local thumb_w = 60 * SCALE
      local offset = (math.sin(t * 4) + 1) / 2 * (bar_w - thumb_w)
      renderer.draw_rect(bar_x + offset, bar_y, thumb_w, bar_h, style.accent)
      
      -- Force continuous redraw for smooth 60fps animation
      core.redraw = true
  
  elseif modal.state == "auth" then
    renderer.draw_text(style.font, "Please authenticate with GitHub to view your codespaces.", x + 30 * SCALE, y + 60 * SCALE, { 200, 200, 200, 255 })
    local iw = w - 60 * SCALE
    local ix = x + 30 * SCALE
    local iy = y + 100 * SCALE
    renderer.draw_rect(ix, iy, iw, 35 * SCALE, { 20, 20, 25, 255 })
    renderer.draw_rect(ix, iy, iw, 1 * SCALE, { 80, 80, 90, 255 })
    
    local display = #modal.token_input > 0 and string.rep("*", #modal.token_input) or "Paste Personal Access Token here..."
    local color = #modal.token_input > 0 and {255, 255, 255, 255} or {100, 100, 110, 255}
    renderer.draw_text(style.font, display, ix + 10 * SCALE, iy + 10 * SCALE, color)
    renderer.draw_text(style.font, "Press ENTER to login or ESC to cancel.", ix, iy + 50 * SCALE, { 150, 150, 160, 255 })
  
  elseif modal.state == "list" then
    renderer.draw_text(style.font, "Select a Codespace to connect:", x + 30 * SCALE, y + 60 * SCALE, { 200, 200, 200, 255 })
    for i, cs in ipairs(modal.codespaces) do
      local iy = y + 90 * SCALE + (i - 1) * 40 * SCALE
      local bg = (i == modal.selected_index) and { 50, 50, 60, 255 } or { 30, 30, 35, 255 }
      renderer.draw_rect(x + 30 * SCALE, iy, w - 60 * SCALE, 35 * SCALE, bg)
      renderer.draw_text(style.font, cs.name .. " (" .. cs.repo .. ")", x + 40 * SCALE, iy + 10 * SCALE, { 255, 255, 255, 255 })
      
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
      core.error("No codespace connected")
      return
    end
    core.log_quiet("Refreshing file tree cache...")
    local ok = sync_file_tree(core.active_codespace.remote_dir, core.active_codespace.name)
    if ok then
      core.log_quiet("Cache refreshed successfully")
    else
      core.error("Cache refresh failed")
    end
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
  end,
  
  ["codespaces:process-sync-queue"] = function()
    if not core.active_codespace then
      core.error("No codespace connected")
      return
    end
    core.log_quiet("Processing sync queue...")
    process_sync_queue()
  end,
  
  ["codespaces:force-reconnect"] = function()
    if not core.active_codespace then
      core.error("No codespace connected")
      return
    end
    core.log_quiet("Forcing reconnection...")
    state.cache.connection.connected = false
    local ok = check_connection(core.active_codespace.name)
    if ok then
      core.log_quiet("Reconnection successful")
    else
      core.error("Reconnection failed")
    end
  end,
  
  ["codespaces:open-remote-terminal"] = function()
    if not core.active_codespace then
      core.error("No codespace connected")
      return
    end
    core.log_quiet("Opening remote terminal...")
    run_cmd_sync({"gh", "cs", "ssh", "-c", core.active_codespace.name})
  end,
  
  ["codespaces:open-in-browser"] = function()
    if not core.active_codespace then
      core.error("No codespace connected")
      return
    end
    core.log_quiet("Opening codespace in browser...")
    run_cmd_sync({"gh", "cs", "code", "-c", core.active_codespace.name})
  end,
  
  ["codespaces:show-resources"] = function()
    if not core.active_codespace then
      core.error("No codespace connected")
      return
    end
    get_remote_resources(core.active_codespace.name)
    core.log_quiet("Remote Resources:")
    core.log_quiet("  CPU: %.1f%%", state.metrics.resources.cpu)
    core.log_quiet("  Memory: %.1f%%", state.metrics.resources.memory)
    core.log_quiet("  Disk: %d%%", state.metrics.resources.disk)
  end,
  
  ["codespaces:refresh-git-status"] = function()
    if not core.active_codespace then
      core.error("No codespace connected")
      return
    end
    core.log_quiet("Refreshing git status...")
    get_git_status(core.active_codespace.name, core.active_codespace.remote_dir)
    core.log_quiet("Git Status:")
    core.log_quiet("  Branch: %s", state.metrics.git_status.branch)
    core.log_quiet("  Changed files: %d", state.metrics.git_status.changed_files)
    core.log_quiet("  Ahead: %d commits", state.metrics.git_status.ahead)
    core.log_quiet("  Behind: %d commits", state.metrics.git_status.behind)
  end,
  
  ["codespaces:git-pull"] = function()
    if not core.active_codespace then
      core.error("No codespace connected")
      return
    end
    core.log_quiet("Pulling from remote...")
    local success, out = run_cmd_sync({"gh", "cs", "ssh", "-c", core.active_codespace.name, "--", "sh", "-c", "cd " .. core.active_codespace.remote_dir .. " && git pull"})
    if success then
      core.log_quiet("Pull successful")
      get_git_status(core.active_codespace.name, core.active_codespace.remote_dir)
    else
      core.error("Pull failed: %s", tostring(out))
    end
  end,
  
  ["codespaces:git-push"] = function()
    if not core.active_codespace then
      core.error("No codespace connected")
      return
    end
    core.log_quiet("Pushing to remote...")
    local success, out = run_cmd_sync({"gh", "cs", "ssh", "-c", core.active_codespace.name, "--", "sh", "-c", "cd " .. core.active_codespace.remote_dir .. " && git push"})
    if success then
      core.log_quiet("Push successful")
      get_git_status(core.active_codespace.name, core.active_codespace.remote_dir)
    else
      core.error("Push failed: %s", tostring(out))
    end
  end,
  
  ["codespaces:run-command"] = function()
    if not core.active_codespace then
      core.error("No codespace connected")
      return
    end
    core.log_quiet("Opening command input...")
    -- This would need a UI for command input - for now just open terminal
    run_cmd_sync({"gh", "cs", "ssh", "-c", core.active_codespace.name})
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
            local p = process.start({"gh", "auth", "login", "--with-token"}, { stdin = process.REDIRECT_PIPE, stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
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
