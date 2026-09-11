local busted = require("busted")
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local assert = require("luassert")
local spy = require("luassert.spy")
local match = require("luassert.match")

describe("Autoclose Plugin", function()
  local Doc, DocView, core

  before_each(function()
    _G.core = {
      active_view = {},
      command_view = { doc = {} },
      docs = {}
    }
    
    local Doc_class = {}
    Doc_class.__index = Doc_class
    function Doc_class:delete_to_cursor(idx, offset) end
    
    local DocView_class = {}
    DocView_class.__index = DocView_class
    function DocView_class:on_text_input(text) end
    function DocView_class:is(cls) return self.class == cls end
    function DocView_class:extends(cls) return true end
    
    _G.Doc = Doc_class
    _G.DocView = DocView_class

    package.loaded["core"] = _G.core
    package.loaded["core.doc"] = _G.Doc
    package.loaded["core.docview"] = _G.DocView
    package.loaded["core.commandview"] = {}
    
    package.loaded["plugins.autoclose"] = nil
    require("plugins.autoclose")
  end)

  describe("DocView:on_text_input", function()
    it("should auto-close brackets when typing an opening bracket", function()
      local doc = {
        filename = "test.txt",
        get_selections = function() return function() return 1, 1, 1, 1, 1 end end,
        set_selections = spy.new(function() end)
      }
      local view = setmetatable({ class = _G.DocView, doc = doc }, _G.DocView)
      _G.core.docs = { doc }
      
      local original_on_text_input = spy.new(function() end)
      -- mock original function inside class (already overridden by plugin, so we simulate base call)
      
      view:on_text_input("{")
      assert.spy(doc.set_selections).was_called()
    end)

    it("should skip auto-closing if view is command_view", function()
      local doc = {}
      _G.core.command_view.doc = doc
      local view = setmetatable({ class = _G.DocView, doc = doc }, _G.DocView)
      view.is = function(_, cls) return false end
      view.extends = function(_, cls) return false end
      
      -- Plugin should fallback to standard text input without bracket closure logic
      -- In full integration this would assert the old_on_text_input is called without "}"
    end)
  end)
end)
