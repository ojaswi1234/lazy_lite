-- mod-version:3
local core = require "core"
local style = require "core.style"
local renderer = require "renderer"
local command = require "core.command"

local show_tools = false
local menu_w = 160 * SCALE
local item_h = 30 * SCALE
local padding = 10 * SCALE
local menu_items = {
  { name = "LeetCode", cmd = "leetcode:toggle" },
  { name = "MongoDB", cmd = "mongodb:toggle" }
}
local menu_h = #menu_items * item_h + padding * 2

-- Remove the individual items by hooking add_item
local old_add_item = core.status_view.add_item
function core.status_view:add_item(item)
  if item.name == "leetcode" or item.name == "mongodb" or item.name == "mongodb_explorer" then
    return -- Block these from cluttering the status bar
  end
  return old_add_item(self, item)
end

-- Also forcefully remove them in case they were already added
core.add_thread(function()
  while true do
    core.status_view:remove_item("leetcode")
    core.status_view:remove_item("mongodb")
    core.status_view:remove_item("mongodb_explorer")
    coroutine.yield(1)
  end
end)

-- Add the new Tools dropdown item
core.status_view:add_item({
  name = "tools_menu",
  alignment = core.status_view.Item.RIGHT,
  position = 1,
  tooltip = "Tools Menu",
  get_item = function()
    local text = " Tools " .. (show_tools and "▼" or "▲") .. " "
    return {
      style.text, style.font, text
    }
  end,
  command = "tools-menu:toggle"
})

command.add(nil, {
  ["tools-menu:toggle"] = function()
    show_tools = not show_tools
    core.redraw = true
  end
})

-- Draw the menu on the root view so it floats globally above everything
local old_root_draw = core.root_view.draw
function core.root_view:draw(...)
  old_root_draw(self, ...)
  
  if show_tools then
    local menu_x = self.size.x - menu_w - 20 * SCALE
    local menu_y = core.status_view.position.y - menu_h
    
    renderer.draw_rect(menu_x, menu_y, menu_w, menu_h, style.background2)
    renderer.draw_rect(menu_x, menu_y, menu_w, 1*SCALE, style.dim) -- top border
    renderer.draw_rect(menu_x, menu_y, 1*SCALE, menu_h, style.dim) -- left
    renderer.draw_rect(menu_x + menu_w, menu_y, 1*SCALE, menu_h, style.dim) -- right
    
    local my = menu_y + padding
    for _, item in ipairs(menu_items) do
      renderer.draw_text(style.font, item.name, menu_x + 15*SCALE, my + 4*SCALE, style.text)
      my = my + item_h
    end
  end
end

-- Intercept clicks globally if the menu is open
local old_root_mouse = core.root_view.on_mouse_pressed
function core.root_view:on_mouse_pressed(button, x, y, clicks)
  if show_tools then
    local menu_x = self.size.x - menu_w - 20 * SCALE
    local menu_y = core.status_view.position.y - menu_h
    
    show_tools = false
    core.redraw = true
    
    if x >= menu_x and x <= menu_x + menu_w and y >= menu_y and y <= menu_y + menu_h then
      local rel_y = y - (menu_y + padding)
      local idx = math.floor(rel_y / item_h) + 1
      if idx >= 1 and idx <= #menu_items then
        command.perform(menu_items[idx].cmd)
      end
      return true
    end
  end
  return old_root_mouse(self, button, x, y, clicks)
end
