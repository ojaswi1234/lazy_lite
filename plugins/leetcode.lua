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

local function json_decode(s)
  local fn, err = load("return " .. s)
  if fn then
    local ok, res = pcall(fn)
    if ok then return res end
  end
  return nil, err
end

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
    core.log("[LeetCode] Failed to start leetcode_api.py - is Python installed?")
    return false
  end
  core.add_thread(function()
    local buf = ""
    while api_proc and api_proc:returncode() == nil do
      local chunk = api_proc:read_stdout(65536) or ""
      if chunk ~= "" then
        buf = buf .. chunk
      end
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
      -- Only yield if no data was read, to avoid artificial throttling on large responses
      if chunk == "" then
        coroutine.yield(0.01)
      end
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


local LeetCodeView = View:extend()

function LeetCodeView:new()
  LeetCodeView.super.new(self)
  self.scrollable = true
  self.state         = "auth"
  self.cookie_input  = ""
  self.auth_status   = ""
  self.problems      = {}
  self.total_problems= 0
  self.search_input  = ""
  self.search_focus  = false
  self.difficulty    = ""
  self.scroll_y      = 0
  self.list_scroll_y = 0
  self.selected_idx  = 1
  self.page_skip     = 0
  self.loading_msg   = ""
  self.current       = nil
  self.open_lang     = "python3"
  self.result        = nil
  self.result_type   = "run"
  self._search_timer = nil
  self.run_req_id    = nil
end

function LeetCodeView:get_name()
  return "LeetCode"
end

function LeetCodeView:supports_text_input()
  return true
end

function LeetCodeView:on_text_input(text)
  if self.state == "auth" then
    self.cookie_input = self.cookie_input .. text
    core.redraw = true
  elseif self.state == "list" then
    self.search_input = self.search_input .. text
    self._search_timer = system.get_time() + 0.4
    core.redraw = true
  end
end

function LeetCodeView:on_key_pressed(key)
  local handled = false
  if key == "escape" then
    command.perform("leetcode:toggle")
    handled = true
  elseif self.state == "auth" then
    if key == "return" then command.perform("leetcode:connect"); handled = true
    elseif key == "backspace" then
      self.cookie_input = self.cookie_input:sub(1, -2)
      handled = true
    end
  elseif self.state == "list" then
    if key == "up" then
      self.selected_idx = math.max(1, self.selected_idx - 1)
      local target_y = (self.selected_idx - 1) * 24 * SCALE
      if target_y < self.list_scroll_y then self.list_scroll_y = target_y end
      handled = true
    elseif key == "down" then
      self.selected_idx = math.min(#self.problems, self.selected_idx + 1)
      local target_y = (self.selected_idx - 1) * 24 * SCALE
      local list_h = 300 * SCALE
      if target_y + 24*SCALE > self.list_scroll_y + list_h then
        self.list_scroll_y = target_y + 24*SCALE - list_h
      end
      handled = true
    elseif key == "return" then
      if self.search_focus then
        self.search_focus = false
      else
        command.perform("leetcode:open-problem")
      end
      handled = true
    elseif key == "tab" then self.search_focus = not self.search_focus; handled = true
    elseif key == "backspace" then
      self.search_input = self.search_input:sub(1, -2)
      self._search_timer = system.get_time() + 0.4
      handled = true
    end
  elseif self.state == "problem" then
    if key == "backspace" then self.state = "list"; self.search_focus = true; handled = true
    elseif key == "down" then self.scroll_y = self.scroll_y + 40; handled = true
    elseif key == "up" then self.scroll_y = math.max(0, self.scroll_y - 40); handled = true
    end
  elseif self.state == "result" then
    if key == "backspace" or key == "return" then command.perform("leetcode:toggle"); handled = true end
  end

  if handled then
    core.redraw = true
    return true
  end
  return false
end

function LeetCodeView:update()
  LeetCodeView.super.update(self)
  if self._search_timer and system.get_time() >= self._search_timer then
    self._search_timer = nil
    self.page_skip     = 0
    command.perform("leetcode:fetch-list")
  end
end

-- We declare lc_view as the global active instance
local lc_view = nil

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

local function open_problem(problem, lang)
  local dir = USERDIR .. PATHSEP .. "leetcode"
  system.mkdir(dir)
  local num   = string.format("%04d", tonumber(problem.id or problem.question_id) or 0)
  local ext   = LANG_EXT[lang] or "txt"
  
  -- Create markdown description
  local fname_md = num .. "_" .. problem.slug .. ".md"
  local fpath_md = dir .. PATHSEP .. fname_md
  local f_md = io.open(fpath_md, "r")
  if not f_md then
    local content = "# " .. num .. ". " .. problem.title .. "\n"
    content = content .. "**Difficulty:** " .. (problem.difficulty or "") .. " | [LeetCode Link](https://leetcode.com/problems/" .. problem.slug .. "/)\n\n"
    content = content .. "---\n\n"
    content = content .. (problem.content_plain or "")
    if problem.test_cases and problem.test_cases ~= "" then
      content = content .. "\n\n### Default Testcases\n```\n" .. problem.test_cases:gsub("\\n", "\n") .. "\n```\n"
    end
    local wf_md = io.open(fpath_md, "w")
    if wf_md then wf_md:write(content); wf_md:close() end
  else
    f_md:close()
  end
  
  local fname = num .. "_" .. problem.slug .. "." .. ext
  local fpath = dir .. PATHSEP .. fname
  local f = io.open(fpath, "r")
  if not f then
    local starter = (problem.starters or {})[lang] or ""
    local header = ""
    local pid = problem.id or problem.question_id or "0"
    if ext == "py" then
      header = "# " .. pid .. ". " .. problem.title .. "\n# " .. (problem.difficulty or "") .. " | https://leetcode.com/problems/" .. problem.slug .. "/\n\n"
    elseif ext == "cpp" or ext == "c" or ext == "java" or ext == "cs" or ext == "js" or ext == "ts" then
      header = "// " .. pid .. ". " .. problem.title .. "\n// " .. (problem.difficulty or "") .. " | https://leetcode.com/problems/" .. problem.slug .. "/\n\n"
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

  local doc_md = core.open_doc(fpath_md)
  local doc_code = core.open_doc(fpath)
  
  core.root_view:open_doc(doc_md)
  
  local views = core.get_views_referencing_doc(doc_code)
  local view_code = views[1]
  
  if not view_code then
    local DocView = require "core.docview"
    view_code = DocView(doc_code)
    local node = core.root_view:get_active_node()
    local new_node = node:split("right")
    new_node:add_view(view_code)
  end
  
  core.set_active_view(view_code)

  command.perform("leetcode:toggle")
  core.redraw  = true
end

command.add(nil, {
  ["leetcode:auto-detect"] = function()
    if not lc_view then return end
    lc_view.state = "loading"
    lc_view.loading_msg = "Auto-detecting cookies..."
    core.redraw = true
    api_call({ cmd = "auth_auto" }, function(res)
      if not lc_view then return end
      if res.ok then
        lc_view.auth_status = "Connected via " .. (res.data.detected_from or "browser")
        lc_view.state = "list"; lc_view.search_focus = true
        command.perform("leetcode:fetch-list")
      else
        lc_view.state = "auth"
        lc_view.auth_status = "Auto-detect failed: " .. (res.error or "Unknown error")
        core.redraw = true
      end
    end)
  end,
  ["leetcode:toggle"] = function()
    if lc_view and core.root_view.root_node:get_node_for_view(lc_view) then
      local node = core.root_view.root_node:get_node_for_view(lc_view)
      node:close_view(core.root_view.root_node, lc_view)
      lc_view = nil
    else
      lc_view = LeetCodeView()
      core.root_view:get_active_node():add_view(lc_view)
      if lc_view.state == "auth" then
        api_call({cmd = "auth_check"}, function(resp)
          if not lc_view then return end
          if resp.ok then
            lc_view.auth_status = "[+] Logged in as " .. resp.data.username
            lc_view.state = "list"; lc_view.search_focus = true
            if #lc_view.problems == 0 then command.perform("leetcode:fetch-list") end
          else
            lc_view.auth_status = ""
          end
          core.redraw = true
        end)
      end
    end
    core.redraw = true
  end,
  ["leetcode:connect"] = function()
    if not lc_view then return end
    lc_view.auth_status = "checking..."
    core.redraw = true
    
    local sess_match = lc_view.cookie_input:match("LEETCODE_SESSION=([^;]+)")
    local csrf_match = lc_view.cookie_input:match("csrftoken=([^;]+)")
    
    if not sess_match or not csrf_match then
      lc_view.auth_status = "Invalid cookie string"
      core.redraw = true
      return
    end
    
    api_call({
      cmd     = "auth_set",
      session = sess_match,
      csrf    = csrf_match,
      raw     = lc_view.cookie_input
    }, function(resp)
      if not lc_view then return end
      if resp.ok then
        lc_view.auth_status = "[+] Logged in as " .. resp.data.username
        lc_view.state = "list"; lc_view.search_focus = true
        command.perform("leetcode:fetch-list")
      else
        lc_view.auth_status = "✗ Invalid cookies"
      end
      core.redraw = true
    end)
  end,
  ["leetcode:fetch-list"] = function()
    if not lc_view then return end
    lc_view.state       = "list"
    lc_view.is_fetching = true
    core.redraw       = true
    api_call({
      cmd        = "problem_list",
      skip       = lc_view.page_skip,
      limit      = 50,
      difficulty = lc_view.difficulty,
      search     = lc_view.search_input,
    }, function(resp)
      if not lc_view then return end
      lc_view.is_fetching = false
      if resp.ok then
        lc_view.problems       = resp.data.problems
        lc_view.total_problems = resp.data.total
        lc_view.selected_idx   = 1
      else
        if resp.error and resp.error:match("Not logged in") then
          lc_view.state = "auth"
          lc_view.auth_status = "Session expired"
        else
          core.log("[LeetCode] " .. (resp.error or "Unknown error"))
        end
      end
      core.redraw = true
    end)
  end,
  ["leetcode:open-problem"] = function()
    if not lc_view or lc_view.state ~= "list" then return end
    local p = lc_view.problems[lc_view.selected_idx]
    if not p then return end
    lc_view.state       = "loading"
    lc_view.loading_msg = "Loading " .. p.title
    core.redraw       = true
    api_call({ cmd = "problem_detail", slug = p.slug }, function(resp)
      if not lc_view then return end
      if resp.ok then
        lc_view.current = resp.data
        lc_view.state   = "problem"
        lc_view.scroll_y = 0
      else
        lc_view.state = "list"; lc_view.search_focus = true
        core.log("[LeetCode] " .. (resp.error or "Failed to load problem"))
      end
      core.redraw = true
    end)
  end,
  ["leetcode:run"] = function()
    local meta = get_active_meta()
    local code = get_active_code()
    if not meta or not code then
      core.log("[LeetCode] Open a LeetCode solution file first (from USERDIR/leetcode/)")
      return
    end
    if not lc_view or not core.root_view.root_node:get_node_for_view(lc_view) then command.perform("leetcode:toggle") end
    lc_view.state       = "running"
    lc_view.loading_msg = "Running test cases"
    core.redraw       = true
    local my_req_id = tostring(req_counter + 1)
    lc_view.run_req_id = my_req_id
    api_call({
      cmd         = "run_code",
      slug        = meta.slug,
      question_id = meta.question_id,
      lang        = meta.lang,
      code        = code,
      test_input  = meta.test_cases:gsub("\\n", "\n"),
    }, function(resp)
      if not lc_view or lc_view.run_req_id ~= my_req_id then return end
      lc_view.result      = resp.data or {}
      lc_view.result.ok   = resp.ok
      lc_view.result.err  = resp.error
      lc_view.result_type = "run"
      lc_view.state       = "result"
      core.redraw       = true
    end)
  end,
  ["leetcode:submit"] = function()
    local meta = get_active_meta()
    local code = get_active_code()
    if not meta or not code then
      core.log("[LeetCode] Open a LeetCode solution file first (from USERDIR/leetcode/)")
      return
    end
    if not lc_view or not core.root_view.root_node:get_node_for_view(lc_view) then command.perform("leetcode:toggle") end
    lc_view.state       = "running"
    lc_view.loading_msg = "Submitting to LeetCode"
    core.redraw       = true
    local my_req_id = tostring(req_counter + 1)
    lc_view.run_req_id = my_req_id
    api_call({
      cmd         = "submit",
      slug        = meta.slug,
      question_id = meta.question_id,
      lang        = meta.lang,
      code        = code,
    }, function(resp)
      if not lc_view or lc_view.run_req_id ~= my_req_id then return end
      lc_view.result      = resp.data or {}
      lc_view.result.ok   = resp.ok
      lc_view.result.err  = resp.error
      lc_view.result_type = "submit"
      lc_view.state       = "result"
      core.redraw       = true
    end)
  end,
})

keymap.add({
  ["ctrl+shift+l"] = "leetcode:toggle",
  ["alt+r"] = "leetcode:run",
  ["alt+s"] = "leetcode:submit",
})



command.add(
  function() return core.active_view and core.active_view:is(LeetCodeView) end,
  {
    ["leetcode:up"] = function() core.active_view:on_key_pressed("up") end,
    ["leetcode:down"] = function() core.active_view:on_key_pressed("down") end,
    ["leetcode:backspace"] = function() core.active_view:on_key_pressed("backspace") end,
    ["leetcode:return"] = function() core.active_view:on_key_pressed("return") end,
    ["leetcode:tab"] = function() core.active_view:on_key_pressed("tab") end,
    ["leetcode:escape"] = function() core.active_view:on_key_pressed("escape") end,
    ["leetcode:paste"] = function() 
      local text = system.get_clipboard()
      if text then
        text = text:gsub("[\r\n]", "")
        local v = core.active_view
        if v.state == "auth" then
          v.cookie_input = v.cookie_input .. text
        elseif v.state == "list" then
          v.search_input = v.search_input .. text
          v._search_timer = system.get_time() + 0.4
        end
        core.redraw = true
      end
    end,
  }
)

keymap.add({
  ["up"] = "leetcode:up",
  ["down"] = "leetcode:down",
  ["backspace"] = "leetcode:backspace",
  ["return"] = "leetcode:return",
  ["tab"] = "leetcode:tab",
  ["escape"] = "leetcode:escape",
  ["ctrl+v"] = "leetcode:paste",
  ["gui+v"] = "leetcode:paste",
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

function LeetCodeView:on_mouse_pressed(btn, x, y, clicks)
  local res = LeetCodeView.super.on_mouse_pressed(self, btn, x, y, clicks)
  if res then return res end

  local sw, sh = self.size.x, self.size.y
  local w, h = 700 * SCALE, 500 * SCALE
  local mx, my = self.position.x + (sw - w) / 2, self.position.y + (sh - h) / 2
  local cx = mx + 20 * SCALE
  local cw = w - 40 * SCALE

  if self.state == "auth" and btn == "left" then
    local cy = my + 20 * SCALE
    cy = cy + 30*SCALE
    local auto_btn_y = cy
    cy = cy + 40*SCALE + 30*SCALE + 20*SCALE
    local box1_y = cy
    cy = cy + 40*SCALE + 20*SCALE
    local box2_y = cy
    cy = cy + 50*SCALE
    local btn_y = cy
    
    if x >= cx and x <= cx + 320*SCALE and y >= auto_btn_y and y <= auto_btn_y + 30*SCALE then
      command.perform("leetcode:auto-detect")
      return true
    end
    if x >= cx and x <= cx + 100*SCALE and y >= btn_y and y <= btn_y + 30*SCALE then
      command.perform("leetcode:connect")
      return true
    end
  end

  if self.state == "list" and btn == "left" then
    local cy = my + 80 * SCALE
    -- Search box click
    if y >= cy and y <= cy + 24*SCALE then
      if x >= cx + 60*SCALE and x <= cx + cw then
        self.search_focus = true
        core.redraw = true
        return true
      end
    end
    
    -- Pagination click
    local btn_cy = my + h - 40*SCALE
    if y >= btn_cy and y <= btn_cy + 24*SCALE then
      if x >= cx + cw/2 - 100*SCALE and x <= cx + cw/2 - 20*SCALE then
        if self.page_skip >= 50 then
          self.page_skip = self.page_skip - 50
          command.perform("leetcode:fetch-list")
        end
        return true
      elseif x >= cx + cw/2 + 20*SCALE and x <= cx + cw/2 + 120*SCALE then
        if self.page_skip + 50 < self.total_problems then
          self.page_skip = self.page_skip + 50
          command.perform("leetcode:fetch-list")
        end
        return true
      end
    end
    
    self.search_focus = false
    core.redraw = true
    
    -- Handle click on a problem
    local list_y = cy + 35*SCALE + 10*SCALE
    if y >= list_y and y < btn_cy then
      local idx = math.floor((y - list_y + self.list_scroll_y) / (24*SCALE)) + 1
      if idx >= 1 and idx <= #self.problems then
        self.selected_idx = idx
        command.perform("leetcode:open-problem")
      end
      return true
    end
  end

  if self.state == "problem" and btn == "left" then
    local cy = my + h - 170*SCALE + 15*SCALE
    local col1_x = mx + 20*SCALE + 80*SCALE
    local col2_x = mx + 20*SCALE + 250*SCALE
    
    local sorted_langs = {}
    for lang, _ in pairs(self.current.starters or {}) do table.insert(sorted_langs, lang) end
    table.sort(sorted_langs)
    
    local lang_cy = cy
    local is_col2 = false
    for _, lang in ipairs(sorted_langs) do
      local bx = is_col2 and col2_x or col1_x
      local bw = style.font:get_width("[" .. lang .. "]")
      if y >= lang_cy and y <= lang_cy + 20*SCALE and x >= bx and x <= bx + bw then
        open_problem(self.current, lang)
        return true
      end
      if is_col2 then
        lang_cy = lang_cy + 24*SCALE
        is_col2 = false
      else
        is_col2 = true
      end
    end
  end
  return false
end

function LeetCodeView:on_mouse_wheel(delta)
  if self.state == "problem" then
    self.scroll_y = math.max(0, self.scroll_y - delta * 40)
    core.redraw = true
  elseif self.state == "list" then
    self.list_scroll_y = math.max(0, (self.list_scroll_y or 0) - delta * 40)
    core.redraw = true
  end
  return true
end

function LeetCodeView:draw()
  self:draw_background(style.background)

  local sw, sh = self.size.x, self.size.y
  local w, h = 700 * SCALE, 500 * SCALE
  local x, y = self.position.x + (sw - w) / 2, self.position.y + (sh - h) / 2
  
  -- We draw the central panel
  renderer.draw_rect(x, y, w, h, style.background)
  renderer.draw_rect(x, y, w, 2 * SCALE, style.accent)
  
  local cx, cy = x + 20 * SCALE, y + 20 * SCALE
  local cw = w - 40 * SCALE

  if self.state == "auth" then
    renderer.draw_text(style.font, "> LeetCode - Connect", cx, cy, style.text)
    cy = cy + 30*SCALE
    
    renderer.draw_rect(cx, cy, 320*SCALE, 30*SCALE, style.accent)
    renderer.draw_text(style.font, "Auto-detect from Chrome / Firefox", cx + 15*SCALE, cy + 5*SCALE, style.background)
    cy = cy + 40*SCALE
    
    renderer.draw_text(style.font, "--- or paste manually ---", cx, cy, style.dim)
    cy = cy + 30*SCALE
    
    renderer.draw_text(style.font, "Full Cookie String:", cx, cy, style.text)
    cy = cy + 20*SCALE
    renderer.draw_rect(cx, cy, cw, 30*SCALE, style.background2)
    if self.cookie_input == "" then
      renderer.draw_text(style.font, "e.g. csrftoken=...; LEETCODE_SESSION=...", cx + 5*SCALE, cy + 5*SCALE, style.dim)
    end
    
    local cookie_text = self.cookie_input:gsub(".", "*")
    if os.time() % 2 == 0 then cookie_text = cookie_text .. "|" end
    
    local visible_text = cookie_text
    local tw = style.font:get_width(cookie_text)
    if tw > cw - 20*SCALE then
       local char_w = style.font:get_width("*")
       if char_w > 0 then
         local chars_fit = math.floor((cw - 20*SCALE) / char_w)
         visible_text = cookie_text:sub(-chars_fit)
       end
    end
    
    renderer.draw_text(style.font, visible_text, cx + 5*SCALE, cy + 5*SCALE, style.text)
    cy = cy + 50*SCALE
    
    renderer.draw_rect(cx, cy, 100*SCALE, 30*SCALE, style.accent)
    renderer.draw_text(style.font, "Connect", cx + 20*SCALE, cy + 5*SCALE, style.background)
    
    if self.auth_status ~= "" then
      renderer.draw_text(style.font, "Status: " .. self.auth_status, cx, cy + 50*SCALE, style.text)
    end
    
  elseif self.state == "loading" or self.state == "running" then
    local dots = string.rep(".", math.floor(system.get_time() * 3) % 4)
    local msg = self.loading_msg .. dots
    local tw = style.font:get_width(msg)
    renderer.draw_text(style.font, msg, cx + cw/2 - tw/2, cy + h/2 - 20*SCALE, style.accent)
    
  elseif self.state == "list" then
    local diff_color = style.text
    if self.difficulty == "EASY" then diff_color = LC_COLORS.easy
    elseif self.difficulty == "MEDIUM" then diff_color = LC_COLORS.medium
    elseif self.difficulty == "HARD" then diff_color = LC_COLORS.hard end
    
    renderer.draw_text(style.font, "LeetCode Browser", cx, cy, style.text)
    renderer.draw_text(style.font, "[ALL]  [Easy]  [Med]  [Hard]", cx + 150*SCALE, cy, diff_color)
    cy = cy + 30*SCALE
    
    renderer.draw_text(style.font, "Ctrl+R: Run Code  |  Ctrl+Shift+S: Submit  |  Tab/Click: Focus Search", cx, cy, style.accent)
    cy = cy + 30*SCALE
    
    renderer.draw_text(style.font, "Search:", cx, cy, style.text)
    local search_x = cx + 60*SCALE
    local search_y = cy
    local search_w = cw - 60*SCALE
    local search_h = 24*SCALE
    
    local border_color = self.search_focus and style.accent or style.dim
    renderer.draw_rect(search_x - 1*SCALE, search_y - 1*SCALE, search_w + 2*SCALE, search_h + 2*SCALE, border_color)
    renderer.draw_rect(search_x, search_y, search_w, search_h, style.background2)
    
    renderer.draw_text(style.font, self.search_input, search_x + 5*SCALE, search_y + 2*SCALE, style.text)
    
    if self.search_focus then
      local text_width = style.font:get_width(self.search_input)
      local cursor_x = search_x + 5*SCALE + text_width + 2*SCALE
      if (system.get_time() % 1.0) < 0.5 then
        renderer.draw_rect(cursor_x, search_y + 4*SCALE, 2*SCALE, search_h - 8*SCALE, style.text)
      end
    end
    
    cy = cy + 35*SCALE
    
    renderer.draw_rect(cx, cy, cw, 1*SCALE, style.dim)
    cy = cy + 10*SCALE
    
    local list_h = (y + h - 50*SCALE) - cy
    
    if self.is_fetching then
      local dots = string.rep(".", math.floor(system.get_time() * 3) % 4)
      local msg = "Fetching problems" .. dots
      local tw = style.font:get_width(msg)
      renderer.draw_text(style.font, msg, cx + cw/2 - tw/2, cy + list_h/2, style.accent)
    else
      local max_scroll = math.max(0, #self.problems * 24*SCALE - list_h)
      self.list_scroll_y = math.min(math.max(0, self.list_scroll_y or 0), max_scroll)
      
      core.push_clip_rect(cx, cy, cw, list_h)
      local item_y = cy - self.list_scroll_y
      for i, p in ipairs(self.problems) do
        if item_y + 24*SCALE > cy and item_y < cy + list_h then
          if i == self.selected_idx then
            renderer.draw_rect(cx - 5*SCALE, item_y - 2*SCALE, cw + 10*SCALE, 24*SCALE, style.line_highlight)
          end
          renderer.draw_text(style.font, "#" .. p.id, cx, item_y, style.dim)
          local title = p.title
          if #title > 45 then title = title:sub(1, 42) .. "..." end
          renderer.draw_text(style.font, title, cx + 50*SCALE, item_y, style.text)
          local dc = p.difficulty == "Easy" and LC_COLORS.easy or (p.difficulty == "Medium" and LC_COLORS.medium or LC_COLORS.hard)
          renderer.draw_text(style.font, p.difficulty, cx + 450*SCALE, item_y, dc)
          renderer.draw_text(style.font, p.ac_rate .. "%", cx + 550*SCALE, item_y, style.dim)
          if p.paid then renderer.draw_text(style.font, "(Premium)", cx + 620*SCALE, item_y, LC_COLORS.tle) end
        end
        item_y = item_y + 24*SCALE
      end
      core.pop_clip_rect()
    end
    cy = y + h - 50*SCALE
    
    -- Draw Pagination at bottom
    local page = math.floor(self.page_skip / 50) + 1
    local total_pages = math.max(1, math.ceil(self.total_problems / 50))
    renderer.draw_text(style.font, "Page " .. page .. " / " .. total_pages, cx, cy + 10*SCALE, style.dim)
    renderer.draw_text(style.font, "[< Prev Page]", cx + cw/2 - 100*SCALE, cy + 10*SCALE, self.page_skip > 0 and style.accent or style.dim)
    renderer.draw_text(style.font, "[Next Page >]", cx + cw/2 + 20*SCALE, cy + 10*SCALE, (self.page_skip + 50) < self.total_problems and style.accent or style.dim)
    
  elseif self.state == "problem" and self.current then
    local p = self.current
    local dc = p.difficulty == "Easy" and LC_COLORS.easy or (p.difficulty == "Medium" and LC_COLORS.medium or LC_COLORS.hard)
    renderer.draw_text(style.font, "<- Back", cx, cy, style.dim)
    renderer.draw_text(style.font, p.title, cx + 80*SCALE, cy, style.text)
    renderer.draw_text(style.font, "[" .. p.difficulty .. "]", cx + cw - 100*SCALE, cy, dc)
    cy = cy + 25*SCALE
    
    if p.topics and #p.topics > 0 then
      local topics_str = "Topics: " .. table.concat(p.topics, ", ")
      renderer.draw_text(style.font, topics_str, cx, cy, style.dim)
      cy = cy + 25*SCALE
    end
    
    if p.companies and #p.companies > 0 then
      local comp_str = "Companies: " .. table.concat(p.companies, ", ")
      renderer.draw_text(style.font, comp_str, cx, cy, style.accent)
      cy = cy + 25*SCALE
    elseif p.companies and #p.companies == 0 then
      renderer.draw_text(style.font, "Companies: [Premium Required / Not Available]", cx, cy, style.dim)
      cy = cy + 25*SCALE
    end
    
    renderer.draw_text(style.font, "Click a language below to scaffold your local solution file.", cx, cy, style.accent)
    cy = cy + 25*SCALE
    renderer.draw_rect(cx, cy, cw, 1*SCALE, style.dim)
    cy = cy + 15*SCALE
    
    local text_area_h = (y + h - 180*SCALE) - cy
    core.push_clip_rect(cx, cy, cw, text_area_h)
    draw_text_wrap(style.font, style.text, p.content_plain, cx, cy - self.scroll_y, cw)
    core.pop_clip_rect()
    
    cy = y + h - 170*SCALE
    renderer.draw_rect(cx, cy, cw, 1*SCALE, style.dim)
    cy = cy + 15*SCALE
    renderer.draw_text(style.font, "Open in:", cx, cy, style.text)
    
    local col1_x = cx + 80*SCALE
    local col2_x = cx + 250*SCALE
    local lang_cy = cy
    local is_col2 = false
    
    local sorted_langs = {}
    for lang, _ in pairs(p.starters or {}) do table.insert(sorted_langs, lang) end
    table.sort(sorted_langs)
    
    for _, lang in ipairs(sorted_langs) do
      local bx = is_col2 and col2_x or col1_x
      renderer.draw_text(style.font, "[" .. lang .. "]", bx, lang_cy, style.accent)
      if is_col2 then
        lang_cy = lang_cy + 24*SCALE
        is_col2 = false
      else
        is_col2 = true
      end
    end
    
  elseif self.state == "result" and self.result then
    local res = self.result
    local title_c = res.ok and LC_COLORS.accepted or LC_COLORS.wrong
    if res.status:match("Limit Exceeded") then title_c = LC_COLORS.tle end
    if res.status:match("Error") then title_c = LC_COLORS.hard end
    
    renderer.draw_text(style.font, res.ok and "[+] " or "[-] ", cx, cy, title_c)
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
      
      if not res.ok and self.result_type == "run" then
        renderer.draw_text(style.font, "Your output:", cx, cy, style.text)
        cy = draw_text_wrap(style.font, LC_COLORS.wrong, table.concat(res.code_output or {}, "\n"), cx + 120*SCALE, cy, cw - 120*SCALE) + 10*SCALE
        renderer.draw_text(style.font, "Expected:", cx, cy, style.text)
        cy = draw_text_wrap(style.font, LC_COLORS.accepted, table.concat(res.expected_output or {}, "\n"), cx + 120*SCALE, cy, cw - 120*SCALE) + 10*SCALE
      end
    end
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
      end
    })
  end
end)
