-- mod-version:3
-- Indent Guide plugin for Lite-XL
-- Renders faint scope and indentation guide lines (VS Code style) with active scope highlighting and UI Settings integration.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"
local DocView = require "core.docview"

config.plugins.indentguide = common.merge({
  enabled = true,
  highlight_active = true,
  show_first_level = false,
  width = 1,
  config_spec = {
    name = "Indent Guides",
    {
      label = "Enabled",
      description = "Show faint vertical guide lines indicating function, loop, and block scope depth.",
      path = "enabled",
      type = "toggle",
      default = true
    },
    {
      label = "Highlight Active Scope",
      description = "Highlight the indent guide corresponding to the cursor's current enclosing scope.",
      path = "highlight_active",
      type = "toggle",
      default = true
    },
    {
      label = "Show First Level",
      description = "Draw indent guide line at column 1 (outermost left margin).",
      path = "show_first_level",
      type = "toggle",
      default = false
    },
    {
      label = "Guide Width",
      description = "Width of the indent guide lines in pixels.",
      path = "width",
      type = "number",
      default = 1,
      min = 1,
      max = 4
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
  for l = line_idx - 1, math.max(1, line_idx - 35), -1 do
    local d = get_line_indent_depth(doc, l)
    if d >= 0 then
      prev_depth = d
      break
    end
  end

  -- Scan next non-blank line
  local next_depth = 0
  for l = line_idx + 1, math.min(#doc.lines, line_idx + 35) do
    local d = get_line_indent_depth(doc, l)
    if d >= 0 then
      next_depth = d
      break
    end
  end

  return math.min(prev_depth, next_depth)
end

-- Compute active cursor scope block
local function get_active_scope(doc)
  local sel_line = doc:get_selection()
  if not sel_line or not doc.lines[sel_line] then return 0, 0, 0 end

  local active_level = get_effective_indent(doc, sel_line)
  if active_level <= 0 then return 0, 0, 0 end

  local scope_start = sel_line
  for l = sel_line - 1, math.max(1, sel_line - 150), -1 do
    local d = get_effective_indent(doc, l)
    if d >= active_level then
      scope_start = l
    else
      break
    end
  end

  local scope_end = sel_line
  for l = sel_line + 1, math.min(#doc.lines, sel_line + 150) do
    local d = get_effective_indent(doc, l)
    if d >= active_level then
      scope_end = l
    else
      break
    end
  end

  return active_level, scope_start, scope_end
end

-- Draw indent guides for a specific line
local function draw_indent_guides(dv, line, x, y)
  local doc = dv.doc
  if not doc then return end

  local indent_type, indent_size = doc:get_indent_info()
  indent_size = math.max(1, indent_size or 4)

  local depth = get_effective_indent(doc, line)
  if depth <= 0 and not config.plugins.indentguide.show_first_level then
    return
  end

  local active_level, scope_start, scope_end = 0, 0, 0
  if config.plugins.indentguide.highlight_active and core.active_view == dv then
    active_level, scope_start, scope_end = get_active_scope(doc)
  end

  local is_in_active_scope = (line >= scope_start and line <= scope_end and active_level > 0)
  local start_level = config.plugins.indentguide.show_first_level and 1 or 2
  local max_level = depth + 1 -- scope line extends to enclosing block depth

  local font = dv:get_font()
  local space_w = font:get_width(" ")
  local lh = dv:get_line_height()
  local gw = math.max(1, math.floor((config.plugins.indentguide.width or 1) * SCALE))

  -- Default faint guide color & active scope accent color
  local normal_color = style.guide or (style.dim and {style.dim[1], style.dim[2], style.dim[3], 48}) or {120, 125, 140, 48}
  local active_color = style.guide_active or (style.accent and {style.accent[1], style.accent[2], style.accent[3], 150}) or {180, 185, 200, 160}

  for lvl = start_level, max_level do
    local col_offset_char = (lvl - 1) * indent_size + 1
    local gx
    local text = doc.lines[line] or ""
    if #text >= col_offset_char then
      gx = x + dv:get_col_x_offset(line, col_offset_char)
    else
      gx = x + math.floor((lvl - 1) * indent_size * space_w)
    end

    local is_active = (is_in_active_scope and lvl == active_level)
    local draw_col = is_active and active_color or normal_color

    renderer.draw_rect(gx, y, gw, lh, draw_col)
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
  get_effective_indent = get_effective_indent
}
