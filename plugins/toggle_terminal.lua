-- mod-version:3
-- Terminal bottom sheet (Ctrl+`)
-- Uses size animation (like treeview) for hide/show — no node removal needed.
-- Command-runner mode: each Enter runs cmd.exe /c <command> (reliable on Windows).

local core    = require "core"
local config  = require "core.config"
local style   = require "core.style"
local command = require "core.command"
local common  = require "core.common"
local View    = require "core.view"
local process = require "process"

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
local node_built = false -- have we added to node tree yet?

function TermView:new()
  TermView.super.new(self)
  self.visible      = true   -- controls size animation (treeview pattern)
  self.target_size  = config.terminal.target_height * SCALE
  self.size.y       = 0      -- start collapsed; animate on first show
  self.lines        = {}     -- { text, kind }  kind = "cmd"|"out"|"err"|"info"
  self.input        = ""     -- current command being typed
  self.scroll_y     = 0
  self.proc         = nil    -- running process (if any)
  self:_push("info", "Terminal ready. Type a command and press Enter.")
  if PLATFORM == "Windows" then
    self:_push("info", "Running on Windows — each command uses cmd.exe /c")
  end
  self.is_fullscreen = false
  self.scroll_to_bottom = true
  self.history = {}
  self.history_idx = 1
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
function TermView:_push_chunk(kind, chunk)
  local buf_key = kind .. "_buf"
  self[buf_key] = (self[buf_key] or "") .. chunk
  
  local buf = self[buf_key]
  local last_nl = 0
  
  for i = 1, #buf do
    if buf:byte(i) == 10 then -- '\n'
      local line = buf:sub(last_nl + 1, i - 1)
      if #line > 0 and line:byte(#line) == 13 then -- strip '\r'
        line = line:sub(1, -2)
      end
      if #line > 0 then
        table.insert(self.lines, { kind = kind, text = line })
      end
      last_nl = i
    end
  end
  
  if last_nl > 0 then
    self[buf_key] = buf:sub(last_nl + 1)
    self.scroll_to_bottom = true
  end
  while #self.lines > config.terminal.scrollback do
    table.remove(self.lines, 1)
  end
  core.redraw = true
end

function TermView:_push(kind, text)
  self:_push_chunk(kind, text .. "\n")
end

-- Run a command string asynchronously
function TermView:run(cmd_str)
  if self.proc then
    self:_push("err", "A command is already running. Wait for it to finish.")
    return
  end
  self:_push("cmd", "> " .. cmd_str)

  -- Build argv
  -- On Windows, passing the command as a single string to cmd /c works best for complex args
  local argv
  if PLATFORM == "Windows" then
    argv = { "cmd.exe", "/c", cmd_str }
  else
    local sh = os.getenv("SHELL") or "/bin/sh"
    argv = { sh, "-c", cmd_str }
  end

  local p, err, code = process.start(argv, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
    cwd    = core.project_dir
  })

  if p then
    self.proc = p
  else
    self:_push("err", "ERROR: " .. tostring(err) .. " (code " .. tostring(code) .. ")")
  end
end

function TermView:update()
  TermView.super.update(self)

  -- Fullscreen overrides target_size
  if self.is_fullscreen then
    self.target_size = math.max(config.terminal.target_height * SCALE, core.root_view.size.y - (40 * SCALE))
  end

  -- Size animation (same pattern as built-in treeview)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "y", dest, nil, "terminal")

  -- Drain process output using 64KB chunks for maximum IPC throughput
  if self.proc then
    while true do
      local out = self.proc:read_stdout(65536)
      if not out or #out == 0 then break end
      self:_push_chunk("out", out)
    end
    
    while true do
      local err = self.proc:read_stderr(65536)
      if not err or #err == 0 then break end
      self:_push_chunk("err", err)
    end

    local rc = self.proc:returncode()
    if rc ~= nil then
      self:_push_chunk("info", string.format("[exited: %d]\n", rc))
      self.proc = nil
    end
  end

  -- Handle scroll snapping
  if self.scroll_to_bottom and #self.lines > 0 then
    local lh    = style.code_font:get_height() + 2 * SCALE
    local total = #self.lines * lh
    local inner = math.max(0, self.size.y - 54 * SCALE)
    self.scroll_y = math.max(0, total - inner)
    self.scroll_to_bottom = false
  end
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
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y

  -- Full background
  renderer.draw_rect(x, y, w, h, bg)

  -- Top border accent
  renderer.draw_rect(x, y, w, 2 * SCALE, border)

  -- ── Header ─────────────────────────────────────────────────────────────────
  local hdr_h = 26 * SCALE
  renderer.draw_rect(x, y + 2 * SCALE, w, hdr_h, hdr_bg)

  -- Running indicator
  local status_dot = self.proc and "\xe2\x97\x8f " or "\xe2\x97\x8b "
  local status_col = self.proc and { common.color "#B8BB26" } or col_inf
  renderer.draw_text(style.font, status_dot,
    x + 8 * SCALE,
    y + 2 * SCALE + math.floor((hdr_h - style.font:get_height()) / 2),
    status_col)

  renderer.draw_text(style.font, "TERMINAL",
    x + 24 * SCALE,
    y + 2 * SCALE + math.floor((hdr_h - style.font:get_height()) / 2),
    fg)

  local hint = "ctrl+` to hide"
  local hint_w = style.font:get_width(hint)
  
  -- Button rendering
  local btn_text = self.is_fullscreen and "RESTORE" or "MAXIMIZE"
  local btn_w = style.font:get_width(btn_text) + 20 * SCALE
  local btn_x = x + w - btn_w
  local btn_y = y + 2 * SCALE

  self.btn_rect = { x = btn_x, y = btn_y, w = btn_w, h = hdr_h }
  local btn_bg = self.hovered_btn and get_contrast_bg(hdr_bg) or hdr_bg
  local btn_fg = self.hovered_btn and fg or col_inf

  renderer.draw_rect(btn_x, btn_y, btn_w, hdr_h, btn_bg)
  renderer.draw_text(style.font, btn_text,
    btn_x + 10 * SCALE,
    btn_y + math.floor((hdr_h - style.font:get_height()) / 2),
    btn_fg)

  -- Draw hint to the left of the button
  renderer.draw_text(style.font, hint,
    btn_x - hint_w - 15 * SCALE,
    y + 2 * SCALE + math.floor((hdr_h - style.font:get_height()) / 2),
    col_inf)

  -- Divider
  renderer.draw_rect(x, y + hdr_h + 2 * SCALE, w, 1 * SCALE, border)

  -- ── Scrollable output ───────────────────────────────────────────────────────
  local inp_h   = 28 * SCALE
  local out_top = y + hdr_h + 3 * SCALE
  local out_bot = y + h - inp_h - 4 * SCALE
  local out_h   = out_bot - out_top

  local lh     = style.code_font:get_height() + 2 * SCALE
  local text_y = out_top + 4 * SCALE - self.scroll_y
  local text_x = x + 10 * SCALE

  for _, ln in ipairs(self.lines) do
    if text_y + lh >= out_top and text_y <= out_bot then
      local col = ln.kind == "cmd"  and col_cmd
               or ln.kind == "err"  and col_err
               or ln.kind == "info" and col_inf
               or fg
      renderer.draw_text(style.code_font, ln.text, text_x, text_y, col)
    end
    text_y = text_y + lh
    if text_y > out_bot + lh then break end
  end

  -- Divider above input
  renderer.draw_rect(x, out_bot + 1 * SCALE, w, 1 * SCALE, border)

  -- ── Input bar ───────────────────────────────────────────────────────────────
  local inp_y = y + h - inp_h
  renderer.draw_rect(x, inp_y, w, inp_h, inp_bg)

  local prompt = "> "
  local prompt_w = style.code_font:get_width(prompt)
  renderer.draw_text(style.code_font, prompt,
    text_x, inp_y + math.floor((inp_h - style.code_font:get_height()) / 2),
    col_cmd)

  local display_input = self.input
  renderer.draw_text(style.code_font, display_input,
    text_x + prompt_w,
    inp_y + math.floor((inp_h - style.code_font:get_height()) / 2),
    fg)

  -- Cursor
  if core.active_view == self then
    local cx = text_x + prompt_w + style.code_font:get_width(display_input)
    renderer.draw_rect(cx,
      inp_y + math.floor((inp_h - style.code_font:get_height()) / 2),
      2 * SCALE, style.code_font:get_height(),
      { common.color "#A9DC76" })
  end
end

-- ── Input ──────────────────────────────────────────────────────────────────────
function TermView:on_text_input(text)
  self.input = self.input .. text
  core.redraw = true
end

function TermView:on_key_pressed(key)
  if key == "return" then
    local cmd = self.input:match("^%s*(.-)%s*$")
    self.input = ""
    if cmd and #cmd > 0 then
      if self.history[#self.history] ~= cmd then
        table.insert(self.history, cmd)
      end
      self.history_idx = #self.history + 1
      
      -- Intercept clear commands to wipe the graphical buffer
      local lower_cmd = cmd:lower()
      if lower_cmd == "cls" or lower_cmd == "clear" then
        self.lines = {}
      end
      
      self:run(cmd)
    end
    core.redraw = true
    return true
  end
  if key == "up" then
    if #self.history > 0 and self.history_idx > 1 then
      self.history_idx = self.history_idx - 1
      self.input = self.history[self.history_idx]
      core.redraw = true
    end
    return true
  end
  if key == "down" then
    if #self.history > 0 and self.history_idx <= #self.history then
      self.history_idx = self.history_idx + 1
      self.input = self.history[self.history_idx] or ""
      core.redraw = true
    end
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
  if key == "ctrl+c" then
    if self.proc then
      pcall(function() self.proc:kill() end)
      self.proc = nil
      self:_push("info", "^C (terminated)")
    else
      self.input = ""
      self:_push("info", "^C")
    end
    core.redraw = true
    return true
  end
  if key == "ctrl+l" then
    self.lines = {}
    core.redraw = true
    return true
  end
  if key == "pageup" then
    local lh = style.code_font:get_height() + 2 * SCALE
    self.scroll_y = math.max(0, self.scroll_y - lh * 8)
    self.scroll_to_bottom = false
    core.redraw = true
    return true
  end
  if key == "pagedown" then
    local lh = style.code_font:get_height() + 2 * SCALE
    self.scroll_y = self.scroll_y + lh * 8
    self.scroll_to_bottom = false
    core.redraw = true
    return true
  end
  return false
end

function TermView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and self.btn_rect then
    local bx, by, bw, bh = self.btn_rect.x, self.btn_rect.y, self.btn_rect.w, self.btn_rect.h
    if x >= bx and x <= bx + bw and y >= by and y <= by + bh then
      command.perform("terminal:fullscreen")
      return true
    end
  end
  return false
end

function TermView:on_mouse_moved(x, y, dx, dy)
  local hover = false
  if self.btn_rect then
    local bx, by, bw, bh = self.btn_rect.x, self.btn_rect.y, self.btn_rect.w, self.btn_rect.h
    if x >= bx and x <= bx + bw and y >= by and y <= by + bh then
      hover = true
    end
  end
  if self.hovered_btn ~= hover then
    self.hovered_btn = hover
    core.redraw = true
  end
end

function TermView:on_mouse_left()
  if self.hovered_btn then
    self.hovered_btn = false
    core.redraw = true
  end
end

function TermView:on_mouse_wheel(dy)
  local lh = style.code_font:get_height() + 2 * SCALE
  self.scroll_y = math.max(0, self.scroll_y - dy * lh * 3)
  
  -- Clamp scroll
  local total = #self.lines * lh
  local inner = math.max(0, self.size.y - 54 * SCALE)
  local max_scroll = math.max(0, total - inner)
  self.scroll_y = math.max(0, math.min(max_scroll, self.scroll_y))
  
  self.scroll_to_bottom = false
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
    command.perform "terminal:toggle"
    if instance and instance.visible then
      core.set_active_view(instance)
    end
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
  }
)

local keymap = require "core.keymap"
keymap.add {
  ["return"]    = "terminal:return",
  ["backspace"] = "terminal:backspace",
  ["ctrl+c"]    = "terminal:interrupt",
  ["ctrl+l"]    = "terminal:clear",
  ["pageup"]    = "terminal:scroll-up",
  ["pagedown"]  = "terminal:scroll-down",
  ["up"]        = "terminal:history-up",
  ["down"]      = "terminal:history-down",
}

