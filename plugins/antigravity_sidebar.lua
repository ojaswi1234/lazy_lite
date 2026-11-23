
-- [AUTO-GENERATED CACHED COLORS FOR GC OPTIMIZATION]
local _COLOR_CACHE_0 = {142, 186, 43, 255}
local _COLOR_CACHE_1 = { 200, 60, 60, 255 }
local _COLOR_CACHE_2 = { 80, 80, 80, 255 }
local _COLOR_CACHE_3 = { 95, 140, 50, 255 }
local _COLOR_CACHE_4 = { 170, 56, 59, 255 }
local _COLOR_CACHE_5 = {255, 100, 100, 40}
local _COLOR_CACHE_6 = { 180, 180, 180, 255 }
local _COLOR_CACHE_7 = { 160, 80, 80, 180 }
local _COLOR_CACHE_8 = { 100, 150, 255, 255 }
local _COLOR_CACHE_9 = {0,0,0,180}
local _COLOR_CACHE_10 = {255, 255, 255, 10}
local _COLOR_CACHE_11 = { 120, 120, 120, 110 }
local _COLOR_CACHE_12 = {255,100,100,255}
local _COLOR_CACHE_13 = {0,0,0,255}
local _COLOR_CACHE_14 = {255, 100, 100, 255}
local _COLOR_CACHE_15 = { 100, 255, 100, 255 }
local _COLOR_CACHE_16 = { 70, 140, 220, 255 }
local _COLOR_CACHE_17 = { 60, 110, 180, 90 }
local _COLOR_CACHE_18 = {200, 100, 100, 255}
local _COLOR_CACHE_19 = { 95, 185, 85, 255 }
local _COLOR_CACHE_20 = { 255,255,255,255 }
local _COLOR_CACHE_21 = { 0,0,0,255 }
local _COLOR_CACHE_22 = {0,0,0,0}
local _COLOR_CACHE_23 = {0,0,0,150}
local _COLOR_CACHE_24 = {200,200,200,255}
local _COLOR_CACHE_25 = { 255, 100, 100, 255 }
local _COLOR_CACHE_26 = {220,60,60,255}
local _COLOR_CACHE_27 = { 255, 255, 255, 255 }
local _COLOR_CACHE_28 = {200, 50, 50, 255}
local _COLOR_CACHE_29 = { 0, 50, 150, 255 }
local _COLOR_CACHE_30 = {84, 52, 20, 255}
local _COLOR_CACHE_31 = {112, 150, 30, 255}
local _COLOR_CACHE_32 = { 0, 0, 0, 255 }
local _COLOR_CACHE_33 = {255,255,255,255}
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
  local tmp_dir = USERDIR .. PATHSEP .. "tempfiles"
  for _, file in ipairs(system.list_dir(tmp_dir) or {}) do
    if file:match("^pasted_text_.*%.txt$") then
      os.remove(tmp_dir .. PATHSEP .. file)
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
-- Lite XL's default fonts (FiraCode, etc.) have no emoji/symbol glyphs, so they
-- render as '?'. We discover and load vector outline symbol & emoji fonts,
-- combining them via renderer.font.group to guarantee clean rendering without
-- missing-glyph question marks.
local _emoji_fonts_cache = {}
local function get_emoji_font(target_sz)
  target_sz = target_sz or (style.font and (style.font.get_size and style.font:get_size() or style.font:get_height()) or 14)
  if _emoji_fonts_cache[target_sz] ~= nil then
    return _emoji_fonts_cache[target_sz] or nil
  end

  local candidates = {}
  if PLATFORM == "Windows" then
    local windir = os.getenv("WINDIR") or "C:\\Windows"
    -- Segoe UI Emoji and Segoe UI Symbol have vector TrueType outlines (glyf table)
    table.insert(candidates, windir .. "\\Fonts\\seguiemj.ttf")
    table.insert(candidates, windir .. "\\Fonts\\seguisym.ttf")
    table.insert(candidates, windir .. "\\Fonts\\arialuni.ttf")
    table.insert(candidates, USERDIR .. PATHSEP .. "fonts/NotoEmoji-Regular.ttf")
    table.insert(candidates, USERDIR .. PATHSEP .. "fonts/NotoColorEmoji.ttf")
  else
    table.insert(candidates, USERDIR .. PATHSEP .. "fonts/NotoEmoji-Regular.ttf")
    for _, p in ipairs({
      "/System/Library/Fonts/Apple Color Emoji.ttc",
      "/Library/Fonts/Apple Color Emoji.ttc",
      "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
      "/usr/share/fonts/noto/NotoColorEmoji.ttf",
      "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf",
      "/usr/share/fonts/truetype/ancient-scripts/Symbola.ttf",
    }) do table.insert(candidates, p) end
    table.insert(candidates, USERDIR .. PATHSEP .. "fonts/NotoColorEmoji.ttf")
  end

  local loaded = {}
  for _, path in ipairs(candidates) do
    local f = io.open(path, "rb")
    if f then
      f:close()
      local ok, fnt = pcall(renderer.font.load, path, target_sz)
      if ok and fnt then
        table.insert(loaded, fnt)
        -- On Windows, grouping seguiemj + seguisym covers both emoji pictographs and tech symbols
        if PLATFORM == "Windows" and #loaded >= 2 then
          break
        elseif PLATFORM ~= "Windows" and #loaded >= 1 then
          break
        end
      end
    end
  end

  local result = nil
  if #loaded > 1 then
    local ok, grp = pcall(renderer.font.group, loaded)
    result = (ok and grp) or loaded[1]
  elseif #loaded == 1 then
    result = loaded[1]
  end

  _emoji_fonts_cache[target_sz] = result or false
  return result
end

-- Font grouping helper that binds a base font with emoji/symbol fallback
local _grouped_font_cache = {}
local function get_ui_font(base_f)
  base_f = base_f or style.font
  if not base_f then return style.font end
  local sz = base_f.get_size and base_f:get_size() or base_f:get_height()
  local ef = get_emoji_font(sz)
  if not ef then return base_f end
  if _grouped_font_cache[base_f] then
    return _grouped_font_cache[base_f]
  end
  local ok, grp = pcall(renderer.font.group, { base_f, ef })
  if ok and grp then
    _grouped_font_cache[base_f] = grp
    return grp
  end
  return base_f
end

-- Returns true if the UTF-8 char starting at byte i in `s` is an emoji/symbol.
-- Consumes trailing variation selectors (U+FE00-U+FE0F), ZWJs, and skin tone modifiers.
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

  -- Comprehensive Unicode emoji and symbol ranges
  local emoji = (cp >= 0x1F300 and cp <= 0x1FAFF)   -- Misc Symbols / Pictographs / Emoticons / Supplemental / Transport
             or (cp >= 0x1F000 and cp <= 0x1F2FF)   -- Tiles, cards, flags, enclosed
             or (cp >= 0x2600  and cp <= 0x27BF)    -- Misc symbols, dingbats (✅, ❌, ⚡, ⚠️, ⚙, etc.)
             or (cp >= 0x2B00  and cp <= 0x2BFF)    -- Misc symbols & arrows (⭐, ⬇, ⬡, etc.)
             or (cp >= 0x25A0  and cp <= 0x25FF)    -- Geometric shapes (●, ■, ▲, etc.)
             or (cp >= 0x2300  and cp <= 0x23FF)    -- Misc technical (⏱, ⌛, etc.)
             or (cp >= 0x2190  and cp <= 0x21FF)    -- Arrows (←, ↑, →, ↓, ↗, etc.)
             or (cp >= 0x2900  and cp <= 0x297F)    -- Supplemental arrows
             or (cp >= 0x2000  and cp <= 0x206F)    -- General punctuation (• bullet, etc.)
             or (cp >= 0x3000  and cp <= 0x303F)    -- CJK symbols & punctuation
  if not emoji then return false, i + seq_len end

  -- Consume trailing variation selectors (U+FE00-U+FE0F: \xEF\xB8[\x80-\x8F])
  -- or skin tone modifiers or zero-width joiners so they never leak into normal text as '?'
  local next_i = i + seq_len
  while next_i <= #s do
    local nb1 = s:byte(next_i)
    if nb1 == 0xEF and s:byte(next_i+1) == 0xB8 then
      local nb3 = s:byte(next_i+2)
      if nb3 and nb3 >= 0x80 and nb3 <= 0x8F then
        next_i = next_i + 3
      else
        break
      end
    elseif nb1 == 0xE2 and s:byte(next_i+1) == 0x80 and (s:byte(next_i+2) == 0x8D or s:byte(next_i+2) == 0x8C) then
      next_i = next_i + 3
      local is_sub, sub_next = is_emoji_char(s, next_i)
      if is_sub then next_i = sub_next else break end
    elseif nb1 == 0xF0 and s:byte(next_i+1) == 0x9F and s:byte(next_i+2) == 0x8F then
      local nb4 = s:byte(next_i+3)
      if nb4 and nb4 >= 0xBB and nb4 <= 0xBF then
        next_i = next_i + 4
      else
        break
      end
    else
      break
    end
  end
  return true, next_i
end

-- Draw text handling emoji segments with the emoji/symbol font.
-- Returns the final x position (same interface as renderer.draw_text).
local function draw_text_emoji(font, text, tx, ty, col)
  if not text or text == "" then return tx end
  local sz = font and (font.get_size and font:get_size() or font:get_height()) or 14
  local ef = get_emoji_font(sz)
  if not ef then
    return renderer.draw_text(font, text, tx, ty, col)
  end
  local i = 1
  local seg_start = 1
  local cur_x = tx
  local function flush_normal(upto)
    if upto > seg_start then
      local chunk = text:sub(seg_start, upto - 1)
      -- Strip any rogue variation selectors or ZWJs
      chunk = chunk:gsub("\239\184[\128-\143]", ""):gsub("\226\128[\140-\141]", "")
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
      -- Strip variation selectors from emj so FreeType renders the pure outline
      local clean_emj = emj:gsub("\239\184[\128-\143]", ""):gsub("\226\128[\140-\141]", "")
      if clean_emj ~= "" then
        cur_x = renderer.draw_text(ef, clean_emj, cur_x, ty, col)
      end
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

-- Safely slice a UTF-8 string at codepoint boundaries so streaming typewriter
-- animations never cut multi-byte emojis or unicode sequences in half, avoiding '?' glyphs.
local function utf8_safe_sub(s, i, j)
  if not s or s == "" then return "" end
  local len = #s
  i = i or 1
  j = math.min(j or len, len)
  if j <= 0 or j < i then return "" end

  -- If j lands inside a multibyte sequence (i.e. byte j+1 is a continuation byte 0x80..0xBF)
  while j > 0 and j < len do
    local next_b = s:byte(j + 1)
    if not next_b or next_b < 0x80 or next_b >= 0xC0 then
      break
    end
    j = j - 1
  end

  -- Check if j ends on an incomplete lead byte at the end of the buffer
  local k = j
  while k > 0 and k > j - 4 do
    local b = s:byte(k)
    if b < 0x80 then
      break
    elseif b >= 0xC0 then
      local needed
      if b >= 0xF0 then needed = 4
      elseif b >= 0xE0 then needed = 3
      else needed = 2 end
      local available = j - k + 1
      if available < needed then
        j = k - 1
      end
      break
    end
    k = k - 1
  end

  if j < i then return "" end
  return s:sub(i, j)
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
  if type(bg) ~= "table" then return _COLOR_CACHE_21 end
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

local function get_model_category_badge(name)
  if not name or type(name) ~= "string" then return nil end
  local n = name:lower()

  -- 1. Reasoning / Thinking: OpenAI o1/o3/o4, DeepSeek R1, QwQ, Gemini Thinking
  if n:match("[/%-_%.]o[134]") or n:match("^o[134]") or
     n:find("r1") or n:find("reason") or n:find("qwq") or n:find("thinking") or n:find("thought") then
    return "Reasoning", { 185, 130, 255, 255 }
  end

  -- 2. Coder / Code / Codex
  if n:find("coder") or n:find("starcoder") or n:find("code") or n:find("codex") then
    return "Coder", { 80, 205, 240, 255 }
  end

  -- 3. Speed Brands & Mini variants
  if n:find("bolt") then
    return "Bolt", { 255, 195, 50, 255 }
  elseif n:find("lightning") then
    return "Lightning", { 255, 215, 0, 255 }
  elseif n:find("flash") then
    if n:find("lite") then
      return "Lite", { 240, 190, 60, 255 }
    end
    return "Flash", { 255, 180, 40, 255 }
  elseif n:find("lite") then
    return "Lite", { 240, 190, 60, 255 }
  elseif n:match("[/%-_%.:]mini") or n:match("^mini") then
    return "Mini", { 240, 180, 70, 255 }
  end

  -- 4. Omni (OpenAI GPT-4o family)
  if n:find("gpt%-4o") or n:find("chatgpt%-4o") then
    return "Omni", { 80, 220, 180, 255 }
  end

  -- 5. Pro (Gemini Pro, etc.) - checks token boundary to avoid matching 'provider'
  if n:match("[/%-_%.:]pro") or n:match("^pro") then
    return "Pro", { 130, 160, 255, 255 }
  end

  -- 6. Flagship / Heavy models (405b, 550b, 675b, 120b, 70b, ultra, super, 1t, large, gpt-4)
  if n:find("405b") or n:find("550b") or n:find("675b") or n:find("120b") or n:find("70b") or
     n:find("ultra") or n:find("super") or n:find("1t") or n:find("large") or n:find("gpt%-4") then
    return "Flagship", { 255, 110, 110, 255 }
  end

  -- 7. Fast / Small parameters / Turbo
  if n:find("nano") or n:find("xs") or n:find(":0%.5b") or n:find(":1b") or n:find(":2b") or n:find(":3b") or
     n:find("tiny") or n:find("instant") or n:find("turbo") then
    return "Fast", { 240, 180, 70, 255 }
  end

  -- 8. Preview / Exp
  if n:find("preview") then
    return "Preview", { 205, 160, 255, 255 }
  elseif n:find("exp") then
    return "Exp", { 220, 150, 240, 255 }
  end

  -- 9. Instruct / It
  if n:find("%-instruct") or n:find("instruct") or n:find("%-it") or n:find(":it") or n:find("gemma") then
    return "Instruct", { 120, 215, 140, 255 }
  end

  -- 10. Chat
  if n:find("chat") then
    return "Chat", { 100, 205, 180, 255 }
  end

  return nil, nil
end

-- Recomputed every draw — automatically tracks theme changes
local _pal_cache = nil
local _pal_sig   = nil
local function get_palette()
  local base = style.background or _COLOR_CACHE_20
  local sig  = base[1] .. "," .. base[2] .. "," .. base[3] .. (style.mossy and "M" or "")
  if sig == _pal_sig and _pal_cache then return _pal_cache end
  _pal_sig = sig

  local bg       = contrast_bg(base, 0.08)
  local bg_dark  = contrast_bg(base, 0.14)
  local bg_darker= contrast_bg(base, 0.20)
  local bg_input = contrast_bg(base, 0.04)
  local fg       = contrast_fg(bg)
  local fg_muted = muted(fg, 0.55)
  local fg_dim   = muted(fg, 0.40)
  local fg_dim   = muted(fg, 0.40)
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
    fg_dim      = fg_dim,
    fg_dim      = fg_dim,
    fg_accent   = fg_accent,
    fg_user     = fg_accent,
    fg_ai       = fg,
    fg_code     = fg,
    fg_send     = fg_send,
    fg_label    = fg_muted,
    border      = border,
    border_input= bg_btnhl,
    dot_idle    = fg_muted,
    dot_run     = _COLOR_CACHE_3,
    dot_err     = _COLOR_CACHE_4,
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
      applocal .. PATHSEP .. "agy/bin/agy.exe",
      applocal .. "\\agy\\bin\\agy.exe",
      home .. PATHSEP .. ".local/bin/agy",
      "agy",
    }) do
      local f = io.open(p, "rb")
      if f then f:close(); return p end
    end
    return "agy"
  end)(),

  target_width = 330,
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
  local plugin_dir = USERDIR .. PATHSEP .. "plugins"
  local bridge = plugin_dir .. PATHSEP .. "agy_pty_bridge.py"
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
        table.insert(folders, { type = "dir", full_path = target_dir .. f .. PATHSEP, name = f .. PATHSEP, badge = "[DIR]", display = "[DIR]  " .. f .. PATHSEP })
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



-- Cached typography fonts for markdown rendering
local _heading_fonts = {}
local _bold_font = nil

local function get_bold_font()
  if _bold_font == nil then
    local bold_candidates = {
      USERDIR .. "/fonts/FiraCodeiScript-Bold.ttf",
      USERDIR .. "/fonts/JetBrainsMono-Bold.ttf",
      USERDIR .. "/fonts/Outfit-Bold.ttf",
    }
    if PLATFORM == "Windows" then
      local windir = os.getenv("WINDIR") or "C:\\Windows"
      table.insert(bold_candidates, windir .. "\\Fonts\\consolab.ttf")
      table.insert(bold_candidates, windir .. "\\Fonts\\seguisb.ttf")
    end
    for _, path in ipairs(bold_candidates) do
      local f = io.open(path, "rb")
      if f then
        f:close()
        local sz = style.font and (style.font.get_size and style.font:get_size() or style.font:get_height()) or (15 * (SCALE or 1))
        local ok, fnt = pcall(renderer.font.load, path, sz)
        if ok and fnt then _bold_font = fnt; break end
      end
    end
    if not _bold_font then
      _bold_font = style.font
    end
    _bold_font = get_ui_font(_bold_font)
  end
  return _bold_font
end

local function get_heading_font(level)
  local base_size = style.font and (style.font.get_size and style.font:get_size() or style.font:get_height()) or (15 * (SCALE or 1))
  local scales = {
    [1] = 1.35,
    [2] = 1.20,
    [3] = 1.10,
    [4] = 1.00,
  }
  local s = scales[level] or 1.00
  local target_size = math.floor(base_size * s)
  local key = tostring(target_size)
  if not _heading_fonts[key] then
    local bfont = get_bold_font()
    local ok, fnt = pcall(function() return bfont:copy(target_size) end)
    if not ok or not fnt then
      ok, fnt = pcall(function() return style.font:copy(target_size) end)
    end
    local raw_fnt = (ok and fnt) and fnt or (style.big_font or style.font)
    _heading_fonts[key] = get_ui_font(raw_fnt)
  end
  return _heading_fonts[key]
end

-- Wrap text into lines that fit within max_w pixels using given font
local function parse_inline(text)
  local segments = {}
  local s_idx = 1
  while s_idx <= #text do
    local bi_s, bi_e = text:find("%*%*%*.-%*%*%*", s_idx)
    local b_s, b_e   = text:find("%*%*.-%*%*", s_idx)
    local c_s, c_e   = text:find("`.-`", s_idx)
    local l_s, l_e   = text:find("%[.-%]%([^%)]+%)", s_idx) -- [link](url)
    local i_s, i_e   = text:find("%*[^%*\n]+%*", s_idx)     -- *italic*
    local u_s, u_e   = text:find("_[^_\n]+_", s_idx)        -- _italic_

    local next_s, next_e, type
    local min_s = math.huge

    if bi_s and bi_s < min_s then min_s = bi_s; next_s, next_e, type = bi_s, bi_e, "bold" end
    if b_s and b_s < min_s then min_s = b_s; next_s, next_e, type = b_s, b_e, "bold" end
    if c_s and c_s < min_s then min_s = c_s; next_s, next_e, type = c_s, c_e, "code" end
    if l_s and l_s < min_s then min_s = l_s; next_s, next_e, type = l_s, l_e, "link" end
    if i_s and i_s < min_s and text:sub(i_s, i_s + 1) ~= "**" then
      min_s = i_s; next_s, next_e, type = i_s, i_e, "italic"
    end
    if u_s and u_s < min_s then
      min_s = u_s; next_s, next_e, type = u_s, u_e, "italic"
    end

    if next_s then
      if next_s > s_idx then table.insert(segments, { text = text:sub(s_idx, next_s - 1), type = "normal" }) end

      local inner_text = text:sub(next_s, next_e)
      if type == "bold" then
        if inner_text:sub(1, 3) == "***" and inner_text:sub(-3) == "***" then
          table.insert(segments, { text = inner_text:sub(4, -4), type = "bold" })
        else
          table.insert(segments, { text = inner_text:sub(3, -3), type = "bold" })
        end
      elseif type == "italic" then
        table.insert(segments, { text = inner_text:sub(2, -2), type = "italic" })
      elseif type == "code" then
        table.insert(segments, { text = inner_text:sub(2, -2), type = "code" })
      elseif type == "link" then
        local label, url = inner_text:match("%[(.-)%]%(([^%)]+)%)")
        if label and label:match("^`.-`$") then
          label = label:sub(2, -2)
          table.insert(segments, { text = label, type = "code_link", url = url })
        elseif label then
          table.insert(segments, { text = label, type = "link", url = url })
        else
          table.insert(segments, { text = inner_text, type = "normal" })
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

local function wrap_segments(segments, base_font, bold_font, code_font, max_w)
  local lines = {}
  local cur_line = {}
  local cur_w = 0
  
  local function get_font(type)
    if type == "code" or type == "code_link" then
      return get_ui_font(code_font)
    elseif type == "bold" and bold_font then
      return get_ui_font(bold_font)
    end
    return get_ui_font(base_font)
  end
  
  local function push_word(word, type, url)
    local f = get_font(type)
    local w = f:get_width(word)
    local is_code_type = (type == "code" or type == "code_link")
    local extra_pad = is_code_type and math.floor(6 * (SCALE or 1)) or 0
    local total_w = w + extra_pad
    
    if total_w > max_w then
      if cur_w > 0 then
        table.insert(lines, cur_line)
        cur_line = {}
        cur_w = 0
      end
      local chunk = ""
      for char in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local cw = f:get_width(chunk .. char) + extra_pad
        if cw > max_w then
          if #chunk > 0 then
            table.insert(lines, {{ text = chunk, type = type, font = f, width = f:get_width(chunk) + extra_pad, url = url }})
          end
          chunk = char
        else
          chunk = chunk .. char
        end
      end
      if #chunk > 0 then
        local cw = f:get_width(chunk) + extra_pad
        table.insert(cur_line, { text = chunk, type = type, font = f, width = cw, url = url })
        cur_w = cw
      end
      return
    end

    if cur_w + total_w > max_w and cur_w > 0 then
      table.insert(lines, cur_line)
      cur_line = {}
      cur_w = 0
      -- drop leading space on new line if normal text
      if word:match("^%s+$") then return end
    end
    if cur_w == 0 and #lines > 0 and word:match("^%s+$") then return end

    table.insert(cur_line, { text = word, type = type, font = f, width = total_w, url = url })
    cur_w = cur_w + total_w
  end

  for _, seg in ipairs(segments) do
    if seg.type == "code" or seg.type == "code_link" then
      push_word(seg.text, seg.type, seg.url)
    else
      local leading_space = seg.text:match("^(%s+)")
      if leading_space then
        push_word(leading_space, seg.type, seg.url)
      end
      for word in seg.text:gmatch("%S+%s*") do
        push_word(word, seg.type, seg.url)
      end
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

local function parse_table_block(table_text, base_font, bold_font, code_font, max_w)
  local raw_lines = {}
  for line in (table_text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:match("^%s*(.-)%s*$")
    if #line > 0 then
      table.insert(raw_lines, line)
    end
  end
  if #raw_lines == 0 then return nil end

  local function split_row(line)
    local inner = line
    if inner:sub(1, 1) == "|" then inner = inner:sub(2) end
    if inner:sub(-1) == "|" then inner = inner:sub(1, -2) end
    local cells = {}
    for cell in (inner .. "|"):gmatch("(.-)|") do
      table.insert(cells, cell:match("^%s*(.-)%s*$") or "")
    end
    return cells
  end

  local all_rows = {}
  for _, line in ipairs(raw_lines) do
    table.insert(all_rows, split_row(line))
  end

  if #all_rows == 0 then return nil end

  local headers = all_rows[1]
  local aligns = {}
  local data_start = 2

  -- Check if second row is divider row: |:---|:---:|---:|
  if #all_rows >= 2 then
    local is_sep = true
    local row2 = all_rows[2]
    for _, cell in ipairs(row2) do
      if not cell:match("^:?%-+:?$") and cell ~= "" then
        is_sep = false
        break
      end
    end
    if is_sep then
      data_start = 3
      for c_idx, cell in ipairs(row2) do
        local left = cell:sub(1, 1) == ":"
        local right = cell:sub(-1) == ":"
        if left and right then
          aligns[c_idx] = "center"
        elseif right then
          aligns[c_idx] = "right"
        else
          aligns[c_idx] = "left"
        end
      end
    end
  end

  local num_cols = #headers
  if num_cols == 0 then return nil end
  for i = 1, num_cols do
    if not aligns[i] then aligns[i] = "left" end
  end

  local rows = {}
  for i = data_start, #all_rows do
    local r = all_rows[i]
    local row_cells = {}
    for c = 1, num_cols do
      table.insert(row_cells, r[c] or "")
    end
    table.insert(rows, row_cells)
  end

  local font = base_font or style.font
  local bfont = bold_font or font
  local cfont = code_font or style.code_font

  local col_widths = {}
  local parsed_headers = {}
  for c = 1, num_cols do
    local segs = parse_inline(headers[c])
    local w = 0
    for _, s in ipairs(segs) do
      local sf = (s.type == "code" or s.type == "code_link") and cfont or bfont
      w = w + sf:get_width(s.text)
    end
    col_widths[c] = math.max(col_widths[c] or 0, w)
    parsed_headers[c] = segs
  end

  local parsed_rows = {}
  for r_idx, r in ipairs(rows) do
    local row_segs = {}
    for c = 1, num_cols do
      local segs = parse_inline(r[c])
      local w = 0
      for _, s in ipairs(segs) do
        local sf = (s.type == "code" or s.type == "code_link") and cfont or ((s.type == "bold") and bfont or font)
        w = w + sf:get_width(s.text)
      end
      col_widths[c] = math.max(col_widths[c] or 0, w)
      row_segs[c] = segs
    end
    table.insert(parsed_rows, row_segs)
  end

  local pad_x = math.floor(10 * (SCALE or 1))
  local total_w = 0
  for c = 1, num_cols do
    col_widths[c] = col_widths[c] + 2 * pad_x
    total_w = total_w + col_widths[c]
  end

  local avail_w = math.max(100, max_w - math.floor(16 * (SCALE or 1)))
  if total_w < avail_w and total_w > 0 then
    local diff = avail_w - total_w
    for c = 1, num_cols do
      local add = math.floor(diff * (col_widths[c] / total_w))
      col_widths[c] = col_widths[c] + add
    end
    local sum = 0
    for c = 1, num_cols do sum = sum + col_widths[c] end
    if sum < avail_w and num_cols > 0 then
      col_widths[num_cols] = col_widths[num_cols] + (avail_w - sum)
    end
    total_w = avail_w
  elseif total_w > avail_w and total_w > 0 then
    local min_col_w = math.floor(45 * (SCALE or 1))
    local min_total = min_col_w * num_cols
    if avail_w > min_total then
      local ratio = avail_w / total_w
      local sum = 0
      for c = 1, num_cols do
        col_widths[c] = math.max(min_col_w, math.floor(col_widths[c] * ratio))
        sum = sum + col_widths[c]
      end
      if sum < avail_w and num_cols > 0 then
        col_widths[num_cols] = col_widths[num_cols] + (avail_w - sum)
      end
      total_w = avail_w
    end
  end

  local hdr_h = math.floor(bfont:get_height() + 14 * (SCALE or 1))
  local row_h = math.floor(font:get_height() + 12 * (SCALE or 1))
  local tbl_h = hdr_h + #rows * row_h

  return {
    type = "table",
    headers = headers,
    parsed_headers = parsed_headers,
    aligns = aligns,
    rows = rows,
    parsed_rows = parsed_rows,
    col_widths = col_widths,
    total_w = total_w,
    total_h = tbl_h,
    hdr_h = hdr_h,
    row_h = row_h,
    pad_x = pad_x,
    raw_text = table_text,
  }
end

local function parse_blocks(text, base_font, code_font, max_w)
  local blocks = {}
  local is_code = false
  local cur_text = ""
  local cur_lang = ""
  local bold_font = get_bold_font()
  
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
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
  
  -- post-process text blocks line by line for headers, tables, dividers, quotes, and lists
  local final_blocks = {}
  for _, blk in ipairs(blocks) do
    if blk.type == "code" then
      table.insert(final_blocks, blk)
    else
      local cur_table = ""
      
      local function flush_table()
        if #cur_table > 0 then
          cur_table = cur_table:gsub("\n$", "")
          local tbl_blk = parse_table_block(cur_table, base_font, bold_font, code_font, max_w)
          if tbl_blk then
            table.insert(final_blocks, tbl_blk)
          else
            table.insert(final_blocks, { type = "code", lang = "txt", raw_lines = wrap_raw_text(code_font, cur_table, max_w) })
          end
          cur_table = ""
        end
      end
      
      for line in (blk.raw .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        if line:match("^%s*%[AGENT%]%s*Using tool:") or line:match("^%s*Using tool:") then
          -- ignore leaked raw tool execution lines from history
        else
          local is_table = line:match("^%s*|.*|%s*$") ~= nil
          if is_table then
            cur_table = cur_table .. line .. "\n"
          else
            flush_table()
            if #line > 0 then
              -- Check for divider line: --- or *** or ___
              if line:match("^%s*[%-%*_][%-%*_][%-%*_]+%s*$") then
                table.insert(final_blocks, { type = "divider" })
              -- Check for blockquote: > text
              elseif line:match("^%s*>%s?(.*)") then
                local q_text = line:match("^%s*>%s?(.*)")
                local segments = parse_inline(q_text)
                local wrapped = wrap_segments(segments, style.font, bold_font, style.code_font, max_w - 16 * (SCALE or 1))
                table.insert(final_blocks, { type = "quote", wrapped_lines = wrapped })
              else
                local header = line:match("^%s*(#+)%s")
                local list_bullet = line:match("^%s*[%-%*]%s+(.*)")
                local list_num_digits, list_num_text = line:match("^%s*(%d+)[%.)]%s*(.*)")
                local level = header and #header or 0
                
                local list_prefix = nil
                local clean_line = line
                if header then
                  clean_line = line:gsub("^%s*#+%s*", "")
                elseif list_bullet then
                  clean_line = list_bullet
                  list_prefix = "• "
                elseif list_num_digits and list_num_text then
                  clean_line = list_num_text
                  -- Strip accidental double-numbering (e.g. '1. 1. text' or '1. 1 text')
                  clean_line = clean_line:gsub("^%s*%d+[%.)]%s*", "")
                  list_prefix = list_num_digits .. ". "
                end
                
                local f = (level > 0) and get_heading_font(level) or (base_font or style.font)
                local lh = (level > 0) and math.floor(f:get_height() * 1.3) or (f:get_height() + 2 * (SCALE or 1))
                local prefix_w = list_prefix and f:get_width(list_prefix) or 0
                local segments = parse_inline(clean_line)
                local wrapped = wrap_segments(segments, f, bold_font, code_font, max_w - prefix_w)
                
                table.insert(final_blocks, {
                  type = "paragraph",
                  level = level,
                  font = f,
                  lh = lh,
                  list_prefix = list_prefix,
                  wrapped_lines = wrapped,
                })
              end
            else
              table.insert(final_blocks, { type = "empty" })
            end
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
        usage = u1 .. PATHSEP .. u2
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
            usage = u1 .. PATHSEP .. u2
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
    if id == "cloud_api" then
      local tc = self:_tool_cfg("cloud_api")
      local prov = tc.active_provider or (tc.selected_model and tc.selected_model:match("^([^/]+)/"))
      if prov then
        local filtered = {}
        for _, m in ipairs(self.tool_model_lists["cloud_api"]) do
          if m.name and m.name:match("^" .. prov .. "[/\\]") then
            table.insert(filtered, m)
          end
        end
        if #filtered > 0 then
          self.model_list = filtered
          return
        end
      end
    end
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

function AGView:get_name() return "Aether" end

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
  local brain_path = base_dir .. PATHSEP .. ".gemini/antigravity-cli/brain"
  
  local files = system.list_dir(brain_path)
  if not files then
    self:_add_session("ai", "Could not find brain directory at " .. brain_path)
    self:state().scroll_to_bottom = true
    core.redraw = true
    return
  end
  
  -- Parse conversation metadata for accurate titles, steps, and agents
  local cache_path = base_dir .. PATHSEP .. ".gemini/antigravity-cli/cache/conversation_metadata.json"
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

  local pinned_path = base_dir .. PATHSEP .. ".gemini/antigravity-cli/pinned_cids.txt"
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
      local path = brain_path .. PATHSEP .. cid .. PATHSEP .. ".system_generated/logs/transcript.jsonl"
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
    local tool_name = (tool and tool.name) or "Aether Engine"
    local help_text = "Built-in commands:\n  `/help` - Show this message\n  `/clear` - Clear chat history & active swarm\n  `/api` - Manage API Keys & MCP Tools\n  `/team clear` - Disband active swarm (keeps chat history)\n  `/usage` - Show model usage\n  `/resume` - Resume a past conversation"
    core.add_thread(function()
      local p = process.start({"python", USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py", "--get-installed-skills"})
      if p then
          local out = ""
          while p:running() do
              local chunk = p:read_stdout()
              if chunk then out = out .. chunk end
              coroutine.yield(0.1)
          end
          local chunk = p:read_stdout()
          if chunk then out = out .. chunk end
          
          local ok_j, json = pcall(require, "plugins.lsp.json")
          if ok_j and out and out ~= "" then
            local ok, skills = pcall(json.decode, out)
            if ok and type(skills) == "table" and #skills > 0 then
              help_text = help_text .. "\n\nInstalled AI Personas:\n"
              for _, s in ipairs(skills) do
                 help_text = help_text .. "  `/" .. s.id .. "` - " .. (s.title or "Custom Skill") .. "\n"
              end
            end
          end
      end
      
      help_text = help_text .. "\n\nActive tool: " .. tool_name .. "\n\n(Type any other prompt to chat with the AI)"
      table.insert(self:state().sessions, { role = "user", text = prompt })
      table.insert(self:state().sessions, { role = "ai", text = help_text })
      core.redraw = true
    end)
    return
  elseif prompt == "/clear" then
    self:state().sessions = {}
    self:state().has_session = false
    self:state().status = "idle"
    self:state().cid = nil
    self.active_skill = nil
    os.remove(USERDIR .. PATHSEP .. "scripts/.team_config.json")
    core.redraw = true
    return
  elseif prompt == "/team clear" then
    os.remove(USERDIR .. PATHSEP .. "scripts/.team_config.json")
    self:_add_session("ai", "Active team swarm disbanded successfully. You are now speaking to the single base model.")
    core.redraw = true
    return
  elseif prompt == "/api" then
    self.show_api_view = true
    local parsed_data = (self.api_key_status and self.api_key_status.data) or {}
    self.api_key_status = { status = "loading", data = parsed_data }
    
    local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
    core.add_thread(function()
      local p, err = process.start({ "python", bridge, "--validate-keys" })
      if not p then
        self.api_key_status = { status = "error", err = err, data = parsed_data }
        return
      end
      local out = ""
      local err_out = ""
      while p:running() do
        local chunk = p:read_stdout(4096)
        if chunk and #chunk > 0 then
          out = out .. chunk
          for line in (out .. "\n"):gmatch("([^\r\n]+)\r?\n") do
            local k, v = line:match("^([^:]+):%s*(.+)$")
            if k and v then
              parsed_data[k] = v:gsub("%s+$", "")
            end
          end
          self.api_key_status = { status = "loading", data = parsed_data }
          core.redraw = true
        end
        local err_chunk = p:read_stderr(4096)
        if err_chunk and #err_chunk > 0 then err_out = err_out .. err_chunk end
        coroutine.yield(0.05)
      end
      while true do
        local chunk = p:read_stdout(4096)
        if not chunk or #chunk == 0 then break end
        out = out .. chunk
      end
      while true do
        local err_chunk = p:read_stderr(4096)
        if not err_chunk or #err_chunk == 0 then break end
        err_out = err_out .. err_chunk
      end
      for line in (out .. "\n"):gmatch("([^\r\n]+)\r?\n") do
        local k, v = line:match("^([^:]+):%s*(.+)$")
        if k and v then
          parsed_data[k] = v:gsub("%s+$", "")
        end
      end
      if next(parsed_data) == nil and err_out ~= "" then
        self.api_key_status = { status = "error", err = err_out, data = parsed_data }
      else
        self.api_key_status = { status = "done", data = parsed_data }
      end
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
      self.usage_text = "Cloud AI (API) Usage:\n\nBecause you are using a direct API integration, usage tracking and billing are managed by your respective API provider.\n\nPlease check your provider's dashboard to view your token quotas and limits:\n\n- Google (Gemini): https://aistudio.google.com/app/plan_information\n- Groq: https://console.groq.com/settings/billing\n- NVIDIA (NIM): https://build.nvidia.com\n- OpenAI: https://platform.openai.com/settings/organization/billing/overview\n- Anthropic: https://console.anthropic.com/settings/billing\n- Ollama Cloud: https://ollama.com/settings/billing"
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

  -- Generate a unique thread ID if this is a new conversation
  if not self:state().cid then
    local count = rawget(_G, "_ag_cid_counter") or 0
    count = count + 1
    rawset(_G, "_ag_cid_counter", count)
    self:state().cid = "thread_" .. tostring(os.time()) .. "_" .. tostring(math.floor(os.clock()*10000)) .. "_" .. tostring(count)
  end

  -- Expand any @pasted_text tokens into absolute file paths
  local tmp_dir = USERDIR .. PATHSEP .. "tempfiles"
  local expanded_prompt = prompt_text:gsub("@(pasted_text[%w_%-%.]+%.txt)", function(f)
    local fp = (tmp_dir .. PATHSEP .. f):gsub("\\", "/")
    return string.format(" [Read this pasted text from file: %s] ", fp)
  end)

  local fname = nil
  local av = core.active_view
  if av and av.doc then fname = av.doc.filename end

  local full_prompt = expanded_prompt
  if fname and tool_id == "agy" then
    full_prompt = string.format("Regarding the active file %s: %s", fname, expanded_prompt)
  end
  if config.ai_sidebar and config.ai_sidebar.read_only then
    full_prompt = "[READ-ONLY MODE: You are currently operating in strict read-only mode. You are STRICTLY FORBIDDEN from editing, modifying, creating, or deleting any files on disk, and you must NOT run mutating commands. Provide explanations, analysis, or proposed code snippets in chat only, WITHOUT touching or modifying the user's workspace files.]\n\n" .. full_prompt
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
  self:state()._chat_start_time    = system.get_time()
  self:state().progress_status     = nil
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
    local is_auto = config.ai_sidebar and config.ai_sidebar.autopilot or false
    argv = tool.build_run_argv({
      bin          = bin,
      prompt       = full_prompt,
      model        = self:_active_model(),
      session_id   = self:state().cid,   -- tool-specific session id (for OpenCode, Devin)
      has_session  = self:state().has_session,
      project_dir  = project_root,
      extra_files  = nil,
      autopilot    = is_auto,
      enable_tools = is_auto,
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
      if cfg.auto_skip_permissions and not (config.ai_sidebar and config.ai_sidebar.read_only) then
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
  local log = io.open(USERDIR .. PATHSEP .. "antigravity_debug.log", "a")
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
    self:state()._chat_start_time = system.get_time()
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
      local brain_path = base_dir .. PATHSEP .. ".gemini/antigravity-cli/brain/" .. item.cid
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
      local pinned_path = base_dir .. PATHSEP .. ".gemini/antigravity-cli/pinned_cids.txt"
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
          self:_sync_model_list()
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
        core.redraw = true
        while true do
          local out = tab.process:read_stdout(65536)
          if not out or #out == 0 then break end
          out = out:gsub("%[STATUS:([^\r\n]*%])\r?\n?", function(st_block)
            local st = st_block:match("^(.-)%]%s*$") or st_block:gsub("%]%s*$", "")
            tab.progress_status = st
            return ""
          end)
          out = out:gsub("[\r\n]*%-%-%- Finished %-%-%-[\r\n]*", "")
          out = out:gsub("%[AGENT%]%s*Using tool:[^\n]*\r?\n?", "")
          out = out:gsub("Using tool:[^\n]*\r?\n?", "")
          out = out:gsub("<tool_call.-</tool_call>%s*", "")
          out = out:gsub("<function.-</function>%s*", "")
          out = out:gsub("<function_call.-</function_call>%s*", "")
          out = out:gsub("%[TOOL_CALLS%].-%]%s*", "")
          out = out:gsub("%[WARNING%][^\r\n]*\r?\n?", "")
          out = out:gsub("%[DIAGNOSTIC%][^\r\n]*\r?\n?", "")
          out = out:gsub("\r?\n%s*%]%s*\r?\n", "\n")
          out = out:gsub("^%s*%]%s*\r?\n", "")
          out = out:gsub("%s*%]%s*$", "")
          out = out:gsub("\n\n\n+", "\n\n")
          if #out > 0 then
            tab._ai_buf = (tab._ai_buf or "") .. out
          end
        end
        while true do
          local out = tab.process:read_stderr(65536)
          if not out or #out == 0 then break end
          tab._err_buf = (tab._err_buf or "") .. out
        end

        local rc = tab.process:returncode()
        if rc ~= nil then
          -- Final drain
          while true do
            local out = tab.process:read_stdout(65536)
            if not out or #out == 0 then break end
            out = out:gsub("%[STATUS:([^\r\n]*%])\r?\n?", function(st_block)
              local st = st_block:match("^(.-)%]%s*$") or st_block:gsub("%]%s*$", "")
              tab.progress_status = st
              return ""
            end)
            out = out:gsub("[\r\n]*%-%-%- Finished %-%-%-[\r\n]*", "")
            out = out:gsub("%[AGENT%]%s*Using tool:[^\n]*\r?\n?", "")
            out = out:gsub("Using tool:[^\n]*\r?\n?", "")
            out = out:gsub("<tool_call.-</tool_call>%s*", "")
            out = out:gsub("<function.-</function>%s*", "")
            out = out:gsub("<function_call.-</function_call>%s*", "")
            out = out:gsub("%[TOOL_CALLS%].-%]%s*", "")
            out = out:gsub("%[WARNING%][^\r\n]*\r?\n?", "")
            out = out:gsub("%[DIAGNOSTIC%][^\r\n]*\r?\n?", "")
            out = out:gsub("\r?\n%s*%]%s*\r?\n", "\n")
            out = out:gsub("^%s*%]%s*\r?\n", "")
            out = out:gsub("%s*%]%s*$", "")
            out = out:gsub("\n\n\n+", "\n\n")
            if #out > 0 then
              tab._ai_buf = (tab._ai_buf or "") .. out
            end
          end
          while true do
            local out = tab.process:read_stderr(65536)
            if not out or #out == 0 then break end
            tab._err_buf = (tab._err_buf or "") .. out
          end
          tab.process = nil
          tab.status = (rc == 0) and "idle" or "error"
          tab.progress_status = nil
          
          -- Automatically refresh the Chat Memory Tree if it's currently open
          if self.show_history_tree then
              self:fetch_history()
          end
          if tab._ai_buf then
            tab._ai_buf = tab._ai_buf:gsub("[\r\n]*%-%-%- Finished %-%-%-[\r\n]*", "")
            tab._ai_buf = tab._ai_buf:gsub("\r?\n%s*%]%s*\r?\n", "\n")
            tab._ai_buf = tab._ai_buf:gsub("^%s*%]%s*\r?\n", "")
            tab._ai_buf = tab._ai_buf:gsub("%s*%]%s*$", "")
            tab._ai_buf = tab._ai_buf:gsub("^%s+", ""):gsub("%s+$", "")
          end
          if not tab._ai_buf or tab._ai_buf:match("^%s*$") then
            local elapsed = os.time() - (tab._chat_started_at or os.time())
            local cur_tool = config.ai_sidebar and config.ai_sidebar.active_tool or "agy"
            local hint
            if tab._err_buf and tab._err_buf:match("%S") then
              hint = string.format("### ⚠️ Process Terminated (Code %s)\n\n```\n%s\n```", tostring(rc), tab._err_buf:match("^%s*(.-)%s*$") or tab._err_buf)
            elseif rc == 0 then
              hint = "*(The model completed the request without generating text.)*"
            elseif cur_tool == "agy" then
              hint = "### ⚠️ Authentication Required\n\nClick the **AGY Auth** button in the sidebar or run `agy auth` in a terminal."
            else
              local tdef = AI_TOOLS and AI_TOOLS.get(cur_tool)
              local tname = (tdef and tdef.name) or cur_tool
              local bin_cmd = (tdef and tdef.bins and tdef.bins[1]) or cur_tool
              hint = string.format(
                "### ⚠️ %s Exited Unexpectedly (Code %s)\n\n" ..
                "The process closed without producing output (after %.0fs).\n\n" ..
                "**Recommended Solutions:**\n" ..
                "• Verify `%s` is installed and in your system PATH.\n" ..
                "• Run `%s --help` in a terminal to check configuration.\n" ..
                "• Check your API key and network connection.",
                tname, tostring(rc), elapsed, bin_cmd, bin_cmd)
            end
            tab._ai_buf = hint
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
          core.log("[Aether] CLI timed out — agy install may be required.")
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
        tab.sessions[#tab.sessions].text = utf8_safe_sub(tab._ai_buf, 1, tab._ai_displayed_chars or 0)
        tab.sessions[#tab.sessions].blocks = nil -- invalidate cache
        tab.scroll_to_bottom = true
        core.redraw = true
      end
    end
  end
end

-- ── Model list disk cache ─────────────────────────────────────────────────────
local MODEL_CACHE_PATH = USERDIR .. PATHSEP .. "model_cache.json"
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
        usage = u1 .. PATHSEP .. u2
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
            usage = u1 .. PATHSEP .. u2
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
    home .. PATHSEP .. ".gemini/antigravity-cli/settings.json",
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

function AGView:fetch_marketplace()
  if self._is_fetching then return end
  self._is_fetching = true
  self.marketplace_skills = "loading"
  core.redraw = true
  core.add_thread(function()
      local ok_json, json = pcall(require, "plugins.lsp.json")
      
      -- Synchronously update installed maps & counts for badges and status
      self.installed_skills_map = {}
      self.installed_tools_map = {}
      self.installed_skills_count = 0
      self.installed_tools_count = 0
      if ok_json then
        local f_sk = io.open(USERDIR .. PATHSEP .. "scripts/local_skills.json", "r")
        if f_sk then
          local sk_raw = f_sk:read("*a")
          f_sk:close()
          local ok_s, sk_data = pcall(json.decode, sk_raw)
          if ok_s and type(sk_data) == "table" then
            self.installed_skills_count = #sk_data
            for _, s in ipairs(sk_data) do
              if s.id then self.installed_skills_map[s.id] = true end
            end
          end
        end
        local f_mc = io.open(USERDIR .. PATHSEP .. "scripts/mcp_config.json", "r")
        if f_mc then
          local mc_raw = f_mc:read("*a")
          f_mc:close()
          local ok_m, mc_data = pcall(json.decode, mc_raw)
          if ok_m and type(mc_data) == "table" and mc_data.mcpServers then
            local count = 0
            for k, _ in pairs(mc_data.mcpServers) do
              self.installed_tools_map[k] = true
              count = count + 1
              if not self.tool_health_map or not self.tool_health_map[k] then
                self:test_tool_health(k)
              end
            end
            self.installed_tools_count = count
          end
        end
      end

      local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
      local arg = ""
      if self.show_tools_tab then
          arg = self.show_installed_skills and "--get-installed-tools" or "--get-marketplace-tools"
      else
          arg = self.show_installed_skills and "--get-installed-skills" or "--get-marketplace-skills"
      end
      
      local tmp_file = USERDIR .. PATHSEP .. "scripts/.market_tmp.json"
      local cmd = {"python", bridge, arg, "--out-file", tmp_file}
      if not self.show_installed_skills then
         self.market_page = self.market_page or 1
         table.insert(cmd, "--page")
         table.insert(cmd, tostring(self.market_page))
         if self.market_source and self.market_source ~= "" then
           table.insert(cmd, "--source")
           table.insert(cmd, self.market_source)
         end
      end
      
      if self.market_search_query and self.market_search_query ~= "" then
          table.insert(cmd, "--search")
          table.insert(cmd, self.market_search_query)
      end
      local p, err = process.start(cmd)
      if p then
          while p:running() do coroutine.yield(0.1) end
      end
      
      local full = ""
      local f = io.open(tmp_file, "r")
      if f then
          full = f:read("*a")
          f:close()
      end
      
      local ok, res = false, nil
      if ok_json and full and full ~= "" then
        ok, res = pcall(json.decode, full)
      end
      
      if ok and type(res) == "table" then
        if self.show_installed_skills then
          self.marketplace_skills = res
        else
          self.marketplace_skills = res.skills or res.data or {}
          self.market_total_pages = res.total_pages or 1
        end
      else
        self.marketplace_skills = "error"
      end
      
      self._is_fetching = false
      core.redraw = true
    end)
  end

function AGView:add_custom_source_repo(repo_str)
  if not repo_str or repo_str == "" then return end
  core.add_thread(function()
    local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
    local p = process.start({"python", bridge, "--add-source-repo", repo_str})
    if p then
      while p:running() do coroutine.yield(0.1) end
    end
    core.log("[Aether] Added marketplace source: " .. repo_str)
    self.market_source = "github"
    self.market_page = 1
    self.market_scroll_y = 0
    self:fetch_marketplace()
    core.redraw = true
  end)
end


function AGView:open_tool_config(tool_item)
  local tool_id = type(tool_item) == "table" and tool_item.id or tool_item
  local tool_title = (type(tool_item) == "table" and (tool_item.title or tool_item.name)) or tool_id
  local ok_json, json = pcall(require, "plugins.lsp.json")

  self.active_tool_config = {
    id = tool_id,
    title = tool_title,
    is_loading = true,
    test_result = nil,
    config = {
      command = "npx",
      args = {"-y", "@smithery/cli", "run", tool_id},
      env = {},
      known_keys = {}
    }
  }
  core.redraw = true

  core.add_thread(function()
    local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
    local tmp_file = USERDIR .. PATHSEP .. "scripts/.cfg_tmp.json"
    local p = process.start({"python", bridge, "--get-tool-config", tool_id, "--out-file", tmp_file})
    if p then
      while p:running() do coroutine.yield(0.1) end
    end
    local f = io.open(tmp_file, "r")
    if f then
      local raw = f:read("*a"); f:close()
      if ok_json then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == "table" and self.active_tool_config and self.active_tool_config.id == tool_id then
          self.active_tool_config.config = data
        end
      end
    end
    if self.active_tool_config and self.active_tool_config.id == tool_id then
      self.active_tool_config.is_loading = false
      self:test_tool_health(tool_id)
    end
    core.redraw = true
  end)
end

function AGView:test_tool_health(tool_id, on_done)
  self.tool_health_map = self.tool_health_map or {}
  self.tool_health_map[tool_id] = { status = "testing", message = "Testing handshake..." }
  if self.active_tool_config and self.active_tool_config.id == tool_id then
    self.active_tool_config.test_result = { status = "testing", message = "Testing handshake..." }
  end
  core.redraw = true

  core.add_thread(function()
    local ok_json, json = pcall(require, "plugins.lsp.json")
    local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
    local tmp_file = USERDIR .. PATHSEP .. "scripts/.test_tmp.json"
    local p = process.start({"python", bridge, "--test-tool", tool_id, "--out-file", tmp_file})
    if p then
      while p:running() do coroutine.yield(0.1) end
    end
    local res = { status = "error", message = "Process failed to execute." }
    local f = io.open(tmp_file, "r")
    if f then
      local raw = f:read("*a"); f:close()
      if ok_json then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == "table" then res = data end
      end
    end
    self.tool_health_map[tool_id] = res
    if self.active_tool_config and self.active_tool_config.id == tool_id then
      self.active_tool_config.test_result = res
    end
    if on_done then on_done(res) end
    core.redraw = true
  end)
end

function AGView:save_tool_config(tool_id, new_cfg, on_done)
  core.add_thread(function()
    local ok_json, json = pcall(require, "plugins.lsp.json")
    if not ok_json then return end
    local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
    local tmp_file = USERDIR .. PATHSEP .. "scripts/.save_tmp.json"
    local f = io.open(tmp_file, "w")
    if f then
      f:write(json.encode(new_cfg))
      f:close()
    end
    local p = process.start({"python", bridge, "--save-tool-config", tool_id, "--config-data", "FILE:" .. tmp_file})
    if p then
      while p:running() do coroutine.yield(0.1) end
    end
    core.log("[Aether] Saved MCP configuration for " .. tool_id)
    self:test_tool_health(tool_id, function(res)
      self:fetch_marketplace()
      if on_done then on_done(res) end
    end)
  end)
end

function AGView:launch_tool_browser_auth(tool_id)
  core.add_thread(function()
    local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
    local p = process.start({"python", bridge, "--open-tool-auth", tool_id})
    if p then
      while p:running() do coroutine.yield(0.1) end
    end
    core.log("[Aether] Launched browser authorization for " .. tool_id)
  end)
end

function AGView:uninstall_skill(skill_id)
  core.add_thread(function()
      local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
      local flag = self.show_tools_tab and "--uninstall-tool" or "--uninstall-skill"
      local p, err = process.start({"python", bridge, flag, skill_id})
      if p then
          while p:running() do coroutine.yield(0.1) end
          core.log("Uninstalled: " .. skill_id)
          self:fetch_marketplace()
          core.redraw = true
      end
  end)
end

function AGView:install_skill(skill_input)
  local skill_obj = nil
  if type(skill_input) == "table" then
    skill_obj = skill_input
  else
    for _, s in ipairs(self.marketplace_skills or {}) do
      if s.id == skill_input then
        skill_obj = s
        break
      end
    end
  end
  if not skill_obj then return end

  if self.show_tools_tab then
    -- For MCP tools: immediately register and open the Pre-Flight Configuration Wizard!
    core.add_thread(function()
      local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
      local p = process.start({"python", bridge, "--install-tool", skill_obj.id})
      if p then
        while p:running() do coroutine.yield(0.1) end
      end
      self.installed_tools_map = self.installed_tools_map or {}
      self.installed_tools_map[skill_obj.id] = true
      core.log("[Aether] Launching Setup Wizard for " .. (skill_obj.title or skill_obj.id) .. "...")
      self:open_tool_config(skill_obj)
      self:fetch_marketplace()
      core.redraw = true
    end)
  else
    local ok_json, json = pcall(require, "plugins.lsp.json")
    if not ok_json then return end
    core.add_thread(function()
      local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
      local tmp_file = USERDIR .. PATHSEP .. "scripts/.tmp_skill.json"
      local f = io.open(tmp_file, "w")
      if f then
        f:write(json.encode(skill_obj))
        f:close()
      end
      local p = process.start({"python", bridge, "--install-skill", "FILE:" .. tmp_file})
      while p:running() do coroutine.yield(0.1) end
      core.log("Installed AI Skill: " .. (skill_obj.title or "Custom Skill"))
      self:fetch_marketplace()
    end)
  end
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
  local acol = self:state().status == "running" and _COLOR_CACHE_19
            or self:state().status == "error"   and _COLOR_CACHE_1
            or _COLOR_CACHE_16
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
  local cur_elapsed = system.get_time() - (self:state()._chat_start_time or system.get_time())
  local status_str = self:state().status == "running"
    and string.format("%.1fs...", cur_elapsed)
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
  local total_pill_w = num_segs * seg_w
  
  -- Draw pill container background
  local max_pills_w = math.max(10 * SCALE, (x + w - status_w - 12 * SCALE) - seg_x)
  core.push_clip_rect(seg_x, seg_y, max_pills_w, seg_h + 4 * SCALE)
  renderer.draw_rect(seg_x, seg_y, total_pill_w, seg_h, P.bg_input)
  draw_rect_outline(seg_x, seg_y, total_pill_w, seg_h, P.border)
  
  -- Draw segments
  for i=1, num_segs do
    local t = det_list[i] or { id="agy", name="Aether", short="AET" }
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
  core.pop_clip_rect()

  -- ── ROW 1 right: status text ─────────────────────────────────────────
  local status_str = self:state().status == "running"
    and string.format("%.1fs...", cur_elapsed)
    or  self:state().status == "error" and "error"
    or  "ready"
  local scol = self:state().status == "running" and { acol[1], acol[2], acol[3], 210 }
            or self:state().status == "error"   and P.dot_err
            or P.fg_muted
  local status_draw_x = x + w - sf:get_width(status_str) - 8 * SCALE
  renderer.draw_rect(status_draw_x - 4 * SCALE, row1_y, sf:get_width(status_str) + 12 * SCALE, fh1, P.bg_darker)
  renderer.draw_text(sf, status_str,
    status_draw_x,
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
    draw_rect_outline(bx, by, pill_w, pill_h, hl and P.fg_accent or { P.border[1], P.border[2], P.border[3], 120 })

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
      local sel_color = style.selection or _COLOR_CACHE_17
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
  local attach_bg = self.hover_attach and P.bg_btn_hl or _COLOR_CACHE_22
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
  local ro_lbl = config.ai_sidebar.read_only and "🔒 RO" or "RO"
  local ro_w = small_font:get_width(ro_lbl) + 16 * SCALE
  local ro_x = send_x - 4 * SCALE - ro_w
  
  -- Autopilot Toggle (Right aligned)
  local auto_lbl = config.ai_sidebar.autopilot and "⚡ Auto" or "Auto"
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

  local m_bg = self.hover_model_btn and P.bg_btn_hl or _COLOR_CACHE_22
  local m_clip_w = math.max(0, auto_x - 4 * SCALE - mx)
  core.push_clip_rect(mx, my, m_clip_w, mh)
  renderer.draw_rect(mx, my, mw, mh, m_bg)
  renderer.draw_text(small_font, model_lbl, mx + 8 * SCALE, my + math.floor((mh - small_font:get_height())/2),
    self.hover_model_btn and P.fg_accent or P.fg_muted)
  core.pop_clip_rect()
  self._model_rect = { x = mx, y = my, w = math.min(mw, m_clip_w), h = mh }

  -- Draw Autopilot
  local auto_bg = config.ai_sidebar.autopilot and { common.color "#2D5A38" } or (self.hover_auto_btn and P.bg_btn_hl or _COLOR_CACHE_22)
  local auto_fg = config.ai_sidebar.autopilot and { common.color "#B8BB26" } or P.fg_muted
  renderer.draw_rect(auto_x, my, auto_w, mh, auto_bg)
  draw_rect_outline(auto_x, my, auto_w, mh, config.ai_sidebar.autopilot and { common.color "#B8BB26" } or P.border)
  renderer.draw_text(small_font, auto_lbl, auto_x + 8 * SCALE, my + math.floor((mh - small_font:get_height())/2), auto_fg)
  self._auto_rect = { x = auto_x, y = my, w = auto_w, h = mh }

  -- Draw Read-Only
  local ro_bg = config.ai_sidebar.read_only and { common.color "#6B4E26" } or (self.hover_ro_btn and P.bg_btn_hl or _COLOR_CACHE_22)
  local ro_fg = config.ai_sidebar.read_only and { common.color "#FABD2F" } or P.fg_muted
  renderer.draw_rect(ro_x, my, ro_w, mh, ro_bg)
  draw_rect_outline(ro_x, my, ro_w, mh, config.ai_sidebar.read_only and { common.color "#FABD2F" } or P.border)
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
    renderer.draw_rect(ix, iy, 8 * SCALE, 8 * SCALE, _COLOR_CACHE_33)
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

  -- Cloud API injected controls & Timeline Button
  self._cloud_ctrl_rects = {}
  local h_btn_w = 32 * SCALE
  local right_bound = x + w - pad
  local h_btn_x = right_bound - h_btn_w
  local h_btn_y = cur_y + math.floor((tab_h - 30 * SCALE) / 2)
  
  -- Inject Tools and Skills to the left of the timeline button
  local active_id = config.ai_sidebar.active_tool or "agy"
  if active_id == "cloud_api" then
    -- Draw separator
    local sep_x = h_btn_x - 4 * SCALE
    renderer.draw_rect(sep_x, h_btn_y + 6 * SCALE, 1, 18 * SCALE, P.border)
    
    -- Draw + Skill button
    local skill_txt = "+ Skill"
    local sw = sf:get_width(skill_txt) + 12 * SCALE
    local sx = sep_x - 4 * SCALE - sw
    local col = self.hover_cloud_skill and P.bg_btn_hl or P.bg_btn
    renderer.draw_rect(sx, h_btn_y, sw, 30 * SCALE, col)
    draw_rect_outline(sx, h_btn_y, sw, 30 * SCALE, P.border)
    renderer.draw_text(sf, skill_txt, sx + 6 * SCALE, h_btn_y + math.floor((30 * SCALE - sf:get_height()) / 2), P.fg)
    table.insert(self._cloud_ctrl_rects, {id="skill", x=sx, y=h_btn_y, w=sw, h=30 * SCALE})
    
    -- Draw Tools toggle
    local tool_txt = self.enable_tools and "MCP: ON" or "MCP: OFF"
    local tw = sf:get_width(tool_txt) + 12 * SCALE
    local tx = sx - 4 * SCALE - tw
    local tcol = self.hover_cloud_tools and P.bg_btn_hl or P.bg_btn
    renderer.draw_rect(tx, h_btn_y, tw, 30 * SCALE, tcol)
    draw_rect_outline(tx, h_btn_y, tw, 30 * SCALE, P.border)
    renderer.draw_text(sf, tool_txt, tx + 6 * SCALE, h_btn_y + math.floor((30 * SCALE - sf:get_height()) / 2), P.fg)
    table.insert(self._cloud_ctrl_rects, {id="tools", x=tx, y=h_btn_y, w=tw, h=30 * SCALE})
    
    -- Draw Team toggle
    local team_txt = "AI Team"
    local team_w = sf:get_width(team_txt) + 12 * SCALE
    local team_x = tx - 4 * SCALE - team_w
    local team_col = self.hover_cloud_team and P.bg_btn_hl or P.bg_btn
    renderer.draw_rect(team_x, h_btn_y, team_w, 30 * SCALE, team_col)
    draw_rect_outline(team_x, h_btn_y, team_w, 30 * SCALE, P.border)
    renderer.draw_text(sf, team_txt, team_x + 6 * SCALE, h_btn_y + math.floor((30 * SCALE - sf:get_height()) / 2), P.fg)
    table.insert(self._cloud_ctrl_rects, {id="team", x=team_x, y=h_btn_y, w=team_w, h=30 * SCALE})

    -- Update the wrap boundary
    right_bound = team_x
  else
    right_bound = h_btn_x
  end

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
    if cur_x + tw > right_bound - 8 * SCALE and cur_x > line_start_x then
      cur_x = line_start_x
      cur_y = cur_y + tab_h + 4 * SCALE
    end
    
    local is_active = (i == self.active_idx)
    local tab_fg = is_active and P.fg_accent or P.fg_muted
    
    -- Draw text
    renderer.draw_text(style.font, label, cur_x + 8 * SCALE, cur_y + math.floor((tab_h - style.font:get_height())/2), tab_fg)
    
    -- Draw active pill and underline
    if is_active then
      renderer.draw_rect(cur_x, cur_y + 2 * SCALE, tw, tab_h - 4 * SCALE, { P.fg_accent[1], P.fg_accent[2], P.fg_accent[3], 35 })
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
  self._insert_rects = {}
  self._starter_card_rects = {}
  self._link_rects = {}

  if #self:state().sessions == 0 then
    local center_y = chat_top + math.max(16 * SCALE, math.floor(chat_h * 0.10)) - self:state().scroll_y
    local bf = style.big_font or style.font
    local sf = style.font
    local sel_name = self:_active_model() or "Default"

    -- 1. Hero Title with accent icon
    local title = "✦ Aether AI"
    local tw_title = bf:get_width(title)
    local tx = x + math.floor((w - tw_title) / 2)
    renderer.draw_text(bf, title, tx, center_y, P.fg_accent)
    center_y = center_y + bf:get_height() + 4 * SCALE

    -- 2. Subtitle with active model pill
    local sub = "Ready to assist • [" .. sel_name .. "]"
    local sw = sf:get_width(sub)
    local sx = x + math.floor((w - sw) / 2)
    renderer.draw_text(sf, sub, sx, center_y, P.fg_muted)
    center_y = center_y + sf:get_height() + 18 * SCALE

    -- 3. Prompt Starter Cards (Interactive)
    local starters = {
      { icon = "✦", title = "Explain Active Code", prompt = "/explain", desc = "Walkthrough architecture & logic" },
      { icon = "⚡", title = "Find Bugs & Edge Cases", prompt = "Analyze the open file for bugs, edge cases, and performance bottlenecks.", desc = "Static sanity & security check" },
      { icon = "🧪", title = "Generate Unit Tests", prompt = "Write comprehensive unit tests for the functions in this file.", desc = "Coverage & regression mocks" },
      { icon = "🛠", title = "Suggest Clean Refactor", prompt = "Suggest a clean, modular refactoring to improve readability and structure.", desc = "Simplify & modernize code" },
    }

    local card_w = math.min(w - 2 * pad - 8 * SCALE, 340 * SCALE)
    local card_h = 38 * SCALE
    local card_x = x + math.floor((w - card_w) / 2)

    for c_i, st in ipairs(starters) do
      local cy = center_y + (c_i - 1) * (card_h + 8 * SCALE)
      local is_hov = (self.hover_starter_idx == c_i)
      local c_bg = is_hov and P.bg_btn_hl or P.bg_btn
      local border_col = is_hov and P.fg_accent or { P.border[1], P.border[2], P.border[3], 90 }

      -- Card Background & Outline
      renderer.draw_rect(card_x, cy, card_w, card_h, c_bg)
      draw_rect_outline(card_x, cy, card_w, card_h, border_col)

      -- Left Accent Pip on Hover
      if is_hov then
        renderer.draw_rect(card_x, cy, 3 * SCALE, card_h, P.fg_accent)
      end

      -- Card Text
      local title_x = card_x + 12 * SCALE
      local title_y = cy + 4 * SCALE
      renderer.draw_text(sf, st.icon .. "  " .. st.title, title_x, title_y, is_hov and P.fg_accent or P.fg)

      local desc_font = style.small_font or sf
      local desc_y = title_y + sf:get_height() + 1 * SCALE
      renderer.draw_text(desc_font, st.desc, title_x + 16 * SCALE, desc_y, P.fg_muted)

      table.insert(self._starter_card_rects, {
        x = card_x, y = cy, w = card_w, h = card_h, prompt = st.prompt, idx = c_i
      })
    end

    -- Bottom hint
    local hint = "Type /help for slash commands • @ to mention files"
    local hw = sf:get_width(hint)
    local hx = x + math.floor((w - hw) / 2)
    local hy = center_y + #starters * (card_h + 8 * SCALE) + 14 * SCALE
    renderer.draw_text(sf, hint, hx, hy, P.fg_dim)
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
      elseif blk.type == "table" then
        msg_h = msg_h + blk.total_h + 16 * SCALE
      elseif blk.type == "divider" then
        msg_h = msg_h + 16 * SCALE
      elseif blk.type == "quote" then
        local f = style.font
        local lh = math.floor(f:get_height() * 1.25)
        msg_h = msg_h + #blk.wrapped_lines * lh + 8 * SCALE
      elseif blk.type == "empty" then
        msg_h = msg_h + lh_f
      elseif blk.type == "paragraph" then
        local f = blk.font or ((blk.level > 0) and get_heading_font(blk.level) or style.font)
        local lh = blk.lh or (f:get_height() + 2 * SCALE)
        local top_m = (blk.level == 1 and 20 * SCALE) or (blk.level == 2 and 14 * SCALE) or (blk.level == 3 and 8 * SCALE) or 0
        local bot_m = (blk.level == 1 and 10 * SCALE) or (blk.level == 2 and 8 * SCALE) or (blk.level == 3 and 4 * SCALE) or 0
        msg_h = msg_h + #blk.wrapped_lines * lh + top_m + bot_m
      end
    end
    msg_h = math.max(lh_f + 2 * msg_pad, msg_h)

    local is_running_ai = (self:state().status == "running" and not is_user and sess == self:state().sessions[#self:state().sessions])
    local loader_h = style.code_font:get_height() + 8 * SCALE
    if is_running_ai then
      if sess.text == "" or #sess.blocks == 0 then
        msg_h = loader_h + 2 * msg_pad
      else
        msg_h = msg_h + loader_h + 8 * SCALE
      end
    end

    local has_hitl = not is_user and sess.text:find("[HITL_APPROVAL_REQUIRED]", 1, true)
    if has_hitl and is_running_ai then
      msg_h = msg_h + 36 * SCALE
    end

    -- Role label badge
    if ty + msg_h + lh_f >= chat_top and ty <= chat_bot then
      local tid  = config.ai_sidebar.active_tool or "agy"
      local tdef = AI_TOOLS.get(tid)

      local role_name = is_user and "YOU" or (tdef and tdef.name:upper() or "AETHER")
      local role_lbl = is_user and role_name or ("✦ " .. role_name)
      local badge_h = style.font:get_height() + 4 * SCALE
      local badge_w = style.font:get_width(role_lbl) + 12 * SCALE
      local badge_y = math.max(chat_top, math.min(ty, chat_bot - badge_h))
      local badge_bg = is_user and P.bg_btn or { P.fg_accent[1], P.fg_accent[2], P.fg_accent[3], 45 }
      local badge_fg = is_user and P.fg_muted or P.fg_accent

      renderer.draw_rect(x + pad, badge_y, badge_w, badge_h, badge_bg)
      draw_rect_outline(x + pad, badge_y, badge_w, badge_h, { P.border[1], P.border[2], P.border[3], 70 })
      renderer.draw_text(style.font, role_lbl, x + pad + 6 * SCALE, badge_y + 2 * SCALE, badge_fg)
    end
    ty = ty + style.font:get_height() + 6 * SCALE

    -- Message card container
    if ty + msg_h >= chat_top and ty <= chat_bot then
      if is_user then
        -- User gets a clean distinct card
        renderer.draw_rect(x + pad, ty, msg_w, msg_h, P.bg_user_msg or P.bg_btn)
        draw_rect_outline(x + pad, ty, msg_w, msg_h, { P.border[1], P.border[2], P.border[3], 90 })
      else
        -- AI gets a soft ambient background with accent spine
        renderer.draw_rect(x + pad, ty, msg_w, msg_h, { P.bg_ai_msg[1], P.bg_ai_msg[2], P.bg_ai_msg[3], 35 })
        renderer.draw_rect(x + pad, ty, 3 * SCALE, msg_h, P.fg_accent)
        draw_rect_outline(x + pad, ty, msg_w, msg_h, { P.border[1], P.border[2], P.border[3], 50 })
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

          -- Apply / Insert button directly into open editor
          local ins_id = tostring(_) .. "_ins_" .. tostring(_b)
          local is_inserted = (self.copy_flash_idx == ins_id)
          local iw = is_inserted and (style.font:get_width("Applied!") + 10 * SCALE) or (style.font:get_width("Apply") + 10 * SCALE)
          local i_x = c_x - iw - 8 * SCALE

          if is_inserted then
            renderer.draw_text(style.font, "Applied!", i_x, line_y + math.floor((hdr_h - style.font:get_height())/2), P.fg_accent)
          else
            local is_hov_ins = (self.hover_insert_idx == ins_id)
            if is_hov_ins then
              renderer.draw_rect(i_x - 2 * SCALE, line_y + 2 * SCALE, iw, hdr_h - 4 * SCALE, P.bg_btn_hl)
              draw_rect_outline(i_x - 2 * SCALE, line_y + 2 * SCALE, iw, hdr_h - 4 * SCALE, P.border)
            end
            renderer.draw_text(style.font, "Apply", i_x + 3 * SCALE, line_y + math.floor((hdr_h - style.font:get_height())/2), is_hov_ins and P.fg_accent or P.fg_muted)
          end

          table.insert(self._insert_rects, {
            x = i_x - 4 * SCALE, y = line_y, w = iw + 8 * SCALE, h = hdr_h,
            text = table.concat(blk.raw_lines, "\n"), idx = ins_id
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
        
      elseif blk.type == "table" then
        line_y = line_y + 8 * SCALE
        local tbl_x = x + pad + 4 * SCALE
        local tbl_w = math.min(msg_w - 8 * SCALE, blk.total_w)
        local tbl_h = blk.total_h
        local hdr_h = blk.hdr_h
        local row_h = blk.row_h
        local pad_x = blk.pad_x
        local bfont = get_bold_font()

        -- Check visibility
        if line_y + tbl_h >= chat_top and line_y <= chat_bot then
          -- Table background & outer border
          renderer.draw_rect(tbl_x, line_y, tbl_w, tbl_h, P.bg_btn)
          draw_rect_outline(tbl_x, line_y, tbl_w, tbl_h, P.border)

          -- Header background
          renderer.draw_rect(tbl_x, line_y, tbl_w, hdr_h, P.bg_darker)
          -- Header bottom border
          renderer.draw_rect(tbl_x, line_y + hdr_h - 1, tbl_w, 1, P.border)

          -- Draw table copy button in top right of header
          local t_id = tostring(_) .. "_tbl_" .. tostring(_b)
          local is_copied = (self.copy_flash_idx == t_id)
          local cw = is_copied and (style.font:get_width("Copied!") + 8 * SCALE) or 16 * SCALE
          local c_x = tbl_x + tbl_w - cw - 6 * SCALE
          local c_y = line_y + math.floor((hdr_h - 14 * SCALE) / 2)
          if is_copied then
            renderer.draw_text(style.font, "Copied!", c_x, c_y, P.fg_accent)
          else
            local ix = c_x + math.floor((cw - 8 * SCALE) / 2)
            local iy = c_y
            draw_rect_outline(ix + 2 * SCALE, iy, 6 * SCALE, 6 * SCALE, P.fg_muted)
            renderer.draw_rect(ix, iy + 2 * SCALE, 6 * SCALE, 6 * SCALE, P.bg_darker)
            draw_rect_outline(ix, iy + 2 * SCALE, 6 * SCALE, 6 * SCALE, P.fg_muted)
          end
          table.insert(self._copy_rects, {
            x = c_x - 4 * SCALE, y = line_y, w = cw + 8 * SCALE, h = hdr_h,
            text = blk.raw_text, idx = t_id
          })

          -- Header columns
          local cur_cx = tbl_x
          for c = 1, #blk.col_widths do
            local cw = blk.col_widths[c]
            local align = blk.aligns[c] or "left"
            local segs = blk.parsed_headers[c] or {}
            
            local seg_w = 0
            for _, s in ipairs(segs) do
              local sf = (s.type == "code" or s.type == "code_link") and style.code_font or bfont
              seg_w = seg_w + sf:get_width(s.text)
            end

            local tx = cur_cx + pad_x
            if align == "center" then
              tx = cur_cx + math.floor((cw - seg_w) / 2)
            elseif align == "right" then
              tx = cur_cx + cw - seg_w - pad_x
            end

            core.push_clip_rect(cur_cx + 2 * SCALE, line_y, cw - 4 * SCALE, hdr_h)
            local sx = tx
            for _, s in ipairs(segs) do
              local sf = (s.type == "code" or s.type == "code_link") and style.code_font or bfont
              local scol = P.fg_accent
              draw_text_emoji(sf, s.text, sx, line_y + math.floor((hdr_h - sf:get_height()) / 2), scol)
              sx = sx + sf:get_width(s.text)
            end
            core.pop_clip_rect()

            -- Column divider line in header
            if c < #blk.col_widths then
              renderer.draw_rect(cur_cx + cw - 1, line_y, 1, hdr_h, P.border)
            end
            cur_cx = cur_cx + cw
          end

          -- Data rows
          for r_idx, row_segs in ipairs(blk.parsed_rows) do
            local ry = line_y + hdr_h + (r_idx - 1) * row_h
            if ry + row_h >= chat_top and ry <= chat_bot then
              -- Zebra striping (even rows have subtle contrast)
              if r_idx % 2 == 0 then
                renderer.draw_rect(tbl_x, ry, tbl_w, row_h, { P.bg_darker[1], P.bg_darker[2], P.bg_darker[3], 70 })
              end
              -- Horizontal divider line between rows
              if r_idx < #blk.parsed_rows then
                renderer.draw_rect(tbl_x, ry + row_h - 1, tbl_w, 1, { P.border[1], P.border[2], P.border[3], 60 })
              end

              local cur_cx = tbl_x
              for c = 1, #blk.col_widths do
                local cw = blk.col_widths[c]
                local align = blk.aligns[c] or "left"
                local segs = row_segs[c] or {}

                local seg_w = 0
                for _, s in ipairs(segs) do
                  local sf = (s.type == "code" or s.type == "code_link") and style.code_font or ((s.type == "bold") and bfont or style.font)
                  seg_w = seg_w + sf:get_width(s.text)
                end

                local tx = cur_cx + pad_x
                if align == "center" then
                  tx = cur_cx + math.floor((cw - seg_w) / 2)
                elseif align == "right" then
                  tx = cur_cx + cw - seg_w - pad_x
                end

                core.push_clip_rect(cur_cx + 4 * SCALE, ry, cw - 8 * SCALE, row_h)
                local sx = tx
                for _, s in ipairs(segs) do
                  local sf = (s.type == "code" or s.type == "code_link") and style.code_font or ((s.type == "bold") and bfont or style.font)
                  local scol = (s.type == "bold") and P.fg_accent or fg_col
                  if s.type == "code" or s.type == "code_link" then
                    -- Pill badge for inline code inside table cell
                    local pill_pad = 2 * SCALE
                    local pill_h = sf:get_height() + 2 * SCALE
                    local pill_w = sf:get_width(s.text) + 2 * pill_pad
                    local pill_y = ry + math.floor((row_h - pill_h) / 2)
                    renderer.draw_rect(sx - pill_pad, pill_y, pill_w, pill_h, P.bg_darker)
                    draw_rect_outline(sx - pill_pad, pill_y, pill_w, pill_h, { P.border[1], P.border[2], P.border[3], 90 })
                    scol = style.syntax["keyword"] or P.fg_accent
                  end
                  draw_text_emoji(sf, s.text, sx, ry + math.floor((row_h - sf:get_height()) / 2), scol)
                  sx = sx + sf:get_width(s.text)
                end
                core.pop_clip_rect()

                -- Vertical divider line between columns
                if c < #blk.col_widths then
                  renderer.draw_rect(cur_cx + cw - 1, ry, 1, row_h, { P.border[1], P.border[2], P.border[3], 60 })
                end
                cur_cx = cur_cx + cw
              end
            end
          end
        end

        line_y = line_y + tbl_h + 8 * SCALE

      elseif blk.type == "divider" then
        line_y = line_y + 4 * SCALE
        if line_y + 8 * SCALE >= chat_top and line_y <= chat_bot then
          local div_x = x + pad + msg_pad
          local div_w = msg_w - 2 * msg_pad
          renderer.draw_rect(div_x, line_y + 4 * SCALE, div_w, 1 * SCALE, { P.border[1], P.border[2], P.border[3], 100 })
        end
        line_y = line_y + 12 * SCALE

      elseif blk.type == "quote" then
        local f = style.font
        local lh = math.floor(f:get_height() * 1.25)
        local q_h = #blk.wrapped_lines * lh
        line_y = line_y + 4 * SCALE
        if line_y + q_h >= chat_top and line_y <= chat_bot then
          local q_x = x + pad + msg_pad
          renderer.draw_rect(q_x, line_y, 3 * SCALE, q_h, P.fg_accent)
          renderer.draw_rect(q_x + 3 * SCALE, line_y, msg_w - 2 * msg_pad - 3 * SCALE, q_h, { P.bg_btn[1], P.bg_btn[2], P.bg_btn[3], 40 })
          for l_idx, w_line in ipairs(blk.wrapped_lines) do
            local lx = q_x + 10 * SCALE
            for _, seg in ipairs(w_line) do
              draw_text_emoji(seg.font, seg.text, lx, line_y + (l_idx - 1) * lh, P.fg_muted)
              lx = lx + seg.width
            end
          end
        end
        line_y = line_y + q_h + 4 * SCALE

      elseif blk.type == "empty" then
        line_y = line_y + lh_f
        
      elseif blk.type == "paragraph" then
        local f = blk.font or ((blk.level > 0) and get_heading_font(blk.level) or style.font)
        local lh = blk.lh or (f:get_height() + 2 * SCALE)
        local l_col = (blk.level > 0) and P.fg_accent or fg_col
        local bfont = get_bold_font()

        -- Extra spacing above headers to separate sections (synchronized with height calc)
        local top_m = (blk.level == 1 and 20 * SCALE) or (blk.level == 2 and 14 * SCALE) or (blk.level == 3 and 8 * SCALE) or 0
        local bot_m = (blk.level == 1 and 10 * SCALE) or (blk.level == 2 and 8 * SCALE) or (blk.level == 3 and 4 * SCALE) or 0
        line_y = line_y + top_m

        for l_idx, w_line in ipairs(blk.wrapped_lines) do
          if line_y + lh >= chat_top and line_y <= chat_bot then
            local lx = x + pad + msg_pad
            local para_avail_w = math.max(10*SCALE, msg_w - 2 * msg_pad)
            core.push_clip_rect(lx, line_y, para_avail_w, lh)
            if blk.list_prefix and l_idx == 1 then
              draw_text_emoji(f, blk.list_prefix, lx, line_y, P.fg_accent)
              lx = lx + f:get_width(blk.list_prefix)
            elseif blk.list_prefix then
              lx = lx + f:get_width(blk.list_prefix)
            end
            
            for _, seg in ipairs(w_line) do
              local cfont = seg.font
              local ccol = l_col
              if seg.type == "code" or seg.type == "code_link" then
                -- Pill badge for inline code
                local pill_pad = math.floor(3 * (SCALE or 1))
                local pill_h = cfont:get_height() + math.floor(2 * (SCALE or 1))
                local pill_y = line_y - math.floor(1 * (SCALE or 1))
                local pill_w = seg.width
                renderer.draw_rect(lx, pill_y, pill_w, pill_h, P.bg_btn)
                draw_rect_outline(lx, pill_y, pill_w, pill_h, { P.border[1], P.border[2], P.border[3], 120 })
                ccol = style.syntax["keyword"] or P.fg_accent
                draw_text_emoji(cfont, seg.text, lx + pill_pad, line_y, ccol)
                if seg.url and self._link_rects then
                  table.insert(self._link_rects, { x = lx, y = line_y, w = pill_w, h = pill_h, url = seg.url })
                  if self.hover_link_url == seg.url then
                    renderer.draw_rect(lx + pill_pad, line_y + cfont:get_height() - 1, pill_w - 2 * pill_pad, 1, ccol)
                  end
                end
                lx = lx + pill_w
              else
                if seg.type == "bold" then
                  ccol = P.fg_accent
                elseif seg.type == "italic" then
                  ccol = P.fg_muted
                elseif seg.type == "link" then
                  ccol = style.syntax["function"] or P.fg_accent
                  if seg.url and self._link_rects then
                    table.insert(self._link_rects, { x = lx, y = line_y, w = seg.width, h = lh, url = seg.url })
                    if self.hover_link_url == seg.url then
                      renderer.draw_rect(lx, line_y + cfont:get_height() - 1, seg.width, 1, ccol)
                    end
                  end
                end
                draw_text_emoji(cfont, seg.text, lx, line_y, ccol)
                lx = lx + seg.width
              end
            end
            core.pop_clip_rect()
          end
          line_y = line_y + lh
        end

        -- Horizontal divider line under section titles (H1 and H2)
        if blk.level == 1 then
          local div_x = x + pad + msg_pad
          local div_w = msg_w - 2 * msg_pad
          local div_y = line_y + 3 * SCALE
          if div_y >= chat_top and div_y <= chat_bot then
            renderer.draw_rect(div_x, div_y, div_w, 2 * SCALE, { P.fg_accent[1], P.fg_accent[2], P.fg_accent[3], 130 })
          end
        elseif blk.level == 2 then
          local div_x = x + pad + msg_pad
          local div_w = msg_w - 2 * msg_pad
          local div_y = line_y + 2 * SCALE
          if div_y >= chat_top and div_y <= chat_bot then
            renderer.draw_rect(div_x, div_y, div_w, 1 * SCALE, { P.border[1], P.border[2], P.border[3], 140 })
          end
        end

        line_y = line_y + bot_m
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

    -- Modern dynamic step loader capsule pill on active AI message while running
    if is_running_ai then
      local elapsed = system.get_time() - (self:state()._chat_start_time or system.get_time())
      
      -- Determine provider name for context
      local cur_tool = config.ai_sidebar.active_tool or "agy"
      local prov_name = "AI"
      if cur_tool == "cloud_api" then
        local tc = self:_tool_cfg("cloud_api")
        local p = tc.active_provider or (tc.selected_model and tc.selected_model:match("^([^/]+)/"))
        if p == "nvidia" then prov_name = "NVIDIA"
        elseif p == "gemini" then prov_name = "Gemini"
        elseif p == "groq" then prov_name = "Groq"
        elseif p == "openai" then prov_name = "OpenAI"
        elseif p == "ollama" then prov_name = "Ollama"
        elseif p then prov_name = p:sub(1,1):upper() .. p:sub(2)
        else prov_name = "Cloud"
        end
      elseif cur_tool == "ollama" then
        prov_name = "Ollama"
      elseif cur_tool == "agy" then
        prov_name = "Aether"
      end

      local function compact_status(st)
        if not st or st == "" then return "" end
        st = st:gsub("%.+$", "")
        
        -- Handle "[AGENT] Using tool: foo" or "Using tool: foo"
        local agent_t = st:match("Using tool:%s*([%w_]+)")
        if agent_t then
          if agent_t == "read_file" then return "Reading file"
          elseif agent_t == "write_file" then return "Writing file"
          elseif agent_t == "local_shell" then return "Running command"
          elseif agent_t == "web_search" then return "Searching web"
          else return "Running " .. agent_t:gsub("^mcp__", ""):gsub("^tool_", "")
          end
        end

        -- Handle "Reading <filename> (<pct>%) [step]"
        local f, pct, step = st:match("^Reading%s+(.-)%s+%((%d+%%)%)(.*)")
        if f and pct then
          f = f:match("^%s*(.-)%s*$")
          if #f > 18 then f = f:sub(1, 8) .. "..." .. f:sub(-7) end
          return string.format("Reading %s (%s)%s", f, pct, step or "")
        end
        
        -- Handle "Reading <filename>"
        local f = st:match("^Reading%s+(.-)$")
        if f and not f:find("%(") then
          f = f:match("^%s*(.-)%s*$")
          if #f > 18 then f = f:sub(1, 8) .. "..." .. f:sub(-7) end
          return string.format("Reading %s", f)
        end
        
        -- Handle "Writing <filename> (<lines> lines) [step]"
        local f, lines, step = st:match("^Writing%s+(.-)%s+%((%d+%s+lines)%)(.*)")
        if f and lines then
          f = f:match("^%s*(.-)%s*$")
          if #f > 18 then f = f:sub(1, 8) .. "..." .. f:sub(-7) end
          return string.format("Writing %s (%s)%s", f, lines, step or "")
        end
        local f = st:match("^Writing%s+(.-)$")
        if f and not f:find("%(") then
          f = f:match("^%s*(.-)%s*$")
          if #f > 18 then f = f:sub(1, 8) .. "..." .. f:sub(-7) end
          return string.format("Writing %s", f)
        end
        
        -- Handle "Scanning directory (<cmd>) [step]"
        local cmd, step = st:match("^Scanning directory%s+%((.-)%)(.*)")
        if cmd then
          if #cmd > 16 then cmd = cmd:sub(1, 13) .. "..." end
          return string.format("Scanning directory (%s)%s", cmd, step or "")
        end

        -- Handle "Running <cmd> [step]"
        local cmd, step = st:match("^Running%s+(.-)%s*(%[.*%])$")
        if cmd then
          if #cmd > 16 then cmd = cmd:sub(1, 13) .. "..." end
          return string.format("Running %s %s", cmd, step)
        end
        local cmd = st:match("^Running%s+(.-)$")
        if cmd then
          if #cmd > 16 then cmd = cmd:sub(1, 13) .. "..." end
          return string.format("Running %s", cmd)
        end
        
        -- Handle "Searching '<query>' [step]"
        local q = st:match("^Searching%s+(.-)$")
        if q then
          if #q > 16 then q = q:sub(1, 13) .. "..." end
          return string.format("Searching %s", q)
        end
        
        -- Legacy "Executing tool: ..."
        local f, pct = st:match("^Executing tool:%s*read_file%s*%((.-),%s*(%d+%%)%)")
        if f and pct then
          f = f:match("^%s*(.-)%s*$")
          if #f > 18 then f = f:sub(1, 8) .. "..." .. f:sub(-7) end
          return string.format("Reading %s (%s)", f, pct)
        end
        local f = st:match("^Executing tool:%s*read_file%s*%((.-)%)")
        if f then
          f = f:match("^%s*(.-)%s*$")
          if #f > 18 then f = f:sub(1, 8) .. "..." .. f:sub(-7) end
          return string.format("Reading %s", f)
        end
        local f = st:match("^Executing tool:%s*write_file%s*%((.-)%)")
        if f then
          f = f:match("^%s*(.-)%s*$")
          if #f > 18 then f = f:sub(1, 8) .. "..." .. f:sub(-7) end
          return string.format("Writing %s", f)
        end
        local cmd = st:match("^Executing tool:%s*local_shell%s*%((.-)%)")
        if cmd then
          cmd = cmd:gsub("%.+$", ""):match("^%s*(.-)%s*$")
          if #cmd > 16 then cmd = cmd:sub(1, 13) .. "..." end
          return string.format("Running %s", cmd)
        end
        local q = st:match("^Executing tool:%s*web_search%s*%((.-)%)")
        if q then
          q = q:gsub("%.+$", ""):match("^%s*(.-)%s*$")
          if #q > 16 then q = q:sub(1, 13) .. "..." end
          return string.format("Searching %s", q)
        end
        local tool = st:match("^Executing tool:%s*(.-)$")
        if tool then
          tool = tool:gsub("^mcp__", ""):gsub("^tool_", "")
          return string.format("Running %s", tool)
        end
        
        return st
      end

      -- Dynamic stage status text
      local status_text
      if self:state().progress_status and self:state().progress_status ~= "" then
        status_text = compact_status(self:state().progress_status)
      elseif elapsed < 1.2 then
        status_text = "Connecting (" .. prov_name .. ")"
      elseif elapsed < 3.5 then
        status_text = "Analyzing context"
      elseif elapsed < 8.0 then
        status_text = "Generating response"
      else
        status_text = "Deep computing"
      end

      -- Animated trailing dots and elapsed time
      local dots = string.rep(".", (math.floor(self.tick / 12) % 4))
      local time_str = string.format(" (%.1fs)", elapsed)
      local avail_w = math.max(10 * SCALE, msg_w - 2 * msg_pad)
      
      -- Dot width and time string width
      local dot_w = style.code_font:get_width("● ")
      local time_w = style.code_font:get_width(time_str)
      
      -- Responsively trim status_text if total string exceeds available bubble width
      local max_status_w = avail_w - dot_w - time_w - 18 * SCALE
      if max_status_w > 20 * SCALE and style.code_font:get_width(status_text) > max_status_w then
        while #status_text > 4 and style.code_font:get_width(status_text .. "…") > max_status_w do
          status_text = status_text:sub(1, -2)
        end
        status_text = status_text .. "…"
      end

      local loader_h = style.code_font:get_height() + 6 * SCALE
      local loader_y = (sess.text == "" or #sess.blocks == 0) and (ty + msg_pad) or (line_y + 4 * SCALE)
      local content_w = dot_w + style.code_font:get_width(status_text .. dots) + time_w
      local pill_w = math.min(avail_w, content_w + 14 * SCALE)
      local pill_x = x + pad + msg_pad
      
      -- Modern capsule pill container with subtle accent outline
      renderer.draw_rect(pill_x, loader_y, pill_w, loader_h, P.bg_btn)
      draw_rect_outline(pill_x, loader_y, pill_w, loader_h, { P.fg_accent[1], P.fg_accent[2], P.fg_accent[3], 50 })
      
      -- Smooth 60fps opacity sine pulse on accent dot
      local pulse = (math.sin(self.tick / 10) + 1) / 2
      local alpha = math.floor(130 + 125 * pulse)
      local dot_col = { P.fg_accent[1], P.fg_accent[2], P.fg_accent[3], alpha }
      
      local tx = pill_x + 7 * SCALE
      local text_y = loader_y + math.floor((loader_h - style.code_font:get_height()) / 2)
      
      core.push_clip_rect(pill_x, loader_y, pill_w, loader_h)
      draw_text_emoji(style.code_font, "●", tx, text_y, dot_col)
      tx = tx + dot_w
      renderer.draw_text(style.code_font, status_text .. dots, tx, text_y, P.fg)
      tx = tx + style.code_font:get_width(status_text .. dots)
      renderer.draw_text(style.code_font, time_str, tx, text_y, P.fg_muted)
      core.pop_clip_rect()
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
      renderer.draw_rect(pop_x, iy, pop_w, item_h, is_sel and P.bg_btn_hl or P.bg_darker)

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
    if (config.ai_sidebar.active_tool or "agy") == "cloud_api" then
      local tc = self:_tool_cfg("cloud_api")
      local prov = tc.active_provider or (tc.selected_model and tc.selected_model:match("^([^/]+)/"))
      if prov and self.tool_model_lists and self.tool_model_lists["cloud_api"] then
        local filtered = {}
        for _, m in ipairs(self.tool_model_lists["cloud_api"]) do
          if m.name and m.name:match("^" .. prov .. "[/\\]") then
            table.insert(filtered, m)
          end
        end
        if #filtered > 0 then
          list = filtered
        end
      end
    end
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
          local rbg    = is_sel and P.bg_btn_hl or is_hov and P.bg_btn or P.bg_dark
          renderer.draw_rect(x, ry, w, item_h, rbg)
          
          local label = m.name
          local is_limited = m.limited
          local fg
          if is_limited then
            fg = _COLOR_CACHE_11
          elseif is_sel then
            fg = P.fg_accent
          elseif is_hov then
            fg = P.fg
          else
            fg = P.fg
          end

          -- Clean display label for cloud_api when provider prefix is present
          local disp_name = label
          if (config.ai_sidebar.active_tool or "agy") == "cloud_api" and disp_name:find("/") then
            disp_name = disp_name:match("^[^/]+/(.+)") or disp_name
          end

          -- Right side elements (drawn from right to left)
          local right_x = x + w - pad
          if m.usage then
            local ufg = is_limited and _COLOR_CACHE_7 or P.fg_muted
            local disp_usage = m.usage
            if is_limited then disp_usage = disp_usage .. " [No Quota]" end
            local uw = mf:get_width(disp_usage)
            renderer.draw_text(mf, disp_usage, right_x - uw,
              ry + math.floor((item_h - mf:get_height()) / 2), ufg)
            right_x = right_x - uw - 6 * SCALE
          end

          if is_limited and not m.usage then
            local tag = "[Pro Tier]"
            local tw = mf:get_width(tag)
            renderer.draw_text(mf, tag, right_x - tw,
              ry + math.floor((item_h - mf:get_height()) / 2),
              _COLOR_CACHE_7)
            right_x = right_x - tw - 6 * SCALE
          elseif is_sel and not m.usage then
            local tag = "[v]"
            local tw = mf:get_width(tag)
            renderer.draw_text(mf, tag, right_x - tw,
              ry + math.floor((item_h - mf:get_height()) / 2), P.dot_run)
            right_x = right_x - tw - 6 * SCALE
          end

          -- Category label badge (e.g. [Instruct], [Coder], [Reasoning], [Bolt], [Lightning], etc.)
          local cat_label, cat_col = get_model_category_badge(label)
          if cat_label then
            local badge_str = "[" .. cat_label .. "]"
            local bw = mf:get_width(badge_str)
            renderer.draw_text(mf, badge_str, right_x - bw,
              ry + math.floor((item_h - mf:get_height()) / 2), cat_col or P.fg_muted)
            right_x = right_x - bw - 6 * SCALE
          end

          -- Truncate left label if it exceeds remaining width
          local max_name_w = math.max(20 * SCALE, right_x - (x + pad) - 4 * SCALE)
          while mf:get_width(disp_name) > max_name_w and #disp_name > 4 do
            disp_name = disp_name:sub(1, -2)
          end
          if disp_name ~= label and disp_name ~= (label:match("^[^/]+/(.+)") or label) then
            disp_name = disp_name:match("^%s*(.-)%s*$") .. ".."
          end

          renderer.draw_text(mf, disp_name, x + pad,
            ry + math.floor((item_h - mf:get_height()) / 2), fg)

          -- Insert rect for hit testing only if it is visible
          table.insert(self._mpicker_rects, { x=x, y=ry, w=w, h=item_h, idx=i, model=m })
        end
      end
    end
    core.pop_clip_rect()
  end
  
  -- USAGE MODAL VIEW
  if self.show_usage_view then
    -- dim bg
    renderer.draw_rect(x, y, w, h, _COLOR_CACHE_23)
    
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
          
          lx = renderer.draw_text(active_font, url, lx, ty, hover_link and P.fg_accent or _COLOR_CACHE_8)
          renderer.draw_rect(ux, ty + lh - 2 * SCALE, lx - ux, 1 * SCALE, hover_link and P.fg_accent or _COLOR_CACHE_8)
          
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
    renderer.draw_rect(x, y, w, h, _COLOR_CACHE_23)
    
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
    local close_col = self._api_hover_close and P.fg_accent or P.fg_muted
    renderer.draw_text(style.icon_font, "C", cx, cy, close_col)
    self._api_close_rect = { x = cx, y = cy, w = style.icon_font:get_width("C") + 8 * SCALE, h = style.icon_font:get_height() }
    
    local div_y = my + pad + style.font:get_height() + 8 * SCALE
    renderer.draw_rect(mx + pad, div_y, mw - 2 * pad, 1 * SCALE, P.border)
    
    -- Text area with clipping & scrolling
    local text_y = div_y + 8 * SCALE
    local ty = text_y - (self.api_scroll_y or 0)
    local lh = style.font:get_height()
    local text_h = my + mh - text_y - pad
    
    self._api_btns = {}
    core.push_clip_rect(mx + pad, text_y, mw - 2 * pad, text_h)
    
    if not self.api_key_status then
      renderer.draw_text(style.font, "Loading API Keys...", mx + pad, ty, P.fg_muted)
    elseif self.api_key_status.status == "error" and (not self.api_key_status.data or next(self.api_key_status.data) == nil) then
      renderer.draw_text(style.font, "Error: " .. tostring(self.api_key_status.err), mx + pad, ty, _COLOR_CACHE_14)
    else
      if self.api_key_status.status == "loading" then
        renderer.draw_text(style.font, "Validating keys in background...", mx + pad, ty, P.fg_muted)
        ty = ty + lh + 4 * SCALE
      end
      local providers = { "gemini", "groq", "nvidia", "openai", "anthropic", "ollama", "omniroute" }
      local data = (self.api_key_status and self.api_key_status.data) or {}
      local seen = {}
      for _, p in ipairs(providers) do seen[p] = true end
      for p, _ in pairs(data) do
         if not seen[p] then
             table.insert(providers, p)
         end
      end
      
      for _, p in ipairs(providers) do
        local stat = data[p] or (self.api_key_status.status == "loading" and "checking..." or "missing")
        local p_name = p:sub(1,1):upper() .. p:sub(2)
        if p == "nvidia" then p_name = "NVIDIA" end
        if p:find("MCP::") then
           local srv_name, ek = p:match("MCP::(.-)::(.*)")
           p_name = "[MCP:" .. (srv_name or "unknown") .. "] " .. (ek or "Key")
        end
        
        renderer.draw_rect(mx + pad, ty - 2 * SCALE, mw - 2 * pad, lh + 6 * SCALE, P.bg)
        renderer.draw_text(style.font, p_name, mx + pad, ty, P.fg)
        local status_x = mx + pad + 95 * SCALE
        
        local stat_color = P.fg_muted
        if stat == "valid" then stat_color = _COLOR_CACHE_15
        elseif stat == "expired" then stat_color = _COLOR_CACHE_25
        elseif stat == "checking..." then stat_color = P.fg_muted end
        
        renderer.draw_text(style.font, stat:upper(), status_x, ty, stat_color)
        
        local btn_w = 55 * SCALE
        local btn_x = mx + mw - pad - btn_w
        
        local btn_text = (stat == "missing" or stat == "expired" or stat == "checking...") and "Set Key" or (p == "ollama" and "URL/Key" or "Delete")
        local is_hover = self._api_hover_btn and self._api_hover_btn == p and self._api_hover_action == btn_text
        local btn_bg = is_hover and P.bg_btn_hl or P.bg_btn
        renderer.draw_rect(btn_x, ty, btn_w, lh, btn_bg)
        renderer.draw_text(style.font, btn_text, btn_x + (btn_w - style.font:get_width(btn_text))/2, ty, P.fg)
        
        if ty + lh >= text_y and ty <= text_y + text_h then
          table.insert(self._api_btns, { p = p, text = btn_text, action = btn_text, x = btn_x, y = ty, w = btn_w, h = lh })
        end
        
        if stat == "valid" then
          local edit_w = 38 * SCALE
          local edit_x = btn_x - edit_w - 4 * SCALE
          local is_edit_hover = self._api_hover_btn and self._api_hover_btn == p and self._api_hover_action == "Edit"
          renderer.draw_rect(edit_x, ty, edit_w, lh, is_edit_hover and P.bg_btn_hl or P.bg_btn)
          renderer.draw_text(style.font, "Edit", edit_x + (edit_w - style.font:get_width("Edit"))/2, ty, P.fg)
          if ty + lh >= text_y and ty <= text_y + text_h then
            table.insert(self._api_btns, { p = p, text = "Edit", action = "Edit", x = edit_x, y = ty, w = edit_w, h = lh })
          end

          local use_w = 38 * SCALE
          local use_x = edit_x - use_w - 4 * SCALE
          local is_use_hover = self._api_hover_btn and self._api_hover_btn == p and self._api_hover_action == "Use"
          renderer.draw_rect(use_x, ty, use_w, lh, is_use_hover and P.bg_btn_hl or P.bg_btn)
          renderer.draw_text(style.font, "Use", use_x + (use_w - style.font:get_width("Use"))/2, ty, P.fg)
          if ty + lh >= text_y and ty <= text_y + text_h then
            table.insert(self._api_btns, { p = p, text = "Use", action = "Use", x = use_x, y = ty, w = use_w, h = lh })
          end
        end
        
        ty = ty + lh + 10 * SCALE
      end
    end
    core.pop_clip_rect()
    self.api_max_scroll = math.max(0, (ty + (self.api_scroll_y or 0)) - text_y - text_h)
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
    local tmp_dir = USERDIR .. PATHSEP .. "tempfiles"
    pcall(system.mkdir, tmp_dir)
    os.execute('mkdir "' .. tmp_dir:gsub("/", "\\") .. '" 2>nul')
    local filename = os.date("pasted_text_%Y%m%d_%H%M%S.txt")
    local filepath = tmp_dir .. PATHSEP .. filename
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
  
  self.hover_cloud_skill = false
  self.hover_cloud_tools = false
  self.hover_cloud_team = false
  self.hover_market_skill = nil
  
  -- 1. Full isolation for API Management View (prevent any background click-through or hovers)
  if self.show_api_view then
    self._api_hover_btn = nil
    self._api_hover_action = nil
    self._api_hover_close = false
    
    if self._api_close_rect then
      local c = self._api_close_rect
      if mx >= c.x and mx <= c.x + c.w and my >= c.y and my <= c.y + c.h then
        self._api_hover_close = true
        system.set_cursor("hand")
        core.redraw = true
        return
      end
    end
    
    if self._api_btns then
      for _, btn in ipairs(self._api_btns) do
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          self._api_hover_btn = btn.p
          self._api_hover_action = btn.action
          system.set_cursor("hand")
          core.redraw = true
          return
        end
      end
    end
    
    system.set_cursor("arrow")
    core.redraw = true
    return
  end

  -- 2. Full isolation for Skills Modal
  if self.show_skills_modal then
    self.hover_market_skill = nil
    self.hover_market_action = nil
    self.hover_market_cat = nil
    self.hover_market_close = nil
    self.hover_market_tab = nil
    self.hover_market_view = nil
    self.hover_market_ref = nil
    self.hover_market_add = nil
    self.hover_market_search = nil
    self.hover_market_search_clear = nil
    self.hover_market_prev = nil
    self.hover_market_next = nil
    self.hover_market_clr_filters = nil
    self.hover_preview_close = nil
    self.hover_preview_cancel = nil
    self.hover_preview_config = nil
    self.hover_preview_install = nil
    self.hover_preview_uninstall = nil
    self.hover_preview_repo = nil

    local is_hand = false

    if self.active_tool_config then
      local function check_btn(btn)
        return btn and (mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h)
      end
      self.hover_cfg_close = nil
      self.hover_cfg_cancel = nil
      self.hover_cfg_test = nil
      self.hover_cfg_save = nil
      self.hover_cfg_auth = nil
      self.hover_cfg_add_var = nil
      self.hover_cfg_edit_cmd = nil
      self.hover_cfg_env_edit = nil
      self.hover_cfg_env_clear = nil

      if check_btn(self._cfg_close_btn) then self.hover_cfg_close = true; is_hand = true
      elseif check_btn(self._cfg_cancel_btn) then self.hover_cfg_cancel = true; is_hand = true
      elseif check_btn(self._cfg_test_btn) then self.hover_cfg_test = true; is_hand = true
      elseif check_btn(self._cfg_save_btn) then self.hover_cfg_save = true; is_hand = true
      elseif check_btn(self._cfg_auth_btn) then self.hover_cfg_auth = true; is_hand = true
      elseif check_btn(self._cfg_add_var_btn) then self.hover_cfg_add_var = true; is_hand = true
      elseif check_btn(self._cfg_edit_cmd_btn) then self.hover_cfg_edit_cmd = true; is_hand = true
      end

      if not is_hand and self._cfg_env_edit_btns then
        for _, eb in ipairs(self._cfg_env_edit_btns) do
          if check_btn(eb) then
            self.hover_cfg_env_edit = eb.key
            is_hand = true
            break
          end
        end
      end
      if not is_hand and self._cfg_env_clear_btns then
        for _, cb in ipairs(self._cfg_env_clear_btns) do
          if check_btn(cb) then
            self.hover_cfg_env_clear = cb.key
            is_hand = true
            break
          end
        end
      end

      system.set_cursor(is_hand and "hand" or "arrow")
      core.redraw = true
      return
    end

    if self.active_skill_preview then
      local function check_btn(btn)
        return btn and (mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h)
      end
      if check_btn(self._preview_close_btn) then self.hover_preview_close = true; is_hand = true
      elseif check_btn(self._preview_cancel_btn) then self.hover_preview_cancel = true; is_hand = true
      elseif check_btn(self._preview_config_btn) then self.hover_preview_config = true; is_hand = true
      elseif check_btn(self._preview_install_btn) then self.hover_preview_install = true; is_hand = true
      elseif check_btn(self._preview_uninstall_btn) then self.hover_preview_uninstall = true; is_hand = true
      elseif check_btn(self._preview_repo_btn) then self.hover_preview_repo = true; is_hand = true
      end
    else
      local function check_btn(btn)
        return btn and (mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h)
      end
      if check_btn(self._market_close_btn) then self.hover_market_close = true; is_hand = true
      elseif check_btn(self._market_tab_skills_btn) then self.hover_market_tab = "skills"; is_hand = true
      elseif check_btn(self._market_tab_tools_btn) then self.hover_market_tab = "tools"; is_hand = true
      elseif check_btn(self._market_browse_btn) then self.hover_market_view = "browse"; is_hand = true
      elseif check_btn(self._market_installed_btn) then self.hover_market_view = "installed"; is_hand = true
      elseif check_btn(self._market_manage_btn) then self.hover_market_view = "manage"; is_hand = true
      elseif check_btn(self._market_refresh_btn) then self.hover_market_ref = true; is_hand = true
      elseif check_btn(self._market_add_btn) then self.hover_market_add = true; is_hand = true
      elseif check_btn(self._market_search_clear_btn) then self.hover_market_search_clear = true; is_hand = true
      elseif check_btn(self._market_search_btn) then self.hover_market_search = true; is_hand = true
      elseif check_btn(self._market_prev_btn) then self.hover_market_prev = true; is_hand = true
      elseif check_btn(self._market_next_btn) then self.hover_market_next = true; is_hand = true
      elseif check_btn(self._market_clear_filters_btn) then self.hover_market_clr_filters = true; is_hand = true
      elseif check_btn(self._market_add_repo_btn) then self.hover_market_add_repo = true; is_hand = true
      end

      self.hover_market_source = nil
      if not is_hand and self._market_source_chips then
        for _, chip in ipairs(self._market_source_chips) do
          if check_btn(chip) then
            self.hover_market_source = chip.id
            is_hand = true
            break
          end
        end
      end

      if not is_hand and self._market_cat_chips then
        for _, chip in ipairs(self._market_cat_chips) do
          if mx >= chip.x and mx <= chip.x + chip.w and my >= chip.y and my <= chip.y + chip.h then
            self.hover_market_cat = chip.id
            is_hand = true
            break
          end
        end
      end

      if not is_hand and self._market_action_btns then
        for _, btn in ipairs(self._market_action_btns) do
          if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
            self.hover_market_action = btn.key
            self.hover_market_skill = btn.item and btn.item.id
            is_hand = true
            break
          end
        end
      end

      if not is_hand and self._market_rects then
        for _, r in ipairs(self._market_rects) do
          if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
            self.hover_market_skill = r.id
            is_hand = true
            break
          end
        end
      end
    end

    system.set_cursor(is_hand and "hand" or "arrow")
    core.redraw = true
    return
  end

  -- 3. Full isolation for Usage View
  self._usage_links_hover = nil
  if self.show_usage_view then
    local hovering = false
    if self._usage_links then
      for _, link in ipairs(self._usage_links) do
        if mx >= link.x and mx <= link.x + link.w and my >= link.y and my <= link.y + link.h then
          self._usage_links_hover = link.url
          system.set_cursor("hand")
          hovering = true
          core.redraw = true
          break
        end
      end
    end
    if not hovering then system.set_cursor("arrow") end
    return
  end
  
  for _, r in ipairs(self._cloud_ctrl_rects or {}) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
          if r.id == "skill" then self.hover_cloud_skill = true
          elseif r.id == "tools" then self.hover_cloud_tools = true
          elseif r.id == "team" then self.hover_cloud_team = true end
          system.set_cursor("hand")
          core.redraw = true
          return
      end
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

  self.hover_insert_idx = nil
  if self._insert_rects then
    for _, r in ipairs(self._insert_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        self.hover_insert_idx = r.idx
        system.set_cursor("hand")
        break
      end
    end
  end

  self.hover_starter_idx = nil
  if self._starter_card_rects then
    for _, r in ipairs(self._starter_card_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        self.hover_starter_idx = r.idx
        system.set_cursor("hand")
        break
      end
    end
  end

  self.hover_link_url = nil
  if self._link_rects then
    for _, r in ipairs(self._link_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        self.hover_link_url = r.url
        system.set_cursor("hand")
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
                  .. tostring(self.hover_link_url)
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
      local config_dir = USERDIR .. PATHSEP .. "scripts"
      local cmd = "python " .. config_dir .. PATHSEP .. "ai_api_bridge.py --get-history"
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
    local C_TR    = _COLOR_CACHE_30    -- Trunk dark brown
    local C_LEAF  = _COLOR_CACHE_0  -- Light green leaf
    local C_LEAF_D= _COLOR_CACHE_31  -- Darker green leaf
    local C_YEAR  = _COLOR_CACHE_0  -- Year green
    local C_TEXT  = P.fg_muted
    local f       = style.font
    local fh      = f:get_height()

    renderer.draw_rect(x, y, w, h, P.bg)
    core.push_clip_rect(x, y, w, h)

    if self.history_state == "loading" then
      renderer.draw_text(f, "Growing tree...", x + 20, y + 20, C_LEAF)
      core.pop_clip_rect(); return
    elseif self.history_state == "error" then
      renderer.draw_text(f, "Error loading timeline.", x + 20, y + 20, _COLOR_CACHE_26)
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
      renderer.draw_text(tf, title_str, trunk_cx - tw/2 + 2, ty + 2, _COLOR_CACHE_9)
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
           renderer.draw_text(f, n._title, tx, cy - math.floor(fh / 2), is_hov and P.fg_accent or C_YEAR)
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
           draw_aligned(m_str, f, current_y, P.fg_accent or _COLOR_CACHE_24, true) -- Bold & brighter!
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




function AGView:_launch_team_builder()
  local team = {}
  
  local function prompt_model(role, cb)
    local items = {}
    if self.model_list then
      for _, m in ipairs(self.model_list) do
        if not m.limited then
          table.insert(items, m.name)
        end
      end
    end
    
    if #items == 0 then
      self:fetch_models()
      table.insert(items, "gemini/gemini-2.5-flash")
      table.insert(items, "groq/llama3-70b-8192")
      table.insert(items, "nvidia/meta/llama-3.3-70b-instruct")
    end
    
    core.command_view:enter("Select Model for " .. role, {
      submit = function(text, item)
        local sel = (type(item) == "table" and item.text) or (type(item) == "string" and item) or text
        local prov = sel:match("^([^/]+)/") or "gemini"
        local mod = sel:match("^[^/]+/(.+)$") or sel
        cb(prov, mod)
      end,
      suggest = function(text)
        return common.fuzzy_match(items, text)
      end
    })
  end

  local function build_next_agent()
    core.command_view:enter("Enter Role (e.g. 'Architect', 'Hunter') or 'done' to finish", {
      submit = function(role)
        if role:lower() == "done" or role == "" then
          if #team > 0 then
            local p = USERDIR .. PATHSEP .. "scripts/.team_config.json"
            local f = io.open(p, "w")
            if f then
              -- basic JSON encode
              f:write("[")
              for i, agent in ipairs(team) do
                f:write('{"id": "agent_'..tostring(i)..'", "provider": "'..agent.provider..'", "model": "'..agent.model..'", "role": "'..agent.role..'"}')
                if i < #team then f:write(",") end
              end
              f:write("]")
              f:close()
              config.ai_sidebar.active_tool = "cloud_api"
              self:_add_session("ai", "Team Built successfully! The Hunter is: " .. team[#team].role .. ". Type a prompt to begin the Swarm session.")
            end
          else
            self:_add_session("ai", "Team Builder cancelled.")
          end
        else
          prompt_model(role, function(prov, mod)
            table.insert(team, {role = role, provider = prov, model = mod})
            build_next_agent()
          end)
        end
      end
    })
  end
  
  build_next_agent()
end

function AGView:on_mouse_pressed(button, mx, my, clicks)
  AGView.super.on_mouse_pressed(self, button, mx, my, clicks)
  core.set_active_view(self)

  -- 1. Full isolation for API Management View (prevent any background click-through)
  if self.show_api_view then
    if button == "left" then
      if self._api_close_rect then
        local c = self._api_close_rect
        if mx >= c.x and mx <= c.x + c.w and my >= c.y and my <= c.y + c.h then
          self.show_api_view = false
          core.redraw = true
          return true
        end
      end
      local mw = self.size.x - 40 * SCALE
      local mh = self.size.y - 60 * SCALE
      local mx_modal = self.position.x + 20 * SCALE
      local my_modal = self.position.y + 30 * SCALE
      if mx < mx_modal or mx > mx_modal + mw or my < my_modal or my > my_modal + mh then
        self.show_api_view = false
        core.redraw = true
        return true
      end
      if self._api_btns then
        for _, btn in ipairs(self._api_btns) do
          if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
            if btn.action == "Delete" then
              local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
              core.add_thread(function()
                local p = process.start({ "python", bridge, "--provider", btn.p, "--delete-key" })
                if p then
                  while p:running() do coroutine.yield(0.1) end
                end
                self:submit("/api")
              end)
            elseif btn.action == "URL/Key" or btn.action == "Edit" or btn.action == "Set Key" then
              self:_prompt_for_api_key(btn.p)
            elseif btn.action == "Use" then
              local chosen_model = nil
              if self.tool_model_lists and self.tool_model_lists["cloud_api"] then
                for _, m in ipairs(self.tool_model_lists["cloud_api"]) do
                  if m.name:match("^" .. btn.p .. "[/\\]") then
                    chosen_model = m.name
                    break
                  end
                end
              end
              if not chosen_model then
                local defaults = {
                  groq      = "groq/qwen/qwen3.8-27b",
                  gemini    = "gemini/gemini-2.5-flash",
                  nvidia    = "nvidia/meta/llama-3.3-70b-instruct",
                  openai    = "openai/gpt-4o",
                  anthropic = "anthropic/claude-3-7-sonnet-20250219",
                  ollama    = "ollama/mistral-large-3:675b",
                  omniroute = "omniroute/default",
                }
                chosen_model = defaults[btn.p] or (btn.p .. "/default")
              end
              config.ai_sidebar.active_tool = "cloud_api"
              local tc = self:_tool_cfg("cloud_api")
              tc.active_provider = btn.p
              tc.selected_model = chosen_model
              config.antigravity.selected_model = chosen_model
              self:_sync_model_list()
              self:state().has_session = false
              self.show_api_view = false
              core.log("AI Sidebar: Switched to " .. btn.p:upper() .. " (" .. chosen_model .. ")")
              core.redraw = true
            else
              self:_prompt_for_api_key(btn.p)
            end
            return true
          end
        end
      end
    end
    return true
  end

  -- 2. Full isolation for Usage View
  if self.show_usage_view then
    if button == "left" then
      if self._usage_close_rect then
        local c = self._usage_close_rect
        if mx >= c.x and mx <= c.x + c.w and my >= c.y and my <= c.y + c.h then
          self.show_usage_view = false
          core.redraw = true
          return true
        end
      end
      local mw = self.size.x - 40 * SCALE
      local mh = self.size.y - 60 * SCALE
      local mx_modal = self.position.x + 20 * SCALE
      local my_modal = self.position.y + 30 * SCALE
      if mx < mx_modal or mx > mx_modal + mw or my < my_modal or my > my_modal + mh then
        self.show_usage_view = false
        core.redraw = true
        return true
      end
    end
    return true
  end
  
  if button == "left" then
    if self._form_rects then
      for _, r in ipairs(self._form_rects) do
        if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
          if r.type == "toggle" then
            self.skill_state[r.id] = not self.skill_state[r.id]
            core.redraw = true
            return
          elseif r.type == "file" then
            core.command_view:enter("File Path for " .. r.id, {
              submit = function(path)
                self.skill_state[r.id] = path
                core.redraw = true
              end
            })
            return
          elseif r.type == "text" then
            core.command_view:enter("Value for " .. r.id, {
              submit = function(text)
                self.skill_state[r.id] = text
                core.redraw = true
              end
            })
            return
          end
        end
      end
    end

    if self.show_skills_modal then
      -- 0. Active Tool Configuration Sheet clicks
      if self.active_tool_config then
        local function check_btn(btn)
          return btn and (mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h)
        end
        if check_btn(self._cfg_close_btn) or check_btn(self._cfg_cancel_btn) then
          self.active_tool_config = nil
          core.redraw = true
          return true
        end
        if check_btn(self._cfg_test_btn) then
          self:test_tool_health(self.active_tool_config.id)
          return true
        end
        if check_btn(self._cfg_auth_btn) then
          self:launch_tool_browser_auth(self.active_tool_config.id)
          return true
        end
        if check_btn(self._cfg_save_btn) then
          local tool_id = self.active_tool_config.id
          local cfg = self.active_tool_config.config
          self:save_tool_config(tool_id, cfg, function()
            core.log("[Aether] Successfully saved & verified " .. tool_id)
            self.active_tool_config = nil
          end)
          return true
        end
        if check_btn(self._cfg_add_var_btn) then
          core.command_view:enter("Environment Variable Name (e.g. GITHUB_TOKEN)", {
            submit = function(key_name)
              if key_name and key_name ~= "" then
                core.command_view:enter("Value for " .. key_name, {
                  submit = function(val)
                    if self.active_tool_config and self.active_tool_config.config then
                      self.active_tool_config.config.env = self.active_tool_config.config.env or {}
                      self.active_tool_config.config.env[key_name] = val
                      core.redraw = true
                    end
                  end
                })
              end
            end
          })
          return true
        end
        if check_btn(self._cfg_edit_cmd_btn) then
          local current_args = table.concat(self.active_tool_config.config.args or {}, " ")
          core.command_view:enter("Command Arguments (space-separated)", {
            text = current_args,
            submit = function(arg_str)
              if self.active_tool_config and self.active_tool_config.config then
                local new_args = {}
                for a in arg_str:gmatch("%S+") do table.insert(new_args, a) end
                self.active_tool_config.config.args = new_args
                core.redraw = true
              end
            end
          })
          return true
        end
        if self._cfg_env_edit_btns then
          for _, eb in ipairs(self._cfg_env_edit_btns) do
            if check_btn(eb) then
              core.command_view:enter("Value for " .. eb.key, {
                text = eb.current_val or "",
                submit = function(new_val)
                  if self.active_tool_config and self.active_tool_config.config then
                    self.active_tool_config.config.env = self.active_tool_config.config.env or {}
                    self.active_tool_config.config.env[eb.key] = new_val
                    core.redraw = true
                  end
                end
              })
              return true
            end
          end
        end
        if self._cfg_env_clear_btns then
          for _, cb in ipairs(self._cfg_env_clear_btns) do
            if check_btn(cb) then
              if self.active_tool_config and self.active_tool_config.config and self.active_tool_config.config.env then
                self.active_tool_config.config.env[cb.key] = nil
                core.redraw = true
              end
              return true
            end
          end
        end
        if self._cfg_modal_rect then
          local mr = self._cfg_modal_rect
          if mx < mr.x or mx > mr.x + mr.w or my < mr.y or my > mr.y + mr.h then
            self.active_tool_config = nil
            core.redraw = true
            return true
          end
        end
        return true
      end

      -- 1. Preview Modal clicks
      if self.active_skill_preview then
        local function check_btn(btn)
          return btn and (mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h)
        end
        if check_btn(self._preview_close_btn) or check_btn(self._preview_cancel_btn) then
          self.active_skill_preview = nil
          self.preview_scroll_y = 0
          core.redraw = true
          return true
        end
        if check_btn(self._preview_config_btn) then
          local item = self.active_skill_preview
          self.active_skill_preview = nil
          self:open_tool_config(item)
          return true
        end
        if check_btn(self._preview_install_btn) then
          self:install_skill(self.active_skill_preview)
          self.active_skill_preview = nil
          core.redraw = true
          return true
        end
        if check_btn(self._preview_uninstall_btn) then
          self:uninstall_skill(self.active_skill_preview.id)
          self.active_skill_preview = nil
          core.redraw = true
          return true
        end
        if check_btn(self._preview_repo_btn) then
          local url = self.active_skill_preview.repo_url
          if url and url ~= "" then
            if system.open_url then system.open_url(url)
            elseif PLATFORM == "Windows" then system.exec("start \"\" \"" .. url .. "\"") end
          end
          return true
        end
        if self._preview_modal_rect then
          local pr = self._preview_modal_rect
          if mx < pr.x or mx > pr.x + pr.w or my < pr.y or my > pr.y + pr.h then
            self.active_skill_preview = nil
            self.preview_scroll_y = 0
            core.redraw = true
            return true
          end
        end
        return true
      end

      -- 2. Header & Modal controls
      if self._market_close_btn then
        local btn = self._market_close_btn
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          self.show_skills_modal = false
          core.redraw = true
          return true
        end
      end

      if self._market_tab_skills_btn then
        local btn = self._market_tab_skills_btn
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          self.show_tools_tab = false
          self.market_page = 1
          self.market_scroll_y = 0
          self:fetch_marketplace()
          return true
        end
      end
      if self._market_tab_tools_btn then
        local btn = self._market_tab_tools_btn
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          self.show_tools_tab = true
          self.market_page = 1
          self.market_scroll_y = 0
          self:fetch_marketplace()
          return true
        end
      end

      if self._market_browse_btn then
        local btn = self._market_browse_btn
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          if self.show_installed_skills then
            self.show_installed_skills = false
            self.market_page = 1
            self.market_scroll_y = 0
            self:fetch_marketplace()
          end
          return true
        end
      end

      if self._market_installed_btn then
        local btn = self._market_installed_btn
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          if not self.show_installed_skills then
            self.show_installed_skills = true
            self.market_page = 1
            self.market_scroll_y = 0
            self:fetch_marketplace()
          end
          return true
        end
      end

      if self._market_manage_btn then
        local btn = self._market_manage_btn
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          self.show_installed_skills = not self.show_installed_skills
          self.market_page = 1
          self.market_scroll_y = 0
          self:fetch_marketplace()
          return true
        end
      end

      if self._market_refresh_btn then
        local btn = self._market_refresh_btn
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          self:fetch_marketplace()
          return true
        end
      end

      if self._market_search_clear_btn then
        local btn = self._market_search_clear_btn
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          self.market_search_query = ""
          self.market_page = 1
          self.market_scroll_y = 0
          self:fetch_marketplace()
          return true
        end
      end

      if self._market_search_btn then
        local btn = self._market_search_btn
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          core.command_view:enter("Search Marketplace", {
            text = self.market_search_query or "",
            submit = function(text)
              self.market_search_query = text
              self.market_page = 1
              self.market_scroll_y = 0
              self:fetch_marketplace()
            end
          })
          return true
        end
      end

      if self._market_clear_filters_btn then
        local btn = self._market_clear_filters_btn
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          self.market_category = "all"
          self.market_search_query = ""
          self.market_page = 1
          self.market_scroll_y = 0
          self:fetch_marketplace()
          return true
        end
      end

      -- Source Selector Chips
      if self._market_source_chips then
        for _, chip in ipairs(self._market_source_chips) do
          if mx >= chip.x and mx <= chip.x + chip.w and my >= chip.y and my <= chip.y + chip.h then
            self.market_source = chip.id
            self.market_page = 1
            self.market_scroll_y = 0
            self:fetch_marketplace()
            return true
          end
        end
      end

      -- Add Custom GitHub Repo Source Button
      if self._market_add_repo_btn then
        local btn = self._market_add_repo_btn
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          core.command_view:enter("Add GitHub Repository as Source (e.g. NVIDIA/skills or username/repo)", {
            submit = function(repo)
              self:add_custom_source_repo(repo)
            end
          })
          return true
        end
      end

      -- Category Filter Chips
      if self._market_cat_chips then
        for _, chip in ipairs(self._market_cat_chips) do
          if mx >= chip.x and mx <= chip.x + chip.w and my >= chip.y and my <= chip.y + chip.h then
            self.market_category = chip.id
            self.market_scroll_y = 0
            core.redraw = true
            return true
          end
        end
      end

      -- Add Custom / URL button
      if self._market_add_btn then
        local btn = self._market_add_btn
        if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
          if self.show_installed_skills then
            core.command_view:enter("Custom Skill Title", {
              submit = function(title)
                core.command_view:enter("System Prompt Content", {
                  submit = function(content)
                    local skill = {
                      id = "custom_" .. tostring(os.time()),
                      title = title,
                      description = "Custom user-defined skill",
                      system_prompt = content,
                      author = "You",
                      domain = "Custom"
                    }
                    self:install_skill(skill)
                  end
                })
              end
            })
          else
            core.command_view:enter("Paste GitHub Repo or Smithery Tool ID", {
              submit = function(url)
                if self.show_tools_tab then
                  self:install_skill({id = url, title = url, name = url, description = "Installed from URL/ID"})
                else
                  local skill = {
                    id = "custom_" .. tostring(os.time()),
                    title = url:match("([^/]+)$") or url,
                    repo_url = url,
                    description = "Custom skill from " .. url,
                    domain = "Custom",
                    author = "Community"
                  }
                  self:install_skill(skill)
                end
              end
            })
          end
          return true
        end
      end

      -- Pagination
      if not self.show_installed_skills then
        if self._market_prev_btn then
          local b = self._market_prev_btn
          if mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h then
            self.market_page = math.max(1, (self.market_page or 1) - 1)
            self.market_scroll_y = 0
            self:fetch_marketplace()
            return true
          end
        end
        if self._market_next_btn then
          local b = self._market_next_btn
          if mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h then
            self.market_page = math.min(self.market_total_pages or 1, (self.market_page or 1) + 1)
            self.market_scroll_y = 0
            self:fetch_marketplace()
            return true
          end
        end
      end

      -- 3. Cards & Action Buttons within clip rect
      local cr = self._market_clip_rect
      local in_clip = cr and (mx >= cr.x and mx <= cr.x + cr.w and my >= cr.y and my <= cr.y + cr.h)
      if in_clip then
        if self._market_action_btns then
          for _, btn in ipairs(self._market_action_btns) do
            if mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h then
              if btn.action == "config" then
                self:open_tool_config(btn.item)
                return true
              elseif btn.action == "install" then
                self:install_skill(btn.item)
                return true
              elseif btn.action == "uninstall" then
                self:uninstall_skill(btn.item.id)
                return true
              elseif btn.action == "details" then
                self:open_skill_preview(btn.item)
                return true
              end
            end
          end
        end

        if self._market_rects then
          for _, crd in ipairs(self._market_rects) do
            if mx >= crd.x and mx <= crd.x + crd.w and my >= crd.y and my <= crd.y + crd.h then
              self:open_skill_preview(crd.item)
              return true
            end
          end
        end
      end

      -- 4. Click outside modal window closes modal
      if self._market_modal_rect then
        local r = self._market_modal_rect
        if mx < r.x or mx > r.x + r.w or my < r.y or my > r.y + r.h then
          self.show_skills_modal = false
          core.redraw = true
          return true
        end
      end
      return true
    end

    if self.hover_cloud_tools then
      self.enable_tools = not self.enable_tools
      core.redraw = true
      return
    end
    
    if self.hover_cloud_skill then
      self.show_skills_modal = true
      self:fetch_marketplace()
      core.redraw = true
      return
    end
    
    if self.hover_cloud_team then
      self:_launch_team_builder()
      return
    end

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
          self.show_skills_modal = false
          self.enable_tools = false
          self.marketplace_skills = nil
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

  -- Starter card clicks in empty state
  if self._starter_card_rects then
    for _, r in ipairs(self._starter_card_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        self:submit(r.prompt)
        return true
      end
    end
  end

  -- Apply / Insert button clicks on code blocks
  if self._insert_rects then
    for _, r in ipairs(self._insert_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        local doc = nil
        if core.active_view and core.active_view.doc then
          doc = core.active_view.doc
        elseif core.root_view and core.root_view.root_node then
          local function find_doc(n)
            if not n then return nil end
            if n.type == "leaf" and n.active_view and n.active_view.doc then
              return n.active_view.doc
            end
            if n.a then local d = find_doc(n.a); if d then return d end end
            if n.b then local d = find_doc(n.b); if d then return d end end
            return nil
          end
          doc = find_doc(core.root_view.root_node)
        end

        if doc then
          doc:insert(doc:get_selection(), r.text)
          self.copy_flash_idx = r.idx
          core.log("Applied code snippet directly into editor document.")
          core.redraw = true
        else
          system.set_clipboard(r.text)
          self.copy_flash_idx = r.idx
          core.log("No open document found — snippet copied to clipboard.")
          core.redraw = true
        end
        return true
      end
    end
  end

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
        local m = r.model or (self.model_list and self.model_list[r.idx])
        if m and not m.limited then
          self:_set_active_model(m.name)
          if (config.ai_sidebar.active_tool or "agy") == "cloud_api" then
            local prov = m.name:match("^([^/]+)/")
            if prov then
              local tc = self:_tool_cfg("cloud_api")
              tc.active_provider = prov
              self:_sync_model_list()
            end
          end
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

  -- Markdown link click
  if button == "left" and self.hover_link_url then
    local url = self.hover_link_url
    if url:match("^file:///(.+)") then
      local path = url:match("^file:///(.+)")
      path = path:gsub("/", PATHSEP)
      local info = system.get_file_info(path)
      if info then
        core.root_view:open_doc(core.open_doc(path))
        return true
      end
    elseif url:match("^https?://") then
      if system.open_url then
        system.open_url(url)
      elseif PLATFORM == "Windows" then
        system.exec("start \"\" \"" .. url .. "\"")
      end
      return true
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
            local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
            core.add_thread(function()
              local p = process.start({ "python", bridge, "--provider", btn.p, "--delete-key" })
              if p then
                while p:running() do coroutine.yield(0.1) end
              end
              self:submit("/api") -- refresh
            end)
          elseif btn.action == "URL/Key" or btn.action == "Edit" or btn.action == "Set Key" then
              self:_prompt_for_api_key(btn.p)
          elseif btn.action == "Use" then
            -- Set provider as active by picking its first model
            local chosen_model = nil
            if self.tool_model_lists and self.tool_model_lists["cloud_api"] then
              for _, m in ipairs(self.tool_model_lists["cloud_api"]) do
                if m.name:match("^" .. btn.p .. "[/\\]") then
                  chosen_model = m.name
                  break
                end
              end
            end
            if not chosen_model then
              local defaults = {
                groq      = "groq/qwen/qwen3.8-27b",
                gemini    = "gemini/gemini-2.5-flash",
                nvidia    = "nvidia/meta/llama-3.3-70b-instruct",
                openai    = "openai/gpt-4o",
                anthropic = "anthropic/claude-3-7-sonnet-20250219",
                ollama    = "ollama/mistral-large-3:675b",
                omniroute = "omniroute/default",
              }
              chosen_model = defaults[btn.p] or (btn.p .. "/default")
            end
            config.ai_sidebar.active_tool = "cloud_api"
            local tc = self:_tool_cfg("cloud_api")
            tc.active_provider = btn.p
            tc.selected_model = chosen_model
            config.antigravity.selected_model = chosen_model
            self:_sync_model_list()
            self:state().has_session = false
            self.show_api_view = false
            core.log("AI Sidebar: Switched to " .. btn.p:upper() .. " (" .. chosen_model .. ")")
            core.redraw = true
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
  if self.show_skills_modal then
      if self.active_skill_preview then
        self.preview_scroll_y = math.max(0, math.min(self.preview_max_scroll or 0, (self.preview_scroll_y or 0) - dy * 45 * SCALE))
      else
        self.market_scroll_y = math.max(0, math.min(self.market_max_scroll or 0, (self.market_scroll_y or 0) - dy * 45 * SCALE))
      end
  elseif self.show_api_view then
    local item_h = style.font:get_height() + 10 * SCALE
    self.api_scroll_y = math.max(0, math.min(self.api_max_scroll or 0, (self.api_scroll_y or 0) - dy * item_h * 2))
  elseif self.show_usage_view then
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
          core.log("Invalid provider: " .. text)
        end
      end
    })
    return
  end

  core.command_view:enter(provider == "ollama" and "Enter URL or URL|Key (e.g. https://api:11434)" or "Enter API Key for " .. provider, {
    submit = function(text)
      text = text:match("^%s*(.-)%s*$")
      if text and #text > 0 then
        -- Run python script to save key
        local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
        local p = process.start({ "python", bridge, "--provider", provider, "--set-key", text })
        if p then
          core.add_thread(function()
            while p:running() do coroutine.yield(0.1) end
            self:fetch_models(true)
            local defaults = {
              groq      = "groq/qwen/qwen3.8-27b",
              gemini    = "gemini/gemini-2.5-flash",
              nvidia    = "nvidia/meta/llama-3.3-70b-instruct",
              openai    = "openai/gpt-4o",
              anthropic = "anthropic/claude-3-7-sonnet-20250219",
              ollama    = "ollama/mistral-large-3:675b",
              omniroute = "omniroute/default",
            }
            local chosen_model = defaults[provider] or (provider .. "/default")
            config.ai_sidebar.active_tool = "cloud_api"
            local tc = self:_tool_cfg("cloud_api")
            tc.active_provider = provider
            tc.selected_model = chosen_model
            config.antigravity.selected_model = chosen_model
            self:_sync_model_list()
            self:state().has_session = false
            core.log("AI Sidebar: Key saved and switched to " .. provider:upper() .. " (" .. chosen_model .. ")")
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
    local artifacts_path = base_dir .. PATHSEP .. ".gemini/antigravity-cli/brain/" .. cid
    
    local items = {}
    local seen = {}
    
    local function scan_dir(dir, prefix)
      local files = system.list_dir(dir)
      if not files then return end
      for _, f in ipairs(files) do
        if not f:match("^%.") then
          local path = dir .. PATHSEP .. f
          local info = system.get_file_info(path)
          if info then
            if info.type == "file" then
              if not seen[path] then
                table.insert(items, { text = prefix .. f, path = path })
                seen[path] = true
              end
            elseif info.type == "dir" and f == "scratch" then
              scan_dir(path, prefix .. f .. PATHSEP)
            end
          end
        end
      end
    end
    
    scan_dir(artifacts_path, "")
    
    if core.project_dir then
      local ws_files = system.list_dir(core.project_dir)
      if ws_files then
        for _, f in ipairs(ws_files) do
          if not f:match("^%.") then
            local ext = f:match("%.([^%.]+)$")
            ext = ext and ext:lower() or ""
            if ext == "docx" or ext == "pdf" or ext == "pptx" or ext == "xlsx" or ext == "csv" then
              local path = core.project_dir .. PATHSEP .. f
              if not seen[path] then
                table.insert(items, { text = "[Workspace] " .. f, path = path })
                seen[path] = true
              end
            end
          end
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
          local ext = item.path:match("%.([^%.]+)$")
          ext = ext and ext:lower() or ""
          if ext == "docx" or ext == "pdf" or ext == "png" or ext == "jpg" or ext == "xlsx" or ext == "pptx" then
            if PLATFORM == "Windows" then
              system.exec("start \"\" \"" .. item.path .. "\"")
            elseif PLATFORM == "Mac OS X" then
              system.exec("open \"" .. item.path .. "\"")
            else
              system.exec("xdg-open \"" .. item.path .. "\"")
            end
          else
            core.root_view:open_doc(core.open_doc(item.path))
          end
        end
      end,
      suggest = function(text)
        return common.fuzzy_match(items, text)
      end
    })
  end


-- ── Commands ──────────────────────────────────────────────────────────────────
command.add(nil, {
  -- Modern Aether aliases (alongside antigravity:* for 100% backward compatibility)
  ["aether:toggle"] = function() command.perform "antigravity:toggle" end,
  ["aether:focus"] = function() command.perform "antigravity:focus" end,
  ["aether:explain"] = function() command.perform "antigravity:explain" end,
  ["aether:refactor"] = function() command.perform "antigravity:refactor" end,
  ["aether:fix"] = function() command.perform "antigravity:fix" end,
  ["aether:tests"] = function() command.perform "antigravity:tests" end,
  ["aether:docs"] = function() command.perform "antigravity:docs" end,
  ["aether:submit"] = function(prompt) command.perform("antigravity:submit", prompt) end,
  ["aether:ask"] = function() command.perform "antigravity:ask" end,
  ["aether:auth"] = function() command.perform "antigravity:auth" end,

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
    core.command_view:enter("Ask Aether", {
      submit = function(text)
        command.perform("antigravity:submit", text)
      end
    })
  end,
  ["antigravity:auth"] = function()
    local cur_tool = config.ai_sidebar and config.ai_sidebar.active_tool or "agy"
    local tdef = AI_TOOLS and AI_TOOLS.get(cur_tool)
    local tname = (tdef and tdef.name) or "Aether"
    
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
  ["antigravity:marketplace"] = function()
    if not instance or not instance.visible then
      command.perform("antigravity:toggle")
    end
    if instance then
      instance.show_skills_modal = true
      instance.show_tools_tab = false
      instance:fetch_marketplace()
      core.redraw = true
    end
  end,
  ["antigravity:mcp_tools"] = function()
    if not instance or not instance.visible then
      command.perform("antigravity:toggle")
    end
    if instance then
      instance.show_skills_modal = true
      instance.show_tools_tab = true
      instance:fetch_marketplace()
      core.redraw = true
    end
  end,
})

-- Hook the StatusView draw function to guarantee the entire status bar text is highly contrasted
local StatusView = require "core.statusview"
local old_sv_draw = StatusView.draw
function StatusView:draw(...)
  local old_text = style.text
  local old_dim = style.dim
  local old_accent = style.accent

  local bg = style.background2 or _COLOR_CACHE_13
  
  -- If background is light, force text to very dark colors
  if lum(bg[1], bg[2], bg[3]) > 128 then
    style.text = _COLOR_CACHE_32
    style.dim = _COLOR_CACHE_2
    style.accent = _COLOR_CACHE_29
  -- If background is dark, force text to very light colors
  else
    style.text = _COLOR_CACHE_27
    style.dim = _COLOR_CACHE_6
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
-- SKILLS MARKETPLACE MODAL
-- -----------------------------------------------------------------------------
  function AGView:draw_crawler_loader(bx, by, bw, bh)
    local P = get_palette()
    local t = system.get_time()
    
    local art = {
        "       .---.       ",
        "      /     \\      ",
        "     | O   O |     ",
        "  /\\_|  ._.  |_/\\  ",
        " / / |       | \\ \\ ",
        "/ /  `-------'  \\ \\",
        "     /       \\     ",
        "    /         \\    "
    }
    
    local logs = {
        "> [net] resolving raw.githubusercontent.com...",
        "> [tls] negotiating certificate exchange...",
        "> [warn] rate limit exceeded, falling back to git...",
        "> [git] executing shallow clone of remote registries...",
        "> [git] extracting tree objects...",
        "> [ast] parsing markdown ast tables...",
        "> [mem] sanitizing utf-8 mojibake...",
        "> [out] committing skills to local json cache..."
    }
    
    local l_idx = (math.floor(t * 1.5) % #logs) + 1
    
    local cx = bx + (bw / 2)
    local cy = by + (bh / 2) - 100 * SCALE
    
    for i, line in ipairs(art) do
        local color = (i % 2 == math.floor(t*2)%2) and P.fg_accent or P.fg_dim
        local lw = style.font:get_width(line)
          renderer.draw_text((style.big_font or style.font), line, cx - lw/2, cy + i * (style.big_font or style.font):get_height(), color)
    end
    
    cy = cy + #art * style.font:get_height() + 40 * SCALE
    
    local log_text = logs[l_idx]
    local sw = style.font:get_width(log_text)
    
      renderer.draw_text(style.font, log_text, cx - sw/2, cy, P.fg_dim)
    local spin = {"-", "\\", "|", "/"}
    local sp = spin[(math.floor(t * 15) % 4) + 1]
  end

  -- Helper for drawing clean framed boxes with optional borders
  local function draw_market_box(bx, by, bw, bh, bg_col, border_col)
    renderer.draw_rect(bx, by, bw, bh, bg_col)
    if border_col then
      renderer.draw_rect(bx, by, bw, 1, border_col)
      renderer.draw_rect(bx, by + bh - 1, bw, 1, border_col)
      renderer.draw_rect(bx, by, 1, bh, border_col)
      renderer.draw_rect(bx + bw - 1, by, 1, bh, border_col)
    end
  end

  -- Helper for pill badges
  local function draw_market_badge(bx, by, bw, bh, bg_col, border_col, text, font, text_col)
    draw_market_box(bx, by, bw, bh, bg_col, border_col)
    local f = get_ui_font(font)
    local tw = f:get_width(text)
    local th = f:get_height()
    draw_text_emoji(f, text, bx + math.floor((bw - tw) / 2), by + math.floor((bh - th) / 2), text_col)
  end

  -- Fast binary search text truncation with ellipsis
  local function truncate_text(font, text, max_w)
    if not text or text == "" then return "" end
    if font:get_width(text) <= max_w then return text end
    local ell = "..."
    local ell_w = font:get_width(ell)
    if max_w <= ell_w then return ell end
    local low, high, best = 1, #text, ""
    while low <= high do
      local mid = math.floor((low + high) / 2)
      local sub = text:sub(1, mid)
      if font:get_width(sub) + ell_w <= max_w then
        best = sub
        low = mid + 1
      else
        high = mid - 1
      end
    end
    return best .. ell
  end

  -- Clean word-wrapped lines with ellipsis truncation on final line
  local function draw_wrapped_lines(font, text, x, y, max_w, max_lines, color, line_spacing)
    if not text or text == "" then return y end
    local lh = font:get_height() + (line_spacing or (2 * SCALE))
    local cur_line = ""
    local line_count = 0
    local words = {}
    for w in text:gmatch("%S+") do table.insert(words, w) end
    
    for idx, w in ipairs(words) do
      local test_line = cur_line == "" and w or (cur_line .. " " .. w)
      if font:get_width(test_line) > max_w then
        if cur_line ~= "" then
          line_count = line_count + 1
          if line_count == max_lines and idx < #words then
            cur_line = truncate_text(font, cur_line .. " " .. w, max_w)
            renderer.draw_text(font, cur_line, x, y, color)
            y = y + lh
            cur_line = ""
            break
          else
            renderer.draw_text(font, cur_line, x, y, color)
            y = y + lh
            cur_line = w
            if line_count >= max_lines then break end
          end
        else
          line_count = line_count + 1
          local trunc = truncate_text(font, w, max_w)
          renderer.draw_text(font, trunc, x, y, color)
          y = y + lh
          cur_line = ""
          if line_count >= max_lines then break end
        end
      else
        cur_line = test_line
      end
    end
    
    if cur_line ~= "" and line_count < max_lines then
      renderer.draw_text(font, cur_line, x, y, color)
      y = y + lh
    end
    return y
  end

  local MARKET_SOURCES = {
    { id = "all",      label = "All Sources", icon = "🌐" },
    { id = "smithery", label = "Smithery",    icon = "⚡" },
    { id = "nvidia",   label = "NVIDIA NIM",  icon = "🟩" },
    { id = "github",   label = "GitHub",      icon = "🐙" },
  }

  local MARKET_CATEGORIES = {
    { id = "all",     label = "All" },
    { id = "coding",  label = "Coding & Dev" },
    { id = "design",  label = "Design & UI" },
    { id = "writing", label = "Writing & Docs" },
    { id = "data_ai", label = "Data & AI" },
    { id = "devops",  label = "DevOps & Cloud" },
    { id = "tools",   label = "Testing & Utilities" },
  }

  local function matches_market_category(cat, domain, title, desc)
    if not cat or cat == "all" then return true end
    local dom = (domain or ""):lower()
    local tit = (title or ""):lower()
    local dsc = (desc or ""):lower()
    local hay = dom .. " " .. tit .. " " .. dsc
    
    if cat == "coding" then
      return hay:find("code") or hay:find("development") or hay:find("dev") or hay:find("git") or hay:find("powershell") or hay:find("programming") or hay:find("script") or hay:find("api")
    elseif cat == "design" then
      return hay:find("design") or hay:find("art") or hay:find("creative") or hay:find("canvas") or hay:find("image") or hay:find("gif") or hay:find("ui") or hay:find("frontend") or hay:find("theme")
    elseif cat == "writing" then
      return hay:find("writing") or hay:find("doc") or hay:find("docx") or hay:find("pdf") or hay:find("epub") or hay:find("content") or hay:find("comms") or hay:find("article") or hay:find("book") or hay:find("gmail") or hay:find("mail")
    elseif cat == "data_ai" then
      return hay:find("data") or hay:find("ai") or hay:find("analysis") or hay:find("machine learning") or hay:find("ml") or hay:find("scientific") or hay:find("csv") or hay:find("xlsx") or hay:find("sql") or hay:find("postgres") or hay:find("sqlite") or hay:find("memory")
    elseif cat == "devops" then
      return hay:find("cloud") or hay:find("aws") or hay:find("infrastructure") or hay:find("server") or hay:find("devops") or hay:find("docker") or hay:find("deploy") or hay:find("slack") or hay:find("jira") or hay:find("github")
    elseif cat == "tools" then
      return hay:find("test") or hay:find("security") or hay:find("productivity") or hay:find("utility") or hay:find("automation") or hay:find("review") or hay:find("search") or hay:find("brave") or hay:find("fetch") or hay:find("everything") or hay:find("filesystem")
    end
    return true
  end

  function AGView:open_skill_preview(skill_obj)
    if not skill_obj then return end
    self.active_skill_preview = skill_obj
    self.preview_scroll_y = 0
    self.active_skill_preview._preview_md = "# " .. (skill_obj.title or skill_obj.name or skill_obj.id) .. "\nLoading documentation from repository...\n(Fetching manifest and details...)"
    core.redraw = true
    
    local bridge = USERDIR .. PATHSEP .. "scripts/ai_api_bridge.py"
    local tmp_file = USERDIR .. PATHSEP .. "scripts/.tmp_skill.json"
    local ok_json, json = pcall(require, "plugins.lsp.json")
    if ok_json then
      local f = io.open(tmp_file, "w")
      if f then
        f:write(json.encode(skill_obj))
        f:close()
      end
      core.add_thread(function()
        local p = process.start({"python", bridge, "--preview-skill", "FILE:" .. tmp_file})
        if p then
          local out = {}
          while true do
            local chunk = p:read_stdout()
            if not chunk or chunk == "" then
              if not p:running() then break end
              coroutine.yield(0.1)
            else
              table.insert(out, chunk)
            end
          end
          skill_obj._preview_md = table.concat(out)
          core.redraw = true
        end
      end)
    end
  end

  function AGView:draw_tool_config_sheet(x, y, w, h)
    local P = get_palette()
    local pad = 12 * SCALE
    local cfg_state = self.active_tool_config
    if not cfg_state then return end

    local tool_id = cfg_state.id
    local tool_title = cfg_state.title or tool_id
    local cfg = cfg_state.config or {}
    local env = cfg.env or {}
    local known_keys = cfg.known_keys or {}
    local test_res = cfg_state.test_result

    local cw = math.min(math.floor(w * 0.92), 800 * SCALE)
    local ch = math.min(math.floor(h * 0.92), 650 * SCALE)
    local cx = x + math.floor((w - cw) / 2)
    local cy = y + math.floor((h - ch) / 2)
    self._cfg_modal_rect = { x = cx, y = cy, w = cw, h = ch }

    -- Backdrop overlay
    renderer.draw_rect(x, y, w, h, {0, 0, 0, 230})

    -- Dialog box frame
    draw_market_box(cx, cy, cw, ch, P.bg, P.border)

    -- Header Bar
    local hdr_h = 44 * SCALE
    renderer.draw_rect(cx, cy, cw, hdr_h, P.bg_darker)
    renderer.draw_rect(cx, cy + hdr_h - 1, cw, 1, P.border)

    local mf = get_ui_font(style.font)
    local mf_big = get_bold_font() or get_ui_font(style.big_font or style.font)

    draw_text_emoji(mf, "⚙️", cx + pad, cy + math.floor((hdr_h - mf:get_height()) / 2), P.fg_accent)

    local h_title = "Configure MCP Server: " .. tool_title
    local trunc_ht = truncate_text(mf_big, h_title, cw - 120 * SCALE)
    draw_text_emoji(mf_big, trunc_ht, cx + pad + 24 * SCALE, cy + math.floor((hdr_h - mf_big:get_height()) / 2), P.fg)

    -- Close (✕) button
    local cb_sz = 26 * SCALE
    local cb_x = cx + cw - pad - cb_sz
    local cb_y = cy + math.floor((hdr_h - cb_sz) / 2)
    self._cfg_close_btn = { x = cb_x, y = cb_y, w = cb_sz, h = cb_sz }
    local is_hov_close = self.hover_cfg_close
    draw_market_box(cb_x, cb_y, cb_sz, cb_sz, is_hov_close and _COLOR_CACHE_5 or P.bg_btn, is_hov_close and _COLOR_CACHE_12 or P.border)
    local xw = mf:get_width("✕")
    draw_text_emoji(mf, "✕", cb_x + math.floor((cb_sz - xw) / 2), cb_y + math.floor((cb_sz - mf:get_height()) / 2), is_hov_close and _COLOR_CACHE_12 or P.fg_muted)

    -- Content layout
    local cur_y = cy + hdr_h + pad
    local inner_w = cw - 2 * pad

    -- 1. Live Health Handshake Banner
    local banner_h = 54 * SCALE
    local b_bg = P.bg_darker
    local b_border = P.border
    local b_status_icon = "🔄"
    local b_status_text = "Testing Handshake & Stdio Connection..."
    local b_sub_text = "Verifying MCP protocol handshake..."
    local b_color = P.fg_dim

    if test_res then
      if test_res.status == "connected" then
        b_bg = {35, 134, 54, 30}
        b_border = {46, 160, 67, 220}
        b_status_icon = "🟢"
        local count = test_res.tool_count or 0
        b_status_text = "Handshake Successful — " .. tostring(count) .. " Tools Active & Ready"
        local tools_list = ""
        if test_res.tools and #test_res.tools > 0 then
          local names = {}
          for idx, t in ipairs(test_res.tools) do
            if idx <= 4 then table.insert(names, type(t) == "table" and (t.name or t.id) or tostring(t)) end
          end
          tools_list = "Tools: " .. table.concat(names, ", ") .. (#test_res.tools > 4 and "..." or "")
        end
        b_sub_text = tools_list ~= "" and tools_list or "Stdio process is responding normally."
        b_color = {76, 175, 80, 255}
      elseif test_res.status == "error" then
        b_bg = {218, 54, 51, 30}
        b_border = {248, 81, 73, 220}
        b_status_icon = "🔴"
        b_status_text = "Connection Failed / Needs Auth"
        b_sub_text = test_res.message or "Unable to complete MCP initialize handshake."
        b_color = _COLOR_CACHE_12
      end
    end

    draw_market_box(cx + pad, cur_y, inner_w, banner_h, b_bg, b_border)
    draw_text_emoji(mf_big, b_status_icon, cx + pad + 12 * SCALE, cur_y + 10 * SCALE, b_color)
    draw_text_emoji(mf_big, truncate_text(mf_big, b_status_text, inner_w - 175 * SCALE), cx + pad + 38 * SCALE, cur_y + 10 * SCALE, b_color)
    renderer.draw_text(mf, truncate_text(mf, b_sub_text, inner_w - 175 * SCALE), cx + pad + 38 * SCALE, cur_y + 32 * SCALE, P.fg_muted)

    -- Test Ping Button on Right of Banner
    local tb_w = mf:get_width("⚡ Test Handshake") + 16 * SCALE
    local tb_h = 28 * SCALE
    local tb_x = cx + pad + inner_w - tb_w - 10 * SCALE
    local tb_y = cur_y + math.floor((banner_h - tb_h) / 2)
    self._cfg_test_btn = { x = tb_x, y = tb_y, w = tb_w, h = tb_h }
    local is_hov_tb = self.hover_cfg_test
    draw_market_box(tb_x, tb_y, tb_w, tb_h, is_hov_tb and P.bg_btn_hl or P.bg_btn, P.border)
    draw_text_emoji(mf, "⚡ Test Handshake", tb_x + 8 * SCALE, tb_y + math.floor((tb_h - mf:get_height()) / 2), is_hov_tb and P.fg_accent or P.fg)

    cur_y = cur_y + banner_h + 10 * SCALE

    -- 2. Browser Auth Card (OAuth & Web Tokens)
    local auth_h = 42 * SCALE
    draw_market_box(cx + pad, cur_y, inner_w, auth_h, P.bg_darker, P.border)
    draw_text_emoji(mf_big, "🌐", cx + pad + 12 * SCALE, cur_y + math.floor((auth_h - mf:get_height()) / 2), P.fg_accent)
    draw_text_emoji(mf_big, "OAuth / Browser Authorization", cx + pad + 36 * SCALE, cur_y + 6 * SCALE, P.fg)
    renderer.draw_text(mf, "Authenticate via browser OAuth or view developer settings.", cx + pad + 36 * SCALE, cur_y + 24 * SCALE, P.fg_muted)

    local ab_w = mf:get_width("Open Auth Page ↗") + 16 * SCALE
    local ab_h = 26 * SCALE
    local ab_x = cx + pad + inner_w - ab_w - 10 * SCALE
    local ab_y = cur_y + math.floor((auth_h - ab_h) / 2)
    self._cfg_auth_btn = { x = ab_x, y = ab_y, w = ab_w, h = ab_h }
    local is_hov_ab = self.hover_cfg_auth
    draw_market_box(ab_x, ab_y, ab_w, ab_h, is_hov_ab and P.bg_btn_hl or P.bg_btn, is_hov_ab and P.fg_accent or P.border)
    draw_text_emoji(mf, "Open Auth Page ↗", ab_x + 8 * SCALE, ab_y + math.floor((ab_h - mf:get_height()) / 2), is_hov_ab and P.fg_accent or P.fg)

    cur_y = cur_y + auth_h + 12 * SCALE

    -- 3. Environment Variables & API Keys Section
    renderer.draw_text(mf_big, "Environment Variables & Credentials", cx + pad, cur_y, P.fg)

    local av_w = mf:get_width("+ Add Variable") + 14 * SCALE
    local av_h = 22 * SCALE
    local av_x = cx + pad + inner_w - av_w
    local av_y = cur_y - 2 * SCALE
    self._cfg_add_var_btn = { x = av_x, y = av_y, w = av_w, h = av_h }
    local is_hov_av = self.hover_cfg_add_var
    draw_market_box(av_x, av_y, av_w, av_h, is_hov_av and P.bg_btn_hl or P.bg_btn, P.border)
    renderer.draw_text(mf, "+ Add Variable", av_x + 7 * SCALE, av_y + math.floor((av_h - mf:get_height()) / 2), is_hov_av and P.fg_accent or P.fg_muted)

    cur_y = cur_y + 24 * SCALE

    local all_keys_set = {}
    local all_keys_list = {}
    for _, k in ipairs(known_keys) do
      if not all_keys_set[k] then
        all_keys_set[k] = true
        table.insert(all_keys_list, k)
      end
    end
    for k, _ in pairs(env) do
      if not all_keys_set[k] then
        all_keys_set[k] = true
        table.insert(all_keys_list, k)
      end
    end

    self._cfg_env_edit_btns = {}
    self._cfg_env_clear_btns = {}

    local env_table_h = 160 * SCALE
    draw_market_box(cx + pad, cur_y, inner_w, env_table_h, P.bg_darker, P.border)

    if #all_keys_list == 0 then
      local no_env_txt = "No specific environment variables configured."
      local no_sub_txt = "Click '+ Add Variable' above if this tool requires API keys or tokens."
      renderer.draw_text(mf, no_env_txt, cx + pad + 16 * SCALE, cur_y + 20 * SCALE, P.fg_dim)
      renderer.draw_text(mf, no_sub_txt, cx + pad + 16 * SCALE, cur_y + 40 * SCALE, P.fg_muted)
    else
      local row_h = 30 * SCALE
      local r_y = cur_y + 4 * SCALE
      for idx, key_name in ipairs(all_keys_list) do
        if idx <= 5 then
          local val = env[key_name]
          local is_set = (val ~= nil and val ~= "")

          local kn_w = mf:get_width(key_name) + 12 * SCALE
          draw_market_badge(cx + pad + 8 * SCALE, r_y + 3 * SCALE, kn_w, 22 * SCALE, P.bg_input, P.border, key_name, mf, is_set and P.fg or _COLOR_CACHE_12)

          local val_x = cx + pad + 8 * SCALE + kn_w + 12 * SCALE
          if is_set then
            local masked = string.rep("•", math.min(#val, 16)) .. (#val > 16 and "..." or "")
            renderer.draw_text(mf, masked, val_x, r_y + 6 * SCALE, {76, 175, 80, 255})
          else
            renderer.draw_text(mf, "(not set / required)", val_x, r_y + 6 * SCALE, P.fg_muted)
          end

          local ed_w = mf:get_width(is_set and "Edit" or "Set") + 16 * SCALE
          local ed_h = 22 * SCALE
          local clr_w = mf:get_width("Clear") + 16 * SCALE
          local clr_h = 22 * SCALE
          local clr_x = cx + pad + inner_w - clr_w - 8 * SCALE
          local ed_x = is_set and (clr_x - ed_w - 6 * SCALE) or clr_x

          local is_hov_ed = self.hover_cfg_env_edit == key_name
          draw_market_box(ed_x, r_y + 3 * SCALE, ed_w, ed_h, is_hov_ed and P.bg_btn_hl or P.bg_btn, P.border)
          renderer.draw_text(mf, is_set and "Edit" or "Set", ed_x + 8 * SCALE, r_y + 3 * SCALE + math.floor((ed_h - mf:get_height()) / 2), is_hov_ed and P.fg_accent or P.fg)
          table.insert(self._cfg_env_edit_btns, { key = key_name, current_val = val or "", x = ed_x, y = r_y + 3 * SCALE, w = ed_w, h = ed_h })

          if is_set then
            local is_hov_clr = self.hover_cfg_env_clear == key_name
            draw_market_box(clr_x, r_y + 3 * SCALE, clr_w, clr_h, is_hov_clr and _COLOR_CACHE_5 or P.bg_btn, is_hov_clr and _COLOR_CACHE_12 or P.border)
            renderer.draw_text(mf, "Clear", clr_x + 8 * SCALE, r_y + 3 * SCALE + math.floor((clr_h - mf:get_height()) / 2), is_hov_clr and _COLOR_CACHE_12 or P.fg_muted)
            table.insert(self._cfg_env_clear_btns, { key = key_name, x = clr_x, y = r_y + 3 * SCALE, w = clr_w, h = clr_h })
          end

          r_y = r_y + row_h
        end
      end
    end

    cur_y = cur_y + env_table_h + 10 * SCALE

    -- 4. Command & Process Arguments
    local cmd_str = (cfg.command or "npx") .. " " .. table.concat(cfg.args or {}, " ")
    renderer.draw_text(mf_big, "Command & Process Arguments", cx + pad, cur_y, P.fg)
    cur_y = cur_y + 18 * SCALE

    local cmd_box_h = 30 * SCALE
    draw_market_box(cx + pad, cur_y, inner_w, cmd_box_h, P.bg_input, P.border)
    local trunc_cmd = truncate_text(mf, cmd_str, inner_w - 95 * SCALE)
    renderer.draw_text(mf, trunc_cmd, cx + pad + 10 * SCALE, cur_y + math.floor((cmd_box_h - mf:get_height()) / 2), P.fg_dim)

    local ec_w = mf:get_width("Edit Args") + 16 * SCALE
    local ec_h = 22 * SCALE
    local ec_x = cx + pad + inner_w - ec_w - 6 * SCALE
    local ec_y = cur_y + math.floor((cmd_box_h - ec_h) / 2)
    self._cfg_edit_cmd_btn = { x = ec_x, y = ec_y, w = ec_w, h = ec_h }
    local is_hov_ec = self.hover_cfg_edit_cmd
    draw_market_box(ec_x, ec_y, ec_w, ec_h, is_hov_ec and P.bg_btn_hl or P.bg_btn, P.border)
    renderer.draw_text(mf, "Edit Args", ec_x + 8 * SCALE, ec_y + math.floor((ec_h - mf:get_height()) / 2), is_hov_ec and P.fg_accent or P.fg)

    -- 5. Footer Actions (Cancel, Save & Connect)
    local ftr_h = 52 * SCALE
    local ftr_y = cy + ch - ftr_h
    renderer.draw_rect(cx, ftr_y, cw, ftr_h, P.bg_darker)
    renderer.draw_rect(cx, ftr_y, cw, 1, P.border)

    local can_txt = "Close"
    local c_w = mf:get_width(can_txt) + 24 * SCALE
    local c_h = 30 * SCALE
    local c_x = cx + pad
    local c_y = ftr_y + math.floor((ftr_h - c_h) / 2)
    self._cfg_cancel_btn = { x = c_x, y = c_y, w = c_w, h = c_h }
    local is_hov_can = self.hover_cfg_cancel
    draw_market_box(c_x, c_y, c_w, c_h, is_hov_can and P.bg_btn_hl or P.bg_btn, P.border)
    renderer.draw_text(mf, can_txt, c_x + 12 * SCALE, c_y + math.floor((c_h - mf:get_height()) / 2), is_hov_can and P.fg_accent or P.fg)

    local save_txt = "💾 Save Configuration & Connect"
    local s_w = mf:get_width(save_txt) + 24 * SCALE
    local s_h = 30 * SCALE
    local s_x = cx + cw - pad - s_w
    local s_y = ftr_y + math.floor((ftr_h - s_h) / 2)
    self._cfg_save_btn = { x = s_x, y = s_y, w = s_w, h = s_h }
    local is_hov_save = self.hover_cfg_save
    draw_market_box(s_x, s_y, s_w, s_h, is_hov_save and P.fg or P.fg_accent, nil)
    draw_text_emoji(mf, save_txt, s_x + 12 * SCALE, s_y + math.floor((s_h - mf:get_height()) / 2), P.bg)
  end

  function AGView:draw_skills_modal(x, y, w, h)
    local P = get_palette()
    local pad = 12 * SCALE
    
    -- Backdrop overlay
    renderer.draw_rect(x, y, w, h, {0, 0, 0, 220})
    
    -- Responsive modal dimensions
    local mw = math.min(math.floor(w * 0.95), 1150 * SCALE)
    local mh = math.min(math.floor(h * 0.93), 850 * SCALE)
    local mx = x + math.floor((w - mw) / 2)
    local my = y + math.floor((h - mh) / 2)
    self._market_modal_rect = {x = mx, y = my, w = mw, h = mh}
    
    -- Window surface
    draw_market_box(mx, my, mw, mh, P.bg, P.border)
    
    -- Top Header Bar
    local hdr_h = 44 * SCALE
    renderer.draw_rect(mx, my, mw, hdr_h, P.bg_darker)
    renderer.draw_rect(mx, my + hdr_h - 1, mw, 1, P.border)
    
    -- Header Title & Subtitle Badge
    local mf = get_ui_font(style.font)
    local mf_big = get_bold_font() or get_ui_font(style.big_font or style.font)
    local h_title = "Extensions & Skills"
    local h_title_font = get_ui_font(style.big_font or style.font)
    renderer.draw_text(h_title_font, h_title, mx + pad, my + math.floor((hdr_h - h_title_font:get_height()) / 2), P.fg)
    
    local mode_pill = self.show_tools_tab and "MCP Servers" or "AI Skills"
    local mp_w = mf:get_width(mode_pill) + 14 * SCALE
    local mp_x = mx + pad + h_title_font:get_width(h_title) + 12 * SCALE
    local mp_y = my + math.floor((hdr_h - 22 * SCALE) / 2)
    draw_market_badge(mp_x, mp_y, mp_w, 22 * SCALE, P.bg_btn, P.border, mode_pill, mf, P.fg_accent)
    
    -- Close button (✕)
    local cb_sz = 26 * SCALE
    local cb_x = mx + mw - pad - cb_sz
    local cb_y = my + math.floor((hdr_h - cb_sz) / 2)
    self._market_close_btn = {x = cb_x, y = cb_y, w = cb_sz, h = cb_sz}
    local is_hov_close = self.hover_market_close
    draw_market_box(cb_x, cb_y, cb_sz, cb_sz, is_hov_close and _COLOR_CACHE_5 or P.bg_btn, is_hov_close and _COLOR_CACHE_12 or P.border)
    local x_w = mf:get_width("✕")
    draw_text_emoji(mf, "✕", cb_x + math.floor((cb_sz - x_w)/2), cb_y + math.floor((cb_sz - mf:get_height())/2), is_hov_close and _COLOR_CACHE_12 or P.fg_muted)
    
    local ty = my + hdr_h + pad
    
    -- Row 1: Segmented Switchers & Action Buttons
    local seg_h = 30 * SCALE
    local sw_skills_w = mf:get_width("⚡ AI Skills") + 18 * SCALE
    local sw_tools_w  = mf:get_width("🔌 MCP Tools") + 18 * SCALE
    local sw_total_w  = sw_skills_w + sw_tools_w
    
    -- Type Segmented Pill Container
    local seg_type_x = mx + pad
    draw_market_box(seg_type_x, ty, sw_total_w, seg_h, P.bg_darker, P.border)
    
    self._market_tab_skills_btn = {x = seg_type_x, y = ty, w = sw_skills_w, h = seg_h}
    self._market_tab_tools_btn  = {x = seg_type_x + sw_skills_w, y = ty, w = sw_tools_w, h = seg_h}
    
    local is_skills_tab = not self.show_tools_tab
    local is_hov_tab1 = self.hover_market_tab == "skills"
    local is_hov_tab2 = self.hover_market_tab == "tools"
    
    if is_skills_tab then
      draw_market_box(seg_type_x, ty, sw_skills_w, seg_h, P.bg_btn_hl, P.border)
    elseif is_hov_tab1 then
      draw_market_box(seg_type_x, ty, sw_skills_w, seg_h, P.bg_btn, nil)
    end
    draw_text_emoji(mf, "⚡ AI Skills", seg_type_x + math.floor((sw_skills_w - mf:get_width("⚡ AI Skills"))/2), ty + math.floor((seg_h - mf:get_height())/2), is_skills_tab and P.fg_accent or P.fg_dim)
    
    if not is_skills_tab then
      draw_market_box(seg_type_x + sw_skills_w, ty, sw_tools_w, seg_h, P.bg_btn_hl, P.border)
    elseif is_hov_tab2 then
      draw_market_box(seg_type_x + sw_skills_w, ty, sw_tools_w, seg_h, P.bg_btn, nil)
    end
    draw_text_emoji(mf, "🔌 MCP Tools", seg_type_x + sw_skills_w + math.floor((sw_tools_w - mf:get_width("🔌 MCP Tools"))/2), ty + math.floor((seg_h - mf:get_height())/2), (not is_skills_tab) and P.fg_accent or P.fg_dim)
    
    -- View Mode Segmented Pill (Marketplace vs Installed)
    local inst_count = self.show_tools_tab and (self.installed_tools_count or 0) or (self.installed_skills_count or 0)
    local v_market_txt = "🌐 Marketplace"
    local v_inst_txt = "📦 Installed (" .. tostring(inst_count) .. ")"
    local vm_w = mf:get_width(v_market_txt) + 18 * SCALE
    local vi_w = mf:get_width(v_inst_txt) + 18 * SCALE
    local seg_view_x = seg_type_x + sw_total_w + 12 * SCALE
    
    draw_market_box(seg_view_x, ty, vm_w + vi_w, seg_h, P.bg_darker, P.border)
    self._market_browse_btn = {x = seg_view_x, y = ty, w = vm_w, h = seg_h}
    self._market_installed_btn = {x = seg_view_x + vm_w, y = ty, w = vi_w, h = seg_h}
    self._market_manage_btn = self._market_installed_btn -- backward compatibility
    
    local is_installed_view = self.show_installed_skills
    local is_hov_v1 = self.hover_market_view == "browse"
    local is_hov_v2 = self.hover_market_view == "installed" or self.hover_market_view == "manage"
    
    if not is_installed_view then
      draw_market_box(seg_view_x, ty, vm_w, seg_h, P.bg_btn_hl, P.border)
    elseif is_hov_v1 then
      draw_market_box(seg_view_x, ty, vm_w, seg_h, P.bg_btn, nil)
    end
    draw_text_emoji(mf, v_market_txt, seg_view_x + math.floor((vm_w - mf:get_width(v_market_txt))/2), ty + math.floor((seg_h - mf:get_height())/2), (not is_installed_view) and P.fg_accent or P.fg_dim)
    
    if is_installed_view then
      draw_market_box(seg_view_x + vm_w, ty, vi_w, seg_h, P.bg_btn_hl, P.border)
    elseif is_hov_v2 then
      draw_market_box(seg_view_x + vm_w, ty, vi_w, seg_h, P.bg_btn, nil)
    end
    draw_text_emoji(mf, v_inst_txt, seg_view_x + vm_w + math.floor((vi_w - mf:get_width(v_inst_txt))/2), ty + math.floor((seg_h - mf:get_height())/2), is_installed_view and P.fg_accent or P.fg_dim)
    
    -- Right Action Buttons: Refresh & Add
    local ref_txt = "🔄 Refresh"
    local ref_w = mf:get_width(ref_txt) + 18 * SCALE
    local ref_x = mx + mw - pad - ref_w
    self._market_refresh_btn = {x = ref_x, y = ty, w = ref_w, h = seg_h}
    local is_hov_ref = self.hover_market_ref
    draw_market_box(ref_x, ty, ref_w, seg_h, is_hov_ref and P.bg_btn_hl or P.bg_btn, P.border)
    draw_text_emoji(mf, ref_txt, ref_x + math.floor((ref_w - mf:get_width(ref_txt))/2), ty + math.floor((seg_h - mf:get_height())/2), is_hov_ref and P.fg_accent or P.fg)
    
    local add_txt = self.show_tools_tab and "➕ Add MCP" or "➕ Add Skill"
    local add_w = mf:get_width(add_txt) + 18 * SCALE
    local add_x = ref_x - 10 * SCALE - add_w
    self._market_add_btn = {x = add_x, y = ty, w = add_w, h = seg_h}
    local is_hov_add = self.hover_market_add
    draw_market_box(add_x, ty, add_w, seg_h, is_hov_add and P.bg_btn_hl or P.bg_btn, P.border)
    draw_text_emoji(mf, add_txt, add_x + math.floor((add_w - mf:get_width(add_txt))/2), ty + math.floor((seg_h - mf:get_height())/2), is_hov_add and P.fg_accent or P.fg)
    
    ty = ty + seg_h + 10 * SCALE
    
    -- Row 1.5: Source Switcher Row (All Sources vs Smithery vs NVIDIA NIM vs GitHub)
    local src_lbl = "Source:"
    local src_lbl_w = mf:get_width(src_lbl) + 10 * SCALE
    renderer.draw_text(mf, src_lbl, mx + pad, ty + math.floor((24 * SCALE - mf:get_height()) / 2), P.fg_muted)

    local s_chip_x = mx + pad + src_lbl_w
    local s_chip_h = 24 * SCALE
    self._market_source_chips = {}
    for _, src in ipairs(MARKET_SOURCES) do
      local s_txt = src.icon .. " " .. src.label
      local sw = mf:get_width(s_txt) + 16 * SCALE
      local is_active = (self.market_source or "all") == src.id
      local is_hov = self.hover_market_source == src.id

      local bg_col = is_active and P.bg_btn_hl or (is_hov and P.bg_btn_hl or P.bg_darker)
      local border_col = is_active and (src.id == "nvidia" and {46, 160, 67, 255} or P.fg_accent) or P.border
      local txt_col = is_active and (src.id == "nvidia" and {76, 175, 80, 255} or P.fg_accent) or (is_hov and P.fg or P.fg_dim)

      draw_market_box(s_chip_x, ty, sw, s_chip_h, bg_col, border_col)
      draw_text_emoji(mf, s_txt, s_chip_x + 8 * SCALE, ty + math.floor((s_chip_h - mf:get_height()) / 2), txt_col)
      table.insert(self._market_source_chips, {id = src.id, x = s_chip_x, y = ty, w = sw, h = s_chip_h})
      s_chip_x = s_chip_x + sw + 8 * SCALE
    end

    local ar_txt = "➕ Add Repo"
    local ar_w = mf:get_width(ar_txt) + 16 * SCALE
    local ar_x = mx + mw - pad - ar_w
    self._market_add_repo_btn = {x = ar_x, y = ty, w = ar_w, h = s_chip_h}
    local is_hov_ar = self.hover_market_add_repo
    draw_market_box(ar_x, ty, ar_w, s_chip_h, is_hov_ar and P.bg_btn_hl or P.bg_btn, is_hov_ar and P.fg_accent or P.border)
    draw_text_emoji(mf, ar_txt, ar_x + 8 * SCALE, ty + math.floor((s_chip_h - mf:get_height()) / 2), is_hov_ar and P.fg_accent or P.fg_muted)

    ty = ty + s_chip_h + 10 * SCALE
    
    -- Row 2: Modern Search Input Bar
    local s_h = 28 * SCALE
    local s_w = mw - 2 * pad
    self._market_search_btn = {x = mx + pad, y = ty, w = s_w, h = s_h}
    local is_hov_search = self.hover_market_search
    draw_market_box(mx + pad, ty, s_w, s_h, P.bg_darker, is_hov_search and P.fg_accent or P.border)
    
    draw_text_emoji(mf, "🔍", mx + pad + 10 * SCALE, ty + math.floor((s_h - mf:get_height())/2), P.fg_muted)
    
    local has_query = self.market_search_query and self.market_search_query ~= ""
    local q_text = has_query and self.market_search_query or "Search skills, tools, prompts, authors, keywords..."
    local q_color = has_query and P.fg or P.fg_dim
    draw_text_emoji(mf, q_text, mx + pad + 32 * SCALE, ty + math.floor((s_h - mf:get_height())/2), q_color)
    
    if has_query then
      local clr_w = 22 * SCALE
      local clr_x = mx + pad + s_w - clr_w - 4 * SCALE
      local clr_y = ty + math.floor((s_h - clr_w) / 2)
      self._market_search_clear_btn = {x = clr_x, y = clr_y, w = clr_w, h = clr_w}
      local is_hov_clr = self.hover_market_search_clear
      draw_market_box(clr_x, clr_y, clr_w, clr_w, is_hov_clr and _COLOR_CACHE_5 or P.bg_btn, P.border)
      local xw = mf:get_width("✕")
      draw_text_emoji(mf, "✕", clr_x + math.floor((clr_w - xw)/2), clr_y + math.floor((clr_w - mf:get_height())/2), is_hov_clr and _COLOR_CACHE_12 or P.fg_dim)
    else
      self._market_search_clear_btn = nil
    end
    
    ty = ty + s_h + 10 * SCALE
    
    -- Row 3: Category Filter Chips Row
    local chip_x = mx + pad
    local chip_y = ty
    local chip_h = 24 * SCALE
    local max_chip_x = mx + mw - pad
    
    self._market_cat_chips = {}
    for _, cat in ipairs(MARKET_CATEGORIES) do
      local cw = style.font:get_width(cat.label) + 16 * SCALE
      if chip_x + cw > max_chip_x and chip_x > mx + pad then
        chip_x = mx + pad
        chip_y = chip_y + chip_h + 6 * SCALE
      end
      
      local is_active = (self.market_category or "all") == cat.id
      local is_hov = self.hover_market_cat == cat.id
      
      local bg_col = is_active and P.bg_btn_hl or (is_hov and P.bg_btn_hl or P.bg_btn)
      local border_col = is_active and P.fg_accent or P.border
      local txt_col = is_active and P.fg_accent or (is_hov and P.fg or P.fg_dim)
      
      draw_market_box(chip_x, chip_y, cw, chip_h, bg_col, border_col)
      local tw = style.font:get_width(cat.label)
      renderer.draw_text(style.font, cat.label, chip_x + math.floor((cw - tw) / 2), chip_y + math.floor((chip_h - style.font:get_height()) / 2), txt_col)
      
      table.insert(self._market_cat_chips, {id = cat.id, x = chip_x, y = chip_y, w = cw, h = chip_h})
      chip_x = chip_x + cw + 8 * SCALE
    end
    ty = chip_y + chip_h + 12 * SCALE
    
    -- Handle loading state with animated spider crawler
    if type(self.marketplace_skills) == "string" then
      if self.marketplace_skills == "loading" then
        self:draw_crawler_loader(mx, ty, mw, (my + mh) - ty)
      else
        local err_box_w = 400 * SCALE
        local err_box_h = 100 * SCALE
        local ex = mx + math.floor((mw - err_box_w)/2)
        local ey = ty + 60 * SCALE
        draw_market_box(ex, ey, err_box_w, err_box_h, P.bg_darker, _COLOR_CACHE_12)
        renderer.draw_text((style.big_font or style.font), "Connection Notice", ex + 20 * SCALE, ey + 20 * SCALE, _COLOR_CACHE_12)
        renderer.draw_text(style.font, "Unable to reach remote marketplace registry.", ex + 20 * SCALE, ey + 48 * SCALE, P.fg_dim)
        renderer.draw_text(style.font, "Check internet connection or click Refresh.", ex + 20 * SCALE, ey + 68 * SCALE, P.fg_muted)
      end
      core.redraw = true
      return
    end
    
    -- Filter items by selected category
    local raw_items = self.marketplace_skills or {}
    local display_items = {}
    if type(raw_items) == "table" then
      for _, item in ipairs(raw_items) do
        if item.id and item.id ~= "error" then
          if matches_market_category(self.market_category or "all", item.domain, item.title or item.name, item.description) then
            table.insert(display_items, item)
          end
        end
      end
    end
    
    self._market_rects = {}
    self._market_action_btns = {}
    
    local content_y = ty
    local clip_h = (my + mh - pad) - content_y
    self._market_clip_rect = {x = mx, y = content_y, w = mw, h = clip_h}
    core.push_clip_rect(mx, content_y, mw, clip_h)
    
    self.market_scroll_y = self.market_scroll_y or 0
    local scroll_ty = content_y - self.market_scroll_y
    
    -- Empty state if 0 matching items
    if #display_items == 0 then
      local empty_cy = content_y + math.floor(clip_h / 2) - 50 * SCALE
      local no_msg = "No " .. (self.show_tools_tab and "MCP tools" or "skills") .. " found"
      if self.market_search_query and self.market_search_query ~= "" then
        no_msg = no_msg .. " matching \"" .. self.market_search_query .. "\""
      end
      local mw_txt = (style.big_font or style.font):get_width(no_msg)
      renderer.draw_text((style.big_font or style.font), no_msg, mx + math.floor((mw - mw_txt)/2), empty_cy, P.fg)
      
      local hint_txt = "Try adjusting your search query or selecting a different category."
      local hw_txt = style.font:get_width(hint_txt)
      renderer.draw_text(style.font, hint_txt, mx + math.floor((mw - hw_txt)/2), empty_cy + 28 * SCALE, P.fg_dim)
      
      local clr_btn_txt = "Clear All Filters"
      local cb_w = style.font:get_width(clr_btn_txt) + 24 * SCALE
      local cb_h = 28 * SCALE
      local cb_x = mx + math.floor((mw - cb_w) / 2)
      local cb_y = empty_cy + 65 * SCALE
      self._market_clear_filters_btn = {x = cb_x, y = cb_y, w = cb_w, h = cb_h}
      local is_hov_clr = self.hover_market_clr_filters
      draw_market_box(cb_x, cb_y, cb_w, cb_h, is_hov_clr and P.bg_btn_hl or P.bg_btn, P.border)
      renderer.draw_text(style.font, clr_btn_txt, cb_x + 12 * SCALE, cb_y + math.floor((cb_h - style.font:get_height())/2), is_hov_clr and P.fg_accent or P.fg)
    else
      -- Responsive column layout
      local gw = mw - 2 * pad
      local cols = gw > 820 * SCALE and 3 or (gw > 480 * SCALE and 2 or 1)
      local col_gap = 12 * SCALE
      local row_gap = 12 * SCALE
      local col_w = math.floor((gw - (cols - 1) * col_gap) / cols)
      local sh = 145 * SCALE
      
      for i, skill in ipairs(display_items) do
        local row = math.floor((i - 1) / cols)
        local col = (i - 1) % cols
        local sx = mx + pad + col * (col_w + col_gap)
        local sy = scroll_ty + row * (sh + row_gap)
        
        -- Cull cards completely outside visible clipping bounds for peak performance
        if sy + sh >= content_y and sy <= content_y + clip_h then
          local is_installed = false
          if self.show_tools_tab then
            is_installed = self.installed_tools_map and self.installed_tools_map[skill.id]
          else
            is_installed = self.installed_skills_map and self.installed_skills_map[skill.id]
          end
          
          local is_hover = self.hover_market_skill == skill.id
          local card_bg = is_hover and P.bg_btn_hl or P.bg_darker
          local card_border = is_hover and P.fg_accent or P.border
          draw_market_box(sx, sy, col_w, sh, card_bg, card_border)
          
          -- Card Header: Type Icon + Title + Branded Source Pill
          local t_icon = self.show_tools_tab and "🔌" or "⚡"
          draw_text_emoji(mf, t_icon, sx + 12 * SCALE, sy + 12 * SCALE, P.fg_accent)

          local src_tag = (skill.source == "nvidia") and "🟩 NVIDIA" or ((skill.source == "github") and "🐙 GitHub" or "⚡ Smithery")
          local st_col = (skill.source == "nvidia") and {76, 175, 80, 255} or ((skill.source == "github") and {170, 140, 240, 255} or P.fg_accent)
          local st_bg = (skill.source == "nvidia") and {35, 134, 54, 30} or P.bg_btn
          local st_border = (skill.source == "nvidia") and {46, 160, 67, 180} or P.border
          local st_w = mf:get_width(src_tag) + 12 * SCALE
          local st_x = sx + col_w - 12 * SCALE - st_w
          draw_market_badge(st_x, sy + 11 * SCALE, st_w, 20 * SCALE, st_bg, st_border, src_tag, mf, st_col)

          local title_str = skill.title or skill.name or skill.id
          local max_title_w = col_w - 40 * SCALE - st_w - 10 * SCALE
          local trunc_title = truncate_text(mf_big, title_str, max_title_w)
          draw_text_emoji(mf_big, trunc_title, sx + 32 * SCALE, sy + 11 * SCALE, P.fg)

          -- Subheader: Author handle & Domain Pill & Star rating
          local cat_label = skill.domain or (self.show_tools_tab and "MCP Tool" or "General")
          local author_txt = "@" .. (skill.author or skill.namespace or "community") .. "  •  " .. cat_label
          renderer.draw_text(mf, author_txt, sx + 12 * SCALE, sy + 38 * SCALE, P.fg_muted)

          if skill.stars and skill.stars > 0 then
            local star_txt = "★ " .. tostring(skill.stars)
            local star_w = mf:get_width(star_txt)
            draw_text_emoji(mf, star_txt, sx + col_w - 12 * SCALE - star_w, sy + 38 * SCALE, {242, 201, 76, 255})
          elseif skill.verified then
            local ver_txt = "✓ Verified"
            local ver_w = mf:get_width(ver_txt)
            draw_text_emoji(mf, ver_txt, sx + col_w - 12 * SCALE - ver_w, sy + 38 * SCALE, P.fg_accent)
          end
          
          -- Description: up to 2 wrapped lines with ellipsis
          local desc_txt = skill.description or "No description provided."
          draw_wrapped_lines(mf, desc_txt, sx + 12 * SCALE, sy + 62 * SCALE, col_w - 24 * SCALE, 2, P.fg_dim, 2 * SCALE)
          
          -- Card Footer: Status badge (Left) & Dedicated Action Buttons (Right)
          local footer_y = sy + sh - 34 * SCALE
          
          if is_installed then
            if self.show_tools_tab then
              local h_info = self.tool_health_map and self.tool_health_map[skill.id]
              if h_info and h_info.status == "connected" then
                local b_txt = "🟢 Active"
                local bw = mf:get_width(b_txt) + 14 * SCALE
                draw_market_badge(sx + 12 * SCALE, footer_y, bw, 22 * SCALE, {35, 134, 54, 35}, {46, 160, 67, 255}, b_txt, mf, {76, 175, 80, 255})
              elseif h_info and h_info.status == "error" then
                local b_txt = "🔴 Needs Auth"
                local bw = mf:get_width(b_txt) + 14 * SCALE
                draw_market_badge(sx + 12 * SCALE, footer_y, bw, 22 * SCALE, _COLOR_CACHE_5, _COLOR_CACHE_12, b_txt, mf, _COLOR_CACHE_12)
              elseif h_info and h_info.status == "testing" then
                local b_txt = "🔄 Testing"
                local bw = mf:get_width(b_txt) + 14 * SCALE
                draw_market_badge(sx + 12 * SCALE, footer_y, bw, 22 * SCALE, P.bg_btn, P.border, b_txt, mf, P.fg_accent)
              else
                local inst_badge_w = mf:get_width("✓ Installed") + 14 * SCALE
                draw_market_badge(sx + 12 * SCALE, footer_y, inst_badge_w, 22 * SCALE, {76, 175, 80, 35}, {76, 175, 80, 255}, "✓ Installed", mf, {76, 175, 80, 255})
              end
            else
              local inst_badge_w = mf:get_width("✓ Installed") + 14 * SCALE
              draw_market_badge(sx + 12 * SCALE, footer_y, inst_badge_w, 22 * SCALE, {76, 175, 80, 35}, {76, 175, 80, 255}, "✓ Installed", mf, {76, 175, 80, 255})
            end
          else
            renderer.draw_text(mf, "Open Source", sx + 12 * SCALE, footer_y + 4 * SCALE, P.fg_muted)
          end
          
          -- Right Action Buttons
          local det_txt = "Details"
          local det_w = style.font:get_width(det_txt) + 12 * SCALE
          local det_h = 24 * SCALE
          
          local act_w = 64 * SCALE
          local act_h = 24 * SCALE
          local act_x = sx + col_w - 12 * SCALE - act_w

          if self.show_tools_tab and is_installed then
            local cfg_txt = "⚙️ Config"
            local cfg_w = mf:get_width(cfg_txt) + 12 * SCALE
            local cfg_h = 24 * SCALE
            local cfg_x = act_x - 6 * SCALE - cfg_w
            local det_pos_x = cfg_x - 6 * SCALE - det_w

            -- Details button
            local is_hov_det = self.hover_market_action == ("details:" .. skill.id)
            draw_market_box(det_pos_x, footer_y, det_w, det_h, is_hov_det and P.bg_btn_hl or P.bg_btn, P.border)
            renderer.draw_text(style.font, det_txt, det_pos_x + math.floor((det_w - style.font:get_width(det_txt))/2), footer_y + math.floor((det_h - style.font:get_height())/2), is_hov_det and P.fg_accent or P.fg)
            table.insert(self._market_action_btns, {key = "details:" .. skill.id, item = skill, action = "details", x = det_pos_x, y = footer_y, w = det_w, h = det_h})

            -- Config button
            local is_hov_cfg = self.hover_market_action == ("config:" .. skill.id)
            draw_market_box(cfg_x, footer_y, cfg_w, cfg_h, is_hov_cfg and P.bg_btn_hl or P.bg_btn, is_hov_cfg and P.fg_accent or P.border)
            draw_text_emoji(mf, cfg_txt, cfg_x + 6 * SCALE, footer_y + math.floor((cfg_h - mf:get_height())/2), is_hov_cfg and P.fg_accent or P.fg)
            table.insert(self._market_action_btns, {key = "config:" .. skill.id, item = skill, action = "config", x = cfg_x, y = footer_y, w = cfg_w, h = cfg_h})

            -- Remove button
            local is_hov_un = self.hover_market_action == ("uninstall:" .. skill.id)
            draw_market_box(act_x, footer_y, act_w, act_h, is_hov_un and _COLOR_CACHE_5 or P.bg_btn, is_hov_un and _COLOR_CACHE_12 or P.border)
            local rm_txt = "Remove"
            renderer.draw_text(style.font, rm_txt, act_x + math.floor((act_w - style.font:get_width(rm_txt))/2), footer_y + math.floor((act_h - style.font:get_height())/2), is_hov_un and _COLOR_CACHE_12 or P.fg_muted)
            table.insert(self._market_action_btns, {key = "uninstall:" .. skill.id, item = skill, action = "uninstall", x = act_x, y = footer_y, w = act_w, h = act_h})
          else
            local det_x = act_x - 6 * SCALE - det_w
            
            -- Details button
            local is_hov_det = self.hover_market_action == ("details:" .. skill.id)
            draw_market_box(det_x, footer_y, det_w, det_h, is_hov_det and P.bg_btn_hl or P.bg_btn, P.border)
            renderer.draw_text(style.font, det_txt, det_x + math.floor((det_w - style.font:get_width(det_txt))/2), footer_y + math.floor((det_h - style.font:get_height())/2), is_hov_det and P.fg_accent or P.fg)
            table.insert(self._market_action_btns, {key = "details:" .. skill.id, item = skill, action = "details", x = det_x, y = footer_y, w = det_w, h = det_h})
            
            -- Primary Action button
            if self.show_installed_skills then
              local is_hov_un = self.hover_market_action == ("uninstall:" .. skill.id)
              draw_market_box(act_x, footer_y, act_w, act_h, is_hov_un and _COLOR_CACHE_5 or P.bg_btn, is_hov_un and _COLOR_CACHE_12 or P.border)
              local rm_txt = "Remove"
              renderer.draw_text(style.font, rm_txt, act_x + math.floor((act_w - style.font:get_width(rm_txt))/2), footer_y + math.floor((act_h - style.font:get_height())/2), is_hov_un and _COLOR_CACHE_12 or P.fg_muted)
              table.insert(self._market_action_btns, {key = "uninstall:" .. skill.id, item = skill, action = "uninstall", x = act_x, y = footer_y, w = act_w, h = act_h})
            else
              if is_installed then
                draw_market_box(act_x, footer_y, act_w, act_h, P.bg_btn, P.border)
                local in_txt = "Installed"
                renderer.draw_text(style.font, in_txt, act_x + math.floor((act_w - style.font:get_width(in_txt))/2), footer_y + math.floor((act_h - style.font:get_height())/2), P.fg_dim)
              else
                local is_hov_in = self.hover_market_action == ("install:" .. skill.id)
                draw_market_box(act_x, footer_y, act_w, act_h, is_hov_in and P.fg or P.fg_accent, nil)
                local in_txt = self.show_tools_tab and "Install" or "Install"
                renderer.draw_text(style.font, in_txt, act_x + math.floor((act_w - style.font:get_width(in_txt))/2), footer_y + math.floor((act_h - style.font:get_height())/2), P.bg)
                table.insert(self._market_action_btns, {key = "install:" .. skill.id, item = skill, action = "install", x = act_x, y = footer_y, w = act_w, h = act_h})
              end
            end
          end
          
          table.insert(self._market_rects, {id = skill.id, item = skill, x = sx, y = sy, w = col_w, h = sh})
        end
      end
      
      -- Calculate content height and max scroll
      local total_rows = math.ceil(#display_items / cols)
      local total_h = total_rows * (sh + row_gap)
      
      -- Pagination UI for Marketplace
      if not self.show_installed_skills and self.market_total_pages and self.market_total_pages > 1 then
        local p_y = scroll_ty + total_h + 16 * SCALE
        local p_text = "Page " .. tostring(self.market_page or 1) .. " of " .. tostring(self.market_total_pages)
        local p_w = style.font:get_width(p_text)
        local cx = mx + math.floor(mw / 2)
        
        local b_prev = "‹ Previous"
        local b_prev_w = style.font:get_width(b_prev) + 16 * SCALE
        local bx_prev = cx - math.floor(p_w / 2) - 20 * SCALE - b_prev_w
        local is_hov_prev = self.hover_market_prev
        self._market_prev_btn = {x = bx_prev, y = p_y, w = b_prev_w, h = 24 * SCALE}
        draw_market_box(bx_prev, p_y, b_prev_w, 24 * SCALE, is_hov_prev and P.bg_btn_hl or P.bg_btn, P.border)
        renderer.draw_text(style.font, b_prev, bx_prev + 8 * SCALE, p_y + math.floor((24 * SCALE - style.font:get_height())/2), (self.market_page or 1) > 1 and (is_hov_prev and P.fg_accent or P.fg) or P.fg_dim)
        
        renderer.draw_text(style.font, p_text, cx - math.floor(p_w / 2), p_y + math.floor((24 * SCALE - style.font:get_height())/2), P.fg)
        
        local b_next = "Next ›"
        local b_next_w = style.font:get_width(b_next) + 16 * SCALE
        local bx_next = cx + math.floor(p_w / 2) + 20 * SCALE
        local is_hov_next = self.hover_market_next
        self._market_next_btn = {x = bx_next, y = p_y, w = b_next_w, h = 24 * SCALE}
        draw_market_box(bx_next, p_y, b_next_w, 24 * SCALE, is_hov_next and P.bg_btn_hl or P.bg_btn, P.border)
        renderer.draw_text(style.font, b_next, bx_next + 8 * SCALE, p_y + math.floor((24 * SCALE - style.font:get_height())/2), (self.market_page or 1) < self.market_total_pages and (is_hov_next and P.fg_accent or P.fg) or P.fg_dim)
        
        total_h = total_h + 50 * SCALE
      end
      
      self.market_max_scroll = math.max(0, total_h - clip_h + 20 * SCALE)
      
      -- Scrollbar indicator
      if self.market_max_scroll > 0 then
        local sb_w = 4 * SCALE
        local sb_x = mx + mw - sb_w - 4 * SCALE
        local sb_h = math.max(24 * SCALE, math.floor(clip_h * (clip_h / (total_h + clip_h))))
        local scroll_pct = (self.market_scroll_y or 0) / self.market_max_scroll
        local sb_y = content_y + math.floor(scroll_pct * (clip_h - sb_h))
        renderer.draw_rect(sb_x, content_y, sb_w, clip_h, P.bg_darker)
        renderer.draw_rect(sb_x, sb_y, sb_w, sb_h, P.fg_muted)
      end
    end
    
    core.pop_clip_rect()
    
    -- ========================================================================
    -- DETAIL / PREVIEW MODAL SHEET
    -- ========================================================================
    if self.active_skill_preview then
      local skill = self.active_skill_preview
      local pw = math.min(mw - 30 * SCALE, 820 * SCALE)
      local ph = math.min(mh - 30 * SCALE, 680 * SCALE)
      local px = mx + math.floor((mw - pw) / 2)
      local py = my + math.floor((mh - ph) / 2)
      self._preview_modal_rect = {x = px, y = py, w = pw, h = ph}
      
      -- Backdrop overlay
      renderer.draw_rect(x, y, w, h, {0, 0, 0, 220})
      
      -- Sheet frame
      draw_market_box(px, py, pw, ph, P.bg, P.border)
      
      -- Sheet Header
      local ph_h = 44 * SCALE
      renderer.draw_rect(px, py, pw, ph_h, P.bg_darker)
      renderer.draw_rect(px, py + ph_h - 1, pw, 1, P.border)
      
      local p_title = skill.title or skill.name or skill.id
      renderer.draw_text(style.big_font or style.font, p_title, px + 16 * SCALE, py + math.floor((ph_h - (style.big_font or style.font):get_height())/2), P.fg)
      
      local p_domain = skill.domain or (self.show_tools_tab and "MCP Server" or "AI Skill")
      local p_dom_w = style.font:get_width(p_domain) + 14 * SCALE
      local p_dom_x = px + pw - 50 * SCALE - p_dom_w
      draw_market_badge(p_dom_x, py + math.floor((ph_h - 22 * SCALE)/2), p_dom_w, 22 * SCALE, P.bg_btn, P.border, p_domain, style.font, P.fg_accent)
      
      -- Close ✕ button
      local p_cb_sz = 26 * SCALE
      local p_cb_x = px + pw - 12 * SCALE - p_cb_sz
      local p_cb_y = py + math.floor((ph_h - p_cb_sz)/2)
      self._preview_close_btn = {x = p_cb_x, y = p_cb_y, w = p_cb_sz, h = p_cb_sz}
      local is_hov_pcb = self.hover_preview_close
      draw_market_box(p_cb_x, p_cb_y, p_cb_sz, p_cb_sz, is_hov_pcb and _COLOR_CACHE_5 or P.bg_btn, is_hov_pcb and _COLOR_CACHE_12 or P.border)
      local pxw = mf:get_width("✕")
      draw_text_emoji(mf, "✕", p_cb_x + math.floor((p_cb_sz - pxw)/2), p_cb_y + math.floor((p_cb_sz - mf:get_height())/2), is_hov_pcb and _COLOR_CACHE_12 or P.fg_muted)
      
      -- Metadata bar: Package ID, Author, and Repository link
      local meta_h = 32 * SCALE
      local meta_y = py + ph_h
      renderer.draw_rect(px, meta_y, pw, meta_h, P.bg_input)
      renderer.draw_rect(px, meta_y + meta_h - 1, pw, 1, P.border)
      
      local id_txt = "ID: " .. skill.id
      local id_w = style.font:get_width(id_txt) + 12 * SCALE
      draw_market_badge(px + 16 * SCALE, meta_y + math.floor((meta_h - 20 * SCALE)/2), id_w, 20 * SCALE, P.bg_darker, P.border, id_txt, style.font, P.fg_muted)
      
      local p_auth_txt = "Author: @" .. (skill.author or skill.namespace or "community")
      renderer.draw_text(style.font, p_auth_txt, px + 24 * SCALE + id_w, meta_y + math.floor((meta_h - style.font:get_height())/2), P.fg_dim)
      
      if skill.repo_url and skill.repo_url ~= "" then
        local repo_btn_txt = "↗ View Repository"
        local rb_w = mf:get_width(repo_btn_txt) + 14 * SCALE
        local rb_h = 22 * SCALE
        local rb_x = px + pw - 16 * SCALE - rb_w
        local rb_y = meta_y + math.floor((meta_h - rb_h)/2)
        self._preview_repo_btn = {x = rb_x, y = rb_y, w = rb_w, h = rb_h}
        local is_hov_repo = self.hover_preview_repo
        draw_market_box(rb_x, rb_y, rb_w, rb_h, is_hov_repo and P.bg_btn_hl or P.bg_btn, P.border)
        draw_text_emoji(mf, repo_btn_txt, rb_x + 7 * SCALE, rb_y + math.floor((rb_h - mf:get_height())/2), is_hov_repo and P.fg_accent or P.fg)
      else
        self._preview_repo_btn = nil
      end
      
      -- Markdown Content Box
      local ftr_h = 52 * SCALE
      local mb_y = meta_y + meta_h + 10 * SCALE
      local mb_h = py + ph - ftr_h - mb_y
      
      if mb_h > 0 then
        draw_market_box(px + 16 * SCALE, mb_y, pw - 32 * SCALE, mb_h, P.bg_darker, P.border)
        core.push_clip_rect(px + 24 * SCALE, mb_y + 8 * SCALE, pw - 48 * SCALE, mb_h - 16 * SCALE)
        
        self.preview_scroll_y = self.preview_scroll_y or 0
        local ldy = mb_y + 12 * SCALE - self.preview_scroll_y
        local md_text = skill._preview_md or (skill.description or "No preview available.")
        
        for line in (md_text .. "\n"):gmatch("([^\n]*)\n") do
          if line:match("^#%s+") then
            -- H1
            local heading = line:gsub("^#%s+", "")
            if ldy > mb_y - 20 * SCALE and ldy < mb_y + mb_h then
              renderer.draw_text(style.big_font or style.font, heading, px + 24 * SCALE, ldy, P.fg)
            end
            ldy = ldy + (style.big_font or style.font):get_height() + 8 * SCALE
          elseif line:match("^##%s+") then
            -- H2
            local heading = line:gsub("^##%s+", "")
            if ldy > mb_y - 20 * SCALE and ldy < mb_y + mb_h then
              renderer.draw_text(style.font, heading, px + 24 * SCALE, ldy, P.fg_accent)
              renderer.draw_rect(px + 24 * SCALE, ldy + style.font:get_height() + 2 * SCALE, pw - 64 * SCALE, 1, P.border)
            end
            ldy = ldy + style.font:get_height() + 10 * SCALE
          elseif line:match("^```") then
            -- Code block fence
            if ldy > mb_y - 20 * SCALE and ldy < mb_y + mb_h then
              renderer.draw_rect(px + 24 * SCALE, ldy, pw - 64 * SCALE, 1 * SCALE, P.border)
            end
            ldy = ldy + 6 * SCALE
          elseif line == "" then
            ldy = ldy + math.floor(style.font:get_height() / 2)
          else
            -- Word wrap normal line
            local max_w = pw - 64 * SCALE
            local cur = ""
            for word in line:gmatch("%S+") do
              if style.font:get_width(cur .. " " .. word) > max_w then
                if cur ~= "" then
                  if ldy > mb_y - 20 * SCALE and ldy < mb_y + mb_h then
                    renderer.draw_text(style.font, cur, px + 24 * SCALE, ldy, P.fg)
                  end
                  ldy = ldy + style.font:get_height() + 3 * SCALE
                end
                cur = word
              else
                cur = cur == "" and word or (cur .. " " .. word)
              end
            end
            if cur ~= "" then
              if ldy > mb_y - 20 * SCALE and ldy < mb_y + mb_h then
                renderer.draw_text(style.font, cur, px + 24 * SCALE, ldy, P.fg)
              end
              ldy = ldy + style.font:get_height() + 3 * SCALE
            end
          end
        end
        
        core.pop_clip_rect()
        
        local total_md_h = (ldy + self.preview_scroll_y) - (mb_y + 12 * SCALE)
        self.preview_max_scroll = math.max(0, total_md_h - mb_h + 30 * SCALE)
        
        -- Preview scrollbar indicator
        if self.preview_max_scroll > 0 then
          local p_sb_w = 4 * SCALE
          local p_sb_x = px + pw - 22 * SCALE
          local p_sb_h = math.max(20 * SCALE, math.floor(mb_h * (mb_h / (total_md_h + mb_h))))
          local p_pct = (self.preview_scroll_y or 0) / self.preview_max_scroll
          local p_sb_y = mb_y + math.floor(p_pct * (mb_h - p_sb_h))
          renderer.draw_rect(p_sb_x, mb_y, p_sb_w, mb_h, P.bg_darker)
          renderer.draw_rect(p_sb_x, p_sb_y, p_sb_w, p_sb_h, P.fg_muted)
        end
      end
      
      -- Sheet Footer & Action Buttons
      local ftr_y = py + ph - ftr_h
      renderer.draw_rect(px, ftr_y, pw, ftr_h, P.bg_darker)
      renderer.draw_rect(px, ftr_y, pw, 1, P.border)
      
      -- Close / Cancel button
      local btn_cancel_txt = "Close"
      local bc_w = style.font:get_width(btn_cancel_txt) + 24 * SCALE
      local bc_h = 30 * SCALE
      local bc_x = px + 16 * SCALE
      local bc_y = ftr_y + math.floor((ftr_h - bc_h) / 2)
      self._preview_cancel_btn = {x = bc_x, y = bc_y, w = bc_w, h = bc_h}
      local is_hov_can = self.hover_preview_cancel
      draw_market_box(bc_x, bc_y, bc_w, bc_h, is_hov_can and P.bg_btn_hl or P.bg_btn, P.border)
      renderer.draw_text(style.font, btn_cancel_txt, bc_x + 12 * SCALE, bc_y + math.floor((bc_h - style.font:get_height())/2), is_hov_can and P.fg_accent or P.fg)
      
      -- Install or Uninstall button
      local is_inst = false
      if self.show_tools_tab then
        is_inst = self.installed_tools_map and self.installed_tools_map[skill.id]
      else
        is_inst = self.installed_skills_map and self.installed_skills_map[skill.id]
      end
      
      if is_inst then
        if self.show_tools_tab then
          local cfg_txt = "⚙️ Configure"
          local cfb_w = mf:get_width(cfg_txt) + 20 * SCALE
          local cfb_h = 30 * SCALE
          local cfb_x = px + pw - 16 * SCALE - cfb_w
          local cfb_y = ftr_y + math.floor((ftr_h - cfb_h) / 2)
          self._preview_config_btn = {x = cfb_x, y = cfb_y, w = cfb_w, h = cfb_h}
          local is_hov_pcfg = self.hover_preview_config
          draw_market_box(cfb_x, cfb_y, cfb_w, cfb_h, is_hov_pcfg and P.bg_btn_hl or P.bg_btn, is_hov_pcfg and P.fg_accent or P.border)
          draw_text_emoji(mf, cfg_txt, cfb_x + 10 * SCALE, cfb_y + math.floor((cfb_h - mf:get_height())/2), is_hov_pcfg and P.fg_accent or P.fg)

          local un_txt = "🗑 Uninstall"
          local un_w = mf:get_width(un_txt) + 20 * SCALE
          local un_h = 30 * SCALE
          local un_x = cfb_x - 10 * SCALE - un_w
          local un_y = ftr_y + math.floor((ftr_h - un_h) / 2)
          self._preview_uninstall_btn = {x = un_x, y = un_y, w = un_w, h = un_h}
          local is_hov_un = self.hover_preview_uninstall
          draw_market_box(un_x, un_y, un_w, un_h, is_hov_un and _COLOR_CACHE_5 or P.bg_btn, is_hov_un and _COLOR_CACHE_12 or P.border)
          draw_text_emoji(mf, un_txt, un_x + 10 * SCALE, un_y + math.floor((un_h - mf:get_height())/2), is_hov_un and _COLOR_CACHE_12 or P.fg_muted)
        else
          self._preview_config_btn = nil
          local un_txt = "🗑 Uninstall Extension"
          local un_w = mf:get_width(un_txt) + 24 * SCALE
          local un_h = 30 * SCALE
          local un_x = px + pw - 16 * SCALE - un_w
          local un_y = ftr_y + math.floor((ftr_h - un_h) / 2)
          self._preview_uninstall_btn = {x = un_x, y = un_y, w = un_w, h = un_h}
          local is_hov_un = self.hover_preview_uninstall
          draw_market_box(un_x, un_y, un_w, un_h, is_hov_un and _COLOR_CACHE_5 or P.bg_btn, is_hov_un and _COLOR_CACHE_12 or P.border)
          draw_text_emoji(mf, un_txt, un_x + 12 * SCALE, un_y + math.floor((un_h - mf:get_height())/2), is_hov_un and _COLOR_CACHE_12 or P.fg_muted)
        end
      else
        self._preview_config_btn = nil
        local in_txt = self.show_tools_tab and "⚡ Setup & Install" or "⬇ Install Extension"
        local in_w = mf:get_width(in_txt) + 24 * SCALE
        local in_h = 30 * SCALE
        local in_x = px + pw - 16 * SCALE - in_w
        local in_y = ftr_y + math.floor((ftr_h - in_h) / 2)
        self._preview_install_btn = {x = in_x, y = in_y, w = in_w, h = in_h}
        local is_hov_in = self.hover_preview_install
        draw_market_box(in_x, in_y, in_w, in_h, is_hov_in and P.fg or P.fg_accent, nil)
        draw_text_emoji(mf, in_txt, in_x + 12 * SCALE, in_y + math.floor((in_h - mf:get_height())/2), P.bg)
      end
    end

    if self.active_tool_config then
      self:draw_tool_config_sheet(x, y, w, h)
    end
  end

-- -----------------------------------------------------------------------------
-- SAFE HISTORY TREE INJECTION
-- -----------------------------------------------------------------------------
local original_draw = AGView.draw
function AGView:draw_dynamic_form(x, y, w)
    local P = get_palette()
    local pad = 10 * SCALE
    local ty = y
    
    if not self.active_skill or not self.active_skill.ui_manifest then return ty end
    
    local manifest = self.active_skill.ui_manifest
    if type(manifest) ~= "table" then return ty end
    
    self.skill_state = self.skill_state or {}
    self._form_rects = {} -- for click handling
    
    -- Draw Header
    renderer.draw_text((style.big_font or style.font), self.active_skill.title or "Skill Config", x + pad, ty, P.fg_accent)
    ty = ty + (style.big_font or style.font):get_height() + pad
    
    -- Draw Inputs
    for _, input in ipairs(manifest) do
        local val = self.skill_state[input.id]
        if input.type == "toggle" then
            if val == nil then val = input.default end
            self.skill_state[input.id] = val
            
            local bx = x + pad
            local bw = 20 * SCALE
            local bh = 20 * SCALE
            renderer.draw_rect(bx, ty, bw, bh, val and P.fg_accent or P.bg_btn)
            renderer.draw_text(style.font, input.name or input.id, bx + bw + 10 * SCALE, ty + (bh - style.font:get_height())/2, P.fg)
            
            table.insert(self._form_rects, {type="toggle", id=input.id, x=bx, y=ty, w=w-2*pad, h=bh, val=val})
            ty = ty + bh + pad
        elseif input.type == "file_picker" then
            local display = val and (val:match("[^/\\]+$") or val) or ("Select " .. (input.label or input.name or input.id))
            local bw = w - 2*pad
            local bh = 25 * SCALE
            renderer.draw_rect(x + pad, ty, bw, bh, P.bg_btn)
            renderer.draw_text(style.font, display, x + pad + 10 * SCALE, ty + (bh - style.font:get_height())/2, P.fg)
            
            table.insert(self._form_rects, {type="file", id=input.id, x=x+pad, y=ty, w=bw, h=bh})
            ty = ty + bh + pad
        elseif input.type == "secret_input" or input.type == "text" then
            local display = val and (input.type == "secret_input" and string.rep("*", #val) or val) or ("Enter " .. (input.label or input.name or input.id))
            local bw = w - 2*pad
            local bh = 25 * SCALE
            renderer.draw_rect(x + pad, ty, bw, bh, P.bg_btn)
            renderer.draw_text(style.font, display, x + pad + 10 * SCALE, ty + (bh - style.font:get_height())/2, P.fg)
            
            table.insert(self._form_rects, {type="text", id=input.id, x=x+pad, y=ty, w=bw, h=bh})
            ty = ty + bh + pad
        end
    end
    return ty
end

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
  
  if self.show_skills_modal then
    self:draw_skills_modal(self.position.x, self.position.y, self.size.x, self.size.y)
  end
end

-- ============================================================================
-- GLOBAL MOUSE EVENT INTERCEPTION FOR FULLSCREEN MODALS
-- ============================================================================
local RootView = require "core.rootview"

local old_root_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks, ...)
  local ag = rawget(_G, "AG_INSTANCE")
  if ag and (ag.show_skills_modal or ag.show_api_view or ag.show_usage_view) then
    ag:on_mouse_pressed(button, x, y, clicks)
    return true -- intercept!
  end
  return old_root_pressed(self, button, x, y, clicks, ...)
end

local old_root_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, dx, dy)
  local ag = rawget(_G, "AG_INSTANCE")
  if ag and (ag.show_skills_modal or ag.show_api_view or ag.show_usage_view) then
    ag:on_mouse_moved(x, y, dx, dy)
    return true
  end
  return old_root_moved(self, x, y, dx, dy)
end

local old_root_wheel = RootView.on_mouse_wheel
function RootView:on_mouse_wheel(y, x, dx, dy, ...)
  local ag = rawget(_G, "AG_INSTANCE")
  if ag and (ag.show_skills_modal or ag.show_api_view or ag.show_usage_view) then
    ag:on_mouse_wheel(y)
    return true
  end
  return old_root_wheel(self, y, x, dx, dy, ...)
end

-- Save instance globally for the rootview to access
local old_ag_new = AGView.new
function AGView:new(...)
  old_ag_new(self, ...)
  rawset(_G, "AG_INSTANCE", self)
end
if instance then rawset(_G, "AG_INSTANCE", instance) end


