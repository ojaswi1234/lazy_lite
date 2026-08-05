# -*- coding: utf-8 -*-
"""
High Performance PDF Browsh-Style Character Engine & Renderer for Lite XL
Inspired by Browsh terminal browser:
- Renders page layout, colors, images and shapes via UTF-8 sub-pixel character matrices ('▀' U+2580).
- Overlays crisp true text characters, symbols, numbers, and words aligned to the monospace grid.
- Completely contained within Lite XL internal SDL2 renderer — never launches external browsers.
"""

import sys
import os
import json
import traceback

try:
    import pypdfium2 as pdfium
    import pypdfium2.raw as pdfium_c
    import ctypes
except ImportError:
    pdfium = None
    pdfium_c = None
    ctypes = None

try:
    import pypdf
except ImportError:
    pypdf = None

try:
    from PIL import Image, ImageEnhance
except ImportError:
    Image = None
    ImageEnhance = None

ASCII_RAMP = " .:-=+*#%@"

def get_pdf_info(pdf_path, out_file):
    try:
        if not pdfium and not pypdf:
            raise RuntimeError("Neither pypdfium2 nor pypdf is installed.")
        
        info = {
            "path": pdf_path,
            "title": os.path.basename(pdf_path),
            "author": "",
            "page_count": 0,
            "pages": []
        }
        
        if pdfium:
            pdf = pdfium.PdfDocument(pdf_path)
            info["page_count"] = len(pdf)
            meta = pdf.get_metadata_dict()
            if meta:
                info["title"] = meta.get("Title") or info["title"]
                info["author"] = meta.get("Author") or ""
            for i in range(len(pdf)):
                page = pdf[i]
                w, h = page.get_size()
                info["pages"].append({"w": round(w, 2), "h": round(h, 2)})
            pdf.close()
        elif pypdf:
            reader = pypdf.PdfReader(pdf_path)
            info["page_count"] = len(reader.pages)
            if reader.metadata:
                info["title"] = reader.metadata.title or info["title"]
                info["author"] = reader.metadata.author or ""
            for p in reader.pages:
                box = p.mediabox
                info["pages"].append({"w": float(box.width), "h": float(box.height)})
                
        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write(f"  page_count = {info['page_count']},\n")
            t_escaped = info['title'].replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ')
            f.write(f"  title = \"{t_escaped}\",\n")
            f.write("  pages = {\n")
            for p in info['pages']:
                f.write(f"    {{ w = {p['w']}, h = {p['h']} }},\n")
            f.write("  }\n}\n")
            
    except Exception as e:
        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write(f"  error = [===[{str(e)}]===]\n")
            f.write("}\n")

def render_page_browsh(pdf, page_idx, cols=110):
    """
    Renders PDF page into a clean Browsh-style Dual-Layer Half-Block Sub-Pixel Character Matrix.
    - Page Background: Auto-detects paper color (e.g. RGB 255,255,255) with zero noise in whitespace.
    - Text Stream: Sharp line-aligned character lines with high-contrast text coloring and ZERO gray/black background boxes.
    - Graphics Layer: Half-block '▀' runs only where non-background graphical elements (images, banners, charts) actually exist.
    """
    page = pdf[page_idx]
    orig_w, orig_h = page.get_size()
    
    aspect = orig_h / max(orig_w, 1)
    rows = max(1, int(cols * aspect * 0.48))
    subpixel_h = rows * 2
    
    scale = max(0.2, (cols * 8) / max(orig_w, 1))
    pil_img = page.render(scale=scale).to_pil().convert('RGB')
    resized = pil_img.resize((cols, subpixel_h), Image.Resampling.BILINEAR)
    pil_img.close()
    
    pixels = resized.load()
    
    # 1. Determine page background color (corners + border sampling)
    corners = [pixels[0, 0], pixels[cols - 1, 0], pixels[0, subpixel_h - 1], pixels[cols - 1, subpixel_h - 1]]
    page_bg = max(set(corners), key=corners.count)
    
    def color_diff(c1, c2):
        return abs(c1[0] - c2[0]) + abs(c1[1] - c2[1]) + abs(c1[2] - c2[2])
        
    # 2. Extract and align text characters line-by-line
    text_page = page.get_textpage()
    try:
        full_text = text_page.get_text_range().replace("\r", "")
    except:
        full_text = ""
        
    n_chars = text_page.count_chars()
    curr_line = []
    lines = []
    for i in range(n_chars):
        ch = text_page.get_text_range(i, 1)
        if ch == '\r':
            continue
        if ch == '\n':
            if curr_line:
                lines.append(curr_line)
                curr_line = []
            continue
        box = text_page.get_charbox(i)
        curr_line.append((ch, box))
        
    if curr_line:
        lines.append(curr_line)
        
    text_grid = {}
    for line in lines:
        if not line:
            continue
        first_char, first_box = line[0]
        left, bottom, right, top = first_box
        start_cx = max(0, int(left / orig_w * cols))
        start_cy = max(0, min(rows - 1, int((orig_h - ((top + bottom) / 2.0)) / orig_h * rows)))
        
        cur_x = start_cx
        for ch, box in line:
            if 0 <= start_cy < rows and 0 <= cur_x < cols:
                text_grid[(cur_x, start_cy)] = ch
            cur_x += 1
            
    # Format text lines for clean, crisp rendering without background boxes
    bg_lum = 0.299 * page_bg[0] + 0.587 * page_bg[1] + 0.114 * page_bg[2]
    text_fg = (25, 30, 26) if bg_lum > 130 else (240, 245, 240)
    
    text_lines = []
    for r in range(rows):
        line_chars = []
        has_text = False
        for c in range(cols):
            ch = text_grid.get((c, r), " ")
            if ch != " ":
                has_text = True
            line_chars.append(ch)
        if has_text:
            raw_str = "".join(line_chars).rstrip()
            leading = len(raw_str) - len(raw_str.lstrip())
            clean_str = raw_str.strip().replace("\\", "\\\\").replace('"', '\\"')
            text_lines.append(f'{{{r},{leading},"{clean_str}",{{{text_fg[0]},{text_fg[1]},{text_fg[2]}}}}}')
            
    # 3. Extract pure graphics runs (half-block '▀' only for non-background non-text cells)
    graphic_runs = []
    for r in range(rows):
        y_top = r * 2
        y_bot = y_top + 1
        c = 0
        while c < cols:
            if (c, r) in text_grid:
                c += 1
                continue
                
            top = pixels[c, y_top]
            bot = pixels[c, y_bot] if y_bot < subpixel_h else page_bg
            
            # Only consider graphic if it significantly differs from background
            if color_diff(top, page_bg) > 35 or color_diff(bot, page_bg) > 35:
                run_len = 1
                while c + run_len < cols and (c + run_len, r) not in text_grid:
                    ntop = pixels[c + run_len, y_top]
                    nbot = pixels[c + run_len, y_bot] if y_bot < subpixel_h else page_bg
                    if color_diff(top, ntop) < 25 and color_diff(bot, nbot) < 25:
                        run_len += 1
                    else:
                        break
                graphic_runs.append(f'{{{r},{c},{run_len},{{{top[0]},{top[1]},{top[2]}}},{{{bot[0]},{bot[1]},{bot[2]}}}}}')
                c += run_len
            else:
                c += 1
                
    resized.close()
    return cols, rows, page_bg, graphic_runs, text_lines, full_text

def render_page_hd(pdf, page_idx, target_width=1300):
    """
    Renders PDF page to high-fidelity 2D coalesced Run-Length Encoded (RLE) pixel spans.
    Preserves exact font anti-aliasing and subpixel geometry with zero degradation.
    """
    page = pdf[page_idx]
    orig_w, orig_h = page.get_size()
    scale = target_width / max(orig_w, 1)
    
    pil_img = page.render(scale=scale).to_pil().convert('RGB')
    
    # Enhance edge contrast for crisp readability of small/congested text
    if ImageEnhance:
        enhancer = ImageEnhance.Contrast(pil_img)
        pil_img = enhancer.enhance(1.15)
        
    w, h = pil_img.size
    pixels = pil_img.load()
    
    # Detect page background color
    corners = [
        pixels[0, 0], pixels[w - 1, 0], pixels[0, h - 1], pixels[w - 1, h - 1],
        pixels[w // 2, 0], pixels[w // 2, h - 1], pixels[0, h // 2], pixels[w - 1, h // 2]
    ]
    page_bg = max(set(corners), key=corners.count)
    
    def is_bg(c):
        return c == page_bg or (abs(c[0] - page_bg[0]) <= 2 and abs(c[1] - page_bg[1]) <= 2 and abs(c[2] - page_bg[2]) <= 2)

    text_page = page.get_textpage()
    try:
        full_text = text_page.get_text_range().replace("\r", "")
    except:
        full_text = ""
        
    # 1. Fast horizontal RLE row runs
    row_spans = []
    for y in range(h):
        current_row = []
        x = 0
        while x < w:
            c = pixels[x, y]
            if is_bg(c):
                x += 1
                continue
            run = 1
            while x + run < w:
                nc = pixels[x + run, y]
                if is_bg(nc) or nc != c:
                    break
                run += 1
            current_row.append([x, y, run, 1, c])
            x += run
        row_spans.append(current_row)
        
    pil_img.close()
    
    # 2. Fast O(N) Hash-Map Vertical Coalescing
    # Active rects: key = (sx, run, color) -> [sx, start_y, run, height, color]
    active_rects = {}
    merged_spans = []
    
    for y in range(h):
        current_active = {}
        for span in row_spans[y]:
            sx, sy, run, _, c = span
            key = (sx, run, c)
            if key in active_rects:
                rect = active_rects[key]
                rect[3] += 1  # extend height
                current_active[key] = rect
            else:
                rect = [sx, sy, run, 1, c]
                current_active[key] = rect
                merged_spans.append(rect)
        active_rects = current_active

    formatted_spans = [
        f"    {{{s[0]},{s[1]},{s[2]},{s[3]},{s[4][0]},{s[4][1]},{s[4][2]}}}"
        for s in merged_spans
    ]

    # Extract word bounding boxes for text selection
    words = []
    curr_word = []
    curr_box = None
    n_chars = text_page.count_chars()
    for i in range(n_chars):
        ch = text_page.get_text_range(i, 1)
        if ch in ('\r', '\n', ' ', '\t'):
            if curr_word:
                word_str = ''.join(curr_word)
                left, bottom, right, top = curr_box
                norm_x = round(left / orig_w, 4)
                norm_y = round((orig_h - top) / orig_h, 4)
                norm_w = round((right - left) / orig_w, 4)
                norm_h = round((top - bottom) / orig_h, 4)
                words.append({
                    "text": word_str,
                    "x": norm_x,
                    "y": norm_y,
                    "w": norm_w,
                    "h": norm_h
                })
                curr_word = []
                curr_box = None
            continue
        box = text_page.get_charbox(i)
        if not curr_box:
            curr_box = list(box)
        else:
            curr_box[0] = min(curr_box[0], box[0])
            curr_box[1] = min(curr_box[1], box[1])
            curr_box[2] = max(curr_box[2], box[2])
            curr_box[3] = max(curr_box[3], box[3])
        curr_word.append(ch)
    if curr_word:
        word_str = ''.join(curr_word)
        left, bottom, right, top = curr_box
        norm_x = round(left / orig_w, 4)
        norm_y = round((orig_h - top) / orig_h, 4)
        norm_w = round((right - left) / orig_w, 4)
        norm_h = round((top - bottom) / orig_h, 4)
        words.append({
            "text": word_str,
            "x": norm_x,
            "y": norm_y,
            "w": norm_w,
            "h": norm_h
        })

    # Comprehensive Hyperlink Extraction (PDFium WebLinks + Link Annotations + Text regex)
    links = []
    seen_links = set()

    def add_link(url_str, nx, ny, nw, nh):
        if not url_str or nw <= 0 or nh <= 0:
            return
        url_clean = url_str.strip()
        if url_clean.startswith("www."):
            url_clean = "https://" + url_clean
        key = (url_clean, round(nx, 3), round(ny, 3))
        if key not in seen_links:
            seen_links.add(key)
            links.append({
                "url": url_clean,
                "x": nx,
                "y": ny,
                "w": nw,
                "h": nh
            })

    # A. PDFium native web link detection
    try:
        page_link = pdfium_c.FPDFLink_LoadWebLinks(text_page.raw)
        if page_link:
            count = pdfium_c.FPDFLink_CountWebLinks(page_link)
            for i in range(count):
                buf_len = pdfium_c.FPDFLink_GetURL(page_link, i, None, 0)
                if buf_len > 0:
                    buf = ctypes.create_string_buffer(buf_len * 2 + 10)
                    pdfium_c.FPDFLink_GetURL(page_link, i, ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)), buf_len)
                    url_str = buf.value.decode('utf-8', errors='ignore').strip('\x00')
                    n_rects = pdfium_c.FPDFLink_CountRects(page_link, i)
                    for r_idx in range(n_rects):
                        l, t, r, b = ctypes.c_double(), ctypes.c_double(), ctypes.c_double(), ctypes.c_double()
                        pdfium_c.FPDFLink_GetRect(page_link, i, r_idx, ctypes.byref(l), ctypes.byref(t), ctypes.byref(r), ctypes.byref(b))
                        norm_x = round(l.value / orig_w, 4)
                        norm_y = round((orig_h - t.value) / orig_h, 4)
                        norm_w = round((r.value - l.value) / orig_w, 4)
                        norm_h = round((t.value - b.value) / orig_h, 4)
                        add_link(url_str, norm_x, norm_y, norm_w, norm_h)
            pdfium_c.FPDFLink_CloseWebLinks(page_link)
    except:
        pass

    # B. PDFium native link annotations
    try:
        pos_ref = ctypes.c_int(0)
        link_annot = pdfium_c.FPDF_LINK()
        while pdfium_c.FPDFLink_Enumerate(page.raw, ctypes.byref(pos_ref), ctypes.byref(link_annot)):
            action = pdfium_c.FPDFLink_GetAction(link_annot)
            if action:
                buf_len = pdfium_c.FPDFAction_GetURIPath(pdf.raw, action, None, 0)
                if buf_len > 0:
                    buf = ctypes.create_string_buffer(buf_len * 2 + 10)
                    pdfium_c.FPDFAction_GetURIPath(pdf.raw, action, buf, buf_len)
                    url_str = buf.value.decode('utf-8', errors='ignore').strip('\x00')
                    rect = pdfium_c.FS_RECTF()
                    pdfium_c.FPDFLink_GetAnnotRect(link_annot, ctypes.byref(rect))
                    norm_x = round(rect.left / orig_w, 4)
                    norm_y = round((orig_h - rect.top) / orig_h, 4)
                    norm_w = round((rect.right - rect.left) / orig_w, 4)
                    norm_h = round((rect.top - rect.bottom) / orig_h, 4)
                    add_link(url_str, norm_x, norm_y, norm_w, norm_h)
    except:
        pass

    # C. Fallback regex text matching on words
    import re
    url_pattern = re.compile(r'^(https?://[^\s()<>]+|www\.[^\s()<>]+|mailto:[^\s()<>]+)', re.IGNORECASE)
    for w_item in words:
        m = url_pattern.match(w_item["text"])
        if m:
            raw_url = m.group(1).rstrip('.,;:!?"\')]}')
            add_link(raw_url, w_item["x"], w_item["y"], w_item["w"], w_item["h"])

    formatted_words = [
        f"    {{ x = {w_item['x']}, y = {w_item['y']}, w = {w_item['w']}, h = {w_item['h']}, text = \"{w_item['text'].replace('\\\\', '\\\\\\\\').replace('\"', '\\\\\"')}\" }}"
        for w_item in words
    ]

    formatted_links = [
        f"    {{ x = {l_item['x']}, y = {l_item['y']}, w = {l_item['w']}, h = {l_item['h']}, url = \"{l_item['url'].replace('\\\\', '\\\\\\\\').replace('\"', '\\\\\"')}\" }}"
        for l_item in links
    ]

    return orig_w, orig_h, w, h, page_bg, formatted_spans, full_text, formatted_words, formatted_links

def render_page(pdf_path, page_idx, out_file, width=110, mode="browsh"):
    try:
        if not pdfium:
            raise RuntimeError("pypdfium2 required for page rendering.")
            
        pdf = pdfium.PdfDocument(pdf_path)
        if page_idx < 0 or page_idx >= len(pdf):
            raise IndexError(f"Page index {page_idx} out of range (0..{len(pdf)-1})")
            
        if mode == "hd":
            target_w = int(width) if width else 1300
            orig_w, orig_h, w, h, page_bg, spans, text, words, links = render_page_hd(pdf, page_idx, target_width=target_w)
            with open(out_file, "w", encoding="utf-8") as f:
                f.write("return {\n")
                f.write("  mode = 'hd',\n")
                f.write(f"  w = {w},\n  h = {h},\n")
                f.write(f"  orig_w = {int(orig_w)},\n  orig_h = {int(orig_h)},\n")
                f.write(f"  bg = {{{page_bg[0]}, {page_bg[1]}, {page_bg[2]}}},\n")
                f.write("  text = [===[" + text + "]===],\n")
                f.write("  words = {\n")
                f.write(",\n".join(words))
                f.write("\n  },\n")
                f.write("  links = {\n")
                f.write(",\n".join(links))
                f.write("\n  },\n")
                f.write("  spans = {\n")
                f.write(",\n".join(spans))
                f.write("\n  }\n}\n")
        elif mode == "text":
            page = pdf[page_idx]
            text_page = page.get_textpage()
            text = text_page.get_text_range().replace("\r", "")
            orig_w, orig_h = page.get_size()
            with open(out_file, "w", encoding="utf-8") as f:
                f.write("return {\n")
                f.write("  mode = 'text',\n")
                f.write(f"  w = {int(orig_w)},\n  h = {int(orig_h)},\n")
                f.write("  text = [===[" + text + "]===]\n}\n")
        else: # Browsh character sub-pixel mode
            cols = int(width) if width else 110
            cols, rows, page_bg, graphic_runs, text_lines, text = render_page_browsh(pdf, page_idx, cols=cols)
            with open(out_file, "w", encoding="utf-8") as f:
                f.write("return {\n")
                f.write("  mode = 'browsh',\n")
                f.write(f"  cols = {cols},\n  rows = {rows},\n")
                f.write(f"  bg = {{{page_bg[0]}, {page_bg[1]}, {page_bg[2]}}},\n")
                f.write("  text = [===[" + text + "]===],\n")
                f.write("  graphic_runs = {\n")
                for gr in graphic_runs:
                    f.write("    " + gr + ",\n")
                f.write("  },\n")
                f.write("  text_lines = {\n")
                for tl in text_lines:
                    f.write("    " + tl + ",\n")
                f.write("  }\n}\n")
                
        pdf.close()
    except Exception as e:
        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write(f"  error = [===[{str(e)}]===]\n")
            f.write("}\n")

def search_pdf(pdf_path, query, out_file):
    try:
        results = []
        if pdfium:
            pdf = pdfium.PdfDocument(pdf_path)
            for i in range(len(pdf)):
                page = pdf[i]
                orig_w, orig_h = page.get_size()
                text_page = page.get_textpage()
                search = text_page.search(query, match_case=False)
                while True:
                    match = search.get_next()
                    if not match:
                        break
                    idx, length = match
                    lefts, bottoms, rights, tops = [], [], [], []
                    for k in range(length):
                        l, b, r, t = text_page.get_charbox(idx + k)
                        lefts.append(l)
                        bottoms.append(b)
                        rights.append(r)
                        tops.append(t)
                    
                    ml, mb, mr, mt = min(lefts), min(bottoms), max(rights), max(tops)
                    nx = ml / max(orig_w, 1)
                    ny = (orig_h - mt) / max(orig_h, 1)
                    nw = (mr - ml) / max(orig_w, 1)
                    nh = (mt - mb) / max(orig_h, 1)
                    
                    results.append({
                        "page": i + 1,
                        "index": idx,
                        "length": length,
                        "rect": [round(nx, 4), round(ny, 4), round(nw, 4), round(nh, 4)]
                    })
                search.close()
            pdf.close()
        elif pypdf:
            reader = pypdf.PdfReader(pdf_path)
            query_lower = query.lower()
            for i, p in enumerate(reader.pages):
                text = p.extract_text() or ""
                if query_lower in text.lower():
                    results.append({
                        "page": i + 1,
                        "rect": [0.05, 0.05, 0.9, 0.05]
                    })
                    
        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            q_escaped = query.replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ')
            f.write(f"  query = \"{q_escaped}\",\n")
            f.write(f"  match_count = {len(results)},\n")
            f.write("  matches = {\n")
            for r in results:
                rect = r.get("rect", [0, 0, 0, 0])
                f.write(f"    {{ page = {r['page']}, rect = {{ {rect[0]}, {rect[1]}, {rect[2]}, {rect[3]} }} }},\n")
            f.write("  }\n}\n")
    except Exception as e:
        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write(f"  error = [===[{str(e)}]===]\n")
            f.write("}\n")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python pdf_engine.py info <pdf_file> <out_lua>")
        print("  python pdf_engine.py render <pdf_file> <page_idx> <out_lua> [width] [mode]")
        print("  python pdf_engine.py search <pdf_file> <query> <out_lua>")
        sys.exit(1)
        
    cmd = sys.argv[1]
    if cmd == "info" and len(sys.argv) >= 4:
        get_pdf_info(sys.argv[2], sys.argv[3])
    elif cmd == "render" and len(sys.argv) >= 5:
        pdf_file = sys.argv[2]
        page_idx = int(sys.argv[3])
        out_lua = sys.argv[4]
        width = int(sys.argv[5]) if len(sys.argv) > 5 else 120
        mode = sys.argv[6] if len(sys.argv) > 6 else "browsh"
        render_page(pdf_file, page_idx, out_lua, width=width, mode=mode)
    elif cmd == "search" and len(sys.argv) >= 5:
        search_pdf(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print("Invalid arguments:", sys.argv)
        sys.exit(1)
