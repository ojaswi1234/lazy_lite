-- mod-version: 3
local core = require "core"
local common = require "core.common"

-- [AUTO-GENERATED CACHED COLORS FOR GC OPTIMIZATION]
local _COLOR_CACHE_0 = {0,0,0,0}
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local system = require "system"
local ok_ab, ActivityBar = pcall(require, "plugins.activity_bar")

local YTView = View:extend()

function YTView:new()
  YTView.super.new(self)
  self.name = "YouTube Player"
  self.search_query = ""
  self.results = {}
  self.ml_concised = false
  self.repeat_mode = false
  self.is_playing = false
  self.current_time = 0
  self.total_time = 0
  self.scroll_y = 0
  self.status_msg = "Ready"
  self.active_input = false
  self.playing_title = ""
  self.models = { { provider = "loading", name = "Fetching models..." } }
  self.selected_model_idx = 1
  
  -- New state for pagination, languages, and playlists
  self.current_page = 1
  self.total_pages = 1
  self.search_type = "video"
  self.search_types = {"video", "playlist"}
  self.selected_search_type_idx = 1
  self.available_languages = {}
  self.selected_language = "original"
  self.expanded_playlists = {}
  self.playlist_videos = {}
  self:load_history()
  
  self:fetch_models()
  
  self.backend_proc = nil
  self:start_backend()
end


local history_file = USERDIR .. "/yt_player_history.txt"

function YTView:save_history()
  if not self.playing_video_id then return end
  local fp = io.open(history_file, "w")
  if fp then
    fp:write(self.playing_video_id .. "\n")
    fp:write((self.playing_title or "") .. "\n")
    fp:write(tostring(self.current_time or 0) .. "\n")
    fp:write(tostring(self.total_time or 0) .. "\n")
    fp:close()
  end
end

function YTView:load_history()
  local fp = io.open(history_file, "r")
  if fp then
    local id = fp:read("*l")
    local title = fp:read("*l")
    local time_str = fp:read("*l")
    local total_str = fp:read("*l")
    if id and title and time_str then
      self.last_video_id = id
      self.last_video_title = title
      self.last_video_time = tonumber(time_str) or 0
      
      self.playing_video_id = self.last_video_id
      self.playing_title = "(Recently Played) " .. self.last_video_title
      self.current_time = self.last_video_time
      self.total_time = tonumber(total_str) or 0
      self.is_playing = false
    end
    fp:close()
  end
end

function YTView:fetch_models()
  core.add_thread(function()
    local script_path = USERDIR .. "/scripts/ai_api_bridge.py"
    if not system.get_file_info(script_path) then return end
    local ok, p = pcall(process.start, {"python", script_path, "--list-models", "--provider", "all"})
    if not ok or not p then return end
    local out = ""
    while p:running() do
      local chunk = p:read_stdout(4096)
      if chunk then out = out .. chunk end
      coroutine.yield(0.1)
    end
    local chunk = p:read_stdout(4096)
    if chunk then out = out .. chunk end
    
    local new_models = {}
    for line in out:gmatch("[^\r\n]+") do
      local prov, name = line:match("^(.-)/(.-)$")
      if prov and name and (prov == "groq" or prov == "ollama") then
        table.insert(new_models, { provider = prov, name = name })
      end
    end
    
    if #new_models > 0 then
      self.models = new_models
      self.selected_model_idx = 1
      core.redraw = true
    else
      self.models = { { provider = "error", name = "No models found" } }
      core.redraw = true
    end
  end)
end

function YTView:try_close(do_close)
  -- Do not kill the backend process so the music keeps playing in the background
  -- It will naturally exit when Lite-XL closes
  do_close()
end

function YTView:start_backend()
  local exe_path = USERDIR .. "/plugins/yt_player/yt_backend.exe"
  if not system.get_file_info(exe_path) then
    self.status_msg = "Error: yt_backend.exe not found"
    return
  end

  local ok, proc = pcall(process.start, {exe_path})
  if not ok or not proc then
    self.status_msg = "Error starting backend"
    return
  end
  self.backend_proc = proc
  
  core.add_thread(function()
    local buf = ""
    while self.backend_proc and self.backend_proc:running() do
      local read_ok, out = pcall(function() return self.backend_proc:read_stdout() end)
      if read_ok and out and out ~= "" then
        buf = buf .. out
        while true do
          local nl = buf:find("\n")
          if not nl then break end
          local line = buf:sub(1, nl - 1):gsub("\r$", "")
          buf = buf:sub(nl + 1)
          if line ~= "" then
            self:handle_backend_msg(line)
          end
        end
      end
      coroutine.yield(0.05)
    end
  end)
  
  -- Status poller
  core.add_thread(function()
    while self.backend_proc and self.backend_proc:running() do
      self:send({cmd = "status"})
      coroutine.yield(1.0)
    end
  end)
end

function YTView:ensure_backend()
  if not self.backend_proc or not self.backend_proc:running() then
    self:start_backend()
  end
end

function YTView:send(data)
  if self.backend_proc and self.backend_proc:running() then
    local ok_json, json = pcall(require, "plugins.lsp.json")
    if not ok_json or not json then return end
    local ok_enc, encoded = pcall(json.encode, data)
    if ok_enc and encoded then
      local write_ok = pcall(function()
        self.backend_proc:write(encoded .. "\n")
      end)
      if not write_ok then
        self.backend_proc = nil
      end
    end
  end
end

function YTView:handle_backend_msg(line)
  local ok_json, json = pcall(require, "plugins.lsp.json")
  if not ok_json or not json then return end
  local ok, msg = pcall(json.decode, line)
  if not ok or type(msg) ~= "table" then return end
  
  if msg.event == "search_results" then
    self.results = msg.results or {}
    if msg.page then self.current_page = msg.page end
    self.status_msg = "Page " .. self.current_page .. " of " .. self.total_pages .. " (" .. #self.results .. " results)"
    
    if self.auto_play_first and #self.results > 0 then
      self.auto_play_first = false
      local first = nil
      for _, r in ipairs(self.results) do
        if not r.type or r.type == "video" then first = r; break end
      end
      if first then
        self.playing_video_id = first.id
        self.playing_title = first.title
        self.video_mode = false
        self:send({cmd = "play", video_id = first.id, ml_concised = self.ml_concised, ml_model = self.models[self.selected_model_idx], language = self.selected_language, sponsor_block = true})
      end
    end
    
    core.redraw = true
  elseif msg.event == "search_pagination" then
    self.total_pages = msg.total_pages or 1
    self.status_msg = "Page " .. self.current_page .. " of " .. self.total_pages .. " (" .. #self.results .. " results)"
    core.redraw = true
  elseif msg.event == "languages_available" then
    if msg.languages and #msg.languages > 0 then
      self.available_languages = {"original"}
      for _, l in ipairs(msg.languages) do
        table.insert(self.available_languages, l)
      end
      if msg.current and msg.current ~= "" then
        self.selected_language = msg.current
      else
        self.selected_language = "original"
      end
      core.redraw = true
    end
  elseif msg.event == "playlist_videos" then
    local pid = msg.playlist_id
    if pid and msg.videos then
      self.playlist_videos[pid] = msg.videos
      core.redraw = true
    end
  elseif msg.event == "playing" then
    self.is_playing = true
    self.status_msg = "Playing..."
    core.redraw = true
  elseif msg.event == "status" then
    self.is_playing = msg.playing or false
    self.current_time = tonumber(msg.time) or 0
    self.total_time = tonumber(msg.length) or 0
    
    if self.pending_resume_time and self.is_playing and self.current_time < 5 then
      self:send({cmd = "seek_abs", offset = self.pending_resume_time})
      self.pending_resume_time = nil
    end

    if os.time() - (self.last_save_os_time or 0) >= 2 then
      if self.playing_title and not self.playing_title:match("^%(Recently Played%)") then
        self:save_history()
      end
      self.last_save_os_time = os.time()
    end
    
    core.redraw = true
  elseif msg.event == "transcript_ready" then
    self.status_msg = msg.message or "ML Analyzing transcript..."
    core.redraw = true
  elseif msg.event == "skipped_filler" then
    self.status_msg = "ML Skipped Filler!"
    core.redraw = true
  elseif msg.event == "skipped_sponsor" then
    self.status_msg = "Skipped Sponsored Segment!"
    core.redraw = true
  elseif msg.event == "info" or msg.event == "producing" then
    self.status_msg = msg.message
    core.redraw = true
  elseif msg.event == "error" then
    self.status_msg = "Error: " .. tostring(msg.message)
    core.redraw = true
  elseif msg.event == "stopped" then
    self.is_playing = false
    self.current_time = 0
    self.total_time = 0
    self.status_msg = "Stopped."
    core.redraw = true
  end
end

function YTView:get_name()
  return self.name
end

function YTView:update()
  YTView.super.update(self)
  -- The Activity Bar explicitly hides tabs, so this view might be the sole view driving the sidebar width.
  -- To properly render in a locked resizable node (like the AI sidebar), it needs a target size.
  self.target_size = self.target_size or (400 * SCALE)
  self:move_towards(self.size, "x", self.target_size)
end

function YTView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function YTView:draw()
  self:draw_background(style.background3 or style.background)
  local font = style.font
  local th = font:get_height()
  local pad = 10
  
  local x, y = self.position.x + pad, self.position.y + pad
  local w = self.size.x - pad*2
  
  local mouse_x, mouse_y = core.root_view.mouse.x, core.root_view.mouse.y
  
  local function is_hovered(rect)
    return rect and mouse_x >= rect[1] and mouse_x <= rect[1] + rect[3] and mouse_y >= rect[2] and mouse_y <= rect[2] + rect[4]
  end
  
  -- ==========================================
  -- 1. SEARCH BAR (Top)
  -- ==========================================
  -- Search Type Selector (Text only, no icon to avoid '?')
  local search_type_text = self.search_types[self.selected_search_type_idx]:sub(1,1):upper() .. self.search_types[self.selected_search_type_idx]:sub(2)
  local type_w = font:get_width("Playlist") + pad*3
  local search_h = th + pad*2
  self.btn_search_type = {x, y, type_w, search_h}
  renderer.draw_rect(x, y, type_w, search_h, is_hovered(self.btn_search_type) and style.background3 or style.background2)
  renderer.draw_text(font, search_type_text, x + (type_w - font:get_width(search_type_text))/2, y + pad, style.text)
  
  -- Search Box
  local search_x = x + type_w + pad
  local search_w = w - type_w - pad
  self.search_box_rect = {search_x, y, search_w, search_h}
  renderer.draw_rect(search_x, y, search_w, search_h, is_hovered(self.search_box_rect) and style.background3 or style.background2)
  local search_icon = "\xef\x80\x82" -- fa-search
  renderer.draw_text(style.icon_font, search_icon, search_x + pad, y + pad, self.active_input and style.text or style.dim)
  local disp_q = self.search_query
  if self.active_input and os.time() % 2 == 0 then disp_q = disp_q .. "|" end
  renderer.draw_text(font, (disp_q == "" and not self.active_input and "Search YouTube..." or disp_q), search_x + pad*2 + style.icon_font:get_width(search_icon), y + pad, self.active_input and style.text or style.dim)
  y = y + search_h + pad

  -- ==========================================
  -- 2. TOOLBAR (Below Search)
  -- ==========================================
  -- AI Trim toggle
  local trim_icon = "\xef\x83\x88" -- fa-magic
  local trim_txt = " Trim: " .. (self.ml_concised and "ON" or "OFF")
  local trim_color = self.ml_concised and style.accent or style.dim
  local trim_w = style.icon_font:get_width(trim_icon) + font:get_width(trim_txt) + pad
  self.btn_ml = {x, y, trim_w, th + pad}
  if is_hovered(self.btn_ml) then renderer.draw_rect(x, y, trim_w, th+pad, style.background2) end
  renderer.draw_text(style.icon_font, trim_icon, x + pad/2, y + pad/2, trim_color)
  renderer.draw_text(font, trim_txt, x + pad/2 + style.icon_font:get_width(trim_icon), y + pad/2, trim_color)
  
  -- Language Toggle
  local lx = x + trim_w + pad
  if #self.available_languages > 1 then
    local lang_txt = "Lang: " .. self.selected_language
    local lang_w = font:get_width(lang_txt) + pad*2
    self.btn_lang = {lx, y, lang_w, th+pad}
    if is_hovered(self.btn_lang) then renderer.draw_rect(lx, y, lang_w, th+pad, style.background2) end
    renderer.draw_text(font, lang_txt, lx + pad, y + pad/2, style.text)
    lx = lx + lang_w + pad
  else
    self.btn_lang = nil
  end
  
  -- Model Selector (Right aligned)
  local current_mod = self.models[self.selected_model_idx]
  local mod_text = "Model: " .. (current_mod.provider == "loading" and "Loading..." or current_mod.name)
  local mod_w = font:get_width(mod_text) + pad
  self.btn_model = {x + w - mod_w, y, mod_w, th+pad}
  if is_hovered(self.btn_model) then renderer.draw_rect(x + w - mod_w, y, mod_w, th+pad, style.background2) end
  renderer.draw_text(font, mod_text, x + w - mod_w + pad/2, y + pad/2, style.dim)
  
  y = y + th + pad*2

  -- Divider
  renderer.draw_rect(x, y, w, 1, style.background2)
  y = y + pad

  -- ==========================================
  -- 3. RESULTS AREA (Middle, takes remaining space)
  -- ==========================================
  -- Calculate bottom area height
  local player_h = th * 3 + pad * 4 -- For the player at the bottom
  local results_h = self.position.y + self.size.y - player_h - y - pad
  
  -- Status message / Pagination
  local disp_msg = self.status_msg or ""
  if disp_msg:match("Searching") or disp_msg:match("Loading") or disp_msg:match("Extracting") then
    local dots = string.rep(".", math.floor(system.get_time() * 3) % 4)
    disp_msg = disp_msg:gsub("%.%.%.", "") .. dots
    core.redraw = true
  end
  renderer.draw_text(font, disp_msg, x, y, style.dim)
  
  -- Pagination controls
  if self.total_pages > 1 then
    local ptext = "Page " .. self.current_page .. "/" .. self.total_pages
    local pw = font:get_width(ptext)
    local pbtn_w = font:get_width("< Prev") + pad
    local nbtn_w = font:get_width("Next >") + pad
    
    local nx = x + w - nbtn_w
    local mx = nx - pw - pad
    local px = mx - pbtn_w - pad
    
    self.btn_prev = {px, y, pbtn_w, th}
    if is_hovered(self.btn_prev) then renderer.draw_rect(px, y, pbtn_w, th, style.background2) end
    renderer.draw_text(font, "< Prev", px + pad/2, y, self.current_page > 1 and style.text or style.dim)
    
    renderer.draw_text(font, ptext, mx, y, style.text)
    
    self.btn_next = {nx, y, nbtn_w, th}
    if is_hovered(self.btn_next) then renderer.draw_rect(nx, y, nbtn_w, th, style.background2) end
    renderer.draw_text(font, "Next >", nx + pad/2, y, self.current_page < self.total_pages and style.text or style.dim)
  else
    self.btn_prev = nil
    self.btn_next = nil
  end
  y = y + th + pad
  
  -- Save results clipping rect
  local clip_y = y
  
  local function draw_item(res, indent)
    local row_h = th * 2 + pad
    if y > clip_y + results_h then 
      res.rect = nil
      return false 
    end
    
    local hovered = is_hovered({x, y, w, row_h})
    local bg = hovered and style.background2 or _COLOR_CACHE_0
    renderer.draw_rect(x, y, w, row_h, bg)
    
    local ix = x + pad + indent
    local iw = w - pad - indent
    
    local right_str = ""
    local dur = tonumber(res.duration) or 0
    if res.type == "playlist" then
      right_str = (res.entry_count or dur) .. " items"
    else
      right_str = string.format("%02d:%02d", math.floor(dur / 60), math.floor(dur % 60))
    end
    
    local right_w = font:get_width(right_str)
    
    local max_title_w = iw - pad*2 - right_w - (res.type == "playlist" and font:get_width("[+] ") or 0)
    if max_title_w < 10 then max_title_w = 10 end
    
    local title = common.truncate_text(res.title or "", font, max_title_w)
    
    if res.type == "playlist" then
      local exp_text = self.expanded_playlists[res.id] and "[-]" or "[+]"
      renderer.draw_text(font, exp_text, ix, y + pad + (th/2), hovered and style.text or style.dim)
      ix = ix + font:get_width(exp_text) + pad/2
    end
    
    local t_col = hovered and style.text or style.dim
    if res.id == self.playing_video_id then t_col = style.accent end
    renderer.draw_text(font, title, ix, y + pad + (th/2), t_col)
    
    renderer.draw_text(font, right_str, x + w - pad - right_w, y + pad + (th/2), style.dim)
    
    res.rect = {x, y, w, row_h}
    y = y + row_h
    return true
  end

  for i, res in ipairs(self.results) do
    if not draw_item(res, 0) then
      -- Clear rects for remaining items so they aren't clickable
      for j = i, #self.results do
        self.results[j].rect = nil
        if self.results[j].type == "playlist" and self.playlist_videos[self.results[j].id] then
          for _, v in ipairs(self.playlist_videos[self.results[j].id]) do
            v.rect = nil
          end
        end
      end
      break
    end
    
    if res.type == "playlist" and self.expanded_playlists[res.id] then
      local pvs = self.playlist_videos[res.id]
      if pvs then
        local stop_inner = false
        for _, v in ipairs(pvs) do
          if stop_inner then
            v.rect = nil
          elseif not draw_item(v, pad*3) then
            stop_inner = true
          end
        end
      else
        local row_h = th + pad
        if y < clip_y + results_h then
          renderer.draw_text(font, "Loading...", x + pad + pad*3, y + pad/2, style.dim)
          y = y + row_h
        end
      end
    end
  end
  
  -- ==========================================
  -- 4. PLAYER AREA (Sticky at Bottom)
  -- ==========================================
  local px_y = self.position.y + self.size.y - player_h - pad
  
  -- Divider for player
  renderer.draw_rect(x, px_y, w, 2, style.accent)
  px_y = px_y + pad
  
  -- Player Background
  renderer.draw_rect(x, px_y, w, player_h, style.background2)
  
  -- Title
  local title = (self.playing_title and self.playing_title ~= "") and self.playing_title or "No media playing"
  renderer.draw_text(font, title:sub(1, 60) .. (title:len() > 60 and "..." or ""), x + pad, px_y + pad, style.text)
  
  -- Progress Bar
  local py = px_y + pad*2 + th
  local pw = w - pad*2
  local p_h = 4
  self.progress_bar_rect = {x + pad, py - pad, pw, p_h + pad*2}
  local pb_hover = is_hovered(self.progress_bar_rect)
  renderer.draw_rect(x + pad, py, pw, pb_hover and p_h + 2 or p_h, style.background3)
  local progress = (self.total_time and self.total_time > 0) and (self.current_time / self.total_time) or 0
  renderer.draw_rect(x + pad, py, pw * progress, pb_hover and p_h + 2 or p_h, style.accent)
  
  -- Time text (Right aligned over progress bar)
  local time_str = string.format("%02d:%02d / %02d:%02d", 
    math.floor((self.current_time or 0) / 60), math.floor((self.current_time or 0) % 60),
    math.floor((self.total_time or 0) / 60), math.floor((self.total_time or 0) % 60))
  renderer.draw_text(style.code_font, time_str, x + w - pad - style.code_font:get_width(time_str), px_y + pad, style.dim)
  
  -- Controls
  local cy = py + pad*1.5
  local btn_size = th + pad
  
  -- Center the main controls
  local controls_w = btn_size * 4 + pad * 3
  local start_x = x + (w - controls_w) / 2
  
  local function draw_btn(rect, icon, active, force_col)
    local hovered = is_hovered(rect)
    if hovered then
      renderer.draw_rect(rect[1], rect[2], rect[3], rect[4], style.background3)
    end
    local col = force_col or (active and style.accent or (hovered and style.text or style.dim))
    renderer.draw_text(style.icon_font, icon, rect[1] + (rect[3] - style.icon_font:get_width(icon))/2, rect[2] + (rect[4] - style.icon_font:get_height())/2, col)
  end

  -- Rewind
  self.btn_rew = {start_x, cy, btn_size, btn_size}
  draw_btn(self.btn_rew, "\xef\x81\x8a", false)
  
  -- Play/Pause
  start_x = start_x + btn_size + pad
  self.btn_play = {start_x, cy, btn_size, btn_size}
  draw_btn(self.btn_play, self.is_playing and "\xef\x81\x8c" or "\xef\x81\x8b", self.is_playing)
  
  -- Forward
  start_x = start_x + btn_size + pad
  self.btn_fwd = {start_x, cy, btn_size, btn_size}
  draw_btn(self.btn_fwd, "\xef\x81\x8e", false)
  
  -- Repeat
  start_x = start_x + btn_size + pad
  self.btn_rep = {start_x, cy, btn_size, btn_size}
  draw_btn(self.btn_rep, "\xef\x80\x9e", self.repeat_mode)
  
	-- Stop Button (far left)
	self.btn_stop = {x + pad, cy, btn_size, btn_size}
	draw_btn(self.btn_stop, "\xef\x81\x8d", false, (self.playing_title ~= "" and style.text or style.dim))

  -- Show Video (far right)
  local vx = x + w - pad - btn_size
  self.btn_video = {vx, cy, btn_size, btn_size}
  draw_btn(self.btn_video, "\xef\x89\xac", self.playing_video_id ~= nil)
end

function YTView:on_mouse_pressed(button, x, y, clicks)
  local function in_rect(rx, ry, rw, rh)
    return x >= rx and y >= ry and x <= rx + rw and y <= ry + rh
  end
  
  if self.search_box_rect and in_rect(table.unpack(self.search_box_rect)) then
    self.active_input = true
    core.redraw = true
    return
  else
    self.active_input = false
    core.redraw = true
  end
  
  if self.btn_play and in_rect(table.unpack(self.btn_play)) then
    self:ensure_backend()
    if self.is_playing then 
      self:send({cmd = "pause"}) 
    else 
      if self.playing_video_id and self.playing_title and self.playing_title:match("^%(Recently Played%)") then
        self.playing_title = self.playing_title:gsub("^%(Recently Played%) ", "")
        self.pending_resume_time = self.current_time
        self:send({cmd = "play", video_id = self.playing_video_id, ml_concised = self.ml_concised, ml_model = self.models[self.selected_model_idx], language = self.selected_language, sponsor_block = true})
      else
        self:send({cmd = "resume"}) 
      end
    end
    return
  end
  
  if self.progress_bar_rect and in_rect(table.unpack(self.progress_bar_rect)) then
    if self.total_time and self.total_time > 0 then
      local click_x = x - self.progress_bar_rect[1]
      local ratio = click_x / self.progress_bar_rect[3]
      local target_time = self.total_time * ratio
      self:ensure_backend()
      self:send({cmd = "seek_abs", offset = target_time})
      -- Optimistically update UI
      self.current_time = target_time
      core.redraw = true
    end
    return
  end
  
  if self.btn_stop and in_rect(table.unpack(self.btn_stop)) then
    self:ensure_backend()
    self:send({cmd = "stop"})
    return
  end
  if self.btn_rew and in_rect(table.unpack(self.btn_rew)) then
    self:ensure_backend()
    self:send({cmd = "seek", offset = -10})
    return
  end
  if self.btn_fwd and in_rect(table.unpack(self.btn_fwd)) then
    self:ensure_backend()
    self:send({cmd = "seek", offset = 10})
    return
  end
  if self.btn_rep and in_rect(table.unpack(self.btn_rep)) then
    self:ensure_backend()
    self.repeat_mode = not self.repeat_mode
    self:send({cmd = "set_repeat", enabled = self.repeat_mode})
    core.redraw = true
    return
  end
  if self.btn_video and in_rect(table.unpack(self.btn_video)) then
    if self.playing_video_id then
      self:ensure_backend()
      self.status_msg = "Opening video in VLC GUI..."
      self.video_mode = true
      self.pending_resume_time = self.current_time
      self:send({cmd = "open_video", video_id = self.playing_video_id, language = self.selected_language, sponsor_block = true})
      core.redraw = true
    end
    return
  end
  if self.btn_ml and in_rect(table.unpack(self.btn_ml)) then
    self.ml_concised = not self.ml_concised
    core.redraw = true
    return
  end
  if self.btn_model and in_rect(table.unpack(self.btn_model)) then
    self.selected_model_idx = self.selected_model_idx + 1
    if self.selected_model_idx > #self.models then self.selected_model_idx = 1 end
    core.redraw = true
    return
  end
  
  if self.btn_search_type and in_rect(table.unpack(self.btn_search_type)) then
    self.selected_search_type_idx = self.selected_search_type_idx + 1
    if self.selected_search_type_idx > #self.search_types then
      self.selected_search_type_idx = 1
    end
    self.search_type = self.search_types[self.selected_search_type_idx]
    core.redraw = true
    return
  end
  
  if self.btn_lang and in_rect(table.unpack(self.btn_lang)) then
    local current_idx = 1
    for i, l in ipairs(self.available_languages) do
      if l == self.selected_language then current_idx = i; break end
    end
    current_idx = current_idx + 1
    if current_idx > #self.available_languages then current_idx = 1 end
    self.selected_language = self.available_languages[current_idx]
    
    if self.playing_video_id then
      self:ensure_backend()
      if self.video_mode then
        self.status_msg = "Reopening video in " .. self.selected_language .. "..."
        self.pending_resume_time = self.current_time
        self:send({cmd = "open_video", video_id = self.playing_video_id, language = self.selected_language, sponsor_block = true})
      else
        self.pending_resume_time = self.current_time
        self:send({cmd = "play", video_id = self.playing_video_id, ml_concised = self.ml_concised, ml_model = self.models[self.selected_model_idx], language = self.selected_language, sponsor_block = true})
      end
    end
    core.redraw = true
    return
  end
  
  if self.btn_prev and in_rect(table.unpack(self.btn_prev)) then
    if self.current_page > 1 then
      self:ensure_backend()
      self.status_msg = "Loading Page " .. (self.current_page - 1) .. "..."
      self:send({cmd = "search", query = self.search_query, page = self.current_page - 1, search_type = self.search_type})
      core.redraw = true
    end
    return
  end
  
  if self.btn_next and in_rect(table.unpack(self.btn_next)) then
    if self.current_page < self.total_pages then
      self:ensure_backend()
      self.status_msg = "Loading Page " .. (self.current_page + 1) .. "..."
      self:send({cmd = "search", query = self.search_query, page = self.current_page + 1, search_type = self.search_type})
      core.redraw = true
    end
    return
  end
  
  local function handle_item_click(res)
    if res.type == "playlist" then
      self.expanded_playlists[res.id] = not self.expanded_playlists[res.id]
      if self.expanded_playlists[res.id] and not self.playlist_videos[res.id] then
        self:ensure_backend()
        self:send({cmd = "playlist_videos", playlist_id = res.id})
      end
      core.redraw = true
      return true
    else
      self:ensure_backend()
      self.status_msg = "Loading..."
      self.playing_title = res.title or ""
      self.playing_video_id = res.id
      self.video_mode = false
      self:send({cmd = "play", video_id = res.id, ml_concised = self.ml_concised, ml_model = self.models[self.selected_model_idx], language = self.selected_language, sponsor_block = true})
      return true
    end
  end

  for _, res in ipairs(self.results) do
    if res.rect and in_rect(table.unpack(res.rect)) then
      if handle_item_click(res) then return end
    end
    if res.type == "playlist" and self.expanded_playlists[res.id] then
      local pvs = self.playlist_videos[res.id]
      if pvs then
        for _, v in ipairs(pvs) do
          if v.rect and in_rect(table.unpack(v.rect)) then
            if handle_item_click(v) then return end
          end
        end
      end
    end
  end
end

function YTView:on_text_input(text)
  if self.active_input then
    self.search_query = self.search_query .. text
    core.redraw = true
  end
end

command.add(YTView, {
  ["youtube-player:backspace"] = function(self)
    if self.active_input and #self.search_query > 0 then
      -- simple utf8 backspace
      local text = self.search_query
      local len = #text
      while len > 0 and text:byte(len) >= 0x80 and text:byte(len) < 0xc0 do
        len = len - 1
      end
      self.search_query = text:sub(1, math.max(0, len - 1))
      core.redraw = true
    end
  end,
  
  ["youtube-player:search"] = function(self)
    if self.active_input then
      self:ensure_backend()
      self.status_msg = "Searching..."
      self.results = {}
      self.current_page = 1
      self.total_pages = 1
      self:send({cmd = "search", query = self.search_query, page = 1, search_type = self.search_type})
      self.active_input = false
      core.redraw = true
    end
  end
})

keymap.add {
  ["backspace"] = "youtube-player:backspace",
  ["return"] = "youtube-player:search",
}

local yt_view_instance = nil

command.add(nil, {
  ["youtube-player:toggle"] = function()
    local sidebar = _G.get_sidebar_node and _G.get_sidebar_node()
    
    local node = yt_view_instance and core.root_view.root_node:get_node_for_view(yt_view_instance)
    
    if yt_view_instance and node then
      if sidebar and node == sidebar then
        if sidebar.active_view == yt_view_instance then
          node:close_view(core.root_view.root_node, yt_view_instance)
          -- DO NOT set to nil, so the music keeps playing in the background
        else
          node:set_active_view(yt_view_instance)
          core.set_active_view(yt_view_instance)
        end
      else
        node:set_active_view(yt_view_instance)
        core.set_active_view(yt_view_instance)
      end
    else
      if not yt_view_instance then
        yt_view_instance = YTView()
      end
      
      if sidebar then
        sidebar:add_view(yt_view_instance)
        sidebar:set_active_view(yt_view_instance)
        core.set_active_view(yt_view_instance)
      else
        local node = core.root_view:get_active_node_default()
        local w = core.root_view.size.x
        local h = core.root_view.size.y
        -- Safely split the active leaf node instead of the root
        node:split("right", yt_view_instance, {x = w - 400, y = h}, true)
        core.set_active_view(yt_view_instance)
      end
    end
  end,
  
  ["youtube-player:play-pause"] = function()
    if yt_view_instance then
      yt_view_instance:ensure_backend()
      if yt_view_instance.is_playing then
        yt_view_instance:send({cmd = "pause"})
      else
        yt_view_instance:send({cmd = "resume"})
      end
    end
  end,
  
  ["youtube-player:seek-forward"] = function()
    if yt_view_instance then
      yt_view_instance:ensure_backend()
      yt_view_instance:send({cmd = "seek", offset = 10})
    end
  end,
  
  ["youtube-player:seek-backward"] = function()
    if yt_view_instance then
      yt_view_instance:ensure_backend()
      yt_view_instance:send({cmd = "seek", offset = -10})
    end
  end,
  
  ["youtube-player:quick-play"] = function()
    core.command_view:enter("Search YouTube to Quick Play", {
      submit = function(text)
        if not yt_view_instance then
          command.perform("youtube-player:toggle")
        end
        if yt_view_instance then
          yt_view_instance:ensure_backend()
          yt_view_instance.status_msg = "Quick Playing..."
          yt_view_instance.results = {}
          yt_view_instance.auto_play_first = true
          yt_view_instance:send({cmd = "search", query = text, page = 1, search_type = "video"})
          core.redraw = true
        end
      end
    })
  end
})

keymap.add {
  ["alt+q"] = "youtube-player:play-pause",
  ["alt+right"] = "youtube-player:seek-forward",
  ["alt+left"] = "youtube-player:seek-backward",
}

-- Status Bar Integration (Mini Player)
local status_view = require "core.statusview"
if status_view and core.status_view then
  core.status_view:add_item({
    name = "youtube_player_playpause",
    alignment = status_view.Item.RIGHT,
    position = 1,
    get_item = function()
      local v = yt_view_instance
      if not v or not v.playing_title or v.playing_title == "" then return {} end
      if v.playing_title:match("^%(Recently Played%)") or v.status_msg == "Stopped." then return {} end
      local icon = v.is_playing and "\xef\x81\x8c" or "\xef\x81\x8b"
      return { style.icon_font, style.accent, icon }
    end,
    command = "youtube-player:play-pause"
  })

  core.status_view:add_item({
    name = "youtube_player_status",
    alignment = status_view.Item.RIGHT,
    position = 2,
    get_item = function()
      local v = yt_view_instance
      if not v or not v.playing_title or v.playing_title == "" then return {} end
      if v.playing_title:match("^%(Recently Played%)") or v.status_msg == "Stopped." then return {} end
      return { style.text, " " .. v.playing_title:sub(1, 30) .. (v.playing_title:len() > 30 and "..." or "") }
    end,
    command = "youtube-player:toggle"
  })
end

return YTView

