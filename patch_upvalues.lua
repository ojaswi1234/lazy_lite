local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local system = require "system"

local function patch_file()
    local path = "C:\\Users\\ojasw\\.config\\lite-xl\\plugins\\antigravity_sidebar.lua"
    local f = io.open(path, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()

    -- Replace the instance upvalue references with core.active_view
    content = content:gsub(
        'function%(%) return core%.active_view == instance end,',
        'function() return core.active_view.class_name == "AGView" end,'
    )
    
    content = content:gsub(
        '%["antigravity:return"%]%s*=%s*function%(%) instance:on_key_pressed%("return"%) end,',
        '["antigravity:return"] = function() core.active_view:on_key_pressed("return") end,'
    )
    
    content = content:gsub(
        '%["antigravity:shift%-return"%]%s*=%s*function%(%)%s*local c = instance:state%(%)%.cursor or #instance:state%(%)%.input%s*local before = instance:state%(%)%.input:sub%(1, c%)%s*local after = instance:state%(%)%.input:sub%(c %+ 1%)%s*instance:state%(%)%.input = before %.%. "\\n" %.%. after%s*instance:state%(%)%.cursor = c %+ 1%s*instance:_update_mentions%(%)%s*core%.redraw = true%s*end,',
        '["antigravity:shift-return"] = function()\n      local view = core.active_view\n      local c = view:state().cursor or #view:state().input\n      local before = view:state().input:sub(1, c)\n      local after = view:state().input:sub(c + 1)\n      view:state().input = before .. "\\n" .. after\n      view:state().cursor = c + 1\n      view:_update_mentions()\n      core.redraw = true\n    end,'
    )
    
    content = content:gsub(
        '%["antigravity:backspace"%]%s*=%s*function%(%) instance:on_key_pressed%("backspace"%) end,',
        '["antigravity:backspace"] = function() core.active_view:on_key_pressed("backspace") end,'
    )
    
    content = content:gsub(
        '%["antigravity:scroll%-up"%]%s*=%s*function%(%) instance:on_key_pressed%("up"%) end,',
        '["antigravity:scroll-up"] = function() core.active_view:on_key_pressed("up") end,'
    )
    
    content = content:gsub(
        '%["antigravity:scroll%-down"%]%s*=%s*function%(%) instance:on_key_pressed%("down"%) end,',
        '["antigravity:scroll-down"] = function() core.active_view:on_key_pressed("down") end,'
    )
    
    content = content:gsub(
        '%["antigravity:escape"%]%s*=%s*function%(%) instance:on_key_pressed%("escape"%) end,',
        '["antigravity:escape"] = function() core.active_view:on_key_pressed("escape") end,'
    )
    
    content = content:gsub(
        '%["antigravity:paste"%]%s*=%s*function%(%) instance:on_paste%(system%.get_clipboard%(%)%) end,',
        '["antigravity:paste"] = function() core.active_view:on_paste(system.get_clipboard()) end,'
    )
    
    content = content:gsub(
        '%["antigravity:delete"%]%s*=%s*function%(%) instance:on_key_pressed%("delete"%) end,',
        '["antigravity:delete"] = function() core.active_view:on_key_pressed("delete") end,'
    )
    
    content = content:gsub(
        '%["antigravity:cursor%-left"%]%s*=%s*function%(%) instance:on_key_pressed%("left"%) end,',
        '["antigravity:cursor-left"] = function() core.active_view:on_key_pressed("left") end,'
    )
    
    content = content:gsub(
        '%["antigravity:cursor%-right"%]%s*=%s*function%(%) instance:on_key_pressed%("right"%) end,',
        '["antigravity:cursor-right"] = function() core.active_view:on_key_pressed("right") end,'
    )
    
    content = content:gsub(
        '%["antigravity:cursor%-home"%]%s*=%s*function%(%) instance:on_key_pressed%("home"%) end,',
        '["antigravity:cursor-home"] = function() core.active_view:on_key_pressed("home") end,'
    )
    
    content = content:gsub(
        '%["antigravity:cursor%-end"%]%s*=%s*function%(%) instance:on_key_pressed%("end"%) end,',
        '["antigravity:cursor-end"] = function() core.active_view:on_key_pressed("end") end,'
    )
    
    -- ensure class_name is set for AGView
    if not content:find('AGView%.class_name = "AGView"') then
      content = content:gsub(
        'local AGView%s*=%s*View:extend%(%)',
        'local AGView = View:extend()\nAGView.class_name = "AGView"'
      )
    end

    f = io.open(path, "w")
    if f then
      f:write(content)
      f:close()
    end
end
patch_file()
