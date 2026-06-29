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
  -- Full sidebar background
  renderer.draw_rect(
    self.position.x, self.position.y,
    self.size.x,     self.size.y,
    style.background2
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

  orig_draw(self)
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
