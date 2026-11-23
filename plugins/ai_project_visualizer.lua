-- mod-version:3
-- =============================================================================
-- AI Project Visualizer for Lite XL
--
-- An AI-powered project analysis and interactive 2D diagram generator that
-- crawls codebases, analyzes architecture via your choice of AI provider
-- (Groq, Ollama / Ollama Cloud, Google Gemini, OpenAI, Anthropic) using API keys
-- stored for the AI Sidebar, and renders multiple categorized interactive
-- diagrams (System Architecture, Data Flow, API Endpoints, Security & Auth,
-- Middleware Chain, Component Dependencies) directly inside Lite XL using its
-- native 2D renderer API.
--
-- Features:
--   - Multi-Provider AI Support: Groq, Ollama Cloud, Gemini, OpenAI, Anthropic
--   - Automatic key discovery from AI Sidebar (ai_api_keys.json, .env, env vars)
--   - Interactive Provider & Model Toggle directly from toolbar [AI: Groq]
--   - Pan & Zoom (zoom-to-cursor with scroll wheel, drag-to-pan)
--   - Clickable nodes that jump directly to source files at specific lines
--   - Hover tooltips showing file path, line, and architectural role
--   - Category tab strip with per-category viewport memory
--   - Force-directed (Fruchterman-Reingold) and Layered (Sugiyama) layout engines
--   - High-quality SVG export to .visualizer/ directory
--   - Disk cache (.visualizer/cache.json) for instant re-opening
--
-- Shortcuts:
--   ctrl+shift+v  - Toggle the AI Project Visualizer panel
--   ctrl+shift+y  - Re-analyze project and regenerate diagrams (clears cache)
--   alt+0         - Cycle to next diagram category tab
-- =============================================================================

local core     = require "core"
local common   = require "core.common"
local style    = require "core.style"
local command  = require "core.command"
local keymap   = require "core.keymap"
local config   = require "core.config"
local View     = require "core.view"

local function ensure_dir(path)
  if path and not system.get_file_info(path) then
    pcall(common.mkdirp, path)
  end
end

-- Forward declarations for all 4 architectural modules and core utilities
local LayoutEngine      = {}
local AIAnalyzer        = {}
local DiagramRenderer   = {}
local SVGExporter       = {}
local get_project_files = nil
local json_decode       = nil
local json_encode       = nil

-- =============================================================================
-- SECTION 1: LAYOUT ENGINE
-- Layout Engine for AI Project Visualizer
-- Implements dynamic, flexible Sugiyama layered layout for DAGs with:
-- 1. Dynamic content-based node sizing (widths fit labels & tech tags cleanly)
-- 2. Multi-row wrapping (prevents single-tier horizontal explosion)
-- 3. Dynamic channel heights (highways expand proportionally to track count)
-- 4. 3-sweep Barycenter crossing minimization
-- 5. Distributed boundary port allocation & Manhattan channel track indexing


local BASE_NODE_W = 230
local BASE_NODE_H = 84
local MAX_ROW_NODES = 4
local H_GAP = 70
local V_ROW_GAP = 55
local MIN_DIST = 1e-6

-- Tier priority order for architectural classification
local TIER_ORDER = {
  ingress        = 0,
  client         = 0,
  gateway        = 0,
  endpoint       = 0,
  api            = 0,
  application    = 1,
  service        = 1,
  controller     = 1,
  orchestration  = 1,
  component      = 1,
  domain         = 2,
  core           = 2,
  model          = 2,
  entity         = 2,
  integration    = 3,
  messaging      = 3,
  queue          = 3,
  broker         = 3,
  auth           = 3,
  security       = 3,
  middleware     = 3,
  persistence    = 4,
  database       = 4,
  db             = 4,
  infrastructure = 4,
  storage        = 4,
  cloud          = 4,
  cache          = 4,
  config         = 4,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Utility helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function node_index(nodes, id)
  for i, n in ipairs(nodes) do
    if n.id == id then return i end
  end
  return nil
end

local function build_adj(nodes, edges)
  local adj = {}
  for _, n in ipairs(nodes) do adj[n.id] = {} end
  for _, e in ipairs(edges) do
    if adj[e.from] then table.insert(adj[e.from], e.to) end
    if adj[e.to]   then table.insert(adj[e.to],   e.from) end
  end
  return adj
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Cycle breaking via DFS (for Sugiyama / layered layout)
-- ─────────────────────────────────────────────────────────────────────────────
function LayoutEngine.break_cycles(nodes, edges)
  local visited    = {}
  local in_stack   = {}
  local result     = {}
  local to_reverse = {}

  local dir_adj = {}
  for _, n in ipairs(nodes) do dir_adj[n.id] = {} end
  for _, e in ipairs(edges) do
    if dir_adj[e.from] then
      table.insert(dir_adj[e.from], e)
    end
  end

  local function dfs(id)
    visited[id]  = true
    in_stack[id] = true
    for _, e in ipairs(dir_adj[id] or {}) do
      if not visited[e.to] then
        dfs(e.to)
      elseif in_stack[e.to] then
        to_reverse[e] = true
      end
    end
    in_stack[id] = false
  end

  for _, n in ipairs(nodes) do
    if not visited[n.id] then dfs(n.id) end
  end

  for _, e in ipairs(edges) do
    local copy = {}
    for k, v in pairs(e) do copy[k] = v end
    if to_reverse[e] then
      copy.from     = e.to
      copy.to       = e.from
      copy.reversed = true
    end
    table.insert(result, copy)
  end
  return result
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Separate graph into connected components (undirected BFS)
-- ─────────────────────────────────────────────────────────────────────────────
function LayoutEngine.separate_components(nodes, edges)
  if #nodes == 0 then return {} end

  local adj        = build_adj(nodes, edges)
  local assigned   = {}
  local components = {}

  for _, n in ipairs(nodes) do
    if not assigned[n.id] then
      local comp_ids = {}
      local queue    = { n.id }
      assigned[n.id] = true
      local head = 1
      while head <= #queue do
        local cur = queue[head]; head = head + 1
        table.insert(comp_ids, cur)
        for _, nb in ipairs(adj[cur] or {}) do
          if not assigned[nb] then
            assigned[nb] = true
            table.insert(queue, nb)
          end
        end
      end

      local id_set = {}
      for _, id in ipairs(comp_ids) do id_set[id] = true end

      local comp_nodes = {}
      local comp_edges = {}
      for _, node in ipairs(nodes) do
        if id_set[node.id] then table.insert(comp_nodes, node) end
      end
      for _, edge in ipairs(edges) do
        if id_set[edge.from] and id_set[edge.to] then
          table.insert(comp_edges, edge)
        end
      end
      table.insert(components, { nodes = comp_nodes, edges = comp_edges })
    end
  end
  return components
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Fruchterman–Reingold force-directed layout
-- ─────────────────────────────────────────────────────────────────────────────
function LayoutEngine.force_directed(nodes, edges, width, height, iterations)
  if #nodes == 0 then return end
  iterations = iterations or 300
  width  = width  or 800
  height = height or 600

  local W = math.max(width  - BASE_NODE_W * 2, 100)
  local H = math.max(height - BASE_NODE_H * 2, 100)

  math.randomseed(42)
  for _, n in ipairs(nodes) do
    n.w = n.w or BASE_NODE_W
    n.h = n.h or BASE_NODE_H
    if not n.x or not n.y then
      n.x = math.random() * W + BASE_NODE_W
      n.y = math.random() * H + BASE_NODE_H
    end
  end

  if #nodes == 1 then
    nodes[1].x = width  / 2
    nodes[1].y = height / 2
    return
  end

  local area = W * H
  local k    = math.sqrt(area / #nodes)
  local k2   = k * k

  local function fr_repulsion(d) return k2 / math.max(d, MIN_DIST) end
  local function fr_attraction(d) return (d * d) / k end

  local dx = {}
  local dy = {}
  local temp = W * 0.1

  for iter = 1, iterations do
    for i = 1, #nodes do dx[i] = 0; dy[i] = 0 end

    -- Repulsion
    for i = 1, #nodes do
      for j = i + 1, #nodes do
        local ni = nodes[i]
        local nj = nodes[j]
        local ex = ni.x - nj.x
        local ey = ni.y - nj.y
        local dist = math.sqrt(ex * ex + ey * ey)
        if dist < MIN_DIST then
          ex = (math.random() - 0.5) * 0.1
          ey = (math.random() - 0.5) * 0.1
          dist = math.sqrt(ex * ex + ey * ey)
          if dist < MIN_DIST then dist = MIN_DIST end
        end
        local rep = fr_repulsion(dist)
        local ux  = ex / dist
        local uy  = ey / dist
        dx[i] = dx[i] + ux * rep
        dy[i] = dy[i] + uy * rep
        dx[j] = dx[j] - ux * rep
        dy[j] = dy[j] - uy * rep
      end
    end

    -- Attraction
    for _, e in ipairs(edges) do
      local si = node_index(nodes, e.from)
      local ti = node_index(nodes, e.to)
      if si and ti then
        local ni = nodes[si]
        local nj = nodes[ti]
        local ex = nj.x - ni.x
        local ey = nj.y - ni.y
        local dist = math.sqrt(ex * ex + ey * ey)
        if dist > MIN_DIST then
          local att = fr_attraction(dist)
          local ux  = ex / dist
          local uy  = ey / dist
          dx[si] = dx[si] + ux * att
          dy[si] = dy[si] + uy * att
          dx[ti] = dx[ti] - ux * att
          dy[ti] = dy[ti] - uy * att
        end
      end
    end

    -- Apply displacement
    for i, n in ipairs(nodes) do
      local mag = math.sqrt(dx[i] * dx[i] + dy[i] * dy[i])
      if mag > MIN_DIST then
        local factor = math.min(mag, temp) / mag
        n.x = clamp(n.x + dx[i] * factor, BASE_NODE_W, W + BASE_NODE_W)
        n.y = clamp(n.y + dy[i] * factor, BASE_NODE_H, H + BASE_NODE_H)
      end
    end

    temp = math.max(temp * (1 - iter / iterations), 1.0)
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Dynamic Layered Layout Engine
-- Content-adaptive sizing, multi-row wrapping, dynamic channel heights
-- ─────────────────────────────────────────────────────────────────────────────
function LayoutEngine.layered(nodes, edges, width, height)
  if #nodes == 0 then return end
  width  = width  or 800
  height = height or 600

  local node_map = {}
  for _, n in ipairs(nodes) do
    node_map[n.id] = n
    -- Dynamic node width based on label and tech length
    local lbl_len  = #(n.label or n.id or "")
    local tech_len = #(n.tech or n.type or "")
    local w_lbl  = math.floor(lbl_len * 9.5 + 46)
    local w_tech = math.floor(tech_len * 8.5 + 46)
    n.w = math.max(BASE_NODE_W, math.max(w_lbl, w_tech))
    n.h = BASE_NODE_H
  end

  -- Phase 1: Cycle breaking
  local safe_edges = LayoutEngine.break_cycles(nodes, edges)

  -- Topological layer assignment with Kahn's DAG traversal
  local in_degree = {}
  local children  = {}
  for _, n in ipairs(nodes) do
    in_degree[n.id] = 0
    children[n.id]  = {}
  end
  for _, e in ipairs(safe_edges) do
    if in_degree[e.to] ~= nil then
      in_degree[e.to] = in_degree[e.to] + 1
    end
    if children[e.from] then
      table.insert(children[e.from], e.to)
    end
  end

  local layer = {}
  local queue = {}
  for _, n in ipairs(nodes) do
    if (in_degree[n.id] or 0) == 0 then
      table.insert(queue, n.id)
      layer[n.id] = 0
    end
  end

  local head = 1
  while head <= #queue do
    local cur = queue[head]; head = head + 1
    for _, child_id in ipairs(children[cur] or {}) do
      layer[child_id] = math.max(layer[child_id] or 0, (layer[cur] or 0) + 1)
      in_degree[child_id] = in_degree[child_id] - 1
      if in_degree[child_id] == 0 then
        table.insert(queue, child_id)
      end
    end
  end

  -- Blend tier classifications
  for _, n in ipairs(nodes) do
    local t_str = (n.tier or n.type or ""):lower()
    local t_order = TIER_ORDER[t_str]
    if t_order then
      layer[n.id] = math.max(layer[n.id] or 0, t_order)
    else
      layer[n.id] = layer[n.id] or 0
    end
    n.orig_layer = layer[n.id]
  end

  -- Phase 2: Layer Compaction (remap gaps so tiers are strictly contiguous 0..M)
  local present_layers = {}
  for _, n in ipairs(nodes) do
    present_layers[n.orig_layer] = true
  end
  local sorted_layers = {}
  for l_idx in pairs(present_layers) do
    table.insert(sorted_layers, l_idx)
  end
  table.sort(sorted_layers)

  local layer_remap = {}
  for new_idx, old_idx in ipairs(sorted_layers) do
    layer_remap[old_idx] = new_idx - 1
  end

  local max_layer = 0
  local layers = {}
  for new_idx = 0, #sorted_layers - 1 do
    layers[new_idx] = {}
  end

  for _, n in ipairs(nodes) do
    local comp_l = layer_remap[n.orig_layer] or 0
    n.layer = comp_l
    table.insert(layers[comp_l], n)
    if comp_l > max_layer then max_layer = comp_l end
  end

  -- Phase 3: Barycenter Crossing Minimization (3 alternating sweeps)
  local in_neighbors  = {}
  local out_neighbors = {}
  for _, n in ipairs(nodes) do
    in_neighbors[n.id]  = {}
    out_neighbors[n.id] = {}
  end
  for _, e in ipairs(edges) do
    if node_map[e.from] and node_map[e.to] then
      table.insert(out_neighbors[e.from], e.to)
      table.insert(in_neighbors[e.to],    e.from)
    end
  end

  for li = 0, max_layer do
    if layers[li] then
      for idx, n in ipairs(layers[li]) do
        n.order = idx
      end
    end
  end

  for _ = 1, 3 do
    -- Downward sweep
    for li = 1, max_layer do
      local l_nodes = layers[li]
      if l_nodes and #l_nodes > 1 then
        for _, n in ipairs(l_nodes) do
          local parents = in_neighbors[n.id]
          if parents and #parents > 0 then
            local sum_pos = 0
            for _, pid in ipairs(parents) do
              sum_pos = sum_pos + (node_map[pid] and node_map[pid].order or 1)
            end
            n.bary = sum_pos / #parents
          else
            n.bary = n.order
          end
        end
        table.sort(l_nodes, function(a, b)
          if a.bary ~= b.bary then return a.bary < b.bary end
          return (a.order or 0) < (b.order or 0)
        end)
        for idx, n in ipairs(l_nodes) do n.order = idx end
      end
    end

    -- Upward sweep
    for li = max_layer - 1, 0, -1 do
      local l_nodes = layers[li]
      if l_nodes and #l_nodes > 1 then
        for _, n in ipairs(l_nodes) do
          local ch = out_neighbors[n.id]
          if ch and #ch > 0 then
            local sum_pos = 0
            for _, cid in ipairs(ch) do
              sum_pos = sum_pos + (node_map[cid] and node_map[cid].order or 1)
            end
            n.bary = sum_pos / #ch
          else
            n.bary = n.order
          end
        end
        table.sort(l_nodes, function(a, b)
          if a.bary ~= b.bary then return a.bary < b.bary end
          return (a.order or 0) < (b.order or 0)
        end)
        for idx, n in ipairs(l_nodes) do n.order = idx end
      end
    end
  end

  -- Phase 4: Multi-Row Wrapping (Chunk tiers with > MAX_ROW_NODES nodes)
  local final_rows = {}
  for li = 0, max_layer do
    local l_nodes = layers[li] or {}
    if #l_nodes <= MAX_ROW_NODES then
      table.insert(final_rows, { layer_idx = li, nodes = l_nodes })
    else
      local i = 1
      while i <= #l_nodes do
        local chunk = {}
        for c = 0, MAX_ROW_NODES - 1 do
          if i + c <= #l_nodes then
            table.insert(chunk, l_nodes[i + c])
          end
        end
        table.insert(final_rows, { layer_idx = li, nodes = chunk })
        i = i + MAX_ROW_NODES
      end
    end
  end

  -- Assign row index to each node
  for r_idx, row in ipairs(final_rows) do
    for _, n in ipairs(row.nodes) do
      n.row_idx = r_idx
    end
  end

  -- Count channel traffic between consecutive rows
  local channel_traffic = {}
  for _, e in ipairs(edges) do
    local s = node_map[e.from]
    local d = node_map[e.to]
    if s and d then
      if s.row_idx < d.row_idx then
        for ri = s.row_idx, d.row_idx - 1 do
          channel_traffic[ri] = (channel_traffic[ri] or 0) + 1
        end
      end
    end
  end

  -- Calculate dynamic vertical row coordinates with generous empty highway channels
  local row_y = {}
  local cur_y = 60
  local prev_l_idx = nil
  for r_idx, row in ipairs(final_rows) do
    if prev_l_idx ~= nil and prev_l_idx ~= row.layer_idx then
      -- Inter-tier channel: expand proportionally to track traffic
      local tracks = channel_traffic[r_idx - 1] or 1
      local channel_h = math.max(55, 30 + tracks * 16)
      cur_y = cur_y + BASE_NODE_H + channel_h
    elseif prev_l_idx ~= nil then
      -- Intra-tier sub-row gap
      cur_y = cur_y + BASE_NODE_H + V_ROW_GAP
    end
    row_y[r_idx] = cur_y
    prev_l_idx = row.layer_idx
  end

  -- Calculate max row width
  local max_row_w = 0
  for _, row in ipairs(final_rows) do
    local w = 0
    for _, n in ipairs(row.nodes) do w = w + n.w end
    w = w + math.max(0, #row.nodes - 1) * H_GAP
    if w > max_row_w then max_row_w = w end
  end

  local canvas_w = math.max(width, max_row_w + 140)

  -- Place nodes centered in their rows
  for r_idx, row in ipairs(final_rows) do
    local w = 0
    for _, n in ipairs(row.nodes) do w = w + n.w end
    w = w + math.max(0, #row.nodes - 1) * H_GAP
    local start_x = (canvas_w - w) / 2
    local cur_x = start_x
    for _, n in ipairs(row.nodes) do
      n.x = cur_x
      n.y = row_y[r_idx]
      cur_x = cur_x + n.w + H_GAP
    end
  end

  -- Phase 5: Distributed Boundary Port Allocation
  local node_out = {}
  local node_in  = {}
  for _, n in ipairs(nodes) do
    node_out[n.id] = {}
    node_in[n.id]  = {}
  end
  for _, e in ipairs(edges) do
    if node_map[e.from] and node_map[e.to] then
      table.insert(node_out[e.from], e)
      table.insert(node_in[e.to],    e)
    end
  end

  for n_id, outs in pairs(node_out) do
    table.sort(outs, function(a, b)
      local da = node_map[a.to] and node_map[a.to].x or 0
      local db = node_map[b.to] and node_map[b.to].x or 0
      return da < db
    end)
    local n = node_map[n_id]
    local count = #outs
    for idx, e in ipairs(outs) do
      e.src_x = n.x + (idx / (count + 1)) * n.w
      e.src_y = n.y + n.h
    end
  end

  for n_id, ins in pairs(node_in) do
    table.sort(ins, function(a, b)
      local sa = node_map[a.from] and node_map[a.from].x or 0
      local sb = node_map[b.from] and node_map[b.from].x or 0
      return sa < sb
    end)
    local n = node_map[n_id]
    local count = #ins
    for idx, e in ipairs(ins) do
      e.dst_x = n.x + (idx / (count + 1)) * n.w
      e.dst_y = n.y
    end
  end

  -- Phase 6: Assign Channel Tracks
  local channels = {}
  for _, e in ipairs(edges) do
    if node_map[e.from] and node_map[e.to] then
      local s = node_map[e.from]
      local d = node_map[e.to]
      local k
      if d.y > s.y + s.h + 15 then
        k = "down_" .. s.row_idx .. "_" .. d.row_idx
      elseif math.abs(d.y - s.y) <= 20 then
        k = "intra_" .. s.row_idx
      else
        k = "up_" .. s.row_idx .. "_" .. d.row_idx
      end
      channels[k] = channels[k] or {}
      table.insert(channels[k], e)
      e.channel_key = k
    end
  end

  for _, ch_edges in pairs(channels) do
    local total = #ch_edges
    for idx, e in ipairs(ch_edges) do
      e.track_idx    = idx
      e.total_tracks = total
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Center nodes and translate edge ports synchronously
-- ─────────────────────────────────────────────────────────────────────────────
function LayoutEngine.center_nodes(nodes, edges, cx, cy)
  if #nodes == 0 then return end
  if type(edges) == "number" then
    cy = cx
    cx = edges
    edges = nil
  end
  cx = cx or 400
  cy = cy or 300

  local min_x, min_y =  math.huge,  math.huge
  local max_x, max_y = -math.huge, -math.huge
  for _, n in ipairs(nodes) do
    min_x = math.min(min_x, n.x)
    min_y = math.min(min_y, n.y)
    max_x = math.max(max_x, n.x + (n.w or BASE_NODE_W))
    max_y = math.max(max_y, n.y + (n.h or BASE_NODE_H))
  end
  local off_x = cx - (min_x + max_x) / 2
  local off_y = cy - (min_y + max_y) / 2
  for _, n in ipairs(nodes) do
    n.x = n.x + off_x
    n.y = n.y + off_y
  end
  if edges then
    for _, e in ipairs(edges) do
      if e.src_x then e.src_x = e.src_x + off_x end
      if e.src_y then e.src_y = e.src_y + off_y end
      if e.dst_x then e.dst_x = e.dst_x + off_x end
      if e.dst_y then e.dst_y = e.dst_y + off_y end
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Full layout pipeline for a category
-- ─────────────────────────────────────────────────────────────────────────────
-- ─────────────────────────────────────────────────────────────────────────────
-- Normalizes node and edge coordinates so min_x and min_y are strictly positive
-- ─────────────────────────────────────────────────────────────────────────────
function LayoutEngine.normalize_nodes(nodes, edges, margin_x, margin_y)
  if not nodes or #nodes == 0 then return end
  margin_x = margin_x or 60
  margin_y = margin_y or 60

  local min_x, min_y = math.huge, math.huge
  for _, n in ipairs(nodes) do
    min_x = math.min(min_x, n.x or 0)
    min_y = math.min(min_y, n.y or 0)
  end
  if min_x == math.huge then return end

  local off_x = margin_x - min_x
  local off_y = margin_y - min_y
  for _, n in ipairs(nodes) do
    n.x = (n.x or 0) + off_x
    n.y = (n.y or 0) + off_y
  end
  if edges then
    for _, e in ipairs(edges) do
      if e.src_x then e.src_x = e.src_x + off_x end
      if e.src_y then e.src_y = e.src_y + off_y end
      if e.dst_x then e.dst_x = e.dst_x + off_x end
      if e.dst_y then e.dst_y = e.dst_y + off_y end
    end
  end
end

function LayoutEngine.run(nodes, edges, width, height)
  if #nodes == 0 then return nodes, edges end
  if #nodes == 1 then
    nodes[1].x = (width  or 400) / 2
    nodes[1].y = (height or 300) / 2
    nodes[1].w = nodes[1].w or BASE_NODE_W
    nodes[1].h = nodes[1].h or BASE_NODE_H
    return nodes, edges
  end

  local safe_edges = LayoutEngine.break_cycles(nodes, edges)
  local components = LayoutEngine.separate_components(nodes, safe_edges)

  -- Sequentially place subgraphs using measured bounding boxes with strict 140px margins
  local cur_offset_x = 60
  for _, comp in ipairs(components) do
    LayoutEngine.layered(comp.nodes, comp.edges, width, height)

    local min_x, max_x = math.huge, -math.huge
    for _, n in ipairs(comp.nodes) do
      min_x = math.min(min_x, n.x or 0)
      max_x = math.max(max_x, (n.x or 0) + (n.w or BASE_NODE_W))
    end
    if min_x == math.huge then min_x, max_x = 0, 0 end

    local shift_x = cur_offset_x - min_x
    for _, n in ipairs(comp.nodes) do
      n.x = n.x + shift_x
    end
    for _, e in ipairs(comp.edges) do
      if e.src_x then e.src_x = e.src_x + shift_x end
      if e.dst_x then e.dst_x = e.dst_x + shift_x end
    end

    local comp_w = max_x - min_x
    cur_offset_x = cur_offset_x + comp_w + 140
  end

  LayoutEngine.normalize_nodes(nodes, safe_edges, 60, 60)
  return nodes, safe_edges
end


LayoutEngine.BASE_NODE_W = BASE_NODE_W
LayoutEngine.BASE_NODE_H = BASE_NODE_H
LayoutEngine.MAX_ROW_NODES = MAX_ROW_NODES
LayoutEngine.H_GAP = H_GAP
LayoutEngine.V_ROW_GAP = V_ROW_GAP

function LayoutEngine.set_dimensions(w, h, h_gap, v_gap)
  if w then
    BASE_NODE_W = math.max(140, math.min(360, math.floor(w)))
    LayoutEngine.BASE_NODE_W = BASE_NODE_W
  end
  if h then
    BASE_NODE_H = math.max(48, math.min(140, math.floor(h)))
    LayoutEngine.BASE_NODE_H = BASE_NODE_H
  end
  if h_gap then
    H_GAP = math.max(30, math.min(160, math.floor(h_gap)))
    LayoutEngine.H_GAP = H_GAP
  end
  if v_gap then
    V_ROW_GAP = math.max(25, math.min(140, math.floor(v_gap)))
    LayoutEngine.V_ROW_GAP = V_ROW_GAP
  end
end

function LayoutEngine.get_dimensions()
  return BASE_NODE_W, BASE_NODE_H, H_GAP, V_ROW_GAP
end

-- SECTION 2: MULTI-PROVIDER AI CLIENT
-- AI Analyzer for AI Project Visualizer
-- Multi-provider AI client supporting Groq, Ollama / Ollama Cloud, Google Gemini,
-- OpenAI, and Anthropic. Reads stored keys from AI Sidebar (ai_api_keys.json).
-- Two-pass strategy: Pass 1 = per-file summaries, Pass 2 = graph generation.

local core = require "core"
local common = require "core.common"

local function ensure_dir(path)
  if path and not system.get_file_info(path) then
    pcall(common.mkdirp, path)
  end
end


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

AIAnalyzer.clean_display_text = clean_display_text


-- ─────────────────────────────────────────────────────────────────────────────
-- Extension allowlist for source files
-- ─────────────────────────────────────────────────────────────────────────────
local ALLOWED_EXTENSIONS = {
  lua=true, py=true, ts=true, js=true, go=true, rs=true, java=true,
  c=true, cpp=true, cc=true, cs=true, rb=true, php=true, swift=true,
  kt=true, ex=true, exs=true, sh=true, md=true, json=true, yaml=true,
  yml=true, toml=true, html=true, css=true, sql=true, r=true, scala=true,
  clj=true, hs=true, ml=true, fs=true, tsx=true, jsx=true, xml=true,
  gradle=true, txt=true,
}

-- Supported providers configuration
AIAnalyzer.PROVIDERS = {
  nvidia = {
    name = "NVIDIA NIM",
    default_model = "nvidia/nemotron-3.5-bolt-e4b",
    models = {
      "nvidia/nemotron-3.5-bolt-e4b",
      "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
      "nvidia/nemotron-3.5-lightning-30b-a3b",
      "nvidia/nemotron-3-ultra-550b-a55b",
      "stepfun-ai/step-5-preview",
      "minimaxai/minimax-m3.1-flash",
      "poolside/laguna-xs-2.1",
    },
    endpoint = "https://integrate.api.nvidia.com/v1/chat/completions",
    type = "openai_chat",
    env_keys = { "NVIDIA_API_KEY", "NVAPI_KEY" },
  },
  gemini = {
    name = "Google Gemini",
    default_model = "gemini-3.7-flash",
    models = {
      "gemini-3.7-flash",
      "gemini-3.5-flash",
      "gemini-3.1-pro-preview",
      "gemini-2.5-flash",
      "gemini-3.8-flash",
      "gemini-3.5-flash-lite",
    },
    endpoint = "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent",
    type = "gemini",
    env_keys = { "GEMINI_API_KEY", "GOOGLE_API_KEY" },
  },
  groq = {
    name = "Groq",
    default_model = "openai/gpt-oss-20b",
    models = {
      "openai/gpt-oss-20b",
      "openai/gpt-oss-120b",
      "qwen/qwen3.8-27b",
      "openai/gpt-oss-safeguard-20b",
    },
    endpoint = "https://api.groq.com/openai/v1/chat/completions",
    type = "openai_chat",
    env_keys = { "GROQ_API_KEY" },
  },
  ollama = {
    name = "Ollama Cloud",
    default_model = "gpt-oss:120b",
    models = {
      "gpt-oss:120b",
      "gemma4:31b",
      "nemotron-3-nano:30b",
      "gpt-oss:20b",
      "llama3.3",
      "mistral-large-3:675b",
    },
    endpoint = "https://ollama.com/v1/chat/completions",
    type = "openai_chat",
    env_keys = { "OLLAMA_API_KEY", "OLLAMA_HOST" },
  },
  openai = {
    name = "OpenAI",
    default_model = "gpt-4o",
    models = { "gpt-4o", "gpt-4o-mini", "o1", "o3-mini" },
    endpoint = "https://api.openai.com/v1/chat/completions",
    type = "openai_chat",
    env_keys = { "OPENAI_API_KEY" },
  },
  anthropic = {
    name = "Anthropic",
    default_model = "claude-3-7-sonnet-20250219",
    models = { "claude-3-7-sonnet-20250219", "claude-3-5-sonnet-20241022", "claude-3-5-haiku-20241022" },
    endpoint = "https://api.anthropic.com/v1/messages",
    type = "anthropic",
    env_keys = { "ANTHROPIC_API_KEY" },
  },
}

-- Label helper for categorization
function AIAnalyzer.get_model_label(model_name)
  if not model_name or type(model_name) ~= "string" then return " [General]" end
  local n = model_name:lower()

  -- 1. Reasoning / Thinking
  if n:match("[/%-_%.]o[134]") or n:match("^o[134]") or
     n:find("r1") or n:find("reason") or n:find("qwq") or n:find("thinking") or n:find("thought") or
     n:find("120b") or n:find("550b") or n:find("opus") then
    return " [Reasoning]"
  end

  -- 2. Coder / Code
  if n:find("coder") or n:find("starcoder") or n:find("code") or n:find("codex") or n:find("qwen") then
    return " [Coder]"
  end

  -- 3. Speed / Performance Brands
  if n:find("bolt") then
    return " [Bolt]"
  elseif n:find("lightning") then
    return " [Lightning]"
  elseif n:find("flash") then
    if n:find("lite") then return " [Lite]" end
    return " [Flash]"
  elseif n:find("instant") or n:find("mini") or n:find("nano") or n:find("20b") then
    return " [Fast]"
  elseif n:find("lite") then
    return " [Lite]"
  end

  -- 4. Flagship & Frontier
  if n:find("4o") or n:find("sonnet") or n:find("gemini%-3%.[5678]") or n:find("step") or n:find("minimax") then
    return " [Flagship]"
  end

  return " [General]"
end

-- Read cached dynamic models from active Aether instance and model_cache.json
function AIAnalyzer.get_cached_models(provider)
  local models = {}
  local seen = {}

  -- 1. First check live in-memory model cache from Aether instance if available
  local ag_inst = rawget(_G, "_ag_instance")
  if ag_inst and ag_inst.tool_model_lists then
    if provider == "groq" or provider == "nvidia" or provider == "ollama" then
      local cmodels = ag_inst.tool_model_lists["cloud_api"]
      if cmodels and type(cmodels) == "table" then
        local prefix = provider .. "/"
        for _, m in ipairs(cmodels) do
          local mname = (type(m) == "table" and m.name) or (type(m) == "string" and m)
          if mname and mname:sub(1, #prefix) == prefix then
            local actual = mname:sub(#prefix + 1)
            if actual:sub(1, #prefix) == prefix then actual = actual:sub(#prefix + 1) end
            if not seen[actual] then
              seen[actual] = true
              table.insert(models, actual)
            end
          end
        end
      end
    end
    if provider == "gemini" then
      for _, tid in ipairs({ "agy", "opencode" }) do
        local tmodels = ag_inst.tool_model_lists[tid]
        if tmodels and type(tmodels) == "table" then
          for _, m in ipairs(tmodels) do
            local mname = (type(m) == "table" and m.name) or (type(m) == "string" and m)
            if mname and mname:lower():find("gemini") then
              local clean_m = mname:match("^(%S+)")
              if clean_m then
                clean_m = clean_m:gsub("^google/", ""):gsub("^opencode/", "")
                if clean_m:find("gemini") and not seen[clean_m] then
                  seen[clean_m] = true
                  table.insert(models, clean_m)
                end
              end
            end
          end
        end
      end
    end
  end

  -- 2. Check disk model_cache.json
  local udir = rawget(_G, "USERDIR") or (os.getenv("USERPROFILE") or os.getenv("HOME") or "") .. "/.config/lite-xl"
  local sep = package.config:sub(1,1)
  local cache_paths = {
    udir .. sep .. "model_cache.json",
    udir:gsub('\\', '/') .. "/model_cache.json",
  }

  for _, cp in ipairs(cache_paths) do
    local f = io.open(cp, "r")
    if f then
      local content = f:read("*a")
      f:close()
      if content and #content > 0 then
        local data = json_decode(content)
        if type(data) == "table" then
          if data.cloud_api and type(data.cloud_api.models) == "table" then
            local prefix = provider .. "/"
            for _, m in ipairs(data.cloud_api.models) do
              local mname = (type(m) == "table" and m.name) or (type(m) == "string" and m)
              if mname and mname:sub(1, #prefix) == prefix then
                local actual = mname:sub(#prefix + 1)
                if actual:sub(1, #prefix) == prefix then actual = actual:sub(#prefix + 1) end
                if not seen[actual] then
                  seen[actual] = true
                  table.insert(models, actual)
                end
              end
            end
          end
          if provider == "gemini" then
            for _, section in ipairs({ data.opencode, data.agy }) do
              if section and type(section.models) == "table" then
                for _, m in ipairs(section.models) do
                  local mname = (type(m) == "table" and m.name) or (type(m) == "string" and m)
                  if mname and mname:lower():find("gemini") then
                    local clean_m = mname:match("^(%S+)")
                    if clean_m then
                      clean_m = clean_m:gsub("^google/", ""):gsub("^opencode/", "")
                      if clean_m:find("gemini") and not seen[clean_m] then
                        seen[clean_m] = true
                        table.insert(models, clean_m)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
      if #models > 0 then break end
    end
  end

  local pinfo = AIAnalyzer.PROVIDERS[provider]
  if pinfo and pinfo.models then
    for _, m in ipairs(pinfo.models) do
      if not seen[m] then
        seen[m] = true
        table.insert(models, m)
      end
    end
  end

  return models
end

-- Cancel flag
local _cancel_requested = false
local _active = false

-- ─────────────────────────────────────────────────────────────────────────────
-- Minimal JSON encoder
-- ─────────────────────────────────────────────────────────────────────────────
json_encode = function(val, depth)
  depth = depth or 0
  if depth > 50 then return '"..."' end
  local t = type(val)
  if val == nil then
    return "null"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    if val ~= val then return "null" end
    return tostring(val)
  elseif t == "string" then
    local s = val
      :gsub('\\', '\\\\')
      :gsub('"',  '\\"')
      :gsub('\n', '\\n')
      :gsub('\r', '\\r')
      :gsub('\t', '\\t')
    s = s:gsub('[\0-\31]', function(c)
      return string.format('\\u%04x', string.byte(c))
    end)
    return '"' .. s .. '"'
  elseif t == "table" then
    local is_array = (#val > 0)
    if is_array then
      local parts = {}
      for _, v in ipairs(val) do
        table.insert(parts, json_encode(v, depth + 1))
      end
      return '[' .. table.concat(parts, ',') .. ']'
    else
      local parts = {}
      for k, v in pairs(val) do
        if type(k) == "string" then
          table.insert(parts, json_encode(k, depth + 1) .. ':' .. json_encode(v, depth + 1))
        end
      end
      return '{' .. table.concat(parts, ',') .. '}'
    end
  end
  return '"[unsupported]"'
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Minimal JSON decoder (recursive descent)
-- ─────────────────────────────────────────────────────────────────────────────
json_decode = function(str)
  local pos = 1

  local function skip_ws()
    while pos <= #str and str:sub(pos, pos):match('%s') do
      pos = pos + 1
    end
  end

  local function parse_value()
    skip_ws()
    if pos > #str then return nil end
    local c = str:sub(pos, pos)

    if c == '"' then
      pos = pos + 1
      local result = {}
      while pos <= #str do
        local ch = str:sub(pos, pos)
        if ch == '"' then
          pos = pos + 1
          return table.concat(result)
        elseif ch == '\\' then
          pos = pos + 1
          local esc = str:sub(pos, pos)
          if     esc == '"'  then table.insert(result, '"')
          elseif esc == '\\' then table.insert(result, '\\')
          elseif esc == '/'  then table.insert(result, '/')
          elseif esc == 'n'  then table.insert(result, '\n')
          elseif esc == 'r'  then table.insert(result, '\r')
          elseif esc == 't'  then table.insert(result, '\t')
          elseif esc == 'u'  then
            local hex = str:sub(pos + 1, pos + 4)
            pos = pos + 4
            local code = tonumber(hex, 16) or 63
            if code < 128 then
              table.insert(result, string.char(code))
            else
              table.insert(result, '?')
            end
          else
            table.insert(result, esc)
          end
          pos = pos + 1
        else
          table.insert(result, ch)
          pos = pos + 1
        end
      end
      return table.concat(result)

    elseif c == '{' then
      pos = pos + 1
      local obj = {}
      skip_ws()
      if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
      while true do
        skip_ws()
        local key = parse_value()
        if type(key) ~= "string" then break end
        skip_ws()
        if str:sub(pos, pos) == ':' then pos = pos + 1 end
        local val = parse_value()
        obj[key] = val
        skip_ws()
        local sep = str:sub(pos, pos)
        if sep == ',' then pos = pos + 1
        elseif sep == '}' then pos = pos + 1; break
        else break end
      end
      return obj

    elseif c == '[' then
      pos = pos + 1
      local arr = {}
      skip_ws()
      if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
      while true do
        local val = parse_value()
        table.insert(arr, val)
        skip_ws()
        local sep = str:sub(pos, pos)
        if sep == ',' then pos = pos + 1
        elseif sep == ']' then pos = pos + 1; break
        else break end
      end
      return arr

    elseif str:sub(pos, pos + 3) == 'true' then
      pos = pos + 4; return true
    elseif str:sub(pos, pos + 4) == 'false' then
      pos = pos + 5; return false
    elseif str:sub(pos, pos + 3) == 'null' then
      pos = pos + 4; return nil
    else
      local num_str = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
      if num_str then
        pos = pos + #num_str
        return tonumber(num_str)
      end
    end
    return nil
  end

  local ok, result = pcall(parse_value)
  if ok then return result end
  return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Load all saved API keys from AI Sidebar and environment
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.load_saved_keys()
  local keys = {}
  local sep = package.config:sub(1,1)

  -- 1. Try USERDIR/scripts/ai_api_keys.json (shared with AI Sidebar)
  local udir = rawget(_G, "USERDIR") or (os.getenv("USERPROFILE") or os.getenv("HOME") or "") .. "/.config/lite-xl"
  local key_paths = {
    udir .. sep .. "scripts" .. sep .. "ai_api_keys.json",
    udir .. sep .. "ai_api_keys.json",
    udir:gsub('\\', '/') .. "/scripts/ai_api_keys.json",
  }

  for _, path in ipairs(key_paths) do
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      if content and #content > 0 then
        local data = json_decode(content)
        if type(data) == "table" then
          for k, v in pairs(data) do
            if type(v) == "string" and #v > 0 then
              keys[k:lower()] = v
            end
          end
        end
      end
    end
  end

  -- 2. Try .env files
  local env_paths = {
    udir .. sep .. ".env",
    udir .. sep .. "scripts" .. sep .. ".env",
  }
  for _, path in ipairs(env_paths) do
    local f = io.open(path, "r")
    if f then
      for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v then
          v = v:gsub('^["\']', ''):gsub('["\']$', '')
          if k == "GROQ_API_KEY" and not keys["groq"] then keys["groq"] = v end
          if (k == "NVIDIA_API_KEY" or k == "NVAPI_KEY") and not keys["nvidia"] then keys["nvidia"] = v end
          if (k == "GEMINI_API_KEY" or k == "GOOGLE_API_KEY") and not keys["gemini"] then keys["gemini"] = v end
          if (k == "OLLAMA_API_KEY" or k == "OLLAMA_HOST") and not keys["ollama"] then keys["ollama"] = v end
          if k == "OPENAI_API_KEY" and not keys["openai"] then keys["openai"] = v end
          if k == "ANTHROPIC_API_KEY" and not keys["anthropic"] then keys["anthropic"] = v end
        end
      end
      f:close()
    end
  end

  -- 3. Environment variables
  if not keys["groq"] and os.getenv("GROQ_API_KEY") then keys["groq"] = os.getenv("GROQ_API_KEY") end
  if not keys["nvidia"] and (os.getenv("NVIDIA_API_KEY") or os.getenv("NVAPI_KEY")) then
    keys["nvidia"] = os.getenv("NVIDIA_API_KEY") or os.getenv("NVAPI_KEY")
  end
  if not keys["gemini"] and (os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")) then
    keys["gemini"] = os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")
  end
  if not keys["ollama"] and (os.getenv("OLLAMA_API_KEY") or os.getenv("OLLAMA_HOST")) then
    keys["ollama"] = os.getenv("OLLAMA_API_KEY") or os.getenv("OLLAMA_HOST")
  end
  if not keys["openai"] and os.getenv("OPENAI_API_KEY") then keys["openai"] = os.getenv("OPENAI_API_KEY") end
  if not keys["anthropic"] and os.getenv("ANTHROPIC_API_KEY") then keys["anthropic"] = os.getenv("ANTHROPIC_API_KEY") end

  -- 4. Plugin config overrides
  local ok, core = pcall(require, "core")
  if ok and core and core.config and core.config.plugins and core.config.plugins.ai_project_visualizer then
    local cfg = core.config.plugins.ai_project_visualizer
    if cfg.api_key and #cfg.api_key > 0 then
      local prov = (cfg.provider or "gemini"):lower()
      keys[prov] = cfg.api_key
    end
  end

  return keys
end

-- Save a key into ai_api_keys.json (shared with AI Sidebar)
function AIAnalyzer.save_key(provider, key)
  local udir = rawget(_G, "USERDIR") or (os.getenv("USERPROFILE") or os.getenv("HOME") or "") .. "/.config/lite-xl"
  local sep = package.config:sub(1,1)
  local scripts_dir = udir .. sep .. "scripts"
  ensure_dir(scripts_dir)
  local path = scripts_dir .. sep .. "ai_api_keys.json"

  local keys = {}
  local f = io.open(path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    if content and #content > 0 then
      keys = json_decode(content) or {}
    end
  end
  keys[provider:lower()] = key
  local wf = io.open(path, "w")
  if wf then
    wf:write(json_encode(keys))
    wf:close()
    return true
  end
  return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Determine active provider, model, and key
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.get_active_provider(preferred_provider, preferred_model)
  local keys = AIAnalyzer.load_saved_keys()

  -- 1. If preferred provider specified and has key
  if preferred_provider and keys[preferred_provider:lower()] then
    local p = preferred_provider:lower()
    local pinfo = AIAnalyzer.PROVIDERS[p]
    local m = preferred_model or (pinfo and pinfo.default_model)
    return p, m, keys[p]
  end

  -- 2. If preferred provider specified even if no key stored yet
  if preferred_provider and AIAnalyzer.PROVIDERS[preferred_provider:lower()] then
    local p = preferred_provider:lower()
    local pinfo = AIAnalyzer.PROVIDERS[p]
    local m = preferred_model or (pinfo and pinfo.default_model)
    return p, m, keys[p]
  end

  -- 3. Auto-detection priority: NVIDIA NIM, Gemini, Groq, Ollama, OpenAI, Anthropic
  local priority = { "nvidia", "gemini", "groq", "ollama", "openai", "anthropic" }
  for _, p in ipairs(priority) do
    if keys[p] and #keys[p] > 0 then
      local pinfo = AIAnalyzer.PROVIDERS[p]
      local m = pinfo and pinfo.default_model or "default"
      return p, m, keys[p]
    end
  end

  -- Default fallback if nothing has key
  local def_pinfo = AIAnalyzer.PROVIDERS["nvidia"]
  return "nvidia", (def_pinfo and def_pinfo.default_model) or "nvidia/nemotron-3.5-bolt-e4b", nil
end

local function get_temp_file(suffix)
  local tmp_dir = os.getenv("TEMP") or os.getenv("TMP")
  if not tmp_dir or #tmp_dir == 0 then
    local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
    tmp_dir = home .. "/.config/lite-xl/tempfiles"
  end
  local sep = package.config:sub(1,1)
  local fname = string.format("apv_%d_%d%s", os.time(), math.random(10000, 99999), suffix or ".json")
  if sep == "\\" then
    return tmp_dir:gsub("/", "\\") .. "\\" .. fname
  else
    return tmp_dir .. "/" .. fname
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Execute curl and return response body or nil + error (non-blocking process)
-- ─────────────────────────────────────────────────────────────────────────────
local _current_proc = nil

local function curl_post(url, json_body, headers)
  local tmp_in = get_temp_file("_in.json")

  local f, err = io.open(tmp_in, "wb")
  if not f then return nil, "Cannot open temp file (" .. tostring(tmp_in) .. "): " .. tostring(err) end
  f:write(json_body)
  f:close()

  local bin = "curl"
  if PLATFORM == "Windows" or package.config:sub(1,1) == "\\" then
    if system.get_file_info("C:\\Windows\\System32\\curl.exe") then
      bin = "C:\\Windows\\System32\\curl.exe"
    else
      bin = "curl.exe"
    end
  end

  local cmd_args = { bin, "-s", "-S", "-X", "POST" }
  if PLATFORM == "Windows" or package.config:sub(1,1) == "\\" then
    table.insert(cmd_args, "-k")
    table.insert(cmd_args, "--ssl-no-revoke")
  end

  for k, v in pairs(headers or {}) do
    table.insert(cmd_args, "-H")
    table.insert(cmd_args, string.format("%s: %s", k, v))
  end

  table.insert(cmd_args, "--data-binary")
  table.insert(cmd_args, "@" .. tmp_in)
  table.insert(cmd_args, url)

  local p = nil
  local start_err = nil
  if process and process.start then
    local ok, res = pcall(process.start, cmd_args, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      stdin  = process.REDIRECT_DISCARD,
    })
    if ok and res then
      p = res
    else
      start_err = tostring(res)
    end
  end

  if not p then
    pcall(os.remove, tmp_in)
    return nil, "Failed to start curl process: " .. tostring(start_err or "process.start unavailable")
  end

  _current_proc = p
  local out_parts = {}
  local err_parts = {}
  local start_time = system.get_time()
  local timeout = 120

  while p:running() do
    if _cancel_requested then
      pcall(function() p:kill() end)
      pcall(os.remove, tmp_in)
      _current_proc = nil
      return nil, "Request cancelled"
    end

    while true do
      local chunk = p:read_stdout(65536)
      if chunk and #chunk > 0 then
        table.insert(out_parts, chunk)
      else
        break
      end
    end
    while true do
      local echunk = p:read_stderr(4096)
      if echunk and #echunk > 0 then
        table.insert(err_parts, echunk)
      else
        break
      end
    end

    if system.get_time() - start_time > timeout then
      pcall(function() p:kill() end)
      pcall(os.remove, tmp_in)
      _current_proc = nil
      return nil, "Request timed out after " .. timeout .. " seconds"
    end

    if coroutine.running() then
      coroutine.yield(0.02)
    else
      system.sleep(0.02)
    end
  end

  while true do
    local chunk = p:read_stdout(65536)
    if chunk and #chunk > 0 then
      table.insert(out_parts, chunk)
    else
      break
    end
  end
  while true do
    local echunk = p:read_stderr(4096)
    if echunk and #echunk > 0 then
      table.insert(err_parts, echunk)
    else
      break
    end
  end

  pcall(os.remove, tmp_in)
  _current_proc = nil

  local body = table.concat(out_parts)
  local err_out = table.concat(err_parts)

  if #body == 0 and #err_out > 0 then
    return nil, "curl error: " .. err_out
  end
  return body, nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Call provider API (handles Gemini, OpenAI-compatible, Anthropic)
-- ─────────────────────────────────────────────────────────────────────────────
local function call_provider(provider, model, api_key, prompt, is_json)
  local pinfo = AIAnalyzer.PROVIDERS[provider]
  if not pinfo then return nil, "Unknown provider: " .. tostring(provider) end
  model = model or pinfo.default_model

  -- Strip provider prefix if present (e.g. "ollama/gpt-oss:120b" -> "gpt-oss:120b")
  if model and provider and model:match("^" .. provider .. "/") then
    model = model:sub(#provider + 2)
  end

  if pinfo.type == "gemini" then
    local url = string.format(pinfo.endpoint, model) .. "?key=" .. api_key
    local req = {
      contents = { { parts = { { text = prompt } }, role = "user" } },
      generationConfig = {
        temperature = 0.2,
        maxOutputTokens = 8192,
      }
    }
    if is_json then
      req.generationConfig.responseMimeType = "application/json"
    end
    local body, err = curl_post(url, json_encode(req), { ["Content-Type"] = "application/json" })
    if not body then return nil, err end
    local parsed = json_decode(body)
    if not parsed then return nil, "Invalid JSON from Gemini: " .. body:sub(1, 120) end
    if parsed.error then return nil, (parsed.error.message or "Gemini API error") end
    if parsed.candidates and parsed.candidates[1] and parsed.candidates[1].content and parsed.candidates[1].content.parts then
      return parsed.candidates[1].content.parts[1].text, nil
    end
    return nil, "No candidates in Gemini response"

  elseif pinfo.type == "openai_chat" then
    local endpoint = pinfo.endpoint
    local auth_header = "Bearer " .. api_key
    if provider == "ollama" then
      if api_key and (api_key:find("^https?://") or api_key:find("|")) then
        local base = api_key:match("^(https?://[^|]+)")
        if base then endpoint = base:gsub("/+$", "") .. "/v1/chat/completions" end
      elseif not api_key or #api_key <= 20 then
        endpoint = "http://127.0.0.1:11434/v1/chat/completions"
      end
    end

    local messages = {
      { role = "system", content = "You are a senior software architecture analyst. Follow instructions carefully and output exact format requested." },
      { role = "user", content = prompt }
    }
    local req = {
      model = model,
      messages = messages,
      temperature = 0.2,
    }
    if provider == "openai" then
      req.max_completion_tokens = 8192
    else
      req.max_tokens = 8192
    end
    if is_json then
      req.response_format = { type = "json_object" }
    end

    local headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = auth_header,
    }
    local body, err = curl_post(endpoint, json_encode(req), headers)
    if not body then return nil, err end
    local parsed = json_decode(body)
    if not parsed then return nil, "Invalid JSON from " .. pinfo.name .. ": " .. body:sub(1, 120) end
    if parsed.error then
      if type(parsed.error) == "table" and parsed.error.failed_generation then
        local failed = parsed.error.failed_generation
        if type(failed) == "string" and #failed > 20 then
          return failed, nil
        end
      end
      local emsg = type(parsed.error) == "table" and parsed.error.message or tostring(parsed.error)
      return nil, pinfo.name .. " error: " .. emsg
    end
    if parsed.choices and parsed.choices[1] and parsed.choices[1].message then
      local msg = parsed.choices[1].message
      local text = (msg.content and #msg.content > 0) and msg.content or msg.reasoning
      if text and #text > 0 then return text, nil end
    end
    return nil, "No response content from " .. pinfo.name

  elseif pinfo.type == "anthropic" then
    local headers = {
      ["Content-Type"] = "application/json",
      ["x-api-key"] = api_key,
      ["anthropic-version"] = "2023-06-01",
    }
    local req = {
      model = model,
      messages = { { role = "user", content = prompt } },
      max_tokens = 4096,
      temperature = 0.2,
    }
    local body, err = curl_post(pinfo.endpoint, json_encode(req), headers)
    if not body then return nil, err end
    local parsed = json_decode(body)
    if not parsed then return nil, "Invalid JSON from Anthropic" end
    if parsed.error then return nil, (parsed.error.message or "Anthropic error") end
    if parsed.content and parsed.content[1] and parsed.content[1].text then
      return parsed.content[1].text, nil
    end
    return nil, "No content from Anthropic"
  end

  return nil, "Unsupported provider: " .. tostring(provider)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Read first N lines from a file
-- ─────────────────────────────────────────────────────────────────────────────
local function read_first_lines(filepath, n)
  local full = filepath:gsub('\\', '/')
  if not full:match("^%a:/") and not full:match("^/") and core.project_dir then
    full = core.project_dir:gsub('\\', '/') .. "/" .. full
  end
  local f = io.open(full, "r")
  if not f then
    f = io.open(filepath, "r")
  end
  if not f then return "" end
  local lines = {}
  local count = 0
  for line in f:lines() do
    table.insert(lines, line)
    count = count + 1
    if count >= n then break end
  end
  f:close()
  return table.concat(lines, "\n")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Cancel ongoing analysis
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.cancel()
  _cancel_requested = true
  _active = false
  if _current_proc then
    pcall(function() _current_proc:kill() end)
    _current_proc = nil
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Main analysis entry point
-- file_list: array of absolute file paths
-- on_progress(msg): status update callback
-- on_complete(diagrams): called with parsed diagram data
-- on_error(msg): called on failure
-- opts: { provider = "groq"|"ollama"|"gemini", model = "..." } (optional)
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.analyze(file_list, on_progress, on_complete, on_error, opts)
  _cancel_requested = false
  _active = true

  opts = opts or {}
  local provider, model, api_key = AIAnalyzer.get_active_provider(opts.provider, opts.model)

  if not api_key or #api_key == 0 then
    on_error("No API key found for " .. (provider:upper()) .. ". Set key in AI Sidebar or click [AI Provider] in toolbar.")
    return
  end

  local pinfo = AIAnalyzer.PROVIDERS[provider]
  local pname = pinfo and pinfo.name or provider

  local ignored_patterns = {
    "[/\\]node_modules[/\\]",
    "[/\\]site%-packages[/\\]",
    "[/\\]my_env[/\\]",
    "[/\\]myenv[/\\]",
    "[/\\]venv[/\\]",
    "[/\\]%.venv[/\\]",
    "[/\\]env[/\\]",
    "[/\\]vendor[/\\]",
    "[/\\]dist[/\\]",
    "[/\\]build[/\\]",
    "[/\\]target[/\\]",
    "[/\\]%.git[/\\]",
    "%.min%.js$",
    "%.min%.css$",
  }

  -- Filter to allowed source files
  local source_files = {}
  for _, path in ipairs(file_list) do
    local ext = path:match('%.([^%.]+)$')
    if ext and ALLOWED_EXTENSIONS[ext:lower()] then
      local norm = "/" .. path:gsub('\\', '/') .. "/"
      local skip = false
      for _, pat in ipairs(ignored_patterns) do
        if norm:find(pat) then skip = true; break end
      end
      if not skip then
        table.insert(source_files, path)
      end
    end
  end

  if #source_files == 0 then
    on_error("No supported source files found in project.")
    return
  end

  local file_set = {}
  for _, f in ipairs(source_files) do
    local norm = f:gsub('\\', '/')
    file_set[norm] = true
    file_set[f] = true
  end

  on_progress(string.format("[%s/%s] Pass 1: Scanning %d source files for real symbols...", pname, model, #source_files))

  -- ── PASS 1: Extract factual symbols from files in batches of 20 ───────────
  local summaries = {}
  local last_error = nil
  local BATCH_SIZE = 20

  for i = 1, #source_files, BATCH_SIZE do
    if _cancel_requested then
      on_error("Analysis cancelled.")
      return
    end

    local batch = {}
    for j = i, math.min(i + BATCH_SIZE - 1, #source_files) do
      local path = source_files[j]
      local content = read_first_lines(path, 150)
      local rel = path:gsub('\\', '/')
      if core.project_dir then
        local pdir = core.project_dir:gsub('\\', '/') .. "/"
        if rel:sub(1, #pdir) == pdir then
          rel = rel:sub(#pdir + 1)
        end
      end
      table.insert(batch, "FILE: " .. rel .. "\n" .. content)
    end

    local batch_num = math.ceil(i / BATCH_SIZE)
    local total_batches = math.ceil(#source_files / BATCH_SIZE)
    on_progress(string.format("[%s] Scanning batch %d/%d...", pname, batch_num, total_batches))

    local prompt = "You are a code scanner. For each source file below, output EXACTLY ONE line:\n" ..
                   "<relative_path>: [tier: ingress|application|domain|integration|persistence|infrastructure] " ..
                   "[tech: <ONLY real imports/requires visible in the file>] " ..
                   "<list the EXACT exported class names, function names, and variable names as they appear in the file. " ..
                   "If the file imports a database driver, cache client, or external service SDK, name it EXACTLY as imported.>\n\n" ..
                   "RULES:\n" ..
                   "- Use ONLY information visible in the file content below. DO NOT guess or invent anything.\n" ..
                   "- Use the EXACT class/function name as written in the source code (case-sensitive).\n" ..
                   "- If a file has no exports or is empty, write: <relative_path>: [tier: infrastructure] [tech: none] no exports\n" ..
                   "- Do NOT suggest or recommend tools not seen in the file.\n\n" ..
                   "FILES:\n" .. table.concat(batch, "\n\n---\n\n")

    local text, err = call_provider(provider, model, api_key, prompt, false)
    if text then
      for line in text:gmatch('[^\n]+') do
        if #line > 2 then
          table.insert(summaries, line)
        end
      end
    else
      last_error = err
      core.log("[AI Visualizer] Batch %d failed: %s", batch_num, tostring(err))
    end
  end

  if _cancel_requested then
    on_error("Analysis cancelled.")
    return
  end

  if #summaries == 0 then
    local detail = last_error and (": " .. tostring(last_error)) or ". Check your key and network."
    on_error("Failed to scan files via " .. pname .. detail)
    return
  end

  -- ── Build symbol allowlist from Pass 1 summaries ──────────────────────────
  -- Used in Pass 2 aggressive pruning: nodes whose label tokens do NOT appear
  -- in any summary are considered hallucinated and are DELETED entirely.
  local summary_text = table.concat(summaries, "\n")
  local summary_lower = summary_text:lower()

  local symbol_set = {}
  for token in summary_text:gmatch('[%w_%.%-]+') do
    if #token >= 3 then
      symbol_set[token:lower()] = true
    end
  end

  on_progress(string.format("[%s] Pass 2: Generating grounded architecture diagrams...", pname))

  -- ── PASS 2: Generate structured graph strictly from summaries ──────────────
  local pass2_prompt = [[You are an enterprise software architect. Based on the codebase summaries below, construct comprehensive production-grade architecture diagrams as valid JSON following the C4 model and cloud engineering standards.

SUMMARIES:
]] .. summary_text .. [[

Generate a JSON object with a top-level "diagrams" array containing diagrams for these 6 distinct architectural views:
1. "System Topology (C4)": High-level container/service topology showing Client/Ingress -> Backend Services -> Message Queues -> Databases -> External Cloud APIs.
2. "Data Flow & Lifecycle": Step-by-step pipeline tracing incoming requests through validation, business logic, persistence, and async events.
3. "Component & Domain Architecture": In-process clean architecture showing Controllers -> Application Services -> Domain Aggregates/Models -> Repositories.
4. "Security, Auth & Ingress": Gateways, CORS/WAF, JWT token validation, authorization guards, session stores, sanitization.
5. "Event Brokers & Async Pipelines": Message queues, event producers, background workers, scheduled jobs, webhooks, and dead-letter queues.
6. "Persistence & Cloud Infrastructure": Relational DBs, Document DBs, Redis caches, S3 object storage, configuration, and connection pools.

CRITICAL ARCHITECTURE GUIDELINES (STRICT CODE GROUNDING):
- STRICT GROUNDING IN REPOSITORY: Represent ONLY the actual components, modules, files, and technologies that TRULY EXIST in the provided file summaries. NEVER hallucinate, invent, or assume third-party tools (such as Kafka, Redis, RabbitMQ, PostgreSQL, MongoDB, AWS S3, Stripe, Docker, Kubernetes) unless they are explicitly imported, configured, or referenced in the project files!
- ACCURATE SIZING WITHOUT ARTIFICIAL QUOTAS: Do NOT generate fictional filler nodes. If a project has 4 real components, represent those 4 components accurately and cleanly. If a category (e.g. Event Brokers) is not used in the codebase, accurately show how the codebase handles events (e.g. in-memory callbacks, EventEmitter, Promises) or create a focused diagram of the actual components.
- EXTERNAL CLOUD & INFRASTRUCTURE: Only mark "external": true if the code contains an active client or configuration connecting to that external service.
- AI ARCHITECTURAL SUGGESTIONS (MUST BE LABELED): If you recommend an industry-standard architectural enhancement (e.g. adding a cache, rate limiter, or message queue) that is NOT yet implemented in the codebase, you MUST set "suggested": true, "external": true, omit "file", and prefix "desc" with "[AI Suggestion] Recommended addition for ...". This ensures developers know it is a suggestion rather than existing code.
- INTERCONNECTIVITY: Aim for realistic dependency links between components. Every node must connect into the dependency graph with at least one edge.
- EXPLICIT PROTOCOL EDGES: Every edge must describe the interaction with a protocol type ("http", "grpc", "sql", "cache", "event", "queue", "auth", "inject") and clear label.

JSON SCHEMA:
{
  "diagrams": [
    {
      "category": "System Topology (C4)",
      "nodes": [
        {
          "id": "node_id",
          "label": "ExactNameFromSummaries",
          "file": "path/file.ts",
          "line": 1,
          "type": "gateway|endpoint|service|domain|database|cache|queue|cloud|auth|middleware|storage|component",
          "tier": "ingress|application|domain|integration|persistence|infrastructure",
          "tech": "OnlyRealImportsFromSummaries",
          "desc": "One sentence describing its operational role",
          "external": false,
          "suggested": false
        }
      ],
      "edges": [
        {
          "from": "node1_id",
          "to": "node2_id",
          "label": "protocol / action description",
          "type": "http|grpc|sql|cache|event|queue|auth|inject"
        }
      ]
    }
  ]
}

Output ONLY the raw valid JSON. Do not wrap in markdown or add commentary.]]
  local text, err = call_provider(provider, model, api_key, pass2_prompt, true)
  if err then
    on_error("Diagram generation failed with " .. pname .. ": " .. err)
    return
  end

  if _cancel_requested then
    on_error("Analysis cancelled.")
    return
  end

  if not text or #text == 0 then
    on_error("Empty response from " .. pname .. " API.")
    return
  end

  on_progress("Parsing diagram data...")

  local clean_text = text
  if clean_text then
    local inner = clean_text:match("```%w*\n?(.-)\n?```")
    if inner then clean_text = inner end
    -- Clean up accidental double-braces or double-commas in LLM arrays
    clean_text = clean_text:gsub("}%s*{%s*}%s*,?%s*{", "},{"):gsub("}%s*{%s*}", "}")
    clean_text = clean_text:gsub(",%s*,+", ",")
    clean_text = clean_text:gsub(",%s*([%]%}])", "%1")
    local s = clean_text:find('{', 1, true)
    local e = clean_text:reverse():find('}', 1, true)
    if s and e then
      local end_pos = #clean_text - e + 1
      if end_pos >= s then
        clean_text = clean_text:sub(s, end_pos)
      end
    end
  end

  local parsed = json_decode(clean_text)
  if not parsed and text then
    local s = text:find('{')
    if s then parsed = json_decode(text:sub(s)) end
  end

  if not parsed or not parsed.diagrams then
    on_error("Could not parse diagram structure from " .. pname .. " response.")
    return
  end

  -- Validate and normalize diagram data
  local diagrams = {}
  for _, diagram in ipairs(parsed.diagrams) do
    if diagram.category and diagram.nodes and diagram.edges then
      diagram.category = clean_display_text(diagram.category)
      local valid_nodes = {}
      local node_ids = {}
      for _, node in ipairs(diagram.nodes) do
        if node.id and node.label then
          node.w        = 150
          node.h        = 48
          node.type     = (node.type or "component"):lower()
          node.tier     = (node.tier or "application"):lower()
          node.label    = clean_display_text(node.label)
          node.tech     = clean_display_text(node.tech or "")
          node.desc     = clean_display_text(node.desc or "")
          node.external  = (node.external == true or node.external == "true")
          node.suggested = (node.suggested == true or node.suggested == "true")
          node.line      = tonumber(node.line) or 1
          local is_file_real = false
          if node.file and not node.external then
            local nf = node.file:gsub('\\', '/')
            if file_set[nf] or file_set[node.file] then
              is_file_real = true
            else
              local base = nf:match('[^/]+$') or nf
              for f in pairs(file_set) do
                if f:match('[^/]+$') == base then
                  node.file = f
                  is_file_real = true
                  break
                end
              end
            end
          end
          -- ── Aggressive two-pass grounding ────────────────────────────────────
          -- Pass A: check if node's file is real in the repo
          if not is_file_real then
            node.suggested = true
          end
          -- Pass B: if still not suggested, verify label tokens exist in summaries.
          -- This catches hallucinated labels with invented file paths.
          if not node.suggested and not node.external then
            local lbl_lower = node.label:lower()
            -- Check if any significant token from the label appears in summaries
            local found_in_summary = false
            for token in lbl_lower:gmatch('[%w_]+') do
              if #token >= 3 and symbol_set[token] then
                found_in_summary = true
                break
              end
            end
            if not found_in_summary then
              node.suggested = true
            end
          end
          -- Pass C: for suggested nodes, check if at least label tokens appear
          -- anywhere in summary_lower. If completely absent, DELETE the node.
          if node.suggested then
            local lbl_lower = (node.label or ""):lower()
            local id_lower  = (node.id or ""):lower()
            local any_token_found = false
            for token in lbl_lower:gmatch('[%w_]+') do
              if #token >= 3 and summary_lower:find(token, 1, true) then
                any_token_found = true
                break
              end
            end
            if not any_token_found then
              -- Also try node id tokens
              for token in id_lower:gmatch('[%w_]+') do
                if #token >= 3 and summary_lower:find(token, 1, true) then
                  any_token_found = true
                  break
                end
              end
            end
            -- Allow suggested=true nodes that have an [AI Suggestion] desc
            -- (these are intentional recommendations, not hallucinations)
            local is_intentional_suggestion = node.desc and node.desc:find('%[AI Suggestion%]', 1, true)
            if not any_token_found and not is_intentional_suggestion then
              -- Hallucinated: skip this node entirely
              goto continue_node
            end
          end
          table.insert(valid_nodes, node)
          node_ids[node.id] = true
          ::continue_node::
        end
      end

      local valid_edges = {}
      for _, edge in ipairs(diagram.edges) do
        if edge.from and edge.to and node_ids[edge.from] and node_ids[edge.to] then
          edge.type  = (edge.type or "http"):lower()
          edge.label = edge.label or ""
          edge.label = clean_display_text(edge.label or "")
          table.insert(valid_edges, edge)
        end
      end

      if #valid_nodes > 0 then
        diagrams[diagram.category] = {
          nodes = valid_nodes,
          edges = valid_edges,
        }
      end
    end
  end

  if next(diagrams) == nil then
    on_error("No valid diagrams could be extracted. The project might be empty or the response had invalid node links.")
    return
  end

  _active = false
  on_complete(diagrams)
end


-- ─────────────────────────────────────────────────────────────────────────────
-- Graph Semantic Query & Local Architecture Reasoner
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.local_architecture_query(query, diagram, category)
  if not diagram or not diagram.nodes or #diagram.nodes == 0 then
    return {
      answer = "The architecture diagram has no active components to analyze.",
      involved_nodes_map = {},
      provider = "local"
    }
  end

  local q_lower = query:lower()
  local stop_words = {
    ["the"]=true, ["a"]=true, ["an"]=true, ["is"]=true, ["are"]=true,
    ["was"]=true, ["were"]=true, ["in"]=true, ["on"]=true, ["at"]=true,
    ["to"]=true, ["for"]=true, ["of"]=true, ["and"]=true, ["or"]=true,
    ["how"]=true, ["does"]=true, ["do"]=true, ["what"]=true, ["where"]=true,
    ["why"]=true, ["which"]=true, ["can"]=true, ["use"]=true, ["used"]=true,
    ["work"]=true, ["flow"]=true, ["this"]=true, ["that"]=true, ["with"]=true
  }

  local terms = {}
  for word in q_lower:gmatch("[%a%d_%-]+") do
    if #word >= 2 and not stop_words[word] then
      table.insert(terms, word)
    end
  end

  -- Score nodes based on query relevance
  local scored_nodes = {}
  for _, n in ipairs(diagram.nodes) do
    local nid   = (n.id or ""):lower()
    local nlbl  = (n.label or ""):lower()
    local ntech = (n.tech or ""):lower()
    local ntype = (n.type or ""):lower()
    local ntier = (n.tier or ""):lower()
    local nfile = (n.file or ""):lower()
    local ndesc = (n.desc or n.description or ""):lower()

    local score = 0
    if #terms > 1 and (nlbl:find(q_lower, 1, true) or nid:find(q_lower, 1, true)) then
      score = score + 50
    end

    for _, term in ipairs(terms) do
      if nid == term or nlbl == term then
        score = score + 30
      elseif nid:find(term, 1, true) or nlbl:find(term, 1, true) then
        score = score + 20
      elseif ntech:find(term, 1, true) then
        score = score + 15
      elseif ntype:find(term, 1, true) or ntier:find(term, 1, true) then
        score = score + 10
      elseif ndesc:find(term, 1, true) or nfile:find(term, 1, true) then
        score = score + 8
      end
    end

    if score > 0 then
      table.insert(scored_nodes, { node = n, score = score })
    end
  end

  table.sort(scored_nodes, function(a, b) return a.score > b.score end)

  local matched_map = {}
  local matched_nodes = {}
  for i = 1, math.min(6, #scored_nodes) do
    local n = scored_nodes[i].node
    matched_map[n.id] = true
    table.insert(matched_nodes, n)
  end

  -- If NO nodes matched, honestly explain without fabricating random nodes
  if #matched_nodes == 0 then
    local sample_names = {}
    for i = 1, math.min(5, #diagram.nodes) do
      local n = diagram.nodes[i]
      table.insert(sample_names, n.label or n.id)
    end
    local answer = string.format([[### Architectural Query Result
No components in the **%s** subsystem directly match your query: `"%s"`.

**Available Components in this Subsystem:**
%s

**Suggestions:**
- Try searching for specific service names (e.g. `gateway`, `api`, `auth`, `db`).
- Check if the component belongs to another category tab in the left sidebar.
- Inspect the full component list in the **Inspect** drawer.]],
      category or "Active", query,
      "- " .. table.concat(sample_names, "\n- "))
    return {
      answer = answer,
      involved_nodes_map = {},
      provider = "local"
    }
  end

  -- Analyze connectivity among matched nodes
  local node_id_set = {}
  for _, n in ipairs(matched_nodes) do node_id_set[n.id] = true end

  local in_callers = {}
  local out_deps = {}
  for _, e in ipairs(diagram.edges or {}) do
    if node_id_set[e.to] then
      in_callers[e.to] = in_callers[e.to] or {}
      table.insert(in_callers[e.to], e.from)
    end
    if node_id_set[e.from] then
      out_deps[e.from] = out_deps[e.from] or {}
      table.insert(out_deps[e.from], e.to)
    end
  end

  local comp_table_lines = {
    "| Component | Tier | Technology | Callers | Downstream | Status |",
    "|:---|:---:|:---:|:---|:---|:---:|"
  }
  for _, n in ipairs(matched_nodes) do
    -- Trace inbound callers and downstream dependencies: Callers: [%s] -> Downstream: [%s]
    local callers = in_callers[n.id] and table.concat(in_callers[n.id], ", ") or "None"
    local deps    = out_deps[n.id] and table.concat(out_deps[n.id], ", ") or "None"
    local status  = (#diagram.edges > 0 and (in_callers[n.id] or out_deps[n.id])) and "Active" or "Healthy"
    local line = string.format("| `%s` | %s | %s | %s | %s | %s |",
      n.label or n.id, n.tier or "logic", n.tech or n.type or "service", callers, deps, status)
    table.insert(comp_table_lines, line)
  end

  local answer = string.format([[### Architecture Insight: %s

**Query:** `"%s"`  
**Category:** %s  
**Identified Components (%d):**

%s

#### Request Flow & Interaction
%s

#### Architectural Context
These components participate in the active **%s** DAG. Requests entering these components execute domain logic before persisting state or delegating to downstream microservices.]],
    matched_nodes[1].label or matched_nodes[1].id,
    query,
    category or "General Architecture",
    #matched_nodes,
    table.concat(comp_table_lines, "\n"),
    (#diagram.edges > 0 and "Direct dependencies and message exchanges are highlighted in glowing purple neon across the diagram canvas." or "Standalone service layer operating without direct edge coupling in this view."),
    category or "General")

  return {
    answer = clean_display_text(answer),
    involved_nodes_map = matched_map,
    provider = "local"
  }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Asynchronous Architecture AI Question Answering with Real LLM Engine
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.ask_architecture_ai(query, diagram, category, opts, on_complete, on_error)
  opts = opts or {}
  local provider, model, api_key = AIAnalyzer.get_active_provider(opts.provider, opts.model)

  -- If no provider configured or provider is "local" / no keys, use intelligent local analyzer
  if not provider or (provider ~= "ollama" and (not api_key or #api_key == 0)) then
    local res = AIAnalyzer.local_architecture_query(query, diagram, category)
    on_complete(res)
    return
  end

  -- Serialize diagram components and connections
  local comp_lines = {}
  local node_id_lookup = {}
  for _, n in ipairs(diagram.nodes or {}) do
    node_id_lookup[n.id] = n
    local tech_str = (n.tech and n.tech ~= "") and (" [" .. n.tech .. "]") or ""
    local file_str = (n.file and n.file ~= "") and (" (source: " .. n.file .. ")") or ""
    table.insert(comp_lines, string.format("- ID: %s | Label: %s | Tier: %s | Type: %s%s%s",
      n.id, n.label or n.id, n.tier or "logic", n.type or "service", tech_str, file_str))
  end

  local edge_lines = {}
  for _, e in ipairs(diagram.edges or {}) do
    table.insert(edge_lines, string.format("- %s -> %s%s",
      e.from, e.to, (e.label and e.label ~= "") and (" (" .. e.label .. ")") or ""))
  end

  local prompt = string.format([[You are a principal software architect analyzing a codebase architecture diagram.
Subsystem Category: %s

Active Components in Diagram:
%s

Connections and Dependencies:
%s

User Question: %s

INSTRUCTIONS:
1. Provide a detailed, professional architectural explanation in clear Markdown.
2. Structure your response with sections (e.g. ## Overview, ## Component Breakdown & Status, ## Request & Data Flow, ## Architectural Considerations).
3. When presenting component inventories, comparisons, or multi-field attributes, format them as standard GitHub Flavored Markdown tables with clear headers and alignment (e.g. | Component | Role | Tier | Status |).
4. Identify the EXACT component IDs from the diagram that are relevant to this question.
5. STRICT RULE: in "involved_nodes", ONLY include component IDs that appear verbatim in the "Active Components in Diagram" list above. Do NOT invent new component IDs.

Respond with a JSON object ONLY:
{
  "answer": "Detailed Markdown explanation answering the user's question...",
  "involved_nodes": ["component_id_1", "component_id_2"]
}]], category or "Architecture", table.concat(comp_lines, "\n"), table.concat(edge_lines, "\n"), query)

  core.add_thread(function()
    local body, err = call_provider(provider, model, api_key, prompt, true)
    if not body or err then
      -- Fallback to intelligent local reasoning on network / LLM failure
      local local_res = AIAnalyzer.local_architecture_query(query, diagram, category)
      local_res.provider = (provider or "AI") .. " (offline)"
      on_complete(local_res)
      return
    end

    -- Clean JSON fences if present
    local clean_body = body:gsub("^%s*```json%s*", ""):gsub("^%s*```%s*", ""):gsub("%s*```%s*$", ""):gsub("^%s*", ""):gsub("%s*$", "")

    local parsed = json_decode(clean_body)
    local answer = nil
    local involved_nodes = {}

    if parsed and type(parsed) == "table" and parsed.answer then
      answer = parsed.answer
      if type(parsed.involved_nodes) == "table" then
        involved_nodes = parsed.involved_nodes
      end
    else
      -- If raw text or non-JSON, use body as answer and extract node IDs mentioned in body
      answer = clean_body
      for _, n in ipairs(diagram.nodes or {}) do
        if clean_body:find(n.id, 1, true) or (n.label and clean_body:find(n.label, 1, true)) then
          table.insert(involved_nodes, n.id)
        end
      end
    end

    -- Strictly ground involved_nodes against actual diagram nodes
    local grounded_map = {}
    for _, nid in ipairs(involved_nodes) do
      if type(nid) == "string" and node_id_lookup[nid] then
        grounded_map[nid] = true
      end
    end

    on_complete({
      answer = clean_display_text(answer),
      involved_nodes_map = grounded_map,
      provider = provider
    })
  end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- AI-Powered Deep Architecture Audit
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.run_ai_architecture_audit(diagram, category, static_findings, opts, on_complete, on_error)
  opts = opts or {}
  local provider, model, api_key = AIAnalyzer.get_active_provider(opts.provider, opts.model)

  local comp_lines = {}
  local node_id_lookup = {}
  for _, n in ipairs(diagram.nodes or {}) do
    node_id_lookup[n.id] = n
    local tech_str = (n.tech and n.tech ~= "") and (" [" .. n.tech .. "]") or ""
    table.insert(comp_lines, string.format("- ID: %s | Label: %s | Tier: %s | Type: %s%s",
      n.id, n.label or n.id, n.tier or "logic", n.type or "service", tech_str))
  end

  local edge_lines = {}
  for _, e in ipairs(diagram.edges or {}) do
    table.insert(edge_lines, string.format("- %s -> %s%s",
      e.from, e.to, (e.label and e.label ~= "") and (" (" .. e.label .. ")") or ""))
  end

  local findings_summary = {}
  for _, f in ipairs(static_findings or {}) do
    table.insert(findings_summary, string.format("- [%s] %s (Nodes: %s)",
      (f.type or "info"):upper(), f.title or "N/A", table.concat(f.nodes or {}, ", ")))
  end

  if not provider or (provider ~= "ollama" and (not api_key or #api_key == 0)) then
    if on_complete then
      on_complete({
        findings = static_findings or {},
        ai_summary = "Static topological rules audit completed. To enable AI deep audits, configure an API key or run Ollama.",
        provider = "local"
      })
    end
    return
  end

  local prompt = string.format([[You are a Principal Software Architect performing an architecture review of the following system design.
Subsystem / Domain: %s

Components:
%s

Connections / Dependencies:
%s

Preliminary Rule-Based Findings:
%s

Analyze this graph for non-trivial architecture anti-patterns, scalability bottlenecks, resilience hazards, data sovereignty issues, or missing circuit breakers / caching.
Provide concrete findings. For each finding, return:
- type: "critical" | "warning" | "info"
- title: concise title
- nodes: array of relevant component IDs matching the system components above ONLY
- desc: technical description of the violation
- impact: system failure or scalability consequences
- recommendation: concrete remediation pattern

Respond with a JSON object ONLY:
{
  "ai_summary": "2-3 sentence executive summary of overall architecture health.",
  "additional_findings": [
    {
      "type": "warning",
      "title": "Anti-pattern title",
      "nodes": ["node_id"],
      "desc": "Description...",
      "impact": "Impact...",
      "recommendation": "Recommendation..."
    }
  ]
}]], category or "General", table.concat(comp_lines, "\n"), table.concat(edge_lines, "\n"), table.concat(findings_summary, "\n"))

  core.add_thread(function()
    local body, err = call_provider(provider, model, api_key, prompt, true)
    if not body or err then
      if on_complete then
        on_complete({
          findings = static_findings or {},
          ai_summary = "AI query unavailable. Displaying static topological audit.",
          provider = (provider or "AI") .. " (offline)"
        })
      end
      return
    end

    local clean_body = body:gsub("^%s*```json%s*", ""):gsub("^%s*```%s*", ""):gsub("%s*```%s*$", ""):gsub("^%s*", ""):gsub("%s*$", "")
    local parsed = json_decode(clean_body)
    local all_findings = {}
    for _, f in ipairs(static_findings or {}) do table.insert(all_findings, f) end

    local ai_summary = "AI Architecture Doctor completed deep analysis."
    if parsed and type(parsed) == "table" then
      if parsed.ai_summary then ai_summary = parsed.ai_summary end
      if type(parsed.additional_findings) == "table" then
        for _, af in ipairs(parsed.additional_findings) do
          if af.title and af.type then
            local valid_nodes = {}
            for _, nid in ipairs(af.nodes or {}) do
              if node_id_lookup[nid] then table.insert(valid_nodes, nid) end
            end
            if #valid_nodes > 0 or not af.nodes or #af.nodes == 0 then
              af.nodes = valid_nodes
              af.source = "ai"
              af.title = clean_display_text(af.title)
              af.desc = clean_display_text(af.desc)
              af.impact = clean_display_text(af.impact)
              af.recommendation = clean_display_text(af.recommendation)
              table.insert(all_findings, af)
            end
          end
        end
      end
    end

    if on_complete then
      on_complete({
        findings = all_findings,
        ai_summary = clean_display_text(ai_summary),
        provider = provider
      })
    end
  end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Graph AI: BFS Flow Path Tracing (Shortest Dependency Path)
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.find_flow_path(edges, from_id, to_id)
  if not edges or not from_id or not to_id or from_id == to_id then return nil end
  local adj = {}
  for _, e in ipairs(edges) do
    if e.from and e.to then
      adj[e.from] = adj[e.from] or {}
      table.insert(adj[e.from], { to = e.to, edge = e })
    end
  end

  local queue = { { node = from_id, path = { from_id }, edges = {} } }
  local visited = { [from_id] = true }

  while #queue > 0 do
    local curr = table.remove(queue, 1)
    if curr.node == to_id then
      return {
        path = curr.path,
        edges = curr.edges,
        hops = #curr.edges,
        is_direct = true
      }
    end

    for _, neighbor in ipairs(adj[curr.node] or {}) do
      if not visited[neighbor.to] then
        visited[neighbor.to] = true
        local next_path = {}
        for _, n in ipairs(curr.path) do table.insert(next_path, n) end
        table.insert(next_path, neighbor.to)

        local next_edges = {}
        for _, ed in ipairs(curr.edges) do table.insert(next_edges, ed) end
        table.insert(next_edges, neighbor.edge)

        table.insert(queue, { node = neighbor.to, path = next_path, edges = next_edges })
      end
    end
  end

  return nil
end

function AIAnalyzer.find_any_path(edges, from_id, to_id)
  local direct = AIAnalyzer.find_flow_path(edges, from_id, to_id)
  if direct then return direct end

  -- Bidirectional search
  local adj = {}
  for _, e in ipairs(edges or {}) do
    if e.from and e.to then
      adj[e.from] = adj[e.from] or {}
      table.insert(adj[e.from], { to = e.to, edge = e, reversed = false })
      adj[e.to] = adj[e.to] or {}
      table.insert(adj[e.to], { to = e.from, edge = e, reversed = true })
    end
  end

  local queue = { { node = from_id, path = { from_id }, edges = {} } }
  local visited = { [from_id] = true }

  while #queue > 0 do
    local curr = table.remove(queue, 1)
    if curr.node == to_id then
      return {
        path = curr.path,
        edges = curr.edges,
        hops = #curr.edges,
        is_direct = false
      }
    end

    for _, neighbor in ipairs(adj[curr.node] or {}) do
      if not visited[neighbor.to] then
        visited[neighbor.to] = true
        local next_path = {}
        for _, n in ipairs(curr.path) do table.insert(next_path, n) end
        table.insert(next_path, neighbor.to)

        local next_edges = {}
        for _, ed in ipairs(curr.edges) do table.insert(next_edges, ed) end
        table.insert(next_edges, neighbor.edge)

        table.insert(queue, { node = neighbor.to, path = next_path, edges = next_edges })
      end
    end
  end
  return nil
end

AIAnalyzer.json_encode = json_encode
AIAnalyzer.json_decode = json_decode

-- SECTION 3: DIAGRAM RENDERER
-- Diagram Renderer for AI Project Visualizer
-- Handles all canvas drawing using Lite XL's renderer API.
-- Renders crisp, pixel-perfect orthogonal Manhattan channels,
-- solid scanline arrowheads, domain-styled architecture cards,
-- tab strip, interactive toolbar with zoom/fit/export controls, and responsive tooltips.


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

  -- Dynamic responsive icon tab strip width (44px in compact/sidebar mode, 54px in desktop)
  local is_sidebar_mode = (view and view.size and view.size.x < 760 * SCALE)
  local is_strip_only   = (rw <= 64 * SCALE)
  local strip_w         = is_strip_only and rw or (is_sidebar_mode and 44 * SCALE or 54 * SCALE)
  local strip_x         = rx + rw - strip_w
  local strip_y         = ry
  local strip_h         = rh

  -- Draw tab strip background
  draw_rect(strip_x, strip_y, strip_w, strip_h, { 18, 22, 30, 255 })
  draw_rect(strip_x, strip_y, 1, strip_h, COLORS.separator)

  local icon_tabs = {
    { id = "dimensions", label = "Size",    tip = "Card Dimensions & Grid" },
    { id = "inspector",  label = "Inspect", tip = "Component Inspector" },
    { id = "heatmap",    label = "Heat",    tip = "Complexity & Hotspots Heatmap" },
    { id = "audit",      label = "Audit",   tip = "Architecture Doctor" },
    { id = "tour",       label = "Tour",    tip = "Guided Architecture Walkthrough" },
    { id = "flow",       label = "Flow",    tip = "Data Flow & Path Trace" },
    { id = "actions",    label = "Export",  tip = "Export SVG, Guide MD & Re-Analyze" },
  }

  local cur_icon_y = strip_y + 10
  local tooltip_to_draw = nil

  for _, it in ipairs(icon_tabs) do
    local is_active = is_open and (active_tab == it.id)
    local btn_w = strip_w - 6
    local btn_h = (strip_w < 50) and 38 or 44
    local btn_x = strip_x + 3
    local btn_y = cur_icon_y
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
    local cx = math.floor(btn_x + (btn_w - 18) / 2)
    local cy = (strip_w < 50) and math.floor(btn_y + (btn_h - 18) / 2) or (btn_y + 4)

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

    -- Mini-label beneath icon when wide enough (hidden when compact to avoid clipping)
    if strip_w >= 50 then
      local tw = fsmall:get_width(it.label)
      local lbl = it.label
      if tw > btn_w - 2 then
        lbl = truncate(it.label, fsmall, btn_w - 2)
        tw = fsmall:get_width(lbl)
      end
      renderer.draw_text(fsmall, lbl, math.floor(btn_x + (btn_w - tw) / 2), math.floor(btn_y + 27), is_active and { 200, 230, 255, 255 } or { 110, 125, 150, 180 })
    end

    hit_rects.tab_icons[it.id] = { x = btn_x, y = btn_y, w = btn_w, h = btn_h, id = it.id }

    if hov then
      tooltip_to_draw = {
        text = it.tip,
        x = strip_x - fsmall:get_width(it.tip) - 24,
        y = btn_y + (btn_h - 22) / 2
      }
    end

    cur_icon_y = cur_icon_y + btn_h + 6
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

  -- In sidebar mode, render drop shadow on left edge of overlay drawer
  if is_sidebar_mode then
    draw_rect(panel_x - 8, panel_y, 8, panel_h, { 0, 0, 0, 70 })
    draw_rect(panel_x - 3, panel_y, 3, panel_h, { 0, 0, 0, 110 })
  end

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
  local max_title_w = panel_w - 40
  local disp_title = truncate(panel_title, fsmall, max_title_w)
  renderer.draw_text(fsmall, disp_title, math.floor(panel_x + 10), math.floor(panel_y + (hdr_h - fsmall:get_height()) / 2), { 220, 235, 255, 255 })

  -- Close / Collapse Panel Button [ ✕ ]
  local tog_w = 20
  local tog_h = 20
  local tog_x = panel_x + panel_w - tog_w - 8
  local tog_y = panel_y + (hdr_h - tog_h) / 2
  local tog_hov = is_hovered(mouse_x, mouse_y, tog_x, tog_y, tog_w, tog_h)
  draw_rect(tog_x, tog_y, tog_w, tog_h, tog_hov and { 65, 38, 48, 255 } or { 30, 36, 50, 255 })
  draw_rect(tog_x, tog_y, tog_w, 1, tog_hov and { 244, 63, 94, 255 } or { 65, 80, 110, 255 })
  local t_str = "x"
  renderer.draw_text(fsmall, t_str, math.floor(tog_x + (tog_w - fsmall:get_width(t_str)) / 2), math.floor(tog_y + (tog_h - fsmall:get_height()) / 2), tog_hov and { 255, 120, 140, 255 } or { 160, 180, 210, 255 })
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
  local toggle_x = is_collapsed and math.floor(rx + (rw - toggle_w) / 2) or (rx + rw - toggle_w - 7)
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

  local btn_w = is_collapsed and (rw - 8) or (rw - 12)
  local btn_h = is_collapsed and 40 or 42
  local btn_x = is_collapsed and (rx + 4) or (rx + 6)
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
    local ix = is_collapsed and math.floor(btn_x + (btn_w - 20) / 2) or (btn_x + 10)
    local iy = math.floor(cy + (btn_h - 20) / 2)

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

  local is_sidebar = tw < 760 * SCALE
  local is_compact = tw < 580 * SCALE
  local is_ultra   = tw < 420 * SCALE

  draw_rect(tx, ty, tw, TOOLBAR_H, COLORS.toolbar_bg)
  draw_rect(tx, ty + TOOLBAR_H - 1, tw, 1, COLORS.separator)

  local hit_rects = {
    export_rect       = {},
    guide_rect        = {},
    reanalyze_rect    = {},
    fit_rect          = { x = -999, y = -999, w = 0, h = 0 },
    zoom100_rect      = { x = -999, y = -999, w = 0, h = 0 },
    zoom_in_rect      = { x = -999, y = -999, w = 0, h = 0 },
    zoom_out_rect     = { x = -999, y = -999, w = 0, h = 0 },
    provider_rect     = { x = -999, y = -999, w = 0, h = 0 },
    search_rect       = nil,
    search_clear_rect = nil,
    search_next_rect  = nil,
    search_prev_rect  = nil,
    category_pill     = nil,
    ask_ai_rect       = nil,
    audit_rect        = nil,
    flow_exit_rect    = nil,
    focus_exit_rect   = nil,
    impact_exit_rect  = nil,
  }

  local btn_y = ty + (TOOLBAR_H - 24) / 2

  -- ─── LEFT REGION ───────────────────────────────────────────────────────────
  -- Mini vector icon (3 nodes connected)
  local icon_x = tx + 8
  local icon_y = ty + (TOOLBAR_H - 12) / 2
  draw_rect(icon_x,     icon_y + 3, 4, 4, { 130, 170, 255, 255 })
  draw_rect(icon_x + 4, icon_y + 4, 5, 2, { 100, 140, 210, 200 })
  draw_rect(icon_x + 9, icon_y,     4, 4, { 100, 220, 150, 255 })
  draw_rect(icon_x + 9, icon_y + 7, 4, 4, { 255, 180, 100, 255 })

  local active_cat = (view and view.categories and view.categories[view.active_category_idx]) or "Architecture"
  local left_end_x = icon_x + 18

  if is_compact then
    -- Interactive Dropdown Pill: [ 🏛️ Architecture ▼ ]
    local max_cat_w = is_ultra and 85 or 140
    local disp_cat = truncate(active_cat, font, max_cat_w)
    local pill_text = disp_cat .. " "
    local ptw = font:get_width(pill_text)
    local pill_w = ptw + 18
    local pill_x = left_end_x
    local pill_h = 24
    local pill_y = btn_y
    local p_hov = is_hovered(mouse_x, mouse_y, pill_x, pill_y, pill_w, pill_h)

    draw_rect(pill_x, pill_y, pill_w, pill_h, p_hov and { 45, 58, 85, 255 } or { 32, 40, 58, 255 })
    draw_rect(pill_x, pill_y, pill_w, 1, p_hov and { 130, 175, 255, 255 } or { 65, 85, 125, 255 })
    renderer.draw_text(font, disp_cat, math.floor(pill_x + 6), math.floor(pill_y + (pill_h - font:get_height()) / 2), p_hov and { 255, 255, 255, 255 } or { 220, 235, 255, 255 })

    -- Mini arrow ▼
    local arr_x = pill_x + pill_w - 12
    local arr_y = pill_y + 11
    draw_rect(arr_x,     arr_y,     5, 1, { 160, 195, 245, 255 })
    draw_rect(arr_x + 1, arr_y + 1, 3, 1, { 160, 195, 245, 255 })
    draw_rect(arr_x + 2, arr_y + 2, 1, 1, { 160, 195, 245, 255 })

    hit_rects.category_pill = { x = pill_x, y = pill_y, w = pill_w, h = pill_h }
    left_end_x = pill_x + pill_w + 8
  else
    -- Full title in desktop mode
    local cat_label = string.format("%s", active_cat)
    local cat_w = font:get_width(cat_label)
    renderer.draw_text(font, cat_label, math.floor(left_end_x), math.floor(ty + (TOOLBAR_H - font:get_height()) / 2), { 235, 245, 255, 255 })
    left_end_x = left_end_x + cat_w + 10

    -- Alt+N quick hint pill
    local shortcut_hint = string.format("Alt+%d", (view and view.active_category_idx) or 1)
    local sc_w = fsmall:get_width(shortcut_hint) + 8
    local sc_h = 18
    local sc_y = ty + (TOOLBAR_H - sc_h) / 2
    draw_rect(left_end_x, sc_y, sc_w, sc_h, { 35, 45, 65, 200 })
    draw_rect(left_end_x, sc_y, sc_w, 1, { 65, 85, 130, 255 })
    renderer.draw_text(fsmall, shortcut_hint, math.floor(left_end_x + 4), math.floor(sc_y + (sc_h - fsmall:get_height()) / 2), { 140, 190, 255, 240 })
    left_end_x = left_end_x + sc_w + 12

    -- Mesh density badge if wide enough
    if node_count and node_count > 0 and tw > 850 * SCALE then
      local density = (edge_count or 0) / math.max(node_count, 1)
      local mesh_label = string.format("Mesh: %d nodes, %d links (%.1fx)", node_count, edge_count or 0, density)
      local mw = fsmall:get_width(mesh_label) + 12
      local my = ty + (TOOLBAR_H - 20) / 2
      if left_end_x + mw < tx + tw - 450 then
        draw_rect(left_end_x, my, mw, 20, { 34, 42, 60, 230 })
        draw_rect(left_end_x, my, mw, 1,  { 70, 95, 150, 255 })
        renderer.draw_text(fsmall, mesh_label, math.floor(left_end_x + 6), math.floor(my + (20 - fsmall:get_height()) / 2), { 145, 215, 255, 255 })
        left_end_x = left_end_x + mw + 12
      end
    end
  end

  -- Mode Dismissal Badges (Flow / Focus / Blast radius) if active
  if view and view.flow_trace then
    local fl = view.flow_trace
    local fl_label = is_compact and " Flow [x] " or string.format(" Flow: %s->%s [x] ", fl.source, fl.target)
    local fl_w = fsmall:get_width(fl_label) + 8
    if left_end_x + fl_w < tx + tw - 160 then
      draw_rect(left_end_x, btn_y, fl_w, 24, { 14, 52, 60, 255 })
      draw_rect(left_end_x, btn_y, fl_w, 1,  { 34, 211, 238, 255 })
      renderer.draw_text(fsmall, fl_label, math.floor(left_end_x + 4), math.floor(btn_y + (24 - fsmall:get_height()) / 2), { 165, 243, 252, 255 })
      hit_rects.flow_exit_rect = { x = left_end_x, y = ty, w = fl_w, h = TOOLBAR_H }
      left_end_x = left_end_x + fl_w + 6
    end
  elseif view and view.focus_node_id then
    local foc_label = is_compact and " Focus [x] " or string.format(" Focus: %s [x] ", view.focus_node_id)
    local foc_w = fsmall:get_width(foc_label) + 8
    if left_end_x + foc_w < tx + tw - 160 then
      draw_rect(left_end_x, btn_y, foc_w, 24, { 55, 42, 20, 255 })
      draw_rect(left_end_x, btn_y, foc_w, 1,  { 245, 158, 11, 255 })
      renderer.draw_text(fsmall, foc_label, math.floor(left_end_x + 4), math.floor(btn_y + (24 - fsmall:get_height()) / 2), { 255, 215, 110, 255 })
      hit_rects.focus_exit_rect = { x = left_end_x, y = ty, w = foc_w, h = TOOLBAR_H }
      left_end_x = left_end_x + foc_w + 6
    end
  elseif view and view.impact_data then
    local imp = view.impact_data
    local imp_label = is_compact and " Blast [x] " or string.format(" Blast: %s [x] ", imp.target)
    local imp_w = fsmall:get_width(imp_label) + 8
    if left_end_x + imp_w < tx + tw - 160 then
      draw_rect(left_end_x, btn_y, imp_w, 24, { 60, 28, 35, 255 })
      draw_rect(left_end_x, btn_y, imp_w, 1,  { 244, 63, 94, 255 })
      renderer.draw_text(fsmall, imp_label, math.floor(left_end_x + 4), math.floor(btn_y + (24 - fsmall:get_height()) / 2), { 255, 160, 180, 255 })
      hit_rects.impact_exit_rect = { x = left_end_x, y = ty, w = imp_w, h = TOOLBAR_H }
      left_end_x = left_end_x + imp_w + 6
    end
  end

  -- ─── RIGHT REGION (Placing right-to-left from cur_rx) ─────────────────────
  local cur_rx = tx + tw - 8
  local min_gap = 6

  -- Helper to allocate button space
  local function try_place_btn(btn_w)
    local bx = cur_rx - btn_w
    if bx < left_end_x + min_gap then
      return nil -- Insufficient space: do not draw to prevent overlap
    end
    cur_rx = bx - 4
    return bx
  end

  -- 1. Fit to Viewport Button [Fit] / [⊡]
  local fit_label = is_ultra and "⊡" or "Fit"
  local fit_w     = is_ultra and 24 or (font:get_width(fit_label) + 12)
  local fit_x     = try_place_btn(fit_w)
  if fit_x then
    local fit_hov = is_hovered(mouse_x, mouse_y, fit_x, ty, fit_w, TOOLBAR_H)
    draw_rect(fit_x, btn_y, fit_w, 24, fit_hov and COLORS.btn_hover or { 38, 44, 58, 255 })
    draw_rect(fit_x, btn_y, fit_w, 1,  fit_hov and { 130, 170, 240, 255 } or { 55, 68, 95, 255 })
    renderer.draw_text(font, fit_label, math.floor(fit_x + (fit_w - font:get_width(fit_label)) / 2), math.floor(btn_y + (24 - font:get_height()) / 2), fit_hov and { 245, 250, 255, 255 } or COLORS.btn_text)
    hit_rects.fit_rect = { x = fit_x - 2, y = ty, w = fit_w + 4, h = TOOLBAR_H }
  end

  -- 2. 100% Zoom Button (Only if not compact)
  if not is_compact then
    local zoom_pct = string.format("%.0f%%", (scale or 1.0) * 100)
    local z100_w   = font:get_width(zoom_pct) + 10
    local z100_x   = try_place_btn(z100_w)
    if z100_x then
      local z100_hov = is_hovered(mouse_x, mouse_y, z100_x, ty, z100_w, TOOLBAR_H)
      draw_rect(z100_x, btn_y, z100_w, 24, z100_hov and COLORS.btn_hover or { 34, 38, 50, 255 })
      draw_rect(z100_x, btn_y, z100_w, 1,  z100_hov and { 130, 170, 240, 255 } or { 50, 60, 85, 255 })
      renderer.draw_text(font, zoom_pct, math.floor(z100_x + (z100_w - font:get_width(zoom_pct)) / 2), math.floor(btn_y + (24 - font:get_height()) / 2), z100_hov and { 245, 250, 255, 255 } or { 160, 180, 220, 255 })
      hit_rects.zoom100_rect = { x = z100_x - 2, y = ty, w = z100_w + 4, h = TOOLBAR_H }
    end
  end

  -- 3. Zoom [+] and [-]
  if not is_ultra then
    local plus_w = 20
    local plus_x = try_place_btn(plus_w)
    if plus_x then
      local plus_hov = is_hovered(mouse_x, mouse_y, plus_x, ty, plus_w, TOOLBAR_H)
      draw_rect(plus_x, btn_y, plus_w, 24, plus_hov and COLORS.btn_hover or { 34, 38, 50, 255 })
      renderer.draw_text(font, "+", math.floor(plus_x + (plus_w - font:get_width("+")) / 2), math.floor(btn_y + (24 - font:get_height()) / 2), plus_hov and { 255, 255, 255, 255 } or COLORS.btn_text)
      hit_rects.zoom_in_rect = { x = plus_x - 2, y = ty, w = plus_w + 4, h = TOOLBAR_H }
    end

    local minus_w = 20
    local minus_x = try_place_btn(minus_w)
    if minus_x then
      local minus_hov = is_hovered(mouse_x, mouse_y, minus_x, ty, minus_w, TOOLBAR_H)
      draw_rect(minus_x, btn_y, minus_w, 24, minus_hov and COLORS.btn_hover or { 34, 38, 50, 255 })
      renderer.draw_text(font, "-", math.floor(minus_x + (minus_w - font:get_width("-")) / 2), math.floor(btn_y + (24 - font:get_height()) / 2), minus_hov and { 255, 255, 255, 255 } or COLORS.btn_text)
      hit_rects.zoom_out_rect = { x = minus_x - 2, y = ty, w = minus_w + 4, h = TOOLBAR_H }
    end
  end

  -- 4. Provider & Model Pill
  local prov_name = provider and (provider:sub(1,1):upper() .. provider:sub(2)) or "AI"
  local short_model = model or "default"
  if #short_model > 18 then
    short_model = short_model:match("[^/]+$") or short_model
    if #short_model > 18 then short_model = short_model:sub(1, 15) .. "..." end
  end

  local prov_label
  if is_ultra then
    prov_label = "⚡"
  elseif is_compact then
    prov_label = " ⚡ " .. prov_name .. " "
  else
    prov_label = string.format(" AI: %s (%s) ", prov_name, short_model)
  end
  local prov_w   = font:get_width(prov_label) + (is_compact and 8 or 16)
  local prov_x   = try_place_btn(prov_w)
  if prov_x then
    local prov_hov = is_hovered(mouse_x, mouse_y, prov_x, ty, prov_w, TOOLBAR_H)
    draw_rect(prov_x, btn_y, prov_w, 24, prov_hov and { 52, 68, 98, 255 } or { 42, 55, 78, 255 })
    draw_rect(prov_x, btn_y, prov_w, 1,  prov_hov and { 110, 155, 240, 255 } or { 75, 110, 180, 255 })
    renderer.draw_text(font, prov_label, math.floor(prov_x + 4), math.floor(btn_y + (24 - font:get_height()) / 2), { 165, 205, 255, 255 })
    if not is_ultra and not is_compact then
      local arrow_x = prov_x + prov_w - 10
      local arrow_y = btn_y + 11
      draw_rect(arrow_x,     arrow_y,     5, 1, { 165, 205, 255, 255 })
      draw_rect(arrow_x + 1, arrow_y + 1, 3, 1, { 165, 205, 255, 255 })
      draw_rect(arrow_x + 2, arrow_y + 2, 1, 1, { 165, 205, 255, 255 })
    end
    hit_rects.provider_rect = { x = prov_x - 3, y = ty, w = prov_w + 6, h = TOOLBAR_H }
  end

  -- 5. Search / Find Controls
  local search_query     = (view and view.search_query) or ""
  local search_matches   = (view and view.search_matches) or {}
  local search_match_idx = (view and view.search_match_idx) or 0

  if not search_query or search_query == "" then
    local search_label = is_compact and " 🔍 " or ((tw > 1050) and " Find (Ctrl+F) " or " Find ")
    local search_w     = font:get_width(search_label) + (is_compact and 6 or 16)
    local search_x     = try_place_btn(search_w)
    if search_x then
      local search_hov = is_hovered(mouse_x, mouse_y, search_x, ty, search_w, TOOLBAR_H)
      draw_rect(search_x, btn_y, search_w, 24, search_hov and COLORS.btn_hover or { 38, 44, 58, 255 })
      draw_rect(search_x, btn_y, search_w, 1,  search_hov and { 130, 170, 240, 255 } or { 60, 75, 105, 255 })
      renderer.draw_text(font, search_label, math.floor(search_x + (search_w - font:get_width(search_label)) / 2), math.floor(btn_y + (24 - font:get_height()) / 2), search_hov and { 245, 250, 255, 255 } or COLORS.btn_text)
      hit_rects.search_rect = { x = search_x - 2, y = ty, w = search_w + 4, h = TOOLBAR_H }
    end
  else
    local match_count = #search_matches
    local match_info  = (match_count > 0) and string.format("%d/%d", search_match_idx, match_count) or "0"
    local q_disp      = search_query
    if #q_disp > 10 then q_disp = q_disp:sub(1, 8) .. ".." end
    local search_label = string.format(" %q (%s) ", q_disp, match_info)
    local search_w   = font:get_width(search_label) + 12
    local search_x   = try_place_btn(search_w)
    if search_x then
      local search_hov = is_hovered(mouse_x, mouse_y, search_x, ty, search_w, TOOLBAR_H)
      local pill_bg = (match_count > 0) and (search_hov and { 45, 65, 95, 255 } or { 32, 48, 72, 255 }) or { 55, 30, 30, 255 }
      local pill_bdr = (match_count > 0) and { 217, 119, 6, 255 } or { 180, 60, 60, 255 }
      draw_rect(search_x, btn_y, search_w, 24, pill_bg)
      draw_rect(search_x, btn_y, search_w, 1,  pill_bdr)
      renderer.draw_text(font, search_label, math.floor(search_x + 6), math.floor(btn_y + (24 - font:get_height()) / 2), (match_count > 0) and { 255, 230, 150, 255 } or { 255, 170, 170, 255 })
      hit_rects.search_rect = { x = search_x - 2, y = ty, w = search_w + 4, h = TOOLBAR_H }

      -- Clear 'x' button
      local clr_w = 18
      local clr_x = try_place_btn(clr_w)
      if clr_x then
        local clr_hov = is_hovered(mouse_x, mouse_y, clr_x, ty, clr_w, TOOLBAR_H)
        draw_rect(clr_x, btn_y, clr_w, 24, clr_hov and COLORS.btn_hover or { 38, 42, 54, 255 })
        renderer.draw_text(font, "x", math.floor(clr_x + (clr_w - font:get_width("x")) / 2), math.floor(btn_y + (24 - font:get_height()) / 2), clr_hov and { 255, 100, 100, 255 } or { 200, 120, 120, 255 })
        hit_rects.search_clear_rect = { x = clr_x - 2, y = ty, w = clr_w + 4, h = TOOLBAR_H }
      end
    end
  end

  -- 6. Ask AI & Audit Doctor (Only if space allows)
  if not is_ultra then
    local ask_ai_label = (view and view.ai_insight) and ((tw > 1200) and " Ask AI: ON " or " AI: ON ") or ((tw > 1200) and " Ask AI " or " ✨ AI ")
    local ask_ai_w     = font:get_width(ask_ai_label) + 8
    local ask_ai_x     = try_place_btn(ask_ai_w)
    if ask_ai_x then
      local ask_ai_hov = is_hovered(mouse_x, mouse_y, ask_ai_x, ty, ask_ai_w, TOOLBAR_H)
      local is_ask_on  = (view and view.ai_insight ~= nil)
      draw_rect(ask_ai_x, btn_y, ask_ai_w, 24, is_ask_on and { 65, 30, 95, 255 } or (ask_ai_hov and { 55, 35, 80, 255 } or { 34, 26, 48, 255 }))
      draw_rect(ask_ai_x, btn_y, ask_ai_w, 1,  is_ask_on and { 192, 132, 252, 255 } or (ask_ai_hov and { 168, 85, 247, 255 } or { 90, 50, 130, 255 }))
      renderer.draw_text(font, ask_ai_label, math.floor(ask_ai_x + 4), math.floor(btn_y + (24 - font:get_height()) / 2), is_ask_on and { 245, 230, 255, 255 } or { 216, 180, 254, 255 })
      hit_rects.ask_ai_rect = { x = ask_ai_x - 2, y = ty, w = ask_ai_w + 4, h = TOOLBAR_H }
    end

    local audit_label = (view and view.audit_open) and " Audit: ON " or ((tw > 1200) and " Audit " or " 🩺 ")
    local audit_w     = font:get_width(audit_label) + 8
    local audit_x     = try_place_btn(audit_w)
    if audit_x then
      local audit_hov = is_hovered(mouse_x, mouse_y, audit_x, ty, audit_w, TOOLBAR_H)
      local is_audit_on = (view and view.audit_open)
      draw_rect(audit_x, btn_y, audit_w, 24, is_audit_on and { 20, 65, 55, 255 } or (audit_hov and { 28, 55, 48, 255 } or { 20, 40, 36, 255 }))
      draw_rect(audit_x, btn_y, audit_w, 1,  is_audit_on and { 45, 212, 191, 255 } or (audit_hov and { 20, 184, 166, 255 } or { 30, 95, 85, 255 }))
      renderer.draw_text(font, audit_label, math.floor(audit_x + 4), math.floor(btn_y + (24 - font:get_height()) / 2), is_audit_on and { 230, 255, 250, 255 } or { 153, 246, 228, 255 })
      hit_rects.audit_rect = { x = audit_x - 2, y = ty, w = audit_w + 4, h = TOOLBAR_H }
    end
  end

  return hit_rects
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
-- Draw "nothing to map" empty state / Interactive Exploration Hero
-- ─────────────────────────────────────────────────────────────────────────────
function DiagramRenderer.draw_empty(view, cx, cy, label)
  local font = style.font
  local fcode = style.code_font or font
  local fbig = style.big_font or font
  label = label or "Nothing to map"

  -- If diagrams already exist and this is just an empty category tab:
  if view and view.diagrams and #view.categories > 0 then
    local nw = 180
    local nh = 60
    local bx = cx - nw / 2
    local by = cy - nh / 2

    draw_rect(bx - 1, by - 1, nw + 2, nh + 2, COLORS.node_border)
    draw_rect(bx, by, nw, nh, COLORS.node_default)

    local tw = font:get_width(label)
    local th = font:get_height()
    renderer.draw_text(font, label, math.floor(bx + (nw - tw) / 2), math.floor(by + (nh - th) / 2), COLORS.empty_text)
    return
  end

  -- Initial / Unmapped Project Hero State
  view.hero_rects = {}

  local avail_view_w = (view and view.size and view.size.x) or 800
  local card_w = math.max(260, math.min(520, avail_view_w - 40))
  local card_h = 240
  local bx = math.floor(cx - card_w / 2)
  local by = math.floor(cy - card_h / 2)

  -- Outer container with subtle border & background
  draw_rect(bx - 1, by - 1, card_w + 2, card_h + 2, { 55, 68, 95, 200 })
  draw_rect(bx, by, card_w, card_h, { 22, 27, 38, 252 })

  -- Top glowing accent bar
  draw_rect(bx, by, card_w, 3, { 99, 102, 241, 255 })

  -- 1. Hero Title
  local title = "✦ Architecture Visualizer"
  local title_font = (card_w < 380) and font or fbig
  local tw = title_font:get_width(title)
  renderer.draw_text(title_font, title, math.floor(cx - tw / 2), by + 20, { 245, 250, 255, 255 })

  -- 2. Subtitle
  local sub = (card_w < 400) and "Topology & Dependency Mapping" or "Interactive Architectural Topology & Dependency Mapping"
  local sw = font:get_width(sub)
  if sw > card_w - 20 then
    sub = truncate(sub, font, card_w - 20)
    sw = font:get_width(sub)
  end
  renderer.draw_text(font, sub, math.floor(cx - sw / 2), by + 50, { 160, 175, 205, 255 })

  -- 3. Provider & Model Selector Pill (Interactive click to configure)
  local prov = (view.provider or "nvidia"):upper()
  local mod = view.model or "nvidia/nemotron-3.5-bolt-e4b"
  if #mod > 24 then mod = mod:match("[^/]+$") or mod end
  if #mod > 24 then mod = mod:sub(1, 21) .. "..." end
  local pill_text = (card_w < 420) and string.format(" %s : %s [Edit] ", prov, mod) or string.format(" Provider: %s   Model: %s  [Change] ", prov, mod)
  local pw = math.min(fcode:get_width(pill_text) + 20, card_w - 20)
  local px = math.floor(cx - pw / 2)
  local py = by + 86
  local ph = 26
  local p_hov = is_hovered(view.mouse_x or 0, view.mouse_y or 0, px, py, pw, ph)

  draw_rect(px, py, pw, ph, p_hov and { 45, 60, 88, 255 } or { 32, 42, 62, 255 })
  draw_rect(px, py, pw, 1, p_hov and { 130, 175, 255, 255 } or { 70, 95, 140, 255 })
  local disp_pill = truncate(pill_text, fcode, pw - 12)
  renderer.draw_text(fcode, disp_pill, px + math.floor((pw - fcode:get_width(disp_pill)) / 2), py + math.floor((ph - fcode:get_height()) / 2), p_hov and { 255, 255, 255, 255 } or { 190, 215, 255, 255 })
  view.hero_rects.provider_pill = { x = px, y = py, w = pw, h = ph }

  -- 4. Action Button: [ 🚀 Explore & Map Project ]
  local btn_text = (card_w < 380) and " 🚀 Explore Project " or " 🚀 Explore & Map Project "
  local bw = math.min(font:get_width(btn_text) + 36, card_w - 30)
  local bx_btn = math.floor(cx - bw / 2)
  local by_btn = by + 128
  local bh = 36
  local b_hov = is_hovered(view.mouse_x or 0, view.mouse_y or 0, bx_btn, by_btn, bw, bh)

  draw_rect(bx_btn, by_btn, bw, bh, b_hov and { 79, 70, 229, 255 } or { 67, 56, 202, 255 })
  draw_rect(bx_btn, by_btn, bw, 1, b_hov and { 165, 180, 252, 255 } or { 129, 140, 248, 255 })
  renderer.draw_text(font, btn_text, bx_btn + math.floor((bw - font:get_width(btn_text)) / 2), by_btn + math.floor((bh - font:get_height()) / 2), { 255, 255, 255, 255 })
  view.hero_rects.explore_btn = { x = bx_btn, y = by_btn, w = bw, h = bh }

  -- 5. Footer info & shortcut
  local count = view._cached_file_count
  local now = system.get_time()
  if not count or (now - (view._cached_file_count_time or 0) > 3) then
    local files = get_project_files and get_project_files() or {}
    count = #files
    view._cached_file_count = count
    view._cached_file_count_time = now
  end
  local info_text = (card_w < 420) and string.format("%d files detected • Ready to explore", count) or string.format("%d project files detected • Analysis starts on click", count)
  local iw = fcode:get_width(info_text)
  if iw > card_w - 16 then
    info_text = truncate(info_text, fcode, card_w - 16)
    iw = fcode:get_width(info_text)
  end
  renderer.draw_text(fcode, info_text, math.floor(cx - iw / 2), by + 180, { 140, 155, 180, 255 })

  local hint_text = "(Ctrl+Shift+Y to start anytime)"
  local hw = fcode:get_width(hint_text)
  renderer.draw_text(fcode, hint_text, math.floor(cx - hw / 2), by + 202, { 100, 115, 140, 255 })
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

-- SECTION 4: SVG EXPORTER
-- SVG Exporter for AI Project Visualizer
-- Serializes diagram data to SVG files in {project_root}/.visualizer/
-- Uses pixel-perfect orthogonal Manhattan channel routing matching canvas rendering.

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

-- SECTION 5: VISUALIZER VIEW & INTEGRATION
-- =============================================================================

local function show_toast(msg)
  pcall(function()
    if core.status_view and core.status_view.show_message then
      core.status_view:show_message(msg)
    else
      core.log("[AI Visualizer] %s", msg)
    end
  end)
end

get_project_files = function()
  local files = {}
  local seen = {}

  local function add_file(p)
    if not p or seen[p] then return end
    seen[p] = true
    table.insert(files, p)
  end

  pcall(function()
    -- 1. Official Lite XL project files iterator
    if core.get_project_files then
      for dir_name, item in core.get_project_files() do
        if item and (item.type == "file" or not item.type) then
          local fn = item.filename or item.path or tostring(item)
          if dir_name and dir_name ~= "" then
            add_file(dir_name .. "/" .. fn)
          else
            add_file(fn)
          end
        end
      end
    end

    -- 2. Fallback to core.project_files or core.project.files
    if #files == 0 then
      local list = core.project_files or (core.project and core.project.files) or (core.project and core.project.get_file_list and core.project:get_file_list())
      if list then
        for _, item in ipairs(list) do
          local p = (type(item) == "table" and (item.filename or item.path)) or tostring(item)
          add_file(p)
        end
      end
    end
  end)

  -- 3. Filesystem walk fallback if list is empty
  if #files == 0 and core.project_dir then
    local ignored_dirs = {
      ["node_modules"] = true,
      [".git"]         = true,
      [".visualizer"]  = true,
      ["venv"]         = true,
      [".venv"]        = true,
      ["my_env"]       = true,
      ["myenv"]        = true,
      ["env"]          = true,
      ["target"]       = true,
      ["build"]        = true,
      ["dist"]         = true,
      [".idea"]        = true,
      [".vscode"]      = true,
      ["__pycache__"]  = true,
    }
    local function walk(dir)
      local items = system.list_dir(dir) or {}
      for _, name in ipairs(items) do
        if name ~= "." and name ~= ".." and not name:match("^%.") and not ignored_dirs[name] then
          local full = dir .. "/" .. name
          local info = system.get_file_info(full)
          if info then
            if info.type == "dir" then
              walk(full)
            else
              add_file(full)
            end
          end
        end
      end
    end
    pcall(walk, core.project_dir)
  end

  return files
end

local function open_node_file(node)
  if not node or not node.file then
    show_toast("No source file associated with this node")
    return
  end

  local ok, err = pcall(function()
    local path = node.file
    if not path:match("^%a:[/\\]") and not path:match("^[/\\]") and core.project_dir then
      path = core.project_dir .. "/" .. path
    end

    local doc = core.open_doc(path)
    if doc then
      local view = core.root_view:open_doc(doc)
      local line = tonumber(node.line) or 1
      if doc.set_selection then doc:set_selection(line, 1, line, 1) end
      if view and view.scroll_to_line then view:scroll_to_line(line, true) end
      show_toast(string.format("Opened %s:%d", node.file, line))
    else
      show_toast("Could not open file: " .. tostring(node.file))
    end
  end)

  if not ok then
    show_toast("Failed to open file: " .. tostring(err))
  end
end

local VisualizerView = View:extend()

function VisualizerView:new()
  VisualizerView.super.new(self)
  self.name = "AI Project Visualizer"
  self.scrollable = false
  self.target_size = 520 * SCALE
  self.visible = true
  self.size = { x = 520 * SCALE, y = 0 }

  self.diagrams            = {}
  self.categories          = {}
  self.active_category_idx = 1
  self.layout_states       = {}

  self.pan_x = 0
  self.pan_y = 0
  self.scale = 1.0

  self.hovered_node  = nil
  self.hover_timer   = 0
  self.show_tooltip  = false
  self.mouse_x       = 0
  self.mouse_y       = 0
  self.dragging      = false
  self.drag_start_x  = 0
  self.drag_start_y  = 0
  self.pan_start_x   = 0
  self.pan_start_y   = 0

  self.rail_hit_rects = {}
  self.toolbar_rects = { reanalyze_rect = {}, export_rect = {}, provider_rect = {} }

  self.search_query     = ""
  self.search_matches   = {}
  self.search_match_idx = 0

  self.focus_node_id    = nil
  self.impact_node_id   = nil
  self.impact_data      = nil
  self.inspector_open   = false
  self.inspector_node   = nil
  self.inspector_rects  = {}
  self.story_mode       = false
  self.story_tour_idx   = 1
  self.story_step_idx   = 1
  self.story_tours      = {}
  self.heatmap_mode     = false
  self.has_fitted        = false
  self.sidebar_collapsed = true
  self.sidebar_w         = 200 * SCALE
  self.right_rail_open   = false
  self.right_rail_tab    = "dimensions"
  self.right_rail_w      = 340 * SCALE
  self.custom_node_w     = 230
  self.custom_node_h     = 84
  self.custom_h_gap      = 70
  self.custom_v_gap      = 55
  self.right_rail_hits   = {}
  self.show_suggested_nodes = true
  self.ai_insight        = nil
  self.ai_insight_loading = false
  self.ai_insight_query   = nil
  self.ai_banner_rects   = {}
  self.ai_insight_enlarged = false
  self.ai_insight_scroll_y = 0
  self.audit_open        = false
  self.audit_data        = nil
  self.audit_rects       = {}
  self.audit_finding_enlarged = nil
  self.audit_enlarged_scroll_y = 0
  self.audit_enlarged_rects    = {}
  self.flow_trace        = nil
  self.flow_rects        = {}

  self.is_analyzing   = false
  self.analysis_error = nil
  self.status_message = nil
  self.spinner_time   = 0

  -- Load preferred provider & model
  self:load_provider_config()

  local proj_dir = core.project_dir or "."
  self.cache_path = proj_dir .. "/.visualizer/cache.json"

  if self:load_cache() then
    self:run_layout()
    self:reset_viewport()
  else
    -- Await explicit user exploration trigger; do NOT auto-start Groq or any API
    self.diagrams = nil
    self.categories = {}
    self.status_message = nil
    self.is_analyzing = false
  end
end

function VisualizerView:get_name()
  return "AI Project Visualizer"
end

function VisualizerView:get_scrollable_size()
  return 0
end

function VisualizerView:set_target_size(axis, value)
  if axis == "x" then
    self.size.x = value
    return true
  elseif axis == "y" then
    self.size.y = value
    return true
  end
  return false
end

function VisualizerView:get_content_bounds()
  return self.position.x, self.position.y, self.size.x, self.size.y
end

function VisualizerView:load_provider_config()
  pcall(function()
    local proj_dir = core.project_dir or "."
    local sep = package.config:sub(1,1)
    local f = io.open(proj_dir .. sep .. ".visualizer" .. sep .. "provider_config.json", "r")
    if f then
      local c = f:read("*a")
      f:close()
      if c and #c > 0 then
        local data = AIAnalyzer.json_decode(c)
        if data and data.provider then
          self.provider = data.provider
          self.model    = data.model
        end
      end
    end
  end)

  local prov, mod = AIAnalyzer.get_active_provider(self.provider, self.model)
  self.provider = prov
  self.model    = mod
end

function VisualizerView:set_provider_and_model(provider, model)
  self.provider = provider
  self.model    = model
  pcall(function()
    local proj_dir = core.project_dir or "."
    local vis_dir  = proj_dir .. "/.visualizer"
    local sep = package.config:sub(1,1)
    ensure_dir(vis_dir)
    local f = io.open(vis_dir .. sep .. "provider_config.json", "w")
    if f then
      f:write(AIAnalyzer.json_encode({ provider = self.provider, model = self.model }))
      f:close()
    end
  end)
end

function VisualizerView:select_provider_dialog()
  local keys = AIAnalyzer.load_saved_keys()
  local providers_list = { "nvidia", "gemini", "groq", "ollama", "openai", "anthropic" }
  local items = {}

  for _, p in ipairs(providers_list) do
    local pinfo = AIAnalyzer.PROVIDERS[p]
    local has_key = (keys[p] and #keys[p] > 0)
    local status = has_key and " [Key Saved]" or " [Missing Key - click to enter]"
    local active = (p == self.provider) and " [ACTIVE]" or ""
    table.insert(items, string.format("%s%s%s", pinfo.name, active, status))
  end

  core.command_view:enter("Select AI Provider for Visualizer", {
    submit = function(text, item)
      local raw = (type(item) == "table" and item.text) or (type(item) == "string" and item) or text or ""
      raw = raw:match("^%s*(.-)%s*$") or ""
      local selected_prov = nil
      if #raw > 0 then
        for _, p in ipairs(providers_list) do
          local pinfo = AIAnalyzer.PROVIDERS[p]
          if pinfo and (raw:lower():find(pinfo.name:lower(), 1, true) or raw:lower():find(p:lower(), 1, true)) then
            selected_prov = p
            break
          end
        end
        if not selected_prov then
          local match = raw:match("^([%w_]+)")
          if match then
            selected_prov = match:lower()
          end
        end
      end
      selected_prov = selected_prov or self.provider or "nvidia"

      if not AIAnalyzer.PROVIDERS[selected_prov] then
        show_toast("Unknown provider: " .. tostring(selected_prov))
        return
      end

      local pinfo = AIAnalyzer.PROVIDERS[selected_prov]

      local function prompt_for_model()
        local cached_models = AIAnalyzer.get_cached_models(selected_prov)
        local cur_model = (selected_prov == self.provider and self.model) or pinfo.default_model or ""
        local model_items = {}

        for _, m in ipairs(cached_models) do
          local lbl = AIAnalyzer.get_model_label(m)
          local is_curr = (m == cur_model) and " (Current)" or ""
          table.insert(model_items, string.format("%-44s %-14s%s", m, lbl, is_curr))
        end

        core.command_view:enter("Select Model for " .. pinfo.name .. " (filter or type custom)", {
          text = cur_model,
          submit = function(model_text, model_item)
            local raw_m = (type(model_item) == "table" and model_item.text) or (type(model_item) == "string" and model_item) or model_text or ""
            raw_m = raw_m:match("^%s*(.-)%s*$") or ""
            if #raw_m == 0 then
              raw_m = cur_model
            end
            -- Strip capability tag and current tag
            raw_m = raw_m:gsub("%s*%[.-%].*", ""):gsub("%s*%(.-%).*", "")
            raw_m = raw_m:match("^%s*(.-)%s*$") or ""
            if #raw_m == 0 then
              raw_m = cur_model
            end
            self:set_provider_and_model(selected_prov, raw_m)
            if not self.diagrams or #self.categories == 0 then
              show_toast(string.format("AI Visualizer: Provider set to %s (%s). Click [Explore] to begin.", pinfo.name, raw_m))
            else
              show_toast(string.format("AI Visualizer: Model switched to %s (%s). Press Ctrl+Shift+Y to re-analyze.", pinfo.name, raw_m))
            end
            core.redraw = true
          end,
          suggest = function(filter_text)
            local q = (filter_text or ""):lower()
            local res = {}
            for _, item_entry in ipairs(model_items) do
              if item_entry:lower():find(q, 1, true) then
                table.insert(res, item_entry)
              end
            end
            return res
          end
        })
      end

      -- If key is missing, prompt to enter it and save it to ai_api_keys.json
      if not keys[selected_prov] or #keys[selected_prov] == 0 then
        core.command_view:enter("Enter API Key for " .. pinfo.name, {
          submit = function(key_text)
            key_text = (key_text or ""):match("^%s*(.-)%s*$") or ""
            if #key_text > 0 then
              AIAnalyzer.save_key(selected_prov, key_text)
              keys[selected_prov] = key_text
              show_toast("Saved key for " .. pinfo.name)
              prompt_for_model()
            end
          end
        })
        return
      end

      prompt_for_model()
    end,
    suggest = function(text)
      local q = (text or ""):lower()
      local res = {}
      for _, item in ipairs(items) do
        if item:lower():find(q, 1, true) then
          table.insert(res, item)
        end
      end
      return res
    end
  })
end

function VisualizerView:cycle_provider()
  local keys = AIAnalyzer.load_saved_keys()
  local available = {}
  local providers_list = { "nvidia", "gemini", "groq", "ollama", "openai", "anthropic" }
  for _, p in ipairs(providers_list) do
    if keys[p] and #keys[p] > 0 then
      table.insert(available, p)
    end
  end

  if #available == 0 then
    self:select_provider_dialog()
    return
  end

  local cur_idx = 1
  for i, p in ipairs(available) do
    if p == self.provider then cur_idx = i; break end
  end

  local next_idx = (cur_idx % #available) + 1
  local next_p = available[next_idx]
  local pinfo = AIAnalyzer.PROVIDERS[next_p]
  self:set_provider_and_model(next_p, pinfo.default_model)
  show_toast(string.format("AI Visualizer: Provider set to %s (%s)", pinfo.name, pinfo.default_model))
  core.redraw = true
end


function VisualizerView:toggle_suggested_nodes()
  self.show_suggested_nodes = not (self.show_suggested_nodes ~= false)
  if self.show_suggested_nodes then
    show_toast("AI Visualizer: Suggestions visible")
  else
    show_toast("AI Visualizer: Showing verified repository code only")
  end
  core.redraw = true
end

function VisualizerView:rebuild_file_set()
  self.project_files_set = {}
  local files = get_project_files()
  local pdir = core.project_dir and (core.project_dir:gsub('\\', '/') .. "/") or ""
  for _, path in ipairs(files) do
    local norm = path:gsub('\\', '/')
    self.project_files_set[norm] = true
    self.project_files_set[path] = true
    if pdir ~= "" and norm:sub(1, #pdir) == pdir then
      local rel = norm:sub(#pdir + 1)
      self.project_files_set[rel] = true
    end
    local base = norm:match('[^/]+$')
    if base then self.project_files_set[base] = true end
  end
end

function VisualizerView:is_file_real(filepath)
  if not filepath or filepath == "" then return false end
  if not self.project_files_set then
    self:rebuild_file_set()
  end
  local nf = filepath:gsub('\\', '/')
  local base = nf:match('[^/]+$') or nf
  if self.project_files_set[nf] or self.project_files_set[filepath] or self.project_files_set[base] then
    return true
  end
  if system.get_file_info(filepath) then
    return true
  end
  if core.project_dir then
    local sep = package.config:sub(1,1)
    if system.get_file_info(core.project_dir .. sep .. filepath) then
      return true
    end
  end
  return false
end

function VisualizerView:validate_and_ground_cache(diagrams)
  self:rebuild_file_set()
  local files = get_project_files()
  local has_project_files = (#files > 0)
  local total_nodes = 0
  local real_file_nodes = 0

  local grounded_diagrams = {}
  for cat, diag in pairs(diagrams) do
    if diag.nodes and diag.edges then
      local valid_nodes = {}
      local node_ids = {}
      for _, n in ipairs(diag.nodes) do
        total_nodes = total_nodes + 1
        local is_real = false
        if n.file and n.file ~= "" and not n.external then
          if self:is_file_real(n.file) then
            is_real = true
            real_file_nodes = real_file_nodes + 1
          end
        end

        if not is_real then
          n.suggested = true
        end

        -- Prune hallucinated files that do not exist at all in current project
        local keep = true
        if has_project_files and n.suggested and not n.external then
          if n.file and n.file ~= "" and not is_real then
            local base = n.file:match('[^/\\]+$')
            if not self.project_files_set[base] then
              keep = false
            end
          end
        end

        if keep then
          table.insert(valid_nodes, n)
          node_ids[n.id] = true
        end
      end

      local valid_edges = {}
      for _, e in ipairs(diag.edges) do
        if e.from and e.to and node_ids[e.from] and node_ids[e.to] then
          table.insert(valid_edges, e)
        end
      end

      if #valid_nodes > 0 then
        grounded_diagrams[cat] = {
          nodes = valid_nodes,
          edges = valid_edges,
        }
      end
    end
  end

  -- Stale foreign cache eviction: if project has files but 0 cached nodes matched, discard cache
  if has_project_files and real_file_nodes == 0 and total_nodes > 0 then
    core.log("[AI Visualizer] Stale cache detected (0 matching files). Evicting cache.")
    return nil
  end

  return next(grounded_diagrams) and grounded_diagrams or nil
end

function VisualizerView:load_cache()
  local f = io.open(self.cache_path, "r")
  if not f then return false end
  local content = f:read("*a")
  f:close()
  if not content or #content == 0 then return false end

  local ok, data = pcall(AIAnalyzer.json_decode, content)
  if ok and data and type(data) == "table" and data.diagrams then
    local validated = self:validate_and_ground_cache(data.diagrams)
    if validated then
      self.diagrams = validated
      self:rebuild_categories()
      return (#self.categories > 0)
    else
      -- Stale cache evicted: remove file so it triggers fresh analysis
      pcall(os.remove, self.cache_path)
    end
  end
  return false
end

function VisualizerView:save_cache()
  pcall(function()
    local proj_dir = core.project_dir or "."
    local vis_dir  = proj_dir .. "/.visualizer"
    ensure_dir(vis_dir)
    local files = get_project_files()
    local cache_data = {
      version      = 2,
      project_dir  = proj_dir:gsub('\\', '/'),
      project_name = proj_dir:match('[^/\\]+$') or "unknown",
      created_at   = os.time(),
      file_count   = #files,
      diagrams     = self.diagrams
    }
    local f = io.open(self.cache_path, "w")
    if f then
      f:write(AIAnalyzer.json_encode(cache_data))
      f:close()
    end
  end)
end

function VisualizerView:clean_and_sanitize_cache(silent)
  pcall(function()
    AIAnalyzer.cancel()

    -- 1. Remove active cache file
    if self.cache_path and system.get_file_info(self.cache_path) then
      pcall(os.remove, self.cache_path)
    end

    -- 2. Clean stale backup/temp files in .visualizer directory
    local proj_dir = core.project_dir or "."
    local vis_dir  = proj_dir .. "/.visualizer"
    local stale_names = { "cache.json", "cache.json.bak", "cache.json.old", "cache_tmp.json", "cache.tmp" }
    for _, fn in ipairs(stale_names) do
      local p = vis_dir .. "/" .. fn
      if system.get_file_info(p) then pcall(os.remove, p) end
    end

    -- 3. Reset in-memory state completely
    self.diagrams            = {}
    self.categories          = {}
    self.active_category_idx = 1
    self.selected_node       = nil
    self.inspector_node      = nil
    self.focus_node_id       = nil
    self.blast_node_id       = nil
    self.flow_trace          = nil
    self.flow_rects          = {}
    self.ai_insight          = nil
    self.ai_insight_enlarged = false
    self.ai_insight_scroll_y = 0
    self.search_query        = ""
    self.search_matches      = {}
    self.search_index        = 0
    self:rebuild_file_set()
  end)

  if not silent then
    show_toast("AI Visualizer: Cache sanitized successfully.")
  end
  core.redraw = true
end

function VisualizerView:clear_cache()
  self:clean_and_sanitize_cache(true)
end

function VisualizerView:rebuild_categories()
  self.categories = {}
  local order = {
    "System Architecture",
    "Data Flow",
    "API Endpoints",
    "Security & Auth",
    "Middleware Chain",
    "Component Dependencies",
  }
  local seen = {}
  for _, name in ipairs(order) do
    if self.diagrams[name] and self.diagrams[name].nodes and #self.diagrams[name].nodes > 0 then
      table.insert(self.categories, name)
      seen[name] = true
    end
  end
  for name, diag in pairs(self.diagrams) do
    if not seen[name] and diag.nodes and #diag.nodes > 0 then
      table.insert(self.categories, name)
      seen[name] = true
    end
  end

  if self.active_category_idx < 1 or self.active_category_idx > #self.categories then
    self.active_category_idx = 1
  end
end

function VisualizerView:current_diagram()
  local cat = self.categories[self.active_category_idx]
  return cat and self.diagrams[cat] or nil
end

function VisualizerView:switch_category(idx)
  if idx == self.active_category_idx or idx < 1 or idx > #self.categories then return end
  local old_cat = self.categories[self.active_category_idx]
  if old_cat then
    self.layout_states[old_cat] = { pan_x = self.pan_x, pan_y = self.pan_y, scale = self.scale }
  end

  self.active_category_idx = idx
  local new_cat = self.categories[idx]
  if new_cat and self.layout_states[new_cat] then
    local st = self.layout_states[new_cat]
    self.pan_x = st.pan_x; self.pan_y = st.pan_y; self.scale = st.scale
  else
    self:fit_to_view()
  end
  self.hovered_node = nil
  self.show_tooltip = false

  if self.search_query and self.search_query ~= "" then
    self:set_search_query(self.search_query)
  end
end

function VisualizerView:next_category()
  if #self.categories == 0 then return end
  local next_idx = self.active_category_idx + 1
  if next_idx > #self.categories then next_idx = 1 end
  self:switch_category(next_idx)
end

function VisualizerView:pick_category_dialog()
  if not self.categories or #self.categories == 0 then
    show_toast("No architecture diagrams generated yet")
    return
  end
  local cat_items = {}
  for i, name in ipairs(self.categories) do
    table.insert(cat_items, { text = string.format("%d. %s", i, name), idx = i, name = name })
  end
  core.command_view:enter("Switch Architecture View", {
    submit = function(text, item)
      local idx = item and item.idx
      if not idx and text then
        local num = tonumber(text:match("^(%d+)"))
        if num and num >= 1 and num <= #self.categories then
          idx = num
        else
          for i, n in ipairs(self.categories) do
            if n:lower():find(text:lower(), 1, true) then
              idx = i
              break
            end
          end
        end
      end
      if idx then
        self:switch_category(idx)
      end
    end,
    suggest = function(text)
      local res = {}
      for _, it in ipairs(cat_items) do
        if text == "" or it.text:lower():find(text:lower(), 1, true) or it.name:lower():find(text:lower(), 1, true) then
          table.insert(res, it)
        end
      end
      return res
    end
  })
end

function VisualizerView:reset_viewport()
  self:fit_to_view()
end

function VisualizerView:fit_to_view()
  local _, _, w, h = self:get_content_bounds()
  local diag = self:current_diagram()
  if diag and diag.nodes and #diag.nodes > 0 then
    local min_x, min_y =  math.huge,  math.huge
    local max_x, max_y = -math.huge, -math.huge
    for _, n in ipairs(diag.nodes) do
      min_x = math.min(min_x, n.x or 0)
      min_y = math.min(min_y, n.y or 0)
      max_x = math.max(max_x, (n.x or 0) + (n.w or (self.custom_node_w or 230)))
      max_y = math.max(max_y, (n.y or 0) + (n.h or (self.custom_node_h or 84)))
    end
    local gw = math.max(max_x - min_x, 100)
    local gh = math.max(max_y - min_y, 100)

    local is_sidebar = (w < 760 * SCALE)
    local rail_w
    if self.sidebar_collapsed then
      rail_w = 44 * SCALE
    elseif is_sidebar then
      rail_w = math.min(180 * SCALE, math.floor(w * 0.4))
    else
      rail_w = self.sidebar_w or (200 * SCALE)
    end
    DiagramRenderer.RAIL_W = rail_w

    local strip_w = (is_sidebar and 44 or 54) * SCALE
    local right_space = is_sidebar and strip_w or ((not self.right_rail_open) and strip_w or math.min(self.right_rail_w or (360 * SCALE), math.floor(w * 0.35)))
    DiagramRenderer.RIGHT_RAIL_W = right_space

    local avail_w = math.max(w - rail_w - right_space - 40 * SCALE, 160 * SCALE)
    local avail_h = math.max(h - (DiagramRenderer.TOOLBAR_H or 36) - (DiagramRenderer.STATUS_H or 28) - 40 * SCALE, 160 * SCALE)

    local fit_scale = math.min(avail_w / gw, avail_h / gh)
    self.scale = math.max(0.22, math.min(fit_scale, 1.25))

    local cx = self.position.x + rail_w + (w - rail_w - right_space) / 2
    local cy = self.position.y + (DiagramRenderer.TOOLBAR_H or 36) + (h - (DiagramRenderer.TOOLBAR_H or 36) - (DiagramRenderer.STATUS_H or 28)) / 2
    local gcx = (min_x + max_x) / 2
    local gcy = (min_y + max_y) / 2
    self.pan_x = cx - gcx * self.scale
    self.pan_y = cy - gcy * self.scale
    core.redraw = true
  end
end

function VisualizerView:zoom_in()
  local mx = self.position.x + self.size.x / 2
  local my = self.position.y + self.size.y / 2
  local wx, wy = DiagramRenderer.screen_to_world(mx, my, self.pan_x, self.pan_y, self.scale)
  self.scale = math.min(3.5, self.scale * 1.15)
  self.pan_x = mx - wx * self.scale
  self.pan_y = my - wy * self.scale
  core.redraw = true
end

function VisualizerView:zoom_out()
  local mx = self.position.x + self.size.x / 2
  local my = self.position.y + self.size.y / 2
  local wx, wy = DiagramRenderer.screen_to_world(mx, my, self.pan_x, self.pan_y, self.scale)
  self.scale = math.max(0.2, self.scale * 0.85)
  self.pan_x = mx - wx * self.scale
  self.pan_y = my - wy * self.scale
  core.redraw = true
end

function VisualizerView:zoom_100()
  local mx = self.position.x + self.size.x / 2
  local my = self.position.y + self.size.y / 2
  local wx, wy = DiagramRenderer.screen_to_world(mx, my, self.pan_x, self.pan_y, self.scale)
  self.scale = 1.0
  self.pan_x = mx - wx * 1.0
  self.pan_y = my - wy * 1.0
  core.redraw = true
end

function VisualizerView:run_layout()
  local _, _, w, h = self:get_content_bounds()
  w = math.max(w, 800)
  h = math.max(h, 600)
  for _, diag in pairs(self.diagrams) do
    if diag.nodes and #diag.nodes > 0 then
      local ln, le = LayoutEngine.run(diag.nodes, diag.edges or {}, w, h)
      diag.nodes = ln; diag.edges = le
      if LayoutEngine.normalize_nodes then
        LayoutEngine.normalize_nodes(diag.nodes, diag.edges, 60, 60)
      else
        LayoutEngine.center_nodes(diag.nodes, diag.edges, w / 2, h / 2)
      end
    end
  end
end

function VisualizerView:start_analysis()
  if self.is_analyzing then return end
  local files = get_project_files()
  if #files == 0 then
    self.analysis_error = "No supported source files found in the project"
    return
  end

  self.is_analyzing   = true
  self.analysis_error = nil
  self.status_message = string.format("Starting AI analysis with %s...", (self.provider or "AI"):upper())

  local opts = {
    provider = self.provider,
    model    = self.model,
  }

  core.add_thread(function()
    AIAnalyzer.analyze(
      files,
      function(prog) self.status_message = prog end,
      function(diagrams)
        self.diagrams = diagrams
        self:rebuild_categories()
        self:run_layout()
        self:save_cache()
        self:reset_viewport()
        self.is_analyzing   = false
        self.status_message = nil
        show_toast("AI Visualizer: Analysis completed!")
      end,
      function(err)
        self.is_analyzing   = false
        self.analysis_error = err
        self.status_message = nil
        show_toast("AI Visualizer: " .. tostring(err))
      end,
      opts
    )
  end)
end

function VisualizerView:reanalyze()
  -- Automated cleanup before re-analysis to guarantee zero cache poisoning
  self:clean_and_sanitize_cache(true)
  show_toast("AI Visualizer: Cache sanitized. Starting fresh re-analysis...")
  self:start_analysis()
end

function VisualizerView:toggle_heatmap()
  self.heatmap_mode = not self.heatmap_mode
  if self.heatmap_mode then
    show_toast("Architecture Heatmap: ON (Amber: SPOF / Cyan: Cloud / Red: Mutations)")
  else
    show_toast("Architecture Heatmap: OFF")
  end
  core.redraw = true
end

function VisualizerView:generate_onboarding_guide_markdown()
  local lines = {}
  local function add(s) table.insert(lines, s or "") end

  add("# Contributor Architecture & Onboarding Guide")
  add("")
  add("> Automatically generated by **AI Project Visualizer**.")
  add("> Provides an end-to-end architectural mental model, subsystem directory,")
  add("> execution workflows, blast radius analysis, and local dev checklist.")
  add("")
  add("---")
  add("")
  add("## 1. Executive System Architecture")
  add("")
  local cat_count = 0
  for _ in pairs(self.diagrams or {}) do cat_count = cat_count + 1 end
  add(string.format("- **Analyzed Architecture Categories**: %d", cat_count))
  add("- **Core Architecture Pattern**: Modular Layered Microservices / Monolithic Core")
  add("- **Communication Protocols**: HTTP/REST, Internal Service Calls, Persistence Adapters")
  add("")
  add("---")
  add("")
  add("## 2. Subsystem & Component Directory")
  add("")
  add("| Component | Category | Tier | File / Module | Responsibility | Ports / Config |")
  add("| :--- | :--- | :--- | :--- | :--- | :--- |")

  local all_nodes = {}
  local in_deg = {}
  local out_deg = {}

  for cat, d in pairs(self.diagrams or {}) do
    for _, n in ipairs(d.nodes or {}) do
      if not all_nodes[n.id] then
        all_nodes[n.id] = { node = n, category = cat }
        in_deg[n.id] = 0
        out_deg[n.id] = 0
      end
    end
    for _, e in ipairs(d.edges or {}) do
      if e.from and out_deg[e.from] then out_deg[e.from] = out_deg[e.from] + 1 end
      if e.to and in_deg[e.to] then in_deg[e.to] = in_deg[e.to] + 1 end
    end
  end

  local sorted_ids = {}
  for nid in pairs(all_nodes) do table.insert(sorted_ids, nid) end
  table.sort(sorted_ids)

  for _, nid in ipairs(sorted_ids) do
    local item = all_nodes[nid]
    local n = item.node
    local name = n.name or n.label or nid
    local ntype = n.type or "service"
    local fpath = n.file or "N/A"
    local line = n.line or 1
    local desc = (n.desc or n.responsibility or "Core system module"):gsub("|", "/")
    local ports = n.port or ((ntype == "gateway") and "80/443" or ((ntype == "database") and "5432/27017" or "Default"))
    add(string.format("| `%s` | %s | `%s` | `%s:%s` | %s | `%s` |", name, item.category, ntype, fpath, tostring(line), desc, ports))
  end

  add("")
  add("---")
  add("")
  add("## 3. Architecture Fragility & Single Points of Failure (SPOF)")
  add("")
  add("Components with high inbound callers pose high blast radius upon interface changes.")
  add("")
  add("| Critical Component | Inbound Callers | Outbound Dependencies | Fragility Risk | Blast Profile |")
  add("| :--- | :--- | :--- | :--- | :--- |")

  table.sort(sorted_ids, function(a, b) return (in_deg[a] or 0) > (in_deg[b] or 0) end)
  for _, nid in ipairs(sorted_ids) do
    local fin = in_deg[nid] or 0
    local fout = out_deg[nid] or 0
    if fin >= 2 or fout >= 3 then
      local n = all_nodes[nid].node
      local name = n.name or n.label or nid
      local risk = (fin >= 4) and "**HIGH RISK (CRITICAL INFRASTRUCTURE)**" or ((fin >= 2) and "**MEDIUM RISK**" or "LOW RISK")
      add(string.format("| `%s` | %d callers | %d dependencies | %s | High fan-in junction |", name, fin, fout, risk))
    end
  end

  add("")
  add("---")
  add("")
  add("## 4. Local Development & Setup Checklist")
  add("")
  add("- [ ] **Runtime**: Ensure Node.js / Python / Docker runtimes matching requirements are installed.")
  add("- [ ] **Environment Configuration**: Configure necessary ports and environment variables.")
  add("- [ ] **Databases & Caches**: Ensure local containers or connection strings for detected storage nodes are configured.")
  add("")
  add("---")
  add("")
  add("## 5. Architectural Topology Diagrams (Mermaid)")
  add("")

  for cat, d in pairs(self.diagrams or {}) do
    add(string.format("### %s", cat))
    add("")
    add("```mermaid")
    add("flowchart TD")
    local s_map = {}
    for _, n in ipairs(d.nodes or {}) do
      local s_id = (n.id or "node"):gsub("[^%w_]", "_")
      s_map[n.id] = s_id
      local lbl = (n.name or n.label or n.id):gsub('"', "'")
      add(string.format('    %s["%s"]', s_id, lbl))
    end
    for _, e in ipairs(d.edges or {}) do
      local u = s_map[e.from]
      local v = s_map[e.to]
      local lbl = (e.label or e.type or "calls"):gsub('"', "'")
      if u and v then
        add(string.format('    %s -->|"%s"| %s', u, lbl, v))
      end
    end
    add("```")
    add("")
  end

  return table.concat(lines, "\n")
end

function VisualizerView:export_onboarding_guide()
  if not self.diagrams or next(self.diagrams) == nil then
    show_toast("No diagrams available to export guide")
    return
  end
  local proj_dir = core.project_dir or "."
  if core.project_directories and #core.project_directories > 0 then
    local p = core.project_directories[1]
    proj_dir = (type(p) == "table" and (p.name or p.path)) or tostring(p)
  end

  local md = self:generate_onboarding_guide_markdown()
  local sep = package.config:sub(1,1)
  local file_path = proj_dir .. sep .. "ARCHITECTURE_ONBOARDING.md"

  local f, err = io.open(file_path, "w")
  if not f then
    show_toast("Failed to write ARCHITECTURE_ONBOARDING.md: " .. tostring(err))
    return
  end
  f:write(md)
  f:close()

  show_toast("Exported ARCHITECTURE_ONBOARDING.md to project root")

  -- Open the file in Lite XL
  pcall(function()
    local doc = core.open_doc(file_path)
    if doc then
      core.root_view:open_doc(doc)
    end
  end)
end

function VisualizerView:export_svg()
  if not self.diagrams or next(self.diagrams) == nil then
    show_toast("No diagrams available to export")
    return
  end
  local proj_dir = core.project_dir or "."
  if core.project_directories and #core.project_directories > 0 then
    local p = core.project_directories[1]
    proj_dir = (type(p) == "table" and (p.name or p.path)) or tostring(p)
  end

  local result, err = SVGExporter.export(self.diagrams, proj_dir)
  if not result then
    show_toast("SVG Export failed: " .. tostring(err))
  else
    local count = 0
    for _, item in ipairs(result) do if item.path then count = count + 1 end end
    local sep = package.config:sub(1,1)
    local vis_dir = proj_dir .. sep .. ".visualizer"
    show_toast(string.format("Exported %d diagram(s) to %s", count, vis_dir))

    -- Automatically open the exported folder in Windows File Explorer
    pcall(function()
      local win_path = vis_dir:gsub('/', '\\')
      process.start({ "explorer.exe", win_path })
    end)
  end
end

function VisualizerView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function VisualizerView:update()
  VisualizerView.super.update(self)
  local sidebar = rawget(_G, "get_sidebar_node") and _G.get_sidebar_node(true)
  local node = core.root_view.root_node:get_node_for_view(self)
  if sidebar and node == sidebar then
    self.target_size = self.target_size or (520 * SCALE)
    local dest = (self.visible ~= false) and self.target_size or 0
    self:move_towards(self.size, "x", dest, nil, "visualizer_view")
  end
  if self.is_analyzing then
    self.spinner_time = self.spinner_time + (1 / (config.fps or 60))
    core.redraw = true
  end
  if self.hovered_node and not self.show_tooltip then
    if system.get_time() - self.hover_timer >= 0.3 then
      self.show_tooltip = true
      core.redraw = true
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Search & Filtering Capability
-- ─────────────────────────────────────────────────────────────────────────────
function VisualizerView:open_search_prompt()
  local old_query = self.search_query or ""
  core.command_view:enter("Search Diagram (service, tech, file, tier)", {
    text = old_query,
    select_text = true,
    submit = function(text, item)
      local q = (item and item.query) or text
      self:set_search_query(q)
      self:focus_current_match()
      core.set_active_view(self)
    end,
    suggest = function(text)
      self:set_search_query(text)
      return self:get_search_suggestions(text)
    end,
    cancel = function(explicit)
      core.set_active_view(self)
    end
  })
end

function VisualizerView:set_search_query(query)
  self.search_query = query or ""
  local q = self.search_query:match("^%s*(.-)%s*$")
  if not q or q == "" then
    self.search_matches   = {}
    self.search_match_idx = 0
    core.redraw = true
    return
  end

  local diag = self:current_diagram()
  local matches = {}
  if diag and diag.nodes then
    local q_lower = q:lower()
    for _, n in ipairs(diag.nodes) do
      local score = 0
      local nid   = (n.id or ""):lower()
      local lbl   = (n.label or ""):lower()
      local tech  = (n.tech or ""):lower()
      local ntype = (n.type or ""):lower()
      local tier  = (n.tier or ""):lower()
      local desc  = (n.desc or ""):lower()
      local f     = (n.file or ""):lower()

      if lbl == q_lower or nid == q_lower then
        score = 100
      elseif lbl:find(q_lower, 1, true) == 1 or nid:find(q_lower, 1, true) == 1 then
        score = 85
      elseif lbl:find(q_lower, 1, true) or nid:find(q_lower, 1, true) then
        score = 70
      elseif tech:find(q_lower, 1, true) then
        score = 55
      elseif ntype:find(q_lower, 1, true) or tier:find(q_lower, 1, true) then
        score = 45
      elseif f:find(q_lower, 1, true) then
        score = 35
      elseif desc:find(q_lower, 1, true) then
        score = 25
      end

      if score > 0 then
        table.insert(matches, { node = n, score = score })
      end
    end
    table.sort(matches, function(a, b) return a.score > b.score end)
  end

  self.search_matches = matches
  if #matches > 0 then
    self.search_match_idx = 1
  else
    self.search_match_idx = 0
    local other = self:search_other_categories(q)
    if other then
      self.status_message = string.format("No matches in current tab (Found %d in %q - press Alt+0)", other.count, other.category_name)
    end
  end
  core.redraw = true
end

function VisualizerView:get_search_suggestions(query)
  local diag = self:current_diagram()
  if not diag or not diag.nodes then return {} end
  local q = (query or ""):lower():match("^%s*(.-)%s*$")
  local suggestions = {}
  local seen = {}

  for _, n in ipairs(diag.nodes) do
    local label = n.label or n.id
    local tech = n.tech and (" [" .. n.tech .. "]") or (n.type and (" [" .. n.type .. "]") or "")
    local disp = label .. tech
    if not seen[disp] then
      if q == "" or disp:lower():find(q, 1, true) or (n.desc and n.desc:lower():find(q, 1, true)) or (n.file and n.file:lower():find(q, 1, true)) then
        table.insert(suggestions, { text = label, info = tech, query = label })
        seen[disp] = true
      end
    end
  end

  for _, n in ipairs(diag.nodes) do
    if n.tech and not seen[n.tech] then
      if q == "" or n.tech:lower():find(q, 1, true) then
        table.insert(suggestions, { text = n.tech, info = " [Technology]", query = n.tech })
        seen[n.tech] = true
      end
    end
  end

  for _, n in ipairs(diag.nodes) do
    if n.tier and not seen[n.tier] then
      if q == "" or n.tier:lower():find(q, 1, true) then
        table.insert(suggestions, { text = n.tier, info = " [Tier / Layer]", query = n.tier })
        seen[n.tier] = true
      end
    end
  end

  return suggestions
end

function VisualizerView:focus_current_match()
  if self.search_matches and #self.search_matches > 0 then
    local idx = self.search_match_idx or 1
    local m = self.search_matches[idx]
    if m and m.node then
      self:center_on_node(m.node)
    end
  end
end

function VisualizerView:center_on_node(node)
  if not node then return end
  local vx, vy, vw, vh = self:get_content_bounds()
  local tb_h   = DiagramRenderer.TOOLBAR_H or 38
  local rail_w = self.sidebar_collapsed and 52 or (self.sidebar_w or 210)
  DiagramRenderer.RAIL_W = rail_w
  local st_h   = DiagramRenderer.STATUS_H or 28
  local insp_w = (self.inspector_open and self.inspector_node) and math.min(320, math.floor(vw * 0.35)) or 0

  local right_rail_w = (not self.right_rail_open) and 60 or (self.right_rail_w or 380)
  DiagramRenderer.RIGHT_RAIL_W = right_rail_w
  local cx = vx + rail_w + (vw - rail_w - right_rail_w) / 2
  local cy = vy + tb_h + (vh - tb_h - st_h) / 2
  local nw = node.w or 180
  local nh = node.h or 60

  self.pan_x = cx - (node.x + nw / 2) * self.scale
  self.pan_y = cy - (node.y + nh / 2) * self.scale
  self.hovered_node = node
  self.show_tooltip = true
  self.hover_timer = system.get_time()
  core.redraw = true
end

function VisualizerView:find_next()
  if not self.search_matches or #self.search_matches == 0 then
    self:open_search_prompt()
    return
  end
  self.search_match_idx = (self.search_match_idx % #self.search_matches) + 1
  local m = self.search_matches[self.search_match_idx]
  if m and m.node then
    self:center_on_node(m.node)
  end
end

function VisualizerView:find_prev()
  if not self.search_matches or #self.search_matches == 0 then
    self:open_search_prompt()
    return
  end
  self.search_match_idx = ((self.search_match_idx - 2) % #self.search_matches) + 1
  local m = self.search_matches[self.search_match_idx]
  if m and m.node then
    self:center_on_node(m.node)
  end
end

function VisualizerView:clear_search()
  self.search_query     = ""
  self.search_matches   = {}
  self.search_match_idx = 0
  self.hovered_node     = nil
  self.show_tooltip     = false
  core.redraw = true
end

function VisualizerView:search_other_categories(query)
  if not query or query == "" or not self.categories then return nil end
  local q = query:lower()
  for i, cat in ipairs(self.categories) do
    if i ~= self.active_category_idx and cat.diagram and cat.diagram.nodes then
      local cnt = 0
      for _, n in ipairs(cat.diagram.nodes) do
        local match = (n.label and n.label:lower():find(q, 1, true)) or
                      (n.id and n.id:lower():find(q, 1, true)) or
                      (n.tech and n.tech:lower():find(q, 1, true))
        if match then cnt = cnt + 1 end
      end
      if cnt > 0 then
        return { category_idx = i, category_name = cat.title or cat.name, count = cnt }
      end
    end
  end
  return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Subsystem Focus Lens, Blast Radius, Story Tours & Inspector
-- ─────────────────────────────────────────────────────────────────────────────
function VisualizerView:get_effective_diagram()
  local raw_diag = self:current_diagram()
  if not raw_diag or not self.focus_node_id then
    return raw_diag
  end

  local fid = self.focus_node_id
  local included_ids = { [fid] = true }
  for _, e in ipairs(raw_diag.edges or {}) do
    if e.from == fid then included_ids[e.to] = true end
    if e.to == fid then included_ids[e.from] = true end
  end

  local filtered_nodes = {}
  for _, n in ipairs(raw_diag.nodes or {}) do
    if included_ids[n.id] then
      table.insert(filtered_nodes, n)
    end
  end

  local filtered_edges = {}
  for _, e in ipairs(raw_diag.edges or {}) do
    if included_ids[e.from] and included_ids[e.to] then
      table.insert(filtered_edges, e)
    end
  end

  return {
    nodes = filtered_nodes,
    edges = filtered_edges,
    title = raw_diag.title or "Focused Subsystem",
    layout_done = true
  }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- AI Architecture Assistant ("Ask AI")
-- ─────────────────────────────────────────────────────────────────────────────
function VisualizerView:open_ai_ask()
  if self.ai_insight then
    core.command_view:enter("AI Insight Active - Ask new question (or type 'clear' to dismiss):", {
      submit = function(text)
        if not text or text:match("^%s*$") then return end
        if text:lower() == "clear" then
          self:clear_ai_insight()
        else
          self:run_ai_ask_query(text)
        end
      end
    })
  else
    core.command_view:enter("Ask Architecture AI (e.g. 'How does order flow?', 'Where is DB used?'):", {
      submit = function(text)
        if not text or text:match("^%s*$") then return end
        self:run_ai_ask_query(text)
      end
    })
  end
end

function VisualizerView:run_ai_ask_query(query)
  local diag = self:current_diagram()
  if not diag or not diag.nodes or #diag.nodes == 0 then
    show_toast("No components in active diagram to analyze.")
    return
  end

  local cat_name = self.categories[self.active_category_idx] or "General Architecture"
  self.ai_insight_loading = true
  self.ai_insight_query   = query
  self.status_message     = "Querying Architecture AI..."
  core.redraw = true
  show_toast("Querying Architecture AI...")

  local opts = {
    provider = self.provider,
    model    = self.model,
  }

  AIAnalyzer.ask_architecture_ai(
    query,
    diag,
    cat_name,
    opts,
    function(result)
      self.ai_insight_loading = false
      self.status_message     = nil
      self.ai_insight = {
        query    = query,
        text     = result.answer,
        nodes    = result.involved_nodes_map,
        provider = result.provider
      }
      self.ai_insight_scroll_y = 0

      -- Focus / center on first matching node if any
      if result.involved_nodes_map and next(result.involved_nodes_map) then
        local first_id = next(result.involved_nodes_map)
        for _, n in ipairs(diag.nodes) do
          if n.id == first_id then
            self:center_on_node(n)
            break
          end
        end
      end

      core.redraw = true
      show_toast("AI Architecture Insight ready!")
    end,
    function(err)
      self.ai_insight_loading = false
      self.status_message     = nil
      core.redraw = true
      show_toast("AI Insight Error: " .. tostring(err))
    end
  )
end

function VisualizerView:clear_ai_insight()
  self.ai_insight          = nil
  self.ai_insight_loading  = false
  self.ai_insight_query    = nil
  self.ai_insight_enlarged = false
  self.ai_insight_scroll_y = 0
  core.redraw = true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Architecture Health Doctor / Anti-Pattern Audit
-- ─────────────────────────────────────────────────────────────────────────────
-- ─────────────────────────────────────────────────────────────────────────────
-- Interactive Graph AI: Flow Path Tracing
-- ─────────────────────────────────────────────────────────────────────────────
-- ─────────────────────────────────────────────────────────────────────────────
-- Interactive Adjustable Node Dimensions & Sizing
-- ─────────────────────────────────────────────────────────────────────────────
function VisualizerView:adjust_dimension(dim, delta)
  local cur_w    = self.custom_node_w or 230
  local cur_h    = self.custom_node_h or 84
  local cur_hgap = self.custom_h_gap or 70
  local cur_vgap = self.custom_v_gap or 55

  if dim == "w" then
    cur_w = math.max(150, math.min(340, cur_w + delta))
  elseif dim == "h" then
    cur_h = math.max(48, math.min(130, cur_h + delta))
  elseif dim == "hgap" then
    cur_hgap = math.max(30, math.min(150, cur_hgap + delta))
  elseif dim == "vgap" then
    cur_vgap = math.max(25, math.min(120, cur_vgap + delta))
  end

  self:set_custom_dimensions(cur_w, cur_h, cur_hgap, cur_vgap)
end

function VisualizerView:apply_dimension_preset(preset_name)
  if preset_name == "compact" then
    self:set_custom_dimensions(180, 68, 50, 40)
  elseif preset_name == "wide" then
    self:set_custom_dimensions(280, 92, 85, 65)
  elseif preset_name == "spacious" then
    self:set_custom_dimensions(320, 105, 100, 75)
  else
    self:set_custom_dimensions(230, 84, 70, 55)
  end
end

function VisualizerView:set_custom_dimensions(w, h, hgap, vgap)
  self.custom_node_w = w
  self.custom_node_h = h
  self.custom_h_gap  = hgap
  self.custom_v_gap  = vgap

  LayoutEngine.set_dimensions(w, h, hgap, vgap)
  DiagramRenderer.set_dimensions(w, h)
  self:run_layout()
  self:fit_to_view()
  core.redraw = true
  show_toast(string.format("Node Dimensions: %dx%d px (Gap: %dx%d px)", w, h, hgap, vgap))
end

function VisualizerView:start_flow_trace(source_id)
  local diag = self:current_diagram()
  if not diag or not diag.nodes then return end

  local candidates = {}
  for _, n in ipairs(diag.nodes) do
    if n.id ~= source_id then
      table.insert(candidates, string.format("%s (%s)", n.label or n.id, n.id))
    end
  end
  if #candidates == 0 then
    show_toast("No other components to trace flow to")
    return
  end

  core.command_view:enter(string.format("Trace Flow from [%s] to:", source_id), {
    submit = function(text)
      if not text or text:match("^%s*$") then return end
      local target_id = text:match("%((.+)%)") or text:match("^%s*(%S+)")
      if not target_id then return end

      local res = AIAnalyzer.find_any_path(diag.edges, source_id, target_id)
      if not res or #res.path == 0 then
        show_toast(string.format("No path found between %s and %s", source_id, target_id))
        return
      end

      local path_set = {}
      local hop_indices = {}
      for idx, nid in ipairs(res.path) do
        path_set[nid] = true
        hop_indices[nid] = idx
      end

      local edge_set = {}
      for _, ed in ipairs(res.edges) do
        edge_set[(ed.from or "") .. "->" .. (ed.to or "")] = true
      end

      self.flow_trace = {
        source = source_id,
        target = target_id,
        path = res.path,
        path_set = path_set,
        hop_indices = hop_indices,
        edges = res.edges,
        edge_set = edge_set,
        hops = res.hops,
        is_direct = res.is_direct
      }
      self.focus_node_id = nil
      self.impact_data   = nil
      self.story_mode    = false
      self:fit_to_view()
      core.redraw = true
      show_toast(string.format("Flow Trace: %d hops found (%s -> %s)", res.hops, source_id, target_id))
    end,
    suggest = function(text)
      return common.fuzzy_match(candidates, text)
    end
  })
end

function VisualizerView:clear_flow_trace()
  self.flow_trace = nil
  self:fit_to_view()
  core.redraw = true
end

function VisualizerView:compute_architecture_audit(diag)
  if not diag or not diag.nodes then
    return { score = 100, grade = "A", findings = {}, counts = { critical = 0, warning = 0, info = 0 } }
  end

  local node_map = {}
  for _, n in ipairs(diag.nodes) do node_map[n.id] = n end
  local in_edges = {}
  local out_edges = {}
  for _, e in ipairs(diag.edges or {}) do
    in_edges[e.to] = in_edges[e.to] or {}
    table.insert(in_edges[e.to], e)
    out_edges[e.from] = out_edges[e.from] or {}
    table.insert(out_edges[e.from], e)
  end

  local score = 100
  local findings = {}

  -- 1. Circular coupling detection (Exact DFS cycle extraction)
  local visited = {}
  local rec_stack = {}
  local path = {}
  local cycles = {}
  local seen_cycle_keys = {}

  local function dfs(curr)
    visited[curr] = true
    rec_stack[curr] = true
    table.insert(path, curr)

    for _, e in ipairs(out_edges[curr] or {}) do
      local nxt = e.to
      if not visited[nxt] then
        dfs(nxt)
      elseif rec_stack[nxt] then
        local start_idx = 1
        for i, nid in ipairs(path) do
          if nid == nxt then
            start_idx = i
            break
          end
        end
        local cycle_nodes = {}
        local key_parts = {}
        for i = start_idx, #path do
          table.insert(cycle_nodes, path[i])
          table.insert(key_parts, path[i])
        end
        table.sort(key_parts)
        local cycle_key = table.concat(key_parts, ":")

        if not seen_cycle_keys[cycle_key] then
          seen_cycle_keys[cycle_key] = true
          local path_nodes_display = {}
          for _, nid in ipairs(cycle_nodes) do
            table.insert(path_nodes_display, nid)
          end
          table.insert(path_nodes_display, nxt)
          local cycle_path_str = table.concat(path_nodes_display, " -> ")

          local c_edges = {}
          for i = 1, #cycle_nodes do
            local u = cycle_nodes[i]
            local v = (i == #cycle_nodes) and cycle_nodes[1] or cycle_nodes[i + 1]
            table.insert(c_edges, { from = u, to = v })
          end

          table.insert(cycles, {
            nodes = cycle_nodes,
            path_str = cycle_path_str,
            edges = c_edges
          })
        end
      end
    end

    rec_stack[curr] = false
    table.remove(path)
  end

  for nid, _ in pairs(node_map) do
    if not visited[nid] then dfs(nid) end
  end

  for _, c in ipairs(cycles) do
    score = score - 15
    table.insert(findings, {
      type = "critical",
      title = string.format("Circular Coupling: Cycle [%s]", c.path_str),
      nodes = c.nodes,
      cycle_edges = c.edges,
      desc = string.format("Components [%s] form a direct circular dependency loop (%s). Circular dependencies violate directed acyclic graph (DAG) structure, causing tight coupling, fragile deployment order, and initialization race conditions.", table.concat(c.nodes, ", "), c.path_str),
      impact = "High ripple effect on refactoring, fragile unit testing, and vulnerability to runtime initialization order issues or deadlock.",
      recommendation = "Apply Dependency Inversion Principle (DIP), introduce an asynchronous message broker, or extract shared models into a common leaf library."
    })
  end

  -- 2. Layer Inversion: Ingress / Presentation calling Persistence / Database / Cache directly
  local seen_inversions = {}
  for _, e in ipairs(diag.edges or {}) do
    local s = node_map[e.from]
    local d = node_map[e.to]
    if s and d then
      local is_upper = (s.tier == "ingress" or s.tier == "presentation" or s.type == "client" or s.type == "frontend" or s.type == "gateway")
      local is_lower = (d.tier == "persistence" or d.tier == "data" or d.type == "database" or d.type == "cache" or d.type == "storage")
      if is_upper and is_lower then
        local inv_key = s.id .. "->" .. d.id
        if not seen_inversions[inv_key] then
          seen_inversions[inv_key] = true
          score = score - 10
          table.insert(findings, {
            type = "critical",
            title = string.format("Layer Inversion: %s bypasses service to call %s", s.id, d.id),
            nodes = { s.id, d.id },
            offending_edge = { from = s.id, to = d.id },
            desc = string.format("The edge/ingress component '%s' directly accesses persistent storage/cache '%s', bypassing domain service and business rule boundaries.", s.id, d.id),
            impact = "Database schema and storage protocol concerns leak into the presentation/gateway tier, bypassing authorization and validation invariants.",
            recommendation = "Route requests through an application service or domain command handler rather than querying the database directly."
          })
        end
      end
    end
  end

  -- 3. God Component / Monolithic Bottleneck (High Fan-In >= 3 AND High Fan-Out >= 3, total >= 7)
  for _, n in ipairs(diag.nodes) do
    local inc = in_edges[n.id] and #in_edges[n.id] or 0
    local outc = out_edges[n.id] and #out_edges[n.id] or 0
    local total_deg = inc + outc
    local is_gw = (n.type == "gateway" or n.type == "ingress" or n.tier == "ingress")
    if inc >= 3 and outc >= 3 and total_deg >= 7 and not is_gw then
      score = score - 8
      table.insert(findings, {
        type = "warning",
        title = string.format("God Component: %s has %d callers and %d dependencies", n.label or n.id, inc, outc),
        nodes = { n.id },
        desc = string.format("Component '%s' has %d incoming callers and %d outgoing dependencies (%d total). It acts as an overly centralized orchestrator or monolithic hub.", n.label or n.id, inc, outc, total_deg),
        impact = "Extreme blast radius on changes, testing fragility, and violation of the Single Responsibility Principle.",
        recommendation = "Decompose into smaller cohesive services following Domain-Driven Design (DDD) boundaries or introduce an event-driven pub/sub architecture."
      })
    end
  end

  -- 4. High Fan-In SPOF (>= 4 callers)
  for nid, callers in pairs(in_edges) do
    local n = node_map[nid]
    local inc = #callers
    local outc = out_edges[nid] and #out_edges[nid] or 0
    local already_god = (inc >= 3 and outc >= 3 and (inc + outc) >= 7 and n and n.type ~= "gateway")
    if inc >= 4 and not already_god then
      score = score - 5
      table.insert(findings, {
        type = "info",
        title = string.format("High Fan-In SPOF: %s has %d incoming dependencies", nid, inc),
        nodes = { nid },
        desc = string.format("Component '%s' is depended upon by %d distinct incoming callers, making it an architectural bottleneck and single point of failure.", nid, inc),
        impact = "Any downtime, breaking schema change, or latency spike in this component cascades directly to all upstream systems.",
        recommendation = "Introduce circuit breakers (Hystrix pattern), horizontal load balancing, and read caching to shield this component."
      })
    end
  end

  -- 5. Sinkhole / Dead-End Service (Incoming >= 1, Outgoing == 0, not persistence/database/cache/queue/external)
  for _, n in ipairs(diag.nodes) do
    local inc = in_edges[n.id] and #in_edges[n.id] or 0
    local outc = out_edges[n.id] and #out_edges[n.id] or 0
    local is_data_sink = (n.tier == "persistence" or n.tier == "data" or n.type == "database" or n.type == "cache" or n.type == "storage" or n.type == "queue" or n.external)
    if inc >= 1 and outc == 0 and not is_data_sink then
      score = score - 5
      table.insert(findings, {
        type = "warning",
        title = string.format("Sinkhole Service: %s accepts traffic but has 0 outgoing dependencies", n.label or n.id),
        nodes = { n.id },
        desc = string.format("Service '%s' has %d incoming caller(s) but zero outgoing dependencies, persistent storage, or event emissions.", n.label or n.id, inc),
        impact = "Potential stub implementation, incomplete architecture model, or black-hole service that silently drops state without persistence.",
        recommendation = "Confirm whether this service should persist state to a database or emit events to downstream queues."
      })
    end
  end

  -- 6. Orphan / Disconnected Services (0 in, 0 out)
  for _, n in ipairs(diag.nodes) do
    local inc = in_edges[n.id] and #in_edges[n.id] or 0
    local outc = out_edges[n.id] and #out_edges[n.id] or 0
    if inc == 0 and outc == 0 and not n.external then
      score = score - 5
      table.insert(findings, {
        type = "warning",
        title = string.format("Orphan Service: %s has 0 callers and 0 dependencies", n.label or n.id),
        nodes = { n.id },
        desc = string.format("Component '%s' has 0 callers and 0 dependencies in the active architecture graph.", n.label or n.id),
        impact = "Potential dead code, abandoned microservice, or missing integration wiring in project architecture definitions.",
        recommendation = "Verify if this component is obsolete and eligible for safe deletion, or document its missing inputs and outputs."
      })
    end
  end

  -- 7. Deep Synchronous Call Chain (Simple path >= 4 hops)
  local max_chain = {}
  local function find_longest_chain(curr, curr_chain, chain_visited)
    if #curr_chain > #max_chain then
      max_chain = {}
      for _, v in ipairs(curr_chain) do table.insert(max_chain, v) end
    end
    if #curr_chain >= 5 then return end
    for _, e in ipairs(out_edges[curr] or {}) do
      local nxt = e.to
      if not chain_visited[nxt] then
        chain_visited[nxt] = true
        table.insert(curr_chain, nxt)
        find_longest_chain(nxt, curr_chain, chain_visited)
        table.remove(curr_chain)
        chain_visited[nxt] = false
      end
    end
  end

  for nid, _ in pairs(node_map) do
    find_longest_chain(nid, { nid }, { [nid] = true })
  end

  if #max_chain >= 4 then
    score = score - 5
    local chain_str = table.concat(max_chain, " -> ")
    local chain_edges = {}
    for i = 1, #max_chain - 1 do
      table.insert(chain_edges, { from = max_chain[i], to = max_chain[i + 1] })
    end
    table.insert(findings, {
      type = "info",
      title = string.format("Deep Call Chain: %d synchronous hops detected", #max_chain - 1),
      nodes = max_chain,
      cycle_edges = chain_edges,
      desc = string.format("Detected a linear synchronous execution chain spanning %d hops (%s).", #max_chain - 1, chain_str),
      impact = "Cascading latency amplification, high vulnerability to timeout storms, and tight coupling across service tiers.",
      recommendation = "Decouple long synchronous call chains using asynchronous message queues, saga orchestrators, or caching."
    })
  end

  local final_score = math.max(0, math.min(100, score))
  local grade = "A"
  if final_score < 40 then grade = "F"
  elseif final_score < 60 then grade = "D"
  elseif final_score < 75 then grade = "C"
  elseif final_score < 90 then grade = "B" end

  local counts = { critical = 0, warning = 0, info = 0 }
  for _, f in ipairs(findings) do
    if f.type == "critical" then counts.critical = counts.critical + 1
    elseif f.type == "warning" then counts.warning = counts.warning + 1
    else counts.info = counts.info + 1 end
  end

  for _, f in ipairs(findings) do
    if DiagramRenderer.clean_display_text then
      f.title = DiagramRenderer.clean_display_text(f.title)
      f.desc = DiagramRenderer.clean_display_text(f.desc)
      f.impact = DiagramRenderer.clean_display_text(f.impact)
      f.recommendation = DiagramRenderer.clean_display_text(f.recommendation)
    end
  end

  return {
    score = final_score,
    grade = grade,
    counts = counts,
    findings = findings
  }
end

function VisualizerView:run_architecture_audit(force_run)
  if self.audit_open and not force_run then
    self.audit_open = false
    core.redraw = true
    return
  end

  local diag = self:current_diagram()
  if not diag or not diag.nodes then return end

  self.audit_data = self:compute_architecture_audit(diag)
  self.audit_open = true
  self.right_rail_tab = "audit"
  core.redraw = true
  show_toast(string.format("Architecture Audit: Grade %s (%d/100) - %d issues", self.audit_data.grade, self.audit_data.score, #self.audit_data.findings))
end

function VisualizerView:run_ai_architecture_audit()
  local diag = self:current_diagram()
  if not diag or not diag.nodes then return end

  if not self.audit_data then
    self.audit_data = self:compute_architecture_audit(diag)
  end

  self.ai_audit_loading = true
  core.redraw = true
  show_toast("Querying Architecture AI Doctor...")

  local cat_name = self.categories and self.active_category and self.categories[self.active_category] and self.categories[self.active_category].name or "System Architecture"
  local static_findings = (self.audit_data and self.audit_data.findings) or {}

  AIAnalyzer.run_ai_architecture_audit(diag, cat_name, static_findings, {
    provider = self.provider,
    model = self.model
  }, function(res)
    self.ai_audit_loading = false
    if res and res.findings then
      if DiagramRenderer.clean_display_text then
        for _, f in ipairs(res.findings) do
          f.title = DiagramRenderer.clean_display_text(f.title)
          f.desc = DiagramRenderer.clean_display_text(f.desc)
          f.impact = DiagramRenderer.clean_display_text(f.impact)
          f.recommendation = DiagramRenderer.clean_display_text(f.recommendation)
        end
        if res.ai_summary then
          res.ai_summary = DiagramRenderer.clean_display_text(res.ai_summary)
        end
      end
      self.audit_data.findings = res.findings
      self.audit_data.ai_summary = res.ai_summary
      self.audit_data.provider = res.provider
      local new_score = 100
      for _, f in ipairs(res.findings) do
        if f.type == "critical" then new_score = new_score - 15
        elseif f.type == "warning" then new_score = new_score - 8
        else new_score = new_score - 4 end
      end
      self.audit_data.score = math.max(0, math.min(100, new_score))
      local g = "A"
      if self.audit_data.score < 40 then g = "F"
      elseif self.audit_data.score < 60 then g = "D"
      elseif self.audit_data.score < 75 then g = "C"
      elseif self.audit_data.score < 90 then g = "B" end
      self.audit_data.grade = g
      show_toast(string.format("AI Architecture Audit complete: Grade %s (%d/100)", g, self.audit_data.score))
    else
      show_toast("AI Architecture Audit returned no new insights.")
    end
    core.redraw = true
  end, function(err)
    self.ai_audit_loading = false
    show_toast("AI Architecture Audit error: " .. tostring(err))
    core.redraw = true
  end)
end

function VisualizerView:select_audit_finding(finding)
  if not finding then return end
  self.active_audit_finding = finding
  if finding.nodes and #finding.nodes > 0 then
    local target_id = finding.nodes[1]
    local diag = self:current_diagram()
    if diag and diag.nodes then
      for _, n in ipairs(diag.nodes) do
        if n.id == target_id then
          self:center_on_node(n)
          break
        end
      end
    end
  end
  core.redraw = true
end

function VisualizerView:clear_active_audit_finding()
  if self.active_audit_finding then
    self.active_audit_finding = nil
    core.redraw = true
  end
end

function VisualizerView:enlarge_audit_finding(finding)
  if not finding then return end
  self.audit_finding_enlarged = finding
  self.active_audit_finding = finding
  self.audit_enlarged_scroll_y = 0
  core.redraw = true
end

function VisualizerView:close_enlarged_audit()
  self.audit_finding_enlarged = nil
  self.audit_enlarged_scroll_y = 0
  self.audit_enlarged_rects = {}
  core.redraw = true
end

function VisualizerView:copy_audit_finding(finding)
  if not finding then return end
  local desc, impact, rec = DiagramRenderer.get_finding_details(finding)
  local nodes_str = (finding.nodes and #finding.nodes > 0) and table.concat(finding.nodes, ", ") or "None"
  local text = string.format([[# Architectural Audit Finding
**Type:** %s
**Title:** %s
**Components:** %s

## Description
%s

## Architectural Impact
%s

## Recommended Remediation
%s
]], (finding.type or "info"):upper(), finding.title or "N/A", nodes_str, desc, impact, rec)

  if system and system.set_clipboard then
    system.set_clipboard(text)
    show_toast("Copied Audit Finding details to clipboard!")
  end
end

function VisualizerView:toggle_inspector(node)
  if node then
    self.inspector_node = node
    self.right_rail_open = true
    self.right_rail_tab  = "inspector"
  else
    if self.right_rail_open and self.right_rail_tab == "inspector" then
      self.right_rail_open = false
    else
      self.right_rail_open = true
      self.right_rail_tab  = "inspector"
    end
  end
  self:fit_to_view()
  core.redraw = true
end

function VisualizerView:toggle_focus_lens(node_id)
  if self.focus_node_id == node_id then
    self.focus_node_id = nil
  else
    self.focus_node_id = node_id
    self.hovered_node  = nil
  end
  self:fit_to_view()
  core.redraw = true
end

function VisualizerView:exit_focus_lens()
  self.focus_node_id = nil
  self:fit_to_view()
  core.redraw = true
end

function VisualizerView:compute_blast_radius(node_id)
  local diag = self:current_diagram()
  if not diag or not diag.edges then return nil end

  local up_adj = {}
  local down_adj = {}
  for _, e in ipairs(diag.edges) do
    if not up_adj[e.to] then up_adj[e.to] = {} end
    table.insert(up_adj[e.to], e.from)

    if not down_adj[e.from] then down_adj[e.from] = {} end
    table.insert(down_adj[e.from], e.to)
  end

  -- BFS Upstream
  local upstream = {}
  local q = { node_id }
  local visited = { [node_id] = true }
  local depth = { [node_id] = 0 }
  while #q > 0 do
    local curr = table.remove(q, 1)
    for _, caller in ipairs(up_adj[curr] or {}) do
      if not visited[caller] then
        visited[caller] = true
        depth[caller] = depth[curr] + 1
        upstream[caller] = depth[caller]
        table.insert(q, caller)
      end
    end
  end

  -- BFS Downstream
  local downstream = {}
  q = { node_id }
  visited = { [node_id] = true }
  depth = { [node_id] = 0 }
  while #q > 0 do
    local curr = table.remove(q, 1)
    for _, dep in ipairs(down_adj[curr] or {}) do
      if not visited[dep] then
        visited[dep] = true
        depth[dep] = depth[curr] + 1
        downstream[dep] = depth[dep]
        table.insert(q, dep)
      end
    end
  end

  local up_cnt = 0; for _ in pairs(upstream) do up_cnt = up_cnt + 1 end
  local down_cnt = 0; for _ in pairs(downstream) do down_cnt = down_cnt + 1 end
  local total = up_cnt + down_cnt
  local risk = (total >= 5) and "HIGH" or ((total >= 2) and "MEDIUM" or "LOW")

  return {
    target = node_id,
    upstream = upstream,
    downstream = downstream,
    total = total,
    risk = risk,
  }
end

function VisualizerView:toggle_blast_radius(node_id)
  if self.impact_node_id == node_id then
    self:clear_blast_radius()
  else
    self.impact_node_id = node_id
    self.impact_data = self:compute_blast_radius(node_id)
    core.redraw = true
  end
end

function VisualizerView:clear_blast_radius()
  self.impact_node_id = nil
  self.impact_data = nil
  core.redraw = true
end

function VisualizerView:generate_story_tours()
  local diag = self:current_diagram()
  if not diag or not diag.nodes or #diag.nodes < 2 then return {} end

  local nodes = diag.nodes
  local edges = diag.edges or {}
  local tours = {}

  -- Tour 1: Request Ingress & Core Lifecycle
  local in_deg = {}
  for _, n in ipairs(nodes) do in_deg[n.id] = 0 end
  for _, e in ipairs(edges) do in_deg[e.to] = (in_deg[e.to] or 0) + 1 end

  local entrypoints = {}
  for _, n in ipairs(nodes) do
    if in_deg[n.id] == 0 then table.insert(entrypoints, n.id) end
  end
  if #entrypoints == 0 then table.insert(entrypoints, nodes[1].id) end

  local visited = {}
  local path = {}
  local curr = entrypoints[1]
  while curr and not visited[curr] do
    visited[curr] = true
    table.insert(path, curr)
    local next_id = nil
    for _, e in ipairs(edges) do
      if e.from == curr and not visited[e.to] then
        next_id = e.to
        break
      end
    end
    curr = next_id
  end

  local node_map = {}
  for _, n in ipairs(nodes) do node_map[n.id] = n end

  local steps = {}
  for i, nid in ipairs(path) do
    local n = node_map[nid] or {}
    table.insert(steps, {
      node_id = nid,
      title = string.format("Step %d: %s", i, n.label or nid),
      desc = n.desc or string.format("Request flows into %s at the %s tier.", n.label or nid, n.tier or "core"),
    })
  end

  if #steps >= 2 then
    table.insert(tours, { name = "Request Ingress & Flow", steps = steps })
  end

  return tours
end

function VisualizerView:start_story_mode(tour_idx)
  self.story_tours = self:generate_story_tours()
  if #self.story_tours == 0 then
    core.log("No story tours available for this category.")
    return
  end
  self.story_mode = true
  self.story_tour_idx = tour_idx or 1
  self.story_step_idx = 1
  self.right_rail_open = true
  self.right_rail_tab = "tour" 
  local tour = self.story_tours[self.story_tour_idx]
  if tour and tour.steps[1] then
    local diag = self:current_diagram()
    if diag and diag.nodes then
      for _, n in ipairs(diag.nodes) do
        if n.id == tour.steps[1].node_id then
          self:center_on_node(n)
          self.inspector_node = n
          self.inspector_open = true
          break
        end
      end
    end
  end
  core.redraw = true
end

function VisualizerView:story_next()
  if not self.story_mode or not self.story_tours or #self.story_tours == 0 then return end
  local tour = self.story_tours[self.story_tour_idx]
  if not tour or #tour.steps == 0 then return end

  self.story_step_idx = (self.story_step_idx % #tour.steps) + 1
  local step = tour.steps[self.story_step_idx]
  local diag = self:current_diagram()
  if diag and diag.nodes and step then
    for _, n in ipairs(diag.nodes) do
      if n.id == step.node_id then
        self:center_on_node(n)
        self.inspector_node = n
        break
      end
    end
  end
  core.redraw = true
end

function VisualizerView:story_prev()
  if not self.story_mode or not self.story_tours or #self.story_tours == 0 then return end
  local tour = self.story_tours[self.story_tour_idx]
  if not tour or #tour.steps == 0 then return end

  self.story_step_idx = ((self.story_step_idx - 2) % #tour.steps) + 1
  local step = tour.steps[self.story_step_idx]
  local diag = self:current_diagram()
  if diag and diag.nodes and step then
    for _, n in ipairs(diag.nodes) do
      if n.id == step.node_id then
        self:center_on_node(n)
        self.inspector_node = n
        break
      end
    end
  end
  core.redraw = true
end

function VisualizerView:exit_story_mode()
  self.story_mode = false
  core.redraw = true
end

function VisualizerView:toggle_story_mode(tour_idx)
  if self.story_mode then
    self:exit_story_mode()
  else
    self:start_story_mode(tour_idx)
  end
end

function VisualizerView:draw()
  self:draw_background(style.background or { 24, 24, 28, 255 })
  local x, y, w, h = self:get_content_bounds()
  local tb_h   = DiagramRenderer.TOOLBAR_H or 36
  local st_h   = DiagramRenderer.STATUS_H or 28

  local is_sidebar_mode = (w < 760 * SCALE)
  local is_compact      = (w < 580 * SCALE)
  local is_ultra        = (w < 420 * SCALE)

  -- Responsive Left Rail width
  local rail_w
  if self.sidebar_collapsed then
    rail_w = 44 * SCALE
  elseif is_sidebar_mode then
    rail_w = math.min(180 * SCALE, math.floor(w * 0.4))
  else
    rail_w = self.sidebar_w or (200 * SCALE)
  end
  DiagramRenderer.RAIL_W = rail_w

  -- Responsive Right Strip width
  local strip_w = (is_sidebar_mode and 44 or 54) * SCALE

  -- Determine right rail geometry
  local right_rail_w
  local right_rail_x
  if is_sidebar_mode then
    if self.right_rail_open then
      local panel_w = math.min(w - 50 * SCALE, 320 * SCALE)
      right_rail_w = strip_w + panel_w
      right_rail_x = x + w - right_rail_w
    else
      right_rail_w = strip_w
      right_rail_x = x + w - strip_w
    end
  else
    right_rail_w = (not self.right_rail_open) and strip_w or math.min(self.right_rail_w or (360 * SCALE), math.floor(w * 0.35))
    right_rail_x = x + w - right_rail_w
  end
  DiagramRenderer.RIGHT_RAIL_W = right_rail_w

  -- Canvas bounds: in sidebar mode, canvas is between rail_w and strip_w!
  local cx = x + rail_w
  local cy = y + tb_h
  local cw = math.max(w - rail_w - strip_w, 1)
  local ch = math.max(h - tb_h - st_h, 1)
  if not is_sidebar_mode and self.right_rail_open then
    cw = math.max(w - rail_w - right_rail_w, 1)
  end

  local diag = self:get_effective_diagram()
  local node_cnt = (diag and diag.nodes) and #diag.nodes or 0
  local edge_cnt = (diag and diag.edges) and #diag.edges or 0

  -- Auto-fit once on first render with valid dimensions
  if not self.has_fitted and w > 200 and h > 200 then
    self:fit_to_view()
    self.has_fitted = true
  end

  -- 1. Render Diagram Canvas
  if self.is_analyzing then
    local pinfo = AIAnalyzer.PROVIDERS[self.provider]
    DiagramRenderer.draw_spinner(self, cx + cw / 2, cy + ch / 2 - 20, self.spinner_time, pinfo and pinfo.name or self.provider)
    if self.status_message then
      local font = style.font
      local tw = font:get_width(self.status_message)
      renderer.draw_text(
        font, self.status_message,
        math.floor(cx + (cw - tw) / 2),
        math.floor(cy + ch / 2 + 35),
        { 160, 180, 220, 255 }
      )
    end
  elseif self.analysis_error then
    DiagramRenderer.draw_error(self, self.analysis_error, cx + cw / 2, cy + ch / 2)
  elseif #self.categories == 0 then
    DiagramRenderer.draw_empty(self, cx + cw / 2, cy + ch / 2, "No diagrams generated yet")
  else
    if diag and diag.nodes and #diag.nodes > 0 then
      renderer.set_clip_rect(cx, cy, cw, ch)
      DiagramRenderer.draw(
        self, diag.nodes, diag.edges or {},
        self.pan_x, self.pan_y, self.scale,
        self.hovered_node
      )
      renderer.set_clip_rect(x, y, w, h)
    else
      DiagramRenderer.draw_empty(self, cx + cw / 2, cy + ch / 2, "Category is empty")
    end
  end

  -- 2. Left Activity Rail
  self.rail_hit_rects = DiagramRenderer.draw_left_rail(
    self, self.categories, self.active_category_idx, x, y + tb_h, rail_w, h - tb_h - st_h, self.mouse_x, self.mouse_y
  )

  -- 3. Right Activity Rail & Drawer
  if is_sidebar_mode and self.right_rail_open then
    -- Semi-transparent canvas scrim to focus on overlay drawer
    draw_rect(x, y + tb_h, right_rail_x - x, h - tb_h - st_h, { 0, 0, 0, 110 })
  end

  self.right_rail_hits = DiagramRenderer.draw_right_rail(
    self, right_rail_x, y + tb_h, right_rail_w, h - tb_h - st_h, self.mouse_x, self.mouse_y
  )

  -- 4. Draw Component Deep-Dive Inspector Drawer (if open)
  if self.inspector_open and self.inspector_node then
    local insp_w = is_sidebar_mode and math.min(320, w - 50) or math.min(340, math.floor(w * 0.35))
    self.inspector_rects = DiagramRenderer.draw_inspector(
      self, self.inspector_node, diag and diag.edges or {},
      x + w - insp_w, y + tb_h, insp_w, h - tb_h - st_h,
      self.mouse_x, self.mouse_y
    )
  else
    self.inspector_rects = {}
  end

  -- 5. Draw Architecture Audit Drawer (if open)
  if self.audit_open and self.audit_data then
    local audit_w = is_sidebar_mode and math.min(340, w - 50) or math.min(360, math.floor(w * 0.38))
    self.audit_rects = DiagramRenderer.draw_audit_drawer(
      self, self.audit_data,
      x + w - audit_w, y + tb_h, audit_w, h - tb_h - st_h,
      self.mouse_x, self.mouse_y
    )
  else
    self.audit_rects = {}
  end

  -- 6. Draw AI Architecture Insight Banner
  if self.ai_insight or self.ai_insight_loading then
    self.ai_banner_rects = DiagramRenderer.draw_ai_insight_banner(
      self, self.ai_insight or { query = self.ai_insight_query, text = "Analyzing architecture graph..." },
      cx, cy, cw, ch, self.mouse_x, self.mouse_y
    )
  else
    self.ai_banner_rects = {}
  end

  -- 7. Draw Enlarged Architecture Audit Finding Modal
  if self.audit_finding_enlarged then
    self.audit_enlarged_rects = DiagramRenderer.draw_enlarged_audit_finding_card(
      self, self.audit_finding_enlarged, cx, cy, cw, ch, self.mouse_x, self.mouse_y
    )
  else
    self.audit_enlarged_rects = {}
  end

  -- 8. Draw Toolbar (drawn on top so it always stays accessible and never obscured)
  self.toolbar_rects = DiagramRenderer.draw_toolbar(self, x, y, w, self.provider, self.model, node_cnt, edge_cnt, self.scale, self.mouse_x, self.mouse_y)

  if self.show_tooltip and self.hovered_node and not self.inspector_open then
    DiagramRenderer.draw_tooltip(self, self.hovered_node, diag and diag.edges or {}, self.mouse_x, self.mouse_y)
  end

  DiagramRenderer.draw_status_bar(self, self.hovered_node, diag and diag.edges or {}, x, y + h - st_h, w)
end

local function point_in_rect(px, py, rect)
  if not rect or not rect.x then return false end
  return px >= rect.x and px <= rect.x + rect.w and
         py >= rect.y and py <= rect.y + rect.h
end

function VisualizerView:on_mouse_pressed(button, px, py, clicks)
  if button ~= "left" then return end

  -- 0a. Interactive Exploration Hero Click Handling (Unmapped / Ready State)
  if self.hero_rects and (not self.diagrams or #self.categories == 0) then
    if self.hero_rects.explore_btn and point_in_rect(px, py, self.hero_rects.explore_btn) then
      self:start_analysis()
      return true
    end
    if self.hero_rects.provider_pill and point_in_rect(px, py, self.hero_rects.provider_pill) then
      self:select_provider_dialog()
      return true
    end
  end

  -- 0b. Enlarged Architecture Audit Finding Modal Click Interception
  if self.audit_finding_enlarged and self.audit_enlarged_rects and self.audit_enlarged_rects.is_enlarged then
    local r = self.audit_enlarged_rects
    -- 1. Close / Dismiss button (Esc or [X])
    if r.dismiss_rect and point_in_rect(px, py, r.dismiss_rect) then
      self:close_enlarged_audit()
      return true
    end
    -- 2. Minimize button (header or footer)
    if (r.minimize_rect and point_in_rect(px, py, r.minimize_rect)) or
       (r.footer_minimize_rect and point_in_rect(px, py, r.footer_minimize_rect)) then
      self:close_enlarged_audit()
      return true
    end
    -- 3. Copy button (header or footer)
    if (r.copy_rect and point_in_rect(px, py, r.copy_rect)) or
       (r.footer_copy_rect and point_in_rect(px, py, r.footer_copy_rect)) then
      self:copy_audit_finding(self.audit_finding_enlarged)
      return true
    end
    -- 4. Component pills
    for _, pill in ipairs(r.node_pills or {}) do
      if point_in_rect(px, py, pill) then
        local diag = self:current_diagram()
        if diag and diag.nodes then
          for _, n in ipairs(diag.nodes) do
            if n.id == pill.id then
              self:center_on_node(n)
              show_toast("Focused component: " .. (n.label or n.id))
              break
            end
          end
        end
        return true
      end
    end
    -- 5. Click inside card bounds (consume click so it doesn't pass through)
    if r.card_bounds and point_in_rect(px, py, r.card_bounds) then
      return true
    end
    -- 6. Click on backdrop outside card (minimizes enlarged card)
    if r.backdrop_rect and point_in_rect(px, py, r.backdrop_rect) then
      self:close_enlarged_audit()
      return true
    end
    return true
  end

  -- Right Activity Rail (Secondary Sidebar) Click Handling
  local tb_h   = DiagramRenderer.TOOLBAR_H or 36
  local st_h   = DiagramRenderer.STATUS_H or 28
  local is_sidebar_mode = (self.size.x < 760 * SCALE)
  local strip_w = (is_sidebar_mode and 44 or 54) * SCALE
  local right_rail_w
  local rx2
  if is_sidebar_mode then
    if self.right_rail_open then
      local panel_w = math.min(self.size.x - 50 * SCALE, 320 * SCALE)
      right_rail_w = strip_w + panel_w
      rx2 = self.position.x + self.size.x - right_rail_w
      -- If clicked on dimmed canvas backdrop outside overlay drawer, close the drawer!
      if px >= self.position.x and px < rx2 and py >= self.position.y + tb_h and py <= self.position.y + self.size.y - st_h then
        self.right_rail_open = false
        core.redraw = true
        return true
      end
    else
      right_rail_w = strip_w
      rx2 = self.position.x + self.size.x - strip_w
    end
  else
    right_rail_w = (not self.right_rail_open) and strip_w or math.min(self.right_rail_w or (360 * SCALE), math.floor(self.size.x * 0.35))
    rx2 = self.position.x + self.size.x - right_rail_w
  end
  local ry2 = self.position.y + tb_h
  local rw2 = right_rail_w
  local rh2 = self.size.y - tb_h - st_h

  if px >= rx2 and px <= rx2 + rw2 and py >= ry2 and py <= ry2 + rh2 then
    local hits = self.right_rail_hits or {}

    -- 1. Check Tab Icon Strip
    if hits.tab_icons then
      for tab_id, icon_box in pairs(hits.tab_icons) do
        if point_in_rect(px, py, icon_box) then
          if self.right_rail_open and self.right_rail_tab == tab_id then
            self.right_rail_open = false
          else
            self.right_rail_open = true
            self.right_rail_tab  = tab_id
            if tab_id == "audit" and not self.audit_data then
              self:run_architecture_audit(true)
            end
          end
          self:fit_to_view()
          core.redraw = true
          return true
        end
      end
    end

    -- 2. Check Header Collapse Toggle
    if hits.toggle_rect and point_in_rect(px, py, hits.toggle_rect) then
      self.right_rail_open = not self.right_rail_open
      self:fit_to_view()
      core.redraw = true
      return true
    end

    -- 3. Check Dimension & Sizing Controls
    if hits.dim_controls and self.right_rail_tab == "dimensions" then
      for act, box in pairs(hits.dim_controls) do
        if point_in_rect(px, py, box) then
          if act == "w_minus" then self:adjust_dimension("w", -15)
          elseif act == "w_plus" then self:adjust_dimension("w", 15)
          elseif act == "h_minus" then self:adjust_dimension("h", -6)
          elseif act == "h_plus" then self:adjust_dimension("h", 6)
          elseif act == "hgap_minus" then self:adjust_dimension("hgap", -10)
          elseif act == "hgap_plus" then self:adjust_dimension("hgap", 10)
          elseif act == "vgap_minus" then self:adjust_dimension("vgap", -10)
          elseif act == "vgap_plus" then self:adjust_dimension("vgap", 10)
          elseif act:find("^preset_") then
            self:apply_dimension_preset(box.preset or act:sub(8))
          elseif act == "reset" then
            self:apply_dimension_preset("standard")
          elseif act == "toggle_suggestions" then
            self:toggle_suggested_nodes()
          end
          return true
        end
      end
    end

    -- 4. Check Inspector Controls
    if hits.insp_controls and self.right_rail_tab == "inspector" then
      local ic = hits.insp_controls
      if ic.focus and point_in_rect(px, py, ic.focus) and self.inspector_node then
        self:toggle_focus_lens(self.inspector_node.id)
        return true
      end
      if ic.blast and point_in_rect(px, py, ic.blast) and self.inspector_node then
        self:toggle_blast_radius(self.inspector_node.id)
        return true
      end
      if ic.flow and point_in_rect(px, py, ic.flow) and self.inspector_node then
        self:start_flow_trace(self.inspector_node.id)
        return true
      end
      if ic.jump and point_in_rect(px, py, ic.jump) and self.inspector_node then
        local n = self.inspector_node
        if n.file and not n.external and not n.suggested then
          core.root_view:open_doc(core.open_doc(n.file))
          local doc = core.active_view and core.active_view.doc
          if doc and n.line then
            doc:set_selection(n.line, 1, n.line, 1)
            core.active_view:scroll_to_line(n.line, true)
          end
        else
          show_toast("AI Visualizer: '" .. (n.label or n.id) .. "' is an AI suggestion / inferred tool (not in local code)")
        end
        return true
      end
    end

    -- 5. Check Audit Controls
    if hits.audit_controls and self.right_rail_tab == "audit" then
      local ac = hits.audit_controls
      if ac.run and point_in_rect(px, py, ac.run) then
        self:run_architecture_audit(true)
        return true
      end
      if ac.ai_deep_audit and point_in_rect(px, py, ac.ai_deep_audit) then
        self:run_ai_architecture_audit()
        return true
      end
      if ac.findings then
        for _, fb in ipairs(ac.findings) do
          if fb.enlarge_rect and point_in_rect(px, py, fb.enlarge_rect) then
            if fb.finding then
              self:enlarge_audit_finding(fb.finding)
            end
            return true
          elseif point_in_rect(px, py, fb) then
            if fb.finding then
              self:select_audit_finding(fb.finding)
            end
            return true
          end
        end
      end
    end

    -- 5b. Check Heatmap Controls
    if hits.heat_controls and self.right_rail_tab == "heatmap" then
      local hc = hits.heat_controls
      if hc.toggle and point_in_rect(px, py, hc.toggle) then
        self:toggle_heatmap()
        return true
      end
      if hc.hotspots then
        for _, hb in ipairs(hc.hotspots) do
          if point_in_rect(px, py, hb) and hb.node then
            self:center_on_node(hb.node)
            return true
          end
        end
      end
    end

    -- 5b. Check Tour Controls in Right Sidebar
    if hits.tour_controls and self.right_rail_tab == "tour" then
      local tc = hits.tour_controls
      if tc.start and point_in_rect(px, py, tc.start) then
        self:start_story_mode()
        return true
      end
      if tc.prev and point_in_rect(px, py, tc.prev) then
        self:story_prev()
        return true
      end
      if tc.next and point_in_rect(px, py, tc.next) then
        self:story_next()
        return true
      end
      if tc.exit and point_in_rect(px, py, tc.exit) then
        self:exit_story_mode()
        return true
      end
    end

    -- 6. Check Flow Controls
    if hits.flow_controls and self.right_rail_tab == "flow" then
      local fc = hits.flow_controls
      if fc.trace and point_in_rect(px, py, fc.trace) then
        local diag = self:current_diagram()
        local src_id = self.inspector_node and self.inspector_node.id or (diag and diag.nodes and diag.nodes[1] and diag.nodes[1].id)
        if src_id then self:start_flow_trace(src_id) end
        return true
      end
      if fc.clear and point_in_rect(px, py, fc.clear) then
        self:clear_flow_trace()
        return true
      end
      if fc.heatmap and point_in_rect(px, py, fc.heatmap) then
        self:toggle_heatmap()
        return true
      end
      if fc.tour and point_in_rect(px, py, fc.tour) then
        self:toggle_story_mode()
        return true
      end
      if fc.fit and point_in_rect(px, py, fc.fit) then
        self:fit_to_view()
        return true
      end
    end

    -- 7. Check Action Controls (Export SVG, Re-Analyze, Guide MD)
    if hits.action_controls and self.right_rail_tab == "actions" then
      local ac = hits.action_controls
      if ac.reanalyze and point_in_rect(px, py, ac.reanalyze) then
        self:reanalyze()
        return true
      end
      if ac.clean_cache and point_in_rect(px, py, ac.clean_cache) then
        self:clean_and_sanitize_cache()
        return true
      end
      if ac.toggle_suggestions and point_in_rect(px, py, ac.toggle_suggestions) then
        self:toggle_suggested_nodes()
        return true
      end
      if ac.toggle_suggestions and point_in_rect(px, py, ac.toggle_suggestions) then
        self:toggle_suggested_nodes()
        return true
      end
      if ac.export_svg and point_in_rect(px, py, ac.export_svg) then
        self:export_svg()
        return true
      end
      if ac.export_guide and point_in_rect(px, py, ac.export_guide) then
        self:export_onboarding_guide()
        return true
      end
      if ac.fit and point_in_rect(px, py, ac.fit) then
        self:fit_to_view()
        return true
      end
      if ac.zoom100 and point_in_rect(px, py, ac.zoom100) then
        self:zoom_100()
        return true
      end
    end

    return true
  end

  -- Toolbar Controls
  if self.toolbar_rects and self.toolbar_rects.category_pill and point_in_rect(px, py, self.toolbar_rects.category_pill) then
    self:pick_category_dialog()
    return true
  end
  if self.toolbar_rects and self.toolbar_rects.ask_ai_rect and point_in_rect(px, py, self.toolbar_rects.ask_ai_rect) then
    self:open_ai_ask()
    return true
  end
  if self.toolbar_rects and self.toolbar_rects.audit_rect and point_in_rect(px, py, self.toolbar_rects.audit_rect) then
    self:run_architecture_audit()
    return true
  end
  -- AI Architecture Insight Banner & Enlarged Modal
  if self.ai_insight and self.ai_banner_rects then
    local r = self.ai_banner_rects
    if r.is_enlarged then
      -- 1. Close / Dismiss button
      if r.dismiss_rect and point_in_rect(px, py, r.dismiss_rect) then
        self:clear_ai_insight()
        return true
      end
      -- 2. Minimize button (header or footer)
      if (r.enlarge_rect and point_in_rect(px, py, r.enlarge_rect)) or
         (r.footer_minimize_rect and point_in_rect(px, py, r.footer_minimize_rect)) then
        self.ai_insight_enlarged = false
        self.ai_insight_scroll_y = 0
        core.redraw = true
        return true
      end
      -- 3. Copy button (header or footer)
      if (r.copy_rect and point_in_rect(px, py, r.copy_rect)) or
         (r.footer_copy_rect and point_in_rect(px, py, r.footer_copy_rect)) then
        if system and system.set_clipboard and self.ai_insight.text then
          system.set_clipboard(self.ai_insight.text)
          show_toast("Copied AI Architecture Insight to clipboard!")
        end
        return true
      end
      -- 4. Component pills
      for _, pill in ipairs(r.node_pills or {}) do
        if point_in_rect(px, py, pill) then
          local diag = self:current_diagram()
          if diag and diag.nodes then
            for _, n in ipairs(diag.nodes) do
              if n.id == pill.id then
                self:center_on_node(n)
                show_toast("Focused component: " .. (n.label or n.id))
                break
              end
            end
          end
          return true
        end
      end
      -- 5. Click inside card bounds (consume click so it doesn't pass through to canvas)
      if r.card_bounds and point_in_rect(px, py, r.card_bounds) then
        return true
      end
      -- 6. Click on backdrop outside card (minimizes enlarged card)
      if r.backdrop_rect and point_in_rect(px, py, r.backdrop_rect) then
        self.ai_insight_enlarged = false
        self.ai_insight_scroll_y = 0
        core.redraw = true
        return true
      end
    else
      -- Compact mode clicks
      if r.dismiss_rect and point_in_rect(px, py, r.dismiss_rect) then
        self:clear_ai_insight()
        return true
      end
      if r.enlarge_rect and point_in_rect(px, py, r.enlarge_rect) then
        self.ai_insight_enlarged = true
        self.ai_insight_scroll_y = 0
        core.redraw = true
        return true
      end
      if r.banner_rect and point_in_rect(px, py, r.banner_rect) then
        self.ai_insight_enlarged = true
        self.ai_insight_scroll_y = 0
        core.redraw = true
        return true
      end
    end
  end
  if self.audit_open and self.audit_rects then
    if self.audit_rects.close_rect and point_in_rect(px, py, self.audit_rects.close_rect) then
      self.audit_open = false
      core.redraw = true
      return true
    end
    for _, fb in ipairs(self.audit_rects.findings or {}) do
      if fb.enlarge_rect and point_in_rect(px, py, fb.enlarge_rect) then
        if fb.finding then
          self:enlarge_audit_finding(fb.finding)
        end
        return true
      elseif point_in_rect(px, py, fb) then
        if fb.finding then
          self:select_audit_finding(fb.finding)
        end
        return true
      end
    end
  end
  if point_in_rect(px, py, self.toolbar_rects.export_rect) then
    self:export_svg()
    return true
  end
  if point_in_rect(px, py, self.toolbar_rects.guide_rect) then
    self:export_onboarding_guide()
    return true
  end
  if point_in_rect(px, py, self.toolbar_rects.search_rect) then
    self:open_search_prompt()
    return true
  end
  if point_in_rect(px, py, self.toolbar_rects.search_clear_rect) then
    self:clear_search()
    return true
  end
  if point_in_rect(px, py, self.toolbar_rects.search_next_rect) then
    self:find_next()
    return true
  end
  if point_in_rect(px, py, self.toolbar_rects.search_prev_rect) then
    self:find_prev()
    return true
  end

  if point_in_rect(px, py, self.toolbar_rects.focus_exit_rect) then
    self:exit_focus_lens()
    return true
  end
  if point_in_rect(px, py, self.toolbar_rects.impact_exit_rect) then
    self:clear_blast_radius()
    return true
  end
  if point_in_rect(px, py, self.toolbar_rects.reanalyze_rect) then
    self:reanalyze()
    return true
  end
  if point_in_rect(px, py, self.toolbar_rects.fit_rect) then
    self:fit_to_view()
    return true
  end
  if point_in_rect(px, py, self.toolbar_rects.zoom100_rect) then
    self:zoom_100()
    return true
  end
  if point_in_rect(px, py, self.toolbar_rects.zoom_in_rect) then
    self:zoom_in()
    return true
  end
  if point_in_rect(px, py, self.toolbar_rects.zoom_out_rect) then
    self:zoom_out()
    return true
  end
  if point_in_rect(px, py, self.toolbar_rects.provider_rect) then
    self:select_provider_dialog()
    return true
  end

  -- Inspector Drawer Actions
  if self.inspector_open and self.inspector_node then
    local ire = self.inspector_rects
    if ire.close_rect and point_in_rect(px, py, ire.close_rect) then
      self.inspector_open = false
      core.redraw = true
      return true
    end
    if ire.focus_rect and point_in_rect(px, py, ire.focus_rect) then
      self:toggle_focus_lens(self.inspector_node.id)
      return true
    end
    if ire.impact_rect and point_in_rect(px, py, ire.impact_rect) then
      self:toggle_blast_radius(self.inspector_node.id)
      return true
    end
    if ire.flow_rect and point_in_rect(px, py, ire.flow_rect) and self.inspector_node then
      if self.flow_trace and self.flow_trace.source == self.inspector_node.id then
        self:clear_flow_trace()
      else
        self:start_flow_trace(self.inspector_node.id)
      end
      return true
    end
    if ire.jump_rect and point_in_rect(px, py, ire.jump_rect) then
      open_node_file(self.inspector_node)
      return true
    end
    if ire.neighbor_rects then
      for nid, nrect in pairs(ire.neighbor_rects) do
        if point_in_rect(px, py, nrect) then
          local diag = self:current_diagram()
          if diag and diag.nodes then
            for _, n in ipairs(diag.nodes) do
              if n.id == nid then
                self.inspector_node = n
                core.redraw = true
                return true
              end
            end
          end
        end
      end
    end
  end

  local tb_h   = DiagramRenderer.TOOLBAR_H or 36
  local rail_w
  if self.sidebar_collapsed then
    rail_w = 44 * SCALE
  elseif is_sidebar_mode then
    rail_w = math.min(180 * SCALE, math.floor(self.size.x * 0.4))
  else
    rail_w = self.sidebar_w or (200 * SCALE)
  end
  DiagramRenderer.RAIL_W = rail_w
  local st_h   = DiagramRenderer.STATUS_H or 28
  if px >= self.position.x and px <= self.position.x + rail_w and
     py >= self.position.y + tb_h and py <= self.position.y + self.size.y - st_h then
    if self.rail_hit_rects and self.rail_hit_rects.toggle_rect then
      local tr = self.rail_hit_rects.toggle_rect
      if px >= tr.x and px <= tr.x + tr.w and py >= tr.y and py <= tr.y + tr.h then
        self.sidebar_collapsed = not self.sidebar_collapsed
        self:fit_to_view()
        core.redraw = true
        return true
      end
    end
    for _, item in ipairs(self.rail_hit_rects or {}) do
      if px >= item.x and px <= item.x + item.w and py >= item.y and py <= item.y + item.h then
        self:switch_category(item.idx)
        return true
      end
    end
    return true
  end

  local diag = self:get_effective_diagram()
  if diag and diag.nodes then
    local node = DiagramRenderer.node_at(diag.nodes, px, py, self.pan_x, self.pan_y, self.scale)
    if node then
      if clicks and clicks >= 2 then
        -- Double click: Toggle Subsystem Focus Lens
        self:toggle_focus_lens(node.id)
      else
        -- Single click: Select and open Inspector Drawer
        self:toggle_inspector(node)
      end
      return true
    end
  end

  if self.active_audit_finding then
    self.active_audit_finding = nil
    core.redraw = true
  end
  self.dragging     = true
  self.drag_start_x = px
  self.drag_start_y = py
  self.pan_start_x  = self.pan_x
  self.pan_start_y  = self.pan_y
  return true
end

function VisualizerView:on_mouse_released(button, px, py)
  if button == "left" then self.dragging = false end
  return true
end

function VisualizerView:on_mouse_moved(px, py, dx, dy)
  self.mouse_x = px
  self.mouse_y = py

  if py <= self.position.y + (DiagramRenderer.TOOLBAR_H or 36) then
    core.redraw = true
  end

  if self.dragging then
    self.pan_x = self.pan_start_x + (px - self.drag_start_x)
    self.pan_y = self.pan_start_y + (py - self.drag_start_y)
    core.redraw = true
    return true
  end

  local diag = self:current_diagram()
  if diag and diag.nodes then
    local node = DiagramRenderer.node_at(diag.nodes, px, py, self.pan_x, self.pan_y, self.scale)
    if node ~= self.hovered_node then
      self.hovered_node = node
      self.hover_timer  = system.get_time()
      self.show_tooltip = false
      core.redraw = true
    end
  end
end

function VisualizerView:on_mouse_wheel(dy, dx)
  local mx = self.mouse_x or (self.position.x + self.size.x / 2)
  local my = self.mouse_y or (self.position.y + self.size.y / 2)

  -- If Enlarged Audit Finding is active and mouse is over card bounds, scroll audit finding text
  if self.audit_finding_enlarged and self.audit_enlarged_rects and self.audit_enlarged_rects.card_bounds then
    if point_in_rect(mx, my, self.audit_enlarged_rects.card_bounds) then
      local max_scroll = self.audit_enlarged_rects.max_scroll or 0
      if max_scroll > 0 then
        self.audit_enlarged_scroll_y = math.max(0, math.min(max_scroll, (self.audit_enlarged_scroll_y or 0) - dy * 35))
        core.redraw = true
      end
      return true
    end
  end

  -- If AI Insight is enlarged and mouse is over card bounds, scroll insight text
  if self.ai_insight and self.ai_insight_enlarged and self.ai_banner_rects and self.ai_banner_rects.card_bounds then
    if point_in_rect(mx, my, self.ai_banner_rects.card_bounds) then
      local max_scroll = self.ai_banner_rects.max_scroll or 0
      if max_scroll > 0 then
        self.ai_insight_scroll_y = math.max(0, math.min(max_scroll, (self.ai_insight_scroll_y or 0) - dy * 35))
        core.redraw = true
      end
      return true
    end
  end

  local ctrl = keymap.modkeys and (keymap.modkeys["ctrl"] or keymap.modkeys["gui"])
  local shift = keymap.modkeys and keymap.modkeys["shift"]

  if ctrl then
    local zoom_factor = (dy > 0) and 1.12 or 0.89
    local new_scale = math.max(0.3, math.min(3.5, self.scale * zoom_factor))
    if new_scale ~= self.scale then
      local mx = self.mouse_x or (self.position.x + self.size.x / 2)
      local my = self.mouse_y or (self.position.y + self.size.y / 2)
      local wx, wy = DiagramRenderer.screen_to_world(mx, my, self.pan_x, self.pan_y, self.scale)
      self.scale = new_scale
      self.pan_x = mx - wx * new_scale
      self.pan_y = my - wy * new_scale
      core.redraw = true
    end
  elseif shift then
    self.pan_x = self.pan_x + dy * 50
    core.redraw = true
  else
    self.pan_y = self.pan_y + dy * 50
    core.redraw = true
  end
  return true
end

function VisualizerView:try_close(do_close)
  AIAnalyzer.cancel()
  VisualizerView.super.try_close(self, do_close)
end

local function find_visualizer_view()
  local function traverse(node)
    if not node then return nil, nil end
    if node.views then
      for _, view in ipairs(node.views) do
        if view:is(VisualizerView) then return view, node end
      end
    end
    if node.a then
      local v, n = traverse(node.a)
      if v then return v, n end
    end
    if node.b then
      local v, n = traverse(node.b)
      if v then return v, n end
    end
    return nil, nil
  end
  return traverse(core.root_view.root_node)
end

local function open_visualizer()
  local view, node = find_visualizer_view()
  local sidebar = rawget(_G, "get_sidebar_node") and _G.get_sidebar_node()
  if view then
    if sidebar and node == sidebar then
      if (sidebar.size.x or 0) < 540 * SCALE then
        sidebar.size.x = 540 * SCALE
        view.size.x = 540 * SCALE
      end
      sidebar:set_active_view(view)
    elseif node then
      node:set_active_view(view)
    end
    core.set_active_view(view)
    view:fit_to_view()
    return view
  end

  local new_view = VisualizerView()
  new_view.visible = true
  if sidebar then
    if (sidebar.size.x or 0) < 540 * SCALE then
      sidebar.size.x = 540 * SCALE
      new_view.size.x = 540 * SCALE
    end
    -- Add new view first so node is never empty/destroyed
    if not core.root_view.root_node:get_node_for_view(new_view) then
      sidebar:add_view(new_view)
    end
    for i = #sidebar.views, 1, -1 do
      local v = sidebar.views[i]
      if v ~= new_view then
        sidebar:remove_view(core.root_view.root_node, v)
      end
    end
    sidebar:set_active_view(new_view)
  else
    local primary = core.root_view:get_primary_node()
    sidebar = primary:split("right", new_view, { x = true }, true)
    if sidebar then
      sidebar.should_show_tabs = function() return false end
      if not sidebar._ab_patched then
        local old_av = sidebar.add_view
        sidebar.add_view = function(self, v)
          local l = self.locked; self.locked = nil
          old_av(self, v)
          self.locked = l
        end
        sidebar._ab_patched = true
      end
      rawset(_G, "_ag_sidebar_node", sidebar)
      sidebar.size.x = 540 * SCALE
      new_view.size.x = 540 * SCALE
    end
  end
  core.set_active_view(new_view)
  new_view:fit_to_view()
  return new_view
end

local function toggle_visualizer()
  local sidebar = rawget(_G, "get_sidebar_node") and _G.get_sidebar_node()
  local view, node = find_visualizer_view()
  if view and node then
    if sidebar and node == sidebar and node.active_view == view then
      for i = #node.views, 1, -1 do
        node:close_view(core.root_view.root_node, node.views[i])
      end
      rawset(_G, "_ag_sidebar_node", nil)
    elseif sidebar and node == sidebar then
      if (sidebar.size.x or 0) < 540 * SCALE then
        sidebar.size.x = 540 * SCALE
        view.size.x = 540 * SCALE
      end
      node:set_active_view(view)
      core.set_active_view(view)
      view:fit_to_view()
    else
      node:close_view(core.root_view.root_node, view)
    end
  else
    if not view then view = VisualizerView() end
    view.visible = true
    if sidebar then
      if (sidebar.size.x or 0) < 540 * SCALE then
        sidebar.size.x = 540 * SCALE
        view.size.x = 540 * SCALE
      end
      -- Add new view first so node is never empty/destroyed
      if not core.root_view.root_node:get_node_for_view(view) then
        sidebar:add_view(view)
      end
      for i = #sidebar.views, 1, -1 do
        local v = sidebar.views[i]
        if v ~= view then
          sidebar:remove_view(core.root_view.root_node, v)
        end
      end
      sidebar:set_active_view(view)
      core.set_active_view(view)
      view:fit_to_view()
    else
      local primary = core.root_view:get_primary_node()
      sidebar = primary:split("right", view, { x = true }, true)
      if sidebar then
        sidebar.should_show_tabs = function() return false end
        if not sidebar._ab_patched then
          local old_av = sidebar.add_view
          sidebar.add_view = function(self, v)
            local l = self.locked; self.locked = nil
            old_av(self, v)
            self.locked = l
          end
          sidebar._ab_patched = true
        end
        rawset(_G, "_ag_sidebar_node", sidebar)
        sidebar.size.x = 540 * SCALE
        view.size.x = 540 * SCALE
        sidebar:set_active_view(view)
        core.set_active_view(view)
        view:fit_to_view()
      end
    end
  end
  core.redraw = true
end

command.add(VisualizerView, {
  ["ai_project_visualizer:pick_category"] = function(view)
    view:pick_category_dialog()
  end,
  ["ai_project_visualizer:find"] = function(view)
    view:open_search_prompt()
  end,
  ["ai_project_visualizer:find_next"] = function(view)
    view:find_next()
  end,
  ["ai_project_visualizer:find_prev"] = function(view)
    view:find_prev()
  end,
  ["ai_project_visualizer:clear_search"] = function(view)
    view:clear_search()
  end,
  ["ai_project_visualizer:trace_flow"] = function(view)
    if view.inspector_node then
      view:start_flow_trace(view.inspector_node.id)
    else
      show_toast("Select a component in Visualizer to trace flow")
    end
  end,
  ["ai_project_visualizer:ask_ai"] = function(view)
    view:open_ai_ask()
  end,
  ["ai_project_visualizer:next_tab"] = function(view)
    view:next_category()
  end,
  ["ai_project_visualizer:toggle_inspector"] = function(view)
    view:toggle_inspector()
  end,
  ["ai_project_visualizer:toggle_focus_lens"] = function(view)
    local target = view.inspector_node or view.hovered_node
    if target then view:toggle_focus_lens(target.id) end
  end,
  ["ai_project_visualizer:toggle_blast_radius"] = function(view)
    local target = view.inspector_node or view.hovered_node
    if target then view:toggle_blast_radius(target.id) end
  end,
  ["ai_project_visualizer:toggle_story_mode"] = function(view)
    if view.story_mode then view:exit_story_mode() else view:start_story_mode() end
  end,
  ["ai_project_visualizer:toggle_heatmap"] = function(view)
    if view.toggle_heatmap then view:toggle_heatmap(); return true end
  end,
  ["ai_project_visualizer:export_onboarding_guide"] = function(view)
    if view.export_onboarding_guide then view:export_onboarding_guide(); return true end
  end,
  ["ai_project_visualizer:story_next"] = function(view)
    if view.story_mode then view:story_next(); return true end
    return false
  end,
  ["ai_project_visualizer:story_prev"] = function(view)
    if view.story_mode then view:story_prev(); return true end
    return false
  end,
  ["ai_project_visualizer:escape_action"] = function(view)
    if view.right_rail_open and (view.size.x < 760 * SCALE) then
      view.right_rail_open = false
      core.redraw = true
      return true
    elseif view.focus_node_id then
      view:exit_focus_lens()
      return true
    elseif view.impact_data then
      view:clear_blast_radius()
      return true
    elseif view.story_mode then
      view:exit_story_mode()
      return true
    elseif view.heatmap_mode then
      view:toggle_heatmap()
      return true
    elseif view.audit_finding_enlarged then
      view:close_enlarged_audit()
      return true
    elseif view.active_audit_finding then
      view:clear_active_audit_finding()
      return true
    elseif view.search_query and view.search_query ~= "" then
      view:clear_search()
      return true
    elseif view.ai_insight then
      if view.ai_insight_enlarged then
        view.ai_insight_enlarged = false
        view.ai_insight_scroll_y = 0
        core.redraw = true
      else
        view:clear_ai_insight()
      end
      return true
    elseif view.audit_open then
      view.audit_open = false
      core.redraw = true
      return true
    elseif view.inspector_open then
      view.inspector_open = false
      core.redraw = true
      return true
    end
    return false
  end,
})

command.add(nil, {
  ["ai_project_visualizer:toggle"] = function()
    toggle_visualizer()
  end,
  ["ai_project_visualizer:open_find"] = function()
    local view = open_visualizer()
    if view then view:open_search_prompt() end
  end,
  ["ai_project_visualizer:open_ai_ask"] = function()
    local view = open_visualizer()
    if view then view:open_ai_ask() end
  end,
  ["ai_project_visualizer:toggle_dimensions"] = function()
    local view, _ = find_visualizer_view()
    if view then
      if view.right_rail_open and view.right_rail_tab == "dimensions" then
        view.right_rail_open = false
      else
        view.right_rail_open = true
        view.right_rail_tab  = "dimensions"
      end
      view:fit_to_view()
      core.redraw = true
    end
  end,
  ["ai_project_visualizer:open_export_tab"] = function(view)
    local v = view or open_visualizer()
    if v then
      v.right_rail_tab = "actions"
      v.right_rail_open = true
      v:fit_to_view()
      core.redraw = true
    end
  end,
  ["ai_project_visualizer:clean_cache"] = function(view)
    local v = view or find_visualizer_view()
    if v and v.clean_and_sanitize_cache then v:clean_and_sanitize_cache() end
  end,
  ["ai_project_visualizer:toggle_suggestions"] = function(view)
    local v = view or find_visualizer_view()
    if v and v.toggle_suggested_nodes then v:toggle_suggested_nodes() end
  end,
  ["ai_project_visualizer:open_tour_tab"] = function(view)
    local v = view or open_visualizer()
    if v then
      v.right_rail_tab = "tour"
      v.right_rail_open = true
      v:fit_to_view()
      core.redraw = true
    end
  end,
  ["ai_project_visualizer:toggle_right_sidebar"] = function()
    local view, _ = find_visualizer_view()
    if view then
      view.right_rail_open = not view.right_rail_open
      view:fit_to_view()
      core.redraw = true
    end
  end,
  ["ai_project_visualizer:toggle_sidebar"] = function()
    local view, _ = find_visualizer_view()
    if view then
      view.sidebar_collapsed = not view.sidebar_collapsed
      core.redraw = true
    end
  end,
  ["ai_project_visualizer:reanalyze"] = function()
    local view = open_visualizer()
    if view then view:reanalyze() end
  end,
  ["ai_project_visualizer:run_audit"] = function()
    local view = open_visualizer()
    if view then view:run_architecture_audit() end
  end,
  ["ai_project_visualizer:export_svg"] = function()
    local view, _ = find_visualizer_view()
    if view then view:export_svg() else show_toast("Open AI Visualizer first to export diagrams") end
  end,
  ["ai_project_visualizer:export_onboarding_guide_global"] = function()
    local view, _ = find_visualizer_view()
    if view then view:export_onboarding_guide() else show_toast("Open AI Visualizer first to export onboarding guide") end
  end,
  ["ai_project_visualizer:select_provider"] = function()
    local view = open_visualizer()
    if view then view:select_provider_dialog() end
  end,
  ["ai_project_visualizer:cycle_provider"] = function()
    local view = open_visualizer()
    if view then view:cycle_provider() end
  end,
})

keymap.add({
  ["ctrl+shift+v"] = "ai_project_visualizer:toggle",
  ["ctrl+shift+u"] = "ai_project_visualizer:run_audit",
  ["ctrl+shift+y"] = "ai_project_visualizer:reanalyze",
  ["ctrl+shift+e"] = "ai_project_visualizer:export_onboarding_guide",
  ["alt+0"]        = "ai_project_visualizer:next_tab",
  ["ctrl+f"]       = "ai_project_visualizer:find",
  ["f3"]           = "ai_project_visualizer:find_next",
  ["shift+f3"]     = "ai_project_visualizer:find_prev",
  ["ctrl+i"]       = "ai_project_visualizer:ask_ai",
  ["i"]            = "ai_project_visualizer:toggle_inspector",
  ["f"]            = "ai_project_visualizer:toggle_focus_lens",
  ["b"]            = "ai_project_visualizer:toggle_blast_radius",
  ["t"]            = "ai_project_visualizer:toggle_story_mode",
  ["h"]            = "ai_project_visualizer:toggle_heatmap",
  ["right"]        = "ai_project_visualizer:story_next",
  ["left"]         = "ai_project_visualizer:story_prev",
  ["escape"]       = "ai_project_visualizer:escape_action",
})

return VisualizerView
