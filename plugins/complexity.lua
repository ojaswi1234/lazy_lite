-- mod-version:3
local core = require "core"
local command = require "core.command"
local style = require "core.style"
local keymap = require "core.keymap"
local config = require "core.config"

-- Big-O Complexity Heuristic Analyzer
-- This plugin performs static analysis using regex heuristics and block depth tracking
-- to estimate Time and Space complexity of code selections.

local function strip_strings_and_comments(line)
  -- naive strip of string literals
  local s = line:gsub('".-"', '""'):gsub("'.-'", "''")
  -- naive strip of common comments
  s = s:gsub("//.*", ""):gsub("#.*", ""):gsub("%-%-.*", "")
  return s
end

local function get_indent(line)
  local spaces = line:match("^(%s*)")
  return spaces and #spaces or 0
end

local function analyze_code(code, lang)
  local max_tc_pow = 0
  local max_sc_pow = 0
  local is_log = false
  local has_nlogn = false
  local has_heap = false
  local has_dp = false
  local num_recursive_calls = 0
  
  local tc_stack = {}
  local sc_stack = {}
  local current_indent = 0
  local depth = 0
  
  local in_c_style = (lang == "c" or lang == "cpp" or lang == "java" or lang == "javascript" or lang == "typescript")
  
  for line in code:gmatch("[^\r\n]+") do
    local clean = strip_strings_and_comments(line)
    if clean:match("%S") then
      -- Track Depth
      if in_c_style then
        local open_braces = select(2, clean:gsub("{", ""))
        local close_braces = select(2, clean:gsub("}", ""))
        depth = depth + open_braces - close_braces
        if depth < 0 then depth = 0 end
      else
        -- Python-style indent tracking
        local ind = get_indent(line)
        if ind > current_indent then
          depth = depth + 1
        elseif ind < current_indent then
          depth = math.max(0, depth - math.ceil((current_indent - ind) / 4))
        end
        current_indent = ind
      end
      
      -- ensure stack size matches depth
      while #tc_stack > depth do table.remove(tc_stack) end
      while #sc_stack > depth do table.remove(sc_stack) end
      while #tc_stack < depth do table.insert(tc_stack, 0) end
      while #sc_stack < depth do table.insert(sc_stack, 0) end
      
      -- Time Complexity Heuristics
      local is_loop = clean:match("%Wfor%W") or clean:match("^for%W") or clean:match("%Wwhile%W") or clean:match("^while%W")
      local is_traversal = clean:match("dfs%(") or clean:match("bfs%(") or clean:match("backtrack%(") or clean:match("helper%(") or clean:match("solve%(") or clean:match("recurse%(")
      if is_loop or is_traversal then
        tc_stack[#tc_stack] = 1 -- Adds O(N) to this depth level
      end
      
      -- Track multiple recursive branches for O(2^N) (Exponential)
      if is_traversal then
        num_recursive_calls = num_recursive_calls + select(2, clean:gsub("dfs%(", ""))
        num_recursive_calls = num_recursive_calls + select(2, clean:gsub("bfs%(", ""))
        num_recursive_calls = num_recursive_calls + select(2, clean:gsub("helper%(", ""))
        num_recursive_calls = num_recursive_calls + select(2, clean:gsub("solve%(", ""))
        num_recursive_calls = num_recursive_calls + select(2, clean:gsub("backtrack%(", ""))
        num_recursive_calls = num_recursive_calls + select(2, clean:gsub("recurse%(", ""))
      end
      
      -- Dynamic Programming / Memoization
      if clean:match("@cache") or clean:match("@lru_cache") or clean:match("memo%[") or clean:match("dp%[") or clean:match("cache%[") then
        has_dp = true
      end
      
      -- Heap / Priority Queue operations
      if clean:match("PriorityQueue") or clean:match("priority_queue") or clean:match("heapq") or clean:match("heappush") or clean:match("heappop") or clean:match("%.poll%(") or clean:match("%.offer%(") or clean:match("push_heap") then
        has_heap = true
      end
      
      -- Check for divide/conquer step in while loops
      if clean:match("%/=?%s*2") or clean:match(">>%s*1") then
        if #tc_stack > 0 and tc_stack[#tc_stack] == 1 then
          is_log = true
          tc_stack[#tc_stack] = 0 -- It's log N, not N
        end
      end
      
      -- Check for N log N algorithms (sorting)
      if clean:match("%.sort%(") or clean:match("Arrays%.sort") or clean:match("Collections%.sort") or clean:match("sorted%(") then
        has_nlogn = true
      end
      
      -- Space Complexity Heuristics
      local is_alloc = clean:match("%[%]") or clean:match("new%s+%w+%[") or clean:match("new%s+List") or clean:match("new%s+Map") or clean:match("new%s+Set") or clean:match("new%s+HashMap") or clean:match("new%s+ArrayList") or clean:match("%{.*%}") or clean:match("malloc")
      if (is_alloc and not clean:match("return%s+[^%s]")) or is_traversal or has_dp then
        sc_stack[#sc_stack] = 1
      end
      
      -- 2D Table allocations for DP -> O(N^2) Space
      if clean:match("new%s+%w+%[%w+%][%w+]") or clean:match("vector<vector") or clean:match("make%([%w%[%]]+,%s*%w+%)") then
         if depth > 0 then sc_stack[#sc_stack] = 2 else max_sc_pow = math.max(max_sc_pow, 2) end
      end
      
      -- Calculate current absolute powers
      local current_tc_pow = 0
      for _, v in ipairs(tc_stack) do current_tc_pow = current_tc_pow + v end
      if current_tc_pow > max_tc_pow then max_tc_pow = current_tc_pow end
      
      local current_sc_pow = 0
      for _, v in ipairs(sc_stack) do current_sc_pow = current_sc_pow + v end
      if current_sc_pow > max_sc_pow then max_sc_pow = current_sc_pow end
    end
  end
  
  -- Ensure DP minimums
  if has_dp then
    if max_tc_pow == 0 then max_tc_pow = 1 end
    if max_sc_pow == 0 then max_sc_pow = 1 end
  end
  
  -- Format TC
  local tc_str = "O(1)"
  if num_recursive_calls >= 2 and not has_dp then
    tc_str = "O(2^N)"
  elseif has_nlogn or has_heap then
    if max_tc_pow > 1 then
      tc_str = "O(N^" .. max_tc_pow .. " log N)"
    else
      tc_str = "O(N log N)"
    end
  elseif max_tc_pow == 1 then
    tc_str = is_log and "O(log N)" or "O(N)"
  elseif max_tc_pow > 1 then
    tc_str = "O(N^" .. max_tc_pow .. ")"
  end
  
  -- Format SC
  local sc_str = "O(1)"
  if max_sc_pow == 1 then
    sc_str = "O(N)"
  elseif max_sc_pow > 1 then
    sc_str = "O(N^" .. max_sc_pow .. ")"
  end
  
  return tc_str, sc_str, max_tc_pow, max_sc_pow
end

command.add("core.docview", {
  ["complexity:analyze"] = function()
    local doc = core.active_view.doc
    if not doc then return end
    
    local text = ""
    if doc:has_selection() then
      text = doc:get_text(doc:get_selection())
    else
      text = doc:get_text(1, 1, math.huge, math.huge)
    end
    
    local lang = doc.syntax and doc.syntax.name and doc.syntax.name:lower() or "python"
    local tc, sc, tpow, spow = analyze_code(text, lang)
    
    core.log("[Complexity] Estimated Big-O -> Time: %s | Space: %s", tc, sc)
    
    local msg = string.format("Estimated Complexity -> Time: %s | Space: %s", tc, sc)
    core.log_quiet(msg)
  end
})

keymap.add({
  ["ctrl+alt+o"] = "complexity:analyze"
})

-- Graph Rendering
local function draw_graph(cx, cy, w, h, user_tc)
  local font = style.font
  -- Draw Axes
  renderer.draw_rect(cx, cy, 2, h, style.text) -- Y axis
  renderer.draw_rect(cx, cy + h, w, 2, style.text) -- X axis
  
  renderer.draw_text(font, "Operations (Time)", cx + 10, cy - 20, style.dim)
  renderer.draw_text(font, "Elements (N)", cx + w - 80, cy + h + 10, style.dim)
  
  local max_n = 20
  local max_y = 400
  
  local curves = {
    { label = "O(1)",       func = function(n) return 10 end, color = {0, 255, 0, 255} },
    { label = "O(log N)",   func = function(n) return math.log(n + 1) * 20 end, color = {100, 255, 100, 255} },
    { label = "O(N)",       func = function(n) return n * 15 end, color = {255, 255, 0, 255} },
    { label = "O(N log N)", func = function(n) return n * math.log(n + 1) * 5 end, color = {255, 165, 0, 255} },
    { label = "O(N^2)",     func = function(n) return n * n end, color = {255, 50, 50, 255} },
    { label = "O(2^N)",     func = function(n) return (2 ^ (n / 2)) * 2 end, color = {255, 0, 255, 255} }
  }
  
  local colors = {
    ["O(1)"] = curves[1].color,
    ["O(log N)"] = curves[2].color,
    ["O(N)"] = curves[3].color,
    ["O(N log N)"] = curves[4].color,
    ["O(N^2)"] = curves[5].color,
    ["O(2^N)"] = curves[6].color,
  }
  
  -- We parse user_tc. If it's higher than O(2^N) we treat it as O(2^N) for graphing
  local active_curve = user_tc
  if not colors[user_tc] then
    if user_tc:match("O%(N%^") then active_curve = "O(N^2)"
    else active_curve = "O(2^N)" end
  end
  
  for _, curve in ipairs(curves) do
    local is_active = (curve.label == active_curve)
    local col = is_active and curve.color or style.dim
    local dot_size = is_active and 4 or 2
    
    -- Plot points
    for n = 0, max_n, 0.2 do
      local val = curve.func(n)
      if val <= max_y then
        local px = cx + (n / max_n) * w
        local py = (cy + h) - (val / max_y) * h
        if px <= cx + w and py >= cy then
          renderer.draw_rect(px, py, dot_size, dot_size, col)
        end
      end
    end
    
    -- Draw Legend
    local end_val = curve.func(max_n)
    if end_val > max_y then end_val = max_y end
    local lx = cx + w + 10
    local ly = (cy + h) - (end_val / max_y) * h
    if curve.label == "O(1)" then ly = (cy + h) - 15 end
    renderer.draw_text(font, curve.label, lx, ly - 10, col)
  end
end

return {
  analyze_code = analyze_code,
  draw_graph = draw_graph
}
