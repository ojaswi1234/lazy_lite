-- mod-version:3
local core = require "core"
local command = require "core.command"
local style = require "core.style"
local View = require "core.view"
local process = require "process"
local treeview = require "plugins.treeview"

local GitTimelineView = View:extend()

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function split_ws(str)
  local result = {}
  for word in str:gmatch("%S+") do
    table.insert(result, word)
  end
  return result
end

-- Try to load a smaller font (85% of code_font size) for VS Code-like density.
-- Falls back gracefully to style.code_font if font loading isn't supported.
local function make_small_font()
  local ok, result = pcall(function()
    -- renderer.font.load is available in Lite XL 2.1+
    -- get_path() and get_size() are available on font objects
    local base = style.code_font
    local path = base:get_path()
    local size = math.floor(base:get_size() * 0.82)
    size = math.max(size, 8)
    return renderer.font.load(path, size, {antialiasing="subpixel", hinting="slight"})
  end)
  if ok and result then return result end
  return style.code_font  -- graceful fallback
end

-- ─── Configuration ────────────────────────────────────────────────────────────

local config = {
  max_commits    = 100,
  col_w          = 16,   -- graph column width (pre-scale)  — narrow like VS Code
  node_size      = 4,    -- commit node radius (pre-scale)
  line_thickness = 2,    -- branch line width (pre-scale)
  margin_left    = 6,    -- left margin (pre-scale)
  margin_right   = 6,    -- right margin (pre-scale)
  margin_top     = 4,    -- top margin inside content area (pre-scale)
  pad_h          = 6,    -- horizontal gap between elements (pre-scale)
  pad_v          = 1,    -- vertical padding (very tight, like VS Code)
  row_extra_px   = 4,    -- extra px above/below text per row (pre-scale)
  max_columns    = 8,    -- hard cap on graph columns
  date_min_w     = 60,   -- minimum width reserved for date column (pre-scale)
  author_min_w   = 60,   -- minimum width reserved for author column (pre-scale)
  branch_colors  = {
    {100, 180, 255},  -- blue  (main/master)
    {100, 220, 100},  -- green
    {255, 170,  50},  -- orange
    {210,  90, 220},  -- purple
    {255, 100, 100},  -- red
    { 80, 210, 210},  -- cyan
    {255, 215,  80},  -- yellow
  },
}

-- ─── Constructor ──────────────────────────────────────────────────────────────


local function small_font()
  local emoji_font = nil
  pcall(function()
    local path = USERDIR .. "/fonts/NotoColorEmoji.ttf"
    local f = io.open(path, "r")
    if f then
      f:close()
    else
      if PLATFORM == "Windows" then
        path = os.getenv("WINDIR") .. "\\Fonts\\seguiemj.ttf"
      elseif PLATFORM == "Mac OS X" then
        path = "/System/Library/Fonts/Apple Color Emoji.ttc"
      else
        path = "/usr/share/fonts/noto/NotoColorEmoji.ttf"
      end
    end
    if path then
      emoji_font = renderer.font.load(path, math.max(8, math.floor(style.code_font:get_size() * 0.82)))
    end
  end)

  local ok, f = pcall(function()
    local primary = renderer.font.load(
      style.code_font:get_path(),
      math.max(8, math.floor(style.code_font:get_size() * 0.82)),
      {antialiasing="subpixel", hinting="slight"}
    )
    if emoji_font then
      return renderer.font.group({primary, emoji_font})
    end
    return primary
  end)
  return (ok and f) or style.code_font
end

local function time_ago(iso)
  if not iso or iso == "" then return "" end
  return iso:match("^(%d+%-%d+%-%d+)") or iso
end

local function status_color(state)
  state = (state or ""):lower()
  if state == "open"   then return {100, 210, 100, 255} end
  if state == "closed" then return {180,  80,  80, 255} end
  if state == "merged" then return {150, 100, 220, 255} end
  return style.text
end

local function parse_json_array(text)
  local items = {}
  local depth, start = 0, nil
  for i = 1, #text do
    local c = text:byte(i)
    if c == 123 then
      depth = depth + 1
      if depth == 1 then start = i end
    elseif c == 125 then
      depth = depth - 1
      if depth == 0 and start then
        local obj_str = text:sub(start, i)
        local item = {}
        for k, v in obj_str:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do item[k] = v end
        for k, v in obj_str:gmatch('"([^"]+)"%s*:%s*(-?%d+)') do if not item[k] then item[k] = tonumber(v) end end
        for k in obj_str:gmatch('"([^"]+)"%s*:%s*null') do if not item[k] then item[k] = nil end end
        if next(item) then table.insert(items, item) end
        start = nil
      end
    end
  end
  return items
end

function GitTimelineView:new()
  GitTimelineView.super.new(self)
  self.scrollable = true
  self.commits = {}
  self.loading = true
  self.error_msg = nil
  self.sf = small_font()
  self.small_font = self.sf
  self.row_height = math.floor(self.sf:get_height() * SCALE * 1.5 + 4 * SCALE)
  self.scroll_pos = {0, 0, 0}
  
  self.size.y = 300 * SCALE

  self.tabs = {"Commits", "Issues", "PRs"}
  self.active_tab = 1
  self.tab_rects = {}
  
  -- GH issues state
  self.gh_items = {{}, {}}
  self.gh_loading = {false, false}
  self.gh_error = {nil, nil}
  self.gh_hovered = nil
  self.gh_item_rects = {}
  self.refresh_rect = nil
  
  self:update_commits()
  self:fetch_gh(1)
  self:fetch_gh(2)
end
local function install_gh_cli(on_complete)
  core.add_thread(function()
    local cmd
    if PLATFORM == "Windows" then
      cmd = {"winget", "install", "--id", "GitHub.cli", "-e", "--source", "winget", "--accept-source-agreements", "--accept-package-agreements"}
    elseif PLATFORM == "Mac OS X" then
      cmd = {"brew", "install", "gh"}
    else
      cmd = {"bash", "-c", "curl -sS https://webi.sh/gh | sh"}
    end
    local p = process.start(cmd, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
    if p then
      while p:returncode() == nil do
        p:read_stdout(8192)
        p:read_stderr(8192)
        coroutine.yield(0.1)
      end
    end
    if on_complete then on_complete() end
  end)
end


function GitTimelineView:fetch_gh(tab_idx)
  self.gh_loading[tab_idx] = true
  self.gh_error[tab_idx]   = nil
  core.redraw = true
  core.add_thread(function()
    local p_dir = core.project_dir or ""
    local cmd
    if tab_idx == 1 then
      cmd = {"gh", "issue", "list", "--json", "number,title,state,labels,createdAt,url", "--limit", "50", "--state", "open"}
    else
      cmd = {"gh", "pr", "list", "--json", "number,title,state,author,createdAt,url", "--limit", "50", "--state", "open"}
    end
    local p = process.start(cmd, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE, cwd = p_dir ~= "" and p_dir or nil })
    if not p then
      if not self.installing_gh and not self.gh_install_attempted then
        self.installing_gh = true
        self.gh_install_attempted = true
        self.gh_error[tab_idx] = "Installing GitHub CLI... Please wait."
        core.redraw = true
        install_gh_cli(function()
          self.installing_gh = false
          self:fetch_gh(tab_idx)
        end)
        return
      end
      self.gh_error[tab_idx] = "Failed to start gh or install it."
      self.gh_loading[tab_idx] = false
      core.redraw = true
      return
    end
    local out, err = "", ""
    while p:returncode() == nil do
      out = out .. (p:read_stdout(4096) or "")
      err = err .. (p:read_stderr(4096) or "")
      coroutine.yield(0.05)
    end
    while true do
      local c = p:read_stdout(4096) or ""; if c=="" then break end; out=out..c
    end
    while true do
      local c = p:read_stderr(4096) or ""; if c=="" then break end; err=err..c
    end
    if p:returncode() ~= 0 then
      self.gh_error[tab_idx] = err:match("%S") and err:gsub("[\r\n]+", " ") or "gh error (are you authenticated?)"
    else
      self.gh_items[tab_idx] = parse_json_array(out)
    end
    self.gh_loading[tab_idx] = false
    core.redraw = true
  end)
end


function GitTimelineView:get_name()
  return "Git Graph"
end

-- ─── Resize detection ─────────────────────────────────────────────────────────

function GitTimelineView:update()
  GitTimelineView.super.update(self)
  if self.size.x ~= self.last_width and #self.commits > 0 then
    self.last_width    = self.size.x
    self.cached_layout = self:calculate_layout(self.size.x)
    core.redraw = true
  end
end

-- ─── Git data fetching ────────────────────────────────────────────────────────

function GitTimelineView:update_commits()
  self.loading       = true
  self.error_msg     = nil
  self.cached_layout = nil
  core.redraw = true

  core.add_thread(function()
    local git_format = "%H|%P|%D|%s|%an|%ar"
    local cmd = {}
    local p_dir = core.project_dir or ""

    if core.active_codespace then
      local inner = "cd '" .. core.active_codespace.remote_dir ..
                    "' && git --no-pager log --all --pretty=format:'" .. git_format ..
                    "' -n " .. config.max_commits
      local safe = "'" .. inner:gsub("'", "'\\''") .. "'"
      cmd = {"gh", "cs", "ssh", "-c", core.active_codespace.name, "--", "sh", "-c", safe}
    else
      cmd = {"git", "-C", p_dir, "--no-pager", "log", "--all",
             "--pretty=format:" .. git_format, "-n", tostring(config.max_commits)}
    end

    local p = process.start(cmd, {stdout = process.REDIRECT_PIPE,
                                   stderr = process.REDIRECT_PIPE})
    if not p then
      self.error_msg = "Failed to start git process"
      self.loading   = false
      core.redraw    = true
      return
    end

    local out, err = self:read_process_output(p)

    if p:returncode() ~= 0 then
      self.error_msg = (err:match("%S") and err:gsub("[\r\n]+", " ")) or "Not a git repository"
      self.loading   = false
      core.redraw    = true
      return
    end

    self:parse_and_build_graph(out)
    self.loading = false
    core.redraw  = true
  end)
end

function GitTimelineView:read_process_output(p)
  local out, err = "", ""
  while p:returncode() == nil do
    out = out .. (p:read_stdout(4096) or "")
    err = err .. (p:read_stderr(4096) or "")
    coroutine.yield(0.05)
  end
  while true do
    local chunk = p:read_stdout(4096) or ""
    if chunk == "" then break end
    out = out .. chunk
  end
  while true do
    local chunk = p:read_stderr(4096) or ""
    if chunk == "" then break end
    err = err .. chunk
  end
  return out, err
end

-- ─── Parsing ──────────────────────────────────────────────────────────────────

function GitTimelineView:parse_and_build_graph(output)
  self.commits = {}

  for line in output:gmatch("[^\r\n]+") do
    local hash, parents_str, refs, msg, author, date =
      line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
    if hash and #hash >= 40 then
      table.insert(self.commits, {
        hash       = hash,
        short_hash = hash:sub(1, 7),
        parents    = (parents_str ~= "") and split_ws(parents_str) or {},
        refs       = (refs ~= "") and refs or nil,
        message    = msg    or "",
        author     = author or "",
        date       = date   or "",
        row_index  = #self.commits + 1,
        column     = 0,
        color      = config.branch_colors[1],
      })
    end
  end

  self:assign_graph_columns()

  local sf = self.small_font
  -- VS Code-like: very tight rows, just font height + tiny padding
  self.row_height = math.floor(sf:get_height() * SCALE + config.row_extra_px * SCALE)
end

-- ─── Graph layout algorithm ───────────────────────────────────────────────────

function GitTimelineView:assign_graph_columns()
  local active_cols = {}
  local used_cols   = {}
  local max_col     = -1

  local function alloc_col()
    local c = 0
    while used_cols[c] do c = c + 1 end
    used_cols[c] = true
    if c > max_col then max_col = c end
    return c
  end

  for _, commit in ipairs(self.commits) do
    local col
    if active_cols[commit.hash] then
      col = active_cols[commit.hash]
      active_cols[commit.hash] = nil
    else
      col = alloc_col()
    end
    commit.column = col
    commit.color  = config.branch_colors[(col % #config.branch_colors) + 1]

    local first_assigned = false
    for j, ph in ipairs(commit.parents) do
      if not active_cols[ph] then
        if j == 1 then
          active_cols[ph] = col
          first_assigned  = true
        else
          local nc = alloc_col()
          active_cols[ph] = nc
        end
      end
    end

    if not first_assigned or #commit.parents == 0 then
      used_cols[col] = nil
    end
  end

  local real_max = 0
  for _, c in ipairs(self.commits) do
    if c.column > real_max then real_max = c.column end
  end
  self.total_columns = real_max + 1
end

-- ─── Ref/branch parsing ───────────────────────────────────────────────────────

function GitTimelineView:parse_branches(ref_string)
  if not ref_string then return {} end
  local branches = {}
  for part in ref_string:gmatch("[^,]+") do
    part = part:match("^%s*(.-)%s*$")
    -- HEAD -> main  →  {name="main", is_head=true}
    local name = part:match("^HEAD %-> (.+)$")
    if name then
      table.insert(branches, {name = name, is_head = true})
    else
      -- plain remote or local branch (skip bare HEAD)
      if not part:match("^HEAD$") and not part:match("^tag: ") then
        if part ~= "" then
          table.insert(branches, {name = part, is_head = false})
        end
      end
    end
  end
  return branches
end

-- ─── Layout calculation ───────────────────────────────────────────────────────
-- All returned coordinates are ABSOLUTE screen X values.

function GitTimelineView:calculate_layout(view_width)
  local sf = self.small_font
  local ml = config.margin_left  * SCALE
  local mr = config.margin_right * SCALE
  local ph = config.pad_h        * SCALE

  local eff_cols  = math.min(self.total_columns, config.max_columns)
  local col_w     = config.col_w * SCALE
  local graph_w   = col_w * math.max(1, eff_cols)

  -- hash column: fixed width based on font
  local hash_w    = sf:get_width("a1b2c3d") + ph

  -- right-side columns (date, author) — only shown if room
  local date_w    = sf:get_width("12 months ago") + ph
  local author_w  = sf:get_width("W. Shakespeare") + ph  -- typical max

  local graph_abs_x = self.position.x + ml
  local hash_abs_x  = graph_abs_x + graph_w + ph
  local msg_abs_x   = hash_abs_x + hash_w

  -- remaining space after graph+hash
  local right_edge  = self.position.x + view_width - mr
  -- try to fit date column on right; author before it
  local date_abs_x   = right_edge - date_w
  local author_abs_x = date_abs_x - author_w

  -- message gets everything between msg_abs_x and author (or right_edge if no room)
  local msg_max_w
  local show_meta = (author_abs_x - msg_abs_x) > sf:get_width("short msg") * 2
  if show_meta then
    msg_max_w = author_abs_x - msg_abs_x - ph
  else
    msg_max_w = right_edge - msg_abs_x
    show_meta = false
  end
  msg_max_w = math.max(msg_max_w, 30 * SCALE)

  return {
    col_w        = col_w,
    eff_cols     = eff_cols,
    graph_abs_x  = graph_abs_x,
    hash_abs_x   = hash_abs_x,
    hash_w       = hash_w,
    msg_abs_x    = msg_abs_x,
    msg_max_w    = msg_max_w,
    show_meta    = show_meta,
    author_abs_x = author_abs_x,
    author_w     = author_w,
    date_abs_x   = date_abs_x,
    date_w       = date_w,
    right_edge   = right_edge,
  }
end

-- ─── Branch line drawing ──────────────────────────────────────────────────────

function GitTimelineView:draw_branch_line(x1, y1, x2, y2, color)
  local t    = math.max(1, config.line_thickness * SCALE)
  local c    = {color[1], color[2], color[3], 200}
  local half = t * 0.5

  if math.abs(x1 - x2) < 1 then
    renderer.draw_rect(math.floor(x1 - half), math.floor(y1),
                       math.ceil(t), math.ceil(y2 - y1), c)
  else
    -- elbow: vertical → horizontal → vertical
    local mid_y = math.floor(y1 + (y2 - y1) * 0.5)
    -- top vertical
    renderer.draw_rect(math.floor(x1 - half), math.floor(y1),
                       math.ceil(t), mid_y - math.floor(y1), c)
    -- horizontal bar
    local lx = math.floor(math.min(x1, x2) - half)
    local rw = math.ceil(math.abs(x2 - x1) + t)
    renderer.draw_rect(lx, math.floor(mid_y - half), rw, math.ceil(t), c)
    -- bottom vertical
    renderer.draw_rect(math.floor(x2 - half), mid_y,
                       math.ceil(t), math.ceil(y2 - mid_y), c)
  end
end

-- ─── Main draw ────────────────────────────────────────────────────────────────


function GitTimelineView:get_scrollable_size()
  if self.active_tab == 1 then
    return #self.commits * self.row_height + 20 * SCALE
  else
    local items = self.gh_items[self.active_tab - 1]
    local fh = math.floor(self.sf:get_height() * SCALE)
    local row_h = math.floor(fh * 2.4 + 6*SCALE)
    return #items * row_h + 20 * SCALE
  end
end

function GitTimelineView:draw()
  self:draw_background(style.background2 or style.background)
  local sf = self.sf
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y

  local title_h = math.floor((style.font:get_height() + 10) * SCALE)
  renderer.draw_rect(x, y, w, title_h, style.background3 or style.background)
  renderer.draw_text(style.font, "GIT", x + config.margin_left * SCALE, y + math.floor(5 * SCALE), style.accent or style.dim)

  -- Tab strip
  local tab_h = math.floor((sf:get_height() + 10) * SCALE)
  local tab_y = y + title_h
  local bg = style.background2 or style.background
  renderer.draw_rect(x, tab_y, w, tab_h, bg)
  
  self.tab_rects = {}
  local tx = x + 4*SCALE
  for i, label in ipairs(self.tabs) do
    local is_active = (i == self.active_tab)
    local tw = sf:get_width(label) + 16*SCALE
    local tab_bg = is_active and style.selection or bg
    local tab_fg = is_active and style.text or style.dim
    renderer.draw_rect(math.floor(tx), tab_y, math.ceil(tw), tab_h, tab_bg)
    if is_active then
      local accent = style.accent or {100, 180, 255, 255}
      renderer.draw_rect(math.floor(tx), tab_y + tab_h - 2*SCALE, math.ceil(tw), math.ceil(2*SCALE), accent)
    end
    renderer.draw_text(sf, label, math.floor(tx + 8*SCALE), tab_y + math.floor((tab_h - sf:get_height()*SCALE) * 0.5), tab_fg)
    table.insert(self.tab_rects, {x=tx, y=tab_y, w=tw, h=tab_h, idx=i})
    tx = tx + tw + 2*SCALE
  end
  
  local ref_w = sf:get_width("↺") + 12*SCALE
  local ref_x = x + w - ref_w - 4*SCALE
  renderer.draw_text(sf, "↺", math.floor(ref_x + 6*SCALE), tab_y + math.floor((tab_h - sf:get_height()*SCALE)*0.5), style.dim)
  self.refresh_rect = {x=ref_x, y=tab_y, w=ref_w, h=tab_h}

  local content_y = tab_y + tab_h
  local content_h = h - title_h - tab_h
  renderer.set_clip_rect(x, content_y, w, content_h)

  if self.active_tab == 1 then
    if self.loading then
      renderer.draw_text(sf, "Loading commits...", x + config.margin_left * SCALE, content_y + config.margin_top * SCALE, style.text)
    elseif self.error_msg then
      renderer.draw_text(sf, self.error_msg, x + config.margin_left * SCALE, content_y + config.margin_top * SCALE, {255, 100, 100, 255})
    elseif #self.commits == 0 then
      renderer.draw_text(sf, "No commits found.", x + config.margin_left * SCALE, content_y + config.margin_top * SCALE, style.dim)
    else
      if not self.cached_layout or self.last_width ~= w then
        self.cached_layout = self:calculate_layout(w)
        self.last_width = w
      end
      self:draw_commits(content_y, self.cached_layout)
    end
  else
    local gh_idx = self.active_tab - 1
    if self.gh_loading[gh_idx] then
      renderer.draw_text(sf, "Loading...", x + 12*SCALE, content_y + 12*SCALE, style.dim)
    elseif self.gh_error[gh_idx] then
      renderer.draw_text(sf, "Error:", x + 12*SCALE, content_y + 10*SCALE, {220,80,80,255})
      renderer.draw_text(sf, self.gh_error[gh_idx], x + 12*SCALE, content_y + 10*SCALE + sf:get_height()*SCALE + 4*SCALE, style.dim)
    else
      local items = self.gh_items[gh_idx]
      if #items == 0 then
        renderer.draw_text(sf, "No open " .. self.tabs[self.active_tab]:lower() .. " found.", x + 12*SCALE, content_y + 12*SCALE, style.dim)
      else
        self:draw_gh_items(items, gh_idx, x, content_y, w, content_h)
      end
    end
  end

  renderer.set_clip_rect(x, y, w, h)
  self:draw_scrollbar()
end

function GitTimelineView:draw_gh_items(items, gh_idx, x, content_y, w, content_h)
  local sf = self.sf
  local fh = math.floor(sf:get_height() * SCALE)
  local row_h = math.floor(fh * 2.4 + 6*SCALE)
  local pad = 10*SCALE
  self.gh_item_rects = {}

  for i, item in ipairs(items) do
    local iy = content_y + (i-1)*row_h - self.scroll.y
    if iy + row_h < content_y or iy > content_y + content_h then goto skip end

    if self.gh_hovered == i then
      renderer.draw_rect(x, iy, w, row_h, style.line_highlight or {255,255,255,15})
    end
    if i > 1 then
      renderer.draw_rect(x + pad, iy, w - pad*2, math.ceil(SCALE), style.divider or {255,255,255,20})
    end

    local state = item.state or "open"
    local sc = status_color(state)
    local badge_label = state:upper():sub(1,1) .. state:lower():sub(2)
    local badge_w = sf:get_width(badge_label) + 8*SCALE
    local badge_h = fh + 4*SCALE
    local badge_x = x + pad
    local badge_y = iy + math.floor((row_h - badge_h) * 0.5)
    renderer.draw_rect(math.floor(badge_x), math.floor(badge_y), math.ceil(badge_w), math.ceil(badge_h), {sc[1],sc[2],sc[3],50})
    renderer.draw_rect(math.floor(badge_x), math.floor(badge_y), math.ceil(badge_w), math.ceil(SCALE), sc)
    renderer.draw_rect(math.floor(badge_x), math.floor(badge_y+badge_h-SCALE), math.ceil(badge_w), math.ceil(SCALE), sc)
    renderer.draw_rect(math.floor(badge_x), math.floor(badge_y), math.ceil(SCALE), math.ceil(badge_h), sc)
    renderer.draw_rect(math.floor(badge_x+badge_w-SCALE), math.floor(badge_y), math.ceil(SCALE), math.ceil(badge_h), sc)
    renderer.draw_text(sf, badge_label, math.floor(badge_x+4*SCALE), math.floor(badge_y + (badge_h - fh)*0.5), sc)

    local num_str = "#" .. tostring(item.number or "?")
    local num_x = badge_x + badge_w + 8*SCALE
    renderer.draw_text(sf, num_str, math.floor(num_x), math.floor(iy + (row_h * 0.5) - fh * 1.05), style.dim)
    local num_w = sf:get_width(num_str)

    local date_str = time_ago(item.createdAt or "")
    local date_w = sf:get_width(date_str)
    renderer.draw_text(sf, date_str, math.floor(x + w - pad - date_w), math.floor(iy + (row_h*0.5) - fh*1.05), {style.dim[1] or 120, style.dim[2] or 120, style.dim[3] or 120, 140})

    if gh_idx == 2 and item.author then
      local auth = "@" .. (item.author or "")
      local auth_w = sf:get_width(auth)
      renderer.draw_text(sf, auth, math.floor(x + w - pad - math.max(date_w, auth_w) - 4*SCALE - sf:get_width(auth)), math.floor(iy + row_h*0.5 + fh*0.1), {style.dim[1] or 120, style.dim[2] or 120, style.dim[3] or 120, 180})
    end

    local title = item.title or "(no title)"
    local title_x = num_x + num_w + 6*SCALE
    local title_max_w = x + w - pad - date_w - 8*SCALE - title_x
    if title_max_w > 20*SCALE then
      local dots_w = sf:get_width("...")
      if sf:get_width(title) > title_max_w then
        local budget = title_max_w - dots_w
        while #title > 0 and sf:get_width(title) > budget do title = title:sub(1,-2) end
        title = title ~= "" and title .. "..." or ""
      end
    else
      title = ""
    end
    if title ~= "" then
      renderer.draw_text(sf, title, math.floor(title_x), math.floor(iy + (row_h*0.5) - fh*1.05), style.text)
    end

    if item.labels and item.labels ~= "" then
      local ly = math.floor(iy + row_h*0.5 + fh*0.1)
      local lx = num_x
      for lname in item.labels:gmatch('"name"%s*:%s*"([^"]+)"') do
        local lcolor_hex = item.labels:match('"color"%s*:%s*"([^"]+)"') or "888888"
        local lr = tonumber(lcolor_hex:sub(1,2),16) or 128
        local lg = tonumber(lcolor_hex:sub(3,4),16) or 128
        local lb = tonumber(lcolor_hex:sub(5,6),16) or 128
        local lw = sf:get_width(lname) + 6*SCALE
        if lx + lw < x + w - pad then
          renderer.draw_rect(math.floor(lx), ly, math.ceil(lw), math.ceil(fh), {lr,lg,lb,60})
          renderer.draw_text(sf, lname, math.floor(lx+3*SCALE), ly, {lr,lg,lb,220})
          lx = lx + lw + 4*SCALE
        end
      end
    end

    table.insert(self.gh_item_rects, {x=x, y=iy, w=w, h=row_h, item=item})
    ::skip::
  end
end



-- ─── Commit row rendering ─────────────────────────────────────────────────────

function GitTimelineView:draw_commits(start_y, layout)
  local sf = self.small_font

  local col_w      = layout.col_w
  local gx         = layout.graph_abs_x
  local eff_cols   = layout.eff_cols
  local rh         = self.row_height
  local font_h     = sf:get_height() * SCALE
  local mt         = config.margin_top * SCALE
  local ph         = config.pad_h * SCALE

  -- Dim color derived from style.dim — used for hash + meta
  local dim_c = style.dim

  for i, commit in ipairs(self.commits) do
    -- vertical center of this row
    local cy = start_y + mt + (i - 1) * rh + rh * 0.5 - self.scroll.y

    -- culling
    if cy + rh < self.position.y or cy - rh > self.position.y + self.size.y then
      goto continue
    end

    local dc = math.min(commit.column, eff_cols - 1)
    local cx = gx + dc * col_w

    -- ── branch lines to parents ──────────────────────────────────────────────
    for _, ph_hash in ipairs(commit.parents) do
      local parent = self:find_commit(ph_hash)
      if parent then
        local pdc = math.min(parent.column, eff_cols - 1)
        local px  = gx + pdc * col_w
        local py  = start_y + mt + (parent.row_index - 1) * rh + rh * 0.5 - self.scroll.y
        self:draw_branch_line(cx, cy, px, py, commit.color)
      end
    end

    -- ── commit node ───────────────────────────────────────────────────────────
    local ns  = config.node_size * SCALE
    local ns2 = ns * 0.5
    -- draw a small filled diamond / circle (rect approximation)
    if #commit.parents > 1 then
      -- merge: wider pill
      renderer.draw_rect(math.floor(cx - ns), math.floor(cy - ns2),
                         math.ceil(ns * 2), math.ceil(ns), commit.color)
    else
      renderer.draw_rect(math.floor(cx - ns2), math.floor(cy - ns2),
                         math.ceil(ns), math.ceil(ns), commit.color)
    end

    -- ── text baseline ─────────────────────────────────────────────────────────
    local ty = math.floor(cy - font_h * 0.5)

    -- ── branch badges (BEFORE message, like VS Code) ──────────────────────────
    local tx = layout.msg_abs_x
    local branches = self:parse_branches(commit.refs)
    for _, branch in ipairs(branches) do
      local label    = branch.name
      local lw       = sf:get_width(label)
      local badge_w  = lw + config.pad_h * SCALE
      local badge_h  = math.ceil(font_h + config.pad_v * 2 * SCALE)
      local badge_y  = math.floor(cy - badge_h * 0.5)

      -- clip badges to not eat all message space
      if tx + badge_w > layout.msg_abs_x + layout.msg_max_w * 0.45 then break end

      local bg = branch.is_head and commit.color
        or {style.dim[1] or 110, style.dim[2] or 110, style.dim[3] or 110, 170}
      renderer.draw_rect(math.floor(tx), badge_y,
                         math.ceil(badge_w), badge_h, bg)
      renderer.draw_text(sf, label,
                         math.floor(tx + config.pad_h * 0.5 * SCALE),
                         ty, {255, 255, 255, 255})
      tx = tx + badge_w + math.floor(ph * 0.5)
    end

    -- ── commit message ────────────────────────────────────────────────────────
    local msg_x   = tx
    local msg_budget = layout.msg_abs_x + layout.msg_max_w - msg_x
    local msg = commit.message
    if msg_budget > 0 and msg ~= "" then
      local dots_w = sf:get_width("...")
      if sf:get_width(msg) > msg_budget then
        local budget = msg_budget - dots_w
        if budget > 0 then
          while #msg > 0 and sf:get_width(msg) > budget do
            msg = msg:sub(1, -2)
          end
          msg = (msg ~= "") and (msg .. "...") or ""
        else
          msg = ""
        end
      end
      if msg ~= "" then
        renderer.draw_text(sf, msg, math.floor(msg_x), ty, style.text)
      end
    end

    -- ── short hash (after graph, before badges) ───────────────────────────────
    -- Drawn at hash_abs_x in a very dim/muted color — exactly like VS Code
    renderer.draw_text(sf, commit.short_hash,
                       math.floor(layout.hash_abs_x), ty,
                       {dim_c[1] or 120, dim_c[2] or 120, dim_c[3] or 120, 160})

    -- ── author & date (right-aligned columns) ────────────────────────────────
    if layout.show_meta then
      -- author: truncate to column width
      local author = commit.author
      if sf:get_width(author) > layout.author_w - ph then
        while #author > 0 and sf:get_width(author .. "…") > layout.author_w - ph do
          author = author:sub(1, -2)
        end
        if author ~= "" then author = author .. "…" end
      end
      renderer.draw_text(sf, author,
                         math.floor(layout.author_abs_x), ty,
                         {dim_c[1] or 120, dim_c[2] or 120, dim_c[3] or 120, 180})

      -- date
      local date = commit.date
      renderer.draw_text(sf, date,
                         math.floor(layout.date_abs_x), ty,
                         {dim_c[1] or 120, dim_c[2] or 120, dim_c[3] or 120, 140})
    end

    ::continue::
  end
end

-- ─── Helpers ──────────────────────────────────────────────────────────────────

function GitTimelineView:find_commit(hash)
  for _, c in ipairs(self.commits) do
    if c.hash == hash then return c end
  end
  return nil
end



function GitTimelineView:open_in_editor(item, is_pr)
  local Doc = require "core.doc"
  local doc = Doc()
  local title = (is_pr and "PR #" or "Issue #") .. tostring(item.number) .. ".md"
  doc.filename = title
  doc.abs_filename = title
  doc:insert(1, 1, "Loading " .. title .. "...\n")
  doc:clean()
  
  pcall(function()
    local syntax = require "plugins.syntax"
    local syn = syntax.get("dummy.md")
    if syn then doc.syntax = syn end
  end)
  
  table.insert(core.docs, doc)
  local MarkdownView = require "plugins.markdown_view"
  local view = MarkdownView(doc)
  local node = core.root_view:get_primary_node()
  node:add_view(view)
  
  local p_dir = core.project_dir or ""
  local cmd_type = is_pr and "pr" or "issue"
  
  core.add_thread(function()
    local tpl = "# {{.title}} (#{{.number}})\n**Status:** {{.state}} | **Author:** @{{.author.login}} | **Created:** {{timeago .createdAt}}\n**URL:** {{.url}}\n\n---\n\n{{if .body}}{{.body}}{{else}}*No description provided.*{{end}}\n\n---\n## Comments\n{{range .comments}}\n**@{{.author.login}}** ({{timeago .createdAt}})\n{{.body}}\n\n{{end}}"
    local cmd = {"gh", cmd_type, "view", tostring(item.number), 
                 "--json", "title,number,state,author,createdAt,url,body,comments",
                 "--template", tpl}
    if core.active_codespace then
      local safe = "'" .. table.concat(cmd, " "):gsub("'", "'\\''") .. "'"
      cmd = {"gh", "cs", "ssh", "-c", core.active_codespace.name, "--", "sh", "-c", safe}
    end
    
    local p = process.start(cmd, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE, cwd = p_dir ~= "" and p_dir or nil })
    if not p then return end
    
    local out = ""
    while p:returncode() == nil do
      out = out .. (p:read_stdout(8192) or "")
      coroutine.yield(0.05)
    end
    while true do local c = p:read_stdout(8192) or ""; if c == "" then break end; out = out .. c end
    
    out = out:gsub("\x1b%[[%d;]*[a-zA-Z]", "")
    if out == "" then out = "Failed to load content." end
    
    doc:remove(1, 1, math.huge, math.huge)
    doc:insert(1, 1, out)
    doc:clean()
    core.redraw = true
  end)
end

function GitTimelineView:on_mouse_pressed(button, mx, my, clicks)
  if button ~= "left" then return end
  
  for _, tr in ipairs(self.tab_rects or {}) do
    if mx >= tr.x and mx < tr.x+tr.w and my >= tr.y and my < tr.y+tr.h then
      if self.active_tab ~= tr.idx then
        self.scroll_pos[self.active_tab] = self.scroll.y
        self.active_tab = tr.idx
        self.scroll.y = self.scroll_pos[self.active_tab] or 0
        core.redraw = true
      end
      return true
    end
  end

  local rr = self.refresh_rect
  if rr and mx >= rr.x and mx < rr.x+rr.w and my >= rr.y and my < rr.y+rr.h then
    if self.active_tab == 1 then
      self:update_commits()
    else
      self:fetch_gh(self.active_tab - 1)
    end
    return true
  end

  if self.active_tab > 1 and clicks >= 1 then
    for _, ir in ipairs(self.gh_item_rects or {}) do
      if mx >= ir.x and mx < ir.x+ir.w and my >= ir.y and my < ir.y+ir.h then
        if ir.item.number then
          self:open_in_editor(ir.item, self.active_tab == 3)
        end
        return true
      end
    end
  end
  
  return GitTimelineView.super.on_mouse_pressed(self, button, mx, my, clicks)
end

function GitTimelineView:on_mouse_moved(mx, my, dx, dy)
  if self.active_tab > 1 then
    local prev = self.gh_hovered
    self.gh_hovered = nil
    for i, ir in ipairs(self.gh_item_rects or {}) do
      if mx >= ir.x and mx < ir.x+ir.w and my >= ir.y and my < ir.y+ir.h then
        self.gh_hovered = i
        break
      end
    end
    if self.gh_hovered ~= prev then core.redraw = true end
  end
  return GitTimelineView.super.on_mouse_moved(self, mx, my, dx, dy)
end

-- ─── Commands ─────────────────────────────────────────────────────────────────

local timeline_view = nil

command.add(nil, {
  ["git-timeline:toggle"] = function()
    if timeline_view then
      local node = core.root_view.root_node:get_node_for_view(timeline_view)
      if node then node:close_view(core.root_view.root_node, timeline_view) end
      timeline_view = nil
    else
      timeline_view = GitTimelineView()
      local node = core.root_view.root_node:get_node_for_view(treeview)
      if node then
        -- locked={y=true} marks this as a locked sidebar section so
        -- get_active_node_default() never routes other panels into it.
        node:split("down", timeline_view, { y = true }, true)
      else
        core.root_view:get_primary_node():split("down", timeline_view, { y = true }, true)
      end
    end
  end,
  ["git-timeline:refresh"] = function()
    if timeline_view then timeline_view:update_commits() end
  end,
})

-- ─── Status bar item ──────────────────────────────────────────────────────────

return {
  name        = "Git Timeline",
  description = "A VS Code-style git graph and commit history viewer.",
  version     = "2.0",
}
