with open(r"C:\Users\ojasw\.config\lite-xl\plugins\antigravity_sidebar.lua", "r", encoding="utf-8") as f:
    content = f.read()

old_skill = """    local col = self.hover_cloud_skill and P.bg_btn_hl or P.bg_btn
    renderer.draw_rect(sx, h_btn_y, sw, 30 * SCALE, col)
    draw_rect_outline(sx, h_btn_y, sw, 30 * SCALE, P.border)
    table.insert"""
new_skill = """    local col = self.hover_cloud_skill and P.bg_btn_hl or P.bg_btn
    renderer.draw_rect(sx, h_btn_y, sw, 30 * SCALE, col)
    draw_rect_outline(sx, h_btn_y, sw, 30 * SCALE, P.border)
    renderer.draw_text(sf, skill_txt, sx + 6 * SCALE, h_btn_y + math.floor((30 * SCALE - sf:get_height()) / 2), P.fg)
    table.insert"""

old_tools = """    local tcol = self.hover_cloud_tools and P.bg_btn_hl or P.bg_btn
    renderer.draw_rect(tx, h_btn_y, tw, 30 * SCALE, tcol)
    draw_rect_outline(tx, h_btn_y, tw, 30 * SCALE, P.border)
    table.insert"""
new_tools = """    local tcol = self.hover_cloud_tools and P.bg_btn_hl or P.bg_btn
    renderer.draw_rect(tx, h_btn_y, tw, 30 * SCALE, tcol)
    draw_rect_outline(tx, h_btn_y, tw, 30 * SCALE, P.border)
    renderer.draw_text(sf, tool_txt, tx + 6 * SCALE, h_btn_y + math.floor((30 * SCALE - sf:get_height()) / 2), P.fg)
    table.insert"""

content = content.replace(old_skill, new_skill).replace(old_tools, new_tools)

with open(r"C:\Users\ojasw\.config\lite-xl\plugins\antigravity_sidebar.lua", "w", encoding="utf-8") as f:
    f.write(content)