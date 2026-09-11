import json, re

path = r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# We need to find the `get_marketplace_tools` block and `install_tool` block.
# Let's just find and replace the hardcoded `tools = [...]` and `tools_db = {...}`.

# Extract the old tools list text using regex
tools_pattern = r'tools = \[\s*\{\s*"id": "mcp-sqlite".*?\s*\]'
tools_match = re.search(tools_pattern, content, re.DOTALL)

tools_db_pattern = r'tools_db = \{\s*"mcp-sqlite":.*?\s*\}'
tools_db_match = re.search(tools_db_pattern, content, re.DOTALL)

if not tools_match or not tools_db_match:
    print("Could not find tools or tools_db blocks!")
    import sys; sys.exit(1)

new_tools = """tools = [
            {
                "id": "mcp-sqlite", "name": "SQLite", "title": "SQLite", "author": "ModelContextProtocol",
                "description": "Inspect, query, and modify local SQLite databases.",
                "command": "npx", "args": ["-y", "@modelcontextprotocol/server-sqlite", "database.db"]
            },
            {
                "id": "mcp-postgres", "name": "PostgreSQL", "title": "PostgreSQL", "author": "ModelContextProtocol",
                "description": "Read and query PostgreSQL databases.",
                "command": "npx", "args": ["-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost/mydb"]
            },
            {
                "id": "mcp-github", "name": "GitHub", "title": "GitHub", "author": "ModelContextProtocol",
                "description": "Read/write access to GitHub repos, issues, and PRs (needs GITHUB_PERSONAL_ACCESS_TOKEN env).",
                "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"]
            },
            {
                "id": "mcp-brave-search", "name": "Brave Search", "title": "Brave Search", "author": "ModelContextProtocol",
                "description": "Web and local search via Brave Search API (needs BRAVE_API_KEY env).",
                "command": "npx", "args": ["-y", "@modelcontextprotocol/server-brave-search"]
            },
            {
                "id": "mcp-fetch", "name": "Fetch API", "title": "Fetch API", "author": "ModelContextProtocol",
                "description": "Fetch and convert web pages/APIs to markdown optimized for LLMs.",
                "command": "npx", "args": ["-y", "@modelcontextprotocol/server-fetch"]
            },
            {
                "id": "mcp-puppeteer", "name": "Puppeteer", "title": "Puppeteer", "author": "ModelContextProtocol",
                "description": "Browser automation for live web scraping and interaction.",
                "command": "npx", "args": ["-y", "@modelcontextprotocol/server-puppeteer"]
            },
            {
                "id": "mcp-memory", "name": "Memory/Knowledge Graph", "title": "Memory", "author": "ModelContextProtocol",
                "description": "Provides a persistent knowledge graph memory layer for the AI.",
                "command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory"]
            },
            {
                "id": "mcp-filesystem", "name": "Filesystem", "title": "Filesystem", "author": "ModelContextProtocol",
                "description": "Provides secure, sandboxed file access to specific directories.",
                "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "./"]
            },
            {
                "id": "mcp-slack", "name": "Slack", "title": "Slack", "author": "ModelContextProtocol",
                "description": "Read channels and send messages via Slack (needs SLACK_BOT_TOKEN).",
                "command": "npx", "args": ["-y", "@modelcontextprotocol/server-slack"]
            },
            {
                "id": "mcp-google-maps", "name": "Google Maps", "title": "Google Maps", "author": "ModelContextProtocol",
                "description": "Location, routing, and places API via Google Maps (needs GOOGLE_MAPS_API_KEY).",
                "command": "npx", "args": ["-y", "@modelcontextprotocol/server-google-maps"]
            }
        ]"""

new_tools_db = """tools_db = {
            "mcp-sqlite": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-sqlite", "database.db"]},
            "mcp-postgres": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost/mydb"]},
            "mcp-github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"]},
            "mcp-brave-search": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-brave-search"]},
            "mcp-fetch": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-fetch"]},
            "mcp-puppeteer": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-puppeteer"]},
            "mcp-memory": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory"]},
            "mcp-filesystem": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "./"]},
            "mcp-slack": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-slack"]},
            "mcp-google-maps": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-google-maps"]}
        }"""

content = content[:tools_match.start()] + new_tools + content[tools_match.end():]

# Need to recalculate match position for tools_db since we changed the string length
tools_db_match = re.search(tools_db_pattern, content, re.DOTALL)
content = content[:tools_db_match.start()] + new_tools_db + content[tools_db_match.end():]

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("Expanded MCP database successfully.")