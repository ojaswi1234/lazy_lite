-- mod-version:3
-- Smart Indent plugin for Lite-XL
-- Enforces proper tab space sizes for specific languages and provides smart auto-indentation & bracket splitting on Enter.

local core = require "core"
local Doc = require "core.doc"
local command = require "core.command"

-- Set specific language indent rules
local lang_indents = {
  python = { type = "soft", size = 4 },
  java = { type = "soft", size = 4 },
  c = { type = "soft", size = 4 },
  cpp = { type = "soft", size = 4 },
  csharp = { type = "soft", size = 4 },
  rust = { type = "soft", size = 4 },
  go = { type = "hard", size = 4 },
  yaml = { type = "soft", size = 2 },
  dockerfile = { type = "soft", size = 4 },
  javascript = { type = "soft", size = 2 },
  typescript = { type = "soft", size = 2 },
  json = { type = "soft", size = 2 },
  lua = { type = "soft", size = 2 },
  html = { type = "soft", size = 2 },
  css = { type = "soft", size = 2 },
  scss = { type = "soft", size = 2 },
  xml = { type = "soft", size = 2 },
  markdown = { type = "soft", size = 2 },
}

-- Hook into Doc set_syntax to enforce tab spacing on file open
local old_set_syntax = Doc.set_syntax
function Doc:set_syntax(syntax)
  old_set_syntax(self, syntax)
  local syntax_name = syntax and syntax.name:lower() or ""
  if lang_indents[syntax_name] then
    self.indent_info = {
      type = lang_indents[syntax_name].type,
      size = lang_indents[syntax_name].size,
      confirmed = true
    }
  end
end

local pairs_map = {
  ["{"] = "}",
  ["["] = "]",
  ["("] = ")"
}

-- Hook into the doc:newline command to provide smart auto-indentation and bracket splitting on Enter
command.map["doc:newline"].perform = function(dv)
  for idx, line, col in dv.doc:get_selections(false, true) do
    local raw_line_text = dv.doc.lines[line] or ""
    local current_line_text = raw_line_text:gsub("[\r\n]+$", "")
    local indent = current_line_text:match("^[\t ]*") or ""
    local prev_text = current_line_text:sub(1, col - 1)
    local next_text = current_line_text:sub(col)
    
    if col <= #indent then
      indent = indent:sub(#indent + 2 - col)
    end
    
    local syntax_name = dv.doc.syntax and dv.doc.syntax.name:lower() or ""
    local indent_str = dv.doc:get_indent_string()
    
    -- Check if cursor is directly between matching brackets e.g. {|} or (|) or [|]
    local open_char = prev_text:match("([{(%[])%s*$")
    local close_char = next_text:match("^%s*([}%]%)])")
    
    if open_char and pairs_map[open_char] and pairs_map[open_char] == close_char then
      -- Remove current line if it contains only whitespace before cursor
      if current_line_text:match("^%s+$") then
        dv.doc:remove(line, 1, line, math.huge)
      end
      
      -- If there is whitespace between cursor and closing bracket, strip it
      local ws_after = next_text:match("^([ \t]+)%S")
      if ws_after then
        dv.doc:remove(line, col, line, col + #ws_after)
      end
      
      -- Insert indented newline and matching closing bracket on next line:
      -- Line 1: prev_text (e.g. for(...) { )
      -- Line 2: indent .. indent_str (cursor lands here)
      -- Line 3: indent .. next_text (e.g. } )
      local insert_text = "\n" .. indent .. indent_str .. "\n" .. indent
      dv.doc:text_input(insert_text, idx)
      dv.doc:set_selections(idx, line + 1, #indent + #indent_str + 1)
    else
      -- Smart increase indentation based on syntax and line ending characters
      local increase = false
      if (syntax_name == "python" or syntax_name == "yaml") and prev_text:match(":[%s]*$") then
        increase = true
      elseif syntax_name == "lua" and (
        prev_text:match("then[%s]*$") or
        prev_text:match("do[%s]*$") or
        prev_text:match("repeat[%s]*$") or
        prev_text:match("else[%s]*$") or
        prev_text:match("function[%s]*%b()[%s]*$")
      ) then
        increase = true
      elseif prev_text:match("{[%s]*$") or prev_text:match("%[[%s]*$") or prev_text:match("%([%s]*$") then
        increase = true
      end
      
      if increase then
        indent = indent .. indent_str
      end
      
      -- Remove current line if it contains only whitespace
      if current_line_text:match("^%s+$") then
        dv.doc:remove(line, 1, line, math.huge)
      end
      
      dv.doc:text_input("\n" .. indent, idx)
    end
  end
end

core.log("Smart Indent loaded: Enforcing bracket splitting & language auto-indentation.")
