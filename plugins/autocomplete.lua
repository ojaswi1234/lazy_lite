-- mod-version:3
-- Premium Autocomplete, LSP, Snippets & Tailwind IntelliSense Engine for Lite XL
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local RootView = require "core.rootview"
local DocView = require "core.docview"
local Doc = require "core.doc"

config.plugins.autocomplete = common.merge({
  min_len = 1,
  max_height = 9,
  max_suggestions = 100,
  max_symbols = 4000,
  desc_font_size = 12,
}, config.plugins.autocomplete)

local autocomplete = {}

autocomplete.map = {}
autocomplete.map_manually = {}
autocomplete.icons = {}
autocomplete.on_close = nil

local triggered_manually = false
local partial = ""
local suggestions_offset = 1
local suggestions_idx = 1
local suggestions = {}
local last_line, last_col
local box_rect = { x = 0, y = 0, w = 0, h = 0 }

local mt = { __tostring = function(t) return t.text or "" end }

function autocomplete.add_icon(name, icon, font, color)
  autocomplete.icons[name] = { icon = icon, font = font, color = color }
end

function autocomplete.add(t, manually_triggered)
  local items = {}
  for text, info in pairs(t.items or {}) do
    if type(info) == "table" then
      local label = (type(text) == "string" and not tonumber(text)) and text or info.text or info.label or ""
      table.insert(
        items,
        setmetatable(
          {
            text = label,
            info = info.info or "Snippet",
            desc = info.desc,
            color = info.color,
            onhover = info.onhover,
            onselect = info.onselect,
            data = info.data
          },
          mt
        )
      )
    elseif type(text) == "number" and type(info) == "string" then
      table.insert(items, setmetatable({ text = info, info = nil }, mt))
    else
      local label = (type(text) == "string" and not tonumber(text)) and text or tostring(info)
      local info_str = (type(info) == "string" and type(text) == "string" and text ~= info) and info or nil
      table.insert(items, setmetatable({ text = label, info = info_str }, mt))
    end
  end

  local target_map = manually_triggered and autocomplete.map_manually or autocomplete.map
  target_map[t.name] = { files = t.files or ".*", items = items }
end

-- Open Document Symbol Indexer
local max_symbols = config.plugins.autocomplete.max_symbols

core.add_thread(function()
  local cache = setmetatable({}, { __mode = "k" })

  local function get_syntax_symbols(syms, doc)
    if doc.syntax and doc.syntax.symbols then
      for sym in pairs(doc.syntax.symbols) do
        syms[sym] = true
      end
    end
  end

  local function get_symbols(doc)
    local s = {}
    get_syntax_symbols(s, doc)
    if doc.disable_symbols then return s end
    local i = 1
    local symbols_count = 0
    while i <= #doc.lines do
      for sym in doc.lines[i]:gmatch(config.symbol_pattern) do
        if not s[sym] then
          symbols_count = symbols_count + 1
          if symbols_count > max_symbols then
            doc.disable_symbols = true
            return {}
          end
          s[sym] = true
        end
      end
      i = i + 1
      if i % 100 == 0 then coroutine.yield() end
    end
    return s
  end

  local function cache_is_valid(doc)
    local c = cache[doc]
    return c and c.last_change_id == doc:get_change_id()
  end

  while true do
    local syms = {}
    for _, doc in ipairs(core.docs) do
      if not cache_is_valid(doc) then
        cache[doc] = {
          last_change_id = doc:get_change_id(),
          symbols = get_symbols(doc)
        }
      end
      for sym in pairs(cache[doc].symbols) do
        syms[sym] = true
      end
      coroutine.yield()
    end

    autocomplete.add { name = "open-docs", items = syms }

    local valid = true
    while valid do
      coroutine.yield(1)
      for _, doc in ipairs(core.docs) do
        if not cache_is_valid(doc) then
          valid = false
          break
        end
      end
    end
  end
end)

local CommandView_ok, CommandView = pcall(require, "core.commandview")

local function is_command_view_active()
  if not core.active_view then return false end
  if core.command_view and core.active_view == core.command_view then
    return true
  end
  if CommandView_ok and core.active_view:is(CommandView) then
    return true
  end
  return false
end

local function is_editor_docview(view)
  if not view then return false end
  if is_command_view_active() then return false end
  if core.command_view and view == core.command_view then return false end
  if not (view:is(DocView) or (DocView and view:extends(DocView))) then
    return false
  end
  local doc = view.doc
  if not doc then return false end
  if core.command_view and doc == core.command_view.doc then
    return false
  end
  return true
end

local function get_active_view()
  local av = core.active_view
  if is_editor_docview(av) then
    return av
  end
  return nil
end

local function get_partial_symbol()
  local av = get_active_view()
  if not av or not av.doc then return "" end
  local doc = av.doc
  local line, col = doc:get_selection()
  local line_text = doc.lines[line] or ""
  local before = line_text:sub(1, col - 1)
  local sym = before:match("([%a_!%$][%w_%-%:%$]*)$") or before:match("([%w_%-%:%$]+)$") or ""
  return sym
end

local function reset_suggestions()
  local had_suggestions = #suggestions > 0
  suggestions_offset = 1
  suggestions_idx = 1
  suggestions = {}
  triggered_manually = false
  box_rect = { x = 0, y = 0, w = 0, h = 0 }

  local av = get_active_view()
  local doc = av and av.doc
  if autocomplete.on_close then
    autocomplete.on_close(doc, nil)
    autocomplete.on_close = nil
  end

  if had_suggestions then
    core.redraw = true
  end
end

local function matches_filter(filename, syntax_name, pattern)
  if not pattern or pattern == ".*" then return true end
  if type(pattern) == "table" then
    for _, p in ipairs(pattern) do
      if matches_filter(filename, syntax_name, p) then return true end
    end
    return false
  end
  if filename and filename ~= "" and filename:find(pattern) then return true end
  if syntax_name and syntax_name ~= "" then
    local p_clean = pattern:gsub("[%^%%%$%.%*%+%-%?%[%]]", ""):lower()
    if syntax_name:lower():find(p_clean) then return true end
  end
  return false
end

local function update_suggestions()
  local av = get_active_view()
  if not av or not av.doc then return end
  local doc = av.doc
  local filename = doc.filename or ""
  local syntax_name = doc.syntax and doc.syntax.name or ""

  local all_items = {}

  -- 1. Direct syntax keyword symbols for instantaneous matching
  if doc.syntax and doc.syntax.symbols then
    for sym, sym_type in pairs(doc.syntax.symbols) do
      local label = (type(sym_type) == "string" and #sym_type > 0) and sym_type or "Keyword"
      table.insert(all_items, setmetatable({ text = sym, info = label }, mt))
    end
  end

  -- 2. Registered plugins, snippets, and open-docs symbols
  for _, v in pairs(autocomplete.map) do
    if matches_filter(filename, syntax_name, v.files) then
      for _, item in pairs(v.items) do
        table.insert(all_items, item)
      end
    end
  end

  -- 3. LSP completions when active
  for _, v in pairs(autocomplete.map_manually) do
    if matches_filter(filename, syntax_name, v.files) then
      for _, item in pairs(v.items) do
        table.insert(all_items, item)
      end
    end
  end

  if #all_items == 0 then
    suggestions = {}
    core.redraw = true
    return
  end

  local needle = partial or ""
  local filtered = {}

  if #needle == 0 then
    filtered = all_items
  else
    local lower_needle = needle:lower()
    local exact = {}
    local prefix = {}
    local substr = {}
    local rest = {}

    for _, it in ipairs(all_items) do
      local text = tostring(it.text or it)
      local ltext = text:lower()
      if ltext == lower_needle then
        table.insert(exact, it)
      elseif ltext:sub(1, #lower_needle) == lower_needle then
        table.insert(prefix, it)
      elseif ltext:find(lower_needle, 1, true) then
        table.insert(substr, it)
      else
        table.insert(rest, it)
      end
    end

    for _, it in ipairs(exact) do table.insert(filtered, it) end
    for _, it in ipairs(prefix) do table.insert(filtered, it) end
    for _, it in ipairs(substr) do table.insert(filtered, it) end

    if #rest > 0 then
      local fuzzy_res = common.fuzzy_match(rest, needle)
      for _, it in ipairs(fuzzy_res) do
        table.insert(filtered, it)
      end
    end
  end

  suggestions = {}
  local seen = {}
  local count = 0
  local max_sug = config.plugins.autocomplete.max_suggestions or 100

  for _, it in ipairs(filtered) do
    local text = tostring(it.text or it)
    if not seen[text] then
      seen[text] = true
      count = count + 1
      table.insert(suggestions, it)
      if count >= max_sug then break end
    end
  end

  suggestions_idx = 1
  suggestions_offset = 1
  core.redraw = true
end

local last_max_width = 0
local function get_suggestions_rect(av)
  if #suggestions == 0 then
    last_max_width = 0
    return 0, 0, 0, 0
  end

  local line, col = av.doc:get_selection()
  local start_col = math.max(1, col - #partial)
  local lx, ly = av:get_line_screen_position(line)
  local col_x = av:get_col_x_offset(line, start_col)
  local x = lx + col_x
  local y = ly
  local lh = av:get_line_height()
  local font = av:get_font()
  local th = font:get_height()

  local ah = config.plugins.autocomplete.max_height or 9
  local show_count = math.min(#suggestions, ah)
  local start_index = suggestions_offset

  local max_width = 0
  for i = start_index, start_index + show_count - 1 do
    local s = suggestions[i]
    if s then
      local text = tostring(s.text or s)
      local w = font:get_width(text) + (s.color and 18 * SCALE or 0)
      if s.info then
        w = w + style.font:get_width(tostring(s.info)) + (style.padding.x * 2)
      end
      max_width = math.max(max_width, w)
    end
  end
  max_width = math.max(last_max_width, max_width)
  last_max_width = max_width

  max_width = max_width + (style.padding.x * 4) + (24 * SCALE)
  if max_width < 240 * SCALE then
    max_width = 240 * SCALE
  end
  if max_width > core.root_view.size.x - 20 then
    max_width = core.root_view.size.x - 20
  end

  local item_h = th + style.padding.y
  local total_height = show_count * item_h + item_h + (style.padding.y * 2)

  local final_x = x - style.padding.x
  if final_x + max_width > core.root_view.size.x - 10 then
    final_x = math.max(10, core.root_view.size.x - max_width - 10)
  end
  if final_x < 10 then final_x = 10 end

  local final_y = y + lh + 2
  if final_y + total_height > core.root_view.size.y - 10 then
    final_y = math.max(10, y - total_height - 2)
  end

  box_rect.x = final_x
  box_rect.y = final_y
  box_rect.w = max_width
  box_rect.h = total_height

  return box_rect.x, box_rect.y, box_rect.w, box_rect.h
end

local function wrap_line(line, max_chars)
  if #line > max_chars then
    local lines = {}
    local line_len = #line
    local new_line = ""
    local prev_char = ""
    local position = 0
    local indent = line:match("^%s+")
    for char in line:gmatch(".") do
      position = position + 1
      if #new_line < max_chars then
        new_line = new_line .. char
        prev_char = char
        if position >= line_len then
          table.insert(lines, new_line)
        end
      else
        if
          not prev_char:match("%s")
          and
          not string.sub(line, position+1, 1):match("%s")
          and
          position < line_len
        then
          new_line = new_line .. "-"
        end
        table.insert(lines, new_line)
        if indent then
          new_line = indent .. char
        else
          new_line = char
        end
      end
    end
    return lines
  end
  return line
end

local previous_scale = SCALE
local desc_font = style.code_font:copy(
  (config.plugins.autocomplete.desc_font_size or 12) * SCALE
)
local function draw_description_box(text, av, sx, sy, sw, sh)
  if previous_scale ~= SCALE then
    desc_font = style.code_font:copy(
      (config.plugins.autocomplete.desc_font_size or 12) * SCALE
    )
    previous_scale = SCALE
  end

  local font = desc_font
  local lh = font:get_height()
  local y = sy + style.padding.y
  local x = sx + sw + style.padding.x / 2
  local width = 0
  local char_width = font:get_width(" ")
  local draw_left = false

  local max_chars = 0
  if sx - av.position.x < av.size.x - (sx - av.position.x) - sw then
    max_chars = (((av.size.x + av.position.x) - x) / char_width) - 4
  else
    draw_left = true
    max_chars = ((sx - av.position.x - style.padding.x - style.scrollbar_size) / char_width) - 4
  end
  if max_chars < 15 then max_chars = 15 end

  local lines = {}
  for line in string.gmatch(text .. "\n", "(.-)\n") do
    local wrapper_lines = wrap_line(line, max_chars)
    if type(wrapper_lines) == "table" then
      for _, wrapped_line in pairs(wrapper_lines) do
        width = math.max(width, font:get_width(wrapped_line))
        table.insert(lines, wrapped_line)
      end
    else
      width = math.max(width, font:get_width(line))
      table.insert(lines, line)
    end
  end

  if draw_left then
    x = sx - width - (style.padding.x * 2) - 4
  end

  local height = #lines * font:get_height()
  local bg_color = style.background2 or style.background3 or { 35, 45, 38 }
  local border_color = style.divider or { 80, 110, 85 }

  renderer.draw_rect(x - 1, sy - 1, width + (style.padding.x * 2) + 2, height + (style.padding.y * 2) + 2, border_color)
  renderer.draw_rect(x, sy, width + (style.padding.x * 2), height + (style.padding.y * 2), bg_color)

  for _, line in pairs(lines) do
    common.draw_text(font, style.text, line, "left", x + style.padding.x, y, width, lh)
    y = y + lh
  end
end

local function draw_suggestions_box(av)
  if #suggestions <= 0 then return end

  -- Direct unclipped overlay rendering
  renderer.set_clip_rect(0, 0, core.root_view.size.x, core.root_view.size.y)

  local ah = config.plugins.autocomplete.max_height or 9
  local rx, ry, rw, rh = get_suggestions_rect(av)
  local bg_color = style.background3 or { 32, 42, 35 }
  local border_color = style.divider or style.accent or { 100, 180, 110 }

  -- Drop shadow & card container
  renderer.draw_rect(rx - 1, ry - 1, rw + 2, rh + 2, border_color)
  renderer.draw_rect(rx, ry, rw, rh, bg_color)

  local font = av:get_font()
  local lh = font:get_height() + style.padding.y
  local y = ry + style.padding.y / 2
  local show_count = math.min(#suggestions, ah)
  local start_index = suggestions_offset

  for i = start_index, start_index + show_count - 1 do
    if not suggestions[i] then break end
    local s = suggestions[i]
    local info_text = s.info or ""
    local info_size = #info_text > 0 and (style.font:get_width(info_text) + style.padding.x * 2) or style.padding.x
    local is_selected = (i == suggestions_idx)
    local color = is_selected and (style.accent or { 104, 193, 113 }) or style.text

    if is_selected then
      local hl_color = style.line_highlight or style.background or { 48, 65, 50 }
      renderer.draw_rect(rx, y, rw, lh, hl_color)
      renderer.draw_rect(rx, y, 3 * SCALE, lh, style.accent or { 104, 193, 113 })
    end

    local item_start_x = rx + style.padding.x + (is_selected and 3 * SCALE or 0)

    -- Render Color Swatch (e.g. for Tailwind CSS colors)
    if s.color then
      local swatch_size = 11 * SCALE
      local swatch_y = y + (lh - swatch_size) / 2
      renderer.draw_rect(item_start_x - 1, swatch_y - 1, swatch_size + 2, swatch_size + 2, { 255, 255, 255, 120 })
      renderer.draw_rect(item_start_x, swatch_y, swatch_size, swatch_size, s.color)
      item_start_x = item_start_x + swatch_size + 6 * SCALE
    end

    renderer.set_clip_rect(item_start_x, y, rw - info_size - style.padding.x - (s.color and 18 * SCALE or 0), lh)
    local x_adv = common.draw_text(font, color, s.text, "left", item_start_x, y, rw, lh)
    renderer.set_clip_rect(0, 0, core.root_view.size.x, core.root_view.size.y)

    if x_adv > rx + rw - info_size then
      local ellipsis_size = font:get_width("…")
      local ell_x = rx + rw - info_size - ellipsis_size
      renderer.draw_rect(ell_x, y, ellipsis_size, lh, is_selected and (style.line_highlight or style.background) or bg_color)
      common.draw_text(font, color, "…", "left", ell_x, y, ellipsis_size, lh)
    end

    if #info_text > 0 then
      local badge_color = style.dim
      if info_text:lower():find("snippet") then
        badge_color = is_selected and (style.accent or { 104, 193, 113 }) or { 110, 210, 160 }
      elseif info_text:lower():find("tailwind") or info_text:lower():find("color") then
        badge_color = { 56, 189, 248 }
      elseif info_text:lower():find("func") or info_text:lower():find("method") then
        badge_color = { 245, 158, 11 }
      elseif info_text:lower():find("keyword") then
        badge_color = { 244, 63, 94 }
      elseif info_text:lower():find("type") or info_text:lower():find("struct") then
        badge_color = { 45, 212, 191 }
      end
      common.draw_text(style.font, badge_color, info_text, "right", rx, y, rw - style.padding.x, lh)
    end

    y = y + lh

    if is_selected then
      if s.onhover then
        s.onhover(suggestions_idx, s)
        s.onhover = nil
      end
      if s.desc and #s.desc > 0 then
        draw_description_box(s.desc, av, rx, ry, rw, rh)
      end
    end
  end

  -- Status Footer
  renderer.draw_rect(rx, y, rw, 1, style.caret or style.accent)
  renderer.draw_rect(rx, y + 1, rw, lh, style.background or { 24, 32, 26 })
  common.draw_text(style.font, style.accent or { 104, 193, 113 }, "Suggestions", "left", rx + style.padding.x, y + 1, rw, lh)
  common.draw_text(
    style.font,
    style.accent or { 104, 193, 113 },
    tostring(suggestions_idx) .. "/" .. tostring(#suggestions),
    "right",
    rx, y + 1, rw - style.padding.x, lh
  )
end

local function is_leetcode_active()
  local av = get_active_view()
  if not av or not av.doc then return false end
  local doc = av.doc
  if doc.is_leetcode then return true end
  local fn = (doc.filename or doc.abs_filename or ""):lower()
  if fn:find("leetcode") or fn:find("interview_prep") then
    return true
  end
  return false
end

local function show_autocomplete()
  local av = get_active_view()
  if av and av.doc and not is_command_view_active() and not is_leetcode_active() then
    partial = get_partial_symbol()
    local min_len = config.plugins.autocomplete.min_len or 1

    if #partial >= min_len or triggered_manually then
      update_suggestions()
      last_line, last_col = av.doc:get_selection()
    else
      reset_suggestions()
    end
  else
    reset_suggestions()
  end
end

-- Input hooks
local on_text_input = RootView.on_text_input
RootView.on_text_input = function(self, text)
  on_text_input(self, text)
  local av = get_active_view()
  if av and not is_command_view_active() then
    show_autocomplete()
  else
    reset_suggestions()
  end
end

local doc_raw_insert = Doc.raw_insert
function Doc:raw_insert(line, col, text, undo_stack, time)
  doc_raw_insert(self, line, col, text, undo_stack, time)
  local av = get_active_view()
  if av and av.doc == self and not is_command_view_active() then
    show_autocomplete()
  end
end

local doc_raw_remove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, undo_stack, time)
  doc_raw_remove(self, line1, col1, line2, col2, undo_stack, time)
  local av = get_active_view()
  if av and av.doc == self and not is_command_view_active() then
    show_autocomplete()
  elseif #suggestions > 0 then
    reset_suggestions()
  end
end

local root_view_update = RootView.update
RootView.update = function(self, ...)
  root_view_update(self, ...)
  local av = get_active_view()
  if not av or is_command_view_active() then
    if #suggestions > 0 then
      reset_suggestions()
    end
    return
  end
  if av and av.doc and #suggestions > 0 then
    local line, col = av.doc:get_selection()
    if last_line and last_col then
      if line ~= last_line or col < last_col - #partial - 1 or col > last_col + 50 then
        reset_suggestions()
      end
    end
  end
end

-- Guaranteed Overlay Draw (Runs immediately after full RootView renders)
local root_view_draw = RootView.draw
RootView.draw = function(self, ...)
  root_view_draw(self, ...)
  local av = get_active_view()
  if av and #suggestions > 0 and not is_command_view_active() then
    draw_suggestions_box(av)
  elseif #suggestions > 0 and is_command_view_active() then
    reset_suggestions()
  end
end

if CommandView_ok and CommandView.enter then
  local old_cv_enter = CommandView.enter
  function CommandView:enter(...)
    reset_suggestions()
    return old_cv_enter(self, ...)
  end
end

-- Public APIs
function autocomplete.open(on_close)
  triggered_manually = true
  if on_close then
    autocomplete.on_close = on_close
  end

  local av = get_active_view()
  if av and av.doc and not is_command_view_active() then
    partial = get_partial_symbol()
    last_line, last_col = av.doc:get_selection()
    update_suggestions()
  end
end

function autocomplete.close()
  reset_suggestions()
end

function autocomplete.is_open()
  return #suggestions > 0
end

function autocomplete.complete(completions, on_close)
  reset_suggestions()
  autocomplete.map_manually = {}
  autocomplete.add(completions, true)
  autocomplete.open(on_close)
end

function autocomplete.can_complete()
  return #partial >= (config.plugins.autocomplete.min_len or 1)
end

-- Key Commands
local function predicate()
  local av = get_active_view()
  return av ~= nil and #suggestions > 0 and not is_command_view_active(), av
end

command.add(predicate, {
  ["autocomplete:complete"] = function(dv)
    local doc = dv.doc
    local item = suggestions[suggestions_idx]
    if not item then return end
    local inserted = false
    if item.onselect then
      inserted = item.onselect(suggestions_idx, item)
    end
    if not inserted then
      local current_partial = get_partial_symbol()
      local sz = #current_partial

      for _, line1, col1, line2, _ in doc:get_selections(true) do
        local n = col1 - 1
        local line = doc.lines[line1]
        for i = 1, sz + 1 do
          local j = sz - i
          local subline = line:sub(n - j, n)
          local subpartial = current_partial:sub(i, -1)
          if subpartial == subline then
            doc:remove(line1, col1, line2, n - j)
            break
          end
        end
      end

      doc:text_input(item.text)
    end
    reset_suggestions()
  end,

  ["autocomplete:previous"] = function()
    if #suggestions == 0 then return end
    suggestions_idx = (suggestions_idx - 2) % #suggestions + 1
    local ah = math.min(config.plugins.autocomplete.max_height or 9, #suggestions)
    if suggestions_offset > suggestions_idx then
      suggestions_offset = suggestions_idx
    elseif suggestions_offset + ah < suggestions_idx + 1 then
      suggestions_offset = suggestions_idx - ah + 1
    end
    core.redraw = true
  end,

  ["autocomplete:next"] = function()
    if #suggestions == 0 then return end
    suggestions_idx = (suggestions_idx % #suggestions) + 1
    local ah = math.min(config.plugins.autocomplete.max_height or 9, #suggestions)
    if suggestions_offset + ah < suggestions_idx + 1 then
      suggestions_offset = suggestions_idx - ah + 1
    elseif suggestions_offset > suggestions_idx then
      suggestions_offset = suggestions_idx
    end
    core.redraw = true
  end,

  ["autocomplete:cancel"] = function()
    reset_suggestions()
  end,
})

keymap.add {
  ["tab"]    = "autocomplete:complete",
  ["return"] = "autocomplete:complete",
  ["up"]     = "autocomplete:previous",
  ["down"]   = "autocomplete:next",
  ["escape"] = "autocomplete:cancel",
}

return autocomplete
