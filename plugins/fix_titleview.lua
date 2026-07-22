-- mod-version:3
-- Fixes Lite-XL native titleview control buttons having dead-zones

local TitleView = require "core.titleview"
local core = require "core"

function TitleView:on_mouse_moved(px, py, ...)
  if self.size.y == 0 then return end
  TitleView.super.on_mouse_moved(self, px, py, ...)
  self.hovered_item = nil
  for item, x, y, w, h in self:each_control_item() do
    if px >= x and py >= 0 and px <= x + w * 2 and py <= self.size.y then
      self.hovered_item = item
      return
    end
  end
end

function TitleView:on_mouse_pressed(button, x, y, clicks)
  local caught = TitleView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then return end
  core.set_active_view(core.last_active_view)
  if self.hovered_item then
    self.hovered_item.action()
    return true
  end
end

-- Override fullscreen toggle to keep the title bar visible
local command = require "core.command"
local config = require "core.config"
local system = require "system"

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
