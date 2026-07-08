-- mod-version:3
-- Stylised bottom status bar (VS Code style) with Git branch indicator.

local core    = require "core"
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
local old_draw_bg = core.status_view.draw_background
function core.status_view:draw_background(...)
  local status_bg = (style.mossy and style.mossy.status_bg) or get_contrast_bg(style.background)
  renderer.draw_rect(0, self.position.y, self.size.x, self.size.y, status_bg)
  
  local border_bg = (style.mossy and style.mossy.border) or get_contrast_bg(status_bg)
  renderer.draw_rect(0, self.position.y, self.size.x, 1 * SCALE, border_bg)
end

local old_draw = core.status_view.draw
function core.status_view:draw(...)
  local old_text = style.text
  local old_dim = style.dim
  local old_icon = style.icon_color
  if style.mossy then
    style.text = style.mossy.status_text or style.text
    style.dim = style.mossy.sidebar_muted or style.dim
    style.icon_color = style.mossy.status_text or style.icon_color
  end
  old_draw(self, ...)
  style.text = old_text
  style.dim = old_dim
  style.icon_color = old_icon
end

-- ── 2. Git Branch Indicator ───────────────────────────────────────────────────
local current_branch = nil
local last_check     = 0
local check_interval = 2 -- seconds

local function check_git_branch()
  local p = process.start(
    PLATFORM == "Windows" 
      and { "cmd.exe", "/c", "git branch --show-current 2>nul" }
      or  { "sh", "-c", "git branch --show-current 2>/dev/null" }, 
    {
      stdout = process.REDIRECT_PIPE,
      cwd    = core.project_dir
    }
  )
  
  if not p then 
    current_branch = nil
    return 
  end

  local output = ""
  while p:running() do
    local chunk = p:read_stdout()
    if chunk and #chunk > 0 then
      output = output .. chunk
    end
    coroutine.yield(0.1)
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
    if now - last_check > check_interval then
      last_check = now
      core.add_thread(check_git_branch)
    end

    if not current_branch then 
      return {} 
    end

    local fg = style.accent or style.text
    
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
