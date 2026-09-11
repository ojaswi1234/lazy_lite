import re

with open(r"C:\Users\ojasw\.config\lite-xl\plugins\antigravity_sidebar.lua", "r", encoding="utf-8") as f:
    content = f.read()

bad = "  renderer.draw_text((style.big_font or style.font), title, mx + pad, ty, P.fg)\n"
good = ""

content = content.replace(bad, good)

with open(r"C:\Users\ojasw\.config\lite-xl\plugins\antigravity_sidebar.lua", "w", encoding="utf-8") as f:
    f.write(content)

print("Title variable error fixed!")