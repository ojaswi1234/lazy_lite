-- font_picker.lua  (mod-version:3)
-- Scans native OS fonts using Lite XL's process API (cross-platform).
-- Adds a "Fonts" section to UI: Settings with a live searchable picker.
--
-- Windows : scans C:\Windows\Fonts + user-installed fonts
-- Linux   : scans /usr/share/fonts, ~/.fonts, ~/.local/share/fonts, etc.
-- macOS   : scans /System/Library/Fonts, /Library/Fonts, ~/Library/Fonts

local core   = require "core"
local style  = require "core.style"
local config = require "core.config"

local settings_ok, settings = pcall(require, "plugins.settings")
if not settings_ok then return end

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.  Font catalogue  (populated asynchronously at startup)
-- ─────────────────────────────────────────────────────────────────────────────
local font_catalogue  = {}   -- { { text = "display name", path = "full/path.ttf" }, … }
local catalogue_ready = false

local function build_catalogue(raw_output)
  local seen, list = {}, {}
  for line in (raw_output .. "\n"):gmatch("([^\r\n]+)") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" then
      local ext = line:match("%.(%a+)$")
      if ext and (ext:lower() == "ttf" or ext:lower() == "ttc" or ext:lower() == "otf") then
        local key = line:lower()
        if not seen[key] then
          seen[key] = true
          local fname = line:match("[/\\]([^/\\]+)$") or line
          local name  = fname:gsub("%.[Tt][Tt][CcFf]$", "")
                             :gsub("%.[Oo][Tt][Ff]$",    "")
                             :gsub("[-_]", " ")
          table.insert(list, { text = name, path = line })
        end
      end
    end
  end
  table.sort(list, function(a, b) return a.text:lower() < b.text:lower() end)
  return list
end

-- Launch the scanner in a background coroutine
core.add_thread(function()
  coroutine.yield(1.5)

  local cmd

  if PLATFORM == "Windows" then
    local windir    = os.getenv("WINDIR") or "C:\\Windows"
    local fonts_dir = windir .. "\\Fonts"
    local bat_path  = USERDIR .. "\\font_picker_scan.bat"
    local userfonts = (os.getenv("LOCALAPPDATA") or "") .. "\\Microsoft\\Windows\\Fonts"

    local bf = io.open(bat_path, "w")
    if not bf then
      core.log("[font_picker] ERROR: could not write helper bat")
      return
    end
    bf:write("@echo off\r\n")
    bf:write('for %%F in ("' .. fonts_dir .. '\\*.ttf" "' .. fonts_dir .. '\\*.ttc" "' .. fonts_dir .. '\\*.otf") do echo %%~fF\r\n')
    bf:write('for %%F in ("' .. userfonts .. '\\*.ttf" "' .. userfonts .. '\\*.ttc" "' .. userfonts .. '\\*.otf") do echo %%~fF\r\n')
    bf:close()

    cmd = { "cmd.exe", "/c", bat_path }

  elseif PLATFORM == "Mac OS X" then
    local home = os.getenv("HOME") or ""
    local dirs = { "/System/Library/Fonts", "/Library/Fonts", home .. "/Library/Fonts" }
    local find_args = "find " .. table.concat(dirs, " ")
      .. " \\( -name '*.ttf' -o -name '*.ttc' -o -name '*.otf' \\) -type f 2>/dev/null"
    cmd = { "sh", "-c", find_args }

  else  -- Linux / BSD
    local home = os.getenv("HOME") or ""
    local candidates = {
      "/usr/share/fonts",
      "/usr/local/share/fonts",
      home .. "/.fonts",
      home .. "/.local/share/fonts",
    }
    local existing = {}
    for _, d in ipairs(candidates) do
      local tf = io.open(d .. "/.", "r")
      if tf then tf:close(); table.insert(existing, d) end
    end
    if #existing == 0 then
      core.log("[font_picker] No font directories found.")
      return
    end
    local find_args = "find " .. table.concat(existing, " ")
      .. " \\( -name '*.ttf' -o -name '*.ttc' -o -name '*.otf' \\) -type f 2>/dev/null"
    cmd = { "sh", "-c", find_args }
  end

  local p = process.start(cmd, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_DISCARD })
  if not p then
    core.log("[font_picker] ERROR: could not start scanner process")
    return
  end

  local raw = ""
  local deadline = system.get_time() + 15
  while p:running() and system.get_time() < deadline do
    local chunk = p:read_stdout()
    if chunk and chunk ~= "" then raw = raw .. chunk end
    coroutine.yield(0.1)
  end

  -- Process might have exited but pipe might still have data
  while true do
    local chunk = p:read_stdout()
    if not chunk or chunk == "" then break end
    raw = raw .. chunk
  end

  font_catalogue = build_catalogue(raw)
  catalogue_ready = true
  core.log(string.format("[font_picker] Found %d system fonts.", #font_catalogue))

  if PLATFORM == "Windows" then
    os.remove(USERDIR .. "\\font_picker_scan.bat")
  end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.  Helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function apply_font(path, size)
  size = size or (config.native_code_font_size or 15)
  local ok, fnt = pcall(renderer.font.load, path, size * SCALE)
  if ok and fnt then
    style.code_font = fnt
    style.font      = fnt
    core.redraw     = true
    return true
  end
  return false
end

local function suggest_fonts(query)
  -- Returns list of { text = display_name }  that match the query
  query = query:lower()
  local results = {}
  for _, item in ipairs(font_catalogue) do
    if query == "" or item.text:lower():find(query, 1, true) then
      table.insert(results, { text = item.text })
    end
  end
  return results
end

local function resolve_path_by_name(name)
  for _, item in ipairs(font_catalogue) do
    if item.text == name then return item.path end
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.  Settings UI
-- ─────────────────────────────────────────────────────────────────────────────
settings.add("Fonts", {
  {
    label    = "Current Font",
    description = "Name of the active font (set via the picker below).",
    path     = "native_code_font_name",
    type     = settings.type.STRING,
    default  = "Default",
  },
  {
    label    = "Font Size",
    description = "Editor & terminal font size in points.",
    path     = "native_code_font_size",
    type     = settings.type.NUMBER,
    default  = 15,
    min      = 8,
    max      = 32,
    step     = 0.5,
    on_apply = function(value)
      local path = config.native_code_font
      if path and path ~= "" then apply_font(path, value) end
    end,
  },
  {
    label    = "Pick System Font…",
    description = "Search & select any installed font on your system (Windows / Linux / macOS).",
    path     = "native_code_font_btn",
    type     = settings.type.BUTTON,
    -- on_click receives (button_name, x, y) — we ignore them
    on_click = function()
      if not catalogue_ready then
        core.log("[font_picker] Still scanning fonts — please wait a moment.")
        return
      end

      -- Open a standard CommandView search box (works in all Lite XL 3.x versions)
      core.command_view:enter("Pick System Font", {
        submit = function(name)
          if name == "" or name == "Default" then
            config.native_code_font      = ""
            config.native_code_font_name = "Default"
            -- Restore default font
            local sz = (config.native_code_font_size or 15) * SCALE
            local function try(p) local ok,f = pcall(renderer.font.load, p, sz); return ok and f or nil end
            local def = try(USERDIR .. "/fonts/FiraCode-iScript.ttf")
                     or try(USERDIR .. "/fonts/FiraCodeNerdFont-Regular.ttf")
            if def then style.code_font = def; style.font = def; core.redraw = true end
            core.log("[font_picker] Reset to default font.")
            return
          end
          local path = resolve_path_by_name(name)
          if path then
            local size = config.native_code_font_size or 15
            if apply_font(path, size) then
              config.native_code_font      = path
              config.native_code_font_name = name
              core.log("[font_picker] Applied: " .. name)
            else
              core.log("[font_picker] Failed to load: " .. path)
            end
          else
            core.log("[font_picker] Font not found in catalogue: " .. name)
          end
        end,
        suggest = function(query)
          -- Prepend a reset option
          local results = { { text = "Default (reset)" } }
          local matches = suggest_fonts(query)
          for _, m in ipairs(matches) do table.insert(results, m) end
          return results
        end,
      })
    end,
  },
})

-- ─────────────────────────────────────────────────────────────────────────────
-- 4.  Restore saved font on startup
-- ─────────────────────────────────────────────────────────────────────────────
core.add_thread(function()
  coroutine.yield(0.5)
  if config.native_code_font and config.native_code_font ~= "" then
    local size = config.native_code_font_size or 15
    if apply_font(config.native_code_font, size) then
      core.log("[font_picker] Restored: " .. (config.native_code_font_name or "?"))
    end
  end
end)
