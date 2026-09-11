with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    lines = f.readlines()

new_lines = []
in_async_block = False

for line in lines:
    if "graph = graph_builder.compile(checkpointer=memory)" in line:
        in_async_block = True
        new_lines.append(line)
        continue
        
    if in_async_block:
        if line.startswith("def main():") or line.startswith("    def main():") or line.strip() == "def main():":
            in_async_block = False
            new_lines.append(line)
            continue
            
        if line.strip() != "":
            # Indent by 8 spaces
            new_lines.append("        " + line)
        else:
            new_lines.append(line)
    else:
        new_lines.append(line)

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "w", encoding="utf-8") as f:
    f.writelines(new_lines)

print("Indented successfully!")