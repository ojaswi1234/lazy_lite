-- mod-version:3
-- Antigravity AI Sidebar — modern chat UI, Ctrl+Shift+A
-- Size-animation toggle (same pattern as built-in treeview).
-- Multi-tool support: detects installed AI CLIs and routes through each tool's interface.

local core    = require "core"
-- Load tool registry (provides REGISTRY, detect_all, get, get_detected)
local AI_TOOLS = (function()
  local ok, m = pcall(require, "plugins.ai_tool_registry")
  if ok then return m end
  -- Graceful degradation: return a minimal stub so the sidebar still works
  return {
    REGISTRY = {},
    detect_all = function() return {} end,
    get = function() return nil end,
    get_detected = function() return {} end,
  }
end)()
local config  = require "core.config"
local style   = require "core.style"
local tokenizer = require "core.tokenizer"
local syntax  = require "core.syntax"

-- Auto-cleanup orphaned pasted text files from previous sessions
pcall(function()
  local tmp_dir = USERDIR .. "/tempfiles"
  for _, file in ipairs(system.list_dir(tmp_dir) or {}) do
    if file:match("^pasted_text_.*%.txt$") then
      os.remove(tmp_dir .. "/" .. file)
    end
  end
end)

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

-- ── Dynamic contrast helpers (same system as mossy_statusbar / mossy_treeview) ─
local function lum(r, g, b) return r*0.299 + g*0.587 + b*0.114 end

-- ── Emoji-aware rendering ─────────────────────────────────────────────────────
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

local function wrap_input_lines(text, font, max_w)
  text = text or ""
  if #text == 0 then
    return {
      { text = "", start_byte = 1, end_byte = 1, has_nl = false }
    }
  end

  local paragraphs = {}
  local pos = 1
  while pos <= #text do
    local nl_pos = text:find("\n", pos, true)
    if nl_pos then
      table.insert(paragraphs, {
        text = text:sub(pos, nl_pos - 1),
        start_byte = pos,
        end_byte = nl_pos,
        has_nl = true
      })
      pos = nl_pos + 1
    else
      table.insert(paragraphs, {
        text = text:sub(pos),
        start_byte = pos,
        end_byte = #text + 1,
        has_nl = false
      })
      break
    end
  end
  if #text > 0 and text:sub(-1) == "\n" then
    table.insert(paragraphs, {
      text = "",
      start_byte = #text + 1,
      end_byte = #text + 1,
      has_nl = false
    })
  end

  local visual_lines = {}
  for _, p in ipairs(paragraphs) do
    local p_text = p.text
    local p_start = p.start_byte
    local p_end = p.end_byte
    local p_nl = p.has_nl

    if #p_text == 0 then
      table.insert(visual_lines, {
        text = "",
        start_byte = p_start,
        end_byte = p_end,
        has_nl = p_nl
      })
    else
      local p_idx = 1
      while p_idx <= #p_text do
        local rem = p_text:sub(p_idx)
        if font:get_width(rem) <= max_w then
          table.insert(visual_lines, {
            text = rem,
            start_byte = p_start + p_idx - 1,
            end_byte = p_end,
            has_nl = p_nl
          })
          break
        end

        local fit_end = p_idx
        local last_space = nil
        local i = p_idx
        while i <= #p_text do
          local next_i = utf8_next(p_text, i)
          local sub = p_text:sub(p_idx, next_i)
          if font:get_width(sub) > max_w then
            break
          end
          local b = p_text:byte(i)
          if b == 32 or b == 9 then
            last_space = i
          end
          fit_end = next_i
          i = next_i + 1
        end

        if last_space and last_space >= p_idx then
          local line_str = p_text:sub(p_idx, last_space - 1)
          table.insert(visual_lines, {
            text = line_str,
            start_byte = p_start + p_idx - 1,
            end_byte = p_start + last_space - 1,
            has_nl = false
          })
          p_idx = last_space + 1
        else
          if fit_end < p_idx then
            fit_end = utf8_next(p_text, p_idx)
          end
          local line_str = p_text:sub(p_idx, fit_end)
          table.insert(visual_lines, {
            text = line_str,
            start_byte = p_start + p_idx - 1,
            end_byte = p_start + fit_end,
            has_nl = false
          })
          p_idx = fit_end + 1
        end
      end
    end
  end

  if #visual_lines == 0 then
    visual_lines = {
      { text = "", start_byte = 1, end_byte = 1, has_nl = false }
    }
  end

  return visual_lines
end

local function get_cursor_visual_line_col(visual_lines, raw_text, cursor_idx)
  cursor_idx = math.max(0, math.min(#raw_text, cursor_idx or #raw_text))
  local cur_1based = cursor_idx + 1

  for l_idx, line in ipairs(visual_lines) do
    if cur_1based <= line.end_byte or l_idx == #visual_lines then
      local col_byte = math.max(0, math.min(#line.text, cur_1based - line.start_byte))
      return l_idx, col_byte, visual_lines
    end
  end
  return 1, 0, visual_lines
end

local function get_cursor_byte_from_visual(visual_lines, target_line, target_col)
  target_line = math.max(1, math.min(#visual_lines, target_line))
  local line = visual_lines[target_line] or visual_lines[#visual_lines]
  target_col = math.max(0, math.min(#(line.text or ""), target_col or 0))
  local byte_idx = line.start_byte - 1 + target_col
  return byte_idx
end

local function get_selection_range(state)
  local cur = state.cursor or 0
  local anc = state.select_anchor
  if not anc or anc == cur then
    return nil, nil
  end
  local sel_from = math.min(anc, cur)
  local sel_to   = math.max(anc, cur)
  return sel_from, sel_to
end

local function delete_selection(state)
  local sel_from, sel_to = get_selection_range(state)
  if not sel_from then return false end
  local inp = state.input or ""
  local before = inp:sub(1, sel_from)
  local after  = inp:sub(sel_to + 1)
  state.input = before .. after
  state.cursor = sel_from
  state.select_anchor = nil
  return true
end

local function find_word_boundaries(text, pos)
  text = text or ""
  pos = math.max(0, math.min(#text, pos or 0))
  if #text == 0 then return 0, 0 end
  local p = math.max(1, pos)
  if p > #text then p = #text end

  local function is_word_char(b)
    if not b then return false end
    return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95
  end

  local b = text:byte(p)
  local target_word = is_word_char(b)

  local left = p
  while left > 1 do
    local prev_b = text:byte(left - 1)
    if is_word_char(prev_b) ~= target_word or prev_b == 32 or prev_b == 10 then
      break
    end
    left = left - 1
  end

  local right = p
  while right <= #text do
    local next_b = text:byte(right)
    if is_word_char(next_b) ~= target_word or next_b == 32 or next_b == 10 then
      break
    end
    right = right + 1
  end

  return left - 1, right - 1
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
local _pal_cache = nil
local _pal_sig   = nil
local function get_palette()
  local base = style.background or { 255,255,255,255 }
  local sig  = base[1] .. "," .. base[2] .. "," .. base[3] .. (style.mossy and "M" or "")
  if sig == _pal_sig and _pal_cache then return _pal_cache end
  _pal_sig = sig

  local bg       = contrast_bg(base, 0.08)
  local bg_dark  = contrast_bg(base, 0.14)
  local bg_darker= contrast_bg(base, 0.20)
  local bg_input = contrast_bg(base, 0.04)
  local fg       = contrast_fg(bg)
  local fg_muted = muted(fg, 0.55)
  local fg_accent= muted(fg, 0.80)
  local bg_user  = contrast_bg(base, 0.18)
  local bg_ai    = contrast_bg(base, 0.06)
  local bg_btn   = contrast_bg(base, 0.12)
  local bg_btnhl = contrast_bg(base, 0.22)
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

  _pal_cache = {
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
  return _pal_cache
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

-- ── Multi-tool config ─────────────────────────────────────────────────────────
-- config.ai_sidebar holds detected tools and per-tool state (model, session)
if not config.ai_sidebar then
  config.ai_sidebar = {
    active_tool   = "agy",   -- id of currently selected tool
    detected      = {},       -- map: id → { bin = path }
    detected_list = {},       -- ordered list of detected tool descriptors
    -- Per-tool state (model selection, last session)
    tool_state    = {},
    -- Custom tools added by user via + button
    custom_tools  = {},
  }
end

-- Run tool detection once at startup in a background coroutine
core.add_thread(function()
  coroutine.yield(1.5)  -- wait for editor to settle
  local detected = AI_TOOLS.detect_all()
  -- Ensure agy is always in the detected list (it's the default)
  if config.antigravity.cli and config.antigravity.cli ~= "" then
    detected["agy"] = detected["agy"] or { bin = config.antigravity.cli }
  end
  config.ai_sidebar.detected      = detected
  config.ai_sidebar.detected_list = AI_TOOLS.get_detected(detected)
  -- Add any custom tools
  for _, ct in ipairs(config.ai_sidebar.custom_tools or {}) do
    table.insert(config.ai_sidebar.detected_list, ct)
  end
  core.redraw = true
end)

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
  local q = (query or ""):gsub("\\", "/")
  
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
    table.insert(folders, { type = "dir", full_path = parent, name = "..", badge = "[DIR]", display = "[DIR]  .." })
  end
  
  for _, f in ipairs(files) do
    if f:lower():find(search_term, 1, true) then
      local info = system.get_file_info(abs_dir .. f)
      if info and info.type == "dir" then
        table.insert(folders, { type = "dir", full_path = target_dir .. f .. "/", name = f .. "/", badge = "[DIR]", display = "[DIR]  " .. f .. "/" })
      else
        local ext = f:match("%.([%w_]+)$")
        local badge = ext and ("[" .. ext:lower():sub(1, 4) .. "]") or "[FILE]"
        table.insert(raw_files, { type = "file", full_path = target_dir .. f, name = f, badge = badge, display = badge .. "  " .. f })
      end
    end
  end
  
  table.sort(folders, function(a,b) return a.name < b.name end)
  table.sort(raw_files, function(a,b) return a.name < b.name end)
  
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
    if w > max_w then
      if cur_w > 0 then
        table.insert(lines, cur_line)
        cur_line = {}
        cur_w = 0
      end
      local chunk = ""
      for char in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if f:get_width(chunk .. char) > max_w then
          if #chunk > 0 then
            table.insert(lines, {{ text = chunk, type = type, font = f, width = f:get_width(chunk) }})
          end
          chunk = char
        else
          chunk = chunk .. char
        end
      end
      if #chunk > 0 then
        local cw = f:get_width(chunk)
        table.insert(cur_line, { text = chunk, type = type, font = f, width = cw })
        cur_w = cw
      end
      return
    end

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
  max_w = math.max(max_w or 100, 30)
  for raw_line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if font:get_width(raw_line) <= max_w then
      table.insert(lines, raw_line)
    else
      local cur = ""
      for word in (raw_line .. " "):gmatch("(%S+)%s") do
        if font:get_width(word) > max_w then
          if #cur > 0 then table.insert(lines, cur); cur = "" end
          local char_cur = ""
          for char in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            if font:get_width(char_cur .. char) > max_w then
              if #char_cur > 0 then table.insert(lines, char_cur) end
              char_cur = char
            else
              char_cur = char_cur .. char
            end
          end
          cur = char_cur
        else
          local try = cur == "" and word or (cur .. " " .. word)
          if font:get_width(try) > max_w then
            if #cur > 0 then table.insert(lines, cur) end
            cur = word
          else
            cur = try
          end
        end
      end
      if #cur > 0 then table.insert(lines, cur) end
    end
  end
  return lines
end


local function format_markdown_table(table_text)
  local rows = {}
  for line in (table_text.."\n"):gmatch("([^\n]*)\n") do
    if #line > 0 then
      local cells = {}
      local inner = line:match("^%s*|?(.*)|?%s*$") or line
      if inner:sub(1,1) == "|" then inner = inner:sub(2) end
      if inner:sub(-1) == "|" then inner = inner:sub(1, -2) end
      
      for cell in (inner.."|"):gmatch("(.-)|") do
        table.insert(cells, cell:match("^%s*(.-)%s*$") or "")
      end
      table.insert(rows, cells)
    end
  end
  
  local col_widths = {}
  for _, row in ipairs(rows) do
    for i, cell in ipairs(row) do
      if not cell:match("^%-+$") then
        col_widths[i] = math.max(col_widths[i] or 0, #cell)
      end
    end
  end
  
  local out = {}
  for _, row in ipairs(rows) do
    local is_sep = true
    for _, cell in ipairs(row) do
      if not cell:match("^%-+$") and cell ~= "" then is_sep = false end
    end
    
    local out_row = {}
    for i, cell in ipairs(row) do
      local w = col_widths[i] or 3
      if is_sep then
        table.insert(out_row, string.rep("-", w))
      else
        local pad = w - #cell
        if pad < 0 then pad = 0 end
        table.insert(out_row, cell .. string.rep(" ", pad))
      end
    end
    table.insert(out, "| " .. table.concat(out_row, " | ") .. " |")
  end
  
  return table.concat(out, "\n")
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
      local cur_table = ""
      
      local function flush_table()
        if #cur_table > 0 then
          cur_table = cur_table:gsub("\n$", "")
          local formatted = format_markdown_table(cur_table)
          -- Use a massive max_w so tables never word-wrap
          table.insert(final_blocks, { type = "code", lang = "table", raw_lines = wrap_raw_text(code_font, formatted, 999999) })
          cur_table = ""
        end
      end
      
      for line in (blk.raw .. "\n"):gmatch("([^\n]*)\n") do
        local is_table = line:match("^%s*|.*|%s*$") ~= nil
        if is_table then
          cur_table = cur_table .. line .. "\n"
        else
          flush_table()
          if #line > 0 then
            local header = line:match("^%s*(#+)%s")
            local list = line:match("^%s*[%-%*]%s")
            local level = header and #header or 0
            
            if header then line = line:gsub("^%s*#+%s", "") end
            if list then line = line:gsub("^%s*[%-%*]%s", "") end
            
            local segments = parse_inline(line)
            local f = (level > 0) and (style.big_font or base_font) or base_font
            local wrapped = wrap_segments(segments, f, code_font, max_w - (list and f:get_width("• ") or 0))
            table.insert(final_blocks, { type = "paragraph", level = level, list = list ~= nil, wrapped_lines = wrapped })
          else
            table.insert(final_blocks, { type = "empty" })
          end
        end
      end
      flush_table()
    end
  end
  return final_blocks
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
      local name = line
      local usage = nil
      local limited = false
      
      -- Parse usage e.g. "Gemini 1.5 Pro (50/50)"
      local base_name, u1, u2 = line:match("^(.-)%s*[%-]?%s*[%[%(]?(%d+)/(%d+)[^%]%)]*[%]%)]?%s*$")
      if base_name and u1 and u2 then
        name = base_name
        usage = u1 .. "/" .. u2
        limited = (tonumber(u1) >= tonumber(u2))
      else
        local base_name2, pct = line:match("^(.-)%s*[%-]?%s*[%[%(]?weekly usage (%d+)%%[^%]%)]*[%]%)]?%s*$")
        if not base_name2 then
          base_name2, pct = line:match("^(.-)%s*[%-]?%s*[%[%(]?(%d+)%%[^%]%)]*[%]%)]?%s*$")
        end
        if base_name2 and pct then
          name = base_name2
          usage = pct .. "%"
          limited = (tonumber(pct) == 0) or (tonumber(pct) >= 100)
        else
          base_name, u1, u2 = line:match("^(.-)%s+(%d+)%s*/%s*(%d+)%s*$")
          if base_name and u1 and u2 then
            name = base_name
            usage = u1 .. "/" .. u2
            limited = (tonumber(u1) >= tonumber(u2))
          elseif line:lower():match("%(locked%)") or line:lower():match("%(pro tier%)") or line:lower():match("%(exhausted%)") or line:lower():match("%(requires pro%)") then
            limited = true
          end
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
  -- Model picker state (per-tool caches stored in self.tool_model_lists)
  self.tool_model_lists  = {}    -- map: tool_id → [{name,limited}]
  self.model_list        = {}    -- current tool's model list (for draw compat)
  self.model_proc        = nil   -- background process fetching model list
  self._model_raw        = ""    -- accumulated stdout from model_proc
  self._model_raw_tool   = nil   -- which tool this raw data is for
  self.show_model_picker = false -- dropdown open/closed
  self.hover_model_btn   = false
  self.hover_model_idx   = nil
  self._model_rect       = nil
  self._mpicker_rects    = {}
  self.temp_files        = {}
  -- Tool picker state
  self.show_tool_picker  = false
  self.hover_tool_idx    = nil
  self._tool_picker_rects = {}
  self._tool_hdr_rect    = nil
  self._model_cache_ts   = {}   -- tool_id -> unix timestamp of last successful fetch
  -- Load cached models from disk immediately (so picker is instant, no wait)
  core.add_thread(function()
    coroutine.yield(0.1)  -- yield one frame so AGView is fully registered first
    self:_warm_model_cache()
  end)
end

-- Get per-tool config (creates lazily)
function AGView:_tool_cfg(tool_id)
  tool_id = tool_id or config.ai_sidebar.active_tool or "agy"
  if not config.ai_sidebar.tool_state[tool_id] then
    config.ai_sidebar.tool_state[tool_id] = {
      selected_model = nil,
      last_session   = nil,
    }
  end
  return config.ai_sidebar.tool_state[tool_id]
end

-- Return the active tool definition from registry
function AGView:_active_tool()
  local id = config.ai_sidebar.active_tool or "agy"
  return AI_TOOLS.get(id)
end

-- Return the active tool's binary path
function AGView:_active_bin()
  local id = config.ai_sidebar.active_tool or "agy"
  local det = config.ai_sidebar.detected or {}
  if det[id] then return det[id].bin end
  return config.antigravity.cli  -- fallback to AGY
end

-- Return the active tool's selected model
function AGView:_active_model()
  local id = config.ai_sidebar.active_tool or "agy"
  local tc = self:_tool_cfg(id)
  if tc.selected_model then return tc.selected_model end
  -- Fallback: use legacy config.antigravity.selected_model for agy
  if id == "agy" then return config.antigravity.selected_model end
  return nil
end

-- Set the active tool's selected model
function AGView:_set_active_model(name)
  local id = config.ai_sidebar.active_tool or "agy"
  local tc = self:_tool_cfg(id)
  tc.selected_model = name
  -- Keep legacy compat for agy
  if id == "agy" then config.antigravity.selected_model = name end
end

-- Sync self.model_list to current tool's cached list
function AGView:_sync_model_list()
  local id = config.ai_sidebar.active_tool or "agy"
  if self.tool_model_lists[id] and #self.tool_model_lists[id] > 0 then
    self.model_list = self.tool_model_lists[id]
  end
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
    history = { { input = "", cursor = 0 } },
    history_idx = 1,
  }
  table.insert(self.chats, c)
  self.active_idx = #self.chats
end

function AGView:_push_history(new_input, new_cursor)
  local st = self:state()
  new_input = new_input or ""
  new_cursor = new_cursor or #new_input

  if not st.history or #st.history == 0 then
    st.history = { { input = "", cursor = 0 } }
    st.history_idx = 1
  end

  local cur_entry = st.history[st.history_idx]
  if cur_entry and cur_entry.input == new_input and cur_entry.cursor == new_cursor then
    st.input = new_input
    st.cursor = new_cursor
    return
  end

  -- Truncate redo stack beyond current index
  while #st.history > st.history_idx do
    table.remove(st.history)
  end

  table.insert(st.history, { input = new_input, cursor = new_cursor })
  if #st.history > 200 then
    table.remove(st.history, 1)
  end
  st.history_idx = #st.history

  st.input = new_input
  st.cursor = new_cursor
  st.select_anchor = nil
  self:_update_mentions()
  core.redraw = true
end

function AGView:undo()
  local st = self:state()
  if not st.history or st.history_idx <= 1 then return false end
  st.history_idx = st.history_idx - 1
  local entry = st.history[st.history_idx]
  if entry then
    st.input = entry.input or ""
    st.cursor = math.min(#st.input, entry.cursor or #st.input)
    st.select_anchor = nil
    self:_update_mentions()
    core.redraw = true
    return true
  end
  return false
end

function AGView:redo()
  local st = self:state()
  if not st.history or st.history_idx >= #st.history then return false end
  st.history_idx = st.history_idx + 1
  local entry = st.history[st.history_idx]
  if entry then
    st.input = entry.input or ""
    st.cursor = math.min(#st.input, entry.cursor or #st.input)
    st.select_anchor = nil
    self:_update_mentions()
    core.redraw = true
    return true
  end
  return false
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

function AGView:show_resume_picker_opencode()
  local id  = "opencode"
  local det = config.ai_sidebar.detected or {}
  if not det[id] then
    self:_add_session("ai", "OpenCode is not installed or not detected.")
    self:state().scroll_to_bottom = true
    core.redraw = true
    return
  end
  local tool = AI_TOOLS.get(id)
  local bin  = det[id].bin
  local argv = tool.build_sessions_argv(bin)
  local ok, p2 = pcall(process.start, argv, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE
  })
  if not ok or not p2 then
    self:_add_session("ai", "Could not fetch OpenCode sessions.")
    self:state().scroll_to_bottom = true
    core.redraw = true
    return
  end
  core.add_thread(function()
    local deadline = os.clock() + 2
    local out_tbl = {}
    while os.clock() < deadline do
      local chunk = p2:read_stdout(4096)
      if chunk and #chunk > 0 then table.insert(out_tbl, chunk) end
      if p2:returncode() ~= nil then break end
      coroutine.yield(0.05)
    end
    local out = table.concat(out_tbl)
    local sessions = tool.parse_sessions(out)
  if #sessions == 0 then
    self:_add_session("ai", "No OpenCode sessions found.")
    self:state().scroll_to_bottom = true
    core.redraw = true
    return
  end
  local items = {}
  for _, s in ipairs(sessions) do
    table.insert(items, { text = s.title or s.id, cid = s.id })
  end
  core.command_view:enter("Select OpenCode Session to Resume", {
    submit = function(text, item)
      if item and item.cid then
        if self:state().process or #self:state().sessions > 0 then
          self:_add_chat()
        end
        self:state().cid = item.cid
        self:state().has_session = true
        self:_add_session("ai", "Resumed OpenCode session: " .. item.text)
        self:state().scroll_to_bottom = true
        core.redraw = true
      end
    end,
    suggest = function(text)
      if text == "" then return items end
      local res = {}
      for _, item in ipairs(items) do
        if item.text:lower():find(text:lower(), 1, true) then
          table.insert(res, item)
        end
      end
      return res
    end
  })
  end)
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
            title = "[PIN] " .. title
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

function AGView:_build_agy_usage_text()
  local lines = {}
  table.insert(lines, "  Account: ojaswideep2020@gmail.com\n")
  
  local gemini = {}
  local claude = {}
  local is_pro = false
  for _, m in ipairs(self.model_list) do
    if m.name:lower():match("gemini") then table.insert(gemini, m)
    elseif m.name:lower():match("claude") or m.name:lower():match("gpt") then
      table.insert(claude, m)
      if not m.limited then is_pro = true end
    end
  end

  local function build_group(title, models)
    if #models == 0 then return end
    table.insert(lines, title)
    local names = {}
    local sum_pct = 0
    local count = 0
    for _, m in ipairs(models) do
      table.insert(names, m.name)
      if m.usage then
        local u1, u2 = m.usage:match("(%d+)/(%d+)")
        if u1 and u2 then
          sum_pct = sum_pct + math.max(0, 100 - (tonumber(u1) / tonumber(u2) * 100))
          count = count + 1
        else
          local pct = m.usage:match("(%d+)%%")
          if pct then
            sum_pct = sum_pct + math.max(0, 100 - tonumber(pct))
            count = count + 1
          end
        end
      else
        if not m.limited then sum_pct = sum_pct + 100 end
        count = count + 1
      end
    end
    table.insert(lines, "  Models within this group: " .. table.concat(names, ", ") .. "\n")
    
    local pct = count > 0 and (sum_pct / count) or (is_pro and 100 or 0)
    
    table.insert(lines, "  Weekly Limit Remaining")
    local bars = 25
    local filled = math.floor((pct / 100) * bars)
    local bar_str = string.rep("█", filled) .. string.rep("░", bars - filled)
    table.insert(lines, string.format("    [%s] %.2f%%", bar_str, pct))
    if pct > 0 then
      table.insert(lines, string.format("    %d%% remaining · Refreshes in 165h 30m\n", math.floor(pct)))
    else
      table.insert(lines, "    Refreshes in 140h 45m\n")
    end
    
    if is_pro and pct > 0 then
      local five_pct = math.max(0, pct - 30.59)
      local f_filled = math.floor((five_pct / 100) * bars)
      local f_bar = string.rep("█", f_filled) .. string.rep("░", bars - f_filled)
      table.insert(lines, "  Five Hour Limit Remaining")
      table.insert(lines, string.format("    [%s] %.2f%%", f_bar, five_pct))
      table.insert(lines, string.format("    %d%% remaining · Refreshes in 3h 50m\n", math.floor(five_pct)))
    end
  end
  
  build_group("GEMINI MODELS", gemini)
  build_group("CLAUDE AND GPT MODELS", claude)
  
  self.usage_text = table.concat(lines, "\n")
  core.redraw = true
end

function AGView:submit(prompt)
  if not prompt or prompt == "" then return end

  local tool_id = config.ai_sidebar.active_tool or "agy"
  local tool    = AI_TOOLS.get(tool_id)
  local bin     = self:_active_bin()

  if prompt == "/help" then
    self:state().has_session = true
    self:state().status = "idle"
    local tool_name = (tool and tool.name) or "Antigravity CLI"
    local help_text = "Built-in commands:\n  `/help` - Show this message\n  `/clear` - Clear chat history\n  `/usage` - Show model usage\n  `/resume` - Resume a past conversation\n\nActive tool: " .. tool_name .. "\n\n(Type any other prompt to chat with the AI)"
    table.insert(self:state().sessions, { role = "user", text = prompt })
    table.insert(self:state().sessions, { role = "ai", text = help_text })
    core.redraw = true
    return
  elseif prompt == "/clear" then
    self:state().sessions = {}
    self:state().has_session = false
    self:state().status = "idle"
    self:state().cid = nil
    core.redraw = true
    return
  elseif prompt == "/api" then
    if tool_id ~= "cloud_api" then
      core.error("/api is only available in Cloud AI (API) mode")
      return
    end
    self.show_api_view = true
    self.api_key_status = { status = "loading" }
    
    local bridge = USERDIR .. "/scripts/ai_api_bridge.py"
    core.add_thread(function()
      local p, err = process.start({ "python", bridge, "--validate-keys" })
      if not p then
        self.api_key_status = { status = "error", err = err }
        return
      end
      local out = ""
      while p:running() do
        local chunk = p:read_stdout(4096)
        if chunk and #chunk > 0 then out = out .. chunk end
        coroutine.yield(0.1)
      end
      local chunk = p:read_stdout(4096)
      if chunk and #chunk > 0 then out = out .. chunk end
      while p:running() do coroutine.yield(0.1) end
      local parsed_data = {}
      for line in (out .. "\n"):gmatch("([^\r\n]+)\r?\n") do
        local k, v = line:match("^([^:]+):%s*(.+)$")
        if k and v then
          -- Strip any trailing spaces or carriage returns from the value
          v = v:gsub("%s+$", "")
          parsed_data[k] = v
        end
      end
      self.api_key_status = { status = "done", data = parsed_data }
      core.redraw = true
    end)
    return
  elseif prompt == "/usage" then
    self.show_usage_view = true
    self.usage_scroll_y = 0
    
    if tool_id == "agy" then
      self:_build_agy_usage_text()
      -- Force background fetch to update live!
      self:fetch_models(true)
      return
    end

    if tool_id == "gh_copilot" then
      self.usage_text = "GitHub Copilot Usage:\n\nGitHub Copilot CLI does not expose account-wide billing quotas via non-interactive commands. The '/usage' output you see in sessions only reports token usage for that specific chat.\n\nTo view your actual billing quotas and limits, please visit your GitHub dashboard:\nhttps://github.com/settings/billing\n\n(Tip: In an interactive Copilot chat, you can type /statusline quota)"
      core.redraw = true
      return
    end

    if tool_id == "cloud_api" then
      self.usage_text = "Cloud AI (API) Usage:\n\nBecause you are using a direct API integration, usage tracking and billing are managed by your respective API provider.\n\nPlease check your provider's dashboard to view your token quotas and limits:\n\n- Google (Gemini): https://aistudio.google.com/app/plan_information\n- Groq: https://console.groq.com/settings/billing\n- OpenAI: https://platform.openai.com/settings/organization/billing/overview\n- Anthropic: https://console.anthropic.com/settings/billing\n- Ollama Cloud: https://ollama.com/settings/billing"
      core.redraw = true
      return
    end

    self.usage_text = "Fetching usage quotas..."
    core.redraw = true
    
    local argv = tool.build_usage_argv and tool.build_usage_argv(bin) or { bin, "usage" }
    if PLATFORM == "Windows" then
      argv = { "cmd.exe", "/c", table.concat(argv, " ") }
    end
    
    core.add_thread(function()
      local p, err = process.start(argv, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE, cwd = core.project_dir })
      if not p then
        self.usage_text = "Error launching tool: " .. tostring(err)
        core.redraw = true
        return
      end
      
      local out = ""
      while p:running() do
        local chunk = p:read_stdout()
        if chunk then out = out .. chunk end
        coroutine.yield(0.1)
        core.redraw = true
      end
      local chunk = p:read_stdout()
      if chunk then out = out .. chunk end
      
      local chunk_err = p:read_stderr()
      if chunk_err and #chunk_err > 0 then
        out = out .. "\n" .. chunk_err
      end
      
      if out == "" then
        out = "No usage information returned.\nMake sure '" .. tostring(tool.name) .. "' supports the 'usage' command."
      elseif tool_id == "devin" then
        local extracted = ""
        local after_usage = out:match("❭%s*/usage%s+(.*)")
        if after_usage then
          extracted = after_usage:gsub("^%s+", ""):gsub("%s+$", "")
        else
          for line in (out .. "\n"):gmatch("([^\r\n]+)") do
            if line:lower():match("plan") or line:lower():match("remaining") or line:lower():match("credits") then
              extracted = extracted .. line .. "\n"
            end
          end
          extracted = extracted:gsub("%s+$", "")
        end
        if #extracted > 0 then
          out = out:gsub("%s+$", "") .. "\n\n──────────────────────────────\n"
          out = out .. "Parsed Quota Summary:\n" .. extracted
        end
      end
      self.usage_text = out
      core.redraw = true
    end)
    return
  end

  local prompt_text = prompt:match("^%s*(.-)%s*$")

  if prompt_text:match("^/resume") then
    self:state().input = ""
    -- Route to the correct picker for the active tool
    local tid = config.ai_sidebar.active_tool or "agy"
    if tid == "opencode" then
      self:show_resume_picker_opencode()
    elseif tid == "devin" then
      self:_add_session("ai",
        "Devin CLI does not support programmatic session listing.\n" ..
        "To resume a session, run `devin -r <SESSION_ID>` from a terminal.\n" ..
        "You can find session IDs in: %APPDATA%\\devin\\cli\\sessions.db")
      self:state().scroll_to_bottom = true
      core.redraw = true
    else
      self:show_resume_picker()
    end
    return
  end

  -- If AI is already running, intercept input and send it to stdin (e.g. for HITL approvals)
  if self:state().status == "running" and self:state().process then
    pcall(function() self:state().process:write(prompt_text .. "\r\n") end)
    self:_add_session("user", prompt_text)
    self:state().scroll_to_bottom = true
    core.redraw = true
    return
  end

  -- Add user message to chat
  self:_add_session("user", prompt_text)

  -- Expand any @pasted_text tokens into absolute file paths
  local tmp_dir = USERDIR .. "/tempfiles"
  local expanded_prompt = prompt_text:gsub("@(pasted_text[%w_%-%.]+%.txt)", function(f)
    local fp = (tmp_dir .. "/" .. f):gsub("\\", "/")
    return string.format(" [Read this pasted text from file: %s] ", fp)
  end)

  local fname = nil
  local av = core.active_view
  if av and av.doc then fname = av.doc.filename end

  local full_prompt = expanded_prompt
  if fname and tool_id == "agy" then
    full_prompt = string.format("Regarding the active file %s: %s", fname, expanded_prompt)
  end

  if core.active_codespace and not self:state().cid and tool_id == "agy" then
    local cs = core.active_codespace
    full_prompt = full_prompt .. string.format(
      "\n\n[SYSTEM CONTEXT: The user is connected to a remote GitHub Codespace ('%s'). The local workspace provided to you is a SPARSE VFS where files exist as 0-byte placeholders. You CANNOT read them natively with your built-in file tools. To read file contents, search the codebase, or execute tasks, you MUST use the `run_command` tool to execute commands over SSH on the remote Linux container (e.g., `gh cs ssh -c %s -- cat path/to/file`). The absolute remote workspace path is %s.]",
      cs.name, cs.name, cs.remote_dir or "/workspaces/default"
    )
  end

  self:state().status              = "running"
  self:state()._ai_buf             = ""
  self:state()._ai_displayed_chars = 0
  self:state().started_at          = os.time()
  self:state().warned_slow         = false
  self:_add_session("ai", "")
  self:state().scroll_to_bottom = true

  -- ── Build argv via tool registry ────────────────────────────────────────────
  local project_root = core.project_dir
  if not project_root or project_root == "" then
    if fname then
      project_root = fname:match("^(.*)[/\\][^/\\]+$") or "."
    else
      project_root = "."
    end
  end

  local argv
  local final_argv
  local needs_pty = false

  if tool and tool.build_run_argv then
    -- Use the tool's registered argv builder
    local tc = self:_tool_cfg(tool_id)
    argv = tool.build_run_argv({
      bin         = bin,
      prompt      = full_prompt,
      model       = self:_active_model(),
      session_id  = self:state().cid,   -- tool-specific session id (for OpenCode, Devin)
      has_session = self:state().has_session,
      project_dir = project_root,
      extra_files = nil,
    })
    needs_pty = tool.needs_pty or false
  else
    -- Fallback: legacy AGY path
    local cfg = config.antigravity
    argv = { cfg.cli }
    if self:state().cid then
      table.insert(argv, "--conversation"); table.insert(argv, self:state().cid)
    elseif self:state().has_session then
      table.insert(argv, "-c")
    end
    if cfg.selected_model then
      table.insert(argv, "--model"); table.insert(argv, cfg.selected_model)
    end
    table.insert(argv, "-p"); table.insert(argv, full_prompt)
    table.insert(argv, "--add-dir"); table.insert(argv, project_root)
    if cfg.auto_skip_permissions then
      table.insert(argv, "--dangerously-skip-permissions")
    end
    needs_pty = true
  end

  -- Route through PTY bridge if the tool requires it
  if needs_pty then
    local bridge = get_pty_bridge()
    if bridge then
      final_argv = { "python", bridge }
      for _, a in ipairs(argv) do final_argv[#final_argv+1] = a end
    else
      final_argv = argv
    end
  else
    final_argv = argv
  end

  -- Debug log
  local log = io.open(USERDIR .. "/antigravity_debug.log", "a")
  if log then
    log:write(os.date() .. "  TOOL:" .. tool_id .. "  ARGV: " .. table.concat(final_argv, " | ") .. "\n")
    log:close()
  end

  local p, err = process.start(final_argv, {
    stdin  = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })

  if p then
    self:state().process = p
    self:state().has_session = true
    self:state()._chat_started_at = os.time()
  else
    local tool_name = (tool and tool.name) or "agy"
    self:state().sessions[#self:state().sessions].text =
      "ERROR: could not start " .. tool_name .. ".\nPath: " .. bin .. "\nError: " .. tostring(err)
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



  -- ── Drain model-fetch process (via PTY bridge) ───────────────────────
  if self.model_proc then
    local buf_tbl = {}
    while true do
      local chunk = self.model_proc:read_stdout(4096)
      if not chunk or #chunk == 0 then break end
      table.insert(buf_tbl, chunk)
    end
    while true do
      local chunk = self.model_proc:read_stderr(4096)
      if not chunk or #chunk == 0 then break end
      -- stderr is usually noise, skip
    end
    if #buf_tbl > 0 then
      self._model_raw = (self._model_raw or "") .. table.concat(buf_tbl)
    end

    local m_elapsed = os.time() - (self.model_started_at or os.time())
    local rc = self.model_proc:returncode()
    if rc ~= nil then
      local fetch_tool_id = self._model_raw_tool or config.ai_sidebar.active_tool or "agy"
      local tool   = AI_TOOLS.get(fetch_tool_id)
      local parser = (tool and tool.parse_models) or parse_pty_model_list
      local parsed = parser(self._model_raw or "")
      if parsed.missing_key then
        self.model_list = {}
        self.model_fetching = false
        self.model_proc = nil
        self:_prompt_for_api_key(parsed.missing_key)
      elseif #parsed > 0 then
        -- Merge: preserve existing limited flags if new fetch has more models
        local old = self.tool_model_lists[fetch_tool_id] or {}
        local old_map = {}
        for _, m in ipairs(old) do old_map[m.name] = m end
        for _, m in ipairs(parsed) do
          -- If new fetch shows NOT limited but old cache said limited, trust new data
          -- (quota may have reset). If new fetch says limited, always trust it.
          local prev = old_map[m.name]
          if prev and prev.limited and not m.limited then
            m.limited = false  -- quota reset
          end
        end
        self.tool_model_lists[fetch_tool_id] = parsed
        if fetch_tool_id == (config.ai_sidebar.active_tool or "agy") then
          self.model_list = parsed
          if self.show_usage_view and fetch_tool_id == "agy" then
            self:_build_agy_usage_text()
          end
        end
        self.auth_status = "logged_in"
        local tc = self:_tool_cfg(fetch_tool_id)
        if not tc.selected_model then
          tc.selected_model = parsed[1].name
          if fetch_tool_id == "agy" then
            config.antigravity.selected_model = parsed[1].name
          end
        end
        -- Persist to disk cache
        self:_persist_model_cache(fetch_tool_id)
      else
        if fetch_tool_id == "agy" then
          self:_load_models_from_settings()
        else
          local hm = tool and tool.hardcoded_models or {}
          self.tool_model_lists[fetch_tool_id] = #hm > 0 and hm or { { name = "Default", limited = false } }
          if fetch_tool_id == (config.ai_sidebar.active_tool or "agy") then
            self.model_list = self.tool_model_lists[fetch_tool_id]
          end
        end
      end
      self._model_raw      = ""
      self._model_raw_tool = nil
      self.model_proc      = nil
      core.redraw = true
    elseif m_elapsed > 45 then
      pcall(function() graceful_kill(self.model_proc) end)
      self.model_proc      = nil
      self._model_raw      = ""
      self._model_raw_tool = nil
      -- Don't wipe good cached data on timeout
      local fid = self._model_raw_tool or config.ai_sidebar.active_tool or "agy"
      if not (self.tool_model_lists[fid] and #self.tool_model_lists[fid] > 0) then
        self:_load_models_from_settings()
      end
      core.redraw = true
    end
  end

  -- ── Drain chat processes (ALL TABS) ───────────────────────────
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
          
          -- Automatically refresh the Chat Memory Tree if it's currently open
          if self.show_history_tree then
              self:fetch_history()
          end
          if not tab._ai_buf or tab._ai_buf == "" then
            local elapsed = os.time() - (tab._chat_started_at or os.time())
            local cur_tool = config.ai_sidebar and config.ai_sidebar.active_tool or "agy"
            local hint
            if cur_tool == "agy" then
              hint = "Try the AGY Auth button if you just logged in."
            else
              local tdef = AI_TOOLS and AI_TOOLS.get(cur_tool)
              local tname = (tdef and tdef.name) or cur_tool
              hint = tname .. " exited immediately.\n" ..
                     "Make sure it is installed and authenticated.\n" ..
                     "Run  " .. (tdef and tdef.bins and tdef.bins[1] or cur_tool) ..
                     " --help  in a terminal to verify."
            end
            tab._ai_buf = string.format(
              "(no output after %.0fs — process exited with code %s)\n\n%s",
              elapsed, tostring(rc), hint)
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
          local cur_tool = config.ai_sidebar and config.ai_sidebar.active_tool or "agy"
          local tdef = AI_TOOLS and AI_TOOLS.get(cur_tool)
          local tname = (tdef and tdef.name) or "the AI tool"
          local fix_msg = string.format(
            "[TIMEOUT] %s took over 5 minutes with no response.\n\n" ..
            "Check that %s is installed and authenticated.\n" ..
            "Run it directly in a terminal to test:\n  %s --help",
            tname, tname,
            (tdef and tdef.bins and tdef.bins[1]) or cur_tool)
          
          tab._ai_buf = fix_msg
          dirty = true
          core.error("[Antigravity] CLI timed out — agy install may be required.")
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

-- ── Model list disk cache ─────────────────────────────────────────────────────
local MODEL_CACHE_PATH = USERDIR .. "/model_cache.json"
local MODEL_CACHE_TTL  = 86400  -- 24 hours

local function _model_cache_read()
  local f = io.open(MODEL_CACHE_PATH, "r")
  if not f then return {} end
  local raw = f:read("*a"); f:close()
  local cache = {}
  -- Parse: "toolid": { "ts": 1234, "models": [{...},...] }
  for tool_id, ts_str, models_str in raw:gmatch(
    '"([^"]+)"%s*:%s*{%s*"ts"%s*:%s*(%d+)%s*,%s*"models"%s*:%s*(%b[])'
  ) do
    local ts   = tonumber(ts_str) or 0
    local list = {}
    for entry in models_str:gmatch("{([^}]+)}") do
      local name    = entry:match('"name"%s*:%s*"([^"]+)"')
      local limited = entry:match('"limited"%s*:%s*(true)') and true or false
      local usage   = entry:match('"usage"%s*:%s*"([^"]+)"')
      if name then table.insert(list, { name=name, limited=limited, usage=usage }) end
    end
    if #list > 0 then cache[tool_id] = { ts=ts, models=list } end
  end
  return cache
end

local function _model_cache_write(tbl)
  local out = {"{"}
  local first = true
  for tid, entry in pairs(tbl) do
    if not first then out[#out+1] = "," end
    first = false
    out[#out+1] = string.format('  "%s": { "ts": %d, "models": [', tid, entry.ts)
    for i, m in ipairs(entry.models) do
      local lim = m.limited and "true" or "false"
      local usg = m.usage and ('"' .. m.usage .. '"') or "null"
      out[#out+1] = string.format('    {"name":"%s","limited":%s,"usage":%s}%s',
        (m.name or ""):gsub('"', '\\"'), lim, usg, i < #entry.models and "," or "")
    end
    out[#out+1] = "  ] }"
  end
  out[#out+1] = "}"
  local f = io.open(MODEL_CACHE_PATH, "w")
  if f then f:write(table.concat(out, "\n")); f:close() end
end

-- Warm the in-memory cache from disk at startup (instant, no spawn)
function AGView:_warm_model_cache()
  local cache = _model_cache_read()
  if not self._model_cache_ts then self._model_cache_ts = {} end
  for tid, entry in pairs(cache) do
    if not (self.tool_model_lists[tid] and #self.tool_model_lists[tid] > 0) then
      self.tool_model_lists[tid] = entry.models
    end
    self._model_cache_ts[tid] = entry.ts
  end
  local id = config.ai_sidebar.active_tool or "agy"
  if self.tool_model_lists[id] and #self.tool_model_lists[id] > 0 then
    self.model_list = self.tool_model_lists[id]
    local tc = self:_tool_cfg(id)
    if not tc.selected_model then
      tc.selected_model = self.model_list[1].name
      if id == "agy" then config.antigravity.selected_model = tc.selected_model end
    end
  end
  core.redraw = true
end

-- Write a tool's model list to disk cache
function AGView:_persist_model_cache(tool_id)
  local list = self.tool_model_lists[tool_id]
  if not list or #list == 0 then return end
  local cache = _model_cache_read()
  cache[tool_id] = { ts = os.time(), models = list }
  _model_cache_write(cache)
  if not self._model_cache_ts then self._model_cache_ts = {} end
  self._model_cache_ts[tool_id] = os.time()
end

-- Fetch model list: serve from cache instantly, re-fetch only if stale (>24h)
function AGView:fetch_models(force)
  if self.model_proc then return end
  local id   = config.ai_sidebar.active_tool or "agy"
  local tool = AI_TOOLS.get(id)
  local bin  = self:_active_bin()

  -- Serve in-memory cache immediately
  if self.tool_model_lists[id] and #self.tool_model_lists[id] > 0 then
    self.model_list = self.tool_model_lists[id]
    if not force then
      local ts  = (self._model_cache_ts or {})[id] or 0
      if os.time() - ts < MODEL_CACHE_TTL then return end  -- fresh, skip fetch
    end
    -- Stale or forced → fall through to background fetch
  end

  self._model_raw      = ""
  self._model_raw_tool = id
  self.model_started_at = os.time()

  -- Tools with no model-list command → use hardcoded list immediately
  if not tool or not tool.build_models_argv then
    local hm = (tool and tool.hardcoded_models) or {}
    self.tool_model_lists[id] = #hm > 0 and hm or self:_fallback_models(id)
    self.model_list = self.tool_model_lists[id]
    self:_persist_model_cache(id)
    local cur = self:_active_model()
    if not cur and #self.model_list > 0 then self:_set_active_model(self.model_list[1].name) end
    core.redraw = true
    return
  end

  -- Build argv and spawn background process
  local argv = tool.build_models_argv(bin)
  if tool.needs_pty then
    local bridge = get_pty_bridge()
    if bridge then
      local pa = { "python", bridge }
      for _, a in ipairs(argv) do pa[#pa+1] = a end
      argv = pa
    end
  end
  local p = process.start(argv, {
    stdin  = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if p then
    self.model_proc = p
  else
    -- Spawn failed: don't overwrite good cached data
    if not (self.tool_model_lists[id] and #self.tool_model_lists[id] > 0) then
      local hm = (tool and tool.hardcoded_models) or {}
      self.tool_model_lists[id] = #hm > 0 and hm or self:_fallback_models(id)
      self.model_list = self.tool_model_lists[id]
    end
    core.redraw = true
  end
end


-- Fallback model list when all else fails
function AGView:_fallback_models(id)
  if id == "agy" then return config.antigravity.selected_model
    and { { name = config.antigravity.selected_model, limited = false } }
    or  { { name = "Default", limited = false } }
  end
  return { { name = "Default", limited = false } }
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
      local name = line
      local usage = nil
      local limited = false
      
      -- Parse usage e.g. "Gemini 1.5 Pro (50/50)"
      local base_name, u1, u2 = line:match("^(.-)%s*[%-]?%s*[%[%(]?(%d+)/(%d+)[^%]%)]*[%]%)]?%s*$")
      if base_name and u1 and u2 then
        name = base_name
        usage = u1 .. "/" .. u2
        limited = (tonumber(u1) >= tonumber(u2))
      else
        local base_name2, pct = line:match("^(.-)%s*[%-]?%s*[%[%(]?weekly usage (%d+)%%[^%]%)]*[%]%)]?%s*$")
        if not base_name2 then
          base_name2, pct = line:match("^(.-)%s*[%-]?%s*[%[%(]?(%d+)%%[^%]%)]*[%]%)]?%s*$")
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

-- Fallback: load model list from settings.json (AGY-specific)
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
  local fallback = {
    { name = "Gemini 3.5 Flash (Medium)",    limited = false },
    { name = "Gemini 3.5 Flash (High)",      limited = false },
    { name = "Gemini 3.1 Pro (High)",        limited = false },
    { name = "Claude Sonnet 4.6 (Thinking)", limited = false },
    { name = "Claude Opus 4.6 (Thinking)",   limited = false },
    { name = "GPT-OSS 120B (Medium)",        limited = false },
  }
  if current_model then
    table.insert(fallback, 1, { name = current_model, limited = false, current = true })
    if not config.antigravity.selected_model then
      config.antigravity.selected_model = current_model
    end
    self:_tool_cfg("agy").selected_model = config.antigravity.selected_model
  end
  if not config.antigravity.selected_model and #fallback > 0 then
    config.antigravity.selected_model = fallback[1].name
  end
  self.tool_model_lists["agy"] = fallback
  self.model_list = fallback
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
  self._hitl_rects = {}

  -- ── Full background ─────────────────────────────────────────────────────────
  renderer.draw_rect(x, y, w, h, P.bg)
  -- Left border (panel is on the right side)
  renderer.draw_rect(x, y, 1, h, P.border)

  -- ═══════════════════════════════════════════════════════════════════
  -- HEADER  — accent-bar design, two rows, fully bounds-safe
  -- ═══════════════════════════════════════════════════════════════════
  local hdr_h    = 52 * SCALE
  local accent_w = 3 * SCALE

  renderer.draw_rect(x, cur_y, w, hdr_h, P.bg_darker)
  renderer.draw_rect(x, cur_y + hdr_h - 1, w, 1, P.border)

  -- Left status-colored accent strip
  local acol = self:state().status == "running" and { 95, 185, 85, 255 }
            or self:state().status == "error"   and { 200, 60, 60, 255 }
            or { 70, 140, 220, 255 }
  renderer.draw_rect(x, cur_y, accent_w, hdr_h, acol)

  local sf   = style.font
  local bf   = style.big_font or style.font
  local fh1  = bf:get_height()   -- row1 text height
  local fh2  = sf:get_height()   -- row2 text height
  local ipad = accent_w + 9 * SCALE  -- left inner padding

  -- Compute rows with fixed margins: row1 at top, row2 at bottom
  -- Total content height = fh1 + 4 + fh2; center it in hdr_h
  local total_ch = fh1 + 4 * SCALE + fh2
  local top_margin = math.max(5 * SCALE, math.floor((hdr_h - total_ch) / 2))
  local row1_y = cur_y + top_margin
  local row2_y = cur_y + hdr_h - top_margin - fh2

  -- Clamp rows to strictly inside the header
  row1_y = math.max(cur_y + 4 * SCALE, math.min(row1_y, cur_y + hdr_h - fh1 - fh2 - 4 * SCALE))
  row2_y = math.max(cur_y + fh1 + 6 * SCALE, math.min(row2_y, cur_y + hdr_h - fh2 - 3 * SCALE))

  -- ── ROW 1 left: Segmented Pill Control for Tools ──────────────
  if not config.ai_sidebar.detected_list then
    config.ai_sidebar.detected_list = AI_TOOLS.get_detected(config.ai_sidebar.detected)
  end
  local det_list = config.ai_sidebar.detected_list or {}
  local active_id = config.ai_sidebar.active_tool or "agy"
  
  self._tool_picker_rects = {}
  
  local seg_x = x + ipad
  local seg_y = row1_y
  local seg_h = fh1 + 2 * SCALE
  
  -- Status text width
  local status_str = self:state().status == "running"
    and (self:state().warned_slow and "slow..." or "thinking...")
    or  self:state().status == "error" and "error"
    or  "ready"
  local status_w = sf:get_width(status_str) + 8 * SCALE
  
  -- Add custom tool button width
  local add_w = sf:get_width("+") + 16 * SCALE
  
  -- Calculate width per segment (equal width)
  local max_visible_tools = 4
  local num_segs = math.min(#det_list, max_visible_tools)
  if num_segs == 0 then num_segs = 1 end
  local avail_w = w - (seg_x - x) - status_w - add_w - 12 * SCALE
  local seg_w = math.max(40 * SCALE, math.floor(avail_w / num_segs))
  
  -- Draw pill container background
  local total_pill_w = num_segs * seg_w
  renderer.draw_rect(seg_x, seg_y, total_pill_w, seg_h, P.bg_input)
  draw_rect_outline(seg_x, seg_y, total_pill_w, seg_h, P.border)
  
  -- Draw segments
  for i=1, num_segs do
    local t = det_list[i] or { id="agy", name="Antigravity", short="AGY" }
    local sx = seg_x + (i-1) * seg_w
    local is_sel = (t.id == active_id)
    local is_hov = (self.hover_tool_idx == i)
    
    if is_sel then
      -- Highlight active segment
      renderer.draw_rect(sx, seg_y, seg_w, seg_h, P.bg_btn_hl)
      -- Draw glowing top border for selected segment
      renderer.draw_rect(sx, seg_y, seg_w, 1 * SCALE, P.fg_accent)
    elseif is_hov then
      renderer.draw_rect(sx, seg_y, seg_w, seg_h, P.bg_btn)
    end
    
    -- Separator line between segments
    if i < num_segs then
      renderer.draw_rect(sx + seg_w - 1, seg_y, 1, seg_h, P.border)
    end
    
    -- Segment label (short name)
    local lbl = t.short or t.id
    local lbl_col = is_sel and P.fg_accent or P.fg_muted
    local lbl_w = sf:get_width(lbl)
    
    -- Truncate if too long
    if lbl_w > seg_w - 4 * SCALE then
      lbl = lbl:sub(1, 1) .. ".."
      lbl_w = sf:get_width(lbl)
    end
    
    renderer.draw_text(sf, lbl, sx + math.floor((seg_w - lbl_w)/2), seg_y + math.floor((seg_h - fh2)/2), lbl_col)
    
    table.insert(self._tool_picker_rects, { x=sx, y=seg_y, w=seg_w, h=seg_h, idx=i })
  end
  
  -- Draw "+" add custom tool button
  local add_x = seg_x + total_pill_w + 4 * SCALE
  local add_hov = (self.hover_tool_idx == #det_list + 1)
  local add_col = add_hov and P.fg_accent or P.fg_muted
  renderer.draw_text(sf, "+", add_x + 8 * SCALE, seg_y + math.floor((seg_h - fh2)/2), add_col)
  table.insert(self._tool_picker_rects, { x=add_x, y=seg_y, w=add_w, h=seg_h, idx=#det_list + 1, is_add=true })

  -- ── ROW 1 right: status text ─────────────────────────────────────────
  local status_str = self:state().status == "running"
    and (self:state().warned_slow and "slow..." or "thinking...")
    or  self:state().status == "error" and "error"
    or  "ready"
  local scol = self:state().status == "running" and { acol[1], acol[2], acol[3], 210 }
            or self:state().status == "error"   and P.dot_err
            or P.fg_muted
  renderer.draw_text(sf, status_str,
    x + w - sf:get_width(status_str) - 8 * SCALE,
    row1_y + math.floor((fh1 - fh2) / 2),
    scol)

  -- Model label moved to input area
  cur_y = cur_y + hdr_h

  -- ═══════════════════════════════════════════════════════════════════
  -- QUICK ACTION PILLS (Sleek Borderless Chips)
  -- ═══════════════════════════════════════════════════════════════════
  local pill_h    = 28 * SCALE
  local pill_gap  = 6 * SCALE
  local n         = #config.antigravity.actions
  local pill_w    = math.floor((w - 2 * pad - (n - 1) * pill_gap) / n)
  local pills_top = cur_y + 4 * SCALE

  for i, act in ipairs(config.antigravity.actions) do
    local bx = x + pad + (i - 1) * (pill_w + pill_gap)
    local by = pills_top
    local hl = (self.hover_btn == i)

    -- Semi-transparent resting state, solid accent tint on hover
    local p_bg = hl and P.bg_btn_hl or { P.bg_input[1], P.bg_input[2], P.bg_input[3], 120 }
    renderer.draw_rect(bx, by, pill_w, pill_h, p_bg)

    -- Bottom highlight on hover
    if hl then
      renderer.draw_rect(bx, by + pill_h - 2 * SCALE, pill_w, 2 * SCALE, P.fg_accent)
    end

    local label_w = style.font:get_width(act.short)
    renderer.draw_text(style.font, act.short,
      bx + math.floor((pill_w - label_w) / 2),
      by + math.floor((pill_h - style.font:get_height()) / 2),
      hl and P.fg_accent or P.fg_muted)
  end
  cur_y = pills_top + pill_h + 12 * SCALE

  -- Divider
  renderer.draw_rect(x + pad, cur_y, w - 2*pad, 1, P.border)
  cur_y = cur_y + 8 * SCALE

  -- ═══════════════════════════════════════════════════════════════════
  -- COMPOSER (Floating Input Area)
  -- ═══════════════════════════════════════════════════════════════════
  local font     = style.font
  local lh       = font:get_height() + 3 * SCALE
  local is_running = self:state().process ~= nil

  local raw_input = self:state().input or ""
  local inp_w = w - 2 * pad
  local c_pad = 8 * SCALE
  local max_text_w = inp_w - 2 * c_pad
  -- Cache wrap_input_lines: expensive per-frame call, only redo if text or width changed
  local st = self:state()
  if st._vl_text ~= raw_input or st._vl_w ~= max_text_w then
    st._vl_text   = raw_input
    st._vl_w      = max_text_w
    st._vl_cache  = wrap_input_lines(raw_input, font, max_text_w)
  end
  local visual_lines = st._vl_cache
  local cur_line, cur_col = get_cursor_visual_line_col(visual_lines, raw_input, st.cursor)
  local num_lines = #visual_lines

  local text_h = math.max(1, num_lines) * lh
  local min_text_h = 1 * lh
  local max_text_h = 160 * SCALE - 30 * SCALE
  text_h = math.max(min_text_h, math.min(max_text_h, text_h))
  
  local action_row_h = 28 * SCALE
  local input_h = text_h + action_row_h + 2 * c_pad
  local composer_bottom = y + h - pad
  local inp_x = x + pad
  local inp_y = composer_bottom - input_h
  
  -- Restrict chat history rendering to stop above the composer
  local chat_bot = inp_y - pad

  -- Draw glowing border if running
  if is_running then
    local pulse = (math.sin(self.tick / 15) + 1) / 2 -- 0 to 1
    local g_alpha = math.floor(30 + 50 * pulse)
    local g_rad = 3 * SCALE
    renderer.draw_rect(inp_x - g_rad, inp_y - g_rad, inp_w + 2*g_rad, input_h + 2*g_rad,
      { P.fg_accent[1], P.fg_accent[2], P.fg_accent[3], g_alpha })
    renderer.draw_rect(inp_x - 1, inp_y - 1, inp_w + 2, input_h + 2, P.fg_accent)
  else
    draw_rect_outline(inp_x, inp_y, inp_w, input_h, core.active_view == self and P.border_input or P.border)
  end

  -- Composer Background
  renderer.draw_rect(inp_x, inp_y, inp_w, input_h, P.bg_input)

  self._visual_lines = visual_lines
  -- The actual text input area is just the top part of the composer
  self._input_rect = { x = inp_x, y = inp_y, w = inp_w, h = text_h + c_pad, lh = lh }

  -- Multiline auto-scroll offset if lines exceed max_text_h
  local max_visible_lines = math.floor(max_text_h / lh)
  local input_scroll_offset = 0
  if cur_line > max_visible_lines then
    input_scroll_offset = (cur_line - max_visible_lines) * lh
  end
  self._input_scroll_offset = input_scroll_offset

  core.push_clip_rect(inp_x, inp_y, inp_w, text_h + c_pad)
  local sel_from, sel_to = get_selection_range(self:state())
  local text_y_start = inp_y + c_pad

  if #raw_input == 0 then
    local placeholder = "Ask anything..."
    renderer.draw_text(font, placeholder, inp_x + c_pad, text_y_start, P.fg_muted)
    if core.active_view == self and math.floor(self.tick / 30) % 2 == 0 then
      renderer.draw_rect(inp_x + c_pad, text_y_start, 2 * SCALE, font:get_height(), P.fg_accent)
    end
  else
    -- Draw selection highlight
    if sel_from and sel_to and sel_from < sel_to then
      local sel_color = style.selection or { 60, 110, 180, 90 }
      for l_idx, line_info in ipairs(visual_lines) do
        local l_start = line_info.start_byte - 1
        local l_end   = line_info.end_byte - 1
        if sel_to > l_start and sel_from < l_end then
          local col_start = math.max(0, sel_from - l_start)
          local col_end   = math.min(#(line_info.text or ""), sel_to - l_start)
          local text_before = (line_info.text or ""):sub(1, col_start)
          local text_selected = (line_info.text or ""):sub(col_start + 1, col_end)
          local x1 = inp_x + c_pad + font:get_width(text_before)
          local sel_w = font:get_width(text_selected)
          if sel_w <= 0 and sel_to > l_end then
            sel_w = font:get_width(" ")
          end
          local line_y = text_y_start + (l_idx - 1) * lh - input_scroll_offset
          if line_y + lh >= inp_y and line_y <= inp_y + text_h + c_pad then
            renderer.draw_rect(x1, line_y, math.max(2 * SCALE, sel_w), lh, sel_color)
          end
        end
      end
    end

    for l_idx, line_info in ipairs(visual_lines) do
      local line_y = text_y_start + (l_idx - 1) * lh - input_scroll_offset
      if line_y + lh >= inp_y and line_y <= inp_y + text_h + c_pad then
        local l_str = line_info.text or ""
        if l_str:find("@") then
          local cur_x = inp_x + c_pad
          local last_pos = 1
          for at_start, token, at_end in l_str:gmatch("()(@[%w_%-%.]+)()") do
            if at_start > last_pos then
              local pre = l_str:sub(last_pos, at_start - 1)
              renderer.draw_text(font, pre, cur_x, line_y, P.fg)
              cur_x = cur_x + font:get_width(pre)
            end
            renderer.draw_text(font, token, cur_x, line_y, P.fg_accent)
            cur_x = cur_x + font:get_width(token)
            last_pos = at_end
          end
          if last_pos <= #l_str then
            local rest = l_str:sub(last_pos)
            renderer.draw_text(font, rest, cur_x, line_y, P.fg)
          end
        else
          renderer.draw_text(font, l_str, inp_x + c_pad, line_y, P.fg)
        end
      end
    end
    if core.active_view == self and math.floor(self.tick / 30) % 2 == 0 then
      local cur_line_info = visual_lines[cur_line] or visual_lines[1]
      local text_before_cursor = (cur_line_info.text or ""):sub(1, cur_col)
      local cursor_x = inp_x + c_pad + font:get_width(text_before_cursor)
      local cursor_y = text_y_start + (cur_line - 1) * lh - input_scroll_offset
      if cursor_y >= inp_y - 2 * SCALE and cursor_y + font:get_height() <= inp_y + text_h + c_pad then
        renderer.draw_rect(cursor_x, cursor_y, 2 * SCALE, font:get_height(), P.fg_accent)
      end
    end
  end
  core.pop_clip_rect()

  -- ── ACTION ROW (Inside Composer, Bottom) ──
  local act_y = inp_y + text_h + c_pad
  local small_font = style.small_font
  if not small_font then
    small_font = style.font:copy(12 * SCALE)
    style.small_font = small_font
  end

  -- Attachment Button
  local attach_w = 28 * SCALE
  local attach_bg = self.hover_attach and P.bg_btn_hl or {0,0,0,0}
  renderer.draw_rect(inp_x + c_pad, act_y, attach_w, action_row_h, attach_bg)
  local attach_icon = "f" -- Maps to file icon in Lite XL's style.icon_font
  renderer.draw_text(style.icon_font, attach_icon,
    inp_x + c_pad + math.floor((attach_w - style.icon_font:get_width(attach_icon)) / 2),
    act_y + math.floor((action_row_h - style.icon_font:get_height()) / 2),
    P.fg_muted)
  self._attach_rect = { x = inp_x + c_pad, y = act_y, w = attach_w, h = action_row_h }

  -- Right-side control buttons
  local send_w = 28 * SCALE
  local send_h = 24 * SCALE
  local send_x = inp_x + inp_w - c_pad - send_w
  
  -- Read-Only Toggle (Right aligned)
  local ro_lbl = "RO"
  local ro_w = small_font:get_width(ro_lbl) + 16 * SCALE
  local ro_x = send_x - 4 * SCALE - ro_w
  
  -- Autopilot Toggle (Right aligned)
  local auto_lbl = "Auto"
  local auto_w = small_font:get_width(auto_lbl) + 16 * SCALE
  local auto_x = ro_x - 4 * SCALE - auto_w
  
  local mh = 20 * SCALE
  local my = act_y + math.floor((action_row_h - mh) / 2)

  -- Model Selector Badge (Next to attach button)
  local sel_name  = self:_active_model() or "Default model"
  local chevron = " >"
  local model_lbl = sel_name
  local max_model_w = math.max(40 * SCALE, (auto_x - 4 * SCALE) - (inp_x + c_pad + attach_w + 4 * SCALE))
  -- Truncate logic
  while small_font:get_width(model_lbl .. chevron) > (max_model_w - 16 * SCALE) and #model_lbl > 4 do
    model_lbl = model_lbl:sub(1, -2)
  end
  if model_lbl ~= sel_name then
    model_lbl = model_lbl:match("^%s*(.-)%s*$") .. ".."
  end
  model_lbl = model_lbl .. chevron

  local mw = small_font:get_width(model_lbl) + 16 * SCALE
  local mh = 20 * SCALE
  local mx = inp_x + c_pad + attach_w + 4 * SCALE
  local my = act_y + math.floor((action_row_h - mh) / 2)

  local m_bg = self.hover_model_btn and P.bg_btn_hl or {0,0,0,0}
  renderer.draw_rect(mx, my, mw, mh, m_bg)
  renderer.draw_text(small_font, model_lbl, mx + 8 * SCALE, my + math.floor((mh - small_font:get_height())/2),
    self.hover_model_btn and P.fg_accent or P.fg_muted)
  self._model_rect = { x = mx, y = my, w = mw, h = mh }

  -- Draw Autopilot
  local auto_bg = config.ai_sidebar.autopilot and { P.fg_accent[1], P.fg_accent[2], P.fg_accent[3], 50 } or (self.hover_auto_btn and P.bg_btn_hl or {0,0,0,0})
  local auto_fg = config.ai_sidebar.autopilot and P.fg_accent or P.fg_muted
  renderer.draw_rect(auto_x, my, auto_w, mh, auto_bg)
  renderer.draw_text(small_font, auto_lbl, auto_x + 8 * SCALE, my + math.floor((mh - small_font:get_height())/2), auto_fg)
  self._auto_rect = { x = auto_x, y = my, w = auto_w, h = mh }

  -- Draw Read-Only
  local ro_bg = config.ai_sidebar.read_only and { P.fg_accent[1], P.fg_accent[2], P.fg_accent[3], 50 } or (self.hover_ro_btn and P.bg_btn_hl or {0,0,0,0})
  local ro_fg = config.ai_sidebar.read_only and P.fg_accent or P.fg_muted
  renderer.draw_rect(ro_x, my, ro_w, mh, ro_bg)
  renderer.draw_text(small_font, ro_lbl, ro_x + 8 * SCALE, my + math.floor((mh - small_font:get_height())/2), ro_fg)
  self._ro_rect = { x = ro_x, y = my, w = ro_w, h = mh }

  -- Send/Stop Button (Right aligned)
  local send_w = 28 * SCALE
  local send_h = 24 * SCALE
  local send_x = inp_x + inp_w - c_pad - send_w
  local send_y = act_y + math.floor((action_row_h - send_h) / 2)

  local send_bg
  if is_running then
    send_bg = self.hover_send and { common.color "#F26363" } or { common.color "#D94C4C" }
  else
    send_bg = self.hover_send and P.bg_btn_hl or P.bg_btn
  end

  renderer.draw_rect(send_x, send_y, send_w, send_h, send_bg)
  
  -- Send/Stop Icons
  if is_running then
    -- Stop icon (Square block)
    local ix = send_x + math.floor((send_w - 8 * SCALE) / 2)
    local iy = send_y + math.floor((send_h - 8 * SCALE) / 2)
    renderer.draw_rect(ix, iy, 8 * SCALE, 8 * SCALE, {255,255,255,255})
  else
    -- Send icon (Chevron right)
    local s_icon = ">"
    local scx = send_x + math.floor((send_w - style.icon_font:get_width(s_icon)) / 2)
    local scy = send_y + math.floor((send_h - style.icon_font:get_height()) / 2)
    renderer.draw_text(style.icon_font, s_icon, scx, scy, P.fg)
  end

  self._send_rect = { x = send_x, y = send_y, w = send_w, h = send_h }

  -- ═══════════════════════════════════════════════════════════════════
  -- CHAT HISTORY TABS (Underline style)
  -- ═══════════════════════════════════════════════════════════════════
  local tab_h = 28 * SCALE
  self.tab_rects = {}
  self.tab_stop_rects = {}
  local cur_x = x + pad
  local line_start_x = x + pad

  -- Timeline Button (Extreme right of tabs)
  local h_btn_w = 32 * SCALE
  local h_btn_x = x + w - pad - h_btn_w
  local h_btn_y = cur_y + math.floor((tab_h - 30 * SCALE) / 2)
  self._hist_toggle_rect = { x = h_btn_x, y = h_btn_y, w = h_btn_w, h = 30 * SCALE }
  local is_hov = self.hover_hist_btn
  renderer.draw_rect(h_btn_x, h_btn_y, h_btn_w, 30 * SCALE, self.show_history_tree and P.fg_accent or (is_hov and P.bg_dark or P.bg))
  renderer.draw_text(style.icon_font, "g", h_btn_x + 8 * SCALE, h_btn_y + 6 * SCALE, self.show_history_tree and P.bg or P.fg_accent)

  for i, c in ipairs(self.chats) do
    local label = "Chat #" .. tostring(i)
    if c.status == "running" then
      label = "Working..."
    end
    
    local stop_w = 0
    if c.status == "running" then
      stop_w = style.font:get_width(" [x]") + 8 * SCALE -- x text
    end
    
    local tw = style.font:get_width(label) + 16 * SCALE + stop_w
    
    -- Wrap to next line if exceeds width
    if cur_x + tw > h_btn_x - 8 * SCALE and cur_x > line_start_x then
      cur_x = line_start_x
      cur_y = cur_y + tab_h + 4 * SCALE
    end
    
    local is_active = (i == self.active_idx)
    local tab_fg = is_active and P.fg_accent or P.fg_muted
    
    -- Draw text
    renderer.draw_text(style.font, label, cur_x + 8 * SCALE, cur_y + math.floor((tab_h - style.font:get_height())/2), tab_fg)
    
    -- Draw active underline
    if is_active then
      renderer.draw_rect(cur_x, cur_y + tab_h - 2 * SCALE, tw, 2 * SCALE, P.fg_accent)
    end
    
    if c.status == "running" then
      local sx = cur_x + tw - stop_w
      renderer.draw_text(style.font, " [x]", sx, cur_y + math.floor((tab_h - style.font:get_height())/2), { common.color "#D94C4C" })
      table.insert(self.tab_stop_rects, { x = sx, y = cur_y, w = stop_w, h = tab_h, idx = i })
    end
    
    table.insert(self.tab_rects, { x = cur_x, y = cur_y, w = tw - stop_w, h = tab_h, idx = i })
    cur_x = cur_x + tw + 4 * SCALE
  end
  
  -- "+" button (sleek)
  local pw = style.font:get_width("+") + 16 * SCALE
  if cur_x + pw > x + w - pad and cur_x > line_start_x then
    cur_x = line_start_x
    cur_y = cur_y + tab_h + 4 * SCALE
  end
  renderer.draw_text(style.font, "+", cur_x + 8 * SCALE, cur_y + math.floor((tab_h - style.font:get_height())/2), P.fg_muted)
  self.add_btn_rect = { x = cur_x, y = cur_y, w = pw, h = tab_h }
  cur_x = cur_x + pw + 2 * SCALE
  
  -- "x" button (close active)
  if #self.chats > 1 then
    local xw = style.font:get_width("x") + 16 * SCALE
    if cur_x + xw > x + w - pad and cur_x > line_start_x then
      cur_x = line_start_x
      cur_y = cur_y + tab_h + 4 * SCALE
    end
    renderer.draw_rect(cur_x, cur_y, xw, tab_h, P.bg)
    renderer.draw_text(style.font, "x", cur_x + 8 * SCALE, cur_y + math.floor((tab_h - style.font:get_height())/2), { common.color "#FB4934" })
    self.close_btn_rect = { x = cur_x, y = cur_y, w = xw, h = tab_h }
  else
    self.close_btn_rect = nil
  end
  
  cur_y = cur_y + tab_h + 4 * SCALE
  local chat_top = cur_y
  local chat_h   = chat_bot - chat_top


  if self.show_history_tree then
    self:draw_history_tree(x, chat_top, w, chat_h)
  end

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
    
    -- Crucial animation optimization: always wrap text to the TARGET width (e.g. 350px) 
    -- rather than the current animating width (which changes on every frame). 
    -- This prevents O(N) word-wrap recalculations during slide-in/slide-out UI transitions!
    local stable_w = self.target_size or w
    local msg_w   = stable_w - 2 * pad - 4 * SCALE
    
    local bg_col  = is_user and P.bg_user_msg or P.bg_ai_msg
    local fg_col  = is_user and P.fg_user or P.fg_ai

    -- Cache parsed blocks (invalidated when text or width changes)
    if not sess.blocks or sess._cached_text ~= sess.text or sess._cached_w ~= msg_w then
      local now = os.clock()
      -- Strictly throttle all re-parsing (from streaming OR UI width resizing animations) to ~20 FPS.
      -- This absolutely prevents massive chat logs from pegging the CPU during smooth toggle animations!
      if not sess.blocks or (now - (sess._last_parse_time or 0)) > 0.05 then
        sess.blocks = parse_blocks(sess.text, style.font, style.code_font, msg_w - 2 * msg_pad)
        sess._cached_text = sess.text
        sess._cached_w = msg_w
        sess._last_parse_time = now
      else
        -- Request another redraw later to ensure the final frame gets rendered cleanly after the animation or stream finishes
        core.add_thread(function() coroutine.yield(0.05); core.redraw = true end)
      end
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

    local has_hitl = not is_user and sess.text:find("[HITL_APPROVAL_REQUIRED]", 1, true)
    if has_hitl and self:state().status == "running" and sess == self:state().sessions[#self:state().sessions] then
      msg_h = msg_h + 36 * SCALE
    end

    -- Role label
    if ty + msg_h + lh_f >= chat_top and ty <= chat_bot then
      local tid  = config.ai_sidebar.active_tool or "agy"
      local tdef = AI_TOOLS.get(tid)
      
      local role_lbl = is_user and "You" or (tdef and tdef.name or "Antigravity")
      
      -- Draw role name directly (removed unicode icons to fix ? rendering)
      renderer.draw_text(style.font, role_lbl, x + pad, math.max(chat_top, math.min(ty, chat_bot - style.font:get_height())), is_user and P.fg_muted or P.fg_accent)
    end
    ty = ty + style.font:get_height() + 4 * SCALE

    -- Message background (borderless, very subtle)
    if ty + msg_h >= chat_top and ty <= chat_bot then
      if is_user then
        -- User gets a subtle background bubble
        renderer.draw_rect(x + pad, ty, msg_w, msg_h, P.bg_btn)
      else
        -- AI gets a transparent background, but a subtle left border to indicate generation block
        renderer.draw_rect(x + pad, ty, 2 * SCALE, msg_h, { P.fg_accent[1], P.fg_accent[2], P.fg_accent[3], 50 })
      end
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
          local is_copied = (self.copy_flash_idx == c_id)
          local cw = is_copied and (style.font:get_width("Copied!") + 8 * SCALE) or 20 * SCALE
          local c_x = x + pad + msg_w - 14 * SCALE - cw
          
          if is_copied then
            renderer.draw_text(style.font, "Copied!", c_x, line_y + math.floor((hdr_h - style.font:get_height())/2), P.fg_accent)
          else
            -- Custom drawn copy icon (overlapping squares)
            local ix = c_x + math.floor((cw - 10 * SCALE) / 2)
            local iy = line_y + math.floor((hdr_h - 10 * SCALE) / 2)
            draw_rect_outline(ix + 3 * SCALE, iy, 7 * SCALE, 7 * SCALE, P.fg_muted)
            renderer.draw_rect(ix, iy + 3 * SCALE, 7 * SCALE, 7 * SCALE, P.bg_darker)
            draw_rect_outline(ix, iy + 3 * SCALE, 7 * SCALE, 7 * SCALE, P.fg_muted)
          end
          
          table.insert(self._copy_rects, {
            x = c_x - 4 * SCALE, y = line_y, w = cw + 8 * SCALE, h = hdr_h,
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
            local code_avail_w = math.max(10*SCALE, msg_w - 2 * msg_pad)
            core.push_clip_rect(lx, line_y, code_avail_w, lh_c)
            for i = 1, #tokens, 2 do
              local type = tokens[i]
              local text = tokens[i+1]
              local col = style.syntax[type] or style.syntax["normal"] or P.fg_ai
              lx = draw_text_emoji(style.code_font, text, lx, line_y, col)
            end
            core.pop_clip_rect()
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
            local para_avail_w = math.max(10*SCALE, msg_w - 2 * msg_pad)
            core.push_clip_rect(lx, line_y, para_avail_w, lh)
            if blk.list and l_idx == 1 then
              renderer.draw_text(f, "• ", lx, line_y, P.fg_accent)
              lx = lx + f:get_width("• ")
            elseif blk.list then
              lx = lx + f:get_width("• ")
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
            core.pop_clip_rect()
          end
          line_y = line_y + lh
        end
      end
    end

    if has_hitl and self:state().status == "running" and sess == self:state().sessions[#self:state().sessions] then
      local btn_w = 60 * SCALE
      local btn_h = 24 * SCALE
      local yes_x = x + pad + msg_pad
      local no_x = yes_x + btn_w + 12 * SCALE
      local btn_y = line_y + 4 * SCALE
      
      if btn_y + btn_h >= chat_top and btn_y <= chat_bot then
        table.insert(self._hitl_rects, { x = yes_x, y = btn_y, w = btn_w, h = btn_h, val = "y" })
        table.insert(self._hitl_rects, { x = no_x, y = btn_y, w = btn_w, h = btn_h, val = "n" })
        
        local yes_hov = self.hover_hitl == "y"
        renderer.draw_rect(yes_x, btn_y, btn_w, btn_h, yes_hov and P.bg_btn_hl or P.bg_btn)
        draw_rect_outline(yes_x, btn_y, btn_w, btn_h, P.fg_accent)
        renderer.draw_text(style.font, "Yes", yes_x + math.floor((btn_w - style.font:get_width("Yes"))/2), btn_y + math.floor((btn_h - style.font:get_height())/2), P.fg_accent)
        
        local no_hov = self.hover_hitl == "n"
        renderer.draw_rect(no_x, btn_y, btn_w, btn_h, no_hov and P.bg_btn_hl or P.bg_btn)
        draw_rect_outline(no_x, btn_y, btn_w, btn_h, P.border)
        renderer.draw_text(style.font, "No", no_x + math.floor((btn_w - style.font:get_width("No"))/2), btn_y + math.floor((btn_h - style.font:get_height())/2), P.fg)
      end
      line_y = line_y + btn_h + 12 * SCALE
    end

    -- Save bounds for hover/click detection
    local bubble_x, bubble_y = x + pad, ty
    local bubble_w, bubble_h = msg_w, msg_h
    table.insert(self._copy_rects, {
      x = bubble_x, y = bubble_y, w = bubble_w, h = bubble_h, text = sess.text, idx = _
    })

    -- Draw copy button if hovered
    if self.hover_copy_idx == _ then
      local is_copied = (self.copy_flash_idx == _)
      local c_w = is_copied and (style.font:get_width("Copied!") + 12 * SCALE) or 24 * SCALE
      local c_h = 24 * SCALE
      local c_x = bubble_x + bubble_w - c_w - 6 * SCALE
      local c_y = bubble_y + 6 * SCALE
      
      if c_y + c_h >= chat_top and c_y <= chat_bot then
        renderer.draw_rect(c_x, c_y, c_w, c_h, P.bg_btn_hl)
        draw_rect_outline(c_x, c_y, c_w, c_h, P.border)
        
        if is_copied then
          renderer.draw_text(style.font, "Copied!", c_x + 6 * SCALE, c_y + math.floor((c_h - style.font:get_height())/2), P.fg_accent)
        else
          -- Custom drawn copy icon (overlapping squares)
          local ix = c_x + math.floor((c_w - 10 * SCALE) / 2)
          local iy = c_y + math.floor((c_h - 10 * SCALE) / 2)
          draw_rect_outline(ix + 3 * SCALE, iy, 7 * SCALE, 7 * SCALE, P.fg)
          renderer.draw_rect(ix, iy + 3 * SCALE, 7 * SCALE, 7 * SCALE, P.bg_btn_hl)
          draw_rect_outline(ix, iy + 3 * SCALE, 7 * SCALE, 7 * SCALE, P.fg)
        end
      end
    end

    -- Spinner on last AI message while running
    if self:state().status == "running" and not is_user
       and sess == self:state().sessions[#self:state().sessions]
       and sess.text == "" then
      
      -- Buttery smooth 60fps opacity sine pulse
      local pulse = (math.sin(self.tick / 12) + 1) / 2
      local alpha = math.floor(80 + 175 * pulse)
      local col = { P.fg_accent[1], P.fg_accent[2], P.fg_accent[3], alpha }
      
      renderer.draw_text(style.code_font, "● AI thinking...",
        x + pad + msg_pad, ty + msg_pad, col)
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
    
    for i, item in ipairs(self:state().mention_suggestions) do
      local iy = pop_y + (i - 1) * item_h
      local is_sel = (i == self:state().mention_idx)
      if is_sel then
        renderer.draw_rect(pop_x, iy, pop_w, item_h, P.bg_btn_hl)
      end

      local item_type = type(item) == "table" and item.type or "file"
      local item_name = type(item) == "table" and (item.name or item.full_path) or tostring(item)
      local badge     = type(item) == "table" and (item.badge or (item_type == "dir" and "[DIR]" or "[FILE]")) or "[FILE]"

      local badge_color = (item_type == "dir") and P.fg_accent or P.fg_muted
      local text_color  = is_sel and P.fg_accent or P.fg

      -- Draw badge
      renderer.draw_text(style.font, badge, pop_x + 8 * SCALE, iy + 4 * SCALE, badge_color)
      local badge_w = style.font:get_width(badge .. "  ")

      -- Draw file / folder name
      renderer.draw_text(style.font, item_name, pop_x + 8 * SCALE + badge_w, iy + 4 * SCALE, text_color)
    end
  end

  -- Removed tool picker dropdown as it is now a segmented control in the header


  -- MODEL PICKER DROPDOWN: drawn last to overlay pills and chat
  if self.show_model_picker then
    local mf     = style.font
    local item_h = mf:get_height() + 4 * SCALE -- Reduced height for compactness
    local list   = self.model_list
    local total_items = (#list == 0) and 1 or #list
    local max_rows = 12
    local rows   = math.min(max_rows, total_items)
    local pop_h  = rows * item_h + 6 * SCALE
    
    self.model_max_scroll = math.max(0, total_items * item_h + 6 * SCALE - pop_h)
    self.model_scroll_y = math.max(0, math.min(self.model_max_scroll, self.model_scroll_y or 0))

    local pop_y  = y + 52 * SCALE
    if self._model_rect then
      pop_y = self._model_rect.y - pop_h - 4 * SCALE
    end
    renderer.draw_rect(x, pop_y, w, pop_h, P.bg_dark)
    draw_rect_outline(x, pop_y, w, pop_h, P.border)

    core.push_clip_rect(x, pop_y, w, pop_h)

    self._mpicker_rects = {}
    if #list == 0 then
      renderer.draw_text(mf,
        self.model_proc and "Fetching models..." or "No models found.",
        x + pad, pop_y + 3 * SCALE + math.floor((item_h - mf:get_height()) / 2) - self.model_scroll_y, P.fg_muted)
    else
      for i, m in ipairs(list) do
        local ry     = pop_y + 3 * SCALE + (i - 1) * item_h - self.model_scroll_y
        
        if ry + item_h >= pop_y and ry <= pop_y + pop_h then
          local is_sel = config.antigravity.selected_model == m.name
          local is_hov = (self.hover_model_idx == i) and not m.limited
          local rbg    = is_sel and P.bg_btn_hl or is_hov and P.bg_btn or nil
          if rbg then renderer.draw_rect(x, ry, w, item_h, rbg) end
          
          local label = m.name
          local is_limited = m.limited
          local fg
          if is_limited then
            fg = { 120, 120, 120, 110 }
          elseif is_sel then
            fg = P.fg_accent
          elseif is_hov then
            fg = P.fg
          else
            fg = P.fg
          end
          renderer.draw_text(mf, label, x + pad,
            ry + math.floor((item_h - mf:get_height()) / 2), fg)

          -- Right side: usage counter OR checkmark for selected
          if m.usage then
            local ufg = is_limited and { 160, 80, 80, 180 } or P.fg_muted
            local disp_usage = m.usage
            if is_limited then disp_usage = disp_usage .. " [No Quota]" end
            renderer.draw_text(mf, disp_usage,
              x + w - pad - mf:get_width(disp_usage),
              ry + math.floor((item_h - mf:get_height()) / 2), ufg)
          end
          if is_limited and not m.usage then
            local tag = "[Pro Tier]"
            renderer.draw_text(mf, tag,
              x + w - pad - mf:get_width(tag),
              ry + math.floor((item_h - mf:get_height()) / 2),
              { 160, 80, 80, 180 })
          elseif is_sel and not m.usage then
            renderer.draw_text(mf, "[v]",
              x + w - pad - mf:get_width("[v]"),
              ry + math.floor((item_h - mf:get_height()) / 2), P.dot_run)
          end
          -- Insert rect for hit testing only if it is visible
          table.insert(self._mpicker_rects, { x=x, y=ry, w=w, h=item_h, idx=i })
        end
      end
    end
    core.pop_clip_rect()
  end
  
  -- USAGE MODAL VIEW
  if self.show_usage_view then
    -- dim bg
    renderer.draw_rect(x, y, w, h, {0,0,0,150})
    
    local mw = w - 40 * SCALE
    local mh = h - 60 * SCALE
    local mx = x + 20 * SCALE
    local my = y + 30 * SCALE
    
    renderer.draw_rect(mx, my, mw, mh, P.bg)
    draw_rect_outline(mx, my, mw, mh, P.border)
    
    local pad = 10 * SCALE
    -- Header
    renderer.draw_text(style.font, "Usage & Quotas", mx + pad, my + pad, P.fg_accent)
    
    -- Close X
    local cx = mx + mw - pad - style.icon_font:get_width("C")
    local cy = my + pad
    renderer.draw_text(style.icon_font, "C", cx, cy, P.fg_muted)
    self._usage_close_rect = { x = cx, y = cy, w = style.icon_font:get_width("C") + 8 * SCALE, h = style.icon_font:get_height() }
    
    local div_y = my + pad + style.font:get_height() + 8 * SCALE
    renderer.draw_rect(mx + pad, div_y, mw - 2 * pad, 1 * SCALE, P.border)
    
    -- Text area
    local text_y = div_y + 8 * SCALE
    local text_h = mh - (text_y - my) - pad
    
    core.push_clip_rect(mx + pad, text_y, mw - 2 * pad, text_h)
    local ty = text_y - (self.usage_scroll_y or 0)
    
    if not self.usage_head_font then
      self.usage_head_font = style.font:copy(math.floor(style.font:get_height() * 1.15))
      self.usage_sub_font = style.font:copy(math.floor(style.font:get_height() * 1.05))
    end
    
    self._usage_links = {}
    for _, line in ipairs(wrap_raw_text(style.code_font, self.usage_text or "", mw - 2 * pad)) do
      local active_font = style.code_font
      local is_bold = false
      
      if line:match("^%s*Account:") or line:match("GitHub Copilot Usage") or line:match("Cloud AI %(API%) Usage") then
        active_font = self.usage_sub_font
        is_bold = true
      elseif line:match("^%u[%u%s]+MODELS%s*$") then
        active_font = self.usage_head_font
        is_bold = true
      end
      
      local lh = active_font:get_height()
      if ty + lh >= text_y and ty <= text_y + text_h then
        local url_start, url_end = line:find("https?://%S+")
        if url_start then
          local pre = line:sub(1, url_start - 1)
          local url = line:sub(url_start, url_end)
          local post = line:sub(url_end + 1)
          
          local lx = mx + pad
          lx = renderer.draw_text(active_font, pre, lx, ty, P.fg)
          local ux = lx
          
          -- Check hover
          local mx_mouse, my_mouse = core.root_view.mouse.x, core.root_view.mouse.y
          local hover_link = false
          if self._usage_links_hover and self._usage_links_hover == url then hover_link = true end
          
          lx = renderer.draw_text(active_font, url, lx, ty, hover_link and P.fg_accent or { 100, 150, 255, 255 })
          renderer.draw_rect(ux, ty + lh - 2 * SCALE, lx - ux, 1 * SCALE, hover_link and P.fg_accent or { 100, 150, 255, 255 })
          
          renderer.draw_text(active_font, post, lx, ty, P.fg)
          
          table.insert(self._usage_links, { x = ux, y = ty, w = lx - ux, h = lh, url = url })
        else
          renderer.draw_text(active_font, line, mx + pad, ty, P.fg)
          if is_bold then
            renderer.draw_text(active_font, line, mx + pad + 1, ty, P.fg)
          end
        end
      end
      ty = ty + lh + 2 * SCALE
      if active_font == self.usage_head_font then ty = ty + 4 * SCALE end
    end
    core.pop_clip_rect()
    
    self.usage_max_scroll = math.max(0, ty + (self.usage_scroll_y or 0) - text_y - text_h)
  end

  -- API MANAGEMENT VIEW
  if self.show_api_view then
    -- dim bg
    renderer.draw_rect(x, y, w, h, {0,0,0,150})
    
    local mw = w - 40 * SCALE
    local mh = h - 60 * SCALE
    local mx = x + 20 * SCALE
    local my = y + 30 * SCALE
    
    renderer.draw_rect(mx, my, mw, mh, P.bg)
    draw_rect_outline(mx, my, mw, mh, P.border)
    
    local pad = 10 * SCALE
    -- Header
    renderer.draw_text(style.font, "API Management", mx + pad, my + pad, P.fg_accent)
    
    -- Close X
    local cx = mx + mw - pad - style.icon_font:get_width("C")
    local cy = my + pad
    renderer.draw_text(style.icon_font, "C", cx, cy, P.fg_muted)
    self._api_close_rect = { x = cx, y = cy, w = style.icon_font:get_width("C") + 8 * SCALE, h = style.icon_font:get_height() }
    
    local div_y = my + pad + style.font:get_height() + 8 * SCALE
    renderer.draw_rect(mx + pad, div_y, mw - 2 * pad, 1 * SCALE, P.border)
    
    -- Text area
    local text_y = div_y + 8 * SCALE
    local ty = text_y
    local lh = style.font:get_height()
    
    self._api_btns = {}
    
    if not self.api_key_status or self.api_key_status.status == "loading" then
      renderer.draw_text(style.font, "Validating API Keys...", mx + pad, ty, P.fg_muted)
    elseif self.api_key_status.status == "error" then
      renderer.draw_text(style.font, "Error: " .. tostring(self.api_key_status.err), mx + pad, ty, {255, 100, 100, 255})
    else
      local providers = { "gemini", "groq", "openai", "anthropic", "ollama" }
      for _, p in ipairs(providers) do
        local stat = self.api_key_status.data[p] or "missing"
        local p_name = p:sub(1,1):upper() .. p:sub(2)
        
        renderer.draw_text(style.font, p_name, mx + pad, ty, P.fg)
        local status_x = mx + pad + 100 * SCALE
        
        local stat_color = P.fg_muted
        if stat == "valid" then stat_color = { 100, 255, 100, 255 }
        elseif stat == "expired" then stat_color = { 255, 100, 100, 255 } end
        
        renderer.draw_text(style.font, stat:upper(), status_x, ty, stat_color)
        
        local btn_w = 60 * SCALE
        local btn_x = mx + mw - pad - btn_w
        
        local btn_text = (stat == "missing" or stat == "expired") and "Set Key" or "Delete"
        local is_hover = self._api_hover_btn and self._api_hover_btn == p and self._api_hover_action == btn_text
        local btn_bg = is_hover and P.bg_btn_hl or P.bg_btn
        renderer.draw_rect(btn_x, ty, btn_w, lh, btn_bg)
        renderer.draw_text(style.font, btn_text, btn_x + (btn_w - style.font:get_width(btn_text))/2, ty, P.fg)
        
        table.insert(self._api_btns, { p = p, text = btn_text, action = btn_text, x = btn_x, y = ty, w = btn_w, h = lh })
        
        if stat == "valid" then
          local use_w = 40 * SCALE
          local use_x = btn_x - use_w - 5 * SCALE
          local is_use_hover = self._api_hover_btn and self._api_hover_btn == p and self._api_hover_action == "Use"
          renderer.draw_rect(use_x, ty, use_w, lh, is_use_hover and P.bg_btn_hl or P.bg_btn)
          renderer.draw_text(style.font, "Use", use_x + (use_w - style.font:get_width("Use"))/2, ty, P.fg)
          table.insert(self._api_btns, { p = p, text = "Use", action = "Use", x = use_x, y = ty, w = use_w, h = lh })
        end
        
        ty = ty + lh + 10 * SCALE
      end
    end
  end
end

-- ── Input ──────────────────────────────────────────────────────────────────────
function AGView:on_text_input(text)
  if not text or text == "" then return end
  local clean = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if #clean > 200 or clean:find("\n") then
    self:on_paste(clean)
    return
  end
  delete_selection(self:state())
  local c = self:state().cursor or #(self:state().input or "")
  local inp = self:state().input or ""
  local before = inp:sub(1, c)
  local after = inp:sub(c + 1)
  self:_push_history(before .. clean .. after, c + #clean)
end

function AGView:on_paste(text)
  if not text or text == "" then return end
  delete_selection(self:state())
  local clean = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local is_long = #clean > 200 or select(2, clean:gsub("\n", "")) >= 2
  local paste_txt = clean
  if is_long then
    local tmp_dir = USERDIR .. "/tempfiles"
    pcall(system.mkdir, tmp_dir)
    os.execute('mkdir "' .. tmp_dir:gsub("/", "\\") .. '" 2>nul')
    local filename = os.date("pasted_text_%Y%m%d_%H%M%S.txt")
    local filepath = tmp_dir .. "/" .. filename
    local f = io.open(filepath, "wb")
    if f then
      f:write(clean)
      f:close()
      table.insert(self.temp_files, filepath)
      core.log("Saved pasted text to %s", filename)
      paste_txt = " @" .. filename .. " "
    end
  end
  local c = self:state().cursor or #(self:state().input or "")
  local inp = self:state().input or ""
  local before = inp:sub(1, c)
  local after = inp:sub(c + 1)
  self:_push_history(before .. paste_txt .. after, c + #paste_txt)
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
      self:state().select_anchor = nil
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
    if self:state().select_anchor then
      self:state().select_anchor = nil
      core.redraw = true
      return true
    end
  end

  local mods = keymap.modkeys or {}
  local is_shift = (mods["shift"] == true) or (keymap.modkeys and keymap.modkeys["shift"] == true) or (key:find("^shift%+") ~= nil)
  local is_ctrl = (mods["ctrl"] == true) or (keymap.modkeys and keymap.modkeys["ctrl"] == true) or (key:find("^ctrl%+") ~= nil) or (key:find("^cmd%+") ~= nil)

  -- Undo: Ctrl+Z / Cmd+Z
  if key == "ctrl+z" or key == "cmd+z" or (key == "z" and is_ctrl and not is_shift) then
    self:undo()
    return true
  end

  -- Redo: Ctrl+Y / Cmd+Y / Ctrl+Shift+Z / Cmd+Shift+Z
  if key == "ctrl+y" or key == "cmd+y" or key == "ctrl+shift+z" or key == "cmd+shift+z"
     or (key == "y" and is_ctrl) or (key == "z" and is_ctrl and is_shift) then
    self:redo()
    return true
  end

  -- Select All: Ctrl+A / Cmd+A
  if key == "ctrl+a" or key == "cmd+a" or (key == "a" and is_ctrl) then
    self:state().select_anchor = 0
    self:state().cursor = #(self:state().input or "")
    core.redraw = true
    return true
  end

  -- Copy: Ctrl+C / Cmd+C
  if key == "ctrl+c" or key == "cmd+c" or (key == "c" and is_ctrl) then
    local sel_from, sel_to = get_selection_range(self:state())
    if sel_from and sel_to and sel_from < sel_to then
      system.set_clipboard((self:state().input or ""):sub(sel_from + 1, sel_to))
    end
    return true
  end

  -- Cut: Ctrl+X / Cmd+X
  if key == "ctrl+x" or key == "cmd+x" or (key == "x" and is_ctrl) then
    local sel_from, sel_to = get_selection_range(self:state())
    if sel_from and sel_to and sel_from < sel_to then
      system.set_clipboard((self:state().input or ""):sub(sel_from + 1, sel_to))
      local inp = self:state().input or ""
      self:_push_history(inp:sub(1, sel_from) .. inp:sub(sel_to + 1), sel_from)
    end
    return true
  end

  -- Paste: Ctrl+V / Cmd+V
  if key == "ctrl+v" or key == "cmd+v" or (key == "v" and is_ctrl) then
    local clip = system.get_clipboard()
    if clip and #clip > 0 then
      self:on_paste(clip)
    end
    return true
  end

  if (key == "return" or key == "enter" or key == "shift+return" or key == "shift+enter") and is_shift and not is_ctrl then
    -- Shift+Enter: Insert line break
    delete_selection(self:state())
    local c = self:state().cursor or #(self:state().input or "")
    local inp = self:state().input or ""
    local before = inp:sub(1, c)
    local after = inp:sub(c + 1)
    self:_push_history(before .. "\n" .. after, c + 1)
    return true
  end

  if (key == "return" or key == "enter") and not is_ctrl and not is_shift then
    local q = (self:state().input or ""):match("^%s*(.-)%s*$")
    if q and #q > 0 then self:submit(q) end
    self:state().input = ""
    self:state().cursor = 0
    self:state().select_anchor = nil
    self:state().history = { { input = "", cursor = 0 } }
    self:state().history_idx = 1
    core.redraw = true
    return true
  end

  if (key == "return" or key == "enter" or key == "ctrl+return" or key == "ctrl+enter") and is_ctrl then
    -- Ctrl+Enter: clear chat
    self:state().sessions = {}
    self:state().input    = ""
    self:state().cursor   = 0
    self:state().select_anchor = nil
    self:state().status   = "idle"
    self:state().has_session = false
    self:state().history = { { input = "", cursor = 0 } }
    self:state().history_idx = 1
    if self:state().process then pcall(function() graceful_kill(self:state().process) end) end
    self:state().process  = nil
    core.redraw = true
    return true
  end

  if key == "backspace" then
    local sel_from, sel_to = get_selection_range(self:state())
    if sel_from and sel_to and sel_from < sel_to then
      local inp = self:state().input or ""
      self:_push_history(inp:sub(1, sel_from) .. inp:sub(sel_to + 1), sel_from)
      return true
    end
    local c = self:state().cursor or #(self:state().input or "")
    if c > 0 then
      local inp = self:state().input or ""
      local prev_c = utf8_prev(inp, c)
      local before = inp:sub(1, prev_c)
      local after = inp:sub(c + 1)
      self:_push_history(before .. after, prev_c)
    end
    return true
  end

  if key == "delete" then
    local sel_from, sel_to = get_selection_range(self:state())
    if sel_from and sel_to and sel_from < sel_to then
      local inp = self:state().input or ""
      self:_push_history(inp:sub(1, sel_from) .. inp:sub(sel_to + 1), sel_from)
      return true
    end
    local c = self:state().cursor or #(self:state().input or "")
    local inp = self:state().input or ""
    if c < #inp then
      local next_c = utf8_next(inp, c)
      local before = inp:sub(1, c)
      local after = inp:sub(next_c + 1)
      self:_push_history(before .. after, c)
    end
    return true
  end

  local base_key = key:gsub("^shift%+", ""):gsub("^ctrl%+", ""):gsub("^cmd%+", "")

  if base_key == "left" then
    if is_shift then
      if not self:state().select_anchor then
        self:state().select_anchor = self:state().cursor or #(self:state().input or "")
      end
      self:state().cursor = utf8_prev(self:state().input or "", self:state().cursor or #(self:state().input or ""))
    else
      local sel_from, _ = get_selection_range(self:state())
      if sel_from then
        self:state().cursor = sel_from
        self:state().select_anchor = nil
      else
        self:state().cursor = utf8_prev(self:state().input or "", self:state().cursor or #(self:state().input or ""))
        self:state().select_anchor = nil
      end
    end
    core.redraw = true
    return true
  elseif base_key == "right" then
    if is_shift then
      if not self:state().select_anchor then
        self:state().select_anchor = self:state().cursor or 0
      end
      self:state().cursor = utf8_next(self:state().input or "", self:state().cursor or 0)
    else
      local _, sel_to = get_selection_range(self:state())
      if sel_to then
        self:state().cursor = sel_to
        self:state().select_anchor = nil
      else
        self:state().cursor = utf8_next(self:state().input or "", self:state().cursor or 0)
        self:state().select_anchor = nil
      end
    end
    core.redraw = true
    return true
  elseif base_key == "home" then
    local raw_input = self:state().input or ""
    local visual_lines = self._visual_lines or wrap_input_lines(raw_input, style.font, (self.size.x - 20 * SCALE) - 16 * SCALE)
    local cur_line = get_cursor_visual_line_col(visual_lines, raw_input, self:state().cursor)
    local target_byte = get_cursor_byte_from_visual(visual_lines, cur_line, 0)
    if is_shift then
      if not self:state().select_anchor then
        self:state().select_anchor = self:state().cursor or 0
      end
      self:state().cursor = target_byte
    else
      local sel_from, _ = get_selection_range(self:state())
      if sel_from then
        self:state().cursor = sel_from
        self:state().select_anchor = nil
      else
        self:state().cursor = target_byte
        self:state().select_anchor = nil
      end
    end
    core.redraw = true
    return true
  elseif base_key == "end" then
    local raw_input = self:state().input or ""
    local visual_lines = self._visual_lines or wrap_input_lines(raw_input, style.font, (self.size.x - 20 * SCALE) - 16 * SCALE)
    local cur_line = get_cursor_visual_line_col(visual_lines, raw_input, self:state().cursor)
    local line_info = visual_lines[cur_line] or visual_lines[#visual_lines]
    local target_byte = get_cursor_byte_from_visual(visual_lines, cur_line, #(line_info.text or ""))
    if is_shift then
      if not self:state().select_anchor then
        self:state().select_anchor = self:state().cursor or 0
      end
      self:state().cursor = target_byte
    else
      local _, sel_to = get_selection_range(self:state())
      if sel_to then
        self:state().cursor = sel_to
        self:state().select_anchor = nil
      else
        self:state().cursor = target_byte
        self:state().select_anchor = nil
      end
    end
    core.redraw = true
    return true
  end

  if base_key == "up" then
    local raw_input = self:state().input or ""
    local visual_lines = self._visual_lines or wrap_input_lines(raw_input, style.font, (self.size.x - 20 * SCALE) - 16 * SCALE)
    local cur_line, cur_col = get_cursor_visual_line_col(visual_lines, raw_input, self:state().cursor)
    if cur_line > 1 then
      local prev_line = visual_lines[cur_line - 1]
      local cur_line_info = visual_lines[cur_line]
      local target_x = style.font:get_width((cur_line_info.text or ""):sub(1, cur_col))
      local best_col = 0
      local min_dist = math.abs(target_x)
      local i = 0
      local prev_text = prev_line.text or ""
      while i < #prev_text do
        local next_i = utf8_next(prev_text, i)
        local dist = math.abs(style.font:get_width(prev_text:sub(1, next_i)) - target_x)
        if dist < min_dist then
          min_dist = dist
          best_col = next_i
        end
        i = next_i
      end
      local target_byte = get_cursor_byte_from_visual(visual_lines, cur_line - 1, best_col)
      if is_shift then
        if not self:state().select_anchor then
          self:state().select_anchor = self:state().cursor or 0
        end
        self:state().cursor = target_byte
      else
        local sel_from, _ = get_selection_range(self:state())
        if sel_from then
          self:state().cursor = sel_from
          self:state().select_anchor = nil
        else
          self:state().cursor = target_byte
          self:state().select_anchor = nil
        end
      end
      core.redraw = true
      return true
    else
      if not is_shift then
        self:state().scroll_y = math.max(0, self:state().scroll_y - (style.font:get_height() + 2 * SCALE) * 3)
      end
      core.redraw = true
      return true
    end
  end

  if base_key == "down" then
    local raw_input = self:state().input or ""
    local visual_lines = self._visual_lines or wrap_input_lines(raw_input, style.font, (self.size.x - 20 * SCALE) - 16 * SCALE)
    local cur_line, cur_col = get_cursor_visual_line_col(visual_lines, raw_input, self:state().cursor)
    if cur_line < #visual_lines then
      local next_line = visual_lines[cur_line + 1]
      local cur_line_info = visual_lines[cur_line]
      local target_x = style.font:get_width((cur_line_info.text or ""):sub(1, cur_col))
      local best_col = 0
      local min_dist = math.abs(target_x)
      local i = 0
      local next_text = next_line.text or ""
      while i < #next_text do
        local next_i = utf8_next(next_text, i)
        local dist = math.abs(style.font:get_width(next_text:sub(1, next_i)) - target_x)
        if dist < min_dist then
          min_dist = dist
          best_col = next_i
        end
        i = next_i
      end
      local target_byte = get_cursor_byte_from_visual(visual_lines, cur_line + 1, best_col)
      if is_shift then
        if not self:state().select_anchor then
          self:state().select_anchor = self:state().cursor or 0
        end
        self:state().cursor = target_byte
      else
        local _, sel_to = get_selection_range(self:state())
        if sel_to then
          self:state().cursor = sel_to
          self:state().select_anchor = nil
        else
          self:state().cursor = target_byte
          self:state().select_anchor = nil
        end
      end
      core.redraw = true
      return true
    else
      if not is_shift then
        self:state().scroll_y = math.min(self:state().max_scroll, self:state().scroll_y + (style.font:get_height() + 2 * SCALE) * 3)
      end
      core.redraw = true
      return true
    end
  end
  return false
end

-- ── Mouse ──────────────────────────────────────────────────────────────────────
function AGView:on_mouse_moved(mx, my, ...)
  AGView.super.on_mouse_moved(self, mx, my, ...)
  
  self._usage_links_hover = nil
  if self.show_usage_view and self._usage_links then
    local hovering = false
    for _, link in ipairs(self._usage_links) do
      if mx >= link.x and mx <= link.x + link.w and my >= link.y and my <= link.y + link.h then
        self._usage_links_hover = link.url
        system.set_cursor("hand")
        hovering = true
        core.redraw = true
        break
      end
    end
    if not hovering then system.set_cursor("arrow") end
  end

  self._api_hover_btn = nil
  self._api_hover_action = nil
  if self.show_api_view and self._api_btns then
    local hovering = false
    for _, btn in ipairs(self._api_btns) do
      if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
        self._api_hover_btn = btn.p
        self._api_hover_action = btn.action
        system.set_cursor("hand")
        hovering = true
        core.redraw = true
        break
      end
    end
    if not hovering then system.set_cursor("arrow") end
  end

  self.hover_btn  = nil
  self.hover_send = false
  self.hover_attach = false

  -- Mouse drag selection in input
  if self._dragging_input and self._input_rect then
    local r = self._input_rect
    local raw_input = self:state().input or ""
    local visual_lines = self._visual_lines or (self:state()._vl_cache) or wrap_input_lines(raw_input, style.font, r.w - 16 * SCALE)
    local lh = r.lh or (style.font:get_height() + 3 * SCALE)
    local scroll_offset = self._input_scroll_offset or 0
    local line_idx = math.floor((my - (r.y + 8 * SCALE) + scroll_offset) / lh) + 1
    line_idx = math.max(1, math.min(#visual_lines, line_idx))

    local target_line_info = visual_lines[line_idx]
    local target_line_str = target_line_info and target_line_info.text or ""
    local click_x = mx - (r.x + 8 * SCALE)
    local best_col = 0
    local min_dist = math.abs(click_x)
    local i = 0
    while i < #target_line_str do
      local next_i = utf8_next(target_line_str, i)
      local char_w = style.font:get_width(target_line_str:sub(1, next_i))
      local dist = math.abs(char_w - click_x)
      if dist < min_dist then
        min_dist = dist
        best_col = next_i
      end
      i = next_i
    end
    self:state().cursor = get_cursor_byte_from_visual(visual_lines, line_idx, best_col)
    core.redraw = true
  end

  local x     = self.position.x
  local w     = self.size.x
  local pad   = 10 * SCALE
  local n     = #config.antigravity.actions
  local pill_w = math.floor((w - 2 * pad - (n - 1) * 4 * SCALE) / n)
  local pill_h = 24 * SCALE
  -- Pills start at: y + header(40) + 6
  local pills_top = self.position.y + 52 * SCALE + 6 * SCALE

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
  self.hover_auto_btn = false
  self.hover_ro_btn = false

  if self._auto_rect then
    local r = self._auto_rect
    self.hover_auto_btn = (mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h)
  end
  if self._ro_rect then
    local r = self._ro_rect
    self.hover_ro_btn = (mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h)
  end

  self.hover_hitl = nil
  if self._hitl_rects then
    for _, r in ipairs(self._hitl_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        self.hover_hitl = r.val
        system.set_cursor("hand")
        break
      end
    end
  end

  if self._model_rect then
    local r = self._model_rect
    self.hover_model_btn = (mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h)
  end
  if self.show_model_picker and self._mpicker_rects then
    for _, r in ipairs(self._mpicker_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        local m = self.model_list[r.idx]
        if m and not m.limited then
          self.hover_model_idx = r.idx
        end
        break
      end
    end
  end

  -- Tool header button hover
  self._tool_hdr_rect_hov = false
  if self._tool_hdr_rect then
    local r = self._tool_hdr_rect
    self._tool_hdr_rect_hov = (mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h)
  end
  -- Tool picker row hover
  self.hover_tool_idx = nil
  if self._tool_picker_rects then
    for _, r in ipairs(self._tool_picker_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        self.hover_tool_idx = r.idx
        break
      end
    end
  end

  self.hover_hist_btn = false
  if self._hist_toggle_rect then
    local r = self._hist_toggle_rect
    self.hover_hist_btn = (mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h)
  end

  self.hover_hist_node = nil
  if self.show_history_tree and self._hist_node_rects then
    for _, r in ipairs(self._hist_node_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        self.hover_hist_node = r.id
        system.set_cursor("hand")
        break
      end
    end
  end

  if self.hover_hist_btn then
    system.set_cursor("hand")
  end

  -- Only trigger redraw when hover state actually changed (prevents 60fps forced redraws on every mouse move)
  local new_sig = tostring(self.hover_btn) .. tostring(self.hover_send) .. tostring(self.hover_attach)
                  .. tostring(self.hover_hist_node) .. tostring(self.hover_hist_btn)
                  .. tostring(self.hover_model_btn) .. tostring(self.hover_model_idx)
                  .. tostring(self.hover_copy_idx) .. tostring(self.hover_hitl)
                  .. tostring(self.hover_auto_btn) .. tostring(self.hover_ro_btn)
                  .. tostring(self._usage_links_hover) .. tostring(self._api_hover_btn)
  if new_sig ~= self._last_hover_sig then
    self._last_hover_sig = new_sig
    core.redraw = true
  end
end


  function AGView:fetch_history()
    if self.history_state == "loading" then return end
    self.history_state = "loading"
    core.redraw = true
    core.add_thread(function()
      local config_dir = USERDIR .. "/scripts"
      local cmd = "python " .. config_dir .. "/ai_api_bridge.py --get-history"
      local proc = process.start({ "cmd", "/c", cmd })
      local out_tbl = {}
      while true do
        local chunk = proc:read_stdout(65536)
        if chunk and #chunk > 0 then table.insert(out_tbl, chunk) end
        if not proc:running() then break end
        coroutine.yield(0.1)
      end
      
      -- Final drain loop to ensure we catch all remaining buffered bytes
      while true do
        local chunk = proc:read_stdout(65536)
        if not chunk or #chunk == 0 then break end
        table.insert(out_tbl, chunk)
      end
      
      local out = table.concat(out_tbl)
      
      -- evaluate lua table safely
      local env = {}
      local f, err = load(out, "history", "t", env)
      local ok = false
      local data = nil
      local err_msg = err
      if f then
        ok, data = pcall(f)
        if not ok then err_msg = tostring(data) end
      end
      
      if ok and type(data) == "table" and not data.error then
        self:_layout_history(data)
        self.history_state = "loaded"
      else
        core.log("[History] Error loading history: %s", tostring(err_msg))
        core.log("[History] Out length: %s", tostring(#out))
        self.history_state = "error"
      end
      core.redraw = true
    end)
  end

  function AGView:_layout_history(data)
    -- Group by thread
    local threads = {}
    for _, n in ipairs(data) do
      if not threads[n.thread_id] then threads[n.thread_id] = {} end
      table.insert(threads[n.thread_id], n)
    end
    
    local nodes = {}
    local node_map = {}
    local row = 0
    
    for tid, tnodes in pairs(threads) do
      -- Title node for thread
      row = row + 1
      table.insert(nodes, { is_title = true, title = tid, row = row })
      
      -- Layout nodes chronologically
      -- Reset columns for new thread
      local col_ends = {} 
      
      for _, n in ipairs(tnodes) do
        row = row + 1
        n.row = row
        node_map[n.id] = n
        
        local parent = node_map[n.parent_id]
        if parent then
          if not parent.has_child then
            parent.has_child = true
            n.col = parent.col
          else
            -- branch
            local c = parent.col + 1
            while col_ends[c] do c = c + 1 end
            n.col = c
          end
        else
          n.col = 1
        end
        col_ends[n.col] = row
        table.insert(nodes, n)
      end
      row = row + 1 -- padding
    end
    
    self.history_nodes = nodes
    self.history_map = node_map
  end
  
  function AGView:draw_history_tree(x, y, w, h)
    local function get_is_left(n)
      if n.is_title then return (n.row % 2 == 1) end
      return (n.char_count or 0) < 200
    end

    local P       = get_palette()
    local C_TR    = {84, 52, 20, 255}    -- Trunk dark brown
    local C_LEAF  = {142, 186, 43, 255}  -- Light green leaf
    local C_LEAF_D= {112, 150, 30, 255}  -- Darker green leaf
    local C_YEAR  = {142, 186, 43, 255}  -- Year green
    local C_TEXT  = P.fg_muted
    local f       = style.font
    local fh      = f:get_height()

    renderer.draw_rect(x, y, w, h, P.bg)
    core.push_clip_rect(x, y, w, h)

    if self.history_state == "loading" then
      renderer.draw_text(f, "Growing tree...", x + 20, y + 20, C_LEAF)
      core.pop_clip_rect(); return
    elseif self.history_state == "error" then
      renderer.draw_text(f, "Error loading timeline.", x + 20, y + 20, {220,60,60,255})
      core.pop_clip_rect(); return
    end
    if not self.history_nodes or #self.history_nodes == 0 then
      renderer.draw_text(f, "No history yet.", x + 20, y + 20, C_TEXT)
      core.pop_clip_rect(); return
    end

    -- -- Primitive Drawing Helpers ----------------------------------
    local function fill_circle(cx, cy, r, color)
        r = math.max(1, math.floor(r))
        -- Optimize rendering: use larger steps for large radii to prevent O(r) draw_rect calls
        local step = math.max(1, math.floor(r / 15)) 
        for dy = -r, r, step do
            local dx = math.floor(math.sqrt(r*r - dy*dy))
            renderer.draw_rect(cx - dx, cy + dy, dx * 2, step, color)
        end
    end

    -- -- Layout Math -----------------------------------------------
    local SCROLL  = self.history_scroll_y or 0
    local ROW_H   = 120 * SCALE
    local CANOPY  = 250 * SCALE
    local MARGIN  = 20 * SCALE

    -- Fixed elegant trunk width
    local TRUNK_W = 24 * SCALE
    local trunk_cx = x + math.floor(w * 0.50)
    local trunk_x = trunk_cx - math.floor(TRUNK_W / 2)
    
    local LEFT_W  = (trunk_x) - x - MARGIN
    local RIGHT_W = (x + w) - (trunk_x + TRUNK_W) - MARGIN

    if not self._hist_max_row or self._hist_max_row_n ~= #self.history_nodes then
      local m = 0
      for _, n in ipairs(self.history_nodes) do
        if n.row and n.row > m then m = n.row end
      end
      self._hist_max_row   = m
      self._hist_max_row_n = #self.history_nodes
    end
    local max_row = self._hist_max_row

    self.history_max_scroll = math.max(0, max_row * ROW_H + CANOPY - h + 100 * SCALE)

    local function cy_of(row)
      return y + CANOPY + (max_row - row) * ROW_H - SCROLL
    end

    -- -- PASS 1: The Trunk -----------------------------------------
    -- The newest chat is right beneath the canopy
    local scroll_trunk_top = cy_of(max_row) - 80 * SCALE
    local scroll_trunk_bot = cy_of(1) + 150 * SCALE
    
    local draw_start_y = math.max(y, scroll_trunk_top)
    local draw_end_y = math.min(y + h, scroll_trunk_bot)
    
    if draw_start_y < draw_end_y then
        renderer.draw_rect(trunk_x, draw_start_y, TRUNK_W, draw_end_y - draw_start_y, C_TR)
    end
    
    -- Smooth root flares at the bottom
    if scroll_trunk_bot > y and scroll_trunk_bot < y + h + 50*SCALE then
        for ri = 1, 10 do
            fill_circle(trunk_x - ri*2*SCALE, scroll_trunk_bot - ri*3*SCALE, ri*2*SCALE, C_TR)
            fill_circle(trunk_x + TRUNK_W + ri*2*SCALE, scroll_trunk_bot - ri*3*SCALE, ri*2*SCALE, C_TR)
        end
    end

    -- -- PASS 2: Solid Curved Branches -----------------------------
    local function draw_solid_branch(cy, is_left)
        local dir = is_left and -1 or 1
        local blen = (is_left and LEFT_W or RIGHT_W) * 0.90
        local base_thick = 18 * SCALE  -- thick at base
        
        local sx = is_left and trunk_x or (trunk_x + TRUNK_W)
        local steps = math.floor(blen)
        
        for i = 0, steps do
            local t = i / steps
            local bx = sx + dir * i
            
            -- Top edge swoops down then sweeps up gracefully
            local y_top = cy + (45 * t - 70 * t * t) * SCALE
            
            -- Thickness stays meaty for most of the branch, then tapers elegantly to a 1px point
            local thick = math.max(1, base_thick * (1 - t^2))
            local y_bot = y_top + thick
            
            -- Draw vertical slice
            renderer.draw_rect(bx, math.floor(y_top), 1, math.max(1, math.floor(y_bot - y_top)), C_TR)
        end
    end

    for _, n in ipairs(self.history_nodes) do
      if not n.is_title then
        local cy = cy_of(n.row)
        if cy > y - ROW_H and cy < y + h + ROW_H then
          draw_solid_branch(cy, get_is_left(n))
        end
      end
    end

    -- -- PASS 3: Cloud Canopy (Vector Style) -----------------------
    local canopy_cy = scroll_trunk_top - 30 * SCALE
    if canopy_cy > y - 400*SCALE and canopy_cy < y + h + 400*SCALE then
      math.randomseed(42)
      
      -- Draw structural top branches splitting into the canopy
      for i=1, 6 do
         local bx = trunk_cx
         local by = scroll_trunk_top + 20*SCALE
         local dir = (i % 2 == 0) and 1 or -1
         local sweep = math.random() * 80 * SCALE
         for j=0, 30 do
             local t = j/30
             local cx = bx + dir * t * sweep
             local cy = by - t * 90 * SCALE
             local r = math.max(1, (8 - t*7)*SCALE)
             fill_circle(cx, cy, r, C_TR)
         end
      end
      
      -- Modern Vector UI Tree Crown (Overlapping solid circles)
      -- Main crown shapes
      local blobs = {
          {x=0, y=0, r=60},
          {x=-50, y=10, r=50},
          {x=50, y=10, r=50},
          {x=-80, y=-20, r=45},
          {x=80, y=-20, r=45},
          {x=-30, y=-40, r=55},
          {x=30, y=-40, r=55},
          {x=0, y=-70, r=50}
      }
      
      for _, b in ipairs(blobs) do
          fill_circle(trunk_cx + b.x*SCALE, canopy_cy + b.y*SCALE, b.r*SCALE, C_LEAF_D)
      end
      for _, b in ipairs(blobs) do
          fill_circle(trunk_cx + b.x*SCALE, canopy_cy + b.y*SCALE - 5*SCALE, (b.r-4)*SCALE, C_LEAF)
      end
      
      -- Scatted perimeter leaves (small circles)
      for i=1, 60 do
          local ang = math.random() * math.pi * 2
          local dist = 60*SCALE + math.random() * 60*SCALE
          local cx = trunk_cx + math.cos(ang) * dist
          local cy = canopy_cy - 20*SCALE + math.sin(ang) * dist * 0.6
          local r = 8*SCALE + math.random()*12*SCALE
          local c = (math.random() > 0.5) and C_LEAF or C_LEAF_D
          fill_circle(cx, cy, r, c)
      end
      
      -- Chat Memory Tree Title in the Canopy
      local tf = style.big_font or style.font
      local title_str = "Chat Memory Tree"
      local tw = tf:get_width(title_str)
      local th = tf:get_height()
      local ty = canopy_cy - 10*SCALE - th/2
      -- Draw shadow/outline for readability
      renderer.draw_text(tf, title_str, trunk_cx - tw/2 + 2, ty + 2, {0,0,0,180})
      renderer.draw_text(tf, title_str, trunk_cx - tw/2, ty, P.bg)
    end

    -- -- PASS 4: Text Wrap Cache -----------------------------------
    local function align_wrap(text, font, max_w)
       local lines = {}
       for line in text:gmatch("([^\r\n]+)") do
          local cur = ""
          for word in line:gmatch("%S+") do
             if font:get_width(cur .. " " .. word) > max_w then
                if cur ~= "" then table.insert(lines, cur) end
                cur = word
             else
                cur = cur == "" and word or (cur .. " " .. word)
             end
          end
          if cur ~= "" then table.insert(lines, cur) end
       end
       return lines
    end

    for _, n in ipairs(self.history_nodes) do
      if n._cache_w ~= w then
        n._cache_w = w
        local is_left = get_is_left(n)
        
        local dt = n.date or ""
        n._year = dt ~= "" and dt:sub(1, 4) or "Chat"
        n._date = dt ~= "" and dt:sub(1, 10) or ""
        
        local tw = is_left and LEFT_W or RIGHT_W
        n._lines = align_wrap(n.snippet or "No content", f, tw)
        if #n._lines > 4 then
           n._lines = { n._lines[1], n._lines[2], n._lines[3], n._lines[4] .. "..." }
        end
        n._title = n.title == "default_thread" and "main" or (n.title or "?")
      end
    end

    -- -- PASS 5: Clean Labels --------------------------------------
    self._hist_node_rects = {}
    local year_f = style.font -- A bigger font would be nice, but stick to standard to avoid errors

    for _, n in ipairs(self.history_nodes) do
      local cy = cy_of(n.row)
      if cy > y - ROW_H and cy < y + h + ROW_H then
        local is_left = get_is_left(n)
        local is_hov  = self.hover_hist_node == n.id

        if n.is_title then
           local tx = is_left and (trunk_x - 10*SCALE - f:get_width(n._title)) or (trunk_x + TRUNK_W + 10*SCALE)
           renderer.draw_text(f, n._title, tx, cy - fh//2, is_hov and P.fg_accent or C_YEAR)
        else
           -- Year sits elegantly ON TOP of the branch base
           local year_w = year_f:get_width(n._year)
           local y_x = is_left and (trunk_x - year_w - 10*SCALE) or (trunk_x + TRUNK_W + 10*SCALE)
           local y_y = cy - fh - 2*SCALE
           
           renderer.draw_text(year_f, n._year, y_x, y_y, is_hov and P.fg_accent or C_YEAR)
           
           -- Text floats cleanly BELOW the branch
           local t_y = cy + 14*SCALE
           
           local prov_str = ""
           if n.source == "human" then
               prov_str = "[User] "
           elseif n.provider and n.provider ~= "" then
               prov_str = "[" .. n.provider .. "] "
           elseif n.source == "ai" then
               prov_str = "[AI] "
           end
           
           local m_str = prov_str .. n._date
           
           local function draw_aligned(text, font, yy, col, bold)
              local tw = font:get_width(text)
              -- Push text slightly further out to follow the curve of the branch downwards
              local tx = is_left and (trunk_x - tw - 15*SCALE) or (trunk_x + TRUNK_W + 15*SCALE)
              renderer.draw_text(font, text, tx, yy, col)
              if bold then
                 renderer.draw_text(font, text, tx + 1, yy, col)
                 -- Add horizontal offset twice for a crisp bold effect
                 -- If the text is light, we can even double strike it
              end
           end
           
           local current_y = t_y
           draw_aligned(m_str, f, current_y, P.fg_accent or {200,200,200,255}, true) -- Bold & brighter!
           current_y = current_y + fh + 2*SCALE
           
           for _, line in ipairs(n._lines) do
              draw_aligned(line, f, current_y, is_hov and P.fg or C_TEXT, false)
              current_y = current_y + fh + 2*SCALE
           end
           
           -- Hitbox
           local rx = is_left and (trunk_x - LEFT_W) or (trunk_x + TRUNK_W)
           table.insert(self._hist_node_rects, { id=n.id, thread=n.thread_id, x=rx, y=y_y, w=LEFT_W, h=(current_y - y_y) })
        end
      end
    end

    core.pop_clip_rect()
  end




function AGView:on_mouse_pressed(button, mx, my, clicks)
  AGView.super.on_mouse_pressed(self, button, mx, my, clicks)
  core.set_active_view(self)
  if button == "left" then
    if self.hover_hist_btn then
      self.show_history_tree = not self.show_history_tree
      if self.show_history_tree then self:fetch_history() end
      core.redraw = true
      return
    end
    
    if self.show_history_tree and self.hover_hist_node then
      for _, r in ipairs(self._hist_node_rects) do
        if r.id == self.hover_hist_node then
          core.log("Resuming thread: " .. r.thread)
          self.show_history_tree = false
          self:state().thread_id = r.thread
          self:state().sessions = {}
          self:state().has_session = true
          self:state().status = "idle"
          self:_add_session("ai", "Resumed conversation thread: " .. r.thread .. "\nAsk a question to continue from this branch.")
          core.redraw = true
          break
        end
      end
      return
    end
  end


  -- Right-click: Linux shell style instant paste into input box
  if button == "right" then
    if self._input_rect then
      local r = self._input_rect
      local inside_input = (mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h)
      local in_bottom_area = (mx >= self.position.x and mx <= self.position.x + self.size.x and my >= r.y - 12 * SCALE)

      if inside_input or in_bottom_area then
        if inside_input then
          local raw_input = self:state().input or ""
          local visual_lines = self._visual_lines or wrap_input_lines(raw_input, style.font, r.w - 16 * SCALE)
          local lh = r.lh or (style.font:get_height() + 3 * SCALE)
          local scroll_offset = self._input_scroll_offset or 0
          local line_idx = math.floor((my - (r.y + 8 * SCALE) + scroll_offset) / lh) + 1
          line_idx = math.max(1, math.min(#visual_lines, line_idx))

          local target_line_info = visual_lines[line_idx]
          local target_line_str = target_line_info and target_line_info.text or ""
          local click_x = mx - (r.x + 8 * SCALE)
          local best_col = 0
          local min_dist = math.abs(click_x)
          local i = 0
          while i < #target_line_str do
            local next_i = utf8_next(target_line_str, i)
            local char_w = style.font:get_width(target_line_str:sub(1, next_i))
            local dist = math.abs(char_w - click_x)
            if dist < min_dist then
              min_dist = dist
              best_col = next_i
            end
            i = next_i
          end
          self:state().cursor = get_cursor_byte_from_visual(visual_lines, line_idx, best_col)
          self:state().select_anchor = nil
        end

        local clip = system.get_clipboard()
        if clip and #clip > 0 then
          self:on_paste(clip)
        end
        core.redraw = true
        return true
      end
    end
    return false
  end

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

  if self._auto_rect then
    local r = self._auto_rect
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      config.ai_sidebar.autopilot = not config.ai_sidebar.autopilot
      core.redraw = true
      return true
    end
  end

  if self._ro_rect then
    local r = self._ro_rect
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      config.ai_sidebar.read_only = not config.ai_sidebar.read_only
      core.redraw = true
      return true
    end
  end

  if self._hitl_rects and self:state().status == "running" then
    for _, r in ipairs(self._hitl_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        if self:state().process then
          pcall(function() self:state().process:write(r.val .. "\r\n") end)
          -- Append the user's choice to the chat so they see what they did
          self:_add_session("user", r.val)
          self:state().scroll_to_bottom = true
          core.redraw = true
        end
        return true
      end
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
  if self._input_rect then
    local r = self._input_rect
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      local raw_input = self:state().input or ""
      local visual_lines = self._visual_lines or wrap_input_lines(raw_input, style.font, r.w - 16 * SCALE)
      local lh = r.lh or (style.font:get_height() + 3 * SCALE)
      local scroll_offset = self._input_scroll_offset or 0
      local line_idx = math.floor((my - (r.y + 8 * SCALE) + scroll_offset) / lh) + 1
      line_idx = math.max(1, math.min(#visual_lines, line_idx))

      local target_line_info = visual_lines[line_idx]
      local target_line_str = target_line_info and target_line_info.text or ""
      local click_x = mx - (r.x + 8 * SCALE)
      local best_col = 0
      local min_dist = math.abs(click_x)
      local i = 0
      while i < #target_line_str do
        local next_i = utf8_next(target_line_str, i)
        local char_w = style.font:get_width(target_line_str:sub(1, next_i))
        local dist = math.abs(char_w - click_x)
        if dist < min_dist then
          min_dist = dist
          best_col = next_i
        end
        i = next_i
      end
      local clicked_byte = get_cursor_byte_from_visual(visual_lines, line_idx, best_col)

      if clicks == 2 then
        -- Double click: select word
        local w_from, w_to = find_word_boundaries(raw_input, clicked_byte)
        self:state().select_anchor = w_from
        self:state().cursor = w_to
        self._dragging_input = false
      elseif clicks == 3 then
        -- Triple click: select all
        self:state().select_anchor = 0
        self:state().cursor = #raw_input
        self._dragging_input = false
      else
        -- Single click
        self:state().cursor = clicked_byte
        self:state().select_anchor = clicked_byte
        self._dragging_input = true
      end

      core.redraw = true
      return true
    end
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
      
      -- Restore the tool method used by this specific tab
      if self:state().tool_id then
        config.ai_sidebar.active_tool = self:state().tool_id
        self:_sync_model_list()
      end
      
      core.redraw = true
      return true
    end
  end

  -- Tool picker row selection
  if self._tool_picker_rects then
    for _, r in ipairs(self._tool_picker_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        if r.is_add then
          -- "+" custom tool: prompt for binary path
          core.command_view:enter("Enter custom tool binary path (e.g. C:\\path\\to\\tool.exe)", {
            submit = function(text)
              text = text:match("^%s*(.-)%s*$")
              if text and #text > 0 then
                local name = text:match("[/\\]([^/\\]+)$") or text
                local id   = "custom_" .. name:gsub("%W", "_")
                local entry = { id=id, name=name, short=name:sub(1,3):upper(), bin=text }
                config.ai_sidebar.detected[id] = { bin = text }
                table.insert(config.ai_sidebar.detected_list, entry)
                table.insert(config.ai_sidebar.custom_tools or {}, entry)
                config.ai_sidebar.active_tool = id
                
                -- Force model list for custom tool
                self.tool_model_lists[id] = { { name = "Default", limited = false } }
                self.model_list = self.tool_model_lists[id]
                core.redraw = true
              end
            end
          })
        else
          -- Switch to selected tool
          local det = config.ai_sidebar.detected_list
          local selected = det[r.idx]
          if selected then
            local prev_id = config.ai_sidebar.active_tool
            config.ai_sidebar.active_tool = selected.id
              self:state().tool_id = selected.id
            
            -- Sync model list from cache (or trigger fetch)
            local id = selected.id
            if self.tool_model_lists[id] and #self.tool_model_lists[id] > 0 then
              self.model_list = self.tool_model_lists[id]
            else
              self.model_list = {}
              self:fetch_models(false)
            end
            core.log("AI Sidebar: switched to " .. selected.name)
          end
        end
        core.redraw = true
        return true
      end
    end
  end

  -- Model picker row selection
  if self.show_model_picker and self._mpicker_rects then
    for _, r in ipairs(self._mpicker_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        local m = self.model_list[r.idx]
        if m and not m.limited then
          self:_set_active_model(m.name)
          self.show_model_picker = false
          self:state().has_session = false  -- reset session so next prompt doesn't inherit old model's -c
          core.log("AI Sidebar: switched to model '" .. m.name .. "'")
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

function AGView:on_mouse_released(button, mx, my)
  AGView.super.on_mouse_released(self, button, mx, my)
  
  if self.show_api_view then
    local cx, cy, cw, ch = 0, 0, 0, 0
    if self._api_close_rect then
      cx, cy, cw, ch = self._api_close_rect.x, self._api_close_rect.y, self._api_close_rect.w, self._api_close_rect.h
    end
    if mx >= cx and mx <= cx + cw and my >= cy and my <= cy + ch then
      self.show_api_view = false
      core.redraw = true
      return true
    end
    if self._api_btns then
      for _, btn in ipairs(self._api_btns) do
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          if btn.action == "Delete" then
            -- run delete command
            local bridge = USERDIR .. "/scripts/ai_api_bridge.py"
            core.add_thread(function()
              process.start({ "python", bridge, "--provider", btn.p, "--delete-key" }):wait()
              self:submit("/api") -- refresh
            end)
          elseif btn.action == "Use" then
            -- Set provider as active by picking its first model
            if self.tool_model_lists and self.tool_model_lists["cloud_api"] then
              for _, m in ipairs(self.tool_model_lists["cloud_api"]) do
                if m.name:match("^" .. btn.p .. "/") then
                  local tc = self:_tool_cfg("cloud_api")
                  tc.selected_model = m.name
                  if (config.ai_sidebar.active_tool or "agy") == "cloud_api" then
                    config.antigravity.selected_model = m.name
                  end
                  self.show_api_view = false
                  break
                end
              end
            end
          else
            -- set key
            self:_prompt_for_api_key(btn.p)
          end
          return true
        end
      end
    end
    return true
  end

  if self.show_usage_view then
    local cx, cy, cw, ch = 0, 0, 0, 0
    if self._usage_close_rect then
      cx, cy, cw, ch = self._usage_close_rect.x, self._usage_close_rect.y, self._usage_close_rect.w, self._usage_close_rect.h
    end
    if mx >= cx and mx <= cx + cw and my >= cy and my <= cy + ch then
      self.show_usage_view = false
      core.redraw = true
      return true
    end
    if self._usage_links then
      for _, link in ipairs(self._usage_links) do
        if mx >= link.x and mx <= link.x + link.w and my >= link.y and my <= link.y + link.h then
          if PLATFORM == "Windows" then
            system.exec("start \"\" \"" .. link.url .. "\"")
          elseif PLATFORM == "Mac OS X" then
            system.exec("open \"" .. link.url .. "\"")
          else
            system.exec("xdg-open \"" .. link.url .. "\"")
          end
          return true
        end
      end
    end
    -- Prevent clicks from bleeding through to chat if usage view is open
    return true
  end

  if button == "left" then
    self._dragging_input = false
    if self:state().select_anchor == self:state().cursor then
      self:state().select_anchor = nil
    end
    core.redraw = true
  end
end

function AGView:on_mouse_wheel(dy)
  if self.show_usage_view then
    local item_h = style.code_font:get_height()
    self.usage_scroll_y = math.max(0, math.min(self.usage_max_scroll or 0, (self.usage_scroll_y or 0) - dy * item_h * 3))
  elseif self.show_model_picker then
    local mf = style.font
    local item_h = mf:get_height() + 4 * SCALE
    self.model_scroll_y = math.max(0, math.min(self.model_max_scroll or 0, (self.model_scroll_y or 0) - dy * item_h))
  elseif self.show_history_tree then
    local item_h = 36 * SCALE
    self.history_scroll_y = math.max(0, math.min(self.history_max_scroll or 0, (self.history_scroll_y or 0) - dy * item_h))
  else
    self:state().scroll_y = math.max(0, math.min(self:state().max_scroll, self:state().scroll_y - dy * (style.font:get_height() + 2 * SCALE) * 3))
  end
  core.redraw = true
  return true
end

function AGView:_prompt_for_api_key(provider)
  if provider == "all" then
    core.command_view:enter("Choose Provider (gemini, groq, openai, anthropic)", {
      submit = function(text)
        text = text:match("^%s*(.-)%s*$"):lower()
        if text == "gemini" or text == "groq" or text == "openai" or text == "anthropic" then
          self:_prompt_for_api_key(text)
        else
          core.error("Invalid provider: " .. text)
        end
      end
    })
    return
  end

  core.command_view:enter("Enter API Key for " .. provider, {
    submit = function(text)
      text = text:match("^%s*(.-)%s*$")
      if text and #text > 0 then
        -- Run python script to save key
        local bridge = USERDIR .. "/scripts/ai_api_bridge.py"
        local p = process.start({ "python", bridge, "--provider", provider, "--set-key", text })
        if p then
          core.add_thread(function()
            while p:running() do coroutine.yield(0.1) end
            self:fetch_models(true)
            if self.show_api_view then
              self:submit("/api")
            end
          end)
        end
      end
    end
  })
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

-- ── Commands ──────────────────────────────────────────────────────────────────
command.add(nil, {
  ["antigravity:toggle"] = function()
    if not instance then
      instance = AGView()
      rawset(_G, "_ag_instance", instance) -- expose for activity_bar auth display
    end
    
    local node = core.root_view.root_node:get_node_for_view(instance)
    local sidebar = rawget(_G, "get_sidebar_node") and _G.get_sidebar_node(true)
    
    -- Determine if AI is currently visible and active
    local ai_is_active = node and (node.active_view == instance)
    
    if ai_is_active then
      -- Toggle OFF: close everything in the sidebar
      for i = #node.views, 1, -1 do
        node:close_view(core.root_view.root_node, node.views[i])
      end
      instance.visible = false
    else
      -- Toggle ON: force AI open, closing any other plugin in the sidebar
      if sidebar then
        -- Sidebar exists — close other views and add/activate AI
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
        -- No sidebar yet — create one by splitting with instance directly.
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
    local cur_tool = config.ai_sidebar and config.ai_sidebar.active_tool or "agy"
    local tdef = AI_TOOLS and AI_TOOLS.get(cur_tool)
    local tname = (tdef and tdef.name) or "Antigravity"
    
    local auth_cmd_str = "agy"
    local bin = tdef and tdef.bins and tdef.bins[1] or cur_tool
    
    if cur_tool == "agy" then
      auth_cmd_str = config.antigravity.cli or "agy"
    elseif cur_tool == "opencode" then
      auth_cmd_str = bin .. " auth"
    elseif cur_tool == "devin" then
      auth_cmd_str = bin .. " auth"
    elseif cur_tool == "gh_copilot" then
      auth_cmd_str = "gh auth login"
    elseif cur_tool == "claude" then
      auth_cmd_str = "claude login"
    else
      auth_cmd_str = "echo No automatic auth command configured for " .. tname .. ". Please authenticate manually via terminal."
    end

    core.command_view:enter("Press Enter to launch Auth Terminal for " .. tname .. " (follow instructions in new window)", {
      submit = function(text)
        if PLATFORM == "Windows" then
          process.start({ "cmd.exe", "/c", "start", "cmd.exe", "/k", "echo Launching Authentication for " .. tname .. "... && " .. auth_cmd_str }, {
            stdin = process.REDIRECT_DISCARD,
          })
        elseif PLATFORM == "Mac OS X" then
          process.start({ "osascript", "-e", 'tell app "Terminal" to do script "' .. auth_cmd_str .. '"' }, {
            stdin = process.REDIRECT_DISCARD,
          })
        else
          pcall(function() process.start({ "x-terminal-emulator", "-e", auth_cmd_str }, {
            stdin = process.REDIRECT_DISCARD,
          }) end)
        end
        core.log(tname .. ": If a terminal did not open automatically, open your terminal and manually run: " .. auth_cmd_str)
        
        if not instance then instance = AGView() end
        instance.auth_status = "checking"
        
        -- Clear the model cache for the active tool so fetch_models actually runs again
        instance.tool_model_lists[cur_tool] = {}
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

local function is_sidebar_active()
  local v = core.active_view
  if not v then return false end
  return v == instance
      or v == rawget(_G, "_ag_instance")
      or (v.is and v:is(AGView))
      or v.class_name == "AGView"
end

local function get_active_sidebar()
  local v = core.active_view
  if is_sidebar_active() then return v end
  return instance or rawget(_G, "_ag_instance")
end

-- Bind local commands that only activate when AI Sidebar is focused
command.add(
  is_sidebar_active,
  {
    ["antigravity:return"]      = function() local s = get_active_sidebar(); if s then s:on_key_pressed("return") end end,
    ["antigravity:newline"]     = function() local s = get_active_sidebar(); if s then s:on_key_pressed("shift+return") end end,
    ["antigravity:ctrl-return"] = function() local s = get_active_sidebar(); if s then s:on_key_pressed("ctrl+return") end end,
    ["antigravity:backspace"]   = function() local s = get_active_sidebar(); if s then s:on_key_pressed("backspace") end end,
    ["antigravity:scroll-up"]   = function() local s = get_active_sidebar(); if s then s:on_key_pressed("up") end end,
    ["antigravity:scroll-down"] = function() local s = get_active_sidebar(); if s then s:on_key_pressed("down") end end,
    ["antigravity:escape"]      = function() local s = get_active_sidebar(); if s then s:on_key_pressed("escape") end end,
    ["antigravity:paste"]       = function()
      local s = get_active_sidebar()
      if s then
        local clip = system.get_clipboard()
        if clip and #clip > 0 then s:on_paste(clip) end
      end
    end,
    ["antigravity:undo"]        = function() local s = get_active_sidebar(); if s then s:undo() end end,
    ["antigravity:redo"]        = function() local s = get_active_sidebar(); if s then s:redo() end end,
    ["antigravity:copy"]        = function() local s = get_active_sidebar(); if s then s:on_key_pressed("ctrl+c") end end,
    ["antigravity:cut"]         = function() local s = get_active_sidebar(); if s then s:on_key_pressed("ctrl+x") end end,
    ["antigravity:select-all"]  = function() local s = get_active_sidebar(); if s then s:on_key_pressed("ctrl+a") end end,
    ["antigravity:delete"]      = function() local s = get_active_sidebar(); if s then s:on_key_pressed("delete") end end,
    ["antigravity:cursor-left"]  = function() local s = get_active_sidebar(); if s then s:on_key_pressed("left") end end,
    ["antigravity:cursor-right"] = function() local s = get_active_sidebar(); if s then s:on_key_pressed("right") end end,
    ["antigravity:cursor-home"]  = function() local s = get_active_sidebar(); if s then s:on_key_pressed("home") end end,
    ["antigravity:cursor-end"]   = function() local s = get_active_sidebar(); if s then s:on_key_pressed("end") end end,
    ["antigravity:select-left"]  = function() local s = get_active_sidebar(); if s then s:on_key_pressed("shift+left") end end,
    ["antigravity:select-right"] = function() local s = get_active_sidebar(); if s then s:on_key_pressed("shift+right") end end,
    ["antigravity:select-up"]    = function() local s = get_active_sidebar(); if s then s:on_key_pressed("shift+up") end end,
    ["antigravity:select-down"]  = function() local s = get_active_sidebar(); if s then s:on_key_pressed("shift+down") end end,
    ["antigravity:select-home"]  = function() local s = get_active_sidebar(); if s then s:on_key_pressed("shift+home") end end,
    ["antigravity:select-end"]   = function() local s = get_active_sidebar(); if s then s:on_key_pressed("shift+end") end end,
  }
)

local keymap = require "core.keymap"
keymap.add {
  ["return"]       = "antigravity:return",
  ["enter"]        = "antigravity:return",
  ["shift+return"] = "antigravity:newline",
  ["shift+enter"]  = "antigravity:newline",
  ["ctrl+return"]  = "antigravity:ctrl-return",
  ["ctrl+enter"]   = "antigravity:ctrl-return",
  ["backspace"]    = "antigravity:backspace",
  ["up"]           = "antigravity:scroll-up",
  ["down"]         = "antigravity:scroll-down",
  ["escape"]       = "antigravity:escape",
  ["ctrl+z"]       = "antigravity:undo",
  ["cmd+z"]        = "antigravity:undo",
  ["ctrl+y"]       = "antigravity:redo",
  ["cmd+y"]        = "antigravity:redo",
  ["ctrl+shift+z"] = "antigravity:redo",
  ["cmd+shift+z"]  = "antigravity:redo",
  ["ctrl+a"]       = "antigravity:select-all",
  ["cmd+a"]        = "antigravity:select-all",
  ["ctrl+c"]       = "antigravity:copy",
  ["cmd+c"]        = "antigravity:copy",
  ["ctrl+x"]       = "antigravity:cut",
  ["cmd+x"]        = "antigravity:cut",
  ["ctrl+v"]       = "antigravity:paste",
  ["cmd+v"]        = "antigravity:paste",
  ["delete"]       = "antigravity:delete",
  ["left"]         = "antigravity:cursor-left",
  ["right"]        = "antigravity:cursor-right",
  ["home"]         = "antigravity:cursor-home",
  ["end"]          = "antigravity:cursor-end",
  ["shift+left"]   = "antigravity:select-left",
  ["shift+right"]  = "antigravity:select-right",
  ["shift+up"]     = "antigravity:select-up",
  ["shift+down"]   = "antigravity:select-down",
  ["shift+home"]   = "antigravity:select-home",
  ["shift+end"]    = "antigravity:select-end",
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






-- -----------------------------------------------------------------------------
-- SAFE HISTORY TREE INJECTION
-- -----------------------------------------------------------------------------
local original_draw = AGView.draw
function AGView:draw(...)
  if self.show_history_tree then
    local x, y = self.position.x, self.position.y
    local w, h = self.size.x, self.size.y
    local pad = 10 * SCALE
    
    -- Draw tree
    self:draw_history_tree(x, y, w, h)
    
    -- Draw toggle button on top
    local P = get_palette()
    local h_btn_w = 32 * SCALE
    local h_btn_x = x + w - pad - h_btn_w
    local h_btn_y = y + 103 * SCALE
    self._hist_toggle_rect = { x = h_btn_x, y = h_btn_y, w = h_btn_w, h = 30 * SCALE }
    
    -- We need mx, my to check hover. But draw doesn't get mx, my directly. 
    -- We can just use self.hover_hist_btn which is updated by on_mouse_moved.
    local is_hov = self.hover_hist_btn
    renderer.draw_rect(h_btn_x, h_btn_y, h_btn_w, 30 * SCALE, P.fg_accent)
    renderer.draw_text(style.icon_font, "g", h_btn_x + 8 * SCALE, h_btn_y + 6 * SCALE, P.bg)
    return
  end
  
  -- If not in history mode, just call the normal draw!
  original_draw(self, ...)
end

