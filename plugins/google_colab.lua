-- mod-version:3
-- Google Colab Integration for Lite-XL
-- Main plugin with UI and logic for notebook management

local core = require "core"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local common = require "core.common"
local View = require "core.view"
-- renderer and system are globals in Lite-XL
local PATHSEP = PATHSEP or package.config:sub(1,1)
local USERDIR = USERDIR or core.userdir or (os.getenv("USERPROFILE") or os.getenv("HOME")) .. "/.config/lite-xl"

-- Load modules with error handling
local auth_ok, auth = pcall(require, "plugins.google_colab_auth")
local api_ok, api = pcall(require, "plugins.google_colab_api")
local runtime_ok, runtime = pcall(require, "plugins.google_colab_runtime")
local view_ok, NotebookView = pcall(require, "plugins.google_colab_view")

if not auth_ok then
  core.log_quiet("Failed to load google_colab_auth: %s", tostring(auth))
  auth = {
    authenticate = function() end,
    is_authenticated = function() return false end,
    get_access_token = function() return nil end
  }
end

if not api_ok then
  core.log_quiet("Failed to load google_colab_api: %s", tostring(api))
  api = {
    list_notebooks = function() end,
    download_notebook = function() end,
    create_notebook = function() end,
    update_notebook = function() end,
    delete_notebook = function() end
  }
end

if not runtime_ok then
  core.log_quiet("Failed to load google_colab_runtime: %s", tostring(runtime))
  runtime = {
    execute_cell = function() end,
    execute_all_cells = function() end,
    connect_runtime = function() end,
    disconnect_runtime = function() end,
    get_runtime_status = function() return {connected = false, runtime_type = "CPU"} end,
    is_connected = function() return false end
  }
end

if not view_ok then
  core.log_quiet("Failed to load google_colab_view: %s", tostring(NotebookView))
  NotebookView = View
end

local COLAB_ICON = "\u{F1BB}" -- Google icon (unicode)
local COLAB_ICON_COLOR = {r=66, g=133, b=244} -- Google blue

local state = {
  authenticated = false,
  current_notebook = nil,
  current_notebook_id = nil,
  notebook_view = nil,
  notebooks = {},
  selected_notebook_index = 1,
  local_notebook_dir = USERDIR .. PATHSEP .. "colab_notebooks"
}

-- Ensure local notebook directory exists
system.mkdir(state.local_notebook_dir)

-- Modal UI View
local ColabModal = View:extend()

function ColabModal:new()
  ColabModal.super.new(self)
  self.state = "auth"
  self.message = "Google Colab"
  self.width = 600
  self.height = 400
  self.selected_index = 1
  self.loading_angle = 0
end

function ColabModal:get_name()
  return "Google Colab"
end

function ColabModal:update()
  ColabModal.super.update(self)
  -- Animate loading spinner
  if self.state == "loading" then
    self.loading_angle = (self.loading_angle + 2) % 360
  end
end

function ColabModal:draw()
  self:draw_background(style.background)
  
  local x, y, w, h = self:get_content_bounds()
  local cx = x + w / 2
  local cy = y + h / 2
  
  -- Draw modal background
  local modal_w = self.width
  local modal_h = self.height
  local modal_x = cx - modal_w / 2
  local modal_y = cy - modal_h / 2
  
  renderer.draw_rect(modal_x, modal_y, modal_w, modal_h, style.background2)
  renderer.draw_rect(modal_x, modal_y, modal_w, 2, style.accent)
  renderer.draw_rect(modal_x, modal_y + modal_h - 2, modal_w, 2, style.accent)
  renderer.draw_rect(modal_x, modal_y, 2, modal_h, style.accent)
  renderer.draw_rect(modal_x + modal_w - 2, modal_y, 2, modal_h, style.accent)
  
  -- Draw content based on state
  if self.state == "auth" then
    self:draw_auth_view(modal_x, modal_y, modal_w, modal_h)
  elseif self.state == "loading" then
    self:draw_loading_view(modal_x, modal_y, modal_w, modal_h)
  elseif self.state == "list" then
    self:draw_notebook_list(modal_x, modal_y, modal_w, modal_h)
  elseif self.state == "notebook" then
    self:draw_notebook_view(modal_x, modal_y, modal_w, modal_h)
  end
end

function ColabModal:draw_auth_view(x, y, w, h)
  local title = "Google Colab Integration"
  local subtitle = "Connect to Google to access your notebooks"
  
  -- Draw title
  local title_y = y + 60
  renderer.draw_text(style.font, title, x + w/2 - style.font:get_width(title)/2, title_y, style.text)
  
  -- Draw subtitle
  local subtitle_y = title_y + style.font:get_height() + 20
  renderer.draw_text(style.font, subtitle, x + w/2 - style.font:get_width(subtitle)/2, subtitle_y, style.dim)
  
  -- Draw instructions
  local instructions = {
    "Press 'Enter' to authenticate with Google",
    "A browser window will open for OAuth login",
    "After authentication, your notebooks will be listed",
    "",
    "Press 'Escape' to close"
  }
  
  local instr_y = subtitle_y + style.font:get_height() + 40
  for i, instr in ipairs(instructions) do
    renderer.draw_text(style.font, instr, x + w/2 - style.font:get_width(instr)/2, instr_y + (i-1) * (style.font:get_height() + 10), style.dim)
  end
  
  -- Draw Google icon (colored circle)
  local icon_x = x + w/2 - 30
  local icon_y = y + h - 100
  renderer.draw_rect(icon_x, icon_y, 60, 60, COLAB_ICON_COLOR)
  renderer.draw_text(style.font, "G", icon_x + 60/2 - style.font:get_width("G")/2, icon_y + 60/2 - style.font:get_height()/2, {r=255, g=255, b=255})
end

function ColabModal:draw_loading_view(x, y, w, h)
  local message = self.message or "Loading..."
  
  -- Draw loading message
  renderer.draw_text(style.font, message, x + w/2 - style.font:get_width(message)/2, y + h/2 - style.font:get_height()/2, style.text)
  
  -- Draw animated spinner
  local spinner_x = x + w/2
  local spinner_y = y + h/2 + 30
  local radius = 20
  
  for i = 0, 7 do
    local angle = math.rad(self.loading_angle + i * 45)
    local px = spinner_x + math.cos(angle) * radius
    local py = spinner_y + math.sin(angle) * radius
    local alpha = 255 - (i * 30)
    renderer.draw_rect(px - 2, py - 2, 4, 4, {r=100, g=100, b=100, a=alpha})
  end
end

function ColabModal:draw_notebook_list(x, y, w, h)
  local title = "Your Notebooks"
  local header_y = y + 40
  
  -- Draw title
  renderer.draw_text(style.font, title, x + w/2 - style.font:get_width(title)/2, header_y, style.text)
  
  -- Draw instructions
  local instructions = "Use arrow keys to navigate, Enter to open, Escape to close"
  renderer.draw_text(style.font, instructions, x + w/2 - style.font:get_width(instructions)/2, header_y + style.font:get_height() + 10, style.dim)
  
  -- Draw notebook list
  local list_y = header_y + style.font:get_height() + 40
  local item_height = 40
  local max_items = math.floor((h - list_y - 20) / item_height)
  
  if #state.notebooks == 0 then
    local no_notebooks = "No notebooks found. Press 'n' to create a new one."
    renderer.draw_text(style.font, no_notebooks, x + w/2 - style.font:get_width(no_notebooks)/2, list_y + 50, style.dim)
  else
  
  for i = 1, math.min(#state.notebooks, max_items) do
    local notebook = state.notebooks[i]
    local item_y = list_y + (i - 1) * item_height
    
    -- Highlight selected item
    if i == self.selected_index then
      renderer.draw_rect(x + 20, item_y, w - 40, item_height - 5, style.mossy.active_row or {r=191, g=211, a=167})
    end
    
    -- Draw notebook name
    renderer.draw_text(style.font, notebook.name, x + 30, item_y + 10, i == self.selected_index and style.accent or style.text)
    
    -- Draw modified date
    local date_str = notebook.modifiedTime or ""
    if date_str then
      date_str = date_str:sub(1, 10) -- Extract date part
      renderer.draw_text(style.font, date_str, x + w - 30 - style.font:get_width(date_str), item_y + 10, style.dim)
    end
  end
  end
end

function ColabModal:draw_notebook_view(x, y, w, h)
  local title = state.current_notebook and state.current_notebook.name or "Notebook"
  
  -- Draw title
  renderer.draw_text(style.font, title, x + w/2 - style.font:get_width(title)/2, y + 40, style.text)
  
  -- Draw runtime status
  local runtime_status = runtime.get_runtime_status()
  local status_text = "Runtime: " .. (runtime_status.connected and "Connected (" .. runtime_status.runtime_type .. ")" or "Disconnected")
  renderer.draw_text(style.font, status_text, x + w/2 - style.font:get_width(status_text)/2, y + 70, runtime_status.connected and style.accent or style.dim)
  
  -- Draw controls
  local controls = {
    "Shift+Enter: Run cell",
    "Ctrl+Enter: Run cell (no advance)",
    "Ctrl+Shift+Enter: Run all cells",
    "Ctrl+Alt+C: Add code cell",
    "Ctrl+Alt+M: Add markdown cell",
    "Ctrl+Alt+D: Delete cell",
    "Escape: Close modal"
  }
  
  local controls_y = y + 120
  for i, control in ipairs(controls) do
    renderer.draw_text(style.font, control, x + w/2 - style.font:get_width(control)/2, controls_y + (i-1) * (style.font:get_height() + 5), style.dim)
  end
end

function ColabModal:on_mouse_pressed(button, x, y, clicks)
  -- Handle mouse clicks in the modal
  return true
end

function ColabModal:on_key_pressed(key)
  if key == "escape" then
    close_colab_modal()
    return true
  elseif self.state == "auth" and key == "return" then
    authenticate()
    return true
  elseif self.state == "list" then
    if key == "up" then
      self.selected_index = math.max(1, self.selected_index - 1)
      return true
    elseif key == "down" then
      self.selected_index = math.min(#state.notebooks, self.selected_index + 1)
      return true
    elseif key == "return" then
      if #state.notebooks > 0 and state.notebooks[self.selected_index] then
        local notebook = state.notebooks[self.selected_index]
        open_notebook(notebook.id, notebook.name)
      end
      return true
    elseif key == "n" then
      -- Create new notebook
      core.command_view:enter("Notebook name:", {
        submit = function(name)
          create_notebook(name)
        end
      })
      return true
    end
  end
  
  return false
end

-- Create modal instance
local colab_modal = ColabModal()

-- Status bar integration
local status_item_added = false
if type(core.status_view.add_item) == "function" and core.status_view.Item then
  local success, err = pcall(function()
    core.status_view:add_item({
      name = "colab:status",
      alignment = core.status_view.Item.RIGHT,
      position = 1,
      tooltip = "Google Colab Status (click to open)",
      get_item = function()
        if not state.authenticated then
          return {}
        end
        
        local status_items = {}
        local icon_color = COLAB_ICON_COLOR
        local runtime_status = runtime.get_runtime_status()
        
        -- Add Colab icon
        table.insert(status_items, icon_color)
        table.insert(status_items, style.font)
        table.insert(status_items, COLAB_ICON)
        
        -- Add runtime status if connected
        if runtime_status.connected then
          table.insert(status_items, style.dim)
          table.insert(status_items, style.font)
          table.insert(status_items, " " .. runtime_status.runtime_type)
        end
        
        return status_items
      end,
      on_click = function()
        open_colab_modal()
      end
    })
  end)
  
  if success then
    status_item_added = true
  end
end

local open_colab_modal
local close_colab_modal
local authenticate
local create_notebook
local open_notebook
local save_notebook
local delete_notebook
local connect_runtime
local disconnect_runtime
local run_current_cell
local run_all_cells

-- Open Colab modal
open_colab_modal = function()
  colab_modal.state = "auth"
  colab_modal.message = "Google Colab"
  colab_modal.selected_index = 1
  
  -- Add modal to root view
  local node = core.root_view.root_node
  node:add_view(colab_modal)
  
  if auth.is_authenticated() then
    colab_modal.state = "loading"
    colab_modal.message = "Loading notebooks..."
    api.list_notebooks(function(success, notebooks)
      if success then
        state.notebooks = notebooks
        colab_modal.state = "list"
        colab_modal.message = "Select a notebook"
      else
        colab_modal.state = "auth"
        colab_modal.message = "Failed to load notebooks"
      end
    end)
  end
  
  core.redraw = true
end

-- Close Colab modal
close_colab_modal = function()
  -- Remove modal from root view
  local node = core.root_view.root_node
  for i, view in ipairs(node:get_children()) do
    if view == colab_modal then
      node:remove_view(colab_modal)
      break
    end
  end
  state.notebook_view = nil
  core.redraw = true
end

-- Authenticate with Google
authenticate = function()
  colab_modal.state = "loading"
  colab_modal.message = "Authenticating with Google..."
  core.redraw = true
  
  auth.authenticate(function(success, message)
    if success then
      state.authenticated = true
      colab_modal.state = "loading"
      colab_modal.message = "Loading notebooks..."
      api.list_notebooks(function(success, notebooks)
        if success then
          state.notebooks = notebooks
          colab_modal.state = "list"
          colab_modal.message = "Select a notebook"
        else
          colab_modal.state = "auth"
          colab_modal.message = "Failed to load notebooks"
        end
      end)
    else
      colab_modal.state = "auth"
      colab_modal.message = "Authentication failed: " .. tostring(message)
    end
    core.redraw = true
  end)
end

-- Create new notebook
create_notebook = function(name)
  if not state.authenticated then
    core.log_quiet("Not authenticated with Google Colab")
    return
  end
  
  name = name or "Untitled Notebook"
  
  local initial_content = [[{
  "metadata": {
    "kernelspec": {
      "display_name": "Python 3",
      "language": "python",
      "name": "python3"
    },
    "colab": {
      "provenance": []
    }
  },
  "nbformat": 4,
  "nbformat_minor": 0,
  "cells": [
    {
      "cell_type": "markdown",
      "metadata": {},
      "source": ["# " .. name .. "\n"]
    },
    {
      "cell_type": "code",
      "execution_count": null,
      "metadata": {},
      "outputs": [],
      "source": ["# Your code here\n"]
    }
  ]
}]]
  
  api.create_notebook(name, initial_content, function(success, data)
    if success then
      core.log("Created notebook: %s", name)
      open_notebook(data.id, name)
    else
      core.log_quiet("Failed to create notebook")
    end
  end)
end

-- Open notebook
open_notebook = function(notebook_id, name)
  colab_modal.state = "loading"
  colab_modal.message = "Loading notebook..."
  core.redraw = true
  
  state.current_notebook_id = notebook_id
  state.current_notebook = { id = notebook_id, name = name }
  
  api.download_notebook(notebook_id, function(success, content)
    if success then
      -- Parse notebook JSON with fallback
      local parse_func = common.parse_json or function(str) 
        local ok, result = pcall(loadstring("return " .. str:gsub('true', 'true'):gsub('false', 'false'):gsub('null', 'nil')))
        if ok then return result else return nil end
      end
      local ok, notebook_data = pcall(parse_func, content)
      if ok then
        -- Create notebook view
        state.notebook_view = NotebookView()
        state.notebook_view:set_notebook_data(notebook_data)
        
        -- Add view to root
        local node = core.root_view.root_node
        node:split("right", state.notebook_view, true)
        
        colab_modal.state = "notebook"
        colab_modal.message = name
        core.log("Opened notebook: %s", name)
      else
        core.log_quiet("Failed to parse notebook JSON")
        colab_modal.state = "list"
      end
    else
      core.log_quiet("Failed to download notebook")
      colab_modal.state = "list"
    end
    core.redraw = true
  end)
end

-- Save notebook
save_notebook = function()
  if not state.notebook_view or not state.current_notebook_id then
    core.log_quiet("No notebook open")
    return
  end
  
  local notebook_data = state.notebook_view.notebook_data
  local encode_func = common.encode_json or function(tbl)
    -- Basic JSON encoding fallback
    local function serialize(val)
      local t = type(val)
      if t == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
      elseif t == "number" then
        return tostring(val)
      elseif t == "boolean" then
        return tostring(val)
      elseif t == "nil" then
        return "null"
      elseif t == "table" then
        local is_array = #val > 0
        local parts = {}
        if is_array then
          for i, v in ipairs(val) do
            table.insert(parts, serialize(v))
          end
          return "[" .. table.concat(parts, ",") .. "]"
        else
          for k, v in pairs(val) do
            local key = type(k) == "string" and '"' .. k .. '"' or tostring(k)
            table.insert(parts, key .. ":" .. serialize(v))
          end
          return "{" .. table.concat(parts, ",") .. "}"
        end
      else
        return "null"
      end
    end
    return serialize(tbl)
  end
  local content = encode_func(notebook_data)
  
  api.update_notebook(state.current_notebook_id, content, function(success, data)
    if success then
      core.log("Saved notebook: %s", state.current_notebook.name)
    else
      core.log_quiet("Failed to save notebook")
    end
  end)
end

-- Delete notebook
delete_notebook = function(notebook_id)
  api.delete_notebook(notebook_id, function(success)
    if success then
      core.log("Deleted notebook")
      -- Refresh list
      api.list_notebooks(function(success, notebooks)
        if success then
          state.notebooks = notebooks
        end
      end)
    else
      core.log_quiet("Failed to delete notebook")
    end
  end)
end

-- Connect to runtime
connect_runtime = function(runtime_type)
  if not state.current_notebook_id then
    core.log_quiet("No notebook open")
    return
  end
  
  runtime_type = runtime_type or "CPU"
  
  runtime.connect_runtime(state.current_notebook_id, runtime_type, function(success, message)
    if success then
      core.log("Connected to %s runtime", runtime_type)
      if state.notebook_view then
        state.notebook_view:set_runtime_status("connected", runtime_type)
      end
    else
      core.log_quiet("Failed to connect to runtime: %s", tostring(message))
    end
  end)
end

-- Disconnect from runtime
disconnect_runtime = function()
  runtime.disconnect_runtime(function(success)
    if success then
      core.log("Disconnected from runtime")
      if state.notebook_view then
        state.notebook_view:set_runtime_status("disconnected")
      end
    end
  end)
end

-- Run current cell
run_current_cell = function()
  if not state.notebook_view or not runtime.is_connected() then
    core.log_quiet("Not connected to runtime")
    return
  end
  
  local cell_index = state.notebook_view.selected_cell_index
  local cell = state.notebook_view:get_cell(cell_index)
  
  if not cell or cell.cell_type ~= "code" then
    core.log_quiet("Not a code cell")
    return
  end
  
  local code = table.concat(cell.source, "\n")
  
  runtime.execute_cell(state.current_notebook_id, tostring(cell_index), code, function(success, output)
    if success then
      state.notebook_view:update_output(cell_index, output)
      -- Increment execution count
      cell.execution_count = (cell.execution_count or 0) + 1
    else
      core.log_quiet("Execution failed")
    end
  end)
end

-- Run all cells
run_all_cells = function()
  if not state.notebook_view or not runtime.is_connected() then
    core.log_quiet("Not connected to runtime")
    return
  end
  
  local cells = state.notebook_view.notebook_data.cells
  runtime.execute_all_cells(state.current_notebook_id, cells, function(results)
    -- Update all outputs
    for i, result in ipairs(results) do
      if result.success then
        state.notebook_view:update_output(i, result.output)
      end
    end
  end, function(completed, total, current_index)
    -- Progress callback
    core.log_quiet("Executing cell %d of %d", current_index, total)
  end)
end

-- Commands
command.add("core", {
  ["colab:open"] = function()
    open_colab_modal()
  end,
  
  ["colab:close"] = function()
    close_colab_modal()
  end,
  
  ["colab:authenticate"] = function()
    authenticate()
  end,
  
  ["colab:create-notebook"] = function()
    core.command_view:enter("Notebook name:", {
      submit = function(name)
        create_notebook(name)
      end
    })
  end,
  
  ["colab:save-notebook"] = function()
    save_notebook()
  end,
  
  ["colab:connect-runtime"] = function()
    core.command_view:enter("Runtime type (CPU/GPU/TPU):", {
      submit = function(runtime_type)
        connect_runtime(runtime_type:upper())
      end,
      text = "CPU"
    })
  end,
  
  ["colab:disconnect-runtime"] = function()
    disconnect_runtime()
  end,
  
  ["colab:run-cell"] = function()
    run_current_cell()
    -- Advance to next cell
    if state.notebook_view then
      state.notebook_view.selected_cell_index = state.notebook_view.selected_cell_index + 1
    end
  end,
  
  ["colab:run-cell-no-advance"] = function()
    run_current_cell()
  end,
  
  ["colab:run-all-cells"] = function()
    run_all_cells()
  end,
  
  ["colab:add-code-cell"] = function()
    if state.notebook_view then
      state.notebook_view:add_cell("code")
    end
  end,
  
  ["colab:add-markdown-cell"] = function()
    if state.notebook_view then
      state.notebook_view:add_cell("markdown")
    end
  end,
  
  ["colab:delete-cell"] = function()
    if state.notebook_view then
      state.notebook_view:delete_cell()
    end
  end,
  
  ["colab:move-cell-up"] = function()
    if state.notebook_view then
      state.notebook_view:move_cell(nil, -1)
    end
  end,
  
  ["colab:move-cell-down"] = function()
    if state.notebook_view then
      state.notebook_view:move_cell(nil, 1)
    end
  end
})

-- Keybindings (avoid conflicts with existing keybindings)
keymap.add {
  ["alt+c"] = "colab:open",
  ["ctrl+shift+n"] = "colab:save-notebook",
  ["shift+return"] = "colab:run-cell",
  ["ctrl+return"] = "colab:run-cell-no-advance",
  ["ctrl+shift+return"] = "colab:run-all-cells",
  ["ctrl+alt+c"] = "colab:add-code-cell",
  ["ctrl+alt+m"] = "colab:add-markdown-cell",
  ["ctrl+alt+d"] = "colab:delete-cell",
  ["ctrl+alt+up"] = "colab:move-cell-up",
  ["ctrl+alt+down"] = "colab:move-cell-down"
}

-- Initialize
core.add_thread(function()
  -- Check if already authenticated
  if auth.is_authenticated() then
    state.authenticated = true
  end
end)

return {
  open = open_colab_modal,
  close = close_colab_modal,
  authenticate = authenticate,
  create_notebook = create_notebook,
  open_notebook = open_notebook,
  save_notebook = save_notebook,
  delete_notebook = delete_notebook,
  connect_runtime = connect_runtime,
  disconnect_runtime = disconnect_runtime,
  run_current_cell = run_current_cell,
  run_all_cells = run_all_cells
}
