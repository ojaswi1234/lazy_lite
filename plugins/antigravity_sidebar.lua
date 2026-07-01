-- mod-version:3
-- Antigravity AI Sidebar — modern chat UI, Ctrl+Shift+A
-- Size-animation toggle (same pattern as built-in treeview).

local core    = require "core"
local config  = require "core.config"
local style   = require "core.style"
local command = require "core.command"
local keymap  = require "core.keymap"
local View    = require "core.view"
local common  = require "core.common"
local process = require "process"
local system  = require "system"

-- ── Dynamic contrast helpers (same system as mossy_statusbar / mossy_treeview) ─
local function lum(r, g, b) return r*0.299 + g*0.587 + b*0.114 end

local function contrast_bg(base, pct)
  pct = pct or 0.08
  if type(base) ~= "table" then return base end
  local r,g,b,a = base[1],base[2],base[3],base[4] or 255
  if lum(r,g,b) > 128 then
    return { math.max(0,math.floor(r*(1-pct))), math.max(0,math.floor(g*(1-pct))), math.max(0,math.floor(b*(1-pct))), a }
  else
    return { math.min(255,math.floor(r+(255-r)*pct)), math.min(255,math.floor(g+(255-g)*pct)), math.min(255,math.floor(b+(255-b)*pct)), a }
  end
end

local function contrast_fg(bg)
  if type(bg) ~= "table" then return { 0,0,0,255 } end
  local r,g,b = bg[1],bg[2],bg[3]
  if lum(r,g,b) > 128 then
    -- light bg → near-black tinted text
    return { math.floor(r*0.15), math.floor(g*0.15), math.floor(b*0.15), 255 }
  else
    -- dark bg → near-white tinted text
    return { math.min(255,math.floor(r+(255-r)*0.85)), math.min(255,math.floor(g+(255-g)*0.85)), math.min(255,math.floor(b+(255-b)*0.85)), 255 }
  end
end

local function muted(fg, factor)
  factor = factor or 0.55
  return { math.floor(fg[1]*factor), math.floor(fg[2]*factor), math.floor(fg[3]*factor), 255 }
end

-- Recomputed every draw — automatically tracks theme changes
local function get_palette()
  local base = style.background or { 255,255,255,255 }
  local bg       = contrast_bg(base, 0.08)
  local bg_dark  = contrast_bg(base, 0.14)
  local bg_darker= contrast_bg(base, 0.20)
  local bg_input = contrast_bg(base, 0.04)
  local fg       = contrast_fg(bg)
  local fg_muted = muted(fg, 0.55)
  local fg_accent= muted(fg, 0.80)
  -- Message bubbles: user slightly darker bg, AI slightly lighter
  local bg_user  = contrast_bg(base, 0.18)
  local bg_ai    = contrast_bg(base, 0.06)
  -- Button colors derived from bg levels
  local bg_btn   = contrast_bg(base, 0.12)
  local bg_btnhl = contrast_bg(base, 0.22)
  -- Send button uses accent (green on light, teal-ish on dark)
  local sr,sg,sb = base[1],base[2],base[3]
  local bg_send  = { math.floor(sr*0.35+0.5), math.floor(sg*0.45+0.5), math.floor(sb*0.30+0.5), 255 }
  local bg_sendhl= { math.max(0,bg_send[1]-15), math.max(0,bg_send[2]-15), math.max(0,bg_send[3]-15), 255 }
  local fg_send  = contrast_fg(bg_send)
  local border   = contrast_bg(base, 0.16)
  return {
    bg          = bg,
    bg_dark     = bg_dark,
    bg_darker   = bg_darker,
    bg_input    = bg_input,
    bg_user_msg = bg_user,
    bg_ai_msg   = bg_ai,
    bg_btn      = bg_btn,
    bg_btn_hl   = bg_btnhl,
    bg_send     = bg_send,
    bg_send_hl  = bg_sendhl,
    fg          = fg,
    fg_muted    = fg_muted,
    fg_accent   = fg_accent,
    fg_user     = fg_accent,
    fg_ai       = fg,
    fg_code     = fg,
    fg_send     = fg_send,
    fg_label    = fg_muted,
    border      = border,
    border_input= bg_btnhl,
    dot_idle    = fg_muted,
    dot_run     = { 95, 140, 50, 255 },
    dot_err     = { 170, 56, 59, 255 },
    scrollbar   = border,
  }
end

-- ── Config ────────────────────────────────────────────────────────────────────
config.antigravity = {
  cli = (function()
    local applocal = os.getenv("LOCALAPPDATA") or ""
    local home     = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    for _, p in ipairs({
      applocal .. "/agy/bin/agy.exe",
      applocal .. "\\agy\\bin\\agy.exe",
      home .. "/.local/bin/agy",
      "agy",
    }) do
      local f = io.open(p, "rb")
      if f then f:close(); return p end
    end
    return "agy"
  end)(),

  target_width = 270,
  auto_skip_permissions = true,
  selected_model = nil,  -- nil means use CLI default

  actions = {
    { label = "Explain",  short = "E", prompt = "Explain what this code does in plain language, line by line." },
    { label = "Refactor", short = "R", prompt = "Refactor this for clarity, idiomatic style, and performance." },
    { label = "Fix",      short = "F", prompt = "Identify every bug and fix it. List each fix with a brief reason." },
    { label = "Tests",    short = "T", prompt = "Write thorough unit tests covering edge cases." },
    { label = "Docs",     short = "D", prompt = "Generate complete docstrings and inline comments." },
  },
}

-- ── PTY Bridge helper ─────────────────────────────────────────────────────────
-- This is the VS Code Copilot approach: spawn agy inside a real pseudoterminal
-- (Python pywinpty / pty module) so it produces output, then pipe from Python.
local function get_pty_bridge()
  -- The bridge lives alongside this plugin file
  local plugin_dir = USERDIR .. "/plugins"
  local bridge = plugin_dir .. "/agy_pty_bridge.py"
  local f = io.open(bridge, "r")
  if f then f:close(); return bridge end
  return nil
end

local function build_pty_argv(cli, args)
  local bridge = get_pty_bridge()
  local argv
  if bridge then
    argv = { "python", bridge, cli }
    for _, a in ipairs(args) do table.insert(argv, a) end
  else
    -- Fallback: direct invocation (may not produce output on Windows)
    argv = { cli }
    for _, a in ipairs(args) do table.insert(argv, a) end
  end
  return argv
end

local parse_pty_model_list

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function get_context()
  local av = core.active_view
  -- If the sidebar itself is focused, fallback to finding the most recent/first DocView
  if not av or not av.doc then
    local views = core.root_view.root_node:get_children()
    for _, v in ipairs(views) do
      if v.doc then
        av = v
        break
      end
    end
  end
  if not av or not av.doc then return nil, nil end
  
  local doc  = av.doc
  local name = doc.filename or "untitled"
  local l1, c1, l2, c2 = doc:get_selection()
  local text
  if l1 ~= l2 or c1 ~= c2 then
    text = doc:get_text(l1, c1, l2, c2)
  else
    text = table.concat(doc.lines)
  end
  return name, text
end

local function get_mention_suggestions(query)
  local results = {}
  local q = query:lower()
  for dir_name, file in core.get_project_files() do
    if file and file.type == "file" then
      local path = file.filename
      if path:lower():find(q, 1, true) then
        table.insert(results, path)
        if #results >= 10 then break end
      end
    end
  end
  return results
end



-- Wrap text into lines that fit within max_w pixels using given font
local function wrap_text(font, text, max_w)
  local lines = {}
  -- simple approach: split on newlines first, then wrap long ones
  for raw_line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if font:get_width(raw_line) <= max_w then
      table.insert(lines, raw_line)
    else
      -- word-wrap
      local cur = ""
      for word in (raw_line .. " "):gmatch("(%S+)%s") do
        local try = cur == "" and word or (cur .. " " .. word)
        if font:get_width(try) > max_w then
          if #cur > 0 then
            table.insert(lines, cur)
            cur = word
          else
            -- The single word is wider than max_w; character-wrap it
            local char_cur = ""
            for i = 1, #word do
              local char = word:sub(i, i)
              local char_try = char_cur .. char
              if font:get_width(char_try) > max_w and #char_cur > 0 then
                table.insert(lines, char_cur)
                char_cur = char
              else
                char_cur = char_try
              end
            end
            cur = char_cur
          end
        else
          cur = try
        end
      end
      if #cur > 0 then table.insert(lines, cur) end
    end
  end
  return lines
end

-- Parse markdown text into blocks for formatted rendering
local function parse_blocks(text, base_font, code_font, max_w)
  local blocks = {}
  local is_code = false
  local cur_text = ""
  
  -- Split by lines to detect ``` blocks
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%s*```") then
      if #cur_text > 0 then
        -- Drop the trailing newline
        cur_text = cur_text:gsub("\n$", "")
        table.insert(blocks, { is_code = is_code, lines = wrap_text(is_code and code_font or base_font, cur_text, max_w) })
      end
      cur_text = ""
      is_code = not is_code
    else
      cur_text = cur_text .. line .. "\n"
    end
  end
  
  if #cur_text > 0 then
    cur_text = cur_text:gsub("\n$", "")
    table.insert(blocks, { is_code = is_code, lines = wrap_text(is_code and code_font or base_font, cur_text, max_w) })
  end
  
  return blocks
end

-- ── View ──────────────────────────────────────────────────────────────────────
local AGView    = View:extend()
local instance  = nil
local node_built = false

-- ── Model list parser ─────────────────────────────────────────────────────────
local function parse_model_list(raw)
  local models = {}
  for line in raw:gmatch("([^\n]+)") do
    line = line:match("^%s*(.-)%s*$")
    if #line > 0 then
      local limited = line:lower():match("limit") or line:lower():match("quota")
                   or line:lower():match("unavail") or line:lower():match("exhausted")
                   or line:lower():match("exceeded") or line:lower():match("over")
      local name = line:gsub("%s*%(.*%)%s*$", ""):gsub("%s+$", "")
      if #name > 0 then
        table.insert(models, { name = name, limited = limited and true or false })
      end
    end
  end
  return models
end

-- Parse real model names from agy PTY bridge output
-- Filters out spinner animation lines and "Fetching..." status lines
local function parse_pty_model_list(raw)
  local models = {}
  local seen = {}
  for line in (raw .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    line = line:match("^%s*(.-)%s*$")
    -- Skip blank, known spinner patterns, and fetching/loading status lines
    if #line > 0
      and not line:lower():match("^%s*fetching")
      and not line:lower():match("^%s*loading")
      and #line > 3  -- skip single spinner chars like ⠋ ⠙ etc
      and not seen[line]
    then
      seen[line] = true
      table.insert(models, { name = line, limited = false })
    end
  end
  return models
end

-- A session is { role="user"|"ai", text=string, lines={} }
function AGView:new()
  AGView.super.new(self)
  self.visible     = true
  self.target_size = config.antigravity.target_width * SCALE
  self.size.x      = 0
  self.scrollable  = true
  self.chats = {}
  self.active_idx = 0
  self.hover_btn = nil
  self.hover_send = false
  self.tick = 0
  self:_add_chat()
  -- Model picker state
  self.model_list        = {}    -- [{name,limited}] populated by 'agy models'
  self.model_proc        = nil   -- background process fetching model list
  self._model_raw        = ""    -- accumulated stdout from model_proc
  self.show_model_picker = false -- dropdown open/closed
  self.hover_model_btn   = false
  self.hover_model_idx   = nil
  self._model_rect       = nil
  self._mpicker_rects    = {}
end

-- Called by the node system when the user drags the resize divider
function AGView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = math.max(180 * SCALE, value)  -- minimum 180px
    return true
  end
end

function AGView:_update_mentions()
  local mention_prefix = self:state().input:match("@([^%s]*)$")
  if mention_prefix then
    self:state().mention_suggestions = get_mention_suggestions(mention_prefix)
    self:state().mention_idx = 1
  else
    self:state().mention_suggestions = nil
  end
  core.redraw = true
end

function AGView:get_name() return "Antigravity" end

function AGView:state()
  return self.chats[self.active_idx]
end

function AGView:_add_chat()
  local c = {
    input = "",
    status = "idle",
    process = nil,
    tmpfile = nil,
    scroll_y = 0,
    max_scroll = 0,
    sessions = {},
    has_session = false,
    warned_slow = false,
    started_at = 0,
    _chat_started_at = 0,
    _ai_buf = "",
    _ai_displayed_chars = 0,
    mention_suggestions = nil,
    mention_idx = 1,
    scroll_to_bottom = true,
  }
  table.insert(self.chats, c)
  self.active_idx = #self.chats
end


local function _session_lines(self, text, role)
  local pad  = 10 * SCALE
  local w    = self.size.x - 2 * pad - 8 * SCALE
  local font = role == "user" and style.font or style.code_font
  return wrap_text(font, text, w)
end

function AGView:_add_session(role, text)
  local entry = { role = role, text = text, lines = {} }
  -- compute wrapped lines lazily in draw (size might not be set yet)
  table.insert(self:state().sessions, entry)
end

function AGView:submit(prompt_text)
  if self:state().process then return end
  if not prompt_text or #prompt_text:match("^%s*(.-)%s*$") == 0 then return end
  prompt_text = prompt_text:match("^%s*(.-)%s*$")

  -- We no longer block execution here. The auth_status is unreliable on Windows due to the CLI's stdin behavior.
  -- If they are truly unauthenticated, the chat will hang in the background, but they can use the AGY Auth button to fix it.

  -- Add user message to chat
  self:_add_session("user", prompt_text)

  local fname = nil
  local av = core.active_view
  if av and av.doc then fname = av.doc.filename end

  local full_prompt = prompt_text
  if fname then
    full_prompt = string.format("Regarding the active file %s: %s", fname, prompt_text)
  end

  self:state().status               = "running"
  self:state()._ai_buf              = ""  -- accumulate streaming response
  self:state()._ai_displayed_chars  = 0   -- typewriter effect
  self:state().started_at           = os.time()
  self:state().warned_slow  = false
  self:_add_session("ai", "")  -- placeholder entry
  self:state().scroll_to_bottom = true

  local cfg  = config.antigravity
  local argv = { cfg.cli }

  -- Continue existing conversation after the first message
  if self:state().has_session then
    table.insert(argv, "-c")
  end

  -- Inject the user-selected model (if any)
  if cfg.selected_model then
    table.insert(argv, "--model")
    table.insert(argv, cfg.selected_model)
  end

  table.insert(argv, "-p")
  table.insert(argv, full_prompt)

  -- Pass the project root so the agent can read files natively
  local project_root = core.project_dir
  if not project_root or project_root == "" then
    if fname then
      project_root = fname:match("^(.*)[/\\][^/\\]+$") or "."
    else
      project_root = "."
    end
  end
  table.insert(argv, "--add-dir")
  table.insert(argv, project_root)

  if cfg.auto_skip_permissions then
    table.insert(argv, "--dangerously-skip-permissions")
  end

  local log = io.open(USERDIR .. "/antigravity_debug.log", "a")
  if log then
    log:write(os.date() .. "  ARGV: " .. table.concat(argv, " | ") .. "\n")
    log:close()
  end

  -- VS Code Copilot approach: route through Python PTY bridge so agy gets a
  -- real pseudoterminal (ConPTY on Windows) and produces streamed output.
  -- Python itself CAN pipe, so we use REDIRECT_PIPE on Python's stdout.
  local bridge = get_pty_bridge()
  local final_argv
  if bridge then
    -- python agy_pty_bridge.py <cli> [args...]
    final_argv = { "python", bridge }
    for _, a in ipairs(argv) do table.insert(final_argv, a) end
  else
    final_argv = argv
  end

  local p, err = process.start(final_argv, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })

  if p then
    self:state().process = p
    self:state().has_session = true
    self:state()._chat_started_at = os.time()
  else
    self:state().sessions[#self:state().sessions].text = "ERROR: could not start agy CLI.\nPath: " .. cfg.cli .. "\nError: " .. tostring(err)
    self:state().status = "error"
  end
  core.redraw = true
end

function AGView:update()
  AGView.super.update(self)
  self.tick = (self.tick + 1) % 120

  -- Size animation (treeview pattern)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "x", dest, nil, "antigravity")



  -- ── Drain model-fetch process (via PTY bridge) ───────────────────────
  if self.model_proc then
    local buf = ""
    while true do
      local chunk = self.model_proc:read_stdout(4096)
      if not chunk or #chunk == 0 then break end
      buf = buf .. chunk
    end
    while true do
      local chunk = self.model_proc:read_stderr(4096)
      if not chunk or #chunk == 0 then break end
      -- stderr is usually noise, skip
    end
    if #buf > 0 then
      self._model_raw = (self._model_raw or "") .. buf
    end

    local m_elapsed = os.time() - (self.model_started_at or os.time())
    local rc = self.model_proc:returncode()
    if rc ~= nil then
      local parsed = parse_pty_model_list(self._model_raw or "")
      if #parsed > 0 then
        self.model_list = parsed
        self.auth_status = "logged_in"
      else
        self:_load_models_from_settings()
      end
      self._model_raw = ""
      self.model_proc = nil
      core.redraw = true
    elseif m_elapsed > 15 then
      pcall(function() self.model_proc:kill() end)
      self.model_proc = nil
      self._model_raw = ""
      self:_load_models_from_settings()
      core.redraw = true
    end
  end

  -- ── Drain chat process (real process handle via PTY bridge) ───────────
  if self:state().process then
    local dirty = false
    while true do
      local out = self:state().process:read_stdout(65536)
      if not out or #out == 0 then break end
      self:state()._ai_buf = (self:state()._ai_buf or "") .. out
      dirty = true
    end
    while true do
      local out = self:state().process:read_stderr(65536)
      if not out or #out == 0 then break end
      -- stderr from bridge is usually noise, skip adding to chat
    end

    local rc = self:state().process:returncode()
    if rc ~= nil then
      -- Final drain
      while true do
        local out = self:state().process:read_stdout(65536)
        if not out or #out == 0 then break end
        self:state()._ai_buf = (self:state()._ai_buf or "") .. out
      end
      self:state().process = nil
      self:state().status = (rc == 0) and "idle" or "error"
      if not self:state()._ai_buf or self:state()._ai_buf == "" then
        local elapsed = os.time() - (self:state()._chat_started_at or os.time())
        self:state()._ai_buf = string.format(
          "(no output after %.0fs — process exited with code %s)\n\nTry the AGY Auth button if you just logged in.",
          elapsed, tostring(rc))
      end
      core.redraw = true
    elseif os.time() - (self:state()._chat_started_at or os.time()) > 315 then
      pcall(function() self:state().process:kill() end)
      self:state().process = nil
      self:state().status = "error"
      self:state()._ai_buf = "⏱ Request timed out after 5 minutes with no response."
      core.redraw = true
    end
  end


  local ai_len = self:state()._ai_buf and #self:state()._ai_buf or 0
  local is_typing = self:state()._ai_displayed_chars and (self:state()._ai_displayed_chars < ai_len)

  if not self:state().process and not is_typing then return end

  -- Typewriter effect logic
  if is_typing then
    -- Reveal characters (approx 60fps * 30 chars = 1800 chars/sec)
    self:state()._ai_displayed_chars = math.min(ai_len, self:state()._ai_displayed_chars + 30)
    
    if self:state().sessions[#self:state().sessions] and self:state().sessions[#self:state().sessions].role == "ai" then
      self:state().sessions[#self:state().sessions].text  = self:state()._ai_buf:sub(1, self:state()._ai_displayed_chars)
      self:state().sessions[#self:state().sessions].blocks = nil  -- invalidate cache
      self:state().scroll_to_bottom = true
    end
    core.redraw = true
  end

  if not self:state().process then return end

  local elapsed = os.time() - (self:state().started_at or os.time())
  -- Soft warning at 45s
  if elapsed > 45 and self:state()._ai_buf == "" and not self:state().warned_slow then
    self:state().warned_slow = true
    core.redraw = true
  end
  -- Hard kill at 315s (5m15s) — surface a fix message instead of hanging forever
  -- The agy CLI itself defaults to a 5m wait, so we give it slightly longer.
  if elapsed > 315 and self:state()._ai_buf == "" and self:state().process then
    pcall(function() self:state().process:kill() end)
    self:state().process = nil
    self:state().status  = "error"
    local fix_msg = table.concat({
      "⏱ Request timed out after 5 minutes with no response.",
      "",
      "Most likely causes:",
      "  1. The AI model is taking too long to generate a response.",
      "  2. The Antigravity CLI is not set up correctly.",
      "",
      "If it's the latter, run this command in a terminal to fix it:",
      "  agy install",
      "",
      "After setup completes, reload Lite-XL and try again.",
      "If the problem persists, check: agy models",
    }, "\n")
    if self:state().sessions[#self:state().sessions] then
      self:state().sessions[#self:state().sessions].text  = fix_msg
      self:state().sessions[#self:state().sessions].blocks = nil
    end
    -- Notify auto-healer so it can log and potentially offer to run agy install
    core.error("[Antigravity] CLI timed out — agy install may be required.")
    core.redraw = true
  end

  -- (Model fetch logic was moved to the top of update())
end

-- Kick off background fetch of real model list via PTY bridge
function AGView:fetch_models()
  if self.model_proc then return end
  if self.model_list and #self.model_list > 0 then return end
  local cfg = config.antigravity

  -- Use the PTY bridge so agy gets a real pseudoterminal and outputs the list
  local bridge = get_pty_bridge()
  local argv
  if bridge then
    argv = { "python", bridge, cfg.cli, "models" }
  else
    -- Fallback: try direct (won't work on Windows but at least it tries)
    argv = { cfg.cli, "models" }
  end

  self._model_raw = ""
  self.model_started_at = os.time()

  local p, err = process.start(argv, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if p then
    self.model_proc = p
  else
    -- Bridge failed — load from settings.json as reliable fallback
    self:_load_models_from_settings()
  end
end

-- Parse models from agy output (spinner lines filtered, real model names kept)
function parse_pty_model_list(raw)
  local models = {}
  local seen = {}
  for line in (raw .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    line = line:match("^%s*(.-)%s*$")
    -- Skip spinner lines, empty lines, and "Fetching" lines
    if #line > 0
      and not line:match("^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]")
      and not line:lower():match("fetching")
      and not line:lower():match("loading")
      and not seen[line]
    then
      seen[line] = true
      table.insert(models, { name = line, limited = false })
    end
  end
  return models
end

-- Fallback: load model list from settings.json
function AGView:_load_models_from_settings()
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
  local settings_paths = {
    home .. "\\.gemini\\antigravity-cli\\settings.json",
    home .. "/.gemini/antigravity-cli/settings.json",
  }
  local current_model = nil
  for _, path in ipairs(settings_paths) do
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a"); f:close()
      local m = content:match('"model"%s*:%s*"([^"]+)"')
      if m then current_model = m; break end
    end
  end
  -- Hardcoded known model list as final fallback
  self.model_list = {
    { name = "Gemini 3.5 Flash (Medium)",    limited = false },
    { name = "Gemini 3.5 Flash (High)",      limited = false },
    { name = "Gemini 3.1 Pro (High)",        limited = false },
    { name = "Claude Sonnet 4.6 (Thinking)", limited = false },
    { name = "Claude Opus 4.6 (Thinking)",   limited = false },
    { name = "GPT-OSS 120B (Medium)",        limited = false },
  }
  if current_model then
    table.insert(self.model_list, 1, { name = current_model, limited = false, current = true })
    if not config.antigravity.selected_model then
      config.antigravity.selected_model = current_model
    end
  end
  self.auth_status = "logged_in"
  core.redraw = true
end

-- Hook into core.quit to kill any zombie background processes when Lite-XL exits
local old_quit = core.quit
function core.quit(force)
  if instance then
    if instance.process then pcall(function() instance.process:kill() end) end
    if instance.model_proc then pcall(function() instance.model_proc:kill() end) end
  end
  return old_quit(force)
end

-- ── Draw helpers ──────────────────────────────────────────────────────────────
local function draw_rect_outline(x, y, w, h, col)
  renderer.draw_rect(x,     y,     w, 1, col)
  renderer.draw_rect(x,     y+h-1, w, 1, col)
  renderer.draw_rect(x,     y,     1, h, col)
  renderer.draw_rect(x+w-1, y,     1, h, col)
end

function AGView:draw()
  if self.size.x < 4 then return end

  -- Recompute the full palette from the active theme every frame
  local P = get_palette()

  local x, y = self.position.x, self.position.y
  local w, h  = self.size.x, self.size.y
  local pad   = 10 * SCALE
  local cur_y = y

  -- ── Full background ─────────────────────────────────────────────────────────
  renderer.draw_rect(x, y, w, h, P.bg)
  -- Left border (panel is on the right side)
  renderer.draw_rect(x, y, 1, h, P.border)

  -- ═══════════════════════════════════════════════════════════════════
  -- HEADER
  -- ═══════════════════════════════════════════════════════════════════
  local hdr_h = 40 * SCALE
  renderer.draw_rect(x, cur_y, w, hdr_h, P.bg_darker)
  renderer.draw_rect(x, cur_y + hdr_h - 1, w, 1, P.border)

  -- Status dot
  local dot_col = self:state().status == "running" and P.dot_run
               or self:state().status == "error"   and P.dot_err
               or P.dot_idle
  local dot_r = 5 * SCALE
  renderer.draw_rect(x + pad, cur_y + math.floor(hdr_h/2) - dot_r, dot_r*2, dot_r*2, dot_col)

  -- Title
  renderer.draw_text(style.big_font or style.font, "Antigravity",
    x + pad + dot_r*2 + 6 * SCALE,
    cur_y + math.floor((hdr_h - (style.big_font or style.font):get_height()) / 2),
    P.fg_accent)

  -- Status + Model button row (right side of header)
  local status_str = self:state().status == "running"
    and (self:state().warned_slow and "slow." or "thinking.")
    or  self:state().status == "error" and "error"
    or  "ready"
  local ss_w = style.font:get_width(status_str)
  renderer.draw_text(style.font, status_str,
    x + w - ss_w - pad - 8 * SCALE,
    cur_y + math.floor((hdr_h - style.font:get_height()) / 2),
    self:state().status == "error" and P.dot_err or P.fg_muted)

  -- Model selector pill button (sits just right of "Antigravity" title)
  local title_x   = x + pad + dot_r*2 + 6 * SCALE
  local title_w   = (style.big_font or style.font):get_width("Antigravity")
  local sel_name  = config.antigravity.selected_model or "model"
  local mfont     = style.font
  local mbtn_max  = w - (title_x - x) - title_w - ss_w - pad * 2 - 16 * SCALE
  local mbtn_lbl  = "[M] " .. sel_name
  while mfont:get_width(mbtn_lbl) > mbtn_max - 10 * SCALE and #mbtn_lbl > 5 do
    mbtn_lbl = mbtn_lbl:sub(1, -2)
  end
  if sel_name ~= "model" and mfont:get_width("[M] " .. sel_name) > mbtn_max - 10 * SCALE then
    mbtn_lbl = mbtn_lbl .. "."
  end
  local mbtn_w = math.min(mfont:get_width(mbtn_lbl) + 14 * SCALE, mbtn_max)
  local mbtn_h = 18 * SCALE
  local mbtn_x = title_x + title_w + 8 * SCALE
  local mbtn_y = cur_y + math.floor((hdr_h - mbtn_h) / 2)
  local mbtn_bg = self.hover_model_btn and P.bg_btn_hl or P.bg_btn
  renderer.draw_rect(mbtn_x, mbtn_y, mbtn_w, mbtn_h, mbtn_bg)
  draw_rect_outline(mbtn_x, mbtn_y, mbtn_w, mbtn_h, P.border)
  renderer.draw_text(mfont, mbtn_lbl,
    mbtn_x + 6 * SCALE,
    mbtn_y + math.floor((mbtn_h - mfont:get_height()) / 2),
    P.fg_label)
  self._model_rect = { x = mbtn_x, y = mbtn_y, w = mbtn_w, h = mbtn_h }

  cur_y = cur_y + hdr_h

    -- QUICK ACTION PILLS (single row, compact)
  -- ═══════════════════════════════════════════════════════════════════
  local pill_h    = 24 * SCALE
  local pill_gap  = 4 * SCALE
  local n         = #config.antigravity.actions
  local pill_w    = math.floor((w - 2 * pad - (n - 1) * pill_gap) / n)
  local pills_top = cur_y + 6 * SCALE

  for i, act in ipairs(config.antigravity.actions) do
    local bx = x + pad + (i - 1) * (pill_w + pill_gap)
    local by = pills_top
    local hl = (self.hover_btn == i)

    renderer.draw_rect(bx, by, pill_w, pill_h, hl and P.bg_btn_hl or P.bg_btn)
    draw_rect_outline(bx, by, pill_w, pill_h, P.border)

    local label_w = style.font:get_width(act.short)
    renderer.draw_text(style.font, act.short,
      bx + math.floor((pill_w - label_w) / 2),
      by + math.floor((pill_h - style.font:get_height()) / 2),
      hl and P.fg_accent or P.fg_label)
  end
  cur_y = pills_top + pill_h + 6 * SCALE

  -- Label row under pills
  for i, act in ipairs(config.antigravity.actions) do
    local bx = x + pad + (i - 1) * (pill_w + pill_gap)
    local lw = style.font:get_width(act.label)
    if lw <= pill_w then
      renderer.draw_text(style.font, act.label,
        bx + math.floor((pill_w - lw) / 2),
        cur_y,
        P.fg_muted)
    end
  end
  cur_y = cur_y + style.font:get_height() + 4 * SCALE

  -- Divider
  renderer.draw_rect(x + pad, cur_y, w - 2*pad, 1, P.border)
  cur_y = cur_y + 8 * SCALE

  -- ═══════════════════════════════════════════════════════════════════
  -- INPUT AREA (at bottom, fixed)
  -- ═══════════════════════════════════════════════════════════════════
  local send_h   = 30 * SCALE
  local input_h  = 56 * SCALE
  local bottom_h = input_h + send_h + 3 * pad
  local chat_bot = y + h - bottom_h

  -- Divider above input
  renderer.draw_rect(x, chat_bot, w, 1, P.border)

  -- Input box
  local inp_x = x + pad
  local inp_y = chat_bot + pad
  local inp_w = w - 2 * pad
  renderer.draw_rect(inp_x, inp_y, inp_w, input_h, P.bg_input)
  draw_rect_outline(inp_x, inp_y, inp_w, input_h,
    core.active_view == self and P.border_input or P.border)

  -- Placeholder / typed text
  local display    = #self:state().input > 0 and self:state().input or "Ask anything about your code."
  local fg_inp     = #self:state().input > 0 and P.fg or P.fg_muted

  local max_text_w = inp_w - 16 * SCALE
  local text_w     = style.font:get_width(display)
  local tx         = inp_x + 8 * SCALE
  if core.active_view == self and text_w > max_text_w then
    tx = tx - (text_w - max_text_w)
  end

  core.push_clip_rect(inp_x, inp_y, inp_w, input_h)
  renderer.draw_text(style.font, display, tx, inp_y + 8 * SCALE, fg_inp)

  -- Blink cursor
  if core.active_view == self and math.floor(self.tick / 30) % 2 == 0 then
    local cw = style.font:get_width(self:state().input)
    renderer.draw_rect(tx + cw, inp_y + 8 * SCALE, 2 * SCALE, style.font:get_height(), P.fg_accent)
  end
  core.pop_clip_rect()

  -- Hint text bottom-right of input
  local hint = "Enter ↵"
  renderer.draw_text(style.font, hint,
    inp_x + inp_w - style.font:get_width(hint) - 6 * SCALE,
    inp_y + input_h - style.font:get_height() - 5 * SCALE,
    P.fg_muted)

  -- Send/Stop button
  local send_y = inp_y + input_h + 4 * SCALE
  local send_bg = P.bg_send
  if self.hover_send then
    send_bg = self:state().process and { common.color "#903030" } or P.bg_send_hl
  end
  renderer.draw_rect(inp_x, send_y, inp_w, send_h, send_bg)

  local send_lbl = self:state().process and "  Stop Generating" or "  Send"
  renderer.draw_text(style.font, send_lbl,
    inp_x + math.floor((inp_w - style.font:get_width(send_lbl)) / 2),
    send_y + math.floor((send_h - style.font:get_height()) / 2),
    P.fg_send)

  -- Store send button bounds for click detection
  self._send_rect = { x = inp_x, y = send_y, w = inp_w, h = send_h }

  -- ═══════════════════════════════════════════════════════════════════
  -- CHAT HISTORY (scrollable, between quick-actions and input)
  -- ═══════════════════════════════════════════════════════════════════
    local tab_h = 24 * SCALE
  self.tab_rects = {}
  local cur_x = x + pad
  for i, c in ipairs(self.chats) do
    local label = tostring(i)
    local tw = style.font:get_width(label) + 16 * SCALE
    local tab_bg = (i == self.active_idx) and P.bg_btn_hl or P.bg
    local tab_fg = (i == self.active_idx) and P.fg or P.fg_muted
    
    renderer.draw_rect(cur_x, cur_y, tw, tab_h, tab_bg)
    renderer.draw_text(style.font, label, cur_x + 8 * SCALE, cur_y + math.floor((tab_h - style.font:get_height())/2), tab_fg)
    
    table.insert(self.tab_rects, { x = cur_x, y = cur_y, w = tw, h = tab_h, idx = i })
    cur_x = cur_x + tw + 2 * SCALE
  end
  
  -- "+" button
  local pw = style.font:get_width("+") + 16 * SCALE
  renderer.draw_rect(cur_x, cur_y, pw, tab_h, P.bg)
  renderer.draw_text(style.font, "+", cur_x + 8 * SCALE, cur_y + math.floor((tab_h - style.font:get_height())/2), P.fg_muted)
  self.add_btn_rect = { x = cur_x, y = cur_y, w = pw, h = tab_h }
  cur_x = cur_x + pw + 2 * SCALE
  
  -- "x" button (close active)
  if #self.chats > 1 then
    local xw = style.font:get_width("x") + 16 * SCALE
    renderer.draw_rect(cur_x, cur_y, xw, tab_h, P.bg)
    renderer.draw_text(style.font, "x", cur_x + 8 * SCALE, cur_y + math.floor((tab_h - style.font:get_height())/2), { common.color "#FB4934" })
    self.close_btn_rect = { x = cur_x, y = cur_y, w = xw, h = tab_h }
  else
    self.close_btn_rect = nil
  end
  
  cur_y = cur_y + tab_h + 4 * SCALE
  local chat_top = cur_y
  local chat_h   = chat_bot - chat_top

  -- Clip: draw a bg rect to mask overflow
  renderer.draw_rect(x, chat_top, w, chat_h, P.bg)

  local lh_f = style.font:get_height() + 2 * SCALE
  local lh_c = style.code_font:get_height() + 2 * SCALE
  local ty    = chat_top + 4 * SCALE - self:state().scroll_y
  local total_h = 0
  self._copy_rects = {}

  for _, sess in ipairs(self:state().sessions) do
    local is_user = sess.role == "user"
    local font    = is_user and style.font or style.code_font
    local lh      = is_user and lh_f or lh_c
    local msg_pad = 8 * SCALE
    local msg_w   = w - 2 * pad - 4 * SCALE
    local bg_col  = is_user and P.bg_user_msg or P.bg_ai_msg
    local fg_col  = is_user and P.fg_user or P.fg_ai

    -- Cache parsed blocks (invalidated when text changes)
    if not sess.blocks or sess._cached_text ~= sess.text then
      sess.blocks = parse_blocks(sess.text, style.font, style.code_font, msg_w - 2 * msg_pad)
      sess._cached_text = sess.text
    end

    local msg_h = 2 * msg_pad
    for _, blk in ipairs(sess.blocks) do
      local blk_lh = blk.is_code and lh_c or lh_f
      msg_h = msg_h + #blk.lines * blk_lh
      if blk.is_code then msg_h = msg_h + 8 * SCALE end
    end
    msg_h = math.max(lh_f + 2 * msg_pad, msg_h)

    -- Role label
    if ty + msg_h + lh_f >= chat_top and ty <= chat_bot then
      local role_lbl = is_user and "You" or "Antigravity"
      renderer.draw_text(style.font, role_lbl,
        x + pad,
        math.max(chat_top, math.min(ty, chat_bot - style.font:get_height())),
        P.fg_muted)
    end
    ty = ty + style.font:get_height() + 2 * SCALE

    -- Message bubble background
    if ty + msg_h >= chat_top and ty <= chat_bot then
      renderer.draw_rect(x + pad, ty, msg_w, msg_h, bg_col)
      draw_rect_outline(x + pad, ty, msg_w, msg_h, P.border)
    end

    -- Blocks inside bubble
    local line_y = ty + msg_pad
    for _, blk in ipairs(sess.blocks) do
      local blk_lh = blk.is_code and lh_c or lh_f
      local block_font = blk.is_code and style.code_font or style.font
      if blk.is_code and #blk.lines > 0 then
        local b_h = #blk.lines * blk_lh + 8 * SCALE
        if line_y + b_h >= chat_top and line_y <= chat_bot then
          renderer.draw_rect(x + pad + 4 * SCALE, line_y, msg_w - 8 * SCALE, b_h, P.bg_darker)
          draw_rect_outline(x + pad + 4 * SCALE, line_y, msg_w - 8 * SCALE, b_h, P.border)
        end
        line_y = line_y + 4 * SCALE
      end
      for _, line in ipairs(blk.lines) do
        if line_y + blk_lh >= chat_top and line_y <= chat_bot then
          renderer.draw_text(block_font, line, x + pad + msg_pad, line_y, fg_col)
        end
        line_y = line_y + blk_lh
      end
      if blk.is_code and #blk.lines > 0 then
        line_y = line_y + 4 * SCALE
      end
    end

    -- Save bounds for hover/click detection
    local bubble_x, bubble_y = x + pad, ty
    local bubble_w, bubble_h = msg_w, msg_h
    table.insert(self._copy_rects, {
      x = bubble_x, y = bubble_y, w = bubble_w, h = bubble_h, text = sess.text, idx = _
    })

    -- Draw copy button if hovered
    if self.hover_copy_idx == _ then
      local copy_txt = self.copy_flash_idx == _ and "Copied!" or "Copy"
      local c_w = style.font:get_width(copy_txt) + 12 * SCALE
      local c_h = style.font:get_height() + 8 * SCALE
      local c_x = bubble_x + bubble_w - c_w - 6 * SCALE
      local c_y = bubble_y + 6 * SCALE
      
      if c_y + c_h >= chat_top and c_y <= chat_bot then
        renderer.draw_rect(c_x, c_y, c_w, c_h, P.bg_btn_hl)
        draw_rect_outline(c_x, c_y, c_w, c_h, P.border)
        renderer.draw_text(style.font, copy_txt, c_x + 6 * SCALE, c_y + 4 * SCALE, P.fg)
      end
    end

    -- Spinner on last AI message while running
    if self:state().status == "running" and not is_user
       and sess == self:state().sessions[#self:state().sessions]
       and sess.text == "" then
      local dots = string.rep("•", (math.floor(self.tick / 20) % 4))
      renderer.draw_text(style.font, dots,
        x + pad + msg_pad, ty + msg_pad, P.fg_muted)
    end

    ty = ty + msg_h + 6 * SCALE
    total_h = total_h + style.font:get_height() + 2 * SCALE + msg_h + 6 * SCALE
  end

  self:state().max_scroll = math.max(0, total_h - chat_h)
  if self:state().scroll_to_bottom then
    if self:state().scroll_y ~= self:state().max_scroll then
      self:state().scroll_y = self:state().max_scroll
      core.redraw = true
    end
    self:state().scroll_to_bottom = false
  end

  -- Empty state
  if #self:state().sessions == 0 then
    local msg = "To reference specific files in your project, type '@' followed by the file name!\n\n" ..
                "Example: '@src/main.lua Can you fix the errors in this file?'"
    local mw = w - 2 * pad
    for _, line in ipairs(wrap_text(style.font, msg, mw)) do
      renderer.draw_text(style.font, line, x + pad, ty, P.fg_muted)
      ty = ty + style.font:get_height() + 2 * SCALE
    end
  end

  -- ═══════════════════════════════════════════════════════════════════
  -- MENTION POPUP
  -- ═══════════════════════════════════════════════════════════════════
  if self:state().mention_suggestions and #self:state().mention_suggestions > 0 then
    local pop_w = w - 2 * pad
    local item_h = style.font:get_height() + 8 * SCALE
    local pop_h = #self:state().mention_suggestions * item_h
    local pop_x = x + pad
    local pop_y = inp_y - pop_h - 4 * SCALE
    
    renderer.draw_rect(pop_x, pop_y, pop_w, pop_h, P.bg_darker)
    draw_rect_outline(pop_x, pop_y, pop_w, pop_h, P.border)
    
    for i, file in ipairs(self:state().mention_suggestions) do
      local iy = pop_y + (i - 1) * item_h
      if i == self:state().mention_idx then
        renderer.draw_rect(pop_x, iy, pop_w, item_h, P.bg_btn_hl)
      end
      renderer.draw_text(style.font, file, pop_x + 8 * SCALE, iy + 4 * SCALE, P.fg)
    end
  end

  -- MODEL PICKER DROPDOWN: drawn last to overlay pills and chat
  if self.show_model_picker then
    local mf     = style.font
    local item_h = mf:get_height() + 10 * SCALE
    local list   = self.model_list
    local rows   = (#list == 0) and 1 or #list
    local pop_h  = rows * item_h + 6 * SCALE
    local pop_y  = y + 40 * SCALE
    renderer.draw_rect(x, pop_y, w, pop_h, P.bg_dark)
    draw_rect_outline(x, pop_y, w, pop_h, P.border)
    self._mpicker_rects = {}
    if #list == 0 then
      renderer.draw_text(mf,
        self.model_proc and "Fetching models..." or "No models found.",
        x + pad, pop_y + 3 * SCALE + math.floor((item_h - mf:get_height()) / 2), P.fg_muted)
    else
      for i, m in ipairs(list) do
        local ry     = pop_y + 3 * SCALE + (i - 1) * item_h
        local is_sel = config.antigravity.selected_model == m.name
        local is_hov = self.hover_model_idx == i
        local rbg    = is_sel and P.bg_btn_hl or is_hov and P.bg_btn or nil
        if rbg then renderer.draw_rect(x, ry, w, item_h, rbg) end
        local flag  = m.limited and " (L)" or ""
        local label = m.name .. flag
        local fg    = m.limited and P.dot_err or (is_sel and P.fg_accent or P.fg)
        renderer.draw_text(mf, label, x + pad,
          ry + math.floor((item_h - mf:get_height()) / 2), fg)
        if is_sel then
          renderer.draw_text(mf, "[v]",
            x + w - pad - mf:get_width("[v]"),
            ry + math.floor((item_h - mf:get_height()) / 2), P.dot_run)
        end
        table.insert(self._mpicker_rects, { x=x, y=ry, w=w, h=item_h, idx=i })
      end
    end
  end
end

-- ── Input ──────────────────────────────────────────────────────────────────────
function AGView:on_text_input(text)
  self:state().input = self:state().input .. text
  self:_update_mentions()
  core.redraw = true
end

function AGView:on_key_pressed(key, ...)
  if self:state().mention_suggestions and #self:state().mention_suggestions > 0 then
    if key == "up" then
      self:state().mention_idx = math.max(1, self:state().mention_idx - 1)
      core.redraw = true
      return true
    elseif key == "down" then
      self:state().mention_idx = math.min(#self:state().mention_suggestions, self:state().mention_idx + 1)
      core.redraw = true
      return true
    elseif key == "return" or key == "tab" then
      local choice = self:state().mention_suggestions[self:state().mention_idx]
      self:state().input = self:state().input:gsub("@[^%s]*$", "@" .. choice .. " ")
      self:state().mention_suggestions = nil
      core.redraw = true
      return true
    elseif key == "escape" then
      self:state().mention_suggestions = nil
      core.redraw = true
      return true
    end
  end

  local mods = keymap.modkeys or {}

  if key == "return" and not mods["ctrl"] then
    local q = self:state().input:match("^%s*(.-)%s*$")
    if q and #q > 0 then self:submit(q) end
    self:state().input = ""
    core.redraw = true
    return true
  end

  if key == "return" and mods["ctrl"] then
    -- Ctrl+Enter: clear chat
    self:state().sessions = {}
    self:state().input    = ""
    self:state().status   = "idle"
    self:state().has_session = false
    if self:state().process then pcall(function() self:state().process:kill() end) end
    self:state().process  = nil
    core.redraw = true
    return true
  end

  if key == "backspace" then
    local text = self:state().input
    if #text > 0 then
      local i = #text
      -- Step back over UTF-8 continuation bytes (10xxxxxx)
      while i > 0 and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do
        i = i - 1
      end
      self:state().input = text:sub(1, math.max(0, i - 1))
      self:_update_mentions()
      core.redraw = true
    end
    return true
  end

  if key == "up" then
    self:state().scroll_y = math.max(0, self:state().scroll_y - (style.font:get_height() + 2 * SCALE) * 3)
    core.redraw = true
    return true
  end
  if key == "down" then
    self:state().scroll_y = math.min(self:state().max_scroll, self:state().scroll_y + (style.font:get_height() + 2 * SCALE) * 3)
    core.redraw = true
    return true
  end
  return false
end

-- ── Mouse ──────────────────────────────────────────────────────────────────────
function AGView:on_mouse_moved(mx, my, ...)
  AGView.super.on_mouse_moved(self, mx, my, ...)
  self.hover_btn  = nil
  self.hover_send = false

  local x     = self.position.x
  local w     = self.size.x
  local pad   = 10 * SCALE
  local n     = #config.antigravity.actions
  local pill_w = math.floor((w - 2 * pad - (n - 1) * 4 * SCALE) / n)
  local pill_h = 24 * SCALE
  -- Pills start at: y + header(40) + 6
  local pills_top = self.position.y + 40 * SCALE + 6 * SCALE

  for i = 1, n do
    local bx = x + pad + (i - 1) * (pill_w + 4 * SCALE)
    if mx >= bx and mx <= bx + pill_w and my >= pills_top and my <= pills_top + pill_h then
      self.hover_btn = i
      break
    end
  end

  if self._send_rect then
    local r = self._send_rect
    self.hover_send = (mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h)
  end

  self.hover_copy_idx = nil
  if self._copy_rects then
    for _, r in ipairs(self._copy_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        self.hover_copy_idx = r.idx
        break
      end
    end
  end

  -- Model button hover
  self.hover_model_btn = false
  self.hover_model_idx = nil
  if self._model_rect then
    local r = self._model_rect
    self.hover_model_btn = (mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h)
  end
  if self.show_model_picker and self._mpicker_rects then
    for _, r in ipairs(self._mpicker_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        self.hover_model_idx = r.idx
        break
      end
    end
  end

  core.redraw = true
end

function AGView:on_mouse_pressed(button, mx, my, clicks)
  AGView.super.on_mouse_pressed(self, button, mx, my, clicks)
  if button ~= "left" then return false end

  -- Model picker button
  if self._model_rect then
    local r = self._model_rect
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      self.show_model_picker = not self.show_model_picker
      if self.show_model_picker and #self.model_list == 0 then
        self:fetch_models()
      end
      core.redraw = true
      return true
    end
  end

  if self.add_btn_rect then
    local r = self.add_btn_rect
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      self:_add_chat()
      core.redraw = true
      return true
    end
  end
  if self.close_btn_rect then
    local r = self.close_btn_rect
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      if self:state().process then pcall(function() self:state().process:kill() end) end
      table.remove(self.chats, self.active_idx)
      if self.active_idx > #self.chats then self.active_idx = #self.chats end
      core.redraw = true
      return true
    end
  end
  for _, r in ipairs(self.tab_rects or {}) do
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      self.active_idx = r.idx
      core.redraw = true
      return true
    end
  end

  -- Model picker row selection
  if self.show_model_picker and self._mpicker_rects then
    for _, r in ipairs(self._mpicker_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        local m = self.model_list[r.idx]
        if m then
          config.antigravity.selected_model = m.name
          self.show_model_picker = false
          self:state().has_session = false  -- reset session so next -p doesn't pass -c with old model
          core.log("Antigravity: switched to model '" .. m.name .. "'")
        end
        core.redraw = true
        return true
      end
    end
  end

  -- Close picker if clicking elsewhere
  if self.show_model_picker then
    self.show_model_picker = false
    core.redraw = true
  end

  -- Quick action pill
  if self.hover_btn then
    local act = config.antigravity.actions[self.hover_btn]
    if act then self:submit(act.prompt) return true end
  end

  -- Copy button click
  if self.hover_copy_idx and self._copy_rects then
    for _, r in ipairs(self._copy_rects) do
      if r.idx == self.hover_copy_idx then
        system.set_clipboard(r.text)
        self.copy_flash_idx = r.idx
        core.add_thread(function()
          coroutine.yield(1)
          if self.copy_flash_idx == r.idx then self.copy_flash_idx = nil; core.redraw = true end
        end)
        core.redraw = true
        return true
      end
    end
  end

  -- Send/Stop button
  if self.hover_send then
    if self:state().process then
      pcall(function() self:state().process:kill() end)
      self:state().process = nil
      self:state().status = "idle"
      if self:state().tmpfile then pcall(os.remove, self:state().tmpfile); self:state().tmpfile = nil end
      -- Append a small message indicating it was stopped
      if self:state().sessions[#self:state().sessions] and self:state().sessions[#self:state().sessions].role == "ai" then
        self:state().sessions[#self:state().sessions].text = (self:state().sessions[#self:state().sessions].text or "") .. "\n\n[Stopped by user]"
        self:state().sessions[#self:state().sessions].lines = nil
      end
    else
      local q = self:state().input:match("^%s*(.-)%s*$")
      if q and #q > 0 then self:submit(q) end
      self:state().input = ""
    end
    core.redraw = true
    return true
  end

  return false
end

function AGView:on_mouse_wheel(dy)
  self:state().scroll_y = math.max(0, math.min(self:state().max_scroll, self:state().scroll_y - dy * (style.font:get_height() + 2 * SCALE) * 3))
  core.redraw = true
  return true
end

-- ── Commands ──────────────────────────────────────────────────────────────────
command.add(nil, {
  ["antigravity:toggle"] = function()
    if not instance then instance = AGView() end

    if not node_built then
      local target = core.root_view:get_active_node_default()
      -- resizable=true makes the divider draggable by the user
      local new_node = target:split("right", instance, { x = true }, true)
      if new_node then
        new_node.size.x = 0
        instance.size.x = 0
      end
      node_built = true
    end

    instance.visible = not instance.visible
    if instance.visible then
      core.set_active_view(instance)
    else
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

  ["antigravity:focus"] = function()
    command.perform "antigravity:toggle"
    if instance and instance.visible then
      core.set_active_view(instance)
    end
  end,

  ["antigravity:explain"]  = function() command.perform("antigravity:submit", config.antigravity.actions[1].prompt) end,
  ["antigravity:refactor"] = function() command.perform("antigravity:submit", config.antigravity.actions[2].prompt) end,
  ["antigravity:fix"]      = function() command.perform("antigravity:submit", config.antigravity.actions[3].prompt) end,
  ["antigravity:tests"]    = function() command.perform("antigravity:submit", config.antigravity.actions[4].prompt) end,
  ["antigravity:docs"]     = function() command.perform("antigravity:submit", config.antigravity.actions[5].prompt) end,
  ["antigravity:submit"]   = function(prompt)
    if not instance or not instance.visible then
      command.perform("antigravity:toggle")
    end
    if instance then
      instance:submit(prompt)
      core.set_active_view(instance)
    end
  end,
  ["antigravity:ask"]      = function()
    core.command_view:enter("Ask Antigravity", {
      submit = function(text)
        command.perform("antigravity:submit", text)
      end
    })
  end,
  ["antigravity:auth"] = function()
    core.command_view:enter("Press Enter to launch Auth Terminal (follow instructions in the new window)", {
      submit = function(text)
        local cfg = config.antigravity
        if PLATFORM == "Windows" then
          process.start({ "cmd.exe", "/c", "start", "cmd.exe", "/k", "echo Launching Antigravity Authentication... && " .. cfg.cli }, {
            stdin = process.REDIRECT_DISCARD,
          })
        elseif PLATFORM == "Mac OS X" then
          process.start({ "osascript", "-e", 'tell app "Terminal" to do script "' .. cfg.cli .. '"' }, {
            stdin = process.REDIRECT_DISCARD,
          })
        else
          pcall(function() process.start({ "x-terminal-emulator", "-e", cfg.cli }, {
            stdin = process.REDIRECT_DISCARD,
          }) end)
        end
        core.log("Antigravity: If a terminal did not open automatically, please open your terminal and manually run: " .. cfg.cli)
        
        if not instance then instance = AGView() end
        instance.auth_status = "checking"
        
        core.add_thread(function()
          coroutine.yield(15) -- wait 15 seconds for them to complete the browser login
          if instance then
            instance:fetch_models()
          end
        end)
      end
    })
  end,
})

-- ── Status Bar Item ───────────────────────────────────────────────────────────
local StatusView = require "core.statusview"

core.status_view:add_item({
  name = "antigravity:auth",
  alignment = StatusView.Item.RIGHT,
  get_item = function()
    local text = "🤖 AGY Auth"
    if instance then
      if instance.auth_status == "logged_in" then
        text = "🤖 " .. (os.getenv("USERNAME") or "AGY Connected")
      elseif instance.auth_status == "auth_error" then
        text = "🤖 Retry Auth[click here again]"
      end
    end
    return {
      style.font,
      style.text,
      text
    }
  end,
  command = "antigravity:auth",
  tooltip = "Sign in to Antigravity / Manage Auth"
})

-- Hook the StatusView draw function to guarantee the entire status bar text is highly contrasted
local old_sv_draw = StatusView.draw
function StatusView:draw(...)
  local old_text = style.text
  local old_dim = style.dim
  local old_accent = style.accent

  local bg = style.background2 or {0,0,0,255}
  
  -- If background is light, force text to very dark colors
  if lum(bg[1], bg[2], bg[3]) > 128 then
    style.text = { 0, 0, 0, 255 }
    style.dim = { 80, 80, 80, 255 }
    style.accent = { 0, 50, 150, 255 }
  -- If background is dark, force text to very light colors
  else
    style.text = { 255, 255, 255, 255 }
    style.dim = { 180, 180, 180, 255 }
  end

  old_sv_draw(self, ...)

  style.text = old_text
  style.dim = old_dim
  style.accent = old_accent
end

-- Bind local commands that only activate when AI Sidebar is focused
command.add(
  function() return core.active_view == instance end,
  {
    ["antigravity:return"]    = function() instance:on_key_pressed("return") end,
    ["antigravity:backspace"] = function() instance:on_key_pressed("backspace") end,
    ["antigravity:scroll-up"] = function() instance:on_key_pressed("up") end,
    ["antigravity:scroll-down"] = function() instance:on_key_pressed("down") end,
  }
)

local keymap = require "core.keymap"
keymap.add {
  ["return"]    = "antigravity:return",
  ["backspace"] = "antigravity:backspace",
  ["up"]        = "antigravity:scroll-up",
  ["down"]      = "antigravity:scroll-down",
}

local ok, contextmenu = pcall(require, "plugins.contextmenu")
if ok then
  local ContextMenu = require "core.contextmenu"
  contextmenu:register("core.docview", {
    ContextMenu.DIVIDER,
    { text = "Explain Code with AI",  command = "antigravity:explain" },
    { text = "Refactor Code with AI", command = "antigravity:refactor" },
    { text = "Fix Code with AI",      command = "antigravity:fix" },
    { text = "Generate Unit Tests",   command = "antigravity:tests" },
    { text = "Generate Documentation",command = "antigravity:docs" },
  })
end
