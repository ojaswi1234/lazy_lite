local busted = require("busted")
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local assert = require("luassert")
local spy = require("luassert.spy")
local match = require("luassert.match")

describe("Tempfiles Manager Plugin", function()
  before_each(function()
    _G.USERDIR = "/tmp/userdir"
    _G.PATHSEP = "/"
    _G.PLATFORM = "Linux"
    
    _G.core = {
      add_thread = spy.new(function(f) f() end),
      error = spy.new(function() end),
      command_view = {
        enter = spy.new(function() end)
      },
      log = spy.new(function() end)
    }
    
    _G.system = {
      get_file_info = spy.new(function(path) return nil end),
      mkdir = spy.new(function() end),
      list_dir = spy.new(function(path) return {} end)
    }
    
    _G.command = {
      add = spy.new(function() end),
      perform = spy.new(function() end)
    }
    
    _G.os = {
      remove = spy.new(function() end),
      execute = spy.new(function() end)
    }
    
    package.loaded["core"] = _G.core
    package.loaded["system"] = _G.system
    package.loaded["core.command"] = _G.command
    
    package.loaded["plugins.tempfiles_manager"] = nil
  end)

  it("should create temp dir if it does not exist", function()
    require("plugins.tempfiles_manager")
    assert.spy(_G.system.mkdir).was_called_with("/tmp/userdir/tempfiles")
  end)

  it("should prompt user to clean up if tempfiles limit is reached", function()
    _G.system.get_file_info = function(path) 
      if path == "/tmp/userdir/tempfiles" then return {type = "dir"} end
      return {type = "file"}
    end
    
    local fake_files = {}
    for i=1, 55 do table.insert(fake_files, "file" .. i) end
    _G.system.list_dir = function() return fake_files end
    
    -- Mock coroutine.yield to prevent thread blocking in test
    local old_yield = coroutine.yield
    coroutine.yield = function() end
    
    require("plugins.tempfiles_manager")
    
    coroutine.yield = old_yield
    
    assert.spy(_G.core.error).was_called()
    assert.spy(_G.core.command_view.enter).was_called()
  end)
end)
