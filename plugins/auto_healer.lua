-- mod-version:3
-- Auto-Healer plugin: Intercepts editor errors and delegates them to the Antigravity AI sidebar.

local core = require "core"
local command = require "core.command"

command.add(nil, {
  ["auto-healer:approve-fix"] = function()
    core.log("[Auto-Healer] Approval sent to AI.")
    command.perform("antigravity:submit", "Yes, I agree with this fix. Please apply it now.")
  end
})

-- 1. Hook handled errors (e.g., inside core.try, plugin execution)
local old_error = core.error
function core.error(err, ...)
  old_error(err, ...)
  local trace = debug.traceback("", 2)
  
  -- Prevent infinite loops if the sidebar or autohealer itself crashes
  if tostring(err):find("antigravity") or tostring(err):find("auto_healer") then return end
  
  -- Delay the execution slightly so the UI doesn't freeze during error handling
  core.add_thread(function()
    coroutine.yield(0.1)
    local prompt = string.format(
      "Activate skill `lite_xl_healer`! The editor just caught a handled Lua error:\n\n```\n%s\n%s\n```\n\nPlease analyze this, explain the fix to me, and WAIT for my agreement.",
      tostring(err), trace
    )
    
    core.log("[Auto-Healer] Caught error: %s", tostring(err))
    core.log("[Auto-Healer] Delegating to AI Sidebar for analysis...")
    core.log("[Auto-Healer] When ready, run 'Auto Healer: Approve Fix' from the Command Palette to approve.")

    local success = command.perform("antigravity:submit", prompt)
    if not success then
      core.command_view:enter("AI Sidebar broken! Run Auto-Healer in background? (y/n)", {
        submit = function(text)
          if text:lower() == "y" or text:lower() == "yes" then
            core.log("Auto-Healer running in background...")
            local process = require "process"
            local config = require "core.config"
            local agy_path = config.antigravity and config.antigravity.cli or "agy"
            
            -- Run headlessly and output to a new doc
            local p = process.start({ agy_path, "-f", "-p", prompt .. " APPLY FIX IMMEDIATELY." }, {
              stdout = process.REDIRECT_PIPE,
              stderr = process.REDIRECT_PIPE
            })
            if p then
              local doc = core.open_doc()
              doc.filename = "Auto-Heal Report.md"
              core.add_thread(function()
                while true do
                  local out = p:read_stdout(2048) or ""
                  local errout = p:read_stderr(2048) or ""
                  if #out > 0 or #errout > 0 then
                    doc:insert(doc:get_selection(), out .. errout)
                  end
                  if p:returncode() ~= nil then break end
                  coroutine.yield(0.1)
                end
              end)
            end
          end
        end
      })
    end
  end)
end

-- 2. Hook fatal errors (crashing the editor main loop)
local old_on_error = core.on_error
function core.on_error(err)
  local trace = debug.traceback("", 2)
  
  -- We can't use the UI reliably during a fatal crash, so save it to a file.
  local fp = io.open(USERDIR .. "/auto_heal_pending.txt", "w")
  if fp then
    fp:write(tostring(err) .. "\n" .. trace)
    fp:close()
  end
  
  -- Continue with standard crash screen
  old_on_error(err)
end

-- 3. On boot, check if there's a fatal error from last session to heal
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
    core.log("[Auto-Healer] When ready, run 'Auto Healer: Approve Fix' from the Command Palette to approve.")
    
    command.perform("antigravity:submit", prompt)
  end
end)
