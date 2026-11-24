-- mod-version:3
-- High Performance PowerPoint (PPTX) Browsh-Style Character Engine & Slideshow Viewer for Lite XL
-- Features:
-- 1. Browsh-Style Dual-Layer Sub-Pixel Character Matrix ('▀' U+2580 + True Text Stream)
-- 2. HD Vector / Raster Run-Length-Encoded GPU/SDL2 Span Acceleration with Spatial Banding
-- 3. Interactive Slideshow / Presentation Mode with On-Screen Navigation Buttons & Controls
-- 4. Slide Deck Explorer Thumbnail Strip for Instant Jump Navigation
-- 5. Blank Screen Blackboard / Whiteboard Mode with Dedicated UI Buttons
-- 6. Complete internal containment - strictly inside Lite XL (zero external browser or Office popups)

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

-- Cached colors for zero GC pressure
local _COLOR_BG_DARK       = { 16, 18, 22 }
local _COLOR_BG_STAGE      = { 24, 27, 33 }
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
  self.aspect_ratio = 1.7778 -- 16:9 standard default
  self.presentation_title = self.basename

  -- Modes & Display Controls
  self.zoom = 1.0
  self.mode = "hd" -- Default: "hd" (RLE Spans), options: "browsh", "text"
  self.inverted = false
  self.show_thumbnails = true
  self.show_notes = false
  self.slideshow_mode = false
  self.blank_screen = nil -- nil, "black", "white"
  self.show_slideshow_notes = false

  -- HUD auto-hide state for slideshow mode
  self.hud_visible = true
  self.hud_timer = 3.5

  -- Layout Sizing
  self.toolbar_h = 38 * SCALE
  self.thumbnail_w = 200 * SCALE
  self.notes_h = 130 * SCALE
  self.thumbnail_scroll = { y = 0, to = { y = 0 } }

  -- Interactive Buttons & Regions
  self.toolbar_buttons = {}
  self.thumbnail_buttons = {}
  self.hud_buttons = {}
  self.hovered_btn = nil

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

  local target_w = 1280
  if mode == "browsh" then
    target_w = 110
  elseif mode == "hd" then
    local avail_w = math.max(640, self.size.x - (self.show_thumbnails and self.thumbnail_w or 0) - 40 * SCALE)
    target_w = math.max(1280, math.min(1920, math.floor(avail_w * math.max(1.2, self.zoom * 1.2))))
  end

  local cmd = { "python", PYTHON_ENGINE, "render", self.abs_filename, tostring(slide_idx - 1), out_file, tostring(target_w), mode }
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
      local cmd = { "python", PYTHON_ENGINE, "render", self.abs_filename, tostring(next_slide - 1), out_file, "1280", self.mode }
      self.active_proc = process.start(cmd)
    end
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
-- SLIDESHOW PRESENTATION MODE TOGGLES
-- ============================================================================

function PptxView:start_slideshow()
  self.slideshow_mode = true
  self.blank_screen = nil
  self.show_slideshow_notes = false
  self.hud_visible = true
  self.hud_timer = 3.5
  core.redraw = true
  core.log("[Slideshow] Presentation started.")
end

function PptxView:exit_slideshow()
  if self.slideshow_mode then
    self.slideshow_mode = false
    self.blank_screen = nil
    self.show_slideshow_notes = false
    core.redraw = true
    core.log("[Slideshow] Returned to deck view.")
  end
end

function PptxView:toggle_slideshow()
  if self.slideshow_mode then
    self:exit_slideshow()
  else
    self:start_slideshow()
  end
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
    self.hud_timer = self.hud_timer - 0.05
    if self.hud_timer <= 0 then
      self.hud_visible = false
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
              -- Spatial banding for HD spans acceleration
              if data.mode == "hd" and data.spans then
                local band_size = 64
                data.bands = {}
                data.band_size = band_size
                for _, span in ipairs(data.spans) do
                  local y = span[2]
                  local sh = span[4]
                  local start_b = math.floor(y / band_size)
                  local end_b = math.floor((y + sh - 1) / band_size)
                  span.color = { span[5], span[6], span[7] }
                  span.inv_color = invert_color(span.color, true)
                  span.frame_id = 0
                  for b_idx = start_b, end_b do
                    local band = data.bands[b_idx]
                    if not band then
                      band = {}
                      data.bands[b_idx] = band
                    end
                    table.insert(band, span)
                  end
                end
              end

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
  local aspect = self.aspect_ratio or 1.7778

  if self.slideshow_mode then
    local sw = avail_w
    local sh = sw / aspect
    if sh > avail_h then
      sh = avail_h
      sw = sh * aspect
    end
    local scale_x = slide_data and (sw / (slide_data.w or 1280)) or 1.0
    local scale_y = slide_data and (sh / (slide_data.h or 720)) or 1.0
    return sw, sh, scale_x, scale_y
  end

  if self.mode == "hd" then
    local base_w = math.max(500, math.min(avail_w - 40 * SCALE, 1100 * SCALE))
    local base_h = base_w / aspect
    local sw = base_w * self.zoom
    local sh = base_h * self.zoom
    local scale_x = sw / (slide_data and slide_data.w or 1280)
    local scale_y = sh / (slide_data and slide_data.h or 720)
    return sw, sh, scale_x, scale_y

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
  local bx = x + 10 * SCALE
  local by = y + 5 * SCALE
  local bh = h - 10 * SCALE

  local function draw_btn(id, label, active, bw, accent)
    bw = bw or (style.font:get_width(label) + 18 * SCALE)
    local is_hover = self.hovered_btn == id

    local btn_bg = accent and (is_hover and _COLOR_ACCENT_HOVER or _COLOR_ACCENT)
                    or (active and _COLOR_ACCENT_BG
                    or (is_hover and (style.background2 or _COLOR_BORDER) or bg))
    local btn_fg = accent and _COLOR_WHITE
                    or (active and _COLOR_ACCENT
                    or (is_hover and _COLOR_TEXT or (style.dim or _COLOR_TEXT_DIM)))

    renderer.draw_rect(bx, by, bw, bh, btn_bg)
    renderer.draw_rect(bx, by, bw, bh, border)
    common.draw_text(style.font, btn_fg, label, "center", bx, by, bw, bh)

    table.insert(self.toolbar_buttons, { id = id, x = bx, y = by, w = bw, h = bh })
    bx = bx + bw + 6 * SCALE
  end

  -- 1. Prominent Slideshow Launch Button
  draw_btn("slideshow_start", "Start Slideshow", false, nil, true)
  bx = bx + 6 * SCALE

  -- 2. Slide Navigation Buttons
  draw_btn("prev_slide", "Previous", false)
  local slide_str = string.format("Slide %d of %d", self.slide, self.slide_count)
  local slide_w = style.font:get_width(slide_str) + 18 * SCALE
  draw_btn("goto_slide", slide_str, false, slide_w)
  draw_btn("next_slide", "Next", false)
  bx = bx + 8 * SCALE

  -- 3. Side & Bottom Panels
  draw_btn("toggle_thumbnails", "Thumbnails", self.show_thumbnails)
  draw_btn("toggle_notes", "Speaker Notes", self.show_notes)
  bx = bx + 8 * SCALE

  -- 4. Zoom & Fit Controls
  draw_btn("zoom_out", "Zoom -", false)
  local zoom_str = string.format("%d%%", math.floor(self.zoom * 100))
  draw_btn("zoom_reset", zoom_str, false, 48 * SCALE)
  draw_btn("zoom_in", "Zoom +", false)
  draw_btn("zoom_fit", "Fit Slide", false)
  bx = bx + 8 * SCALE

  -- 5. Render Modes
  draw_btn("mode_hd", "HD Spans", self.mode == "hd")
  draw_btn("mode_browsh", "Browsh", self.mode == "browsh")
  draw_btn("mode_text", "Text", self.mode == "text")
  draw_btn("toggle_invert", self.inverted and "Dark Mode" or "Light Mode", self.inverted)

  -- 6. Search Button (Right Aligned)
  local search_lbl = self.search_query and ("Find: " .. self.search_query) or "Find"
  local sw = style.font:get_width(search_lbl) + 18 * SCALE
  local sx = x + w - sw - 12 * SCALE
  local s_hover = self.hovered_btn == "search"
  renderer.draw_rect(sx, by, sw, bh, s_hover and (style.background2 or _COLOR_BORDER) or bg)
  renderer.draw_rect(sx, by, sw, bh, border)
  common.draw_text(style.font, self.search_query and _COLOR_ACCENT or style.dim, search_lbl, "center", sx, by, sw, bh)
  table.insert(self.toolbar_buttons, { id = "search", x = sx, y = by, w = sw, h = bh })
end

function PptxView:draw_thumbnails(x, y, w, h)
  renderer.draw_rect(x, y, w, h, style.background2 or _COLOR_BG_DARK)
  renderer.draw_rect(x + w - 1, y, 1, h, style.divider or _COLOR_BORDER)

  -- Header
  local header_h = 28 * SCALE
  renderer.draw_rect(x, y, w, header_h, style.background3 or _COLOR_BG_STAGE)
  renderer.draw_rect(x, y + header_h - 1, w, 1, style.divider or _COLOR_BORDER)
  common.draw_text(style.font, _COLOR_TEXT_DIM, "SLIDE DECK (" .. self.slide_count .. ")", "left", x + 12 * SCALE, y + 4 * SCALE, w, header_h)

  core.push_clip_rect(x, y + header_h, w, h - header_h)

  self.thumbnail_buttons = {}
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

    -- Slide Number Pill
    local pill_w = 26 * SCALE
    local pill_h = 18 * SCALE
    local pill_bg = is_active and _COLOR_ACCENT or _COLOR_BORDER
    local pill_fg = is_active and _COLOR_WHITE or _COLOR_TEXT_DIM
    renderer.draw_rect(card_x + 8 * SCALE, cur_y + 8 * SCALE, pill_w, pill_h, pill_bg)
    common.draw_text(style.font, pill_fg, tostring(idx), "center", card_x + 8 * SCALE, cur_y + 8 * SCALE, pill_w, pill_h)

    -- Slide Title
    local title_fg = is_active and _COLOR_WHITE or _COLOR_TEXT
    local title_x = card_x + pill_w + 14 * SCALE
    local title_w = card_w - pill_w - 20 * SCALE
    common.draw_text(style.font, title_fg, title, "left", title_x, cur_y + 8 * SCALE, title_w, pill_h)

    -- Speaker Notes Indicator
    if has_notes then
      local note_str = "Notes"
      common.draw_text(style.font, _COLOR_WARN, note_str, "left", title_x, cur_y + 30 * SCALE, title_w, 18 * SCALE)
    end

    table.insert(self.thumbnail_buttons, {
      id = "thumb_" .. idx,
      slide = idx,
      x = card_x,
      y = cur_y,
      w = card_w,
      h = card_h
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

  -- Drop shadow & card border
  renderer.draw_rect(cx - 6 * SCALE, cy - 6 * SCALE, pw + 12 * SCALE, ph + 12 * SCALE, _COLOR_SHADOW)
  renderer.draw_rect(cx - 1, cy - 1, pw + 2, ph + 2, style.divider or _COLOR_BORDER)
  renderer.draw_rect(cx, cy, pw, ph, page_bg)

  local view_top = self.position.y + (self.slideshow_mode and 0 or self.toolbar_h)
  local view_bot = self.position.y + self.size.y

  -- 1. Half-Block Subpixel Graphics Runs
  local graphic_runs = page_data.graphic_runs or {}
  for _, run in ipairs(graphic_runs) do
    local r = run[1]
    local c = run[2]
    local count = run[3]
    local fg = invert_color(run[4], self.inverted)
    local bg = invert_color(run[5], self.inverted)

    local ry = cy + r * lh
    if ry + lh >= view_top and ry <= view_bot then
      local rx = cx + c * char_w
      local rw = count * char_w
      renderer.draw_rect(rx, ry, rw, lh, bg)
      local blocks = string.rep(HALF_BLOCK, count)
      renderer.draw_text(font, blocks, rx, ry, fg)
    end
  end

  -- 2. Text Stream Overlay
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

function PptxView:draw_hd_slide(page_data, cx, cy, pw, ph, scale_x, scale_y)
  local raw_bg = page_data.bg or _COLOR_WHITE
  local page_bg = invert_color(raw_bg, self.inverted)

  -- Stage Drop Shadow & Presentation Card Border
  renderer.draw_rect(cx - 6 * SCALE, cy - 6 * SCALE, pw + 12 * SCALE, ph + 12 * SCALE, _COLOR_SHADOW)
  renderer.draw_rect(cx - 1, cy - 1, pw + 2, ph + 2, style.divider or _COLOR_BORDER)
  renderer.draw_rect(cx, cy, pw, ph, page_bg)

  local view_top = self.position.y + (self.slideshow_mode and 0 or self.toolbar_h)
  local view_bot = self.position.y + self.size.y

  -- Spatial-Banded 2D Span Rendering
  if page_data.bands then
    page_data.frame_id = (page_data.frame_id or 0) + 1
    local frame_id = page_data.frame_id
    local band_size = page_data.band_size or 64
    local local_top = math.max(0, (view_top - cy) / scale_y)
    local local_bot = math.min(page_data.h or 9999, (view_bot - cy) / scale_y)
    local min_band = math.max(0, math.floor(local_top / band_size))
    local max_band = math.max(min_band, math.floor(local_bot / band_size))
    local inv = self.inverted

    for b_idx = min_band, max_band do
      local band = page_data.bands[b_idx]
      if band then
        for _, span in ipairs(band) do
          if span.frame_id ~= frame_id then
            span.frame_id = frame_id
            local sx = cx + span[1] * scale_x
            local sy = cy + span[2] * scale_y
            local sw = math.max(1, math.ceil(span[3] * scale_x))
            local sh = math.max(1, math.ceil(span[4] * scale_y))

            if sy + sh >= view_top and sy <= view_bot then
              local col = inv and span.inv_color or span.color
              renderer.draw_rect(sx, sy, sw, sh, col)
            end
          end
        end
      end
    end
  else
    local spans = page_data.spans or {}
    for _, span in ipairs(spans) do
      local sx = cx + span[1] * scale_x
      local sy = cy + span[2] * scale_y
      local sw = math.max(1, math.ceil(span[3] * scale_x))
      local sh = math.max(1, math.ceil(span[4] * scale_y))

      if sy + sh >= view_top and sy <= view_bot then
        local col = invert_color({ span[5], span[6], span[7] }, self.inverted)
        renderer.draw_rect(sx, sy, sw, sh, col)
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
  local view_top = self.position.y + (self.slideshow_mode and 0 or self.toolbar_h)
  local view_bot = self.position.y + self.size.y

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
-- SLIDESHOW OVERLAYS: FLOATING HUD, SIDE NAV BUTTONS & PRESENTER NOTES
-- ============================================================================

function PptxView:draw_slideshow_hud()
  if not self.hud_visible then return end

  local tx = self.position.x
  local ty = self.position.y
  local tw = self.size.x
  local th = self.size.y

  local hud_w = 560 * SCALE
  local hud_h = 44 * SCALE
  local hud_x = tx + (tw - hud_w) / 2
  local hud_y = ty + th - hud_h - 24 * SCALE

  -- Frosted Floating Capsule
  renderer.draw_rect(hud_x, hud_y, hud_w, hud_h, _COLOR_BG_HUD)
  renderer.draw_rect(hud_x, hud_y, hud_w, hud_h, _COLOR_BORDER_LIGHT)

  self.hud_buttons = {}
  local bx = hud_x + 8 * SCALE
  local by = hud_y + 6 * SCALE
  local bh = hud_h - 12 * SCALE

  local function draw_hud_btn(id, label, active, bw, accent)
    bw = bw or (style.font:get_width(label) + 16 * SCALE)
    local is_hover = self.hovered_btn == id
    local btn_bg = accent and (is_hover and _COLOR_ACCENT_HOVER or _COLOR_ACCENT)
                    or (active and _COLOR_ACCENT
                    or (is_hover and _COLOR_BORDER or _COLOR_CARD_BG))
    local btn_fg = (accent or active or is_hover) and _COLOR_WHITE or _COLOR_TEXT

    renderer.draw_rect(bx, by, bw, bh, btn_bg)
    renderer.draw_rect(bx, by, bw, bh, _COLOR_BORDER)
    common.draw_text(style.font, btn_fg, label, "center", bx, by, bw, bh)

    table.insert(self.hud_buttons, { id = id, x = bx, y = by, w = bw, h = bh })
    bx = bx + bw + 6 * SCALE
  end

  draw_hud_btn("hud_first", "First", false)
  draw_hud_btn("hud_prev", "Previous", false)
  local slide_str = string.format("Slide %d of %d", self.slide, self.slide_count)
  local slide_w = style.font:get_width(slide_str) + 18 * SCALE
  draw_hud_btn("hud_indicator", slide_str, false, slide_w)
  draw_hud_btn("hud_next", "Next", false)
  draw_hud_btn("hud_last", "Last", false)
  draw_hud_btn("hud_notes", "Notes", self.show_slideshow_notes)
  draw_hud_btn("hud_blank", "Blank", self.blank_screen ~= nil)
  draw_hud_btn("hud_exit", "Exit", false, nil, true)
end

function PptxView:draw_slideshow_side_nav(tx, ty, tw, th)
  if not self.hud_visible then return end

  local side_btn_w = 44 * SCALE
  local side_btn_h = 68 * SCALE
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

function PptxView:draw_slideshow_notes_overlay()
  if not self.show_slideshow_notes then return end

  local tx = self.position.x
  local ty = self.position.y
  local tw = self.size.x

  local card_w = math.min(tw - 60 * SCALE, 700 * SCALE)
  local card_h = 160 * SCALE
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

-- ============================================================================
-- MAIN VIEW DRAW ENTRYPOINT
-- ============================================================================

function PptxView:draw()
  local tx = self.position.x
  local ty = self.position.y
  local tw = self.size.x
  local th = self.size.y

  if self.slideshow_mode then
    -- 1. Fullscreen Presentation Background
    renderer.draw_rect(tx, ty, tw, th, _COLOR_BLACK)

    -- Blank Screen Mode
    if self.blank_screen == "black" then
      renderer.draw_rect(tx, ty, tw, th, _COLOR_BLACK)
      self:draw_slideshow_hud()
      return
    elseif self.blank_screen == "white" then
      renderer.draw_rect(tx, ty, tw, th, _COLOR_WHITE)
      self:draw_slideshow_hud()
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
      local pw, ph, scale_x, scale_y = self:get_slide_dimensions(page_data, tw, th)
      local cx = tx + (tw - pw) / 2
      local cy = ty + (th - ph) / 2

      if self.mode == "browsh" then
        self:draw_browsh_slide(page_data, cx, cy, pw, ph)
      elseif self.mode == "hd" then
        self:draw_hd_slide(page_data, cx, cy, pw, ph, scale_x, scale_y)
      elseif self.mode == "text" then
        self:draw_text_slide(page_data, cx, cy, pw, ph)
      end
    end

    self:draw_slideshow_notes_overlay()
    self:draw_slideshow_side_nav(tx, ty, tw, th)
    self:draw_slideshow_hud()
    return
  end

  -- 2. Standard Deck / Editor View
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
    local pw, ph, scale_x, scale_y = self:get_slide_dimensions(page_data, stage_w, stage_h)
    local cx = math.max(stage_x + 20 * SCALE, stage_x + (stage_w - pw) / 2 - self.scroll.x)

    if self.mode == "browsh" then
      self:draw_browsh_slide(page_data, cx, content_y, pw, ph)
    elseif self.mode == "hd" then
      self:draw_hd_slide(page_data, cx, content_y, pw, ph, scale_x, scale_y)
    elseif self.mode == "text" then
      self:draw_text_slide(page_data, cx, content_y, pw, ph)
    end
  end

  core.pop_clip_rect()

  -- Sticky Toolbar on top
  self:draw_toolbar()
  self:draw_scrollbar()
end

-- ============================================================================
-- MOUSE & KEYBOARD INTERACTION
-- ============================================================================

function PptxView:on_mouse_moved(px, py, dx, dy)
  if self.slideshow_mode then
    self.hud_visible = true
    self.hud_timer = 3.5
    core.redraw = true

    self.hovered_btn = nil
    for _, btn in ipairs(self.hud_buttons) do
      if px >= btn.x and px <= btn.x + btn.w and py >= btn.y and py <= btn.y + btn.h then
        self.hovered_btn = btn.id
        break
      end
    end
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

  -- Check toolbar buttons
  for _, btn in ipairs(self.toolbar_buttons) do
    if px >= btn.x and px <= btn.x + btn.w and py >= btn.y and py <= btn.y + btn.h then
      self.hovered_btn = btn.id
      break
    end
  end

  -- Check thumbnail buttons
  if not self.hovered_btn and self.show_thumbnails then
    for _, btn in ipairs(self.thumbnail_buttons) do
      if px >= btn.x and px <= btn.x + btn.w and py >= btn.y and py <= btn.y + btn.h then
        self.hovered_btn = btn.id
        break
      end
    end
  end

  if old_hover ~= self.hovered_btn then
    core.redraw = true
  end
  return true
end

function PptxView:on_mouse_pressed(button, px, py, clicks)
  if self.slideshow_mode then
    -- Check HUD & on-screen buttons
    if self.hud_visible then
      for _, btn in ipairs(self.hud_buttons) do
        if px >= btn.x and px <= btn.x + btn.w and py >= btn.y and py <= btn.y + btn.h then
          if btn.id == "hud_first" then self:goto_slide(1)
          elseif btn.id == "hud_prev" or btn.id == "side_prev" then self:previous_slide()
          elseif btn.id == "hud_next" or btn.id == "side_next" then self:next_slide()
          elseif btn.id == "hud_last" then self:goto_slide(self.slide_count)
          elseif btn.id == "hud_indicator" then command.perform("pptx:goto-slide")
          elseif btn.id == "hud_notes" then self:toggle_notes()
          elseif btn.id == "hud_blank" then self:toggle_blank_screen("black")
          elseif btn.id == "hud_exit" then self:exit_slideshow()
          elseif btn.id == "notes_close" then
            self.show_slideshow_notes = false
            core.redraw = true
          end
          return true
        end
      end
    end

    -- If blank screen, click resumes
    if self.blank_screen then
      self.blank_screen = nil
      core.redraw = true
      return true
    end

    -- Left click advances slide, Right click goes back
    if button == "left" then
      self:next_slide()
      return true
    elseif button == "right" then
      self:previous_slide()
      return true
    end
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
        self:goto_slide(btn.slide)
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
-- COMMAND PALETTE & KEYBINDINGS
-- ============================================================================

local function is_pptx_active()
  return core.active_view and core.active_view:is(PptxView)
end

command.add(function()
  return is_pptx_active(), core.active_view
end, {
  ["pptx:start-slideshow"] = function(view)
    view:start_slideshow()
  end,

  ["pptx:exit-slideshow"] = function(view)
    view:exit_slideshow()
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

  ["pptx:goto-slide"] = function(view)
    core.command_view:enter("Go to Slide (1.." .. view.slide_count .. ")", {
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
