-- mod-version:3
-- Terminal bottom sheet (Ctrl+`)
-- Uses size animation (like treeview) for hide/show — no node removal needed.
-- Command-runner mode: each Enter runs cmd.exe /c <command> (reliable on Windows).

local core    = require "core"
local config  = require "core.config"
local style   = require "core.style"
local command = require "core.command"
local common  = require "core.common"

local function append_wrapped(lines, kind, text, max_chars)
  table.insert(lines, { kind = kind, text = text })
end

local View    = require "core.view"
local process = require "process"
local system  = require "system"

local function shell_quote(value)
  value = tostring(value or "")
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function utf8_prev_index(text, cursor)
  cursor = math.max(1, math.min(cursor or (#text + 1), #text + 1))
  if cursor <= 1 then return 1 end
  local i = cursor - 1
  while i > 1 do
    local b = text:byte(i)
    if not b or b < 0x80 or b >= 0xC0 then break end
    i = i - 1
  end
  return i
end

local function utf8_next_index(text, cursor)
  cursor = math.max(1, math.min(cursor or (#text + 1), #text + 1))
  if cursor > #text then return #text + 1 end
  local i = cursor + 1
  while i <= #text do
    local b = text:byte(i)
    if not b or b < 0x80 or b >= 0xC0 then break end
    i = i + 1
  end
  return i
end

local function sort_positions(l1, c1, l2, c2)
  if l1 < l2 or (l1 == l2 and c1 <= c2) then
    return l1, c1, l2, c2
  end
  return l2, c2, l1, c1
end

local function strip_ansi(text)
  return text:gsub("\027%[[%?0-9;]*[A-Za-z]", "")
end

local function draw_ansi_text(font, text, x, y, default_color)
  if not text:find("\027%[") then
    return renderer.draw_text(font, text, x, y, default_color)
  end
  
  local cx = x
  local current_color = default_color
  local last_pos = 1
  for start_pos, codes, end_pos in text:gmatch("()\027%[([0-9;]*)m()") do
    if start_pos > last_pos then
      local sub = text:sub(last_pos, start_pos - 1)
      renderer.draw_text(font, sub, cx, y, current_color)
      cx = cx + font:get_width(sub)
    end
    
    if codes == "0" or codes == "" then current_color = default_color end
    for code in codes:gmatch("%d+") do
      local n = tonumber(code)
      if n == 0 then current_color = default_color
      elseif n >= 30 and n <= 37 then
        local cols = {
          [30] = {common.color("#282828")},
          [31] = {common.color("#CC241D")},
          [32] = {common.color("#98971A")},
          [33] = {common.color("#D79921")},
          [34] = {common.color("#458588")},
          [35] = {common.color("#B16286")},
          [36] = {common.color("#689D6A")},
          [37] = {common.color("#A89984")}
        }
        current_color = cols[n] or default_color
      elseif n >= 90 and n <= 97 then
        local cols = {
          [90] = {common.color("#928374")},
          [91] = {common.color("#FB4934")},
          [92] = {common.color("#B8BB26")},
          [93] = {common.color("#FABD2F")},
          [94] = {common.color("#83A598")},
          [95] = {common.color("#D3869B")},
          [96] = {common.color("#8EC07C")},
          [97] = {common.color("#EBDBB2")}
        }
        current_color = cols[n] or default_color
      end
    end
    last_pos = end_pos
  end
  if last_pos <= #text then
    renderer.draw_text(font, text:sub(last_pos), cx, y, current_color)
    cx = cx + font:get_width(text:sub(last_pos))
  end
  return cx
end

local function get_prompt(s)
  if s.shell.is_port_manager then return "" end
  if s.proc then return "" end
  if core.active_codespace then
    if s.waiting_sentinel then return "" end  -- running, no input prompt
    local repo_only = core.active_codespace.repo:match("[^/]+$") or core.active_codespace.repo
    return "\u{f09b} /workspaces/" .. repo_only .. "$ "
  end
  local prefix = ""
  if s.venv_name then prefix = "(" .. s.venv_name .. ") " end
  local suffix = (PLATFORM == "Windows" and "> " or "$ ")
  if s.shell.name and s.shell.name:match("Bash") then suffix = "$ " end
  return prefix .. (s.shell.prompt_prefix or "") .. (s.cwd or core.project_dir) .. suffix
end

local shells = {}
if PLATFORM == "Windows" then
  table.insert(shells, { name = "PowerShell", cmd = {"powershell.exe", "-NoProfile"}, prompt_prefix = "" })
  table.insert(shells, { name = "Command Prompt", cmd = {"cmd.exe"}, prompt_prefix = "" })

  local sys = require "system"
  if sys.get_file_info("C:\\Program Files\\Git\\bin\\bash.exe") then
    table.insert(shells, { name = "Git Bash", cmd = {"C:\\Program Files\\Git\\bin\\bash.exe", "--login", "-i"}, prompt_prefix = "" })
  end
  if sys.get_file_info("C:\\Windows\\System32\\wsl.exe") then
    table.insert(shells, { name = "WSL", cmd = {"C:\\Windows\\System32\\wsl.exe", "-e", "bash"}, prompt_prefix = "" })
  end
else
  local function has_cmd(c) return os.execute("command -v " .. c .. " >/dev/null 2>&1") == 0 end
  if has_cmd("bash") then table.insert(shells, { name = "bash", cmd = {"bash"}, prompt_prefix = "" }) end
  if has_cmd("zsh") then table.insert(shells, { name = "zsh", cmd = {"zsh"}, prompt_prefix = "" }) end
  table.insert(shells, { name = "sh", cmd = {"sh"}, prompt_prefix = "" })
end
table.insert(shells, { name = "Port Manager", is_port_manager = true })


-- ── Config ────────────────────────────────────────────────────────────────────
config.terminal = {
  target_height = 220,
  min_height    = 80,
  scrollback    = 500,   -- max output lines kept
}

-- ── Dynamic contrast helpers (same logic as mossy_statusbar/treeview) ────────
local function luminance(r, g, b)
  return r * 0.299 + g * 0.587 + b * 0.114
end

local function get_contrast_bg(base)
  if type(base) ~= "table" then return base end
  local r, g, b, a = base[1], base[2], base[3], base[4] or 255
  local lum = luminance(r, g, b)
  if lum > 128 then
    return { math.max(0, math.floor(r*0.92)), math.max(0, math.floor(g*0.92)), math.max(0, math.floor(b*0.92)), a }
  else
    return { math.min(255, math.floor(r+(255-r)*0.08)), math.min(255, math.floor(g+(255-g)*0.08)), math.min(255, math.floor(b+(255-b)*0.08)), a }
  end
end

local function get_contrast_fg(bg)
  if type(bg) ~= "table" then return { 0,0,0,255 } end
  local r, g, b = bg[1], bg[2], bg[3]
  -- If bg is light → use dark text; if bg is dark → use light text
  if luminance(r, g, b) > 128 then
    return { math.floor(r*0.2), math.floor(g*0.2), math.floor(b*0.2), 255 }   -- near-black tinted
  else
    return { math.min(255,math.floor(r+(255-r)*0.82)), math.min(255,math.floor(g+(255-g)*0.82)), math.min(255,math.floor(b+(255-b)*0.82)), 255 }  -- near-white tinted
  end
end

-- ── Colours (read from mossy palette or literal fallback) ─────────────────────
local function tc(key, fallback)
  if style.mossy and style.mossy[key] then return style.mossy[key] end
  return { common.color(fallback) }
end

-- ── View ──────────────────────────────────────────────────────────────────────
local TermView = View:extend()
local instance   = nil   -- single instance kept alive across toggles
TermView.instances = TermView.instances or {}
-- have we added to node tree yet?
local node_built = false
-- Sentinel used to detect end-of-command in persistent shell sessions.
-- Must be unique enough to never appear in normal command output.
local SENTINEL_BASE = "__LITEXL_DONE_"
local function make_sentinel(n) return SENTINEL_BASE .. tostring(n) .. "__" end

function TermView:new()
  TermView.super.new(self)
  self.visible      = true   -- controls size animation (treeview pattern)
  self.target_size  = config.terminal.target_height * SCALE
  self.size.y       = 0      -- start collapsed; animate on first show
  self.scrollable = true
  self.sessions = {}
  self.active_idx = 1
  self.split_indices = { 1 }
  self.show_sidebar = true
  self.hovering_url = false
  self.is_fullscreen = false
  self.dragging_selection = false
  self.hovered_btn_name = nil
  self:add_session(shells[1])
  table.insert(TermView.instances, self)
end

function TermView:state()
  return self.sessions[self.active_idx]
end

function TermView:add_session(shell_opts)
  if core.active_codespace then
    shell_opts = { name = "Cloud Shell", cmd = {} }
  else
    if shell_opts and shell_opts ~= shells[1] then
      setmetatable(shell_opts, { __index = shells[1] })
    else
      shell_opts = shells[1]
    end
  end
  local s = {
    lines = {},
    input = "",
    cursor = 1,
    scroll_y = 0,
    proc = nil,
    -- Persistent shell for codespace sessions (avoids per-command SSH handshake)
    persistent_proc = nil,
    codespace_cwd = nil,   -- tracks cwd inside the persistent shell
    sentinel_n = 0,        -- counter for unique sentinels
    waiting_sentinel = nil,-- sentinel we're waiting for
    history = {},
    history_idx = 1,
    selection = nil,
    scroll_to_bottom = true,
      shell = shell_opts,
      start_time = system.get_time(),
  }
  table.insert(self.sessions, s)
  self.active_idx = #self.sessions
  if shell_opts.is_port_manager then
    self:refresh_ports(s)
  else
    local right_w = 0
    if self.show_sidebar ~= false then
      local max_w = 100 * SCALE
      local num_terms = 0
      for i, sess in ipairs(self.sessions) do 
        if not sess.shell.is_port_manager then 
          num_terms = num_terms + 1 
          local title_w = style.font:get_width("├─ " .. (sess.shell.name or ("Term " .. i))) + 30 * SCALE
          if title_w > max_w then max_w = title_w end
        end 
      end
      if num_terms > 1 then right_w = max_w end
    end
    local available_w = self.size.x - right_w
    local col_w = math.floor(available_w / math.max(1, #self.split_indices))
    local char_w = style.code_font:get_width("W")
    local init_cols = math.floor((col_w - 20 * SCALE) / char_w)
    init_cols = math.max(40, init_cols)
    
    local lh = style.code_font:get_height() + 2 * SCALE
    local out_h = self.size.y - 31 * SCALE
    local init_rows = math.floor((out_h - 10 * SCALE) / lh)
    init_rows = math.max(10, init_rows)
    
    s.term = require("plugins.toggle_terminal.vt100_parser").new(init_cols, init_rows)
    local exe_path = USERDIR .. "/plugins/toggle_terminal/lite-pty/lite-pty.exe"
    if not system.get_file_info(exe_path) then
      exe_path = USERDIR .. "/plugins/toggle_terminal/lite-pty/lite-pty"
    end
    
    local shell_str = ""
    if shell_opts.cmd and #shell_opts.cmd > 0 then
      local parts = {}
      for i, v in ipairs(shell_opts.cmd) do
        if v:find(" ") then
          table.insert(parts, '"' .. v .. '"')
        else
          table.insert(parts, v)
        end
      end
      shell_str = table.concat(parts, " ")
    end
    
    local args = {exe_path, "-cols", tostring(init_cols), "-rows", tostring(init_rows)}
    if shell_str ~= "" then
      table.insert(args, "-shell")
      table.insert(args, shell_str)
    end
    s.proc = process.start(args)
    s.ctrl_port_found = false
  end
end

local ignore_procs = {
  ["svchost.exe"] = true,
  ["system"] = true,
  ["lsass.exe"] = true,
  ["wininit.exe"] = true,
  ["smss.exe"] = true,
  ["vmms.exe"] = true,
  ["vmms"] = true,
  ["agy.exe"] = true,
  ["agy"] = true,
  ["csrss.exe"] = true,
  ["services.exe"] = true,
  ["wlanext.exe"] = true,
  ["spoolsv.exe"] = true,
  ["explorer.exe"] = true,
  ["searchapp.exe"] = true,
  ["dashost.exe"] = true,
  ["taskhostw.exe"] = true,
  ["winlogon.exe"] = true,
  ["dwm.exe"] = true,
  ["fontdrvhost.exe"] = true,
  ["wmiprvse.exe"] = true,
  ["conhost.exe"] = true,
  ["searchindexer.exe"] = true,
  ["securityhealthservice.exe"] = true,
  ["lsaiso.exe"] = true,
  ["wudfhost.exe"] = true,
  ["system idle process"] = true,
  ["registry"] = true,
  ["secure system"] = true,
  ["ctfmon.exe"] = true,
  ["sihost.exe"] = true,
  ["rtkngui64.exe"] = true,
}

function TermView:refresh_ports(s)
  s.fetching = true
  s.ports = {}
  s.port_buttons = {}
  s.selected_ports = {}
  s.checkbox_rects = {}
  s.filtered_ports = {}
  
  core.add_thread(function()
    local p_names = {}
    if PLATFORM == "Windows" then
      local p1 = process.start({"powershell", "-NoProfile", "-Command", "Get-Process | Select-Object Id, ProcessName | ConvertTo-Csv -NoTypeInformation"}, { stdout = process.REDIRECT_PIPE })
      if p1 then
        local out = ""
        local deadline = system.get_time() + 4
        while true do
          local chunk = p1:read_stdout(4096)
          if chunk and #chunk > 0 then
            out = out .. chunk
          elseif not p1:running() then
            break
          elseif system.get_time() > deadline then
            break
          else
            coroutine.yield(0.05)
          end
        end
        for line in (out .. "\n"):gmatch("[^\n]+") do
          local pid, name = line:match('^"([^"]+)","([^"]+)"')
          if pid and name then
            local pid_num = tonumber(pid)
            if pid_num then
              if not name:lower():match("%.exe$") then name = name .. ".exe" end
              p_names[tostring(pid_num)] = name
            end
          end
        end
      end
      
      local p2 = process.start({"cmd.exe", "/c", "netstat -ano | findstr LISTENING"}, { stdout = process.REDIRECT_PIPE })
      if p2 then
        local out = ""
        local deadline = system.get_time() + 4
        while true do
          local chunk = p2:read_stdout(4096)
          if chunk and #chunk > 0 then
            out = out .. chunk
          elseif not p2:running() then
            break
          elseif system.get_time() > deadline then
            break
          else
            coroutine.yield(0.05)
          end
        end
        for line in (out .. "\n"):gmatch("[^\n]+") do
          local proto, local_addr, foreign_addr, state, pid = line:match("%s*(%w+)%s+([%w%.%:%[%]]+)%s+([%w%.%:%[%]]+)%s+(%w+)%s+(%d+)")
          if proto and local_addr and pid and pid ~= "0" and pid ~= "4" then
            local ip, port = local_addr:match("^(.*):(%d+)$")
            if port and (ip == "0.0.0.0" or ip == "127.0.0.1" or ip == "[::]" or ip == "[::1]") then
               local pname = p_names[pid] or "Unknown"
               if not ignore_procs[pname:lower()] then
                 table.insert(s.ports, { proto = proto, port = port, pid = pid, name = pname })
               end
            end
          end
        end
      end
    else
      -- Linux / macOS implementation using ps and ss
      local p1 = process.start({"sh", "-c", "ps -e -o pid=,comm="}, { stdout = process.REDIRECT_PIPE })
      if p1 then
        local out = ""
        local deadline = system.get_time() + 4
        while true do
          local chunk = p1:read_stdout(4096)
          if chunk and #chunk > 0 then out = out .. chunk
          elseif not p1:running() then break
          elseif system.get_time() > deadline then break
          else coroutine.yield(0.05) end
        end
        for line in (out .. "\n"):gmatch("[^\n]+") do
          local pid, name = line:match("^%s*(%d+)%s+(.+)$")
          if pid and name then p_names[pid] = name end
        end
      end
      
      local p2 = process.start({"sh", "-c", "ss -lntp"}, { stdout = process.REDIRECT_PIPE })
      if p2 then
        local out = ""
        local deadline = system.get_time() + 4
        while true do
          local chunk = p2:read_stdout(4096)
          if chunk and #chunk > 0 then out = out .. chunk
          elseif not p2:running() then break
          elseif system.get_time() > deadline then break
          else coroutine.yield(0.05) end
        end
        for line in (out .. "\n"):gmatch("[^\n]+") do
          local state, recv, send, local_addr, peer_addr, users = line:match("^LISTEN%s+%S+%s+%S+%s+(%S+)%s+%S+%s+(.+)$")
          if local_addr then
            local ip, port = local_addr:match("^(.*):(%d+)$")
            if port and (ip == "0.0.0.0" or ip == "127.0.0.1" or ip == "[::]" or ip == "[::1]" or ip == "*") then
              local pid = users:match('pid=(%d+)')
              if pid then
                local pname = p_names[pid] or users:match('^users:%(%(%"([^%"]+)%"') or "Unknown"
                if not ignore_procs[pname:lower()] then
                  table.insert(s.ports, { proto = "TCP", port = port, pid = pid, name = pname })
                end
              end
            end
          end
        end
      end
    end
    
    table.sort(s.ports, function(a, b) return tonumber(a.port) < tonumber(b.port) end)
    
    s.fetching = false
    core.redraw = true
  end)
end

-- Called by the node system when the user drags the resize divider
function TermView:set_target_size(axis, value)
  if axis == "y" then
    if self.is_fullscreen then self.is_fullscreen = false end
    if not self.visible and value > 10 * SCALE then self.visible = true end
    local max_h = core.root_view.root_node.size.y
    local node = core.root_view.root_node:get_node_for_view(self)
    if node then
      local parent = node:get_parent_node(core.root_view.root_node)
      if parent then max_h = parent.size.y - style.divider_size end
    end
    self.target_size = math.min(max_h, math.max(config.terminal.min_height * SCALE, value))
    return true
  end
end

function TermView:get_name() return "Terminal" end

function TermView:_push_chunk(kind, chunk, no_redraw)
  local s = self:state()
  if not s then return end

  local right_w = 0
  if self.show_sidebar ~= false then
    local max_w = 100 * SCALE
    local num_terms = 0
    for i, sess in ipairs(self.sessions) do 
      if not sess.shell.is_port_manager then 
        num_terms = num_terms + 1 
        local title_w = style.font:get_width("├─ " .. (sess.shell.name or ("Term " .. i))) + 30 * SCALE
        if title_w > max_w then max_w = title_w end
      end 
    end
    if num_terms > 1 then right_w = max_w end
  end
  if s.shell.is_port_manager then right_w = 0 end
  local num_terms = 0
  for _, sess in ipairs(self.sessions) do if not sess.shell.is_port_manager then num_terms = num_terms + 1 end end
  if num_terms <= 1 then right_w = 0 end
  
  local available_w = self.size.x - right_w
  local col_w = math.floor(available_w / math.max(1, #self.split_indices))
  local char_w = style.code_font:get_width("W")
  local max_cols = math.floor((col_w - 20 * SCALE) / char_w)
  max_cols = math.max(20, max_cols)

  if not s.lines then s.lines = {} end
  if #s.lines == 0 then
    table.insert(s.lines, {kind = kind, text = ""})
    s.vis_len = 0
  end

  local i = 1
  local len = #chunk
  local last_line = s.lines[#s.lines]
  
  while i <= len do
    local b = chunk:byte(i)
    if b == 27 then
      local j = i + 1
      if chunk:byte(j) == 91 then
        j = j + 1
        while j <= len do
          local cb = chunk:byte(j)
          if (cb >= 64 and cb <= 126) then break end
          j = j + 1
        end
      end
      last_line.text = last_line.text .. chunk:sub(i, j)
      i = j + 1
    elseif b == 10 then -- \n
      table.insert(s.lines, {kind = kind, text = ""})
      last_line = s.lines[#s.lines]
      s.vis_len = 0
      i = i + 1
    elseif b == 13 then -- \r
      if i < len and chunk:byte(i + 1) == 10 then
        -- Skip \r if it's part of a \r\n sequence to prevent erasing the line before \n
        i = i + 1
      else
        last_line.text = ""
        s.vis_len = 0
        i = i + 1
      end
    else
      local char_len = 1
      if b >= 0xC0 then
        if b >= 0xF0 then char_len = 4
        elseif b >= 0xE0 then char_len = 3
        else char_len = 2 end
      end
      last_line.text = last_line.text .. chunk:sub(i, math.min(len, i + char_len - 1))
      s.vis_len = (s.vis_len or 0) + 1
      i = i + char_len
      if s.vis_len >= max_cols then
        table.insert(s.lines, {kind = kind, text = ""})
        last_line = s.lines[#s.lines]
        s.vis_len = 0
      end
    end
  end

  local max_scroll = config.terminal.scrollback or 500
  if #s.lines > max_scroll + 50 then
    local overflow = #s.lines - max_scroll
    table.move(s.lines, overflow + 1, #s.lines, 1)
    for j = max_scroll + 1, #s.lines do s.lines[j] = nil end
  end

  if s.scroll_to_bottom then
    local lh = style.code_font:get_height() + 2 * SCALE
    local out_h = self.size.y - 31 * SCALE
    s.scroll_y = math.max(0, (#s.lines + 1) * lh - out_h + 10 * SCALE)
  end
  if not no_redraw then core.redraw = true end
end

function TermView:_push(kind, text)
  self:_push_chunk(kind, text, false)
end

function TermView:_flush_chunk_buffer(kind)
end

function TermView:_ensure_persistent_proc(s)
end

function TermView:run(cmd_str)
  local s = self:state()
  if not s then return end
  self:_push("cmd", cmd_str)
  if s.proc and s.proc:running() then
    pcall(function() s.proc:write(cmd_str .. "\n") end)
    return
  end
  if s.proc then pcall(function() s.proc:kill() end) end
  
  local shell = s.shell
  if shell.cmd then
    local cmd = {}
    for _, c in ipairs(shell.cmd) do table.insert(cmd, c) end
    table.insert(cmd, cmd_str)
    local opts = {}
    if s.cwd then opts.cwd = s.cwd end
    s.proc = process.start(cmd, opts)
    s.out_buf = ""
  end
end

function TermView:update()
  TermView.super.update(self)
  local dest = self.visible and self.target_size or 0
  if self.is_fullscreen and self.visible then
    local node = core.root_view.root_node:get_node_for_view(self)
    if node then
      local parent = node:get_parent_node(core.root_view.root_node)
      dest = parent and (parent.size.y - style.divider_size) or core.root_view.root_node.size.y
    else
      dest = core.root_view.root_node.size.y
    end
  end
  if math.abs(self.size.y - dest) > 0.5 then
    self.size.y = common.lerp(self.size.y, dest, 0.2)
    core.redraw = true
  else
    self.size.y = dest
  end
  
  if self.dragging_selection then
    local s = self:state()
    if s then
      local mx, my = core.root_view.mouse.x, core.root_view.mouse.y
      local hdr_h = 26 * SCALE
      local top = self.position.y + hdr_h
      local bottom = self.position.y + self.size.y
      local lh = style.code_font:get_height() + 2 * SCALE
      
      local scrolled = false
      if my < top then
        s.scroll_y = math.max(0, (s.scroll_y or 0) - lh)
        scrolled = true
      elseif my > bottom then
        local out_h = self.size.y - 31 * SCALE
        local max_scroll = math.max(0, (#s.lines + 1) * lh - out_h + 10 * SCALE)
        s.scroll_y = math.min(max_scroll, (s.scroll_y or 0) + lh)
        scrolled = true
      end
      
      if scrolled then
        s.scroll_to_bottom = false
        local l, c = self:resolve_position(mx, my)
        if not s.selection then s.selection = { l1 = l, c1 = c, l2 = l, c2 = c } end
        s.selection.l2 = l
        s.selection.c2 = c
        core.redraw = true
      end
    end
  end
  
  local right_w = 0
  if self.show_sidebar ~= false then
    local max_w = 100 * SCALE
    local num_terms = 0
    for i, sess in ipairs(self.sessions) do 
      if not sess.shell.is_port_manager then 
        num_terms = num_terms + 1 
        local title_w = style.font:get_width("├─ " .. (sess.shell.name or ("Term " .. i))) + 30 * SCALE
        if title_w > max_w then max_w = title_w end
      end 
    end
    if num_terms > 1 then right_w = max_w end
  end
  local available_w = self.size.x - right_w
  local col_w = math.floor(available_w / math.max(1, #self.split_indices))
  local char_w = style.code_font:get_width("W")
  local max_cols = math.floor((col_w - 20 * SCALE) / char_w)
  max_cols = math.max(40, max_cols)
  
  local lh = style.code_font:get_height() + 2 * SCALE
  local out_h = self.size.y - 31 * SCALE
  local max_rows = math.floor((out_h - 10 * SCALE) / lh)
  max_rows = math.max(10, max_rows)

  for _, s in ipairs(self.sessions) do
    if s.proc then
        if s.term and (s.term.cols ~= max_cols or s.term.rows ~= max_rows) then
          if not s.target_cols or s.target_cols ~= max_cols or s.target_rows ~= max_rows then
            s.target_cols = max_cols
            s.target_rows = max_rows
            s.resize_timer = system.get_time() + 0.1
          end
        end
        
        if s.term and s.resize_timer and system.get_time() > s.resize_timer then
          if s.term.cols ~= s.target_cols or s.term.rows ~= s.target_rows then
            s.term:resize(s.target_cols, s.target_rows)
            if s.ctrl_port then
              process.start({"curl", "-s", "http://127.0.0.1:" .. s.ctrl_port .. "/resize?cols=" .. s.target_cols .. "&rows=" .. s.target_rows})
            end
            core.redraw = true
          end
          s.resize_timer = nil
        end
      if not s.ctrl_port_found then s.out_buf = s.out_buf or "" end
      local budget_start = system.get_time()
      local processed_any = false
      
      -- Drain stdout
      while true do
        local chunk = s.proc:read_stdout(65536)
        if not chunk or #chunk == 0 then break end
        processed_any = true
        if not s.ctrl_port_found then
          s.out_buf = (s.out_buf or "") .. chunk
          local cport, cport_end = s.out_buf:match("CTRL_PORT=(%d+)\n()")
          if cport then
            s.ctrl_port = tonumber(cport)
            s.ctrl_port_found = true
            local rest = s.out_buf:sub(cport_end)
            if #rest > 0 and s.term then s.term:feed(rest) end
            s.out_buf = nil
            -- Immediately send initial resize now that port is known
            if s.term then
              process.start({"curl", "-s", "http://127.0.0.1:" .. s.ctrl_port .. "/resize?cols=" .. s.term.cols .. "&rows=" .. s.term.rows})
            end
          elseif #s.out_buf > 1024 then
            s.ctrl_port_found = true
            if s.term then s.term:feed(s.out_buf) end
            s.out_buf = nil
          end
        else
          if s.term then s.term:feed(chunk) end
        end
        if system.get_time() - budget_start > 0.010 then break end
      end
      
      if processed_any then core.redraw = true end
      
      -- Handle unexpected exit / crash
        if not processed_any and not s.proc:running() then 
          if s.start_time and system.get_time() - s.start_time < 0.5 then
            -- Died instantly. Avoid infinite loop by just cleaning up
            s.proc = nil
            return
          end
          local old_shell = s.shell
          
          local idx = 1
          for i, sess in ipairs(self.sessions) do
            if sess == s then idx = i; break end
          end
          
          table.remove(self.sessions, idx)
          self:add_session(old_shell)
          
          local new_s = table.remove(self.sessions) 
          table.insert(self.sessions, idx, new_s)
          
          if self.active_idx == #self.sessions + 1 or self.active_idx == #self.sessions then 
            self.active_idx = idx 
          end
          
          core.redraw = true
        end
    end
  end
end

function TermView:draw()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  local bg = (style.mossy and style.mossy.terminal_bg) or style.background2 or style.background
  self:draw_background(bg)
  
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  
  -- Header Background
  local hdr_h = 26 * SCALE
  local hdr_bg = (style.mossy and style.mossy.sidebar_bg) or style.background or style.background3
  renderer.draw_rect(x, y, w, hdr_h, hdr_bg)
  
  -- Header Divider
  local div_color = (style.mossy and style.mossy.border) or style.divider or {common.color("#444444")}
  renderer.draw_rect(x, y + hdr_h - 1 * SCALE, w, 1 * SCALE, div_color)
  
  -- Draw TERMINAL and PORTS major tabs
  local tx = x + 10 * SCALE
  local is_pm_active = self:state() and self:state().shell.is_port_manager
  
  -- TERMINAL Tab
  local term_txt = "TERMINAL"
  local term_w = style.font:get_width(term_txt) + 20 * SCALE
  local fg_text = (style.mossy and style.mossy.terminal_text) or style.text
  local term_col = not is_pm_active and fg_text or style.dim
  renderer.draw_text(style.font, term_txt, tx + 10 * SCALE, y + math.floor((hdr_h - style.font:get_height()) / 2), term_col)
  if not is_pm_active then
    renderer.draw_rect(tx, y + hdr_h - 2 * SCALE, term_w, 2 * SCALE, style.accent or {common.color("#A9DC76")})
  end
  self.terminal_tab_rect = { x = tx, y = y, w = term_w, h = hdr_h }
  tx = tx + term_w
  
  -- PORTS Tab
  local ports_txt = "PORT MANAGER"
  local ports_w = style.font:get_width(ports_txt) + 20 * SCALE
  local ports_col = is_pm_active and style.text or style.dim
  renderer.draw_text(style.font, ports_txt, tx + 10 * SCALE, y + math.floor((hdr_h - style.font:get_height()) / 2), ports_col)
  if is_pm_active then
    renderer.draw_rect(tx, y + hdr_h - 2 * SCALE, ports_w, 2 * SCALE, style.accent or {common.color("#A9DC76")})
  end
  self.ports_tab_rect = { x = tx, y = y, w = ports_w, h = hdr_h }
  tx = tx + ports_w + 10 * SCALE

  -- Draw vertical separator
  renderer.draw_rect(tx, y + 5 * SCALE, 1 * SCALE, hdr_h - 10 * SCALE, style.divider or {common.color("#444444")})
  tx = tx + 10 * SCALE

  -- (Horizontal session tabs removed, moved to right vertical sidebar)
  
  -- Draw buttons
  local btn_x = x + w - 30 * SCALE
  local btns = {
    { name = "trash",    icon = "" },
    { name = "sidebar",  icon = "󰍜" },
    { name = "maximize", icon = "" },
    { name = "split",    icon = "󰤽" },
    { name = "add",      icon = "" }
  }
  self.right_btns = {}
  for _, b in ipairs(btns) do
    renderer.draw_text(style.icon_font, b.icon, btn_x, y + math.floor((hdr_h - style.icon_font:get_height()) / 2), style.text)
    table.insert(self.right_btns, { name = b.name, x = btn_x, y = y, w = 30 * SCALE, h = hdr_h })
    btn_x = btn_x - 30 * SCALE
  end
  
  -- Output
  local out_top = y + hdr_h + 3 * SCALE
  local out_bot = y + h - 2 * SCALE
  local out_h   = out_bot - out_top
  
  if self:state() and self:state().shell.is_port_manager then
    self:draw_port_manager(x, out_top, w, out_h)
    core.pop_clip_rect()
    return
  end
  
  local fg = (style.mossy and style.mossy.terminal_text) or style.text
  local col_err = style.error or {common.color("#ff5555")}
  local col_inf = style.accent or {common.color("#55ff55")}
  local border = (style.mossy and style.mossy.border) or style.divider or {common.color("#444444")}
  
  -- The split drawing loop
  local right_w = 0
  if self.show_sidebar ~= false then
    local max_w = 100 * SCALE
    local num_terms = 0
    for i, sess in ipairs(self.sessions) do 
      if not sess.shell.is_port_manager then 
        num_terms = num_terms + 1 
        local title_w = style.font:get_width("├─ " .. (sess.shell.name or ("Term " .. i))) + 30 * SCALE
        if title_w > max_w then max_w = title_w end
      end 
    end
    if num_terms > 1 then right_w = max_w end
  end
  if self:state() and self:state().shell.is_port_manager then right_w = 0 end
  
  local available_w = w - right_w
  local col_w = math.floor(available_w / #self.split_indices)
  
  -- Generous, VS Code-like line spacing
  local lh = math.floor(style.code_font:get_height() * 1.3)
  local char_w = style.code_font:get_width("W")
  local max_cols = math.max(20, math.floor((col_w - 20 * SCALE) / char_w))

  for col_idx, sess_idx in ipairs(self.split_indices) do
    local s = self.sessions[sess_idx]
    if not s then goto continue end
    
    local col_x = x + (col_idx - 1) * col_w
    if col_idx > 1 then
      renderer.draw_rect(col_x, out_top, 1 * SCALE, out_h, border)
    end
    
    local text_y = out_top + 4 * SCALE - (s.scroll_y or 0)
    local text_x = col_x + 10 * SCALE - (s.scroll_x or 0)
    
    local sel = s.selection
    local sel_l1, sel_c1, sel_l2, sel_c2
    if sel then sel_l1, sel_c1, sel_l2, sel_c2 = sort_positions(sel.l1, sel.c1, sel.l2, sel.c2) end

    core.push_clip_rect(col_x + 1 * SCALE, out_top, col_w - 2 * SCALE, out_h)

    if s.term then
      local cx = text_x
      local cw = style.code_font:get_width("A")
      local total_lines = #s.term.scrollback + s.term.rows
      for r = 1, total_lines do
        local cy = text_y + (r - 1) * lh
        if cy + lh > out_top and cy < out_top + out_h then
          local row = s.term:get_absolute_line(r)
          if row then
            local current_str_parts = {}
            local cur_fg = nil
            local cur_bg = nil
            local cur_bold = false
            local str_start_x = cx
            
            -- Premium VS Code terminal color palette
            local ansi = {
              [0] = {common.color("#000000")}, [1] = {common.color("#cd3131")},
              [2] = {common.color("#0dbc79")}, [3] = {common.color("#e5e510")},
              [4] = {common.color("#2472c8")}, [5] = {common.color("#bc3fbc")},
              [6] = {common.color("#11a8cd")}, [7] = {common.color("#e5e5e5")},
            }
            local ansi_bright = {
              [0] = {common.color("#666666")}, [1] = {common.color("#f14c4c")},
              [2] = {common.color("#23d18b")}, [3] = {common.color("#f5f543")},
              [4] = {common.color("#3b8eea")}, [5] = {common.color("#d670d6")},
              [6] = {common.color("#29b8db")}, [7] = {common.color("#ffffff")},
            }
            
            local function flush_chunk()
              if #current_str_parts > 0 and cur_fg ~= nil then
                local str = table.concat(current_str_parts)
                local str_w = style.code_font:get_width(str)
                if cur_bg then
                  renderer.draw_rect(str_start_x, cy, str_w, lh, cur_bg)
                end
                renderer.draw_text(style.code_font, str, str_start_x, cy, cur_fg)
                if cur_bold then
                  -- Simulate bold font weight by drawing with a tiny horizontal offset
                  renderer.draw_text(style.code_font, str, str_start_x + math.max(1, math.ceil(0.5 * SCALE)), cy, cur_fg)
                end
              end
            end

            for c = 1, s.term.cols do
              local cell = row[c]
              
              -- Draw selection highlight
              if sel_l1 then
                local in_sel = false
                if r > sel_l1 and r < sel_l2 then in_sel = true
                elseif r == sel_l1 and r == sel_l2 then in_sel = (c >= sel_c1 and c < sel_c2)
                elseif r == sel_l1 then in_sel = (c >= sel_c1)
                elseif r == sel_l2 then in_sel = (c < sel_c2)
                end
                if in_sel then
                  renderer.draw_rect(cx, cy, cw, lh, style.selection or {common.color("#ffffff", 50)})
                end
              end
              
              if cell then
                local cell_bold = cell.attr.bold
                local pal = cell_bold and ansi_bright or ansi
                local cell_fg = (cell.attr.fg == 7 and not cell_bold) and fg or (pal[cell.attr.fg] or fg)
                local cell_bg = (cell.attr.bg ~= 0) and ansi[cell.attr.bg] or nil
                
                if cur_fg == nil then
                  cur_fg, cur_bg, cur_bold = cell_fg, cell_bg, cell_bold
                  table.insert(current_str_parts, cell.char)
                elseif cur_fg == cell_fg and cur_bg == cell_bg and cur_bold == cell_bold then
                  table.insert(current_str_parts, cell.char)
                else
                  flush_chunk()
                  str_start_x = cx
                  cur_fg, cur_bg, cur_bold = cell_fg, cell_bg, cell_bold
                  current_str_parts = { cell.char }
                end
              else
                flush_chunk()
                current_str_parts = {}
                cur_fg, cur_bg, cur_bold = nil, nil, false
                str_start_x = cx + cw
              end
              cx = cx + cw
            end
            flush_chunk()
          end
        end
        cx = text_x
      end
      
      if core.active_view == self and sess_idx == self.active_idx then
        local cursor_cx = text_x + (s.term.cursor_x - 1) * cw
        local cursor_cy = text_y + (#s.term.scrollback + s.term.cursor_y - 1) * lh
        if system.get_time() % 1 < 0.5 then
          renderer.draw_rect(cursor_cx, cursor_cy, cw, lh, style.caret or { common.color("#A9DC76", 180) })
        end
      end
    end
    core.pop_clip_rect()
    ::continue::
  end

  if right_w > 0 then
    local rx = x + w - right_w
    local right_bg = (style.mossy and style.mossy.sidebar_bg) or style.background2
    renderer.draw_rect(rx, out_top, right_w, out_h, right_bg)
    local div_color = (style.mossy and style.mossy.border) or style.divider or {common.color("#444444")}
    renderer.draw_rect(rx, out_top, 1 * SCALE, out_h, div_color)
    local ry = out_top
    -- First draw grouped split sessions
    for split_col, i in ipairs(self.split_indices) do
      local sess = self.sessions[i]
      if not sess or sess.shell.is_port_manager then goto skip_vsplit end
      local is_focused = (i == self.active_idx)
      local bg_color = is_focused and ((style.mossy and style.mossy.active_row) or style.background3 or style.background) or right_bg
      renderer.draw_rect(rx + 1 * SCALE, ry, right_w - 1 * SCALE, 26 * SCALE, bg_color)
      renderer.draw_rect(rx + 1 * SCALE, ry, 2 * SCALE, 26 * SCALE, style.accent or {common.color("#A9DC76")})
      
      -- Draw tree branch prefix
      local prefix = (split_col == #self.split_indices) and "└─ " or "├─ "
      if split_col == 1 and #self.split_indices == 1 then prefix = "" end
      
      local title = prefix .. (sess.shell.name or ("Term " .. i))
      local fg_text = (style.mossy and style.mossy.active_row_text) or style.text
      local fg_dim = (style.mossy and style.mossy.sidebar_text) or style.dim
      local title_fg = is_focused and fg_text or fg_dim
      renderer.draw_text(style.font, title, rx + 10 * SCALE, ry + math.floor((26 * SCALE - style.font:get_height())/2), title_fg)
      sess.tab_rect = { x = rx, y = ry, w = right_w, h = 26 * SCALE }
      ry = ry + 26 * SCALE
      ::skip_vsplit::
    end
    
    -- Then draw remaining hidden sessions
    for i, sess in ipairs(self.sessions) do
      if sess.shell.is_port_manager then goto skip_vhidden end
      local is_in_split = false
      for _, s_idx in ipairs(self.split_indices) do if s_idx == i then is_in_split = true break end end
      if not is_in_split then
        renderer.draw_rect(rx + 1 * SCALE, ry, right_w - 1 * SCALE, 26 * SCALE, style.background2)
        local title = sess.shell.name or ("Term " .. i)
        renderer.draw_text(style.font, title, rx + 10 * SCALE, ry + math.floor((26 * SCALE - style.font:get_height())/2), style.dim)
        sess.tab_rect = { x = rx, y = ry, w = right_w, h = 26 * SCALE }
        ry = ry + 26 * SCALE
      end
      ::skip_vhidden::
    end
  else
    for i, sess in ipairs(self.sessions) do sess.tab_rect = nil end
  end
  core.pop_clip_rect()
end

function TermView:resolve_position(x, y)
  local hdr_h = 26 * SCALE
  local out_top = self.position.y + hdr_h + 3 * SCALE
  local right_w = 0
  if self.show_sidebar ~= false then
    local max_w = 100 * SCALE
    local num_terms = 0
    for i, sess in ipairs(self.sessions) do 
      if not sess.shell.is_port_manager then 
        num_terms = num_terms + 1 
        local title_w = style.font:get_width("├─ " .. (sess.shell.name or ("Term " .. i))) + 30 * SCALE
        if title_w > max_w then max_w = title_w end
      end 
    end
    if num_terms > 1 then right_w = max_w end
  end
  if self:state() and self:state().shell.is_port_manager then right_w = 0 end
  local available_w = self.size.x - right_w
  local col_w = math.floor(available_w / #self.split_indices)
  local col_idx = math.floor((x - self.position.x) / col_w) + 1
  col_idx = common.clamp(col_idx, 1, #self.split_indices)
  local col_x = self.position.x + (col_idx - 1) * col_w
  local s = self.sessions[self.split_indices[col_idx]]
  if not s then return 1, 1 end
  local text_x = col_x + 10 * SCALE - (s.scroll_x or 0)
  if not s then return 1, 1 end
  local text_y = out_top + 4 * SCALE - (s.scroll_y or 0)
  local lh = style.code_font:get_height() + 2 * SCALE
  local line = math.floor((y - text_y) / lh) + 1
  local total_lines = s.term and (#s.term.scrollback + s.term.rows) or #s.lines
  line = common.clamp(line, 1, total_lines)
  local col = 1
  
  if s.term then
    local row = s.term:get_absolute_line(line)
    if row then
      local w = 0
      for i = 1, s.term.cols do
        local cell = row[i]
        if not cell then break end
        local char_w = style.code_font:get_width(cell.char)
        if x < text_x + w + char_w / 2 then break end
        w = w + char_w
        col = i + 1
      end
    end
  elseif s.lines[line] then
    local txt = strip_ansi(s.lines[line].text)
    local w = 0
    for i = 1, #txt do
      local char_w = style.code_font:get_width(txt:sub(i, i))
      if x < text_x + w + char_w / 2 then break end
      w = w + char_w
      col = i + 1
    end
  end
  return line, col
end

function TermView:get_url_at(x, y)
  local line, col = self:resolve_position(x, y)
  local s = self:state()
  if not s then return nil end

  local txt = ""
  if s.term then
    local row = s.term:get_absolute_line(line)
    if not row then return nil end
    local chars = {}
    -- PTY rows are arrays of cell objects
    for i = 1, s.term.cols do
      if not row[i] then break end
      table.insert(chars, row[i].char)
    end
    txt = table.concat(chars)
  elseif s.lines and s.lines[line] then
    txt = strip_ansi(s.lines[line].text)
  else
    return nil
  end
  
  local i = 1
  while true do
    local s_idx, e_idx, url = txt:find("(https?://[%w-_%.%?%.:/%+=&]+)", i)
    if not s_idx then break end
    if col >= s_idx and col <= e_idx then
      return url
    end
    i = e_idx + 1
  end
  return nil
end

function TermView:draw_port_manager(x, y, w, h)
  local s = self:state()
  local cx, cy = x + 20 * SCALE, y + 20 * SCALE
  
  -- Header
  local title_font = style.big_font or style.font
  renderer.draw_text(title_font, "PORT MANAGER", cx, cy, style.accent or {common.color "#E67E80"})
  
  -- Refresh button
  local ref_w = style.font:get_width("Refresh") + 20*SCALE
  local ref_h = 24*SCALE
  local ref_x = cx + w - 40*SCALE - ref_w
  s.refresh_btn_rect = { x = ref_x, y = cy, w = ref_w, h = ref_h }
  local ref_bg = style.background3 or {common.color "#444444"}
  renderer.draw_rect(ref_x, cy, ref_w, ref_h, ref_bg)
  renderer.draw_text(style.font, "Refresh", ref_x + 10*SCALE, cy + math.floor((ref_h - style.font:get_height())/2), style.text)
  
  -- Kill Selected button
  local kill_sel_w = style.font:get_width("Kill Selected") + 20*SCALE
  local kill_sel_x = ref_x - kill_sel_w - 10*SCALE
  s.kill_sel_btn_rect = { x = kill_sel_x, y = cy, w = kill_sel_w, h = ref_h }
  renderer.draw_rect(kill_sel_x, cy, kill_sel_w, ref_h, {common.color "#FB4934"})
  renderer.draw_text(style.font, "Kill Selected", kill_sel_x + 10*SCALE, cy + math.floor((ref_h - style.font:get_height())/2), {255, 255, 255, 255})
  
  -- Port Forwarding button
  local pf_btn_w = style.font:get_width("Port Forwarding") + 20*SCALE
  local pf_btn_x = kill_sel_x - pf_btn_w - 10*SCALE
  s.pf_btn_rect = { x = pf_btn_x, y = cy, w = pf_btn_w, h = ref_h }
  renderer.draw_rect(pf_btn_x, cy, pf_btn_w, ref_h, style.accent or {common.color "#E67E80"})
  renderer.draw_text(style.font, "Port Forwarding", pf_btn_x + 10*SCALE, cy + math.floor((ref_h - style.font:get_height())/2), {255, 255, 255, 255})
  
  cy = cy + 40*SCALE
  
  -- Search Box
  local search_h = 24*SCALE
  local search_w = math.min(w - 40*SCALE, 400*SCALE)
  renderer.draw_rect(cx, cy, search_w, search_h, style.background3 or {common.color "#444444"})
  
  local placeholder = "Search ports/process..."
  local display_text = (s.input and #s.input > 0) and s.input or placeholder
  local text_color = (s.input and #s.input > 0) and style.text or style.dim
  renderer.draw_text(style.font, display_text, cx + 10*SCALE, cy + math.floor((search_h - style.font:get_height())/2), text_color)
  
  if core.active_view == self and (system.get_time() % 1 < 0.5) then
    local cursor_x = cx + 10*SCALE + style.font:get_width(s.input:sub(1, (s.cursor or (#s.input + 1)) - 1))
    renderer.draw_rect(cursor_x, cy + 4*SCALE, 2*SCALE, search_h - 8*SCALE, style.accent or {common.color "#A9DC76"})
  end
  
  cy = cy + 40*SCALE
  
  if s.fetching then
    renderer.draw_text(style.font, "Scanning active ports...", cx, cy, style.dim)
    return
  end
  
  if not s.ports or #s.ports == 0 then
    renderer.draw_text(style.font, "No listening ports found.", cx, cy, style.dim)
    return
  end
  
  -- Filter ports
  local filter_text = (s.input or ""):lower()
  s.filtered_ports = {}
  for _, p in ipairs(s.ports) do
    if filter_text == "" or p.port:lower():find(filter_text, 1, true) or p.name:lower():find(filter_text, 1, true) then
      table.insert(s.filtered_ports, p)
    end
  end
  
  if #s.filtered_ports == 0 then
    renderer.draw_text(style.font, "No matches found.", cx, cy, style.dim)
    return
  end
  
  -- Table Header
  local c_check = cx
  local c_port = cx + 40*SCALE
  local c_name = cx + 120*SCALE
  local c_pid = cx + 370*SCALE
  local c_act = cx + 470*SCALE
  
  -- Select All Button
  local sa_w = 14*SCALE
  s.select_all_btn_rect = { x = c_check, y = cy + math.floor((style.font:get_height() - sa_w)/2), w = sa_w, h = sa_w }
  renderer.draw_rect(s.select_all_btn_rect.x, s.select_all_btn_rect.y, sa_w, sa_w, style.dim)
  
  local any_unsel = false
  for _, p in ipairs(s.filtered_ports) do
    if not (s.selected_ports and s.selected_ports[p.pid]) then any_unsel = true break end
  end
  if not any_unsel and #s.filtered_ports > 0 then
    renderer.draw_rect(s.select_all_btn_rect.x + 2*SCALE, s.select_all_btn_rect.y + 2*SCALE, sa_w - 4*SCALE, sa_w - 4*SCALE, style.accent or {common.color "#E67E80"})
  end
  
  renderer.draw_text(style.font, "PORT", c_port, cy, style.dim)
  renderer.draw_text(style.font, "PROCESS", c_name, cy, style.dim)
  renderer.draw_text(style.font, "PID", c_pid, cy, style.dim)
  renderer.draw_text(style.font, "ACTION", c_act, cy, style.dim)
  
  cy = cy + 30*SCALE
  renderer.draw_rect(cx, cy, w - 40*SCALE, 1*SCALE, style.dim)
  cy = cy + 10*SCALE
  
  s.port_buttons = {}
  s.checkbox_rects = {}
  
  local lh = 30 * SCALE
  local max_scroll = math.max(0, #s.filtered_ports * lh - (h - cy - 20*SCALE))
  s.scroll_y = math.min(math.max(0, s.scroll_y or 0), max_scroll)
  
  core.push_clip_rect(x, cy, w, h - (cy - y))
  local item_y = cy - s.scroll_y
  
  for i, p in ipairs(s.filtered_ports) do
    if item_y + lh > cy and item_y < y + h then
      -- Checkbox
      local cb_size = 14*SCALE
      local cb_y = item_y + math.floor((lh - cb_size)/2)
      table.insert(s.checkbox_rects, { x = c_check, y = cb_y, w = cb_size, h = cb_size, pid = p.pid })
      renderer.draw_rect(c_check, cb_y, cb_size, cb_size, style.dim)
      if s.selected_ports and s.selected_ports[p.pid] then
        renderer.draw_rect(c_check + 2*SCALE, cb_y + 2*SCALE, cb_size - 4*SCALE, cb_size - 4*SCALE, style.accent or {common.color "#E67E80"})
      end
      
      renderer.draw_text(style.font, tostring(p.port), c_port, item_y, style.text)
      renderer.draw_text(style.font, tostring(p.name), c_name, item_y, style.text)
      renderer.draw_text(style.font, tostring(p.pid), c_pid, item_y, style.dim)
      
      -- Kill button
      local btn_w = style.font:get_width("KILL") + 16*SCALE
      local btn_h = 20*SCALE
      local btn_x = c_act
      local btn_y = item_y + math.floor((lh - btn_h)/2)
      
      table.insert(s.port_buttons, { x = btn_x, y = btn_y, w = btn_w, h = btn_h, pid = p.pid, pids = p.pids, port = p.port })
      
      renderer.draw_rect(btn_x, btn_y, btn_w, btn_h, {common.color "#FB4934"})
      renderer.draw_text(style.font, "KILL", btn_x + 8*SCALE, btn_y + math.floor((btn_h - style.font:get_height())/2), {255, 255, 255, 255})
    end
    item_y = item_y + lh
  end
  
  core.pop_clip_rect()
end

-- ── Input ──────────────────────────────────────────────────────────────────────
function TermView:scroll_to_end()
  local s = self:state()
  if not s then return end
  s.scroll_to_bottom = true
  local lh = style.code_font:get_height() + 2 * SCALE
  local out_h = self.size.y - 31 * SCALE
  local total_lines = s.term and (#s.term.scrollback + s.term.rows) or (#s.lines + 1)
  s.scroll_y = math.max(0, total_lines * lh - out_h + 10 * SCALE)
  core.redraw = true
end

function TermView:on_text_input(text)
  local s = self:state()
  if s.shell.is_port_manager then
    s.cursor = s.cursor or (#s.input + 1)
    s.input = s.input:sub(1, s.cursor - 1) .. text .. s.input:sub(s.cursor)
    s.cursor = s.cursor + #text
    self:scroll_to_end()
  elseif s.proc and s.proc:running() then
    s.proc:write(text)
  end
end

function TermView:on_key_pressed(key)
  local s = self:state()
  if not s.shell.is_port_manager then
    if not s.proc or not s.proc:running() then return false end
    local seq = nil
    if key == "up" then seq = "\27[A"
    elseif key == "down" then seq = "\27[B"
    elseif key == "right" then seq = "\27[C"
    elseif key == "left" then seq = "\27[D"
    elseif key == "return" then seq = "\r"
    elseif key == "backspace" then seq = "\8"
    elseif key == "escape" then seq = "\27"
    elseif key == "tab" then seq = "\t"
    elseif key == "ctrl+c" then seq = "\3"
    elseif key == "ctrl+v" or key == "shift+insert" then 
      local text = system.get_clipboard()
      if text then 
        text = text:gsub("\r\n", "\r"):gsub("\n", "\r")
        s.proc:write(text) 
      end
      return true
    end
    if seq then
      s.proc:write(seq)
      return true
    end
    if key == "pageup" then
      local lh = style.code_font:get_height() + 2 * SCALE
      s.scroll_y = math.max(0, s.scroll_y - lh * 8)
      s.scroll_to_bottom = false
      core.redraw = true
      return true
    end
    if key == "pagedown" then
      local lh = style.code_font:get_height() + 2 * SCALE
      s.scroll_y = s.scroll_y + lh * 8
      s.scroll_to_bottom = false
      core.redraw = true
      return true
    end
    return false
  end

  if key == "return" then return true end
  if key == "backspace" then
    local text = s.input
    local cursor = s.cursor or (#text + 1)
    if #text > 0 and cursor > 1 then
      local i = cursor - 1
      while i > 0 and i <= #text and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do i = i - 1 end
      s.input = text:sub(1, i - 1) .. text:sub(cursor)
      s.cursor = i
    end
    return true
  end
  if key == "delete" then
    local text = s.input
    local cursor = s.cursor or (#text + 1)
    if cursor <= #text then
      local i = cursor + 1
      while i <= #text and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do i = i + 1 end
      s.input = text:sub(1, cursor - 1) .. text:sub(i)
    end
    return true
  end
  if key == "left" then
    s.cursor = utf8_prev_index(s.input, s.cursor or (#s.input + 1))
    core.redraw = true
    return true
  end
  if key == "right" then
    s.cursor = utf8_next_index(s.input, s.cursor or (#s.input + 1))
    core.redraw = true
    return true
  end
  if key == "home" then
    s.cursor = 1
    core.redraw = true
    return true
  end
  if key == "end" then
    s.cursor = #s.input + 1
    core.redraw = true
    return true
  end
  return false
end


function TermView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    local s = self:state()
    if s and s.shell.is_port_manager then
      if s.refresh_btn_rect then
        local r = s.refresh_btn_rect
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
          self:refresh_ports(s)
          return true
        end
      end
      if s.kill_sel_btn_rect then
        local r = s.kill_sel_btn_rect
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
          for pid, sel in pairs(s.selected_ports or {}) do
            if sel then
              core.log("Killing process %s...", pid)
              if PLATFORM == "Windows" then os.execute("taskkill /F /T /PID " .. pid) end
            end
          end
          self:refresh_ports(s)
          return true
        end
      end
      if s.pf_btn_rect then
        local r = s.pf_btn_rect
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
          command.perform("port_forward:toggle")
          return true
        end
      end
      if s.select_all_btn_rect then
        local r = s.select_all_btn_rect
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
          s.selected_ports = s.selected_ports or {}
          local any_unsel = false
          for _, p in ipairs(s.filtered_ports or s.ports or {}) do
            if not s.selected_ports[p.pid] then any_unsel = true break end
          end
          for _, p in ipairs(s.filtered_ports or s.ports or {}) do
            s.selected_ports[p.pid] = any_unsel
          end
          core.redraw = true
          return true
        end
      end
      if s.checkbox_rects then
        for _, cb in ipairs(s.checkbox_rects) do
          if x >= cb.x and x <= cb.x + cb.w and y >= cb.y and y <= cb.y + cb.h then
            s.selected_ports = s.selected_ports or {}
            s.selected_ports[cb.pid] = not s.selected_ports[cb.pid]
            core.redraw = true
            return true
          end
        end
      end
      if s.port_buttons then
        for _, btn in ipairs(s.port_buttons) do
          if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            core.log("Killing process %s on port %s...", btn.pid, btn.port)
            if PLATFORM == "Windows" then
              os.execute("taskkill /F /T /PID " .. btn.pid)
            end
            self:refresh_ports(s)
            return true
          end
        end
      end
      -- Fall through allows focus/clicking inside the terminal input logic if needed
    end

    local hdr_h = 26 * SCALE
    local out_top = self.position.y + hdr_h + 3 * SCALE
    if y > out_top then
      local right_w = 0
      if self.show_sidebar ~= false then
        local max_w = 100 * SCALE
        local num_terms = 0
        for i, sess in ipairs(self.sessions) do 
          if not sess.shell.is_port_manager then 
            num_terms = num_terms + 1 
            local title_w = style.font:get_width("├─ " .. (sess.shell.name or ("Term " .. i))) + 30 * SCALE
            if title_w > max_w then max_w = title_w end
          end 
        end
        if num_terms > 1 then right_w = max_w end
      end
      if self:state() and self:state().shell.is_port_manager then right_w = 0 end
      
      local available_w = self.size.x - right_w
      
      if right_w > 0 and x - self.position.x > available_w then
        -- Let fall through to sidebar click handler
      else
        local col_w = math.floor(available_w / #self.split_indices)
        local col_idx = math.floor((x - self.position.x) / col_w) + 1
        col_idx = common.clamp(col_idx, 1, #self.split_indices)
        self.active_idx = self.split_indices[col_idx]
        core.redraw = true
  
        local url = self:get_url_at(x, y)
        if url then
          if PLATFORM == "Windows" then
            os.execute('start "" "' .. url .. '"')
          elseif PLATFORM == "Mac OS X" then
            os.execute('open "' .. url .. '"')
          else
            os.execute('xdg-open "' .. url .. '"')
          end
          return true
        end
        
        local l, c = self:resolve_position(x, y)
        if s then
          s.selection = { l1 = l, c1 = c, l2 = l, c2 = c }
          self.dragging_selection = true
        end
        core.redraw = true
        return true
      end
    end
    if self.terminal_tab_rect then
      local r = self.terminal_tab_rect
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        if s and s.shell.is_port_manager then
          local found = false
          for i, sess in ipairs(self.sessions) do
            if not sess.shell.is_port_manager then self.active_idx = i; found = true; break end
          end
          if not found then self:add_session(shells[1]) end
        end
        core.redraw = true
        return true
      end
    end
    
    if self.ports_tab_rect then
      local r = self.ports_tab_rect
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        local found = false
        for i, sess in ipairs(self.sessions) do
          if sess.shell.is_port_manager then self.active_idx = i; found = true; break end
        end
        if not found then self:add_session({ name = "Port Manager", is_port_manager = true }) end
        core.redraw = true
        return true
      end
    end

    for i, sess in ipairs(self.sessions) do
      if sess.tab_rect then
        local r = sess.tab_rect
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
          -- Check if clicked session is already in the active split view
          local found_in_split = false
          for split_col, s_idx in ipairs(self.split_indices) do
            if s_idx == i then found_in_split = true break end
          end
          
          -- If it's a hidden session, swap it into the currently active split column!
          if not found_in_split then
             for split_col, s_idx in ipairs(self.split_indices) do
               if s_idx == self.active_idx then
                 self.split_indices[split_col] = i
                 break
               end
             end
          end
          
          local swapped = false
          for split_col, s_idx in ipairs(self.split_indices) do
            if s_idx == self.active_idx then
              self.split_indices[split_col] = i
              swapped = true
              break
            end
          end
          if not swapped then self.split_indices[1] = i end
          self.active_idx = i
          core.redraw = true
          return true
        end
      end
    end

    if self.right_btns then
      for _, b in ipairs(self.right_btns) do
        if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
          if b.name == "hide" then
            command.perform("terminal:toggle")
          elseif b.name == "sidebar" then
            self.show_sidebar = not (self.show_sidebar ~= false)
            core.redraw = true
          elseif b.name == "maximize" then
            command.perform("terminal:fullscreen")
          elseif b.name == "trash" then
            if self:state().proc then pcall(function() self:state().proc:kill() end) end
            for i, sess_idx in ipairs(self.split_indices) do
              if sess_idx == self.active_idx then table.remove(self.split_indices, i) break end
            end
            table.remove(self.sessions, self.active_idx)
            for i, sess_idx in ipairs(self.split_indices) do
              if sess_idx > self.active_idx then self.split_indices[i] = sess_idx - 1 end
            end
            if #self.split_indices == 0 then
              if #self.sessions > 0 then self.split_indices = {1} self.active_idx = 1
              else command.perform("terminal:toggle") end
            else self.active_idx = self.split_indices[#self.split_indices] end
          elseif b.name == "add" then
            core.command_view:enter("Select Shell to Open", {
              submit = function(text, item)
                self:add_session(item.shell)
                self.split_indices = { #self.sessions }
                self.active_idx = #self.sessions
                core.redraw = true
              end,
              suggest = function(text)
                local res = {}
                for i, sh in ipairs(shells) do
                  table.insert(res, { text = sh.name, shell = sh })
                end
                return res
              end
            })
          elseif b.name == "split" then
            core.command_view:enter("Select Shell to Split", {
              submit = function(text, item)
                self:add_session(item.shell)
                table.insert(self.split_indices, #self.sessions)
                self.active_idx = #self.sessions
                core.redraw = true
              end,
              suggest = function(text)
                local res = {}
                for i, sh in ipairs(shells) do
                  table.insert(res, { text = sh.name, shell = sh })
                end
                return res
              end
            })
          elseif b.name == "dropdown" then
            core.command_view:enter("Switch Terminal", {
              submit = function(text, item)
                self.active_idx = item.idx
                core.redraw = true
              end,
              suggest = function(text)
                local res = {}
                for i, sess in ipairs(self.sessions) do
                  if not sess.shell.is_port_manager then 
                    table.insert(res, { text = tostring(i) .. ": " .. sess.shell.name, idx = i }) 
                  end
                end
                return res
              end
            })
          end
          core.redraw = true
          return true
        end
      end
    end
  end
  return false
end


function TermView:on_mouse_moved(x, y, dx, dy)
  if self.dragging_selection then
    local l, c = self:resolve_position(x, y)
    local st = self:state()
    if st then
      if not st.selection then st.selection = { l1 = l, c1 = c, l2 = l, c2 = c } end
      st.selection.l2 = l
      st.selection.c2 = c
    end
    core.redraw = true
    return true
  end

  local hdr_h = 26 * SCALE
  local out_top = self.position.y + hdr_h + 3 * SCALE
    if y > out_top then
      local right_w = 0
      if self.show_sidebar ~= false then
        local max_w = 100 * SCALE
        local num_terms = 0
        for i, sess in ipairs(self.sessions) do 
          if not sess.shell.is_port_manager then 
            num_terms = num_terms + 1 
            local title_w = style.font:get_width("├─ " .. (sess.shell.name or ("Term " .. i))) + 30 * SCALE
            if title_w > max_w then max_w = title_w end
          end 
        end
        if num_terms > 1 then right_w = max_w end
      end
      if self:state() and self:state().shell.is_port_manager then right_w = 0 end
      
      local available_w = self.size.x - right_w
      
      if right_w > 0 and x - self.position.x > available_w then
        -- Let fall through to sidebar click handler
      else
        local col_w = math.floor(available_w / #self.split_indices)
        local col_idx = math.floor((x - self.position.x) / col_w) + 1
        col_idx = common.clamp(col_idx, 1, #self.split_indices)
        -- Only change focus if we actually want focus-follows-mouse, but usually click is better.
        -- self.active_idx = self.split_indices[col_idx] 
        -- core.redraw = true
  
        local url = self:get_url_at(x, y)
        if url then
          system.set_cursor("hand")
        else
          system.set_cursor("ibeam")
        end
        return false
      end
    end
  return false
end

function TermView:on_mouse_released(button, x, y)
  if button == "left" then
    self.dragging_selection = false
  end
end

function TermView:on_mouse_wheel(dy, dx)
  local s = self:state()
  if s.is_port_manager then
    s.scroll_y = math.max(0, (s.scroll_y or 0) - dy * 40)
    return true
  end

  local lh = style.code_font:get_height() + 2 * SCALE
  s.scroll_y = math.max(0, s.scroll_y - dy * lh * 3)
  
  -- Clamp scroll
  local total = s.term and (#s.term.scrollback + s.term.rows) * lh or (#s.lines + 1) * lh
  local inner = math.max(0, self.size.y - 31 * SCALE)
  local max_scroll = math.max(0, total - inner)
  s.scroll_y = math.max(0, math.min(max_scroll, s.scroll_y))
  
  dx = dx or 0
  s.scroll_x = math.max(0, (s.scroll_x or 0) - dx * 40)
  
  s.scroll_to_bottom = false
  core.redraw = true
  return true
end

-- ── Toggle (size-based, like built-in treeview — no node removal needed) ──────
command.add(nil, {
  ["terminal:toggle"] = function()
    if not instance then
      instance = TermView()
    end

    if not node_built then
      -- First time: insert into node tree via split
      local target = core.root_view:get_active_node_default()
      -- resizable=true makes the top divider draggable by the user
      local new_node = target:split("down", instance, { y = true }, true)
      if new_node then
        new_node.size.y = 0   -- start at 0; update() will animate to target
        instance.size.y = 0
      end
      node_built = true
    end

    -- Toggle visibility (size animates to 0 or target_height)
    instance.visible = not instance.visible
    if instance.visible then
      if #instance.sessions == 0 then
        instance:add_session(shells[1])
        instance.split_indices = { 1 }
        instance.active_idx = 1
      end
      core.set_active_view(instance)
    else
      -- Return focus to editor
      local views = core.root_view.root_node:get_children()
      for _, v in ipairs(views) do
        if v ~= instance and v.doc then
          core.set_active_view(v)
          break
        end
      end
    end
    core.redraw = true
  end,

  ["terminal:focus"] = function()
    if not instance or not node_built or not instance.visible then
      command.perform "terminal:toggle"
    end
    if instance and instance.visible then core.set_active_view(instance) end
  end,

  
  ["terminal:copy"] = function()
    if not instance or not instance.visible or not instance:state().selection then return end
    local s = instance:state()
    local sel = s.selection
    local l1, c1, l2, c2 = sort_positions(sel.l1, sel.c1, sel.l2, sel.c2)
    local res = {}
    for i = l1, l2 do
      local txt = ""
      if s.term then
        local row = s.term:get_absolute_line(i)
        if row then
          local chars = {}
          for c = 1, s.term.cols do
            if row[c] then table.insert(chars, row[c].char) end
          end
          txt = table.concat(chars)
          -- trim trailing whitespace
          txt = txt:gsub("%s+$", "")
        end
      else
        if i <= #s.lines then 
          txt = strip_ansi(s.lines[i].text or "")
        else
          local prompt = get_prompt(s)
          txt = strip_ansi(prompt .. s.input)
        end
      end
      local sc = (i == l1) and c1 or 1
      local ec = (i == l2) and c2 - 1 or #txt
      table.insert(res, txt:sub(sc, ec))
    end
    system.set_clipboard(table.concat(res, "\n"))
  end,

  ["terminal:fullscreen"] = function()
    if not instance then instance = TermView() end
    if not node_built then command.perform("terminal:toggle") end
    
    if not instance.visible then
      instance.visible = true
      if #instance.sessions == 0 then
        instance:add_session(shells[1])
        instance.split_indices = { 1 }
        instance.active_idx = 1
      end
      core.set_active_view(instance)
    end

    instance.is_fullscreen = not instance.is_fullscreen
    if not instance.is_fullscreen then
      instance.target_size = config.terminal.target_height * SCALE
    end
    core.redraw = true
  end,
})

-- Global shortcut for fullscreen
local keymap = require "core.keymap"
keymap.add {
  ["ctrl+shift+`"] = "terminal:fullscreen",
}

keymap.add {
  ["ctrl+`"] = "terminal:toggle",
}



keymap.add {
  ["ctrl+shift+c"] = "terminal:copy",
}

-- Bind local commands that only activate when Terminal is focused
command.add(
  function() return core.active_view == instance end,
  {
    ["terminal:return"]    = function() instance:on_key_pressed("return") end,
    ["terminal:backspace"] = function() instance:on_key_pressed("backspace") end,
    ["terminal:interrupt"] = function() instance:on_key_pressed("ctrl+c") end,
    ["terminal:clear"]     = function() instance:on_key_pressed("ctrl+l") end,
    ["terminal:scroll-up"] = function() instance:on_key_pressed("pageup") end,
    ["terminal:scroll-down"] = function() instance:on_key_pressed("pagedown") end,
    ["terminal:history-up"] = function() instance:on_key_pressed("up") end,
    ["terminal:history-down"] = function() instance:on_key_pressed("down") end,
    ["terminal:cursor-left"] = function() instance:on_key_pressed("left") end,
    ["terminal:cursor-right"] = function() instance:on_key_pressed("right") end,
    ["terminal:cursor-home"] = function() instance:on_key_pressed("home") end,
    ["terminal:cursor-end"] = function() instance:on_key_pressed("end") end,
    ["terminal:delete"] = function() instance:on_key_pressed("delete") end,
    ["terminal:paste"] = function()
      local text = system.get_clipboard()
      if text then
        text = text:gsub("\r", "")
        instance:on_text_input(text)
      end
    end,
  }
)

keymap.add {
    ["return"]    = "terminal:return",
    ["backspace"] = "terminal:backspace",
    ["ctrl+c"]    = "terminal:interrupt",
    ["ctrl+l"]    = "terminal:clear",
    ["ctrl+v"]    = "terminal:paste",
    ["shift+insert"] = "terminal:paste",
    ["pageup"]    = "terminal:scroll-up",
    ["pagedown"]  = "terminal:scroll-down",
  ["up"]        = "terminal:history-up",
  ["down"]      = "terminal:history-down",
  ["left"]      = "terminal:cursor-left",
  ["right"]     = "terminal:cursor-right",
  ["home"]      = "terminal:cursor-home",
  ["end"]       = "terminal:cursor-end",
  ["delete"]    = "terminal:delete",
}

-- Hook into core.quit to kill any zombie background processes when Lite-XL exits
local old_quit = core.quit
function core.quit(force)
  if TermView.instances then
    for _, tv in ipairs(TermView.instances) do
      if tv.sessions then
        for _, s in ipairs(tv.sessions) do
          if s.proc then pcall(function() s.proc:kill() end) end
        end
      end
    end
  end
  return old_quit(force)
end

-- ── Error Line Marker Extractor ──────────────────────────────────────────────
local DocView = require "core.docview"
local old_draw_line_gutter = DocView.draw_line_gutter
local terminal_errors = {}
local first_error_jumped = false

local old_termview_update = TermView.update
local last_scanned_line = 0
local last_session_ptr = nil

function TermView:update(...)
  if old_termview_update then old_termview_update(self, ...) end
  local s = self:state()
  if not s then return end

  if last_session_ptr ~= s then
    last_scanned_line = s.lines and #s.lines or 0
    last_session_ptr = s
  end

  -- Throttle error scanning per-session to every 500ms
  local now = system.get_time()
  if now - (s.last_scan_time or 0) < 0.5 then return end
  s.last_scan_time = now

  if s.lines and #s.lines > last_scanned_line then
    for i = last_scanned_line + 1, #s.lines do
      local line_text = s.lines[i].text
      if line_text then
        local file, lnum
        -- 1. Python: File "script.py", line 42
        file, lnum = line_text:match('File "([^"]+)", line (%d+)')
        -- 2. Windows absolute paths (C:\foo\bar.c:42:)
        if not file then file, lnum = line_text:match('([%a]:\\[^:]+%.%w+):(%d+):') end
        -- 3. Generic (C/C++, Rust, Lua, Go, Ruby): src/main.c:42:5: error:
        if not file then file, lnum = line_text:match('([%w%._/\\-]+%.%w+):(%d+):') end
        -- 4. Node.js stack trace with Windows path
        if not file then file, lnum = line_text:match('%(([%a]:\\[^:]+%.%w+):(%d+):%d+%)') end
        -- 5. Node.js stack trace generic
        if not file then file, lnum = line_text:match('%(([%w%._/\\-]+%.%w+):(%d+):%d+%)') end
        -- 6. Java stack trace
        if not file then file, lnum = line_text:match('at .*%(([%w%._/\\-]+%.java):(%d+)%)') end
        -- 7. C# stack trace
        if not file then file, lnum = line_text:match('in ([%w%._/\\-]+%.cs):line (%d+)') end

        if file and lnum then
          lnum = tonumber(lnum)
          local abs = system.absolute_path(file)
          if not abs then
            local full = core.project_dir .. PATHSEP .. file
            local info = system.get_file_info(full)
            if info then abs = full end
          end
          if abs then
            terminal_errors[abs] = terminal_errors[abs] or {}
            terminal_errors[abs][lnum] = true
            core.redraw = true
            
            -- Automatically jump to the FIRST error found in this session
            if not first_error_jumped then
              first_error_jumped = true
              core.try(function()
                local doc = core.open_doc(abs)
                core.root_view:open_doc(doc)
                if core.active_view and core.active_view.doc == doc then
                  core.active_view.doc:set_selection(lnum, 1)
                  core.active_view:scroll_to_line(lnum, true)
                end
              end)
            end
          end
        end
      end
    end
    last_scanned_line = #s.lines
  end
end

local old_termview_run = TermView.run
function TermView:run(cmd, ...)
  terminal_errors = {}
  first_error_jumped = false
  return old_termview_run(self, cmd, ...)
end

function DocView:draw_line_gutter(line, x, y, width)
  local res = old_draw_line_gutter(self, line, x, y, width)
  local abs = self.doc.abs_filename
  if abs and terminal_errors[abs] and terminal_errors[abs][line] then
    local color = style.error or {255, 50, 50, 255}
    local icon = "" -- Warning/Error icon in Nerd Font
    -- Draw next to the line number
    renderer.draw_text(style.icon_font, icon, x + math.max(0, width - 15 * SCALE), y, color)
  end
  return res
end

local Node = require("core.node")

local old_node_draw_tabs_term = Node.draw_tabs
function Node:draw_tabs(...)
  if self.active_view and self.active_view.is and self.active_view:is(TermView) and #self.views == 1 then
    return
  end
  return old_node_draw_tabs_term(self, ...)
end

if Node.get_tab_height then
  local old_node_get_tab_height_term = Node.get_tab_height
  function Node:get_tab_height(...)
    if self.active_view and self.active_view.is and self.active_view:is(TermView) and #self.views == 1 then
      return 0
    end
    return old_node_get_tab_height_term(self, ...)
  end
else
  function TermView:get_tab_height()
    return 0
  end
end

return { TermView = TermView, get_instance = function() return instance end }
