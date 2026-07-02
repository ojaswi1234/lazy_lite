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

local shells = {}
if PLATFORM == "Windows" then
  table.insert(shells, { name = "Command Prompt", cmd = {"cmd.exe", "/c"}, prompt_prefix = "" })
  table.insert(shells, { name = "PowerShell", cmd = {"powershell.exe", "-NoProfile", "-Command"}, prompt_prefix = "PS " })
else
  local function has_cmd(c) return os.execute("command -v " .. c .. " >/dev/null 2>&1") == 0 end
  if has_cmd("bash") then table.insert(shells, { name = "bash", cmd = {"bash", "-c"}, prompt_prefix = "" }) end
  if has_cmd("zsh") then table.insert(shells, { name = "zsh", cmd = {"zsh", "-c"}, prompt_prefix = "" }) end
  table.insert(shells, { name = "sh", cmd = {"sh", "-c"}, prompt_prefix = "" })
end


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
  self.sessions = {}
  self.active_idx = 0
  self:add_session(shells[1])
  self.is_fullscreen = false
end

function TermView:state()
  return self.sessions[self.active_idx]
end

function TermView:add_session(shell_opts)
  shell_opts = shell_opts or shells[1]
  local s = {
    lines = {},
    input = "",
    scroll_y = 0,
    proc = nil,
    history = {},
    history_idx = 1,
    selection = nil,
    scroll_to_bottom = true,
    shell = shell_opts,
  }
  table.insert(self.sessions, s)
  self.active_idx = #self.sessions
  self:_push("info", shell_opts.name .. "
")
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
  self:state()[buf_key] = (self:state()[buf_key] or "") .. chunk
  
  local buf = self:state()[buf_key]
  local last_nl = 0
  
  for i = 1, #buf do
    if buf:byte(i) == 10 then -- '\n'
      local line = buf:sub(last_nl + 1, i - 1)
      if #line > 0 and line:byte(#line) == 13 then -- strip '\r'
        line = line:sub(1, -2)
      end
      if #line > 0 then
        table.insert(self:state().lines, { kind = kind, text = line })
      end
      last_nl = i
    end
  end
  
  if last_nl > 0 then
    self:state()[buf_key] = buf:sub(last_nl + 1)
    self:state().scroll_to_bottom = true
  end
  local n = #self:state().lines
  local overflow = n - config.terminal.scrollback
  if overflow > 0 then
    local new_lines = {}
    for i = overflow + 1, n do
      table.insert(new_lines, self:state().lines[i])
    end
    self:state().lines = new_lines
  end
  core.redraw = true
end

function TermView:_push(kind, text)
  self:_push_chunk(kind, text .. "\n")
end

-- Run a command string asynchronously
function TermView:run(cmd_str)
  -- If a process is already running, send input to stdin
  if self:state().proc then
    self:_push("cmd", cmd_str)
    pcall(function() self:state().proc:write(cmd_str .. "\n") end)
    return
  end

  local s = self:state()
  local prompt_str = s.shell.prompt_prefix .. core.project_dir .. (PLATFORM == "Windows" and ">" or "$")
  self:_push("cmd", prompt_str .. " " .. cmd_str)

  local argv = {}
  for _, v in ipairs(s.shell.cmd) do table.insert(argv, v) end
  table.insert(argv, cmd_str)

  local p, err, code = process.start(argv, {
    stdin  = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
    cwd    = core.project_dir
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

  -- Drain ALL process outputs using 64KB chunks for maximum IPC throughput
  for i, s in ipairs(self.sessions) do
    if s.proc then
      while true do
        local out = s.proc:read_stdout(65536)
        if not out or #out == 0 then break end
        -- Need to temporarily set active state for _push_chunk to target right session
        local old_idx = self.active_idx
        self.active_idx = i
        self:_push_chunk("out", out)
        self.active_idx = old_idx
      end
      
      while true do
        local err = s.proc:read_stderr(65536)
        if not err or #err == 0 then break end
        local old_idx = self.active_idx
        self.active_idx = i
        self:_push_chunk("err", err)
        self.active_idx = old_idx
      end

      local rc = s.proc:returncode()
      if rc ~= nil then
        local old_idx = self.active_idx
        self.active_idx = i
        self:_push_chunk("info", string.format("[exited: %d]\\n", rc))
        self.active_idx = old_idx
        s.proc = nil
      end
    end
  end

  -- Handle scroll snapping
  if self:state().scroll_to_bottom and #self:state().lines > 0 then
    local lh    = style.code_font:get_height() + 2 * SCALE
    local total = #self:state().lines * lh
    local inner = math.max(0, self.size.y - 20 * SCALE)
    self:state().scroll_y = math.max(0, total - inner)
    self:state().scroll_to_bottom = false
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
    local prompt = s.proc and "" or (s.shell.prompt_prefix .. core.project_dir .. (PLATFORM == "Windows" and "> " or "$ "))
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
  local status_dot = self:state().proc and "\xe2\x97\x8f " or "\xe2\x97\x8b "
  local status_col = self:state().proc and { common.color "#B8BB26" } or col_inf
  renderer.draw_text(style.font, status_dot,
    x + 8 * SCALE,
    y + 2 * SCALE + math.floor((hdr_h - style.font:get_height()) / 2),
    status_col)

  renderer.draw_text(style.font, "TERMINAL",
    x + 24 * SCALE,
    y + 2 * SCALE + math.floor((hdr_h - style.font:get_height()) / 2),
    fg)

  local cur_x = x + 120 * SCALE
  self.tab_rects = {}
  for i, s in ipairs(self.sessions) do
    local label = tostring(i)
    local tw = style.font:get_width(label) + 16 * SCALE
    local tab_bg = (i == self.active_idx) and get_contrast_bg(hdr_bg) or hdr_bg
    local tab_fg = (i == self.active_idx) and fg or col_inf
    
    renderer.draw_rect(cur_x, y + 2 * SCALE, tw, hdr_h, tab_bg)
    renderer.draw_text(style.font, label, cur_x + 8 * SCALE, y + 2 * SCALE + math.floor((hdr_h - style.font:get_height())/2), tab_fg)
    
    table.insert(self.tab_rects, { x = cur_x, y = y + 2 * SCALE, w = tw, h = hdr_h, idx = i })
    cur_x = cur_x + tw + 2 * SCALE
  end
  
  -- "+" button
  local pw = style.font:get_width("+") + 16 * SCALE
  renderer.draw_rect(cur_x, y + 2 * SCALE, pw, hdr_h, hdr_bg)
  renderer.draw_text(style.font, "+", cur_x + 8 * SCALE, y + 2 * SCALE + math.floor((hdr_h - style.font:get_height())/2), col_inf)
  self.add_btn_rect = { x = cur_x, y = y + 2 * SCALE, w = pw, h = hdr_h }
    cur_x = cur_x + pw + 2 * SCALE
    
    -- "v" dropdown button
    local vw = style.font:get_width("v") + 16 * SCALE
    renderer.draw_rect(cur_x, y + 2 * SCALE, vw, hdr_h, hdr_bg)
    renderer.draw_text(style.font, "v", cur_x + 8 * SCALE, y + 2 * SCALE + math.floor((hdr_h - style.font:get_height())/2), col_inf)
    self.dropdown_btn_rect = { x = cur_x, y = y + 2 * SCALE, w = vw, h = hdr_h }
    cur_x = cur_x + vw + 2 * SCALE
  
  -- "x" button (close active)
  if #self.sessions > 1 then
    local xw = style.font:get_width("x") + 16 * SCALE
    renderer.draw_rect(cur_x, y + 2 * SCALE, xw, hdr_h, hdr_bg)
    renderer.draw_text(style.font, "x", cur_x + 8 * SCALE, y + 2 * SCALE + math.floor((hdr_h - style.font:get_height())/2), col_err)
    self.close_btn_rect = { x = cur_x, y = y + 2 * SCALE, w = xw, h = hdr_h }
  else
    self.close_btn_rect = nil
  end

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

  -- ── Seamless Terminal Output & Input ──────────────────────────────────────────
  local out_top = y + hdr_h + 3 * SCALE
  local out_bot = y + h - 2 * SCALE
  local out_h   = out_bot - out_top

  local lh     = style.code_font:get_height() + 2 * SCALE
  local text_y = out_top + 4 * SCALE - self:state().scroll_y
  local text_x = x + 10 * SCALE


  local sel = self:state().selection
  local sel_l1, sel_c1, sel_l2, sel_c2
  if sel then sel_l1, sel_c1, sel_l2, sel_c2 = sort_positions(sel.l1, sel.c1, sel.l2, sel.c2) end

  core.push_clip_rect(x, out_top, w, out_h)

  
  -- Render all historical lines
  for i, ln in ipairs(self:state().lines) do
    if text_y + lh >= out_top and text_y <= out_bot then
      if sel and i >= sel_l1 and i <= sel_l2 then
         local txt = ln.text
         local col1 = (i == sel_l1) and sel_c1 or 1
         local col2 = (i == sel_l2) and sel_c2 or (#txt + 1)
         local x1 = text_x + style.code_font:get_width(txt:sub(1, col1 - 1))
         local sw = style.code_font:get_width(txt:sub(col1, col2 - 1))
         if i < sel_l2 and col2 == #txt + 1 then sw = sw + style.code_font:get_width(" ") end
         renderer.draw_rect(x1, text_y, sw, lh, style.selection or {255, 255, 255, 60})
      end
      local col = ln.kind == "cmd"  and fg

               or ln.kind == "err"  and col_err
               or ln.kind == "info" and col_inf
               or fg
      renderer.draw_text(style.code_font, ln.text, text_x, text_y, col)
    end
    text_y = text_y + lh
  end

  -- Render the live input line at the bottom
  if text_y <= out_bot then
    local s = self:state()
    local prompt = s.proc and "" or (s.shell.prompt_prefix .. core.project_dir .. (PLATFORM == "Windows" and "> " or "$ "))
    
    local prompt_w = style.code_font:get_width(prompt)
    
    if prompt ~= "" then
      renderer.draw_text(style.code_font, prompt, text_x, text_y, col_cmd)
    end

    local display_input = self:state().input
    local line_idx = #self:state().lines + 1
    if sel and line_idx >= sel_l1 and line_idx <= sel_l2 then
       local full_txt = prompt .. display_input
       local col1 = (line_idx == sel_l1) and sel_c1 or 1
       local col2 = (line_idx == sel_l2) and sel_c2 or (#full_txt + 1)
       local x1 = text_x + style.code_font:get_width(full_txt:sub(1, col1 - 1))
       local sw = style.code_font:get_width(full_txt:sub(col1, col2 - 1))
       renderer.draw_rect(x1, text_y, sw, lh, style.selection or {255, 255, 255, 60})
    end

    renderer.draw_text(style.code_font, display_input, text_x + prompt_w, text_y, fg)

    -- Cursor
    if core.active_view == self then
      local cx = text_x + prompt_w + style.code_font:get_width(display_input)
      renderer.draw_rect(cx, text_y, 2 * SCALE, style.code_font:get_height(), { common.color "#A9DC76" })
    end
  end
  
  core.pop_clip_rect()
end

-- ── Input ──────────────────────────────────────────────────────────────────────
function TermView:on_text_input(text)
  self:state().input = self:state().input .. text
  core.redraw = true
end

function TermView:on_key_pressed(key)
  if key == "return" then
    local cmd = self:state().input:match("^%s*(.-)%s*$")
    self:state().input = ""
    if cmd and #cmd > 0 then
      if self:state().history[#self:state().history] ~= cmd then
        table.insert(self:state().history, cmd)
      end
      self:state().history_idx = #self:state().history + 1
      
      -- Intercept clear commands to wipe the graphical buffer
      local lower_cmd = cmd:lower()
      if lower_cmd == "cls" or lower_cmd == "clear" then
        self:state().lines = {}
      end
      
      self:run(cmd)
    end
    core.redraw = true
    return true
  end
  if key == "up" then
    if #self:state().history > 0 and self:state().history_idx > 1 then
      self:state().history_idx = self:state().history_idx - 1
      self:state().input = self:state().history[self:state().history_idx]
      core.redraw = true
    end
    return true
  end
  if key == "down" then
    if #self:state().history > 0 and self:state().history_idx <= #self:state().history then
      self:state().history_idx = self:state().history_idx + 1
      self:state().input = self:state().history[self:state().history_idx] or ""
      core.redraw = true
    end
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
      core.redraw = true
    end
    return true
  end
  if key == "ctrl+c" then
    if self:state().proc then
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
    local hdr_h = 26 * SCALE
    local out_top = self.position.y + hdr_h + 3 * SCALE
    if y > out_top then
      local l, c = self:resolve_position(x, y)
      self:state().selection = { l1 = l, c1 = c, l2 = l, c2 = c }
      self.dragging_selection = true
      core.redraw = true
      return true
    end

    if self.btn_rect then
      local bx, by, bw, bh = self.btn_rect.x, self.btn_rect.y, self.btn_rect.w, self.btn_rect.h
      if x >= bx and x <= bx + bw and y >= by and y <= by + bh then
        command.perform("terminal:fullscreen")
        return true
      end
    end
    if self.add_btn_rect then
      local r = self.add_btn_rect
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        self:add_session(self:state().shell)
        core.redraw = true
        return true
      end
    end
    if self.dropdown_btn_rect then
      local r = self.dropdown_btn_rect
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        core.command_view:enter("Select Shell", {
          submit = function(text, item)
            self:add_session(item.shell)
            core.redraw = true
          end,
          suggest = function(text)
            local res = {}
            for _, sh in ipairs(shells) do table.insert(res, { text = sh.name, shell = sh }) end
            return res
          end
        })
        return true
      end
    end
    if self.close_btn_rect then
      local r = self.close_btn_rect
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        if self:state().proc then pcall(function() self:state().proc:kill() end) end
        table.remove(self.sessions, self.active_idx)
        if self.active_idx > #self.sessions then self.active_idx = #self.sessions end
        core.redraw = true
        return true
      end
    end
    for _, r in ipairs(self.tab_rects or {}) do
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        self.active_idx = r.idx
        core.redraw = true
        return true
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
  local lh = style.code_font:get_height() + 2 * SCALE
  self:state().scroll_y = math.max(0, self:state().scroll_y - dy * lh * 3)
  
  -- Clamp scroll
  local total = #self:state().lines * lh
  local inner = math.max(0, self.size.y - 20 * SCALE)
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
    command.perform "terminal:toggle"
    if instance and instance.visible then
      core.set_active_view(instance)
    end
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
        local prompt = s.proc and "" or (s.shell.prompt_prefix .. core.project_dir .. (PLATFORM == "Windows" and "> " or "$ "))
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

-- Hook into core.quit to kill any zombie background processes when Lite-XL exits
local old_quit = core.quit
function core.quit(force)
  if instance then
    for _, s in ipairs(instance.sessions) do
      if s.proc then pcall(function() s.proc:kill() end) end
    end
  end
  return old_quit(force)
end

