local core = require "core"
local config = require "core.config"
local command = require "core.command"
local DocView = require "core.docview"
local RootView = require "core.rootview"
local lsp = require "plugins.lsp"
local process = require "process"

local remote_lsp = {}
local active_tunnels = {}
local uri_map = {} -- local absolute -> remote absolute
local inv_uri_map = {} -- remote absolute -> local absolute
local configuration_queue = {}

-- Helper to replace URI prefix
local function translate_local_to_remote(uri)
  if not uri or type(uri) ~= "string" then return uri end
  local file_path = uri:gsub("^file://", "")
  if uri_map[file_path] then
    return "file://" .. uri_map[file_path]
  end
  if core.active_codespace and core.project_dir and file_path:find(core.project_dir, 1, true) == 1 then
    local rel = file_path:sub(#core.project_dir + 2):gsub("\\\\", "/")
    local remote = core.active_codespace.remote_dir .. "/" .. rel
    return "file://" .. remote
  end
  return uri
end

local function translate_remote_to_local(uri)
  if not uri or type(uri) ~= "string" then return uri end
  local file_path = uri:gsub("^file://", "")
  if inv_uri_map[file_path] then
    return "file://" .. inv_uri_map[file_path]
  end
  if core.active_codespace and file_path:find(core.active_codespace.remote_dir, 1, true) == 1 then
    local rel = file_path:sub(#core.active_codespace.remote_dir + 2)
    local local_path = core.project_dir .. PATHSEP .. rel:gsub("/", PATHSEP)
    return "file://" .. local_path
  end
  return uri
end

-- Deep map translation
local function deep_translate(obj, direction)
  if type(obj) == "table" then
    local new_t = {}
    for k, v in pairs(obj) do
      if type(k) == "string" and k:match("^file://") then
        k = direction == "to_remote" and translate_local_to_remote(k) or translate_remote_to_local(k)
      end
      if k == "uri" or k == "targetUri" then
        new_t[k] = direction == "to_remote" and translate_local_to_remote(v) or translate_remote_to_local(v)
      else
        new_t[k] = deep_translate(v, direction)
      end
    end
    return new_t
  end
  return obj
end

-- Intercept lsp request and notify
if lsp and lsp.client then
  local old_request = lsp.client.request
  local old_notify = lsp.client.notify
  local old_respond = lsp.client.respond

  function lsp.client:request(method, params, callback)
    if not core.active_codespace then return old_request(self, method, params, callback) end
    if method == "initialize" then
      self.remote_initialized = false
    end
    params = deep_translate(params, "to_remote")
    old_request(self, method, params, function(err, result)
      if method == "initialize" then
        self.remote_initialized = true
        for _, q in ipairs(configuration_queue) do
          old_notify(self, q.method, q.params)
        end
        configuration_queue = {}
      end
      if result then result = deep_translate(result, "to_local") end
      if callback then callback(err, result) end
    end)
  end

  function lsp.client:notify(method, params)
    if not core.active_codespace then return old_notify(self, method, params) end
    if method == "$/setTrace" and not config.debug_lsp then return end
    if method == "workspace/didChangeConfiguration" and not self.remote_initialized then
      table.insert(configuration_queue, {method = method, params = deep_translate(params, "to_remote")})
      return
    end
    if method == "textDocument/didSave" then
      -- didSave must ship remote file content hash, handled via lsp plugin but we just ensure translated URIs
      local cap = self.server_capabilities
      if not (cap and cap.textDocumentSync and type(cap.textDocumentSync) == "table" and cap.textDocumentSync.save and cap.textDocumentSync.save.includeText) then
        params.text = nil
      end
    end
    params = deep_translate(params, "to_remote")
    old_notify(self, method, params)
  end
end

local backoff_delays = {0.25, 0.5, 1, 2, 5, 30}
local tunnel_retry_count = 0

function remote_lsp.start_tunnel(cs_name, server_cmd)
  if active_tunnels[cs_name] then return end
  local port = 9000 + math.random(0, 999)
  core.log_quiet("Spawning remote LSP tunnel on port %d...", port)
  
  local ssh_opts = {"-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/cs-%r@%h:%p", "-o", "ControlPersist=10m"}
  local cmd = {"gh", "cs", "ssh", "-c", cs_name, "--", unpack(ssh_opts)}
  table.insert(cmd, "-L")
  table.insert(cmd, "127.0.0.1:"..port..":127.0.0.1:"..port)
  
  -- The probe and execution string
  local remote_script = string.format("command -v %s >/dev/null && echo 'LSP_READY' && %s --stdio || echo 'LSP_MISSING'", server_cmd, server_cmd)
  table.insert(cmd, "sh")
  table.insert(cmd, "-c")
  table.insert(cmd, "'" .. remote_script .. "'")
  
  core.add_thread(function()
    local p = process.start(cmd, {stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE})
    if not p then return end
    
    local ready = false
    while p:returncode() == nil do
      local out = p:read_stdout(1024)
      if out and out:find("LSP_MISSING") then
        core.warn("Remote LSP server '%s' is missing! Please install it.", server_cmd)
        p:kill()
        return
      elseif out and out:find("LSP_READY") then
        ready = true
        tunnel_retry_count = 0
        active_tunnels[cs_name] = {pid = p:pid(), process = p, port = port}
        core.log_quiet("Remote LSP Ready.")
        break
      end
      coroutine.yield(0.1)
    end
    
    if not ready then
      local delay = backoff_delays[math.min(#backoff_delays, tunnel_retry_count + 1)]
      tunnel_retry_count = tunnel_retry_count + 1
      core.warn("LSP Tunnel failed. Retrying in %ss...", delay)
      coroutine.yield(delay)
      remote_lsp.start_tunnel(cs_name, server_cmd)
    end
  end)
end

-- Hook core.quit and RootView:on_unload for cleanup
local old_quit = core.quit
function core.quit(...)
  for cs_name, tunnel in pairs(active_tunnels) do
    if tunnel.process then
      tunnel.process:kill()
      local ssh_opts = {"-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/cs-%r@%h:%p", "-o", "ControlPersist=10m"}
      process.start({"gh", "cs", "ssh", "-c", cs_name, "--", unpack(ssh_opts), "-O", "exit", cs_name})
    end
  end
  return old_quit(...)
end

local old_root_unload = RootView.on_unload
function RootView:on_unload(...)
  for cs_name, tunnel in pairs(active_tunnels) do
    if tunnel.process then
      tunnel.process:kill()
      local ssh_opts = {"-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/cs-%r@%h:%p", "-o", "ControlPersist=10m"}
      process.start({"gh", "cs", "ssh", "-c", cs_name, "--", unpack(ssh_opts), "-O", "exit", cs_name})
    end
  end
  active_tunnels = {}
  if old_root_unload then old_root_unload(self, ...) end
end

-- Hook DocView open to register URIs
local old_doc_open = DocView.new
function DocView:new(doc)
  local dv = old_doc_open(self, doc)
  if core.active_codespace and doc.abs_filename then
    local rel = doc.abs_filename:sub(#core.project_dir + 2):gsub("\\\\", "/")
    local remote = core.active_codespace.remote_dir .. "/" .. rel
    uri_map[doc.abs_filename] = remote
    inv_uri_map[remote] = doc.abs_filename
  end
  return dv
end

return remote_lsp
