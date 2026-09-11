import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

# Replace the checkpointer setup
old_cp = """    # Checkpointer Setup
    config_dir = os.path.dirname(os.path.abspath(__file__))
    db_path = os.path.join(config_dir, "ai_threads.db")
    conn = sqlite3.connect(db_path, check_same_thread=False)
    memory = SqliteSaver(conn)
    
    graph = graph_builder.compile(checkpointer=memory)"""

new_cp = """    # MCP & Checkpointer Setup
    from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver
    from mcp import StdioServerParameters, ClientSession
    from mcp.client.stdio import stdio_client
    from langchain_mcp_adapters.tools import load_mcp_tools
    from contextlib import AsyncExitStack
    import json

    config_dir = os.path.dirname(os.path.abspath(__file__))
    db_path = os.path.join(config_dir, "ai_threads.db")
    
    # We will use AsyncSqliteSaver in the async with block.
    # We need to wrap the rest of the function!
"""

content = content.replace(old_cp, new_cp)

# Actually, rather than replacing old_cp and trying to indent the bottom half of the file,
# I will just write a wrapper around graph_builder.compile!