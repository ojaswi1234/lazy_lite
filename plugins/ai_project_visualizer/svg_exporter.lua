-- mod-version:3
-- SVG Exporter for AI Project Visualizer
-- Serializes diagram data to SVG files in {project_root}/.visualizer/
-- Uses pixel-perfect orthogonal Manhattan channel routing matching canvas rendering.

local SVGExporter = {}
local common = require "core.common"

local BASE_NODE_W = 230
local BASE_NODE_H = 84

-- ─────────────────────────────────────────────────────────────────────────────
-- XML escape helper
-- ─────────────────────────────────────────────────────────────────────────────
local function xml_escape(s)
  if type(s) ~= "string" then s = tostring(s or "") end
  return s
    :gsub("&",  "&amp;")
    :gsub("<",  "&lt;")
    :gsub(">",  "&gt;")
    :gsub('"',  "&quot;")
    :gsub("'",  "&apos;")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Color palette by node type (hex strings for SVG)
-- ─────────────────────────────────────────────────────────────────────────────
local function node_fill(ntype)
  ntype = (ntype or ""):lower()
  if     ntype == "gateway" or ntype == "ingress"       then return "#2369BE", "#3B8CE8"
  elseif ntype == "endpoint" or ntype == "api"         then return "#2D75C8", "#4A9AE8"
  elseif ntype == "service" or ntype == "controller"   then return "#1E8C9E", "#30ABC0"
  elseif ntype == "domain" or ntype == "entity" or ntype == "model" then return "#783CA5", "#9B55CC"
  elseif ntype == "database" or ntype == "db"          then return "#2D914B", "#45B868"
  elseif ntype == "cache"                              then return "#D2821E", "#EAA03C"
  elseif ntype == "queue" or ntype == "broker"         then return "#BE3764", "#DC5582"
  elseif ntype == "cloud" or ntype == "external"       then return "#464BAF", "#646CD2"
  elseif ntype == "auth" or ntype == "security"        then return "#BE3232", "#DC5050"
  elseif ntype == "middleware"                         then return "#B98719", "#D7A532"
  elseif ntype == "storage"                            then return "#505A69", "#738094"
  elseif ntype == "component" or ntype == "module"     then return "#5A4682", "#7D64B0"
  elseif ntype == "ui"                                 then return "#BE5A23", "#DC783C"
  elseif ntype == "config"                             then return "#4B505F", "#697082"
  else                                                      return "#484858", "#686878"
  end
end

local function edge_stroke(etype)
  etype = (etype or ""):lower()
  if     etype == "http" or etype == "rest"            then return "#4B9BE8"
  elseif etype == "grpc"                               then return "#30B4C8"
  elseif etype == "sql" or etype == "db" or etype == "query" then return "#46B96E"
  elseif etype == "cache"                              then return "#EBA53C"
  elseif etype == "event" or etype == "pubsub"         then return "#EB6E3C"
  elseif etype == "queue" or etype == "msg"            then return "#DC5582"
  elseif etype == "auth"                               then return "#DC5050"
  elseif etype == "inject" or etype == "imports"       then return "#78829B"
  end
  return "#646E82"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Compute bounding box of all nodes to size the SVG canvas
-- ─────────────────────────────────────────────────────────────────────────────
local function bounding_box(nodes)
  local min_x, min_y =  math.huge,  math.huge
  local max_x, max_y = -math.huge, -math.huge
  for _, n in ipairs(nodes) do
    local x = n.x or 0
    local y = n.y or 0
    local w = n.w or BASE_NODE_W
    local h = n.h or BASE_NODE_H
    if x     < min_x then min_x = x     end
    if y     < min_y then min_y = y     end
    if x + w > max_x then max_x = x + w end
    if y + h > max_y then max_y = y + h end
  end
  if min_x == math.huge then return 0, 0, 800, 600 end
  return min_x, min_y, max_x - min_x, max_y - min_y
end

-- Simple monospace font width estimate (7px per char)
local function font_estimate_width(s)
  return #(s or "") * 7
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Generate SVG text for one diagram category
-- ─────────────────────────────────────────────────────────────────────────────
local function generate_svg(category_name, nodes, edges, padding)
  padding = padding or 60

  if #nodes == 0 then
    return table.concat({
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200">',
      '<rect width="400" height="200" fill="#1E1E22"/>',
      '<text x="200" y="105" font-family="monospace" font-size="14" fill="#686878" text-anchor="middle">',
      xml_escape(category_name) .. ': No data',
      '</text>',
      '</svg>',
    }, "\n")
  end

  local bx, by, bw, bh = bounding_box(nodes)
  local svg_w = bw + padding * 2
  local svg_h = bh + padding * 2
  local off_x = -bx + padding
  local off_y = -by + padding

  local node_map = {}
  for _, n in ipairs(nodes) do node_map[n.id] = n end

  local parts = {}

  -- SVG header
  table.insert(parts, '<?xml version="1.0" encoding="UTF-8"?>')
  table.insert(parts, string.format(
    '<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="%.0f" style="background:#1E1E22">',
    svg_w, svg_h
  ))

  -- Defs: arrowhead markers & drop shadow
  table.insert(parts, '<defs>')
  table.insert(parts, [[  <marker id="arrow" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
    <polygon points="0 1, 8 4, 0 7" fill="#6488C8"/>
  </marker>]])
  table.insert(parts, [[  <marker id="arrow-rev" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
    <polygon points="0 1, 8 4, 0 7" fill="#505060"/>
  </marker>]])
  table.insert(parts, [[  <filter id="shadow" x="-10%" y="-10%" width="120%" height="120%">
    <feDropShadow dx="2" dy="3" stdDeviation="3" flood-color="#000000" flood-opacity="0.5"/>
  </filter>]])
  table.insert(parts, '</defs>')

  -- Title & Interconnectivity Subtitle
  table.insert(parts, string.format(
    '<text x="%.0f" y="28" font-family="monospace" font-size="16" font-weight="bold" fill="#A0B4E8" text-anchor="middle">%s</text>',
    svg_w / 2, xml_escape(category_name)
  ))
  local density = #edges / math.max(#nodes, 1)
  table.insert(parts, string.format(
    '<text x="%.0f" y="46" font-family="monospace" font-size="11" fill="#7085A8" text-anchor="middle">Interconnectivity Mesh: %d nodes, %d links (%.1fx density)</text>',
    svg_w / 2, #nodes, #edges, density
  ))

  -- Edges (Orthogonal Manhattan Routing)
  for _, e in ipairs(edges) do
    local src = node_map[e.from]
    local dst = node_map[e.to]
    if src and dst then
      local sw = (src.w or BASE_NODE_W)
      local sh = (src.h or BASE_NODE_H)
      local dw = (dst.w or BASE_NODE_W)
      local dh = (dst.h or BASE_NODE_H)

      local sx = (e.src_x or ((src.x or 0) + sw / 2)) + off_x
      local sy = (e.src_y or ((src.y or 0) + sh)) + off_y
      local dx = (e.dst_x or ((dst.x or 0) + dw / 2)) + off_x
      local dy = (e.dst_y or (dst.y or 0)) + off_y

      local track_idx    = e.track_idx or 0
      local total_tracks = e.total_tracks or 1

      local marker    = e.reversed and 'url(#arrow-rev)' or 'url(#arrow)'
      local stroke    = e.reversed and "#505060" or edge_stroke(e.type)
      local dash_attr = e.reversed and ' stroke-dasharray="6,3"' or ''

      local path_d
      local lx, ly

      local src_y = src.y or 0
      local dst_y = dst.y or 0
      if dst_y > src_y + sh + 15 then
        -- Forward Downward Channel
        local frac = (track_idx + 1) / (total_tracks + 1)
        local track_y = sy + 12 + frac * math.max(dy - sy - 24, 10)
        path_d = string.format("M%.1f,%.1f V%.1f H%.1f V%.1f", sx, sy, track_y, dx, dy - 6)
        local stagger_factors = { 0.50, 0.35, 0.65, 0.22, 0.78 }
        local s_frac = stagger_factors[((track_idx or 0) % #stagger_factors) + 1]
        lx = sx + (dx - sx) * s_frac
        ly = track_y - 6
      elseif math.abs(dst_y - src_y) <= 20 then
        -- Intra-row Channel
        local track_y = sy + 12 + ((track_idx + 1) * 14)
        local target_y = dst_y + dh + off_y
        path_d = string.format("M%.1f,%.1f V%.1f H%.1f V%.1f", sx, sy, track_y, dx, target_y + 6)
        lx = (sx + dx) / 2
        ly = track_y + 12
      else
        -- Upward Feedback Loop via Gutter
        local gutter_pad = (track_idx + 1) * 18
        local src_left = (src.x or 0) + off_x
        local dst_left = (dst.x or 0) + off_x
        local use_left = (sx + dx) / 2 < ((src_left + dst_left) / 2)
        local gutter_x = use_left and (math.min(src_left, dst_left) - gutter_pad)
                                  or  (math.max(src_left + sw, dst_left + dw) + gutter_pad)
        local exit_y = sy + 8
        local enter_y = dy - 12
        path_d = string.format("M%.1f,%.1f V%.1f H%.1f V%.1f H%.1f V%.1f",
          sx, sy, exit_y, gutter_x, enter_y, dx, dy - 6)
        lx = gutter_x + (use_left and 14 or -14)
        ly = (exit_y + enter_y) / 2
      end

      table.insert(parts, string.format(
        '<path d="%s" fill="none" stroke="%s" stroke-width="1.5"%s marker-end="%s" data-from="%s" data-to="%s" data-type="%s"/>',
        path_d, stroke, dash_attr, marker, xml_escape(e.from or ""), xml_escape(e.to or ""), xml_escape(e.type or "")
      ))

      -- Edge label
      if e.label and #e.label > 0 then
        local ew = font_estimate_width(e.label)
        table.insert(parts, string.format(
          '<rect x="%.1f" y="%.1f" width="%.0f" height="16" rx="2" fill="#16161A" opacity="0.85"/>',
          lx - ew / 2 - 3, ly - 2, ew + 6
        ))
        table.insert(parts, string.format(
          '<text x="%.1f" y="%.1f" font-family="monospace" font-size="10" fill="#8090A0" text-anchor="middle">%s</text>',
          lx, ly + 10, xml_escape(e.label)
        ))
      end
    end
  end

  -- Nodes
  for _, n in ipairs(nodes) do
    local nx  = (n.x or 0) + off_x
    local ny  = (n.y or 0) + off_y
    local nw  = n.w or BASE_NODE_W
    local nh  = n.h or BASE_NODE_H
    local fill, accent = node_fill(n.type)
    local is_ext = (n.external == true)
    local stroke_w = is_ext and "2" or "1"
    local stroke_col = is_ext and "#8CA5E0" or accent
    local top_accent = is_ext and "#DCE6FF" or accent

    -- Group wrapper for node
    table.insert(parts, string.format(
      '<g id="node-%s" data-id="%s" data-tier="%s" data-tech="%s">',
      xml_escape(n.id or ""), xml_escape(n.id or ""), xml_escape(n.tier or ""), xml_escape(n.tech or "")
    ))

    -- Shadow + outer rect
    table.insert(parts, string.format(
      '<rect x="%.1f" y="%.1f" width="%d" height="%d" rx="4" ry="4" fill="%s" filter="url(#shadow)"/>',
      nx, ny, nw, nh, fill
    ))
    -- Accent top bar
    table.insert(parts, string.format(
      '<rect x="%.1f" y="%.1f" width="%d" height="3" rx="2" ry="2" fill="%s"/>',
      nx, ny, nw, top_accent
    ))

    -- Border
    table.insert(parts, string.format(
      '<rect x="%.1f" y="%.1f" width="%d" height="%d" rx="4" ry="4" fill="none" stroke="%s" stroke-width="%s" opacity="0.7"/>',
      nx - 0.5, ny - 0.5, nw + 1, nh + 1, stroke_col, stroke_w
    ))

    -- 3-Tier Card Typography
    -- Tier 1: Type / Subsystem Tag
    local type_tag = "[" .. (n.type or "component"):upper() .. "]"
    if #type_tag > 24 then type_tag = type_tag:sub(1, 21) .. "...]" end
    table.insert(parts, string.format(
      '<text x="%.1f" y="%.1f" font-family="monospace" font-size="10" fill="#94A3B8" text-anchor="middle">%s</text>',
      nx + nw / 2, ny + 17, xml_escape(type_tag)
    ))

    -- Tier 2: Bold Component Title
    local label = n.label or n.id
    if #label > 28 then label = label:sub(1, 25) .. "..." end
    table.insert(parts, string.format(
      '<text x="%.1f" y="%.1f" font-family="sans-serif, system-ui" font-size="12" font-weight="bold" fill="#F1F5F9" text-anchor="middle">%s</text>',
      nx + nw / 2, ny + 38, xml_escape(label)
    ))

    -- Tier 3: Tech Stack Pill
    local tech_str = (n.tech and #n.tech > 0) and n.tech or (n.type or "service")
    if #tech_str > 26 then tech_str = tech_str:sub(1, 23) .. "..." end
    local pill_w = math.max(60, #tech_str * 7 + 16)
    table.insert(parts, string.format(
      '<rect x="%.1f" y="%.1f" width="%.1f" height="18" rx="3" fill="#111827" stroke="#334155" stroke-width="0.8" opacity="0.85"/>',
      nx + (nw - pill_w) / 2, ny + 49, pill_w
    ))
    table.insert(parts, string.format(
      '<text x="%.1f" y="%.1f" font-family="monospace" font-size="10" fill="%s" text-anchor="middle">%s</text>',
      nx + nw / 2, ny + 62, accent, xml_escape(tech_str)
    ))

    -- Tooltip (native SVG title element)
    local tooltip = (n.label or n.id)
    if n.tier then tooltip = tooltip .. "\nTier: " .. n.tier:upper() end
    if n.tech and #n.tech > 0 then tooltip = tooltip .. "\nTech: " .. n.tech end
    if n.desc and #n.desc > 0 then tooltip = tooltip .. "\nRole: " .. n.desc end
    if n.file and not n.external then
      tooltip = tooltip .. "\nFile: " .. n.file .. ":" .. (n.line or 1)
    elseif n.external then
      tooltip = tooltip .. "\n[Managed Cloud / External Service]"
    end
    table.insert(parts, string.format('<title>%s</title>', xml_escape(tooltip)))
    table.insert(parts, '</g>')
  end

  -- Footer legend
  local legend_y = svg_h - 20
  table.insert(parts, string.format(
    '<text x="8" y="%.0f" font-family="monospace" font-size="9" fill="#404858">Generated by AI Project Visualizer</text>',
    legend_y
  ))

  table.insert(parts, '</svg>')

  return table.concat(parts, "\n")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Ensure a directory exists (cross-platform)
-- ─────────────────────────────────────────────────────────────────────────────
local function ensure_dir(path)
  if path and not system.get_file_info(path) then
    pcall(common.mkdirp, path)
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Sanitize a string to be a safe filename
-- ─────────────────────────────────────────────────────────────────────────────
local function safe_filename(s)
  return s
    :lower()
    :gsub('[^a-z0-9_%-]', '_')
    :gsub('__+', '_')
    :gsub('^_+', '')
    :gsub('_+$', '')
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Export all diagram categories to SVG files
-- ─────────────────────────────────────────────────────────────────────────────
function SVGExporter.export(diagrams_data, project_path)
  if not diagrams_data then
    return nil, "No diagram data to export"
  end
  if not project_path or #project_path == 0 then
    return nil, "No project path provided"
  end

  local sep = package.config:sub(1,1)
  local vis_dir = project_path .. sep .. ".visualizer"

  local ok, err_msg = pcall(ensure_dir, vis_dir)
  if not ok then
    return nil, "Could not create .visualizer directory: " .. tostring(err_msg)
  end

  local written = {}

  for category, data in pairs(diagrams_data) do
    local nodes = data.nodes or {}
    local edges = data.edges or {}

    local ok2, svg_or_err = pcall(generate_svg, category, nodes, edges)
    if not ok2 then
      table.insert(written, { error = "Failed to generate SVG for '" .. category .. "': " .. tostring(svg_or_err) })
    else
      local filename  = safe_filename(category) .. ".svg"
      local filepath  = vis_dir .. sep .. filename

      local f, ferr = io.open(filepath, "w")
      if not f then
        table.insert(written, { error = "Could not write " .. filepath .. ": " .. tostring(ferr) })
      else
        f:write(svg_or_err)
        f:close()
        table.insert(written, { path = filepath, category = category })
      end
    end
  end

  if #written == 0 then
    return nil, "No SVG files were written"
  end

  return written, nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Export a single category by name
-- ─────────────────────────────────────────────────────────────────────────────
function SVGExporter.export_category(category, nodes, edges, project_path)
  local data = {}
  data[category] = { nodes = nodes or {}, edges = edges or {} }
  return SVGExporter.export(data, project_path)
end

return SVGExporter
