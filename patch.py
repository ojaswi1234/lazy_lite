import re

file_path = r"C:\Users\ojasw\.config\lite-xl\plugins\antigravity_sidebar.lua"

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# We want to replace the single-line input rendering block with our multi-line one.

# Step 1: Insert wrap_input_text before AGView:draw
wrap_func = '''
local function wrap_input_text(font, text, max_w)
  local lines = {}
  if text == "" then
    return {{ text = "", start_byte = 1, end_byte = 0, has_nl = false }}
  end
  
  local line_start = 1
  local line_str = ""
  local current_byte = 1
  
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if char == "\\n" then
      table.insert(lines, { text = line_str, start_byte = line_start, end_byte = current_byte - 1, has_nl = true })
      line_start = current_byte + 1
      line_str = ""
    else
      if font:get_width(line_str .. char) > max_w and #line_str > 0 then
        table.insert(lines, { text = line_str, start_byte = line_start, end_byte = current_byte - 1, has_nl = false })
        line_start = current_byte
        line_str = char
      else
        line_str = line_str .. char
      end
    end
    current_byte = current_byte + #char
  end
  table.insert(lines, { text = line_str, start_byte = line_start, end_byte = #text, has_nl = false })
  return lines
end
'''

if "wrap_input_text" not in content:
    content = content.replace("function AGView:draw()", wrap_func + "\nfunction AGView:draw()")

# Step 2: Replace the input area block
# We find the block starting with "local send_h   = 30 * SCALE"
# and ending before "-- Hint text bottom-right of input"

old_block = r'''  local send_h   = 30 * SCALE
  local input_h  = 56 * SCALE
  local bottom_h = input_h + send_h + 3 * pad
  local chat_bot = y + h - bottom_h

  -- Divider above input
  renderer.draw_rect(x, chat_bot, w, 1, P.border)

  -- Input box
  local inp_x = x + pad
  local inp_y = chat_bot + pad
  local inp_w = w - 2 * pad
  renderer.draw_rect(inp_x, inp_y, inp_w, input_h, P.bg_input)
  draw_rect_outline(inp_x, inp_y, inp_w, input_h,
    core.active_view == self and P.border_input or P.border)

  -- Placeholder / typed text
  local display    = #self:state().input > 0 and self:state().input or "Ask anything about your code."
  local fg_inp     = #self:state().input > 0 and P.fg or P.fg_muted

  local max_text_w = inp_w - 16 * SCALE
  local cursor_idx = self:state().cursor or #self:state().input
  local cursor_x   = style.font:get_width(self:state().input:sub(1, cursor_idx))
  local tx         = inp_x + 8 * SCALE
  if core.active_view == self and cursor_x > max_text_w then
    tx = tx - (cursor_x - max_text_w)
  end

  core.push_clip_rect(inp_x, inp_y, inp_w, input_h)
  renderer.draw_text(style.font, display, tx, inp_y + 8 * SCALE, fg_inp)

  -- Blink cursor
  if core.active_view == self and math.floor(self.tick / 30) % 2 == 0 then
    local cw = #self:state().input > 0 and cursor_x or style.font:get_width(display)
    if #self:state().input == 0 then cw = 0 end
    renderer.draw_rect(tx + cw, inp_y + 8 * SCALE, 2 * SCALE, style.font:get_height(), P.fg_accent)
  end
  core.pop_clip_rect()'''

new_block = r'''  local send_h   = 30 * SCALE
  local inp_x = x + pad
  local inp_w = w - 2 * pad
  local max_text_w = inp_w - 16 * SCALE

  local display_text = #self:state().input > 0 and self:state().input or "Ask anything about your code."
  local wrapped_lines = wrap_input_text(style.font, display_text, max_text_w)
  
  local line_h = style.font:get_height()
  local num_lines = #wrapped_lines
  local max_lines = 10
  local visible_lines = math.min(num_lines, max_lines)
  local input_text_h = visible_lines * line_h
  
  local input_pad_y = 8 * SCALE
  local hint_h = 10 * SCALE
  local input_h = input_text_h + (input_pad_y * 2) + hint_h
  
  local bottom_h = input_h + send_h + 3 * pad
  local chat_bot = y + h - bottom_h

  -- Divider above input
  renderer.draw_rect(x, chat_bot, w, 1, P.border)

  -- Input box
  local inp_y = chat_bot + pad
  renderer.draw_rect(inp_x, inp_y, inp_w, input_h, P.bg_input)
  draw_rect_outline(inp_x, inp_y, inp_w, input_h,
    core.active_view == self and P.border_input or P.border)

  local fg_inp = #self:state().input > 0 and P.fg or P.fg_muted

  local cursor_idx = self:state().cursor or #self:state().input
  local cursor_x = 0
  local cursor_y_idx = 1
  
  for i, line in ipairs(wrapped_lines) do
    cursor_y_idx = i
    if not line.has_nl and cursor_idx == line.end_byte and i < #wrapped_lines then
      cursor_x = style.font:get_width(line.text)
      break
    elseif cursor_idx >= line.start_byte and cursor_idx <= line.end_byte then
      local sub_len = cursor_idx - line.start_byte + 1
      cursor_x = style.font:get_width(line.text:sub(1, sub_len))
      break
    elseif line.has_nl and cursor_idx == line.end_byte then
      cursor_x = style.font:get_width(line.text)
      break
    elseif cursor_idx < line.start_byte then
      cursor_x = 0
      break
    end
  end
  
  if not self:state().input_scroll_y then self:state().input_scroll_y = 0 end
  
  local tx = inp_x + 8 * SCALE
  local cursor_y_pos = (cursor_y_idx - 1) * line_h
  if core.active_view == self then
    if cursor_y_pos < self:state().input_scroll_y then
      self:state().input_scroll_y = cursor_y_pos
    elseif cursor_y_pos + line_h > self:state().input_scroll_y + input_text_h then
      self:state().input_scroll_y = cursor_y_pos + line_h - input_text_h
    end
  end
  
  core.push_clip_rect(inp_x, inp_y, inp_w, input_text_h + (input_pad_y * 2))
  for i, line in ipairs(wrapped_lines) do
    local ly = inp_y + input_pad_y + (i - 1) * line_h - self:state().input_scroll_y
    if ly + line_h >= inp_y and ly <= inp_y + input_h then
      renderer.draw_text(style.font, line.text, tx, ly, fg_inp)
    end
  end

  -- Blink cursor
  if core.active_view == self and math.floor(self.tick / 30) % 2 == 0 then
    local cw = #self:state().input > 0 and cursor_x or style.font:get_width(display_text)
    if #self:state().input == 0 then cw = 0 end
    local cy = inp_y + input_pad_y + (cursor_y_idx - 1) * line_h - self:state().input_scroll_y
    renderer.draw_rect(tx + cw, cy, 2 * SCALE, line_h, P.fg_accent)
  end
  core.pop_clip_rect()'''

if old_block in content:
    content = content.replace(old_block, new_block)
    with open(file_path, "w", encoding="utf-8") as f:
        f.write(content)
    print("PATCH APPLIED SUCCESSFULLY")
else:
    print("OLD BLOCK NOT FOUND. MAYBE ALREADY PATCHED?")
