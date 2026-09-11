import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

# We need to replace the Graph Building section with dynamic graph building.
old_graph_builder = """    # Build Graph
    graph_builder = StateGraph(AgentState)
    graph_builder.add_node("chatbot", chatbot)
    graph_builder.add_node("tools", tool_executor)
    
    graph_builder.add_edge(START, "chatbot")
    graph_builder.add_conditional_edges("chatbot", should_continue, {"tools": "tools", END: END})
    graph_builder.add_edge("tools", "chatbot")"""

new_graph_builder = """    # Build Graph
    graph_builder = StateGraph(AgentState)
    
    if team_config_file:
        import os, json
        with open(team_config_file, "r") as f:
            team_cfg = json.load(f)
            
        keys_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ai_api_keys.json")
        all_keys = {}
        if os.path.exists(keys_file):
            with open(keys_file, "r") as f: all_keys = json.load(f)
            
        def make_agent_node(agent_def):
            a_id = agent_def["id"]
            a_prov = agent_def["provider"]
            a_mod = agent_def["model"]
            a_role = agent_def.get("role", "Team Member")
            a_key = all_keys.get(a_prov, "")
            
            node_llm = create_llm(a_prov, a_mod, a_key)
            if not node_llm:
                node_llm = create_llm(provider, model_name, api_key) # fallback
                
            async def agent_node(state: AgentState):
                # We need to use the globally bound tools when tools are enabled.
                # However, llm_with_tools is bound LATER inside AsyncExitStack!
                # We will handle binding later.
                pass
            return agent_node
            
        # We need to rethink binding tools if there are multiple LLMs!
        # Let's use a dynamic wrapper.
    else:
        graph_builder.add_node("chatbot", chatbot)
        graph_builder.add_node("tools", tool_executor)
        
        graph_builder.add_edge(START, "chatbot")
        graph_builder.add_conditional_edges("chatbot", should_continue, {"tools": "tools", END: END})
        graph_builder.add_edge("tools", "chatbot")"""

# Let's NOT replace it yet! We need to handle tool binding inside AsyncExitStack.