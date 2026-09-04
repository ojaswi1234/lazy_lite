--- mod-version:3
--
-- Ghost Text (Inline Multi-line Code Autocompletion) for Lite-XL
-- Behaves exactly like VS Code / Copilot inline ghost text:
--   - Renders dim/ghost text and multi-line snippets directly in-place at cursor
--   - Press <Tab> to ACCEPT and insert the ghost text
--   - Press <Escape> to REJECT and dismiss the ghost text
--

local core = require "core"

-- [AUTO-GENERATED CACHED COLORS FOR GC OPTIMIZATION]
local _COLOR_CACHE_0 = { 140, 140, 140, 160 }
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local Doc = require "core.doc"
local DocView = require "core.docview"
local translate = require "core.doc.translate"

config.plugins.ghost_text = common.merge({
  enabled = true,
  min_trigger_len = 1,
  color = nil, -- uses style.syntax["comment"] or dimmed gray
  config_spec = {
    name = "Ghost Text Autocomplete",
    {
      label = "Enable Ghost Text",
      description = "Shows inline ghost text & multi-line code completions.",
      path = "enabled",
      type = "toggle",
      default = true
    }
  }
}, config.plugins.ghost_text)

local ghost = {
  doc = nil,
  line = 0,
  col = 0,
  text = nil,      -- full ghost text string
  lines = {},     -- array of ghost text lines
  active = false
}

-- Built-in intelligent multi-line code patterns for common languages
local PATTERNS = {
  go = {
    { prefix = "if err", text = " != nil {\n\treturn err\n}" },
    { prefix = "if err !=", text = " nil {\n\treturn err\n}" },
    { prefix = "func main", text = "() {\n\t\n}" },
    { prefix = "for i", text = " := 0; i < n; i++ {\n\t\n}" },
    { prefix = "for _,", text = " v := range items {\n\t\n}" },
    { prefix = "type ", text = "struct {\n\t\n}" },
    { prefix = "package main", text = "\n\nimport (\n\t\"fmt\"\n)\n\nfunc main() {\n\tfmt.Println(\"Hello, World!\")\n}" },
    { prefix = "fmt.P", text = "rintln()" },
    { prefix = "fmt.Print", text = "ln()" },
    { prefix = "fmt.Printf", text = "(\"%v\\n\", )" },
    { prefix = "fmt.Sp", text = "rintf(\"%v\", )" }
  },
  python = {
    { prefix = "def __init__", text = "(self):\n    " },
    { prefix = "if __name__", text = " == \"__main__\":\n    main()" },
    { prefix = "try:", text = "\n    pass\nexcept Exception as e:\n    print(e)" },
    { prefix = "with open", text = "(\"file.txt\", \"r\") as f:\n    content = f.read()" },
    { prefix = "for i in", text = " range(len(items)):\n    " },
    { prefix = "print(", text = "\"\"" }
  },
  javascript = {
    { prefix = "console.l", text = "og()" },
    { prefix = "console.log", text = "()" },
    { prefix = "function", text = " name() {\n  \n}" },
    { prefix = "const [", text = "state, setState] = useState();" },
    { prefix = "useEffect(", text = "() => {\n  \n}, []);" },
    { prefix = "async function", text = "() {\n  try {\n    \n  } catch (err) {\n    console.error(err);\n  }\n}" },
    { prefix = "if (err", text = ") {\n  console.error(err);\n}" }
  },
  rust = {
    { prefix = "fn main", text = "() {\n    println!(\"Hello, World!\");\n}" },
    { prefix = "println!", text = "(\"{}\", );" },
    { prefix = "match ", text = "result {\n    Ok(val) => val,\n    Err(e) => return Err(e),\n}" },
    { prefix = "if let Some(", text = "val) = opt {\n    \n}" }
  }
}

local CommandView_ok, CommandView = pcall(require, "core.commandview")

local function is_editor_doc(doc)
  if not doc then return false end
  if core.command_view and (core.active_view == core.command_view or doc == core.command_view.doc) then
    return false
  end
  local av = core.active_view
  if CommandView_ok and av and (av == core.command_view or av:is(CommandView)) then
    return false
  end
  if av and not (av:is(DocView) or av:extends(DocView)) then
    return false
  end
  for _, d in ipairs(core.docs or {}) do
    if d == doc then return true end
  end
  return doc.filename ~= nil
end

local function clear_ghost()
  if ghost.active then
    ghost.active = false
    ghost.text = nil
    ghost.lines = {}
    ghost.doc = nil
    core.redraw = true
  end
end

local function get_file_lang(doc)
  if not doc or not doc.filename then return "generic" end
  local ext = doc.filename:match("%.([a-zA-Z0-9]+)$")
  if not ext then return "generic" end
  ext = ext:lower()
  if ext == "go" then return "go" end
  if ext == "py" then return "python" end
  if ext == "js" or ext == "jsx" or ext == "ts" or ext == "tsx" then return "javascript" end
  if ext == "rs" then return "rust" end
  if ext == "lua" then return "lua" end
  return ext
end

-- Find best ghost text match
local function compute_ghost_text(doc, line, col)
  if not config.plugins.ghost_text.enabled then return nil end
  if not is_editor_doc(doc) then return nil end
  if not doc or not doc.lines[line] then return nil end

  local line_text = doc.lines[line]
  local prefix_on_line = line_text:sub(1, col - 1)
  
  -- Don't show ghost if cursor is in middle of existing alphanumeric text
  local char_after = line_text:sub(col, col)
  if char_after:match("[%w_]") then
    return nil
  end

  local lang = get_file_lang(doc)
  local patterns = PATTERNS[lang] or {}

  -- 1. Check language block snippets
  for _, p in ipairs(patterns) do
    if prefix_on_line:sub(-#p.prefix) == p.prefix then
      return p.text
    end
  end

  -- Extract current word at cursor
  local word_start_l, word_start_c = translate.start_of_word(doc, line, col)
  local current_word = doc:get_text(word_start_l, word_start_c, line, col)

  -- 2. Check LSP completion cache for active language server
  local ac = package.loaded["plugins.autocomplete"]
  if ac and #current_word >= config.plugins.ghost_text.min_trigger_len then
    local maps = { ac.map_manually, ac.map }
    for _, m in ipairs(maps) do
      if m then
        for _, v in pairs(m) do
          if v.items then
            for _, item in pairs(v.items) do
              local text = type(item) == "table" and (item.text or item.label) or tostring(item)
              if text:sub(1, #current_word) == current_word and #text > #current_word then
                return text:sub(#current_word + 1)
              end
            end
          end
        end
      end
    end
  end

  -- 3. Check word tokens from buffer / open documents
  if #current_word >= config.plugins.ghost_text.min_trigger_len then
    local word_pat = "^" .. current_word:gsub("(%W)", "%%%1") .. "([%w_]+)$"
    for _, item_doc in ipairs(core.docs or {}) do
      if item_doc.lines then
        for _, lstr in ipairs(item_doc.lines) do
          for w in lstr:gmatch("[%w_]+") do
            local suffix = w:match(word_pat)
            if suffix and #suffix > 0 then
              return suffix
            end
          end
        end
      end
    end
  end

  return nil
end

local function update_ghost(doc)
  if not doc then
    clear_ghost()
    return
  end
  local line1, col1, line2, col2 = doc:get_selection()
  if line1 ~= line2 or col1 ~= col2 then
    clear_ghost()
    return
  end

  local candidate = compute_ghost_text(doc, line1, col1)
  if candidate and #candidate > 0 then
    ghost.doc = doc
    ghost.line = line1
    ghost.col = col1
    ghost.text = candidate
    ghost.lines = {}
    for l in (candidate .. "\n"):gmatch("(.-)\n") do
      table.insert(ghost.lines, l)
    end
    ghost.active = true
    core.redraw = true
  else
    clear_ghost()
  end
end

-- Hook Document changes to update ghost text
local doc_raw_insert = Doc.raw_insert
function Doc:raw_insert(line, col, text, undo_stack, time)
  doc_raw_insert(self, line, col, text, undo_stack, time)
  if is_editor_doc(self) and self == (core.active_view and core.active_view.doc) then
    core.add_thread(function()
      update_ghost(self)
    end)
  end
end

local doc_raw_remove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, undo_stack, time)
  doc_raw_remove(self, line1, col1, line2, col2, undo_stack, time)
  if is_editor_doc(self) and self == (core.active_view and core.active_view.doc) then
    core.add_thread(function()
      update_ghost(self)
    end)
  end
end

-- Hook Cursor Selection
local doc_set_selection = Doc.set_selection
function Doc:set_selection(line1, col1, line2, col2, swap)
  doc_set_selection(self, line1, col1, line2, col2, swap)
  if ghost.active and (ghost.line ~= line1 or ghost.col ~= col1 or ghost.doc ~= self or not is_editor_doc(self)) then
    clear_ghost()
  end
end

-- Render Ghost Text in DocView Overlay with pixel-perfect font baseline
local old_draw_overlay = DocView.draw_overlay
function DocView:draw_overlay()
  old_draw_overlay(self)

  if ghost.active and ghost.doc == self.doc and core.active_view == self and is_editor_doc(self.doc) then
    local line1, col1 = self.doc:get_selection()
    if line1 == ghost.line and col1 == ghost.col then
      local font = self:get_font()
      local lh = self:get_line_height()
      local y_off = self.get_line_text_y_offset and self:get_line_text_y_offset() or 0
      local ghost_color = config.plugins.ghost_text.color or style.syntax["comment"] or _COLOR_CACHE_0
      
      -- Position of the first ghost segment (immediately after cursor)
      local sx, sy = self:get_line_screen_position(ghost.line, ghost.col)
      
      for i, gline in ipairs(ghost.lines) do
        if i == 1 then
          -- First line drawn directly after cursor
          if #gline > 0 then
            renderer.draw_text(font, gline, sx, sy + y_off, ghost_color)
          end
        else
          -- Multi-line continuation drawn on successive lines aligned to indentation
          local next_y = sy + (i - 1) * lh + y_off
          local line_base_x = self:get_line_screen_position(ghost.line)
          renderer.draw_text(font, gline, line_base_x, next_y, ghost_color)
        end
      end
    end
  end
end

-- Commands & Predicates for Tab Accept / Esc Reject
local function has_ghost()
  local av = core.active_view
  if not av or not is_editor_doc(av.doc) then
    return false
  end
  local ac = package.loaded["plugins.autocomplete"]
  if ac and ac.is_open and ac.is_open() then
    return false
  end
  return ghost.active 
     and (av:is(DocView) or av:extends(DocView))
     and av.doc == ghost.doc
     and ghost.text ~= nil
end

command.add(has_ghost, {
  ["ghost-text:accept"] = function()
    if has_ghost() then
      local text = ghost.text
      local doc = ghost.doc
      clear_ghost()
      doc:text_input(text)
    end
  end,

  ["ghost-text:reject"] = function()
    if has_ghost() then
      clear_ghost()
    end
  end
})

-- Keybindings: Priority mapping for Tab (Accept) and Esc (Reject)
keymap.add {
  ["tab"]    = "ghost-text:accept",
  ["escape"] = "ghost-text:reject"
}

return {
  clear = clear_ghost,
  update = update_ghost,
  get_ghost = function() return ghost end
}
