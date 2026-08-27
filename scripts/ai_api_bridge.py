import argparse
import json
import sys
import os
import subprocess
import queue
import threading
from typing import Annotated, Literal, TypedDict
import sqlite3
from langgraph.checkpoint.sqlite import SqliteSaver
from ai_memory import MicroMemory
from langchain_core.tools import tool

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8')

# Global queue for standard input
stdin_queue = queue.Queue()

def stdin_watchdog():
    try:
        while True:
            line = sys.stdin.readline()
            if not line: break
            line_str = line.strip()
            if line_str == "KILL":
                # Kill all child processes to prevent orphans
                try:
                    import psutil
                    parent = psutil.Process(os.getpid())
                    for child in parent.children(recursive=True):
                        child.terminate()
                except ImportError:
                    if os.name == 'nt':
                        subprocess.call(['taskkill', '/F', '/T', '/PID', str(os.getpid())])
                os._exit(1)
            else:
                stdin_queue.put(line_str)
    except:
        pass

# Start the watchdog immediately
threading.Thread(target=stdin_watchdog, daemon=True).start()

def load_keys():
    config_dir = os.path.dirname(os.path.abspath(__file__))
    keys_file = os.path.join(config_dir, "ai_api_keys.json")
    if not os.path.exists(keys_file):
        with open(keys_file, "w") as f:
            json.dump({}, f)
        return {}
    with open(keys_file, "r") as f:
        try:
            return json.load(f)
        except:
            return {}

def validate_keys(keys):
    status = {}
    providers = ["gemini", "groq", "openai", "anthropic", "ollama"]
    for p in providers:
        api_key = keys.get(p, "")
        if not api_key:
            status[p] = "missing"
            continue
        try:
            if p == "gemini":
                import google.generativeai as genai
                genai.configure(api_key=api_key)
                genai.list_models()
                status[p] = "valid"
            elif p == "groq":
                from groq import Groq
                client = Groq(api_key=api_key)
                client.models.list()
                status[p] = "valid"
            elif p == "openai":
                from openai import OpenAI
                client = OpenAI(api_key=api_key)
                client.models.list()
                status[p] = "valid"
            elif p == "ollama":
                from openai import OpenAI
                client = OpenAI(base_url="https://ollama.com/v1", api_key=api_key)
                client.models.list()
                status[p] = "valid"
            elif p == "anthropic":
                from anthropic import Anthropic
                client = Anthropic(api_key=api_key)
                client.models.list()
                status[p] = "valid"
        except Exception as e:
            status[p] = "expired"
    for p, v in status.items():
        print(f"{p}:{v}", flush=True)

def list_models(provider, keys):
    models = []
    providers = ["gemini", "groq", "openai", "anthropic", "ollama"] if provider == "all" else [provider]
    
    for p in providers:
        api_key = keys.get(p, "")
        if not api_key:
            if provider != "all":
                return [f"MISSING_API_KEY:{p}"]
            continue
        try:
            if p == "gemini":
                import google.generativeai as genai
                genai.configure(api_key=api_key)
                m_list = [m.name.replace("models/", "") for m in genai.list_models() if "generateContent" in m.supported_generation_methods]
                if not m_list: m_list = ["gemini-2.5-pro", "gemini-2.5-flash"]
                models.extend([f"gemini/{m}" for m in m_list])
            elif p == "groq":
                import time, json, os, urllib.request, concurrent.futures
                cache_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "groq_model_cache.json")
                cache = {}
                if os.path.exists(cache_file):
                    try:
                        with open(cache_file, "r") as cf: cache = json.load(cf)
                    except: pass
                
                current_time = time.time()
                valid_models = []
                
                if "_last_fetch" not in cache or (current_time - cache["_last_fetch"]) > 86400:
                    from groq import Groq
                    try:
                        client = Groq(api_key=api_key)
                        m_list = [m.id for m in client.models.list().data if not any(x in m.id.lower() for x in ["whisper", "tts", "embed"])]
                        cache["_last_fetch"] = current_time
                        
                        models_to_check = []
                        for m in m_list:
                            if m in cache and (current_time - cache[m].get("time", 0)) < 86400 * 7:
                                if cache[m].get("is_free"): valid_models.append(m)
                            else:
                                models_to_check.append(m)
                        
                        if models_to_check:
                            def check_model(m):
                                tools = [{
                                    "type": "function",
                                    "function": {
                                        "name": "test_tool",
                                        "description": "A test tool",
                                        "parameters": {"type": "object", "properties": {}, "required": []}
                                    }
                                }]
                                try:
                                    client.chat.completions.create(
                                        model=m,
                                        messages=[{'role': 'user', 'content': 'hi'}],
                                        tools=tools,
                                        max_tokens=1,
                                        timeout=3
                                    )
                                    return m, True
                                except Exception as e:
                                    msg = str(e).lower()
                                    if "terms acceptance" in msg or "tool" in msg or "does not support" in msg or "400" in msg:
                                        return m, False
                                    return m, True
                            
                            with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
                                results = executor.map(check_model, models_to_check)
                                for m, is_free in results:
                                    cache[m] = {"is_free": is_free, "time": current_time}
                                    if is_free: valid_models.append(m)
                            
                            try:
                                with open(cache_file, "w") as cf: json.dump(cache, cf)
                            except: pass
                    except:
                        valid_models = [k for k, v in cache.items() if k != "_last_fetch" and isinstance(v, dict) and v.get("is_free")]
                else:
                    valid_models = [k for k, v in cache.items() if k != "_last_fetch" and isinstance(v, dict) and v.get("is_free")]
                
                models.extend([f"groq/{m}" for m in valid_models])
            elif p == "openai":
                from openai import OpenAI
                client = OpenAI(api_key=api_key)
                m_list = [m.id for m in client.models.list().data if "gpt" in m.id or "o1" in m.id or "o3" in m.id or "o4" in m.id]
                models.extend([f"openai/{m}" for m in m_list])
            elif p == "ollama":
                import time, json, os, urllib.request, concurrent.futures
                cache_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ollama_model_cache.json")
                cache = {}
                if os.path.exists(cache_file):
                    try:
                        with open(cache_file, "r") as cf: cache = json.load(cf)
                    except: pass
                
                current_time = time.time()
                valid_models = []
                
                # Fetch full model list if cache is missing or older than 24 hours
                if "_last_fetch" not in cache or (current_time - cache["_last_fetch"]) > 86400:
                    from openai import OpenAI
                    try:
                        client = OpenAI(base_url="https://ollama.com/v1", api_key=api_key)
                        m_list = [m.id for m in client.models.list().data if "embed" not in m.id.lower()]
                        cache["_last_fetch"] = current_time
                        
                        models_to_check = []
                        for m in m_list:
                            if m in cache and (current_time - cache[m].get("time", 0)) < 86400 * 7:
                                if cache[m].get("is_free"): valid_models.append(m)
                            else:
                                models_to_check.append(m)
                        
                        if models_to_check:
                            def check_model(m):
                                tools = [{
                                    "type": "function",
                                    "function": {
                                        "name": "test_tool",
                                        "description": "A test tool",
                                        "parameters": {"type": "object", "properties": {}, "required": []}
                                    }
                                }]
                                try:
                                    client.chat.completions.create(model=m, messages=[{'role': 'user', 'content': 'hi'}], tools=tools, max_tokens=1, timeout=5)
                                    return m, True
                                except Exception as e:
                                    msg = str(e).lower()
                                    if "terms acceptance" in msg or "tool" in msg or "does not support" in msg or "400" in msg or "subscription" in msg or "403" in msg:
                                        return m, False
                                    return m, True
                            
                            with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
                                results = executor.map(check_model, models_to_check)
                                for m, is_free in results:
                                    cache[m] = {"is_free": is_free, "time": current_time}
                                    if is_free: valid_models.append(m)
                            
                        try:
                            with open(cache_file, "w") as cf: json.dump(cache, cf)
                        except: pass
                    except:
                        # Fallback to cached valid models if network fails
                        valid_models = [k for k, v in cache.items() if k != "_last_fetch" and isinstance(v, dict) and v.get("is_free")]
                else:
                    # Use cache immediately
                    valid_models = [k for k, v in cache.items() if k != "_last_fetch" and isinstance(v, dict) and v.get("is_free")]
                
                models.extend([f"ollama/{m}" for m in valid_models])
            elif p == "anthropic":
                from anthropic import Anthropic
                client = Anthropic(api_key=api_key)
                models.extend([f"anthropic/{m.id}" for m in client.models.list().data])
        except Exception:
            if p == "gemini": models.extend([f"gemini/{m}" for m in ["gemini-2.5-pro", "gemini-2.5-flash"]])
            elif p == "groq": models.extend([f"groq/{m}" for m in ["llama3-70b-8192"]])
            elif p == "openai": models.extend([f"openai/{m}" for m in ["gpt-4o", "gpt-4o-mini"]])
            elif p == "ollama": models.extend([f"ollama/{m}" for m in ["mistral-large-3:675b", "llama3.3"]])
            elif p == "anthropic": models.extend([f"anthropic/{m}" for m in ["claude-3-7-sonnet-20250219"]])
    
    if not models and provider == "all":
        return ["MISSING_API_KEY:all"]
    return models

def run_agent(provider, model_name, api_key, prompt, autopilot, read_only, workspace, thread_id, enable_tools=True, active_skill=None, skill_state=None, team_config_file=None):
    import asyncio
    async def _run_agent_async():
        try:
            from langchain_core.messages import HumanMessage, AIMessage, ToolMessage, SystemMessage
            from langgraph.graph import StateGraph, START, END
            from langgraph.graph.message import add_messages
            from langchain_core.tools import tool
            from pydantic import BaseModel, Field
        except ImportError:
            print("ERROR: Missing dependencies.", flush=True)
            sys.exit(1)

        def is_in_workspace(filepath: str) -> bool:
            if not workspace: return True
            abs_workspace = os.path.abspath(workspace)
            abs_path = os.path.abspath(filepath)
            return abs_path.startswith(abs_workspace)

        @tool
        def local_shell(command: str) -> str:
            """Executes a local shell command."""
            import subprocess, os
            try:
                cwd = workspace if workspace else os.getcwd()
                result = subprocess.run(command, shell=True, capture_output=True, text=True, cwd=cwd, timeout=60)
                output = result.stdout + result.stderr
                return output if output else "Command executed successfully (no output)."
            except Exception as e:
                return f"Error executing command: {str(e)}"

        @tool
        def read_file(filepath: str, start_line: int = None, end_line: int = None) -> str:
            """Reads the contents of a file."""
            import os
            if not is_in_workspace(filepath):
                return f"Error: Cannot read file outside of workspace ({workspace})"
            try:
                with open(filepath, "r", encoding="utf-8") as f:
                    lines = f.readlines()
                    
                if start_line is not None and end_line is not None:
                    lines = lines[start_line-1:end_line]
                elif start_line is not None:
                    lines = lines[start_line-1:]
                    
                if len(lines) > 2000:
                    lines = lines[:2000]
                    lines.append(f"\n...[FILE TRUNCATED AT 2000 LINES TO PROTECT CONTEXT WINDOW]... Use start_line and end_line parameters to read further.\n")
                    
                return "".join(lines)
            except Exception as e:
                return f"Error reading file: {str(e)}"

        @tool
        def write_file(filepath: str, content: str) -> str:
            """Writes or overwrites a file."""
            import os
            if read_only: return "Error: Read-only mode is enabled."
            if not is_in_workspace(filepath): return f"Error: Cannot write outside workspace."
            try:
                os.makedirs(os.path.dirname(os.path.abspath(filepath)), exist_ok=True)
                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(content)
                return f"Successfully wrote to {filepath}"
            except Exception as e:
                return f"Error writing file: {str(e)}"

        tools = []
        if enable_tools:
            tools.extend([local_shell, read_file, write_file])

        def create_llm(p_name, m_name, p_key):
            if p_name == "gemini":
                from langchain_google_genai import ChatGoogleGenerativeAI
                return ChatGoogleGenerativeAI(model=m_name, api_key=p_key, temperature=0.2)
            elif p_name == "groq":
                from langchain_groq import ChatGroq
                return ChatGroq(model_name=m_name, api_key=p_key, temperature=0.2)
            elif p_name == "openai":
                from langchain_openai import ChatOpenAI
                return ChatOpenAI(model_name=m_name, api_key=p_key, temperature=0.2)
            elif p_name == "ollama":
                from langchain_openai import ChatOpenAI
                return ChatOpenAI(model_name=m_name, api_key=p_key, base_url="http://127.0.0.1:11434/v1", temperature=0.2)
            elif p_name == "anthropic":
                from langchain_anthropic import ChatAnthropic
                return ChatAnthropic(model_name=m_name, api_key=p_key, temperature=0.2)
            return None

        llm = create_llm(provider, model_name, api_key)
        if not llm and not team_config_file:
            print(f"ERROR: Unsupported provider {provider}", flush=True)
            import sys
            sys.exit(1)
            
        class AgentState(TypedDict):
            messages: Annotated[list, add_messages]

        ws_context = f"\nCURRENT WORKSPACE: {workspace}\n" if workspace else "\n"
        system_prompt = f"""You are Antigravity, an advanced AI coding assistant running inside the Lite XL editor. 
You have access to local shell execution, file editing, and web search.{ws_context}
CRITICAL INSTRUCTIONS:
1. THINK BEFORE EXECUTING: Always explore the directory structure first.
2. FILE EDITING: When editing files, ALWAYS write the COMPLETE file content using write_file.
3. CONTEXTUAL SEARCHING: Use local_shell with grep to locate files."""

        custom_skill_prompt = ""
        try:
            if prompt.startswith("/"):
                cmd = prompt.split()[0][1:]
                import json, os
                config_dir = os.path.dirname(os.path.abspath(__file__))
                skills_file = os.path.join(config_dir, "local_skills.json")
                if os.path.exists(skills_file):
                    with open(skills_file, "r") as f:
                        skills = json.load(f)
                    for s in skills:
                        if s.get("id") == cmd:
                            custom_skill_prompt = f"\n\n[SKILL ACTIVATED: {s.get('title')}]\n{s.get('system_prompt')}"
                            break
            elif active_skill:
                import json, os
                config_dir = os.path.dirname(os.path.abspath(__file__))
                skills_file = os.path.join(config_dir, "local_skills.json")
                if os.path.exists(skills_file):
                    with open(skills_file, "r") as f:
                        skills = json.load(f)
                    for s in skills:
                        if s.get("id") == active_skill:
                            custom_skill_prompt = f"\n\n[SKILL ACTIVATED: {s.get('title')}]\n{s.get('system_prompt')}"
                            break
        except: pass

        skill_ui_context = ""
        if active_skill and skill_state:
            import json
            try:
                state_data = json.loads(skill_state)
                skill_ui_context = "\n\n[SKILL CONFIGURATION STATE]\n"
                for k, v in state_data.items():
                    skill_ui_context += f"- {k}: {v}\n"
            except: pass

        if custom_skill_prompt:
            system_prompt = custom_skill_prompt.strip() + "\n\n[Note: You have access to tools if you need them. Do not use them unless strictly necessary for your activated skill.]" + skill_ui_context
        else:
            system_prompt = system_prompt + skill_ui_context

        # Teams logic
        team_agents = []
        if team_config_file:
            import os, json
            with open(team_config_file, "r") as f:
                raw_team = json.load(f)
            keys_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ai_api_keys.json")
            all_keys = {}
            if os.path.exists(keys_file):
                with open(keys_file, "r") as f: all_keys = json.load(f)
            for a_def in raw_team:
                a_key = all_keys.get(a_def["provider"], "")
                if not a_key and a_def["provider"] == provider: a_key = api_key
                a_llm = create_llm(a_def["provider"], a_def["model"], a_key)
                if not a_llm: a_llm = llm
                team_agents.append({
                    "id": a_def["id"],
                    "role": a_def.get("role", "Team Member"),
                    "llm": a_llm,
                    "base_llm": a_llm
                })

        def create_team_node(agent):
            async def team_node(state: AgentState):
                print(f"\n[TEAM: {agent['role']}] Thinking...", flush=True)
                final_sys_prompt = f"You are part of an AI Team. Your role is: {agent['role']}. Evaluate the current state, use tools if needed, and contribute your expertise. If you are the Hunter/Analyzer, end your turn with [REJECT] if the work is flawed, or [APPROVE] if it is perfect.\n\n{system_prompt}"
                safe_messages = state["messages"]
                if len(safe_messages) > 40:
                    safe_messages = safe_messages[-40:]
                    while safe_messages and (safe_messages[0].type == "tool" or (safe_messages[0].type == "ai" and getattr(safe_messages[0], "tool_calls", None))):
                        safe_messages = safe_messages[1:]
                messages = [SystemMessage(content=final_sys_prompt)] + safe_messages
                try:
                    msg = await agent["llm"].ainvoke(messages)
                except Exception as e:
                    print(f"\n[WARNING] Tool calling unsupported by {agent['id']}, falling back.\n", flush=True)
                    msg = await agent["base_llm"].ainvoke(messages)
                if msg.content:
                    msg.content = f"[{agent['role']}] {msg.content}"
                return {"messages": [msg]}
            return team_node

        def team_should_continue(state: AgentState) -> str:
            last_message = state['messages'][-1]
            if getattr(last_message, "tool_calls", None): return "tools"
            return "next"

        def hunter_router(state: AgentState) -> str:
            last_message = state['messages'][-1]
            if getattr(last_message, "tool_calls", None): return "tools"
            if "[REJECT]" in str(last_message.content): return "reject"
            return END

        def route_tools(state: AgentState):
            for m in reversed(state["messages"]):
                if m.type == "ai":
                    content = m.content or ""
                    for a in team_agents:
                        if content.startswith(f"[{a['role']}]"): return a["id"]
            return team_agents[0]["id"]

        def should_continue(state: AgentState) -> str:
            messages = state['messages']
            last_message = messages[-1]
            if getattr(last_message, "tool_calls", None): return "tools"
            return END

        async def chatbot(state: AgentState):
            max_messages = 40
            safe_messages = state["messages"]
            if len(safe_messages) > max_messages:
                safe_messages = safe_messages[-max_messages:]
                while safe_messages and (safe_messages[0].type == "tool" or (safe_messages[0].type == "ai" and getattr(safe_messages[0], "tool_calls", None))):
                    safe_messages = safe_messages[1:]
            messages = [SystemMessage(content=system_prompt)] + safe_messages
            try:
                msg = await llm_with_tools.ainvoke(messages)
            except Exception as e:
                if "tool calling" in str(e).lower() or "tools" in str(e).lower() or "invalid_request" in str(e).lower() or "400" in str(e).lower():
                    print(f"\n[WARNING EXCEPTION]: {e}\n[WARNING] This model does not support tool calling. Falling back to chat-only mode.\n", flush=True)
                    msg = await llm.ainvoke(messages)
                else:
                    raise e
            return {"messages": [msg]}

        async def tool_executor(state: AgentState):
            last_message = state["messages"][-1]
            tool_outputs = []
            for tool_call in last_message.tool_calls:
                tool_name = tool_call["name"]
                tool_args = tool_call["args"]
                print(f"\n[AGENT] Using tool: {tool_name}", flush=True)
                matched_tool = next((t for t in tools if t.name == tool_name), None)
                if matched_tool:
                    try:
                        result = await matched_tool.ainvoke(tool_args)
                    except Exception as e:
                        result = f"Error executing tool: {str(e)}"
                else:
                    result = f"Error: Tool {tool_name} not found."
                res_str = str(result)
                if len(res_str) > 4000:
                    res_str = res_str[:4000] + "\n...[OUTPUT TRUNCATED BY SYSTEM TO PROTECT CONTEXT WINDOW]..."
                tool_outputs.append(ToolMessage(content=res_str, name=tool_name, tool_call_id=tool_call["id"]))
            return {"messages": tool_outputs}

        graph_builder = StateGraph(AgentState)
        if team_config_file and len(team_agents) > 0:
            for i, agent in enumerate(team_agents):
                graph_builder.add_node(agent["id"], create_team_node(agent))
            graph_builder.add_node("tools", tool_executor)
            graph_builder.add_edge(START, team_agents[0]["id"])
            for i in range(len(team_agents) - 1):
                curr_id = team_agents[i]["id"]
                next_id = team_agents[i+1]["id"]
                graph_builder.add_conditional_edges(curr_id, team_should_continue, {"tools": "tools", "next": next_id})
            hunter_id = team_agents[-1]["id"]
            first_id = team_agents[0]["id"]
            graph_builder.add_conditional_edges(hunter_id, hunter_router, {"tools": "tools", "reject": first_id, END: END})
            graph_builder.add_conditional_edges("tools", route_tools)
        else:
            graph_builder.add_node("chatbot", chatbot)
            graph_builder.add_node("tools", tool_executor)
            graph_builder.add_edge(START, "chatbot")
            graph_builder.add_conditional_edges("chatbot", should_continue, {"tools": "tools", END: END})
            graph_builder.add_edge("tools", "chatbot")

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
                    print(f"[ERROR Loading MCP]: {e}\n", flush=True)

            if enable_tools:
                llm_with_tools = llm.bind_tools(tools) if llm else None
                for a in team_agents:
                    a["llm"] = a["base_llm"].bind_tools(tools)
            else:
                llm_with_tools = llm
                for a in team_agents:
                    a["llm"] = a["base_llm"]

            async with AsyncSqliteSaver.from_conn_string(db_path) as memory:
                graph = graph_builder.compile(checkpointer=memory)
                
                try:
                    inputs = {"messages": [HumanMessage(content=prompt)]}
                    config = {"configurable": {"thread_id": thread_id}}
                    async for event in graph.astream(inputs, config=config, stream_mode="messages"):
                        msg, metadata = event
                        if isinstance(msg, AIMessage) and msg.content:
                            sys.stdout.write(msg.content)
                            sys.stdout.flush()
                    print("\n\n--- Finished ---", flush=True)
                except Exception as e:
                    print(f"\nERROR in execution: {str(e)}", flush=True)

    asyncio.run(_run_agent_async())
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--list-models", action="store_true")
    parser.add_argument("--chat", action="store_true")
    parser.add_argument("--provider", type=str, default="all")
    parser.add_argument("--model", type=str)
    parser.add_argument("--prompt", type=str)
    parser.add_argument("--thread-id", type=str, default="default_thread")
    parser.add_argument("--get-history", action="store_true")
    parser.add_argument("--autopilot", action="store_true")
    parser.add_argument("--read-only", action="store_true")
    parser.add_argument("--workspace", type=str)
    parser.add_argument("--team-config", type=str)
    parser.add_argument("--set-key", type=str)
    parser.add_argument("--delete-key", action="store_true")
    parser.add_argument("--validate-keys", action="store_true")
    parser.add_argument("--get-marketplace-tools", action="store_true")
    parser.add_argument("--get-marketplace-skills", action="store_true")
    parser.add_argument("--get-installed-tools", action="store_true")
    parser.add_argument("--get-installed-skills", action="store_true")
    parser.add_argument("--page", type=int, default=1)
    parser.add_argument("--out-file", type=str)
    args = parser.parse_args()

    import re
    import os
    # Intercept and expand pasted text files directly into the prompt to bypass OS command-line limits
    if args.prompt:
        def replace_pasted_text(match):
            filepath = match.group(1).strip()
            try:
                with open(filepath, 'r', encoding='utf-8') as pf:
                    content = pf.read()
                    return f'\n\n--- PASTED TEXT ({os.path.basename(filepath)}) ---\n{content}\n--- END PASTED TEXT ---\n\n'
            except Exception as e:
                return f" [Error reading pasted text from {filepath}: {e}] "
                
        args.prompt = re.sub(r'\[Read this pasted text from file: (.*?)\]', replace_pasted_text, args.prompt)

    
    if args.get_history:
        import sqlite3
        import json
        config_dir = os.path.dirname(os.path.abspath(__file__))
        db_path = os.path.join(config_dir, "ai_threads.db")
        if not os.path.exists(db_path):
            print("return {}")
            sys.exit(0)
            
        conn = sqlite3.connect(db_path)
        c = conn.cursor()
        # LangGraph schema for sqlite: checkpoints(thread_id, checkpoint_ns, checkpoint_id, parent_checkpoint_id, type, checkpoint, metadata)
        # Check what columns actually exist
        try:
            from langgraph.checkpoint.sqlite import SqliteSaver
            memory = SqliteSaver(conn)
            c.execute("SELECT thread_id, checkpoint_id, parent_checkpoint_id, type, checkpoint, metadata FROM checkpoints ORDER BY thread_id, checkpoint_id")
            rows = c.fetchall()
            history = []
            for thread_id, checkpoint_id, parent_id, type_, checkpoint_blob, metadata_blob in rows:
                try:
                    cp = memory.serde.loads_typed((type_, checkpoint_blob))
                    meta = memory.serde.loads_typed((type_, metadata_blob))
                except Exception as e:
                    cp, meta = {}, {}
                
                snippet = "No content"
                char_count = 0
                source = meta.get("source", "unknown") if isinstance(meta, dict) else "unknown"
                provider = ""
                date = cp.get("ts", "")[:16].replace("T", " ") if isinstance(cp, dict) else ""
                
                try:
                    msgs = cp.get("channel_values", {}).get("messages", [])
                    if msgs:
                        last_msg = msgs[-1]
                        if hasattr(last_msg, "content"):
                            content = last_msg.content
                            if content:
                                char_count = len(content)
                                snippet = (content[:100].replace('\n', ' ') + '...') if len(content) > 100 else content.replace('\n', ' ')
                        
                        if hasattr(last_msg, "type"):
                            source = last_msg.type
                            
                        if getattr(last_msg, "response_metadata", None):
                            provider = last_msg.response_metadata.get("model_name", "")
                            if "fp_ollama" in last_msg.response_metadata.get("system_fingerprint", ""):
                                provider = "Ollama / " + provider
                except:
                    pass

                history.append({
                    "thread_id": thread_id,
                    "id": checkpoint_id,
                    "parent_id": parent_id,
                    "snippet": snippet,
                    "char_count": char_count,
                    "source": source,
                    "provider": provider,
                    "date": date
                })
            
            def to_lua_string(s):
                if not isinstance(s, str): return 'nil'
                eq = '='
                while f']{eq}]' in s: eq += '='
                return f'[{eq}[{s}]{eq}]'

            lua_lines = ["return {"]
            for item in history:
                tid = to_lua_string(item['thread_id']) if item['thread_id'] else 'nil'
                iid = to_lua_string(item['id']) if item['id'] else 'nil'
                pid = to_lua_string(item['parent_id']) if item['parent_id'] else 'nil'
                snip = to_lua_string(item['snippet'])
                cc = item.get('char_count', 0)
                src = to_lua_string(item['source'])
                prov = to_lua_string(item['provider'])
                dt = to_lua_string(item.get('date', ''))
                lua_lines.append(f'  {{ thread_id = {tid}, id = {iid}, parent_id = {pid}, snippet = {snip}, char_count = {cc}, source = {src}, provider = {prov}, date = {dt} }},')
            lua_lines.append("}")
            print("\n".join(lua_lines))
        except Exception as e:
            print("return { error = " + json.dumps(str(e)) + " }")
        sys.exit(0)


    if args.get_marketplace_tools or args.get_marketplace_skills or args.get_installed_tools or args.get_installed_skills:
        import json
        config_dir = os.path.dirname(os.path.abspath(__file__))
        
        # Comprehensive MCP Marketplace Database
        mcp_marketplace = [
            {"id": "graphify", "title": "Graphify (AST Code Map)", "description": "Converts projects into structured knowledge graphs to beat context limits.", "author": "Open Source", "type": "mcp", "tags": ["code", "ast", "memory"]},
            {"id": "github", "title": "GitHub Connector", "description": "Securely connect to GitHub with OAuth to read/write PRs, issues, and repos.", "author": "GitHub", "type": "mcp", "tags": ["auth", "git", "connector"]},
            {"id": "canvas", "title": "Canvas LMS Connector", "description": "Live sync and auth with Canvas LMS to manage courses, assignments, and grades.", "author": "Instructure", "type": "mcp", "tags": ["auth", "education", "connector"]},
            {"id": "slack", "title": "Slack Automator", "description": "Read channels, send messages, and automate Slack workflows via proper OAuth.", "author": "Slack", "type": "mcp", "tags": ["auth", "communication", "connector"]},
            {"id": "postgres", "title": "Postgres SQL Explorer", "description": "Safely connect to PostgreSQL databases, read schemas, and run queries.", "author": "Community", "type": "mcp", "tags": ["database", "sql"]},
            {"id": "puppeteer", "title": "Puppeteer Browser", "description": "Headless browser automation for live web scraping and screenshotting.", "author": "Google", "type": "mcp", "tags": ["browser", "web"]},
            {"id": "gdrive", "title": "Google Drive Connector", "description": "OAuth connector to read and manage Google Docs, Sheets, and Drive files.", "author": "Google", "type": "mcp", "tags": ["auth", "files", "connector"]},
            {"id": "spotify", "title": "Spotify Controller", "description": "Control playback, read playlists, and analyze listening history via OAuth.", "author": "Spotify", "type": "mcp", "tags": ["auth", "media", "connector"]}
        ]
        
        # Load local skills for installed check and skill marketplace
        skills_file = os.path.join(config_dir, "local_skills.json")
        installed_skills = []
        if os.path.exists(skills_file):
            try:
                with open(skills_file, "r", encoding="utf-8") as f:
                    installed_skills = json.load(f)
            except: pass
            
        mcp_config_file = os.path.join(config_dir, "mcp_config.json")
        installed_mcp = []
        if os.path.exists(mcp_config_file):
            try:
                with open(mcp_config_file, "r", encoding="utf-8") as f:
                    mcp_conf = json.load(f)
                    installed_mcp = [{"id": k, "title": k.title(), "type": "mcp"} for k in mcp_conf.get("mcpServers", {}).keys()]
            except: pass

        if args.get_marketplace_tools:
            data = mcp_marketplace
        elif args.get_installed_tools:
            data = installed_mcp
        elif args.get_marketplace_skills:
            # Fallback to fetch skills from github if needed, or just show installed for now
            data = installed_skills
        elif args.get_installed_skills:
            data = installed_skills
            
        if args.out_file:
            with open(args.out_file, "w", encoding="utf-8") as f:
                json.dump(data, f)
        else:
            print(json.dumps(data))
        sys.exit(0)

    keys = load_keys()

    if args.validate_keys:
        validate_keys(keys)
        sys.exit(0)

    if args.delete_key:
        if args.provider in keys:
            del keys[args.provider]
            config_dir = os.path.dirname(os.path.abspath(__file__))
            with open(os.path.join(config_dir, "ai_api_keys.json"), "w") as f:
                json.dump(keys, f)
        print("OK")
        sys.exit(0)

    if args.set_key:
        keys[args.provider] = args.set_key
        config_dir = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(config_dir, "ai_api_keys.json"), "w") as f:
            json.dump(keys, f)
        print("OK")
        sys.exit(0)

    api_key = keys.get(args.provider, "")

    if not api_key and args.provider != "all":
        print(f"MISSING_API_KEY:{args.provider}", flush=True)
        sys.exit(1)

    if args.list_models:
        models = list_models(args.provider, keys)
        for m in models:
            print(m)
        sys.exit(0)
    
    if args.chat:
        run_agent(
            provider=args.provider,
            model_name=args.model,
            api_key=api_key,
            prompt=args.prompt,
            autopilot=args.autopilot,
            read_only=args.read_only,
            workspace=args.workspace,
            thread_id=args.thread_id,
            team_config_file=args.team_config
        )

if __name__ == "__main__":
    main()
