import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

bad = """    if args.chat:
        import asyncio
        asyncio.run(run_agent(
            provider=args.provider,
            model_name=args.model,
            api_key=api_key,
            prompt=args.prompt,
            autopilot=args.autopilot,
            read_only=args.read_only,
            workspace=args.workspace,
            thread_id=args.thread_id,
            enable_tools=args.enable_tools,
            active_skill=args.active_skill,
            skill_state=args.skill_state
        )"""

good = """    if args.chat:
        import asyncio
        asyncio.run(run_agent(
            provider=args.provider,
            model_name=args.model,
            api_key=api_key,
            prompt=args.prompt,
            autopilot=args.autopilot,
            read_only=args.read_only,
            workspace=args.workspace,
            thread_id=args.thread_id,
            enable_tools=args.enable_tools,
            active_skill=args.active_skill,
            skill_state=args.skill_state
        ))"""

content = content.replace(bad, good)

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "w", encoding="utf-8") as f:
    f.write(content)

print("Fixed syntax error!")