import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

# Add arg
bad_arg = """    parser.add_argument("--uninstall-tool", type=str)
    parser.add_argument("--get-installed-tools", action="store_true")"""
    
good_arg = """    parser.add_argument("--uninstall-tool", type=str)
    parser.add_argument("--get-installed-tools", action="store_true")
    parser.add_argument("--set-tool-env", nargs=3, metavar=("TOOL_ID", "KEY", "VALUE"))"""

content = content.replace(bad_arg, good_arg)

# Add logic
logic = """
    if args.set_tool_env:
        import json, os
        tool_id, key, val = args.set_tool_env
        config_dir = os.path.dirname(os.path.abspath(__file__))
        mcp_config_path = os.path.join(config_dir, "mcp_config.json")
        if os.path.exists(mcp_config_path):
            with open(mcp_config_path, "r", encoding="utf-8") as f:
                mcp_data = json.load(f)
            
            if tool_id in mcp_data.get("mcpServers", {}):
                if "env" not in mcp_data["mcpServers"][tool_id]:
                    mcp_data["mcpServers"][tool_id]["env"] = {}
                mcp_data["mcpServers"][tool_id]["env"][key] = val
                
                with open(mcp_config_path, "w", encoding="utf-8") as f:
                    json.dump(mcp_data, f, indent=4)
        print("OK")
        sys.exit(0)
"""

content = content.replace("    if args.uninstall_tool:", logic + "    if args.uninstall_tool:")

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "w", encoding="utf-8") as f:
    f.write(content)

print("Added --set-tool-env")