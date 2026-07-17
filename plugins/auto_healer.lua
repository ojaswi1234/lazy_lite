-- mod-version:3
-- Auto-Healer plugin: Intercepts editor errors and delegates them to the Antigravity AI sidebar.
-- Also detects specific known failure patterns (e.g. agy CLI not set up) and auto-heals them.

local core    = require "core"
local config = require "core.config"
local command = require "core.command"
local process = require "process"
local system  = require "system"
local style   = require "core.style"

-- ── Visual Overlay State ──────────────────────────────────────────────────────
rawset(_G, "auto_healer_toast", {
  active = false,
  start_time = 0,
  error_msg = ""
})

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
    local w = 550 * SCALE
    local h = 80 * SCALE
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
    
    renderer.draw_text(font, spinner_chars[spin_idx], x + 15 * SCALE, y + 15 * SCALE, { r, g, b, 255 })
    
    -- Title
    local title_font = style.big_font or font
    renderer.draw_text(title_font, "AI Auto-Healer Working", x + 40 * SCALE, y + 15 * SCALE, { 255, 255, 255, 255 })
    
    -- Error preview (muted)
    renderer.draw_text(font, _G.auto_healer_toast.error_msg, x + 15 * SCALE, y + 42 * SCALE, { 160, 160, 170, 255 })

    -- Fake progress bar (asymptotic to 99%)
    local progress = 0.99 * (1 - math.exp(-elapsed / 4))
    local bar_w = (w - 30 * SCALE) * progress
    renderer.draw_rect(x + 15 * SCALE, y + 65 * SCALE, bar_w, 4 * SCALE, { r, g, b, 255 })
    
    -- Draw % text
    local fixed_pct = math.floor(progress * 100)
    local flawed_pct = 100 - fixed_pct
    local pct_text = string.format("%d%% Fixed | %d%% Flawed", fixed_pct, flawed_pct)
    local pct_w = font:get_width(pct_text)
    renderer.draw_text(font, pct_text, x + w - 15 * SCALE - pct_w, y + 15 * SCALE, { r, g, b, 255 })

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

  ["auto-healer:scan-workspace"] = function()
    core.log("[Auto-Healer] Initiating workspace scan...")
    show_healer_toast("Auto-Healer is analyzing the workspace for issues.")
    command.perform("antigravity:submit", "Scan the entire project workspace for hidden bugs, inconsistencies, and issues that could cause it to hang or become non-responsive. Provide a report and prioritize fixing them.")
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
    match   = "No such file or directory",
    title   = "Codespace Archive Missing",
    message = "Remote archive missing — re-running prepare_remote_archive()",
    command = nil,
    cmd_label = nil,
    auto_retry = { once = true, action = "prepare_remote_archive" },
  },
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
  {
    match   = "Failed to tar remote files",
    title   = "Codespace SSH Tar Failed",
    message = "The remote tar command failed. Common causes:\n"
           .. "  1. The codespace is still waking up — wait 30s and reconnect.\n"
           .. "  2. The `gh` CLI SSH RPC failed (ArgumentNullException) — this is\n"
           .. "     a known gh CLI bug on Windows with single-quoted shell commands.\n"
           .. "  3. The remote_dir path is wrong or the codespace has no /workspaces.\n"
           .. "Fix: Open the Codespaces modal, disconnect, and reconnect.",
    command = nil,
    cmd_label = nil,
  },
  {
    match   = "Failed to download workspace",
    title   = "Codespace Download Failed",
    message = "Could not copy the tar archive from the remote codespace.\n"
           .. "Check your network connection and that `gh cs cp` is available.\n"
           .. "Run `gh cs list` in a terminal to verify the codespace is Available.",
    command = nil,
    cmd_label = nil,
  },
  {
    match   = "Failed to sync .* to Codespace",
    title   = "Codespace File Sync Failed",
    message = "A file save could not be synced to the remote codespace.\n"
           .. "The local shadow copy is up-to-date but the remote is behind.\n"
           .. "Reconnect the codespace to force a full re-sync.",
    command = nil,
    cmd_label = nil,
  },
}

local function check_known_patterns(err_str)
  for _, p in ipairs(KNOWN_PATTERNS) do
    if err_str:find(p.match, 1, true) then
      return p
    end
  end
  return nil
end

-- ── 1. Hook handled errors ────────────────────────────────────────────────────

local recent_errors = {}
local function is_duplicate(err_str)
  local t = system.get_time()
  if recent_errors[err_str] and (t - recent_errors[err_str] < 300) then
    return true
  end
  recent_errors[err_str] = t
  return false
end

local old_error = core.error
local _healer_in_error = false

function core.error(fmt, ...)
  if _healer_in_error then
    return old_error(fmt, ...)
  end
  _healer_in_error = true

  local ok, ret = pcall(old_error, fmt, ...)
  if not ok then
    core.log_quiet("Suppressed old_error crash (likely missing statusview): %s", tostring(ret))
  end
  
  -- Handle clock skew (Group E.4)
  if type(fmt) == "string" and (fmt:find("token expired") or fmt:find("gh auth status")) then
    if os.time() < 1767225600 then -- 2026-01-01
      core.warn("System clock skew detected! Please fix your clock.")
    end
  end

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
  if is_duplicate(err_str) then return ret end

  core.add_thread(function()
    coroutine.yield(0.1)

    -- ── Check for known fixable patterns first ──────────────────────────────
    local known = check_known_patterns(err_str)
    if known then
      show_healer_toast(known.message)
      core.log("[Auto-Healer] Known issue: %s", known.title)
      core.log("[Auto-Healer] %s", known.message)
      if known.command then
        core.log("[Auto-Healer] To fix: run '%s' from the Command Palette.", known.command)
        core.command_view:enter("[Auto-Healer] " .. known.title .. " — run '" .. known.cmd_label .. "'? (y/n)", {
          submit = function(text)
            if text:lower() == "y" or text:lower() == "yes" then
              command.perform(known.command)
            end
          end
        })
      end
      return
    end

    -- ── Generic AI healer for unknown errors ────────────────────────────────
    local prompt = string.format(
      "Activate skill `lite_xl_healer`! The editor just caught a handled Lua error:\n\n```\n%s\n%s\n```\n\nPlease analyze this and APPLY THE FIX IMMEDIATELY using replace_file_content or multi_replace_file_content. DO NOT wait for my permission.",
      err_str, trace
    )

    core.log("[Auto-Healer] Caught error: %s", err_str)
    core.log("[Auto-Healer] Delegating to AI Sidebar to auto-fix...")

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
  _healer_in_error = false
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
      "Activate skill `lite_xl_healer`! The editor CRASHED in my last session with this fatal error:\n\n```\n%s\n```\n\n**Note to AI**: This crash happened in the PREVIOUS session. If you have already deployed a fix that resolves this, simply explain that to me so we don't get confused. Otherwise, please analyze this and APPLY THE FIX IMMEDIATELY. DO NOT wait for my permission.",
      err_text
    )

    core.log("[Auto-Healer] Found fatal crash from previous session.")
    core.log("[Auto-Healer] Delegating to AI Sidebar to auto-fix...")

    command.perform("antigravity:submit", prompt)
  end
end)