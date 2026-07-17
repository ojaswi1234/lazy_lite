-- mod-version:3
-- A miniature, highly optimized CPU & RAM resource monitor in the titlebar.
local core = require "core"
local style = require "core.style"
local common = require "core.common"
local config = require "core.config"
local process = require "process"
local system = require "system"

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
local monitor_proc = nil

local function reset_history()
  current_cpu = 0
  current_ram = 0
  for i = 1, config.resource_monitor.history do
    cpu_history[i] = 0
    ram_history[i] = 0
  end
end

local function start_monitor()
  if monitor_proc then
    pcall(function() monitor_proc:kill() end)
    monitor_proc = nil
  end
  reset_history()
  
  if core.active_codespace then
    local script = string.format([[
      prev_total=""
      prev_idle=""
      while true; do
        read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
        total=$((user+nice+system+idle+iowait+irq+softirq+steal))
        idle_val=$((idle+iowait))
        if [ -n "$prev_total" ]; then
          d_total=$((total - prev_total))
          d_idle=$((idle_val - prev_idle))
          if [ $d_total -eq 0 ]; then c=0; else c=$((100 * (d_total - d_idle) / d_total)); fi
          m=$(free | awk '/Mem/{printf("%%.0f", $3/$2 * 100)}')
          echo "${c},${m}"
        fi
        prev_total=$total
        prev_idle=$idle_val
        sleep %d
      done
    ]], config.resource_monitor.poll_rate)

    monitor_proc = process.start({ "gh", "cs", "ssh", "-c", core.active_codespace.name, "--", "bash", "-c", script }, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_DISCARD,
      stdin  = process.REDIRECT_DISCARD,
    })
  else
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

    local ok, p = pcall(process.start, { "powershell", "-NoProfile", "-Command", script }, {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_DISCARD,
      stdin  = process.REDIRECT_DISCARD,
    })
    if ok then monitor_proc = p else monitor_proc = nil end
  end

  if not monitor_proc then
    core.warn("Resource monitor: failed to start monitor process.")
  end
end

start_monitor()

local out_buf = ""
core.add_thread(function()
  while true do
    local p = monitor_proc
    if p then
      local chunk = p:read_stdout(1024)
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
      if p:returncode() ~= nil then
        local out = ""
        while true do
          local data = p:read_stdout(4096)
          if not data or data == "" then break end
          out = out .. data
        end
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
  
  local current_x = self.size.x - controls_width - 15 * SCALE

  local function draw_chart(history, current, label, col)
    local txt = string.format("%d%% %s", current, label)
    local tw = style.font:get_width(txt)
    
    current_x = current_x - cw
    local cx = current_x
    
    renderer.draw_rect(cx, y + 2*SCALE, cw, max_h, style.background3 or style.background)
    
    for i = 1, #history do
      local val = history[i]
      local bar_h = math.max(1, math.floor((val / 100) * max_h))
      local bx = cx + (i - 1) * bar_w
      renderer.draw_rect(math.floor(bx), y + 2*SCALE + (max_h - bar_h), math.ceil(bar_w), bar_h, col)
    end
    
    current_x = current_x - 6 * SCALE - tw
    renderer.draw_text(style.font, txt, current_x, y, style.text)
    current_x = current_x - gap
  end

  local is_cloud = core.active_codespace ~= nil
  draw_chart(ram_history, current_ram, is_cloud and "CLOUD RAM" or "RAM", { common.color "#FC9867" })
  draw_chart(cpu_history, current_cpu, is_cloud and "CLOUD CPU" or "CPU", { common.color "#A9DC76" })

  if is_cloud and core.active_codespace.start_time then
    local elapsed = system.get_time() - core.active_codespace.start_time
    local mins = math.floor(elapsed / 60)
    local secs = math.floor(elapsed % 60)
    local txt = string.format("CS UPTIME: %02d:%02d", mins, secs)
    local tw = style.font:get_width(txt)
    current_x = current_x - tw
    renderer.draw_text(style.font, txt, current_x, y, { 100, 255, 100, 255 })
  end
end

local old_quit = core.quit
function core.quit(force)
  if monitor_proc then
    pcall(function() monitor_proc:kill() end)
    monitor_proc = nil
  end
  if old_quit then return old_quit(force) end
end

return {
  restart = start_monitor
}
