-- mod-version: 3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local ActivityBar = require "plugins.activity_bar"

local YTView = View:extend()

function YTView:new()
  YTView.super.new(self)
  self.name = "YouTube Player"
  self.search_query = ""
  self.results = {}
  self.ml_concised = false
  self.is_playing = false
  self.current_time = 0
  self.total_time = 0
  self.scroll_y = 0
  self.status_msg = "Ready"
  self.active_input = false
  self.playing_title = ""
  self.models = { { provider = "loading", name = "Fetching models..." } }
  self.selected_model_idx = 1
  self:fetch_models()
  
  self.backend_proc = nil
  self:start_backend()
end


function YTView:fetch_models()
  core.add_thread(function()
    local script_path = USERDIR .. "/scripts/ai_api_bridge.py"
    local p = process.start({"python", script_path, "--list-models", "--provider", "all"})
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

function YTView:start_backend()
  local script_path = USERDIR .. "/plugins/yt_player/yt_backend.py"
  self.backend_proc = process.start({"python", script_path})
  
  core.add_thread(function()
    while true do
      if self.backend_proc then
        local out = self.backend_proc:read_stdout()
        if out and out ~= "" then
          for line in out:gmatch("([^\n]+)") do
            self:handle_backend_msg(line)
          end
        end
      end
      coroutine.yield(0.1)
    end
  end)
  
  -- Status poller
  core.add_thread(function()
    while true do
      self:send({cmd = "status"})
      coroutine.yield(1.0)
    end
  end)
end

function YTView:send(data)
  if self.backend_proc then
    self.backend_proc:write(require("plugins.lsp.json").encode(data) .. "\n")
  end
end

function YTView:handle_backend_msg(line)
  local ok, msg = pcall(require("plugins.lsp.json").decode, line)
  if not ok then return end
  
  if msg.event == "search_results" then
    self.results = msg.results
    self.status_msg = "Found " .. #self.results .. " results"
    core.redraw = true
  elseif msg.event == "playing" then
    self.is_playing = true
    self.status_msg = "Playing..."
    core.redraw = true
  elseif msg.event == "status" then
    self.is_playing = msg.playing
    self.current_time = msg.time
    self.total_time = msg.length
    core.redraw = true
  elseif msg.event == "transcript_ready" then
    self.status_msg = msg.message or "ML Analyzing transcript..."
    core.redraw = true
  elseif msg.event == "skipped_filler" then
    self.status_msg = "ML Skipped Filler!"
    core.redraw = true
  elseif msg.event == "error" then
    self.status_msg = "Error: " .. msg.message
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
  
  -- Title
  renderer.draw_text(style.big_font, "YouTube Audio", x, y, style.text)
  y = y + style.big_font:get_height() + pad
  
  -- Input box
  local bg_col = self.active_input and style.accent or style.background2
  renderer.draw_rect(x, y, w, th + pad, bg_col)
  local disp_q = self.search_query
  if self.active_input and os.time() % 2 == 0 then disp_q = disp_q .. "|" end
  renderer.draw_text(font, (disp_q == "" and not self.active_input and "Click to search..." or disp_q), x + pad/2, y + pad/2, self.active_input and style.text or style.dim)
  self.search_box_rect = {x, y, w, th + pad}
  y = y + th + pad*2
  
  -- Controls
  local btn_w = 40
  local ctrl_y = y
  
  -- Play/Pause
  local pp_icon = self.is_playing and "\xef\x81\x8c" or "\xef\x81\x8b" -- fa-pause or fa-play
  renderer.draw_rect(x, y, btn_w, th+pad, style.background2)
  renderer.draw_text(style.icon_font, pp_icon, x + (btn_w - style.icon_font:get_width(pp_icon))/2, y + pad/2, style.text)
  self.btn_play = {x, y, btn_w, th+pad}
  
  -- Rewind
  local rew_icon = "\xef\x81\x8a" -- fa-backward
  renderer.draw_rect(x + btn_w + pad, y, btn_w, th+pad, style.background2)
  renderer.draw_text(style.icon_font, rew_icon, x + btn_w + pad + (btn_w - style.icon_font:get_width(rew_icon))/2, y + pad/2, style.text)
  self.btn_rew = {x + btn_w + pad, y, btn_w, th+pad}
  
  -- Forward
  local fwd_icon = "\xef\x81\x8e" -- fa-forward
  renderer.draw_rect(x + btn_w*2 + pad*2, y, btn_w, th+pad, style.background2)
  renderer.draw_text(style.icon_font, fwd_icon, x + btn_w*2 + pad*2 + (btn_w - style.icon_font:get_width(fwd_icon))/2, y + pad/2, style.text)
  self.btn_fwd = {x + btn_w*2 + pad*2, y, btn_w, th+pad}
  
  -- ML Toggle
  local ml_icon = "\xef\x83\x88" -- fa-magic
  local ml_x = x + btn_w*3 + pad*3
  local ml_w = w - (btn_w*3 + pad*3)
  renderer.draw_rect(ml_x, y, ml_w, th+pad, self.ml_concised and style.accent or style.background2)
  renderer.draw_text(font, "ML Concised", ml_x + pad, y + pad/2, style.text)
  self.btn_ml = {ml_x, y, ml_w, th+pad}
  
  y = y + th + pad*2
  
  -- Model Selector Button
  local current_mod = self.models[self.selected_model_idx]
  local mod_text = current_mod.provider:upper() .. ": " .. current_mod.name
  renderer.draw_rect(x, y, w, th+pad, style.background2)
  renderer.draw_text(font, mod_text, x + pad, y + pad/2, style.text)
  self.btn_model = {x, y, w, th+pad}
  
  y = y + th + pad*2
  
  -- Status & Time
  local time_str = string.format("%02d:%02d / %02d:%02d", 
    math.floor(self.current_time / 60), self.current_time % 60,
    math.floor(self.total_time / 60), self.total_time % 60)
  renderer.draw_text(font, time_str, x, y, style.text)
  y = y + th
  
  if self.playing_title ~= "" then
     renderer.draw_text(font, "Playing: " .. self.playing_title:sub(1, 35) .. "...", x, y, style.accent)
     y = y + th
  end
  
  local disp_msg = self.status_msg
  if disp_msg:match("Searching") or disp_msg:match("Loading") then
    local spinners = {"\xef\x84\x8c", "\xef\x84\x91", "\xef\x84\x90", "\xef\x84\x8d", "\xef\x84\x8e"} -- fa-circle-o-notch equivalents
    local frame = spinners[math.floor((os.time() * 5) % #spinners) + 1]
    -- Wait! os.time() is in seconds! We should use system.get_time() for smooth animation!
    -- Let's just use dots for now, it's safer than font icons which might not match.
    local dots = string.rep(".", math.floor(system.get_time() * 3) % 4)
    disp_msg = disp_msg:gsub("%.%.%.", "") .. dots
    core.redraw = true -- force redraw for animation
  end
  renderer.draw_text(font, disp_msg, x, y, style.dim)
  y = y + th + pad
  
  -- Results
  local mouse_x, mouse_y = core.root_view.mouse.x, core.root_view.mouse.y
  for i, res in ipairs(self.results) do
    local ry = y + (i-1) * (th*2 + pad*2)
    if ry > self.position.y + self.size.y then break end
    
    local hovered = mouse_x >= x and mouse_x <= x + w and mouse_y >= ry and mouse_y <= ry + th*2 + pad
    local bg = hovered and style.background2 or {0,0,0,0}
    renderer.draw_rect(x, ry, w, th*2 + pad, bg)
    
    renderer.draw_text(font, res.title:sub(1, 45) .. (res.title:len() > 45 and "..." or ""), x + pad, ry + pad/2, hovered and style.text or style.accent)
    
    local dur_str = string.format("%02d:%02d", math.floor(res.duration / 60), res.duration % 60)
    renderer.draw_text(font, dur_str, x + pad, ry + th + pad/2, style.dim)
    res.rect = {x, ry, w, th*2 + pad}
  end
end

function YTView:on_mouse_pressed(button, x, y, clicks)
  local function in_rect(rx, ry, rw, rh)
    return x >= rx and y >= ry and x <= rx + rw and y <= ry + rh
  end
  
  if in_rect(table.unpack(self.search_box_rect)) then
    self.active_input = true
    core.redraw = true
    return
  else
    self.active_input = false
    core.redraw = true
  end
  
  if in_rect(table.unpack(self.btn_play)) then
    if self.is_playing then self:send({cmd = "pause"}) else self:send({cmd = "resume"}) end
    return
  end
  if in_rect(table.unpack(self.btn_rew)) then
    self:send({cmd = "seek", offset = -10})
    return
  end
  if in_rect(table.unpack(self.btn_fwd)) then
    self:send({cmd = "seek", offset = 10})
    return
  end
  if in_rect(table.unpack(self.btn_ml)) then
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
  
  for _, res in ipairs(self.results) do
    if res.rect and in_rect(table.unpack(res.rect)) then
      self.status_msg = "Loading..."
      self.playing_title = res.title
      self:send({cmd = "play", video_id = res.id, ml_concised = self.ml_concised, model = self.models[self.selected_model_idx]})
      return
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
      self.status_msg = "Searching..."
      self.results = {}
      self:send({cmd = "search", query = self.search_query})
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
    core.log("[YT] Toggle triggered!")
    local sidebar = _G.get_sidebar_node and _G.get_sidebar_node()
    core.log("[YT] Sidebar node found: " .. tostring(sidebar ~= nil))
    
    if yt_view_instance and core.root_view.root_node:get_node_for_view(yt_view_instance) then
      core.log("[YT] View already exists, toggling focus/close")
      local node = core.root_view.root_node:get_node_for_view(yt_view_instance)
      if sidebar and node == sidebar then
        if sidebar.active_view == yt_view_instance then
          node:close_view(core.root_view.root_node, yt_view_instance)
          yt_view_instance = nil
        else
          node:set_active_view(yt_view_instance)
          core.set_active_view(yt_view_instance)
        end
      else
        node:set_active_view(yt_view_instance)
        core.set_active_view(yt_view_instance)
      end
    else
      core.log("[YT] Creating new YTView instance")
      yt_view_instance = YTView()
      if sidebar then
        core.log("[YT] Adding to existing sidebar")
        sidebar:add_view(yt_view_instance)
        sidebar:set_active_view(yt_view_instance)
        core.set_active_view(yt_view_instance)
      else
        core.log("[YT] Splitting root node right")
        local w = core.root_view.size.x
        local h = core.root_view.size.y
        core.root_view.root_node:split("right", yt_view_instance, {x = w - 400, y = h}, true)
        core.set_active_view(yt_view_instance)
      end
    end
  end
})



return YTView
