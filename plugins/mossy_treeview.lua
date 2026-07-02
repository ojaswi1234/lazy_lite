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
  
  if self.is_dragging and self.dnd_item then
    local ifont2 = style.icon_font or style.font
    local icon_str2 = icons.get(self.dnd_item.name, self.dnd_item.type == "dir", false)
    local mx, my = core.root_view.mouse.x, core.root_view.mouse.y
    local c_alpha = {255, 255, 255, 180}
    renderer.draw_text(ifont2, icon_str2, mx + 10, my + 10, c_alpha)
    renderer.draw_text(style.font, self.dnd_item.name, mx + 10 + ifont2:get_width(icon_str2) + 4, my + 10, c_alpha)
  end
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
  
  if button == "left" then
    self.dnd_start_x = x
    self.dnd_start_y = y
    self.dnd_item = self.hovered_item
    self.is_dragging = false
  end

  if orig_on_mouse_pressed then
    return orig_on_mouse_pressed(self, button, x, y, clicks)
  end
end

local orig_on_mouse_moved = TreeView.on_mouse_moved
function TreeView:on_mouse_moved(x, y, dx, dy)
  local res = orig_on_mouse_moved and orig_on_mouse_moved(self, x, y, dx, dy)
  
  if self.dnd_item then
    if not self.is_dragging then
      if math.abs(x - self.dnd_start_x) > 5 or math.abs(y - self.dnd_start_y) > 5 then
        self.is_dragging = true
      end
    end
  else
    self.dnd_item = nil
    self.is_dragging = false
  end
  
  return res
end

local orig_on_mouse_released = TreeView.on_mouse_released
function TreeView:on_mouse_released(button, x, y)
  if button == "left" and self.is_dragging and self.dnd_item then
    local target = self.hovered_item
    if target and target ~= self.dnd_item then
      -- Compute destination path
      local dest_dir = target.abs_filename
      if target.type ~= "dir" then
        dest_dir = common.dirname(target.abs_filename)
      end
      
      -- Avoid moving a directory inside itself or its children
      local src_abs = self.dnd_item.abs_filename
      local src_prefix = src_abs .. PATHSEP
      if dest_dir ~= src_abs and dest_dir:sub(1, #src_prefix) ~= src_prefix then
        local dest_path = dest_dir .. PATHSEP .. self.dnd_item.name
        if dest_path ~= src_abs then
          local ok, err = os.rename(src_abs, dest_path)
          if ok then
            core.log("Moved %s to %s", self.dnd_item.name, dest_path)
            -- update open docs if moved
            for _, doc in ipairs(core.docs) do
              if doc.abs_filename then
                if doc.abs_filename == src_abs or doc.abs_filename:sub(1, #src_prefix) == src_prefix then
                  local new_doc_path = dest_path .. doc.abs_filename:sub(#src_abs + 1)
                  -- For the relative filename, we let Lite XL re-normalize it by passing nil or a new name
                  -- but using doc.filename might be invalid. We can just use the basename or nil.
                  doc:set_filename(nil, new_doc_path)
                end
              end
            end
          else
            core.error("Failed to move %s: %s", self.dnd_item.name, err)
          end
        end
      end
    end
    self.dnd_item = nil
    self.is_dragging = false
  end
  
  if orig_on_mouse_released then
    return orig_on_mouse_released(self, button, x, y)
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
