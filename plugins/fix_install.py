import re

with open(r"C:\Users\ojasw\.config\lite-xl\plugins\antigravity_sidebar.lua", "r", encoding="utf-8") as f:
    content = f.read()

# 1. Update install_skill
old_install = """      local p = process.start({"python", bridge, "--install-skill", "FILE:" .. tmp_file})
      while p:running() do coroutine.yield(0.1) end
      core.log("Installed AI Skill: " .. (skill_obj.title or "Custom Skill"))
      self:fetch_marketplace()"""

new_install = """      local p
      if self.show_tools_tab then
          p = process.start({"python", bridge, "--install-tool", skill_obj.id})
      else
          p = process.start({"python", bridge, "--install-skill", "FILE:" .. tmp_file})
      end
      while p:running() do coroutine.yield(0.1) end
      core.log("Installed: " .. (skill_obj.title or "Custom Item"))
      self:fetch_marketplace()"""

content = content.replace(old_install, new_install)

# 2. Update uninstall_skill
old_uninstall = """        local p, err = process.start({"python", bridge, "--uninstall-skill", skill_id})"""
new_uninstall = """        local flag = self.show_tools_tab and "--uninstall-tool" or "--uninstall-skill"
        local p, err = process.start({"python", bridge, flag, skill_id})"""

content = content.replace(old_uninstall, new_uninstall)

with open(r"C:\Users\ojasw\.config\lite-xl\plugins\antigravity_sidebar.lua", "w", encoding="utf-8") as f:
    f.write(content)

print("Fixed install/uninstall routing!")