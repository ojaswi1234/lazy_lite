import re

with open(r"C:\Users\ojasw\.config\lite-xl\plugins\diff_utf8.txt", "r", encoding="utf-8") as f:
    content = f.read().replace('\r\n', '\n')

hunks = re.split(r'(^@@ [^@]+ @@.*?\n)', content, flags=re.MULTILINE)
out = [hunks[0]]

for i in range(1, len(hunks), 2):
    header = hunks[i]
    body = hunks[i+1]
    
    # Process body
    new_body = []
    lines = body.split('\n')
    if lines[-1] == '':
        lines.pop()
        
    for line in lines:
        if line.startswith("-") and "renderer.draw_text" in line:
            new_body.append(" " + line[1:])
        elif line == '\\ No newline at end of file':
            new_body.append(line)
        else:
            new_body.append(line)
            
    # Recalculate header
    old_cnt = 0
    new_cnt = 0
    for line in new_body:
        if line == '\\ No newline at end of file':
            continue
        if line.startswith(' '):
            old_cnt += 1
            new_cnt += 1
        elif line.startswith('-'):
            old_cnt += 1
        elif line.startswith('+'):
            new_cnt += 1
            
    m = re.match(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)', header)
    if m:
        old_start = m.group(1)
        new_start = m.group(3)
        rest = m.group(5)
        header = f"@@ -{old_start},{old_cnt} +{new_start},{new_cnt} @@{rest}\n"
        
    out.append(header)
    out.append("\n".join(new_body) + "\n")

with open(r"C:\Users\ojasw\.config\lite-xl\plugins\diff_fixed.txt", "w", encoding="utf-8", newline="\n") as f:
    f.write("".join(out))