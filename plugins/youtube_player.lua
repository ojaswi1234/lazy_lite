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
    for line in out:gmatch("[^\r\n]+") do