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
style.dim              = c "#424A3E" -- Explicitly matched to text color for high-contrast inactive tabs
style.accent           = c "#68C171"

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
