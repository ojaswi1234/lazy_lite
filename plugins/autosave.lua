-- mod-version:3
-- Autosave plugin for Lite-XL
-- Automatically saves dirty named documents periodically and on focus lost with UI Settings integration.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local Doc = require "core.doc"
local Node = require "core.node"

config.plugins.autosave = common.merge({
  enabled = true,
  interval = 5,
  save_on_focus_lost = true,
  config_spec = {
    name = "Autosave",
    {
      label = "Enabled",
      description = "Automatically save modified files in the background.",
      path = "enabled",
      type = "toggle",
      default = true
    },
    {
      label = "Autosave Interval",
      description = "Interval in seconds between background auto-saves.",
      path = "interval",
      type = "number",
      default = 5,
      min = 1,
      max = 120
    },
    {
      label = "Save on Focus Lost",
      description = "Automatically save modified files when switching tabs or when the editor loses window focus.",
      path = "save_on_focus_lost",
      type = "toggle",
      default = true
    }
  }
}, config.plugins.autosave)

-- Save a document safely
local function save_doc_safe(doc)
  if not doc or not doc.filename or doc.filename == "" then return false end
  if not doc:is_dirty() then return false end

  local ok, err = pcall(function() doc:save() end)
  if ok then
    core.redraw = true
    return true
  else
    core.log_quiet("Autosave failed for %s: %s", doc.filename, tostring(err))
    return false
  end
end

-- Save all modified named documents
local function save_all_dirty_docs()
  if not config.plugins.autosave or not config.plugins.autosave.enabled then return end
  for _, doc in ipairs(core.docs) do
    save_doc_safe(doc)
  end
end

-- Periodic autosave background thread
core.add_thread(function()
  local last_save_time = system.get_time()
  while true do
    coroutine.yield(0.5)
    local current_time = system.get_time()
    local interval = (config.plugins.autosave and config.plugins.autosave.interval) or 5
    if current_time - last_save_time >= interval then
      last_save_time = current_time
      save_all_dirty_docs()
    end
  end
end)

-- Save on tab switch or active view change
local old_set_active_view = core.set_active_view
function core.set_active_view(view)
  if config.plugins.autosave and config.plugins.autosave.enabled and config.plugins.autosave.save_on_focus_lost then
    if core.active_view and core.active_view.doc then
      save_doc_safe(core.active_view.doc)
    end
  end
  return old_set_active_view(view)
end

-- Hook Node:set_active_view for split panes
local old_node_set_active_view = Node.set_active_view
function Node:set_active_view(view)
  if config.plugins.autosave and config.plugins.autosave.enabled and config.plugins.autosave.save_on_focus_lost then
    if self.active_view and self.active_view.doc then
      save_doc_safe(self.active_view.doc)
    end
  end
  return old_node_set_active_view(self, view)
end

-- Commands
command.add(nil, {
  ["autosave:toggle"] = function()
    config.plugins.autosave.enabled = not config.plugins.autosave.enabled
    core.log("Autosave: %s", config.plugins.autosave.enabled and "Enabled" or "Disabled")
  end,
  ["autosave:save-all"] = function()
    save_all_dirty_docs()
    core.log("Autosave: Saved all modified files.")
  end
})

core.log_quiet("Autosave plugin loaded.")
