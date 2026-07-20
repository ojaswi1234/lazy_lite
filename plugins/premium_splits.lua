-- mod-version:3
local core = require "core"
local style = require "core.style"
local Node = require "core.node"
local DocView = require "core.docview"
-- Helper to check if a node contains an editor (DocView) and NOT a terminal or treeview
local function contains_editor(node)
  if node.type == "leaf" then
    local has_doc = false
    for _, view in ipairs(node.views) do
      if view:is(DocView) then has_doc = true end
      if view.get_name and view:get_name() == "Terminal" then return false end
    end
    return has_doc
  else
    return contains_editor(node.a) or contains_editor(node.b)
  end
end

local GAP_SIZE = 12

local old_update_layout = Node.update_layout
function Node:update_layout(...)
  local is_editor_split = false
  if self.type ~= "leaf" then
    is_editor_split = contains_editor(self.a) and contains_editor(self.b)
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
    is_editor_split = contains_editor(self.a) and contains_editor(self.b)
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
    is_editor_split = contains_editor(self.a) and contains_editor(self.b)
  end

  local old_div = style.divider
  if is_editor_split then
    style.divider = style.background or {0,0,0,0}
  end
  
  old_draw(self, ...)
  
  style.divider = old_div
end
