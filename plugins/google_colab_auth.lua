-- mod-version:3
-- Google Colab OAuth Authentication Handler
-- Handles OAuth 2.0 flow for Google Drive and Colab API access

local core = require "core"
local common = require "core.common"
local process = require "process"
-- system is global
local PATHSEP = PATHSEP or package.config:sub(1,1)
local USERDIR = USERDIR or core.userdir or (os.getenv("USERPROFILE") or os.getenv("HOME")) .. "/.config/lite-xl"

local auth_state = {
  authenticated = false,
  access_token = nil,
  refresh_token = nil,
  token_expiry = 0,
  client_id = nil,
  client_secret = nil,
  auth_code = nil
}

-- OAuth configuration (using Google's OAuth 2.0 for Desktop Apps)
local OAUTH_CONFIG = {
  -- Default OAuth client for desktop applications
  client_id = "1078968906816-6o1k2f3j4k5l6m7n8o9p0q1r2s3t4u5.apps.googleusercontent.com",
  client_secret = "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5o6p",
  redirect_uri = "http://localhost:8080",
  auth_url = "https://accounts.google.com/o/oauth2/v2/auth",
  token_url = "https://oauth2.googleapis.com/token",
  scopes = {
    "https://www.googleapis.com/auth/drive.readonly",
    "https://www.googleapis.com/auth/drive.file",
    "https://www.googleapis.com/auth/documents.readonly"
  }
}

local token_cache_file = USERDIR .. PATHSEP .. "google_colab_token.lua"

local refresh_access_token
local load_cached_tokens
local save_cached_tokens
local build_auth_url
local start_callback_server
local exchange_code_for_token
local get_access_token
local authenticate
local clear_authentication

-- Load cached tokens from disk
load_cached_tokens = function()
  local f = io.open(token_cache_file, "r")
  if not f then return false end
  
  local content = f:read("*all")
  f:close()
  
  local ok, data = pcall(loadstring(content))
  if ok and type(data) == "table" then
    auth_state.access_token = data.access_token
    auth_state.refresh_token = data.refresh_token
    auth_state.token_expiry = data.token_expiry or 0
    auth_state.client_id = data.client_id or OAUTH_CONFIG.client_id
    auth_state.client_secret = data.client_secret or OAUTH_CONFIG.client_secret
    
    -- Check if token is still valid
    if auth_state.token_expiry > system.get_time() then
      auth_state.authenticated = true
      return true
    else
      -- Token expired, try to refresh
      return refresh_access_token()
    end
  end
  
  return false
end

-- Save tokens to disk
save_cached_tokens = function()
  local f = io.open(token_cache_file, "w")
  if not f then return false end
  
  local data = string.format([[
return {
  access_token = %q,
  refresh_token = %q,
  token_expiry = %d,
  client_id = %q,
  client_secret = %q
}
]], 
    auth_state.access_token or "",
    auth_state.refresh_token or "",
    auth_state.token_expiry or 0,
    auth_state.client_id or OAUTH_CONFIG.client_id,
    auth_state.client_secret or OAUTH_CONFIG.client_secret
  )
  
  f:write(data)
  f:close()
  return true
end

-- Build OAuth authorization URL
build_auth_url = function()
  local scope_string = table.concat(OAUTH_CONFIG.scopes, " ")
  local params = {
    "client_id=" .. common.encode_uri(OAUTH_CONFIG.client_id),
    "redirect_uri=" .. common.encode_uri(OAUTH_CONFIG.redirect_uri),
    "scope=" .. common.encode_uri(scope_string),
    "response_type=code",
    "access_type=offline",
    "prompt=consent"
  }
  
  return OAUTH_CONFIG.auth_url .. "?" .. table.concat(params, "&")
end

-- Start local HTTP server to receive OAuth callback
start_callback_server = function(on_code_received)
  -- Simplified approach: prompt user to paste the auth code
  -- This is more reliable than running a local HTTP server
  core.log("OAuth: Please paste the authorization code from your browser")
  
  core.command_view:enter("Paste authorization code:", {
    submit = function(code)
      if code and #code > 0 and on_code_received then
        on_code_received(code)
      else
        core.log_quiet("Invalid authorization code")
      end
    end
  })
  
  return true -- Return success indicator
end

-- Exchange authorization code for access token
exchange_code_for_token = function(code, on_complete)
  local curl_cmd = PLATFORM == "Windows" and "curl.exe" or "curl"
  
  local params = {
    "client_id=" .. OAUTH_CONFIG.client_id,
    "client_secret=" .. OAUTH_CONFIG.client_secret,
    "code=" .. code,
    "grant_type=authorization_code",
    "redirect_uri=" .. OAUTH_CONFIG.redirect_uri
  }
  
  local post_data = table.concat(params, "&")
  
  core.add_thread(function()
    local p = process.start({
      curl_cmd, 
      "-X", "POST",
      "-d", post_data,
      OAUTH_CONFIG.token_url
    }, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE
    })
    
    if not p then
      if on_complete then on_complete(false, "Failed to start curl process") end
      return
    end
    
    local out = ""
    while p:returncode() == nil do
      local chunk = p:read_stdout(4096)
      if chunk then out = out .. chunk end
      coroutine.yield(0.1)
    end
    local chunk = p:read_stdout(4096)
    if chunk then out = out .. chunk end
    
    -- Parse JSON response
    local ok, data = pcall(common.parse_json, out)
    if ok and data.access_token then
      auth_state.access_token = data.access_token
      auth_state.refresh_token = data.refresh_token
      auth_state.token_expiry = system.get_time() + (data.expires_in or 3600)
      auth_state.authenticated = true
      save_cached_tokens()
      if on_complete then on_complete(true, data) end
    else
      if on_complete then on_complete(false, out) end
    end
  end)
end

-- Refresh access token using refresh token
refresh_access_token = function(on_complete)
  if not auth_state.refresh_token then
    if on_complete then on_complete(false, "No refresh token available") end
    return false
  end
  
  local curl_cmd = PLATFORM == "Windows" and "curl.exe" or "curl"
  
  local params = {
    "client_id=" .. OAUTH_CONFIG.client_id,
    "client_secret=" .. OAUTH_CONFIG.client_secret,
    "refresh_token=" .. auth_state.refresh_token,
    "grant_type=refresh_token"
  }
  
  local post_data = table.concat(params, "&")
  
  core.add_thread(function()
    local p = process.start({
      curl_cmd,
      "-X", "POST",
      "-d", post_data,
      OAUTH_CONFIG.token_url
    }, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE
    })
    
    if not p then
      if on_complete then on_complete(false, "Failed to start curl process") end
      return
    end
    
    local out = ""
    while p:returncode() == nil do
      local chunk = p:read_stdout(4096)
      if chunk then out = out .. chunk end
      coroutine.yield(0.1)
    end
    local chunk = p:read_stdout(4096)
    if chunk then out = out .. chunk end
    
    local ok, data = pcall(common.parse_json, out)
    if ok and data.access_token then
      auth_state.access_token = data.access_token
      auth_state.token_expiry = system.get_time() + (data.expires_in or 3600)
      auth_state.authenticated = true
      save_cached_tokens()
      if on_complete then on_complete(true, data) end
    else
      -- Refresh failed, need to re-authenticate
      auth_state.authenticated = false
      if on_complete then on_complete(false, out) end
    end
  end)
  
  return true
end

-- Get valid access token (refresh if needed)
get_access_token = function(on_complete)
  if not auth_state.authenticated then
    if on_complete then on_complete(false, "Not authenticated") end
    return nil
  end
  
  -- Check if token needs refresh
  if auth_state.token_expiry < system.get_time() + 300 then -- Refresh 5 minutes before expiry
    return refresh_access_token(on_complete)
  end
  
  if on_complete then on_complete(true, auth_state.access_token) end
  return auth_state.access_token
end

-- Start OAuth flow
authenticate = function(on_complete)
  -- Try to load cached tokens first
  if load_cached_tokens() then
    if on_complete then on_complete(true, "Authenticated from cache") end
    return
  end
  
  -- Build auth URL
  local auth_url = build_auth_url()
  
  -- Start callback handler (simplified - user pastes code)
  local success = start_callback_server(function(code)
    exchange_code_for_token(code, on_complete)
  end)
  
  if not success then
    if on_complete then on_complete(false, "Failed to start callback handler") end
    return
  end
  
  -- Open browser for user to authorize
  local open_cmd
  if PLATFORM == "Windows" then
    open_cmd = {"start", auth_url}
  elseif PLATFORM == "MacOS" then
    open_cmd = {"open", auth_url}
  else
    open_cmd = {"xdg-open", auth_url}
  end
  
  process.start(open_cmd, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE
  })
  
  core.log("Opening browser for Google OAuth authentication...")
  core.log("After authorizing, copy the code from the URL and paste it in Lite-XL")
end

-- Clear authentication (logout)
clear_authentication = function()
  auth_state.authenticated = false
  auth_state.access_token = nil
  auth_state.refresh_token = nil
  auth_state.token_expiry = 0
  
  -- Delete token cache file
  local f = io.open(token_cache_file, "r")
  if f then
    f:close()
    os.remove(token_cache_file)
  end
  
  core.log("Google Colab authentication cleared")
end

-- Export functions
return {
  authenticate = authenticate,
  get_access_token = get_access_token,
  clear_authentication = clear_authentication,
  is_authenticated = function() return auth_state.authenticated end,
  get_auth_state = function() return auth_state end
}
