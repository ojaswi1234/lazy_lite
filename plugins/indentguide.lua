-- mod-version:3
-- Indent Guide plugin for Lite-XL
-- Renders faint, elegant scope and indentation guide lines (VS Code style)
-- for all functions, loops, conditions, and bracketed blocks with active scope illumination.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"
local DocView = require "core.docview"

config.plugins.indentguide = common.merge({
  enabled = true,
  highlight_active = true,
  highlight_header_footer = true,
  normal_opacity = 10,  -- 1 to 100 (faint, subtle, non-distracting)
  active_opacity = 38,  -- 1 to 100 (subtle active accent)
  width = 1,
  config_spec = {
    name = "Indent Guides",
    {
      label = "Enabled",
      description = "Show faint vertical guide lines indicating function, loop, and bracket block scope depth.",
      path = "enabled",
      type = "toggle",
      default = true
    },
    {
      label = "Highlight Active Scope",
      description = "Highlight the indent guide corresponding to the cursor's current enclosing loop, function, or block.",
      path = "highlight_active",
      type = "toggle",
      default = true
    },
    {
      label = "Highlight Header & Footer",
      description = "Extend active scope guide line to the opening header line and closing bracket line.",
      path = "highlight_header_footer",
      type = "toggle",
      default = true
    },
    {
      label = "Normal Guide Opacity (%)",
      description = "Opacity of inactive guide lines (1 = very faint, 100 = solid).",
      path = "normal_opacity",
      type = "number",
      default = 10,
      min = 2,
      max = 100
    },
    {
      label = "Active Scope Opacity (%)",
      description = "Opacity of the active scope guide line (1 = faint, 100 = solid).",
      path = "active_opacity",
      type = "number",
      default = 38,
      min = 5,
      max = 100
    },
    {
      label = "Guide Line Width",
      description = "Width of the indent guide lines in pixels.",
      path = "width",
      type = "number",
      default = 1,
      min = 1,
      max = 3
    }
  }
}, config.plugins.indentguide)

-- Helper to compute indent depth of a line
local function get_line_indent_depth(doc, line_idx)
  local text = doc.lines[line_idx]
  if not text then return -1 end
  local _, indent_size = doc:get_indent_info()
  indent_size = math.max(1, indent_size or 4)

  local ws = text:match("^[ \t]+")
  if not ws then
    if text:match("^%s*$") then
      return -1 -- blank line
    end
    return 0
  end
  if text:match("^%s*$") then
    return -1 -- blank line
  end

  local col = 0
  for i = 1, #ws do
    local c = ws:byte(i)
    if c == 9 then -- tab \t
      col = math.floor(col / indent_size + 1) * indent_size
    elseif c == 32 then -- space ' '
      col = col + 1
    end
  end
  return math.floor(col / indent_size)
end

-- Resolve effective indent for blank lines by checking neighboring lines
local function get_effective_indent(doc, line_idx)
  local depth = get_line_indent_depth(doc, line_idx)
  if depth >= 0 then return depth end

  -- Scan previous non-blank line
  local prev_depth = 0
  for l = line_idx - 1, math.max(1, line_idx - 40), -1 do
    local d = get_line_indent_depth(doc, l)
    if d >= 0 then
      prev_depth = d
      break
    end
  end

  -- Scan next non-blank line
  local next_depth = 0
  for l = line_idx + 1, math.min(#doc.lines, line_idx + 40) do
    local d = get_line_indent_depth(doc, l)
    if d >= 0 then
      next_depth = d
      break
    end
  end

  return math.min(prev_depth, next_depth)
end

-- Compute active cursor scope block (loops, functions, bracket blocks)
local function get_active_scope(doc)
  local sel_line = doc:get_selection()
  if not sel_line or not doc.lines[sel_line] then return 0, 0, 0 end

  local cur_depth = get_effective_indent(doc, sel_line)
  local next_depth = (sel_line < #doc.lines) and get_effective_indent(doc, sel_line + 1) or 0

  local active_level = cur_depth
  local header_line = nil

  -- If cursor is on the opening header line of a block (e.g. for(...) {, if(...) {, function(...) {)
  if next_depth > cur_depth then
    active_level = cur_depth + 1
    header_line = sel_line
  end

  if active_level <= 0 then return 0, 0, 0 end

  local scope_start = header_line or sel_line
  for l = (header_line and (header_line - 1) or (sel_line - 1)), math.max(1, sel_line - 200), -1 do
    local d = get_effective_indent(doc, l)
    if d >= active_level then
      scope_start = l
    else
      -- Found the enclosing header line
      if d == active_level - 1 then
        scope_start = l
      end
      break
    end
  end

  local scope_end = sel_line
  for l = sel_line + 1, math.min(#doc.lines, sel_line + 200) do
    local d = get_effective_indent(doc, l)
    if d >= active_level then
      scope_end = l
    else
      -- Found the closing footer/brace line
      if d == active_level - 1 then
        scope_end = l
      end
      break
    end
  end

  return active_level, scope_start, scope_end
end

-- Helper to get palette-aware subtle colors
local function get_guide_colors()
  local bg = style.background or {227, 239, 206}
  local is_dark = (bg[1] + bg[2] + bg[3]) < (128 * 3)
  local norm_op = (config.plugins.indentguide.normal_opacity or 10) / 100
  local act_op  = (config.plugins.indentguide.active_opacity or 38) / 100

  local norm_alpha = math.max(4, math.min(255, math.floor(norm_op * 255)))
  local act_alpha  = math.max(10, math.min(255, math.floor(act_op * 255)))

  local normal_color
  local active_color

  if is_dark then
    normal_color = {220, 230, 225, norm_alpha}
    if style.accent then
      active_color = {style.accent[1], style.accent[2], style.accent[3], act_alpha}
    else
      active_color = {180, 215, 170, act_alpha}
    end
  else
    -- Light theme (Everforest Light, etc.) - soft dark tint with reduced brightness
    normal_color = {40, 50, 42, norm_alpha}
    if style.accent then
      active_color = {math.floor(style.accent[1] * 0.7), math.floor(style.accent[2] * 0.7), math.floor(style.accent[3] * 0.7), act_alpha}
    else
      active_color = {60, 95, 65, act_alpha}
    end
  end

  return normal_color, active_color
end

-- Draw indent guides for a specific line
local function draw_indent_guides(dv, line, x, y)
  local doc = dv.doc
  if not doc then return end

  local _, indent_size = doc:get_indent_info()
  indent_size = math.max(1, indent_size or 4)

  local depth = get_effective_indent(doc, line)
  local active_level, scope_start, scope_end = 0, 0, 0
  if config.plugins.indentguide.highlight_active and core.active_view == dv then
    active_level, scope_start, scope_end = get_active_scope(doc)
  end

  local is_in_active_scope = (line >= scope_start and line <= scope_end and active_level > 0)
  
  -- Max depth of guide lines to draw on this line
  local max_level = depth
  if is_in_active_scope and config.plugins.indentguide.highlight_header_footer then
    max_level = math.max(max_level, active_level)
  end

  if max_level <= 0 then return end

  local font = dv:get_font()
  local space_w = font:get_width(" ")
  local lh = dv:get_line_height()
  local gw = math.max(1, math.floor((config.plugins.indentguide.width or 1) * SCALE))

  local normal_color, active_color = get_guide_colors()

  for lvl = 1, max_level do
    local col_offset_char = (lvl - 1) * indent_size + 1
    local gx
    local text = doc.lines[line] or ""
    if #text >= col_offset_char then
      gx = x + dv:get_col_x_offset(line, col_offset_char)
    else
      gx = x + math.floor((lvl - 1) * indent_size * space_w)
    end

    local is_active = (is_in_active_scope and lvl == active_level)
    
    -- Only draw active line if on header/footer line beyond normal depth
    if lvl <= depth or is_active then
      local draw_col = is_active and active_color or normal_color
      renderer.draw_rect(gx, y, gw, lh, draw_col)
    end
  end
end

-- Hook into DocView:draw_line_body
local old_draw_line_body = DocView.draw_line_body
function DocView:draw_line_body(line, x, y)
  if config.plugins.indentguide and config.plugins.indentguide.enabled and self:is(DocView) then
    draw_indent_guides(self, line, x, y)
  end
  return old_draw_line_body(self, line, x, y)
end

-- Register commands
command.add("core.docview", {
  ["indentguide:toggle"] = function()
    config.plugins.indentguide.enabled = not config.plugins.indentguide.enabled
    core.redraw = true
  end,
  ["indentguide:toggle-active-scope"] = function()
    config.plugins.indentguide.highlight_active = not config.plugins.indentguide.highlight_active
    core.redraw = true
  end
})

return {
  get_line_indent_depth = get_line_indent_depth,
  get_effective_indent = get_effective_indent,
  get_active_scope = get_active_scope
}
