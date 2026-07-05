-- mod-version:3
local core = require "core"
local style = require "core.style"
local system = require "system"

local pet = {
  active = false,
  start_time = 0,
  last_interaction = 0,
  happiness = 0,
  mood = "idle", -- idle, feed, poke, sad, happy, celebrating
  mood_until = 0,
  show_tooltip = false,
  phase_msg = "",
  percent = nil,
  error_msg = nil
}

-- ASCII, monospace-safe. Recognizable creature: round ears, dot/O eyes,
-- a snout, and a body with paws. Digits (8, 0) double as speckles/pupils
-- for extra texture without breaking monospace alignment.
local ASCII_FRAMES = {

  egg = {
    "      _____      ",
    "    ,d8888b,    ",
    "   d8'    `8b   ",
    "  d8'  ()  `8b  ",
    "  88        88  ",
    "  `8,      ,8'  ",
    "   `8bd88db8'   "
  },
  egg_alt = {
    "      _____      ",
    "    ,d8888b,    ",
    "   d8'  /\\ `8b  ",
    "  d8'  /  \\`8b  ",
    "  88   \\  / 88  ",
    "  `8,   \\/ ,8'  ",
    "   `8bd88db8'   "
  },

  hatchling = {
    "    (\\_/)    ",
    "   ( o.o )   ",
    "   c(\")(\")   ",
    "    /   \\    ",
    "   (  8  )   "
  },
  hatchling_alt = {
    "    (\\_/)    ",
    "   ( -.- )   ",
    "   c(\")(\")   ",
    "    /   \\    ",
    "   (  8  )   "
  },

  juvenile = {
    "   ^\\   /^   ",
    "  /  \\ /  \\  ",
    " (  o   o  )  ",
    "  \\   w   /   ",
    "  /` *0* `\\   ",
    " (___/ \\___) ",
  },
  juvenile_alt = {
    "   ^\\   /^   ",
    "  /  \\ /  \\  ",
    " (  -   -  )  ",
    "  \\   w   /   ",
    "  /` *0* `\\   ",
    " (___/ \\___) ",
  },

  adult = {
    "   ^\\     /^   ",
    "  /  \\   /  \\  ",
    " (   O     O   ) ",
    "  \\     w     /  ",
    " ,-'.  ---  .'-, ",
    "(   8    8    ) ",
    " \\___\\   /___/  ",
  },
  adult_alt = {
    "   ^\\     /^   ",
    "  /  \\   /  \\  ",
    " (   -     -   ) ",
    "  \\     w     /  ",
    " ,-'.  ---  .'-, ",
    "(   8    8    ) ",
    " \\___\\   /___/  ",
  },

  sad = {
    "   ^\\     /^   ",
    "  /  \\   /  \\  ",
    " (   T     T   ) ",
    "  \\    ...    /  ",
    " ,-'.  ---  .'-, ",
    "(   8    8    ) ",
    " \\___\\   /___/  ",
  },

  feed = {
    "   ^\\     /^   ",
    "  /  \\   /  \\  ",
    " (   ^     ^   ) ",
    "  \\   (@)    /  ",
    " ,-'.  ---  .'-, ",
    "(   8    8    ) ",
    " \\___\\   /___/  ",
  },

  poke = {
    "   ^\\     /^   ",
    "  /  \\   /  \\  ",
    " (   >     <   ) ",
    "  \\    o     /  ",
    " ,-'.  ---  .'-, ",
    "(   8    8    ) ",
    " \\___\\   /___/  ",
  },

  happy = {
    "   ^\\     /^   ",
    "  /  \\   /  \\  ",
    " (   ^     ^   ) ",
    "  \\    v    / <3",
    " ,-'.  ---  .'-, ",
    "(   8    8    ) ",
    " \\___\\   /___/  ",
  },

  celebrating = {
    " *   ^\\     /^   * ",
    "  /  \\   /  \\  ~ ",
    " (   ^     ^   )  ",
    "  \\   \\o/    /  * ",
    " ,-'.  ---  .'-,  ",
    "(   8    8    )  ~",
    " \\___\\   /___/  * ",
  }
}

function pet.start(phase_msg)
  pet.active = true
  pet.start_time = system.get_time()
  pet.last_interaction = 0
  pet.happiness = 0
  pet.mood = "idle"
  pet.mood_until = 0
  pet.show_tooltip = false
  pet.phase_msg = phase_msg or "Starting..."
  pet.percent = nil
  pet.error_msg = nil
end

function pet.stop()
  pet.active = false
end

function pet.set_error(msg)
  pet.error_msg = msg
  pet.mood = "sad"
  pet.mood_until = system.get_time() + 10 -- Show sad face for errors
end

function pet.update_progress(phase_msg, percent)
  if phase_msg then pet.phase_msg = phase_msg end
  if percent then pet.percent = percent end
end

-- internal interaction handler, tied directly to keypress intercept
local function interact(action)
  local t = system.get_time()
  -- Rate limit: 3 seconds between actions
  if t - pet.last_interaction < 3 then return end
  pet.last_interaction = t

  if action == "feed" then
    pet.mood = "feed"
    pet.mood_until = t + 1.5
    pet.happiness = pet.happiness + 1
  elseif action == "poke" then
    pet.mood = "poke"
    pet.mood_until = t + 1.5
    pet.happiness = math.max(0, pet.happiness - 1)
  end
  core.redraw = true
end

function pet.on_keypressed(key)
  if not pet.active then return false end

  if key == "f" then
    interact("feed")
    return true
  elseif key == "p" then
    interact("poke")
    return true
  elseif key == "?" or key == "shift+/" then
    pet.show_tooltip = not pet.show_tooltip
    core.redraw = true
    return true
  end
  return false
end

-- Determine frame purely from system time (avoids core.timer memory leaks)
local function get_frame()
  local t = system.get_time()

  if pet.error_msg then
    return ASCII_FRAMES.sad
  end

  -- Restore idle mood if interaction expired
  if pet.mood ~= "idle" and t >= pet.mood_until then
    -- happiness only affects cosmetic mood, it doesn't change actual growth stage
    if pet.happiness > 3 and pet.mood ~= "sad" then
      pet.mood = "happy"
      pet.mood_until = t + 10
      pet.happiness = 0 -- consume happiness to stay happy for 10s
    else
      pet.mood = "idle"
    end
  end

  -- Determine growth stage (progress locked)
  -- Real codespace startup takes ~4 minutes (240s)
  local elapsed = t - pet.start_time
  local stage = "egg"

  -- If we explicitly pass 100% completion
  if pet.percent and pet.percent >= 100 then
    return ASCII_FRAMES.celebrating
  end

  -- Fallback to time-based growth if no percent is available
  if pet.percent then
    if pet.percent > 80 then stage = "adult"
    elseif pet.percent > 50 then stage = "juvenile"
    elseif pet.percent > 20 then stage = "hatchling"
    end
  else
    if elapsed > 192 then -- > 80% (3.2 min)
      stage = "adult"
    elseif elapsed > 120 then -- > 50% (2 min)
      stage = "juvenile"
    elseif elapsed > 48 then -- > 20%
      stage = "hatchling"
    end
  end

  -- Frame swapping (idle animation ~600ms)
  local frame_idx = math.floor(t / 0.6) % 2 == 0

  local frame = ASCII_FRAMES[stage]
  if pet.mood == "feed" then
    frame = ASCII_FRAMES.feed
  elseif pet.mood == "poke" then
    frame = ASCII_FRAMES.poke
  elseif pet.mood == "happy" then
    frame = ASCII_FRAMES.happy
  else
    if frame_idx then
      frame = ASCII_FRAMES[stage .. "_alt"] or frame
    end
  end

  return frame
end

function pet.draw(x, y, w, h)
  if not pet.active then return end

  local frame = get_frame()
  local pet_font = style.code_font or style.font
  local line_h = pet_font:get_height()

  -- Measure frame dimensions
  local max_w = 0
  for _, line in ipairs(frame) do
    max_w = math.max(max_w, pet_font:get_width(line))
  end
  local total_h = #frame * line_h

  -- Draw centered
  local start_x = x + (w - max_w) / 2
  local start_y = y + (h - total_h) / 2 - 20 * SCALE

  for i, line in ipairs(frame) do
    renderer.draw_text(pet_font, line, start_x, start_y + (i - 1) * line_h, style.text)
  end

  -- Draw instructions below pet
  local inst_y = start_y + total_h + 20 * SCALE
  local inst = "Press [f] to feed | [p] to poke | [?] info"
  local inst_w = style.font:get_width(inst)
  renderer.draw_text(style.font, inst, x + (w - inst_w)/2, inst_y, {150, 150, 150, 255})

  -- Draw tooltip if active
  if pet.show_tooltip then
    local elapsed = math.floor(system.get_time() - pet.start_time)
    local mins = math.floor(elapsed / 60)
    local secs = elapsed % 60
    local ttip = string.format("Elapsed: %d:%02d / Phase: %s", mins, secs, pet.phase_msg)
    local tt_w = style.font:get_width(ttip)
    renderer.draw_text(style.font, ttip, x + (w - tt_w)/2, inst_y + 30 * SCALE, style.accent)
  end

  -- Draw error if active
  if pet.error_msg then
    local err_w = style.font:get_width(pet.error_msg)
    renderer.draw_text(style.font, pet.error_msg, x + (w - err_w)/2, inst_y + 50 * SCALE, {255, 100, 100, 255})
  end

  -- Force continuous redraw to drive animations without timers
  core.redraw = true
end

return pet
