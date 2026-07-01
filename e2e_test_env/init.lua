-- E2E Test Suite Init for Lite-XL
local f = io.open(USERDIR .. "/test_boot.txt", "w")
if f then
  f:write("Booted!")
  f:close()
end

package.path = package.path .. ";C:/Users/ojasw/Documents/LiteXL-Mossy-Setup/?.lua;C:/Users/ojasw/Documents/LiteXL-Mossy-Setup/?/init.lua"

local core    = require "core"
local config  = require "core.config"
local style   = require "core.style"
local keymap  = require "core.keymap"

-- ── 1. Color scheme ───────────────────────────────────────────────────────────
core.reload_module("colors.everforest_lite_xl")

-- ── 2. Font ───────────────────────────────────────────────────────────────────
local function try_load_font(path, size, opts)
  local ok, f = pcall(renderer.font.load, path, size, opts or {})
  return ok and f or nil
end

local FONT_PATH = USERDIR .. "/fonts/FiraCode-iScript.ttf"
local NERD_PATH = USERDIR .. "/fonts/FiraCodeNerdFont-Regular.ttf"

local base_font = try_load_font(FONT_PATH, 15 * SCALE)
              or try_load_font(NERD_PATH,  15 * SCALE)
              or nil

if base_font then
  style.font          = base_font
  style.big_font      = try_load_font(FONT_PATH, 20 * SCALE) or base_font
  style.code_font     = base_font
  style.icon_font     = try_load_font(NERD_PATH, 14 * SCALE) or base_font
  style.icon_big_font = try_load_font(NERD_PATH, 28 * SCALE) or base_font
end

-- ── 3. Editor behaviour ───────────────────────────────────────────────────────
config.tab_type               = "soft"
config.indent_size            = 4
config.line_limit             = 120
config.highlight_current_line = true
config.blink_period           = 0.5
config.draw_whitespace        = false
config.max_undos              = 10000
config.file_size_limit        = 10
config.ignore_files           = {
  "^%.git", "^node_modules", "^__pycache__", "^%.env$", "^%.DS_Store",
}

-- ── 4. Built-in plugins ───────────────────────────────────────────────────────
config.plugins.treeview       = true
config.plugins.autocomplete   = true
config.plugins.bracketmatch   = true
config.plugins.autosave       = false
config.plugins.minimap        = true
config.plugins.drawwhitespace = false
config.plugins.lineguide      = false
config.plugins.wordcount      = false

-- ── 5. Custom plugins ─────────────────────────────────────────────────────────
local function safe_require(mod)
  local ok, err = pcall(require, mod)
  if not ok then
    local log_path = USERDIR .. "/../init_errors.log"
    local f = io.open(log_path, "a")
    if f then
      f:write("Failed to load " .. mod .. ": " .. tostring(err) .. "\n")
      f:close()
    end
    core.warn("Failed to load " .. mod .. ": " .. tostring(err))
  end
end

safe_require "plugins.mossy_icons"
safe_require "plugins.mossy_treeview"
safe_require "plugins.toggle_terminal"
safe_require "plugins.antigravity_sidebar"
safe_require "plugins.mossy_statusbar"
safe_require "plugins.auto_healer"

-- ── 6. Redirect Antigravity CLI to Mock ───────────────────────────────────────
if config.antigravity then
  config.antigravity.cli = USERDIR .. "/mock_agy.exe"
  config.antigravity.auto_skip_permissions = true
  print("[E2E Init] Redirected config.antigravity.cli to: " .. config.antigravity.cli)
else
  print("[E2E Init] ERROR: config.antigravity not found!")
end

-- ── 7. Keybindings ────────────────────────────────────────────────────────────
keymap.add {
  ["ctrl+`"]        = "terminal:toggle",
  ["ctrl+shift+a"]  = "antigravity:toggle",
  ["ctrl+b"]        = "treeview:toggle",
  ["ctrl+p"]        = "core:open-file",
  ["ctrl+shift+p"]  = "core:find-command",
  ["ctrl+shift+e"]  = "treeview:focus",
  ["ctrl+/"]        = "doc:toggle-line-comments",
  ["ctrl+d"]        = "find-replace:select-next",
  ["ctrl+z"]        = "doc:undo",
  ["ctrl+y"]        = "doc:redo",
  ["ctrl+s"]        = "doc:save",
  ["ctrl+w"]        = "root:close-active",
  ["ctrl+shift+k"]  = "doc:delete-lines",
  ["alt+up"]        = "doc:move-lines-up",
  ["alt+down"]      = "doc:move-lines-down",
}

-- ── 8. Start E2E Simulator/Runner ─────────────────────────────────────────────
safe_require "plugins.e2e_simulator"
