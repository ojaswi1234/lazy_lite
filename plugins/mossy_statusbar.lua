-- mod-version:3
-- Stylised bottom status bar (VS Code style) with Git branch indicator.

local core    = require "core"
local system = require "system"
local style   = require "core.style"
local common  = require "core.common"
local process = require "process"

local function get_contrast_bg(bg)
  if type(bg) ~= "table" then return bg end
  local r, g, b, a = bg[1], bg[2], bg[3], bg[4] or 255
  local lum = (r * 0.299 + g * 0.587 + b * 0.114)
  if lum > 128 then
    -- Light theme: darken by 8%
    return { math.max(0, math.floor(r * 0.92)), math.max(0, math.floor(g * 0.92)), math.max(0, math.floor(b * 0.92)), a }
  else
    -- Dark theme: lighten by 8%
    return { math.min(255, math.floor(r + (255 - r) * 0.08)), math.min(255, math.floor(g + (255 - g) * 0.08)), math.min(255, math.floor(b + (255 - b) * 0.08)), a }
  end
end

-- ── 1. Override Status View Background ──────────────────────────────────────────
-- ── 1. Override Status View Background & Overlap-Proof Drawing ────────────────
local StatusView = require "core.statusview"

local function draw_clean_status_bg(self)
  local status_bg = (style.mossy and style.mossy.status_bg) or get_contrast_bg(style.background)
  local full_w = math.max(self.size.x, (core.root_view and core.root_view.size.x) or self.size.x)
  -- Clear across full window width to prevent un-cleared ghost artifacts in gutters/sidebars
  renderer.draw_rect(0, self.position.y, full_w, self.size.y, status_bg)
  if self.position.x > 0 then
    renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, status_bg)
  end
  local border_bg = (style.mossy and style.mossy.border) or get_contrast_bg(status_bg)
  renderer.draw_rect(0, self.position.y, full_w, math.ceil(1 * SCALE), border_bg)
end

core.status_view.draw_background = draw_clean_status_bg

-- The REAL fix: hook update_active_items() where item.cached_item is built.
local old_update_active = core.status_view.update_active_items
function core.status_view:update_active_items(...)
  local old_text   = style.text
  local old_dim    = style.dim
  local old_icon   = style.icon_color
  local old_accent = style.accent
  if style.mossy and style.mossy.status_text then
    local st = style.mossy.status_text
    style.text       = st
    style.dim        = st
    style.icon_color = st
    style.accent     = st
  end
  old_update_active(self, ...)
  style.text       = old_text
  style.dim        = old_dim
  style.icon_color = old_icon
  style.accent     = old_accent
end

local function get_item_bg(self, item)
  local hovered = self.hovered_item == item
  local item_bg = hovered and item.background_color_hover or item.background_color
  return hovered, item_bg
end

-- Bulletproof draw() that guarantees ZERO text overlap across status bar items
function core.status_view:draw(...)
  if not self.visible and self.size.y <= 0 then return end

  local old_text   = style.text
  local old_dim    = style.dim
  local old_icon   = style.icon_color
  local old_accent = style.accent
  if style.mossy and style.mossy.status_text then
    local st = style.mossy.status_text
    style.text       = st
    style.dim        = st
    style.icon_color = st
    style.accent     = st
  end

  draw_clean_status_bg(self)

  if self.message and system.get_time() <= self.message_timeout then
    self:draw_items(self.message, false, 0, self.size.y)
  else
    if self.tooltip_mode then
      self:draw_items(self.tooltip)
    end

    if #self.active_items > 0 then
      local base_x = self.position.x
      local bar_w = self.size.x
      local bar_y = self.position.y
      local bar_h = self.size.y
      local pad = style.padding.x

      -- Group active items into left and right
      local left_items = {}
      local right_items = {}
      for _, item in ipairs(self.active_items) do
        if item.alignment == StatusView.Item.LEFT then
          table.insert(left_items, item)
        else
          table.insert(right_items, item)
        end
      end

      -- Draw left items sequentially from left edge
      local cur_left_x = base_x + pad
      local max_left_reach = base_x + math.floor(bar_w * 0.45)

      for _, item in ipairs(left_items) do
        local iw = item.w or 0
        if cur_left_x + iw > max_left_reach then
          local avail = math.max(0, max_left_reach - cur_left_x)
          if avail > 10 * SCALE then
            core.push_clip_rect(cur_left_x, bar_y, avail, bar_h)
            local hovered, item_bg = get_item_bg(self, item)
            if type(item_bg) == "table" then
              renderer.draw_rect(cur_left_x, bar_y, avail, bar_h, item_bg)
            end
            if item.on_draw then
              item.on_draw(cur_left_x, bar_y, bar_h, hovered)
            else
              self:draw_items(item.cached_item, false, (cur_left_x - base_x) - pad)
            end
            core.pop_clip_rect()
          end
          cur_left_x = max_left_reach
          break
        else
          core.push_clip_rect(cur_left_x, bar_y, iw, bar_h)
          local hovered, item_bg = get_item_bg(self, item)
          if type(item_bg) == "table" then
            renderer.draw_rect(cur_left_x, bar_y, iw, bar_h, item_bg)
          end
          if item.on_draw then
            item.on_draw(cur_left_x, bar_y, bar_h, hovered)
          else
            self:draw_items(item.cached_item, false, (cur_left_x - base_x) - pad)
          end
          core.pop_clip_rect()
          cur_left_x = cur_left_x + iw
        end
      end

      -- Draw right items backwards from the right edge
      local cur_right_x = base_x + bar_w - pad
      local min_right_reach = cur_left_x + pad -- NEVER cross into left pane!

      for i = #right_items, 1, -1 do
        local item = right_items[i]
        local iw = item.w or 0
        local item_x = cur_right_x - iw

        if item_x < min_right_reach then
          break -- Stop drawing if no space left; guarantees zero overlap
        end

        core.push_clip_rect(item_x, bar_y, iw, bar_h)
        local hovered, item_bg = get_item_bg(self, item)
        if type(item_bg) == "table" then
          renderer.draw_rect(item_x, bar_y, iw, bar_h, item_bg)
        end
        if item.on_draw then
          item.on_draw(item_x, bar_y, bar_h, hovered)
        else
          self:draw_items(item.cached_item, false, (item_x - base_x) - pad)
        end
        core.pop_clip_rect()

        cur_right_x = item_x
      end

      if self.hovered_item and self.hovered_item.tooltip and self.hovered_item.tooltip ~= "" and self.hovered_item.active then
        self:draw_item_tooltip(self.hovered_item)
      end
    end
  end

  style.text       = old_text
  style.dim        = old_dim
  style.icon_color = old_icon
  style.accent     = old_accent
end

-- ── 2. Git Branch Indicator ───────────────────────────────────────────────────
local current_branch = nil
local last_check     = 0
local check_interval = 10 -- seconds: git branch check (low-priority background task)
local git_checking   = false

local function check_git_branch()
  if not core.project_dir then
    current_branch = nil
    return
  end

  -- Fast-path check: Only spawn git if .git directory/file exists in the project
  local git_info = system.get_file_info(core.project_dir .. PATHSEP .. ".git")
  if not git_info then
    current_branch = nil
    return
  end

  git_checking = true
  local p = process.start(
    { "git", "branch", "--show-current" }, 
    {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_DISCARD,
      cwd    = core.project_dir
    }
  )
  
  if not p then 
    current_branch = nil
    git_checking = false
    return 
  end

  local output = ""
  local start_time = system.get_time()
  while p:running() do
    if system.get_time() - start_time > 3 then
      p:kill()
      break
    end
    local chunk = p:read_stdout()
    if chunk and #chunk > 0 then
      output = output .. chunk
    end
    coroutine.yield(0.2)
  end
  
  -- Drain remaining output
  local chunk = p:read_stdout()
  if chunk and #chunk > 0 then 
    output = output .. chunk 
  end

  if p:returncode() == 0 and #output > 0 then
    current_branch = output:match("^%s*(.-)%s*$")
    if current_branch == "" then current_branch = nil end
  else
    current_branch = nil
  end
  git_checking = false
  core.redraw = true
end

-- Register the Git branch item on the far left of the status bar
core.status_view:add_item({
  name = "mossy:git_branch",
  alignment = core.status_view.Item.LEFT,
  position = 1,
  tooltip = "Current Git Branch",
  get_item = function()
    local now = system.get_time()
    if now - last_check > check_interval and not git_checking then
      last_check = now
      core.add_thread(check_git_branch)
    end

    if not current_branch then 
      return {} 
    end

    -- Read style.text at draw time — the draw hook will have already swapped
    -- it to status_text, so this correctly goes dark on a light status bar.
    local fg = style.text
    
    -- The branch icon (using standard Nerd Font code \xee\x82\xa0 which is U+E0A0)
    -- or just a clear text prefix. We'll use the standard branch icon character.
    return {
      fg,
      style.font,
      "\xee\x82\xa0 " .. current_branch,
      core.status_view.separator2
    }
  end,
  command = "git-timeline:toggle",
})

-- ── 3. Truncate Long Filenames & Codespace Names ────────────────────────────────────────────────
local status_view = core.status_view

-- Truncate document filename
local doc_file_item = status_view:get_item("doc:file")
if doc_file_item then
  local old_get_item = doc_file_item.get_item
  doc_file_item.get_item = function(self)
    local items = old_get_item(self)
    if not items or #items == 0 then return items end
    
    local path = items[#items]
    if type(path) == "string" then
      local max_len = 30
      if #path > max_len then
        local file = path:match("[^/\\]+$") or ""
        local dir = path:sub(1, #path - #file)
        
        if #file > max_len - 5 then
          items[#items] = "..." .. path:sub(-(max_len - 3))
        else
          local keep_dir = max_len - #file - 3
          items[#items] = dir:sub(1, math.max(1, math.floor(keep_dir / 2))) .. "..." .. dir:sub(-math.max(1, math.ceil(keep_dir / 2))) .. file
        end
      end
    end
    return items
  end
end

-- Truncate Codespace name indicator or hide verbose text
local cs_item = status_view:get_item("codespaces")
if cs_item then
  local old_cs_get_item = cs_item.get_item
  cs_item.get_item = function(self)
    local items = old_cs_get_item(self)
    if items then
      for i, item in ipairs(items) do
        if type(item) == "string" and item:match("^ ") then
          -- The text is usually " name" or " GitHub Codespaces"
          local name = item:sub(2)
          if name == "GitHub Codespaces" then
            -- In local mode, the text "GitHub Codespaces" is redundant. 
            -- Just let the GitHub icon show.
            items[i] = ""
          elseif #name > 15 then
            items[i] = " " .. name:sub(1, 12) .. "..."
          end
          break
        end
      end
    end
    return items
  end
end

-- Remove percentage from doc:position
local pos_item = status_view:get_item("doc:position")
if pos_item then
  local old_pos_get_item = pos_item.get_item
  pos_item.get_item = function(self)
    local items = old_pos_get_item(self)
    -- Original ends with: self.separator, string.format("%.f%%", ...)
    if items and #items >= 2 then
      if type(items[#items]) == "string" and items[#items]:match("%%$") then
        table.remove(items, #items) -- remove percentage
        table.remove(items, #items) -- remove separator
      end
    end
    return items
  end
end

-- ── 4. Clean Up Clutter ────────────────────────────────────────────────────────
-- Remove rarely used items to save space
status_view:remove_item("doc:line-ending")
status_view:remove_item("doc:lines")
