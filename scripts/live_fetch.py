import json, sys
import urllib.request

def main():
    try:
        url = "https://raw.githubusercontent.com/lobehub/lobe-chat-agents/main/index.json"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=5) as response:
            data = json.loads(response.read().decode())
            skills = []
            for agent in data.get("agents", [])[:30]: # Fetch top 30 for speed & UI bounds
                meta = agent.get("meta", {})
                tags = meta.get("tags", [])
                domain = tags[0] if tags else "General"
                skills.append({
                    "id": agent.get("identifier", "unknown"),
                    "title": meta.get("title", "Unknown"),
                    "description": meta.get("description", ""),
                    "domain": domain,
                    "author": agent.get("author", "Community"),
                    "system_prompt": agent.get("systemRole", "")
                })
            # Add our official models dynamically
            skills.insert(0, {"id":"claude","title":"Claude 3 Opus","description":"Anthropic Claude persona. Articulate & reasoning-focused.","domain":"General","author":"Anthropic","system_prompt":"You are Claude, trained by Anthropic. Highly articulate, objective, and reasoning-focused. Avoid harmful assistance."})
            skills.insert(1, {"id":"gemini","title":"Google Gemini","description":"Google Gemini persona. Multimodal & massive context.","domain":"General","author":"Google","system_prompt":"You are Gemini, a highly capable multimodal AI model by Google. Helpful, harmless, honest. Excel at long-context reasoning."})
            skills.insert(2, {"id":"copilot","title":"GitHub Copilot","description":"AI pair programmer. Terse, code-focused.","domain":"Coding","author":"GitHub","system_prompt":"You are GitHub Copilot, an AI pair programmer. Provide terse, highly technical, and immediately usable code snippets without explanation unless asked."})
            skills.insert(3, {"id":"cursor","title":"Cursor AI","description":"Code editing assistant.","domain":"Coding","author":"Cursor","system_prompt":"You are an expert AI programming assistant in Cursor. Output concise code edits. Only write code that needs changing."})
            
            print(json.dumps(skills))
    except Exception as e:
        # Print empty array on network failure so UI doesn't crash
        print("[]")
    sys.exit(0)

if __name__ == "__main__":
    main()