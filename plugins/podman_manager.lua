-- mod-version:3
-- Unified Podman, Compose, and Kubernetes Manager for Lite XL
local core    = require "core"
local command = require "core.command"
local style   = require "core.style"
local View    = require "core.view"
local process = require "process"
local system  = require "system"

local PODMAN_COLORS = {
  up = {100, 255, 100, 255},
  exited = {255, 100, 100, 255},
  header = style.accent,
}

-- Full exe paths. On Windows, use 8.3 short path for podman (no spaces) so the
-- io.popen command string doesn't START with a quote. When cmd.exe /c sees a command
-- starting with ", it strips the first and last " from the whole string, breaking inner quotes.
-- 8.3 short path has no spaces -> no quote needed -> cmd.exe parses normally.
local PODMAN_EXE   = PLATFORM == "Windows" and "C:\\PROGRA~1\\RedHat\\Podman\\podman.exe" or "podman"
local KUBECTL_EXE  = PLATFORM == "Windows" and "kubectl" or "kubectl"
local K3S_EXE      = PLATFORM == "Windows" and "k3s"     or "k3s"

-- Build a cmd.exe-safe command string from a table of args.
-- The first element (exe) is already pre-quoted if needed via the PODMAN_EXE constant.
-- Other args get quoted if they contain spaces.
local function build_win_cmd(args)
  local parts = {}
  for i, v in ipairs(args) do
    -- Quote args that contain spaces OR cmd.exe special chars (|, &, <, >, ^, %)
    if i > 1 and v:find("[%s|&<>^%%]") then
      parts[#parts+1] = '"' .. v:gsub('"', '\\"') .. '"'
    else
      parts[#parts+1] = v
    end
  end
  return table.concat(parts, " ")
end

-- async_exec: on Windows use io.popen (cmd.exe), on Unix use process.start.
-- io.popen is used on Windows because process.start's CreateProcess has issues
-- finding executables in paths with spaces on this setup.
local function async_exec(cmd_args, on_result)
  core.add_thread(function()
    if PLATFORM == "Windows" then
      local cmd_str
      if type(cmd_args) == "table" then
        cmd_str = build_win_cmd(cmd_args)
      else
        cmd_str = cmd_args
      end
      -- io.popen goes through cmd.exe which handles quoted paths and PATH lookup
      local h = io.popen(cmd_str .. " 2>nul", "r")
      local out = h and h:read("*a") or ""
      if h then h:close() end
      out = out:gsub("%z", "")
      -- Debug: write cmd and output to file
      local dbg = io.open("C:/Users/ojasw/popen_debug.log", "a")
      if dbg then
        dbg:write("CMD: " .. tostring(cmd_str) .. "\n")
        dbg:write("OUT: " .. tostring(out) .. "\n---\n")
        dbg:close()
      end
      if on_result then on_result(out, "", 0) end
    else
      local args = type(cmd_args) == "table" and cmd_args or {"bash", "-c", cmd_args}
      local p = process.start(args)
      if not p then
        if on_result then on_result(nil, "Failed to start process") end
        return
      end
      local out, err = "", ""
      while p:running() do
        out = out .. (p:read_stdout() or "")
        err = err .. (p:read_stderr() or "")
        coroutine.yield(0.1)
      end
      out = out .. (p:read_stdout() or "")
      err = err .. (p:read_stderr() or "")
      local rc = p:returncode()
      if on_result then on_result(out, err, rc) end
    end
  end)
end

local PodmanView = View:extend()

local function split(str, sep)
  local res = {}
  for w in str:gmatch("([^" .. sep .. "]+)") do
    table.insert(res, w)
  end
  return res
end


function PodmanView:new()
  PodmanView.super.new(self)
  self.scrollable = true
  self.focusable = true
  self.name = "Podman Manager"
  self.target_size = 350 * SCALE
  self.visible = false
  
  self.sections = {
    { id = "compose", name = "Podman Compose", expanded = true, data = {}, loading = false },
    { id = "containers", name = "Containers", expanded = true, data = {}, loading = false },
    { id = "images", name = "Images", expanded = false, data = {}, loading = false },
    { id = "k8s", name = "Kubernetes Pods", expanded = false, data = {}, loading = false },
    { id = "k3s", name = "K3s Pods", expanded = false, data = {}, loading = false },
  }
  
  self.hovered_item = nil
  self.hovered_btn = nil
  self.buttons = {} -- stores click rects for the current frame
  
  self:refresh_all()
end

function PodmanView:get_name() return self.name end

function PodmanView:refresh_all()
  self:refresh_compose()
  self:refresh_containers()
  self:refresh_images()
  self:refresh_k8s()
  self:refresh_k3s()
end

function PodmanView:refresh_compose()
  local sec = nil
  for _, s in ipairs(self.sections) do if s.id == "compose" then sec = s; break end end
  if not sec then return end
  sec.loading = true
  core.redraw = true
  
  local proj_dir = core.project_dir or (core.project_directories and core.project_directories[1] and core.project_directories[1].name) or system.absolute_path(".") or ""
  
  local has_compose = false
  for _, f in ipairs({"docker-compose.yml", "docker-compose.yaml", "podman-compose.yml", "compose.yml", "compose.yaml"}) do
    local p = proj_dir .. PATHSEP .. f
    local file = io.open(p, "r")
    if file then
      file:close()
      has_compose = true
      break
    end
  end
  
  sec.data = {}
  if has_compose then
    local name = proj_dir:match("([^/\\]+)$") or "Project"
    table.insert(sec.data, { name = "Project: " .. name })
  end
  sec.loading = false
  core.redraw = true
end

function PodmanView:refresh_containers()
  local sec = nil
  for _, s in ipairs(self.sections) do if s.id == "containers" then sec = s; break end end
  if not sec then return end
  sec.loading = true
  core.redraw = true
  async_exec({PODMAN_EXE, "ps", "-a", "--format", "{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}|{{.Ports}}"}, function(out, err)
    sec.data = {}
    if out then
      for line in out:gmatch("[^\r\n]+") do
        local parts = split(line, "|")
        if #parts >= 4 then
          local ports = parts[5] or ""
          table.insert(sec.data, { id = parts[1], name = parts[2], status = parts[3], image = parts[4], ports = ports })
        end
      end
    end
    sec.loading = false
    core.redraw = true
  end)
end

function PodmanView:refresh_images()
  local sec = nil
  for _, s in ipairs(self.sections) do if s.id == "images" then sec = s; break end end
  if not sec then return end
  sec.loading = true
  core.redraw = true
  async_exec({PODMAN_EXE, "images", "--format", "{{.ID}}|{{.Repository}}|{{.Tag}}|{{.Size}}"}, function(out, err)
    sec.data = {}
    if out then
      for line in out:gmatch("[^\r\n]+") do
        local parts = split(line, "|")
        if #parts >= 4 then
          table.insert(sec.data, { id = parts[1], repo = parts[2], tag = parts[3], size = parts[4] })
        end
      end
    end
    sec.loading = false
    core.redraw = true
  end)
end

function PodmanView:refresh_k8s()
  local sec = nil
  for _, s in ipairs(self.sections) do if s.id == "k8s" then sec = s; break end end
  if not sec then return end
  sec.loading = true
  core.redraw = true
  async_exec({KUBECTL_EXE, "get", "pods", "-A", "--no-headers"}, function(out, err, rc)
    sec.data = {}
    if out and rc == 0 and not out:match("not found") and not out:match("error") then
      for line in out:gmatch("[^\r\n]+") do
        local ns, name, ready, status, restarts, age = line:match("(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if name then
          table.insert(sec.data, { ns = ns, name = name, status = status })
        end
      end
    end
    sec.loading = false
    core.redraw = true
  end)
end

function PodmanView:refresh_k3s()
  local sec = nil
  for _, s in ipairs(self.sections) do if s.id == "k3s" then sec = s; break end end
  if not sec then return end
  sec.loading = true
  core.redraw = true
  async_exec({K3S_EXE, "kubectl", "get", "pods", "-A", "--no-headers"}, function(out, err, rc)
    sec.data = {}
    if out and rc == 0 and not out:match("not found") and not out:match("error") then
      for line in out:gmatch("[^\r\n]+") do
        local ns, name, ready, status, restarts, age = line:match("(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if name then
          table.insert(sec.data, { ns = ns, name = name, status = status })
        end
      end
    end
    sec.loading = false
    core.redraw = true
  end)
end

function PodmanView:update()
  PodmanView.super.update(self)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "x", dest, nil, "podman_view")
end

local function draw_icon_btn(self, icon, bx, by, color, action_fn, tooltip)
  local bw = style.icon_font:get_width(icon) + 10 * SCALE
  local bh = style.icon_font:get_height()
  table.insert(self.buttons, { x = bx, y = by, w = bw, h = bh, action = action_fn })
  
  local hovered = false
  if self.mouse_x and self.mouse_y then
    if self.mouse_x >= bx and self.mouse_x <= bx + bw and self.mouse_y >= by and self.mouse_y <= by + bh then
      hovered = true
      self.hovered_btn = true
    end
  end
  
  local c = hovered and style.text or color
  renderer.draw_text(style.icon_font, icon, bx + 5 * SCALE, by, c)
  return bx + bw
end

function PodmanView:draw()
  self:draw_background(style.background2)
  local x, y = self.position.x, self.position.y - self.scroll.y
  local w, h = self.size.x, self.size.y
  
  self.buttons = {}
  self.hovered_btn = false
  
  -- Header
  renderer.draw_text(style.font, "Podman Manager", x + 10 * SCALE, y + 10 * SCALE, style.accent)
  local h_refresh = y + 10 * SCALE
  draw_icon_btn(self, "\u{f021}", x + w - 30 * SCALE, h_refresh, style.text, function() self:refresh_all() end, "Refresh All")
  
  y = y + 40 * SCALE
  
  for _, sec in ipairs(self.sections) do
    -- Section Header
    local chevron = sec.expanded and "\u{f078}" or "\u{f054}"
    local sec_hovered = (self.mouse_y and self.mouse_y >= y and self.mouse_y < y + 25 * SCALE)
    if sec_hovered then renderer.draw_rect(x, y, w, 25 * SCALE, style.line_highlight) end
    
    renderer.draw_text(style.icon_font, chevron, x + 10 * SCALE, y + 5 * SCALE, style.text)
    renderer.draw_text(style.font, sec.name, x + 30 * SCALE, y + 5 * SCALE, style.text)
    
    if sec.loading then
      renderer.draw_text(style.font, "...", x + w - 30 * SCALE, y + 5 * SCALE, style.dim)
    else
      renderer.draw_text(style.font, tostring(#sec.data), x + w - 30 * SCALE, y + 5 * SCALE, style.dim)
    end
    
    table.insert(self.buttons, { x = x, y = y, w = w, h = 25 * SCALE, action = function() sec.expanded = not sec.expanded; core.redraw = true end })
    y = y + 25 * SCALE
    
    -- Items
    if sec.expanded then
      if #sec.data == 0 and not sec.loading then
        renderer.draw_text(style.font, "No items found", x + 30 * SCALE, y + 5 * SCALE, style.dim)
        y = y + 25 * SCALE
      end
      
      for _, item in ipairs(sec.data) do
        local item_hovered = (self.mouse_y and self.mouse_y >= y and self.mouse_y < y + 30 * SCALE)
        if item_hovered then renderer.draw_rect(x, y, w, 30 * SCALE, style.line_highlight) end
        
        if sec.id == "compose" then
          renderer.draw_text(style.icon_font, "\u{f490}", x + 20 * SCALE, y + 5 * SCALE, style.accent)
          renderer.draw_text(style.font, (item.name or "Unknown"), x + 40 * SCALE, y + 5 * SCALE, style.text)
          
          if item_hovered then
            local bx = x + w - 110 * SCALE
            -- Logs
            bx = draw_icon_btn(self, "\u{f15c}", bx, y + 5 * SCALE, style.dim, function()
              command.perform("terminal:toggle")
              core.add_thread(function()
                while not core.active_view.add_session do coroutine.yield(0.1) end
                core.active_view:add_session({ name = "Compose Logs", cmd = {"podman-compose", "logs", "-f"}, prompt_prefix = "" })
              end)
            end)
            -- Down
            bx = draw_icon_btn(self, "\u{f04d}", bx, y + 5 * SCALE, style.dim, function() async_exec("podman-compose down", function() self:refresh_all() end) end)
            -- Up
            bx = draw_icon_btn(self, "\u{f04b}", bx, y + 5 * SCALE, style.dim, function() async_exec("podman-compose up -d", function() self:refresh_all() end) end)
          end
          
        elseif sec.id == "containers" then
          local c_col = (item.status or ""):match("Up") and PODMAN_COLORS.up or PODMAN_COLORS.exited
          renderer.draw_text(style.icon_font, "\u{f1b2}", x + 20 * SCALE, y + 5 * SCALE, c_col)
          local nx = renderer.draw_text(style.font, (item.name or "Unknown"), x + 40 * SCALE, y + 5 * SCALE, style.text)
          if item.ports and item.ports ~= "" then
            renderer.draw_text(style.font, "  [" .. item.ports .. "]", nx, y + 5 * SCALE, style.dim)
          end
          
          if item_hovered then
            local bx = x + w - 160 * SCALE
            -- Logs
            bx = draw_icon_btn(self, "\u{f15c}", bx, y + 5 * SCALE, style.dim, function()
              command.perform("terminal:toggle")
              core.add_thread(function()
                while not core.active_view.add_session do coroutine.yield(0.1) end
                core.active_view:add_session({ name = (item.name or "Unknown"), cmd = {PODMAN_EXE, "logs", "-f", item.id}, prompt_prefix = "" })
              end)
            end)
            -- Exec terminal
            bx = draw_icon_btn(self, "\u{f120}", bx, y + 5 * SCALE, style.dim, function()
              command.perform("terminal:toggle")
              core.add_thread(function()
                while not core.active_view.add_session do coroutine.yield(0.1) end
                core.active_view:add_session({ name = (item.name or "Unknown"), cmd = {PODMAN_EXE, "exec", "-it", item.id, "sh"}, prompt_prefix = "" })
              end)
            end)
            -- Restart
            bx = draw_icon_btn(self, "\u{f01e}", bx, y + 5 * SCALE, style.dim, function() async_exec({PODMAN_EXE, "restart", item.id}, function() self:refresh_containers() end) end)
            -- Stop/Start
            if (item.status or ""):match("Up") then
              bx = draw_icon_btn(self, "\u{f04d}", bx, y + 5 * SCALE, style.dim, function() async_exec({PODMAN_EXE, "stop", item.id}, function() self:refresh_containers() end) end)
            else
              bx = draw_icon_btn(self, "\u{f04b}", bx, y + 5 * SCALE, style.dim, function() async_exec({PODMAN_EXE, "start", item.id}, function() self:refresh_containers() end) end)
            end
            -- Trash
            draw_icon_btn(self, "\u{f1f8}", bx, y + 5 * SCALE, style.dim, function() async_exec({PODMAN_EXE, "rm", "-f", item.id}, function() self:refresh_containers() end) end)
          end
          
        elseif sec.id == "images" then
          renderer.draw_text(style.icon_font, "\u{f490}", x + 20 * SCALE, y + 5 * SCALE, style.dim)
          renderer.draw_text(style.font, item.repo .. ":" .. item.tag, x + 40 * SCALE, y + 5 * SCALE, style.text)
          
          if item_hovered then
            local bx = x + w - 30 * SCALE
            draw_icon_btn(self, "\u{f1f8}", bx, y + 5 * SCALE, style.dim, function() async_exec({PODMAN_EXE, "rmi", "-f", item.id}, function() self:refresh_images() end) end)
          end
          
        elseif sec.id == "k8s" or sec.id == "k3s" then
          local is_running = item.status == "Running"
          renderer.draw_text(style.icon_font, "\u{fd31}", x + 20 * SCALE, y + 5 * SCALE, is_running and PODMAN_COLORS.up or PODMAN_COLORS.exited)
          renderer.draw_text(style.font, (item.name or "Unknown"), x + 40 * SCALE, y + 5 * SCALE, style.text)
          
          if item_hovered then
            local bx = x + w - 110 * SCALE
            local cmd_prefix = sec.id == "k3s" and "k3s kubectl" or "kubectl"
            -- Exec
            bx = draw_icon_btn(self, "\u{f120}", bx, y + 5 * SCALE, style.dim, function()
              command.perform("terminal:toggle")
              core.add_thread(function()
                while not core.active_view.add_session do coroutine.yield(0.1) end
                local cmd_parts = {}
                for w in cmd_prefix:gmatch("%S+") do table.insert(cmd_parts, w) end
                table.insert(cmd_parts, "exec"); table.insert(cmd_parts, "-it"); table.insert(cmd_parts, item.name)
                table.insert(cmd_parts, "-n"); table.insert(cmd_parts, item.ns); table.insert(cmd_parts, "--"); table.insert(cmd_parts, "sh")
                core.active_view:add_session({ name = (item.name or "Unknown"), cmd = cmd_parts, prompt_prefix = "" })
              end)
            end)
            -- Logs
            bx = draw_icon_btn(self, "\u{f15c}", bx, y + 5 * SCALE, style.dim, function()
              command.perform("terminal:toggle")
              core.add_thread(function()
                while not core.active_view.add_session do coroutine.yield(0.1) end
                local cmd_parts = {}
                for w in cmd_prefix:gmatch("%S+") do table.insert(cmd_parts, w) end
                table.insert(cmd_parts, "logs")
                table.insert(cmd_parts, "-f")
                table.insert(cmd_parts, item.name)
                table.insert(cmd_parts, "-n")
                table.insert(cmd_parts, item.ns)
                core.active_view:add_session({ name = (item.name or "Unknown"), cmd = cmd_parts, prompt_prefix = "" })
              end)
            end)
            -- Trash
            draw_icon_btn(self, "\u{f1f8}", bx, y + 5 * SCALE, style.dim, function() 
              local del_cmd = sec.id == "k3s" and {K3S_EXE, "kubectl", "delete", "pod", item.name, "-n", item.ns} or {KUBECTL_EXE, "delete", "pod", item.name, "-n", item.ns}
              async_exec(del_cmd, function()
                if sec.id == "k3s" then self:refresh_k3s() else self:refresh_k8s() end
              end) 
            end)
          end
        end
        
        y = y + 30 * SCALE
      end
    end
  end
end

function PodmanView:on_mouse_moved(x, y, dx, dy)
  self.mouse_x = x
  self.mouse_y = y
  core.redraw = true
  if self.hovered_btn then
    system.set_cursor("hand")
  else
    system.set_cursor("arrow")
  end
end

function PodmanView:on_mouse_left()
  self.mouse_x = nil
  self.mouse_y = nil
  system.set_cursor("arrow")
  core.redraw = true
end

function PodmanView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    for i = #self.buttons, 1, -1 do
      local r = self.buttons[i]
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        r.action()
        return true
      end
    end
  end
  return PodmanView.super.on_mouse_pressed(self, button, x, y, clicks)
end

local podman_view = nil

command.add(nil, {
  ["podman:toggle"] = function()
    local sidebar = _G.get_sidebar_node and _G.get_sidebar_node()
    if podman_view and core.root_view.root_node:get_node_for_view(podman_view) then
      local node = core.root_view.root_node:get_node_for_view(podman_view)
      if sidebar and node == sidebar and node.active_view ~= podman_view then
        node:set_active_view(podman_view)
      else
        node:close_view(core.root_view.root_node, podman_view)
        podman_view = nil
      end
    else
      podman_view = PodmanView()
      local node = sidebar or core.root_view:get_active_node_default():split("right")
      node:add_view(podman_view)
      if sidebar then node:set_active_view(podman_view) end
      podman_view.visible = true
    end
  end
})


-- Hook into core.quit to stop all podman containers when lite-xl closes, as requested
local old_quit = core.quit
function core.quit(force)
  pcall(function()
    if PLATFORM == "Windows" or PLATFORM == "Mac OS X" then
      -- Completely shut down the Podman VM to free up all resources
      process.start({PODMAN_EXE, "machine", "stop"})
    else
      -- On Linux podman is daemonless, so just stop all containers instantly
      process.start({PODMAN_EXE, "stop", "-a", "-t", "0"})
    end
  end)
  return old_quit(force)
end
