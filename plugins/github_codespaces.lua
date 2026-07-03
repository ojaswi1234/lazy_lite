-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"

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
  for _, cfg in pairs(lspconfig) do
    if type(cfg) == "table" and cfg.command then
      -- Restore original before re-hooking (handles reconnect to different codespace)
      if cfg.orig_command then
        cfg.command = cfg.orig_command
      end
      cfg.orig_command = cfg.command
      local cmd_str = table.concat(cfg.orig_command, " ")
      cfg.command = {
        "python",
        USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "remote_lsp_proxy.py",
        cs_name, repo_name, cmd_str, USERDIR
      }
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

local function run_cmd_sync(args)
  local p = process.start(args, {stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE})
  if not p then return false, "Failed to start process" end
  local out = ""
  while p:returncode() == nil do
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
    coroutine.yield(0.1)
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

local function connect_codespace(cs)
  if cs.state ~= "Available" then
    modal.state = "loading"
    modal.loading_msg = "Waking up " .. cs.name .. " (takes 30-60s)..."
    core.redraw = true
  else
    modal.state = "loading"
    modal.loading_msg = "Preparing remote workspace..."
    core.redraw = true
  end

  local repo_name = cs.repo:match("[^/]+$") or cs.repo

  core.add_thread(function()
    -- 0. Get remote workspace directory (robust against SSH login shells that 'cd ~')
    local dir_success, dir_out = run_cmd_sync({"gh", "cs", "ssh", "-c", cs.name, "--", "sh", "-c", "'ls -d /workspaces/* | head -n 1'"})
    local remote_dir = "/workspaces/" .. repo_name
    if dir_success and dir_out then
      for line in dir_out:gmatch("[^\r\n]+") do
        if line:match("^/workspaces/") then remote_dir = line end
      end
    end

    -- 1. Tar on remote
    local abs_shadow_path = remote_dir .. "/shadow.tar.gz"
    local tar_script = "'cd " .. remote_dir .. " && tar -czf shadow.tar.gz --exclude=node_modules --exclude=.git --exclude=dist --exclude=build . || [ $? -eq 1 ]'"
    local success, err = run_cmd_sync({"gh", "cs", "ssh", "-c", cs.name, "--", "sh", "-c", tar_script})
    if not success then
      core.error("Failed to tar remote files: %s", tostring(err))
      modal.state = "list"
      core.redraw = true
      return
    end

    -- 2. Download
    modal.loading_msg = "Downloading to Shadow Workspace..."
    core.redraw = true
    local local_dir = USERDIR .. PATHSEP .. "codespaces"
    system.mkdir(local_dir)
    local_dir = local_dir .. PATHSEP .. cs.name
    system.mkdir(local_dir)
    
    success, err = run_cmd_sync({"gh", "cs", "cp", "remote:" .. abs_shadow_path, local_dir .. PATHSEP .. "shadow.tar.gz", "-c", cs.name})
    if not success then
      core.error("%s", "Failed to download workspace: " .. tostring(err))
      modal.state = "list"
      core.redraw = true
      return
    end

    -- 3. Extract
    -- Cleanup remote tarball
    run_gh_async({"gh", "cs", "ssh", "-c", cs.name, "--", "rm", "-f", abs_shadow_path})
    
    modal.loading_msg = "Extracting files..."
    core.redraw = true
    success, err = run_cmd_sync({"tar", "-xzf", local_dir .. PATHSEP .. "shadow.tar.gz", "-C", local_dir})
    if not success then
      core.error("%s", "Failed to extract workspace: " .. tostring(err))
      os.remove(local_dir .. PATHSEP .. "shadow.tar.gz")
      modal.state = "list"
      core.redraw = true
      return
    end
    os.remove(local_dir .. PATHSEP .. "shadow.tar.gz")

    modal.active = false
    core.project_directories = {}
    core.add_project_directory(local_dir)
    core.set_project_dir(local_dir)
    core.active_codespace = { name = cs.name, repo = repo_name, remote_dir = remote_dir, start_time = system.get_time() }
    if _G.restart_resource_monitor then _G.restart_resource_monitor() end
    hook_lsp_for_codespace(cs.name, repo_name)
    core.redraw = true
  end)
end

-- Hook saving to auto-sync to codespace
local Doc = require "core.doc"
local old_save = Doc.save
function Doc:save(...)
  local res = old_save(self, ...)
  if core.active_codespace and core.project_dir and self.abs_filename:find(core.project_dir, 1, true) == 1 then
    local rel_path = self.abs_filename:sub(#core.project_dir + 2)
    rel_path = rel_path:gsub("\\", "/")
    core.add_thread(function()
      core.log_quiet("Syncing %s to Codespace...", rel_path)
      local remote_path = core.active_codespace.remote_dir and (core.active_codespace.remote_dir.."/"..rel_path) or ("/workspaces/"..core.active_codespace.repo.."/"..rel_path)
      local success, err = run_cmd_sync({"gh", "cs", "cp", self.abs_filename, "remote:"..remote_path, "-c", core.active_codespace.name})
      if success then
        core.log_quiet("Successfully synced %s", rel_path)
      else
        core.error("Failed to sync %s to Codespace: %s", rel_path, tostring(err))
      end
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
    for _, cs in ipairs(modal.codespaces) do
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
      
      local icon_font = style.icon_font
      local stop_icon = ""
      local stop_w = icon_font:get_width(stop_icon)
      local stop_x = x + w - 40 * SCALE - stop_w
      renderer.draw_text(icon_font, stop_icon, stop_x, iy + 10 * SCALE, { 255, 80, 80, 255 })
      
      local state_x = stop_x - style.font:get_width(state_text) - 15 * SCALE
      renderer.draw_text(style.font, state_text, state_x, iy + 10 * SCALE, state_color)
    end
  end
end

-- Intercept Events
local old_on_event = core.on_event
function core.on_event(type, ...)
  if modal.active then
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
            -- Write token to temp file to avoid shell injection and cross-platform issues
            local tmp = os.tmpname()
            local f = io.open(tmp, "w")
            if not f then
              modal.state = "auth"
              core.error("Failed to create temp file for auth token")
              return
            end
            f:write(modal.token_input)
            f:close()
            local argv
            if PLATFORM == "Windows" then
              argv = {"cmd.exe", "/c", "type \"" .. tmp .. "\" | gh auth login --with-token"}
            else
              argv = {"sh", "-c", "cat " .. tmp .. " | gh auth login --with-token"}
            end
            local success, err = run_cmd_sync(argv)
            pcall(os.remove, tmp)
            if success then
              fetch_codespaces()
            else
              modal.state = "auth"
              modal.token_input = ""
              core.error("GitHub Login Failed. Invalid token.")
            end
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
        for _, cs in ipairs(modal.codespaces) do
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
            
            local stop_w = style.icon_font:get_width("")
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
  end
  return old_on_event(type, ...)
end

return {
  name = "GitHub Codespaces",
  description = "A massive integration for cloud development."
}
