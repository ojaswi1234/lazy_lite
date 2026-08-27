-- mod-version:3
-- ai_tool_registry.lua — Registry of known AI CLI tools for the AI sidebar.
-- Research-backed: Aug 2026 · covers agy, opencode, devin, claude, codex, gemini,
-- aider, cline, goose, gh-copilot, amp, cursor-agent, crush, codebuff, kilo,
-- auggie, openhands, hermes, junie, cortex + more.

local process = require "process"

local M = {}

-- ── Parser helpers ────────────────────────────────────────────────────────────
local function parse_plain_models(raw)
  local models, seen = {}, {}
  for line in (raw .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    line = line:match("^%s*(.-)%s*$")
    if #line > 2 and not seen[line]
      and not line:lower():match("^fetching")
      and not line:lower():match("^loading")
      and not line:lower():match("^%-%-%-")
      and not line:lower():match("^session")
      and not line:lower():match("^model")
      and not line:lower():match("%-%-%-%-")
    then
      seen[line] = true
      table.insert(models, { name = line, limited = false })
    end
  end
  return models
end

local function parse_opencode_sessions(raw)
  local sessions = {}
  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    line = line:match("^%s*(.-)%s*$")
    local id, title = line:match("^(ses_%S+)%s+(.*)")
    if id and title then
      local clean = title:match("^(.-)%s+%d+:%d+") or title
      table.insert(sessions, { id = id, title = clean:match("^%s*(.-)%s*$") })
    end
  end
  return sessions
end

local function parse_auggie_sessions(raw)
  local sessions = {}
  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    local id = line:match("^%s*([%w%-_]+)%s*$")
    if id and #id > 4 then
      table.insert(sessions, { id = id, title = id })
    end
  end
  return sessions
end

-- ── OpenCode Windows helper ───────────────────────────────────────────────────
-- Prefers the actual .exe (bypasses PS1 wrapper issues with process.start)
local function oc_argv(bin, args_table)
  -- If we have the .exe directly, call it straight (no PS1 quoting hell)
  local use_bin = bin
  if PLATFORM == "Windows" and bin:lower():match("%.ps1$") then
    -- Try to find the .exe next to the ps1
    local exe = bin:gsub("%.ps1$", "") -- strip .ps1
    -- Common node location
    local npm_dir = (os.getenv("APPDATA") or "") .. "\\npm\\node_modules\\opencode-ai\\bin\\opencode.exe"
    local f = io.open(npm_dir, "r")
    if f then f:close(); use_bin = npm_dir
    else
      -- Fall back: run via cmd.exe /c which handles .ps1 less painfully
      local argv = { "cmd.exe", "/c", bin }
      for _, a in ipairs(args_table) do table.insert(argv, a) end
      return argv
    end
  end
  local argv = { use_bin }
  for _, a in ipairs(args_table) do table.insert(argv, a) end
  return argv
end

-- ── Hardcoded model lists (fallbacks when no `models` CLI cmd) ─────────────────
local HM = {
  devin = {
    { name = "claude-sonnet-4-5", limited = false },
    { name = "claude-sonnet-4",   limited = false },
    { name = "claude-opus-4",     limited = false },
    { name = "claude-opus-4.6",   limited = false },
    { name = "codex",             limited = false },
    { name = "opus",              limited = false },
  },
  agy = {
    { name = "Gemini 3.5 Flash (Medium)",    limited = false },
    { name = "Gemini 3.5 Flash (High)",      limited = false },
    { name = "Gemini 3.1 Pro (High)",        limited = false },
    { name = "Claude Sonnet 4.6 (Thinking)", limited = false },
    { name = "Claude Opus 4.6 (Thinking)",   limited = false },
    { name = "GPT-OSS 120B (Medium)",        limited = false },
  },
  claude = {
    { name = "claude-opus-4-5",   limited = false },
    { name = "claude-sonnet-4-5", limited = false },
    { name = "claude-haiku-3-5",  limited = false },
    { name = "claude-opus-4",     limited = false },
    { name = "claude-sonnet-4",   limited = false },
  },
  codex = {
    { name = "o4-mini",      limited = false },
    { name = "o3",           limited = false },
    { name = "gpt-4.1",      limited = false },
    { name = "gpt-4.1-mini", limited = false },
  },
  gemini = {
    { name = "gemini-2.5-pro",        limited = false },
    { name = "gemini-2.5-flash",      limited = false },
    { name = "gemini-2.5-flash-lite", limited = false },
    { name = "gemini-2.0-flash-exp",  limited = false },
  },
  aider = {
    { name = "gpt-4o",                          limited = false },
    { name = "claude-3-5-sonnet-20241022",       limited = false },
    { name = "deepseek/deepseek-coder",          limited = false },
    { name = "gemini/gemini-2.5-pro",            limited = false },
  },
  cline = {
    { name = "claude-sonnet-4-5",    limited = false },
    { name = "gpt-4o",               limited = false },
    { name = "gemini-2.5-pro",       limited = false },
    { name = "deepseek-v3",          limited = false },
  },
  goose = {
    { name = "claude-3-5-sonnet-20241022", limited = false },
    { name = "gpt-4o",                    limited = false },
    { name = "gemini-2.5-flash",          limited = false },
    { name = "deepseek-v3",               limited = false },
  },
  gh_copilot = {
    { name = "gpt-4.1",           limited = false },
    { name = "gpt-4o",            limited = false },
    { name = "o3",                limited = false },
    { name = "o4-mini",           limited = false },
    { name = "claude-sonnet-4-5", limited = false },
    { name = "gemini-2.5-pro",    limited = false },
  },
  amp = {
    { name = "claude-opus-4-5",   limited = false },
    { name = "claude-sonnet-4-5", limited = false },
    { name = "gpt-4o",            limited = false },
  },
  cursor_agent = {
    { name = "claude-sonnet-4-5", limited = false },
    { name = "gpt-4o",            limited = false },
    { name = "gemini-2.5-pro",    limited = false },
    { name = "cursor-small",      limited = false },
  },
  crush = {
    { name = "claude-opus-4-5",   limited = false },
    { name = "claude-sonnet-4-5", limited = false },
    { name = "gpt-4o",            limited = false },
    { name = "gemini-2.5-flash",  limited = false },
  },
  codebuff = {
    { name = "gpt-4o",                    limited = false },
    { name = "claude-3-5-sonnet-20241022", limited = false },
    { name = "gemini-2.5-pro",            limited = false },
  },
  openhands = {
    { name = "openai/gpt-4o",                    limited = false },
    { name = "anthropic/claude-3-5-sonnet-20241022", limited = false },
    { name = "google/gemini-2.5-pro",            limited = false },
  },
  hermes = {
    { name = "hermes-3-llama-3.1-70b", limited = false },
    { name = "gpt-4o",                 limited = false },
    { name = "claude-sonnet-4",        limited = false },
  },
  junie = {
    { name = "claude-sonnet-4-5",  limited = false },
    { name = "gpt-4o",             limited = false },
    { name = "gemini-2.5-pro",     limited = false },
  },
  cortex = {
    { name = "mistral-large",       limited = false },
    { name = "llama3.3-70b",        limited = false },
    { name = "snowflake-arctic",    limited = false },
  },
  claw = {
    { name = "claude-sonnet-4-5",  limited = false },
    { name = "gpt-4o",             limited = false },
    { name = "gemini-2.5-pro",     limited = false },
  },
}

-- ── Tool Registry ─────────────────────────────────────────────────────────────
-- Field reference:
--   id                  string   unique key used in config
--   name                string   display name in dropdown
--   short               string   badge (≤4 chars) shown in header
--   bins                table    binary names to probe on PATH
--   extra_paths         fn→table platform-specific absolute paths to check first
--   build_run_argv      fn(cfg)  build argv table for a chat run
--   build_models_argv   fn(bin)  argv to list models, or nil
--   parse_models        fn(raw)  parse model list stdout → [{name,limited}]
--   build_sessions_argv fn(bin)  argv to list sessions, or nil
--   parse_sessions      fn(raw)  parse session list → [{id,title}]
--   hardcoded_models    table    shown immediately when no list command
--   needs_pty           bool     true = route through Python PTY bridge
--   session_flag        string   flag used to resume by session id (may be nil)
--   continue_flag       string   flag to continue most-recent session (may be nil)
--   resume_supported    bool     whether /resume should work for this tool

M.REGISTRY = {

  -- ── Cloud APIs (LangChain Bridge) ─────────────────────────────────────────
  {
    id    = "cloud_api",
    name  = "Cloud AI (API)",
    short = "API",
    bins  = { "python", "python.exe", "python3" },
    extra_paths = function() return {} end,
    build_run_argv = function(cfg)
      local bridge = USERDIR .. "/scripts/ai_api_bridge.py"
      local a = { cfg.bin, bridge, "--chat" }
      -- Extract provider from model string (e.g. "gemini/gemini-2.5-pro")
      local provider = "gemini"
      local model_id = cfg.model
      if cfg.model and cfg.model:find("/") then
        provider = cfg.model:match("^(.-)/")
        model_id = cfg.model:match("/(.*)$")
      end
      a[#a+1] = "--provider"; a[#a+1] = provider
      if model_id then a[#a+1] = "--model"; a[#a+1] = model_id end
      
      local config = require "core.config"
      if config.ai_sidebar and config.ai_sidebar.autopilot then
        a[#a+1] = "--autopilot"
      end
      if cfg.enable_tools then
        a[#a+1] = "--enable-tools"
      end
      if config.ai_sidebar and config.ai_sidebar.read_only then
        a[#a+1] = "--read-only"
      end

      local pdir = (require "core").project_dir or (os.getenv("PWD") or os.getenv("CD") or "")
      if pdir ~= "" then
        a[#a+1] = "--workspace"; a[#a+1] = pdir
      end
      
      if cfg.session_id then
        a[#a+1] = "--thread-id"; a[#a+1] = cfg.session_id
      end
      
      local team_cfg = USERDIR .. "/scripts/.team_config.json"
      local tf = io.open(team_cfg, "r")
      if tf then
        tf:close()
        a[#a+1] = "--team-config"; a[#a+1] = team_cfg
      end

      a[#a+1] = "--prompt"; a[#a+1] = cfg.prompt
      return a
    end,
    build_models_argv = function(bin, extra)
      local bridge = USERDIR .. "/scripts/ai_api_bridge.py"
      -- extra can be passed from UI if we select a specific provider
      local provider = (extra and extra.provider) or "all" 
      return { bin, bridge, "--list-models", "--provider", provider }
    end,
    parse_models = function(raw)
      local models = {}
      for line in (raw .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if line:match("^MISSING_API_KEY:(.*)") then
           return { missing_key = line:match("^MISSING_API_KEY:(.*)") }
        end
        line = line:match("^%s*(.-)%s*$")
        if #line > 2 then
          table.insert(models, { name = line, limited = false })
        end
      end
      return models
    end,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = {
      { name = "gemini/gemini-2.5-pro", limited = false },
      { name = "groq/llama3-70b-8192", limited = false },
      { name = "openai/gpt-4o", limited = false },
      { name = "anthropic/claude-3-7-sonnet-20250219", limited = false },
    },
    needs_pty = false,
    session_flag = nil,
    continue_flag = nil,
    resume_supported = false,
  },

  -- ==================================================================================================
  -- Antigravity CLI
  -- ==================================================================================================
  {
    id    = "agy",
    name  = "Antigravity CLI",
    short = "AGY",
    bins  = { "agy", "agy.exe" },
    extra_paths = function()
      local lad  = os.getenv("LOCALAPPDATA") or ""
      local home = os.getenv("HOME") or ""
      return { lad.."/agy/bin/agy.exe", lad.."\\agy\\bin\\agy.exe", home.."/.local/bin/agy" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.session_id then
        a[#a+1]="--conversation"; a[#a+1]=cfg.session_id
      elseif cfg.has_session then
        a[#a+1]="-c"
      end
      if cfg.model then
        -- AGY model list entries are "model-id   Display Name"
        -- Extract just the first token (the actual model ID) for the --model flag
        local model_id = cfg.model:match("^(%S+)") or cfg.model
        a[#a+1]="--model"; a[#a+1]=model_id
      end
      a[#a+1]="-p"; a[#a+1]=cfg.prompt
      if cfg.project_dir and #cfg.project_dir>0 then
        a[#a+1]="--add-dir"; a[#a+1]=cfg.project_dir
      end
      a[#a+1]="--dangerously-skip-permissions"
      return a
    end,
    build_models_argv = function(bin) return { bin, "models" } end,
    parse_models = nil,           -- uses parse_pty_model_list in sidebar
    build_sessions_argv = nil,    -- uses AGY brain dir scan
    parse_sessions = nil,
    hardcoded_models = HM.agy,
    needs_pty = true,
    session_flag = "--conversation",
    continue_flag = "-c",
    resume_supported = true,
  },

  -- ── OpenCode ────────────────────────────────────────────────────────────────
  {
    id    = "opencode",
    name  = "OpenCode",
    short = "OC",
    bins  = { "opencode", "opencode.exe", "opencode.ps1", "opencode.cmd" },
    extra_paths = function()
      local apd = os.getenv("APPDATA") or ""
      return {
        -- Prefer the actual .exe (avoids PS1 wrapper issues)
        apd .. "\\npm\\node_modules\\opencode-ai\\bin\\opencode.exe",
        apd .. "/npm/node_modules/opencode-ai/bin/opencode.exe",
        apd .. "\\npm\\opencode.ps1",
        apd .. "/npm/opencode.ps1",
      }
    end,
    build_run_argv = function(cfg)
      local args = { "run" }
      if cfg.session_id then
        args[#args+1]="--session"; args[#args+1]=cfg.session_id
      elseif cfg.has_session then
        args[#args+1]="--continue"
      end
      if cfg.model then
        args[#args+1]="--model"; args[#args+1]=cfg.model
      end
      if cfg.project_dir and #cfg.project_dir>0 then
        args[#args+1]="--dir"; args[#args+1]=cfg.project_dir
      end
      if cfg.extra_files then
        for _, f in ipairs(cfg.extra_files) do
          args[#args+1]="--file"; args[#args+1]=f
        end
      end
      -- Output format: default gives human-readable streamed text
      args[#args+1]="--format"; args[#args+1]="default"
      args[#args+1]=cfg.prompt
      return oc_argv(cfg.bin, args)
    end,
    build_models_argv = function(bin) return oc_argv(bin, { "models" }) end,
    parse_models = parse_plain_models,
    build_usage_argv = function(bin) return oc_argv(bin, { "stats" }) end,
    build_sessions_argv = function(bin) return oc_argv(bin, { "session", "list" }) end,
    parse_sessions = parse_opencode_sessions,
    hardcoded_models = nil,
    needs_pty = false,
    session_flag = "--session",
    continue_flag = "--continue",
    resume_supported = true,
  },

  -- ── Devin CLI ───────────────────────────────────────────────────────────────
  {
    id    = "devin",
    name  = "Devin CLI",
    short = "DEV",
    bins  = { "devin", "devin.exe" },
    extra_paths = function()
      local lad  = os.getenv("LOCALAPPDATA") or ""
      local home = os.getenv("HOME") or ""
      return { lad.."/devin/cli/bin/devin.exe", lad.."\\devin\\cli\\bin\\devin.exe", home.."/.local/bin/devin" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.session_id then
        a[#a+1]="--resume"; a[#a+1]=cfg.session_id
      elseif cfg.has_session then
        a[#a+1]="--continue"
      end
      if cfg.model then a[#a+1]="--model"; a[#a+1]=cfg.model end
      a[#a+1]="--permission-mode"; a[#a+1]="dangerous"
      a[#a+1]="--print"; a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_usage_argv = function(bin) return { bin, "auth", "status" } end,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.devin,
    needs_pty = false,
    session_flag = "--resume",
    continue_flag = "--continue",
    resume_supported = false,  -- devin list is TUI; no programmatic session list
  },

  -- ── Claude Code ─────────────────────────────────────────────────────────────
  {
    id    = "claude",
    name  = "Claude Code",
    short = "CL",
    bins  = { "claude" },
    extra_paths = function()
      local apd  = os.getenv("APPDATA") or ""
      local home = os.getenv("HOME") or ""
      return { apd.."/npm/claude", home.."/.local/bin/claude", "/usr/local/bin/claude" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.session_id then
        a[#a+1]="--resume"; a[#a+1]=cfg.session_id
      elseif cfg.has_session then
        a[#a+1]="--continue"
      end
      if cfg.model then a[#a+1]="--model"; a[#a+1]=cfg.model end
      a[#a+1]="--dangerously-skip-permissions"
      a[#a+1]="-p"; a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.claude,
    needs_pty = false,
    session_flag = "--resume",
    continue_flag = "--continue",
    resume_supported = false,  -- sessions stored in ~/.claude/projects/<hash>/*.jsonl; no list cmd
  },

  -- ── OpenAI Codex CLI ────────────────────────────────────────────────────────
  {
    id    = "codex",
    name  = "Codex CLI",
    short = "CDX",
    bins  = { "codex" },
    extra_paths = function()
      local apd  = os.getenv("APPDATA") or ""
      local home = os.getenv("HOME") or ""
      return { apd.."/npm/codex", home.."/.local/bin/codex", "/usr/local/bin/codex" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.model then a[#a+1]="--model"; a[#a+1]=cfg.model end
      a[#a+1]="-p"; a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.codex,
    needs_pty = false,
    session_flag = nil,
    continue_flag = nil,
    resume_supported = false,
  },

  -- ── Gemini CLI ──────────────────────────────────────────────────────────────
  {
    id    = "gemini",
    name  = "Gemini CLI",
    short = "GEM",
    bins  = { "gemini" },
    extra_paths = function()
      local apd  = os.getenv("APPDATA") or ""
      local home = os.getenv("HOME") or ""
      return { apd.."/npm/gemini", home.."/.local/bin/gemini", "/usr/local/bin/gemini" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.model then a[#a+1]="--model"; a[#a+1]=cfg.model end
      a[#a+1]="-p"; a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = function(bin) return { bin, "models", "list" } end,
    parse_models = parse_plain_models,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.gemini,
    needs_pty = false,
    session_flag = nil,
    continue_flag = nil,
    resume_supported = false,
  },

  -- ── Aider ───────────────────────────────────────────────────────────────────
  {
    id    = "aider",
    name  = "Aider",
    short = "AID",
    bins  = { "aider" },
    extra_paths = function()
      local home = os.getenv("HOME") or ""
      return { home.."/.local/bin/aider", "/usr/local/bin/aider" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.model then a[#a+1]="--model"; a[#a+1]=cfg.model end
      a[#a+1]="--yes-always"; a[#a+1]="--no-auto-commits"
      a[#a+1]="--message"; a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.aider,
    needs_pty = false,
    session_flag = nil,
    continue_flag = "--restore-chat-history",
    resume_supported = false,
  },

  -- ── Cline ───────────────────────────────────────────────────────────────────
  {
    id    = "cline",
    name  = "Cline",
    short = "CLN",
    bins  = { "cline" },
    extra_paths = function()
      local apd  = os.getenv("APPDATA") or ""
      local home = os.getenv("HOME") or ""
      return { apd.."/npm/cline", home.."/.local/bin/cline", "/usr/local/bin/cline" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.model then a[#a+1]="-m"; a[#a+1]=cfg.model end
      a[#a+1]="--yolo"
      a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.cline,
    needs_pty = false,
    session_flag = nil,
    continue_flag = nil,
    resume_supported = false,
  },

  -- ── Goose ───────────────────────────────────────────────────────────────────
  {
    id    = "goose",
    name  = "Goose",
    short = "GOS",
    bins  = { "goose" },
    extra_paths = function()
      local home = os.getenv("HOME") or ""
      return { home.."/.local/bin/goose", "/usr/local/bin/goose" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin, "run" }
      if cfg.model then
        -- Goose uses GOOSE_MODEL env var; pass as env prefix is not possible via process.start
        -- so we inject it via --with-extension flag if supported, else skip
        a[#a+1]="--model"; a[#a+1]=cfg.model
      end
      a[#a+1]="--text"; a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.goose,
    needs_pty = false,
    session_flag = nil,
    continue_flag = nil,
    resume_supported = false,
  },

  -- ── GitHub Copilot CLI ──────────────────────────────────────────────────────
  -- Non-interactive: gh copilot -- -p "prompt" --allow-all-tools
  -- Resume session:  gh copilot -- --resume=<id> -p "prompt" --allow-all-tools
  {
    id    = "gh_copilot",
    name  = "GitHub Copilot",
    short = "GH",
    bins  = { "gh" },
    extra_paths = function()
      local lad  = os.getenv("LOCALAPPDATA") or ""
      local home = os.getenv("HOME") or ""
      return {
        "C:\\Program Files\\GitHub CLI\\gh.exe",
        lad .. "\\GitHub CLI\\gh.exe",
        home .. "/.local/bin/gh",
        "/usr/local/bin/gh",
      }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin, "copilot", "--" }
      if cfg.session_id then
        a[#a+1] = "--resume=" .. cfg.session_id
      end
      if cfg.model and cfg.model ~= "" then
        a[#a+1] = "--model"; a[#a+1] = cfg.model
      end
      if cfg.project_dir and #cfg.project_dir > 0 then
        a[#a+1] = "--add-dir"; a[#a+1] = cfg.project_dir
      end
      a[#a+1] = "-p"; a[#a+1] = cfg.prompt
      a[#a+1] = "--allow-all-tools"
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.gh_copilot,
    needs_pty = false,
    session_flag = nil,
    continue_flag = nil,
    resume_supported = true,
  },

  -- ── Amp ─────────────────────────────────────────────────────────────────────
  {
    id    = "amp",
    name  = "Amp",
    short = "AMP",
    bins  = { "amp" },
    extra_paths = function()
      local apd  = os.getenv("APPDATA") or ""
      local home = os.getenv("HOME") or ""
      return { apd.."/npm/amp", home.."/.local/bin/amp", "/usr/local/bin/amp" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin, "-x", cfg.prompt }
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.amp,
    needs_pty = false,
    session_flag = nil,
    continue_flag = nil,
    resume_supported = false,
  },

  -- ── Cursor Agent ────────────────────────────────────────────────────────────
  {
    id    = "cursor_agent",
    name  = "Cursor Agent",
    short = "CSR",
    bins  = { "cursor-agent" },
    extra_paths = function()
      local home = os.getenv("HOME") or ""
      return { home.."/.local/bin/cursor-agent", "/usr/local/bin/cursor-agent" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.model then a[#a+1]="--model"; a[#a+1]=cfg.model end
      if cfg.session_id then a[#a+1]="--resume"; a[#a+1]=cfg.session_id end
      a[#a+1]="-p"; a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = function(bin) return { bin, "--list-models" } end,
    parse_models = parse_plain_models,
    build_sessions_argv = function(bin) return { bin, "ls" } end,
    parse_sessions = nil,
    hardcoded_models = HM.cursor_agent,
    needs_pty = false,
    session_flag = "--resume",
    continue_flag = nil,
    resume_supported = false,
  },

  -- ── Crush ───────────────────────────────────────────────────────────────────
  {
    id    = "crush",
    name  = "Crush",
    short = "CRU",
    bins  = { "crush" },
    extra_paths = function()
      local home = os.getenv("HOME") or ""
      return { home.."/.local/bin/crush", "/usr/local/bin/crush" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.model then a[#a+1]="--model"; a[#a+1]=cfg.model end
      a[#a+1]="--yolo"
      a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.crush,
    needs_pty = false,
    session_flag = nil,
    continue_flag = nil,
    resume_supported = false,
  },

  -- ── Codebuff ────────────────────────────────────────────────────────────────
  {
    id    = "codebuff",
    name  = "Codebuff",
    short = "CBF",
    bins  = { "codebuff" },
    extra_paths = function()
      local apd  = os.getenv("APPDATA") or ""
      local home = os.getenv("HOME") or ""
      return { apd.."/npm/codebuff", home.."/.local/bin/codebuff", "/usr/local/bin/codebuff" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin, cfg.prompt }
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.codebuff,
    needs_pty = false,
    session_flag = nil,
    continue_flag = nil,
    resume_supported = false,
  },

  -- ── Kilo Code ───────────────────────────────────────────────────────────────
  {
    id    = "kilo",
    name  = "Kilo Code",
    short = "KLO",
    bins  = { "kilo" },
    extra_paths = function()
      local apd  = os.getenv("APPDATA") or ""
      local home = os.getenv("HOME") or ""
      return { apd.."/npm/kilo", home.."/.local/bin/kilo", "/usr/local/bin/kilo" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin, "run" }
      if cfg.has_session or cfg.session_id then
        if cfg.session_id then
          a[#a+1]="--session"; a[#a+1]=cfg.session_id
        else
          a[#a+1]="--continue"
        end
      end
      a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = function(bin) return { bin, "models" } end,
    parse_models = parse_plain_models,
    build_sessions_argv = function(bin) return { bin, "session", "list" } end,
    parse_sessions = parse_opencode_sessions,
    hardcoded_models = nil,
    needs_pty = false,
    session_flag = "--session",
    continue_flag = "--continue",
    resume_supported = false,
  },

  -- ── Auggie CLI ──────────────────────────────────────────────────────────────
  {
    id    = "auggie",
    name  = "Auggie",
    short = "AUG",
    bins  = { "auggie" },
    extra_paths = function()
      local apd  = os.getenv("APPDATA") or ""
      local home = os.getenv("HOME") or ""
      return { apd.."/npm/auggie", home.."/.local/bin/auggie", "/usr/local/bin/auggie" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.session_id then
        a[#a+1]="session"; a[#a+1]="resume"; a[#a+1]=cfg.session_id
      end
      if not cfg.session_id then
        a[#a+1]="--print"; a[#a+1]=cfg.prompt
      end
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = function(bin) return { bin, "session", "list" } end,
    parse_sessions = parse_auggie_sessions,
    hardcoded_models = HM.junie,
    needs_pty = false,
    session_flag = "session resume",
    continue_flag = nil,
    resume_supported = false,
  },

  -- ── OpenHands ───────────────────────────────────────────────────────────────
  {
    id    = "openhands",
    name  = "OpenHands",
    short = "OHA",
    bins  = { "openhands" },
    extra_paths = function()
      local home = os.getenv("HOME") or ""
      return { home.."/.local/bin/openhands", "/usr/local/bin/openhands" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.model then
        -- OpenHands uses LLM_MODEL env var, but also --model flag
        a[#a+1]="--model"; a[#a+1]=cfg.model
      end
      a[#a+1]="-t"; a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.openhands,
    needs_pty = false,
    session_flag = nil,
    continue_flag = nil,
    resume_supported = false,
  },

  -- ── Hermes Agent ────────────────────────────────────────────────────────────
  {
    id    = "hermes",
    name  = "Hermes Agent",
    short = "HRM",
    bins  = { "hermes" },
    extra_paths = function()
      local home = os.getenv("HOME") or ""
      return { home.."/.local/bin/hermes", "/usr/local/bin/hermes" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin, "chat", "send", cfg.prompt }
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.hermes,
    needs_pty = false,
    session_flag = nil,
    continue_flag = nil,
    resume_supported = false,
  },

  -- ── Junie CLI ───────────────────────────────────────────────────────────────
  {
    id    = "junie",
    name  = "Junie CLI",
    short = "JUN",
    bins  = { "junie" },
    extra_paths = function()
      local apd  = os.getenv("APPDATA") or ""
      local home = os.getenv("HOME") or ""
      return { apd.."/npm/junie", home.."/.local/bin/junie", "/usr/local/bin/junie" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.model then a[#a+1]="--model"; a[#a+1]=cfg.model end
      a[#a+1]="-p"; a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.junie,
    needs_pty = false,
    session_flag = nil,
    continue_flag = nil,
    resume_supported = false,
  },

  -- ── Cortex Code CLI ─────────────────────────────────────────────────────────
  {
    id    = "cortex",
    name  = "Cortex CLI",
    short = "CTX",
    bins  = { "cortex" },
    extra_paths = function()
      local home = os.getenv("HOME") or ""
      return { home.."/.local/bin/cortex", "/usr/local/bin/cortex" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.model then a[#a+1]="--model"; a[#a+1]=cfg.model end
      if cfg.session_id then a[#a+1]="-r"; a[#a+1]=cfg.session_id
      elseif cfg.has_session then a[#a+1]="--continue" end
      a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.cortex,
    needs_pty = false,
    session_flag = "-r",
    continue_flag = "--continue",
    resume_supported = false,
  },

  -- ── Claw Code ───────────────────────────────────────────────────────────────
  {
    id    = "claw",
    name  = "Claw Code",
    short = "CLW",
    bins  = { "claw" },
    extra_paths = function()
      local home = os.getenv("HOME") or ""
      return { home.."/.local/bin/claw", "/usr/local/bin/claw" }
    end,
    build_run_argv = function(cfg)
      local a = { cfg.bin }
      if cfg.model then a[#a+1]="--model"; a[#a+1]=cfg.model end
      if cfg.session_id then a[#a+1]="--session"; a[#a+1]=cfg.session_id
      elseif cfg.has_session then a[#a+1]="--resume" end
      a[#a+1]="--dangerously-skip-permissions"
      a[#a+1]="-p"; a[#a+1]=cfg.prompt
      return a
    end,
    build_models_argv = nil,
    parse_models = nil,
    build_sessions_argv = nil,
    parse_sessions = nil,
    hardcoded_models = HM.claw,
    needs_pty = false,
    session_flag = "--session",
    continue_flag = "--resume",
    resume_supported = false,
  },
}

-- ── Detection (must be called inside a coroutine) ─────────────────────────────
function M.detect_all()
  local found = {}
  for _, tool in ipairs(M.REGISTRY) do
    local bin_path = nil

    -- Check extra_paths first (no subprocess)
    local paths = type(tool.extra_paths) == "function" and tool.extra_paths() or {}
    for _, p in ipairs(paths) do
      local f = io.open(p, "rb")
      if f then f:close(); bin_path = p; break end
    end

    -- Try PATH
    if not bin_path then
      for _, name in ipairs(tool.bins) do
        local cmd = PLATFORM == "Windows" and { "where.exe", name } or { "which", name }
        local ok, p2 = pcall(process.start, cmd, {
          stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE
        })
        if ok and p2 then
          coroutine.yield(0.05)
          local out = ""
          for _ = 1, 30 do
            local chunk = p2:read_stdout(512)
            if chunk and #chunk > 0 then out = out .. chunk end
            if p2:returncode() ~= nil then break end
            coroutine.yield(0.02)
          end
          local line = out:match("^([^\r\n]+)")
          if line then bin_path = line:match("^%s*(.-)%s*$"); break end
        end
      end
    end

    if bin_path and #bin_path > 0 then
      found[tool.id] = { bin = bin_path }
    end
  end
  return found
end

-- Get tool definition by id
function M.get(id)
  for _, t in ipairs(M.REGISTRY) do
    if t.id == id then return t end
  end
  return nil
end

-- Get ordered list of only the detected tools
function M.get_detected(detected_map)
  local list = {}
  for _, tool in ipairs(M.REGISTRY) do
    if detected_map and detected_map[tool.id] then
      table.insert(list, {
        id    = tool.id,
        name  = tool.name,
        short = tool.short,
        bin   = detected_map[tool.id].bin,
      })
    end
  end
  return list
end

return M
