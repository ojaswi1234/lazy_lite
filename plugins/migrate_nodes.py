import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

content = content.replace("def chatbot(state: AgentState):", "async def chatbot(state: AgentState):")
content = content.replace("msg = llm_with_tools.invoke(messages)", "msg = await llm_with_tools.ainvoke(messages)")
content = content.replace("msg = llm.invoke(messages)", "msg = await llm.ainvoke(messages)")

content = content.replace("def tool_executor(state: AgentState):", "async def tool_executor(state: AgentState):")
content = content.replace("result = matched_tool.invoke(tool_args)", "result = await matched_tool.ainvoke(tool_args)")

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "w", encoding="utf-8") as f:
    f.write(content)

print("Updated nodes to async!")