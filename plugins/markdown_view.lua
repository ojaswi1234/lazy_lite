-- mod-version:3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local View = require "core.view"
local style = require "core.style"

local MarkdownView = View:extend()

-- Safely try to load emoji font
local emoji_font = nil
pcall(function()
  local path = USERDIR .. "/fonts/NotoColorEmoji.ttf"
  local f = io.open(path, "r")
  if f then
    f:close()
  else
    if PLATFORM == "Windows" then
      path = os.getenv("WINDIR") .. "\\Fonts\\seguiemj.ttf"
    elseif PLATFORM == "Mac OS X" then
      path = "/System/Library/Fonts/Apple Color Emoji.ttc"
    else
      path = "/usr/share/fonts/noto/NotoColorEmoji.ttf"
    end
  end
  if path then
    emoji_font = renderer.font.load(path, style.font:get_size())
  end
end)

function MarkdownView:new(doc)
  MarkdownView.super.new(self)
  if type(doc) == "string" then
    doc = core.open_doc(doc)
  end
  self.doc = doc or require("core.doc")()
  self.scrollable = true
  self.name = "Preview: " .. (self.doc.filename or self.doc.name or "Untitled")
  self.scroll = {x = 0, y = 0, to = {x = 0, y = 0}}
  self.max_scroll = {x = 0, y = 0}
  self.links = {}
  
  local base_size = style.font:get_size()
  
  local normal_font = style.font
  if emoji_font then
    normal_font = renderer.font.group({style.font, emoji_font})
  end

  self.fonts = {
    normal = normal_font,
    code = style.code_font,
  }
  
  -- Safely try to load varied fonts
  pcall(function() self.fonts.h1 = style.font:copy(math.floor(base_size * 2)) end)
  pcall(function() self.fonts.h2 = style.font:copy(math.floor(base_size * 1.5)) end)
  pcall(function() self.fonts.h3 = style.font:copy(math.floor(base_size * 1.25)) end)
  
  if not self.fonts.h1 then self.fonts.h1 = self.fonts.normal end
  if not self.fonts.h2 then self.fonts.h2 = self.fonts.normal end
  if not self.fonts.h3 then self.fonts.h3 = self.fonts.normal end
  
  -- Apply emoji fallback to headers as well if possible
  if emoji_font then
    pcall(function() self.fonts.h1 = renderer.font.group({self.fonts.h1, emoji_font}) end)
    pcall(function() self.fonts.h2 = renderer.font.group({self.fonts.h2, emoji_font}) end)
    pcall(function() self.fonts.h3 = renderer.font.group({self.fonts.h3, emoji_font}) end)
  end
end

function MarkdownView:set_target_size(axis, value)
  return false
end

function MarkdownView:get_name()
  return self.name
end

local function draw_text_wrapped(font, text, x, y, x_start, max_x, color)
  if x + font:get_width(text) <= max_x then
    return renderer.draw_text(font, text, x, y, color), y
  end
  for i = 1, #text do
    local c = text:sub(i, i)
    local w = font:get_width(c)
    if x + w > max_x and x > x_start then
      x = x_start
      y = y + font:get_height()
    end
    x = renderer.draw_text(font, c, x, y, color)
  end
  return x, y
end

local function draw_inline_markdown(self, line, x, y, fonts, def_color, x_start, max_x)
  local pos = 1
  while pos <= #line do
    local b_start, b_end = line:find("%*%*.-%*%*", pos)
    local c_start, c_end = line:find("`.-`", pos)
    local url_start, url_end = line:find("https?://[%w%-_%.~:/?#%[%]@!$&'()*+,;=]+", pos)
    local u_start, u_end = line:find("@[a-zA-Z0-9_-]+", pos)
    local i_start, i_end = line:find("#%d+", pos)
    local r_start, r_end = line:find("[%w_%-]+/[%w_%-]+#%d+", pos)
    
    local next_start = math.huge
    local next_type = nil
    
    if b_start and b_start < next_start then next_start = b_start; next_type = "bold" end
    if c_start and c_start < next_start then next_start = c_start; next_type = "code" end
    if url_start and url_start < next_start then next_start = url_start; next_type = "url" end
    if u_start and u_start < next_start then next_start = u_start; next_type = "user" end
    if r_start and r_start < next_start then next_start = r_start; next_type = "repo_issue" end
    if i_start and i_start < next_start then next_start = i_start; next_type = "issue" end
    
    if next_type == nil then
      local chunk = line:sub(pos)
      x, y = draw_text_wrapped(fonts.normal, chunk, x, y, x_start, max_x, def_color)
      break
    end
    
    if next_start > pos then
      local chunk = line:sub(pos, next_start - 1)
      x, y = draw_text_wrapped(fonts.normal, chunk, x, y, x_start, max_x, def_color)
    end
    
    if next_type == "bold" then
      local chunk = line:sub(b_start + 2, b_end - 2)
      x, y = draw_text_wrapped(fonts.normal, chunk, x, y, x_start, max_x, style.syntax.keyword or def_color)
      pos = b_end + 1
    elseif next_type == "code" then
      local chunk = line:sub(c_start + 1, c_end - 1)
      local cw = fonts.code:get_width(chunk)
      renderer.draw_rect(math.floor(x - 2), math.floor(y), math.ceil(cw + 4), fonts.code:get_height(), style.line_highlight)
      x, y = draw_text_wrapped(fonts.code, chunk, x, y, x_start, max_x, style.syntax.string or def_color)
      pos = c_end + 1
    elseif next_type == "url" or next_type == "user" or next_type == "issue" or next_type == "repo_issue" then
      local chunk = ""
      local url = ""
      local p_end = pos
      
      if next_type == "url" then
        chunk = line:sub(url_start, url_end)
        url = chunk
        p_end = url_end
      elseif next_type == "user" then
        chunk = line:sub(u_start, u_end)
        url = "https://github.com/" .. chunk:sub(2)
        p_end = u_end
      elseif next_type == "repo_issue" then
        chunk = line:sub(r_start, r_end)
        local repo, num = chunk:match("([^#]+)#(%d+)")
        url = "https://github.com/" .. repo .. "/issues/" .. num
        p_end = r_end
      elseif next_type == "issue" then
        chunk = line:sub(i_start, i_end)
        local num = chunk:sub(2)
        url = "gh:" .. num
        p_end = i_end
      end
      
      local w = fonts.normal:get_width(chunk)
      local h = fonts.normal:get_height()
      
      table.insert(self.links, {
        x = x, y = y, w = w, h = h,
        url = url
      })
      
      local color = style.accent or {100, 180, 255, 255}
      x, y = draw_text_wrapped(fonts.normal, chunk, x, y, x_start, max_x, color)
      pos = p_end + 1
    end
  end
  return x, y
end

function MarkdownView:get_image_data(url, req_w, req_h, force)
  self.image_cache = self.image_cache or {}
  if not force and self.image_cache[url] then return self.image_cache[url] end
  
  self.image_cache[url] = self.image_cache[url] or "loading"
  
  local out_file = USERDIR .. "/img_" .. tostring(math.random(1000000)) .. ".lua"
  
  core.add_thread(function()
    local py_script = USERDIR .. "/plugins/img_to_rects.py"
    local cmd = {"python", py_script, url, out_file}
    if req_w and req_h then
      table.insert(cmd, tostring(req_w))
      table.insert(cmd, tostring(req_h))
    end
    local p = process.start(cmd)
    if p then
      while p:running() do coroutine.yield(0.1) end
      local f = io.open(out_file, "r")
        if f then
          f:close()
          local ok, res = pcall(dofile, out_file)
          if ok then
            self.image_cache[url] = res
            if self.image_scales then self.image_scales[url] = 1.0 end
          else
            self.image_cache[url] = { error = "Failed to parse Lua file" }
          end
          os.remove(out_file)
        else
          self.image_cache[url] = { error = "Python script failed to output" }
        end
    else
      self.image_cache[url] = { error = "Python not found" }
    end
    core.redraw = true
  end)
  
  return "loading"
end

function MarkdownView:draw()
  self:draw_background(style.background)
  self.links = {}
  self.buttons = {}
  self.image_scales = self.image_scales or {}
  
  local y = self.position.y - self.scroll.y + style.padding.y
  local x_start = self.position.x + style.padding.x
  local max_w = self.size.x - style.padding.x * 2
  
  local in_code = false
  
  for i, line in ipairs(self.doc.lines) do
    line = line:gsub("[\r\n]", "")
    if line:match("^```") then
      in_code = not in_code
      y = y + self.fonts.code:get_height()
      goto continue
    end
    
    local img_alt, img_url = line:match("^!%[([^%]]*)%]%(([^%)]+)%)")
    if not img_url then
      img_url = line:match("<img[^>]+src=[\"']([^\"']+)[\"']")
      img_alt = "HTML Image"
    end
    
    if not in_code and img_url then
      local img_data = self:get_image_data(img_url)
      if type(img_data) == "string" and img_data == "loading" then
        renderer.draw_text(self.fonts.normal, "🖼️ Loading image: " .. (img_alt or img_url), x_start, y, style.dim)
        y = y + self.fonts.normal:get_height()
      elseif type(img_data) == "table" and img_data.rects then
        local scale = self.image_scales[img_url] or 1.5
        local start_x = x_start
        local start_y = y
        
        -- Make the image clickable so the user can see it in full resolution
        table.insert(self.links, {
          x = start_x, y = start_y, 
          w = img_data.w * scale, h = img_data.h * scale, 
          url = img_url
        })
        
        for _, r in ipairs(img_data.rects) do
          local color = {r[4], r[5], r[6], 255}
          renderer.draw_rect(math.floor(start_x + r[1]*scale), math.floor(start_y + r[2]*scale), math.ceil(r[3]*scale), math.ceil(scale), color)
        end
        y = y + (img_data.h * scale) + 5
        
        if self.zoom_timer and self.zoom_timer[img_url] and system.get_time() > self.zoom_timer[img_url] then
          self.zoom_timer[img_url] = nil
          local target_w = math.floor(img_data.w * scale)
          local target_h = math.floor(img_data.h * scale)
          self:get_image_data(img_url, target_w, target_h, true)
        end
        
        -- Draw inline controls for real-time resizing & resolution
        local controls = {
          { label = "[-] Zoom Out", action = function() 
              self.image_scales[img_url] = math.max(0.2, scale - 0.2)
              self.zoom_timer = self.zoom_timer or {}
              self.zoom_timer[img_url] = system.get_time() + 0.5
            end },
          { label = "[+] Zoom In", action = function() 
              self.image_scales[img_url] = scale + 0.2
              self.zoom_timer = self.zoom_timer or {}
              self.zoom_timer[img_url] = system.get_time() + 0.5
            end },
          { label = "[HD] Max Res", action = function() 
              self:get_image_data(img_url, 800, 800, true) 
            end },
        }
        
        local cx = start_x
        for _, c in ipairs(controls) do
          local cw = self.fonts.normal:get_width(c.label)
          renderer.draw_text(self.fonts.normal, c.label, cx, y, style.accent)
          table.insert(self.buttons, { x = cx, y = y, w = cw, h = self.fonts.normal:get_height(), action = c.action })
          cx = cx + cw + 15
        end
        y = y + self.fonts.normal:get_height() + 10
      elseif type(img_data) == "table" and img_data.error then
        renderer.draw_text(self.fonts.normal, "❌ Failed to load image: " .. (img_data.error), x_start, y, {255, 100, 100, 255})
        y = y + self.fonts.normal:get_height()
      end
      goto continue
    end
    
    local font = self.fonts.normal
    local color = style.text
    local bg = nil
    local x = x_start
    
    if in_code then
      font = self.fonts.code
      color = style.syntax.string or style.text
      bg = style.line_highlight
      renderer.draw_text(font, line, x, y, color)
    else
      local is_chat_header = (line:match("ago%s*$") or line:match("edited.*$")) and #line < 60
      if is_chat_header then
        font = self.fonts.bold
        color = style.accent or {100, 180, 255, 255}
        renderer.draw_rect(x_start, y - 4, max_w, 1, style.dim)
        y = y + 8
      end
      
      local h1 = line:match("^# %s*(.*)")
      local h2 = line:match("^## %s*(.*)")
      local h3 = line:match("^### %s*(.*)")
      
      if h1 then font = self.fonts.h1; line = h1; color = style.syntax.keyword or style.text end
      if not h1 and h2 then font = self.fonts.h2; line = h2; color = style.syntax.keyword or style.text end
      if not h1 and not h2 and h3 then font = self.fonts.h3; line = h3; color = style.syntax.keyword or style.text end
      
      if line:match("^%s*>") then
        color = style.dim
        renderer.draw_rect(x_start, y, 4, font:get_height(), style.dim)
        x = x + 10
        bg = style.line_highlight
      end
      if line:match("^%-%-%-+") then
        local hr_y = y + math.floor(font:get_height()/2)
        renderer.draw_rect(x_start, hr_y, max_w, 2, style.dim)
        y = y + font:get_height()
        goto continue
      end
    end
    
    local line_h = font:get_height() + 4
    
    if y + line_h >= self.position.y and y <= self.position.y + self.size.y then
      if bg then
        renderer.draw_rect(x_start - 5, y, max_w + 10, line_h, bg)
      end
      
      if in_code or font ~= self.fonts.normal then
        renderer.draw_text(font, line, x, y, color)
      else
        x, y = draw_inline_markdown(self, line, x, y, self.fonts, color, x_start, x_start + max_w)
      end
    end
    
    y = y + line_h
    ::continue::
  end
  
  self.max_scroll.y = math.max(0, y - (self.position.y - self.scroll.y) - self.size.y + style.padding.y)
end

function MarkdownView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and self.buttons then
    for _, btn in ipairs(self.buttons) do
      if x >= btn.x and x < btn.x + btn.w and y >= btn.y and y < btn.y + btn.h then
        btn.action()
        core.redraw = true
        return true
      end
    end
  end
  
  if button == "left" and self.links then
    for _, link in ipairs(self.links) do
      if x >= link.x and x < link.x + link.w and y >= link.y and y < link.y + link.h then
        local url = link.url:gsub('"', '\\"')
        if url:match("^gh:(%d+)") then
          local num = url:match("^gh:(%d+)")
          -- Use gh to open the current repo's issue/pr in the browser
          system.exec('gh issue view --web ' .. num)
        else
          if PLATFORM == "Windows" then
            system.exec('cmd.exe /c start "" "' .. url .. '"')
          elseif PLATFORM == "Mac OS X" then
            system.exec('open "' .. url .. '"')
          else
            system.exec('xdg-open "' .. url .. '"')
          end
        end
        return true
      end
    end
  end
  return MarkdownView.super.on_mouse_pressed(self, button, x, y, clicks)
end

function MarkdownView:on_mouse_wheel(dy, x, y)
  if keymap.modkeys["ctrl"] and self.links then
    -- Find if we are hovering over an image URL
    for _, link in ipairs(self.links) do
      if core.window.mouse_x >= link.x and core.window.mouse_x < link.x + link.w and 
         core.window.mouse_y >= link.y and core.window.mouse_y < link.y + link.h then
        local url = link.url
        self.image_scales[url] = math.max(0.2, (self.image_scales[url] or 1.5) + (dy * 0.1))
        self.zoom_timer = self.zoom_timer or {}
        self.zoom_timer[url] = system.get_time() + 0.5
        core.redraw = true
        return true
      end
    end
  end
  return MarkdownView.super.on_mouse_wheel(self, dy, x, y)
end

function MarkdownView:on_mouse_moved(x, y, dx, dy)
  self.mouse_x = x
  self.mouse_y = y
  return MarkdownView.super.on_mouse_moved(self, x, y, dx, dy)
end

function MarkdownView:update()
  MarkdownView.super.update(self)
  if not self.mouse_x then return end
  
  local x, y = self.mouse_x, self.mouse_y
  local hovering_link = false
  
  if self.buttons then
    for _, btn in ipairs(self.buttons) do
      if x >= btn.x and x < btn.x + btn.w and y >= btn.y and y < btn.y + btn.h then
        hovering_link = true
        break
      end
    end
  end
  
  if not hovering_link and self.links then
    for _, link in ipairs(self.links) do
      if x >= link.x and x < link.x + link.w and y >= link.y and y < link.y + link.h then
        hovering_link = true
        break
      end
    end
  end
  
  if hovering_link then
    self.cursor = "hand"
  end
end

command.add("core.docview", {
  ["markdown:open-native-preview"] = function()
    core.log("MARKDOWN: Command triggered!")
    local doc = core.active_view.doc
    if not doc then
      core.log("MARKDOWN: Error - active_view has no doc!")
      return
    end
    
    core.log("MARKDOWN: Instantiating MarkdownView for " .. tostring(doc.filename))
    local view = MarkdownView(doc)
    
    local node = core.root_view:get_active_node()
    if node.locked then
      core.log("MARKDOWN: Node is locked, switching to primary node")
      node = core.root_view:get_primary_node()
    end
    
    core.log("MARKDOWN: Splitting node right!")
    node:split("right", view)
    core.log("MARKDOWN: Split successful!")
  end
})

keymap.add { ["ctrl+shift+m"] = "markdown:open-native-preview" }

return MarkdownView



