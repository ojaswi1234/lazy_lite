-- mod-version:3
-- Mossy green styled tree view with Nerd Font file icons

local core     = require "core"
local config   = require "core.config"
local style    = require "core.style"
local command  = require "core.command"
local common   = require "core.common"
local icons    = require "plugins.mossy_icons"
local TreeView = require "plugins.treeview"

config.treeview_size = 240 * SCALE

local function get_contrast_bg(bg)
  if type(bg) ~= "table" then return bg end
  local r, g, b, a = bg[1], bg[2], bg[3], bg[4] or 255
  local lum = (r * 0.299 + g * 0.587 + b * 0.114)
  if lum > 128 then
    -- Light theme: darken by 8%
    return { math.max(0, math.floor(r * 0.92)), math.max(0, math.floor(g * 0.92)), math.max(0, math.floor(b * 0.92)), a }
  else
    -- Dark theme: lighten by 8%
    return { math.min(255, math.floor(r + (255 - r) * 0.08)), math.min(255, math.floor(g + (255 - g) * 0.08)), math.min(255, math.floor(b + (255 - b) * 0.08)), a }
  end
end

-- ── Item draw override ────────────────────────────────────────────────────────
local orig_draw_item = TreeView.draw_item

function TreeView:draw_item(item, active, hovered, x, y, w, h)
  -- Row background
  if active then
    renderer.draw_rect(x, y, w, h, style.selection)
  elseif hovered then
    renderer.draw_rect(x, y, w, h, style.line_highlight)
  end

  -- Indent guides
  local depth = item.depth or 0
  local step  = 20 * SCALE
  for d = 1, depth do
    local gx = x + (d - 1) * step + 8 * SCALE
    renderer.draw_rect(gx, y, 1 * SCALE, h, style.divider)
  end

  -- Icon (guard: icon_font may be nil on some builds, fall back to style.font)
  local ifont      = style.icon_font or style.font
  local icon_str   = icons.get(item.name, item.type == "dir", item.expanded)
  local icon_color = (active or hovered) and style.text or style.dim
  local icon_x     = x + depth * step + 6 * SCALE

  renderer.draw_text(
    ifont, icon_str,
    icon_x,
    y + math.floor((h - ifont:get_height()) / 2),
    icon_color
  )

  -- Filename
  local name_x     = icon_x + ifont:get_width(icon_str) + 4 * SCALE
  local text_color = (active or hovered) and style.text or style.dim

  renderer.draw_text(
    style.font, item.name,
    name_x,
    y + math.floor((h - style.font:get_height()) / 2),
    text_color
  )
end

-- ── Sidebar background + EXPLORER header ─────────────────────────────────────
local orig_draw = TreeView.draw

function TreeView:draw()
  local sidebar_bg = get_contrast_bg(style.background)
  
  -- Full sidebar background
  renderer.draw_rect(
    self.position.x, self.position.y,
    self.size.x,     self.size.y,
    sidebar_bg
  )

  -- "EXPLORER" header band
  local hdr_h = 28 * SCALE
  renderer.draw_rect(
    self.position.x, self.position.y,
    self.size.x, hdr_h,
    style.background3 or style.selection
  )
  renderer.draw_text(
    style.font, "  EXPLORER",
    self.position.x + 8 * SCALE,
    self.position.y + math.floor((hdr_h - style.font:get_height()) / 2),
    style.text
  )

  -- Draw "Open Folder" button icon
  local btn_w = 24 * SCALE
  local btn_x = self.position.x + self.size.x - btn_w - 4 * SCALE
  local ifont = style.icon_font or style.font
  local icon = "" -- folder icon
  
  local mx, my = core.root_view.mouse.x, core.root_view.mouse.y
  local hovered = (mx >= btn_x and mx <= btn_x + btn_w and my >= self.position.y and my <= self.position.y + hdr_h)

  if hovered then
    renderer.draw_rect(btn_x, self.position.y + 2 * SCALE, btn_w, hdr_h - 4 * SCALE, style.line_highlight)
  end

  local iw = ifont:get_width(icon)
  renderer.draw_text(
    ifont, icon,
    btn_x + (btn_w - iw) / 2,
    self.position.y + math.floor((hdr_h - ifont:get_height()) / 2),
    hovered and style.text or style.dim
  )

  orig_draw(self)
end
local orig_on_mouse_pressed = TreeView.on_mouse_pressed

function TreeView:on_mouse_pressed(button, x, y, clicks)
  local hdr_h = 28 * SCALE
  if button == "left" and y >= self.position.y and y <= self.position.y + hdr_h then
    local btn_w = 24 * SCALE
    local btn_x = self.position.x + self.size.x - btn_w - 4 * SCALE
    if x >= btn_x and x <= btn_x + btn_w then
      command.perform("core:change-project-folder")
      return true
    end
  end
  if orig_on_mouse_pressed then
    return orig_on_mouse_pressed(self, button, x, y, clicks)
  end
end

-- ── Commands ──────────────────────────────────────────────────────────────────
-- NOTE: treeview:toggle is already defined by the built-in treeview plugin
-- (it sets view.visible). We only need to override treeview:focus here.
-- Redefining treeview:toggle would conflict — so we leave it to the built-in.

command.add(nil, {
  ["treeview:focus"] = function()
    -- get_children() recursively collects all views in the node tree
    local views = core.root_view.root_node:get_children()
    for _, view in ipairs(views) do
      if view:is(TreeView) then
        core.set_active_view(view)
        return
      end
    end
  end,
})
