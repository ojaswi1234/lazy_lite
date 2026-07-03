-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local style = require "themes.mossy_theme" or require "core.style"

-- Placeholder for our custom modal state
local modal = {
  active = false,
  state = "auth", -- "auth" or "list"
  token_input = "",
  codespaces = {},
  selected_index = 1,
}

-- Add GitHub button to status bar
local status_view = require "core.statusview"
if status_view then
  core.status_view:add_item({
    name = "codespaces",
    alignment = status_view.Item.RIGHT,
    get_item = function()
      local color = modal.active and style.accent or style.text
      return { color, " GitHub Codespaces" }
    end,
    on_click = function()
      modal.active = not modal.active
      if modal.active then
        -- Trigger check auth in background later
      end
    end
  })
end

-- Hook drawing to render the floating modal
local old_root_draw = core.root_view.draw
function core.root_view:draw()
  old_root_draw(self)
  
  if not modal.active then return end
  
  local w = 600 * SCALE
  local h = 400 * SCALE
  local x = (self.size.x - w) / 2
  local y = (self.size.y - h) / 2
  
  -- Dim background
  renderer.draw_rect(0, 0, self.size.x, self.size.y, { 10, 10, 15, 180 })
  
  -- Modal Window
  renderer.draw_rect(x, y, w, h, { 30, 30, 35, 255 })
  -- Border
  local border = 2 * SCALE
  local accent = { 100, 200, 150, 255 }
  renderer.draw_rect(x, y, w, border, accent)
  renderer.draw_rect(x, y + h - border, w, border, accent)
  renderer.draw_rect(x, y, border, h, accent)
  renderer.draw_rect(x + w - border, y, border, h, accent)
  
  -- Title
  local title_font = style.big_font or style.font
  renderer.draw_text(title_font, "GitHub Codespaces Integration", x + 30 * SCALE, y + 20 * SCALE, { 255, 255, 255, 255 })
  
  if modal.state == "auth" then
    renderer.draw_text(style.font, "Please authenticate with GitHub to view your codespaces.", x + 30 * SCALE, y + 60 * SCALE, { 200, 200, 200, 255 })
    
    -- Input Box for Token
    local iw = w - 60 * SCALE
    local ih = 35 * SCALE
    local ix = x + 30 * SCALE
    local iy = y + 100 * SCALE
    renderer.draw_rect(ix, iy, iw, ih, { 20, 20, 25, 255 })
    renderer.draw_rect(ix, iy, iw, 1 * SCALE, { 80, 80, 90, 255 })
    
    local display_text = #modal.token_input > 0 and string.rep("*", #modal.token_input) or "Paste Personal Access Token here..."
    local text_color = #modal.token_input > 0 and { 255, 255, 255, 255 } or { 100, 100, 110, 255 }
    renderer.draw_text(style.font, display_text, ix + 10 * SCALE, iy + 10 * SCALE, text_color)
    
    -- Helper Text
    renderer.draw_text(style.font, "Press ENTER to login or ESC to cancel.", x + 30 * SCALE, iy + 50 * SCALE, { 150, 150, 160, 255 })
  end
end

-- Intercept Events for Modal
local old_on_event = core.on_event
function core.on_event(type, ...)
  if modal.active then
    if type == "textinput" then
      local text = ...
      if modal.state == "auth" then
        modal.token_input = modal.token_input .. text
        core.redraw = true
        return true -- consume event
      end
    elseif type == "keypressed" then
      local key = ...
      if key == "escape" then
        modal.active = false
        core.redraw = true
        return true
      elseif key == "backspace" and modal.state == "auth" then
        modal.token_input = modal.token_input:sub(1, -2)
        core.redraw = true
        return true
      elseif key == "return" and modal.state == "auth" then
        core.log("Attempting GitHub Login...")
        -- trigger background login here
        return true
      end
    elseif type == "mousepressed" then
      -- If clicked outside modal, close it
      local x, y, button = ...
      local w = 600 * SCALE
      local h = 400 * SCALE
      local mx = (core.root_view.size.x - w) / 2
      local my = (core.root_view.size.y - h) / 2
      if x < mx or x > mx + w or y < my or y > my + h then
        modal.active = false
        core.redraw = true
      end
      return true
    end
  end
  return old_on_event(type, ...)
end

return {
  name = "GitHub Codespaces",
  description = "A massive integration for cloud development."
}
