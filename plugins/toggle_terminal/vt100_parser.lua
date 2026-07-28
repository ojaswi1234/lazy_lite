-- vt100_parser.lua
-- A highly optimized, regex-free, state-machine-based VT100 ANSI escape code parser in Lua.
-- This module implements a virtual 2D grid that represents a terminal emulator's screen.

local STATE_GROUND      = 0
local STATE_ESCAPE      = 1
local STATE_CSI_ENTRY   = 2
local STATE_CSI_PARAM   = 3

local Terminal = {}
Terminal.__index = Terminal

-- Create a new terminal emulator instance
function Terminal.new(cols, rows)
  local self = setmetatable({}, Terminal)
  self.cols = cols
  self.rows = rows
  self.grid = {}
  self.cursor_x = 1
  self.cursor_y = 1
  
  -- SGR (Select Graphic Rendition) attributes
  self.attr = { fg = 7, bg = 0, bold = false }
  
  self.scrollback = {}
  self.max_scrollback = 10000
  
  for y = 1, rows do
    self.grid[y] = self:empty_line()
  end
  
  -- State machine variables
  self.state = STATE_GROUND
  self.params = {}
  self.param_val = 0
  self.has_param = false
  
  return self
end

function Terminal:empty_line_for_cols(cols)
  local line = {}
  for x = 1, cols do
    line[x] = { char = ' ', attr = { fg = self.attr.fg, bg = self.attr.bg, bold = self.attr.bold } }
  end
  return line
end

function Terminal:empty_line()
  return self:empty_line_for_cols(self.cols)
end

function Terminal:resize(cols, rows)
  if self.cols == cols and self.rows == rows then return end
  
  if rows > self.rows then
    for y = self.rows + 1, rows do
      self.grid[y] = self:empty_line_for_cols(cols)
    end
  elseif rows < self.rows then
    for y = rows + 1, self.rows do
      self.grid[y] = nil
    end
    if self.cursor_y > rows then self.cursor_y = rows end
  end
  
  for y = 1, rows do
    local row = self.grid[y]
    if row then
      if cols > self.cols then
        for x = self.cols + 1, cols do
          row[x] = { char = ' ', attr = { fg = self.attr.fg, bg = self.attr.bg, bold = self.attr.bold } }
        end
      elseif cols < self.cols then
        for x = cols + 1, self.cols do
          row[x] = nil
        end
      end
    end
  end
  
  if self.cursor_x > cols then self.cursor_x = cols end
  
  self.cols = cols
  self.rows = rows
end

-- Process a raw string of ANSI data byte-by-byte
function Terminal:feed(data)
  for i = 1, #data do
    local b = string.byte(data, i)
    self:process_byte(b)
  end
end

-- Core state machine logic based on Paul Williams' DEC ANSI Parser
function Terminal:process_byte(b)
  -- Immediate interrupt for ESC
  if b == 0x1B then
    self.state = STATE_ESCAPE
    return
  end
  
  if self.state == STATE_GROUND then
    if b >= 0x20 and b <= 0x7E then -- Printable ASCII
      self:print_char(string.char(b))
    elseif b == 0x0A or b == 0x0B or b == 0x0C then -- LF, VT, FF
      self:line_feed()
    elseif b == 0x0D then -- CR
      self.cursor_x = 1
    elseif b == 0x08 then -- BS
      if self.cursor_x > 1 then self.cursor_x = self.cursor_x - 1 end
    end
    
  elseif self.state == STATE_ESCAPE then
    if b == 0x5B then -- '[' (CSI Entry)
      self.state = STATE_CSI_ENTRY
      self.params = {}
      self.param_val = 0
      self.has_param = false
    else
      -- Unhandled ESC sequence, fallback to ground
      self.state = STATE_GROUND
    end
    
  elseif self.state == STATE_CSI_ENTRY or self.state == STATE_CSI_PARAM then
    if b >= 0x30 and b <= 0x39 then -- '0'-'9'
      self.param_val = self.param_val * 10 + (b - 0x30)
      self.has_param = true
      self.state = STATE_CSI_PARAM
    elseif b == 0x3B then -- ';'
      table.insert(self.params, self.has_param and self.param_val or 0)
      self.param_val = 0
      self.has_param = false
      self.state = STATE_CSI_PARAM
    elseif b >= 0x40 and b <= 0x7E then -- Dispatch action
      if self.has_param then
        table.insert(self.params, self.param_val)
      elseif self.state == STATE_CSI_PARAM then
        -- Handle trailing semicolon (e.g. \x1b[1;m)
        table.insert(self.params, 0)
      end
      self:dispatch_csi(b)
      self.state = STATE_GROUND
    end
  end
end

function Terminal:print_char(c)
  local cell = self.grid[self.cursor_y][self.cursor_x]
  if cell then
    cell.char = c
    cell.attr.fg = self.attr.fg
    cell.attr.bg = self.attr.bg
    cell.attr.bold = self.attr.bold
  end
  self.cursor_x = self.cursor_x + 1
  if self.cursor_x > self.cols then
    self.cursor_x = self.cols -- Simple clamp. Real terminals wrap to col 1, row+1
  end
end

function Terminal:line_feed()
  if self.cursor_y < self.rows then
    self.cursor_y = self.cursor_y + 1
  else
    -- Scroll up
    local top_line = table.remove(self.grid, 1)
    table.insert(self.scrollback, top_line)
    if #self.scrollback > self.max_scrollback then
      table.remove(self.scrollback, 1)
    end
    table.insert(self.grid, self:empty_line())
  end
end

function Terminal:dispatch_csi(action)
  local char = string.char(action)
  
  if char == 'H' or char == 'f' then -- CUP / HVP (Cursor Position)
    local row = self.params[1] or 1
    local col = self.params[2] or 1
    if row < 1 then row = 1 end
    if col < 1 then col = 1 end
    self.cursor_y = math.min(row, self.rows)
    self.cursor_x = math.min(col, self.cols)
    
  elseif char == 'A' then -- CUU (Cursor Up)
    local n = self.params[1] or 1
    if n == 0 then n = 1 end
    self.cursor_y = math.max(1, self.cursor_y - n)
    
  elseif char == 'B' then -- CUD (Cursor Down)
    local n = self.params[1] or 1
    if n == 0 then n = 1 end
    self.cursor_y = math.min(self.rows, self.cursor_y + n)
    
  elseif char == 'C' then -- CUF (Cursor Forward)
    local n = self.params[1] or 1
    if n == 0 then n = 1 end
    self.cursor_x = math.min(self.cols, self.cursor_x + n)
    
  elseif char == 'D' then -- CUB (Cursor Backward)
    local n = self.params[1] or 1
    if n == 0 then n = 1 end
    self.cursor_x = math.max(1, self.cursor_x - n)
    
  elseif char == 'J' then -- ED (Erase in Display)
    local n = self.params[1] or 0
    if n == 0 then
      -- Clear from cursor to end of screen
      for x = self.cursor_x, self.cols do self:clear_cell(x, self.cursor_y) end
      for y = self.cursor_y + 1, self.rows do
        for x = 1, self.cols do self:clear_cell(x, y) end
      end
    elseif n == 1 then
      -- Clear from beginning to cursor
      for y = 1, self.cursor_y - 1 do
        for x = 1, self.cols do self:clear_cell(x, y) end
      end
      for x = 1, self.cursor_x do self:clear_cell(x, self.cursor_y) end
    elseif n == 2 then
      -- Clear entire screen
      for y = 1, self.rows do
        for x = 1, self.cols do self:clear_cell(x, y) end
      end
    end
    
  elseif char == 'K' then -- EL (Erase in Line)
    local n = self.params[1] or 0
    if n == 0 then
      for x = self.cursor_x, self.cols do self:clear_cell(x, self.cursor_y) end
    elseif n == 1 then
      for x = 1, self.cursor_x do self:clear_cell(x, self.cursor_y) end
    elseif n == 2 then
      for x = 1, self.cols do self:clear_cell(x, self.cursor_y) end
    end
    
  elseif char == 'm' then -- SGR (Select Graphic Rendition - Colors/Bold)
    if #self.params == 0 then self.params = {0} end
    for _, param in ipairs(self.params) do
      if param == 0 then
        self.attr = { fg = 7, bg = 0, bold = false }
      elseif param == 1 then
        self.attr.bold = true
      elseif param >= 30 and param <= 37 then
        self.attr.fg = param - 30
      elseif param >= 40 and param <= 47 then
        self.attr.bg = param - 40
      end
    end
  end
end

function Terminal:clear_cell(x, y)
  local cell = self.grid[y][x]
  if cell then
    cell.char = ' '
    cell.attr = { fg = self.attr.fg, bg = self.attr.bg, bold = self.attr.bold }
  end
end

-- Helper to render the screen as a text string (for debugging)
function Terminal:render_text()
  local lines = {}
  for y = 1, self.rows do
    local str = ""
    for x = 1, self.cols do
      str = str .. self.grid[y][x].char
    end
    table.insert(lines, str)
  end
  return table.concat(lines, "\n")
end

function Terminal:get_absolute_line(y)
  if y <= #self.scrollback then
    return self.scrollback[y]
  else
    return self.grid[y - #self.scrollback]
  end
end

return Terminal
