-- mod-version:3
-- Smart Indent plugin for Lite-XL
-- Enforces proper tab space sizes for specific languages and provides smart auto-indentation when pressing Enter.

local core = require "core"
local Doc = require "core.doc"
local command = require "core.command"

-- Set specific language indent rules
local lang_indents = {
  python = { type = "soft", size = 4 },
  yaml = { type = "soft", size = 2 },
  dockerfile = { type = "soft", size = 4 },
  javascript = { type = "soft", size = 2 },
  typescript = { type = "soft", size = 2 },
  json = { type = "soft", size = 2 },
  lua = { type = "soft", size = 2 },
}

-- Hook into Doc set_syntax to enforce tab spacing on file open
local old_set_syntax = Doc.set_syntax
function Doc:set_syntax(syntax)
  old_set_syntax(self, syntax)
  local syntax_name = syntax and syntax.name:lower() or ""
  if lang_indents[syntax_name] then
    self.indent_info = { type = lang_indents[syntax_name].type, size = lang_indents[syntax_name].size, confirmed = true }
  end
end

-- Hook into the doc:newline command to provide smart auto-indentation on Enter
local old_newline = command.map["doc:newline"].perform
command.map["doc:newline"].perform = function(dv)
  for idx, line, col in dv.doc:get_selections(false, true) do
    local current_line_text = dv.doc.lines[line]
    local indent = current_line_text:match("^[\t ]*")
    local prev_text = current_line_text:sub(1, col - 1)
    
    if col <= #indent then
      indent = indent:sub(#indent + 2 - col)
    end
    
    local syntax_name = dv.doc.syntax and dv.doc.syntax.name:lower() or ""
    local indent_str = dv.doc:get_indent_string()
    
    -- Smart increase indentation based on syntax and line ending characters
    if syntax_name == "python" and prev_text:match(":[%s]*$") then
      indent = indent .. indent_str
    elseif syntax_name == "yaml" and prev_text:match(":[%s]*$") then
      indent = indent .. indent_str
    elseif syntax_name == "lua" and (prev_text:match("then[%s]*$") or prev_text:match("do[%s]*$") or prev_text:match("function.*%)[%s]*$") or prev_text:match("repeat[%s]*$")) then
      indent = indent .. indent_str
    elseif prev_text:match("{[%s]*$") or prev_text:match("%[[%s]*$") or prev_text:match("%([%s]*$") then
      indent = indent .. indent_str
    end
    
    -- Remove current line if it contains only whitespace
    if current_line_text:match("^%s+$") then
      dv.doc:remove(line, 1, line, math.huge)
    end
    
    dv.doc:text_input("\n" .. indent, idx)
  end
end

core.log("Smart Indent loaded: Enforcing Python/YAML/Docker indentations.")
