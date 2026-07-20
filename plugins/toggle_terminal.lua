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
  table.insert(shells, { name = "PowerShell", cmd = {"powershell.exe", "-NoProfile", "-Command"}, prompt_prefix = "PS " })
  table.insert(shells, { name = "Command Prompt", cmd = {"cmd.exe", "/c"}, prompt_prefix = "" })

  local sys = require "system"
  if sys.get_file_info("C:\\Program Files\\Git\\bin\\bash.exe") then
    table.insert(shells, { name = "Git Bash", cmd = {"C:\\Program Files\\Git\\bin\\bash.exe", "-c"}, prompt_prefix = "" })
  end
  if sys.get_file_info("C:\\Windows\\System32\\wsl.exe") then
    table.insert(shells, { name = "WSL", cmd = {"C:\\Windows\\System32\\wsl.exe", "-e", "bash", "-c"}, prompt_prefix = "" })
  end
else
  local function has_cmd(c) return os.execute("command -v " .. c .. " >/dev/null 2>&1") == 0 end
  if has_cmd("bash") then table.insert(shells, { name = "bash", cmd = {"bash", "-c"}, prompt_prefix = "" }) end
  if has_cmd("zsh") then table.insert(shells, { name = "zsh", cmd = {"zsh", "-c"}, prompt_prefix = "" }) end
  table.insert(shells, { name = "sh", cmd = {"sh", "-c"}, prompt_prefix = "" })
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
  }
  table.insert(self.sessions, s)
  self.active_idx = #self.sessions
  if shell_opts.is_port_manager then
    self:refresh_ports(s)
  else
    self:_push("info", shell_opts.name)
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
            coroutine.yield(0.01)
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
            coroutine.yield(0.01)
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

  local right_w = (self.show_sidebar ~= false) and (150 * SCALE) or 0
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
      if #s.lines > (config.terminal.scrollback or 500) then
        table.remove(s.lines, 1)
      end
    elseif b == 13 then -- \r
      last_line.text = ""
      s.vis_len = 0
      i = i + 1
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
        if #s.lines > (config.terminal.scrollback or 500) then
          table.remove(s.lines, 1)
        end
      end
    end
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
  
  for _, s in ipairs(self.sessions) do
    if s.proc then
      local has_chunk = false
      local loops = 0
      while loops < 64 do
        local chunk = s.proc:read_stdout(4096)
        if chunk and #chunk > 0 then
          has_chunk = true
          s.out_buf = (s.out_buf or "") .. chunk
          self:_push_chunk("info", chunk, false)
        else
          break
        end
        loops = loops + 1
      end
      
      loops = 0
      while loops < 64 do
        local err_chunk = s.proc.read_stderr and s.proc:read_stderr(4096) or nil
        if err_chunk and #err_chunk > 0 then
          has_chunk = true
          self:_push_chunk("err", err_chunk, false)
        else
          break
        end
        loops = loops + 1
      end
      
      if not has_chunk and not s.proc:running() then
        s.proc = nil
      end
    end
  end
end

function TermView:draw()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  self:draw_background(style.background2 or style.background)
  
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  
  -- Header Background
  local hdr_h = 26 * SCALE
  renderer.draw_rect(x, y, w, hdr_h, style.background or style.background3)
  
  -- Header Divider
  renderer.draw_rect(x, y + hdr_h - 1 * SCALE, w, 1 * SCALE, style.divider or {common.color("#444444")})
  
  -- Draw TERMINAL and PORTS major tabs
  local tx = x + 10 * SCALE
  local is_pm_active = self:state() and self:state().shell.is_port_manager
  
  -- TERMINAL Tab
  local term_txt = "TERMINAL"
  local term_w = style.font:get_width(term_txt) + 20 * SCALE
  local term_col = not is_pm_active and style.text or style.dim
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
  
  local fg = style.text
  local col_err = style.error or {common.color("#ff5555")}
  local col_inf = style.accent or {common.color("#55ff55")}
  local border = style.divider or {common.color("#444444")}
  
  -- The split drawing loop
  local right_w = (self.show_sidebar ~= false) and (150 * SCALE) or 0
  if self:state() and self:state().shell.is_port_manager then right_w = 0 end
  
  local available_w = w - right_w
  local col_w = math.floor(available_w / #self.split_indices)
  local lh = style.code_font:get_height() + 2 * SCALE

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

    local lines = s.lines
    local first_vi = math.floor((text_y - out_top) / lh) + 1
    local last_vi  = math.ceil((out_bot - text_y) / lh) + 1
    first_vi = common.clamp(first_vi, 1, #lines + 1)
    last_vi  = common.clamp(last_vi, first_vi, #lines)
    if #lines > 0 then
      for i = first_vi, last_vi do
        local ln = lines[i]
        if ln then
          local line_y = text_y + (i - 1) * lh
          if sel and i >= sel_l1 and i <= sel_l2 then
             local txt = ln.text
             local col1 = (i == sel_l1) and sel_c1 or 1
             local col2 = (i == sel_l2) and sel_c2 or (#txt + 1)
             local x1 = text_x + style.code_font:get_width(txt:sub(1, col1 - 1))
             local sw = style.code_font:get_width(txt:sub(col1, col2 - 1))
             if i < sel_l2 and col2 == #txt + 1 then sw = sw + style.code_font:get_width(" ") end
             renderer.draw_rect(x1, line_y, sw, lh, style.selection or {255, 255, 255, 60})
          end
          local col = ln.kind == "cmd"  and fg
                   or ln.kind == "err"  and col_err
                   or ln.kind == "info" and col_inf
                   or fg
          draw_ansi_text(style.code_font, ln.text, text_x, line_y, col)
        end
      end
    end
    text_y = text_y + #lines * lh

    if text_y <= out_bot then
      local prompt = get_prompt(s)
      if s.proc and s.out_buf then
        local clean = s.out_buf:gsub("\r$", "")
        prompt = prompt .. clean
      end
      
      local full_txt = prompt .. (s.input or "")
      draw_ansi_text(style.code_font, full_txt, text_x, text_y, fg)
      
      if core.active_view == self and sess_idx == self.active_idx then
        local abs_cursor = #strip_ansi(prompt) + (s.cursor or (#(s.input or "") + 1))
        local left_txt = strip_ansi(full_txt):sub(1, abs_cursor - 1)
        local cx = text_x + style.code_font:get_width(left_txt)
        local cy = text_y
        if system.get_time() % 1 < 0.5 and cy <= out_bot then
          renderer.draw_rect(cx, cy, style.code_font:get_width("M"), style.code_font:get_height(), { common.color("#A9DC76", 180) })
        end
      end
    end
    core.pop_clip_rect()
    ::continue::
  end

  if right_w > 0 then
    local rx = x + w - right_w
    renderer.draw_rect(rx, out_top, right_w, out_h, style.background2)
    renderer.draw_rect(rx, out_top, 1 * SCALE, out_h, style.divider or {common.color("#444444")})
    local ry = out_top
    -- First draw grouped split sessions
    for split_col, i in ipairs(self.split_indices) do
      local sess = self.sessions[i]
      if not sess or sess.shell.is_port_manager then goto skip_vsplit end
      local is_focused = (i == self.active_idx)
      local bg_color = is_focused and (style.background3 or style.background) or style.background2
      renderer.draw_rect(rx + 1 * SCALE, ry, right_w - 1 * SCALE, 26 * SCALE, bg_color)
      renderer.draw_rect(rx + 1 * SCALE, ry, 2 * SCALE, 26 * SCALE, style.accent or {common.color("#A9DC76")})
      
      -- Draw tree branch prefix
      local prefix = (split_col == #self.split_indices) and "└─ " or "├─ "
      if split_col == 1 and #self.split_indices == 1 then prefix = "" end
      
      local title = prefix .. (sess.shell.name or ("Term " .. i))
      local fg = is_focused and style.text or style.dim
      renderer.draw_text(style.font, title, rx + 10 * SCALE, ry + math.floor((26 * SCALE - style.font:get_height())/2), fg)
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
  local right_w = (self.show_sidebar ~= false) and (150 * SCALE) or 0
  local num_terms = 0
  for _, sess in ipairs(self.sessions) do if not sess.shell.is_port_manager then num_terms = num_terms + 1 end end
  if num_terms <= 1 then right_w = 0 end
  if self:state() and self:state().shell.is_port_manager then right_w = 0 end
  local available_w = self.size.x - right_w
  local col_w = math.floor(available_w / #self.split_indices)
  local col_idx = math.floor((x - self.position.x) / col_w) + 1
  col_idx = common.clamp(col_idx, 1, #self.split_indices)
  local col_x = self.position.x + (col_idx - 1) * col_w
  local text_x = col_x + 10 * SCALE
  local s = self.sessions[self.split_indices[col_idx]]
  if not s then return 1, 1 end
  local text_y = out_top + 4 * SCALE - (s.scroll_y or 0)
  local lh = style.code_font:get_height() + 2 * SCALE
  local line = math.floor((y - text_y) / lh) + 1
  line = common.clamp(line, 1, #s.lines)
  local col = 1
  if s.lines[line] then
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
  s.scroll_y = math.max(0, (#s.lines + 1) * lh - out_h + 10 * SCALE)
  core.redraw = true
end

function TermView:on_text_input(text)
  local s = self:state()
  s.cursor = s.cursor or (#s.input + 1)
  s.input = s.input:sub(1, s.cursor - 1) .. text .. s.input:sub(s.cursor)
  s.cursor = s.cursor + #text
  self:scroll_to_end()
end

function TermView:on_key_pressed(key)
  if self:state().shell.is_port_manager and key == "return" then
    return true
  end

  if key == "return" then
    local cmd = self:state().input:match("^%s*(.-)%s*$")
    self:state().input = ""
    self:state().cursor = 1
    if not cmd or #cmd == 0 then
      local s = self:state()
      local prefix = ""
      if s.venv_name then prefix = "(" .. s.venv_name .. ") " end
      local prompt = prefix .. (s.shell.prompt_prefix or "") .. (s.cwd or core.project_dir) .. (PLATFORM == "Windows" and "> " or "$ ")
      if s.shell.is_port_manager or s.proc or core.active_codespace then prompt = "" end
      if prompt ~= "" then self:_push("cmd", prompt) end
      if s.proc and s.proc:running() then
        pcall(function() s.proc:write("\n") end)
      end
      return true
    end
    if cmd and #cmd > 0 then
      if self:state().history[#self:state().history] ~= cmd then
        table.insert(self:state().history, cmd)
      end
      self:state().history_idx = #self:state().history + 1
      
      local lower_cmd = cmd:lower()
      local cd_dir, venv_cmd
      if not self:state().proc then
        cd_dir = cmd:match("^%s*[cC][dD]%s+([^&;|]+)%s*$")
        if not cd_dir and cmd:match("^%s*[cC][dD]%s*$") then cd_dir = "" end
        
        if cmd:match("deactivate") then
          venv_cmd = "deactivate"
        else
          local venv_path = cmd:match("([%w_%.%-/\\]+)[/\\][Ss]cripts[/\\][Aa]ctivate") or cmd:match("([%w_%.%-/\\]+)[/\\]bin[/\\]activate")
          if venv_path then
            local full_path = cmd:match("^%s*(%S+)") or venv_path
            full_path = full_path:gsub("^%.[/\\]", "")
            if not (full_path:match("^%a:") or full_path:match("^/") or full_path:match("^\\")) then
              full_path = (self:state().cwd or core.project_dir) .. PATHSEP .. full_path
            end
            
            local exists = system.get_file_info(full_path) or system.get_file_info(full_path .. ".bat") or system.get_file_info(full_path .. ".ps1")
            
            if exists then
              local vname = venv_path:match("([^/\\]+)$") or venv_path
              if vname == "." or vname == ".." then vname = "env" end
              vname = vname:gsub("%.%a+$", "")
              -- Store the absolute path so changing directories doesn't break future commands
              venv_cmd = { name = vname, path = full_path }
            end
          end
        end
      end
      
      if venv_cmd then
          if venv_cmd == "deactivate" then
            self:state().venv_name = nil
            self:state().venv_path = nil
          else
            self:state().venv_name = venv_cmd.name
            self:state().venv_path = venv_cmd.path
          end
          self:_push("cmd", get_prompt(self:state()) .. cmd)
          self:_push("info", venv_cmd == "deactivate" and "Virtual environment deactivated." or ("Virtual environment '" .. venv_cmd.name .. "' activated."))
      elseif cd_dir and not self:state().proc then
          cd_dir = cd_dir:gsub('^"([^"]*)"$', '%1'):gsub("^'([^']*)'$", "%1")
          if cd_dir == "" then
             if PLATFORM == "Windows" then
                 self:_push("cmd", get_prompt(self:state()) .. cmd)
                 self:_push("out", self:state().cwd or core.project_dir)
             else
                 self:state().cwd = os.getenv("HOME") or (self:state().cwd or core.project_dir)
                 self:_push("cmd", get_prompt(self:state()) .. cmd)
             end
          else
              local cur = self:state().cwd or core.project_dir
              local new_dir = cd_dir
              if not (new_dir:match("^%a:") or new_dir:match("^/") or new_dir:match("^\\")) then
                  new_dir = cur .. "/" .. new_dir
              end
              
              local parts = {}
              for part in new_dir:gmatch("[^/\\]+") do
                  if part == ".." then
                      if #parts > 0 and not parts[#parts]:match("^%a:$") then
                          table.remove(parts)
                      end
                  elseif part ~= "." then
                      table.insert(parts, part)
                  end
              end
              
              if PLATFORM == "Windows" then
                  new_dir = table.concat(parts, "\\")
                  if not new_dir:match("^%a:\\") and #parts > 0 and parts[1]:match("^%a:$") then
                      new_dir = parts[1] .. "\\" .. table.concat(parts, "\\", 2)
                  end
                  if new_dir:match("^%a:$") then new_dir = new_dir .. "\\" end
              else
                  new_dir = "/" .. table.concat(parts, "/")
              end
              
              local info = system.get_file_info(new_dir)
              if info and info.type == "dir" then
                  self:state().cwd = new_dir
                  self:_push("cmd", get_prompt(self:state()) .. cmd)
              else
                  self:_push("cmd", get_prompt(self:state()) .. cmd)
                  self:_push("err", "Cannot find path: " .. cd_dir)
              end
          end
      elseif lower_cmd == "cls" or lower_cmd == "clear" then
        self:state().lines = {}
        self:state().scroll_y = 0
        if self:state().proc and self:state().proc:running() then
          pcall(function() self:state().proc:write("\n") end)
        end
      else
        self:run(cmd)
      end
    end
    core.redraw = true
    return true
  end
  if key == "up" then
    if #self:state().history > 0 and self:state().history_idx > 1 then
      self:state().history_idx = self:state().history_idx - 1
      self:state().input = self:state().history[self:state().history_idx]
      self:state().cursor = nil
      core.redraw = true
    end
    return true
  end
  if key == "down" then
    if #self:state().history > 0 and self:state().history_idx <= #self:state().history then
      self:state().history_idx = self:state().history_idx + 1
      self:state().input = self:state().history[self:state().history_idx] or ""
      self:state().cursor = nil
      core.redraw = true
    end
    return true
  end
  if key == "backspace" then
    local s = self:state()
    local text = s.input
    local cursor = s.cursor or (#text + 1)
    if #text > 0 and cursor > 1 then
      local i = cursor - 1
      -- Step back over UTF-8 continuation bytes (10xxxxxx)
      while i > 0 and i <= #text and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do
        i = i - 1
      end
      s.input = text:sub(1, i - 1) .. text:sub(cursor)
      s.cursor = i
      self:scroll_to_end()
    end
    return true
  end
  if key == "delete" then
    local s = self:state()
    local text = s.input
    local cursor = s.cursor or (#text + 1)
    if cursor <= #text then
      local i = cursor + 1
      while i <= #text and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do
        i = i + 1
      end
      s.input = text:sub(1, cursor - 1) .. text:sub(i)
      self:scroll_to_end()
    end
    return true
  end
  if key == "left" then
    local s = self:state()
    s.cursor = utf8_prev_index(s.input, s.cursor or (#s.input + 1))
    core.redraw = true
    return true
  end
  if key == "right" then
    local s = self:state()
    s.cursor = utf8_next_index(s.input, s.cursor or (#s.input + 1))
    core.redraw = true
    return true
  end
  if key == "home" then
    self:state().cursor = 1
    core.redraw = true
    return true
  end
  if key == "end" then
    self:state().cursor = #self:state().input + 1
    core.redraw = true
    return true
  end
  if key == "ctrl+c" then
    if self:state().persistent_proc then
      -- Send SIGINT to the remote bash process via the persistent SSH shell
      pcall(function() self:state().persistent_proc:write("\x03") end)
      self:state().waiting_sentinel = nil  -- cancel sentinel wait
      self:_push("info", "^C (sent to remote)")
    elseif self:state().proc then
      pcall(function() self:state().proc:kill() end)
      self:state().proc = nil
      self:_push("info", "^C (terminated)")
    else
      self:state().input = ""
      self:_push("info", "^C")
    end
    core.redraw = true
    return true
  end
  if key == "ctrl+l" then
    self:state().lines = {}
    core.redraw = true
    return true
  end
  if key == "pageup" then
    local lh = style.code_font:get_height() + 2 * SCALE
    self:state().scroll_y = math.max(0, self:state().scroll_y - lh * 8)
    self:state().scroll_to_bottom = false
    core.redraw = true
    return true
  end
  if key == "pagedown" then
    local lh = style.code_font:get_height() + 2 * SCALE
    self:state().scroll_y = self:state().scroll_y + lh * 8
    self:state().scroll_to_bottom = false
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
      local right_w = (self.show_sidebar ~= false) and (150 * SCALE) or 0
      local num_terms = 0
      for _, sess in ipairs(self.sessions) do if not sess.shell.is_port_manager then num_terms = num_terms + 1 end end
      if num_terms <= 1 then right_w = 0 end
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
      local right_w = (self.show_sidebar ~= false) and (150 * SCALE) or 0
      local num_terms = 0
      for _, sess in ipairs(self.sessions) do if not sess.shell.is_port_manager then num_terms = num_terms + 1 end end
      if num_terms <= 1 then right_w = 0 end
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
        self:state().selection = { l1 = l, c1 = c, l2 = l, c2 = c }
        self.dragging_selection = true
        core.redraw = true
        return true
      end
    end
  return false
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
  local total = (#s.lines + 1) * lh
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
    local sel = instance:state().selection
    local l1, c1, l2, c2 = sort_positions(sel.l1, sel.c1, sel.l2, sel.c2)
    local res = {}
    for i = l1, l2 do
      local txt = ""
      if i <= #instance:state().lines then txt = instance:state().lines[i].text
      else
        local s = instance:state()
        local prompt = get_prompt(s)
        txt = prompt .. instance:state().input
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
