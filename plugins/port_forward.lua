-- mod-version:3
-- Plugin: port_forward
-- Overview: Provides a UI to manage and monitor local and remote port forwarding rules directly from the editor.
-- It allows developers to spawn background SSH tunnels or similar port-forwarding processes and easily start or stop them.

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
-- renderer is a global in Lite XL

-- Safely require process API which could be a global or module depending on the Lite XL build
local has_process, process_module = pcall(require, "process")
local process = has_process and process_module or _G.process

local forwards = {}

local config_path = USERDIR .. "/plugins/tunnel_monitor/rules.lua"

local function save_rules()
  local f = io.open(config_path, "w")
  if not f then return end
  f:write("return {\n")
  for _, fw in ipairs(forwards) do
    f:write(string.format("  { name = %q, cmd = %q, target_port = %s, proxy_port = %s, auto_restart = %s },\n", 
      fw.name, fw.cmd, fw.target_port or "nil", fw.proxy_port or "nil", tostring(fw.auto_restart)))
  end
  f:write("}\n")
  f:close()
end

local function load_rules()
  local f = io.open(config_path, "r")
  if not f then return end
  f:close()
  local ok, data = pcall(dofile, config_path)
  if ok and type(data) == "table" then
    forwards = {}
    for _, item in ipairs(data) do
      table.insert(forwards, {
        name = item.name,
        cmd = item.cmd,
        output = "Press Enter/Double-click to start.\n",
        proc = nil,
        url_printed = false,
        target_port = item.target_port,
        proxy_port = item.proxy_port,
        auto_restart = item.auto_restart
      })
    end
  end
end

-- Load rules on init
load_rules()

-- Helper to safely parse command strings respecting quotes
local function parse_cmd(cmd_str)
  local args = {}
  local in_quote = false
  local curr = {}
  for i = 1, #cmd_str do
    local c = cmd_str:sub(i, i)
    if (c == '"' or c == "'") then
      if in_quote == c then
        in_quote = false
      elseif not in_quote then
        in_quote = c
      else
        table.insert(curr, c)
      end
    elseif c:match("%s") and not in_quote then
      if #curr > 0 then
        table.insert(args, table.concat(curr))
        curr = {}
      end
    else
      table.insert(curr, c)
    end
  end
  if #curr > 0 then table.insert(args, table.concat(curr)) end
  return args
end

local function start_forward(idx)
  local fw = forwards[idx]
  if not fw then return end
  if fw.proc then return end
  
  if not process then
    core.error("port_forward: 'process' API is not available in this Lite XL build.")
    return
  end
  
  local args = parse_cmd(fw.cmd)
  if #args == 0 then return end
  
  if fw.target_port and fw.proxy_port then
     if fw.proxy_proc then
       pcall(function()
         if fw.proxy_proc.terminate then fw.proxy_proc:terminate()
         elseif fw.proxy_proc.kill then fw.proxy_proc:kill() end
       end)
     end
     local exe_ext = (PLATFORM == "Windows") and ".exe" or ""
     if not fw.auth_pin then
       fw.auth_pin = string.format("%04d", math.random(1000, 9999))
     end
     local go_cmd = string.format('"%s/plugins/tunnel_monitor/proxy%s" %s %s %s', USERDIR, exe_ext, fw.proxy_port, fw.target_port, fw.auth_pin)
     local go_args = parse_cmd(go_cmd)
     pcall(function() fw.proxy_proc = process.start(go_args) end)
  end

  local ok, proc = pcall(function() return process.start(args) end)
  if ok and proc then
    fw.proc = proc
    fw.start_time = os.time()
    fw.raw_output = ""
    fw.health_check_scheduled = true
    fw.health_check_time = os.time() + 5
    if not fw.initial_retries then fw.initial_retries = 0 end
    fw.output = "Started command: " .. fw.cmd .. "\n"
    core.log("Port forward '%s' started.", fw.name)
  else
    core.error("Failed to start port forward '%s': %s", fw.name, tostring(proc))
  end
end

local function stop_forward(idx)
  local fw = forwards[idx]
  if not fw or not fw.proc then return end
  pcall(function()
    if fw.proc.terminate then fw.proc:terminate()
    elseif fw.proc.kill then fw.proc:kill() end
  end)
  if fw.proxy_proc then
    pcall(function()
      if fw.proxy_proc.terminate then fw.proxy_proc:terminate()
      elseif fw.proxy_proc.kill then fw.proxy_proc:kill() end
    end)
    fw.proxy_proc = nil
  end
  fw.proc = nil
  fw.output = fw.output .. "Stopped.\n"
  core.log("Port forward '%s' stopped.", fw.name)
end

local PortForwardView = View:extend()

function PortForwardView:new()
  PortForwardView.super.new(self)
  self.scrollable = true
  self.selected_idx = 1
end

function PortForwardView:get_name()
  return "Port Forwards"
end

function PortForwardView:get_line_height()
  return style.font:get_height()
end

function PortForwardView:update()
  PortForwardView.super.update(self)
  local needs_redraw = false
  for idx, fw in ipairs(forwards) do
    if fw.proc then
      local ok, running = pcall(function() return fw.proc:running() end)
      
      -- Always try to read output first, so we don't miss final crash logs
      local out = ""
      pcall(function()
        if fw.proc.read_stdout then
          out = (fw.proc:read_stdout() or "") .. (fw.proc:read_stderr() or "")
        elseif fw.proc.read then
          out = fw.proc:read() or ""
        end
      end)
      if #out > 0 then 
        -- Strip ANSI escape sequences
        out = out:gsub("\27%[[%d;]*[a-zA-Z]", "")
        
        fw.raw_output = (fw.raw_output or "") .. out
        
        -- Fully strip the QR code block which causes '?' rendering due to Unicode block elements
        if fw.cmd:match("pinggy%.io") then
          -- Prepare a proper, perfectly clean UI for logs. We completely hide Pinggy's raw terminal output
          -- to guarantee no '?' artifacts from its interactive dashboard, and only show the finalized URL block.
          if out:match("Connection reset") or out:match("refused") or out:match("kex_exchange_identification") or out:match("Permission denied") then
            fw.output = fw.output .. out 
          end
          
          if not fw.url_printed then
            local url = nil
            for match in fw.raw_output:gmatch('https://([%w%-%.]+pinggy[%w%-%.]*)') do
              if not match:match("dashboard%.pinggy%.io") and not match:match("^pinggy%.io") then
                url = match
                break
              end
            end
            if url and url ~= "localhost" then
              local display_url = url
              if url:match("pinggy") then display_url = "lazy:lite@" .. url end
              if system.set_clipboard then system.set_clipboard("https://" .. display_url) end
              fw.output = fw.output .. "\n======================================================\n" ..
                          "[PUBLIC URL] https://" .. display_url .. "\n" ..
                          "[AUTH PIN]   " .. fw.auth_pin .. "\n" ..
                          "[NOTE] Pinggy free tier tunnels expire after 60 minutes.\n" ..
                          "(Automatically copied to clipboard!)\n" ..
                          "======================================================\n"
              fw.url_printed = true
              fw.restart_count = 0
            end
          end
        else
          if not fw.qr_started then
            fw.output = fw.output .. out
            local qr_idx = fw.output:find("Open your tunnel address")
            if qr_idx then
              fw.output = fw.output:sub(1, qr_idx - 1)
              fw.qr_started = true
            end
          end
          
          if fw.cmd:match("localhost%.run") and not fw.url_printed then
            local url = fw.raw_output:match('https://([%w%-%.]+%.lhr%.life)')
                or fw.raw_output:match('https://([%w%-%.]+%.localhost%.run)')
                or fw.raw_output:match('https://([%w%-%.]+%.lhr%.rocks)')
            if url and url ~= "localhost" then
              if system.set_clipboard then system.set_clipboard("https://" .. url) end
              fw.output = fw.output .. "\n======================================================\n[PUBLIC URL] https://" .. url .. "\n[AUTH PIN]   " .. fw.auth_pin .. "\n(Automatically copied to clipboard!)\n======================================================\n"
              fw.url_printed = true
              fw.restart_count = 0
            end
          end
        end
        
        needs_redraw = true
        if #fw.output > 5000 then
          fw.output = fw.output:sub(-5000)
          fw.output = fw.output:match("[^\n]*\n(.*)") or fw.output
        end
      end

      if running and fw.health_check_scheduled and os.time() >= fw.health_check_time then
        fw.health_check_scheduled = false
        if fw.proxy_port then
          local null_file = (PLATFORM == "Windows") and "NUL" or "/dev/null"
          local test_cmd = string.format('curl -s -o %s -w "%%{http_code}" http://localhost:%s', null_file, fw.proxy_port)
          local handle = io.popen(test_cmd)
          if handle then
            local result = handle:read("*a")
            handle:close()
            if result:match("^000") then
              fw.output = fw.output .. "Warning: Tunnel may not be forwarding traffic yet. Try refreshing in 10 seconds.\n"
              needs_redraw = true
            end
          end
        end
      end

      -- EC6: Force reconnect after 1 hour to prevent pinggy domain rotation staleness
      if running and fw.auto_restart and fw.start_time and os.time() - fw.start_time > 3600 then
        fw.output = fw.output .. "Tunnel reached 60-minute free tier limit, forcing reconnect...\n"
        if fw.proxy_proc then
          pcall(function()
            if fw.proxy_proc.terminate then fw.proxy_proc:terminate()
            elseif fw.proxy_proc.kill then fw.proxy_proc:kill() end
          end)
          fw.proxy_proc = nil
        end
        stop_forward(idx)
        running = false
        ok = true
      end

      if ok and not running then
        fw.proc = nil
        fw.start_time = nil
        fw.url_printed = false
        fw.raw_output = ""
        fw.output = fw.output .. "\nProcess exited.\n"
        -- Auto-reconnect with exponential backoff if this was a tunnel that should be running
        if fw.auto_restart then
          if not fw.url_printed then
            fw.initial_retries = (fw.initial_retries or 0) + 1
          end
          if not fw.url_printed and fw.initial_retries > 3 then
            fw.output = fw.output .. "Failed to connect after 3 attempts. Network might be down or SSH is blocked.\n"
          else
            fw.restart_count = (fw.restart_count or 0) + 1
            if fw.restart_count <= 15 then
              local backoff = math.min(300, 2 ^ fw.restart_count)
              if not fw.last_restart or os.time() - fw.last_restart > backoff then
                fw.last_restart = os.time()
                fw.output = fw.output .. "Auto-reconnecting (attempt " .. fw.restart_count .. ")...\n"
                core.log("Tunnel '%s' died — auto-reconnecting...", fw.name)
                start_forward(idx)
              end
            else
              fw.output = fw.output .. "Max reconnect retries reached.\n"
            end
          end
        end
        needs_redraw = true
      end
    end
  end
  if needs_redraw then
    core.redraw = true
  end
end

local TunnelVisitorView = View:extend()
function TunnelVisitorView:new(log_path)
  TunnelVisitorView.super.new(self)
  self.scrollable = true
  self.log_path = log_path
  self.visitors = {}
  self.last_mtime = 0
end
function TunnelVisitorView:get_name() return "🕵️ Visitors" end

function TunnelVisitorView:update()
  TunnelVisitorView.super.update(self)
  local info = system.get_file_info(self.log_path)
  if info and info.modified > self.last_mtime then
    self.last_mtime = info.modified
    local f = io.open(self.log_path, "r")
    if f then
      local data = f:read("*a")
      f:close()
      self.visitors = {}
      for ip, loc, ua, time in data:gmatch('"ip"%s*:%s*"([^"]+)",%s*"location"%s*:%s*"([^"]+)",%s*"userAgent"%s*:%s*"([^"]+)",%s*"time"%s*:%s*"([^"]+)"') do
        table.insert(self.visitors, {ip = ip, location = loc, userAgent = ua, time = time})
      end
      core.redraw = true
    end
  end
end

function TunnelVisitorView:get_scrollable_size()
  return (#self.visitors + 3) * (style.font:get_height() + 4) + 100
end

function TunnelVisitorView:draw()
  self:draw_background(style.background)
  local lh = style.font:get_height()
  local ox, oy = self:get_content_offset()
  local x = ox + style.padding.x
  local y = oy + style.padding.y
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  
  renderer.draw_text(style.big_font or style.font, "[Analytics] Tunnel Visitors", x, y, style.accent)
  y = y + (style.big_font and style.big_font:get_height() or lh) + style.padding.y * 2
  
  -- Dynamically calculate column widths based on the active font to prevent overlaps
  local ip_w = math.max(220, style.font:get_width("255.255.255.255 (Google LLC)    "))
  local path_w = math.max(200, style.font:get_width("POST /api/v1/users/login    "))
  local dev_w = math.max(300, style.font:get_width("Chrome on Windows | https://reddit.com/    "))
  local loc_w = math.max(280, style.font:get_width("Ghaziabad, Uttar Pradesh, India (en-US)    "))
  local time_w = math.max(120, style.font:get_width("12:00:00 PM    "))
  local col_w = { ip_w, path_w, dev_w, loc_w, time_w }
  
  renderer.draw_rect(x, y - 2, self.size.x, lh + 4, style.line_highlight)
  
  local cx = x
  renderer.draw_text(style.font, "IP / ISP", cx, y, style.text); cx = cx + col_w[1]
  renderer.draw_text(style.font, "Request", cx, y, style.text); cx = cx + col_w[2]
  renderer.draw_text(style.font, "Device & Referer", cx, y, style.text); cx = cx + col_w[3]
  renderer.draw_text(style.font, "Location & Lang", cx, y, style.text); cx = cx + col_w[4]
  renderer.draw_text(style.font, "Time", cx, y, style.text)
  
  y = y + lh + style.padding.y
  
  if #self.visitors == 0 then
    renderer.draw_text(style.font, "No visitors yet...", x, y, style.dim)
  else
    for i, v in ipairs(self.visitors) do
      if i % 2 == 0 then renderer.draw_rect(x, y - 2, self.size.x, lh + 4, style.line_highlight) end
      
      cx = x
      -- IP & ISP Column
      core.push_clip_rect(cx, y, col_w[1] - 10, lh)
      local ip_str = v.ip
      if v.isp and v.isp ~= "" and v.isp ~= "Unknown ISP" then ip_str = ip_str .. " (" .. v.isp .. ")" end
      renderer.draw_text(style.font, ip_str, cx, y, style.text)
      core.pop_clip_rect()
      
      -- Path Column
      cx = cx + col_w[1]
      core.push_clip_rect(cx, y, col_w[2] - 10, lh)
      local path_str = (v.method or "GET") .. " " .. (v.path or "/")
      renderer.draw_text(style.font, path_str, cx, y, style.text)
      core.pop_clip_rect()
      
      -- Device & Referer Column
      cx = cx + col_w[2]
      core.push_clip_rect(cx, y, col_w[3] - 10, lh)
      local dev_str = v.userAgent or "Unknown"
      if v.referer and v.referer ~= "" then dev_str = dev_str .. " | " .. v.referer end
      renderer.draw_text(style.font, dev_str, cx, y, style.dim)
      core.pop_clip_rect()
      
      -- Location & Lang Column
      cx = cx + col_w[3]
      core.push_clip_rect(cx, y, col_w[4] - 10, lh)
      local loc_str = v.location or "Unknown"
      if v.language and v.language ~= "" and v.language ~= "Unknown" then loc_str = loc_str .. " (" .. v.language .. ")" end
      renderer.draw_text(style.font, loc_str, cx, y, style.dim)
      core.pop_clip_rect()
      
      -- Time Column
      cx = cx + col_w[4]
      core.push_clip_rect(cx, y, self.size.x - cx, lh)
      renderer.draw_text(style.font, v.time or "", cx, y, style.dim)
      core.pop_clip_rect()
      
      y = y + lh + 4
    end
  end
  core.pop_clip_rect()
end

function PortForwardView:get_scrollable_size()
  local lh = self:get_line_height()
  local h = style.padding.y + (style.big_font and style.big_font:get_height() or lh) + style.padding.y
  
  for _, _ in ipairs(forwards) do
    h = h + (lh * 2.5) + style.padding.y
  end
  
  local selected_fw = forwards[self.selected_idx]
  if selected_fw then
    h = h + 20 + lh + style.padding.y
    local log_font = style.code_font or style.font
    local lines = 0
    for _ in selected_fw.output:gmatch("([^\n]+)") do lines = lines + 1 end
    h = h + lines * log_font:get_height() + style.padding.y
  end
  
  return h
end

function PortForwardView:on_mouse_pressed(button, x, y, clicks)
  local caught = PortForwardView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then return caught end
  
  local lh = self:get_line_height()
  local ox, oy = self:get_content_offset()
  local item_x = ox + style.padding.x
  local item_y = oy + style.padding.y
  
  if self.add_btn_rect and x >= self.add_btn_rect.x and x <= self.add_btn_rect.x + self.add_btn_rect.w and y >= self.add_btn_rect.y and y <= self.add_btn_rect.y + self.add_btn_rect.h then
    command.perform("port_forward:add-rule")
    return true
  end

  if self.lt_btn_rect and x >= self.lt_btn_rect.x and x <= self.lt_btn_rect.x + self.lt_btn_rect.w and y >= self.lt_btn_rect.y and y <= self.lt_btn_rect.y + self.lt_btn_rect.h then
    command.perform("port_forward:add-localtunnel")
    return true
  end

  if self.visit_btn_rect and x >= self.visit_btn_rect.x and x <= self.visit_btn_rect.x + self.visit_btn_rect.w and y >= self.visit_btn_rect.y and y <= self.visit_btn_rect.y + self.visit_btn_rect.h then
    command.perform("port_forward:show-visitors")
    return true
  end

  item_y = item_y + (style.big_font and style.big_font:get_height() or lh) + style.padding.y
  
  for i, fw in ipairs(forwards) do
    local h = lh * 2.5
    if x >= item_x and x <= item_x + self.size.x - style.padding.x * 2 and y >= item_y and y <= item_y + h then
      self.selected_idx = i
      if clicks == 2 then
        if fw.proc then stop_forward(i) else start_forward(i) end
      end
      core.redraw = true
      return true
    end
    item_y = item_y + h + style.padding.y
  end
end

function PortForwardView:draw()
  self:draw_background(style.background)
  local lh = self:get_line_height()
  
  local ox, oy = self:get_content_offset()
  local x = ox + style.padding.x
  local y = oy + style.padding.y
  
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  
  renderer.draw_text(style.big_font or style.font, "Port Forwarding Rules", x, y, style.text)
  
  -- Add Rule Button
  local btn_text = "+ Add Rule"
  self.add_btn_rect = { x = x + 300, y = y, w = style.font:get_width(btn_text) + 20, h = lh * 1.5 }
  renderer.draw_rect(self.add_btn_rect.x, self.add_btn_rect.y, self.add_btn_rect.w, self.add_btn_rect.h, style.accent or {200, 80, 80})
  renderer.draw_text(style.font, btn_text, self.add_btn_rect.x + 10, self.add_btn_rect.y + math.floor((self.add_btn_rect.h - style.font:get_height())/2), {255, 255, 255, 255})
  
  -- Add Public Tunnel Button
  local lt_btn_text = "+ Add Public Tunnel"
  self.lt_btn_rect = { x = self.add_btn_rect.x + self.add_btn_rect.w + 10, y = y, w = style.font:get_width(lt_btn_text) + 20, h = lh * 1.5 }
  renderer.draw_rect(self.lt_btn_rect.x, self.lt_btn_rect.y, self.lt_btn_rect.w, self.lt_btn_rect.h, {80, 200, 80})
  renderer.draw_text(style.font, lt_btn_text, self.lt_btn_rect.x + 10, self.lt_btn_rect.y + math.floor((self.lt_btn_rect.h - style.font:get_height())/2), {255, 255, 255, 255})
  
  y = y + (style.big_font and style.big_font:get_height() or lh) + style.padding.y
  
  for i, fw in ipairs(forwards) do
    local is_selected = (i == self.selected_idx)
    local bg = is_selected and style.line_highlight or nil
    local fg = is_selected and style.accent or style.text
    
    local h = lh * 2.5
    if bg then
      renderer.draw_rect(x, y, self.size.x - style.padding.x * 2, h, bg)
    end
    
    local status = fw.proc and "RUNNING" or "STOPPED"
    local status_color = fw.proc and (style.good or style.accent) or style.dim
    
    renderer.draw_text(style.font, fw.name, x + style.padding.x, y + style.padding.y, fg)
    renderer.draw_text(style.font, status, x + 250, y + style.padding.y, status_color)
    renderer.draw_text(style.font, fw.cmd, x + style.padding.x, y + style.padding.y + lh, style.dim)
    
    y = y + h + style.padding.y
  end
  
  -- Render execution log for the selected forward
  local selected_fw = forwards[self.selected_idx]
  if selected_fw then
    local log_y = y + 20
    renderer.draw_rect(self.position.x, log_y - 10, self.size.x, 2, style.dim)
    renderer.draw_text(style.font, "Log: " .. selected_fw.name, x, log_y, style.accent)
    
    local visit_btn_text = "🕵️ Monitor Visitors"
    self.visit_btn_rect = { x = x + 300, y = log_y - 10, w = style.font:get_width(visit_btn_text) + 20, h = lh * 1.5 }
    renderer.draw_rect(self.visit_btn_rect.x, self.visit_btn_rect.y, self.visit_btn_rect.w, self.visit_btn_rect.h, {60, 140, 200})
    renderer.draw_text(style.font, visit_btn_text, self.visit_btn_rect.x + 10, self.visit_btn_rect.y + math.floor((self.visit_btn_rect.h - style.font:get_height())/2), {255, 255, 255, 255})
    
    log_y = log_y + lh + style.padding.y
    
    local log_font = style.code_font or style.font
    for line in selected_fw.output:gmatch("([^\n]+)") do
      renderer.draw_text(log_font, line, x, log_y, style.text)
      log_y = log_y + log_font:get_height()
    end
  end
  
  core.pop_clip_rect()
end

-- Setup Global Commands
command.add(nil, {
  ["port_forward:toggle"] = function()
    for _, view in ipairs(core.root_view.root_node:get_children()) do
      if view:is(PortForwardView) then
        local node = core.root_view.root_node:get_node_for_view(view)
        if node then node:close_view(core.root_view.root_node, view) end
        return
      end
    end
    local node = core.root_view:get_active_node_default()
    node:add_view(PortForwardView())
  end,
  ["port_forward:add-localtunnel"] = function()
    core.command_view:enter("Local Port to Expose (e.g. 3000)", {
      submit = function(local_port)
        if not tonumber(local_port) then
          core.error("Port must be a valid number!")
          return
        end
        
        -- Automatically patch Vite configs to prevent "Blocked request" host errors!
        for _, ext in ipairs({"ts", "js"}) do
          local path = core.project_dir .. "/vite.config." .. ext
          local f = io.open(path, "r")
          if f then
            local content = f:read("*a")
            f:close()
            local modified = false
            
            -- 1. Patch allowedHosts
            if not content:match("allowedHosts%s*:") then
              local new_content, count = content:gsub("server%s*:%s*%{", "server: { allowedHosts: true,")
              if count == 0 then
                new_content = content:gsub("defineConfig%s*%(%s*%{", "defineConfig({\n  server: { allowedHosts: true },")
              end
              if new_content ~= content then
                content = new_content
                modified = true
              end
            end
            
            -- 2. Patch HMR clientPort and protocol (supports Vite 5/6 'hmr' and Vite 7 'ws' configs)
            if not content:match("clientPort") then
              local new_content, count = content:gsub("server%s*:%s*%{", "server: { ws: { clientPort: 443, protocol: 'wss' }, hmr: { clientPort: 443, protocol: 'wss' },")
              if count == 0 then
                new_content = content:gsub("defineConfig%s*%(%s*%{", "defineConfig({\n  server: { ws: { clientPort: 443, protocol: 'wss' }, hmr: { clientPort: 443, protocol: 'wss' } },")
              end
              if new_content ~= content then
                content = new_content
                modified = true
              end
            end
            
            if modified then
              local fw = io.open(path, "w")
              if fw then
                fw:write(content)
                fw:close()
                core.log("Auto-patched vite.config." .. ext .. " for public tunneling (HMR + Allowed Hosts)!")
              end
            end
          end
        end

          -- Automatically patch Python Django configs to prevent DisallowedHost errors
          -- (Note: Flask, FastAPI, Go, and Java Spring Boot do NOT block hosts by default, so they already work out of the box!)

          -- To keep it simple and fast without blocking the UI with recursive searches, 
          -- we'll check the most common Django project structure: core/settings.py, config/settings.py, backend/settings.py or just settings.py
          local django_paths = {"settings.py", "core/settings.py", "config/settings.py", "backend/settings.py", "app/settings.py", "project/settings.py"}
          for _, dp in ipairs(django_paths) do
            local path = core.project_dir .. "/" .. dp
            local f = io.open(path, "r")
            if f then
              local content = f:read("*a")
              f:close()
              if content:match("ALLOWED_HOSTS") and not content:match("ALLOWED_HOSTS%s*=%s*%[%s*['\"]%*['\"]%s*%]") then
                local new_content = content:gsub("ALLOWED_HOSTS%s*=%s*%[.-%]", "ALLOWED_HOSTS = ['*']")
                if new_content ~= content then
                  local fw = io.open(path, "w")
                  if fw then
                     fw:write(new_content)
                     fw:close()
                     core.log("Auto-patched Django " .. dp .. " to allow public tunnels!")
                  end
                end
              end
            end
          end

          local proxy_port = local_port + 10000

          -- Use SSH tunneling to pinggy.io
        local cmd = string.format(
          'ssh -p 443 -o StrictHostKeyChecking=no -o UserKnownHostsFile=' .. ((PLATFORM == "Windows") and "NUL" or "/dev/null") ..
          ' -o ServerAliveInterval=60' ..
          ' -o ServerAliveCountMax=10' ..
          ' -o ExitOnForwardFailure=yes' ..
          ' -o ConnectTimeout=15' ..
          ' -o LogLevel=ERROR' ..
          ' -T -R 0:127.0.0.1:%s free:lazy:lite@a.pinggy.io', proxy_port)
        table.insert(forwards, { 
          name = "Public Tunnel (Port " .. local_port .. ")", 
          cmd = cmd, 
          output = "Press Enter/Double-click to start.\n", 
          proc = nil, 
          url_printed = false, 
          target_port = local_port, 
          proxy_port = proxy_port,
          auto_restart = true 
        })
        save_rules()
        core.log("Added Public Tunnel for port: %s", local_port)
      end
    })
  end,

  ["port_forward:show-visitors"] = function()
    local path = USERDIR .. "/plugins/tunnel_monitor/visitors.json"
    
    local view = TunnelVisitorView(path)
    core.root_view:get_primary_node():add_view(view)
  end,
  ["port_forward:add-rule"] = function()
    core.command_view:enter("Rule Name (e.g. Database Tunnel)", {
      submit = function(name)
        core.command_view:enter("Local Port to open (e.g. 8080)", {
          submit = function(local_port)
            core.command_view:enter("Remote Host/URL (e.g. example.com or localhost)", {
              submit = function(host)
                core.command_view:enter("Remote Port (e.g. 5432)", {
                  submit = function(remote_port)
                    -- Cyber attack protection: strict validation against injection
                    if not tonumber(local_port) or not tonumber(remote_port) then
                      core.error("Ports must be valid numbers! Cyber attack prevented.")
                      return
                    end
                    if host:find("[;&|<>%%$`\\]") then
                      core.error("Invalid characters in host! Cyber attack prevented.")
                      return
                    end
                    
                    -- Auto-generate secure command based on standard local forwarding
                    local cmd = string.format("ssh -N -L %s:localhost:%s %s", local_port, remote_port, host)
                    table.insert(forwards, { name = name, cmd = cmd, output = "Press Enter/Double-click to start.\n", proc = nil })
                    save_rules()
                    core.log("Added secure port forward: %s", name)
                  end
                })
              end
            })
          end
        })
      end
    })
  end
})

-- Setup View-Specific Commands
command.add(PortForwardView, {
  ["port_forward:start"] = function(view)
    if view.selected_idx then start_forward(view.selected_idx) end
  end,
  ["port_forward:stop"] = function(view)
    if view.selected_idx then stop_forward(view.selected_idx) end
  end,
  ["port_forward:remove"] = function(view)
    if view.selected_idx and forwards[view.selected_idx] then
      stop_forward(view.selected_idx)
      table.remove(forwards, view.selected_idx)
      save_rules()
      view.selected_idx = math.max(1, math.min(view.selected_idx, #forwards))
      core.redraw = true
    end
  end,
  ["port_forward:move-up"] = function(view)
    if view.selected_idx > 1 then 
      view.selected_idx = view.selected_idx - 1 
      core.redraw = true
    end
  end,
  ["port_forward:move-down"] = function(view)
    if view.selected_idx < #forwards then 
      view.selected_idx = view.selected_idx + 1 
      core.redraw = true
    end
  end
})

-- Keybindings
keymap.add {
  ["alt+m"]  = "port_forward:toggle",
  ["return"] = { "port_forward:start", "core:newline", "command:submit" },
  ["escape"] = { "port_forward:stop", "core:cancel", "command:escape" },
  ["delete"] = { "port_forward:remove", "core:delete" },
  ["up"]     = { "port_forward:move-up", "core:move-up", "command:select-previous" },
  ["down"]   = { "port_forward:move-down", "core:move-down", "command:select-next" }
}

-- Ensure child processes are killed properly when closing the editor
local core_quit = core.quit
function core.quit(...)
  for i, fw in ipairs(forwards) do
    if fw.proc then stop_forward(i) end
  end
  return core_quit(...)
end