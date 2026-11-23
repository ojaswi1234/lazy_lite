-- mod-version:3
local core = require "core"
local command = require "core.command"
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
local function get_x_btn_width()
  return style.icon_font:get_width("X") + 16 * SCALE
end

local function get_tab_spacing(node)
  if node and node.size and node.size.x < 180 * SCALE then
    return 0
  end
  local w = get_x_btn_width()
  if package.loaded["plugins.split_editor_buttons"] then
    w = w + 50 * SCALE
  end
  return w
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
  if is_editor_node(self) then self.size.x = self.size.x - get_tab_spacing() end
  local x, y, w, h = old_get_tab_rect(self, idx)
  self.size.x = old_size_x
  return x, y, w, h
end

-- 3. Hook target_tab_width so tab logic allocates the correct space
local old_target_tab_width = Node.target_tab_width
function Node:target_tab_width()
  local old_size_x = self.size.x
  if is_editor_node(self) then self.size.x = self.size.x - get_tab_spacing() end
  local res = old_target_tab_width(self)
  self.size.x = old_size_x
  return res
end

-- 3.5. Hook get_max_tab_shift so we can scroll to the last tab fully
local old_get_max_tab_shift = Node.get_max_tab_shift
function Node:get_max_tab_shift()
  local old_size_x = self.size.x
  if is_editor_node(self) then self.size.x = self.size.x - get_tab_spacing() end
  local res = old_get_max_tab_shift(self)
  self.size.x = old_size_x
  return res
end

-- 4. Hook draw_tabs to draw our beautiful close-all button at the end AND completely remove arrows!
local old_draw_tabs = Node.draw_tabs
function Node:draw_tabs(...)
  local is_editor = is_editor_node(self)
  local total_bw = is_editor and get_tab_spacing(self) or 0
  
  -- Push clip rect to prevent tabs from bleeding past the buttons
  local th = (self.get_tab_height and self:get_tab_height()) or (style and style.tab_height) or 24
  core.push_clip_rect(self.position.x, self.position.y, self.size.x - total_bw, th)
  
  old_draw_tabs(self, ...)
  
  core.pop_clip_rect()
  
  if not is_editor or total_bw == 0 then return end
  
  local xw = get_x_btn_width()
  local bx = self.position.x + self.size.x - total_bw
  local by = self.position.y
  local bh = style.font:get_height() + style.padding.y * 2
  
  local is_hover = (hovered_node == self)
  
  -- Draw hover state
  renderer.draw_rect(bx, by, xw, bh, is_hover and style.background3 or style.background2)
  local ds = style.divider_size
  renderer.draw_rect(bx, by + bh - ds, xw, ds, style.divider)
  
  -- Draw 'X' icon
  local text_color = is_hover and style.accent or style.text
  common.draw_text(style.icon_font, text_color, "X", "center", bx, by, xw, bh)
end

-- Prevent invisible arrows from triggering clicks, but do NOT spoof size.x
-- because spoofing it breaks get_tab_overlapping_point bounds and max tab shift!
local old_node_on_mouse_pressed = Node.on_mouse_pressed
function Node:on_mouse_pressed(button, x, y, clicks)
  local old_size_x = self.size.x
  if is_editor_node(self) then self.size.x = self.size.x - get_tab_spacing() end
  local res = old_node_on_mouse_pressed(self, button, x, y, clicks)
  self.size.x = old_size_x
  return res
end

local old_node_on_mouse_moved = Node.on_mouse_moved
function Node:on_mouse_moved(x, y, dx, dy)
  local old_size_x = self.size.x
  if is_editor_node(self) then self.size.x = self.size.x - get_tab_spacing() end
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
    local total_bw = get_tab_spacing()
    local xw = get_x_btn_width()
    local bx = node.position.x + node.size.x - total_bw
    local by = node.position.y
    local bh = style.font:get_height() + style.padding.y * 2
    if x >= bx and x <= bx + xw and y >= by and y <= by + bh then
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
    local total_bw = get_tab_spacing()
    local xw = get_x_btn_width()
    local bx = node.position.x + node.size.x - total_bw
    local by = node.position.y
    local bh = style.font:get_height() + style.padding.y * 2
    if x >= bx and x <= bx + xw and y >= by and y <= by + bh then
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

    -- Real-World UX: Double click empty tab bar to open new document,
    -- and single click to focus pane without accidentally clicking into document code!
    if node:should_show_tabs() then
      local th = (node.get_tab_height and node:get_tab_height()) or (style and style.tab_height) or bh
      if y >= node.position.y and y <= node.position.y + th and x >= node.position.x and x < bx then
        local tab_idx = node:get_tab_overlapping_point(x, y)
        if not tab_idx and (not node.hovered_scroll_button or node.hovered_scroll_button == 0) then
          if button == "left" and clicks == 2 then
            command.perform("core:new-doc")
            return true
          elseif button == "left" and clicks == 1 then
            core.set_active_view(node.active_view)
            return true
          end
        end
      end
    end
  end
  return old_on_mouse_pressed_root(self, button, x, y, clicks)
end

-- 7. Hook RootView:on_mouse_wheel to enable seamless tab bar scrolling with the mouse wheel
local old_on_mouse_wheel_root = RootView.on_mouse_wheel
function RootView:on_mouse_wheel(y_delta, x_delta, ...)
  local x, y = self.mouse.x, self.mouse.y
  local node = self.root_node:get_child_overlapping_point(x, y)
  if node and is_editor_node(node) and node:should_show_tabs() then
    local th = (node.get_tab_height and node:get_tab_height()) or (style and style.tab_height) or (style.font:get_height() + style.padding.y * 2)
    if y >= node.position.y and y <= node.position.y + th and x >= node.position.x and x <= node.position.x + node.size.x then
      local delta = (y_delta and y_delta ~= 0) and y_delta or (x_delta and -x_delta or 0)
      if delta > 0 then
        node:scroll_tabs(1)
        core.redraw = true
        return true
      elseif delta < 0 then
        node:scroll_tabs(2)
        core.redraw = true
        return true
      end
      return true
    end
  end
  if old_on_mouse_wheel_root then
    return old_on_mouse_wheel_root(self, y_delta, x_delta, ...)
  end
end
