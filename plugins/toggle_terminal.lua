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
end

-- Called by the node system when the user drags the resize divider
function TermView:set_target_size(axis, value)
  if axis == "y" then
    self.target_size = math.max(config.terminal.min_height * SCALE, value)
    return true
  end
end

function TermView:get_name() return "Terminal" end

function TermView:_push(kind, text)
  -- Strip ANSI escape codes
  text = text:gsub("\27%[[%d;]*[A-Za-z]", "")
             :gsub("\r\n", "\n"):gsub("\r", "")
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(self.lines, { text = line, kind = kind })
  end
  while #self.lines > config.terminal.scrollback do
    table.remove(self.lines, 1)
  end
  -- Auto-scroll to bottom
  core.redraw = true
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

  -- Size animation (same pattern as built-in treeview)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "y", dest, nil, "terminal")

  -- Drain process output
  if self.proc then
    -- Drain stdout completely
    while true do
      local out = self.proc:read_stdout(4096)
      if not out or #out == 0 then break end
      self:_push("out", out)
    end
    
    -- Drain stderr completely
    while true do
      local err = self.proc:read_stderr(4096)
      if not err or #err == 0 then break end
      self:_push("err", err)
    end

    local rc = self.proc:returncode()
    if rc ~= nil then
      self:_push("info", string.format("[exited: %d]", rc))
      self.proc = nil
    end
  end

  -- Keep scroll pinned to bottom when output arrives
  if #self.lines > 0 then
    local lh    = style.code_font:get_height() + 2 * SCALE
    local total = #self.lines * lh
    local inner = math.max(0, self.size.y - 54 * SCALE)
    self.scroll_y = math.max(0, total - inner)
  end
end

function TermView:draw()
  if self.size.y < 2 then return end  -- fully hidden

  local bg     = tc("terminal_bg",   "#2D3B28")
  local fg     = tc("terminal_text", "#D4E8C8")
  local col_cmd= { common.color "#8EC07C" }
  local col_err= { common.color "#FB4934" }
  local col_inf= { common.color "#6B8A60" }
  local border = tc("status_bg",     "#597450")
  local inp_bg = { common.color "#243020" }
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y

  -- Full background
  renderer.draw_rect(x, y, w, h, bg)

  -- Top border accent
  renderer.draw_rect(x, y, w, 2 * SCALE, border)

  -- ── Header ─────────────────────────────────────────────────────────────────
  local hdr_h = 26 * SCALE
  renderer.draw_rect(x, y + 2 * SCALE, w, hdr_h, { common.color "#243020" })

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

  local hint = "ctrl+`  to hide"
  renderer.draw_text(style.font, hint,
    x + w - style.font:get_width(hint) - 10 * SCALE,
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
      self:run(cmd)
    end
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
  if key == "ctrl+c" then
    if self.proc then
      self.proc:terminate()   -- SIGTERM first
      self.proc = nil
      self:_push("info", "^C (terminated)")
    else
      self.input = ""
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
    core.redraw = true
    return true
  end
  if key == "pagedown" then
    local lh = style.code_font:get_height() + 2 * SCALE
    self.scroll_y = self.scroll_y + lh * 8
    core.redraw = true
    return true
  end
  return false
end

function TermView:on_mouse_wheel(dy)
  local lh = style.code_font:get_height() + 2 * SCALE
  self.scroll_y = math.max(0, self.scroll_y - dy * lh * 3)
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
})
