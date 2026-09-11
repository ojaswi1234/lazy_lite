import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

# 1. Update args.chat block
old_chat = """    if args.chat:
        run_agent(
            provider=args.provider,"""
new_chat = """    if args.chat:
        import asyncio
        asyncio.run(run_agent(
            provider=args.provider,"""
content = content.replace(old_chat, new_chat)

# 2. Update run_agent signature
content = content.replace("def run_agent(provider", "async def run_agent(provider")

# 3. Update execution loop
old_checkpointer = """    # Checkpointer Setup
    config_dir = os.path.dirname(os.path.abspath(__file__))
    db_path = os.path.join(config_dir, "ai_threads.db")
    conn = sqlite3.connect(db_path, check_same_thread=False)
    memory = SqliteSaver(conn)
    
    graph = graph_builder.compile(checkpointer=memory)

    ws_context = f"\\nCURRENT WORKSPACE: {workspace}\\n" if workspace else "\\n"

    system_prompt = f\"\"\"You are Antigravity, an advanced AI coding assistant running inside the Lite XL editor. 
You have access to local shell execution, file editing, and web search.{ws_context}
When executing commands, wait for completion before proceeding. If a command runs endlessly (like starting a server), background it.
If making code edits, ALWAYS read the file first to understand its structure. 
Return your reasoning inside <thought> tags before taking any action or tool execution.
\"\"\"

    config = {"configurable": {"thread_id": thread_id}}

    try:
        for event in graph.stream({"messages": [HumanMessage(content=prompt)]}, config, stream_mode="values"):
            last_msg = event["messages"][-1]
            if isinstance(last_msg, AIMessage) and not getattr(last_msg, "tool_calls", None):
                sys.stdout.write(last_msg.content)
                sys.stdout.flush()
        print("\\n\\n--- Finished ---", flush=True)
    except Exception as e:"""

new_checkpointer = """    # MCP & Checkpointer Setup
    from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver
    from mcp import StdioServerParameters, ClientSession
    from mcp.client.stdio import stdio_client
    from langchain_mcp_adapters.tools import load_mcp_tools
    from contextlib import AsyncExitStack
    import json

    config_dir = os.path.dirname(os.path.abspath(__file__))
    db_path = os.path.join(config_dir, "ai_threads.db")

    async with AsyncExitStack() as stack:
        # Load MCP tools
        mcp_config_path = os.path.join(config_dir, "mcp_config.json")
        if os.path.exists(mcp_config_path):
            try:
                with open(mcp_config_path, "r") as f:
                    mcp_data = json.load(f)
                for srv_name, srv_conf in mcp_data.get("mcpServers", {}).items():
                    params = StdioServerParameters(command=srv_conf["command"], args=srv_conf.get("args", []), env=srv_conf.get("env", None))
                    read, write = await stack.enter_async_context(stdio_client(params))
                    session = await stack.enter_async_context(ClientSession(read, write))
                    await session.initialize()
                    mcp_tools = await load_mcp_tools(session)
                    tools.extend(mcp_tools)
            except Exception as e:
                print(f"[ERROR Loading MCP]: {e}\\n", flush=True)

        if enable_tools:
            llm_with_tools = llm.bind_tools(tools)
        else:
            llm_with_tools = llm

        async with AsyncSqliteSaver.from_conn_string(db_path) as memory:
            graph = graph_builder.compile(checkpointer=memory)

            ws_context = f"\\nCURRENT WORKSPACE: {workspace}\\n" if workspace else "\\n"

            system_prompt = f\"\"\"You are Antigravity, an advanced AI coding assistant running inside the Lite XL editor. 
You have access to local shell execution, file editing, and web search.{ws_context}
When executing commands, wait for completion before proceeding. If a command runs endlessly (like starting a server), background it.
If making code edits, ALWAYS read the file first to understand its structure. 
Return your reasoning inside <thought> tags before taking any action or tool execution.
\"\"\"

            config = {"configurable": {"thread_id": thread_id}}

            try:
                async for event in graph.astream({"messages": [HumanMessage(content=prompt)]}, config, stream_mode="values"):
                    last_msg = event["messages"][-1]
                    if isinstance(last_msg, AIMessage) and not getattr(last_msg, "tool_calls", None):
                        sys.stdout.write(last_msg.content)
                        sys.stdout.flush()
                print("\\n\\n--- Finished ---", flush=True)
            except Exception as e:"""

content = content.replace(old_checkpointer, new_checkpointer)

# Now we need to remove the LLM binding from BEFORE the checkpointer, since we moved it INSIDE the async context!
old_bind = """    if enable_tools:
        llm_with_tools = llm.bind_tools(tools)
    else:
        llm_with_tools = llm"""

# The easiest way to remove it is to replace the first occurrence ONLY.
content = content.replace(old_bind, "", 1)

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "w", encoding="utf-8") as f:
    f.write(content)

print("Migrated bridge to async MCP!")