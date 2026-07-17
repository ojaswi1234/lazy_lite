local core = require "core"
local Node = require "core.node"
local RootView = require "core.rootview"
local style = require "core.style"
local common = require "core.common"

-- State
local hovered_node = nil

-- Calculate button dimensions
local function get_btn_info()
  return style.icon_font:get_width("X") + 16 * SCALE
end

-- 1. Hook get_scroll_button_rect to naturally shift the scroll buttons leftwards
local old_get_scroll_button_rect = Node.get_scroll_button_rect
function Node:get_scroll_button_rect(self, index)
  local old_size_x = self.size.x
  if #self.views > 0 then self.size.x = self.size.x - get_btn_info() end
  local x, y, w, h, pad = old_get_scroll_button_rect(self, index)
  self.size.x = old_size_x
  return x, y, w, h, pad
end

-- 2. Hook get_tab_rect so tabs are naturally clamped to the reduced width
local old_get_tab_rect = Node.get_tab_rect
function Node:get_tab_rect(self, idx)
  local old_size_x = self.size.x
  if #self.views > 0 then self.size.x = self.size.x - get_btn_info() end
  local x, y, w, h = old_get_tab_rect(self, idx)
  self.size.x = old_size_x
  return x, y, w, h
end

-- 3. Hook target_tab_width so tab logic allocates the correct space
local old_target_tab_width = Node.target_tab_width
function Node:target_tab_width(self)
  local old_size_x = self.size.x
  if #self.views > 0 then self.size.x = self.size.x - get_btn_info() end
  local res = old_target_tab_width(self)
  self.size.x = old_size_x
  return res
end

-- 4. Hook draw_tabs to draw our beautiful close-all button at the end
local old_draw_tabs = Node.draw_tabs
function Node:draw_tabs(self)
  old_draw_tabs(self)
  if #self.views == 0 then return end
  
  local bw = get_btn_info()
  local bx = self.position.x + self.size.x - bw
  local by = self.position.y
  local bh = style.font:get_height() + style.padding.y * 2
  
  local is_hover = (hovered_node == self)
  
  -- Draw hover state
  renderer.draw_rect(bx, by, bw, bh, is_hover and style.background3 or style.background2)
  local ds = style.divider_size
  renderer.draw_rect(bx, by + bh - ds, bw, ds, style.divider)
  
  -- Draw 'X' icon
  local text_color = is_hover and style.accent or style.text
  common.draw_text(style.icon_font, text_color, "X", "center", bx, by, bw, bh)
end

-- 5. Hook RootView for accurate hover states
local old_on_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(self, x, y, dx, dy)
  local node = self.root_node:get_child_overlapping_point(x, y)
  local hnode = nil
  if node and node.type == "leaf" and #node.views > 0 then
    local bw = get_btn_info()
    local bx = node.position.x + node.size.x - bw
    local by = node.position.y
    local bh = style.font:get_height() + style.padding.y * 2
    if x >= bx and x <= bx + bw and y >= by and y <= by + bh then
      hnode = node
    end
  end
  
  if hovered_node ~= hnode then
    hovered_node = hnode
    core.redraw = true
  end
  
  return old_on_mouse_moved(self, x, y, dx, dy)
end

-- 6. Hook RootView to intercept clicks and safely close all tabs
local old_on_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(self, button, x, y, clicks)
  local node = self.root_node:get_child_overlapping_point(x, y)
  if node and node.type == "leaf" and #node.views > 0 then
    local bw = get_btn_info()
    local bx = node.position.x + node.size.x - bw
    local by = node.position.y
    local bh = style.font:get_height() + style.padding.y * 2
    if x >= bx and x <= bx + bw and y >= by and y <= by + bh then
      if button == "left" then
        -- Close all tabs in this node (clone list to avoid mutation issues)
        local views_to_close = {}
        for _, view in ipairs(node.views) do
          table.insert(views_to_close, view)
        end
        for _, view in ipairs(views_to_close) do
          node:close_view(self.root_node, view)
        end
        return true
      end
    end
  end
  return old_on_mouse_pressed(self, button, x, y, clicks)
end
