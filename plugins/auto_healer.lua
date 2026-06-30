-- mod-version:3
-- Auto-Healer plugin: Intercepts editor errors and delegates them to the Antigravity AI sidebar.
-- Also detects specific known failure patterns (e.g. agy CLI not set up) and auto-heals them.

local core    = require "core"
local command = require "core.command"
local process = require "process"
local config  = require "core.config"

-- ── Shared helper ─────────────────────────────────────────────────────────────
local function agy_path()
  return config.antigravity and config.antigravity.cli or "agy"
end

local function run_headless(prompt)
  local p = process.start({ agy_path(), "-p", prompt, "--dangerously-skip-permissions" }, {
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
    -- The agy CLI timed out with zero output — almost always means `agy install` needed.
    match   = "%[Antigravity%] CLI timed out",
    title   = "Antigravity CLI not set up",
    message = "The Antigravity CLI hung without producing output. This almost always means\n"
           .. "it needs to be configured first. Options:\n\n"
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
function core.error(err, ...)
  old_error(err, ...)
  local err_str = tostring(err)
  local trace   = debug.traceback("", 2)

  -- Prevent infinite loops
  if err_str:find("antigravity") and not err_str:find("%[Antigravity%]") then return end
  if err_str:find("auto_healer") then return end

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
      return  -- Don't escalate to generic AI handler for known patterns
    end

    -- ── Generic AI healer for unknown errors ────────────────────────────────
    local prompt = string.format(
      "Activate skill `lite_xl_healer`! The editor just caught a handled Lua error:\n\n```\n%s\n%s\n```\n\nPlease analyze this, explain the fix to me, and WAIT for my agreement.",
      err_str, trace
    )

    core.log("[Auto-Healer] Caught error: %s", err_str)
    core.log("[Auto-Healer] Delegating to AI Sidebar for analysis...")
    core.log("[Auto-Healer] When ready, run 'Auto Healer: Approve Fix' from the Command Palette.")

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
