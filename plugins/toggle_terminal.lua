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
  if #text <= max_chars then
    table.insert(lines, { kind = kind, text = text })
  else
    for i = 1, #text, max_chars do
      table.insert(lines, { kind = kind, text = text:sub(i, i + max_chars - 1) })
    end
  end
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
  return prefix .. (s.shell.prompt_prefix or "") .. (s.cwd or core.project_dir) .. (PLATFORM == "Windows" and "> " or "$ ")
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
local node_built = false -- have we added to node tree yet?

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
    if shell_opts then
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
    self.target_size = math.max(config.terminal.min_height * SCALE, value)
    return true
  end
end

function TermView:get_name() return "Terminal" end

-- Highly optimized chunk parser that prevents string allocation spam on massive I/O
function TermView:_push_chunk(kind, chunk, no_redraw)
  local s = self:state()
  local max_chars = math.max(60, math.floor((self.size.x - 20 * SCALE) / style.code_font:get_width("A")))
  local lh = style.code_font:get_height() + 2 * SCALE
  local old_total = (#s.lines + 1) * lh
  local inner = math.max(0, self.size.y - 31 * SCALE)
  local was_at_bottom = s.scroll_to_bottom or (s.scroll_y >= old_total - inner - lh)

  local buf_key = kind .. "_buf"
  s[buf_key] = (s[buf_key] or "") .. chunk
  
  local buf = s[buf_key]
  local last_nl = 0
  
  for i = 1, #buf do
    if buf:byte(i) == 10 then -- '\n'
      local line = buf:sub(last_nl + 1, i - 1)
      if #line > 0 and line:byte(#line) == 13 then -- strip '\r'
        line = line:sub(1, -2)
      end
      -- Strip ALL ANSI escape sequences (with or without ESC byte)
      line = line:gsub("\027%[[0-9;]*[A-Za-z]", "")       -- ESC [ ... letter
      line = line:gsub("\027[%[%]%(%)#%%][%d;]*[A-Za-z]", "")  -- other ESC seqs
      line = line:gsub("%[[0-9;]+[mKJHABCDEFGfu]", "")   -- orphaned (no ESC byte)
      -- Replace common Unicode symbols that code fonts can't render
      line = line:gsub("\xe2\x9e\x9c", "->")  -- ➜  (U+279C)
      line = line:gsub("\xe2\x86\x92", "->")  -- →  (U+2192)
      line = line:gsub("\xe2\x96\xb6", ">")   -- ▶  (U+25B6)
      line = line:gsub("\xe2\x9c\x94", "ok")  -- ✔  (U+2714)
      line = line:gsub("\xe2\x9c\x96", "err") -- ✖  (U+2716)
      line = line:gsub("\xe2\x9c\x93", "ok")  -- ✓  (U+2713)
      line = line:gsub("\xe2\x9c\x97", "err") -- ✗  (U+2717)
      if #line > 0 then
        append_wrapped(s.lines, kind, line, max_chars)
      end
      last_nl = i
    end
  end
  
  if last_nl > 0 then
    s[buf_key] = buf:sub(last_nl + 1)
    if was_at_bottom then
      s.scroll_to_bottom = true
    end
  end
  local lines = s.lines
  local n = #lines
  local overflow = n - config.terminal.scrollback
  if overflow > 0 then
    -- O(N) table rebuild instead of O(N²) repeated table.remove(t,1)
    local new_lines = {}
    for i = overflow + 1, n do
      new_lines[#new_lines + 1] = lines[i]
    end
    s.lines = new_lines
  end
  if not no_redraw then
    core.redraw = true
  end
end

function TermView:_push(kind, text)
  self:_push_chunk(kind, text .. "\n")
end

function TermView:_flush_chunk_buffer(kind)
  local max_chars = math.max(60, math.floor((self.size.x - 20 * SCALE) / style.code_font:get_width("A")))
  local buf_key = kind .. "_buf"
  local rem = self:state()[buf_key]
  if rem and #rem > 0 then
    if rem:byte(#rem) == 13 then
      rem = rem:sub(1, -2)
    end
    if #rem > 0 then
      append_wrapped(self:state().lines, kind, rem, max_chars)
    end
    self:state()[buf_key] = ""
  end
end

-- Start (or reuse) a persistent SSH bash session for the given session state.
-- Returns true if the proc is ready, false/nil otherwise.
function TermView:_ensure_persistent_proc(s)
  if s.persistent_proc then
    local rc = s.persistent_proc:returncode()
    if rc == nil then return true end  -- still alive
    -- Process died — clear it so we reconnect
    s.persistent_proc = nil
    s.waiting_sentinel = nil
    self:_push("info", "[connection lost, reconnecting...]")
  end

  if not core.active_codespace then return false end
  local repo_only = core.active_codespace.repo:match("[^/]+$") or core.active_codespace.repo
  local remote_dir = core.active_codespace.remote_dir or ("/workspaces/" .. repo_only)
  s.codespace_cwd = s.codespace_cwd or remote_dir

  -- Launch a SINGLE long-lived interactive bash via SSH.
  -- GH_INSECURE_SKIP_VERIFY_TLS bypasses corporate proxy TLS interception.
  local GH_ENV = { GH_INSECURE_SKIP_VERIFY_TLS = "1", GH_NO_UPDATE_NOTIFIER = "1" }
  local p, err = process.start(
    { "gh", "codespace", "ssh", "-c", core.active_codespace.name, "--", "-T", "-q", "bash" },
    { stdin = process.REDIRECT_PIPE, stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE, env = GH_ENV }
  )
  if not p then
    self:_push("err", "ERROR: failed to start persistent SSH: " .. tostring(err))
    return false
  end
  s.persistent_proc = p
  s.waiting_sentinel = nil
  -- Initialise: cd to the remote working dir and disable prompt so our output is clean.
  pcall(function()
    p:write("cd " .. shell_quote(remote_dir) .. " && export PS1='' && export PS2='' && stty -echo 2>/dev/null; echo READY\n")
  end)
  self:_push("info", "[connecting to codespace...]")
  return true
end

-- Run a command string asynchronously
function TermView:run(cmd_str)
  local s = self:state()
  s.scroll_to_bottom = true

  -- ── Codespace path: use persistent SSH shell (no per-command SSH handshake) ──
  if core.active_codespace then
    -- If the persistent shell process is already running a command, queue nothing
    -- (the user typed another command while one is executing)
    if s.waiting_sentinel then
      self:_push("err", "[command already running — wait for it to finish]")
      return
    end
    self:_push("cmd", get_prompt(s) .. cmd_str)
    if not self:_ensure_persistent_proc(s) then return end
    -- Build a sentinel-wrapped command that:
    --   1. runs the user's command
    --   2. captures its exit code
    --   3. prints a unique sentinel so we know it finished
    s.sentinel_n = (s.sentinel_n or 0) + 1
    local sentinel = make_sentinel(s.sentinel_n)
    s.waiting_sentinel = sentinel
    -- Wrap: run cmd, capture exit code, echo sentinel on its own line
    local wrapped = string.format(
      "%s; _rc=$?; echo '%s'; echo \"[exit: $_rc]\"\n",
      cmd_str, sentinel
    )
    pcall(function() s.persistent_proc:write(wrapped) end)
    return
  end

  -- ── Local path: legacy per-command spawn ──
  -- If a process is already running, send input to stdin
  if s.proc then
    self:_push("cmd", cmd_str)
    pcall(function() s.proc:write(cmd_str .. "\n") end)
    return
  end

  self:_push("cmd", get_prompt(s) .. cmd_str)

  local final_cmd = cmd_str
  if s.venv_path then
    local safe_path = string.format("%q", s.venv_path)
    if s.shell.name == "PowerShell" then
      final_cmd = "& " .. safe_path .. " ; " .. cmd_str
    elseif s.shell.name == "Command Prompt" then
      final_cmd = safe_path .. " && " .. cmd_str
    else
      final_cmd = "source " .. safe_path .. " && " .. cmd_str
    end
  end

  local argv = {}
  for _, v in ipairs(s.shell.cmd) do table.insert(argv, v) end
  if final_cmd and final_cmd ~= "" then table.insert(argv, final_cmd) end

  local p, err, code = process.start(argv, {
    stdin  = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
    cwd    = s.cwd or core.project_dir
  })

  if p then
    self:state().proc = p
  else
    self:_push("err", "ERROR: " .. tostring(err) .. " (code " .. tostring(code) .. ")")
  end
end

function TermView:update()
  TermView.super.update(self)

  -- Fullscreen overrides target_size
  if self.is_fullscreen then
    self.target_size = math.max(config.terminal.target_height * SCALE, core.root_view.size.y - (80 * SCALE))
  end

  -- Size animation (same pattern as built-in treeview)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "y", dest, nil, "terminal")

  -- ── Drain persistent SSH shell output (codespace sessions) ──
  for i, s in ipairs(self.sessions) do
    if s.persistent_proc then
      local had_output = false
      local old_idx = self.active_idx
      self.active_idx = i

      -- Drain stdout from persistent proc, watch for sentinel
      while true do
        local out = s.persistent_proc:read_stdout(65536)
        if not out or #out == 0 then break end
        -- Split on lines, filter out sentinel line
        local buf = (s.persistent_out_buf or "") .. out
        s.persistent_out_buf = ""
        local done = false
        for line in (buf .. "\n"):gmatch("([^\n]*)\n") do
          -- Strip \r and ALL ANSI escape sequences (mid-line too)
          line = line:gsub("\r$", "")
          line = line:gsub("\027%[[0-9;]*[A-Za-z]", "")
          line = line:gsub("\027[%[%]%(%)#%%][%d;]*[A-Za-z]", "")
          line = line:gsub("%[[0-9;]+[mKJHABCDEFGfu]", "")
          -- Replace common Unicode symbols that code fonts may not render
          line = line:gsub("➜", "->")  -- ➜ arrow
          line = line:gsub("→", "->")
          line = line:gsub("▶", ">")
          line = line:gsub("✔", "ok")
          line = line:gsub("✖", "err")
          -- Filter READY init marker
          if line == "READY" then
            -- skip init marker
          elseif s.waiting_sentinel and line:find(s.waiting_sentinel, 1, true) then
            -- Sentinel found — command finished
            s.waiting_sentinel = nil
            done = true
          elseif #line > 0 then
            append_wrapped(s.lines, "out", line, max_chars)
            had_output = true
          end
        end
        if done then
          s.scroll_to_bottom = true
          had_output = true
        end
      end

      -- Drain stderr from persistent proc
      while true do
        local err = s.persistent_proc:read_stderr(65536)
        if not err or #err == 0 then break end
        local buf = (s.persistent_err_buf or "") .. err
        s.persistent_err_buf = ""
        for line in (buf .. "\n"):gmatch("([^\n]*)\n") do
          line = line:gsub("\r$", "")
          line = line:gsub("\027%[[0-9;]*[A-Za-z]", "")  -- strip all ANSI escapes
          line = line:gsub("\027[%[%]%(%)#%%][%d;]*[A-Za-z]", "")
          line = line:gsub("%[[0-9;]+[mKJHABCDEFGfu]", "")
          line = line:gsub("➜", "->")
          line = line:gsub("→", "->")
          line = line:gsub("▶", ">")
          line = line:gsub("✔", "ok")
          line = line:gsub("✖", "err")
          if #line > 0 then
            append_wrapped(s.lines, "err", line, max_chars)
            had_output = true
          end
        end
      end

      -- Check if persistent proc died unexpectedly
      local rc = s.persistent_proc:returncode()
      if rc ~= nil then
        s.persistent_proc = nil
        s.waiting_sentinel = nil
        self:_push("info", string.format("[ssh session closed: %d]", rc))
        had_output = true
      end

      self.active_idx = old_idx
      if had_output then
        core.redraw = true
      end
    end
  end

  -- Drain ALL regular (local) process outputs using 64KB chunks
  for i, s in ipairs(self.sessions) do
    if s.proc then
      local had_output = false
      while true do
        local out = s.proc:read_stdout(65536)
        if not out or #out == 0 then break end
        -- Need to temporarily set active state for _push_chunk to target right session
        local old_idx = self.active_idx
        self.active_idx = i
        self:_push_chunk("out", out, true)
        self.active_idx = old_idx
        had_output = true
      end
      
      while true do
        local err = s.proc:read_stderr(65536)
        if not err or #err == 0 then break end
        local old_idx = self.active_idx
        self.active_idx = i
        self:_push_chunk("err", err, true)
        self.active_idx = old_idx
        had_output = true
      end

      local rc = s.proc:returncode()
      if rc ~= nil then
        local old_idx = self.active_idx
        self.active_idx = i
        self:_flush_chunk_buffer("out")
        self:_flush_chunk_buffer("err")
          if rc ~= 0 then
            self:_push_chunk("err", string.format("[exited with code: %d]\n", rc), true)
          end
        self.active_idx = old_idx
        s.proc = nil
        had_output = true
      end

      if had_output then
        core.redraw = true
      end
    end
  end

  -- Handle scroll snapping & clamp on resize
  local s = self:state()
  if not s.shell.is_port_manager then
    local lh = style.code_font:get_height() + 2 * SCALE
    local prompt = get_prompt(s)
      local max_chars = math.max(60, math.floor((self.size.x - 20 * SCALE) / style.code_font:get_width("A")))
      local full_txt = prompt .. s.input
      local input_lines_count = math.ceil(math.max(1, #full_txt) / max_chars)
      local total = (#s.lines + input_lines_count) * lh
    local inner = math.max(0, self.size.y - 31 * SCALE)
    local max_scroll = math.max(0, total - inner)
    if s.scroll_to_bottom and total > 0 then
      s.scroll_y = max_scroll
      s.scroll_to_bottom = false
    elseif s.scroll_y > max_scroll then
      s.scroll_y = max_scroll
    end
  end
end


local function sort_positions(l1, c1, l2, c2)
  if l1 < l2 then return l1, c1, l2, c2 end
  if l1 > l2 then return l2, c2, l1, c1 end
  if c1 <= c2 then return l1, c1, l2, c2 else return l2, c2, l1, c1 end
end

function TermView:resolve_position(x, y)
  local hdr_h = 26 * SCALE
  local out_top = self.position.y + hdr_h + 3 * SCALE
  local lh = style.code_font:get_height() + 2 * SCALE
  local text_y_start = out_top + 4 * SCALE - self:state().scroll_y
  local line_idx = math.floor((y - text_y_start) / lh) + 1
  line_idx = common.clamp(line_idx, 1, #self:state().lines + 1)
  
  local text_x_start = self.position.x + 10 * SCALE
  local x_offset = x - text_x_start
  if x_offset < 0 then return line_idx, 1 end
  
  local text = ""
  if line_idx <= #self:state().lines then
    text = self:state().lines[line_idx].text
  else
    local s = self:state()
    local prompt = get_prompt(s)
    text = prompt .. self:state().input
  end
  
  local current_w = 0
  local i = 1
  for char in common.utf8_chars(text) do
    local w = style.code_font:get_width(char)
    if current_w + w >= x_offset then
       if x_offset <= current_w + (w / 2) then return line_idx, i end
       return line_idx, i + #char
    end
    current_w = current_w + w
    i = i + #char
  end
  return line_idx, #text + 1
end

function TermView:get_url_at(x, y)
  local l, c = self:resolve_position(x, y)
  local line = self:state().lines[l]
  if not line or not line.text then return nil end
  local text = line.text
  
  local start_idx = 1
  while true do
    local s, e = text:find("https?://[^%s\"'<>%)]+", start_idx)
    if not s then break end
    if c >= s and c <= e then
      return text:sub(s, e)
    end
    start_idx = e + 1
  end
  return nil
end

function TermView:draw()
  if self.size.y < 2 then return end  -- fully hidden

  -- Derive bg/fg dynamically from the active editor theme (same as statusbar/treeview)
  local base   = style.background or { 255, 255, 255, 255 }
  local bg     = get_contrast_bg(base)
  local fg     = get_contrast_fg(bg)
  local hdr_bg = get_contrast_bg(bg)   -- one more level for the header strip
  local inp_bg_dyn = get_contrast_bg(hdr_bg)  -- deepest for input bar
  local col_cmd= { common.color "#8EC07C" }
  local col_err= { common.color "#FB4934" }
  local col_inf
  do  -- slightly muted version of fg
    local r,g,b = fg[1],fg[2],fg[3]
    col_inf = { math.floor(r*0.6+0.5), math.floor(g*0.6+0.5), math.floor(b*0.6+0.5), 255 }
  end
  local border = get_contrast_bg(hdr_bg)
  local inp_bg = inp_bg_dyn
  
  if style.mossy then
    bg = style.mossy.terminal_bg or bg
    fg = style.mossy.terminal_text or fg
    hdr_bg = style.mossy.activity_bg or hdr_bg
    inp_bg = style.mossy.sidebar_bg or inp_bg
    border = style.mossy.border or border
  end
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y

  -- Full background
  renderer.draw_rect(x, y, w, h, bg)

  -- Top border accent
  renderer.draw_rect(x, y, w, 2 * SCALE, border)

  -- ── Header ─────────────────────────────────────────────────────────────────
  local hdr_h = 30 * SCALE
  renderer.draw_rect(x, y, w, hdr_h, hdr_bg)

  local cur_x = x + 16 * SCALE
  local is_pm_active = self:state().shell.is_port_manager

  local function draw_tab(label, is_active)
    local tw = style.font:get_width(label) + 20 * SCALE
    local t_fg = is_active and fg or col_inf
    renderer.draw_text(style.font, label, cur_x + 10 * SCALE, y + math.floor((hdr_h - style.font:get_height()) / 2), t_fg)
    if is_active then
      renderer.draw_rect(cur_x + 10 * SCALE, y + hdr_h - 2 * SCALE, tw - 20 * SCALE, 2 * SCALE, style.accent or { common.color "#E67E80" })
    end
    local rect = { x = cur_x, y = y, w = tw, h = hdr_h }
    cur_x = cur_x + tw
    return rect
  end

  self.terminal_tab_rect = draw_tab("TERMINAL", not is_pm_active)
  self.ports_tab_rect = draw_tab("PORTS", is_pm_active)

  local right_x = x + w - 4 * SCALE
  self.right_btns = {}

  local function draw_btn(text, name, is_icon)
    local font = is_icon and style.icon_font or style.font
    local iw = font:get_width(text) + 16 * SCALE
    right_x = right_x - iw
    local hovered = self.hovered_btn_name == name
    local btn_bg = hovered and get_contrast_bg(hdr_bg) or hdr_bg
    local btn_fg = hovered and fg or col_inf
    if hovered and (name == "trash" or name == "hide") then btn_fg = col_err end
    renderer.draw_rect(right_x, y, iw, hdr_h, btn_bg)
    renderer.draw_text(font, text, right_x + math.floor((iw - font:get_width(text))/2), y + math.floor((hdr_h - font:get_height())/2), btn_fg)
    table.insert(self.right_btns, { x = right_x, y = y, w = iw, h = hdr_h, name = name })
  end

  draw_btn("\u{f00d}", "hide", true) -- ✕
  draw_btn(self.is_fullscreen and "\u{f066}" or "\u{f065}", "maximize", true) -- ▼ / ▲
  if not is_pm_active and #self.sessions > 1 then
    draw_btn("\u{f1f8}", "trash", true) -- 🗑
  end
  draw_btn("\u{f0db}", "split", true) -- ◫
  draw_btn("\u{f067}", "add", true) -- +

  if not is_pm_active then
    local session_name = self:state().shell.name
    if session_name:len() > 10 then session_name = session_name:sub(1, 10) .. ".." end
    local dd_text = tostring(self.active_idx) .. ": " .. session_name .. " v"
    draw_btn(dd_text, "dropdown", false)
  end

  -- Divider
  renderer.draw_rect(x, y + hdr_h + 2 * SCALE, w, 1 * SCALE, border)

  -- ── Seamless Terminal Output & Input ──────────────────────────────────────────
  local out_top = y + hdr_h + 3 * SCALE
  local out_bot = y + h - 2 * SCALE
  local out_h   = out_bot - out_top
  
  if self:state().shell.is_port_manager then
    self:draw_port_manager(x, out_top, w, out_h)
    return
  end

  local lh     = style.code_font:get_height() + 2 * SCALE
  local text_y = out_top + 4 * SCALE - self:state().scroll_y
  local text_x = x + 10 * SCALE


  local sel = self:state().selection
  local sel_l1, sel_c1, sel_l2, sel_c2
  if sel then sel_l1, sel_c1, sel_l2, sel_c2 = sort_positions(sel.l1, sel.c1, sel.l2, sel.c2) end

  core.push_clip_rect(x, out_top, w, out_h)

  
  -- Render only visible lines
  local lines = self:state().lines
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
        renderer.draw_text(style.code_font, ln.text, text_x, line_y, col)
      end
    end
  end
  text_y = text_y + #lines * lh

  -- Render the live input line at the bottom
  if text_y <= out_bot then
    local s = self:state()
    local prompt = get_prompt(s)
    local max_chars = math.max(60, math.floor((w - 20 * SCALE) / style.code_font:get_width("A")))
    local full_txt = prompt .. s.input
    
    local chunks = {}
    if #full_txt == 0 then
      chunks = {""}
    else
      for i = 1, #full_txt, max_chars do
        table.insert(chunks, full_txt:sub(i, i + max_chars - 1))
      end
    end
    
    for i, chunk in ipairs(chunks) do
      local chunk_y = text_y + (i - 1) * lh
      if chunk_y <= out_bot then
        if i * max_chars <= #prompt then
          renderer.draw_text(style.code_font, chunk, text_x, chunk_y, col_cmd)
        elseif (i - 1) * max_chars >= #prompt then
          renderer.draw_text(style.code_font, chunk, text_x, chunk_y, fg)
        else
          local p_len_in_chunk = #prompt - (i - 1) * max_chars
          local p_part = chunk:sub(1, p_len_in_chunk)
          local i_part = chunk:sub(p_len_in_chunk + 1)
          renderer.draw_text(style.code_font, p_part, text_x, chunk_y, col_cmd)
          renderer.draw_text(style.code_font, i_part, text_x + style.code_font:get_width(p_part), chunk_y, fg)
        end
      end
    end
    
    -- Cursor
    if core.active_view == self then
      s.cursor = s.cursor or (#s.input + 1)
      local abs_cursor = #prompt + s.cursor
      local chunk_idx = math.floor((abs_cursor - 1) / max_chars) + 1
      local cursor_col = abs_cursor - (chunk_idx - 1) * max_chars
      
      local chunk_str = chunks[chunk_idx] or ""
      local left_txt = chunk_str:sub(1, cursor_col - 1)
      local cx = text_x + style.code_font:get_width(left_txt)
      local cy = text_y + (chunk_idx - 1) * lh
      
      if system.get_time() % 1 < 0.5 and cy <= out_bot then
        renderer.draw_rect(cx, cy, 2 * SCALE, style.code_font:get_height(), { common.color("#A9DC76") })
      end
    end
  end
  
  core.pop_clip_rect()
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
function TermView:on_text_input(text)
  local s = self:state()
  s.cursor = s.cursor or (#s.input + 1)
  s.input = s.input:sub(1, s.cursor - 1) .. text .. s.input:sub(s.cursor)
  s.cursor = s.cursor + #text
  core.redraw = true
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
      elseif cd_dir then
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
      core.redraw = true
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
      core.redraw = true
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
    local max_chars = math.max(60, math.floor((self.size.x - 20 * SCALE) / style.code_font:get_width("A")))
    if s.shell.is_port_manager then
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

    if self.terminal_tab_rect then
      local r = self.terminal_tab_rect
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        if self:state().shell.is_port_manager then
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

    if self.right_btns then
      for _, b in ipairs(self.right_btns) do
        if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
          if b.name == "hide" then
            command.perform("terminal:toggle")
          elseif b.name == "maximize" then
            command.perform("terminal:fullscreen")
          elseif b.name == "trash" then
            if self:state().proc then pcall(function() self:state().proc:kill() end) end
            table.remove(self.sessions, self.active_idx)
            if self.active_idx > #self.sessions then self.active_idx = #self.sessions end
          elseif b.name == "add" then
            self:add_session(shells[1] or self:state().shell)
          elseif b.name == "split" then
            local node = core.root_view.root_node:get_node_for_view(self)
            if node then
              local new_term = TermView()
              local new_node = node:split("right", new_term)
              core.set_active_view(new_term)
            end
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
    self:state().selection.l2 = l
    self:state().selection.c2 = c
    core.redraw = true
    return true
  end

  local hdr_h = 26 * SCALE
  local out_top = self.position.y + hdr_h + 3 * SCALE
  if y > out_top then
    local url = self:get_url_at(x, y)
    if url then
      system.set_cursor("hand")
      self.hovering_url = true
    elseif self.hovering_url then
      system.set_cursor("arrow")
      self.hovering_url = false
    end
  elseif self.hovering_url then
    system.set_cursor("arrow")
    self.hovering_url = false
  end

  local hovered_name = nil
  if self.right_btns then
    for _, b in ipairs(self.right_btns) do
      if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
        hovered_name = b.name
        break
      end
    end
  end
  if self.hovered_btn_name ~= hovered_name then
    self.hovered_btn_name = hovered_name
    core.redraw = true
  end
end

function TermView:on_mouse_left()
  if self.hovered_btn_name then
    self.hovered_btn_name = nil
    core.redraw = true
  end
end


function TermView:on_mouse_released(button, x, y)
  if button == "left" and self.dragging_selection then
    self.dragging_selection = false
    if self:state().selection and self:state().selection.l1 == self:state().selection.l2 and self:state().selection.c1 == self:state().selection.c2 then
      self:state().selection = nil
    end
    core.redraw = true
    return true
  end
  return false
end

function TermView:on_mouse_wheel(dy)
  if self:state().shell.is_port_manager then
    self:state().scroll_y = math.max(0, (self:state().scroll_y or 0) - dy * 40)
    core.redraw = true
    return true
  end

  local lh = style.code_font:get_height() + 2 * SCALE
  self:state().scroll_y = math.max(0, self:state().scroll_y - dy * lh * 3)
  
  -- Clamp scroll
  local total = (#self:state().lines + 1) * lh
  local inner = math.max(0, self.size.y - 31 * SCALE)
  local max_scroll = math.max(0, total - inner)
  self:state().scroll_y = math.max(0, math.min(max_scroll, self:state().scroll_y))
  
  self:state().scroll_to_bottom = false
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

return { TermView = TermView, get_instance = function() return instance end }

