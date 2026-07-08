-- mod-version:3
-- Dark Forest color scheme for Lite XL
-- A high contrast, medium-to-dark green theme.

local style  = require "core.style"
local common = require "core.common"

local function c(hex) return { common.color(hex) } end

-- Surfaces
style.background       = c "#131F15" -- Deep dark green background
style.background2      = c "#1B2A1E" -- Slightly lighter for sidebars
style.background3      = c "#243827" -- Active elements/dividers

-- Text
style.text             = c "#D4E4D7" -- Pale green-tinted white
style.dim              = c "#8A9F8E" -- Muted green text
style.accent           = c "#68C171" -- Vibrant green accent

-- Caret & selection
style.caret            = c "#8DE896"
style.caret_width      = 2 * SCALE
style.selection        = c "#2C4C32"
style.line_highlight   = c "#18271B"

-- Line numbers
style.line_number      = c "#547358"
style.line_number2     = c "#8A9F8E"

-- Dividers & scrollbar
style.divider          = c "#2A412E"
style.scrollbar        = c "#38563E"
style.scrollbar2       = c "#4F7356"

-- Tab bar
style.tab_bar_background = c "#101911"
style.tab_width          = 200 * SCALE
style.tab_height         = 32 * SCALE

-- Title / activity bar
style.titlebar_background = c "#0C140D"
style.titlebar_text       = c "#D4E4D7"

-- Shared palette for custom plugins (they read style.mossy.*)
style.mossy = {
  sidebar_bg       = c "#18271B",
  sidebar_text     = c "#B5C8B8",
  sidebar_muted    = c "#6C8770",
  active_row       = c "#243827",
  active_row_text  = c "#E0EFE2",
  hover_row        = c "#1E3022",
  activity_bg      = c "#0C140D",
  activity_icon    = c "#8A9F8E",
  activity_icon_hl = c "#68C171",
  status_bg        = c "#1B2A1E",
  status_text      = c "#B5C8B8",
  terminal_bg      = c "#0F1A12",
  terminal_text    = c "#D4E4D7",
  indent_guide     = c "#223525",
  border           = c "#2A412E",
}

-- Syntax tokens (High contrast green spectrum)
local syntax_colors = {
  normal       = c "#D4E4D7",
  symbol       = c "#A8C3AC",
  comment      = c "#68886C", -- Dimmer green
  keyword      = c "#7CE087", -- Bright mint green
  keyword2     = c "#50C878", -- Emerald
  number       = c "#D9F28A", -- Yellow-green
  literal      = c "#D9F28A",
  string       = c "#A3E2A8", -- Light pale green
  operator     = c "#68C171", -- Accent green
  ["function"] = c "#9FE8A5", -- Bright soft green
  link         = c "#8DE896",
  ["type"]     = c "#6FD97A", 
}
for k, v in pairs(syntax_colors) do style.syntax[k] = v end

style.padding  = { x = 12 * SCALE, y = 6 * SCALE }
style.tab_font = style.font
