-- ~/.config/lite-xl/init.lua
-- VS Code Everforest Light layout for Lite-XL
-- Load order is critical — do NOT reorder these blocks.

local core    = require "core"
local config  = require "core.config"
local style   = require "core.style"
local keymap  = require "core.keymap"
local command = require "core.command"
local common  = require "core.common"

-- ── 1. Color scheme (must load before any rendering) ──────────────────────────
-- NOTE: Lua module names cannot contain hyphens. File is everforest_lite_xl.lua
require "colors.everforest_lite_xl"

-- ── 2. Font — Fira Code iScript ───────────────────────────────────────────────
-- Download from: https://github.com/kencrocken/FiraCodeiScript
-- Place the TTF at: ~/.config/lite-xl/fonts/FiraCode-iScript.ttf
-- Nerd Font for icons: ~/.config/lite-xl/fonts/FiraCodeNerdFont-Regular.ttf
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

-- ── 3. Editor behaviour (VS Code defaults) ────────────────────────────────────
config.tab_type               = "soft"
config.indent_size            = 4
config.max_project_files      = 25000
config.line_limit             = 120
config.highlight_current_line = true
config.mouse_wheel_scroll     = 50 * SCALE
config.blink_period           = 0.5
config.draw_whitespace        = false
config.max_undos              = 10000
config.file_size_limit        = 10
config.ignore_files           = {
  "^%.git", "^node_modules", "^__pycache__", "^%.env$", "^%.DS_Store",
  "^venv$", "^%.venv$", "^build$", "^dist$", "^%.next$", "^vendor$"
}

-- ── 4. Built-in plugin config ─────────────────────────────────────────────────
config.plugins.treeview       = true
config.plugins.autocomplete   = true
config.plugins.bracketmatch   = true
config.plugins.autosave       = false
config.plugins.minimap        = true
config.plugins.drawwhitespace = false
config.plugins.lineguide      = false
config.plugins.wordcount      = false

-- ── 5. Hybrid Theme Universal Patches ──────────────────────────────────────────
local Node = require "core.node"
local old_node_draw_tabs = Node.draw_tabs
function Node:draw_tabs(...)
  local old_text = style.text
  local old_dim = style.dim
  local old_bg2 = style.background2
  if style.mossy then
    style.background2 = style.tab_bar_background or style.mossy.activity_bg or style.background2
    style.text = style.syntax.normal or style.text
    style.dim = style.mossy.sidebar_text or style.dim
  end
  old_node_draw_tabs(self, ...)
  style.text = old_text
  style.dim = old_dim
  style.background2 = old_bg2
end

local TreeView_ok, TreeView = pcall(require, "plugins.treeview")
if TreeView_ok then
  local old_tv_draw = TreeView.draw
  function TreeView:draw(...)
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
    old_tv_draw(self, ...)
    style.background2 = old_bg2
    style.background3 = old_bg3
    style.text = old_text
    style.dim = old_dim
  end
end

local TitleView_ok, TitleView = pcall(require, "core.titleview")
if TitleView_ok then
  local old_title_draw = TitleView.draw
  function TitleView:draw(...)
    local old_bg2 = style.background2
    local old_bg3 = style.background3
    local old_text = style.text
    local old_dim = style.dim
    if style.mossy then
      style.background2 = style.titlebar_background or style.mossy.activity_bg or style.background2
      style.background3 = style.titlebar_background or style.mossy.activity_bg or style.background3
      style.text = style.titlebar_text or style.mossy.sidebar_text or style.text
      style.dim = style.titlebar_text or style.mossy.sidebar_muted or style.dim
    end
    old_title_draw(self, ...)
    style.background2 = old_bg2
    style.background3 = old_bg3
    style.text = old_text
    style.dim = old_dim
  end
end

local ToolbarView_ok, ToolbarView = pcall(require, "plugins.toolbarview")
if ToolbarView_ok then
  local old_toolbar_draw = ToolbarView.draw
  function ToolbarView:draw(...)
    local old_bg2 = style.background2
    local old_bg3 = style.background3
    local old_text = style.text
    local old_dim = style.dim
    if style.mossy then
      style.background2 = style.mossy.activity_bg or style.background2
      style.background3 = style.mossy.activity_bg or style.background3
      style.text = style.mossy.activity_icon_hl or style.text
      style.dim = style.mossy.sidebar_muted or style.dim
    end
    old_toolbar_draw(self, ...)
    style.background2 = old_bg2
    style.background3 = old_bg3
    style.text = old_text
    style.dim = old_dim
  end
end

-- ── 6. Custom plugins ─────────────────────────────────────────────────────────
-- mossy_icons must load before mossy_treeview (dependency order)
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
safe_require "plugins.git_timeline"
safe_require "plugins.github_actions"
safe_require "plugins.antigravity_sidebar"
safe_require "plugins.auto_healer"
safe_require "plugins.mossy_statusbar"
safe_require "plugins.loader_games"
safe_require "plugins.virtual_codespace_fs"
safe_require "plugins.github_codespaces"


-- ── 6. Keybindings (VS Code parity) ──────────────────────────────────────────
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
  ["ctrl+shift+g"]  = "git-timeline:toggle",
}

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
      
      local recents = core.recent_projects
      local dirname = common.normalize_volume(STARTUP_CWD)
      if recents and dirname then
        for i, v in ipairs(recents) do
          if v == dirname then
            table.remove(recents, i)
            break
          end
        end
        table.insert(recents, 1, dirname)
      end
    end
  end
  return original_add_project_directory(path)
end
config.borderless = true
safe_require "plugins.resource_monitor"

-- Patch to prevent statusview crash when project_files is nil
local StatusView = require "core.statusview"
local orig_statusview_update = StatusView.update
function StatusView:update(...)
  if core.project_files == nil then
    core.project_files = {}
  end
  if orig_statusview_update then
    return orig_statusview_update(self, ...)
  end
end

-- ── 12. Fix Inactive Tab Font Color ──────────────────────────────────────────
-- The user requested that inactive tabs use the exact same dark text color as active tabs.
-- We temporarily override style.dim during the drawing of the tab title.
local Node = require "core.node"
local style = require "core.style"
local old_draw_tab_title = Node.draw_tab_title
function Node:draw_tab_title(view, font, is_active, is_hovered, x, y, w, h)
  local old_dim = style.dim
  style.dim = style.text 
  old_draw_tab_title(self, view, font, is_active, is_hovered, x, y, w, h)
  style.dim = old_dim
end

-- ── 13. Fix Theme Inconsistency ──────────────────────────────────────────────
-- When switching themes, Lua doesn't delete unknown keys from the style table.
-- We hook module reloading to explicitly wipe style.mossy when a new theme loads,
-- so the mossy colors don't permanently bleed into standard themes.
local old_reload = core.reload_module
function core.reload_module(name)
  if type(name) == "string" and name:match("^colors%.") then
    style.mossy = nil
  end
  return old_reload(name)
end
