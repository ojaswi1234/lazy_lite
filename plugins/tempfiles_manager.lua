-- mod-version:3
local core = require "core"
local system = require "system"
local command = require "core.command"

local TEMP_LIMIT = 50
local tmp_dir = USERDIR .. PATHSEP .. "tempfiles"

-- Auto-create global tempfiles dir in .config/lite-xl
local function init_and_check_tempfiles()
  local info = system.get_file_info(tmp_dir)
  if not info then
    system.mkdir(tmp_dir)
    return
  end
  
  -- Check for file limit
  local files = system.list_dir(tmp_dir)
  if files then
    local count = 0
    for _, f in ipairs(files) do
      local stat = system.get_file_info(tmp_dir .. PATHSEP .. f)
      if stat and stat.type == "file" then
        count = count + 1
      end
    end
    
    if count >= TEMP_LIMIT then
      core.add_thread(function()
        coroutine.yield(0.5) -- wait for editor to fully load
        core.error("Tempfiles limit reached! (%d files) Please clean up: %s", count, tmp_dir)
        core.command_view:enter("Tempfiles folder is full! Select an action:", {
          submit = function(text, item)
            local action = item and item.text or text
            if action == "Clean Now" then
              local to_delete = system.list_dir(tmp_dir)
              if to_delete then
                for _, f in ipairs(to_delete) do
                  os.remove(tmp_dir .. PATHSEP .. f)
                end
              end
              core.log("Tempfiles folder cleaned.")
            elseif action == "Open Folder" then
              command.perform("tempfiles:open-folder")
            else
              core.log("Tempfiles cleanup ignored.")
            end
          end,
          suggest = function()
            return {
              { text = "Clean Now", description = "Instantly delete all temporary files" },
              { text = "Open Folder", description = "Open the folder in File Explorer" },
              { text = "Ignore", description = "Do not clean up right now" }
            }
          end
        })
      end)
    end
  end
end

command.add(nil, {
  ["tempfiles:open-folder"] = function()
    local path = tmp_dir
    if PLATFORM == "Windows" then
      os.execute('explorer "' .. path:gsub("/", "\\") .. '"')
    elseif PLATFORM == "Mac OS X" then
      os.execute('open "' .. path .. '"')
    else
      os.execute('xdg-open "' .. path .. '"')
    end
  end
})

init_and_check_tempfiles()

return {
  name = "Tempfiles Manager",
  description = "Manages a global tempfiles folder and alerts when it needs manual cleanup."
}
