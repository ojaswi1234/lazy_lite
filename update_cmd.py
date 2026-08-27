import os

with open("install.cmd", "r", encoding="utf-8") as f:
    content = f.read()
    
old_block = """    if /i "!SETUP_MONGO!"=="y" (
        python -m pip install pymongo --quiet >nul 2>nul
    )
)"""

new_block = """    if /i "!SETUP_MONGO!"=="y" (
        python -m pip install pymongo --quiet >nul 2>nul
    )
    echo Installing Core AI Dependencies (LangGraph, MCP, Graphify, etc.)...
    python -m pip install langchain-core langchain-google-genai langchain-groq langchain-openai langchain-anthropic langgraph mcp langchain-mcp-adapters graphifyy duckduckgo-search psutil --quiet >nul 2>nul
)"""

content = content.replace(old_block, new_block)
with open("install.cmd", "w", encoding="utf-8") as f:
    f.write(content)

print("cmd patched!")