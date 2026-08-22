-- mod-version:3
local core = require "core"
local style = require "core.style"
local Node = require "core.node"
local DocView = require "core.docview"
-- Helper to check if a node contains an editor (DocView) and NOT a terminal or treeview
local function is_editor_leaf(node)
  if node.type ~= "leaf" then return false end
  local has_doc = false
  for _, view in ipairs(node.views) do
    if view:is(DocView) then has_doc = true end
    if view.get_name then
      local name = view:get_name()
      if name == "Terminal" or name == "Antigravity" or name == "Tree" then return false end
    end
  end
  return has_doc
end

local function check_boundary_leaves_editor(node, split_type, side)
  if node.type == "leaf" then return is_editor_leaf(node) end
  if node.type == split_type then
    if side == "left" or side == "top" then
      return check_boundary_leaves_editor(node.a, split_type, side)
    else
      return check_boundary_leaves_editor(node.b, split_type, side)
    end
  else
    return check_boundary_leaves_editor(node.a, split_type, side) and check_boundary_leaves_editor(node.b, split_type, side)
  end
end

local function is_editor_split_boundary(node)
  if node.type == "leaf" then return false end
  local split_type = node.type
  local is_a_editor = check_boundary_leaves_editor(node.a, split_type, split_type == "hsplit" and "right" or "bottom")
  if not is_a_editor then return false end
  return check_boundary_leaves_editor(node.b, split_type, split_type == "hsplit" and "left"  or "top")
end

local GAP_SIZE = 12

local old_update_layout = Node.update_layout
function Node:update_layout(...)
  local is_editor_split = false
  if self.type ~= "leaf" then
    is_editor_split = is_editor_split_boundary(self)
  end
  
  local old_size = style.divider_size
  if is_editor_split then
    style.divider_size = GAP_SIZE * SCALE
  end
  
  old_update_layout(self, ...)
  
  style.divider_size = old_size
end

local old_get_divider_rect = Node.get_divider_rect
function Node:get_divider_rect(...)
  local is_editor_split = false
  if self.type ~= "leaf" then
    is_editor_split = is_editor_split_boundary(self)
  end
  
  local old_size = style.divider_size
  if is_editor_split then
    style.divider_size = GAP_SIZE * SCALE
  end
  
  local x, y, w, h = old_get_divider_rect(self, ...)
  
  style.divider_size = old_size
  return x, y, w, h
end

local old_draw = Node.draw
function Node:draw(...)
  local is_editor_split = false
  if self.type ~= "leaf" then
    is_editor_split = is_editor_split_boundary(self)
  end

  local old_div = style.divider
  if is_editor_split then
    style.divider = style.background or {0,0,0,0}
  end
  
  old_draw(self, ...)
  
  style.divider = old_div
end
