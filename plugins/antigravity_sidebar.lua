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

-- A session is { role="user"|"ai", text=string, lines={} }
function AGView:new()
  AGView.super.new(self)
  self.visible     = true
  self.target_size = config.antigravity.target_width * SCALE
  self.size.x      = 0
  self.scrollable  = true
  self.input       = ""
  self.status      = "idle"
  self.process     = nil
  self.tmpfile     = nil
  self.scroll_y    = 0
  self.max_scroll  = 0
  self.hover_btn   = nil
  self.hover_send  = false
  self.tick        = 0
  self.sessions    = {}   -- list of { role, text, lines }
  self._chat_height = 0
  self.mention_suggestions = nil
  self.mention_idx = 1
  self.has_session = false
  self.warned_slow = false
  self.started_at  = 0
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
  local mention_prefix = self.input:match("@([^%s]*)$")
  if mention_prefix then
    self.mention_suggestions = get_mention_suggestions(mention_prefix)
    self.mention_idx = 1
  else
    self.mention_suggestions = nil
  end
  core.redraw = true
end

function AGView:get_name() return "Antigravity" end

local function _session_lines(self, text, role)
  local pad  = 10 * SCALE
  local w    = self.size.x - 2 * pad - 8 * SCALE
  local font = role == "user" and style.font or style.code_font
  return wrap_text(font, text, w)
end

function AGView:_add_session(role, text)
  local entry = { role = role, text = text, lines = {} }
  -- compute wrapped lines lazily in draw (size might not be set yet)
  table.insert(self.sessions, entry)
end

function AGView:submit(prompt_text)
  if self.process then return end
  if not prompt_text or #prompt_text:match("^%s*(.-)%s*$") == 0 then return end
  prompt_text = prompt_text:match("^%s*(.-)%s*$")

  -- Block execution and prompt login if not authenticated
  if self.auth_status == "auth_error" then
    core.error("Antigravity: You are not logged in! Please sign in to chat.")
    self.input = prompt_text -- restore input so they don't lose their prompt
    command.perform("antigravity:auth")
    return
  end

  -- Add user message to chat
  self:_add_session("user", prompt_text)

  local fname = nil
  local av = core.active_view
  if av and av.doc then fname = av.doc.filename end

  local full_prompt = prompt_text
  if fname then
    full_prompt = string.format("Regarding the active file %s: %s", fname, prompt_text)
  end

  self.status               = "running"
  self._ai_buf              = ""  -- accumulate streaming response
  self._ai_displayed_chars  = 0   -- typewriter effect
  self.started_at           = os.time()
  self.warned_slow  = false
  self:_add_session("ai", "")  -- placeholder entry

  local cfg  = config.antigravity
  local argv = { cfg.cli }

  -- Continue existing conversation after the first message
  if self.has_session then
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

  local p, err, code = process.start(argv, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })

  if p then
    self.process = p
    self.has_session = true
  else
    self.sessions[#self.sessions].text = "ERROR: could not start agy CLI.\nPath tried: " .. cfg.cli .. "\nError: " .. tostring(err)
    self.status = "error"
  end
  core.redraw = true
end

function AGView:update()
  AGView.super.update(self)
  self.tick = (self.tick + 1) % 120

  -- Size animation (treeview pattern)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "x", dest, nil, "antigravity")

  -- ── Drain model-fetch process ────────────────────────────────────────
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
      buf = buf .. chunk
    end
    if #buf > 0 then
      self._model_raw = (self._model_raw or "") .. buf
    end
    
    local m_elapsed = os.time() - (self.model_started_at or os.time())
    if self.model_proc:returncode() ~= nil then
      local parsed = parse_model_list(self._model_raw or "")
      if #parsed > 0 then
        self.model_list = parsed
        self.auth_status = "logged_in"
      else
        self.auth_status = "auth_error"
        self.model_list = {
          { name = "gemini-2.5-flash", limited = false },
          { name = "gemini-2.5-pro", limited = false },
          { name = "gemini-2.5-flash-thinking", limited = false }
        }
      end
      self._model_raw = ""
      self.model_proc = nil
      core.redraw = true
    elseif m_elapsed > 10 then
      pcall(function() self.model_proc:kill() end)
      self.model_proc = nil
      self._model_raw = ""
      self.auth_status = "auth_error"
      self.model_list = {
        { name = "gemini-2.5-flash", limited = false },
        { name = "gemini-2.5-pro", limited = false },
        { name = "gemini-2.5-flash-thinking", limited = false }
      }
      core.redraw = true
    end
  end

  local ai_len = self._ai_buf and #self._ai_buf or 0
  local is_typing = self._ai_displayed_chars and (self._ai_displayed_chars < ai_len)

  if not self.process and not is_typing then return end

  if self.process then
    local dirty = false
    -- Drain stdout completely in large chunks
    while true do
      local out = self.process:read_stdout(65536)
      if not out or #out == 0 then break end
      self._ai_buf = (self._ai_buf or "") .. out
      dirty = true
    end
    
    -- Drain stderr completely
    while true do
      local err = self.process:read_stderr(65536)
      if not err or #err == 0 then break end
      self._ai_buf = (self._ai_buf or "") .. err
      dirty = true
    end
    
    local rc = self.process:returncode()
    if rc ~= nil then
      -- Final drain in case pipe hasn't fully flushed before exit
      while true do
        local out = self.process:read_stdout(65536)
        if not out or #out == 0 then break end
        self._ai_buf = (self._ai_buf or "") .. out
      end
      while true do
        local err = self.process:read_stderr(65536)
        if not err or #err == 0 then break end
        self._ai_buf = (self._ai_buf or "") .. err
      end

      self.process = nil
      self.status  = (rc == 0) and "idle" or "error"
      if self._ai_buf == "" then
        self._ai_buf = string.format("(no output — process exited with code %s)", tostring(rc))
      end
      if self.tmpfile then pcall(os.remove, self.tmpfile); self.tmpfile = nil end
    end
  end

  ai_len = self._ai_buf and #self._ai_buf or 0
  is_typing = self._ai_displayed_chars and (self._ai_displayed_chars < ai_len)

  -- Typewriter effect logic
  if is_typing then
    -- Reveal characters (approx 60fps * 30 chars = 1800 chars/sec)
    self._ai_displayed_chars = math.min(ai_len, self._ai_displayed_chars + 30)
    
    if self.sessions[#self.sessions] and self.sessions[#self.sessions].role == "ai" then
      self.sessions[#self.sessions].text  = self._ai_buf:sub(1, self._ai_displayed_chars)
      self.sessions[#self.sessions].lines = nil  -- invalidate cache
      self.scroll_to_bottom = true
    end
    core.redraw = true
  end

  if not self.process then return end

  local elapsed = os.time() - (self.started_at or os.time())
  -- Soft warning at 45s
  if elapsed > 45 and self._ai_buf == "" and not self.warned_slow then
    self.warned_slow = true
    core.redraw = true
  end
  -- Hard kill at 315s (5m15s) — surface a fix message instead of hanging forever
  -- The agy CLI itself defaults to a 5m wait, so we give it slightly longer.
  if elapsed > 315 and self._ai_buf == "" and self.process then
    pcall(function() self.process:kill() end)
    self.process = nil
    self.status  = "error"
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
    if self.sessions[#self.sessions] then
      self.sessions[#self.sessions].text  = fix_msg
      self.sessions[#self.sessions].lines = nil
    end
    -- Notify auto-healer so it can log and potentially offer to run agy install
    core.error("[Antigravity] CLI timed out — agy install may be required.")
    core.redraw = true
  end

  -- (Model fetch logic was moved to the top of update())
end

-- Kick off background fetch of model list
function AGView:fetch_models()
  if self.model_proc then return end
  self._model_raw = ""
  self.model_started_at = os.time()
  local cfg = config.antigravity
  
  -- Wrap in cmd.exe with < NUL to prevent agy from hanging if it tries to read stdin for auth
  local p = process.start({ "cmd.exe", "/c", cfg.cli, "models", "<", "NUL" }, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if p then 
    self.model_proc = p
  end
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
  local dot_col = self.status == "running" and P.dot_run
               or self.status == "error"   and P.dot_err
               or P.dot_idle
  local dot_r = 5 * SCALE
  renderer.draw_rect(x + pad, cur_y + math.floor(hdr_h/2) - dot_r, dot_r*2, dot_r*2, dot_col)

  -- Title
  renderer.draw_text(style.big_font or style.font, "Antigravity",
    x + pad + dot_r*2 + 6 * SCALE,
    cur_y + math.floor((hdr_h - (style.big_font or style.font):get_height()) / 2),
    P.fg_accent)

  -- Status + Model button row (right side of header)
  local status_str = self.status == "running"
    and (self.warned_slow and "slow." or "thinking.")
    or  self.status == "error" and "error"
    or  "ready"
  local ss_w = style.font:get_width(status_str)
  renderer.draw_text(style.font, status_str,
    x + w - ss_w - pad - 8 * SCALE,
    cur_y + math.floor((hdr_h - style.font:get_height()) / 2),
    self.status == "error" and P.dot_err or P.fg_muted)

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
  local display    = #self.input > 0 and self.input or "Ask anything about your code."
  local fg_inp     = #self.input > 0 and P.fg or P.fg_muted

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
    local cw = style.font:get_width(self.input)
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
    send_bg = self.process and { common.color "#903030" } or P.bg_send_hl
  end
  renderer.draw_rect(inp_x, send_y, inp_w, send_h, send_bg)

  local send_lbl = self.process and "  Stop Generating" or "  Send"
  renderer.draw_text(style.font, send_lbl,
    inp_x + math.floor((inp_w - style.font:get_width(send_lbl)) / 2),
    send_y + math.floor((send_h - style.font:get_height()) / 2),
    P.fg_send)

  -- Store send button bounds for click detection
  self._send_rect = { x = inp_x, y = send_y, w = inp_w, h = send_h }

  -- ═══════════════════════════════════════════════════════════════════
  -- CHAT HISTORY (scrollable, between quick-actions and input)
  -- ═══════════════════════════════════════════════════════════════════
  local chat_top = cur_y
  local chat_h   = chat_bot - chat_top

  -- Clip: draw a bg rect to mask overflow
  renderer.draw_rect(x, chat_top, w, chat_h, P.bg)

  local lh_f = style.font:get_height() + 2 * SCALE
  local lh_c = style.code_font:get_height() + 2 * SCALE
  local ty    = chat_top + 4 * SCALE - self.scroll_y
  local total_h = 0

  for _, sess in ipairs(self.sessions) do
    local is_user = sess.role == "user"
    local font    = is_user and style.font or style.code_font
    local lh      = is_user and lh_f or lh_c
    local msg_pad = 8 * SCALE
    local msg_w   = w - 2 * pad - 4 * SCALE
    local bg_col  = is_user and P.bg_user_msg or P.bg_ai_msg
    local fg_col  = is_user and P.fg_user or P.fg_ai

    -- Cache wrapped lines (invalidated when text changes)
    if not sess.lines or sess._cached_text ~= sess.text then
      sess.lines = wrap_text(font, sess.text, msg_w - 2 * msg_pad)
      sess._cached_text = sess.text
    end

    local msg_h = math.max(lh, #sess.lines * lh) + 2 * msg_pad

    -- Role label
    if ty + msg_h + lh >= chat_top and ty <= chat_bot then
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

    -- Lines of text inside bubble
    local line_y = ty + msg_pad
    for _, line in ipairs(sess.lines) do
      if line_y + lh >= chat_top and line_y <= chat_bot then
        renderer.draw_text(font, line, x + pad + msg_pad, line_y, fg_col)
      end
      line_y = line_y + lh
    end

    -- Spinner on last AI message while running
    if self.status == "running" and not is_user
       and sess == self.sessions[#self.sessions]
       and #sess.lines == 0 then
      local dots = string.rep("•", (math.floor(self.tick / 20) % 4))
      renderer.draw_text(style.font, dots,
        x + pad + msg_pad, ty + msg_pad, P.fg_muted)
    end

    ty = ty + msg_h + 6 * SCALE
    total_h = total_h + style.font:get_height() + 2 * SCALE + msg_h + 6 * SCALE
  end

  self.max_scroll = math.max(0, total_h - chat_h)

  -- Empty state
  if #self.sessions == 0 then
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
  if self.mention_suggestions and #self.mention_suggestions > 0 then
    local pop_w = w - 2 * pad
    local item_h = style.font:get_height() + 8 * SCALE
    local pop_h = #self.mention_suggestions * item_h
    local pop_x = x + pad
    local pop_y = inp_y - pop_h - 4 * SCALE
    
    renderer.draw_rect(pop_x, pop_y, pop_w, pop_h, P.bg_darker)
    draw_rect_outline(pop_x, pop_y, pop_w, pop_h, P.border)
    
    for i, file in ipairs(self.mention_suggestions) do
      local iy = pop_y + (i - 1) * item_h
      if i == self.mention_idx then
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
  self.input = self.input .. text
  self:_update_mentions()
  core.redraw = true
end

function AGView:on_key_pressed(key, ...)
  if self.mention_suggestions and #self.mention_suggestions > 0 then
    if key == "up" then
      self.mention_idx = math.max(1, self.mention_idx - 1)
      core.redraw = true
      return true
    elseif key == "down" then
      self.mention_idx = math.min(#self.mention_suggestions, self.mention_idx + 1)
      core.redraw = true
      return true
    elseif key == "return" or key == "tab" then
      local choice = self.mention_suggestions[self.mention_idx]
      self.input = self.input:gsub("@[^%s]*$", "@" .. choice .. " ")
      self.mention_suggestions = nil
      core.redraw = true
      return true
    elseif key == "escape" then
      self.mention_suggestions = nil
      core.redraw = true
      return true
    end
  end

  local mods = keymap.modkeys or {}

  if key == "return" and not mods["ctrl"] then
    local q = self.input:match("^%s*(.-)%s*$")
    if q and #q > 0 then self:submit(q) end
    self.input = ""
    core.redraw = true
    return true
  end

  if key == "return" and mods["ctrl"] then
    -- Ctrl+Enter: clear chat
    self.sessions = {}
    self.input    = ""
    self.status   = "idle"
    self.has_session = false
    if self.process then pcall(function() self.process:kill() end) end
    self.process  = nil
    core.redraw = true
    return true
  end

  if key == "backspace" then
    local text = self.input
    if #text > 0 then
      local i = #text
      -- Step back over UTF-8 continuation bytes (10xxxxxx)
      while i > 0 and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do
        i = i - 1
      end
      self.input = text:sub(1, math.max(0, i - 1))
      self:_update_mentions()
      core.redraw = true
    end
    return true
  end

  if key == "up" then
    self.scroll_y = math.max(0, self.scroll_y - (style.font:get_height() + 2 * SCALE) * 3)
    core.redraw = true
    return true
  end
  if key == "down" then
    self.scroll_y = math.min(self.max_scroll, self.scroll_y + (style.font:get_height() + 2 * SCALE) * 3)
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

  -- Model picker row selection
  if self.show_model_picker and self._mpicker_rects then
    for _, r in ipairs(self._mpicker_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        local m = self.model_list[r.idx]
        if m then
          config.antigravity.selected_model = m.name
          self.show_model_picker = false
          self.has_session = false  -- reset session so next -p doesn't pass -c with old model
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

  -- Send/Stop button
  if self.hover_send then
    if self.process then
      pcall(function() self.process:kill() end)
      self.process = nil
      self.status = "idle"
      if self.tmpfile then pcall(os.remove, self.tmpfile); self.tmpfile = nil end
      -- Append a small message indicating it was stopped
      if self.sessions[#self.sessions] and self.sessions[#self.sessions].role == "ai" then
        self.sessions[#self.sessions].text = (self.sessions[#self.sessions].text or "") .. "\n\n[Stopped by user]"
        self.sessions[#self.sessions].lines = nil
      end
    else
      local q = self.input:match("^%s*(.-)%s*$")
      if q and #q > 0 then self:submit(q) end
      self.input = ""
    end
    core.redraw = true
    return true
  end

  return false
end

function AGView:on_mouse_wheel(dy)
  self.scroll_y = math.max(0, math.min(self.max_scroll, self.scroll_y - dy * (style.font:get_height() + 2 * SCALE) * 3))
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

  ["antigravity:explain"]  = function() if instance then instance:submit(config.antigravity.actions[1].prompt) end end,
  ["antigravity:refactor"] = function() if instance then instance:submit(config.antigravity.actions[2].prompt) end end,
  ["antigravity:fix"]      = function() if instance then instance:submit(config.antigravity.actions[3].prompt) end end,
  ["antigravity:tests"]    = function() if instance then instance:submit(config.antigravity.actions[4].prompt) end end,
  ["antigravity:docs"]     = function() if instance then instance:submit(config.antigravity.actions[5].prompt) end end,
  ["antigravity:submit"]   = function(prompt)
    if not instance or not instance.visible then
      command.perform("antigravity:toggle")
    end
    if instance then
      instance:submit(prompt)
      core.set_active_view(instance)
    end
  end,
  ["antigravity:auth"] = function()
    core.command_view:enter("Sign in to Antigravity (Press Enter to launch browser or paste token)", {
      submit = function(text)
        local cfg = config.antigravity
        -- Launch a visible terminal for the interactive auth process so the user can see what's happening
        process.start({ "cmd.exe", "/c", "start", "cmd.exe", "/k", "echo Launching Antigravity Authentication... && " .. cfg.cli .. " install" })
        core.log("Antigravity: Authentication terminal opened. Please follow the instructions in the new window.")
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
