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

local function run_gh_async(args, on_complete)
  core.add_thread(function()
    local p = process.start(args, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE
    })
    if not p then 
      if on_complete then on_complete(false, "") end
      return 
    end
    
    local out = ""
    while p:returncode() == nil do
      out = out .. (p:read_stdout(2048) or "")
      coroutine.yield(0.1)
    end
    out = out .. (p:read_stdout(2048) or "")
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
      for obj in out:gmatch("%{.-%}") do
        local name = obj:match('"name"%s*:%s*"([^"]+)"')
        local repo = obj:match('"repository"%s*:%s*"([^"]+)"')
        local state = obj:match('"state"%s*:%s*"([^"]+)"')
        if name and repo then
          table.insert(modal.codespaces, {name=name, repo=repo, state=state})
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

local function connect_codespace(cs)
  modal.state = "loading"
  modal.loading_msg = "Preparing remote workspace..."
  core.redraw = true

  local repo_name = cs.repo:match("[^/]+$") or cs.repo

  core.add_thread(function()
    -- 1. Tar on remote
    local p1 = process.start({"gh", "cs", "ssh", "-c", cs.name, "--", "sh", "-c", "cd /workspaces/"..repo_name.." && tar -czf /tmp/shadow.tar.gz --exclude=node_modules --exclude=.git --exclude=dist --exclude=build ."})
    while p1:returncode() == nil do coroutine.yield(0.1) end

    -- 2. Download
    modal.loading_msg = "Downloading to Shadow Workspace..."
    core.redraw = true
    local local_dir = USERDIR .. PATHSEP .. "codespaces"
    system.mkdir(local_dir)
    local_dir = local_dir .. PATHSEP .. cs.name
    system.mkdir(local_dir)
    
    local p2 = process.start({"gh", "cs", "cp", "remote:/tmp/shadow.tar.gz", local_dir .. PATHSEP .. "shadow.tar.gz", "-c", cs.name})
    while p2:returncode() == nil do coroutine.yield(0.1) end

    -- 3. Extract
    modal.loading_msg = "Extracting files..."
    core.redraw = true
    local p3 = process.start({"tar", "-xzf", local_dir .. PATHSEP .. "shadow.tar.gz", "-C", local_dir})
    while p3:returncode() == nil do coroutine.yield(0.1) end
    os.remove(local_dir .. PATHSEP .. "shadow.tar.gz")

    modal.active = false
    core.project_directories = {}
    core.add_project_directory(local_dir)
    core.set_project_dir(local_dir)
    core.active_codespace = { name = cs.name, repo = repo_name, start_time = system.get_time() }
    if _G.restart_resource_monitor then _G.restart_resource_monitor() end
    core.redraw = true
  end)
end

-- Hook saving to auto-sync to codespace
local Doc = require "core.doc"
local old_save = Doc.save
function Doc:save(...)
  local res = old_save(self, ...)
  if core.active_codespace and core.project_dir and self.abs_filename:find(core.project_dir, 1, true) then
    local rel_path = self.abs_filename:sub(#core.project_dir + 2)
    rel_path = rel_path:gsub("\\", "/")
    core.add_thread(function()
      core.log_quiet("Syncing %s to Codespace...", rel_path)
      local p = process.start({"gh", "cs", "cp", self.abs_filename, "remote:/workspaces/"..core.active_codespace.repo.."/"..rel_path, "-c", core.active_codespace.name})
      while p:returncode() == nil do coroutine.yield(0.1) end
      if p:returncode() == 0 then
        core.log_quiet("Successfully synced %s", rel_path)
      else
        core.error("Failed to sync %s to Codespace", rel_path)
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
  if modal.state == "list" then
    for _, cs in ipairs(modal.codespaces) do
      local txt_w = style.font:get_width(cs.name .. " (" .. cs.repo .. ")")
      max_w = math.max(max_w, txt_w + 200 * SCALE)
    end
  end
  
  local w = max_w
  local h = 400 * SCALE
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
      renderer.draw_text(style.font, cs.state, x + w - 100 * SCALE, iy + 10 * SCALE, { 150, 150, 150, 255 })
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
        modal.token_input = modal.token_input:sub(1, -2)
        core.redraw = true; return true
      elseif key == "return" then
        if modal.state == "auth" and #modal.token_input > 0 then
          modal.state = "loading"
          modal.loading_msg = "Logging in..."
          core.redraw = true
          -- Echo token into gh auth login
          core.add_thread(function()
            local p = process.start({"cmd.exe", "/c", "echo " .. modal.token_input .. " | gh auth login --with-token"})
            while p:returncode() == nil do coroutine.yield(0.1) end
            if p:returncode() == 0 then
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
      local w, h = 600 * SCALE, 400 * SCALE
      local px = (core.root_view.size.x - w) / 2
      local py = (core.root_view.size.y - h) / 2
      if mx < px or mx > px + w or my < py or my > py + h then
        modal.active = false
        core.redraw = true
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
