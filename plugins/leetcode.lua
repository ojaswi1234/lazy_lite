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
    local success = pcall(function() api_proc:write(line) end)
    if not success then
      pending[id] = nil
      if callback then callback(nil, "Failed to write to API") end
    end
  else
    pending[id] = nil
    if callback then callback(nil, "API not running") end
  end
end


-- ── Drawing utilities (defined early so ResultView can use them) ─────────────────
local function draw_text_wrap(font, color, text, x, y, max_w)
  local lh = font:get_height()
  local cy = y
  if not text or text == "" then return cy end

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

-- ── Standalone Result View (opens as a tab in the code editor section) ──────
local LeetCodeResultView = View:extend()

function LeetCodeResultView:new(result, result_type, title)
  LeetCodeResultView.super.new(self)
  self.scrollable  = true
  self.result      = result
  self.result_type = result_type or "run"
  self.prob_title  = title or "Result"
  self.scroll_y    = 0
  self.max_scroll  = 0
end

function LeetCodeResultView:get_name()
  local res = self.result
  if not res then return "LC: Result" end
  local status = res.status or res.err or "Error"
  local icon = res.ok and "✓" or "✗"
  return "LC: " .. icon .. " " .. status:sub(1, 20)
end

function LeetCodeResultView:on_key_pressed(key)
  if key == "down" then
    self.scroll_y = math.min(self.max_scroll, self.scroll_y + 40)
    core.redraw = true; return true
  elseif key == "up" then
    self.scroll_y = math.max(0, self.scroll_y - 40)
    core.redraw = true; return true
  elseif key == "escape" or key == "ctrl+w" then
    local node = core.root_view.root_node:get_node_for_view(self)
    if node then node:close_view(core.root_view.root_node, self) end
    return true
  end
  return false
end

function LeetCodeResultView:on_mouse_wheel(delta)
  self.scroll_y = math.max(0, math.min(self.max_scroll, self.scroll_y - delta * 40))
  core.redraw = true
  return true
end

function LeetCodeResultView:draw()
  self:draw_background(style.background)

  local res = self.result
  if not res then return end

  local sw, sh = self.size.x, self.size.y
  local pad = math.min(20 * SCALE, sw * 0.04)
  local x, y = self.position.x, self.position.y
  local w, h = sw, sh
  local cx, cy_base = x + pad, y + pad
  local cw = w - 2 * pad

  local status_text = res.status or res.err or "Unknown Error"
  local title_c = (res.ok) and LC_COLORS.accepted or LC_COLORS.wrong
  if not title_c then title_c = style.text end
  if status_text:match("Limit Exceeded") then title_c = LC_COLORS.tle end
  if status_text:match("Error") then title_c = LC_COLORS.hard end

  -- Left accent bar
  renderer.draw_rect(x, y, 3 * SCALE, h, title_c)
  -- Top accent bar
  renderer.draw_rect(x, y, w, 2 * SCALE, title_c)

  core.push_clip_rect(x, y, w, h)

  local cy = cy_base - self.scroll_y
  local content_start = cy

  -- Problem title subtitle
  if self.prob_title and self.prob_title ~= "" then
    renderer.draw_text(style.font, self.prob_title, cx + 8*SCALE, cy + 2*SCALE, style.dim)
    cy = cy + style.font:get_height() + 6*SCALE
  end

  -- Big status header
  local big_font = style.big_font or style.font
  renderer.draw_text(big_font, status_text, cx + 8*SCALE, cy, title_c)
  cy = cy + big_font:get_height() + 10*SCALE

  renderer.draw_rect(cx, cy, cw, 1*SCALE, {title_c[1], title_c[2], title_c[3], 60})
  cy = cy + 12*SCALE

  if res.compile_error and res.compile_error ~= "" then
    cy = draw_text_wrap(style.font, LC_COLORS.hard or style.error,
      "Compile Error:\n\n" .. res.compile_error, cx + 8*SCALE, cy, cw - 16*SCALE)
  elseif res.runtime_error and res.runtime_error ~= "" then
    cy = draw_text_wrap(style.font, LC_COLORS.hard or style.error,
      "Runtime Error:\n\n" .. res.runtime_error, cx + 8*SCALE, cy, cw - 16*SCALE)
  else
    -- ── Metric cards (runtime / memory / complexity) ──────────────────────
    local card_gutter = 10 * SCALE
    local card_w = math.max(140 * SCALE, (cw - card_gutter) / 2)
    local card_h = 72 * SCALE
    local card_pad = 10 * SCALE

    local function draw_metric_card(lx, label, value, beats, beats_color)
      renderer.draw_rect(lx, cy, card_w, card_h, style.background2)
      renderer.draw_rect(lx, cy, card_w, 2*SCALE, beats_color or title_c)
      renderer.draw_text(style.font, label, lx + card_pad, cy + card_pad, style.dim)
      renderer.draw_text(style.font, value or "N/A", lx + card_pad, cy + card_pad + style.font:get_height() + 4*SCALE, style.text)
      if beats and beats > 0 then
        local bl = "Beats " .. beats .. "%"
        renderer.draw_text(style.font, bl, lx + card_pad, cy + card_pad + style.font:get_height() * 2 + 8*SCALE, beats_color or LC_COLORS.accepted)
        local bar_y = cy + card_h - 8*SCALE
        renderer.draw_rect(lx + card_pad, bar_y, card_w - 2*card_pad, 4*SCALE, style.background3)
        renderer.draw_rect(lx + card_pad, bar_y, (card_w - 2*card_pad) * beats / 100, 4*SCALE, beats_color or LC_COLORS.accepted)
      end
    end

    local rt_col = (res.runtime_percentile and res.runtime_percentile > 75) and LC_COLORS.accepted or style.accent
    draw_metric_card(cx, "Runtime", res.runtime, res.runtime_percentile, rt_col)
    local mem_col = (res.memory_percentile and res.memory_percentile > 75) and LC_COLORS.accepted or style.accent
    draw_metric_card(cx + card_w + card_gutter, "Memory", res.memory, res.memory_percentile, mem_col)
    cy = cy + card_h + card_gutter

    -- Complexity cards
    renderer.draw_rect(cx, cy, card_w, card_h, style.background2)
    renderer.draw_text(style.font, "Est. Time Complexity", cx + card_pad, cy + card_pad, style.dim)
    renderer.draw_text(style.font, res.est_tc or "O(?)", cx + card_pad, cy + card_pad + style.font:get_height() + 6*SCALE, style.accent)
    renderer.draw_rect(cx + card_w + card_gutter, cy, card_w, card_h, style.background2)
    renderer.draw_text(style.font, "Est. Space Complexity", cx + card_w + card_gutter + card_pad, cy + card_pad, style.dim)
    renderer.draw_text(style.font, res.est_sc or "O(?)", cx + card_w + card_gutter + card_pad, cy + card_pad + style.font:get_height() + 6*SCALE, style.accent)
    cy = cy + card_h + card_gutter

    local ok2, complexity = pcall(require, "plugins.complexity")
    if ok2 and complexity.draw_graph then
      complexity.draw_graph(cx + 10*SCALE, cy + 20*SCALE, math.min(300*SCALE, cw - 20*SCALE), 130*SCALE, res.est_tc or "O(?)")
      cy = cy + 130*SCALE + 40*SCALE
    end

    -- Testcases
    if res.total_testcases then
      local tc_str = "Testcases Passed: " .. (res.total_correct or 0) .. " / " .. res.total_testcases
      local tc_col = (res.total_correct == res.total_testcases) and LC_COLORS.accepted or LC_COLORS.tle
      renderer.draw_rect(cx, cy, cw, style.font:get_height() + 10*SCALE, {tc_col[1], tc_col[2], tc_col[3], 20})
      renderer.draw_text(style.font, tc_str, cx + 8*SCALE, cy + 5*SCALE, tc_col)
      cy = cy + style.font:get_height() + 18*SCALE
    end

    -- Wrong answer / run diff
    if not res.ok and self.result_type == "run" then
      local function draw_output_box(label, text, col)
        renderer.draw_text(style.font, label, cx, cy, style.dim)
        cy = cy + style.font:get_height() + 4*SCALE
        local box_h = style.font:get_height() + 12*SCALE
        renderer.draw_rect(cx, cy, cw, box_h, style.background2)
        renderer.draw_rect(cx, cy, 3*SCALE, box_h, col)
        cy = draw_text_wrap(style.code_font, col, text, cx + 10*SCALE, cy + 6*SCALE, cw - 14*SCALE) + 10*SCALE
      end
      local co = type(res.code_output) == "table" and table.concat(res.code_output, "\n") or (res.code_output or "")
      local eo = type(res.expected_output) == "table" and table.concat(res.expected_output, "\n") or (res.expected_output or "")
      draw_output_box("Your Output", co, LC_COLORS.hard or style.error)
      draw_output_box("Expected", eo, LC_COLORS.accepted or style.accent)
    end

    if res.std_output and res.std_output ~= "" then
      renderer.draw_text(style.font, "Stdout", cx, cy, style.dim)
      cy = cy + style.font:get_height() + 4*SCALE
      local sbox_h = style.font:get_height() + 12*SCALE
      renderer.draw_rect(cx, cy, cw, sbox_h, style.background2)
      cy = draw_text_wrap(style.font, style.text, res.std_output, cx + 10*SCALE, cy + 6*SCALE, cw - 14*SCALE) + 10*SCALE
    end
  end

  local content_h = cy - content_start + self.scroll_y
  self.max_scroll = math.max(0, content_h - h + pad)
  core.pop_clip_rect()
end

-- ── Helper: open result as new tab in the code editor node ───────────────────
local function open_result_tab(result, result_type, prob_title)
  local rv = LeetCodeResultView(result, result_type, prob_title)
  -- Find the node that holds the active LeetCode code file
  -- (prefer the node of the currently active view)
  local target_node = nil
  if core.active_view then
    target_node = core.root_view.root_node:get_node_for_view(core.active_view)
  end
  if not target_node then
    target_node = core.root_view:get_active_node_default()
  end
  target_node:add_view(rv)
  core.set_active_view(rv)
  core.redraw = true
end


local LeetCodeView = View:extend()

function LeetCodeView:new()
  LeetCodeView.super.new(self)
  self.scrollable = true
  self.target_size   = 800 * SCALE
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
  
  self.target_size = self.target_size or (800 * SCALE)
  self:move_towards(self.size, "x", self.target_size)
  
  if self._search_timer and system.get_time() >= self._search_timer then
    self._search_timer = nil
    self.page_skip     = 0
    command.perform("leetcode:fetch-list")
  end
end

function LeetCodeView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = math.max(400 * SCALE, value)
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

  -- Still write the .md for reference/backup but don't open it in editor
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

  -- Open code file in a right split, keeping the LeetCode panel on the left as the problem viewer
  local doc_code = core.open_doc(fpath)
  local views = core.get_views_referencing_doc(doc_code)
  local view_code = views[1]

  if not view_code then
    local DocView = require "core.docview"
    view_code = DocView(doc_code)
    -- Find a non-leetcode node to split from
    local target_node = core.root_view:get_active_node_default()
    local split_node = target_node:split("right")
    split_node:add_view(view_code)
  end

  core.set_active_view(view_code)

  -- Keep the LeetCode panel open and in 'problem' state so it serves as the rich viewer
  -- (do NOT call leetcode:toggle which would close it)
  if lc_view then
    lc_view.state = "problem"
    lc_view.scroll_y = 0
  end
  core.redraw = true
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
    local sidebar = _G.get_sidebar_node and _G.get_sidebar_node()
    if lc_view and core.root_view.root_node:get_node_for_view(lc_view) then
      local node = core.root_view.root_node:get_node_for_view(lc_view)
      if sidebar and node == sidebar then
        node:set_active_view(lc_view)
      else
        node:close_view(core.root_view.root_node, lc_view)
        lc_view = nil
      end
    else
      lc_view = LeetCodeView()
      local node = sidebar or core.root_view:get_active_node_default()
      node:add_view(lc_view)
      if sidebar then node:set_active_view(lc_view) end
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
      local result      = resp.data or {}
      result.ok   = resp.ok
      result.err  = resp.error
      result.est_tc = est_tc
      result.est_sc = est_sc
      -- Restore the problem panel on the left
      if lc_view then
        lc_view.state = lc_view.current and "problem" or "list"
      end
      -- Open result as a new tab in the code editor section
      local title = (meta and meta.title) or ""
      open_result_tab(result, "run", title)
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
      local result      = resp.data or {}
      result.ok   = resp.ok
      result.err  = resp.error
      result.est_tc = est_tc
      result.est_sc = est_sc
      -- Restore the problem panel on the left
      if lc_view then
        lc_view.state = lc_view.current and "problem" or "list"
      end
      -- Open result as a new tab in the code editor section
      local title = (meta and meta.title) or ""
      open_result_tab(result, "submit", title)
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

-- ── Rich markdown-aware text renderer ──────────────────────────────────────
local SECTION_HEADERS = {
  ["Example"]    = true, ["Input"]      = true, ["Output"]     = true,
  ["Explanation"]= true, ["Constraints"]= true, ["Note"]       = true,
  ["Follow-up"]  = true, ["Follow up"]  = true, ["Definition"] = true,
}

local function draw_inline_rich(font, text, x, y, max_x, default_color)
  -- Renders a single line with inline code spans highlighted
  local cx = x
  local i = 1
  local code_bg = {30, 30, 40, 200}
  local code_fg = LC_COLORS.easy
  while i <= #text do
    local tick_s = text:find("`", i, true)
    if tick_s then
      -- draw plain text before the backtick
      local plain = text:sub(i, tick_s - 1)
      if #plain > 0 then
        cx = renderer.draw_text(font, plain, cx, y, default_color)
      end
      local tick_e = text:find("`", tick_s + 1, true)
      if tick_e then
        local code = text:sub(tick_s + 1, tick_e - 1)
        local cw = font:get_width(code) + 6 * SCALE
        renderer.draw_rect(cx, y, cw, font:get_height(), code_bg)
        cx = renderer.draw_text(font, code, cx + 3 * SCALE, y, code_fg)
        cx = cx + 3 * SCALE
        i = tick_e + 1
      else
        cx = renderer.draw_text(font, "`", cx, y, default_color)
        i = tick_s + 1
      end
    else
      local remain = text:sub(i)
      cx = renderer.draw_text(font, remain, cx, y, default_color)
      break
    end
  end
  return cx
end

local function draw_rich_content(font, text, x, y, max_w, scroll_offset)
  -- Full rich renderer: section headers, inline code, bullets, image links
  local lh    = math.floor(font:get_height() * 1.3)
  local cy    = y
  local cx    = x
  if not text or text == "" then return cy end

  if lc_view then lc_view.image_links = lc_view.image_links or {} end

  local sec_accent   = LC_COLORS.easy
  local bullet_color = {common.color("#888888")}
  local dim          = style.dim
  local main_fg      = style.text

  for raw_line in (text .. "\n"):gmatch("(.-)\n") do
    -- strip trailing whitespace
    local line = raw_line:match("^(.-)%s*$")

    if line == "" then
      cy = cy + lh * 0.5
    elseif line:match("^Example%s*%d") or line:match("^Constraints:?") or
           line:match("^Follow%s*%-?%s*up:?") or line:match("^Note:?") then
      -- ── Section header ────────────────────────────────
      local is_example  = line:match("^Example")
      local is_constrs  = line:match("^Constraint")
      local hl_color    = is_example  and {common.color("#A9DC76")} or
                          is_constrs  and {common.color("#FFD866")} or
                          {common.color("#AB9DF2")}
      local clean       = line:gsub(":%s*$", "")
      local tw          = font:get_width(clean)
      local pad         = 8 * SCALE
      local pill_h      = math.floor(font:get_height() + 6 * SCALE)
      cy = cy + lh * 0.4
      -- pill background
      renderer.draw_rect(cx - pad, cy, tw + pad * 2, pill_h,
                         {hl_color[1], hl_color[2], hl_color[3], 30})
      -- left accent bar
      renderer.draw_rect(cx - pad, cy, 3 * SCALE, pill_h, hl_color)
      renderer.draw_text(font, clean, cx, cy + 3 * SCALE, hl_color)
      cy = cy + pill_h + lh * 0.3

    elseif line:match("^Input:") or line:match("^Output:") or line:match("^Explanation:") then
      -- ── Example sub-labels ─────────────────────────────
      local label, rest = line:match("^([^:]+:)%s*(.*)$")
      if label then
        local label_w = font:get_width(label)
        renderer.draw_text(font, label, cx + 12*SCALE, cy, dim)
        if rest and rest ~= "" then
          draw_inline_rich(font, rest, cx + 12*SCALE + label_w + 4*SCALE, cy,
                           cx + max_w, main_fg)
        end
        cy = cy + lh
      end

    elseif line:match("^%s*%-") or line:match("^%s*%*") then
      -- ── Bullet point ──────────────────────────────────
      local indent = #(line:match("^(%s*)"))
      local content = line:match("^%s*[%-%*]%s*(.*)") or ""
      local bx = cx + indent * 4 * SCALE
      renderer.draw_text(font, "•", bx, cy, bullet_color)
      local bx2 = bx + font:get_width("• ")
      -- word-wrap the bullet content inline
      local words = {}
      for w in content:gmatch("%S+") do words[#words+1] = w end
      local lx = bx2
      for wi, word in ipairs(words) do
        local img_url = word:match("^%[Image:(.-)%]$")
        if img_url then
          if lc_view then
            table.insert(lc_view.image_links, {x=lx, y=cy, w=font:get_width("[image]"), h=lh, url=img_url})
          end
          lx = renderer.draw_text(font, "[image] ", lx, cy, LC_COLORS.accepted)
        else
          if lx + font:get_width(word) > cx + max_w and lx > bx2 then
            cy = cy + lh; lx = bx2
          end
          -- check for inline code
          if word:match("`") then
            lx = draw_inline_rich(font, word .. " ", lx, cy, cx + max_w, main_fg)
          else
            lx = renderer.draw_text(font, word .. " ", lx, cy, main_fg)
          end
        end
      end
      cy = cy + lh

    elseif line:match("^%[Image:") then
      -- ── Standalone image placeholder ─────────────────
      local img_url = line:match("^%[Image:(.-)%]")
      if img_url and lc_view then
        local label = "📷  View diagram →"
        renderer.draw_rect(cx, cy, max_w, lh + 4*SCALE, {30,40,60,200})
        renderer.draw_text(font, label, cx + 8*SCALE, cy + 2*SCALE, LC_COLORS.accepted)
        table.insert(lc_view.image_links, {x=cx, y=cy, w=max_w, h=lh+4*SCALE, url=img_url})
      end
      cy = cy + lh + 8*SCALE

    else
      -- ── Normal paragraph line – word-wrap with inline code ─────────────
      local words = {}
      for w in line:gmatch("%S+") do words[#words+1] = w end
      if #words == 0 then
        cy = cy + lh * 0.5
      else
        local lx = cx
        for _, word in ipairs(words) do
          local img_url = word:match("^%[Image:(.-)%]$")
          if img_url then
            if lc_view then
              table.insert(lc_view.image_links, {x=lx, y=cy, w=font:get_width("[img]"), h=lh, url=img_url})
            end
            lx = renderer.draw_text(font, "[img] ", lx, cy, LC_COLORS.accepted)
          else
            -- measure word (may have backticks)
            local plain_word = word:gsub("`", "")
            local ww = font:get_width(plain_word) + 8 * SCALE -- rough with padding
            if lx + ww > cx + max_w and lx > cx then
              cy = cy + lh; lx = cx
            end
            lx = draw_inline_rich(font, word .. " ", lx, cy, cx + max_w, main_fg)
          end
        end
        cy = cy + lh
      end
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
        if mouse_x >= b.x and mouse_x <= b.x + b.w and mouse_y >= b.y and mouse_y <= b.y + b.h then
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
  -- Fully fluid: always fill the actual allocated split width/height
  -- Small pad (8px) on sides so text doesn't touch edges
  local pad = math.min(16 * SCALE, sw * 0.03)
  local x, y = self.position.x, self.position.y
  local w, h = sw, sh

  -- Top accent bar scales with width
  renderer.draw_rect(x, y, w, 2 * SCALE, style.accent)

  local cx, cy = x + pad, y + 14 * SCALE
  local cw = w - 2 * pad

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
    
    -- In narrow mode, skip the inline hints and use abbreviated layout
    local narrow = cw < 350 * SCALE
    if not narrow then
      renderer.draw_text(style.font, "Alt+R:Run  Alt+S:Submit  #tag  @co", cx, cy, style.accent)
    else
      renderer.draw_text(style.font, "Alt+R Run  Alt+S Submit", cx, cy, style.accent)
    end
    cy = cy + 30*SCALE
    
    renderer.draw_text(style.font, "Search:", cx, cy, style.text)
    local search_lbl_w = style.font:get_width("Search: ")
    local search_x = cx + search_lbl_w
    local search_y = cy
    self.search_y_start = search_y
    -- Pick One button width (hide if panel is too narrow)
    local pick_btn_w = (cw > 280*SCALE) and (style.font:get_width("Pick One") + 24*SCALE) or 0
    local search_w = cw - search_lbl_w - (pick_btn_w > 0 and pick_btn_w + 10*SCALE or 0)
    local search_h = 24*SCALE

    local border_color = self.search_focus and style.accent or style.dim
    renderer.draw_rect(search_x, search_y + search_h, search_w, 2*SCALE, border_color)
    renderer.draw_text(style.font, self.search_input, search_x + 5*SCALE, search_y + 2*SCALE, style.text)

    if pick_btn_w > 0 then
      local r_x = search_x + search_w + 10*SCALE
      local r_y = search_y
      local r_h = 24*SCALE
      self.random_btn_rect = {x = r_x, y = r_y, w = pick_btn_w, h = r_h}
      renderer.draw_rect(r_x, r_y, pick_btn_w, r_h, style.background2)
      renderer.draw_rect(r_x, r_y, pick_btn_w, 1*SCALE, LC_COLORS.accepted)
      renderer.draw_rect(r_x, r_y + r_h - 1*SCALE, pick_btn_w, 1*SCALE, LC_COLORS.accepted)
      renderer.draw_text(style.font, "Pick One", r_x + 8*SCALE, r_y + 4*SCALE, LC_COLORS.accepted)
    else
      self.random_btn_rect = nil
    end
    
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

          -- Proportional columns: diff=15%, stat=12%, prem=10% from right edge
          local narrow_list = cw < 300 * SCALE
          local diff_x, stat_x, prem_x
          if narrow_list then
            -- In narrow mode: just id + title, no extra columns
            diff_x  = cx + cw + 1  -- push off-screen
            stat_x  = cx + cw + 1
            prem_x  = cx + cw + 1
          else
            local has_prem = p.paid
            prem_x  = has_prem and (cx + cw - style.font:get_width("(Prem)") - 4*SCALE) or (cx + cw + 1)
            local stat_fw = style.font:get_width("50.0% [AC]")
            stat_x  = (prem_x < cx + cw) and (prem_x - stat_fw - 10*SCALE) or (cx + cw - stat_fw - 4*SCALE)
            local diff_fw = style.font:get_width("Medium")
            diff_x  = stat_x - diff_fw - 14*SCALE
          end

          local title_max_x = (diff_x < cx + cw) and diff_x or (cx + cw)
          local title_avail = title_max_x - (cx + 50*SCALE) - 8*SCALE
          local title = p.title
          -- Clip title to fit by pixel width
          while #title > 4 and style.font:get_width(title) > title_avail do
            title = title:sub(1, -2)
          end
          if title ~= p.title then title = title .. "..." end

          local title_color = style.text
          if p.status == "ac" then title_color = LC_COLORS.accepted end
          if p.status == "notac" then title_color = LC_COLORS.tle end
          renderer.draw_text(style.font, title, cx + 50*SCALE, item_y, title_color)

          if diff_x <= cx + cw then
            local dc = LC_COLORS[p.difficulty:lower()]
            local bg_dc = {dc[1], dc[2], dc[3], dc[4] * 0.15}
            local dw = style.font:get_width(p.difficulty)
            renderer.draw_rect(diff_x - 4*SCALE, item_y - 2*SCALE, dw + 8*SCALE, style.font:get_height() + 4*SCALE, bg_dc)
            renderer.draw_text(style.font, p.difficulty, diff_x, item_y, dc)
          end
          if stat_x <= cx + cw then
            local stat_str = p.ac_rate .. "%"
            if p.status == "ac" then stat_str = stat_str .. " [AC]" end
            local stat_color = p.status == "ac" and LC_COLORS.accepted or style.dim
            renderer.draw_text(style.font, stat_str, stat_x, item_y, stat_color)
          end
          if p.paid and prem_x <= cx + cw then
            renderer.draw_text(style.font, "(Prem)", prem_x, item_y, LC_COLORS.tle)
          end
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
      
      if not p_topic and self.search_input:match("#$") then p_topic = "" end
      if not p_comp and self.search_input:match("@$") then p_comp = "" end

      local partial = p_topic or p_comp
      
      if partial then
        local filtered = {}
        local src_list = p_topic and TOPIC_TAGS or COMPANIES
        local prefix = p_topic and "#" or "@"
        
        for _, t in ipairs(src_list) do
          if partial == "" or t:find(partial, 1, true) then table.insert(filtered, t) end
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
    local diff_lower = p.difficulty:lower()
    local dc = LC_COLORS[diff_lower] or style.text

    -- ── Header Bar ───────────────────────────────────────────────────────────
    -- Back button
    local back_label = "<  Back"
    local back_w = style.font:get_width(back_label) + 16 * SCALE
    local back_h = style.font:get_height() + 8 * SCALE
    renderer.draw_rect(cx, cy, back_w, back_h, style.background2)
    renderer.draw_text(style.font, back_label, cx + 8*SCALE, cy + 4*SCALE, style.dim)
    self.back_btn_rect = {x=cx, y=cy, w=back_w, h=back_h}

    -- Difficulty badge (right-aligned)
    local diff_badge_x = cx + cw - style.font:get_width(p.difficulty) - 16*SCALE
    local badge_w = style.font:get_width(p.difficulty) + 16*SCALE
    local badge_h = back_h
    renderer.draw_rect(diff_badge_x, cy, badge_w, badge_h, {dc[1], dc[2], dc[3], 35})
    renderer.draw_rect(diff_badge_x, cy, badge_w, 1*SCALE, dc)
    renderer.draw_rect(diff_badge_x, cy + badge_h - SCALE, badge_w, 1*SCALE, dc)
    renderer.draw_text(style.font, p.difficulty, diff_badge_x + 8*SCALE, cy + 4*SCALE, dc)

    cy = cy + back_h + 8*SCALE

    -- Title - wraps if too long for narrow panel
    local title_font = (cw > 300*SCALE) and (style.big_font or style.font) or style.font
    local title = p.title
    local title_max_w = cw - badge_w - 8*SCALE
    -- If title overflows, draw it on two lines by splitting at nearest word
    if title_font:get_width(title) > cw then
      local half = math.floor(#title / 2)
      while half > 0 and title:sub(half, half) ~= " " do half = half - 1 end
      if half > 0 then
        renderer.draw_text(title_font, title:sub(1, half), cx, cy, style.text)
        cy = cy + title_font:get_height() + 2*SCALE
        renderer.draw_text(title_font, title:sub(half + 1), cx, cy, style.text)
      else
        renderer.draw_text(title_font, title, cx, cy, style.text)
      end
    else
      renderer.draw_text(title_font, title, cx, cy, style.text)
    end
    cy = cy + title_font:get_height() + 8*SCALE

    -- Chip row: wraps when narrow
    local chip_y = cy
    local chip_h = style.font:get_height() + 6*SCALE
    local chip_x = cx
    local chip_row_max_x = cx + cw - (style.font:get_width("Copy desc") + 14*SCALE) - 8*SCALE

    local function draw_chip(label, fg, bg)
      bg = bg or {fg[1], fg[2], fg[3], 25}
      local cw2 = style.font:get_width(label) + 14*SCALE
      if chip_x + cw2 > chip_row_max_x then
        chip_x = cx
        chip_y = chip_y + chip_h + 4*SCALE
      end
      renderer.draw_rect(chip_x, chip_y, cw2, chip_h, bg)
      renderer.draw_text(style.font, label, chip_x + 7*SCALE, chip_y + 3*SCALE, fg)
      chip_x = chip_x + cw2 + 6*SCALE
      return cw2
    end

    if p.question_id or p.id then
      draw_chip("#" .. (p.question_id or p.id), {common.color("#888888")})
    end
    if p.topics and #p.topics > 0 then
      for _, t in ipairs(p.topics) do
        draw_chip(t, {common.color("#75BFFF")})
      end
    end

    -- Copy button always right-aligned at the same cy as start of chip row
    local copy_label = "Copy desc"
    local copy_w = style.font:get_width(copy_label) + 14*SCALE
    local init_chip_y = cy  -- original chip row start
    self.copy_btn_rect = {x = cx + cw - copy_w, y = init_chip_y, w = copy_w, h = chip_h}
    renderer.draw_rect(cx + cw - copy_w, init_chip_y, copy_w, chip_h, {style.accent[1], style.accent[2], style.accent[3], 30})
    renderer.draw_text(style.font, copy_label, cx + cw - copy_w + 7*SCALE, init_chip_y + 3*SCALE, style.accent)

    cy = chip_y + chip_h + 10*SCALE

    -- Company row
    if p.companies and #p.companies > 0 then
      local comp_x = cx
      local comp_y = cy
      renderer.draw_text(style.font, "Asked by:", comp_x, comp_y + 2*SCALE, style.dim)
      comp_x = comp_x + style.font:get_width("Asked by: ")
      for ci, company in ipairs(p.companies) do
        if ci > 8 then
          renderer.draw_text(style.font, "+ " .. (#p.companies - 8) .. " more", comp_x, comp_y + 2*SCALE, style.dim)
          break
        end
        local cw2 = style.font:get_width(company) + 10*SCALE
        -- Fix: common.color returns r,g,b,a separately so must wrap correctly
        local rc, gc, bc = 255, 97, 136
        renderer.draw_rect(comp_x, comp_y, cw2, chip_h - 2*SCALE, {rc, gc, bc, 30})
        renderer.draw_text(style.font, company, comp_x + 5*SCALE, comp_y + 2*SCALE, {rc, gc, bc, 255})
        comp_x = comp_x + cw2 + 5*SCALE
        if comp_x > cx + cw - 80*SCALE then break end
      end
      cy = comp_y + chip_h + 10*SCALE
    end

    -- Language picker hint
    renderer.draw_text(style.font, "Pick a language to scaffold your solution:",
      cx, cy, {common.color("#888888")})
    cy = cy + style.font:get_height() + 5*SCALE

    -- Divider with accent
    renderer.draw_rect(cx, cy, cw, 1*SCALE, dc)
    cy = cy + 8*SCALE

    -- ── Scrollable content area ───────────────────────────────────────────
    local scroll_area_h = (y + h - 20*SCALE) - cy
    self.problem_scroll_y_start = cy
    self.problem_scroll_h = scroll_area_h
    core.push_clip_rect(cx, cy, cw, scroll_area_h)

    local inner_cy = cy - self.scroll_y
    self.content_y_start = inner_cy
    lc_view.image_links = {}

    -- ── Problem content ────────────────────────────────────────────────────
    inner_cy = draw_rich_content(style.font, p.content_plain, cx + 4*SCALE, inner_cy, cw - 8*SCALE, self.scroll_y)

    inner_cy = inner_cy + 20*SCALE
    renderer.draw_rect(cx, inner_cy, cw, 1*SCALE, {common.color("#444444")})
    inner_cy = inner_cy + 16*SCALE

    -- ── Language buttons ─────────────────────────────────────────────────
    local LANG_COLORS = {
      python3    = {common.color("#3572A5")},
      javascript = {common.color("#F1E05A")},
      typescript = {common.color("#3178C6")},
      cpp        = {common.color("#F34B7D")},
      c          = {common.color("#555555")},
      java       = {common.color("#B07219")},
      csharp     = {common.color("#178600")},
      golang     = {common.color("#00ADD8")},
      rust       = {common.color("#DEA584")},
      ruby       = {common.color("#701516")},
      swift      = {common.color("#F05138")},
      kotlin     = {common.color("#A97BFF")},
      php        = {common.color("#4F5D95")},
      lua        = {common.color("#000080")},
      bash       = {common.color("#89E051")},
    }
    local lang_lh = 32 * SCALE
    local lang_cy = inner_cy
    local bx = cx
    local sorted_langs = {}
    for lang in pairs(p.starters or {}) do table.insert(sorted_langs, lang) end
    table.sort(sorted_langs)
    self.lang_buttons = {}

    for _, lang in ipairs(sorted_langs) do
      local lbl = lang
      local lcol = LANG_COLORS[lang] or {common.color("#888888")}
      local lw = style.font:get_width(lbl) + 28*SCALE

      if bx + lw > cx + cw then
        bx = cx
        lang_cy = lang_cy + lang_lh + 6*SCALE
      end

      -- Card background
      renderer.draw_rect(bx, lang_cy, lw, lang_lh,
        {lcol[1], lcol[2], lcol[3], 20})
      -- Top accent line
      renderer.draw_rect(bx, lang_cy, lw, 2*SCALE, lcol)
      -- Language dot
      renderer.draw_rect(bx + 8*SCALE, lang_cy + lang_lh/2 - 4*SCALE, 8*SCALE, 8*SCALE, lcol)
      -- Label
      renderer.draw_text(style.font, lbl, bx + 22*SCALE, lang_cy + lang_lh/2 - style.font:get_height()/2, style.text)

      table.insert(self.lang_buttons, {x=bx, y=lang_cy, w=lw, h=lang_lh, lang=lang})
      bx = bx + lw + 8*SCALE
    end
    lang_cy = lang_cy + lang_lh + 16*SCALE

    -- ── Similar questions ────────────────────────────────────────────────
    self.similar_buttons = {}
    if p.similar_questions and #p.similar_questions > 0 then
      lang_cy = lang_cy + 8*SCALE
      renderer.draw_text(style.font, "Similar Problems", cx, lang_cy, style.dim)
      lang_cy = lang_cy + style.font:get_height() + 10*SCALE

      local sq_x = cx
      for _, sq in ipairs(p.similar_questions) do
        local diff_col  = LC_COLORS[sq.difficulty:lower()] or style.dim
        local sq_label  = sq.title
        local sq_w      = style.font:get_width(sq_label) + 24*SCALE
        local diff_tag  = " [" .. sq.difficulty:sub(1,1) .. "]"
        local dtw       = style.font:get_width(diff_tag)
        local total_w   = sq_w + dtw + 4*SCALE

        if sq_x + total_w > cx + cw then
          sq_x = cx; lang_cy = lang_cy + 28*SCALE
        end

        renderer.draw_rect(sq_x, lang_cy, sq_w, 24*SCALE, {diff_col[1], diff_col[2], diff_col[3], 20})
        renderer.draw_rect(sq_x, lang_cy, 3*SCALE, 24*SCALE, diff_col)
        renderer.draw_text(style.font, sq_label, sq_x + 8*SCALE, lang_cy + 3*SCALE, style.text)
        renderer.draw_text(style.font, diff_tag, sq_x + sq_w, lang_cy + 3*SCALE, diff_col)

        table.insert(self.similar_buttons, {
          x=sq_x, y=lang_cy, w=total_w, h=24*SCALE, slug=sq.titleSlug
        })
        sq_x = sq_x + total_w + 10*SCALE
      end
      lang_cy = lang_cy + 32*SCALE
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


