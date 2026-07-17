-- mod-version:3
-- Fixes Lite-XL native titleview control buttons having dead-zones

local TitleView = require "core.titleview"

function TitleView:on_mouse_moved(px, py, ...)
  if self.size.y == 0 then return end
  TitleView.super.on_mouse_moved(self, px, py, ...)
  self.hovered_item = nil
  for item, x, y, w, h in self:each_control_item() do
    -- The buttons are drawn at x, but they have spacing between them.
    -- w is the width of the icon itself. The spacing is exactly w.
    -- So each button theoretically owns a block of size w * 2.
    -- By expanding the hit detection to x + w * 2, the blocks become contiguous.
    -- By expanding the y detection to 0 .. self.size.y, we remove top/bottom dead zones.
    if px >= x and py >= 0 and px < x + w * 2 and py <= self.size.y then
      self.hovered_item = item
      return
    end
  end
end
