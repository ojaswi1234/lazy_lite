-- mod-version:3
-- Layout Engine for AI Project Visualizer
-- Implements dynamic, flexible Sugiyama layered layout for DAGs with:
-- 1. Dynamic content-based node sizing (widths fit labels & tech tags cleanly)
-- 2. Multi-row wrapping (prevents single-tier horizontal explosion)
-- 3. Dynamic channel heights (highways expand proportionally to track count)
-- 4. 3-sweep Barycenter crossing minimization
-- 5. Distributed boundary port allocation & Manhattan channel track indexing

local LayoutEngine = {}

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

return LayoutEngine
