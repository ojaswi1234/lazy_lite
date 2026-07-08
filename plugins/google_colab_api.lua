-- mod-version:3
-- Google Drive API Wrapper for Colab Notebooks
-- Handles CRUD operations for Colab notebook files stored in Google Drive

local core = require "core"
local common = require "core.common"
local process = require "process"
local system = require "system"
local auth = require "plugins.google_colab_auth"

-- URL encoding function
local function encode_uri(str)
  -- Basic URL encoding
  return str:gsub("[^A-Za-z0-9%-_.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

-- Use Lite-XL's built-in JSON parsing if available
local function parse_json(str)
  -- Try to use common.parse_json if available
  if common.parse_json then
    local ok, result = pcall(common.parse_json, str)
    if ok then return result end
  end
  
  -- Fallback: try to load JSON library
  local ok, json = pcall(require, "plugins.lsp.json")
  if ok and json.decode then
    return json.decode(str)
  end
  
  -- Last resort: simple manual parsing
  -- This is very basic and won't handle all JSON
  local ok, result = pcall(loadstring("return " .. str:gsub('true', 'true'):gsub('false', 'false'):gsub('null', 'nil')))
  if ok then return result end
  
  return nil
end

local function encode_json(tbl)
  -- Try to use common.encode_json if available
  if common.encode_json then
    local ok, result = pcall(common.encode_json, tbl)
    if ok then return result end
  end
  
  -- Fallback: try to use JSON library
  local ok, json = pcall(require, "plugins.lsp.json")
  if ok and json.encode then
    return json.encode(tbl)
  end
  
  -- Last resort: simple manual encoding
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

local DRIVE_API_BASE = "https://www.googleapis.com/drive/v3/files"
local COLAB_MIME_TYPE = "application/vnd.google.colaboratory"

-- Execute curl request with OAuth token
local function curl_request(method, url, data, on_complete)
  local curl_cmd = PLATFORM == "Windows" and "curl.exe" or "curl"
  
  local args = {
    curl_cmd,
    "-X", method,
    "-H", "Authorization: Bearer " .. (auth.get_access_token() or ""),
    "-H", "Content-Type: application/json"
  }
  
  if data then
    table.insert(args, "-d")
    table.insert(args, data)
  end
  
  table.insert(args, url)
  
  core.add_thread(function()
    local p = process.start(args, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE
    })
    
    if not p then
      if on_complete then on_complete(false, "Failed to start curl process") end
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

-- List all Colab notebooks in Google Drive
local function list_notebooks(on_complete)
  local url = DRIVE_API_BASE .. "?q=mimeType='" .. COLAB_MIME_TYPE .. "'&fields=files(id,name,createdTime,modifiedTime)&pageSize=100"
  
  curl_request("GET", url, nil, function(success, out, err)
    if not success then
      if on_complete then on_complete(false, err) end
      return
    end
    
    local ok, data = pcall(parse_json, out)
    if ok and data.files then
      if on_complete then on_complete(true, data.files) end
    else
      if on_complete then on_complete(false, "Failed to parse response") end
    end
  end)
end

-- Get notebook metadata
local function get_notebook_metadata(file_id, on_complete)
  local url = DRIVE_API_BASE .. "/" .. file_id .. "?fields=id,name,createdTime,modifiedTime"
  
  curl_request("GET", url, nil, function(success, out, err)
    if not success then
      if on_complete then on_complete(false, err) end
      return
    end
    
    local ok, data = pcall(parse_json, out)
    if ok then
      if on_complete then on_complete(true, data) end
    else
      if on_complete then on_complete(false, "Failed to parse response") end
    end
  end)
end

-- Download notebook content
local function download_notebook(file_id, on_complete)
  local url = DRIVE_API_BASE .. "/" .. file_id .. "/alt=media"
  
  curl_request("GET", url, nil, function(success, out, err)
    if not success then
      if on_complete then on_complete(false, err) end
      return
    end
    
    if on_complete then on_complete(true, out) end
  end)
end

-- Create new notebook
local function create_notebook(name, content, on_complete)
  local metadata = {
    name = name,
    mimeType = COLAB_MIME_TYPE
  }
  
  local metadata_json = encode_json(metadata)
  
  -- For file creation with content, we need multipart upload
  -- Simplified version: create metadata first, then update with content
  local url = DRIVE_API_BASE
  
  curl_request("POST", url, metadata_json, function(success, out, err)
    if not success then
      if on_complete then on_complete(false, err) end
      return
    end
    
    local ok, data = pcall(parse_json, out)
    if ok and data.id then
      -- Now upload the content
      if content then
        update_notebook(data.id, content, on_complete)
      else
        if on_complete then on_complete(true, data) end
      end
    else
      if on_complete then on_complete(false, "Failed to create notebook") end
    end
  end)
end

-- Update notebook content
local function update_notebook(file_id, content, on_complete)
  local url = DRIVE_API_BASE .. "/" .. file_id
  
  curl_request("PATCH", url, content, function(success, out, err)
    if not success then
      if on_complete then on_complete(false, err) end
      return
    end
    
    local ok, data = pcall(parse_json, out)
    if ok then
      if on_complete then on_complete(true, data) end
    else
      if on_complete then on_complete(false, "Failed to update notebook") end
    end
  end)
end

-- Delete notebook (move to trash)
local function delete_notebook(file_id, on_complete)
  local url = DRIVE_API_BASE .. "/" .. file_id
  
  curl_request("PATCH", url, '{"trashed": true}', function(success, out, err)
    if not success then
      if on_complete then on_complete(false, err) end
      return
    end
    
    if on_complete then on_complete(true, out) end
  end)
end

-- Permanently delete notebook
local function permanently_delete_notebook(file_id, on_complete)
  local url = DRIVE_API_BASE .. "/" .. file_id
  
  curl_request("DELETE", url, nil, function(success, out, err)
    if not success then
      if on_complete then on_complete(false, err) end
      return
    end
    
    if on_complete then on_complete(true, out) end
  end)
end

-- Search notebooks by name
local function search_notebooks(query, on_complete)
  local escaped_query = query:gsub("'", "\\'")
  local search_query = "mimeType='" .. COLAB_MIME_TYPE .. "' and name contains '" .. escaped_query .. "'"
  local url = DRIVE_API_BASE .. "?q=" .. encode_uri(search_query) .. "&fields=files(id,name,createdTime,modifiedTime)&pageSize=50"
  
  curl_request("GET", url, nil, function(success, out, err)
    if not success then
      if on_complete then on_complete(false, err) end
      return
    end
    
    local ok, data = pcall(parse_json, out)
    if ok and data.files then
      if on_complete then on_complete(true, data.files) end
    else
      if on_complete then on_complete(false, "Failed to parse response") end
    end
  end)
end

-- Export functions
return {
  list_notebooks = list_notebooks,
  get_notebook_metadata = get_notebook_metadata,
  download_notebook = download_notebook,
  create_notebook = create_notebook,
  update_notebook = update_notebook,
  delete_notebook = delete_notebook,
  permanently_delete_notebook = permanently_delete_notebook,
  search_notebooks = search_notebooks,
  COLAB_MIME_TYPE = COLAB_MIME_TYPE
}