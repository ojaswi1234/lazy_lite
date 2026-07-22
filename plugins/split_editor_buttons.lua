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
-- Walk the node tree to find the parent of `target`.
local function find_parent(root, target)
  if root.type == "leaf" then return nil end
  if root.a == target or root.b == target then return root end
  return find_parent(root.a, target) or find_parent(root.b, target)
end

-- Recursively close all views in a node so it collapses/merges away.
local function close_node_views(n)
  if n.type == "leaf" then
    -- snapshot the list first; close_view mutates n.views
    local views = {table.unpack(n.views)}
    for _, v in ipairs(views) do
      pcall(function() n:close_view(core.root_view.root_node, v) end)
    end
  else
    -- close b first so the tree merges cleanly top-down
    close_node_views(n.b)
    close_node_views(n.a)
  end
end

-- Toggle split for `node` in `dir` ("right"→hsplit, "down"→vsplit).
--   • If `node` is already the LEFT/TOP child of the matching split type,
--     collapse the sibling (right/bottom pane) — acting as an undo.
--   • Otherwise, create a fresh split.
local function toggle_split(node, dir)
  local split_type = (dir == "right") and "hsplit" or "vsplit"
  local parent = find_parent(core.root_view.root_node, node)

  if parent and parent.type == split_type and parent.a == node then
    -- Already split in this direction from our node → collapse sibling
    close_node_views(parent.b)
  else
    -- Not yet split (or we are the secondary pane) → create split
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
