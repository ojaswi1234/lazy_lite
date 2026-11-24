-- mod-version:3
-- plugins/agent_helpers.lua — Host-Side Algorithmic Helpers for Lite XL
-- Provides high-level deterministic algorithms for workspace choreography,
-- AST scope minification, diagnostic triage, and semantic intent matching.

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local DocView = require "core.docview"
local Node = require "core.node"

local Helpers = {}

-- ── 1. The Autonomous Workspace Choreographer ─────────────────────────────────
-- Solves the binary split tree (Node) deterministically, eliminating the need
-- for an external LLM to calculate split math, node IDs, or divider coordinates.
local Choreographer = {}

function Choreographer.find_node_for_doc(doc)
  local function scan(n)
    if n.type == "leaf" then
      for _, v in ipairs(n.views) do
        if v.doc == doc then return n, v end
      end
    else
      local na, va = scan(n.a)
      if na then return na, va end
      return scan(n.b)
    end
  end
  return scan(core.root_view.root_node)
end

function Choreographer.arrange(opts)
  opts = opts or {}
  local mode = opts.mode or opts.layout or "side_by_side"
  local primary_path = opts.primary
  local secondary_path = opts.secondary
  local ratio = opts.ratio or 0.5

  -- 1. Resolve primary view / doc
  local primary_doc = nil
  if primary_path then
    primary_doc = core.open_doc(primary_path)
  elseif core.active_view and core.active_view.doc then
    primary_doc = core.active_view.doc
  end

  local active_node = core.root_view:get_active_node_default()
  if not active_node then
    return false, "No active document node available."
  end

  if mode == "side_by_side" then
    -- If secondary path is provided, split right and open secondary in new node
    local dir = opts.direction or "right"
    local new_node = active_node:split(dir)
    if new_node then
      local doc_to_open = secondary_path and core.open_doc(secondary_path) or primary_doc
      if doc_to_open then
        local sec_view = DocView(doc_to_open)
        new_node:add_view(sec_view)
        new_node:set_active_view(sec_view)
      end
    end
    -- Balance parent divider
    local parent = active_node:get_parent_node(core.root_view.root_node)
    if parent then parent.divider = ratio end
    core.root_view.root_node:update_layout()
    return true, "Arranged side-by-side"

  elseif mode == "stacked" then
    local new_node = active_node:split("down")
    if new_node then
      local doc_to_open = secondary_path and core.open_doc(secondary_path) or primary_doc
      if doc_to_open then
        local sec_view = DocView(doc_to_open)
        new_node:add_view(sec_view)
        new_node:set_active_view(sec_view)
      end
    end
    local parent = active_node:get_parent_node(core.root_view.root_node)
    if parent then parent.divider = ratio end
    core.root_view.root_node:update_layout()
    return true, "Arranged stacked vertically"

  elseif mode == "diff_view" then
    -- Try to trigger native git diff view if available
    if command.map["git-diff:open"] then
      command.perform("git-diff:open")
      return true, "Opened git diff view"
    else
      -- Fallback: split side-by-side with secondary
      return Choreographer.arrange({ mode = "side_by_side", primary = primary_path, secondary = secondary_path })
    end

  elseif mode == "focus" then
    -- Close all docviews other than active one
    command.perform("root:close-all-others")
    return true, "Focused on primary document"

  elseif mode == "clean" then
    command.perform("root:close-all")
    return true, "Workspace cleared"
  end

  return false, "Unknown arrangement mode: " .. tostring(mode)
end

Helpers.choreographer = Choreographer
core.choreographer = Choreographer

-- ── 2. Scope & AST Context Minifier ───────────────────────────────────────────
-- Crawls the active document around the user's cursor to identify the enclosing
-- function/class and top-level imports. Turns 2,000 lines into a 35-token summary.
local ScopeExtractor = {}

function ScopeExtractor.extract(doc, line, col)
  doc = doc or (core.active_view and core.active_view.doc)
  if not doc or not doc.lines then
    return "[Scope: No active document]"
  end

  line = line or doc:get_selection() or 1
  line = math.min(math.max(line, 1), #doc.lines)

  local filename = doc.filename or "untitled"
  local ext = filename:match("%.([a-zA-Z0-9]+)$") or ""

  -- 1. Scan upward to find enclosing function or class header
  local scope_name = nil
  local scope_start = line
  local scope_end = line

  for l = line, math.max(1, line - 120), -1 do
    local text = doc.lines[l]
    -- Lua pattern: function Name(...) or local function Name(...)
    local fn_name = text:match("^%s*function%s+([%w_.:]+)%s*%(") or
                    text:match("^%s*local%s+function%s+([%w_]+)%s*%(") or
                    text:match("^%s*([%w_.:]+)%s*=%s*function%s*%(")
    if fn_name then
      scope_name = "function " .. fn_name
      scope_start = l
      break
    end
    -- Python pattern: def name(...) or class Name(...)
    local py_fn = text:match("^%s*def%s+([%w_]+)%s*%(") or text:match("^%s*class%s+([%w_]+)")
    if py_fn then
      scope_name = py_fn
      scope_start = l
      break
    end
    -- JS/TS pattern: function name(...) or const name = (...) =>
    local js_fn = text:match("^%s*function%s+([%w_]+)%s*%(") or
                   text:match("^%s*const%s+([%w_]+)%s*=%s*%(?[%w_,%s]*%)?%s*=>")
    if js_fn then
      scope_name = js_fn
      scope_start = l
      break
    end
  end

  -- 2. Scan forward to find end of function (approximate)
  if scope_name then
    for l = line, math.min(#doc.lines, line + 150) do
      local text = doc.lines[l]
      if ext == "lua" and text:match("^%s*end[%s,;]*$") then
        scope_end = l
        break
      elseif ext == "py" and l > line and text:match("^%S") then
        scope_end = l - 1
        break
      elseif (ext == "js" or ext == "ts") and text:match("^%s*}[%s,;]*$") then
        scope_end = l
        break
      end
    end
  end

  -- 3. Extract top-level imports / requires
  local imports = {}
  for l = 1, math.min(#doc.lines, 40) do
    local text = doc.lines[l]
    local req = text:match('require%s*%(?["\']([^"\']+)["\']') or
                text:match('import%s+([%w_]+)') or
                text:match('from%s+([%w_.]+)%s+import')
    if req and #imports < 5 then
      table.insert(imports, req:match("([^.]+)$") or req)
    end
  end

  local scope_desc = scope_name and
    string.format("%s (lines %d-%d)", scope_name, scope_start, scope_end) or
    string.format("global scope (line %d/%d)", line, #doc.lines)

  local import_str = #imports > 0 and (" | Imports: " .. table.concat(imports, ", ")) or ""

  return string.format("[Scope: %s in %s%s]", scope_desc, common.basename(filename), import_str)
end

Helpers.scope_extractor = ScopeExtractor
core.scope_extractor = ScopeExtractor

-- ── 3. Diagnostic & Stack Triage Engine ───────────────────────────────────────
-- Catches runtime errors, extracts exact 10-line failure windows, and prepares
-- ready-to-heal diagnosis packets for the AI.
local DiagnosticTriage = {
  last_triage = nil
}

function DiagnosticTriage.capture(err)
  local err_str = tostring(err)
  local file, line, msg = err_str:match("([^:\n]+):(%d+):%s*(.*)")
  if not file or not line then
    DiagnosticTriage.last_triage = { raw = err_str }
    return DiagnosticTriage.last_triage
  end

  line = tonumber(line)
  local norm_file = common.normalize_path(file)

  -- Read 5 lines before and 5 lines after the failure line
  local snippet = {}
  local fp = io.open(norm_file, "r")
  if fp then
    local cur = 1
    for l in fp:lines() do
      if cur >= math.max(1, line - 5) and cur <= line + 5 then
        local marker = (cur == line) and ">> " or "   "
        table.insert(snippet, string.format("%s%4d: %s", marker, cur, l))
      end
      cur = cur + 1
      if cur > line + 5 then break end
    end
    fp:close()
  end

  -- Detect common bug patterns
  local hint = "General runtime exception."
  if msg:match("cannot get undefined variable: (%w+)") then
    local var = msg:match("cannot get undefined variable: (%w+)")
    hint = string.format("Missing local declaration: 'local %s = require(\"core.%s\")' or missing variable assignment.", var, var)
  elseif msg:match("attempt to index a nil value %(field '(%w+)'%)") then
    local field = msg:match("attempt to index a nil value %(field '(%w+)'%)")
    hint = string.format("Nil index: Table holding '%s' is nil. Add guard check: 'if tbl and tbl.%s then'.", field, field)
  elseif msg:match("attempt to call a nil value") then
    hint = "Calling undefined function. Verify method name or require path."
  end

  DiagnosticTriage.last_triage = {
    file = norm_file,
    filename = common.basename(norm_file),
    line = line,
    message = msg,
    hint = hint,
    snippet = snippet,
    timestamp = system.get_time()
  }

  return DiagnosticTriage.last_triage
end

function DiagnosticTriage.get_summary()
  local t = DiagnosticTriage.last_triage
  if not t then return "[Diagnostics: Clean. No active exceptions.]" end
  if not t.file then return string.format("[Diagnostics: Raw error: %s]", tostring(t.raw or ""):sub(1, 80)) end
  return string.format("[Triage: %s:%d | Error: %s | Hint: %s]", t.filename, t.line, t.message, t.hint)
end

Helpers.diagnostic_triage = DiagnosticTriage
core.diagnostic_triage = DiagnosticTriage

-- Hook into core.on_error for automatic triage capture
local old_on_err = core.on_error
function core.on_error(err)
  DiagnosticTriage.capture(err)
  if old_on_err then return old_on_err(err) end
end

-- ── 4. Semantic Intent Pipeline Matcher ───────────────────────────────────────
-- Translates natural semantic action verbs into verified Lite XL commands,
-- so the AI does not have to memorize all 491 command names.
local IntentMatcher = {
  INTENT_MAP = {
    ["start_presentation"]  = { "pptx:start-slideshow", "pptx:first-slide" },
    ["exit_presentation"]   = { "pptx:exit-slideshow" },
    ["next_slide"]          = { "pptx:next-slide" },
    ["prev_slide"]          = { "pptx:prev-slide" },
    ["toggle_slide_deck"]   = { "pptx:toggle-deck" },
    ["split_right"]         = { "root:split-right" },
    ["split_down"]          = { "root:split-down" },
    ["close_tab"]           = { "root:close" },
    ["clean_tabs"]          = { "root:close-all-others" },
    ["format_buffer"]       = { "lsp:format-document", "doc:indent" },
    ["toggle_terminal"]     = { "toggle-terminal:toggle", "terminal:toggle" },
    ["open_visualizer"]     = { "ai_project_visualizer:toggle", "terraform_visualizer:open_canvas" },
    ["refresh_visualizer"]  = { "ai_project_visualizer:refresh", "terraform_visualizer:refresh" },
    ["leetcode_daily"]      = { "leetcode:daily-challenge" },
    ["leetcode_detect"]     = { "leetcode:auto-detect" },
    ["play_youtube"]        = { "youtube-player:quick-play" },
    ["play_music"]          = { "youtube-player:quick-play" },
    ["play_song"]           = { "youtube-player:quick-play" },
    ["toggle_youtube"]      = { "youtube-player:toggle" },
    ["pause_youtube"]       = { "youtube-player:play-pause" },
    ["voice_toggle"]        = { "aether:toggle-voice-typing" },
    ["save_buffer"]         = { "doc:save" },
    ["undo"]                = { "doc:undo" },
    ["redo"]                = { "doc:redo" },
  }
}

function IntentMatcher.execute(intent_verb, ...)
  local candidate_commands = IntentMatcher.INTENT_MAP[intent_verb]
  if candidate_commands then
    for _, cmd in ipairs(candidate_commands) do
      if command.map[cmd] then
        local ok, res = pcall(command.perform, cmd, ...)
        if ok then return true, string.format("Executed '%s' for intent '%s'", cmd, intent_verb) end
      end
    end
  end

  -- Fallback: Check if intent_verb is already a direct command name
  if command.map[intent_verb] then
    local ok, res = pcall(command.perform, intent_verb, ...)
    if ok then return true, string.format("Executed direct command '%s'", intent_verb) end
  end

  return false, "UNKNOWN_INTENT: Could not match intent '" .. tostring(intent_verb) .. "' to any registered command."
end

Helpers.intent_matcher = IntentMatcher
core.intent_matcher = IntentMatcher

-- Export on core
core.agent_helpers = Helpers

return Helpers
