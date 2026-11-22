-- mod-version:3
-- Fixes Lite-XL native titleview control buttons having dead-zones,
-- prevents button hitbox collisions, and guarantees zero text overlap
-- across window title, resource monitor charts, and window controls.

local TitleView = require "core.titleview"
local core = require "core"
local style = require "core.style"
local command = require "core.command"
local config = require "core.config"
local system = require "system"

-- 1. Precision hit-testing for window control buttons (no dead-zones, zero boundary theft)
function TitleView:on_mouse_moved(px, py, ...)
  if self.size.y == 0 then return end
  TitleView.super.on_mouse_moved(self, px, py, ...)
  self.hovered_item = nil
  for item, x, y, w, h in self:each_control_item() do
    -- Accurately partition spacing so each button owns [x - w*0.5, x + w*1.5)
    if px >= x - w * 0.5 and px < x + w * 1.5 and py >= 0 and py <= self.size.y then
      self.hovered_item = item
      return
    end
  end
end

function TitleView:on_mouse_pressed(button, x, y, clicks)
  local caught = TitleView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then return end
  if core.last_active_view then core.set_active_view(core.last_active_view) end
  if self.hovered_item then
    self.hovered_item.action()
    return true
  end
  if clicks == 2 and button == "left" then
    local mode = system.get_window_mode()
    if mode == "maximized" then
      system.set_window_mode("normal")
    else
      system.set_window_mode("maximized")
    end
    return true
  end
end

-- Clear hover state immediately when mouse exits title view to prevent stuck hover or accidental clicks
function TitleView:on_mouse_left()
  TitleView.super.on_mouse_left(self)
  self.hovered_item = nil
  core.redraw = true
end

-- 2. Prevent window title text from overlapping resource monitor and window control buttons
local old_draw_window_title = TitleView.draw_window_title
function TitleView:draw_window_title()
  local icon_w = style.icon_font:get_width("_")
  local controls_width = (icon_w + icon_w) * 3 + icon_w
  local res_mon_w = package.loaded["plugins.resource_monitor"] and (240 * SCALE) or 0
  local max_title_w = math.max(60 * SCALE, self.size.x - controls_width - res_mon_w - style.padding.x * 2)

  local ox, oy = self:get_content_offset()
  local x, y = ox + style.padding.x, oy + style.padding.y
  local h = style.font:get_height()

  core.push_clip_rect(x, y, max_title_w, h + style.padding.y * 2)
  old_draw_window_title(self)
  core.pop_clip_rect()
end

-- 3. Override fullscreen toggle to keep the title bar visible
command.add(nil, {
  ["core:toggle-fullscreen"] = function()
    local is_fullscreen = (core.window_mode == "fullscreen" or system.get_window_mode() == "fullscreen")
    if is_fullscreen then
      system.set_window_mode("normal")
      core.show_title_bar(config.borderless)
      core.title_view:configure_hit_test(config.borderless)
    else
      system.set_window_mode("fullscreen")
      -- Keep the title bar visible instead of hiding it!
      core.show_title_bar(true)
      core.title_view:configure_hit_test(true)
    end
  end
})
