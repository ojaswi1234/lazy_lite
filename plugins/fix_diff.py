import os

with open(r"C:\Users\ojasw\.config\lite-xl\plugins\diff_utf8.txt", "r", encoding="utf-8") as f:
    diff_lines = f.readlines()

out_diff = []
for line in diff_lines:
    if line.startswith("-") and "renderer.draw_text" in line:
        out_diff.append(" " + line[1:])
    else:
        out_diff.append(line)

with open(r"C:\Users\ojasw\.config\lite-xl\plugins\diff_fixed.txt", "w", encoding="utf-8") as f:
    f.writelines(out_diff)