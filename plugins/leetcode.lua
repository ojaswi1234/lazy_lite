-- mod-version:3
local core    = require "core"
local common  = require "core.common"
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
  easy     = { common.color("#00b8a3") },
  medium   = { common.color("#ffc01e") },
  hard     = { common.color("#ff375f") },
  accepted = { common.color("#2cbb5d") },
  tle      = { common.color("#ff375f") }
}

-- Actually, wait, `common.color` returns 4 unpacked values!
-- By doing `{ common.color(...) }`, I am wrapping the 4 returned values into a single array `{r, g, b, a}`!
-- So `{ common.color("#00b8a3") }` IS correct for Lite-XL colors!

local TOPIC_TAGS = {
  "array", "string", "hash-table", "dynamic-programming", "math", "sorting",
  "greedy", "depth-first-search", "database", "binary-search", "breadth-first-search",
  "tree", "matrix", "two-pointers", "bit-manipulation", "binary-tree", "heap-priority-queue",
  "stack", "prefix-sum", "graph", "design", "simulation", "counting", "backtracking",
  "sliding-window", "union-find", "linked-list", "ordered-set", "monotonic-stack",
  "enumeration", "recursion", "trie", "divide-and-conquer", "binary-search-tree", "geometry",
  "queue", "memoization", "topological-sort", "segment-tree", "game-theory"
}

local COMPANIES = { "amazon", "google", "microsoft", "facebook", "apple", "adobe", "bloomberg", "uber", "oracle", "goldman-sachs", "linkedin", "yahoo", "salesforce", "bytedance", "tiktok", "doordash", "samsung", "snapchat", "cisco", "flipkart", "vmware", "twitter", "infosys", "expedia", "walmart-global-tech", "ibm", "intuit", "atlassian", "nvidia", "visa", "airbnb", "sprinklr", "yandex", "de-shaw", "ebay", "paypal", "accenture", "tcs", "morgan-stanley", "paytm", "phonepe", "jpmorgan", "dunzo", "citadel", "makemytrip", "american-express", "walmart-labs", "accolite", "servicenow", "qualtrics", "spotify", "mathworks", "capital-one", "wayfair", "pinterest", "twilio", "zoho", "grab", "walmart", "sap", "nutanix", "square", "oyo", "rubrik", "deutsche-bank", "media.net", "tesla", "nagarro", "karat", "cognizant", "jpmorgan-and-chase", "akuna-capital", "indeed", "dropbox", "publicis-sapient", "zomato", "arcesium", "qualcomm", "lyft", "quora", "sap-labs", "meesho", "databricks", "capgemini", "booking.com", "barclays", "snowflake", "wipro", "snapdeal", "geico", "robinhood", "airtel", "swiggy", "docusign", "directi", "sharechat", "hrt", "roblox", "shopee", "expedia-group", "hsbc", "cruise-automation", "coursera", "intel", "codenation", "spinny", "ola", "optum", "wish", "zoom", "amdocs", "two-sigma", "morgan-stanely" }

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
  self.difficulty    = "ALL"
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

local lc_view = nil
local last_run_time = 0
local last_submit_time = 0
local last_fetch_time = 0

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

local function has_lint_errors(doc)
  if not doc or not doc.filename then return false end
  local lint = package.loaded["plugins.lintplus"]
  if not lint or not lint.messages then return false end
  
  local path = core.project_absolute_path(doc.filename)
  local errs = lint.messages[path]
  if errs and errs.lines then
    for _, msgs in pairs(errs.lines) do
      for _, msg in ipairs(msgs) do
        if msg.kind == "error" then return true end
      end
    end
  end
  return false
end

local function get_active_code()
  local doc = core.active_view and core.active_view.doc
  if not doc then return nil end
  local lines = {}
  for i = 1, #doc.lines do lines[i] = doc.lines[i] end
  return table.concat(lines)
end

local function open_problem(problem, lang)
  local dir_parent = USERDIR .. PATHSEP .. "leetcode"
  system.mkdir(dir_parent)
  local num   = string.format("%04d", tonumber(problem.id or problem.question_id) or 0)
  local dir = dir_parent .. PATHSEP .. "Leetcode " .. num
  system.mkdir(dir)
  local ext   = LANG_EXT[lang] or "txt"
  
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
      header = "# " .. pid .. ". " .. problem.title .. "\n# " .. (problem.difficulty or "") .. " | https://leetcode.com/problems/" .. problem.slug .. "/\n"
      header = header .. "# Shortcuts: [Ctrl+S] Save | [Alt+R] Run | [Alt+S] Submit | [Ctrl+Q] Close & Return\n\n"
    elseif ext == "cpp" or ext == "c" or ext == "java" or ext == "cs" or ext == "js" or ext == "ts" then
      header = "// " .. pid .. ". " .. problem.title .. "\n// " .. (problem.difficulty or "") .. " | https://leetcode.com/problems/" .. problem.slug .. "/\n"
      header = header .. "// Shortcuts: [Ctrl+S] Save | [Alt+R] Run | [Alt+S] Submit | [Ctrl+Q] Close & Return\n\n"
    else
      header = "// " .. pid .. ". " .. problem.title .. "\n// " .. (problem.difficulty or "") .. " | https://leetcode.com/problems/" .. problem.slug .. "/\n"
      header = header .. "// Shortcuts: [Ctrl+S] Save | [Alt+R] Run | [Alt+S] Submit | [Ctrl+Q] Close & Return\n\n"
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

  local node = core.root_view:get_active_node_default()
  node:add_view(core.open_doc(fpath_md))
  command.perform("line-wrapping:enable")
  
  -- Open the code file natively for editing
  node:add_view(core.open_doc(fpath))
  local node = core.root_view:get_active_node_default()
  node:split("right")
  core.root_view:open_doc(core.open_doc(fpath))
  
  local doc_code = core.open_doc(fpath)
  local views = core.get_views_referencing_doc(doc_code)
  local view_code = views[1]
  
  if not view_code then
    local DocView = require "core.docview"
    view_code = DocView(doc_code)
    local node = core.root_view:get_active_node_default()
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
    lc_view.state = "auth"
    lc_view.auth_status = "checking for old creds..... "
    core.redraw = true
    api_call({ cmd = "auth_auto" }, function(res)
      if not lc_view then return end
      if res.ok then
        lc_view.auth_status = "checking for old creds..... Found !! ....... "
        lc_view.user_stats = res.data.stats
        core.redraw = true
        core.add_thread(function()
          local start = system.get_time()
          while system.get_time() - start < 0.8 do coroutine.yield(0.1) end
          if lc_view and lc_view.state == "auth" then
            lc_view.state = "list"; lc_view.search_focus = true
            command.perform("leetcode:fetch-list")
            core.redraw = true
          end
        end)
      else
        lc_view.state = "auth"
        lc_view.auth_status = "creds expired...... Paste/Auto fetch new cookies"
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
      core.root_view:get_active_node_default():add_view(lc_view)
      if lc_view.state == "auth" then
        lc_view.auth_status = "checking for old creds..... "
        api_call({cmd = "auth_check"}, function(resp)
          if not lc_view then return end
          if resp.ok then
            lc_view.auth_status = "checking for old creds..... Found !! ....... "
            lc_view.user_stats = resp.data.stats
            core.redraw = true
            core.add_thread(function()
              local start = system.get_time()
              while system.get_time() - start < 0.8 do coroutine.yield(0.1) end
              if lc_view and lc_view.state == "auth" then
                lc_view.state = "list"; lc_view.search_focus = true
                if #lc_view.problems == 0 then command.perform("leetcode:fetch-list") end
                core.redraw = true
              end
            end)
          else
            if resp.error == "Not logged in" then
              lc_view.auth_status = "creds expired...... Paste/Auto fetch new cookies"
            else
              lc_view.auth_status = resp.error or "creds expired...... Paste/Auto fetch new cookies"
            end
          end
          core.redraw = true
        end)
      end
    end
    core.redraw = true
  end,
  ["leetcode:connect"] = function()
    if not lc_view then return end
    lc_view.auth_status = "checking for old creds..... "
    core.redraw = true
    
    local sess_match = lc_view.cookie_input:match("LEETCODE_SESSION=([^;]+)")
    local csrf_match = lc_view.cookie_input:match("csrftoken=([^;]+)")
    
    if not sess_match or not csrf_match then
      lc_view.auth_status = "creds expired...... Paste/Auto fetch new cookies"
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
        lc_view.auth_status = "checking for old creds..... Found !! ....... "
        lc_view.user_stats = resp.data.stats
        core.redraw = true
        core.add_thread(function()
          local start = system.get_time()
          while system.get_time() - start < 0.8 do coroutine.yield(0.1) end
          if lc_view and lc_view.state == "auth" then
            lc_view.state = "list"; lc_view.search_focus = true
            command.perform("leetcode:fetch-list")
            core.redraw = true
          end
        end)
      else
        lc_view.auth_status = "creds expired...... Paste/Auto fetch new cookies"
      end
      core.redraw = true
    end)
  end,
  ["leetcode:fetch-list"] = function()
    if not lc_view then return end
    if not lc_view then return end
    -- Throttle removed to prevent missed clicks
    
    lc_view.state       = "list"
    lc_view.is_fetching = true
    core.redraw       = true
    api_call({
      cmd        = "problem_list",
      skip       = lc_view.page_skip,
      limit      = 50,
      difficulty = lc_view.difficulty == "ALL" and "" or lc_view.difficulty,
      search     = lc_view.search_input,
    }, function(resp)
      if not lc_view then return end
      lc_view.is_fetching = false
      if resp.ok then
        lc_view.problems       = resp.data.problems
        lc_view.total_problems = resp.data.total
        lc_view.selected_idx   = 1
        lc_view.list_scroll_y  = 0
      else
        if resp.error and resp.error:match("Not logged in") then
          lc_view.state = "auth"
          lc_view.auth_status = "creds expired...... Paste/Auto fetch new cookies"
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
  ["leetcode:daily-challenge"] = function()
    core.log("[LeetCode] Fetching Daily Challenge...")
    api_call({ cmd = "daily_challenge" }, function(resp)
      if resp.ok and resp.data and resp.data.slug then
        if not lc_view or not core.root_view.root_node:get_node_for_view(lc_view) then command.perform("leetcode:toggle") end
        lc_view.state = "loading"
        lc_view.loading_msg = "Loading Daily Challenge"
        core.redraw = true
        api_call({ cmd = "problem_detail", slug = resp.data.slug }, function(p_resp)
          if not lc_view then return end
          if p_resp.ok then
            lc_view.current = p_resp.data
            lc_view.state   = "problem"
            lc_view.scroll_y = 0
          else
            lc_view.state = "list"
            core.log("[LeetCode] Failed to load daily problem")
          end
          core.redraw = true
        end)
      else
        core.log("[LeetCode] Failed to fetch Daily Challenge")
      end
    end)
  end,
  ["leetcode:random"] = function()
    if not lc_view or lc_view.total_problems == 0 then return end
    
    lc_view.loading_msg = "Picking a random problem"
    lc_view.state = "loading"
    core.redraw = true
    
    local function pick_random()
      local idx = math.random(1, lc_view.total_problems)
      api_call({
        cmd = "problem_list",
        skip = idx - 1,
        limit = 1,
        difficulty = lc_view.difficulty == "ALL" and "" or lc_view.difficulty,
        search = lc_view.search_input,
      }, function(resp)
        if not lc_view then return end
        if resp.ok and resp.data and resp.data.problems and #resp.data.problems > 0 then
          local p = resp.data.problems[1]
          if p.paid then
             lc_view.random_retries = (lc_view.random_retries or 0) + 1
             if lc_view.random_retries < 15 then
               pick_random()
               return
             end
          end
          lc_view.random_retries = 0
          
          lc_view.loading_msg = "Loading " .. p.title
          core.redraw = true
          
          api_call({ cmd = "problem_detail", slug = p.slug }, function(det_resp)
            if not lc_view then return end
            if det_resp.ok then
              lc_view.current = det_resp.data
              lc_view.state   = "problem"
              lc_view.scroll_y = 0
            else
              lc_view.state = "list"
              core.log("[LeetCode] " .. (det_resp.error or "Failed to load random problem"))
            end
            core.redraw = true
          end)
        else
          lc_view.state = "list"
          core.log("[LeetCode] Failed to fetch random problem")
          core.redraw = true
        end
      end)
    end
    
    lc_view.random_retries = 0
    pick_random()
  end,
  ["leetcode:close"] = function()
    local lc_is_active = (core.active_view and core.active_view:is(LeetCodeView))
    local in_problem = false
    if lc_is_active and (core.active_view.state == "problem" or core.active_view.state == "running" or core.active_view.state == "result") then
      in_problem = true
    else
      if core.active_view and core.active_view.doc and core.active_view.doc.filename then
        if core.active_view.doc.filename:find("leetcode[/\\]Leetcode") then
          in_problem = true
        end
      end
    end

    if in_problem then
      local nodes = core.root_view.root_node:get_children()
      for _, node in ipairs(nodes) do
        if node.type == "leaf" and node.views then
          for i = #node.views, 1, -1 do
            local view = node.views[i]
            if view.doc and view.doc.filename and view.doc.filename:find("leetcode[/\\]Leetcode") then
              node:close_view(core.root_view.root_node, view)
            end
          end
        end
      end
      
      if not lc_view or not core.root_view.root_node:get_node_for_view(lc_view) then
        command.perform("leetcode:toggle")
      end
      if lc_view then
        lc_view.state = "list"
        lc_view.search_focus = true
        core.set_active_view(lc_view)
      end
    end
  end,
  ["leetcode:run"] = function()
    local rem_run = 3 - (os.time() - last_run_time)
    if rem_run > 0 then
      local mm = math.floor(rem_run / 60)
      local ss = rem_run % 60
      core.log_quiet(string.format("[LeetCode] You can Run again in %02d:%02d", mm, ss))
      return
    end
    
    local doc = core.active_view and core.active_view.doc
    if has_lint_errors(doc) then
      core.error("[LeetCode] Syntax error(s) found locally! Please fix them before running.")
      return
    end
    
    last_run_time = os.time()
    local meta = get_active_meta()
    local code = get_active_code()
    if not meta or not code then
      core.log("[LeetCode] Open a LeetCode solution file first (from USERDIR/leetcode/)")
      return
    end
    
    local ok, complexity = pcall(require, "plugins.complexity")
    local est_tc, est_sc = "O(?)", "O(?)"
    if ok and complexity.analyze_code then
      est_tc, est_sc = complexity.analyze_code(code, meta.lang)
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
      lc_view.result.est_tc = est_tc
      lc_view.result.est_sc = est_sc
      lc_view.result_type = "run"
      lc_view.state       = "result"
      core.redraw       = true
    end)
  end,
  
  ["leetcode:submit"] = function()
    local rem_sub = 10 - (os.time() - last_submit_time)
    if rem_sub > 0 then
      local mm = math.floor(rem_sub / 60)
      local ss = rem_sub % 60
      core.log_quiet(string.format("[LeetCode] You can Submit again in %02d:%02d", mm, ss))
      return
    end
    
    local doc = core.active_view and core.active_view.doc
    if has_lint_errors(doc) then
      core.error("[LeetCode] Syntax error(s) found locally! Please fix them before submitting.")
      return
    end
    
    last_submit_time = os.time()
    local meta = get_active_meta()
    local code = get_active_code()
    if not meta or not code then
      core.log("[LeetCode] Open a LeetCode solution file first (from USERDIR/leetcode/)")
      return
    end
    
    local ok, complexity = pcall(require, "plugins.complexity")
    local est_tc, est_sc = "O(?)", "O(?)"
    if ok and complexity.analyze_code then
      est_tc, est_sc = complexity.analyze_code(code, meta.lang)
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
      lc_view.result.est_tc = est_tc
      lc_view.result.est_sc = est_sc
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
  ["ctrl+q"] = "leetcode:close",
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
  local cy = y
  if not text or text == "" then return cy end
  
  if lc_view and lc_view.state == "problem" and not lc_view.is_fetching then
     -- Clear image links for this frame
     if y == lc_view.content_y_start then lc_view.image_links = {} end
  end
  
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line == "" then
      cy = cy + lh
    else
      local cx = x
      for word in line:gmatch("%S+") do
        local img_url = word:match("^%[Image:(.-)%]$")
        if img_url then
          local label = "[View Image]"
          if cx + font:get_width(label) > x + max_w and cx > x then cx = x; cy = cy + lh end
          
          if lc_view and lc_view.state == "problem" then
            lc_view.image_links = lc_view.image_links or {}
            table.insert(lc_view.image_links, {x = cx, y = cy, w = font:get_width(label), h = lh, url = img_url})
          end
          
          cx = renderer.draw_text(font, label .. " ", cx, cy, LC_COLORS.accepted or style.accent)
        else
          if cx + font:get_width(word) > x + max_w and cx > x then cx = x; cy = cy + lh end
          cx = renderer.draw_text(font, word .. " ", cx, cy, color)
        end
      end
      cy = cy + lh
    end
  end
  return cy
end

function LeetCodeView:on_mouse_pressed(btn, mouse_x, mouse_y, clicks)
  local res = LeetCodeView.super.on_mouse_pressed(self, btn, mouse_x, mouse_y, clicks)
  if res then return res end

  local sw, sh = self.size.x, self.size.y
  local w, h = 700 * SCALE, 500 * SCALE
  local bg_x, bg_y = self.position.x + (sw - w) / 2, self.position.y + (sh - h) / 2
  local cx = bg_x + 20 * SCALE
  local cw = w - 40 * SCALE

  if self.state == "auth" and btn == "left" then
    local cy = bg_y + 20 * SCALE
    cy = cy + 30*SCALE
    local auto_btn_y = cy
    cy = cy + 40*SCALE + 30*SCALE + 20*SCALE
    local box1_y = cy
    cy = cy + 40*SCALE + 20*SCALE
    local box2_y = cy
    cy = cy + 50*SCALE
    local btn_y = cy
    
    if mouse_x >= cx and mouse_x <= cx + 320*SCALE and mouse_y >= auto_btn_y and mouse_y <= auto_btn_y + 30*SCALE then
      command.perform("leetcode:auto-detect")
      return true
    end
    if mouse_x >= cx and mouse_x <= cx + 100*SCALE and mouse_y >= btn_y and mouse_y <= btn_y + 30*SCALE then
      command.perform("leetcode:connect")
      return true
    end
  end

  if self.state == "list" and btn == "left" then
    -- 1. Check dropdown clicks
    if self.dropdown_rect and self.search_focus then
      local r = self.dropdown_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        for _, item in ipairs(self.dropdown_items) do
          if mouse_y >= item.y and mouse_y < item.y + 24*SCALE then
            self.search_input = self.search_input:gsub(item.prefix .. "[^%s]*$", item.prefix .. item.t .. " ")
            self.page_skip = 0
            command.perform("leetcode:fetch-list")
            return true
          end
        end
      end
    end
    
    -- 2. Check difficulty toggles
    if self.diff_buttons then
      for _, btn_obj in ipairs(self.diff_buttons) do
        if mouse_x >= btn_obj.x and mouse_x <= btn_obj.x + btn_obj.w and mouse_y >= btn_obj.y and mouse_y <= btn_obj.y + btn_obj.h then
          self.difficulty = btn_obj.val
          self.page_skip = 0
          command.perform("leetcode:fetch-list")
          return true
        end
      end
    end
    
    -- 2.5 Check Pick One button
    if self.random_btn_rect then
      local r = self.random_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        command.perform("leetcode:random")
        return true
      end
    end
    
    local view_x, view_y, view_w, view_h = bg_x, bg_y, w, h
    local search_cy = self.search_y_start or (view_y + 80 * SCALE)
    -- Search box click
    if mouse_y >= search_cy and mouse_y <= search_cy + 24*SCALE then
      if mouse_x >= cx + 60*SCALE and mouse_x <= cx + cw - 100*SCALE then
        self.search_focus = true
        core.redraw = true
        return true
      end
    end
    
    -- Pagination click
    if self.page_prev_rect then
      local r = self.page_prev_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        if self.page_skip >= 50 then
          self.page_skip = self.page_skip - 50
          command.perform("leetcode:fetch-list")
        end
        return true
      end
    end
    
    if self.page_next_rect then
      local r = self.page_next_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
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
    local list_y = self.list_y_start or (view_y + 155*SCALE)
    local list_bottom = bg_y + h - 50*SCALE
    if mouse_y >= list_y and mouse_y < list_bottom then
      local idx = math.floor((mouse_y - list_y + self.list_scroll_y) / (24*SCALE)) + 1
      if idx >= 1 and idx <= #self.problems then
        self.selected_idx = idx
        command.perform("leetcode:open-problem")
      end
      return true
    end
  elseif self.state == "problem" and btn == "left" then
    if self.back_btn_rect then
      local r = self.back_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.state = "list"
        self.current = nil
        core.redraw = true
        return true
      end
    end
    
    if self.copy_btn_rect then
      local r = self.copy_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        local text_to_copy = self.current.title .. "\n\n" .. (self.current.content_plain or "")
        system.set_clipboard(text_to_copy)
        core.log("[LeetCode] Problem description copied to clipboard!")
        return true
      end
    end
    
    if self.image_links then
      for _, link in ipairs(self.image_links) do
        if mouse_x >= link.x and mouse_x <= link.x + link.w and mouse_y >= link.y and mouse_y <= link.y + link.h then
          core.log("[LeetCode] Opening image viewer...")
          core.root_view:open_doc({filename = link.url})
          return true
        end
      end
    end
    
    local in_scroll_area = true
    if self.problem_scroll_y_start and self.problem_scroll_h then
      in_scroll_area = (mouse_y >= self.problem_scroll_y_start and mouse_y <= self.problem_scroll_y_start + self.problem_scroll_h)
    end
    
    if in_scroll_area and self.similar_buttons then
      for _, b in ipairs(self.similar_buttons) do
        if mouse_x >= b.x and mouse_x <= b.x + b.w and mouse_y >= b.y and mouse_y <= b.y + b.h then
          self.state = "loading"
          self.loading_msg = "Loading similar problem..."
          core.redraw = true
          api_call({cmd = "problem_detail", slug = b.slug}, function(res)
            if not lc_view then return end
            if res.ok then
              self.current = res.data
              self.state = "problem"
              self.scroll_y = 0
            else
              core.error("[LeetCode] Failed to fetch similar problem")
              self.state = "list"
            end
            core.redraw = true
          end)
          return true
        end
      end
    end
    
    if in_scroll_area and self.lang_buttons then
      for _, b in ipairs(self.lang_buttons) do
        if mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h then
          core.log("[LeetCode] Bootstrapping " .. b.lang .. " environment...")
          local ok, err = pcall(open_problem, self.current, b.lang)
          if not ok then core.error("[LeetCode] Failed to open problem: " .. tostring(err)) end
          return true
        end
      end
    end
  end

  return false
end

function LeetCodeView:on_mouse_wheel(delta)
  if self.state == "problem" then
    self.scroll_y = math.max(0, math.min(self.max_scroll or 0, self.scroll_y - delta * 40))
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
  local w = math.min(1200 * SCALE, math.max(700 * SCALE, sw - 80 * SCALE))
  local h = math.max(500 * SCALE, sh - 80 * SCALE)
  
  local x, y = self.position.x + (sw - w) / 2, self.position.y + (sh - h) / 2
  
  renderer.draw_rect(x, y, w, h, style.background)
  renderer.draw_rect(x, y, w, 2 * SCALE, style.accent)
  
  local cx, cy = x + 20 * SCALE, y + 20 * SCALE
  local cw = w - 40 * SCALE

  local rem_run = 3 - (os.time() - last_run_time)
  local rem_sub = 10 - (os.time() - last_submit_time)
  local cd_msg = nil
  if rem_sub > 0 then
    cd_msg = string.format("Submit Cooldown: %02d:%02d", math.floor(rem_sub / 60), rem_sub % 60)
    core.redraw = true
  elseif rem_run > 0 then
    cd_msg = string.format("Run Cooldown: %02d:%02d", math.floor(rem_run / 60), rem_run % 60)
    core.redraw = true
  end
  
  if cd_msg then
    local tw = style.font:get_width(cd_msg)
    renderer.draw_text(style.font, cd_msg, x + w - 10*SCALE - tw, y + 10*SCALE, style.accent)
  end

  if self.state == "auth" then
    if self.auth_status then
      local col = style.text
      if self.auth_status:match("expired") then col = LC_COLORS.wrong or style.error end
      if self.auth_status:match("Found") then col = LC_COLORS.accepted or style.accent end
      renderer.draw_text(style.font, self.auth_status, cx, cy, col)
    else
      renderer.draw_text(style.font, "> LeetCode - Connect", cx, cy, style.text)
    end
    cy = cy + 30*SCALE
    
    renderer.draw_rect(cx, cy, 320*SCALE, 30*SCALE, LC_COLORS.accepted)
    renderer.draw_text(style.font, "Auto-detect from Chrome / Firefox", cx + 15*SCALE, cy + 5*SCALE, style.background)
    cy = cy + 40*SCALE
    
    renderer.draw_text(style.font, "--- or paste manually ---", cx, cy, style.dim)
    cy = cy + 30*SCALE
    
    renderer.draw_text(style.font, "Full Cookie String:", cx, cy, style.text)
    cy = cy + 20*SCALE
    renderer.draw_rect(cx, cy, cw, 30*SCALE, style.dim)
    renderer.draw_rect(cx + 1*SCALE, cy + 1*SCALE, cw - 2*SCALE, 28*SCALE, style.background2)
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
      local prefix = (self.auth_status:match("Successfully") or self.auth_status:match("Connected")) and "✓ " or "✗ "
      local stat_c = (prefix == "✓ ") and LC_COLORS.accepted or LC_COLORS.wrong
      renderer.draw_text(style.font, prefix .. self.auth_status, cx, cy + 50*SCALE, stat_c)
    end
    
  elseif self.state == "loading" or self.state == "running" then
    local SPINNER = {"⣾","⣽","⣻","⢿","⡿","⣟","⣯","⣷"}
    local dots = " " .. SPINNER[math.floor(system.get_time() * 8) % 8 + 1]
    local msg = self.loading_msg .. dots
    local tw = style.font:get_width(msg)
    renderer.draw_text(style.font, msg, cx + cw/2 - tw/2, cy + h/2 - 20*SCALE, style.accent)
    
  elseif self.state == "list" then
    renderer.draw_text(style.font, "LeetCode Browser", cx, cy, style.text)
    
    if self.user_stats then
      local s_all, s_easy, s_med, s_hard = 0, 0, 0, 0
      for _, stat in ipairs(self.user_stats) do
        if stat.difficulty == "All" then s_all = stat.count end
        if stat.difficulty == "Easy" then s_easy = stat.count end
        if stat.difficulty == "Medium" then s_med = stat.count end
        if stat.difficulty == "Hard" then s_hard = stat.count end
      end
      local stat_str = string.format("%d Solved (E:%d M:%d H:%d)", s_all, s_easy, s_med, s_hard)
      local tw = style.font:get_width(stat_str)
      renderer.draw_text(style.font, stat_str, cx + cw - tw, cy, style.dim)
    end
    
    local d_opts = { {"ALL", "ALL"}, {"Easy", "EASY"}, {"Med", "MEDIUM"}, {"Hard", "HARD"} }
    self.diff_buttons = {}
    local d_x = cx + 160*SCALE
    for _, opt in ipairs(d_opts) do
      local label = opt[1]
      local is_active = self.difficulty == opt[2]
      local dc = LC_COLORS[opt[2]:lower()] or style.text
      local bg_color = is_active and {dc[1], dc[2], dc[3], dc[4] * 0.15} or style.background2
      local text_color = is_active and dc or style.dim
      
      local lw = style.font:get_width(label)
      local bh = style.font:get_height() + 4*SCALE
      local btn_rect = { x = d_x, y = cy - 2*SCALE, w = lw + 12*SCALE, h = bh, val = opt[2] }
      
      renderer.draw_rect(btn_rect.x, btn_rect.y, btn_rect.w, btn_rect.h, bg_color)
      renderer.draw_text(style.font, label, d_x + 6*SCALE, cy, text_color)
      
      table.insert(self.diff_buttons, btn_rect)
      d_x = d_x + lw + 22*SCALE
    end
    cy = cy + 30*SCALE
    
    renderer.draw_text(style.font, "Alt+R: Run Code  |  Alt+S: Submit  |  #tag for topics  |  @company for companies", cx, cy, style.accent)
    cy = cy + 30*SCALE
    
    renderer.draw_text(style.font, "Search:", cx, cy, style.text)
    local search_x = cx + 60*SCALE
    local search_y = cy
    self.search_y_start = search_y
    local search_w = cw - 200*SCALE
    local search_h = 24*SCALE
    
    local border_color = self.search_focus and style.accent or style.dim
    -- Minimalist Material-style bottom line
    renderer.draw_rect(search_x, search_y + search_h, search_w, 2*SCALE, border_color)
    
    renderer.draw_text(style.font, self.search_input, search_x + 5*SCALE, search_y + 2*SCALE, style.text)
    
    -- Draw Pick One button
    local r_x = search_x + search_w + 30*SCALE
    local r_y = search_y
    local r_w = 90*SCALE
    local r_h = 24*SCALE
    self.random_btn_rect = {x = r_x, y = r_y, w = r_w, h = r_h}
    
    renderer.draw_rect(r_x, r_y, r_w, r_h, style.background2)
    renderer.draw_rect(r_x, r_y, r_w, 1*SCALE, LC_COLORS.accepted)
    renderer.draw_rect(r_x, r_y + r_h - 1*SCALE, r_w, 1*SCALE, LC_COLORS.accepted)
    renderer.draw_text(style.font, "Pick One", r_x + 14*SCALE, r_y + 4*SCALE, LC_COLORS.accepted)
    
    cy = cy + 30*SCALE
    
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
    self.list_y_start = cy
    
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
            renderer.draw_rect(cx - 5*SCALE, item_y - 2*SCALE, 3*SCALE, 24*SCALE, style.accent)
          end
          renderer.draw_text(style.font, "#" .. p.id, cx, item_y, style.dim)
          
          local diff_x = cx + cw - 250 * SCALE
          local stat_x = cx + cw - 150 * SCALE
          local prem_x = cx + cw - 80 * SCALE
          
          local max_title_chars = math.max(15, math.floor((diff_x - (cx + 50*SCALE)) / style.font:get_width("A")) * 1.5)
          local title = p.title
          if #title > max_title_chars then title = title:sub(1, max_title_chars) .. "..." end
          
          local title_color = style.text
          if p.status == "ac" then title_color = LC_COLORS.accepted end
          if p.status == "notac" then title_color = LC_COLORS.tle end
          renderer.draw_text(style.font, title, cx + 50*SCALE, item_y, title_color)
          local dc = LC_COLORS[p.difficulty:lower()]
          local bg_dc = {dc[1], dc[2], dc[3], dc[4] * 0.15}
          local dw = style.font:get_width(p.difficulty)
          renderer.draw_rect(diff_x - 6*SCALE, item_y - 2*SCALE, dw + 12*SCALE, style.font:get_height() + 4*SCALE, bg_dc)
          renderer.draw_text(style.font, p.difficulty, diff_x, item_y, dc)
          local stat_str = p.ac_rate .. "%"
          if p.status == "ac" then stat_str = stat_str .. " [AC]" end
          local stat_color = p.status == "ac" and LC_COLORS.accepted or style.dim
          renderer.draw_text(style.font, stat_str, stat_x, item_y, stat_color)
          if p.paid then renderer.draw_text(style.font, "(Premium)", prem_x, item_y, LC_COLORS.tle) end
        end
        item_y = item_y + 24*SCALE
      end
      core.pop_clip_rect()
    end
    cy = y + h - 50*SCALE
    
    local page = math.floor(self.page_skip / 50) + 1
    local total_pages = math.max(1, math.ceil(self.total_problems / 50))
    renderer.draw_text(style.font, "Page " .. page .. " / " .. total_pages, cx, cy + 10*SCALE, style.dim)
    local prev_lbl = "  < Prev Page  "
    local next_lbl = "  Next Page >  "
    local p_w, n_w = style.font:get_width(prev_lbl), style.font:get_width(next_lbl)
    local p_col = self.page_skip > 0 and style.accent or style.dim
    local n_col = (self.page_skip + 50) < self.total_problems and style.accent or style.dim
    
    local bh = style.font:get_height() + 4*SCALE
    self.page_prev_rect = { x = cx + cw/2 - 100*SCALE, y = cy + 8*SCALE, w = p_w, h = bh }
    self.page_next_rect = { x = cx + cw/2 + 20*SCALE, y = cy + 8*SCALE, w = n_w, h = bh }
    
    renderer.draw_rect(self.page_prev_rect.x, self.page_prev_rect.y, self.page_prev_rect.w, self.page_prev_rect.h, style.background2)
    renderer.draw_text(style.font, prev_lbl, self.page_prev_rect.x, cy + 10*SCALE, p_col)
    
    renderer.draw_rect(self.page_next_rect.x, self.page_next_rect.y, self.page_next_rect.w, self.page_next_rect.h, style.background2)
    renderer.draw_text(style.font, next_lbl, self.page_next_rect.x, cy + 10*SCALE, n_col)
    
    if self.search_focus then
      local p_topic = self.search_input:match("#([^%s]*)$")
      local p_comp = self.search_input:match("@([^%s]*)$")
      local partial = p_topic or p_comp
      
      if partial then
        local filtered = {}
        local src_list = p_topic and TOPIC_TAGS or COMPANIES
        local prefix = p_topic and "#" or "@"
        
        for _, t in ipairs(src_list) do
          if t:find(partial, 1, true) then table.insert(filtered, t) end
        end
        if #filtered > 0 then
          local drop_x, drop_y = search_x, search_y + search_h
          local drop_w = 200 * SCALE
          local drop_h = math.min(10, #filtered) * 24 * SCALE
          
          self.dropdown_rect = {x = drop_x, y = drop_y, w = drop_w, h = drop_h}
          self.dropdown_items = {}
          
          renderer.draw_rect(drop_x, drop_y, drop_w, drop_h, style.background3)
          renderer.draw_rect(drop_x, drop_y, drop_w, 1*SCALE, style.text)
          for i, t in ipairs(filtered) do
            if i > 10 then break end
            local item_y = drop_y + (i-1)*24*SCALE
            table.insert(self.dropdown_items, { t = t, y = item_y, prefix = prefix })
            renderer.draw_text(style.font, prefix .. t, drop_x + 10*SCALE, item_y + 4*SCALE, style.text)
          end
        else
          self.dropdown_rect = nil
        end
      else
        self.dropdown_rect = nil
      end
    else
      self.dropdown_rect = nil
    end

  elseif self.state == "problem" and self.current then
    local p = self.current
    local dc = LC_COLORS[p.difficulty:lower()]
    local back_w = style.font:get_width("<- Back")
    self.back_btn_rect = {x = cx, y = cy, w = back_w, h = style.font:get_height()}
    renderer.draw_text(style.font, "<- Back", cx, cy, style.dim)
    renderer.draw_text(style.big_font, p.title, cx + 80*SCALE, cy - 4*SCALE, style.text)
    
    local copy_text = "[Copy Description]"
    local copy_w = style.font:get_width(copy_text)
    self.copy_btn_rect = {x = cx + cw - 120*SCALE - copy_w, y = cy, w = copy_w, h = style.font:get_height()}
    renderer.draw_text(style.font, copy_text, self.copy_btn_rect.x, self.copy_btn_rect.y, style.accent)
    
    renderer.draw_text(style.font, "[" .. p.difficulty .. "]", cx + cw - 100*SCALE, cy, dc)
    cy = cy + 25*SCALE
    
    if p.topics and #p.topics > 0 then
      local topics_str = "Topics: " .. table.concat(p.topics, ", ")
      cy = draw_text_wrap(style.font, style.dim, topics_str, cx, cy, cw)
      cy = cy + 10*SCALE
    end
    
    if p.companies and #p.companies > 0 then
      local comp_str = "Companies: " .. table.concat(p.companies, ", ")
      cy = draw_text_wrap(style.font, style.accent, comp_str, cx, cy, cw)
      cy = cy + 10*SCALE
    elseif p.companies and #p.companies == 0 then
      cy = draw_text_wrap(style.font, style.dim, "Companies: [Premium Required / Not Available]", cx, cy, cw)
      cy = cy + 10*SCALE
    end
    
    renderer.draw_text(style.font, "Click a language below to scaffold your local solution file.", cx, cy, style.accent)
    cy = cy + 25*SCALE
    renderer.draw_rect(cx, cy, cw, 1*SCALE, style.dim)
    cy = cy + 15*SCALE
    
    local scroll_area_h = (y + h - 20*SCALE) - cy
    self.problem_scroll_y_start = cy
    self.problem_scroll_h = scroll_area_h
    core.push_clip_rect(cx, cy, cw, scroll_area_h)
    
    local inner_cy = cy - self.scroll_y
    self.content_y_start = inner_cy
    
    inner_cy = draw_text_wrap(style.font, style.text, p.content_plain, cx, inner_cy, cw)
    
    inner_cy = inner_cy + 25*SCALE
    renderer.draw_rect(cx, inner_cy, cw, 1*SCALE, style.dim)
    inner_cy = inner_cy + 15*SCALE
    renderer.draw_text(style.font, "Open in:", cx, inner_cy, style.text)
    
    local lang_cy = inner_cy
    local bx = cx
    
    local sorted_langs = {}
    for lang, _ in pairs(p.starters or {}) do table.insert(sorted_langs, lang) end
    table.sort(sorted_langs)
    
    self.lang_buttons = {}
    for _, lang in ipairs(sorted_langs) do
      local lbl = lang
      local lw = style.font:get_width(lbl)
      
      if bx + lw + 20*SCALE > cx + cw then
        bx = cx
        lang_cy = lang_cy + 28*SCALE
      end
      
      renderer.draw_rect(bx, lang_cy, lw + 12*SCALE, 22*SCALE, style.dim)
      renderer.draw_rect(bx+1, lang_cy+1, lw + 10*SCALE, 20*SCALE, style.background2)
      renderer.draw_text(style.font, lbl, bx + 6*SCALE, lang_cy + 3*SCALE, style.text)
      table.insert(self.lang_buttons, { x = bx, y = lang_cy, w = lw + 12*SCALE, h = 22*SCALE, lang = lang })
      
      bx = bx + lw + 20*SCALE
    end
    lang_cy = lang_cy + 24*SCALE
    
    self.similar_buttons = {}
    if p.similar_questions and #p.similar_questions > 0 then
      lang_cy = lang_cy + 20*SCALE
      renderer.draw_text(style.font, "Similar Problems:", cx, lang_cy, style.dim)
      lang_cy = lang_cy + 24*SCALE
      for _, sq in ipairs(p.similar_questions) do
        local btn_text = "> " .. sq.title .. " [" .. sq.difficulty .. "]"
        local bw = style.font:get_width(btn_text)
        local diff_col = LC_COLORS[sq.difficulty:lower()] or style.text
        
        table.insert(self.similar_buttons, { x = cx, y = lang_cy, w = bw, h = 20*SCALE, slug = sq.titleSlug })
        
        renderer.draw_text(style.font, btn_text, cx, lang_cy, diff_col)
        lang_cy = lang_cy + 24*SCALE
      end
    end
    
    local content_total_h = lang_cy - (cy - self.scroll_y)
    self.max_scroll = math.max(0, content_total_h - scroll_area_h + 50*SCALE)
    
    core.pop_clip_rect()
    
  elseif self.state == "result" and self.result then
    local res = self.result
    local status_text = res.status or res.err or "Unknown Error"
    local title_c = res.ok and LC_COLORS.accepted or LC_COLORS.wrong
    if status_text:match("Limit Exceeded") then title_c = LC_COLORS.tle end
    if status_text:match("Error") then title_c = LC_COLORS.hard end
    
    -- Result area accent bar
    renderer.draw_rect(x + 10*SCALE, y + 20*SCALE, 4*SCALE, h - 40*SCALE, title_c)
    
    renderer.draw_text(style.big_font, status_text, cx, cy, title_c)
    cy = cy + 40*SCALE
    
    renderer.draw_rect(cx, cy, cw, 1*SCALE, style.dim)
    cy = cy + 20*SCALE
    
    if res.compile_error and res.compile_error ~= "" then
      cy = draw_text_wrap(style.font, LC_COLORS.hard, "Compile Error:\n\n" .. res.compile_error, cx, cy, cw)
    elseif res.runtime_error and res.runtime_error ~= "" then
      cy = draw_text_wrap(style.font, LC_COLORS.hard, "Runtime Error:\n\n" .. res.runtime_error, cx, cy, cw)
    else
      -- Metrics Cards
      local card_w = math.max(200*SCALE, (cw - 20*SCALE) / 2)
      local card_h = 70*SCALE
      
      local rt_color = (res.runtime_percentile and res.runtime_percentile > 75) and LC_COLORS.accepted or style.text
      renderer.draw_rect(cx, cy, card_w, card_h, style.background2)
      renderer.draw_text(style.font, "Runtime", cx + 10*SCALE, cy + 10*SCALE, style.dim)
      renderer.draw_text(style.font, res.runtime or "N/A", cx + 10*SCALE, cy + 30*SCALE, rt_color)
      if res.runtime_percentile and res.runtime_percentile > 0 then
        renderer.draw_text(style.font, "Beats " .. res.runtime_percentile .. "%", cx + 10*SCALE, cy + 50*SCALE, style.accent)
        local bar_y = cy + 70*SCALE - 6*SCALE
        renderer.draw_rect(cx + 10*SCALE, bar_y, card_w - 20*SCALE, 3*SCALE, style.background3)
        renderer.draw_rect(cx + 10*SCALE, bar_y, (card_w - 20*SCALE) * res.runtime_percentile / 100, 3*SCALE, LC_COLORS.accepted)
      end
      
      local mem_color = (res.memory_percentile and res.memory_percentile > 75) and LC_COLORS.accepted or style.text
      renderer.draw_rect(cx + card_w + 10*SCALE, cy, card_w, card_h, style.background2)
      renderer.draw_text(style.font, "Memory", cx + card_w + 20*SCALE, cy + 10*SCALE, style.dim)
      renderer.draw_text(style.font, res.memory or "N/A", cx + card_w + 20*SCALE, cy + 30*SCALE, mem_color)
      if res.memory_percentile and res.memory_percentile > 0 then
        renderer.draw_text(style.font, "Beats " .. res.memory_percentile .. "%", cx + card_w + 20*SCALE, cy + 50*SCALE, style.accent)
        local bar_y = cy + 70*SCALE - 6*SCALE
        renderer.draw_rect(cx + card_w + 20*SCALE, bar_y, card_w - 20*SCALE, 3*SCALE, style.background3)
        renderer.draw_rect(cx + card_w + 20*SCALE, bar_y, (card_w - 20*SCALE) * res.memory_percentile / 100, 3*SCALE, LC_COLORS.accepted)
      end
      
      -- Complexity Cards (Heuristic)
      local c_card_y = cy + card_h + 10*SCALE
      renderer.draw_rect(cx, c_card_y, card_w, card_h, style.background2)
      renderer.draw_text(style.font, "Est. Time Complexity", cx + 10*SCALE, c_card_y + 10*SCALE, style.dim)
      renderer.draw_text(style.font, res.est_tc or "O(?)", cx + 10*SCALE, c_card_y + 35*SCALE, style.accent)
      
      renderer.draw_rect(cx + card_w + 10*SCALE, c_card_y, card_w, card_h, style.background2)
      renderer.draw_text(style.font, "Est. Space Complexity", cx + card_w + 20*SCALE, c_card_y + 10*SCALE, style.dim)
      renderer.draw_text(style.font, res.est_sc or "O(?)", cx + card_w + 20*SCALE, c_card_y + 35*SCALE, style.accent)
      
      cy = c_card_y + card_h + 20*SCALE
      
      local ok, complexity = pcall(require, "plugins.complexity")
      if ok and complexity.draw_graph then
        complexity.draw_graph(cx + 20*SCALE, cy + 30*SCALE, 300*SCALE, 150*SCALE, res.est_tc or "O(?)")
        cy = cy + 150*SCALE + 60*SCALE
      end
      
      if res.total_testcases then
        renderer.draw_text(style.font, "Testcases Passed: " .. (res.total_correct or 0) .. " / " .. (res.total_testcases or 0), cx, cy, style.text)
        cy = cy + 30*SCALE
      end
      
      if not res.ok and self.result_type == "run" then
        renderer.draw_text(style.font, "Your Output", cx, cy, style.dim)
        cy = cy + 20*SCALE
        renderer.draw_rect(cx, cy, cw, 50*SCALE, style.background2)
        local co = type(res.code_output) == "table" and table.concat(res.code_output, "\n") or (res.code_output or "")
        cy = draw_text_wrap(style.code_font, LC_COLORS.hard, co, cx + 10*SCALE, cy + 10*SCALE, cw - 20*SCALE) + 30*SCALE
        
        renderer.draw_text(style.font, "Expected", cx, cy, style.dim)
        cy = cy + 20*SCALE
        renderer.draw_rect(cx, cy, cw, 50*SCALE, style.background2)
        local eo = type(res.expected_output) == "table" and table.concat(res.expected_output, "\n") or (res.expected_output or "")
        cy = draw_text_wrap(style.code_font, LC_COLORS.accepted, eo, cx + 10*SCALE, cy + 10*SCALE, cw - 20*SCALE) + 20*SCALE
      end
      
      if res.std_output and res.std_output ~= "" then
        cy = cy + 10*SCALE
        renderer.draw_text(style.font, "Stdout", cx, cy, style.dim)
        cy = cy + 20*SCALE
        renderer.draw_rect(cx, cy, cw, 50*SCALE, style.background2)
        cy = draw_text_wrap(style.font, style.text, res.std_output, cx + 10*SCALE, cy + 10*SCALE, cw - 20*SCALE) + 20*SCALE
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
            style.dim, "  [alt+r] Run  [alt+s] Submit"
          }
        end
        return { style.text, " LC ", style.font, " LeetCode" }
      end
    })
  end
end)

-- Inject a floating "Copy Code" button into the actual Code Editor for LeetCode files
local DocView = require "core.docview"
local old_docview_draw = DocView.draw
function DocView:draw(...)
  old_docview_draw(self, ...)
  if self.doc and self.doc.filename and self.doc.filename:find("leetcode[/\\]Leetcode") then
    local cx = self.position.x + self.size.x - 110 * SCALE
    local cy = self.position.y + 10 * SCALE
    self.editor_copy_btn = {x = cx, y = cy, w = 90*SCALE, h = 28*SCALE}
    
    renderer.draw_rect(cx, cy, self.editor_copy_btn.w, self.editor_copy_btn.h, style.background2)
    renderer.draw_rect(cx, cy, self.editor_copy_btn.w, 1*SCALE, LC_COLORS.accepted)
    renderer.draw_text(style.font, "Copy Code", cx + 12*SCALE, cy + 6*SCALE, style.text)
  else
    self.editor_copy_btn = nil
  end
end

local old_docview_on_mouse_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and self.editor_copy_btn then
    local r = self.editor_copy_btn
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
      system.set_clipboard(self.doc:get_text(1, 1, math.huge, math.huge))
      core.log("[LeetCode] Your code has been copied to the clipboard!")
      return true
    end
  end
  return old_docview_on_mouse_pressed(self, button, x, y, clicks)
end
