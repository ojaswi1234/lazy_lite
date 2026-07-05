-- mod-version:3
local core = require "core"
local style = require "core.style"
local system = require "system"

-- Ensure random is seeded
math.randomseed(math.floor(system.get_time() * 1000))

local games = {
  require "plugins.loader_games.snake",
  require "plugins.loader_games.pong",
  require "plugins.loader_games.typing_test"
}

local loader = {
  active = false,
  start_time = 0,
  phase_msg = "",
  percent = nil,
  error_msg = nil,
  show_tooltip = true,
  current_game = nil,
  last_game_idx = -1,
  last_update = 0
}

function loader.start(phase_msg)
  loader.active = true
  loader.start_time = system.get_time()
  loader.phase_msg = phase_msg or "Starting..."
  loader.percent = nil
  loader.error_msg = nil
  loader.show_tooltip = true
  loader.last_update = system.get_time()
  
  -- Pick a random game, avoiding immediate repeat if there's history
  local idx
  repeat
    idx = math.random(1, #games)
  until idx ~= loader.last_game_idx or #games == 1
  loader.last_game_idx = idx
  
  loader.current_game = games[idx]
  if loader.current_game and loader.current_game.start then
    loader.current_game.start()
  end
end

function loader.stop()
  loader.active = false
  -- cleanup any dangling state
  if loader.current_game and loader.current_game.stop then
    loader.current_game.stop()
  end
  loader.current_game = nil
end

function loader.set_error(msg)
  loader.error_msg = msg
end

function loader.update_progress(phase_msg, percent)
  if phase_msg then loader.phase_msg = phase_msg end
  if percent then loader.percent = percent end
end

function loader.on_keypressed(key)
  if not loader.active then return false end
  
  -- global loader toggle
  if key == "?" or key == "shift+/" then
    loader.show_tooltip = not loader.show_tooltip
    core.redraw = true
    return true
  end
  
  if loader.error_msg then return false end
  
  if loader.current_game and loader.current_game.on_keypressed then
    return loader.current_game.on_keypressed(key)
  end
  return false
end

function loader.on_textinput(text)
  if not loader.active or loader.error_msg then return false end
  if loader.current_game and loader.current_game.on_textinput then
    return loader.current_game.on_textinput(text)
  end
  return false
end

function loader.draw(x, y, w, h)
  if not loader.active then return end
  
  local t = system.get_time()
  local dt = t - loader.last_update
  loader.last_update = t
  
  local status_h = 40 * SCALE
  local game_h = math.max(10 * SCALE, h - status_h)
  w = math.max(10 * SCALE, w)
  
  if loader.error_msg then
    local err_w = style.font:get_width(loader.error_msg)
    renderer.draw_text(style.font, loader.error_msg, x + (w - err_w)/2, y + (game_h)/2, {255, 100, 100, 255})
  elseif loader.current_game then
    if loader.current_game.update then
      loader.current_game.update(dt)
    end
    if loader.current_game.draw then
      loader.current_game.draw(x, y, w, game_h)
    end
  end
  
  -- draw persistent progress bar / info strip at the bottom
  local strip_y = y + h - status_h
  renderer.draw_rect(x, strip_y, w, status_h, {20, 20, 25, 255})
  
  local elapsed = math.floor(t - loader.start_time)
  local mins = math.floor(elapsed / 60)
  local secs = elapsed % 60
  
  local status_text = string.format("[%d:%02d] %s", mins, secs, loader.phase_msg)
  if loader.percent then
    status_text = status_text .. string.format(" (%d%%)", loader.percent)
  end
  
  if not loader.show_tooltip then
    status_text = string.format("[%d:%02d] ... (Press ? to show details)", mins, secs)
  end
  
  local st_w = style.font:get_width(status_text)
  local font_h = style.font:get_height()
  renderer.draw_text(style.font, status_text, x + (w - st_w)/2, strip_y + (status_h - font_h)/2, style.accent)
  
  -- force continuous redraw since games are animating
  core.redraw = true
end

return loader
