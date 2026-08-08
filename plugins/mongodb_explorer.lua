-- mod-version:3
--[[
  MongoDB Explorer for Lite XL (High Performance & Resilient Edition)
  A production-grade, asynchronous MongoDB cluster and collection manager for Lite XL.
  Supports multiple connections (standard URI & SRV), sidebar treeview inspection
  of databases, collections, and indexes, interactive document viewing/inline editing,
  aggregation/query scratchpad execution, live search filtering, responsive
  theme-adaptive UI styling, and crash-resilient process management.
]]

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local process = require "process"
local Doc = require "core.doc"
local DocView = require "core.docview"
local View = require "core.view"
local syntax = require "core.syntax"

-- ============================================================================
-- Configuration & Defaults
-- ============================================================================
config.plugins.mongodb_explorer = common.merge({
  mongosh_path = "mongosh",          -- Path to mongosh (or "mongo" fallback)
  fallback_mongo_path = "mongo",
  page_size = 20,                   -- Default document pagination limit
  connect_timeout = 10,             -- Connect timeout in seconds
  query_timeout = 30,               -- Query execution timeout in seconds
  max_output_bytes = 8 * 1024 * 1024, -- 8MB output buffer cap
  view_width = 280,                 -- Default sidebar width in pixels
  save_path = USERDIR .. "/mongodb_connections.json",
  show_doc_counts = true,           -- Show collection document count badges
  show_indent_guides = true,        -- Show vertical hierarchy lines in tree
  compact_mode = false,             -- Compact row spacing mode
  autostop_on_exit = true,          -- Auto-stop MongoDB server when closing Lite XL
  autostart_server = false,         -- Do not autostart MongoDB server when opening Lite XL
  theme_override = nil,             -- Custom color table overrides if desired
  config_spec = {
    name = "MongoDB Explorer",
    {
      label = "mongosh Binary Path",
      description = "Executable path or command name for MongoDB Shell (mongosh).",
      path = "mongosh_path",
      type = "string",
      default = "mongosh",
    },
    {
      label = "Default Query Page Size",
      description = "Default number of documents to fetch per page.",
      path = "page_size",
      type = "number",
      default = 20,
      min = 1,
      max = 500,
    },
    {
      label = "Show Document Counts",
      description = "Display estimated document count badges next to collections.",
      path = "show_doc_counts",
      type = "toggle",
      default = true,
    },
    {
      label = "Show Tree Indent Guides",
      description = "Display vertical indentation guides in the explorer tree.",
      path = "show_indent_guides",
      type = "toggle",
      default = true,
    },
    {
      label = "Auto-Stop Server on Exit",
      description = "Automatically stop local MongoDB server when Lite XL is closed.",
      path = "autostop_on_exit",
      type = "toggle",
      default = true,
    },
    {
      label = "Autostart Server on Open",
      description = "Automatically start local MongoDB server when Lite XL opens (Default: disabled).",
      path = "autostart_server",
      type = "toggle",
      default = false,
    },
  }
}, config.plugins.mongodb_explorer)

-- ============================================================================
-- Theme & Color System (Adaptive & Nil-Safe for Light & Dark Themes)
-- ============================================================================
local function get_luminance(col)
  if type(col) ~= "table" then return 128 end
  local r, g, b = col[1] or 0, col[2] or 0, col[3] or 0
  return (r * 0.299 + g * 0.587 + b * 0.114)
end

local function blend_color(c1, c2, t)
  if type(c1) ~= "table" then return c2 or { 128, 128, 128, 255 } end
  if type(c2) ~= "table" then return c1 end
  return {
    math.floor((c1[1] or 0) * (1 - t) + (c2[1] or 0) * t),
    math.floor((c1[2] or 0) * (1 - t) + (c2[2] or 0) * t),
    math.floor((c1[3] or 0) * (1 - t) + (c2[3] or 0) * t),
    math.floor((c1[4] or 255) * (1 - t) + (c2[4] or 255) * t),
  }
end

local function with_alpha(col, alpha)
  if type(col) ~= "table" then return { 128, 128, 128, alpha or 255 } end
  return { col[1] or 0, col[2] or 0, col[3] or 0, alpha or 255 }
end

local function format_number(n)
  if type(n) ~= "number" then return tostring(n or 0) end
  local str = string.format("%.0f", n)
  local k
  while true do
    str, k = string.gsub(str, "^(-?%d+)(%d%d%d)", '%1,%2')
    if k == 0 then break end
  end
  return str
end

local function get_theme_palette()
  local bg = style.background or { 30, 30, 30, 255 }
  local lum = get_luminance(bg)
  local is_light = lum > 135

  -- Inherit base tokens safely
  local base_text = (style.mossy and style.mossy.sidebar_text) or style.text or (is_light and { 40, 40, 40, 255 } or { 230, 230, 230, 255 })
  local base_dim = (style.mossy and style.mossy.sidebar_muted) or style.dim or (is_light and { 110, 110, 110, 255 } or { 150, 150, 150, 255 })
  local accent = style.accent or (is_light and { 45, 125, 185, 255 } or { 80, 170, 240, 255 })
  local divider = style.divider or (style.mossy and style.mossy.border) or with_alpha(base_dim, is_light and 45 or 40)

  -- Adaptive backgrounds
  local sidebar_bg
  if style.mossy and style.mossy.sidebar_bg then
    sidebar_bg = style.mossy.sidebar_bg
  elseif is_light then
    sidebar_bg = blend_color(bg, { 0, 0, 0, 255 }, 0.035)
  else
    sidebar_bg = blend_color(bg, { 255, 255, 255, 255 }, 0.025)
  end

  local header_bg = (style.mossy and style.mossy.activity_bg) or style.background3 or blend_color(sidebar_bg, is_light and { 0, 0, 0, 255 } or { 255, 255, 255, 255 }, 0.05)
  local footer_bg = header_bg

  -- Row highlights
  local row_hover = (style.mossy and style.mossy.hover_row) or style.line_highlight or with_alpha(accent, is_light and 25 or 35)
  local row_selected = (style.mossy and style.mossy.active_row) or style.selection or with_alpha(accent, is_light and 60 or 70)
  local row_selected_text = (style.mossy and style.mossy.active_row_text) or base_text

  -- Search box styling
  local search_bg = is_light and blend_color(header_bg, { 255, 255, 255, 255 }, 0.7) or blend_color(header_bg, { 0, 0, 0, 255 }, 0.4)
  local search_border = with_alpha(divider, is_light and 90 or 80)
  local search_text = base_text
  local search_placeholder = with_alpha(base_dim, is_light and 180 or 150)

  -- Pill Badges
  local badge_bg = is_light and with_alpha(accent, 22) or with_alpha(accent, 35)
  local badge_text = is_light and blend_color(accent, { 0, 0, 0, 255 }, 0.25) or blend_color(accent, { 255, 255, 255, 255 }, 0.4)
  local badge_border = with_alpha(accent, is_light and 45 or 55)

  -- Status Colors
  local status_connected = is_light and { 35, 140, 75, 255 } or { 70, 215, 120, 255 }
  local status_connecting = is_light and { 190, 120, 10, 255 } or { 245, 185, 45, 255 }
  local status_error = is_light and { 205, 45, 45, 255 } or { 245, 85, 85, 255 }
  local status_disconnected = base_dim

  -- Button tokens
  local btn_bg = is_light and blend_color(sidebar_bg, { 255, 255, 255, 255 }, 0.5) or blend_color(sidebar_bg, { 255, 255, 255, 255 }, 0.08)
  local btn_hover = with_alpha(accent, is_light and 35 or 50)
  local btn_text = base_text
  local btn_hover_text = is_light and blend_color(accent, { 0, 0, 0, 255 }, 0.3) or { 255, 255, 255, 255 }
  local btn_border = with_alpha(divider, is_light and 90 or 75)

  -- Indent guide line color
  local indent_guide = with_alpha(divider, is_light and 55 or 45)

  local palette = {
    is_light = is_light,
    bg = sidebar_bg,
    header_bg = header_bg,
    footer_bg = footer_bg,
    divider = divider,
    text = base_text,
    dim = base_dim,
    accent = accent,
    row_hover = row_hover,
    row_selected = row_selected,
    row_selected_text = row_selected_text,
    search_bg = search_bg,
    search_border = search_border,
    search_text = search_text,
    search_placeholder = search_placeholder,
    badge_bg = badge_bg,
    badge_text = badge_text,
    badge_border = badge_border,
    status_connected = status_connected,
    status_connecting = status_connecting,
    status_error = status_error,
    status_disconnected = status_disconnected,
    btn_bg = btn_bg,
    btn_hover = btn_hover,
    btn_text = btn_text,
    btn_hover_text = btn_hover_text,
    btn_border = btn_border,
    indent_guide = indent_guide,
  }

  if config.plugins.mongodb_explorer.theme_override and type(config.plugins.mongodb_explorer.theme_override) == "table" then
    for k, v in pairs(config.plugins.mongodb_explorer.theme_override) do
      palette[k] = v
    end
  end

  return palette
end

-- ============================================================================
-- MongoDB JSON & Document Results Syntax Highlighter
-- ============================================================================
local function init_mongodb_syntax()
  -- Ensure style syntax table exists
  style.syntax = style.syntax or {}
  style.syntax_fonts = style.syntax_fonts or {}

  -- Curated high-contrast semantic palette
  style.syntax["mongo_id"] = { common.color "#22D3EE" }         -- Bright Cyan / Turquoise for primary keys (_id, $oid)
  style.syntax["mongo_oid_val"] = { common.color "#06B6D4" }    -- Deep Cyan for hex ObjectIds
  style.syntax["mongo_date"] = { common.color "#F59E0B" }       -- Golden Amber for date fields (createdAt, updatedAt, expiry)
  style.syntax["mongo_date_val"] = { common.color "#FDE047" }   -- Warm Gold for ISO 8601 timestamps
  style.syntax["mongo_name"] = { common.color "#38BDF8" }       -- Vivid Sky Blue for names, titles, categories, manufacturer
  style.syntax["mongo_meta"] = { common.color "#C084FC" }       -- Soft Orchid Purple for status, __v, counters, booleans
  style.syntax["mongo_operator"] = { common.color "#FB7185" }   -- Neon Rose Pink for EJSON/Mongo operators ($match, $set, etc.)
  style.syntax["mongo_key"] = { common.color "#94A3B8" }        -- Crisp Ice Slate for general JSON property keys
  style.syntax["mongo_number"] = { common.color "#FB923C" }     -- Bright Tangerine Orange for numeric values
  style.syntax["mongo_literal"] = { common.color "#F87171" }    -- Coral Red / Purple for literals (true, false, null)
  style.syntax["mongo_bracket"] = { common.color "#64748B" }    -- Muted Slate for array/object scope brackets ([ ], { })
  style.syntax["mongo_colon"] = { common.color "#94A3B8" }      -- Soft Silver for colons and commas

  -- Bold font for primary keys and entity names if available
  local bold_font = nil
  local font_candidates = {
    "C:/Windows/Fonts/consolab.ttf",
    "C:/Windows/Fonts/CascadiaCode-Bold.ttf",
    "C:/Windows/Fonts/segoeuib.ttf",
    DATADIR .. "/fonts/FiraSans-Bold.ttf",
  }
  for _, fp in ipairs(font_candidates) do
    local ok, f = pcall(renderer.font.load, fp, 15 * SCALE)
    if ok and f then
      bold_font = f
      break
    end
  end

  if bold_font then
    style.syntax_fonts["mongo_id"] = bold_font
    style.syntax_fonts["mongo_name"] = bold_font
    style.syntax_fonts["mongo_date"] = bold_font
  end

  syntax.add {
    name = "MongoDB JSON",
    files = {
      "results%.mongodb%.json$",
      "%.mongodb%.json$",
      "%_documents%.json$",
      "insert_%w+_%w+%.json$",
      "%.ejson$",
      "%.json$",
    },
    comment = "//",
    block_comment = { "/*", "*/" },
    patterns = {
      -- Comments
      { pattern = "//.*", type = "comment" },
      { pattern = { "/%*", "%*/" }, type = "comment" },

      -- 1. Primary Identifier Keys: "_id", "$oid", "$id", "id", "uuid", "_key"
      { regex = [["(?:_id|\$oid|\$id|uuid|_key)"()\s*:]], type = { "mongo_id", "mongo_colon" } },

      -- 2. Timestamps & Dates Keys: "createdAt", "updatedAt", "$date", "timestamp", "expiry", "expiresAt", "deletedAt", "publishedAt", "modifiedAt", "birthDate", "date", "created_at", "updated_at"
      { regex = [["(?:createdAt|updatedAt|\$date|timestamp|expiry|expiresAt|deletedAt|publishedAt|modifiedAt|birthDate|date|created_at|updated_at|created_on|updated_on|generation_time)"()\s*:]], type = { "mongo_date", "mongo_colon" } },

      -- 3. Core Entity Names / Attributes: "name", "title", "collection", "database", "databases", "label", "username", "user", "email", "role", "category", "manufacturer", "author", "type", "subject", "description"
      { regex = [["(?:name|title|collection|database|databases|label|username|user|email|role|category|manufacturer|author|type|subject|description|first_name|last_name|full_name|product_name|company)"()\s*:]], type = { "mongo_name", "mongo_colon" } },

      -- 4. Status, Flags & Counters: "__v", "status", "state", "active", "enabled", "disabled", "acknowledged", "ok", "prescriptionRequired", "empty", "sizeOnDisk", "totalSize", "version", "deleted", "isDeleted", "count", "quantity", "price", "total"
      { regex = [["(?:__v|status|state|active|enabled|disabled|acknowledged|ok|prescriptionRequired|empty|sizeOnDisk|totalSize|version|deleted|isDeleted|count|quantity|price|total|inStock|isAvailable|available)"()\s*:]], type = { "mongo_meta", "mongo_colon" } },

      -- 5. MongoDB & EJSON Operators: "$numberLong", "$numberDecimal", "$numberInt", "$binary", "$regex", "$minKey", "$maxKey", "$timestamp", "$code", "$ref", "$db", "$match", "$group", "$project", "$sort", "$lookup", "$unwind", "$limit", "$skip", "$set", "$inc", "$push", "$pull", "$in", "$nin", "$gt", "$gte", "$lt", "$lte", "$eq", "$ne", "$exists", "$or", "$and", "$not", "$nor"
      { regex = [["\$(?:numberLong|numberDecimal|numberInt|binary|regex|minKey|maxKey|timestamp|code|ref|db|match|group|project|sort|lookup|unwind|limit|skip|set|inc|push|pull|in|nin|gt|gte|lt|lte|eq|ne|exists|or|and|not|nor)"()\s*:]], type = { "mongo_operator", "mongo_colon" } },

      -- 6. Generic JSON Keys
      { regex = [["(?:[^"\\]|\\.)*"()\s*:]], type = { "mongo_key", "mongo_colon" } },

      -- 7. Special String Values:
      -- ISO 8601 Date / Timestamps: "2025-12-28T10:35:48.615Z"
      { regex = [["\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?"]], type = "mongo_date_val" },
      -- 24-hex char MongoDB ObjectIDs: "695108044a82bcf17fb6c5f4"
      { regex = [["[0-9a-fA-F]{24}"]], type = "mongo_oid_val" },

      -- 8. General Strings
      { regex = [["(?:[^"\\]|\\.)*"]], type = "string" },

      -- 9. Numbers
      { pattern = "0x[%da-fA-F]+", type = "mongo_number" },
      { pattern = "-?%d+[%d%.eE]*", type = "mongo_number" },
      { pattern = "-?%.?%d+", type = "mongo_number" },

      -- 10. Literals
      { pattern = "null", type = "mongo_literal" },
      { pattern = "true", type = "mongo_literal" },
      { pattern = "false", type = "mongo_literal" },

      -- 11. Structural Brackets and Delimiters
      { pattern = "[%[%]{}]", type = "mongo_bracket" },
      { pattern = "[,:]", type = "mongo_colon" },
    },
    symbols = {},
  }
end

pcall(init_mongodb_syntax)

-- ============================================================================
-- Layout & UI Helper Utilities
-- ============================================================================
local function truncate_text(font, text, max_w)
  if not text or max_w <= 0 then return "" end
  if font:get_width(text) <= max_w then return text end

  local ellipsis = "..."
  local ell_w = font:get_width(ellipsis)
  if ell_w >= max_w then return "" end

  local l, r = 1, #text
  local best = ""
  while l <= r do
    local mid = math.floor((l + r) / 2)
    local sub = text:sub(1, mid)
    if font:get_width(sub) + ell_w <= max_w then
      best = sub
      l = mid + 1
    else
      r = mid - 1
    end
  end
  return best .. ellipsis
end

local function draw_pill_badge(font, text, x, y, bg_col, text_col, border_col)
  local pad_x = math.floor(5 * SCALE)
  local pad_y = math.floor(1 * SCALE)
  local txt_w = font:get_width(text)
  local badge_w = txt_w + pad_x * 2
  local badge_h = font:get_height() + pad_y * 2

  renderer.draw_rect(x, y, badge_w, badge_h, bg_col)
  if border_col then
    renderer.draw_rect(x, y, badge_w, 1 * SCALE, border_col)
    renderer.draw_rect(x, y + badge_h - 1 * SCALE, badge_w, 1 * SCALE, border_col)
    renderer.draw_rect(x, y, 1 * SCALE, badge_h, border_col)
    renderer.draw_rect(x + badge_w - 1 * SCALE, y, 1 * SCALE, badge_h, border_col)
  end

  renderer.draw_text(font, text, x + pad_x, y + pad_y, text_col)
  return badge_w, badge_h
end

local function draw_indent_guides(x, y, h, depth, step, color)
  if not config.plugins.mongodb_explorer.show_indent_guides then return end
  for d = 1, depth do
    local gx = x + (d - 1) * step + math.floor(6 * SCALE)
    renderer.draw_rect(gx, y, 1 * SCALE, h, color)
  end
end

-- ============================================================================
-- Pure Lua JSON Parser and Pretty Formatter with MongoDB EJSON Support
-- ============================================================================
local json = {}

local function kind_of(obj)
  if type(obj) ~= "table" then return type(obj) end
  local i = 1
  for _ in pairs(obj) do
    if obj[i] ~= nil then i = i + 1 else return "table" end
  end
  if i == 1 then return "table" else return "array" end
end

local function escape_str(s)
  local in_char  = {'\\', '"', '\b', '\f', '\n', '\r', '\t'}
  local out_char = {'\\\\', '\\"', '\\b', '\\f', '\\n', '\\r', '\\t'}
  for i, c in ipairs(in_char) do
    s = s:gsub(c, out_char[i])
  end
  return s
end

function json.stringify(val, pretty, indent_level, seen)
  pretty = pretty or false
  indent_level = indent_level or 0
  seen = seen or {}
  local indent = pretty and string.rep("  ", indent_level) or ""
  local next_indent = pretty and string.rep("  ", indent_level + 1) or ""
  local newline = pretty and "\n" or ""
  local space = pretty and " " or ""

  local val_type = type(val)
  if val_type == "nil" then
    return "null"
  elseif val_type == "boolean" then
    return tostring(val)
  elseif val_type == "number" then
    if val ~= val or val == math.huge or val == -math.huge then
      return "null"
    end
    return tostring(val)
  elseif val_type == "string" then
    return '"' .. escape_str(val) .. '"'
  elseif val_type == "table" then
    if seen[val] or indent_level > 64 then
      return '"[Circular/MaxDepth]"'
    end
    seen[val] = true

    local k = kind_of(val)
    if k == "array" then
      if #val == 0 then
        seen[val] = nil
        return "[]"
      end
      local items = {}
      for _, item in ipairs(val) do
        table.insert(items, next_indent .. json.stringify(item, pretty, indent_level + 1, seen))
      end
      seen[val] = nil
      return "[" .. newline .. table.concat(items, "," .. newline) .. newline .. indent .. "]"
    else
      local keys = {}
      for key in pairs(val) do table.insert(keys, key) end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      if #keys == 0 then
        seen[val] = nil
        return "{}"
      end
      local entries = {}
      for _, key in ipairs(keys) do
        local k_str = '"' .. escape_str(tostring(key)) .. '"'
        local v_str = json.stringify(val[key], pretty, indent_level + 1, seen)
        table.insert(entries, next_indent .. k_str .. ":" .. space .. v_str)
      end
      seen[val] = nil
      return "{" .. newline .. table.concat(entries, "," .. newline) .. newline .. indent .. "}"
    end
  end
  return '"' .. tostring(val) .. '"'
end

function json.parse(str)
  if not str or str == "" then return nil, "empty string" end

  -- Try native/lsp json parser first if available
  local ok_lsp, lsp_json = pcall(require, "plugins.lsp.json")
  if ok_lsp and lsp_json and lsp_json.decode then
    local ok, res = pcall(lsp_json.decode, str)
    if ok and res ~= nil then return res end
  end

  local pos = 1
  local len = #str
  local depth = 0

  local function skip_whitespace()
    while pos <= len do
      local c = str:sub(pos, pos)
      if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
        pos = pos + 1
      elseif c == '/' and str:sub(pos+1, pos+1) == '/' then
        while pos <= len and str:sub(pos, pos) ~= '\n' do pos = pos + 1 end
      elseif c == '/' and str:sub(pos+1, pos+1) == '*' then
        pos = pos + 2
        while pos < len and not (str:sub(pos, pos) == '*' and str:sub(pos+1, pos+1) == '/') do
          pos = pos + 1
        end
        pos = pos + 2
      else
        break
      end
    end
  end

  local parse_value

  local function parse_string()
    pos = pos + 1
    local res = {}
    while pos <= len do
      local c = str:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(res)
      elseif c == '\\' then
        pos = pos + 1
        local next_c = str:sub(pos, pos)
        if next_c == '"' or next_c == '\\' or next_c == '/' then
          table.insert(res, next_c)
        elseif next_c == 'b' then table.insert(res, '\b')
        elseif next_c == 'f' then table.insert(res, '\f')
        elseif next_c == 'n' then table.insert(res, '\n')
        elseif next_c == 'r' then table.insert(res, '\r')
        elseif next_c == 't' then table.insert(res, '\t')
        elseif next_c == 'u' then
          local hex = str:sub(pos + 1, pos + 4)
          local code = tonumber(hex, 16)
          if code then
            table.insert(res, string.char(code % 256))
            pos = pos + 4
          end
        else
          table.insert(res, next_c)
        end
        pos = pos + 1
      else
        table.insert(res, c)
        pos = pos + 1
      end
    end
    return table.concat(res)
  end

  local function parse_number()
    local start_pos = pos
    if str:sub(pos, pos) == '-' or str:sub(pos, pos) == '+' then pos = pos + 1 end
    while pos <= len and str:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
    if pos <= len and str:sub(pos, pos) == '.' then
      pos = pos + 1
      while pos <= len and str:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
    end
    if pos <= len and str:sub(pos, pos):match("[eE]") then
      pos = pos + 1
      if str:sub(pos, pos) == '+' or str:sub(pos, pos) == '-' then pos = pos + 1 end
      while pos <= len and str:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
    end
    local num_str = str:sub(start_pos, pos - 1)
    return tonumber(num_str) or num_str
  end

  local function parse_array()
    if depth > 128 then return {} end
    depth = depth + 1
    pos = pos + 1
    local arr = {}
    skip_whitespace()
    if pos <= len and str:sub(pos, pos) == ']' then
      pos = pos + 1
      depth = depth - 1
      return arr
    end
    while pos <= len do
      local val = parse_value()
      table.insert(arr, val)
      skip_whitespace()
      local c = str:sub(pos, pos)
      if c == ']' then
        pos = pos + 1
        depth = depth - 1
        return arr
      elseif c == ',' then
        pos = pos + 1
        skip_whitespace()
      else
        pos = pos + 1
      end
    end
    depth = depth - 1
    return arr
  end

  local function parse_object()
    if depth > 128 then return {} end
    depth = depth + 1
    pos = pos + 1
    local obj = {}
    skip_whitespace()
    if pos <= len and str:sub(pos, pos) == '}' then
      pos = pos + 1
      depth = depth - 1
      return obj
    end
    while pos <= len do
      skip_whitespace()
      local key = nil
      local c = str:sub(pos, pos)
      if c == '"' then
        key = parse_string()
      elseif c == '}' then
        pos = pos + 1
        depth = depth - 1
        return obj
      else
        local start_k = pos
        while pos <= len and str:sub(pos, pos):match("[%w_$%-]") do pos = pos + 1 end
        key = str:sub(start_k, pos - 1)
      end
      skip_whitespace()
      if str:sub(pos, pos) == ':' then pos = pos + 1 end
      skip_whitespace()
      local val = parse_value()
      if key and key ~= "" then
        obj[key] = val
      end
      skip_whitespace()
      c = str:sub(pos, pos)
      if c == '}' then
        pos = pos + 1
        depth = depth - 1
        return obj
      elseif c == ',' then
        pos = pos + 1
        skip_whitespace()
      else
        pos = pos + 1
      end
    end
    depth = depth - 1
    return obj
  end

  parse_value = function()
    skip_whitespace()
    if pos > len then return nil end
    local c = str:sub(pos, pos)
    if c == '"' then
      return parse_string()
    elseif c == '{' then
      return parse_object()
    elseif c == '[' then
      return parse_array()
    elseif c == '-' or c == '+' or c:match("[0-9]") then
      return parse_number()
    elseif str:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif str:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif str:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    elseif str:sub(pos, pos + 8) == "undefined" then
      pos = pos + 9
      return nil
    elseif c:match("[%a_$]") then
      local start_id = pos
      while pos <= len and str:sub(pos, pos) ~= '(' and str:sub(pos, pos):match("[%w_$]") do
        pos = pos + 1
      end
      local fn_name = str:sub(start_id, pos - 1)
      skip_whitespace()
      if str:sub(pos, pos) == '(' then
        pos = pos + 1
        local args = {}
        skip_whitespace()
        if str:sub(pos, pos) ~= ')' then
          while pos <= len do
            table.insert(args, parse_value())
            skip_whitespace()
            if str:sub(pos, pos) == ',' then
              pos = pos + 1
              skip_whitespace()
            elseif str:sub(pos, pos) == ')' then
              break
            else
              pos = pos + 1
            end
          end
        end
        if str:sub(pos, pos) == ')' then pos = pos + 1 end
        if #args == 1 then
          return { ["$" .. fn_name] = args[1] }
        else
          return { ["$" .. fn_name] = args }
        end
      end
      return fn_name
    else
      pos = pos + 1
      return nil
    end
  end

  local ok, res = pcall(parse_value)
  if ok then return res else return nil, tostring(res) end
end

-- ============================================================================
-- Masking & URI Utilities
-- ============================================================================
local function mask_uri(uri)
  if not uri then return "" end
  return uri:gsub("(mongodb%+?s?r?v?://[^:]+:)([^@]+)(@)", "%1***%3")
end

local function parse_uri_alias(uri)
  if not uri then return "MongoDB Cluster" end
  local host = uri:match("@([^/?]+)") or uri:match("://([^/?]+)") or "localhost"
  local short_host = host:match("([^.]+)%.") or host
  return short_host
end

-- ============================================================================
-- Non-Blocking Async CLI Process Runner (Guaranteed Zero-Freeze)
-- ============================================================================
local _query_counter = 0

local function get_mongo_command_candidates(uri, script_path)
  local is_windows = (PLATFORM == "Windows" or os.getenv("OS") == "Windows_NT" or package.config:sub(1,1) == "\\")
  local custom_bin = config.plugins.mongodb_explorer.mongosh_path
  local candidates = {}

  -- 1. Custom user-configured path
  if custom_bin and custom_bin ~= "" and custom_bin ~= "mongosh" then
    if is_windows and (custom_bin:match("%.cmd$") or custom_bin:match("%.bat$") or custom_bin == "npx") then
      table.insert(candidates, { "cmd.exe", "/c", custom_bin, "--quiet", "--norc", uri, "--file", script_path })
    else
      table.insert(candidates, { custom_bin, "--quiet", "--norc", uri, "--file", script_path })
    end
  end

  -- 2. Windows-specific candidate paths & wrappers
  if is_windows then
    local appdata = os.getenv("APPDATA")
    local localappdata = os.getenv("LOCALAPPDATA")

    -- 1. Standard standalone mongosh.exe binaries (highest priority)
    if localappdata then
      table.insert(candidates, { localappdata .. "\\Programs\\mongosh\\mongosh.exe", "--quiet", "--norc", uri, "--file", script_path })
      table.insert(candidates, { localappdata .. "\\Programs\\mongosh\\bin\\mongosh.exe", "--quiet", "--norc", uri, "--file", script_path })
    end
    table.insert(candidates, { "C:\\Program Files\\MongoDB\\Server\\7.0\\bin\\mongosh.exe", "--quiet", "--norc", uri, "--file", script_path })
    table.insert(candidates, { "C:\\Program Files\\MongoDB\\Server\\6.0\\bin\\mongosh.exe", "--quiet", "--norc", uri, "--file", script_path })
    table.insert(candidates, { "mongosh.exe", "--quiet", "--norc", uri, "--file", script_path })
    table.insert(candidates, { "mongo.exe", "--quiet", "--norc", uri, "--file", script_path })

    -- 2. Windows PATH fallback
    table.insert(candidates, { "cmd.exe", "/c", "mongosh", "--quiet", "--norc", uri, "--file", script_path })
  else
    -- Unix / macOS candidates
    table.insert(candidates, { "mongosh", "--quiet", "--norc", uri, "--file", script_path })
    table.insert(candidates, { "mongo", "--quiet", "--norc", uri, "--file", script_path })
    table.insert(candidates, { "npx", "-y", "mongosh", "--quiet", "--norc", uri, "--file", script_path })
    table.insert(candidates, { "/usr/local/bin/mongosh", "--quiet", "--norc", uri, "--file", script_path })
    table.insert(candidates, { "/usr/bin/mongosh", "--quiet", "--norc", uri, "--file", script_path })
    table.insert(candidates, { "/opt/homebrew/bin/mongosh", "--quiet", "--norc", uri, "--file", script_path })
  end

  return candidates
end

local function run_mongo_cli(uri, eval_js, callback)
  core.add_thread(function()
    _query_counter = _query_counter + 1
    local temp_js_path = USERDIR .. "/temp_mongo_query_" .. tostring(system.get_time()):gsub("%.", "") .. "_" .. tostring(_query_counter) .. ".js"

    local function cleanup()
      pcall(os.remove, temp_js_path)
    end

    local f, err = io.open(temp_js_path, "w")
    if not f then
      if callback then callback(nil, "Failed to create temporary query file: " .. tostring(err)) end
      return
    end

    local wrapped_js = string.format([[
(async () => {
  try {
    async function __resolve(val) {
      if (val && typeof val.then === 'function') {
        val = await val;
      }
      if (val && typeof val.toArray === 'function') {
        val = await val.toArray();
      }
      return val;
    }

    let __res = await (async () => {
%s
    })();

    __res = await __resolve(__res);

    if (typeof __res === 'undefined') {
      __res = { status: "success", acknowledged: true, message: "Query executed successfully." };
    }

    if (typeof EJSON !== 'undefined' && EJSON.stringify) {
      print("___JSON_START___" + EJSON.stringify(__res, { relaxed: true }) + "___JSON_END___");
    } else {
      print("___JSON_START___" + JSON.stringify(__res) + "___JSON_END___");
    }
  } catch (e) {
    print("___ERR_START___" + (e.stack || e.message || String(e)) + "___ERR_END___");
  }
})();
]], eval_js)

    f:write(wrapped_js)
    f:close()

    local candidate_cmds = get_mongo_command_candidates(uri, temp_js_path)
    local proc, start_err = nil, nil

    if process and process.start then
      for _, cmd_args in ipairs(candidate_cmds) do
        local ok, p = pcall(process.start, cmd_args)
        if ok and p then
          proc = p
          break
        else
          start_err = p
        end
      end
    end

    if not proc then
      cleanup()
      if callback then
        callback(nil, "Failed to start MongoDB Shell (mongosh). Please install mongosh or npm globally: " .. tostring(start_err))
      end
      return
    end

    local stdout_chunks = {}
    local stderr_chunks = {}
    local total_bytes = 0
    local max_bytes = config.plugins.mongodb_explorer.max_output_bytes or (8 * 1024 * 1024)
    local start_time = system.get_time()
    local timeout = config.plugins.mongodb_explorer.query_timeout or 45

    while true do
      local r_out = nil
      pcall(function() r_out = proc:read_stdout() end)
      if r_out and #r_out > 0 then
        total_bytes = total_bytes + #r_out
        if total_bytes <= max_bytes then
          table.insert(stdout_chunks, r_out)
        end
      end

      local r_err = nil
      pcall(function() r_err = proc:read_stderr() end)
      if r_err and #r_err > 0 then
        table.insert(stderr_chunks, r_err)
      end

      local is_running = false
      pcall(function() is_running = proc:running() end)
      if not is_running then break end

      if system.get_time() - start_time > timeout then
        pcall(function() proc:terminate() end)
        cleanup()
        if callback then callback(nil, "Query timed out after " .. tostring(timeout) .. " seconds.") end
        return
      end

      coroutine.yield(0.05)
    end

    -- Flush remaining stream
    local last_out = nil
    pcall(function() last_out = proc:read_stdout() end)
    if last_out and #last_out > 0 and total_bytes <= max_bytes then
      table.insert(stdout_chunks, last_out)
    end

    local last_err = nil
    pcall(function() last_err = proc:read_stderr() end)
    if last_err and #last_err > 0 then
      table.insert(stderr_chunks, last_err)
    end

    cleanup()

    local full_stdout = table.concat(stdout_chunks)
    local full_stderr = table.concat(stderr_chunks)

    local err_data = full_stdout:match("___ERR_START___(.-)___ERR_END___")
    if not err_data and #full_stderr > 0 and (full_stderr:match("Mongo") or full_stderr:match("Error")) then
      err_data = full_stderr
    end

    if err_data then
      if callback then callback(nil, err_data) end
      return
    end

    local json_data = full_stdout:match("___JSON_START___(.-)___JSON_END___")
    if json_data then
      local parsed, parse_err = json.parse(json_data)
      if parsed ~= nil or not parse_err then
        if callback then callback(parsed, nil) end
      else
        if callback then callback(json_data, nil) end
      end
    else
      if #full_stdout > 0 then
        if callback then callback(full_stdout, nil) end
      else
        if callback then callback(nil, nil) end
      end
    end
  end)
end

-- ============================================================================
-- Connection Profiles Store
-- ============================================================================
local store = {
  connections = {},
  selected_node = nil,
  server_status = "stopped", -- "stopped", "running", "starting", "stopping"
}

function store.check_server_status(callback)
  core.add_thread(function()
    local is_running = false
    local is_windows = (PLATFORM == "Windows" or os.getenv("OS") == "Windows_NT" or package.config:sub(1,1) == "\\")
    if is_windows then
      local proc = process.start({ "cmd.exe", "/c", "tasklist /FI \"IMAGENAME eq mongod.exe\" /NH" })
      if proc then
        local out = ""
        local t0 = system.get_time()
        while proc:running() and system.get_time() - t0 < 3 do
          local r = proc:read_stdout()
          if r then out = out .. r end
          coroutine.yield(0.05)
        end
        local r = proc:read_stdout()
        if r then out = out .. r end
        if out:find("mongod.exe") then
          is_running = true
        end
      end
    else
      local proc = process.start({ "systemctl", "is-active", "mongod" })
      if proc then
        local out = ""
        local t0 = system.get_time()
        while proc:running() and system.get_time() - t0 < 3 do
          local r = proc:read_stdout()
          if r then out = out .. r end
          coroutine.yield(0.05)
        end
        local r = proc:read_stdout()
        if r then out = out .. r end
        if out:find("active") then is_running = true end
      end
    end

    store.server_status = is_running and "running" or "stopped"
    if callback then callback(is_running) end
    core.redraw = true
  end)
end

function store.start_server(callback)
  store.server_status = "starting"
  core.log("[MongoDB] Starting local MongoDB Community Server...")
  core.redraw = true

  core.add_thread(function()
    local is_windows = (PLATFORM == "Windows" or os.getenv("OS") == "Windows_NT" or package.config:sub(1,1) == "\\")
    local started = false

    if is_windows then
      local localappdata = os.getenv("LOCALAPPDATA") or "C:\\Users\\Default\\AppData\\Local"
      local userprofile = os.getenv("USERPROFILE") or "C:\\Users\\Default"
      local data_dir = userprofile .. "\\mongodb_data"
      local log_file = data_dir .. "\\mongod.log"
      pcall(function() os.execute('mkdir "' .. data_dir .. '" 2>nul') end)

      local mongod_paths = {
        localappdata .. "\\Programs\\MongoDB-7.0\\bin\\mongod.exe",
        "C:\\Program Files\\MongoDB\\Server\\7.0\\bin\\mongod.exe",
        "C:\\Program Files\\MongoDB\\Server\\6.0\\bin\\mongod.exe",
        "mongod.exe",
      }

      for _, mp in ipairs(mongod_paths) do
        local f = io.open(mp, "r")
        if f or mp == "mongod.exe" then
          if f then f:close() end
          local ok, p = pcall(process.start, { mp, "--dbpath", data_dir, "--logpath", log_file, "--logappend", "--bind_ip", "127.0.0.1", "--port", "27017" })
          if ok and p then
            store.mongod_proc = p
            started = true
            break
          end
        end
      end

      if not started then
        local proc = process.start({ "cmd.exe", "/c", "net start MongoDB" })
        if proc then
          local out = ""
          local t0 = system.get_time()
          while proc:running() and system.get_time() - t0 < 4 do
            local r = proc:read_stdout()
            if r then out = out .. r end
            coroutine.yield(0.05)
          end
          if out:find("started successfully") or out:find("already been started") then
            started = true
          end
        end
      end
    else
      local ok, p = pcall(process.start, { "sudo", "systemctl", "start", "mongod" })
      if ok and p then started = true end
    end

    -- Non-blocking readiness polling (up to 12s)
    local ready = false
    local start_t = system.get_time()
    while system.get_time() - start_t < 12 do
      coroutine.yield(0.8)
      local ping_done = false
      local ping_ok = false

      run_mongo_cli("mongodb://127.0.0.1:27017", "return db.adminCommand({ ping: 1 });", function(res, err)
        ping_done = true
        if res and res.ok == 1 then
          ping_ok = true
        end
      end)

      local sub_t = system.get_time()
      while not ping_done and system.get_time() - sub_t < 1.5 do
        coroutine.yield(0.05)
      end

      if ping_ok then
        ready = true
        break
      end
    end

    if ready then
      store.server_status = "running"
      core.log("[MongoDB] MongoDB Server is ready and running at 127.0.0.1:27017.")
      local local_conn = store.find_connection("conn_local") or store.connections[1]
      if local_conn and local_conn.uri:find("127.0.0.1") then
        store.connect(local_conn)
      end
      if callback then callback(true) end
    else
      store.server_status = "stopped"
      core.warn("[MongoDB] MongoDB Server took longer than expected to start. Try clicking 'Start Server' again.")
      if callback then callback(false) end
    end
    core.redraw = true
  end)
end

function store.stop_server(callback)
  store.server_status = "stopping"
  core.log("[MongoDB] Stopping local MongoDB Community Server...")
  core.redraw = true

  core.add_thread(function()
    if store.mongod_proc then
      pcall(function() store.mongod_proc:terminate() end)
      store.mongod_proc = nil
    end

    local is_windows = (PLATFORM == "Windows" or os.getenv("OS") == "Windows_NT" or package.config:sub(1,1) == "\\")
    if is_windows then
      local shut_js = "db.getSiblingDB('admin').shutdownServer({ force: true })"
      run_mongo_cli("mongodb://127.0.0.1:27017", shut_js, function() end)

      pcall(function() os.execute("taskkill /F /IM mongod.exe >nul 2>&1") end)
      pcall(function() os.execute("net stop MongoDB >nul 2>&1") end)
    else
      process.start({ "sudo", "systemctl", "stop", "mongod" })
    end

    coroutine.yield(1.0)
    store.server_status = "stopped"

    for _, c in ipairs(store.connections) do
      if c.uri:find("127.0.0.1") and c.status == "connected" then
        store.disconnect(c)
      end
    end

    core.log("[MongoDB] MongoDB Server stopped.")
    if callback then callback(true) end
    core.redraw = true
  end)
end


function store.save()
  local serialized = {}
  for _, c in ipairs(store.connections) do
    table.insert(serialized, {
      id = c.id,
      name = c.name,
      uri = c.uri,
      default_db = c.default_db,
    })
  end
  local f = io.open(config.plugins.mongodb_explorer.save_path, "w")
  if f then
    f:write(json.stringify(serialized, true))
    f:close()
  end
end

function store.load()
store.check_server_status()
  local f = io.open(config.plugins.mongodb_explorer.save_path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    local data = json.parse(content)
    if type(data) == "table" then
      store.connections = {}
      for _, item in ipairs(data) do
        table.insert(store.connections, {
          id = item.id or tostring(system.get_time()),
          name = item.name or "MongoDB Connection",
          uri = item.uri or "mongodb://127.0.0.1:27017",
          default_db = item.default_db or "admin",
          status = "disconnected",
          version = "",
          error = nil,
          databases = {},
          expanded = false,
        })
      end
    end
  end

  if #store.connections == 0 then
    table.insert(store.connections, {
      id = "conn_local",
      name = "Localhost Dev",
      uri = "mongodb://127.0.0.1:27017",
      default_db = "admin",
      status = "disconnected",
      version = "",
      error = nil,
      databases = {},
      expanded = false,
    })
    store.save()
  end
end

function store.find_connection(id)
  if not id then return nil end
  for _, c in ipairs(store.connections) do
    if c.id == id then return c end
  end
  return nil
end

function store.connect(conn, on_complete)
  if not conn then return end
  conn.status = "connecting"
  conn.error = nil
  core.log("[MongoDB] Connecting to %s (%s)...", conn.name, mask_uri(conn.uri))

  local inspect_js = [[
    const buildInfo = db.runCommand({ buildInfo: 1 });
    const adminDB = db.getSiblingDB('admin');
    let dbs = [];
    try {
      const res = adminDB.runCommand({ listDatabases: 1 });
      dbs = res.databases || [];
    } catch(e) {
      dbs = [{ name: db.getName() }];
    }
    return {
      version: buildInfo.version || "unknown",
      databases: dbs.map(d => ({ name: d.name, sizeOnDisk: d.sizeOnDisk || 0 }))
    };
  ]]

  run_mongo_cli(conn.uri, inspect_js, function(data, err)
    if err then
      conn.status = "error"
      conn.error = err
      if err and (err:find("ECONNREFUSED") or err:find("MongoNetworkError") or err:find("connection refused")) then
        core.warn("[MongoDB] Connection refused at 127.0.0.1:27017. Click 'Start Server' in the bottom sidebar or connect to MongoDB Atlas Cloud by clicking '+ Add Connection'.")
      else
        core.error("[MongoDB] Connection error on %s: %s", conn.name, err)
      end
      if on_complete then on_complete(false, err) end
      core.redraw = true
      return
    end

    conn.status = "connected"
    conn.version = data and data.version or "v7.0.x"
    conn.databases = {}
    if data and data.databases then
      for _, d in ipairs(data.databases) do
        table.insert(conn.databases, {
          name = d.name,
          sizeOnDisk = d.sizeOnDisk,
          collections = {},
          expanded = false,
          loaded = false,
        })
      end
    end
    conn.expanded = true
    core.log("[MongoDB] Connected to %s (v%s)", conn.name, conn.version)
    if on_complete then on_complete(true, nil) end
    core.redraw = true
  end)
end

function store.disconnect(conn)
  if not conn then return end
  conn.status = "disconnected"
  conn.databases = {}
  conn.expanded = false
  conn.version = ""
  conn.error = nil
  core.log("[MongoDB] Disconnected from %s", conn.name)
  core.redraw = true
end

function store.load_collections(conn, db_node, on_complete)
  if not conn or not db_node then return end
  db_node.loading = true
  db_node.expanded = true
  core.redraw = true

  -- Ultra-fast lightweight collection names fetching in sub-10ms
  local fetch_colls_js = string.format([[
    const targetDb = db.getSiblingDB(%s);
    const infos = targetDb.getCollectionInfos({}, { nameOnly: true });
    return infos.filter(c => !c.name.startsWith('system.')).map(c => ({
      name: c.name,
      type: c.type || "collection"
    }));
  ]], json.stringify(db_node.name))

  run_mongo_cli(conn.uri, fetch_colls_js, function(data, err)
    db_node.loading = false
    if err then
      core.error("[MongoDB] Error listing collections for %s: %s", db_node.name, err)
      if on_complete then on_complete(false, err) end
      core.redraw = true
      return
    end

    local old_cols = {}
    for _, oc in ipairs(db_node.collections or {}) do
      old_cols[oc.name] = oc
    end

    db_node.collections = {}
    if type(data) == "table" then
      for _, col in ipairs(data) do
        local prev = old_cols[col.name]
        table.insert(db_node.collections, {
          name = col.name,
          count = prev and prev.count or 0,
          indexes = prev and prev.indexes or {},
          sampleDocs = prev and prev.sampleDocs or {},
          expanded = prev and prev.expanded or false,
          loaded = prev and prev.loaded or false,
          loading = false,
        })
      end
    end
    db_node.loaded = true
    db_node.expanded = true
    if on_complete then on_complete(true, nil) end
    core.redraw = true
  end)
end

function store.load_collection_details(conn, db_node, col_node, on_complete)
  if not conn or not db_node or not col_node then return end
  col_node.loading = true
  core.redraw = true

  local details_js = string.format([[
    const targetDb = db.getSiblingDB(%s);
    const targetCol = targetDb.getCollection(%s);
    let count = 0;
    try { count = targetCol.estimatedDocumentCount(); } catch(e) {}
    let indexes = [];
    try { indexes = targetCol.getIndexes(); } catch(e) {}
    let sampleDocs = [];
    try { sampleDocs = targetCol.find({}).limit(5).toArray(); } catch(e) {}
    return {
      count: count,
      indexes: indexes.map(idx => ({ name: idx.name, key: idx.key, unique: !!idx.unique })),
      sampleDocs: sampleDocs
    };
  ]], json.stringify(db_node.name), json.stringify(col_node.name))

  run_mongo_cli(conn.uri, details_js, function(data, err)
    col_node.loading = false
    if data and type(data) == "table" then
      col_node.count = data.count or col_node.count
      col_node.indexes = data.indexes or {}
      col_node.sampleDocs = data.sampleDocs or {}
      col_node.loaded = true
    end
    col_node.expanded = not col_node.expanded
    if on_complete then on_complete(true) end
    core.redraw = true
  end)
end

store.load()

-- ============================================================================
-- MongoDB Explorer Sidebar View (With Live Filter & Responsive Design)
-- ============================================================================
local MongoDBExplorerView = View:extend()

function MongoDBExplorerView:new()
  MongoDBExplorerView.super.new(self)
  self.name = "MongoDB Explorer"
  self.scrollable = true
  self.visible = true
  self.filter_text = ""
  self.filter_active = false
  self.hovered_item = nil
  self.hovered_btn = nil
  self.buttons = {}
  self.tree_rows = {}
  self.target_width = config.plugins.mongodb_explorer.view_width * SCALE
  self.target_size = self.target_width
  self.footer_rows = 1
end

function MongoDBExplorerView:get_name()
  return self.name or "MongoDB Explorer"
end

function MongoDBExplorerView:get_default_width()
  return self.target_width
end

function MongoDBExplorerView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = math.max(240 * SCALE, value)
    self.target_width = self.target_size
    return true
  elseif axis == "y" then
    return true
  end
  return false
end

function MongoDBExplorerView:update()
  MongoDBExplorerView.super.update(self)
  self.target_size = self.target_size or (config.plugins.mongodb_explorer.view_width * SCALE)
  if math.abs(self.size.x - self.target_size) > 0.5 then
    self:move_towards(self.size, "x", self.target_size)
  else
    self.size.x = self.target_size
  end
end

function MongoDBExplorerView:get_item_height()
  local pad = config.plugins.mongodb_explorer.compact_mode and (3 * SCALE) or (style.padding.y * 1.1)
  return math.floor(style.font:get_height() + pad * 2)
end

function MongoDBExplorerView:get_header_height()
  local font = style.font
  local pad_y = math.floor(style.padding.y * 0.8)
  local title_h = font:get_height() + pad_y * 2
  local search_h = font:get_height() + math.floor(8 * SCALE)
  local quick_act_h = font:get_height() + math.floor(8 * SCALE)
  return title_h + search_h + quick_act_h + math.floor(10 * SCALE)
end

function MongoDBExplorerView:get_footer_height()
  local font = style.font
  local btn_h = font:get_height() + math.floor(8 * SCALE)
  local pad_y = math.floor(6 * SCALE)
  return (self.footer_rows * (btn_h + pad_y)) + pad_y
end

function MongoDBExplorerView:get_scrollable_size()
  local count = #self.tree_rows
  local item_h = self:get_item_height()
  local header_h = self:get_header_height()
  local footer_h = self:get_footer_height()
  return header_h + (count * item_h) + footer_h + math.floor(20 * SCALE)
end

function MongoDBExplorerView:matches_filter(text)
  if not self.filter_text or self.filter_text == "" then return true end
  if not text then return false end
  return text:lower():find(self.filter_text:lower(), 1, true) ~= nil
end

function MongoDBExplorerView:build_tree_rows()
  self.tree_rows = {}
  local query = self.filter_text:lower()
  local filtering = query ~= ""

  for _, conn in ipairs(store.connections) do
    local conn_matches = self:matches_filter(conn.name) or self:matches_filter(conn.uri)
    local conn_row = {
      type = "connection",
      data = conn,
      depth = 0,
      label = conn.name,
      status = conn.status,
      version = conn.version,
    }

    local db_rows = {}
    if conn.status == "connected" and (conn.expanded or filtering) then
      for _, db in ipairs(conn.databases or {}) do
        local db_matches = self:matches_filter(db.name)
        local db_row = {
          type = "database",
          data = db,
          parent_conn = conn,
          depth = 1,
          label = db.name,
        }

        local col_rows = {}
        if db.loaded and (db.expanded or filtering) then
          for _, col in ipairs(db.collections or {}) do
            local col_matches = self:matches_filter(col.name)
            local col_row = {
              type = "collection",
              data = col,
              parent_db = db,
              parent_conn = conn,
              depth = 2,
              label = col.name,
              count = col.count,
            }

            local sub_rows = {}
            if col.expanded or filtering then
              if #col.indexes > 0 then
                local idx_matches = self:matches_filter("indexes")
                if idx_matches or col_matches or db_matches or conn_matches or not filtering then
                  table.insert(sub_rows, {
                    type = "indexes_group",
                    data = col.indexes,
                    parent_col = col,
                    parent_db = db,
                    parent_conn = conn,
                    depth = 3,
                    label = string.format("indexes (%d)", #col.indexes),
                  })
                end
              end

              for idx, doc in ipairs(col.sampleDocs or {}) do
                local preview_id = doc._id or ("doc_" .. idx)
                if type(preview_id) == "table" then
                  preview_id = preview_id["$oid"] or json.stringify(preview_id)
                end
                local doc_label = string.format("{ _id: %s }", tostring(preview_id))
                if self:matches_filter(doc_label) or col_matches or db_matches or conn_matches or not filtering then
                  table.insert(sub_rows, {
                    type = "document",
                    data = doc,
                    parent_col = col,
                    parent_db = db,
                    parent_conn = conn,
                    depth = 3,
                    label = doc_label,
                  })
                end
              end
            end

            if not filtering or col_matches or #sub_rows > 0 or db_matches or conn_matches then
              table.insert(col_rows, col_row)
              for _, sr in ipairs(sub_rows) do table.insert(col_rows, sr) end
            end
          end
        end

        if not filtering or db_matches or #col_rows > 0 or conn_matches then
          table.insert(db_rows, db_row)
          for _, cr in ipairs(col_rows) do table.insert(db_rows, cr) end
        end
      end
    end

    if not filtering or conn_matches or #db_rows > 0 then
      table.insert(self.tree_rows, conn_row)
      for _, dr in ipairs(db_rows) do table.insert(self.tree_rows, dr) end
    end
  end
end

function MongoDBExplorerView:on_mouse_moved(px, py, dx, dy)
  MongoDBExplorerView.super.on_mouse_moved(self, px, py, dx, dy)
  self.hovered_item = nil
  self.hovered_btn = nil

  for _, btn in ipairs(self.buttons) do
    if px >= btn.x and px <= btn.x + btn.w and py >= btn.y and py <= btn.y + btn.h then
      self.hovered_btn = btn
      return
    end
  end

  local item_h = self:get_item_height()
  local header_h = self:get_header_height()
  local start_y = self.position.y + header_h - self.scroll.y

  for i, row in ipairs(self.tree_rows) do
    local item_y = start_y + (i - 1) * item_h
    if px >= self.position.x and px <= self.position.x + self.size.x and py >= item_y and py <= item_y + item_h then
      self.hovered_item = row
      return
    end
  end
end

function MongoDBExplorerView:on_mouse_pressed(button, px, py, clicks)
  if MongoDBExplorerView.super.on_mouse_pressed(self, button, px, py, clicks) then
    return true
  end

  if button == "right" then
    if self.hovered_item then
      store.selected_node = self.hovered_item
      core.redraw = true
      local ok, menu = pcall(require, "plugins.contextmenu")
      if ok and menu and menu.show then
        menu:show(px, py)
        return true
      end
    end
  end

  if button == "left" then
    if self.hovered_btn then
      if self.hovered_btn.action then self.hovered_btn.action() end
      return true
    end

    -- Check Search Box Click
    local pad_x = math.floor(style.padding.x * 0.8)
    local header_h = self:get_header_height()
    local search_y = self.position.y + header_h - style.font:get_height() - math.floor(12 * SCALE)
    local search_w = self.size.x - pad_x * 2

    if px >= self.position.x + pad_x and px <= self.position.x + pad_x + search_w and py >= search_y and py <= search_y + style.font:get_height() + math.floor(8 * SCALE) then
      self.filter_active = true
      core.command_view:enter("Filter Explorer (Type query or press Enter)", {
        text = self.filter_text,
        change = function(text)
          self.filter_text = text
          core.redraw = true
        end,
        submit = function(text)
          self.filter_text = text
          self.filter_active = false
          core.redraw = true
        end,
        cancel = function()
          self.filter_active = false
          core.redraw = true
        end
      })
      return true
    end

    if self.hovered_item then
      local row = self.hovered_item
      store.selected_node = row

      if row.type == "connection" then
        if clicks == 2 then
          if row.data.status == "connected" then
            store.disconnect(row.data)
          else
            store.connect(row.data)
          end
        else
          row.data.expanded = not row.data.expanded
          if row.data.expanded and row.data.status == "disconnected" then
            store.connect(row.data)
          end
        end
      elseif row.type == "database" then
        if not row.data.loaded then
          store.load_collections(row.parent_conn, row.data)
        else
          row.data.expanded = not row.data.expanded
        end
      elseif row.type == "collection" then
        if clicks >= 2 then
          command.perform("mongodb_explorer:view-documents")
        else
          if not row.data.loaded then
            store.load_collection_details(row.parent_conn, row.parent_db, row.data)
          else
            row.data.expanded = not row.data.expanded
          end
        end
      elseif row.type == "document" then
        if clicks >= 1 then
          command.perform("mongodb_explorer:open-document-editor")
        end
      end
      core.redraw = true
      return true
    end
  end

  return false
end

function MongoDBExplorerView:draw()
  local pal = get_theme_palette()
  self:draw_background(pal.bg)
  self:build_tree_rows()
  self.buttons = {}

  local font = style.font
  local item_h = self:get_item_height()
  local pad = math.floor(style.padding.x * 0.8)
  local x, y = self.position.x, self.position.y
  local w, h = self.size.x, self.size.y

  local is_compact = (w < 300 * SCALE)
  local is_wide = (w >= 480 * SCALE)

  -- Top accent bar
  renderer.draw_rect(x, y, w, 2 * SCALE, pal.accent)

  -- 1. Header Bar (Adaptive & Scale-Aware)
  local title_pad_y = math.floor(style.padding.y * 0.8)
  local title_h = font:get_height() + title_pad_y * 2
  local header_h = self:get_header_height()

  renderer.draw_rect(x, y + 2 * SCALE, w, header_h - 2 * SCALE, pal.header_bg)

  -- Title + Action Buttons
  local title_str = is_wide and "MONGODB EXPLORER" or "MONGODB"
  renderer.draw_text(font, title_str, x + pad, y + title_pad_y, pal.accent)

  -- Add Connection & Refresh Buttons (Adapt text based on width)
  local add_btn_text = is_wide and "+ Add Connection" or (is_compact and "+" or "+ Add")
  local ref_btn_text = is_compact and "R" or "Refresh"
  local add_btn_w = font:get_width(add_btn_text) + math.floor(12 * SCALE)
  local ref_btn_w = font:get_width(ref_btn_text) + math.floor(12 * SCALE)
  local btn_h = font:get_height() + math.floor(4 * SCALE)
  local btn_y = y + title_pad_y - math.floor(2 * SCALE)

  local ref_btn_x = x + w - pad - ref_btn_w
  local add_btn_x = ref_btn_x - math.floor(6 * SCALE) - add_btn_w

  local is_hover_add = self.hovered_btn and self.hovered_btn.id == "add_conn"
  local is_hover_ref = self.hovered_btn and self.hovered_btn.id == "refresh_all"

  renderer.draw_rect(add_btn_x, btn_y, add_btn_w, btn_h, is_hover_add and pal.btn_hover or pal.btn_bg)
  renderer.draw_rect(add_btn_x, btn_y, add_btn_w, 1 * SCALE, is_hover_add and pal.accent or pal.btn_border)
  renderer.draw_rect(add_btn_x, btn_y + btn_h - 1 * SCALE, add_btn_w, 1 * SCALE, is_hover_add and pal.accent or pal.btn_border)
  renderer.draw_rect(add_btn_x, btn_y, 1 * SCALE, btn_h, is_hover_add and pal.accent or pal.btn_border)
  renderer.draw_rect(add_btn_x + add_btn_w - 1 * SCALE, btn_y, 1 * SCALE, btn_h, is_hover_add and pal.accent or pal.btn_border)
  renderer.draw_text(font, add_btn_text, add_btn_x + math.floor(6 * SCALE), btn_y + math.floor(2 * SCALE), is_hover_add and pal.btn_hover_text or pal.btn_text)
  table.insert(self.buttons, {
    id = "add_conn",
    x = add_btn_x, y = btn_y, w = add_btn_w, h = btn_h,
    action = function() command.perform("mongodb_explorer:add-connection") end
  })

  renderer.draw_rect(ref_btn_x, btn_y, ref_btn_w, btn_h, is_hover_ref and pal.btn_hover or pal.btn_bg)
  renderer.draw_rect(ref_btn_x, btn_y, ref_btn_w, 1 * SCALE, is_hover_ref and pal.accent or pal.btn_border)
  renderer.draw_rect(ref_btn_x, btn_y + btn_h - 1 * SCALE, ref_btn_w, 1 * SCALE, is_hover_ref and pal.accent or pal.btn_border)
  renderer.draw_rect(ref_btn_x, btn_y, 1 * SCALE, btn_h, is_hover_ref and pal.accent or pal.btn_border)
  renderer.draw_rect(ref_btn_x + ref_btn_w - 1 * SCALE, btn_y, 1 * SCALE, btn_h, is_hover_ref and pal.accent or pal.btn_border)
  renderer.draw_text(font, ref_btn_text, ref_btn_x + math.floor(6 * SCALE), btn_y + math.floor(2 * SCALE), is_hover_ref and pal.btn_hover_text or pal.btn_text)
  table.insert(self.buttons, {
    id = "refresh_all",
    x = ref_btn_x, y = btn_y, w = ref_btn_w, h = btn_h,
    action = function() command.perform("mongodb_explorer:refresh") end
  })

  -- Filter / Search Input Box
  local search_box_y = y + title_h + math.floor(2 * SCALE)
  local search_box_w = w - pad * 2
  local search_box_h = font:get_height() + math.floor(6 * SCALE)

  renderer.draw_rect(x + pad, search_box_y, search_box_w, search_box_h, pal.search_bg)
  renderer.draw_rect(x + pad, search_box_y, search_box_w, 1 * SCALE, self.filter_active and pal.accent or pal.search_border)
  renderer.draw_rect(x + pad, search_box_y + search_box_h - 1 * SCALE, search_box_w, 1 * SCALE, self.filter_active and pal.accent or pal.search_border)
  renderer.draw_rect(x + pad, search_box_y, 1 * SCALE, search_box_h, self.filter_active and pal.accent or pal.search_border)
  renderer.draw_rect(x + pad + search_box_w - 1 * SCALE, search_box_y, 1 * SCALE, search_box_h, self.filter_active and pal.accent or pal.search_border)

  local search_icon = "Filter: "
  local s_icon_w = font:get_width(search_icon)
  renderer.draw_text(font, search_icon, x + pad + math.floor(6 * SCALE), search_box_y + math.floor(3 * SCALE), pal.dim)

  local search_txt_x = x + pad + math.floor(6 * SCALE) + s_icon_w
  if self.filter_text and self.filter_text ~= "" then
    local query_disp = truncate_text(font, self.filter_text, search_box_w - s_icon_w - math.floor(30 * SCALE))
    renderer.draw_text(font, query_disp, search_txt_x, search_box_y + math.floor(3 * SCALE), pal.search_text)

    -- Clear filter button '[x]'
    local clr_btn_w = font:get_width("[x]") + math.floor(6 * SCALE)
    local clr_btn_x = x + pad + search_box_w - clr_btn_w - math.floor(2 * SCALE)
    local is_clr_hover = self.hovered_btn and self.hovered_btn.id == "clear_filter"
    renderer.draw_text(font, "[x]", clr_btn_x + math.floor(3 * SCALE), search_box_y + math.floor(3 * SCALE), is_clr_hover and pal.accent or pal.dim)
    table.insert(self.buttons, {
      id = "clear_filter",
      x = clr_btn_x, y = search_box_y, w = clr_btn_w, h = search_box_h,
      action = function()
        self.filter_text = ""
        core.redraw = true
      end
    })
  else
    local placeholder = is_compact and "Search..." or (is_wide and "Filter clusters, databases, collections, indexes..." or "Filter databases & collections...")
    placeholder = truncate_text(font, placeholder, search_box_w - s_icon_w - math.floor(10 * SCALE))
    renderer.draw_text(font, placeholder, search_txt_x, search_box_y + math.floor(3 * SCALE), pal.search_placeholder)
  end

  -- Upper Section Quick Actions Bar (Directly after Search / Filter Input)
  local quick_act_y = search_box_y + search_box_h + math.floor(4 * SCALE)
  local quick_btn_h = font:get_height() + math.floor(4 * SCALE)
  local q_cur_x = x + pad
  local q_gap = math.floor(4 * SCALE)

  local sel_node = store.selected_node
  local quick_buttons = {
    { label = "+ Col", cmd = "mongodb_explorer:create-collection" },
    { label = "+ Doc", cmd = "mongodb_explorer:insert-document" },
    { label = "Edit", cmd = "mongodb_explorer:open-document-editor" },
    { label = "Del", cmd = (sel_node and sel_node.type == "collection" and "mongodb_explorer:drop-collection" or "mongodb_explorer:delete-document") },
    { label = "Refresh", cmd = "mongodb_explorer:refresh" },
    { label = "Scratch", cmd = "mongodb_explorer:new-scratchpad" },
  }

  for _, qb in ipairs(quick_buttons) do
    local qbw = font:get_width(qb.label) + math.floor(8 * SCALE)
    if q_cur_x + qbw <= x + w - pad then
      local is_qb_hover = self.hovered_btn and self.hovered_btn.id == ("qact_" .. qb.label)
      renderer.draw_rect(q_cur_x, quick_act_y, qbw, quick_btn_h, is_qb_hover and pal.btn_hover or pal.btn_bg)
      renderer.draw_rect(q_cur_x, quick_act_y, qbw, 1 * SCALE, is_qb_hover and pal.accent or pal.btn_border)
      renderer.draw_rect(q_cur_x, quick_act_y + quick_btn_h - 1 * SCALE, qbw, 1 * SCALE, is_qb_hover and pal.accent or pal.btn_border)
      renderer.draw_rect(q_cur_x, quick_act_y, 1 * SCALE, quick_btn_h, is_qb_hover and pal.accent or pal.btn_border)
      renderer.draw_rect(q_cur_x + qbw - 1 * SCALE, quick_act_y, 1 * SCALE, quick_btn_h, is_qb_hover and pal.accent or pal.btn_border)
      renderer.draw_text(font, qb.label, q_cur_x + math.floor(4 * SCALE), quick_act_y + math.floor(2 * SCALE), is_qb_hover and pal.btn_hover_text or pal.btn_text)
      table.insert(self.buttons, {
        id = "qact_" .. qb.label,
        x = q_cur_x, y = quick_act_y, w = qbw, h = quick_btn_h,
        action = function() command.perform(qb.cmd) end
      })
      q_cur_x = q_cur_x + qbw + q_gap
    end
  end

  -- Header Bottom Divider
  renderer.draw_rect(x, y + header_h - 1 * SCALE, w, 1 * SCALE, pal.divider)

  -- 2. Scrollable Tree List
  local footer_h = self:get_footer_height()
  core.push_clip_rect(x, y + header_h, w, h - header_h - footer_h)
  local row_y = y + header_h + math.floor(2 * SCALE) - self.scroll.y
  local step_x = math.floor(14 * SCALE)

  for _, row in ipairs(self.tree_rows) do
    if row_y + item_h >= y + header_h and row_y <= y + h - footer_h then
      local is_selected = store.selected_node == row
      local is_hover = self.hovered_item == row

      if is_selected then
        renderer.draw_rect(x, row_y, w, item_h, pal.row_selected)
        renderer.draw_rect(x, row_y, 3 * SCALE, item_h, pal.accent)
      elseif is_hover then
        renderer.draw_rect(x, row_y, w, item_h, pal.row_hover)
      end

      -- Vertical hierarchy guides
      if row.depth > 0 then
        draw_indent_guides(x + pad, row_y, item_h, row.depth, step_x, pal.indent_guide)
      end

      local indent_x = x + pad + (row.depth * step_x)
      local text_y = row_y + math.floor((item_h - font:get_height()) / 2)
      local row_text_color = is_selected and pal.row_selected_text or pal.text

      if row.type == "connection" then
        local fold_icon = (row.data.expanded or (self.filter_text ~= "")) and "v " or "> "
        renderer.draw_text(font, fold_icon, indent_x, text_y, pal.dim)
        local icon_w = font:get_width(fold_icon)

        local cluster_icon = "[C] "
        renderer.draw_text(font, cluster_icon, indent_x + icon_w, text_y, pal.accent)
        local cluster_icon_w = font:get_width(cluster_icon)

        -- Status Indicator (Badge / Dot)
        local status_str = "Connected"
        local status_col = pal.status_connected
        if row.status == "disconnected" then
          status_str = "Disconnected"
          status_col = pal.status_disconnected
        elseif row.status == "connecting" then
          status_str = "Connecting..."
          status_col = pal.status_connecting
        elseif row.status == "error" then
          status_str = "Error"
          status_col = pal.status_error
        end

        if row.version and row.version ~= "" and (is_wide or not is_compact) then
          status_str = status_str .. " (v" .. row.version:gsub("^v", "") .. ")"
        end

        local dot_sz = math.floor(6 * SCALE)
        local status_txt_w = font:get_width(status_str)
        local total_status_w = dot_sz + math.floor(4 * SCALE) + status_txt_w

        local max_label_w = math.max(0, w - (indent_x + icon_w + cluster_icon_w - x) - total_status_w - pad * 2 - math.floor(8 * SCALE))
        local label_to_draw = truncate_text(font, row.label, max_label_w)
        renderer.draw_text(font, label_to_draw, indent_x + icon_w + cluster_icon_w, text_y, row_text_color)

        if x + w - pad - total_status_w > indent_x + icon_w + cluster_icon_w + font:get_width(label_to_draw) + math.floor(6 * SCALE) then
          local dot_x = x + w - pad - total_status_w
          local dot_y = row_y + math.floor((item_h - dot_sz) / 2)
          renderer.draw_rect(dot_x, dot_y, dot_sz, dot_sz, status_col)
          renderer.draw_text(font, status_str, dot_x + dot_sz + math.floor(4 * SCALE), text_y, status_col)
        end

      elseif row.type == "database" then
        local fold_icon = (row.data.expanded or (self.filter_text ~= "")) and "v " or "> "
        renderer.draw_text(font, fold_icon, indent_x, text_y, pal.dim)
        local icon_w = font:get_width(fold_icon)

        local db_icon = "[DB] "
        renderer.draw_text(font, db_icon, indent_x + icon_w, text_y, pal.accent)
        local db_icon_w = font:get_width(db_icon)

        local extra_info = ""
        local extra_w = 0
        if is_wide and row.data.collections and #row.data.collections > 0 then
          extra_info = string.format("(%d cols)", #row.data.collections)
          extra_w = font:get_width(extra_info) + math.floor(10 * SCALE)
        end

        local max_db_w = math.max(0, w - (indent_x + icon_w + db_icon_w - x) - extra_w - pad - math.floor(60 * SCALE))
        local label_to_draw = truncate_text(font, row.label, max_db_w)
        renderer.draw_text(font, label_to_draw, indent_x + icon_w + db_icon_w, text_y, row_text_color)
        local label_w = font:get_width(label_to_draw)

        -- INLINE ACTIONS RIGHT AFTER DATABASE NAME: [+ Col] [Ref]
        local inline_x = indent_x + icon_w + db_icon_w + label_w + math.floor(6 * SCALE)
        local bh = item_h - math.floor(4 * SCALE)
        local by = row_y + math.floor(2 * SCALE)

        if inline_x < x + w - pad - math.floor(35 * SCALE) then
          local btn_txt = "+ Col"
          local bw = font:get_width(btn_txt) + math.floor(6 * SCALE)
          local is_b_hover = self.hovered_btn and self.hovered_btn.id == ("row_add_col_" .. row.label)
          renderer.draw_rect(inline_x, by, bw, bh, is_b_hover and pal.btn_hover or pal.btn_bg)
          renderer.draw_rect(inline_x, by, bw, 1 * SCALE, is_b_hover and pal.accent or pal.btn_border)
          renderer.draw_rect(inline_x, by + bh - 1 * SCALE, bw, 1 * SCALE, is_b_hover and pal.accent or pal.btn_border)
          renderer.draw_rect(inline_x, by, 1 * SCALE, bh, is_b_hover and pal.accent or pal.btn_border)
          renderer.draw_rect(inline_x + bw - 1 * SCALE, by, 1 * SCALE, bh, is_b_hover and pal.accent or pal.btn_border)
          renderer.draw_text(font, btn_txt, inline_x + math.floor(3 * SCALE), text_y, is_b_hover and pal.btn_hover_text or pal.accent)
          table.insert(self.buttons, {
            id = "row_add_col_" .. row.label,
            x = inline_x, y = by, w = bw, h = bh,
            action = function()
              store.selected_node = row
              command.perform("mongodb_explorer:create-collection")
            end
          })
          inline_x = inline_x + bw + math.floor(4 * SCALE)
        end

        if extra_info ~= "" and x + w - pad - extra_w > inline_x + math.floor(6 * SCALE) then
          renderer.draw_text(font, extra_info, x + w - pad - extra_w, text_y, pal.dim)
        end

      elseif row.type == "collection" then
        local fold_icon = (row.data.expanded or (self.filter_text ~= "")) and "v " or "> "
        renderer.draw_text(font, fold_icon, indent_x, text_y, pal.dim)
        local icon_w = font:get_width(fold_icon)

        local col_icon = "[Col] "
        renderer.draw_text(font, col_icon, indent_x + icon_w, text_y, pal.text)
        local col_icon_w = font:get_width(col_icon)

        local count_w = 0
        local count_str = ""
        if config.plugins.mongodb_explorer.show_doc_counts and row.count ~= nil then
          count_str = string.format("%s docs", format_number(row.count))
          count_w = font:get_width(count_str) + math.floor(8 * SCALE)
        end

        local max_col_w = math.max(0, w - (indent_x + icon_w + col_icon_w - x) - math.floor(110 * SCALE))
        local label_to_draw = truncate_text(font, row.label, max_col_w)
        renderer.draw_text(font, label_to_draw, indent_x + icon_w + col_icon_w, text_y, row_text_color)
        local label_w = font:get_width(label_to_draw)

        -- INLINE ACTIONS RIGHT AFTER COLLECTION NAME: (count) [+ Doc] [Docs] [x]
        local inline_x = indent_x + icon_w + col_icon_w + label_w + math.floor(6 * SCALE)
        local bh = item_h - math.floor(4 * SCALE)
        local by = row_y + math.floor(2 * SCALE)

        if count_str ~= "" and inline_x + count_w < x + w - pad - math.floor(50 * SCALE) then
          local badge_y = row_y + math.floor((item_h - font:get_height() - math.floor(2 * SCALE)) / 2)
          draw_pill_badge(font, count_str, inline_x, badge_y, pal.badge_bg, pal.badge_text, pal.badge_border)
          inline_x = inline_x + count_w + math.floor(4 * SCALE)
        end

        -- [+ Doc] Button inline right after collection name
        local add_txt = "+ Doc"
        local add_w = font:get_width(add_txt) + math.floor(6 * SCALE)
        if inline_x + add_w <= x + w - pad - math.floor(35 * SCALE) then
          local is_a_hover = self.hovered_btn and self.hovered_btn.id == ("row_add_doc_" .. row.label)
          renderer.draw_rect(inline_x, by, add_w, bh, is_a_hover and pal.btn_hover or pal.btn_bg)
          renderer.draw_rect(inline_x, by, add_w, 1 * SCALE, is_a_hover and pal.accent or pal.btn_border)
          renderer.draw_rect(inline_x, by + bh - 1 * SCALE, add_w, 1 * SCALE, is_a_hover and pal.accent or pal.btn_border)
          renderer.draw_rect(inline_x, by, 1 * SCALE, bh, is_a_hover and pal.accent or pal.btn_border)
          renderer.draw_rect(inline_x + add_w - 1 * SCALE, by, 1 * SCALE, bh, is_a_hover and pal.accent or pal.btn_border)
          renderer.draw_text(font, add_txt, inline_x + math.floor(3 * SCALE), text_y, is_a_hover and pal.btn_hover_text or pal.accent)
          table.insert(self.buttons, {
            id = "row_add_doc_" .. row.label,
            x = inline_x, y = by, w = add_w, h = bh,
            action = function()
              store.selected_node = row
              command.perform("mongodb_explorer:insert-document")
            end
          })
          inline_x = inline_x + add_w + math.floor(4 * SCALE)
        end

        -- [Docs] Button inline right after collection name
        local view_txt = "Docs"
        local view_w = font:get_width(view_txt) + math.floor(6 * SCALE)
        if inline_x + view_w <= x + w - pad - math.floor(20 * SCALE) then
          local is_v_hover = self.hovered_btn and self.hovered_btn.id == ("row_view_doc_" .. row.label)
          renderer.draw_rect(inline_x, by, view_w, bh, is_v_hover and pal.btn_hover or pal.btn_bg)
          renderer.draw_text(font, view_txt, inline_x + math.floor(3 * SCALE), text_y, is_v_hover and pal.btn_hover_text or pal.text)
          table.insert(self.buttons, {
            id = "row_view_doc_" .. row.label,
            x = inline_x, y = by, w = view_w, h = bh,
            action = function()
              store.selected_node = row
              command.perform("mongodb_explorer:view-documents")
            end
          })
          inline_x = inline_x + view_w + math.floor(4 * SCALE)
        end

        -- [x] Drop Button inline right after collection name
        local drop_txt = "x"
        local drop_w = font:get_width(drop_txt) + math.floor(6 * SCALE)
        if inline_x + drop_w <= x + w - pad then
          local is_d_hover = self.hovered_btn and self.hovered_btn.id == ("row_drop_col_" .. row.label)
          renderer.draw_rect(inline_x, by, drop_w, bh, is_d_hover and pal.status_error or pal.btn_bg)
          renderer.draw_text(font, drop_txt, inline_x + math.floor(3 * SCALE), text_y, is_d_hover and pal.btn_hover_text or pal.status_error)
          table.insert(self.buttons, {
            id = "row_drop_col_" .. row.label,
            x = inline_x, y = by, w = drop_w, h = bh,
            action = function()
              store.selected_node = row
              command.perform("mongodb_explorer:drop-collection")
            end
          })
        end

      elseif row.type == "indexes_group" then
        local idx_icon = "[Idx] "
        renderer.draw_text(font, idx_icon, indent_x, text_y, pal.dim)
        local icon_w = font:get_width(idx_icon)
        local max_idx_w = math.max(0, w - (indent_x + icon_w - x) - pad)
        local label_to_draw = truncate_text(font, row.label, max_idx_w)
        renderer.draw_text(font, label_to_draw, indent_x + icon_w, text_y, pal.dim)

      elseif row.type == "document" then
        local doc_icon = "[Doc] "
        renderer.draw_text(font, doc_icon, indent_x, text_y, pal.dim)
        local icon_w = font:get_width(doc_icon)
        local max_doc_w = math.max(0, w - (indent_x + icon_w - x) - math.floor(75 * SCALE))
        local label_to_draw = truncate_text(font, row.label, max_doc_w)
        renderer.draw_text(font, label_to_draw, indent_x + icon_w, text_y, pal.dim)
        local label_w = font:get_width(label_to_draw)

        -- INLINE ACTIONS RIGHT AFTER RECORD / DOCUMENT: [Edit] [Del]
        local inline_x = indent_x + icon_w + label_w + math.floor(6 * SCALE)
        local bh = item_h - math.floor(4 * SCALE)
        local by = row_y + math.floor(2 * SCALE)

        local edit_txt = "Edit"
        local edit_w = font:get_width(edit_txt) + math.floor(6 * SCALE)
        if inline_x + edit_w <= x + w - pad - math.floor(25 * SCALE) then
          local is_ed_hover = self.hovered_btn and self.hovered_btn.id == ("row_ed_doc_" .. tostring(row.label))
          renderer.draw_rect(inline_x, by, edit_w, bh, is_ed_hover and pal.btn_hover or pal.btn_bg)
          renderer.draw_rect(inline_x, by, edit_w, 1 * SCALE, is_ed_hover and pal.accent or pal.btn_border)
          renderer.draw_rect(inline_x, by + bh - 1 * SCALE, edit_w, 1 * SCALE, is_ed_hover and pal.accent or pal.btn_border)
          renderer.draw_rect(inline_x, by, 1 * SCALE, bh, is_ed_hover and pal.accent or pal.btn_border)
          renderer.draw_rect(inline_x + edit_w - 1 * SCALE, by, 1 * SCALE, bh, is_ed_hover and pal.accent or pal.btn_border)
          renderer.draw_text(font, edit_txt, inline_x + math.floor(3 * SCALE), text_y, is_ed_hover and pal.btn_hover_text or pal.accent)
          table.insert(self.buttons, {
            id = "row_ed_doc_" .. tostring(row.label),
            x = inline_x, y = by, w = edit_w, h = bh,
            action = function()
              store.selected_node = row
              command.perform("mongodb_explorer:open-document-editor")
            end
          })
          inline_x = inline_x + edit_w + math.floor(4 * SCALE)
        end

        local del_txt = "Del"
        local del_w = font:get_width(del_txt) + math.floor(6 * SCALE)
        if inline_x + del_w <= x + w - pad then
          local is_del_hover = self.hovered_btn and self.hovered_btn.id == ("row_del_doc_" .. tostring(row.label))
          renderer.draw_rect(inline_x, by, del_w, bh, is_del_hover and pal.status_error or pal.btn_bg)
          renderer.draw_text(font, del_txt, inline_x + math.floor(3 * SCALE), text_y, is_del_hover and pal.btn_hover_text or pal.status_error)
          table.insert(self.buttons, {
            id = "row_del_doc_" .. tostring(row.label),
            x = inline_x, y = by, w = del_w, h = bh,
            action = function()
              store.selected_node = row
              command.perform("mongodb_explorer:delete-document")
            end
          })
        end
      end
    end
    row_y = row_y + item_h
  end
  core.pop_clip_rect()

  -- 3. Responsive Context-Aware Auto-Wrapping Bottom Action Toolbar
  local footer_y = y + h - footer_h
  renderer.draw_rect(x, footer_y, w, footer_h, pal.footer_bg)
  renderer.draw_rect(x, footer_y, w, 1 * SCALE, pal.divider)

  local s_lbl = (store.server_status == "starting" and "Starting...") or (store.server_status == "stopping" and "Stopping...") or (store.server_status == "running" and "Stop Server" or "Start Server")

  local action_buttons = {}
  local sel = store.selected_node

  if sel and sel.type == "collection" then
    table.insert(action_buttons, { label = "📄 View Docs", cmd = "mongodb_explorer:view-documents" })
    table.insert(action_buttons, { label = "➕ Insert Doc", cmd = "mongodb_explorer:insert-document" })
    table.insert(action_buttons, { label = "⚠️ Clear All", cmd = "mongodb_explorer:clear-collection" })
    table.insert(action_buttons, { label = "🗑 Drop Col", cmd = "mongodb_explorer:drop-collection" })
    table.insert(action_buttons, { label = "⚡ Scratchpad", cmd = "mongodb_explorer:new-scratchpad" })
    table.insert(action_buttons, { label = "Shell", cmd = "mongodb_explorer:open-terminal" })
  elseif sel and sel.type == "database" then
    table.insert(action_buttons, { label = "➕ New Coll", cmd = "mongodb_explorer:create-collection" })
    table.insert(action_buttons, { label = "⚡ Scratchpad", cmd = "mongodb_explorer:new-scratchpad" })
    table.insert(action_buttons, { label = "🔄 Refresh", cmd = "mongodb_explorer:refresh" })
    table.insert(action_buttons, { label = "Shell", cmd = "mongodb_explorer:open-terminal" })
  elseif sel and sel.type == "document" then
    table.insert(action_buttons, { label = "✏️ Edit Record", cmd = "mongodb_explorer:open-document-editor" })
    table.insert(action_buttons, { label = "🗑 Delete Record", cmd = "mongodb_explorer:delete-document" })
    table.insert(action_buttons, { label = "📋 Copy JSON", cmd = "mongodb_explorer:copy-document-json" })
    table.insert(action_buttons, { label = "📄 View All", cmd = "mongodb_explorer:view-documents" })
  else
    table.insert(action_buttons, { label = s_lbl, cmd = "mongodb_explorer:toggle-server" })
    table.insert(action_buttons, { label = "mongosh Shell", cmd = "mongodb_explorer:open-terminal" })
    table.insert(action_buttons, { label = "View Docs", cmd = "mongodb_explorer:view-documents" })
    table.insert(action_buttons, { label = "Scratchpad", cmd = "mongodb_explorer:new-scratchpad" })
    table.insert(action_buttons, { label = "Insert", cmd = "mongodb_explorer:insert-document" })
    table.insert(action_buttons, { label = "Disconnect", cmd = "mongodb_explorer:disconnect" })
  end

  local cur_x = x + pad
  local cur_row = 1
  local btn_row_h = font:get_height() + math.floor(8 * SCALE)
  local btn_gap = math.floor(5 * SCALE)
  local cur_y = footer_y + math.floor(6 * SCALE)

  for _, act in ipairs(action_buttons) do
    local bw = font:get_width(act.label) + math.floor(12 * SCALE)

    if cur_x + bw > x + w - pad and cur_x > x + pad then
      cur_row = cur_row + 1
      cur_x = x + pad
      cur_y = cur_y + btn_row_h + btn_gap
    end

    local is_act_hover = self.hovered_btn and self.hovered_btn.id == ("act_" .. act.label)
    renderer.draw_rect(cur_x, cur_y, bw, btn_row_h, is_act_hover and pal.btn_hover or pal.btn_bg)
    renderer.draw_rect(cur_x, cur_y, bw, 1 * SCALE, is_act_hover and pal.accent or pal.btn_border)
    renderer.draw_rect(cur_x, cur_y + btn_row_h - 1 * SCALE, bw, 1 * SCALE, is_act_hover and pal.accent or pal.btn_border)
    renderer.draw_rect(cur_x, cur_y, 1 * SCALE, btn_row_h, is_act_hover and pal.accent or pal.btn_border)
    renderer.draw_rect(cur_x + bw - 1 * SCALE, cur_y, 1 * SCALE, btn_row_h, is_act_hover and pal.accent or pal.btn_border)

    local txt_col = is_act_hover and pal.btn_hover_text or pal.btn_text
    renderer.draw_text(font, act.label, cur_x + math.floor(6 * SCALE), cur_y + math.floor(4 * SCALE), txt_col)

    table.insert(self.buttons, {
      id = "act_" .. act.label,
      x = cur_x, y = cur_y, w = bw, h = btn_row_h,
      action = function() command.perform(act.cmd) end
    })

    cur_x = cur_x + bw + btn_gap
  end

  if self.footer_rows ~= cur_row then
    self.footer_rows = cur_row
  end

  self:draw_scrollbar()
end

-- ============================================================================
-- Document Virtual Doc & Scratchpad Helpers (High Performance & Memory Safe)
-- ============================================================================
local function open_virtual_doc(title, content, syntax_filename, metadata)
  -- Search if a document of this type/scope is already open to reuse it
  local existing_doc = nil
  for _, d in ipairs(core.docs) do
    if metadata and metadata.is_mongo_scratchpad and d.is_mongo_scratchpad and d.mongo_db == metadata.mongo_db then
      existing_doc = d
      break
    elseif metadata and metadata.is_mongo_results and d.is_mongo_results then
      existing_doc = d
      break
    elseif metadata and metadata.is_mongo_doc_viewer and d.is_mongo_doc_viewer and d.mongo_db == metadata.mongo_db and d.mongo_col == metadata.mongo_col then
      existing_doc = d
      break
    elseif d.filename and syntax_filename and d.filename == syntax_filename then
      existing_doc = d
      break
    end
  end

  if existing_doc then
    -- Reuse existing open tab in-place
    existing_doc:reset()
    pcall(function() existing_doc:raw_insert(1, 1, content or "") end)
    existing_doc:clean()
    existing_doc.clean_change_id = existing_doc:get_change_id()
    if metadata then
      for k, v in pairs(metadata) do existing_doc[k] = v end
    end
    
    -- Focus existing view
    for _, node in ipairs(core.root_view.root_node:get_children()) do
      if node.views then
        for _, view in ipairs(node.views) do
          if view.doc == existing_doc then
            core.set_active_view(view)
            return existing_doc, view
          end
        end
      end
    end
    local doc_view = core.root_view:open_doc(existing_doc)
    return existing_doc, doc_view
  end

  local doc = Doc()
  if syntax_filename then
    pcall(function() doc:set_filename(syntax_filename) end)
  end
  doc:reset()
  pcall(function() doc:raw_insert(1, 1, content or "") end)
  doc:clean()
  doc.clean_change_id = doc:get_change_id()

  if metadata then
    for k, v in pairs(metadata) do
      doc[k] = v
    end
  end

  local doc_view = core.root_view:open_doc(doc)
  return doc, doc_view
end

local function get_selected_context()
  local sel = store.selected_node
  if not sel then return nil end

  local conn, db, col = nil, nil, nil
  if sel.type == "connection" then
    conn = sel.data
  elseif sel.type == "database" then
    conn = sel.parent_conn
    db = sel.data.name
  elseif sel.type == "collection" then
    conn = sel.parent_conn
    db = sel.parent_db.name
    col = sel.data.name
  elseif sel.type == "document" or sel.type == "indexes_group" then
    conn = sel.parent_conn
    db = sel.parent_db.name
    col = sel.parent_col.name
  end

  return conn, db, col
end

-- ============================================================================
-- Plugin Commands & Keymaps
-- ============================================================================

local function resolve_mongosh_binary()
  local is_windows = (PLATFORM == "Windows" or os.getenv("OS") == "Windows_NT" or package.config:sub(1,1) == "\\")
  local custom = config.plugins.mongodb_explorer.mongosh_path
  if custom and custom ~= "" and custom ~= "mongosh" then return custom end
  if is_windows then
    local candidates = {
      (os.getenv("LOCALAPPDATA") or "") .. "\\Programs\\mongosh\\mongosh.exe",
      (os.getenv("LOCALAPPDATA") or "") .. "\\Programs\\mongosh\\bin\\mongosh.exe",
      "C:\\Program Files\\MongoDB\\Server\\7.0\\bin\\mongosh.exe",
      "C:\\Program Files\\MongoDB\\Server\\6.0\\bin\\mongosh.exe",
      "C:\\Program Files\\MongoDB\\Server\\7.0\\bin\\mongo.exe",
      "C:\\Program Files\\MongoDB\\Server\\6.0\\bin\\mongo.exe",
    }
    for _, p in ipairs(candidates) do
      local f = io.open(p, "r")
      if f then
        f:close()
        return p
      end
    end
  end
  return "mongosh"
end

local function open_mongosh_terminal(conn, db)
  if not conn then
    conn = store.connections[1]
  end
  if not conn then
    core.warn("[MongoDB] No connection available to open mongosh terminal.")
    return
  end

  local connect_target = conn.uri
  if db and db ~= "" and not conn.uri:find("mongodb%+?s?r?v?://[^/]+/[^?]+") then
    if conn.uri:find("%?") then
      connect_target = conn.uri:gsub("%?", "/" .. db .. "?", 1)
    else
      connect_target = conn.uri:gsub("/?$", "/" .. db)
    end
  end

  local is_windows = (PLATFORM == "Windows" or os.getenv("OS") == "Windows_NT" or package.config:sub(1,1) == "\\")
  local bin_path = resolve_mongosh_binary()
  local title = string.format("MongoDB Shell (%s)", db and (conn.name .. " / " .. db) or conn.name)

  pcall(function()
    if is_windows then
      -- Launch in native dedicated terminal window with zero freezing and 100% crash protection
      local proc = process.start({ "cmd.exe", "/c", "start", title, bin_path, connect_target })
      if proc then
        core.log("[MongoDB] Launched interactive mongosh terminal (%s)", conn.name)
      else
        core.warn("[MongoDB] Failed to start mongosh process.")
      end
    else
      local proc = process.start({ "x-terminal-emulator", "-e", bin_path, connect_target })
      if not proc then proc = process.start({ "gnome-terminal", "--", bin_path, connect_target }) end
      if not proc then proc = process.start({ "xterm", "-e", bin_path, connect_target }) end
      if proc then
        core.log("[MongoDB] Launched interactive mongosh terminal (%s)", conn.name)
      else
        core.warn("[MongoDB] Could not launch terminal emulator.")
      end
    end
  end)
end

local function preprocess_mongo_script(code)
  if not code then return "" end
  local lines = {}
  for line in code:gmatch("[^\r\n]+") do
    local stripped = line:match("^%s*(.-)%s*$")
    if stripped:sub(1, 2) == "//" or stripped:sub(1, 2) == "/*" or stripped:sub(1, 1) == "*" then
      table.insert(lines, line)
    elseif stripped:lower():match("^show%s+dbs%s*;?$") or stripped:lower():match("^show%s+databases%s*;?$") then
      table.insert(lines, "return db.adminCommand({ listDatabases: 1 });")
    elseif stripped:lower():match("^show%s+collections%s*;?$") or stripped:lower():match("^show%s+tables%s*;?$") then
      table.insert(lines, "return db.getCollectionNames();")
    elseif stripped:lower():match("^show%s+users%s*;?$") then
      table.insert(lines, "return db.getUsers();")
    elseif stripped:lower():match("^show%s+profile%s*;?$") then
      table.insert(lines, "return db.system.profile.find().toArray();")
    elseif stripped:lower():match("^use%s+([%w_%-]+)%s*;?$") then
      local db_target = stripped:match("^use%s+([%w_%-]+)%s*;?$")
      table.insert(lines, string.format('db = (typeof db !== "undefined" && db.getSiblingDB) ? db.getSiblingDB(%s) : db;', json.stringify(db_target)))
    else
      -- Auto-convert db.collection. to db.getCollection("collection"). if written literally
      local fixed_line = line:gsub("db%.collection%.", "db.getCollection(\"collection\").")
      table.insert(lines, fixed_line)
    end
  end

  -- If the last non-empty line is an expression without return/declaration, wrap with return (...)
  local last_idx = nil
  for i = #lines, 1, -1 do
    local s = lines[i]:match("^%s*(.-)%s*$")
    if s ~= "" and s:sub(1, 2) ~= "//" and s:sub(1, 2) ~= "/*" and s:sub(1, 1) ~= "*" then
      last_idx = i
      break
    end
  end

  if last_idx then
    local s = lines[last_idx]:match("^%s*(.-)%s*$")
    local lower = s:lower()
    if not (lower:match("^return%s") or lower:match("^const%s") or lower:match("^let%s") or lower:match("^var%s") or lower:match("^if%s*%(") or lower:match("^for%s*%(") or lower:match("^while%s*%(") or lower:match("^function%s") or lower:match("^try%s*{") or lower:match("^switch%s*%(")) then
      local trimmed = s:gsub(";%s*$", "")
      lines[last_idx] = "return (" .. trimmed .. ");"
    end
  end

  return table.concat(lines, "\n")
end

local explorer_view = nil

local function get_or_create_explorer()
  if not explorer_view then
    explorer_view = MongoDBExplorerView()
  end
  return explorer_view
end

command.add(nil, {
  ["mongodb_explorer:start-server"] = function()
    store.start_server()
  end,

  ["mongodb_explorer:stop-server"] = function()
    store.stop_server()
  end,

  ["mongodb_explorer:toggle-server"] = function()
    if store.server_status == "running" then
      store.stop_server()
    else
      store.start_server()
    end
  end,

  ["mongodb_explorer:open-terminal"] = function()
    local conn, db, _ = get_selected_context()
    open_mongosh_terminal(conn, db)
  end,

  ["mongodb_explorer:open-mongosh-terminal"] = function()
    local conn, db, _ = get_selected_context()
    open_mongosh_terminal(conn, db)
  end,

  ["mongodb:activity-bar"] = function()
    command.perform("mongodb_explorer:toggle")
  end,

  ["mongodb_explorer:toggle"] = function()
    local sidebar = _G.get_sidebar_node and _G.get_sidebar_node()
    if explorer_view and core.root_view.root_node:get_node_for_view(explorer_view) then
      local node = core.root_view.root_node:get_node_for_view(explorer_view)
      if sidebar and node == sidebar and node.active_view ~= explorer_view then
        node:set_active_view(explorer_view)
        core.set_active_view(explorer_view)
      else
        node:close_view(core.root_view.root_node, explorer_view)
        explorer_view = nil
      end
    else
      if not explorer_view then
        explorer_view = MongoDBExplorerView()
      end
      local node = sidebar
      if not node then
        local editor_node = core.root_view:get_active_node_default()
        node = editor_node:split("right", explorer_view, { x = true }, true)
        rawset(_G, "_ag_sidebar_node", node)
      else
        node:add_view(explorer_view)
        node:set_active_view(explorer_view)
      end
      core.set_active_view(explorer_view)
      explorer_view.visible = true
    end
    core.redraw = true
  end,

  ["mongodb_explorer:add-connection"] = function()
    core.command_view:enter("MongoDB Connection Name", {
      text = "Atlas / Localhost",
      submit = function(name)
        core.command_view:enter("MongoDB Connection URI (mongodb:// or mongodb+srv://)", {
          text = "mongodb://127.0.0.1:27017",
          submit = function(uri)
            local new_conn = {
              id = "conn_" .. tostring(system.get_time()):gsub("%.", ""),
              name = name ~= "" and name or parse_uri_alias(uri),
              uri = uri,
              default_db = "admin",
              status = "disconnected",
              version = "",
              error = nil,
              databases = {},
              expanded = false,
            }
            table.insert(store.connections, new_conn)
            store.save()
            core.log("[MongoDB] Added connection '%s'", new_conn.name)
            store.connect(new_conn)
          end
        })
      end
    })
  end,

  ["mongodb_explorer:refresh"] = function()
    local conn = get_selected_context()
    if conn and conn.status == "connected" then
      store.connect(conn, function()
        core.log("[MongoDB] Refreshed %s", conn.name)
      end)
    else
      for _, c in ipairs(store.connections) do
        if c.status == "connected" then store.connect(c) end
      end
      core.log("[MongoDB] Refreshed active connections")
    end
  end,

  ["mongodb_explorer:disconnect"] = function()
    local conn = get_selected_context()
    if conn then
      store.disconnect(conn)
    end
  end,

  ["mongodb_explorer:new-scratchpad"] = function()
    local conn, db, col = get_selected_context()
    if not conn then
      conn = store.connections[1]
    end
    if not conn then
      core.warn("[MongoDB] No MongoDB connection available.")
      return
    end

    local db_name = db or conn.default_db or "test"
    local col_name = col or "collection"

    local template = string.format([[// ============================================================================
// MongoDB Scratchpad
// Connection: %s (%s)
// Database:   %s
// Collection: %s
//
// Execute Query: Press 'Ctrl+Enter' or Command Palette: 'mongodb_explorer:execute-scratchpad'
// ============================================================================

db.getCollection(%s).find({}).limit(20);

// Example Aggregation Pipeline:
// db.getCollection(%s).aggregate([
//   { $match: {} },
//   { $group: { _id: "$status", total: { $sum: 1 } } },
//   { $sort: { total: -1 } }
// ]);
]], conn.name, mask_uri(conn.uri), db_name, col_name, json.stringify(col_name), json.stringify(col_name))

    open_virtual_doc("scratchpad.mongodb.js", template, "scratchpad.mongodb.js", {
      is_mongo_scratchpad = true,
      mongo_conn_id = conn.id,
      mongo_db = db_name,
      mongo_col = col_name,
    })
  end,

  ["mongodb_explorer:execute-scratchpad"] = function()
    local doc = core.active_view and core.active_view.doc
    if not doc then return end

    local code = doc:get_text(1, 1, #doc.lines, #doc.lines[#doc.lines])
    local conn = store.find_connection(doc.mongo_conn_id) or store.connections[1]
    if not conn then
      core.error("[MongoDB] Scratchpad has no active connection assigned.")
      return
    end

    local target_db = doc.mongo_db or "admin"
    core.log("[MongoDB] Running scratchpad on %s / %s...", conn.name, target_db)

    local clean_code = preprocess_mongo_script(code)

    local exec_body = string.format([[
const __targetDb = %s;
if (__targetDb && typeof db !== 'undefined' && db.getSiblingDB) {
  db = db.getSiblingDB(__targetDb);
}
%s
]], json.stringify(target_db), clean_code)

    run_mongo_cli(conn.uri, exec_body, function(result, err)
      if err then
        core.error("[MongoDB] Scratchpad Error: %s", err)
        return
      end

      local formatted_json = json.stringify(result, true)
      local banner = ""
      local count = nil
      if type(result) == "table" and #result > 0 then
        count = #result
        banner = string.format([[// ============================================================================
// 📦 MongoDB Query Results (%d document%s) | Database: %s
// 🎨 Legend: Cyan=_id/IDs | Gold=Dates/Timestamps | Blue=Names/Entity | Purple=Meta
// ============================================================================
]], count, count == 1 and "" or "s", target_db)
      elseif type(result) == "table" and result.databases then
        banner = string.format([[// ============================================================================
// 📦 MongoDB Database List (%d databases) | Status: OK
// ============================================================================
]], #result.databases)
      end

      local full_content = banner .. formatted_json
      
      -- Open or update single reusable results.mongodb.json tab with full JSON syntax highlighting
      open_virtual_doc("results.mongodb.json", full_content, "results.mongodb.json", {
        is_mongo_results = true,
        mongo_conn_id = conn.id,
        mongo_db = target_db,
      })
      core.log("[MongoDB] Scratchpad query executed -> Results displayed in results.mongodb.json")
    end)
  end,

  ["mongodb_explorer:view-documents"] = function()
    local conn, db, col = get_selected_context()
    if not conn or not db or not col then
      core.warn("[MongoDB] Please select a collection first.")
      return
    end

    local limit = config.plugins.mongodb_explorer.page_size or 20
    local find_js = string.format([[
      const targetDb = db.getSiblingDB(%s);
      const docs = targetDb.getCollection(%s).find({}).limit(%d).toArray();
      const total = targetDb.getCollection(%s).estimatedDocumentCount();
      return { total: total, limit: %d, docs: docs };
    ]], json.stringify(db), json.stringify(col), limit, json.stringify(col), limit)

    core.log("[MongoDB] Fetching documents from %s.%s...", db, col)
    run_mongo_cli(conn.uri, find_js, function(data, err)
      if err then
        core.error("[MongoDB] Failed to fetch documents: %s", err)
        return
      end

      local docs = (data and data.docs) or data or {}
      local formatted_json = json.stringify(docs, true)
      local total = (data and data.total) or #docs
      local banner = string.format([[// ============================================================================
// 📄 Collection: %s.%s (%d document%s shown | %s total)
// 🎨 Legend: Cyan=_id/IDs | Gold=Dates/Timestamps | Blue=Names/Entity | Purple=Meta
// ============================================================================
]], db, col, #docs, #docs == 1 and "" or "s", tostring(total))

      local full_content = banner .. formatted_json
      local filename = string.format("%s_%s_documents.json", db, col)

      open_virtual_doc(filename, full_content, filename, {
        is_mongo_doc_viewer = true,
        mongo_conn_id = conn.id,
        mongo_db = db,
        mongo_col = col,
      })
      core.log("[MongoDB] Loaded %d documents from %s.%s", #docs, db, col)
    end)
  end,

  ["mongodb_explorer:insert-document"] = function()
    local conn, db, col = get_selected_context()
    if not conn or not db or not col then
      core.warn("[MongoDB] Please select a collection to insert into.")
      return
    end

    local template = json.stringify({
      title = "New Document",
      createdAt = { ["$date"] = "2026-08-06T12:00:00Z" },
      active = true,
      tags = { "sample", "mongo" }
    }, true)

    local filename = string.format("insert_%s_%s.json", db, col)
    open_virtual_doc(filename, template, filename, {
      is_mongo_insert_doc = true,
      mongo_conn_id = conn.id,
      mongo_db = db,
      mongo_col = col,
    })
  end,

  ["mongodb_explorer:save-document"] = function()
    local doc = core.active_view and core.active_view.doc
    if not doc then return end

    if doc.is_mongo_insert_doc then
      local text = doc:get_text(1, 1, #doc.lines, #doc.lines[#doc.lines])
      local parsed, parse_err = json.parse(text)
      if not parsed then
        core.error("[MongoDB] JSON syntax error: %s", parse_err)
        return
      end

      local conn = store.find_connection(doc.mongo_conn_id)
      if not conn then return end

      local insert_js = string.format([[
        const targetDb = db.getSiblingDB(%s);
        const rawDoc = %s;
        const doc = (typeof EJSON !== 'undefined' && EJSON.deserialize) ? EJSON.deserialize(rawDoc) : rawDoc;
        const res = targetDb.getCollection(%s).insertOne(doc);
        return res;
      ]], json.stringify(doc.mongo_db), json.stringify(parsed), json.stringify(doc.mongo_col))

      run_mongo_cli(conn.uri, insert_js, function(res, err)
        if err then
          core.error("[MongoDB] Insert failed: %s", err)
        else
          core.log("[MongoDB] Document successfully inserted into %s.%s", doc.mongo_db, doc.mongo_col)
          doc:clean()
        end
      end)
    elseif doc.is_mongo_doc_editor then
      local text = doc:get_text(1, 1, #doc.lines, #doc.lines[#doc.lines])
      local parsed, parse_err = json.parse(text)
      if not parsed then
        core.error("[MongoDB] JSON syntax error: %s", parse_err)
        return
      end

      local conn = store.find_connection(doc.mongo_conn_id)
      if not conn then return end

      local replace_js = string.format([[
        const targetDb = db.getSiblingDB(%s);
        const rawDoc = %s;
        const doc = (typeof EJSON !== 'undefined' && EJSON.deserialize) ? EJSON.deserialize(rawDoc) : rawDoc;
        const res = targetDb.getCollection(%s).replaceOne({ _id: doc._id }, doc, { upsert: true });
        return res;
      ]], json.stringify(doc.mongo_db), json.stringify(parsed), json.stringify(doc.mongo_col))

      run_mongo_cli(conn.uri, replace_js, function(res, err)
        if err then
          core.error("[MongoDB] Update document failed: %s", err)
        else
          core.log("[MongoDB] Document updated in %s.%s", doc.mongo_db, doc.mongo_col)
          doc:clean()
        end
      end)
    elseif doc.is_mongo_doc_viewer then
      core.log("[MongoDB] To modify individual documents, double click them in the explorer tree or use Scratchpad.")
    end
  end,

  ["mongodb_explorer:open-document-editor"] = function()
    local sel = store.selected_node
    if not sel or sel.type ~= "document" then return end
    local doc_data = sel.data
    local conn = sel.parent_conn
    local db = sel.parent_db.name
    local col = sel.parent_col.name

    local formatted = json.stringify(doc_data, true)
    local doc_id = doc_data._id
    local id_str = type(doc_id) == "table" and (doc_id["$oid"] or json.stringify(doc_id)) or tostring(doc_id)
    local clean_id = tostring(id_str):gsub("[^%w_-]", ""):sub(1, 16)
    local filename = string.format("%s_%s_%s.json", db, col, clean_id ~= "" and clean_id or "doc")

    open_virtual_doc(filename, formatted, filename, {
      is_mongo_doc_editor = true,
      mongo_conn_id = conn.id,
      mongo_db = db,
      mongo_col = col,
      mongo_doc_id = doc_id,
    })
  end,

  ["mongodb_explorer:toggle-connect"] = function()
    local conn = get_selected_context()
    if conn then
      if conn.status == "connected" then
        store.disconnect(conn)
      else
        store.connect(conn)
      end
    end
  end,

  ["mongodb_explorer:remove-connection"] = function()
    local conn = get_selected_context()
    if not conn then return end
    core.command_view:enter(string.format("Type 'yes' to remove saved connection '%s'", conn.name), {
      submit = function(confirm)
        if confirm:lower() ~= "yes" then return end
        for idx, c in ipairs(store.connections) do
          if c == conn or c.id == conn.id then
            table.remove(store.connections, idx)
            break
          end
        end
        store.save()
        core.log("[MongoDB] Removed connection '%s'", conn.name)
        core.redraw = true
      end
    })
  end,

  ["mongodb_explorer:clear-collection"] = function()
    local conn, db, col = get_selected_context()
    if not conn or not db or not col then
      core.warn("[MongoDB] Please select a collection to clear.")
      return
    end

    core.command_view:enter(string.format("Type 'yes' to delete ALL documents from collection '%s.%s'", db, col), {
      submit = function(confirm)
        if confirm:lower() ~= "yes" then
          core.log("[MongoDB] Clear collection cancelled.")
          return
        end

        local clear_js = string.format([[
          const targetDb = db.getSiblingDB(%s);
          const res = targetDb.getCollection(%s).deleteMany({});
          return { deletedCount: res.deletedCount || 0 };
        ]], json.stringify(db), json.stringify(col))

        core.log("[MongoDB] Deleting all records in %s.%s...", db, col)
        run_mongo_cli(conn.uri, clear_js, function(res, err)
          if err then
            core.error("[MongoDB] Failed to clear collection: %s", err)
          else
            local count = res and res.deletedCount or 0
            core.log("[MongoDB] Cleared collection %s.%s (deleted %d documents)", db, col, count)
            command.perform("mongodb_explorer:refresh")
          end
        end)
      end
    })
  end,

  ["mongodb_explorer:delete-all-documents"] = function()
    command.perform("mongodb_explorer:clear-collection")
  end,

  ["mongodb_explorer:delete-document"] = function()
    local sel = store.selected_node
    local conn, db, col = nil, nil, nil
    local doc_id = nil

    if sel and sel.type == "document" then
      conn = sel.parent_conn
      db = sel.parent_db.name
      col = sel.parent_col.name
      doc_id = sel.data and sel.data._id
    else
      local active_doc = core.active_view and core.active_view.doc
      if active_doc and active_doc.is_mongo_doc_editor then
        conn = store.find_connection(active_doc.mongo_conn_id)
        db = active_doc.mongo_db
        col = active_doc.mongo_col
        doc_id = active_doc.mongo_doc_id
      end
    end

    if not conn or not db or not col or doc_id == nil then
      core.warn("[MongoDB] Please select a document in the explorer or open a document editor to delete.")
      return
    end

    local id_display = type(doc_id) == "table" and (doc_id["$oid"] or json.stringify(doc_id)) or tostring(doc_id)

    core.command_view:enter(string.format("Type 'yes' to delete record {_id: %s} from %s.%s", id_display, db, col), {
      submit = function(confirm)
        if confirm:lower() ~= "yes" then
          core.log("[MongoDB] Delete record cancelled.")
          return
        end

        local del_js = string.format([[
          const targetDb = db.getSiblingDB(%s);
          const rawId = %s;
          let filterId = rawId;
          if (typeof rawId === 'string' && /^[0-9a-fA-F]{24}$/.test(rawId)) {
            try { filterId = ObjectId(rawId); } catch(e) {}
          } else if (typeof rawId === 'object' && rawId['$oid']) {
            try { filterId = ObjectId(rawId['$oid']); } catch(e) {}
          }
          const res = targetDb.getCollection(%s).deleteOne({ _id: filterId });
          return { deletedCount: res.deletedCount || 0 };
        ]], json.stringify(db), json.stringify(doc_id), json.stringify(col))

        run_mongo_cli(conn.uri, del_js, function(res, err)
          if err then
            core.error("[MongoDB] Delete record error: %s", err)
          else
            core.log("[MongoDB] Deleted record {_id: %s} from %s.%s", id_display, db, col)
            command.perform("mongodb_explorer:refresh")
          end
        end)
      end
    })
  end,

  ["mongodb_explorer:copy-document-json"] = function()
    local sel = store.selected_node
    if not sel or sel.type ~= "document" then return end
    local formatted = json.stringify(sel.data, true)
    system.set_clipboard(formatted)
    core.log("[MongoDB] Copied document JSON to clipboard.")
  end,

  ["mongodb_explorer:create-collection"] = function()
    local conn, db = get_selected_context()
    if not conn or not db then
      core.warn("[MongoDB] Please select a database first.")
      return
    end

    core.command_view:enter("New Collection Name", {
      submit = function(col_name)
        if col_name == "" then return end
        local create_js = string.format([[
          const targetDb = db.getSiblingDB(%s);
          targetDb.createCollection(%s);
          return { ok: 1 };
        ]], json.stringify(db), json.stringify(col_name))

        run_mongo_cli(conn.uri, create_js, function(res, err)
          if err then
            core.error("[MongoDB] Create collection failed: %s", err)
          else
            core.log("[MongoDB] Created collection '%s' in %s", col_name, db)
            command.perform("mongodb_explorer:refresh")
          end
        end)
      end
    })
  end,

  ["mongodb_explorer:drop-collection"] = function()
    local conn, db, col = get_selected_context()
    if not conn or not db or not col then
      core.warn("[MongoDB] Please select a collection to drop.")
      return
    end

    core.command_view:enter(string.format("Type 'yes' to confirm dropping collection '%s.%s'", db, col), {
      submit = function(confirm)
        if confirm:lower() ~= "yes" then
          core.log("[MongoDB] Drop collection cancelled.")
          return
        end

        local drop_js = string.format([[
          const targetDb = db.getSiblingDB(%s);
          return targetDb.getCollection(%s).drop();
        ]], json.stringify(db), json.stringify(col))

        run_mongo_cli(conn.uri, drop_js, function(res, err)
          if err then
            core.error("[MongoDB] Drop collection error: %s", err)
          else
            core.log("[MongoDB] Dropped collection %s.%s", db, col)
            command.perform("mongodb_explorer:refresh")
          end
        end)
      end
    })
  end,
})

-- ============================================================================
-- Auto-Stop Server on Lite XL Exit (Never Autostarts on Open)
-- ============================================================================
local old_core_quit = core.quit
function core.quit(force)
  if config.plugins.mongodb_explorer.autostop_on_exit ~= false then
    if store.server_status == "running" then
      pcall(function()
        local is_windows = (PLATFORM == "Windows" or os.getenv("OS") == "Windows_NT" or package.config:sub(1,1) == "\\")
        if is_windows then
          os.execute("net stop MongoDB >nul 2>&1")
          os.execute("powershell -Command \"Stop-Service MongoDB -ErrorAction SilentlyContinue\" >nul 2>&1")
          os.execute("taskkill /F /IM mongod.exe >nul 2>&1")
        else
          os.execute("sudo systemctl stop mongod >/dev/null 2>&1")
        end
      end)
    end
  end
  return old_core_quit(force)
end

-- ============================================================================
-- Keymap Bindings
-- ============================================================================
keymap.add({
  ["ctrl+alt+m"] = "mongodb_explorer:toggle",
  ["ctrl+return"] = "mongodb_explorer:execute-scratchpad",
})


-- ============================================================================
-- Context Menu Registrations for Right-Click Actions
-- ============================================================================
local ok_cm, menu = pcall(require, "plugins.contextmenu")
if ok_cm and menu and menu.register then
  local ok_core_cm, ContextMenu = pcall(require, "core.contextmenu")
  local DIVIDER = (ok_core_cm and ContextMenu.DIVIDER) or {}

  -- Database context menu
  menu:register(function(x, y)
    return store.selected_node and store.selected_node.type == "database"
  end, {
    { text = "+ Create Collection", command = "mongodb_explorer:create-collection" },
    { text = "⚡ Open Scratchpad", command = "mongodb_explorer:new-scratchpad" },
    DIVIDER,
    { text = "🔄 Refresh Database", command = "mongodb_explorer:refresh" },
  })

  -- Collection context menu
  menu:register(function(x, y)
    return store.selected_node and store.selected_node.type == "collection"
  end, {
    { text = "📄 View Documents", command = "mongodb_explorer:view-documents" },
    { text = "➕ Insert Document", command = "mongodb_explorer:insert-document" },
    { text = "⚡ Open Scratchpad", command = "mongodb_explorer:new-scratchpad" },
    DIVIDER,
    { text = "⚠️ Delete All Records (Clear)", command = "mongodb_explorer:clear-collection" },
    { text = "🗑 Drop Collection", command = "mongodb_explorer:drop-collection" },
  })

  -- Document / Record context menu
  menu:register(function(x, y)
    return store.selected_node and store.selected_node.type == "document"
  end, {
    { text = "✏️ Edit Record", command = "mongodb_explorer:open-document-editor" },
    { text = "🗑 Delete Record", command = "mongodb_explorer:delete-document" },
    DIVIDER,
    { text = "📋 Copy JSON", command = "mongodb_explorer:copy-document-json" },
  })

  -- Connection context menu
  menu:register(function(x, y)
    return store.selected_node and store.selected_node.type == "connection"
  end, {
    { text = "Connect / Disconnect", command = "mongodb_explorer:toggle-connect" },
    { text = "🔄 Refresh", command = "mongodb_explorer:refresh" },
    DIVIDER,
    { text = "➕ Add Connection", command = "mongodb_explorer:add-connection" },
    { text = "🗑 Remove Connection", command = "mongodb_explorer:remove-connection" },
  })
end

return {
  store = store,
  view = explorer_view,
  json = json,
  mask_uri = mask_uri,
  get_theme_palette = get_theme_palette,
}
