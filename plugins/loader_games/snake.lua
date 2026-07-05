-- mod-version:3
local core = require "core"
local style = require "core.style"

local snake = {}

function snake.start()
  snake.cell_size = 14 * SCALE
  snake.body = {{x = 10, y = 10}}
  snake.dir = {x = 1, y = 0}
  snake.next_dir = {x = 1, y = 0}
  snake.food = {x = 15, y = 10}
  snake.dead = false
  snake.move_timer = 0
  snake.move_delay = 0.1
  snake.score = 0
  snake.w = 0
  snake.h = 0
end

function snake.spawn_food()
  if snake.w == 0 or snake.h == 0 then return end
  local cols = math.floor(snake.w / snake.cell_size)
  local rows = math.floor(snake.h / snake.cell_size)
  
  local valid = false
  local fx, fy
  for i=1, 100 do
    fx = math.random(0, cols - 1)
    fy = math.random(0, rows - 1)
    local col = false
    for _, b in ipairs(snake.body) do
      if b.x == fx and b.y == fy then col = true break end
    end
    if not col then valid = true break end
  end
  if valid then
    snake.food.x = fx
    snake.food.y = fy
  end
end

function snake.update(dt)
  if snake.dead or snake.w == 0 or snake.h == 0 then return end
  snake.move_timer = snake.move_timer + dt
  if snake.move_timer >= snake.move_delay then
    snake.move_timer = 0
    snake.dir.x = snake.next_dir.x
    snake.dir.y = snake.next_dir.y
    
    local head = snake.body[1]
    local nx = head.x + snake.dir.x
    local ny = head.y + snake.dir.y
    
    -- self collision
    for i = 1, #snake.body do
      if snake.body[i].x == nx and snake.body[i].y == ny then
        snake.dead = true
        return
      end
    end
    
    -- wall collision
    local cols = math.floor(snake.w / snake.cell_size)
    local rows = math.floor(snake.h / snake.cell_size)
    if nx < 0 or nx >= cols or ny < 0 or ny >= rows then
      snake.dead = true
      return
    end
    
    table.insert(snake.body, 1, {x = nx, y = ny})
    
    if nx == snake.food.x and ny == snake.food.y then
      snake.score = snake.score + 1
      snake.spawn_food()
    else
      table.remove(snake.body)
    end
  end
end

function snake.draw(x, y, w, h)
  -- wait to spawn food until first draw gives us bounds
  if snake.w == 0 then
    snake.w = w
    snake.h = h
    snake.spawn_food()
  end
  snake.w = w
  snake.h = h
  
  local cs = snake.cell_size
  
  -- Draw food
  if snake.food.x then
    renderer.draw_rect(x + snake.food.x * cs, y + snake.food.y * cs, cs, cs, style.accent)
  end
  
  -- Draw snake
  for i, b in ipairs(snake.body) do
    local color = (i == 1) and style.text or style.dim
    renderer.draw_rect(x + b.x * cs, y + b.y * cs, cs - 1, cs - 1, color)
  end
  
  -- Draw score
  renderer.draw_text(style.font, "Score: " .. snake.score, x + 10 * SCALE, y + 10 * SCALE, style.text)
  
  if snake.dead then
    local msg = "Game Over! Press any key to restart"
    local mw = style.font:get_width(msg)
    renderer.draw_text(style.font, msg, x + (w - mw)/2, y + (h - style.font:get_height())/2, {255,100,100,255})
  end
end

function snake.on_keypressed(key)
  if snake.dead then
    snake.start()
    return true
  end
  
  if (key == "up" or key == "w") and snake.dir.y == 0 then snake.next_dir = {x=0, y=-1}; return true end
  if (key == "down" or key == "s") and snake.dir.y == 0 then snake.next_dir = {x=0, y=1}; return true end
  if (key == "left" or key == "a") and snake.dir.x == 0 then snake.next_dir = {x=-1, y=0}; return true end
  if (key == "right" or key == "d") and snake.dir.x == 0 then snake.next_dir = {x=1, y=0}; return true end
  return false
end

function snake.is_finished()
  return snake.dead
end

return snake
