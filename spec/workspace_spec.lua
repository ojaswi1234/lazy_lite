local busted = require("busted")
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local assert = require("luassert")
local spy = require("luassert.spy")

describe("Workspace Plugin", function()
  before_each(function()
    _G.USERDIR = "/home/user/.config/lite-xl"
    _G.PATHSEP = "/"
    
    _G.core = {
      project_dir = "/home/user/project",
      project_directories = { {name = "/home/user/project"} },
      docs = {},
      root_view = { root_node = { type = "leaf", locked = false, views = {} } },
      try = spy.new(function(f, ...) if f then f(...) end end),
      run = spy.new(function() end),
      set_active_view = spy.new(function() end),
      add_project_directory = spy.new(function() end)
    }
    
    _G.system = {
      get_file_info = function(path) return nil end,
      mkdir = spy.new(function() return true end),
      list_dir = function() return {} end,
      absolute_path = function(p) return p end
    }
    
    _G.common = {
      basename = function(p) return p:match("([^/]+)$") or p end,
      serialize = function(t) return "{}" end,
      relative_path = function(base, p) return p end
    }
    
    _G.DocView = {}
    _G.LogView = {}
    
    package.loaded["core"] = _G.core
    package.loaded["system"] = _G.system
    package.loaded["core.common"] = _G.common
    package.loaded["core.docview"] = _G.DocView
    package.loaded["core.logview"] = _G.LogView
    
    package.loaded["plugins.workspace"] = nil
  end)

  describe("Hooks", function()
    it("should hook core.run and execute load_workspace if no docs are open", function()
      require("plugins.workspace")
      
      _G.core.docs = {}
      _G.core.run()
      
      assert.spy(_G.core.try).was_called()
    end)
    
    it("should skip load_workspace if docs are already open", function()
      require("plugins.workspace")
      
      _G.core.docs = { { filename = "test.txt" } }
      _G.core.run()
      
      assert.spy(_G.core.try).was_not_called()
    end)
    
    it("should hook core.on_quit_project and attempt to save workspace", function()
      _G.core.on_quit_project = spy.new(function() end)
      require("plugins.workspace")
      _G.core.run() -- To initialize hooks
      
      _G.core.on_quit_project()
      assert.spy(_G.core.try).was_called()
    end)
  end)
end)
