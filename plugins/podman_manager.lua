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
      local function file_log(msg)
        local f = io.open("C:\\Users\\ojasw\\Desktop\\podman_debug.txt", "a")
        if f then f:write(tostring(msg) .. "\n"); f:close() end
      end
      
      file_log("Podman executing: " .. tostring(cmd_str))
      local p, err = process.start({"cmd.exe", "/c", cmd_str}, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
      if p then
        local out = ""
        local err_str = ""
        while true do
          local chunk = p:read_stdout(4096)
          local err_chunk = p.read_stderr and p:read_stderr(4096) or ""
          local has_data = false
          if chunk and #chunk > 0 then
            out = out .. chunk
            has_data = true
          end
          if err_chunk and #err_chunk > 0 then
            err_str = err_str .. err_chunk
            has_data = true
          end
          if not has_data then
            if not p:running() then
              break
            else
              coroutine.yield(0.01)
            end
          end
        end
        file_log("Podman success. Out len: " .. tostring(#out) .. " Err len: " .. tostring(#err_str))
        if #out < 200 then file_log("Output snippet: " .. out) end
        if #err_str > 0 then file_log("Err snippet: " .. err_str) end
        if on_result then on_result(out, err_str, 0) end
      else
        file_log("Podman failed to start: " .. tostring(err))
        if on_result then on_result(nil, "Failed to start process: " .. tostring(err)) end
      end
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
    { id = "local_pods", name = "Local Pods (YAML)", expanded = false, data = {}, loading = false },
    { id = "local_deployments", name = "Local Deployments (YAML)", expanded = false, data = {}, loading = false },
  }
  
  self.hovered_item = nil
  self.hovered_btn = nil
  self.buttons = {} -- stores click rects for the current frame
  
  self:refresh_all()
end

function PodmanView:get_name() return self.name end

local function scan_k8s_files(dir, pods, deployments, is_root)
  local files = system.list_dir(dir)
  if not files then return end
  for _, f in ipairs(files) do
    if f:sub(1,1) == "." then goto continue end
    local path = dir .. PATHSEP .. f
    local info = system.get_file_info(path)
    if info and info.type == "dir" then
      if is_root and (f == "pods" or f == "deployments" or f == "k8s" or f == "kubernetes" or f == "manifests") then
        scan_k8s_files(path, pods, deployments, false)
      elseif not is_root then
        scan_k8s_files(path, pods, deployments, false)
      end
    elseif info and info.type == "file" and f:match("%.ya?ml$") then
      local file = io.open(path, "r")
      if file then
        local content = file:read(4096)
        file:close()
        if content then
          if content:match("kind:%s*Pod") then
            local name = content:match("name:%s*([^\r\n]+)") or f
            table.insert(pods, { file = path, name = name, short = f })
          elseif content:match("kind:%s*Deployment") then
            local name = content:match("name:%s*([^\r\n]+)") or f
            table.insert(deployments, { file = path, name = name, short = f })
          end
        end
      end
    end
    ::continue::
  end
end

function PodmanView:refresh_local_k8s()
  local pods_sec, deps_sec = nil, nil
  for _, s in ipairs(self.sections) do
    if s.id == "local_pods" then pods_sec = s end
    if s.id == "local_deployments" then deps_sec = s end
  end
  if not pods_sec or not deps_sec then return end
  
  pods_sec.loading = true
  deps_sec.loading = true
  core.redraw = true
  
  local proj_dir = core.project_dir or (core.project_directories and core.project_directories[1] and core.project_directories[1].name) or system.absolute_path(".") or ""
  local pods, deployments = {}, {}
  scan_k8s_files(proj_dir, pods, deployments, true)
  
  pods_sec.data = pods
  deps_sec.data = deployments
  
  pods_sec.loading = false
  deps_sec.loading = false
  core.redraw = true
end

function PodmanView:refresh_all()
  self:refresh_containers()
  self:refresh_images()
  self:refresh_k8s()
  self:refresh_local_k8s()
  self:refresh_compose()
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
      out = out:gsub('"', '')
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
      out = out:gsub('"', '')
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

function PodmanView:update()
  PodmanView.super.update(self)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "x", dest, nil, "podman_view")
end

function PodmanView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = math.max(300 * SCALE, value)
  end
end

local function draw_icon_btn(self, icon, bx, by, color, action_fn, tooltip, visible)
  local bw = style.icon_font:get_width(icon) + 16 * SCALE
  local btn_y = by - 5 * SCALE
  local btn_h = 30 * SCALE
  table.insert(self.buttons, { x = bx, y = btn_y, w = bw, h = btn_h, action = action_fn })
  
  if visible ~= false then
    local hovered = false
    if self.mouse_x and self.mouse_y then
      local in_bounds = self.mouse_x >= self.position.x and self.mouse_x <= self.position.x + self.size.x and
                        self.mouse_y >= self.position.y and self.mouse_y <= self.position.y + self.size.y
      if in_bounds and self.mouse_x >= bx and self.mouse_x <= bx + bw and self.mouse_y >= btn_y and self.mouse_y <= btn_y + btn_h then
        hovered = true
        self.hovered_btn = true
      end
    end

    renderer.draw_text(style.icon_font, icon, bx + 8 * SCALE, btn_y + 5 * SCALE, hovered and style.text or color)
  end
  return bx + bw
end

function PodmanView:draw()
  self:draw_background(style.background2)
  local x, y = self.position.x, self.position.y - self.scroll.y
  local w, h = self.size.x, self.size.y
  
  local in_bounds = self.mouse_x and self.mouse_y and 
                    self.mouse_x >= self.position.x and self.mouse_x <= self.position.x + self.size.x and
                    self.mouse_y >= self.position.y and self.mouse_y <= self.position.y + self.size.y

  self.buttons = {}
  self.hovered_btn = false
  
  -- Header
  renderer.draw_text(style.font, "Podman Manager", x + 10 * SCALE, y + 10 * SCALE, style.accent)
  local h_refresh = y + 10 * SCALE
  draw_icon_btn(self, "\u{f021}", x + w - 50 * SCALE, h_refresh, style.text, function() self:refresh_all() end, "Refresh All")
  
  y = y + 40 * SCALE
  
  for _, sec in ipairs(self.sections) do
    -- Section Header
    local chevron = sec.expanded and "\u{f078}" or "\u{f054}"
    local sec_hovered = (in_bounds and self.mouse_y >= y and self.mouse_y < y + 25 * SCALE)
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
        if sec.id == "k8s" then
          local btn_txt = "Setup Cluster"
          local tw = style.font:get_width(btn_txt)
          local bx = x + w - tw - 30 * SCALE
          local by = y + 5 * SCALE
          local hovered = (self.mouse_x and self.mouse_x >= bx and self.mouse_x <= bx + tw and self.mouse_y >= by and self.mouse_y <= by + 20 * SCALE)
          renderer.draw_text(style.font, btn_txt, bx, by, hovered and style.accent or style.text)
          table.insert(self.buttons, { x = bx, y = by, w = tw, h = 20 * SCALE, action = function()
            if sec.id == "k8s" then
              local cmd
              if PLATFORM == "Windows" then
                cmd = { "powershell", "-NoProfile", "-Command", "$env:KIND_EXPERIMENTAL_PROVIDER='podman'; kind create cluster" }
              else
                cmd = { "sh", "-c", "KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster" }
              end
              async_exec(cmd, function() self:refresh_k8s() end)
            end
          end })
        end
        y = y + 25 * SCALE
      end
      
      for _, item in ipairs(sec.data) do
        local item_hovered = (in_bounds and self.mouse_y >= y and self.mouse_y < y + 30 * SCALE)
        if item_hovered then renderer.draw_rect(x, y, w, 30 * SCALE, style.line_highlight) end
        
        if sec.id == "compose" then
          renderer.draw_text(style.icon_font, "\u{f490}", x + 20 * SCALE, y + 5 * SCALE, style.accent)
          core.push_clip_rect(x, y, w - 170 * SCALE, 30 * SCALE)
            renderer.draw_text(style.font, (item.name or "Unknown"), x + 40 * SCALE, y + 5 * SCALE, style.text)
            core.pop_clip_rect()
          
          if item_hovered then
            local bx = x + w - 110 * SCALE
            -- Logs
            bx = draw_icon_btn(self, "\u{f15c}", bx, y + 5 * SCALE, style.dim, function()
              
                local toggle_term = require("plugins.toggle_terminal")
                local term = type(toggle_term) == "table" and toggle_term.get_instance() or nil
                if not term then 
                  command.perform("terminal:toggle")
                  term = type(toggle_term) == "table" and toggle_term.get_instance() or nil
                end
                if term and not term.visible then command.perform("terminal:toggle") end
                if term then
                  core.set_active_view(term)
                term:add_session({ name = "Compose Logs", prompt_prefix = "" })
                term:run("podman-compose logs -f")
                end

            end)
            -- Down
            bx = draw_icon_btn(self, "\u{f04d}", bx, y + 5 * SCALE, style.dim, function() async_exec("podman-compose down", function() self:refresh_all() end) end)
            -- Up
            bx = draw_icon_btn(self, "\u{f04b}", bx, y + 5 * SCALE, style.dim, function() async_exec("podman-compose up -d", function() self:refresh_all() end) end)
          end
          
        elseif sec.id == "containers" then
          local c_col = (item.status or ""):match("Up") and PODMAN_COLORS.up or PODMAN_COLORS.exited
          renderer.draw_text(style.icon_font, "\u{f1b2}", x + 20 * SCALE, y + 5 * SCALE, c_col)
          core.push_clip_rect(x, y, w - 170 * SCALE, 30 * SCALE)
            local nx = renderer.draw_text(style.font, (item.name or "Unknown"), x + 40 * SCALE, y + 5 * SCALE, style.text)
            core.pop_clip_rect()
          if item.ports and item.ports ~= "" then
            renderer.draw_text(style.font, "  [" .. item.ports .. "]", nx, y + 5 * SCALE, style.dim)
          end
          local item_hovered = (in_bounds and self.mouse_y >= y and self.mouse_y < y + 30 * SCALE)
          local bx = x + w - 160 * SCALE
          
          -- Logs
          bx = draw_icon_btn(self, "\u{f15c}", bx, y + 5 * SCALE, style.dim, function()
            local toggle_term = require("plugins.toggle_terminal")
            local term = type(toggle_term) == "table" and toggle_term.get_instance() or nil
            if not term then 
              command.perform("terminal:toggle")
              term = type(toggle_term) == "table" and toggle_term.get_instance() or nil
            end
            if term and not term.visible then command.perform("terminal:toggle") end
            if term then
              core.set_active_view(term)
              term:add_session({ name = (item.name or "Unknown"), prompt_prefix = "", is_remote_tty = true })
              term:run(PODMAN_EXE .. " logs -f " .. item.id)
            end
          end, "Logs", item_hovered)

          -- Exec terminal
          bx = draw_icon_btn(self, "\u{f120}", bx, y + 5 * SCALE, style.dim, function()
            local toggle_term = require("plugins.toggle_terminal")
            local term = type(toggle_term) == "table" and toggle_term.get_instance() or nil
            if not term then 
              command.perform("terminal:toggle")
              term = type(toggle_term) == "table" and toggle_term.get_instance() or nil
            end
            if term and not term.visible then command.perform("terminal:toggle") end
            if term then
              core.set_active_view(term)
              term:add_session({ name = (item.name or "Unknown"), prompt_prefix = "", is_remote_tty = true })
              term:run(PODMAN_EXE .. " exec -it " .. item.id .. " /bin/bash")
            end
          end, "Exec", item_hovered)

          -- Restart
          bx = draw_icon_btn(self, "\u{f01e}", bx, y + 5 * SCALE, style.dim, function() async_exec({PODMAN_EXE, "restart", item.id}, function() self:refresh_containers() end) end, "Restart", item_hovered)

          -- Stop/Start
          if (item.status or ""):match("Up") then
            bx = draw_icon_btn(self, "\u{f04d}", bx, y + 5 * SCALE, style.dim, function() async_exec({PODMAN_EXE, "stop", item.id}, function() self:refresh_containers() end) end, "Stop", item_hovered)
          else
            bx = draw_icon_btn(self, "\u{f04b}", bx, y + 5 * SCALE, style.dim, function() async_exec({PODMAN_EXE, "start", item.id}, function() self:refresh_containers() end) end, "Start", item_hovered)
          end

          -- Trash
          draw_icon_btn(self, "\u{f1f8}", bx, y + 5 * SCALE, style.dim, function() async_exec({PODMAN_EXE, "rm", "-f", item.id}, function() self:refresh_containers() end) end, "Delete", item_hovered)
          
        elseif sec.id == "images" then
          renderer.draw_text(style.icon_font, "\u{f490}", x + 20 * SCALE, y + 5 * SCALE, style.dim)
          core.push_clip_rect(x, y, w - 100 * SCALE, 30 * SCALE)
            local nx = renderer.draw_text(style.font, (item.repo or "Unknown") .. ":" .. (item.tag or "latest"), x + 40 * SCALE, y + 5 * SCALE, style.text)
            renderer.draw_text(style.font, item.size or "", nx + 10 * SCALE, y + 5 * SCALE, style.dim)
          core.pop_clip_rect()

          local item_hovered = (in_bounds and self.mouse_y >= y and self.mouse_y < y + 30 * SCALE)
          local bx = x + w - 30 * SCALE
          draw_icon_btn(self, "\u{f1f8}", bx, y + 5 * SCALE, style.dim, function() async_exec({PODMAN_EXE, "rmi", "-f", item.id}, function() self:refresh_images() end) end, "Delete", item_hovered)
          
        elseif sec.id == "k8s" then
          local c_col = (item.status or ""):match("Running") and PODMAN_COLORS.up or PODMAN_COLORS.exited
          renderer.draw_text(style.icon_font, "\u{f1b3}", x + 20 * SCALE, y + 5 * SCALE, c_col)
          core.push_clip_rect(x, y, w - 150 * SCALE, 30 * SCALE)
            renderer.draw_text(style.font, (item.name or "Unknown"), x + 40 * SCALE, y + 5 * SCALE, style.text)
          core.pop_clip_rect()
          
          local item_hovered = (in_bounds and self.mouse_y >= y and self.mouse_y < y + 30 * SCALE)
          local bx = x + w - 90 * SCALE
          
          -- Exec
          bx = draw_icon_btn(self, "\u{f120}", bx, y + 5 * SCALE, style.dim, function()
            local toggle_term = require("plugins.toggle_terminal")
            local term = type(toggle_term) == "table" and toggle_term.get_instance() or nil
            if not term then command.perform("terminal:toggle"); term = type(toggle_term) == "table" and toggle_term.get_instance() or nil end
            if term and not term.visible then command.perform("terminal:toggle") end
            if term then
              core.set_active_view(term)
              local cmd_prefix = PLATFORM == "Windows" and "kubectl" or KUBECTL_EXE
              local cmd_parts = {}
              for w in cmd_prefix:gmatch("%S+") do table.insert(cmd_parts, w) end
              table.insert(cmd_parts, "exec"); table.insert(cmd_parts, "-it"); table.insert(cmd_parts, item.name)
              table.insert(cmd_parts, "-n"); table.insert(cmd_parts, item.ns); table.insert(cmd_parts, "--"); table.insert(cmd_parts, "/bin/bash")
              term:add_session({ name = (item.name or "Unknown"), prompt_prefix = "", is_remote_tty = true })
              term:run(table.concat(cmd_parts, " "))
            end
          end, "Exec", item_hovered)

          -- Logs
          bx = draw_icon_btn(self, "\u{f15c}", bx, y + 5 * SCALE, style.dim, function()
            local toggle_term = require("plugins.toggle_terminal")
            local term = type(toggle_term) == "table" and toggle_term.get_instance() or nil
            if not term then 
              command.perform("terminal:toggle")
              term = type(toggle_term) == "table" and toggle_term.get_instance() or nil
            end
            if term and not term.visible then command.perform("terminal:toggle") end
            if term then
              core.set_active_view(term)
              local cmd_prefix = PLATFORM == "Windows" and "kubectl" or KUBECTL_EXE
              term:add_session({ name = (item.name or "Unknown"), prompt_prefix = "", is_remote_tty = true })
              term:run(cmd_prefix .. " logs -f " .. item.name .. " -n " .. item.ns)
            end
          end, "Logs", item_hovered)

          -- Delete
          draw_icon_btn(self, "\u{f1f8}", bx, y + 5 * SCALE, style.dim, function() 
            local del_cmd = {KUBECTL_EXE, "delete", "pod", item.name, "-n", item.ns}
            async_exec(del_cmd, function()
              self:refresh_k8s()
            end) 
          end, "Delete", item_hovered)
        elseif sec.id == "local_pods" or sec.id == "local_deployments" then
          renderer.draw_text(style.icon_font, "\u{f15b}", x + 20 * SCALE, y + 5 * SCALE, style.dim)
          core.push_clip_rect(x, y, w - 110 * SCALE, 30 * SCALE)
            renderer.draw_text(style.font, item.short or "Unknown", x + 40 * SCALE, y + 5 * SCALE, style.text)
          core.pop_clip_rect()
          
          local item_hovered = (in_bounds and self.mouse_y >= y and self.mouse_y < y + 30 * SCALE)
          local bx = x + w - 70 * SCALE
          
          -- Apply
          bx = draw_icon_btn(self, "\u{f04b}", bx, y + 5 * SCALE, style.dim, function()
            async_exec({KUBECTL_EXE, "apply", "-f", item.file}, function()
              self:refresh_k8s()
            end)
          end, "Apply (kubectl apply -f)", item_hovered)
          
          -- Delete
          draw_icon_btn(self, "\u{f1f8}", bx, y + 5 * SCALE, style.dim, function() 
            async_exec({KUBECTL_EXE, "delete", "-f", item.file}, function()
              self:refresh_k8s()
            end) 
          end, "Delete (kubectl delete -f)", item_hovered)
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

if PLATFORM == "Windows" then
  core.add_thread(function()
    while true do
      coroutine.yield(30) -- Check every 30 seconds
      local p = process.start({"wsl", "-d", "podman-machine-default", "--exec", "free", "-m"}, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
      if p then
        local out = ""
        while true do
          local chunk = p:read_stdout(4096)
          if chunk and #chunk > 0 then
            out = out .. chunk
          elseif not p:running() then
            break
          else
            coroutine.yield(0.1)
          end
        end
        out = out .. (p:read_stdout() or "")
        
        local mem_total, mem_used, mem_free, mem_shared, mem_buff, mem_avail = out:match("Mem:%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
        if mem_avail and mem_total then
          local avail = tonumber(mem_avail)
          local total = tonumber(mem_total)
          if avail and total and (avail / total) < 0.10 then
            if not _G.podman_resource_warned then
              _G.podman_resource_warned = true
              
              local function update_wsl_mem(new_mem)
                local f = io.open("C:\\Users\\ojasw\\.wslconfig", "r")
                local content = f and f:read("*a") or ""
                if f then f:close() end
                content = content:gsub("memory=%d+GB", "memory=" .. new_mem)
                local fw = io.open("C:\\Users\\ojasw\\.wslconfig", "w")
                if fw then 
                  fw:write(content)
                  fw:close() 
                end
                core.log("Applying " .. new_mem .. " limit and restarting WSL...")
                process.start({"wsl", "--shutdown"})
                _G.podman_resource_warned = false
              end

              core.command_view:enter("Podman memory critically low! (" .. avail .. "MB left) Increase limit?", {
                submit = function(text, item)
                  if item.action then item.action() end
                end,
                suggest = function(text)
                  return {
                    { text = "Increase to 4GB and Restart", action = function() update_wsl_mem("4GB") end },
                    { text = "Increase to 5GB and Restart", action = function() update_wsl_mem("5GB") end },
                    { text = "Ignore for now", action = function() _G.podman_resource_warned = false end }
                  }
                end
              })
            end
          end
        end
      end
    end
  end)
end

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



