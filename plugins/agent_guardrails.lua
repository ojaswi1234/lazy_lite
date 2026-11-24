-- mod-version:3
-- plugins/agent_guardrails.lua — Zero-Trust Anti-Hallucination & Safety Engine for Lite XL
-- Enforces deterministic host-side guardrails before any agent tool call can touch disk, buffers, or state.

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local system = require "system"
local config = require "core.config"

-- Initialize configuration namespace
config.guardrails = config.guardrails or {}
config.guardrails.mode = config.guardrails.mode or "supervised" -- "off", "read_only", "supervised", "autopilot"
config.guardrails.plugin_dev_mode = config.guardrails.plugin_dev_mode or false
config.guardrails.enabled = (config.guardrails.enabled == nil) and true or config.guardrails.enabled
config.guardrails.max_snapshots = config.guardrails.max_snapshots or 10
config.guardrails.strike_window_sec = config.guardrails.strike_window_sec or 60
config.guardrails.max_strikes = config.guardrails.max_strikes or 3

local Guardrails = {
  snapshots = {},       -- In-memory LIFO stack of recent buffer snapshots for instant rollback
  strike_window = {},   -- Timestamps of recent unhandled exceptions following agent actions
  circuit_tripped = false,
  audit_file = USERDIR .. PATHSEP .. "tempfiles" .. PATHSEP .. "agent_audit.jsonl",
}

-- Ensure tempfiles directory exists for audit log
pcall(function()
  local tmp = USERDIR .. PATHSEP .. "tempfiles"
  if not system.get_file_info(tmp) then
    system.mkdir(tmp)
  end
end)

-- ── Audit Logger ──────────────────────────────────────────────────────────────
function Guardrails.log_audit(subsystem, action, target, status, details)
  pcall(function()
    local fp = io.open(Guardrails.audit_file, "a")
    if fp then
      local ok_json, json = pcall(require, "plugins.lsp.json")
      if ok_json and json and json.encode then
        local entry_tbl = {
          ts = os.time(),
          time = system.get_time(),
          subsystem = tostring(subsystem or "unknown"),
          action = tostring(action or "unknown"),
          target = tostring(target or ""),
          status = tostring(status or "ok"),
          details = tostring(details or "")
        }
        fp:write(json.encode(entry_tbl) .. "\n")
      else
        local clean_details = tostring(details or ""):gsub('"', '\\"'):gsub("\r?\n", " ")
        local entry = string.format(
          '{"ts":%d,"time":%.2f,"subsystem":"%s","action":"%s","target":"%s","status":"%s","details":"%s"}\n',
          os.time(),
          system.get_time(),
          tostring(subsystem or "unknown"):gsub('"', '\\"'),
          tostring(action or "unknown"):gsub('"', '\\"'),
          tostring(target or ""):gsub('"', '\\"'),
          tostring(status or "ok"):gsub('"', '\\"'),
          clean_details
        )
        fp:write(entry)
      end
      fp:close()
    end
  end)
end

-- ── Algorithm 1: Canonical Path Boundary Verification ─────────────────────────
function Guardrails.verify_path(path, intent)
  if not config.guardrails.enabled then return true, "GUARDRAILS_DISABLED" end
  if config.guardrails.mode == "off" then
    return false, "GUARDRAIL_MODE_OFF: Agent automation is disabled in AI settings."
  end
  if config.guardrails.mode == "read_only" and intent ~= "read" then
    return false, "GUARDRAIL_MODE_READ_ONLY: Agent write operations are blocked in Read-Only mode."
  end
  if not path or path == "" then
    Guardrails.log_audit("guardrails", "verify_path", path, "rejected", "EMPTY_PATH")
    return false, "EMPTY_PATH: Path cannot be nil or empty."
  end

  local abs_path = system.absolute_path(path) or path
  local norm_path = common.normalize_path(abs_path)
  local norm_datadir = common.normalize_path(DATADIR)
  local norm_userdir = common.normalize_path(USERDIR)
  local norm_project = common.normalize_path(core.project_dir or "")

  -- 1. HARD FORBIDDEN: C:\Program Files\Lite XL\data (Core engine & base plugins)
  -- Case-insensitive check on Windows
  local p_low = norm_path:lower()
  local d_low = norm_datadir:lower()
  if p_low:sub(1, #d_low) == d_low then
    local err = "GUARDRAIL_CORE_IMMUTABLE: Target path resides in core Lite XL system directory. Modification is strictly blocked."
    Guardrails.log_audit("guardrails", "verify_path", norm_path, "rejected", err)
    return false, err
  end

  -- 2. Windows system roots (C:\Windows, C:\Program Files outside Lite XL)
  if PLATFORM == "Windows" then
    if norm_path:match("^[A-Za-z]:[/\\][Ww][Ii][Nn][Dd][Oo][Ww][Ss]") or
       (norm_path:match("^[A-Za-z]:[/\\][Pp][Rr][Oo][Gg][Rr][Aa][Mm]%s+[Ff][Ii][Ll][Ee][Ss]") and p_low:sub(1, #d_low) ~= d_low)
    then
      local err = "GUARDRAIL_SYSTEM_ROOT: Target path outside allowed IDE workspace scope."
      Guardrails.log_audit("guardrails", "verify_path", norm_path, "rejected", err)
      return false, err
    end
  end

  -- 3. USERDIR/plugins/ protection (requires Dev Mode toggle)
  local u_plugins = (norm_userdir .. "/plugins"):lower()
  if p_low:sub(1, #u_plugins) == u_plugins then
    if not config.guardrails.plugin_dev_mode then
      local err = "GUARDRAIL_PLUGIN_LOCKED: Modifying editor plugins is locked. Enable 'Plugin Maintenance Mode' in AI settings to permit plugin edits."
      Guardrails.log_audit("guardrails", "verify_path", norm_path, "rejected", err)
      return false, err
    end
    Guardrails.log_audit("guardrails", "verify_path", norm_path, "allowed_sensitive", "PLUGIN_DEV_MODE_ENABLED")
    return true, "PLUGIN_SENSITIVE"
  end

  -- 4. Active Workspace files (core.project_dir)
  if norm_project ~= "" and p_low:sub(1, #norm_project) == norm_project:lower() then
    Guardrails.log_audit("guardrails", "verify_path", norm_path, "allowed", "WORKSPACE_FILE")
    return true, "WORKSPACE_ALLOWED"
  end

  -- 5. Scratch / Temp area allowance (USERDIR/tempfiles)
  local u_temp = (norm_userdir .. "/tempfiles"):lower()
  if p_low:sub(1, #u_temp) == u_temp then
    return true, "TEMPFILES_ALLOWED"
  end

  -- Out of workspace warning
  local err = "GUARDRAIL_OUTSIDE_WORKSPACE: Target path is outside the active workspace directory (" .. (core.project_dir or "none") .. ")."
  Guardrails.log_audit("guardrails", "verify_path", norm_path, "rejected", err)
  return false, err
end

-- ── Algorithm 2: Pre-Flight AST & Syntax Compilation Gate ────────────────────
function Guardrails.preflight_compile(filepath, content)
  if not config.guardrails.enabled then return true, "GUARDRAILS_DISABLED" end
  if not content then return false, "EMPTY_CONTENT" end

  local ext = filepath:match("%.([a-zA-Z0-9]+)$")
  if not ext then return true end
  ext = ext:lower()

  -- Lua Pre-Flight: Sandboxed load() check
  if ext == "lua" then
    -- Load into empty sandboxed environment to prevent execution of top-level code during compilation
    local fn, err = load(content, "@preflight_" .. common.basename(filepath), "t", {})
    if not fn then
      local err_msg = "LUA_SYNTAX_VIOLATION: " .. tostring(err)
      Guardrails.log_audit("guardrails", "preflight", filepath, "rejected", err_msg)
      return false, err_msg
    end
  -- JSON Pre-Flight: Strict parse check
  elseif ext == "json" then
    local ok, json = pcall(require, "plugins.lsp.json")
    if ok and json and json.decode then
      local success, jerr = pcall(json.decode, content)
      if not success then
        local err_msg = "JSON_SYNTAX_VIOLATION: " .. tostring(jerr)
        Guardrails.log_audit("guardrails", "preflight", filepath, "rejected", err_msg)
        return false, err_msg
      end
    end
  end

  Guardrails.log_audit("guardrails", "preflight", filepath, "passed", "Syntax validated")
  return true, "SYNTAX_VALID"
end

-- ── Algorithm 3: Anti-Hallucination Atomic Buffer Patcher ─────────────────────
function Guardrails.atomic_patch(doc, target_signature, replacement_code)
  if not config.guardrails.enabled then
    -- Fallback simple replace
    local text = table.concat(doc.lines)
    local s, e = text:find(target_signature, 1, true)
    if not s then return false, "TARGET_NOT_FOUND" end
    doc:remove(1, 1, math.huge, math.huge)
    doc:insert(1, 1, text:sub(1, s - 1) .. replacement_code .. text:sub(e + 1))
    return true, "COMMITTED"
  end

  assert(doc, "doc must be provided")
  if not target_signature or target_signature == "" then
    return false, "EMPTY_TARGET: Target signature cannot be empty."
  end
  replacement_code = replacement_code or ""

  local text = table.concat(doc.lines)

  -- 1. Uniqueness check: locate target signature
  local s, e = text:find(target_signature, 1, true)
  if not s then
    -- Try line-trimmed whitespace fallback
    local trimmed_target = target_signature:gsub("^%s+", ""):gsub("%s+$", "")
    s, e = text:find(trimmed_target, 1, true)
    if not s then
      local err = "TARGET_NOT_FOUND: The code block you targeted was not found in the buffer. Check line contents and try again."
      Guardrails.log_audit("guardrails", "atomic_patch", doc.filename or "buffer", "rejected", err)
      return false, err
    end
  end

  -- Check ambiguity: ensure target signature is unique
  local s2 = text:find(target_signature, s + 1, true)
  if s2 then
    local err = "AMBIGUOUS_TARGET: Target code block matches multiple locations in the buffer. Provide more surrounding context lines to disambiguate."
    Guardrails.log_audit("guardrails", "atomic_patch", doc.filename or "buffer", "rejected", err)
    return false, err
  end

  -- 2. Stage modification in memory string
  local staged_text = text:sub(1, s - 1) .. replacement_code .. text:sub(e + 1)

  -- 3. Run Pre-Flight Syntax Compilation Gate on staged content
  local fname = doc.filename or "buffer.lua"
  local valid, compile_err = Guardrails.preflight_compile(fname, staged_text)
  if not valid then
    local err = "REJECTED_BEFORE_WRITE: " .. compile_err .. " (No changes applied to disk or buffer)."
    Guardrails.log_audit("guardrails", "atomic_patch", fname, "rejected", err)
    return false, err
  end

  -- 4. Push snapshot to rollback stack
  local copy_lines = {}
  for idx, line_str in ipairs(doc.lines) do
    copy_lines[idx] = line_str
  end

  table.insert(Guardrails.snapshots, {
    doc = doc,
    filename = doc.filename,
    lines = copy_lines,
    timestamp = system.get_time(),
    target = target_signature:sub(1, 60)
  })
  if #Guardrails.snapshots > config.guardrails.max_snapshots then
    table.remove(Guardrails.snapshots, 1)
  end

  -- 5. Commit atomically via Doc lines
  doc:remove(1, 1, math.huge, math.huge)
  doc:insert(1, 1, staged_text)
  doc:clean()

  Guardrails.log_audit("guardrails", "atomic_patch", fname, "committed", "Patch committed cleanly with undo preservation")
  return true, "PATCH_COMMITTED_CLEAN"
end

-- ── Algorithm 4: Command Whitelist & Sensitivity Verifier ─────────────────────
function Guardrails.verify_command(command_name)
  if not command_name or command_name == "" then
    return false, "EMPTY_COMMAND"
  end

  -- Hallucination check: command must exist in command.map
  if not command.map[command_name] then
    local err = string.format("HALLUCINATED_COMMAND: '%s' is not a registered command in Lite XL.", command_name)
    Guardrails.log_audit("guardrails", "verify_command", command_name, "rejected", err)
    return false, err
  end

  -- Sensitive command interceptor
  local sensitive = {
    ["core:quit"] = true,
    ["core:force-quit"] = true,
    ["core:restart"] = true,
    ["file:delete"] = true,
    ["treeview:delete"] = true,
  }
  if sensitive[command_name] then
    Guardrails.log_audit("guardrails", "verify_command", command_name, "requires_confirm", "Sensitive command")
    return false, "SENSITIVE_COMMAND_REQUIRES_CONFIRMATION: Command '" .. command_name .. "' requires explicit user confirmation."
  end

  Guardrails.log_audit("guardrails", "verify_command", command_name, "allowed", "Valid command")
  return true, "ALLOWED"
end

-- ── Algorithm 5: Runtime Watchdog & Circuit Breaker ───────────────────────────
function Guardrails.record_failure(err_msg)
  if Guardrails.circuit_tripped then return "CIRCUIT_BREAKER_ALREADY_TRIPPED" end

  local now = system.get_time()
  table.insert(Guardrails.strike_window, now)

  -- Prune outside time window
  local valid = {}
  for _, ts in ipairs(Guardrails.strike_window) do
    if now - ts <= config.guardrails.strike_window_sec then
      table.insert(valid, ts)
    end
  end
  Guardrails.strike_window = valid

  Guardrails.log_audit("guardrails", "watchdog_strike", "core", "strike", "Strike count: " .. #Guardrails.strike_window .. " / " .. config.guardrails.max_strikes)

  if #Guardrails.strike_window >= config.guardrails.max_strikes then
    Guardrails.circuit_tripped = true
    core.error("[CIRCUIT BREAKER ACTIVATED]: %d consecutive failures detected within %ds. AI automation frozen to protect editor stability.", #Guardrails.strike_window, config.guardrails.strike_window_sec)
    Guardrails.log_audit("guardrails", "circuit_breaker", "core", "TRIPPED", "Circuit breaker triggered; automation frozen")

    -- Auto-rollback to last known clean snapshot
    if #Guardrails.snapshots > 0 then
      local snap = table.remove(Guardrails.snapshots)
      if snap.doc then
        snap.doc:remove(1, 1, math.huge, math.huge)
        snap.doc:insert(1, 1, table.concat(snap.lines))
        snap.doc:clean()
        core.log("[Guardrails]: Auto-reverted '%s' to last pre-agent snapshot.", snap.filename or "buffer")
      end
    end
    return "CIRCUIT_BREAKER_TRIPPED"
  end

  return "STRIKE_RECORDED"
end

function Guardrails.reset_circuit_breaker()
  Guardrails.circuit_tripped = false
  Guardrails.strike_window = {}
  core.log("[Guardrails]: Circuit breaker reset by user. AI automation re-enabled.")
  Guardrails.log_audit("guardrails", "circuit_breaker", "core", "reset", "Reset by user")
end

-- ── Rollback Command ──────────────────────────────────────────────────────────
command.add(nil, {
  ["guardrails:rollback-last-action"] = function()
    if #Guardrails.snapshots == 0 then
      core.log("[Guardrails]: No agent snapshots available in rollback stack.")
      return
    end
    local snap = table.remove(Guardrails.snapshots)
    if snap.doc then
      snap.doc:remove(1, 1, math.huge, math.huge)
      snap.doc:insert(1, 1, table.concat(snap.lines))
      snap.doc:clean()
      core.log("[Guardrails]: Reverted '%s' to pre-agent snapshot (Target: %s).", snap.filename or "buffer", snap.target or "unknown")
      Guardrails.log_audit("guardrails", "rollback", snap.filename or "buffer", "reverted", "User triggered rollback")
    end
  end,

  ["guardrails:reset-circuit-breaker"] = function()
    Guardrails.reset_circuit_breaker()
  end,

  ["guardrails:toggle-plugin-dev-mode"] = function()
    config.guardrails.plugin_dev_mode = not config.guardrails.plugin_dev_mode
    core.log("[Guardrails]: Plugin Maintenance Mode is now %s.", config.guardrails.plugin_dev_mode and "ENABLED (Sensitive)" or "LOCKED")
  end,

  ["guardrails:view-audit-log"] = function()
    local path = Guardrails.audit_file
    if system.get_file_info(path) then
      local doc = core.open_doc(path)
      core.root_view:open_doc(doc)
      core.log("[Guardrails]: Opened agent audit log.")
    else
      core.log("[Guardrails]: No audit log entries recorded yet.")
    end
  end,

  ["guardrails:cycle-mode"] = function()
    local modes = { "supervised", "autopilot", "read_only", "off" }
    local cur_idx = 1
    for i, m in ipairs(modes) do
      if m == config.guardrails.mode then cur_idx = i break end
    end
    local next_idx = (cur_idx % #modes) + 1
    config.guardrails.mode = modes[next_idx]
    core.log("[Guardrails]: Agent Control Mode is now '%s'.", config.guardrails.mode:upper())
  end
})

-- Intercept unhandled Lua errors in core.on_error
local old_on_error = core.on_error
function core.on_error(err)
  Guardrails.record_failure(tostring(err))
  if old_on_error then return old_on_error(err) end
end

-- Export module globally on core
core.guardrails = Guardrails

return Guardrails
