-- mod-version:3
local core    = require "core"
local command = require "core.command"
local keymap  = require "core.keymap"
local style   = require "core.style"
local View    = require "core.view"
local process = require "process"
local system  = require "system"
local PATHSEP = PATHSEP or package.config:sub(1,1)
local USERDIR = USERDIR or (os.getenv("USERPROFILE") or os.getenv("HOME")) .. "/.config/lite-xl"

local LANG_MAP = {
  py   = "python3",   js  = "javascript", ts  = "typescript",
  cpp  = "cpp",       c   = "c",          java = "java",
  cs   = "csharp",    go  = "golang",     rs  = "rust",
  rb   = "ruby",      swift = "swift",    kt  = "kotlin",
  php  = "php",       lua = "lua",        sh  = "bash",
}

local LANG_EXT = {
  python3    = "py",    javascript = "js",   typescript = "ts",
  cpp        = "cpp",   c          = "c",    java       = "java",
  csharp     = "cs",    golang     = "go",   rust       = "rs",
  ruby       = "rb",    swift      = "swift",kotlin     = "kt",
  php        = "php",   lua        = "lua",  bash       = "sh",
}

local LC_COLORS = {
  accepted  = { 34, 197,  94, 255 },
  wrong     = {239,  68,  68, 255 },
  tle       = {234, 179,   8, 255 },
  mle       = {249, 115,  22, 255 },
  easy      = { 34, 197,  94, 255 },
  medium    = {234, 179,   8, 255 },
  hard      = {239,  68,  68, 255 },
  badge_bg  = { 30,  30,  46, 255 },
}

local function json_encode(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number"  then return tostring(v)
  elseif t == "string"  then
    return '"' .. v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t') .. '"'
  elseif t == "table" then
    if v[1] ~= nil or next(v) == nil then
      local parts = {}
      for _, item in ipairs(v) do parts[#parts+1] = json_encode(item) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts+1] = json_encode(tostring(k)) .. ":" .. json_encode(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

-- Safely parse the python response
local function json_decode(s)
  s = s:gsub('"([^"]-)"%s*:', '["%1"]=')
       :gsub('%[%s*%]', '{}')
       :gsub('null', 'nil')
       :gsub('true', 'true')
       :gsub('false', 'false')
  local fn, err = load("return " .. s)
  if fn then
    local ok, res = pcall(fn)
    if ok then return res end
  end
  return nil, err
end

local modal = {
  active        = false,
  state         = "auth",
  session_input = "",
  csrf_input    = "",
  auth_focus    = "session",
  auth_status   = "",
  problems      = {},
  total_problems= 0,
  search_input  = "",
  search_focus  = false,
  difficulty    = "",
  scroll_y      = 0,
  selected_idx  = 1,
  page_skip     = 0,
  loading_msg   = "",
  current       = nil,
  open_lang     = "python3",
  result        = nil,
  result_type   = "run",
  _search_timer = nil,
  run_req_id    = nil,
}

local api_proc   = nil
local pending    = {}
local req_counter = 0

local function ensure_api()
  if api_proc and api_proc:returncode() == nil then return true end
  local script = USERDIR .. PATHSEP .. "scripts" .. PATHSEP .. "leetcode_api.py"
  local python_cmd = PLATFORM == "Windows" and "python" or "python3"
  api_proc = process.start(
    {python_cmd, script, USERDIR},
    { stdin  = process.REDIRECT_PIPE,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_DISCARD }
  )
  if not api_proc then
    core.error("[LeetCode] Failed to start leetcode_api.py — is Python installed?")
    return false
  end
  core.add_thread(function()
    local buf = ""
    while api_proc and api_proc:returncode() == nil do
      local chunk = api_proc:read_stdout(4096) or ""
      buf = buf .. chunk
      while true do
        local line, rest = buf:match("^([^\n]+)\n(.*)")
        if not line then break end
        buf = rest
        local ok, resp = pcall(json_decode, line)
        if ok and resp and resp.id then
          local cb = pending[resp.id]
          if cb then pending[resp.id] = nil; cb(resp) end
        end
      end
      coroutine.yield(0.05)
    end
  end)
  return true
end

local function api_call(params, callback)
  req_counter = req_counter + 1
  local id = tostring(req_counter)
  params.id = id
  pending[id] = callback
  if ensure_api() then
    local line = json_encode(params) .. "\n"
    api_proc:write(line)
  end
end

local function open_problem(problem, lang)
  local dir = USERDIR .. PATHSEP .. "leetcode"
  system.mkdir(dir)
  local num   = string.format("%04d", tonumber(problem.id) or 0)
  local ext   = LANG_EXT[lang] or "txt"
  local fname = num .. "_" .. problem.slug .. "." .. ext
  local fpath = dir .. PATHSEP .. fname

  local f = io.open(fpath, "r")
  if not f then
    local starter = (problem.starters or {})[lang] or ""
    local header = ""
    if ext == "py" then
      header = "# " .. problem.id .. ". " .. problem.title .. "\n# " .. (problem.difficulty or "") .. " | https://leetcode.com/problems/" .. problem.slug .. "/\n\n"
    elseif ext == "cpp" or ext == "c" or ext == "java" or ext == "cs" or ext == "js" or ext == "ts" then
      header = "// " .. problem.id .. ". " .. problem.title .. "\n// " .. (problem.difficulty or "") .. " | https://leetcode.com/problems/" .. problem.slug .. "/\n\n"
    end
    local wf = io.open(fpath, "w")
    if wf then wf:write(header .. starter); wf:close() end
  else
    f:close()
  end

  local meta_path = fpath .. ".lc_meta"
  local mf = io.open(meta_path, "w")
  if mf then
    mf:write(json_encode({
      slug        = problem.slug,
      question_id = problem.question_id or problem.id,
      lang        = lang,
      title       = problem.title,
      difficulty  = problem.difficulty,
      test_cases  = problem.test_cases or "",
    }))
    mf:close()
  end

  core.root_view:open_doc(core.open_doc(fpath))
  modal.active = false
  core.redraw  = true
end

local function get_active_meta()
  local doc = core.active_view and core.active_view.doc
  if not doc or not doc.abs_filename then return nil end
  local leetcode_dir = USERDIR .. PATHSEP .. "leetcode"
  if doc.abs_filename:find(leetcode_dir, 1, true) ~= 1 then return nil end
  local meta_path = doc.abs_filename .. ".lc_meta"
  local f = io.open(meta_path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local slug  = content:match('"slug"%s*:%s*"([^"]+)"')
  local qid   = content:match('"question_id"%s*:%s*"([^"]+)"')
  local lang  = content:match('"lang"%s*:%s*"([^"]+)"')
  local title = content:match('"title"%s*:%s*"([^"]+)"')
  local diff  = content:match('"difficulty"%s*:%s*"([^"]+)"')
  local tc    = content:match('"test_cases"%s*:%s*"(.-)"')
  if not slug then return nil end
  return { slug=slug, question_id=qid, lang=lang, title=title, difficulty=diff, test_cases=tc or "" }
end

local function get_active_code()
  local doc = core.active_view and core.active_view.doc
  if not doc then return nil end
  local lines = {}
  for i = 1, #doc.lines do lines[i] = doc.lines[i] end
  return table.concat(lines)
end

command.add(nil, {
  ["leetcode:toggle"] = function()
    modal.active = not modal.active
    if modal.active and modal.state == "list" and #modal.problems == 0 then
      command.perform("leetcode:fetch-list")
    elseif modal.active and modal.state == "auth" then
      api_call({cmd = "auth_check"}, function(resp)
        if resp.ok then
          modal.auth_status = "✓ Logged in as " .. resp.data.username
          modal.state = "list"
          if #modal.problems == 0 then command.perform("leetcode:fetch-list") end
        else
          modal.auth_status = ""
        end
        core.redraw = true
      end)
    end
    core.redraw = true
  end,

  ["leetcode:connect"] = function()
    modal.auth_status = "checking..."
    core.redraw = true
    api_call({
      cmd     = "auth_set",
      session = modal.session_input,
      csrf    = modal.csrf_input
    }, function(resp)
      if resp.ok then
        modal.auth_status = "✓ Logged in as " .. resp.data.username
        modal.state = "list"
        command.perform("leetcode:fetch-list")
      else
        modal.auth_status = "✗ Invalid cookies"
      end
      core.redraw = true
    end)
  end,

  ["leetcode:fetch-list"] = function()
    modal.state       = "loading"
    modal.loading_msg = "Fetching problems…"
    core.redraw       = true
    api_call({
      cmd        = "problem_list",
      skip       = modal.page_skip,
      limit      = 50,
      difficulty = modal.difficulty,
      search     = modal.search_input,
    }, function(resp)
      if resp.ok then
        modal.problems       = resp.data.problems
        modal.total_problems = resp.data.total
        modal.state          = "list"
        modal.selected_idx   = 1
      else
        if resp.error and resp.error:match("Not logged in") then
          modal.state = "auth"
          modal.auth_status = "Session expired"
        else
          modal.state = "list"
          core.error("[LeetCode] " .. (resp.error or "Unknown error"))
        end
      end
      core.redraw = true
    end)
  end,

  ["leetcode:open-problem"] = function()
    if modal.state ~= "list" then return end
    local p = modal.problems[modal.selected_idx]
    if not p then return end
    modal.state       = "loading"
    modal.loading_msg = "Loading " .. p.title .. "…"
    core.redraw       = true
    api_call({ cmd = "problem_detail", slug = p.slug }, function(resp)
      if resp.ok then
        modal.current = resp.data
        modal.state   = "problem"
        modal.scroll_y = 0
      else
        modal.state = "list"
        core.error("[LeetCode] " .. (resp.error or "Failed to load problem"))
      end
      core.redraw = true
    end)
  end,

  ["leetcode:run"] = function()
    local meta = get_active_meta()
    local code = get_active_code()
    if not meta or not code then
      core.error("[LeetCode] Open a LeetCode solution file first (from USERDIR/leetcode/)")
      return
    end
    modal.active      = true
    modal.state       = "running"
    modal.loading_msg = "Running test cases…"
    core.redraw       = true
    local my_req_id = tostring(req_counter + 1)
    modal.run_req_id = my_req_id
    api_call({
      cmd         = "run_code",
      slug        = meta.slug,
      question_id = meta.question_id,
      lang        = meta.lang,
      code        = code,
      test_input  = meta.test_cases:gsub("\\n", "\n"),
    }, function(resp)
      if modal.run_req_id ~= my_req_id then return end
      modal.result      = resp.data or {}
      modal.result.ok   = resp.ok
      modal.result.err  = resp.error
      modal.result_type = "run"
      modal.state       = "result"
      core.redraw       = true
    end)
  end,

  ["leetcode:submit"] = function()
    local meta = get_active_meta()
    local code = get_active_code()
    if not meta or not code then
      core.error("[LeetCode] Open a LeetCode solution file first (from USERDIR/leetcode/)")
      return
    end
    modal.active      = true
    modal.state       = "running"
    modal.loading_msg = "Submitting to LeetCode…"
    core.redraw       = true
    local my_req_id = tostring(req_counter + 1)
    modal.run_req_id = my_req_id
    api_call({
      cmd         = "submit",
      slug        = meta.slug,
      question_id = meta.question_id,
      lang        = meta.lang,
      code        = code,
    }, function(resp)
      if modal.run_req_id ~= my_req_id then return end
      modal.result      = resp.data or {}
      modal.result.ok   = resp.ok
      modal.result.err  = resp.error
      modal.result_type = "submit"
      modal.state       = "result"
      core.redraw       = true
    end)
  end,
})

keymap.add({
  ["ctrl+shift+l"] = "leetcode:toggle",
})

command.add(function() return get_active_meta() ~= nil end, {
  ["ctrl+r"] = "leetcode:run",
  ["ctrl+shift+s"] = "leetcode:submit",
})

-- Drawing utilities
local function draw_text_wrap(font, color, text, x, y, max_w)
  local lh = font:get_height()
  local cx, cy = x, y
  for word in text:gmatch("%S+") do
    local ww = font:get_width(word .. " ")
    if cx + ww > x + max_w then
      cx = x
      cy = cy + lh
    end
    cx = renderer.draw_text(font, word .. " ", cx, cy, color)
  end
  return cy + lh
end

-- Overlay renderer
local old_root_draw = core.root_view.draw
local spinner_frames = {"⣾","⣽","⣻","⢿","⡿","⣟","⣯","⣷"}

function core.root_view:draw()
  old_root_draw(self)
  if not modal.active then return end

  local sw, sh = self.size.x, self.size.y
  renderer.draw_rect(0, 0, sw, sh, {0, 0, 0, 140})
  
  local w, h = 700 * SCALE, 500 * SCALE
  local x, y = (sw - w) / 2, (sh - h) / 2
  renderer.draw_rect(x, y, w, h, style.background)
  renderer.draw_rect(x, y, w, 2 * SCALE, style.accent) -- Top border
  
  local cx, cy = x + 20 * SCALE, y + 20 * SCALE
  local cw = w - 40 * SCALE

  if modal.state == "auth" then
    cy = renderer.draw_text(style.font, "🟨 LeetCode — Setup", cx, cy, style.text) + 20*SCALE
    cy = renderer.draw_text(style.font, "Paste your LeetCode session cookies below.", cx, cy, style.dim) + 10*SCALE
    cy = renderer.draw_text(style.font, "Log in at leetcode.com → F12 → Application → Cookies → leetcode.com", cx, cy, style.dim) + 20*SCALE
    
    renderer.draw_text(style.font, "LEETCODE_SESSION:", cx, cy, style.text)
    cy = cy + 20*SCALE
    renderer.draw_rect(cx, cy, cw, 30*SCALE, style.background2)
    local sess_text = modal.session_input:gsub(".", "*")
    if modal.auth_focus == "session" and os.time() % 2 == 0 then sess_text = sess_text .. "|" end
    renderer.draw_text(style.font, sess_text, cx + 5*SCALE, cy + 5*SCALE, style.text)
    cy = cy + 40*SCALE
    
    renderer.draw_text(style.font, "csrftoken:", cx, cy, style.text)
    cy = cy + 20*SCALE
    renderer.draw_rect(cx, cy, cw, 30*SCALE, style.background2)
    local csrf_text = modal.csrf_input
    if modal.auth_focus == "csrf" and os.time() % 2 == 0 then csrf_text = csrf_text .. "|" end
    renderer.draw_text(style.font, csrf_text, cx + 5*SCALE, cy + 5*SCALE, style.text)
    cy = cy + 50*SCALE
    
    renderer.draw_rect(cx, cy, 100*SCALE, 30*SCALE, style.accent)
    renderer.draw_text(style.font, "Connect", cx + 20*SCALE, cy + 5*SCALE, style.background)
    
    if modal.auth_status ~= "" then
      renderer.draw_text(style.font, "Status: " .. modal.auth_status, cx, cy + 50*SCALE, style.text)
    end
    
  elseif modal.state == "loading" or modal.state == "running" then
    local frame = spinner_frames[math.floor(system.get_time() * 10) % #spinner_frames + 1]
    renderer.draw_text(style.font, frame .. "  " .. modal.loading_msg, cx + cw/2 - 50*SCALE, y + h/2, style.text)
    
  elseif modal.state == "list" then
    local diff_color = style.text
    if modal.difficulty == "EASY" then diff_color = LC_COLORS.easy
    elseif modal.difficulty == "MEDIUM" then diff_color = LC_COLORS.medium
    elseif modal.difficulty == "HARD" then diff_color = LC_COLORS.hard end
    
    renderer.draw_text(style.font, "LeetCode", cx, cy, style.text)
    renderer.draw_text(style.font, "[ALL]  [Easy]  [Med]  [Hard]", cx + 100*SCALE, cy, diff_color)
    cy = cy + 30*SCALE
    
    renderer.draw_text(style.font, "Search:", cx, cy, style.text)
    renderer.draw_rect(cx + 60*SCALE, cy, cw - 60*SCALE, 24*SCALE, style.background2)
    local stext = modal.search_input
    if modal.search_focus and os.time() % 2 == 0 then stext = stext .. "|" end
    renderer.draw_text(style.font, stext, cx + 65*SCALE, cy + 2*SCALE, style.text)
    cy = cy + 35*SCALE
    
    renderer.draw_rect(cx, cy, cw, 1*SCALE, style.dim)
    cy = cy + 10*SCALE
    
    for i, p in ipairs(modal.problems) do
      if cy > y + h - 50*SCALE then break end
      if i == modal.selected_idx then
        renderer.draw_rect(cx - 5*SCALE, cy - 2*SCALE, cw + 10*SCALE, 24*SCALE, style.line_highlight)
      end
      renderer.draw_text(style.font, "#" .. p.id, cx, cy, style.dim)
      renderer.draw_text(style.font, p.title, cx + 50*SCALE, cy, style.text)
      local dc = p.difficulty == "Easy" and LC_COLORS.easy or (p.difficulty == "Medium" and LC_COLORS.medium or LC_COLORS.hard)
      renderer.draw_text(style.font, p.difficulty, cx + 450*SCALE, cy, dc)
      renderer.draw_text(style.font, p.ac_rate .. "%", cx + 550*SCALE, cy, style.dim)
      if p.paid then renderer.draw_text(style.font, "(Premium)", cx + 620*SCALE, cy, LC_COLORS.tle) end
      cy = cy + 24*SCALE
    end
    
  elseif modal.state == "problem" and modal.current then
    local p = modal.current
    local dc = p.difficulty == "Easy" and LC_COLORS.easy or (p.difficulty == "Medium" and LC_COLORS.medium or LC_COLORS.hard)
    renderer.draw_text(style.font, "← Back", cx, cy, style.dim)
    renderer.draw_text(style.font, p.title, cx + 80*SCALE, cy, style.text)
    renderer.draw_text(style.font, "[" .. p.difficulty .. "]", cx + cw - 100*SCALE, cy, dc)
    cy = cy + 25*SCALE
    renderer.draw_rect(cx, cy, cw, 1*SCALE, style.dim)
    cy = cy + 15*SCALE
    
    core.push_clip_rect(cx, cy, cw, h - 120*SCALE)
    draw_text_wrap(style.font, style.text, p.content_plain, cx, cy - modal.scroll_y, cw)
    core.pop_clip_rect()
    
    cy = y + h - 50*SCALE
    renderer.draw_rect(cx, cy, cw, 1*SCALE, style.dim)
    cy = cy + 15*SCALE
    renderer.draw_text(style.font, "Open in:", cx, cy, style.text)
    local bx = cx + 80*SCALE
    for lang, _ in pairs(p.starters or {}) do
      local bw = renderer.draw_text(style.font, "[" .. lang .. "]", bx, cy, style.accent)
      bx = bx + 10*SCALE
    end
    
  elseif modal.state == "result" and modal.result then
    local res = modal.result
    local title_c = res.ok and LC_COLORS.accepted or LC_COLORS.wrong
    if res.status:match("Limit Exceeded") then title_c = LC_COLORS.tle end
    if res.status:match("Error") then title_c = LC_COLORS.hard end
    
    renderer.draw_text(style.font, res.ok and "✓ " or "✗ ", cx, cy, title_c)
    renderer.draw_text(style.font, res.status, cx + 20*SCALE, cy, title_c)
    cy = cy + 30*SCALE
    renderer.draw_rect(cx, cy, cw, 1*SCALE, style.dim)
    cy = cy + 20*SCALE
    
    if res.compile_error and res.compile_error ~= "" then
      draw_text_wrap(style.font, LC_COLORS.hard, "Compile Error:\n" .. res.compile_error, cx, cy, cw)
    elseif res.runtime_error and res.runtime_error ~= "" then
      draw_text_wrap(style.font, LC_COLORS.hard, "Runtime Error:\n" .. res.runtime_error, cx, cy, cw)
    else
      renderer.draw_text(style.font, "Runtime: " .. (res.runtime or "N/A"), cx, cy, style.text)
      if res.runtime_percentile and res.runtime_percentile > 0 then
        renderer.draw_text(style.font, "beats " .. res.runtime_percentile .. "%", cx + 200*SCALE, cy, style.dim)
      end
      cy = cy + 24*SCALE
      renderer.draw_text(style.font, "Memory:  " .. (res.memory or "N/A"), cx, cy, style.text)
      if res.memory_percentile and res.memory_percentile > 0 then
        renderer.draw_text(style.font, "beats " .. res.memory_percentile .. "%", cx + 200*SCALE, cy, style.dim)
      end
      cy = cy + 30*SCALE
      renderer.draw_text(style.font, "Testcases passed: " .. (res.total_correct or 0) .. " / " .. (res.total_testcases or 0), cx, cy, style.text)
      cy = cy + 30*SCALE
      
      if not res.ok and modal.result_type == "run" then
        renderer.draw_text(style.font, "Your output:", cx, cy, style.text)
        cy = draw_text_wrap(style.font, LC_COLORS.wrong, table.concat(res.code_output or {}, "\n"), cx + 120*SCALE, cy, cw - 120*SCALE) + 10*SCALE
        renderer.draw_text(style.font, "Expected:", cx, cy, style.text)
        cy = draw_text_wrap(style.font, LC_COLORS.accepted, table.concat(res.expected_output or {}, "\n"), cx + 120*SCALE, cy, cw - 120*SCALE) + 10*SCALE
      end
    end
  end
end

local old_on_event = core.on_event
function core.on_event(type, ...)
  if modal.active then
    if type == "keypressed" then
      local key = ...
      if key == "escape" then
        modal.active = false; core.redraw = true; return true
      end
      if key == "ctrl+v" or key == "cmd+v" then
        local text = system.get_clipboard()
        if text then
          text = text:gsub("[\r\n]", "") -- strip newlines from pasted cookies
          if modal.state == "auth" then
            if modal.auth_focus == "session" then modal.session_input = modal.session_input .. text
            else modal.csrf_input = modal.csrf_input .. text end
          elseif modal.state == "list" and modal.search_focus then
            modal.search_input = modal.search_input .. text
            modal._search_timer = system.get_time() + 0.4
          end
        end
        core.redraw = true; return true
      end
      if modal.state == "auth" then
        if key == "tab" then
          modal.auth_focus = modal.auth_focus == "session" and "csrf" or "session"
          core.redraw = true; return true
        end
        if key == "return" then command.perform("leetcode:connect"); return true end
        if key == "backspace" then
          if modal.auth_focus == "session" then modal.session_input = modal.session_input:sub(1, -2)
          else modal.csrf_input = modal.csrf_input:sub(1, -2) end
          core.redraw = true; return true
        end
      end
      if modal.state == "list" then
        if key == "up"    then modal.selected_idx = math.max(1, modal.selected_idx - 1); core.redraw = true; return true end
        if key == "down"  then modal.selected_idx = math.min(#modal.problems, modal.selected_idx + 1); core.redraw = true; return true end
        if key == "return" then command.perform("leetcode:open-problem"); return true end
        if key == "tab" then modal.search_focus = not modal.search_focus; core.redraw = true; return true end
        if key == "backspace" and modal.search_focus then
          modal.search_input = modal.search_input:sub(1, -2)
          modal._search_timer = system.get_time() + 0.4
          core.redraw = true; return true
        end
      end
      if modal.state == "problem" then
        if key == "backspace" then modal.state = "list"; core.redraw = true; return true end
        if key == "down" then modal.scroll_y = modal.scroll_y + 40; core.redraw = true; return true end
        if key == "up" then modal.scroll_y = math.max(0, modal.scroll_y - 40); core.redraw = true; return true end
      end
      if modal.state == "result" then
        if key == "backspace" or key == "return" then modal.active = false; core.redraw = true; return true end
      end
    end
    if type == "textinput" then
      local text = ...
      if modal.state == "auth" then
        if modal.auth_focus == "session" then modal.session_input = modal.session_input .. text
        else modal.csrf_input = modal.csrf_input .. text end
        core.redraw = true; return true
      end
      if modal.state == "list" and modal.search_focus then
        modal.search_input = modal.search_input .. text
        modal._search_timer = system.get_time() + 0.4
        core.redraw = true; return true
      end
    end
    if type == "mousepressed" then
      local btn, x, y = ...
      if modal.state == "problem" and btn == "left" then
        local sw, sh = core.root_view.size.x, core.root_view.size.y
        local mw, mh = 700 * SCALE, 500 * SCALE
        local mx, my = (sw - mw) / 2, (sh - mh) / 2
        local cy = my + mh - 50*SCALE + 15*SCALE
        local bx = mx + 20*SCALE + 80*SCALE
        if y >= cy and y <= cy + 20*SCALE then
          for lang, _ in pairs(modal.current.starters or {}) do
            local bw = style.font:get_width("[" .. lang .. "]")
            if x >= bx and x <= bx + bw then
              open_problem(modal.current, lang)
              return true
            end
            bx = bx + bw + 10*SCALE
          end
        end
      end
      return true
    end
    if type == "mousewheel" and modal.state == "problem" then
      local delta = ...
      modal.scroll_y = math.max(0, modal.scroll_y - delta * 40)
      core.redraw = true
      return true
    end
    return true
  end
  return old_on_event(type, ...)
end

local old_update = core.root_view.update
function core.root_view:update(...)
  old_update(self, ...)
  if modal.active and modal._search_timer then
    if system.get_time() >= modal._search_timer then
      modal._search_timer = nil
      modal.page_skip     = 0
      command.perform("leetcode:fetch-list")
    end
    core.redraw = true
  end
end

core.add_thread(function()
  if core.status_view and core.status_view.add_item then
    core.status_view:add_item({
      name      = "leetcode",
      alignment = core.status_view.Item.RIGHT,
      get_item  = function()
        local meta = get_active_meta()
        if meta then
          return {
            style.text, " LC ",
            style.font, " " .. (meta.title or "LeetCode"),
            style.dim, "  [ctrl+r] Run  [ctrl+shift+s] Submit"
          }
        end
        return { style.text, " LC ", style.font, " LeetCode" }
      end,
      command = "leetcode:toggle",
    })
  end
end)
