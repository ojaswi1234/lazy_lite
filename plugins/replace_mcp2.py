with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    lines = f.readlines()

new_lines = []
skip = False
in_try = False

for i, line in enumerate(lines):
    if "# Checkpointer Setup" in line:
        skip = True
        
        # Inject our new logic
        new_lines.append("""    # MCP & Checkpointer Setup
    from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver
    from mcp import StdioServerParameters, ClientSession
    from mcp.client.stdio import stdio_client
    from langchain_mcp_adapters.tools import load_mcp_tools
    from contextlib import AsyncExitStack
    import json

    config_dir = os.path.dirname(os.path.abspath(__file__))
    db_path = os.path.join(config_dir, "ai_threads.db")

    async with AsyncExitStack() as stack:
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
""")
        continue
        
    if skip:
        if "graph = graph_builder.compile(checkpointer=memory)" in line:
            skip = False
        continue

    # Now we need to indent everything that was after the checkpointer!
    # Where does it end? At `print(f"\\nERROR in execution: {str(e)}", flush=True)` which is the end of run_agent.
    # Actually, we can just replace the whole remaining block since we know exactly what it is.
    new_lines.append(line)

# Let's fix the bind_tools which we copied inside the async block
# We need to remove the old bind_tools
final_content = "".join(new_lines)

old_bind = """    if enable_tools:
        llm_with_tools = llm.bind_tools(tools)
    else:
        llm_with_tools = llm"""

final_content = final_content.replace(old_bind, "", 1)

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "w", encoding="utf-8") as f:
    f.write(final_content)
print("done")