-- mod-version:3
-- Antigravity AI Sidebar — modern chat UI, Ctrl+Shift+A
-- Size-animation toggle (same pattern as built-in treeview).

local core    = require "core"
local config  = require "core.config"
local style   = require "core.style"
local tokenizer = require "core.tokenizer"
local syntax  = require "core.syntax"

local function graceful_kill(p)
  if not p then return end
  pcall(function() p:write("KILL\n") end)
  core.add_thread(function()
    coroutine.yield(0.1)
    pcall(function() p:kill() end)
  end)
end

local command = require "core.command"
local keymap  = require "core.keymap"
local View    = require "core.view"
local common  = require "core.common"
local process = require "process"
local system  = require "system"

-- ── Dynamic contrast helpers (same system as mossy_statusbar / mossy_treeview) ─
local function lum(r, g, b) return r*0.299 + g*0.587 + b*0.114 end

local function utf8_prev(text, i)
  if not i or i <= 0 then return 0 end
  i = i - 1
  while i > 0 do
    local b = text:byte(i + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    i = i - 1
  end
  return i
end

local function utf8_next(text, i)
  if not i or i >= #text then return #text end
  i = i + 1
  while i < #text do
    local b = text:byte(i + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    i = i + 1
  end
  return i
end

local function contrast_bg(base, pct)
  pct = pct or 0.08
  if type(base) ~= "table" then return base end
  local r,g,b,a = base[1],base[2],base[3],base[4] or 255
  if lum(r,g,b) > 128 then
    return { math.max(0,math.floor(r*(1-pct))), math.max(0,math.floor(g*(1-pct))), math.max(0,math.floor(b*(1-pct))), a }
  else
    return { math.min(255,math.floor(r+(255-r)*pct)), math.min(255,math.floor(g+(255-g)*pct)), math.min(255,math.floor(b+(255-b)*pct)), a }
  end
end

local function contrast_fg(bg)
  if type(bg) ~= "table" then return { 0,0,0,255 } end
  local r,g,b = bg[1],bg[2],bg[3]
  if lum(r,g,b) > 128 then
    -- light bg → near-black tinted text
    return { math.floor(r*0.15), math.floor(g*0.15), math.floor(b*0.15), 255 }
  else
    -- dark bg → near-white tinted text
    return { math.min(255,math.floor(r+(255-r)*0.85)), math.min(255,math.floor(g+(255-g)*0.85)), math.min(255,math.floor(b+(255-b)*0.85)), 255 }
  end
end

local function muted(fg, factor)
  factor = factor or 0.55
  return { math.floor(fg[1]*factor), math.floor(fg[2]*factor), math.floor(fg[3]*factor), 255 }
end

-- Recomputed every draw — automatically tracks theme changes
local function get_palette()
  local base = style.background or { 255,255,255,255 }
  local bg       = contrast_bg(base, 0.08)
  local bg_dark  = contrast_bg(base, 0.14)
  local bg_darker= contrast_bg(base, 0.20)
  local bg_input = contrast_bg(base, 0.04)
  local fg       = contrast_fg(bg)
  local fg_muted = muted(fg, 0.55)
  local fg_accent= muted(fg, 0.80)
  -- Message bubbles: user slightly darker bg, AI slightly lighter
  local bg_user  = contrast_bg(base, 0.18)
  local bg_ai    = contrast_bg(base, 0.06)
  -- Button colors derived from bg levels
  local bg_btn   = contrast_bg(base, 0.12)
  local bg_btnhl = contrast_bg(base, 0.22)
  -- Send button uses accent (green on light, teal-ish on dark)
  local sr,sg,sb = base[1],base[2],base[3]
  local bg_send  = { math.floor(sr*0.35+0.5), math.floor(sg*0.45+0.5), math.floor(sb*0.30+0.5), 255 }
  local bg_sendhl= { math.max(0,bg_send[1]-15), math.max(0,bg_send[2]-15), math.max(0,bg_send[3]-15), 255 }
  local fg_send  = contrast_fg(bg_send)
  local border   = contrast_bg(base, 0.16)
  return {
    bg          = bg,
    bg_dark     = bg_dark,
    bg_darker   = bg_darker,
    bg_input    = bg_input,
    bg_user_msg = bg_user,
    bg_ai_msg   = bg_ai,
    bg_btn      = bg_btn,
    bg_btn_hl   = bg_btnhl,
    bg_send     = bg_send,
    bg_send_hl  = bg_sendhl,
    fg          = fg,
    fg_muted    = fg_muted,
    fg_accent   = fg_accent,
    fg_user     = fg_accent,
    fg_ai       = fg,
    fg_code     = fg,
    fg_send     = fg_send,
    fg_label    = fg_muted,
    border      = border,
    border_input= bg_btnhl,
    dot_idle    = fg_muted,
    dot_run     = { 95, 140, 50, 255 },
    dot_err     = { 170, 56, 59, 255 },
    scrollbar   = border,
  }
end

-- ── Config ────────────────────────────────────────────────────────────────────
config.antigravity = {
  cli = (function()
    local applocal = os.getenv("LOCALAPPDATA") or ""
    local home     = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    for _, p in ipairs({
      applocal .. "/agy/bin/agy.exe",
      applocal .. "\\agy\\bin\\agy.exe",
      home .. "/.local/bin/agy",
      "agy",
    }) do
      local f = io.open(p, "rb")
      if f then f:close(); return p end
    end
    return "agy"
  end)(),

  target_width = 270,
  auto_skip_permissions = true,
  selected_model = nil,  -- nil means use CLI default

  actions = {
    { label = "Explain",  short = "E", prompt = "Explain what this code does in plain language, line by line." },
    { label = "Refactor", short = "R", prompt = "Refactor this for clarity, idiomatic style, and performance." },
    { label = "Fix",      short = "F", prompt = "Identify every bug and fix it. List each fix with a brief reason." },
    { label = "Tests",    short = "T", prompt = "Write thorough unit tests covering edge cases." },
    { label = "Docs",     short = "D", prompt = "Generate complete docstrings and inline comments." },
  },
}

-- ── PTY Bridge helper ─────────────────────────────────────────────────────────
-- This is the VS Code Copilot approach: spawn agy inside a real pseudoterminal
-- (Python pywinpty / pty module) so it produces output, then pipe from Python.
local function get_pty_bridge()
  -- The bridge lives alongside this plugin file
  local plugin_dir = USERDIR .. "/plugins"
  local bridge = plugin_dir .. "/agy_pty_bridge.py"
  local f = io.open(bridge, "r")
  if f then f:close(); return bridge end
  return nil
end

local function build_pty_argv(cli, args)
  local bridge = get_pty_bridge()
  local argv
  if bridge then
    argv = { "python", bridge, cli }
    for _, a in ipairs(args) do table.insert(argv, a) end
  else
    -- Fallback: direct invocation (may not produce output on Windows)
    argv = { cli }
    for _, a in ipairs(args) do table.insert(argv, a) end
  end
  return argv
end

local parse_pty_model_list

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function get_context()
  local av = core.active_view
  -- If the sidebar itself is focused, fallback to finding the most recent/first DocView
  if not av or not av.doc then
    local views = core.root_view.root_node:get_children()
    for _, v in ipairs(views) do
      if v.doc then
        av = v
        break
      end
    end
  end
  if not av or not av.doc then return nil, nil end
  
  local doc  = av.doc
  local name = doc.filename or "untitled"
  local l1, c1, l2, c2 = doc:get_selection()
  local text
  if l1 ~= l2 or c1 ~= c2 then
    text = doc:get_text(l1, c1, l2, c2)
  else
    text = table.concat(doc.lines)
  end
  return name, text
end

local function get_mention_suggestions(query)
  local results = {}
  local q = query:lower()
  for dir_name, file in core.get_project_files() do
    if file and file.type == "file" then
      local path = file.filename
      if path:lower():find(q, 1, true) then
        table.insert(results, path)
        if #results >= 10 then break end
      end
    end
  end
  return results
end



-- Wrap text into lines that fit within max_w pixels using given font
local function parse_inline(text)
  local segments = {}
  local s_idx = 1
  while s_idx <= #text do
    local b_s, b_e = text:find("%*%*.-%*%*", s_idx)
    local c_s, c_e = text:find("`.-`", s_idx)
    local l_s, l_e = text:find("%[.-%]%([^%)]+%)", s_idx) -- [link](url)
    
    local next_s, next_e, type
    local min_s = math.huge
    
    if b_s and b_s < min_s then min_s = b_s; next_s, next_e, type = b_s, b_e, "bold" end
    if c_s and c_s < min_s then min_s = c_s; next_s, next_e, type = c_s, c_e, "code" end
    if l_s and l_s < min_s then min_s = l_s; next_s, next_e, type = l_s, l_e, "link" end
    
    if next_s then
      if next_s > s_idx then table.insert(segments, { text = text:sub(s_idx, next_s - 1), type = "normal" }) end
      
      local inner_text = text:sub(next_s, next_e)
      if type == "bold" then
        table.insert(segments, { text = inner_text:sub(3, -3), type = "bold" })
      elseif type == "code" then
        table.insert(segments, { text = inner_text:sub(2, -2), type = "code" })
      elseif type == "link" then
        local label, url = inner_text:match("%[(.-)%]%(([^%)]+)%)")
        -- If the link label itself contains code, e.g. [`code`](url), unwrap it
        if label:match("^`.-`$") then
          label = label:sub(2, -2)
          table.insert(segments, { text = label, type = "code_link", url = url })
        else
          table.insert(segments, { text = label, type = "link", url = url })
        end
      end
      s_idx = next_e + 1
    else
      table.insert(segments, { text = text:sub(s_idx), type = "normal" })
      break
    end
  end
  return segments
end

local function wrap_segments(segments, base_font, code_font, max_w)
  local lines = {}
  local cur_line = {}
  local cur_w = 0
  
  local function get_font(type) return (type == "code" or type == "code_link") and code_font or base_font end
  
  local function push_word(word, type)
    local f = get_font(type)
    local w = f:get_width(word)
    if cur_w + w > max_w and cur_w > 0 then
      table.insert(lines, cur_line)
      cur_line = {}
      cur_w = 0
      -- drop leading space on new line if normal text
      if word == " " then return end
    end
    table.insert(cur_line, { text = word, type = type, font = f, width = w })
    cur_w = cur_w + w
  end

  for _, seg in ipairs(segments) do
    if seg.type == "code" or seg.type == "code_link" then
      -- don't split inline code if possible, just push it whole or split by chunks if truly massive
      push_word(seg.text, seg.type)
    else
      -- split text by spaces but keep the spaces
      for word in seg.text:gmatch("%S+%s*") do
        push_word(word, seg.type)
      end
      -- capture trailing space if any
      if seg.text:match("%s$") and not seg.text:match("%S") then push_word(" ", seg.type) end
    end
  end
  if #cur_line > 0 then table.insert(lines, cur_line) end
  return lines
end

local function wrap_raw_text(font, text, max_w)
  local lines = {}
  for raw_line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if font:get_width(raw_line) <= max_w then
      table.insert(lines, raw_line)
    else
      local cur = ""
      for word in (raw_line .. " "):gmatch("(%S+)%s") do
        local try = cur == "" and word or (cur .. " " .. word)
        if font:get_width(try) > max_w then
          if #cur > 0 then table.insert(lines, cur); cur = word
          else
            local char_cur = ""
            for i = 1, #word do
              local char = word:sub(i, i)
              if font:get_width(char_cur .. char) > max_w then table.insert(lines, char_cur); char_cur = char
              else char_cur = char_cur .. char end
            end
            cur = char_cur
          end
        else cur = try end
      end
      if #cur > 0 then table.insert(lines, cur) end
    end
  end
  return lines
end

local function parse_blocks(text, base_font, code_font, max_w)
  local blocks = {}
  local is_code = false
  local cur_text = ""
  local cur_lang = ""
  
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local lang_match = line:match("^%s*```(%w*)")
    if lang_match then
      if #cur_text > 0 then
        cur_text = cur_text:gsub("\n$", "")
        if is_code then
          table.insert(blocks, { type = "code", lang = cur_lang, raw_lines = wrap_raw_text(code_font, cur_text, max_w) })
        else
          table.insert(blocks, { type = "text", raw = cur_text })
        end
      end
      cur_text = ""
      is_code = not is_code
      if is_code then cur_lang = lang_match end
    else
      cur_text = cur_text .. line .. "\n"
    end
  end
  
  if #cur_text > 0 then
    cur_text = cur_text:gsub("\n$", "")
    if is_code then
      table.insert(blocks, { type = "code", lang = cur_lang, raw_lines = wrap_raw_text(code_font, cur_text, max_w) })
    else
      table.insert(blocks, { type = "text", raw = cur_text })
    end
  end
  
  -- post-process text blocks line by line for headers and lists
  local final_blocks = {}
  for _, blk in ipairs(blocks) do
    if blk.type == "code" then
      table.insert(final_blocks, blk)
    else
      for line in (blk.raw .. "\n"):gmatch("([^\n]*)\n") do
        if #line > 0 then
          local header = line:match("^%s*(#+)%s")
          local list = line:match("^%s*[%-%*]%s")
          local level = header and #header or 0
          
          -- strip header symbols for parsing
          if header then line = line:gsub("^%s*#+%s", "") end
          
          local segments = parse_inline(line)
          -- adjust fonts for headers
          local f = (level > 0) and (style.big_font or base_font) or base_font
          local wrapped = wrap_segments(segments, f, code_font, max_w - (list and f:get_width("• ") or 0))
          table.insert(final_blocks, { type = "paragraph", level = level, list = list ~= nil, wrapped_lines = wrapped })
        else
          table.insert(final_blocks, { type = "empty" })
        end
      end
    end
  end
  return final_blocks
end

-- ── View ──────────────────────────────────────────────────────────────────────
local AGView    = View:extend()
local instance  = nil
local node_built = false

-- ── Model list parser ─────────────────────────────────────────────────────────
local function parse_model_list(raw)
  local models = {}
  for line in raw:gmatch("([^\n]+)") do
    line = line:match("^%s*(.-)%s*$")
    if #line > 0 then
      local limited = line:lower():match("limit") or line:lower():match("quota")
                   or line:lower():match("unavail") or line:lower():match("exhausted")
                   or line:lower():match("exceeded") or line:lower():match("over")
      local name = line:gsub("%s*%(.*%)%s*$", ""):gsub("%s+$", "")
      if #name > 0 then
        table.insert(models, { name = name, limited = limited and true or false })
      end
    end
  end
  return models
end

-- Parse real model names from agy PTY bridge output
-- Filters out spinner animation lines and "Fetching..." status lines
local function parse_pty_model_list(raw)
  local models = {}
  local seen = {}
  for line in (raw .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    line = line:match("^%s*(.-)%s*$")
    -- Skip blank, known spinner patterns, and fetching/loading status lines
    if #line > 0
      and not line:lower():match("^%s*fetching")
      and not line:lower():match("^%s*loading")
      and #line > 3  -- skip single spinner chars like ⠋ ⠙ etc
      and not seen[line]
    then
      seen[line] = true
      local name = line
      local usage = nil
      local limited = false
      
      -- Parse usage e.g. "Gemini 1.5 Pro (50/50)"
      local base_name, u1, u2 = line:match("^(.-)%s*[%-]?%s*[%[%(]?(%d+)/(%d+)[^%]%)]*[%]%)]?%s*$")
      if base_name and u1 and u2 then
        name = base_name
        usage = u1 .. "/" .. u2
        limited = (tonumber(u1) >= tonumber(u2))
      else
        base_name, u1, u2 = line:match("^(.-)%s+(%d+)%s*/%s*(%d+)%s*$")
        if base_name and u1 and u2 then
          name = base_name
          usage = u1 .. "/" .. u2
          limited = (tonumber(u1) >= tonumber(u2))
        end
      end
      table.insert(models, { name = name, usage = usage, limited = limited })
    end
  end
  return models
end

-- A session is { role="user"|"ai", text=string, lines={} }
function AGView:new()
  AGView.super.new(self)
  self.visible     = true
  self.target_size = config.antigravity.target_width * SCALE
  self.size.x      = 0
  self.scrollable  = true
  self.chats = {}
  self.active_idx = 0
  self.hover_btn = nil
  self.hover_send = false
  self.tick = 0
  self:_add_chat()
  -- Model picker state
  self.model_list        = {}    -- [{name,limited}] populated by 'agy models'
  self.model_proc        = nil   -- background process fetching model list
  self._model_raw        = ""    -- accumulated stdout from model_proc
  self.show_model_picker = false -- dropdown open/closed
  self.hover_model_btn   = false
  self.hover_model_idx   = nil
  self._model_rect       = nil
  self._mpicker_rects    = {}
  self.temp_files        = {}
end

-- Called by the node system when the user drags the resize divider
function AGView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = math.max(180 * SCALE, value)  -- minimum 180px
    return true
  end
end

function AGView:_update_mentions()
  local mention_prefix = self:state().input:match("@([^%s]*)$")
  if mention_prefix then
    self:state().mention_suggestions = get_mention_suggestions(mention_prefix)
    self:state().mention_idx = 1
  else
    self:state().mention_suggestions = nil
  end
  core.redraw = true
end

function AGView:get_name() return "Antigravity" end

function AGView:state()
  return self.chats[self.active_idx]
end

function AGView:_add_chat()
  local c = {
    input = "",
    cursor = 0,
    status = "idle",
    process = nil,
    tmpfile = nil,
    scroll_y = 0,
    max_scroll = 0,
    sessions = {},
    has_session = false,
    warned_slow = false,
    started_at = 0,
    _chat_started_at = 0,
    _ai_buf = "",
    _ai_displayed_chars = 0,
    mention_suggestions = nil,
    mention_idx = 1,
    scroll_to_bottom = true,
  }
  table.insert(self.chats, c)
  self.active_idx = #self.chats
end


local function _session_lines(self, text, role)
  local pad  = 10 * SCALE
  local w    = self.size.x - 2 * pad - 8 * SCALE
  local font = role == "user" and style.font or style.code_font
  return wrap_raw_text(font, text, w)
end

function AGView:_add_session(role, text)
  local entry = { role = role, text = text, lines = {} }
  -- compute wrapped lines lazily in draw (size might not be set yet)
  table.insert(self:state().sessions, entry)
end

local function parse_iso_timestamp(str)
  if not str then return nil end
  local y, m, d, h, min, s = str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
  if y then
    return os.time({year=y, month=m, day=d, hour=h, min=min, sec=s})
  end
  return nil
end

function AGView:show_resume_picker()
  local base_dir = (os.getenv("USERPROFILE") or os.getenv("HOME"))
  local brain_path = base_dir .. "/.gemini/antigravity-cli/brain"
  
  local files = system.list_dir(brain_path)
  if not files then
    self:_add_session("ai", "Could not find brain directory at " .. brain_path)
    self:state().scroll_to_bottom = true
    core.redraw = true
    return
  end
  
  -- Parse conversation metadata for accurate titles, steps, and agents
  local cache_path = base_dir .. "/.gemini/antigravity-cli/cache/conversation_metadata.json"
  local cache_f = io.open(cache_path, "r")
  local meta = {}
  if cache_f then
    local current_cid = nil
    for line in cache_f:lines() do
      local cid = line:match('"(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)"%s*:%s*{')
      if cid then
        current_cid = cid
        meta[current_cid] = { preview = "", steps = 0, agent = "" }
      elseif current_cid then
        local preview = line:match('"Preview"%s*:%s*"([^"]*)"')
        if preview then meta[current_cid].preview = preview:gsub('\\"', '"'):gsub("\\n", " "):gsub("\\u0026", "&") end
        
        local steps = line:match('"NumSteps"%s*:%s*(%d+)')
        if steps then meta[current_cid].steps = tonumber(steps) end
        
        local agent = line:match('"AgentName"%s*:%s*"([^"]*)"')
        if agent then meta[current_cid].agent = agent end
      end
    end
    cache_f:close()
  end

  local results = {}
  local active_cid = self:state().cid

  local pinned_path = base_dir .. "/.gemini/antigravity-cli/pinned_cids.txt"
  local pinned = {}
  local pf = io.open(pinned_path, "r")
  if pf then
    for line in pf:lines() do
      local c = line:match("^%s*(.-)%s*$")
      if c and c ~= "" then pinned[c] = true end
    end
    pf:close()
  end

  for _, name in ipairs(files) do
    local cid = name:match("^(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$")
    if cid then
      local path = brain_path .. "/" .. cid .. "/.system_generated/logs/transcript.jsonl"
      local tf = io.open(path, "r")
      if tf then
        local title = ""
        local created_at = ""
        local has_user_input = false
        
        for line in tf:lines() do
          if not has_user_input and line:find('"type":"USER_INPUT"') then
            has_user_input = true
            local content = line:match('"content"%s*:%s*"(.*)"%s*}')
            if content then
              if #content > 2000 then content = content:sub(1, 2000) end
              local req = content:match("<USER_REQUEST>%s*(.-)%s*</USER_REQUEST>")
              title = req or content
              title = title:gsub("\\n", " "):gsub('\\"', '"'):gsub("\\u0026", "&")
              title = title:match("^%s*(.-)%s*$")
            end
            created_at = line:match('"created_at"%s*:%s*"([^"]+)"')
            break
          end
        end
        tf:close()
        
        if title == "" then
          title = cid
        end
        
        if title:find("lite_xl_healer") or title:find("The editor CRASHED") then
          title = "🚨 [Auto-Healer] Crash Report"
        end
        
        if active_cid == cid then
          title = "[CURRENT] " .. title
        end
        
        if #title > 60 then title = title:sub(1, 57) .. "..." end
        
        local m = meta[cid]
        local skill = m and m.agent or ""
        local steps = m and m.steps or 0
        
        -- Compute time ago from transcript timestamp
        local time_ago = ""
        local ts = parse_iso_timestamp(created_at)
        if ts then
          local diff = os.time() - ts
          if diff < 0 then diff = 0 end
          if diff < 60 then time_ago = diff .. "s ago"
          elseif diff < 3600 then time_ago = math.floor(diff / 60) .. "m ago"
          elseif diff < 86400 then time_ago = math.floor(diff / 3600) .. "h ago"
          else time_ago = math.floor(diff / 86400) .. "d ago" end
        else
          time_ago = cid:sub(1,8)
        end
        
        local info_str
        if skill == "" then
          info_str = string.format("%d steps      %s", steps, time_ago)
        else
          info_str = string.format("%s      %d steps      %s", skill, steps, time_ago)
        end
        
        local is_pinned = pinned[cid]
        if is_pinned then
          title = "📌 " .. title
        end
        
        table.insert(results, { text = title, info = info_str, cid = cid, time = ts or 0, pinned = is_pinned })
      end
    end
  end
  
  -- Sort results by pinned status, then timestamp (newest first)
  table.sort(results, function(a, b) 
    if a.pinned and not b.pinned then return true end
    if b.pinned and not a.pinned then return false end
    return a.time > b.time 
  end)

  if #results == 0 then
    self:_add_session("ai", "No past conversations found.")
    self:state().scroll_to_bottom = true
    core.redraw = true
    return
  end

  core.command_view:enter("Select Conversation to Resume (Ctrl+P: Pin, Ctrl+Del: Delete)", {
    submit = function(text, item)
      if item and item.cid then
        if self:state().process or #self:state().sessions > 0 then
          self:_add_chat()
        end
        self:state().cid = item.cid
        self:state().has_session = true
        self:_add_session("ai", "Resumed conversation: " .. item.text .. "\n\nBackend context loaded. You may now continue typing!")
        self:state().scroll_to_bottom = true
        core.redraw = true
      end
    end,
    suggest = function(text)
      if text == "" then return results end
      local res = {}
      for _, item in ipairs(results) do
        local score = system.fuzzy_match(item.text, text, true)
        if score then
          item._score = score
          table.insert(res, item)
        end
      end
      table.sort(res, function(a, b) return (a._score or 0) > (b._score or 0) end)
      return res
    end
  })
end

function AGView:submit(prompt)
  if not prompt or prompt == "" then return end
  
  if prompt == "/help" then
    self:state().has_session = true
    self:state().status = "idle"
    local help_text = "Built-in commands:\n  `/help` - Show this message\n  `/usage` - Show model usage\n  `/resume` - Resume a past conversation\n\n(Type any other prompt to chat with the AI)"
    table.insert(self:state().sessions, { role = "user", text = prompt })
    table.insert(self:state().sessions, { role = "ai", text = help_text })
    core.redraw = true
    return
  elseif prompt == "/usage" then
    self:state().status = "running"
    self:state().has_session = true
    table.insert(self:state().sessions, { role = "user", text = prompt })
    table.insert(self:state().sessions, { role = "ai", text = "" })
    
    local cfg = config.antigravity
    local argv = { cfg.cli, "usage" }
    if PLATFORM == "Windows" then
      argv = { "cmd.exe", "/c", cfg.cli, "usage" }
    end
    
    local p, err = process.start(argv, {
      stdin = process.REDIRECT_PIPE,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      cwd = core.project_dir
    })
    
    if p then
      self:state().process = p
      self:state()._chat_started_at = os.time()
    else
      self:state().sessions[#self:state().sessions].text = "Error: " .. tostring(err)
      self:state().status = "error"
    end
    core.redraw = true
    return
  end
  local prompt_text = prompt:match("^%s*(.-)%s*$")
  
  if prompt_text:match("^/resume") then
    self:state().input = ""
    self:show_resume_picker()
    return
  end


  -- We no longer block execution here. The auth_status is unreliable on Windows due to the CLI's stdin behavior.
  -- If they are truly unauthenticated, the chat will hang in the background, but they can use the AGY Auth button to fix it.

  -- Add user message to chat
  self:_add_session("user", prompt_text)

  local fname = nil
  local av = core.active_view
  if av and av.doc then fname = av.doc.filename end

  local full_prompt = prompt_text
  if fname then
    full_prompt = string.format("Regarding the active file %s: %s", fname, prompt_text)
  end

  self:state().status               = "running"
  self:state()._ai_buf              = ""  -- accumulate streaming response
  self:state()._ai_displayed_chars  = 0   -- typewriter effect
  self:state().started_at           = os.time()
  self:state().warned_slow  = false
  self:_add_session("ai", "")  -- placeholder entry
  self:state().scroll_to_bottom = true

  local cfg  = config.antigravity
  local argv = { cfg.cli }

  -- Continue existing conversation
  if self:state().cid then
    table.insert(argv, "--conversation")
    table.insert(argv, self:state().cid)
  elseif self:state().has_session then
    table.insert(argv, "-c")
  end

  -- Inject the user-selected model (if any)
  if cfg.selected_model then
    table.insert(argv, "--model")
    table.insert(argv, cfg.selected_model)
  end

  table.insert(argv, "-p")
  table.insert(argv, full_prompt)

  -- Pass the project root so the agent can read files natively
  local project_root = core.project_dir
  if not project_root or project_root == "" then
    if fname then
      project_root = fname:match("^(.*)[/\\][^/\\]+$") or "."
    else
      project_root = "."
    end
  end
  table.insert(argv, "--add-dir")
  table.insert(argv, project_root)

  if cfg.auto_skip_permissions then
    table.insert(argv, "--dangerously-skip-permissions")
  end

  local log = io.open(USERDIR .. "/antigravity_debug.log", "a")
  if log then
    log:write(os.date() .. "  ARGV: " .. table.concat(argv, " | ") .. "\n")
    log:close()
  end

  -- VS Code Copilot approach: route through Python PTY bridge so agy gets a
  -- real pseudoterminal (ConPTY on Windows) and produces streamed output.
  -- Python itself CAN pipe, so we use REDIRECT_PIPE on Python's stdout.
  local bridge = get_pty_bridge()
  local final_argv
  if bridge then
    -- python agy_pty_bridge.py <cli> [args...]
    final_argv = { "python", bridge }
    for _, a in ipairs(argv) do table.insert(final_argv, a) end
  else
    final_argv = argv
  end

    local p, err = process.start(final_argv, {
    stdin = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })

  if p then
    self:state().process = p
    self:state().has_session = true
    self:state()._chat_started_at = os.time()
  else
    self:state().sessions[#self:state().sessions].text = "ERROR: could not start agy CLI.\nPath: " .. cfg.cli .. "\nError: " .. tostring(err)
    self:state().status = "error"
  end
  core.redraw = true
end

local function is_resume_picker()
  return core.active_view == core.command_view and core.command_view.label == "Select Conversation to Resume (Ctrl+P: Pin, Ctrl+Del: Delete)"
end

command.add(is_resume_picker, {
  ["antigravity:delete-conversation"] = function()
    local item = core.command_view.suggestions[core.command_view.suggestion_idx]
    if item and item.cid then
      local base_dir = (os.getenv("USERPROFILE") or os.getenv("HOME"))
      local brain_path = base_dir .. "/.gemini/antigravity-cli/brain/" .. item.cid
      if PLATFORM == "Windows" then
        os.execute('rmdir /S /Q "' .. brain_path:gsub("/", "\\") .. '"')
      else
        os.execute('rm -rf "' .. brain_path .. '"')
      end
      core.log("Deleted conversation: " .. item.text)
      if instance then instance:show_resume_picker() end
    end
  end,
  ["antigravity:toggle-pin-conversation"] = function()
    local item = core.command_view.suggestions[core.command_view.suggestion_idx]
    if item and item.cid then
      local base_dir = (os.getenv("USERPROFILE") or os.getenv("HOME"))
      local pinned_path = base_dir .. "/.gemini/antigravity-cli/pinned_cids.txt"
      local pinned = {}
      local f = io.open(pinned_path, "r")
      if f then
        for line in f:lines() do
          local c = line:match("^%s*(.-)%s*$")
          if c and c ~= "" then pinned[c] = true end
        end
        f:close()
      end
      
      if pinned[item.cid] then
        pinned[item.cid] = nil
        core.log("Unpinned conversation.")
      else
        pinned[item.cid] = true
        core.log("Pinned conversation.")
      end
      
      f = io.open(pinned_path, "w")
      if f then
        for c, _ in pairs(pinned) do f:write(c .. "\n") end
        f:close()
      end
      if instance then instance:show_resume_picker() end
    end
  end
})

keymap.add({
  ["ctrl+delete"] = "antigravity:delete-conversation",
  ["ctrl+p"]      = "antigravity:toggle-pin-conversation"
})

function AGView:update()
  AGView.super.update(self)
  self.tick = (self.tick + 1) % 120

  -- Size animation (treeview pattern)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "x", dest, nil, "antigravity")



  -- ── Drain model-fetch process (via PTY bridge) ───────────────────────
  if self.model_proc then
    local buf = ""
    while true do
      local chunk = self.model_proc:read_stdout(4096)
      if not chunk or #chunk == 0 then break end
      buf = buf .. chunk
    end
    while true do
      local chunk = self.model_proc:read_stderr(4096)
      if not chunk or #chunk == 0 then break end
      -- stderr is usually noise, skip
    end
    if #buf > 0 then
      self._model_raw = (self._model_raw or "") .. buf
    end

    local m_elapsed = os.time() - (self.model_started_at or os.time())
    local rc = self.model_proc:returncode()
    if rc ~= nil then
      local parsed = parse_pty_model_list(self._model_raw or "")
      if #parsed > 0 then
        self.model_list = parsed
        self.auth_status = "logged_in"
        if not config.antigravity.selected_model then
          config.antigravity.selected_model = parsed[1].name
        end
      else
        self:_load_models_from_settings()
      end
      self._model_raw = ""
      self.model_proc = nil
      core.redraw = true
    elseif m_elapsed > 15 then
      pcall(function() graceful_kill(self.model_proc) end)
      self.model_proc = nil
      self._model_raw = ""
      self:_load_models_from_settings()
      core.redraw = true
    end
  end

  -- ── Drain chat processes (ALL TABS) ───────────────────────────
  for i, tab in ipairs(self.chats) do
    local is_active_process = tab.process ~= nil
    local ai_len = tab._ai_buf and #tab._ai_buf or 0
    local is_typing = tab._ai_displayed_chars and (tab._ai_displayed_chars < ai_len)

    if is_active_process or is_typing then
      local dirty = false

      -- Read stdout and stderr if process is alive
      if is_active_process then
        while true do
          local out = tab.process:read_stdout(65536)
          if not out or #out == 0 then break end
          tab._ai_buf = (tab._ai_buf or "") .. out
        end
        while true do
          local out = tab.process:read_stderr(65536)
          if not out or #out == 0 then break end
        end

        local rc = tab.process:returncode()
        if rc ~= nil then
          -- Final drain
          while true do
            local out = tab.process:read_stdout(65536)
            if not out or #out == 0 then break end
            tab._ai_buf = (tab._ai_buf or "") .. out
          end
          tab.process = nil
          tab.status = (rc == 0) and "idle" or "error"
          if not tab._ai_buf or tab._ai_buf == "" then
            local elapsed = os.time() - (tab._chat_started_at or os.time())
            tab._ai_buf = string.format(
              "(no output after %.0fs — process exited with code %s)\n\nTry the AGY Auth button if you just logged in.",
              elapsed, tostring(rc))
          end
          dirty = true
          core.redraw = true
        end

        local elapsed = os.time() - (tab._chat_started_at or os.time())
        
        -- Soft warning at 45s
        if tab.process and elapsed > 45 and tab._ai_buf == "" and not tab.warned_slow then
          tab.warned_slow = true
          core.redraw = true
        end
        
        -- Hard kill at 315s (5m15s)
        if tab.process and elapsed > 315 and tab._ai_buf == "" then
          pcall(function() graceful_kill(tab.process) end)
          tab.process = nil
          tab.status  = "error"
          local fix_msg = table.concat({
            "⏱ Request timed out after 5 minutes with no response.",
            "",
            "Most likely causes:",
            "  1. The AI model is taking too long to generate a response.",
            "  2. The Antigravity CLI is not set up correctly.",
            "",
            "If it's the latter, run this command in a terminal to fix it:",
            "  agy install",
            "",
            "After setup completes, reload Lite-XL and try again.",
            "If the problem persists, check: agy models",
          }, "\n")
          
          tab._ai_buf = fix_msg
          dirty = true
          core.error("[Antigravity] CLI timed out — agy install may be required.")
          core.redraw = true
        end
      end

      -- Re-evaluate length after reading new output
      ai_len = tab._ai_buf and #tab._ai_buf or 0
      is_typing = tab._ai_displayed_chars and (tab._ai_displayed_chars < ai_len)

      -- Typewriter effect logic
      if is_typing then
        -- Reveal characters chunk by chunk (approx 60fps * 150 chars = 9000 chars/sec)
        tab._ai_displayed_chars = math.min(ai_len, tab._ai_displayed_chars + 150)
        dirty = true
      end
      
      -- Update text if dirty
      if dirty and tab.sessions[#tab.sessions] and tab.sessions[#tab.sessions].role == "ai" then
        tab.sessions[#tab.sessions].text = tab._ai_buf:sub(1, tab._ai_displayed_chars or 0)
        tab.sessions[#tab.sessions].blocks = nil -- invalidate cache
        tab.scroll_to_bottom = true
        core.redraw = true
      end
    end
  end
end

-- Kick off background fetch of real model list via PTY bridge
function AGView:fetch_models()
  if self.model_proc then return end
  if self.model_list and #self.model_list > 0 then return end
  local cfg = config.antigravity

  -- Use the PTY bridge so agy gets a real pseudoterminal and outputs the list
  local bridge = get_pty_bridge()
  local argv
  if bridge then
    argv = { "python", bridge, cfg.cli, "models" }
  else
    -- Fallback: try direct (won't work on Windows but at least it tries)
    argv = { cfg.cli, "models" }
  end

  self._model_raw = ""
  self.model_started_at = os.time()

    local p, err = process.start(argv, {
    stdin = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if p then
    self.model_proc = p
  else
    -- Bridge failed — load from settings.json as reliable fallback
    self:_load_models_from_settings()
  end
end

-- Parse models from agy output (spinner lines filtered, real model names kept)
function parse_pty_model_list(raw)
  local models = {}
  local seen = {}
  for line in (raw .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    line = line:match("^%s*(.-)%s*$")
    -- Skip spinner lines, empty lines, and "Fetching" lines
    if #line > 0
      and not line:match("^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]")
      and not line:lower():match("fetching")
      and not line:lower():match("loading")
      and not seen[line]
    then
      seen[line] = true
      local name = line
      local usage = nil
      local limited = false
      
      -- Parse usage e.g. "Gemini 1.5 Pro (50/50)"
      local base_name, u1, u2 = line:match("^(.-)%s*[%-]?%s*[%[%(]?(%d+)/(%d+)[^%]%)]*[%]%)]?%s*$")
      if base_name and u1 and u2 then
        name = base_name
        usage = u1 .. "/" .. u2
        limited = (tonumber(u1) >= tonumber(u2))
      else
        local base_name2, pct = line:match("^(.-)%s*[%-]?%s*[%[%(]?weekly usage (%d+)%%[^%]%)]*[%]%)]?%s*$")
        if not base_name2 then
          base_name2, pct = line:match("^(.-)%s*[%-]?%s*[%[%(]?(%d+)%%[^%]%)]*[%]%)]?%s*$")
        end
        if base_name2 and pct then
          name = base_name2
          usage = pct .. "%"
          -- Force red badge if the usage string specifically contains '0%' (as requested)
          limited = (tonumber(pct) == 0) or (tonumber(pct) >= 100)
        else
          base_name, u1, u2 = line:match("^(.-)%s+(%d+)%s*/%s*(%d+)%s*$")
          if base_name and u1 and u2 then
            name = base_name
            usage = u1 .. "/" .. u2
            limited = (tonumber(u1) >= tonumber(u2))
          end
        end
      end
      table.insert(models, { name = name, usage = usage, limited = limited })
    end
  end
  return models
end

-- Fallback: load model list from settings.json
function AGView:_load_models_from_settings()
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
  local settings_paths = {
    home .. "\\.gemini\\antigravity-cli\\settings.json",
    home .. "/.gemini/antigravity-cli/settings.json",
  }
  local current_model = nil
  for _, path in ipairs(settings_paths) do
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a"); f:close()
      local m = content:match('"model"%s*:%s*"([^"]+)"')
      if m then current_model = m; break end
    end
  end
  -- Hardcoded known model list as final fallback
  self.model_list = {
    { name = "Gemini 3.5 Flash (Medium)",    limited = false },
    { name = "Gemini 3.5 Flash (High)",      limited = false },
    { name = "Gemini 3.1 Pro (High)",        limited = false },
    { name = "Claude Sonnet 4.6 (Thinking)", limited = false },
    { name = "Claude Opus 4.6 (Thinking)",   limited = false },
    { name = "GPT-OSS 120B (Medium)",        limited = false },
  }
  if current_model then
    table.insert(self.model_list, 1, { name = current_model, limited = false, current = true })
    if not config.antigravity.selected_model then
      config.antigravity.selected_model = current_model
    end
  end
  if not config.antigravity.selected_model and #self.model_list > 0 then
    config.antigravity.selected_model = self.model_list[1].name
  end
  self.auth_status = "logged_in"
  core.redraw = true
end

-- Hook into core.quit to kill any zombie background processes when Lite-XL exits
local old_quit = core.quit
function core.quit(force)
  if instance then
    for _, c in ipairs(instance.chats) do
      if c.process then pcall(function() graceful_kill(c.process) end) end
    end
    if instance.model_proc then pcall(function() graceful_kill(instance.model_proc) end) end
    if instance.temp_files then
      for _, fpath in ipairs(instance.temp_files) do
        os.remove(fpath)
      end
    end
  end
  return old_quit(force)
end

-- ── Draw helpers ──────────────────────────────────────────────────────────────
local function draw_rect_outline(x, y, w, h, col)
  renderer.draw_rect(x,     y,     w, 1, col)
  renderer.draw_rect(x,     y+h-1, w, 1, col)
  renderer.draw_rect(x,     y,     1, h, col)
  renderer.draw_rect(x+w-1, y,     1, h, col)
end

function AGView:draw()
  if self.size.x < 4 then return end

  -- Recompute the full palette from the active theme every frame
  local P = get_palette()

  local x, y = self.position.x, self.position.y
  local w, h  = self.size.x, self.size.y
  local pad   = 10 * SCALE
  local cur_y = y

  -- ── Full background ─────────────────────────────────────────────────────────
  renderer.draw_rect(x, y, w, h, P.bg)
  -- Left border (panel is on the right side)
  renderer.draw_rect(x, y, 1, h, P.border)

  -- ═══════════════════════════════════════════════════════════════════
  -- HEADER
  -- ═══════════════════════════════════════════════════════════════════
  local hdr_h = 40 * SCALE
  renderer.draw_rect(x, cur_y, w, hdr_h, P.bg_darker)
  renderer.draw_rect(x, cur_y + hdr_h - 1, w, 1, P.border)

  -- Status dot
  local dot_col = self:state().status == "running" and P.dot_run
               or self:state().status == "error"   and P.dot_err
               or P.dot_idle
  local dot_r = 5 * SCALE
  renderer.draw_rect(x + pad, cur_y + math.floor(hdr_h/2) - dot_r, dot_r*2, dot_r*2, dot_col)

  -- Title
  renderer.draw_text(style.big_font or style.font, "Antigravity",
    x + pad + dot_r*2 + 6 * SCALE,
    cur_y + math.floor((hdr_h - (style.big_font or style.font):get_height()) / 2),
    P.fg_accent)

  -- Status + Model button row (right side of header)
  local status_str = self:state().status == "running"
    and (self:state().warned_slow and "slow." or "thinking.")
    or  self:state().status == "error" and "error"
    or  "ready"
  local ss_w = style.font:get_width(status_str)
  renderer.draw_text(style.font, status_str,
    x + w - ss_w - pad - 8 * SCALE,
    cur_y + math.floor((hdr_h - style.font:get_height()) / 2),
    self:state().status == "error" and P.dot_err or P.fg_muted)

  -- Model selector pill button (sits just right of "Antigravity" title)
  local title_x   = x + pad + dot_r*2 + 6 * SCALE
  local title_w   = (style.big_font or style.font):get_width("Antigravity")
  local sel_name  = config.antigravity.selected_model or "model"
  local mfont     = style.font
  local mbtn_max  = w - (title_x - x) - title_w - ss_w - pad * 2 - 16 * SCALE
  local mbtn_lbl  = "[M] " .. sel_name
  while mfont:get_width(mbtn_lbl) > mbtn_max - 10 * SCALE and #mbtn_lbl > 5 do
    mbtn_lbl = mbtn_lbl:sub(1, -2)
  end
  if sel_name ~= "model" and mfont:get_width("[M] " .. sel_name) > mbtn_max - 10 * SCALE then
    mbtn_lbl = mbtn_lbl .. "."
  end
  local mbtn_w = math.min(mfont:get_width(mbtn_lbl) + 14 * SCALE, mbtn_max)
  local mbtn_h = 18 * SCALE
  local mbtn_x = title_x + title_w + 8 * SCALE
  local mbtn_y = cur_y + math.floor((hdr_h - mbtn_h) / 2)
  local mbtn_bg = self.hover_model_btn and P.bg_btn_hl or P.bg_btn
  renderer.draw_rect(mbtn_x, mbtn_y, mbtn_w, mbtn_h, mbtn_bg)
  draw_rect_outline(mbtn_x, mbtn_y, mbtn_w, mbtn_h, P.border)
  renderer.draw_text(mfont, mbtn_lbl,
    mbtn_x + 6 * SCALE,
    mbtn_y + math.floor((mbtn_h - mfont:get_height()) / 2),
    P.fg_label)
  self._model_rect = { x = mbtn_x, y = mbtn_y, w = mbtn_w, h = mbtn_h }

  cur_y = cur_y + hdr_h

    -- QUICK ACTION PILLS (single row, compact)
  -- ═══════════════════════════════════════════════════════════════════
  local pill_h    = 24 * SCALE
  local pill_gap  = 4 * SCALE
  local n         = #config.antigravity.actions
  local pill_w    = math.floor((w - 2 * pad - (n - 1) * pill_gap) / n)
  local pills_top = cur_y + 6 * SCALE

  for i, act in ipairs(config.antigravity.actions) do
    local bx = x + pad + (i - 1) * (pill_w + pill_gap)
    local by = pills_top
    local hl = (self.hover_btn == i)

    renderer.draw_rect(bx, by, pill_w, pill_h, hl and P.bg_btn_hl or P.bg_btn)
    draw_rect_outline(bx, by, pill_w, pill_h, P.border)

    local label_w = style.font:get_width(act.short)
    renderer.draw_text(style.font, act.short,
      bx + math.floor((pill_w - label_w) / 2),
      by + math.floor((pill_h - style.font:get_height()) / 2),
      hl and P.fg_accent or P.fg_label)
  end
  cur_y = pills_top + pill_h + 6 * SCALE

  -- Label row under pills
  for i, act in ipairs(config.antigravity.actions) do
    local bx = x + pad + (i - 1) * (pill_w + pill_gap)
    local lw = style.font:get_width(act.label)
    if lw <= pill_w then
      renderer.draw_text(style.font, act.label,
        bx + math.floor((pill_w - lw) / 2),
        cur_y,
        P.fg_muted)
    end
  end
  cur_y = cur_y + style.font:get_height() + 4 * SCALE

  -- Divider
  renderer.draw_rect(x + pad, cur_y, w - 2*pad, 1, P.border)
  cur_y = cur_y + 8 * SCALE

  -- ═══════════════════════════════════════════════════════════════════
  -- INPUT AREA (at bottom, fixed)
  -- ═══════════════════════════════════════════════════════════════════
  local send_h   = 30 * SCALE
  local input_h  = 56 * SCALE
  local bottom_h = input_h + send_h + 3 * pad
  local chat_bot = y + h - bottom_h

  -- Divider above input
  renderer.draw_rect(x, chat_bot, w, 1, P.border)

  -- Input box
  local inp_x = x + pad
  local inp_y = chat_bot + pad
  local inp_w = w - 2 * pad
  renderer.draw_rect(inp_x, inp_y, inp_w, input_h, P.bg_input)
  draw_rect_outline(inp_x, inp_y, inp_w, input_h,
    core.active_view == self and P.border_input or P.border)

  -- Placeholder / typed text
  local display    = #self:state().input > 0 and self:state().input or "Ask anything about your code."
  local fg_inp     = #self:state().input > 0 and P.fg or P.fg_muted

  local max_text_w = inp_w - 16 * SCALE
  local cursor_idx = self:state().cursor or #self:state().input
  local cursor_x   = style.font:get_width(self:state().input:sub(1, cursor_idx))
  local tx         = inp_x + 8 * SCALE
  if core.active_view == self and cursor_x > max_text_w then
    tx = tx - (cursor_x - max_text_w)
  end

  core.push_clip_rect(inp_x, inp_y, inp_w, input_h)
  renderer.draw_text(style.font, display, tx, inp_y + 8 * SCALE, fg_inp)

  -- Blink cursor
  if core.active_view == self and math.floor(self.tick / 30) % 2 == 0 then
    local cw = #self:state().input > 0 and cursor_x or style.font:get_width(display)
    if #self:state().input == 0 then cw = 0 end
    renderer.draw_rect(tx + cw, inp_y + 8 * SCALE, 2 * SCALE, style.font:get_height(), P.fg_accent)
  end
  core.pop_clip_rect()

  -- Hint text bottom-right of input
  local hint = "Enter ↵"
  renderer.draw_text(style.font, hint,
    inp_x + inp_w - style.font:get_width(hint) - 6 * SCALE,
    inp_y + input_h - style.font:get_height() - 5 * SCALE,
    P.fg_muted)

  -- Send/Stop button
  local send_y = inp_y + input_h + 4 * SCALE
  local is_running = self:state().process ~= nil
  local send_bg = is_running and { common.color "#D94C4C" } or P.bg_send
  if self.hover_send then
    send_bg = is_running and { common.color "#F26363" } or P.bg_send_hl
  end
  renderer.draw_rect(inp_x, send_y, inp_w, send_h, send_bg)

  local send_lbl = is_running and "      [x] STOP GENERATING      " or "  Send"
  renderer.draw_text(style.font, send_lbl,
    inp_x + math.floor((inp_w - style.font:get_width(send_lbl)) / 2),
    send_y + math.floor((send_h - style.font:get_height()) / 2),
    P.fg_send)

  -- Store send button bounds for click detection
  self._send_rect = { x = inp_x, y = send_y, w = inp_w, h = send_h }

  -- ═══════════════════════════════════════════════════════════════════
  -- CHAT HISTORY (scrollable, between quick-actions and input)
  -- ═══════════════════════════════════════════════════════════════════
    local tab_h = 24 * SCALE
  self.tab_rects = {}
  self.tab_stop_rects = {}
  local cur_x = x + pad
  for i, c in ipairs(self.chats) do
    local label = tostring(i)
    if c.status == "running" then
      label = "working..."
    end
    
    local stop_w = 0
    if c.status == "running" then
      stop_w = style.font:get_width(" [x]") + 8 * SCALE
    end
    
    local tw = style.font:get_width(label) + 16 * SCALE + stop_w
    local tab_bg = (i == self.active_idx) and P.bg_btn_hl or P.bg
    local tab_fg = (i == self.active_idx) and P.fg or P.fg_muted
    
    renderer.draw_rect(cur_x, cur_y, tw, tab_h, tab_bg)
    renderer.draw_text(style.font, label, cur_x + 8 * SCALE, cur_y + math.floor((tab_h - style.font:get_height())/2), tab_fg)
    
    if c.status == "running" then
      local sx = cur_x + tw - stop_w
      renderer.draw_text(style.font, " [x]", sx, cur_y + math.floor((tab_h - style.font:get_height())/2), { common.color "#FB4934" })
      table.insert(self.tab_stop_rects, { x = sx, y = cur_y, w = stop_w, h = tab_h, idx = i })
    end
    
    table.insert(self.tab_rects, { x = cur_x, y = cur_y, w = tw - stop_w, h = tab_h, idx = i })
    cur_x = cur_x + tw + 2 * SCALE
  end
  
  -- "+" button
  local pw = style.font:get_width("+") + 16 * SCALE
  renderer.draw_rect(cur_x, cur_y, pw, tab_h, P.bg)
  renderer.draw_text(style.font, "+", cur_x + 8 * SCALE, cur_y + math.floor((tab_h - style.font:get_height())/2), P.fg_muted)
  self.add_btn_rect = { x = cur_x, y = cur_y, w = pw, h = tab_h }
  cur_x = cur_x + pw + 2 * SCALE
  
  -- "x" button (close active)
  if #self.chats > 1 then
    local xw = style.font:get_width("x") + 16 * SCALE
    renderer.draw_rect(cur_x, cur_y, xw, tab_h, P.bg)
    renderer.draw_text(style.font, "x", cur_x + 8 * SCALE, cur_y + math.floor((tab_h - style.font:get_height())/2), { common.color "#FB4934" })
    self.close_btn_rect = { x = cur_x, y = cur_y, w = xw, h = tab_h }
  else
    self.close_btn_rect = nil
  end
  
  cur_y = cur_y + tab_h + 4 * SCALE
  local chat_top = cur_y
  local chat_h   = chat_bot - chat_top

  -- Clip: draw a bg rect to mask overflow
  renderer.draw_rect(x, chat_top, w, chat_h, P.bg)
  core.push_clip_rect(x, chat_top, w, chat_h)

  local lh_f = style.font:get_height() + 2 * SCALE
  local lh_c = style.code_font:get_height() + 2 * SCALE
  local ty    = chat_top + 4 * SCALE - self:state().scroll_y
  local total_h = 0
  self._copy_rects = {}

    if #self:state().sessions == 0 then
      local msg = "Type /help for commands"
      local w_msg = style.font:get_width(msg)
      renderer.draw_text(style.font, msg, x + math.floor((w - w_msg) / 2), chat_top + math.floor(chat_h / 2) - self:state().scroll_y, P.fg_muted)
    end

  for _, sess in ipairs(self:state().sessions) do
    local is_user = sess.role == "user"
    local lh      = is_user and lh_f or lh_c
    local msg_pad = 8 * SCALE
    local msg_w   = w - 2 * pad - 4 * SCALE
    local bg_col  = is_user and P.bg_user_msg or P.bg_ai_msg
    local fg_col  = is_user and P.fg_user or P.fg_ai

    -- Cache parsed blocks (invalidated when text or width changes)
    if not sess.blocks or sess._cached_text ~= sess.text or sess._cached_w ~= msg_w then
      sess.blocks = parse_blocks(sess.text, style.font, style.code_font, msg_w - 2 * msg_pad)
      sess._cached_text = sess.text
      sess._cached_w = msg_w
    end

    local msg_h = 2 * msg_pad
    for _, blk in ipairs(sess.blocks) do
      if blk.type == "code" then
        msg_h = msg_h + #blk.raw_lines * lh_c + 8 * SCALE
      elseif blk.type == "empty" then
        msg_h = msg_h + lh_f
      elseif blk.type == "paragraph" then
        local f = (blk.level > 0) and (style.big_font or style.font) or style.font
        local lh = f:get_height() + 2 * SCALE
        msg_h = msg_h + #blk.wrapped_lines * lh
      end
    end
    msg_h = math.max(lh_f + 2 * msg_pad, msg_h)

    -- Role label
    if ty + msg_h + lh_f >= chat_top and ty <= chat_bot then
      local role_lbl = is_user and "You" or "Antigravity"
      renderer.draw_text(style.font, role_lbl, x + pad, math.max(chat_top, math.min(ty, chat_bot - style.font:get_height())), P.fg_muted)
    end
    ty = ty + style.font:get_height() + 2 * SCALE

    -- Message bubble background
    if ty + msg_h >= chat_top and ty <= chat_bot then
      renderer.draw_rect(x + pad, ty, msg_w, msg_h, bg_col)
      draw_rect_outline(x + pad, ty, msg_w, msg_h, P.border)
    end

    -- Blocks inside bubble
    local line_y = ty + msg_pad
    for _, blk in ipairs(sess.blocks) do
      if blk.type == "code" and #blk.raw_lines > 0 then
        local b_h = #blk.raw_lines * lh_c + 8 * SCALE
        if line_y + b_h >= chat_top and line_y <= chat_bot then
          renderer.draw_rect(x + pad + 4 * SCALE, line_y, msg_w - 8 * SCALE, b_h, P.bg_darker)
          draw_rect_outline(x + pad + 4 * SCALE, line_y, msg_w - 8 * SCALE, b_h, P.border)
        end
        line_y = line_y + 4 * SCALE
        
        local lang = blk.lang or "txt"
        local synt = syntax.get("dummy." .. lang) or syntax.get(lang)
        local state = nil
        
        for _, line in ipairs(blk.raw_lines) do
          if line_y + lh_c >= chat_top and line_y <= chat_bot then
            local tokens = { "normal", line }
            if synt then
              local ok, res1, res2 = pcall(tokenizer.tokenize, synt, line, state)
              if ok then tokens, state = res1, res2 end
            end
            local lx = x + pad + msg_pad
            for i = 1, #tokens, 2 do
              local type = tokens[i]
              local text = tokens[i+1]
              local col = style.syntax[type] or style.syntax["normal"] or P.fg_ai
              lx = renderer.draw_text(style.code_font, text, lx, line_y, col)
            end
          else
            if synt then pcall(function() _, state = tokenizer.tokenize(synt, line, state) end) end
          end
          line_y = line_y + lh_c
        end
        line_y = line_y + 4 * SCALE
        
      elseif blk.type == "empty" then
        line_y = line_y + lh_f
        
      elseif blk.type == "paragraph" then
        local f = (blk.level > 0) and (style.big_font or style.font) or style.font
        local lh = f:get_height() + 2 * SCALE
        local l_col = (blk.level > 0) and P.fg_accent or fg_col
        
        for l_idx, w_line in ipairs(blk.wrapped_lines) do
          if line_y + lh >= chat_top and line_y <= chat_bot then
            local lx = x + pad + msg_pad
            if blk.list and l_idx == 1 then
              renderer.draw_text(f, "• ", lx, line_y, P.fg_accent)
              lx = lx + f:get_width("• ")
            elseif blk.list then
              lx = lx + f:get_width("• ")
            end
            
            for _, seg in ipairs(w_line) do
              local cfont = seg.font
              local ccol = l_col
              if seg.type == "code" or seg.type == "code_link" then ccol = style.syntax["keyword"] or P.fg_accent
              elseif seg.type == "bold" then ccol = P.fg_accent
              elseif seg.type == "link" then ccol = style.syntax["function"] or P.fg_accent end
              
              renderer.draw_text(cfont, seg.text, lx, line_y, ccol)
              lx = lx + seg.width
            end
          end
          line_y = line_y + lh
        end
      end
    end

    -- Save bounds for hover/click detection
    local bubble_x, bubble_y = x + pad, ty
    local bubble_w, bubble_h = msg_w, msg_h
    table.insert(self._copy_rects, {
      x = bubble_x, y = bubble_y, w = bubble_w, h = bubble_h, text = sess.text, idx = _
    })

    -- Draw copy button if hovered
    if self.hover_copy_idx == _ then
      local copy_txt = self.copy_flash_idx == _ and "Copied!" or "Copy"
      local c_w = style.font:get_width(copy_txt) + 12 * SCALE
      local c_h = style.font:get_height() + 8 * SCALE
      local c_x = bubble_x + bubble_w - c_w - 6 * SCALE
      local c_y = bubble_y + 6 * SCALE
      
      if c_y + c_h >= chat_top and c_y <= chat_bot then
        renderer.draw_rect(c_x, c_y, c_w, c_h, P.bg_btn_hl)
        draw_rect_outline(c_x, c_y, c_w, c_h, P.border)
        renderer.draw_text(style.font, copy_txt, c_x + 6 * SCALE, c_y + 4 * SCALE, P.fg)
      end
    end

    -- Spinner on last AI message while running
    if self:state().status == "running" and not is_user
       and sess == self:state().sessions[#self:state().sessions]
       and sess.text == "" then
      local dots = string.rep("•", (math.floor(self.tick / 20) % 4))
      renderer.draw_text(style.font, dots,
        x + pad + msg_pad, ty + msg_pad, P.fg_muted)
    end

    ty = ty + msg_h + 6 * SCALE
    total_h = total_h + style.font:get_height() + 2 * SCALE + msg_h + 6 * SCALE
  end

  self:state().max_scroll = math.max(0, total_h - chat_h)
  if self:state().scroll_to_bottom then
    if self:state().scroll_y ~= self:state().max_scroll then
      self:state().scroll_y = self:state().max_scroll
      core.redraw = true
    end
    self:state().scroll_to_bottom = false
  end

  -- Empty state
  if #self:state().sessions == 0 then
    local msg = "To reference specific files in your project, type '@' followed by the file name!\n\n" ..
                "Example: '@src/main.lua Can you fix the errors in this file?'"
    local mw = w - 2 * pad
    for _, line in ipairs(wrap_raw_text(style.font, msg, mw)) do
      renderer.draw_text(style.font, line, x + pad, ty, P.fg_muted)
      ty = ty + style.font:get_height() + 2 * SCALE
    end
  end
  core.pop_clip_rect()

  -- ═══════════════════════════════════════════════════════════════════
  -- MENTION POPUP
  -- ═══════════════════════════════════════════════════════════════════
  if self:state().mention_suggestions and #self:state().mention_suggestions > 0 then
    local pop_w = w - 2 * pad
    local item_h = style.font:get_height() + 8 * SCALE
    local pop_h = #self:state().mention_suggestions * item_h
    local pop_x = x + pad
    local pop_y = inp_y - pop_h - 4 * SCALE
    
    renderer.draw_rect(pop_x, pop_y, pop_w, pop_h, P.bg_darker)
    draw_rect_outline(pop_x, pop_y, pop_w, pop_h, P.border)
    
    for i, file in ipairs(self:state().mention_suggestions) do
      local iy = pop_y + (i - 1) * item_h
      if i == self:state().mention_idx then
        renderer.draw_rect(pop_x, iy, pop_w, item_h, P.bg_btn_hl)
      end
      renderer.draw_text(style.font, file, pop_x + 8 * SCALE, iy + 4 * SCALE, P.fg)
    end
  end

  -- MODEL PICKER DROPDOWN: drawn last to overlay pills and chat
  if self.show_model_picker then
    local mf     = style.font
    local item_h = mf:get_height() + 10 * SCALE
    local list   = self.model_list
    local rows   = (#list == 0) and 1 or #list
    local pop_h  = rows * item_h + 6 * SCALE
    local pop_y  = y + 40 * SCALE
    renderer.draw_rect(x, pop_y, w, pop_h, P.bg_dark)
    draw_rect_outline(x, pop_y, w, pop_h, P.border)
    self._mpicker_rects = {}
    if #list == 0 then
      renderer.draw_text(mf,
        self.model_proc and "Fetching models..." or "No models found.",
        x + pad, pop_y + 3 * SCALE + math.floor((item_h - mf:get_height()) / 2), P.fg_muted)
    else
      for i, m in ipairs(list) do
        local ry     = pop_y + 3 * SCALE + (i - 1) * item_h
        local is_sel = config.antigravity.selected_model == m.name
        local is_hov = self.hover_model_idx == i
        local rbg    = is_sel and P.bg_btn_hl or is_hov and P.bg_btn or nil
        if rbg then renderer.draw_rect(x, ry, w, item_h, rbg) end
        
        if m.limited then
          -- red corner wrapper / border if usage is over limit
          draw_rect_outline(x, ry, w, item_h, P.dot_err)
        end
        
        local label = m.name
        local fg    = m.limited and P.dot_err or (is_sel and P.fg_accent or P.fg)
        renderer.draw_text(mf, label, x + pad,
          ry + math.floor((item_h - mf:get_height()) / 2), fg)
          
        if m.usage then
          local usage_w = mf:get_width(m.usage)
          local ufg = m.limited and P.dot_err or P.fg_muted
          renderer.draw_text(mf, m.usage,
            x + w - pad - usage_w,
            ry + math.floor((item_h - mf:get_height()) / 2), ufg)
        elseif is_sel then
          renderer.draw_text(mf, "[v]",
            x + w - pad - mf:get_width("[v]"),
            ry + math.floor((item_h - mf:get_height()) / 2), P.dot_run)
        end
        table.insert(self._mpicker_rects, { x=x, y=ry, w=w, h=item_h, idx=i })
      end
    end
  end
end

-- ── Input ──────────────────────────────────────────────────────────────────────
function AGView:on_text_input(text)
  local c = self:state().cursor or #self:state().input
  local before = self:state().input:sub(1, c)
  local after = self:state().input:sub(c + 1)
  self:state().input = before .. text .. after
  self:state().cursor = c + #text
  self:_update_mentions()
  core.redraw = true
end

function AGView:on_paste(text)
  if not text then return end
  local is_long = #text > 1000 or select(2, text:gsub("\n", "")) > 10
  local paste_txt = text
  if is_long then
    local tmp_dir = USERDIR .. "/tempfiles"
    pcall(system.mkdir, tmp_dir)
    local filename = os.date("pasted_text_%Y%m%d_%H%M%S.txt")
    local filepath = tmp_dir .. "/" .. filename
    local f = io.open(filepath, "w")
    if f then
      f:write(text)
      f:close()
      table.insert(self.temp_files, filepath)
      core.log("Saved long paste to %s", filename)
      paste_txt = " @" .. filename .. " "
    end
  end
  local c = self:state().cursor or #self:state().input
  local before = self:state().input:sub(1, c)
  local after = self:state().input:sub(c + 1)
  self:state().input = before .. paste_txt .. after
  self:state().cursor = c + #paste_txt
  self:_update_mentions()
  core.redraw = true
end

function AGView:on_key_pressed(key, ...)
  if self:state().mention_suggestions and #self:state().mention_suggestions > 0 then
    if key == "up" then
      self:state().mention_idx = math.max(1, self:state().mention_idx - 1)
      core.redraw = true
      return true
    elseif key == "down" then
      self:state().mention_idx = math.min(#self:state().mention_suggestions, self:state().mention_idx + 1)
      core.redraw = true
      return true
    elseif key == "return" or key == "tab" then
      local choice = self:state().mention_suggestions[self:state().mention_idx]
      self:state().input = self:state().input:gsub("@[^%s]*$", "@" .. choice .. " ")
      self:state().mention_suggestions = nil
      core.redraw = true
      return true
    elseif key == "escape" then
      self:state().mention_suggestions = nil
      core.redraw = true
      return true
    end
  end

  if key == "escape" then
    if self:state().process or self:state().status == "running" then
      if self:state().process then
        pcall(function() graceful_kill(self:state().process) end)
        self:state().process = nil
      end
      self:state()._ai_buf = (self:state()._ai_buf or "") .. "\n\n*[Stopped by user]*"
      self:state()._ai_displayed_chars = #(self:state()._ai_buf)
      self:state().status = "idle"
      core.log("Chat generation stopped by user.")
      core.redraw = true
      return true
    end
  end

  local mods = keymap.modkeys or {}

  if key == "return" and not mods["ctrl"] then
    local q = self:state().input:match("^%s*(.-)%s*$")
    if q and #q > 0 then self:submit(q) end
    self:state().input = ""
    core.redraw = true
    return true
  end

  if key == "return" and mods["ctrl"] then
    -- Ctrl+Enter: clear chat
    self:state().sessions = {}
    self:state().input    = ""
    self:state().status   = "idle"
    self:state().has_session = false
    if self:state().process then pcall(function() graceful_kill(self:state().process) end) end
    self:state().process  = nil
    core.redraw = true
    return true
  end

  if key == "backspace" then
    local c = self:state().cursor or #self:state().input
    if c > 0 then
      local prev_c = utf8_prev(self:state().input, c)
      local before = self:state().input:sub(1, prev_c)
      local after = self:state().input:sub(c + 1)
      self:state().input = before .. after
      self:state().cursor = prev_c
      self:_update_mentions()
      core.redraw = true
    end
    return true
  end

  if key == "delete" then
    local c = self:state().cursor or #self:state().input
    if c < #self:state().input then
      local next_c = utf8_next(self:state().input, c)
      local before = self:state().input:sub(1, c)
      local after = self:state().input:sub(next_c + 1)
      self:state().input = before .. after
      self:_update_mentions()
      core.redraw = true
    end
    return true
  end

  if key == "left" then
    self:state().cursor = utf8_prev(self:state().input, self:state().cursor or #self:state().input)
    core.redraw = true
    return true
  elseif key == "right" then
    self:state().cursor = utf8_next(self:state().input, self:state().cursor or #self:state().input)
    core.redraw = true
    return true
  elseif key == "home" then
    self:state().cursor = 0
    core.redraw = true
    return true
  elseif key == "end" then
    self:state().cursor = #self:state().input
    core.redraw = true
    return true
  end

  if key == "up" then
    self:state().scroll_y = math.max(0, self:state().scroll_y - (style.font:get_height() + 2 * SCALE) * 3)
    core.redraw = true
    return true
  end
  if key == "down" then
    self:state().scroll_y = math.min(self:state().max_scroll, self:state().scroll_y + (style.font:get_height() + 2 * SCALE) * 3)
    core.redraw = true
    return true
  end
  return false
end

-- ── Mouse ──────────────────────────────────────────────────────────────────────
function AGView:on_mouse_moved(mx, my, ...)
  AGView.super.on_mouse_moved(self, mx, my, ...)
  self.hover_btn  = nil
  self.hover_send = false

  local x     = self.position.x
  local w     = self.size.x
  local pad   = 10 * SCALE
  local n     = #config.antigravity.actions
  local pill_w = math.floor((w - 2 * pad - (n - 1) * 4 * SCALE) / n)
  local pill_h = 24 * SCALE
  -- Pills start at: y + header(40) + 6
  local pills_top = self.position.y + 40 * SCALE + 6 * SCALE

  for i = 1, n do
    local bx = x + pad + (i - 1) * (pill_w + 4 * SCALE)
    if mx >= bx and mx <= bx + pill_w and my >= pills_top and my <= pills_top + pill_h then
      self.hover_btn = i
      break
    end
  end

  if self._send_rect then
    local r = self._send_rect
    self.hover_send = (mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h)
  end

  self.hover_copy_idx = nil
  if self._copy_rects then
    for _, r in ipairs(self._copy_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        self.hover_copy_idx = r.idx
        break
      end
    end
  end

  -- Model button hover
  self.hover_model_btn = false
  self.hover_model_idx = nil
  if self._model_rect then
    local r = self._model_rect
    self.hover_model_btn = (mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h)
  end
  if self.show_model_picker and self._mpicker_rects then
    for _, r in ipairs(self._mpicker_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        self.hover_model_idx = r.idx
        break
      end
    end
  end

  core.redraw = true
end

function AGView:on_mouse_pressed(button, mx, my, clicks)
  AGView.super.on_mouse_pressed(self, button, mx, my, clicks)
  if button ~= "left" then return false end

  -- Model picker button
  if self._model_rect then
    local r = self._model_rect
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      self.show_model_picker = not self.show_model_picker
      if self.show_model_picker and #self.model_list == 0 then
        self:fetch_models()
      end
      core.redraw = true
      return true
    end
  end

  if self.add_btn_rect then
    local r = self.add_btn_rect
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      self:_add_chat()
      core.redraw = true
      return true
    end
  end

  -- Check if clicked inside input
  local pad = 16 * SCALE
  local chat_bot = self.size.y - (style.font:get_height() + 16 * SCALE) - 10 * SCALE - pad
  local inp_y = chat_bot + pad
  local input_h = style.font:get_height() + 16 * SCALE
  if my >= inp_y and my <= inp_y + input_h then
    local inp_x = self.position.x + pad
    local inp_w = self.size.x - 2 * pad
    local tx = inp_x + 8 * SCALE
    if core.active_view == self then
      local max_text_w = inp_w - 16 * SCALE
      local cursor_idx = self:state().cursor or #self:state().input
      local cursor_x = style.font:get_width(self:state().input:sub(1, cursor_idx))
      if cursor_x > max_text_w then tx = tx - (cursor_x - max_text_w) end
    end
    local click_x = mx - tx
    local best_cursor = 0
    local min_dist = math.abs(click_x)
    local i = 0
    while i < #self:state().input do
      local next_i = utf8_next(self:state().input, i)
      local char_w = style.font:get_width(self:state().input:sub(1, next_i))
      local dist = math.abs(char_w - click_x)
      if dist < min_dist then
        min_dist = dist
        best_cursor = next_i
      end
      i = next_i
    end
    self:state().cursor = best_cursor
    core.redraw = true
    return true
  end
  if self.close_btn_rect then
    local r = self.close_btn_rect
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      if self:state().process then pcall(function() graceful_kill(self:state().process) end) end
      if self:state().tmpfile then pcall(os.remove, self:state().tmpfile) end
      table.remove(self.chats, self.active_idx)
      if self.active_idx > #self.chats then self.active_idx = #self.chats end
      core.redraw = true
      return true
    end
  end
  for _, r in ipairs(self.tab_stop_rects or {}) do
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      local c = self.chats[r.idx]
      if c and c.process then
        pcall(function() graceful_kill(c.process) end)
        c.process = nil
        c.status = "idle"
        if c.tmpfile then pcall(os.remove, c.tmpfile); c.tmpfile = nil end
        if c.sessions[#c.sessions] and c.sessions[#c.sessions].role == "ai" then
          c.sessions[#c.sessions].text = (c.sessions[#c.sessions].text or "") .. "\n\n[Stopped by user]"
          c.sessions[#c.sessions].lines = nil
        end
        core.redraw = true
        return true
      end
    end
  end

  for _, r in ipairs(self.tab_rects or {}) do
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      self.active_idx = r.idx
      core.redraw = true
      return true
    end
  end

  -- Model picker row selection
  if self.show_model_picker and self._mpicker_rects then
    for _, r in ipairs(self._mpicker_rects) do
      if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
        local m = self.model_list[r.idx]
        if m then
          config.antigravity.selected_model = m.name
          self.show_model_picker = false
          self:state().has_session = false  -- reset session so next -p doesn't pass -c with old model
          core.log("Antigravity: switched to model '" .. m.name .. "'")
        end
        core.redraw = true
        return true
      end
    end
  end

  -- Close picker if clicking elsewhere
  if self.show_model_picker then
    self.show_model_picker = false
    core.redraw = true
  end

  -- Quick action pill
  if self.hover_btn then
    local act = config.antigravity.actions[self.hover_btn]
    if act then self:submit(act.prompt) return true end
  end

  -- Copy button click
  if self.hover_copy_idx and self._copy_rects then
    for _, r in ipairs(self._copy_rects) do
      if r.idx == self.hover_copy_idx then
        system.set_clipboard(r.text)
        self.copy_flash_idx = r.idx
        core.add_thread(function()
          coroutine.yield(1)
          if self.copy_flash_idx == r.idx then self.copy_flash_idx = nil; core.redraw = true end
        end)
        core.redraw = true
        return true
      end
    end
  end

  -- Send/Stop button
  if self.hover_send then
    if self:state().process then
      pcall(function() graceful_kill(self:state().process) end)
      self:state().process = nil
      self:state().status = "idle"
      if self:state().tmpfile then pcall(os.remove, self:state().tmpfile); self:state().tmpfile = nil end
      -- Append a small message indicating it was stopped
      if self:state().sessions[#self:state().sessions] and self:state().sessions[#self:state().sessions].role == "ai" then
        self:state().sessions[#self:state().sessions].text = (self:state().sessions[#self:state().sessions].text or "") .. "\n\n[Stopped by user]"
        self:state().sessions[#self:state().sessions].lines = nil
      end
    else
      local q = self:state().input:match("^%s*(.-)%s*$")
      if q and #q > 0 then self:submit(q) end
      self:state().input = ""
    end
    core.redraw = true
    return true
  end

  return false
end

function AGView:on_mouse_wheel(dy)
  self:state().scroll_y = math.max(0, math.min(self:state().max_scroll, self:state().scroll_y - dy * (style.font:get_height() + 2 * SCALE) * 3))
  core.redraw = true
  return true
end

-- ── Commands ──────────────────────────────────────────────────────────────────
command.add(nil, {
  ["antigravity:toggle"] = function()
    if not instance then instance = AGView() end

    if not node_built then
      local target = core.root_view:get_active_node_default()
      -- resizable=true makes the divider draggable by the user
      local new_node = target:split("right", instance, { x = true }, true)
      if new_node then
        new_node.size.x = 0
        instance.size.x = 0
      end
      node_built = true
    end

    instance.visible = not instance.visible
    if instance.visible then
      core.set_active_view(instance)
    else
      local views = core.root_view.root_node:get_children()
      for _, v in ipairs(views) do
        if v ~= instance and v.doc then
          core.set_active_view(v)
          break
        end
      end
    end
    core.redraw = true
  end,

  ["antigravity:focus"] = function()
    command.perform "antigravity:toggle"
    if instance and instance.visible then
      core.set_active_view(instance)
    end
  end,

  ["antigravity:explain"]  = function() command.perform("antigravity:submit", config.antigravity.actions[1].prompt) end,
  ["antigravity:refactor"] = function() command.perform("antigravity:submit", config.antigravity.actions[2].prompt) end,
  ["antigravity:fix"]      = function() command.perform("antigravity:submit", config.antigravity.actions[3].prompt) end,
  ["antigravity:tests"]    = function() command.perform("antigravity:submit", config.antigravity.actions[4].prompt) end,
  ["antigravity:docs"]     = function() command.perform("antigravity:submit", config.antigravity.actions[5].prompt) end,
  ["antigravity:submit"]   = function(prompt)
    if not instance or not instance.visible then
      command.perform("antigravity:toggle")
    end
    if instance then
      instance:submit(prompt)
      core.set_active_view(instance)
    end
  end,
  ["antigravity:ask"]      = function()
    core.command_view:enter("Ask Antigravity", {
      submit = function(text)
        command.perform("antigravity:submit", text)
      end
    })
  end,
  ["antigravity:auth"] = function()
    core.command_view:enter("Press Enter to launch Auth Terminal (follow instructions in the new window)", {
      submit = function(text)
        local cfg = config.antigravity
        if PLATFORM == "Windows" then
          process.start({ "cmd.exe", "/c", "start", "cmd.exe", "/k", "echo Launching Antigravity Authentication... && " .. cfg.cli }, {
            stdin = process.REDIRECT_DISCARD,
          })
        elseif PLATFORM == "Mac OS X" then
          process.start({ "osascript", "-e", 'tell app "Terminal" to do script "' .. cfg.cli .. '"' }, {
            stdin = process.REDIRECT_DISCARD,
          })
        else
          pcall(function() process.start({ "x-terminal-emulator", "-e", cfg.cli }, {
            stdin = process.REDIRECT_DISCARD,
          }) end)
        end
        core.log("Antigravity: If a terminal did not open automatically, please open your terminal and manually run: " .. cfg.cli)
        
        if not instance then instance = AGView() end
        instance.auth_status = "checking"
        
        core.add_thread(function()
          coroutine.yield(15) -- wait 15 seconds for them to complete the browser login
          if instance then
            instance:fetch_models()
          end
        end)
      end
    })
  end,
})

-- ── Status Bar Item ───────────────────────────────────────────────────────────
local StatusView = require "core.statusview"

core.status_view:add_item({
  name = "antigravity:auth",
  alignment = StatusView.Item.RIGHT,
  get_item = function()
    local text = "🤖 AGY Auth"
    if instance then
      if instance.auth_status == "logged_in" then
        text = "🤖 " .. (os.getenv("USERNAME") or "AGY Connected")
      elseif instance.auth_status == "auth_error" then
        text = "🤖 Retry Auth[click here again]"
      end
    end
    return {
      style.font,
      style.text,
      text
    }
  end,
  command = "antigravity:auth",
  tooltip = "Sign in to Antigravity / Manage Auth"
})

-- Hook the StatusView draw function to guarantee the entire status bar text is highly contrasted
local old_sv_draw = StatusView.draw
function StatusView:draw(...)
  local old_text = style.text
  local old_dim = style.dim
  local old_accent = style.accent

  local bg = style.background2 or {0,0,0,255}
  
  -- If background is light, force text to very dark colors
  if lum(bg[1], bg[2], bg[3]) > 128 then
    style.text = { 0, 0, 0, 255 }
    style.dim = { 80, 80, 80, 255 }
    style.accent = { 0, 50, 150, 255 }
  -- If background is dark, force text to very light colors
  else
    style.text = { 255, 255, 255, 255 }
    style.dim = { 180, 180, 180, 255 }
  end

  old_sv_draw(self, ...)

  style.text = old_text
  style.dim = old_dim
  style.accent = old_accent
end

-- Bind local commands that only activate when AI Sidebar is focused
command.add(
  function() return core.active_view == instance end,
  {
    ["antigravity:return"]    = function() instance:on_key_pressed("return") end,
    ["antigravity:backspace"] = function() instance:on_key_pressed("backspace") end,
    ["antigravity:scroll-up"] = function() instance:on_key_pressed("up") end,
    ["antigravity:scroll-down"] = function() instance:on_key_pressed("down") end,
    ["antigravity:escape"]    = function() instance:on_key_pressed("escape") end,
    ["antigravity:paste"]     = function() instance:on_paste(system.get_clipboard()) end,
    ["antigravity:delete"]    = function() instance:on_key_pressed("delete") end,
    ["antigravity:cursor-left"]  = function() instance:on_key_pressed("left") end,
    ["antigravity:cursor-right"] = function() instance:on_key_pressed("right") end,
    ["antigravity:cursor-home"]  = function() instance:on_key_pressed("home") end,
    ["antigravity:cursor-end"]   = function() instance:on_key_pressed("end") end,
  }
)

local keymap = require "core.keymap"
keymap.add {
  ["return"]    = { "antigravity:return", "command:submit", "doc:newline", "dialog:select" },
  ["backspace"] = { "antigravity:backspace", "doc:backspace" },
  ["up"]        = { "antigravity:scroll-up", "command:select-previous", "doc:move-to-previous-line", "command:select-previous-char" },
  ["down"]      = { "antigravity:scroll-down", "command:select-next", "doc:move-to-next-line", "command:select-next-char" },
  ["escape"]    = { "antigravity:escape", "command:escape", "core:cancel", "doc:select-none", "dialog:close" },
  ["ctrl+v"]    = { "antigravity:paste", "core:paste" },
  ["cmd+v"]     = { "antigravity:paste", "core:paste" },
  ["delete"]    = { "antigravity:delete", "doc:delete", "command:delete" },
  ["left"]      = { "antigravity:cursor-left", "doc:move-to-previous-char", "command:select-previous-char" },
  ["right"]     = { "antigravity:cursor-right", "doc:move-to-next-char", "command:select-next-char" },
  ["home"]      = { "antigravity:cursor-home", "doc:move-to-start-of-line" },
  ["end"]       = { "antigravity:cursor-end", "doc:move-to-end-of-line" },
}

local ok, contextmenu = pcall(require, "plugins.contextmenu")
if ok then
  local ContextMenu = require "core.contextmenu"
  contextmenu:register("core.docview", {
    ContextMenu.DIVIDER,
    { text = "Explain Code with AI",  command = "antigravity:explain" },
    { text = "Refactor Code with AI", command = "antigravity:refactor" },
    { text = "Fix Code with AI",      command = "antigravity:fix" },
    { text = "Generate Unit Tests",   command = "antigravity:tests" },
    { text = "Generate Documentation",command = "antigravity:docs" },
  })
end
