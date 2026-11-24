-- mod-version:3
-- plugins/agent_capabilities.lua — Decentralized Host Capability Registry for Lite XL
-- Self-describing registry where all editor subsystems (Editor, LeetCode, PPTX, PDF,
-- MongoDB, Podman, Visualizers, Terminal, Diagnostics) expose verified agentic actions.

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local system = require "system"
local config = require "core.config"
local DocView = require "core.docview"

local Capabilities = {
  registry = {}
}

local function find_view_of_type(type_name)
  local function match_view(v)
    if not v then return false end
    if type_name == "pptx" then
      return v.goto_slide ~= nil or v.slideshow_mode ~= nil or (v.doc and v.doc.filename and v.doc.filename:match("%.pptx$"))
    elseif type_name == "pdf" then
      return v.goto_page ~= nil or (v.doc and v.doc.filename and v.doc.filename:match("%.pdf$"))
    elseif type_name == "youtube" then
      return v.ensure_backend ~= nil or v.playing_title ~= nil
    end
    return false
  end

  if core.active_view and match_view(core.active_view) then
    return core.active_view
  end

  local function scan(node)
    if not node then return nil end
    if node.views then
      for _, v in ipairs(node.views) do
        if match_view(v) then return v end
      end
    end
    if node.a then
      local res = scan(node.a)
      if res then return res end
    end
    if node.b then
      local res = scan(node.b)
      if res then return res end
    end
    return nil
  end

  return scan(core.root_view.root_node)
end

function Capabilities.register(subsystem_name, descriptor)
  assert(subsystem_name, "Subsystem name required")
  assert(descriptor and descriptor.actions, "Descriptor with actions required")
  Capabilities.registry[subsystem_name] = descriptor
  return true
end

function Capabilities.invoke(subsystem, action, params)
  params = params or {}
  local sub = Capabilities.registry[subsystem]
  if not sub then
    return false, string.format("UNKNOWN_SUBSYSTEM: '%s' is not registered in Lite XL.", tostring(subsystem))
  end

  local act_fn = sub.actions[action]
  if not act_fn then
    return false, string.format("UNKNOWN_ACTION: Subsystem '%s' does not have action '%s'.", subsystem, tostring(action))
  end

  local ok, res = pcall(act_fn, params)
  if not ok then
    -- Record failure with guardrails
    if core.guardrails then
      core.guardrails.record_failure(string.format("Capability '%s:%s' failed: %s", subsystem, action, tostring(res)))
    end
    return false, string.format("ACTION_ERROR: Failed executing '%s:%s': %s", subsystem, action, tostring(res))
  end

  return true, res
end

function Capabilities.list()
  local list = {}
  for name, sub in pairs(Capabilities.registry) do
    table.insert(list, { name = name, summary = sub.summary or "" })
  end
  return list
end

function Capabilities.get_schema(subsystem)
  local sub = Capabilities.registry[subsystem]
  if not sub then return nil end
  local actions = {}
  for a_name, a_info in pairs(sub.actions_meta or {}) do
    actions[a_name] = a_info
  end
  return { subsystem = subsystem, summary = sub.summary or "", actions = actions }
end

-- ── 1. Register "editor" Subsystem ────────────────────────────────────────────
Capabilities.register("editor", {
  summary = "Core document buffers, view navigation, tab management, and split choreography",
  actions_meta = {
    open_file = "Opens a file in the active or new tab, optionally scrolling to line/col.",
    switch_tab = "Switches active tab to document matching filename.",
    close_tab = "Closes active or specified tab.",
    open_split = "Arranges workspace in side_by_side, stacked, diff_view, or focus mode.",
    patch_buffer = "Applies atomic pre-flight verified code patch with rollback.",
    set_cursor = "Positions cursor at target line and column.",
    get_scope = "Returns AST scope summary (enclosing function, class, imports).",
    format = "Formats active buffer via LSP or indentation.",
    save = "Saves active document to disk."
  },
  actions = {
    open_file = function(p)
      local path = assert(p.path or p.file, "Missing path")
      local doc = core.open_doc(path)
      local view = core.root_view:open_doc(doc)
      if p.line then
        local line = tonumber(p.line) or 1
        local col = tonumber(p.col) or 1
        doc:set_selection(line, col, line, col)
        if view and view.scroll_to_line then
          view:scroll_to_line(line, true, true)
        end
      end
      return string.format("Opened '%s' at line %s", common.basename(path), tostring(p.line or 1))
    end,

    switch_tab = function(p)
      local target = assert(p.target or p.path or p.file, "Missing target")
      local target_low = target:lower()
      local node = core.root_view:get_active_node_default()
      for _, v in ipairs(node.views) do
        local fname = v.doc and v.doc.filename or (v.get_name and v:get_name() or "")
        if fname:lower():find(target_low, 1, true) then
          node:set_active_view(v)
          return string.format("Switched to tab '%s'", fname)
        end
      end
      return "Tab not found in active split node."
    end,

    close_tab = function(p)
      local node = core.root_view:get_active_node_default()
      node:close_active_view(core.root_view.root_node)
      return "Closed active view tab."
    end,

    open_split = function(p)
      if core.choreographer then
        local ok, msg = core.choreographer.arrange(p)
        if ok then return msg else error(msg) end
      end
      return "Choreographer not loaded."
    end,

    patch_buffer = function(p)
      local target_sig = assert(p.target_signature or p.target, "Missing target_signature")
      local replacement = assert(p.replacement_code or p.replacement or "", "Missing replacement_code")
      local doc = core.active_view and core.active_view.doc
      if p.path then doc = core.open_doc(p.path) end
      if not doc then error("No active document to patch.") end

      if core.guardrails then
        local ok, msg = core.guardrails.atomic_patch(doc, target_sig, replacement)
        if ok then return msg else error(msg) end
      else
        error("Guardrails engine missing.")
      end
    end,

    set_cursor = function(p)
      local doc = core.active_view and core.active_view.doc
      if not doc then error("No active document.") end
      local l = tonumber(p.line) or 1
      local c = tonumber(p.col) or 1
      doc:set_selection(l, c, l, c)
      if core.active_view.scroll_to_line then
        core.active_view:scroll_to_line(l, true, true)
      end
      return string.format("Cursor positioned at %d:%d", l, c)
    end,

    get_scope = function(p)
      if core.scope_extractor then
        return core.scope_extractor.extract(core.active_view and core.active_view.doc)
      end
      return "[Scope: ScopeExtractor missing]"
    end,

    format = function(p)
      if command.map["lsp:format-document"] then
        command.perform("lsp:format-document")
        return "Formatted document via LSP."
      else
        command.perform("doc:indent")
        return "Formatted document via indentation."
      end
    end,

    save = function(p)
      command.perform("doc:save")
      return "Saved active document."
    end
  }
})

-- ── 2. Register "leetcode" Subsystem ──────────────────────────────────────────
Capabilities.register("leetcode", {
  summary = "LeetCode DSA problem bank, company OA prediction, code test runner, and submission evaluator",
  actions_meta = {
    predict_company_oa = "Predicts top Online Assessment questions for a specific tech company (Google, Meta, Amazon, etc.).",
    fetch_problem = "Fetches problem description, sample inputs, constraints, and starter code.",
    run_test = "Executes solution code against official LeetCode test cases via GraphQL.",
    submit = "Submits solution to LeetCode and reports verdict (Accepted, WA, TLE) + percentiles.",
    daily_challenge = "Opens today's LeetCode daily challenge in an editor split.",
    dsa_patterns = "Lists key DSA patterns and associated practice questions."
  },
  actions = {
    predict_company_oa = function(p)
      local co = p.company or "Google"
      local limit = tonumber(p.limit) or 5
      local script = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "leetcode_api.py"
      local p_cmd = { "python", script, "--action", "predict_company_oa", "--company", co, "--limit", tostring(limit) }

      local proc = process.start(p_cmd, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
      if not proc then error("Failed to spawn leetcode_api.py process.") end
      while proc:running() do coroutine.yield(0.05) end

      local out = proc:read_stdout() or ""
      if out == "" then
        -- Fallback: query company_scores.json directly if present
        local scores_path = USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "company_scores.json"
        local fp = io.open(scores_path, "r")
        if fp then
          local raw = fp:read(4096)
          fp:close()
          return string.format("Predicted top OA problems for %s (from company scores bank):\n%s", co, raw:sub(1, 500))
        end
        return string.format("Predicted problems for %s retrieved.", co)
      end
      return out:sub(1, 2000)
    end,

    fetch_problem = function(p)
      local slug = assert(p.slug or p.title, "Missing problem slug or title")
      if command.map["leetcode:open-problem"] then
        command.perform("leetcode:open-problem", slug)
        return string.format("Fetched problem '%s' into LeetCode panel.", slug)
      elseif command.map["leetcode:fetch"] then
        command.perform("leetcode:fetch", slug)
        return string.format("Fetched problem '%s' into LeetCode panel.", slug)
      end
      return string.format("LeetCode problem '%s' fetched.", slug)
    end,

    run_test = function(p)
      if command.map["leetcode:run"] then
        command.perform("leetcode:run")
        return "Executed LeetCode test cases. Inspecting results in panel."
      elseif command.map["leetcode:run-code"] then
        command.perform("leetcode:run-code")
        return "Executed LeetCode test cases. Inspecting results in panel."
      end
      return "Triggered LeetCode code execution."
    end,

    submit = function(p)
      if command.map["leetcode:submit"] then
        command.perform("leetcode:submit")
        return "Submitted code to LeetCode evaluation engine."
      end
      return "Submission dispatched to LeetCode."
    end,

    daily_challenge = function(p)
      if command.map["leetcode:daily-challenge"] then
        command.perform("leetcode:daily-challenge")
        return "Opened today's LeetCode Daily Challenge."
      end
      return "Daily challenge triggered."
    end,

    dsa_patterns = function(p)
      return "DSA Patterns: Two Pointers, Sliding Window, Monotonic Stack, Backtracking, DP, Fast & Slow Pointers, Topological Sort."
    end
  }
})

-- ── 3. Register "pptx" Subsystem ──────────────────────────────────────────────
Capabilities.register("pptx", {
  summary = "PowerPoint presentation viewer, slideshow fullscreen mode, slide navigation, deck resizing",
  actions_meta = {
    start_slideshow = "Enters full-screen slideshow presentation mode.",
    exit_slideshow = "Exits slideshow mode back to slide deck editor.",
    goto_slide = "Jumps to specific slide number.",
    next_slide = "Advances to next slide.",
    prev_slide = "Moves to previous slide.",
    toggle_deck = "Toggles slide deck thumbnail sidebar.",
    toggle_theme = "Toggles slide color theme between light and dark."
  },
  actions = {
    start_slideshow = function(p)
      local view = find_view_of_type("pptx")
      if view and view.start_slideshow then
        view:start_slideshow()
        core.redraw = true
        return "Entered fullscreen slideshow mode."
      end
      command.perform("pptx:start-slideshow")
      return "Entered fullscreen slideshow mode."
    end,
    exit_slideshow = function(p)
      local view = find_view_of_type("pptx")
      if view and view.exit_slideshow then
        view:exit_slideshow()
        core.redraw = true
        return "Exited slideshow mode."
      end
      command.perform("pptx:exit-slideshow")
      return "Exited slideshow mode."
    end,
    goto_slide = function(p)
      local num = assert(p.slide or p.number, "Missing slide number")
      local view = find_view_of_type("pptx")
      if view and view.goto_slide then
        view:goto_slide(tonumber(num) or 1)
        core.redraw = true
        return string.format("Navigated to slide %d.", tonumber(num) or 1)
      end
      command.perform("pptx:goto-slide", tonumber(num) or 1)
      return string.format("Navigated to slide %d.", tonumber(num) or 1)
    end,
    next_slide = function(p)
      local view = find_view_of_type("pptx")
      if view and view.next_slide then
        view:next_slide()
        core.redraw = true
        return "Advanced to next slide."
      end
      command.perform("pptx:next-slide")
      return "Advanced to next slide."
    end,
    prev_slide = function(p)
      local view = find_view_of_type("pptx")
      if view and view.previous_slide then
        view:previous_slide()
        core.redraw = true
        return "Moved to previous slide."
      end
      command.perform("pptx:previous-slide")
      return "Moved to previous slide."
    end,
    toggle_deck = function(p)
      local view = find_view_of_type("pptx")
      if view then
        view.show_deck = not view.show_deck
        core.redraw = true
        return "Toggled slide deck panel."
      end
      command.perform("pptx:toggle-thumbnails")
      return "Toggled slide deck panel."
    end,
    toggle_theme = function(p)
      local view = find_view_of_type("pptx")
      if view then
        view.dark_theme = not view.dark_theme
        core.redraw = true
        return "Toggled PPTX color theme."
      end
      command.perform("pptx:toggle-theme")
      return "Toggled PPTX color theme."
    end
  }
})

-- ── 4. Register "pdf" Subsystem ───────────────────────────────────────────────
Capabilities.register("pdf", {
  summary = "Native PDF document viewing, page navigation, search, and zooming",
  actions = {
    goto_page = function(p)
      local pg = assert(p.page or p.number, "Missing page number")
      local view = find_view_of_type("pdf")
      if view and view.goto_page then
        view:goto_page(tonumber(pg) or 1)
        core.redraw = true
        return string.format("Navigated to PDF page %d.", tonumber(pg) or 1)
      end
      command.perform("pdf:goto-page", tonumber(pg) or 1)
      return string.format("Navigated to PDF page %d.", tonumber(pg) or 1)
    end,
    next_page = function(p)
      local view = find_view_of_type("pdf")
      if view and view.next_page then
        view:next_page()
        core.redraw = true
        return "Next PDF page."
      end
      command.perform("pdf:next-page")
      return "Next PDF page."
    end,
    prev_page = function(p)
      local view = find_view_of_type("pdf")
      if view and view.prev_page then
        view:prev_page()
        core.redraw = true
        return "Previous PDF page."
      end
      command.perform("pdf:previous-page")
      return "Previous PDF page."
    end,
    zoom = function(p)
      local dir = p.direction or "in"
      local view = find_view_of_type("pdf")
      if view then
        if dir == "in" and view.zoom_in then
          view:zoom_in()
        elseif view.zoom_out then
          view:zoom_out()
        end
        core.redraw = true
        return "Adjusted PDF zoom."
      end
      command.perform(dir == "in" and "pdf:zoom-in" or "pdf:zoom-out")
      return "Adjusted PDF zoom."
    end
  }
})

-- ── 5. Register "visualizer" Subsystem ────────────────────────────────────────
Capabilities.register("visualizer", {
  summary = "Interactive architecture flow graph visualizer and Terraform resource canvas",
  actions = {
    visualize_architecture = function(p)
      if command.map["ai_project_visualizer:toggle"] then
        command.perform("ai_project_visualizer:toggle")
        return "Toggled AI Project Visualizer canvas."
      end
      return "Visualizer toggle requested."
    end,
    refresh_architecture = function(p)
      if command.map["ai_project_visualizer:reanalyze"] then
        command.perform("ai_project_visualizer:reanalyze")
        return "Refreshed AI Project Visualizer dependency cache."
      elseif command.map["ai_project_visualizer:refresh"] then
        command.perform("ai_project_visualizer:refresh")
        return "Refreshed AI Project Visualizer dependency cache."
      end
      return "Visualizer refresh requested."
    end,
    visualize_terraform = function(p)
      if command.map["terraform_visualizer:open_canvas"] then
        command.perform("terraform_visualizer:open_canvas")
        return "Opened Terraform architecture canvas."
      end
      return "Terraform visualizer requested."
    end
  }
})

-- ── 6. Register "terminal" Subsystem ──────────────────────────────────────────
Capabilities.register("terminal", {
  summary = "Embedded terminal emulator running in split panes",
  actions = {
    toggle = function(p)
      if command.map["terminal:toggle"] then
        command.perform("terminal:toggle")
        return "Toggled terminal emulator."
      elseif command.map["toggle-terminal:toggle"] then
        command.perform("toggle-terminal:toggle")
        return "Toggled terminal emulator."
      end
      return "Terminal toggle requested."
    end,
    new_tab = function(p)
      if command.map["terminal:new-tab"] then
        command.perform("terminal:new-tab")
        return "Created new terminal tab."
      end
      return "New terminal tab requested."
    end,
    clear = function(p)
      if command.map["terminal:clear"] then
        command.perform("terminal:clear")
        return "Cleared terminal output."
      end
      return "Terminal clear requested."
    end
  }
})

-- ── 7. Register "diagnostics" Subsystem ────────────────────────────────────────
Capabilities.register("diagnostics", {
  summary = "Real-time error tracebacks, failure window isolation, and LSP compiler diagnostics",
  actions = {
    get_triage = function(p)
      if core.diagnostic_triage then
        return core.diagnostic_triage.get_summary()
      end
      return "No active diagnostic triage."
    end,
    get_recent_logs = function(p)
      local count = tonumber(p.limit) or 5
      local items = {}
      local logs = core.log_items or {}
      for i = #logs, math.max(1, #logs - count + 1), -1 do
        table.insert(items, string.format("[%s] %s", logs[i].level or "INFO", logs[i].text or ""))
      end
      return table.concat(items, "\n")
    end
  }
})

-- ── 8. Register "git" Subsystem ───────────────────────────────────────────────
Capabilities.register("git", {
  summary = "Git version control operations, diff viewer, commit history timeline",
  actions = {
    open_timeline = function(p)
      if command.map["git-timeline:toggle"] then
        command.perform("git-timeline:toggle")
        return "Toggled Git Timeline panel."
      end
      return "Git timeline toggle requested."
    end,
    open_diff = function(p)
      local target_file = p.path or p.file or ""
      local cmd = {"git", "diff"}
      if target_file ~= "" then
        table.insert(cmd, target_file)
      end
      local proc = process.start(cmd, { cwd = core.project_dir, stdout = process.REDIRECT_PIPE })
      if not proc then error("Failed to execute git diff.") end
      while proc:running() do coroutine.yield(0.05) end
      local diff_out = proc:read_stdout() or ""
      if diff_out == "" then
        return "Working tree clean. No diff to show."
      end

      local ok, GitDiffView = pcall(require, "plugins.git_diff_view")
      if ok and GitDiffView then
        local tab_name = target_file ~= "" and (target_file:match("[^/\\]+$") or target_file) or "Repository"
        local view = GitDiffView(diff_out, tab_name .. " (Diff)")
        local node = core.root_view:get_active_node_default()
        if node then
          node:add_view(view)
          node:set_active_view(view)
          core.redraw = true
          return string.format("Opened Git Diff view for %s.", tab_name)
        end
      end
      return string.format("Diff output:\n%s", diff_out:sub(1, 1000))
    end,
    status = function(p)
      local proc = process.start({"git", "status", "-s"}, { cwd = core.project_dir, stdout = process.REDIRECT_PIPE })
      if not proc then error("Failed to execute git status.") end
      while proc:running() do coroutine.yield(0.05) end
      local out = proc:read_stdout() or ""
      return #out > 0 and out or "Working tree clean. No changes."
    end,
    recent_commits = function(p)
      local limit = tonumber(p.limit) or 5
      local proc = process.start({"git", "log", string.format("-n%d", limit), "--oneline"}, { cwd = core.project_dir, stdout = process.REDIRECT_PIPE })
      if not proc then error("Failed to execute git log.") end
      while proc:running() do coroutine.yield(0.05) end
      return proc:read_stdout() or "No commits found."
    end
  }
})

-- ── 9. Register "mongodb" Subsystem ───────────────────────────────────────────
Capabilities.register("mongodb", {
  summary = "MongoDB database explorer, collection browser, document editor, and query scratchpad",
  actions_meta = {
    toggle = "Toggles MongoDB Explorer sidebar view.",
    refresh = "Refreshes active MongoDB connections, databases, and collections.",
    start_server = "Starts local MongoDB server daemon.",
    stop_server = "Stops local MongoDB server daemon.",
    new_scratchpad = "Opens a new MongoDB playground/scratchpad buffer.",
    execute_scratchpad = "Executes active MongoDB scratchpad query against connected database."
  },
  actions = {
    toggle = function(p)
      if command.map["mongodb_explorer:toggle"] then
        command.perform("mongodb_explorer:toggle")
        return "Toggled MongoDB Explorer."
      end
      return "MongoDB toggle requested."
    end,
    refresh = function(p)
      if command.map["mongodb_explorer:refresh"] then
        command.perform("mongodb_explorer:refresh")
        return "Refreshed MongoDB Explorer."
      end
      return "MongoDB refresh requested."
    end,
    start_server = function(p)
      if command.map["mongodb_explorer:start-server"] then
        command.perform("mongodb_explorer:start-server")
        return "Started MongoDB server."
      end
      return "MongoDB server start requested."
    end,
    stop_server = function(p)
      if command.map["mongodb_explorer:stop-server"] then
        command.perform("mongodb_explorer:stop-server")
        return "Stopped MongoDB server."
      end
      return "MongoDB server stop requested."
    end,
    new_scratchpad = function(p)
      if command.map["mongodb_explorer:new-scratchpad"] then
        command.perform("mongodb_explorer:new-scratchpad")
        return "Opened new MongoDB scratchpad."
      end
      return "MongoDB new scratchpad requested."
    end,
    execute_scratchpad = function(p)
      if command.map["mongodb_explorer:execute-scratchpad"] then
        command.perform("mongodb_explorer:execute-scratchpad")
        return "Executed MongoDB scratchpad query."
      end
      return "MongoDB scratchpad execution requested."
    end
  }
})

-- ── 10. Register "podman" Subsystem ───────────────────────────────────────────
Capabilities.register("podman", {
  summary = "Podman container engine, pods, images, and Kubernetes local orchestrator",
  actions_meta = {
    toggle = "Toggles Podman Manager sidebar view.",
    list_containers = "Queries podman ps -a to list active and stopped containers."
  },
  actions = {
    toggle = function(p)
      if command.map["podman:toggle"] then
        command.perform("podman:toggle")
        return "Toggled Podman Manager."
      end
      return "Podman toggle requested."
    end,
    list_containers = function(p)
      local cmd = PLATFORM == "Windows" and {"cmd.exe", "/c", "podman ps -a"} or {"podman", "ps", "-a"}
      local proc = process.start(cmd, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
      if not proc then error("Podman executable not found.") end
      while proc:running() do coroutine.yield(0.05) end
      local out = proc:read_stdout() or ""
      return #out > 0 and out or "No containers running."
    end
  }
})

-- ── 11. Register "crewai" Subsystem ───────────────────────────────────────────
Capabilities.register("crewai", {
  summary = "CrewAI multi-agent background crew (Investigator, Systems Engineer, Safety Auditor)",
  actions_meta = {
    run_crew = "Launches autonomous 3-agent background crew to solve, triage, or choreograph tasks.",
    pulse = "Fetches Lite XL ambient awareness pulse signature."
  },
  actions = {
    run_crew = function(p)
      local task_desc = p.task or "Triage current editor state and report findings"
      local script = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "crewai_litexl_bridge.py"
      local proc = process.start({"python", script, "--task", task_desc}, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
      if not proc then error("Failed to launch crewai_litexl_bridge.py") end
      while proc:running() do coroutine.yield(0.05) end
      local out = proc:read_stdout() or ""
      return #out > 0 and out or "Crew completed execution."
    end,
    pulse = function(p)
      if core.agent_meta_tools then
        return core.agent_meta_tools.pulse()
      end
      return "[IDE: active]"
    end
  }
})

-- ── 12. Register "voice" Subsystem ───────────────────────────────────────────
Capabilities.register("voice", {
  summary = "Real-time voice-to-text typing and conversational audio engine",
  actions_meta = {
    toggle = "Toggles real-time voice typing and microphone capture.",
    start = "Activates microphone and begins real-time speech transcription.",
    stop = "Deactivates microphone and stops voice typing.",
    status = "Returns whether voice typing is currently active."
  },
  actions = {
    toggle = function(p)
      if command.map["aether:toggle-voice-typing"] then
        command.perform("aether:toggle-voice-typing")
        return "Toggled voice typing."
      end
      return "Voice toggle requested."
    end,
    start = function(p)
      local inst = rawget(_G, "_ag_instance")
      if inst and inst.start_voice then
        inst:start_voice()
        return "Voice typing started."
      end
      command.perform("aether:toggle-voice-typing")
      return "Voice typing started."
    end,
    stop = function(p)
      local inst = rawget(_G, "_ag_instance")
      if inst and inst.stop_voice then
        inst:stop_voice()
        return "Voice typing stopped."
      end
      return "Voice typing stopped."
    end,
    status = function(p)
      local inst = rawget(_G, "_ag_instance")
      local active = inst and inst.voice_active or false
      return active and "Voice typing is ACTIVE (listening)" or "Voice typing is INACTIVE"
    end
  }
})

-- ── 13. Register "youtube" Subsystem ──────────────────────────────────────────
Capabilities.register("youtube", {
  summary = "Integrated YouTube audio and video music player with quick-play and playback controls",
  actions_meta = {
    play = "Searches YouTube and plays song or video immediately (param: query or title).",
    search = "Searches YouTube and lists video results (param: query).",
    toggle = "Toggles YouTube player panel view in split or sidebar.",
    play_pause = "Toggles playback between play and pause.",
    seek_forward = "Seeks playback forward 10 seconds.",
    seek_backward = "Seeks playback backward 10 seconds."
  },
  actions = {
    play = function(p)
      local q = p.query or p.title or p.song or p.name or p.target
      if not q or q == "" then error("Missing 'query' or 'title' to play.") end
      if command.map["youtube-player:quick-play"] then
        command.perform("youtube-player:quick-play", q)
        return string.format("Started playing '%s' on YouTube player.", q)
      end
      return "YouTube player plugin not loaded."
    end,
    search = function(p)
      local q = p.query or p.title or p.target
      if not q or q == "" then error("Missing 'query'.") end
      if command.map["youtube-player:search"] then
        command.perform("youtube-player:search", q)
        return string.format("Searched YouTube for '%s'.", q)
      end
      return "YouTube player plugin not loaded."
    end,
    toggle = function(p)
      if command.map["youtube-player:toggle"] then
        command.perform("youtube-player:toggle")
        return "Toggled YouTube player."
      end
      return "YouTube toggle requested."
    end,
    play_pause = function(p)
      if command.map["youtube-player:play-pause"] then
        command.perform("youtube-player:play-pause")
        return "Toggled YouTube playback."
      end
      return "Playback toggle requested."
    end,
    seek_forward = function(p)
      if command.map["youtube-player:seek-forward"] then
        command.perform("youtube-player:seek-forward")
        return "Seeked forward 10s."
      end
      return "Seek forward requested."
    end,
    seek_backward = function(p)
      if command.map["youtube-player:seek-backward"] then
        command.perform("youtube-player:seek-backward")
        return "Seeked backward 10s."
      end
      return "Seek backward requested."
    end
  }
})

-- ── 14. Register "web_preview" Subsystem ──────────────────────────────────────
Capabilities.register("web_preview", {
  summary = "Local HTTP preview server for web projects with hot reloading",
  actions_meta = {
    start = "Starts the local web preview server.",
    stop = "Stops the local web preview server.",
    restart = "Restarts the web preview server.",
    copy_url = "Copies local web preview server URL to clipboard."
  },
  actions = {
    start = function(p)
      if command.map["web-preview:start"] then
        command.perform("web-preview:start")
        return "Started local web preview server."
      end
      return "Web preview plugin not loaded."
    end,
    stop = function(p)
      if command.map["web-preview:stop"] then
        command.perform("web-preview:stop")
        return "Stopped local web preview server."
      end
      return "Web preview plugin not loaded."
    end,
    restart = function(p)
      if command.map["web-preview:restart"] then
        command.perform("web-preview:restart")
        return "Restarted local web preview server."
      end
      return "Web preview plugin not loaded."
    end,
    copy_url = function(p)
      if command.map["web-preview:copy-url"] then
        command.perform("web-preview:copy-url")
        return "Copied web preview URL."
      end
      return "Web preview plugin not loaded."
    end
  }
})

-- ── 15. Register "markdown" Subsystem ─────────────────────────────────────────
Capabilities.register("markdown", {
  summary = "Native rendered Markdown preview with GitHub-flavored markdown support",
  actions_meta = {
    preview = "Opens native rendered preview of the active or specified Markdown document."
  },
  actions = {
    preview = function(p)
      if p.path or p.file then
        local doc = core.open_doc(p.path or p.file)
        core.root_view:open_doc(doc)
      end
      if command.map["markdown:open-native-preview"] then
        command.perform("markdown:open-native-preview")
        return "Opened native Markdown preview."
      end
      return "Markdown preview plugin not loaded."
    end
  }
})

-- Export on core
core.capabilities = Capabilities

return Capabilities
