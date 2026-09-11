import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

tool_logic = """
    # Tool Management Execution Blocks
    if args.get_marketplace_tools:
        import json, os
        # Return a curated list of tools for the marketplace UI
        tools = [
            {
                "id": "mcp-sqlite",
                "name": "SQLite MCP Server",
                "author": "ModelContextProtocol",
                "description": "Allows the AI to inspect, query, and modify SQLite databases.",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-sqlite", "database.db"]
            },
            {
                "id": "mcp-github",
                "name": "GitHub MCP Server",
                "author": "ModelContextProtocol",
                "description": "Provides read/write access to GitHub repositories, issues, and PRs.",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-github"]
            },
            {
                "id": "mcp-brave-search",
                "name": "Brave Search",
                "author": "ModelContextProtocol",
                "description": "Empowers the AI to search the web securely using Brave Search API.",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-brave-search"]
            }
        ]
        print(json.dumps(tools))
        sys.exit(0)

    if args.get_installed_tools:
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
        print(json.dumps(installed))
        sys.exit(0)

    if args.install_tool:
        import json, os
        import urllib.request
        
        # In a real app we'd fetch this from the central JSON. For now we hardcode the matches for the demo.
        tools_db = {
            "mcp-sqlite": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-sqlite", "database.db"]},
            "mcp-github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"]},
            "mcp-brave-search": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-brave-search"]}
        }
        
        target = args.install_tool
        if target in tools_db:
            config_dir = os.path.dirname(os.path.abspath(__file__))
            mcp_config_path = os.path.join(config_dir, "mcp_config.json")
            mcp_data = {"mcpServers": {}}
            if os.path.exists(mcp_config_path):
                try:
                    with open(mcp_config_path, "r") as f:
                        mcp_data = json.load(f)
                except: pass
            
            if "mcpServers" not in mcp_data:
                mcp_data["mcpServers"] = {}
                
            mcp_data["mcpServers"][target] = tools_db[target]
            
            with open(mcp_config_path, "w", encoding="utf-8") as f:
                json.dump(mcp_data, f, indent=4)
            print("OK")
        else:
            print("Error: Tool not found in marketplace.")
        sys.exit(0)

    if args.uninstall_tool:
        import json, os
        target = args.uninstall_tool
        config_dir = os.path.dirname(os.path.abspath(__file__))
        mcp_config_path = os.path.join(config_dir, "mcp_config.json")
        
        if os.path.exists(mcp_config_path):
            try:
                with open(mcp_config_path, "r") as f:
                    mcp_data = json.load(f)
                if target in mcp_data.get("mcpServers", {}):
                    del mcp_data["mcpServers"][target]
                    with open(mcp_config_path, "w", encoding="utf-8") as f:
                        json.dump(mcp_data, f, indent=4)
                print("OK")
            except Exception as e:
                print(f"Error: {str(e)}")
        else:
            print("OK")
        sys.exit(0)
"""

content = content.replace("    if args.chat:", tool_logic + "\n    if args.chat:")

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "w", encoding="utf-8") as f:
    f.write(content)

print("Tool logic added!")