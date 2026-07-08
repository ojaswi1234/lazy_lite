-- mod-version:3
-- Google Colab Runtime Execution
-- Handles code cell execution on Google Colab's cloud runtime

local core = require "core"
local common = require "core.common"
local process = require "process"
local system = require "system"
local PATHSEP = PATHSEP or package.config:sub(1,1)
local USERDIR = USERDIR or core.userdir or (os.getenv("USERPROFILE") or os.getenv("HOME")) .. "/.config/lite-xl"

local runtime_state = {
  connected = false,
  runtime_id = nil,
  notebook_id = nil,
  tunnel_id = nil,
  execution_count = 0,
  runtime_type = "CPU", -- CPU, GPU, TPU
  pending_executions = {}
}

-- Check if Colab MCP Server bridge is available
local function check_mcp_bridge()
  local bridge_path = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "colab_mcp_bridge.py"
  return system.get_file_info(bridge_path) ~= nil
end

-- Execute code cell using Colab MCP Server (preferred method)
local function execute_cell_mcp(notebook_id, cell_id, code, on_complete)
  if not check_mcp_bridge() then
    if on_complete then on_complete(false, "Colab MCP bridge not found") end
    return
  end
  
  local python_cmd = PLATFORM == "Windows" and "python" or "python3"
  local bridge_path = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "colab_mcp_bridge.py"
  
  core.add_thread(function()
    local p = process.start({
      python_cmd, bridge_path,
      "execute",
      "--notebook_id", notebook_id,
      "--cell_id", cell_id,
      "--code", code
    }, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE
    })
    
    if not p then
      if on_complete then on_complete(false, "Failed to start MCP bridge") end
      return
    end
    
    local out = ""
    local err = ""
    
    while p:returncode() == nil do
      local chunk = p:read_stdout(4096)
      if chunk then out = out .. chunk end
      local echunk = p:read_stderr(4096)
      if echunk then err = err .. echunk end
      coroutine.yield(0.1)
    end
    
    local chunk = p:read_stdout(4096)
    if chunk then out = out .. chunk end
    local echunk = p:read_stderr(4096)
    if echunk then err = err .. echunk end
    
    local success = p:returncode() == 0
    if on_complete then on_complete(success, out, err) end
  end)
end

-- Execute code cell using direct Colab Runtime API (fallback)
local function execute_cell_direct(notebook_id, cell_id, code, on_complete)
  -- This would use the Colab Runtime API directly
  -- For now, we'll implement a placeholder that simulates execution
  
  core.add_thread(function()
    -- Simulate execution delay
    coroutine.yield(1)
    
    -- In a real implementation, this would:
    -- 1. Connect to Colab runtime via WebSocket
    -- 2. Send the code to be executed
    -- 3. Receive output (stdout, stderr, display_data, error)
    -- 4. Parse and return the results
    
    local mock_output = {
      output_type = "stream",
      name = "stdout",
      text = "Execution simulated - implement direct Colab Runtime API connection"
    }
    
    if on_complete then on_complete(true, mock_output) end
  end)
end

-- Execute a single code cell
local function execute_cell(notebook_id, cell_id, code, on_complete)
  runtime_state.execution_count = runtime_state.execution_count + 1
  
  -- Try MCP bridge first, fall back to direct API
  if check_mcp_bridge() then
    execute_cell_mcp(notebook_id, cell_id, code, function(success, out, err)
      if success then
        if on_complete then on_complete(true, out) end
      else
        -- Fall back to direct API
        core.log_quiet("MCP bridge failed, trying direct API: %s", tostring(err))
        execute_cell_direct(notebook_id, cell_id, code, on_complete)
      end
    end)
  else
    execute_cell_direct(notebook_id, cell_id, code, on_complete)
  end
end

-- Execute all code cells in sequence
local function execute_all_cells(notebook_id, cells, on_complete, on_progress)
  local total_cells = #cells
  local completed = 0
  local results = {}
  
  for i, cell in ipairs(cells) do
    if cell.cell_type == "code" then
      execute_cell(notebook_id, cell.id or tostring(i), table.concat(cell.source, "\n"), function(success, output)
        completed = completed + 1
        results[i] = { success = success, output = output }
        
        if on_progress then
          on_progress(completed, total_cells, i)
        end
        
        if completed == total_cells then
          if on_complete then on_complete(results) end
        end
      end)
    else
      -- Skip markdown cells
      completed = completed + 1
      if completed == total_cells and on_complete then
        on_complete(results)
      end
    end
  end
end

-- Connect to Colab runtime
local function connect_runtime(notebook_id, runtime_type, on_complete)
  runtime_type = runtime_type or "CPU"
  runtime_state.notebook_id = notebook_id
  runtime_state.runtime_type = runtime_type
  
  -- Check if MCP bridge is available
  if check_mcp_bridge() then
    local python_cmd = PLATFORM == "Windows" and "python" or "python3"
    local bridge_path = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "colab_mcp_bridge.py"
    
    core.add_thread(function()
      local p = process.start({
        python_cmd, bridge_path,
        "connect",
        "--notebook_id", notebook_id,
        "--runtime_type", runtime_type
      }, {
        stdout = process.REDIRECT_PIPE,
        stderr = process.REDIRECT_PIPE
      })
      
      if not p then
        if on_complete then on_complete(false, "Failed to start MCP bridge") end
        return
      end
      
      local out = ""
      local err = ""
      
      while p:returncode() == nil do
        local chunk = p:read_stdout(4096)
        if chunk then out = out .. chunk end
        local echunk = p:read_stderr(4096)
        if echunk then err = err .. echunk end
        coroutine.yield(0.1)
      end
      
      local chunk = p:read_stdout(4096)
      if chunk then out = out .. chunk end
      local echunk = p:read_stderr(4096)
      if echunk then err = err .. echunk end
      
      local success = p:returncode() == 0
      if success then
        runtime_state.connected = true
        -- Parse runtime_id from output if available
        runtime_state.runtime_id = out:match("runtime_id:(%S+)") or "unknown"
      end
      
      if on_complete then on_complete(success, out, err) end
    end)
  else
    -- Simulate connection for direct API
    core.add_thread(function()
      coroutine.yield(0.5)
      runtime_state.connected = true
      runtime_state.runtime_id = "simulated_" .. tostring(system.get_time())
      if on_complete then on_complete(true, "Connected to runtime (simulated)") end
    end)
  end
end

-- Disconnect from runtime
local function disconnect_runtime(on_complete)
  if check_mcp_bridge() then
    local python_cmd = PLATFORM == "Windows" and "python" or "python3"
    local bridge_path = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "colab_mcp_bridge.py"
    
    core.add_thread(function()
      local p = process.start({
        python_cmd, bridge_path,
        "disconnect"
      }, {
        stdout = process.REDIRECT_PIPE,
        stderr = process.REDIRECT_PIPE
      })
      
      -- Wait for process to complete
      while p:returncode() == nil do
        coroutine.yield(0.1)
      end
      
      runtime_state.connected = false
      runtime_state.runtime_id = nil
      runtime_state.notebook_id = nil
      
      if on_complete then on_complete(true) end
    end)
  else
    runtime_state.connected = false
    runtime_state.runtime_id = nil
    runtime_state.notebook_id = nil
    if on_complete then on_complete(true) end
  end
end

-- Install package in runtime
local function install_package(package_name, on_complete)
  if not runtime_state.connected then
    if on_complete then on_complete(false, "Not connected to runtime") end
    return
  end
  
  local install_code = string.format("!pip install %s", package_name)
  execute_cell(runtime_state.notebook_id, "install_" .. package_name, install_code, on_complete)
end

-- Get runtime status
local function get_runtime_status()
  return {
    connected = runtime_state.connected,
    runtime_id = runtime_state.runtime_id,
    notebook_id = runtime_state.notebook_id,
    runtime_type = runtime_state.runtime_type,
    execution_count = runtime_state.execution_count
  }
end

-- Export functions
return {
  execute_cell = execute_cell,
  execute_all_cells = execute_all_cells,
  connect_runtime = connect_runtime,
  disconnect_runtime = disconnect_runtime,
  install_package = install_package,
  get_runtime_status = get_runtime_status,
  is_connected = function() return runtime_state.connected end
}