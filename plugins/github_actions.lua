-- mod-version:3
-- GitHub Actions & Insights panels — injected into the terminal bottom sheet
-- Adds "Actions" and "Insights" tabs alongside the existing terminal sessions.
-- Clicking those tabs replaces the terminal content area with GitHub data.
-- Shell sessions are untouched; switching back to any shell tab restores the terminal.

local core    = require "core"
local command = require "core.command"
local style   = require "core.style"
local process = require "process"
local common  = require "core.common"

-- ─── Tiny JSON helpers ────────────────────────────────────────────────────────

local function parse_json_array(text)
  local items = {}
  -- gh outputs arrays of objects; extract each { ... }
  -- We use a greedy approach: find balanced braces
  local depth, start = 0, nil
  for i = 1, #text do
    local c = text:byte(i)
    if c == 123 then  -- '{'
      depth = depth + 1
      if depth == 1 then start = i end
    elseif c == 125 then  -- '}'
      depth = depth - 1
      if depth == 0 and start then
        local obj_str = text:sub(start, i)
        local item = {}
        for k, v in obj_str:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
          item[k] = v
        end
        for k, v in obj_str:gmatch('"([^"]+)"%s*:%s*(-?%d+)') do
          if not item[k] then item[k] = tonumber(v) end
        end
        if next(item) then table.insert(items, item) end
        start = nil
      end
    end
  end
  return items
end

local function luminance(r,g,b) return r*.299+g*.587+b*.114 end
local function contrast_bg(base)
  if type(base)~="table" then return base end
  local r,g,b,a=base[1],base[2],base[3],base[4] or 255
  if luminance(r,g,b)>128 then
    return{math.max(0,math.floor(r*.92)),math.max(0,math.floor(g*.92)),math.max(0,math.floor(b*.92)),a}
  else
    return{math.min(255,math.floor(r+(255-r)*.08)),math.min(255,math.floor(g+(255-g)*.08)),math.min(255,math.floor(b+(255-b)*.08)),a}
  end
end

local function small_font()
  local ok,f=pcall(function()
    return renderer.font.load(
      style.code_font:get_path(),
      math.max(8,math.floor(style.code_font:get_size()*.82)),
      {antialiasing="subpixel",hinting="slight"})
  end)
  return (ok and f) or style.code_font
end

-- ─── Shared state ─────────────────────────────────────────────────────────────

-- Panel IDs (terminals use positive integers as session indices)
local PANEL_ACTIONS  = "actions"
local PANEL_INSIGHTS = "insights"

local gh_state = {
  -- active extra panel or nil (means show terminal session)
  active_panel   = nil,

  -- Actions data
  actions_items  = {},
  actions_loading= false,
  actions_error  = nil,
  actions_scroll = 0,
  actions_tab_rects = {},

  -- Insights data  
  insights       = nil,  -- { stars, forks, watchers, open_issues, language, description }
  contrib_items  = {},   -- top contributors
  insights_loading = false,
  insights_error  = nil,
  insights_scroll = 0,
  -- rate limiting
  last_actions_refresh = 0,
  last_insights_refresh = 0,

  sf = nil,   -- small font (lazy init)

  -- extra tab button rects (drawn by our hook into TermView:draw)
  extra_tab_rects = {},
}

local function get_sf()
  if not gh_state.sf then gh_state.sf = small_font() end
  return gh_state.sf
end

-- ─── Data fetching ────────────────────────────────────────────────────────────

local function run_gh(args, callback)
  local p_dir = core.project_dir or ""
  core.add_thread(function()
    local p = process.start(args, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      cwd    = p_dir ~= "" and p_dir or nil,
    })
    if not p then callback(nil, "Failed to start gh") return end

    local out, err = "", ""
    while p:returncode() == nil do
      out = out .. (p:read_stdout(4096) or "")
      err = err .. (p:read_stderr(4096) or "")
      coroutine.yield(0.05)
    end
    while true do local c=p:read_stdout(4096) or ""; if c==""then break end; out=out..c end
    while true do local c=p:read_stderr(4096) or ""; if c==""then break end; err=err..c end

    if p:returncode() ~= 0 then
      callback(nil, err:match("%S") and err:gsub("[\r\n]+"," ") or "gh error")
    else
      callback(out, nil)
    end
  end)
end

local function fetch_actions()
  if gh_state.actions_loading then return end
  if os.time() - gh_state.last_actions_refresh < 3 then return end
  gh_state.last_actions_refresh = os.time()
  gh_state.actions_loading = true
  gh_state.actions_error   = nil
  core.redraw = true

  run_gh(
    {"gh", "run", "list",
     "--json", "databaseId,displayTitle,status,conclusion,workflowName,headBranch,createdAt",
     "--limit", "30"},
    function(out, err)
      gh_state.actions_loading = false
      if err then
        if err:match("HTTP 404") then
          gh_state.actions_error = "No GitHub Actions found for this repository."
        else
          gh_state.actions_error = err
        end
      else
        gh_state.actions_items = parse_json_array(out or "")
      end
      core.redraw = true
    end
  )
end

local function fetch_insights()
  if gh_state.insights_loading then return end
  if os.time() - gh_state.last_insights_refresh < 5 then return end
  gh_state.last_insights_refresh = os.time()
  gh_state.insights_loading = true
  gh_state.insights_error   = nil
  core.redraw = true

  -- Fetch repo info
  run_gh(
    {"gh", "repo", "view",
     "--json", "name,description,stargazerCount,forkCount,watchers,primaryLanguage,url"},
    function(out, err)
      if err then
        gh_state.insights_error   = err
        gh_state.insights_loading = false
        core.redraw = true
        return
      end
      -- Parse single object
      local info = {}
      if out then
        for k,v in out:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do info[k]=v end
        for k,v in out:gmatch('"([^"]+)"%s*:%s*(-?%d+)') do if not info[k] then info[k]=tonumber(v) end end
        -- primaryLanguage is nested: {"name":"Lua"}
        info.language = out:match('"primaryLanguage"%s*:%s*{[^}]*"name"%s*:%s*"([^"]+)"') or "—"
      end
      gh_state.insights = info

      -- Now fetch top contributors
      run_gh(
        {"gh", "api", "repos/{owner}/{repo}/contributors",
         "--paginate", "--jq", ".[0:10] | .[] | {login:.login, contributions:.contributions}"},
        function(cout, cerr)
          gh_state.insights_loading = false
          if not cerr and cout then
            -- Output is NDJSON lines of {login:..., contributions:...}
            gh_state.contrib_items = {}
            for line in cout:gmatch("[^\r\n]+") do
              local item = {}
              for k,v in line:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do item[k]=v end
              for k,v in line:gmatch('"([^"]+)"%s*:%s*(-?%d+)') do if not item[k] then item[k]=tonumber(v) end end
              if item.login then table.insert(gh_state.contrib_items, item) end
            end
          end
          core.redraw = true
        end
      )
    end
  )
end

-- ─── Status/conclusion colors ─────────────────────────────────────────────────

local function conclusion_color(conclusion, status)
  status     = (status or ""):lower()
  conclusion = (conclusion or ""):lower()
  if status == "in_progress" or status == "queued" or status == "waiting" then
    return {255, 200, 60, 255}   -- yellow: running
  end
  if conclusion == "success"   then return {80, 200, 120, 255}  end  -- green
  if conclusion == "failure"   then return {220, 80,  80, 255}  end  -- red
  if conclusion == "cancelled" then return {160, 160, 160, 255} end  -- grey
  if conclusion == "skipped"   then return {120, 120, 120, 200} end
  return style.dim or {160, 160, 160, 255}
end

local function status_icon(conclusion, status)
  status     = (status or ""):lower()
  conclusion = (conclusion or ""):lower()
  if status == "in_progress" then return "⟳" end
  if status == "queued"      then return "…" end
  if conclusion == "success"   then return "✓" end
  if conclusion == "failure"   then return "✗" end
  if conclusion == "cancelled" then return "⊘" end
  return "○"
end

local function fmt_date(iso)
  if not iso or iso == "" then return "" end
  return iso:match("^(%d+%-%d+%-%d+)") or iso
end

-- ─── Panel rendering ──────────────────────────────────────────────────────────

local function draw_actions_panel(x, y, w, h)
  local sf   = get_sf()
  local fh   = math.floor(sf:get_height())
  local row_h= math.floor(fh * 1.8 + 4*SCALE)
  local pad  = 10*SCALE
  local base = style.background or {30,30,30,255}
  local bg   = contrast_bg(base)
  local hdr_bg = contrast_bg(bg)

  renderer.draw_rect(x, y, w, h, bg)

  if gh_state.actions_loading then
    renderer.draw_text(sf, "Fetching workflow runs...", x+pad, y+pad, style.dim)
    return
  end
  if gh_state.actions_error then
    renderer.draw_text(sf, "Error: " .. gh_state.actions_error, x+pad, y+pad, {220,80,80,255})
    renderer.draw_text(sf, "(Is gh authenticated? Run: gh auth login)", x+pad, y+pad+fh+4*SCALE, style.dim)
    return
  end

  local items = gh_state.actions_items
  if #items == 0 then
    renderer.draw_text(sf, "No workflow runs found.", x+pad, y+pad, style.dim)
    return
  end

  core.push_clip_rect(x, y, w, h)

  local oy = y - gh_state.actions_scroll

  for i, run in ipairs(items) do
    local ry = oy + (i-1) * row_h
    if ry + row_h < y or ry > y + h then goto skip end

    -- row bg on hover
    if gh_state.actions_hover == i then
      renderer.draw_rect(x, ry, w, row_h, {255,255,255,10})
    end

    -- divider
    if i > 1 then
      renderer.draw_rect(x+pad, ry, w-pad*2, math.ceil(SCALE), {255,255,255,15})
    end

    -- Status icon + color
    local c   = conclusion_color(run.conclusion, run.status)
    local ico = status_icon(run.conclusion, run.status)
    local ico_y = math.floor(ry + (row_h - fh)*0.5)
    renderer.draw_text(sf, ico, x+pad, ico_y, c)
    local ico_w = sf:get_width(ico) + 8*SCALE

    -- Workflow name (dim, small)
    local wf_name = run.workflowName or "Workflow"
    local wf_w    = sf:get_width(wf_name)
    renderer.draw_text(sf, wf_name, x+pad+ico_w, ico_y, style.dim)

    -- Run title (main)
    local title = run.displayTitle or run.name or "Run"
    local title_x = x+pad+ico_w+wf_w+8*SCALE
    local date_str = fmt_date(run.createdAt or "")
    local date_w   = sf:get_width(date_str)
    local title_max = x+w-pad-date_w-8*SCALE - title_x
    if title_max > 20*SCALE then
      local dots_w = sf:get_width("...")
      if sf:get_width(title) > title_max then
        local bud = title_max - dots_w
        while #title>0 and sf:get_width(title)>bud do title=title:sub(1,-2) end
        title = title~="" and title.."..." or ""
      end
      renderer.draw_text(sf, title, title_x, ico_y, style.text)
    end

    -- Branch (second line)
    local branch = run.headBranch or ""
    if branch ~= "" then
      local branch_y = ry + math.floor(row_h*0.5 + fh*0.1)
      renderer.draw_text(sf, " " .. branch, x+pad+ico_w, branch_y,
        {style.dim[1] or 120, style.dim[2] or 120, style.dim[3] or 120, 180})
    end

    -- Date
    renderer.draw_text(sf, date_str, x+w-pad-date_w, ico_y,
      {style.dim[1] or 120, style.dim[2] or 120, style.dim[3] or 120, 140})

    -- Conclusion badge
    local badge = (run.conclusion or run.status or "pending"):upper()
    badge = badge:gsub("_"," ")
    local badge_w = sf:get_width(badge) + 8*SCALE
    local badge_x = x+w-pad-date_w-badge_w-8*SCALE
    local badge_y2 = math.floor(ry + (row_h - fh - 4*SCALE)*0.5)
    renderer.draw_rect(math.floor(badge_x), badge_y2, math.ceil(badge_w), math.ceil(fh+4*SCALE), {c[1],c[2],c[3],40})
    renderer.draw_text(sf, badge, math.floor(badge_x+4*SCALE), math.floor(badge_y2+2*SCALE), c)

    ::skip::
  end

  core.pop_clip_rect()

  -- Scroll clamp
  local total_h = #items * row_h
  local max_s   = math.max(0, total_h - h)
  gh_state.actions_scroll = math.max(0, math.min(gh_state.actions_scroll, max_s))
end

local function draw_stat_card(x, y, w, h, label, value, color, sf, fh)
  local bg = contrast_bg(contrast_bg(style.background or {30,30,30,255}))
  renderer.draw_rect(math.floor(x), math.floor(y), math.ceil(w), math.ceil(h), bg)
  -- top accent bar
  renderer.draw_rect(math.floor(x), math.floor(y), math.ceil(w), math.ceil(3*SCALE), color)
  -- value (big)
  local val_str = tostring(value or "—")
  local val_w   = sf:get_width(val_str)
  renderer.draw_text(sf, val_str,
    math.floor(x + (w - val_w)*0.5),
    math.floor(y + h*0.3),
    color)
  -- label (small dim)
  local lbl_w = sf:get_width(label)
  renderer.draw_text(sf, label,
    math.floor(x + (w - lbl_w)*0.5),
    math.floor(y + h*0.6),
    style.dim)
end

local function draw_insights_panel(x, y, w, h)
  local sf  = get_sf()
  local fh  = math.floor(sf:get_height())
  local pad = 10*SCALE
  local base= style.background or {30,30,30,255}
  local bg  = contrast_bg(base)

  renderer.draw_rect(x, y, w, h, bg)

  if gh_state.insights_loading then
    renderer.draw_text(sf, "Fetching repository insights...", x+pad, y+pad, style.dim)
    return
  end
  if gh_state.insights_error then
    renderer.draw_text(sf, "Error: " .. gh_state.insights_error, x+pad, y+pad, {220,80,80,255})
    renderer.draw_text(sf, "(Run: gh auth login)", x+pad, y+pad+fh+4*SCALE, style.dim)
    return
  end
  if not gh_state.insights then
    renderer.draw_text(sf, "No data.", x+pad, y+pad, style.dim)
    return
  end

  core.push_clip_rect(x, y, w, h)

  local info = gh_state.insights
  local cy   = y + pad - gh_state.insights_scroll

  -- Repo name + description
  local name = info.name or "Repository"
  renderer.draw_text(sf, name, x+pad, cy, style.text)
  cy = cy + fh + 4*SCALE
  if info.description and info.description ~= "" then
    -- word-wrap description
    local words = {}; for w in info.description:gmatch("%S+") do table.insert(words,w) end
    local line = ""; local max_w = w - pad*2
    for _, word in ipairs(words) do
      local test = line ~= "" and (line.." "..word) or word
      if sf:get_width(test) > max_w then
        if line ~= "" then
          renderer.draw_text(sf, line, x+pad, cy, style.dim)
          cy = cy + fh + 2*SCALE
        end
        line = word
      else
        line = test
      end
    end
    if line ~= "" then
      renderer.draw_text(sf, line, x+pad, cy, style.dim)
      cy = cy + fh + 2*SCALE
    end
  end
  cy = cy + 8*SCALE

  -- Stat cards row
  local card_gap  = 6*SCALE
  local n_cards   = 4
  local card_w    = math.floor((w - pad*2 - card_gap*(n_cards-1)) / n_cards)
  local card_h    = math.floor(fh * 3.5)
  local colors    = {
    {100, 200, 255, 255},  -- stars: blue
    {100, 220, 100, 255},  -- forks: green
    {255, 180,  50, 255},  -- watchers: orange
    {220, 100, 220, 255},  -- issues: purple
  }
  local cards = {
    {label="Stars",      value=info.stargazerCount},
    {label="Forks",      value=info.forkCount},
    {label="Watchers",   value=info.watchers},
  }
  for i, card in ipairs(cards) do
    local cx2 = x + pad + (i-1)*(card_w + card_gap)
    draw_stat_card(cx2, cy, card_w, card_h, card.label, card.value, colors[i], sf, fh)
  end
  cy = cy + card_h + 12*SCALE

  -- Language
  renderer.draw_text(sf, "Primary Language: " .. (info.language or "—"), x+pad, cy, style.text)
  cy = cy + fh + 10*SCALE

  -- Top contributors
  renderer.draw_text(sf, "Top Contributors", x+pad, cy, style.accent or style.text)
  cy = cy + fh + 6*SCALE

  -- Simple bar chart of contributions
  local contribs = gh_state.contrib_items
  if #contribs == 0 then
    renderer.draw_text(sf, "(Loading contributors...)", x+pad, cy, style.dim)
  else
    local max_c = 1
    for _, c in ipairs(contribs) do
      if (c.contributions or 0) > max_c then max_c = c.contributions end
    end
    local bar_h = math.floor(fh * 0.7)
    local name_w = math.floor(w * 0.28)
    local count_w= math.floor(w * 0.12)
    local bar_max= w - pad*2 - name_w - count_w - 8*SCALE
    local bar_color = style.accent or {100, 180, 255, 255}

    for _, c in ipairs(contribs) do
      if cy > y + h then break end
      local login = c.login or "unknown"
      local contr = c.contributions or 0
      renderer.draw_text(sf, "@" .. login, x+pad, cy, style.text)
      local bar_w2 = math.floor(bar_max * contr / max_c)
      local bar_x  = x+pad+name_w
      renderer.draw_rect(bar_x, cy+math.floor((fh-bar_h)*0.5),
                         math.max(2*SCALE, bar_w2), bar_h,
                         {bar_color[1],bar_color[2],bar_color[3],180})
      renderer.draw_text(sf, tostring(contr),
        bar_x + bar_max + 4*SCALE, cy, style.dim)
      cy = cy + fh + 4*SCALE
    end
  end

  core.pop_clip_rect()

  -- Scroll clamp
  local total_content = cy - (y - gh_state.insights_scroll) + pad
  local max_s = math.max(0, total_content - h)
  gh_state.insights_scroll = math.max(0, math.min(gh_state.insights_scroll, max_s))
end

-- ─── Hook into TermView:draw ──────────────────────────────────────────────────
-- We patch the TermView after it loads so we can inject our tabs and panels.

core.add_thread(function()
  -- Wait until toggle_terminal has loaded and 'instance' is accessible
  -- We hook via the module's TermView class
  coroutine.yield(0.5)

  -- Find TermView by inspecting loaded modules through core.root_view
  -- Strategy: hook into the draw method of whatever view is the terminal
  -- We detect it by get_name() == "Terminal"

  local function inject_into_term(term_view)
    local TermClass = getmetatable(term_view).__index
    if not TermClass or TermClass._gh_actions_injected then return end
    TermClass._gh_actions_injected = true

    -- Patch draw at the class level (affects all instances)
    local orig_class_draw = TermClass.draw

    TermClass.draw = function(self)
      -- Draw the terminal normally first (handles its own header with session tabs)
      orig_class_draw(self)

      if self.size.y < 2 then return end

      -- Inject extra tabs into the header strip
      local base   = style.background or {255,255,255,255}
      local hdr_bg = base -- Match the newly updated terminal header!
      local bg     = contrast_bg(base)
      local hdr_h  = 26 * SCALE
      local x, y   = self.position.x, self.position.y
      local w, h   = self.size.x, self.size.y
      local sf     = get_sf()

      -- Find where session tabs end
      local tabs_end_x = x + 160 * SCALE
      if self.ports_tab_rect then
        tabs_end_x = math.max(tabs_end_x, self.ports_tab_rect.x + self.ports_tab_rect.w + 10 * SCALE)
      elseif self.terminal_tab_rect then
        tabs_end_x = math.max(tabs_end_x, self.terminal_tab_rect.x + self.terminal_tab_rect.w + 10 * SCALE)
      end
      if self.tab_rects and #self.tab_rects > 0 then
        local last = self.tab_rects[#self.tab_rects]
        tabs_end_x = math.max(tabs_end_x, last.x + last.w + 2*SCALE)
      end

      -- Draw separator before extra tabs
      local sep_x = tabs_end_x
      renderer.draw_rect(math.floor(sep_x), y + 2*SCALE + 4*SCALE,
                         math.ceil(SCALE), math.ceil(hdr_h - 8*SCALE),
                         {255,255,255,30})
      local cur_x = sep_x + 4*SCALE

      self._gh_extra_tab_rects = {}

      local extra_tabs = {
        {id=PANEL_INSIGHTS, label="Insights", icon=""},
        {id=PANEL_ACTIONS,  label="Actions",  icon=""},
      }
      
      -- Anchor from the rightmost buttons
      local right_edge = x + w - 80 * SCALE
      if self.right_btns and #self.right_btns > 0 then
        right_edge = self.right_btns[#self.right_btns].x
      elseif self.btn_rect then
        right_edge = self.btn_rect.x
      end
      local cur_x = right_edge - 12 * SCALE

      for _, tab in ipairs(extra_tabs) do
        local is_active = (gh_state.active_panel == tab.id)
        local icon_w = style.icon_font:get_width(tab.icon)
        local lbl_w = icon_w + sf:get_width(tab.label) + 14*SCALE
        
        cur_x = cur_x - lbl_w - 2*SCALE
        
        local tab_fg = is_active and (style.mossy and style.mossy.terminal_text or style.text) or style.dim
        
        -- Draw active underline (no background box!)
        if is_active then
          local ac = style.accent or {100,180,255,255}
          renderer.draw_rect(math.floor(cur_x), y + hdr_h - 2*SCALE, math.ceil(lbl_w), math.ceil(2*SCALE), ac)
        end
        
        -- Draw icon
        renderer.draw_text(style.icon_font, tab.icon,
          math.floor(cur_x + 5*SCALE),
          y + math.floor((hdr_h - style.icon_font:get_height())*0.5),
          tab_fg)
          
        -- Draw label
        renderer.draw_text(sf, tab.label,
          math.floor(cur_x + 5*SCALE + icon_w + 4*SCALE),
          y + math.floor((hdr_h - sf:get_height())*0.5),
          tab_fg)
          
        table.insert(self._gh_extra_tab_rects, {
          x=cur_x, y=y, w=lbl_w, h=hdr_h, id=tab.id
        })
      end

      -- If an extra panel is active, OVERDRAW the content area
      if gh_state.active_panel then
        local out_top = y + hdr_h + 3*SCALE
        local out_h   = h - hdr_h - 3*SCALE
        if out_h > 4 then
          if gh_state.active_panel == PANEL_ACTIONS then
            draw_actions_panel(x, out_top, w, out_h)
          elseif gh_state.active_panel == PANEL_INSIGHTS then
            draw_insights_panel(x, out_top, w, out_h)
          end
        end
      end
    end

    -- Patch on_mouse_pressed at class level
    local orig_mouse_press = TermClass.on_mouse_pressed
    TermClass.on_mouse_pressed = function(self, button, mx, my, clicks)
      -- Check extra tabs first
      if button == "left" then
        for _, tr in ipairs(self._gh_extra_tab_rects or {}) do
          if mx>=tr.x and mx<tr.x+tr.w and my>=tr.y and my<tr.y+tr.h then
            if gh_state.active_panel == tr.id then
              -- Toggle off → back to terminal
              gh_state.active_panel = nil
            else
              gh_state.active_panel = tr.id
              if tr.id == PANEL_ACTIONS and #gh_state.actions_items == 0 then
                fetch_actions()
              end
              if tr.id == PANEL_INSIGHTS and not gh_state.insights then
                fetch_insights()
              end
            end
            core.redraw = true
            return true
          end
        end
        -- If a session tab is clicked while extra panel is active, close panel
        if gh_state.active_panel then
          local clicked_tab = false
          if self.terminal_tab_rect and mx >= self.terminal_tab_rect.x and mx < self.terminal_tab_rect.x + self.terminal_tab_rect.w and my >= self.terminal_tab_rect.y and my < self.terminal_tab_rect.y + self.terminal_tab_rect.h then
            clicked_tab = true
          end
          if self.ports_tab_rect and mx >= self.ports_tab_rect.x and mx < self.ports_tab_rect.x + self.ports_tab_rect.w and my >= self.ports_tab_rect.y and my < self.ports_tab_rect.y + self.ports_tab_rect.h then
            clicked_tab = true
          end
          for _, sess in ipairs(self.sessions or {}) do
            if sess.tab_rect and mx >= sess.tab_rect.x and mx < sess.tab_rect.x + sess.tab_rect.w and my >= sess.tab_rect.y and my < sess.tab_rect.y + sess.tab_rect.h then
              clicked_tab = true
              break
            end
          end
          if clicked_tab then
            gh_state.active_panel = nil
            core.redraw = true
            -- intentionally do not return true so that the terminal's native handler can process the tab switch!
          end
        end
      end
      -- If extra panel is active, swallow scroll/interaction in content area
      if gh_state.active_panel then
        local hdr_h  = 26 * SCALE
        local out_top= self.position.y + hdr_h + 3*SCALE
        
        if button == "left" and gh_state.active_panel == PANEL_ACTIONS and my >= out_top then
          local sf = get_sf()
          local fh = math.floor(sf:get_height())
          local row_h = math.floor(fh * 2.4 + 6*SCALE)
          local run_idx = math.floor((my + gh_state.actions_scroll - out_top) / row_h) + 1
          if run_idx >= 1 and run_idx <= #gh_state.actions_items then
            local run = gh_state.actions_items[run_idx]
            if run and run.databaseId then
              local Doc = require "core.doc"
              local doc = Doc()
              local title = "Run #" .. tostring(run.databaseId) .. ".log"
              doc.filename = title
              doc.abs_filename = title
              doc:insert(1, 1, "Loading action log for " .. title .. "...\n")
              doc:clean()
              table.insert(core.docs, doc)
              local MarkdownView = require "plugins.markdown_view"
              local view = MarkdownView(doc)
              local node = core.root_view:get_primary_node()
              node:add_view(view)
              
              local p_dir = core.project_dir or ""
              core.add_thread(function()
                local cmd = {"gh", "run", "view", tostring(run.databaseId)}
                if core.active_codespace then
                  local safe = "'" .. table.concat(cmd, " "):gsub("'", "'\\''") .. "'"
                  cmd = {"gh", "cs", "ssh", "-c", core.active_codespace.name, "--", "sh", "-c", safe}
                end
                local p = process.start(cmd, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE, cwd = p_dir ~= "" and p_dir or nil })
                if p then
                  local out = ""
                  while p:returncode() == nil do
                    out = out .. (p:read_stdout(8192) or "")
                    coroutine.yield(0.05)
                  end
                  while true do local c = p:read_stdout(8192) or ""; if c == "" then break end; out = out .. c end
                  out = out:gsub("\x1b%[[%d;]*[a-zA-Z]", "")
                  if out == "" then out = "Failed to load action log." end
                  doc:remove(1, 1, math.huge, math.huge)
                  doc:insert(1, 1, out)
                  doc:clean()
                  core.redraw = true
                end
              end)
            end
          end
        end

        if my >= out_top then
          return true  -- don't let terminal handle it
        end
      end
      return orig_mouse_press and orig_mouse_press(self, button, mx, my, clicks)
    end

    -- Patch on_mouse_wheel
    local orig_wheel = TermClass.on_mouse_wheel
    TermClass.on_mouse_wheel = function(self, dy, ...)
      if gh_state.active_panel == PANEL_ACTIONS then
        gh_state.actions_scroll = math.max(0, gh_state.actions_scroll - dy * 30 * SCALE)
        core.redraw = true
        return true
      elseif gh_state.active_panel == PANEL_INSIGHTS then
        gh_state.insights_scroll = math.max(0, gh_state.insights_scroll - dy * 30 * SCALE)
        core.redraw = true
        return true
      end
      return orig_wheel and orig_wheel(self, dy, ...)
    end
  end

  -- Poll until terminal instance appears in view tree.
  local function find_term(node)
    if not node then return nil end
    if node.views then
      for _, v in ipairs(node.views) do
        if v.get_name and v:get_name() == "Terminal" then return v end
      end
    end
    if node.a then
      local v = find_term(node.a)
      if v then return v end
    end
    if node.b then
      local v = find_term(node.b)
      if v then return v end
    end
    return nil
  end

  while true do
    if core.root_view and core.root_view.root_node then
      local term = find_term(core.root_view.root_node)
      if term then
        inject_into_term(term)
      end
    end
    coroutine.yield(0.5)
  end
end)

-- ─── Commands ─────────────────────────────────────────────────────────────────

command.add(nil, {
  ["github-actions:show"] = function()
    -- Make sure terminal is open
    command.perform "terminal:toggle"
    core.add_thread(function()
      coroutine.yield(0.3)
      gh_state.active_panel = PANEL_ACTIONS
      if #gh_state.actions_items == 0 then fetch_actions() end
      core.redraw = true
    end)
  end,

  ["github-actions:refresh"] = function()
    fetch_actions()
  end,

  ["github-insights:show"] = function()
    command.perform "terminal:toggle"
    core.add_thread(function()
      coroutine.yield(0.3)
      gh_state.active_panel = PANEL_INSIGHTS
      if not gh_state.insights then fetch_insights() end
      core.redraw = true
    end)
  end,

  ["github-insights:refresh"] = function()
    fetch_insights()
  end,
})

return {
  name        = "GitHub Actions & Insights",
  description = "Adds Actions and Insights panels to the terminal bottom sheet",
  version     = "1.0.0",
}
