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
                from groq import Groq
                client = Groq(api_key=api_key)
                m_list = [m.id for m in client.models.list().data if not any(x in m.id.lower() for x in ["whisper", "tts", "embed"])]
                models.extend([f"groq/{m}" for m in m_list])
            elif p == "openai":
                from openai import OpenAI
                client = OpenAI(api_key=api_key)
                m_list = [m.id for m in client.models.list().data if "gpt" in m.id or "o1" in m.id or "o3" in m.id or "o4" in m.id]
                models.extend([f"openai/{m}" for m in m_list])
            elif p == "ollama":
                from openai import OpenAI
                client = OpenAI(base_url="https://ollama.com/v1", api_key=api_key)
                m_list = [m.id for m in client.models.list().data if "embed" not in m.id.lower()]
                models.extend([f"ollama/{m}" for m in m_list])
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

def run_agent(provider, model_name, api_key, prompt, autopilot, read_only, workspace, thread_id):
    try:
        from langchain_core.messages import HumanMessage, AIMessage, ToolMessage, SystemMessage
        from langgraph.graph import StateGraph, START, END
        from langgraph.graph.message import add_messages
        from langchain_core.tools import tool
        from pydantic import BaseModel, Field
    except ImportError:
        print("ERROR: Missing dependencies. Please run:\npip install langchain langgraph langchain-google-genai langchain-groq langchain-openai langchain-anthropic pydantic duckduckgo-search", flush=True)
        sys.exit(1)

    def is_in_workspace(filepath: str) -> bool:
        if not workspace: return True # If no workspace provided, allow all
        abs_workspace = os.path.abspath(workspace)
        abs_path = os.path.abspath(filepath)
        return abs_path.startswith(abs_workspace)

    # Define Tools
    @tool
    def local_shell(command: str) -> str:
        """Executes a local shell command. Use this to run scripts, compile code, list directory contents, or check system state."""
        if read_only:
            return "ERROR: Read-Only mode is active. Cannot execute shell commands."
        
        # Guardrails: Command blacklist
        blacklist = [
            "rm -rf", "rm -r", "del /f", "rd /s", "rmdir /s", "remove-item -recurse", "remove-item -force",
            "format", "mkfs", "diskpart", "vssadmin", "bcdedit", 
            "reg add", "reg delete", "takeown", "icacls",
            "shutdown", "restart", "logoff", "stop-process", "set-executionpolicy",
            "attrib -h -s", "cipher /w"
        ]
        for b in blacklist:
            if b in command.lower():
                return f"ERROR: Command rejected due to security blacklist ({b})."

        if not autopilot:
            # Human in the loop pause
            print(f"\n[HITL_APPROVAL_REQUIRED] Tool: LocalShell\nCommand: {command}\nType 'y' to approve, 'n' to reject: ", end="", flush=True)
            choice = stdin_queue.get().lower()
            if choice not in ['y', 'yes', 'approve']:
                return "ERROR: User rejected this command."

        print(f"\n[EXEC] Running: {command}\n", flush=True)
        try:
            cwd = workspace if workspace else None
            proc = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=cwd, bufsize=1)
            
            output_lines = []
            
            def reader_thread():
                for line in proc.stdout:
                    sys.stdout.write(line)
                    sys.stdout.flush()
                    output_lines.append(line)
            
            import threading
            t = threading.Thread(target=reader_thread)
            t.daemon = True
            t.start()
            
            t.join(timeout=60)
            if t.is_alive():
                proc.kill()
                t.join()
                output_lines.append("\n[ERROR: Command forcefully terminated after 60s timeout.]")
            
            exit_code = proc.wait()
            
            full_output = "".join(output_lines)
            max_chars = 15000
            if len(full_output) > max_chars:
                half = max_chars // 2
                full_output = full_output[:half] + f"\n\n[... {len(full_output) - max_chars} characters truncated ...]\n\n" + full_output[-half:]
                
            final_res = f"--- Shell Output (Exit Code: {exit_code}) ---\n"
            final_res += full_output if full_output.strip() else "(Command executed with no output)"
            return final_res
            
        except Exception as e:
            return f"ERROR: {str(e)}"

    @tool
    def read_file(filepath: str, start_line: int = None, end_line: int = None) -> str:
        """Reads the contents of a local file. Optionally specify start_line and end_line (1-indexed) to read a specific chunk of a long file to save context window."""
        if not os.path.isabs(filepath) and workspace:
            filepath = os.path.join(workspace, filepath)
        
        if not is_in_workspace(filepath):
            return "ERROR: Path jail restricted. Cannot access files outside the current workspace."
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                lines = f.readlines()
            
            total_lines = len(lines)
            start_idx = max(0, start_line - 1) if start_line else 0
            end_idx = min(total_lines, end_line) if end_line else total_lines
            
            # Safety truncation for massively bloated files (prevents 100MB log file crashes)
            # Modern LLMs easily handle 2000 lines (~15k tokens).
            max_lines = 2000
            if (end_idx - start_idx) > max_lines:
                end_idx = start_idx + max_lines
            
            if start_idx >= total_lines:
                return f"ERROR: start_line {start_line} is beyond the end of the file (total lines: {total_lines})."
                
            chunk = "".join(lines[start_idx:end_idx])
            meta = f"--- File: {os.path.basename(filepath)} (Lines {start_idx+1} to {end_idx} of {total_lines}) ---\n"
            if end_idx < total_lines and not end_line:
                meta += f"[WARNING: File truncated to {max_lines} lines. Use start_line/end_line to read the rest.]\n"
            return meta + chunk
        except Exception as e:
            return f"ERROR: {str(e)}"

    @tool
    def write_file(filepath: str, content: str) -> str:
        """Writes content to a file, completely overwriting it."""
        if read_only:
            return "ERROR: Read-Only mode is active. Cannot modify files."
        
        if not os.path.isabs(filepath) and workspace:
            filepath = os.path.join(workspace, filepath)
        
        if not is_in_workspace(filepath):
            return "ERROR: Path jail restricted. Cannot modify files outside the current workspace."
        
        if not autopilot:
            print(f"\n[HITL_APPROVAL_REQUIRED] Tool: WriteFile\nFile: {filepath}\nType 'y' to approve, 'n' to reject: ", end="", flush=True)
            choice = stdin_queue.get().lower()
            if choice not in ['y', 'yes', 'approve']:
                return "ERROR: User rejected this file modification."

        try:
            os.makedirs(os.path.dirname(os.path.abspath(filepath)), exist_ok=True)
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(content)
            return f"Successfully wrote to {filepath}"
        except Exception as e:
            return f"ERROR: {str(e)}"

    @tool
    def web_search(query: str) -> str:
        """Searches the internet for up-to-date information."""
        try:
            from duckduckgo_search import DDGS
            results = DDGS().text(query, max_results=5)
            if not results: return "No results found."
            return "\n\n".join([f"Title: {r['title']}\nSnippet: {r['body']}\nURL: {r['href']}" for r in results])
        except ImportError:
            return "ERROR: duckduckgo-search package not installed."
        except Exception as e:
            return f"ERROR: Web search failed: {str(e)}"

    tools = [read_file, web_search]
    if not read_only:
        tools.extend([local_shell, write_file])

    # Initialize LLM
    llm = None
    if provider == "gemini":
        from langchain_google_genai import ChatGoogleGenerativeAI
        llm = ChatGoogleGenerativeAI(model=model_name, api_key=api_key, temperature=0.2)
    elif provider == "groq":
        from langchain_groq import ChatGroq
        llm = ChatGroq(model_name=model_name, api_key=api_key, temperature=0.2)
    elif provider == "openai":
        from langchain_openai import ChatOpenAI
        llm = ChatOpenAI(model_name=model_name, api_key=api_key, temperature=0.2)
    elif provider == "ollama":
        from langchain_openai import ChatOpenAI
        llm = ChatOpenAI(model_name=model_name, api_key=api_key, base_url="https://ollama.com/v1", temperature=0.2)
    elif provider == "anthropic":
        from langchain_anthropic import ChatAnthropic
        llm = ChatAnthropic(model_name=model_name, api_key=api_key, temperature=0.2)
    
    if not llm:
        print(f"ERROR: Unsupported provider {provider}", flush=True)
        sys.exit(1)

    llm_with_tools = llm.bind_tools(tools)

    # Define Graph State
    class AgentState(TypedDict):
        messages: Annotated[list, add_messages]

    # Graph Nodes
    def chatbot(state: AgentState):
        # Inject the system prompt dynamically without saving it in the db every turn
        messages = [SystemMessage(content=system_prompt)] + state["messages"]
        try:
            msg = llm_with_tools.invoke(messages)
        except Exception as e:
            if "tool calling" in str(e).lower() or "tools" in str(e).lower() or "invalid_request" in str(e).lower() or "400" in str(e).lower():
                print("\n[WARNING] This model does not support tool calling. Falling back to chat-only mode.\n", flush=True)
                msg = llm.invoke(state["messages"])
            else:
                raise e
        return {"messages": [msg]}

    def tool_executor(state: AgentState):
        last_message = state["messages"][-1]
        tool_outputs = []
        for tool_call in last_message.tool_calls:
            tool_name = tool_call["name"]
            tool_args = tool_call["args"]
            print(f"\n[AGENT] Using tool: {tool_name}", flush=True)
            
            # Find and execute tool
            matched_tool = next((t for t in tools if t.name == tool_name), None)
            if matched_tool:
                try:
                    result = matched_tool.invoke(tool_args)
                except Exception as e:
                    result = f"Error executing tool: {str(e)}"
            else:
                result = f"Error: Tool {tool_name} not found."
                
            tool_outputs.append(ToolMessage(content=str(result), tool_call_id=tool_call["id"]))
        return {"messages": tool_outputs}

    def should_continue(state: AgentState):
        last_message = state["messages"][-1]
        if last_message.tool_calls:
            return "tools"
        return END

    # Build Graph
    graph_builder = StateGraph(AgentState)
    graph_builder.add_node("chatbot", chatbot)
    graph_builder.add_node("tools", tool_executor)
    
    graph_builder.add_edge(START, "chatbot")
    graph_builder.add_conditional_edges("chatbot", should_continue, {"tools": "tools", END: END})
    graph_builder.add_edge("tools", "chatbot")
    
    # Checkpointer Setup
    config_dir = os.path.dirname(os.path.abspath(__file__))
    db_path = os.path.join(config_dir, "ai_threads.db")
    conn = sqlite3.connect(db_path, check_same_thread=False)
    memory = SqliteSaver(conn)
    
    graph = graph_builder.compile(checkpointer=memory)

    ws_context = f"\nCURRENT WORKSPACE: {workspace}\n" if workspace else "\n"

    system_prompt = f"""You are Antigravity, an advanced AI coding assistant running inside the Lite XL editor. 
You have access to local shell execution, file editing, and web search.{ws_context}
CRITICAL INSTRUCTIONS:
1. THINK BEFORE EXECUTING: Always explore the directory structure first (e.g., using `dir` or `ls`) to understand the project architecture before blindly running commands.
2. IGNORE DEPENDENCY FOLDERS: When exploring, searching, or explaining the codebase, ALWAYS ignore dependency and environment folders (like `venv`, `.venv`, `my_env`, `node_modules`, `.git`, `__pycache__`, `vendor`, `target`). Focus strictly on the user's source code!
3. ECOSYSTEM AWARENESS & ENVIRONMENTS: Identify the language and framework of the project. ALWAYS respect and utilize isolated environments and local dependency managers:
   - Python: Look for virtual environments (`venv`, `.venv`, `env`, `my_env`). If found, ACTIVATE them (e.g., `<env>\\Scripts\\activate` on Windows or `source <env>/bin/activate` on Unix) before running `pip` or `python`. NEVER install globally.
   - Node.js/JS/TS: Look for `package.json` and lockfiles (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`). Use the correct package manager (`npm`, `yarn`, `pnpm`, `bun`).
   - Rust: Use `cargo`. Go: Use `go mod`. Ruby: Use `bundle` with `Gemfile`. PHP: Use `composer`. Java: Use `mvn` or `./gradlew`.
   - C/C++: Look for `CMakeLists.txt` or `Makefile`.
4. DEPENDENCIES: Always check for dependency manifests (`requirements.txt`, `package.json`, `Cargo.toml`, etc.) and ensure dependencies are installed in the proper environment before attempting to run or build the app.
5. CONTEXTUAL SEARCHING: You may use `local_shell` with `grep` or `findstr` to *locate* files containing specific keywords. However, once you find the file, DO NOT rely purely on small 10-line snippets to make edits. You MUST read the full file (or massive chunks of it) to understand the global context (imports, class state, variable scoping) before writing fixes.
6. LARGE FILES: The `read_file` tool automatically truncates files over 2000 lines. Modern LLMs can handle 2000 lines perfectly. Do not waste time reading a standard 500-line file "chunk by chunk" (which adds massive latency); just read the whole thing at once. Only use `start_line` and `end_line` if you hit the 2000-line truncation limit.
7. Think step-by-step and explain your rationale."""
    
    sys_msg = SystemMessage(content=system_prompt)
    
    print(f"--- Agent Initialized ({provider}/{model_name}) ---\n", flush=True)
    
    # Stream the graph execution
    try:
        inputs = {"messages": [HumanMessage(content=prompt)]}
        config = {"configurable": {"thread_id": thread_id}}
        # Use stream mode="messages" to stream tokens if supported, otherwise stream node outputs
        for event in graph.stream(inputs, config=config, stream_mode="messages"):
            msg, metadata = event
            if isinstance(msg, AIMessage) and msg.content:
                # Stream the content chunks
                sys.stdout.write(msg.content)
                sys.stdout.flush()
        print("\n\n--- Finished ---", flush=True)
    except Exception as e:
        if "tool calling" in str(e).lower() or "tools" in str(e).lower() or "invalid_request" in str(e).lower() or "400" in str(e).lower():
            print("\n[WARNING] This model does not support tool calling. Falling back to chat-only mode.\n", flush=True)
            try:
                for chunk in llm.stream([sys_msg, HumanMessage(content=prompt)]):
                    if chunk.content:
                        sys.stdout.write(chunk.content)
                        sys.stdout.flush()
            except Exception as e2:
                print(f"\nERROR in fallback execution: {str(e2)}", flush=True)
            print("\n\n--- Finished ---", flush=True)
        else:
            print(f"\nERROR in execution: {str(e)}", flush=True)

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
    parser.add_argument("--set-key", type=str)
    parser.add_argument("--delete-key", action="store_true")
    parser.add_argument("--validate-keys", action="store_true")
    args = parser.parse_args()

    # Intercept and expand pasted text files directly into the prompt to bypass OS command-line limits
    if args.prompt:
        import re
        import os
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
            thread_id=args.thread_id
        )

if __name__ == "__main__":
    main()
