-- mod-version:3
-- AI Plugin Generator — Generate Lite XL plugins from natural language.
-- Adds an "AI Plugins" tab to Settings (between Keybindings and About).
-- Powered by the AGY CLI with full plan → build → auto-heal pipeline.

local core    = require "core"
local config  = require "core.config"
local style   = require "core.style"
local command = require "core.command"
local keymap  = require "core.keymap"
local system  = require "system"
local process = require "process"
local View    = require "core.view"
local Doc     = require "core.doc"
local DocView = require "core.docview"

-- ── Constants ─────────────────────────────────────────────────────────────────
local PLUGIN_DIR = USERDIR .. PATHSEP .. "plugins"
local STORE_FILE = USERDIR .. PATHSEP .. "ai_plugin_gen_store.lua"
local TEMP_DIR   = USERDIR .. PATHSEP .. "tempfiles"
local PAD        = 14  -- logical pixels (will be scaled)

local STATE = {
  DESCRIBE  = "describe",
  LOADING   = "loading",
  PLAN      = "plan",
  BUILDING  = "building",
  SUCCESS   = "success",
  ERROR     = "error",
}

local PLAN_STEPS = {
  "Parsing your description",
  "Web research & reasoning",
  "Analyzing Lite XL API surface",
  "Checking keybinding conflicts",
  "Designing sample UI preview",
  "Calculating complexity & risks",
  "Writing the full plan",
}

local BUILD_STEPS = {
  "Approving plan",
  "Generating plugin code via AGY",
  "Writing file to disk",
  "Running auto-healer validation",
  "Reloading editor plugins",
}

-- Global signals for auto-healer integration
if global then
  global {
    ai_plugin_gen_resume_fn = false,
    auto_healer_new_plugins = rawget(_G, "auto_healer_new_plugins") or {},
  }
else
  rawset(_G, "ai_plugin_gen_resume_fn", false)
  rawset(_G, "auto_healer_new_plugins", rawget(_G, "auto_healer_new_plugins") or {})
end

local function set_global_resume_fn(fn)
  if global then
    global { ai_plugin_gen_resume_fn = fn }
  else
    rawset(_G, "ai_plugin_gen_resume_fn", fn)
  end
end

-- ── Persistent store ──────────────────────────────────────────────────────────
local store = {
  installed       = {},
  rejected_hashes = {},
  engine          = "cloud_api",
  cloud_provider  = "groq",
  cloud_model     = "groq/openai/gpt-oss-120b",
  agy_model       = "Default"
}

local function save_store()
  local fp = io.open(STORE_FILE, "w")
  if not fp then return end
  fp:write("return {\n")
  fp:write(string.format("  engine = %q,\n  cloud_provider = %q,\n  cloud_model = %q,\n  agy_model = %q,\n",
    store.engine or "cloud_api",
    store.cloud_provider or "groq",
    store.cloud_model or "groq/openai/gpt-oss-120b",
    store.agy_model or "Default"))
  fp:write("  installed = {\n")
  for _, p in ipairs(store.installed) do
    fp:write(("    {name=%q,file=%q,desc=%q,ts=%d},\n"):format(
      p.name or "", p.file or "", p.desc or "", p.ts or 0))
  end
  fp:write("  },\n  rejected_hashes = {\n")
  for h in pairs(store.rejected_hashes) do
    fp:write(("    [%q]=true,\n"):format(h))
  end
  fp:write("  }\n}\n")
  fp:close()
end

local function load_store()
  local fp = io.open(STORE_FILE, "r"); if not fp then return end
  local src = fp:read("*a"); fp:close()
  local ok, fn = pcall(load, src)
  if ok and fn then
    local ok2, r = pcall(fn)
    if ok2 and r then
      store.installed       = r.installed       or {}
      store.rejected_hashes = r.rejected_hashes or {}
      store.engine          = r.engine          or "cloud_api"
      store.cloud_provider  = r.cloud_provider  or "groq"
      store.cloud_model     = r.cloud_model     or "groq/openai/gpt-oss-120b"
      store.agy_model       = r.agy_model       or "Default"
    end
  end
end
load_store()

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function agy_path()
  return (config.antigravity and config.antigravity.cli) or "agy"
end

local function simple_hash(s)
  local h = 5381
  for i = 1, #s do h = ((h * 33) ~ s:byte(i)) % 0x7fffffff end
  return tostring(h)
end

local function ensure_tempdir()
  if not system.get_file_info(TEMP_DIR) then
    system.mkdir(TEMP_DIR)
  end
end

local function c(r, g, b, a) return {r, g, b, a or 255} end

local function lerp_color(a, b, t)
  return { math.floor(a[1]+(b[1]-a[1])*t), math.floor(a[2]+(b[2]-a[2])*t),
           math.floor(a[3]+(b[3]-a[3])*t), 255 }
end

local function wrap_text(font, text, max_w)
  local lines = {}
  max_w = math.max(max_w or 100, 40)
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    if raw == "" then
      table.insert(lines, "")
    else
      local cur = ""
      for word in raw:gmatch("%S+") do
        if font:get_width(word) > max_w then
          if cur ~= "" then
            table.insert(lines, cur)
            cur = ""
          end
          local chunk = ""
          for char in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            if font:get_width(chunk .. char) > max_w then
              if #chunk > 0 then table.insert(lines, chunk) end
              chunk = char
            else
              chunk = chunk .. char
            end
          end
          cur = chunk
        else
          local test = cur == "" and word or (cur .. " " .. word)
          if font:get_width(test) <= max_w then
            cur = test
          else
            if cur ~= "" then table.insert(lines, cur) end
            cur = word
          end
        end
      end
      if cur ~= "" then table.insert(lines, cur) end
    end
  end
  return lines
end

local function generate_uuid()
  local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  return string.gsub(template, '[xy]', function (c)
    local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format('%x', v)
  end)
end

local function sp(n) return math.floor(n * SCALE) end

local function get_icon_text_width(font, text)
  local first = text:match("^([%z\1-\127\194-\244][\128-\191]*)")
  if first and #first > 1 then
    local rest = text:sub(#first + 1):match("^%s*(.-)$")
    local iw = style.icon_font:get_width(first)
    if rest ~= "" then
      return iw + (8 * SCALE) + font:get_width(rest)
    end
    return iw
  end
  return font:get_width(text)
end

local function draw_icon_text(font, text, x, y, color)
  local first = text:match("^([%z\1-\127\194-\244][\128-\191]*)")
  if first and #first > 1 then
    local iw = style.icon_font:get_width(first)
    renderer.draw_text(style.icon_font, first, x, y, color)
    local rest = text:sub(#first + 1):match("^%s*(.-)$")
    if rest ~= "" then
      renderer.draw_text(font, rest, x + iw + (8 * SCALE), y, color)
    end
  else
    renderer.draw_text(font, text, x, y, color)
  end
end

local function draw_btn(x, y, w, h, label, hov, col)
  local bg = hov and (col or style.accent) or (style.background2 or c(55,55,55))
  local fg = hov and c(255,255,255) or style.text
  renderer.draw_rect(x, y, w, h, bg)
  -- subtle border
  renderer.draw_rect(x, y, w, 1, style.divider or c(90,90,90))
  renderer.draw_rect(x, y+h-1, w, 1, style.divider or c(90,90,90))
  local tw = get_icon_text_width(style.font, label)
  local fh = style.font:get_height()
  draw_icon_text(style.font, label, x+(w-tw)/2, y+(h-fh)/2, fg)
end

-- ── AI output parser ──────────────────────────────────────────────────────────
local function etag(text, tag)
  local block = text:match("%[" .. tag .. "%]\n?(.-)\n?%[/" .. tag .. "%]")
  if block then return block:match("^%s*(.-)%s*$") end
  return text:match("%[" .. tag .. "%][ \t]*([^\n]*)")
end

local function split_bullets(s)
  if not s or s == "" then return {} end
  local t = {}
  for ln in (s.."\n"):gmatch("([^\n]+)") do
    ln = ln:gsub("^[%-%*%•%d%.%)%]%s]+",""):match("^%s*(.-)%s*$")
    if #ln > 2 then table.insert(t, ln) end
  end
  return t
end

local function parse_plan(text)
  local sc_raw = etag(text,"SHORTCUTS") or ""
  local shortcuts = {}
  for ln in (sc_raw.."\n"):gmatch("([^\n]+)") do
    local k,d = ln:match("^([^:]+):%s*(.+)$")
    if k then table.insert(shortcuts,{key=k:match("^%s*(.-)%s*$"),desc=d}) end
  end
  local hooks={};  for h in (etag(text,"HOOKS") or ""):gmatch("[^,\n]+") do local t=h:match("^%s*(.-)%s*$"); if #t>0 then table.insert(hooks,t) end end
  local files={};  for f in (etag(text,"OUTPUT_FILES") or ""):gmatch("[^,\n]+") do local t=f:match("^%s*(.-)%s*$"); if #t>0 then table.insert(files,t) end end
  return {
    name       = etag(text,"NAME") or "unnamed_plugin",
    overview   = etag(text,"OVERVIEW") or "",
    complexity = tonumber((etag(text,"COMPLEXITY") or "5"):match("%d+")) or 5,
    time_est   = etag(text,"TIME") or "Unknown",
    worth      = etag(text,"WORTH") or "Situational",
    deps       = etag(text,"DEPENDENCIES") or "None",
    research   = split_bullets(etag(text,"RESEARCH")),
    fatal      = split_bullets(etag(text,"CHALLENGES_FATAL")),
    conquer    = split_bullets(etag(text,"CHALLENGES_CONQUER")),
    easy       = split_bullets(etag(text,"CHALLENGES_EASY")),
    design     = etag(text,"DESIGN") or "",
    shortcuts  = shortcuts,
    hooks      = hooks,
    testing    = split_bullets(etag(text,"TESTING")),
    edge_cases = split_bullets(etag(text,"EDGE_CASES")),
    files      = files,
    github_repos = split_bullets(etag(text,"GITHUB_REPOS")),
    integration = etag(text,"INTEGRATION") or "Independent Plugin",
    raw        = text,
  }
end

-- ── Model Catalogs & Helpers ──────────────────────────────────────────────────
local DEFAULT_CLOUD_MODELS = {
  groq = {
    "groq/openai/gpt-oss-120b",
    "groq/openai/gpt-oss-20b",
    "groq/qwen/qwen3.8-27b",
    "groq/openai/gpt-oss-safeguard-20b",
  },
  nvidia = {
    "nvidia/nvidia/nemotron-3.5-bolt-e4b",
    "nvidia/nvidia/nemotron-3.5-lightning-30b-a3b",
    "nvidia/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
    "nvidia/nvidia/nemotron-3-ultra-550b-a55b",
    "nvidia/stepfun-ai/step-5-preview",
    "nvidia/minimaxai/minimax-m3.1-flash",
    "nvidia/poolside/laguna-xs-2.1",
  },
  ollama = {
    "ollama/llama3.3",
    "ollama/qwen2.5-coder",
    "ollama/deepseek-r1",
  },
  gemini = {
    "gemini/gemini-2.5-pro",
    "gemini/gemini-2.5-flash",
  },
  openai = {
    "openai/gpt-4o",
    "openai/gpt-4o-mini",
    "openai/o3-mini",
  },
  anthropic = {
    "anthropic/claude-3-7-sonnet",
    "anthropic/claude-3-5-haiku",
  }
}

local AGY_MODELS = {
  "Default",
  "Gemini 3.8 Flash (High)",
  "Gemini 3.8 Flash (Medium)",
  "Gemini 3.8 Flash (Low)",
  "Claude Sonnet 4.6 (Thinking)",
  "Claude Opus 4.6 (Thinking)",
  "GPT-OSS 120B (Medium)",
}

local _cloud_models_cache = {}
local _cloud_models_fetching = false

local function get_configured_providers()
  local providers = { "groq", "nvidia", "ollama", "gemini", "openai", "anthropic", "deepseek", "openrouter" }
  local configured = {}
  local k_path = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "ai_api_keys.json"
  local f = io.open(k_path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    for _, prov in ipairs(providers) do
      if content:find('"' .. prov .. '":%s*"[^"]+"') then
        table.insert(configured, prov)
      end
    end
  end
  if #configured == 0 then
    return { "groq", "nvidia", "ollama", "gemini" }
  end
  return configured
end

local function fetch_cloud_models(provider, callback)
  local prov = provider or "groq"
  if _cloud_models_cache[prov] and #_cloud_models_cache[prov] > 0 then
    if callback then callback(_cloud_models_cache[prov]) end
    return _cloud_models_cache[prov]
  end
  if _cloud_models_fetching then
    return DEFAULT_CLOUD_MODELS[prov] or {}
  end
  _cloud_models_fetching = true

  local bridge = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "ai_api_bridge.py"
  core.add_thread(function()
    local p = process.start({ "python", bridge, "--list-models", "--provider", prov }, {
      stdin  = process.REDIRECT_DISCARD,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
    })
    if not p then
      _cloud_models_fetching = false
      return
    end
    local out = ""
    while p:returncode() == nil do
      local ch = p:read_stdout(4096) or ""
      if #ch > 0 then out = out .. ch end
      coroutine.yield(0.1)
    end
    while true do
      local ch = p:read_stdout(4096) or ""
      if ch == "" then break end
      out = out .. ch
    end
    _cloud_models_fetching = false

    local list = {}
    for line in out:gmatch("[^\r\n]+") do
      line = line:match("^%s*(.-)%s*$")
      if line ~= "" and not line:match("^MISSING_API_KEY") and not line:match("^Fetching") then
        table.insert(list, line)
      end
    end
    if #list > 0 then
      _cloud_models_cache[prov] = list
      if callback then callback(list) end
      core.redraw = true
    else
      _cloud_models_cache[prov] = DEFAULT_CLOUD_MODELS[prov] or {}
    end
  end)
  return DEFAULT_CLOUD_MODELS[prov] or {}
end

-- ── AGY runner ────────────────────────────────────────────────────────────────
local function run_agy(prompt, conv_id, model_name, on_done)
  ensure_tempdir()
  -- Write prompt to temp file to avoid shell argument length limits and character splitting
  local tmp = TEMP_DIR .. PATHSEP .. "ai_plugin_gen_prompt.txt"
  local fp  = io.open(tmp, "w")
  if fp then fp:write(prompt); fp:close() end

  local runner = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "run_agy_prompt.py"
  local args = { "python", runner, agy_path(), tmp }
  if conv_id and conv_id ~= "" then
    table.insert(args, "--conversation")
    table.insert(args, conv_id)
  end
  if model_name and model_name ~= "" and model_name ~= "Default" then
    table.insert(args, "--model")
    table.insert(args, model_name)
  end

  local p, err = process.start(
    args,
    { stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_PIPE, stderr=process.REDIRECT_PIPE }
  )
  if not p then on_done(nil, "Failed to start agy runner: " .. tostring(err)); return end

  local buf = ""
  local err_buf = ""
  core.add_thread(function()
    local deadline = system.get_time() + 240
    while p:returncode() == nil do
      local ch = p:read_stdout(4096) or ""
      if #ch > 0 then buf = buf .. ch end
      local ech = p:read_stderr(4096) or ""
      if #ech > 0 then err_buf = err_buf .. ech end
      if system.get_time() > deadline then
        pcall(function() p:kill() end)
        on_done(nil, "AGY timed out after 4 minutes"); return
      end
      coroutine.yield(0.1)
    end
    while true do local c2 = p:read_stdout(4096) or ""; if c2 == "" then break end; buf = buf .. c2 end
    while true do local e2 = p:read_stderr(4096) or ""; if e2 == "" then break end; err_buf = err_buf .. e2 end
    
    local rc = p:returncode() or 0
    if rc ~= 0 then
      local emsg = (err_buf ~= "" and err_buf) or (buf ~= "" and buf) or ("AGY exited with code " .. tostring(rc))
      on_done(nil, emsg)
    elseif #buf == 0 then
      local emsg = (err_buf ~= "" and err_buf) or "AGY returned no output"
      on_done(nil, emsg)
    else
      on_done(buf, nil)
    end
  end)
  return p
end

-- ── Cloud API runner ──────────────────────────────────────────────────────────
local function run_cloud_api(prompt, provider, model_id, on_done)
  ensure_tempdir()
  local tmp = TEMP_DIR .. PATHSEP .. "ai_plugin_gen_prompt.txt"
  local fp  = io.open(tmp, "w")
  if fp then fp:write(prompt); fp:close() end

  local bridge = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "ai_api_bridge.py"
  local args = { "python", bridge, "--chat", "--disable-tools", "--prompt-file", tmp }
  
  local prov = provider or "groq"
  local mod  = model_id or "groq/openai/gpt-oss-120b"
  if mod:find("/") then
    local p_pref, m_sub = mod:match("^(.-)/(.*)$")
    if p_pref and p_pref ~= "" then prov = p_pref end
    if m_sub and m_sub ~= "" then mod = m_sub end
  end
  table.insert(args, "--provider")
  table.insert(args, prov)
  table.insert(args, "--model")
  table.insert(args, mod)

  local p, err = process.start(
    args,
    { stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_PIPE, stderr=process.REDIRECT_PIPE }
  )
  if not p then on_done(nil, "Failed to start Cloud AI bridge: " .. tostring(err)); return end

  local buf = ""
  local err_buf = ""
  core.add_thread(function()
    local deadline = system.get_time() + 240
    while p:returncode() == nil do
      local ch = p:read_stdout(4096) or ""
      if #ch > 0 then buf = buf .. ch end
      local ech = p:read_stderr(4096) or ""
      if #ech > 0 then err_buf = err_buf .. ech end
      if system.get_time() > deadline then
        pcall(function() p:kill() end)
        on_done(nil, "Cloud AI timed out after 4 minutes"); return
      end
      coroutine.yield(0.1)
    end
    while true do local c2 = p:read_stdout(4096) or ""; if c2 == "" then break end; buf = buf .. c2 end
    while true do local e2 = p:read_stderr(4096) or ""; if e2 == "" then break end; err_buf = err_buf .. e2 end

    local rc = p:returncode() or 0
    if rc ~= 0 then
      local emsg = (err_buf ~= "" and err_buf) or (buf ~= "" and buf) or ("Cloud AI exited with code " .. tostring(rc))
      on_done(nil, emsg)
    elseif #buf == 0 then
      local emsg = (err_buf ~= "" and err_buf) or "Cloud AI returned no output"
      on_done(nil, emsg)
    elseif buf:match("^MISSING_API_KEY:") then
      local missing_p = buf:match("^MISSING_API_KEY:(%S+)") or prov
      on_done(nil, "Missing API Key for " .. missing_p .. ". Please configure it in AI Settings.")
    elseif buf:match("^ERROR:") then
      on_done(nil, buf)
    else
      on_done(buf, nil)
    end
  end)
  return p
end

-- ── Widget ────────────────────────────────────────────────────────────────────
local AIPluginGen = View:extend()

function AIPluginGen:new()
  AIPluginGen.super.new(self)
  self.scrollable = true
  self.name = "AI Plugins"

  self.state          = STATE.DESCRIBE
  self.doc            = Doc()
  self.doc_view       = DocView(self.doc)
  self.doc_view.gutter_width = 0
  self.doc_view.margin1 = 0
  self.doc_view.margin2 = 0
  self.doc_view.scrollable = true
  self.doc_view.get_gutter_width = function() return 0 end
  self.doc_view.draw_line_gutter = function() end
  self.doc_view.draw_background = function() end
  self.plan           = nil       -- parsed plan table
  self.result         = nil       -- {name, file} on success
  self.error_msg      = nil
  self.loading_start  = 0
  self.build_step     = 0
  self.plan_scroll    = 0
  self.plan_total_h   = 0
  self.buttons        = {}        -- [{x,y,w,h,id}]
  self.hovered        = nil

  self.engine              = store.engine or "cloud_api"
  self.cloud_provider      = store.cloud_provider or "groq"
  self.cloud_model         = store.cloud_model or "groq/openai/gpt-oss-120b"
  self.agy_model           = store.agy_model or "Default"
  self.show_model_picker   = false
  self.model_filter        = ""
  self.model_picker_scroll = 0
  self.hovered_model       = nil
end

function AIPluginGen:run_ai(prompt, on_done)
  if self.engine == "cloud_api" then
    return run_cloud_api(prompt, self.cloud_provider, self.cloud_model, on_done)
  else
    return run_agy(prompt, self.agy_conv_id, self.agy_model, on_done)
  end
end

-- ── Draw helpers (scaler-aware) ────────────────────────────────────────────
local function sp(n) return math.floor(n * SCALE) end

local function section_header(text, x, y, col)
  draw_icon_text(style.font, text, x, y, col or style.dim)
  return y + style.font:get_height() + sp(8)
end

local function complexity_bar(x, y, w, val)
  local fh = style.font:get_height()
  local bar_h = fh
  renderer.draw_rect(x, y, w, bar_h, style.background3 or c(45,45,45))
  local t    = val / 10
  local fill = math.floor(w * t)
  local col  = lerp_color(c(60,200,80), c(220,70,70), t)
  renderer.draw_rect(x, y, fill, bar_h, col)
  -- braille overlay
  local bars = ""
  for i=1,10 do bars = bars .. (i<=val and "▓" or "░") end
  renderer.draw_text(style.code_font, bars, x + sp(4), y, c(255,255,255,160))
  renderer.draw_text(style.font, val .. PATHSEP .. "10", x + w + sp(8), y, style.text)
  return y + bar_h + sp(4)
end

-- ── State: DESCRIBE ────────────────────────────────────────────────────────
function AIPluginGen:draw_describe()
  local x,y,w,h = self.position.x, self.position.y, self.size.x, self.size.y
  self.buttons = {}
  local pad = sp(PAD)
  local font = style.font
  local bfont = style.big_font or font
  local fh, bfh = font:get_height(), bfont:get_height()

  local cx, cy = x + pad, y + pad - self.scroll.y

  -- Title
  draw_icon_text(bfont, "\u{f0e7}  AI Plugin Generator", cx, cy, style.accent)
  cy = cy + bfh + sp(4)
  renderer.draw_text(font, "Describe a plugin idea and the AI will think, research and plan it for you.", cx, cy, style.dim)
  cy = cy + fh + sp(12)

  -- Engine & Model Toolbar
  local pill_w = sp(110)
  local pill_h = sp(26)
  
  -- Engine Toggle: Local AGY vs Cloud API
  local is_agy = (self.engine == "local_agy")
  local is_cloud = (self.engine == "cloud_api")
  
  local agy_bg = is_agy and (style.accent or c(60, 140, 220)) or (style.background3 or c(45, 45, 45))
  local agy_fg = is_agy and (style.background or c(20,20,20)) or style.dim
  local hov_agy = (self.hovered == "engine_agy")
  renderer.draw_rect(cx, cy, pill_w, pill_h, hov_agy and (style.background3 or c(55,55,55)) or agy_bg)
  local agy_txt = "\u{26a1} Local AGY"
  local atw = font:get_width(agy_txt)
  renderer.draw_text(font, agy_txt, cx + math.floor((pill_w - atw)/2), cy + math.floor((pill_h - fh)/2), agy_fg)
  table.insert(self.buttons, { x = cx, y = cy, w = pill_w, h = pill_h, id = "engine_agy" })
  
  local cloud_x = cx + pill_w + sp(6)
  local cloud_bg = is_cloud and (style.accent or c(60, 140, 220)) or (style.background3 or c(45, 45, 45))
  local cloud_fg = is_cloud and (style.background or c(20,20,20)) or style.dim
  local hov_cloud = (self.hovered == "engine_cloud")
  renderer.draw_rect(cloud_x, cy, pill_w, pill_h, hov_cloud and (style.background3 or c(55,55,55)) or cloud_bg)
  local cloud_txt = "\u{1f310} Cloud API"
  local ctw = font:get_width(cloud_txt)
  renderer.draw_text(font, cloud_txt, cloud_x + math.floor((pill_w - ctw)/2), cy + math.floor((pill_h - fh)/2), cloud_fg)
  table.insert(self.buttons, { x = cloud_x, y = cy, w = pill_w, h = pill_h, id = "engine_cloud" })
  
  -- Right side of toolbar: Provider & Model Picker Button
  local model_btn_x = cloud_x + pill_w + sp(12)
  local model_btn_w = (w - pad) - model_btn_x
  if model_btn_w > sp(100) then
    if is_cloud then
      local prov_display = (self.cloud_provider or "groq"):upper()
      local model_display = self.cloud_model or "gpt-oss-120b"
      if model_display:find("/") then
        model_display = model_display:match("^[^/]+/(.+)") or model_display
      end
      local btn_label = string.format("[%s] %s \u{25bc}", prov_display, model_display)
      local hov_mpick = (self.hovered == "pick_model")
      draw_btn(model_btn_x, cy, model_btn_w, pill_h, btn_label, hov_mpick, style.background3 or c(45,45,45))
      table.insert(self.buttons, { x = model_btn_x, y = cy, w = model_btn_w, h = pill_h, id = "pick_model" })
    else
      local agy_m_display = string.format("Model: %s \u{25bc}", self.agy_model or "Default")
      local hov_apick = (self.hovered == "pick_agy_model")
      draw_btn(model_btn_x, cy, model_btn_w, pill_h, agy_m_display, hov_apick, style.background3 or c(45,45,45))
      table.insert(self.buttons, { x = model_btn_x, y = cy, w = model_btn_w, h = pill_h, id = "pick_agy_model" })
    end
    self._model_btn_rect = { x = model_btn_x, y = cy, w = model_btn_w, h = pill_h }
  end
  cy = cy + pill_h + sp(14)

  -- Input display box
  local inp_w = w - pad*2
  local inp_h = sp(130)
  local is_focused = (core.active_view == self.doc_view) or (core.active_view == self)
  
  -- Card background
  local card_bg = style.background3 or style.background2 or c(45, 45, 45)
  renderer.draw_rect(cx, cy, inp_w, inp_h, card_bg)
  
  -- Border / Focus Glow
  local border_color = is_focused and (style.accent or c(80, 160, 240)) or (style.divider or c(70, 70, 70))
  local bw = is_focused and sp(2) or sp(1)
  renderer.draw_rect(cx, cy, inp_w, bw, border_color)
  renderer.draw_rect(cx, cy + inp_h - bw, inp_w, bw, border_color)
  renderer.draw_rect(cx, cy, bw, inp_h, border_color)
  renderer.draw_rect(cx + inp_w - bw, cy, bw, inp_h, border_color)

  local inner_pad = sp(10)
  self.doc_view.position.x = cx + inner_pad
  self.doc_view.position.y = cy + inner_pad
  self.doc_view.size.x = inp_w - (inner_pad * 2)
  self.doc_view.size.y = inp_h - (inner_pad * 2) - sp(16)
  
  core.push_clip_rect(cx + bw, cy + bw, inp_w - (bw * 2), inp_h - (bw * 2))
  self.doc_view:draw()
  
  local raw_txt = self.doc:get_text(1, 1, math.huge, math.huge)
  local is_empty = (raw_txt:match("^%s*$") ~= nil)
  
  if is_empty then
    local ph_col = { style.dim[1], style.dim[2], style.dim[3], 170 }
    local ph_y = cy + inner_pad
    local ph_x = cx + inner_pad
    
    if is_focused then
      ph_x = ph_x + sp(4)
    end
    
    renderer.draw_text(font, "Describe what you want your Lite XL plugin to do...", ph_x, ph_y, ph_col)
    
    local ex_y = ph_y + fh + sp(6)
    if ex_y + fh <= cy + inp_h - sp(22) then
      renderer.draw_text(font, "Example: 'Add Pomodoro timer to status bar with chime alerts'", ph_x, ex_y, { style.dim[1], style.dim[2], style.dim[3], 120 })
    end
  end
  
  -- Hint in bottom right corner
  local hint_txt = "Ctrl+V / Right-Click to Paste"
  local hint_w = font:get_width(hint_txt)
  local hint_y = cy + inp_h - fh - sp(4)
  local hint_x = cx + inp_w - hint_w - sp(8)
  renderer.draw_text(font, hint_txt, hint_x, hint_y, { style.dim[1], style.dim[2], style.dim[3], 90 })
  
  core.pop_clip_rect()

  self.input_rect = {x=cx, y=cy, w=inp_w, h=inp_h}
  cy = cy + inp_h + sp(12)

  -- Buttons row
  local bh = sp(32)
  local bw_gen = w - pad*2
  
  rawset(_G, "ai_plugin_gen_last_doc", self.doc)

  local hov_gen = self.hovered == "generate"
  draw_btn(cx, cy, bw_gen, bh, "\u{f135}  Generate Plan", hov_gen, c(60,160,100))
  table.insert(self.buttons, {x=cx, y=cy, w=bw_gen, h=bh, id="generate"})
  cy = cy + bh + sp(20)

  -- Divider
  renderer.draw_rect(cx, cy, w - pad*2, sp(1), style.divider or c(80,80,80))
  cy = cy + sp(12)

  -- Installed list
  local list_label = ("\u{f0c0}  My Generated Plugins (%d)"):format(#store.installed)
  draw_icon_text(font, list_label, cx, cy, style.dim)
  cy = cy + fh + sp(8)

  if #store.installed == 0 then
    renderer.draw_text(font, "No plugins generated yet.", cx, cy, style.dim)
  else
    for i, plug in ipairs(store.installed) do
      local rh = sp(30)
      if cy + rh > y + h - sp(8) then break end
      local hov_row = self.hovered == ("plug_"..i)
      if hov_row then renderer.draw_rect(cx, cy, w-pad*2, rh, style.line_highlight or c(80,80,80,60)) end

      local exists = system.get_file_info(plug.file) ~= nil
      local dw,ow = sp(64), sp(64)
      local del_x = x + w - pad - dw
      local opn_x = del_x - ow - sp(4)
      core.push_clip_rect(cx + sp(16), cy, math.max(sp(20), opn_x - cx - sp(20)), rh)
      renderer.draw_text(font, plug.name or "?", cx+sp(16), cy+(rh-fh)/2, style.text)
      core.pop_clip_rect()
      local hov_o = self.hovered == ("opn_"..i)
      local hov_d = self.hovered == ("del_"..i)
      draw_btn(opn_x, cy+sp(2), ow, rh-sp(4), "\u{f15b}", hov_o)
      draw_btn(del_x, cy+sp(2), dw, rh-sp(4), "\u{f1f8}", hov_d, c(180,60,60))
      table.insert(self.buttons, {x=cx, y=cy, w=opn_x-cx, h=rh, id="plug_"..i})
      table.insert(self.buttons, {x=opn_x, y=cy+sp(2), w=ow, h=rh-sp(4), id="opn_"..i})
      table.insert(self.buttons, {x=del_x, y=cy+sp(2), w=dw, h=rh-sp(4), id="del_"..i})
      cy = cy + rh + sp(2)
    end
  end

  core.redraw = true
end

-- ── State: LOADING ────────────────────────────────────────────────────────────
function AIPluginGen:draw_loading(mode)
  local x,y,w,h = self.position.x, self.position.y, self.size.x, self.size.y
  self.buttons = {}
  mode = mode or "planning"
  local steps  = mode == "planning" and PLAN_STEPS or BUILD_STEPS
  local elapsed = system.get_time() - self.loading_start
  local t       = system.get_time()

  -- Panel
  local panel_w = math.min(sp(520), w - sp(40))
  local panel_x = x + (w - panel_w) / 2
  local fh       = style.font:get_height()
  local bfh      = (style.big_font or style.font):get_height()
  local panel_h  = bfh + sp(60) + #steps*(fh+sp(6)) + sp(60)
  local panel_y  = y + (h - panel_h) / 2

  -- Pulse
  local pulse = (math.sin(t * 3) + 1) / 2
  local pc    = lerp_color(c(80,220,100), c(60,160,255), pulse)

  renderer.draw_rect(panel_x, panel_y, panel_w, panel_h, style.background2 or c(35,35,35))
  local bw = math.max(1, sp(2))
  renderer.draw_rect(panel_x,           panel_y,           panel_w, bw, pc)
  renderer.draw_rect(panel_x,           panel_y+panel_h-bw,panel_w, bw, pc)
  renderer.draw_rect(panel_x,           panel_y,           bw, panel_h, pc)
  renderer.draw_rect(panel_x+panel_w-bw,panel_y,           bw, panel_h, pc)

  local cy = panel_y + sp(18)
  local cx = panel_x + sp(18)
  local inner_w = panel_w - sp(36)

  -- Spinner + title
  local spinners = {"/", "-", "\\", "|"}
  local spin = spinners[(math.floor(t*10) % #spinners) + 1]
  local eng_lbl = (self.engine == "cloud_api") and ((self.cloud_provider or "Cloud AI"):upper()) or "AGY"
  local title = mode=="planning" and ("\u{f0e7}  " .. eng_lbl .. " PLANNING...") or ("\u{f0e7}  " .. eng_lbl .. " BUILDING...")
  renderer.draw_text(style.font, spin, cx, cy+(bfh-fh)/2, pc)
  draw_icon_text(style.big_font or style.font, title, cx+sp(24), cy, style.accent)
  cy = cy + bfh + sp(18)

  -- Progress bar
  local n_done = mode=="planning"
    and math.min(#PLAN_STEPS, math.floor(elapsed/2))
    or math.min(#BUILD_STEPS, self.build_step or 0)
    
  local pct
  if mode == "planning" then
    pct = math.min(0.97, n_done / #steps + (elapsed % 2.0) / (2.0 * #steps))
  else
    pct = math.min(0.99, n_done / #steps)
  end
  
  local pct_text = ("%.0f%%"):format(pct*100)
  local pct_w = style.font:get_width(pct_text)
  local bar_w = math.max(sp(60), inner_w - pct_w - sp(16))
  renderer.draw_rect(cx, cy, bar_w, sp(6), style.background3 or c(50,50,50))
  renderer.draw_rect(cx, cy, math.floor(bar_w*pct), sp(6), pc)
  renderer.draw_text(style.font, pct_text, cx + bar_w + sp(8), cy - sp(5), pc)
  cy = cy + sp(24)

  -- Checklist
  for i, step in ipairs(steps) do
    local done, active
    if mode == "planning" then
      local step_elapsed = elapsed - (i-1) * 2.0
      done   = step_elapsed > 1.5
      active = (not done) and step_elapsed > 0
    else
      done   = i <= (self.build_step or 0)
      active = i == (self.build_step or 0) + 1
    end
    local icon   = done and "\u{f00c}" or (active and spinners[(math.floor(t*8) % #spinners)+1] or "\u{f111}")
    local col    = done and c(80,200,80) or (active and pc or style.dim)
    draw_icon_text(style.font, icon.."  "..step, cx+sp(4), cy, col)
    cy = cy + fh + sp(8)
  end

  -- Flavor text
  local flavors = {
    "researching the Lite XL API surface...",
    "scanning existing plugin patterns...",
    "synthesizing an optimal plan...",
    "designing the sample UI preview...",
    "analyzing complexity and risks...",
  }
  local fl = flavors[(math.floor(t*0.4) % #flavors) + 1]
  cy = cy + sp(16)
  draw_icon_text(style.font, "\u{f05a}  agy is "..fl, cx, cy, style.dim)

  core.redraw = true
end

-- ── State: PLAN PAGE ──────────────────────────────────────────────────────────
function AIPluginGen:draw_plan()
  local x,y,w,h = self.position.x, self.position.y, self.size.x, self.size.y
  self.buttons = {}
  local plan  = self.plan; if not plan then return end
  local font  = style.font
  local cf    = style.code_font
  local bfont = style.big_font or font
  local fh, cfh, bfh = font:get_height(), cf:get_height(), bfont:get_height()
  local pad   = sp(PAD)

  -- ── Bottom bar (fixed) ──
  local bar_h = sp(50)
  local bar_y = y + h - bar_h
  renderer.draw_rect(x, bar_y, w, sp(1), style.divider or c(80,80,80))
  renderer.draw_rect(x, bar_y+sp(1), w, bar_h, style.background or c(40,40,40))

  local bh = sp(34)
  local by = bar_y + (bar_h - bh) / 2
  local approve_w, decline_w, trash_w = sp(170), sp(165), sp(44)
  local total_bw = approve_w + decline_w + trash_w + sp(10)*2
  local bx = x + (w - total_bw) / 2

  local hov_a  = self.hovered == "approve"
  local hov_d  = self.hovered == "decline"
  local hov_t  = self.hovered == "trash"
  draw_btn(bx,                       by, approve_w, bh, "\u{f058}  Approve & Build", hov_a, c(50,180,80))
  draw_btn(bx+approve_w+sp(10),      by, decline_w, bh, "\u{f021}  Decline & Redo",  hov_d, c(200,140,50))
  draw_btn(bx+approve_w+decline_w+sp(20), by, trash_w, bh, "\u{f1f8}",             hov_t, c(180,60,60))
  table.insert(self.buttons, {x=bx, y=by, w=approve_w, h=bh, id="approve"})
  table.insert(self.buttons, {x=bx+approve_w+sp(10), y=by, w=decline_w, h=bh, id="decline"})
  table.insert(self.buttons, {x=bx+approve_w+decline_w+sp(20), y=by, w=trash_w, h=bh, id="trash"})

  -- Engine badge on left side of bottom bar
  local eng_str = (self.engine == "cloud_api")
    and string.format("\u{1f310} %s: %s", (self.cloud_provider or "cloud"):upper(), (self.cloud_model or ""):match("[^/]+$") or (self.cloud_model or ""))
    or string.format("\u{26a1} AGY: %s", self.agy_model or "Default")
  local eng_w = font:get_width(eng_str) + sp(16)
  if bx - (x + pad) > eng_w + sp(10) then
    local ebx = x + pad
    renderer.draw_rect(ebx, by + sp(2), eng_w, bh - sp(4), style.background3 or c(50,50,50))
    renderer.draw_text(font, eng_str, ebx + sp(8), by + math.floor((bh - fh)/2), style.accent or c(60,140,220))
  end

  -- ── Scrollable content ──
  local content_h = h - bar_h
  core.push_clip_rect(x, y, w, content_h)

  local cw   = w - pad*2
  local gap  = sp(16)
  local left_w  = math.floor((cw - gap) * 0.55)
  local right_w = cw - left_w - gap
  local left_x  = x + pad
  local right_x = left_x + left_w + gap

  local left_y  = y - self.plan_scroll + pad
  local right_y = left_y
  local start_y = left_y

  local function bento(cx, cy, w_card, accent_col, render_func)
    local cpad = sp(16)
    local bottom = render_func(cx + cpad, cy + cpad, w_card - cpad*2, true)
    local card_h = bottom - cy + cpad
    if cy + card_h > y and cy < y + content_h then
      renderer.draw_rect(cx, cy, w_card, card_h, style.background2 or c(40,40,40))
      renderer.draw_rect(cx, cy, w_card, sp(2), accent_col or style.accent)
      core.push_clip_rect(cx, cy, w_card, card_h)
      render_func(cx + cpad, cy + cpad, w_card - cpad*2, false)
      core.pop_clip_rect()
    end
    return cy + card_h + gap
  end

  local function d_text(m, ...) if not m then renderer.draw_text(...) end end
  local function d_icon(m, ...) if not m then draw_icon_text(...) end end
  local function d_rect(m, ...) if not m then renderer.draw_rect(...) end end
  local function d_header(m, text, sx, sy, col)
    d_icon(m, bfont, text, sx, sy, col or style.text)
    return sy + bfh + sp(8)
  end

  -- === LEFT COLUMN ===
  left_y = bento(left_x, left_y, left_w, style.accent, function(sx, sy, cw_c, m)
    sy = d_header(m, "\u{f0e7}  "..plan.name, sx, sy, style.accent)
    for _, ln in ipairs(wrap_text(font, plan.overview, cw_c)) do
      d_text(m, font, ln, sx, sy, style.text); sy = sy + fh + sp(4)
    end
    return sy
  end)

  if #plan.research > 0 then
    left_y = bento(left_x, left_y, left_w, c(100,160,200), function(sx, sy, cw_c, m)
      sy = d_header(m, "\u{f0ac}  Research Findings", sx, sy, c(100,160,200))
      for _, r in ipairs(plan.research) do
        d_icon(m, font, "\u{f111}", sx, sy, style.dim)
        for _, ln in ipairs(wrap_text(font, r, cw_c - sp(24))) do
          d_text(m, font, ln, sx + sp(24), sy, style.text); sy = sy + fh + sp(4)
        end
        sy = sy + sp(4)
      end
      return sy
    end)
  end

  local has_chal = (#(plan.fatal or {}) > 0) or (#(plan.conquer or {}) > 0) or (#(plan.easy or {}) > 0)
  if has_chal then
    left_y = bento(left_x, left_y, left_w, c(220,160,50), function(sx, sy, cw_c, m)
      sy = d_header(m, "\u{f071}  Challenges & Wins", sx, sy, c(220,160,50))
      for _, cs in ipairs({
        {key="fatal",   label="\u{f057} Fatal",    col=c(220,80,80)},
        {key="conquer", label="\u{f071} Conquerable", col=c(220,160,50)},
        {key="easy",    label="\u{f058} Easy Wins", col=c(80,200,80)},
      }) do
        local items = plan[cs.key]
        if items and #items > 0 then
          d_icon(m, font, cs.label, sx, sy, cs.col); sy = sy + fh + sp(6)
          for _, it in ipairs(items) do
            d_icon(m, font, "\u{f0da}", sx + sp(8), sy, style.dim)
            for _, ln in ipairs(wrap_text(font, it, cw_c - sp(28))) do
              d_text(m, font, ln, sx + sp(28), sy, style.text); sy = sy + fh + sp(4)
            end
            sy = sy + sp(2)
          end
          sy = sy + sp(6)
        end
      end
      return sy
    end)
  end

  if plan.edge_cases and #plan.edge_cases > 0 then
    left_y = bento(left_x, left_y, left_w, c(220,100,50), function(sx, sy, cw_c, m)
      sy = d_header(m, "\u{f071}  Critical Edge Cases", sx, sy, c(220,100,50))
      for _, it in ipairs(plan.edge_cases) do
        d_icon(m, font, "\u{f0da}", sx, sy, style.dim)
        for _, ln in ipairs(wrap_text(font, it, cw_c - sp(16))) do
          d_text(m, font, ln, sx + sp(16), sy, style.text); sy = sy + fh + sp(4)
        end
        sy = sy + sp(4)
      end
      return sy
    end)
  end

  if plan.design ~= "" then
    left_y = bento(left_x, left_y, left_w, c(180,100,200), function(sx, sy, cw_c, m)
      sy = d_header(m, "\u{f1fb}  Sample Design", sx, sy, c(180,100,200))
      local rdw, rdh = sp(100), fh+sp(6)
      local rdx = sx + cw_c - rdw
      if not m then
        draw_btn(rdx, sy - rdh - sp(10), rdw, rdh, "\u{f021} Redesign", self.hovered == "redesign")
        table.insert(self.buttons, {x=rdx, y=sy - rdh - sp(10), w=rdw, h=rdh, id="redesign"})
      end
      
      local design_lines = {}
      for ln in (plan.design.."\n"):gmatch("([^\n]*)") do table.insert(design_lines, ln) end
      local design_h = #design_lines * (cfh+sp(2)) + sp(16)
      
      d_rect(m, sx, sy, cw_c, design_h, style.background3 or c(30,30,30))
      local dy = sy + sp(8)
      for _, ln in ipairs(design_lines) do
        if not m then
          core.push_clip_rect(sx + sp(10), dy, cw_c - sp(20), cfh + sp(2))
          renderer.draw_text(cf, ln, sx + sp(10), dy, style.accent)
          core.pop_clip_rect()
        end
        dy = dy + cfh + sp(2)
      end
      return sy + design_h
    end)
  end

  -- === RIGHT COLUMN ===
  right_y = bento(right_x, right_y, right_w, c(100,200,100), function(sx, sy, cw_c, m)
    sy = d_header(m, "\u{f080}  At a Glance", sx, sy, c(100,200,100))
    d_icon(m, font, "Complexity", sx, sy, style.dim); sy = sy + fh + sp(4)
    if not m then complexity_bar(sx, sy, cw_c, plan.complexity) end
    sy = sy + fh + sp(12)
    
    local lbl1 = "\u{f017}  Est. Time:"
    d_icon(m, font, lbl1, sx, sy, style.dim)
    local lw1 = get_icon_text_width(font, lbl1) + sp(12)
    for _, ln in ipairs(wrap_text(font, plan.time_est, cw_c - lw1)) do
      d_text(m, font, ln, sx + lw1, sy, style.text); sy = sy + fh + sp(2)
    end
    sy = sy + sp(6)
    
    local wcol = plan.worth=="Recommended" and c(80,200,80) or plan.worth=="Overkill" and c(200,80,80) or c(220,180,50)
    local lbl2 = "\u{f0eb}  Worth It:"
    d_icon(m, font, lbl2, sx, sy, style.dim)
    local lw2 = get_icon_text_width(font, lbl2) + sp(12)
    for _, ln in ipairs(wrap_text(font, plan.worth, cw_c - lw2)) do
      d_text(m, font, ln, sx + lw2, sy, wcol); sy = sy + fh + sp(2)
    end
    sy = sy + sp(6)
    
    local lbl3 = "\u{f12e}  Integration:"
    d_icon(m, font, lbl3, sx, sy, style.dim)
    local lw3 = get_icon_text_width(font, lbl3) + sp(12)
    for _, ln in ipairs(wrap_text(font, plan.integration, cw_c - lw3)) do
      d_text(m, font, ln, sx + lw3, sy, style.text); sy = sy + fh + sp(2)
    end
    sy = sy + sp(6)
    
    return sy
  end)

  right_y = bento(right_x, right_y, right_w, c(180,180,180), function(sx, sy, cw_c, m)
    sy = d_header(m, "\u{f187}  Architecture", sx, sy, c(180,180,180))
    d_icon(m, font, "Dependencies:", sx, sy, style.dim); sy = sy + fh + sp(4)
    for _, ln in ipairs(wrap_text(font, plan.deps, cw_c)) do
      d_text(m, font, ln, sx, sy, style.text); sy = sy + fh + sp(4)
    end
    sy = sy + sp(8)
    
    if #plan.hooks > 0 then
      d_icon(m, font, "\u{f1e6} Hooks Required:", sx, sy, style.dim); sy = sy + fh + sp(8)
      local hx, hy = sx, sy
      for _, hook in ipairs(plan.hooks) do
        local hw = cf:get_width(hook) + sp(12)
        local hw_capped = math.min(hw, cw_c)
        if hx + hw_capped > sx + cw_c then hx = sx; hy = hy + cfh + sp(8) end
        d_rect(m, hx, hy, hw_capped, cfh + sp(4), style.background3 or c(50,50,50))
        if not m then
          core.push_clip_rect(hx + sp(6), hy + sp(2), hw_capped - sp(12), cfh + sp(2))
          renderer.draw_text(cf, hook, hx + sp(6), hy + sp(2), style.accent)
          core.pop_clip_rect()
        end
        hx = hx + hw_capped + sp(6)
      end
      sy = hy + cfh + sp(12)
    end
    
    if #plan.files > 0 then
      d_icon(m, font, "\u{f07b} Files Created:", sx, sy, style.dim); sy = sy + fh + sp(4)
      for _, f in ipairs(plan.files) do
        local lblf = "\u{f15b}  "
        d_icon(m, cf, lblf, sx, sy, c(150,200,250))
        local fw = get_icon_text_width(cf, lblf)
        for _, ln in ipairs(wrap_text(cf, f, cw_c - fw)) do
          d_text(m, cf, ln, sx + fw, sy, c(150,200,250)); sy = sy + cfh + sp(2)
        end
        sy = sy + sp(4)
      end
    end
    return sy
  end)

  if #plan.shortcuts > 0 then
    local used = {}
    for stroke, _ in pairs(keymap.map) do used[stroke] = true end
    local modkeys = { "ctrl", "alt", "shift", "cmd" }
    local function normalize_stroke(stroke)
      local st = {}
      for key in stroke:lower():gsub("%s+", ""):gmatch("[^+]+") do table.insert(st, key) end
      table.sort(st, function(a, b)
        if a == b then return false end
        for _, mod in ipairs(modkeys) do if a == mod or b == mod then return a == mod end end
        return a < b
      end)
      return table.concat(st, "+")
    end

    right_y = bento(right_x, right_y, right_w, c(200,100,100), function(sx, sy, cw_c, m)
      sy = d_header(m, "\u{f11c}  Shortcuts", sx, sy, c(200,100,100))
      for _, sc in ipairs(plan.shortcuts) do
        local clash = used[normalize_stroke(sc.key)]
        local scol = clash and c(220,80,80) or c(80,200,80)
        local status = clash and "\u{f057} Clash" or "\u{f058} Free"
        
        local status_w = get_icon_text_width(font, status)
        d_text(m, cf, sc.key, sx, sy, style.accent)
        d_icon(m, font, status, sx + cw_c - status_w, sy, scol)
        sy = sy + cfh + sp(4)
        
        for _, ln in ipairs(wrap_text(font, sc.desc, cw_c)) do
          d_text(m, font, ln, sx, sy, style.dim); sy = sy + fh + sp(2)
        end
        sy = sy + sp(8)
      end
      return sy
    end)
  end

  if #plan.testing > 0 then
    right_y = bento(right_x, right_y, right_w, c(100,180,220), function(sx, sy, cw_c, m)
      sy = d_header(m, "\u{f0c3}  Testing", sx, sy, c(100,180,220))
      for _, t2 in ipairs(plan.testing) do
        d_icon(m, font, "\u{f00c}", sx, sy, c(80,200,80))
        for _, ln in ipairs(wrap_text(font, t2, cw_c - sp(24))) do
          d_text(m, font, ln, sx + sp(24), sy, style.text); sy = sy + fh + sp(4)
        end
        sy = sy + sp(4)
      end
      return sy
    end)
  end

  if #plan.github_repos > 0 then
    right_y = bento(right_x, right_y, right_w, c(150,150,220), function(sx, sy, cw_c, m)
      sy = d_header(m, "\u{f09b}  Related GitHub Repos & Tools", sx, sy, c(150,150,220))
      for i, repo in ipairs(plan.github_repos) do
        d_icon(m, font, "\u{f126}", sx, sy, style.dim)
        local url = repo:match("https?://[%w-_%.%?%.:/%%+=&]+")
        local text_to_draw = repo
        if url then text_to_draw = repo:gsub("https?://[%w-_%.%?%.:/%%+=&]+", "") end
        
        for _, ln in ipairs(wrap_text(font, text_to_draw, cw_c - sp(24))) do
          d_text(m, font, ln, sx + sp(24), sy, style.text); sy = sy + fh + sp(4)
        end
        if url and not m then
          local btn_w = math.min(cw_c - sp(24), font:get_width(url) + sp(30))
          draw_btn(sx + sp(24), sy, btn_w, fh + sp(8), "\u{f08e} Open Link", self.hovered == ("repo_btn_"..i))
          table.insert(self.buttons, {x=sx + sp(24), y=sy, w=btn_w, h=fh + sp(8), id="repo_btn_"..i, url=url})
          sy = sy + fh + sp(12)
        elseif url and m then
          sy = sy + fh + sp(12)
        end
        sy = sy + sp(4)
      end
      return sy
    end)
  end

  self.plan_total_h = (math.max(left_y, right_y) - start_y) + pad
  core.pop_clip_rect()

  -- Scrollbar
  if self.plan_total_h > content_h then
    local sbw = sp(4); local sbx = x+w-sbw-sp(2)
    local vis  = content_h / self.plan_total_h
    local sbh  = math.max(sp(24), math.floor(content_h*vis))
    local sby  = y + math.floor((self.plan_scroll / self.plan_total_h) * content_h)
    renderer.draw_rect(sbx, y, sbw, content_h, style.background2 or c(40,40,40))
    renderer.draw_rect(sbx, sby, sbw, sbh, style.accent)
  end

  core.redraw = true
end

-- ── State: SUCCESS ────────────────────────────────────────────────────────────
function AIPluginGen:draw_success()
  local x,y,w,h = self.position.x, self.position.y, self.size.x, self.size.y
  self.buttons = {}
  local t   = system.get_time()
  local bfont = style.big_font or style.font
  local font  = style.font
  local fh, bfh = font:get_height(), bfont:get_height()
  local pulse = (math.sin(t*2)+1)/2
  local gc    = math.floor(140+115*pulse)
  local gc2   = lerp_color(c(60,gc,60), c(80,220,100), pulse)

  local cy = y + h/2 - sp(90)
  local icon = "\u{f058}"
  local iw   = bfont:get_width(icon)
  renderer.draw_text(bfont, icon, x+w/2-iw/2, cy, gc2)
  cy = cy + bfh + sp(10)
  local title = "Plugin Ready!"
  local tw = bfont:get_width(title)
  renderer.draw_text(bfont, title, x+w/2-tw/2, cy, style.accent)
  cy = cy + bfh + sp(12)

  if self.result then
    local msg = (self.result.name or "Plugin") .. " is generated, installed, and now active."
    local mw = font:get_width(msg)
    renderer.draw_text(font, msg, x+w/2-mw/2, cy, style.text)
    cy = cy + fh + sp(24)
  end

  local bh,bw = sp(34), sp(144)
  local bx  = x+w/2-(bw*2+sp(12))/2
  local hov_o = self.hovered == "open_result"
  local hov_c = self.hovered == "done_success"
  draw_btn(bx,         cy, bw, bh, "\u{f15b}  Open File", hov_o, style.accent)
  draw_btn(bx+bw+sp(12), cy, bw, bh, "Done",              hov_c)
  table.insert(self.buttons, {x=bx,         y=cy, w=bw, h=bh, id="open_result"})
  table.insert(self.buttons, {x=bx+bw+sp(12), y=cy, w=bw, h=bh, id="done_success"})
  core.redraw = true
end

-- ── State: ERROR ──────────────────────────────────────────────────────────────
function AIPluginGen:draw_error()
  local x,y,w,h = self.position.x, self.position.y, self.size.x, self.size.y
  self.buttons = {}
  local bfont = style.big_font or style.font
  local font  = style.font
  local fh, bfh = font:get_height(), bfont:get_height()
  local cy = y + h/2 - sp(80)

  local icon = "\u{f057}"
  local iw   = bfont:get_width(icon)
  renderer.draw_text(bfont, icon, x+w/2-iw/2, cy, c(220,80,80))
  cy = cy + bfh + sp(10)
  local title = "Error During Generation"
  local tw    = bfont:get_width(title)
  renderer.draw_text(bfont, title, x+w/2-tw/2, cy, c(220,80,80))
  cy = cy + bfh + sp(12)

  if self.error_msg then
    local emsg = self.error_msg:sub(1,90) .. (#self.error_msg>90 and "..." or "")
    local ew   = font:get_width(emsg)
    renderer.draw_text(font, emsg, x+w/2-ew/2, cy, style.dim)
    cy = cy + fh + sp(8)
  end
  local note = "Auto-Healer has been notified. It will attempt to fix this and resume."
  local nw = font:get_width(note)
  renderer.draw_text(font, note, x+w/2-nw/2, cy, style.dim)
  cy = cy + fh + sp(24)

  local bh, bw = sp(34), sp(140)
  local bx     = x+w/2-bw/2
  local hov    = self.hovered == "back_error"
  draw_btn(bx, cy, bw, bh, "\u{f060}  Go Back", hov)
  table.insert(self.buttons, {x=bx, y=cy, w=bw, h=bh, id="back_error"})
  core.redraw = true
end
-- ── Main draw & update ────────────────────────────────────────────────────────
function AIPluginGen:update()
  AIPluginGen.super.update(self)
  self.target_size = self.target_size or (400 * SCALE)
  self:move_towards(self.size, "x", self.target_size)
  if self.state == STATE.DESCRIBE then
    self.doc_view:update()
    -- Automatically hand off global keyboard focus to our inline editor
    if core.active_view == self then
      core.set_active_view(self.doc_view)
    end
  end
end

function AIPluginGen:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function AIPluginGen:draw()
  self:draw_background(style.background or c(38,38,38))
  local x,y,w,h = self.position.x,self.position.y,self.size.x,self.size.y
  if w<=0 or h<=0 then return false end
  renderer.draw_rect(x,y,w,h, style.background or c(38,38,38))

  if     self.state == STATE.DESCRIBE  then self:draw_describe()
  elseif self.state == STATE.LOADING   then self:draw_loading("planning")
  elseif self.state == STATE.PLAN      then self:draw_plan()
  elseif self.state == STATE.BUILDING  then self:draw_loading("building")
  elseif self.state == STATE.SUCCESS   then self:draw_success()
  elseif self.state == STATE.ERROR     then self:draw_error()
  end

  if self.show_model_picker then
    self:draw_model_picker()
  end
  return true
end

function AIPluginGen:draw_model_picker()
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local font = style.font
  local fh = font:get_height()
  local pad = sp(12)
  
  local anchor = self._model_btn_rect or { x = x + sp(20), y = y + sp(120), w = sp(280), h = sp(28) }
  local pop_w = math.max(sp(340), anchor.w)
  local pop_h = math.min(sp(320), h - sp(40))
  local pop_x = math.min(anchor.x, x + w - pop_w - sp(10))
  local pop_y = anchor.y + anchor.h + sp(4)
  if pop_y + pop_h > y + h - sp(10) then
    pop_y = anchor.y - pop_h - sp(4)
  end
  
  self._mpicker_rect = { x = pop_x, y = pop_y, w = pop_w, h = pop_h }
  self._mpicker_items = {}
  self._mpicker_tabs = {}

  -- Background card & border
  renderer.draw_rect(pop_x, pop_y, pop_w, pop_h, style.background2 or c(30,30,30))
  local bw = math.max(1, sp(2))
  local border_col = style.accent or c(60, 140, 220)
  renderer.draw_rect(pop_x, pop_y, pop_w, bw, border_col)
  renderer.draw_rect(pop_x, pop_y + pop_h - bw, pop_w, bw, border_col)
  renderer.draw_rect(pop_x, pop_y, bw, pop_h, border_col)
  renderer.draw_rect(pop_x + pop_w - bw, pop_y, bw, pop_h, border_col)

  local cur_y = pop_y + pad
  local cx = pop_x + pad
  local inner_w = pop_w - pad * 2

  -- 1. Search Bar
  local sb_h = fh + sp(8)
  renderer.draw_rect(cx, cur_y, inner_w, sb_h, style.background3 or c(42,42,42))
  renderer.draw_rect(cx, cur_y, inner_w, sp(1), style.divider or c(60,60,60))
  local filter_str = (self.model_filter and self.model_filter ~= "") and self.model_filter or ""
  if filter_str == "" then
    renderer.draw_text(font, "Type to search models...", cx + sp(8), cur_y + sp(4), style.dim)
  else
    renderer.draw_text(font, filter_str .. " |", cx + sp(8), cur_y + sp(4), style.text)
  end
  cur_y = cur_y + sb_h + sp(8)

  -- 2. Provider Tabs (if Cloud API)
  if self.engine == "cloud_api" then
    local provs = get_configured_providers()
    local tab_h = sp(22)
    local tx = cx
    for _, prov in ipairs(provs) do
      local is_cur_prov = (self.cloud_provider == prov)
      local t_label = prov:upper()
      local tw = font:get_width(t_label) + sp(12)
      if tx + tw <= cx + inner_w then
        local t_bg = is_cur_prov and (style.accent or c(60,140,220)) or (style.background3 or c(45,45,45))
        local t_fg = is_cur_prov and (style.background or c(20,20,20)) or style.dim
        renderer.draw_rect(tx, cur_y, tw, tab_h, t_bg)
        renderer.draw_text(font, t_label, tx + sp(6), cur_y + math.floor((tab_h - fh)/2), t_fg)
        table.insert(self._mpicker_tabs, { x = tx, y = cur_y, w = tw, h = tab_h, provider = prov })
        tx = tx + tw + sp(4)
      end
    end
    cur_y = cur_y + tab_h + sp(8)
  end

  -- 3. Model list
  local list = {}
  if self.engine == "cloud_api" then
    list = fetch_cloud_models(self.cloud_provider)
  else
    list = AGY_MODELS
  end

  -- Filter list
  local filtered = {}
  local q = (self.model_filter or ""):lower()
  for _, m in ipairs(list) do
    if q == "" or m:lower():find(q, 1, true) then
      table.insert(filtered, m)
    end
  end

  local item_h = fh + sp(8)
  local list_area_h = (pop_y + pop_h - sp(24)) - cur_y
  local total_h = #filtered * item_h
  self.model_picker_max_scroll = math.max(0, total_h - list_area_h)
  self.model_picker_scroll = math.max(0, math.min(self.model_picker_max_scroll, self.model_picker_scroll or 0))

  core.push_clip_rect(cx, cur_y, inner_w, list_area_h)
  local iy = cur_y - self.model_picker_scroll
  for _, m in ipairs(filtered) do
    if iy + item_h >= cur_y and iy <= cur_y + list_area_h then
      local is_sel = (self.engine == "cloud_api" and (self.cloud_model == m or self.cloud_model:find(m, 1, true)))
                  or (self.engine == "local_agy" and (self.agy_model == m))
      local is_hov = (self.hovered_model == m)
      local ibg = is_sel and (style.accent or c(60,140,220)) or (is_hov and (style.background3 or c(50,50,50)) or (style.background2 or c(32,32,32)))
      local ifg = is_sel and (style.background or c(20,20,20)) or (is_hov and style.text or style.dim)

      renderer.draw_rect(cx, iy, inner_w, item_h, ibg)
      
      -- Display label: clean provider prefix
      local disp = m
      if disp:find("/") then disp = disp:match("^[^/]+/(.+)") or disp end
      renderer.draw_text(font, disp, cx + sp(8), iy + math.floor((item_h - fh)/2), ifg)

      -- Category tag on right
      local cat = nil
      local ml = m:lower()
      if ml:find("nemotron") or ml:find("reasoning") or ml:find("thinking") or ml:find("r1") then
        cat = "Reasoning"
      elseif ml:find("bolt") or ml:find("lightning") or ml:find("fast") or ml:find("flash") or ml:find("20b") or ml:find("8b") then
        cat = "Fast"
      elseif ml:find("coder") or ml:find("code") then
        cat = "Coder"
      elseif ml:find("120b") or ml:find("pro") or ml:find("ultra") then
        cat = "Pro"
      end

      if cat then
        local cstr = "[" .. cat .. "]"
        local cw = font:get_width(cstr)
        local ccol = is_sel and (style.background or c(20,20,20)) or style.dim
        renderer.draw_text(font, cstr, cx + inner_w - cw - sp(8), iy + math.floor((item_h - fh)/2), ccol)
      end

      table.insert(self._mpicker_items, { x = cx, y = iy, w = inner_w, h = item_h, model = m })
    end
    iy = iy + item_h
  end
  core.pop_clip_rect()

  -- Bottom tip
  local tip_txt = "Esc to close • Click to select"
  local tw = font:get_width(tip_txt)
  renderer.draw_text(font, tip_txt, cx + math.floor((inner_w - tw)/2), pop_y + pop_h - fh - sp(4), { style.dim[1], style.dim[2], style.dim[3], 120 })
end

-- ── Input handling ────────────────────────────────────────────────────────────
function AIPluginGen:on_mouse_moved(mx, my, dx, dy)
  if self.state == STATE.DESCRIBE then self.doc_view:on_mouse_moved(mx, my, dx, dy) end

  if self.show_model_picker and self._mpicker_items then
    local prev_m = self.hovered_model
    self.hovered_model = nil
    for _, item in ipairs(self._mpicker_items) do
      if mx >= item.x and mx <= item.x + item.w and my >= item.y and my <= item.y + item.h then
        self.hovered_model = item.model
        break
      end
    end
    if prev_m ~= self.hovered_model then core.redraw = true end
  end

  local prev = self.hovered; self.hovered = nil
  for _, btn in ipairs(self.buttons) do
    if mx>=btn.x and mx<=btn.x+btn.w and my>=btn.y and my<=btn.y+btn.h then
      self.hovered = btn.id; break
    end
  end
  if prev ~= self.hovered then core.redraw = true end
  return AIPluginGen.super.on_mouse_moved(self, mx, my, dx, dy)
end

function AIPluginGen:on_mouse_pressed(button, mx, my, clicks)
  if button == "right" then
    if self.state == STATE.DESCRIBE and self.input_rect then
      local r = self.input_rect
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        local text = system.get_clipboard()
        if text and text ~= "" then
          self.doc:text_input(text)
          core.set_active_view(self.doc_view)
          core.redraw = true
          return true
        end
      end
    end
    return false
  end

  if button ~= "left" then return false end

  -- Handle model picker popover interactions
  if self.show_model_picker then
    -- Check provider tabs
    if self._mpicker_tabs then
      for _, tab in ipairs(self._mpicker_tabs) do
        if mx >= tab.x and mx <= tab.x + tab.w and my >= tab.y and my <= tab.y + tab.h then
          self.cloud_provider = tab.provider
          store.cloud_provider = tab.provider
          save_store()
          self.model_filter = ""
          self.model_picker_scroll = 0
          fetch_cloud_models(tab.provider)
          core.redraw = true
          return true
        end
      end
    end

    -- Check model item selection
    if self._mpicker_items then
      for _, item in ipairs(self._mpicker_items) do
        if mx >= item.x and mx <= item.x + item.w and my >= item.y and my <= item.y + item.h then
          if self.engine == "cloud_api" then
            self.cloud_model = item.model
            store.cloud_model = item.model
          else
            self.agy_model = item.model
            store.agy_model = item.model
          end
          save_store()
          self.show_model_picker = false
          core.redraw = true
          return true
        end
      end
    end

    -- Check if clicked outside popover
    if self._mpicker_rect then
      local pr = self._mpicker_rect
      if mx < pr.x or mx > pr.x + pr.w or my < pr.y or my > pr.y + pr.h then
        self.show_model_picker = false
        core.redraw = true
        return true
      end
    end
  end

  -- Route to doc_view if clicked inside input box
  if self.state == STATE.DESCRIBE and self.input_rect then
    local r = self.input_rect
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      self.doc_view:on_mouse_pressed(button, mx, my, clicks)
      core.set_active_view(self.doc_view) -- ensure we receive keyboard
      return true
    end
  end

  for _, btn in ipairs(self.buttons) do
    if mx>=btn.x and mx<=btn.x+btn.w and my>=btn.y and my<=btn.y+btn.h then
      self:handle_click(btn.id); return true
    end
  end
  return false
end

function AIPluginGen:on_mouse_released(button, mx, my)
  if self.state == STATE.DESCRIBE then self.doc_view:on_mouse_released(button, mx, my) end
end

function AIPluginGen:on_mouse_left()
  if self.state == STATE.DESCRIBE then self.doc_view:on_mouse_left() end
end

function AIPluginGen:on_mouse_wheel(dy, dx)
  if self.show_model_picker then
    self.model_picker_scroll = math.max(0, math.min(self.model_picker_max_scroll or 1000, (self.model_picker_scroll or 0) - dy * sp(20)))
    core.redraw = true
    return true
  end
  if self.state == STATE.DESCRIBE then self.doc_view:on_mouse_wheel(dy, dx) end
  if self.state == STATE.PLAN then
    local ch = self.size.y - sp(50)
    self.plan_scroll = math.max(0, math.min(
      math.max(0, self.plan_total_h - ch),
      self.plan_scroll - dy * sp(40)
    ))
    core.redraw = true; return true
  end
  return false
end

function AIPluginGen:on_text_input(text)
  if self.show_model_picker then
    self.model_filter = (self.model_filter or "") .. text
    self.model_picker_scroll = 0
    core.redraw = true
    return true
  end
  return AIPluginGen.super.on_text_input(self, text)
end

function AIPluginGen:on_key_pressed(key)
  if self.show_model_picker then
    if key == "escape" then
      self.show_model_picker = false
      core.redraw = true
      return true
    elseif key == "backspace" then
      if self.model_filter and #self.model_filter > 0 then
        self.model_filter = self.model_filter:sub(1, -2)
        self.model_picker_scroll = 0
        core.redraw = true
      end
      return true
    end
  end
  return AIPluginGen.super.on_key_pressed(self, key)
end

-- ── Button actions ────────────────────────────────────────────────────────────
function AIPluginGen:handle_click(id)
  if id == "engine_agy" then
    self.engine = "local_agy"
    store.engine = "local_agy"
    save_store()
    self.show_model_picker = false
    core.redraw = true
    return

  elseif id == "engine_cloud" then
    self.engine = "cloud_api"
    store.engine = "cloud_api"
    save_store()
    self.show_model_picker = false
    fetch_cloud_models(self.cloud_provider)
    core.redraw = true
    return

  elseif id == "pick_model" or id == "pick_agy_model" then
    self.show_model_picker = not self.show_model_picker
    if self.show_model_picker then
      self.model_filter = ""
      self.model_picker_scroll = 0
      if self.engine == "cloud_api" then
        fetch_cloud_models(self.cloud_provider)
      end
    end
    core.redraw = true
    return

  elseif id == "generate" then
    local text = self.doc:get_text(1, 1, math.huge, math.huge)
    if #(text:match("^%s*(.-)%s*$")) < 8 then
      core.log("[AI Plugin Gen] Please describe your plugin idea first.")
      return
    end
    self:do_generate_plan()

  elseif id == "approve" then
    self:do_build()

  elseif id == "decline" then
    if self.plan then
      store.rejected_hashes[simple_hash(self.plan.name..tostring(self.plan.complexity))] = true
      save_store()
    end
    self.plan = nil
    self:do_generate_plan()

  elseif id == "trash" then
    if self.agy_conv_id then
      local brain_dir = (os.getenv("HOME") or os.getenv("USERPROFILE")) .. "/.gemini/antigravity-cli/brain/" .. self.agy_conv_id
      if PLATFORM == "Windows" then
        os.execute('rmdir /s /q "' .. brain_dir:gsub("/", "\\") .. '"')
      else
        os.execute('rm -rf "' .. brain_dir .. '"')
      end
      self.agy_conv_id = nil
    end
    self.plan = nil; self.doc:remove(1, 1, math.huge, math.huge)
    self.state = STATE.DESCRIBE; core.redraw = true

  elseif id == "redesign" then
    self:do_redesign()

  elseif id == "open_result" then
    if self.result then
      local ok, doc = pcall(core.open_doc, self.result.file)
      if ok and doc then
        local node = core.root_view:get_active_node_default()
        local DocView = require "core.docview"
        if node then node:add_view(DocView(doc)) end
      end
    end

  elseif id == "done_success" then
    self.state = STATE.DESCRIBE; self.doc:remove(1, 1, math.huge, math.huge); core.redraw = true

  elseif id == "back_error" then
    self.state = self.plan and STATE.PLAN or STATE.DESCRIBE; core.redraw = true

  elseif id:match("^opn_%d+$") then
    local i   = tonumber(id:match("%d+"))
    local plug = store.installed[i]
    if plug and system.get_file_info(plug.file) then
      local ok, doc = pcall(core.open_doc, plug.file)
      if ok and doc then
        local node = core.root_view:get_active_node_default()
        local DocView = require "core.docview"
        if node then node:add_view(DocView(doc)) end
      end
    end

  elseif id:match("^del_%d+$") then
    local i = tonumber(id:match("%d+"))
    local plug = store.installed[i]
    if plug then
      os.remove(plug.file)
      table.remove(store.installed, i)
      save_store(); core.redraw = true
    end

  elseif id:match("^repo_btn_%d+$") then
    for _, btn in ipairs(self.buttons) do
      if btn.id == id and btn.url then
        local cmd = PLATFORM == "Windows" and ('start "" "' .. btn.url .. '"') or ('xdg-open "' .. btn.url .. '"')
        os.execute(cmd)
      end
    end
  end
end

-- ── AI actions ────────────────────────────────────────────────────────────────

function AIPluginGen:get_local_context()
  local ctx_files = {}
  local function scan_lua(dir, prefix)
    pcall(function()
      local files = system.list_dir(dir) or {}
      for _, f in ipairs(files) do
        if f:match("%.lua$") and #ctx_files < 20 then
          table.insert(ctx_files, prefix .. f)
        end
      end
    end)
  end
  scan_lua(USERDIR .. PATHSEP .. "plugins", "user-plugin:")
  if #ctx_files == 0 then return "" end
  return "LOCAL ENVIRONMENT CONTEXT (Existing User Plugins):\n" .. table.concat(ctx_files, ", ") .. "\nCRITICAL: If the requested feature logically belongs to an existing plugin from the list above, modify the existing plugin.\n\n"
end

function AIPluginGen:do_generate_plan()
  self.state = STATE.LOADING
  self.loading_start = system.get_time()
  self.error_msg = nil
  self.agy_conv_id = self.agy_conv_id or generate_uuid()
  core.redraw = true
  local user_input = self.doc:get_text(1, 1, math.huge, math.huge)

  local rejected_note = ""
  local rkeys = {}
  for h in pairs(store.rejected_hashes) do table.insert(rkeys, h) end
  if #rkeys > 0 then
    rejected_note = "Do NOT regenerate plans similar to these rejected approach hashes: " .. table.concat(rkeys, ", ") .. "\n"
  end

  local used_keys = {}
  local key_count = 0
  for stroke, _ in pairs(keymap.map) do
    if key_count < 25 then
      table.insert(used_keys, stroke)
      key_count = key_count + 1
    end
  end
  local key_note = #used_keys > 0 and ("Common used shortcuts: " .. table.concat(used_keys, ", ") .. "\n") or ""

  local ctx_note = self:get_local_context()

  local prompt = ([[
You are creating a plugin development plan for the Lite XL text editor.
%sUser request: "%s"
%s%s
Respond with ONLY the exact structured format. No preamble, no extra text.

[NAME] snake_case_name_here
[OVERVIEW] 2-3 sentence description of what this plugin does and why it's useful.
[COMPLEXITY] NUMBER_1_TO_10
[TIME] e.g. "~2 hours"
[WORTH] Recommended OR Situational OR Overkill
[DEPENDENCIES] comma-separated or None
[RESEARCH]
- finding 1
- finding 2
- finding 3
[/RESEARCH]
[CHALLENGES_FATAL]
- fatal challenge or None
[/CHALLENGES_FATAL]
[CHALLENGES_CONQUER]
- hard but solvable challenge
[/CHALLENGES_CONQUER]
[CHALLENGES_EASY]
- easy challenge
[/CHALLENGES_EASY]
[EDGE_CASES]
- edge case 1
- edge case 2
[/EDGE_CASES]
[DESIGN]
╔═══════════════════════════════╗
║  Plugin UI Sample             ║
║  ─────────────────────────── ║
║  ◈ Feature   ▶ Action   ●    ║
║  ① Item one  ▓▓▓▓▒░ 60%%     ║
║  ② Item two  ★ status: ok    ║
║  ─────────────────────────── ║
║  [ Confirm ]   [ Cancel ]    ║
╚═══════════════════════════════╝
[/DESIGN]
[SHORTCUTS]
ctrl+shift+x: description of what this does
[/SHORTCUTS]
[HOOKS]
core.DocView, core.command, style, core.keymap
[/HOOKS]
[TESTING]
- How to verify the plugin works
[/TESTING]
[OUTPUT_FILES]
plugins/plugin_name.lua
[/OUTPUT_FILES]
]]):format(ctx_note, user_input, rejected_note, key_note)

  self:run_ai(prompt, function(out, err)
    if err or not out or #out < 30 then
      self.state = STATE.ERROR
      self.error_msg = err or (self.engine == "cloud_api" and "Cloud AI returned no output" or "AGY returned no output")
      set_global_resume_fn(function() self:do_generate_plan() end)
      core.error("[AI Plugin Gen] Plan generation error: %s", tostring(self.error_msg))
      core.redraw = true; return
    end
    self.plan = parse_plan(out)
    self.plan_scroll = 0
    self.state = STATE.PLAN
    core.redraw = true
  end)
end

function AIPluginGen:do_redesign()
  if not self.plan then return end
  local user_input = self.doc:get_text(1, 1, math.huge, math.huge)
  local prompt = ('Create a complete, feature-rich Lite XL plugin based on this user description:\n"%s"\n'
    .. 'You MUST output exactly a new sample ASCII art UI preview.\n'
    .. 'Use varied box-drawing chars: ╔╗╚╝║═╠╣╦╩╬┌┐└┘│─█▓▒░▀▄▌▐◈●○▶▷◀★✓✗①②③④⑤\n'
    .. 'Output ONLY [DESIGN]...\nProvide a highly creative ASCII mockup here...\n[/DESIGN]. No other text.'):format(user_input)
  self:run_ai(prompt, function(out, err)
    if err or not out then return end
    if not self.plan then return end  -- plan was reset while AI was running
    local d = etag(out, "DESIGN")
    if d and #d > 5 then self.plan.design = d; core.redraw = true end
  end)
end

function AIPluginGen:do_build()
  if not self.plan then return end
  self.state = STATE.BUILDING
  self.loading_start = system.get_time()
  self.build_step = 0
  core.redraw = true

  local plan = self.plan
  local sc_hints = ""
  for _, sc in ipairs(plan.shortcuts) do
    sc_hints = sc_hints .. ('  keymap.add({ ["%s"] = "%s:toggle" })\n'):format(sc.key, plan.name)
  end

  local existing_code = ""
  if plan.out_files then
    for _, fname in ipairs(plan.out_files) do
      local path = USERDIR .. PATHSEP .. fname
      local f = io.open(path, "r")
      if f then
        existing_code = existing_code .. "\n=== EXISTING " .. fname .. " ===\n" .. f:read("*a") .. "\n"
        f:close()
      end
    end
  end
  local existing_note = existing_code ~= "" and ("\nExisting code to modify:\n" .. existing_code) or ""

  local prompt = ([[
Write a COMPLETE, WORKING Lite XL plugin in Lua based on the following approved plan:

%s
%s
Rules:
1. First line MUST be: -- mod-version:3
2. Add a descriptive header comment
3. Use proper Lite XL APIs (core, style, command, keymap, renderer)
4. Wrap risky code in pcall
5. Register commands and keyboard shortcuts
6. Plugin must work immediately after being placed in plugins/ dir
7. If existing code was provided, you MUST modify it to include the new features without breaking existing functionality. Output the ENTIRE modified file.

Shortcut hints:
%s

Output the COMPLETE Lua source between [PLUGIN_CODE] and [/PLUGIN_CODE] tags ONLY.

[PLUGIN_CODE]
-- write complete plugin code here
[/PLUGIN_CODE]
]]):format(plan.raw, existing_note, sc_hints)

  self.build_step = 1

  self:run_ai(prompt, function(out, err)
    if err or not out then
      self.state = STATE.ERROR
      self.error_msg = err or (self.engine == "cloud_api" and "Cloud AI returned no output" or "AGY returned no output")
      -- Store resume function for auto-healer
      set_global_resume_fn(function() self:do_build() end)
      core.error("[AI Plugin Gen] Build error: %s", tostring(self.error_msg))
      core.redraw = true; return
    end

    self.build_step = 2

    -- Extract code block
    local code = out:match("%[PLUGIN_CODE%]\n?(.-)\n?%[/PLUGIN_CODE%]")
               or out:match("```lua\n(.-)\n```")
    if not code or #code < 30 then
      self.state = STATE.ERROR
      self.error_msg = "Could not extract valid Lua code from AI response"
      core.redraw = true; return
    end

    -- Determine file path
    local filename = plan.files[1] or ("plugins/" .. plan.name .. ".lua")
    local filepath = USERDIR .. PATHSEP .. filename

    self.build_step = 3

    -- Write file
    local fp = io.open(filepath, "w")
    if not fp then
      self.state = STATE.ERROR
      self.error_msg = "Failed to write: " .. filepath
      core.redraw = true; return
    end
    fp:write(code); fp:close()

    self.build_step = 4

    -- Register in store
    table.insert(store.installed, {
      name = plan.name, file = filepath,
      desc = plan.overview, ts   = os.time(),
    })
    save_store()

    -- Notify auto-healer about the new plugin file
    table.insert(_G.auto_healer_new_plugins, {name=plan.name, file=filepath})

    self.build_step = 5

    -- Hot-reload attempt
    core.add_thread(function()
      coroutine.yield(0.2)
      local ok2, load_err = pcall(dofile, filepath)
      if not ok2 then
        core.log("[AI Plugin Gen] Load warning for %s: %s", plan.name, tostring(load_err))
        pcall(command.perform, "antigravity:submit",
          ("[AI Plugin Gen] Newly generated plugin '%s' has a load error.\n```\n%s\n```\nFile: %s\nPlease fix it."):format(
          plan.name, tostring(load_err), filepath))
      end
      self.result = {name=plan.name, file=filepath}
      self.state  = STATE.SUCCESS
      core.redraw = true
    end)
  end)
end

-- ── Command Registration ──────────────────────────────────────────────────────
local plugin_view

command.add(nil, {
  ["ai-plugin-gen:toggle"] = function()
    local sidebar = _G.get_sidebar_node and _G.get_sidebar_node()
    if plugin_view and core.root_view.root_node:get_node_for_view(plugin_view) then
      local node = core.root_view.root_node:get_node_for_view(plugin_view)
      if sidebar and node == sidebar then
        if sidebar.active_view == plugin_view then
          node:close_view(core.root_view.root_node, plugin_view)
          plugin_view = nil
        else
          node:set_active_view(plugin_view)
        end
      else
        node:close_view(core.root_view.root_node, plugin_view)
        plugin_view = nil
      end
    else
      if not plugin_view then plugin_view = AIPluginGen() end
      if sidebar then
        sidebar:add_view(plugin_view)
        sidebar:set_active_view(plugin_view)
      else
        local root = core.root_view.root_node
        local child = root
        while child.a do child = child.a end
        sidebar = child:split("right", child, { y = true }, true)
        sidebar:add_view(plugin_view)
        core.set_active_view(plugin_view)
        -- Register the sidebar so activity_bar can find it
        rawset(_G, "_ag_sidebar_node", sidebar)
      end
    end
    core.redraw = true
  end
})

-- ── Auto-healer: aware of new plugins ────────────────────────────────────────
-- The auto_healer checks _G.auto_healer_new_plugins for context.
-- Also expose a public resume signal for the healer to call back into.
core.log("[AI Plugin Gen] Loaded — use 'ai-plugin-gen:toggle' or Activity Bar \u{f0e7} to start.")

command.add(
  function()
    return (type(core.active_view) == "table" and core.active_view.name == "AI Plugins")
        or (type(core.active_view) == "table" and core.active_view.doc == rawget(_G, "ai_plugin_gen_last_doc"))
  end,
  {
    ["ai-plugin-gen:paste"] = function()
      local text = system.get_clipboard()
      local last_doc = rawget(_G, "ai_plugin_gen_last_doc")
      if text and last_doc then
        last_doc:text_input(text)
      end
    end
  }
)
keymap.add({  ["cmd+v"] = "ai-plugin-gen:paste" })

