import re

with open(r"C:\Users\ojasw\.config\lite-xl\plugins\antigravity_sidebar.lua", "r", encoding="utf-8") as f:
    content = f.read()

# Let's replace the ENTIRE install_skill and uninstall_skill functions using robust regex.
pattern = r"function AGView:uninstall_skill\(skill_id\).*?end\)\s*end\s*function AGView:install_skill\(skill_input\).*?end\)\s*end"

new_funcs = """function AGView:uninstall_skill(skill_id)
  core.add_thread(function()
      local bridge = USERDIR .. "/scripts/ai_api_bridge.py"
      local flag = self.show_tools_tab and "--uninstall-tool" or "--uninstall-skill"
      local p, err = process.start({"python", bridge, flag, skill_id})
      if p then
          while p:running() do coroutine.yield(0.1) end
          core.log("Uninstalled: " .. skill_id)
          self:fetch_marketplace()
          core.redraw = true
      end
  end)
end

function AGView:install_skill(skill_input)
  local skill_obj = nil
  if type(skill_input) == "table" then
    skill_obj = skill_input
  else
    for _, s in ipairs(self.marketplace_skills or {}) do
      if s.id == skill_input then
        skill_obj = s
        break
      end
    end
  end
  if not skill_obj then return end
  
  core.add_thread(function()
    local env_vals = {}
    if self.show_tools_tab and skill_obj.env_requirements and #skill_obj.env_requirements > 0 then
      for _, req in ipairs(skill_obj.env_requirements) do
        local done = false
        core.command_view:enter("Enter value for " .. req, {
          submit = function(text)
            env_vals[req] = text
            done = true
          end
        })
        while not done do coroutine.yield(0.1) end
      end
    end

    local bridge = USERDIR .. "/scripts/ai_api_bridge.py"
    if self.show_tools_tab then
      local p = process.start({"python", bridge, "--install-tool", skill_obj.id})
      while p:running() do coroutine.yield(0.1) end
      
      -- Send envs to python if any
      for k, v in pairs(env_vals) do
        local p2 = process.start({"python", bridge, "--set-tool-env", skill_obj.id, k, v})
        while p2:running() do coroutine.yield(0.1) end
      end
      
      core.log("Installed MCP Tool: " .. (skill_obj.title or skill_obj.name or skill_obj.id))
      self:fetch_marketplace()
    else
      local ok_json, json = pcall(require, "plugins.lsp.json")
      if not ok_json then return end
      local tmp_file = USERDIR .. "/scripts/.tmp_skill.json"
      local f = io.open(tmp_file, "w")
      if f then
        f:write(json.encode(skill_obj))
        f:close()
      end
      local p = process.start({"python", bridge, "--install-skill", "FILE:" .. tmp_file})
      while p:running() do coroutine.yield(0.1) end
      core.log("Installed AI Skill: " .. (skill_obj.title or "Custom Skill"))
      self:fetch_marketplace()
    end
  end)
end"""

if re.search(pattern, content, re.DOTALL):
    content = re.sub(pattern, new_funcs, content, flags=re.DOTALL)
    with open(r"C:\Users\ojasw\.config\lite-xl\plugins\antigravity_sidebar.lua", "w", encoding="utf-8") as f:
        f.write(content)
    print("Replaced lua functions successfully!")
else:
    print("Regex failed to match functions!")