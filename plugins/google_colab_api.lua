-- mod-version:3
-- Google Drive API Wrapper for Colab Notebooks
-- Handles CRUD operations for Colab notebook files stored in Google Drive

local core = require "core"
local common = require "core.common"
local process = require "process"
-- system is global
local auth = require "plugins.google_colab_auth"

-- URL encoding function
local function encode_uri(str)
  -- Basic URL encoding
  return str:gsub("[^A-Za-z0-9%-_.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

-- Use our bundled JSON parsing
local function parse_json(str)
  
  -- Use our bundled json library
  local ok, json = pcall(require, "plugins.google_colab_json")
  if ok and json and json.decode then
    return json.decode(str)
  end
  
  -- Last resort: simple manual parsing
  -- This is very basic and won't handle all JSON, but it won't crash the editor
  local lua_str = "return " .. str:gsub('true', 'true'):gsub('false', 'false'):gsub('null', 'nil')
  local ok, result = pcall(function() return load(lua_str)() end)
  if ok then return result end
  
  return nil
end

local function encode_json(tbl)
  -- Use our bundled json library
  local ok, json = pcall(require, "plugins.google_colab_json")
  if ok and json and json.encode then
    return json.encode(tbl)
  end
  return "{}"
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
    
    local out_tbl = {}
    local err_tbl = {}
    
    while p:returncode() == nil do
      local chunk = p:read_stdout(4096)
      if chunk and #chunk > 0 then table.insert(out_tbl, chunk) end
      local echunk = p:read_stderr(4096)
      if echunk and #echunk > 0 then table.insert(err_tbl, echunk) end
      coroutine.yield(0.01)
    end
    
    -- Drain remaining output
    while true do
      local chunk = p:read_stdout(4096)
      if chunk and #chunk > 0 then table.insert(out_tbl, chunk) else break end
    end
    while true do
      local echunk = p:read_stderr(4096)
      if echunk and #echunk > 0 then table.insert(err_tbl, echunk) else break end
    end
    
    local out = table.concat(out_tbl)
    local err = table.concat(err_tbl)
    
    local success = p:returncode() == 0
    if on_complete then on_complete(success, out, err) end
  end)
end

local list_notebooks
local get_notebook_metadata
local download_notebook
local create_notebook
local update_notebook
local delete_notebook
local permanently_delete_notebook
local search_notebooks

-- List all Colab notebooks in Google Drive
list_notebooks = function(on_complete)
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
get_notebook_metadata = function(file_id, on_complete)
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
download_notebook = function(file_id, on_complete)
  local url = DRIVE_API_BASE .. "/" .. file_id .. "?alt=media"
  
  curl_request("GET", url, nil, function(success, out, err)
    if not success then
      if on_complete then on_complete(false, err) end
      return
    end
    
    if on_complete then on_complete(true, out) end
  end)
end

-- Create new notebook
create_notebook = function(name, content, on_complete)
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
update_notebook = function(file_id, content, on_complete)
  local url = "https://www.googleapis.com/upload/drive/v3/files/" .. file_id .. "?uploadType=media"
  
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
delete_notebook = function(file_id, on_complete)
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
permanently_delete_notebook = function(file_id, on_complete)
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
search_notebooks = function(query, on_complete)
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
