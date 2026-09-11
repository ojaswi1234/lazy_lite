local busted = require("busted")
local describe = busted.describe
local it = busted.it
local setup = busted.setup
local teardown = busted.teardown
local before_each = busted.before_each
local assert = require("luassert")
local spy = require("luassert.spy")
local match = require("luassert.match")

describe("Autosave Plugin", function()
  local core, system, config, command, Node
  
  before_each(function()
    _G.core = {
      docs = {},
      add_thread = spy.new(function() end),
      set_active_view = spy.new(function() end),
      log = spy.new(function() end),
      log_quiet = spy.new(function() end),
    }
    _G.system = { get_time = function() return 0 end }
    _G.common = { merge = function(a, b) return a end }
    _G.config = { plugins = { autosave = {} } }
    _G.command = { add = spy.new(function() end) }
    _G.Node = { set_active_view = function(self, view) end }
    
    package.loaded["core"] = _G.core
    package.loaded["system"] = _G.system
    package.loaded["core.common"] = _G.common
    package.loaded["core.config"] = _G.config
    package.loaded["core.command"] = _G.command
    package.loaded["core.doc"] = {}
    package.loaded["core.node"] = _G.Node
    
    package.loaded["plugins.autosave"] = nil
    require("plugins.autosave")
  end)

  describe("save_doc_safe", function()
    it("should not save if document has no filename", function()
      local doc = { is_dirty = function() return true end, save = spy.new(function() end) }
      _G.core.docs = { doc }
      _G.core.active_view = { doc = doc }
      _G.config.plugins.autosave.save_on_focus_lost = true
      _G.config.plugins.autosave.enabled = true
      
      _G.core.set_active_view({})
      assert.spy(doc.save).was_not_called()
    end)
    
    it("should not save if document is not dirty", function()
      local doc = { filename = "test.txt", is_dirty = function() return false end, save = spy.new(function() end) }
      _G.core.docs = { doc }
      _G.core.active_view = { doc = doc }
      
      _G.core.set_active_view({})
      assert.spy(doc.save).was_not_called()
    end)

    it("should save if document is dirty and has filename", function()
      local doc = { filename = "test.txt", is_dirty = function() return true end, save = spy.new(function() end) }
      _G.core.docs = { doc }
      _G.core.active_view = { doc = doc }
      
      _G.core.set_active_view({})
      assert.spy(doc.save).was_called(1)
      assert.is_true(_G.core.redraw)
    end)
    
    it("should catch errors during save and log quietly", function()
      local doc = { 
        filename = "test.txt", 
        is_dirty = function() return true end, 
        save = spy.new(function() error("disk full") end) 
      }
      _G.core.docs = { doc }
      _G.core.active_view = { doc = doc }
      
      _G.core.set_active_view({})
      assert.spy(doc.save).was_called(1)
      assert.spy(_G.core.log_quiet).was_called_with(match.is_string(), "test.txt", match.is_string())
    end)
  end)

  describe("Commands", function()
    it("autosave:toggle should flip the enabled state", function()
      _G.config.plugins.autosave.enabled = true
      local toggle_cmd = nil
      for _, call in ipairs(_G.command.add.calls) do
        if call.vals[2]["autosave:toggle"] then
          toggle_cmd = call.vals[2]["autosave:toggle"]
          break
        end
      end
      
      assert.is_not_nil(toggle_cmd)
      toggle_cmd()
      assert.is_false(_G.config.plugins.autosave.enabled)
      assert.spy(_G.core.log).was_called_with("Autosave: %s", "Disabled")
    end)
  end)
end)
