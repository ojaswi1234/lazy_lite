-- font_picker.lua
-- Scans native OS fonts using Lite XL's process API and adds a live
-- font picker section to UI: Settings > Appearance.

local core    = require "core"
local style   = require "core.style"
local config  = require "core.config"
local command = require "core.command"
local common  = require "core.common"

local settings_ok, settings = pcall(require, "plugins.settings")
if not settings_ok then return end  -- settings UI not installed

-- ──────────────────────────────────────────────────────────────────────
-- 1.  Font catalogue (populated asynchronously at startup)
-- ──────────────────────────────────────────────────────────────────────
local font_catalogue = {}   -- { {label, path}, … }
local catalogue_ready = false

local function build_catalogue(raw_output)
  local seen = {}
  local list = {}
  for line in (raw_output .. "\n"):gmatch("([^\r\n]+)") do
    line = line:match("^%s*(.-)%s*$")  -- trim
    if line ~= "" then
      local ext = line:match("%.(%a+)$")
      if ext and (ext:lower() == "ttf" or ext:lower() == "ttc") then
        local name = line:gsub("%.[Tt][Tt][CcFf]$", "")
        if not seen[line:lower()] then
          seen[line:lower()] = true
          table.insert(list, { name, line })  -- {label, filename}
        end
      end
    end
  end
  table.sort(list, function(a, b) return a[1]:lower() < b[1]:lower() end)
  return list
end

-- Run `dir /b` via Lite XL's own process.start so we bypass io.popen sandbox
core.add_thread(function()
  coroutine.yield(1.0)   -- let the rest of the editor finish loading

  local fonts_dir = (os.getenv("WINDIR") or "C:\\Windows") .. "\\Fonts"

  -- Write a tiny helper .bat to list fonts (most reliable approach)
  local bat_path = USERDIR .. "/font_picker_scan.bat"
  local f = io.open(bat_path, "w")
  if not f then
    core.log("[font_picker] ERROR: could not write scan helper bat")
    return
  end
  f:write('@echo off\r\n')
  f:write('for %%F in ("' .. fonts_dir .. '\\*.ttf" "' .. fonts_dir .. '\\*.ttc") do echo %%~nxF\r\n')
  f:close()

  local out_path = USERDIR .. "/font_picker_list.txt"

  local p = process.start(
    { "cmd.exe", "/c", bat_path .. " > \"" .. out_path .. "\" 2>nul" },
    { stdout = process.REDIRECT_PIPE }
  )
  if not p then
    core.log("[font_picker] ERROR: could not start scanner process")
    return
  end

  -- Wait for it to finish (max 10 sec)
  local deadline = system.get_time() + 10
  while p:running() and system.get_time() < deadline do
    coroutine.yield(0.2)
  end

  -- Read the output file
  local rf = io.open(out_path, "r")
  if rf then
    local raw = rf:read("*a")
    rf:close()
    os.remove(out_path)
    font_catalogue = build_catalogue(raw)
    catalogue_ready = true
    core.log("[font_picker] Loaded " .. #font_catalogue .. " system fonts.")
  else
    core.log("[font_picker] ERROR: could not read font list output")
  end

  os.remove(bat_path)
end)

-- ──────────────────────────────────────────────────────────────────────
-- 2.  Settings UI — uses BUTTON type to open a live command-palette picker
-- ──────────────────────────────────────────────────────────────────────
settings.add("Fonts", {
  {
    label = "System Font Picker",
    description = "Browse & apply any font installed on your PC. Click the button below.",
    path = "native_code_font_label",
    type = settings.type.STRING,
    default = config.native_code_font_name or "Default (Fira Code)",
  },
  {
    label = "Pick System Font…",
    description = "Opens a searchable list of every .ttf/.ttc font on your system.",
    path = "native_code_font_btn",
    type = settings.type.BUTTON,
    on_click = function()
      if not catalogue_ready then
        core.log("[font_picker] Still scanning fonts, please wait a moment and try again.")
        return
      end

      -- Build items for command palette
      local items = {}
      table.insert(items, "Default (Fira Code / custom)")
      for _, entry in ipairs(font_catalogue) do
        table.insert(items, entry[1])
      end

      core.command_view:enter("Choose Font", {
        items = items,
        get_name = function(item) return item end,
        submit = function(item)
          if item == "Default (Fira Code / custom)" then
            config.native_code_font = ""
            config.native_code_font_name = "Default (Fira Code / custom)"
            -- reload default
            local function try_load(path, size)
              local ok, fnt = pcall(renderer.font.load, path, size)
              return ok and fnt or nil
            end
            local default = try_load(USERDIR .. "/fonts/FiraCode-iScript.ttf", 15 * SCALE)
                        or  try_load(USERDIR .. "/fonts/FiraCodeNerdFont-Regular.ttf", 15 * SCALE)
            if default then
              style.code_font = default
              style.font      = default
            end
            core.log("Font reset to default.")
            core.redraw = true
            return
          end

          -- Find the full path
          local chosen_path = nil
          local fonts_dir = (os.getenv("WINDIR") or "C:\\Windows") .. "\\Fonts"
          for _, entry in ipairs(font_catalogue) do
            if entry[1] == item then
              chosen_path = fonts_dir .. "\\" .. entry[2]
              break
            end
          end

          if chosen_path then
            local ok, fnt = pcall(renderer.font.load, chosen_path, 15 * SCALE)
            if ok and fnt then
              style.code_font = fnt
              style.font      = fnt
              config.native_code_font      = chosen_path
              config.native_code_font_name = item
              core.log("Font applied: " .. item)
              core.redraw = true
            else
              core.log("[font_picker] Failed to load: " .. chosen_path)
            end
          end
        end
      })
    end
  },
  {
    label = "Font Size",
    description = "Point size to use for the selected font.",
    path = "native_code_font_size",
    type = settings.type.NUMBER,
    default = 15,
    min = 8,
    max = 32,
    step = 0.5,
    on_apply = function(value)
      local path = config.native_code_font
      if path and path ~= "" then
        local ok, fnt = pcall(renderer.font.load, path, value * SCALE)
        if ok and fnt then
          style.code_font = fnt
          style.font      = fnt
          core.redraw = true
        end
      end
    end
  }
})
