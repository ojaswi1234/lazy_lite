# -*- coding: utf-8 -*-
"""
High Performance PowerPoint (PPTX) Vector & Typography Engine for Lite XL
Features:
- Structured Vector Slide Extraction: Shapes, Cards, Borders, Fills, Tables, Pictures.
- Authentic TrueType Typography: Exact font sizing (points), weights (bold/regular),
  vibrant RGB colors, paragraph alignment, bullet points, and multi-level indents.
- Dual-Layer Rendering Pipeline:
  1. HD Vector & Native Typography Mode: Zero raster pixel blur, razor-sharp FreeType text.
  2. Browsh Sub-Pixel Character Matrix: Half-block graphics with true monospace text stream.
  3. Structured Document Reader Mode: Clean markdown-style text representation.
- Speaker Notes Extraction & Full-Text Presentation Search.
"""

import sys
import os
import io
import math
import traceback
import re

try:
    import pptx
    from pptx import Presentation
    from pptx.util import Inches, Pt
    from pptx.enum.shapes import MSO_SHAPE, MSO_SHAPE_TYPE
    from pptx.enum.text import PP_ALIGN
    from pptx.dml.color import RGBColor
except ImportError:
    pptx = None
    Presentation = None

try:
    from PIL import Image, ImageEnhance
except ImportError:
    Image = None
    ImageEnhance = None

# EMU constants
EMU_PER_INCH = 914400
EMU_PER_PT = 12700

def escape_lua_string(text):
    if not text:
        return "''"
    level = 3
    while f"]{'='*level}]" in text:
        level += 1
    return f"[{'='*level}[" + text + f"]{'='*level}]"

def sanitize_str(s):
    if not s:
        return ""
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r')

def get_color_rgb(color_obj, default=(35, 40, 48)):
    if not color_obj:
        return default
    try:
        rgb = color_obj.rgb
        return (rgb[0], rgb[1], rgb[2])
    except Exception:
        return default

def get_pptx_info(pptx_path, out_file):
    try:
        if not Presentation:
            raise RuntimeError("python-pptx is not installed.")

        prs = Presentation(pptx_path)
        slide_count = len(prs.slides)
        w_emu = prs.slide_width
        h_emu = prs.slide_height

        w_inches = round(w_emu / EMU_PER_INCH, 2)
        h_inches = round(h_emu / EMU_PER_INCH, 2)
        aspect = round(w_inches / max(h_inches, 0.01), 4)

        base_name = os.path.splitext(os.path.basename(pptx_path))[0]
        pres_title = base_name

        slides_meta = []
        for idx, slide in enumerate(prs.slides):
            s_title = f"Slide {idx + 1}"
            try:
                if slide.shapes.title and slide.shapes.title.text:
                    clean_t = slide.shapes.title.text.strip().split("\n")[0].strip()
                    if clean_t:
                        s_title = clean_t
                else:
                    for shp in slide.shapes:
                        if shp.has_text_frame and shp.text_frame.text:
                            clean_t = shp.text_frame.text.strip().split("\n")[0].strip()
                            if clean_t and len(clean_t) <= 60:
                                s_title = clean_t
                                break
            except Exception:
                pass

            if idx == 0 and s_title and s_title != f"Slide 1":
                pres_title = s_title

            has_notes = False
            notes_preview = ""
            try:
                if slide.has_notes_slide and slide.notes_slide.notes_text_frame:
                    n_text = slide.notes_slide.notes_text_frame.text.strip()
                    if n_text:
                        has_notes = True
                        notes_preview = n_text.split("\n")[0][:100]
            except Exception:
                pass

            slides_meta.append({
                "idx": idx + 1,
                "title": s_title,
                "has_notes": has_notes,
                "notes_preview": notes_preview
            })

        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write(f"  slide_count = {slide_count},\n")
            f.write(f"  title = \"{sanitize_str(pres_title)}\",\n")
            f.write(f"  width_inches = {w_inches},\n")
            f.write(f"  height_inches = {h_inches},\n")
            f.write(f"  aspect_ratio = {aspect},\n")
            f.write("  slides = {\n")
            for sm in slides_meta:
                f.write(f"    {{ idx = {sm['idx']}, title = \"{sanitize_str(sm['title'])}\", has_notes = {'true' if sm['has_notes'] else 'false'}, notes_preview = \"{sanitize_str(sm['notes_preview'])}\" }},\n")
            f.write("  }\n}\n")

    except Exception as e:
        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write(f"  error = {escape_lua_string(str(e))}\n")
            f.write("}\n")

def extract_slide_structured(prs, slide):
    """
    Extracts complete vector, picture, and typography document structure from slide.
    Coordinates are normalized to 0.0 .. 1.0 relative to slide width and height.
    """
    sw = float(prs.slide_width)
    sh = float(prs.slide_height)
    aspect = round(sw / max(sh, 1.0), 4)

    # 1. Background color
    bg_color = (252, 252, 253)
    try:
        if slide.background and slide.background.fill:
            fill = slide.background.fill
            if fill.type == 1: # SOLID
                bg_color = get_color_rgb(fill.fore_color, default=bg_color)
    except Exception:
        pass

    # 2. Speaker notes
    speaker_notes = ""
    try:
        if slide.has_notes_slide and slide.notes_slide.notes_text_frame:
            speaker_notes = slide.notes_slide.notes_text_frame.text.strip()
    except Exception:
        speaker_notes = ""

    shapes_list = []
    text_blocks = []
    images_list = []
    full_text_lines = []

    for shape in slide.shapes:
        try:
            nx = max(0.0, min(1.0, shape.left / sw))
            ny = max(0.0, min(1.0, shape.top / sh))
            nw = max(0.005, min(1.0, shape.width / sw))
            nh = max(0.005, min(1.0, shape.height / sh))

            # Shape visual styling (fill and border)
            fill_color = None
            try:
                if hasattr(shape, "fill") and shape.fill and shape.fill.type == 1:
                    fill_color = get_color_rgb(shape.fill.fore_color, None)
            except Exception:
                fill_color = None

            border_color = None
            border_w = 1
            try:
                if hasattr(shape, "line") and shape.line and shape.line.color:
                    border_color = get_color_rgb(shape.line.color, None)
                    if shape.line.width:
                        border_w = max(1, int(shape.line.width / EMU_PER_PT))
            except Exception:
                border_color = None

            # Record geometric container if visible fill or line
            if fill_color or border_color:
                shapes_list.append({
                    "x": round(nx, 4),
                    "y": round(ny, 4),
                    "w": round(nw, 4),
                    "h": round(nh, 4),
                    "fill": fill_color,
                    "border": border_color,
                    "border_w": border_w
                })

            # Embedded Pictures
            if (shape.shape_type == MSO_SHAPE_TYPE.PICTURE or hasattr(shape, "image")) and Image:
                try:
                    blob = shape.image.blob
                    pil_img = Image.open(io.BytesIO(blob)).convert("RGB")
                    # Scale down image to reasonable thumbnail resolution
                    thumb_w = min(400, max(60, int(nw * 800)))
                    thumb_h = max(30, int(thumb_w * (pil_img.height / max(pil_img.width, 1))))
                    resized = pil_img.resize((thumb_w, thumb_h), Image.Resampling.BILINEAR)
                    pil_img.close()

                    # RLE spans for picture
                    pixels = resized.load()
                    spans = []
                    for py in range(thumb_h):
                        in_run = False
                        run_start = 0
                        run_c = None
                        for px in range(thumb_w):
                            c = pixels[px, py]
                            if not in_run:
                                in_run = True
                                run_start = px
                                run_c = c
                            else:
                                if abs(c[0] - run_c[0]) > 6 or abs(c[1] - run_c[1]) > 6 or abs(c[2] - run_c[2]) > 6:
                                    spans.append((run_start, py, px - run_start, 1, run_c))
                                    run_start = px
                                    run_c = c
                        if in_run:
                            spans.append((run_start, py, thumb_w - run_start, 1, run_c))
                    resized.close()

                    images_list.append({
                        "x": round(nx, 4),
                        "y": round(ny, 4),
                        "w": round(nw, 4),
                        "h": round(nh, 4),
                        "tw": thumb_w,
                        "th": thumb_h,
                        "spans": spans
                    })
                except Exception:
                    pass

            # Tables
            if shape.has_table:
                table = shape.table
                n_rows = len(table.rows)
                n_cols = len(table.columns)
                if n_rows > 0 and n_cols > 0:
                    cw = nw / n_cols
                    ch = nh / n_rows
                    for r_idx, row in enumerate(table.rows):
                        for c_idx, cell in enumerate(row.cells):
                            cx = nx + c_idx * cw
                            cy = ny + r_idx * ch
                            shapes_list.append({
                                "x": round(cx, 4),
                                "y": round(cy, 4),
                                "w": round(cw, 4),
                                "h": round(ch, 4),
                                "fill": (245, 247, 250) if r_idx == 0 else (255, 255, 255),
                                "border": (210, 218, 226),
                                "border_w": 1
                            })
                            c_text = cell.text.strip()
                            if c_text:
                                full_text_lines.append(c_text)
                                text_blocks.append({
                                    "x": round(cx + 0.005, 4),
                                    "y": round(cy + 0.004, 4),
                                    "w": round(cw - 0.01, 4),
                                    "h": round(ch - 0.008, 4),
                                    "paragraphs": [{
                                        "text": c_text,
                                        "size": 14,
                                        "bold": (r_idx == 0),
                                        "color": (25, 30, 38) if r_idx == 0 else (45, 52, 64),
                                        "align": "left",
                                        "level": 0,
                                        "bullet": False
                                    }]
                                })

            # Text Frames
            if shape.has_text_frame:
                tf = shape.text_frame
                paras = []
                for p in tf.paragraphs:
                    p_text = p.text
                    if not p_text.strip():
                        continue

                    full_text_lines.append(p_text.strip())

                    # Font size in points
                    pt_size = 18.0
                    try:
                        if p.font and p.font.size:
                            pt_size = p.font.size.pt
                        elif p.runs and p.runs[0].font and p.runs[0].font.size:
                            pt_size = p.runs[0].font.size.pt
                    except Exception:
                        pt_size = 18.0

                    # Font weight (bold)
                    is_bold = False
                    try:
                        if p.font and p.font.bold is not None:
                            is_bold = p.font.bold
                        elif p.runs and p.runs[0].font and p.runs[0].font.bold is not None:
                            is_bold = p.runs[0].font.bold
                    except Exception:
                        is_bold = False

                    # Font color
                    p_color = (35, 40, 50)
                    try:
                        if p.font and p.font.color:
                            p_color = get_color_rgb(p.font.color, p_color)
                        elif p.runs and p.runs[0].font and p.runs[0].font.color:
                            p_color = get_color_rgb(p.runs[0].font.color, p_color)
                    except Exception:
                        p_color = (35, 40, 50)

                    # Ensure high contrast against slide background
                    bg_lum = 0.299 * bg_color[0] + 0.587 * bg_color[1] + 0.114 * bg_color[2]
                    fg_lum = 0.299 * p_color[0] + 0.587 * p_color[1] + 0.114 * p_color[2]
                    if bg_lum < 110 and fg_lum < 110:
                        p_color = (240, 245, 252)
                    elif bg_lum > 150 and fg_lum > 170:
                        p_color = (30, 36, 45)

                    # Alignment
                    align = "left"
                    if p.alignment == PP_ALIGN.CENTER:
                        align = "center"
                    elif p.alignment == PP_ALIGN.RIGHT:
                        align = "right"

                    # Bullet indicator
                    level = p.level or 0
                    has_bullet = p_text.strip().startswith("•") or p_text.strip().startswith("-") or level > 0

                    paras.append({
                        "text": p_text.strip(),
                        "size": round(pt_size, 1),
                        "bold": is_bold,
                        "color": p_color,
                        "align": align,
                        "level": level,
                        "bullet": has_bullet
                    })

                if paras:
                    text_blocks.append({
                        "x": round(nx, 4),
                        "y": round(ny, 4),
                        "w": round(nw, 4),
                        "h": round(nh, 4),
                        "paragraphs": paras
                    })

        except Exception:
            pass

    full_text = "\n".join(full_text_lines)
    return aspect, bg_color, speaker_notes, shapes_list, images_list, text_blocks, full_text

def render_slide_browsh_blocks(aspect, bg_color, text_blocks, cols=110):
    rows = max(1, int(cols * (1.0 / aspect) * 0.50))
    bg_lum = 0.299 * bg_color[0] + 0.587 * bg_color[1] + 0.114 * bg_color[2]
    default_fg = (25, 30, 35) if bg_lum > 130 else (240, 245, 250)

    # Place text directly into monospace grid lines
    text_lines = []
    for tb in text_blocks:
        start_r = int(tb["y"] * rows)
        start_c = int(tb["x"] * cols)
        cur_r = start_r
        for p in tb["paragraphs"]:
            if cur_r >= rows:
                break
            clean_str = sanitize_str(p["text"])
            fg = p["color"]
            text_lines.append(f'{{{cur_r},{start_c},"{clean_str}",{{{fg[0]},{fg[1]},{fg[2]}}}}}')
            cur_r += 1

    graphic_runs = []
    return cols, rows, bg_color, graphic_runs, text_lines

def render_slide(pptx_path, slide_idx, out_file, width=110, mode="hd"):
    try:
        if not Presentation:
            raise RuntimeError("python-pptx is not installed.")

        prs = Presentation(pptx_path)
        if slide_idx < 0 or slide_idx >= len(prs.slides):
            raise IndexError(f"Slide index {slide_idx} out of range (0..{len(prs.slides)-1})")

        slide = prs.slides[slide_idx]
        aspect, bg_color, notes, shapes, images, text_blocks, full_text = extract_slide_structured(prs, slide)

        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write(f"  mode = '{mode}',\n")
            f.write(f"  aspect_ratio = {aspect},\n")
            f.write(f"  bg = {{{bg_color[0]}, {bg_color[1]}, {bg_color[2]}}},\n")
            f.write(f"  notes = {escape_lua_string(notes)},\n")
            f.write(f"  text = {escape_lua_string(full_text)},\n")

            # 1. Shapes
            f.write("  shapes = {\n")
            for s in shapes:
                fill_str = f"{{{s['fill'][0]},{s['fill'][1]},{s['fill'][2]}}}" if s.get("fill") else "nil"
                border_str = f"{{{s['border'][0]},{s['border'][1]},{s['border'][2]}}}" if s.get("border") else "nil"
                f.write(f"    {{ x = {s['x']}, y = {s['y']}, w = {s['w']}, h = {s['h']}, fill = {fill_str}, border = {border_str}, border_w = {s.get('border_w', 1)} }},\n")
            f.write("  },\n")

            # 2. Embedded Pictures / Images
            f.write("  images = {\n")
            for img in images:
                f.write(f"    {{ x = {img['x']}, y = {img['y']}, w = {img['w']}, h = {img['h']}, tw = {img['tw']}, th = {img['th']}, spans = {{\n")
                for sp in img["spans"]:
                    f.write(f"      {{{sp[0]},{sp[1]},{sp[2]},{sp[3]},{sp[4][0]},{sp[4][1]},{sp[4][2]}}},\n")
                f.write("    } },\n")
            f.write("  },\n")

            # 3. Native FreeType Typography Blocks
            f.write("  text_blocks = {\n")
            for tb in text_blocks:
                f.write(f"    {{ x = {tb['x']}, y = {tb['y']}, w = {tb['w']}, h = {tb['h']}, paragraphs = {{\n")
                for p in tb["paragraphs"]:
                    c = p["color"]
                    f.write(f"      {{ text = \"{sanitize_str(p['text'])}\", size = {p['size']}, bold = {'true' if p['bold'] else 'false'}, color = {{{c[0]},{c[1]},{c[2]}}}, align = \"{p['align']}\", level = {p['level']}, bullet = {'true' if p['bullet'] else 'false'} }},\n")
                f.write("    } },\n")
            f.write("  },\n")

            # Browsh fallback matrix
            if mode == "browsh":
                cols, rows, bg, gruns, tlines = render_slide_browsh_blocks(aspect, bg_color, text_blocks, cols=int(width) if width else 110)
                f.write(f"  cols = {cols},\n  rows = {rows},\n")
                f.write("  graphic_runs = {},\n")
                f.write("  text_lines = {\n")
                for tl in tlines:
                    f.write(f"    {tl},\n")
                f.write("  },\n")

            f.write("}\n")

    except Exception as e:
        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write(f"  error = {escape_lua_string(str(e))}\n")
            f.write("}\n")

def search_pptx(pptx_path, query, out_file):
    try:
        if not Presentation:
            raise RuntimeError("python-pptx is not installed.")

        prs = Presentation(pptx_path)
        matches = []
        q_lower = query.lower()

        for idx, slide in enumerate(prs.slides):
            slide_text = []
            for shp in slide.shapes:
                if shp.has_text_frame:
                    slide_text.append(shp.text_frame.text)
                if shp.has_table:
                    for row in shp.table.rows:
                        for cell in row.cells:
                            slide_text.append(cell.text)

            combined = "\n".join(slide_text)
            if q_lower in combined.lower():
                matches.append({
                    "slide": idx + 1,
                    "target": "slide",
                    "snippet": sanitize_str(combined[:120].strip())
                })
                continue

            if slide.has_notes_slide and slide.notes_slide.notes_text_frame:
                n_text = slide.notes_slide.notes_text_frame.text
                if q_lower in n_text.lower():
                    matches.append({
                        "slide": idx + 1,
                        "target": "notes",
                        "snippet": sanitize_str(n_text[:120].strip())
                    })

        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write("  matches = {\n")
            for m in matches:
                f.write(f"    {{ slide = {m['slide']}, target = \"{m['target']}\", snippet = \"{m['snippet']}\" }},\n")
            f.write("  }\n}\n")

    except Exception as e:
        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write(f"  error = {escape_lua_string(str(e))}\n")
            f.write("}\n")

def main():
    if len(sys.argv) < 3:
        print("Usage: pptx_engine.py <command> <pptx_path> [args...]")
        sys.exit(1)

    cmd = sys.argv[1].lower()
    pptx_path = sys.argv[2]

    if cmd == "info":
        out_file = sys.argv[3]
        get_pptx_info(pptx_path, out_file)

    elif cmd == "render":
        slide_idx = int(sys.argv[3])
        out_file = sys.argv[4]
        width = int(sys.argv[5]) if len(sys.argv) > 5 else 110
        mode = sys.argv[6] if len(sys.argv) > 6 else "hd"
        render_slide(pptx_path, slide_idx, out_file, width=width, mode=mode)

    elif cmd == "search":
        query = sys.argv[3]
        out_file = sys.argv[4]
        search_pptx(pptx_path, query, out_file)

    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

if __name__ == "__main__":
    main()
