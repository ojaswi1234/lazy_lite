-- mod-version:3
-- Everforest Light color scheme for Lite XL
-- Pixel-sampled from reference VS Code screenshot

local style  = require "core.style"
local common = require "core.common"

local function c(hex) return { common.color(hex) } end

-- Surfaces
style.background       = c "#E3EFCE"
style.background2      = c "#D5E5B9"
style.background3      = c "#B9CFA5"

-- Text
style.text             = c "#424A3E"
style.dim              = c "#6A7B61"
style.accent           = c "#437A16"

-- Caret & selection
style.caret            = c "#2A4016"
style.caret_width      = 2 * SCALE
style.selection        = c "#B2D38A"
style.line_highlight   = c "#D5ECB9"

-- Line numbers
style.line_number      = c "#7A9165"
style.line_number2     = c "#4A6B30"

-- Dividers & scrollbar
style.divider          = c "#A9C985"
style.scrollbar        = c "#A1C47A"
style.scrollbar2       = c "#7BA351"

-- Tab bar
style.tab_bar_background = c "#B9CFA5"
style.tab_width          = 200 * SCALE
style.tab_height         = 32 * SCALE

-- Title / activity bar
style.titlebar_background = c "#0F1A11"
style.titlebar_text       = c "#B4D6B0"

-- Shared palette for custom plugins (they read style.mossy.*)
style.mossy = {
  sidebar_bg       = c "#132115", -- A lot darker green
  sidebar_text     = c "#B4D6B0", -- Light green text
  sidebar_muted    = c "#658560",
  active_row       = c "#1E3321",
  active_row_text  = c "#D6EBD3",
  hover_row        = c "#192B1C",
  activity_bg      = c "#0F1A11",
  activity_icon    = c "#658560",
  activity_icon_hl = c "#B4D6B0",
  status_bg        = c "#132115",
  status_text      = c "#B4D6B0",
  terminal_bg      = c "#0F1A11",
  terminal_text    = c "#B4D6B0",
  indent_guide     = c "#203623",
  border           = c "#0A120C",
}

-- Syntax tokens
local syntax_colors = {
  normal       = c "#2A3821",
  symbol       = c "#2A3821",
  comment      = c "#737D53",
  keyword      = c "#6166BA",
  keyword2     = c "#8F627C",
  number       = c "#824DA4",
  literal      = c "#824DA4",
  string       = c "#637A3E",
  operator     = c "#5C6B4A",
  ["function"] = c "#AA383B",
  link         = c "#5581B4",
  ["type"]     = c "#5581B4",
}
for k, v in pairs(syntax_colors) do style.syntax[k] = v end

style.padding  = { x = 12 * SCALE, y = 6 * SCALE }
style.tab_font = style.font
