-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"

local function suggest_directory(text)
  text = common.home_expand(text)
  local basedir = common.dirname(core.project_dir)
  return common.home_encode_list((basedir and text == basedir .. PATHSEP or text == "") and
    core.recent_projects or common.dir_path_suggest(text))
end

local function check_directory_path(path)
  local abs_path = system.absolute_path(path)
  local info = abs_path and system.get_file_info(abs_path)
  if not info or info.type ~= 'dir' then
    return nil
  end
  return abs_path
end

-- Override the default open project command to add window mode selection
command.add(nil, {
  ["core:open-project-folder"] = function()
    local dirname = common.dirname(core.project_dir)
    local text
    if dirname then
      text = common.home_encode(dirname) .. PATHSEP
    end
    core.command_view:enter("Open Project", {
      text = text,
      submit = function(text)
        local path = common.home_expand(text)
        local abs_path = check_directory_path(path)
        if not abs_path then
          core.error("Cannot open directory %q", path)
          return
        end
        if abs_path == core.project_dir then
          core.error("Directory %q is currently opened", abs_path)
          return
        end
        
        -- Prompt for window mode
        core.command_view:enter("Open mode for " .. common.home_encode(abs_path), {
          text = "Open Here only",
          submit = function(choice)
            if choice == "Open Here only" then
              core.open_folder_project(abs_path)
            elseif choice == "Open in a new window" then
              system.exec(string.format("%q %q", EXEFILE, abs_path))
            end
          end,
          suggest = function(text)
            local choices = {"Open Here only", "Open in a new window"}
            local res = {}
            for _, c in ipairs(choices) do
              if c:lower():find(text:lower(), 1, true) then
                table.insert(res, c)
              end
            end
            return res
          end
        })
      end,
      suggest = suggest_directory
    })
  end
})
