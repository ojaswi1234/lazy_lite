-- mod-version:3
local core = require "core"
local system = require "system"
local command = require "core.command"

local TEMP_LIMIT = 20
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
        core.command_view:enter("Tempfiles folder is full! Open folder to clean it? (y/n)", {
          submit = function(text)
            if text:lower() == "y" or text:lower() == "yes" then
              command.perform("tempfiles:open-folder")
            end
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
