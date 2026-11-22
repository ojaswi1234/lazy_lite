-- mod-version:3
-- AI Analyzer for AI Project Visualizer
-- Multi-provider AI client supporting Groq, Ollama / Ollama Cloud, Google Gemini,
-- OpenAI, and Anthropic. Reads stored keys from AI Sidebar (ai_api_keys.json).
-- Two-pass strategy: Pass 1 = per-file summaries, Pass 2 = graph generation.

local core = require "core"
local common = require "core.common"

local function ensure_dir(path)
  if path and not system.get_file_info(path) then
    pcall(common.mkdirp, path)
  end
end

local AIAnalyzer = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Universal Clean Display Text Sanitizer (UTF-8 to Clean ASCII)
-- Eliminates FreeType missing-glyph fallback '?' characters in Lite XL
-- ─────────────────────────────────────────────────────────────────────────────
local UTF8_REPLACEMENTS = {
  -- Quotes & Apostrophes
  { "\226\128\156", '"' },    -- “
  { "\226\128\157", '"' },    -- ”
  { "\226\128\158", '"' },    -- „
  { "\194\171", '"' },        -- «
  { "\194\187", '"' },        -- »
  { "\226\128\152", "'" },    -- ‘
  { "\226\128\153", "'" },    -- ’
  { "\226\128\154", "'" },    -- ‚
  { "\226\128\178", "'" },    -- ′
  { "\194\180", "'" },        -- ´
  { "\226\128\185", "'" },    -- ‹
  { "\226\128\186", "'" },    -- ›
  -- Dashes & Hyphens
  { "\226\128\147", "-" },    -- – en dash
  { "\226\136\146", "-" },    -- − minus sign
  { "\226\128\144", "-" },    -- ‐ hyphen
  { "\226\128\145", "-" },    -- ‑ non-breaking hyphen
  -- Ellipsis
  { "\226\128\166", "..." },  -- …
  -- Arrows
  { "\226\134\146", "->" },   -- →
  { "\226\134\144", "<-" },   -- ←
  { "\226\134\148", "<->" },  -- ↔
  { "\226\135\146", "=>" },   -- ⇒
  { "\226\135\144", "<=" },   -- ⇐
  { "\226\135\148", "<=>" },  -- <=>
  { "\226\158\148", "->" },   -- ➔
  { "\226\158\156", "->" },   -- ➜
  { "\226\158\164", "->" },   -- ➤
  { "\226\150\186", ">" },    -- ►
  { "\226\151\132", "<" },    -- ◄
  { "\226\150\178", "^" },    -- ▲
  { "\226\150\188", "v" },    -- ▼
  { "\226\134\145", "^" },    -- ↑
  { "\226\134\147", "v" },    -- ↓
  { "\226\134\152", "\\" },   -- ↘
  { "\226\134\151", "/" },    -- ↗
  -- Bullets & Dots
  { "\226\128\162", "*" },    -- •
  { "\194\183", "*" },        -- ·
  { "\226\151\166", "*" },    -- ◦
  { "\226\151\143", "*" },    -- ●
  { "\226\151\139", "*" },    -- ○
  { "\226\150\170", "*" },    -- ▪
  { "\226\150\171", "*" },    -- ▫
  { "\226\150\160", "*" },    -- ■
  { "\226\150\161", "*" },    -- □
  { "\226\151\134", "*" },    -- ◆
  { "\226\151\135", "*" },    -- ◇
  { "\226\128\163", ">" },    -- ‣
  -- Checks & Crosses
  { "\226\156\147", "[OK]" }, -- ✓
  { "\226\156\148", "[OK]" }, -- ✔
  { "\226\156\133", "[OK]" }, -- ✅
  { "\226\156\151", "[X]" },  -- ✗
  { "\226\156\152", "[X]" },  -- ✘
  { "\226\156\149", "[X]" },  -- ✕
  { "\226\156\150", "[X]" },  -- ✖
  { "\226\157\140", "[X]" },  -- ❌
  -- Emojis & Common Icons
  { "\226\154\160\239\184\143", "[!]" }, -- ⚠️
  { "\226\154\160", "[!]" },             -- ⚠
  { "\226\157\151", "[!]" },             -- ❗
  { "\226\157\147", "[?]" },             -- ❓
  { "\240\159\146\161", "[*]" },         -- 💡
  { "\240\159\154\128", "[^]" },         -- 🚀
  { "\240\159\148\165", "[*]" },         -- 🔥
  { "\240\159\155\161\239\184\143", "[SEC]" }, -- 🛡️
  { "\240\159\155\161", "[SEC]" },             -- 🛡
  { "\226\154\161", "[*]" },             -- ⚡
  { "\240\159\148\146", "[SEC]" },       -- 🔒
  { "\240\159\148\145", "[KEY]" },       -- 🔑
  { "\240\159\147\166", "[PKG]" },       -- 📦
  { "\240\159\147\129", "[DIR]" },       -- 📁
  { "\240\159\147\132", "[DOC]" },       -- 📄
  { "\240\159\148\141", "[FIND]" },      -- 🔍
  { "\240\159\142\175", "[*]" },         -- 🎯
  { "\226\173\144", "[*]" },             -- ⭐
  { "\226\132\185\239\184\143", "[i]" }, -- ℹ️
  { "\226\132\185", "[i]" },             -- ℹ
  { "\226\154\153\239\184\143", "[CFG]" }, -- ⚙️
  { "\226\154\153", "[CFG]" },             -- ⚙
  { "\240\159\148\167", "[TOOL]" },      -- 🔧
  { "\240\159\147\138", "[STAT]" },      -- 📊
  { "\240\159\147\136", "[UP]" },        -- 📈
  { "\240\159\147\137", "[DOWN]" },      -- 📉
  -- Math & Comparisons
  { "\226\137\165", ">=" },   -- ≥
  { "\226\137\164", "<=" },   -- ≤
  { "\226\137\160", "!=" },   -- ≠
  { "\226\137\136", "~=" },   -- ≈
  { "\195\151", "x" },        -- ×
  { "\195\183", "/" },        -- ÷
  { "\194\177", "+/-" },      -- ±
  { "\194\176", " deg" },     -- °
  { "\194\181", "u" },        -- µ
  -- Whitespace & Invisible Characters
  { "\194\160", " " },        -- \u00a0 NBSP
  { "\226\128\137", " " },    -- \u2009 thin space
  { "\226\128\139", "" },     -- \u200b zero-width space
  { "\226\128\175", " " },    -- \u202f narrow NBSP
  { "\239\187\191", "" },     -- \ufeff BOM
  -- Box Drawing
  { "\226\148\128", "-" },    -- ─
  { "\226\148\129", "-" },    -- ━
  { "\226\148\130", "|" },    -- │
  { "\226\148\131", "|" },    -- ┃
  { "\226\148\140", "+" },    -- ┌
  { "\226\148\144", "+" },    -- ┐
  { "\226\148\148", "+" },    -- └
  { "\226\148\152", "+" },    -- ┘
  { "\226\148\156", "+" },    -- ├
  { "\226\148\164", "+" },    -- ┤
  { "\226\148\172", "+" },    -- ┬
  { "\226\148\180", "+" },    -- ┴
  { "\226\148\188", "+" },    -- ┼
  -- Accented Latin Characters
  { "\195\169", "e" }, { "\195\168", "e" }, { "\195\170", "e" }, { "\195\171", "e" },
  { "\195\160", "a" }, { "\195\161", "a" }, { "\195\162", "a" }, { "\195\163", "a" }, { "\195\164", "a" },
  { "\195\172", "i" }, { "\195\173", "i" }, { "\195\174", "i" }, { "\195\175", "i" },
  { "\195\178", "o" }, { "\195\179", "o" }, { "\195\180", "o" }, { "\195\181", "o" }, { "\195\182", "o" },
  { "\195\185", "u" }, { "\195\186", "u" }, { "\195\187", "u" }, { "\195\188", "u" },
  { "\195\177", "n" }, { "\195\167", "c" },
  { "\195\137", "E" }, { "\195\136", "E" }, { "\195\128", "A" }, { "\195\129", "A" },
  { "\195\147", "O" }, { "\195\154", "U" }, { "\195\145", "N" }, { "\195\135", "C" },
}

local function clean_display_text(s)
  if not s or s == "" then return "" end
  s = tostring(s)

  -- Fast path: if 100% ASCII (all byte values <= 127), return immediately
  local has_non_ascii = false
  for i = 1, #s do
    if s:byte(i) > 127 then
      has_non_ascii = true
      break
    end
  end
  if not has_non_ascii then return s end

  -- Dashes with surrounding whitespace
  s = s:gsub("%s*\226\128\148%s*", " - ") -- em dash
  s = s:gsub("%s*\226\128\149%s*", " - ") -- horizontal bar

  -- Deterministic multi-byte replacements
  for _, pair in ipairs(UTF8_REPLACEMENTS) do
    s = s:gsub(pair[1], pair[2])
  end

  -- Catch-all for any remaining multi-byte sequences or non-ASCII bytes
  s = s:gsub("[\194-\223][\128-\191]", " ")
  s = s:gsub("[\224-\239][\128-\191][\128-\191]", " ")
  s = s:gsub("[\240-\244][\128-\191][\128-\191][\128-\191]", " ")
  s = s:gsub("[\128-\255]", " ")

  return s
end

AIAnalyzer.clean_display_text = clean_display_text


-- ─────────────────────────────────────────────────────────────────────────────
-- Extension allowlist for source files
-- ─────────────────────────────────────────────────────────────────────────────
local ALLOWED_EXTENSIONS = {
  lua=true, py=true, ts=true, js=true, go=true, rs=true, java=true,
  c=true, cpp=true, cc=true, cs=true, rb=true, php=true, swift=true,
  kt=true, ex=true, exs=true, sh=true, md=true, json=true, yaml=true,
  yml=true, toml=true, html=true, css=true, sql=true, r=true, scala=true,
  clj=true, hs=true, ml=true, fs=true, tsx=true, jsx=true, xml=true,
  gradle=true, txt=true,
}

-- Supported providers configuration
AIAnalyzer.PROVIDERS = {
  groq = {
    name = "Groq",
    default_model = "openai/gpt-oss-120b",
    models = { "openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.8-27b" },
    endpoint = "https://api.groq.com/openai/v1/chat/completions",
    type = "openai_chat",
    env_keys = { "GROQ_API_KEY" },
  },
  ollama = {
    name = "Ollama Cloud",
    default_model = "gpt-oss:120b",
    models = { "gpt-oss:120b", "deepseek-v4.1-flash", "mistral-large-3:675b", "gemma4:31b", "nemotron-3-nano:30b" },
    endpoint = "https://ollama.com/v1/chat/completions",
    type = "openai_chat",
    env_keys = { "OLLAMA_API_KEY", "OLLAMA_HOST" },
  },
  gemini = {
    name = "Google Gemini",
    default_model = "gemini-3.8-flash",
    models = { "gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-3.1-pro-preview" },
    endpoint = "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent",
    type = "gemini",
    env_keys = { "GEMINI_API_KEY", "GOOGLE_API_KEY" },
  },
  openai = {
    name = "OpenAI",
    default_model = "gpt-4o",
    models = { "gpt-4o", "gpt-4o-mini" },
    endpoint = "https://api.openai.com/v1/chat/completions",
    type = "openai_chat",
    env_keys = { "OPENAI_API_KEY" },
  },
  anthropic = {
    name = "Anthropic",
    default_model = "claude-3-7-sonnet-20250219",
    models = { "claude-3-7-sonnet-20250219", "claude-3-5-sonnet-20241022" },
    endpoint = "https://api.anthropic.com/v1/messages",
    type = "anthropic",
    env_keys = { "ANTHROPIC_API_KEY" },
  },
}

-- Cancel flag
local _cancel_requested = false
local _active = false

-- ─────────────────────────────────────────────────────────────────────────────
-- Minimal JSON encoder
-- ─────────────────────────────────────────────────────────────────────────────
local function json_encode(val, depth)
  depth = depth or 0
  if depth > 50 then return '"..."' end
  local t = type(val)
  if val == nil then
    return "null"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    if val ~= val then return "null" end
    return tostring(val)
  elseif t == "string" then
    local s = val
      :gsub('\\', '\\\\')
      :gsub('"',  '\\"')
      :gsub('\n', '\\n')
      :gsub('\r', '\\r')
      :gsub('\t', '\\t')
    s = s:gsub('[\0-\31]', function(c)
      return string.format('\\u%04x', string.byte(c))
    end)
    return '"' .. s .. '"'
  elseif t == "table" then
    local is_array = (#val > 0)
    if is_array then
      local parts = {}
      for _, v in ipairs(val) do
        table.insert(parts, json_encode(v, depth + 1))
      end
      return '[' .. table.concat(parts, ',') .. ']'
    else
      local parts = {}
      for k, v in pairs(val) do
        if type(k) == "string" then
          table.insert(parts, json_encode(k, depth + 1) .. ':' .. json_encode(v, depth + 1))
        end
      end
      return '{' .. table.concat(parts, ',') .. '}'
    end
  end
  return '"[unsupported]"'
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Minimal JSON decoder (recursive descent)
-- ─────────────────────────────────────────────────────────────────────────────
local function json_decode(str)
  local pos = 1

  local function skip_ws()
    while pos <= #str and str:sub(pos, pos):match('%s') do
      pos = pos + 1
    end
  end

  local function parse_value()
    skip_ws()
    if pos > #str then return nil end
    local c = str:sub(pos, pos)

    if c == '"' then
      pos = pos + 1
      local result = {}
      while pos <= #str do
        local ch = str:sub(pos, pos)
        if ch == '"' then
          pos = pos + 1
          return table.concat(result)
        elseif ch == '\\' then
          pos = pos + 1
          local esc = str:sub(pos, pos)
          if     esc == '"'  then table.insert(result, '"')
          elseif esc == '\\' then table.insert(result, '\\')
          elseif esc == '/'  then table.insert(result, '/')
          elseif esc == 'n'  then table.insert(result, '\n')
          elseif esc == 'r'  then table.insert(result, '\r')
          elseif esc == 't'  then table.insert(result, '\t')
          elseif esc == 'u'  then
            local hex = str:sub(pos + 1, pos + 4)
            pos = pos + 4
            local code = tonumber(hex, 16) or 63
            if code < 128 then
              table.insert(result, string.char(code))
            else
              table.insert(result, '?')
            end
          else
            table.insert(result, esc)
          end
          pos = pos + 1
        else
          table.insert(result, ch)
          pos = pos + 1
        end
      end
      return table.concat(result)

    elseif c == '{' then
      pos = pos + 1
      local obj = {}
      skip_ws()
      if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
      while true do
        skip_ws()
        local key = parse_value()
        if type(key) ~= "string" then break end
        skip_ws()
        if str:sub(pos, pos) == ':' then pos = pos + 1 end
        local val = parse_value()
        obj[key] = val
        skip_ws()
        local sep = str:sub(pos, pos)
        if sep == ',' then pos = pos + 1
        elseif sep == '}' then pos = pos + 1; break
        else break end
      end
      return obj

    elseif c == '[' then
      pos = pos + 1
      local arr = {}
      skip_ws()
      if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
      while true do
        local val = parse_value()
        table.insert(arr, val)
        skip_ws()
        local sep = str:sub(pos, pos)
        if sep == ',' then pos = pos + 1
        elseif sep == ']' then pos = pos + 1; break
        else break end
      end
      return arr

    elseif str:sub(pos, pos + 3) == 'true' then
      pos = pos + 4; return true
    elseif str:sub(pos, pos + 4) == 'false' then
      pos = pos + 5; return false
    elseif str:sub(pos, pos + 3) == 'null' then
      pos = pos + 4; return nil
    else
      local num_str = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
      if num_str then
        pos = pos + #num_str
        return tonumber(num_str)
      end
    end
    return nil
  end

  local ok, result = pcall(parse_value)
  if ok then return result end
  return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Load all saved API keys from AI Sidebar and environment
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.load_saved_keys()
  local keys = {}
  local sep = package.config:sub(1,1)

  -- 1. Try USERDIR/scripts/ai_api_keys.json (shared with AI Sidebar)
  local udir = rawget(_G, "USERDIR") or (os.getenv("USERPROFILE") or os.getenv("HOME") or "") .. "/.config/lite-xl"
  local key_paths = {
    udir .. sep .. "scripts" .. sep .. "ai_api_keys.json",
    udir .. sep .. "ai_api_keys.json",
    udir:gsub('\\', '/') .. "/scripts/ai_api_keys.json",
  }

  for _, path in ipairs(key_paths) do
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      if content and #content > 0 then
        local data = json_decode(content)
        if type(data) == "table" then
          for k, v in pairs(data) do
            if type(v) == "string" and #v > 0 then
              keys[k:lower()] = v
            end
          end
        end
      end
    end
  end

  -- 2. Try .env files
  local env_paths = {
    udir .. sep .. ".env",
    udir .. sep .. "scripts" .. sep .. ".env",
  }
  for _, path in ipairs(env_paths) do
    local f = io.open(path, "r")
    if f then
      for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v then
          v = v:gsub('^["\']', ''):gsub('["\']$', '')
          if k == "GROQ_API_KEY" and not keys["groq"] then keys["groq"] = v end
          if (k == "GEMINI_API_KEY" or k == "GOOGLE_API_KEY") and not keys["gemini"] then keys["gemini"] = v end
          if (k == "OLLAMA_API_KEY" or k == "OLLAMA_HOST") and not keys["ollama"] then keys["ollama"] = v end
          if k == "OPENAI_API_KEY" and not keys["openai"] then keys["openai"] = v end
          if k == "ANTHROPIC_API_KEY" and not keys["anthropic"] then keys["anthropic"] = v end
        end
      end
      f:close()
    end
  end

  -- 3. Environment variables
  if not keys["groq"] and os.getenv("GROQ_API_KEY") then keys["groq"] = os.getenv("GROQ_API_KEY") end
  if not keys["gemini"] and (os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")) then
    keys["gemini"] = os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")
  end
  if not keys["ollama"] and (os.getenv("OLLAMA_API_KEY") or os.getenv("OLLAMA_HOST")) then
    keys["ollama"] = os.getenv("OLLAMA_API_KEY") or os.getenv("OLLAMA_HOST")
  end
  if not keys["openai"] and os.getenv("OPENAI_API_KEY") then keys["openai"] = os.getenv("OPENAI_API_KEY") end
  if not keys["anthropic"] and os.getenv("ANTHROPIC_API_KEY") then keys["anthropic"] = os.getenv("ANTHROPIC_API_KEY") end

  -- 4. Plugin config overrides
  local ok, core = pcall(require, "core")
  if ok and core and core.config and core.config.plugins and core.config.plugins.ai_project_visualizer then
    local cfg = core.config.plugins.ai_project_visualizer
    if cfg.api_key and #cfg.api_key > 0 then
      local prov = (cfg.provider or "gemini"):lower()
      keys[prov] = cfg.api_key
    end
  end

  return keys
end

-- Save a key into ai_api_keys.json (shared with AI Sidebar)
function AIAnalyzer.save_key(provider, key)
  local udir = rawget(_G, "USERDIR") or (os.getenv("USERPROFILE") or os.getenv("HOME") or "") .. "/.config/lite-xl"
  local sep = package.config:sub(1,1)
  local scripts_dir = udir .. sep .. "scripts"
  ensure_dir(scripts_dir)
  local path = scripts_dir .. sep .. "ai_api_keys.json"

  local keys = {}
  local f = io.open(path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    if content and #content > 0 then
      keys = json_decode(content) or {}
    end
  end
  keys[provider:lower()] = key
  local wf = io.open(path, "w")
  if wf then
    wf:write(json_encode(keys))
    wf:close()
    return true
  end
  return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Determine active provider, model, and key
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.get_active_provider(preferred_provider, preferred_model)
  local keys = AIAnalyzer.load_saved_keys()

  -- If preferred provider specified and has key
  if preferred_provider and keys[preferred_provider:lower()] then
    local p = preferred_provider:lower()
    local pinfo = AIAnalyzer.PROVIDERS[p]
    local m = preferred_model or (pinfo and pinfo.default_model)
    return p, m, keys[p]
  end

  -- Priority auto-detection
  local priority = { "groq", "ollama", "gemini", "openai", "anthropic" }
  for _, p in ipairs(priority) do
    if keys[p] and #keys[p] > 0 then
      local pinfo = AIAnalyzer.PROVIDERS[p]
      local m = pinfo and pinfo.default_model or "default"
      return p, m, keys[p]
    end
  end

  -- Default fallback if nothing has key
  return "gemini", "gemini-3.8-flash", nil
end

local function get_temp_file(suffix)
  local tmp_dir = os.getenv("TEMP") or os.getenv("TMP")
  if not tmp_dir or #tmp_dir == 0 then
    local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
    tmp_dir = home .. "/.config/lite-xl/tempfiles"
  end
  local sep = package.config:sub(1,1)
  local fname = string.format("apv_%d_%d%s", os.time(), math.random(10000, 99999), suffix or ".json")
  if sep == "\\" then
    return tmp_dir:gsub("/", "\\") .. "\\" .. fname
  else
    return tmp_dir .. "/" .. fname
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Execute curl and return response body or nil + error (non-blocking process)
-- ─────────────────────────────────────────────────────────────────────────────
local _current_proc = nil

local function curl_post(url, json_body, headers)
  local tmp_in = get_temp_file("_in.json")

  local f, err = io.open(tmp_in, "wb")
  if not f then return nil, "Cannot open temp file (" .. tostring(tmp_in) .. "): " .. tostring(err) end
  f:write(json_body)
  f:close()

  local bin = "curl"
  if PLATFORM == "Windows" or package.config:sub(1,1) == "\\" then
    if system.get_file_info("C:\\Windows\\System32\\curl.exe") then
      bin = "C:\\Windows\\System32\\curl.exe"
    else
      bin = "curl.exe"
    end
  end

  local cmd_args = { bin, "-s", "-S", "-X", "POST" }
  if PLATFORM == "Windows" or package.config:sub(1,1) == "\\" then
    table.insert(cmd_args, "-k")
    table.insert(cmd_args, "--ssl-no-revoke")
  end

  for k, v in pairs(headers or {}) do
    table.insert(cmd_args, "-H")
    table.insert(cmd_args, string.format("%s: %s", k, v))
  end

  table.insert(cmd_args, "--data-binary")
  table.insert(cmd_args, "@" .. tmp_in)
  table.insert(cmd_args, url)

  local p = nil
  local start_err = nil
  if process and process.start then
    local ok, res = pcall(process.start, cmd_args, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      stdin  = process.REDIRECT_DISCARD,
    })
    if ok and res then
      p = res
    else
      start_err = tostring(res)
    end
  end

  if not p then
    pcall(os.remove, tmp_in)
    return nil, "Failed to start curl process: " .. tostring(start_err or "process.start unavailable")
  end

  _current_proc = p
  local out_parts = {}
  local err_parts = {}
  local start_time = system.get_time()
  local timeout = 120

  while p:running() do
    if _cancel_requested then
      pcall(function() p:kill() end)
      pcall(os.remove, tmp_in)
      _current_proc = nil
      return nil, "Request cancelled"
    end

    while true do
      local chunk = p:read_stdout(65536)
      if chunk and #chunk > 0 then
        table.insert(out_parts, chunk)
      else
        break
      end
    end
    while true do
      local echunk = p:read_stderr(4096)
      if echunk and #echunk > 0 then
        table.insert(err_parts, echunk)
      else
        break
      end
    end

    if system.get_time() - start_time > timeout then
      pcall(function() p:kill() end)
      pcall(os.remove, tmp_in)
      _current_proc = nil
      return nil, "Request timed out after " .. timeout .. " seconds"
    end

    if coroutine.running() then
      coroutine.yield(0.02)
    else
      system.sleep(0.02)
    end
  end

  while true do
    local chunk = p:read_stdout(65536)
    if chunk and #chunk > 0 then
      table.insert(out_parts, chunk)
    else
      break
    end
  end
  while true do
    local echunk = p:read_stderr(4096)
    if echunk and #echunk > 0 then
      table.insert(err_parts, echunk)
    else
      break
    end
  end

  pcall(os.remove, tmp_in)
  _current_proc = nil

  local body = table.concat(out_parts)
  local err_out = table.concat(err_parts)

  if #body == 0 and #err_out > 0 then
    return nil, "curl error: " .. err_out
  end
  return body, nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Call provider API (handles Gemini, OpenAI-compatible, Anthropic)
-- ─────────────────────────────────────────────────────────────────────────────
local function call_provider(provider, model, api_key, prompt, is_json)
  local pinfo = AIAnalyzer.PROVIDERS[provider]
  if not pinfo then return nil, "Unknown provider: " .. tostring(provider) end
  model = model or pinfo.default_model

  -- Strip provider prefix if present (e.g. "ollama/gpt-oss:120b" -> "gpt-oss:120b")
  if model and provider and model:match("^" .. provider .. "/") then
    model = model:sub(#provider + 2)
  end

  if pinfo.type == "gemini" then
    local url = string.format(pinfo.endpoint, model) .. "?key=" .. api_key
    local req = {
      contents = { { parts = { { text = prompt } }, role = "user" } },
      generationConfig = {
        temperature = 0.2,
        maxOutputTokens = 8192,
      }
    }
    if is_json then
      req.generationConfig.responseMimeType = "application/json"
    end
    local body, err = curl_post(url, json_encode(req), { ["Content-Type"] = "application/json" })
    if not body then return nil, err end
    local parsed = json_decode(body)
    if not parsed then return nil, "Invalid JSON from Gemini: " .. body:sub(1, 120) end
    if parsed.error then return nil, (parsed.error.message or "Gemini API error") end
    if parsed.candidates and parsed.candidates[1] and parsed.candidates[1].content and parsed.candidates[1].content.parts then
      return parsed.candidates[1].content.parts[1].text, nil
    end
    return nil, "No candidates in Gemini response"

  elseif pinfo.type == "openai_chat" then
    local endpoint = pinfo.endpoint
    local auth_header = "Bearer " .. api_key
    if provider == "ollama" then
      if api_key and (api_key:find("^https?://") or api_key:find("|")) then
        local base = api_key:match("^(https?://[^|]+)")
        if base then endpoint = base:gsub("/+$", "") .. "/v1/chat/completions" end
      elseif not api_key or #api_key <= 20 then
        endpoint = "http://127.0.0.1:11434/v1/chat/completions"
      end
    end

    local messages = {
      { role = "system", content = "You are a senior software architecture analyst. Follow instructions carefully and output exact format requested." },
      { role = "user", content = prompt }
    }
    local req = {
      model = model,
      messages = messages,
      temperature = 0.2,
      max_completion_tokens = 8192,
    }
    if is_json then
      req.response_format = { type = "json_object" }
    end

    local headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = auth_header,
    }
    local body, err = curl_post(endpoint, json_encode(req), headers)
    if not body then return nil, err end
    local parsed = json_decode(body)
    if not parsed then return nil, "Invalid JSON from " .. pinfo.name .. ": " .. body:sub(1, 120) end
    if parsed.error then
      if type(parsed.error) == "table" and parsed.error.failed_generation then
        local failed = parsed.error.failed_generation
        if type(failed) == "string" and #failed > 20 then
          return failed, nil
        end
      end
      local emsg = type(parsed.error) == "table" and parsed.error.message or tostring(parsed.error)
      return nil, pinfo.name .. " error: " .. emsg
    end
    if parsed.choices and parsed.choices[1] and parsed.choices[1].message then
      local msg = parsed.choices[1].message
      local text = (msg.content and #msg.content > 0) and msg.content or msg.reasoning
      if text and #text > 0 then return text, nil end
    end
    return nil, "No response content from " .. pinfo.name

  elseif pinfo.type == "anthropic" then
    local headers = {
      ["Content-Type"] = "application/json",
      ["x-api-key"] = api_key,
      ["anthropic-version"] = "2023-06-01",
    }
    local req = {
      model = model,
      messages = { { role = "user", content = prompt } },
      max_tokens = 4096,
      temperature = 0.2,
    }
    local body, err = curl_post(pinfo.endpoint, json_encode(req), headers)
    if not body then return nil, err end
    local parsed = json_decode(body)
    if not parsed then return nil, "Invalid JSON from Anthropic" end
    if parsed.error then return nil, (parsed.error.message or "Anthropic error") end
    if parsed.content and parsed.content[1] and parsed.content[1].text then
      return parsed.content[1].text, nil
    end
    return nil, "No content from Anthropic"
  end

  return nil, "Unsupported provider: " .. tostring(provider)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Read first N lines from a file
-- ─────────────────────────────────────────────────────────────────────────────
local function read_first_lines(filepath, n)
  local full = filepath:gsub('\\', '/')
  if not full:match("^%a:/") and not full:match("^/") and core.project_dir then
    full = core.project_dir:gsub('\\', '/') .. "/" .. full
  end
  local f = io.open(full, "r")
  if not f then
    f = io.open(filepath, "r")
  end
  if not f then return "" end
  local lines = {}
  local count = 0
  for line in f:lines() do
    table.insert(lines, line)
    count = count + 1
    if count >= n then break end
  end
  f:close()
  return table.concat(lines, "\n")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Cancel ongoing analysis
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.cancel()
  _cancel_requested = true
  _active = false
  if _current_proc then
    pcall(function() _current_proc:kill() end)
    _current_proc = nil
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Main analysis entry point
-- file_list: array of absolute file paths
-- on_progress(msg): status update callback
-- on_complete(diagrams): called with parsed diagram data
-- on_error(msg): called on failure
-- opts: { provider = "groq"|"ollama"|"gemini", model = "..." } (optional)
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.analyze(file_list, on_progress, on_complete, on_error, opts)
  _cancel_requested = false
  _active = true

  opts = opts or {}
  local provider, model, api_key = AIAnalyzer.get_active_provider(opts.provider, opts.model)

  if not api_key or #api_key == 0 then
    on_error("No API key found for " .. (provider:upper()) .. ". Set key in AI Sidebar or click [AI Provider] in toolbar.")
    return
  end

  local pinfo = AIAnalyzer.PROVIDERS[provider]
  local pname = pinfo and pinfo.name or provider

  local ignored_patterns = {
    "[/\\]node_modules[/\\]",
    "[/\\]site%-packages[/\\]",
    "[/\\]my_env[/\\]",
    "[/\\]myenv[/\\]",
    "[/\\]venv[/\\]",
    "[/\\]%.venv[/\\]",
    "[/\\]env[/\\]",
    "[/\\]vendor[/\\]",
    "[/\\]dist[/\\]",
    "[/\\]build[/\\]",
    "[/\\]target[/\\]",
    "[/\\]%.git[/\\]",
    "%.min%.js$",
    "%.min%.css$",
  }

  -- Filter to allowed source files
  local source_files = {}
  for _, path in ipairs(file_list) do
    local ext = path:match('%.([^%.]+)$')
    if ext and ALLOWED_EXTENSIONS[ext:lower()] then
      local norm = "/" .. path:gsub('\\', '/') .. "/"
      local skip = false
      for _, pat in ipairs(ignored_patterns) do
        if norm:find(pat) then skip = true; break end
      end
      if not skip then
        table.insert(source_files, path)
      end
    end
  end

  if #source_files == 0 then
    on_error("No supported source files found in project.")
    return
  end

  local file_set = {}
  for _, f in ipairs(source_files) do
    local norm = f:gsub('\\', '/')
    file_set[norm] = true
    file_set[f] = true
  end

  on_progress(string.format("[%s/%s] Pass 1: Scanning %d source files for real symbols...", pname, model, #source_files))

  -- ── PASS 1: Extract factual symbols from files in batches of 20 ───────────
  local summaries = {}
  local last_error = nil
  local BATCH_SIZE = 20

  for i = 1, #source_files, BATCH_SIZE do
    if _cancel_requested then
      on_error("Analysis cancelled.")
      return
    end

    local batch = {}
    for j = i, math.min(i + BATCH_SIZE - 1, #source_files) do
      local path = source_files[j]
      local content = read_first_lines(path, 150)
      local rel = path:gsub('\\', '/')
      if core.project_dir then
        local pdir = core.project_dir:gsub('\\', '/') .. "/"
        if rel:sub(1, #pdir) == pdir then
          rel = rel:sub(#pdir + 1)
        end
      end
      table.insert(batch, "FILE: " .. rel .. "\n" .. content)
    end

    local batch_num = math.ceil(i / BATCH_SIZE)
    local total_batches = math.ceil(#source_files / BATCH_SIZE)
    on_progress(string.format("[%s] Scanning batch %d/%d...", pname, batch_num, total_batches))

    local prompt = "You are a code scanner. For each source file below, output EXACTLY ONE line:\n" ..
                   "<relative_path>: [tier: ingress|application|domain|integration|persistence|infrastructure] " ..
                   "[tech: <ONLY real imports/requires visible in the file>] " ..
                   "<list the EXACT exported class names, function names, and variable names as they appear in the file. " ..
                   "If the file imports a database driver, cache client, or external service SDK, name it EXACTLY as imported.>\n\n" ..
                   "RULES:\n" ..
                   "- Use ONLY information visible in the file content below. DO NOT guess or invent anything.\n" ..
                   "- Use the EXACT class/function name as written in the source code (case-sensitive).\n" ..
                   "- If a file has no exports or is empty, write: <relative_path>: [tier: infrastructure] [tech: none] no exports\n" ..
                   "- Do NOT suggest or recommend tools not seen in the file.\n\n" ..
                   "FILES:\n" .. table.concat(batch, "\n\n---\n\n")

    local text, err = call_provider(provider, model, api_key, prompt, false)
    if text then
      for line in text:gmatch('[^\n]+') do
        if #line > 2 then
          table.insert(summaries, line)
        end
      end
    else
      last_error = err
      core.log("[AI Visualizer] Batch %d failed: %s", batch_num, tostring(err))
    end
  end

  if _cancel_requested then
    on_error("Analysis cancelled.")
    return
  end

  if #summaries == 0 then
    local detail = last_error and (": " .. tostring(last_error)) or ". Check your key and network."
    on_error("Failed to scan files via " .. pname .. detail)
    return
  end

  -- ── Build symbol allowlist from Pass 1 summaries ──────────────────────────
  -- Used in Pass 2 aggressive pruning: nodes whose label tokens do NOT appear
  -- in any summary are considered hallucinated and are DELETED entirely.
  local summary_text = table.concat(summaries, "\n")
  local summary_lower = summary_text:lower()

  local symbol_set = {}
  for token in summary_text:gmatch('[%w_%.%-]+') do
    if #token >= 3 then
      symbol_set[token:lower()] = true
    end
  end

  on_progress(string.format("[%s] Pass 2: Generating grounded architecture diagrams...", pname))

  -- ── PASS 2: Generate structured graph strictly from summaries ──────────────
  local pass2_prompt = [[You are an enterprise software architect. Based on the codebase summaries below, construct comprehensive production-grade architecture diagrams as valid JSON following the C4 model and cloud engineering standards.

SUMMARIES:
]] .. summary_text .. [[

Generate a JSON object with a top-level "diagrams" array containing diagrams for these 6 distinct architectural views:
1. "System Topology (C4)": High-level container/service topology showing Client/Ingress -> Backend Services -> Message Queues -> Databases -> External Cloud APIs.
2. "Data Flow & Lifecycle": Step-by-step pipeline tracing incoming requests through validation, business logic, persistence, and async events.
3. "Component & Domain Architecture": In-process clean architecture showing Controllers -> Application Services -> Domain Aggregates/Models -> Repositories.
4. "Security, Auth & Ingress": Gateways, CORS/WAF, JWT token validation, authorization guards, session stores, sanitization.
5. "Event Brokers & Async Pipelines": Message queues, event producers, background workers, scheduled jobs, webhooks, and dead-letter queues.
6. "Persistence & Cloud Infrastructure": Relational DBs, Document DBs, Redis caches, S3 object storage, configuration, and connection pools.

CRITICAL ARCHITECTURE GUIDELINES (STRICT CODE GROUNDING):
- STRICT GROUNDING IN REPOSITORY: Represent ONLY the actual components, modules, files, and technologies that TRULY EXIST in the provided file summaries. NEVER hallucinate, invent, or assume third-party tools (such as Kafka, Redis, RabbitMQ, PostgreSQL, MongoDB, AWS S3, Stripe, Docker, Kubernetes) unless they are explicitly imported, configured, or referenced in the project files!
- ACCURATE SIZING WITHOUT ARTIFICIAL QUOTAS: Do NOT generate fictional filler nodes. If a project has 4 real components, represent those 4 components accurately and cleanly. If a category (e.g. Event Brokers) is not used in the codebase, accurately show how the codebase handles events (e.g. in-memory callbacks, EventEmitter, Promises) or create a focused diagram of the actual components.
- EXTERNAL CLOUD & INFRASTRUCTURE: Only mark "external": true if the code contains an active client or configuration connecting to that external service.
- AI ARCHITECTURAL SUGGESTIONS (MUST BE LABELED): If you recommend an industry-standard architectural enhancement (e.g. adding a cache, rate limiter, or message queue) that is NOT yet implemented in the codebase, you MUST set "suggested": true, "external": true, omit "file", and prefix "desc" with "[AI Suggestion] Recommended addition for ...". This ensures developers know it is a suggestion rather than existing code.
- INTERCONNECTIVITY: Aim for realistic dependency links between components. Every node must connect into the dependency graph with at least one edge.
- EXPLICIT PROTOCOL EDGES: Every edge must describe the interaction with a protocol type ("http", "grpc", "sql", "cache", "event", "queue", "auth", "inject") and clear label.

JSON SCHEMA:
{
  "diagrams": [
    {
      "category": "System Topology (C4)",
      "nodes": [
        {
          "id": "node_id",
          "label": "ExactNameFromSummaries",
          "file": "path/file.ts",
          "line": 1,
          "type": "gateway|endpoint|service|domain|database|cache|queue|cloud|auth|middleware|storage|component",
          "tier": "ingress|application|domain|integration|persistence|infrastructure",
          "tech": "OnlyRealImportsFromSummaries",
          "desc": "One sentence describing its operational role",
          "external": false,
          "suggested": false
        }
      ],
      "edges": [
        {
          "from": "node1_id",
          "to": "node2_id",
          "label": "protocol / action description",
          "type": "http|grpc|sql|cache|event|queue|auth|inject"
        }
      ]
    }
  ]
}

Output ONLY the raw valid JSON. Do not wrap in markdown or add commentary.]]
  local text, err = call_provider(provider, model, api_key, pass2_prompt, true)
  if err then
    on_error("Diagram generation failed with " .. pname .. ": " .. err)
    return
  end

  if _cancel_requested then
    on_error("Analysis cancelled.")
    return
  end

  if not text or #text == 0 then
    on_error("Empty response from " .. pname .. " API.")
    return
  end

  on_progress("Parsing diagram data...")

  local clean_text = text
  if clean_text then
    local inner = clean_text:match("```%w*\n?(.-)\n?```")
    if inner then clean_text = inner end
    -- Clean up accidental double-braces or double-commas in LLM arrays
    clean_text = clean_text:gsub("}%s*{%s*}%s*,?%s*{", "},{"):gsub("}%s*{%s*}", "}")
    clean_text = clean_text:gsub(",%s*,+", ",")
    clean_text = clean_text:gsub(",%s*([%]%}])", "%1")
    local s = clean_text:find('{', 1, true)
    local e = clean_text:reverse():find('}', 1, true)
    if s and e then
      local end_pos = #clean_text - e + 1
      if end_pos >= s then
        clean_text = clean_text:sub(s, end_pos)
      end
    end
  end

  local parsed = json_decode(clean_text)
  if not parsed and text then
    local s = text:find('{')
    if s then parsed = json_decode(text:sub(s)) end
  end

  if not parsed or not parsed.diagrams then
    on_error("Could not parse diagram structure from " .. pname .. " response.")
    return
  end

  -- Validate and normalize diagram data
  local diagrams = {}
  for _, diagram in ipairs(parsed.diagrams) do
    if diagram.category and diagram.nodes and diagram.edges then
      diagram.category = clean_display_text(diagram.category)
      local valid_nodes = {}
      local node_ids = {}
      for _, node in ipairs(diagram.nodes) do
        if node.id and node.label then
          node.w        = 150
          node.h        = 48
          node.type     = (node.type or "component"):lower()
          node.tier     = (node.tier or "application"):lower()
          node.label    = clean_display_text(node.label)
          node.tech     = clean_display_text(node.tech or "")
          node.desc     = clean_display_text(node.desc or "")
          node.external  = (node.external == true or node.external == "true")
          node.suggested = (node.suggested == true or node.suggested == "true")
          node.line      = tonumber(node.line) or 1
          local is_file_real = false
          if node.file and not node.external then
            local nf = node.file:gsub('\\', '/')
            if file_set[nf] or file_set[node.file] then
              is_file_real = true
            else
              local base = nf:match('[^/]+$') or nf
              for f in pairs(file_set) do
                if f:match('[^/]+$') == base then
                  node.file = f
                  is_file_real = true
                  break
                end
              end
            end
          end
          -- ── Aggressive two-pass grounding ────────────────────────────────────
          -- Pass A: check if node's file is real in the repo
          if not is_file_real then
            node.suggested = true
          end
          -- Pass B: if still not suggested, verify label tokens exist in summaries.
          -- This catches hallucinated labels with invented file paths.
          if not node.suggested and not node.external then
            local lbl_lower = node.label:lower()
            -- Check if any significant token from the label appears in summaries
            local found_in_summary = false
            for token in lbl_lower:gmatch('[%w_]+') do
              if #token >= 3 and symbol_set[token] then
                found_in_summary = true
                break
              end
            end
            if not found_in_summary then
              node.suggested = true
            end
          end
          -- Pass C: for suggested nodes, check if at least label tokens appear
          -- anywhere in summary_lower. If completely absent, DELETE the node.
          if node.suggested then
            local lbl_lower = (node.label or ""):lower()
            local id_lower  = (node.id or ""):lower()
            local any_token_found = false
            for token in lbl_lower:gmatch('[%w_]+') do
              if #token >= 3 and summary_lower:find(token, 1, true) then
                any_token_found = true
                break
              end
            end
            if not any_token_found then
              -- Also try node id tokens
              for token in id_lower:gmatch('[%w_]+') do
                if #token >= 3 and summary_lower:find(token, 1, true) then
                  any_token_found = true
                  break
                end
              end
            end
            -- Allow suggested=true nodes that have an [AI Suggestion] desc
            -- (these are intentional recommendations, not hallucinations)
            local is_intentional_suggestion = node.desc and node.desc:find('%[AI Suggestion%]', 1, true)
            if not any_token_found and not is_intentional_suggestion then
              -- Hallucinated: skip this node entirely
              goto continue_node
            end
          end
          table.insert(valid_nodes, node)
          node_ids[node.id] = true
          ::continue_node::
        end
      end

      local valid_edges = {}
      for _, edge in ipairs(diagram.edges) do
        if edge.from and edge.to and node_ids[edge.from] and node_ids[edge.to] then
          edge.type  = (edge.type or "http"):lower()
          edge.label = edge.label or ""
          edge.label = clean_display_text(edge.label or "")
          table.insert(valid_edges, edge)
        end
      end

      if #valid_nodes > 0 then
        diagrams[diagram.category] = {
          nodes = valid_nodes,
          edges = valid_edges,
        }
      end
    end
  end

  if next(diagrams) == nil then
    on_error("No valid diagrams could be extracted. The project might be empty or the response had invalid node links.")
    return
  end

  _active = false
  on_complete(diagrams)
end


-- ─────────────────────────────────────────────────────────────────────────────
-- Graph Semantic Query & Local Architecture Reasoner
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.local_architecture_query(query, diagram, category)
  if not diagram or not diagram.nodes or #diagram.nodes == 0 then
    return {
      answer = "The architecture diagram has no active components to analyze.",
      involved_nodes_map = {},
      provider = "local"
    }
  end

  local q_lower = query:lower()
  local stop_words = {
    ["the"]=true, ["a"]=true, ["an"]=true, ["is"]=true, ["are"]=true,
    ["was"]=true, ["were"]=true, ["in"]=true, ["on"]=true, ["at"]=true,
    ["to"]=true, ["for"]=true, ["of"]=true, ["and"]=true, ["or"]=true,
    ["how"]=true, ["does"]=true, ["do"]=true, ["what"]=true, ["where"]=true,
    ["why"]=true, ["which"]=true, ["can"]=true, ["use"]=true, ["used"]=true,
    ["work"]=true, ["flow"]=true, ["this"]=true, ["that"]=true, ["with"]=true
  }

  local terms = {}
  for word in q_lower:gmatch("[%a%d_%-]+") do
    if #word >= 2 and not stop_words[word] then
      table.insert(terms, word)
    end
  end

  -- Score nodes based on query relevance
  local scored_nodes = {}
  for _, n in ipairs(diagram.nodes) do
    local nid   = (n.id or ""):lower()
    local nlbl  = (n.label or ""):lower()
    local ntech = (n.tech or ""):lower()
    local ntype = (n.type or ""):lower()
    local ntier = (n.tier or ""):lower()
    local nfile = (n.file or ""):lower()
    local ndesc = (n.desc or n.description or ""):lower()

    local score = 0
    if #terms > 1 and (nlbl:find(q_lower, 1, true) or nid:find(q_lower, 1, true)) then
      score = score + 50
    end

    for _, term in ipairs(terms) do
      if nid == term or nlbl == term then
        score = score + 30
      elseif nid:find(term, 1, true) or nlbl:find(term, 1, true) then
        score = score + 20
      elseif ntech:find(term, 1, true) then
        score = score + 15
      elseif ntype:find(term, 1, true) or ntier:find(term, 1, true) then
        score = score + 10
      elseif ndesc:find(term, 1, true) or nfile:find(term, 1, true) then
        score = score + 8
      end
    end

    if score > 0 then
      table.insert(scored_nodes, { node = n, score = score })
    end
  end

  table.sort(scored_nodes, function(a, b) return a.score > b.score end)

  local matched_map = {}
  local matched_nodes = {}
  for i = 1, math.min(6, #scored_nodes) do
    local n = scored_nodes[i].node
    matched_map[n.id] = true
    table.insert(matched_nodes, n)
  end

  -- If NO nodes matched, honestly explain without fabricating random nodes
  if #matched_nodes == 0 then
    local sample_names = {}
    for i = 1, math.min(5, #diagram.nodes) do
      local n = diagram.nodes[i]
      table.insert(sample_names, n.label or n.id)
    end
    local answer = string.format([[### Architectural Query Result
No components in the **%s** subsystem directly match your query: `"%s"`.

**Available Components in this Subsystem:**
%s

**Suggestions:**
- Try searching for specific service names (e.g. `gateway`, `api`, `auth`, `db`).
- Check if the component belongs to another category tab in the left sidebar.
- Inspect the full component list in the **Inspect** drawer.]],
      category or "Active", query,
      "- " .. table.concat(sample_names, "\n- "))
    return {
      answer = answer,
      involved_nodes_map = {},
      provider = "local"
    }
  end

  -- Analyze connectivity among matched nodes
  local node_id_set = {}
  for _, n in ipairs(matched_nodes) do node_id_set[n.id] = true end

  local in_callers = {}
  local out_deps = {}
  for _, e in ipairs(diagram.edges or {}) do
    if node_id_set[e.to] then
      in_callers[e.to] = in_callers[e.to] or {}
      table.insert(in_callers[e.to], e.from)
    end
    if node_id_set[e.from] then
      out_deps[e.from] = out_deps[e.from] or {}
      table.insert(out_deps[e.from], e.to)
    end
  end

  local comp_table_lines = {
    "| Component | Tier | Technology | Callers | Downstream | Status |",
    "|:---|:---:|:---:|:---|:---|:---:|"
  }
  for _, n in ipairs(matched_nodes) do
    -- Trace inbound callers and downstream dependencies: Callers: [%s] -> Downstream: [%s]
    local callers = in_callers[n.id] and table.concat(in_callers[n.id], ", ") or "None"
    local deps    = out_deps[n.id] and table.concat(out_deps[n.id], ", ") or "None"
    local status  = (#diagram.edges > 0 and (in_callers[n.id] or out_deps[n.id])) and "Active" or "Healthy"
    local line = string.format("| `%s` | %s | %s | %s | %s | %s |",
      n.label or n.id, n.tier or "logic", n.tech or n.type or "service", callers, deps, status)
    table.insert(comp_table_lines, line)
  end

  local answer = string.format([[### Architecture Insight: %s

**Query:** `"%s"`  
**Category:** %s  
**Identified Components (%d):**

%s

#### Request Flow & Interaction
%s

#### Architectural Context
These components participate in the active **%s** DAG. Requests entering these components execute domain logic before persisting state or delegating to downstream microservices.]],
    matched_nodes[1].label or matched_nodes[1].id,
    query,
    category or "General Architecture",
    #matched_nodes,
    table.concat(comp_table_lines, "\n"),
    (#diagram.edges > 0 and "Direct dependencies and message exchanges are highlighted in glowing purple neon across the diagram canvas." or "Standalone service layer operating without direct edge coupling in this view."),
    category or "General")

  return {
    answer = clean_display_text(answer),
    involved_nodes_map = matched_map,
    provider = "local"
  }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Asynchronous Architecture AI Question Answering with Real LLM Engine
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.ask_architecture_ai(query, diagram, category, opts, on_complete, on_error)
  opts = opts or {}
  local provider, model, api_key = AIAnalyzer.get_active_provider(opts.provider, opts.model)

  -- If no provider configured or provider is "local" / no keys, use intelligent local analyzer
  if not provider or (provider ~= "ollama" and (not api_key or #api_key == 0)) then
    local res = AIAnalyzer.local_architecture_query(query, diagram, category)
    on_complete(res)
    return
  end

  -- Serialize diagram components and connections
  local comp_lines = {}
  local node_id_lookup = {}
  for _, n in ipairs(diagram.nodes or {}) do
    node_id_lookup[n.id] = n
    local tech_str = (n.tech and n.tech ~= "") and (" [" .. n.tech .. "]") or ""
    local file_str = (n.file and n.file ~= "") and (" (source: " .. n.file .. ")") or ""
    table.insert(comp_lines, string.format("- ID: %s | Label: %s | Tier: %s | Type: %s%s%s",
      n.id, n.label or n.id, n.tier or "logic", n.type or "service", tech_str, file_str))
  end

  local edge_lines = {}
  for _, e in ipairs(diagram.edges or {}) do
    table.insert(edge_lines, string.format("- %s -> %s%s",
      e.from, e.to, (e.label and e.label ~= "") and (" (" .. e.label .. ")") or ""))
  end

  local prompt = string.format([[You are a principal software architect analyzing a codebase architecture diagram.
Subsystem Category: %s

Active Components in Diagram:
%s

Connections and Dependencies:
%s

User Question: %s

INSTRUCTIONS:
1. Provide a detailed, professional architectural explanation in clear Markdown.
2. Structure your response with sections (e.g. ## Overview, ## Component Breakdown & Status, ## Request & Data Flow, ## Architectural Considerations).
3. When presenting component inventories, comparisons, or multi-field attributes, format them as standard GitHub Flavored Markdown tables with clear headers and alignment (e.g. | Component | Role | Tier | Status |).
4. Identify the EXACT component IDs from the diagram that are relevant to this question.
5. STRICT RULE: in "involved_nodes", ONLY include component IDs that appear verbatim in the "Active Components in Diagram" list above. Do NOT invent new component IDs.

Respond with a JSON object ONLY:
{
  "answer": "Detailed Markdown explanation answering the user's question...",
  "involved_nodes": ["component_id_1", "component_id_2"]
}]], category or "Architecture", table.concat(comp_lines, "\n"), table.concat(edge_lines, "\n"), query)

  core.add_thread(function()
    local body, err = call_provider(provider, model, api_key, prompt, true)
    if not body or err then
      -- Fallback to intelligent local reasoning on network / LLM failure
      local local_res = AIAnalyzer.local_architecture_query(query, diagram, category)
      local_res.provider = (provider or "AI") .. " (offline)"
      on_complete(local_res)
      return
    end

    -- Clean JSON fences if present
    local clean_body = body:gsub("^%s*```json%s*", ""):gsub("^%s*```%s*", ""):gsub("%s*```%s*$", ""):gsub("^%s*", ""):gsub("%s*$", "")

    local parsed = json_decode(clean_body)
    local answer = nil
    local involved_nodes = {}

    if parsed and type(parsed) == "table" and parsed.answer then
      answer = parsed.answer
      if type(parsed.involved_nodes) == "table" then
        involved_nodes = parsed.involved_nodes
      end
    else
      -- If raw text or non-JSON, use body as answer and extract node IDs mentioned in body
      answer = clean_body
      for _, n in ipairs(diagram.nodes or {}) do
        if clean_body:find(n.id, 1, true) or (n.label and clean_body:find(n.label, 1, true)) then
          table.insert(involved_nodes, n.id)
        end
      end
    end

    -- Strictly ground involved_nodes against actual diagram nodes
    local grounded_map = {}
    for _, nid in ipairs(involved_nodes) do
      if type(nid) == "string" and node_id_lookup[nid] then
        grounded_map[nid] = true
      end
    end

    on_complete({
      answer = clean_display_text(answer),
      involved_nodes_map = grounded_map,
      provider = provider
    })
  end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- AI-Powered Deep Architecture Audit
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.run_ai_architecture_audit(diagram, category, static_findings, opts, on_complete, on_error)
  opts = opts or {}
  local provider, model, api_key = AIAnalyzer.get_active_provider(opts.provider, opts.model)

  local comp_lines = {}
  local node_id_lookup = {}
  for _, n in ipairs(diagram.nodes or {}) do
    node_id_lookup[n.id] = n
    local tech_str = (n.tech and n.tech ~= "") and (" [" .. n.tech .. "]") or ""
    table.insert(comp_lines, string.format("- ID: %s | Label: %s | Tier: %s | Type: %s%s",
      n.id, n.label or n.id, n.tier or "logic", n.type or "service", tech_str))
  end

  local edge_lines = {}
  for _, e in ipairs(diagram.edges or {}) do
    table.insert(edge_lines, string.format("- %s -> %s%s",
      e.from, e.to, (e.label and e.label ~= "") and (" (" .. e.label .. ")") or ""))
  end

  local findings_summary = {}
  for _, f in ipairs(static_findings or {}) do
    table.insert(findings_summary, string.format("- [%s] %s (Nodes: %s)",
      (f.type or "info"):upper(), f.title or "N/A", table.concat(f.nodes or {}, ", ")))
  end

  if not provider or (provider ~= "ollama" and (not api_key or #api_key == 0)) then
    if on_complete then
      on_complete({
        findings = static_findings or {},
        ai_summary = "Static topological rules audit completed. To enable AI deep audits, configure an API key or run Ollama.",
        provider = "local"
      })
    end
    return
  end

  local prompt = string.format([[You are a Principal Software Architect performing an architecture review of the following system design.
Subsystem / Domain: %s

Components:
%s

Connections / Dependencies:
%s

Preliminary Rule-Based Findings:
%s

Analyze this graph for non-trivial architecture anti-patterns, scalability bottlenecks, resilience hazards, data sovereignty issues, or missing circuit breakers / caching.
Provide concrete findings. For each finding, return:
- type: "critical" | "warning" | "info"
- title: concise title
- nodes: array of relevant component IDs matching the system components above ONLY
- desc: technical description of the violation
- impact: system failure or scalability consequences
- recommendation: concrete remediation pattern

Respond with a JSON object ONLY:
{
  "ai_summary": "2-3 sentence executive summary of overall architecture health.",
  "additional_findings": [
    {
      "type": "warning",
      "title": "Anti-pattern title",
      "nodes": ["node_id"],
      "desc": "Description...",
      "impact": "Impact...",
      "recommendation": "Recommendation..."
    }
  ]
}]], category or "General", table.concat(comp_lines, "\n"), table.concat(edge_lines, "\n"), table.concat(findings_summary, "\n"))

  core.add_thread(function()
    local body, err = call_provider(provider, model, api_key, prompt, true)
    if not body or err then
      if on_complete then
        on_complete({
          findings = static_findings or {},
          ai_summary = "AI query unavailable. Displaying static topological audit.",
          provider = (provider or "AI") .. " (offline)"
        })
      end
      return
    end

    local clean_body = body:gsub("^%s*```json%s*", ""):gsub("^%s*```%s*", ""):gsub("%s*```%s*$", ""):gsub("^%s*", ""):gsub("%s*$", "")
    local parsed = json_decode(clean_body)
    local all_findings = {}
    for _, f in ipairs(static_findings or {}) do table.insert(all_findings, f) end

    local ai_summary = "AI Architecture Doctor completed deep analysis."
    if parsed and type(parsed) == "table" then
      if parsed.ai_summary then ai_summary = parsed.ai_summary end
      if type(parsed.additional_findings) == "table" then
        for _, af in ipairs(parsed.additional_findings) do
          if af.title and af.type then
            local valid_nodes = {}
            for _, nid in ipairs(af.nodes or {}) do
              if node_id_lookup[nid] then table.insert(valid_nodes, nid) end
            end
            if #valid_nodes > 0 or not af.nodes or #af.nodes == 0 then
              af.nodes = valid_nodes
              af.source = "ai"
              af.title = clean_display_text(af.title)
              af.desc = clean_display_text(af.desc)
              af.impact = clean_display_text(af.impact)
              af.recommendation = clean_display_text(af.recommendation)
              table.insert(all_findings, af)
            end
          end
        end
      end
    end

    if on_complete then
      on_complete({
        findings = all_findings,
        ai_summary = clean_display_text(ai_summary),
        provider = provider
      })
    end
  end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Graph AI: BFS Flow Path Tracing (Shortest Dependency Path)
-- ─────────────────────────────────────────────────────────────────────────────
function AIAnalyzer.find_flow_path(edges, from_id, to_id)
  if not edges or not from_id or not to_id or from_id == to_id then return nil end
  local adj = {}
  for _, e in ipairs(edges) do
    if e.from and e.to then
      adj[e.from] = adj[e.from] or {}
      table.insert(adj[e.from], { to = e.to, edge = e })
    end
  end

  local queue = { { node = from_id, path = { from_id }, edges = {} } }
  local visited = { [from_id] = true }

  while #queue > 0 do
    local curr = table.remove(queue, 1)
    if curr.node == to_id then
      return {
        path = curr.path,
        edges = curr.edges,
        hops = #curr.edges,
        is_direct = true
      }
    end

    for _, neighbor in ipairs(adj[curr.node] or {}) do
      if not visited[neighbor.to] then
        visited[neighbor.to] = true
        local next_path = {}
        for _, n in ipairs(curr.path) do table.insert(next_path, n) end
        table.insert(next_path, neighbor.to)

        local next_edges = {}
        for _, ed in ipairs(curr.edges) do table.insert(next_edges, ed) end
        table.insert(next_edges, neighbor.edge)

        table.insert(queue, { node = neighbor.to, path = next_path, edges = next_edges })
      end
    end
  end

  return nil
end

function AIAnalyzer.find_any_path(edges, from_id, to_id)
  local direct = AIAnalyzer.find_flow_path(edges, from_id, to_id)
  if direct then return direct end

  -- Bidirectional search
  local adj = {}
  for _, e in ipairs(edges or {}) do
    if e.from and e.to then
      adj[e.from] = adj[e.from] or {}
      table.insert(adj[e.from], { to = e.to, edge = e, reversed = false })
      adj[e.to] = adj[e.to] or {}
      table.insert(adj[e.to], { to = e.from, edge = e, reversed = true })
    end
  end

  local queue = { { node = from_id, path = { from_id }, edges = {} } }
  local visited = { [from_id] = true }

  while #queue > 0 do
    local curr = table.remove(queue, 1)
    if curr.node == to_id then
      return {
        path = curr.path,
        edges = curr.edges,
        hops = #curr.edges,
        is_direct = false
      }
    end

    for _, neighbor in ipairs(adj[curr.node] or {}) do
      if not visited[neighbor.to] then
        visited[neighbor.to] = true
        local next_path = {}
        for _, n in ipairs(curr.path) do table.insert(next_path, n) end
        table.insert(next_path, neighbor.to)

        local next_edges = {}
        for _, ed in ipairs(curr.edges) do table.insert(next_edges, ed) end
        table.insert(next_edges, neighbor.edge)

        table.insert(queue, { node = neighbor.to, path = next_path, edges = next_edges })
      end
    end
  end
  return nil
end

AIAnalyzer.json_encode = json_encode
AIAnalyzer.json_decode = json_decode

return AIAnalyzer
