-- font_picker.lua
-- Scans native OS fonts using Lite XL's process API (cross-platform).
-- Adds a "Fonts" section to UI: Settings with a live searchable picker.
--
-- Windows: scans C:\Windows\Fonts + user fonts
-- Linux:   scans /usr/share/fonts, /usr/local/share/fonts, ~/.fonts, ~/.local/share/fonts
-- macOS:   scans /System/Library/Fonts, /Library/Fonts, ~/Library/Fonts

local core    = require "core"
local style   = require "core.style"
local config  = require "core.config"

local settings_ok, settings = pcall(require, "plugins.settings")
if not settings_ok then return end

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.  Platform-aware font directory scanner
-- ─────────────────────────────────────────────────────────────────────────────
local font_catalogue  = {}
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
          -- Store full path; derive a human-friendly name from the filename
          local fname = line:match("[/\\]([^/\\]+)$") or line
          local name  = fname:gsub("%.[Tt][Tt][CcFf]$",""):gsub("%.[Oo][Tt][Ff]$","")
                             :gsub("[-_]", " ")
          table.insert(list, { name, line })   -- { display_name, full_path }
        end
      end
    end
  end
  table.sort(list, function(a, b) return a[1]:lower() < b[1]:lower() end)
  return list
end

-- Launch a background scan using Lite XL's process API
core.add_thread(function()
  coroutine.yield(1.5)   -- let editor finish loading first

  local out_path = USERDIR .. "/font_picker_list.txt"
  local cmd      = nil

  if PLATFORM == "Windows" then
    -- Write a .bat that lists all fonts and emits their full paths
    local windir    = os.getenv("WINDIR") or "C:\\Windows"
    local fonts_dir = windir .. "\\Fonts"
    local bat_path  = USERDIR .. "\\font_picker_scan.bat"

    local bf = io.open(bat_path, "w")
    if not bf then
      core.log("[font_picker] ERROR: could not write helper bat")
      return
    end
    bf:write("@echo off\r\n")
    -- Emit full absolute paths for every ttf/ttc/otf
    bf:write('for %%F in ("' .. fonts_dir .. '\\*.ttf" "' .. fonts_dir .. '\\*.ttc" "' .. fonts_dir .. '\\*.otf") do echo %%~fF\r\n')
    -- Also scan user-installed fonts (Windows 10+)
    local userfonts = (os.getenv("LOCALAPPDATA") or "") .. "\\Microsoft\\Windows\\Fonts"
    bf:write('for %%F in ("' .. userfonts .. '\\*.ttf" "' .. userfonts .. '\\*.ttc" "' .. userfonts .. '\\*.otf") do echo %%~fF\r\n')
    bf:close()

    cmd = { "cmd.exe", "/c", bat_path .. " > \"" .. out_path .. "\" 2>nul" }

  elseif PLATFORM == "Mac OS X" then
    -- Use `find` across standard macOS font dirs
    local home = os.getenv("HOME") or "~"
    local dirs = {
      "/System/Library/Fonts",
      "/Library/Fonts",
      home .. "/Library/Fonts",
    }
    local find_args = "find " .. table.concat(dirs, " ")
                    .. " \\( -name '*.ttf' -o -name '*.ttc' -o -name '*.otf' \\)"
                    .. " -type f 2>/dev/null > '" .. out_path .. "'"
    cmd = { "sh", "-c", find_args }

  else
    -- Linux: scan standard XDG font directories
    local home = os.getenv("HOME") or ""
    local dirs = {
      "/usr/share/fonts",
      "/usr/local/share/fonts",
      home .. "/.fonts",
      home .. "/.local/share/fonts",
    }
    -- Filter only existing dirs to avoid find errors
    local existing = {}
    for _, d in ipairs(dirs) do
      local tf = io.open(d .. "/.", "r")
      if tf then tf:close(); table.insert(existing, d) end
    end
    if #existing == 0 then
      core.log("[font_picker] No font directories found on Linux.")
      return
    end
    local find_args = "find " .. table.concat(existing, " ")
                    .. " \\( -name '*.ttf' -o -name '*.ttc' -o -name '*.otf' \\)"
                    .. " -type f 2>/dev/null > '" .. out_path .. "'"
    cmd = { "sh", "-c", find_args }
  end

  -- Run the scanner
  local p = process.start(cmd, { stdout = process.REDIRECT_PIPE })
  if not p then
    core.log("[font_picker] ERROR: could not start scanner process")
    return
  end

  local deadline = system.get_time() + 15
  while p:running() and system.get_time() < deadline do
    coroutine.yield(0.2)
  end

  -- Read results
  local rf = io.open(out_path, "r")
  if rf then
    local raw = rf:read("*a")
    rf:close()
    os.remove(out_path)
    font_catalogue = build_catalogue(raw)
    catalogue_ready = true
    core.log(string.format("[font_picker] Found %d system fonts.", #font_catalogue))
  else
    core.log("[font_picker] ERROR: could not read font list output file.")
  end

  -- Clean up bat on Windows
  if PLATFORM == "Windows" then
    os.remove(USERDIR .. "\\font_picker_scan.bat")
  end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.  Settings UI — "Fonts" section in UI: Settings
-- ─────────────────────────────────────────────────────────────────────────────
local function apply_font(path, size)
  size = size or (config.native_code_font_size or 15)
  local ok, fnt = pcall(renderer.font.load, path, size * SCALE)
  if ok and fnt then
    style.code_font = fnt
    style.font      = fnt
    core.redraw = true
    return true
  end
  return false
end

settings.add("Fonts", {
  {
    label       = "Current Font",
    description = "Name of the currently active font. Set via the picker button below.",
    path        = "native_code_font_name",
    type        = settings.type.STRING,
    default     = "Default",
  },
  {
    label       = "Font Size",
    description = "Editor & terminal font size (points).",
    path        = "native_code_font_size",
    type        = settings.type.NUMBER,
    default     = 15,
    min         = 8,
    max         = 32,
    step        = 0.5,
    on_apply    = function(value)
      local path = config.native_code_font
      if path and path ~= "" then apply_font(path, value) end
    end
  },
  {
    label       = "Pick System Font…",
    description = "Opens a searchable list of every font installed on your OS (Windows / Linux / macOS).",
    path        = "native_code_font_btn",
    type        = settings.type.BUTTON,
    on_click    = function()
      if not catalogue_ready then
        core.log("[font_picker] Still scanning fonts — please wait a moment and try again.")
        return
      end

      -- Build item list for command palette
      local items = {{ label = "⟳  Default (reset to config font)", path = "" }}
      for _, entry in ipairs(font_catalogue) do
        table.insert(items, { label = entry[1], path = entry[2] })
      end

      core.command_view:enter("Choose System Font", {
        items      = items,
        get_name   = function(item) return item.label end,
        submit     = function(item)
          if item.path == "" then
            -- Reset to custom/default font
            config.native_code_font      = ""
            config.native_code_font_name = "Default"
            local function try_load(p, s)
              local ok, f = pcall(renderer.font.load, p, s)
              return ok and f or nil
            end
            local sz = (config.native_code_font_size or 15) * SCALE
            local def = try_load(USERDIR .. "/fonts/FiraCode-iScript.ttf",        sz)
                     or try_load(USERDIR .. "/fonts/FiraCodeNerdFont-Regular.ttf", sz)
            if def then style.code_font = def; style.font = def end
            core.log("[font_picker] Font reset to default.")
            core.redraw = true
          else
            local size = config.native_code_font_size or 15
            if apply_font(item.path, size) then
              config.native_code_font      = item.path
              config.native_code_font_name = item.label
              core.log("[font_picker] Applied: " .. item.label)
            else
              core.log("[font_picker] Failed to load: " .. item.path)
            end
          end
        end
      })
    end
  },
})

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.  Restore saved font on startup
-- ─────────────────────────────────────────────────────────────────────────────
core.add_thread(function()
  coroutine.yield(0.5)
  if config.native_code_font and config.native_code_font ~= "" then
    local size = config.native_code_font_size or 15
    if apply_font(config.native_code_font, size) then
      core.log("[font_picker] Restored font: " .. (config.native_code_font_name or "?"))
    end
  end
end)
