-- mod-version:3
local core = require "core"
local style = require "core.style"
local system = require "system"

local typing = {}

local TOKENS = {
  "function", "local", "nil", "require", "end", "return", 
  "pcall", "for i = 1, 10 do", "if not ok then",
  "table.insert", "io.open", "system",
  "local core", "function return end", "while true do"
}

function typing.start()
  typing.current_token = TOKENS[math.random(#TOKENS)]
  typing.input = ""
  typing.start_time = system.get_time()
  typing.words_typed = 0
  typing.errors = 0
  typing.error_flash = 0
  typing.total_chars = 0
end

function typing.update(dt)
  if typing.error_flash > 0 then
    typing.error_flash = math.max(0, typing.error_flash - dt)
  end
end

function typing.draw(x, y, w, h)
  -- WPM calculation
  local elapsed = system.get_time() - typing.start_time
  local wpm = 0
  if elapsed > 0 then
    wpm = math.floor((typing.total_chars / 5) / (elapsed / 60))
  end
  
  local stats = "WPM: " .. wpm .. "   Errors: " .. typing.errors
  local st_w = style.font:get_width(stats)
  renderer.draw_text(style.font, stats, x + (w - st_w)/2, y + 20 * SCALE, style.dim)
  
  local display_font = style.big_font or style.font
  local c_w = display_font:get_width(typing.current_token)
  local cx = x + (w - c_w) / 2
  local cy = y + h / 2 - 20 * SCALE
  
  -- draw token background flash on error
  local bg_color = typing.error_flash > 0 and {255, 50, 50, 100} or {30, 30, 35, 150}
  renderer.draw_rect(cx - 10 * SCALE, cy - 5 * SCALE, c_w + 20 * SCALE, display_font:get_height() + 10 * SCALE, bg_color)
  
  -- draw characters
  local text_x = cx
  for i = 1, #typing.current_token do
    local char = typing.current_token:sub(i, i)
    local color = style.text
    if i <= #typing.input then
      if typing.input:sub(i, i) == char then
        color = style.dim
      else
        color = style.accent
      end
    end
    text_x = renderer.draw_text(display_font, char, text_x, cy, color)
  end
end

function typing.on_keypressed(key)
  if key == "backspace" then
    if #typing.input > 0 then
      typing.input = typing.input:sub(1, -2)
    end
    return true
  end
  
  -- filter modifiers
  if #key > 1 and key ~= "space" and key ~= "-" and key ~= "=" and key ~= "." and key ~= "," then return false end
  
  local char = key
  if key == "space" then char = " " end
  
  -- basic punctuation mapping for US keyboard without shift (simplified)
  -- since we only need simple typing, and the user might press shift+key which comes as separate events in lite-xl
  -- we rely on textinput for accuracy in a real editor, but for this mini-game `on_keypressed` is sufficient if we stick to basic chars
  
  typing.input = typing.input .. char
  
  local expected = typing.current_token:sub(1, #typing.input)
  if typing.input ~= expected then
    typing.errors = typing.errors + 1
    typing.error_flash = 0.2
    typing.input = typing.input:sub(1, -2) -- prevent wrong char from being added
  end
  
  if typing.input == typing.current_token then
    typing.total_chars = typing.total_chars + #typing.current_token + 1
    typing.current_token = TOKENS[math.random(#TOKENS)]
    typing.input = ""
  end
  
  return true
end

function typing.on_textinput(text)
  -- if we get actual text input (e.g. shifted characters), we can process it here
  -- for now, `on_keypressed` handles our limited token set well enough
  return false
end

function typing.is_finished()
  return false
end

return typing
