import sys, re, os

path = r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# First we need to find the block we (the agents) injected earlier.
# Let's use regex to find the entire block from `if args.get_marketplace_tools or ... :` up to the `sys.exit(0)` before `keys = load_keys()`

start_marker = "    if args.get_marketplace_tools or args.get_marketplace_skills or args.get_installed_tools or args.get_installed_skills:"
end_marker = "        sys.exit(0)\n\n    keys = load_keys()"

if start_marker in content and end_marker in content:
    start_idx = content.find(start_marker)
    end_idx = content.find(end_marker) + len("        sys.exit(0)\n\n")
    old_block = content[start_idx:end_idx]
else:
    print("Could not find the injected marketplace block.")
    sys.exit(1)

new_block = r"""    if args.get_marketplace_tools:
        import json, os
        # User's original curated list of tools for the marketplace UI
        tools = [
            {
                "id": "mcp-sqlite",
                "name": "SQLite MCP Server",
                "title": "SQLite MCP Server",
                "author": "ModelContextProtocol",
                "description": "Allows the AI to inspect, query, and modify SQLite databases.",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-sqlite", "database.db"]
            },
            {
                "id": "mcp-github",
                "name": "GitHub MCP Server",
                "title": "GitHub MCP Server",
                "author": "ModelContextProtocol",
                "description": "Provides read/write access to GitHub repositories, issues, and PRs.",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-github"]
            },
            {
                "id": "mcp-brave-search",
                "name": "Brave Search",
                "title": "Brave Search",
                "author": "ModelContextProtocol",
                "description": "Empowers the AI to search the web securely using Brave Search API.",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-brave-search"]
            }
        ]
        
        # Wrapped for Lua table structure
        data = {"data": tools, "total_pages": 1}
        if args.out_file:
            with open(args.out_file, "w", encoding="utf-8") as f: json.dump(data, f)
        else:
            print(json.dumps(data))
        sys.exit(0)

    if args.get_installed_tools:
        import json, os
        config_dir = os.path.dirname(os.path.abspath(__file__))
        mcp_config_path = os.path.join(config_dir, "mcp_config.json")
        installed = []
        if os.path.exists(mcp_config_path):
            try:
                with open(mcp_config_path, "r", encoding="utf-8") as f:
                    mcp_data = json.load(f)
                installed = [{"id": k, "title": k.title(), "description": "Local installed MCP connector."} for k in mcp_data.get("mcpServers", {}).keys()]
            except: pass
        if args.out_file:
            with open(args.out_file, "w", encoding="utf-8") as f: json.dump(installed, f)
        else:
            print(json.dumps(installed))
        sys.exit(0)

    if args.get_marketplace_skills:
        import json, os, urllib.request, re
        config_dir = os.path.dirname(os.path.abspath(__file__))
        res_file = os.path.join(config_dir, "resources.json")
        
        # User's original Web Scraper / Crawler
        resources = [
            "https://raw.githubusercontent.com/obviousworks/Claude-AI-skills-collection-2026/main/README.md",
            "https://raw.githubusercontent.com/VoltAgent/awesome-agent-skills/main/README.md"
        ]
        
        if os.path.exists(res_file):
            try:
                with open(res_file, "r") as f: 
                    saved = json.load(f)
                    if saved: resources = saved
            except: pass
            
        skills = []
        
        for url in resources:
            try:
                if "github.com" in url and "raw.githubusercontent" not in url:
                    url = url.replace("github.com", "raw.githubusercontent.com").replace("/tree/", "/").replace("/blob/", "/")
                    if url.endswith(".git"): url = url[:-4]
                    if not url.endswith(".md"): url += "/main/README.md"
                
                req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
                with urllib.request.urlopen(req, timeout=5) as response:
                    text = response.read().decode('utf-8')
                    
                lines = text.split("\n")
                current_category = "General"
                for line in lines:
                    if line.startswith("## "):
                        current_category = line[3:].strip()
                        current_category = re.sub(r'[^a-zA-Z0-9 &\-]', '', current_category).strip()
                    
                    if line.startswith("| ") and "|--" not in line and "Name" not in line and "Description" not in line:
                        parts = [p.strip() for p in line.split("|")]
                        if len(parts) >= 4:
                            name_raw = parts[1]
                            desc = parts[2]
                            link_raw = parts[3]
                            
                            name_m = re.search(r'\*\*(.*?)\*\*', name_raw)
                            name = name_m.group(1) if name_m else name_raw
                            name = re.sub(r'\[(.*?)\]\(.*?\)', r'\g<1>', name)
                            
                            link_m = re.search(r'\[.*?\]\((.*?)\)', link_raw)
                            skill_url = link_m.group(1) if link_m else link_raw
                            
                            if "http" in skill_url:
                                skills.append({
                                    "id": re.sub(r'[^a-zA-Z0-9]', '_', name.lower()),
                                    "title": name,
                                    "description": desc,
                                    "domain": current_category,
                                    "repo_url": skill_url
                                })
            except Exception as e:
                pass
                
        if not skills:
            skills = [{"id": "fallback", "title": "Fallback", "description": "Failed to crawl resources. Please check connection or URLs.", "repo_url": ""}]
            
        page = args.page
        per_page = 12
        start_idx = (page - 1) * per_page
        end_idx = start_idx + per_page
        
        paginated = skills[start_idx:end_idx]
        total_pages = (len(skills) + per_page - 1) // per_page
        
        data = {
            "skills": paginated,
            "total_pages": total_pages,
            "current_page": page
        }
        if args.out_file:
            with open(args.out_file, "w", encoding="utf-8") as f: json.dump(data, f)
        else:
            print(json.dumps(data))
        sys.exit(0)

    if args.get_installed_skills:
        import json, os
        config_dir = os.path.dirname(os.path.abspath(__file__))
        skills_file = os.path.join(config_dir, "local_skills.json")
        installed_skills = []
        if os.path.exists(skills_file):
            try:
                with open(skills_file, "r", encoding="utf-8") as f:
                    installed_skills = json.load(f)
            except: pass
        if args.out_file:
            with open(args.out_file, "w", encoding="utf-8") as f: json.dump(installed_skills, f)
        else:
            print(json.dumps(installed_skills))
        sys.exit(0)

"""

content = content.replace(old_block, new_block)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("Successfully restored crawler and NPM mcp tools!")