-- mod-version:3
-- Mossy green styled tree view with Nerd Font file icons

local core     = require "core"
local config   = require "core.config"
local style    = require "core.style"
local command  = require "core.command"
local keymap   = require "core.keymap"
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
  if not item or not item.name then
    return orig_draw_item(self, item, active, hovered, x, y, w, h)
  end

  -- Row background
  if active then
    renderer.draw_rect(x, y, w, h, (style.mossy and style.mossy.active_row) or style.selection)
  elseif hovered then
    renderer.draw_rect(x, y, w, h, (style.mossy and style.mossy.hover_row) or style.line_highlight)
  end

  -- Indent guides
  local depth = item.depth or 0
  local step  = 20 * SCALE
  for d = 1, depth do
    local gx = x + (d - 1) * step + 8 * SCALE
    renderer.draw_rect(gx, y, 1 * SCALE, h, (style.mossy and style.mossy.border) or style.divider)
  end

  -- Icon (guard: icon_font may be nil on some builds, fall back to style.font)
  local ifont      = style.icon_font or style.font
  local icon_str   = icons.get(item.name, item.type == "dir", item.expanded)
  
  local base_text  = (style.mossy and style.mossy.sidebar_text)  or style.text
  local base_dim   = (style.mossy and style.mossy.sidebar_muted) or style.dim
  local active_txt = (style.mossy and style.mossy.active_row_text) or base_text
  
  local icon_color = (active or hovered) and active_txt or base_dim
  local text_color = (active or hovered) and active_txt or base_text
  
  local icon_x     = x + depth * step + 6 * SCALE

  renderer.draw_text(
    ifont, icon_str,
    icon_x,
    y + math.floor((h - ifont:get_height()) / 2),
    icon_color
  )

  -- Filename
  local name_x     = icon_x + ifont:get_width(icon_str) + 4 * SCALE

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
  local sidebar_bg = (style.mossy and style.mossy.sidebar_bg) or get_contrast_bg(style.background)
  
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
    (style.mossy and style.mossy.activity_bg) or style.background3 or style.selection
  )
  renderer.draw_text(
    style.font, "  EXPLORER",
    self.position.x + 8 * SCALE,
    self.position.y + math.floor((hdr_h - style.font:get_height()) / 2),
    (style.mossy and style.mossy.sidebar_text) or style.text
  )

  -- Draw "Open Folder" button icon
  local btn_w = 24 * SCALE
  local btn_x = self.position.x + self.size.x - btn_w - 4 * SCALE
  local ifont = style.icon_font or style.font
  local icon = "" -- folder icon
  
  local mx, my = core.root_view.mouse.x, core.root_view.mouse.y
  local hovered = (mx >= btn_x and mx <= btn_x + btn_w and my >= self.position.y and my <= self.position.y + hdr_h)

  if hovered then
    renderer.draw_rect(btn_x, self.position.y + 2 * SCALE, btn_w, hdr_h - 4 * SCALE, (style.mossy and style.mossy.hover_row) or style.line_highlight)
  end

  local iw = ifont:get_width(icon)
  renderer.draw_text(
    ifont, icon,
    btn_x + (btn_w - iw) / 2,
    self.position.y + math.floor((hdr_h - ifont:get_height()) / 2),
    hovered and style.text or style.dim
  )

  local old_bg2 = style.background2
  local old_bg3 = style.background3
  local old_text = style.text
  local old_dim = style.dim
  if style.mossy then
    style.background2 = style.mossy.sidebar_bg or style.background2
    style.background3 = style.mossy.activity_bg or style.background3
    style.text = style.mossy.sidebar_text or style.text
    style.dim = style.mossy.sidebar_muted or style.dim
  end
  orig_draw(self)
  style.background2 = old_bg2
  style.background3 = old_bg3
  style.text = old_text
  style.dim = old_dim
  
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
    local keymap = require "core.keymap"
    if (keymap.modkeys["ctrl"] or keymap.modkeys["cmd"]) and keymap.modkeys["shift"] then
      command.perform("treeview:toggle-selection")
      return true
    end
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
            core.log("Failed to move %s: %s", self.dnd_item.name, err)
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

-- ── Context Menu: Open Folder ─────────────────────────────────────────────────
local function get_sidebar_item()
  return TreeView.hovered_item or TreeView.selected_item
end

local function get_hovered_dir()
  local item = get_sidebar_item()
  if item and item.type == "dir" and item.abs_filename ~= core.project_dir then
    return item
  end
  return nil
end

command.add(
  function()
    local item = get_hovered_dir()
    return item ~= nil and (core.active_view == TreeView or (TreeView.contextmenu and TreeView.contextmenu.show_context_menu)), item
  end, {
  ["treeview:open-folder"] = function(item)
    core.confirm_close_docs(core.docs, function(dirpath)
      core.open_folder_project(dirpath)
    end, item.abs_filename)
  end,
})

if TreeView.contextmenu then
  TreeView.contextmenu:register(
    function()
      return core.active_view == TreeView and get_hovered_dir() ~= nil
    end, {
      { text = "Open Folder", command = "treeview:open-folder" }
    }
  )
  -- Reorder menu itemset so "Open Folder" appears at the top (index 1)
  local last = table.remove(TreeView.contextmenu.itemset)
  table.insert(TreeView.contextmenu.itemset, 1, last)
end


command.add(
  function()
    local item = TreeView.hovered_item or TreeView.selected_item
    return item ~= nil and (core.active_view == TreeView or (TreeView.contextmenu and TreeView.contextmenu.show_context_menu)), item
  end, {
  ["treeview:move-to-any-folder"] = function(item)
    local common = require 'core.common'
    core.command_view:enter("Move to folder (target path)", {
      text = item.dir_name,
      submit = function(target_dir)
        local abs_dir = target_dir
        if not common.is_absolute_path(target_dir) then
          abs_dir = core.project_dir .. PATHSEP .. target_dir
        end
        local new_abs_filename = abs_dir .. PATHSEP .. item.name
        
        local stat = system.get_file_info(abs_dir)
        if not stat then
          common.mkdirp(abs_dir)
        end

        local res, err = os.rename(item.abs_filename, new_abs_filename)
        if res then
          core.log("Moved %s to %s", item.name, abs_dir)
        else
          core.error("Failed to move %s: %s", item.name, err)
        end
      end
    })
  end,
  ["treeview:go-into-its-folder"] = function(item)
    core.confirm_close_docs(core.docs, function(dirpath)
      core.open_folder_project(dirpath)
    end, item.dir_name)
  end,
})

if TreeView.contextmenu then
  TreeView.contextmenu:register(
    function()
      return core.active_view == TreeView and (TreeView.hovered_item or TreeView.selected_item) ~= nil
    end, {
      { text = "Move to any folder", command = "treeview:move-to-any-folder" },
      { text = "Go into any folder", command = "treeview:go-into-its-folder" }
    }
  )
end

-- "?"? Multi-Selection Override "?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?
local orig_set_selection = TreeView.set_selection
function TreeView:set_selection(selection, selection_y)
  orig_set_selection(self, selection, selection_y)
  self.selected_items = selection and { [selection.abs_filename] = selection } or {}
end

local orig_draw_item_bg = TreeView.draw_item_background
function TreeView:draw_item_background(item, active, hovered, x, y, w, h)
  local is_selected = self.selected_items and self.selected_items[item.abs_filename] ~= nil
  orig_draw_item_bg(self, item, active or is_selected, hovered, x, y, w, h)
end

  command.add(
    function()
      return TreeView.hovered_item ~= nil
    end, {
  ["treeview:toggle-selection"] = function()
    local item = TreeView.hovered_item
    if not item then return end
    
    TreeView.selected_items = TreeView.selected_items or {}
    
    if TreeView.selected_items[item.abs_filename] then
      TreeView.selected_items[item.abs_filename] = nil
      if TreeView.selected_item == item then
        TreeView.selected_item = nil
        local any = next(TreeView.selected_items)
        if any then
          TreeView.selected_item = TreeView.selected_items[any]
        end
      end
    else
      TreeView.selected_items[item.abs_filename] = item
      TreeView.selected_item = item
    end
    core.redraw = true
  end
})

  keymap.add {
    ["ctrl+shift+lclick"] = "treeview:toggle-selection"
  }


-- "?"? Multi-Select Commands "?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?"?
local function get_all_selected()
  if not TreeView.selected_items or not next(TreeView.selected_items) then
    local item = TreeView.hovered_item or TreeView.selected_item
    return item and {item} or {}
  end
  local res = {}
  for _, it in pairs(TreeView.selected_items) do table.insert(res, it) end
  return res
end

-- Override treeview:delete
local orig_delete = command.map["treeview:delete"] and command.map["treeview:delete"].perform
if orig_delete then
  command.map["treeview:delete"].perform = function(item)
    local items = get_all_selected()
    if #items <= 1 then
      return orig_delete(items[1] or item)
    end
    
    local opt = {
      { text = "Yes", default_yes = true },
      { text = "No", default_no = true }
    }
    core.nag_view:show(
      "Delete Multiple Items",
      string.format("Are you sure you want to delete %d items?", #items),
      opt,
      function(item_opt)
        if item_opt.text == "Yes" then
          for _, it in ipairs(items) do
            local file_info = system.get_file_info(it.abs_filename)
            if file_info then
              local err
              if file_info.type == "dir" then
                local common = require "core.common"
                err = common.rmdir(it.abs_filename, true)
              else
                local res
                res, err = os.remove(it.abs_filename)
              end
              if err then core.error("Failed to delete %s: %s", it.name, err) end
            end
          end
          TreeView.selected_items = {}
          TreeView.selected_item = nil
          core.update_project_files()
        end
      end
    )
  end
end

-- "?"? Global Mouse Release Hook for Drag & Drop Safety "?"?"?"?"?"?"?"?"?
local RootView = require "core.rootview"
local orig_root_mousereleased = RootView.on_mouse_released
function RootView:on_mouse_released(button, x, y, clicks)
  local res
  if orig_root_mousereleased then
    res = orig_root_mousereleased(self, button, x, y, clicks)
  end
  if button == "left" then
    for _, view in ipairs(core.root_view.root_node:get_children()) do
      if view:is(TreeView) then
        if view.is_dragging and view.dnd_item and view.dnd_item.type == "file" then
          local node = core.root_view.root_node:get_child_overlapping_point(x, y)
          if node then
            local target_view = node.active_view
            local DocView = require "core.docview"
            local EmptyView = require "core.emptyview"
            if target_view:is(DocView) or target_view:is(EmptyView) then
              local split_type = node:get_split_type(x, y)
              if split_type ~= "middle" and split_type ~= "tab" then
                local new_node = node:split(split_type)
                core.root_view:set_active_node(new_node)
              else
                core.root_view:set_active_node(node)
              end
              core.root_view:open_doc(core.open_doc(view.dnd_item.abs_filename))
              core.redraw = true
            end
          end
        end
        view.dnd_item = nil
        view.is_dragging = false
      end
    end
  end
  return res
end

local orig_root_mouseleft = RootView.on_mouse_left
function RootView:on_mouse_left()
  if orig_root_mouseleft then orig_root_mouseleft(self) end
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view:is(TreeView) then
      view.dnd_item = nil
      view.is_dragging = false
    end
  end
end


