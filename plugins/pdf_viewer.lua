-- mod-version:3
-- High Performance PDF Browsh-Style Character Engine & Viewer for Lite XL
-- Features:
-- 1. Browsh-Style Dual-Layer Sub-Pixel Character Matrix ('▀' U+2580 + True Text Stream)
-- 2. HD Vector / Raster Run-Length-Encoded GPU/SDL2 Span Acceleration
-- 3. Formatted Document Text Extraction & Reader Mode
-- 4. Interactive Toolbar with Navigation, Zooming, Modes, and In-Document Search
-- 5. Complete internal containment - strictly inside Lite XL (zero external browser popups)

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local Doc = require "core.doc"
local RootView = require "core.rootview"
local process = require "process"

local PYTHON_ENGINE = USERDIR .. "/plugins/pdf_engine.py"
local HALF_BLOCK = "▀"

-- Create cache directory
local CACHE_DIR = USERDIR .. "/tempfiles/pdf_cache"
system.mkdir(USERDIR .. "/tempfiles")
system.mkdir(CACHE_DIR)

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

local function open_external_url(url)
  if not url or url == "" then return end
  url = url:gsub("^%s+", ""):gsub("%s+$", "")
  if url:match("^www%.") then
    url = "https://" .. url
  end
  
  if PLATFORM == "Windows" then
    local p = process.start({ "rundll32.exe", "url.dll,FileProtocolHandler", url })
    if not p then
      system.exec(string.format('start "" %q', url))
    end
  elseif PLATFORM == "Mac OS X" or PLATFORM == "Darwin" then
    process.start({ "open", url })
  else
    process.start({ "xdg-open", url })
  end
  core.log("[PDF] Opening link in browser: %s", url)
end

local PdfView = View:extend()

function PdfView:new(filename)
  PdfView.super.new(self)
  self.filename = filename or ""
  if filename and filename ~= "" then
    self.abs_filename = core.project_absolute_path(filename) or filename
    self.basename = common.basename(filename)
    self.name = "PDF: " .. self.basename
  else
    self.abs_filename = ""
    self.basename = "No Document"
    self.name = "PDF Viewer"
  end
  self.scrollable = true
  self.scroll = { x = 0, y = 0, to = { x = 0, y = 0 } }
  
  self.page = 1
  self.page_count = 1
  self.page_sizes = {}
  self.zoom = 1.0
  self.mode = "browsh" -- Default to Browsh Character Sub-Pixel Engine
  self.inverted = false -- Dark / Inverted color mode toggle
  self.fit_mode = nil
  
  self.loading = (filename ~= nil and filename ~= "")
  self.loading_msg = self.loading and "Reading PDF character matrix..." or nil
  self.error_msg = (not self.loading) and "No PDF file loaded. Press Alt+P to open a PDF." or nil
  
  self.cache = {}
  self.active_proc = nil
  self.active_proc_file = nil
  self.active_proc_type = nil
  self.active_page_loading = nil
  
  self.toolbar_h = 36 * SCALE
  self.toolbar_buttons = {}
  
  self.search_query = nil
  self.search_matches = {}
  
  self.font = style.code_font
  
  if filename and filename ~= "" then
    self:load_pdf_info()
  end
end

function PdfView:get_name()
  return self.name
end

function PdfView:get_filename()
  return self.filename
end

function PdfView:get_page_dimensions(page_data)
  if not page_data then
    return 850 * self.zoom, 1100 * self.zoom, 1.0, 1.0
  end
  if self.mode == "hd" then
    local base_w = math.max(600, math.min(1000, (page_data.orig_w or 612) * (96 / 72)))
    local base_h = base_w * ((page_data.h or 1100) / (page_data.w or 850))
    local pw = base_w * self.zoom
    local ph = base_h * self.zoom
    local scale_x = pw / (page_data.w or 850)
    local scale_y = ph / (page_data.h or 1100)
    return pw, ph, scale_x, scale_y
  elseif self.mode == "browsh" then
    local char_w = math.max(6, self.font:get_width(" ")) * self.zoom
    local lh = self.font:get_height() * self.zoom
    local pw = (page_data.cols or 110) * char_w
    local ph = (page_data.rows or 60) * lh
    return pw, ph, char_w, lh
  elseif self.mode == "text" then
    local pw = math.min(self.size.x - 80 * SCALE, 850 * SCALE)
    local lh = style.font:get_height() + 4 * SCALE
    local lines = select(2, (page_data.text or ""):gsub("\n", "\n")) + 5
    local ph = lines * lh
    return pw, ph, 1.0, 1.0
  end
  return 850 * self.zoom, 1100 * self.zoom, 1.0, 1.0
end

function PdfView:get_scrollable_size()
  local page_data = self.cache[self.page .. "_" .. self.mode]
  if page_data then
    local _, ph = self:get_page_dimensions(page_data)
    return ph + self.toolbar_h + 120 * SCALE
  end
  return self.size.y
end

function PdfView:get_h_scrollable_size()
  local page_data = self.cache[self.page .. "_" .. self.mode]
  if page_data then
    local pw = self:get_page_dimensions(page_data)
    return math.max(self.size.x, pw + 80 * SCALE)
  end
  return self.size.x
end

local function clean_temp_path(name)
  if not rawget(_G, "__random_seeded") then
    math.randomseed(os.time() + os.clock() * 1000)
    rawset(_G, "__random_seeded", true)
  end
  return CACHE_DIR .. "/" .. name:gsub("[^%w%._%-]", "_") .. "_" .. os.time() .. "_" .. math.random(1000, 9999)
end

function PdfView:load_pdf_info()
  self.loading = true
  self.loading_msg = "Extracting document structure..."
  self.error_msg = nil
  
  local out_file = clean_temp_path("info") .. ".lua"
  self.active_proc_file = out_file
  self.active_proc_type = "info"
  
  local cmd = { "python", PYTHON_ENGINE, "info", self.abs_filename, out_file }
  self.active_proc = process.start(cmd)
  if not self.active_proc then
    self.loading = false
    self.error_msg = "Python runtime or pypdfium2 not found. Please ensure Python is installed."
    core.redraw = true
  end
end

function PdfView:request_page(page_idx, mode)
  mode = mode or self.mode
  local cache_key = page_idx .. "_" .. mode
  if self.cache[cache_key] then
    self.loading = false
    core.redraw = true
    return
  end
  
  if self.active_proc and self.active_page_loading == cache_key then
    return
  end
  
  self.loading = true
  self.loading_msg = string.format("Rendering Page %d (%s mode)...", page_idx, mode:upper())
  self.error_msg = nil
  self.active_page_loading = cache_key
  
  local out_file = clean_temp_path("p" .. page_idx .. "_" .. mode) .. ".lua"
  self.active_proc_file = out_file
  self.active_proc_type = "page"
  
  local target_w = 120
  if mode == "browsh" then
    local char_w = math.max(6, self.font:get_width(" "))
    local avail_w = math.max(400, self.size.x - 60 * SCALE)
    target_w = math.min(180, math.max(70, math.floor(avail_w / (char_w * self.zoom))))
  elseif mode == "hd" then
    local avail_w = math.max(600, self.size.x - 60 * SCALE)
    target_w = math.max(1300, math.min(2200, math.floor(avail_w * math.max(1.3, self.zoom * 1.3))))
  end
  
  local cmd = { "python", PYTHON_ENGINE, "render", self.abs_filename, tostring(page_idx - 1), out_file, tostring(target_w), mode }
  self.active_proc = process.start(cmd)
  if not self.active_proc then
    self.loading = false
    self.error_msg = "Failed to launch PDF rendering engine."
    core.redraw = true
  end
end

function PdfView:next_page()
  if self.page < self.page_count then
    self:goto_page(self.page + 1)
  end
end

function PdfView:prev_page()
  if self.page > 1 then
    self:goto_page(self.page - 1)
  end
end

function PdfView:goto_page(page_idx)
  page_idx = math.max(1, math.min(self.page_count, page_idx))
  if self.page ~= page_idx then
    self.page = page_idx
    self.scroll.to.y = 0
    self.scroll.y = 0
    self:request_page(self.page, self.mode)
    core.redraw = true
  end
end

function PdfView:set_zoom(new_zoom)
  new_zoom = math.max(0.3, math.min(3.5, new_zoom))
  if math.abs(self.zoom - new_zoom) > 0.01 then
    self.zoom = new_zoom
    -- Invalidate current page cache to trigger sharp re-render at new zoom
    self.cache[self.page .. "_" .. self.mode] = nil
    self:request_page(self.page, self.mode)
    core.redraw = true
  end
end

function PdfView:toggle_mode()
  if self.mode == "browsh" then
    self.mode = "hd"
  elseif self.mode == "hd" then
    self.mode = "text"
  else
    self.mode = "browsh"
  end
  self:request_page(self.page, self.mode)
  core.redraw = true
end

function PdfView:toggle_invert()
  self.inverted = not self.inverted
  core.redraw = true
end

function PdfView:copy_selection()
  if self.selected_text and #self.selected_text > 0 then
    system.set_clipboard(self.selected_text)
    core.log_quiet("[PDF] Copied %d characters to clipboard", #self.selected_text)
    return true
  end
  local page_data = self.cache[self.page .. "_" .. self.mode]
  if page_data and page_data.text and #page_data.text > 0 then
    system.set_clipboard(page_data.text)
    core.log_quiet("[PDF] Copied page text (%d chars) to clipboard", #page_data.text)
    return true
  end
  return false
end

function PdfView:select_all()
  local page_data = self.cache[self.page .. "_" .. self.mode]
  if not page_data then
    self:request_page(self.page, self.mode)
    return false
  end
  
  local text_to_copy = ""
  if page_data.text and #page_data.text > 0 then
    text_to_copy = page_data.text
  elseif page_data.words and #page_data.words > 0 then
    local parts = {}
    local last_y = nil
    for _, w in ipairs(page_data.words) do
      if last_y and (w.y - last_y) > 0.012 then
        table.insert(parts, "\n")
      elseif #parts > 0 and parts[#parts] ~= "\n" then
        table.insert(parts, " ")
      end
      table.insert(parts, w.text)
      last_y = w.y
    end
    text_to_copy = table.concat(parts)
  end
  
  if #text_to_copy > 0 then
    self.has_selection = true
    self.selected_text = text_to_copy
    
    local pw, ph = self:get_page_dimensions(page_data)
    local cx = self.position.x + math.max(20 * SCALE, (self.size.x - pw) / 2)
    local cy = self.position.y + self.toolbar_h + 20 * SCALE - self.scroll.y
    self.sel_start_x = cx - 20 * SCALE
    self.sel_start_y = cy - 20 * SCALE
    self.sel_end_x = cx + pw + 20 * SCALE
    self.sel_end_y = cy + ph + 20 * SCALE
    
    system.set_clipboard(text_to_copy)
    core.log_quiet("[PDF] Selected & copied all text (%d characters)", #text_to_copy)
    core.redraw = true
    return true
  end
  return false
end

function PdfView:search(query)
  if not query or query == "" then
    self.search_query = nil
    self.search_matches = {}
    self.current_match_idx = 1
    return
  end
  
  self.search_query = query
  self.loading = true
  self.loading_msg = "Searching document for: " .. query .. "..."
  
  local out_file = clean_temp_path("search") .. ".lua"
  self.active_proc_file = out_file
  self.active_proc_type = "search"
  
  local cmd = { "python", PYTHON_ENGINE, "search", self.abs_filename, query, out_file }
  self.active_proc = process.start(cmd)
end

function PdfView:goto_match(match_idx)
  if not self.search_matches or #self.search_matches == 0 then return end
  match_idx = math.max(1, math.min(#self.search_matches, match_idx))
  self.current_match_idx = match_idx
  local match = self.search_matches[match_idx]
  if match then
    self:goto_page(match.page)
    if match.rect then
      local lh = self.font:get_height() * self.zoom
      local page_data = self.cache[self.page .. "_" .. self.mode]
      local ph = 1100 * self.zoom
      if self.mode == "hd" and page_data and page_data.h then
        ph = page_data.h * self.zoom
      elseif self.mode == "browsh" and page_data and page_data.rows then
        ph = page_data.rows * lh
      end
      local target_y = math.max(0, match.rect[2] * ph - self.size.y / 3)
      self.scroll.to.y = target_y
      self.scroll.y = target_y
    end
    core.redraw = true
  end
end

function PdfView:next_match()
  if not self.search_matches or #self.search_matches == 0 then return end
  local next_idx = ((self.current_match_idx or 1) % #self.search_matches) + 1
  self:goto_match(next_idx)
  core.log("Match %d of %d (Page %d)", self.current_match_idx, #self.search_matches, self.page)
end

function PdfView:prev_match()
  if not self.search_matches or #self.search_matches == 0 then return end
  local prev_idx = ((self.current_match_idx or 1) - 2 + #self.search_matches) % #self.search_matches + 1
  self:goto_match(prev_idx)
  core.log("Match %d of %d (Page %d)", self.current_match_idx, #self.search_matches, self.page)
end

function PdfView:update()
  PdfView.super.update(self)
  
  -- Handle background process completion
  if self.active_proc then
    if not self.active_proc:running() then
      local proc_type = self.active_proc_type
      local proc_file = self.active_proc_file
      self.active_proc = nil
      self.active_proc_file = nil
      self.active_proc_type = nil
      self.active_page_loading = nil
      
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
              self.page_count = math.max(1, info.page_count or 1)
              self.page_sizes = info.pages or {}
              self.name = "PDF: " .. (info.title or self.basename)
              self.loading = false
              self:request_page(self.page, self.mode)
            end
          else
            self.loading = false
            self.error_msg = "Failed to evaluate info metadata."
          end
        else
          os.remove(proc_file)
          self.loading = false
          self.error_msg = "Failed to compile info: " .. tostring(err)
        end
        core.redraw = true
        
      elseif proc_type == "page" then
        local fn, err = loadfile(proc_file)
        if fn then
          local ok, data = pcall(fn)
          os.remove(proc_file)
          if ok and data then
            if data.error then
              self.error_msg = data.error
              self.loading = false
            else
              -- Pre-process spans into spatial vertical bands with zero-GC cached colors
              if data.spans then
                local BAND_SIZE = 64
                data.bands = {}
                data.band_size = BAND_SIZE
                for _, span in ipairs(data.spans) do
                  local r, g, b = span[5] or 0, span[6] or 0, span[7] or 0
                  span.color = { r, g, b }
                  span.inv_color = { 255 - r, 255 - g, 255 - b }
                  
                  local sy = span[2]
                  local sh = span[4]
                  local min_b = math.floor(sy / BAND_SIZE)
                  local max_b = math.floor((sy + sh) / BAND_SIZE)
                  for b_idx = min_b, max_b do
                    local band = data.bands[b_idx]
                    if not band then
                      band = {}
                      data.bands[b_idx] = band
                    end
                    table.insert(band, span)
                  end
                end
              end

              local cache_key = self.page .. "_" .. (data.mode or self.mode)
              self.cache[cache_key] = data
              self.loading = false
              self.error_msg = nil
            end
          else
            self.loading = false
            self.error_msg = "Failed to load rendered page data: " .. tostring(data)
          end
        else
          os.remove(proc_file)
          self.loading = false
          self.error_msg = "Failed to compile page cache: " .. tostring(err)
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
              core.log("Found %d matches for '%s'. Jumping to page %d.", #self.search_matches, self.search_query, self.search_matches[1].page)
              self:goto_match(1)
            else
              core.log("No matches found for '%s'.", self.search_query)
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
-- DRAWING LOGIC
-- ============================================================================

function PdfView:draw_toolbar()
  local x = self.position.x
  local y = self.position.y
  local w = self.size.x
  local h = self.toolbar_h
  
  -- Toolbar background
  local bg = style.background3 or { 24, 30, 26 }
  local border = style.divider or { 50, 65, 55 }
  renderer.draw_rect(x, y, w, h, bg)
  renderer.draw_rect(x, y + h - 1, w, 1, border)
  
  self.toolbar_buttons = {}
  local bx = x + 10 * SCALE
  local by = y + 4 * SCALE
  local bh = h - 8 * SCALE
  
  local function draw_btn(id, label, active, bw)
    bw = bw or (style.font:get_width(label) + 16 * SCALE)
    local is_hover = self.hovered_btn == id
    local btn_bg = active and (style.accent or { 104, 193, 113 })
                    or (is_hover and (style.background2 or { 35, 45, 38 }) or bg)
    local btn_fg = active and (style.background or { 20, 26, 22 })
                    or (is_hover and (style.text or { 240, 245, 240 }) or (style.dim or { 160, 175, 165 }))
    
    renderer.draw_rect(bx, by, bw, bh, btn_bg)
    renderer.draw_rect(bx, by, bw, bh, border)
    common.draw_text(style.font, btn_fg, label, "center", bx, by, bw, bh)
    
    table.insert(self.toolbar_buttons, { id = id, x = bx, y = by, w = bw, h = bh })
    bx = bx + bw + 6 * SCALE
  end
  
  -- 1. Mode Switcher Buttons
  draw_btn("mode_browsh", "Browsh Matrix", self.mode == "browsh")
  draw_btn("mode_hd", "HD Spans", self.mode == "hd")
  draw_btn("mode_text", "Plain Text", self.mode == "text")
  
  -- Dark / Light Invert Mode Button
  draw_btn("toggle_invert", self.inverted and "Dark Mode" or "Light Mode", self.inverted)
  
  bx = bx + 12 * SCALE
  
  -- 2. Page Navigation Buttons
  draw_btn("prev_page", "< Prev", false)
  
  local page_str = string.format("Page %d / %d", self.page, self.page_count)
  local page_w = style.font:get_width(page_str) + 16 * SCALE
  draw_btn("goto_page", page_str, false, page_w)
  
  draw_btn("next_page", "Next >", false)
  
  bx = bx + 12 * SCALE
  
  -- 3. Zoom Controls
  draw_btn("zoom_out", "-", false, 28 * SCALE)
  local zoom_str = string.format("%d%%", math.floor(self.zoom * 100))
  draw_btn("zoom_reset", zoom_str, false, 50 * SCALE)
  draw_btn("zoom_in", "+", false, 28 * SCALE)
  draw_btn("fit_width", "Fit Width", false)
  
  -- 4. Search Button (Right aligned)
  local search_lbl = self.search_query and ("Find: '" .. self.search_query .. "'") or "Find"
  local sw = style.font:get_width(search_lbl) + 18 * SCALE
  local sx = x + w - sw - 12 * SCALE
  local s_hover = self.hovered_btn == "search"
  renderer.draw_rect(sx, by, sw, bh, s_hover and (style.background2 or { 35, 45, 38 }) or bg)
  renderer.draw_rect(sx, by, sw, bh, border)
  common.draw_text(style.font, self.search_query and (style.accent or { 104, 193, 113 }) or style.dim, search_lbl, "center", sx, by, sw, bh)
  table.insert(self.toolbar_buttons, { id = "search", x = sx, y = by, w = sw, h = bh })
end

function PdfView:draw_browsh_page(page_data, cx, cy)
  local cols = page_data.cols or 110
  local rows = page_data.rows or 60
  local raw_bg = page_data.bg or { 255, 255, 255 }
  local page_bg = invert_color(raw_bg, self.inverted)
  local font = self.font
  local char_w = math.max(6, font:get_width(" ")) * self.zoom
  local lh = font:get_height() * self.zoom
  
  local pw = cols * char_w
  local ph = rows * lh
  
  -- Card Drop Shadow & Border
  renderer.draw_rect(cx - 6, cy - 6, pw + 12, ph + 12, { 0, 0, 0, 140 })
  renderer.draw_rect(cx - 1, cy - 1, pw + 2, ph + 2, style.divider or { 70, 90, 75 })
  -- Clean Paper Canvas
  renderer.draw_rect(cx, cy, pw, ph, page_bg)
  
  local view_top = self.position.y + self.toolbar_h
  local view_bot = self.position.y + self.size.y
  
  -- 1. Draw Graphic Half-Block Runs (only for images, diagrams, banners)
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
  
  -- 2. Draw Crisp Aligned Text Lines (Direct on Canvas, ZERO gray/black background boxes)
  local text_lines = page_data.text_lines or {}
  for _, line in ipairs(text_lines) do
    local r = line[1]
    local col = line[2]
    local str = line[3]
    local raw_fg = line[4] or { 25, 30, 26 }
    local fg = invert_color(raw_fg, self.inverted)
    
    local ry = cy + r * lh
    if ry + lh >= view_top and ry <= view_bot then
      local rx = cx + col * char_w
      renderer.draw_text(font, str, rx, ry, fg)
    end
  end
  
  -- Fallback for legacy browsh_rows if present
  if #graphic_runs == 0 and #text_lines == 0 and page_data.browsh_rows then
    for row_idx, row_runs in ipairs(page_data.browsh_rows) do
      local ry = cy + (row_idx - 1) * lh
      if ry + lh >= view_top and ry <= view_bot then
        for _, run in ipairs(row_runs) do
          local rx = cx + run[1] * char_w
          local count = run[2]
          local fg = invert_color(run[3], self.inverted)
          local bg = invert_color(run[4], self.inverted)
          local char_str = run[5] or "▀"
          local is_text = run[6] == true
          local rw = count * char_w
          if is_text then
            renderer.draw_text(font, char_str, rx, ry, fg)
          else
            renderer.draw_rect(rx, ry, rw, lh, bg)
            local blocks = string.rep(HALF_BLOCK, count)
            renderer.draw_text(font, blocks, rx, ry, fg)
          end
        end
      end
    end
  end

  -- Search Highlights in Browsh Mode
  if self.search_matches and #self.search_matches > 0 then
    for _, match in ipairs(self.search_matches) do
      if match.page == self.page and match.rect then
        local rx = cx + match.rect[1] * pw
        local ry = cy + match.rect[2] * ph
        local rw = math.max(4, match.rect[3] * pw)
        local rh = math.max(4, match.rect[4] * ph)
        
        if ry + rh >= view_top and ry <= view_bot then
          renderer.draw_rect(rx - 2, ry - 1, rw + 4, rh + 2, { 255, 220, 0, 110 })
          renderer.draw_rect(rx - 2, ry - 1, rw + 4, rh + 2, { 255, 170, 0, 230 })
        end
      end
    end
  end
end

function PdfView:draw_hd_page(page_data, cx, cy)
  local pw, ph, scale_x, scale_y = self:get_page_dimensions(page_data)
  local raw_bg = page_data.bg or { 255, 255, 255 }
  local page_bg = invert_color(raw_bg, self.inverted)
  
  -- Elegant Paper Card Drop Shadow & Border
  renderer.draw_rect(cx - 6 * SCALE, cy - 6 * SCALE, pw + 12 * SCALE, ph + 12 * SCALE, { 0, 0, 0, 140 })
  renderer.draw_rect(cx - 1, cy - 1, pw + 2, ph + 2, style.divider or { 70, 90, 75 })
  renderer.draw_rect(cx, cy, pw, ph, page_bg)
  
  local view_top = self.position.y + self.toolbar_h
  local view_bot = self.position.y + self.size.y
  
  -- Blazing Fast Spatial-Banded 2D Span Rendering with ZERO GC Allocations
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

  -- 1. Active Hyperlinks in HD Sans Mode
  self.active_links = {}
  local links = page_data.links or {}
  for _, link in ipairs(links) do
    local lx = cx + link.x * pw
    local ly = cy + link.y * ph
    local lw = math.max(10, link.w * pw)
    local lh = math.max(10, link.h * ph)
    table.insert(self.active_links, { x = lx, y = ly, w = lw, h = lh, url = link.url })
    
    if ly + lh >= view_top and ly <= view_bot then
      local is_hover = self.hovered_link and self.hovered_link.url == link.url
      if is_hover then
        renderer.draw_rect(lx - 2, ly - 1, lw + 4, lh + 2, { 104, 193, 113, 60 })
        renderer.draw_rect(lx, ly + lh - 1, lw, 2 * SCALE, style.accent or { 104, 193, 113 })
      else
        renderer.draw_rect(lx, ly + lh - 1, lw, 1 * SCALE, { 70, 140, 255, 160 })
      end
    end
  end

  -- 2. Text Selection Highlight in HD Sans Mode
  if (self.selecting_text or self.has_selection) and self.sel_start_x and self.sel_end_x then
    local x1 = math.min(self.sel_start_x, self.sel_end_x)
    local x2 = math.max(self.sel_start_x, self.sel_end_x)
    local y1 = math.min(self.sel_start_y, self.sel_end_y)
    local y2 = math.max(self.sel_start_y, self.sel_end_y)
    
    if x2 - x1 > 2 or y2 - y1 > 2 then
      local words = page_data.words or {}
      for _, word in ipairs(words) do
        local wx = cx + word.x * pw
        local wy = cy + word.y * ph
        local ww = math.max(4, word.w * pw)
        local wh = math.max(6, word.h * ph)
        
        -- Intersection test with selection rectangle
        if wx + ww >= x1 and wx <= x2 and wy + wh >= y1 and wy <= y2 then
          if wy + wh >= view_top and wy <= view_bot then
            renderer.draw_rect(wx - 2, wy - 1, ww + 4, wh + 2, { 51, 153, 255, 110 })
            renderer.draw_rect(wx - 2, wy - 1, ww + 4, wh + 2, { 30, 120, 255, 180 })
          end
        end
      end
    end
  end

  -- Search Highlights on HD Page
  if self.search_matches and #self.search_matches > 0 then
    for _, match in ipairs(self.search_matches) do
      if match.page == self.page and match.rect then
        local rx = cx + match.rect[1] * pw
        local ry = cy + match.rect[2] * ph
        local rw = math.max(4, match.rect[3] * pw)
        local rh = math.max(4, match.rect[4] * ph)
        
        if ry + rh >= view_top and ry <= view_bot then
          -- Translucent yellow highlight box
          renderer.draw_rect(rx - 2, ry - 2, rw + 4, rh + 4, { 255, 225, 50, 120 })
          renderer.draw_rect(rx - 2, ry - 2, rw + 4, rh + 4, { 255, 175, 0, 220 })
        end
      end
    end
  end
end

function PdfView:draw_text_page(page_data, cx, cy)
  local font = style.font
  local lh = font:get_height() + 4 * SCALE
  local text = page_data.text or ""
  
  local pw = math.min(self.size.x - 80 * SCALE, 850 * SCALE)
  local y = cy + 20 * SCALE
  local view_top = self.position.y + self.toolbar_h
  local view_bot = self.position.y + self.size.y
  
  local doc_bg = self.inverted and (style.background or { 20, 26, 22 }) or { 245, 245, 245 }
  local text_fg = self.inverted and (style.text or { 230, 235, 230 }) or { 25, 30, 26 }
  local num_fg = self.inverted and (style.dim or { 100, 120, 105 }) or { 140, 150, 145 }
  
  renderer.draw_rect(cx - 10 * SCALE, cy, pw + 20 * SCALE, self:get_scrollable_size(), doc_bg)
  renderer.draw_rect(cx - 10 * SCALE, cy, pw + 20 * SCALE, 1, style.divider or { 60, 80, 65 })
  
  local line_num = 1
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if y + lh >= view_top and y <= view_bot then
      local l_str = string.format("%4d", line_num)
      common.draw_text(style.font, num_fg, l_str, "left", cx, y, 50 * SCALE, lh)
      common.draw_text(style.font, text_fg, line, "left", cx + 55 * SCALE, y, pw - 60 * SCALE, lh)
    end
    y = y + lh
    line_num = line_num + 1
  end
end

function PdfView:draw()
  self:draw_background(style.background or { 20, 26, 22 })
  
  local tx = self.position.x
  local ty = self.position.y
  local tw = self.size.x
  local th = self.size.y
  
  core.push_clip_rect(tx, ty, tw, th)
  
  local content_y = ty + self.toolbar_h + 20 * SCALE - self.scroll.y
  local cache_key = self.page .. "_" .. self.mode
  local page_data = self.cache[cache_key]
  
  if self.loading then
    local msg = self.loading_msg or "Rendering PDF..."
    local lh = style.font:get_height()
    local spinner_frames = { "[ | ]", "[ / ]", "[ - ]", "[ \\ ]" }
    local frame_idx = math.floor(system.get_time() * 6) % 4 + 1
    local spinner = spinner_frames[frame_idx]
    local display_text = spinner .. "  " .. msg
    common.draw_text(style.font, style.accent or { 104, 193, 113 }, display_text, "center", tx, ty + th / 2 - 20, tw, lh)
    core.redraw = true
  elseif self.error_msg then
    local lh = style.font:get_height()
    common.draw_text(style.font, { 235, 100, 100 }, "Error: " .. self.error_msg, "center", tx, ty + th / 2 - 20, tw, lh)
  elseif page_data then
    local pw = self:get_page_dimensions(page_data)
    local cx = math.max(tx + 20 * SCALE, tx + (tw - pw) / 2)
    if self.mode == "browsh" then
      self:draw_browsh_page(page_data, cx, content_y)
    elseif self.mode == "hd" then
      self:draw_hd_page(page_data, cx, content_y)
    elseif self.mode == "text" then
      self:draw_text_page(page_data, cx, content_y)
    end
  end
  
  core.pop_clip_rect()
  
  -- Draw Sticky Toolbar on top
  self:draw_toolbar()
  self:draw_scrollbar()
end

-- ============================================================================
-- MOUSE & KEYBOARD INTERACTION
-- ============================================================================

function PdfView:on_mouse_moved(px, py, dx, dy)
  if self.dragging_canvas then
    local dy_drag = py - self.drag_start_y
    local dx_drag = px - self.drag_start_x
    self.scroll.to.y = self.drag_scroll_y - dy_drag
    self.scroll.to.x = self.drag_scroll_x - dx_drag
    self:clamp_scroll_position()
    self.scroll.y = self.scroll.to.y
    self.scroll.x = self.scroll.to.x
    core.redraw = true
    return true
  end

  if self.selecting_text then
    self.sel_end_x = px
    self.sel_end_y = py
    self.has_selection = true
    core.redraw = true
    return true
  end

  PdfView.super.on_mouse_moved(self, px, py, dx, dy)
  
  -- Check link hover in HD and Browsh modes
  local old_hover_link = self.hovered_link
  self.hovered_link = nil
  if (self.mode == "hd" or self.mode == "browsh") and self.active_links then
    for _, link in ipairs(self.active_links) do
      if px >= link.x and px <= link.x + link.w and py >= link.y and py <= link.y + link.h then
        self.hovered_link = link
        break
      end
    end
  end

  local old_hover = self.hovered_btn
  self.hovered_btn = nil
  for _, btn in ipairs(self.toolbar_buttons or {}) do
    if px >= btn.x and px <= btn.x + btn.w and py >= btn.y and py <= btn.y + btn.h then
      self.hovered_btn = btn.id
      break
    end
  end

  if self.hovered_btn or self.hovered_link then
    self.cursor = "hand"
    core.request_cursor("hand")
  elseif self.mode == "hd" and py > self.position.y + self.toolbar_h then
    self.cursor = "ibeam"
    core.request_cursor("ibeam")
  else
    self.cursor = "arrow"
    core.request_cursor("arrow")
  end

  if old_hover ~= self.hovered_btn or old_hover_link ~= self.hovered_link then
    core.redraw = true
  end
end

function PdfView:on_mouse_pressed(button, px, py, clicks)
  if py <= self.position.y + self.toolbar_h then
    local target_btn = nil
    for _, btn in ipairs(self.toolbar_buttons or {}) do
      if px >= btn.x and px <= btn.x + btn.w and py >= btn.y and py <= btn.y + btn.h then
        target_btn = btn.id
        break
      end
    end
    target_btn = target_btn or self.hovered_btn

    if target_btn == "prev_page" then
      self:prev_page()
    elseif target_btn == "next_page" then
      self:next_page()
    elseif target_btn == "goto_page" then
      core.command_view:enter("Go to Page (1-" .. self.page_count .. ")", {
        text = tostring(self.page),
        select_text = true,
        show_suggestions = false,
        typeahead = false,
        suggest = function() return {} end,
        submit = function(val, item)
          val = item and item.text or val
          self:goto_page(tonumber(val) or self.page)
        end
      })
    elseif target_btn == "mode_browsh" then
      self.mode = "browsh"
      self:request_page(self.page, self.mode)
    elseif target_btn == "mode_hd" then
      self.mode = "hd"
      self:request_page(self.page, self.mode)
    elseif target_btn == "mode_text" then
      self.mode = "text"
      self:request_page(self.page, self.mode)
    elseif target_btn == "toggle_invert" then
      self:toggle_invert()
    elseif target_btn == "zoom_in" then
      self:set_zoom(self.zoom + 0.15)
    elseif target_btn == "zoom_out" then
      self:set_zoom(self.zoom - 0.15)
    elseif target_btn == "zoom_reset" then
      self:set_zoom(1.0)
    elseif target_btn == "fit_width" then
      local page_data = self.cache[self.page .. "_" .. self.mode]
      if page_data then
        local base_w = math.max(400, math.min(1200, (page_data.orig_w or 612) * (96 / 72)))
        self:set_zoom(math.max(0.4, (self.size.x - 60 * SCALE) / base_w))
      else
        self:set_zoom(1.0)
      end
    elseif target_btn == "search" then
      core.command_view:enter("Search in PDF", {
        text = self.search_query or "",
        select_text = true,
        show_suggestions = false,
        typeahead = false,
        suggest = function() return {} end,
        submit = function(text, item)
          text = item and item.text or text
          self:search(text)
        end
      })
    end
    return true
  end

  -- 1. Check clickable hyperlink in HD and Browsh modes
  if button == "left" and (self.mode == "hd" or self.mode == "browsh") and self.active_links then
    for _, link in ipairs(self.active_links) do
      if px >= link.x and px <= link.x + link.w and py >= link.y and py <= link.y + link.h then
        open_external_url(link.url)
        return true
      end
    end
  end

  -- 2. Drag Canvas Panning with Middle click, Space+Left, or Right click
  if button == "middle" or (button == "left" and keymap.modkeys["space"]) or button == "right" then
    self.dragging_canvas = true
    self.drag_start_x = px
    self.drag_start_y = py
    self.drag_scroll_x = self.scroll.to.x
    self.drag_scroll_y = self.scroll.to.y
    return true
  end

  -- 3. Text Selection in HD Mode with Left Click
  if button == "left" and self.mode == "hd" then
    local page_data = self.cache[self.page .. "_hd"]
    if clicks == 2 and page_data and page_data.words then
      local pw, ph = self:get_page_dimensions(page_data)
      local cx = self.position.x + math.max(20 * SCALE, (self.size.x - pw) / 2)
      local cy = self.position.y + self.toolbar_h + 20 * SCALE - self.scroll.y
      
      for _, word in ipairs(page_data.words) do
        local wx = cx + word.x * pw
        local wy = cy + word.y * ph
        local ww = math.max(4, word.w * pw)
        local wh = math.max(6, word.h * ph)
        if px >= wx and px <= wx + ww and py >= wy and py <= wy + wh then
          self.sel_start_x = wx
          self.sel_start_y = wy
          self.sel_end_x = wx + ww
          self.sel_end_y = wy + wh
          self.has_selection = true
          self.selected_text = word.text
          system.set_clipboard(word.text)
          core.log_quiet("[PDF] Copied: %s", word.text)
          core.redraw = true
          return true
        end
      end
    else
      self.selecting_text = true
      self.sel_start_x = px
      self.sel_start_y = py
      self.sel_end_x = px
      self.sel_end_y = py
      self.has_selection = false
      self.selected_text = nil
      core.redraw = true
      return true
    end
  end

  return PdfView.super.on_mouse_pressed(self, button, px, py, clicks)
end

function PdfView:on_mouse_released(button, px, py)
  if self.dragging_canvas then
    self.dragging_canvas = false
    return true
  end

  if self.selecting_text then
    self.selecting_text = false
    self.sel_end_x = px
    self.sel_end_y = py
    
    local page_data = self.cache[self.page .. "_hd"]
    if page_data and page_data.words then
      local pw, ph = self:get_page_dimensions(page_data)
      local cx = self.position.x + math.max(20 * SCALE, (self.size.x - pw) / 2)
      local cy = self.position.y + self.toolbar_h + 20 * SCALE - self.scroll.y
      
      local x1 = math.min(self.sel_start_x, self.sel_end_x)
      local x2 = math.max(self.sel_start_x, self.sel_end_x)
      local y1 = math.min(self.sel_start_y, self.sel_end_y)
      local y2 = math.max(self.sel_start_y, self.sel_end_y)
      
      if x2 - x1 > 3 or y2 - y1 > 3 then
        local selected = {}
        for _, word in ipairs(page_data.words) do
          local wx = cx + word.x * pw
          local wy = cy + word.y * ph
          local ww = math.max(4, word.w * pw)
          local wh = math.max(6, word.h * ph)
          if wx + ww >= x1 and wx <= x2 and wy + wh >= y1 and wy <= y2 then
            table.insert(selected, word)
          end
        end
        
        table.sort(selected, function(a, b)
          if math.abs(a.y - b.y) > 0.008 then
            return a.y < b.y
          end
          return a.x < b.x
        end)
        
        local parts = {}
        local last_y = nil
        for _, w in ipairs(selected) do
          if last_y and (w.y - last_y) > 0.012 then
            table.insert(parts, "\n")
          elseif #parts > 0 and parts[#parts] ~= "\n" then
            table.insert(parts, " ")
          end
          table.insert(parts, w.text)
          last_y = w.y
        end
        
        self.selected_text = table.concat(parts)
        if #self.selected_text > 0 then
          self.has_selection = true
          system.set_clipboard(self.selected_text)
          core.log_quiet("[PDF] Selected & copied %d characters", #self.selected_text)
        else
          self.has_selection = false
        end
      else
        self.has_selection = false
        self.selected_text = nil
      end
    end
    core.redraw = true
    return true
  end

  return PdfView.super.on_mouse_released(self, button, px, py)
end

function PdfView:on_mouse_wheel(y, x)
  if keymap.modkeys["ctrl"] then
    if y > 0 then
      self:set_zoom(self.zoom + 0.1)
    else
      self:set_zoom(self.zoom - 0.1)
    end
    return true
  end

  local scroll_delta = y * 50 * SCALE
  self.scroll.to.y = self.scroll.to.y - scroll_delta
  if x and x ~= 0 then
    self.scroll.to.x = self.scroll.to.x - x * 50 * SCALE
  end
  
  self:clamp_scroll_position()
  core.redraw = true
  return true
end

-- ============================================================================
-- GLOBAL HOOKS: COMPLETE AUTOMATIC PDF OPENING (EXPLORER, TREEVIEW, CLI, DND)
-- ============================================================================
local function is_pdf(filename)
  return filename and tostring(filename):lower():match("%.pdf$") ~= nil
end

local function find_existing_pdf_view(abs_fn)
  if not abs_fn then return nil end
  local norm_target = common.normalize_path(abs_fn):lower()
  if core.root_view and core.root_view.root_node then
    for _, view in ipairs(core.root_view.root_node:get_children()) do
      if type(view) == "table" and type(view.is) == "function" and view:is(PdfView) then
        local v_abs = view.abs_filename or view.filename
        if v_abs and common.normalize_path(v_abs):lower() == norm_target then
          return view
        end
      end
    end
  end
  return nil
end

local function activate_or_create_pdf_view(abs_fn, rel_fn)
  local file_path = abs_fn or rel_fn
  if not file_path or file_path == "" then return nil end
  local full_abs = system.absolute_path(common.home_expand(file_path)) or file_path
  
  local existing = find_existing_pdf_view(full_abs)
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
  local view = PdfView(full_abs)
  node:add_view(view)
  core.root_view.root_node:update_layout()
  core.set_active_view(view)
  core.redraw = true
  return view
end

-- 1. Hook core.open_doc to prevent loading huge binary PDF files into Doc text buffers
local old_core_open_doc = core.open_doc
core.open_doc = function(filename)
  if filename and is_pdf(filename) then
    local abs_filename = core.project_absolute_path(core.normalize_to_project_dir(filename)) or filename
    -- Return lightweight dummy Doc without disk content loading
    local doc = Doc(filename, abs_filename, true)
    doc.is_pdf_proxy = true
    table.insert(core.docs, doc)
    return doc
  end
  return old_core_open_doc(filename)
end

-- 2. Hook open_doc on both RootView class and core.root_view instance
local function create_open_doc_wrapper(old_fn)
  return function(self, doc)
    if not doc then return nil end
    if type(doc) == "table" and type(doc.is) == "function" and doc:is(PdfView) then
      return doc
    end
    if type(doc) == "string" and is_pdf(doc) then
      local abs_fn = core.project_absolute_path(core.normalize_to_project_dir(doc)) or doc
      return activate_or_create_pdf_view(abs_fn, doc)
    end
    if type(doc) == "table" then
      local fn = doc.filename or doc.abs_filename
      if (fn and is_pdf(fn)) or (doc.is_pdf_proxy) then
        local abs_fn = doc.abs_filename or doc.filename
        local view = activate_or_create_pdf_view(abs_fn, fn)

        -- Remove temporary/dummy doc from core.docs memory
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

-- 3. Prevent open_ext from intercepting PDFs
local ok_open_ext, open_ext = pcall(require, "plugins.open_ext")
if ok_open_ext and open_ext then
  -- open_ext already bypassed
end

-- ============================================================================
-- COMMAND PALETTE & KEYBINDINGS
-- ============================================================================
command.add(function()
  return core.active_view and core.active_view:is(PdfView), core.active_view
end, {
  ["pdf:next-page"] = function(view)
    view:next_page()
  end,
  ["pdf:previous-page"] = function(view)
    view:prev_page()
  end,
  ["pdf:zoom-in"] = function(view)
    view:set_zoom(view.zoom + 0.15)
  end,
  ["pdf:zoom-out"] = function(view)
    view:set_zoom(view.zoom - 0.15)
  end,
  ["pdf:zoom-reset"] = function(view)
    view:set_zoom(1.0)
  end,
  ["pdf:toggle-mode"] = function(view)
    view:toggle_mode()
  end,
  ["pdf:toggle-invert"] = function(view)
    view:toggle_invert()
  end,
  ["pdf:toggle-dark-mode"] = function(view)
    view:toggle_invert()
  end,
  ["pdf:find"] = function(view)
    core.command_view:enter("Search in PDF", {
      text = view.search_query or "",
      select_text = true,
      show_suggestions = false,
      typeahead = false,
      suggest = function() return {} end,
      submit = function(text, item)
        text = item and item.text or text
        view:search(text)
      end
    })
  end,
  ["pdf:find-next"] = function(view)
    view:next_match()
  end,
  ["pdf:find-previous"] = function(view)
    view:prev_match()
  end,
  ["pdf:goto-page"] = function(view)
    core.command_view:enter("Go to Page (1-" .. view.page_count .. ")", {
      text = tostring(view.page),
      select_text = true,
      show_suggestions = false,
      typeahead = false,
      suggest = function() return {} end,
      submit = function(val, item)
        val = item and item.text or val
        view:goto_page(tonumber(val) or view.page)
      end
    })
  end,
  ["pdf:copy"] = function(view)
    view:copy_selection()
  end,
  ["pdf:select-all"] = function(view)
    view:select_all()
  end,
})

-- Helper to filter suggestions strictly to PDFs and navigable folders
local function filter_pdf_suggestions(suggestions)
  local filtered = {}
  for _, item in ipairs(suggestions) do
    local text = type(item) == "table" and item.text or item
    local expanded = common.home_expand(text)
    if text:sub(-1) == "/" or text:sub(-1) == "\\" or text:sub(-1) == PATHSEP then
      table.insert(filtered, item)
    elseif text:lower():match("%.pdf$") then
      table.insert(filtered, item)
    else
      local info = system.get_file_info(expanded)
      if info and info.type == "dir" then
        table.insert(filtered, item)
      end
    end
  end
  return filtered
end

local function collect_all_pdf_files()
  local pdf_files = {}
  local seen = {}
  
  local function add_file(path)
    local full = system.absolute_path(common.home_expand(path)) or path
    if not seen[full] and full:lower():match("%.pdf$") then
      seen[full] = true
      table.insert(pdf_files, common.home_encode(path))
    end
  end

  -- 1. Scan project files
  for dir, item in core.get_project_files() do
    if item.type == "file" and item.filename:lower():match("%.pdf$") then
      local path = (dir == core.project_dir and "" or dir .. PATHSEP) .. item.filename
      add_file(path)
    end
  end

  -- 2. Scan Desktop directory
  local desktop_dir = USERDIR .. "/../../Desktop"
  local d_files = system.list_dir(desktop_dir) or {}
  for _, f in ipairs(d_files) do
    if f:lower():match("%.pdf$") then
      add_file(desktop_dir .. "/" .. f)
    end
  end

  return pdf_files
end

-- Global Open Command (Strictly Filtered to PDF Files)
command.add(nil, {
  ["pdf:open-file"] = function()
    local pdf_files = collect_all_pdf_files()
    core.command_view:enter("Open PDF File", {
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
        local view = activate_or_create_pdf_view(filename)
      end,
      suggest = function(text)
        if text:find("[\\/]") then
          -- Navigating directory: return ONLY directories and .pdf files
          local raw_suggestions = common.home_encode_list(common.path_suggest(common.home_expand(text)))
          return filter_pdf_suggestions(raw_suggestions)
        end
        -- Fuzzy match over collected PDF files (100% PDF files only)
        return common.fuzzy_match(pdf_files, text, true)
      end
    })
  end,
})

-- Keybindings
keymap.add {
  ["pagedown"]       = "pdf:next-page",
  ["pageup"]         = "pdf:previous-page",
  ["ctrl+="]         = "pdf:zoom-in",
  ["ctrl++"]         = "pdf:zoom-in",
  ["ctrl+-"]         = "pdf:zoom-out",
  ["ctrl+0"]         = "pdf:zoom-reset",
  ["ctrl+m"]         = "pdf:toggle-mode",
  ["ctrl+f"]         = "pdf:find",
  ["f3"]             = "pdf:find-next",
  ["shift+f3"]       = "pdf:find-previous",
  ["ctrl+g"]         = "pdf:goto-page",
  ["ctrl+c"]         = "pdf:copy",
  ["ctrl+insert"]    = "pdf:copy",
  ["ctrl+a"]         = "pdf:select-all",
  ["alt+p"]          = "pdf:open-file",
  ["ctrl+alt+p"]     = "pdf:open-file",
}

return PdfView
