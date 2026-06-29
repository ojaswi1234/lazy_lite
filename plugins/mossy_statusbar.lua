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
  local status_bg = get_contrast_bg(style.background)
  renderer.draw_rect(0, self.position.y, self.size.x, self.size.y, status_bg)
  
  local border_bg = get_contrast_bg(status_bg)
  renderer.draw_rect(0, self.position.y, self.size.x, 1 * SCALE, border_bg)
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
  end
})
