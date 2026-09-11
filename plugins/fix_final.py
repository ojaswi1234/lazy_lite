import re

with open(r"C:\Users\ojasw\.config\lite-xl\plugins\antigravity_sidebar.lua", "r", encoding="utf-8") as f:
    content = f.read()

# Fix fg_dim
content = content.replace("local fg_muted = muted(fg, 0.55)", "local fg_muted = muted(fg, 0.55)\n  local fg_dim   = muted(fg, 0.40)")
content = content.replace("fg_muted    = fg_muted,", "fg_muted    = fg_muted,\n    fg_dim      = fg_dim,")

# Fix form missing draw_text
old_form = """renderer.draw_rect(x + pad, ty, bw, bh, P.bg_btn)
            table.insert"""
new_form = """renderer.draw_rect(x + pad, ty, bw, bh, P.bg_btn)
            renderer.draw_text(style.font, display, x + pad + 10 * SCALE, ty + (bh - style.font:get_height())/2, P.fg)
            table.insert"""
content = re.sub(r'renderer\.draw_rect\(x \+ pad, ty, bw, bh, P\.bg_btn\)\s*table\.insert', new_form, content)

with open(r"C:\Users\ojasw\.config\lite-xl\plugins\antigravity_sidebar.lua", "w", encoding="utf-8") as f:
    f.write(content)