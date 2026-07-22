-- mod-version:3
-- Tokyo Night Remix color scheme for Lite XL
-- An ultra eye-pleasing, high-contrast neon vibe.

local style = require "core.style"
local common = require "core.common"

local function c(hex) return { common.color(hex) } end

style.background = c "#151620" -- Deep dark background
style.background2 = c "#0F1016" -- Darker sidebar/tabs
style.background3 = c "#1A1B28" -- Active elements
style.text = c "#C0CAF5" -- Crisp blue-ish white
style.caret = c "#E0AF68" -- Golden caret
style.caret_width = 2 * SCALE
style.accent = c "#7AA2F7" -- Neon blue accent
style.dim = c "#565F89" -- Muted dim
style.divider = c "#0B0C11" -- Deep space borders
style.selection = c "#2F3554" -- Visible selection
style.line_number = c "#3A4160"
style.line_number2 = c "#C8A6FF" -- Vibrant neon purple active line number
style.line_highlight = c "#1A1C2A"
style.scrollbar = c "#2F3554"
style.scrollbar2 = c "#565F89"

style.syntax["normal"] = c "#C0CAF5"
style.syntax["symbol"] = c "#9ABDF5"
style.syntax["comment"] = c "#6672A1" -- Slightly brighter comments for readability
style.syntax["keyword"] = c "#C8A6FF" -- Super vibrant neon purple
style.syntax["keyword2"] = c "#BB9AF7" -- Original purple
style.syntax["number"] = c "#FF9E64" -- Bright neon orange
style.syntax["literal"] = c "#FF9E64"
style.syntax["string"] = c "#A9DC76" -- Vivid neon green
style.syntax["operator"] = c "#89DDFF" -- Neon cyan
style.syntax["function"] = c "#7AA2F7" -- Bright neon blue
style.syntax["type"] = c "#2AC3DE" -- Soft cyan

-- PLUGINS
style.linter_warning = c "#E0AF68"
style.bracketmatch_color = c "#C8A6FF"
style.guide = c "#1A1C2A"
style.guide_highlight = c "#3A4160"
style.guide_width = 1

-- Custom Mossy Plugin Palette Integration
style.mossy = {
  sidebar_bg       = c "#0F1016",
  sidebar_text     = c "#A9B1D6",
  sidebar_muted    = c "#565F89",
  active_row       = c "#1A1B28",
  active_row_text  = c "#C0CAF5",
  hover_row        = c "#13141C",
  
  -- Warm amber-gold status bar — softer than pure yellow, still vivid
  -- Dark near-black text for maximum contrast on the light background
  status_bg        = c "#C9A227",  -- warm amber-gold (muted, not harsh)
  status_text      = c "#12111A",  -- very dark purple-black (softer than #000)
  
  -- The Tokyo Night Purple Activity Bar
  activity_bg      = c "#BB9AF7",
  activity_icon    = c "#0F1016",
  activity_icon_hl = c "#FFFFFF",
  
  terminal_bg      = c "#0F1016",
  terminal_text    = c "#C0CAF5",
  indent_guide     = c "#1A1C2A",
  border           = c "#0B0C11",
}

-- Ensure tabs integrate with the vibe
style.tab_bar_background = c "#0F1016"
style.titlebar_background = c "#0B0C11"
style.titlebar_text = c "#A9B1D6"
