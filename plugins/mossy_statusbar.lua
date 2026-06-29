-- mod-version:3
-- Stylised bottom status bar (VS Code style) with Git branch indicator.

local core    = require "core"
local style   = require "core.style"
local common  = require "core.common"
local process = require "process"

-- ── 1. Override Status View Background ──────────────────────────────────────────
local old_draw_bg = core.status_view.draw_background
function core.status_view:draw_background(...)
  -- Draw the entire bar in our Mossy status background color
  if style.mossy and style.mossy.status_bg then
    renderer.draw_rect(0, self.position.y, self.size.x, self.size.y, style.mossy.status_bg)
    
    -- Draw a subtle top border
    renderer.draw_rect(0, self.position.y, self.size.x, 1 * SCALE, { common.color "#4A6A3A" })
  else
    old_draw_bg(self, ...)
  end
end

-- Force text in standard items to contrast well against the dark green bar
-- (By default they use style.text which might be dark in a light theme)
local old_draw_items = core.status_view.draw_items
function core.status_view:draw_items(items, ...)
  if style.mossy and style.mossy.status_text then
    local contrast_items = {}
    for i, item in ipairs(items) do
      if type(item) == "table" and not item.get_width then
        -- It's a color table, replace it with our status_text color
        table.insert(contrast_items, style.mossy.status_text)
      else
        table.insert(contrast_items, item)
      end
    end
    return old_draw_items(self, contrast_items, ...)
  end
  return old_draw_items(self, items, ...)
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

    local fg = style.mossy and style.mossy.status_text or style.text
    
    -- The branch icon (using standard Nerd Font code \xee\x82\xa0 which is U+E0A0)
    -- or just a clear text prefix. We'll use the standard branch icon character.
    return {
      fg,
      style.font,
      "\xee\x82\xa0 " .. current_branch,
      core.status_view.separator2
    }
  end
})
