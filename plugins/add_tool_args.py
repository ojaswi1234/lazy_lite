import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

# 1. Add tool management arguments to parser
old_parser = """    parser.add_argument("--add-resource", type=str)
    parser.add_argument("--get-installed-skills", action="store_true")
    parser.add_argument("--enable-tools", action="store_true")"""

new_parser = """    parser.add_argument("--add-resource", type=str)
    parser.add_argument("--get-installed-skills", action="store_true")
    parser.add_argument("--enable-tools", action="store_true")
    
    # Tool Management
    parser.add_argument("--get-marketplace-tools", action="store_true")
    parser.add_argument("--install-tool", type=str)
    parser.add_argument("--uninstall-tool", type=str)
    parser.add_argument("--get-installed-tools", action="store_true")"""

content = content.replace(old_parser, new_parser)

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "w", encoding="utf-8") as f:
    f.write(content)

print("Parser arguments added")