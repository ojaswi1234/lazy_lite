-- mod-version:3
local core = require "core"

core.add_thread(function()
  coroutine.yield(2.0) -- Wait a bit
  local f = io.open("C:\\Users\\ojasw\\Desktop\\lite_xl_log.txt", "w")
  if f then
    if core.log_items then
      for _, item in ipairs(core.log_items) do
        f:write(tostring(item.text) .. "\n")
      end
    end
    f:close()
  end
end)
