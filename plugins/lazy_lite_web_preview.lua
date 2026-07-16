-- mod-version:3
-- lazy_lite_web_preview.lua
-- A Web Preview Plugin for Lite-XL (lazy-lite suite)

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"
local system = require "system"

-- Config Schema
config.plugins.web_preview = config.plugins.web_preview or {}
local cfg = config.plugins.web_preview
cfg.port = cfg.port or 8080
if cfg.spa_fallback == nil then cfg.spa_fallback = false end
if cfg.live_reload == nil then cfg.live_reload = true end
cfg.ignore_dirs = cfg.ignore_dirs or { ".git", "node_modules" }
cfg.bind_host = cfg.bind_host or "127.0.0.1"
cfg.keybind_start = cfg.keybind_start or "ctrl+alt+p"
cfg.keybind_stop = cfg.keybind_stop or "ctrl+alt+shift+p"


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

-- Open Browser Cross-Platform (use rundll32 on Windows — more reliable than cmd start for URLs)
local function open_browser(url)
  if PLATFORM == "Windows" then
    -- rundll32 is always available and handles URLs correctly including IPv6
    process.start({ "rundll32", "url.dll,FileProtocolHandler", url })
  elseif PLATFORM == "Mac OS X" then
    process.start({ "open", url })
  else
    process.start({ "xdg-open", url })
  end
end

local function file_exists(path)
  return system.get_file_info(path) ~= nil
end

-- Run netstat ONCE and return a table of { port → url } for all LISTENING TCP ports.
-- Must be called from inside a coroutine (core.add_thread).
local function get_all_listening_ports()
  local cmd = PLATFORM == "Windows" and { "netstat", "-ano" } or { "ss", "-tnlp" }
  local p = process.start(cmd, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
  if not p then return {} end
  local out = ""
  local deadline = system.get_time() + 4
  while p:running() and system.get_time() < deadline do
    coroutine.yield(0.05)
  end
  -- drain all output
  while true do
    local chunk = p:read_stdout(65536)
    if not chunk or #chunk == 0 then break end
    out = out .. chunk
  end
  local result = {}
  -- Windows netstat line format examples:
  --   TCP    127.0.0.1:5000     0.0.0.0:0     LISTENING  1234
  --   TCP    [::1]:5173         [::]:0        LISTENING  5678
  --   TCP    0.0.0.0:80         0.0.0.0:0     LISTENING  91
  for line in (out .. "\n"):gmatch("[^\n]+") do
    if line:find("LISTEN") then
      local ipv4, port4 = line:match("(%d+%.%d+%.%d+%.%d+):(%d+)")
      if ipv4 and port4 then
        local portnum = tonumber(port4)
        if portnum and not result[portnum] then
          -- prefer 127.0.0.1 > 0.0.0.0 for the URL
          if ipv4 == "127.0.0.1" or not result[portnum] then
            result[portnum] = "http://127.0.0.1:" .. port4
          end
        end
      end
      -- IPv6: [::1]:5173 or [::]:5173
      local port6 = line:match("%[.-%]:(%d+)")
      if port6 then
        local portnum = tonumber(port6)
        if portnum then
          -- only use localhost (IPv6) if no IPv4 entry found yet
          if not result[portnum] then
            result[portnum] = "http://localhost:" .. port6
          end
        end
      end
    end
  end
  return result
end

-- Port ranges to scan per framework (in priority order)
local FRAMEWORK_PORT_RANGES = {
  vite    = { 5173, 5174, 5175, 5176, 5177, 4173, 4174 },
  next    = { 3000, 3001, 3002, 3003 },
  react   = { 3000, 3001, 3002, 8080 },
  django  = { 8000, 8001, 8080 },
  fastapi = { 8000, 8001, 8080 },
  go      = { 8080, 8000, 3000 },
}

-- Find the first bound port for a framework type. Returns (url, port) or nil.
-- Must be called from inside a coroutine.
local function find_dev_server(fw_type, hint_port)
  local listening = get_all_listening_ports()
  -- try the hint port first (from detect_framework or config override)
  local cfg_override = config.plugins.web_preview.dev_port
  for _, port in ipairs({ cfg_override, hint_port }) do
    if port and listening[port] then
      return listening[port], port
    end
  end
  -- scan the range for this framework type
  local ranges = FRAMEWORK_PORT_RANGES[fw_type]
  if ranges then
    for _, port in ipairs(ranges) do
      if listening[port] then
        return listening[port], port
      end
    end
  end
  return nil, nil
end

-- Strip ANSI escape codes from output before URL parsing
local function strip_ansi(s)
  if not s then return s end
  s = s:gsub("\027%[[0-9;]*[A-Za-z]", "")
  s = s:gsub("%[[0-9;]+[mKJHABCDEF]", "")
  return s
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local function make_cmd(cmd_list)
  if PLATFORM == "Windows" then
    local out = {"cmd.exe", "/c"}
    for _, v in ipairs(cmd_list) do table.insert(out, v) end
    return out
  end
  return cmd_list
end

-- Scan a package.json for framework markers; returns a result table or nil
local function check_pkg_json(pkg_path, subdir)
  local pkg = read_file(pkg_path) or ""
  local cmd_prefix = subdir and {"cmd.exe", "/c", "cd", subdir, "&&"} or nil
  local function cmd(args)
    if PLATFORM == "Windows" and subdir then
      local out = {"cmd.exe", "/c", "cd", subdir, "&&"}
      for _, v in ipairs(args) do table.insert(out, v) end
      return out
    elseif PLATFORM == "Windows" then
      local out = {"cmd.exe", "/c"}
      for _, v in ipairs(args) do table.insert(out, v) end
      return out
    elseif subdir then
      local out = {"sh", "-c", "cd '" .. subdir .. "' && " .. table.concat(args, " ")}
      return out
    end
    return args
  end
  if pkg:find('"next"') then return { type = "next", cmd = cmd({"npm", "run", "dev"}), port = 3000 } end
  if pkg:find('"vite"') then return { type = "vite", cmd = cmd({"npm", "run", "dev"}), port = 5173 } end
  if pkg:find('"react%-scripts"') then return { type = "react", cmd = cmd({"npm", "start"}), port = 3000 } end
  return nil
end

-- Sub-directories to check for front-end projects in monorepos
local FRONTEND_SUBDIRS = { "client", "frontend", "web", "app", "ui", "src", "packages/web", "packages/app" }

local function detect_framework(root)
  -- 1. Check root package.json
  local pkg_path = root .. PATHSEP .. "package.json"
  if file_exists(pkg_path) then
    local res = check_pkg_json(pkg_path, nil)
    if res then return res end
  end
  
  -- 2. Check common monorepo subdirectories
  for _, subname in ipairs(FRONTEND_SUBDIRS) do
    local sub = root .. PATHSEP .. subname
    local sub_pkg = sub .. PATHSEP .. "package.json"
    if file_exists(sub_pkg) then
      local res = check_pkg_json(sub_pkg, sub)
      if res then
        core.log("Web Preview: Found %s framework in subdirectory '%s'", res.type, subname)
        return res
      end
    end
  end

  -- 3. Python backends
  if file_exists(root .. PATHSEP .. "manage.py") then
    return { type = "django", cmd = make_cmd({"python", "manage.py", "runserver"}), port = 8000 }
  end
  local main_py = root .. PATHSEP .. "main.py"
  if file_exists(main_py) then
    local c = read_file(main_py) or ""
    if c:find("FastAPI") then
      return { type = "fastapi", cmd = make_cmd({"uvicorn", "main:app", "--reload"}), port = 8000 }
    end
  end
  
  -- 4. Go
  if file_exists(root .. PATHSEP .. "go.mod") then
    return { type = "go", cmd = make_cmd({"go", "run", "."}), port = 8080 }
  end
  
  return { type = "static" }
end

-- Commands
command.add(nil, {
    ["web-preview:start"] = function()
    if preview_proc and preview_proc:running() then
      core.log("Web Preview: Already running on %s", active_url or "unknown")
      if active_url then open_browser(active_url) end
      return
    end

    local root = core.project_dir or "."
    local fw = detect_framework(root)
    local cfg = config.plugins.web_preview

    -- ── Attach mode: scan port range for already-running dev server ──
    local default_port = fw.port  -- set by detect_framework (nil for static)
    if default_port or config.plugins.web_preview.dev_port then
      core.add_thread(function()
        core.log("Web Preview: Scanning for %s dev server (ports %d--%d)...", fw.type, default_port or 0, (default_port or 0) + 4)
        local bound_url, bound_port = find_dev_server(fw.type, default_port)
        if bound_url then
          active_port = bound_port
          active_url = bound_url
          core.log("Web Preview: Found %s on port %d → opening %s", fw.type, bound_port, active_url)
          open_browser(active_url)
          return
        end
        -- Not already up — spawn it
        core.log("Web Preview: Detected %s framework. Starting dev server...", fw.type)
        preview_proc = process.start(fw.cmd, { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE })
        if not preview_proc then
          core.error("Web Preview: Failed to spawn %s dev server.", fw.type)
          return
        end
        -- Monitor output for URL
        local start_time = system.get_time()
        local out = ""
        while preview_proc and preview_proc:running() do
          local chunk = preview_proc:read_stdout(4096)
          if chunk then
            out = out .. strip_ansi(chunk)
            local url = out:match("(https?://[%w%.]+:%d+)")
            if url then
              active_url = url
              active_port = tonumber(url:match(":(%d+)/?$")) or 80
              core.log("Web Preview: Framework ready on %s", active_url)
              open_browser(active_url)
              break
            end
          end
          if system.get_time() - start_time > 20 then
            -- Fallback to default port after timeout
            active_port = default_port
            active_url = "http://localhost:" .. default_port
            core.log("Web Preview: Timeout — assuming %s is on %s", fw.type, active_url)
            open_browser(active_url)
            break
          end
          coroutine.yield(0.2)
        end
      end)
      return
    end

    -- ── Static server path ──
    local bin = get_binary_path()
    if not system.get_file_info(bin) then
      core.error("Web Preview: Binary not found at %s. Please compile it.", bin)
      return
    end
    if system.get_file_info(root .. PATHSEP .. "index.html") == nil then
      core.log("Web Preview: No index.html found in project root, but starting anyway.")
    end
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
    core.add_thread(function()
      local start_time = system.get_time()
      local out = ""
      while preview_proc and preview_proc:running() do
        local chunk = preview_proc:read_stdout(4096)
        if chunk then
          out = out .. chunk
          local p_str = out:match("PORT_BOUND:(%d+)")
          if p_str then
            active_port = tonumber(p_str)
            active_url = "http://" .. (cfg.bind_host or "127.0.0.1") .. ":" .. active_port
            core.log("Web Preview: Serving on %s", active_url)
            open_browser(active_url)
            break
          end
        end
        if system.get_time() - start_time > 15 then
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
local preview_status = core.status_view:add_item({
  name = "web_preview",
  alignment = core.status_view.Item.RIGHT,
  tooltip = "Click to start Web Preview",
  get_item = function()
    local icon = "\u{f0c1} " -- FontAwesome link icon
    local text = active_url and (":" .. active_port) or "Idle"
    local color = active_url and style.good or style.dim
    return {
      color,
      icon .. text
    }
  end,
  -- NOTE: Lite-XL reads the click handler from 'command' when it's a function
  command = function(button, x, y)
    if button == "left" then
      if active_url then
        command.perform("web-preview:copy-url")
      else
        command.perform("web-preview:start")
      end
    elseif button == "right" then
      command.perform("web-preview:stop")
    end
  end
})

local old_get_item = preview_status.get_item
preview_status.get_item = function()
  local expected_tooltip = active_url and "Left-click: Copy URL | Right-click: Stop Server" or "Click to start Web Preview"
  if preview_status.tooltip ~= expected_tooltip then
    preview_status.tooltip = expected_tooltip
  end
  return old_get_item()
end

-- Process lifecycle cleanup
local old_quit = core.quit
function core.quit(force)
  if preview_proc then
    pcall(function() preview_proc:terminate() end)
  end
  return old_quit(force)
end

