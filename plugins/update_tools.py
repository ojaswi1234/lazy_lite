import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

bad = """        tools = [
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
        ]"""

good = """        tools = [
            {
                "id": "mcp-sqlite",
                "name": "SQLite Database",
                "author": "ModelContextProtocol",
                "description": "[Tool] Allows the AI to inspect, query, and modify SQLite databases local to your machine.",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-sqlite", "database.db"]
            },
            {
                "id": "mcp-filesystem",
                "name": "Local Filesystem",
                "author": "ModelContextProtocol",
                "description": "[Tool] Secure, scoped read/write access to specific local directories.",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-filesystem", "C:/Users/ojasw/Desktop"]
            },
            {
                "id": "mcp-puppeteer",
                "name": "Puppeteer Browser",
                "author": "ModelContextProtocol",
                "description": "[Tool] Empowers the AI to control a headless Chrome browser for web scraping and automation.",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-puppeteer"]
            },
            {
                "id": "mcp-github",
                "name": "GitHub Connector",
                "author": "ModelContextProtocol",
                "description": "[Connector] Grants read/write access to GitHub repositories, issues, and PRs. Requires GITHUB_PERSONAL_ACCESS_TOKEN.",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-github"],
                "env_requirements": ["GITHUB_PERSONAL_ACCESS_TOKEN"]
            },
            {
                "id": "mcp-slack",
                "name": "Slack Connector",
                "author": "ModelContextProtocol",
                "description": "[Connector] Read and write messages to Slack workspaces. Requires SLACK_BOT_TOKEN.",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-slack"],
                "env_requirements": ["SLACK_BOT_TOKEN"]
            },
            {
                "id": "mcp-canvas",
                "name": "Canvas LMS Connector",
                "author": "Community",
                "description": "[Connector] Access course materials, assignments, and grades from Canvas LMS. Requires CANVAS_API_KEY.",
                "command": "python",
                "args": ["-m", "mcp_canvas_server"],
                "env_requirements": ["CANVAS_API_KEY", "CANVAS_BASE_URL"]
            }
        ]"""

content = content.replace(bad, good)

# Also update the tools_db in install_tool to have the new servers!
bad_db = """        tools_db = {
            "mcp-sqlite": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-sqlite", "database.db"]},
            "mcp-github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"]},
            "mcp-brave-search": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-brave-search"]}
        }"""
        
good_db = """        tools_db = {
            "mcp-sqlite": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-sqlite", "database.db"]},
            "mcp-filesystem": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "C:/Users/ojasw/Desktop"]},
            "mcp-puppeteer": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-puppeteer"]},
            "mcp-github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env_requirements": ["GITHUB_PERSONAL_ACCESS_TOKEN"]},
            "mcp-slack": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-slack"], "env_requirements": ["SLACK_BOT_TOKEN"]},
            "mcp-canvas": {"command": "python", "args": ["-m", "mcp_canvas_server"], "env_requirements": ["CANVAS_API_KEY", "CANVAS_BASE_URL"]}
        }"""

content = content.replace(bad_db, good_db)

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "w", encoding="utf-8") as f:
    f.write(content)

print("Updated tools database with connectors!")