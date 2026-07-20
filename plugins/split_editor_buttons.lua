-- mod-version:3
local core = require "core"
local style = require "core.style"
local Node = require "core.node"
local RootView = require "core.rootview"

local old_draw_tabs = Node.draw_tabs
function Node:draw_tabs()
  old_draw_tabs(self)
  
  if not self.views or #self.views == 0 then return end
  
  -- Draw split buttons on the right side of the tab bar
  local th = style.font:get_height() + (style.padding.y * 2)
  if self.tab_height then th = self.tab_height end
  
  local x = self.position.x + self.size.x - (25 * SCALE)
  local y = self.position.y
  
  -- Split Down Button
  local hovered_down = (self.hovered_split == "down")
  core.push_clip_rect(self.position.x, y, self.size.x, th)
  renderer.draw_text(style.icon_font, "\u{f103}", x, y + (th - style.icon_font:get_height())/2, hovered_down and style.accent or style.dim)
  
  -- Split Right Button
  x = x - (25 * SCALE)
  local hovered_right = (self.hovered_split == "right")
  renderer.draw_text(style.icon_font, "\u{f101}", x, y + (th - style.icon_font:get_height())/2, hovered_right and style.accent or style.dim)
  core.pop_clip_rect()
end

local old_on_mouse_moved = Node.on_mouse_moved
function Node:on_mouse_moved(x, y, ...)
  local res = old_on_mouse_moved(self, x, y, ...)
  if not self.views or #self.views == 0 then return res end
  
  local th = style.font:get_height() + (style.padding.y * 2)
  if self.tab_height then th = self.tab_height end
  
  self.hovered_split = nil
  if y >= self.position.y and y <= self.position.y + th then
    local btn_y_start = self.position.x + self.size.x - (25 * SCALE)
    if x >= btn_y_start and x <= btn_y_start + (25 * SCALE) then
      self.hovered_split = "down"
      core.request_cursor("hand")
      return true
    end
    
    local btn_x_start = btn_y_start - (25 * SCALE)
    if x >= btn_x_start and x <= btn_y_start then
      self.hovered_split = "right"
      core.request_cursor("hand")
      return true
    end
  end
  return res
end

local old_on_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  local node = self.root_node:get_child_overlapping_point(x, y)
  if button == "left" and node and node.hovered_split then
    if node.hovered_split == "down" then
      node:split("down")
    elseif node.hovered_split == "right" then
      node:split("right")
    end
    node.hovered_split = nil
    return true
  end
  return old_on_mouse_pressed(self, button, x, y, clicks)
end

local old_on_mouse_left = Node.on_mouse_left
function Node:on_mouse_left()
  self.hovered_split = nil
  if old_on_mouse_left then
    old_on_mouse_left(self)
  end
end
