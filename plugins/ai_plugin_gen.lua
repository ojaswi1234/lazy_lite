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
local PLUGIN_DIR = USERDIR .. "/plugins"
local STORE_FILE = USERDIR .. "/ai_plugin_gen_store.lua"
local TEMP_DIR   = USERDIR .. "/tempfiles"
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
rawset(_G, "ai_plugin_gen_resume_fn", nil)
rawset(_G, "auto_healer_new_plugins", rawget(_G, "auto_healer_new_plugins") or {})

-- ── Persistent store ──────────────────────────────────────────────────────────
local store = { installed = {}, rejected_hashes = {} }

local function save_store()
  local fp = io.open(STORE_FILE, "w")
  if not fp then return end
  fp:write("return {\n  installed = {\n")
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
    os.execute(PLATFORM == "Windows"
      and ('mkdir "' .. TEMP_DIR:gsub("/","\\") .. '"')
      or  ('mkdir -p "' .. TEMP_DIR .. '"'))
  end
end

local function c(r, g, b, a) return {r, g, b, a or 255} end

local function lerp_color(a, b, t)
  return { math.floor(a[1]+(b[1]-a[1])*t), math.floor(a[2]+(b[2]-a[2])*t),
           math.floor(a[3]+(b[3]-a[3])*t), 255 }
end

local function wrap_text(font, text, max_w)
  local lines = {}
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    if raw == "" then
      table.insert(lines, "")
    else
      local cur = ""
      for word in raw:gmatch("%S+") do
        local test = cur == "" and word or (cur .. " " .. word)
        if font:get_width(test) <= max_w then cur = test
        else
          if cur ~= "" then table.insert(lines, cur) end
          cur = word
        end
      end
      if cur ~= "" then table.insert(lines, cur) end
    end
  end
  return lines
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
    files      = files,
    raw        = text,
  }
end

-- ── AGY runner ────────────────────────────────────────────────────────────────
local function run_agy(prompt, on_done)
  ensure_tempdir()
  -- Write prompt to temp file to avoid shell argument length limits
  local tmp = TEMP_DIR .. "/ai_plugin_gen_prompt.txt"
  local fp  = io.open(tmp, "w")
  if fp then fp:write(prompt); fp:close() end

  -- Read and inline the prompt (agy uses -p flag)
  local p, err = process.start(
    { agy_path(), "-p", prompt, "--dangerously-skip-permissions" },
    { stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_PIPE, stderr=process.REDIRECT_PIPE }
  )
  if not p then on_done(nil, "Failed to start agy: " .. tostring(err)); return end

  local buf = ""
  core.add_thread(function()
    local deadline = system.get_time() + 240
    while p:returncode() == nil do
      local ch = p:read_stdout(4096) or ""
      if #ch > 0 then buf = buf .. ch end
      if system.get_time() > deadline then
        pcall(function() p:kill() end)
        on_done(nil, "AGY timed out after 4 minutes"); return
      end
      coroutine.yield(0.1)
    end
    while true do local c2=p:read_stdout(4096) or ""; if c2=="" then break end; buf=buf..c2 end
    on_done(buf, nil)
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
  renderer.draw_text(style.font, val.."/10", x + w + sp(8), y, style.text)
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
  renderer.draw_text(font, "Describe a plugin idea and AGY will think, research and plan it for you.", cx, cy, style.dim)
  cy = cy + fh + sp(16)

  -- Input display box
  local inp_w = w - pad*2
  local inp_h = sp(120)
  renderer.draw_rect(cx, cy, inp_w, inp_h, style.background2 or c(50,50,50))

  self.doc_view.position.x = cx + sp(12)
  self.doc_view.position.y = cy + sp(12)
  self.doc_view.size.x = inp_w - sp(24)
  self.doc_view.size.y = inp_h - sp(24)
  
  core.push_clip_rect(cx, cy, inp_w, inp_h)
  self.doc_view:draw()
  local txt = self.doc:get_text(1, 1, math.huge, math.huge)
  if txt == "\n" or txt == "" then
    draw_icon_text(font, "\u{f040}  Describe your plugin here...", cx + sp(12), cy + sp(12), style.dim)
  end
  core.pop_clip_rect()

  self.input_rect = {x=cx, y=cy, w=inp_w, h=inp_h}
  cy = cy + inp_h + sp(12)

  -- Buttons row
  local bh = sp(32)
  local bw_gen = w - pad*2
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
      renderer.draw_rect(cx, cy+rh/2-sp(4), sp(8), sp(8), exists and c(70,200,70) or c(200,70,70))
      renderer.draw_text(font, plug.name or "?", cx+sp(16), cy+(rh-fh)/2, style.text)

      local dw,ow = sp(64), sp(64)
      local del_x = x + w - pad - dw
      local opn_x = del_x - ow - sp(4)
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
  local title = mode=="planning" and "\u{f0e7}  AGY THINKING..." or "\u{f0e7}  AGY BUILDING..."
  renderer.draw_text(style.font, spin, cx, cy+(bfh-fh)/2, pc)
  draw_icon_text(style.big_font or style.font, title, cx+sp(24), cy, style.accent)
  cy = cy + bfh + sp(18)

  -- Progress bar
  local n_done = mode=="planning"
    and math.min(#PLAN_STEPS, math.floor(elapsed/2))
    or math.min(#BUILD_STEPS, self.build_step or 0)
  local pct = math.min(0.97, n_done / #steps + (elapsed % 2.0) / (2.0 * #steps))
  local bar_w = inner_w
  renderer.draw_rect(cx, cy, bar_w, sp(6), style.background3 or c(50,50,50))
  renderer.draw_rect(cx, cy, math.floor(bar_w*pct), sp(6), pc)
  renderer.draw_text(style.font, ("%.0f%%"):format(pct*100), cx+bar_w+sp(6), cy-sp(2), pc)
  cy = cy + sp(24)

  -- Checklist
  for i, step in ipairs(steps) do
    local step_elapsed = elapsed - (i-1) * (mode=="planning" and 2.0 or 5.0)
    local done   = step_elapsed > 1.5
    local active = (not done) and step_elapsed > 0
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

  -- ── Scrollable content ──
  local content_h = h - bar_h
  core.push_clip_rect(x, y, w, content_h)

  local cw   = w - pad*2
  local ry   = y - self.plan_scroll + pad
  local total = 0
  local function section(draw_fn, est_h)
    if ry+est_h > y and ry < y+content_h then draw_fn(x, ry, w, cw) end
    ry = ry + est_h; total = total + est_h
  end

  -- Name + overview
  section(function(sx, sy)
    draw_icon_text(bfont, "\u{f0e7} "..plan.name, sx+pad, sy, style.accent)
    sy = sy + bfh + sp(4)
    for _, ln in ipairs(wrap_text(font, plan.overview, cw)) do
      renderer.draw_text(font, ln, sx+pad, sy, style.text); sy = sy + fh+sp(2)
    end
  end, bfh + math.max(1,#wrap_text(font,plan.overview,cw))*(fh+sp(2)) + pad)

  -- Complexity / Time / Worth
  section(function(sx, sy)
    renderer.draw_rect(sx+pad, sy, cw, sp(1), style.divider or c(70,70,70)); sy = sy+pad+sp(4)
    sy = section_header("\u{f080}  Complexity  ·  Time  ·  Worth", sx+pad, sy)
    local ny = complexity_bar(sx+pad, sy, cw*0.5, plan.complexity)
    draw_icon_text(font, "\u{f017}  "..plan.time_est, sx+pad+cw*0.55, sy, style.text)
    sy = ny + sp(8)
    local wcol = plan.worth=="Recommended" and c(80,200,80) or
                 plan.worth=="Overkill"     and c(200,80,80) or c(220,180,50)
    draw_icon_text(font, "\u{f0eb}  Worth making?  " .. plan.worth, sx+pad, sy, wcol)
    sy = sy + fh+sp(8)
    draw_icon_text(font, "\u{f187}  Dependencies: " .. plan.deps, sx+pad, sy, style.text)
  end, pad + fh + fh + fh + fh + sp(24))

  -- Research
  if #plan.research > 0 then
    section(function(sx, sy)
      renderer.draw_rect(sx+pad, sy, cw, sp(1), style.divider or c(70,70,70)); sy=sy+pad+sp(4)
      sy = section_header("\u{f0ac}  Research Findings", sx+pad, sy, style.dim)
      for _, r in ipairs(plan.research) do
        draw_icon_text(font, "\u{f111}", sx+pad+sp(4), sy, style.dim)
        for _, ln in ipairs(wrap_text(font, r, cw-sp(24))) do
          renderer.draw_text(font, ln, sx+pad+sp(24), sy, style.text); sy=sy+fh+sp(4)
        end
        sy=sy+sp(4)
      end
    end, pad + fh + #plan.research*(fh+sp(6)) + pad)
  end

  -- Challenges
  for _, cs in ipairs({
    {key="fatal",   label="\u{f057}  Fatal Challenges",    col=c(220,80,80)},
    {key="conquer", label="\u{f071}  Conquerable Challenges", col=c(220,160,50)},
    {key="easy",    label="\u{f058}  Easy Wins",            col=c(80,200,80)},
  }) do
    local items = plan[cs.key]
    if items and #items > 0 then
      local _cs = cs; local _items = items
      section(function(sx, sy)
        renderer.draw_rect(sx+pad, sy, cw, sp(1), style.divider or c(70,70,70)); sy=sy+pad+sp(4)
        sy = section_header(_cs.label, sx+pad, sy, _cs.col)
        for _, it in ipairs(_items) do
          draw_icon_text(font, "\u{f0da}", sx+pad+sp(4), sy, style.dim)
          for _, ln in ipairs(wrap_text(font, it, cw-sp(24))) do
            renderer.draw_text(font, ln, sx+pad+sp(24), sy, style.text); sy=sy+fh+sp(4)
          end
          sy=sy+sp(4)
        end
      end, pad + fh + #_items*(fh+sp(6)) + pad)
    end
  end

  -- Sample Design (ASCII art)
  if plan.design ~= "" then
    local design_lines = {}
    for ln in (plan.design.."\n"):gmatch("([^\n]*)") do table.insert(design_lines, ln) end
    local design_box_h = #design_lines*(cfh+sp(2)) + sp(20)
    section(function(sx, sy)
      renderer.draw_rect(sx+pad, sy, cw, sp(1), style.divider or c(70,70,70)); sy=sy+pad+sp(4)
      -- Header + redesign button
      sy = section_header("\u{f1fb}  Sample Design Preview", sx+pad, sy, style.dim)
      local rdw, rdh = sp(100), fh+sp(6)
      local rdx = sx+w-pad-rdw
      local hov_rd = self.hovered == "redesign"
      draw_btn(rdx, sy-sp(2)-fh, rdw, rdh, "\u{f021} Redesign", hov_rd)
      table.insert(self.buttons, {x=rdx, y=sy-sp(2)-fh, w=rdw, h=rdh, id="redesign"})
      -- Design box
      renderer.draw_rect(sx+pad, sy, cw, design_box_h, style.background2 or c(40,40,40))
      local dy = sy + sp(10)
      for _, ln in ipairs(design_lines) do
        renderer.draw_text(cf, ln, sx+pad+sp(10), dy, style.accent); dy=dy+cfh+sp(2)
      end
    end, pad + fh + sp(8) + design_box_h + pad)
  end

  -- Keyboard shortcuts with conflict checker
  if #plan.shortcuts > 0 then
    local used = {}
    for _, bindings in pairs(keymap.map) do
      local blist = type(bindings)=="table" and bindings or {bindings}
      for _, k in ipairs(blist) do used[k:lower()]=true end
    end
    section(function(sx, sy)
      renderer.draw_rect(sx+pad, sy, cw, sp(1), style.divider or c(70,70,70)); sy=sy+pad+sp(4)
      sy = section_header("\u{f11c}  Suggested Shortcuts  (green = free, red = clash)", sx+pad, sy, style.dim)
      for _, sc in ipairs(plan.shortcuts) do
        local clash = used[sc.key:lower()]
        local scol  = clash and c(220,80,80) or c(80,200,80)
        local status = clash and "\u{f057} Clash" or "\u{f058} Free"
        renderer.draw_text(cf, sc.key, sx+pad, sy, style.accent)
        renderer.draw_text(font, sc.desc, sx+pad+sp(200), sy, style.text)
        draw_icon_text(font, status, sx+pad+cw-sp(80), sy, scol)
        sy=sy+fh+sp(4)
      end
    end, pad + fh + #plan.shortcuts*(fh+sp(4)) + pad)
  end

  -- API hooks used
  if #plan.hooks > 0 then
    section(function(sx, sy)
      renderer.draw_rect(sx+pad, sy, cw, sp(1), style.divider or c(70,70,70)); sy=sy+pad+sp(4)
      sy = section_header("\u{f1e6}  Lite XL API Hooks Required", sx+pad, sy, style.dim)
      local hx = sx+pad
      for _, hook in ipairs(plan.hooks) do
        local hw = cf:get_width(hook)+sp(12)
        renderer.draw_rect(hx, sy, hw, cfh+sp(6), style.background3 or c(50,50,50))
        renderer.draw_text(cf, hook, hx+sp(6), sy+sp(3), style.accent)
        hx = hx + hw + sp(6)
        if hx + sp(100) > sx+w-pad then hx=sx+pad; sy=sy+cfh+sp(10) end
      end
      sy = sy + cfh + sp(10)
    end, pad + fh + sp(8) + math.ceil(#plan.hooks/4)*(cfh+sp(10)) + pad)
  end

  -- Testing strategy
  if #plan.testing > 0 then
    section(function(sx, sy)
      renderer.draw_rect(sx+pad, sy, cw, sp(1), style.divider or c(70,70,70)); sy=sy+pad+sp(4)
      sy = section_header("\u{f0c3}  Testing Strategy", sx+pad, sy, style.dim)
      for _, t2 in ipairs(plan.testing) do
        draw_icon_text(font, "\u{f00c}  "..t2, sx+pad+sp(12), sy, style.text); sy=sy+fh+sp(6)
      end
    end, pad + fh + #plan.testing*(fh+sp(6)) + pad)
  end

  -- Output files
  if #plan.files > 0 then
    section(function(sx, sy)
      renderer.draw_rect(sx+pad, sy, cw, sp(1), style.divider or c(70,70,70)); sy=sy+pad+sp(4)
      sy = section_header("\u{f07b}  Files That Will Be Created", sx+pad, sy, style.dim)
      for _, f in ipairs(plan.files) do
        draw_icon_text(cf, "\u{f15b}  "..f, sx+pad+sp(12), sy, style.accent); sy=sy+cfh+sp(6)
      end
    end, pad + fh + #plan.files*(cfh+sp(6)) + pad)
  end

  self.plan_total_h = total + pad
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
  return true
end

-- ── Input handling ────────────────────────────────────────────────────────────
function AIPluginGen:on_mouse_moved(mx, my, dx, dy)
  if self.state == STATE.DESCRIBE then self.doc_view:on_mouse_moved(mx, my, dx, dy) end
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
  if button ~= "left" then return false end
  
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

-- ── Button actions ────────────────────────────────────────────────────────────
function AIPluginGen:handle_click(id)
  if id == "generate" then
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
  end
end

-- ── AI actions ────────────────────────────────────────────────────────────────

function AIPluginGen:do_generate_plan()
  self.state = STATE.LOADING
  self.loading_start = system.get_time()
  self.error_msg = nil
  core.redraw = true
  local user_input = self.doc:get_text(1, 1, math.huge, math.huge)

  local rejected_note = ""
  local rkeys = {}
  for h in pairs(store.rejected_hashes) do table.insert(rkeys, h) end
  if #rkeys > 0 then
    rejected_note = "Do NOT regenerate plans similar to these rejected approach hashes: " .. table.concat(rkeys, ", ") .. "\n"
  end

  local prompt = ([[
You are creating a plugin development plan for the Lite XL text editor.
User request: "%s"
%s
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
]]):format(user_input, rejected_note)

  run_agy(prompt, function(out, err)
    if err or not out or #out < 30 then
      self.state = STATE.ERROR
      self.error_msg = err or "AGY returned no output"
      pcall(command.perform, "antigravity:submit",
        "[AI Plugin Gen] Plan generation failed: " .. tostring(err))
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
  run_agy(prompt, function(out, err)
    if err or not out then return end
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

  local prompt = ([[
Write a COMPLETE, WORKING Lite XL plugin in Lua.

Plugin name:  %s
Overview:     %s
Complexity:   %d/10
Dependencies: %s
API hooks:    %s
Output files: %s

Rules:
1. First line MUST be: -- mod-version:3
2. Add a descriptive header comment
3. Use proper Lite XL APIs (core, style, command, keymap, renderer)
4. Wrap risky code in pcall
5. Register commands and keyboard shortcuts
6. Plugin must work immediately after being placed in plugins/ dir

Shortcut hints:
%s

Output the COMPLETE Lua source between [PLUGIN_CODE] and [/PLUGIN_CODE] tags ONLY.

[PLUGIN_CODE]
-- write complete plugin code here
[/PLUGIN_CODE]
]]):format(plan.name, plan.overview, plan.complexity, plan.deps,
    table.concat(plan.hooks,", "), table.concat(plan.files,", "), sc_hints)

  self.build_step = 1

  run_agy(prompt, function(out, err)
    if err or not out then
      self.state = STATE.ERROR
      self.error_msg = err or "AGY returned no output"
      -- Tell auto-healer and set resume function
      _G.ai_plugin_gen_resume_fn = function() self:do_build() end
      pcall(command.perform, "antigravity:submit",
        "[AI Plugin Gen] Build failed: " .. tostring(err) ..
        "\nFix the issue and then call _G.ai_plugin_gen_resume_fn() to resume.")
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
    local filepath = USERDIR .. "/" .. filename

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
        node:set_active_view(plugin_view)
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
  end
})

-- ── Auto-healer: aware of new plugins ────────────────────────────────────────
-- The auto_healer checks _G.auto_healer_new_plugins for context.
-- Also expose a public resume signal for the healer to call back into.
core.log("[AI Plugin Gen] Loaded — use 'ai-plugin-gen:toggle' or Activity Bar \u{f0e7} to start.")
