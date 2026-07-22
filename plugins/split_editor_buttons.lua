-- mod-version:3
local core = require "core"
local style = require "core.style"
local Node = require "core.node"
local RootView = require "core.rootview"

local DocView = require "core.docview"

local function is_editor_node(node)
  if not node or node.type ~= "leaf" or not node.views then return false end
  for _, v in ipairs(node.views) do
    if v:is(DocView) then return true end
  end
  return false
end

local old_draw_tabs = Node.draw_tabs
function Node:draw_tabs(...)
  old_draw_tabs(self, ...)
  
  if not is_editor_node(self) then return end
  
  -- Draw split buttons on the right side of the tab bar.
  -- Layout (right → left):  [v down][>> right][  X close-all  ] | tabs...
  -- close_all_tabs reserves total_bw = x_btn_w + 50*SCALE on the right.
  --   X button starts at:  real_right - x_btn_w - 50*SCALE, width = x_btn_w
  --   50*SCALE slot (for us) is: [real_right - 50*SCALE, real_right]
  --     v  button: [real_right - 25*SCALE, real_right]
  --     >> button: [real_right - 50*SCALE, real_right - 25*SCALE]
  local real_right = self.position.x + (self._real_size_x or self.size.x)
  local btn_w = 25 * SCALE

  local th = style.font:get_height() + (style.padding.y * 2)
  if self.tab_height then th = self.tab_height end

  local bx_down  = real_right - btn_w           -- v  (rightmost)
  local bx_right = real_right - 2 * btn_w       -- >> (left of v)
  local by = self.position.y
  local icon_y = by + (th - style.icon_font:get_height()) / 2

  core.push_clip_rect(self.position.x, by, real_right - self.position.x, th)

  -- Split Right Button (>>)
  local hovered_right = (self.hovered_split == "right")
  renderer.draw_text(style.icon_font, "\u{f054}", bx_right, icon_y, hovered_right and style.accent or style.dim)

  -- Split Down Button (v)
  local hovered_down = (self.hovered_split == "down")
  renderer.draw_text(style.icon_font, "\u{f078}", bx_down, icon_y, hovered_down and style.accent or style.dim)

  core.pop_clip_rect()

  -- Save real size.x for mouse hit-testing (it may have been spoofed by close_all_tabs)
  self._real_size_x = self._real_size_x or self.size.x
end

local old_on_mouse_moved = Node.on_mouse_moved
function Node:on_mouse_moved(x, y, ...)
  -- Keep real size fresh (it may get spoofed by close_all_tabs mid-call)
  if is_editor_node(self) then
    self._real_size_x = self.size.x
  end
  local res = old_on_mouse_moved(self, x, y, ...)
  if not is_editor_node(self) then return res end

  local th = style.font:get_height() + (style.padding.y * 2)
  if self.tab_height then th = self.tab_height end

  self.hovered_split = nil
  if y >= self.position.y and y <= self.position.y + th then
    local real_right = self.position.x + (self._real_size_x or self.size.x)
    local btn_w    = 25 * SCALE
    local bx_down  = real_right - btn_w
    local bx_right = real_right - 2 * btn_w

    if x >= bx_down and x < bx_down + btn_w then
      self.hovered_split = "down"
      core.request_cursor("hand")
      return true
    end
    if x >= bx_right and x < bx_right + btn_w then
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
