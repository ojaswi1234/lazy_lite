-- [[ LazyLite Configuration ]]
-- Do not reorder these blocks. Dependencies matter.
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
config.mouse_wheel_scroll     = 50 * SCALE
config.blink_period           = 0.5
config.draw_whitespace        = false
config.max_undos              = 10000
config.file_size_limit        = 10
config.max_project_files      = 100000
config.ignore_files           = {
  "^node_modules", "^__pycache__", "^%.DS_Store",
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
    core.warn("Failed to load %s: %s", mod, tostring(err))
    local f = io.open(USERDIR .. "/error_log.txt", "a")
    if f then
      f:write("Failed to load " .. mod .. ": " .. tostring(err) .. "\n")
      f:close()
    end
  end
end

safe_require "plugins.mossy_icons"
safe_require "plugins.mossy_treeview"
safe_require "plugins.toggle_terminal"
safe_require "plugins.antigravity_sidebar"
safe_require "plugins.auto_healer"
safe_require "plugins.mossy_statusbar"
safe_require "plugins.resource_monitor"

-- ── 6. Keybindings ────────────────────────────────────────────────────────────
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
  ["ctrl+shift+r"]  = "core:restart",
}

config.borderless = true

-- ── 7. Open CWD when launched without arguments from a project folder ─────────
local function is_generic_dir(path)
  local p = path:lower():gsub("\\", "/")
  local userprofile = (os.getenv("USERPROFILE") or ""):lower():gsub("\\", "/")
  local exedir = EXEDIR:lower():gsub("\\", "/")
  
  if p == userprofile then return true end
  if p == userprofile .. "/desktop" then return true end
  if p == userprofile .. "/documents" then return true end
  if p == userprofile .. "/downloads" then return true end
  if p == userprofile .. "/onedrive" then return true end
  if p == userprofile .. "/onedrive/desktop" then return true end
  if p == userprofile .. "/onedrive/documents" then return true end
  if p == exedir then return true end
  if p == "c:/windows/system32" then return true end
  if p == "c:/windows" then return true end
  
  return false
end

local STARTUP_CWD = system.absolute_path(".")

local original_add_project_directory = core.add_project_directory
function core.add_project_directory(path)
  if #ARGS <= 1 and not core._cwd_handled then
    core._cwd_handled = true
    if STARTUP_CWD and STARTUP_CWD ~= path and not is_generic_dir(STARTUP_CWD) then
      path = STARTUP_CWD
      core.set_project_dir(STARTUP_CWD)
    end
  end
  return original_add_project_directory(path)
end

-- Patch to prevent statusview crash when project_files is nil
local orig_statusview_update = core.statusview.update
function core.statusview:update(...)
  if core.project_files == nil then
    core.project_files = {}
  end
  if orig_statusview_update then
    return orig_statusview_update(self, ...)
  end
end

-- [[ End LazyLite Configuration ]]
