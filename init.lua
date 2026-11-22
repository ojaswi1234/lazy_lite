-- ~/.config/lite-xl/init.lua
-- Dynamic theme and layout configuration for Lite-XL
-- Load order is critical — do NOT reorder these blocks.

local core    = require "core"
local config  = require "core.config"
local style   = require "core.style"
local keymap  = require "core.keymap"
local command = require "core.command"
local common  = require "core.common"

-- ── Notification & Error/Warning Stream Listener ──────────────────────────────
do
  local notif_log_path = USERDIR .. "/notifications_stream.log"
  local function log_entry(level, text, trace)
    pcall(function()
      local fp = io.open(notif_log_path, "a")
      if fp then
        local timestamp = os.date("%Y-%m-%d %H:%M:%S")
        fp:write(string.format("[%s] [%s] %s\n", timestamp, level, tostring(text)))
        if trace and trace ~= "" then
          fp:write(string.format("    Traceback:\n      %s\n", tostring(trace):gsub("\n", "\n      ")))
        end
        fp:flush()
        fp:close()
      end
    end)
  end

  local orig_custom_log = core.custom_log
  function core.custom_log(level, show, backtrace, fmt, ...)
    local msg
    if select("#", ...) > 0 and type(fmt) == "string" then
      local ok, res = pcall(string.format, fmt, ...)
      msg = ok and res or tostring(fmt)
    else
      msg = tostring(fmt)
    end

    if level == "WARN" or level == "ERROR" then
      local tb = backtrace and debug.traceback("", 2) or ""
      log_entry(level, msg, tb)
    elseif show then
      log_entry("NOTIFICATION", msg, nil)
    end

    return orig_custom_log(level, show, backtrace, fmt, ...)
  end

  local orig_on_error = core.on_error
  function core.on_error(err)
    local tb = debug.traceback("", 2)
    log_entry("FATAL", tostring(err), tb)
    if orig_on_error then
      return orig_on_error(err)
    end
  end
end

-- Global Process Spawn Protection
-- Wraps process.start to prevent fatal Lua crashes when executables (like bash, gh, powershell) are missing.
local process = require "process"
local orig_process_start = process.start
function process.start(...)
  local ok, a, b, c = pcall(orig_process_start, ...)
  if ok then return a, b, c else return nil, a end
end

-- Global Active View Guard
-- Prevents fatal crashes when core components or plugins attempt to restore active view to nil (e.g. NagView, TitleView, or closed tabs)
local function get_fallback_view()
  if not core.root_view then return nil end
  local node = core.root_view.get_primary_node and core.root_view:get_primary_node()
  if node then
    if node.active_view and node.active_view ~= core.nag_view then
      return node.active_view
    end
    if node.views and #node.views > 0 then
      for _, v in ipairs(node.views) do
        if v ~= core.nag_view then return v end
      end
    end
  end
  local default_node = core.root_view.get_active_node_default and core.root_view:get_active_node_default()
  return default_node and default_node.active_view
end

local orig_core_set_active_view = core.set_active_view
function core.set_active_view(view)
  if not view or (core.nag_view and view == core.nag_view and not core.nag_view.visible) then
    view = get_fallback_view()
  end
  if not view then return end
  return orig_core_set_active_view(view)
end

-- ── 1. Color scheme — Dynamic Theme Resolution ───────────────────────────────
-- Dynamically loads user's saved theme from user_settings.lua to ensure
-- persistence across restarts and eliminate hardcoded overrides.
local function get_saved_theme()
  local ok, t = pcall(dofile, USERDIR .. "/user_settings.lua")
  if ok and type(t) == "table" and t.config and t.config.theme and t.config.theme ~= "" then
    return t.config.theme
  end
  return "everforest_lite_xl"
end

local active_theme = get_saved_theme()
local ok_theme = pcall(require, "colors." .. active_theme)
if not ok_theme then
  pcall(require, "colors.everforest_lite_xl")
end

-- ── 2. Font — Auto-Native OS Fonts & Universal Fallback ─────────────────────────
-- Global Universal Font Fallback Builder
-- Combines any primary typeface with vector outlines for modern emojis (Segoe UI Emoji),
-- box/technical symbols (Segoe UI Symbol), and Nerd Font icons (FiraCodeNerdFont)
-- so that missing-glyph question marks '?' never appear anywhere in the editor.
function core.create_font_fallback_group(primary, size, opts)
  if not primary then return nil end
  local primary_font = primary
  local sz = size
  if type(primary) == "string" then
    sz = sz or (15 * SCALE)
    local ok, f = pcall(renderer.font.load, primary, sz, opts or {})
    if not ok or not f then return nil end
    primary_font = f
  else
    sz = sz or (primary_font.get_size and primary_font:get_size()) or (primary_font.get_height and primary_font:get_height()) or (15 * SCALE)
  end

  local candidates = {}
  if PLATFORM == "Windows" then
    local windir = os.getenv("WINDIR") or "C:\\Windows"
    table.insert(candidates, windir .. "\\Fonts\\seguiemj.ttf")
    table.insert(candidates, windir .. "\\Fonts\\seguisym.ttf")
    table.insert(candidates, windir .. "\\Fonts\\arialuni.ttf")
  else
    for _, p in ipairs({
      "/System/Library/Fonts/Apple Color Emoji.ttc",
      "/Library/Fonts/Apple Color Emoji.ttc",
      "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
      "/usr/share/fonts/noto/NotoColorEmoji.ttf",
      "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf",
      "/usr/share/fonts/truetype/ancient-scripts/Symbola.ttf",
    }) do table.insert(candidates, p) end
  end
  table.insert(candidates, USERDIR .. "/fonts/FiraCodeNerdFont-Regular.ttf")
  table.insert(candidates, USERDIR .. "/fonts/NotoEmoji-Regular.ttf")
  table.insert(candidates, USERDIR .. "/fonts/NotoColorEmoji.ttf")

  local chain = { primary_font }
  for _, path in ipairs(candidates) do
    local f_test = io.open(path, "rb")
    if f_test then
      f_test:close()
      local ok, f_extra = pcall(renderer.font.load, path, sz, opts or {})
      if ok and f_extra then
        table.insert(chain, f_extra)
        if #chain >= 5 then break end
      end
    end
  end

  if #chain > 1 then
    local ok, grp = pcall(renderer.font.group, chain)
    if ok and grp then
      return grp
    end
  end
  return primary_font
end

local function try_load_font(path, size, opts)
  return core.create_font_fallback_group(path, size, opts)
end

local os_fonts = {
  USERDIR .. "/fonts/FiraCode-iScript.ttf",
  USERDIR .. "/fonts/FiraCodeNerdFont-Regular.ttf",
}

if PLATFORM == "Windows" then
  local windir = os.getenv("WINDIR") or "C:\\Windows"
  table.insert(os_fonts, windir .. "\\Fonts\\consola.ttf") -- Consolas
  table.insert(os_fonts, windir .. "\\Fonts\\lucon.ttf")   -- Lucida Console
elseif PLATFORM == "Mac OS X" then
  table.insert(os_fonts, "/System/Library/Fonts/Menlo.ttc")
  table.insert(os_fonts, "/System/Library/Fonts/Monaco.ttf")
else
  table.insert(os_fonts, "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf")
  table.insert(os_fonts, "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf")
  table.insert(os_fonts, "/usr/share/fonts/dejavu/DejaVuSansMono.ttf")
end

local base_font = nil
local font_path_used = nil
for _, path in ipairs(os_fonts) do
  base_font = try_load_font(path, 15 * SCALE)
  if base_font then 
    font_path_used = path
    break 
  end
end

if base_font then
  style.font          = base_font
  style.big_font      = try_load_font(font_path_used, 20 * SCALE) or base_font
  style.code_font     = base_font
  
  -- Try to load icons, but fallback to base if missing
  local NERD_PATH = USERDIR .. "/fonts/FiraCodeNerdFont-Regular.ttf"
  style.icon_font     = try_load_font(NERD_PATH, 14 * SCALE) or base_font
  style.icon_big_font = try_load_font(NERD_PATH, 28 * SCALE) or base_font
end

-- ── 3. Editor behaviour (VS Code defaults) ────────────────────────────────────
config.tab_type               = "soft"
config.indent_size            = 4
config.max_project_files      = 50000
config.line_limit             = 120
config.highlight_current_line = true
config.mouse_wheel_scroll     = 50 * SCALE
config.blink_period           = 0.5
config.draw_whitespace        = false
config.max_undos              = 10000
config.file_size_limit        = 10
config.ignore_files           = {
  "^%.git$", "^node_modules$", "^__pycache__$", "^%.DS_Store$",
  "^venv$", "^%.venv$", "^build$", "^dist$", "^%.next$", "^vendor$",
  "^%.gemini$", "^AppData$", "^%.config$", "^%.cache$", "^%.vscode$",
  "^%.npm$", "^%.rustup$", "^%.cargo$", "^%.antigravity$", "^tempfiles$",
  "^NTUSER%.DAT", "^ntuser%.dat", "%.tmp$", "%.log$", "%.cache$"
}

-- ── 4. Built-in plugin config ─────────────────────────────────────────────────
-- Plugin toggles are now managed by the GUI Settings plugin (user_settings.lua)
-- Hardcoding them here causes conflicts and startup warnings.
-- (Use the settings menu in the editor to toggle plugins)

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
safe_require "plugins.font_picker"
safe_require "plugins.empty_file_guide"


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
  ["alt+p"]         = "pdf:open-file",
  ["ctrl+alt+p"]    = "pdf:open-file",
  ["shift+alt+f"]   = "lsp:format-document",
  ["alt+shift+f"]   = "lsp:format-document",
  ["ctrl+alt+l"]    = "lsp:toggle-servers",
  ["alt+l"]         = "lsp:toggle-servers",
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

-- ── 8. Responsive Filesystem Indexing ──────────────────────────────────────────
-- Keep UI silky smooth (60 FPS) while project files are indexed progressively
config.max_project_files = 10000

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



-- ── 13. Fix Theme Inconsistency & State Cleanup ──────────────────────────────
-- When switching themes, Lua doesn't delete unknown keys from the style table.
-- We hook module reloading to explicitly wipe custom theme override properties
-- so colors from previous themes don't permanently bleed into newly selected themes.
local old_reload = core.reload_module
function core.reload_module(name)
  if type(name) == "string" and name:match("^colors%.") then
    style.mossy = nil
    style.tab_bar_background = nil
    style.titlebar_background = nil
    style.titlebar_text = nil
  end
  return old_reload(name)
end

function core.set_theme(theme_name)
  style.mossy = nil
  style.tab_bar_background = nil
  style.titlebar_background = nil
  style.titlebar_text = nil

  local ok, err = pcall(core.reload_module, "colors." .. theme_name)
  if not ok then
    core.error("Failed to load theme %q: %s", theme_name, tostring(err))
    return false
  end

  config.theme = theme_name

  local settings_ok, settings = pcall(require, "plugins.settings")
  if settings_ok and settings.config then
    settings.config.theme = theme_name
  end

  local ok_read, user_cfg = pcall(dofile, USERDIR .. "/user_settings.lua")
  if not ok_read or type(user_cfg) ~= "table" then
    user_cfg = { config = {} }
  end
  user_cfg.config = user_cfg.config or {}
  user_cfg.config.theme = theme_name

  local fp = io.open(USERDIR .. "/user_settings.lua", "w")
  if fp then
    fp:write("return " .. common.serialize(user_cfg) .. "\n")
    fp:close()
  end

  core.log("Switched theme to %q", theme_name)
  core.redraw = true
  return true
end

command.add(nil, {
  ["theme:select"] = function()
    local colors = {}
    local seen = {}
    for _, root in ipairs({ DATADIR, USERDIR }) do
      local dir = root .. "/colors"
      for _, file in ipairs(system.list_dir(dir) or {}) do
        local name = file:match("^(.-)%.lua$")
        if name and not seen[name] then
          seen[name] = true
          table.insert(colors, name)
        end
      end
    end
    table.sort(colors)

    core.command_view:enter("Select Theme", {
      submit = function(text, item)
        local theme_name = item and item.text or text
        if theme_name and theme_name ~= "" then
          core.set_theme(theme_name)
        end
      end,
      suggest = function(text)
        return common.fuzzy_match(colors, text)
      end
    })
  end
})

-- ── 14. Hide Tab Overflow Arrows Visually ────────────────────────────────────
local Node = require "core.node"
local old_draw = Node.draw_tabs
local renderer = require "renderer"

function Node:draw_tabs(...)
  local old_draw_text = renderer.draw_text
  -- Intercept text rendering just for the tab bar
  renderer.draw_text = function(font, text, x, y, color)
    -- If it tries to draw the specific scroll/dropdown icons, skip them!
    if text == "\u{f104}" or text == "\u{f105}" or text == "\u{f107}" then
      return x
    end
    return old_draw_text(font, text, x, y, color)
  end
  
  local res = old_draw(self, ...)
  
  -- Restore the normal text renderer immediately after
  renderer.draw_text = old_draw_text
  return res
end

-- ── Auto-Close Editor Splits on Startup ───────────────────────────────────────
core.add_thread(function()
  coroutine.yield() -- Wait one frame for workspace to load

  local max_iters = 20 -- Safety limit to prevent infinite loop
  for iter = 1, max_iters do
    local editor_nodes = {}
    local function collect(node)
      if node.type == "leaf" then
        if not node.locked then table.insert(editor_nodes, node) end
      elseif node.type ~= "leaf" then
        collect(node.a)
        collect(node.b)
      end
    end
    collect(core.root_view.root_node)
    
    if #editor_nodes <= 1 then break end
    
    local source = editor_nodes[2]
    local view = source.views[1]
    
    if view then
      source:remove_view(core.root_view.root_node, view)
      
      -- Re-collect to find the surviving editor node, safely avoiding detached tables
      local surviving_nodes = {}
      local function collect_survivors(node)
        if node.type == "leaf" then
          if not node.locked then table.insert(surviving_nodes, node) end
        elseif node.type ~= "leaf" then
          collect_survivors(node.a)
          collect_survivors(node.b)
        end
      end
      collect_survivors(core.root_view.root_node)
      
      if #surviving_nodes > 0 then
        surviving_nodes[1]:add_view(view)
      end
    else
      break -- no view to move, stop
    end
  end
end)

-- Window Opacity Setting
local settings_module = require "plugins.settings"
if settings_module then
  settings_module.add("Appearance", {
    {
      label = "Window Opacity",
      description = "Adjust the global transparency of the editor window (glass effect).",
      path = "window_opacity",
      type = settings_module.type.NUMBER,
      default = 1.0,
      min = 0.1,
      max = 1.0,
      step = 0.05,
      on_apply = function(value)
        if system.set_window_opacity then
          system.set_window_opacity(value)
        end
      end
    }
  })
end

core.add_thread(function()
  coroutine.yield()
  if config.window_opacity and config.window_opacity < 1.0 then
    if system.set_window_opacity then
      system.set_window_opacity(config.window_opacity)
    end
  end
end)

-- 14. Native OS Font on startup (applied by font_picker plugin)
core.add_thread(function()
  coroutine.yield(0.5) -- wait for plugins to load
  if config.native_code_font and config.native_code_font ~= "" then
    local f = core.create_font_fallback_group(config.native_code_font, 15 * SCALE)
    if f then
      style.code_font = f
      style.font = f
      core.redraw = true
    end
  end
end)


-- 15. System-Level UI Performance & Smoothness Enhancements
-- Uncap the engine frame rate for high-refresh-rate monitors (144Hz+)
config.fps = 144

-- Accelerate the internal spring-physics transition math. 
-- This makes sidebars, terminals, and menus snap open much faster while keeping the smooth deceleration.
config.animation_rate = 2.5

-- Tune the Lua Garbage Collector for high-frequency game loop rendering.
-- A lower pause (110 instead of 200) forces GC to run more frequently in tiny increments,
-- completely eliminating microscopic frame-drop stutters during heavy text scrolling.
collectgarbage("setpause", 110)
collectgarbage("setstepmul", 200)

-- Disable LSP autostart
if not config.plugins.lsp then config.plugins.lsp = {} end
config.plugins.lsp.autostart_server = false

-- [[ LazyLite API Fallback ]]
config.ai_sidebar = config.ai_sidebar or {}
config.ai_sidebar.active_tool = "cloud_api"
