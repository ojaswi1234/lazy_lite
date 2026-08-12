-- mod-version:3
local core = require "core"
local style = require "core.style"
local common = require "core.common"
local treeview = require "plugins.treeview"

-- Global state for git file statuses
core.git_ghost_status = {}
core.git_ghost_files_cache = {}

-- Store original methods
local old_get_item_text = treeview.get_item_text
local old_draw_item_text = treeview.draw_item_text
local old_get_cached = treeview.get_cached

-- Monkey-patch treeview to colorize items based on git status
function treeview:get_cached(dir, item, dirname)
  local t = old_get_cached(self, dir, item, dirname)
  
  -- CRITICAL: Clear the cached status first, otherwise toggling OFF leaves the old status stuck forever!
  t.git_status = nil
  
  if item.git_status then
    t.git_status = item.git_status
  else
    if t.abs_filename and core.git_ghost_status then
      local t_abs = t.abs_filename:lower():gsub("[/\\]+", PATHSEP)
      for g_path, status in pairs(core.git_ghost_status) do
        if g_path:lower():gsub("[/\\]+", PATHSEP) == t_abs then
          t.git_status = status
          break
        end
      end
    end
  end
  return t
end

function treeview:get_item_text(item, active, hovered)
  local text, font, color = old_get_item_text(self, item, active, hovered)
  if item.git_status == "added" then
    color = { 100, 220, 100, 255 } -- Green
  elseif item.git_status == "deleted" then
    color = { 220, 100, 100, 255 } -- Red
  elseif item.git_status == "modified" then
    color = { 220, 180, 80, 255 } -- Yellow
  end
  return text, font, color
end

function treeview:draw_item_text(item, active, hovered, x, y, w, h)
  old_draw_item_text(self, item, active, hovered, x, y, w, h)
  
  if item.git_status then
    local badge = ""
    local badge_color = style.text
    if item.git_status == "added" then
      badge = "A"
      badge_color = { 100, 220, 100, 255 }
    elseif item.git_status == "deleted" then
      badge = "D"
      badge_color = { 220, 100, 100, 255 }
    elseif item.git_status == "modified" then
      badge = "M"
      badge_color = { 220, 180, 80, 255 }
    end
    
    if badge ~= "" then
      local badge_font = style.font
      local bw = badge_font:get_width(badge)
      local bx = self.size.x - bw - style.padding.x - 14
      common.draw_text(badge_font, badge_color, badge, "right", bx, y, bw, h)
    end
  end
end

-- Force ghost files into dir.files dynamically
local old_check_cache = treeview.check_cache
function treeview:check_cache()
    old_check_cache(self)
    
    -- Inject ghost files into core.project_directories
    for _, dir in ipairs(core.project_directories) do
      if dir.files then
        local current_version = core.git_ghost_status_version or 0
        if dir._git_ghost_table == dir.files and dir._git_ghost_version == current_version then
          goto skip_injection
        end
        
        -- Cleanup existing ghosts and statuses before applying new ones
        for i = #dir.files, 1, -1 do
          local f = dir.files[i]
          if f.is_ghost then
            table.remove(dir.files, i)
          else
            f.git_status = nil
            f.git_folder_tally = nil
          end
        end
        
        local injected = false
        for ghost_path, status in pairs(core.git_ghost_status) do
          local g_path = ghost_path:lower():gsub("[/\\]+", PATHSEP)
          local d_name = dir.name:lower():gsub("[/\\]+$", ""):gsub("[/\\]+", PATHSEP)
          
          if g_path:find(d_name, 1, true) == 1 then
            local exists = false
            for _, f in ipairs(dir.files) do
              local f_abs = d_name .. PATHSEP .. f.filename:lower():gsub("[/\\]+", PATHSEP)
              if f_abs == g_path then
                f.git_status = status
                exists = true
                break
              end
            end
            if not exists then
              local rel_path = ghost_path:sub(#dir.name + 1):gsub("^[/\\]+", "")
              
              -- Ensure parent folders for this ghost file exist!
              local current = rel_path
              while true do
                current = current:match("^(.*)[/\\][^/\\]+$")
                if not current or current == "" then break end
                local p_exists = false
                for _, pf in ipairs(dir.files) do
                  if pf.filename:lower() == current:lower() then
                    p_exists = true
                    break
                  end
                end
                if not p_exists then
                  table.insert(dir.files, {
                    filename = current,
                    type = "dir",
                    is_ghost = true
                  })
                end
              end

              table.insert(dir.files, {
                filename = rel_path,
                type = "file",
                git_status = status,
                is_ghost = true
              })
              injected = true
            end
          end
        end
        
        -- Compute folder tally
        local folder_tally = {}
        for _, f in ipairs(dir.files) do
          if f.type == "file" and f.git_status then
            local current = f.filename
            while true do
              current = current:match("^(.*)[/\\][^/\\]+$")
              if not current or current == "" then break end
              if not folder_tally[current] then folder_tally[current] = { added = 0, deleted = 0, modified = 0 } end
              folder_tally[current][f.git_status] = folder_tally[current][f.git_status] + 1
            end
          end
        end
        
        -- Assign folder statuses based on tally
        for _, f in ipairs(dir.files) do
          if f.type == "dir" then
            local tally = folder_tally[f.filename:gsub("[/\\]+$", "")]
            if tally then
              local max_val = 0
              local max_status = nil
              for st, count in pairs(tally) do
                if count > max_val then
                  max_val = count
                  max_status = st
                end
              end
              f.git_status = max_status
            else
              f.git_status = nil
            end
          end
        end

        if injected then
          -- Re-sort the files list so ghost files and folders appear in correct order
          table.sort(dir.files, function(a, b)
            return system.path_compare(a.filename, a.type, b.filename, b.type)
          end)
        end
        
        dir._git_ghost_table = dir.files
        dir._git_ghost_version = current_version
        ::skip_injection::
      end
    end
  end

function core.set_git_ghost_files(status_map, hash, p_dir)
  core.git_ghost_status = status_map or {}
  core.git_active_commit = hash
  core.git_project_dir = p_dir
  core.git_ghost_status_version = (core.git_ghost_status_version or 0) + 1
  -- Mark dirs dirty to force treeview rebuild
  for _, dir in ipairs(core.project_directories) do
    dir.is_dirty = true
  end
  core.redraw = true
end

local command = require "core.command"
local process = require "process"

local old_treeview_open = command.map["treeview:open"].perform
command.map["treeview:open"].perform = function(...)
  local item = treeview.selected_item
  if item and item.type == "file" and item.git_status and core.git_active_commit then
    core.add_thread(function()
      local p_dir = core.git_project_dir or core.project_dir or ""
      local file_path = item.abs_filename:sub(#p_dir + 2):gsub("\\", "/")
      
      local cmd_diff
      if core.git_active_commit == "UNCOMMITTED" then
        cmd_diff = {"git", "diff", "HEAD", "-U1000", "--", file_path}
      else
        cmd_diff = {"git", "diff", "-U1000", core.git_active_commit .. "^!", "--", file_path}
      end
      
      local p_diff = process.start(cmd_diff, { cwd = p_dir ~= "" and p_dir or nil, stdout = process.REDIRECT_PIPE })
      if p_diff then
        local diff_out = ""
        while p_diff:returncode() == nil do
          diff_out = diff_out .. (p_diff:read_stdout(8192) or "")
          coroutine.yield(0.05)
        end
        while true do local c = p_diff:read_stdout(8192) or ""; if c == "" then break end; diff_out = diff_out .. c end
        
        if diff_out ~= "" then
          local GitDiffView = require "plugins.git_diff_view"
          for _, v in ipairs(core.root_view.root_node:get_children()) do
            if v:is(GitDiffView) then
              local v_node = core.root_view.root_node:get_node_for_view(v)
              if v_node then
                v_node:close_view(core.root_view.root_node, v)
              end
            end
          end

          local tab_name = file_path:match("[^/\\]+$") or file_path
          local view = GitDiffView(diff_out, tab_name .. " (Diff)")
          local node = core.root_view:get_primary_node()
          node:add_view(view)
          core.redraw = true
        end
      end
    end)
    return
  end
  return old_treeview_open(...)
end

return {
  set_ghost_files = core.set_git_ghost_files
}
