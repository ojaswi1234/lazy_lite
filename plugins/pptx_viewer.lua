-- mod-version:3
-- High Performance PowerPoint (PPTX) Vector & Native Typography Viewer for Lite XL
-- Features:
-- 1. Native FreeType Typography: TrueType kerning, authentic weights (Calibri Bold/Regular),
--    high contrast vibrant colors, word-wrapping, and multi-level bullet hierarchy. Zero raster blur or gibberish.
-- 2. Clean Vector Canvas: Precision cards, containers, borders, fills, and embedded pictures.
-- 3. True Fullscreen Slideshow Mode: Fills 100% of the physical screen edge-to-edge (zero editor chrome).
-- 4. Interactive Slideshow HUD & On-Screen Side Navigation Arrows (< and >).
-- 5. Slide Deck Explorer Thumbnail Strip for Instant Jump Navigation.
-- 6. Blank Screen Blackboard / Whiteboard Mode with Dedicated UI Buttons.
-- 7. Complete internal containment - strictly inside Lite XL (zero external browser or Office popups).

local core = require "core"
local system = require "system"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local Doc = require "core.doc"
local RootView = require "core.rootview"
local process = require "process"

config.plugins.pptx = common.merge({
  thumbnail_width = 220,
  default_mode = "hd",
  snap_sensitivity = "normal",   -- "low", "normal", "high" (far-field presenter)
  snap_double_window_ms = 400,   -- max gap (ms) between 2 fast snaps for previous slide
}, config.plugins.pptx)

local function truncate_text(font, text, max_w)
  if not text or text == "" then return "" end
  if font:get_width(text) <= max_w then return text end
  local ell = "..."
  local ell_w = font:get_width(ell)
  if ell_w >= max_w then return ell end
  local target_w = max_w - ell_w
  local len = #text
  while len > 1 and font:get_width(text:sub(1, len)) > target_w do
    len = len - 1
  end
  return text:sub(1, len) .. ell
end

-- Cached colors for zero GC pressure
local _COLOR_BG_DARK       = { 16, 18, 22 }
local _COLOR_BG_STAGE      = { 22, 25, 30 }
local _COLOR_BG_HUD        = { 20, 24, 30, 235 }
local _COLOR_BORDER        = { 45, 52, 64 }
local _COLOR_BORDER_LIGHT  = { 65, 75, 92 }
local _COLOR_ACCENT        = { 64, 160, 255 }
local _COLOR_ACCENT_HOVER  = { 85, 175, 255 }
local _COLOR_ACCENT_BG     = { 30, 80, 150, 80 }
local _COLOR_TEXT          = { 235, 240, 245 }
local _COLOR_TEXT_DIM      = { 140, 150, 165 }
local _COLOR_SHADOW        = { 0, 0, 0, 160 }
local _COLOR_WHITE         = { 255, 255, 255 }
local _COLOR_BLACK         = { 0, 0, 0 }
local _COLOR_WARN          = { 255, 175, 50 }
local _COLOR_ERROR         = { 240, 90, 90 }
local _COLOR_NOTES_BG      = { 22, 26, 32, 240 }
local _COLOR_CARD_BG       = { 28, 32, 40 }
local _COLOR_CARD_ACTIVE   = { 35, 45, 60 }

local PYTHON_ENGINE = USERDIR .. PATHSEP .. "plugins/pptx_engine.py"
local SNAP_BRIDGE   = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "snap_detector_bridge.py"
local HALF_BLOCK = "▀"

local CACHE_DIR = USERDIR .. PATHSEP .. "tempfiles/pptx_cache"
system.mkdir(USERDIR .. PATHSEP .. "tempfiles")
system.mkdir(CACHE_DIR)

-- Auto-cleanup orphaned cache files from previous sessions
pcall(function()
  for _, file in ipairs(system.list_dir(CACHE_DIR) or {}) do
    if file:match("%.lua$") then
      os.remove(CACHE_DIR .. PATHSEP .. file)
    end
  end
end)

local function invert_color(c, invert)
  if not invert or not c then return c end
  local r = 255 - (c[1] or 0)
  local g = 255 - (c[2] or 0)
  local b = 255 - (c[3] or 0)
  if c[4] ~= nil then
    return { r, g, b, c[4] }
  end
  return { r, g, b }
end

local function clean_temp_path(name)
  if not rawget(_G, "__random_seeded") then
    math.randomseed(os.time() + os.clock() * 1000)
    rawset(_G, "__random_seeded", true)
  end
  return CACHE_DIR .. PATHSEP .. name:gsub("[^%w%._%-]", "_") .. "_" .. os.time() .. "_" .. math.random(1000, 9999)
end

-- ============================================================================
-- DYNAMIC TRUE-TYPE FONT CACHING FOR CRISP NATIVE TYPOGRAPHY
-- ============================================================================
local _FONT_CACHE = {}

-- Quantize to rich discrete pixel sizes so large 40-72pt titles keep authentic scale
local QUANTIZED_SIZES = { 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 26, 28, 30, 34, 38, 42, 46, 54, 64, 76, 90, 108, 128 }

local function quantize_size(raw_size)
  local best = QUANTIZED_SIZES[1]
  local min_diff = math.abs(raw_size - best)
  for i = 2, #QUANTIZED_SIZES do
    local diff = math.abs(raw_size - QUANTIZED_SIZES[i])
    if diff < min_diff then
      min_diff = diff
      best = QUANTIZED_SIZES[i]
    end
  end
  return best
end

local function get_slide_font(size_pt, is_bold, scale_factor, font_family, is_italic)
  -- Convert points using exact slide width scale (1 pt = pw / slide_width_pt)
  local raw_px = (size_pt or 18) * (scale_factor or 1.0)
  local px_size = quantize_size(raw_px)
  local fam = font_family or "sans"
  local style_tag = (is_bold and "b" or "") .. (is_italic and "i" or "")
  if style_tag == "" then style_tag = "r" end
  local cache_key = px_size .. "_" .. fam .. "_" .. style_tag

  if not _FONT_CACHE[cache_key] then
    local candidates = {}
    if fam == "serif" then
      if is_bold and is_italic then
        table.insert(candidates, "C:/Windows/Fonts/georgiaz.ttf")
        table.insert(candidates, "C:/Windows/Fonts/timesbi.ttf")
      elseif is_italic then
        table.insert(candidates, "C:/Windows/Fonts/georgiai.ttf")
        table.insert(candidates, "C:/Windows/Fonts/timesi.ttf")
      elseif is_bold then
        table.insert(candidates, "C:/Windows/Fonts/georgiab.ttf")
        table.insert(candidates, "C:/Windows/Fonts/cambriab.ttf")
        table.insert(candidates, "C:/Windows/Fonts/timesbd.ttf")
      else
        table.insert(candidates, "C:/Windows/Fonts/georgia.ttf")
        table.insert(candidates, "C:/Windows/Fonts/cambria.ttc")
        table.insert(candidates, "C:/Windows/Fonts/times.ttf")
      end
    elseif fam == "mono" then
      if is_bold and is_italic then
        table.insert(candidates, "C:/Windows/Fonts/consolaz.ttf")
      elseif is_italic then
        table.insert(candidates, "C:/Windows/Fonts/consolai.ttf")
      elseif is_bold then
        table.insert(candidates, "C:/Windows/Fonts/consolab.ttf")
      else
        table.insert(candidates, "C:/Windows/Fonts/consola.ttf")
      end
    end
    if is_bold and is_italic then
      table.insert(candidates, "C:/Windows/Fonts/segoeuiz.ttf")
      table.insert(candidates, "C:/Windows/Fonts/arialbi.ttf")
    elseif is_italic then
      table.insert(candidates, "C:/Windows/Fonts/segoeuii.ttf")
      table.insert(candidates, "C:/Windows/Fonts/ariali.ttf")
    elseif is_bold then
      table.insert(candidates, "C:/Windows/Fonts/segoeuib.ttf")
      table.insert(candidates, "C:/Windows/Fonts/arialbd.ttf")
      table.insert(candidates, "C:/Windows/Fonts/calibrib.ttf")
    else
      table.insert(candidates, "C:/Windows/Fonts/segoeui.ttf")
      table.insert(candidates, "C:/Windows/Fonts/arial.ttf")
      table.insert(candidates, "C:/Windows/Fonts/calibri.ttf")
    end
    table.insert(candidates, DATADIR .. "/fonts/FiraSans-Regular.ttf")

    local loaded_font = nil
    for _, font_path in ipairs(candidates) do
      if system.get_file_info(font_path) then
        local ok, f = pcall(renderer.font.load, font_path, px_size)
        if ok and f then
          loaded_font = f
          break
        end
      end
    end

    if not loaded_font and style.font then
      local ok, f = pcall(function() return style.font:copy(px_size) end)
      if ok and f then loaded_font = f end
    end

    _FONT_CACHE[cache_key] = loaded_font or style.font
  end

  return _FONT_CACHE[cache_key] or style.font
end

-- ============================================================================
-- PPTX VIEW COMPONENT
-- ============================================================================
local PptxView = View:extend()

function PptxView:new(filename)
  PptxView.super.new(self)
  self.filename = filename or ""
  if filename and filename ~= "" then
    self.abs_filename = core.project_absolute_path(filename) or filename
    self.basename = common.basename(filename)
    self.name = "PPT: " .. self.basename
  else
    self.abs_filename = ""
    self.basename = "No Presentation"
    self.name = "PowerPoint Viewer"
  end

  self.scrollable = true
  self.scroll = { x = 0, y = 0, to = { x = 0, y = 0 } }

  -- Presentation State
  self.slide = 1
  self.slide_count = 1
  self.slides_meta = {}
  self.aspect_ratio = 1.7778
  self.presentation_title = self.basename

  -- Modes & Display Controls
  self.zoom = 1.0
  self.mode = "hd" -- "hd" (Vector & Native FreeType Typography), "browsh", "text"
  self.inverted = false
  self.show_thumbnails = true
  self.show_notes = false
  self.slideshow_mode = false
  self.blank_screen = nil
  self.show_slideshow_notes = false

  -- Acoustic Snap Control State (Fullscreen Slideshow only)
  self.snap_active = false
  self.snap_ready = false
  self.snap_proc = nil
  self.snap_session_id = 0
  self.snap_status_msg = nil
  self.snap_flash_text = nil
  self.snap_flash_timer = 0

  -- Previous window state for restoring after fullscreen
  self.prev_window_mode = nil
  self.prev_title_visible = nil

  -- HUD auto-hide state for slideshow mode
  self.hud_visible = true
  self.hud_timer = 3.5

  -- Layout Sizing & Customization
  self.toolbar_h = 38 * SCALE
  local cfg_thumb_w = (config.plugins and config.plugins.pptx and config.plugins.pptx.thumbnail_width) or 220
  self.thumbnail_w = cfg_thumb_w * SCALE
  self.resizing_thumbnails = false
  self.hovered_divider = false
  self.notes_h = 130 * SCALE
  self.thumbnail_scroll = { y = 0, to = { y = 0 } }

  -- Interactive Buttons & Regions
  self.toolbar_buttons = {}
  self.thumbnail_buttons = {}
  self.hud_buttons = {}
  self.hud_rect = nil
  self.hovered_btn = nil
  self.hovered_tooltip = nil
  self.hovered_tooltip_rect = nil
  self.last_mouse_x = 0
  self.last_mouse_y = 0
  self.font = style.code_font or style.font

  -- Caching & Process Management
  self.cache = {}
  self.active_proc = nil
  self.active_proc_file = nil
  self.active_proc_type = nil
  self.active_slide_loading = nil

  self.loading = (filename ~= nil and filename ~= "")
  self.loading_msg = self.loading and "Opening presentation..." or nil
  self.error_msg = (not self.loading) and "No presentation loaded. Use Open Presentation button or File menu." or nil

  self.search_query = nil
  self.search_matches = {}
  self.current_match_idx = 1

  self.font = style.code_font

  if filename and filename ~= "" then
    self:load_pptx_info()
  end
end

function PptxView:get_name()
  return self.name
end

function PptxView:get_filename()
  return self.filename
end

function PptxView:destroy()
  self:stop_snap_detector(true)
  if self.slideshow_mode then
    self:exit_slideshow()
  end
  PptxView.super.destroy(self)
end

-- ============================================================================
-- PROCESS & CACHE MANAGEMENT
-- ============================================================================

function PptxView:load_pptx_info()
  self.loading = true
  self.loading_msg = "Extracting presentation structure..."
  self.error_msg = nil

  local out_file = clean_temp_path("info") .. ".lua"
  self.active_proc_file = out_file
  self.active_proc_type = "info"

  local cmd = { "python", PYTHON_ENGINE, "info", self.abs_filename, out_file }
  self.active_proc = process.start(cmd)
  if not self.active_proc then
    self.loading = false
    self.error_msg = "Python runtime or python-pptx not found. Please ensure Python is installed."
    core.redraw = true
  end
end

function PptxView:request_slide(slide_idx, mode)
  mode = mode or self.mode
  slide_idx = math.max(1, math.min(self.slide_count, slide_idx))

  local cache_key = slide_idx .. "_" .. mode
  if self.cache[cache_key] then
    self.loading = false
    core.redraw = true
    return
  end

  if self.active_proc and self.active_slide_loading == cache_key then
    return
  end

  self.loading = true
  self.loading_msg = string.format("Rendering Slide %d / %d (%s)...", slide_idx, self.slide_count, mode:upper())
  self.error_msg = nil
  self.active_slide_loading = cache_key

  local out_file = clean_temp_path("s" .. slide_idx .. "_" .. mode) .. ".lua"
  self.active_proc_file = out_file
  self.active_proc_type = "slide"

  local cmd = { "python", PYTHON_ENGINE, "render", self.abs_filename, tostring(slide_idx - 1), out_file, "110", mode }
  self.active_proc = process.start(cmd)
  if not self.active_proc then
    self.loading = false
    self.error_msg = "Failed to launch PPTX rendering engine."
    core.redraw = true
  end
end

function PptxView:prefetch_next_slide()
  local next_slide = self.slide + 1
  if next_slide <= self.slide_count then
    local key = next_slide .. "_" .. self.mode
    if not self.cache[key] and not self.active_proc then
      local out_file = clean_temp_path("s" .. next_slide .. "_" .. self.mode) .. ".lua"
      self.active_proc_file = out_file
      self.active_proc_type = "prefetch"
      self.active_slide_loading = key
      local cmd = { "python", PYTHON_ENGINE, "render", self.abs_filename, tostring(next_slide - 1), out_file, "110", self.mode }
      self.active_proc = process.start(cmd)
    end
  end
end

function PptxView:scroll_thumbnail_into_view(idx)
  if not self.show_thumbnails then return end
  local card_h = 56 * SCALE
  local card_gap = 6 * SCALE
  local target_y = (idx - 1) * (card_h + card_gap)
  local view_h = self.size.y - self.toolbar_h - 40 * SCALE
  if target_y < self.thumbnail_scroll.y then
    self.thumbnail_scroll.y = target_y
    core.redraw = true
  elseif target_y + card_h > self.thumbnail_scroll.y + view_h then
    self.thumbnail_scroll.y = math.max(0, target_y + card_h - view_h)
    core.redraw = true
  end
end

function PptxView:goto_slide(slide_idx)
  slide_idx = math.max(1, math.min(self.slide_count, slide_idx))
  if self.slide == slide_idx and self.cache[slide_idx .. "_" .. self.mode] then
    return
  end
  self.slide = slide_idx
  self.scroll.to.x = 0
  self.scroll.to.y = 0
  self.blank_screen = nil
  self:request_slide(slide_idx)
  self:scroll_thumbnail_into_view(slide_idx)
  core.redraw = true
end

function PptxView:next_slide()
  if self.slide < self.slide_count then
    self:goto_slide(self.slide + 1)
  end
end

function PptxView:previous_slide()
  if self.slide > 1 then
    self:goto_slide(self.slide - 1)
  end
end

function PptxView:search(query)
  if not query or query == "" then
    self.search_query = nil
    self.search_matches = {}
    self.current_match_idx = 1
    return
  end

  self.search_query = query
  self.loading = true
  self.loading_msg = "Searching presentation for: " .. query .. "..."

  local out_file = clean_temp_path("search") .. ".lua"
  self.active_proc_file = out_file
  self.active_proc_type = "search"

  local cmd = { "python", PYTHON_ENGINE, "search", self.abs_filename, query, out_file }
  self.active_proc = process.start(cmd)
end

function PptxView:goto_match(match_idx)
  if not self.search_matches or #self.search_matches == 0 then return end
  match_idx = math.max(1, math.min(#self.search_matches, match_idx))
  self.current_match_idx = match_idx
  local match = self.search_matches[match_idx]
  if match and match.slide then
    self:goto_slide(match.slide)
    core.redraw = true
  end
end

-- ============================================================================
-- FULLSCREEN SLIDESHOW PRESENTATION CONTROLS
-- ============================================================================

function PptxView:start_slideshow()
  self.slideshow_mode = true
  self.blank_screen = nil
  self.show_slideshow_notes = false
  self.hud_visible = true
  self.hud_timer = 3.5

  -- Switch Lite XL window to True Fullscreen Mode
  self.prev_window_mode = system.get_window_mode()
  system.set_window_mode("fullscreen")
  if core.title_view then
    self.prev_title_visible = core.title_view.visible
    core.show_title_bar(false)
    if core.title_view.configure_hit_test then
      core.title_view:configure_hit_test(false)
    end
  end

  core.redraw = true
  core.log("[Slideshow] Fullscreen presentation active. Press Escape to exit, Space/Arrows or on-screen buttons to navigate.")
end

function PptxView:exit_slideshow()
  self:stop_snap_detector(true)
  if self.slideshow_mode then
    self.slideshow_mode = false
    self.blank_screen = nil
    self.show_slideshow_notes = false

    -- Restore window mode and title bar
    system.set_window_mode(self.prev_window_mode or "normal")
    if core.title_view and self.prev_title_visible ~= nil then
      core.show_title_bar(self.prev_title_visible)
      if core.title_view.configure_hit_test then
        core.title_view:configure_hit_test(self.prev_title_visible)
      end
    end

    core.redraw = true
    core.log("[Slideshow] Exited fullscreen presentation.")
  end
end

function PptxView:toggle_slideshow()
  if self.slideshow_mode then
    self:exit_slideshow()
  else
    self:start_slideshow()
  end
end

function PptxView:_handle_snap_event(evt)
  if not self.slideshow_mode or not self.snap_active or not evt then return end
  if evt.event == "calibrating" then
    self.snap_ready = false
    self.snap_status_msg = "SNAP MIC: Calibrating..."
    core.redraw = true
  elseif evt.event == "ready" then
    self.snap_ready = true
    local mode_tag = evt.ml and "ML" or "DSP"
    local sens_tag = tostring(evt.sensitivity or (config.plugins and config.plugins.pptx and config.plugins.pptx.snap_sensitivity) or "normal"):upper()
    self.snap_status_msg = string.format("SNAP %s [%s] (1x Next | 2x Prev)", mode_tag, sens_tag)
    core.log("[Snap] Microphone %s snap control ready (%s sensitivity; 1 snap = Next, 2 fast snaps = Prev).", mode_tag, sens_tag)
    core.redraw = true
  elseif evt.event == "snap" then
    if evt.action == "next" then
      self.snap_flash_text = "[1x SNAP] Next Slide"
      self.snap_flash_timer = 1.2
      self:next_slide()
    elseif evt.action == "prev" then
      self.snap_flash_text = "[2x SNAP] Previous Slide"
      self.snap_flash_timer = 1.2
      self:previous_slide()
    end
    core.redraw = true
  elseif evt.event == "error" then
    local msg = evt.message or "Snap microphone error"
    core.error("[Snap] %s", msg)
    self:stop_snap_detector(true)
  end
end

function PptxView:start_snap_detector()
  if self.snap_active then return end
  if not self.slideshow_mode then
    core.log("[Snap] Snap control is only active in Fullscreen Slideshow mode.")
    return
  end
  if not system.get_file_info(SNAP_BRIDGE) then
    core.error("[Snap] Detector script not found: %s", SNAP_BRIDGE)
    return
  end

  local cfg = (config.plugins and config.plugins.pptx) or {}
  local sens = tostring(cfg.snap_sensitivity or "normal")
  local dbl_ms = tostring(cfg.snap_double_window_ms or 400)

  local proc = process.start({
    "python", "-u", SNAP_BRIDGE,
    "--sensitivity", sens,
    "--double-window-ms", dbl_ms,
  }, {
    stdout = process.REDIRECT_PIPE,
    stdin  = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if not proc then
    core.error("[Snap] Failed to start Python snap detector process.")
    return
  end

  self.snap_session_id = (self.snap_session_id or 0) + 1
  local session_id = self.snap_session_id
  self.snap_proc = proc
  self.snap_active = true
  self.snap_ready = false
  self.snap_status_msg = "SNAP MIC: Starting..."
  self.snap_flash_text = nil
  self.snap_flash_timer = 0
  core.redraw = true

  core.add_thread(function()
    local ok_json, json = pcall(require, "plugins.lsp.json")
    local line_acc = ""
    while self.snap_active and self.snap_session_id == session_id and self.snap_proc == proc and proc:running() do
      local chunk = proc:read_stdout(4096)
      if chunk and #chunk > 0 then
        line_acc = line_acc .. chunk
        while line_acc:find("\n") do
          local line, rest = line_acc:match("^(.-)\r?\n(.*)$")
          line_acc = rest or ""
          if line and #line > 3 then
            local evt = nil
            if ok_json and json and json.decode then
              local p_ok, decoded = pcall(json.decode, line)
              if p_ok and type(decoded) == "table" then
                evt = decoded
              end
            end
            if not evt then
              local ev_name = line:match('"event"%s*:%s*"([^"]+)"')
              if ev_name then
                evt = {
                  event = ev_name,
                  action = line:match('"action"%s*:%s*"([^"]+)"'),
                  message = line:match('"message"%s*:%s*"([^"]+)"'),
                  sensitivity = line:match('"sensitivity"%s*:%s*"([^"]+)"'),
                  ml = (line:match('"ml"%s*:%s*true') ~= nil),
                }
              end
            end
            if evt then
              self:_handle_snap_event(evt)
            end
          end
        end
      end
      coroutine.yield(0.04)
    end
    -- Drain final stderr if Python exited unexpectedly while still active
    if self.snap_active and self.snap_session_id == session_id then
      local err_out = proc:read_stderr(4096)
      if err_out and #err_out > 0 then
        core.error("[Snap] %s", err_out:match("^%s*(.-)%s*$"))
      end
      self:stop_snap_detector(true)
    end
  end)
end

function PptxView:stop_snap_detector(silent)
  if not self.snap_active and not self.snap_proc then return end
  self.snap_session_id = (self.snap_session_id or 0) + 1
  self.snap_active = false
  self.snap_ready = false
  self.snap_status_msg = nil
  self.snap_flash_text = nil
  self.snap_flash_timer = 0
  if self.snap_proc then
    local p = self.snap_proc
    self.snap_proc = nil
    pcall(function() p:write("STOP\n") end)
    pcall(function() p:kill() end)
  end
  if not silent then
    core.log("[Snap] Microphone snap control deactivated.")
  end
  core.redraw = true
end

function PptxView:toggle_snap_control()
  if not self.slideshow_mode then
    core.log("[Snap] Enter Fullscreen Slideshow (F5) first to enable snap navigation.")
    return
  end
  if self.snap_active then
    self:stop_snap_detector(false)
  else
    self:start_snap_detector()
  end
end

function PptxView:cycle_snap_sensitivity()
  if not config.plugins or not config.plugins.pptx then return end
  local order = { "normal", "low", "high" }
  local cur = tostring(config.plugins.pptx.snap_sensitivity or "normal")
  local next_sens = "normal"
  for i, s in ipairs(order) do
    if s == cur then
      next_sens = order[(i % #order) + 1]
      break
    end
  end
  config.plugins.pptx.snap_sensitivity = next_sens
  local labels = { normal = "NORMAL (Balanced)", low = "LOW (Strict Noisy Room)", high = "HIGH (Far Presenter)" }
  core.log("[Snap] Sensitivity set to %s", labels[next_sens] or next_sens)
  if self.slideshow_mode and self.snap_active then
    self:stop_snap_detector(true)
    self:start_snap_detector()
  elseif self.slideshow_mode then
    self.snap_flash_text = "SNAP SENSITIVITY: " .. (labels[next_sens] or next_sens)
    self.snap_flash_timer = 1.4
  end
  core.redraw = true
end

function PptxView:toggle_blank_screen(mode)
  mode = mode or "black"
  if self.blank_screen == mode then
    self.blank_screen = nil
  else
    self.blank_screen = mode
  end
  core.redraw = true
end

function PptxView:toggle_notes()
  if self.slideshow_mode then
    self.show_slideshow_notes = not self.show_slideshow_notes
  else
    self.show_notes = not self.show_notes
  end
  core.redraw = true
end

function PptxView:toggle_thumbnails()
  if not self.slideshow_mode then
    self.show_thumbnails = not self.show_thumbnails
    core.redraw = true
  end
end

-- ============================================================================
-- VIEW UPDATE & PROCESS HANDLING
-- ============================================================================

function PptxView:update()
  PptxView.super.update(self)

  -- Update HUD auto-hide timer during slideshow
  if self.slideshow_mode and self.hud_visible and self.hud_timer > 0 then
    if not self.hovered_btn then
      self.hud_timer = self.hud_timer - 0.05
      if self.hud_timer <= 0 then
        self.hud_visible = false
        core.redraw = true
      end
    else
      self.hud_timer = 3.5
    end
  end

  -- Fade out temporary snap confirmation flash badge
  if self.snap_flash_timer and self.snap_flash_timer > 0 then
    self.snap_flash_timer = self.snap_flash_timer - 0.05
    if self.snap_flash_timer <= 0 then
      self.snap_flash_timer = 0
      self.snap_flash_text = nil
      core.redraw = true
    end
  end

  -- Process completed background tasks
  if self.active_proc then
    if not self.active_proc:running() then
      local proc_type = self.active_proc_type
      local proc_file = self.active_proc_file
      local requested_slide = self.active_slide_loading

      self.active_proc = nil
      self.active_proc_file = nil
      self.active_proc_type = nil
      self.active_slide_loading = nil

      if proc_type == "info" then
        local fn, err = loadfile(proc_file)
        if fn then
          local ok, info = pcall(fn)
          os.remove(proc_file)
          if ok and info then
            if info.error then
              self.loading = false
              self.error_msg = info.error
            else
              self.slide_count = math.max(1, info.slide_count or 1)
              self.aspect_ratio = info.aspect_ratio or 1.7778
              self.presentation_title = info.title or self.basename
              self.slides_meta = info.slides or {}
              self.name = "PPT: " .. self.presentation_title
              self:request_slide(self.slide)
            end
          else
            self.loading = false
            self.error_msg = "Failed to parse presentation metadata: " .. tostring(info)
          end
        else
          os.remove(proc_file)
          self.loading = false
          self.error_msg = "Failed to compile info cache: " .. tostring(err)
        end
        core.redraw = true

      elseif proc_type == "slide" or proc_type == "prefetch" then
        local fn, err = loadfile(proc_file)
        if fn then
          local ok, data = pcall(fn)
          os.remove(proc_file)
          if ok and data then
            if data.error then
              if proc_type == "slide" then
                self.loading = false
                self.error_msg = data.error
              end
            else
              local cache_key = requested_slide or (self.slide .. "_" .. (data.mode or self.mode))
              self.cache[cache_key] = data
              if proc_type == "slide" then
                self.loading = false
                self.error_msg = nil
                self:prefetch_next_slide()
              end
            end
          else
            if proc_type == "slide" then
              self.loading = false
              self.error_msg = "Failed to load rendered slide: " .. tostring(data)
            end
          end
        else
          os.remove(proc_file)
          if proc_type == "slide" then
            self.loading = false
            self.error_msg = "Failed to compile slide cache: " .. tostring(err)
          end
        end
        core.redraw = true

      elseif proc_type == "search" then
        local fn, err = loadfile(proc_file)
        if fn then
          local ok, data = pcall(fn)
          os.remove(proc_file)
          if ok and data then
            self.search_matches = data.matches or {}
            self.current_match_idx = 1
            self.loading = false
            if #self.search_matches > 0 then
              core.log("[PPTX] Found %d matches for '%s'. Jumping to slide %d.", #self.search_matches, self.search_query, self.search_matches[1].slide)
              self:goto_match(1)
            else
              core.log("[PPTX] No matches found for '%s'.", self.search_query)
            end
          else
            self.loading = false
          end
        else
          os.remove(proc_file)
          self.loading = false
        end
        core.redraw = true
      end
    end
  end
end

-- ============================================================================
-- DIMENSIONS & SCROLL SIZES
-- ============================================================================

function PptxView:get_slide_dimensions(slide_data, avail_w, avail_h)
  local aspect = (slide_data and slide_data.aspect_ratio) or self.aspect_ratio or 1.7778

  if self.slideshow_mode then
    local sw = avail_w
    local sh = sw / aspect
    if sh > avail_h then
      sh = avail_h
      sw = sh * aspect
    end
    return sw, sh, 1.0, 1.0
  end

  if self.mode == "hd" then
    local max_w = math.max(400, avail_w - 48 * SCALE)
    local max_h = math.max(240, avail_h - 48 * SCALE)
    local base_w = math.min(max_w, 1280 * SCALE)
    local base_h = base_w / aspect
    if base_h > max_h then
      base_h = max_h
      base_w = base_h * aspect
    end
    local sw = base_w * self.zoom
    local sh = base_h * self.zoom
    return sw, sh, 1.0, 1.0

  elseif self.mode == "browsh" then
    local char_w = math.max(6, self.font:get_width(" ")) * self.zoom
    local lh = self.font:get_height() * self.zoom
    local sw = (slide_data and slide_data.cols or 110) * char_w
    local sh = (slide_data and slide_data.rows or 35) * lh
    return sw, sh, char_w, lh

  elseif self.mode == "text" then
    local sw = math.min(avail_w - 60 * SCALE, 900 * SCALE)
    local lh = style.font:get_height() + 6 * SCALE
    local text = slide_data and slide_data.text or ""
    local lines = select(2, text:gsub("\n", "\n")) + 8
    local sh = lines * lh
    return sw, sh, 1.0, 1.0
  end

  return 960 * self.zoom, (960 / aspect) * self.zoom, 1.0, 1.0
end

function PptxView:get_scrollable_size()
  if self.slideshow_mode then
    return self.size.y
  end
  local page_data = self.cache[self.slide .. "_" .. self.mode]
  if page_data then
    local avail_w = self.size.x - (self.show_thumbnails and self.thumbnail_w or 0)
    local _, sh = self:get_slide_dimensions(page_data, avail_w, self.size.y)
    local total_h = sh + self.toolbar_h + 80 * SCALE
    if self.show_notes then
      total_h = total_h + self.notes_h
    end
    return total_h
  end
  return self.size.y
end

-- ============================================================================
-- DRAWING LOGIC: TOOLBAR, THUMBNAILS, STAGE, SLIDESHOW
-- ============================================================================

function PptxView:draw_toolbar()
  local x = self.position.x
  local y = self.position.y
  local w = self.size.x
  local h = self.toolbar_h

  local bg = style.background3 or _COLOR_BG_DARK
  local border = style.divider or _COLOR_BORDER
  renderer.draw_rect(x, y, w, h, bg)
  renderer.draw_rect(x, y + h - 1, w, 1, border)

  self.toolbar_buttons = {}
  local bx = x + 8 * SCALE
  local by = y + 5 * SCALE
  local bh = h - 10 * SCALE
  local is_compact = w < 880 * SCALE
  local is_ultra_compact = w < 660 * SCALE

  -- Right-aligned search button width reservation
  local search_lbl = self.search_query and ("Find: " .. self.search_query) or (is_compact and "🔍" or "🔍 Find")
  local search_w = style.font:get_width(search_lbl) + 16 * SCALE
  local max_btn_x = x + w - search_w - 12 * SCALE

  local function draw_btn(id, label, active, bw, accent, tooltip)
    bw = bw or (style.font:get_width(label) + 14 * SCALE)
    if bx + bw > max_btn_x then
      return false
    end

    local is_hover = (self.hovered_btn == id)
    local btn_bg = accent and (is_hover and _COLOR_ACCENT_HOVER or _COLOR_ACCENT)
                    or (active and _COLOR_ACCENT_BG
                    or (is_hover and (style.background2 or _COLOR_BORDER) or bg))
    local btn_fg = accent and _COLOR_WHITE
                    or (active and _COLOR_ACCENT
                    or (is_hover and _COLOR_TEXT or (style.dim or _COLOR_TEXT_DIM)))

    renderer.draw_rect(bx, by, bw, bh, btn_bg)
    renderer.draw_rect(bx, by, bw, bh, border)
    common.draw_text(style.font, btn_fg, label, "center", bx, by, bw, bh)

    table.insert(self.toolbar_buttons, { id = id, x = bx, y = by, w = bw, h = bh, tooltip = tooltip })
    bx = bx + bw + 4 * SCALE
    return true
  end

  local function add_separator()
    if bx + 8 * SCALE < max_btn_x then
      renderer.draw_rect(bx + 2 * SCALE, by + 4 * SCALE, 1, bh - 8 * SCALE, border)
      bx = bx + 7 * SCALE
    end
  end

  -- 1. Prominent Slideshow Launch Button
  local show_lbl = is_compact and "▶" or "▶ Slideshow"
  draw_btn("slideshow_start", show_lbl, false, nil, true, "Start Fullscreen Slideshow (F5)")
  add_separator()

  -- 2. Slide Navigation Buttons [ ◀ ] [ Slide X of Y ] [ ▶ ]
  draw_btn("prev_slide", "◀", false, 28 * SCALE, false, "Previous Slide (Left / PgUp)")
  local slide_str = is_ultra_compact and string.format("%d/%d", self.slide, self.slide_count)
                     or (is_compact and string.format("%d of %d", self.slide, self.slide_count)
                     or string.format("Slide %d of %d", self.slide, self.slide_count))
  local slide_w = style.font:get_width(slide_str) + 16 * SCALE
  draw_btn("goto_slide", slide_str, false, slide_w, false, "Go to Slide (Ctrl+G)")
  draw_btn("next_slide", "▶", false, 28 * SCALE, false, "Next Slide (Right / PgDown / Space)")
  add_separator()

  -- 3. Side Panels Toggle Buttons [ ▤ Deck ] [ ✎ Notes ]
  local deck_lbl = is_compact and "▤" or "▤ Deck"
  draw_btn("toggle_thumbnails", deck_lbl, self.show_thumbnails, nil, false, "Toggle Slide Deck Explorer (Ctrl+T)")
  local notes_lbl = is_compact and "✎" or "✎ Notes"
  draw_btn("toggle_notes", notes_lbl, self.show_notes, nil, false, "Toggle Speaker Notes (N)")
  add_separator()

  -- 4. Zoom & Fit Controls [ - ] [ 100% ] [ + ] [ ⛶ ]
  draw_btn("zoom_out", "-", false, 26 * SCALE, false, "Zoom Out (Ctrl+-)")
  local zoom_str = string.format("%d%%", math.floor(self.zoom * 100))
  draw_btn("zoom_reset", zoom_str, false, 42 * SCALE, false, "Reset Zoom to 100% (Ctrl+0)")
  draw_btn("zoom_in", "+", false, 26 * SCALE, false, "Zoom In (Ctrl++)")
  draw_btn("zoom_fit", "⛶", false, 28 * SCALE, false, "Fit Slide to Window")
  add_separator()

  -- 5. Render Modes: Segmented [ HD | Browsh | Text ]
  if not is_ultra_compact then
    draw_btn("mode_hd", "HD", self.mode == "hd", 32 * SCALE, false, "HD Vector & Native FreeType Typography Mode")
    draw_btn("mode_browsh", "Browsh", self.mode == "browsh", 52 * SCALE, false, "Browsh Half-Block Monospace Matrix Mode")
    draw_btn("mode_text", "Text", self.mode == "text", 36 * SCALE, false, "Structured Document Text Reader Mode")
    add_separator()
  end

  -- 6. Dark / Light Inversion Toggle [ ◐ ]
  draw_btn("toggle_invert", "◐", self.inverted, 28 * SCALE, false, self.inverted and "Switch to Authentic Light Slide" or "Invert to Dark Mode (Ctrl+I)")

  -- 7. Search Button (Right Aligned)
  local sx = x + w - search_w - 8 * SCALE
  local s_hover = (self.hovered_btn == "search")
  renderer.draw_rect(sx, by, search_w, bh, s_hover and (style.background2 or _COLOR_BORDER) or bg)
  renderer.draw_rect(sx, by, search_w, bh, border)
  common.draw_text(style.font, self.search_query and _COLOR_ACCENT or (s_hover and _COLOR_TEXT or style.dim), search_lbl, "center", sx, by, search_w, bh)
  table.insert(self.toolbar_buttons, { id = "search", x = sx, y = by, w = search_w, h = bh, tooltip = "Search Presentation (Ctrl+F)" })
end

function PptxView:draw_thumbnails(x, y, w, h)
  self.thumbnail_buttons = {}
  renderer.draw_rect(x, y, w, h, style.background2 or _COLOR_BG_DARK)
  renderer.draw_rect(x + w - 1, y, 1, h, style.divider or _COLOR_BORDER)

  -- Header
  local header_h = 28 * SCALE
  renderer.draw_rect(x, y, w, header_h, style.background3 or _COLOR_BG_STAGE)
  renderer.draw_rect(x, y + header_h - 1, w, 1, style.divider or _COLOR_BORDER)

  local close_w = 22 * SCALE
  local close_x = x + w - close_w - 4 * SCALE
  local title_max_w = math.max(20, w - close_w - 14 * SCALE)
  local header_title = (w >= 140 * SCALE) and ("SLIDE DECK (" .. self.slide_count .. ")") or ("DECK (" .. self.slide_count .. ")")
  if w < 100 * SCALE then header_title = tostring(self.slide_count) end

  core.push_clip_rect(x, y, title_max_w, header_h)
  common.draw_text(style.font, _COLOR_TEXT_DIM, header_title, "left", x + 10 * SCALE, y + 4 * SCALE, title_max_w, header_h)
  core.pop_clip_rect()

  -- Collapse Button [ ◂ ]
  local is_close_hover = (self.hovered_btn == "deck_close")
  renderer.draw_rect(close_x, y + 3 * SCALE, close_w, header_h - 6 * SCALE, is_close_hover and _COLOR_BORDER or (style.background2 or _COLOR_BG_DARK))
  renderer.draw_rect(close_x, y + 3 * SCALE, close_w, header_h - 6 * SCALE, style.divider or _COLOR_BORDER)
  common.draw_text(style.font, is_close_hover and _COLOR_TEXT or _COLOR_TEXT_DIM, "◂", "center", close_x, y + 3 * SCALE, close_w, header_h - 6 * SCALE)
  table.insert(self.thumbnail_buttons, {
    id = "deck_close",
    x = close_x,
    y = y + 3 * SCALE,
    w = close_w,
    h = header_h - 6 * SCALE,
    tooltip = "Collapse Slide Deck (Ctrl+T)"
  })

  core.push_clip_rect(x, y + header_h, w, h - header_h)

  local card_h = 56 * SCALE
  local card_gap = 6 * SCALE
  local cur_y = y + header_h + 8 * SCALE - self.thumbnail_scroll.y
  local card_w = w - 16 * SCALE

  for idx = 1, self.slide_count do
    local card_x = x + 8 * SCALE
    local is_active = (idx == self.slide)
    local is_hover = (self.hovered_btn == ("thumb_" .. idx))

    local meta = self.slides_meta[idx]
    local title = meta and meta.title or ("Slide " .. idx)
    local has_notes = meta and meta.has_notes

    -- Card Background & Border
    local card_bg = is_active and _COLOR_CARD_ACTIVE or (is_hover and _COLOR_BORDER or _COLOR_CARD_BG)
    local card_border = is_active and _COLOR_ACCENT or (is_hover and _COLOR_BORDER_LIGHT or _COLOR_BORDER)
    renderer.draw_rect(card_x, cur_y, card_w, card_h, card_bg)
    renderer.draw_rect(card_x, cur_y, card_w, card_h, card_border)

    if card_w < 100 * SCALE then
      -- Compact mode: Big centered slide number
      local pill_w = card_w - 12 * SCALE
      local pill_h = 24 * SCALE
      local pill_bg = is_active and _COLOR_ACCENT or _COLOR_BORDER
      local pill_fg = is_active and _COLOR_WHITE or _COLOR_TEXT
      renderer.draw_rect(card_x + 6 * SCALE, cur_y + 16 * SCALE, pill_w, pill_h, pill_bg)
      common.draw_text(style.font, pill_fg, tostring(idx), "center", card_x + 6 * SCALE, cur_y + 16 * SCALE, pill_w, pill_h)
      if has_notes then
        renderer.draw_rect(card_x + card_w - 12 * SCALE, cur_y + 6 * SCALE, 6 * SCALE, 6 * SCALE, _COLOR_WARN)
      end
    else
      -- Full card: Slide Number Pill + Title
      local pill_w = 26 * SCALE
      local pill_h = 20 * SCALE
      local pill_bg = is_active and _COLOR_ACCENT or _COLOR_BORDER
      local pill_fg = is_active and _COLOR_WHITE or _COLOR_TEXT_DIM
      renderer.draw_rect(card_x + 8 * SCALE, cur_y + 8 * SCALE, pill_w, pill_h, pill_bg)
      common.draw_text(style.font, pill_fg, tostring(idx), "center", card_x + 8 * SCALE, cur_y + 8 * SCALE, pill_w, pill_h)

      local title_fg = is_active and _COLOR_WHITE or _COLOR_TEXT
      local title_x = card_x + pill_w + 12 * SCALE
      local title_w = card_w - pill_w - 18 * SCALE

      -- Truncate title cleanly with ellipsis if wider than title_w
      local display_title = truncate_text(style.font, title, title_w)

      core.push_clip_rect(title_x, cur_y + 4 * SCALE, title_w, card_h - 8 * SCALE)
      common.draw_text(style.font, title_fg, display_title, "left", title_x, cur_y + 8 * SCALE, title_w, pill_h)

      -- Speaker Notes Indicator
      if has_notes then
        common.draw_text(style.font, _COLOR_WARN, "Notes", "left", title_x, cur_y + 30 * SCALE, title_w, 18 * SCALE)
      end
      core.pop_clip_rect()
    end

    table.insert(self.thumbnail_buttons, {
      id = "thumb_" .. idx,
      slide = idx,
      x = card_x,
      y = cur_y,
      w = card_w,
      h = card_h,
      tooltip = string.format("Slide %d: %s", idx, title)
    })

    cur_y = cur_y + card_h + card_gap
  end

  core.pop_clip_rect()
end

function PptxView:draw_notes_drawer(x, y, w, h)
  renderer.draw_rect(x, y, w, h, _COLOR_NOTES_BG)
  renderer.draw_rect(x, y, w, 1, style.divider or _COLOR_BORDER)

  local title_h = 24 * SCALE
  local meta = self.slides_meta[self.slide]
  local s_title = meta and meta.title or ("Slide " .. self.slide)
  common.draw_text(style.font, _COLOR_ACCENT, "SPEAKER NOTES - " .. s_title, "left", x + 16 * SCALE, y + 6 * SCALE, w, title_h)

  local page_data = self.cache[self.slide .. "_" .. self.mode]
  local notes_text = (page_data and page_data.notes and page_data.notes ~= "") and page_data.notes
                      or "No speaker notes recorded for this slide."

  local text_fg = (page_data and page_data.notes and page_data.notes ~= "") and _COLOR_TEXT or _COLOR_TEXT_DIM
  local ny = y + title_h + 6 * SCALE
  local font = style.font
  local lh = font:get_height() + 4 * SCALE

  core.push_clip_rect(x + 16 * SCALE, ny, w - 32 * SCALE, h - title_h - 12 * SCALE)
  for line in (notes_text .. "\n"):gmatch("(.-)\n") do
    common.draw_text(font, text_fg, line, "left", x + 16 * SCALE, ny, w - 32 * SCALE, lh)
    ny = ny + lh
  end
  core.pop_clip_rect()
end

function PptxView:draw_browsh_slide(page_data, cx, cy, pw, ph)
  local cols = page_data.cols or 110
  local rows = page_data.rows or 35
  local raw_bg = page_data.bg or _COLOR_WHITE
  local page_bg = invert_color(raw_bg, self.inverted)
  local font = self.font
  local char_w = pw / cols
  local lh = ph / rows

  renderer.draw_rect(cx - 6 * SCALE, cy - 6 * SCALE, pw + 12 * SCALE, ph + 12 * SCALE, _COLOR_SHADOW)
  renderer.draw_rect(cx - 1, cy - 1, pw + 2, ph + 2, style.divider or _COLOR_BORDER)
  renderer.draw_rect(cx, cy, pw, ph, page_bg)

  local view_top = self.slideshow_mode and 0 or (self.position.y + self.toolbar_h)
  local view_bot = self.slideshow_mode and select(2, system.get_window_size()) or (self.position.y + self.size.y)

  local text_lines = page_data.text_lines or {}
  for _, line in ipairs(text_lines) do
    local r = line[1]
    local col = line[2]
    local str = line[3]
    local raw_fg = line[4] or _COLOR_TEXT
    local fg = invert_color(raw_fg, self.inverted)

    local ry = cy + r * lh
    if ry + lh >= view_top and ry <= view_bot then
      local rx = cx + col * char_w
      renderer.draw_text(font, str, rx, ry, fg)
    end
  end
end

-- ============================================================================
-- HIGH FIDELITY VECTOR & NATIVE FREETYPE TYPOGRAPHY SLIDE RENDERING
-- ============================================================================

function PptxView:draw_hd_slide(page_data, cx, cy, pw, ph)
  local raw_bg = page_data.bg or _COLOR_WHITE
  local page_bg = invert_color(raw_bg, self.inverted)

  -- Stage Drop Shadow & Presentation Card Border
  if not self.slideshow_mode then
    renderer.draw_rect(cx - 8 * SCALE, cy - 8 * SCALE, pw + 16 * SCALE, ph + 16 * SCALE, _COLOR_SHADOW)
    renderer.draw_rect(cx - 1, cy - 1, pw + 2, ph + 2, style.divider or _COLOR_BORDER)
  end
  renderer.draw_rect(cx, cy, pw, ph, page_bg)

  local view_top = self.slideshow_mode and 0 or (self.position.y + self.toolbar_h)
  local view_bot = self.slideshow_mode and select(2, system.get_window_size()) or (self.position.y + self.size.y)

  local function draw_shape_layer(s)
    local sx = cx + s.x * pw
    local sy = cy + s.y * ph
    local sw = s.w * pw
    local sh = s.h * ph
    if sy + sh >= view_top and sy <= view_bot then
      if s.fill then
        local fill_col = invert_color(s.fill, self.inverted)
        renderer.draw_rect(sx, sy, sw, sh, fill_col)
      end
      if s.border then
        local border_col = invert_color(s.border, self.inverted)
        local bw = math.max(1, math.floor((s.border_w or 1) * SCALE))
        renderer.draw_rect(sx, sy, sw, bw, border_col)
        renderer.draw_rect(sx, sy + sh - bw, sw, bw, border_col)
        renderer.draw_rect(sx, sy, bw, sh, border_col)
        renderer.draw_rect(sx + sw - bw, sy, bw, sh, border_col)
      end
    end
  end

  local function draw_image_layer(img)
    local ix = cx + img.x * pw
    local iy = cy + img.y * ph
    local iw = img.w * pw
    local ih = img.h * ph
    local scale_x = iw / math.max(1, img.tw)
    local scale_y = ih / math.max(1, img.th)
    if iy + ih >= view_top and iy <= view_bot then
      local spans = img.spans or {}
      for _, sp in ipairs(spans) do
        local px1 = math.floor(ix + sp[1] * scale_x + 0.5)
        local px2 = math.floor(ix + (sp[1] + sp[3]) * scale_x + 0.5)
        local py1 = math.floor(iy + sp[2] * scale_y + 0.5)
        local py2 = math.floor(iy + (sp[2] + (sp[4] or 1)) * scale_y + 0.5)
        local pw_sp = math.max(1, px2 - px1)
        local ph_sp = math.max(1, py2 - py1)
        local alpha = sp[8] or 255
        if alpha >= 12 then
          local base = { sp[5], sp[6], sp[7], alpha }
          local col = invert_color(base, self.inverted)
          renderer.draw_rect(px1, py1, pw_sp, ph_sp, col)
        end
      end
    end
  end

  -- 1 & 2. Draw Unified Z-Ordered Visual Layers (or legacy shapes/images fallback)
  if page_data.layers then
    for _, lay in ipairs(page_data.layers) do
      if lay.kind == "shape" then
        draw_shape_layer(lay)
      elseif lay.kind == "image" then
        draw_image_layer(lay)
      end
    end
  else
    for _, s in ipairs(page_data.shapes or {}) do
      draw_shape_layer(s)
    end
    for _, img in ipairs(page_data.images or {}) do
      draw_image_layer(img)
    end
  end

  -- 3. Native Razor-Sharp FreeType Typography with Insets & Vertical Anchoring
  local width_pt = (page_data.width_pt and page_data.width_pt > 100) and page_data.width_pt or 720.0
  local scale_factor = pw / width_pt
  local text_blocks = page_data.text_blocks or {}

  for _, tb in ipairs(text_blocks) do
    local bx = cx + tb.x * pw
    local by = cy + tb.y * ph
    local bw = math.max(12, tb.w * pw)
    local bh = math.max(10, (tb.h or 0.1) * ph)

    local in_x = bx + (tb.ins_l or 0) * pw
    local in_y = by + (tb.ins_t or 0) * ph
    local in_w = math.max(12, bw - ((tb.ins_l or 0) + (tb.ins_r or 0)) * pw)
    local in_h = math.max(10, bh - ((tb.ins_t or 0) + (tb.ins_b or 0)) * ph)

    local paras = tb.paragraphs or {}
    local bg_lum = 0.299 * page_bg[1] + 0.587 * page_bg[2] + 0.114 * page_bg[3]
    local laid_out = {}
    local total_h = 0

    for p_idx, p in ipairs(paras) do
      local p_text = p.text or ""
      if p_text == "" then
        local gap_h = 12 * scale_factor
        table.insert(laid_out, { kind = "gap", h = gap_h })
        total_h = total_h + gap_h
      else
        if p.spc_b and p.spc_b > 0 and p_idx > 1 then
          local bh_spc = p.spc_b * scale_factor
          table.insert(laid_out, { kind = "gap", h = bh_spc })
          total_h = total_h + bh_spc
        end

        local font = get_slide_font(p.size or 18, p.bold, scale_factor, p.font, p.italic)
        local raw_fg = p.color or (bg_lum > 128 and { 20, 24, 30 } or { 245, 245, 248 })
        local fg = invert_color(raw_fg, self.inverted)
        local indent = (p.level or 0) * 18 * scale_factor
        local text_x = in_x + indent
        local max_line_w = math.max(12, in_w - indent)
        local lh = font:get_height() + math.max(2, math.floor((p.size or 18) * scale_factor * 0.20))

        local runs = p.runs
        if runs and #runs > 1 then
          local tokens = {}
          local space_w = font:get_width(" ")
          for _, r in ipairs(runs) do
            local r_text = r.text or ""
            local r_font = get_slide_font(r.size or p.size or 18, r.bold, scale_factor, r.font or p.font, r.italic)
            local r_fg = invert_color(r.color or raw_fg, self.inverted)
            for seg, br in (r_text .. "\n"):gmatch("([^\n]*)\n()") do
              local lead_ws, rest_seg = seg:match("^(%s*)(.*)$")
              local pending_lead = (#lead_ws > 0) and (#lead_ws * space_w * 0.85) or 0
              if rest_seg == "" and pending_lead > 0 and #tokens > 0 then
                tokens[#tokens].trail_px = (tokens[#tokens].trail_px or 0) + pending_lead
                pending_lead = 0
              else
                for word, trail_ws in rest_seg:gmatch("(%S+)(%s*)") do
                  local trail_px = (#trail_ws > 0) and (#trail_ws * space_w * 0.85) or 0
                  table.insert(tokens, {
                    text = word,
                    lead_px = pending_lead,
                    trail_px = trail_px,
                    font = r_font,
                    color = r_fg,
                    w = r_font:get_width(word)
                  })
                  pending_lead = 0
                end
              end
              if br <= #r_text then
                table.insert(tokens, { newline = true })
              end
            end
          end

          local cur_line = {}
          local cur_line_w = 0

          for _, tok in ipairs(tokens) do
            if tok.newline then
              table.insert(laid_out, { kind = "rich", items = cur_line, w = cur_line_w, x = text_x, bw = in_w, align = p.align, h = lh })
              total_h = total_h + lh
              cur_line = {}
              cur_line_w = 0
            else
              local prev_trail = (#cur_line > 0) and (cur_line[#cur_line].trail_px or 0) or 0
              local gap_px = (#cur_line > 0) and (prev_trail + (tok.lead_px or 0)) or 0
              if cur_line_w + gap_px + tok.w > max_line_w and #cur_line > 0 then
                table.insert(laid_out, { kind = "rich", items = cur_line, w = cur_line_w, x = text_x, bw = in_w, align = p.align, h = lh })
                total_h = total_h + lh
                cur_line = { tok }
                cur_line_w = tok.w
              else
                tok._gap_before = gap_px
                table.insert(cur_line, tok)
                cur_line_w = cur_line_w + gap_px + tok.w
              end
            end
          end
          if #cur_line > 0 then
            table.insert(laid_out, { kind = "rich", items = cur_line, w = cur_line_w, x = text_x, bw = in_w, align = p.align, h = lh })
            total_h = total_h + lh
          end
        else
          for subline in (p_text .. "\n"):gmatch("(.-)\n") do
            local words = {}
            for w_word in subline:gmatch("%S+") do
              table.insert(words, w_word)
            end
            if #words == 0 and p_text:find("\n") then
              table.insert(laid_out, { kind = "gap", h = lh * 0.6 })
              total_h = total_h + lh * 0.6
            else
              local cur_line = {}
              for _, w_word in ipairs(words) do
                table.insert(cur_line, w_word)
                local test_str = table.concat(cur_line, " ")
                if font:get_width(test_str) > max_line_w and #cur_line > 1 then
                  table.remove(cur_line)
                  local lstr = table.concat(cur_line, " ")
                  table.insert(laid_out, { kind = "line", text = lstr, font = font, color = fg, x = text_x, in_x = in_x, bw = in_w, align = p.align, h = lh })
                  total_h = total_h + lh
                  cur_line = { w_word }
                end
              end
              if #cur_line > 0 then
                local lstr = table.concat(cur_line, " ")
                table.insert(laid_out, { kind = "line", text = lstr, font = font, color = fg, x = text_x, in_x = in_x, bw = in_w, align = p.align, h = lh })
                total_h = total_h + lh
              end
            end
          end
        end

        if p_idx < #paras then
          local para_gap = (p.spc_a ~= nil) and (p.spc_a * scale_factor) or math.max(3, math.floor((p.size or 18) * scale_factor * 0.25))
          if para_gap > 0 then
            table.insert(laid_out, { kind = "gap", h = para_gap })
            total_h = total_h + para_gap
          end
        end
      end
    end

    local cur_y = in_y
    if tb.anchor == "b" then
      cur_y = in_y + math.max(0, in_h - total_h)
    elseif tb.anchor == "ctr" then
      cur_y = in_y + (in_h - total_h) / 2
    end

    for _, item in ipairs(laid_out) do
      if item.kind == "gap" then
        cur_y = cur_y + item.h
      elseif item.kind == "line" then
        if cur_y + item.h >= view_top and cur_y <= view_bot then
          local draw_x = item.x
          if item.align == "center" then
            draw_x = (item.in_x or item.x) + math.max(0, (item.bw - item.font:get_width(item.text)) / 2)
          elseif item.align == "right" then
            draw_x = (item.in_x or item.x) + math.max(0, item.bw - item.font:get_width(item.text))
          end
          renderer.draw_text(item.font, item.text, math.floor(draw_x + 0.5), math.floor(cur_y + 0.5), item.color)
        end
        cur_y = cur_y + item.h
      elseif item.kind == "rich" then
        if cur_y + item.h >= view_top and cur_y <= view_bot then
          local draw_x = item.x
          if item.align == "center" then
            draw_x = in_x + math.max(0, (item.bw - item.w) / 2)
          elseif item.align == "right" then
            draw_x = in_x + math.max(0, item.bw - item.w)
          end
          local cur_x = draw_x
          local draw_y = math.floor(cur_y + 0.5)
          for ti, tok in ipairs(item.items) do
            if ti > 1 then
              cur_x = cur_x + (tok._gap_before or 0)
            end
            renderer.draw_text(tok.font, tok.text, math.floor(cur_x + 0.5), draw_y, tok.color)
            cur_x = cur_x + tok.w
          end
        end
        cur_y = cur_y + item.h
      end
    end
  end
end

function PptxView:draw_text_slide(page_data, cx, cy, pw, ph)
  local font = style.font
  local lh = font:get_height() + 6 * SCALE
  local text = page_data.text or ""

  local doc_bg = self.inverted and _COLOR_BG_DARK or _COLOR_WHITE
  local text_fg = self.inverted and _COLOR_TEXT or _COLOR_BLACK
  local num_fg = style.dim or _COLOR_TEXT_DIM

  renderer.draw_rect(cx - 10 * SCALE, cy, pw + 20 * SCALE, ph, doc_bg)
  renderer.draw_rect(cx - 10 * SCALE, cy, pw + 20 * SCALE, 1, style.divider or _COLOR_BORDER)

  local y = cy + 20 * SCALE
  local view_top = self.slideshow_mode and 0 or (self.position.y + self.toolbar_h)
  local view_bot = self.slideshow_mode and select(2, system.get_window_size()) or (self.position.y + self.size.y)

  local line_num = 1
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if y + lh >= view_top and y <= view_bot then
      local l_str = string.format("%2d", line_num)
      common.draw_text(style.font, num_fg, l_str, "left", cx, y, 40 * SCALE, lh)
      common.draw_text(style.font, text_fg, line, "left", cx + 45 * SCALE, y, pw - 50 * SCALE, lh)
    end
    y = y + lh
    line_num = line_num + 1
  end
end

-- ============================================================================
-- FULLSCREEN SLIDESHOW OVERLAYS: FLOATING HUD, SIDE ARROWS & NOTES
-- ============================================================================

function PptxView:draw_slideshow_hud(tx, ty, tw, th)
  if not self.hud_visible then
    self.hud_rect = nil
    return
  end

  local btn_defs = {
    { id = "hud_first", label = "First", active = false },
    { id = "hud_prev", label = "Previous", active = false },
    { id = "hud_indicator", label = string.format("Slide %d of %d", self.slide, self.slide_count), active = false, extra_pad = 22 },
    { id = "hud_next", label = "Next", active = false },
    { id = "hud_last", label = "Last", active = false },
    { id = "hud_notes", label = "Notes", active = self.show_slideshow_notes },
    { id = "hud_blank", label = "Blank", active = (self.blank_screen ~= nil) },
    { id = "hud_snap", label = self.snap_active and "Snap: ON" or "Snap", active = self.snap_active },
    { id = "hud_exit", label = "Exit", active = false, accent = true },
  }

  local font = style.font
  local spacing = 6 * SCALE
  local pad_x = 10 * SCALE
  local total_btn_w = 0

  for _, b in ipairs(btn_defs) do
    b.w = font:get_width(b.label) + (b.extra_pad or 16) * SCALE
    total_btn_w = total_btn_w + b.w
  end

  local hud_w = total_btn_w + (#btn_defs - 1) * spacing + pad_x * 2
  local hud_h = 44 * SCALE
  local hud_x = tx + (tw - hud_w) / 2
  local hud_y = ty + th - hud_h - 24 * SCALE

  self.hud_rect = { x = hud_x, y = hud_y, w = hud_w, h = hud_h }

  -- Frosted Floating Capsule
  renderer.draw_rect(hud_x, hud_y, hud_w, hud_h, _COLOR_BG_HUD)
  renderer.draw_rect(hud_x, hud_y, hud_w, hud_h, _COLOR_BORDER_LIGHT)

  local bx = hud_x + pad_x
  local by = hud_y + 6 * SCALE
  local bh = hud_h - 12 * SCALE

  for _, b in ipairs(btn_defs) do
    local is_hover = (self.hovered_btn == b.id)
    local btn_bg = b.accent and (is_hover and _COLOR_ACCENT_HOVER or _COLOR_ACCENT)
                    or (b.active and _COLOR_ACCENT
                    or (is_hover and _COLOR_BORDER or _COLOR_CARD_BG))
    local btn_fg = (b.accent or b.active or is_hover) and _COLOR_WHITE or _COLOR_TEXT

    renderer.draw_rect(bx, by, b.w, bh, btn_bg)
    renderer.draw_rect(bx, by, b.w, bh, _COLOR_BORDER)
    common.draw_text(font, btn_fg, b.label, "center", bx, by, b.w, bh)

    table.insert(self.hud_buttons, { id = b.id, x = bx, y = by, w = b.w, h = bh })
    bx = bx + b.w + spacing
  end
end

function PptxView:draw_slideshow_side_nav(tx, ty, tw, th)
  if not self.hud_visible then return end

  local side_btn_w = 48 * SCALE
  local side_btn_h = 72 * SCALE
  local side_btn_y = ty + (th - side_btn_h) / 2

  -- Left Previous Button
  if self.slide > 1 then
    local left_x = tx + 16 * SCALE
    local is_left_hover = (self.hovered_btn == "side_prev")
    local left_bg = is_left_hover and _COLOR_ACCENT or _COLOR_BG_HUD
    renderer.draw_rect(left_x, side_btn_y, side_btn_w, side_btn_h, left_bg)
    renderer.draw_rect(left_x, side_btn_y, side_btn_w, side_btn_h, _COLOR_BORDER_LIGHT)
    common.draw_text(style.font, _COLOR_WHITE, "<", "center", left_x, side_btn_y, side_btn_w, side_btn_h)
    table.insert(self.hud_buttons, { id = "side_prev", x = left_x, y = side_btn_y, w = side_btn_w, h = side_btn_h })
  end

  -- Right Next Button
  if self.slide < self.slide_count then
    local right_x = tx + tw - side_btn_w - 16 * SCALE
    local is_right_hover = (self.hovered_btn == "side_next")
    local right_bg = is_right_hover and _COLOR_ACCENT or _COLOR_BG_HUD
    renderer.draw_rect(right_x, side_btn_y, side_btn_w, side_btn_h, right_bg)
    renderer.draw_rect(right_x, side_btn_y, side_btn_w, side_btn_h, _COLOR_BORDER_LIGHT)
    common.draw_text(style.font, _COLOR_WHITE, ">", "center", right_x, side_btn_y, side_btn_w, side_btn_h)
    table.insert(self.hud_buttons, { id = "side_next", x = right_x, y = side_btn_y, w = side_btn_w, h = side_btn_h })
  end
end

function PptxView:draw_slideshow_notes_overlay(tx, ty, tw, th)
  if not self.show_slideshow_notes then return end

  local card_w = math.min(tw - 60 * SCALE, 740 * SCALE)
  local card_h = 170 * SCALE
  local card_x = tx + (tw - card_w) / 2
  local card_y = ty + 30 * SCALE

  renderer.draw_rect(card_x, card_y, card_w, card_h, _COLOR_NOTES_BG)
  renderer.draw_rect(card_x, card_y, card_w, card_h, _COLOR_ACCENT)

  local meta = self.slides_meta[self.slide]
  local s_title = meta and meta.title or ("Slide " .. self.slide)
  common.draw_text(style.font, _COLOR_ACCENT, "PRESENTER NOTES - " .. s_title, "left", card_x + 16 * SCALE, card_y + 10 * SCALE, card_w - 100 * SCALE, 20 * SCALE)

  -- Close Button in Header
  local close_btn_w = 64 * SCALE
  local close_btn_h = 22 * SCALE
  local close_btn_x = card_x + card_w - close_btn_w - 12 * SCALE
  local close_btn_y = card_y + 8 * SCALE
  local is_close_hover = (self.hovered_btn == "notes_close")
  renderer.draw_rect(close_btn_x, close_btn_y, close_btn_w, close_btn_h, is_close_hover and _COLOR_ACCENT or _COLOR_BORDER)
  renderer.draw_rect(close_btn_x, close_btn_y, close_btn_w, close_btn_h, _COLOR_BORDER_LIGHT)
  common.draw_text(style.font, _COLOR_WHITE, "Close", "center", close_btn_x, close_btn_y, close_btn_w, close_btn_h)
  table.insert(self.hud_buttons, { id = "notes_close", x = close_btn_x, y = close_btn_y, w = close_btn_w, h = close_btn_h })

  local page_data = self.cache[self.slide .. "_" .. self.mode]
  local notes_text = (page_data and page_data.notes and page_data.notes ~= "") and page_data.notes
                      or "No speaker notes recorded for this slide."

  local text_fg = (page_data and page_data.notes and page_data.notes ~= "") and _COLOR_WHITE or _COLOR_TEXT_DIM
  local ny = card_y + 36 * SCALE
  local font = style.font
  local lh = font:get_height() + 4 * SCALE

  core.push_clip_rect(card_x + 16 * SCALE, ny, card_w - 32 * SCALE, card_h - 44 * SCALE)
  for line in (notes_text .. "\n"):gmatch("(.-)\n") do
    common.draw_text(font, text_fg, line, "left", card_x + 16 * SCALE, ny, card_w - 32 * SCALE, lh)
    ny = ny + lh
  end
  core.pop_clip_rect()
end

-- Floating Snap Control Status / Flash Pill in Fullscreen Mode
function PptxView:draw_slideshow_snap_badge(tx, ty, tw, th)
  if not self.snap_active then return end
  local label = (self.snap_flash_timer and self.snap_flash_timer > 0 and self.snap_flash_text)
                or self.snap_status_msg
                or "SNAP MIC ON"
  local font = style.font
  local pad_x = 12 * SCALE
  local pad_y = 6 * SCALE
  local bw = font:get_width(label) + pad_x * 2
  local bh = font:get_height() + pad_y * 2
  local bx = tx + tw - bw - 18 * SCALE
  local by = ty + 16 * SCALE

  local is_flash = (self.snap_flash_timer and self.snap_flash_timer > 0 and self.snap_flash_text ~= nil)
  local bg = is_flash and _COLOR_ACCENT or _COLOR_BG_HUD
  local border = is_flash and _COLOR_WHITE or (self.snap_ready and _COLOR_ACCENT or _COLOR_WARN)
  local fg = is_flash and _COLOR_WHITE or _COLOR_TEXT

  renderer.draw_rect(bx, by, bw, bh, bg)
  renderer.draw_rect(bx, by, bw, 2, border)
  common.draw_text(font, fg, label, "center", bx, by, bw, bh)
end

-- Dedicated Fullscreen Presentation Renderer
function PptxView:draw_fullscreen(tx, ty, tw, th)
  self.hud_buttons = {}

  -- 1. True Fullscreen Stage Background
  renderer.draw_rect(tx, ty, tw, th, _COLOR_BLACK)

  -- Blank Screen Mode
  if self.blank_screen == "black" then
    renderer.draw_rect(tx, ty, tw, th, _COLOR_BLACK)
    self:draw_slideshow_hud(tx, ty, tw, th)
    self:draw_slideshow_snap_badge(tx, ty, tw, th)
    return
  elseif self.blank_screen == "white" then
    renderer.draw_rect(tx, ty, tw, th, _COLOR_WHITE)
    self:draw_slideshow_hud(tx, ty, tw, th)
    self:draw_slideshow_snap_badge(tx, ty, tw, th)
    return
  end

  local page_data = self.cache[self.slide .. "_" .. self.mode]
  if self.loading then
    local msg = self.loading_msg or "Loading slide..."
    local lh = style.font:get_height()
    common.draw_text(style.font, _COLOR_ACCENT, msg, "center", tx, ty + th / 2 - 20, tw, lh)
    core.redraw = true
  elseif self.error_msg then
    common.draw_text(style.font, _COLOR_ERROR, "Error: " .. self.error_msg, "center", tx, ty + th / 2 - 20, tw, 20)
  elseif page_data then
    -- Fit slide 100% edge-to-edge preserving aspect ratio
    local aspect = page_data.aspect_ratio or self.aspect_ratio or 1.7778
    local sw = tw
    local sh = sw / aspect
    if sh > th then
      sh = th
      sw = sh * aspect
    end
    local cx = tx + math.floor((tw - sw) / 2)
    local cy = ty + math.floor((th - sh) / 2)

    if self.mode == "browsh" then
      self:draw_browsh_slide(page_data, cx, cy, sw, sh)
    elseif self.mode == "hd" then
      self:draw_hd_slide(page_data, cx, cy, sw, sh)
    elseif self.mode == "text" then
      self:draw_text_slide(page_data, cx, cy, sw, sh)
    end
  end

  self:draw_slideshow_notes_overlay(tx, ty, tw, th)
  self:draw_slideshow_side_nav(tx, ty, tw, th)
  self:draw_slideshow_hud(tx, ty, tw, th)
  self:draw_slideshow_snap_badge(tx, ty, tw, th)
end

-- ============================================================================
-- MAIN VIEW DRAW ENTRYPOINT (DECK / EDITOR VIEW)
-- ============================================================================

function PptxView:draw()
  if self.slideshow_mode then
    local win_w, win_h = system.get_window_size()
    self:draw_fullscreen(0, 0, win_w, win_h)
    return
  end

  local tx = self.position.x
  local ty = self.position.y
  local tw = self.size.x
  local th = self.size.y

  self:draw_background(style.background or _COLOR_BG_DARK)

  local stage_x = tx
  local stage_w = tw

  if self.show_thumbnails then
    local thumb_h = th - self.toolbar_h
    self:draw_thumbnails(tx, ty + self.toolbar_h, self.thumbnail_w, thumb_h)
    stage_x = stage_x + self.thumbnail_w
    stage_w = stage_w - self.thumbnail_w
  end

  local stage_h = th - self.toolbar_h
  if self.show_notes then
    stage_h = stage_h - self.notes_h
    self:draw_notes_drawer(stage_x, ty + th - self.notes_h, stage_w, self.notes_h)
  end

  -- Presentation Stage Canvas
  core.push_clip_rect(stage_x, ty + self.toolbar_h, stage_w, stage_h)
  renderer.draw_rect(stage_x, ty + self.toolbar_h, stage_w, stage_h, _COLOR_BG_STAGE)

  local content_y = ty + self.toolbar_h + 24 * SCALE - self.scroll.y
  local page_data = self.cache[self.slide .. "_" .. self.mode]

  if self.loading then
    local msg = self.loading_msg or "Rendering slide..."
    local lh = style.font:get_height()
    local spinner_frames = { "[ | ]", "[ / ]", "[ - ]", "[ \\ ]" }
    local frame_idx = math.floor(system.get_time() * 6) % 4 + 1
    local display_text = spinner_frames[frame_idx] .. "  " .. msg
    common.draw_text(style.font, _COLOR_ACCENT, display_text, "center", stage_x, ty + stage_h / 2, stage_w, lh)
    core.redraw = true
  elseif self.error_msg then
    common.draw_text(style.font, _COLOR_ERROR, "Error: " .. self.error_msg, "center", stage_x, ty + stage_h / 2, stage_w, 20)
  elseif page_data then
    local pw, ph = self:get_slide_dimensions(page_data, stage_w, stage_h)
    local cx = math.max(stage_x + 20 * SCALE, stage_x + (stage_w - pw) / 2 - self.scroll.x)
    local stage_content_y = content_y
    if ph < stage_h - 36 * SCALE then
      stage_content_y = ty + self.toolbar_h + (stage_h - ph) / 2 - self.scroll.y
    end

    if self.mode == "browsh" then
      self:draw_browsh_slide(page_data, cx, stage_content_y, pw, ph)
    elseif self.mode == "hd" then
      self:draw_hd_slide(page_data, cx, stage_content_y, pw, ph)
    elseif self.mode == "text" then
      self:draw_text_slide(page_data, cx, stage_content_y, pw, ph)
    end
  end

  core.pop_clip_rect()

  -- Sticky Toolbar on top
  self:draw_toolbar()
  self:draw_scrollbar()

  -- Draw Divider Drag Handle Highlight
  if self.show_thumbnails and not self.slideshow_mode then
    local div_x = tx + self.thumbnail_w
    if self.hovered_divider or self.resizing_thumbnails then
      renderer.draw_rect(div_x - 1, ty + self.toolbar_h, 3 * SCALE, th - self.toolbar_h, _COLOR_ACCENT)
    end
  end

  -- Draw Floating Tooltip for hovered button
  if self.hovered_tooltip and not self.slideshow_mode then
    local font = style.font
    local tip = self.hovered_tooltip
    local tip_w = font:get_width(tip) + 16 * SCALE
    local tip_h = font:get_height() + 8 * SCALE
    local br = self.hovered_tooltip_rect or { x = tx, y = ty + self.toolbar_h, w = 30, h = 20 }
    local tip_x = math.max(tx + 8 * SCALE, math.min(tx + tw - tip_w - 8 * SCALE, br.x + (br.w - tip_w) / 2))
    local tip_y = br.y + br.h + 6 * SCALE
    if tip_y + tip_h > ty + th then
      tip_y = math.max(ty + 4 * SCALE, br.y - tip_h - 6 * SCALE)
    end

    renderer.draw_rect(tip_x - 2, tip_y - 2, tip_w + 4, tip_h + 4, _COLOR_SHADOW)
    renderer.draw_rect(tip_x, tip_y, tip_w, tip_h, _COLOR_BG_DARK)
    renderer.draw_rect(tip_x, tip_y, tip_w, tip_h, _COLOR_BORDER_LIGHT)
    common.draw_text(font, _COLOR_TEXT, tip, "center", tip_x, tip_y, tip_w, tip_h)
  end
end

-- ============================================================================
-- MOUSE & KEYBOARD INTERACTION
-- ============================================================================

function PptxView:on_mouse_moved(px, py, dx, dy)
  self.last_mouse_x = px
  self.last_mouse_y = py

  if self.slideshow_mode then
    self.hud_visible = true
    self.hud_timer = 3.5
    core.redraw = true

    self.hovered_btn = nil
    for _, btn in ipairs(self.hud_buttons) do
      if px >= btn.x - 2 and px <= btn.x + btn.w + 2 and py >= btn.y - 2 and py <= btn.y + btn.h + 2 then
        self.hovered_btn = btn.id
        break
      end
    end

    if self.hovered_btn then
      core.request_cursor("hand")
    else
      core.request_cursor("arrow")
    end
    return true
  end

  if self.resizing_thumbnails then
    local new_w = px - self.position.x
    local min_w = 70 * SCALE
    local max_w = math.max(min_w, math.floor(self.size.x * 0.6))
    self.thumbnail_w = math.max(min_w, math.min(max_w, new_w))
    if config.plugins and config.plugins.pptx then
      config.plugins.pptx.thumbnail_width = math.floor(self.thumbnail_w / SCALE)
    end
    core.request_cursor("sizeh")
    core.redraw = true
    return true
  end

  if self.dragging_canvas then
    local dy_drag = py - self.drag_start_y
    local dx_drag = px - self.drag_start_x
    self.scroll.to.y = self.drag_scroll_y - dy_drag
    self.scroll.to.x = self.drag_scroll_x - dx_drag
    self.scroll.y = self.scroll.to.y
    self.scroll.x = self.scroll.to.x
    core.redraw = true
    return true
  end

  local old_hover = self.hovered_btn
  self.hovered_btn = nil
  self.hovered_tooltip = nil
  self.hovered_tooltip_rect = nil

  -- Check divider hover
  self.hovered_divider = false
  if self.show_thumbnails and not self.slideshow_mode then
    local div_x = self.position.x + self.thumbnail_w
    if math.abs(px - div_x) <= 4 * SCALE and py >= self.position.y + self.toolbar_h then
      self.hovered_divider = true
      core.request_cursor("sizeh")
      if old_hover ~= nil then core.redraw = true end
      return true
    end
  end

  -- Check toolbar buttons
  for _, btn in ipairs(self.toolbar_buttons) do
    if px >= btn.x and px <= btn.x + btn.w and py >= btn.y and py <= btn.y + btn.h then
      self.hovered_btn = btn.id
      if btn.tooltip then
        self.hovered_tooltip = btn.tooltip
        self.hovered_tooltip_rect = { x = btn.x, y = btn.y, w = btn.w, h = btn.h }
      end
      break
    end
  end

  -- Check thumbnail buttons
  if not self.hovered_btn and self.show_thumbnails then
    for _, btn in ipairs(self.thumbnail_buttons) do
      if px >= btn.x and px <= btn.x + btn.w and py >= btn.y and py <= btn.y + btn.h then
        self.hovered_btn = btn.id
        if btn.tooltip then
          self.hovered_tooltip = btn.tooltip
          self.hovered_tooltip_rect = { x = btn.x, y = btn.y, w = btn.w, h = btn.h }
        end
        break
      end
    end
  end

  if self.hovered_divider then
    core.request_cursor("sizeh")
  elseif self.hovered_btn then
    core.request_cursor("hand")
  else
    core.request_cursor("arrow")
  end

  if old_hover ~= self.hovered_btn then
    core.redraw = true
  end
  return true
end

function PptxView:on_mouse_pressed(button, px, py, clicks)
  if self.slideshow_mode then
    -- 1. Check if click is inside floating HUD capsule
    if self.hud_visible and self.hud_rect then
      local hr = self.hud_rect
      if px >= hr.x - 4 and px <= hr.x + hr.w + 4 and py >= hr.y - 4 and py <= hr.y + hr.h + 4 then
        for _, btn in ipairs(self.hud_buttons) do
          if px >= btn.x - 3 and px <= btn.x + btn.w + 3 and py >= btn.y - 3 and py <= btn.y + btn.h + 3 then
            if btn.id == "hud_first" then self:goto_slide(1)
            elseif btn.id == "hud_prev" then self:previous_slide()
            elseif btn.id == "hud_indicator" then command.perform("pptx:goto-slide")
            elseif btn.id == "hud_next" then self:next_slide()
            elseif btn.id == "hud_last" then self:goto_slide(self.slide_count)
            elseif btn.id == "hud_notes" then self:toggle_notes()
            elseif btn.id == "hud_blank" then self:toggle_blank_screen("black")
            elseif btn.id == "hud_snap" then self:toggle_snap_control()
            elseif btn.id == "hud_exit" then self:exit_slideshow()
            end
            return true
          end
        end
        -- Clicked inside HUD capsule boundary (e.g. padding/gap): ALWAYS consume!
        -- Never fall through to slide advance!
        return true
      end
    end

    -- 2. Check on-screen side arrows (< and >) and notes overlay close button
    if self.hud_visible then
      for _, btn in ipairs(self.hud_buttons) do
        if (btn.id == "side_prev" or btn.id == "side_next" or btn.id == "notes_close") and
           px >= btn.x and px <= btn.x + btn.w and py >= btn.y and py <= btn.y + btn.h then
          if btn.id == "side_prev" then self:previous_slide()
          elseif btn.id == "side_next" then self:next_slide()
          elseif btn.id == "notes_close" then
            self.show_slideshow_notes = false
            core.redraw = true
          end
          return true
        end
      end
    end

    -- 3. If notes overlay is shown and click is inside its body, consume click
    if self.show_slideshow_notes then
      local tw, th = system.get_window_size()
      local card_w = math.min(tw - 60 * SCALE, 740 * SCALE)
      local card_h = 170 * SCALE
      local card_x = (tw - card_w) / 2
      local card_y = th - card_h - 80 * SCALE
      if px >= card_x and px <= card_x + card_w and py >= card_y and py <= card_y + card_h then
        return true
      end
    end

    -- 4. If blank screen, click resumes
    if self.blank_screen then
      self.blank_screen = nil
      core.redraw = true
      return true
    end

    -- 5. Left click advances slide, Right click goes back
    if button == "left" then
      self:next_slide()
      return true
    elseif button == "right" then
      self:previous_slide()
      return true
    end
    return true
  end

  -- Divider click for resizing slide deck
  if button == "left" and self.hovered_divider then
    if clicks == 2 then
      self.thumbnail_w = (self.thumbnail_w == 220 * SCALE) and (90 * SCALE) or (220 * SCALE)
      if config.plugins and config.plugins.pptx then
        config.plugins.pptx.thumbnail_width = math.floor(self.thumbnail_w / SCALE)
      end
      core.redraw = true
      return true
    end
    self.resizing_thumbnails = true
    return true
  end

  -- Toolbar Buttons Click
  if py <= self.position.y + self.toolbar_h then
    for _, btn in ipairs(self.toolbar_buttons) do
      if px >= btn.x and px <= btn.x + btn.w and py >= btn.y and py <= btn.y + btn.h then
        if btn.id == "slideshow_start" then self:start_slideshow()
        elseif btn.id == "prev_slide" then self:previous_slide()
        elseif btn.id == "next_slide" then self:next_slide()
        elseif btn.id == "goto_slide" then
          command.perform("pptx:goto-slide")
        elseif btn.id == "toggle_thumbnails" then self:toggle_thumbnails()
        elseif btn.id == "toggle_notes" then self:toggle_notes()
        elseif btn.id == "zoom_in" then
          self.zoom = math.min(3.0, self.zoom + 0.15)
          core.redraw = true
        elseif btn.id == "zoom_out" then
          self.zoom = math.max(0.4, self.zoom - 0.15)
          core.redraw = true
        elseif btn.id == "zoom_reset" then
          self.zoom = 1.0
          core.redraw = true
        elseif btn.id == "zoom_fit" then
          self.zoom = 1.0
          self.scroll.to.x = 0
          self.scroll.to.y = 0
          core.redraw = true
        elseif btn.id == "mode_hd" then
          self.mode = "hd"
          self:request_slide(self.slide)
        elseif btn.id == "mode_browsh" then
          self.mode = "browsh"
          self:request_slide(self.slide)
        elseif btn.id == "mode_text" then
          self.mode = "text"
          self:request_slide(self.slide)
        elseif btn.id == "toggle_invert" then
          self.inverted = not self.inverted
          core.redraw = true
        elseif btn.id == "search" then
          command.perform("pptx:find")
        end
        return true
      end
    end
    return true
  end

  -- Thumbnails Click
  if self.show_thumbnails and px <= self.position.x + self.thumbnail_w then
    for _, btn in ipairs(self.thumbnail_buttons) do
      if px >= btn.x and px <= btn.x + btn.w and py >= btn.y and py <= btn.y + btn.h then
        if btn.id == "deck_close" then
          self:toggle_thumbnails()
        else
          self:goto_slide(btn.slide)
        end
        return true
      end
    end
    return true
  end

  -- Canvas drag panning
  if button == "left" then
    self.dragging_canvas = true
    self.drag_start_x = px
    self.drag_start_y = py
    self.drag_scroll_x = self.scroll.x
    self.drag_scroll_y = self.scroll.y
    return true
  end

  return PptxView.super.on_mouse_pressed(self, button, px, py, clicks)
end

function PptxView:on_mouse_released(button, px, py)
  if self.resizing_thumbnails then
    self.resizing_thumbnails = false
    core.redraw = true
    return true
  end
  self.dragging_canvas = false
  return PptxView.super.on_mouse_released(self, button, px, py)
end

function PptxView:on_mouse_wheel(y, x)
  if self.slideshow_mode then
    if y < 0 then
      self:next_slide()
    elseif y > 0 then
      self:previous_slide()
    end
    return true
  end

  -- Mouse wheel scroll over Slide Deck thumbnails
  local px = self.last_mouse_x or 0
  if self.show_thumbnails and px >= self.position.x and px <= self.position.x + self.thumbnail_w then
    local card_h = 56 * SCALE
    local card_gap = 6 * SCALE
    local total_h = self.slide_count * (card_h + card_gap) + 40 * SCALE
    local view_h = self.size.y - self.toolbar_h
    local max_scroll = math.max(0, total_h - view_h)
    self.thumbnail_scroll.y = math.max(0, math.min(max_scroll, self.thumbnail_scroll.y - y * 60 * SCALE))
    core.redraw = true
    return true
  end

  if keymap.modkeys["ctrl"] then
    if y > 0 then
      self.zoom = math.min(3.0, self.zoom + 0.1)
    else
      self.zoom = math.max(0.4, self.zoom - 0.1)
    end
    core.redraw = true
    return true
  end

  return PptxView.super.on_mouse_wheel(self, y, x)
end

-- ============================================================================
-- GLOBAL HOOKS & FILE ASSOCIATIONS
-- ============================================================================

local function is_pptx(filename)
  if not filename then return false end
  local lower = tostring(filename):lower()
  return lower:match("%.pptx$") ~= nil or lower:match("%.ppsx$") ~= nil or lower:match("%.pptm$") ~= nil
end

local function find_existing_pptx_view(abs_fn)
  if not abs_fn then return nil end
  local norm_target = common.normalize_path(abs_fn):lower()
  if core.root_view and core.root_view.root_node then
    for _, view in ipairs(core.root_view.root_node:get_children()) do
      if type(view) == "table" and type(view.is) == "function" and view:is(PptxView) then
        local v_abs = view.abs_filename or view.filename
        if v_abs and common.normalize_path(v_abs):lower() == norm_target then
          return view
        end
      end
    end
  end
  return nil
end

local function activate_or_create_pptx_view(abs_fn, rel_fn)
  local file_path = abs_fn or rel_fn
  if not file_path or file_path == "" then return nil end
  local full_abs = system.absolute_path(common.home_expand(file_path)) or file_path

  local existing = find_existing_pptx_view(full_abs)
  if existing then
    local node = core.root_view.root_node:get_node_for_view(existing)
    if node then
      node:set_active_view(existing)
    end
    core.set_active_view(existing)
    core.redraw = true
    return existing
  end

  local node = core.root_view:get_active_node_default()
  local view = PptxView(full_abs)
  node:add_view(view)
  core.root_view.root_node:update_layout()
  core.set_active_view(view)
  core.redraw = true
  return view
end

-- Hook core.open_doc to intercept PPTX files before binary loading
local old_core_open_doc = core.open_doc
core.open_doc = function(filename)
  if filename and is_pptx(filename) then
    local abs_filename = core.project_absolute_path(core.normalize_to_project_dir(filename)) or filename
    local doc = Doc(filename, abs_filename, true)
    doc.is_pptx_proxy = true
    table.insert(core.docs, doc)
    return doc
  end
  return old_core_open_doc(filename)
end

-- Hook open_doc on RootView
local function create_open_doc_wrapper(old_fn)
  return function(self, doc)
    if not doc then return nil end
    if type(doc) == "table" and type(doc.is) == "function" and doc:is(PptxView) then
      return doc
    end
    if type(doc) == "string" and is_pptx(doc) then
      local abs_fn = core.project_absolute_path(core.normalize_to_project_dir(doc)) or doc
      return activate_or_create_pptx_view(abs_fn, doc)
    end
    if type(doc) == "table" then
      local fn = doc.filename or doc.abs_filename
      if (fn and is_pptx(fn)) or (doc.is_pptx_proxy) then
        local abs_fn = doc.abs_filename or doc.filename
        local view = activate_or_create_pptx_view(abs_fn, fn)
        for i, d in ipairs(core.docs) do
          if d == doc then
            table.remove(core.docs, i)
            break
          end
        end
        return view
      end
    end
    if old_fn then
      return old_fn(self, doc)
    end
  end
end

if RootView and RootView.open_doc then
  local old_rootview_open = RootView.open_doc
  RootView.open_doc = create_open_doc_wrapper(old_rootview_open)
end

if core.root_view and core.root_view.open_doc then
  local old_inst_open = core.root_view.open_doc
  core.root_view.open_doc = create_open_doc_wrapper(old_inst_open)
end

-- ============================================================================
-- FULLSCREEN PRESENTATION ROOTVIEW OVERRIDE
-- ============================================================================

local function is_active_pptx_slideshow()
  return core.active_view and type(core.active_view.is) == "function"
         and core.active_view:is(PptxView) and core.active_view.slideshow_mode
end

local function hook_rootview_for_slideshow()
  -- 1. Hook RootView:draw
  local old_rootview_draw = RootView.draw
  RootView.draw = function(self)
    if is_active_pptx_slideshow() then
      local win_w, win_h = system.get_window_size()
      core.active_view:draw_fullscreen(0, 0, win_w, win_h)
      return
    end
    return old_rootview_draw(self)
  end

  if core.root_view and core.root_view.draw then
    local old_inst_draw = core.root_view.draw
    core.root_view.draw = function(self)
      if is_active_pptx_slideshow() then
        local win_w, win_h = system.get_window_size()
        core.active_view:draw_fullscreen(0, 0, win_w, win_h)
        return
      end
      return old_inst_draw(self)
    end
  end

  -- 2. Hook RootView:on_mouse_pressed
  local old_rootview_mouse_pressed = RootView.on_mouse_pressed
  RootView.on_mouse_pressed = function(self, button, x, y, clicks)
    if is_active_pptx_slideshow() then
      return core.active_view:on_mouse_pressed(button, x, y, clicks)
    end
    return old_rootview_mouse_pressed(self, button, x, y, clicks)
  end

  if core.root_view and core.root_view.on_mouse_pressed then
    local old_inst_mouse_pressed = core.root_view.on_mouse_pressed
    core.root_view.on_mouse_pressed = function(self, button, x, y, clicks)
      if is_active_pptx_slideshow() then
        return core.active_view:on_mouse_pressed(button, x, y, clicks)
      end
      return old_inst_mouse_pressed(self, button, x, y, clicks)
    end
  end

  -- 3. Hook RootView:on_mouse_moved
  local old_rootview_mouse_moved = RootView.on_mouse_moved
  RootView.on_mouse_moved = function(self, x, y, dx, dy)
    if is_active_pptx_slideshow() then
      return core.active_view:on_mouse_moved(x, y, dx, dy)
    end
    return old_rootview_mouse_moved and old_rootview_mouse_moved(self, x, y, dx, dy)
  end

  if core.root_view and core.root_view.on_mouse_moved then
    local old_inst_mouse_moved = core.root_view.on_mouse_moved
    core.root_view.on_mouse_moved = function(self, x, y, dx, dy)
      if is_active_pptx_slideshow() then
        return core.active_view:on_mouse_moved(x, y, dx, dy)
      end
      return old_inst_mouse_moved and old_inst_mouse_moved(self, x, y, dx, dy)
    end
  end

  -- 4. Hook RootView:on_mouse_wheel
  local old_rootview_mouse_wheel = RootView.on_mouse_wheel
  RootView.on_mouse_wheel = function(self, y, x)
    if is_active_pptx_slideshow() then
      return core.active_view:on_mouse_wheel(y, x)
    end
    return old_rootview_mouse_wheel and old_rootview_mouse_wheel(self, y, x)
  end

  if core.root_view and core.root_view.on_mouse_wheel then
    local old_inst_mouse_wheel = core.root_view.on_mouse_wheel
    core.root_view.on_mouse_wheel = function(self, y, x)
      if is_active_pptx_slideshow() then
        return core.active_view:on_mouse_wheel(y, x)
      end
      return old_inst_mouse_wheel and old_inst_mouse_wheel(self, y, x)
    end
  end
end

hook_rootview_for_slideshow()

-- ============================================================================
-- COMMAND PALETTE & KEYBINDINGS
-- ============================================================================

local function is_pptx_active()
  return core.active_view and core.active_view:is(PptxView)
end

local function is_pptx_slideshow_active()
  return core.active_view and core.active_view:is(PptxView) and core.active_view.slideshow_mode
end

command.add(function()
  return is_pptx_slideshow_active(), core.active_view
end, {
  ["pptx:exit-slideshow"] = function(view)
    view:exit_slideshow()
  end,

  ["pptx:toggle-snap-control"] = function(view)
    view:toggle_snap_control()
  end,

  ["pptx:cycle-snap-sensitivity"] = function(view)
    view:cycle_snap_sensitivity()
  end,
})

command.add(function()
  return is_pptx_active(), core.active_view
end, {
  ["pptx:start-slideshow"] = function(view)
    view:start_slideshow()
  end,

  ["pptx:toggle-slideshow"] = function(view)
    view:toggle_slideshow()
  end,

  ["pptx:next-slide"] = function(view)
    view:next_slide()
  end,

  ["pptx:previous-slide"] = function(view)
    view:previous_slide()
  end,

  ["pptx:first-slide"] = function(view)
    view:goto_slide(1)
  end,

  ["pptx:last-slide"] = function(view)
    view:goto_slide(view.slide_count)
  end,

  ["pptx:toggle-blank-screen"] = function(view)
    view:toggle_blank_screen("black")
  end,

  ["pptx:toggle-white-screen"] = function(view)
    view:toggle_blank_screen("white")
  end,

  ["pptx:toggle-notes"] = function(view)
    view:toggle_notes()
  end,

  ["pptx:toggle-thumbnails"] = function(view)
    view:toggle_thumbnails()
  end,

  ["pptx:widen-deck"] = function(view)
    view.thumbnail_w = math.min(math.floor(view.size.x * 0.6), view.thumbnail_w + 30 * SCALE)
    if config.plugins and config.plugins.pptx then
      config.plugins.pptx.thumbnail_width = math.floor(view.thumbnail_w / SCALE)
    end
    core.redraw = true
  end,

  ["pptx:narrow-deck"] = function(view)
    view.thumbnail_w = math.max(70 * SCALE, view.thumbnail_w - 30 * SCALE)
    if config.plugins and config.plugins.pptx then
      config.plugins.pptx.thumbnail_width = math.floor(view.thumbnail_w / SCALE)
    end
    core.redraw = true
  end,

  ["pptx:reset-deck-width"] = function(view)
    view.thumbnail_w = 220 * SCALE
    if config.plugins and config.plugins.pptx then
      config.plugins.pptx.thumbnail_width = 220
    end
    core.redraw = true
  end,

  ["pptx:toggle-mode"] = function(view)
    if view.mode == "hd" then
      view.mode = "browsh"
    elseif view.mode == "browsh" then
      view.mode = "text"
    else
      view.mode = "hd"
    end
    view:request_slide(view.slide)
  end,

  ["pptx:zoom-in"] = function(view)
    view.zoom = math.min(3.0, view.zoom + 0.15)
    core.redraw = true
  end,

  ["pptx:zoom-out"] = function(view)
    view.zoom = math.max(0.4, view.zoom - 0.15)
    core.redraw = true
  end,

  ["pptx:zoom-reset"] = function(view)
    view.zoom = 1.0
    core.redraw = true
  end,

  ["pptx:goto-slide"] = function(view, target_slide)
    if type(view) == "number" then
      target_slide = view
      view = core.active_view
    end
    view = view or core.active_view
    if not view or not view.goto_slide then return end
    if target_slide then
      view:goto_slide(tonumber(target_slide))
      core.redraw = true
      return
    end
    core.command_view:enter("Go to Slide (1.." .. (view.slide_count or 1) .. ")", {
      submit = function(text)
        local num = tonumber(text)
        if num then
          view:goto_slide(num)
        end
      end
    })
  end,

  ["pptx:find"] = function(view)
    core.command_view:enter("Find in Presentation", {
      submit = function(text)
        if text and text ~= "" then
          view:search(text)
        end
      end
    })
  end,
})

-- Global Open Command for PPTX
local function collect_all_pptx_files()
  local pptx_files = {}
  local seen = {}

  local function add_file(path)
    local full = system.absolute_path(common.home_expand(path)) or path
    if not seen[full] and is_pptx(full) then
      seen[full] = true
      table.insert(pptx_files, common.home_encode(path))
    end
  end

  for dir, item in core.get_project_files() do
    if item.type == "file" and is_pptx(item.filename) then
      local path = (dir == core.project_dir and "" or dir .. PATHSEP) .. item.filename
      add_file(path)
    end
  end

  local desktop_dir = USERDIR .. PATHSEP .. "../../Desktop"
  local d_files = system.list_dir(desktop_dir) or {}
  for _, f in ipairs(d_files) do
    if is_pptx(f) then
      add_file(desktop_dir .. PATHSEP .. f)
    end
  end

  return pptx_files
end

command.add(nil, {
  ["pptx:open-file"] = function()
    local pptx_files = collect_all_pptx_files()
    core.command_view:enter("Open PowerPoint File", {
      submit = function(text, item)
        if type(item) == "table" and item.text then
          text = item.text
        elseif type(item) == "string" then
          text = item
        end
        local filename = system.absolute_path(common.home_expand(text)) or text
        local info = system.get_file_info(filename)
        if info and info.type == "dir" then
          core.command_view:set_text(text .. PATHSEP)
          return
        end
        activate_or_create_pptx_view(filename)
      end,
      suggest = function(text)
        return common.fuzzy_match(pptx_files, text, true)
      end
    })
  end,
})

-- Keybindings
keymap.add {
  ["f5"]             = "pptx:start-slideshow",
  ["shift+f5"]       = "pptx:start-slideshow",
  ["escape"]         = "pptx:exit-slideshow",
  ["space"]          = "pptx:next-slide",
  ["return"]         = "pptx:next-slide",
  ["right"]          = "pptx:next-slide",
  ["down"]           = "pptx:next-slide",
  ["pagedown"]       = "pptx:next-slide",
  ["left"]           = "pptx:previous-slide",
  ["up"]             = "pptx:previous-slide",
  ["backspace"]      = "pptx:previous-slide",
  ["pageup"]         = "pptx:previous-slide",
  ["home"]           = "pptx:first-slide",
  ["end"]            = "pptx:last-slide",
  ["b"]              = "pptx:toggle-blank-screen",
  ["w"]              = "pptx:toggle-white-screen",
  ["n"]              = "pptx:toggle-notes",
  ["m"]              = "pptx:toggle-snap-control",
  ["shift+m"]        = "pptx:cycle-snap-sensitivity",
  ["ctrl+t"]         = "pptx:toggle-thumbnails",
  ["ctrl+m"]         = "pptx:toggle-mode",
  ["ctrl+="]         = "pptx:zoom-in",
  ["ctrl++"]         = "pptx:zoom-in",
  ["ctrl+-"]         = "pptx:zoom-out",
  ["ctrl+0"]         = "pptx:zoom-reset",
  ["alt+p"]          = "pptx:open-file",
  ["ctrl+alt+p"]     = "pptx:open-file",
}

return PptxView
