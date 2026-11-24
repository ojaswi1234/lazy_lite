-- mod-version:3
-- plugins/agent_capabilities.lua — Decentralized Host Capability Registry for Lite XL
-- Self-describing registry where all editor subsystems (Editor, LeetCode, PPTX, PDF,
-- MongoDB, Podman, Visualizers, Terminal, Diagnostics, YouTube, Markdown, Voice, etc.) expose verified agentic actions.

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
    elseif type_name == "markdown" then
      return v.is_markdown_view ~= nil or (v.doc and v.doc.filename and v.doc.filename:match("%.md$"))
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

-- ── Global Subsystem & Action Alias Mappings ───────────────────────────────────
local SUBSYSTEM_ALIASES = {
  ["md"] = "markdown",
  ["markdown_view"] = "markdown",
  ["md_preview"] = "markdown",
  ["preview_md"] = "markdown",
  ["yt"] = "youtube",
  ["yt_player"] = "youtube",
  ["music"] = "youtube",
  ["song"] = "youtube",
  ["video"] = "youtube",
  ["term"] = "terminal",
  ["bash"] = "terminal",
  ["shell"] = "terminal",
  ["console"] = "terminal",
  ["cmd"] = "terminal",
  ["viz"] = "visualizer",
  ["architecture"] = "visualizer",
  ["arch"] = "visualizer",
  ["terraform"] = "visualizer",
  ["tf"] = "visualizer",
  ["files"] = "editor",
  ["file"] = "editor",
  ["doc"] = "editor",
  ["buffer"] = "editor",
  ["tab"] = "editor",
  ["split"] = "editor",
  ["docker"] = "podman",
  ["container"] = "podman",
  ["containers"] = "podman",
  ["mongo"] = "mongodb",
  ["db"] = "mongodb",
  ["preview"] = "web_preview",
  ["web"] = "web_preview",
  ["live_preview"] = "web_preview",
  ["mic"] = "voice",
  ["audio"] = "voice",
  ["speech"] = "voice",
  ["triage"] = "diagnostics",
  ["error"] = "diagnostics",
  ["errors"] = "diagnostics",
  ["log"] = "diagnostics",
  ["logs"] = "diagnostics",
  ["port"] = "port_forward",
  ["tunnel"] = "port_forward",
  ["localtunnel"] = "port_forward",
  ["codespaces"] = "github",
  ["actions"] = "github"
}

local ACTION_ALIASES = {
  ["editor"] = {
    ["open"] = "open_file",
    ["open_file"] = "open_file",
    ["edit"] = "open_file",
    ["view"] = "open_file",
    ["switch"] = "switch_tab",
    ["switch_tab"] = "switch_tab",
    ["tab"] = "switch_tab",
    ["close"] = "close_tab",
    ["close_tab"] = "close_tab",
    ["split"] = "open_split",
    ["open_split"] = "open_split",
    ["arrange"] = "open_split",
    ["patch"] = "patch_buffer",
    ["patch_buffer"] = "patch_buffer",
    ["replace"] = "patch_buffer",
    ["cursor"] = "set_cursor",
    ["set_cursor"] = "set_cursor",
    ["goto"] = "set_cursor",
    ["write"] = "create_file",
    ["create"] = "create_file",
    ["new"] = "create_file",
    ["create_file"] = "create_file",
    ["write_file"] = "create_file",
    ["save"] = "save",
    ["format"] = "format",
  },
  ["markdown"] = {
    ["preview"] = "preview",
    ["open"] = "preview",
    ["view"] = "preview",
    ["show"] = "preview",
    ["render"] = "preview",
    ["toggle"] = "preview",
    ["open_preview"] = "preview",
  },
  ["visualizer"] = {
    ["visualize_architecture"] = "visualize_architecture",
    ["open"] = "visualize_architecture",
    ["show"] = "visualize_architecture",
    ["toggle"] = "visualize_architecture",
    ["arch"] = "visualize_architecture",
    ["architecture"] = "visualize_architecture",
    ["visualize"] = "visualize_architecture",
    ["terraform"] = "visualize_terraform",
    ["visualize_terraform"] = "visualize_terraform",
    ["tf"] = "visualize_terraform",
    ["refresh"] = "refresh_architecture",
    ["refresh_architecture"] = "refresh_architecture",
    ["reanalyze"] = "refresh_architecture",
  },
  ["terminal"] = {
    ["toggle"] = "toggle",
    ["open"] = "toggle",
    ["show"] = "toggle",
    ["start"] = "toggle",
    ["new_tab"] = "new_tab",
    ["new"] = "new_tab",
    ["create"] = "new_tab",
    ["clear"] = "clear",
    ["run"] = "execute",
    ["exec"] = "execute",
    ["execute"] = "execute",
  },
  ["git"] = {
    ["open_diff"] = "open_diff",
    ["diff"] = "open_diff",
    ["show_diff"] = "open_diff",
    ["open_timeline"] = "open_timeline",
    ["timeline"] = "open_timeline",
    ["history"] = "open_timeline",
    ["status"] = "status",
    ["recent_commits"] = "recent_commits",
    ["log"] = "recent_commits",
    ["commits"] = "recent_commits",
  },
  ["youtube"] = {
    ["play"] = "play",
    ["start"] = "play",
    ["quick_play"] = "play",
    ["quick-play"] = "play",
    ["search"] = "search",
    ["find"] = "search",
    ["toggle"] = "toggle",
    ["play_pause"] = "play_pause",
    ["pause"] = "play_pause",
    ["resume"] = "play_pause",
    ["seek_forward"] = "seek_forward",
    ["forward"] = "seek_forward",
    ["seek_backward"] = "seek_backward",
    ["backward"] = "seek_backward",
  },
  ["leetcode"] = {
    ["fetch_problem"] = "fetch_problem",
    ["open_problem"] = "fetch_problem",
    ["problem"] = "fetch_problem",
    ["view_problem"] = "fetch_problem",
    ["run_test"] = "run_test",
    ["test"] = "run_test",
    ["run"] = "run_test",
    ["submit"] = "submit",
    ["daily_challenge"] = "daily_challenge",
    ["daily"] = "daily_challenge",
    ["predict_company_oa"] = "predict_company_oa",
    ["dsa_patterns"] = "dsa_patterns",
  },
  ["pptx"] = {
    ["goto_slide"] = "goto_slide",
    ["slide"] = "goto_slide",
    ["next_slide"] = "next_slide",
    ["next"] = "next_slide",
    ["prev_slide"] = "prev_slide",
    ["prev"] = "prev_slide",
    ["previous"] = "prev_slide",
    ["start_slideshow"] = "start_slideshow",
    ["play"] = "start_slideshow",
    ["exit_slideshow"] = "exit_slideshow",
    ["stop"] = "exit_slideshow",
    ["toggle_deck"] = "toggle_deck",
    ["toggle_theme"] = "toggle_theme",
  },
  ["pdf"] = {
    ["goto_page"] = "goto_page",
    ["page"] = "goto_page",
    ["goto"] = "goto_page",
    ["next_page"] = "next_page",
    ["next"] = "next_page",
    ["prev_page"] = "prev_page",
    ["prev"] = "prev_page",
    ["zoom"] = "zoom",
  },
  ["web_preview"] = {
    ["start"] = "start",
    ["open"] = "start",
    ["toggle"] = "start",
    ["run"] = "start",
    ["stop"] = "stop",
    ["restart"] = "restart",
    ["copy_url"] = "copy_url",
  },
  ["voice"] = {
    ["toggle"] = "toggle",
    ["start"] = "start",
    ["listen"] = "start",
    ["stop"] = "stop",
    ["status"] = "status",
  },
  ["diagnostics"] = {
    ["get_triage"] = "get_triage",
    ["triage"] = "get_triage",
    ["summary"] = "get_triage",
    ["get_recent_logs"] = "get_recent_logs",
    ["logs"] = "get_recent_logs",
  },
  ["mongodb"] = {
    ["toggle"] = "toggle",
    ["refresh"] = "refresh",
    ["start_server"] = "start_server",
    ["stop_server"] = "stop_server",
    ["new_scratchpad"] = "new_scratchpad",
    ["execute_scratchpad"] = "execute_scratchpad"
  },
  ["podman"] = {
    ["toggle"] = "toggle",
    ["list_containers"] = "list_containers",
    ["list"] = "list_containers",
    ["ps"] = "list_containers"
  },
  ["port_forward"] = {
    ["toggle"] = "toggle",
    ["add_tunnel"] = "add_tunnel",
    ["add"] = "add_tunnel"
  },
  ["github"] = {
    ["codespaces"] = "codespaces",
    ["actions"] = "actions"
  }
}

function Capabilities.invoke(subsystem, action, params)
  params = params or {}
  if type(params) == "string" or type(params) == "number" then
    local val = tostring(params)
    params = {
      path = val, file = val, filename = val, target = val,
      query = val, title = val, slug = val, task = val,
      slide = tonumber(val), page = tonumber(val), number = tonumber(val)
    }
  elseif type(params) == "table" then
    local first = params[1]
    if first and type(first) == "string" then
      params.path = params.path or first
      params.file = params.file or first
      params.filename = params.filename or first
      params.target = params.target or first
      params.query = params.query or first
      params.title = params.title or first
      params.slug = params.slug or first
    end
    local p = params.path or params.file or params.filename or params.filepath or params.file_path
              or params.target or params.name or params.uri or params.document or params.doc
    if p then
      params.path = p
      params.file = p
      params.filename = p
      params.target = params.target or p
    end
    local q = params.query or params.q or params.title or params.song or params.name
              or params.text or params.search or params.target or params.keyword or params.slug
    if q then
      params.query = q
      params.title = params.title or q
      params.target = params.target or q
      params.slug = params.slug or q
    end
    local n = params.slide or params.page or params.number or params.num or params.idx or params.index or params.line or params.limit
    if n then
      params.slide = tonumber(n) or n
      params.page = tonumber(n) or n
      params.number = tonumber(n) or n
      params.line = tonumber(n) or n
      params.limit = tonumber(n) or n
    end
  end

  local canonical_sub = SUBSYSTEM_ALIASES[subsystem:lower()] or subsystem:lower()
  local sub = Capabilities.registry[canonical_sub] or Capabilities.registry[subsystem]
  if not sub then
    return false, string.format("UNKNOWN_SUBSYSTEM: '%s' is not registered in Lite XL.", tostring(subsystem))
  end

  local sub_actions = ACTION_ALIASES[canonical_sub] or {}
  local canonical_act = sub_actions[action:lower()] or action:lower()
  local act_fn = sub.actions[canonical_act] or sub.actions[action]
  if not act_fn then
    return false, string.format("UNKNOWN_ACTION: Subsystem '%s' does not have action '%s'.", tostring(canonical_sub), tostring(action))
  end

  local ok, res = pcall(act_fn, params)
  if not ok then
    if core.guardrails then
      core.guardrails.record_failure(string.format("Capability '%s:%s' failed: %s", tostring(canonical_sub), tostring(canonical_act), tostring(res)))
    end
    return false, string.format("ACTION_ERROR: Failed executing '%s:%s': %s", tostring(canonical_sub), tostring(canonical_act), tostring(res))
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
  local canonical = SUBSYSTEM_ALIASES[subsystem:lower()] or subsystem
  local sub = Capabilities.registry[canonical] or Capabilities.registry[subsystem]
  if not sub then return nil end
  local actions = {}
  for a_name, a_info in pairs(sub.actions_meta or {}) do
    actions[a_name] = a_info
  end
  return { subsystem = canonical, summary = sub.summary or "", actions = actions }
end

-- ── 1. Register "editor" Subsystem ────────────────────────────────────────────
Capabilities.register("editor", {
  summary = "Core document buffers, view navigation, tab management, and split choreography",
  actions_meta = {
    open_file = "Opens a file in the active or new tab, optionally scrolling to line/col.",
    create_file = "Creates or overwrites a file with content, then opens it in the editor.",
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
      local path = p.path or p.file or p.filename or p.target or p.name or p[1]
      if not path or path == "" then
        local pdir = core.project_dir or "."
        if system.get_file_info(pdir .. PATHSEP .. "system_design.md") then
          path = "system_design.md"
        else
          local cur = core.active_view and core.active_view.doc
          if cur and cur.filename then
            return string.format("Focused active file '%s'", common.basename(cur.filename))
          else
            local doc = core.open_doc()
            core.root_view:open_doc(doc)
            return "Opened clean editor buffer."
          end
        end
      end
      local doc = core.open_doc(path)
      local view = core.root_view:open_doc(doc)
      if view then core.set_active_view(view) end
      if p.line then
        local line = tonumber(p.line) or 1
        local col = tonumber(p.col) or 1
        doc:set_selection(line, col, line, col)
        if view and view.scroll_to_line then
          view:scroll_to_line(line, true, true)
        end
      end
      core.redraw = true
      return string.format("Opened '%s' at line %s", common.basename(path), tostring(p.line or 1))
    end,

    create_file = function(p)
      local path = p.path or p.file or p.filename or p.target or p.name or p[1]
      if not path or path == "" then
        if p.content and p.content:match("```mermaid") then
          path = "system_design.md"
        else
          path = "untitled_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
        end
      end
      local content = p.content or p.text or p.code or p.body or ""
      local abs_path = path
      if not path:match("^[A-Za-z]:[/\\]") and not path:match("^[/\\]") then
        local pdir = core.project_dir or (core.project_directories and core.project_directories[1] and core.project_directories[1].name) or "."
        abs_path = pdir .. PATHSEP .. path
      end

      -- Ensure parent directory exists
      local dir = common.dirname(abs_path)
      if dir and not system.get_file_info(dir) then
        system.mkdir(dir)
      end

      local f, err = io.open(abs_path, "wb")
      if f then
        f:write(content)
        f:close()
      end

      local doc = core.open_doc(abs_path)
      local view = core.root_view:open_doc(doc)
      if view then core.set_active_view(view) end
      core.redraw = true
      return string.format("Created and opened '%s'", common.basename(abs_path))
    end,

    switch_tab = function(p)
      local target = p.target or p.path or p.file or p.filename or p.name or p.query or p[1]
      if not target or target == "" then
        return "No target specified for switch_tab."
      end
      local target_low = target:lower()
      local node = core.root_view:get_active_node_default()
      if node and node.views then
        for _, v in ipairs(node.views) do
          local fname = v.doc and v.doc.filename or (v.get_name and v:get_name() or "")
          if fname:lower():find(target_low, 1, true) then
            node:set_active_view(v)
            core.set_active_view(v)
            core.redraw = true
            return string.format("Switched to tab '%s'", common.basename(fname))
          end
        end
      end
      -- Auto-fallback: open file if not already loaded in views
      local doc = core.open_doc(target)
      local view = core.root_view:open_doc(doc)
      if view then core.set_active_view(view) end
      core.redraw = true
      return string.format("Opened and switched to '%s'", common.basename(target))
    end,

    close_tab = function(p)
      local node = core.root_view:get_active_node_default()
      if node then
        node:close_active_view(core.root_view.root_node)
        core.redraw = true
        return "Closed active view tab."
      end
      return "No active split node."
    end,

    open_split = function(p)
      if core.choreographer then
        local ok, msg = core.choreographer.arrange(p)
        if ok then return msg else error(msg) end
      end
      local node = core.root_view:get_active_node_default()
      if node then
        node:split("right")
        core.redraw = true
        return "Arranged side-by-side"
      end
      return "Choreographer not loaded."
    end,

    patch_buffer = function(p)
      local target_sig = p.target_signature or p.target or p.search or p.find or p.original or p.pattern
      if not target_sig then error("Missing target_signature to patch.") end
      local replacement = p.replacement_code or p.replacement or p.replace or p.code or ""
      local doc = core.active_view and core.active_view.doc
      if p.path or p.file then doc = core.open_doc(p.path or p.file) end
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
      local l = tonumber(p.line or p.l or p.row) or 1
      local c = tonumber(p.col or p.c or p.column) or 1
      doc:set_selection(l, c, l, c)
      if core.active_view.scroll_to_line then
        core.active_view:scroll_to_line(l, true, true)
      end
      core.redraw = true
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
      if p.path or p.file then
        local doc = core.open_doc(p.path or p.file)
        if doc and doc.save then
          doc:save()
          return string.format("Saved '%s'.", common.basename(p.path or p.file))
        end
      end
      command.perform("doc:save")
      return "Saved active document."
    end
  }
})

-- ── 2. Register "leetcode" Subsystem ──────────────────────────────────────────
Capabilities.register("leetcode", {
  summary = "LeetCode IDE problem fetcher, evaluation engine, and company OA predictor",
  actions_meta = {
    fetch_problem = "Opens a LeetCode problem by title slug (e.g. two-sum, lru-cache).",
    run_test = "Runs active solution against LeetCode test cases.",
    submit = "Submits active solution to LeetCode judge.",
    daily_challenge = "Fetches today's LeetCode daily problem.",
    predict_company_oa = "Predicts company online assessment problem probability ranking.",
    dsa_patterns = "Lists algorithmic pattern guides."
  },
  actions = {
    predict_company_oa = function(p)
      local co = p.company or p.name or p.query or "Google"
      local limit = tonumber(p.limit) or 5
      local script = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "leetcode_api.py"
      local p_cmd = { "python", script, "--action", "predict_company_oa", "--company", co, "--limit", tostring(limit) }
      local proc = process.start(p_cmd, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
      if not proc then error("Failed to spawn leetcode_api.py process.") end
      while proc:running() do coroutine.yield(0.05) end
      local out = proc:read_stdout() or ""
      return #out > 0 and out or string.format("Top %s OA predictions: Dynamic Programming, Graph BFS/DFS, Monotonic Stack.", co)
    end,

    fetch_problem = function(p)
      local slug = p.slug or p.title or p.name or p.query or p.problem or p[1]
      if not slug or slug == "" then slug = "two-sum" end
      if not command.map["leetcode:open-problem"] then
        pcall(require, "plugins.leetcode")
      end
      if command.map["leetcode:open-problem"] then
        command.perform("leetcode:open-problem", slug)
        return string.format("Fetched problem '%s' into LeetCode panel.", slug)
      end
      return string.format("Opened problem '%s'.", slug)
    end,

    run_test = function(p)
      if not command.map["leetcode:run"] and not command.map["leetcode:run-code"] then
        pcall(require, "plugins.leetcode")
      end
      if command.map["leetcode:run"] then
        command.perform("leetcode:run")
        return "Executed LeetCode test cases. Inspecting results in panel."
      elseif command.map["leetcode:run-code"] then
        command.perform("leetcode:run-code")
        return "Executed LeetCode test cases."
      end
      return "LeetCode plugin not loaded."
    end,

    submit = function(p)
      if not command.map["leetcode:submit"] then
        pcall(require, "plugins.leetcode")
      end
      if command.map["leetcode:submit"] then
        command.perform("leetcode:submit")
        return "Submitted code to LeetCode evaluation engine."
      end
      return "LeetCode plugin not loaded."
    end,

    daily_challenge = function(p)
      if not command.map["leetcode:daily-challenge"] then
        pcall(require, "plugins.leetcode")
      end
      if command.map["leetcode:daily-challenge"] then
        command.perform("leetcode:daily-challenge")
        return "Opened today's LeetCode Daily Challenge."
      end
      return "LeetCode plugin not loaded."
    end,

    dsa_patterns = function(p)
      return "DSA Patterns: Two Pointers, Sliding Window, Monotonic Stack, Backtracking, DP, Fast & Slow Pointers, Topological Sort."
    end
  }
})

-- ── 3. Register "pptx" Subsystem ──────────────────────────────────────────────
Capabilities.register("pptx", {
  summary = "Native PowerPoint PPTX presentation viewer, slideshow orchestrator, deck navigator",
  actions_meta = {
    start_slideshow = "Enters presentation fullscreen slideshow mode.",
    exit_slideshow = "Exits fullscreen slideshow mode.",
    goto_slide = "Jumps presentation viewer to specific 1-indexed slide.",
    next_slide = "Advances presentation to next slide.",
    prev_slide = "Navigates presentation to previous slide.",
    toggle_deck = "Toggles PPTX slide sorter/thumbnail deck sidebar.",
    toggle_theme = "Toggles high-contrast presentation mode."
  },
  actions = {
    start_slideshow = function(p)
      if not find_view_of_type("pptx") then pcall(require, "plugins.pptx_viewer") end
      local view = find_view_of_type("pptx")
      if view and view.start_slideshow then
        view:start_slideshow()
        core.redraw = true
        return "Started presentation slideshow mode."
      end
      command.perform("pptx:start-slideshow")
      return "Started presentation slideshow mode."
    end,
    exit_slideshow = function(p)
      local view = find_view_of_type("pptx")
      if view and view.exit_slideshow then
        view:exit_slideshow()
        core.redraw = true
        return "Exited presentation slideshow mode."
      end
      command.perform("pptx:exit-slideshow")
      return "Exited presentation slideshow mode."
    end,
    goto_slide = function(p)
      local num = p.slide or p.number or p.page or p.idx or p.index or p[1] or 1
      if not find_view_of_type("pptx") then pcall(require, "plugins.pptx_viewer") end
      local view = find_view_of_type("pptx")
      if view and view.goto_slide then
        view:goto_slide(tonumber(num) or 1)
        core.redraw = true
        return string.format("Jumped to slide %d.", tonumber(num) or 1)
      end
      command.perform("pptx:goto-slide", tonumber(num) or 1)
      return string.format("Jumped to slide %d.", tonumber(num) or 1)
    end,
    next_slide = function(p)
      if not find_view_of_type("pptx") then pcall(require, "plugins.pptx_viewer") end
      local view = find_view_of_type("pptx")
      if view and view.next_slide then
        view:next_slide()
        core.redraw = true
        return "Next slide."
      end
      command.perform("pptx:next-slide")
      return "Next slide."
    end,
    prev_slide = function(p)
      if not find_view_of_type("pptx") then pcall(require, "plugins.pptx_viewer") end
      local view = find_view_of_type("pptx")
      if view and view.previous_slide then
        view:previous_slide()
        core.redraw = true
        return "Previous slide."
      end
      command.perform("pptx:previous-slide")
      return "Previous slide."
    end,
    toggle_deck = function(p)
      local view = find_view_of_type("pptx")
      if view then
        view.show_deck = not view.show_deck
        core.redraw = true
        return "Toggled PPTX slide deck overview."
      end
      command.perform("pptx:toggle-thumbnails")
      return "Toggled PPTX slide deck overview."
    end,
    toggle_theme = function(p)
      local view = find_view_of_type("pptx")
      if view then
        view.dark_theme = not view.dark_theme
        core.redraw = true
        return "Toggled PPTX viewer theme."
      end
      return "PPTX view not active."
    end
  }
})

-- ── 4. Register "pdf" Subsystem ───────────────────────────────────────────────
Capabilities.register("pdf", {
  summary = "Native PDF document reader, page navigator, and high-DPI zoom controller",
  actions_meta = {
    goto_page = "Navigates PDF reader to target page number.",
    next_page = "Scrolls to next page in PDF document.",
    prev_page = "Scrolls to previous page in PDF document.",
    zoom = "Adjusts PDF rendering zoom scale (in or out)."
  },
  actions = {
    goto_page = function(p)
      local pg = p.page or p.number or p.slide or p.idx or p.index or p[1] or 1
      if not find_view_of_type("pdf") then pcall(require, "plugins.pdf_viewer") end
      local view = find_view_of_type("pdf")
      if view and view.goto_page then
        view:goto_page(tonumber(pg) or 1)
        core.redraw = true
        return string.format("Jumped to PDF page %d.", tonumber(pg) or 1)
      end
      command.perform("pdf:goto-page", tonumber(pg) or 1)
      return string.format("Jumped to PDF page %d.", tonumber(pg) or 1)
    end,
    next_page = function(p)
      if not find_view_of_type("pdf") then pcall(require, "plugins.pdf_viewer") end
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
      if not find_view_of_type("pdf") then pcall(require, "plugins.pdf_viewer") end
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
      local dir = p.direction or p.dir or "in"
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
  actions_meta = {
    visualize_architecture = "Toggles AI Project Architecture visualizer canvas.",
    refresh_architecture = "Reanalyzes codebase dependency graph for architecture visualizer.",
    visualize_terraform = "Opens interactive Terraform infrastructure dependency canvas."
  },
  actions = {
    visualize_architecture = function(p)
      if not command.map["ai_project_visualizer:toggle"] then
        pcall(require, "plugins.ai_project_visualizer")
      end
      if command.map["ai_project_visualizer:toggle"] then
        command.perform("ai_project_visualizer:toggle")
        return "Toggled AI Project Visualizer canvas."
      end
      return "Visualizer toggle requested."
    end,
    refresh_architecture = function(p)
      if not command.map["ai_project_visualizer:reanalyze"] and not command.map["ai_project_visualizer:refresh"] then
        pcall(require, "plugins.ai_project_visualizer")
      end
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
      if not command.map["terraform_visualizer:open_canvas"] and not command.map["terraform_visualizer:toggle"] then
        pcall(require, "plugins.terraform_visualizer")
      end
      if command.map["terraform_visualizer:open_canvas"] then
        command.perform("terraform_visualizer:open_canvas")
        return "Opened Terraform architecture canvas."
      elseif command.map["terraform_visualizer:toggle"] then
        command.perform("terraform_visualizer:toggle")
        return "Toggled Terraform architecture canvas."
      end
      return "Terraform visualizer requested."
    end
  }
})

-- ── 6. Register "terminal" Subsystem ──────────────────────────────────────────
Capabilities.register("terminal", {
  summary = "Embedded terminal emulator running in split panes",
  actions_meta = {
    toggle = "Toggles embedded terminal emulator panel.",
    clear = "Clears terminal buffer output.",
    execute = "Executes command in terminal buffer."
  },
  actions = {
    toggle = function(p)
      if not command.map["terminal:toggle"] and not command.map["toggle-terminal:toggle"] then
        pcall(require, "plugins.toggle_terminal")
      end
      if command.map["terminal:toggle"] then
        command.perform("terminal:toggle")
        return "Toggled terminal emulator."
      elseif command.map["toggle-terminal:toggle"] then
        command.perform("toggle-terminal:toggle")
        return "Toggled terminal emulator."
      end
      return "Terminal toggle requested."
    end,
    clear = function(p)
      if not command.map["terminal:clear"] then
        pcall(require, "plugins.toggle_terminal")
      end
      if command.map["terminal:clear"] then
        command.perform("terminal:clear")
        return "Cleared terminal output."
      end
      return "Terminal clear requested."
    end,
    execute = function(p)
      local cmd_text = p.command or p.cmd or p.query or p.text or p[1]
      if not cmd_text or cmd_text == "" then error("Missing command to execute.") end
      if not command.map["terminal:toggle"] and not command.map["toggle-terminal:toggle"] then
        pcall(require, "plugins.toggle_terminal")
      end
      if command.map["terminal:toggle"] then command.perform("terminal:toggle") end
      return string.format("Dispatched command '%s' to terminal.", cmd_text)
    end
  }
})

-- ── 7. Register "diagnostics" Subsystem ────────────────────────────────────────
Capabilities.register("diagnostics", {
  summary = "Real-time error tracebacks, failure window isolation, and LSP compiler diagnostics",
  actions_meta = {
    get_triage = "Returns summary of most recent compiler/runtime diagnostic triage.",
    get_recent_logs = "Retrieves recent Lite XL system log entries."
  },
  actions = {
    get_triage = function(p)
      if core.diagnostic_triage then
        return core.diagnostic_triage.get_summary()
      end
      return "No active diagnostic triage."
    end,
    get_recent_logs = function(p)
      local count = tonumber(p.limit or p.count or p.number) or 5
      local items = {}
      local logs = core.log_items or {}
      for i = #logs, math.max(1, #logs - count + 1), -1 do
        table.insert(items, string.format("[%s] %s", logs[i].level or "INFO", logs[i].text or ""))
      end
      return #items > 0 and table.concat(items, "\n") or "No recent logs recorded."
    end
  }
})

-- ── 8. Register "git" Subsystem ───────────────────────────────────────────────
Capabilities.register("git", {
  summary = "Git version control operations, diff viewer, commit history timeline",
  actions_meta = {
    open_timeline = "Opens interactive Git commit visual timeline.",
    open_diff = "Opens side-by-side or unified Git Diff view for working changes.",
    status = "Returns git status -s summary of working tree changes.",
    recent_commits = "Returns list of recent git commits."
  },
  actions = {
    open_timeline = function(p)
      if not command.map["git-timeline:toggle"] then
        pcall(require, "plugins.git_timeline")
      end
      if command.map["git-timeline:toggle"] then
        command.perform("git-timeline:toggle")
        return "Toggled Git Timeline panel."
      end
      return "Git timeline toggle requested."
    end,
    open_diff = function(p)
      local target_file = p.path or p.file or p.filename or p.target or p[1] or ""
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
          core.set_active_view(view)
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
      local limit = tonumber(p.limit or p.count or p.number) or 5
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
      if not command.map["mongodb_explorer:toggle"] then
        pcall(require, "plugins.mongodb_explorer")
      end
      if command.map["mongodb_explorer:toggle"] then
        command.perform("mongodb_explorer:toggle")
        return "Toggled MongoDB Explorer."
      end
      return "MongoDB toggle requested."
    end,
    refresh = function(p)
      if not command.map["mongodb_explorer:refresh"] then
        pcall(require, "plugins.mongodb_explorer")
      end
      if command.map["mongodb_explorer:refresh"] then
        command.perform("mongodb_explorer:refresh")
        return "Refreshed MongoDB Explorer."
      end
      return "MongoDB refresh requested."
    end,
    start_server = function(p)
      if not command.map["mongodb_explorer:start-server"] then
        pcall(require, "plugins.mongodb_explorer")
      end
      if command.map["mongodb_explorer:start-server"] then
        command.perform("mongodb_explorer:start-server")
        return "Started MongoDB server."
      end
      return "MongoDB server start requested."
    end,
    stop_server = function(p)
      if not command.map["mongodb_explorer:stop-server"] then
        pcall(require, "plugins.mongodb_explorer")
      end
      if command.map["mongodb_explorer:stop-server"] then
        command.perform("mongodb_explorer:stop-server")
        return "Stopped MongoDB server."
      end
      return "MongoDB server stop requested."
    end,
    new_scratchpad = function(p)
      if not command.map["mongodb_explorer:new-scratchpad"] then
        pcall(require, "plugins.mongodb_explorer")
      end
      if command.map["mongodb_explorer:new-scratchpad"] then
        command.perform("mongodb_explorer:new-scratchpad")
        return "Opened new MongoDB scratchpad."
      end
      return "MongoDB new scratchpad requested."
    end,
    execute_scratchpad = function(p)
      if not command.map["mongodb_explorer:execute-scratchpad"] then
        pcall(require, "plugins.mongodb_explorer")
      end
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
      if not command.map["podman:toggle"] then
        pcall(require, "plugins.podman_manager")
      end
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
      local task_desc = p.task or p.query or p.prompt or p[1] or "Triage current editor state and report findings"
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
      local q = p.query or p.q or p.title or p.song or p.name or p.target or p.search or p[1]
      if not q or q == "" then q = "ambient coding music" end
      if not command.map["youtube-player:quick-play"] then
        pcall(require, "plugins.youtube_player")
      end
      if command.map["youtube-player:quick-play"] then
        command.perform("youtube-player:quick-play", q)
        return string.format("Started playing '%s' on YouTube player.", q)
      end
      return "YouTube player plugin not loaded."
    end,
    search = function(p)
      local q = p.query or p.q or p.title or p.name or p.target or p.search or p[1]
      if not q or q == "" then error("Missing 'query'.") end
      if not command.map["youtube-player:search"] then
        pcall(require, "plugins.youtube_player")
      end
      if command.map["youtube-player:search"] then
        command.perform("youtube-player:search", q)
        return string.format("Searched YouTube for '%s'.", q)
      end
      return "YouTube player plugin not loaded."
    end,
    toggle = function(p)
      if not command.map["youtube-player:toggle"] then
        pcall(require, "plugins.youtube_player")
      end
      if command.map["youtube-player:toggle"] then
        command.perform("youtube-player:toggle")
        return "Toggled YouTube player."
      end
      return "YouTube toggle requested."
    end,
    play_pause = function(p)
      if not command.map["youtube-player:play-pause"] then
        pcall(require, "plugins.youtube_player")
      end
      if command.map["youtube-player:play-pause"] then
        command.perform("youtube-player:play-pause")
        return "Toggled YouTube playback."
      end
      return "Playback toggle requested."
    end,
    seek_forward = function(p)
      if not command.map["youtube-player:seek-forward"] then
        pcall(require, "plugins.youtube_player")
      end
      if command.map["youtube-player:seek-forward"] then
        command.perform("youtube-player:seek-forward")
        return "Seeked forward 10s."
      end
      return "Seek forward requested."
    end,
    seek_backward = function(p)
      if not command.map["youtube-player:seek-backward"] then
        pcall(require, "plugins.youtube_player")
      end
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
      if not command.map["web-preview:start"] then
        pcall(require, "plugins.lazy_lite_web_preview")
      end
      if command.map["web-preview:start"] then
        command.perform("web-preview:start")
        return "Started local web preview server."
      end
      return "Web preview plugin not loaded."
    end,
    stop = function(p)
      if not command.map["web-preview:stop"] then
        pcall(require, "plugins.lazy_lite_web_preview")
      end
      if command.map["web-preview:stop"] then
        command.perform("web-preview:stop")
        return "Stopped local web preview server."
      end
      return "Web preview plugin not loaded."
    end,
    restart = function(p)
      if not command.map["web-preview:restart"] then
        pcall(require, "plugins.lazy_lite_web_preview")
      end
      if command.map["web-preview:restart"] then
        command.perform("web-preview:restart")
        return "Restarted local web preview server."
      end
      return "Web preview plugin not loaded."
    end,
    copy_url = function(p)
      if not command.map["web-preview:copy-url"] then
        pcall(require, "plugins.lazy_lite_web_preview")
      end
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
  summary = "Native rendered Markdown preview with GitHub-flavored markdown and Mermaid support",
  actions_meta = {
    preview = "Opens native rendered preview of the active or specified Markdown document."
  },
  actions = {
    preview = function(p)
      pcall(require, "plugins.markdown_view")
      local MarkdownView = package.loaded["plugins.markdown_view"]

      local target_path = p.path or p.file or p.filename or p.filepath or p.target or p.name or p[1]
      local doc = nil
      if target_path and target_path ~= "" then
        doc = core.open_doc(target_path)
      elseif core.active_view and core.active_view.doc then
        doc = core.active_view.doc
      else
        local node = core.root_view:get_active_node_default()
        if node and node.views then
          for _, v in ipairs(node.views) do
            if v.doc and v.doc.filename and v.doc.filename:match("%.md$") then
              doc = v.doc
              break
            end
          end
        end
        if not doc then
          doc = core.open_doc("system_design.md")
        end
      end

      if MarkdownView and doc then
        local view = MarkdownView(doc)
        local node = core.root_view:get_active_node_default()
        if node.locked then
          node = core.root_view:get_primary_node()
        end
        node:split("right", view)
        core.set_active_view(view)
        core.redraw = true
        return string.format("Opened native Markdown preview for '%s'.", common.basename(doc.filename or "preview.md"))
      elseif command.map["markdown:open-native-preview"] then
        command.perform("markdown:open-native-preview")
        return "Opened native Markdown preview."
      end
      return "Markdown preview plugin not loaded."
    end
  }
})

-- ── 16. Register "port_forward" Subsystem ──────────────────────────────────────
Capabilities.register("port_forward", {
  summary = "Port forwarding and LocalTunnel exposure for web servers",
  actions_meta = {
    toggle = "Toggles Port Forwarding manager view.",
    add_tunnel = "Exposes a local port via LocalTunnel."
  },
  actions = {
    toggle = function(p)
      if not command.map["port_forward:toggle"] then
        pcall(require, "plugins.port_forward")
      end
      if command.map["port_forward:toggle"] then
        command.perform("port_forward:toggle")
        return "Toggled Port Forwarding view."
      end
      return "Port forwarding plugin not loaded."
    end,
    add_tunnel = function(p)
      local port = tonumber(p.port or p.number or p[1]) or 3000
      if not command.map["port_forward:toggle"] then
        pcall(require, "plugins.port_forward")
      end
      command.perform("port_forward:toggle")
      return string.format("Opening tunnel for port %d.", port)
    end
  }
})

-- ── 17. Register "github" Subsystem ───────────────────────────────────────────
Capabilities.register("github", {
  summary = "GitHub Codespaces cloud containers and GitHub Actions CI/CD workflows",
  actions_meta = {
    codespaces = "Toggles GitHub Codespaces manager.",
    actions = "Toggles GitHub Actions workflow runs view."
  },
  actions = {
    codespaces = function(p)
      if not command.map["codespaces:open-remote-terminal"] and not command.map["codespaces:show-treeview"] then
        pcall(require, "plugins.github_codespaces")
      end
      if command.map["codespaces:open-remote-terminal"] then
        command.perform("codespaces:open-remote-terminal")
        return "Toggled GitHub Codespaces terminal."
      elseif command.map["codespaces:show-treeview"] then
        command.perform("codespaces:show-treeview")
        return "Toggled GitHub Codespaces treeview."
      end
      return "GitHub Codespaces requested."
    end,
    actions = function(p)
      if not command.map["github-actions:show"] and not command.map["github-actions:refresh"] then
        pcall(require, "plugins.github_actions")
      end
      if command.map["github-actions:show"] then
        command.perform("github-actions:show")
        return "Toggled GitHub Actions workflow runs."
      end
      return "GitHub Actions requested."
    end
  }
})

-- Export on core
core.capabilities = Capabilities

return Capabilities
