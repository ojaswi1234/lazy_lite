-- mod-version:3
-- Auto-Healer plugin: Intercepts editor errors and delegates them to the Antigravity AI sidebar.
-- Also detects specific known failure patterns (e.g. agy CLI not set up) and auto-heals them.

local core    = require "core"
local command = require "core.command"
local process = require "process"
local system  = require "system"
local style   = require "core.style"

-- ── Visual Overlay State ──────────────────────────────────────────────────────
_G.auto_healer_toast = {
  active = false,
  start_time = 0,
  error_msg = ""
}

local function show_healer_toast(msg)
  _G.auto_healer_toast.active = true
  _G.auto_healer_toast.start_time = system.get_time()
  -- Clean up newlines for a single-line preview
  local clean = msg:gsub("\n", " ")
  _G.auto_healer_toast.error_msg = clean:sub(1, 60) .. (#clean > 60 and "..." or "")
end

local old_root_draw = core.root_view.draw
function core.root_view:draw()
  old_root_draw(self)
  
  if _G.auto_healer_toast.active then
    local t = system.get_time()
    local elapsed = t - _G.auto_healer_toast.start_time
    
    -- Auto-hide after 20 seconds to prevent getting stuck
    if elapsed > 20 then
      _G.auto_healer_toast.active = false
      return
    end

    local font = style.font
    local w = 450 * SCALE
    local h = 65 * SCALE
    local x = (self.size.x - w) / 2
    local y = self.size.y - h - 50 * SCALE -- Bottom center

    -- Draw main background (dark glass)
    renderer.draw_rect(x, y, w, h, { 25, 25, 30, 240 })

    -- Pulse effect for the border (Neon Purple/Cyan)
    local pulse = (math.sin(t * 4) + 1) / 2
    local r, g, b = 180 + 75 * pulse, 100 + 50 * pulse, 255
    local border = 2 * SCALE
    renderer.draw_rect(x, y, w, border, { r, g, b, 255 })
    renderer.draw_rect(x, y + h - border, w, border, { r, g, b, 255 })
    renderer.draw_rect(x, y, border, h, { r, g, b, 255 })
    renderer.draw_rect(x + w - border, y, border, h, { r, g, b, 255 })

    -- Spinner
    local spinner_chars = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
    local spin_idx = (math.floor(t * 12) % #spinner_chars) + 1
    
    renderer.draw_text(font, spinner_chars[spin_idx], x + 15 * SCALE, y + 10 * SCALE, { r, g, b, 255 })
    
    -- Title
    renderer.draw_text(font, "AI Auto-Healer Working", x + 40 * SCALE, y + 10 * SCALE, { 255, 255, 255, 255 })
    
    -- Error preview (muted)
    renderer.draw_text(font, _G.auto_healer_toast.error_msg, x + 15 * SCALE, y + 35 * SCALE, { 160, 160, 170, 255 })

    -- Fake progress bar (asymptotic to 99%)
    local progress = 0.99 * (1 - math.exp(-elapsed / 4))
    local bar_w = (w - 30 * SCALE) * progress
    renderer.draw_rect(x + 15 * SCALE, y + 55 * SCALE, bar_w, 3 * SCALE, { r, g, b, 255 })
    
    -- Draw % text
    local pct_text = string.format("%d%% Diagnosed", math.floor(progress * 100))
    local pct_w = font:get_width(pct_text)
    renderer.draw_text(font, pct_text, x + w - 15 * SCALE - pct_w, y + 10 * SCALE, { r, g, b, 255 })

    core.redraw = true
  end
end

-- ── Shared helper ─────────────────────────────────────────────────────────────
local function agy_path()
  return config.antigravity and config.antigravity.cli or "agy"
end

local function run_headless(prompt)
  local p = process.start({ agy_path(), "-p", prompt, "--dangerously-skip-permissions" }, {
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if not p then return end
  local doc = core.open_doc()
  doc.filename = "Auto-Heal Report.md"
  core.add_thread(function()
    while true do
      local out = p:read_stdout(2048) or ""
      local err = p:read_stderr(2048) or ""
      if #out > 0 or #err > 0 then
        doc:insert(doc:get_selection(), out .. err)
      end
      if p:returncode() ~= nil then break end
      coroutine.yield(0.1)
    end
  end)
end

-- ── Command Palette approval shortcut ────────────────────────────────────────
command.add(nil, {
  ["auto-healer:approve-fix"] = function()
    core.log("[Auto-Healer] Approval sent to AI.")
    if _G.auto_healer_toast then _G.auto_healer_toast.active = false end
    command.perform("antigravity:submit", "Yes, I agree with this fix. Please apply it now.")
  end,

  -- Manual trigger to run 'agy install' via integrated terminal
  ["auto-healer:run-agy-install"] = function()
    core.log("[Auto-Healer] Running 'agy install' in the background terminal...")
    command.perform("toggle-terminal:open")
    core.add_thread(function()
      coroutine.yield(0.3)
      command.perform("toggle-terminal:run", "agy install")
    end)
  end,
})

-- ── Known pattern detector ────────────────────────────────────────────────────
-- Detects specific well-understood failure messages and provides targeted fixes
-- instead of sending them to the generic AI healer.
local KNOWN_PATTERNS = {
  {
    match   = "%[Antigravity%] CLI timed out",
    title   = "Antigravity CLI Timeout",
    message = "The Antigravity CLI timed out after 5 minutes with zero output.\n"
           .. "Most likely causes:\n"
           .. "  1. The AI model is taking too long to generate a response.\n"
           .. "  2. The Antigravity CLI has not been set up yet.\n\n"
           .. "If you suspect it's a setup issue, you can try running `agy install`.\n"
           .. "Options:\n"
           .. "  1. Run 'Auto-Healer: Run agy install' from the Command Palette.\n"
           .. "  2. OR open a terminal and run:  agy install\n\n"
           .. "After setup, reload Lite-XL (Ctrl+Shift+R) and try again.",
    command = "auto-healer:run-agy-install",
    cmd_label = "Run agy install now",
  },
}

local function check_known_patterns(err_str)
  for _, p in ipairs(KNOWN_PATTERNS) do
    if err_str:find(p.match) then
      return p
    end
  end
  return nil
end

-- ── 1. Hook handled errors ────────────────────────────────────────────────────
local old_error = core.error
function core.error(fmt, ...)
  local ret = old_error(fmt, ...)
  local err_str
  if type(fmt) == "string" and select("#", ...) > 0 then
    -- Catch cases where the format fails (e.g. invalid format string)
    local ok, res = pcall(string.format, fmt, ...)
    err_str = ok and res or tostring(fmt)
  else
    err_str = tostring(fmt)
  end
  local trace = debug.traceback("", 2)

  -- Prevent infinite loops and ignore non-critical warnings
  if err_str:find("Too many files in project directory") then return ret end
  if err_str:find("antigravity") and not err_str:find("%[Antigravity%]") then return ret end
  if err_str:find("auto_healer") then return ret end

  core.add_thread(function()
    coroutine.yield(0.1)

    -- ── Check for known fixable patterns first ──────────────────────────────
    local known = check_known_patterns(err_str)
    if known then
      core.log("[Auto-Healer] Known issue detected: %s", known.title)
      core.log("[Auto-Healer] %s", known.message)
      core.log("[Auto-Healer] To fix: run '%s' from the Command Palette.", known.command)
      -- Also show in command view for instant visibility
      core.command_view:enter("[Auto-Healer] " .. known.title .. " — run '" .. known.cmd_label .. "'? (y/n)", {
        submit = function(text)
          if text:lower() == "y" or text:lower() == "yes" then
            command.perform(known.command)
          end
        end
      })
      return
    end

    -- ── Generic AI healer for unknown errors ────────────────────────────────
    local prompt = string.format(
      "Activate skill `lite_xl_healer`! The editor just caught a handled Lua error:\n\n```\n%s\n%s\n```\n\nPlease analyze this, explain the fix to me, and WAIT for my agreement.",
      err_str, trace
    )

    core.log("[Auto-Healer] Caught error: %s", err_str)
    core.log("[Auto-Healer] Delegating to AI Sidebar for analysis...")
    core.log("[Auto-Healer] When ready, run 'Auto Healer: Approve Fix' from the Command Palette.")

    show_healer_toast(err_str)

    local success = command.perform("antigravity:submit", prompt)
    if not success then
      core.command_view:enter("AI Sidebar broken! Run Auto-Healer in background? (y/n)", {
        submit = function(text)
          if text:lower() == "y" or text:lower() == "yes" then
            core.log("Auto-Healer running in background...")
            run_headless(prompt .. " APPLY FIX IMMEDIATELY.")
          end
        end
      })
    end
  end)
  return ret
end

-- ── 2. Hook fatal errors ──────────────────────────────────────────────────────
local old_on_error = core.on_error
function core.on_error(err)
  local trace = debug.traceback("", 2)
  local fp = io.open(USERDIR .. "/auto_heal_pending.txt", "w")
  if fp then
    fp:write(tostring(err) .. "\n" .. trace)
    fp:close()
  end
  old_on_error(err)
end

-- ── 3. On boot, heal fatal crash from previous session ───────────────────────
core.add_thread(function()
  local path = USERDIR .. "/auto_heal_pending.txt"
  local fp = io.open(path, "r")
  if fp then
    local err_text = fp:read("*a")
    fp:close()
    os.remove(path)

    local prompt = string.format(
      "Activate skill `lite_xl_healer`! The editor CRASHED in my last session with this fatal error:\n\n```\n%s\n```\n\nPlease analyze this, explain the fix to me, and WAIT for my agreement.",
      err_text
    )

    core.log("[Auto-Healer] Found fatal crash from previous session.")
    core.log("[Auto-Healer] Delegating to AI Sidebar for analysis...")
    core.log("[Auto-Healer] When ready, run 'Auto Healer: Approve Fix' from the Command Palette.")

    command.perform("antigravity:submit", prompt)
  end
end)