# -*- coding: utf-8 -*-
"""
High Performance PowerPoint (PPTX) Browsh-Style Character Engine & Slideshow Renderer for Lite XL
Inspired by Browsh terminal browser and high-performance presentation display systems:
- Extracts slide dimensions (16:9 widescreen, 4:3 standard, custom), titles, speaker notes, and shapes.
- High-fidelity vector/raster compositing of shapes, pictures, tables, and formatted typography via Pillow.
- Dual-Layer rendering:
  1. Browsh-Style UTF-8 Sub-Pixel Character Matrix ('▀' U+2580 + crisp true text stream).
  2. HD Spatial-Banded Run-Length Encoded (RLE) pixel spans for instantaneous GPU/SDL2 drawing.
  3. Interactive Presentation / Slideshow mode with speaker notes extraction and deck navigation.
- Completely contained within Lite XL internal SDL2 renderer — zero external browser/Office popups.
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
    from PIL import Image, ImageDraw, ImageFont, ImageEnhance
except ImportError:
    Image = None
    ImageDraw = None
    ImageFont = None
    ImageEnhance = None

# EMU constants
EMU_PER_INCH = 914400
EMU_PER_PT = 12700

# Cached font loader for Windows system fonts
_FONT_CACHE = {}

def get_pil_font(family, size_pt, bold=False, italic=False):
    if not ImageFont:
        return None
    cache_key = (family, size_pt, bold, italic)
    if cache_key in _FONT_CACHE:
        return _FONT_CACHE[cache_key]

    windir = os.environ.get("WINDIR", "C:\\Windows")
    fonts_dir = os.path.join(windir, "Fonts")

    # Font candidate mapping
    candidates = []
    f_lower = (family or "").lower()
    if "calibri" in f_lower:
        if bold and italic: candidates.append("calibriz.ttf")
        elif bold: candidates.append("calibrib.ttf")
        elif italic: candidates.append("calibrii.ttf")
        candidates.append("calibri.ttf")
    elif "arial" in f_lower:
        if bold and italic: candidates.append("arialbi.ttf")
        elif bold: candidates.append("arialbd.ttf")
        elif italic: candidates.append("ariali.ttf")
        candidates.append("arial.ttf")
    elif "segoe" in f_lower:
        if bold: candidates.append("segoeuib.ttf")
        candidates.append("segoeui.ttf")
    elif "times" in f_lower:
        if bold and italic: candidates.append("timesbi.ttf")
        elif bold: candidates.append("timesbd.ttf")
        elif italic: candidates.append("timesi.ttf")
        candidates.append("times.ttf")

    # General fallbacks
    if bold:
        candidates.extend(["calibrib.ttf", "arialbd.ttf", "segoeuib.ttf"])
    candidates.extend(["calibri.ttf", "arial.ttf", "segoeui.ttf", "tahoma.ttf"])

    px_size = max(8, int(size_pt * 1.333))

    font_obj = None
    for cand in candidates:
        cand_path = os.path.join(fonts_dir, cand)
        if os.path.exists(cand_path):
            try:
                font_obj = ImageFont.truetype(cand_path, px_size)
                break
            except Exception:
                pass

    if not font_obj:
        try:
            font_obj = ImageFont.load_default()
        except Exception:
            font_obj = None

    _FONT_CACHE[cache_key] = font_obj
    return font_obj

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

def get_color_rgb(color_obj, default=(40, 45, 50)):
    if not color_obj:
        return default
    try:
        rgb = color_obj.rgb
        return (rgb[0], rgb[1], rgb[2])
    except Exception:
        return default

def composite_slide_image(prs, slide, canvas_w=1280):
    """
    Renders PowerPoint slide into a high-fidelity PIL Image.
    Extracts backgrounds, auto-shapes, embedded images, tables, and formatted typography.
    """
    w_emu = prs.slide_width
    h_emu = prs.slide_height
    aspect = h_emu / max(w_emu, 1)
    canvas_h = int(canvas_w * aspect)

    scale_x = canvas_w / float(w_emu)
    scale_y = canvas_h / float(h_emu)

    # 1. Determine slide background
    bg_color = (252, 252, 253)
    try:
        if slide.background and slide.background.fill:
            fill = slide.background.fill
            if fill.type == 1: # MSO_FILL.SOLID
                bg_color = get_color_rgb(fill.fore_color, default=bg_color)
    except Exception:
        pass

    img = Image.new("RGB", (canvas_w, canvas_h), bg_color)
    draw = ImageDraw.Draw(img)

    extracted_words = []
    full_text_blocks = []
    speaker_notes = ""

    try:
        if slide.has_notes_slide and slide.notes_slide.notes_text_frame:
            speaker_notes = slide.notes_slide.notes_text_frame.text.strip()
    except Exception:
        speaker_notes = ""

    # Sort shapes by z-order
    for shape in slide.shapes:
        try:
            sx = int(shape.left * scale_x)
            sy = int(shape.top * scale_y)
            sw = max(1, int(shape.width * scale_x))
            sh = max(1, int(shape.height * scale_y))

            # Shape background / fill
            fill_color = None
            try:
                if hasattr(shape, "fill") and shape.fill and shape.fill.type == 1:
                    fill_color = get_color_rgb(shape.fill.fore_color, None)
            except Exception:
                fill_color = None

            # Border / line
            line_color = None
            line_w = 1
            try:
                if hasattr(shape, "line") and shape.line and shape.line.color:
                    line_color = get_color_rgb(shape.line.color, None)
                    if shape.line.width:
                        line_w = max(1, int(shape.line.width * scale_x))
            except Exception:
                line_color = None

            # Draw basic shape rectangle/oval if fill or line present
            if fill_color or line_color:
                if fill_color:
                    draw.rectangle([sx, sy, sx + sw, sy + sh], fill=fill_color)
                if line_color:
                    draw.rectangle([sx, sy, sx + sw, sy + sh], outline=line_color, width=line_w)

            # Embedded Pictures
            if shape.shape_type == MSO_SHAPE_TYPE.PICTURE or hasattr(shape, "image"):
                try:
                    blob = shape.image.blob
                    pic = Image.open(io.BytesIO(blob)).convert("RGBA")
                    pic_resized = pic.resize((sw, sh), Image.Resampling.BILINEAR)
                    img.paste(pic_resized, (sx, sy), pic_resized)
                    pic.close()
                    pic_resized.close()
                except Exception:
                    pass

            # Tables
            if shape.has_table:
                table = shape.table
                n_rows = len(table.rows)
                n_cols = len(table.columns)
                if n_rows > 0 and n_cols > 0:
                    row_h = max(1, sh // n_rows)
                    col_w = max(1, sw // n_cols)
                    for r_i, row in enumerate(table.rows):
                        for c_i, cell in enumerate(row.cells):
                            cx = sx + c_i * col_w
                            cy = sy + r_i * row_h
                            draw.rectangle([cx, cy, cx + col_w, cy + row_h], outline=(180, 190, 200), width=1)
                            if cell.text.strip():
                                c_font = get_pil_font("Calibri", 12)
                                draw.text((cx + 6, cy + 4), cell.text.strip(), fill=(30, 35, 40), font=c_font)
                                full_text_blocks.append(cell.text.strip())

            # Text Frames
            if shape.has_text_frame:
                tf = shape.text_frame
                curr_y = sy + 6
                for p_idx, p in enumerate(tf.paragraphs):
                    p_text = p.text
                    if not p_text.strip():
                        curr_y += int(14 * scale_y * 1000)
                        continue

                    full_text_blocks.append(p_text.strip())

                    # Paragraph font properties
                    font_size_pt = 18
                    try:
                        if p.font and p.font.size:
                            font_size_pt = p.font.size.pt
                        elif p.runs and p.runs[0].font.size:
                            font_size_pt = p.runs[0].font.size.pt
                    except Exception:
                        font_size_pt = 18

                    # Adjust font size according to canvas scaling
                    font_size_pt = max(10, min(64, font_size_pt * (canvas_w / 1280.0)))

                    font_bold = False
                    try:
                        if p.font and p.font.bold is not None:
                            font_bold = p.font.bold
                        elif p.runs and p.runs[0].font.bold is not None:
                            font_bold = p.runs[0].font.bold
                    except Exception:
                        font_bold = False

                    font_color = (25, 30, 35)
                    try:
                        if p.font and p.font.color:
                            font_color = get_color_rgb(p.font.color, font_color)
                        elif p.runs and p.runs[0].font.color:
                            font_color = get_color_rgb(p.runs[0].font.color, font_color)
                    except Exception:
                        font_color = (25, 30, 35)

                    # High contrast adjustment if background is dark
                    bg_lum = 0.299 * bg_color[0] + 0.587 * bg_color[1] + 0.114 * bg_color[2]
                    fg_lum = 0.299 * font_color[0] + 0.587 * font_color[1] + 0.114 * font_color[2]
                    if bg_lum < 100 and fg_lum < 100:
                        font_color = (240, 245, 250)
                    elif bg_lum > 160 and fg_lum > 160:
                        font_color = (25, 30, 35)

                    font_obj = get_pil_font("Calibri", font_size_pt, bold=font_bold)
                    line_height = int(font_size_pt * 1.35)

                    # Word wrapping
                    words = p_text.split()
                    lines = []
                    curr_line = []
                    for w in words:
                        curr_line.append(w)
                        test_str = " ".join(curr_line)
                        try:
                            bbox = draw.textbbox((0, 0), test_str, font=font_obj)
                            w_px = bbox[2] - bbox[0]
                        except Exception:
                            w_px = len(test_str) * font_size_pt * 0.6
                        if w_px > max(100, sw - 12):
                            if len(curr_line) > 1:
                                curr_line.pop()
                                lines.append(" ".join(curr_line))
                                curr_line = [w]
                            else:
                                lines.append(test_str)
                                curr_line = []
                    if curr_line:
                        lines.append(" ".join(curr_line))

                    # Alignment
                    align = p.alignment
                    for l_str in lines:
                        try:
                            bbox = draw.textbbox((0, 0), l_str, font=font_obj)
                            lw = bbox[2] - bbox[0]
                            lh = bbox[3] - bbox[1]
                        except Exception:
                            lw = len(l_str) * font_size_pt * 0.6
                            lh = line_height

                        draw_x = sx + 6
                        if align == PP_ALIGN.CENTER:
                            draw_x = sx + max(0, (sw - lw) // 2)
                        elif align == PP_ALIGN.RIGHT:
                            draw_x = sx + max(0, sw - lw - 6)

                        draw.text((draw_x, curr_y), l_str, fill=font_color, font=font_obj)

                        # Record word bounding boxes for search & selection
                        for single_w in l_str.split():
                            extracted_words.append({
                                "text": single_w,
                                "x": round(draw_x / canvas_w, 4),
                                "y": round(curr_y / canvas_h, 4),
                                "w": round(lw / canvas_w, 4),
                                "h": round(lh / canvas_h, 4)
                            })

                        curr_y += line_height + 4
        except Exception:
            pass

    return img, bg_color, full_text_blocks, extracted_words, speaker_notes

def render_slide_browsh(img, bg_color, text_blocks, cols=110):
    """
    Converts composited PIL slide image into Browsh UTF-8 Half-Block Sub-Pixel Character Matrix.
    """
    orig_w, orig_h = img.size
    aspect = orig_h / max(orig_w, 1)
    rows = max(1, int(cols * aspect * 0.50))
    subpixel_h = rows * 2

    resized = img.resize((cols, subpixel_h), Image.Resampling.BILINEAR)
    pixels = resized.load()

    def color_diff(c1, c2):
        return abs(c1[0] - c2[0]) + abs(c1[1] - c2[1]) + abs(c1[2] - c2[2])

    graphic_runs = []
    for r in range(rows):
        y_top = r * 2
        y_bot = y_top + 1
        c = 0
        while c < cols:
            top = pixels[c, y_top]
            bot = pixels[c, y_bot] if y_bot < subpixel_h else bg_color

            if color_diff(top, bg_color) > 30 or color_diff(bot, bg_color) > 30:
                run_len = 1
                while c + run_len < cols:
                    ntop = pixels[c + run_len, y_top]
                    nbot = pixels[c + run_len, y_bot] if y_bot < subpixel_h else bg_color
                    if color_diff(top, ntop) < 25 and color_diff(bot, nbot) < 25:
                        run_len += 1
                    else:
                        break
                graphic_runs.append(f'{{{r},{c},{run_len},{{{top[0]},{top[1]},{top[2]}}},{{{bot[0]},{bot[1]},{bot[2]}}}}}')
                c += run_len
            else:
                c += 1

    resized.close()

    bg_lum = 0.299 * bg_color[0] + 0.587 * bg_color[1] + 0.114 * bg_color[2]
    text_fg = (25, 30, 26) if bg_lum > 130 else (240, 245, 240)

    text_lines = []
    full_text = "\n".join(text_blocks)
    return cols, rows, bg_color, graphic_runs, text_lines, full_text

def render_slide_hd(img, bg_color, target_width=1300):
    """
    Generates horizontal RLE pixel spans for smooth, zero-latency Lite XL drawing.
    """
    if ImageEnhance:
        enhancer = ImageEnhance.Contrast(img)
        img = enhancer.enhance(1.10)

    w, h = img.size
    pixels = img.load()

    def is_bg(c):
        return abs(c[0] - bg_color[0]) <= 3 and abs(c[1] - bg_color[1]) <= 3 and abs(c[2] - bg_color[2]) <= 3

    row_spans = []
    for y in range(h):
        in_run = False
        run_start = 0
        run_color = None

        for x in range(w):
            c = pixels[x, y]
            if is_bg(c):
                if in_run:
                    row_spans.append((run_start, y, x - run_start, 1, run_color))
                    in_run = False
            else:
                if not in_run:
                    in_run = True
                    run_start = x
                    run_color = c
                else:
                    if abs(c[0] - run_color[0]) > 4 or abs(c[1] - run_color[1]) > 4 or abs(c[2] - run_color[2]) > 4:
                        row_spans.append((run_start, y, x - run_start, 1, run_color))
                        run_start = x
                        run_color = c
        if in_run:
            row_spans.append((run_start, y, w - run_start, 1, run_color))

    # Coalesce identical vertical spans
    coalesced = []
    active = {}
    for span in row_spans:
        x, y, sw, sh, color = span
        key = (x, sw, color)
        if key in active:
            prev_y, prev_h = active[key]
            if prev_y + prev_h == y:
                active[key] = (prev_y, prev_h + 1)
                continue
            else:
                coalesced.append((x, prev_y, sw, prev_h, color))
                del active[key]
        active[key] = (y, 1)

    for key, (prev_y, prev_h) in active.items():
        x, sw, color = key
        coalesced.append((x, prev_y, sw, prev_h, color))

    formatted_spans = [
        f"    {{{s[0]},{s[1]},{s[2]},{s[3]},{s[4][0]},{s[4][1]},{s[4][2]}}}"
        for s in coalesced
    ]
    return w, h, bg_color, formatted_spans

def render_slide(pptx_path, slide_idx, out_file, width=110, mode="hd"):
    try:
        if not Presentation:
            raise RuntimeError("python-pptx is not installed.")

        prs = Presentation(pptx_path)
        if slide_idx < 0 or slide_idx >= len(prs.slides):
            raise IndexError(f"Slide index {slide_idx} out of range (0..{len(prs.slides)-1})")

        slide = prs.slides[slide_idx]
        target_w = 1280 if mode == "hd" else 960
        img, bg_color, text_blocks, words, notes = composite_slide_image(prs, slide, canvas_w=target_w)
        full_text = "\n".join(text_blocks)

        if mode == "hd":
            w, h, page_bg, spans = render_slide_hd(img, bg_color, target_width=target_w)
            with open(out_file, "w", encoding="utf-8") as f:
                f.write("return {\n")
                f.write("  mode = 'hd',\n")
                f.write(f"  w = {w},\n  h = {h},\n")
                f.write(f"  bg = {{{page_bg[0]}, {page_bg[1]}, {page_bg[2]}}},\n")
                f.write(f"  notes = {escape_lua_string(notes)},\n")
                f.write(f"  text = {escape_lua_string(full_text)},\n")
                f.write("  words = {\n")
                for w_item in words:
                    clean_t = sanitize_str(w_item["text"])
                    f.write(f"    {{ x = {w_item['x']}, y = {w_item['y']}, w = {w_item['w']}, h = {w_item['h']}, text = \"{clean_t}\" }},\n")
                f.write("  },\n")
                f.write("  spans = {\n")
                f.write(",\n".join(spans))
                f.write("\n  }\n}\n")

        elif mode == "text":
            w, h = img.size
            with open(out_file, "w", encoding="utf-8") as f:
                f.write("return {\n")
                f.write("  mode = 'text',\n")
                f.write(f"  w = {w},\n  h = {h},\n")
                f.write(f"  bg = {{{bg_color[0]}, {bg_color[1]}, {bg_color[2]}}},\n")
                f.write(f"  notes = {escape_lua_string(notes)},\n")
                f.write(f"  text = {escape_lua_string(full_text)}\n")
                f.write("}\n")

        else: # browsh mode
            cols = int(width) if width else 110
            cols, rows, page_bg, graphic_runs, text_lines, text = render_slide_browsh(img, bg_color, text_blocks, cols=cols)
            with open(out_file, "w", encoding="utf-8") as f:
                f.write("return {\n")
                f.write("  mode = 'browsh',\n")
                f.write(f"  cols = {cols},\n  rows = {rows},\n")
                f.write(f"  bg = {{{page_bg[0]}, {page_bg[1]}, {page_bg[2]}}},\n")
                f.write(f"  notes = {escape_lua_string(notes)},\n")
                f.write(f"  text = {escape_lua_string(full_text)},\n")
                f.write("  graphic_runs = {\n")
                for gr in graphic_runs:
                    f.write("    " + gr + ",\n")
                f.write("  },\n")
                f.write("  text_lines = {\n")
                for tl in text_lines:
                    f.write("    " + tl + ",\n")
                f.write("  }\n}\n")

        img.close()

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
            # Check slide shapes
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

            # Check speaker notes
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
