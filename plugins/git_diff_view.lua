-- mod-version:3
local core = require "core"

-- [AUTO-GENERATED CACHED COLORS FOR GC OPTIMIZATION]
local _COLOR_CACHE_0 = {150, 255, 150, 255}
local _COLOR_CACHE_1 = { 40, 120, 40, 50 }
local _COLOR_CACHE_2 = { 250, 80, 80, 255 }
local _COLOR_CACHE_3 = {255, 150, 150, 255}
local _COLOR_CACHE_4 = { 180, 40, 40, 50 }
local _COLOR_CACHE_5 = { 80, 200, 80, 255 }
local _COLOR_CACHE_6 = { 40, 80, 180, 40 }
local style = require "core.style"
local common = require "core.common"
local DocView = require "core.docview"
local Doc = require "core.doc"
local renderer = require "renderer"

local GitDiffView = DocView:extend()

function GitDiffView:new(diff_text, filename)
  local doc = Doc()
  local orig_name = filename:match("^(.+) %(Diff%)$") or filename
  doc.filename = nil
  pcall(function()
    local syntax = require "core.syntax"
    local syn = syntax.get(orig_name)
    if syn then doc.syntax = syn end
  end)

  self.line_status = {}
  local lines = {}
  
  local old_ln = 0
  local new_ln = 0
  local in_hunk = false

  for line in (diff_text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    if not in_hunk then
      if line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@") then
        local o, n = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
        old_ln = tonumber(o)
        new_ln = tonumber(n)
        in_hunk = true
        table.insert(lines, string.rep("-", 60))
        table.insert(self.line_status, { status = "header", old = "", new = "" })
      end
    else
      if line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@") then
        local o, n = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
        old_ln = tonumber(o)
        new_ln = tonumber(n)
        table.insert(lines, string.rep("-", 60))
        table.insert(self.line_status, { status = "header", old = "", new = "" })
      elseif line:sub(1, 1) == "+" then
        table.insert(lines, line)
        table.insert(self.line_status, { status = "added", old = "", new = tostring(new_ln) })
        new_ln = new_ln + 1
      elseif line:sub(1, 1) == "-" then
        table.insert(lines, line)
        table.insert(self.line_status, { status = "deleted", old = tostring(old_ln), new = "" })
        old_ln = old_ln + 1
      elseif line:sub(1, 1) == " " then
        table.insert(lines, line)
        table.insert(self.line_status, { status = "normal", old = tostring(old_ln), new = tostring(new_ln) })
        old_ln = old_ln + 1
        new_ln = new_ln + 1
      elseif line == "\\ No newline at end of file" then
        -- skip
      elseif line == "" then
        table.insert(lines, "")
        table.insert(self.line_status, { status = "normal", old = tostring(old_ln), new = tostring(new_ln) })
        old_ln = old_ln + 1
        new_ln = new_ln + 1
      else
        in_hunk = false
      end
    end
  end

  local final_text = table.concat(lines, "\n")
  if final_text == "" then final_text = "No changes or binary file." end
  doc:insert(1, 1, final_text)
  doc:clean()
  
  -- Aggressively prevent any modifications or saving
  doc.read_only = true
  doc.insert = function() end
  doc.remove = function() end
  doc.save = function() end
  doc.abs_filename = "" -- Prevent autoreload crash when trying to save

  GitDiffView.super.new(self, doc)
  self.name = filename or "Git Diff"
end

function GitDiffView:get_name()
  return self.name
end

function GitDiffView:supports_text_input()
  return false
end

function GitDiffView:draw_cursor(x, y)
  -- Do not draw cursor
end

function GitDiffView:draw_line_body(line, x, y)
  local st = self.line_status[line]
  if st then
    local status = st.status
    if status == "added" then
      renderer.draw_rect(0, y, self.size.x, self:get_line_height(), _COLOR_CACHE_1)
    elseif status == "deleted" then
      renderer.draw_rect(0, y, self.size.x, self:get_line_height(), _COLOR_CACHE_4)
    elseif status == "header" then
      renderer.draw_rect(0, y, self.size.x, self:get_line_height(), _COLOR_CACHE_6)
    end
  end
  GitDiffView.super.draw_line_body(self, line, x, y)
end

function GitDiffView:get_gutter_width()
  local font = self:get_font()
  return font:get_width(" 9999 | 9999 ") + style.padding.x * 2
end

function GitDiffView:draw_line_gutter(line, x, y, width)
  local st = self.line_status[line]
  if not st then return GitDiffView.super.draw_line_gutter(self, line, x, y, width) end

  local status = st.status
  if status == "added" then
    renderer.draw_rect(x, y, width, self:get_line_height(), _COLOR_CACHE_1)
    renderer.draw_rect(x + width - 4 * SCALE, y, 4 * SCALE, self:get_line_height(), _COLOR_CACHE_5)
  elseif status == "deleted" then
    renderer.draw_rect(x, y, width, self:get_line_height(), _COLOR_CACHE_4)
    renderer.draw_rect(x + width - 4 * SCALE, y, 4 * SCALE, self:get_line_height(), _COLOR_CACHE_2)
  elseif status == "header" then
    renderer.draw_rect(x, y, width, self:get_line_height(), _COLOR_CACHE_6)
  end

  local color = style.dim
  if status == "added" then color = _COLOR_CACHE_0
  elseif status == "deleted" then color = _COLOR_CACHE_3 end

  local old_text = st.old or ""
  local new_text = st.new or ""
  
  local hw = width / 2
  local font = self:get_font()
  common.draw_text(font, color, old_text, "right", x, y, hw - 4*SCALE, self:get_line_height())
  common.draw_text(font, color, new_text, "right", x + hw, y, hw - 4*SCALE, self:get_line_height())
end

return GitDiffView
