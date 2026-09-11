local busted = require("busted")
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local assert = require("luassert")
local spy = require("luassert.spy")

describe("Detect Indent Plugin", function()
  local Doc

  before_each(function()
    _G.core = {
      command_view = { enter = spy.new(function() end) },
      active_view = {}
    }
    
    _G.core_regex = {
      compile = function(p) return p end,
      find_offsets = function(p, str, init) return nil end,
      ANCHORED = 1
    }
    
    _G.command = { add = spy.new(function() end) }
    _G.common = { fuzzy_match = function() return {} end }
    
    _G.config = {
      indent_size = 4,
      tab_type = "soft"
    }
    
    _G.core_syntax = {
      get = function() return { patterns = {} } end
    }
    
    _G.DocView = {}
    
    local Doc_class = {}
    Doc_class.__index = Doc_class
    function Doc_class:new(...) self.lines = {} self.syntax = { patterns = {} } end
    function Doc_class:clean(...) end
    function Doc_class:get_indent_info(...) return self.indent_info.type, self.indent_info.size, self.indent_info.confirmed end
    
    _G.Doc = Doc_class

    package.loaded["core"] = _G.core
    package.loaded["core.regex"] = _G.core_regex
    package.loaded["core.command"] = _G.command
    package.loaded["core.common"] = _G.common
    package.loaded["core.config"] = _G.config
    package.loaded["core.syntax"] = _G.core_syntax
    package.loaded["core.docview"] = _G.DocView
    package.loaded["core.doc"] = _G.Doc
    
    package.loaded["plugins.detectindent"] = nil
    require("plugins.detectindent")
    Doc = _G.Doc
  end)

  describe("Doc:new", function()
    it("should default to config indent if no clear pattern exists", function()
      local doc = setmetatable({}, Doc)
      doc.lines = { "hello", "world" }
      doc:new()
      assert.is_not_nil(doc.indent_info)
      assert.are.equal("soft", doc.indent_info.type)
      assert.are.equal(4, doc.indent_info.size)
      assert.is_false(doc.indent_info.confirmed)
    end)

    it("should detect 2-space soft indent", function()
      local doc = setmetatable({}, Doc)
      doc.lines = {
        "function test()",
        "  print('hello')",
        "  if true then",
        "    print('world')",
        "  end",
        "end"
      }
      doc:new()
      assert.are.equal("soft", doc.indent_info.type)
      assert.are.equal(2, doc.indent_info.size)
      assert.is_true(doc.indent_info.confirmed)
    end)

    it("should detect hard tabs indent", function()
      local doc = setmetatable({}, Doc)
      doc.lines = {
        "function test()",
        "\tprint('hello')",
        "\tif true then",
        "\t\tprint('world')",
        "\tend",
        "end"
      }
      doc:new()
      assert.are.equal("hard", doc.indent_info.type)
      assert.is_true(doc.indent_info.confirmed)
    end)
  end)
end)
