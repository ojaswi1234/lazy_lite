-- mod-version:3
-- Fixes Lite-XL native titleview control buttons having dead-zones

local TitleView = require "core.titleview"
local core = require "core"

function TitleView:on_mouse_moved(px, py, ...)
  if self.size.y == 0 then return end
  TitleView.super.on_mouse_moved(self, px, py, ...)
  self.hovered_item = nil
  for item, x, y, w, h in self:each_control_item() do
    if px >= x and py >= 0 and px < x + w * 2 and py <= self.size.y then
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
