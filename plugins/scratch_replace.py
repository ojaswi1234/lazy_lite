import sys

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

# Replace run_agent definition
content = content.replace("def run_agent(", "async def run_agent(")

# In tool_executor, use result instead of matched_tool.invoke since we may have sync tools and async MCP tools?
# Wait! If we use ainvoke, LangChain tools can be async!
# We don't call them manually, we let LangGraph's ToolNode call them!
# Wait! ai_api_bridge.py uses a CUSTOM tool_executor node!!