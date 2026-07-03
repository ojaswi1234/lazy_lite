local core = require "core"
local system = require "system"
local config = require "core.config"

-- Auto-create tempfiles dir in the workspace when opening
local function init_tempfiles()
  if not core.project_dir then return end
  local tmp_dir = core.project_dir .. PATHSEP .. "tempfiles"
  local info = system.get_file_info(tmp_dir)
  if not info then
    system.mkdir(tmp_dir)
  end
end

-- Hook project change to create it if it changes
local old_set_project_dir = core.set_project_dir
function core.set_project_dir(dir, ...)
  local res = { old_set_project_dir(dir, ...) }
  init_tempfiles()
  return table.unpack(res)
end

-- Hook quit to clear it
local old_quit = core.quit
function core.quit(force)
  if core.project_dir then
    local tmp_dir = core.project_dir .. PATHSEP .. "tempfiles"
    local files = system.list_dir(tmp_dir)
    if files then
      for _, f in ipairs(files) do
        local path = tmp_dir .. PATHSEP .. f
        local stat = system.get_file_info(path)
        if stat and stat.type == "file" then
          os.remove(path)
        end
      end
    end
  end
  return old_quit(force)
end

init_tempfiles()

return {
  name = "Tempfiles Manager",
  description = "Creates a tempfiles directory for long AI prompts and auto-clears it on exit."
}
