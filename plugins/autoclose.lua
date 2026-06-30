-- mod-version:3
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"

local pairs_map = {
  ["{"] = "}",
  ["["] = "]",
  ["("] = ")",
  ['"'] = '"',
  ["'"] = "'",
  ["`"] = "`"
}

local old_on_text_input = DocView.on_text_input
function DocView:on_text_input(text)
  local doc = self.doc
  local closing = pairs_map[text]
  
  if closing then
    -- Check if we're just typing the closing bracket to step over it
    if text == closing then
      local all_step = true
      for idx, l1, c1, l2, c2 in doc:get_selections() do
        if l1 ~= l2 or c1 ~= c2 or doc:get_text(l1, c1, l1, c1 + #text) ~= text then
          all_step = false
          break
        end
      end
      
      if all_step then
        for idx, l1, c1, l2, c2 in doc:get_selections() do
          doc:set_selections(idx, l1, c1 + #text)
        end
        return
      end
    end

    -- Check if we have active text selections to wrap
    local has_selection = false
    for idx, l1, c1, l2, c2 in doc:get_selections() do
      if l1 ~= l2 or c1 ~= c2 then
        has_selection = true
        break
      end
    end
    
    if has_selection then
      -- Iterate selections backwards so we don't mess up cursor indices
      local selections = {}
      for idx, l1, c1, l2, c2, swap in doc:get_selections(true) do
        table.insert(selections, {l1, c1, l2, c2})
      end
      for i = #selections, 1, -1 do
        local sel = selections[i]
        local l1, c1, l2, c2 = sel[1], sel[2], sel[3], sel[4]
        doc:insert(l2, c2, closing)
        doc:insert(l1, c1, text)
      end
      return
    end

    -- Normal insertion with auto-close bracket pair
    old_on_text_input(self, text .. closing)
    
    -- Step all cursors backward by 1 character so they land inside the brackets
    for idx, l1, c1, l2, c2 in doc:get_selections() do
      doc:set_selections(idx, l1, c1 - #closing)
    end
    return
  end
  
  old_on_text_input(self, text)
end

-- Hook backspace to delete empty pairs together
local old_delete_to_cursor = Doc.delete_to_cursor
function Doc:delete_to_cursor(idx, ...)
  local args = {...}
  local offset = args[1]
  
  -- -1 offset usually means backspace
  if offset == -1 then
    for sidx, l1, c1, l2, c2 in self:get_selections(true, idx) do
      if l1 == l2 and c1 == c2 then
        local before = self:get_text(l1, c1 - 1, l1, c1)
        local after = self:get_text(l1, c1, l1, c1 + 1)
        if pairs_map[before] and pairs_map[before] == after then
          -- We are exactly between a bracket pair. Manually delete the right side.
          self:remove(l1, c1, l1, c1 + 1)
        end
      end
    end
  end
  
  -- Now let the original delete_to_cursor delete the left side (the normal backspace)
  old_delete_to_cursor(self, idx, ...)
end
