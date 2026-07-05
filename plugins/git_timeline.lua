-- mod-version:3
local core = require "core"
local command = require "core.command"
local style = require "core.style"
local View = require "core.view"
local process = require "process"
local treeview = require "plugins.treeview"

local GitTimelineView = View:extend()

function GitTimelineView:new()
  GitTimelineView.super.new(self)
  self.scrollable = true
  self.commits = {}
  self:update_commits()
end

function GitTimelineView:get_name()
  return "Git Commits"
end

function GitTimelineView:update_commits()
  self.commits = { { graph = "", hash = "", msg = "Loading commits...", is_loading = true } }
  core.redraw = true
  
  core.add_thread(function()
    local cmd = {}
    if core.active_codespace then
      local inner_cmd = "cd '" .. core.active_codespace.remote_dir .. "' && git --no-pager log --graph --pretty=format:'%h %s' -n 50"
      local safe_cmd = "'" .. inner_cmd:gsub("'", "'\\''") .. "'"
      cmd = {"gh", "cs", "ssh", "-c", core.active_codespace.name, "--", "sh", "-c", safe_cmd}
    else
      local p_dir = core.project_dir or ""
      cmd = {"git", "--no-pager", "-C", p_dir, "log", "--graph", "--pretty=format:%h %s", "-n", "50"}
    end
    
    local p = process.start(cmd, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
    if not p then
      self.commits = { { graph = "", hash = "", msg = "Git not found or error executing." } }
      core.redraw = true
      return
    end
    
    local out = ""
    local err = ""
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

    if p:returncode() ~= 0 then
      local msg = (err and err:match("%S")) and err:gsub("[\r\n]+", " ") or "No git repository found in current project."
      self.commits = { { graph = "", hash = "", msg = msg } }
      core.redraw = true
      return
    end
    
    self.commits = {}
    for line in out:gmatch("[^\r\n]+") do
      -- Parse graph, hash, and msg
      -- Example: * | \ a1b2c3d Commit message
      local graph, hash, msg = line:match("^(.-)%s+([0-9a-fA-F]+)%s+(.*)$")
      if hash and #hash >= 7 then
        table.insert(self.commits, { graph = graph, hash = hash, msg = msg })
      else
        -- Just graph lines, like | | |
        table.insert(self.commits, { graph = line, hash = "", msg = "" })
      end
    end
    
    if #self.commits == 0 then
      table.insert(self.commits, { graph = "", hash = "", msg = "No commits found." })
    end
    core.redraw = true
  end)
end

function GitTimelineView:draw()
  self:draw_background(style.background2 or style.background)
  
  -- Title bar for the section
  local title_h = style.font:get_height() + 10 * SCALE
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, title_h, style.background3 or style.background)
  renderer.draw_text(style.font, "GIT COMMITS", self.position.x + 10 * SCALE, self.position.y + 5 * SCALE, style.dim or style.text)
  
  -- Drawing commits
  local h = style.code_font:get_height()
  local y = self.position.y + title_h - self.scroll.y + 5 * SCALE
  
  for i, c in ipairs(self.commits) do
    if y + h > self.position.y + title_h and y < self.position.y + self.size.y then
      local x = self.position.x + 10 * SCALE
      
      if c.is_loading then
        renderer.draw_text(style.font, c.msg, x, y, style.text)
      else
        -- Draw graph with accent color
        if #c.graph > 0 then
          renderer.draw_text(style.code_font, c.graph, x, y, {100, 200, 255, 255})
          x = x + style.code_font:get_width(c.graph) + 5 * SCALE
        end
        
        -- Draw hash
        if #c.hash > 0 then
          renderer.draw_text(style.code_font, c.hash, x, y, {200, 150, 50, 255})
          x = x + style.code_font:get_width(c.hash) + 10 * SCALE
        end
        
        -- Draw msg
        if #c.msg > 0 then
          renderer.draw_text(style.font, c.msg, x, y, style.text)
        end
      end
    end
    y = y + h
  end
  
  self.scroll.y = math.max(0, math.min(self.scroll.y, y - self.position.y - self.size.y + self.scroll.y))
  self:draw_scrollbar()
end

-- Toggle Command
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
        node:split("down", timeline_view)
      else
        -- fallback to right sidebar if treeview not found
        core.root_view.root_node:split("right", timeline_view)
      end
    end
  end,
  ["git-timeline:refresh"] = function()
    if timeline_view then timeline_view:update_commits() end
  end
})

-- Hook status bar to add toggle button
local status_view = require "core.statusview"
if status_view then
  core.status_view:add_item({
    name = "git_timeline",
    alignment = status_view.Item.LEFT,
    position = 2,
    get_item = function()
      local color = timeline_view and style.accent or style.text
      return { color, style.icon_font, "", style.font, " Commits" }
    end,
    command = "git-timeline:toggle"
  })
end

return {
  name = "Git Timeline",
  description = "Provides a vertical Git Commit explorer pane."
}
