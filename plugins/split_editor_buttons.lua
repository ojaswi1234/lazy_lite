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

-- ── Cache real size in update() ────────────────────────────────────────────
-- Node:update() runs every frame with true layout dimensions, before any hook
-- (like close_all_tabs) can spoof self.size.x. It is the only safe place.
local old_update = Node.update
function Node:update(...)
  if self.type == "leaf" and is_editor_node(self) then
    self._real_size_x = self.size.x
  end
  return old_update(self, ...)
end

-- ── Toggle-split helpers ────────────────────────────────────────────────────
-- Recursively close all views in a node using Node's own remove_view API.
-- This correctly handles collapse when the last view is removed.
local function close_node_views(n, root)
  if n.type == "leaf" then
    local views = {table.unpack(n.views)}
    for _, v in ipairs(views) do
      pcall(function() n:remove_view(root, v) end)
    end
  else
    close_node_views(n.b, root)
    close_node_views(n.a, root)
  end
end

-- Toggle split for `node` in `dir` ("right"→hsplit, "down"→vsplit).
--   • Uses the built-in get_parent_node() API to reliably find the parent.
--   • If node is the LEFT/TOP child (a) of the matching split, collapses it.
--   • Empty sibling (fresh split) → parent:consume(node) directly.
--   • Non-empty sibling → close each view via remove_view (triggers collapse).
local function toggle_split(node, dir)
  local split_type = (dir == "right") and "hsplit" or "vsplit"
  local root = core.root_view.root_node
  local parent = node:get_parent_node(root)

  if parent and parent.type == split_type and parent.a == node then
    local sibling = parent.b
    if sibling:is_empty() then
      -- Fresh empty split pane — just consume directly (same as Lite XL internals)
      parent:consume(node)
    else
      -- Sibling has files — close them via remove_view (prompts for unsaved)
      close_node_views(sibling, root)
    end
    core.redraw = true
  else
    node:split(dir)
  end
end

-- ── Draw split buttons ──────────────────────────────────────────────────────
-- Layout (right → left):  [ v ][ >> ][ X close-all ] | tabs...
--
-- close_all_tabs.lua reserves:  total_bw = x_btn_w + 50*SCALE on the right.
--   X button  →  [real_right - x_btn_w - 50*SCALE,  real_right - 50*SCALE]
--   our slot  →  [real_right - 50*SCALE,             real_right           ]
--     >>  →  [real_right - 50*SCALE,  real_right - 25*SCALE]
--      v  →  [real_right - 25*SCALE,  real_right           ]
local old_draw_tabs = Node.draw_tabs
function Node:draw_tabs(...)
  old_draw_tabs(self, ...)

  if not is_editor_node(self) then return end

  local real_right = self.position.x + (self._real_size_x or self.size.x)
  local btn_w = 25 * SCALE

  local th = style.font:get_height() + (style.padding.y * 2)
  if self.tab_height then th = self.tab_height end

  -- Detect active split state for visual feedback
  local parent = find_parent(core.root_view.root_node, self)
  local is_split_right = parent and parent.type == "hsplit" and parent.a == self
  local is_split_down  = parent and parent.type == "vsplit" and parent.a == self

  local bx_down  = real_right - btn_w           -- v  (rightmost)
  local bx_right = real_right - 2 * btn_w       -- >> (left of v)
  local by    = self.position.y
  local icon_y = by + (th - style.icon_font:get_height()) / 2

  core.push_clip_rect(self.position.x, by, real_right - self.position.x, th)

  -- Split Right Button (>>) — lit up when split is active
  local hovered_right = (self.hovered_split == "right")
  local col_right = hovered_right and style.accent
                 or is_split_right and style.text
                 or style.dim
  renderer.draw_text(style.icon_font, "\u{f054}", bx_right, icon_y, col_right)

  -- Split Down Button (v) — lit up when split is active
  local hovered_down = (self.hovered_split == "down")
  local col_down = hovered_down and style.accent
                or is_split_down and style.text
                or style.dim
  renderer.draw_text(style.icon_font, "\u{f078}", bx_down, icon_y, col_down)

  core.pop_clip_rect()
end

-- ── Mouse hover detection ───────────────────────────────────────────────────
local old_on_mouse_moved = Node.on_mouse_moved
function Node:on_mouse_moved(x, y, ...)
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

-- ── Click handling ──────────────────────────────────────────────────────────
local old_on_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  local node = self.root_node:get_child_overlapping_point(x, y)
  if button == "left" and node and node.hovered_split then
    toggle_split(node, node.hovered_split)
    node.hovered_split = nil
    core.redraw = true
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
