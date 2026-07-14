-- mod-version:3
-- VS Code style Activity Bar for Lite XL
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"

local ActivityBar = View:extend()

function ActivityBar:new()
  ActivityBar.super.new(self)
  self.name = "ActivityBar"
  self.size = { x = 48 * SCALE, y = 0 }
  
  self.items = {
    { id = "docker",   icon = "\u{f308}", command = "docker:toggle",    tooltip = "Docker" },
    { id = "leetcode", icon = "\u{e653}", command = "leetcode:toggle",   tooltip = "LeetCode" },
    { id = "mongodb",  icon = "\u{e7a4}", command = "mongodb:activity-bar", tooltip = "MongoDB" }
  }
  -- Bottom-anchored auth button
  self.auth_item = { id = "auth", icon = "\u{f084}", command = "antigravity:toggle", tooltip = "AGY Auth / Toggle AI" }
  self.active_id = "docker"
  self.target_size = 48 * SCALE
  self.visible = false -- Start hidden; will be pulled open by the AI Sidebar
end

function ActivityBar:get_name() return self.name end

function ActivityBar:update()
  ActivityBar.super.update(self)
  
  -- Dynamically check if the AI sidebar is active and has views
  local sidebar = _G.get_sidebar_node and _G.get_sidebar_node(true)
  local has_views = sidebar and sidebar.views and #sidebar.views > 0
  
  -- If sidebar is closed/empty, hide the Activity Bar so it "slides along with it"
  if has_views and not self.visible then
    self.visible = true
  elseif not has_views and self.visible then
    self.visible = false
  end
  
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "x", dest)
end

function ActivityBar:get_auth_label()
  -- Read auth info from the global AGView instance if available
  local inst = rawget(_G, "_ag_instance")
  if inst and inst.auth_status == "logged_in" then
    local home = os.getenv("USERPROFILE") or os.getenv("HOME") or ""
    local sep = PLATFORM == "Windows" and "\\" or "/"
    local state_path = home .. sep .. ".gemini" .. sep .. "antigravity-cli" .. sep .. "jetski_state.pbtxt"
    local f = io.open(state_path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local email = content:match('email:%s*"([^"]+)"')
                 or content:match("email:%s*'([^']+)'")
      if email then
        return email:match("^([^@]+)") or email
      end
    end
    return os.getenv("USER") or os.getenv("USERNAME") or "AGY"
  elseif inst and inst.auth_status == "auth_error" then
    return "Auth Error!"
  end
  return "AGY Auth"
end

function ActivityBar:draw()
  self:draw_background(style.background3 or style.background)
  local x, y = self.position.x, self.position.y
  local cell = 48 * SCALE
  
  -- Draw top regular items
  local item_y = y
  for _, item in ipairs(self.items) do
    local is_active = (self.active_id == item.id)
    local hovered = self.mouse_y and self.mouse_y >= item_y and self.mouse_y < item_y + cell
    local color = (is_active or hovered) and style.text or style.dim
    
    if is_active then
      renderer.draw_rect(x, item_y, 2 * SCALE, cell, style.accent)
    end
    if hovered then
      renderer.draw_rect(x, item_y, self.size.x, cell, { 255, 255, 255, 15 })
    end
    
    local icon_w = style.icon_font:get_width(item.icon)
    local icon_h = style.icon_font:get_height()
    local hx = x + (self.size.x - icon_w) / 2
    local hy = item_y + (cell - icon_h) / 2
    renderer.draw_text(style.icon_font, item.icon, hx, hy, color)
    item_y = item_y + cell
  end
  
  -- Draw bottom-anchored AGY Auth button
  local auth = self.auth_item
  local auth_y = y + self.size.y - cell
  if auth_y > item_y then -- only draw if it doesn't overlap items
    local inst = rawget(_G, "_ag_instance")
    local is_authed = inst and inst.auth_status == "logged_in"
    local hovered = self.mouse_y and self.mouse_y >= auth_y and self.mouse_y < auth_y + cell
    local auth_color = is_authed and (style.accent or style.text)
                    or (hovered and style.text or style.dim)
    
    -- Subtle separator line above auth button
    renderer.draw_rect(x + 8 * SCALE, auth_y, self.size.x - 16 * SCALE, math.max(1, SCALE), { 255, 255, 255, 30 })
    
    if hovered then
      renderer.draw_rect(x, auth_y, self.size.x, cell, { 255, 255, 255, 15 })
    end
    
    local icon = auth.icon
    local icon_w = style.icon_font:get_width(icon)
    local icon_h = style.icon_font:get_height()
    local hx = x + (self.size.x - icon_w) / 2
    local hy = auth_y + (cell - icon_h) / 2
    renderer.draw_text(style.icon_font, icon, hx, hy, auth_color)
  end
end

function ActivityBar:on_mouse_moved(x, y)
  self.mouse_y = y
  core.redraw = true
end

function ActivityBar:on_mouse_left()
  self.mouse_y = nil
  core.redraw = true
end

function ActivityBar:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    local cell = 48 * SCALE
    local rel_y = y - self.position.y
    local auth_y_start = self.size.y - cell
    
    -- Check if click is in the bottom auth button zone
    if rel_y >= auth_y_start and rel_y < self.size.y then
      command.perform(self.auth_item.command)
      return true
    end
    
    -- Check regular items
    local idx = math.floor(rel_y / cell) + 1
    if self.items[idx] then
      local item = self.items[idx]
      local current_node = _G.get_sidebar_node and _G.get_sidebar_node(true)
      
      if self.active_id == item.id and current_node and #current_node.views > 0 then
        for i = #current_node.views, 1, -1 do
          current_node:close_view(core.root_view.root_node, current_node.views[i])
        end
      else
        self.active_id = item.id
        command.perform(item.command)
      end
      return true
    end
  end
end

local activity_bar = nil
local sidebar_node = nil

local function is_node_in_tree(root, target)
  if not root then return false end
  if root == target then return true end
  if root.type == "leaf" then return false end
  return is_node_in_tree(root.a, target) or is_node_in_tree(root.b, target)
end

rawset(_G, "get_sidebar_node", function(dont_create)
  if not activity_bar then return nil end
  local ab_node = core.root_view.root_node:get_node_for_view(activity_bar)
  if not ab_node then return nil end
  
  local function apply_monkey_patch(node)
    if not node._ab_patched then
      local old_add_view = node.add_view
      node.add_view = function(self, view)
        local l = self.locked
        self.locked = nil
        old_add_view(self, view)
        self.locked = l
      end
      node._ab_patched = true
    end
    -- Ensure the active_view always has set_target_size to prevent node.lua:682 crash
    -- when user drags the resize divider on a node whose view doesn't implement it.
    if node.active_view and not node.active_view.set_target_size then
      node.active_view.set_target_size = function(self, axis, value) return true end
    end
    return node
  end
  
  if sidebar_node and is_node_in_tree(core.root_view.root_node, sidebar_node) then
    return apply_monkey_patch(sidebar_node)
  end
  
  -- Also check if toggle registered a node directly
  local ag_node = rawget(_G, "_ag_sidebar_node")
  if ag_node and is_node_in_tree(core.root_view.root_node, ag_node) then
    sidebar_node = ag_node
    return apply_monkey_patch(sidebar_node)
  end
  
  -- Dynamically search for any existing custom sidebar in the tree
  local found_sidebar = nil
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view and (view.name == "Docker" or view.name == "LeetCode" or view.name == "Antigravity") then
      found_sidebar = core.root_view.root_node:get_node_for_view(view)
      break
    end
  end
  
  if found_sidebar then
    sidebar_node = found_sidebar
    sidebar_node.should_show_tabs = function() return false end
    return apply_monkey_patch(sidebar_node)
  end
  
  -- Return nil so the caller (antigravity:toggle) can do split with the actual view.
  -- This avoids ever creating an empty sidebar node with no set_target_size on its EmptyView.
  if dont_create then return nil end
  return nil
end)

local function init_activity_bar()
  local target_node = nil
  
  -- Find any existing custom sidebar if it is already open
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view and (view.name == "Docker" or view.name == "LeetCode" or view.name == "Antigravity") then
      target_node = core.root_view.root_node:get_node_for_view(view)
      break
    end
  end
  
  -- If no sidebar exists, safely attach directly to the primary editor node
  -- This prevents the Activity Bar from getting trapped in top/bottom/side Resource Monitors!
  if not target_node then
    target_node = core.root_view:get_primary_node()
  end
  if not target_node then return end
  
  -- Create the Activity Bar
  activity_bar = ActivityBar()
  
  -- Split the target node to place Activity Bar on its extreme RIGHT edge
  local ab_node = target_node:split("right", activity_bar, {x = true}, false)
  
  -- Because target_node was split, it was converted into an hsplit.
  -- The original contents (Editor or old sidebar) are now in target_node.a
  local sibling_node = target_node.a
  
  -- Check if the sibling node is actually a custom sidebar panel (and not the editor)
  local is_sidebar = false
  if sibling_node and sibling_node.views then
    for _, view in ipairs(sibling_node.views) do
      if view and (view.name == "Docker" or view.name == "LeetCode" or view.name == "Antigravity") then
        is_sidebar = true
        break
      end
    end
  end
  
  if is_sidebar then
    sidebar_node = sibling_node
    sidebar_node.should_show_tabs = function() return false end
  else
    sidebar_node = nil
  end
    
    -- Do not override treeview:toggle anymore. Let it function normally.
    command.add(nil, {
      ["mongodb:activity-bar"] = function()
        local mongo = require("plugins.mongodb_explorer")
        if not mongo.uri then
          command.perform("mongodb:connect")
        else
          command.perform("mongodb:explore-databases")
        end
      end
    })
end

core.add_thread(function()
  -- Wait a bit for treeview and other plugins to initialize
  while not core.root_view or not core.root_view.root_node do coroutine.yield(0.1) end
  coroutine.yield(0.1)
  init_activity_bar()
end)
