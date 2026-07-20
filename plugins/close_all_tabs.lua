-- mod-version:3
local core = require "core"
local Node = require "core.node"
local RootView = require "core.rootview"
local style = require "core.style"
local common = require "core.common"
local DocView = require "core.docview"

-- Only treat a node as a real editor node if it contains at least one DocView.
-- This prevents the close-all button from appearing on TitleView / StatusView
-- nodes that also span the full editor width and would intercept OS window clicks.
local function is_editor_node(node)
  if not node or node.type ~= "leaf" then return false end
  for _, v in ipairs(node.views) do
    if v:is(DocView) then return true end
  end
  return false
end

-- State
local hovered_node = nil

-- Calculate button dimensions
local function get_btn_info()
  return style.icon_font:get_width("X") + 16 * SCALE
end

-- 1. Hook get_scroll_button_rect to prevent arrows from taking space
local old_get_scroll_button_rect = Node.get_scroll_button_rect
function Node:get_scroll_button_rect(index)
  local x, y, w, h, pad = old_get_scroll_button_rect(self, index)
  return -1000, y, 0, h, 0
end

-- 2. Hook get_tab_rect so tabs are naturally clamped to the reduced width
local old_get_tab_rect = Node.get_tab_rect
function Node:get_tab_rect(idx)
  local old_size_x = self.size.x
  if is_editor_node(self) then self.size.x = self.size.x - get_btn_info() end
  local x, y, w, h = old_get_tab_rect(self, idx)
  self.size.x = old_size_x
  return x, y, w, h
end

-- 3. Hook target_tab_width so tab logic allocates the correct space
local old_target_tab_width = Node.target_tab_width
function Node:target_tab_width()
  local old_size_x = self.size.x
  if is_editor_node(self) then self.size.x = self.size.x - get_btn_info() end
  local res = old_target_tab_width(self)
  self.size.x = old_size_x
  return res
end

-- 3.5. Hook get_max_tab_shift so we can scroll to the last tab fully
local old_get_max_tab_shift = Node.get_max_tab_shift
function Node:get_max_tab_shift()
  local old_size_x = self.size.x
  if is_editor_node(self) then self.size.x = self.size.x - get_btn_info() end
  local res = old_get_max_tab_shift(self)
  self.size.x = old_size_x
  return res
end

-- 4. Hook draw_tabs to draw our beautiful close-all button at the end AND completely remove arrows!
local old_draw_tabs = Node.draw_tabs
function Node:draw_tabs(...)
  local is_editor = is_editor_node(self)
  local old_size_x = self.size.x
  local bw = is_editor and get_btn_info() or 0
  
  -- Push clip rect to prevent tabs from bleeding past the X button
  local th = (self.get_tab_height and self:get_tab_height()) or (style and style.tab_height) or 24
  core.push_clip_rect(self.position.x, self.position.y, self.size.x - bw, th)
  
  -- Trick the engine into infinite width so it NEVER draws the scroll arrows or dropdown
  self.size.x = 999999 
  old_draw_tabs(self, ...)
  self.size.x = old_size_x
  
  core.pop_clip_rect()
  
  if not is_editor then return end
  
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

-- Prevent invisible arrows from triggering clicks, but do NOT spoof size.x
-- because spoofing it breaks get_tab_overlapping_point bounds and max tab shift!
local old_node_on_mouse_pressed = Node.on_mouse_pressed
function Node:on_mouse_pressed(button, x, y, clicks)
  local old_size_x = self.size.x
  if is_editor_node(self) then self.size.x = self.size.x - get_btn_info() end
  local res = old_node_on_mouse_pressed(self, button, x, y, clicks)
  self.size.x = old_size_x
  return res
end

local old_node_on_mouse_moved = Node.on_mouse_moved
function Node:on_mouse_moved(x, y, dx, dy)
  local old_size_x = self.size.x
  if is_editor_node(self) then self.size.x = self.size.x - get_btn_info() end
  local res = old_node_on_mouse_moved(self, x, y, dx, dy)
  self.size.x = old_size_x
  return res
end

-- 5. Hook RootView for accurate hover states of the X button
local old_on_mouse_moved_root = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, dx, dy)
  local node = self.root_node:get_child_overlapping_point(x, y)
  local hnode = nil
  if is_editor_node(node) then
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
  
  return old_on_mouse_moved_root(self, x, y, dx, dy)
end

-- 6. Hook RootView to intercept clicks and safely close all tabs
local old_on_mouse_pressed_root = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  local node = self.root_node:get_child_overlapping_point(x, y)
  if is_editor_node(node) then
    local bw = get_btn_info()
    local bx = node.position.x + node.size.x - bw
    local by = node.position.y
    local bh = style.font:get_height() + style.padding.y * 2
    if x >= bx and x <= bx + bw and y >= by and y <= by + bh then
      if button == "left" then
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
  return old_on_mouse_pressed_root(self, button, x, y, clicks)
end
