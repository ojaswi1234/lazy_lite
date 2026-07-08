-- mod-version:3
-- Virtual Treeview for GitHub Codespaces
-- Uses VFS to display remote files without local shadow directories

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"

-- Lazy load VFS to avoid circular dependency
local VFS = nil
local function get_vfs()
  if not VFS then
    local ok, vfs = pcall(require, "plugins.virtual_codespace_fs")
    if ok then
      VFS = vfs
    end
  end
  return VFS
end

local TreeView = {
  cache = {},          -- { path: { expanded: bool, children: {name, type} } }
  root = nil,
  expanded = {},
  selected = {},
}

-- Lazy load directory contents
local function get_directory_contents(path)
  local vfs = get_vfs()
  if not vfs or not vfs.active then return {} end
  
  -- Check VFS cache first
  local cached = vfs.cache.directories[path]
  if cached and cached.entries then
    return cached.entries
  end
  
  -- Request from VFS (this will cache it)
  local entries = vfs.readdir(path)
  if entries then
    return entries
  end
  
  return {}
end

-- Toggle directory expansion
function TreeView:toggle(path)
  if not path then return end
  
  self.expanded[path] = not self.expanded[path]
  
  if self.expanded[path] then
    -- Pre-fetch contents when expanding
    core.add_thread(function()
      get_directory_contents(path)
      core.redraw = true
    end)
  end
  
  core.redraw = true
end

-- Draw a single tree item
local function draw_item(path, depth, x, y, w, h)
  local vfs = get_vfs()
  if not vfs or not vfs.active then return false end
  
  -- Convert path to relative
  local rel_path = path:gsub(vfs.local_dir, "")
  local name = rel_path:match("[^/]+$") or rel_path
  
  -- Get file info
  local is_dir = self.expanded[path] or false
  local entries = get_directory_contents(path)
  if entries and #entries > 0 then
    is_dir = true
  end
  
  -- Draw expand/collapse icon
  local icon = is_dir and (self.expanded[path] and "▼" or "▶") or " "
  renderer.draw_text(style.code_font, icon, x + depth * 20 * SCALE, y, style.dim)
  
  -- Draw file name
  local name_x = x + (depth + 1) * 20 * SCALE
  renderer.draw_text(style.code_font, name, name_x, y, style.text)
  
  -- Draw selection indicator
  if self.selected[path] then
    renderer.draw_rect(x, y, w, h, style.selection)
  end
  
  return true
end

-- Draw the entire tree
function TreeView:draw(x, y, w, h)
  local vfs = get_vfs()
  if not vfs or not vfs.active then return end
  
  local line_h = style.code_font:get_height()
  local current_y = y
  
  -- Draw root
  if draw_item(vfs.local_dir, 0, x, current_y, w, line_h) then
    current_y = current_y + line_h
  end
  
  -- Recursively draw expanded directories
  local function draw_recursive(path, depth)
    if current_y > y + h then return end
    
    local entries = get_directory_contents(path)
    if not entries then return end
    
    for _, entry in ipairs(entries) do
      local child_path = path .. "/" .. entry.name
      
      if entry.type == "dir" and self.expanded[child_path] then
        if draw_item(child_path, depth + 1, x, current_y, w, line_h) then
          current_y = current_y + line_h
          draw_recursive(child_path, depth + 1)
        end
      else
        if draw_item(child_path, depth + 1, x, current_y, w, line_h) then
          current_y = current_y + line_h
        end
      end
    end
  end
  
  if self.expanded[vfs.local_dir] then
    draw_recursive(vfs.local_dir, 0)
  end
end

-- Handle mouse clicks
function TreeView:on_mouse_pressed(button, x, y, clicks)
  local vfs = get_vfs()
  if not vfs or not vfs.active then return false end
  
  if button == "left" and clicks == 1 then
    -- Find which item was clicked
    local line_h = style.code_font:get_height()
    local current_y = self.position.y
    
    -- Simple hit detection (can be improved)
    if y >= current_y and y < current_y + line_h then
      -- Root clicked
      self:toggle(vfs.local_dir)
      return true
    end
    
    -- Recursively check children
    local function check_recursive(path, depth, current_y)
      local entries = get_directory_contents(path)
      if not entries then return current_y, false end
      
      for _, entry in ipairs(entries) do
        local child_path = path .. "/" .. entry.name
        current_y = current_y + line_h
        
        if y >= current_y and y < current_y + line_h then
          self:toggle(child_path)
          return current_y, true
        end
        
        if entry.type == "dir" and self.expanded[child_path] then
          current_y, found = check_recursive(child_path, depth + 1, current_y)
          if found then return current_y, true end
        end
      end
      
      return current_y, false
    end
    
    if self.expanded[vfs.local_dir] then
      check_recursive(vfs.local_dir, 0, current_y + line_h)
    end
  end
  
  return false
end

-- Handle keyboard navigation
function TreeView:on_keypressed(key)
  local vfs = get_vfs()
  if not vfs or not vfs.active then return false end
  
  if key == "up" or key == "down" then
    -- Navigate through items (simplified)
    return true
  elseif key == "return" or key == "enter" then
    -- Open selected file
    for path, selected in pairs(self.selected) do
      if selected then
        command.perform("core:open-file", path)
        break
      end
    end
    return true
  end
  
  return false
end

-- Create the treeview widget
local function new_treeview()
  local node = core.root_view:get_active_node()
  local treeview = {
    name = "codespace_treeview",
    position = { x = 0, y = 0 },
    size = { x = 200 * SCALE, y = 0 },
    draw = TreeView.draw,
    on_mouse_pressed = TreeView.on_mouse_pressed,
    on_keypressed = TreeView.on_keypressed,
    toggle = TreeView.toggle,
    expanded = {},
    selected = {}
  }
  
  return treeview
end

-- Register command to show codespace treeview
command.add(nil, {
  ["codespaces:show-treeview"] = function()
    local vfs = get_vfs()
    if not vfs or not vfs.active then
      core.log_quiet("No active codespace connection")
      return
    end
    
    local treeview = new_treeview()
    core.root_view:get_active_node():add_view(treeview)
  end
})

return TreeView