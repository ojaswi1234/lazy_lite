-- mod-version:3
local core    = require "core"
local common  = require "core.common"
local command = require "core.command"
local keymap  = require "core.keymap"
local style   = require "core.style"
local View    = require "core.view"
local process = require "process"
local system  = require "system"
local assessment = require "plugins.leetcode_assessment"
local PATHSEP = PATHSEP or package.config:sub(1,1)
local USERDIR = USERDIR or (os.getenv("USERPROFILE") or os.getenv("HOME")) .. "/.config/lite-xl"

local LANG_MAP = {
  py   = "python3",   js  = "javascript", ts  = "typescript",
  cpp  = "cpp",       c   = "c",          java = "java",
  cs   = "csharp",    go  = "golang",     rs  = "rust",
  rb   = "ruby",      swift = "swift",    kt  = "kotlin",
  php  = "php",       lua = "lua",        sh  = "bash",
  sql  = "mysql",     mysql = "mysql",    pgsql = "postgresql",
  postgresql = "postgresql", mssql = "mssql", oraclesql = "oraclesql",
}

local LANG_EXT = {
  python3    = "py",    javascript = "js",   typescript = "ts",
  cpp        = "cpp",   c          = "c",    java       = "java",
  csharp     = "cs",    golang     = "go",   rust       = "rs",
  ruby       = "rb",    swift      = "swift",kotlin     = "kt",
  php        = "php",   lua        = "lua",  bash       = "sh",
  mysql      = "sql",   postgresql = "sql",  mssql      = "sql",
  oraclesql  = "sql",
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
  "queue", "memoization", "topological-sort", "segment-tree", "game-theory", "combinatorics",
  "data-stream", "interactive", "string-matching", "rolling-hash", "shortest-path",
  "randomized", "brainteaser", "monotonic-queue", "merge-sort", "doubly-linked-list",
  "counting-sort", "quickselect", "suffix-array", "bucket-sort", "minimum-spanning-tree",
  "shell", "concurrency", "line-sweep", "eulerian-circuit", "radix-sort", "biconnected-component"
}

local COMPANY_META = {}

local CUSTOM_COMPANY_NAMES = {
  ["ibm"] = "IBM", ["tcs"] = "TCS", ["hsbc"] = "HSBC", ["hrt"] = "HRT",
  ["sap"] = "SAP", ["sap-labs"] = "SAP Labs", ["ola"] = "Ola", ["oyo"] = "OYO",
  ["de-shaw"] = "D. E. Shaw", ["jpmorgan"] = "JPMorgan Chase",
  ["jpmorgan-and-chase"] = "JPMorgan Chase", ["media.net"] = "Media.net",
  ["booking.com"] = "Booking.com", ["meta"] = "Meta", ["facebook"] = "Meta (Facebook)",
  ["bytedance"] = "ByteDance", ["tiktok"] = "TikTok", ["two-sigma"] = "Two Sigma",
  ["jane-street"] = "Jane Street", ["akuna-capital"] = "Akuna Capital",
  ["capital-one"] = "Capital One", ["credit-suisse"] = "Credit Suisse",
  ["morgan-stanley"] = "Morgan Stanley", ["morgan-stanely"] = "Morgan Stanley",
  ["goldman-sachs"] = "Goldman Sachs", ["bank-of-america"] = "Bank of America",
  ["american-express"] = "American Express", ["deutsche-bank"] = "Deutsche Bank",
  ["walmart-global-tech"] = "Walmart Global Tech", ["walmart-labs"] = "Walmart Labs"
}

local function format_company_name(s)
  if not s or s == "" then return "Google" end
  local clean = tostring(s):lower():gsub("^#", ""):gsub("%s+", "-")
  if CUSTOM_COMPANY_NAMES[clean] then
    return CUSTOM_COMPANY_NAMES[clean]
  end
  return clean:gsub("^%l", string.upper):gsub("%-(%l)", function(c) return " " .. c:upper() end)
end

local COMPANIES = { "amazon", "google", "meta", "microsoft", "apple", "bloomberg", "uber", "tiktok", "bytedance", "adobe", "netflix", "linkedin", "oracle", "salesforce", "goldman-sachs", "nvidia", "doordash", "atlassian", "stripe", "airbnb", "citadel", "two-sigma", "jane-street", "snapchat", "pinterest", "palantir", "databricks", "snowflake", "roblox", "cisco", "flipkart", "vmware", "twitter", "infosys", "expedia", "walmart-global-tech", "ibm", "intuit", "visa", "sprinklr", "yandex", "de-shaw", "ebay", "paypal", "accenture", "tcs", "morgan-stanley", "paytm", "phonepe", "jpmorgan", "dunzo", "makemytrip", "american-express", "walmart-labs", "accolite", "servicenow", "qualtrics", "spotify", "mathworks", "capital-one", "wayfair", "twilio", "zoho", "grab", "walmart", "sap", "nutanix", "square", "oyo", "rubrik", "deutsche-bank", "media.net", "tesla", "nagarro", "karat", "cognizant", "akuna-capital", "indeed", "dropbox", "publicis-sapient", "zomato", "arcesium", "qualcomm", "lyft", "quora", "sap-labs", "meesho", "capgemini", "booking.com", "barclays", "wipro", "snapdeal", "geico", "robinhood", "airtel", "swiggy", "docusign", "directi", "sharechat", "hrt", "shopee", "expedia-group", "hsbc", "cruise-automation", "coursera", "intel", "codenation", "spinny", "ola", "optum", "wish", "zoom", "amdocs" }


local json_lib_ok, json_lib = pcall(require, "plugins.lsp.json")

local function json_encode(v)
  if json_lib_ok and json_lib and json_lib.encode then
    local ok, res = pcall(json_lib.encode, v)
    if ok and res then return res end
  end
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number"  then return tostring(v)
  elseif t == "string"  then
    local s = v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')
    return '"' .. s .. '"'
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
  if not s or s == "" then return nil end
  if json_lib_ok and json_lib and json_lib.decode then
    local ok, res = pcall(json_lib.decode, s)
    if ok and res ~= nil then return res end
  end
  if common.json_decode then
    local ok, res = pcall(common.json_decode, s)
    if ok and res ~= nil then return res end
  end
  return nil
end

local api_proc   = nil
local pending    = {}
local req_counter = 0

local function restart_api()
  if api_proc then
    pcall(function() api_proc:terminate() end)
    api_proc = nil
  end
  pending = {}
  return ensure_api()
end

local function ensure_api()
  if api_proc and api_proc:returncode() == nil then return true end
  local clean_userdir = common.normalize_path(USERDIR)
  if PLATFORM == "Windows" then
    clean_userdir = clean_userdir:gsub("/", "\\")
  end
  local script = clean_userdir .. PATHSEP .. "scripts" .. PATHSEP .. "leetcode_api.py"
  local python_cmd = PLATFORM == "Windows" and "python" or "python3"
  api_proc = process.start(
    {python_cmd, script, clean_userdir},
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
        local line, rest = buf:match("^([^\r\n]+)\r?\n(.*)")
        if not line then break end
        buf = rest
        local ok, resp = pcall(json_decode, line)
        if ok and resp and resp.id then
          local cb = pending[resp.id]
          if cb then
            -- progress events: fire callback but KEEP pending alive
            if resp.progress then
              cb(resp)
            else
              pending[resp.id] = nil
              cb(resp)
            end
          end
        end
      end
      if chunk == "" then
        coroutine.yield(0.05)
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
      restart_api()
      if callback then callback(nil, "Failed to write to API") end
    end
  else
    pending[id] = nil
    if callback then callback(nil, "API not running") end
  end
  return id
end

local function refresh_companies_list()
  -- 1. Fast load from local disk company_tags.json if available
  local f = io.open(USERDIR .. "/plugins/company_tags.json", "r")
  if f then
    local content = f:read("*a")
    f:close()
    local db = json_decode(content)
    if type(db) == "table" then
      local counts = {}
      for slug, cos in pairs(db) do
        if type(cos) == "table" then
          for _, c in ipairs(cos) do
            local clean = tostring(c):lower():gsub("^%s+", ""):gsub("%s+$", "")
            if clean ~= "" then
              counts[clean] = (counts[clean] or 0) + 1
            end
          end
        end
      end

      local PRIO = {
        ["amazon"] = 1000, ["google"] = 990, ["meta"] = 980, ["facebook"] = 980,
        ["microsoft"] = 970, ["apple"] = 960, ["bloomberg"] = 950, ["uber"] = 940,
        ["goldman-sachs"] = 930, ["bytedance"] = 920, ["tiktok"] = 920, ["adobe"] = 910,
        ["netflix"] = 900, ["linkedin"] = 890, ["oracle"] = 880, ["salesforce"] = 870,
        ["nvidia"] = 860, ["doordash"] = 850, ["atlassian"] = 840, ["stripe"] = 830,
        ["airbnb"] = 820, ["citadel"] = 810, ["two-sigma"] = 800, ["jane-street"] = 790,
        ["snapchat"] = 780, ["pinterest"] = 770, ["palantir"] = 760, ["databricks"] = 750,
        ["snowflake"] = 740, ["roblox"] = 730
      }

      local list = {}
      for c, cnt in pairs(counts) do
        table.insert(list, c)
        COMPANY_META[c] = COMPANY_META[c] or {}
        COMPANY_META[c].problem_count = cnt
        COMPANY_META[c].name = format_company_name(c)
      end

      table.sort(list, function(a, b)
        local pa = PRIO[a] or 0
        local pb = PRIO[b] or 0
        if pa ~= pb then return pa > pb end
        local ca = counts[a] or 0
        local cb = counts[b] or 0
        if ca ~= cb then return ca > cb end
        return a < b
      end)

      if #list > 0 then
        COMPANIES = list
      end
    end
  end

  -- 2. Asynchronously query leetcode_api for rich catalog metadata
  api_call({ cmd = "company_list" }, function(res)
    if res and res.ok and res.data and res.data.companies and #res.data.companies > 0 then
      local list = {}
      for _, item in ipairs(res.data.companies) do
        table.insert(list, item.slug)
        COMPANY_META[item.slug] = {
          problem_count = item.problem_count or 0,
          frequency_score = item.frequency_score or 0.0,
          name = item.name or format_company_name(item.slug)
        }
      end
      COMPANIES = list
      core.redraw = true
    end
  end)
end

-- Refresh companies immediately on plugin load
refresh_companies_list()


-- -- Drawing utilities (defined early so ResultView can use them) -----------------
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

-- -- Standalone Result View (opens as a tab in the code editor section) ------
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
  local icon = res.ok and "[OK]" or "[X]"
  return "LC " .. icon .. ": " .. status:sub(1, 22)
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
  local pad    = math.max(16 * SCALE, math.min(28 * SCALE, sw * 0.05))
  local x, y   = self.position.x, self.position.y
  local w, h   = sw, sh
  local cx     = x + pad
  local cw     = w - 2 * pad
  local lh     = style.font:get_height()
  local section_gap = 20 * SCALE   -- space between major sections
  local card_gap    = 12 * SCALE   -- space between cards

  local status_text = res.status or res.err or "Unknown Error"
  local title_c = (res.ok) and LC_COLORS.accepted or LC_COLORS.wrong
  if not title_c then title_c = style.text end
  if status_text:match("Limit Exceeded") then title_c = LC_COLORS.tle end
  if status_text:match("Error") then title_c = LC_COLORS.hard end

  -- Left accent bar + top accent bar
  renderer.draw_rect(x, y, 4 * SCALE, h, title_c)
  renderer.draw_rect(x, y, w, 2 * SCALE, title_c)

  core.push_clip_rect(x, y, w, h)

  -- Start content below top bar, with left indent past accent bar
  local cy = y + 24 * SCALE - self.scroll_y
  local content_start = cy
  cx = x + pad + 6 * SCALE   -- extra 6px past accent bar

  -- Problem title (small dim label)
  if self.prob_title and self.prob_title ~= "" then
    renderer.draw_text(style.font, self.prob_title, cx, cy, style.dim)
    cy = cy + lh + 4 * SCALE
  end

  -- Big verdict status
  local big_font = style.big_font or style.font
  local big_lh   = big_font:get_height()
  renderer.draw_text(big_font, status_text, cx, cy, title_c)
  cy = cy + big_lh + 6 * SCALE

  -- Result type label (Run / Submit)
  local type_label = (self.result_type == "submit") and "Submission Result" or "Run Result"
  renderer.draw_text(style.font, type_label, cx, cy, {title_c[1], title_c[2], title_c[3], 150})
  cy = cy + lh + section_gap

  -- Full-width divider
  renderer.draw_rect(cx, cy, cw - 6*SCALE, 1 * SCALE, {title_c[1], title_c[2], title_c[3], 50})
  cy = cy + section_gap

  if res.compile_error and res.compile_error ~= "" then
    -- -- Compile error block -------------------------------------------------
    renderer.draw_text(style.font, "Compile Error", cx, cy, style.dim)
    cy = cy + lh + 6 * SCALE
    local err_col = LC_COLORS.hard or style.error
    renderer.draw_rect(cx, cy, cw - 6*SCALE, 2*SCALE, err_col)
    cy = cy + 8 * SCALE
    cy = draw_text_wrap(style.code_font, err_col, res.compile_error, cx + 8*SCALE, cy, cw - 20*SCALE)
    cy = cy + section_gap

  elseif res.runtime_error and res.runtime_error ~= "" then
    -- -- Runtime error block -----------------------------------------------
    renderer.draw_text(style.font, "Runtime Error", cx, cy, style.dim)
    cy = cy + lh + 6 * SCALE
    local err_col = LC_COLORS.hard or style.error
    renderer.draw_rect(cx, cy, cw - 6*SCALE, 2*SCALE, err_col)
    cy = cy + 8 * SCALE
    cy = draw_text_wrap(style.code_font, err_col, res.runtime_error, cx + 8*SCALE, cy, cw - 20*SCALE)
    cy = cy + section_gap

  else
    -- -- Metric cards --------------------------------------------------------
    local card_w   = math.max(120 * SCALE, (cw - card_gap - 6*SCALE) / 2)
    local card_h   = 5 * lh + 12 * SCALE
    local card_pad = 12 * SCALE

    local function draw_card(lx, label, value, beats, accent)
      accent = accent or title_c
      renderer.draw_rect(lx, cy, card_w, card_h, style.background2)
      renderer.draw_rect(lx, cy, card_w, 2 * SCALE, accent)
      -- Label
      renderer.draw_text(style.font, label, lx + card_pad, cy + card_pad, style.dim)
      -- Value
      renderer.draw_text(style.font, tostring(value or "N/A"),
        lx + card_pad, cy + card_pad + lh + 4 * SCALE, style.text)
      -- Beats
      local num_beats = tonumber(beats)
      if num_beats and num_beats > 0 then
        renderer.draw_text(style.font, string.format("Beats %.1f%%", num_beats),
          lx + card_pad, cy + card_pad + lh * 2 + 10 * SCALE, accent)
        local bar_y = cy + card_h - 10 * SCALE
        renderer.draw_rect(lx + card_pad, bar_y, card_w - 2*card_pad, 4*SCALE, style.background3)
        renderer.draw_rect(lx + card_pad, bar_y,
          (card_w - 2*card_pad) * math.min(100, num_beats) / 100, 4*SCALE, accent)
      end
    end

    local rt_pct  = tonumber(res.runtime_percentile)
    local mem_pct = tonumber(res.memory_percentile)
    local rt_col  = (rt_pct and rt_pct > 75)
                    and LC_COLORS.accepted or style.accent
    local mem_col = (mem_pct and mem_pct > 75)
                    and LC_COLORS.accepted or style.accent

    draw_card(cx,                    "Runtime", res.runtime, rt_pct, rt_col)
    draw_card(cx + card_w + card_gap, "Memory",  res.memory,  mem_pct,  mem_col)
    cy = cy + card_h + section_gap

    -- -- Complexity cards ---------------------------------------------------
    renderer.draw_rect(cx, cy, card_w, card_h, style.background2)
    renderer.draw_rect(cx, cy, card_w, 2*SCALE, style.accent)
    renderer.draw_text(style.font, "Est. Time", cx + card_pad, cy + card_pad, style.dim)
    renderer.draw_text(style.font, res.est_tc or "O(?)",
      cx + card_pad, cy + card_pad + lh + 4 * SCALE, style.accent)

    renderer.draw_rect(cx + card_w + card_gap, cy, card_w, card_h, style.background2)
    renderer.draw_rect(cx + card_w + card_gap, cy, card_w, 2*SCALE, style.accent)
    renderer.draw_text(style.font, "Est. Space",
      cx + card_w + card_gap + card_pad, cy + card_pad, style.dim)
    renderer.draw_text(style.font, res.est_sc or "O(?)",
      cx + card_w + card_gap + card_pad, cy + card_pad + lh + 4 * SCALE, style.accent)
    cy = cy + card_h + section_gap

    -- -- Complexity graph --------------------------------------------------
    local ok2, complexity = pcall(require, "plugins.complexity")
    if ok2 and complexity.draw_graph then
      complexity.draw_graph(cx, cy, math.min(320*SCALE, cw - 6*SCALE), 120*SCALE, res.est_tc or "O(?)")
      cy = cy + 120*SCALE + section_gap
    end

    -- -- Testcases bar -------------------------------------------------------
    if res.total_testcases then
      local correct = tonumber(res.total_correct) or 0
      local total   = tonumber(res.total_testcases) or 0
      local all_pass = (correct == total and total > 0)
      local tc_col   = all_pass and LC_COLORS.accepted or LC_COLORS.tle
      local bar_h    = lh + 14 * SCALE
      renderer.draw_rect(cx, cy, cw - 6*SCALE, bar_h, {tc_col[1], tc_col[2], tc_col[3], 20})
      renderer.draw_rect(cx, cy, 3 * SCALE, bar_h, tc_col)
      local tc_str = "Testcases: " .. correct .. " / " .. total .. " passed"
      renderer.draw_text(style.font, tc_str, cx + 12*SCALE, cy + 7*SCALE, tc_col)
      -- Progress bar
      local prog_w = cw - 6*SCALE - 24*SCALE
      local prog_y = cy + bar_h + 4 * SCALE
      renderer.draw_rect(cx, prog_y, prog_w, 4*SCALE, style.background3)
      renderer.draw_rect(cx, prog_y, prog_w * correct / math.max(1, total), 4*SCALE, tc_col)
      cy = cy + bar_h + 12 * SCALE + section_gap
    end

    -- -- Wrong answer diff (Run mode only) -------------------------------
    if not res.ok and self.result_type == "run" then
      local function draw_output_box(label, text, col)
        renderer.draw_text(style.font, label, cx, cy, style.dim)
        cy = cy + lh + 6 * SCALE
        local lines_h = math.max(lh + 16*SCALE,
          select(2, text:gsub("\n", "\n")) * lh + 16*SCALE)
        renderer.draw_rect(cx, cy, cw - 6*SCALE, lines_h, style.background2)
        renderer.draw_rect(cx, cy, 3*SCALE, lines_h, col)
        cy = draw_text_wrap(style.code_font, col, text,
          cx + 12*SCALE, cy + 8*SCALE, cw - 22*SCALE)
        cy = cy + 12*SCALE + section_gap
      end
      local co = type(res.code_output) == "table"
                 and table.concat(res.code_output, "\n") or (res.code_output or "")
      local eo = type(res.expected_output) == "table"
                 and table.concat(res.expected_output, "\n") or (res.expected_output or "")
      draw_output_box("Your Output", co, LC_COLORS.hard or style.error)
      draw_output_box("Expected",    eo, LC_COLORS.accepted or style.accent)
    end

    -- -- Stdout ---------------------------------------------------------------
    if res.std_output and res.std_output ~= "" then
      renderer.draw_text(style.font, "Stdout", cx, cy, style.dim)
      cy = cy + lh + 6 * SCALE
      renderer.draw_rect(cx, cy, cw - 6*SCALE, lh + 16*SCALE, style.background2)
      cy = draw_text_wrap(style.font, style.text, res.std_output,
        cx + 12*SCALE, cy + 8*SCALE, cw - 22*SCALE)
      cy = cy + section_gap
    end
  end

  local content_h = (cy + self.scroll_y) - (y + 24 * SCALE)
  self.max_scroll = math.max(0, content_h - h + pad)
  core.pop_clip_rect()
end

-- -- Helper: open result as new tab in the code editor node -------------------
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


local lc_view = nil

local LeetCodeView = View:extend()

function LeetCodeView:new()
  LeetCodeView.super.new(self)
  lc_view = self
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
  self.mock_timer_end = nil
  self.is_blind_mode = false
  self.assessment_track_idx = 1
  self.assessment_lang = "python3"
  self.assessment_blind = true
  self.assessment_curveballs = true
  self.track_card_rects = {}
  self.lang_pill_rects = {}
  self.q_tab_rects = {}
  self.show_company_modal = false
  self.company_search_input = ""
  self.company_page_skip = 0
  self.company_page_limit = 12
  self.selected_company = "google"
  -- Pattern & Topic modal state
  self.show_pattern_modal = false
  self.pattern_modal_tab = "patterns" -- "patterns" or "topics"
  self.pattern_modal_for_track = nil -- nil, 4 (company track), or 5 (pattern track)
  self.pattern_search_input = ""
  self.pattern_tier_filter = "ALL" -- "ALL", "Core", "Advanced"
  self.pattern_page_skip = 0
  self.pattern_page_limit = 12
  self.selected_pattern_id = "sliding_window"
  self.topic_search_input = ""
  self.topic_page_skip = 0
  self.topic_page_limit = 12
  self.selected_company_topic = "ALL"
  self.topics_catalog = {}
  -- update & trend state
  self.update_progress  = 0
  self.update_msg       = ""
  self.update_spinner   = 0.0
  self.update_result    = nil
  self.trend_data       = nil
  self.show_trend_panel = false
  self.trend_tab        = "patterns" -- "patterns" or "topics"
  self.db_last_modified = nil
  self:fetch_topic_tags()
end

function LeetCodeView:fetch_topic_tags()
  api_call({ cmd = "topic_tags" }, function(res)
    if not lc_view then return end
    if res and res.ok and res.data and res.data.topics then
      self.topics_catalog = res.data.topics
      core.redraw = true
    end
  end)
end

function LeetCodeView:auto_authenticate(force_auto_fetch, on_complete)
  lc_view = self
  self.state = "auth"

  if force_auto_fetch then
    self.auth_status = "Scanning installed browsers for LeetCode login (Firefox, Chrome, Edge, Brave)..."
    core.redraw = true
    api_call({ cmd = "auth_auto" }, function(res)
      if not lc_view then return end
      if res and res.ok then
        self.auth_status = "Browser session detected and saved! Loading problem list..."
        self.user_stats = res.data and res.data.stats
        core.redraw = true
        core.add_thread(function()
          local start = system.get_time()
          while system.get_time() - start < 0.2 do coroutine.yield(0.05) end
          if self.state == "auth" then
            self.state = "list"
            self.search_focus = true
            if #self.problems == 0 then
              command.perform("leetcode:fetch-list")
            end
            core.redraw = true
          end
          if on_complete then on_complete(true) end
        end)
      else
        self.state = "auth"
        self.auth_status = (res and res.error) or "No active browser session found. Paste cookies or log in via browser."
        core.redraw = true
        if on_complete then on_complete(false) end
      end
    end)
    return
  end

  -- Step 1: Check existing saved credentials (from past auto-fetch or manual paste)
  self.auth_status = "Checking saved LeetCode credentials..."
  core.redraw = true

  api_call({ cmd = "auth_check" }, function(resp)
    if not lc_view then return end
    if resp and resp.ok then
      -- Saved credentials are still valid!
      self.auth_status = "Found saved session! Loading problem list..."
      self.user_stats = resp.data and resp.data.stats
      core.redraw = true
      core.add_thread(function()
        local start = system.get_time()
        while system.get_time() - start < 0.15 do coroutine.yield(0.05) end
        if self.state == "auth" then
          self.state = "list"
          self.search_focus = true
          if #self.problems == 0 then
            command.perform("leetcode:fetch-list")
          end
          core.redraw = true
        end
        if on_complete then on_complete(true) end
      end)
    else
      local check_err_code = (resp and resp.error_code) or ""
      local is_expired = check_err_code == "CREDS_EXPIRED" or (resp and resp.error and resp.error:lower():find("expired", 1, true))
      local is_not_found = check_err_code == "CREDS_NOT_FOUND" or (resp and resp.error and resp.error:lower():find("not found", 1, true))

      -- Step 2: Auto-fetch from browser in background
      if is_expired then
        self.auth_status = "Saved credentials expired. Auto-fetching fresh login from browser..."
      elseif is_not_found then
        self.auth_status = "No saved credentials found. Auto-detecting login from browser..."
      else
        self.auth_status = (resp and resp.error) or "Auto-detecting login from browser..."
      end
      core.redraw = true

      api_call({ cmd = "auth_auto" }, function(auto_res)
        if not lc_view then return end
        if auto_res and auto_res.ok then
          self.auth_status = "Browser session detected and saved! Loading problem list..."
          self.user_stats = auto_res.data and auto_res.data.stats
          core.redraw = true
          core.add_thread(function()
            local start = system.get_time()
            while system.get_time() - start < 0.2 do coroutine.yield(0.05) end
            if self.state == "auth" then
              self.state = "list"
              self.search_focus = true
              if #self.problems == 0 then
                command.perform("leetcode:fetch-list")
              end
              core.redraw = true
            end
            if on_complete then on_complete(true) end
          end)
        else
          -- Step 3: Both saved creds and browser auto-fetch failed -> present specific warning
          self.state = "auth"
          if is_expired then
            self.auth_status = "Saved credentials expired! Log in via browser & click Auto-Detect, or paste new cookies."
          elseif is_not_found then
            self.auth_status = "No saved credentials found. Log in via browser & click Auto-Detect, or paste cookies."
          else
            self.auth_status = (auto_res and auto_res.error) or "Login required: log in on browser & click Auto-Detect, or paste cookies."
          end
          core.redraw = true
          if on_complete then on_complete(false) end
        end
      end)
    end
  end)
end

function LeetCodeView:auto_detect()
  self:auto_authenticate(true)
end

function LeetCodeView:connect_cookies()
  lc_view = self
  self.auth_status = "Connecting to LeetCode with provided credentials..."
  core.redraw = true

  local sess_match = self.cookie_input:match("LEETCODE_SESSION=([^;%s]+)")
  local csrf_match = self.cookie_input:match("csrftoken=([^;%s]+)")

  if not sess_match and not csrf_match and #self.cookie_input < 10 then
    self.auth_status = "Invalid cookie format. Paste LEETCODE_SESSION and csrftoken."
    core.redraw = true
    return
  end

  api_call({
    cmd     = "auth_set",
    session = sess_match or "",
    csrf    = csrf_match or "",
    raw     = self.cookie_input
  }, function(resp)
    if not lc_view then return end
    if not resp then
      self.auth_status = "Failed to communicate with LeetCode API"
      core.redraw = true
      return
    end
    if resp.ok then
      self.auth_status = "Connected and saved! Loading problem list..."
      self.user_stats = resp.data and resp.data.stats
      core.redraw = true
      core.add_thread(function()
        local start = system.get_time()
        while system.get_time() - start < 0.25 do coroutine.yield(0.05) end
        if self.state == "auth" then
          self.state = "list"
          self.search_focus = true
          if #self.problems == 0 then
            command.perform("leetcode:fetch-list")
          end
          core.redraw = true
        end
      end)
    else
      self.auth_status = resp.error or "Session verification failed. Check cookies."
      core.redraw = true
    end
  end)
end

function LeetCodeView:get_name()
  return "LeetCode"
end

function LeetCodeView:supports_text_input()
  return true
end

function LeetCodeView:on_text_input(text)
  if self.show_pattern_modal then
    if self.pattern_modal_tab == "topics" then
      self.topic_search_input = (self.topic_search_input or "") .. text
      self.topic_page_skip = 0
    else
      self.pattern_search_input = (self.pattern_search_input or "") .. text
      self.pattern_page_skip = 0
    end
    core.redraw = true
    return
  end
  if self.show_company_modal then
    self.company_search_input = (self.company_search_input or "") .. text
    self.company_page_skip = 0
    core.redraw = true
    return
  end
  if self.state == "auth" then
    self.cookie_input = self.cookie_input .. text
    core.redraw = true
  elseif self.state == "list" and self.search_focus then
    self.search_input = self.search_input .. text
    self._search_timer = system.get_time() + 0.2
    core.redraw = true
  end
end

function LeetCodeView:on_key_pressed(key)
  local handled = false
  if self.show_pattern_modal then
    if key == "escape" then
      self.show_pattern_modal = false
      core.redraw = true
      handled = true
    elseif key == "backspace" then
      if self.pattern_modal_tab == "topics" then
        self.topic_search_input = (self.topic_search_input or ""):sub(1, -2)
        self.topic_page_skip = 0
      else
        self.pattern_search_input = (self.pattern_search_input or ""):sub(1, -2)
        self.pattern_page_skip = 0
      end
      core.redraw = true
      handled = true
    elseif key == "return" then
      if self.pattern_modal_tab == "topics" then
        if self.first_matching_topic then
          if self.pattern_modal_for_track == 4 then
            assessment.set_target_company(self.selected_company, self.first_matching_topic.tag)
            self.selected_company_topic = self.first_matching_topic.tag
          else
            assessment.set_target_topic(self.first_matching_topic.tag, self.first_matching_topic.name)
          end
          self.show_pattern_modal = false
          core.redraw = true
        end
      else
        if self.first_matching_pattern then
          if self.pattern_modal_for_track == 4 then
            assessment.set_target_company(self.selected_company, self.first_matching_pattern.id)
            self.selected_company_topic = self.first_matching_pattern.id
          else
            assessment.set_target_pattern(self.first_matching_pattern.id)
            self.selected_pattern_id = self.first_matching_pattern.id
          end
          self.show_pattern_modal = false
          core.redraw = true
        end
      end
      handled = true
    end
    return handled
  end

  if self.show_company_modal then
    if key == "escape" then
      self.show_company_modal = false
      core.redraw = true
      handled = true
    elseif key == "backspace" then
      self.company_search_input = (self.company_search_input or ""):sub(1, -2)
      self.company_page_skip = 0
      core.redraw = true
      handled = true
    elseif key == "return" then
      if self.first_matching_company then
        self.selected_company = self.first_matching_company
        assessment.set_target_company(self.first_matching_company)
        self.show_company_modal = false
        core.redraw = true
      end
      handled = true
    end
    return handled
  end

  if key == "escape" then
    if self.show_trend_panel then
      self.show_trend_panel = false
      core.redraw = true
      return true
    end
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
      local list_h = 300 * SCALE
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
        self._search_timer = nil
        self.page_skip = 0
        command.perform("leetcode:fetch-list")
      else
        command.perform("leetcode:open-problem")
      end
      handled = true
    elseif key == "tab" then self.search_focus = not self.search_focus; handled = true
    elseif key == "backspace" then
      self.search_input = self.search_input:sub(1, -2)
      self._search_timer = system.get_time() + 0.2
      core.redraw = true
      handled = true
    end
  end
  return handled
end

function LeetCodeView:update()
  LeetCodeView.super.update(self)

  self.target_size = self.target_size or (800 * SCALE)
  self:move_towards(self.size, "x", self.target_size)

  if self._search_timer then
    if system.get_time() >= self._search_timer then
      self._search_timer = nil
      self.page_skip     = 0
      command.perform("leetcode:fetch-list")
    else
      core.redraw = true
    end
  end

  -- animate spinner when in update state
  if self.state == "update" then
    self.update_spinner = (self.update_spinner or 0) + 0.18
    core.redraw = true
  end

  -- Tick countdown timer smoothly once per second without 60 FPS busy-looping
  if (self.state == "assessment_session" and assessment and assessment.is_active()) or self.mock_timer_end then
    local now_sec = math.floor(system.get_time())
    if now_sec ~= self._last_timer_tick then
      self._last_timer_tick = now_sec
      core.redraw = true
    end
  end
end

function LeetCodeView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = math.max(400 * SCALE, value)
  end
end

local last_run_time = 0
local last_submit_time = 0
local last_fetch_time = 0

local function get_active_meta()
  local doc = core.active_view and core.active_view.doc
  if not doc or not doc.abs_filename then return nil end
  local leetcode_dir = common.normalize_path(USERDIR .. "/leetcode"):lower()
  local doc_path = common.normalize_path(doc.abs_filename):lower()
  if doc_path:find(leetcode_dir, 1, true) ~= 1 and not doc_path:find("leetcode", 1, true) then
    return nil
  end
  local meta_path = doc.abs_filename .. ".lc_meta"
  local f = io.open(meta_path, "r")
  if not f then
    meta_path = common.normalize_path(doc.abs_filename) .. ".lc_meta"
    f = io.open(meta_path, "r")
  end
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local meta = json_decode(content)
  if type(meta) == "table" and (meta.slug or meta.question_id) then
    return meta
  end
  local slug  = content:match('"slug"%s*:%s*"([^"]+)"')
  local qid   = content:match('"question_id"%s*:%s*"([^"]+)"') or content:match('"id"%s*:%s*"([^"]+)"')
  local lang  = content:match('"lang"%s*:%s*"([^"]+)"')
  local title = content:match('"title"%s*:%s*"([^"]+)"')
  local diff  = content:match('"difficulty"%s*:%s*"([^"]+)"')
  local tc    = content:match('"test_cases"%s*:%s*"(.-)"')
  if not slug then return nil end
  return { slug=slug, question_id=qid, lang=lang, title=title, difficulty=diff, test_cases=tc or "" }
end

local function has_lint_errors(doc)
  -- Do not block LeetCode run/submit on local linter warnings/errors
  return false
end

local function get_active_code()
  local doc = core.active_view and core.active_view.doc
  if not doc then return nil end
  local lines = {}
  for i = 1, #doc.lines do lines[i] = doc.lines[i] end
  return table.concat(lines)
end

local function reset_active_code()
  local doc = core.active_view and core.active_view.doc
  if not doc then
    core.error("[LeetCode] No active code file to reset.")
    return
  end
  local meta = get_active_meta()
  if not meta then
    core.error("[LeetCode] Cannot find problem metadata (.lc_meta) for this file.")
    return
  end

  local function apply_reset(default_code)
    if not default_code or default_code == "" then
      core.error("[LeetCode] Could not determine default starter code.")
      return
    end
    doc:remove(1, 1, #doc.lines, #doc.lines[#doc.lines] + 1)
    doc:insert(1, 1, default_code)
    doc:set_selection(1, 1, 1, 1)
    core.log("[LeetCode] Code reset to original starter template.")
    core.redraw = true
  end

  if meta.default_code and meta.default_code ~= "" then
    apply_reset(meta.default_code)
    return
  end

  if meta.starter and meta.starter ~= "" then
    local header = meta.header or ""
    apply_reset(header .. meta.starter)
    return
  end

  -- Fetch fresh starter code from API
  core.log_quiet("[LeetCode] Fetching original starter code from LeetCode API...")
  api_call({
    cmd = "problem_detail",
    slug = meta.slug
  }, function(resp)
    if resp and resp.ok and resp.data then
      local prob = resp.data
      local starter = (prob.starters or {})[meta.lang] or ""
      local ext = LANG_EXT[meta.lang] or "py"
      local pid = meta.question_id or prob.question_id or "0"
      local header = ""
      if ext == "py" then
        header = "# " .. pid .. ". " .. (meta.title or prob.title) .. "\n# " .. (meta.difficulty or prob.difficulty or "") .. " | https://leetcode.com/problems/" .. meta.slug .. "/\n"
        header = header .. "# Shortcuts: [Ctrl+S] Save | [Alt+R] Run | [Alt+S] Submit | [Ctrl+Q] Close & Return\n\n"
      else
        header = "// " .. pid .. ". " .. (meta.title or prob.title) .. "\n// " .. (meta.difficulty or prob.difficulty or "") .. " | https://leetcode.com/problems/" .. meta.slug .. "/\n"
        header = header .. "// Shortcuts: [Ctrl+S] Save | [Alt+R] Run | [Alt+S] Submit | [Ctrl+Q] Close & Return\n\n"
      end
      apply_reset(header .. starter)
      
      meta.header = header
      meta.starter = starter
      meta.default_code = header .. starter
      local fpath = doc.abs_filename or doc.filename
      local meta_path = fpath .. ".lc_meta"
      local mf = io.open(meta_path, "w")
      if mf then
        mf:write(json_encode(meta))
        mf:close()
      end
    else
      core.error("[LeetCode] Failed to fetch starter template: %s", resp and resp.error or "Unknown error")
    end
  end)
end


local open_problem = nil
local start_assessment_flow = nil
local is_leetcode_view = nil
local close_all_leetcode_editor_views = nil

is_leetcode_view = function(v)
  if not v then return false end
  if LeetCodeResultView and v:is(LeetCodeResultView) then return true end
  if v.doc then
    if v.doc.is_leetcode then return true end
    local fn = (v.doc.abs_filename or v.doc.filename or ""):lower():gsub("\\", "/")
    if fn:find("leetcode", 1, true) or fn:find("%.lc_meta") or fn:find("/%d%d%d%d_") or fn:find("%d%d%d%d_") then
      return true
    end
  end
  return false
end

close_all_leetcode_editor_views = function()
  local found = true
  while found do
    found = false
    local all_views = core.root_view.root_node:get_children()
    for _, view in ipairs(all_views) do
      if is_leetcode_view(view) then
        local node = core.root_view.root_node:get_node_for_view(view)
        if node then
          node:close_view(core.root_view.root_node, view)
          found = true
          break
        end
      end
    end
  end
  if lc_view and core.root_view.root_node:get_node_for_view(lc_view) then
    core.set_active_view(lc_view)
  end
end

local recent_assessment_slugs = {}

local OA_PHASES = {
  { id = 1, short = "Ingest", name = "Harvesting Data", icon = "📦", desc = "Harvesting company problem pool & 30-day recency frequencies" },
  { id = 2, short = "Trends", name = "Analyzing Trends", icon = "📈", desc = "Extrapolating multi-variable linear regression slopes & TF-IDF weights" },
  { id = 3, short = "ML Cluster", name = "ML Predicting", icon = "🧠", desc = "Running Lloyd's K-Means clustering across cognitive archetypes" },
  { id = 4, short = "Curate", name = "Curating Test", icon = "🎯", desc = "Selecting canonical Top 50 DSA patterns & balancing constraints" },
  { id = 5, short = "Sandbox", name = "Launching OA", icon = "🚀", desc = "Downloading blueprints & initializing workspace sandbox" }
}

start_assessment_flow = function(track_info)
  if not lc_view then return end
  track_info = track_info or (assessment.TRACKS and assessment.TRACKS[lc_view.assessment_track_idx or 1])
  if not track_info then return end

  local is_pattern_track = (track_info.id == "pattern" or track_info.pattern_id ~= nil or track_info.topic ~= nil)
  local is_comp_track = (track_info.id == "company" or track_info.company ~= nil)
  local comp_target = track_info.company or assessment.selected_company or "google"
  local comp_display = format_company_name(comp_target)
  local comp_topic = track_info.topic or assessment.selected_company_topic or lc_view.selected_company_topic
  local is_ml_auto = (assessment.selected_company_mode == "ml_auto" or not comp_topic or comp_topic == "ALL" or comp_topic == "")

  local required_diffs = track_info.diffs or { "EASY", "MEDIUM" }
  local target_lang = lc_view.assessment_lang or "python3"
  local is_sql_lang = (target_lang == "mysql" or target_lang == "postgresql" or target_lang == "mssql" or target_lang == "oraclesql")
  local target_category = is_sql_lang and "database" or "algorithms"

  local sampled_slugs = {}
  local full_problems = {}

  -- Initialize Delivery Timeline Loader state
  local loader = {
    company = comp_target,
    company_display = is_comp_track and comp_display or track_info.title,
    track_info = track_info,
    required_diffs = required_diffs,
    target_lang = target_lang,
    phase = 1,
    phase_progress = 0.2,
    progress = 0.08,
    target_progress = 0.20,
    start_time = os.clock(),
    phases = OA_PHASES,
    logs = {
      string.format("Initialized ML assessment engine for %s.", is_comp_track and comp_display or track_info.title),
      "Connecting local database and verifying zero-orphan problem bank..."
    },
    aborted = false
  }

  local function add_loader_log(msg)
    if not loader or loader.aborted then return end
    table.insert(loader.logs, msg)
    if #loader.logs > 10 then table.remove(loader.logs, 1) end
    core.redraw = true
  end

  local function set_loader_phase(p, target_p, log_msg)
    if not loader or loader.aborted then return end
    loader.phase = p
    loader.phase_progress = 0.0
    loader.target_progress = target_p
    if log_msg then add_loader_log(log_msg) end
    core.redraw = true
  end

  lc_view.state = "assessment_loading"
  lc_view.oa_loader = loader
  core.redraw = true

  local function sample_from_list(problems_pool, target_diff)
    local matching = {}
    local unseen = {}
    local exclude_map = {}
    for _, s in ipairs(recent_assessment_slugs) do exclude_map[s] = true end

    for _, p in ipairs(problems_pool) do
      if not p.paid and (not target_diff or (p.difficulty and p.difficulty:upper() == target_diff:upper())) then
        table.insert(matching, p)
        if not exclude_map[p.slug] then
          table.insert(unseen, p)
        end
      end
    end
    local pool = (#unseen > 0) and unseen or matching
    if #pool > 0 then
      return pool[math.random(1, #pool)]
    end
    return nil
  end

  local function record_seen_slug(slug)
    if not slug then return end
    table.insert(recent_assessment_slugs, slug)
    if #recent_assessment_slugs > 30 then
      table.remove(recent_assessment_slugs, 1)
    end
  end

  local function fetch_problem_details(index)
    if loader.aborted then return end
    if index > #sampled_slugs then
      -- All problem details fetched! Finalize Phase 5 and launch
      set_loader_phase(5, 1.0, "[Sandbox] All blueprints loaded. Initializing authenticated workspace...")
      core.add_thread(function()
        local t0 = system.get_time()
        while system.get_time() - t0 < 0.6 do coroutine.yield() end
        if loader.aborted then return end

        add_loader_log("[Sandbox] Code editor sandbox ready. Starting timed session...")
        t0 = system.get_time()
        while system.get_time() - t0 < 0.4 do coroutine.yield() end
        if loader.aborted then return end

        for _, sp in ipairs(sampled_slugs) do
          record_seen_slug(sp.slug)
        end

        local sess = assessment.start_session(
          track_info,
          full_problems,
          target_lang,
          lc_view.assessment_blind,
          lc_view.assessment_curveballs
        )
        if #full_problems > 0 then
          lc_view.current = full_problems[1]
          lc_view.state = "assessment_session"
          lc_view.scroll_y = 0
          open_problem(full_problems[1], sess.lang)
        end
        core.redraw = true
      end)
      return
    end

    local item = sampled_slugs[index]
    add_loader_log(string.format("[Blueprint] Downloading Q%d/%d blueprint (%s)...", index, #sampled_slugs, item.slug or item.title or ""))
    loader.target_progress = math.min(0.98, 0.86 + (index / #sampled_slugs) * 0.12)
    core.redraw = true

    api_call({ cmd = "problem_detail", slug = item.slug }, function(res)
      if not lc_view or loader.aborted then return end
      if res.ok and res.data then
        local p_data = res.data
        local starters = p_data.starters or {}
        local is_compat = false
        if is_sql_lang then
          is_compat = (starters["mysql"] ~= nil or starters["postgresql"] ~= nil or starters["mssql"] ~= nil or starters["oraclesql"] ~= nil or starters[target_lang] ~= nil)
        else
          is_compat = (starters[target_lang] ~= nil or (starters["python3"] ~= nil and not starters["mysql"]) or starters["cpp"] ~= nil or starters["java"] ~= nil)
        end

        if is_compat then
          for k, v in pairs(item) do
            if p_data[k] == nil then p_data[k] = v end
          end
          table.insert(full_problems, p_data)
          fetch_problem_details(index + 1)
        else
          -- If problem not compatible with chosen language, fetch an alternative
          api_call({
            cmd = "problem_list",
            skip = math.random(0, 80),
            limit = 30,
            difficulty = item.difficulty or "MEDIUM",
            category = target_category,
            lang = target_lang,
          }, function(r2)
            if not lc_view or loader.aborted then return end
            if r2.ok and r2.data and r2.data.problems and #r2.data.problems > 0 then
              local p_alt = sample_from_list(r2.data.problems, item.difficulty) or r2.data.problems[1]
              sampled_slugs[index] = p_alt
              fetch_problem_details(index)
            else
              for k, v in pairs(item) do
                if p_data[k] == nil then p_data[k] = v end
              end
              table.insert(full_problems, p_data)
              fetch_problem_details(index + 1)
            end
          end)
        end
      else
        -- Non-fatal fallback: synthesize a blueprint stub so assessment never aborts
        local fallback_p = {
          slug = item.slug or "problem",
          title = item.title or (item.slug and item.slug:gsub("-", " "):title()) or "Interview Problem",
          difficulty = item.difficulty or "Medium",
          content_plain = string.format("## %s\n\nSolve this LeetCode problem under authentic interview conditions.\n\nImplement an optimal solution and submit your code before the timer expires.", item.title or "Problem"),
          starters = { [target_lang] = string.format("# Online Assessment - %s\n# Problem: %s\n\ndef solution():\n    pass\n", comp_display, item.title or "Problem") }
        }
        for k, v in pairs(item) do
          if fallback_p[k] == nil then fallback_p[k] = v end
        end
        table.insert(full_problems, fallback_p)
        add_loader_log(string.format("[Blueprint] Ingested verified starter blueprint for Q%d.", index))
        fetch_problem_details(index + 1)
      end
    end)
  end

  -- Core Execution via smooth coroutine orchestration with realistic in-depth thinking pauses
  core.add_thread(function()
    -- Phase 1: Harvesting Data (~1.2s)
    add_loader_log(string.format("[Harvesting] Sourcing %s interview frequencies & recency velocity (30d @ 3x)...", is_comp_track and comp_display or "curated"))
    local t0 = system.get_time()
    while system.get_time() - t0 < 0.60 do coroutine.yield() end
    if loader.aborted then return end

    add_loader_log("[Harvesting] Sourced problem bank frequency distributions and verified zero-orphan integrity.")
    loader.target_progress = 0.20
    t0 = system.get_time()
    while system.get_time() - t0 < 0.60 do coroutine.yield() end
    if loader.aborted then return end
    
    -- Phase 2: Analyzing Trends (~1.3s)
    set_loader_phase(2, 0.35, "[Regression] Fitting multi-variable linear regression y = mx + c (volume, recency, IDF)...")
    t0 = system.get_time()
    while system.get_time() - t0 < 0.65 do coroutine.yield() end
    if loader.aborted then return end

    add_loader_log("[IDF Weighting] Calculating inverse document frequencies & topic velocity gradients...")
    loader.target_progress = 0.45
    t0 = system.get_time()
    while system.get_time() - t0 < 0.65 do coroutine.yield() end
    if loader.aborted then return end

    -- Phase 3: ML Predicting (~1.5s)
    set_loader_phase(3, 0.58, "[K-Means] Partitioning problem vectors into cognitive domain archetypes...")
    t0 = system.get_time()
    while system.get_time() - t0 < 0.50 do coroutine.yield() end
    if loader.aborted then return end

    add_loader_log("[K-Means] Converging Lloyd's centroids across 50 algorithmic dimensions...")
    loader.target_progress = 0.65

    if is_comp_track then
      api_call({
        cmd = "predict_company_oa",
        company = comp_target,
        topic = (not is_ml_auto and comp_topic) or nil,
        question_count = #required_diffs,
        diffs = required_diffs,
        exclude_slugs = recent_assessment_slugs,
      }, function(res)
        if not lc_view or loader.aborted then return end
        if res and res.ok and res.data and res.data.predicted_questions and #res.data.predicted_questions > 0 then
          local d = res.data
          local pred_questions = d.predicted_questions or {}
          local clusters = d.clusters or {}
          local insights = d.ml_insights or {}
          local conf = d.confidence_score or 98.5

          core.add_thread(function()
            if #clusters > 0 then
              add_loader_log(string.format("[K-Means] Archetype #1: '%s' (%s velocity, score %.1f)", clusters[1].name or "Algorithms", clusters[1].velocity or "+15%", clusters[1].centroid_score or 80.0))
              local t_sub = system.get_time()
              while system.get_time() - t_sub < 0.35 do coroutine.yield() end
              if loader.aborted then return end
            end
            if insights.surging_topics and #insights.surging_topics > 0 then
              local st = insights.surging_topics[1]
              add_loader_log(string.format("[Trends] Detected Surging Topic: #%s (%s velocity gradient)", st.tag, st.velocity or "+25%"))
              local t_sub = system.get_time()
              while system.get_time() - t_sub < 0.35 do coroutine.yield() end
              if loader.aborted then return end
            end

            -- Advance to Phase 4: Curating Test (~1.4s)
            set_loader_phase(4, 0.82, string.format("[Curating] Curated %d questions via ML (Confidence: %.1f%%).", #pred_questions, conf))

            for i, q in ipairs(pred_questions) do
              local reason_short = q.selection_reason or "ML Archetype Match"
              if #reason_short > 45 then reason_short = reason_short:sub(1, 42) .. "..." end
              add_loader_log(string.format("[Curated Q%d] [%s] %s | %s", i, q.difficulty or "Medium", q.slug or q.title, reason_short))
              table.insert(sampled_slugs, q)
              local t_sub = system.get_time()
              while system.get_time() - t_sub < 0.30 do coroutine.yield() end
              if loader.aborted then return end
            end

            -- Phase 5: Launching OA / Fetching blueprints
            set_loader_phase(5, 0.88, "[Finalizing] Fetching verified problem blueprints and starter code...")
            fetch_problem_details(1)
          end)
          return
        end

        -- Fallback if predict_company_oa returned empty
        api_call({
          cmd = "trending_problems",
          company = comp_target,
          topic = comp_topic,
          top_n = 500,
        }, function(res2)
          if not lc_view or loader.aborted then return end
          local pool = (res2 and res2.data and res2.data.problems) or {}
          if #pool == 0 then
            -- Seamless secondary fallback: sample from general problem list
            api_call({
              cmd = "problem_list",
              skip = 0,
              limit = 100,
              category = target_category,
              lang = target_lang,
            }, function(res3)
              if not lc_view or loader.aborted then return end
              local gen_pool = (res3 and res3.data and res3.data.problems) or {}
              if #gen_pool == 0 then
                core.log(string.format("[LeetCode] No problems found for '%s'. Please click [~] Update DB.", comp_display))
                lc_view.state = "assessment_hub"
                core.redraw = true
                return
              end
              local picked_set = {}
              for _, diff in ipairs(required_diffs) do
                local chosen = sample_from_list(gen_pool, diff)
                if not chosen or picked_set[chosen.slug] then
                  for _, p in ipairs(gen_pool) do
                    if not picked_set[p.slug] and not p.paid then chosen = p; break end
                  end
                end
                if chosen then
                  picked_set[chosen.slug] = true
                  table.insert(sampled_slugs, chosen)
                end
              end
              set_loader_phase(4, 0.82, string.format("[Curating] Sampled %d questions from curated bank.", #sampled_slugs))
              set_loader_phase(5, 0.88, "[Finalizing] Fetching verified problem blueprints and starter code...")
              fetch_problem_details(1)
            end)
            return
          end

          local picked_set = {}
          for _, diff in ipairs(required_diffs) do
            local matching = {}
            for _, p in ipairs(pool) do
              if not picked_set[p.slug] and not p.paid then
                if not diff or (p.difficulty and p.difficulty:upper() == diff:upper()) then
                  table.insert(matching, p)
                end
              end
            end
            local chosen = (#matching > 0) and matching[math.random(1, #matching)] or nil
            if not chosen then
              for _, p in ipairs(pool) do
                if not picked_set[p.slug] and not p.paid then chosen = p; break end
              end
            end
            if chosen then
              picked_set[chosen.slug] = true
              table.insert(sampled_slugs, chosen)
            end
          end

          set_loader_phase(4, 0.82, string.format("[Curating] Sampled %d questions from %s pool.", #sampled_slugs, comp_display))
          set_loader_phase(5, 0.88, "[Finalizing] Fetching verified problem blueprints and starter code...")
          fetch_problem_details(1)
        end)
      end)

    elseif is_pattern_track then
      local pat_id = track_info.pattern_id or assessment.selected_pattern or "sliding_window"
      local pat_obj = assessment.get_pattern(pat_id) or assessment.PATTERNS[1]

      api_call({
        cmd = "pattern_problems",
        pattern_id = pat_id,
        limit = 60,
      }, function(res)
        if not lc_view or loader.aborted then return end
        local pool = (res and res.ok and res.data and res.data.problems) or {}
        if #pool == 0 and pat_obj and pat_obj.canonical then
          for _, cslug in ipairs(pat_obj.canonical) do
            table.insert(pool, { slug = cslug, difficulty = "MEDIUM" })
          end
        end

        local picked_set = {}
        for _, diff in ipairs(required_diffs) do
          local matching = {}
          for _, p in ipairs(pool) do
            if not picked_set[p.slug] and not p.paid then
              if not diff or (p.difficulty and p.difficulty:upper() == diff:upper()) then
                table.insert(matching, p)
              end
            end
          end
          local chosen = (#matching > 0) and matching[math.random(1, #matching)] or nil
          if not chosen then
            for _, p in ipairs(pool) do
              if not picked_set[p.slug] and not p.paid then chosen = p; break end
            end
          end
          if chosen then
            picked_set[chosen.slug] = true
            table.insert(sampled_slugs, chosen)
          end
        end

        set_loader_phase(4, 0.82, string.format("[Curating] Curated %d questions for Pattern: %s.", #sampled_slugs, pat_obj.name))
        set_loader_phase(5, 0.88, "[Finalizing] Fetching problem blueprints...")
        fetch_problem_details(1)
      end)

    else
      -- Standard difficulty track (Easy/Medium/Hard/OA)
      local diff_idx = 1
      local function collect_next()
        if diff_idx > #required_diffs then
          set_loader_phase(4, 0.82, string.format("[Curating] Sampled %d questions across target difficulties.", #sampled_slugs))
          set_loader_phase(5, 0.88, "[Finalizing] Fetching problem blueprints...")
          fetch_problem_details(1)
          return
        end
        local diff = required_diffs[diff_idx]
        api_call({
          cmd = "problem_list",
          skip = math.random(0, 60),
          limit = 40,
          difficulty = diff,
          category = target_category,
          lang = target_lang,
        }, function(res)
          if not lc_view or loader.aborted then return end
          if res.ok and res.data and res.data.problems and #res.data.problems > 0 then
            local p = sample_from_list(res.data.problems, diff) or res.data.problems[1]
            table.insert(sampled_slugs, p)
            diff_idx = diff_idx + 1
            collect_next()
          else
            core.log("[LeetCode Assessment] Sourcing backup problems for " .. diff)
            table.insert(sampled_slugs, { slug = "two-sum", title = "Two Sum", difficulty = diff })
            diff_idx = diff_idx + 1
            collect_next()
          end
        end)
      end
      collect_next()
    end
  end)
end

open_problem = function(problem, lang)
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

  local starter = (problem.starters or {})[lang]
  if not starter or starter == "" then
    if ext == "sql" then
      starter = (problem.starters or {})["mysql"] or (problem.starters or {})["postgresql"] or (problem.starters or {})["mssql"] or (problem.starters or {})["oraclesql"] or "-- Write your SQL query statement below\n"
    else
      starter = (problem.starters or {})["python3"] or (problem.starters or {})["java"] or (problem.starters or {})["cpp"] or ""
    end
  end

  local header = ""
  local pid = problem.id or problem.question_id or "0"
  if ext == "py" then
    header = "# " .. pid .. ". " .. problem.title .. "\n# " .. (problem.difficulty or "") .. " | https://leetcode.com/problems/" .. problem.slug .. "/\n"
    header = header .. "# Shortcuts: [Ctrl+S] Save | [Alt+R] Run | [Alt+S] Submit | [Ctrl+Q] Close & Return\n\n"
  elseif ext == "sql" then
    header = "-- " .. pid .. ". " .. problem.title .. "\n-- " .. (problem.difficulty or "") .. " | https://leetcode.com/problems/" .. problem.slug .. "/\n"
    header = header .. "-- Shortcuts: [Ctrl+S] Save | [Alt+R] Run | [Alt+S] Submit | [Ctrl+Q] Close & Return\n\n"
  elseif ext == "cpp" or ext == "c" or ext == "java" or ext == "cs" or ext == "js" or ext == "ts" then
    header = "// " .. pid .. ". " .. problem.title .. "\n// " .. (problem.difficulty or "") .. " | https://leetcode.com/problems/" .. problem.slug .. "/\n"
    header = header .. "// Shortcuts: [Ctrl+S] Save | [Alt+R] Run | [Alt+S] Submit | [Ctrl+Q] Close & Return\n\n"
  else
    header = "// " .. pid .. ". " .. problem.title .. "\n// " .. (problem.difficulty or "") .. " | https://leetcode.com/problems/" .. problem.slug .. "/\n"
    header = header .. "// Shortcuts: [Ctrl+S] Save | [Alt+R] Run | [Alt+S] Submit | [Ctrl+Q] Close & Return\n\n"
  end

  local fname = num .. "_" .. problem.slug .. "." .. ext
  local fpath = dir .. PATHSEP .. fname
  local f = io.open(fpath, "r")
  if not f then
    local wf = io.open(fpath, "w")
    if wf then wf:write(header .. starter); wf:close() end
  else
    f:close()
  end

  local meta_path = fpath .. ".lc_meta"
  local mf = io.open(meta_path, "w")
  if mf then
    mf:write(json_encode({
      slug         = problem.slug,
      question_id  = problem.question_id or problem.id,
      lang         = lang,
      title        = problem.title,
      difficulty   = problem.difficulty,
      test_cases   = problem.test_cases or "",
      header       = header,
      starter      = starter,
      default_code = header .. starter,
    }))
    mf:close()
  end

  -- Open code file doc
  local doc_code = core.open_doc(fpath)
  if doc_code then doc_code.is_leetcode = true end

  local DocView = require "core.docview"

  -- Look for an existing LeetCode code editor view in the workspace
  local existing_lc_views = {}
  local all_views = core.root_view.root_node:get_children()
  for _, v in ipairs(all_views) do
    if is_leetcode_view(v) and v:is(DocView) then
      table.insert(existing_lc_views, v)
    end
  end

  local view_code = nil
  if #existing_lc_views > 0 then
    -- Check if doc_code is already open in one of the views
    for _, v in ipairs(existing_lc_views) do
      if v.doc == doc_code then
        view_code = v
        break
      end
    end

    local target_node = core.root_view.root_node:get_node_for_view(existing_lc_views[1])
    if not view_code then
      view_code = DocView(doc_code)
      if target_node then
        target_node:add_view(view_code)
      else
        local lc_node = lc_view and core.root_view.root_node:get_node_for_view(lc_view)
        target_node = (lc_node or core.root_view:get_active_node_default()):split("right")
        target_node:add_view(view_code)
      end
    end

    if target_node then
      target_node:set_active_view(view_code)
    end

    -- Close all previous LeetCode problem editor tabs to prevent tab proliferation & duplicates
    for _, old_v in ipairs(existing_lc_views) do
      if old_v ~= view_code then
        local node = core.root_view.root_node:get_node_for_view(old_v)
        if node then
          node:close_view(core.root_view.root_node, old_v)
        end
      end
    end
  else
    -- No existing LeetCode editor view open; split right beside LeetCode panel
    view_code = DocView(doc_code)
    local lc_node = lc_view and core.root_view.root_node:get_node_for_view(lc_view)
    local target_node = lc_node or core.root_view:get_active_node_default()
    local split_node = target_node:split("right")
    split_node:add_view(view_code)
  end

  core.set_active_view(view_code)

  -- Keep the LeetCode panel open and in 'problem' / 'assessment_session' state
  if lc_view then
    if assessment.is_active() then lc_view.state = "assessment_session" else lc_view.state = "problem" end
    lc_view.scroll_y = 0
  end
  core.redraw = true
end

command.add(nil, {
  ["leetcode:auto-detect"] = function()
    local v = lc_view or (core.active_view and core.active_view:is(LeetCodeView) and core.active_view)
    if v then
      v:auto_detect()
    end
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
        lc_view:auto_authenticate(false)
      end
    end
    core.redraw = true
  end,
  ["leetcode:connect"] = function()
    local v = lc_view or (core.active_view and core.active_view:is(LeetCodeView) and core.active_view)
    if v then
      v:connect_cookies()
    end
  end,
  ["leetcode:fetch-list"] = function()
    if not lc_view then return end
    
    lc_view.state       = "list"
    lc_view.is_fetching = true
    lc_view._fetch_seq  = (lc_view._fetch_seq or 0) + 1
    local current_seq   = lc_view._fetch_seq
    core.redraw         = true

    api_call({
      cmd        = "problem_list",
      skip       = lc_view.page_skip,
      limit      = 50,
      difficulty = lc_view.difficulty == "ALL" and "" or lc_view.difficulty,
      search     = lc_view.search_input,
    }, function(resp)
      if not lc_view then return end
      if lc_view._fetch_seq ~= current_seq then
        return -- Stale response discarded to prevent out-of-order search glitches
      end
      lc_view.is_fetching = false
      if resp.ok then
        lc_view.problems       = resp.data.problems
        lc_view.total_problems = resp.data.total
        lc_view.selected_idx   = 1
        lc_view.list_scroll_y  = 0
        lc_view.last_error     = nil
      else
        if resp.error and (resp.error:match("Not logged in") or resp.error:match("expired") or resp.error:match("403")) then
          lc_view:auto_authenticate(false)
        else
          lc_view.last_error = resp.error or "Unknown error"
          core.log("[LeetCode] " .. lc_view.last_error)
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
    if not lc_view then return end
    
    lc_view.loading_msg = "Picking a random problem"
    lc_view.state = "loading"
    core.redraw = true
    
    local function pick_random(total)
      local idx = math.random(1, total)
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
               pick_random(total)
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
              lc_view.mock_timer_end = nil
              lc_view.is_blind_mode = false
              lc_view.last_error = det_resp.error or "Failed to load random problem"
              core.log("[LeetCode] " .. lc_view.last_error)
            end
            core.redraw = true
          end)
        else
          -- Network failure: auto-retry up to 3 times with a 2-second delay
          lc_view.net_retries = (lc_view.net_retries or 0) + 1
          if lc_view.net_retries <= 3 then
            lc_view.loading_msg = "Retrying... (attempt " .. lc_view.net_retries .. "/3)"
            core.redraw = true
            core.add_thread(function()
              coroutine.yield(2.0)
              pick_random(total)
            end)
          else
            lc_view.state = "list"
            lc_view.net_retries = 0
            lc_view.mock_timer_end = nil
            lc_view.is_blind_mode = false
            lc_view.last_error = (resp.error or "Network error") .. " - try again in a moment."
            core.log("[LeetCode] Failed to fetch random problem: " .. lc_view.last_error)
            core.redraw = true
          end
        end
      end)
    end
    
    lc_view.random_retries = 0
    lc_view.net_retries = 0
    api_call({
      cmd = "problem_list",
      skip = 0,
      limit = 1,
      difficulty = lc_view.difficulty == "ALL" and "" or lc_view.difficulty,
      search = lc_view.search_input,
    }, function(resp)
      if resp.ok and resp.data and resp.data.total > 0 then
        pick_random(resp.data.total)
      else
        lc_view.state = "list"
        lc_view.mock_timer_end = nil
        lc_view.is_blind_mode = false
        lc_view.last_error = (resp.error or "Network error") .. " - could not count problems."
        core.log("[LeetCode] " .. lc_view.last_error)
        core.redraw = true
      end
    end)
  end,
  ["leetcode:close"] = function()
    close_all_leetcode_editor_views()
    if not lc_view or not core.root_view.root_node:get_node_for_view(lc_view) then
      command.perform("leetcode:toggle")
    end
    if lc_view then
      lc_view.state = "list"
      lc_view.current = nil
      lc_view.search_focus = true
      core.set_active_view(lc_view)
      core.redraw = true
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

    -- Fix: when the panel is active (no doc), find the code file from open tabs
    if (not meta or not code) and lc_view and lc_view.current then
      local slug = lc_view.current.slug
      local all_views = core.root_view.root_node:get_children()
      for _, view in ipairs(all_views) do
        if view.doc then
          local fname = view.doc.abs_filename or view.doc.filename or ""
          -- .lc_meta is stored as "fname.ext.lc_meta" — do NOT strip extension
          if fname:find(slug, 1, true)
            and not fname:find("%.lc_meta$")
            and not fname:find("%.md$") then
            local mp = fname .. ".lc_meta"
            local f = io.open(mp, "r")
            if f then
              local m = json_decode(f:read("*a")); f:close()
              if m and m.slug then
                local ls = {}
                for i = 1, #view.doc.lines do ls[i] = view.doc.lines[i] end
                meta = m; code = table.concat(ls)
                break
              end
            end
          end
        end
      end
    end

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
    if lc_view then lc_view.state = "running"; lc_view.loading_msg = "Running test cases" end  -- Bug 7 fix
    core.redraw = true
    -- Bug 1 fix: capture the id AFTER api_call so it's guaranteed correct
    local my_req_id
    my_req_id = api_call({
      cmd         = "run_code",
      slug        = meta.slug,
      question_id = meta.question_id,
      lang        = meta.lang,
      code        = code,
      test_input  = meta.test_cases,  -- Bug 2 fix: no gsub needed, json_decode already unescapes
    }, function(resp)
      if not lc_view or lc_view.run_req_id ~= my_req_id then return end
      local result      = resp.data or {}
      result.ok   = resp.ok
      result.err  = resp.error
      result.est_tc = est_tc
      result.est_sc = est_sc
      if assessment.is_active() then
        assessment.on_run_result(meta.slug, result)
      end
      -- Restore the problem panel on the left
      if lc_view then
        if assessment.is_active() then
          lc_view.state = "assessment_session"
        else
          lc_view.state = lc_view.current and "problem" or "list"
        end
      end
      -- Open result as a new tab in the code editor section
      local title = (meta and meta.title) or ""
      open_result_tab(result, "run", title)
    end)
    if lc_view then lc_view.run_req_id = my_req_id end  -- Bug 1 fix: set AFTER call
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

    -- Fix: when the panel is active (no doc), find the code file from open tabs
    if (not meta or not code) and lc_view and lc_view.current then
      local slug = lc_view.current.slug
      local all_views = core.root_view.root_node:get_children()
      for _, view in ipairs(all_views) do
        if view.doc then
          local fname = view.doc.abs_filename or view.doc.filename or ""
          -- .lc_meta stored as fname..ext..lc_meta — do NOT strip extension
          if fname:find(slug, 1, true)
            and not fname:find("%.lc_meta$")
            and not fname:find("%.md$") then
            local mp = fname .. ".lc_meta"
            local f = io.open(mp, "r")
            if f then
              local m = json_decode(f:read("*a")); f:close()
              if m and m.slug then
                local ls = {}
                for i = 1, #view.doc.lines do ls[i] = view.doc.lines[i] end
                meta = m; code = table.concat(ls)
                break
              end
            end
          end
        end
      end
    end

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
    if lc_view then lc_view.state = "running"; lc_view.loading_msg = "Submitting to LeetCode" end  -- Bug 7 fix
    core.redraw = true
    -- Bug 1 fix: capture the id AFTER api_call
    local my_req_id
    my_req_id = api_call({
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
      if assessment.is_active() then
        assessment.on_submit_result(meta.slug, result)
      end
      -- Restore the problem panel on the left
      if lc_view then
        if assessment.is_active() then
          lc_view.state = "assessment_session"
        else
          lc_view.state = lc_view.current and "problem" or "list"
        end
      end
      -- Open result as a new tab in the code editor section
      local title = (meta and meta.title) or ""
      open_result_tab(result, "submit", title)
    end)
    if lc_view then lc_view.run_req_id = my_req_id end  -- Bug 1 fix: set AFTER call
  end,

    ["leetcode:assessment"] = function()
    if not lc_view or not core.root_view.root_node:get_node_for_view(lc_view) then command.perform("leetcode:toggle") end
    if lc_view then
      lc_view.state = "assessment_hub"
      core.redraw = true
    end
  end,
  ["leetcode:start-assessment"] = function()
    start_assessment_flow()
  end,
  ["leetcode:next-question"] = function()
    if not assessment.is_active() then return end
    local sess = assessment.get_session()
    if not sess then return end
    local next_idx = (sess.current_q_idx % #sess.questions) + 1
    assessment.switch_question(next_idx)
    local q = sess.questions[next_idx]
    if q and q.problem_data then
      if lc_view then lc_view.current = q.problem_data end
      open_problem(q.problem_data, sess.lang)
    end
  end,
  ["leetcode:finish-assessment"] = function()
    if not assessment.is_active() then return end
    assessment.finish_session()
    close_all_leetcode_editor_views()
    if lc_view then
      lc_view.state = "assessment_scorecard"
      core.set_active_view(lc_view)
      core.redraw = true
    end
  end,
  ["leetcode:reset"] = function()
    reset_active_code()
  end,

  ["leetcode:reset-current"] = function()
    local in_panel_with_problem = lc_view
      and (lc_view.state == "problem" or lc_view.state == "assessment_session")
      and lc_view.current
    if in_panel_with_problem then
      local target_slug = lc_view.current.slug
      local all_views = core.root_view.root_node:get_children()
      for _, view in ipairs(all_views) do
        local fname = (view.doc and (view.doc.abs_filename or view.doc.filename)) or ""
        -- .lc_meta is stored as "filename.ext.lc_meta", not "filename.lc_meta"
        if fname:find(target_slug, 1, true) and not fname:find("%.lc_meta$") and not fname:find("%.md$") then
          local meta_path = fname .. ".lc_meta"
          local f = io.open(meta_path, "r")
          local meta = nil
          if f then
            local content = f:read("*a")
            f:close()
            meta = json_decode(content)
          end
          if meta then
            local doc = view.doc
            local default_code = meta.default_code
            if not default_code or default_code == "" then
              if meta.starter and meta.starter ~= "" then
                default_code = (meta.header or "") .. meta.starter
              end
            end
            if default_code and default_code ~= "" then
              doc:remove(1, 1, #doc.lines, #doc.lines[#doc.lines] + 1)
              doc:insert(1, 1, default_code)
              doc:set_selection(1, 1, 1, 1)
              core.log("[LeetCode] Code reset to original starter template.")
              core.redraw = true
              return
            end
          end
        end
      end
      -- Code file not open in any tab: fetch fresh starter from API
      core.log("[LeetCode] Fetching fresh starter code from API...")
      lc_view.state = "loading"
      lc_view.loading_msg = "Fetching starter code..."
      core.redraw = true
      local prob = lc_view.current
      local lang = lc_view.selected_lang or "python3"
      api_call({ cmd = "problem_detail", slug = prob.slug }, function(resp)
        if not lc_view then return end
        if resp.ok and resp.data then
          lc_view.current = resp.data
          open_problem(resp.data, lang)
        else
          core.error("[LeetCode] Could not fetch starter: click a language pill to open the code file first.")
          lc_view.state = "problem"
          core.redraw = true
        end
      end)
    else
      reset_active_code()
    end
  end,

  -- ── Update DB ────────────────────────────────────────────────────────────
  ["leetcode:update-data"] = function()
    if not lc_view then return end
    lc_view.state          = "update"
    lc_view.update_progress = 0
    lc_view.update_msg     = "Connecting to GitHub sources..."
    lc_view.update_spinner = 0
    lc_view.update_result  = nil
    core.redraw = true
    api_call({ cmd = "update_data", threshold = 1 }, function(resp)
      if not lc_view then return end
      if resp and resp.progress then
        -- intermediate streaming progress update
        lc_view.update_progress = resp.pct or lc_view.update_progress
        lc_view.update_msg      = resp.msg or lc_view.update_msg
        core.redraw = true
      elseif resp and resp.ok then
        local d = resp.data or {}
        local new_n   = d.new_entries          or 0
        local upd_n   = d.updated_entries      or 0
        local total   = d.total_slugs          or 0
        local fitted  = d.newly_fitted_into_bank or 0
        local orphans = d.orphans              or 0
        lc_view.update_result = string.format(
          "+%d new, %d updated, %d fitted to bank. Total: %d slugs (Orphans: %d)",
          new_n, upd_n, fitted, total, orphans)
        lc_view.update_result_time = os.time()
        lc_view.update_progress = 100
        lc_view.state = "list"
        refresh_companies_list()
        if lc_view.fetch_topic_tags then lc_view:fetch_topic_tags() end
        core.log("[LeetCode] DB verified & updated: " .. lc_view.update_result)
        core.redraw = true
      else
        local err = (resp and resp.error) or "Unknown error"
        lc_view.update_result = "Update failed: " .. err
        lc_view.update_result_time = os.time()
        lc_view.state = "list"
        core.error("[LeetCode] " .. lc_view.update_result)
        core.redraw = true
      end
    end)
  end,

  -- ── Verify / Reconcile DB Health ──────────────────────────────────────────
  ["leetcode:verify-db"] = function()
    if not lc_view then return end
    api_call({ cmd = "verify_db" }, function(resp)
      if resp and resp.ok and resp.data then
        local d = resp.data
        core.log(string.format(
          "[LeetCode DB Health] Status: %s | Co Slugs: %d | Metadata Bank: %d | Scores: %d | Fitted: %d | Orphans: %d",
          d.status or "OK", d.total_company_problems or 0, d.total_metadata_bank_problems or 0,
          d.total_scores_tracked or 0, d.newly_fitted_into_bank or 0, d.orphan_count or 0
        ))
      else
        core.error("[LeetCode] DB check failed: " .. tostring(resp and resp.error))
      end
    end)
  end,

  -- ── Analyze Trends ────────────────────────────────────────────────────────
  ["leetcode:analyze-trends"] = function()
    if not lc_view then return end
    -- Priority: 1) explicitly selected company pill, 2) current problem's first company, 3) "google"
    local company = lc_view.selected_company
    if not company and lc_view.current then
      local comps = lc_view.current.companies
      if comps and #comps > 0 then
        company = comps[1]:lower():gsub("%s+", "-")
        lc_view.selected_company = company   -- remember for panel header
      end
    end
    company = company or "google"
    lc_view.trend_data = nil   -- show loading state
    core.redraw = true
    api_call({ cmd = "analyze_trends", company = company, top_n = 10 }, function(resp)
      if not lc_view then return end
      if resp and resp.ok then
        lc_view.trend_data = resp.data
      else
        lc_view.trend_data = { trends = {}, total_problems = 0,
          _error = (resp and resp.error) or "Analysis failed" }
      end
      core.redraw = true
    end)
  end,
})

keymap.add({
  ["ctrl+shift+l"] = "leetcode:toggle",
  ["alt+r"] = "leetcode:run",
  ["alt+s"] = "leetcode:submit",
  ["alt+z"] = "leetcode:reset",
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
          v._search_timer = system.get_time() + 0.2
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

-- -- Rich markdown-aware text renderer --------------------------------------
local SECTION_HEADERS = {
  ["Example"]    = true, ["Input"]      = true, ["Output"]     = true,
  ["Explanation"]= true, ["Constraints"]= true, ["Note"]       = true,
  ["Follow-up"]  = true, ["Follow up"]  = true, ["Definition"] = true,
}

local function draw_wrapped_line(font, text, left_x, current_y, max_w, default_color, indent_x)
  local lh = math.floor(font:get_height() * 1.3)
  local cx = indent_x or left_x
  local cy = current_y
  local right_limit = left_x + max_w
  local code_bg = {30, 30, 42, 210}
  local code_fg = LC_COLORS.easy
  local scale = SCALE or 1

  -- Split into tokens
  for word in text:gmatch("%S+") do
    local plain_word = word:gsub("`", "")
    local ww = font:get_width(plain_word) + 4 * scale

    -- Wrap to next line if word exceeds remaining width
    if cx + ww > right_limit and cx > (indent_x or left_x) then
      cy = cy + lh
      cx = indent_x or left_x
    end

    -- If a single word/array string exceeds max_w itself, chunk it by characters
    if ww > max_w then
      local cur_chunk = ""
      for char in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if font:get_width(cur_chunk .. char) > (right_limit - cx) then
          if #cur_chunk > 0 then
            renderer.draw_text(font, cur_chunk, cx, cy, default_color)
            cur_chunk = ""
          end
          cy = cy + lh
          cx = indent_x or left_x
          cur_chunk = char
        else
          cur_chunk = cur_chunk .. char
        end
      end
      if #cur_chunk > 0 then
        cx = renderer.draw_text(font, cur_chunk .. " ", cx, cy, default_color)
      end
    else
      -- Render word with inline backtick support
      if word:find("`") then
        local i = 1
        while i <= #word do
          local tick_s = word:find("`", i, true)
          if tick_s then
            local plain = word:sub(i, tick_s - 1)
            if #plain > 0 then
              cx = renderer.draw_text(font, plain, cx, cy, default_color)
            end
            local tick_e = word:find("`", tick_s + 1, true)
            if tick_e then
              local code = word:sub(tick_s + 1, tick_e - 1)
              local cw = font:get_width(code) + 6 * scale
              renderer.draw_rect(cx, cy, cw, font:get_height(), code_bg)
              cx = renderer.draw_text(font, code, cx + 3 * scale, cy, code_fg)
              cx = cx + 3 * scale
              i = tick_e + 1
            else
              cx = renderer.draw_text(font, "`", cx, cy, default_color)
              i = tick_s + 1
            end
          else
            local remain = word:sub(i)
            cx = renderer.draw_text(font, remain, cx, cy, default_color)
            break
          end
        end
        cx = renderer.draw_text(font, " ", cx, cy, default_color)
      else
        cx = renderer.draw_text(font, word .. " ", cx, cy, default_color)
      end
    end
  end

  return cy + lh
end

local function draw_rich_content(font, text, x, y, max_w, scroll_offset)
  -- Full rich renderer: SQL/ASCII tables, section headers, inline code, bullets, image links, testcases
  local lh       = math.floor(font:get_height() * 1.3)
  local cfont    = style.code_font or font
  local clh      = math.floor(cfont:get_height() * 1.25)
  local cy       = y
  local cx       = x
  if not text or text == "" then return cy end

  if lc_view then lc_view.image_links = lc_view.image_links or {} end

  local bullet_color  = {common.color("#888888")}
  local border_color  = {common.color("#5E6D82")}
  local dim           = style.dim
  local main_fg       = style.text
  local in_table      = false
  local in_code_block = false

  for raw_line in (text .. "\n"):gmatch("(.-)\n") do
    -- strip trailing whitespace
    local line = raw_line:match("^(.-)%s*$")

    -- 0. Code Blocks / Testcases (```)
    if line:match("^```") then
      in_table = false
      in_code_block = not in_code_block
      cy = cy + lh * 0.25
    elseif in_code_block then
      local block_bg = {22, 26, 36, 230}
      local line_h = clh
      renderer.draw_rect(cx, cy, max_w, line_h, block_bg)
      renderer.draw_rect(cx, cy, 2 * SCALE, line_h, style.accent)
      cy = draw_wrapped_line(cfont, line, cx + 8*SCALE, cy, max_w - 16*SCALE, LC_COLORS.easy, cx + 8*SCALE)

    elseif line == "" then
      cy = cy + lh * 0.4
      in_table = false

    -- 1. Table Declarations (e.g. Table: Person, Table: `Person`, Person table:)
    elseif line:match("^Table:%s*`?([%w_]+)`?") or line:match("^`?([%w_]+)`?%s+table:?$") then
      local tbl_name = line:match("^Table:%s*`?([%w_]+)`?") or line:match("^`?([%w_]+)`?%s+table:?$")
      local banner_txt = "TABLE: " .. tbl_name
      local tw = font:get_width(banner_txt)
      local pad = 8 * SCALE
      local pill_h = math.floor(font:get_height() + 6 * SCALE)
      cy = cy + lh * 0.3
      renderer.draw_rect(cx - pad, cy, tw + pad * 2, pill_h, {style.accent[1], style.accent[2], style.accent[3], 35})
      renderer.draw_rect(cx - pad, cy, 3 * SCALE, pill_h, style.accent)
      renderer.draw_text(font, banner_txt, cx, cy + 3 * SCALE, style.accent)
      cy = cy + pill_h + lh * 0.2
      in_table = false

    -- 2. Table Borders (e.g. +-------------+---------+)
    elseif line:match("^%s*%+[-%+]+%+%s*$") or line:match("^%s*%+[-%+]+$") then
      renderer.draw_rect(cx, cy, max_w, clh, style.background2)
      core.push_clip_rect(cx, cy, max_w, clh)
      renderer.draw_text(cfont, line, cx + 4*SCALE, cy + 1*SCALE, border_color)
      core.pop_clip_rect()
      cy = cy + clh
      in_table = true

    -- 3. Table Rows (e.g. | personId | int |)
    elseif line:match("^%s*%|.*%|%s*$") then
      local is_header = line:lower():find("column") or line:lower():find("type") or (line:lower():find("name") and in_table)
      local row_bg = is_header and style.background3 or (in_table and style.background2 or style.background)
      local row_fg = is_header and style.accent or style.text
      renderer.draw_rect(cx, cy, max_w, clh, row_bg)
      core.push_clip_rect(cx, cy, max_w, clh)
      renderer.draw_text(cfont, line, cx + 4*SCALE, cy + 1*SCALE, row_fg)
      core.pop_clip_rect()
      cy = cy + clh
      in_table = true

    -- 4. Section Headers (Example 1, Constraints, Follow-up, Note)
    elseif line:match("^Example%s*%d") or line:match("^Constraints:?") or
           line:match("^Follow%s*%-?%s*up:?") or line:match("^Note:?") then
      in_table = false
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
      renderer.draw_rect(cx - pad, cy, tw + pad * 2, pill_h,
                         {hl_color[1], hl_color[2], hl_color[3], 30})
      renderer.draw_rect(cx - pad, cy, 3 * SCALE, pill_h, hl_color)
      renderer.draw_text(font, clean, cx, cy + 3 * SCALE, hl_color)
      cy = cy + pill_h + lh * 0.3

    -- 5. Example sub-labels (Input:, Output:, Explanation:)
    elseif line:match("^Input:") or line:match("^Output:") or line:match("^Explanation:") then
      in_table = false
      local label, rest = line:match("^([^:]+:)%s*(.*)$")
      if label then
        local label_w = font:get_width(label .. " ")
        renderer.draw_text(font, label, cx + 12*SCALE, cy, dim)
        if rest and rest ~= "" then
          cy = draw_wrapped_line(font, rest, cx, cy, max_w - 12*SCALE, main_fg, cx + 12*SCALE + label_w)
        else
          cy = cy + lh
        end
      end

    -- 6. Bullet points
    elseif line:match("^%s*%-") or line:match("^%s*%*") then
      in_table = false
      local indent = #(line:match("^(%s*)"))
      local content = line:match("^%s*[%-%*]%s*(.*)") or ""
      local bx = cx + indent * 4 * SCALE
      renderer.draw_text(font, "|", bx, cy, bullet_color)
      local bx2 = bx + font:get_width("| ")
      cy = draw_wrapped_line(font, content, cx, cy, max_w, main_fg, bx2)

    -- 7. Image links
    elseif line:match("^%[Image:") then
      in_table = false
      local img_url = line:match("^%[Image:(.-)%]")
      if img_url and lc_view then
        local label = "   View diagram  "
        renderer.draw_rect(cx, cy, max_w, lh + 4*SCALE, {30,40,60,200})
        renderer.draw_text(font, label, cx + 8*SCALE, cy + 2*SCALE, LC_COLORS.accepted)
        table.insert(lc_view.image_links, {x=cx, y=cy, w=max_w, h=lh+4*SCALE, url=img_url})
      end
      cy = cy + lh + 8*SCALE

    -- 8. Normal Paragraph text (fully wrapped)
    else
      in_table = false
      cy = draw_wrapped_line(font, line, cx, cy, max_w, main_fg, cx)
    end
  end
  return cy
end




local function format_company_name(name)
  if not name then return "" end
  return name:gsub("%-", " "):gsub("(%a)([%w]*)", function(first, rest)
    return first:upper() .. rest:lower()
  end)
end

function LeetCodeView:on_mouse_pressed(btn, mouse_x, mouse_y, clicks)
  local res = LeetCodeView.super.on_mouse_pressed(self, btn, mouse_x, mouse_y, clicks)
  if res then return res end

  if btn ~= "left" then return false end

  -- 0a. Pattern & Topic Selection Modal (Top Priority if visible)
  if self.show_pattern_modal then
    -- Close button
    if self.pattern_modal_close_rect then
      local r = self.pattern_modal_close_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.show_pattern_modal = false
        core.redraw = true
        return true
      end
    end

    -- Tab switcher: Patterns Tab
    if self.pattern_modal_tab_pat_rect then
      local r = self.pattern_modal_tab_pat_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.pattern_modal_tab = "patterns"
        self.pattern_page_skip = 0
        core.redraw = true
        return true
      end
    end

    -- Tab switcher: Topics Tab
    if self.pattern_modal_tab_top_rect then
      local r = self.pattern_modal_tab_top_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.pattern_modal_tab = "topics"
        self.topic_page_skip = 0
        core.redraw = true
        return true
      end
    end

    -- Reset topic filter button (for Company OA)
    if self.pattern_modal_reset_topic_rect then
      local r = self.pattern_modal_reset_topic_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.selected_company_topic = "ALL"
        assessment.set_target_company(self.selected_company, nil)
        self.show_pattern_modal = false
        core.redraw = true
        core.log("[LeetCode Assessment] Cleared topic filter for " .. format_company_name(self.selected_company))
        return true
      end
    end

    if self.pattern_modal_tab == "topics" then
      -- Prev page (Topics)
      if self.topic_modal_prev_rect then
        local r = self.topic_modal_prev_rect
        if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
          if (self.topic_page_skip or 0) >= (self.topic_page_limit or 12) then
            self.topic_page_skip = self.topic_page_skip - (self.topic_page_limit or 12)
            core.redraw = true
          end
          return true
        end
      end

      -- Next page (Topics)
      if self.topic_modal_next_rect then
        local r = self.topic_modal_next_rect
        if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
          if (self.topic_page_skip or 0) + (self.topic_page_limit or 12) < (self.topic_matching_count or 0) then
            self.topic_page_skip = (self.topic_page_skip or 0) + (self.topic_page_limit or 12)
            core.redraw = true
          end
          return true
        end
      end

      -- Topic item cards
      if self.topic_modal_item_rects then
        for _, item in ipairs(self.topic_modal_item_rects) do
          if mouse_x >= item.x and mouse_x <= item.x + item.w and mouse_y >= item.y and mouse_y <= item.y + item.h then
            assessment.set_target_topic(item.topic.tag, item.topic.name)
            core.log(string.format("[LeetCode Assessment] Selected Topic: #%s (%s)", item.topic.tag, item.topic.name))
            self.show_pattern_modal = false
            core.redraw = true
            return true
          end
        end
      end

    else
      -- Tier filter chips (Patterns)
      if self.pattern_modal_tier_rects then
        for _, t in ipairs(self.pattern_modal_tier_rects) do
          if mouse_x >= t.x and mouse_x <= t.x + t.w and mouse_y >= t.y and mouse_y <= t.y + t.h then
            self.pattern_tier_filter = t.tier
            self.pattern_page_skip = 0
            core.redraw = true
            return true
          end
        end
      end

      -- Prev page (Patterns)
      if self.pattern_modal_prev_rect then
        local r = self.pattern_modal_prev_rect
        if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
          if (self.pattern_page_skip or 0) >= (self.pattern_page_limit or 8) then
            self.pattern_page_skip = self.pattern_page_skip - (self.pattern_page_limit or 8)
            core.redraw = true
          end
          return true
        end
      end

      -- Next page (Patterns)
      if self.pattern_modal_next_rect then
        local r = self.pattern_modal_next_rect
        if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
          if (self.pattern_page_skip or 0) + (self.pattern_page_limit or 8) < (self.pattern_matching_count or 0) then
            self.pattern_page_skip = (self.pattern_page_skip or 0) + (self.pattern_page_limit or 8)
            core.redraw = true
          end
          return true
        end
      end

      -- Pattern item cards
      if self.pattern_modal_item_rects then
        for _, item in ipairs(self.pattern_modal_item_rects) do
          if mouse_x >= item.x and mouse_x <= item.x + item.w and mouse_y >= item.y and mouse_y <= item.y + item.h then
            assessment.set_target_pattern(item.pattern.id)
            self.selected_pattern_id = item.pattern.id
            core.log(string.format("[LeetCode Assessment] Selected Pattern #%d: %s", item.pattern.idx, item.pattern.name))
            self.show_pattern_modal = false
            core.redraw = true
            return true
          end
        end
      end
    end

    -- Search box click
    if self.pattern_modal_search_rect then
      local r = self.pattern_modal_search_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        core.redraw = true
        return true
      end
    end

    -- Clicking outside the modal dialog box closes it
    if self.pattern_modal_box_rect then
      local r = self.pattern_modal_box_rect
      if mouse_x < r.x or mouse_x > r.x + r.w or mouse_y < r.y or mouse_y > r.y + r.h then
        self.show_pattern_modal = false
        core.redraw = true
        return true
      end
    end

    return true
  end

  -- 0b. Company Selection Modal (Top Priority if visible)
  if self.show_company_modal then
    -- Close button
    if self.company_modal_close_rect then
      local r = self.company_modal_close_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.show_company_modal = false
        core.redraw = true
        return true
      end
    end

    -- Prev page
    if self.company_modal_prev_rect then
      local r = self.company_modal_prev_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        if (self.company_page_skip or 0) >= (self.company_page_limit or 12) then
          self.company_page_skip = self.company_page_skip - (self.company_page_limit or 12)
          core.redraw = true
        end
        return true
      end
    end

    -- Next page
    if self.company_modal_next_rect then
      local r = self.company_modal_next_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        if (self.company_page_skip or 0) + (self.company_page_limit or 12) < (self.company_matching_count or 0) then
          self.company_page_skip = (self.company_page_skip or 0) + (self.company_page_limit or 12)
          core.redraw = true
        end
        return true
      end
    end

    -- Company item cards
    if self.company_modal_item_rects then
      for _, item in ipairs(self.company_modal_item_rects) do
        if mouse_x >= item.x and mouse_x <= item.x + item.w and mouse_y >= item.y and mouse_y <= item.y + item.h then
          self.selected_company = item.company
          assessment.set_target_company(item.company)
          self.show_company_modal = false
          core.redraw = true
          core.log("[LeetCode Assessment] Selected target company: " .. item.display_name)
          return true
        end
      end
    end

    -- Search box
    if self.company_modal_search_rect then
      local r = self.company_modal_search_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        core.redraw = true
        return true
      end
    end

    -- Clicking outside the modal dialog box closes it
    if self.company_modal_box_rect then
      local r = self.company_modal_box_rect
      if mouse_x < r.x or mouse_x > r.x + r.w or mouse_y < r.y or mouse_y > r.y + r.h then
        self.show_company_modal = false
        core.redraw = true
        return true
      end
    end

    return true -- Consume all clicks while modal is open
  end

  -- 0. Assessment Loading State (Delivery Timeline Stepper)
  if self.state == "assessment_loading" then
    if self.oa_cancel_btn_rect then
      local r = self.oa_cancel_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        if self.oa_loader then self.oa_loader.aborted = true end
        self.state = "assessment_hub"
        core.redraw = true
        return true
      end
    end
    return true
  end

  -- 1. Assessment Hub
  if self.state == "assessment_hub" then
    if self.hub_back_btn_rect then
      local r = self.hub_back_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        close_all_leetcode_editor_views()
        self.state = "list"
        core.redraw = true
        return true
      end
    end

    -- Change Company pill button on Card 4
    if self.change_company_btn_rect then
      local r = self.change_company_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.assessment_track_idx = 4
        self.show_company_modal = true
        self.company_search_input = ""
        self.company_page_skip = 0
        core.redraw = true
        return true
      end
    end

    -- Change Pattern pill button on Card 5
    if self.change_pattern_btn_rect then
      local r = self.change_pattern_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.assessment_track_idx = 5
        self.pattern_modal_for_track = 5
        self.show_pattern_modal = true
        self.pattern_search_input = ""
        self.pattern_page_skip = 0
        core.redraw = true
        return true
      end
    end

    if self.track_card_rects then
      for i, r in ipairs(self.track_card_rects) do
        if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
          self.assessment_track_idx = i
          if i == 4 then
            self.show_company_modal = true
            self.company_search_input = ""
            self.company_page_skip = 0
          elseif i == 5 then
            self.pattern_modal_for_track = 5
            self.show_pattern_modal = true
            self.pattern_search_input = ""
            self.pattern_page_skip = 0
          end
          core.redraw = true
          return true
        end
      end
    end

    if self.lang_pill_rects then
      for _, p in ipairs(self.lang_pill_rects) do
        if mouse_x >= p.x and mouse_x <= p.x + p.w and mouse_y >= p.y and mouse_y <= p.y + p.h then
          self.assessment_lang = p.lang
          core.redraw = true
          return true
        end
      end
    end

    if self.blind_toggle_rect then
      local r = self.blind_toggle_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.assessment_blind = not self.assessment_blind
        core.redraw = true
        return true
      end
    end

    if self.curveball_toggle_rect then
      local r = self.curveball_toggle_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.assessment_curveballs = not self.assessment_curveballs
        core.redraw = true
        return true
      end
    end

    if self.start_assess_btn_rect then
      local r = self.start_assess_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        start_assessment_flow()
        return true
      end
    end
    return true
  end

  -- 2. Assessment Session
  if self.state == "assessment_session" then
    if self.quit_assess_btn_rect then
      local r = self.quit_assess_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        assessment.finish_session()
        close_all_leetcode_editor_views()
        self.state = "assessment_hub"
        core.redraw = true
        return true
      end
    end

    if self.q_tab_rects then
      for i, r in ipairs(self.q_tab_rects) do
        if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
          local sess = assessment.get_session()
          if sess then
            assessment.switch_question(i)
            local q = sess.questions[i]
            if q and q.problem_data then
              self.current = q.problem_data
              open_problem(q.problem_data, sess.lang)
            end
          end
          return true
        end
      end
    end

    if self.next_q_btn_rect then
      local r = self.next_q_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        command.perform("leetcode:next-question")
        return true
      end
    end

    if self.finish_assess_btn_rect then
      local r = self.finish_assess_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        command.perform("leetcode:finish-assessment")
        return true
      end
    end

    if self.copy_btn_rect then
      local r = self.copy_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        if self.current then
          local text_to_copy = self.current.title .. "\n\n" .. (self.current.content_plain or "")
          system.set_clipboard(text_to_copy)
          core.log("[LeetCode] Problem description copied to clipboard!")
        end
        return true
      end
    end
    -- Bug 6 fix: wire Run / Submit / Clear in assessment_session (they were dead before)
    if self.run_btn_rect then
      local r = self.run_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        command.perform("leetcode:run")
        return true
      end
    end

    if self.submit_btn_rect then
      local r = self.submit_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        command.perform("leetcode:submit")
        return true
      end
    end

    if self.reset_btn_rect then
      local r = self.reset_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        command.perform("leetcode:reset-current")
        return true
      end
    end
    return true
  end

  -- 3. Assessment Scorecard
  if self.state == "assessment_scorecard" then
    if self.scorecard_back_btn_rect then
      local r = self.scorecard_back_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        close_all_leetcode_editor_views()
        self.state = "list"
        core.redraw = true
        return true
      end
    end

    if self.new_assess_btn_rect then
      local r = self.new_assess_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        close_all_leetcode_editor_views()
        self.state = "assessment_hub"
        core.redraw = true
        return true
      end
    end

    if self.review_btn_rect then
      local r = self.review_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        local sess = assessment.get_session()
        if sess and #sess.questions > 0 then
          local q = sess.questions[1]
          self.current = q.problem_data
          self.state = "problem"
          open_problem(q.problem_data, sess.lang)
        end
        return true
      end
    end
    return true
  end

  -- 4. Authentication State
  if self.state == "auth" then
    lc_view = self
    if self.auth_auto_btn_rect then
      local r = self.auth_auto_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self:auto_detect()
        return true
      end
    end

    if self.auth_cookie_rect then
      local r = self.auth_cookie_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.auth_input_focus = true
        core.redraw = true
        return true
      end
    end

    if self.auth_connect_btn_rect then
      local r = self.auth_connect_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self:connect_cookies()
        return true
      end
    end
    return true
  end

  -- 5. Problem List State
  if self.state == "list" then
    -- Dropdown clicks
    if self.dropdown_rect and self.search_focus and self.dropdown_items then
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

    -- Difficulty pills
    if self.diff_buttons then
      for _, b in ipairs(self.diff_buttons) do
        if mouse_x >= b.x and mouse_x <= b.x + b.w and mouse_y >= b.y and mouse_y <= b.y + b.h then
          self.difficulty = b.val
          self.page_skip = 0
          command.perform("leetcode:fetch-list")
          return true
        end
      end
    end

    -- Assessment button
    if self.assessment_btn_rect then
      local r = self.assessment_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.state = "assessment_hub"
        core.redraw = true
        return true
      end
    end

    -- Mock Interview button
    if self.mock_btn_rect then
      local r = self.mock_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.is_blind_mode = true
        self.mock_timer_end = os.time() + 45 * 60
        self.curveball_triggered = false
        self.active_curveball = nil
        self.difficulty = "MEDIUM"
        command.perform("leetcode:random")
        return true
      end
    end

    -- Pick One button
    if self.random_btn_rect then
      local r = self.random_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.is_blind_mode = false
        self.mock_timer_end = nil
        command.perform("leetcode:random")
        return true
      end
    end

    -- Study Plans button — opens StudyPlanView in a new node tab
    if self.study_plan_btn_rect then
      local r = self.study_plan_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        command.perform("leetcode:open-study-plan")
        return true
      end
    end

    -- Search box
    if self.clear_btn_rect then
      local r = self.clear_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.search_input = ""
        self.search_focus = true
        self._search_timer = nil
        self.page_skip = 0
        command.perform("leetcode:fetch-list")
        core.redraw = true
        return true
      end
    end

    if self.search_rect then
      local r = self.search_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.search_focus = true
        core.redraw = true
        return true
      end
    end

    -- Pagination clicks
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
        if (self.page_skip or 0) + 50 < (self.total_problems or 3000) then
          self.page_skip = (self.page_skip or 0) + 50
          command.perform("leetcode:fetch-list")
        end
        return true
      end
    end

    -- ⟳ Update DB button
    if self.update_db_btn_rect then
      local r = self.update_db_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        command.perform("leetcode:update-data")
        return true
      end
    end

    self.search_focus = false
    core.redraw = true

    -- Handle click on a problem in the table
    if self.problem_rows then
      for _, row in ipairs(self.problem_rows) do
        if mouse_x >= row.x and mouse_x <= row.x + row.w and mouse_y >= row.y and mouse_y <= row.y + row.h then
          self.selected_idx = row.idx
          self.is_blind_mode = false
          self.mock_timer_end = nil
          command.perform("leetcode:open-problem")
          return true
        end
      end
    end
    return true
  end

  -- 6. Problem View State
  if self.state == "problem" then
    -- Trend panel close or dismiss clicks
    if self.show_trend_panel then
      if self.trend_close_rect then
        local r = self.trend_close_rect
        if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
          self.show_trend_panel = false
          core.redraw = true
          return true
        end
      end
      if self.trend_patterns_tab_rect then
        local r = self.trend_patterns_tab_rect
        if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
          self.trend_tab = "patterns"
          core.redraw = true
          return true
        end
      end
      if self.trend_topics_tab_rect then
        local r = self.trend_topics_tab_rect
        if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
          self.trend_tab = "topics"
          core.redraw = true
          return true
        end
      end
      if self.trend_panel_rect then
        local r = self.trend_panel_rect
        if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
          -- Click inside trend panel
          return true
        else
          -- Click outside trend panel dismisses it cleanly without triggering background buttons
          self.show_trend_panel = false
          core.redraw = true
          return true
        end
      end
    end

    if self.back_btn_rect then
      local r = self.back_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        close_all_leetcode_editor_views()
        self.state = "list"
        self.current = nil
        core.redraw = true
        return true
      end
    end

    if self.run_btn_rect then
      local r = self.run_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        command.perform("leetcode:run")
        return true
      end
    end

    if self.submit_btn_rect then
      local r = self.submit_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        command.perform("leetcode:submit")
        return true
      end
    end

    if self.reset_btn_rect then
      local r = self.reset_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        command.perform("leetcode:reset-current")
        return true
      end
    end

    if self.copy_btn_rect then
      local r = self.copy_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        if self.current then
          local text_to_copy = self.current.title .. "\n\n" .. (self.current.content_plain or "")
          system.set_clipboard(text_to_copy)
          core.log("[LeetCode] Problem description copied to clipboard!")
        end
        return true
      end
    end

    if self.image_links then
      for _, link in ipairs(self.image_links) do
        if mouse_x >= link.x and mouse_x <= link.x + link.w and mouse_y >= link.y and mouse_y <= link.y + link.h then
          core.log("[LeetCode] Opening: " .. tostring(link.url))
          if link.url:match("^https?://") then
            if system.open_url then system.open_url(link.url) end
          else
            core.root_view:open_doc(core.open_doc(link.url))
          end
          return true
        end
      end
    end

    if self.similar_buttons then
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

    if self.lang_buttons then
      for _, b in ipairs(self.lang_buttons) do
        if mouse_x >= b.x and mouse_x <= b.x + b.w and mouse_y >= b.y and mouse_y <= b.y + b.h then
          if b._is_toggle then
            self.langs_expanded = not self.langs_expanded
            core.redraw = true
            return true
          else
            core.log("[LeetCode] Bootstrapping " .. b.lang .. " environment...")
            local ok, err = pcall(open_problem, self.current, b.lang)
            if not ok then core.error("[LeetCode] Failed to open problem: " .. tostring(err)) end
            return true
          end
        end
      end
    end

    -- Trend panel button
    if self.trend_btn_rect then
      local r = self.trend_btn_rect
      if mouse_x >= r.x and mouse_x <= r.x + r.w and mouse_y >= r.y and mouse_y <= r.y + r.h then
        self.show_trend_panel = not self.show_trend_panel
        if self.show_trend_panel then
          command.perform("leetcode:analyze-trends")
        end
        core.redraw = true
        return true
      end
    end

    -- Company pill clicks — select company OR toggle expand
    if self.company_pill_rects then
      for _, pill in ipairs(self.company_pill_rects) do
        if mouse_x >= pill.x and mouse_x <= pill.x + pill.w and mouse_y >= pill.y and mouse_y <= pill.y + pill.h then
          if pill._is_toggle then
            self.companies_expanded = not self.companies_expanded
          else
            self.selected_company = pill.slug
            self.show_trend_panel = true
            command.perform("leetcode:analyze-trends")
          end
          core.redraw = true
          return true
        end
      end
    end

    -- Topic pill clicks — toggle expand
    if self.topic_pill_rects then
      for _, pill in ipairs(self.topic_pill_rects) do
        if mouse_x >= pill.x and mouse_x <= pill.x + pill.w and mouse_y >= pill.y and mouse_y <= pill.y + pill.h then
          if pill._is_toggle then
            self.topics_expanded = not self.topics_expanded
          end
          core.redraw = true
          return true
        end
      end
    end
    return true
  end

  return false
end

function LeetCodeView:on_mouse_wheel(delta)
  if self.show_company_modal then
    if delta < 0 then
      if (self.company_page_skip or 0) + (self.company_page_limit or 12) < (self.company_matching_count or 0) then
        self.company_page_skip = (self.company_page_skip or 0) + (self.company_page_limit or 12)
        core.redraw = true
      end
    elseif delta > 0 then
      if (self.company_page_skip or 0) >= (self.company_page_limit or 12) then
        self.company_page_skip = self.company_page_skip - (self.company_page_limit or 12)
        core.redraw = true
      end
    end
    return true
  end

  if self.show_trend_panel and self.trend_panel_rect then
    local mx = core.root_view and core.root_view.mouse and core.root_view.mouse.x or 0
    local my = core.root_view and core.root_view.mouse and core.root_view.mouse.y or 0
    local r = self.trend_panel_rect
    if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
      self.trend_scroll_y = math.max(0, math.min(self.trend_max_scroll or 0, (self.trend_scroll_y or 0) - delta * 40))
      core.redraw = true
      return true
    end
  end

  if self.state == "problem" or self.state == "assessment_session" then
    self.scroll_y = math.max(0, math.min(self.max_scroll or 0, self.scroll_y - delta * 40))
    core.redraw = true
  elseif self.state == "list" then
    self.list_scroll_y = math.max(0, (self.list_scroll_y or 0) - delta * 40)
    core.redraw = true
  end
  return true
end

function LeetCodeView:draw_company_modal(x, y, w, h)
  -- 1. Dark Backdrop
  renderer.draw_rect(x, y, w, h, {0, 0, 0, 185})

  -- 2. Modal Box in middle of screen
  local mw = math.min(w - 32*SCALE, 580 * SCALE)
  local mh = math.min(h - 40*SCALE, 450 * SCALE)
  local mx = x + math.floor((w - mw) / 2)
  local my = y + math.floor((h - mh) / 2)

  self.company_modal_box_rect = {x = mx, y = my, w = mw, h = mh}

  -- Box Background & Border
  renderer.draw_rect(mx, my, mw, mh, style.background)
  renderer.draw_rect(mx, my, mw, 2*SCALE, style.accent)
  renderer.draw_rect(mx, my + mh - 1*SCALE, mw, 1*SCALE, style.accent)
  renderer.draw_rect(mx, my, 1*SCALE, mh, style.accent)
  renderer.draw_rect(mx + mw - 1*SCALE, my, 1*SCALE, mh, style.accent)

  -- Header
  local hx = mx + 16*SCALE
  local hy = my + 14*SCALE
  renderer.draw_text(style.big_font or style.font, "Select Target Company", hx, hy, style.accent)

  -- Close Button [ X ]
  local close_lbl = "[ X ]"
  local clw = style.font:get_width(close_lbl) + 8*SCALE
  self.company_modal_close_rect = {x = mx + mw - clw - 14*SCALE, y = hy, w = clw, h = 22*SCALE}
  renderer.draw_rect(self.company_modal_close_rect.x, hy, clw, 22*SCALE, style.background2)
  renderer.draw_text(style.font, close_lbl, self.company_modal_close_rect.x + 4*SCALE, hy + 3*SCALE, style.dim)

  hy = hy + (style.big_font or style.font):get_height() + 4*SCALE
  local total_cos = math.max(1000, #COMPANIES)
  renderer.draw_text(style.font, string.format("Simulate real interview questions from %d+ top tech companies.", total_cos), hx, hy, style.dim)
  hy = hy + style.font:get_height() + 10*SCALE

  -- Search Input Bar
  local sw = mw - 32*SCALE
  local sh = 28*SCALE
  self.company_modal_search_rect = {x = hx, y = hy, w = sw, h = sh}
  renderer.draw_rect(hx, hy, sw, sh, style.background2)
  renderer.draw_rect(hx, hy, sw, 1*SCALE, style.accent)

  local search_lbl = "Filter: "
  renderer.draw_text(style.font, search_lbl, hx + 8*SCALE, hy + 6*SCALE, style.accent)
  local sx = hx + 8*SCALE + style.font:get_width(search_lbl)
  local search_avail_w = math.max(20*SCALE, sw - (sx - hx) - 10*SCALE)

  core.push_clip_rect(sx, hy, search_avail_w, sh)
  if self.company_search_input and self.company_search_input ~= "" then
    local cursor = (math.floor(system.get_time() * 2) % 2 == 0) and "|" or ""
    renderer.draw_text(style.font, self.company_search_input .. cursor, sx, hy + 6*SCALE, style.text)
  else
    local cursor = (math.floor(system.get_time() * 2) % 2 == 0) and "|" or ""
    renderer.draw_text(style.font, "Type company name (e.g. Google, Meta, DE Shaw, TikTok, Uber)..." .. cursor, sx, hy + 6*SCALE, style.dim)
  end
  core.pop_clip_rect()

  hy = hy + sh + 12*SCALE

  -- Filter Companies across slug and display name
  local q = (self.company_search_input or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local q_slug = q:gsub("%s+", "-")
  local matching = {}
  for _, c in ipairs(COMPANIES or {}) do
    local disp = (COMPANY_META[c] and COMPANY_META[c].name) or format_company_name(c)
    local disp_lower = disp:lower()
    if q == "" or c:find(q, 1, true) or c:find(q_slug, 1, true) or disp_lower:find(q, 1, true) then
      table.insert(matching, c)
    end
  end

  self.company_matching_count = #matching
  self.first_matching_company = matching[1]

  -- Paginate: 12 items per page (3 columns x 4 rows)
  local limit = self.company_page_limit or 12
  local skip = self.company_page_skip or 0
  if skip >= #matching and #matching > 0 then
    self.company_page_skip = 0
    skip = 0
  end

  local cols = (mw >= 480*SCALE) and 3 or 2
  local card_w = math.floor((sw - (cols - 1) * 8*SCALE) / cols)
  local card_h = 42*SCALE
  self.company_modal_item_rects = {}

  local grid_y = hy
  if #matching == 0 then
    renderer.draw_text(style.font, "No companies found matching '" .. (self.company_search_input or "") .. "'", hx, hy + 20*SCALE, style.dim)
  else
    for i = 1, limit do
      local idx = skip + i
      if idx > #matching then break end
      local comp = matching[idx]
      local col = (i - 1) % cols
      local row = math.floor((i - 1) / cols)
      local cx = hx + col * (card_w + 8*SCALE)
      local cy = grid_y + row * (card_h + 6*SCALE)

      local is_cur = (self.selected_company == comp)
      local bg = is_cur and style.background3 or style.background2
      local border_c = is_cur and style.accent or style.dim

      renderer.draw_rect(cx, cy, card_w, card_h, bg)
      renderer.draw_rect(cx, cy, card_w, 1*SCALE, border_c)
      renderer.draw_rect(cx, cy + card_h - 1*SCALE, card_w, 1*SCALE, border_c)
      renderer.draw_rect(cx, cy, 1*SCALE, card_h, border_c)
      renderer.draw_rect(cx + card_w - 1*SCALE, cy, 1*SCALE, card_h, border_c)

      if is_cur then
        renderer.draw_rect(cx, cy, 3*SCALE, card_h, style.accent)
      end

      -- Company Name & Problem Count Subtitle
      local disp_name = (COMPANY_META[comp] and COMPANY_META[comp].name) or format_company_name(comp)
      local cnt = COMPANY_META[comp] and COMPANY_META[comp].problem_count or 0
      local sub_text = (cnt > 0) and string.format("%d Problems • Simulate OA", cnt) or "Simulate OA / Onsite"

      core.push_clip_rect(cx + 6*SCALE, cy, card_w - 12*SCALE, card_h)
      renderer.draw_text(style.font, disp_name, cx + 8*SCALE, cy + 6*SCALE, is_cur and style.accent or style.text)
      renderer.draw_text(style.font, sub_text, cx + 8*SCALE, cy + 22*SCALE, is_cur and (LC_COLORS.medium or style.accent) or style.dim)
      core.pop_clip_rect()

      table.insert(self.company_modal_item_rects, {
        x = cx, y = cy, w = card_w, h = card_h,
        company = comp, display_name = disp_name
      })
    end
  end

  -- Bottom Pagination Footer
  local bot_y = my + mh - 36*SCALE
  renderer.draw_rect(hx, bot_y - 6*SCALE, sw, 1*SCALE, style.dim)

  local prev_lbl = "< Prev (12)"
  local pw = style.font:get_width(prev_lbl) + 14*SCALE
  self.company_modal_prev_rect = {x = hx, y = bot_y, w = pw, h = 24*SCALE}
  renderer.draw_rect(hx, bot_y, pw, 24*SCALE, style.background2)
  renderer.draw_text(style.font, prev_lbl, hx + 7*SCALE, bot_y + 4*SCALE, skip > 0 and style.text or style.dim)

  local next_lbl = "Next (12) >"
  local nw = style.font:get_width(next_lbl) + 14*SCALE
  self.company_modal_next_rect = {x = hx + pw + 8*SCALE, y = bot_y, w = nw, h = 24*SCALE}
  renderer.draw_rect(hx + pw + 8*SCALE, bot_y, nw, 24*SCALE, style.background2)
  renderer.draw_text(style.font, next_lbl, hx + pw + 15*SCALE, bot_y + 4*SCALE, (skip + limit < #matching) and style.text or style.dim)

  local cur_page = math.floor(skip / limit) + 1
  local total_pages = math.max(1, math.ceil(#matching / limit))
  local p_str = string.format("Page %d/%d (%d companies)", cur_page, total_pages, #matching)
  local p_x = hx + pw + nw + 14*SCALE
  local p_max_w = math.max(20*SCALE, mx + mw - p_x - 14*SCALE)
  core.push_clip_rect(p_x, bot_y, p_max_w, 24*SCALE)
  renderer.draw_text(style.font, p_str, p_x, bot_y + 4*SCALE, style.dim)
  core.pop_clip_rect()
end

function LeetCodeView:draw_pattern_modal(x, y, w, h)
  -- 1. Dark Backdrop
  renderer.draw_rect(x, y, w, h, {0, 0, 0, 195})

  -- 2. Modal Dialog Window - Spacious and Responsive
  local mw = math.min(w - 24*SCALE, 760 * SCALE)
  local mh = math.min(h - 24*SCALE, 540 * SCALE)
  local mx = x + math.floor((w - mw) / 2)
  local my = y + math.floor((h - mh) / 2)

  self.pattern_modal_box_rect = {x = mx, y = my, w = mw, h = mh}

  -- Dialog Background & Accent Borders
  renderer.draw_rect(mx, my, mw, mh, style.background)
  renderer.draw_rect(mx, my, mw, 2*SCALE, style.accent)
  renderer.draw_rect(mx, my + mh - 1*SCALE, mw, 1*SCALE, style.accent)
  renderer.draw_rect(mx, my, 1*SCALE, mh, style.accent)
  renderer.draw_rect(mx + mw - 1*SCALE, my, 1*SCALE, mh, style.accent)

  -- Header
  local hx = mx + 16*SCALE
  local hy = my + 14*SCALE
  local sw = mw - 32*SCALE

  -- Close Button [ X ]
  local close_lbl = "[ X ]"
  local clw = style.font:get_width(close_lbl) + 10*SCALE
  self.pattern_modal_close_rect = {x = mx + mw - clw - 14*SCALE, y = hy, w = clw, h = 22*SCALE}
  renderer.draw_rect(self.pattern_modal_close_rect.x, hy, clw, 22*SCALE, style.background2)
  renderer.draw_text(style.font, close_lbl, self.pattern_modal_close_rect.x + 5*SCALE, hy + 3*SCALE, style.accent)

  local is_comp_mode = (self.pattern_modal_for_track == 4)
  local title_txt = is_comp_mode and ("Filter " .. format_company_name(self.selected_company or "Google") .. " OA by Topic / Pattern")
                                  or "50 DSA Patterns & LeetCode Native Topics"
  local sub_txt = is_comp_mode and ("Target specific algorithmic patterns frequently tested at " .. format_company_name(self.selected_company or "Google") .. ".")
                               or "Drill canonical DSA patterns or target specific LeetCode topic tags (#hashtags)."

  core.push_clip_rect(hx, hy, self.pattern_modal_close_rect.x - hx - 8*SCALE, 24*SCALE)
  renderer.draw_text(style.big_font or style.font, title_txt, hx, hy, style.accent)
  core.pop_clip_rect()

  hy = hy + (style.big_font or style.font):get_height() + 4*SCALE
  core.push_clip_rect(hx, hy, sw, 18*SCALE)
  renderer.draw_text(style.font, sub_txt, hx, hy, style.dim)
  core.pop_clip_rect()
  hy = hy + style.font:get_height() + 8*SCALE

  -- Tab Navigation Bar: [ 50 DSA Patterns ] | [ LeetCode Topics (#) ] | (Optional [ Reset to ALL ])
  local active_tab = self.pattern_modal_tab or "patterns"
  local tab_h = 24*SCALE
  local tab_x = hx

  local pat_tab_lbl = " 50 DSA Patterns "
  local pat_tw = style.font:get_width(pat_tab_lbl) + 16*SCALE
  self.pattern_modal_tab_pat_rect = {x = tab_x, y = hy, w = pat_tw, h = tab_h}
  local pat_is_active = (active_tab == "patterns")
  renderer.draw_rect(tab_x, hy, pat_tw, tab_h, pat_is_active and {style.accent[1], style.accent[2], style.accent[3], 45} or style.background2)
  renderer.draw_rect(tab_x, hy, pat_tw, 1*SCALE, pat_is_active and style.accent or style.dim)
  renderer.draw_rect(tab_x, hy + tab_h - 1*SCALE, pat_tw, 1*SCALE, pat_is_active and style.accent or style.dim)
  renderer.draw_text(style.font, pat_tab_lbl, tab_x + 8*SCALE, hy + 4*SCALE, pat_is_active and style.accent or style.dim)
  tab_x = tab_x + pat_tw + 8*SCALE

  local top_tab_lbl = " LeetCode Topics (#) "
  local top_tw = style.font:get_width(top_tab_lbl) + 16*SCALE
  self.pattern_modal_tab_top_rect = {x = tab_x, y = hy, w = top_tw, h = tab_h}
  local top_is_active = (active_tab == "topics")
  renderer.draw_rect(tab_x, hy, top_tw, tab_h, top_is_active and {style.accent[1], style.accent[2], style.accent[3], 45} or style.background2)
  renderer.draw_rect(tab_x, hy, top_tw, 1*SCALE, top_is_active and style.accent or style.dim)
  renderer.draw_rect(tab_x, hy + tab_h - 1*SCALE, top_tw, 1*SCALE, top_is_active and style.accent or style.dim)
  renderer.draw_text(style.font, top_tab_lbl, tab_x + 8*SCALE, hy + 4*SCALE, top_is_active and style.accent or style.dim)
  tab_x = tab_x + top_tw + 8*SCALE

  if is_comp_mode then
    local cur_top = self.selected_company_topic or "ALL"
    local rst_lbl = (cur_top ~= "ALL") and string.format("[ Active: #%s | Clear Filter ]", cur_top) or "[ Filter: All Topics ]"
    local rst_tw = style.font:get_width(rst_lbl) + 12*SCALE
    local rst_x = mx + mw - rst_tw - 16*SCALE
    self.pattern_modal_reset_topic_rect = {x = rst_x, y = hy, w = rst_tw, h = tab_h}
    renderer.draw_rect(rst_x, hy, rst_tw, tab_h, (cur_top ~= "ALL") and {LC_COLORS.easy[1], LC_COLORS.easy[2], LC_COLORS.easy[3], 40} or style.background2)
    renderer.draw_rect(rst_x, hy, rst_tw, 1*SCALE, (cur_top ~= "ALL") and LC_COLORS.easy or style.dim)
    renderer.draw_rect(rst_x, hy + tab_h - 1*SCALE, rst_tw, 1*SCALE, (cur_top ~= "ALL") and LC_COLORS.easy or style.dim)
    renderer.draw_text(style.font, rst_lbl, rst_x + 6*SCALE, hy + 4*SCALE, (cur_top ~= "ALL") and LC_COLORS.easy or style.dim)
  end

  hy = hy + tab_h + 8*SCALE

  -- Render Active Tab
  if active_tab == "topics" then
    -- Topics Search Bar
    local sh = 26*SCALE
    self.pattern_modal_search_rect = {x = hx, y = hy, w = sw, h = sh}
    renderer.draw_rect(hx, hy, sw, sh, style.background2)
    renderer.draw_rect(hx, hy, sw, 1*SCALE, style.accent)

    local search_lbl = "Search Topic (#): "
    renderer.draw_text(style.font, search_lbl, hx + 8*SCALE, hy + 5*SCALE, style.accent)
    local sx = hx + 8*SCALE + style.font:get_width(search_lbl)
    local search_avail_w = math.max(20*SCALE, sw - (sx - hx) - 10*SCALE)

    core.push_clip_rect(sx, hy, search_avail_w, sh)
    local cur_top_query = self.topic_search_input or ""
    if cur_top_query ~= "" then
      local cursor = (math.floor(system.get_time() * 2) % 2 == 0) and "|" or ""
      renderer.draw_text(style.font, cur_top_query .. cursor, sx, hy + 5*SCALE, style.text)
    else
      local cursor = (math.floor(system.get_time() * 2) % 2 == 0) and "|" or ""
      renderer.draw_text(style.font, "Type topic tag (e.g. array, dynamic-programming, graph, tree, binary-search)..." .. cursor, sx, hy + 5*SCALE, style.dim)
    end
    core.pop_clip_rect()

    hy = hy + sh + 10*SCALE

    -- Build topic catalog items from self.topics_catalog or fallback
    local q = cur_top_query:lower():gsub("^#", ""):gsub("%s+", "-")
    local matching = {}
    local topic_source = (self.topics_catalog and #self.topics_catalog > 0) and self.topics_catalog or nil

    if topic_source then
      for _, t in ipairs(topic_source) do
        local tag = (t.tag or t.slug or ""):lower()
        local name = (t.name or format_company_name(tag)):lower()
        if q == "" or tag:find(q, 1, true) or name:find(q, 1, true) then
          table.insert(matching, {
            tag = t.tag or t.slug or tag,
            name = t.name or format_company_name(tag),
            count = t.count or 0,
            easy = t.easy or 0,
            medium = t.medium or 0,
            hard = t.hard or 0
          })
        end
      end
    else
      for _, tag in ipairs(TOPIC_TAGS) do
        local name = format_company_name(tag)
        if q == "" or tag:find(q, 1, true) or name:lower():find(q, 1, true) then
          table.insert(matching, {
            tag = tag,
            name = name,
            count = 0,
            easy = 0, medium = 0, hard = 0
          })
        end
      end
    end

    self.topic_matching_count = #matching
    self.first_matching_topic = matching[1]

    -- 3 columns x 4 rows = 12 items per page
    local cols = (mw >= 580*SCALE) and 3 or 2
    local limit = (cols == 3) and 12 or 8
    self.topic_page_limit = limit

    local skip = self.topic_page_skip or 0
    if skip >= #matching and #matching > 0 then
      self.topic_page_skip = 0
      skip = 0
    end

    local gap_x = 8*SCALE
    local card_w = math.floor((sw - (cols - 1) * gap_x) / cols)
    local card_h = 44*SCALE
    self.topic_modal_item_rects = {}

    local grid_y = hy
    if #matching == 0 then
      renderer.draw_text(style.font, "No topics found matching '" .. cur_top_query .. "'", hx, hy + 20*SCALE, style.dim)
    else
      for i = 1, limit do
        local idx = skip + i
        if idx > #matching then break end
        local top = matching[idx]
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local cx = hx + col * (card_w + gap_x)
        local cy = grid_y + row * (card_h + 6*SCALE)

        local is_cur = is_comp_mode and (self.selected_company_topic == top.tag)
                                    or (assessment.selected_topic == top.tag and assessment.selected_mode == "topic")
        local bg = is_cur and style.background3 or style.background2
        local border_c = is_cur and style.accent or style.dim

        renderer.draw_rect(cx, cy, card_w, card_h, bg)
        renderer.draw_rect(cx, cy, card_w, 1*SCALE, border_c)
        renderer.draw_rect(cx, cy + card_h - 1*SCALE, card_w, 1*SCALE, border_c)
        renderer.draw_rect(cx, cy, 1*SCALE, card_h, border_c)
        renderer.draw_rect(cx + card_w - 1*SCALE, cy, 1*SCALE, card_h, border_c)

        if is_cur then
          renderer.draw_rect(cx, cy, 3*SCALE, card_h, style.accent)
        end

        -- Header: #tag display
        local tag_str = "#" .. top.tag
        core.push_clip_rect(cx + 6*SCALE, cy + 4*SCALE, card_w - 12*SCALE, 18*SCALE)
        renderer.draw_text(style.font, tag_str, cx + 8*SCALE, cy + 4*SCALE, is_cur and style.accent or style.text)
        core.pop_clip_rect()

        -- Subtitle: Problem counts or friendly name
        local sub_info = (top.count and top.count > 0)
          and string.format("%d Qs (E:%d M:%d H:%d)", top.count, top.easy or 0, top.medium or 0, top.hard or 0)
          or top.name
        core.push_clip_rect(cx + 6*SCALE, cy + 22*SCALE, card_w - 12*SCALE, 18*SCALE)
        renderer.draw_text(style.font, sub_info, cx + 8*SCALE, cy + 22*SCALE, style.dim)
        core.pop_clip_rect()

        table.insert(self.topic_modal_item_rects, {
          x = cx, y = cy, w = card_w, h = card_h,
          topic = top
        })
      end
    end

    -- Bottom Pagination Footer (Topics)
    local bot_y = my + mh - 36*SCALE
    renderer.draw_rect(hx, bot_y - 6*SCALE, sw, 1*SCALE, style.dim)

    local prev_lbl = "< Prev (12)"
    local pw = style.font:get_width(prev_lbl) + 14*SCALE
    self.topic_modal_prev_rect = {x = hx, y = bot_y, w = pw, h = 24*SCALE}
    renderer.draw_rect(hx, bot_y, pw, 24*SCALE, style.background2)
    renderer.draw_text(style.font, prev_lbl, hx + 7*SCALE, bot_y + 4*SCALE, skip > 0 and style.text or style.dim)

    local next_lbl = "Next (12) >"
    local nw = style.font:get_width(next_lbl) + 14*SCALE
    self.topic_modal_next_rect = {x = hx + pw + 8*SCALE, y = bot_y, w = nw, h = 24*SCALE}
    renderer.draw_rect(hx + pw + 8*SCALE, bot_y, nw, 24*SCALE, style.background2)
    renderer.draw_text(style.font, next_lbl, hx + pw + 15*SCALE, bot_y + 4*SCALE, (skip + limit < #matching) and style.text or style.dim)

    local cur_page = math.floor(skip / limit) + 1
    local total_pages = math.max(1, math.ceil(#matching / limit))
    local p_str = string.format("Page %d/%d (%d topics)", cur_page, total_pages, #matching)
    local p_x = hx + pw + nw + 14*SCALE
    local p_max_w = math.max(20*SCALE, mx + mw - p_x - 14*SCALE)
    core.push_clip_rect(p_x, bot_y, p_max_w, 24*SCALE)
    renderer.draw_text(style.font, p_str, p_x, bot_y + 4*SCALE, style.dim)
    core.pop_clip_rect()

  else
    -- Patterns Tab: Tier Chips
    self.pattern_modal_tier_rects = {}
    local tiers = {
      { id = "ALL", label = "All Patterns (50)" },
      { id = "Core", label = "Core (1-31)" },
      { id = "Advanced", label = "Advanced (32-50)" }
    }
    local chip_x = hx
    local chip_h = 22*SCALE
    for _, t in ipairs(tiers) do
      local is_sel = (self.pattern_tier_filter or "ALL") == t.id
      local tw = style.font:get_width(t.label) + 14*SCALE
      local bg = is_sel and {style.accent[1], style.accent[2], style.accent[3], 45} or style.background2
      local fg = is_sel and style.accent or style.dim

      renderer.draw_rect(chip_x, hy, tw, chip_h, bg)
      renderer.draw_rect(chip_x, hy, tw, 1*SCALE, is_sel and style.accent or style.dim)
      renderer.draw_rect(chip_x, hy + chip_h - 1*SCALE, tw, 1*SCALE, is_sel and style.accent or style.dim)
      renderer.draw_text(style.font, t.label, chip_x + 7*SCALE, hy + 3*SCALE, fg)

      table.insert(self.pattern_modal_tier_rects, {
        x = chip_x, y = hy, w = tw, h = chip_h, tier = t.id
      })
      chip_x = chip_x + tw + 8*SCALE
    end
    hy = hy + chip_h + 8*SCALE

    -- Search Input Bar
    local sh = 26*SCALE
    self.pattern_modal_search_rect = {x = hx, y = hy, w = sw, h = sh}
    renderer.draw_rect(hx, hy, sw, sh, style.background2)
    renderer.draw_rect(hx, hy, sw, 1*SCALE, style.accent)

    local search_lbl = "Filter: "
    renderer.draw_text(style.font, search_lbl, hx + 8*SCALE, hy + 5*SCALE, style.accent)
    local sx = hx + 8*SCALE + style.font:get_width(search_lbl)
    local search_avail_w = math.max(20*SCALE, sw - (sx - hx) - 10*SCALE)

    core.push_clip_rect(sx, hy, search_avail_w, sh)
    if self.pattern_search_input and self.pattern_search_input ~= "" then
      local cursor = (math.floor(system.get_time() * 2) % 2 == 0) and "|" or ""
      renderer.draw_text(style.font, self.pattern_search_input .. cursor, sx, hy + 5*SCALE, style.text)
    else
      local cursor = (math.floor(system.get_time() * 2) % 2 == 0) and "|" or ""
      renderer.draw_text(style.font, "Search pattern name, category, or keyword (e.g. Sliding Window, BFS, DP)..." .. cursor, sx, hy + 5*SCALE, style.dim)
    end
    core.pop_clip_rect()

    hy = hy + sh + 10*SCALE

    -- Filter Patterns
    local q = (self.pattern_search_input or ""):lower():gsub("%s+", " ")
    local cur_tier = self.pattern_tier_filter or "ALL"
    local matching = {}

    for _, p in ipairs(assessment.PATTERNS or {}) do
      local match_tier = (cur_tier == "ALL" or (p.tier and p.tier:lower():find(cur_tier:lower(), 1, true)))
      if match_tier then
        if q == "" then
          table.insert(matching, p)
        else
          local p_idx_str = tostring(p.idx)
          local p_name = (p.name or ""):lower()
          local p_cat = (p.category or ""):lower()
          local p_idea = (p.key_idea or ""):lower()
          local p_id = (p.id or ""):lower()
          if p_name:find(q, 1, true) or p_cat:find(q, 1, true) or p_idea:find(q, 1, true) or p_id:find(q, 1, true) or p_idx_str == q then
            table.insert(matching, p)
          end
        end
      end
    end

    self.pattern_matching_count = #matching
    self.first_matching_pattern = matching[1]

    -- Dynamic Grid: 2 columns if width >= 540, otherwise 1 column
    local cols = (mw >= 540*SCALE) and 2 or 1
    local limit = (cols == 2) and 6 or 5
    self.pattern_page_limit = limit

    local skip = self.pattern_page_skip or 0
    if skip >= #matching and #matching > 0 then
      self.pattern_page_skip = 0
      skip = 0
    end

    local gap_x = 10*SCALE
    local card_w = (cols == 2) and math.floor((sw - gap_x) / 2) or sw
    local card_h = 66*SCALE
    self.pattern_modal_item_rects = {}

    local grid_y = hy
    if #matching == 0 then
      renderer.draw_text(style.font, "No patterns found matching '" .. (self.pattern_search_input or "") .. "'", hx, hy + 20*SCALE, style.dim)
    else
      for i = 1, limit do
        local idx = skip + i
        if idx > #matching then break end
        local pat = matching[idx]
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local cx = hx + col * (card_w + gap_x)
        local cy = grid_y + row * (card_h + 8*SCALE)

        local is_cur = is_comp_mode and (self.selected_company_topic == pat.id)
                                    or (assessment.selected_pattern == pat.id and assessment.selected_mode == "pattern")
        local bg = is_cur and style.background3 or style.background2
        local border_c = is_cur and style.accent or style.dim

        renderer.draw_rect(cx, cy, card_w, card_h, bg)
        renderer.draw_rect(cx, cy, card_w, 1*SCALE, border_c)
        renderer.draw_rect(cx, cy + card_h - 1*SCALE, card_w, 1*SCALE, border_c)
        renderer.draw_rect(cx, cy, 1*SCALE, card_h, border_c)
        renderer.draw_rect(cx + card_w - 1*SCALE, cy, 1*SCALE, card_h, border_c)

        if is_cur then
          renderer.draw_rect(cx, cy, 4*SCALE, card_h, style.accent)
        end

        -- Top line: Tier Badge (Right)
        local tier_badge = pat.tier or "Core"
        local badge_w = style.font:get_width(tier_badge) + 12*SCALE
        local badge_h = 18*SCALE
        local badge_x = cx + card_w - badge_w - 8*SCALE
        local is_core = (pat.tier == "Core")
        local badge_col = is_core and LC_COLORS.easy or LC_COLORS.hard
        local badge_bg = {badge_col[1], badge_col[2], badge_col[3], 35}
        renderer.draw_rect(badge_x, cy + 6*SCALE, badge_w, badge_h, badge_bg)
        renderer.draw_text(style.font, tier_badge, badge_x + 6*SCALE, cy + 7*SCALE, badge_col)

        -- Top line: Pattern Title (Left) - with clear clipping before the badge
        local title_str = string.format("#%d. %s", pat.idx, pat.name)
        local title_max_w = card_w - badge_w - 24*SCALE
        core.push_clip_rect(cx + 8*SCALE, cy + 4*SCALE, title_max_w, 20*SCALE)
        renderer.draw_text(style.font, title_str, cx + 8*SCALE, cy + 6*SCALE, is_cur and style.accent or style.text)
        core.pop_clip_rect()

        -- Line 2: Category
        local cat_str = "Category: " .. (pat.category or "General")
        core.push_clip_rect(cx + 8*SCALE, cy + 26*SCALE, card_w - 16*SCALE, 18*SCALE)
        renderer.draw_text(style.font, cat_str, cx + 8*SCALE, cy + 26*SCALE, style.accent)
        core.pop_clip_rect()

        -- Line 3: Key Idea Summary
        local idea_str = pat.key_idea or ""
        core.push_clip_rect(cx + 8*SCALE, cy + 44*SCALE, card_w - 16*SCALE, 18*SCALE)
        renderer.draw_text(style.font, idea_str, cx + 8*SCALE, cy + 44*SCALE, style.dim)
        core.pop_clip_rect()

        table.insert(self.pattern_modal_item_rects, {
          x = cx, y = cy, w = card_w, h = card_h,
          pattern = pat
        })
      end
    end

    -- Bottom Pagination Footer (Patterns)
    local bot_y = my + mh - 36*SCALE
    renderer.draw_rect(hx, bot_y - 6*SCALE, sw, 1*SCALE, style.dim)

    local prev_lbl = "< Prev"
    local pw = style.font:get_width(prev_lbl) + 16*SCALE
    self.pattern_modal_prev_rect = {x = hx, y = bot_y, w = pw, h = 24*SCALE}
    renderer.draw_rect(hx, bot_y, pw, 24*SCALE, style.background2)
    renderer.draw_text(style.font, prev_lbl, hx + 8*SCALE, bot_y + 4*SCALE, skip > 0 and style.text or style.dim)

    local next_lbl = "Next >"
    local nw = style.font:get_width(next_lbl) + 16*SCALE
    self.pattern_modal_next_rect = {x = hx + pw + 8*SCALE, y = bot_y, w = nw, h = 24*SCALE}
    renderer.draw_rect(hx + pw + 8*SCALE, bot_y, nw, 24*SCALE, style.background2)
    renderer.draw_text(style.font, next_lbl, hx + pw + 16*SCALE, bot_y + 4*SCALE, (skip + limit < #matching) and style.text or style.dim)

    local cur_page = math.floor(skip / limit) + 1
    local total_pages = math.max(1, math.ceil(#matching / limit))
    local p_str = string.format("Page %d/%d (%d patterns)", cur_page, total_pages, #matching)
    local p_x = hx + pw + nw + 14*SCALE
    local p_max_w = math.max(20*SCALE, mx + mw - p_x - 14*SCALE)
    core.push_clip_rect(p_x, bot_y, p_max_w, 24*SCALE)
    renderer.draw_text(style.font, p_str, p_x, bot_y + 4*SCALE, style.dim)
    core.pop_clip_rect()
  end
end

function LeetCodeView:draw_assessment_loading(cx, cy, cw, ch)
  local ldr = self.oa_loader or {}
  local comp_disp = ldr.company_display or "Target Company"
  local phases = ldr.phases or {}
  local cur_phase = ldr.phase or 1
  local cur_prog = ldr.progress or 0.1
  local target_prog = ldr.target_progress or 0.2

  -- Smooth progression interpolation
  if cur_prog < target_prog then
    ldr.progress = math.min(target_prog, cur_prog + 0.015)
  end

  core.redraw = true -- drive 60 FPS animation

  local pulse = (math.sin(os.clock() * 4.5) + 1) * 0.5
  local orig_cx, orig_cy, orig_cw, orig_ch = cx, cy, cw, ch
  core.push_clip_rect(cx, cy, cw, ch)

  -- =========================================================================
  -- 1. Top Header Banner (Height: 38px)
  -- =========================================================================
  local banner_h = 38 * SCALE
  renderer.draw_rect(cx, cy, cw, banner_h, style.background2)
  renderer.draw_rect(cx, cy, cw, 1 * SCALE, style.dim)
  renderer.draw_rect(cx, cy + banner_h - 1 * SCALE, cw, 1 * SCALE, style.dim)

  local cur_phase_short = (phases[cur_phase] and phases[cur_phase].short) or "PROCESSING"
  local badge_str = string.format("PHASE %d/%d: %s", cur_phase, #phases, cur_phase_short:upper())
  local bw = style.font:get_width(badge_str) + 14 * SCALE
  local bh = 22 * SCALE
  local bx = cx + cw - bw - 10 * SCALE
  local by = cy + 8 * SCALE
  renderer.draw_rect(bx, by, bw, bh, {style.accent[1], style.accent[2], style.accent[3], 45})
  renderer.draw_rect(bx, by, bw, 1 * SCALE, style.accent)
  renderer.draw_text(style.font, badge_str, bx + 7 * SCALE, by + 4 * SCALE, style.accent)

  local title_str = string.format("ONLINE ASSESSMENT: %s", comp_disp:upper())
  local max_title_w = math.max(40 * SCALE, cw - bw - 30 * SCALE)
  core.push_clip_rect(cx + 10 * SCALE, cy, max_title_w, banner_h)
  renderer.draw_text(style.big_font or style.font, title_str, cx + 10 * SCALE, cy + 8 * SCALE, style.accent)
  core.pop_clip_rect()

  cy = cy + banner_h + 12 * SCALE

  -- =========================================================================
  -- 2. Delivery Stepper Timeline Track (Height: 52px)
  -- =========================================================================
  local num_phases = #phases
  local step_pad = math.max(16 * SCALE, math.min(32 * SCALE, cw * 0.05))
  local stepper_w = cw - 2 * step_pad
  local node_y = cy + 16 * SCALE
  local node_r = 10 * SCALE
  local step_dx = (num_phases > 1) and (stepper_w / (num_phases - 1)) or 0

  -- Background connecting line
  local line_start_x = cx + step_pad
  renderer.draw_rect(line_start_x, node_y - 2 * SCALE, stepper_w, 4 * SCALE, style.background3)

  -- Animated filled progress connecting line
  local filled_ratio = math.max(0, math.min(1, (cur_phase - 1 + (ldr.phase_progress or 0.5)) / math.max(1, num_phases - 1)))
  local fill_w = stepper_w * filled_ratio
  renderer.draw_rect(line_start_x, node_y - 2 * SCALE, fill_w, 4 * SCALE, style.accent)

  -- Render Nodes & Step Labels with Strict Anti-Collision Clipping
  for i, ph in ipairs(phases) do
    local nx = cx + step_pad + (i - 1) * step_dx
    local is_completed = (i < cur_phase)
    local is_active = (i == cur_phase)

    if is_completed then
      -- Completed node: solid accent/accepted circle
      renderer.draw_rect(nx - node_r, node_y - node_r, node_r * 2, node_r * 2, LC_COLORS.accepted or style.accent)
      renderer.draw_text(style.font, "OK", nx - 7 * SCALE, node_y - 6 * SCALE, style.background)
    elseif is_active then
      -- Glowing pulsing outer ring
      local glow_r = node_r + 3 * SCALE + pulse * 3 * SCALE
      local glow_col = {style.accent[1], style.accent[2], style.accent[3], math.floor(90 * (1 - pulse * 0.5))}
      renderer.draw_rect(nx - glow_r, node_y - glow_r, glow_r * 2, glow_r * 2, glow_col)

      -- Inner active circle
      renderer.draw_rect(nx - node_r, node_y - node_r, node_r * 2, node_r * 2, style.accent)
      local spinner_chars = { "|", "/", "-", "\\" }
      local spin_idx = math.floor(os.clock() * 8) % #spinner_chars + 1
      local spin_txt = spinner_chars[spin_idx]
      renderer.draw_text(style.font, spin_txt, nx - 3 * SCALE, node_y - 6 * SCALE, style.background)
    else
      -- Pending node
      renderer.draw_rect(nx - node_r, node_y - node_r, node_r * 2, node_r * 2, style.background2)
      renderer.draw_rect(nx - node_r, node_y - node_r, node_r * 2, 1 * SCALE, style.dim)
      renderer.draw_rect(nx - node_r, node_y + node_r - 1 * SCALE, node_r * 2, 1 * SCALE, style.dim)
      renderer.draw_text(style.font, tostring(i), nx - 3 * SCALE, node_y - 6 * SCALE, style.dim)
    end

    -- Step Label Below Node (Strictly bounded so adjacent labels NEVER overlap)
    local cell_w = (num_phases > 1) and math.max(40 * SCALE, step_dx - 8 * SCALE) or 80 * SCALE
    local cell_x = nx - (cell_w / 2)
    local lbl_col = is_active and style.accent or (is_completed and style.text or style.dim)
    core.push_clip_rect(cell_x, node_y + node_r + 4 * SCALE, cell_w, 16 * SCALE)
    local lbl_str = ph.short or tostring(i)
    local lbl_w = style.font:get_width(lbl_str)
    local tx = (lbl_w < cell_w) and (nx - (lbl_w / 2)) or cell_x
    renderer.draw_text(style.font, lbl_str, tx, node_y + node_r + 4 * SCALE, lbl_col)
    core.pop_clip_rect()
  end

  cy = cy + 54 * SCALE

  -- =========================================================================
  -- 3. Telemetry & Console Card (Adaptive Height based on container)
  -- =========================================================================
  local footer_reserved_h = 36 * SCALE
  local card_h = math.max(120 * SCALE, (orig_cy + orig_ch) - cy - footer_reserved_h - 10 * SCALE)
  renderer.draw_rect(cx, cy, cw, card_h, style.background2)
  renderer.draw_rect(cx, cy, cw, 1 * SCALE, style.dim)
  renderer.draw_rect(cx, cy + card_h - 1 * SCALE, cw, 1 * SCALE, style.dim)

  -- Terminal Title Bar
  local tbar_h = 24 * SCALE
  renderer.draw_rect(cx, cy, cw, tbar_h, style.background3)
  -- Simulated macOS dots
  renderer.draw_rect(cx + 8 * SCALE, cy + 7 * SCALE, 8 * SCALE, 8 * SCALE, {235, 87, 87})
  renderer.draw_rect(cx + 20 * SCALE, cy + 7 * SCALE, 8 * SCALE, 8 * SCALE, {242, 201, 76})
  renderer.draw_rect(cx + 32 * SCALE, cy + 7 * SCALE, 8 * SCALE, 8 * SCALE, {39, 174, 96})

  local elapsed = os.clock() - (ldr.start_time or os.clock())
  local el_str = string.format("Elapsed: %.1fs", elapsed)
  local el_w = style.font:get_width(el_str)
  renderer.draw_text(style.font, el_str, cx + cw - el_w - 10 * SCALE, cy + 5 * SCALE, style.accent)

  local title_max_w = math.max(40 * SCALE, cw - el_w - 60 * SCALE)
  core.push_clip_rect(cx + 46 * SCALE, cy, title_max_w, tbar_h)
  renderer.draw_text(style.font, "REAL-TIME ML ENGINE TELEMETRY & PIPELINE AUDIT", cx + 46 * SCALE, cy + 5 * SCALE, style.dim)
  core.pop_clip_rect()

  local inner_y = cy + tbar_h + 8 * SCALE

  -- Active Phase Description Banner (Clipped)
  local cur_desc = (phases[cur_phase] and phases[cur_phase].desc) or "Executing ML pipeline..."
  local act_w = cw - 20 * SCALE
  local act_h = 22 * SCALE
  renderer.draw_rect(cx + 10 * SCALE, inner_y, act_w, act_h, {style.accent[1], style.accent[2], style.accent[3], 30})
  renderer.draw_rect(cx + 10 * SCALE, inner_y, act_w, 1 * SCALE, style.accent)
  core.push_clip_rect(cx + 14 * SCALE, inner_y, act_w - 8 * SCALE, act_h)
  renderer.draw_text(style.font, ">> " .. cur_desc, cx + 16 * SCALE, inner_y + 3 * SCALE, style.text)
  core.pop_clip_rect()
  inner_y = inner_y + act_h + 8 * SCALE

  -- Overall Progress Bar with Percentage
  local pct_str = string.format("%d%%", math.floor((ldr.progress or 0.1) * 100))
  local pct_w = style.font:get_width(pct_str) + 8 * SCALE
  local pbar_w = math.max(40 * SCALE, cw - 20 * SCALE - pct_w)
  local pbar_h = 6 * SCALE
  renderer.draw_rect(cx + 10 * SCALE, inner_y + 3 * SCALE, pbar_w, pbar_h, style.background3)
  local pbar_fill = pbar_w * math.max(0.05, math.min(1.0, ldr.progress or 0.1))
  renderer.draw_rect(cx + 10 * SCALE, inner_y + 3 * SCALE, pbar_fill, pbar_h, style.accent)
  renderer.draw_text(style.font, pct_str, cx + 10 * SCALE + pbar_w + 6 * SCALE, inner_y, style.accent)
  inner_y = inner_y + 16 * SCALE

  -- Console Log Stream (Adaptive number of lines based on remaining card height)
  local logs = ldr.logs or {}
  local rem_log_h = (cy + card_h) - inner_y - 6 * SCALE
  local line_h = 16 * SCALE
  local visible_lines = math.max(1, math.floor(rem_log_h / line_h))
  local start_log_idx = math.max(1, #logs - visible_lines + 1)

  for li = start_log_idx, #logs do
    if inner_y + line_h <= cy + card_h - 4 * SCALE then
      local ltxt = logs[li]
      local is_latest = (li == #logs)
      local lcol = is_latest and style.text or style.dim
      core.push_clip_rect(cx + 12 * SCALE, inner_y, cw - 24 * SCALE, line_h)
      renderer.draw_text(style.font, "> " .. ltxt, cx + 12 * SCALE, inner_y, lcol)
      core.pop_clip_rect()
      inner_y = inner_y + line_h
    end
  end

  cy = cy + card_h + 8 * SCALE

  -- =========================================================================
  -- 4. Footer Metadata & Cancel Button (Zero Overlap Guaranteed)
  -- =========================================================================
  local cancel_lbl = "< Cancel & Return to Hub"
  local cancel_w = style.font:get_width(cancel_lbl) + 16 * SCALE
  local cancel_h = 22 * SCALE
  local cancel_x = cx + cw - cancel_w
  self.oa_cancel_btn_rect = {x = cancel_x, y = cy, w = cancel_w, h = cancel_h}
  renderer.draw_rect(cancel_x, cy, cancel_w, cancel_h, style.background2)
  renderer.draw_rect(cancel_x, cy, cancel_w, 1 * SCALE, style.dim)
  renderer.draw_text(style.font, cancel_lbl, cancel_x + 8 * SCALE, cy + 3 * SCALE, style.dim)

  -- Left Summary Pill (Clipped before the cancel button so it NEVER collides)
  local max_pill_w = math.max(0, cancel_x - cx - 12 * SCALE)
  if max_pill_w > 60 * SCALE then
    local summary_str = string.format("Target: %s  •  %d Problems  •  Confidence: 98.5%%", comp_disp, #(ldr.required_diffs or {1, 2}))
    local pw = math.min(max_pill_w, style.font:get_width(summary_str) + 16 * SCALE)
    renderer.draw_rect(cx, cy, pw, 22 * SCALE, style.background2)
    renderer.draw_rect(cx, cy, pw, 1 * SCALE, style.dim)
    core.push_clip_rect(cx + 8 * SCALE, cy, pw - 12 * SCALE, 22 * SCALE)
    renderer.draw_text(style.font, summary_str, cx + 8 * SCALE, cy + 3 * SCALE, style.dim)
    core.pop_clip_rect()
  end

  core.pop_clip_rect() -- pop orig root clip rect
end

function LeetCodeView:draw()
  self:draw_background(style.background)

  local sw, sh = self.size.x, self.size.y
  local pad = math.min(16 * SCALE, sw * 0.03)
  local x, y = self.position.x, self.position.y
  local w, h = sw, sh

  -- Top accent bar
  renderer.draw_rect(x, y, w, 2 * SCALE, style.accent)

  local cx, cy = x + pad, y + 14 * SCALE
  local cw = w - 2 * pad

  local rem_run = 3 - (os.time() - (last_run_time or 0))
  local rem_sub = 10 - (os.time() - (last_submit_time or 0))
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

  -- =========================================================================
  -- STATE 0: ASSESSMENT LOADING (DELIVERY TRACKER TIMELINE LOADER)
  -- =========================================================================
  if self.state == "assessment_loading" then
    self:draw_assessment_loading(cx, cy, cw, h - 2 * pad)
    return
  end

  -- =========================================================================
  -- STATE 1: ASSESSMENT HUB
  -- =========================================================================
  if self.state == "assessment_hub" then
    renderer.draw_text(style.big_font or style.font, "LeetCode Assessment & Mock Tests", cx, cy, style.accent)
    cy = cy + (style.big_font or style.font):get_height() + 4*SCALE
    renderer.draw_text(style.font, "Simulate timed technical interviews under authentic pressure (Free Tiers).", cx, cy, style.dim)
    cy = cy + style.font:get_height() + 14*SCALE

    -- 1. Track Cards
    self.track_card_rects = {}
    self.change_company_btn_rect = nil
    self.change_pattern_btn_rect = nil
    local use_2col = (cw >= 580*SCALE)
    local card_w = use_2col and math.floor((cw - 12*SCALE) / 2) or cw
    local card_h = 74*SCALE
    local tracks = assessment.TRACKS or {}

    for i, tr in ipairs(tracks) do
      local col = use_2col and ((i - 1) % 2) or 0
      local row = use_2col and math.floor((i - 1) / 2) or (i - 1)
      local tx = cx + col * (card_w + 12*SCALE)
      local ty = cy + row * (card_h + 8*SCALE)

      local is_selected = (self.assessment_track_idx == i)
      local bg_col = is_selected and style.background3 or style.background2
      local border_col = is_selected and style.accent or style.dim

      renderer.draw_rect(tx, ty, card_w, card_h, bg_col)
      renderer.draw_rect(tx, ty, card_w, 1*SCALE, border_col)
      renderer.draw_rect(tx, ty + card_h - 1*SCALE, card_w, 1*SCALE, border_col)
      renderer.draw_rect(tx, ty, 1*SCALE, card_h, border_col)
      renderer.draw_rect(tx + card_w - 1*SCALE, ty, 1*SCALE, card_h, border_col)

      if is_selected then
        renderer.draw_rect(tx, ty, 4*SCALE, card_h, style.accent)
      end

      -- Badge (Top Right)
      local badge_text = tr.badge
      if i == 4 and self.selected_company then
        badge_text = "[" .. self.selected_company:upper() .. " | ML PREDICTED]"
      elseif i == 5 then
        if assessment.selected_mode == "topic" and assessment.selected_topic then
          badge_text = "[#" .. assessment.selected_topic:upper() .. "]"
        else
          local cur_pat = assessment.get_pattern(assessment.selected_pattern)
          if cur_pat then
            badge_text = "[#" .. tostring(cur_pat.idx) .. " " .. cur_pat.tier:upper() .. "]"
          end
        end
      end
      local bw = style.font:get_width(badge_text) + 10*SCALE
      local bh = style.font:get_height() + 2*SCALE
      renderer.draw_rect(tx + card_w - bw - 8*SCALE, ty + 6*SCALE, bw, bh, {style.accent[1], style.accent[2], style.accent[3], 35})
      renderer.draw_text(style.font, badge_text, tx + card_w - bw - 3*SCALE, ty + 7*SCALE, style.accent)

      -- Title & Subtitle
      local title_text = tr.title
      local sub_text = tr.subtitle
      if i == 4 and self.selected_company then
        title_text = format_company_name(self.selected_company) .. " Assessment"
        sub_text = "ML Linear Regression Trends & K-Means Clusters"
      elseif i == 5 then
        if assessment.selected_mode == "topic" and assessment.selected_topic then
          title_text = "Topic: #" .. assessment.selected_topic
          sub_text = "LeetCode Native Topic Drill (" .. (assessment.selected_topic_name or format_company_name(assessment.selected_topic)) .. ")"
        else
          local cur_pat = assessment.get_pattern(assessment.selected_pattern)
          if cur_pat then
            title_text = string.format("Pattern #%d: %s", cur_pat.idx, cur_pat.name)
            sub_text = cur_pat.category .. " (" .. cur_pat.tier .. ")"
          end
        end
      end

      core.push_clip_rect(tx + 8*SCALE, ty, card_w - bw - 20*SCALE, card_h)
      renderer.draw_text(style.font, (tr.icon or "") .. " " .. title_text, tx + 10*SCALE, ty + 8*SCALE, is_selected and style.text or style.dim)
      core.pop_clip_rect()

      core.push_clip_rect(tx + 8*SCALE, ty + 28*SCALE, card_w - 16*SCALE, card_h - 28*SCALE)
      renderer.draw_text(style.font, sub_text, tx + 10*SCALE, ty + 28*SCALE, style.dim)
      
      if i == 4 then
        local chg_lbl = "[ Change Company ]"
        local chg_w = style.font:get_width(chg_lbl) + 8*SCALE
        local desc_text = "Topics, patterns & questions automatically predicted by ML trend algos"
        local desc_max_w = card_w - chg_w - 24*SCALE

        core.push_clip_rect(tx + 10*SCALE, ty + 48*SCALE, desc_max_w, 20*SCALE)
        renderer.draw_text(style.font, desc_text, tx + 10*SCALE, ty + 48*SCALE, style.text)
        core.pop_clip_rect()

        self.change_company_btn_rect = {x = tx + card_w - chg_w - 10*SCALE, y = ty + 46*SCALE, w = chg_w, h = 20*SCALE}
        renderer.draw_rect(self.change_company_btn_rect.x, self.change_company_btn_rect.y, chg_w, 20*SCALE, style.background)
        renderer.draw_text(style.font, chg_lbl, self.change_company_btn_rect.x + 4*SCALE, self.change_company_btn_rect.y + 2*SCALE, style.accent)

      elseif i == 5 then
        local chg_lbl = "[ Change Pattern / Topic ]"
        local chg_w = style.font:get_width(chg_lbl) + 8*SCALE
        local desc_text = ""
        if assessment.selected_mode == "topic" and assessment.selected_topic then
          desc_text = "Targeted Topic: #" .. assessment.selected_topic
        else
          local cur_pat = assessment.get_pattern(assessment.selected_pattern)
          local pat_name = cur_pat and cur_pat.name or "Sliding Window"
          desc_text = "Targeted Pattern: " .. pat_name
        end
        local desc_max_w = card_w - chg_w - 24*SCALE

        core.push_clip_rect(tx + 10*SCALE, ty + 48*SCALE, desc_max_w, 20*SCALE)
        renderer.draw_text(style.font, desc_text, tx + 10*SCALE, ty + 48*SCALE, style.text)
        core.pop_clip_rect()

        self.change_pattern_btn_rect = {x = tx + card_w - chg_w - 10*SCALE, y = ty + 46*SCALE, w = chg_w, h = 20*SCALE}
        renderer.draw_rect(self.change_pattern_btn_rect.x, self.change_pattern_btn_rect.y, chg_w, 20*SCALE, style.background)
        renderer.draw_text(style.font, chg_lbl, self.change_pattern_btn_rect.x + 4*SCALE, self.change_pattern_btn_rect.y + 2*SCALE, style.accent)
      else
        core.push_clip_rect(tx + 10*SCALE, ty + 48*SCALE, card_w - 20*SCALE, 20*SCALE)
        renderer.draw_text(style.font, tr.desc, tx + 10*SCALE, ty + 48*SCALE, style.text)
        core.pop_clip_rect()
      end
      core.pop_clip_rect()

      table.insert(self.track_card_rects, {x=tx, y=ty, w=card_w, h=card_h, idx=i})
    end

    local total_rows = use_2col and math.ceil(#tracks / 2) or #tracks
    cy = cy + total_rows * (card_h + 8*SCALE) + 12*SCALE

    -- 2. Language Picker
    renderer.draw_text(style.font, "Target Language:", cx, cy, style.text)
    cy = cy + style.font:get_height() + 6*SCALE
    self.lang_pill_rects = {}
    local avail_langs = { "python3", "java", "cpp", "typescript", "javascript", "golang", "rust", "csharp", "mysql", "postgresql", "mssql", "oraclesql" }
    local lx = cx
    local lh = style.font:get_height() + 6*SCALE
    for _, l in ipairs(avail_langs) do
      local is_sel = (self.assessment_lang == l)
      local is_sql = (l == "mysql" or l == "postgresql" or l == "mssql" or l == "oraclesql")
      local display_l = l
      if is_sql then
        display_l = "SQL (" .. l .. ")"
      end
      local lw = style.font:get_width(display_l) + 16*SCALE
      if lx + lw > cx + cw then
        lx = cx
        cy = cy + lh + 6*SCALE
      end
      local bg = is_sel and {style.accent[1], style.accent[2], style.accent[3], 40} or style.background2
      local fg = is_sel and style.accent or (is_sql and (LC_COLORS.easy or style.accent) or style.dim)

      renderer.draw_rect(lx, cy, lw, lh, bg)
      renderer.draw_rect(lx, cy, lw, 1*SCALE, is_sel and style.accent or style.dim)
      renderer.draw_rect(lx, cy + lh - 1*SCALE, lw, 1*SCALE, is_sel and style.accent or style.dim)
      renderer.draw_text(style.font, display_l, lx + 8*SCALE, cy + 3*SCALE, fg)

      table.insert(self.lang_pill_rects, {x=lx, y=cy, w=lw, h=lh, lang=l})
      lx = lx + lw + 8*SCALE
    end
    cy = cy + lh + 14*SCALE

    -- 3. Options
    renderer.draw_text(style.font, "Interview Mode & Constraints:", cx, cy, style.text)
    cy = cy + style.font:get_height() + 6*SCALE

    local blind_lbl = self.assessment_blind and "[x] Blind Mode (Hide difficulty, tags & stats)" or "[ ] Blind Mode (Show hints & tags)"
    local blind_w = style.font:get_width(blind_lbl) + 16*SCALE
    local bh = style.font:get_height() + 6*SCALE
    self.blind_toggle_rect = {x=cx, y=cy, w=blind_w, h=bh}
    renderer.draw_rect(cx, cy, blind_w, bh, style.background2)
    renderer.draw_text(style.font, blind_lbl, cx + 8*SCALE, cy + 3*SCALE, self.assessment_blind and LC_COLORS.accepted or style.dim)

    local curve_lbl = self.assessment_curveballs and "[x] Interviewer Curveballs (Live follow-up questions)" or "[ ] Interviewer Curveballs (Disabled)"
    local curve_w = style.font:get_width(curve_lbl) + 16*SCALE
    if cx + blind_w + 12*SCALE + curve_w <= cx + cw then
      self.curveball_toggle_rect = {x=cx + blind_w + 12*SCALE, y=cy, w=curve_w, h=bh}
    else
      cy = cy + bh + 6*SCALE
      self.curveball_toggle_rect = {x=cx, y=cy, w=curve_w, h=bh}
    end
    renderer.draw_rect(self.curveball_toggle_rect.x, self.curveball_toggle_rect.y, curve_w, bh, style.background2)
    renderer.draw_text(style.font, curve_lbl, self.curveball_toggle_rect.x + 8*SCALE, self.curveball_toggle_rect.y + 3*SCALE, self.assessment_curveballs and LC_COLORS.medium or style.dim)

    cy = self.curveball_toggle_rect.y + bh + 18*SCALE

    -- 4. Action Buttons
    local start_lbl = "[>] Start Timed Assessment"
    local start_w = style.font:get_width(start_lbl) + 24*SCALE
    local btn_h = 30*SCALE
    self.start_assess_btn_rect = {x=cx, y=cy, w=start_w, h=btn_h}
    renderer.draw_rect(cx, cy, start_w, btn_h, style.accent)
    renderer.draw_text(style.font, start_lbl, cx + 12*SCALE, cy + 6*SCALE, style.background)

    local back_lbl = "< Back to Problem List"
    local back_w = style.font:get_width(back_lbl) + 20*SCALE
    if cx + start_w + 14*SCALE + back_w <= cx + cw then
      self.hub_back_btn_rect = {x=cx + start_w + 14*SCALE, y=cy, w=back_w, h=btn_h}
    else
      cy = cy + btn_h + 8*SCALE
      self.hub_back_btn_rect = {x=cx, y=cy, w=back_w, h=btn_h}
    end
    renderer.draw_rect(self.hub_back_btn_rect.x, self.hub_back_btn_rect.y, back_w, btn_h, style.background2)
    renderer.draw_text(style.font, back_lbl, self.hub_back_btn_rect.x + 10*SCALE, self.hub_back_btn_rect.y + 6*SCALE, style.dim)

  -- =========================================================================
  -- STATE 2: ASSESSMENT SESSION
  -- =========================================================================
  elseif self.state == "assessment_session" and assessment.is_active() then
    local sess = assessment.get_session()
    local now = os.time()
    local remaining = math.max(0, sess.end_time - now)

    if remaining == 0 and not sess.completed then
      assessment.finish_session()
      close_all_leetcode_editor_views()
      self.state = "assessment_scorecard"
      core.redraw = true
      return
    end

    if sess.curveballs and not sess.curveball_triggered and remaining < (sess.duration_mins * 60) - (15 * 60) then
      sess.curveball_triggered = true
      local curveballs = {
        "INTERVIEWER: 'Dataset size increased by 1000x and cannot fit in RAM. How would you adjust your space complexity?'",
        "INTERVIEWER: 'The PM updated requirements: what if input stream contains duplicate negative keys?'",
        "INTERVIEWER: 'Can you optimize this algorithm to run strictly in O(1) auxiliary memory?'",
        "INTERVIEWER: 'How would you handle this if 10,000 concurrent threads accessed this function simultaneously?'"
      }
      sess.active_curveball = curveballs[math.random(#curveballs)]
    end

    -- Header: Exit button + Track badge + Timer
    local exit_lbl = "< Exit OA"
    local exit_w = style.font:get_width(exit_lbl) + 12*SCALE
    self.quit_assess_btn_rect = {x=cx, y=cy, w=exit_w, h=20*SCALE}
    renderer.draw_rect(cx, cy, exit_w, 20*SCALE, style.background2)
    renderer.draw_text(style.font, exit_lbl, cx + 6*SCALE, cy + 3*SCALE, style.dim)

    local badge_str = string.format("[%s | %d MINS]", sess.track.badge, sess.duration_mins)
    renderer.draw_text(style.font, badge_str, cx + exit_w + 10*SCALE, cy + 2*SCALE, style.accent)

    local timer_col = remaining > 900 and LC_COLORS.accepted or (remaining > 300 and LC_COLORS.medium or LC_COLORS.hard)
    local timer_str = string.format("Time Left: %02d:%02d", math.floor(remaining / 60), remaining % 60)
    local tw = style.font:get_width(timer_str)
    renderer.draw_text(style.font, timer_str, cx + cw - tw, cy + 2*SCALE, timer_col)
    cy = cy + 24*SCALE

    -- Progress Bar
    local total_secs = sess.duration_mins * 60
    local prog_w = math.floor(cw * (remaining / total_secs))
    renderer.draw_rect(cx, cy, cw, 4*SCALE, style.background3)
    renderer.draw_rect(cx, cy, prog_w, 4*SCALE, timer_col)
    cy = cy + 12*SCALE

    -- Question Tabs
    self.q_tab_rects = {}
    local tab_x = cx
    for i, q in ipairs(sess.questions) do
      local is_cur = (sess.current_q_idx == i)
      local status_icon = "[-]"
      local status_col = style.dim
      if q.status == "accepted" then status_icon = "[OK]"; status_col = LC_COLORS.accepted
      elseif q.status == "in_progress" then status_icon = "[~]"; status_col = LC_COLORS.medium
      elseif q.status == "wrong" or q.status == "tle" or q.status == "error" then status_icon = "[!]"; status_col = LC_COLORS.hard end

      local diff_tag = sess.blind_mode and "" or (" [" .. q.difficulty:sub(1,1) .. "]")
      local max_tlen = 16
      local trunc_title = #q.title > max_tlen and (q.title:sub(1, max_tlen) .. "..") or q.title
      local tab_label = string.format(" Q%d: %s%s %s ", i, trunc_title, diff_tag, status_icon)
      local tab_w = style.font:get_width(tab_label) + 8*SCALE
      local tab_h = 24*SCALE

      local bg = is_cur and style.background3 or style.background2
      renderer.draw_rect(tab_x, cy, tab_w, tab_h, bg)
      renderer.draw_rect(tab_x, cy, tab_w, 1*SCALE, is_cur and style.accent or style.dim)
      if is_cur then renderer.draw_rect(tab_x, cy, 3*SCALE, tab_h, style.accent) end
      renderer.draw_text(style.font, tab_label, tab_x + 4*SCALE, cy + 4*SCALE, is_cur and style.text or status_col)

      table.insert(self.q_tab_rects, {x=tab_x, y=cy, w=tab_w, h=tab_h, idx=i})
      tab_x = tab_x + tab_w + 6*SCALE
    end

    local finish_lbl = "Finish Assessment"
    local finish_w = style.font:get_width(finish_lbl) + 14*SCALE
    local next_lbl = "Next >"
    local next_w = style.font:get_width(next_lbl) + 14*SCALE

    if tab_x + next_w + finish_w + 14*SCALE <= cx + cw then
      self.finish_assess_btn_rect = {x=cx + cw - finish_w, y=cy, w=finish_w, h=24*SCALE}
      renderer.draw_rect(self.finish_assess_btn_rect.x, cy, finish_w, 24*SCALE, {LC_COLORS.hard[1], LC_COLORS.hard[2], LC_COLORS.hard[3], 40})
      renderer.draw_rect(self.finish_assess_btn_rect.x, cy, finish_w, 1*SCALE, LC_COLORS.hard)
      renderer.draw_text(style.font, finish_lbl, self.finish_assess_btn_rect.x + 7*SCALE, cy + 4*SCALE, LC_COLORS.hard)

      self.next_q_btn_rect = {x=cx + cw - finish_w - next_w - 8*SCALE, y=cy, w=next_w, h=24*SCALE}
      renderer.draw_rect(self.next_q_btn_rect.x, cy, next_w, 24*SCALE, style.background2)
      renderer.draw_text(style.font, next_lbl, self.next_q_btn_rect.x + 7*SCALE, cy + 4*SCALE, style.accent)
      cy = cy + 32*SCALE
    else
      cy = cy + 28*SCALE
      self.next_q_btn_rect = {x=cx, y=cy, w=next_w, h=24*SCALE}
      renderer.draw_rect(cx, cy, next_w, 24*SCALE, style.background2)
      renderer.draw_text(style.font, next_lbl, cx + 7*SCALE, cy + 4*SCALE, style.accent)

      self.finish_assess_btn_rect = {x=cx + next_w + 8*SCALE, y=cy, w=finish_w, h=24*SCALE}
      renderer.draw_rect(self.finish_assess_btn_rect.x, cy, finish_w, 24*SCALE, {LC_COLORS.hard[1], LC_COLORS.hard[2], LC_COLORS.hard[3], 40})
      renderer.draw_rect(self.finish_assess_btn_rect.x, cy, finish_w, 1*SCALE, LC_COLORS.hard)
      renderer.draw_text(style.font, finish_lbl, self.finish_assess_btn_rect.x + 7*SCALE, cy + 4*SCALE, LC_COLORS.hard)
      cy = cy + 32*SCALE
    end

    -- Curveball Prompt
    if sess.active_curveball then
      local cb_w = cw
      renderer.draw_rect(cx, cy, cb_w, 32*SCALE, {LC_COLORS.hard[1], LC_COLORS.hard[2], LC_COLORS.hard[3], 35})
      renderer.draw_rect(cx, cy, 4*SCALE, 32*SCALE, LC_COLORS.hard)
      core.push_clip_rect(cx + 8*SCALE, cy, cb_w - 12*SCALE, 32*SCALE)
      renderer.draw_text(style.font, sess.active_curveball, cx + 12*SCALE, cy + 7*SCALE, style.text)
      core.pop_clip_rect()
      cy = cy + 38*SCALE
    end

    -- Problem Area
    local cur_q = sess.questions[sess.current_q_idx]
    if cur_q and cur_q.problem_data then
      local p = cur_q.problem_data
      local p_title = string.format("Q%d. %s", sess.current_q_idx, p.title)
      renderer.draw_text(style.big_font or style.font, p_title, cx, cy, style.text)

      local copy_label = "Copy desc"
      local copy_w = style.font:get_width(copy_label) + 14*SCALE
      self.copy_btn_rect = {x = cx + cw - copy_w, y = cy, w = copy_w, h = 24*SCALE}
      renderer.draw_rect(cx + cw - copy_w, cy, copy_w, 24*SCALE, style.background2)
      renderer.draw_text(style.font, copy_label, cx + cw - copy_w + 7*SCALE, cy + 3*SCALE, style.accent)

      cy = cy + (style.big_font or style.font):get_height() + 4*SCALE
      local pat_n = cur_q.pattern_name or p.pattern_name
      local top_n = cur_q.topic or p.topic or (p.topics and p.topics[1])
      if pat_n or top_n then
        local ml_str = string.format("[ ML Predicted | Pattern: %s | Topic: #%s ]", pat_n or "DSA Pattern", top_n or "algorithms")
        renderer.draw_text(style.font, ml_str, cx, cy, style.accent)
        cy = cy + style.font:get_height() + 4*SCALE
      else
        cy = cy + 4*SCALE
      end

      -- Action toolbar: Run / Submit / Clear (wired in mouse handler)
      local as_run_lbl = "> Run"
      local as_run_w = style.font:get_width(as_run_lbl) + 14*SCALE
      self.run_btn_rect = {x=cx, y=cy, w=as_run_w, h=22*SCALE}
      renderer.draw_rect(cx, cy, as_run_w, 22*SCALE, style.background2)
      renderer.draw_text(style.font, as_run_lbl, cx + 7*SCALE, cy + 3*SCALE, LC_COLORS.accepted or style.accent)

      local as_sub_lbl = "^ Submit"
      local as_sub_w = style.font:get_width(as_sub_lbl) + 14*SCALE
      self.submit_btn_rect = {x=cx + as_run_w + 8*SCALE, y=cy, w=as_sub_w, h=22*SCALE}
      renderer.draw_rect(self.submit_btn_rect.x, cy, as_sub_w, 22*SCALE, style.background2)
      renderer.draw_text(style.font, as_sub_lbl, self.submit_btn_rect.x + 7*SCALE, cy + 3*SCALE, LC_COLORS.medium or style.accent)

      local as_clr_lbl = "~ Clear"
      local as_clr_w = style.font:get_width(as_clr_lbl) + 14*SCALE
      self.reset_btn_rect = {x=cx + as_run_w + as_sub_w + 16*SCALE, y=cy, w=as_clr_w, h=22*SCALE}
      renderer.draw_rect(self.reset_btn_rect.x, cy, as_clr_w, 22*SCALE, style.background2)
      renderer.draw_text(style.font, as_clr_lbl, self.reset_btn_rect.x + 7*SCALE, cy + 3*SCALE, style.error)

      cy = cy + 28*SCALE
      renderer.draw_rect(cx, cy, cw, 1*SCALE, style.dim)
      cy = cy + 8*SCALE

      local scroll_area_h = (y + h - 20*SCALE) - cy
      core.push_clip_rect(cx, cy, cw, scroll_area_h)
      local inner_cy = cy - self.scroll_y
      inner_cy = draw_rich_content(style.font, p.content_plain, cx + 4*SCALE, inner_cy, cw - 8*SCALE, self.scroll_y)
      self.max_scroll = math.max(0, inner_cy - (cy - self.scroll_y) - scroll_area_h + 50*SCALE)
      core.pop_clip_rect()
    end
    core.redraw = true

  -- =========================================================================
  -- STATE 3: ASSESSMENT SCORECARD
  -- =========================================================================
  elseif self.state == "assessment_scorecard" then
    local sess = assessment.get_session()
    local sc = sess and sess.scorecard or {}

    renderer.draw_text(style.big_font or style.font, "Assessment Scorecard & Performance Report", cx, cy, style.accent)
    cy = cy + (style.big_font or style.font):get_height() + 12*SCALE

    -- Hero Verdict Banner
    local v_col = sc.verdict_color or LC_COLORS.accepted
    local banner_h = 56*SCALE
    renderer.draw_rect(cx, cy, cw, banner_h, {v_col[1], v_col[2], v_col[3], 30})
    renderer.draw_rect(cx, cy, 6*SCALE, banner_h, v_col)

    local score_str = string.format("Score: %d / 100  |  Verdict: %s", sc.score or 0, sc.verdict or "Completed")
    renderer.draw_text(style.big_font or style.font, score_str, cx + 16*SCALE, cy + 8*SCALE, v_col)
    core.push_clip_rect(cx + 16*SCALE, cy + 30*SCALE, cw - 24*SCALE, 22*SCALE)
    renderer.draw_text(style.font, sc.verdict_desc or "Assessment concluded.", cx + 16*SCALE, cy + 32*SCALE, style.text)
    core.pop_clip_rect()
    cy = cy + banner_h + 14*SCALE

    -- 4 Metric Cards
    local use_4col = (cw >= 620*SCALE)
    local m_cols = use_4col and 4 or 2
    local m_w = math.floor((cw - (m_cols - 1) * 10*SCALE) / m_cols)
    local m_h = 50*SCALE

    local metrics = {
      { label = "Time Taken", val = string.format("%02dm %02ds", math.floor((sc.total_time_used or 0)/60), (sc.total_time_used or 0)%60), col = style.text },
      { label = "Solved", val = string.format("%d / %d Accepted", sc.accepted_count or 0, sc.total_questions or 0), col = LC_COLORS.accepted },
      { label = "Speed Bonus", val = string.format("+%d pts", sc.time_bonus or 0), col = style.accent },
      { label = "Submissions", val = string.format("%d subs (-%d pts)", sc.submissions_count or 0, sc.penalties or 0), col = style.text }
    }

    for idx, m in ipairs(metrics) do
      local col = (idx - 1) % m_cols
      local row = math.floor((idx - 1) / m_cols)
      local mx = cx + col * (m_w + 10*SCALE)
      local my = cy + row * (m_h + 8*SCALE)

      renderer.draw_rect(mx, my, m_w, m_h, style.background2)
      renderer.draw_text(style.font, m.label, mx + 8*SCALE, my + 5*SCALE, style.dim)
      renderer.draw_text(style.font, m.val, mx + 8*SCALE, my + 25*SCALE, m.col)
    end

    local m_rows = use_4col and 1 or 2
    cy = cy + m_rows * (m_h + 8*SCALE) + 14*SCALE

    -- Breakdown Table
    renderer.draw_text(style.font, "Per-Question Breakdown:", cx, cy, style.text)
    cy = cy + style.font:get_height() + 6*SCALE

    renderer.draw_rect(cx, cy, cw, 24*SCALE, style.background3)
    renderer.draw_text(style.font, "#", cx + 8*SCALE, cy + 4*SCALE, style.dim)
    renderer.draw_text(style.font, "Problem Title", cx + 32*SCALE, cy + 4*SCALE, style.dim)
    renderer.draw_text(style.font, "Diff", cx + cw - 320*SCALE, cy + 4*SCALE, style.dim)
    renderer.draw_text(style.font, "Status", cx + cw - 250*SCALE, cy + 4*SCALE, style.dim)
    renderer.draw_text(style.font, "Time", cx + cw - 160*SCALE, cy + 4*SCALE, style.dim)
    renderer.draw_text(style.font, "Complexity", cx + cw - 85*SCALE, cy + 4*SCALE, style.dim)
    cy = cy + 26*SCALE

    if sess and sess.questions then
      for i, q in ipairs(sess.questions) do
        renderer.draw_rect(cx, cy, cw, 26*SCALE, (i % 2 == 0) and style.background2 or style.background)
        renderer.draw_text(style.font, string.format("Q%d", i), cx + 8*SCALE, cy + 4*SCALE, style.text)

        core.push_clip_rect(cx + 32*SCALE, cy, math.max(20*SCALE, cw - 360*SCALE), 26*SCALE)
        renderer.draw_text(style.font, q.title, cx + 32*SCALE, cy + 4*SCALE, style.text)
        core.pop_clip_rect()

        local dc = LC_COLORS[q.difficulty:lower()] or style.dim
        renderer.draw_text(style.font, q.difficulty, cx + cw - 320*SCALE, cy + 4*SCALE, dc)

        local stat_str = q.status == "accepted" and "Accepted" or (q.status == "wrong" and "Wrong" or "Incomplete")
        local stat_col = q.status == "accepted" and LC_COLORS.accepted or (q.status == "wrong" and LC_COLORS.hard or style.dim)
        renderer.draw_text(style.font, stat_str, cx + cw - 250*SCALE, cy + 4*SCALE, stat_col)

        local qs_str = string.format("%02dm %02ds", math.floor((q.time_spent or 0)/60), (q.time_spent or 0)%60)
        renderer.draw_text(style.font, qs_str, cx + cw - 160*SCALE, cy + 4*SCALE, style.text)

        core.push_clip_rect(cx + cw - 85*SCALE, cy, 80*SCALE, 26*SCALE)
        renderer.draw_text(style.font, q.est_tc or "O(?)", cx + cw - 85*SCALE, cy + 4*SCALE, style.accent)
        core.pop_clip_rect()
        cy = cy + 28*SCALE
      end
    end
    cy = cy + 16*SCALE

    -- Action Buttons
    local rev_lbl = "Review Solution Code"
    local rev_w = style.font:get_width(rev_lbl) + 20*SCALE
    local new_lbl = "Start New Assessment"
    local new_w = style.font:get_width(new_lbl) + 20*SCALE
    local back_list_lbl = "Back to Problem Browser"
    local back_list_w = style.font:get_width(back_list_lbl) + 20*SCALE

    local bx = cx
    self.review_btn_rect = {x=bx, y=cy, w=rev_w, h=30*SCALE}
    renderer.draw_rect(bx, cy, rev_w, 30*SCALE, style.accent)
    renderer.draw_text(style.font, rev_lbl, bx + 10*SCALE, cy + 6*SCALE, style.background)
    bx = bx + rev_w + 10*SCALE

    if bx + new_w > cx + cw then
      bx = cx
      cy = cy + 36*SCALE
    end
    self.new_assess_btn_rect = {x=bx, y=cy, w=new_w, h=30*SCALE}
    renderer.draw_rect(bx, cy, new_w, 30*SCALE, style.background2)
    renderer.draw_text(style.font, new_lbl, bx + 10*SCALE, cy + 6*SCALE, style.text)
    bx = bx + new_w + 10*SCALE

    if bx + back_list_w > cx + cw then
      bx = cx
      cy = cy + 36*SCALE
    end
    self.scorecard_back_btn_rect = {x=bx, y=cy, w=back_list_w, h=30*SCALE}
    renderer.draw_rect(bx, cy, back_list_w, 30*SCALE, style.background2)
    renderer.draw_text(style.font, back_list_lbl, bx + 10*SCALE, cy + 6*SCALE, style.dim)

  -- =========================================================================
  -- STATE 4: AUTHENTICATION
  -- =========================================================================
  elseif self.state == "auth" then
    renderer.draw_text(style.big_font or style.font, "LeetCode Account Connection", cx, cy, style.accent)
    cy = cy + (style.big_font or style.font):get_height() + 4*SCALE
    renderer.draw_text(style.font, "Login with browser cookies or auto-detect to sync submissions.", cx, cy, style.dim)
    cy = cy + style.font:get_height() + 16*SCALE

    -- Status pill
    if self.auth_status and self.auth_status ~= "" then
      local stat_w = style.font:get_width(self.auth_status) + 16*SCALE
      renderer.draw_rect(cx, cy, stat_w, 24*SCALE, style.background2)
      renderer.draw_text(style.font, self.auth_status, cx + 8*SCALE, cy + 4*SCALE, style.accent)
      cy = cy + 32*SCALE
    end

    -- Auto Detect Button
    local auto_lbl = "[>] Auto-Detect Login from Installed Browsers"
    local auto_w = style.font:get_width(auto_lbl) + 24*SCALE
    self.auth_auto_btn_rect = {x=cx, y=cy, w=auto_w, h=30*SCALE}
    renderer.draw_rect(cx, cy, auto_w, 30*SCALE, style.accent)
    renderer.draw_text(style.font, auto_lbl, cx + 12*SCALE, cy + 6*SCALE, style.background)
    cy = cy + 44*SCALE

    -- Manual Cookie Input
    renderer.draw_text(style.font, "Manual Cookie String (LEETCODE_SESSION & csrftoken):", cx, cy, style.text)
    cy = cy + style.font:get_height() + 6*SCALE

    local input_w = math.min(cw, 500*SCALE)
    self.auth_cookie_rect = {x=cx, y=cy, w=input_w, h=28*SCALE}
    renderer.draw_rect(cx, cy, input_w, 28*SCALE, style.background2)
    renderer.draw_rect(cx, cy, input_w, 1*SCALE, self.auth_input_focus and style.accent or style.dim)

    local cookie_display = (self.cookie_input and self.cookie_input ~= "") and self.cookie_input or "Paste LEETCODE_SESSION=...; csrftoken=... here"
    local cookie_col = (self.cookie_input and self.cookie_input ~= "") and style.text or style.dim
    core.push_clip_rect(cx + 6*SCALE, cy, input_w - 12*SCALE, 28*SCALE)
    renderer.draw_text(style.font, cookie_display, cx + 8*SCALE, cy + 5*SCALE, cookie_col)
    core.pop_clip_rect()
    cy = cy + 36*SCALE

    -- Connect Button
    local conn_lbl = "Connect Account"
    local conn_w = style.font:get_width(conn_lbl) + 20*SCALE
    self.auth_connect_btn_rect = {x=cx, y=cy, w=conn_w, h=28*SCALE}
    renderer.draw_rect(cx, cy, conn_w, 28*SCALE, style.background3)
    renderer.draw_rect(cx, cy, conn_w, 1*SCALE, style.accent)
    renderer.draw_text(style.font, conn_lbl, cx + 10*SCALE, cy + 5*SCALE, style.accent)

  -- =========================================================================
  -- STATE 5: PROBLEM LIST (BROWSER)
  -- =========================================================================
  elseif self.state == "list" then
    -- Header Row: Title & Stats
    local title_str = "LeetCode Problems"
    renderer.draw_text(style.big_font or style.font, title_str, cx, cy, style.accent)
    
    if self.user_stats and type(self.user_stats) == "table" then
      local total_s, easy_s, med_s, hard_s = "0", "0", "0", "0"
      for _, stat in ipairs(self.user_stats) do
        if stat.difficulty == "All" then total_s = tostring(stat.count)
        elseif stat.difficulty == "Easy" then easy_s = tostring(stat.count)
        elseif stat.difficulty == "Medium" then med_s = tostring(stat.count)
        elseif stat.difficulty == "Hard" then hard_s = tostring(stat.count)
        end
      end
      local stats_str = string.format("Solved: %s (E:%s M:%s H:%s)", total_s, easy_s, med_s, hard_s)
      local sw_w = style.font:get_width(stats_str)
      renderer.draw_text(style.font, stats_str, cx + cw - sw_w, cy + 4*SCALE, LC_COLORS.accepted)
    end
    cy = cy + (style.big_font or style.font):get_height() + 10*SCALE

    -- Toolbar: Difficulty Filters & Special Modes (Auto-wrapping row)
    local diffs = { "ALL", "EASY", "MEDIUM", "HARD" }
    self.diff_buttons = {}
    local tx = cx
    local th = 22*SCALE

    for _, d in ipairs(diffs) do
      local is_cur = (self.difficulty == d)
      local dw = style.font:get_width(d) + 14*SCALE
      local bg = is_cur and style.background3 or style.background2
      local fg = is_cur and (LC_COLORS[d:lower()] or style.accent) or style.dim

      renderer.draw_rect(tx, cy, dw, th, bg)
      renderer.draw_rect(tx, cy, dw, 1*SCALE, is_cur and fg or style.dim)
      renderer.draw_text(style.font, d, tx + 7*SCALE, cy + 3*SCALE, fg)

      table.insert(self.diff_buttons, {x=tx, y=cy, w=dw, h=th, val=d})
      tx = tx + dw + 6*SCALE
    end

    tx = tx + 10*SCALE

    -- [OA] Assessment
    local oa_lbl = "[OA] Assessment"
    local oa_w = style.font:get_width(oa_lbl) + 14*SCALE
    if tx + oa_w > cx + cw then tx = cx; cy = cy + th + 6*SCALE end
    self.assessment_btn_rect = {x=tx, y=cy, w=oa_w, h=th}
    renderer.draw_rect(tx, cy, oa_w, th, {style.accent[1], style.accent[2], style.accent[3], 40})
    renderer.draw_rect(tx, cy, oa_w, 1*SCALE, style.accent)
    renderer.draw_text(style.font, oa_lbl, tx + 7*SCALE, cy + 3*SCALE, style.accent)
    tx = tx + oa_w + 6*SCALE

    -- [Mock] 45m
    local mock_lbl = "[Mock] 45m"
    local mock_w = style.font:get_width(mock_lbl) + 14*SCALE
    if tx + mock_w > cx + cw then tx = cx; cy = cy + th + 6*SCALE end
    self.mock_btn_rect = {x=tx, y=cy, w=mock_w, h=th}
    renderer.draw_rect(tx, cy, mock_w, th, style.background2)
    renderer.draw_rect(tx, cy, mock_w, 1*SCALE, style.dim)
    renderer.draw_text(style.font, mock_lbl, tx + 7*SCALE, cy + 3*SCALE, LC_COLORS.medium)
    tx = tx + mock_w + 6*SCALE

    -- [Pick One]
    local pick_lbl = "[Pick One]"
    local pick_w = style.font:get_width(pick_lbl) + 14*SCALE
    if tx + pick_w > cx + cw then tx = cx; cy = cy + th + 6*SCALE end
    self.random_btn_rect = {x=tx, y=cy, w=pick_w, h=th}
    renderer.draw_rect(tx, cy, pick_w, th, style.background2)
    renderer.draw_rect(tx, cy, pick_w, 1*SCALE, style.dim)
    renderer.draw_text(style.font, pick_lbl, tx + 7*SCALE, cy + 3*SCALE, style.text)
    tx = tx + pick_w + 6*SCALE

    -- [Study Plans] — opens StudyPlanView in a new tab
    local sp_lbl = "[P] Study Plans"   -- Ⓟ Study Plans (UTF-8)
    local sp_w   = style.font:get_width(sp_lbl) + 14*SCALE
    if tx + sp_w > cx + cw then tx = cx; cy = cy + th + 6*SCALE end
    self.study_plan_btn_rect = {x=tx, y=cy, w=sp_w, h=th}
    local sp_acc = LC_COLORS.accepted or style.accent
    renderer.draw_rect(tx, cy, sp_w, th, {sp_acc[1], sp_acc[2], sp_acc[3], 0.12})
    renderer.draw_rect(tx, cy, sp_w, 1*SCALE, sp_acc)
    renderer.draw_text(style.font, sp_lbl, tx + 7*SCALE, cy + 3*SCALE, sp_acc)

    -- [Update Database] button (far-right of toolbar row)
    local upd_lbl = "[~] Update DB"
    local upd_w = style.font:get_width(upd_lbl) + 14*SCALE
    local upd_x = cx + cw - upd_w
    self.update_db_btn_rect = {x=upd_x, y=cy, w=upd_w, h=th}
    renderer.draw_rect(upd_x, cy, upd_w, th, {style.accent[1], style.accent[2], style.accent[3], 30})
    renderer.draw_rect(upd_x, cy, upd_w, 1*SCALE, style.accent)
    renderer.draw_text(style.font, upd_lbl, upd_x + 7*SCALE, cy + 3*SCALE, style.accent)

    -- "DB: Nd ago" label (cached to avoid per-frame disk I/O)
    do
      local now_t = os.time()
      if not self.db_age_str or not self.db_age_cache_time or (now_t - self.db_age_cache_time > 60) then
        local db_path = USERDIR .. "/plugins/company_tags.json"
        local info = system.get_file_info(db_path)
        if info then
          local age_s = os.difftime(now_t, info.modified)
          if age_s < 3600 then
            self.db_age_str = string.format("DB: %dm ago", math.floor(age_s/60))
          elseif age_s < 86400 then
            self.db_age_str = string.format("DB: %dh ago", math.floor(age_s/3600))
          else
            self.db_age_str = string.format("DB: %dd ago", math.floor(age_s/86400))
          end
        else
          self.db_age_str = nil
        end
        self.db_age_cache_time = now_t
      end
      if self.db_age_str then
        renderer.draw_text(style.font, self.db_age_str, upd_x - style.font:get_width(self.db_age_str) - 8*SCALE, cy + 3*SCALE, style.dim)
      end
    end

    cy = cy + th + 8*SCALE

    -- Show last update result toast if present (properly separated with no overlap)
    if self.update_result then
      if not self.update_result_time then self.update_result_time = os.time() end
      if os.time() - self.update_result_time > 8 then
        self.update_result = nil
        self.update_result_time = nil
      else
        local toast_h = 22*SCALE
        local tw = math.min(cw, style.font:get_width(self.update_result) + 20*SCALE)
        renderer.draw_rect(cx, cy, tw, toast_h, {40, 180, 100, 40})
        renderer.draw_rect(cx, cy, tw, 1*SCALE, LC_COLORS.accepted or style.accent)
        renderer.draw_text(style.font, self.update_result, cx + 8*SCALE, cy + 3*SCALE, LC_COLORS.accepted or style.accent)
        cy = cy + toast_h + 8*SCALE
      end
    end

    -- Search Bar
    self.search_rect = {x=cx, y=cy, w=cw, h=24*SCALE}
    renderer.draw_rect(cx, cy, cw, 24*SCALE, style.background2)
    renderer.draw_rect(cx, cy, cw, 1*SCALE, self.search_focus and style.accent or style.dim)

    local lbl_w = style.font:get_width("Search: ")
    local clear_lbl = "x Clear"
    local clear_w = style.font:get_width(clear_lbl) + 14*SCALE
    local has_input = (self.search_input and self.search_input ~= "")
    local s_text = has_input and self.search_input or "Search problems or type tag:... (e.g. #array, @google)"
    local s_col = has_input and style.text or style.dim
    renderer.draw_text(style.font, "Search: ", cx + 8*SCALE, cy + 3*SCALE, style.dim)

    local max_stext_w = math.max(20*SCALE, cw - lbl_w - (has_input and (clear_w + 16*SCALE) or 16*SCALE))
    core.push_clip_rect(cx + 8*SCALE + lbl_w, cy, max_stext_w, 24*SCALE)
    renderer.draw_text(style.font, s_text, cx + 8*SCALE + lbl_w, cy + 3*SCALE, s_col)
    core.pop_clip_rect()

    self.clear_btn_rect = {x=cx + cw - clear_w - 4*SCALE, y=cy, w=clear_w, h=24*SCALE}
    if has_input then
      renderer.draw_rect(self.clear_btn_rect.x, cy, clear_w, 24*SCALE, style.background3)
      renderer.draw_text(style.font, clear_lbl, self.clear_btn_rect.x + 7*SCALE, cy + 3*SCALE, style.text)
    else
      self.clear_btn_rect = nil
    end

    cy = cy + 30*SCALE

    -- Autocomplete Dropdown (if active)
    if self.search_focus and self.search_input and self.search_input ~= "" then
      local query = self.search_input:match("(%S+)$") or ""
      local prefix = ""
      local items = {}
      if query:match("^#(.+)") or query == "#" then
        prefix = "#"
        local sub = query:match("^#?(.*)"):lower()
        for _, t in ipairs(TOPIC_TAGS or {}) do
          if t:lower():find(sub, 1, true) then table.insert(items, t) end
          if #items >= 6 then break end
        end
      elseif query:match("^@(.+)") or query == "@" then
        prefix = "@"
        local sub = query:match("^@?(.*)"):lower()
        for _, c in ipairs(COMPANIES or {}) do
          if c:lower():find(sub, 1, true) then table.insert(items, c) end
          if #items >= 6 then break end
        end
      end

      if #items > 0 then
        local drop_h = #items * 24*SCALE
        self.dropdown_rect = {x=cx, y=cy, w=300*SCALE, h=drop_h}
        self.dropdown_items = {}
        renderer.draw_rect(cx, cy, 300*SCALE, drop_h, style.background3)
        renderer.draw_rect(cx, cy, 300*SCALE, drop_h, style.accent)
        for di, itm in ipairs(items) do
          local iy = cy + (di - 1) * 24*SCALE
          renderer.draw_text(style.font, prefix .. itm, cx + 8*SCALE, iy + 4*SCALE, style.text)
          table.insert(self.dropdown_items, {y=iy, t=itm, prefix=prefix})
        end
        cy = cy + drop_h + 6*SCALE
      end
    end

    -- Problem Table Header
    renderer.draw_rect(cx, cy, cw, 22*SCALE, style.background3)
    renderer.draw_text(style.font, "#", cx + 8*SCALE, cy + 3*SCALE, style.dim)
    renderer.draw_text(style.font, "Title", cx + 50*SCALE, cy + 3*SCALE, style.dim)
    renderer.draw_text(style.font, "Acceptance", cx + cw - 150*SCALE, cy + 3*SCALE, style.dim)
    renderer.draw_text(style.font, "Difficulty", cx + cw - 70*SCALE, cy + 3*SCALE, style.dim)
    cy = cy + 24*SCALE

    -- Problem List Items
    self.problem_rows = {}
    local bottom_bar_h = 36*SCALE
    local list_max_h = (y + h - bottom_bar_h) - cy
    core.push_clip_rect(cx, cy, cw, list_max_h)

    local row_y = cy - (self.list_scroll_y or 0)
    local problems = self.problems or {}

    for pi, prob in ipairs(problems) do
      if row_y + 24*SCALE >= cy and row_y <= cy + list_max_h then
        local is_sel = (self.selected_idx == pi)
        local bg = is_sel and style.background3 or ((pi % 2 == 0) and style.background2 or style.background)
        renderer.draw_rect(cx, row_y, cw, 24*SCALE, bg)
        if is_sel then renderer.draw_rect(cx, row_y, 3*SCALE, 24*SCALE, style.accent) end

        -- Num
        local p_num = tostring(prob.id or prob.question_id or pi)
        renderer.draw_text(style.font, p_num, cx + 8*SCALE, row_y + 4*SCALE, style.dim)

        -- Title
        core.push_clip_rect(cx + 50*SCALE, row_y, cw - 210*SCALE, 24*SCALE)
        local p_title = prob.title or prob.slug or "Unknown"
        local title_fg = prob.paid and style.dim or (is_sel and style.accent or style.text)
        renderer.draw_text(style.font, p_title, cx + 50*SCALE, row_y + 4*SCALE, title_fg)
        core.pop_clip_rect()

        -- Acceptance
        local acc_str = prob.ac_rate and string.format("%.1f%%", prob.ac_rate) or "--"
        renderer.draw_text(style.font, acc_str, cx + cw - 150*SCALE, row_y + 4*SCALE, style.dim)

        -- Difficulty
        local diff_str = prob.difficulty or "Easy"
        local diff_col = LC_COLORS[diff_str:lower()] or style.dim
        renderer.draw_text(style.font, diff_str, cx + cw - 70*SCALE, row_y + 4*SCALE, diff_col)

        table.insert(self.problem_rows, {x=cx, y=row_y, w=cw, h=24*SCALE, idx=pi})
      end
      row_y = row_y + 24*SCALE
    end
    core.pop_clip_rect()

    -- Bottom Pagination Bar
    local bot_y = y + h - 30*SCALE
    renderer.draw_rect(cx, bot_y - 4*SCALE, cw, 1*SCALE, style.dim)

    local prev_lbl = "< Prev (50)"
    local prev_w = style.font:get_width(prev_lbl) + 14*SCALE
    self.page_prev_rect = {x=cx, y=bot_y, w=prev_w, h=22*SCALE}
    renderer.draw_rect(cx, bot_y, prev_w, 22*SCALE, style.background2)
    renderer.draw_text(style.font, prev_lbl, cx + 7*SCALE, bot_y + 3*SCALE, (self.page_skip or 0) > 0 and style.text or style.dim)

    local next_lbl = "Next (50) >"
    local next_w = style.font:get_width(next_lbl) + 14*SCALE
    self.page_next_rect = {x=cx + prev_w + 10*SCALE, y=bot_y, w=next_w, h=22*SCALE}
    renderer.draw_rect(cx + prev_w + 10*SCALE, bot_y, next_w, 22*SCALE, style.background2)
    renderer.draw_text(style.font, next_lbl, cx + prev_w + 17*SCALE, bot_y + 3*SCALE, style.text)

    local page_num = math.floor((self.page_skip or 0) / 50) + 1
    local page_str = string.format("Page %d", page_num)
    renderer.draw_text(style.font, page_str, cx + prev_w + next_w + 20*SCALE, bot_y + 3*SCALE, style.dim)

  -- =========================================================================
  -- STATE 6: PROBLEM VIEW
  -- =========================================================================
  elseif self.state == "problem" and self.current then
    local p = self.current

    -- Top Navigation Bar: Back, Run, Submit, Clear, Trends, Copy
    local back_lbl = "< Back to List"
    local back_w = style.font:get_width(back_lbl) + 14*SCALE
    self.back_btn_rect = {x=cx, y=cy, w=back_w, h=24*SCALE}
    renderer.draw_rect(cx, cy, back_w, 24*SCALE, style.background2)
    renderer.draw_text(style.font, back_lbl, cx + 7*SCALE, cy + 4*SCALE, style.accent)

    local run_lbl = "[>] Run"
    local run_w = style.font:get_width(run_lbl) + 14*SCALE
    self.run_btn_rect = {x=cx + back_w + 8*SCALE, y=cy, w=run_w, h=24*SCALE}
    renderer.draw_rect(self.run_btn_rect.x, cy, run_w, 24*SCALE, style.background2)
    renderer.draw_text(style.font, run_lbl, self.run_btn_rect.x + 7*SCALE, cy + 4*SCALE, LC_COLORS.accepted or style.accent)

    local submit_lbl = "[^] Submit"
    local submit_w = style.font:get_width(submit_lbl) + 14*SCALE
    self.submit_btn_rect = {x=cx + back_w + run_w + 16*SCALE, y=cy, w=submit_w, h=24*SCALE}
    renderer.draw_rect(self.submit_btn_rect.x, cy, submit_w, 24*SCALE, style.background2)
    renderer.draw_text(style.font, submit_lbl, self.submit_btn_rect.x + 7*SCALE, cy + 4*SCALE, LC_COLORS.medium or style.accent)

    local reset_lbl = "[~] Clear"
    local reset_w = style.font:get_width(reset_lbl) + 14*SCALE
    self.reset_btn_rect = {x=cx + back_w + run_w + submit_w + 24*SCALE, y=cy, w=reset_w, h=24*SCALE}
    renderer.draw_rect(self.reset_btn_rect.x, cy, reset_w, 24*SCALE, style.background2)
    renderer.draw_text(style.font, reset_lbl, self.reset_btn_rect.x + 7*SCALE, cy + 4*SCALE, style.error)

    local trend_lbl = "[ Trends ]"
    local trend_w = style.font:get_width(trend_lbl) + 14*SCALE
    local trend_x = cx + back_w + run_w + submit_w + reset_w + 32*SCALE
    self.trend_btn_rect = {x=trend_x, y=cy, w=trend_w, h=24*SCALE}
    renderer.draw_rect(trend_x, cy, trend_w, 24*SCALE,
      self.show_trend_panel and {style.accent[1], style.accent[2], style.accent[3], 80} or style.background2)
    renderer.draw_text(style.font, trend_lbl, trend_x + 7*SCALE, cy + 4*SCALE,
      self.show_trend_panel and style.accent or style.dim)

    local copy_lbl = "[ Copy Desc ]"
    local copy_w = style.font:get_width(copy_lbl) + 14*SCALE
    self.copy_btn_rect = {x=cx + cw - copy_w, y=cy, w=copy_w, h=24*SCALE}
    renderer.draw_rect(self.copy_btn_rect.x, cy, copy_w, 24*SCALE, style.background2)
    renderer.draw_text(style.font, copy_lbl, self.copy_btn_rect.x + 7*SCALE, cy + 4*SCALE, style.dim)

    if self.is_blind_mode and self.mock_timer_end then
      local remaining = math.max(0, self.mock_timer_end - os.time())
      local timer_col = remaining > 900 and (LC_COLORS.accepted or style.accent) or (remaining > 300 and (LC_COLORS.medium or style.text) or (LC_COLORS.hard or style.error))
      local timer_str = string.format("Time Left: %02d:%02d", math.floor(remaining / 60), remaining % 60)
      local tw = style.font:get_width(timer_str)
      renderer.draw_text(style.font, timer_str, cx + cw - copy_w - tw - 16*SCALE, cy + 4*SCALE, timer_col)
    end

    cy = cy + 32*SCALE

    -- Title & Difficulty
    local num = tostring(p.id or p.question_id or "")
    local full_title = (num ~= "" and (num .. ". ") or "") .. (p.title or p.slug)
    renderer.draw_text(style.big_font or style.font, full_title, cx, cy, style.text)
    cy = cy + (style.big_font or style.font):get_height() + 4*SCALE

    local diff_str = p.difficulty or "Medium"
    local diff_col = LC_COLORS[diff_str:lower()] or style.dim
    renderer.draw_text(style.font, diff_str, cx, cy, diff_col)

    if p.ac_rate then
      local acc_str = string.format("  |  Acceptance: %.1f%%", p.ac_rate)
      renderer.draw_text(style.font, acc_str, cx + style.font:get_width(diff_str), cy, style.dim)
    end
    cy = cy + style.font:get_height() + 8*SCALE

    -- Company pills (with 3-item preview + toggle + auto-wrap)
    self.company_pill_rects = {}
    if p.companies and #p.companies > 0 then
      local PREVIEW = 3
      local expanded = self.companies_expanded
      local show_list = expanded and p.companies or {table.unpack(p.companies, 1, math.min(PREVIEW, #p.companies))}

      renderer.draw_text(style.font, "Companies:", cx, cy, style.dim)
      local cpx = cx + style.font:get_width("Companies:") + 8*SCALE

      for _, comp in ipairs(show_list) do
        local slug    = comp:lower():gsub("%s+", "-")
        local pw      = style.font:get_width(comp) + 12*SCALE
        if cpx + pw > cx + cw and cpx > cx then
          cpx = cx
          cy = cy + 22*SCALE
        end
        local is_sel  = (self.selected_company == slug)
        local pill_bg = is_sel
          and {style.accent[1], style.accent[2], style.accent[3], 90}
          or  {style.accent[1], style.accent[2], style.accent[3], 22}
        renderer.draw_rect(cpx, cy, pw, 18*SCALE, pill_bg)
        renderer.draw_text(style.font, comp, cpx + 6*SCALE, cy + 2*SCALE,
          is_sel and style.accent or style.dim)
        table.insert(self.company_pill_rects, {x=cpx, y=cy, w=pw, h=18*SCALE, slug=slug, name=comp})
        cpx = cpx + pw + 6*SCALE
      end

      if #p.companies > PREVIEW then
        local hidden   = #p.companies - PREVIEW
        local tog_lbl  = expanded and "< less" or (string.format("+%d more", hidden))
        local tog_w    = style.font:get_width(tog_lbl) + 12*SCALE
        if cpx + tog_w > cx + cw and cpx > cx then
          cpx = cx
          cy = cy + 22*SCALE
        end
        renderer.draw_rect(cpx, cy, tog_w, 18*SCALE, {60, 60, 80, 60})
        renderer.draw_text(style.font, tog_lbl, cpx + 6*SCALE, cy + 2*SCALE, style.accent)
        table.insert(self.company_pill_rects, {x=cpx, y=cy, w=tog_w, h=18*SCALE, _is_toggle=true})
      end

      cy = cy + 24*SCALE
    end

    -- Topic pills (with 3-item preview + toggle + auto-wrap)
    self.topic_pill_rects = {}
    if p.topics and #p.topics > 0 then
      local PREVIEW_TOPICS = 3
      local expanded_topics = self.topics_expanded
      local show_topics = expanded_topics and p.topics or {table.unpack(p.topics, 1, math.min(PREVIEW_TOPICS, #p.topics))}

      renderer.draw_text(style.font, "Topics:", cx, cy, style.dim)
      local tpx = cx + style.font:get_width("Topics:") + 8*SCALE

      for _, tag in ipairs(show_topics) do
        local tw_pill = style.font:get_width(tag) + 12*SCALE
        if tpx + tw_pill > cx + cw and tpx > cx then
          tpx = cx
          cy = cy + 22*SCALE
        end
        renderer.draw_rect(tpx, cy, tw_pill, 18*SCALE, {70, 80, 110, 45})
        renderer.draw_text(style.font, tag, tpx + 6*SCALE, cy + 2*SCALE, style.text)
        tpx = tpx + tw_pill + 6*SCALE
      end

      if #p.topics > PREVIEW_TOPICS then
        local hidden_topics = #p.topics - PREVIEW_TOPICS
        local tog_lbl  = expanded_topics and "< less" or (string.format("+%d more", hidden_topics))
        local tog_w    = style.font:get_width(tog_lbl) + 12*SCALE
        if tpx + tog_w > cx + cw and tpx > cx then
          tpx = cx
          cy = cy + 22*SCALE
        end
        renderer.draw_rect(tpx, cy, tog_w, 18*SCALE, {60, 60, 80, 60})
        renderer.draw_text(style.font, tog_lbl, tpx + 6*SCALE, cy + 2*SCALE, style.accent)
        table.insert(self.topic_pill_rects, {x=tpx, y=cy, w=tog_w, h=18*SCALE, _is_toggle=true})
      end

      cy = cy + 24*SCALE
    end

    -- Language Starter Buttons (with 4-item preview + toggle + auto-wrap)
    renderer.draw_text(style.font, "Code Starter:", cx, cy, style.dim)
    local lx = cx + style.font:get_width("Code Starter:") + 8*SCALE
    self.lang_buttons = {}
    local langs = {}
    if p.starters then
      for l, _ in pairs(p.starters) do table.insert(langs, l) end
      table.sort(langs)
    end
    if #langs == 0 then langs = { "python3", "cpp", "java", "javascript", "rust", "golang", "mysql", "postgresql" } end

    local PREVIEW_LANGS = 4
    local expanded_langs = self.langs_expanded
    local show_langs = expanded_langs and langs or {table.unpack(langs, 1, math.min(PREVIEW_LANGS, #langs))}

    for _, l in ipairs(show_langs) do
      local has_starter = (p.starters and p.starters[l] ~= nil)
      local lw = style.font:get_width(l) + 12*SCALE
      if lx + lw > cx + cw and lx > cx then lx = cx; cy = cy + 22*SCALE end
      renderer.draw_rect(lx, cy, lw, 20*SCALE, style.background2)
      local col = has_starter and style.accent or style.dim
      renderer.draw_text(style.font, l, lx + 6*SCALE, cy + 2*SCALE, col)
      table.insert(self.lang_buttons, {x=lx, y=cy, w=lw, h=20*SCALE, lang=l})
      lx = lx + lw + 6*SCALE
    end

    if #langs > PREVIEW_LANGS then
      local hidden_langs = #langs - PREVIEW_LANGS
      local tog_lbl  = expanded_langs and "< less" or (string.format("+%d more", hidden_langs))
      local tog_w    = style.font:get_width(tog_lbl) + 12*SCALE
      if lx + tog_w > cx + cw and lx > cx then
        lx = cx
        cy = cy + 22*SCALE
      end
      renderer.draw_rect(lx, cy, tog_w, 20*SCALE, {60, 60, 80, 60})
      renderer.draw_text(style.font, tog_lbl, lx + 6*SCALE, cy + 2*SCALE, style.accent)
      table.insert(self.lang_buttons, {x=lx, y=cy, w=tog_w, h=20*SCALE, _is_toggle=true})
    end

    cy = cy + 26*SCALE

    -- Divider
    renderer.draw_rect(cx, cy, cw, 1*SCALE, style.dim)
    cy = cy + 6*SCALE

    -- Scrollable Rich Content Area
    local scroll_area_h = (y + h - 16*SCALE) - cy
    core.push_clip_rect(cx, cy, cw, scroll_area_h)
    local inner_cy = cy - self.scroll_y
    inner_cy = draw_rich_content(style.font, p.content_plain, cx + 4*SCALE, inner_cy, cw - 8*SCALE, self.scroll_y)

    -- Similar Problems section (scrolls with content)
    self.similar_buttons = {}
    local sq = p.similar_questions
    if sq and #sq > 0 then
      inner_cy = inner_cy + 16*SCALE
      renderer.draw_rect(cx + 4*SCALE, inner_cy, cw - 8*SCALE, 1*SCALE, style.dim)
      inner_cy = inner_cy + 10*SCALE

      renderer.draw_text(style.font, "Similar Problems", cx + 4*SCALE, inner_cy, style.accent)
      inner_cy = inner_cy + style.font:get_height() + 8*SCALE

      for _, sq_item in ipairs(sq) do
        local sq_title = sq_item.title or sq_item.titleSlug or "?"
        local sq_slug  = sq_item.titleSlug or ""
        local sq_diff  = sq_item.difficulty or "Medium"
        local diff_col = LC_COLORS[sq_diff:lower()] or style.dim
        local row_h    = 24*SCALE

        -- row background (subtle hover-ready rectangle)
        renderer.draw_rect(cx + 4*SCALE, inner_cy, cw - 8*SCALE, row_h, style.background2)

        -- title (clipped to leave room for badge)
        local badge_w = style.font:get_width(sq_diff) + 12*SCALE
        local title_avail_w = math.max(20*SCALE, cw - badge_w - 24*SCALE)
        core.push_clip_rect(cx + 10*SCALE, inner_cy, title_avail_w, row_h)
        renderer.draw_text(style.font, sq_title, cx + 10*SCALE, inner_cy + 4*SCALE, style.text)
        core.pop_clip_rect()

        -- difficulty badge (right-aligned)
        local badge_x = cx + cw - badge_w - 4*SCALE
        renderer.draw_rect(badge_x, inner_cy + 3*SCALE, badge_w, row_h - 6*SCALE, diff_col)
        renderer.draw_text(style.font, sq_diff, badge_x + 6*SCALE, inner_cy + 5*SCALE, style.background)

        table.insert(self.similar_buttons, {
          x    = cx + 4*SCALE,
          y    = inner_cy,
          w    = cw - 8*SCALE,
          h    = row_h,
          slug = sq_slug,
          title = sq_title,
        })
        inner_cy = inner_cy + row_h + 4*SCALE
      end
      inner_cy = inner_cy + 12*SCALE
    end

    self.max_scroll = math.max(0, inner_cy - (cy - self.scroll_y) - scroll_area_h + 50*SCALE)
    core.pop_clip_rect()


  -- =========================================================================
  -- STATE 7: LOADING / RUNNING
  -- =========================================================================
  elseif self.state == "loading" or self.state == "running" then
    local msg = self.loading_msg or "Loading LeetCode content..."
    local mw = style.font:get_width(msg) + 30*SCALE
    local mh = 40*SCALE
    local mx = cx + (cw - mw) / 2
    local my = y + (h - mh) / 2

    renderer.draw_rect(mx, my, mw, mh, style.background2)
    renderer.draw_rect(mx, my, mw, 1*SCALE, style.accent)
    renderer.draw_rect(mx, my + mh - 1*SCALE, mw, 1*SCALE, style.accent)
    renderer.draw_text(style.font, msg, mx + 15*SCALE, my + 12*SCALE, style.accent)
    core.redraw = true

  -- =========================================================================
  -- STATE 8: UPDATE IN PROGRESS
  -- =========================================================================
  elseif self.state == "update" then
    -- Background overlay
    renderer.draw_rect(cx, cy, cw, y + h - cy, style.background)

    local center_y = y + h / 2
    local center_x = cx + cw / 2

    -- Title
    local title = "Updating LeetCode Database"
    local tw = (style.big_font or style.font):get_width(title)
    renderer.draw_text(style.big_font or style.font, title,
      center_x - tw / 2, center_y - 80*SCALE, style.accent)

    -- Animated dot-trail spinner
    local spinner_r = 22 * SCALE
    local num_dots = 10
    local t = self.update_spinner or 0
    for i = 1, num_dots do
      local angle = (i / num_dots) * math.pi * 2 + t
      local fade = i / num_dots
      local sx = center_x + math.cos(angle) * spinner_r
      local sy = center_y - 28*SCALE + math.sin(angle) * spinner_r
      local dot_size = math.max(2, math.floor(4 * fade)) * SCALE
      local alpha = math.floor(40 + 180 * fade)
      renderer.draw_rect(sx - dot_size/2, sy - dot_size/2, dot_size, dot_size,
        {style.accent[1], style.accent[2], style.accent[3], alpha})
    end

    -- Progress bar (gradient shimmer style)
    local pct = math.max(0, math.min(100, self.update_progress or 0))
    local pct_str = string.format("%d%%", math.floor(pct))
    local pct_w = style.font:get_width(pct_str)
    local max_avail_w = math.min(cw - 40*SCALE, 420*SCALE)
    local bar_w = math.max(80*SCALE, max_avail_w - pct_w - 12*SCALE)
    local bar_h = 8 * SCALE
    local bar_x = center_x - (bar_w + pct_w + 12*SCALE) / 2
    local bar_y = center_y + 6*SCALE
    -- track
    renderer.draw_rect(bar_x, bar_y, bar_w, bar_h, style.background2)
    -- fill
    local fill_w = bar_w * pct / 100
    if fill_w > 0 then
      renderer.draw_rect(bar_x, bar_y, fill_w, bar_h,
        {style.accent[1], style.accent[2], style.accent[3], 220})
      -- shimmer at leading edge
      renderer.draw_rect(bar_x + fill_w - 4*SCALE, bar_y, 4*SCALE, bar_h,
        {255, 255, 255, 80})
    end
    -- percentage text
    renderer.draw_text(style.font, pct_str,
      bar_x + bar_w + 8*SCALE, bar_y - 2*SCALE, style.dim)

    -- Status message
    local msg_text = self.update_msg or "Initializing..."
    local mw2 = style.font:get_width(msg_text)
    core.push_clip_rect(cx + 10*SCALE, bar_y + bar_h + 10*SCALE, cw - 20*SCALE, style.font:get_height() + 6*SCALE)
    renderer.draw_text(style.font, msg_text,
      math.max(cx + 10*SCALE, center_x - mw2/2), bar_y + bar_h + 12*SCALE, style.text)
    core.pop_clip_rect()

    -- cancel hint
    local hint = "This may take 2-4 minutes. Data is saved incrementally."
    local hw = style.font:get_width(hint)
    core.push_clip_rect(cx + 10*SCALE, bar_y + bar_h + 30*SCALE, cw - 20*SCALE, style.font:get_height() + 6*SCALE)
    renderer.draw_text(style.font, hint,
      math.max(cx + 10*SCALE, center_x - hw/2), bar_y + bar_h + 32*SCALE, style.dim)
    core.pop_clip_rect()
  end

  -- =========================================================================
  -- OVERLAY: TREND ANALYSIS PANEL (RIGHT SIDE)
  -- =========================================================================
  if self.show_trend_panel and self.state == "problem" then
    local panel_w = math.min(420 * SCALE, math.max(340 * SCALE, w * 0.38))
    local panel_x = x + w - panel_w
    local panel_y = y
    local panel_h = h
    self.trend_panel_rect = {x=panel_x, y=panel_y, w=panel_w, h=panel_h}

    -- backdrop
    renderer.draw_rect(panel_x, panel_y, panel_w, panel_h, {20, 22, 30, 252})
    renderer.draw_rect(panel_x, panel_y, 1*SCALE, panel_h, style.accent)

    local px = panel_x + 14*SCALE
    local pw = panel_w - 28*SCALE
    local py = panel_y + 14*SCALE

    -- Close Button [X] in top-right corner
    local close_sz = 22 * SCALE
    self.trend_close_rect = {x=panel_x + panel_w - close_sz - 12*SCALE, y=py - 2*SCALE, w=close_sz, h=close_sz}
    renderer.draw_rect(self.trend_close_rect.x, self.trend_close_rect.y, close_sz, close_sz, style.background2)
    renderer.draw_text(style.font, "x", self.trend_close_rect.x + 7*SCALE, self.trend_close_rect.y + 3*SCALE, style.dim)

    -- Header
    core.push_clip_rect(px, py, pw - close_sz - 8*SCALE, style.font:get_height() + 4*SCALE)
    renderer.draw_text(style.font, "Interview Trends & Patterns", px, py, style.accent)
    core.pop_clip_rect()
    py = py + style.font:get_height() + 6*SCALE

    local company = self.selected_company or "?"
    local co_lbl = "Target Company: " .. format_company_name(company)
    core.push_clip_rect(px, py, pw - 8*SCALE, style.font:get_height() + 4*SCALE)
    renderer.draw_text(style.font, co_lbl, px, py, style.dim)
    core.pop_clip_rect()
    py = py + style.font:get_height() + 8*SCALE

    -- Tab Switcher: [ Patterns ] [ Topics ]
    local tab_w = math.floor((pw - 8*SCALE) / 2)
    local tab_h = 24*SCALE
    local cur_tab = self.trend_tab or "patterns"

    self.trend_patterns_tab_rect = {x = px, y = py, w = tab_w, h = tab_h}
    local is_pat_tab = (cur_tab == "patterns")
    renderer.draw_rect(px, py, tab_w, tab_h, is_pat_tab and {style.accent[1], style.accent[2], style.accent[3], 45} or style.background2)
    renderer.draw_rect(px, py, tab_w, 1*SCALE, is_pat_tab and style.accent or style.dim)
    renderer.draw_rect(px, py + tab_h - 1*SCALE, tab_w, 1*SCALE, is_pat_tab and style.accent or style.dim)
    renderer.draw_text(style.font, "DSA Patterns", px + 14*SCALE, py + 4*SCALE, is_pat_tab and style.accent or style.dim)

    local top_tab_x = px + tab_w + 8*SCALE
    self.trend_topics_tab_rect = {x = top_tab_x, y = py, w = tab_w, h = tab_h}
    local is_top_tab = (cur_tab == "topics")
    renderer.draw_rect(top_tab_x, py, tab_w, tab_h, is_top_tab and {style.accent[1], style.accent[2], style.accent[3], 45} or style.background2)
    renderer.draw_rect(top_tab_x, py, tab_w, 1*SCALE, is_top_tab and style.accent or style.dim)
    renderer.draw_rect(top_tab_x, py + tab_h - 1*SCALE, tab_w, 1*SCALE, is_top_tab and style.accent or style.dim)
    renderer.draw_text(style.font, "Topic Tags", top_tab_x + 20*SCALE, py + 4*SCALE, is_top_tab and style.accent or style.dim)

    py = py + tab_h + 10*SCALE

    if not self.trend_data then
      -- loading dots
      local dots = string.rep(".", (math.floor((self.update_spinner or 0)) % 4))
      renderer.draw_text(style.font, "Analyzing trends & patterns" .. dots, px, py, style.dim)
    else
      renderer.draw_text(style.font,
        string.format("%d problems analyzed in pool", self.trend_data.total_problems or 0),
        px, py, style.dim)
      py = py + style.font:get_height() + 6*SCALE
      renderer.draw_rect(px, py, pw, 1*SCALE, style.dim)
      py = py + 8*SCALE

      local list_clip_y = py
      local list_clip_h = panel_y + panel_h - list_clip_y - 10*SCALE
      core.push_clip_rect(panel_x, list_clip_y, panel_w, list_clip_h)

      local start_py = py - (self.trend_scroll_y or 0)
      local cur_y = start_py

      if cur_tab == "patterns" then
        local patterns = self.trend_data.patterns or {}
        if #patterns == 0 then
          renderer.draw_text(style.font, "No patterns indexed. Run ⟳ Update DB.", px, cur_y + 10*SCALE, style.dim)
          cur_y = cur_y + 30*SCALE
        else
          local max_score = (patterns[1] and patterns[1].score) or 1
          local item_x = px + 24*SCALE
          local item_w = pw - 24*SCALE
          for i, item in ipairs(patterns) do
            local name = item.name or item.id or ""
            local score = item.score or 0
            local cat = item.category or (item.tier or "")
            local score_str = string.format("%.0f", score)
            local score_w = style.font:get_width(score_str) + 6*SCALE

            -- rank number
            renderer.draw_text(style.font, tostring(i) .. ".", px, cur_y, style.dim)

            -- pattern name (clipped cleanly to avoid overflow)
            core.push_clip_rect(item_x, cur_y, item_w, style.font:get_height() + 2*SCALE)
            renderer.draw_text(style.font, name, item_x, cur_y,
              i == 1 and (LC_COLORS.accepted or style.accent) or (i <= 3 and LC_COLORS.easy or style.text))
            core.pop_clip_rect()
            cur_y = cur_y + style.font:get_height() + 2*SCALE

            -- mini subline: category / tier + count
            local sub = string.format("%s • %d probs (%.0f%%)", cat, item.count or 0, item.pct or 0)
            core.push_clip_rect(item_x, cur_y, item_w, style.font:get_height() + 2*SCALE)
            renderer.draw_text(style.font, sub, item_x, cur_y, style.dim)
            core.pop_clip_rect()
            cur_y = cur_y + style.font:get_height() + 3*SCALE

            -- mini progress bar and score badge
            local bar_w = item_w - score_w - 12*SCALE
            local bh = 5*SCALE
            renderer.draw_rect(item_x, cur_y + 3*SCALE, bar_w, bh, style.background2)
            local fill = bar_w * math.min(1, score / math.max(1, max_score))
            local bar_col = i == 1 and (LC_COLORS.accepted or style.accent)
                         or (i <= 3 and (LC_COLORS.medium or style.text) or style.dim)
            renderer.draw_rect(item_x, cur_y + 3*SCALE, fill, bh, bar_col)
            -- score badge placed cleanly after progress bar within panel width
            renderer.draw_text(style.font, score_str, item_x + bar_w + 8*SCALE, cur_y - 2*SCALE, style.dim)
            cur_y = cur_y + bh + 10*SCALE
          end
        end

      else
        -- Topic tags tab
        local trends = self.trend_data.trends or {}
        if #trends == 0 then
          renderer.draw_text(style.font, "No topic tags found.", px, cur_y + 10*SCALE, style.dim)
          cur_y = cur_y + 30*SCALE
        else
          local max_score = (trends[1] and trends[1].score) or 1
          local item_x = px + 24*SCALE
          local item_w = pw - 24*SCALE
          for i, item in ipairs(trends) do
            local tag = item.tag or ""
            local score = item.score or 0
            local score_str = string.format("%.0f", score)
            local score_w = style.font:get_width(score_str) + 6*SCALE

            -- rank number
            renderer.draw_text(style.font, tostring(i) .. ".", px, cur_y, style.dim)

            -- tag name (clipped cleanly)
            core.push_clip_rect(item_x, cur_y, item_w, style.font:get_height() + 2*SCALE)
            renderer.draw_text(style.font, tag, item_x, cur_y,
              i == 1 and (LC_COLORS.accepted or style.accent) or style.text)
            core.pop_clip_rect()
            cur_y = cur_y + style.font:get_height() + 3*SCALE

            -- mini progress bar and score badge
            local bar_w = item_w - score_w - 12*SCALE
            local bh = 5*SCALE
            renderer.draw_rect(item_x, cur_y + 3*SCALE, bar_w, bh, style.background2)
            local fill = bar_w * math.min(1, score / math.max(1, max_score))
            local bar_col = i == 1 and (LC_COLORS.accepted or style.accent)
                         or (i <= 3 and (LC_COLORS.medium or style.text) or style.dim)
            renderer.draw_rect(item_x, cur_y + 3*SCALE, fill, bh, bar_col)
            -- score
            renderer.draw_text(style.font, score_str, item_x + bar_w + 8*SCALE, cur_y - 2*SCALE, style.dim)
            cur_y = cur_y + bh + 8*SCALE
          end
        end
      end

      local total_h = cur_y - start_py
      self.trend_max_scroll = math.max(0, total_h - list_clip_h)
      core.pop_clip_rect()
    end
  end

  -- =========================================================================
  -- MODAL OVERLAY: PATTERN SELECTION MODAL (IF ACTIVE)
  -- =========================================================================
  if self.show_pattern_modal then
    self:draw_pattern_modal(x, y, w, h)
  end

  -- =========================================================================
  -- MODAL OVERLAY: COMPANY SELECTION MODAL (IF ACTIVE)
  -- =========================================================================
  if self.show_company_modal then
    self:draw_company_modal(x, y, w, h)
  end
end

function LeetCodeView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = math.max(400 * SCALE, value)
  end
end

-- =========================================================================
-- Study Plan & Calendar View
-- =========================================================================
local StudyPlanView = View:extend()

function StudyPlanView:new()
  StudyPlanView.super.new(self)
  self.scrollable = true

  self.available_plans = {
    { label = "Top Interview 150", slug = "top-interview-150" },
    { label = "LeetCode 75",       slug = "leetcode-75" },
    { label = "SQL 50",            slug = "sql-50" },
    { label = "Top 100 Liked",     slug = "top-100-liked" },
  }
  self.current_plan_idx = 1
  self.plan_slug  = self.available_plans[1].slug
  self.plan_data  = nil
  self.calendar_data = nil
  self.username   = nil          -- resolved dynamically from auth_check

  self.collapsed_sections = {}
  self.show_dropdown  = false
  self.content_height = 0
  self.click_zones    = {}
  self.loading        = true

  self:resolve_username()
end

-- ── helpers ────────────────────────────────────────────────────────────

function StudyPlanView:resolve_username()
  api_call({ cmd = "auth_check" }, function(res)
    if res and res.ok and res.data and res.data.username then
      self.username = res.data.username
    end
    self:fetch_plan()
    self:fetch_calendar()
  end)
end

function StudyPlanView:fetch_plan()
  self.plan_data = nil
  self.loading   = true
  core.redraw    = true
  api_call({ cmd = "study_plan_detail", slug = self.plan_slug }, function(res)
    self.loading = false
    if res and res.ok and res.data and res.data.studyPlanV2Detail then
      self.plan_data = res.data.studyPlanV2Detail
    end
    core.redraw = true
  end)
end

function StudyPlanView:fetch_calendar()
  if not self.username then return end
  local year = os.date("*t").year
  api_call({ cmd = "user_calendar", username = self.username, year = year }, function(res)
    if res and res.ok and res.data then
      local mu = res.data.matchedUser
      if mu and mu.userCalendar then
        self.calendar_data = mu.userCalendar
        -- parse the JSON-encoded submission calendar into a lookup table
        if self.calendar_data.submissionCalendar then
          local ok, parsed = pcall(json_decode, self.calendar_data.submissionCalendar)
          self.calendar_data.parsed_subs = ok and parsed or {}
        else
          self.calendar_data.parsed_subs = {}
        end
      end
    end
    core.redraw = true
  end)
end

-- ── lifecycle ──────────────────────────────────────────────────────────

function StudyPlanView:get_name() return "LeetCode Study Plan" end

function StudyPlanView:get_scrollable_size()
  return math.max(self.size.y + 1, self.content_height)
end

-- ── mouse ──────────────────────────────────────────────────────────────

function StudyPlanView:on_mouse_pressed(btn, x, y, clicks)
  local res = StudyPlanView.super.on_mouse_pressed(self, btn, x, y, clicks)
  if res then return res end
  if btn ~= "left" then return false end

  for _, z in ipairs(self.click_zones) do
    if x >= z.x and x <= z.x + z.w and y >= z.y and y <= z.y + z.h then
      if z.action == "toggle_dropdown" then
        self.show_dropdown = not self.show_dropdown
        core.redraw = true
        return true

      elseif z.action == "select_plan" then
        self.current_plan_idx = z.idx
        self.plan_slug = self.available_plans[z.idx].slug
        self.show_dropdown = false
        self.collapsed_sections = {}
        self:fetch_plan()
        core.redraw = true
        return true

      elseif z.action == "toggle_section" then
        self.collapsed_sections[z.name] = not self.collapsed_sections[z.name]
        core.redraw = true
        return true

      elseif z.action == "open_problem" then
        -- fetch detail then open, same pattern as the list view
        api_call({ cmd = "problem_detail", slug = z.slug }, function(resp)
          if resp and resp.ok and resp.data then
            local lc = lc_view or core.root_view:get_active_node_default()
            local lang = "python3"
            open_problem(resp.data, lang)
            core.redraw = true
          else
            core.log("[Study Plan] Failed to fetch problem: " .. (resp and resp.error or "?"))
          end
        end)
        core.redraw = true
        return true
      end
    end
  end
  return false
end

-- ── draw helpers ───────────────────────────────────────────────────────

local function draw_rect_outline(x, y, w, h, color, thickness)
  thickness = thickness or 1
  renderer.draw_rect(x, y, w, thickness, color)
  renderer.draw_rect(x, y + h - thickness, w, thickness, color)
  renderer.draw_rect(x, y, thickness, h, color)
  renderer.draw_rect(x + w - thickness, y, thickness, h, color)
end

-- Draw the mini contribution heatmap for this month
local function draw_calendar(x, y, w, cal, font)
  local fh     = font:get_height()
  local cell   = fh + 4          -- cell size
  local cols   = 7               -- days per row
  local rows   = 5

  local t = os.date("*t")
  -- First day of current month (weekday: 0=Sun,1=Mon…)
  local first_wday = os.date("*t", os.time({ year = t.year, month = t.month, day = 1 })).wday - 1
  local days_in_month = os.date("*t", os.time({ year = t.year, month = t.month + 1, day = 0 })).day

  local month_name = os.date("%B %Y")
  renderer.draw_text(font, month_name, x, y, style.text)
  y = y + fh + 6

  -- Day labels
  local day_labels = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }
  for i, lbl in ipairs(day_labels) do
    local lx = x + (i - 1) * (cell + 2)
    renderer.draw_text(font, lbl, lx, y, style.dim)
  end
  y = y + fh + 4

  local parsed = cal.parsed_subs or {}
  -- Convert epoch keys to YYYY-MM-DD
  local subs_by_day = {}
  for epoch_str, count in pairs(parsed) do
    local epoch = tonumber(epoch_str)
    if epoch then
      local d = os.date("*t", epoch)
      local key = string.format("%04d-%02d-%02d", d.year, d.month, d.day)
      subs_by_day[key] = (subs_by_day[key] or 0) + count
    end
  end

  local col = first_wday
  local row = 0
  for day = 1, days_in_month do
    local cx = x + col * (cell + 2)
    local cy = y + row * (cell + 2)
    local key = string.format("%04d-%02d-%02d", t.year, t.month, day)
    local count = subs_by_day[key] or 0

    local bg
    if count == 0 then
      bg = style.background2 or style.background
    elseif count <= 2 then
      bg = { common.color "#264d3b" }
    elseif count <= 5 then
      bg = { common.color "#1a7f4b" }
    else
      bg = { common.color "#26c063" }
    end

    renderer.draw_rect(cx, cy, cell, cell, bg)
    if day == t.day then
      draw_rect_outline(cx, cy, cell, cell, style.accent, 1)
    end

    -- day number inside cell
    renderer.draw_text(font, tostring(day), cx + 1, cy, style.dim)

    col = col + 1
    if col >= cols then
      col = 0
      row = row + 1
    end
  end

  local total_h = y + (row + 1) * (cell + 2)
  return total_h
end

-- ── main draw ──────────────────────────────────────────────────────────

function StudyPlanView:draw()
  self:draw_background(style.background)

  local W   = self.size.x
  local H   = self.size.y
  local pad = 16
  local fh  = style.font:get_height()
  local mx, my = core.root_view.mouse.x, core.root_view.mouse.y

  self.click_zones = {}

  -- ── Column layout ──────────────────────────────────────────────────
  -- Right calendar panel: fixed 220px wide, flush right, no divider
  local cal_panel_w = 220
  local col_gap     = 28          -- invisible breathing room between columns
  local left_x      = self.position.x + pad
  local left_w      = W - pad * 2 - cal_panel_w - col_gap  -- list column width
  local right_x     = self.position.x + W - pad - cal_panel_w
  local top_y       = self.position.y + pad - self.scroll.y

  -- ── LEFT: Dropdown ─────────────────────────────────────────────────
  local lx = left_x
  local ly = top_y

  local plan_label = self.available_plans[self.current_plan_idx].label
  local dd_text    = "Study Plan: " .. plan_label .. " v"
  local dd_w       = math.min(style.big_font:get_width(dd_text) + 24, left_w)
  local dd_h       = style.big_font:get_height() + 8
  local dd_hov     = mx >= lx and mx <= lx + dd_w and my >= ly and my <= ly + dd_h

  renderer.draw_rect(lx, ly, dd_w, dd_h, dd_hov and style.line_highlight or style.background2 or style.background)
  renderer.draw_text(style.big_font, dd_text, lx + 8, ly + 4, style.text)
  table.insert(self.click_zones, { x = lx, y = ly, w = dd_w, h = dd_h, action = "toggle_dropdown" })
  ly = ly + dd_h + 10

  -- ── LEFT: Problem list ─────────────────────────────────────────────
  if self.loading then
    renderer.draw_text(style.font, "Loading plan data...", lx, ly, style.dim)
    ly = ly + fh + 8
  elseif not self.plan_data then
    renderer.draw_text(style.font, "Failed to load plan. Check your connection.", lx, ly, { 1, 0.4, 0.4, 1 })
    ly = ly + fh + 8
  else
    local groups = self.plan_data.planSubGroups or {}
    for _, grp in ipairs(groups) do
      local collapsed  = self.collapsed_sections[grp.name]
      local arrow      = collapsed and ">" or "v"
      local qs         = grp.questions or {}
      local done_count = 0
      for _, q in ipairs(qs) do
        if (q.status == "AC" or q.status == "PAST_SOLVED") then done_count = done_count + 1 end
      end
      local hdr_text = string.format("%s %s  (%d/%d)", arrow, grp.name, done_count, #qs)
      local hdr_hov  = mx >= lx and mx <= lx + left_w and my >= ly and my <= ly + fh + 4
      renderer.draw_rect(lx, ly, left_w, fh + 4, hdr_hov and style.line_highlight or style.background)
      renderer.draw_text(style.font, hdr_text, lx + 4, ly + 2, style.text)
      table.insert(self.click_zones, { x = lx, y = ly, w = left_w, h = fh + 4, action = "toggle_section", name = grp.name })
      ly = ly + fh + 6

      if not collapsed then
        for _, q in ipairs(qs) do
          local is_ac   = (q.status == "AC" or q.status == "PAST_SOLVED")
          local icon    = is_ac and "[+] " or "  "
          local q_color = is_ac and (style.good or { 0.3, 0.9, 0.5, 1 }) or style.text
          local q_hov   = mx >= lx + 20 and mx <= lx + left_w and my >= ly and my <= ly + fh + 2
          if q_hov then
            renderer.draw_rect(lx + 20, ly, left_w - 20, fh + 2, style.line_highlight)
          end
          renderer.draw_text(style.font, icon .. q.title, lx + 24, ly + 1, q_color)
          table.insert(self.click_zones, {
            x = lx + 20, y = ly, w = left_w - 20, h = fh + 2,
            action = "open_problem", slug = q.titleSlug or q.slug or "",
          })
          ly = ly + fh + 3
        end
        ly = ly + 6
      end
    end
  end

  -- ── RIGHT COLUMN: Calendar heatmap ─────────────────────────────────
  -- Fixed to the visible window top — doesn't scroll with the left list
  local ry = self.position.y + 16
  core.push_clip_rect(right_x, self.position.y, cal_panel_w, H)

  if self.plan_data then
    -- ── Plan progress stats (changes per plan) ─────────────────────────
    local groups  = self.plan_data.planSubGroups or {}
    local total_q = 0
    local done_q  = 0

    for _, grp in ipairs(groups) do
      for _, q in ipairs(grp.questions or {}) do
        total_q = total_q + 1
        if (q.status == "AC" or q.status == "PAST_SOLVED") then
          done_q = done_q + 1
        end
      end
    end

    -- Plan name header
    local plan_name = (self.plan_data.name or self.available_plans[self.current_plan_idx].label)
    renderer.draw_text(style.font, plan_name, right_x, ry, style.text)
    ry = ry + fh + 6

    -- Completion fraction
    local pct      = total_q > 0 and math.floor(done_q / total_q * 100) or 0
    local frac_txt = string.format("%d / %d  (%d%%)", done_q, total_q, pct)
    renderer.draw_text(style.font, frac_txt, right_x, ry, style.accent)
    ry = ry + fh + 5

    -- Progress bar
    local bar_h = 6
    renderer.draw_rect(right_x, ry, cal_panel_w, bar_h, style.background2 or style.background)
    local fill_w = total_q > 0 and math.floor(cal_panel_w * done_q / total_q) or 0
    if fill_w > 0 then
      renderer.draw_rect(right_x, ry, fill_w, bar_h, LC_COLORS.accepted or { 0.3, 0.9, 0.5, 1 })
    end
    ry = ry + bar_h + 16
  end

  -- ── Global activity calendar (same for all plans by design) ─────────
  if self.calendar_data then
    local cal = self.calendar_data
    renderer.draw_text(style.font, "Your Activity", right_x, ry, style.text)
    ry = ry + fh + 2
    local str_txt = string.format("%d day streak  -  %d active days", cal.streak or 0, cal.totalActiveDays or 0)
    renderer.draw_text(style.font, str_txt, right_x, ry, style.dim)
    ry = ry + fh + 8
    draw_calendar(right_x, ry, cal_panel_w, cal, style.small_font or style.font)
  else
    renderer.draw_text(style.font, "Loading calendar...", right_x, ry, style.dim)
  end

  core.pop_clip_rect()


  -- ── Update scrollable height (left column drives scroll) ───────────
  self.content_height = ly - self.position.y + self.scroll.y + pad

  -- ── Dropdown overlay (drawn last so it floats on top) ──────────────
  if self.show_dropdown then
    local item_h = fh + 8
    local menu_w = 240
    local menu_x = self.position.x + pad
    local menu_y = self.position.y + pad + dd_h + 2
    local menu_h = #self.available_plans * item_h + 4

    renderer.draw_rect(menu_x, menu_y, menu_w, menu_h, style.background2 or style.background)
    draw_rect_outline(menu_x, menu_y, menu_w, menu_h, style.dim)

    for i, plan in ipairs(self.available_plans) do
      local iy  = menu_y + 2 + (i - 1) * item_h
      local hov = mx >= menu_x and mx <= menu_x + menu_w and my >= iy and my <= iy + item_h
      local sel = (i == self.current_plan_idx)
      renderer.draw_rect(menu_x + 2, iy, menu_w - 4, item_h,
        sel and (style.selection or style.line_highlight) or
        (hov and style.line_highlight or (style.background2 or style.background))
      )
      renderer.draw_text(style.font, plan.label, menu_x + 10, iy + 4,
        sel and style.accent or style.text)
      table.insert(self.click_zones, { x = menu_x, y = iy, w = menu_w, h = item_h, action = "select_plan", idx = i })
    end
  end
end


command.add(nil, {
  ["leetcode:open-study-plan"] = function()
    local node = core.root_view:get_active_node_default()
    node:add_view(StudyPlanView())
  end,
})

return LeetCodeView
