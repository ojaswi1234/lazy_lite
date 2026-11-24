-- mod-version:3
-- plugins/agent_meta_tools.lua — 3 High-Density Meta-Tools & Ambient Pulse Generator
-- Replaces 60+ individual tool schemas (~4,500 tokens) with 3 compact Meta-Tools (~120 tokens).

local core = require "core"
local common = require "core.common"
local system = require "system"
local command = require "core.command"

local MetaTools = {}

-- ── 1. Ambient Pulse Generator (`litexl_pulse`) ───────────────────────────────
-- Injects an ultra-compact ~20-35 token status signature into the conversation turn.
function MetaTools.pulse()
  local av = core.active_view
  local doc = av and av.doc

  -- 1. Buffer & Cursor coordinates
  local file_info = "none"
  local pos_info = "0:0"
  local flags = {}

  if doc then
    file_info = common.basename(doc.filename or "untitled")
    local l1, c1, l2, c2 = doc:get_selection()
    pos_info = string.format("%d:%d", l1, c1)
    if l1 ~= l2 or c1 ~= c2 then table.insert(flags, "sel") end
    if doc:is_dirty() then table.insert(flags, "dirty") end
  end

  local flag_str = #flags > 0 and (" (" .. table.concat(flags, ",") .. ")") or ""

  -- 2. Open Tabs summary in active node
  local tabs = {}
  local active_node = core.root_view:get_active_node_default()
  if active_node and active_node.views then
    for i, v in ipairs(active_node.views) do
      if #tabs < 4 then
        local tname = v.doc and common.basename(v.doc.filename or "untitled") or (v.get_name and v:get_name() or "view")
        if v.doc and v.doc:is_dirty() then tname = tname .. "*" end
        table.insert(tabs, tname)
      end
    end
  end
  local tab_str = table.concat(tabs, ", ")
  local tab_count = active_node and active_node.views and #active_node.views or 0

  -- 3. Subsystem Micro-Badge
  local badge = ""
  if av then
    local vname = tostring(av)
    if vname:find("LeetCode") or (av.doc and av.doc.filename and av.doc.filename:find("leetcode")) then
      badge = " | [Subsystem: LeetCode]"
    elseif vname:find("Pptx") or (av.doc and av.doc.filename and av.doc.filename:match("%.pptx$")) then
      local slide_num = av.current_slide or 1
      local total = av.total_slides or 1
      badge = string.format(" | [PPTX: Slide %d/%d]", slide_num, total)
    elseif vname:find("Pdf") or (av.doc and av.doc.filename and av.doc.filename:match("%.pdf$")) then
      badge = string.format(" | [PDF: Page %d]", av.page or 1)
    end
  end

  -- 4. Error badge
  local err_badge = ""
  if core.diagnostic_triage and core.diagnostic_triage.last_triage then
    local t = core.diagnostic_triage.last_triage
    if t.filename then
      err_badge = string.format(" | [Err: %s:%d]", t.filename, t.line)
    end
  end

  return string.format(
    "[IDE: active=%s:%s%s | tabs=%s (%d) | splits=%d%s%s]",
    file_info,
    pos_info,
    flag_str,
    tab_str,
    tab_count,
    2,
    badge,
    err_badge
  )
end

-- ── 2. Universal Actuator (`litexl_do`) ────────────────────────────────────────
function MetaTools.execute(subsystem, action, params)
  if not subsystem or not action then
    return false, "INVALID_ARGS: Both 'subsystem' and 'action' are required."
  end
  params = params or {}

  -- 1. Security & Guardrail pre-checks
  if core.guardrails then
    if core.guardrails.circuit_tripped then
      return false, "CIRCUIT_BREAKER_ACTIVE: Automated execution is frozen. User must reset circuit breaker."
    end

    -- If target file is provided, check path boundary
    local target_path = params.path or params.file or params.filename or params.filepath or params.target or params.name
    if target_path and target_path ~= "" then
      local ok, perm = core.guardrails.verify_path(target_path, action)
      if not ok then return false, perm end
    end
  end

  -- 2. Dispatch to capability registry
  if not core.capabilities then
    pcall(require, "plugins.agent_capabilities")
  end
  if not core.capabilities then
    return false, "CAPABILITIES_UNAVAILABLE: Host capability registry is not loaded."
  end

  local ok, res = core.capabilities.invoke(subsystem, action, params)
  if ok then
    core.redraw = true
    return true, res
  else
    return false, res
  end
end

-- ── 3. JIT Capability Inspector (`litexl_discover`) ───────────────────────────
function MetaTools.discover(subsystem)
  if not core.capabilities then
    pcall(require, "plugins.agent_capabilities")
  end
  if not core.capabilities then return "Capabilities not available." end
  if not subsystem or subsystem == "" or subsystem == "all" then
    local subs = core.capabilities.list()
    local lines = { "Available Lite XL Subsystems:" }
    for _, s in ipairs(subs) do
      table.insert(lines, string.format("  • '%s': %s", s.name, s.summary))
    end
    return table.concat(lines, "\n")
  else
    local schema = core.capabilities.get_schema(subsystem)
    if not schema then return "Subsystem '" .. tostring(subsystem) .. "' not found." end
    local lines = { string.format("Subsystem '%s' (%s):", schema.subsystem, schema.summary) }
    for act, desc in pairs(schema.actions) do
      table.insert(lines, string.format("  - %s: %s", act, desc))
    end
    return table.concat(lines, "\n")
  end
end

-- ── 4. Frame-Synchronized Mailbox Listener (Cross-Process IPC) ─────────────────
-- Drains requests from Python agents (ai_api_bridge.py, CrewAI) or external CLIs
-- at the start of core.step(), guaranteeing 100% thread safety and zero UI frame drops.
local MAILBOX_DIR = USERDIR .. PATHSEP .. "tempfiles"
local MAILBOX_REQ = MAILBOX_DIR .. PATHSEP .. "agent_mailbox.jsonl"

core.add_thread(function()
  local ok, json = pcall(require, "plugins.lsp.json")
  if not ok or not json then return end

  while true do
    local f_info = system.get_file_info(MAILBOX_REQ)
    if f_info and f_info.size > 0 then
      local fp = io.open(MAILBOX_REQ, "r")
      if fp then
        local lines = {}
        for line in fp:lines() do
          if #line > 3 then table.insert(lines, line) end
        end
        fp:close()

        -- Truncate mailbox file immediately so new requests don't duplicate
        local clear_fp = io.open(MAILBOX_REQ, "w")
        if clear_fp then clear_fp:close() end

        -- Process requests synchronously on main thread
        for _, raw_req in ipairs(lines) do
          local parse_ok, req = pcall(json.decode, raw_req)
          if parse_ok and req and req.id then
            local resp = { id = req.id, ok = false, result = "" }

            if req.method == "pulse" then
              resp.ok = true
              resp.result = MetaTools.pulse()
            elseif req.method == "discover" then
              resp.ok = true
              resp.result = MetaTools.discover(req.subsystem)
            elseif req.method == "do" then
              local exec_ok, res = MetaTools.execute(req.subsystem, req.action, req.params or {})
              resp.ok = exec_ok
              resp.result = tostring(res)
            else
              resp.result = "UNKNOWN_MAILBOX_METHOD: " .. tostring(req.method)
            end

            -- Write response file
            local resp_file = MAILBOX_DIR .. PATHSEP .. string.format("agent_resp_%s.json", tostring(req.id))
            local r_fp = io.open(resp_file, "w")
            if r_fp then
              r_fp:write(json.encode(resp))
              r_fp:close()
            end
          end
        end
      end
    end
    coroutine.yield(0.05) -- Check every 50ms without consuming CPU
  end
end)

-- Export on core
core.agent_meta_tools = MetaTools

return MetaTools
