-- mod-version:3
-- ============================================================================
-- Terraform Visualizer for Lite XL
-- Interactive Infrastructure Inspector, Provider/Resource Explorer, and Code Navigator
-- ============================================================================

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local system = require "system"

local SCALE = SCALE or 1

-- Color palette helpers
local function c(r, g, b, a) return { r, g, b, a or 255 } end
local COLOR_BG_CARD   = c(35, 38, 48)
local COLOR_BG_HOVER  = c(48, 52, 66)
local COLOR_BORDER    = c(55, 60, 75)
local COLOR_ACCENT    = c(132, 79, 186)    -- Terraform purple
local COLOR_RESOURCE  = c(68, 157, 248)    -- Azure/Cloud blue
local COLOR_DATA      = c(78, 201, 176)    -- Teal
local COLOR_MODULE    = c(220, 160, 60)    -- Amber
local COLOR_VAR       = c(150, 200, 100)   -- Soft green
local COLOR_OUTPUT    = c(240, 120, 140)   -- Coral

local TerraformVisualizerView = View:extend()

function TerraformVisualizerView:new()
  TerraformVisualizerView.super.new(self)
  self.name = "Terraform Visualizer"
  self.scrollable = true
  self.target_size = 380 * SCALE
  self.visible = true
  self.size = { x = 380 * SCALE, y = 0 }

  self.providers = {}   -- list of { name, alias, file, abs_file, line }
  self.resources = {}   -- list of { kind="resource", provider, type, name, file, abs_file, line }
  self.data_sources = {}-- list of { kind="data", provider, type, name, file, abs_file, line }
  self.modules = {}     -- list of { name, source, file, abs_file, line }
  self.variables = {}   -- list of { name, type, default, file, abs_file, line }
  self.outputs = {}     -- list of { name, file, abs_file, line }

  self.files_scanned = 0
  self.last_scan_time = 0
  self.is_scanning = false
  self.filter = ""
  self.hovered_idx = nil
  self.items = {}       -- flattened list of clickable rendered items

  self.collapsed = {
    providers = false,
    resources = false,
    data_sources = false,
    modules = false,
    variables = false,
    outputs = false,
  }

  self.content_height = 0
  self.scroll = { x = 0, y = 0, to = { x = 0, y = 0 } }
end

function TerraformVisualizerView:update()
  TerraformVisualizerView.super.update(self)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "x", dest, nil, "terraform_visualizer")
end

function TerraformVisualizerView:get_name()
  return "Terraform Visualizer"
end

function TerraformVisualizerView:get_scrollable_size()
  return math.max(self.size.y + 1, self.content_height + 40 * SCALE)
end

function TerraformVisualizerView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  elseif axis == "y" then
    self.size.y = value
    return true
  end
  return false
end

-- ============================================================================
-- Project Scanning & HCL Parsing
-- ============================================================================

local function get_project_dirs()
  local dirs = {}
  if core.project_directories then
    for _, pd in ipairs(core.project_directories) do
      table.insert(dirs, pd.name or pd)
    end
  elseif core.project_dir then
    table.insert(dirs, core.project_dir)
  end
  return dirs
end

local function normalize_path(p)
  return (p or ""):gsub("\\", "/")
end

local function is_ignored_dir(name)
  local n = name:lower()
  return n == ".terraform" or n == ".git" or n == "node_modules"
      or n == ".visualizer" or n == "dist" or n == "build" or n == "vendor"
end

local function scan_files_recursive(dir, file_list)
  local files = system.list_dir(dir)
  if not files then return end
  for _, fname in ipairs(files) do
    if not fname:match("^%.") or fname == ".tfvars" then
      local full = dir .. "/" .. fname
      local info = system.get_file_info(full)
      if info then
        if info.type == "dir" and not is_ignored_dir(fname) then
          scan_files_recursive(full, file_list)
        elseif info.type == "file" then
          if fname:match("%.tf$") or fname:match("%.tfvars$") then
            table.insert(file_list, full)
          end
        end
      end
    end
  end
end

function TerraformVisualizerView:scan_project()
  self.is_scanning = true
  self.providers = {}
  self.resources = {}
  self.data_sources = {}
  self.modules = {}
  self.variables = {}
  self.outputs = {}
  self.files_scanned = 0

  local file_list = {}
  local pdirs = get_project_dirs()
  for _, pdir in ipairs(pdirs) do
    scan_files_recursive(normalize_path(pdir), file_list)
  end
  self.files_scanned = #file_list

  for _, full_path in ipairs(file_list) do
    local f = io.open(full_path, "r")
    if f then
      local content = f:read("*a")
      f:close()

      -- Calculate relative path from root
      local rel_path = full_path
      for _, pdir in ipairs(pdirs) do
        local np = normalize_path(pdir)
        if full_path:sub(1, #np) == np then
          rel_path = full_path:sub(#np + 2)
          break
        end
      end

      -- Line-by-line parsing for robust line numbers and HCL blocks
      local line_no = 1
      for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        local trimmed = line:match("^%s*(.-)%s*$")

        -- Resource: resource "type" "name" {
        local r_type, r_name = trimmed:match('^resource%s+"([^"]+)"%s+"([^"]+)"')
        if r_type and r_name then
          local prov = r_type:match("^([^_]+)") or "custom"
          table.insert(self.resources, {
            kind = "resource",
            provider = prov,
            type = r_type,
            name = r_name,
            file = rel_path,
            abs_file = full_path,
            line = line_no
          })
        end

        -- Data source: data "type" "name" {
        local d_type, d_name = trimmed:match('^data%s+"([^"]+)"%s+"([^"]+)"')
        if d_type and d_name then
          local prov = d_type:match("^([^_]+)") or "custom"
          table.insert(self.data_sources, {
            kind = "data",
            provider = prov,
            type = d_type,
            name = d_name,
            file = rel_path,
            abs_file = full_path,
            line = line_no
          })
        end

        -- Provider: provider "name" {
        local p_name = trimmed:match('^provider%s+"([^"]+)"')
        if p_name then
          -- Check duplicate
          local exists = false
          for _, p in ipairs(self.providers) do
            if p.name == p_name and p.file == rel_path then exists = true; break end
          end
          if not exists then
            table.insert(self.providers, {
              name = p_name,
              file = rel_path,
              abs_file = full_path,
              line = line_no
            })
          end
        end

        -- Module: module "name" {
        local m_name = trimmed:match('^module%s+"([^"]+)"')
        if m_name then
          table.insert(self.modules, {
            name = m_name,
            file = rel_path,
            abs_file = full_path,
            line = line_no
          })
        end

        -- Variable: variable "name" {
        local v_name = trimmed:match('^variable%s+"([^"]+)"')
        if v_name then
          table.insert(self.variables, {
            name = v_name,
            file = rel_path,
            abs_file = full_path,
            line = line_no
          })
        end

        -- Output: output "name" {
        local o_name = trimmed:match('^output%s+"([^"]+)"')
        if o_name then
          table.insert(self.outputs, {
            name = o_name,
            file = rel_path,
            abs_file = full_path,
            line = line_no
          })
        end

        line_no = line_no + 1
      end
    end
  end

  self.last_scan_time = system.get_time()
  self.is_scanning = false
  core.redraw = true
end

-- ============================================================================
-- Rendering & Interaction
-- ============================================================================

function TerraformVisualizerView:on_mouse_wheel(y)
  self.scroll.to.y = self.scroll.to.y - y * 40 * SCALE
  local max_scroll = math.max(0, self:get_scrollable_size() - self.size.y)
  self.scroll.to.y = math.max(0, math.min(self.scroll.to.y, max_scroll))
  return true
end

function TerraformVisualizerView:on_mouse_moved(x, y, dx, dy)
  TerraformVisualizerView.super.on_mouse_moved(self, x, y, dx, dy)
  local found_hover = nil
  for idx, item in ipairs(self.items) do
    if x >= item.x and x <= item.x + item.w and y >= item.y and y <= item.y + item.h then
      found_hover = idx
      break
    end
  end
  if found_hover ~= self.hovered_idx then
    self.hovered_idx = found_hover
    core.redraw = true
  end
  if found_hover then
    system.set_cursor("hand")
  else
    system.set_cursor("arrow")
  end
end

function TerraformVisualizerView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    for _, item in ipairs(self.items) do
      if x >= item.x and x <= item.x + item.w and y >= item.y and y <= item.y + item.h then
        if item.action == "toggle_section" then
          self.collapsed[item.section] = not self.collapsed[item.section]
          core.redraw = true
          return true
        elseif item.action == "refresh" then
          self:scan_project()
          return true
        elseif item.action == "jump" and item.abs_file and item.line then
          local doc = core.open_doc(item.abs_file)
          if doc then
            local node = core.root_view:get_active_node_default()
            local doc_view = node:open_doc(doc)
            doc:set_selection(item.line, 1, item.line, 1)
            if doc_view and doc_view.scroll_to_line then
              doc_view:scroll_to_line(item.line, true)
            end
          end
          return true
        end
      end
    end
  end
  return TerraformVisualizerView.super.on_mouse_pressed(self, button, x, y, clicks)
end

function TerraformVisualizerView:draw()
  self:draw_background(style.background)
  local font = style.font
  local bfont = style.big_font or font
  local cfont = style.code_font or font
  local fh = font:get_height()
  local pad = 12 * SCALE

  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local cy = y + pad - self.scroll.y
  local inner_w = w - pad * 2

  self.items = {}

  -- ── Top Header ────────────────────────────────────────────────────────────
  local header_h = 32 * SCALE
  renderer.draw_rect(x + pad, cy, inner_w, header_h, COLOR_BG_CARD)
  renderer.draw_rect(x + pad, cy, 3 * SCALE, header_h, COLOR_ACCENT)

  -- Icon & Title
  local title = "\u{f1b3}  Terraform Visualizer"
  renderer.draw_text(bfont, title, x + pad + 10 * SCALE, cy + (header_h - bfont:get_height()) / 2, style.text)

  -- Scan/Refresh Button
  local btn_text = self.is_scanning and "Scanning..." or "\u{f021} Scan"
  local btn_w = font:get_width(btn_text) + 16 * SCALE
  local btn_h = 22 * SCALE
  local btn_x = x + pad + inner_w - btn_w - 6 * SCALE
  local btn_y = cy + (header_h - btn_h) / 2
  local is_btn_hov = (self.hovered_idx == "btn_refresh")

  renderer.draw_rect(btn_x, btn_y, btn_w, btn_h, is_btn_hov and COLOR_BG_HOVER or COLOR_BORDER)
  renderer.draw_text(font, btn_text, btn_x + 8 * SCALE, btn_y + (btn_h - fh) / 2, style.text)
  table.insert(self.items, { action = "refresh", x = btn_x, y = btn_y, w = btn_w, h = btn_h })

  cy = cy + header_h + 10 * SCALE

  -- ── Stats Summary Bar ─────────────────────────────────────────────────────
  local total_res = #self.resources + #self.data_sources
  local stats_text = string.format("%d files | %d resources | %d providers | %d modules",
    self.files_scanned, total_res, #self.providers, #self.modules)
  renderer.draw_text(font, stats_text, x + pad + 4 * SCALE, cy, style.dim)
  cy = cy + fh + 12 * SCALE

  -- ── Empty State ───────────────────────────────────────────────────────────
  if self.files_scanned == 0 then
    local empty_card_h = 90 * SCALE
    renderer.draw_rect(x + pad, cy, inner_w, empty_card_h, COLOR_BG_CARD)
    renderer.draw_rect(x + pad, cy, inner_w, empty_card_h, COLOR_BORDER)

    local msg1 = "No Terraform files found in workspace."
    local msg2 = "Create or open *.tf files, then click 'Scan' to inspect resources."
    renderer.draw_text(font, msg1, x + pad + 14 * SCALE, cy + 18 * SCALE, style.text)
    renderer.draw_text(font, msg2, x + pad + 14 * SCALE, cy + 42 * SCALE, style.dim)
    self.content_height = cy + empty_card_h - y
    return
  end

  -- Helper to draw an expandable section header
  local function draw_section_header(sec_id, title_str, count, tag_color)
    local is_coll = self.collapsed[sec_id]
    local arrow = is_coll and "\u{25b6} " or "\u{25bc} "
    local sh_h = 24 * SCALE

    renderer.draw_rect(x + pad, cy, inner_w, sh_h, COLOR_BG_CARD)
    renderer.draw_rect(x + pad, cy, 2 * SCALE, sh_h, tag_color)

    local full_title = string.format("%s%s (%d)", arrow, title_str, count)
    renderer.draw_text(font, full_title, x + pad + 8 * SCALE, cy + (sh_h - fh) / 2, tag_color)

    table.insert(self.items, {
      action = "toggle_section",
      section = sec_id,
      x = x + pad,
      y = cy,
      w = inner_w,
      h = sh_h
    })

    cy = cy + sh_h + 4 * SCALE
    return not is_coll
  end

  -- Helper to draw resource cards
  local function draw_resource_card(item, badge_text, badge_color)
    local item_h = 36 * SCALE
    local item_x = x + pad + 8 * SCALE
    local item_w = inner_w - 8 * SCALE

    local is_hov = (self.hovered_idx == #self.items + 1)
    renderer.draw_rect(item_x, cy, item_w, item_h, is_hov and COLOR_BG_HOVER or COLOR_BG_CARD)
    renderer.draw_rect(item_x, cy, item_w, 1, COLOR_BORDER)
    renderer.draw_rect(item_x, cy + item_h - 1, item_w, 1, COLOR_BORDER)

    -- Badge
    local bw = cfont:get_width(badge_text) + 10 * SCALE
    local bh = cfont:get_height() + 4 * SCALE
    local bx = item_x + 6 * SCALE
    local by = cy + (item_h - bh) / 2
    renderer.draw_rect(bx, by, bw, bh, badge_color)
    renderer.draw_text(cfont, badge_text, bx + 5 * SCALE, by + 2 * SCALE, style.background)

    -- Primary Label (type & name)
    local label = item.type and (item.type .. "." .. item.name) or item.name
    local lx = bx + bw + 8 * SCALE
    renderer.draw_text(font, label, lx, cy + 4 * SCALE, is_hov and style.text or style.text)

    -- Secondary Label (file:line)
    local sub = string.format("%s:%d", item.file or "", item.line or 1)
    renderer.draw_text(font, sub, lx, cy + 18 * SCALE, style.dim)

    table.insert(self.items, {
      action = "jump",
      abs_file = item.abs_file,
      line = item.line,
      x = item_x,
      y = cy,
      w = item_w,
      h = item_h
    })

    cy = cy + item_h + 3 * SCALE
  end

  -- ── 1. Providers ──────────────────────────────────────────────────────────
  if #self.providers > 0 then
    if draw_section_header("providers", "Providers", #self.providers, COLOR_ACCENT) then
      for _, p in ipairs(self.providers) do
        draw_resource_card(p, "provider", COLOR_ACCENT)
      end
      cy = cy + 6 * SCALE
    end
  end

  -- ── 2. Resources ──────────────────────────────────────────────────────────
  if #self.resources > 0 then
    if draw_section_header("resources", "Resources", #self.resources, COLOR_RESOURCE) then
      for _, r in ipairs(self.resources) do
        draw_resource_card(r, "res", COLOR_RESOURCE)
      end
      cy = cy + 6 * SCALE
    end
  end

  -- ── 3. Data Sources ───────────────────────────────────────────────────────
  if #self.data_sources > 0 then
    if draw_section_header("data_sources", "Data Sources", #self.data_sources, COLOR_DATA) then
      for _, d in ipairs(self.data_sources) do
        draw_resource_card(d, "data", COLOR_DATA)
      end
      cy = cy + 6 * SCALE
    end
  end

  -- ── 4. Modules ────────────────────────────────────────────────────────────
  if #self.modules > 0 then
    if draw_section_header("modules", "Modules", #self.modules, COLOR_MODULE) then
      for _, m in ipairs(self.modules) do
        draw_resource_card(m, "module", COLOR_MODULE)
      end
      cy = cy + 6 * SCALE
    end
  end

  -- ── 5. Variables ──────────────────────────────────────────────────────────
  if #self.variables > 0 then
    if draw_section_header("variables", "Variables", #self.variables, COLOR_VAR) then
      for _, v in ipairs(self.variables) do
        draw_resource_card(v, "var", COLOR_VAR)
      end
      cy = cy + 6 * SCALE
    end
  end

  -- ── 6. Outputs ────────────────────────────────────────────────────────────
  if #self.outputs > 0 then
    if draw_section_header("outputs", "Outputs", #self.outputs, COLOR_OUTPUT) then
      for _, o in ipairs(self.outputs) do
        draw_resource_card(o, "output", COLOR_OUTPUT)
      end
      cy = cy + 6 * SCALE
    end
  end

  self.content_height = cy + self.scroll.y - y + 20 * SCALE
end

-- ============================================================================
-- Commands & Keymaps
-- ============================================================================

local tv_view = nil

local function toggle_tf_view()
  local sidebar = rawget(_G, "get_sidebar_node") and _G.get_sidebar_node()
  if tv_view and core.root_view.root_node:get_node_for_view(tv_view) then
    local node = core.root_view.root_node:get_node_for_view(tv_view)
    if sidebar and node == sidebar and node.active_view == tv_view then
      node:close_view(core.root_view.root_node, tv_view)
      tv_view = nil
    elseif sidebar and node == sidebar then
      node:set_active_view(tv_view)
      core.set_active_view(tv_view)
    else
      node:close_view(core.root_view.root_node, tv_view)
      tv_view = nil
    end
  else
    if not tv_view then tv_view = TerraformVisualizerView() end
    tv_view.visible = true
    if sidebar then
      if not core.root_view.root_node:get_node_for_view(tv_view) then
        sidebar:add_view(tv_view)
      end
      sidebar:set_active_view(tv_view)
    else
      local primary = core.root_view:get_primary_node()
      sidebar = primary:split("right", tv_view, { x = true }, true)
      if sidebar then
        sidebar.should_show_tabs = function() return false end
        if not sidebar._ab_patched then
          local old_av = sidebar.add_view
          sidebar.add_view = function(self, v)
            local l = self.locked; self.locked = nil
            old_av(self, v)
            self.locked = l
          end
          sidebar._ab_patched = true
        end
        rawset(_G, "_ag_sidebar_node", sidebar)
      end
    end
    core.set_active_view(tv_view)
    tv_view:scan_project()
  end
  core.redraw = true
end

command.add(nil, {
  ["terraform_visualizer:toggle"] = function()
    toggle_tf_view()
  end,
  ["terraform_visualizer:refresh"] = function()
    if tv_view then tv_view:scan_project() end
  end,
})

keymap.add({ ["ctrl+shift+x"] = "terraform_visualizer:toggle" })

core.log("[Terraform Visualizer] Loaded — use 'terraform_visualizer:toggle' or Activity Bar \u{f1b3}")

return TerraformVisualizerView
