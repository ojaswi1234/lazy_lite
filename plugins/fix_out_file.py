import re

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "r", encoding="utf-8") as f:
    content = f.read()

bad1 = """        print(json.dumps(tools))
        sys.exit(0)"""
good1 = """        if args.out_file:
            with open(args.out_file, "w", encoding="utf-8") as f:
                json.dump(tools, f)
        else:
            print(json.dumps(tools))
        sys.exit(0)"""

bad2 = """        print(json.dumps(installed))
        sys.exit(0)"""
good2 = """        if args.out_file:
            with open(args.out_file, "w", encoding="utf-8") as f:
                json.dump(installed, f)
        else:
            print(json.dumps(installed))
        sys.exit(0)"""

content = content.replace(bad1, good1).replace(bad2, good2)

with open(r"C:\Users\ojasw\.config\lite-xl\scripts\ai_api_bridge.py", "w", encoding="utf-8") as f:
    f.write(content)

print("Fixed output routing!")