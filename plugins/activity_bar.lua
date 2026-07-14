-- mod-version:3
-- VS Code style Activity Bar for Lite XL
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"

local ActivityBar = View:extend()

function ActivityBar:new()
  ActivityBar.super.new(self)
  self.name = "ActivityBar"
  self.size = { x = 48 * SCALE, y = 0 }
  
  self.items = {
    { id = "treeview", icon = "\u{f07b}", command = "treeview:toggle", tooltip = "Explorer" },
    { id = "antigravity", icon = "\u{eb53}", command = "antigravity:toggle", tooltip = "Antigravity AI" },
    { id = "leetcode", icon = "\u{f121}", command = "leetcode:toggle", tooltip = "LeetCode" },
    { id = "docker", icon = "\u{f38b}", command = "docker:toggle", tooltip = "Docker" },
    { id = "mongodb", icon = "\u{e7a4}", command = "mongodb:activity-bar", tooltip = "MongoDB" }
  }
  self.active_id = "treeview"
  self.target_size = 48 * SCALE
  self.visible = true
end

function ActivityBar:get_name() return self.name end

function ActivityBar:update()
  ActivityBar.super.update(self)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "x", dest, nil, "activity_bar")
end

function ActivityBar:draw()
  self:draw_background(style.background3 or style.background)
  local x, y = self.position.x, self.position.y
  
  for _, item in ipairs(self.items) do
    local is_active = (self.active_id == item.id)
    local hovered = self.mouse_y and self.mouse_y >= y and self.mouse_y < y + 48 * SCALE
    local color = is_active and style.text or (hovered and style.text or style.dim)
    
    local icon_w = style.icon_font:get_width(item.icon)
    local icon_h = style.icon_font:get_height()
    
    if is_active then
      renderer.draw_rect(x, y, 2 * SCALE, 48 * SCALE, style.accent)
    end
    
    local hx = x + (self.size.x - icon_w) / 2
    local hy = y + (48 * SCALE - icon_h) / 2
    
    renderer.draw_text(style.icon_font, item.icon, hx, hy, color)
    y = y + 48 * SCALE
  end
end

function ActivityBar:on_mouse_moved(x, y)
  self.mouse_y = y
  core.redraw = true
end

function ActivityBar:on_mouse_left()
  self.mouse_y = nil
  core.redraw = true
end

function ActivityBar:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    local idx = math.floor((y - self.position.y) / (48 * SCALE)) + 1
    if self.items[idx] then
      local item = self.items[idx]
      local current_node = _G.get_sidebar_node and _G.get_sidebar_node(true)
      
      if self.active_id == item.id and current_node and #current_node.views > 0 then
        for i = #current_node.views, 1, -1 do
          current_node:close_view(core.root_view.root_node, current_node.views[i])
        end
      else
        self.active_id = item.id
        if item.command == "treeview:toggle" then
          local tv = require "plugins.treeview"
          local node = _G.get_sidebar_node()
          if tv and tv.view and node then
            if not node:get_view_idx(tv.view) then node:add_view(tv.view) end
            node:set_active_view(tv.view)
          end
        else
          command.perform(item.command)
        end
      end
      return true
    end
  end
end

local activity_bar = nil
local sidebar_node = nil

local function is_node_in_tree(root, target)
  if not root then return false end
  if root == target then return true end
  if root.type == "leaf" then return false end
  return is_node_in_tree(root.a, target) or is_node_in_tree(root.b, target)
end

rawset(_G, "get_sidebar_node", function(dont_create)
  if not activity_bar then return nil end
  local ab_node = core.root_view.root_node:get_node_for_view(activity_bar)
  if not ab_node then return nil end
  
  if sidebar_node and is_node_in_tree(core.root_view.root_node, sidebar_node) then
    return sidebar_node
  end
  
  if dont_create then return nil end
  
  -- If destroyed (e.g. user closed all sidebar views), recreate it
  sidebar_node = ab_node:split("right")
  sidebar_node.should_show_tabs = function() return false end
  return sidebar_node
end)

local function init_activity_bar()
  local target_node = nil
  
  -- Find the TreeView node or any existing sidebar if it is already open
  for _, node in ipairs(core.root_view.root_node:get_children()) do
    if node and node.views then
      for _, view in ipairs(node.views) do
        if view and (view.name == "Tree" or view.class_name == "TreeView" or view.name == "Docker" or view.name == "LeetCode" or view.name == "Antigravity") then
          target_node = node
          break
        end
      end
    end
    if target_node then break end
  end
  
  -- If no sidebar exists, attach to the primary editor node
  if not target_node then
    target_node = core.root_view:get_primary_node()
  end
  if not target_node then return end
  
  -- Create the Activity Bar
  activity_bar = ActivityBar()
  
  -- Split the target node to place Activity Bar on its left edge
  local ab_node = target_node:split("left", activity_bar, {x = true}, false)
  
  -- Because target_node was split, it was converted into an hsplit.
  -- The original contents (TreeView or Editor) are now in target_node.b
  local sibling_node = target_node.b
  
  -- Check if the sibling node is actually a sidebar panel (and not the editor)
  local is_sidebar = false
  if sibling_node and sibling_node.views then
    for _, view in ipairs(sibling_node.views) do
      if view and (view.name == "Tree" or view.class_name == "TreeView" or view.name == "Docker" or view.name == "LeetCode" or view.name == "Antigravity") then
        is_sidebar = true
        break
      end
    end
  end
  
  if is_sidebar then
    sidebar_node = sibling_node
    sidebar_node.should_show_tabs = function() return false end
  else
    sidebar_node = nil
  end
    
    -- Override Ctrl+B to toggle only the Sidebar Node
    command.add(nil, {
      ["treeview:toggle"] = function()
        local current_node = _G.get_sidebar_node(true)
        if current_node and #current_node.views > 0 then
          for i = #current_node.views, 1, -1 do
            current_node:close_view(core.root_view.root_node, current_node.views[i])
          end
        else
          activity_bar.active_id = "treeview"
          local tv = require "plugins.treeview"
          local node = _G.get_sidebar_node()
          if tv and tv.view and node then
            if not node:get_view_idx(tv.view) then node:add_view(tv.view) end
            node:set_active_view(tv.view)
          end
        end
      end,
      ["mongodb:activity-bar"] = function()
        local mongo = require("plugins.mongodb_explorer")
        if not mongo.uri then
          command.perform("mongodb:connect")
        else
          command.perform("mongodb:explore-databases")
        end
      end
    })
end

core.add_thread(function()
  -- Wait a bit for treeview and other plugins to initialize
  while not core.root_view or not core.root_view.root_node do coroutine.yield(0.1) end
  coroutine.yield(0.1)
  init_activity_bar()
end)
