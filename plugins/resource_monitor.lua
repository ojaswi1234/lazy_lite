-- mod-version:3
-- A miniature, highly optimized CPU & RAM resource monitor in the titlebar.
local core = require "core"
local style = require "core.style"
local common = require "core.common"
local config = require "core.config"
local process = require "process"

config.resource_monitor = {
  width = 60,
  history = 30,
  poll_rate = 2,
}

local cpu_history = {}
local ram_history = {}
for i = 1, config.resource_monitor.history do
  cpu_history[i] = 0
  ram_history[i] = 0
end
local current_cpu = 0
local current_ram = 0

local function start_monitor()
  if rawget(_G, "resource_monitor_proc") then pcall(function() rawget(_G, "resource_monitor_proc"):kill() end) end
  
  -- Use a long-running powershell process to feed us stats over stdout.
  -- This avoids the heavy overhead of spawning wmic every 2 seconds.
  local script = string.format([[
    $ErrorActionPreference = 'SilentlyContinue'
    while ($true) {
      $c = (Get-WmiObject Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
      $o = Get-WmiObject Win32_OperatingSystem
      if ($o) {
        $m = [math]::Round(($o.TotalVisibleMemorySize - $o.FreePhysicalMemory) / $o.TotalVisibleMemorySize * 100)
        Write-Output "$c,$m"
      }
      Start-Sleep -Seconds %d
    }
  ]], config.resource_monitor.poll_rate)

  rawset(_G, "resource_monitor_proc", process.start({ "powershell", "-NoProfile", "-Command", script }, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_DISCARD,
    stdin  = process.REDIRECT_DISCARD,
  }))
end

start_monitor()

local out_buf = ""
core.add_thread(function()
  while true do
    if rawget(_G, "resource_monitor_proc") then
      local chunk = rawget(_G, "resource_monitor_proc"):read_stdout(1024)
      if chunk and #chunk > 0 then
        out_buf = out_buf .. chunk
        while out_buf:find("\n") do
          local s, e = out_buf:find("\n")
          local line = out_buf:sub(1, s - 1)
          out_buf = out_buf:sub(e + 1)
          
          local cpu, mem = line:match("(%d+),(%d+)")
          if cpu and mem then
            current_cpu = tonumber(cpu) or 0
            current_ram = tonumber(mem) or 0
            table.remove(cpu_history, 1)
            table.insert(cpu_history, current_cpu)
            table.remove(ram_history, 1)
            table.insert(ram_history, current_ram)
            core.redraw = true
          end
        end
      end
      if rawget(_G, "resource_monitor_proc"):returncode() ~= nil then
        start_monitor()
      end
    end
    coroutine.yield(0.1)
  end
end)

-- Hook into TitleView to draw our mini charts!
local TitleView = require "core.titleview"
local old_draw = TitleView.draw

function TitleView:draw()
  old_draw(self)
  if self.size.y == 0 then return end

  local icon_w = style.icon_font:get_width("_")
  local controls_width = (icon_w + icon_w) * 3 + icon_w
  local h = style.font:get_height()
  local y = self.position.y + style.padding.y
  local max_h = h - 2 * SCALE
  
  local cw = 40 * SCALE
  local gap = 15 * SCALE
  local n = config.resource_monitor.history
  local bar_w = cw / n
  
  -- Start from the left of the window controls and draw right-to-left
  local current_x = self.size.x - controls_width - 15 * SCALE

  local function draw_chart(history, current, label, col)
    local txt = string.format("%d%% %s", current, label)
    local tw = style.font:get_width(txt)
    
    current_x = current_x - cw
    local cx = current_x
    
    -- Background panel
    renderer.draw_rect(cx, y + 2*SCALE, cw, max_h, style.background3 or style.background)
    
    -- Draw Bars
    for i = 1, #history do
      local val = history[i]
      local bar_h = math.max(1, math.floor((val / 100) * max_h))
      local bx = cx + (i - 1) * bar_w
      renderer.draw_rect(math.floor(bx), y + 2*SCALE + (max_h - bar_h), math.ceil(bar_w), bar_h, col)
    end
    
    -- Text Label
    current_x = current_x - 6 * SCALE - tw
    renderer.draw_text(style.font, txt, current_x, y, style.text)
    
    -- Add gap for the next block
    current_x = current_x - gap
  end

  -- Draw right-to-left: RAM will be rightmost, CPU will be left of it
  draw_chart(ram_history, current_ram, "RAM", { common.color "#FC9867" })
  draw_chart(cpu_history, current_cpu, "CPU", { common.color "#A9DC76" })
end

-- Hook into core.quit to kill the background polling process when Lite-XL exits
local old_quit = core.quit
function core.quit(force)
  if rawget(_G, "resource_monitor_proc") then
    pcall(function() rawget(_G, "resource_monitor_proc"):kill() end)
  end
  if old_quit then return old_quit(force) end
end
