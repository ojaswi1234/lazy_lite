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

-- ── Palette (all pixel-sampled from reference) ────────────────────────────────
local P = {
  bg           = { common.color "#E4EAD0" },
  bg_dark      = { common.color "#D8E4C0" },
  bg_darker    = { common.color "#C8D8B0" },
  bg_input     = { common.color "#F0F5E4" },
  bg_user_msg  = { common.color "#BFD3A7" },
  bg_ai_msg    = { common.color "#EEF3E2" },
  bg_btn       = { common.color "#CDD8B4" },
  bg_btn_hl    = { common.color "#A8C28A" },
  bg_send      = { common.color "#597450" },
  bg_send_hl   = { common.color "#4A6A3A" },
  fg           = { common.color "#405335" },
  fg_muted     = { common.color "#7A9B6A" },
  fg_accent    = { common.color "#2D3B28" },
  fg_user      = { common.color "#2D3B28" },
  fg_ai        = { common.color "#405335" },
  fg_code      = { common.color "#4F4C4E" },
  fg_send      = { common.color "#F0F5E4" },
  fg_label     = { common.color "#5C6B55" },
  border       = { common.color "#CDD3BB" },
  border_input = { common.color "#A8C28A" },
  dot_idle     = { common.color "#A8AE8C" },
  dot_run      = { common.color "#5F8C32" },
  dot_err      = { common.color "#AA383B" },
  scrollbar    = { common.color "#C5D9A8" },
}

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

-- Wrap text into lines that fit within max_w pixels using given font
local function wrap_text(font, text, max_w)
  local lines = {}
  for _, raw in ipairs((text .. "\n"):gmatch("([^\n]*)\n") and {} or {}) do end
  -- simple approach: split on newlines first, then wrap long ones
  for raw_line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if font:get_width(raw_line) <= max_w then
      table.insert(lines, raw_line)
    else
      -- word-wrap
      local cur = ""
      for word in (raw_line .. " "):gmatch("(%S+)%s") do
        local try = cur == "" and word or (cur .. " " .. word)
        if font:get_width(try) > max_w and #cur > 0 then
          table.insert(lines, cur)
          cur = word
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
end

-- Called by the node system when the user drags the resize divider
function AGView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = math.max(180 * SCALE, value)  -- minimum 180px
    return true
  end
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

  -- Add user message to chat
  self:_add_session("user", prompt_text)

  local fname, ftext = get_context()
  local body = string.format(
    "FILE: %s\n\nCODE:\n```\n%s\n```\n\nINSTRUCTION: %s\n",
    fname or "unknown", ftext or "", prompt_text
  )

  self.status   = "running"
  self._ai_buf  = ""  -- accumulate streaming response
  self:_add_session("ai", "")  -- placeholder entry

  -- Write to temp file in USERDIR to guarantee absolute path safely
  local tmp = USERDIR .. "/agy_prompt_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".txt"
  local f   = io.open(tmp, "w")
  if f then f:write(body); f:close(); self.tmpfile = tmp end

  local cfg  = config.antigravity
  
  -- Ask agy to read the temp file, avoiding multi-line arguments in process.start which break on Windows.
  local safe_prompt = "Read this file and follow the instruction inside: " .. (self.tmpfile or "unknown")
  
  local p, err, code = process.start({ cfg.cli, "-p", safe_prompt }, {
    stdin  = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })

  if p then
    self.process = p
  else
    self.sessions[#self.sessions].text = "ERROR: could not start agy CLI.\nPath tried: " .. cfg.cli .. "\nError: " .. tostring(err)
    self.status = "error"
    if self.tmpfile then pcall(os.remove, self.tmpfile); self.tmpfile = nil end
  end
  core.redraw = true
end

function AGView:update()
  AGView.super.update(self)
  self.tick = (self.tick + 1) % 120

  -- Size animation (treeview pattern)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "x", dest, nil, "antigravity")

  if not self.process then return end

  local dirty = false

  -- Drain stdout completely
  while true do
    local out = self.process:read_stdout(4096)
    if not out or #out == 0 then break end
    self._ai_buf = (self._ai_buf or "") .. out
    dirty = true
  end
  
  -- Drain stderr completely
  while true do
    local err = self.process:read_stderr(4096)
    if not err or #err == 0 then break end
    self._ai_buf = (self._ai_buf or "") .. err
    dirty = true
  end

  if dirty then
    if self.sessions[#self.sessions] and self.sessions[#self.sessions].role == "ai" then
      self.sessions[#self.sessions].text  = self._ai_buf
      self.sessions[#self.sessions].lines = nil  -- invalidate cache
    end
    core.redraw = true
  end

  local rc = self.process:returncode()
  if rc ~= nil then
    self.process = nil
    self.status  = (rc == 0) and "idle" or "error"
    if self.tmpfile then pcall(os.remove, self.tmpfile); self.tmpfile = nil end
    core.redraw = true
  end
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

  -- Status label (right side)
  local status_str = self.status == "running" and "thinking…"
                  or self.status == "error"   and "error"
                  or "ready"
  local ss_w = style.font:get_width(status_str)
  renderer.draw_text(style.font, status_str,
    x + w - ss_w - pad - 8 * SCALE,
    cur_y + math.floor((hdr_h - style.font:get_height()) / 2),
    self.status == "error" and P.dot_err or P.fg_muted)

  cur_y = cur_y + hdr_h

  -- ═══════════════════════════════════════════════════════════════════
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
  local display    = #self.input > 0 and self.input or "Ask anything about your code…"
  local fg_inp     = #self.input > 0 and P.fg or P.fg_muted
  renderer.draw_text(style.font, display,
    inp_x + 8 * SCALE,
    inp_y + 8 * SCALE,
    fg_inp)

  -- Blink cursor
  if core.active_view == self and math.floor(self.tick / 30) % 2 == 0 then
    local cw = style.font:get_width(self.input)
    renderer.draw_rect(inp_x + 8 * SCALE + cw, inp_y + 8 * SCALE,
      2 * SCALE, style.font:get_height(), P.fg_accent)
  end

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
    local em1 = "No conversation yet."
    local em2 = "Select code and press a quick"
    local em3 = "action, or type below."
    local ems = { em1, em2, em3 }
    local emy = chat_top + math.floor(chat_h / 2) - #ems * lh_f
    for _, em in ipairs(ems) do
      local emw = style.font:get_width(em)
      renderer.draw_text(style.font, em,
        x + math.floor((w - emw) / 2), emy, P.fg_muted)
      emy = emy + lh_f + 2 * SCALE
    end
  end
end

-- ── Input ──────────────────────────────────────────────────────────────────────
function AGView:on_text_input(text)
  self.input = self.input .. text
  core.redraw = true
end

function AGView:on_key_pressed(key)
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
    if self.process then pcall(function() self.process:kill() end) end
    self.process  = nil
    if self.tmpfile then pcall(os.remove, self.tmpfile); self.tmpfile = nil end
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

  core.redraw = true
end

function AGView:on_mouse_pressed(button, mx, my, clicks)
  AGView.super.on_mouse_pressed(self, button, mx, my, clicks)
  if button ~= "left" then return false end

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
