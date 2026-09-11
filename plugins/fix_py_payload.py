import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

bad1 = """        if args.out_file:
            with open(args.out_file, "w", encoding="utf-8") as f:
                json.dump(tools, f)
        else:
            print(json.dumps(tools))"""

good1 = """        payload = {"skills": tools, "total_pages": 1}
        if args.out_file:
            with open(args.out_file, "w", encoding="utf-8") as f:
                json.dump(payload, f)
        else:
            print(json.dumps(payload))"""

content = content.replace(bad1, good1)

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "w", encoding="utf-8") as f:
    f.write(content)

print("Python dict payload fixed!")