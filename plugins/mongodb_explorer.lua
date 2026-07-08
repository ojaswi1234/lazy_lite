-- mod-version:3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local process = require "process"
local common = require "core.common"

-- Basic JSON Parser for reading bridge output
local function decode_json(str)
  local ok, json = pcall(require, "plugins.lsp.json")
  if ok and json.decode then return json.decode(str) end
  
  -- Extremely basic fallback for our specific bridge outputs
  local obj = {}
  local is_success = str:match('"success":%s*true')
  obj.success = is_success ~= nil
  
  local action = str:match('"action":%s*"([^"]+)"')
  if action then obj.action = action end
  
  local err = str:match('"error":%s*"([^"]+)"')
  if err then obj.error = err end
  
  if action == "list_databases" then
    obj.databases = {}
    for db in str:gmatch('"([^"]+)"') do
      if db ~= "success" and db ~= "action" and db ~= "list_databases" and db ~= "databases" then
        table.insert(obj.databases, db)
      end
    end
  end
  return obj
end

local function encode_json(tbl)
  local ok, json = pcall(require, "plugins.lsp.json")
  if ok and json.encode then return json.encode(tbl) end
  
  local parts = {}
  for k, v in pairs(tbl) do
    local val = type(v) == "string" and '"' .. v:gsub('"', '\\"') .. '"' or tostring(v)
    table.insert(parts, '"' .. k .. '":' .. val)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local mongo = {
  proc = nil,
  uri = nil,
  current_db = nil,
  buffer = ""
}

local function get_bridge_path()
  local USERDIR = USERDIR or core.userdir or (os.getenv("USERPROFILE") or os.getenv("HOME")) .. "/.config/lite-xl"
  local PATHSEP = PATHSEP or package.config:sub(1,1)
  return USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "mongodb_bridge.py"
end

local function start_bridge()
  if mongo.proc then return true end
  
  local python_cmd = PLATFORM == "Windows" and "python" or "python3"
  mongo.proc = process.start({python_cmd, get_bridge_path()}, {
    stdin = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE
  })
  
  if not mongo.proc then
    core.error("Failed to start MongoDB bridge. Is Python installed?")
    return false
  end
  return true
end

local function check_dependencies()
  core.log_quiet("Checking MongoDB dependencies...")
  local python_cmd = PLATFORM == "Windows" and "python" or "python3"
  local p = process.start({python_cmd, "-c", "import pymongo"}, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE
  })
  
  if not p then return false end
  
  while p:returncode() == nil do
    coroutine.yield(0.1)
  end
  
  return p:returncode() == 0
end

local function send_request(req, callback)
  if not start_bridge() then return end
  
  mongo.proc:write(encode_json(req) .. "\n")
  
  -- Wait for response in a thread
  core.add_thread(function()
    local result = ""
    while true do
      local chunk = mongo.proc:read_stdout(4096)
      if chunk then
        result = result .. chunk
        if chunk:match("\n$") then break end
      else
        coroutine.yield(0.01)
      end
    end
    
    local ok, parsed = pcall(decode_json, result)
    if ok and parsed then
      if callback then callback(parsed) end
    else
      core.error("Failed to parse MongoDB bridge response")
    end
  end)
end

-- Commands
command.add(nil, {
  ["mongodb:connect"] = function()
    core.command_view:enter("MongoDB Connection String (URI):", {
      submit = function(uri)
        mongo.uri = uri
        core.log_quiet("Connecting to MongoDB...")
        send_request({action = "connect", uri = uri}, function(res)
          if res.success then
            core.log("Connected to MongoDB successfully!")
          else
            core.error("MongoDB Connection Failed: " .. (res.error or "Unknown error"))
          end
        end)
      end
    })
  end,
  
  ["mongodb:explore-databases"] = function()
    if not mongo.uri then
      core.error("Please connect to MongoDB first")
      return
    end
    
    core.log_quiet("Fetching databases...")
    send_request({action = "list_databases", uri = mongo.uri}, function(res)
      if res.success and res.databases then
        core.command_view:enter("Select Database", {
          submit = function(db_name)
            mongo.current_db = db_name
            core.log("Selected Database: " .. db_name)
            command.perform("mongodb:explore-collections")
          end,
          suggest = function(text)
            local suggestions = {}
            for _, db in ipairs(res.databases) do
              if db:lower():find(text:lower(), 1, true) then
                table.insert(suggestions, db)
              end
            end
            return suggestions
          end
        })
      else
        core.error("Failed to fetch databases")
      end
    end)
  end,
  
  ["mongodb:explore-collections"] = function()
    if not mongo.current_db then
      core.error("Please select a database first")
      return
    end
    
    core.log_quiet("Fetching collections for " .. mongo.current_db .. "...")
    send_request({action = "list_collections", uri = mongo.uri, db = mongo.current_db}, function(res)
      if res.success and res.collections then
        core.command_view:enter("Select Collection", {
          submit = function(col_name)
            core.log_quiet("Fetching documents from " .. col_name .. "...")
            send_request({
              action = "find", 
              uri = mongo.uri, 
              db = mongo.current_db, 
              collection = col_name,
              limit = 50
            }, function(doc_res)
              if doc_res.success and doc_res.documents then
                -- Open documents in a new scratch buffer
                local doc = core.open_doc()
                
                -- Attempt to format JSON nicely if LSP json is available
                local ok, json = pcall(require, "plugins.lsp.json")
                local formatted = ""
                if ok and json.encode then
                  -- Hack for pretty print since plugins.lsp.json doesn't natively indent
                  formatted = json.encode(doc_res.documents)
                  formatted = formatted:gsub('{"_id"', '{\n  "_id"')
                                     :gsub(',"', ',\n  "')
                                     :gsub('} ,', '\n},\n')
                else
                  formatted = require("core.common").serialize(doc_res.documents) or "Parse error"
                end
                
                doc:insert(1, 1, "// MongoDB Collection: " .. col_name .. " (Limit: 50)\n" .. formatted)
                core.root_view:open_doc(doc)
                core.log("Opened collection: " .. col_name)
              else
                core.error("Failed to fetch documents")
              end
            end)
          end,
          suggest = function(text)
            local suggestions = {}
            for _, col in ipairs(res.collections) do
              if col:lower():find(text:lower(), 1, true) then
                table.insert(suggestions, col)
              end
            end
            return suggestions
          end
        })
      else
        core.error("Failed to fetch collections")
      end
    end)
  end,
  
  ["mongodb:install-dependencies"] = function()
    core.log("Installing PyMongo via pip...")
    local python_cmd = PLATFORM == "Windows" and "python" or "python3"
    
    core.add_thread(function()
      local p = process.start({python_cmd, "-m", "pip", "install", "pymongo"}, {
        stdout = process.REDIRECT_PIPE,
        stderr = process.REDIRECT_PIPE
      })
      
      if not p then
        core.error("Failed to start pip installer. Is Python installed?")
        return
      end
      
      while p:returncode() == nil do
        coroutine.yield(0.1)
      end
      
      if p:returncode() == 0 then
        core.log("PyMongo successfully installed! You can now connect to MongoDB.")
      else
        core.error("Failed to install PyMongo. Check your Python installation.")
      end
    end)
  end
})

-- Initialize Toolbar UI if available
core.add_thread(function()
  if core.toolbar_view and type(core.toolbar_view.toolbar_commands) == "table" then
    table.insert(core.toolbar_view.toolbar_commands, {
      symbol = "M",
      command = "mongodb:connect",
      tooltip = "Connect to MongoDB"
    })
  end
  
  -- Check dependencies quietly on startup
  if not check_dependencies() then
    core.log_quiet("MongoDB dependencies missing. Run 'MongoDB: Install Dependencies' to enable the explorer.")
  end
end)

return mongo
