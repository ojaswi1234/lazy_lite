-- mod-version:3
-- Google Colab Notebook Cell Editor View
-- Custom view for displaying and editing Jupyter notebook cells

local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local command = require "core.command"
local keymap = require "core.keymap"
local tokenizer = require "core.tokenizer"
local syntax = require "core.syntax"
-- renderer is global

-- Cell types
local CELL_TYPE_MARKDOWN = "markdown"
local CELL_TYPE_CODE = "code"

-- NotebookView class
local NotebookView = View:extend()

function NotebookView:new()
  NotebookView.super.new(self)
  self.notebook_data = {
    cells = {},
    metadata = {},
    nbformat = 4,
    nbformat_minor = 0
  }
  self.selected_cell_index = 1
  self.editing_cell_index = nil
  self.cell_heights = {}
  self.scroll_y = 0
  self.scrollbar_visible = false
  self.output_cache = {}
  self.runtime_status = "disconnected"
  self.runtime_type = "CPU"
end

function NotebookView:set_notebook_data(data)
  self.notebook_data = data or {
    cells = {},
    metadata = {},
    nbformat = 4,
    nbformat_minor = 0
  }
  self.selected_cell_index = 1
  self.editing_cell_index = nil
  self.cell_heights = {}
  self.output_cache = {}
  self:calculate_cell_heights()
end

function NotebookView:get_cell_count()
  return #self.notebook_data.cells
end

function NotebookView:get_cell(index)
  return self.notebook_data.cells[index]
end

function NotebookView:add_cell(cell_type, index)
  index = index or (self.selected_cell_index + 1)
  local new_cell = {
    cell_type = cell_type or CELL_TYPE_CODE,
    metadata = {},
    source = {""},
    execution_count = nil,
    outputs = {}
  }
  table.insert(self.notebook_data.cells, index, new_cell)
  self.selected_cell_index = index
  self.editing_cell_index = index
  self:calculate_cell_heights()
  return new_cell
end

function NotebookView:delete_cell(index)
  index = index or self.selected_cell_index
  if #self.notebook_data.cells > 1 then
    table.remove(self.notebook_data.cells, index)
    self.selected_cell_index = math.min(index, #self.notebook_data.cells)
    self.editing_cell_index = nil
    self:calculate_cell_heights()
  end
end

function NotebookView:move_cell(index, direction)
  index = index or self.selected_cell_index
  local new_index = index + direction
  
  if new_index >= 1 and new_index <= #self.notebook_data.cells then
    local cell = table.remove(self.notebook_data.cells, index)
    table.insert(self.notebook_data.cells, new_index, cell)
    self.selected_cell_index = new_index
    self:calculate_cell_heights()
  end
end

function NotebookView:calculate_cell_heights()
  self.cell_heights = {}
  local total_height = 0
  
  for i, cell in ipairs(self.notebook_data.cells) do
    local height = self:get_cell_height(cell)
    self.cell_heights[i] = height
    total_height = total_height + height
  end
  
  return total_height
end

function NotebookView:get_cell_height(cell)
  local base_height = 60 -- minimum cell height
  local line_height = style.code_font:get_height()
  
  -- Calculate height based on content
  local source_lines = cell.source or {""}
  local content_height = #source_lines * line_height + 20 -- padding
  
  -- Add output height if present
  local output_height = 0
  if cell.outputs and #cell.outputs > 0 then
    output_height = self:get_output_height(cell.outputs)
  end
  
  return base_height + content_height + output_height
end

function NotebookView:get_output_height(outputs)
  local height = 20 -- base output area height
  local line_height = style.code_font:get_height()
  
  for _, output in ipairs(outputs) do
    if output.output_type == "stream" then
      local lines = output.text or {}
      if type(lines) == "string" then
        lines = {lines}
      end
      height = height + #lines * line_height
    elseif output.output_type == "execute_result" or output.output_type == "display_data" then
      -- Estimate height for rich output
      height = height + 100
    elseif output.output_type == "error" then
      local traceback = output.traceback or {}
      height = height + #traceback * line_height
    end
  end
  
  return height
end

function NotebookView:get_total_height()
  local total = 0
  for _, height in ipairs(self.cell_heights) do
    total = total + height
  end
  return total
end

function NotebookView:get_cell_y_position(index)
  local y = 0
  for i = 1, index - 1 do
    y = y + (self.cell_heights[i] or 60)
  end
  return y
end

function NotebookView:get_cell_at_position(y)
  local cumulative = 0
  for i, height in ipairs(self.cell_heights) do
    cumulative = cumulative + height
    if y <= cumulative then
      return i
    end
  end
  return #self.notebook_data.cells
end

function NotebookView:scroll_to_cell(index)
  local cell_y = self:get_cell_y_position(index)
  local cell_height = self.cell_heights[index] or 60
  
  if cell_y < self.scroll_y then
    self.scroll_y = cell_y
  elseif cell_y + cell_height > self.scroll_y + self.size.y then
    self.scroll_y = cell_y + cell_height - self.size.y
  end
end

function NotebookView:update_output(cell_index, outputs)
  local cell = self.notebook_data.cells[cell_index]
  if cell then
    cell.outputs = outputs
    self.output_cache[cell_index] = outputs
    self:calculate_cell_heights()
  end
end

function NotebookView:set_runtime_status(status, runtime_type)
  self.runtime_status = status
  self.runtime_type = runtime_type or "CPU"
end

-- Drawing functions
function NotebookView:draw_cell_background(x, y, w, h, is_selected, is_editing)
  local color = style.background2
  if is_selected then
    color = style.mossy.active_row or {191, 211, 167}
  end
  if is_editing then
    color = style.background3
  end
  
  renderer.draw_rect(x, y, w, h, color)
  
  -- Draw cell border
  local border_color = is_selected and style.accent or style.divider
  renderer.draw_rect(x, y, w, 1, border_color)
  renderer.draw_rect(x, y + h - 1, w, 1, border_color)
end

function NotebookView:draw_cell_header(x, y, w, cell, index)
  local font = style.font
  local padding = 5
  
  -- Cell type indicator
  local type_text = cell.cell_type == CELL_TYPE_MARKDOWN and "Markdown" or "Code"
  local type_color = cell.cell_type == CELL_TYPE_MARKDOWN and style.dim or style.accent
  
  renderer.draw_text(font, type_text, x + padding, y + padding, type_color)
  
  -- Cell index
  renderer.draw_text(font, tostring(index), x + w - padding - font:get_width(tostring(index)), y + padding, style.dim)
  
  -- Execution count for code cells
  if cell.cell_type == CELL_TYPE_CODE and cell.execution_count then
    local exec_text = "[✓ " .. tostring(cell.execution_count) .. "]"
    renderer.draw_text(font, exec_text, x + padding + font:get_width(type_text) + 10, y + padding, style.accent)
  end
end

function NotebookView:draw_cell_content(x, y, w, h, cell, is_editing)
  local font = is_editing and style.code_font or style.font
  local padding = 10
  local line_height = font:get_height()
  
  local source_lines = cell.source or {""}
  for i, line in ipairs(source_lines) do
    local line_y = y + padding + (i - 1) * line_height
    renderer.draw_text(font, line, x + padding, line_y, style.text)
  end
end

function NotebookView:draw_cell_output(x, y, w, cell)
  if not cell.outputs or #cell.outputs == 0 then
    return
  end
  
  local font = style.code_font
  local padding = 10
  local line_height = font:get_height()
  local output_y = y + 10
  
  -- Draw output separator
  renderer.draw_rect(x, output_y, w, 1, style.divider)
  output_y = output_y + 5
  
  for _, output in ipairs(cell.outputs) do
    if output.output_type == "stream" then
      local lines = output.text or {}
      if type(lines) == "string" then
        lines = {lines}
      end
      for _, line in ipairs(lines) do
        renderer.draw_text(font, line, x + padding, output_y, style.dim)
        output_y = output_y + line_height
      end
    elseif output.output_type == "error" then
      local traceback = output.traceback or {}
      for _, line in ipairs(traceback) do
        renderer.draw_text(font, line, x + padding, output_y, {255, 100, 100})
        output_y = output_y + line_height
      end
    elseif output.output_type == "execute_result" or output.output_type == "display_data" then
      -- Simplified rich output rendering
      renderer.draw_text(font, "[Rich output - not fully rendered]", x + padding, output_y, style.dim)
      output_y = output_y + line_height
    end
  end
end

function NotebookView:draw_runtime_status(x, y, w)
  local font = style.font
  local padding = 5
  
  local status_text = "Runtime: " .. self.runtime_status
  if self.runtime_status == "connected" then
    status_text = status_text .. " (" .. self.runtime_type .. ")"
  end
  
  local status_color = self.runtime_status == "connected" and style.accent or style.dim
  renderer.draw_text(font, status_text, x + padding, y + padding, status_color)
end

function NotebookView:draw()
  self:draw_background(style.background)
  
  local x, y, w, h = self:get_content_bounds()
  local current_y = -self.scroll_y
  
  -- Draw runtime status
  self:draw_runtime_status(x, 0, w)
  current_y = current_y + 30
  
  -- Draw cells
  for i, cell in ipairs(self.notebook_data.cells) do
    local cell_height = self.cell_heights[i] or 60
    local is_selected = (i == self.selected_cell_index)
    local is_editing = (i == self.editing_cell_index)
    
    if current_y + cell_height > 0 and current_y < h then
      -- Draw cell background
      self:draw_cell_background(x, current_y, w, cell_height, is_selected, is_editing)
      
      -- Draw cell header
      self:draw_cell_header(x, current_y, w, cell, i)
      
      -- Draw cell content
      self:draw_cell_content(x, current_y + 25, w, cell_height - 25, cell, is_editing)
      
      -- Draw cell output
      self:draw_cell_output(x, current_y + 25, w, cell)
    end
    
    current_y = current_y + cell_height
  end
  
  -- Draw scrollbar if needed
  local total_height = self:get_total_height()
  if total_height > h then
    self.scrollbar_visible = true
    local scrollbar_height = (h / total_height) * h
    local scrollbar_y = (self.scroll_y / total_height) * h
    renderer.draw_rect(x + w - 4, scrollbar_y, 4, scrollbar_height, style.scrollbar)
  else
    self.scrollbar_visible = false
  end
end

-- Mouse handling
function NotebookView:on_mouse_pressed(button, x, y, clicks)
  local content_y = y - 30 -- account for runtime status bar
  local cell_index = self:get_cell_at_position(content_y + self.scroll_y)
  
  if cell_index >= 1 and cell_index <= #self.notebook_data.cells then
    self.selected_cell_index = cell_index
    if clicks == 2 then
      self.editing_cell_index = cell_index
    end
    self:scroll_to_cell(cell_index)
  end
  
  return true
end

function NotebookView:on_mouse_wheel(dy)
  local total_height = self:get_total_height()
  local max_scroll = math.max(0, total_height - self.size.y)
  
  self.scroll_y = self.scroll_y - dy * 50
  self.scroll_y = math.max(0, math.min(self.scroll_y, max_scroll))
  
  return true
end

-- Keyboard handling
function NotebookView:on_key_pressed(key)
  if key == "up" then
    if self.selected_cell_index > 1 then
      self.selected_cell_index = self.selected_cell_index - 1
      self:scroll_to_cell(self.selected_cell_index)
    end
    return true
  elseif key == "down" then
    if self.selected_cell_index < #self.notebook_data.cells then
      self.selected_cell_index = self.selected_cell_index + 1
      self:scroll_to_cell(self.selected_cell_index)
    end
    return true
  elseif key == "return" and keymap.modkeys["shift"] then
    -- Shift+Enter: run cell and advance
    command.perform("colab:run-cell")
    return true
  elseif key == "return" and keymap.modkeys["ctrl"] then
    -- Ctrl+Enter: run cell without advancing
    command.perform("colab:run-cell-no-advance")
    return true
  elseif key == "escape" then
    -- Escape: exit edit mode
    self.editing_cell_index = nil
    return true
  end
  
  return false
end

return NotebookView
