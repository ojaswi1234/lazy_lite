import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

bad = """    if args.get_installed_tools:
        import json, os
        config_dir = os.path.dirname(os.path.abspath(__file__))
        mcp_config_path = os.path.join(config_dir, "mcp_config.json")
        installed = []
        if os.path.exists(mcp_config_path):
            try:
                with open(mcp_config_path, "r") as f:
                    mcp_data = json.load(f)
                installed = list(mcp_data.get("mcpServers", {}).keys())
            except: pass
        if args.out_file:
            with open(args.out_file, "w", encoding="utf-8") as f:
                json.dump(installed, f)
        else:
            print(json.dumps(installed))
        sys.exit(0)"""

good = """    if args.get_installed_tools:
        import json, os
        config_dir = os.path.dirname(os.path.abspath(__file__))
        mcp_config_path = os.path.join(config_dir, "mcp_config.json")
        installed = []
        if os.path.exists(mcp_config_path):
            try:
                with open(mcp_config_path, "r") as f:
                    mcp_data = json.load(f)
                for k, v in mcp_data.get("mcpServers", {}).items():
                    installed.append({
                        "id": k,
                        "title": k,
                        "description": "Command: " + v.get("command", "") + " " + " ".join(v.get("args", []))
                    })
            except: pass
        if args.out_file:
            with open(args.out_file, "w", encoding="utf-8") as f:
                json.dump(installed, f)
        else:
            print(json.dumps(installed))
        sys.exit(0)"""

content = content.replace(bad, good)

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "w", encoding="utf-8") as f:
    f.write(content)

print("Installed tools formatting fixed!")