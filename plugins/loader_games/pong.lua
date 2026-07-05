-- mod-version:3
local core = require "core"
local style = require "core.style"

local pong = {}

function pong.start()
  pong.paddle_w = 10 * SCALE
  pong.paddle_h = 60 * SCALE
  pong.p1_y = 0
  pong.p2_y = 0
  pong.ball = {x=0, y=0, vx=-200 * SCALE, vy=150 * SCALE, size=10 * SCALE}
  pong.score = {p1 = 0, p2 = 0}
  pong.state = "playing" -- playing, scored, over
  pong.delay_timer = 0
  pong.w = 0
  pong.h = 0
end

function pong.update(dt)
  if pong.state == "scored" then
    pong.delay_timer = pong.delay_timer - dt
    if pong.delay_timer <= 0 then
      if pong.score.p1 >= 5 or pong.score.p2 >= 5 then
        pong.state = "over"
        pong.delay_timer = 2.0
      else
        pong.state = "playing"
        pong.ball.x = pong.w / 2
        pong.ball.y = pong.h / 2
        pong.ball.vx = (math.random() > 0.5 and 1 or -1) * 200 * SCALE
        pong.ball.vy = (math.random() > 0.5 and 1 or -1) * 150 * SCALE
      end
    end
    return
  elseif pong.state == "over" then
    pong.delay_timer = pong.delay_timer - dt
    if pong.delay_timer <= 0 then
      pong.start()
    end
    return
  end
  
  if pong.w == 0 or pong.h == 0 then return end
  
  -- ball movement
  pong.ball.x = pong.ball.x + pong.ball.vx * dt
  pong.ball.y = pong.ball.y + pong.ball.vy * dt
  
  -- top/bottom bounce
  if pong.ball.y <= 0 then
    pong.ball.y = 0
    pong.ball.vy = math.abs(pong.ball.vy)
  elseif pong.ball.y + pong.ball.size >= pong.h then
    pong.ball.y = pong.h - pong.ball.size
    pong.ball.vy = -math.abs(pong.ball.vy)
  end
  
  -- AI paddle (right)
  local target_y = pong.ball.y - pong.paddle_h / 2
  local ai_speed = 180 * SCALE
  if pong.p2_y < target_y - 5 * SCALE then
    pong.p2_y = pong.p2_y + ai_speed * dt
  elseif pong.p2_y > target_y + 5 * SCALE then
    pong.p2_y = pong.p2_y - ai_speed * dt
  end
  pong.p2_y = math.max(0, math.min(pong.p2_y, pong.h - pong.paddle_h))
  
  -- Paddle collisions
  -- P1 (left)
  if pong.ball.x <= pong.paddle_w and pong.ball.y + pong.ball.size >= pong.p1_y and pong.ball.y <= pong.p1_y + pong.paddle_h then
    pong.ball.x = pong.paddle_w
    pong.ball.vx = math.abs(pong.ball.vx) * 1.1 -- ramp up speed
  end
  
  -- P2 (right)
  if pong.ball.x + pong.ball.size >= pong.w - pong.paddle_w and pong.ball.y + pong.ball.size >= pong.p2_y and pong.ball.y <= pong.p2_y + pong.paddle_h then
    pong.ball.x = pong.w - pong.paddle_w - pong.ball.size
    pong.ball.vx = -math.abs(pong.ball.vx) * 1.1
  end
  
  -- Scoring
  if pong.ball.x < 0 then
    pong.score.p2 = pong.score.p2 + 1
    pong.state = "scored"
    pong.delay_timer = 1.0
  elseif pong.ball.x > pong.w then
    pong.score.p1 = pong.score.p1 + 1
    pong.state = "scored"
    pong.delay_timer = 1.0
  end
end

function pong.draw(x, y, w, h)
  -- wait to set initial pos until first draw
  if pong.w == 0 then
    pong.w = w
    pong.h = h
    pong.ball.x = w / 2
    pong.ball.y = h / 2
    pong.p1_y = (h - pong.paddle_h) / 2
    pong.p2_y = (h - pong.paddle_h) / 2
  end
  pong.w = w
  pong.h = h
  
  -- Draw center line
  renderer.draw_rect(x + w/2 - 1, y, 2, h, {style.dim[1], style.dim[2], style.dim[3], 100})
  
  -- Draw P1
  renderer.draw_rect(x, y + pong.p1_y, pong.paddle_w, pong.paddle_h, style.text)
  -- Draw P2
  renderer.draw_rect(x + w - pong.paddle_w, y + pong.p2_y, pong.paddle_w, pong.paddle_h, style.text)
  -- Draw Ball
  renderer.draw_rect(x + pong.ball.x, y + pong.ball.y, pong.ball.size, pong.ball.size, style.accent)
  
  -- Draw Score
  local score_text = pong.score.p1 .. "   " .. pong.score.p2
  local score_font = style.big_font or style.font
  local sw = score_font:get_width(score_text)
  renderer.draw_text(score_font, score_text, x + (w - sw)/2, y + 20 * SCALE, style.dim)
  
  if pong.state == "over" then
    local msg = pong.score.p1 >= 5 and "You Win!" or "You Lose!"
    local mw = style.font:get_width(msg)
    renderer.draw_text(style.font, msg, x + (w - mw)/2, y + h/2, style.text)
  end
end

function pong.on_keypressed(key)
  local step = 30 * SCALE
  if key == "up" or key == "w" then
    pong.p1_y = math.max(0, pong.p1_y - step)
    return true
  elseif key == "down" or key == "s" then
    pong.p1_y = math.min(pong.h - pong.paddle_h, pong.p1_y + step)
    return true
  end
  return false
end

function pong.is_finished()
  return pong.state == "over"
end

return pong
