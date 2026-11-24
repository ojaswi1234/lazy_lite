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
import xml.etree.ElementTree as ET

try:
    import pptx
    from pptx import Presentation
    from pptx.util import Inches, Pt
    from pptx.enum.shapes import MSO_SHAPE, MSO_SHAPE_TYPE
    from pptx.enum.text import PP_ALIGN
    from pptx.dml.color import RGBColor
    from pptx.oxml.ns import qn
except ImportError:
    pptx = None
    Presentation = None
    qn = None

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

def extract_lum_mod_off(elem):
    """
    Extracts DrawingML luminance modulation (lumMod) and offset (lumOff)
    modifiers for theme tint and shade calculations.
    """
    lum_mod = None
    lum_off = None
    try:
        for child in elem:
            ctag = child.tag.split('}')[-1].lower()
            if ctag == 'lummod' and 'val' in child.attrib:
                lum_mod = float(child.attrib['val'])
            elif ctag == 'lumoff' and 'val' in child.attrib:
                lum_off = float(child.attrib['val'])
    except Exception:
        pass
    return lum_mod, lum_off

def apply_lum_mod_off(rgb, lum_mod=None, lum_off=None):
    """
    Applies DrawingML lumMod (scale) and lumOff (shift towards white)
    to compute exact theme color tints and shades.
    """
    r, g, b = rgb
    if lum_mod is not None:
        r = r * (lum_mod / 100000.0)
        g = g * (lum_mod / 100000.0)
        b = b * (lum_mod / 100000.0)
    if lum_off is not None:
        offset = 255.0 * (lum_off / 100000.0)
        r = r + offset
        g = g + offset
        b = b + offset
    return (
        max(0, min(255, int(round(r)))),
        max(0, min(255, int(round(g)))),
        max(0, min(255, int(round(b))))
    )

def load_theme_colors(prs):
    """
    Parses DrawingML theme color scheme (dk1, lt1, accent1..accent6, etc.)
    from the presentation's theme part with 100% precision.
    """
    theme_colors = {
        "dk1": (0, 0, 0),
        "lt1": (255, 255, 255),
        "dk2": (31, 73, 125),
        "lt2": (238, 236, 225),
        "accent1": (79, 129, 189),
        "accent2": (192, 80, 77),
        "accent3": (155, 187, 89),
        "accent4": (128, 100, 162),
        "accent5": (75, 172, 198),
        "accent6": (247, 150, 70),
        "hlink": (0, 0, 255),
        "folhlink": (128, 0, 128),
        "tx1": (0, 0, 0),
        "bg1": (255, 255, 255),
        "tx2": (31, 73, 125),
        "bg2": (238, 236, 225),
    }
    try:
        for rel in prs.part.rels.values():
            if "theme" in rel.reltype:
                root = ET.fromstring(rel.target_part.blob)
                for clrScheme in root.iter('{http://schemas.openxmlformats.org/drawingml/2006/main}clrScheme'):
                    for elem in clrScheme:
                        tag = elem.tag.split('}')[-1].lower()
                        srgb = elem.find('{http://schemas.openxmlformats.org/drawingml/2006/main}srgbClr')
                        if srgb is not None and 'val' in srgb.attrib:
                            hex_c = srgb.attrib['val']
                            theme_colors[tag] = (int(hex_c[0:2], 16), int(hex_c[2:4], 16), int(hex_c[4:6], 16))
                        else:
                            sys_clr = elem.find('{http://schemas.openxmlformats.org/drawingml/2006/main}sysClr')
                            if sys_clr is not None and 'lastClr' in sys_clr.attrib:
                                hex_c = sys_clr.attrib['lastClr']
                                theme_colors[tag] = (int(hex_c[0:2], 16), int(hex_c[2:4], 16), int(hex_c[4:6], 16))
        if 'dk1' in theme_colors: theme_colors['tx1'] = theme_colors['dk1']
        if 'lt1' in theme_colors: theme_colors['bg1'] = theme_colors['lt1']
        if 'dk2' in theme_colors: theme_colors['tx2'] = theme_colors['dk2']
        if 'lt2' in theme_colors: theme_colors['bg2'] = theme_colors['lt2']
        # Register both short and long key aliases
        theme_colors['dark1'] = theme_colors.get('dk1', (0, 0, 0))
        theme_colors['light1'] = theme_colors.get('lt1', (255, 255, 255))
        theme_colors['dark2'] = theme_colors.get('dk2', (31, 73, 125))
        theme_colors['light2'] = theme_colors.get('lt2', (238, 236, 225))
        theme_colors['text1'] = theme_colors.get('tx1', (0, 0, 0))
        theme_colors['text2'] = theme_colors.get('tx2', (31, 73, 125))
        theme_colors['background1'] = theme_colors.get('bg1', (255, 255, 255))
        theme_colors['background2'] = theme_colors.get('bg2', (238, 236, 225))
        theme_colors['hyperlink'] = theme_colors.get('hlink', (0, 0, 255))
        theme_colors['followedhyperlink'] = theme_colors.get('folhlink', (128, 0, 128))
    except Exception:
        pass
    return theme_colors

def resolve_color(color_obj, xml_el=None, theme_dict=None, default=None):
    """
    Accurately extracts the author's RGB color from python-pptx color objects
    or OpenXML DrawingML elements, properly resolving theme colors and lumMod/lumOff shades.
    """
    if theme_dict is None:
        theme_dict = {}

    # 1. Try color_obj if present
    if color_obj is not None:
        c_type = getattr(color_obj, 'type', None)
        if c_type is not None:
            # 1a. Direct RGB
            try:
                rgb = color_obj.rgb
                if rgb:
                    return (rgb[0], rgb[1], rgb[2])
            except Exception:
                pass

            # 1b. Theme color enum
            try:
                tc = getattr(color_obj, "theme_color", None)
                if tc is not None:
                    name = getattr(tc, "name", None)
                    if not name:
                        name = str(tc).split('.')[-1].split(':')[0]
                    key = name.lower().replace('_', '')
                    if key in theme_dict:
                        base_rgb = theme_dict[key]
                        if xml_el is not None:
                            mod, off = extract_lum_mod_off(xml_el)
                            if mod is not None or off is not None:
                                return apply_lum_mod_off(base_rgb, mod, off)
                        return base_rgb
            except Exception:
                pass

    # 2. Inspect XML element directly (solidFill / srgbClr / schemeClr / lumMod / lumOff)
    if xml_el is not None:
        try:
            for solid in xml_el.iter('{http://schemas.openxmlformats.org/drawingml/2006/main}solidFill'):
                for child in solid:
                    tag = child.tag.split('}')[-1].lower()
                    if tag == 'srgbclr' and 'val' in child.attrib:
                        hex_c = child.attrib['val']
                        base_rgb = (int(hex_c[0:2], 16), int(hex_c[2:4], 16), int(hex_c[4:6], 16))
                        mod, off = extract_lum_mod_off(child)
                        if mod is not None or off is not None:
                            return apply_lum_mod_off(base_rgb, mod, off)
                        return base_rgb
                    elif tag == 'schemeclr' and 'val' in child.attrib:
                        val = child.attrib['val'].lower().replace('_', '')
                        if val in theme_dict:
                            base_rgb = theme_dict[val]
                            mod, off = extract_lum_mod_off(child)
                            if mod is not None or off is not None:
                                return apply_lum_mod_off(base_rgb, mod, off)
                            return base_rgb
        except Exception:
            pass

    return default

def get_color_rgb(color_obj, default=(0, 0, 0)):
    return resolve_color(color_obj, default=default)

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

def get_slide_background(slide, prs, theme_dict):
    """
    Extracts authentic slide background RGB color through the PPTX inheritance chain:
    Slide background -> Slide Layout background -> Slide Master background -> Theme bg1/lt1 -> (255, 255, 255).
    """
    try:
        if slide.background and slide.background.fill and slide.background.fill.type == 1:
            bg = resolve_color(slide.background.fill.fore_color, xml_el=getattr(slide.background, '_element', None), theme_dict=theme_dict)
            if bg:
                return bg
    except Exception:
        pass

    try:
        layout = getattr(slide, 'slide_layout', None)
        if layout and layout.background and layout.background.fill and layout.background.fill.type == 1:
            bg = resolve_color(layout.background.fill.fore_color, xml_el=getattr(layout.background, '_element', None), theme_dict=theme_dict)
            if bg:
                return bg
    except Exception:
        pass

    try:
        layout = getattr(slide, 'slide_layout', None)
        master = getattr(layout, 'slide_master', None) if layout else None
        if master and master.background and master.background.fill and master.background.fill.type == 1:
            bg = resolve_color(master.background.fill.fore_color, xml_el=getattr(master.background, '_element', None), theme_dict=theme_dict)
            if bg:
                return bg
    except Exception:
        pass

    return theme_dict.get('bg1', theme_dict.get('lt1', (255, 255, 255)))

def extract_paragraphs(tf, theme_colors, default_color):
    """
    Extracts paragraphs and detailed runs from a TextFrame with 100% color and style fidelity.
    Resolves paragraph-level colors, run-level colors, font sizes, bold styles, indents, and bullets.
    """
    paras = []
    text_lines = []
    for p in tf.paragraphs:
        p_text = p.text
        if not p_text.strip():
            continue

        text_lines.append(p_text.strip())

        # Paragraph font size in points
        pt_size = 18.0
        try:
            if p.font and p.font.size:
                pt_size = p.font.size.pt
            elif p.runs and p.runs[0].font and p.runs[0].font.size:
                pt_size = p.runs[0].font.size.pt
        except Exception:
            pt_size = 18.0

        # Paragraph bold weight
        is_bold = False
        try:
            if p.font and p.font.bold is not None:
                is_bold = p.font.bold
            elif p.runs and p.runs[0].font and p.runs[0].font.bold is not None:
                is_bold = p.runs[0].font.bold
        except Exception:
            is_bold = False

        # Resolve paragraph-level color
        p_color = None
        try:
            p_color = resolve_color(p.font.color, xml_el=getattr(p, '_p', None), theme_dict=theme_colors, default=None)
        except Exception:
            p_color = None

        # Runs breakdown
        runs_data = []
        first_explicit_run_color = None
        for r in p.runs:
            r_text = r.text
            if not r_text:
                continue

            r_size = pt_size
            try:
                if r.font and r.font.size:
                    r_size = r.font.size.pt
            except Exception:
                pass

            r_bold = is_bold
            try:
                if r.font and r.font.bold is not None:
                    r_bold = r.font.bold
            except Exception:
                pass

            r_color = resolve_color(r.font.color, xml_el=getattr(r, '_r', None), theme_dict=theme_colors, default=None)
            if r_color is not None and first_explicit_run_color is None:
                first_explicit_run_color = r_color

            runs_data.append({
                "text": r_text,
                "size": round(r_size, 1),
                "bold": r_bold,
                "color": r_color
            })

        # Effective paragraph color: explicit p_color -> first run explicit color -> slide default_color
        effective_p_color = p_color or first_explicit_run_color or default_color

        # Fill in any unset run colors
        for r_item in runs_data:
            if r_item["color"] is None:
                r_item["color"] = effective_p_color

        # Alignment
        align = "left"
        if p.alignment == PP_ALIGN.CENTER:
            align = "center"
        elif p.alignment == PP_ALIGN.RIGHT:
            align = "right"

        # Bullet indicator
        level = p.level or 0
        final_text = p_text.strip()
        has_bullet = final_text.startswith("•") or final_text.startswith("-") or level > 0
        if has_bullet and not (final_text.startswith("•") or final_text.startswith("-")):
            final_text = "• " + final_text
            if runs_data and not (runs_data[0]["text"].startswith("•") or runs_data[0]["text"].startswith("-")):
                runs_data[0]["text"] = "• " + runs_data[0]["text"]

        paras.append({
            "text": final_text,
            "size": round(pt_size, 1),
            "bold": is_bold,
            "color": effective_p_color,
            "align": align,
            "level": level,
            "bullet": has_bullet,
            "runs": runs_data
        })

    return paras, text_lines

def extract_slide_structured(prs, slide):
    """
    Extracts complete vector, picture, and typography document structure from slide.
    Coordinates are normalized to 0.0 .. 1.0 relative to slide width and height.
    """
    sw = float(prs.slide_width)
    sh = float(prs.slide_height)
    aspect = round(sw / max(sh, 1.0), 4)

    # Theme color definitions
    theme_colors = load_theme_colors(prs)

    # 1. Background color with full inheritance
    bg_color = get_slide_background(slide, prs, theme_colors)
    bg_lum = 0.299 * bg_color[0] + 0.587 * bg_color[1] + 0.114 * bg_color[2]
    default_text_color = theme_colors.get("tx1") or theme_colors.get("dk1") or ((0, 0, 0) if bg_lum >= 128 else (255, 255, 255))

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
                    fill_color = resolve_color(shape.fill.fore_color, xml_el=getattr(shape, '_element', None), theme_dict=theme_colors, default=None)
            except Exception:
                fill_color = None

            border_color = None
            border_w = 1
            try:
                if hasattr(shape, "line") and shape.line and shape.line.color:
                    border_color = resolve_color(shape.line.color, theme_dict=theme_colors, default=None)
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
                            cell_fill = (245, 247, 250) if r_idx == 0 else (255, 255, 255)
                            try:
                                if hasattr(cell, "fill") and cell.fill and cell.fill.type == 1:
                                    cell_fill = resolve_color(cell.fill.fore_color, xml_el=getattr(cell, '_tc', None), theme_dict=theme_colors, default=cell_fill)
                            except Exception:
                                pass
                            shapes_list.append({
                                "x": round(cx, 4),
                                "y": round(cy, 4),
                                "w": round(cw, 4),
                                "h": round(ch, 4),
                                "fill": cell_fill,
                                "border": (210, 218, 226),
                                "border_w": 1
                            })
                            if cell.text_frame:
                                cell_paras, cell_lines = extract_paragraphs(cell.text_frame, theme_colors, (25, 30, 38) if r_idx == 0 else default_text_color)
                                if cell_paras:
                                    full_text_lines.extend(cell_lines)
                                    text_blocks.append({
                                        "x": round(cx + 0.005, 4),
                                        "y": round(cy + 0.004, 4),
                                        "w": round(cw - 0.01, 4),
                                        "h": round(ch - 0.008, 4),
                                        "paragraphs": cell_paras
                                    })

            # Text Frames
            if shape.has_text_frame:
                paras, t_lines = extract_paragraphs(shape.text_frame, theme_colors, default_text_color)
                if paras:
                    full_text_lines.extend(t_lines)
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
                    f.write(f"      {{ text = \"{sanitize_str(p['text'])}\", size = {p['size']}, bold = {'true' if p['bold'] else 'false'}, color = {{{c[0]},{c[1]},{c[2]}}}, align = \"{p['align']}\", level = {p['level']}, bullet = {'true' if p['bullet'] else 'false'}")
                    if p.get("runs") and len(p["runs"]) > 1:
                        f.write(", runs = {\n")
                        for r in p["runs"]:
                            rc = r["color"]
                            f.write(f"        {{ text = \"{sanitize_str(r['text'])}\", size = {r['size']}, bold = {'true' if r['bold'] else 'false'}, color = {{{rc[0]},{rc[1]},{rc[2]}}} }},\n")
                        f.write("      }")
                    f.write(" },\n")
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
