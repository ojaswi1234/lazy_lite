-- mod-version:3
-- Smart Indent plugin for Lite-XL
-- Enforces proper tab space sizes for specific languages and provides smart auto-indentation when pressing Enter.

local core = require "core"
local DocView = require "core.docview"

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

-- Hook into DocView on_text_input to intercept Enter key
local old_on_text_input = DocView.on_text_input
function DocView:on_text_input(text)
  if text == "\n" or text == "\r\n" then
    local line, col = self.doc:get_selection()
    local current_line_text = self.doc.lines[line]
    local prev_text = current_line_text:sub(1, col - 1)
    
    -- Extract current indentation
    local indent = prev_text:match("^[\t ]*") or ""
    
    -- Enforce language specific tab spaces
    local syntax = self.doc.syntax and self.doc.syntax.name:lower() or ""
    if lang_indents[syntax] then
      self.doc.indent_info = { type = lang_indents[syntax].type, size = lang_indents[syntax].size, confirmed = true }
    end
    
    local indent_str = self.doc:get_indent_string()
    
    -- Smart increase indentation based on syntax and line ending characters
    if syntax == "python" and prev_text:match(":[%s]*$") then
      indent = indent .. indent_str
    elseif syntax == "yaml" and prev_text:match(":[%s]*$") then
      indent = indent .. indent_str
    elseif syntax == "lua" and (prev_text:match("then[%s]*$") or prev_text:match("do[%s]*$") or prev_text:match("function.*%)[%s]*$") or prev_text:match("repeat[%s]*$")) then
      indent = indent .. indent_str
    elseif prev_text:match("{[%s]*$") or prev_text:match("%[[%s]*$") or prev_text:match("%([%s]*$") then
      indent = indent .. indent_str
    end
    
    self.doc:text_input("\n" .. indent)
    self:scroll_to_make_visible(line + 1, #indent + 1)
    return
  end
  
  -- Handle auto-unindenting for closing brackets
  if text == "}" or text == "]" or text == ")" then
    local line, col = self.doc:get_selection()
    local current_line_text = self.doc.lines[line]
    if current_line_text:match("^[\t ]*$") then
      local indent_str = self.doc:get_indent_string()
      if current_line_text:len() >= indent_str:len() then
        self.doc:remove(line, 1, line, indent_str:len() + 1)
      end
    end
  end

  old_on_text_input(self, text)
end

core.log("Smart Indent loaded: Enforcing Python/YAML/Docker indentations.")
