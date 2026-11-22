-- mod-version:3
-- Diagram Renderer for AI Project Visualizer
-- Handles all canvas drawing using Lite XL's renderer API.
-- Renders crisp, pixel-perfect orthogonal Manhattan channels,
-- solid scanline arrowheads, domain-styled architecture cards,
-- tab strip, interactive toolbar with zoom/fit/export controls, and responsive tooltips.

local DiagramRenderer = {}

local BASE_NODE_W = 230
local BASE_NODE_H = 84
local RAIL_W      = 210
local TAB_H       = 30
local TAB_PAD     = 14
local TOOLBAR_H   = 38
local STATUS_H    = 28

-- ─────────────────────────────────────────────────────────────────────────────
-- Color palette  (r, g, b, a) — all 0–255
-- ─────────────────────────────────────────────────────────────────────────────
local COLORS = {
  bg           = { 30,  30,  34, 255 },
  bg_dark      = { 20,  20,  24, 255 },
  bg_panel     = { 38,  38,  44, 255 },
  toolbar_bg   = { 26,  26,  30, 255 },
  tab_active   = { 65,  90, 160, 255 },
  tab_inactive = { 40,  40,  48, 255 },
  tab_hover    = { 55,  55,  70, 255 },
  tab_text     = { 210, 210, 220, 255 },
  status_bg    = { 18,  18,  22, 255 },
  status_text  = { 150, 160, 175, 255 },
  edge_default = { 100, 110, 130, 200 },
  edge_dashed  = {  90,  90, 110, 150 },
  edge_label   = { 160, 175, 195, 240 },
  node_default = {  65,  70,  85, 255 },
  node_hover   = {  85,  90, 110, 255 },
  node_border  = {  95, 105, 125, 200 },
  node_border_hover = { 160, 190, 255, 255 },
  node_border_ext   = { 140, 165, 225, 240 },
  node_text    = { 235, 240, 250, 255 },
  node_subtext = { 160, 175, 195, 220 },
  tooltip_bg   = {  22,  24,  32, 248 },
  tooltip_text = { 235, 240, 255, 255 },
  tooltip_sub  = { 170, 185, 205, 255 },
  tooltip_meta = { 120, 190, 255, 255 },
  error_bg     = {  75,  22,  22, 240 },
  error_text   = { 255, 120, 120, 255 },
  spinner      = {  90, 140, 240, 255 },
  empty_text   = { 110, 120, 135, 200 },
  btn_bg       = {  48,  52,  65, 255 },
  btn_hover    = {  75,  95, 135, 255 },
  btn_active   = {  95, 120, 175, 255 },
  btn_text     = { 200, 210, 225, 255 },
  separator    = {  45,  48,  56, 255 },

  -- Node Types (Domain-driven color palette)
  gateway      = {  35, 105, 190, 255 },
  gateway_h    = {  55, 135, 225, 255 },
  endpoint     = {  45, 115, 205, 255 },
  endpoint_h   = {  75, 145, 235, 255 },
  service      = {  30, 140, 160, 255 },
  service_h    = {  50, 170, 195, 255 },
  domain       = { 120,  60, 165, 255 },
  domain_h     = { 150,  85, 200, 255 },
  database     = {  45, 145,  75, 255 },
  database_h   = {  70, 175, 105, 255 },
  cache        = { 210, 130,  30, 255 },
  cache_h      = { 240, 155,  50, 255 },
  queue        = { 190,  55, 100, 255 },
  queue_h      = { 220,  80, 130, 255 },
  cloud        = {  70,  75, 175, 255 },
  cloud_h      = {  95, 105, 210, 255 },
  auth         = { 190,  50,  50, 255 },
  auth_h       = { 220,  75,  75, 255 },
  middleware   = { 185, 135,  25, 255 },
  middleware_h = { 215, 165,  55, 255 },
  storage      = {  80,  90, 105, 255 },
  storage_h    = { 105, 120, 140, 255 },
  component    = {  90,  70, 130, 255 },
  component_h  = { 115,  95, 160, 255 },
  config       = {  75,  80,  95, 255 },
  config_h     = { 100, 105, 125, 255 },
  ui           = { 190,  90,  35, 255 },
  ui_h         = { 220, 120,  60, 255 },

  -- Protocol Edge Colors
  edge_http    = {  75, 145, 235, 220 },
  edge_grpc    = {  45, 190, 195, 220 },
  edge_sql     = {  70, 185, 110, 220 },
  edge_cache   = { 235, 165,  55, 220 },
  edge_event   = { 235, 110,  60, 220 },
  edge_queue   = { 220,  80, 130, 220 },
  edge_auth    = { 225,  75,  75, 220 },
  edge_inject  = { 120, 130, 155, 180 },
}

local function node_color(ntype, hovered)
  ntype = (ntype or ""):lower()
  if     ntype == "gateway" or ntype == "ingress"       then return hovered and COLORS.gateway_h    or COLORS.gateway
  elseif ntype == "endpoint" or ntype == "api"         then return hovered and COLORS.endpoint_h   or COLORS.endpoint
  elseif ntype == "service" or ntype == "controller"   then return hovered and COLORS.service_h    or COLORS.service
  elseif ntype == "domain" or ntype == "entity" or ntype == "model" then return hovered and COLORS.domain_h or COLORS.domain
  elseif ntype == "database" or ntype == "db"          then return hovered and COLORS.database_h   or COLORS.database
  elseif ntype == "cache"                              then return hovered and COLORS.cache_h      or COLORS.cache
  elseif ntype == "queue" or ntype == "broker"         then return hovered and COLORS.queue_h      or COLORS.queue
  elseif ntype == "cloud" or ntype == "external"       then return hovered and COLORS.cloud_h      or COLORS.cloud
  elseif ntype == "auth" or ntype == "security"        then return hovered and COLORS.auth_h       or COLORS.auth
  elseif ntype == "middleware"                         then return hovered and COLORS.middleware_h or COLORS.middleware
  elseif ntype == "storage"                            then return hovered and COLORS.storage_h    or COLORS.storage
  elseif ntype == "component" or ntype == "module"     then return hovered and COLORS.component_h  or COLORS.component
  elseif ntype == "ui"                                 then return hovered and COLORS.ui_h         or COLORS.ui
  elseif ntype == "config"                             then return hovered and COLORS.config_h     or COLORS.config
  end
  return hovered and COLORS.node_hover or COLORS.node_default
end

local function edge_color(etype)
  etype = (etype or ""):lower()
  if     etype == "http" or etype == "rest"            then return COLORS.edge_http
  elseif etype == "grpc"                               then return COLORS.edge_grpc
  elseif etype == "sql" or etype == "db" or etype == "query" then return COLORS.edge_sql
  elseif etype == "cache"                              then return COLORS.edge_cache
  elseif etype == "event" or etype == "pubsub"         then return COLORS.edge_event
  elseif etype == "queue" or etype == "msg"            then return COLORS.edge_queue
  elseif etype == "auth"                               then return COLORS.edge_auth
  elseif etype == "inject" or etype == "imports"       then return COLORS.edge_inject
  end
  return COLORS.edge_default
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Helper to test if mouse is in rect
-- ─────────────────────────────────────────────────────────────────────────────
local function is_hovered(mx, my, rx, ry, rw, rh)
  if not mx or not my then return false end
  return mx >= rx and mx <= rx + rw and my >= ry and my <= ry + rh
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Coordinate transforms
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.world_to_screen(wx, wy, pan_x, pan_y, scale)
  return wx * scale + pan_x, wy * scale + pan_y
end

function DiagramRenderer.screen_to_world(sx, sy, pan_x, pan_y, scale)
  if scale == 0 then scale = 1 end
  return (sx - pan_x) / scale, (sy - pan_y) / scale
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Hit test: which node is under screen point (mx, my)?
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.node_at(nodes, mx, my, pan_x, pan_y, scale)
  if not nodes then return nil end
  for _, n in ipairs(nodes) do
    local sx, sy = DiagramRenderer.world_to_screen(n.x, n.y, pan_x, pan_y, scale)
    local sw = (n.w or BASE_NODE_W) * scale
    local sh = (n.h or BASE_NODE_H) * scale
    if mx >= sx and mx <= sx + sw and my >= sy and my <= sy + sh then
      return n
    end
  end
  return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw a filled rectangle (safe wrapper)
-- ─────────────────────────────────────────────────────────────────────────────

DiagramRenderer.BASE_NODE_W = BASE_NODE_W
DiagramRenderer.BASE_NODE_H = BASE_NODE_H

function DiagramRenderer.set_dimensions(w, h)
  if w then
    BASE_NODE_W = math.max(140, math.min(360, math.floor(w)))
    DiagramRenderer.BASE_NODE_W = BASE_NODE_W
  end
  if h then
    BASE_NODE_H = math.max(48, math.min(140, math.floor(h)))
    DiagramRenderer.BASE_NODE_H = BASE_NODE_H
  end
end

local function draw_rect(x, y, w, h, color)
  if w <= 0 or h <= 0 then return end
  renderer.draw_rect(math.floor(x), math.floor(y), math.ceil(w), math.ceil(h), color)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Pixel-Perfect Orthogonal Line Primitives
-- Zero diagonal stepping, 100% razor-sharp horizontal & vertical segments
-- ─────────────────────────────────────────────────────────────────────────────
local function draw_h_seg(x1, x2, y, thickness, color, dashed)
  thickness = math.max(1, math.floor(thickness or 1))
  local min_x = math.min(x1, x2)
  local max_x = math.max(x1, x2)
  local span = max_x - min_x
  if span <= 0 then return end

  if not dashed then
    draw_rect(min_x, y - math.floor(thickness / 2), span, thickness, color)
  else
    local dash_len = 6
    local gap_len  = 4
    local cur_x    = min_x
    while cur_x < max_x do
      local cur_w = math.min(dash_len, max_x - cur_x)
      draw_rect(cur_x, y - math.floor(thickness / 2), cur_w, thickness, color)
      cur_x = cur_x + dash_len + gap_len
    end
  end
end

local function draw_v_seg(y1, y2, x, thickness, color, dashed)
  thickness = math.max(1, math.floor(thickness or 1))
  local min_y = math.min(y1, y2)
  local max_y = math.max(y1, y2)
  local span = max_y - min_y
  if span <= 0 then return end

  if not dashed then
    draw_rect(x - math.floor(thickness / 2), min_y, thickness, span, color)
  else
    local dash_len = 6
    local gap_len  = 4
    local cur_y    = min_y
    while cur_y < max_y do
      local cur_h = math.min(dash_len, max_y - cur_y)
      draw_rect(x - math.floor(thickness / 2), cur_y, thickness, cur_h, color)
      cur_y = cur_y + dash_len + gap_len
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Solid Scanline Arrowhead Rasterization
-- ─────────────────────────────────────────────────────────────────────────────
local function draw_arrow_down(cx, cy, color, size)
  size = math.max(4, size or 6)
  for dy = 0, size do
    local y = cy - dy
    local half_w = math.floor(dy * 0.8)
    draw_rect(cx - half_w, y, half_w * 2 + 1, 1, color)
  end
end

local function draw_arrow_up(cx, cy, color, size)
  size = math.max(4, size or 6)
  for dy = 0, size do
    local y = cy + dy
    local half_w = math.floor(dy * 0.8)
    draw_rect(cx - half_w, y, half_w * 2 + 1, 1, color)
  end
end

-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- Universal Clean Display Text Sanitizer (UTF-8 to Clean ASCII)
-- Eliminates FreeType missing-glyph fallback '?' characters in Lite XL
-- ─────────────────────────────────────────────────────────────────────────────
local UTF8_REPLACEMENTS = {
  -- Quotes & Apostrophes
  { "\226\128\156", '"' },    -- “
  { "\226\128\157", '"' },    -- ”
  { "\226\128\158", '"' },    -- „
  { "\194\171", '"' },        -- «
  { "\194\187", '"' },        -- »
  { "\226\128\152", "'" },    -- ‘
  { "\226\128\153", "'" },    -- ’
  { "\226\128\154", "'" },    -- ‚
  { "\226\128\178", "'" },    -- ′
  { "\194\180", "'" },        -- ´
  { "\226\128\185", "'" },    -- ‹
  { "\226\128\186", "'" },    -- ›
  -- Dashes & Hyphens
  { "\226\128\147", "-" },    -- – en dash
  { "\226\136\146", "-" },    -- − minus sign
  { "\226\128\144", "-" },    -- ‐ hyphen
  { "\226\128\145", "-" },    -- ‑ non-breaking hyphen
  -- Ellipsis
  { "\226\128\166", "..." },  -- …
  -- Arrows
  { "\226\134\146", "->" },   -- →
  { "\226\134\144", "<-" },   -- ←
  { "\226\134\148", "<->" },  -- ↔
  { "\226\135\146", "=>" },   -- ⇒
  { "\226\135\144", "<=" },   -- ⇐
  { "\226\135\148", "<=>" },  -- <=>
  { "\226\158\148", "->" },   -- ➔
  { "\226\158\156", "->" },   -- ➜
  { "\226\158\164", "->" },   -- ➤
  { "\226\150\186", ">" },    -- ►
  { "\226\151\132", "<" },    -- ◄
  { "\226\150\178", "^" },    -- ▲
  { "\226\150\188", "v" },    -- ▼
  { "\226\134\145", "^" },    -- ↑
  { "\226\134\147", "v" },    -- ↓
  { "\226\134\152", "\\" },   -- ↘
  { "\226\134\151", "/" },    -- ↗
  -- Bullets & Dots
  { "\226\128\162", "*" },    -- •
  { "\194\183", "*" },        -- ·
  { "\226\151\166", "*" },    -- ◦
  { "\226\151\143", "*" },    -- ●
  { "\226\151\139", "*" },    -- ○
  { "\226\150\170", "*" },    -- ▪
  { "\226\150\171", "*" },    -- ▫
  { "\226\150\160", "*" },    -- ■
  { "\226\150\161", "*" },    -- □
  { "\226\151\134", "*" },    -- ◆
  { "\226\151\135", "*" },    -- ◇
  { "\226\128\163", ">" },    -- ‣
  -- Checks & Crosses
  { "\226\156\147", "[OK]" }, -- ✓
  { "\226\156\148", "[OK]" }, -- ✔
  { "\226\156\133", "[OK]" }, -- ✅
  { "\226\156\151", "[X]" },  -- ✗
  { "\226\156\152", "[X]" },  -- ✘
  { "\226\156\149", "[X]" },  -- ✕
  { "\226\156\150", "[X]" },  -- ✖
  { "\226\157\140", "[X]" },  -- ❌
  -- Emojis & Common Icons
  { "\226\154\160\239\184\143", "[!]" }, -- ⚠️
  { "\226\154\160", "[!]" },             -- ⚠
  { "\226\157\151", "[!]" },             -- ❗
  { "\226\157\147", "[?]" },             -- ❓
  { "\240\159\146\161", "[*]" },         -- 💡
  { "\240\159\154\128", "[^]" },         -- 🚀
  { "\240\159\148\165", "[*]" },         -- 🔥
  { "\240\159\155\161\239\184\143", "[SEC]" }, -- 🛡️
  { "\240\159\155\161", "[SEC]" },             -- 🛡
  { "\226\154\161", "[*]" },             -- ⚡
  { "\240\159\148\146", "[SEC]" },       -- 🔒
  { "\240\159\148\145", "[KEY]" },       -- 🔑
  { "\240\159\147\166", "[PKG]" },       -- 📦
  { "\240\159\147\129", "[DIR]" },       -- 📁
  { "\240\159\147\132", "[DOC]" },       -- 📄
  { "\240\159\148\141", "[FIND]" },      -- 🔍
  { "\240\159\142\175", "[*]" },         -- 🎯
  { "\226\173\144", "[*]" },             -- ⭐
  { "\226\132\185\239\184\143", "[i]" }, -- ℹ️
  { "\226\132\185", "[i]" },             -- ℹ
  { "\226\154\153\239\184\143", "[CFG]" }, -- ⚙️
  { "\226\154\153", "[CFG]" },             -- ⚙
  { "\240\159\148\167", "[TOOL]" },      -- 🔧
  { "\240\159\147\138", "[STAT]" },      -- 📊
  { "\240\159\147\136", "[UP]" },        -- 📈
  { "\240\159\147\137", "[DOWN]" },      -- 📉
  -- Math & Comparisons
  { "\226\137\165", ">=" },   -- ≥
  { "\226\137\164", "<=" },   -- ≤
  { "\226\137\160", "!=" },   -- ≠
  { "\226\137\136", "~=" },   -- ≈
  { "\195\151", "x" },        -- ×
  { "\195\183", "/" },        -- ÷
  { "\194\177", "+/-" },      -- ±
  { "\194\176", " deg" },     -- °
  { "\194\181", "u" },        -- µ
  -- Whitespace & Invisible Characters
  { "\194\160", " " },        -- \u00a0 NBSP
  { "\226\128\137", " " },    -- \u2009 thin space
  { "\226\128\139", "" },     -- \u200b zero-width space
  { "\226\128\175", " " },    -- \u202f narrow NBSP
  { "\239\187\191", "" },     -- \ufeff BOM
  -- Box Drawing
  { "\226\148\128", "-" },    -- ─
  { "\226\148\129", "-" },    -- ━
  { "\226\148\130", "|" },    -- │
  { "\226\148\131", "|" },    -- ┃
  { "\226\148\140", "+" },    -- ┌
  { "\226\148\144", "+" },    -- ┐
  { "\226\148\148", "+" },    -- └
  { "\226\148\152", "+" },    -- ┘
  { "\226\148\156", "+" },    -- ├
  { "\226\148\164", "+" },    -- ┤
  { "\226\148\172", "+" },    -- ┬
  { "\226\148\180", "+" },    -- ┴
  { "\226\148\188", "+" },    -- ┼
  -- Accented Latin Characters
  { "\195\169", "e" }, { "\195\168", "e" }, { "\195\170", "e" }, { "\195\171", "e" },
  { "\195\160", "a" }, { "\195\161", "a" }, { "\195\162", "a" }, { "\195\163", "a" }, { "\195\164", "a" },
  { "\195\172", "i" }, { "\195\173", "i" }, { "\195\174", "i" }, { "\195\175", "i" },
  { "\195\178", "o" }, { "\195\179", "o" }, { "\195\180", "o" }, { "\195\181", "o" }, { "\195\182", "o" },
  { "\195\185", "u" }, { "\195\186", "u" }, { "\195\187", "u" }, { "\195\188", "u" },
  { "\195\177", "n" }, { "\195\167", "c" },
  { "\195\137", "E" }, { "\195\136", "E" }, { "\195\128", "A" }, { "\195\129", "A" },
  { "\195\147", "O" }, { "\195\154", "U" }, { "\195\145", "N" }, { "\195\135", "C" },
}

local function clean_display_text(s)
  if not s or s == "" then return "" end
  s = tostring(s)

  -- Fast path: if 100% ASCII (all byte values <= 127), return immediately
  local has_non_ascii = false
  for i = 1, #s do
    if s:byte(i) > 127 then
      has_non_ascii = true
      break
    end
  end
  if not has_non_ascii then return s end

  -- Dashes with surrounding whitespace
  s = s:gsub("%s*\226\128\148%s*", " - ") -- em dash
  s = s:gsub("%s*\226\128\149%s*", " - ") -- horizontal bar

  -- Deterministic multi-byte replacements
  for _, pair in ipairs(UTF8_REPLACEMENTS) do
    s = s:gsub(pair[1], pair[2])
  end

  -- Catch-all for any remaining multi-byte sequences or non-ASCII bytes
  s = s:gsub("[\194-\223][\128-\191]", " ")
  s = s:gsub("[\224-\239][\128-\191][\128-\191]", " ")
  s = s:gsub("[\240-\244][\128-\191][\128-\191][\128-\191]", " ")
  s = s:gsub("[\128-\255]", " ")

  return s
end

DiagramRenderer.clean_display_text = clean_display_text

-- Truncate a string to max_width with ellipsis
-- ─────────────────────────────────────────────────────────────────────────────
local function truncate(s, font, max_width)
  if not s then return "" end
  s = clean_display_text(s)
  local w = font:get_width(s)
  if w <= max_width then return s end
  local ellipsis = "..."
  local ew = font:get_width(ellipsis)
  local result = ""
  for i = 1, #s do
    local part = s:sub(1, i)
    if font:get_width(part) + ew > max_width then
      return result .. ellipsis
    end
    result = part
  end
  return result .. ellipsis
end

-- Helper for wrapping text into multiple lines with paragraph awareness
local function wrap_insight_text(str, font, max_w)
  if not str or str == "" then return {} end
  str = clean_display_text(str)
  local out = {}
  for para in (str .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    if para:match("^%s*$") then
      table.insert(out, "")
    else
      local words = {}
      for w in para:gmatch("%S+") do table.insert(words, w) end
      local cur = ""
      for _, w in ipairs(words) do
        local test_line = (cur == "") and w or (cur .. " " .. w)
        if font:get_width(test_line) <= max_w then
          cur = test_line
        else
          if cur ~= "" then
            table.insert(out, cur)
          end
          cur = w
        end
      end
      if cur ~= "" then
        table.insert(out, cur)
      end
    end
  end
  while #out > 0 and out[#out] == "" do
    table.remove(out)
  end
  return out
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw all edges using Orthogonal Manhattan Channel Routing
-- ─────────────────────────────────────────────────────────────────────────────
local function draw_edges(nodes, edges, pan_x, pan_y, scale, hovered_node, font_small, search_matches, view)
  if not edges then return end

  local node_map = {}
  local node_screen_boxes = {}
  if nodes then
    for _, n in ipairs(nodes) do
      node_map[n.id] = n
      local nsx, nsy = DiagramRenderer.world_to_screen(n.x or 0, n.y or 0, pan_x, pan_y, scale)
      local nsw = (n.w or BASE_NODE_W) * scale
      local nsh = (n.h or BASE_NODE_H) * scale
      table.insert(node_screen_boxes, {
        x1 = nsx - 2,
        y1 = nsy - 2,
        x2 = nsx + nsw + 2,
        y2 = nsy + nsh + 2
      })
    end
  end

  local is_focus = (hovered_node ~= nil)
  local conn_roles = {}
  if is_focus then
    for idx, e in ipairs(edges) do
      if e.to == hovered_node.id then
        conn_roles[idx] = "inbound"
      elseif e.from == hovered_node.id then
        conn_roles[idx] = "outbound"
      end
    end
  end

  local has_search = (search_matches and #search_matches > 0)
  local search_match_set = {}
  if has_search then
    for _, m in ipairs(search_matches) do
      if m.node and m.node.id then
        search_match_set[m.node.id] = true
      end
    end
  end

  local impact = view and view.impact_data
  local is_story = view and view.story_mode
  local story_curr_id, story_prev_id
  if is_story and view.story_tours and view.story_tours[view.story_tour_idx] then
    local steps = view.story_tours[view.story_tour_idx].steps
    local s_idx = view.story_step_idx or 1
    story_curr_id = steps[s_idx] and steps[s_idx].node_id
    story_prev_id = (s_idx > 1 and steps[s_idx - 1]) and steps[s_idx - 1].node_id
  end

  local arrow_size = math.max(4, math.floor(6 * math.min(scale, 1.4)))
  local candidate_labels = {}
  local stagger_factors  = { 0.50, 0.35, 0.65, 0.22, 0.78 }

  for idx, e in ipairs(edges) do
    local src = node_map[e.from]
    local dst = node_map[e.to]
    if src and dst then
      local elabel = clean_display_text(e.label or "")
      local sw = (src.w or BASE_NODE_W)
      local sh = (src.h or BASE_NODE_H)
      local dw = (dst.w or BASE_NODE_W)
      local dh = (dst.h or BASE_NODE_H)

      local p_sx = e.src_x or (src.x + sw / 2)
      local p_sy = e.src_y or (src.y + sh)
      local p_dx = e.dst_x or (dst.x + dw / 2)
      local p_dy = e.dst_y or dst.y

      local ssx, ssy = DiagramRenderer.world_to_screen(p_sx, p_sy, pan_x, pan_y, scale)
      local sdx, sdy = DiagramRenderer.world_to_screen(p_dx, p_dy, pan_x, pan_y, scale)

      local src_sx, src_sy = DiagramRenderer.world_to_screen(src.x, src.y, pan_x, pan_y, scale)
      local src_sw = sw * scale
      local dst_sx, dst_sy = DiagramRenderer.world_to_screen(dst.x, dst.y, pan_x, pan_y, scale)
      local dst_sw = dw * scale
      local dst_sh = dh * scale

      local role = conn_roles[idx]
      local is_dashed = (e.reversed == true)
      local is_search_edge = has_search and search_match_set[e.from] and search_match_set[e.to]
      local is_story_edge = is_story and (e.from == story_prev_id and e.to == story_curr_id)

      local is_impact_in  = impact and (e.to == impact.target)
      local is_impact_out = impact and (e.from == impact.target)

      local flow = view and view.flow_trace
      local is_flow_edge = false
      if flow and flow.edge_set then
        local ek1 = (e.from or "") .. "->" .. (e.to or "")
        local ek2 = (e.to or "") .. "->" .. (e.from or "")
        is_flow_edge = (flow.edge_set[ek1] == true or flow.edge_set[ek2] == true)
      end

      local line_thickness = math.max(1, math.floor(1.5 * math.min(scale, 1.3)))
      local glow_thickness = line_thickness + 3
      local primary_col
      local glow_col = nil
      local is_dimmed = false

      if flow and not is_flow_edge then
        is_dimmed = true
        primary_col = { 40, 45, 55, 30 }
        line_thickness = 1
      elseif is_flow_edge then
        glow_col = { 6, 182, 212, 140 }
        primary_col = { 34, 211, 238, 255 }
        line_thickness = line_thickness + 2
      elseif is_story and not is_story_edge and not is_focus then
        is_dimmed = true
        primary_col = { 45, 50, 62, 35 }
        line_thickness = 1
      elseif is_story_edge then
        glow_col = { 250, 204, 21, 120 }
        primary_col = { 255, 215, 0, 255 }
        line_thickness = line_thickness + 2
      elseif impact and not is_impact_in and not is_impact_out and not is_focus then
        is_dimmed = true
        primary_col = { 45, 50, 62, 35 }
        line_thickness = 1
      elseif is_impact_in then
        glow_col = { 249, 115, 22, 110 }
        primary_col = { 249, 115, 22, 255 }
        line_thickness = line_thickness + 1
      elseif is_impact_out then
        glow_col = { 16, 185, 129, 110 }
        primary_col = { 16, 185, 129, 255 }
        line_thickness = line_thickness + 1
      elseif is_focus and not role then
        is_dimmed = true
        primary_col = { 50, 55, 68, 35 }
        line_thickness = 1
      elseif is_focus and role then
        glow_col    = role == "inbound" and { 70, 230, 180, 85 } or { 255, 195, 75, 85 }
        primary_col = role == "inbound" and { 90, 245, 195, 255 } or { 255, 210, 95, 255 }
        line_thickness = line_thickness + 1
      elseif has_search and not is_search_edge then
        is_dimmed = true
        primary_col = { 50, 55, 68, 35 }
        line_thickness = 1
      elseif has_search and is_search_edge then
        glow_col = { 56, 189, 248, 85 }
        primary_col = { 56, 189, 248, 255 }
        line_thickness = line_thickness + 1
      elseif view and view.ai_insight and view.ai_insight.nodes and next(view.ai_insight.nodes) then
        local is_insight_edge = (view.ai_insight.nodes[e.from] and view.ai_insight.nodes[e.to])
        if is_insight_edge then
          glow_col = { 168, 85, 247, 120 }
          primary_col = { 192, 132, 252, 255 }
          line_thickness = line_thickness + 1
        else
          is_dimmed = true
          primary_col = { 45, 50, 62, 35 }
          line_thickness = 1
        end
      elseif view and view.active_audit_finding then
        local af = view.active_audit_finding
        local is_audit_edge = false
        if af.offending_edge and af.offending_edge.from == e.from and af.offending_edge.to == e.to then
          is_audit_edge = true
        elseif af.cycle_edges then
          for _, ce in ipairs(af.cycle_edges) do
            if ce.from == e.from and ce.to == e.to then
              is_audit_edge = true
              break
            end
          end
        elseif af.nodes and #af.nodes > 1 then
          local has_from = false
          local has_to = false
          for _, nid in ipairs(af.nodes) do
            if nid == e.from then has_from = true end
            if nid == e.to then has_to = true end
          end
          if has_from and has_to then
            is_audit_edge = true
          end
        end

        if is_audit_edge then
          local sev = af.type or "warning"
          if sev == "critical" then
            glow_col = { 244, 63, 94, 140 }
            primary_col = { 251, 113, 133, 255 }
          elseif sev == "info" then
            glow_col = { 56, 189, 248, 120 }
            primary_col = { 125, 211, 252, 255 }
          else
            glow_col = { 245, 158, 11, 130 }
            primary_col = { 251, 191, 36, 255 }
          end
          line_thickness = line_thickness + 2
        else
          is_dimmed = true
          primary_col = { 45, 50, 62, 35 }
          line_thickness = 1
        end
      elseif view and view.heatmap_mode then
        local et = (e.type or ""):lower()
        local el = elabel:lower()
        local is_mut = et:match("sql") or et:match("db") or et:match("mutation") or et:match("write") or et:match("post") or et:match("insert") or et:match("delete") or et:match("put") or el:match("write") or el:match("mutat") or el:match("save") or el:match("insert") or el:match("delet")
        local is_rd = not is_mut and (et:match("cache") or et:match("query") or et:match("read") or et:match("get") or el:match("read") or el:match("fetch") or el:match("get") or el:match("quer"))
        if is_mut then
          glow_col = { 244, 63, 94, 90 }
          primary_col = { 244, 63, 94, 255 }
          line_thickness = line_thickness + 1
          is_dashed = false
        elseif is_rd then
          glow_col = { 56, 189, 248, 70 }
          primary_col = { 56, 189, 248, 230 }
          is_dashed = true
        else
          primary_col = edge_color(e.type)
        end
      else
        primary_col = is_dashed and COLORS.edge_dashed or edge_color(e.type)
      end

      local track_idx    = e.track_idx or 0
      local total_tracks = e.total_tracks or 1

      if dst.y > src.y + sh + 15 then
        -- Case A: Downward Highway Channel
        local ch_h = sdy - ssy
        local frac = (track_idx + 1) / (total_tracks + 1)
        local track_y = ssy + 12 * scale + frac * math.max(ch_h - 24 * scale, 10)

        if glow_col then
          draw_v_seg(ssy, track_y, ssx, glow_thickness, glow_col, false)
          draw_h_seg(ssx, sdx, track_y, glow_thickness, glow_col, false)
          draw_v_seg(track_y, sdy - arrow_size, sdx, glow_thickness, glow_col, false)
        end

        draw_v_seg(ssy, track_y, ssx, line_thickness, primary_col, is_dashed)
        draw_h_seg(ssx, sdx, track_y, line_thickness, primary_col, is_dashed)
        draw_v_seg(track_y, sdy - arrow_size, sdx, line_thickness, primary_col, is_dashed)

        if not is_dimmed then
          draw_arrow_down(sdx, sdy, primary_col, arrow_size)
        end

        if #elabel > 0 and font_small and not is_dimmed and scale >= 0.55 then
          local lw = font_small:get_width(elabel)
          local lh = font_small:get_height()
          local seg_w = math.abs(sdx - ssx)
          -- Length Guard: Only candidate if segment has room
          if (seg_w >= lw + 24 or is_focus) and (track_idx or 0) <= 3 then
            local s_frac = stagger_factors[((track_idx or 0) % #stagger_factors) + 1]
            local base_lx = ssx + (sdx - ssx) * s_frac
            local base_ly = track_y - lh / 2 - 2
            table.insert(candidate_labels, {
              e = e,
              label = elabel,
              base_lx = base_lx,
              base_ly = base_ly,
              lw = lw,
              lh = lh,
              role = role,
              is_focus = is_focus
            })
          end
        end

      elseif math.abs(dst.y - src.y) <= 20 then
        -- Case B: Intra-Row Drop Loop
        local track_y = ssy + 12 * scale + ((track_idx + 1) * 14 * scale)

        if glow_col then
          draw_v_seg(ssy, track_y, ssx, glow_thickness, glow_col, false)
          draw_h_seg(ssx, sdx, track_y, glow_thickness, glow_col, false)
          draw_v_seg(dst_sy + dst_sh + arrow_size, track_y, sdx, glow_thickness, glow_col, false)
        end

        draw_v_seg(ssy, track_y, ssx, line_thickness, primary_col, is_dashed)
        draw_h_seg(ssx, sdx, track_y, line_thickness, primary_col, is_dashed)
        draw_v_seg(dst_sy + dst_sh + arrow_size, track_y, sdx, line_thickness, primary_col, is_dashed)

        if not is_dimmed then
          draw_arrow_up(sdx, dst_sy + dst_sh, primary_col, arrow_size)
        end

        if #elabel > 0 and font_small and not is_dimmed and scale >= 0.55 then
          local lw = font_small:get_width(elabel)
          local lh = font_small:get_height()
          local seg_w = math.abs(sdx - ssx)
          if (seg_w >= lw + 24 or is_focus) and (track_idx or 0) <= 3 then
            local base_lx = (ssx + sdx) / 2
            local base_ly = track_y + 4
            table.insert(candidate_labels, {
              e = e,
              label = elabel,
              base_lx = base_lx,
              base_ly = base_ly,
              lw = lw,
              lh = lh,
              role = role,
              is_focus = is_focus
            })
          end
        end

      else
        -- Case C: Upward / Feedback Loop via Side Gutter
        local gutter_pad = (track_idx + 1) * 18 * scale
        local use_left = (ssx + sdx) / 2 < ((src_sx + dst_sx) / 2)
        local gutter_x = use_left and (math.min(src_sx, dst_sx) - gutter_pad)
                                  or  (math.max(src_sx + src_sw, dst_sx + dst_sw) + gutter_pad)
        local exit_y  = ssy + 8 * scale
        local enter_y = sdy - 12 * scale

        if glow_col then
          draw_v_seg(ssy, exit_y, ssx, glow_thickness, glow_col, false)
          draw_h_seg(ssx, gutter_x, exit_y, glow_thickness, glow_col, false)
          draw_v_seg(enter_y, exit_y, gutter_x, glow_thickness, glow_col, false)
          draw_h_seg(gutter_x, sdx, enter_y, glow_thickness, glow_col, false)
          draw_v_seg(enter_y, sdy - arrow_size, sdx, glow_thickness, glow_col, false)
        end

        draw_v_seg(ssy, exit_y, ssx, line_thickness, primary_col, is_dashed)
        draw_h_seg(ssx, gutter_x, exit_y, line_thickness, primary_col, is_dashed)
        draw_v_seg(enter_y, exit_y, gutter_x, line_thickness, primary_col, is_dashed)
        draw_h_seg(gutter_x, sdx, enter_y, line_thickness, primary_col, is_dashed)
        draw_v_seg(enter_y, sdy - arrow_size, sdx, line_thickness, primary_col, is_dashed)

        if not is_dimmed then
          draw_arrow_down(sdx, sdy, primary_col, arrow_size)
        end

        if #elabel > 0 and font_small and not is_dimmed and scale >= 0.5 then
          local base_lx = gutter_x + (use_left and 8 or -font_small:get_width(elabel) - 8)
          local base_ly = (exit_y + enter_y) / 2
          local lw = font_small:get_width(elabel)
          local lh = font_small:get_height()
          table.insert(candidate_labels, {
            e = e,
            label = elabel,
            base_lx = base_lx,
            base_ly = base_ly,
            lw = lw,
            lh = lh,
            role = role,
            is_focus = is_focus
          })
        end
      end
    end
  end

  -- Pass 2: AABB Edge Label Collision Resolver
  local placed_label_boxes = {}
  local function rects_overlap(r1, r2)
    return not (r1.x2 < r2.x1 or r1.x1 > r2.x2 or r1.y2 < r2.y1 or r1.y1 > r2.y2)
  end

  local candidate_shifts = {
    { 0, 0 },
    { 0, -14 * scale },
    { 0, 14 * scale },
    { 35 * scale, 0 },
    { -35 * scale, 0 },
    { 35 * scale, -14 * scale },
    { -35 * scale, 14 * scale },
    { 70 * scale, 0 },
    { -70 * scale, 0 },
    { 70 * scale, -14 * scale },
    { -70 * scale, 14 * scale },
    { 105 * scale, 0 },
    { -105 * scale, 0 },
    { 0, -28 * scale },
    { 0, 28 * scale }
  }

  for _, item in ipairs(candidate_labels) do
    local chosen_box = nil
    local final_lx   = item.base_lx
    local final_ly   = item.base_ly

    for _, shift in ipairs(candidate_shifts) do
      local test_lx = item.base_lx + shift[1]
      local test_ly = item.base_ly + shift[2]
      local test_box = {
        x1 = test_lx - item.lw / 2 - 4,
        y1 = test_ly - 2,
        x2 = test_lx + item.lw / 2 + 4,
        y2 = test_ly + item.lh + 2
      }

      local has_collision = false
      for _, pb in ipairs(placed_label_boxes) do
        if rects_overlap(test_box, pb) then
          has_collision = true
          break
        end
      end
      if not has_collision then
        for _, nb in ipairs(node_screen_boxes) do
          if rects_overlap(test_box, nb) then
            has_collision = true
            break
          end
        end
      end

      if not has_collision then
        chosen_box = test_box
        final_lx   = test_lx
        final_ly   = test_ly
        break
      end
    end

    if not chosen_box then
      if item.is_focus then
        chosen_box = {
          x1 = item.base_lx - item.lw / 2 - 4,
          y1 = item.base_ly - 2,
          x2 = item.base_lx + item.lw / 2 + 4,
          y2 = item.base_ly + item.lh + 2
        }
        final_lx = item.base_lx
        final_ly = item.base_ly
      end
    end

    if chosen_box then
      table.insert(placed_label_boxes, chosen_box)

    local e = item.e
    local role = item.role
    if item.is_focus and role then
      local badge_bg     = role == "inbound" and { 16, 42, 36, 245 } or { 48, 38, 14, 245 }
      local badge_border = role == "inbound" and { 70, 220, 170, 255 } or { 240, 185, 60, 255 }
      draw_rect(final_lx - item.lw / 2 - 4, final_ly - 2, item.lw + 8, item.lh + 4, badge_border)
      draw_rect(final_lx - item.lw / 2 - 3, final_ly - 1, item.lw + 6, item.lh + 2, badge_bg)
      renderer.draw_text(font_small, item.label or clean_display_text(e.label or ""), math.floor(final_lx - item.lw / 2), math.floor(final_ly), { 245, 250, 255, 255 })
    else
      draw_rect(final_lx - item.lw / 2 - 4, final_ly - 2, item.lw + 8, item.lh + 4, { 18, 18, 24, 230 })
      draw_rect(final_lx - item.lw / 2 - 4, final_ly - 2, item.lw + 8, 1, { 60, 75, 105, 180 })
      renderer.draw_text(font_small, item.label or clean_display_text(e.label or ""), math.floor(final_lx - item.lw / 2), math.floor(final_ly), COLORS.edge_label)
    end
    end -- end if chosen_box
  end
end
local function draw_nodes(nodes, edges, pan_x, pan_y, scale, hovered_node, font, font_small, search_matches, search_match_idx, view)
  if not nodes then return end

  local in_degree_map = {}
  if view and view.heatmap_mode and edges then
    for _, e in ipairs(edges) do
      if e.to then
        in_degree_map[e.to] = (in_degree_map[e.to] or 0) + 1
      end
    end
  end

  local is_focus = (hovered_node ~= nil)
  local callers = {}
  local deps = {}
  if is_focus and edges then
    for _, e in ipairs(edges) do
      if e.to == hovered_node.id then
        callers[e.from] = true
      elseif e.from == hovered_node.id then
        deps[e.to] = true
      end
    end
  end

  local has_search = (search_matches and #search_matches > 0)
  local match_map = {}
  local current_match_id = nil
  if has_search then
    for i, m in ipairs(search_matches) do
      if m.node and m.node.id then
        match_map[m.node.id] = i
      end
    end
    if search_match_idx and search_matches[search_match_idx] and search_matches[search_match_idx].node then
      current_match_id = search_matches[search_match_idx].node.id
    end
  end

  for _, n in ipairs(nodes) do
    local is_self    = (hovered_node and hovered_node.id == n.id)
    local is_caller  = is_focus and callers[n.id]
    local is_dep     = is_focus and deps[n.id]
    local is_related = is_self or is_caller or is_dep

    local match_idx     = match_map[n.id]
    local is_match      = (match_idx ~= nil)
    local is_curr_match = (n.id == current_match_id)

    local impact = view and view.impact_data
    local is_impact_target = impact and (impact.target == n.id)
    local impact_up_d      = impact and impact.upstream and impact.upstream[n.id]
    local impact_down_d    = impact and impact.downstream and impact.downstream[n.id]
    local is_in_impact     = is_impact_target or (impact_up_d ~= nil) or (impact_down_d ~= nil)

    local is_story = view and view.story_mode
    local is_story_curr = false
    if is_story and view.story_tours and view.story_tours[view.story_tour_idx] then
      local step = view.story_tours[view.story_tour_idx].steps[view.story_step_idx or 1]
      is_story_curr = (step and step.node_id == n.id)
    end

    local flow = view and view.flow_trace
    local is_in_flow = false
    local flow_hop_idx = nil
    if flow and flow.path_set and flow.path_set[n.id] then
      is_in_flow = true
      flow_hop_idx = flow.hop_indices and flow.hop_indices[n.id]
    end

    local is_dimmed  = false
    if flow then
      is_dimmed = not is_in_flow
    elseif is_focus then
      is_dimmed = not is_related
    elseif is_story then
      is_dimmed = not is_story_curr
    elseif impact then
      is_dimmed = not is_in_impact
    elseif has_search then
      is_dimmed = not is_match
    elseif view and view.ai_insight and view.ai_insight.nodes and next(view.ai_insight.nodes) then
      is_dimmed = not view.ai_insight.nodes[n.id]
    elseif view and view.active_audit_finding and view.active_audit_finding.nodes and #view.active_audit_finding.nodes > 0 then
      local in_audit = false
      for _, nid in ipairs(view.active_audit_finding.nodes) do
        if nid == n.id then in_audit = true; break end
      end
      is_dimmed = not in_audit
    end
    local is_ext       = (n.external == true)
    local is_file_real = false
    if n.file and n.file ~= "" and not is_ext then
      if view and view.is_file_real then
        is_file_real = view:is_file_real(n.file)
      elseif system.get_file_info(n.file) then
        is_file_real = true
      end
    end
    local is_suggested = (n.suggested == true or (is_ext and (not n.file or n.file == "")) or (not is_file_real))

    -- Toggle filter: render node only if suggestions are not hidden
    local should_render_node = not (view and view.show_suggested_nodes == false and is_suggested)
    if should_render_node then
    local sx, sy = DiagramRenderer.world_to_screen(n.x, n.y, pan_x, pan_y, scale)
    local sw = (n.w or BASE_NODE_W) * scale
    local sh = (n.h or BASE_NODE_H) * scale

    if sw >= 2 and sh >= 2 then
      if is_dimmed then
      local fill = node_color(n.type, false)
      local dim_fill   = { math.floor(fill[1]*0.25), math.floor(fill[2]*0.25), math.floor(fill[3]*0.25), 65 }
      local dim_border = { 45, 48, 58, 65 }
      local dim_text   = { 95, 100, 115, 65 }
      draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, dim_border)
      draw_rect(sx, sy, sw, sh, dim_fill)
      if sw > 25 and sh > 12 then
        local label = truncate(n.label or n.id, font, sw - 12)
        local tw = font:get_width(label)
        renderer.draw_text(font, label, math.floor(sx + (sw - tw) / 2), math.floor(sy + 8), dim_text)
      end
    else
      local fill_color = node_color(n.type, is_self)
      local border_color
      local top_accent

      if is_self then
        border_color = { 140, 215, 255, 255 }
        top_accent   = { 160, 230, 255, 255 }
      elseif view and view.ai_insight and view.ai_insight.nodes and view.ai_insight.nodes[n.id] then
        border_color = { 192, 132, 252, 255 }
        top_accent   = { 216, 180, 254, 255 }
      elseif view and view.active_audit_finding and view.active_audit_finding.nodes then
        local is_audit_node = false
        for _, nid in ipairs(view.active_audit_finding.nodes) do
          if nid == n.id then is_audit_node = true; break end
        end
        if is_audit_node then
          local sev = view.active_audit_finding.type or "warning"
          if sev == "critical" then
            border_color = { 244, 63, 94, 255 }
            top_accent   = { 254, 205, 211, 255 }
          elseif sev == "info" then
            border_color = { 56, 189, 248, 255 }
            top_accent   = { 186, 230, 253, 255 }
          else
            border_color = { 245, 158, 11, 255 }
            top_accent   = { 254, 240, 138, 255 }
          end
        else
          border_color = is_suggested and { 245, 158, 11, 240 } or (is_ext and COLORS.node_border_ext or COLORS.node_border)
          top_accent   = is_suggested and { 251, 191, 36, 255 } or (is_ext and { 220, 235, 255, 255 } or {
            math.min(fill_color[1] + 55, 255),
            math.min(fill_color[2] + 55, 255),
            math.min(fill_color[3] + 55, 255),
            255
          })
        end
      elseif is_caller and is_dep then
        border_color = { 180, 210, 255, 255 }
        top_accent   = { 180, 210, 255, 255 }
      elseif is_caller then
        border_color = { 70, 230, 180, 255 }
        top_accent   = { 70, 230, 180, 255 }
      elseif is_dep then
        border_color = { 255, 195, 75, 255 }
        top_accent   = { 255, 195, 75, 255 }
      else
        border_color = is_suggested and { 245, 158, 11, 240 } or (is_ext and COLORS.node_border_ext or COLORS.node_border)
        top_accent   = is_suggested and { 251, 191, 36, 255 } or (is_ext and { 220, 235, 255, 255 } or {
          math.min(fill_color[1] + 55, 255),
          math.min(fill_color[2] + 55, 255),
          math.min(fill_color[3] + 55, 255),
          255
        })
      end

      -- Drop Shadow
      draw_rect(sx + 3, sy + 3, sw, sh, { 0, 0, 0, 110 })

      -- Card Border
      if is_in_flow then
        draw_rect(sx - 3, sy - 3, sw + 6, sh + 6, { 6, 182, 212, 240 })
        draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, { 165, 243, 252, 255 })
      elseif is_story_curr then
        draw_rect(sx - 3, sy - 3, sw + 6, sh + 6, { 250, 204, 21, 240 })
        draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, { 254, 240, 138, 255 })
      elseif is_impact_target then
        draw_rect(sx - 3, sy - 3, sw + 6, sh + 6, { 244, 63, 94, 240 })
        draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, { 254, 205, 211, 255 })
      elseif impact_up_d then
        draw_rect(sx - 2, sy - 2, sw + 4, sh + 4, { 249, 115, 22, 230 })
        draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, { 254, 215, 170, 255 })
      elseif impact_down_d then
        draw_rect(sx - 2, sy - 2, sw + 4, sh + 4, { 16, 185, 129, 230 })
        draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, { 167, 243, 208, 255 })
      elseif is_curr_match then
        draw_rect(sx - 3, sy - 3, sw + 6, sh + 6, { 245, 158, 11, 230 })
        draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, { 254, 240, 138, 255 })
      elseif is_match then
        draw_rect(sx - 2, sy - 2, sw + 4, sh + 4, { 56, 189, 248, 220 })
        draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, { 186, 230, 253, 255 })
      elseif view and view.active_audit_finding and view.active_audit_finding.nodes then
        local is_audit_node = false
        for _, nid in ipairs(view.active_audit_finding.nodes) do
          if nid == n.id then is_audit_node = true; break end
        end
        if is_audit_node then
          local sev = view.active_audit_finding.type or "warning"
          local gcol = (sev == "critical") and { 244, 63, 94, 240 } or ((sev == "info") and { 56, 189, 248, 240 } or { 245, 158, 11, 240 })
          local icol = (sev == "critical") and { 254, 205, 211, 255 } or ((sev == "info") and { 186, 230, 253, 255 } or { 254, 240, 138, 255 })
          draw_rect(sx - 3, sy - 3, sw + 6, sh + 6, gcol)
          draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, icol)
        else
          draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, border_color)
        end
      elseif is_self or is_caller or is_dep then
        draw_rect(sx - 2, sy - 2, sw + 4, sh + 4, border_color)
      elseif view and view.heatmap_mode then
        local in_deg = in_degree_map[n.id] or 0
        if in_deg >= 3 then
          draw_rect(sx - 3, sy - 3, sw + 6, sh + 6, { 245, 158, 11, 230 })
          draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, { 254, 240, 138, 255 })
        elseif (n.type == "cloud" or n.type == "external" or (n.name and n.name:match("AWS|GCP|Azure|S3|Stripe|Cloud"))) then
          draw_rect(sx - 2, sy - 2, sw + 4, sh + 4, { 129, 140, 248, 220 })
          draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, { 199, 210, 254, 255 })
        else
          draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, { 16, 185, 129, 180 })
        end
      elseif is_suggested then
        -- Distinctive Dashed Border for AI Suggestions / Inferred Tools
        local dash_len = math.max(4, math.floor(7 * scale))
        local gap_len  = math.max(3, math.floor(4 * scale))
        local s_bdr    = { 245, 158, 11, 240 }
        local cur_x = sx - 1
        while cur_x < sx + sw + 1 do
          local d_w = math.min(dash_len, sx + sw + 1 - cur_x)
          draw_rect(cur_x, sy - 1, d_w, 2, s_bdr)
          draw_rect(cur_x, sy + sh - 1, d_w, 2, s_bdr)
          cur_x = cur_x + dash_len + gap_len
        end
        local cur_y = sy - 1
        while cur_y < sy + sh + 1 do
          local d_h = math.min(dash_len, sy + sh + 1 - cur_y)
          draw_rect(sx - 1, cur_y, 2, d_h, s_bdr)
          draw_rect(sx + sw - 1, cur_y, 2, d_h, s_bdr)
          cur_y = cur_y + dash_len + gap_len
        end
      else
        draw_rect(sx - 1, sy - 1, sw + 2, sh + 2, border_color)
      end

      -- Card Background Fill
      draw_rect(sx, sy, sw, sh, fill_color)

      -- 3px Architectural Top Accent Bar
      draw_rect(sx, sy, sw, math.max(2, math.floor(3 * scale)), top_accent)

      if sw > 25 and sh > 16 then
        -- ADAPTIVE ZERO-COLLISION CARD ARCHITECTURE (100% mathematical disjoint intervals)
        local fh = font_small:get_height()

        if sh < 38 then
          -- Tier 1-line mode: Single bold centered title
          local max_lbl_w = sw - 12
          local raw_label = (is_suggested and "* " or "") .. (n.label or n.id)
          local label = truncate(raw_label, font_small, max_lbl_w)
          local tw = font_small:get_width(label)
          local tx = sx + (sw - tw) / 2
          local ty = sy + (sh - fh) / 2
          renderer.draw_text(font_small, label, math.floor(tx), math.floor(ty), COLORS.node_text)

        elseif sh < 54 then
          -- Tier 2-line mode: Title on top, Tech Stack Pill on bottom (Guaranteed zero collision)
          local max_lbl_w = sw - 14
          local raw_label = (is_suggested and "* " or "") .. (n.label or n.id)
          local label = truncate(raw_label, font_small, max_lbl_w)
          local tw = font_small:get_width(label)
          local tx = sx + (sw - tw) / 2
          local ty = sy + (sh * 0.45 - fh) / 2 + 2
          renderer.draw_text(font_small, label, math.floor(tx), math.floor(ty), COLORS.node_text)

          local tech_str = n.tech and (#n.tech > 0) and n.tech or (n.type or "service")
          tech_str = truncate(tech_str, font_small, sw - 24)
          local stw = font_small:get_width(tech_str)
          local stx = sx + (sw - stw) / 2
          local sty = sy + sh * 0.52 + (sh * 0.48 - fh) / 2 - 2
          draw_rect(stx - 4, sty - 1, stw + 8, fh + 2, { 18, 22, 32, 200 })
          renderer.draw_text(font_small, tech_str, math.floor(stx), math.floor(sty), COLORS.node_subtext)

        else
          -- Full 3-Tier Mode: Tag/Badge + Bold Title + Tech Pill (Strictly disjoint Y bands)
          -- Tier 1: Y = [sy + 4, sy + 4 + fh]
          -- Tier 2: Y = [sy + 20, sy + sh - 25]
          -- Tier 3: Y = [sy + sh - 22, sy + sh - 4]

          -- Evaluate State Badge first to know reserved right-side width
          local btext = nil
          local bbg   = nil
          local bcol  = { 255, 255, 255, 255 }
          if is_in_flow then
            if flow.source == n.id then
              btext = "1. SOURCE"
            elseif flow.target == n.id then
              btext = string.format("%d. TARGET", flow_hop_idx or #flow.path)
            else
              btext = string.format("%d. HOP", flow_hop_idx or 2)
            end
            bbg   = { 8, 145, 178, 255 }
          elseif is_story_curr then
            btext = string.format("* STEP %d", view.story_step_idx or 1)
            bbg   = { 202, 138, 4, 255 }
          elseif is_impact_target then
            btext = "#TARGET"
            bbg   = { 225, 29, 72, 255 }
          elseif impact_up_d then
            btext = string.format("^ CALLER (d=%d)", impact_up_d)
            bbg   = { 194, 65, 12, 255 }
          elseif impact_down_d then
            btext = string.format("v DEP (d=%d)", impact_down_d)
            bbg   = { 4, 120, 87, 255 }
          elseif is_curr_match then
            btext = string.format("#%d/%d", match_idx, #search_matches)
            bbg   = { 217, 119, 6, 255 }
          elseif is_match then
            btext = string.format("#%d", match_idx)
            bbg   = { 14, 116, 144, 255 }
          elseif view and view.ai_insight and view.ai_insight.nodes and view.ai_insight.nodes[n.id] then
            btext = "AI INSIGHT"
            bbg   = { 147, 51, 234, 255 }
          elseif view and view.heatmap_mode then
            local in_deg = in_degree_map[n.id] or 0
            if in_deg >= 3 then
              btext = string.format("! SPOF: %d IN", in_deg)
              bbg   = { 180, 83, 9, 255 }
              bcol  = { 254, 240, 138, 255 }
            elseif (n.type == "cloud" or n.type == "external" or (n.name and n.name:match("AWS|GCP|Azure|S3|Stripe|Cloud"))) then
              btext = "CLOUD"
              bbg   = { 67, 56, 202, 255 }
              bcol  = { 224, 231, 255, 255 }
            end
          elseif is_suggested then
            btext = "[SUGGESTION]"
            bbg   = { 180, 83, 9, 255 }
            bcol  = { 254, 240, 138, 255 }
          elseif is_ext then
            btext = "[CLOUD]"
            bbg   = { 67, 56, 202, 255 }
            bcol  = { 224, 231, 255, 255 }
          elseif n.file and #n.file > 0 then
            btext = "[CODE]"
            bbg   = { 30, 41, 59, 255 }
            bcol  = { 148, 163, 184, 255 }
          end

          local bw = 0
          if btext and font_small then
            bw = font_small:get_width(btext) + 8
            local bh = 15
            local bx = sx + sw - bw - 6 * scale
            local by = sy + 4
            draw_rect(bx, by, bw, bh, bbg)
            renderer.draw_text(font_small, btext, math.floor(bx + 4), math.floor(by + (bh - fh) / 2), bcol)
          end

          -- TIER 1: Left Type / Subsystem Tag (guaranteed clearance before badge)
          local max_tag_w = sw - bw - (bw > 0 and 18 or 14)
          if max_tag_w > 28 then
            local raw_tag
            local tag_col = COLORS.node_subtext
            if is_caller and is_dep then
              raw_tag = "[CALLER & DEP]"
              tag_col = { 180, 215, 255, 255 }
            elseif is_caller then
              raw_tag = "[CALLER: IN]"
              tag_col = { 80, 240, 190, 255 }
            elseif is_dep then
              raw_tag = "[DEP: OUT]"
              tag_col = { 255, 210, 95, 255 }
            else
              raw_tag = "[" .. (n.type or "component"):upper() .. "]"
            end
            local tag_str = truncate(raw_tag, font_small, max_tag_w)
            local tag_x = sx + 8 * scale
            local tag_y = sy + 4 + (15 - fh) / 2
            renderer.draw_text(font_small, tag_str, math.floor(tag_x), math.floor(tag_y), tag_col)
          end

          -- TIER 2: Bold Component Title (Centered in dedicated middle band)
          local title_font = (scale >= 0.75 and sh >= 65) and font or font_small
          local th = title_font:get_height()
          local t1_bottom = sy + 4 + fh + 2
          local t3_top    = sy + sh - 22
          local avail_t2  = t3_top - t1_bottom
          local ty = t1_bottom + (avail_t2 - th) / 2

          local max_lbl_w = sw - 16 * scale
          local raw_label = (is_suggested and "* " or "") .. (n.label or n.id)
          local label = truncate(raw_label, title_font, max_lbl_w)
          local tw = title_font:get_width(label)
          local tx = sx + (sw - tw) / 2
          renderer.draw_text(title_font, label, math.floor(tx), math.floor(ty), COLORS.node_text)

          -- TIER 3: Tech Stack Pill (Centered in dedicated bottom band)
          local tech_str = n.tech and (#n.tech > 0) and n.tech or (n.type or "service")
          tech_str = truncate(tech_str, font_small, sw - 20 * scale)
          local stw = font_small:get_width(tech_str)
          local stx = sx + (sw - stw) / 2
          local sty = sy + sh - 21
          draw_rect(stx - 6, sty - 1, stw + 12, fh + 2, { 18, 22, 32, 200 })
          draw_rect(stx - 6, sty - 1, stw + 12, 1,      { 65, 80, 115, 200 })
          renderer.draw_text(font_small, tech_str, math.floor(stx), math.floor(sty), COLORS.node_subtext)
        end
      end
    end
    end
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Main draw function
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw Right Activity Rail (Secondary Sidebar with Vertical Icon Tabs)
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.draw_right_rail(view, rx, ry, rw, rh, mouse_x, mouse_y)
  local font   = style.font
  local fsmall = style.code_font or font
  local hit_rects = {
    tab_icons       = {},
    dim_controls    = {},
    insp_controls   = { callers = {}, deps = {} },
    heat_controls   = { hotspots = {} },
    audit_controls  = { findings = {} },
    tour_controls   = {},
    flow_controls   = {},
    action_controls = {},
  }

  local is_open    = (view and view.right_rail_open)
  local active_tab = (view and view.right_rail_tab) or "dimensions"

  -- 1. Outer 60px Vertical Icon Tab Strip (Wider to prevent any button text clipping)
  local strip_w = 60
  local strip_x = rx + rw - strip_w
  local strip_y = ry
  local strip_h = rh

  draw_rect(strip_x, strip_y, strip_w, strip_h, { 18, 22, 30, 255 })
  draw_rect(strip_x, strip_y, 1, strip_h, COLORS.separator)

  local icon_tabs = {
    { id = "dimensions", label = "Size",    tip = "Card Dimensions & Grid" },
    { id = "inspector",  label = "Inspect", tip = "Component Inspector" },
    { id = "heatmap",    label = "Heat",    tip = "Complexity & Hotspots Heatmap" },
    { id = "audit",      label = "Audit",   tip = "Architecture Doctor" },
    { id = "tour",       label = "Tour",   tip = "Guided Architecture Walkthrough" },
    { id = "flow",       label = "Flow",    tip = "Data Flow & Path Trace" },
    { id = "actions",    label = "Export",  tip = "Export SVG, Guide MD & Re-Analyze" },
  }

  local cur_icon_y = strip_y + 10
  local tooltip_to_draw = nil

  for _, it in ipairs(icon_tabs) do
    local is_active = is_open and (active_tab == it.id)
    local btn_x = strip_x + 5
    local btn_y = cur_icon_y
    local btn_w = 50
    local btn_h = 44
    local hov = is_hovered(mouse_x, mouse_y, btn_x, btn_y, btn_w, btn_h)

    local bg_col = is_active and { 36, 48, 72, 255 } or (hov and { 28, 34, 48, 255 } or { 22, 26, 36, 255 })
    local bdr_col = is_active and { 56, 189, 248, 255 } or (hov and { 50, 65, 95, 255 } or { 32, 38, 52, 255 })
    draw_rect(btn_x, btn_y, btn_w, btn_h, bg_col)
    draw_rect(btn_x, btn_y, btn_w, 1, bdr_col)

    if is_active then
      -- 3px neon indicator on the outer right edge
      draw_rect(btn_x + btn_w - 3, btn_y + 3, 3, btn_h - 6, { 56, 189, 248, 255 })
    end

    local icon_col = is_active and { 224, 238, 255, 255 } or (hov and { 180, 215, 255, 255 } or { 130, 145, 175, 200 })
    local cx = btn_x + (btn_w - 18) / 2
    local cy = btn_y + 4

    -- Vector Icons (18x18)
    if it.id == "dimensions" then
      -- Caliper / Dimension ruler icon
      draw_rect(cx + 1,  cy + 2,  2, 14, icon_col)
      draw_rect(cx + 15, cy + 2,  2, 14, icon_col)
      draw_rect(cx + 3,  cy + 8,  12, 2, icon_col)
      draw_rect(cx + 5,  cy + 6,  2, 6, is_active and { 56, 189, 248, 255 } or icon_col)
      draw_rect(cx + 11, cy + 6,  2, 6, is_active and { 56, 189, 248, 255 } or icon_col)
    elseif it.id == "inspector" then
      -- Info circular icon
      draw_rect(cx + 2,  cy + 2, 14, 2, icon_col)
      draw_rect(cx + 2,  cy + 14, 14, 2, icon_col)
      draw_rect(cx + 2,  cy + 2, 2, 14, icon_col)
      draw_rect(cx + 14, cy + 2, 2, 14, icon_col)
      draw_rect(cx + 8,  cy + 5, 2, 2, is_active and { 56, 189, 248, 255 } or icon_col)
      draw_rect(cx + 8,  cy + 8, 2, 5, is_active and { 56, 189, 248, 255 } or icon_col)
    elseif it.id == "heatmap" then
      -- Thermal flame / hotspot gradient icon
      local is_heat_on = (view and view.heatmap_mode)
      local flame_base = is_heat_on and { 245, 158, 11, 255 } or icon_col
      draw_rect(cx + 4, cy + 10, 10, 6, flame_base)
      draw_rect(cx + 6, cy + 6,  6, 5, is_active and { 239, 68, 68, 255 } or flame_base)
      draw_rect(cx + 8, cy + 2,  2, 5, is_active and { 251, 191, 36, 255 } or flame_base)
      draw_rect(cx + 7, cy + 12, 4, 3, { 254, 240, 138, 255 })
    elseif it.id == "audit" then
      -- Heartbeat pulse / Stethoscope icon
      draw_rect(cx + 1,  cy + 9, 3, 2, icon_col)
      draw_rect(cx + 4,  cy + 5, 2, 6, icon_col)
      draw_rect(cx + 6,  cy + 2, 2, 8, is_active and { 45, 212, 191, 255 } or icon_col)
      draw_rect(cx + 8,  cy + 8, 2, 8, is_active and { 244, 63, 94, 255 } or icon_col)
      draw_rect(cx + 10, cy + 6, 2, 6, icon_col)
      draw_rect(cx + 12, cy + 9, 5, 2, icon_col)
    elseif it.id == "tour" then
      -- Guided Walkthrough / Play Triangle vector icon
      draw_rect(cx + 4, cy + 3, 2, 12, is_active and { 250, 204, 21, 255 } or icon_col)
      draw_rect(cx + 6, cy + 5, 2, 8,  is_active and { 250, 204, 21, 255 } or icon_col)
      draw_rect(cx + 8, cy + 7, 2, 4,  is_active and { 250, 204, 21, 255 } or icon_col)
      draw_rect(cx + 10, cy + 8, 2, 2, is_active and { 250, 204, 21, 255 } or icon_col)
    elseif it.id == "flow" then
      -- Flow branching / merging icon
      draw_rect(cx + 2,  cy + 3, 4, 4, is_active and { 34, 211, 238, 255 } or icon_col)
      draw_rect(cx + 6,  cy + 5, 6, 2, icon_col)
      draw_rect(cx + 12, cy + 3, 4, 4, icon_col)
      draw_rect(cx + 6,  cy + 7, 2, 6, icon_col)
      draw_rect(cx + 8,  cy + 13, 6, 2, icon_col)
      draw_rect(cx + 14, cy + 11, 4, 4, is_active and { 34, 211, 238, 255 } or icon_col)
    else
      -- Actions / Export tray & upward arrow icon
      draw_rect(cx + 2,  cy + 12, 14, 2, icon_col)
      draw_rect(cx + 2,  cy + 7,  2,  6, icon_col)
      draw_rect(cx + 14, cy + 7,  2,  6, icon_col)
      draw_rect(cx + 8,  cy + 3,  2,  7, is_active and { 56, 189, 248, 255 } or icon_col)
      draw_rect(cx + 6,  cy + 4,  2,  2, is_active and { 56, 189, 248, 255 } or icon_col)
      draw_rect(cx + 10, cy + 4,  2,  2, is_active and { 56, 189, 248, 255 } or icon_col)
      draw_rect(cx + 7,  cy + 2,  4,  2, is_active and { 56, 189, 248, 255 } or icon_col)
    end

    -- Mini-label beneath icon with guaranteed zero clipping
    local tw = fsmall:get_width(it.label)
    local lbl = it.label
    if tw > btn_w - 2 then
      lbl = truncate(it.label, fsmall, btn_w - 2)
      tw = fsmall:get_width(lbl)
    end
    renderer.draw_text(fsmall, lbl, math.floor(btn_x + (btn_w - tw) / 2), math.floor(btn_y + 27), is_active and { 200, 230, 255, 255 } or { 110, 125, 150, 180 })

    hit_rects.tab_icons[it.id] = { x = btn_x, y = btn_y, w = btn_w, h = btn_h, id = it.id }

    if hov then
      tooltip_to_draw = {
        text = it.tip,
        x = strip_x - fsmall:get_width(it.tip) - 24,
        y = btn_y + (btn_h - 22) / 2
      }
    end

    cur_icon_y = cur_icon_y + btn_h + 8
  end

  -- If right rail is closed, return hit rects and render tooltip
  if not is_open or rw <= strip_w then
    if tooltip_to_draw then
      local tw = fsmall:get_width(tooltip_to_draw.text) + 16
      local th = 22
      local tx = tooltip_to_draw.x
      local ty = tooltip_to_draw.y
      draw_rect(tx + 2, ty + 2, tw, th, { 0, 0, 0, 130 })
      draw_rect(tx,     ty,     tw, th, { 26, 32, 44, 250 })
      draw_rect(tx,     ty,     tw, 1,  { 70, 95, 150, 255 })
      renderer.draw_text(fsmall, tooltip_to_draw.text, math.floor(tx + 8), math.floor(ty + (th - fsmall:get_height()) / 2), { 235, 245, 255, 255 })
    end
    return hit_rects
  end

  -- 2. Inner Panel Content Area (rx to strip_x)
  local panel_x = rx
  local panel_y = ry
  local panel_w = rw - strip_w
  local panel_h = rh

  draw_rect(panel_x, panel_y, panel_w, panel_h, { 16, 20, 28, 252 })
  draw_rect(panel_x, panel_y, 1, panel_h, COLORS.separator)

  -- Panel Header (34px)
  local hdr_h = 34
  draw_rect(panel_x, panel_y, panel_w, hdr_h, { 22, 27, 38, 255 })
  draw_rect(panel_x, panel_y + hdr_h - 1, panel_w, 1, COLORS.separator)

  local titles = {
    dimensions = "SIZING & DIMENSIONS",
    inspector  = "COMPONENT INSPECTOR",
    heatmap    = "COMPLEXITY HEATMAP",
    audit      = "ARCHITECTURE AUDIT",
    flow       = "FLOW & LAYERS",
    actions    = "PROJECT ACTIONS & EXPORT",
  }
  local panel_title = titles[active_tab] or "CONTROLS"
  renderer.draw_text(fsmall, panel_title, math.floor(panel_x + 12), math.floor(panel_y + (hdr_h - fsmall:get_height()) / 2), { 220, 235, 255, 255 })

  -- Close / Collapse Panel Button [ > ]
  local tog_w = 20
  local tog_h = 20
  local tog_x = panel_x + panel_w - tog_w - 8
  local tog_y = panel_y + (hdr_h - tog_h) / 2
  local tog_hov = is_hovered(mouse_x, mouse_y, tog_x, tog_y, tog_w, tog_h)
  draw_rect(tog_x, tog_y, tog_w, tog_h, tog_hov and { 50, 60, 80, 255 } or { 30, 36, 50, 255 })
  draw_rect(tog_x, tog_y, tog_w, 1, { 65, 80, 110, 255 })
  local t_str = ">"
  renderer.draw_text(fsmall, t_str, math.floor(tog_x + (tog_w - fsmall:get_width(t_str)) / 2), math.floor(tog_y + (tog_h - fsmall:get_height()) / 2), tog_hov and { 255, 255, 255, 255 } or { 160, 180, 210, 255 })
  hit_rects.toggle_rect = { x = tog_x, y = tog_y, w = tog_w, h = tog_h }

  local cur_y = panel_y + hdr_h + 10
  local pad = 12
  local content_w = panel_w - pad * 2

  local function draw_section_label(txt)
    renderer.draw_text(fsmall, txt, math.floor(panel_x + pad), math.floor(cur_y), { 110, 140, 190, 255 })
    cur_y = cur_y + fsmall:get_height() + 6
  end

  local function draw_separator()
    draw_rect(panel_x + pad, cur_y, content_w, 1, { 35, 42, 56, 255 })
    cur_y = cur_y + 8
  end

  -- TAB 1: SIZING & DIMENSIONS CONTROLS
  if active_tab == "dimensions" then
    local cur_w    = view.custom_node_w or DiagramRenderer.BASE_NODE_W or 230
    local cur_h    = view.custom_node_h or DiagramRenderer.BASE_NODE_H or 84
    local cur_hgap = view.custom_h_gap or 70
    local cur_vgap = view.custom_v_gap or 55

    draw_section_label("NODE CARD SIZING")

    local function draw_stepper(label_text, val_text, key_prefix)
      local row_h = 24
      renderer.draw_text(fsmall, label_text, math.floor(panel_x + pad), math.floor(cur_y + (row_h - fsmall:get_height()) / 2), { 200, 215, 235, 255 })

      local btn_size = 22
      local disp_w   = 68
      local plus_x   = panel_x + panel_w - pad - btn_size
      local disp_x   = plus_x - disp_w - 4
      local minus_x  = disp_x - btn_size - 4

      local m_hov = is_hovered(mouse_x, mouse_y, minus_x, cur_y + 1, btn_size, btn_size)
      draw_rect(minus_x, cur_y + 1, btn_size, btn_size, m_hov and { 52, 65, 90, 255 } or { 32, 40, 56, 255 })
      draw_rect(minus_x, cur_y + 1, btn_size, 1, m_hov and { 130, 170, 240, 255 } or { 60, 75, 105, 255 })
      local m_str = "-"
      renderer.draw_text(font, m_str, math.floor(minus_x + (btn_size - font:get_width(m_str)) / 2), math.floor(cur_y + 1 + (btn_size - font:get_height()) / 2), m_hov and { 255, 255, 255, 255 } or { 180, 205, 240, 255 })

      draw_rect(disp_x, cur_y + 1, disp_w, btn_size, { 22, 28, 40, 255 })
      draw_rect(disp_x, cur_y + 1, disp_w, 1, { 45, 58, 80, 255 })
      local v_tw = fsmall:get_width(val_text)
      renderer.draw_text(fsmall, val_text, math.floor(disp_x + (disp_w - v_tw) / 2), math.floor(cur_y + 1 + (btn_size - fsmall:get_height()) / 2), { 240, 245, 255, 255 })

      local p_hov = is_hovered(mouse_x, mouse_y, plus_x, cur_y + 1, btn_size, btn_size)
      draw_rect(plus_x, cur_y + 1, btn_size, btn_size, p_hov and { 52, 65, 90, 255 } or { 32, 40, 56, 255 })
      draw_rect(plus_x, cur_y + 1, btn_size, 1, p_hov and { 130, 170, 240, 255 } or { 60, 75, 105, 255 })
      local p_str = "+"
      renderer.draw_text(font, p_str, math.floor(plus_x + (btn_size - font:get_width(p_str)) / 2), math.floor(cur_y + 1 + (btn_size - font:get_height()) / 2), p_hov and { 255, 255, 255, 255 } or { 180, 205, 240, 255 })

      hit_rects.dim_controls[key_prefix .. "_minus"] = { x = minus_x, y = cur_y + 1, w = btn_size, h = btn_size }
      hit_rects.dim_controls[key_prefix .. "_plus"]  = { x = plus_x,  y = cur_y + 1, w = btn_size, h = btn_size }

      cur_y = cur_y + row_h + 6
    end

    draw_stepper("Width", string.format("%d px", cur_w), "w")
    draw_stepper("Height", string.format("%d px", cur_h), "h")

    draw_separator()
    draw_section_label("LAYOUT & SPACING")

    draw_stepper("H-Gap", string.format("%d px", cur_hgap), "hgap")
    draw_stepper("V-Row Gap", string.format("%d px", cur_vgap), "vgap")

    draw_separator()
    draw_section_label("QUICK PRESETS")

    local presets = {
      { id = "compact",  name = "Compact",  w = 180, h = 68,  hg = 50, vg = 40 },
      { id = "standard", name = "Standard", w = 230, h = 84,  hg = 70, vg = 55 },
      { id = "wide",     name = "Wide",     w = 280, h = 92,  hg = 85, vg = 65 },
      { id = "spacious", name = "Spacious", w = 320, h = 105, hg = 100, vg = 75 },
    }

    local pbtn_w = math.floor((content_w - 6) / 2)
    local pbtn_h = 24
    for i, p in ipairs(presets) do
      local px_btn = panel_x + pad + ((i - 1) % 2) * (pbtn_w + 6)
      local py_btn = cur_y + math.floor((i - 1) / 2) * (pbtn_h + 6)
      local is_cur = (cur_w == p.w and cur_h == p.h)
      local phov   = is_hovered(mouse_x, mouse_y, px_btn, py_btn, pbtn_w, pbtn_h)

      local bg = is_cur and { 42, 60, 92, 255 } or (phov and { 34, 44, 62, 255 } or { 24, 30, 42, 255 })
      local bdr = is_cur and { 56, 189, 248, 255 } or (phov and { 100, 140, 200, 255 } or { 45, 55, 75, 255 })
      draw_rect(px_btn, py_btn, pbtn_w, pbtn_h, bg)
      draw_rect(px_btn, py_btn, pbtn_w, 1, bdr)

      local ptw = fsmall:get_width(p.name)
      renderer.draw_text(fsmall, p.name, math.floor(px_btn + (pbtn_w - ptw) / 2), math.floor(py_btn + (pbtn_h - fsmall:get_height()) / 2), is_cur and { 240, 250, 255, 255 } or { 160, 180, 210, 255 })

      hit_rects.dim_controls["preset_" .. p.id] = { x = px_btn, y = py_btn, w = pbtn_w, h = pbtn_h, preset = p.id }
    end
    cur_y = cur_y + (pbtn_h + 6) * 2 + 8

    -- Reset Sizing button
    local rst_w = content_w
    local rst_h = 26
    local rst_hov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, rst_w, rst_h)
    draw_rect(panel_x + pad, cur_y, rst_w, rst_h, rst_hov and { 45, 52, 70, 255 } or { 28, 34, 46, 255 })
    draw_rect(panel_x + pad, cur_y, rst_w, 1, rst_hov and { 130, 170, 240, 255 } or { 50, 62, 85, 255 })
    local rst_label = "Reset to Standard Sizing"
    local rst_tw = fsmall:get_width(rst_label)
    renderer.draw_text(fsmall, rst_label, math.floor(panel_x + pad + (rst_w - rst_tw) / 2), math.floor(cur_y + (rst_h - fsmall:get_height()) / 2), rst_hov and { 255, 255, 255, 255 } or { 180, 205, 240, 255 })
    hit_rects.dim_controls["reset"] = { x = panel_x + pad, y = cur_y, w = rst_w, h = rst_h }
    cur_y = cur_y + rst_h + 10

    draw_separator()
    draw_section_label("FILTERING & GROUNDING")

    local show_sug = (view and view.show_suggested_nodes ~= false)
    local tog_w = content_w
    local tog_h = 28
    local tog_hov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, tog_w, tog_h)
    local tog_bg  = show_sug and (tog_hov and { 45, 60, 85, 255 } or { 30, 42, 62, 255 })
                             or (tog_hov and { 60, 40, 25, 255 } or { 40, 28, 18, 255 })
    local tog_bdr = show_sug and { 56, 189, 248, 255 } or { 245, 158, 11, 255 }
    draw_rect(panel_x + pad, cur_y, tog_w, tog_h, tog_bg)
    draw_rect(panel_x + pad, cur_y, tog_w, 1, tog_bdr)

    local tog_label = show_sug and "[*] AI Suggestions: ON (Click to Hide)"
                                or "[*] AI Suggestions: HIDDEN (Code Only)"
    local tog_col = show_sug and { 220, 240, 255, 255 } or { 254, 240, 138, 255 }
    renderer.draw_text(fsmall, tog_label, math.floor(panel_x + pad + 10), math.floor(cur_y + (tog_h - fsmall:get_height()) / 2), tog_col)
    hit_rects.dim_controls["toggle_suggestions"] = { x = panel_x + pad, y = cur_y, w = tog_w, h = tog_h }
    cur_y = cur_y + tog_h + 4

    local hint_txt = show_sug and "Showing repo code + inferred tools." or "Showing 100% verified repository code only."
    renderer.draw_text(fsmall, hint_txt, math.floor(panel_x + pad + 2), math.floor(cur_y), { 120, 140, 175, 220 })
    cur_y = cur_y + fsmall:get_height() + 8

  -- TAB 2: COMPONENT INSPECTOR
  elseif active_tab == "inspector" then
    local node = view.inspector_node
    if not node then
      cur_y = cur_y + 20
      draw_rect(panel_x + pad, cur_y, content_w, 70, { 22, 28, 38, 200 })
      draw_rect(panel_x + pad, cur_y, content_w, 1, { 45, 55, 75, 255 })
      renderer.draw_text(fsmall, "No Component Selected", math.floor(panel_x + pad + 12), math.floor(cur_y + 12), { 210, 225, 250, 255 })
      renderer.draw_text(fsmall, "Click any card on canvas", math.floor(panel_x + pad + 12), math.floor(cur_y + 32), { 130, 145, 175, 200 })
      renderer.draw_text(fsmall, "to inspect its connections.", math.floor(panel_x + pad + 12), math.floor(cur_y + 48), { 130, 145, 175, 200 })
    else
      local title = truncate(node.label or node.id, font, content_w - 8)
      renderer.draw_text(font, title, math.floor(panel_x + pad), math.floor(cur_y), { 245, 250, 255, 255 })
      cur_y = cur_y + font:get_height() + 4

      local is_sug = (node.suggested == true or (node.external == true and (not node.file or node.file == "")) or (not node.file or node.file == ""))
      local tier_text = string.format("[%s : %s]", (node.tier or "app"):upper(), (node.type or "service"):upper())
      if is_sug then
        tier_text = tier_text .. " [SUGGESTION]"
      elseif node.external then
        tier_text = tier_text .. " [CLOUD]"
      else
        tier_text = tier_text .. " [IN CODE]"
      end
      renderer.draw_text(fsmall, tier_text, math.floor(panel_x + pad), math.floor(cur_y), is_sug and { 254, 240, 138, 255 } or { 140, 215, 255, 255 })
      cur_y = cur_y + fsmall:get_height() + 10

      if is_sug then
        draw_rect(panel_x + pad, cur_y, content_w, 34, { 48, 32, 12, 230 })
        draw_rect(panel_x + pad, cur_y, content_w, 1,  { 245, 158, 11, 255 })
        renderer.draw_text(fsmall, "AI ARCHITECTURAL SUGGESTION", math.floor(panel_x + pad + 8), math.floor(cur_y + 4), { 254, 240, 138, 255 })
        renderer.draw_text(fsmall, "Inferred tool (Not found in project source code).", math.floor(panel_x + pad + 8), math.floor(cur_y + 18), { 220, 200, 160, 230 })
        cur_y = cur_y + 40
      end

      local abtn_w = math.floor((content_w - 8) / 3)
      local abtn_h = 24

      local is_foc = (view.focus_node_id == node.id)
      local fx = panel_x + pad
      local fhov = is_hovered(mouse_x, mouse_y, fx, cur_y, abtn_w, abtn_h)
      draw_rect(fx, cur_y, abtn_w, abtn_h, is_foc and { 70, 52, 20, 255 } or (fhov and { 45, 55, 75, 255 } or { 28, 34, 46, 255 }))
      draw_rect(fx, cur_y, abtn_w, 1, is_foc and { 245, 158, 11, 255 } or { 50, 65, 90, 255 })
      local flbl = is_foc and "Exit Focus" or "Focus"
      renderer.draw_text(fsmall, flbl, math.floor(fx + (abtn_w - fsmall:get_width(flbl)) / 2), math.floor(cur_y + (abtn_h - fsmall:get_height()) / 2), is_foc and { 255, 215, 110, 255 } or { 180, 205, 240, 255 })
      hit_rects.insp_controls.focus = { x = fx, y = cur_y, w = abtn_w, h = abtn_h }

      local is_imp = (view.impact_data and view.impact_data.target == node.id)
      local bx = fx + abtn_w + 4
      local bhov = is_hovered(mouse_x, mouse_y, bx, cur_y, abtn_w, abtn_h)
      draw_rect(bx, cur_y, abtn_w, abtn_h, is_imp and { 80, 28, 40, 255 } or (bhov and { 45, 55, 75, 255 } or { 28, 34, 46, 255 }))
      draw_rect(bx, cur_y, abtn_w, 1, is_imp and { 244, 63, 94, 255 } or { 50, 65, 90, 255 })
      local blbl = is_imp and "Exit Blast" or "Blast"
      renderer.draw_text(fsmall, blbl, math.floor(bx + (abtn_w - fsmall:get_width(blbl)) / 2), math.floor(cur_y + (abtn_h - fsmall:get_height()) / 2), is_imp and { 255, 150, 170, 255 } or { 180, 205, 240, 255 })
      hit_rects.insp_controls.blast = { x = bx, y = cur_y, w = abtn_w, h = abtn_h }

      local is_fl = (view.flow_trace and (view.flow_trace.source == node.id or view.flow_trace.target == node.id))
      local flow_x = bx + abtn_w + 4
      local flow_hov = is_hovered(mouse_x, mouse_y, flow_x, cur_y, abtn_w, abtn_h)
      draw_rect(flow_x, cur_y, abtn_w, abtn_h, is_fl and { 14, 52, 60, 255 } or (flow_hov and { 45, 55, 75, 255 } or { 28, 34, 46, 255 }))
      draw_rect(flow_x, cur_y, abtn_w, 1, is_fl and { 34, 211, 238, 255 } or { 50, 65, 90, 255 })
      local fllbl = is_fl and "Exit Flow" or "Trace Flow"
      renderer.draw_text(fsmall, fllbl, math.floor(flow_x + (abtn_w - fsmall:get_width(fllbl)) / 2), math.floor(cur_y + (abtn_h - fsmall:get_height()) / 2), is_fl and { 165, 243, 252, 255 } or { 180, 205, 240, 255 })
      hit_rects.insp_controls.flow = { x = flow_x, y = cur_y, w = abtn_w, h = abtn_h }

      cur_y = cur_y + abtn_h + 10

      draw_separator()
      draw_section_label("PROPERTIES")
      renderer.draw_text(fsmall, "Tech: " .. (node.tech or "N/A"), math.floor(panel_x + pad), math.floor(cur_y), { 160, 200, 250, 255 })
      cur_y = cur_y + fsmall:get_height() + 4
      if node.port then
        renderer.draw_text(fsmall, "Port: " .. tostring(node.port), math.floor(panel_x + pad), math.floor(cur_y), { 140, 175, 215, 255 })
        cur_y = cur_y + fsmall:get_height() + 4
      end

      draw_separator()
      draw_section_label("SOURCE CODE")
      local is_sug = (node.suggested == true or (node.external == true and (not node.file or node.file == "")) or (not node.file or node.file == ""))
      local fstr = node.file and string.format("%s:%s", node.file, node.line or 1) or (is_sug and "[AI Suggestion - Inferred]" or "[External Cloud]")
      local jhov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, 20)
      draw_rect(panel_x + pad, cur_y, content_w, 20, jhov and { 34, 48, 70, 255 } or { 22, 28, 40, 200 })
      renderer.draw_text(fsmall, truncate(fstr, fsmall, content_w - 12), math.floor(panel_x + pad + 6), math.floor(cur_y + 3), jhov and { 140, 220, 255, 255 } or { 110, 160, 230, 255 })
      hit_rects.insp_controls.jump = { x = panel_x + pad, y = cur_y, w = content_w, h = 20 }
      cur_y = cur_y + 26
    end

  -- TAB 3: HEATMAP & HOTSPOTS
  elseif active_tab == "heatmap" then
    draw_section_label("COMPLEXITY & HOTSPOTS")

    local is_heat_on = (view and view.heatmap_mode)
    local hbtn_h = 28
    local hhov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, hbtn_h)
    local hbg = is_heat_on and { 65, 42, 20, 255 } or (hhov and { 45, 55, 75, 255 } or { 28, 34, 46, 255 })
    local hbdr = is_heat_on and { 245, 158, 11, 255 } or (hhov and { 130, 170, 240, 255 } or { 50, 65, 90, 255 })
    draw_rect(panel_x + pad, cur_y, content_w, hbtn_h, hbg)
    draw_rect(panel_x + pad, cur_y, content_w, 1, hbdr)
    local h_lbl = is_heat_on and "Heatmap Mode: ACTIVE" or "Enable Heatmap Mode"
    local h_col = is_heat_on and { 255, 215, 110, 255 } or { 220, 235, 255, 255 }
    renderer.draw_text(font, h_lbl, math.floor(panel_x + pad + (content_w - font:get_width(h_lbl)) / 2), math.floor(cur_y + (hbtn_h - font:get_height()) / 2), h_col)
    hit_rects.heat_controls.toggle = { x = panel_x + pad, y = cur_y, w = content_w, h = hbtn_h }
    cur_y = cur_y + hbtn_h + 12

    -- Thermal Legend
    draw_separator()
    draw_section_label("HEAT SCALE")
    local leg_w = math.floor((content_w - 8) / 3)
    local leg_h = 20
    draw_rect(panel_x + pad, cur_y, leg_w, leg_h, { 30, 75, 130, 220 })
    renderer.draw_text(fsmall, "Low", math.floor(panel_x + pad + (leg_w - fsmall:get_width("Low")) / 2), math.floor(cur_y + 3), { 160, 210, 255, 255 })
    draw_rect(panel_x + pad + leg_w + 4, cur_y, leg_w, leg_h, { 180, 100, 25, 220 })
    renderer.draw_text(fsmall, "Medium", math.floor(panel_x + pad + leg_w + 4 + (leg_w - fsmall:get_width("Medium")) / 2), math.floor(cur_y + 3), { 255, 220, 140, 255 })
    draw_rect(panel_x + pad + (leg_w + 4) * 2, cur_y, leg_w, leg_h, { 180, 35, 45, 220 })
    renderer.draw_text(fsmall, "Critical", math.floor(panel_x + pad + (leg_w + 4) * 2 + (leg_w - fsmall:get_width("Critical")) / 2), math.floor(cur_y + 3), { 255, 160, 170, 255 })
    cur_y = cur_y + leg_h + 12

    -- Top Coupling Hotspots
    draw_separator()
    draw_section_label("COUPLING HOTSPOTS")
    local diag = view and view:current_diagram()
    if diag and diag.nodes and diag.edges then
      local in_deg = {}
      for _, e in ipairs(diag.edges) do
        if e.to then in_deg[e.to] = (in_deg[e.to] or 0) + 1 end
      end
      local sorted_nodes = {}
      for _, n in ipairs(diag.nodes) do
        table.insert(sorted_nodes, { node = n, deg = in_deg[n.id] or 0 })
      end
      table.sort(sorted_nodes, function(a, b) return a.deg > b.deg end)

      hit_rects.heat_controls.hotspots = {}
      for i = 1, math.min(6, #sorted_nodes) do
        local sn = sorted_nodes[i]
        local card_h = 24
        local chov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, card_h)
        local cbg = chov and { 45, 52, 68, 255 } or { 24, 28, 38, 200 }
        draw_rect(panel_x + pad, cur_y, content_w, card_h, cbg)
        local badge_col = (sn.deg >= 4) and { 244, 63, 94, 255 } or ((sn.deg >= 2) and { 245, 158, 11, 255 } or { 56, 189, 248, 255 })
        draw_rect(panel_x + pad, cur_y, content_w, 1, badge_col)

        local n_lbl = truncate(sn.node.label or sn.node.id, fsmall, content_w - 65)
        renderer.draw_text(fsmall, n_lbl, math.floor(panel_x + pad + 6), math.floor(cur_y + 4), { 230, 240, 255, 255 })
        local d_lbl = string.format("%d in-deps", sn.deg)
        renderer.draw_text(fsmall, d_lbl, math.floor(panel_x + pad + content_w - fsmall:get_width(d_lbl) - 6), math.floor(cur_y + 4), badge_col)

        table.insert(hit_rects.heat_controls.hotspots, {
          x = panel_x + pad, y = cur_y, w = content_w, h = card_h, node = sn.node
        })
        cur_y = cur_y + card_h + 4
      end
    end

  -- TAB 4: ARCHITECTURE AUDIT
  elseif active_tab == "audit" then
    local audit = view.audit_data
    local score = audit and audit.score or 100
    local grade = (audit and audit.grade) or (score >= 90 and "A" or (score >= 75 and "B" or (score >= 60 and "C" or (score >= 40 and "D" or "F"))))
    local score_col = (score >= 80) and { 16, 185, 129, 255 } or ((score >= 60) and { 245, 158, 11, 255 } or { 244, 63, 94, 255 })

    -- Health Score & Letter Grade Banner
    local banner_h = 42
    draw_rect(panel_x + pad, cur_y, content_w, banner_h, { 22, 28, 40, 255 })
    draw_rect(panel_x + pad, cur_y, content_w, 1, score_col)
    local s_str = string.format("HEALTH SCORE: %d/100", score)
    renderer.draw_text(font, s_str, math.floor(panel_x + pad + 10), math.floor(cur_y + 12), score_col)
    local g_str = string.format("GRADE: %s", grade)
    local g_w = font:get_width(g_str)
    renderer.draw_text(font, g_str, math.floor(panel_x + pad + content_w - g_w - 10), math.floor(cur_y + 12), score_col)
    cur_y = cur_y + banner_h + 8

    -- Re-run Rules Audit Button
    local rbtn_h = 24
    local rhov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, rbtn_h)
    draw_rect(panel_x + pad, cur_y, content_w, rbtn_h, rhov and { 45, 65, 55, 255 } or { 25, 45, 38, 255 })
    draw_rect(panel_x + pad, cur_y, content_w, 1, rhov and { 45, 212, 191, 255 } or { 30, 120, 100, 255 })
    local r_lbl = "Re-run Rules Audit"
    renderer.draw_text(fsmall, r_lbl, math.floor(panel_x + pad + (content_w - fsmall:get_width(r_lbl)) / 2), math.floor(cur_y + (rbtn_h - fsmall:get_height()) / 2), { 200, 255, 240, 255 })
    hit_rects.audit_controls.run = { x = panel_x + pad, y = cur_y, w = content_w, h = rbtn_h }
    cur_y = cur_y + rbtn_h + 6

    -- AI Deep Audit (Doctor) Button
    local is_ai_loading = (view and view.ai_audit_loading)
    local ai_btn_lbl = is_ai_loading and "[...] Auditing Architecture with AI..." or "AI Deep Audit (Doctor)"
    local aihov = not is_ai_loading and is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, rbtn_h)
    draw_rect(panel_x + pad, cur_y, content_w, rbtn_h, is_ai_loading and { 50, 30, 70, 255 } or (aihov and { 65, 35, 95, 255 } or { 38, 20, 58, 255 }))
    draw_rect(panel_x + pad, cur_y, content_w, 1, is_ai_loading and { 216, 180, 254, 255 } or (aihov and { 192, 132, 252, 255 } or { 147, 51, 234, 255 }))
    renderer.draw_text(fsmall, ai_btn_lbl, math.floor(panel_x + pad + (content_w - fsmall:get_width(ai_btn_lbl)) / 2), math.floor(cur_y + (rbtn_h - fsmall:get_height()) / 2), { 235, 215, 255, 255 })
    hit_rects.audit_controls.ai_deep_audit = { x = panel_x + pad, y = cur_y, w = content_w, h = rbtn_h }
    cur_y = cur_y + rbtn_h + 8

    -- AI Summary callout if present
    if audit and audit.ai_summary and #audit.ai_summary > 0 then
      local prov_tag = (audit.provider and #audit.provider > 0) and string.format("[%s] ", audit.provider:upper()) or ""
      local sum_lbl = prov_tag .. "AI Summary:"
      renderer.draw_text(fsmall, sum_lbl, math.floor(panel_x + pad), math.floor(cur_y), { 192, 132, 252, 255 })
      cur_y = cur_y + fsmall:get_height() + 4
      local sum_lines = wrap_insight_text(audit.ai_summary, fsmall, content_w - 12)
      for _, sl in ipairs(sum_lines) do
        renderer.draw_text(fsmall, sl, math.floor(panel_x + pad + 6), math.floor(cur_y), { 220, 215, 240, 255 })
        cur_y = cur_y + fsmall:get_height() + 2
      end
      cur_y = cur_y + 6
    end

    draw_separator()
    draw_section_label("FINDINGS")

    local findings = audit and audit.findings or {}
    if #findings == 0 then
      renderer.draw_text(fsmall, "[OK] No anti-patterns detected!", math.floor(panel_x + pad), math.floor(cur_y), { 16, 185, 129, 255 })
    else
      for idx, f in ipairs(findings) do
        local f_h = 52
        local f_hov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, f_h)
        local is_active = (view and view.active_audit_finding == f)
        local bcol = (f.type == "critical") and { 244, 63, 94, 255 } or ((f.type == "warning") and { 245, 158, 11, 255 } or { 56, 189, 248, 255 })
        draw_rect(panel_x + pad, cur_y, content_w, f_h, is_active and { 48, 55, 76, 255 } or (f_hov and { 36, 44, 60, 255 } or { 24, 28, 38, 255 }))
        draw_rect(panel_x + pad, cur_y, content_w, 1, is_active and { 255, 255, 255, 255 } or bcol)
        draw_rect(panel_x + pad, cur_y, is_active and 4 or 3, f_h, bcol)

        -- [ [+] Enlarge ] Button on right
        local enl_label = " [+] Enlarge "
        local enl_w     = fsmall:get_width(enl_label) + 6
        local enl_h     = 20
        local enl_x     = panel_x + pad + content_w - enl_w - 6
        local enl_y     = cur_y + 6
        local enl_hov   = is_hovered(mouse_x, mouse_y, enl_x, enl_y, enl_w, enl_h)
        draw_rect(enl_x, enl_y, enl_w, enl_h, enl_hov and { 45, 55, 80, 255 } or { 30, 36, 52, 220 })
        draw_rect(enl_x, enl_y, enl_w, 1,    enl_hov and bcol or { 60, 80, 110, 200 })
        renderer.draw_text(fsmall, enl_label, math.floor(enl_x + 3), math.floor(enl_y + (enl_h - fsmall:get_height()) / 2), enl_hov and { 255, 255, 255, 255 } or { 190, 215, 245, 255 })

        -- Title line (with AI badge if source == 'ai')
        local title_prefix = (f.source == "ai") and "[AI] " or ""
        local f_title = truncate(title_prefix .. (f.title or "Issue"), fsmall, content_w - enl_w - 18)
        renderer.draw_text(fsmall, f_title, math.floor(panel_x + pad + 8), math.floor(cur_y + 7), is_active and { 255, 255, 255, 255 } or { 240, 245, 255, 255 })

        -- Action / Node string
        local action_str = f.nodes and #f.nodes > 0 and ("Targets: " .. table.concat(f.nodes, ", ")) or "Inspect finding"
        action_str = truncate(action_str, fsmall, content_w - enl_w - 18)
        renderer.draw_text(fsmall, action_str, math.floor(panel_x + pad + 8), math.floor(cur_y + 28), is_active and { 186, 230, 253, 255 } or { 130, 185, 255, 255 })

        table.insert(hit_rects.audit_controls.findings, {
          x = panel_x + pad, y = cur_y, w = content_w, h = f_h,
          enlarge_rect = { x = enl_x, y = enl_y, w = enl_w, h = enl_h },
          finding = f
        })
        cur_y = cur_y + f_h + 6
        if cur_y > panel_y + panel_h - 40 then break end
      end
    end
  -- TAB 4: FLOW & LAYERS
  elseif active_tab == "tour" then
    local max_w = content_w
    -- Panel Title
    local title = "GUIDED ARCHITECTURE TOUR"
    renderer.draw_text(font, title, math.floor(panel_x + pad), math.floor(cur_y), { 250, 204, 21, 255 })
    cur_y = cur_y + font:get_height() + 6

    -- Subtitle / Description
    local desc = "Step-by-step walkthrough of major architecture tiers and critical component paths."
    renderer.draw_text(fsmall, desc, math.floor(panel_x + pad), math.floor(cur_y), COLORS.node_subtext)
    cur_y = cur_y + fsmall:get_height() + 12

    draw_rect(panel_x + pad, cur_y, content_w, 1, COLORS.separator)
    cur_y = cur_y + 12

    local is_tour_active = (view and view.story_mode)
    local tours = (view and view.story_tours) or (view and view.generate_story_tours and view:generate_story_tours()) or {}

    if not is_tour_active then
      renderer.draw_text(font, "Available Tours (" .. #tours .. "):", math.floor(panel_x + pad), math.floor(cur_y), { 220, 230, 245, 255 })
      cur_y = cur_y + font:get_height() + 8

      for idx, t in ipairs(tours) do
        local tbox_h = 32
        local tbox_hov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, tbox_h)
        draw_rect(panel_x + pad, cur_y, content_w, tbox_h, tbox_hov and { 45, 38, 28, 255 } or { 32, 28, 22, 220 })
        draw_rect(panel_x + pad, cur_y, content_w, 1, tbox_hov and { 250, 204, 21, 255 } or { 160, 120, 30, 200 })
        draw_rect(panel_x + pad, cur_y, 3, tbox_h, { 250, 204, 21, 255 })

        local tname = string.format("%d. %s", idx, truncate(t.name or "Guided Walkthrough", fsmall, content_w - 90))
        renderer.draw_text(fsmall, tname, math.floor(panel_x + pad + 10), math.floor(cur_y + 8), { 254, 240, 138, 255 })

        local step_count_str = string.format("(%d steps)", #(t.steps or {}))
        local scw = fsmall:get_width(step_count_str)
        renderer.draw_text(fsmall, step_count_str, math.floor(panel_x + pad + content_w - scw - 10), math.floor(cur_y + 8), { 180, 160, 120, 255 })

        cur_y = cur_y + tbox_h + 8
      end

      cur_y = cur_y + 6
      local start_btn_h = 28
      local start_hov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, start_btn_h)
      draw_rect(panel_x + pad, cur_y, content_w, start_btn_h, start_hov and { 85, 65, 20, 255 } or { 55, 42, 16, 220 })
      draw_rect(panel_x + pad, cur_y, content_w, 1, start_hov and { 250, 204, 21, 255 } or { 180, 140, 30, 255 })
      local start_lbl = "> Start Guided Walkthrough"
      local slw = font:get_width(start_lbl)
      renderer.draw_text(font, start_lbl, math.floor(panel_x + pad + (content_w - slw) / 2), math.floor(cur_y + (start_btn_h - font:get_height()) / 2), start_hov and { 255, 255, 255, 255 } or { 254, 240, 138, 255 })
      hit_rects.tour_controls.start = { x = panel_x + pad, y = cur_y, w = content_w, h = start_btn_h }
      cur_y = cur_y + start_btn_h + 14

      renderer.draw_text(fsmall, "Keyboard: Left / Right arrows navigate steps.", math.floor(panel_x + pad), math.floor(cur_y), { 140, 150, 175, 200 })
    else
      local tour_idx = view.story_tour_idx or 1
      local curr_tour = tours[tour_idx] or { name = "Architecture Walkthrough", steps = {} }
      local steps = curr_tour.steps or {}
      local s_idx = view.story_step_idx or 1

      local badge_w = fsmall:get_width(" TOUR ACTIVE ") + 8
      draw_rect(panel_x + pad, cur_y, badge_w, 18, { 85, 65, 20, 255 })
      draw_rect(panel_x + pad, cur_y, badge_w, 1, { 250, 204, 21, 255 })
      renderer.draw_text(fsmall, " TOUR ACTIVE ", math.floor(panel_x + pad + 4), math.floor(cur_y + 2), { 254, 240, 138, 255 })

      local progress_str = string.format("Step %d of %d", s_idx, #steps)
      local pw = fsmall:get_width(progress_str)
      renderer.draw_text(fsmall, progress_str, math.floor(panel_x + pad + content_w - pw), math.floor(cur_y + 2), { 220, 230, 245, 255 })
      cur_y = cur_y + 24

      draw_rect(panel_x + pad, cur_y, content_w, 24, { 35, 30, 22, 220 })
      draw_rect(panel_x + pad, cur_y, 2, 24, { 250, 204, 21, 255 })
      renderer.draw_text(fsmall, truncate(curr_tour.name or "Architecture Tour", fsmall, content_w - 16), math.floor(panel_x + pad + 8), math.floor(cur_y + 5), { 254, 240, 138, 255 })
      cur_y = cur_y + 30

      local step_data = steps[s_idx]
      local step_node_id = step_data and step_data.node_id or "N/A"
      local step_desc = step_data and step_data.desc or "Core architecture component and data flow."

      draw_rect(panel_x + pad, cur_y, content_w, 64, { 24, 28, 38, 220 })
      draw_rect(panel_x + pad, cur_y, content_w, 1, { 60, 75, 105, 255 })
      draw_rect(panel_x + pad, cur_y, 3, 64, { 56, 189, 248, 255 })

      renderer.draw_text(fsmall, "Focus Component:", math.floor(panel_x + pad + 8), math.floor(cur_y + 6), { 140, 160, 190, 255 })
      renderer.draw_text(font, step_node_id, math.floor(panel_x + pad + 8), math.floor(cur_y + 20), { 255, 255, 255, 255 })
      renderer.draw_text(fsmall, truncate(step_desc, fsmall, content_w - 16), math.floor(panel_x + pad + 8), math.floor(cur_y + 42), COLORS.node_subtext)
      cur_y = cur_y + 72

      local btn_w = math.floor((content_w - 8) / 2)
      local nav_h = 26

      local prev_hov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, btn_w, nav_h)
      draw_rect(panel_x + pad, cur_y, btn_w, nav_h, prev_hov and { 55, 45, 25, 255 } or { 36, 32, 24, 220 })
      draw_rect(panel_x + pad, cur_y, btn_w, 1, prev_hov and { 250, 204, 21, 255 } or { 140, 110, 30, 255 })
      local plbl = "< Prev Step"
      local plw = fsmall:get_width(plbl)
      renderer.draw_text(fsmall, plbl, math.floor(panel_x + pad + (btn_w - plw) / 2), math.floor(cur_y + (nav_h - fsmall:get_height()) / 2), prev_hov and { 255, 255, 255, 255 } or { 240, 220, 160, 255 })
      hit_rects.tour_controls.prev = { x = panel_x + pad, y = cur_y, w = btn_w, h = nav_h }

      local next_x = panel_x + pad + btn_w + 8
      local next_hov = is_hovered(mouse_x, mouse_y, next_x, cur_y, btn_w, nav_h)
      draw_rect(next_x, cur_y, btn_w, nav_h, next_hov and { 85, 65, 20, 255 } or { 48, 40, 20, 220 })
      draw_rect(next_x, cur_y, btn_w, 1, next_hov and { 250, 204, 21, 255 } or { 180, 140, 30, 255 })
      local nlbl = "Next Step >"
      local nlw = fsmall:get_width(nlbl)
      renderer.draw_text(fsmall, nlbl, math.floor(next_x + (btn_w - nlw) / 2), math.floor(cur_y + (nav_h - fsmall:get_height()) / 2), next_hov and { 255, 255, 255, 255 } or { 254, 240, 138, 255 })
      hit_rects.tour_controls.next = { x = next_x, y = cur_y, w = btn_w, h = nav_h }

      cur_y = cur_y + nav_h + 10

      local exit_h = 24
      local exit_hov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, exit_h)
      draw_rect(panel_x + pad, cur_y, content_w, exit_h, exit_hov and { 65, 30, 40, 255 } or { 38, 24, 32, 220 })
      draw_rect(panel_x + pad, cur_y, content_w, 1, exit_hov and { 244, 63, 94, 255 } or { 140, 50, 70, 255 })
      local elbl = "X Exit Guided Tour"
      local elw = fsmall:get_width(elbl)
      renderer.draw_text(fsmall, elbl, math.floor(panel_x + pad + (content_w - elw) / 2), math.floor(cur_y + (exit_h - fsmall:get_height()) / 2), exit_hov and { 255, 220, 230, 255 } or { 220, 160, 180, 255 })
      hit_rects.tour_controls.exit = { x = panel_x + pad, y = cur_y, w = content_w, h = exit_h }
      cur_y = cur_y + exit_h + 12

      renderer.draw_text(fsmall, "Keyboard: Left/Right arrows or Esc", math.floor(panel_x + pad), math.floor(cur_y), { 140, 150, 175, 200 })
    end

  elseif active_tab == "flow" then
    draw_section_label("PATH TRACE & DATA FLOW")

    local tbtn_h = 24
    local thov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, tbtn_h)
    draw_rect(panel_x + pad, cur_y, content_w, tbtn_h, thov and { 24, 62, 75, 255 } or { 16, 44, 54, 255 })
    draw_rect(panel_x + pad, cur_y, content_w, 1, thov and { 34, 211, 238, 255 } or { 20, 120, 140, 255 })
    local t_lbl = "Trace Flow Between Nodes"
    renderer.draw_text(fsmall, t_lbl, math.floor(panel_x + pad + (content_w - fsmall:get_width(t_lbl)) / 2), math.floor(cur_y + (tbtn_h - fsmall:get_height()) / 2), { 180, 245, 255, 255 })
    hit_rects.flow_controls.trace = { x = panel_x + pad, y = cur_y, w = content_w, h = tbtn_h }
    cur_y = cur_y + tbtn_h + 10

    if view.flow_trace then
      local fl = view.flow_trace
      draw_rect(panel_x + pad, cur_y, content_w, 46, { 14, 38, 48, 255 })
      draw_rect(panel_x + pad, cur_y, content_w, 1, { 34, 211, 238, 255 })
      renderer.draw_text(fsmall, string.format("Flow: %s -> %s", fl.source, fl.target), math.floor(panel_x + pad + 6), math.floor(cur_y + 6), { 200, 245, 255, 255 })
      renderer.draw_text(fsmall, string.format("Hops: %d (%s)", fl.hops or 0, fl.is_direct and "Direct" or "Bi-dir"), math.floor(panel_x + pad + 6), math.floor(cur_y + 24), { 140, 215, 240, 255 })
      cur_y = cur_y + 52

      local clr_hov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, 22)
      draw_rect(panel_x + pad, cur_y, content_w, 22, clr_hov and { 60, 30, 40, 255 } or { 40, 24, 32, 255 })
      renderer.draw_text(fsmall, "X Clear Flow Trace", math.floor(panel_x + pad + 12), math.floor(cur_y + 4), { 255, 170, 180, 255 })
      hit_rects.flow_controls.clear = { x = panel_x + pad, y = cur_y, w = content_w, h = 22 }
      cur_y = cur_y + 30
    end

    draw_separator()
    draw_section_label("VIEW & NAVIGATION")

    local function draw_view_btn(lbl, key)
      local bh = 24
      local bhov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, bh)
      draw_rect(panel_x + pad, cur_y, content_w, bh, bhov and { 45, 55, 75, 255 } or { 28, 34, 46, 255 })
      draw_rect(panel_x + pad, cur_y, content_w, 1, bhov and { 130, 170, 240, 255 } or { 50, 65, 90, 255 })
      renderer.draw_text(fsmall, lbl, math.floor(panel_x + pad + (content_w - fsmall:get_width(lbl)) / 2), math.floor(cur_y + (bh - fsmall:get_height()) / 2), { 220, 235, 255, 255 })
      hit_rects.flow_controls[key] = { x = panel_x + pad, y = cur_y, w = content_w, h = bh }
      cur_y = cur_y + bh + 6
    end

    draw_view_btn(view.heatmap_mode and "Heatmap: ON" or "Heatmap: OFF", "heatmap")
    draw_view_btn(view.story_mode and "Tour: Active" or "Start Guided Tour", "tour")
    draw_view_btn("Fit Diagram to Screen", "fit")

  -- TAB 6: ACTIONS & EXPORT
  elseif active_tab == "actions" then
    draw_section_label("CODEBASE ANALYSIS")

    local rbtn_h = 28
    local rhov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, rbtn_h)
    local rbg = rhov and { 45, 60, 85, 255 } or { 28, 38, 56, 255 }
    local rbdr = rhov and { 130, 180, 255, 255 } or { 60, 85, 130, 255 }
    draw_rect(panel_x + pad, cur_y, content_w, rbtn_h, rbg)
    draw_rect(panel_x + pad, cur_y, content_w, 1, rbdr)
    local r_lbl = "Re-Analyze Codebase"
    renderer.draw_text(font, r_lbl, math.floor(panel_x + pad + (content_w - font:get_width(r_lbl)) / 2), math.floor(cur_y + (rbtn_h - font:get_height()) / 2), rhov and { 255, 255, 255, 255 } or { 220, 240, 255, 255 })
    hit_rects.action_controls.reanalyze = { x = panel_x + pad, y = cur_y, w = content_w, h = rbtn_h }
    cur_y = cur_y + rbtn_h + 4

    renderer.draw_text(fsmall, "Re-scans AST imports & architecture.", math.floor(panel_x + pad + 2), math.floor(cur_y), { 120, 140, 175, 220 })
    cur_y = cur_y + fsmall:get_height() + 8

    -- Sanitize & Purge Cache button
    local cbtn_h = 24
    local chov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, cbtn_h)
    local cbg = chov and { 65, 32, 32, 255 } or { 42, 22, 22, 255 }
    local cbdr = chov and { 244, 63, 94, 255 } or { 150, 45, 60, 255 }
    draw_rect(panel_x + pad, cur_y, content_w, cbtn_h, cbg)
    draw_rect(panel_x + pad, cur_y, content_w, 1, cbdr)
    local c_lbl = "Purge & Sanitize Cache"
    renderer.draw_text(fsmall, c_lbl, math.floor(panel_x + pad + (content_w - fsmall:get_width(c_lbl)) / 2), math.floor(cur_y + (cbtn_h - fsmall:get_height()) / 2), chov and { 255, 220, 225, 255 } or { 240, 180, 190, 255 })
    hit_rects.action_controls.clean_cache = { x = panel_x + pad, y = cur_y, w = content_w, h = cbtn_h }
    cur_y = cur_y + cbtn_h + 4

    renderer.draw_text(fsmall, "Wipes stale caches & temp files.", math.floor(panel_x + pad + 2), math.floor(cur_y), { 140, 120, 125, 200 })
    cur_y = cur_y + fsmall:get_height() + 10

    local show_sug = (view and view.show_suggested_nodes ~= false)
    local tog_w = content_w
    local tog_h = 28
    local tog_hov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, tog_w, tog_h)
    local tog_bg  = show_sug and (tog_hov and { 45, 60, 85, 255 } or { 30, 42, 62, 255 })
                             or (tog_hov and { 60, 40, 25, 255 } or { 40, 28, 18, 255 })
    local tog_bdr = show_sug and { 56, 189, 248, 255 } or { 245, 158, 11, 255 }
    draw_rect(panel_x + pad, cur_y, tog_w, tog_h, tog_bg)
    draw_rect(panel_x + pad, cur_y, tog_w, 1, tog_bdr)
    local tog_label = show_sug and "[*] AI Suggestions: ON" or "[*] AI Suggestions: HIDDEN"
    local tog_col = show_sug and { 220, 240, 255, 255 } or { 254, 240, 138, 255 }
    renderer.draw_text(fsmall, tog_label, math.floor(panel_x + pad + 10), math.floor(cur_y + (tog_h - fsmall:get_height()) / 2), tog_col)
    hit_rects.action_controls.toggle_suggestions = { x = panel_x + pad, y = cur_y, w = tog_w, h = tog_h }
    cur_y = cur_y + tog_h + 8

    draw_separator()
    draw_section_label("EXPORT & DOCUMENTATION")

    -- Export SVG button
    local sbtn_h = 28
    local shov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, sbtn_h)
    local sbg = shov and COLORS.btn_primary_hover or COLORS.btn_primary
    draw_rect(panel_x + pad, cur_y, content_w, sbtn_h, sbg)
    draw_rect(panel_x + pad, cur_y, content_w, 1, shov and { 140, 215, 255, 255 } or { 80, 150, 230, 255 })
    local s_lbl = "Export SVG Diagram"
    renderer.draw_text(font, s_lbl, math.floor(panel_x + pad + (content_w - font:get_width(s_lbl)) / 2), math.floor(cur_y + (sbtn_h - font:get_height()) / 2), { 255, 255, 255, 255 })
    hit_rects.action_controls.export_svg = { x = panel_x + pad, y = cur_y, w = content_w, h = sbtn_h }
    cur_y = cur_y + sbtn_h + 4

    renderer.draw_text(fsmall, "Crisp vector (.svg) with styles.", math.floor(panel_x + pad + 2), math.floor(cur_y), { 120, 140, 175, 220 })
    cur_y = cur_y + fsmall:get_height() + 12

    -- Export Guide MD button
    local gbtn_h = 28
    local ghov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, content_w, gbtn_h)
    local gbg = ghov and { 36, 68, 56, 255 } or { 24, 48, 40, 255 }
    local gbdr = ghov and { 52, 211, 153, 255 } or { 35, 120, 85, 255 }
    draw_rect(panel_x + pad, cur_y, content_w, gbtn_h, gbg)
    draw_rect(panel_x + pad, cur_y, content_w, 1, gbdr)
    local g_lbl = "Export Guide (MD)"
    renderer.draw_text(font, g_lbl, math.floor(panel_x + pad + (content_w - font:get_width(g_lbl)) / 2), math.floor(cur_y + (gbtn_h - font:get_height()) / 2), ghov and { 255, 255, 255, 255 } or { 200, 250, 230, 255 })
    hit_rects.action_controls.export_guide = { x = panel_x + pad, y = cur_y, w = content_w, h = gbtn_h }
    cur_y = cur_y + gbtn_h + 4

    renderer.draw_text(fsmall, "Markdown onboarding documentation.", math.floor(panel_x + pad + 2), math.floor(cur_y), { 120, 140, 175, 220 })
    cur_y = cur_y + fsmall:get_height() + 14

    draw_separator()
    draw_section_label("VIEWPORT")

    local vbtn_w = math.floor((content_w - 6) / 2)
    local vbtn_h = 24
    local fhov = is_hovered(mouse_x, mouse_y, panel_x + pad, cur_y, vbtn_w, vbtn_h)
    draw_rect(panel_x + pad, cur_y, vbtn_w, vbtn_h, fhov and { 45, 55, 75, 255 } or { 28, 34, 46, 255 })
    draw_rect(panel_x + pad, cur_y, vbtn_w, 1, fhov and { 130, 170, 240, 255 } or { 50, 65, 90, 255 })
    local f_lbl = "Fit View"
    renderer.draw_text(fsmall, f_lbl, math.floor(panel_x + pad + (vbtn_w - fsmall:get_width(f_lbl)) / 2), math.floor(cur_y + (vbtn_h - fsmall:get_height()) / 2), { 220, 235, 255, 255 })
    hit_rects.action_controls.fit = { x = panel_x + pad, y = cur_y, w = vbtn_w, h = vbtn_h }

    local zhov = is_hovered(mouse_x, mouse_y, panel_x + pad + vbtn_w + 6, cur_y, vbtn_w, vbtn_h)
    draw_rect(panel_x + pad + vbtn_w + 6, cur_y, vbtn_w, vbtn_h, zhov and { 45, 55, 75, 255 } or { 28, 34, 46, 255 })
    draw_rect(panel_x + pad + vbtn_w + 6, cur_y, vbtn_w, 1, zhov and { 130, 170, 240, 255 } or { 50, 65, 90, 255 })
    local z_lbl = "100% Zoom"
    renderer.draw_text(fsmall, z_lbl, math.floor(panel_x + pad + vbtn_w + 6 + (vbtn_w - fsmall:get_width(z_lbl)) / 2), math.floor(cur_y + (vbtn_h - fsmall:get_height()) / 2), { 220, 235, 255, 255 })
    hit_rects.action_controls.zoom100 = { x = panel_x + pad + vbtn_w + 6, y = cur_y, w = vbtn_w, h = vbtn_h }
  end

  -- Floating tooltip drawn on top
  if tooltip_to_draw then
    local tw = fsmall:get_width(tooltip_to_draw.text) + 16
    local th = 22
    local tx = tooltip_to_draw.x
    local ty = tooltip_to_draw.y
    draw_rect(tx + 2, ty + 2, tw, th, { 0, 0, 0, 130 })
    draw_rect(tx,     ty,     tw, th, { 26, 32, 44, 250 })
    draw_rect(tx,     ty,     tw, 1,  { 70, 95, 150, 255 })
    renderer.draw_text(fsmall, tooltip_to_draw.text, math.floor(tx + 8), math.floor(ty + (th - fsmall:get_height()) / 2), { 235, 245, 255, 255 })
  end

  return hit_rects
end

function DiagramRenderer.draw(view, nodes, edges, pan_x, pan_y, scale, hovered_node)
  local x, y, w, h = view:get_content_bounds()
  local font       = style.font
  local font_small = style.code_font

  local search_matches   = view and view.search_matches
  local search_match_idx = view and view.search_match_idx

  draw_edges(nodes, edges, pan_x, pan_y, scale, hovered_node, font_small, search_matches, view)
  draw_nodes(nodes, edges, pan_x, pan_y, scale, hovered_node, font, font_small, search_matches, search_match_idx, view)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw tooltip for a hovered node
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.draw_tooltip(view, node, edges, mx, my)
  if not node then return end
  if type(edges) == "number" then
    my = mx
    mx = edges
    edges = nil
  end
  local font   = style.font
  local fsmall = style.code_font

  local in_cnt = 0
  local out_cnt = 0
  for _, e in ipairs(edges or {}) do
    if e.to == node.id then in_cnt = in_cnt + 1 end
    if e.from == node.id then out_cnt = out_cnt + 1 end
  end
  local total_deg = in_cnt + out_cnt

  local role = "Standard Mesh Component"
  if in_cnt == 0 and out_cnt > 0 then
    role = "Edge Ingress / Entrypoint (Fan-Out Only)"
  elseif out_cnt == 0 and in_cnt > 0 then
    role = "Terminal Sink / Leaf (Fan-In Only)"
  elseif in_cnt >= 3 and out_cnt <= 1 then
    role = "Core Hub / Shared Resource (High Fan-In)"
  elseif out_cnt >= 3 and in_cnt <= 1 then
    role = "Orchestrator / Dispatcher (High Fan-Out)"
  elseif in_cnt >= 2 and out_cnt >= 2 then
    role = "Central Mesh Coordinator"
  end

  local lines = {
    { text = node.label or node.id, color = COLORS.tooltip_text, font = font },
    { text = string.format("Wiring: %d callers in  ->  %d deps out (Total: %d)", in_cnt, out_cnt, total_deg), color = { 130, 220, 255, 255 }, font = fsmall },
    { text = "Role: " .. role, color = { 255, 215, 110, 255 }, font = fsmall },
  }

  if node.tier and #node.tier > 0 then
    table.insert(lines, { text = "Tier: " .. node.tier:upper() .. (node.external and " (Cloud/External)" or ""), color = COLORS.tooltip_meta, font = fsmall })
  end
  if node.tech and #node.tech > 0 then
    table.insert(lines, { text = "Tech: " .. node.tech, color = COLORS.status_text, font = fsmall })
  end
  if node.type and #node.type > 0 then
    table.insert(lines, { text = "Type: " .. node.type, color = COLORS.status_text, font = fsmall })
  end
  if node.desc and #node.desc > 0 then
    table.insert(lines, { text = "Summary: " .. node.desc, color = COLORS.tooltip_sub, font = fsmall })
  end
  local is_sug_node = (node.suggested == true or (node.external == true and (not node.file or node.file == "")) or (not node.file or node.file == ""))
  if node.file and not node.external and not is_sug_node then
    table.insert(lines, { text = "File: " .. node.file .. ":" .. (node.line or 1) .. " ([CODE] Verified in repo)", color = COLORS.tooltip_meta, font = fsmall })
  elseif is_sug_node then
    table.insert(lines, { text = "[SUGGESTION] AI Architecture Suggestion (Inferred)", color = { 254, 240, 138, 255 }, font = fsmall })
  elseif node.external then
    table.insert(lines, { text = "[CLOUD] Managed Cloud / Service", color = COLORS.tooltip_meta, font = fsmall })
  end

  local pad    = 8
  local line_h = fsmall:get_height() + 4
  local max_w  = 0
  for _, item in ipairs(lines) do
    local lw = (item.font or fsmall):get_width(item.text)
    if lw > max_w then max_w = lw end
  end
  local tw = max_w + pad * 2
  local th = (#lines - 1) * line_h + font:get_height() + pad * 2 + 4

  local vx, vy, vw, vh = view:get_content_bounds()
  local tx = mx + 14
  local ty = my - th - 6
  if tx + tw > vx + vw then tx = mx - tw - 6 end
  if ty < vy then ty = my + 20 end

  draw_rect(tx, ty, tw, th, COLORS.tooltip_bg)
  draw_rect(tx, ty, tw, 2, COLORS.tab_active)
  draw_rect(tx - 1, ty - 1, tw + 2, th + 2, COLORS.node_border)

  local cy = ty + pad
  for _, item in ipairs(lines) do
    local lfont = item.font or fsmall
    renderer.draw_text(lfont, item.text, math.floor(tx + pad), math.floor(cy), item.color or COLORS.tooltip_text)
    cy = cy + lfont:get_height() + 3
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw the category tab strip
-- ─────────────────────────────────────────────────────────────────────────────
-- Draw the Left Activity Rail (Vertical Category Icon Tabs)
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.draw_left_rail(view, categories, active_idx, rx, ry, rw, rh, mouse_x, mouse_y)
  local font   = style.font
  local fsmall = style.code_font or font
  local hit_rects = {}
  local tooltip_to_draw = nil

  local is_collapsed = (rw < 100) or (view and view.sidebar_collapsed)

  -- Sidebar panel background
  draw_rect(rx, ry, rw, rh, COLORS.bg_dark)
  draw_rect(rx + rw - 1, ry, 1, rh, COLORS.separator)

  -- Sidebar Header (34px)
  local hdr_h = 34
  draw_rect(rx, ry, rw, hdr_h, { 24, 27, 36, 255 })
  draw_rect(rx, ry + hdr_h - 1, rw, 1, COLORS.separator)

  local toggle_w = 20
  local toggle_h = 20
  local toggle_x = rx + rw - toggle_w - 7
  local toggle_y = ry + (hdr_h - toggle_h) / 2
  local tog_hov = is_hovered(mouse_x, mouse_y, toggle_x, toggle_y, toggle_w, toggle_h)
  draw_rect(toggle_x, toggle_y, toggle_w, toggle_h, tog_hov and { 45, 55, 75, 255 } or { 30, 35, 48, 255 })
  draw_rect(toggle_x, toggle_y, toggle_w, 1, { 60, 75, 105, 255 })

  local tog_sym = is_collapsed and ">" or "<"
  local tsw = fsmall:get_width(tog_sym)
  renderer.draw_text(fsmall, tog_sym, math.floor(toggle_x + (toggle_w - tsw) / 2), math.floor(toggle_y + (toggle_h - fsmall:get_height()) / 2), tog_hov and { 255, 255, 255, 255 } or { 160, 180, 210, 255 })

  hit_rects.toggle_rect = { x = toggle_x, y = toggle_y, w = toggle_w, h = toggle_h }

  if not is_collapsed then
    local title = "VIEWS"
    renderer.draw_text(fsmall, title, math.floor(rx + 12), math.floor(ry + (hdr_h - fsmall:get_height()) / 2), { 150, 175, 215, 255 })

    local cat_count_str = string.format("[%d]", categories and #categories or 0)
    local cw = fsmall:get_width(cat_count_str)
    renderer.draw_text(fsmall, cat_count_str, math.floor(rx + 14 + fsmall:get_width(title)), math.floor(ry + (hdr_h - fsmall:get_height()) / 2), { 100, 120, 155, 200 })
  end

  if not categories or #categories == 0 then return hit_rects end

  local btn_w = rw - 12
  local btn_h = is_collapsed and 44 or 42
  local btn_x = rx + 6
  local cy    = ry + hdr_h + 8

  for i, cat in ipairs(categories) do
    local is_active = (i == active_idx)
    local is_hov = is_hovered(mouse_x, mouse_y, btn_x, cy, btn_w, btn_h)

    -- Container card
    local bg_col     = is_active and { 38, 50, 74, 255 } or (is_hov and { 30, 36, 50, 255 } or { 22, 26, 36, 255 })
    local border_col = is_active and { 70, 105, 165, 255 } or (is_hov and { 50, 65, 95, 255 } or { 32, 38, 52, 255 })
    draw_rect(btn_x, cy, btn_w, btn_h, bg_col)
    draw_rect(btn_x, cy, btn_w, 1, border_col)

    -- Active indicator strip
    if is_active then
      draw_rect(rx, cy + 4, 3, btn_h - 8, { 56, 189, 248, 255 })
    end

    -- Icon styling
    local icon_col = is_active and { 224, 238, 255, 255 } or (is_hov and { 180, 210, 255, 255 } or { 130, 145, 175, 200 })
    local ix = is_collapsed and (btn_x + (btn_w - 20) / 2) or (btn_x + 10)
    local iy = cy + (btn_h - 20) / 2

    -- Render category-specific vector mini-icon (20x20)
    if i == 1 then
      draw_rect(ix,      iy,      9, 8, is_active and { 56, 189, 248, 255 } or icon_col)
      draw_rect(ix + 11, iy,      9, 8, icon_col)
      draw_rect(ix,      iy + 10, 9, 8, icon_col)
      draw_rect(ix + 11, iy + 10, 9, 8, icon_col)
    elseif i == 2 then
      local sc = is_active and { 244, 63, 94, 255 } or icon_col
      draw_rect(ix + 2,  iy + 1,  16, 2, sc)
      draw_rect(ix + 2,  iy + 1,  2, 9, sc)
      draw_rect(ix + 16, iy + 1,  2, 9, sc)
      draw_rect(ix + 4,  iy + 10, 2, 4, sc)
      draw_rect(ix + 14, iy + 10, 2, 4, sc)
      draw_rect(ix + 6,  iy + 14, 2, 3, sc)
      draw_rect(ix + 12, iy + 14, 2, 3, sc)
      draw_rect(ix + 8,  iy + 17, 4, 2, sc)
      draw_rect(ix + 8,  iy + 6,  4, 5, is_active and { 255, 215, 110, 255 } or sc)
    elseif i == 3 then
      local dc = is_active and { 16, 185, 129, 255 } or icon_col
      draw_rect(ix + 2, iy + 2,  16, 4, dc)
      draw_rect(ix + 2, iy + 8,  16, 4, dc)
      draw_rect(ix + 2, iy + 14, 16, 4, dc)
      draw_rect(ix + 1, iy + 2,  2, 16, dc)
      draw_rect(ix + 17, iy + 2, 2, 16, dc)
    elseif i == 4 then
      local cc = is_active and { 168, 85, 247, 255 } or icon_col
      draw_rect(ix + 6,  iy + 6,  8, 8, is_active and { 236, 72, 153, 255 } or cc)
      draw_rect(ix + 1,  iy + 1,  4, 4, cc)
      draw_rect(ix + 15, iy + 1,  4, 4, cc)
      draw_rect(ix + 1,  iy + 15, 4, 4, cc)
      draw_rect(ix + 15, iy + 15, 4, 4, cc)
    elseif i == 5 then
      local fc = is_active and { 245, 158, 11, 255 } or icon_col
      draw_rect(ix + 1,  iy + 3,  13, 2, fc)
      draw_rect(ix + 14, iy + 2,  3, 4, fc)
      draw_rect(ix + 4,  iy + 9,  13, 2, fc)
      draw_rect(ix + 17, iy + 8,  3, 4, fc)
      draw_rect(ix + 1,  iy + 15, 13, 2, fc)
      draw_rect(ix + 14, iy + 14, 3, 4, fc)
    else
      local bc = is_active and { 236, 72, 153, 255 } or icon_col
      draw_rect(ix + 1,  iy + 3,  18, 2, bc)
      draw_rect(ix + 1,  iy + 15, 18, 2, bc)
      draw_rect(ix + 3,  iy + 7,  3, 6, is_active and { 255, 215, 110, 255 } or bc)
      draw_rect(ix + 8,  iy + 7,  3, 6, bc)
      draw_rect(ix + 13, iy + 7,  3, 6, is_active and { 56, 189, 248, 255 } or bc)
    end

    if is_collapsed then
      -- Shortcut number in collapsed mode
      local num_str = tostring(i)
      local nw = fsmall:get_width(num_str)
      local nx = btn_x + (btn_w - nw) / 2
      local ny = cy + 27
      renderer.draw_text(fsmall, num_str, math.floor(nx), math.floor(ny), is_active and { 180, 215, 255, 255 } or { 110, 125, 150, 160 })

      if is_hov then
        tooltip_to_draw = {
          text = string.format("%s (Alt+%d)", cat, i),
          x = rx + rw + 8,
          y = cy + (btn_h - 22) / 2
        }
      end
    else
      -- Full readable title in expanded mode
      local max_tw = btn_w - 40 - 45
      local title_str = truncate(cat, fsmall, max_tw)
      local tx = btn_x + 36
      local ty_title = cy + (btn_h - fsmall:get_height()) / 2
      renderer.draw_text(fsmall, title_str, math.floor(tx), math.floor(ty_title), is_active and { 245, 250, 255, 255 } or { 165, 180, 205, 255 })

      -- Alt+N shortcut badge on the right
      local sc_str = string.format("A+%d", i)
      local sc_w   = fsmall:get_width(sc_str) + 6
      local sc_h   = 16
      local sc_x   = btn_x + btn_w - sc_w - 6
      local sc_y   = cy + (btn_h - sc_h) / 2
      draw_rect(sc_x, sc_y, sc_w, sc_h, is_active and { 50, 70, 105, 255 } or { 26, 30, 42, 220 })
      draw_rect(sc_x, sc_y, sc_w, 1,    is_active and { 75, 115, 180, 255 } or { 40, 48, 65, 255 })
      renderer.draw_text(fsmall, sc_str, math.floor(sc_x + 3), math.floor(sc_y + (sc_h - fsmall:get_height()) / 2), is_active and { 180, 225, 255, 255 } or { 110, 130, 160, 200 })
    end

    table.insert(hit_rects, { x = btn_x, y = cy, w = btn_w, h = btn_h, idx = i, name = cat })
    cy = cy + btn_h + 4
  end

  -- Floating tooltip drawn on top (for collapsed mode)
  if tooltip_to_draw then
    local tw = font:get_width(tooltip_to_draw.text) + 16
    local th = 22
    local tx = tooltip_to_draw.x
    local ty = tooltip_to_draw.y
    draw_rect(tx + 2, ty + 2, tw, th, { 0, 0, 0, 120 })
    draw_rect(tx,     ty,     tw, th, { 28, 34, 48, 250 })
    draw_rect(tx,     ty,     tw, 1,  { 70, 95, 150, 255 })
    renderer.draw_text(font, tooltip_to_draw.text, math.floor(tx + 8), math.floor(ty + (th - font:get_height()) / 2), { 235, 245, 255, 255 })
  end

  return hit_rects
end

function DiagramRenderer.draw_tab_strip(view, categories, active_idx, strip_x, strip_y, strip_w)
  return {}
end


-- ─────────────────────────────────────────────────────────────────────────────
-- Draw toolbar (title bar with dynamic viewport & export buttons)
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.draw_toolbar(view, tx, ty, tw, provider, model, node_count, edge_count, scale, mouse_x, mouse_y)
  local font = style.font
  local fsmall = style.code_font or font

  draw_rect(tx, ty, tw, TOOLBAR_H, COLORS.toolbar_bg)
  draw_rect(tx, ty + TOOLBAR_H - 1, tw, 1, COLORS.separator)

  -- Architectural diagram mini-icon (3 nodes connected)
  local icon_x = tx + 10
  local icon_y = ty + (TOOLBAR_H - 12) / 2
  draw_rect(icon_x,     icon_y + 3, 4, 4, { 130, 170, 255, 255 })
  draw_rect(icon_x + 4, icon_y + 4, 5, 2, { 100, 140, 210, 200 })
  draw_rect(icon_x + 9, icon_y,     4, 4, { 100, 220, 150, 255 })
  draw_rect(icon_x + 9, icon_y + 7, 4, 4, { 255, 180, 100, 255 })

  -- Active Category Title with Alt+N badge
  local active_cat = (view and view.categories and view.categories[view.active_category_idx]) or "Architecture Overview"
  local ty_text = ty + (TOOLBAR_H - font:get_height()) / 2
  local cat_label = string.format("%s", active_cat)
  local cat_w = font:get_width(cat_label)
  renderer.draw_text(font, cat_label, math.floor(icon_x + 18), math.floor(ty_text), { 235, 245, 255, 255 })

  local badge_x = icon_x + 18 + cat_w + 10
  -- Alt+N quick hint pill
  local shortcut_hint = string.format("Alt+%d", (view and view.active_category_idx) or 1)
  local sc_w = fsmall:get_width(shortcut_hint) + 8
  local sc_h = 18
  local sc_y = ty + (TOOLBAR_H - sc_h) / 2
  draw_rect(badge_x, sc_y, sc_w, sc_h, { 35, 45, 65, 200 })
  draw_rect(badge_x, sc_y, sc_w, 1, { 65, 85, 130, 255 })
  renderer.draw_text(fsmall, shortcut_hint, math.floor(badge_x + 4), math.floor(sc_y + (sc_h - fsmall:get_height()) / 2), { 140, 190, 255, 240 })
  badge_x = badge_x + sc_w + 12

  -- Interconnectivity Mesh Density Badge
  if node_count and node_count > 0 then
    local density = (edge_count or 0) / math.max(node_count, 1)
    local mesh_label = string.format("Mesh: %d nodes, %d links (%.1fx)", node_count, edge_count or 0, density)
    local mw = fsmall:get_width(mesh_label) + 12
    local my = ty + (TOOLBAR_H - 20) / 2
    if badge_x + mw < tx + tw - 580 then
      draw_rect(badge_x, my, mw, 20, { 34, 42, 60, 230 })
      draw_rect(badge_x, my, mw, 1,  { 70, 95, 150, 255 })
      renderer.draw_text(fsmall, mesh_label, math.floor(badge_x + 6), math.floor(my + (20 - fsmall:get_height()) / 2), { 145, 215, 255, 255 })
    end
  end

  local btn_y = ty + (TOOLBAR_H - 24) / 2

  -- 1. Fit to Viewport Button [Fit] (Rightmost toolbar action; Export/Guide/Re-analyze moved to Right Activity Rail)
  local fit_label = " Fit "
  local fit_w     = font:get_width(fit_label) + 8
  local fit_x     = tx + tw - fit_w - 8
  local fit_hov   = is_hovered(mouse_x, mouse_y, fit_x, ty, fit_w, TOOLBAR_H)
  draw_rect(fit_x, btn_y, fit_w, 24, fit_hov and COLORS.btn_hover or { 38, 44, 58, 255 })
  draw_rect(fit_x, btn_y, fit_w, 1,  fit_hov and { 130, 170, 240, 255 } or { 55, 68, 95, 255 })
  renderer.draw_text(font, fit_label, math.floor(fit_x + 4), math.floor(btn_y + (24 - font:get_height()) / 2), fit_hov and { 245, 250, 255, 255 } or COLORS.btn_text)

  -- 4. 100% Zoom Button [100%]
  local zoom_pct  = string.format("%.0f%%", (scale or 1.0) * 100)
  local z100_w    = font:get_width(zoom_pct) + 10
  local z100_x    = fit_x - z100_w - 4
  local z100_hov  = is_hovered(mouse_x, mouse_y, z100_x, ty, z100_w, TOOLBAR_H)
  draw_rect(z100_x, btn_y, z100_w, 24, z100_hov and COLORS.btn_hover or { 34, 38, 50, 255 })
  draw_rect(z100_x, btn_y, z100_w, 1,  z100_hov and { 130, 170, 240, 255 } or { 50, 60, 85, 255 })
  renderer.draw_text(font, zoom_pct, math.floor(z100_x + 5), math.floor(btn_y + (24 - font:get_height()) / 2), z100_hov and { 245, 250, 255, 255 } or { 160, 180, 220, 255 })

  -- 5. Zoom In [+] and Zoom Out [-]
  local plus_w   = 22
  local plus_x   = z100_x - plus_w - 4
  local plus_hov = is_hovered(mouse_x, mouse_y, plus_x, ty, plus_w, TOOLBAR_H)
  draw_rect(plus_x, btn_y, plus_w, 24, plus_hov and COLORS.btn_hover or { 34, 38, 50, 255 })
  renderer.draw_text(font, "+", math.floor(plus_x + 6), math.floor(btn_y + (24 - font:get_height()) / 2), plus_hov and { 255, 255, 255, 255 } or COLORS.btn_text)

  local minus_w   = 22
  local minus_x   = plus_x - minus_w - 2
  local minus_hov = is_hovered(mouse_x, mouse_y, minus_x, ty, minus_w, TOOLBAR_H)
  draw_rect(minus_x, btn_y, minus_w, 24, minus_hov and COLORS.btn_hover or { 34, 38, 50, 255 })
  renderer.draw_text(font, "-", math.floor(minus_x + 7), math.floor(btn_y + (24 - font:get_height()) / 2), minus_hov and { 255, 255, 255, 255 } or COLORS.btn_text)

  -- 6. Provider & Model Toggle Button
  local prov_name = provider and (provider:sub(1,1):upper() .. provider:sub(2)) or "AI"
  local short_model = model or "default"
  if #short_model > 18 then
    short_model = short_model:match("[^/]+$") or short_model
    if #short_model > 18 then short_model = short_model:sub(1, 15) .. "..." end
  end
  local prov_label = string.format(" AI: %s (%s) ", prov_name, short_model)
  local prov_w     = font:get_width(prov_label) + 18
  local prov_x     = minus_x - prov_w - 8
  local prov_hov   = is_hovered(mouse_x, mouse_y, prov_x, ty, prov_w, TOOLBAR_H)
  draw_rect(prov_x, btn_y, prov_w, 24, prov_hov and { 52, 68, 98, 255 } or { 42, 55, 78, 255 })
  draw_rect(prov_x, btn_y, prov_w, 1,  prov_hov and { 110, 155, 240, 255 } or { 75, 110, 180, 255 })
  renderer.draw_text(font, prov_label, math.floor(prov_x + 5), math.floor(btn_y + (24 - font:get_height()) / 2), { 165, 205, 255, 255 })

  local arrow_x = prov_x + prov_w - 11
  local arrow_y = btn_y + 11
  draw_rect(arrow_x,     arrow_y,     5, 1, { 165, 205, 255, 255 })
  draw_rect(arrow_x + 1, arrow_y + 1, 3, 1, { 165, 205, 255, 255 })
  draw_rect(arrow_x + 2, arrow_y + 2, 1, 1, { 165, 205, 255, 255 })

  -- 7. Search / Find Controls
  local search_query     = (view and view.search_query) or ""
  local search_matches   = (view and view.search_matches) or {}
  local search_match_idx = (view and view.search_match_idx) or 0

  local search_rect       = nil
  local search_clear_rect = nil
  local search_next_rect  = nil
  local search_prev_rect  = nil

  if not search_query or search_query == "" then
    local search_label = (tw > 1050) and " Find (Ctrl+F) " or " Find "
    local search_w     = font:get_width(search_label) + 24
    local search_x     = prov_x - search_w - 8
    local search_hov   = is_hovered(mouse_x, mouse_y, search_x, ty, search_w, TOOLBAR_H)

    draw_rect(search_x, btn_y, search_w, 24, search_hov and COLORS.btn_hover or { 38, 44, 58, 255 })
    draw_rect(search_x, btn_y, search_w, 1,  search_hov and { 130, 170, 240, 255 } or { 60, 75, 105, 255 })

    local gx = search_x + 7
    local gy = btn_y + 8
    local icon_col = search_hov and { 245, 250, 255, 255 } or { 150, 180, 230, 255 }
    draw_rect(gx + 1, gy,     3, 1, icon_col)
    draw_rect(gx + 1, gy + 4, 3, 1, icon_col)
    draw_rect(gx,     gy + 1, 1, 3, icon_col)
    draw_rect(gx + 4, gy + 1, 1, 3, icon_col)
    draw_rect(gx + 4, gy + 4, 2, 2, icon_col)
    draw_rect(gx + 6, gy + 6, 2, 2, icon_col)

    renderer.draw_text(font, search_label, math.floor(search_x + 18), math.floor(btn_y + (24 - font:get_height()) / 2), search_hov and { 245, 250, 255, 255 } or COLORS.btn_text)
    search_rect = { x = search_x - 3, y = ty, w = search_w + 6, h = TOOLBAR_H }
  else
    local match_count = #search_matches
    local match_info  = (match_count > 0) and string.format("%d/%d", search_match_idx, match_count) or "0 matches"
    local q_disp      = search_query
    if #q_disp > 14 then q_disp = q_disp:sub(1, 12) .. "..." end
    local search_label = string.format(" %q (%s) ", q_disp, match_info)

    local search_w   = font:get_width(search_label) + 24
    local search_x   = prov_x - search_w - 8
    local search_hov = is_hovered(mouse_x, mouse_y, search_x, ty, search_w, TOOLBAR_H)

    local pill_bg = (match_count > 0) and (search_hov and { 45, 65, 95, 255 } or { 32, 48, 72, 255 })
                                       or (search_hov and { 70, 40, 40, 255 } or { 55, 30, 30, 255 })
    local pill_border = (match_count > 0) and (search_hov and { 245, 158, 11, 255 } or { 217, 119, 6, 255 })
                                          or (search_hov and { 240, 90, 90, 255 }  or { 180, 60, 60, 255 })
    draw_rect(search_x, btn_y, search_w, 24, pill_bg)
    draw_rect(search_x, btn_y, search_w, 1,  pill_border)

    local gx = search_x + 7
    local gy = btn_y + 8
    local icon_col = (match_count > 0) and { 255, 215, 110, 255 } or { 255, 140, 140, 255 }
    draw_rect(gx + 1, gy,     3, 1, icon_col)
    draw_rect(gx + 1, gy + 4, 3, 1, icon_col)
    draw_rect(gx,     gy + 1, 1, 3, icon_col)
    draw_rect(gx + 4, gy + 1, 1, 3, icon_col)
    draw_rect(gx + 4, gy + 4, 2, 2, icon_col)
    draw_rect(gx + 6, gy + 6, 2, 2, icon_col)

    local text_col = (match_count > 0) and { 255, 230, 150, 255 } or { 255, 170, 170, 255 }
    renderer.draw_text(font, search_label, math.floor(search_x + 18), math.floor(btn_y + (24 - font:get_height()) / 2), text_col)
    search_rect = { x = search_x - 3, y = ty, w = search_w + 6, h = TOOLBAR_H }

    local clr_w   = 20
    local clr_x   = search_x - clr_w - 4
    local clr_hov = is_hovered(mouse_x, mouse_y, clr_x, ty, clr_w, TOOLBAR_H)
    draw_rect(clr_x, btn_y, clr_w, 24, clr_hov and COLORS.btn_hover or { 38, 42, 54, 255 })
    draw_rect(clr_x, btn_y, clr_w, 1,  clr_hov and { 240, 100, 100, 255 } or { 70, 60, 70, 255 })
    renderer.draw_text(font, "x", math.floor(clr_x + 6), math.floor(btn_y + (24 - font:get_height()) / 2), clr_hov and { 255, 100, 100, 255 } or { 200, 120, 120, 255 })
    search_clear_rect = { x = clr_x - 2, y = ty, w = clr_w + 4, h = TOOLBAR_H }

    if match_count > 1 then
      local nxt_w   = 20
      local nxt_x   = clr_x - nxt_w - 3
      local nxt_hov = is_hovered(mouse_x, mouse_y, nxt_x, ty, nxt_w, TOOLBAR_H)
      draw_rect(nxt_x, btn_y, nxt_w, 24, nxt_hov and COLORS.btn_hover or { 38, 42, 54, 255 })
      draw_rect(nxt_x, btn_y, nxt_w, 1,  nxt_hov and { 130, 170, 240, 255 } or { 55, 68, 95, 255 })
      renderer.draw_text(font, ">", math.floor(nxt_x + 6), math.floor(btn_y + (24 - font:get_height()) / 2), nxt_hov and { 255, 255, 255, 255 } or COLORS.btn_text)
      search_next_rect = { x = nxt_x - 2, y = ty, w = nxt_w + 4, h = TOOLBAR_H }

      local prv_w   = 20
      local prv_x   = nxt_x - prv_w - 2
      local prv_hov = is_hovered(mouse_x, mouse_y, prv_x, ty, prv_w, TOOLBAR_H)
      draw_rect(prv_x, btn_y, prv_w, 24, prv_hov and COLORS.btn_hover or { 38, 42, 54, 255 })
      draw_rect(prv_x, btn_y, prv_w, 1,  prv_hov and { 130, 170, 240, 255 } or { 55, 68, 95, 255 })
      renderer.draw_text(font, "<", math.floor(prv_x + 6), math.floor(btn_y + (24 - font:get_height()) / 2), prv_hov and { 255, 255, 255, 255 } or COLORS.btn_text)
      search_prev_rect = { x = prv_x - 2, y = ty, w = prv_w + 4, h = TOOLBAR_H }
    end
  end

  -- Anchor left of search bar
  local search_anchor = (search_rect and search_rect.x or prov_x)
  if search_clear_rect and search_clear_rect.x < search_anchor then
    search_anchor = (search_prev_rect and search_prev_rect.x or (search_clear_rect and search_clear_rect.x or search_rect.x))
  end

  -- 8c. AI Architecture Assistant ("Ask AI") Button (Anchored directly left of search bar)
  local ask_ai_label = (view and view.ai_insight) and ((tw > 1200) and " Ask AI: ON " or " ON ") or ((tw > 1200) and " Ask AI " or " AI ")
  local ask_ai_w     = font:get_width(ask_ai_label) + 12
  local ask_ai_x     = search_anchor - ask_ai_w - 6
  local ask_ai_hov   = is_hovered(mouse_x, mouse_y, ask_ai_x, ty, ask_ai_w, TOOLBAR_H)
  local is_ask_on    = (view and view.ai_insight ~= nil)
  draw_rect(ask_ai_x, btn_y, ask_ai_w, 24, is_ask_on and { 65, 30, 95, 255 } or (ask_ai_hov and { 55, 35, 80, 255 } or { 34, 26, 48, 255 }))
  draw_rect(ask_ai_x, btn_y, ask_ai_w, 1,  is_ask_on and { 192, 132, 252, 255 } or (ask_ai_hov and { 168, 85, 247, 255 } or { 90, 50, 130, 255 }))
  renderer.draw_text(font, ask_ai_label, math.floor(ask_ai_x + 6), math.floor(btn_y + (24 - font:get_height()) / 2), is_ask_on and { 245, 230, 255, 255 } or { 216, 180, 254, 255 })
  local ask_ai_rect = { x = ask_ai_x - 2, y = ty, w = ask_ai_w + 4, h = TOOLBAR_H }

  -- 8e. Architecture Health Doctor / Audit Button
  local audit_label = (view and view.audit_open) and ((tw > 1200) and " Audit: ON " or " ON ") or ((tw > 1200) and " Audit " or " Audit ")
  local audit_w     = font:get_width(audit_label) + 12
  local audit_x     = ask_ai_x - audit_w - 6
  local audit_hov   = is_hovered(mouse_x, mouse_y, audit_x, ty, audit_w, TOOLBAR_H)
  local is_audit_on = (view and view.audit_open)
  draw_rect(audit_x, btn_y, audit_w, 24, is_audit_on and { 20, 65, 55, 255 } or (audit_hov and { 28, 55, 48, 255 } or { 20, 40, 36, 255 }))
  draw_rect(audit_x, btn_y, audit_w, 1,  is_audit_on and { 45, 212, 191, 255 } or (audit_hov and { 20, 184, 166, 255 } or { 30, 95, 85, 255 }))
  renderer.draw_text(font, audit_label, math.floor(audit_x + 6), math.floor(btn_y + (24 - font:get_height()) / 2), is_audit_on and { 230, 255, 250, 255 } or { 153, 246, 228, 255 })
  local audit_rect = { x = audit_x - 2, y = ty, w = audit_w + 4, h = TOOLBAR_H }

  -- 10. Focus Lens / Blast Radius / Flow Trace Indicator Badges
  local focus_exit_rect, impact_exit_rect, flow_exit_rect
  if view and view.flow_trace then
    local fl = view.flow_trace
    local fl_label = string.format(" Flow: %s -> %s (%d hops) [x] ", fl.source, fl.target, fl.hops or 0)
    local fl_w = fsmall:get_width(fl_label) + 10
    local fl_x = badge_x
    draw_rect(fl_x, ty + 6, fl_w, 24, { 14, 52, 60, 255 })
    draw_rect(fl_x, ty + 6, fl_w, 1,  { 34, 211, 238, 255 })
    renderer.draw_text(fsmall, fl_label, math.floor(fl_x + 5), math.floor(ty + 6 + (24 - fsmall:get_height()) / 2), { 165, 243, 252, 255 })
    flow_exit_rect = { x = fl_x, y = ty, w = fl_w, h = TOOLBAR_H }
  elseif view and view.focus_node_id then
    local foc_label = string.format(" Focus: %s [x] ", view.focus_node_id)
    local foc_w = fsmall:get_width(foc_label) + 10
    local foc_x = badge_x
    draw_rect(foc_x, ty + 6, foc_w, 24, { 55, 42, 20, 255 })
    draw_rect(foc_x, ty + 6, foc_w, 1,  { 245, 158, 11, 255 })
    renderer.draw_text(fsmall, foc_label, math.floor(foc_x + 5), math.floor(ty + 6 + (24 - fsmall:get_height()) / 2), { 255, 215, 110, 255 })
    focus_exit_rect = { x = foc_x, y = ty, w = foc_w, h = TOOLBAR_H }
  elseif view and view.impact_data then
    local imp = view.impact_data
    local imp_label = string.format(" Blast Radius: %s (%s RISK) [x] ", imp.target, imp.risk)
    local imp_w = fsmall:get_width(imp_label) + 10
    local imp_x = badge_x
    draw_rect(imp_x, ty + 6, imp_w, 24, { 60, 28, 35, 255 })
    draw_rect(imp_x, ty + 6, imp_w, 1,  { 244, 63, 94, 255 })
    renderer.draw_text(fsmall, imp_label, math.floor(imp_x + 5), math.floor(ty + 6 + (24 - fsmall:get_height()) / 2), { 255, 160, 180, 255 })
    impact_exit_rect = { x = imp_x, y = ty, w = imp_w, h = TOOLBAR_H }
  end

  return {
    export_rect       = {},
    guide_rect        = {},
    reanalyze_rect    = {},
    fit_rect          = { x = fit_x - 2,   y = ty, w = fit_w + 4,   h = TOOLBAR_H },
    zoom100_rect      = { x = z100_x - 2,  y = ty, w = z100_w + 4,  h = TOOLBAR_H },
    zoom_in_rect      = { x = plus_x - 2,  y = ty, w = plus_w + 4,  h = TOOLBAR_H },
    zoom_out_rect     = { x = minus_x - 2, y = ty, w = minus_w + 4, h = TOOLBAR_H },
    provider_rect     = { x = prov_x - 3,  y = ty, w = prov_w + 6,  h = TOOLBAR_H },
    search_rect       = search_rect,
    search_clear_rect = search_clear_rect,
    search_next_rect  = search_next_rect,
    search_prev_rect  = search_prev_rect,
    inspector_rect    = nil,
    heatmap_rect      = nil,
    story_rect        = nil,
    story_next_rect   = nil,
    story_prev_rect   = nil,
    story_exit_rect   = nil,
    ask_ai_rect       = ask_ai_rect,
    audit_rect        = audit_rect,
    flow_exit_rect    = flow_exit_rect,
    focus_exit_rect   = focus_exit_rect,
    impact_exit_rect  = impact_exit_rect,
  }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw status bar at bottom
-- ─────────────────────────────────────────────────────────────────────────────
-- ─────────────────────────────────────────────────────────────────────────────
-- Draw floating AI Architecture Insight Banner
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- Embedded Rich Markdown & Table Compiler
-- Compiles raw markdown text into structured, cached layout blocks
-- (Tables, Headings, Code Blocks, Blockquotes, Lists, and Paragraphs)
-- ─────────────────────────────────────────────────────────────────────────────

local function split_pipe_row(line)
  local cells = {}
  local s = line:gsub("^%s*|", ""):gsub("|%s*$", "")
  local current = {}
  local i = 1
  local len = #s
  while i <= len do
    local c = s:sub(i, i)
    if c == "\\" and i < len and s:sub(i + 1, i + 1) == "|" then
      table.insert(current, "|")
      i = i + 2
    elseif c == "|" then
      local cell = table.concat(current):gsub("^%s+", ""):gsub("%s+$", "")
      table.insert(cells, cell)
      current = {}
      i = i + 1
    else
      table.insert(current, c)
      i = i + 1
    end
  end
  local cell = table.concat(current):gsub("^%s+", ""):gsub("%s+$", "")
  table.insert(cells, cell)
  return cells
end

local function is_table_separator_line(line)
  if not line or not line:find("|") or not line:find("%-") then return false end
  local cells = split_pipe_row(line)
  if #cells == 0 then return false end
  for _, c in ipairs(cells) do
    if not c:match("^%s*:?%-+:?%s*$") then
      return false
    end
  end
  return true
end

local function is_table_start(line, next_line)
  if not line or not next_line then return false end
  if not line:find("|") or not next_line:find("|") then return false end
  local hdr = split_pipe_row(line)
  if #hdr == 0 then return false end
  return is_table_separator_line(next_line)
end

local function extract_alignments(cells)
  local aligns = {}
  for _, c in ipairs(cells) do
    if c:match("^%s*:%-+:%s*$") then
      table.insert(aligns, "center")
    elseif c:match("^%s*%-+:%s*$") then
      table.insert(aligns, "right")
    else
      table.insert(aligns, "left")
    end
  end
  return aligns
end

function DiagramRenderer.compile_rich_markdown(text, font, code_font, max_w)
  if not text or text == "" then
    return { blocks = {}, total_h = 0 }
  end
  text = clean_display_text(text)
  font = font or style.font
  code_font = code_font or style.code_font or font

  local lines = {}
  for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end

  local blocks = {}
  local total_h = 0
  local line_h = font:get_height() + 5
  local code_line_h = code_font:get_height() + 4
  local i = 1
  local n = #lines

  while i <= n do
    local raw_line = lines[i]
    local line = raw_line:gsub("^%s+", ""):gsub("%s+$", "")

    -- 1. Empty spacer line
    if line == "" then
      table.insert(blocks, { type = "spacer", h = 8 })
      total_h = total_h + 8
      i = i + 1

    -- 2. Code Block: ```
    elseif line:sub(1, 3) == "```" then
      local lang = line:sub(4):gsub("^%s+", ""):gsub("%s+$", "")
      local code_lines = {}
      i = i + 1
      while i <= n and lines[i]:gsub("^%s+", ""):sub(1, 3) ~= "```" do
        table.insert(code_lines, lines[i])
        i = i + 1
      end
      if i <= n then i = i + 1 end -- consume closing ```
      local bh = (#code_lines * code_line_h) + 16
      table.insert(blocks, {
        type = "code_block",
        lang = lang,
        lines = code_lines,
        h = bh
      })
      total_h = total_h + bh

    -- 3. Heading: #, ##, ###
    elseif line:sub(1, 1) == "#" then
      local level = 0
      while line:sub(level + 1, level + 1) == "#" do level = level + 1 end
      local title = line:sub(level + 1):gsub("^%s+", ""):gsub("%s+$", "")
      local hh = font:get_height() + 14
      table.insert(blocks, {
        type = "heading",
        level = level,
        text = title,
        h = hh
      })
      total_h = total_h + hh
      i = i + 1

    -- 4. Horizontal Rule: --- or ***
    elseif line:match("^%-%-%-+$") or line:match("^%*%*%*+$") or line:match("^___+$") then
      local hh = 12
      table.insert(blocks, { type = "hr", h = hh })
      total_h = total_h + hh
      i = i + 1

    -- 5. Blockquote: >
    elseif line:sub(1, 1) == ">" then
      local quote_parts = {}
      while i <= n and lines[i]:gsub("^%s+", ""):sub(1, 1) == ">" do
        local ql = lines[i]:gsub("^%s+", ""):sub(2):gsub("^%s+", ""):gsub("%s+$", "")
        if #ql > 0 then table.insert(quote_parts, ql) end
        i = i + 1
      end
      local full_quote = table.concat(quote_parts, " ")
      local wrapped = wrap_insight_text(full_quote, font, max_w - 24)
      local qh = (#wrapped * line_h) + 12
      table.insert(blocks, {
        type = "blockquote",
        lines = wrapped,
        h = qh
      })
      total_h = total_h + qh

    -- 6. Markdown Table: GFM compliant header + separator row
    elseif is_table_start(line, (i + 1 <= n) and lines[i + 1]:gsub("^%s+", ""):gsub("%s+$", "") or nil) then
      local maybe_next = lines[i + 1]:gsub("^%s+", ""):gsub("%s+$", "")
      local header_cells = split_pipe_row(line)
      local sep_cells = split_pipe_row(maybe_next)
      local aligns = extract_alignments(sep_cells)
      local num_cols = #header_cells
      i = i + 2 -- consume header and separator

      local rows = {}
      while i <= n do
        local cur_row = lines[i]:gsub("^%s+", ""):gsub("%s+$", "")
        -- Stop table on empty line, code block, heading, or if line has no pipes
        if cur_row == "" or cur_row:sub(1, 3) == "```" or cur_row:sub(1, 1) == "#" or not cur_row:find("|") then
          break
        end
        -- Also check if cur_row is an accidental separator or hr
        if cur_row:match("^%-%-%-+$") or cur_row:match("^___+$") then
          break
        end
        local r_cells = split_pipe_row(cur_row)
        while #r_cells < num_cols do table.insert(r_cells, "") end
        while #r_cells > num_cols and r_cells[#r_cells] == "" do table.remove(r_cells) end
        table.insert(rows, r_cells)
        i = i + 1
      end

      -- Proportional column width calculation with per-column max caps
      local col_max_w = {}
      local max_single_cell_w = math.max(140, math.floor(max_w * 0.45))
      for c_idx, h in ipairs(header_cells) do
        local clean_h = h:gsub("[%*`%[%]_]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        col_max_w[c_idx] = font:get_width(clean_h) + 24
      end
      for _, row in ipairs(rows) do
        for c_idx = 1, num_cols do
          local cell_val = row[c_idx] or ""
          local clean_val = cell_val:gsub("[%*`%[%]_]", ""):gsub("^%s+", ""):gsub("%s+$", "")
          local cw = math.min(max_single_cell_w, font:get_width(clean_val) + 24)
          if cw > col_max_w[c_idx] then col_max_w[c_idx] = cw end
        end
      end

      local total_col_w = 0
      for _, w in ipairs(col_max_w) do total_col_w = total_col_w + w end

      -- Target table width: don't stretch small 2-3 column tables across empty 800px!
      local table_avail_w
      if total_col_w <= max_w then
        table_avail_w = math.min(max_w, math.max(total_col_w, math.min(360, max_w)))
      else
        table_avail_w = max_w
      end

      local col_widths = {}
      local allocated = 0
      for c_idx, w in ipairs(col_max_w) do
        local cw
        if c_idx == num_cols then
          cw = math.max(65, table_avail_w - allocated)
        else
          cw = math.max(65, math.floor((w / math.max(1, total_col_w)) * table_avail_w))
          allocated = allocated + cw
        end
        table.insert(col_widths, cw)
      end

      local row_h = font:get_height() + 10
      local hdr_h = font:get_height() + 12
      local tbl_h = hdr_h + (#rows * row_h) + 12

      table.insert(blocks, {
        type = "table",
        headers = header_cells,
        aligns = aligns,
        rows = rows,
        col_widths = col_widths,
        total_w = table_avail_w,
        row_h = row_h,
        hdr_h = hdr_h,
        h = tbl_h
      })
      total_h = total_h + tbl_h
      goto continue_scan

    -- 7. List Item: - , * , + , or 1.
    elseif line:match("^[%*%-%+]%s+") or line:match("^%d+%.%s+") then
      local bullet = line:match("^([%*%-%+])%s+") or line:match("^(%d+%.)%s+")
      local content = line:gsub("^[%*%-%+]%s+", ""):gsub("^%d+%.%s+", "")
      local wrapped = wrap_insight_text(content, font, max_w - 24)
      local lh = (#wrapped * line_h) + 4
      table.insert(blocks, {
        type = "list_item",
        bullet = bullet,
        lines = wrapped,
        h = lh
      })
      total_h = total_h + lh
      i = i + 1

    -- 8. Regular Paragraph
    else
      local para_parts = { line }
      i = i + 1
      while i <= n do
        local nxt = lines[i]:gsub("^%s+", ""):gsub("%s+$", "")
        if nxt == "" or nxt:sub(1, 1) == "#" or nxt:sub(1, 3) == "```" or nxt:sub(1, 1) == ">" or nxt:match("^%-%-%-+$") or nxt:match("^%*%*%*+$") or nxt:match("^___+$") or nxt:match("^[%*%-%+]%s+") or nxt:match("^%d+%.%s+") or (nxt:find("|") and i + 1 <= n and is_table_separator_line(lines[i + 1]:gsub("^%s+", ""):gsub("%s+$", ""))) then
          break
        end
        table.insert(para_parts, nxt)
        i = i + 1
      end
      local full_para = table.concat(para_parts, " ")
      local wrapped = wrap_insight_text(full_para, font, max_w)
      local ph = (#wrapped * line_h) + 6
      table.insert(blocks, {
        type = "paragraph",
        lines = wrapped,
        h = ph
      })
      total_h = total_h + ph
    end

    ::continue_scan::
  end

  return {
    blocks = blocks,
    total_h = total_h
  }
end

local function render_inline_chunk(font, text, x, y, max_x, default_col)
  text = clean_display_text(text)
  local pos = 1
  local cur_x = x
  while pos <= #text do
    if max_x and cur_x >= max_x then break end
    local b_start, b_end = text:find("%*%*.-%*%*", pos)
    local c_start, c_end = text:find("`.-`", pos)

    local next_start = math.huge
    local next_type = nil
    if b_start and b_start < next_start then next_start = b_start; next_type = "bold" end
    if c_start and c_start < next_start then next_start = c_start; next_type = "code" end

    if not next_type then
      local chunk = text:sub(pos)
      if max_x and cur_x + font:get_width(chunk) > max_x then
        local avail = max_x - cur_x
        if avail > 10 then
          local truncated = truncate(chunk, font, avail)
          renderer.draw_text(font, truncated, math.floor(cur_x), math.floor(y), default_col)
        end
        cur_x = max_x
        break
      end
      renderer.draw_text(font, chunk, math.floor(cur_x), math.floor(y), default_col)
      cur_x = cur_x + font:get_width(chunk)
      break
    end

    if next_start > pos then
      local chunk = text:sub(pos, next_start - 1)
      if max_x and cur_x + font:get_width(chunk) > max_x then
        local avail = max_x - cur_x
        if avail > 10 then
          local truncated = truncate(chunk, font, avail)
          renderer.draw_text(font, truncated, math.floor(cur_x), math.floor(y), default_col)
        end
        cur_x = max_x
        break
      end
      renderer.draw_text(font, chunk, math.floor(cur_x), math.floor(y), default_col)
      cur_x = cur_x + font:get_width(chunk)
      if max_x and cur_x >= max_x then break end
    end

    if next_type == "bold" then
      local chunk = text:sub(b_start + 2, b_end - 2)
      if max_x and cur_x + font:get_width(chunk) > max_x then
        local avail = max_x - cur_x
        if avail > 10 then
          local truncated = truncate(chunk, font, avail)
          renderer.draw_text(font, truncated, math.floor(cur_x), math.floor(y), { 255, 255, 255, 255 })
        end
        cur_x = max_x
        break
      end
      renderer.draw_text(font, chunk, math.floor(cur_x), math.floor(y), { 255, 255, 255, 255 })
      cur_x = cur_x + font:get_width(chunk)
      pos = b_end + 1
    elseif next_type == "code" then
      local chunk = text:sub(c_start + 1, c_end - 1)
      local cw = font:get_width(chunk)
      local ch = font:get_height()
      if max_x and cur_x + cw + 4 > max_x then
        local avail = max_x - cur_x - 4
        if avail > 10 then
          local truncated = truncate(chunk, font, avail)
          local t_cw = font:get_width(truncated)
          draw_rect(cur_x - 1, y, t_cw + 4, ch, { 45, 32, 60, 220 })
          draw_rect(cur_x - 1, y, t_cw + 4, 1,  { 147, 51, 234, 180 })
          renderer.draw_text(font, truncated, math.floor(cur_x + 1), math.floor(y), { 216, 180, 254, 255 })
        end
        cur_x = max_x
        break
      end
      draw_rect(cur_x - 1, y, cw + 4, ch, { 45, 32, 60, 220 })
      draw_rect(cur_x - 1, y, cw + 4, 1,  { 147, 51, 234, 180 })
      renderer.draw_text(font, chunk, math.floor(cur_x + 1), math.floor(y), { 216, 180, 254, 255 })
      cur_x = cur_x + cw + 4
      pos = c_end + 1
    end
  end
  return cur_x
end

function DiagramRenderer.render_rich_markdown(compiled, start_x, start_y, max_w, view_y, view_h, theme)
  if not compiled or not compiled.blocks then return end
  theme = theme or {}
  local font = theme.font or style.font
  local code_font = theme.code_font or style.code_font or font
  local accent_col = theme.accent or { 192, 132, 252, 255 }
  local text_col = theme.text_col or { 226, 232, 240, 255 }
  local line_h = font:get_height() + 5
  local code_line_h = code_font:get_height() + 4

  local cur_y = start_y
  local bottom_clip = view_y + view_h

  for _, block in ipairs(compiled.blocks) do
    local b_top = cur_y
    local b_bot = cur_y + block.h

    -- Render block only if visible within vertical clip
    if b_bot >= view_y and b_top <= bottom_clip then
      if block.type == "table" then
        local tx = start_x
        local ty = cur_y
        local tw = 0
        for _, w in ipairs(block.col_widths) do tw = tw + w end
        local row_h = block.row_h or (font:get_height() + 10)
        local hdr_h = block.hdr_h or (font:get_height() + 12)
        local tbl_content_h = hdr_h + (#block.rows * row_h)

        -- 1. Table Outer Background & Clean Subtle Border
        draw_rect(tx, ty, tw, tbl_content_h, { 18, 15, 27, 235 })
        draw_rect(tx, ty, tw, 1, { 70, 52, 98, 220 })
        draw_rect(tx, ty + tbl_content_h - 1, tw, 1, { 70, 52, 98, 220 })
        draw_rect(tx, ty, 1, tbl_content_h, { 70, 52, 98, 220 })
        draw_rect(tx + tw - 1, ty, 1, tbl_content_h, { 70, 52, 98, 220 })
        -- Top neon accent line:
        draw_rect(tx, ty, tw, 2, accent_col)

        -- 2. Header Row Background
        draw_rect(tx, ty + 2, tw, hdr_h - 2, { 32, 24, 48, 255 })
        draw_rect(tx, ty + hdr_h - 1, tw, 1, { 120, 80, 180, 180 })

        -- 3. Draw Header Cells & Vertical Dividers
        local hx = tx
        for c_idx, h_text in ipairs(block.headers) do
          local cw = block.col_widths[c_idx] or 80
          local align = (block.aligns and block.aligns[c_idx]) or "left"

          -- Vertical divider (between columns only)
          if c_idx < #block.headers then
            draw_rect(hx + cw - 1, ty + 2, 1, hdr_h - 2, { 75, 55, 105, 150 })
          end

          -- Cell text positioning with alignment
          local clean_h = h_text:gsub("[%*`%[%]_]", "")
          local tw_text = font:get_width(clean_h)
          local text_x
          if align == "center" then
            text_x = math.max(hx + 6, hx + math.floor((cw - tw_text) / 2))
          elseif align == "right" then
            text_x = math.max(hx + 6, hx + cw - tw_text - 10)
          else
            text_x = hx + 8
          end

          core.push_clip_rect(hx + 2, ty, cw - 4, hdr_h)
          render_inline_chunk(font, h_text, text_x, ty + math.floor((hdr_h - font:get_height()) / 2), hx + cw - 4, { 240, 225, 255, 255 })
          core.pop_clip_rect()

          hx = hx + cw
        end

        -- 4. Draw Data Rows
        local ry = ty + hdr_h
        for r_idx, row in ipairs(block.rows) do
          local is_odd = (r_idx % 2 == 1)
          local bg_col = is_odd and { 22, 18, 34, 190 } or { 26, 21, 40, 190 }
          draw_rect(tx, ry, tw, row_h, bg_col)

          -- Row bottom border (except last row)
          if r_idx < #block.rows then
            draw_rect(tx, ry + row_h - 1, tw, 1, { 48, 36, 68, 120 })
          end

          local cx = tx
          for c_idx = 1, #block.headers do
            local cw = block.col_widths[c_idx] or 80
            local val = row[c_idx] or ""
            local align = (block.aligns and block.aligns[c_idx]) or "left"

            -- Vertical divider (internal columns only)
            if c_idx < #block.headers then
              draw_rect(cx + cw - 1, ry, 1, row_h, { 55, 40, 75, 100 })
            end

            -- Clean string for status matching & badge width
            local clean_val = val:gsub("[%*`%[%]_]", ""):gsub("^%s+", ""):gsub("%s+$", "")
            local lval = clean_val:lower()

            -- Status badge color schemes
            local is_badge = false
            local badge_bg, badge_border, badge_text
            if lval == "critical" or lval == "severe" or lval == "fail" or lval == "failed" or lval == "error" or lval == "danger" then
              is_badge = true
              badge_bg     = { 85, 20, 35, 230 }
              badge_border = { 244, 63, 94, 255 }
              badge_text   = { 255, 205, 215, 255 }
            elseif lval == "warning" or lval == "warn" or lval == "bottleneck" or lval == "high" or lval == "medium" or lval == "degraded" or lval == "caution" then
              is_badge = true
              badge_bg     = { 85, 55, 18, 230 }
              badge_border = { 245, 158, 11, 255 }
              badge_text   = { 254, 240, 200, 255 }
            elseif lval == "healthy" or lval == "active" or lval == "ok" or lval == "pass" or lval == "passed" or lval == "optimal" or lval == "low" or lval == "good" or lval == "ready" then
              is_badge = true
              badge_bg     = { 18, 70, 48, 230 }
              badge_border = { 16, 185, 129, 255 }
              badge_text   = { 210, 255, 235, 255 }
            elseif lval == "primary" or lval == "cloud" or lval == "edge" or lval == "service" or lval == "ingress" or lval == "info" or lval == "core" then
              is_badge = true
              badge_bg     = { 24, 45, 80, 230 }
              badge_border = { 59, 130, 246, 255 }
              badge_text   = { 200, 230, 255, 255 }
            end

            core.push_clip_rect(cx + 2, ry, cw - 4, row_h)

            if is_badge then
              local pw = font:get_width(clean_val) + 14
              local ph = row_h - 6
              local px
              if align == "center" then
                px = math.max(cx + 4, cx + math.floor((cw - pw) / 2))
              elseif align == "right" then
                px = math.max(cx + 4, cx + cw - pw - 8)
              else
                px = cx + 6
              end
              local py = ry + 3
              draw_rect(px, py, pw, ph, badge_bg)
              draw_rect(px, py, pw, 1, badge_border)
              draw_rect(px, py + ph - 1, pw, 1, badge_border)
              draw_rect(px, py, 1, ph, badge_border)
              draw_rect(px + pw - 1, py, 1, ph, badge_border)
              renderer.draw_text(font, clean_val, math.floor(px + 7), math.floor(py + math.floor((ph - font:get_height()) / 2)), badge_text)
            else
              local text_w = font:get_width(clean_val)
              local text_x
              if align == "center" then
                text_x = math.max(cx + 6, cx + math.floor((cw - text_w) / 2))
              elseif align == "right" then
                text_x = math.max(cx + 6, cx + cw - text_w - 8)
              else
                text_x = cx + 8
              end
              render_inline_chunk(font, val, text_x, ry + math.floor((row_h - font:get_height()) / 2), cx + cw - 4, text_col)
            end

            core.pop_clip_rect()

            cx = cx + cw
          end
          ry = ry + row_h
        end

      elseif block.type == "heading" then
        local hcol = (block.level == 1) and { 235, 215, 255, 255 } or ((block.level == 2) and { 216, 180, 254, 255 } or { 192, 132, 252, 255 })
        render_inline_chunk(font, block.text, start_x, cur_y + 2, start_x + max_w, hcol)
        draw_rect(start_x, cur_y + block.h - 4, max_w, 1, { 70, 50, 95, 160 })

      elseif block.type == "code_block" then
        draw_rect(start_x, cur_y, max_w, block.h - 4, { 15, 13, 22, 245 })
        draw_rect(start_x, cur_y, max_w, 1, { 55, 42, 75, 200 })
        draw_rect(start_x, cur_y + block.h - 5, max_w, 1, { 55, 42, 75, 200 })
        draw_rect(start_x, cur_y, 1, block.h - 4, { 55, 42, 75, 200 })
        draw_rect(start_x + max_w - 1, cur_y, 1, block.h - 4, { 55, 42, 75, 200 })

        local cy = cur_y + 8
        for _, cl in ipairs(block.lines) do
          renderer.draw_text(code_font, cl, math.floor(start_x + 10), math.floor(cy), { 186, 230, 253, 255 })
          cy = cy + code_line_h
        end

      elseif block.type == "blockquote" then
        draw_rect(start_x, cur_y, max_w, block.h - 4, { 28, 22, 40, 180 })
        draw_rect(start_x, cur_y, 3, block.h - 4, accent_col)
        local qy = cur_y + 6
        for _, ql in ipairs(block.lines) do
          render_inline_chunk(font, ql, start_x + 12, qy, start_x + max_w - 10, { 220, 210, 240, 255 })
          qy = qy + line_h
        end

      elseif block.type == "list_item" then
        renderer.draw_text(font, block.bullet or "-", math.floor(start_x + 4), math.floor(cur_y + 2), accent_col)
        local ly = cur_y + 2
        for _, ll in ipairs(block.lines) do
          render_inline_chunk(font, ll, start_x + 20, ly, start_x + max_w, text_col)
          ly = ly + line_h
        end

      elseif block.type == "paragraph" then
        local py = cur_y + 2
        for _, pl in ipairs(block.lines) do
          render_inline_chunk(font, pl, start_x, py, start_x + max_w, text_col)
          py = py + line_h
        end

      elseif block.type == "hr" then
        local my = cur_y + math.floor(block.h / 2)
        draw_rect(start_x, my, max_w, 1, { 65, 50, 85, 200 })
      end
    end

    cur_y = cur_y + block.h
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw floating AI Architecture Insight Banner / Enlarged Card Component
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.draw_ai_insight_banner(view, insight, bx, by, bw, bh, mouse_x, mouse_y)
  local font   = style.font
  local fsmall = style.code_font or font

  -- Loading State Banner
  if view and view.ai_insight_loading then
    local banner_h = 56
    local banner_y = by + bh - banner_h - 6
    local banner_x = bx + 20
    local banner_w = bw - 40
    draw_rect(banner_x + 2, banner_y + 2, banner_w, banner_h, { 0, 0, 0, 140 })
    draw_rect(banner_x,     banner_y,     banner_w, banner_h, { 26, 18, 38, 252 })
    draw_rect(banner_x,     banner_y,     banner_w, 2,        { 192, 132, 252, 255 })

    local spin_chars = { "|", "/", "-", "\\" }
    local spin_idx = math.floor((system.get_time() * 6) % 4) + 1
    local spin_icon = spin_chars[spin_idx] or "*"

    local l_title = string.format("[%s] QUERYING ARCHITECTURE AI...", spin_icon)
    renderer.draw_text(font, l_title, math.floor(banner_x + 14), math.floor(banner_y + 8), { 216, 180, 254, 255 })

    local q_sub = truncate(string.format("Analyzing: \"%s\" (reasoning across topological graph using %s...)", view.ai_insight_query or "Query", (view.provider or "AI"):upper()), fsmall, banner_w - 40)
    renderer.draw_text(fsmall, q_sub, math.floor(banner_x + 14), math.floor(banner_y + 30), { 220, 210, 245, 255 })

    return {
      is_enlarged = false,
      banner_rect = { x = banner_x, y = banner_y, w = banner_w, h = banner_h }
    }
  end

  if not insight or not insight.text then return {} end

  -- Check if user has enlarged the insight into a full card modal
  if view and view.ai_insight_enlarged then
    -- 1. Dimmed Modal Backdrop
    draw_rect(bx, by, bw, bh, { 0, 0, 0, 165 })

    -- 2. Card Dimensions & Dynamic Layout Calculation
    local pad_x      = 22
    local card_w     = math.min(880, bw - 48)
    local max_card_h = math.max(240, bh - 60)
    local max_text_w = card_w - (pad_x * 2) - 18 -- reserve 18px for right scrollbar

    local line_h        = font:get_height() + 5
    local compiled_body = DiagramRenderer.compile_rich_markdown(insight.text, font, fsmall, max_text_w)
    local total_text_h  = math.max(compiled_body.total_h, line_h)

    local header_h = 44
    local query_h  = 30
    local nodes_list = {}
    if insight.nodes then
      local diag = (view.current_diagram and view:current_diagram()) or nil
      local node_map = {}
      if diag and diag.nodes then
        for _, n in ipairs(diag.nodes) do node_map[n.id] = n end
      end
      for nid, active in pairs(insight.nodes) do
        if active then
          local n = node_map[nid]
          table.insert(nodes_list, { id = nid, label = (n and n.label) or nid })
        end
      end
      table.sort(nodes_list, function(a, b) return a.label < b.label end)
    end
    local nodes_h = (#nodes_list > 0) and 28 or 0
    local footer_h = 38
    local pad_v = 16

    local natural_card_h = header_h + query_h + nodes_h + total_text_h + footer_h + (pad_v * 2)
    local card_h = math.min(max_card_h, math.max(220, natural_card_h))
    local card_x = bx + math.floor((bw - card_w) / 2)
    local card_y = by + math.floor((bh - card_h) / 2)

    -- 3. Outer Shadow & Elevated Violet Card Body
    draw_rect(card_x + 5, card_y + 5, card_w, card_h, { 0, 0, 0, 180 })
    draw_rect(card_x,     card_y,     card_w, card_h, { 20, 15, 30, 252 })
    -- Borders
    draw_rect(card_x, card_y, card_w, 2, { 192, 132, 252, 255 }) -- glowing top neon border
    draw_rect(card_x, card_y + card_h - 1, card_w, 1, { 75, 42, 105, 200 })
    draw_rect(card_x, card_y, 1, card_h, { 75, 42, 105, 200 })
    draw_rect(card_x + card_w - 1, card_y, 1, card_h, { 75, 42, 105, 200 })

    -- 4. Header Bar
    local title_str = "ARCHITECTURE AI INSIGHT"
    renderer.draw_text(font, title_str, math.floor(card_x + pad_x), math.floor(card_y + 13), { 216, 180, 254, 255 })
    local t_w = font:get_width(title_str)

    -- Badge pill
    local prov_str = (insight.provider and #insight.provider > 0) and (" " .. insight.provider:upper() .. " ") or " DEEP DIVE "
    local b_w = fsmall:get_width(prov_str) + 6
    local b_x = card_x + pad_x + t_w + 12
    local b_y = card_y + 13
    draw_rect(b_x, b_y, b_w, 18, { 68, 30, 98, 220 })
    draw_rect(b_x, b_y, b_w, 1,  { 168, 85, 247, 255 })
    renderer.draw_text(fsmall, prov_str, math.floor(b_x + 3), math.floor(b_y + 2), { 235, 215, 255, 255 })

    -- Header Action Buttons (Right Aligned)
    -- [ Close (Esc) ]
    local dis_label = " X Close (Esc) "
    local dis_w     = fsmall:get_width(dis_label) + 10
    local dis_h     = 22
    local dis_x     = card_x + card_w - pad_x - dis_w
    local dis_y     = card_y + 11
    local dis_hov   = is_hovered(mouse_x, mouse_y, dis_x, dis_y, dis_w, dis_h)
    draw_rect(dis_x, dis_y, dis_w, dis_h, dis_hov and { 85, 30, 48, 255 } or { 48, 24, 36, 220 })
    draw_rect(dis_x, dis_y, dis_w, 1,    dis_hov and { 244, 63, 94, 255 } or { 160, 50, 80, 255 })
    renderer.draw_text(fsmall, dis_label, math.floor(dis_x + 5), math.floor(dis_y + (dis_h - fsmall:get_height()) / 2), dis_hov and { 255, 220, 230, 255 } or { 235, 170, 190, 255 })

    -- [ ↘ Minimize ]
    local min_label = " [-] Minimize "
    local min_w     = fsmall:get_width(min_label) + 10
    local min_h     = 22
    local min_x     = dis_x - min_w - 8
    local min_y     = card_y + 11
    local min_hov   = is_hovered(mouse_x, mouse_y, min_x, min_y, min_w, min_h)
    draw_rect(min_x, min_y, min_w, min_h, min_hov and { 70, 45, 95, 255 } or { 38, 26, 52, 220 })
    draw_rect(min_x, min_y, min_w, 1,    min_hov and { 192, 132, 252, 255 } or { 120, 60, 170, 255 })
    renderer.draw_text(fsmall, min_label, math.floor(min_x + 5), math.floor(min_y + (min_h - fsmall:get_height()) / 2), min_hov and { 255, 255, 255, 255 } or { 210, 195, 230, 255 })

    -- [ Copy ]
    local copy_label = " Copy "
    local copy_w     = fsmall:get_width(copy_label) + 10
    local copy_h     = 22
    local copy_x     = min_x - copy_w - 8
    local copy_y     = card_y + 11
    local copy_hov   = is_hovered(mouse_x, mouse_y, copy_x, copy_y, copy_w, copy_h)
    draw_rect(copy_x, copy_y, copy_w, copy_h, copy_hov and { 45, 65, 95, 255 } or { 28, 38, 56, 220 })
    draw_rect(copy_x, copy_y, copy_w, 1,    copy_hov and { 56, 189, 248, 255 } or { 40, 110, 170, 255 })
    renderer.draw_text(fsmall, copy_label, math.floor(copy_x + 5), math.floor(copy_y + (copy_h - fsmall:get_height()) / 2), copy_hov and { 235, 250, 255, 255 } or { 180, 215, 240, 255 })

    -- Header separator line
    draw_rect(card_x + pad_x, card_y + header_h, card_w - (pad_x * 2), 1, { 65, 45, 85, 200 })

    -- 5. Query Box
    local cur_y = card_y + header_h + 8
    local q_w = card_w - (pad_x * 2)
    draw_rect(card_x + pad_x, cur_y, q_w, 24, { 30, 22, 44, 220 })
    draw_rect(card_x + pad_x, cur_y, 2,   24, { 168, 85, 247, 255 })
    local q_prefix = "Question: "
    renderer.draw_text(fsmall, q_prefix, math.floor(card_x + pad_x + 8), math.floor(cur_y + 5), { 192, 132, 252, 255 })
    local q_pre_w = fsmall:get_width(q_prefix)
    local q_val = truncate(string.format("\"%s\"", insight.query or "General Architecture Inquiry"), fsmall, q_w - q_pre_w - 20)
    renderer.draw_text(fsmall, q_val, math.floor(card_x + pad_x + 8 + q_pre_w), math.floor(cur_y + 5), { 245, 245, 255, 255 })
    cur_y = cur_y + 24 + 8

    -- 6. Involved Components Row (if any)
    local node_pills = {}
    if #nodes_list > 0 then
      local n_lbl = "Components: "
      renderer.draw_text(fsmall, n_lbl, math.floor(card_x + pad_x), math.floor(cur_y + 4), { 160, 150, 185, 255 })
      local pill_x = card_x + pad_x + fsmall:get_width(n_lbl)
      for _, item in ipairs(nodes_list) do
        local plabel = " " .. item.label .. " "
        local pw = fsmall:get_width(plabel) + 6
        if pill_x + pw > card_x + card_w - pad_x then
          break -- keep in one row
        end
        local phov = is_hovered(mouse_x, mouse_y, pill_x, cur_y + 2, pw, 20)
        draw_rect(pill_x, cur_y + 2, pw, 20, phov and { 45, 30, 65, 255 } or { 32, 22, 46, 220 })
        draw_rect(pill_x, cur_y + 2, pw, 1,  phov and { 216, 180, 254, 255 } or { 147, 51, 234, 200 })
        renderer.draw_text(fsmall, plabel, math.floor(pill_x + 3), math.floor(cur_y + 4), phov and { 255, 255, 255, 255 } or { 220, 205, 245, 255 })
        table.insert(node_pills, { id = item.id, x = pill_x, y = cur_y + 2, w = pw, h = 20 })
        pill_x = pill_x + pw + 6
      end
      cur_y = cur_y + 24 + 8
    end

    -- 7. Scrollable Text Body
    local footer_y = card_y + card_h - footer_h
    local body_x = card_x + pad_x
    local body_y = cur_y
    local body_w = card_w - (pad_x * 2) - 14
    local body_h = footer_y - body_y - 6

    local max_scroll = math.max(0, total_text_h - body_h)
    local scroll_y = math.max(0, math.min(max_scroll, (view and view.ai_insight_scroll_y) or 0))
    if view then view.ai_insight_scroll_y = scroll_y end

    -- Render compiled rich markdown with push_clip_rect
    core.push_clip_rect(body_x, body_y, body_w, body_h)
    DiagramRenderer.render_rich_markdown(compiled_body, body_x, body_y - scroll_y, body_w, body_y, body_h, {
      font = font,
      code_font = fsmall,
      accent = { 192, 132, 252, 255 },
      text_col = { 226, 232, 240, 255 }
    })
    core.pop_clip_rect()

    -- 8. Scrollbar (if overflow)
    if max_scroll > 0 then
      local sb_track_w = 6
      local sb_track_x = card_x + card_w - pad_x
      local sb_track_y = body_y
      local sb_track_h = body_h
      draw_rect(sb_track_x, sb_track_y, sb_track_w, sb_track_h, { 35, 25, 50, 160 })
      local thumb_h = math.max(22, math.floor(sb_track_h * (sb_track_h / total_text_h)))
      local thumb_y = sb_track_y + math.floor((scroll_y / max_scroll) * (sb_track_h - thumb_h))
      local sb_hov = is_hovered(mouse_x, mouse_y, sb_track_x - 4, sb_track_y, sb_track_w + 8, sb_track_h)
      draw_rect(sb_track_x, thumb_y, sb_track_w, thumb_h, sb_hov and { 216, 180, 254, 255 } or { 168, 85, 247, 220 })
    end

    -- 9. Footer Bar
    draw_rect(card_x + pad_x, footer_y, card_w - (pad_x * 2), 1, { 65, 45, 85, 200 })
    local tip_str = (max_scroll > 0)
      and "Tip: Scroll with mouse wheel | Click components above to focus | Esc to minimize"
      or  "Tip: Press Esc or click outside to minimize back to bottom banner"
    renderer.draw_text(fsmall, tip_str, math.floor(card_x + pad_x), math.floor(footer_y + 12), { 160, 150, 185, 255 })

    -- Footer Quick Actions
    -- [ Copy Insight ]
    local ft_copy_label = " Copy Insight "
    local ft_copy_w     = fsmall:get_width(ft_copy_label) + 10
    local ft_copy_h     = 22
    local ft_copy_x     = card_x + card_w - pad_x - ft_copy_w
    local ft_copy_y     = footer_y + 8
    local ft_copy_hov   = is_hovered(mouse_x, mouse_y, ft_copy_x, ft_copy_y, ft_copy_w, ft_copy_h)
    draw_rect(ft_copy_x, ft_copy_y, ft_copy_w, ft_copy_h, ft_copy_hov and { 45, 65, 95, 255 } or { 28, 38, 56, 220 })
    draw_rect(ft_copy_x, ft_copy_y, ft_copy_w, 1,    ft_copy_hov and { 56, 189, 248, 255 } or { 40, 110, 170, 255 })
    renderer.draw_text(fsmall, ft_copy_label, math.floor(ft_copy_x + 5), math.floor(ft_copy_y + (ft_copy_h - fsmall:get_height()) / 2), ft_copy_hov and { 235, 250, 255, 255 } or { 180, 215, 240, 255 })

    -- [ ↘ Minimize ]
    local ft_min_label = " [-] Minimize "
    local ft_min_w     = fsmall:get_width(ft_min_label) + 10
    local ft_min_h     = 22
    local ft_min_x     = ft_copy_x - ft_min_w - 8
    local ft_min_y     = footer_y + 8
    local ft_min_hov   = is_hovered(mouse_x, mouse_y, ft_min_x, ft_min_y, ft_min_w, ft_min_h)
    draw_rect(ft_min_x, ft_min_y, ft_min_w, ft_min_h, ft_min_hov and { 70, 45, 95, 255 } or { 38, 26, 52, 220 })
    draw_rect(ft_min_x, ft_min_y, ft_min_w, 1,    ft_min_hov and { 192, 132, 252, 255 } or { 120, 60, 170, 255 })
    renderer.draw_text(fsmall, ft_min_label, math.floor(ft_min_x + 5), math.floor(ft_min_y + (ft_min_h - fsmall:get_height()) / 2), ft_min_hov and { 255, 255, 255, 255 } or { 210, 195, 230, 255 })

    return {
      is_enlarged          = true,
      card_bounds          = { x = card_x, y = card_y, w = card_w, h = card_h },
      backdrop_rect        = { x = bx, y = by, w = bw, h = bh },
      dismiss_rect         = { x = dis_x, y = dis_y, w = dis_w, h = dis_h },
      enlarge_rect         = { x = min_x, y = min_y, w = min_w, h = min_h }, -- acts as minimize
      copy_rect            = { x = copy_x, y = copy_y, w = copy_w, h = copy_h },
      footer_copy_rect     = { x = ft_copy_x, y = ft_copy_y, w = ft_copy_w, h = ft_copy_h },
      footer_minimize_rect = { x = ft_min_x, y = ft_min_y, w = ft_min_w, h = ft_min_h },
      node_pills           = node_pills,
      max_scroll           = max_scroll,
    }
  else
    -- COMPACT MODE: Floating Bottom Banner
    local banner_h = 56
    local banner_y = by + bh - banner_h - 6
    local banner_x = bx + 20
    local banner_w = bw - 40

    -- Elevated dark violet container with purple neon border
    draw_rect(banner_x + 2, banner_y + 2, banner_w, banner_h, { 0, 0, 0, 140 })
    draw_rect(banner_x,     banner_y,     banner_w, banner_h, { 22, 16, 32, 250 })
    draw_rect(banner_x,     banner_y,     banner_w, 1,        { 168, 85, 247, 255 })

    -- Close button [X Dismiss]
    local dis_label = " X Dismiss (Esc) "
    local dis_w     = fsmall:get_width(dis_label) + 8
    local dis_h     = 20
    local dis_x     = banner_x + banner_w - dis_w - 10
    local dis_y     = banner_y + (banner_h - dis_h) / 2
    local dis_hov   = is_hovered(mouse_x, mouse_y, dis_x, dis_y, dis_w, dis_h)
    draw_rect(dis_x, dis_y, dis_w, dis_h, dis_hov and { 65, 30, 45, 255 } or { 38, 24, 34, 220 })
    draw_rect(dis_x, dis_y, dis_w, 1,    dis_hov and { 244, 63, 94, 255 } or { 140, 50, 75, 255 })
    renderer.draw_text(fsmall, dis_label, math.floor(dis_x + 4), math.floor(dis_y + (dis_h - fsmall:get_height()) / 2), dis_hov and { 255, 220, 230, 255 } or { 225, 150, 175, 255 })

    -- Enlarge button [+] Enlarge
    local enl_label = " [+] Enlarge "
    local enl_w     = fsmall:get_width(enl_label) + 8
    local enl_h     = 20
    local enl_x     = dis_x - enl_w - 8
    local enl_y     = dis_y
    local enl_hov   = is_hovered(mouse_x, mouse_y, enl_x, enl_y, enl_w, enl_h)
    draw_rect(enl_x, enl_y, enl_w, enl_h, enl_hov and { 85, 45, 120, 255 } or { 48, 28, 65, 220 })
    draw_rect(enl_x, enl_y, enl_w, 1,    enl_hov and { 216, 180, 254, 255 } or { 168, 85, 247, 255 })
    renderer.draw_text(fsmall, enl_label, math.floor(enl_x + 4), math.floor(enl_y + (enl_h - fsmall:get_height()) / 2), enl_hov and { 255, 255, 255, 255 } or { 235, 215, 255, 255 })

    -- Title & Query Line
    local prov_tag     = (insight.provider and #insight.provider > 0) and string.format("[%s] ", insight.provider:upper()) or ""
    local title_prefix = prov_tag .. "AI INSIGHT: "
    local query_str    = truncate(string.format("\"%s\"", insight.query or "Query"), font, banner_w - dis_w - enl_w - 260)
    renderer.draw_text(font, title_prefix, math.floor(banner_x + 14), math.floor(banner_y + 8), { 192, 132, 252, 255 })
    local p_w = font:get_width(title_prefix)
    renderer.draw_text(font, query_str, math.floor(banner_x + 14 + p_w), math.floor(banner_y + 8), { 245, 245, 255, 255 })

    -- Answer / Explanation Line (Truncated preview with hint to enlarge)
    local ans_str = truncate(insight.text or "", fsmall, banner_w - dis_w - enl_w - 50)
    renderer.draw_text(fsmall, ans_str, math.floor(banner_x + 14), math.floor(banner_y + 30), { 216, 225, 240, 255 })

    return {
      is_enlarged  = false,
      banner_rect  = { x = banner_x, y = banner_y, w = banner_w, h = banner_h },
      dismiss_rect = { x = dis_x, y = dis_y, w = dis_w, h = dis_h },
      enlarge_rect = { x = enl_x, y = enl_y, w = enl_w, h = enl_h },
    }
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Helper to resolve full details, impact, and remediation for an audit finding
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.get_finding_details(f)
  if not f then return "", "", "" end
  local desc = f.desc
  local impact = f.impact
  local rec = f.recommendation

  if not desc or desc == "" then
    local title = f.title or ""
    if title:find("Circular Coupling") then
      local nstr = (f.nodes and #f.nodes > 0) and table.concat(f.nodes, " -> ") or "Multiple components"
      desc = "Components form a cyclical dependency loop (" .. nstr .. "). In a healthy architecture, dependencies flow strictly acyclic (DAG). Circular loops intertwine component lifecycles, prevent modular compilation, and cause cascading startup failures."
      impact = "High ripple effect on code modifications, tight coupling, and risk of infinite recursion or deadlocks during event propagation."
      rec = "Break the loop by extracting shared domain models into an independent leaf module, or introduce an asynchronous event bus or Dependency Inversion (DIP) abstraction."
    elseif title:find("Layer Inversion") then
      local s = (f.nodes and f.nodes[1]) or "Ingress component"
      local d = (f.nodes and f.nodes[2]) or "persistence layer"
      desc = "The edge/presentation ingress component '" .. s .. "' bypasses the domain service tier to directly invoke the persistence layer '" .. d .. "'. This violates Clean Architecture and Hexagonal layering principles."
      impact = "Leaking database entities and query specifics into client presentation layers, bypassing business rule validation, audit trails, and transaction boundaries."
      rec = "Refactor ingress to invoke an application service or command handler. Mediate all database interactions through domain repositories."
    elseif title:find("High Fan%-In SPOF") then
      local nid = (f.nodes and f.nodes[1]) or "Component"
      desc = "Component '" .. nid .. "' is heavily depended upon by multiple upstream services, acting as an architectural bottleneck and potential Single Point of Failure (SPOF)."
      impact = "Any disruption, deployment downtime, or schema regression in this component immediately degrades upstream dependent subsystems."
      rec = "Implement circuit breakers (e.g. Hystrix/Resilience4j pattern), enable horizontal load replication, and add aggressive read caching (e.g. Redis)."
    elseif title:find("Orphan Service") then
      local nid = (f.nodes and f.nodes[1]) or "Component"
      desc = "Component '" .. nid .. "' has zero incoming callers and zero outgoing dependencies in the active architecture graph."
      impact = "Potential dead code, abandoned microservice, or missing integration wiring in system architecture definitions."
      rec = "Verify if this component is obsolete and eligible for safe deprecation, or register its missing upstream consumers and downstream providers."
    elseif title:find("God Component") then
      local nid = (f.nodes and f.nodes[1]) or "Component"
      desc = "Component '" .. nid .. "' has an excessive number of incoming callers and outgoing dependencies, acting as an oversized orchestrator or monolithic God Component."
      impact = "Extreme blast radius on changes, testing fragility, and severe violation of the Single Responsibility Principle (SRP)."
      rec = "Decompose into smaller cohesive services following Domain-Driven Design (DDD) bounded contexts, or introduce an event-driven pub/sub architecture."
    elseif title:find("Sinkhole") then
      local nid = (f.nodes and f.nodes[1]) or "Service"
      desc = "Service '" .. nid .. "' accepts incoming traffic but has zero downstream dependencies, persistent storage, or event emissions."
      impact = "Potential stub implementation, incomplete architecture model, or black-hole service that silently drops state without persistence."
      rec = "Confirm whether this service should persist state to a database or emit events to downstream queues."
    elseif title:find("Deep Call Chain") then
      desc = "Detected a deep synchronous call chain spanning multiple hops. Synchronous chaining amplifies latency and compounds availability risk."
      impact = "Cascading latency amplification, high vulnerability to timeout storms, and tight coupling across service tiers."
      rec = "Decouple long synchronous call chains using asynchronous message queues, saga orchestrators, or caching."
    elseif title:find("Hub Overload") then
      local nid = (f.nodes and f.nodes[1]) or "Component"
      desc = "Component '" .. nid .. "' has an unusually high degree of connectivity, acting as an oversized hub or God Component."
      impact = "High maintenance friction, extreme regression risk on any change, and tight coupling across disparate project domains."
      rec = "Decompose the component into cohesive sub-modules following Single Responsibility (SRP), or place a Facade / API Mediator in front of it."
    else
      desc = "Architectural pattern flagged during static dependency and topological analysis: " .. title
      impact = "May reduce maintainability, testability, or operational resilience if left unaddressed as the codebase scales."
      rec = "Review component coupling and boundary separation according to project architecture guidelines."
    end
  end

  return desc, impact or "Architecture health risk.", rec or "Review component dependencies and decouple."
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw Enlarged Architecture Audit Finding Modal Card Component
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.draw_enlarged_audit_finding_card(view, finding, bx, by, bw, bh, mouse_x, mouse_y)
  if not finding then return {} end
  local font   = style.font
  local fsmall = style.code_font or font

  -- 1. Dimmed Modal Backdrop
  draw_rect(bx, by, bw, bh, { 0, 0, 0, 165 })

  -- 2. Theme colors based on severity
  local f_type = finding.type or "info"
  local accent_col, banner_bg, badge_bg, badge_lbl, header_title_col
  if f_type == "critical" then
    accent_col       = { 244,  63,  94, 255 } -- rose-500
    banner_bg        = {  45,  18,  26, 252 }
    badge_bg         = {  75,  20,  32, 230 }
    badge_lbl        = " CRITICAL ISSUE "
    header_title_col = { 254, 205, 215, 255 }
  elseif f_type == "warning" then
    accent_col       = { 245, 158,  11, 255 } -- amber-500
    banner_bg        = {  45,  34,  18, 252 }
    badge_bg         = {  75,  50,  15, 230 }
    badge_lbl        = " ARCHITECTURE WARNING "
    header_title_col = { 254, 235, 200, 255 }
  else
    accent_col       = {  56, 189, 248, 255 } -- sky-400
    banner_bg        = {  18,  32,  48, 252 }
    badge_bg         = {  20,  50,  75, 230 }
    badge_lbl        = " ARCHITECTURE NOTICE "
    header_title_col = { 210, 235, 255, 255 }
  end

  -- 3. Card Dimensions & Dynamic Layout Calculation
  local pad_x      = 22
  local card_w     = math.min(880, bw - 48)
  local max_card_h = math.max(260, bh - 60)
  local max_text_w = card_w - (pad_x * 2) - 18 -- reserve 18px for right scrollbar

  local desc, impact, rec = DiagramRenderer.get_finding_details(finding)
  local desc_compiled   = DiagramRenderer.compile_rich_markdown(desc, font, fsmall, max_text_w)
  local impact_compiled = DiagramRenderer.compile_rich_markdown(impact, font, fsmall, max_text_w)
  local rec_compiled    = DiagramRenderer.compile_rich_markdown(rec, font, fsmall, max_text_w)

  local line_h       = font:get_height() + 5
  local sec_hdr_h    = fsmall:get_height() + 10

  -- Calculate total text content height
  local text_content_h = (sec_hdr_h + desc_compiled.total_h + 12) +
                         (sec_hdr_h + impact_compiled.total_h + 12) +
                         (sec_hdr_h + rec_compiled.total_h + 12)

  local header_h    = 44
  local title_box_h = 32
  local nodes_list  = {}
  if finding.nodes and #finding.nodes > 0 then
    local diag = (view.current_diagram and view:current_diagram()) or nil
    local node_map = {}
    if diag and diag.nodes then
      for _, n in ipairs(diag.nodes) do node_map[n.id] = n end
    end
    for _, nid in ipairs(finding.nodes) do
      local n = node_map[nid]
      table.insert(nodes_list, { id = nid, label = (n and n.label) or nid })
    end
  end
  local nodes_h = (#nodes_list > 0) and 28 or 0
  local footer_h = 38
  local pad_v    = 16

  local natural_card_h = header_h + title_box_h + nodes_h + text_content_h + footer_h + (pad_v * 2)
  local card_h = math.min(max_card_h, math.max(260, natural_card_h))
  local card_x = bx + math.floor((bw - card_w) / 2)
  local card_y = by + math.floor((bh - card_h) / 2)

  -- 4. Outer Shadow & Elevated Card Body
  draw_rect(card_x + 5, card_y + 5, card_w, card_h, { 0, 0, 0, 180 })
  draw_rect(card_x,     card_y,     card_w, card_h, { 20, 22, 30, 252 })
  -- Borders
  draw_rect(card_x, card_y, card_w, 2, accent_col) -- glowing top neon border
  draw_rect(card_x, card_y + card_h - 1, card_w, 1, { 50, 60, 80, 200 })
  draw_rect(card_x, card_y, 1, card_h, { 50, 60, 80, 200 })
  draw_rect(card_x + card_w - 1, card_y, 1, card_h, { 50, 60, 80, 200 })

  -- 5. Header Bar
  local hdr_str = "ARCHITECTURE AUDIT FINDING"
  renderer.draw_text(font, hdr_str, math.floor(card_x + pad_x), math.floor(card_y + 13), header_title_col)
  local t_w = font:get_width(hdr_str)

  -- Severity Badge Pill
  local b_w = fsmall:get_width(badge_lbl) + 6
  local b_x = card_x + pad_x + t_w + 12
  local b_y = card_y + 13
  draw_rect(b_x, b_y, b_w, 18, badge_bg)
  draw_rect(b_x, b_y, b_w, 1,  accent_col)
  renderer.draw_text(fsmall, badge_lbl, math.floor(b_x + 3), math.floor(b_y + 2), accent_col)

  -- Header Action Buttons (Right Aligned)
  -- [ Close (Esc) ]
  local dis_label = " X Close (Esc) "
  local dis_w     = fsmall:get_width(dis_label) + 10
  local dis_h     = 22
  local dis_x     = card_x + card_w - pad_x - dis_w
  local dis_y     = card_y + 11
  local dis_hov   = is_hovered(mouse_x, mouse_y, dis_x, dis_y, dis_w, dis_h)
  draw_rect(dis_x, dis_y, dis_w, dis_h, dis_hov and { 85, 30, 48, 255 } or { 48, 24, 36, 220 })
  draw_rect(dis_x, dis_y, dis_w, 1,    dis_hov and { 244, 63, 94, 255 } or { 160, 50, 80, 255 })
  renderer.draw_text(fsmall, dis_label, math.floor(dis_x + 5), math.floor(dis_y + (dis_h - fsmall:get_height()) / 2), dis_hov and { 255, 220, 230, 255 } or { 235, 170, 190, 255 })

  -- [ [-] Minimize ]
  local min_label = " [-] Minimize "
  local min_w     = fsmall:get_width(min_label) + 10
  local min_h     = 22
  local min_x     = dis_x - min_w - 8
  local min_y     = card_y + 11
  local min_hov   = is_hovered(mouse_x, mouse_y, min_x, min_y, min_w, min_h)
  draw_rect(min_x, min_y, min_w, min_h, min_hov and { 45, 55, 75, 255 } or { 30, 36, 50, 220 })
  draw_rect(min_x, min_y, min_w, 1,    min_hov and accent_col or { 65, 80, 110, 255 })
  renderer.draw_text(fsmall, min_label, math.floor(min_x + 5), math.floor(min_y + (min_h - fsmall:get_height()) / 2), min_hov and { 255, 255, 255, 255 } or { 210, 220, 240, 255 })

  -- [ Copy ]
  local copy_label = " Copy "
  local copy_w     = fsmall:get_width(copy_label) + 10
  local copy_h     = 22
  local copy_x     = min_x - copy_w - 8
  local copy_y     = card_y + 11
  local copy_hov   = is_hovered(mouse_x, mouse_y, copy_x, copy_y, copy_w, copy_h)
  draw_rect(copy_x, copy_y, copy_w, copy_h, copy_hov and { 35, 65, 85, 255 } or { 24, 40, 55, 220 })
  draw_rect(copy_x, copy_y, copy_w, 1,    copy_hov and { 56, 189, 248, 255 } or { 40, 110, 170, 255 })
  renderer.draw_text(fsmall, copy_label, math.floor(copy_x + 5), math.floor(copy_y + (copy_h - fsmall:get_height()) / 2), copy_hov and { 235, 250, 255, 255 } or { 180, 215, 240, 255 })

  -- Header separator line
  draw_rect(card_x + pad_x, card_y + header_h, card_w - (pad_x * 2), 1, { 55, 65, 85, 200 })

  -- 6. Finding Title Banner
  local cur_y = card_y + header_h + 8
  local tb_w  = card_w - (pad_x * 2)
  draw_rect(card_x + pad_x, cur_y, tb_w, 26, banner_bg)
  draw_rect(card_x + pad_x, cur_y, 3,    26, accent_col)
  local f_title = truncate(finding.title or "Architecture Finding", font, tb_w - 20)
  renderer.draw_text(font, f_title, math.floor(card_x + pad_x + 10), math.floor(cur_y + 4), { 245, 248, 255, 255 })
  cur_y = cur_y + 26 + 8

  -- 7. Involved Components Row (if any)
  local node_pills = {}
  if #nodes_list > 0 then
    local n_lbl = "Components: "
    renderer.draw_text(fsmall, n_lbl, math.floor(card_x + pad_x), math.floor(cur_y + 4), { 160, 175, 200, 255 })
    local pill_x = card_x + pad_x + fsmall:get_width(n_lbl)
    for _, item in ipairs(nodes_list) do
      local plabel = " " .. item.label .. " "
      local pw = fsmall:get_width(plabel) + 6
      if pill_x + pw > card_x + card_w - pad_x then
        break -- keep in one row
      end
      local phov = is_hovered(mouse_x, mouse_y, pill_x, cur_y + 2, pw, 20)
      draw_rect(pill_x, cur_y + 2, pw, 20, phov and { 45, 55, 75, 255 } or { 28, 34, 48, 220 })
      draw_rect(pill_x, cur_y + 2, pw, 1,  phov and accent_col or { 65, 85, 115, 200 })
      renderer.draw_text(fsmall, plabel, math.floor(pill_x + 3), math.floor(cur_y + 4), phov and { 255, 255, 255, 255 } or { 210, 225, 245, 255 })
      table.insert(node_pills, { id = item.id, x = pill_x, y = cur_y + 2, w = pw, h = 20 })
      pill_x = pill_x + pw + 6
    end
    cur_y = cur_y + 24 + 8
  end

  -- 8. Scrollable Body
  local footer_y = card_y + card_h - footer_h
  local body_x   = card_x + pad_x
  local body_y   = cur_y
  local body_w   = card_w - (pad_x * 2) - 14
  local body_h   = footer_y - body_y - 6

  local max_scroll = math.max(0, text_content_h - body_h)
  local scroll_y = math.max(0, math.min(max_scroll, (view and view.audit_enlarged_scroll_y) or 0))
  if view then view.audit_enlarged_scroll_y = scroll_y end

  -- Render content with clip rect
  core.push_clip_rect(body_x, body_y, body_w, body_h)
  local draw_y = body_y - scroll_y

  local function render_section(sec_title, sec_color, compiled_block)
    if draw_y + sec_hdr_h >= body_y and draw_y <= body_y + body_h then
      draw_rect(body_x, draw_y + 2, 3, sec_hdr_h - 4, sec_color)
      renderer.draw_text(fsmall, sec_title, math.floor(body_x + 8), math.floor(draw_y + 2), sec_color)
    end
    draw_y = draw_y + sec_hdr_h

    DiagramRenderer.render_rich_markdown(compiled_block, body_x + 8, draw_y, body_w - 12, body_y, body_h, {
      font = font,
      code_font = fsmall,
      accent = sec_color,
      text_col = { 226, 232, 240, 255 }
    })
    draw_y = draw_y + compiled_block.total_h + 12
  end

  -- Section 1: DESCRIPTION & CONTEXT
  render_section("DESCRIPTION & CONTEXT", { 147, 197, 253, 255 }, desc_compiled)

  -- Section 2: ARCHITECTURAL IMPACT
  render_section("ARCHITECTURAL IMPACT", accent_col, impact_compiled)

  -- Section 3: RECOMMENDED REMEDIATION
  render_section("RECOMMENDED REMEDIATION", { 52, 211, 153, 255 }, rec_compiled)

  core.pop_clip_rect()

  -- 9. Scrollbar (if overflow)
  if max_scroll > 0 then
    local sb_track_w = 6
    local sb_track_x = card_x + card_w - pad_x
    local sb_track_y = body_y
    local sb_track_h = body_h
    draw_rect(sb_track_x, sb_track_y, sb_track_w, sb_track_h, { 30, 36, 48, 160 })
    local thumb_h = math.max(22, math.floor(sb_track_h * (sb_track_h / text_content_h)))
    local thumb_y = sb_track_y + math.floor((scroll_y / max_scroll) * (sb_track_h - thumb_h))
    local sb_hov = is_hovered(mouse_x, mouse_y, sb_track_x - 4, sb_track_y, sb_track_w + 8, sb_track_h)
    draw_rect(sb_track_x, thumb_y, sb_track_w, thumb_h, sb_hov and { 255, 255, 255, 255 } or accent_col)
  end

  -- 10. Footer Bar
  draw_rect(card_x + pad_x, footer_y, card_w - (pad_x * 2), 1, { 55, 65, 85, 200 })
  local tip_str = (max_scroll > 0)
    and "Tip: Scroll with mouse wheel | Click components above to focus | Esc to minimize"
    or  "Tip: Press Esc or click outside to minimize back to Audit panel"
  renderer.draw_text(fsmall, tip_str, math.floor(card_x + pad_x), math.floor(footer_y + 12), { 160, 175, 200, 255 })

  -- Footer Quick Actions
  -- [ Copy Finding ]
  local ft_copy_label = " Copy Finding "
  local ft_copy_w     = fsmall:get_width(ft_copy_label) + 10
  local ft_copy_h     = 22
  local ft_copy_x     = card_x + card_w - pad_x - ft_copy_w
  local ft_copy_y     = footer_y + 8
  local ft_copy_hov   = is_hovered(mouse_x, mouse_y, ft_copy_x, ft_copy_y, ft_copy_w, ft_copy_h)
  draw_rect(ft_copy_x, ft_copy_y, ft_copy_w, ft_copy_h, ft_copy_hov and { 35, 65, 85, 255 } or { 24, 40, 55, 220 })
  draw_rect(ft_copy_x, ft_copy_y, ft_copy_w, 1,    ft_copy_hov and { 56, 189, 248, 255 } or { 40, 110, 170, 255 })
  renderer.draw_text(fsmall, ft_copy_label, math.floor(ft_copy_x + 5), math.floor(ft_copy_y + (ft_copy_h - fsmall:get_height()) / 2), ft_copy_hov and { 235, 250, 255, 255 } or { 180, 215, 240, 255 })

  -- [ [-] Minimize ]
  local ft_min_label = " [-] Minimize "
  local ft_min_w     = fsmall:get_width(ft_min_label) + 10
  local ft_min_h     = 22
  local ft_min_x     = ft_copy_x - ft_min_w - 8
  local ft_min_y     = footer_y + 8
  local ft_min_hov   = is_hovered(mouse_x, mouse_y, ft_min_x, ft_min_y, ft_min_w, ft_min_h)
  draw_rect(ft_min_x, ft_min_y, ft_min_w, ft_min_h, ft_min_hov and { 45, 55, 75, 255 } or { 30, 36, 50, 220 })
  draw_rect(ft_min_x, ft_min_y, ft_min_w, 1,    ft_min_hov and accent_col or { 65, 80, 110, 255 })
  renderer.draw_text(fsmall, ft_min_label, math.floor(ft_min_x + 5), math.floor(ft_min_y + (ft_min_h - fsmall:get_height()) / 2), ft_min_hov and { 255, 255, 255, 255 } or { 210, 220, 240, 255 })

  return {
    is_enlarged          = true,
    card_bounds          = { x = card_x, y = card_y, w = card_w, h = card_h },
    backdrop_rect        = { x = bx, y = by, w = bw, h = bh },
    dismiss_rect         = { x = dis_x, y = dis_y, w = dis_w, h = dis_h },
    minimize_rect        = { x = min_x, y = min_y, w = min_w, h = min_h },
    copy_rect            = { x = copy_x, y = copy_y, w = copy_w, h = copy_h },
    footer_copy_rect     = { x = ft_copy_x, y = ft_copy_y, w = ft_copy_w, h = ft_copy_h },
    footer_minimize_rect = { x = ft_min_x, y = ft_min_y, w = ft_min_w, h = ft_min_h },
    node_pills           = node_pills,
    max_scroll           = max_scroll,
  }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw Architecture Health & Anti-Pattern Audit Drawer
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.draw_audit_drawer(view, audit_data, ax, ay, aw, ah, mouse_x, mouse_y)
  if not audit_data then return {} end
  local font   = style.font
  local fsmall = style.code_font or font
  local hit_rects = { findings = {} }

  draw_rect(ax, ay, aw, ah, { 18, 22, 30, 252 })
  draw_rect(ax, ay, 1, ah, COLORS.separator)

  local cur_y = ay + 14

  -- Header
  local title = "ARCHITECTURE AUDIT"
  renderer.draw_text(font, title, math.floor(ax + 14), math.floor(cur_y), { 45, 212, 191, 255 })

  local close_w = 20
  local close_h = 20
  local close_x = ax + aw - close_w - 12
  local close_hov = is_hovered(mouse_x, mouse_y, close_x, cur_y - 2, close_w, close_h)
  draw_rect(close_x, cur_y - 2, close_w, close_h, close_hov and { 60, 25, 35, 255 } or { 32, 36, 46, 255 })
  renderer.draw_text(fsmall, "X", math.floor(close_x + 6), math.floor(cur_y - 2 + (close_h - fsmall:get_height()) / 2), close_hov and { 255, 150, 160, 255 } or { 160, 175, 195, 255 })
  hit_rects.close_rect = { x = close_x, y = cur_y - 2, w = close_w, h = close_h }
  cur_y = cur_y + font:get_height() + 14

  -- Health Score Banner
  local score = audit_data.score or 100
  local score_label = string.format("Health Score: %d / 100", score)
  local status_str  = (score >= 90) and "EXCELLENT" or ((score >= 75) and "GOOD" or "NEEDS ATTENTION")
  local sc_col      = (score >= 90) and { 16, 185, 129, 255 } or ((score >= 75) and { 245, 158, 11, 255 } or { 244, 63, 94, 255 })

  draw_rect(ax + 14, cur_y, aw - 28, 38, { 24, 30, 42, 230 })
  draw_rect(ax + 14, cur_y, aw - 28, 1,  sc_col)
  renderer.draw_text(font, score_label, math.floor(ax + 24), math.floor(cur_y + (38 - font:get_height()) / 2), { 240, 245, 255, 255 })
  local st_w = fsmall:get_width(status_str)
  renderer.draw_text(fsmall, status_str, math.floor(ax + aw - 24 - st_w), math.floor(cur_y + (38 - fsmall:get_height()) / 2), sc_col)
  cur_y = cur_y + 48

  -- Findings list
  local findings = audit_data.findings or {}
  local fh_str = string.format("Detected Issues (%d):", #findings)
  renderer.draw_text(fsmall, fh_str, math.floor(ax + 14), math.floor(cur_y), { 160, 175, 205, 255 })
  cur_y = cur_y + fsmall:get_height() + 8

  if #findings == 0 then
    renderer.draw_text(fsmall, "  * 0 Architectural anti-patterns found!", math.floor(ax + 14), math.floor(cur_y), { 74, 222, 128, 255 })
    renderer.draw_text(fsmall, "  Clean layer separation & dependency DAG.", math.floor(ax + 14), math.floor(cur_y + 18), { 140, 160, 180, 200 })
  else
    for idx, fd in ipairs(findings) do
      local f_box_h = 50
      if cur_y + f_box_h > ay + ah - 10 then break end
      local f_hov = is_hovered(mouse_x, mouse_y, ax + 14, cur_y, aw - 28, f_box_h)
      local bcol  = fd.type == "critical" and { 244, 63, 94, 255 } or ((fd.type == "warning") and { 245, 158, 11, 255 } or { 56, 189, 248, 255 })
      draw_rect(ax + 14, cur_y, aw - 28, f_box_h, f_hov and { 34, 40, 56, 255 } or { 24, 28, 38, 220 })
      draw_rect(ax + 14, cur_y, 3, f_box_h, bcol)

      -- [ [+] Enlarge ] Button on right
      local enl_label = " [+] Enlarge "
      local enl_w     = fsmall:get_width(enl_label) + 6
      local enl_h     = 20
      local enl_x     = ax + aw - 14 - enl_w - 6
      local enl_y     = cur_y + 6
      local enl_hov   = is_hovered(mouse_x, mouse_y, enl_x, enl_y, enl_w, enl_h)
      draw_rect(enl_x, enl_y, enl_w, enl_h, enl_hov and { 45, 55, 80, 255 } or { 30, 36, 52, 220 })
      draw_rect(enl_x, enl_y, enl_w, 1,    enl_hov and bcol or { 60, 80, 110, 200 })
      renderer.draw_text(fsmall, enl_label, math.floor(enl_x + 3), math.floor(enl_y + (enl_h - fsmall:get_height()) / 2), enl_hov and { 255, 255, 255, 255 } or { 190, 215, 245, 255 })

      local type_tag = string.format("[%s]", (fd.type or "info"):upper())
      renderer.draw_text(fsmall, type_tag, math.floor(ax + 24), math.floor(cur_y + 6), bcol)

      local title_str = truncate(fd.title or "", fsmall, aw - enl_w - 60)
      renderer.draw_text(fsmall, title_str, math.floor(ax + 24), math.floor(cur_y + 26), { 225, 235, 245, 255 })

      table.insert(hit_rects.findings, {
        x = ax + 14, y = cur_y, w = aw - 28, h = f_box_h,
        enlarge_rect = { x = enl_x, y = enl_y, w = enl_w, h = enl_h },
        finding = fd
      })
      cur_y = cur_y + f_box_h + 6
    end
  end

  return hit_rects
end

function DiagramRenderer.draw_status_bar(view, hovered_node, edges, bx, by, bw)
  if type(edges) == "number" then
    bw = by
    by = bx
    bx = edges
    edges = nil
  end
  local fsmall = style.code_font

  draw_rect(bx, by, bw, STATUS_H, COLORS.status_bg)
  draw_rect(bx, by, bw, 1, COLORS.separator)

  local hints = "Toolbar: Zoom / Fit / Search  |  Legend: [CODE] In Repo  [SUGGESTION] Inferred Tool  |  Esc: Clear"
  if view and view.active_audit_finding then
    local af = view.active_audit_finding
    hints = string.format("[Audit Focus: %s] %s  |  Esc: Clear Audit Focus", (af.type or "issue"):upper(), af.title or "Finding")
  elseif view and view.search_query and view.search_query ~= "" then
    local matches = view.search_matches or {}
    if #matches > 0 then
      local idx  = view.search_match_idx or 1
      local curr = matches[idx] and matches[idx].node
      local name = curr and (curr.label or curr.id) or ""
      local info = curr and (curr.tech or curr.type or "") or ""
      hints = string.format("[Search] %d/%d for %q: %s [%s]  |  F3: Next  |  Shift+F3: Prev  |  Esc: Clear",
        idx, #matches, view.search_query, name, info)
    else
      hints = string.format("[Search] No matches for %q in this tab  |  Esc: Clear", view.search_query)
    end
  end
  local ty = by + (STATUS_H - fsmall:get_height()) / 2

  hints = clean_display_text(hints)
  renderer.draw_text(fsmall, hints, math.floor(bx + 8), math.floor(ty), COLORS.status_text)

  if hovered_node then
    local in_cnt = 0
    local out_cnt = 0
    for _, e in ipairs(edges or {}) do
      if e.to == hovered_node.id then in_cnt = in_cnt + 1 end
      if e.from == hovered_node.id then out_cnt = out_cnt + 1 end
    end
    local target = hovered_node.file and (hovered_node.file .. ":" .. (hovered_node.line or 1)) or (hovered_node.external and "Cloud Infrastructure" or "")
    local info = string.format("> %s [%s]  |  In: %d  Out: %d  |  %s",
      hovered_node.label or hovered_node.id,
      hovered_node.tech or hovered_node.type or "node",
      in_cnt, out_cnt,
      target
    )
    local iw = fsmall:get_width(info)
    if bx + bw - iw - 10 > bx + fsmall:get_width(hints) + 20 then
      info = clean_display_text(info)
      renderer.draw_text(fsmall, info, math.floor(bx + bw - iw - 10), math.floor(ty), COLORS.tooltip_text)
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw animated loading spinner
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.draw_spinner(view, cx, cy, t, provider_name)
  local r     = 18
  local segs  = 10
  local speed = 2.5

  for i = 0, segs - 1 do
    local angle  = (i / segs) * math.pi * 2 + t * speed
    local alpha  = math.floor(255 * (i / segs))
    local sx = cx + math.cos(angle) * r
    local sy = cy + math.sin(angle) * r
    local color  = {90, 140, 240, alpha}
    draw_rect(sx - 2, sy - 2, 4, 4, color)
  end

  local font = style.font
  local msg  = string.format("Analyzing codebase via %s...", provider_name or "AI")
  local mw   = font:get_width(msg)
  renderer.draw_text(font, msg, math.floor(cx - mw / 2), math.floor(cy + r + 10), COLORS.spinner)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw error message in center of view
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.draw_error(view, msg, cx, cy)
  local font = style.font
  local pad  = 16
  local mw   = font:get_width(msg)
  local mh   = font:get_height()
  local bx   = cx - mw / 2 - pad
  local by   = cy - mh / 2 - pad
  local bw   = mw + pad * 2
  local bh   = mh + pad * 2

  draw_rect(bx, by, bw, bh, COLORS.error_bg)
  draw_rect(bx, by, bw, 1,  {180, 60, 60, 255})
  draw_rect(bx, by + bh - 1, bw, 1, {180, 60, 60, 255})

  renderer.draw_text(font, msg, math.floor(cx - mw / 2), math.floor(cy - mh / 2), COLORS.error_text)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw "nothing to map" empty state
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.draw_empty(view, cx, cy, label)
  local font = style.font
  label = label or "Nothing to map"
  local nw = 180
  local nh = 60
  local bx = cx - nw / 2
  local by = cy - nh / 2

  draw_rect(bx - 1, by - 1, nw + 2, nh + 2, COLORS.node_border)
  draw_rect(bx, by, nw, nh, COLORS.node_default)

  local tw = font:get_width(label)
  local th = font:get_height()
  renderer.draw_text(font, label, math.floor(bx + (nw - tw) / 2), math.floor(by + (nh - th) / 2), COLORS.empty_text)

  local sub = "Open a multi-file project and press Ctrl+Shift+V"
  local sfont = style.code_font
  local sw  = sfont:get_width(sub)
  renderer.draw_text(sfont, sub, math.floor(cx - sw / 2), math.floor(by + nh + 12), COLORS.empty_text)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Draw Component Deep-Dive Inspector Drawer
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.draw_inspector(view, node, edges, ix, iy, iw, ih, mouse_x, mouse_y)
  local font   = style.font
  local fsmall = style.code_font

  draw_rect(ix, iy, iw, ih, { 20, 24, 34, 252 })
  draw_rect(ix, iy, 1, ih, { 55, 68, 95, 255 })

  if not node then
    renderer.draw_text(fsmall, "Select a component to inspect", math.floor(ix + 16), math.floor(iy + 24), COLORS.status_text)
    return {}
  end

  local cur_y = iy + 12

  -- 1. Drawer Header (Title & Close Button)
  local title = truncate(node.label or node.id, font, iw - 50)
  renderer.draw_text(font, title, math.floor(ix + 14), math.floor(cur_y), { 245, 250, 255, 255 })

  local cl_w, cl_h = 20, 20
  local cl_x = ix + iw - cl_w - 10
  local cl_y = cur_y
  local cl_hov = is_hovered(mouse_x, mouse_y, cl_x, cl_y, cl_w, cl_h)
  draw_rect(cl_x, cl_y, cl_w, cl_h, cl_hov and { 70, 35, 35, 255 } or { 32, 38, 50, 255 })
  draw_rect(cl_x, cl_y, cl_w, 1,  cl_hov and { 240, 80, 80, 255 } or { 65, 75, 95, 255 })
  renderer.draw_text(font, "x", math.floor(cl_x + 6), math.floor(cl_y + (cl_h - font:get_height()) / 2), cl_hov and { 255, 100, 100, 255 } or { 180, 195, 220, 255 })
  local close_rect = { x = cl_x, y = cl_y, w = cl_w, h = cl_h }

  cur_y = cur_y + font:get_height() + 6

  local is_sug = (node.suggested == true or (node.external == true and (not node.file or node.file == "")) or (not node.file or node.file == ""))
  -- Tier / Cloud Badge Pill
  local tier_text = node.tier and string.format(" TIER: %s ", node.tier:upper()) or " TIER: SERVICE "
  if is_sug then
    tier_text = tier_text .. "[SUGGESTION] "
  elseif node.external then
    tier_text = tier_text .. "[CLOUD] "
  else
    tier_text = tier_text .. "[CODE] "
  end
  local tw_tier = fsmall:get_width(tier_text) + 8
  draw_rect(ix + 14, cur_y, tw_tier, 18, is_sug and { 60, 42, 16, 220 } or { 32, 42, 60, 220 })
  draw_rect(ix + 14, cur_y, tw_tier, 1,  is_sug and { 245, 158, 11, 255 } or { 70, 95, 150, 255 })
  renderer.draw_text(fsmall, tier_text, math.floor(ix + 18), math.floor(cur_y + (18 - fsmall:get_height()) / 2), is_sug and { 254, 240, 138, 255 } or { 140, 215, 255, 255 })

  cur_y = cur_y + 26

  if is_sug then
    draw_rect(ix + 14, cur_y, iw - 28, 34, { 48, 32, 12, 230 })
    draw_rect(ix + 14, cur_y, iw - 28, 1,  { 245, 158, 11, 255 })
    renderer.draw_text(fsmall, "AI ARCHITECTURAL SUGGESTION", math.floor(ix + 20), math.floor(cur_y + 4), { 254, 240, 138, 255 })
    renderer.draw_text(fsmall, "Inferred tool (Not found in project source code).", math.floor(ix + 20), math.floor(cur_y + 18), { 220, 200, 160, 230 })
    cur_y = cur_y + 40
  end

  -- 2. Action Bar: [Focus] [Impact] [Flow] [Jump Code]
  local btn_w = math.floor((iw - 40) / 4)
  local btn_h = 24

  local is_focused = (view and view.focus_node_id == node.id)
  local f_label = is_focused and "Exit" or "Focus"
  local fx = ix + 14
  local f_hov = is_hovered(mouse_x, mouse_y, fx, cur_y, btn_w, btn_h)
  draw_rect(fx, cur_y, btn_w, btn_h, is_focused and { 55, 42, 20, 255 } or (f_hov and COLORS.btn_hover or { 32, 38, 52, 255 }))
  draw_rect(fx, cur_y, btn_w, 1,  is_focused and { 245, 158, 11, 255 } or (f_hov and { 130, 170, 240, 255 } or { 60, 75, 105, 255 }))
  local ftw = fsmall:get_width(f_label)
  renderer.draw_text(fsmall, f_label, math.floor(fx + (btn_w - ftw) / 2), math.floor(cur_y + (btn_h - fsmall:get_height()) / 2), is_focused and { 255, 215, 110, 255 } or COLORS.btn_text)
  local focus_rect = { x = fx, y = cur_y, w = btn_w, h = btn_h }

  local is_impact = (view and view.impact_node_id == node.id)
  local b_label = is_impact and "Clear" or "Impact"
  local bx = fx + btn_w + 4
  local b_hov = is_hovered(mouse_x, mouse_y, bx, cur_y, btn_w, btn_h)
  draw_rect(bx, cur_y, btn_w, btn_h, is_impact and { 60, 28, 35, 255 } or (b_hov and COLORS.btn_hover or { 32, 38, 52, 255 }))
  draw_rect(bx, cur_y, btn_w, 1,  is_impact and { 244, 63, 94, 255 } or (b_hov and { 130, 170, 240, 255 } or { 60, 75, 105, 255 }))
  local btw = fsmall:get_width(b_label)
  renderer.draw_text(fsmall, b_label, math.floor(bx + (btn_w - btw) / 2), math.floor(cur_y + (btn_h - fsmall:get_height()) / 2), is_impact and { 255, 150, 170, 255 } or COLORS.btn_text)
  local impact_rect = { x = bx, y = cur_y, w = btn_w, h = btn_h }

  local is_flow = (view and view.flow_trace and view.flow_trace.source == node.id)
  local fl_label = is_flow and "Stop" or "Flow"
  local flx = bx + btn_w + 4
  local fl_hov = is_hovered(mouse_x, mouse_y, flx, cur_y, btn_w, btn_h)
  draw_rect(flx, cur_y, btn_w, btn_h, is_flow and { 25, 45, 60, 255 } or (fl_hov and COLORS.btn_hover or { 32, 38, 52, 255 }))
  draw_rect(flx, cur_y, btn_w, 1,  is_flow and { 56, 189, 248, 255 } or (fl_hov and { 130, 170, 240, 255 } or { 60, 75, 105, 255 }))
  local fltw = fsmall:get_width(fl_label)
  renderer.draw_text(fsmall, fl_label, math.floor(flx + (btn_w - fltw) / 2), math.floor(cur_y + (btn_h - fsmall:get_height()) / 2), is_flow and { 125, 211, 252, 255 } or COLORS.btn_text)
  local flow_rect = { x = flx, y = cur_y, w = btn_w, h = btn_h }

  local j_label = "Code->"
  local jx = flx + btn_w + 4
  local j_hov = is_hovered(mouse_x, mouse_y, jx, cur_y, btn_w, btn_h)
  draw_rect(jx, cur_y, btn_w, btn_h, j_hov and COLORS.btn_hover or { 32, 38, 52, 255 })
  draw_rect(jx, cur_y, btn_w, 1,  j_hov and { 130, 170, 240, 255 } or { 60, 75, 105, 255 })
  local jtw = fsmall:get_width(j_label)
  renderer.draw_text(fsmall, j_label, math.floor(jx + (btn_w - jtw) / 2), math.floor(cur_y + (btn_h - fsmall:get_height()) / 2), { 165, 215, 255, 255 })
  local jump_rect = { x = jx, y = cur_y, w = btn_w, h = btn_h }

  cur_y = cur_y + btn_h + 16

  local function draw_section_hdr(label)
    draw_rect(ix + 14, cur_y, iw - 28, 1, { 45, 55, 75, 200 })
    cur_y = cur_y + 6
    renderer.draw_text(fsmall, label, math.floor(ix + 14), math.floor(cur_y), { 120, 150, 200, 255 })
    cur_y = cur_y + fsmall:get_height() + 6
  end

  -- 3. Architecture Purpose & Summary
  draw_section_hdr("PURPOSE & ARCHITECTURE")
  local desc = node.desc or "Core service component responsible for business domain processing."
  local max_desc_w = iw - 28
  local words = {}
  for w in desc:gmatch("%S+") do table.insert(words, w) end
  local line = ""
  for _, w in ipairs(words) do
    local test_l = (line == "") and w or (line .. " " .. w)
    if fsmall:get_width(test_l) <= max_desc_w then
      line = test_l
    else
      renderer.draw_text(fsmall, line, math.floor(ix + 14), math.floor(cur_y), COLORS.tooltip_text)
      cur_y = cur_y + fsmall:get_height() + 2
      line = w
    end
  end
  if line ~= "" then
    renderer.draw_text(fsmall, line, math.floor(ix + 14), math.floor(cur_y), COLORS.tooltip_text)
    cur_y = cur_y + fsmall:get_height() + 2
  end
  cur_y = cur_y + 8

  -- 4. Runtime & Config Matrix
  draw_section_hdr("RUNTIME & CONFIG MATRIX")
  local port_str = (node.type == "gateway") and "8080 (HTTP/REST)" or
                   (node.type == "database") and "5432 (PostgreSQL)" or
                   (node.type == "cache") and "6379 (Redis TCP)" or
                   (node.type == "queue") and "9092 (Kafka AMQP)" or "Dynamic Port"
  local env_str = (node.type == "database") and "DATABASE_URL, DB_POOL" or
                  (node.type == "cache") and "REDIS_HOST, REDIS_PORT" or
                  (node.type == "gateway") and "PORT, CORS_ORIGIN, JWT_SECRET" or "APP_ENV, LOG_LEVEL"

  renderer.draw_text(fsmall, "Tech: " .. (node.tech or "Unspecified"), math.floor(ix + 14), math.floor(cur_y), { 160, 200, 250, 255 })
  cur_y = cur_y + fsmall:get_height() + 3
  renderer.draw_text(fsmall, "Port/Proto: " .. port_str, math.floor(ix + 14), math.floor(cur_y), { 140, 175, 215, 255 })
  cur_y = cur_y + fsmall:get_height() + 3
  renderer.draw_text(fsmall, "Env Keys: " .. env_str, math.floor(ix + 14), math.floor(cur_y), { 215, 185, 120, 255 })
  cur_y = cur_y + fsmall:get_height() + 10

  -- 5. Wiring & Contracts
  draw_section_hdr("WIRING & CONTRACTS")
  local callers = {}
  local deps = {}
  for _, e in ipairs(edges or {}) do
    if e.to == node.id then table.insert(callers, e.from) end
    if e.from == node.id then table.insert(deps, e.to) end
  end

  local neighbor_rects = {}

  local in_hdr = string.format("Callers Inbound (%d):", #callers)
  renderer.draw_text(fsmall, in_hdr, math.floor(ix + 14), math.floor(cur_y), { 130, 215, 245, 255 })
  cur_y = cur_y + fsmall:get_height() + 4
  if #callers == 0 then
    renderer.draw_text(fsmall, "  (Ingress / Entrypoint - 0 callers)", math.floor(ix + 14), math.floor(cur_y), { 120, 130, 145, 255 })
    cur_y = cur_y + fsmall:get_height() + 4
  else
    local pill_x = ix + 14
    for _, cid in ipairs(callers) do
      local plabel = " ^ " .. cid .. " "
      local pw = fsmall:get_width(plabel) + 6
      if pill_x + pw > ix + iw - 14 then
        pill_x = ix + 14
        cur_y = cur_y + 20
      end
      local phov = is_hovered(mouse_x, mouse_y, pill_x, cur_y, pw, 18)
      draw_rect(pill_x, cur_y, pw, 18, phov and { 45, 65, 85, 255 } or { 24, 34, 48, 220 })
      draw_rect(pill_x, cur_y, pw, 1,  phov and { 80, 200, 255, 255 } or { 45, 85, 130, 255 })
      renderer.draw_text(fsmall, plabel, math.floor(pill_x + 3), math.floor(cur_y + (18 - fsmall:get_height()) / 2), { 140, 215, 255, 255 })
      neighbor_rects[cid] = { x = pill_x, y = cur_y, w = pw, h = 18, id = cid }
      pill_x = pill_x + pw + 4
    end
    cur_y = cur_y + 24
  end

  local out_hdr = string.format("Dependencies Outbound (%d):", #deps)
  renderer.draw_text(fsmall, out_hdr, math.floor(ix + 14), math.floor(cur_y), { 255, 200, 110, 255 })
  cur_y = cur_y + fsmall:get_height() + 4
  if #deps == 0 then
    renderer.draw_text(fsmall, "  (Leaf / Terminal Sink - 0 deps)", math.floor(ix + 14), math.floor(cur_y), { 120, 130, 145, 255 })
    cur_y = cur_y + fsmall:get_height() + 4
  else
    local pill_x = ix + 14
    for _, did in ipairs(deps) do
      local plabel = " v " .. did .. " "
      local pw = fsmall:get_width(plabel) + 6
      if pill_x + pw > ix + iw - 14 then
        pill_x = ix + 14
        cur_y = cur_y + 20
      end
      local phov = is_hovered(mouse_x, mouse_y, pill_x, cur_y, pw, 18)
      draw_rect(pill_x, cur_y, pw, 18, phov and { 70, 55, 30, 255 } or { 40, 32, 20, 220 })
      draw_rect(pill_x, cur_y, pw, 1,  phov and { 255, 210, 80, 255 } or { 140, 100, 45, 255 })
      renderer.draw_text(fsmall, plabel, math.floor(pill_x + 3), math.floor(cur_y + (18 - fsmall:get_height()) / 2), { 255, 210, 120, 255 })
      neighbor_rects[did] = { x = pill_x, y = cur_y, w = pw, h = 18, id = did }
      pill_x = pill_x + pw + 4
    end
    cur_y = cur_y + 24
  end

  draw_section_hdr("SOURCE CODE JUMP")
  local is_sug = (node.suggested == true or (node.external == true and (not node.file or node.file == "")) or (not node.file or node.file == ""))
  local file_str = node.file and string.format("%s:%s", node.file, node.line or 1) or (is_sug and "[AI Suggestion - Inferred]" or "[Managed Cloud Infrastructure]")
  renderer.draw_text(fsmall, truncate(file_str, fsmall, iw - 28), math.floor(ix + 14), math.floor(cur_y), { 120, 180, 255, 255 })

  return {
    close_rect     = close_rect,
    focus_rect     = focus_rect,
    impact_rect    = impact_rect,
    flow_rect      = flow_rect,
    jump_rect      = jump_rect,
    neighbor_rects = neighbor_rects,
  }
end

DiagramRenderer.TOOLBAR_H = TOOLBAR_H
DiagramRenderer.RAIL_W    = RAIL_W
DiagramRenderer.TAB_H     = TAB_H
DiagramRenderer.STATUS_H  = STATUS_H
DiagramRenderer.STRIP_W      = 60
DiagramRenderer.RIGHT_RAIL_W = 380

return DiagramRenderer
