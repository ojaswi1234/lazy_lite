-- mod-version:3
-- Antigravity AI Sidebar Ã¢â‚¬â€ modern chat UI, Ctrl+Shift+A
-- Size-animation toggle (same pattern as built-in treeview).

local core    = require "core"
local config  = require "core.config"
local style   = require "core.style"
local tokenizer = require "core.tokenizer"
local syntax  = require "core.syntax"

local function graceful_kill(p)
  if not p then return end
  pcall(function() p:write("KILL\n") end)
  core.add_thread(function()
    coroutine.yield(0.1)
    pcall(function() p:terminate() end)
  end)
end

local command = require "core.command"
local keymap  = require "core.keymap"
local View    = require "core.view"

-- Monkey-patch View to provide a default set_target_size for all views (like EmptyView).
-- This prevents the node.lua:682 crash when resizing a locked node that became empty.
if not View.set_target_size then
  function View:set_target_size(axis, value) return false end
end

local common  = require "core.common"
local process = require "process"
local system  = require "system"

-- Ã¢â€â‚¬Ã¢â€â‚¬ Dynamic contrast helpers (same system as mossy_statusbar / mossy_treeview) Ã¢â€â‚¬
local function lum(r, g, b) return r*0.299 + g*0.587 + b*0.114 end

-- Ã¢â€â‚¬Ã¢â€â‚¬ Emoji-aware rendering Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
-- Lite XL's default fonts (FiraCode, etc.) have no emoji glyphs, so emoji
-- codepoints render as '?'. We load the system emoji font once and use it
-- to draw emoji segments, falling back gracefully if unavailable.
local _emoji_font = nil
local function get_emoji_font()
  if _emoji_font ~= false then  -- false = already tried and failed
    if not _emoji_font then
      local candidates = {}
      -- First priority: bundled font in user's Lite XL config dir (installed by setup script)
      local user_bundled = USERDIR .. "/fonts/NotoColorEmoji.ttf"
      table.insert(candidates, user_bundled)
      if PLATFORM == "Windows" then
        local windir = os.getenv("WINDIR") or "C:\\Windows"
        table.insert(candidates, windir .. "\\Fonts\\seguiemj.ttf")  -- Segoe UI Emoji
      else
        -- Linux / macOS system candidates
        for _, p in ipairs({
          "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
          "/usr/share/fonts/noto/NotoColorEmoji.ttf",
          "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf",
          "/Library/Fonts/Apple Color Emoji.ttc",
        }) do table.insert(candidates, p) end
      end
      for _, path in ipairs(candidates) do
        local f = io.open(path, "rb")
        if f then f:close()
          -- Load at same size as style.font
          local sz = style.font and style.font:get_height() or 14
          local ok, fnt = pcall(renderer.font.load, path, sz)
          if ok then _emoji_font = fnt; break end
        end
      end
      if not _emoji_font then _emoji_font = false end  -- mark as unavailable
    end
  end
  return _emoji_font or nil
end

-- Returns true if the UTF-8 char starting at byte i in `s` is an emoji.
-- We check the first codepoint of each multi-byte sequence.
local function is_emoji_char(s, i)
  local b1 = s:byte(i)
  if not b1 then return false, i+1 end
  local seq_len, cp
  if b1 < 0x80 then
    -- ASCII
    return false, i+1
  elseif b1 >= 0xF0 then
    seq_len = 4
    local b2,b3,b4 = s:byte(i+1), s:byte(i+2), s:byte(i+3)
    if not (b2 and b3 and b4) then return false, i+1 end
    cp = ((b1 & 0x07) << 18) | ((b2 & 0x3F) << 12) | ((b3 & 0x3F) << 6) | (b4 & 0x3F)
  elseif b1 >= 0xE0 then
    seq_len = 3
    local b2,b3 = s:byte(i+1), s:byte(i+2)
    if not (b2 and b3) then return false, i+1 end
    cp = ((b1 & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
  elseif b1 >= 0xC0 then
    seq_len = 2
    local b2 = s:byte(i+1)
    if not b2 then return false, i+1 end
    cp = ((b1 & 0x1F) << 6) | (b2 & 0x3F)
  else
    return false, i+1
  end
  -- Unicode emoji ranges
  local emoji = (cp >= 0x1F300 and cp <= 0x1FAFF)   -- Misc Symbols / Pictographs / emoticons
             or (cp >= 0x2600  and cp <= 0x27BF)    -- Misc symbols, dingbats
             or (cp >= 0x2300  and cp <= 0x23FF)    -- Misc Technical
             or (cp >= 0x1F000 and cp <= 0x1F02F)   -- Mahjong/domino tiles
             or (cp >= 0x1F0A0 and cp <= 0x1F0FF)   -- Playing cards
             or (cp >= 0x231A  and cp <= 0x231B)    -- Watch, Hourglass
             or (cp >= 0x23E9  and cp <= 0x23F3)    -- Various
             or cp == 0x2764                         -- Heart
  return emoji, i + seq_len
end

-- Draw text handling emoji segments with the emoji font.
-- Returns the final x position (same interface as renderer.draw_text).
local function draw_text_emoji(font, text, tx, ty, col)
  local ef = get_emoji_font()
  if not ef or not text or text == "" then
    return renderer.draw_text(font, text, tx, ty, col)
  end
  local i = 1
  local seg_start = 1
  local cur_x = tx
  local function flush_normal(upto)
    if upto > seg_start then
      local chunk = text:sub(seg_start, upto - 1)
      if chunk ~= "" then
        cur_x = renderer.draw_text(font, chunk, cur_x, ty, col)
      end
    end
  end
  while i <= #text do
    local is_emj, next_i = is_emoji_char(text, i)
    if is_emj then
      flush_normal(i)
      local emj = text:sub(i, next_i - 1)
      -- Skip zero-width joiner (U+200D) and variation selectors that follow
      cur_x = renderer.draw_text(ef, emj, cur_x, ty, col)
      seg_start = next_i
      i = next_i
    else
      i = next_i
    end
  end
  flush_normal(#text + 1)
  return cur_x
end

local function utf8_prev(text, i)
  if not i or i <= 0 then return 0 end
  i = i - 1
  while i > 0 do
    local b = text:byte(i + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    i = i - 1
  end
  return i
end

local function utf8_next(text, i)
  if not i or i >= #text then return #text end
  i = i + 1
  while i < #text do
    local b = text:byte(i + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    i = i + 1
  end
  return i
end

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
    -- light bg Ã¢â€ â€™ near-black tinted text
    return { math.floor(r*0.15), math.floor(g*0.15), math.floor(b*0.15), 255 }
  else
    -- dark bg Ã¢â€ â€™ near-white tinted text
    return { math.min(255,math.floor(r+(255-r)*0.85)), math.min(255,math.floor(g+(255-g)*0.85)), math.min(255,math.floor(b+(255-b)*0.85)), 255 }
  end
end

local function muted(fg, factor)
  factor = factor or 0.55
  return { math.floor(fg[1]*factor), math.floor(fg[2]*factor), math.floor(fg[3]*factor), 255 }
end

-- Recomputed every draw Ã¢â‚¬â€ automatically tracks theme changes
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
  
  if style.mossy then
    bg          = style.mossy.sidebar_bg or bg
    bg_dark     = style.mossy.sidebar_bg or bg_dark
    bg_darker   = style.mossy.activity_bg or bg_darker
    bg_input    = style.mossy.terminal_bg or bg_input
    bg_user     = style.mossy.active_row or bg_user
    bg_ai       = style.mossy.sidebar_bg or bg_ai
    bg_btn      = style.mossy.sidebar_muted or bg_btn
    bg_btnhl    = style.mossy.active_row or bg_btnhl
    bg_send     = style.mossy.active_row or bg_send
    bg_sendhl   = style.mossy.hover_row or bg_sendhl
    fg          = style.mossy.sidebar_text or fg
    fg_muted    = style.mossy.sidebar_muted or fg_muted
    fg_accent   = style.mossy.activity_icon_hl or fg_accent
    fg_send     = style.mossy.sidebar_text or fg_send
    border      = style.mossy.border or border
  end
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

-- Ã¢â€â‚¬Ã¢â€â‚¬ Config Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
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

-- Ã¢â€â‚¬Ã¢â€â‚¬ PTY Bridge helper Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
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

-- Ã¢â€â‚¬Ã¢â€â‚¬ Helpers Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
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
  local q = query:gsub("\\", "/")
  
  -- Split query into folder and search term
  local target_dir = ""
  local search_term = q:lower()
  
  local last_slash = q:match("^.*()[/]")
  if last_slash then
    target_dir = q:sub(1, last_slash)
    search_term = q:sub(last_slash + 1):lower()
  end
  
  local base_dir = core.project_dir
  if not base_dir then return results end
  
  local abs_dir = base_dir .. PATHSEP .. target_dir:gsub("/", PATHSEP)
  local files = system.list_dir(abs_dir) or {}
  
  local folders = {}
  local raw_files = {}
  
  -- If we are inside a subfolder, add a ".." option
  if target_dir ~= "" then
    local parent = target_dir:match("^(.*[/])[^/]+[/]$") or ""
    table.insert(folders, { type = "dir", full_path = parent, display = "Ã°Å¸â€œÂ .." })
  end
  
  for _, f in ipairs(files) do
    if f:lower():find(search_term, 1, true) then
      local info = system.get_file_info(abs_dir .. f)
      if info and info.type == "dir" then
        table.insert(folders, { type = "dir", full_path = target_dir .. f .. "/", display = "Ã°Å¸â€œÂ " .. f .. "/" })
      else
        table.insert(raw_files, { type = "file", full_path = target_dir .. f, display = "Ã°Å¸â€œâ€ž " .. f })
      end
    end
  end
  
  table.sort(folders, function(a,b) return a.display < b.display end)
  table.sort(raw_files, function(a,b) return a.display < b.display end)
  
  for _, f in ipairs(folders) do
    table.insert(results, f)
    if #results >= 15 then break end
  end
  for _, f in ipairs(raw_files) do
    if #results >= 15 then break end
    table.insert(results, f)
  end
  
  return results
end



-- Wrap text into lines that fit within max_w pixels using given font
local function parse_inline(text)
  local segments = {}
  local s_idx = 1
  while s_idx <= #text do
    local b_s, b_e = text:find("%*%*.-%*%*", s_idx)
    local c_s, c_e = text:find("`.-`", s_idx)
    local l_s, l_e = text:find("%[.-%]%([^%)]+%)", s_idx) -- [link](url)
    
    local next_s, next_e, type
    local min_s = math.huge
    
    if b_s and b_s < min_s then min_s = b_s; next_s, next_e, type = b_s, b_e, "bold" end
    if c_s and c_s < min_s then min_s = c_s; next_s, next_e, type = c_s, c_e, "code" end
    if l_s and l_s < min_s then min_s = l_s; next_s, next_e, type = l_s, l_e, "link" end
    
    if next_s then
      if next_s > s_idx then table.insert(segments, { text = text:sub(s_idx, next_s - 1), type = "normal" }) end
      
      local inner_text = text:sub(next_s, next_e)
      if type == "bold" then
        table.insert(segments, { text = inner_text:sub(3, -3), type = "bold" })
      elseif type == "code" then
        table.insert(segments, { text = inner_text:sub(2, -2), type = "code" })
      elseif type == "link" then
        local label, url = inner_text:match("%[(.-)%]%(([^%)]+)%)")
        -- If the link label itself contains code, e.g. [`code`](url), unwrap it
        if label:match("^`.-`$") then
          label = label:sub(2, -2)
          table.insert(segments, { text = label, type = "code_link", url = url })
        else
          table.insert(segments, { text = label, type = "link", url = url })
        end
      end
      s_idx = next_e + 1
    else
      table.insert(segments, { text = text:sub(s_idx), type = "normal" })
      break
    end
  end
  return segments
end

local function wrap_segments(segments, base_font, code_font, max_w)
  local lines = {}
  local cur_line = {}
  local cur_w = 0
  
  local function get_font(type) return (type == "code" or type == "code_link") and code_font or base_font end
  
  local function push_word(word, type)
    local f = get_font(type)
    local w = f:get_width(word)
    if cur_w + w > max_w and cur_w > 0 then
      table.insert(lines, cur_line)
      cur_line = {}
      cur_w = 0
      -- drop leading space on new line if normal text
      if word == " " then return end
    end
    table.insert(cur_line, { text = word, type = type, font = f, width = w })
    cur_w = cur_w + w
  end

  for _, seg in ipairs(segments) do
    if seg.type == "code" or seg.type == "code_link" then
      -- don't split inline code if possible, just push it whole or split by chunks if truly massive
      push_word(seg.text, seg.type)
    else
      -- split text by spaces but keep the spaces
      for word in seg.text:gmatch("%S+%s*") do
        push_word(word, seg.type)
      end
      -- capture trailing space if any
      if seg.text:match("%s$") and not seg.text:match("%S") then push_word(" ", seg.type) end
    end
  end
  if #cur_line > 0 then table.insert(lines, cur_line) end
  return lines
end

local function wrap_raw_text(font, text, max_w)
  local lines = {}
  for raw_line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if font:get_width(raw_line) <= max_w then
      table.insert(lines, raw_line)
    else
      local cur = ""
      for word in (raw_line .. " "):gmatch("(%S+)%s") do
        local try = cur == "" and word or (cur .. " " .. word)
        if font:get_width(try) > max_w then
          if #cur > 0 then table.insert(lines, cur); cur = word
          else
            local char_cur = ""
            for i = 1, #word do
              local char = word:sub(i, i)
              if font:get_width(char_cur .. char) > max_w then table.insert(lines, char_cur); char_cur = char
              else char_cur = char_cur .. char end
            end
            cur = char_cur
          end
        else cur = try end
      end
      if #cur > 0 then table.insert(lines, cur) end
    end
  end
  return lines
end

local function parse_blocks(text, base_font, code_font, max_w)
  local blocks = {}
  local is_code = false
  local cur_text = ""
  local cur_lang = ""
  
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local lang_match = line:match("^%s*```(%w*)")
    if lang_match then
      if #cur_text > 0 then
        cur_text = cur_text:gsub("\n$", "")
        if is_code then
          table.insert(blocks, { type = "code", lang = cur_lang, raw_lines = wrap_raw_text(code_font, cur_text, max_w) })
        else
          table.insert(blocks, { type = "text", raw = cur_text })
        end
      end
      cur_text = ""
      is_code = not is_code
      if is_code then cur_lang = lang_match end
    else
      cur_text = cur_text .. line .. "\n"
    end
  end
  
  if #cur_text > 0 then
    cur_text = cur_text:gsub("\n$", "")
    if is_code then
      table.insert(blocks, { type = "code", lang = cur_lang, raw_lines = wrap_raw_text(code_font, cur_text, max_w) })
    else
      table.insert(blocks, { type = "text", raw = cur_text })
    end
  end
  
  -- post-process text blocks line by line for headers and lists
  local final_blocks = {}
  for _, blk in ipairs(blocks) do
    if blk.type == "code" then
      table.insert(final_blocks, blk)
    else
      for line in (blk.raw .. "\n"):gmatch("([^\n]*)\n") do
        if #line > 0 then
          local header = line:match("^%s*(#+)%s")
          local list = line:match("^%s*[%-%*]%s")
          local level = header and #header or 0
          
          -- strip header symbols for parsing
          if header then line = line:gsub("^%s*#+%s", "") end
          
          local segments = parse_inline(line)
          -- adjust fonts for headers
          local f = (level > 0) and (style.big_font or base_font) or base_font
          local wrapped = wrap_segments(segments, f, code_font, max_w - (list and f:get_width("Ã¢â‚¬Â¢ ") or 0))
          table.insert(final_blocks, { type = "paragraph", level = level, list = list ~= nil, wrapped_lines = wrapped })
        else
          table.insert(final_blocks, { type = "empty" })
        end
      end
    end
  end
  return final_blocks
end

-- Ã¢â€â‚¬Ã¢â€â‚¬ View Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
local AGView    = View:extend()
local instance  = nil
local node_built = false

-- Ã¢â€â‚¬Ã¢â€â‚¬ Model list parser Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
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
      and #line > 3  -- skip single spinner chars like Ã¢Â â€¹ Ã¢Â â„¢ etc
      and not seen[line]
    then
      seen[line] = true
      local name = line
      
      -- If the line starts with an ID followed by multiple spaces (e.g. "gemini-3.1-pro-high   Gemini 3.1 Pro (High)")
      -- strip the ID and keep only the display name for the CLI.
      local id, disp = line:match("^([^%s]+)%s%s+(.+)$")
      if id and disp then
        name = disp
      end

      local usage = nil
      local limited = false
      
      -- Parse usage e.g. "Gemini 1.5 Pro (50/50)"
      local base_name, u1, u2 = name:match("^(.-)%s*[%-]?%s*[%[%(]?(%d+)/(%d+)[^%]%)]*[%]%)]?%s*$")
      if base_name and u1 and u2 then
        name = base_name
        usage = u1 .. "/" .. u2
        limited = (tonumber(u1) >= tonumber(u2))
      else
        base_name, u1, u2 = name:match("^(.-)%s+(%d+)%s*/%s*(%d+)%s*$")
        if base_name and u1 and u2 then
          name = base_name
          usage = u1 .. "/" .. u2
          limited = (tonumber(u1) >= tonumber(u2))
        end
      end
      table.insert(models, { name = name, usage = usage, limited = limited })
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
  self.hover_attach = false
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
  self.temp_files        = {}
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
    cursor = 0,
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
  return wrap_raw_text(font, text, w)
end

function AGView:_add_session(role, text)
  local entry = { role = role, text = text, lines = {} }
  -- compute wrapped lines lazily in draw (size might not be set yet)
  table.insert(self:state().sessions, entry)
end

local function parse_iso_timestamp(str)
  if not str then return nil end
  local y, m, d, h, min, s = str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
  if y then
    return os.time({year=y, month=m, day=d, hour=h, min=min, sec=s})
  end
  return nil
end

function AGView:show_resume_picker()
  local base_dir = (os.getenv("USERPROFILE") or os.getenv("HOME"))
  local brain_path = base_dir .. "/.gemini/antigravity-cli/brain"
  
  local files = system.list_dir(brain_path)
  if not files then
    self:_add_session("ai", "Could not find brain directory at " .. brain_path)
    self:state().scroll_to_bottom = true
    core.redraw = true
    return
  end
  
  -- Parse conversation metadata for accurate titles, steps, and agents
  local cache_path = base_dir .. "/.gemini/antigravity-cli/cache/conversation_metadata.json"
  local cache_f = io.open(cache_path, "r")
  local meta = {}
  if cache_f then
    local current_cid = nil
    for line in cache_f:lines() do
      local cid = line:match('"(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)"%s*:%s*{')
      if cid then
        current_cid = cid
        meta[current_cid] = { preview = "", steps = 0, agent = "" }
      elseif current_cid then
        local preview = line:match('"Preview"%s*:%s*"([^"]*)"')
        if preview then meta[current_cid].preview = preview:gsub('\\"', '"'):gsub("\\n", " "):gsub("\\u0026", "&") end
        
        local steps = line:match('"NumSteps"%s*:%s*(%d+)')
        if steps then meta[current_cid].steps = tonumber(steps) end
        
        local agent = line:match('"AgentName"%s*:%s*"([^"]*)"')
        if agent then meta[current_cid].agent = agent end
      end
    end
    cache_f:close()
  end

  local results = {}
  local active_cid = self:state().cid

  local pinned_path = base_dir .. "/.gemini/antigravity-cli/pinned_cids.txt"
  local pinned = {}
  local pf = io.open(pinned_path, "r")
  if pf then
    for line in pf:lines() do
      local c = line:match("^%s*(.-)%s*$")
      if c and c ~= "" then pinned[c] = true end
    end
    pf:close()
  end

  for _, name in ipairs(files) do
    local cid = name:match("^(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$")
    if cid then
      local path = brain_path .. "/" .. cid .. "/.system_generated/logs/transcript.jsonl"
      local tf = io.open(path, "r")
      if tf then
        local title = ""
        local created_at = ""
        local has_user_input = false
        
        for line in tf:lines() do
          if not has_user_input and line:find('"type":"USER_INPUT"') then
            has_user_input = true
            local content = line:match('"content"%s*:%s*"(.*)"%s*}')
            if content then
              if #content > 2000 then content = content:sub(1, 2000) end
              local req = content:match("<USER_REQUEST>%s*(.-)%s*</USER_REQUEST>")
              title = req or content
              title = title:gsub("\\n", " "):gsub('\\"', '"'):gsub("\\u0026", "&")
              title = title:match("^%s*(.-)%s*$")
            end
            created_at = line:match('"created_at"%s*:%s*"([^"]+)"')
            break
          end
        end
        tf:close()
        
        if title == "" then
          title = cid
        end
        
        if active_cid == cid then
          title = "[CURRENT] " .. title
        end
        
        if #title > 60 then title = title:sub(1, 57) .. "..." end
        
        local m = meta[cid]
        local skill = m and m.agent or ""
        local steps = m and m.steps or 0
        
        -- Compute time ago from transcript timestamp
        local time_ago = ""
        local ts = parse_iso_timestamp(created_at)
        if ts then
          local diff = os.time() - ts
          if diff < 0 then diff = 0 end
          if diff < 60 then time_ago = diff .. "s ago"
          elseif diff < 3600 then time_ago = math.floor(diff / 60) .. "m ago"
          elseif diff < 86400 then time_ago = math.floor(diff / 3600) .. "h ago"
          else time_ago = math.floor(diff / 86400) .. "d ago" end
        else
          time_ago = cid:sub(1,8)
        end
        
        local info_str
        if skill == "" then
          info_str = string.format("%d steps      %s", steps, time_ago)
        else
          info_str = string.format("%s      %d steps      %s", skill, steps, time_ago)
        end
        
        local is_auto_healer = (skill == "lite_xl_healer") or title:find("lite_xl_healer") or title:find("The editor CRASHED")
        if not is_auto_healer then
          local is_pinned = pinned[cid]
          if is_pinned then
            title = "Ã°Å¸â€œÅ’ " .. title
          end
          
          table.insert(results, { text = title, info = info_str, cid = cid, time = ts or 0, pinned = is_pinned })
        end
      end
    end
  end
  
  -- Sort results by pinned status, then timestamp (newest first)
  table.sort(results, function(a, b) 
    if a.pinned and not b.pinned then return true end
    if b.pinned and not a.pinned then return false end
    return a.time > b.time 
  end)

  if #results == 0 then
    self:_add_session("ai", "No past conversations found.")
    self:state().scroll_to_bottom = true
    core.redraw = true
    return
  end

  core.command_view:enter("Select Conversation to Resume (Ctrl+P: Pin, Ctrl+Del: Delete)", {
    submit = function(text, item)
      if item and item.cid then
        if self:state().process or #self:state().sessions > 0 then
          self:_add_chat()
        end
        self:state().cid = item.cid
        self:state().has_session = true
        self:_add_session("ai", "Resumed conversation: " .. item.text .. "\n\nBackend context loaded. You may now continue typing!")
        self:state().scroll_to_bottom = true
        core.redraw = true
      end
    end,
    suggest = function(text)
      if text == "" then return results end
      local res = {}
      for _, item in ipairs(results) do
        local score = system.fuzzy_match(item.text, text, true)
        if score then
          item._score = score
          table.insert(res, item)
        end
      end
      table.sort(res, function(a, b) return (a._score or 0) > (b._score or 0) end)
      return res
    end
  })
end

function AGView:submit(prompt)
  if not prompt or prompt == "" then return end
  
  if prompt == "/help" then
    self:state().has_session = true
    self:state().status = "idle"
    local help_text = "Built-in commands:\n  `/help` - Show this message\n  `/usage` - Show model usage\n  `/resume` - Resume a past conversation\n\n(Type any other prompt to chat with the AI)"
    table.insert(self:state().sessions, { role = "user", text = prompt })
    table.insert(self:state().sessions, { role = "ai", text = help_text })
    core.redraw = true
    return
  elseif prompt == "/usage" then
    self:state().status = "running"
    self:state().has_session = true
    self:state()._ai_buf = ""
    self:state()._ai_displayed_chars = 0
    table.insert(self:state().sessions, { role = "user", text = prompt })
    table.insert(self:state().sessions, { role = "ai", text = "" })
    
    local cfg = config.antigravity
    local argv = { cfg.cli, "usage" }
    if PLATFORM == "Windows" then
      argv = { "cmd.exe", "/c", cfg.cli, "usage" }
    end
    
    local p, err = process.start(argv, {
      stdin = process.REDIRECT_PIPE,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      cwd = core.project_dir
    })
    
    if p then
      self:state().process = p
      self:state()._chat_started_at = os.time()
    else
      self:state().sessions[#self:state().sessions].text = "Error: " .. tostring(err)
      self:state().status = "error"
    end
    core.redraw = true
    return
  end
  local prompt_text = prompt:match("^%s*(.-)%s*$")
  
  if prompt_text:match("^/resume") then
    self:state().input = ""
    self:show_resume_picker()
    return
  end


  -- We no longer block execution here. The auth_status is unreliable on Windows due to the CLI's stdin behavior.
  -- If they are truly unauthenticated, the chat will hang in the background, but they can use the AGY Auth button to fix it.

  -- Add user message to chat (showing the @ token)
  self:_add_session("user", prompt_text)

  -- Expand any @pasted_text tokens into absolute file paths before sending to AI
  local tmp_dir = USERDIR .. "/tempfiles"
  local expanded_prompt = prompt_text:gsub("@(pasted_text_[a-zA-Z0-9_]+%.txt)", function(f)
    local fp = tmp_dir .. "/" .. f
    return string.format(" [Read this pasted text from file: %s] ", fp)
  end)

  local fname = nil
  local av = core.active_view
  if av and av.doc then fname = av.doc.filename end

  local full_prompt = expanded_prompt
  if fname then
    full_prompt = string.format("Regarding the active file %s: %s", fname, prompt_text)
  end
  
  if core.active_codespace and not self:state().cid then
    local cs = core.active_codespace
    full_prompt = full_prompt .. string.format(
      "\n\n[SYSTEM CONTEXT: The user is connected to a remote GitHub Codespace ('%s'). The local workspace provided to you is a SPARSE VFS where files exist as 0-byte placeholders. You CANNOT read them natively with your built-in file tools. To read file contents, search the codebase, or execute tasks, you MUST use the `run_command` tool to execute commands over SSH on the remote Linux container (e.g., `gh cs ssh -c %s -- cat path/to/file`). The absolute remote workspace path is %s.]",
      cs.name, cs.name, cs.remote_dir or "/workspaces/default"
    )
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

  -- Continue existing conversation
  if self:state().cid then
    table.insert(argv, "--conversation")
    table.insert(argv, self:state().cid)
  elseif self:state().has_session then
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
    stdin = process.REDIRECT_PIPE,
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

local function is_resume_picker()
  return core.active_view == core.command_view and core.command_view.label == "Select Conversation to Resume (Ctrl+P: Pin, Ctrl+Del: Delete)"
end

command.add(is_resume_picker, {
  ["antigravity:delete-conversation"] = function()
    local item = core.command_view.suggestions[core.command_view.suggestion_idx]
    if item and item.cid then
      local base_dir = (os.getenv("USERPROFILE") or os.getenv("HOME"))
      local brain_path = base_dir .. "/.gemini/antigravity-cli/brain/" .. item.cid
      if PLATFORM == "Windows" then
        os.execute('rmdir /S /Q "' .. brain_path:gsub("/", "\\") .. '"')
      else
        os.execute('rm -rf "' .. brain_path .. '"')
      end
        core.log("Deleted conversation: " .. item.text)
        if instance then
          local current_text = core.command_view:get_text()
          core.command_view:exit()
          instance:show_resume_picker()
          core.command_view:set_text(current_text)
        end
    end
  end,
  ["antigravity:toggle-pin-conversation"] = function()
    local item = core.command_view.suggestions[core.command_view.suggestion_idx]
    if item and item.cid then
      local base_dir = (os.getenv("USERPROFILE") or os.getenv("HOME"))
      local pinned_path = base_dir .. "/.gemini/antigravity-cli/pinned_cids.txt"
      local pinned = {}
      local f = io.open(pinned_path, "r")
      if f then
        for line in f:lines() do
          local c = line:match("^%s*(.-)%s*$")
          if c and c ~= "" then pinned[c] = true end
        end
        f:close()
      end
      
      if pinned[item.cid] then
        pinned[item.cid] = nil
        core.log("Unpinned conversation.")
      else
        pinned[item.cid] = true
        core.log("Pinned conversation.")
      end
      
      f = io.open(pinned_path, "w")
      if f then
        for c, _ in pairs(pinned) do f:write(c .. "\n") end
        f:close()
      end
      if instance then
        local current_text = core.command_view:get_text()
        core.command_view:exit()
        instance:show_resume_picker()
        core.command_view:set_text(current_text)
      end
    end
  end
})

keymap.add({
  ["ctrl+delete"] = "antigravity:delete-conversation",
  ["ctrl+p"]      = "antigravity:toggle-pin-conversation"
})

function AGView:update()
  AGView.super.update(self)
  self.tick = (self.tick + 1) % 120

  -- Size animation (treeview pattern)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "x", dest, nil, "antigravity")



  -- Ã¢â€â‚¬Ã¢â€â‚¬ Drain model-fetch process (via PTY bridge) Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
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
        if not config.antigravity.selected_model then
          config.antigravity.selected_model = parsed[1].name
        end
      else
        self:_load_models_from_settings()
      end
      self._model_raw = ""
      self.model_proc = nil
      core.redraw = true
    elseif m_elapsed > 45 then
      pcall(function() graceful_kill(self.model_proc) end)
      self.model_proc = nil
      self._model_raw = ""
      self:_load_models_from_settings()
      core.redraw = true
    end
  end

  -- Ã¢â€â‚¬Ã¢â€â‚¬ Drain chat processes (ALL TABS) Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
  for i, tab in ipairs(self.chats) do
    local is_active_process = tab.process ~= nil
    local ai_len = tab._ai_buf and #tab._ai_buf or 0
    local is_typing = tab._ai_displayed_chars and (tab._ai_displayed_chars < ai_len)

    if is_active_process or is_typing then
      local dirty = false

      -- Read stdout and stderr if process is alive
      if is_active_process then
        while true do
          local out = tab.process:read_stdout(65536)
          if not out or #out == 0 then break end
          tab._ai_buf = (tab._ai_buf or "") .. out
        end
        while true do
          local out = tab.process:read_stderr(65536)
          if not out or #out == 0 then break end
        end

        local rc = tab.process:returncode()
        if rc ~= nil then
          -- Final drain
          while true do
            local out = tab.process:read_stdout(65536)
            if not out or #out == 0 then break end
            tab._ai_buf = (tab._ai_buf or "") .. out
          end
          tab.process = nil
          tab.status = (rc == 0) and "idle" or "error"
          if not tab._ai_buf or tab._ai_buf == "" then
            local elapsed = os.time() - (tab._chat_started_at or os.time())
            tab._ai_buf = string.format(
              "(no output after %.0fs Ã¢â‚¬â€ process exited with code %s)\n\nTry the AGY Auth button if you just logged in.",
              elapsed, tostring(rc))
          end
          dirty = true
          core.redraw = true
        end

        local elapsed = os.time() - (tab._chat_started_at or os.time())
        
        -- Soft warning at 45s
        if tab.process and elapsed > 45 and tab._ai_buf == "" and not tab.warned_slow then
          tab.warned_slow = true
          core.redraw = true
        end
        
        -- Hard kill at 315s (5m15s)
        if tab.process and elapsed > 315 and tab._ai_buf == "" then
          pcall(function() graceful_kill(tab.process) end)
          tab.process = nil
          tab.status  = "error"
          local fix_msg = table.concat({
            "Ã¢ÂÂ± Request timed out after 5 minutes with no response.",
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
          
          tab._ai_buf = fix_msg
          dirty = true
          core.error("[Antigravity] CLI timed out Ã¢â‚¬â€ agy install may be required.")
          core.redraw = true
        end
      end

      -- Re-evaluate length after reading new output
      ai_len = tab._ai_buf and #tab._ai_buf or 0
      is_typing = tab._ai_displayed_chars and (tab._ai_displayed_chars < ai_len)

      -- Typewriter effect logic
      if is_typing then
        -- Reveal characters chunk by chunk (approx 60fps * 150 chars = 9000 chars/sec)
        tab._ai_displayed_chars = math.min(ai_len, tab._ai_displayed_chars + 150)
        dirty = true
      end
      
      -- Update text if dirty
      if dirty and tab.sessions[#tab.sessions] and tab.sessions[#tab.sessions].role == "ai" then
        tab.sessions[#tab.sessions].text = tab._ai_buf:sub(1, tab._ai_displayed_chars or 0)
        tab.sessions[#tab.sessions].blocks = nil -- invalidate cache
        tab.scroll_to_bottom = true
        core.redraw = true
      end
    end
  end
end

-- Kick off background fetch of real model list via PTY bridge
function AGView:fetch_models(force)
  if self.model_proc then return end
  if not force and self.model_list and #self.model_list > 0 then return end
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
    stdin = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if p then
    self.model_proc = p
  else
    -- Bridge failed Ã¢â‚¬â€ load from settings.json as reliable fallback
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
      and not line:match("^[Ã¢Â â€¹Ã¢Â â„¢Ã¢Â Â¹Ã¢Â Â¸Ã¢Â Â¼Ã¢Â Â´Ã¢Â Â¦Ã¢Â Â§Ã¢Â â€¡Ã¢Â Â]")
      and not line:lower():match("fetching")
      and not line:lower():match("loading")
      and not seen[line]
    then
      seen[line] = true
      local name = line
      
      -- If the line starts with an ID followed by multiple spaces (e.g. "gemini-3.1-pro-high   Gemini 3.1 Pro (High)")
      -- strip the ID and keep only the display name for the CLI.
      local id, disp = line:match("^([^%s]+)%s%s+(.+)$")
      if id and disp then
        name = disp
      end

      local usage = nil
      local limited = false
      
      -- Parse usage e.g. "Gemini 1.5 Pro (50/50)"
      local base_name, u1, u2 = name:match("^(.-)%s*[%-]?%s*[%[%(]?(%d+)/(%d+)[^%]%)]*[%]%)]?%s*$")
      if base_name and u1 and u2 then
        name = base_name
        usage = u1 .. "/" .. u2
        limited = (tonumber(u1) >= tonumber(u2))
      else
        local base_name2, pct = name:match("^(.-)%s*[%-]?%s*[%[%(]?weekly usage (%d+)%%[^%]%)]*[%]%)]?%s*$")
        if not base_name2 then
          base_name2, pct = name:match("^(.-)%s*[%-]?%s*[%[%(]?(%d+)%%[^%]%)]*[%]%)]?%s*$")
        end
        if base_name2 and pct then
          name = base_name2
          usage = pct .. "%"
          -- Force red badge if the usage string specifically contains '0%' (as requested)
          limited = (tonumber(pct) == 0) or (tonumber(pct) >= 100)
        else
          base_name, u1, u2 = line:match("^(.-)%s+(%d+)%s*/%s*(%d+)%s*$")
          if base_name and u1 and u2 then
            name = base_name
            usage = u1 .. "/" .. u2
            limited = (tonumber(u1) >= tonumber(u2))
          end
        end
      end
      table.insert(models, { name = name, usage = usage, limited = limited })
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
  if not config.antigravity.selected_model and #self.model_list > 0 then
    config.antigravity.selected_model = self.model_list[1].name
  end
  self.auth_status = "logged_in"
  core.redraw = true
end

-- Hook into core.quit to kill any zombie background processes when Lite-XL exits
local old_quit = core.quit
function core.quit(force)
  if instance then
    for _, c in ipairs(instance.chats) do
      if c.process then pcall(function() c.process:kill() end) end
    end
    if instance.model_proc then pcall(function() instance.model_proc:kill() end) end
    if instance.temp_files then
      for _, fpath in ipairs(instance.temp_files) do
        pcall(os.remove, fpath)
      end
    end
  end
  return old_quit(force)
end

-- Ã¢â€â‚¬Ã¢â€â‚¬ Draw helpers Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
local function draw_rect_outline(x, y, w, h, col)
  renderer.draw_rect(x,     y,     w, 1, col)
  renderer.draw_rect(x,     y+h-1, w, 1, col)
  renderer.draw_rect(x,     y,     1, h, col)
  renderer.draw_rect(x+w-1, y,     1, h, col)
end


local function wrap_input_text(font, text, max_w)
  local lines = {}
  if text == "" then
    return {{ text = "", start_byte = 1, end_byte = 0, has_nl = false }}
  end
  
  local line_start = 1
  local line_str = ""
  local current_byte = 1
  
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if char == "\n" then
      table.insert(lines, { text = line_str, start_byte = line_start, end_byte = current_byte - 1, has_nl = true })
      line_start = current_byte + 1
      line_str = ""
    else
      if font:get_width(line_str .. char) > max_w and #line_str > 0 then
        table.insert(lines, { text = line_str, start_byte = line_start, end_byte = current_byte - 1, has_nl = false })
        line_start = current_byte
        line_str = char
      else
        line_str = line_str .. char
      end
    end
    current_byte = current_byte + #char
  end
  table.insert(lines, { text = line_str, start_byte = line_start, end_byte = #text, has_nl = false })
  return lines
end

function AGView:draw()
  if self.size.x < 4 then return end

  -- Recompute the full palette from the active theme every frame
  local P = get_palette()

  local x, y = self.position.x, self.position.y
  local w, h  = self.size.x, self.size.y
  local pad   = 10 * SCALE
  local cur_y = y

  -- Ã¢â€â‚¬Ã¢â€â‚¬ Full background Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
  renderer.draw_rect(x, y, w, h, P.bg)
  -- Left border (panel is on the right side)
  renderer.draw_rect(x, y, 1, h, P.border)

  -- Ã¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢Â
  -- HEADER
  -- Ã¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢Â
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
  -- Ã¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢Â
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

  -- Ã¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢Â
  -- INPUT AREA (at bottom, fixed)
  -- Ã¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢Â
  local send_h   = 30 * SCALE
  local inp_x = x + pad
  local inp_w = w - 2 * pad
  local max_text_w = inp_w - 16 * SCALE

  local display_text = #self:state().input > 0 and self:state().input or "Ask anything about your code."
  local wrapped_lines = wrap_input_text(style.font, display_text, max_text_w)
  
  local line_h = style.font:get_height()
  local num_lines = #wrapped_lines
  local max_lines = 10
  local visible_lines = math.min(num_lines, max_lines)
  local input_text_h = visible_lines * line_h
  
  local input_pad_y = 8 * SCALE
  local hint_h = 10 * SCALE
  local input_h = input_text_h + (input_pad_y * 2) + hint_h
  
  local bottom_h = input_h + send_h + 3 * pad
  local chat_bot = y + h - bottom_h

  -- Divider above input
  renderer.draw_rect(x, chat_bot, w, 1, P.border)

  -- Input box
  local inp_y = chat_bot + pad
  renderer.draw_rect(inp_x, inp_y, inp_w, input_h, P.bg_input)
  draw_rect_outline(inp_x, inp_y, inp_w, input_h,
    core.active_view == self and P.border_input or P.border)

  local fg_inp = #self:state().input > 0 and P.fg or P.fg_muted

  local cursor_idx = self:state().cursor or #self:state().input
  local cursor_x = 0
  local cursor_y_idx = 1
  
  for i, line in ipairs(wrapped_lines) do
    cursor_y_idx = i
    if not line.has_nl and cursor_idx == line.end_byte and i < #wrapped_lines then
      cursor_x = style.font:get_width(line.text)
      break
    elseif cursor_idx >= line.start_byte and cursor_idx <= line.end_byte then
      local sub_len = cursor_idx - line.start_byte + 1
      cursor_x = style.font:get_width(line.text:sub(1, sub_len))
      break
    elseif line.has_nl and cursor_idx == line.end_byte then
      cursor_x = style.font:get_width(line.text)
      break
    elseif cursor_idx < line.start_byte then
      cursor_x = 0
      break
    end
  end
  
  if not self:state().input_scroll_y then self:state().input_scroll_y = 0 end
  
  local tx = inp_x + 8 * SCALE
  local cursor_y_pos = (cursor_y_idx - 1) * line_h
  if core.active_view == self then
    if cursor_y_pos < self:state().input_scroll_y then
      self:state().input_scroll_y = cursor_y_pos
    elseif cursor_y_pos + line_h > self:state().input_scroll_y + input_text_h then
      self:state().input_scroll_y = cursor_y_pos + line_h - input_text_h
    end
  end
  
  core.push_clip_rect(inp_x, inp_y, inp_w, input_text_h + (input_pad_y * 2))
  for i, line in ipairs(wrapped_lines) do
    local ly = inp_y + input_pad_y + (i - 1) * line_h - self:state().input_scroll_y
    if ly + line_h >= inp_y and ly <= inp_y + input_h then
      renderer.draw_text(style.font, line.text, tx, ly, fg_inp)
    end
  end

  -- Blink cursor
  if core.active_view == self and math.floor(self.tick / 30) % 2 == 0 then
    local cw = #self:state().input > 0 and cursor_x or style.font:get_width(display_text)
    if #self:state().input == 0 then cw = 0 end
    local cy = inp_y + input_pad_y + (cursor_y_idx - 1) * line_h - self:state().input_scroll_y
    renderer.draw_rect(tx + cw, cy, 2 * SCALE, line_h, P.fg_accent)
  end
  core.pop_clip_rect()

  -- Hint text bottom-right of input
  local hint = "Enter Ã¢â€ Âµ"
  renderer.draw_text(style.font, hint,
    inp_x + inp_w - style.font:get_width(hint) - 6 * SCALE,
    inp_y + input_h - style.font:get_height() - 5 * SCALE,
    P.fg_muted)

  -- Send/Stop button and Attachment button
  local send_y = inp_y + input_h + 4 * SCALE
  local attach_w = 34 * SCALE
  local send_w = inp_w - attach_w - 4 * SCALE
  local is_running = self:state().process ~= nil
  
  -- Draw attachment button
  local attach_bg = self.hover_attach and P.bg_send_hl or P.bg_send
  renderer.draw_rect(inp_x, send_y, attach_w, send_h, attach_bg)
  local attach_icon = "\u{f0c6}" -- paperclip icon
  renderer.draw_text(style.icon_font, attach_icon,
    inp_x + math.floor((attach_w - style.icon_font:get_width(attach_icon)) / 2),
    send_y + math.floor((send_h - style.icon_font:get_height()) / 2),
    P.fg_send)
  self._attach_rect = { x = inp_x, y = send_y, w = attach_w, h = send_h }
  
  -- Draw Send button
  local send_x = inp_x + attach_w + 4 * SCALE
  local send_bg = is_running and { common.color "#D94C4C" } or P.bg_send
  if self.hover_send then
    send_bg = is_running and { common.color "#F26363" } or P.bg_send_hl
  end
  renderer.draw_rect(send_x, send_y, send_w, send_h, send_bg)

  local send_lbl = is_running and "      [x] STOP GENERATING      " or "  Send"
  renderer.draw_text(style.font, send_lbl,
    send_x + math.floor((send_w - style.font:get_width(send_lbl)) / 2),
    send_y + math.floor((send_h - style.font:get_height()) / 2),
    P.fg_send)

  -- Store send button bounds for click detection
  self._send_rect = { x = send_x, y = send_y, w = send_w, h = send_h }

  -- Ã¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢Â
  -- CHAT HISTORY (scrollable, between quick-actions and input)
  -- Ã¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢Â
    local tab_h = 24 * SCALE
  self.tab_rects = {}
  self.tab_stop_rects = {}
  local cur_x = x + pad
  for i, c in ipairs(self.chats) do
    local label = tostring(i)
    if c.status == "running" then
      label = "working..."
    end
    
    local stop_w = 0
    if c.status == "running" then
      stop_w = style.font:get_width(" [x]") + 8 * SCALE
    end
    
    local tw = style.font:get_width(label) + 16 * SCALE + stop_w
    local tab_bg = (i == self.active_idx) and P.bg_btn_hl or P.bg
    local tab_fg = (i == self.active_idx) and P.fg or P.fg_muted
    
    renderer.draw_rect(cur_x, cur_y, tw, tab_h, tab_bg)
    renderer.draw_text(style.font, label, cur_x + 8 * SCALE, cur_y + math.floor((tab_h - style.font:get_height())/2), tab_fg)
    
    if c.status == "running" then
      local sx = cur_x + tw - stop_w
      renderer.draw_text(style.font, " [x]", sx, cur_y + math.floor((tab_h - style.font:get_height())/2), { common.color "#FB4934" })
      table.insert(self.tab_stop_rects, { x = sx, y = cur_y, w = stop_w, h = tab_h, idx = i })
    end
    
    table.insert(self.tab_rects, { x = cur_x, y = cur_y, w = tw - stop_w, h = tab_h, idx = i })
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
  core.push_clip_rect(x, chat_top, w, chat_h)

  local lh_f = style.font:get_height() + 2 * SCALE
  local lh_c = style.code_font:get_height() + 2 * SCALE
  local ty    = chat_top + 4 * SCALE - self:state().scroll_y
  local total_h = 0
  self._copy_rects = {}

    if #self:state().sessions == 0 then
      local msg = "Type /help for commands"
      local w_msg = style.font:get_width(msg)
      renderer.draw_text(style.font, msg, x + math.floor((w - w_msg) / 2), chat_top + math.floor(chat_h / 2) - self:state().scroll_y, P.fg_muted)
    end

  for _, sess in ipairs(self:state().sessions) do
    local is_user = sess.role == "user"
    local lh      = is_user and lh_f or lh_c
    local msg_pad = 8 * SCALE
    local msg_w   = w - 2 * pad - 4 * SCALE
    local bg_col  = is_user and P.bg_user_msg or P.bg_ai_msg
    local fg_col  = is_user and P.fg_user or P.fg_ai

    -- Cache parsed blocks (invalidated when text or width changes)
    if not sess.blocks or sess._cached_text ~= sess.text or sess._cached_w ~= msg_w then
      sess.blocks = parse_blocks(sess.text, style.font, style.code_font, msg_w - 2 * msg_pad)
      sess._cached_text = sess.text
      sess._cached_w = msg_w
    end

    local msg_h = 2 * msg_pad
    for _b, blk in ipairs(sess.blocks) do
      if blk.type == "code" then
        msg_h = msg_h + #blk.raw_lines * lh_c + 8 * SCALE + 24 * SCALE
      elseif blk.type == "empty" then
        msg_h = msg_h + lh_f
      elseif blk.type == "paragraph" then
        local f = (blk.level > 0) and (style.big_font or style.font) or style.font
        local lh = f:get_height() + 2 * SCALE
        msg_h = msg_h + #blk.wrapped_lines * lh
      end
    end
    msg_h = math.max(lh_f + 2 * msg_pad, msg_h)

    -- Role label
    if ty + msg_h + lh_f >= chat_top and ty <= chat_bot then
      local role_lbl = is_user and "You" or "Antigravity"
      renderer.draw_text(style.font, role_lbl, x + pad, math.max(chat_top, math.min(ty, chat_bot - style.font:get_height())), P.fg_muted)
    end
    ty = ty + style.font:get_height() + 2 * SCALE

    -- Message bubble background
    if ty + msg_h >= chat_top and ty <= chat_bot then
      renderer.draw_rect(x + pad, ty, msg_w, msg_h, bg_col)
      draw_rect_outline(x + pad, ty, msg_w, msg_h, P.border)
    end

    -- Blocks inside bubble
    local line_y = ty + msg_pad
    for _b, blk in ipairs(sess.blocks) do
      if blk.type == "code" and #blk.raw_lines > 0 then
        local b_h = #blk.raw_lines * lh_c + 8 * SCALE
        local hdr_h = 24 * SCALE
        local lang = blk.lang or "txt"
        
        if line_y + hdr_h >= chat_top and line_y <= chat_bot then
          renderer.draw_rect(x + pad + 4 * SCALE, line_y, msg_w - 8 * SCALE, hdr_h, P.bg_darker)
          draw_rect_outline(x + pad + 4 * SCALE, line_y, msg_w - 8 * SCALE, hdr_h, P.border)
          renderer.draw_text(style.font, lang, x + pad + 10 * SCALE, line_y + math.floor((hdr_h - style.font:get_height())/2), P.fg_muted)
          
          local c_id = tostring(_) .. "_code_" .. tostring(_b)
          local copy_txt = self.copy_flash_idx == c_id and "Copied!" or "Copy"
          local ccol = self.copy_flash_idx == c_id and P.fg_accent or P.fg_muted
          local cw = style.font:get_width(copy_txt)
          renderer.draw_text(style.font, copy_txt, x + pad + msg_w - 14 * SCALE - cw, line_y + math.floor((hdr_h - style.font:get_height())/2), ccol)
          
          table.insert(self._copy_rects, {
            x = x + pad + msg_w - 24 * SCALE - cw, y = line_y, w = cw + 20 * SCALE, h = hdr_h,
            text = table.concat(blk.raw_lines, "\n"), idx = c_id
          })
        end
        line_y = line_y + hdr_h
        
        if line_y + b_h >= chat_top and line_y <= chat_bot then
          renderer.draw_rect(x + pad + 4 * SCALE, line_y, msg_w - 8 * SCALE, b_h, P.bg_darker)
          draw_rect_outline(x + pad + 4 * SCALE, line_y, msg_w - 8 * SCALE, b_h, P.border)
        end
        line_y = line_y + 4 * SCALE
        
        local synt = syntax.get("dummy." .. lang) or syntax.get(lang)
        local state = nil
        
        for _, line in ipairs(blk.raw_lines) do
          if line_y + lh_c >= chat_top and line_y <= chat_bot then
            local tokens = { "normal", line }
            if synt then
              local ok, res1, res2 = pcall(tokenizer.tokenize, synt, line, state)
              if ok then tokens, state = res1, res2 end
            end
            local lx = x + pad + msg_pad
            for i = 1, #tokens, 2 do
              local type = tokens[i]
              local text = tokens[i+1]
              local col = style.syntax[type] or style.syntax["normal"] or P.fg_ai
              lx = draw_text_emoji(style.code_font, text, lx, line_y, col)
            end
          else
            if synt then pcall(function() _, state = tokenizer.tokenize(synt, line, state) end) end
          end
          line_y = line_y + lh_c
        end
        line_y = line_y + 4 * SCALE
        
      elseif blk.type == "empty" then
        line_y = line_y + lh_f
        
      elseif blk.type == "paragraph" then
        local f = (blk.level > 0) and (style.big_font or style.font) or style.font
        local lh = f:get_height() + 2 * SCALE
        local l_col = (blk.level > 0) and P.fg_accent or fg_col
        
        for l_idx, w_line in ipairs(blk.wrapped_lines) do
          if line_y + lh >= chat_top and line_y <= chat_bot then
            local lx = x + pad + msg_pad
            if blk.list and l_idx == 1 then
              renderer.draw_text(f, "Ã¢â‚¬Â¢ ", lx, line_y, P.fg_accent)
              lx = lx + f:get_width("Ã¢â‚¬Â¢ ")
            elseif blk.list then
              lx = lx + f:get_width("Ã¢â‚¬Â¢ ")
            end
            
            for _, seg in ipairs(w_line) do
              local cfont = seg.font
              local ccol = l_col
              if seg.type == "code" or seg.type == "code_link" then ccol = style.syntax["keyword"] or P.fg_accent
              elseif seg.type == "bold" then ccol = P.fg_accent
              elseif seg.type == "link" then ccol = style.syntax["function"] or P.fg_accent end
              
              draw_text_emoji(cfont, seg.text, lx, line_y, ccol)
              lx = lx + seg.width
            end
          end
          line_y = line_y + lh
        end
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
      local dots = string.rep("Ã¢â‚¬Â¢", (math.floor(self.tick / 20) % 4))
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
    for _, line in ipairs(wrap_raw_text(style.font, msg, mw)) do
      renderer.draw_text(style.font, line, x + pad, ty, P.fg_muted)
      ty = ty + style.font:get_height() + 2 * SCALE
    end
  end
  core.pop_clip_rect()

  -- Ã¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢Â
  -- MENTION POPUP
  -- Ã¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢ÂÃ¢â€¢Â
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
      renderer.draw_text(style.font, type(file) == "table" and file.display or file, pop_x + 8 * SCALE, iy + 4 * SCALE, P.fg)
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
        
        if m.limited then
          -- red corner wrapper / border if usage is over limit
          draw_rect_outline(x, ry, w, item_h, P.dot_err)
        end
        
        local label = m.name
        local fg    = m.limited and P.dot_err or (is_sel and P.fg_accent or P.fg)
        renderer.draw_text(mf, label, x + pad,
          ry + math.floor((item_h - mf:get_height()) / 2), fg)
          
        if m.usage then
          local usage_w = mf:get_width(m.usage)
          local ufg = m.limited and P.dot_err or P.fg_muted
          renderer.draw_text(mf, m.usage,
            x + w - pad - usage_w,
            ry + math.floor((item_h - mf:get_height()) / 2), ufg)
        elseif is_sel then
          renderer.draw_text(mf, "[v]",
            x + w - pad - mf:get_width("[v]"),
            ry + math.floor((item_h - mf:get_height()) / 2), P.dot_run)
        end
        table.insert(self._mpicker_rects, { x=x, y=ry, w=w, h=item_h, idx=i })
      end
    end
  end
end

-- Ã¢â€â‚¬Ã¢â€â‚¬ Input Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
function AGView:on_text_input(text)
  local c = self:state().cursor or #self:state().input
  local before = self:state().input:sub(1, c)
  local after = self:state().input:sub(c + 1)
  self:state().input = before .. text .. after
  self:state().cursor = c + #text
  self:_update_mentions()
  core.redraw = true
end

function AGView:on_paste(text)
  if not text then return end
  local is_long = #text > 3000
  local paste_txt = text
  if is_long then
    local tmp_dir = USERDIR .. "/tempfiles"
    os.execute('mkdir "' .. tmp_dir:gsub("/", "\\") .. '" 2>nul')
    pcall(system.mkdir, tmp_dir)
    local filename = os.date("pasted_text_%Y%m%d_%H%M%S.txt")
    local filepath = tmp_dir .. "/" .. filename
    local f = io.open(filepath, "w")
    if f then
      f:write(text)
      f:close()
      table.insert(self.temp_files, filepath)
      core.log("Saved long paste to %s", filename)
      paste_txt = " @" .. filename .. " "
    else
      paste_txt = text:gsub("\r", "")
    end
  else
    paste_txt = text:gsub("\r", "")
  end
  local c = self:state().cursor or #self:state().input
  local before = self:state().input:sub(1, c)
  local after = self:state().input:sub(c + 1)
  self:state().input = before .. paste_txt .. after
  self:state().cursor = c + #paste_txt
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
      if type(choice) == "table" and choice.type == "dir" then
        self:state().input = self:state().input:gsub("@[^%s]*$", "@" .. choice.full_path)
        self:_update_mentions()
      else
        local path = type(choice) == "table" and choice.full_path or choice
        self:state().input = self:state().input:gsub("@[^%s]*$", "@" .. path .. " ")
        self:state().mention_suggestions = nil
      end
      core.redraw = true
      return true
    elseif key == "escape" then
      self:state().mention_suggestions = nil
      core.redraw = true
      return true
    end
  end

  if key == "escape" then
    if self:state().process or self:state().status == "running" then
      if self:state().process then
        pcall(function() graceful_kill(self:state().process) end)
        self:state().process = nil
      end
      self:state()._ai_buf = (self:state()._ai_buf or "") .. "\n\n*[Stopped by user]*"
      self:state()._ai_displayed_chars = #(self:state()._ai_buf)
      self:state().status = "idle"
      core.log("Chat generation stopped by user.")
      core.redraw = true
      return true
    end
  end

  local mods = keymap.modkeys or {}

  if key == "return" and mods["shift"] and not mods["ctrl"] then
    local c = self:state().cursor or #self:state().input
    local before = self:state().input:sub(1, c)
    local after = self:state().input:sub(c + 1)
    self:state().input = before .. "\n" .. after
    self:state().cursor = c + 1
    self:_update_mentions()
    core.redraw = true
    return true
  end

  if key == "return" and not mods["ctrl"] and not mods["shift"] then
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
    if self:state().process then pcall(function() graceful_kill(self:state().process) end) end
    self:state().process  = nil
    core.redraw = true
    return true
  end

  if key == "backspace" then
    local text = self:state().input or ""
    local c = self:state().cursor or #text
    if #text > 0 and c > 0 then
      local i = c
      -- step back over continuation bytes (10xxxxxx)
      while i > 1 and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do
        i = i - 1
      end
      self:state().input = text:sub(1, i - 1) .. text:sub(c + 1)
      self:state().cursor = i - 1
      self:_update_mentions()
      core.redraw = true
    end
    return true
  end

  if key == "delete" then
    local c = self:state().cursor or #self:state().input
    if c < #self:state().input then
      local next_c = utf8_next(self:state().input, c)
      local before = self:state().input:sub(1, c)
      local after = self:state().input:sub(next_c + 1)
      self:state().input = before .. after
      self:_update_mentions()
      core.redraw = true
    end
    return true
  end

  if key == "left" then
    self:state().cursor = utf8_prev(self:state().input, self:state().cursor or #self:state().input)
    core.redraw = true
    return true
  elseif key == "right" then
    self:state().cursor = utf8_next(self:state().input, self:state().cursor or #self:state().input)
    core.redraw = true
    return true
  elseif key == "home" then
    self:state().cursor = 0
    core.redraw = true
    return true
  elseif key == "end" then
    self:state().cursor = #self:state().input
    core.redraw = true
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

-- Ã¢â€â‚¬Ã¢â€â‚¬ Mouse Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
function AGView:on_mouse_moved(mx, my, ...)
  AGView.super.on_mouse_moved(self, mx, my, ...)
  self.hover_btn  = nil
  self.hover_send = false
  self.hover_attach = false

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
  self.hover_attach = false
  if self._attach_rect then
    local r = self._attach_rect
    self.hover_attach = (mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h)
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

  -- Check if clicked inside input
  local pad = 16 * SCALE
  local chat_bot = self.size.y - (style.font:get_height() + 16 * SCALE) - 10 * SCALE - pad
  local inp_y = chat_bot + pad
  local input_h = style.font:get_height() + 16 * SCALE
  if my >= inp_y and my <= inp_y + input_h then
    local inp_x = self.position.x + pad
    local inp_w = self.size.x - 2 * pad
    local tx = inp_x + 8 * SCALE
    if core.active_view == self then
      local max_text_w = inp_w - 16 * SCALE
      local cursor_idx = self:state().cursor or #self:state().input
      local cursor_x = style.font:get_width(self:state().input:sub(1, cursor_idx))
      if cursor_x > max_text_w then tx = tx - (cursor_x - max_text_w) end
    end
    local click_x = mx - tx
    local best_cursor = 0
    local min_dist = math.abs(click_x)
    local i = 0
    while i < #self:state().input do
      local next_i = utf8_next(self:state().input, i)
      local char_w = style.font:get_width(self:state().input:sub(1, next_i))
      local dist = math.abs(char_w - click_x)
      if dist < min_dist then
        min_dist = dist
        best_cursor = next_i
      end
      i = next_i
    end
    self:state().cursor = best_cursor
    core.redraw = true
    return true
  end
  if self.close_btn_rect then
    local r = self.close_btn_rect
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      if self:state().process then pcall(function() graceful_kill(self:state().process) end) end
      if self:state().tmpfile then pcall(os.remove, self:state().tmpfile) end
      table.remove(self.chats, self.active_idx)
      if self.active_idx > #self.chats then self.active_idx = #self.chats end
      core.redraw = true
      return true
    end
  end
  for _, r in ipairs(self.tab_stop_rects or {}) do
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      local c = self.chats[r.idx]
      if c and c.process then
        pcall(function() graceful_kill(c.process) end)
        c.process = nil
        c.status = "idle"
        if c.tmpfile then pcall(os.remove, c.tmpfile); c.tmpfile = nil end
        if c.sessions[#c.sessions] and c.sessions[#c.sessions].role == "ai" then
          c.sessions[#c.sessions].text = (c.sessions[#c.sessions].text or "") .. "\n\n[Stopped by user]"
          c.sessions[#c.sessions].lines = nil
        end
        core.redraw = true
        return true
      end
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

  -- Attachment button
  if self.hover_attach then
    self:open_artifacts_popup()
    return true
  end

  -- Send/Stop button
  if self.hover_send then
    if self:state().process then
      pcall(function() graceful_kill(self:state().process) end)
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

function AGView:open_artifacts_popup()
  local cid = self:state().cid
  if not cid then
    core.log("No active conversation to find artifacts.")
    return
  end
  
  local base_dir = (os.getenv("USERPROFILE") or os.getenv("HOME"))
  local artifacts_path = base_dir .. "/.gemini/antigravity-cli/brain/" .. cid
  
  local files = system.list_dir(artifacts_path)
  if not files or #files == 0 then
    core.log("No artifacts found for this conversation.")
    return
  end
  
  local items = {}
  for _, f in ipairs(files) do
    if not f:match("^%.") then -- skip hidden
      local path = artifacts_path .. "/" .. f
      local info = system.get_file_info(path)
      if info and info.type == "file" then
        table.insert(items, { text = f, path = path })
      end
    end
  end
  
  if #items == 0 then
    core.log("No artifact files found.")
    return
  end
  
  core.command_view:enter("Open Artifact", {
    submit = function(text, item)
      if item and item.path then
        core.root_view:open_doc(core.open_doc(item.path))
      end
    end,
    suggest = function(text)
      return common.fuzzy_match(items, text)
    end
  })
end

-- Ã¢â€â‚¬Ã¢â€â‚¬ Commands Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
command.add(nil, {
  ["antigravity:toggle"] = function()
    if not instance then
      instance = AGView()
      rawset(_G, "_ag_instance", instance) -- expose for activity_bar auth display
    end
    
    local sidebar = _G.get_sidebar_node and _G.get_sidebar_node(true) -- dont_create=true
    local node = core.root_view.root_node:get_node_for_view(instance)
    
    -- Determine if AI is currently visible and active
    local ai_is_active = sidebar and (sidebar.active_view == instance)
    
    if ai_is_active then
      -- Toggle OFF: close everything in the sidebar
      for i = #sidebar.views, 1, -1 do
        sidebar:close_view(core.root_view.root_node, sidebar.views[i])
      end
      instance.visible = false
    else
      -- Toggle ON: force AI open, closing any other plugin in the sidebar
      if sidebar then
        -- Sidebar exists Ã¢â‚¬â€ close other views and add/activate AI
        for i = #sidebar.views, 1, -1 do
          if sidebar.views[i] ~= instance then
            sidebar:close_view(core.root_view.root_node, sidebar.views[i])
          end
        end
        if not core.root_view.root_node:get_node_for_view(instance) then
          sidebar:add_view(instance)
        end
        sidebar:set_active_view(instance)
        instance.visible = true
        node_built = true
        core.set_active_view(instance)
      else
        -- No sidebar yet Ã¢â‚¬â€ create one by splitting with instance directly.
        -- Passing instance into split() avoids ever having an empty EmptyView placeholder.
        local primary = core.root_view:get_primary_node()
        local new_node = primary:split("right", instance, { x = true }, true)
        if new_node then
          new_node.should_show_tabs = function() return false end
          -- Patch: allow add_view on this locked node
          if not new_node._ab_patched then
            local old_av = new_node.add_view
            new_node.add_view = function(self, view)
              local l = self.locked; self.locked = nil
              old_av(self, view)
              self.locked = l
            end
            new_node._ab_patched = true
          end
          -- Register as the global sidebar so other plugins can find it
          rawset(_G, "_ag_sidebar_node", new_node)
          new_node.size.x = 0
          instance.size.x = 0
          instance.visible = true
          node_built = true
          core.set_active_view(instance)
        end
      end
    end
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
        -- Clear the model cache so fetch_models actually runs again
        instance.model_list = {}
        instance.model_proc = nil
        instance._model_raw = ""
        
        core.add_thread(function()
          coroutine.yield(20) -- wait 20 seconds for browser auth to complete
          if instance then
            instance:fetch_models(true) -- force=true bypasses the "already loaded" guard
          end
        end)
      end
    })
  end,
})

-- Hook the StatusView draw function to guarantee the entire status bar text is highly contrasted
local StatusView = require "core.statusview"
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
  function() return type(core.active_view) == "table" and core.active_view.get_name and core.active_view:get_name() == "Antigravity" end,
  {
    ["antigravity:return"]    = function() core.active_view:on_key_pressed("return") end,
    ["antigravity:shift-return"] = function()
      local view = core.active_view
      local c = view:state().cursor or #view:state().input
      local before = view:state().input:sub(1, c)
      local after = view:state().input:sub(c + 1)
      view:state().input = before .. "\n" .. after
      view:state().cursor = c + 1
      view:_update_mentions()
      core.redraw = true
    end,
    ["antigravity:backspace"] = function() core.active_view:on_key_pressed("backspace") end,
    ["antigravity:scroll-up"] = function() core.active_view:on_key_pressed("up") end,
    ["antigravity:scroll-down"] = function() core.active_view:on_key_pressed("down") end,
    ["antigravity:escape"]    = function() core.active_view:on_key_pressed("escape") end,
    ["antigravity:paste"]     = function() core.active_view:on_paste(system.get_clipboard()) end,
    ["antigravity:delete"]    = function() core.active_view:on_key_pressed("delete") end,
    ["antigravity:cursor-left"]  = function() core.active_view:on_key_pressed("left") end,
    ["antigravity:cursor-right"] = function() core.active_view:on_key_pressed("right") end,
    ["antigravity:cursor-home"]  = function() core.active_view:on_key_pressed("home") end,
    ["antigravity:cursor-end"]   = function() core.active_view:on_key_pressed("end") end,
  }
)

local keymap = require "core.keymap"
keymap.add {
  ["return"]       = "antigravity:return",
  ["shift+return"] = "antigravity:shift-return",
  ["backspace"]    = "antigravity:backspace",
  ["up"]        = "antigravity:scroll-up",
  ["down"]      = "antigravity:scroll-down",
  ["escape"]    = "antigravity:escape",
  ["ctrl+v"]    = "antigravity:paste",
  ["cmd+v"]     = "antigravity:paste",
  ["delete"]    = "antigravity:delete",
  ["left"]      = "antigravity:cursor-left",
  ["right"]     = "antigravity:cursor-right",
  ["home"]      = "antigravity:cursor-home",
  ["end"]       = "antigravity:cursor-end",
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





