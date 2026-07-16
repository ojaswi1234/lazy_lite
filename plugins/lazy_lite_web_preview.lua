-- lazy_lite_web_preview.lua
-- A Web Preview Plugin for Lite-XL (lazy-lite suite)

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"
local system = require "system"

-- Config Schema
config.plugins.web_preview = config.plugins.web_preview or {
  port = 8080,          -- requested port; actual may differ, see PORT_BOUND
  spa_fallback = false,
  live_reload = true,
  ignore_dirs = { ".git", "node_modules" },
  bind_host = "127.0.0.1",
  keybind_start = "ctrl+alt+p",
  keybind_stop = "ctrl+alt+shift+p",
}

-- State
local preview_proc = nil
local active_port = nil
local active_url = nil

-- Colors for UI
local function luminance(r, g, b)
  return r * 0.299 + g * 0.587 + b * 0.114
end

local function get_contrast_bg(base)
  if type(base) ~= "table" then return base end
  local r, g, b, a = base[1], base[2], base[3], base[4] or 255
  if luminance(r, g, b) > 128 then
    return { math.max(0, math.floor(r*0.92)), math.max(0, math.floor(g*0.92)), math.max(0, math.floor(b*0.92)), a }
  else
    return { math.min(255, math.floor(r*1.08)), math.min(255, math.floor(g*1.08)), math.min(255, math.floor(b*1.08)), a }
  end
end

-- Server binary path
local BIN_NAME = "lazy_lite_preview_server"
if PLATFORM == "Windows" then
  BIN_NAME = "lazy_lite_preview_server.exe"
elseif PLATFORM == "Mac OS X" then
  BIN_NAME = "lazy_lite_preview_server_mac"
end

local function get_binary_path()
  -- Assume binary is in the plugins directory
  return USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. BIN_NAME
end

-- Open Browser Cross-Platform
local function open_browser(url)
  if PLATFORM == "Windows" then
    process.start({ "cmd.exe", "/c", "start", "", url })
  elseif PLATFORM == "Mac OS X" then
    process.start({ "open", url })
  else
    process.start({ "xdg-open", url })
  end
end

-- Commands
command.add(nil, {
  ["web-preview:start"] = function()
    if preview_proc and preview_proc:running() then
      core.log("Web Preview: Already running on %s", active_url or "unknown")
      if active_url then open_browser(active_url) end
      return
    end

    local bin = get_binary_path()
    if not system.get_file_info(bin) then
      core.error("Web Preview: Binary not found at %s. Please compile it.", bin)
      return
    end

    local root = core.project_dir or "."
    if system.get_file_info(root .. PATHSEP .. "index.html") == nil then
      core.log("Web Preview: No index.html found in project root, but starting anyway.")
    end

    local cfg = config.plugins.web_preview
    local args = { bin, root, tostring(cfg.port) }
    
    if cfg.spa_fallback then table.insert(args, "--spa") end
    if not cfg.live_reload then table.insert(args, "--no-reload") end
    if #cfg.ignore_dirs > 0 then
      table.insert(args, "--ignore=" .. table.concat(cfg.ignore_dirs, ","))
    end
    if cfg.bind_host then table.insert(args, "--host=" .. cfg.bind_host) end

    preview_proc = process.start(args, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
    
    if not preview_proc then
      core.error("Web Preview: Failed to spawn preview server process.")
      return
    end

    -- Non-blocking thread to read stdout and wait for PORT_BOUND
    core.add_thread(function()
      local start_time = system.get_time()
      local out = ""
      while preview_proc and preview_proc:running() do
        local chunk = preview_proc:read_stdout(4096)
        if chunk then
          out = out .. chunk
          local p1, p2, p_str = out:find("PORT_BOUND:(%d+)")
          if p1 then
            active_port = tonumber(p_str)
            active_url = "http://" .. (cfg.bind_host or "127.0.0.1") .. ":" .. active_port
            core.log("Web Preview: Serving on %s", active_url)
            open_browser(active_url)
            break
          end
        end
        if system.get_time() - start_time > 10 then
          core.error("Web Preview: Timeout waiting for PORT_BOUND from server.")
          command.perform("web-preview:stop")
          break
        end
        coroutine.yield(0.1)
      end
    end)
  end,
  
  ["web-preview:stop"] = function()
    if preview_proc then
      pcall(function() preview_proc:terminate() end)
      preview_proc = nil
    end
    active_port = nil
    active_url = nil
    core.log("Web Preview: Stopped.")
  end,
  
  ["web-preview:restart"] = function()
    command.perform("web-preview:stop")
    core.add_thread(function()
      coroutine.yield(0.5) -- wait for OS socket to close
      command.perform("web-preview:start")
    end)
  end,
  
  ["web-preview:copy-url"] = function()
    if active_url then
      system.set_clipboard(active_url)
      core.log("Web Preview: Copied %s to clipboard.", active_url)
    else
      core.log("Web Preview: Server is not running.")
    end
  end
})

-- Keybindings
keymap.add({
  [config.plugins.web_preview.keybind_start] = "web-preview:start",
  [config.plugins.web_preview.keybind_stop] = "web-preview:stop",
})

-- Singleton Status Bar Item
core.status_view:add_item({
  name = "web_preview",
  alignment = core.status_view.Item.RIGHT,
  get_item = function()
    local bg = get_contrast_bg(style.background)
    
    local icon = "\u{f0c1} " -- FontAwesome link icon
    local text = active_url and (":" .. active_port) or "Idle"
    local color = active_url and style.good or style.dim
    
    return {
      icon = icon,
      text = text,
      color = color,
      on_click = function() command.perform("web-preview:copy-url") end
    }
  end
})

-- Process lifecycle cleanup
local old_quit = core.quit
function core.quit(force)
  if preview_proc then
    pcall(function() preview_proc:terminate() end)
  end
  return old_quit(force)
end
