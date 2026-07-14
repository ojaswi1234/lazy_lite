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
  self.locked_size = { x = 48 * SCALE, y = true }
  
  self.items = {
    { id = "treeview", icon = "\u{f07b}", command = "treeview:toggle", tooltip = "Explorer" },
    { id = "antigravity", icon = "\u{eb53}", command = "antigravity:toggle", tooltip = "Antigravity AI" },
    { id = "leetcode", icon = "\u{f121}", command = "leetcode:toggle", tooltip = "LeetCode" },
    { id = "docker", icon = "\u{f38b}", command = "docker:toggle", tooltip = "Docker" },
    { id = "git", icon = "\u{f1d3}", command = "git-timeline:toggle", tooltip = "Git Timeline" }
  }
  self.active_id = "treeview"
  self.target_size = 48 * SCALE
  self.visible = true
end

function ActivityBar:get_name() return self.name end

function ActivityBar:update()
  ActivityBar.super.update(self)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.locked_size, "x", dest, nil, "activity_bar")
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
      if self.active_id == item.id then
        command.perform("treeview:toggle")
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
  if root == target then return true end
  if root.type == "split" then
    return is_node_in_tree(root.a, target) or is_node_in_tree(root.b, target)
  end
  return false
end

function _G.get_sidebar_node()
  if not activity_bar then return nil end
  local ab_node = core.root_view.root_node:get_node_for_view(activity_bar)
  if not ab_node then return nil end
  
  if sidebar_node and is_node_in_tree(core.root_view.root_node, sidebar_node) then
    return sidebar_node
  end
  
  -- If destroyed (e.g. user closed all sidebar views), recreate it
  sidebar_node = ab_node:split("right")
  sidebar_node.should_show_tabs = function() return false end
  return sidebar_node
end

local function init_activity_bar()
  -- Find the TreeView node
  for _, node in ipairs(core.root_view.root_node:get_children()) do
    for _, view in ipairs(node.views) do
      if view.name == "Tree" or view.class_name == "TreeView" then
        sidebar_node = node
        break
      end
    end
    if sidebar_node then break end
  end
  
  if sidebar_node then
    sidebar_node.should_show_tabs = function() return false end
    activity_bar = ActivityBar()
    -- Split the sidebar node to the left for the activity bar
    local ab_node = sidebar_node:split("left", activity_bar, {x = true}, true)
    
    -- Override Ctrl+B to toggle both Activity Bar and Sidebar Node
    command.add(nil, {
      ["treeview:toggle"] = function()
        activity_bar.visible = not activity_bar.visible
        if activity_bar.visible then
          for _, item in ipairs(activity_bar.items) do
            if item.id == activity_bar.active_id then
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
              break
            end
          end
        else
          local node = _G.get_sidebar_node()
          if node then
            for i = #node.views, 1, -1 do
              node:close_view(core.root_view.root_node, node.views[i])
            end
          end
        end
      end
    })
  end
end

core.add_thread(function()
  -- Wait a bit for treeview and other plugins to initialize
  while not core.root_view or not core.root_view.root_node do coroutine.yield(0.1) end
  coroutine.yield(0.1)
  init_activity_bar()
end)
