import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

# Replace Checkpointer Setup & Execution block
content = re.sub(
    r'# Checkpointer Setup\n.*?conn = sqlite3\.connect\(db_path, check_same_thread=False\)\n.*?memory = SqliteSaver\(conn\)\n.*?graph = graph_builder\.compile\(checkpointer=memory\)',
    r'''# MCP & Checkpointer Setup
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
            graph = graph_builder.compile(checkpointer=memory)''',
    content,
    flags=re.DOTALL
)

# Indent everything after `graph = graph_builder.compile(checkpointer=memory)` manually?
# Since it's inside `async with AsyncSqliteSaver`, the rest of the function must be indented 2 levels (8 spaces).
# Wait, actually `AsyncSqliteSaver.from_conn_string` can be used WITHOUT an `async with` block if we just use `memory = AsyncSqliteSaver.from_conn_string(...)` and await `memory.setup()`?
# No, we can just use `re.sub` to add 8 spaces to all remaining lines in run_agent!