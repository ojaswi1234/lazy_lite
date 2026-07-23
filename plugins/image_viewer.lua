-- mod-version:3
local core = require "core"

local image_exts = { "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "ico" }

local function is_image(filename)
  if not filename then return false end
  local ext = filename:match("%.([^%.]+)$")
  if not ext then return false end
  ext = ext:lower()
  for _, e in ipairs(image_exts) do
    if e == ext then return true end
  end
  return false
end

local old_open_doc = core.root_view.open_doc
core.root_view.open_doc = function(self, doc)
  if doc and doc.filename and is_image(doc.filename) then
    local url = doc.filename:gsub('"', '\\"')
    if PLATFORM == "Windows" then
      system.exec('cmd.exe /c start "" "' .. url .. '"')
    elseif PLATFORM == "Mac OS X" then
      system.exec('open "' .. url .. '"')
    else
      system.exec('xdg-open "' .. url .. '"')
    end
    
    core.log("Image opened in external viewer: " .. doc.filename)
    
    -- Clean up the memory loaded by core.open_doc
    for i, d in ipairs(core.docs) do
      if d == doc then
        table.remove(core.docs, i)
        break
      end
    end
    
    return nil
  end
  
  return old_open_doc(self, doc)
end
