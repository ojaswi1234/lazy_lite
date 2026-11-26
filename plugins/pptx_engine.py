# -*- coding: utf-8 -*-
"""
High Performance PowerPoint (PPTX) Vector, Chart & Typography Engine for Lite XL
Features:
- Full Master / Layout / Slide Inheritance: Resolves theme colors, theme fonts,
  non-placeholder master/layout background shapes, and placeholder styles.
- Vector Geometry & Alpha Media Pipeline: Renders rounded rectangles, ellipses,
  arrows, connectors, gradients, and transparent RGBA images with 2x LANCZOS
  supersampling to compact alpha-aware RLE spans preserving exact Z-order.
- Native OpenXML Chart Renderer: Draws c:lineChart, c:scatterChart, c:barChart,
  c:areaChart, and c:pieChart directly from chartSpace XML with axes, gridlines,
  markers, legends, and transparent chart backgrounds.
- Authentic FreeType Typography Metadata: Extracts true slide width (pt), vertical
  anchors (t/ctr/b), insets, explicit bullet rules (<a:buNone/>), rich runs, and
  serif/sans/mono font family hints.
- Dual/Tri-Mode Support: HD, Browsh character matrix, and Text reader + search.
"""

import io
import math
import os
import sys
import traceback
import xml.etree.ElementTree as ET

try:
    from pptx import Presentation
    from pptx.enum.shapes import MSO_SHAPE_TYPE
    from pptx.enum.text import PP_ALIGN
except ImportError:
    Presentation = None
    MSO_SHAPE_TYPE = None
    PP_ALIGN = None

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    Image = None
    ImageDraw = None
    ImageFont = None

EMU_PER_INCH = 914400
EMU_PER_PT = 12700

A_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
P_NS = "http://schemas.openxmlformats.org/presentationml/2006/main"
C_NS = "http://schemas.openxmlformats.org/drawingml/2006/chart"
R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

PRST_COLORS = {
    "black": (0, 0, 0),
    "white": (255, 255, 255),
    "red": (255, 0, 0),
    "green": (0, 128, 0),
    "blue": (0, 0, 255),
    "yellow": (255, 255, 0),
    "gray": (128, 128, 128),
    "grey": (128, 128, 128),
    "lightgray": (211, 211, 211),
    "darkgray": (169, 169, 169),
}

SERIF_HINTS = (
    "cambria", "georgia", "times", "garamond", "palatino", "serif",
    "merriweather", "playfair", "lora", "bitter", "book", "charter",
)
MONO_HINTS = (
    "consolas", "courier", "mono", "fira code", "jetbrains", "menlo",
    "monaco", "source code", "inconsolata", "hack", "dejavu sans mono",
)


def _tag_local(tag):
    return tag.split("}")[-1].lower() if tag else ""


def _bool_attr(el, attr="val", default=True):
    if el is None:
        return default
    v = el.attrib.get(attr)
    if v is None:
        return default
    return str(v).lower() not in ("0", "false", "no")


def escape_lua_string(text):
    if not text:
        return "''"
    level = 3
    while f"]{'=' * level}]" in text:
        level += 1
    return f"[{'=' * level}[" + text + f"]{'=' * level}]"


def sanitize_str(s):
    if not s:
        return ""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "")


def classify_font_family(typeface, theme_fonts=None):
    if not typeface:
        return None
    tf = typeface.strip()
    if tf.startswith("+mj") and theme_fonts:
        tf = theme_fonts.get("major", "")
    elif tf.startswith("+mn") and theme_fonts:
        tf = theme_fonts.get("minor", "")
    low = tf.lower()
    if any(h in low for h in MONO_HINTS):
        return "mono"
    if any(h in low for h in SERIF_HINTS):
        return "serif"
    return "sans" if low else None


def _extract_color_modifiers(elem):
    mods = {}
    try:
        for child in elem:
            ctag = _tag_local(child.tag)
            if ctag in ("lummod", "lumoff", "tint", "shade", "alpha") and "val" in child.attrib:
                mods[ctag] = float(child.attrib["val"]) / 100000.0
    except Exception:
        pass
    return mods


def _apply_color_modifiers(rgb, mods):
    if not mods:
        return rgb
    r, g, b = float(rgb[0]), float(rgb[1]), float(rgb[2])
    if "tint" in mods:
        t = mods["tint"]
        r = r * t + 255.0 * (1.0 - t)
        g = g * t + 255.0 * (1.0 - t)
        b = b * t + 255.0 * (1.0 - t)
    if "shade" in mods:
        s = mods["shade"]
        r *= s
        g *= s
        b *= s
    if "lummod" in mods:
        m = mods["lummod"]
        r *= m
        g *= m
        b *= m
    if "lumoff" in mods:
        off = 255.0 * mods["lumoff"]
        r += off
        g += off
        b += off
    return (
        max(0, min(255, int(round(r)))),
        max(0, min(255, int(round(g)))),
        max(0, min(255, int(round(b)))),
    )


def _parse_color_node(clr_el, theme_dict):
    if clr_el is None:
        return None
    tag = _tag_local(clr_el.tag)
    base = None
    if tag == "srgbclr" and "val" in clr_el.attrib:
        hx = clr_el.attrib["val"]
        if len(hx) >= 6:
            base = (int(hx[0:2], 16), int(hx[2:4], 16), int(hx[4:6], 16))
    elif tag == "schemeclr" and "val" in clr_el.attrib:
        key = clr_el.attrib["val"].lower().replace("_", "")
        base = theme_dict.get(key)
    elif tag == "prstclr" and "val" in clr_el.attrib:
        base = PRST_COLORS.get(clr_el.attrib["val"].lower())
    elif tag == "sysclr" and "lastClr" in clr_el.attrib:
        hx = clr_el.attrib["lastClr"]
        if len(hx) >= 6:
            base = (int(hx[0:2], 16), int(hx[2:4], 16), int(hx[4:6], 16))
    if base is None:
        return None
    return _apply_color_modifiers(base, _extract_color_modifiers(clr_el))


def _resolve_fill_element(fill_el, theme_dict):
    """Resolve solid color from an <a:solidFill> element; returns None if empty/invalid."""
    if fill_el is None:
        return None
    for child in fill_el:
        col = _parse_color_node(child, theme_dict)
        if col is not None:
            return col
    return None


def _resolve_grad_first_color(grad_el, theme_dict):
    if grad_el is None:
        return None
    colors = []
    for gs in grad_el.findall(f".//{{{A_NS}}}gs"):
        c = _resolve_fill_element(gs, theme_dict)
        if c is not None:
            colors.append(c)
    if not colors:
        return None
    return colors[len(colors) // 2]


def load_theme_info(prs):
    """Parse DrawingML theme colors and major/minor font families."""
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
    }
    theme_fonts = {"major": "Calibri", "minor": "Calibri"}
    try:
        for rel in prs.part.rels.values():
            if "theme" in rel.reltype:
                root = ET.fromstring(rel.target_part.blob)
                for clrScheme in root.iter(f"{{{A_NS}}}clrScheme"):
                    for elem in clrScheme:
                        tag = _tag_local(elem.tag)
                        srgb = elem.find(f"{{{A_NS}}}srgbClr")
                        if srgb is not None and "val" in srgb.attrib:
                            hx = srgb.attrib["val"]
                            theme_colors[tag] = (int(hx[0:2], 16), int(hx[2:4], 16), int(hx[4:6], 16))
                        else:
                            sys_clr = elem.find(f"{{{A_NS}}}sysClr")
                            if sys_clr is not None and "lastClr" in sys_clr.attrib:
                                hx = sys_clr.attrib["lastClr"]
                                theme_colors[tag] = (int(hx[0:2], 16), int(hx[2:4], 16), int(hx[4:6], 16))
                for ftag, key in (("majorFont", "major"), ("minorFont", "minor")):
                    fel = root.find(f".//{{{A_NS}}}{ftag}/{{{A_NS}}}latin")
                    if fel is not None and fel.attrib.get("typeface"):
                        theme_fonts[key] = fel.attrib["typeface"]
                break
    except Exception:
        pass

    aliases = {
        "tx1": "dk1", "text1": "dk1", "dark1": "dk1",
        "bg1": "lt1", "background1": "lt1", "light1": "lt1",
        "tx2": "dk2", "text2": "dk2", "dark2": "dk2",
        "bg2": "lt2", "background2": "lt2", "light2": "lt2",
        "hyperlink": "hlink", "followedhyperlink": "folhlink",
    }
    for k, src in aliases.items():
        if src in theme_colors:
            theme_colors[k] = theme_colors[src]
    return theme_colors, theme_fonts


def load_theme_colors(prs):
    tc, _ = load_theme_info(prs)
    return tc


def resolve_color(color_obj, xml_el=None, theme_dict=None, default=None):
    """Resolve explicit or theme RGB color without falling back falsely on empty fills."""
    theme_dict = theme_dict or {}
    if xml_el is not None:
        try:
            solid = xml_el.find(f"{{{A_NS}}}solidFill")
            if solid is None and _tag_local(xml_el.tag) != "solidfill":
                solid = xml_el.find(f".//{{{A_NS}}}solidFill")
            elif _tag_local(xml_el.tag) == "solidfill":
                solid = xml_el
            if solid is not None:
                c = _resolve_fill_element(solid, theme_dict)
                if c is not None:
                    return c
                # If solidFill explicitly exists on XML but is empty, do not hallucinate
                if len(list(solid)) == 0:
                    return default
        except Exception:
            pass

    if color_obj is not None and getattr(color_obj, "type", None) is not None:
        try:
            rgb = color_obj.rgb
            if rgb:
                return (rgb[0], rgb[1], rgb[2])
        except Exception:
            pass
        try:
            tc = getattr(color_obj, "theme_color", None)
            if tc is not None:
                name = getattr(tc, "name", None) or str(tc).split(".")[-1].split(":")[0]
                key = name.lower().replace("_", "")
                if key in theme_dict:
                    return theme_dict[key]
        except Exception:
            pass
    return default


def _extract_bg_from_cSld(cSld, theme_dict):
    if cSld is None:
        return None
    bg = cSld.find(f"{{{P_NS}}}bg")
    if bg is None:
        return None
    bgPr = bg.find(f"{{{P_NS}}}bgPr")
    if bgPr is not None:
        if bgPr.find(f"{{{A_NS}}}noFill") is not None:
            return None
        solid = bgPr.find(f"{{{A_NS}}}solidFill")
        if solid is not None:
            c = _resolve_fill_element(solid, theme_dict)
            if c is not None:
                return c
        grad = bgPr.find(f"{{{A_NS}}}gradFill")
        if grad is not None:
            c = _resolve_grad_first_color(grad, theme_dict)
            if c is not None:
                return c
        # blipFill background (image bg) — use a neutral fallback tint
        if bgPr.find(f"{{{A_NS}}}blipFill") is not None:
            return None  # let image shapes handle it; keep existing bg
    bgRef = bg.find(f"{{{P_NS}}}bgRef")
    if bgRef is not None:
        # <p:bgRef idx="..."> — the idx encodes which theme fill slot to use.
        # idx 1001-1012 → dk1/lt1/dk2/lt2/accent1-6 respectively.
        idx_str = bgRef.attrib.get("idx", "0")
        try:
            idx = int(idx_str)
        except ValueError:
            idx = 0
        # First try any explicit color child (srgbClr, sysClr, schemeClr, etc.)
        for child in bgRef:
            c = _parse_color_node(child, theme_dict)
            if c is not None:
                return c
        # Fallback: decode idx if no explicit child (idx maps to theme color slots)
        BGREF_IDX_KEYS = {
            1001: "dk1", 1002: "lt1", 1003: "dk2", 1004: "lt2",
            1005: "accent1", 1006: "accent2", 1007: "accent3",
            1008: "accent4", 1009: "accent5", 1010: "accent6",
            1011: "hlink", 1012: "folHlink",
        }
        slot = BGREF_IDX_KEYS.get(idx)
        if slot and slot in theme_dict:
            return theme_dict[slot]
    return None


def get_slide_background(slide, prs, theme_dict):
    """Resolve slide background through Slide -> Layout -> Master -> Theme bg1/lt1."""
    for holder in (
        slide,
        getattr(slide, "slide_layout", None),
        getattr(getattr(slide, "slide_layout", None), "slide_master", None),
    ):
        if holder is None:
            continue
        try:
            cSld = holder._element.find(f"{{{P_NS}}}cSld")
            c = _extract_bg_from_cSld(cSld, theme_dict)
            if c is not None:
                return c
        except Exception:
            pass
    return theme_dict.get("bg1", theme_dict.get("lt1", (255, 255, 255)))


def _encode_rgba_rle(pil_rgba, color_tol=3, alpha_tol=4, max_spans=28000):
    """Encode an RGBA image into compact 2D-merged spans skipping transparent pixels."""
    w, h = pil_rgba.size
    pixels = pil_rgba.load()

    def _run_pass(ctol, atol):
        row_spans = []
        active = {}  # (x, w) -> index in merged list
        merged = []
        for py in range(h):
            in_run = False
            run_start = 0
            run_c = None
            cur_row = []
            for px in range(w):
                r, g, b, a = pixels[px, py]
                if a < 12:
                    if in_run:
                        cur_row.append((run_start, px - run_start, run_c[0], run_c[1], run_c[2], run_c[3]))
                        in_run = False
                    continue
                cur = (r, g, b, a)
                if not in_run:
                    in_run = True
                    run_start = px
                    run_c = cur
                elif (
                    abs(r - run_c[0]) > ctol
                    or abs(g - run_c[1]) > ctol
                    or abs(b - run_c[2]) > ctol
                    or abs(a - run_c[3]) > atol
                ):
                    cur_row.append((run_start, px - run_start, run_c[0], run_c[1], run_c[2], run_c[3]))
                    run_start = px
                    run_c = cur
            if in_run:
                cur_row.append((run_start, w - run_start, run_c[0], run_c[1], run_c[2], run_c[3]))

            next_active = {}
            for x0, rw, r, g, b, a in cur_row:
                key = (x0, rw)
                prev_idx = active.get(key)
                if prev_idx is not None:
                    pm = merged[prev_idx]
                    if pm[1] + pm[3] == py and pm[4] == r and pm[5] == g and pm[6] == b and pm[7] == a:
                        merged[prev_idx] = (x0, pm[1], rw, pm[3] + 1, r, g, b, a)
                        next_active[key] = prev_idx
                        continue
                idx = len(merged)
                merged.append((x0, py, rw, 1, r, g, b, a))
                next_active[key] = idx
            active = next_active
            row_spans = merged
        return row_spans

    spans = _run_pass(color_tol, alpha_tol)
    if max_spans and len(spans) > max_spans:
        spans = _run_pass(max(color_tol, 8), max(alpha_tol, 12))
    return spans


def _get_pil_font(size_px, bold=False, serif=False):
    if ImageFont is None:
        return None
    if serif:
        candidates = ["C:/Windows/Fonts/georgiab.ttf" if bold else "C:/Windows/Fonts/georgia.ttf"]
    elif bold:
        candidates = ["C:/Windows/Fonts/arialbd.ttf", "C:/Windows/Fonts/segoeuib.ttf"]
    else:
        candidates = ["C:/Windows/Fonts/arial.ttf", "C:/Windows/Fonts/segoeui.ttf"]
    for p in candidates:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, max(8, int(round(size_px))))
            except Exception:
                pass
    try:
        return ImageFont.load_default()
    except Exception:
        return None


def _draw_dashed_line(draw, pts, fill, width, dash="solid"):
    """Draw solid or dashed/dotted polyline cleanly on a PIL ImageDraw."""
    if not pts or len(pts) < 2 or not fill:
        return
    if not dash or dash == "solid":
        draw.line(pts, fill=fill, width=width, joint="curve")
        return

    w = max(2, width)
    if dash in ("dot", "sysDot"):
        on_len, off_len = w * 1.6, w * 2.2
    elif dash in ("lgDash", "lgDashDot"):
        on_len, off_len = w * 7.0, w * 3.5
    else:  # dash, sysDash, dashDot
        on_len, off_len = w * 4.2, w * 2.8

    period = on_len + off_len
    carry = 0.0
    for i in range(len(pts) - 1):
        x0, y0 = pts[i]
        x1, y1 = pts[i + 1]
        dx, dy = x1 - x0, y1 - y0
        seg_len = math.hypot(dx, dy)
        if seg_len < 1e-6:
            continue
        ux, uy = dx / seg_len, dy / seg_len
        pos = 0.0
        while pos < seg_len:
            phase = (carry + pos) % period
            if phase < on_len:
                step = min(on_len - phase, seg_len - pos)
                sx, sy = x0 + ux * pos, y0 + uy * pos
                ex, ey = x0 + ux * (pos + step), y0 + uy * (pos + step)
                draw.line([(sx, sy), (ex, ey)], fill=fill, width=width)
                pos += step
            else:
                pos += min(period - phase, seg_len - pos)
        carry = (carry + seg_len) % period


def _draw_chart_marker(draw, cx, cy, r, sym, fill_rgba, stroke_rgba=None, stroke_w=1):
    """Draw a crisp OpenXML chart marker symbol (circle, square, diamond, triangle, x, plus)."""
    if sym == "none" or not fill_rgba:
        return
    if sym in ("square", "auto"):
        draw.rectangle([cx - r, cy - r, cx + r, cy + r], fill=fill_rgba, outline=stroke_rgba, width=stroke_w)
    elif sym == "diamond":
        poly = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
        draw.polygon(poly, fill=fill_rgba, outline=stroke_rgba)
    elif sym == "triangle":
        poly = [(cx, cy - r), (cx + r, cy + r), (cx - r, cy + r)]
        draw.polygon(poly, fill=fill_rgba, outline=stroke_rgba)
    elif sym == "x":
        draw.line([(cx - r, cy - r), (cx + r, cy + r)], fill=stroke_rgba or fill_rgba, width=max(2, stroke_w + 1))
        draw.line([(cx - r, cy + r), (cx + r, cy - r)], fill=stroke_rgba or fill_rgba, width=max(2, stroke_w + 1))
    elif sym in ("plus", "star"):
        draw.line([(cx - r, cy), (cx + r, cy)], fill=stroke_rgba or fill_rgba, width=max(2, stroke_w + 1))
        draw.line([(cx, cy - r), (cx, cy + r)], fill=stroke_rgba or fill_rgba, width=max(2, stroke_w + 1))
    else:
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=fill_rgba, outline=stroke_rgba, width=stroke_w)


def _apply_rot_flip(img, rot_deg=0.0, flip_h=False, flip_v=False):
    if flip_h:
        img = img.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    if flip_v:
        img = img.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    if abs(rot_deg) > 0.5:
        img = img.rotate(-rot_deg, resample=Image.Resampling.BICUBIC, expand=True)
    return img


def _render_vector_shape_spans(geom, fill_color, border_color, border_w_pt, nw, nh, prst_av, flip_h, flip_v, rot_deg=0.0, cust_geom_el=None):
    """Render non-rectangular vector shapes and custom DrawingML geometry with 2x supersampling."""
    if Image is None:
        return None
    tw = max(48, min(960, int(round(nw * 1440))))
    th = max(48, min(720, int(round(nh * 810))))
    ss = 2
    cw, ch = tw * ss, th * ss

    img = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    fill_rgba = (fill_color[0], fill_color[1], fill_color[2], 255) if fill_color else None
    stroke_rgba = (border_color[0], border_color[1], border_color[2], 255) if border_color else None
    lw = max(ss, int(round(border_w_pt * ss * (tw / max(nw * 720.0, 1.0))))) if stroke_rgba else 0
    pad = max(2, lw // 2 + 2) if stroke_rgba else 2
    x0, y0, x1, y1 = pad, pad, max(pad + 2, cw - 1 - pad), max(pad + 2, ch - 1 - pad)

    if cust_geom_el is not None:
        drew = False
        for path_el in cust_geom_el.findall(f".//{{{A_NS}}}path"):
            pw_g = float(path_el.attrib.get("w", 100000) or 100000)
            ph_g = float(path_el.attrib.get("h", 100000) or 100000)
            sx_g = (x1 - x0) / max(1.0, pw_g)
            sy_g = (y1 - y0) / max(1.0, ph_g)
            poly = []
            closed = False
            for cmd in path_el:
                ct = _tag_local(cmd.tag)
                if ct in ("moveto", "lnto"):
                    pt = cmd.find(f"{{{A_NS}}}pt")
                    if pt is not None:
                        poly.append((x0 + float(pt.attrib.get("x", 0)) * sx_g, y0 + float(pt.attrib.get("y", 0)) * sy_g))
                elif ct == "cubicbezto":
                    pts_b = cmd.findall(f"{{{A_NS}}}pt")
                    if len(pts_b) >= 3 and poly:
                        p0 = poly[-1]
                        p1 = (x0 + float(pts_b[0].attrib.get("x", 0)) * sx_g, y0 + float(pts_b[0].attrib.get("y", 0)) * sy_g)
                        p2 = (x0 + float(pts_b[1].attrib.get("x", 0)) * sx_g, y0 + float(pts_b[1].attrib.get("y", 0)) * sy_g)
                        p3 = (x0 + float(pts_b[2].attrib.get("x", 0)) * sx_g, y0 + float(pts_b[2].attrib.get("y", 0)) * sy_g)
                        for stp in range(1, 13):
                            u = stp / 12.0
                            mu = 1.0 - u
                            bx = (mu**3)*p0[0] + 3*(mu**2)*u*p1[0] + 3*mu*(u**2)*p2[0] + (u**3)*p3[0]
                            by = (mu**3)*p0[1] + 3*(mu**2)*u*p1[1] + 3*mu*(u**2)*p2[1] + (u**3)*p3[1]
                            poly.append((bx, by))
                    elif pts_b:
                        p_last = pts_b[-1]
                        poly.append((x0 + float(p_last.attrib.get("x", 0)) * sx_g, y0 + float(p_last.attrib.get("y", 0)) * sy_g))
                elif ct == "quadbezto":
                    pts_b = cmd.findall(f"{{{A_NS}}}pt")
                    if len(pts_b) >= 2 and poly:
                        p0 = poly[-1]
                        p1 = (x0 + float(pts_b[0].attrib.get("x", 0)) * sx_g, y0 + float(pts_b[0].attrib.get("y", 0)) * sy_g)
                        p2 = (x0 + float(pts_b[1].attrib.get("x", 0)) * sx_g, y0 + float(pts_b[1].attrib.get("y", 0)) * sy_g)
                        for stp in range(1, 9):
                            u = stp / 8.0
                            mu = 1.0 - u
                            bx = (mu**2)*p0[0] + 2*mu*u*p1[0] + (u**2)*p2[0]
                            by = (mu**2)*p0[1] + 2*mu*u*p1[1] + (u**2)*p2[1]
                            poly.append((bx, by))
                    elif pts_b:
                        p_last = pts_b[-1]
                        poly.append((x0 + float(p_last.attrib.get("x", 0)) * sx_g, y0 + float(p_last.attrib.get("y", 0)) * sy_g))
                elif ct == "close":
                    closed = True
            if len(poly) >= 2:
                drew = True
                if closed and len(poly) >= 3 and fill_rgba:
                    draw.polygon(poly, fill=fill_rgba, outline=stroke_rgba)
                if stroke_rgba:
                    draw.line(poly + ([poly[0]] if closed else []), fill=stroke_rgba, width=max(ss, lw), joint="curve")
                elif not closed and fill_rgba:
                    draw.line(poly, fill=fill_rgba, width=max(ss, int(round(2 * (tw / max(nw * 720.0, 1.0))))), joint="curve")
        if not drew:
            img.close()
            return None
    elif geom == "ellipse":
        draw.ellipse([x0, y0, x1, y1], fill=fill_rgba, outline=stroke_rgba, width=lw)
    elif geom == "roundRect":
        adj = prst_av.get("adj", 16667.0) / 100000.0
        radius = max(2, int(round(min(x1 - x0, y1 - y0) * adj)))
        draw.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=fill_rgba, outline=stroke_rgba, width=lw)
    elif geom in ("rightArrow", "leftArrow", "upArrow", "downArrow"):
        head_frac, shaft_frac = 0.42, 0.46
        w_span, h_span = x1 - x0, y1 - y0
        if geom in ("rightArrow", "leftArrow"):
            hw = max(4, int(w_span * head_frac))
            sy0 = y0 + int(h_span * (1.0 - shaft_frac) / 2.0)
            sy1 = y1 - int(h_span * (1.0 - shaft_frac) / 2.0)
            cy = (y0 + y1) // 2
            if geom == "rightArrow":
                hx = x1 - hw
                poly = [(x0, sy0), (hx, sy0), (hx, y0), (x1, cy), (hx, y1), (hx, sy1), (x0, sy1)]
            else:
                hx = x0 + hw
                poly = [(x1, sy0), (hx, sy0), (hx, y0), (x0, cy), (hx, y1), (hx, sy1), (x1, sy1)]
        else:
            hh = max(4, int(h_span * head_frac))
            sx0 = x0 + int(w_span * (1.0 - shaft_frac) / 2.0)
            sx1 = x1 - int(w_span * (1.0 - shaft_frac) / 2.0)
            cx = (x0 + x1) // 2
            if geom == "downArrow":
                hy = y1 - hh
                poly = [(sx0, y0), (sx0, hy), (x0, hy), (cx, y1), (x1, hy), (sx1, hy), (sx1, y0)]
            else:
                hy = y0 + hh
                poly = [(sx0, y1), (sx0, hy), (x0, hy), (cx, y0), (x1, hy), (sx1, hy), (sx1, y1)]
        draw.polygon(poly, fill=fill_rgba, outline=stroke_rgba)
        if stroke_rgba and lw > 1:
            draw.line(poly + [poly[0]], fill=stroke_rgba, width=lw)
    elif geom == "triangle":
        poly = [((x0 + x1) // 2, y0), (x1, y1), (x0, y1)]
        draw.polygon(poly, fill=fill_rgba, outline=stroke_rgba)
    elif geom == "diamond":
        cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
        poly = [(cx, y0), (x1, cy), (cx, y1), (x0, cy)]
        draw.polygon(poly, fill=fill_rgba, outline=stroke_rgba)
    elif geom in ("line", "straightConnector1"):
        p0 = (x1 if flip_h else x0, y1 if flip_v else y0)
        p1 = (x0 if flip_h else x1, y0 if flip_v else y1)
        col = stroke_rgba or fill_rgba
        if col:
            draw.line([p0, p1], fill=col, width=max(ss, lw))
    else:
        img.close()
        return None

    resized = img.resize((tw, th), Image.Resampling.LANCZOS)
    img.close()
    if abs(rot_deg) > 0.5:
        resized = _apply_rot_flip(resized, rot_deg=rot_deg)
    spans = _encode_rgba_rle(resized)
    rtw, rth = resized.size
    resized.close()
    return rtw, rth, spans


_SVG_NAMED_COLORS = {
    "black": (0, 0, 0), "white": (255, 255, 255), "red": (255, 0, 0),
    "green": (0, 128, 0), "blue": (0, 0, 255), "yellow": (255, 255, 0),
    "gray": (128, 128, 128), "grey": (128, 128, 128), "orange": (255, 165, 0),
    "purple": (128, 0, 128), "cyan": (0, 255, 255), "magenta": (255, 0, 255),
}


def _parse_svg_color(val, opacity=1.0):
    if not val:
        return None
    v = val.strip().lower()
    if v in ("none", "transparent"):
        return None
    rgb = None
    if v.startswith("#"):
        hx = v[1:]
        if len(hx) == 3:
            rgb = (int(hx[0] * 2, 16), int(hx[1] * 2, 16), int(hx[2] * 2, 16))
        elif len(hx) >= 6:
            rgb = (int(hx[0:2], 16), int(hx[2:4], 16), int(hx[4:6], 16))
    elif v.startswith("rgb("):
        nums = [int(float(x.strip())) for x in v[4:-1].split(",")[:3]]
        if len(nums) == 3:
            rgb = (max(0, min(255, nums[0])), max(0, min(255, nums[1])), max(0, min(255, nums[2])))
    else:
        rgb = _SVG_NAMED_COLORS.get(v)
    if rgb is None:
        return None
    a = max(0, min(255, int(round(255 * opacity))))
    return (rgb[0], rgb[1], rgb[2], a)


def _render_svg_to_rgba(svg_bytes, tw, th):
    """Lightweight offline SVG vector rasterizer onto an RGBA PIL image."""
    if Image is None:
        return None
    import re
    try:
        root = ET.fromstring(svg_bytes)
    except Exception:
        return None

    vb = root.attrib.get("viewBox")
    vb_x, vb_y, vb_w, vb_h = 0.0, 0.0, 100.0, 100.0
    if vb:
        parts = [float(p) for p in re.split(r"[\s,]+", vb.strip()) if p]
        if len(parts) == 4:
            vb_x, vb_y, vb_w, vb_h = parts
    else:
        try:
            vb_w = float(re.sub(r"[^0-9.]", "", root.attrib.get("width", "100")) or 100)
            vb_h = float(re.sub(r"[^0-9.]", "", root.attrib.get("height", "100")) or 100)
        except Exception:
            pass

    ss = 2
    cw, ch = max(24, tw * ss), max(24, th * ss)
    img = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    sx = cw / max(vb_w, 1e-6)
    sy = ch / max(vb_h, 1e-6)

    def map_pt(px, py, tx=0.0, ty=0.0):
        return ((px + tx - vb_x) * sx, (py + ty - vb_y) * sy)

    def parse_style(el):
        st = {}
        raw = el.attrib.get("style", "")
        for item in raw.split(";"):
            if ":" in item:
                k, v = item.split(":", 1)
                st[k.strip().lower()] = v.strip()
        for k in ("fill", "stroke", "stroke-width", "opacity", "fill-opacity", "stroke-opacity"):
            if k in el.attrib and k not in st:
                st[k] = el.attrib[k]
        return st

    def walk(el, parent_style, tx=0.0, ty=0.0):
        st = dict(parent_style)
        st.update(parse_style(el))
        tr = el.attrib.get("transform", "")
        m_tr = re.search(r"translate\(\s*([+-]?[0-9.eE+-]+)(?:[\s,]+([+-]?[0-9.eE+-]+))?\s*\)", tr)
        if m_tr:
            tx += float(m_tr.group(1))
            ty += float(m_tr.group(2) or 0.0)

        tag = _tag_local(el.tag)
        op = float(st.get("opacity", 1.0) or 1.0)
        fill_col = _parse_svg_color(st.get("fill", "#000000"), op * float(st.get("fill-opacity", 1.0) or 1.0)) if tag in ("rect", "circle", "ellipse", "polygon", "path") else None
        stroke_col = _parse_svg_color(st.get("stroke"), op * float(st.get("stroke-opacity", 1.0) or 1.0)) if "stroke" in st else None
        sw_px = max(1, int(round(float(re.sub(r"[^0-9.]", "", st.get("stroke-width", "1")) or 1) * min(sx, sy))))

        if tag == "rect":
            rx = float(el.attrib.get("x", 0))
            ry = float(el.attrib.get("y", 0))
            rw = float(el.attrib.get("width", 0))
            rh = float(el.attrib.get("height", 0))
            p0, p1 = map_pt(rx, ry, tx, ty), map_pt(rx + rw, ry + rh, tx, ty)
            draw.rectangle([p0[0], p0[1], p1[0], p1[1]], fill=fill_col, outline=stroke_col, width=sw_px)
        elif tag == "circle":
            cx, cy = float(el.attrib.get("cx", 0)), float(el.attrib.get("cy", 0))
            r = float(el.attrib.get("r", 0))
            p0, p1 = map_pt(cx - r, cy - r, tx, ty), map_pt(cx + r, cy + r, tx, ty)
            draw.ellipse([p0[0], p0[1], p1[0], p1[1]], fill=fill_col, outline=stroke_col, width=sw_px)
        elif tag == "ellipse":
            cx, cy = float(el.attrib.get("cx", 0)), float(el.attrib.get("cy", 0))
            rx, ry = float(el.attrib.get("rx", 0)), float(el.attrib.get("ry", 0))
            p0, p1 = map_pt(cx - rx, cy - ry, tx, ty), map_pt(cx + rx, cy + ry, tx, ty)
            draw.ellipse([p0[0], p0[1], p1[0], p1[1]], fill=fill_col, outline=stroke_col, width=sw_px)
        elif tag == "line":
            p0 = map_pt(float(el.attrib.get("x1", 0)), float(el.attrib.get("y1", 0)), tx, ty)
            p1 = map_pt(float(el.attrib.get("x2", 0)), float(el.attrib.get("y2", 0)), tx, ty)
            if stroke_col:
                draw.line([p0, p1], fill=stroke_col, width=sw_px)
        elif tag in ("polygon", "polyline"):
            coords = [float(x) for x in re.findall(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?", el.attrib.get("points", ""))]
            pts = [map_pt(coords[i], coords[i + 1], tx, ty) for i in range(0, len(coords) - 1, 2)]
            if len(pts) >= 2:
                if tag == "polygon" and fill_col:
                    draw.polygon(pts, fill=fill_col, outline=stroke_col)
                elif stroke_col:
                    draw.line(pts + ([pts[0]] if tag == "polygon" else []), fill=stroke_col, width=sw_px)
        elif tag == "path":
            d = el.attrib.get("d", "")
            toks = re.findall(r"[MLHVCSQTAZmlhvcsqtaz]|[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?", d)
            subpaths = []
            cur_pts = []
            cx, cy, sx0, sy0 = 0.0, 0.0, 0.0, 0.0
            i, cmd = 0, ""
            while i < len(toks):
                t = toks[i]
                if t.isalpha():
                    cmd = t
                    i += 1
                    if cmd in ("Z", "z"):
                        if cur_pts:
                            subpaths.append((cur_pts, True))
                            cur_pts = []
                        cx, cy = sx0, sy0
                    continue
                if cmd in ("M", "m", "L", "l"):
                    x, y = float(toks[i]), float(toks[i + 1])
                    i += 2
                    if cmd.islower():
                        x += cx
                        y += cy
                    if cmd in ("M", "m"):
                        if cur_pts:
                            subpaths.append((cur_pts, False))
                        cur_pts = [map_pt(x, y, tx, ty)]
                        sx0, sy0 = x, y
                        cmd = "l" if cmd == "m" else "L"
                    else:
                        cur_pts.append(map_pt(x, y, tx, ty))
                    cx, cy = x, y
                elif cmd in ("H", "h"):
                    x = float(toks[i]) + (cx if cmd == "h" else 0.0)
                    i += 1
                    cur_pts.append(map_pt(x, cy, tx, ty))
                    cx = x
                elif cmd in ("V", "v"):
                    y = float(toks[i]) + (cy if cmd == "v" else 0.0)
                    i += 1
                    cur_pts.append(map_pt(cx, y, tx, ty))
                    cy = y
                elif cmd in ("C", "c"):
                    x1, y1, x2, y2, x, y = [float(toks[i + k]) for k in range(6)]
                    i += 6
                    if cmd == "c":
                        x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy
                    for stp in range(1, 13):
                        u = stp / 12.0
                        bx = ((1 - u)**3)*cx + 3*((1 - u)**2)*u*x1 + 3*(1 - u)*(u**2)*x2 + (u**3)*x
                        by = ((1 - u)**3)*cy + 3*((1 - u)**2)*u*y1 + 3*(1 - u)*(u**2)*y2 + (u**3)*y
                        cur_pts.append(map_pt(bx, by, tx, ty))
                    cx, cy = x, y
                elif cmd in ("Q", "q"):
                    x1, y1, x, y = [float(toks[i + k]) for k in range(4)]
                    i += 4
                    if cmd == "q":
                        x1 += cx; y1 += cy; x += cx; y += cy
                    for stp in range(1, 9):
                        u = stp / 8.0
                        bx = ((1 - u)**2)*cx + 2*(1 - u)*u*x1 + (u**2)*x
                        by = ((1 - u)**2)*cy + 2*(1 - u)*u*y1 + (u**2)*y
                        cur_pts.append(map_pt(bx, by, tx, ty))
                    cx, cy = x, y
                else:
                    i += 1
            if cur_pts:
                subpaths.append((cur_pts, False))
            for pts, is_closed in subpaths:
                if len(pts) >= 2:
                    if is_closed and len(pts) >= 3 and fill_col:
                        draw.polygon(pts, fill=fill_col, outline=stroke_col)
                    elif stroke_col or fill_col:
                        draw.line(pts + ([pts[0]] if is_closed else []), fill=stroke_col or fill_col, width=sw_px)

        for child in el:
            walk(child, st, tx, ty)

    walk(root, {})
    out = img.resize((tw, th), Image.Resampling.LANCZOS)
    img.close()
    return out


def _extract_chart_text(el):
    if el is None:
        return ""
    texts = [t.text for t in el.iter(f"{{{A_NS}}}t") if t.text]
    return "".join(texts).strip()


def _extract_chart_num_map(container_el):
    """Return ordered {idx: float} dict preserving sparse <c:pt idx="..."> indices."""
    if container_el is None:
        return {}
    out = {}
    fallback_idx = 0
    for pt in container_el.findall(f".//{{{C_NS}}}pt"):
        v_el = pt.find(f"{{{C_NS}}}v")
        idx = int(pt.attrib["idx"]) if "idx" in pt.attrib else fallback_idx
        fallback_idx = idx + 1
        if v_el is not None and v_el.text is not None:
            try:
                out[idx] = float(v_el.text)
            except Exception:
                pass
    return out


def _extract_chart_str_map(container_el):
    """Return ordered {idx: str} dict and declared ptCount preserving sparse category indices."""
    if container_el is None:
        return {}, 0
    out = {}
    pt_cnt_el = container_el.find(f".//{{{C_NS}}}ptCount")
    pt_count = int(pt_cnt_el.attrib.get("val", 0)) if pt_cnt_el is not None else 0
    fallback_idx = 0
    for pt in container_el.findall(f".//{{{C_NS}}}pt"):
        v_el = pt.find(f"{{{C_NS}}}v")
        idx = int(pt.attrib["idx"]) if "idx" in pt.attrib else fallback_idx
        fallback_idx = idx + 1
        if v_el is not None and v_el.text is not None:
            out[idx] = v_el.text.strip()
    return out, max(pt_count, (max(out.keys()) + 1) if out else 0)


def _parse_spPr_stroke(spPr, theme_colors, default_color=None, default_w_pt=1.5):
    if spPr is None:
        return default_color, default_w_pt, False, "solid"
    ln = spPr.find(f"{{{A_NS}}}ln")
    if ln is None:
        return default_color, default_w_pt, False, "solid"
    if ln.find(f"{{{A_NS}}}noFill") is not None:
        return None, 0.0, True, "solid"
    col = resolve_color(None, xml_el=ln, theme_dict=theme_colors, default=default_color)
    w_pt = default_w_pt
    if "w" in ln.attrib:
        try:
            w_pt = max(0.5, float(ln.attrib["w"]) / EMU_PER_PT)
        except Exception:
            pass
    dash_el = ln.find(f"{{{A_NS}}}prstDash")
    dash = dash_el.attrib.get("val", "solid") if dash_el is not None else "solid"
    return col, w_pt, False, dash


def _parse_spPr_fill(spPr, theme_colors, default_color=None):
    if spPr is None:
        return default_color
    if spPr.find(f"{{{A_NS}}}noFill") is not None:
        return None
    solid = spPr.find(f"{{{A_NS}}}solidFill")
    if solid is not None:
        c = _resolve_fill_element(solid, theme_colors)
        if c is not None:
            return c
    return default_color


def _nice_ticks(vmin, vmax, count=5, fixed_step=None):
    if vmax <= vmin:
        return [vmin]
    span = vmax - vmin
    if fixed_step and fixed_step > 0:
        step = fixed_step
    else:
        raw_step = span / max(1, count - 1)
        mag = 10 ** math.floor(math.log10(raw_step))
        norm = raw_step / mag
        if norm <= 1.2:
            step = 1.0 * mag
        elif norm <= 2.2:
            step = 2.0 * mag
        elif norm <= 5.2:
            step = 5.0 * mag
        else:
            step = 10.0 * mag
    start = math.ceil((vmin - 1e-9) / step) * step
    ticks = []
    cur = start
    for _ in range(30):
        if cur > vmax + 1e-9:
            break
        ticks.append(round(cur, 6))
        cur += step
    if not ticks:
        ticks = [vmin, vmax]
    return ticks


def _fmt_num(val):
    if abs(val) < 1e-9:
        return "0"
    if abs(val - round(val)) < 1e-4:
        return str(int(round(val)))
    return f"{val:.2f}".rstrip("0").rstrip(".")


def _catmull_rom_points(pts, subdiv=6):
    if len(pts) < 3:
        return pts
    out = []
    ext = [pts[0]] + pts + [pts[-1]]
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        for s in range(subdiv):
            t = s / float(subdiv)
            t2 = t * t
            t3 = t2 * t
            x = 0.5 * (
                (2 * p1[0])
                + (-p0[0] + p2[0]) * t
                + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2
                + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3
            )
            y = 0.5 * (
                (2 * p1[1])
                + (-p0[1] + p2[1]) * t
                + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2
                + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3
            )
            out.append((x, y))
    out.append(pts[-1])
    return out


def render_chart_to_rgba_rle(chart_shape, nw, nh, theme_colors, effective_bg):
    """Render OpenXML c:chart XML accurately into anti-aliased RGBA RLE spans."""
    if Image is None or not chart_shape.has_chart:
        return None
    try:
        cs = chart_shape.chart._chartSpace
    except Exception:
        return None

    tw = max(240, min(960, int(round(nw * 1440))))  # 2x base res -> sharp at any display scale
    th = max(180, min(640, int(round(nh * 810))))
    ss = 2  # 2x supersampling -> 4x effective pixel density
    pt_scale = tw / max(nw * 720.0, 1.0)
    s_px = ss * pt_scale
    cw, ch = tw * ss, th * ss

    cs_spPr = cs.find(f"{{{C_NS}}}spPr")
    cs_bg = _parse_spPr_fill(cs_spPr, theme_colors, default_color=None)
    canvas_bg = (cs_bg[0], cs_bg[1], cs_bg[2], 255) if cs_bg else (0, 0, 0, 0)
    img = Image.new("RGBA", (cw, ch), canvas_bg)
    draw = ImageDraw.Draw(img)

    chart_el = cs.find(f"{{{C_NS}}}chart")
    if chart_el is None:
        img.close()
        return None

    plot_area = chart_el.find(f"{{{C_NS}}}plotArea")
    if plot_area is None:
        img.close()
        return None

    title_text = ""
    title_color = (235, 240, 245) if (0.299 * effective_bg[0] + 0.587 * effective_bg[1] + 0.114 * effective_bg[2]) < 128 else (0, 30, 43)
    auto_deleted = _bool_attr(chart_el.find(f"{{{C_NS}}}autoTitleDeleted"), default=False)
    title_el = chart_el.find(f"{{{C_NS}}}title")
    if title_el is not None and not auto_deleted:
        title_text = _extract_chart_text(title_el)
        tc_xml = title_el.find(f".//{{{A_NS}}}rPr")
        if tc_xml is None:
            tc_xml = title_el.find(f".//{{{A_NS}}}defRPr")
        title_color = resolve_color(None, xml_el=tc_xml, theme_dict=theme_colors, default=title_color)

    cat_ax = plot_area.find(f"{{{C_NS}}}catAx")
    val_axes = plot_area.findall(f"{{{C_NS}}}valAx")
    x_ax = cat_ax
    y_ax = val_axes[0] if val_axes else None
    if cat_ax is None and len(val_axes) >= 2:
        for ax in val_axes:
            pos = ax.find(f"{{{C_NS}}}axPos")
            pval = pos.attrib.get("val", "") if pos is not None else ""
            if pval in ("b", "t"):
                x_ax = ax
            elif pval in ("l", "r"):
                y_ax = ax
        if x_ax is None:
            x_ax, y_ax = val_axes[0], val_axes[1]

    show_x = x_ax is not None and not _bool_attr(x_ax.find(f"{{{C_NS}}}delete"), default=False)
    show_y = y_ax is not None and not _bool_attr(y_ax.find(f"{{{C_NS}}}delete"), default=False)
    x_title = _extract_chart_text(x_ax.find(f"{{{C_NS}}}title")) if show_x else ""
    y_title = _extract_chart_text(y_ax.find(f"{{{C_NS}}}title")) if show_y else ""

    legend_el = chart_el.find(f"{{{C_NS}}}legend")
    has_legend = legend_el is not None
    leg_pos = "b"
    if legend_el is not None:
        lp = legend_el.find(f"{{{C_NS}}}legendPos")
        if lp is not None and "val" in lp.attrib:
            leg_pos = lp.attrib["val"]

    pad_l = int(round(((54 if show_y else 10) + (16 if y_title else 0)) * s_px))
    pad_r = int(round(16 * s_px))
    pad_t = int(round(((32 if title_text else 12) + (16 if (has_legend and leg_pos == "t") else 0)) * s_px))
    pad_b = int(round(((28 if show_x else 10) + (16 if x_title else 0) + (20 if (has_legend and leg_pos == "b") else 0)) * s_px))

    px0, py0 = pad_l, pad_t
    px1, py1 = max(px0 + 20, cw - pad_r), max(py0 + 20, ch - pad_b)

    line_chart = plot_area.find(f"{{{C_NS}}}lineChart")
    scatter_chart = plot_area.find(f"{{{C_NS}}}scatterChart")
    bar_chart = plot_area.find(f"{{{C_NS}}}barChart")
    area_chart = plot_area.find(f"{{{C_NS}}}areaChart")
    pie_chart = plot_area.find(f"{{{C_NS}}}pieChart")
    if pie_chart is None:
        pie_chart = plot_area.find(f"{{{C_NS}}}doughnutChart")
    # Collect ALL chart type nodes for combo-chart support (multiple <c:lineChart> etc.)
    _all_line_charts    = plot_area.findall(f"{{{C_NS}}}lineChart")
    _all_scatter_charts = plot_area.findall(f"{{{C_NS}}}scatterChart")
    _all_bar_charts     = plot_area.findall(f"{{{C_NS}}}barChart")
    _all_area_charts    = plot_area.findall(f"{{{C_NS}}}areaChart")

    fallback_palette = [
        theme_colors.get("accent1", (0, 104, 74)),
        theme_colors.get("accent2", (0, 237, 100)),
        theme_colors.get("accent3", (214, 57, 63)),
        theme_colors.get("accent4", (64, 160, 255)),
        theme_colors.get("accent5", (255, 175, 50)),
    ]

    bg_lum = 0.299 * effective_bg[0] + 0.587 * effective_bg[1] + 0.114 * effective_bg[2]
    axis_default = (160, 175, 185) if bg_lum < 128 else (120, 130, 140)
    grid_default = (45, 65, 78) if bg_lum < 128 else (215, 226, 220)
    lbl_default = (200, 215, 225) if bg_lum < 128 else (85, 105, 118)
    font_tick = _get_pil_font(10 * s_px, bold=False)
    font_title = _get_pil_font(13 * s_px, bold=True)

    # Optional plotArea background fill
    pa_bg = _parse_spPr_fill(plot_area.find(f"{{{C_NS}}}spPr"), theme_colors, default_color=None)
    if pa_bg is not None:
        draw.rectangle([px0, py0, px1, py1], fill=pa_bg + (255,))

    if pie_chart is not None:
        ser = pie_chart.find(f"{{{C_NS}}}ser")
        vmap = _extract_chart_num_map(ser.find(f"{{{C_NS}}}val")) if ser is not None else {}
        vals = [vmap[k] for k in sorted(vmap)]
        total = sum(max(0.0, v) for v in vals) or 1.0
        cx_p, cy_p = cw // 2, (py0 + py1) // 2
        rad = min(px1 - px0, py1 - py0) // 2 - int(round(6 * s_px))
        start_deg = -90.0
        for idx, v in enumerate(vals):
            sweep = (max(0.0, v) / total) * 360.0
            col = fallback_palette[idx % len(fallback_palette)]
            draw.pieslice([cx_p - rad, cy_p - rad, cx_p + rad, cy_p + rad], start=start_deg, end=start_deg + sweep, fill=col + (255,), outline=canvas_bg if cs_bg else (255, 255, 255, 255), width=max(1, int(round(s_px))))
            start_deg += sweep
    else:
        chart_node = scatter_chart if scatter_chart is not None else (line_chart if line_chart is not None else (area_chart if area_chart is not None else bar_chart))
        if chart_node is None:
            img.close()
            return None

        # For combo charts (e.g. 5 separate <c:lineChart> elements each with 1 series),
        # collect ser elements from ALL matching chart-type nodes in Z-order.
        if scatter_chart is not None:
            _combo_nodes = _all_scatter_charts
        elif line_chart is not None:
            _combo_nodes = _all_line_charts
        elif area_chart is not None:
            _combo_nodes = _all_area_charts
        else:
            _combo_nodes = _all_bar_charts

        ser_list = []
        cat_map = {}
        cat_total_count = 0
        all_x, all_y = [], []

        _global_ser_idx = 0
        for _cnode in _combo_nodes:
            for ser in _cnode.findall(f"{{{C_NS}}}ser"):
                idx = _global_ser_idx
                _global_ser_idx += 1
                def_col = fallback_palette[idx % len(fallback_palette)]
                spPr = ser.find(f"{{{C_NS}}}spPr")
                ln_col, ln_w_pt, no_ln, ln_dash = _parse_spPr_stroke(spPr, theme_colors, default_color=def_col, default_w_pt=2.5)
                fill_col = _parse_spPr_fill(spPr, theme_colors, default_color=ln_col or def_col)

                mk_el = ser.find(f"{{{C_NS}}}marker")
                mk_sym = "none"
                mk_size = 7
                mk_col = ln_col or fill_col or def_col
                mk_stroke = None
                if mk_el is not None:
                    sym_el = mk_el.find(f"{{{C_NS}}}symbol")
                    if sym_el is not None:
                        mk_sym = sym_el.attrib.get("val", "circle")
                    sz_el = mk_el.find(f"{{{C_NS}}}size")
                    if sz_el is not None:
                        try:
                            mk_size = int(sz_el.attrib["val"])
                        except Exception:
                            pass
                    mk_spPr = mk_el.find(f"{{{C_NS}}}spPr")
                    if mk_spPr is not None:
                        mc = _parse_spPr_fill(mk_spPr, theme_colors, default_color=None)
                        ms, _, ms_no, _ = _parse_spPr_stroke(mk_spPr, theme_colors, default_color=None)
                        if mc is not None:
                            mk_col = mc
                        elif ms is not None and not ms_no:
                            mk_col = ms
                        if ms is not None and not ms_no:
                            mk_stroke = ms + (255,)
                elif getattr(chart_shape.chart, "chart_type", None) and "MARKERS" in str(chart_shape.chart.chart_type):
                    mk_sym = "circle"

                ser_name = _extract_chart_text(ser.find(f"{{{C_NS}}}tx"))

                if scatter_chart is not None:
                    x_map = _extract_chart_num_map(ser.find(f"{{{C_NS}}}xVal"))
                    y_map = _extract_chart_num_map(ser.find(f"{{{C_NS}}}yVal"))
                    common_keys = sorted(set(x_map.keys()) & set(y_map.keys()))
                    pts = [(x_map[k], y_map[k]) for k in common_keys]
                    all_x.extend(p[0] for p in pts)
                    all_y.extend(p[1] for p in pts)
                else:
                    cmap, cnt = _extract_chart_str_map(ser.find(f"{{{C_NS}}}cat"))
                    if cmap and not cat_map:
                        cat_map = cmap
                        cat_total_count = max(cat_total_count, cnt)
                    v_map = _extract_chart_num_map(ser.find(f"{{{C_NS}}}val"))
                    pts = [(k, v_map[k]) for k in sorted(v_map.keys())]
                    if pts:
                        cat_total_count = max(cat_total_count, max(k for k, _ in pts) + 1)
                    all_x.extend(p[0] for p in pts)
                    all_y.extend(p[1] for p in pts)

                ser_list.append({
                    "name": ser_name,
                    "pts": pts,
                    "line_col": None if no_ln else ln_col,
                    "line_w": ln_w_pt,
                    "line_dash": ln_dash,
                    "fill_col": fill_col,
                    "mk_sym": mk_sym,
                    "mk_size": mk_size,
                    "mk_col": mk_col,
                    "mk_stroke": mk_stroke,
                })

        if not all_y:
            img.close()
            return None

        def _axis_bounds(ax_el, vals):
            amin, amax = min(vals), max(vals)
            if ax_el is not None:
                sc = ax_el.find(f"{{{C_NS}}}scaling")
                if sc is not None:
                    mn = sc.find(f"{{{C_NS}}}min")
                    mx = sc.find(f"{{{C_NS}}}max")
                    if mn is not None and "val" in mn.attrib:
                        amin = float(mn.attrib["val"])
                    if mx is not None and "val" in mx.attrib:
                        amax = float(mx.attrib["val"])
            if abs(amax - amin) < 1e-9:
                amin -= 1.0
                amax += 1.0
            return amin, amax

        is_horiz_bar = False
        if bar_chart is not None:
            bdir = bar_chart.find(f"{{{C_NS}}}barDir")
            if bdir is not None and bdir.attrib.get("val") == "bar":
                is_horiz_bar = True

        ymin, ymax = _axis_bounds(y_ax, all_y)
        if bar_chart is not None and ymin > 0:
            ymin = 0.0
        if scatter_chart is not None:
            xmin, xmax = _axis_bounds(x_ax, all_x)
        else:
            xmin, xmax = 0.0, float(max(1, cat_total_count - 1))

        y_unit = None
        if y_ax is not None:
            mu = y_ax.find(f"{{{C_NS}}}majorUnit")
            if mu is not None and "val" in mu.attrib:
                try:
                    y_unit = float(mu.attrib["val"])
                except Exception:
                    pass
        y_ticks = _nice_ticks(ymin, ymax, count=5, fixed_step=y_unit)

        if show_y and not is_horiz_bar:
            mg = y_ax.find(f"{{{C_NS}}}majorGridlines")
            if mg is not None:
                gcol, gw, gno, gdash = _parse_spPr_stroke(mg.find(f"{{{C_NS}}}spPr"), theme_colors, default_color=grid_default, default_w_pt=0.75)
                if gcol and not gno:
                    for yv in y_ticks:
                        yy = py1 - int(round((yv - ymin) / (ymax - ymin) * (py1 - py0)))
                        _draw_dashed_line(draw, [(px0, yy), (px1, yy)], gcol + (255,), max(1, int(round(gw * s_px))), dash=gdash)

        if not is_horiz_bar:
            if show_x:
                xcol, xw, xno, _ = _parse_spPr_stroke(x_ax.find(f"{{{C_NS}}}spPr"), theme_colors, default_color=axis_default, default_w_pt=1.0)
                if xcol and not xno:
                    draw.line([(px0, py1), (px1, py1)], fill=xcol + (255,), width=max(ss, int(round(xw * s_px))))
                if scatter_chart is not None:
                    for xv in _nice_ticks(xmin, xmax, count=5):
                        xx = px0 + int(round((xv - xmin) / (xmax - xmin) * (px1 - px0)))
                        draw.line([(xx, py1), (xx, py1 + int(round(4 * s_px)))], fill=(xcol or axis_default) + (255,), width=max(1, int(round(s_px))))
                        if font_tick:
                            draw.text((xx, py1 + int(round(6 * s_px))), _fmt_num(xv), fill=lbl_default + (255,), font=font_tick, anchor="ma")
                elif cat_map:
                    non_empty = [(ci, lbl) for ci, lbl in sorted(cat_map.items()) if lbl]
                    last_tick_px = -1e9
                    for ci, lbl in non_empty:
                        xx = px0 + int(round((ci - xmin) / max(xmax - xmin, 1.0) * (px1 - px0)))
                        if xx - last_tick_px >= 28 * s_px:
                            draw.line([(xx, py1), (xx, py1 + int(round(4 * s_px)))], fill=(xcol or axis_default) + (255,), width=max(1, int(round(s_px))))
                            if font_tick:
                                draw.text((xx, py1 + int(round(6 * s_px))), lbl, fill=lbl_default + (255,), font=font_tick, anchor="ma")
                            last_tick_px = xx
                if x_title and font_tick:
                    xt_y = (py1 + int(round(22 * s_px))) if (has_legend and leg_pos == "b") else (ch - int(round(4 * s_px)))
                    draw.text(((px0 + px1) // 2, xt_y), x_title, fill=lbl_default + (255,), font=font_tick, anchor="ma" if (has_legend and leg_pos == "b") else "mb")

            if show_y:
                ycol, yw, yno, _ = _parse_spPr_stroke(y_ax.find(f"{{{C_NS}}}spPr"), theme_colors, default_color=axis_default, default_w_pt=1.0)
                if ycol and not yno:
                    draw.line([(px0, py0), (px0, py1)], fill=ycol + (255,), width=max(ss, int(round(yw * s_px))))
                for yv in y_ticks:
                    yy = py1 - int(round((yv - ymin) / (ymax - ymin) * (py1 - py0)))
                    draw.line([(px0 - int(round(4 * s_px)), yy), (px0, yy)], fill=(ycol or axis_default) + (255,), width=max(1, int(round(s_px))))
                    if font_tick:
                        draw.text((px0 - int(round(8 * s_px)), yy), _fmt_num(yv), fill=lbl_default + (255,), font=font_tick, anchor="rm")
                if y_title and font_tick:
                    draw.text((int(round(8 * s_px)), (py0 + py1) // 2), y_title, fill=lbl_default + (255,), font=font_tick, anchor="lm")

        def _to_px(vx, vy):
            sx = px0 + (vx - xmin) / max(xmax - xmin, 1e-9) * (px1 - px0)
            sy = py1 - (vy - ymin) / max(ymax - ymin, 1e-9) * (py1 - py0)
            return (sx, sy)

        if bar_chart is not None:
            n_cats = max(1, cat_total_count or len(ser_list[0]["pts"]))
            n_sers = max(1, len(ser_list))
            if is_horiz_bar:
                slot_h = (py1 - py0) / float(n_cats)
                bar_h = max(4 * s_px, (slot_h * 0.72) / n_sers)
                for si, s in enumerate(ser_list):
                    bcol = s["fill_col"] or s["line_col"] or fallback_palette[si % len(fallback_palette)]
                    for ci, yv in s["pts"]:
                        by0 = py0 + ci * slot_h + slot_h * 0.14 + si * bar_h
                        by1 = by0 + bar_h * 0.90
                        bx_end = px0 + (yv - ymin) / max(ymax - ymin, 1e-9) * (px1 - px0)
                        draw.rectangle([px0, by0, max(px0 + 2, bx_end), by1], fill=bcol + (255,))
                        if show_x and cat_map.get(ci) and si == 0 and font_tick:
                            draw.text((px0 - int(round(6 * s_px)), (by0 + by1) / 2), cat_map[ci], fill=lbl_default + (255,), font=font_tick, anchor="rm")
            else:
                slot_w = (px1 - px0) / float(n_cats)
                bar_w = max(4 * s_px, (slot_w * 0.72) / n_sers)
                y_zero = max(py0, min(py1, py1 - (0.0 - ymin) / max(ymax - ymin, 1e-9) * (py1 - py0)))
                for si, s in enumerate(ser_list):
                    bcol = s["fill_col"] or s["line_col"] or fallback_palette[si % len(fallback_palette)]
                    for ci, yv in s["pts"]:
                        bx0 = px0 + ci * slot_w + slot_w * 0.14 + si * bar_w
                        bx1 = bx0 + bar_w * 0.90
                        by = _to_px(ci, yv)[1]
                        draw.rectangle([bx0, min(by, y_zero), bx1, max(by, y_zero)], fill=bcol + (255,))
        else:
            for s in ser_list:
                screen_pts = [_to_px(vx, vy) for vx, vy in s["pts"]]
                if area_chart is not None and len(screen_pts) >= 2:
                    acol = s["fill_col"] or s["line_col"] or fallback_palette[0]
                    poly = [(screen_pts[0][0], py1)] + screen_pts + [(screen_pts[-1][0], py1)]
                    draw.polygon(poly, fill=acol + (140,))
                if s["line_col"] and len(screen_pts) >= 2:
                    smooth_pts = _catmull_rom_points(screen_pts, subdiv=6) if (len(screen_pts) >= 4 and s["line_dash"] == "solid" and scatter_chart is None) else screen_pts
                    lw = max(ss, int(round(s["line_w"] * s_px * 1.1)))
                    _draw_dashed_line(draw, smooth_pts, s["line_col"] + (255,), lw, dash=s["line_dash"])
                if s["mk_sym"] != "none":
                    r_mk = max(int(round(3 * s_px)), int(round((s["mk_size"] or 6) * s_px * 0.50)))
                    for mx, my in screen_pts:
                        _draw_chart_marker(draw, mx, my, r_mk, s["mk_sym"], s["mk_col"] + (255,), stroke_rgba=s["mk_stroke"], stroke_w=max(1, int(round(s_px * 0.5))))

        if title_text and font_title:
            draw.text(((px0 + px1) // 2, int(round(10 * s_px))), title_text, fill=title_color + (255,), font=font_title, anchor="ma")

        if has_legend and font_tick:
            leg_items = [s for s in ser_list[:6] if s["name"]]
            if leg_items:
                est_w = sum(int(round((26 + len(s["name"]) * 6) * s_px)) for s in leg_items)
                lx = max(px0, (px0 + px1 - est_w) // 2)
                ly = (ch - int(round(10 * s_px))) if leg_pos == "b" else (py0 - int(round(14 * s_px)))
                for s in leg_items:
                    lcol = s["mk_col"] if s["mk_sym"] != "none" else (s["line_col"] or fallback_palette[0])
                    if s["mk_sym"] != "none":
                        draw.ellipse([lx, ly - int(round(4 * s_px)), lx + int(round(8 * s_px)), ly + int(round(4 * s_px))], fill=lcol + (255,))
                    else:
                        _draw_dashed_line(draw, [(lx, ly), (lx + int(round(12 * s_px)), ly)], lcol + (255,), max(2, int(round(1.5 * s_px))), dash=s["line_dash"])
                    draw.text((lx + int(round(16 * s_px)), ly), s["name"], fill=lbl_default + (255,), font=font_tick, anchor="lm")
                    lx += int(round((28 + len(s["name"]) * 6) * s_px))

    resized = img.resize((tw, th), Image.Resampling.LANCZOS)
    img.close()
    spans = _encode_rgba_rle(resized)
    resized.close()
    return tw, th, spans


def _find_placeholder_source(slide, ph_type, ph_idx):
    """Locate matching placeholder element on slide_layout or slide_master for inherited styles."""
    layout = getattr(slide, "slide_layout", None)
    master = getattr(layout, "slide_master", None) if layout else None
    matches = []
    for holder in (layout, master):
        if not holder:
            continue
        for sh in holder.shapes:
            if not sh.is_placeholder:
                continue
            try:
                nv = sh._element.find(f".//{{{P_NS}}}ph")
                if nv is None:
                    continue
                t = nv.attrib.get("type", "")
                idx = nv.attrib.get("idx", "")
                if (ph_idx and idx == ph_idx) or (ph_type and t == ph_type):
                    matches.append(sh)
            except Exception:
                pass
    return matches


def _master_txStyle_for_ph(slide, ph_type, level):
    layout = getattr(slide, "slide_layout", None)
    master = getattr(layout, "slide_master", None) if layout else None
    if master is None:
        return None
    txStyles = master._element.find(f"{{{P_NS}}}txStyles")
    if txStyles is None:
        return None
    if ph_type in ("title", "ctrTitle"):
        style_el = txStyles.find(f"{{{P_NS}}}titleStyle")
    elif ph_type in ("body", "subTitle", "obj"):
        style_el = txStyles.find(f"{{{P_NS}}}bodyStyle")
    else:
        style_el = txStyles.find(f"{{{P_NS}}}otherStyle")
    if style_el is None:
        return None
    return style_el.find(f"{{{A_NS}}}lvl{min(9, level + 1)}pPr")


def _extract_rPr_props(rPr_el, theme_colors, theme_fonts):
    if rPr_el is None:
        return {}
    out = {}
    if "sz" in rPr_el.attrib:
        try:
            out["size"] = float(rPr_el.attrib["sz"]) / 100.0
        except Exception:
            pass
    if "b" in rPr_el.attrib:
        out["bold"] = rPr_el.attrib["b"] in ("1", "true", "True")
    if "i" in rPr_el.attrib:
        out["italic"] = rPr_el.attrib["i"] in ("1", "true", "True")
    col = resolve_color(None, xml_el=rPr_el, theme_dict=theme_colors, default=None)
    if col is not None:
        out["color"] = col
    latin = rPr_el.find(f"{{{A_NS}}}latin")
    if latin is not None and latin.attrib.get("typeface"):
        fam = classify_font_family(latin.attrib["typeface"], theme_fonts)
        if fam:
            out["font"] = fam
    return out


def _extract_para_spacing_pt(pPr, tag_name, pt_size):
    if pPr is None:
        return None
    el = pPr.find(f"{{{A_NS}}}{tag_name}")
    if el is None:
        return None
    pts = el.find(f"{{{A_NS}}}spcPts")
    if pts is not None and "val" in pts.attrib:
        try:
            return round(float(pts.attrib["val"]) / 100.0, 1)
        except Exception:
            pass
    pct = el.find(f"{{{A_NS}}}spcPct")
    if pct is not None and "val" in pct.attrib:
        try:
            return round(pt_size * (float(pct.attrib["val"]) / 100000.0), 1)
        except Exception:
            pass
    return None


def extract_paragraphs(shape, slide, theme_colors, theme_fonts, default_color):
    """Extract paragraphs/runs resolving full placeholder + theme inheritance."""
    tf = shape.text_frame
    ph_type, ph_idx = None, None
    try:
        ph_el = shape._element.find(f".//{{{P_NS}}}ph")
        if ph_el is not None:
            ph_type = ph_el.attrib.get("type")
            ph_idx = ph_el.attrib.get("idx")
    except Exception:
        pass

    ph_sources = _find_placeholder_source(slide, ph_type, ph_idx) if (ph_type or ph_idx) else []
    default_ph_family = "serif" if ph_type in ("title", "ctrTitle") and classify_font_family(theme_fonts.get("major"), theme_fonts) == "serif" else classify_font_family(theme_fonts.get("minor"), theme_fonts) or "sans"

    paras = []
    text_lines = []
    for p in tf.paragraphs:
        p_text = p.text
        if not p_text or not p_text.strip():
            continue

        text_lines.append(p_text.strip())
        level = p.level or 0
        pPr = p._p.find(f"{{{A_NS}}}pPr")

        # Build inheritance chain for paragraph-level defaults (lowest priority -> highest)
        inherited = {"size": 18.0, "bold": False, "italic": False, "color": None, "font": default_ph_family}
        m_lvl_pPr = _master_txStyle_for_ph(slide, ph_type, level)
        if m_lvl_pPr is not None:
            inherited.update({k: v for k, v in _extract_rPr_props(m_lvl_pPr.find(f"{{{A_NS}}}defRPr"), theme_colors, theme_fonts).items() if v is not None})
        for src in reversed(ph_sources):
            lstStyle = src._element.find(f".//{{{A_NS}}}txBody/{{{A_NS}}}lstStyle/{{{A_NS}}}lvl{min(9, level + 1)}pPr")
            if lstStyle is not None:
                inherited.update({k: v for k, v in _extract_rPr_props(lstStyle.find(f"{{{A_NS}}}defRPr"), theme_colors, theme_fonts).items() if v is not None})
        if pPr is not None:
            inherited.update({k: v for k, v in _extract_rPr_props(pPr.find(f"{{{A_NS}}}defRPr"), theme_colors, theme_fonts).items() if v is not None})

        pt_size = inherited["size"]
        is_bold = inherited["bold"]
        is_italic = inherited["italic"]
        p_color = inherited["color"]
        p_font = inherited["font"]

        try:
            if p.font and p.font.size:
                pt_size = p.font.size.pt
            elif p.runs and p.runs[0].font and p.runs[0].font.size:
                pt_size = p.runs[0].font.size.pt
        except Exception:
            pass
        try:
            if p.font and p.font.bold is not None:
                is_bold = p.font.bold
            elif p.runs and p.runs[0].font and p.runs[0].font.bold is not None:
                is_bold = p.runs[0].font.bold
        except Exception:
            pass
        try:
            if p.font and p.font.italic is not None:
                is_italic = p.font.italic
            elif p.runs and p.runs[0].font and p.runs[0].font.italic is not None:
                is_italic = p.runs[0].font.italic
        except Exception:
            pass

        runs_data = []
        first_explicit_run_color = None
        for r in p.runs:
            r_text = r.text
            if not r_text:
                continue
            rPr = r._r.find(f"{{{A_NS}}}rPr")
            rp = _extract_rPr_props(rPr, theme_colors, theme_fonts)
            r_size = rp.get("size", pt_size)
            r_bold = rp.get("bold", is_bold)
            r_italic = rp.get("italic", is_italic)
            r_font = rp.get("font", p_font)
            r_color = rp.get("color") or resolve_color(r.font.color, xml_el=rPr, theme_dict=theme_colors, default=None)
            if r_color is not None and first_explicit_run_color is None:
                first_explicit_run_color = r_color
            runs_data.append({
                "text": r_text,
                "size": round(r_size, 1),
                "bold": bool(r_bold),
                "italic": bool(r_italic),
                "color": r_color,
                "font": r_font,
            })

        effective_p_color = first_explicit_run_color or p_color or default_color
        if runs_data and runs_data[0].get("font"):
            p_font = runs_data[0]["font"]
        for r_item in runs_data:
            if r_item["color"] is None:
                r_item["color"] = effective_p_color

        align = "left"
        if p.alignment == PP_ALIGN.CENTER:
            align = "center"
        elif p.alignment == PP_ALIGN.RIGHT:
            align = "right"
        elif pPr is not None and pPr.attrib.get("algn"):
            al = pPr.attrib["algn"]
            if al == "ctr":
                align = "center"
            elif al == "r":
                align = "right"

        bu_none = pPr is not None and pPr.find(f"{{{A_NS}}}buNone") is not None
        bu_explicit = pPr is not None and (
            pPr.find(f"{{{A_NS}}}buChar") is not None or pPr.find(f"{{{A_NS}}}buAutoNum") is not None
        )
        final_text = p_text.strip()
        already_bulleted = final_text.startswith("•") or final_text.startswith("- ")
        has_bullet = already_bulleted or ((not bu_none) and (bu_explicit or level > 0))
        if has_bullet and not already_bulleted:
            final_text = "• " + final_text
            if runs_data:
                runs_data[0]["text"] = "• " + runs_data[0]["text"]

        spc_bef = _extract_para_spacing_pt(pPr, "spcBef", pt_size) or 0.0
        spc_aft = _extract_para_spacing_pt(pPr, "spcAft", pt_size)

        paras.append({
            "text": final_text,
            "size": round(pt_size, 1),
            "bold": bool(is_bold),
            "italic": bool(is_italic),
            "color": effective_p_color,
            "align": align,
            "level": level,
            "bullet": has_bullet,
            "font": p_font,
            "space_before": spc_bef,
            "space_after": spc_aft,
            "runs": runs_data,
        })

    return paras, text_lines


def _extract_shape_recursive(shape, slide, sw, sh, theme_colors, theme_fonts, layers, text_blocks, full_text_lines, default_text_color, ox=0.0, oy=0.0, sx=1.0, sy=1.0, bg_tracker=None):
    """Extract a shape (or grouped shape hierarchy) preserving true Z-order."""
    # Group shapes
    if MSO_SHAPE_TYPE and shape.shape_type == MSO_SHAPE_TYPE.GROUP:
        try:
            xfrm = shape._element.find(f".//{{{P_NS}}}grpSpPr/{{{A_NS}}}xfrm")
            g_off_x, g_off_y = shape.left, shape.top
            g_ext_x, g_ext_y = max(1, shape.width), max(1, shape.height)
            ch_off_x, ch_off_y, ch_ext_x, ch_ext_y = 0, 0, g_ext_x, g_ext_y
            if xfrm is not None:
                chOff = xfrm.find(f"{{{A_NS}}}chOff")
                chExt = xfrm.find(f"{{{A_NS}}}chExt")
                if chOff is not None:
                    ch_off_x = float(chOff.attrib.get("x", 0))
                    ch_off_y = float(chOff.attrib.get("y", 0))
                if chExt is not None:
                    ch_ext_x = max(1.0, float(chExt.attrib.get("cx", g_ext_x)))
                    ch_ext_y = max(1.0, float(chExt.attrib.get("cy", g_ext_y)))
            sub_sx = sx * (g_ext_x / ch_ext_x)
            sub_sy = sy * (g_ext_y / ch_ext_y)
            sub_ox = ox + g_off_x * sx - ch_off_x * sub_sx
            sub_oy = oy + g_off_y * sy - ch_off_y * sub_sy
            for child in shape.shapes:
                _extract_shape_recursive(
                    child, slide, sw, sh, theme_colors, theme_fonts,
                    layers, text_blocks, full_text_lines, default_text_color,
                    ox=sub_ox, oy=sub_oy, sx=sub_sx, sy=sub_sy, bg_tracker=bg_tracker,
                )
        except Exception:
            pass
        return

    try:
        left_emu = ox + (shape.left or 0) * sx
        top_emu = oy + (shape.top or 0) * sy
        w_emu = max(12700, (shape.width or 0) * sx)
        h_emu = max(12700, (shape.height or 0) * sy)

        nx = max(0.0, min(1.0, left_emu / sw))
        ny = max(0.0, min(1.0, top_emu / sh))
        nw = max(0.002, min(1.0 - nx + 0.002, w_emu / sw))
        nh = max(0.002, min(1.0 - ny + 0.002, h_emu / sh))

        # Inspect geometry, transform (flip/rotate), fill, and stroke directly from spPr
        spPr = shape._element.find(f"{{{P_NS}}}spPr") if hasattr(shape, "_element") else None
        if spPr is None and hasattr(shape, "_element"):
            spPr = shape._element.find("{http://schemas.microsoft.com/office/drawing/2008/diagram}spPr")
        geom = "rect"
        prst_av = {}
        cust_geom_el = None
        flip_h, flip_v, rot_deg = False, False, 0.0
        if spPr is not None:
            prst_el = spPr.find(f"{{{A_NS}}}prstGeom")
            if prst_el is not None and prst_el.attrib.get("prst"):
                geom = prst_el.attrib["prst"]
                for gd in prst_el.findall(f".//{{{A_NS}}}gd"):
                    if "name" in gd.attrib and "fmla" in gd.attrib and gd.attrib["fmla"].startswith("val "):
                        try:
                            prst_av[gd.attrib["name"]] = float(gd.attrib["fmla"].split()[1])
                        except Exception:
                            pass
            else:
                cust_geom_el = spPr.find(f"{{{A_NS}}}custGeom")
                if cust_geom_el is not None:
                    geom = "custGeom"
            xfrm = spPr.find(f"{{{A_NS}}}xfrm")
            if xfrm is not None:
                flip_h = xfrm.attrib.get("flipH") == "1"
                flip_v = xfrm.attrib.get("flipV") == "1"
                if "rot" in xfrm.attrib:
                    try:
                        rot_deg = float(xfrm.attrib["rot"]) / 60000.0
                    except Exception:
                        pass

        fill_color = None
        if spPr is not None:
            if spPr.find(f"{{{A_NS}}}noFill") is None:
                fill_color = _resolve_fill_element(spPr.find(f"{{{A_NS}}}solidFill"), theme_colors)
                if fill_color is None:
                    fill_color = _resolve_grad_first_color(spPr.find(f"{{{A_NS}}}gradFill"), theme_colors)
        elif hasattr(shape, "fill") and shape.fill and shape.fill.type == 1:
            fill_color = resolve_color(shape.fill.fore_color, theme_dict=theme_colors, default=None)

        # Track full-bleed background shape (e.g. Google Slides dark layout rect)
        if fill_color and nx <= 0.02 and ny <= 0.02 and nw >= 0.96 and nh >= 0.96 and bg_tracker is not None:
            bg_tracker[0] = fill_color

        border_color = None
        border_w = 1
        if spPr is not None:
            ln_el = spPr.find(f"{{{A_NS}}}ln")
            if ln_el is not None and ln_el.find(f"{{{A_NS}}}noFill") is None:
                border_color = _resolve_fill_element(ln_el.find(f"{{{A_NS}}}solidFill"), theme_colors)
                if border_color is not None and "w" in ln_el.attrib:
                    try:
                        border_w = max(1, int(round(float(ln_el.attrib["w"]) / EMU_PER_PT)))
                    except Exception:
                        pass

        # Avoid double border if border equals solid fill
        if border_color == fill_color:
            border_color = None

        # Charts (p:graphicFrame -> c:chart)
        if getattr(shape, "has_chart", False):
            eff_bg = bg_tracker[0] if bg_tracker else (255, 255, 255)
            rendered = render_chart_to_rgba_rle(shape, nw, nh, theme_colors, eff_bg)
            if rendered:
                tw, th, spans = rendered
                layers.append({
                    "kind": "image",
                    "x": round(nx, 4), "y": round(ny, 4), "w": round(nw, 4), "h": round(nh, 4),
                    "tw": tw, "th": th, "spans": spans,
                })
            return

        # SmartArt / DrawingML Diagrams (p:graphicFrame -> dgm:relIds -> ppt/diagrams/drawing*.xml)
        if hasattr(shape, "_element"):
            gdata = shape._element.find(f".//{{{A_NS}}}graphicData")
            if gdata is not None and "diagram" in (gdata.attrib.get("uri", "").lower()):
                try:
                    DSP_NS = "http://schemas.microsoft.com/office/drawing/2008/diagram"
                    drawing_part = None
                    dm_partname = None
                    rel_ids = gdata.find(".//{http://schemas.openxmlformats.org/drawingml/2006/diagram}relIds")
                    if rel_ids is not None:
                        dm_rid = rel_ids.attrib.get(f"{{{R_NS}}}dm")
                        if dm_rid and dm_rid in slide.part.rels:
                            dm_partname = str(slide.part.rels[dm_rid].target_part.partname)
                    expected_draw = dm_partname.replace("data", "drawing") if dm_partname else None
                    for rel in slide.part.rels.values():
                        tname = str(rel.target_part.partname) if hasattr(rel, "target_part") else ""
                        if expected_draw and tname == expected_draw:
                            drawing_part = rel.target_part
                            break
                        if drawing_part is None and ("diagramDrawing" in rel.reltype or "diagrams/drawing" in str(rel.target_ref)):
                            drawing_part = rel.target_part
                    if drawing_part is None and hasattr(slide.part, "package"):
                        for part in slide.part.package.iter_parts():
                            pname = str(part.partname)
                            if expected_draw and pname == expected_draw:
                                drawing_part = part
                                break
                            if drawing_part is None and "diagrams/drawing" in pname:
                                drawing_part = part
                    if drawing_part is not None:
                        droot = ET.fromstring(drawing_part.blob)
                        spTree = droot.find(f".//{{{DSP_NS}}}spTree")
                        if spTree is not None:
                            for dsp_sp in spTree.findall(f"{{{DSP_NS}}}sp"):
                                d_spPr = dsp_sp.find(f"{{{DSP_NS}}}spPr")
                                d_txBody = dsp_sp.find(f"{{{DSP_NS}}}txBody")
                                if d_spPr is None:
                                    continue
                                d_xfrm = d_spPr.find(f"{{{A_NS}}}xfrm")
                                if d_xfrm is None:
                                    continue
                                d_off = d_xfrm.find(f"{{{A_NS}}}off")
                                d_ext = d_xfrm.find(f"{{{A_NS}}}ext")
                                if d_off is None or d_ext is None:
                                    continue
                                dx = float(d_off.attrib.get("x", 0))
                                dy = float(d_off.attrib.get("y", 0))
                                dw = max(12700.0, float(d_ext.attrib.get("cx", 0)))
                                dh = max(12700.0, float(d_ext.attrib.get("cy", 0)))
                                # Coordinates in drawing*.xml can be local to graphicFrame or full-slide EMU
                                ax = (left_emu + dx * sx) if (dx + dw <= w_emu * 1.1 and dx < left_emu) else (ox + dx * sx)
                                ay = (top_emu + dy * sy) if (dy + dh <= h_emu * 1.1 and dy < top_emu) else (oy + dy * sy)
                                dnx = max(0.0, min(1.0, ax / sw))
                                dny = max(0.0, min(1.0, ay / sh))
                                dnw = max(0.002, min(1.0 - dnx + 0.002, (dw * sx) / sw))
                                dnh = max(0.002, min(1.0 - dny + 0.002, (dh * sy) / sh))

                                d_geom = "rect"
                                d_av = {}
                                d_prst = d_spPr.find(f"{{{A_NS}}}prstGeom")
                                if d_prst is not None and d_prst.attrib.get("prst"):
                                    d_geom = d_prst.attrib["prst"]
                                d_fill = _resolve_fill_element(d_spPr.find(f"{{{A_NS}}}solidFill"), theme_colors)
                                d_ln = d_spPr.find(f"{{{A_NS}}}ln")
                                d_bcol = _resolve_fill_element(d_ln.find(f"{{{A_NS}}}solidFill"), theme_colors) if (d_ln is not None and d_ln.find(f"{{{A_NS}}}noFill") is None) else None
                                if d_fill or d_bcol:
                                    rend = _render_vector_shape_spans(d_geom, d_fill, d_bcol, 1, dnw, dnh, d_av, False, False) if d_geom != "rect" else None
                                    if rend:
                                        rtw, rth, rsp = rend
                                        layers.append({"kind": "image", "x": round(dnx, 4), "y": round(dny, 4), "w": round(dnw, 4), "h": round(dnh, 4), "tw": rtw, "th": rth, "spans": rsp})
                                    else:
                                        layers.append({"kind": "shape", "x": round(dnx, 4), "y": round(dny, 4), "w": round(dnw, 4), "h": round(dnh, 4), "fill": d_fill, "border": d_bcol, "border_w": 1})
                                if d_txBody is not None:
                                    d_paras = []
                                    for dp in d_txBody.findall(f"{{{A_NS}}}p"):
                                        txt_runs = [t.text for t in dp.iter(f"{{{A_NS}}}t") if t.text]
                                        full_dp = "".join(txt_runs).strip()
                                        if not full_dp:
                                            continue
                                        full_text_lines.append(full_dp)
                                        rpr = dp.find(f".//{{{A_NS}}}rPr")
                                        d_col = resolve_color(None, xml_el=rpr, theme_dict=theme_colors, default=(255, 255, 255) if (d_fill and (0.299*d_fill[0]+0.587*d_fill[1]+0.114*d_fill[2]) < 128) else (20, 24, 30))
                                        d_sz = float(rpr.attrib.get("sz", 1200)) / 100.0 if (rpr is not None and "sz" in rpr.attrib) else 12.0
                                        d_bold = (rpr.attrib.get("b") in ("1", "true")) if rpr is not None else False
                                        d_paras.append({"text": full_dp, "size": d_sz, "bold": d_bold, "italic": False, "color": d_col, "align": "center", "level": 0, "bullet": False, "font": "sans", "runs": []})
                                    if d_paras:
                                        text_blocks.append({"x": round(dnx, 4), "y": round(dny, 4), "w": round(dnw, 4), "h": round(dnh, 4), "anchor": "ctr", "ins_l": 0.004, "ins_t": 0.002, "ins_r": 0.004, "ins_b": 0.002, "paragraphs": d_paras})
                except Exception:
                    pass
                return

        # Vector shapes: plain unrotated rects stay fast native rects; curved/arrow/line/rotated/custGeom use AA RGBA spans
        if fill_color or border_color:
            if geom != "rect" or abs(rot_deg) > 0.5:
                rendered = _render_vector_shape_spans(geom, fill_color, border_color, border_w, nw, nh, prst_av, flip_h, flip_v, rot_deg=rot_deg, cust_geom_el=cust_geom_el)
                if rendered:
                    tw, th, spans = rendered
                    layers.append({
                        "kind": "image",
                        "x": round(nx, 4), "y": round(ny, 4), "w": round(nw, 4), "h": round(nh, 4),
                        "tw": tw, "th": th, "spans": spans,
                    })
                else:
                    layers.append({
                        "kind": "shape",
                        "x": round(nx, 4), "y": round(ny, 4), "w": round(nw, 4), "h": round(nh, 4),
                        "fill": fill_color, "border": border_color, "border_w": border_w,
                    })
            else:
                layers.append({
                    "kind": "shape",
                    "x": round(nx, 4), "y": round(ny, 4), "w": round(nw, 4), "h": round(nh, 4),
                    "fill": fill_color, "border": border_color, "border_w": border_w,
                })

        # Embedded Pictures & Shape blipFills (handles PNG/JPEG/RGBA/SVG, srcRect crop, flipH/flipV, rot)
        pic_blob = None
        if (MSO_SHAPE_TYPE and shape.shape_type == MSO_SHAPE_TYPE.PICTURE) or hasattr(shape, "image"):
            try:
                pic_blob = shape.image.blob
            except Exception:
                pic_blob = None
        if pic_blob is None and spPr is not None and spPr.find(f"{{{A_NS}}}blipFill") is not None:
            try:
                blip_el = spPr.find(f".//{{{A_NS}}}blip")
                if blip_el is not None:
                    rid = blip_el.attrib.get(f"{{{R_NS}}}embed")
                    if rid and rid in slide.part.rels:
                        pic_blob = slide.part.rels[rid].target_part.blob
            except Exception:
                pic_blob = None
        if pic_blob is None and hasattr(shape, "_element"):
            try:
                svg_el = shape._element.find(".//{http://schemas.microsoft.com/office/drawing/2016/SVG/main}svgBlip")
                if svg_el is not None:
                    srid = svg_el.attrib.get(f"{{{R_NS}}}embed")
                    if srid and srid in slide.part.rels:
                        pic_blob = slide.part.rels[srid].target_part.blob
            except Exception:
                pic_blob = None

        if pic_blob and Image:
            try:
                thumb_w = min(900, max(64, int(round(nw * 1280))))
                thumb_h_est = max(48, int(round(nh * 720)))
                pil_img = None

                # Check for SVG blob or svgBlip extension when raster fallback fails
                is_svg = pic_blob.lstrip()[:16].lower().startswith((b"<svg", b"<?xml"))
                if is_svg:
                    pil_img = _render_svg_to_rgba(pic_blob, thumb_w, thumb_h_est)
                else:
                    try:
                        pil_img = Image.open(io.BytesIO(pic_blob)).convert("RGBA")
                    except Exception:
                        # Fallback to <asvg:svgBlip r:embed="..."/> if raster failed
                        svg_el = shape._element.find(".//{http://schemas.microsoft.com/office/drawing/2016/SVG/main}svgBlip") if hasattr(shape, "_element") else None
                        if svg_el is not None:
                            srid = svg_el.attrib.get(f"{{{R_NS}}}embed")
                            if srid and srid in slide.part.rels:
                                pil_img = _render_svg_to_rgba(slide.part.rels[srid].target_part.blob, thumb_w, thumb_h_est)

                if pil_img is not None:
                    # Apply <a:srcRect l="" t="" r="" b=""/> image crop if present
                    bf = shape._element.find(f".//{{{A_NS}}}blipFill") if hasattr(shape, "_element") else None
                    if bf is None and hasattr(shape, "_element"):
                        bf = shape._element.find(f"{{{P_NS}}}blipFill")
                    if bf is not None:
                        src_rect = bf.find(f"{{{A_NS}}}srcRect")
                        if src_rect is not None:
                            cl = float(src_rect.attrib.get("l", 0)) / 100000.0
                            ct = float(src_rect.attrib.get("t", 0)) / 100000.0
                            cr = float(src_rect.attrib.get("r", 0)) / 100000.0
                            cb = float(src_rect.attrib.get("b", 0)) / 100000.0
                            if cl > 0 or ct > 0 or cr > 0 or cb > 0:
                                iw, ih = pil_img.size
                                x0_c = max(0, int(round(iw * cl)))
                                y0_c = max(0, int(round(ih * ct)))
                                x1_c = max(x0_c + 1, int(round(iw * (1.0 - cr))))
                                y1_c = max(y0_c + 1, int(round(ih * (1.0 - cb))))
                                pil_img = pil_img.crop((x0_c, y0_c, x1_c, y1_c))

                    pil_img = _apply_rot_flip(pil_img, rot_deg=rot_deg, flip_h=flip_h, flip_v=flip_v)
                    thumb_h = max(24, int(round(thumb_w * (pil_img.height / max(pil_img.width, 1)))))
                    resized = pil_img.resize((thumb_w, thumb_h), Image.Resampling.LANCZOS)
                    pil_img.close()
                    spans = _encode_rgba_rle(resized)
                    resized.close()
                    layers.append({
                        "kind": "image",
                        "x": round(nx, 4), "y": round(ny, 4), "w": round(nw, 4), "h": round(nh, 4),
                        "tw": thumb_w, "th": thumb_h, "spans": spans,
                    })
            except Exception:
                pass

        # Tables (true col widths, true row heights, direct <a:tcPr> fill/borders, merged cells)
        if getattr(shape, "has_table", False):
            table = shape.table
            n_rows = len(table.rows)
            n_cols = len(table.columns)
            if n_rows > 0 and n_cols > 0:
                raw_cw = [max(0.0, float(c.width or 0)) for c in table.columns]
                sum_cw = sum(raw_cw)
                if sum_cw > 0:
                    col_ws = [w / sw for w in raw_cw]
                else:
                    col_ws = [nw / n_cols] * n_cols

                raw_rh = [max(0.0, float(r.height or 0)) for r in table.rows]
                if all(h > 0 for h in raw_rh):
                    row_hs = [h / sh for h in raw_rh]
                else:
                    # Fallback when OOXML leaves <a:tr h="0"/> unset
                    eff_tbl_h = max(nh, n_rows * 24.0 * EMU_PER_PT / sh)
                    row_hs = [eff_tbl_h / n_rows] * n_rows

                col_xs = [nx]
                for cw_i in col_ws[:-1]:
                    col_xs.append(col_xs[-1] + cw_i)
                row_ys = [ny]
                for rh_i in row_hs[:-1]:
                    row_ys.append(row_ys[-1] + rh_i)

                eff_bg = bg_tracker[0] if bg_tracker else (255, 255, 255)
                bg_lum = 0.299 * eff_bg[0] + 0.587 * eff_bg[1] + 0.114 * eff_bg[2]
                tbl_default_fg = (25, 30, 38) if bg_lum >= 128 else (240, 244, 248)

                for r_idx, row in enumerate(table.rows):
                    for c_idx, cell in enumerate(row.cells):
                        if getattr(cell, "is_spanned", False):
                            continue
                        span_w = max(1, int(getattr(cell, "span_width", 1) or 1))
                        span_h = max(1, int(getattr(cell, "span_height", 1) or 1))
                        cx = col_xs[c_idx]
                        cy = row_ys[r_idx]
                        cw_c = sum(col_ws[c_idx : min(n_cols, c_idx + span_w)])
                        ch_c = sum(row_hs[r_idx : min(n_rows, r_idx + span_h)])

                        default_band = theme_colors.get("accent1", (245, 247, 250)) if r_idx == 0 else ((255, 255, 255) if bg_lum >= 128 else (28, 36, 48))
                        cell_fill = default_band
                        cell_border = (210, 218, 226)
                        cell_border_w = 1
                        cell_anchor = "t"
                        mar_l, mar_r, mar_t, mar_b = 0.004, 0.004, 0.002, 0.002

                        tcPr = cell._tc.find(f"{{{A_NS}}}tcPr")
                        if tcPr is not None:
                            cell_anchor = tcPr.attrib.get("anchor", "t")
                            if tcPr.find(f"{{{A_NS}}}noFill") is not None:
                                cell_fill = None
                            else:
                                sf = tcPr.find(f"{{{A_NS}}}solidFill")
                                if sf is not None:
                                    c_col = _resolve_fill_element(sf, theme_colors)
                                    if c_col is not None:
                                        cell_fill = c_col
                                else:
                                    gf = tcPr.find(f"{{{A_NS}}}gradFill")
                                    if gf is not None:
                                        g_col = _resolve_grad_first_color(gf, theme_colors)
                                        if g_col is not None:
                                            cell_fill = g_col
                            for ln_tag in ("lnB", "lnT", "lnL", "lnR"):
                                ln_el = tcPr.find(f"{{{A_NS}}}{ln_tag}")
                                if ln_el is not None:
                                    if ln_el.find(f"{{{A_NS}}}noFill") is not None:
                                        cell_border = None
                                    else:
                                        b_col = _resolve_fill_element(ln_el.find(f"{{{A_NS}}}solidFill"), theme_colors)
                                        if b_col is not None:
                                            cell_border = b_col
                                            if "w" in ln_el.attrib:
                                                try:
                                                    cell_border_w = max(1, int(round(float(ln_el.attrib["w"]) / EMU_PER_PT)))
                                                except Exception:
                                                    pass
                                            break
                            try:
                                if "marL" in tcPr.attrib: mar_l = float(tcPr.attrib["marL"]) / sw
                                if "marR" in tcPr.attrib: mar_r = float(tcPr.attrib["marR"]) / sw
                                if "marT" in tcPr.attrib: mar_t = float(tcPr.attrib["marT"]) / sh
                                if "marB" in tcPr.attrib: mar_b = float(tcPr.attrib["marB"]) / sh
                            except Exception:
                                pass

                        layers.append({
                            "kind": "shape",
                            "x": round(cx, 4), "y": round(cy, 4), "w": round(cw_c, 4), "h": round(ch_c, 4),
                            "fill": cell_fill, "border": cell_border, "border_w": cell_border_w,
                        })
                        if cell.text_frame:
                            c_bg = cell_fill or eff_bg
                            c_lum = 0.299 * c_bg[0] + 0.587 * c_bg[1] + 0.114 * c_bg[2]
                            c_def_fg = (245, 245, 248) if c_lum < 128 else tbl_default_fg
                            c_shape_proxy = type("_CellShape", (), {"text_frame": cell.text_frame, "_element": cell._tc})()
                            cell_paras, cell_lines = extract_paragraphs(c_shape_proxy, slide, theme_colors, theme_fonts, c_def_fg)
                            if cell_paras:
                                full_text_lines.extend(cell_lines)
                                text_blocks.append({
                                    "x": round(cx, 4), "y": round(cy, 4),
                                    "w": round(cw_c, 4), "h": round(ch_c, 4),
                                    "anchor": cell_anchor,
                                    "ins_l": round(mar_l, 4), "ins_t": round(mar_t, 4),
                                    "ins_r": round(mar_r, 4), "ins_b": round(mar_b, 4),
                                    "paragraphs": cell_paras,
                                })

        # Text Frames (including text inside shapes/badges/cards)
        if getattr(shape, "has_text_frame", False):
            eff_bg = fill_color or (bg_tracker[0] if bg_tracker else (255, 255, 255))
            eff_lum = 0.299 * eff_bg[0] + 0.587 * eff_bg[1] + 0.114 * eff_bg[2]
            box_default_fg = default_text_color if eff_lum >= 128 else (255, 255, 255)
            paras, t_lines = extract_paragraphs(shape, slide, theme_colors, theme_fonts, box_default_fg)
            if paras:
                full_text_lines.extend(t_lines)
                anchor = "t"
                ins_l, ins_t, ins_r, ins_b = 0.0, 0.0, 0.0, 0.0
                try:
                    bpr = shape.text_frame._txBody.find(f"{{{A_NS}}}bodyPr")
                    if bpr is not None:
                        anchor = bpr.attrib.get("anchor", "t")
                        ins_l = float(bpr.attrib.get("lIns", 91440)) / sw
                        ins_r = float(bpr.attrib.get("rIns", 91440)) / sw
                        ins_t = float(bpr.attrib.get("tIns", 45720)) / sh
                        ins_b = float(bpr.attrib.get("bIns", 45720)) / sh
                except Exception:
                    pass
                text_blocks.append({
                    "x": round(nx, 4), "y": round(ny, 4),
                    "w": round(nw, 4), "h": round(nh, 4),
                    "anchor": anchor,
                    "ins_l": round(ins_l, 4), "ins_t": round(ins_t, 4),
                    "ins_r": round(ins_r, 4), "ins_b": round(ins_b, 4),
                    "paragraphs": paras,
                })
    except Exception:
        pass


def extract_slide_structured(prs, slide):
    """Extract slide background, Z-ordered shapes/charts/images, and typography."""
    sw = float(prs.slide_width)
    sh = float(prs.slide_height)
    aspect = round(sw / max(sh, 1.0), 4)
    width_pt = round(sw / EMU_PER_PT, 2)

    theme_colors, theme_fonts = load_theme_info(prs)
    bg_color = get_slide_background(slide, prs, theme_colors)
    bg_tracker = [bg_color]

    bg_lum = 0.299 * bg_color[0] + 0.587 * bg_color[1] + 0.114 * bg_color[2]
    default_text_color = theme_colors.get("tx1") or ((0, 0, 0) if bg_lum >= 128 else (255, 255, 255))

    speaker_notes = ""
    try:
        if slide.has_notes_slide and slide.notes_slide.notes_text_frame:
            speaker_notes = slide.notes_slide.notes_text_frame.text.strip()
    except Exception:
        pass

    layers = []
    text_blocks = []
    full_text_lines = []

    layout = getattr(slide, "slide_layout", None)
    master = getattr(layout, "slide_master", None) if layout else None
    slide_show_master = _bool_attr(slide._element, "showMasterSp", default=True)
    layout_show_master = _bool_attr(layout._element, "showMasterSp", default=True) if layout else True

    # 1. Master non-placeholder shapes (backgrounds, footer accents, logos)
    if master and slide_show_master and layout_show_master:
        for msh in master.shapes:
            if not msh.is_placeholder:
                _extract_shape_recursive(msh, slide, sw, sh, theme_colors, theme_fonts, layers, text_blocks, full_text_lines, default_text_color, bg_tracker=bg_tracker)

    # 2. Layout non-placeholder shapes (critical for Google Slides dark/themed layouts!)
    if layout and slide_show_master:
        for lsh in layout.shapes:
            if not lsh.is_placeholder:
                _extract_shape_recursive(lsh, slide, sw, sh, theme_colors, theme_fonts, layers, text_blocks, full_text_lines, default_text_color, bg_tracker=bg_tracker)

    # Refresh default text color if layout/master contributed a full-bleed background shape
    effective_bg = bg_tracker[0]
    eff_lum = 0.299 * effective_bg[0] + 0.587 * effective_bg[1] + 0.114 * effective_bg[2]
    default_text_color = (245, 245, 248) if eff_lum < 128 else (theme_colors.get("tx1") or (0, 0, 0))

    # 3. Slide's own shapes in true Z-order
    for shape in slide.shapes:
        _extract_shape_recursive(shape, slide, sw, sh, theme_colors, theme_fonts, layers, text_blocks, full_text_lines, default_text_color, bg_tracker=bg_tracker)

    bg_color = bg_tracker[0]
    shapes_list = [x for x in layers if x["kind"] == "shape"]
    images_list = [x for x in layers if x["kind"] == "image"]
    full_text = "\n".join(full_text_lines)
    return aspect, width_pt, bg_color, speaker_notes, shapes_list, images_list, layers, text_blocks, full_text


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
            if idx == 0 and s_title and s_title != "Slide 1":
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
                "idx": idx + 1, "title": s_title,
                "has_notes": has_notes, "notes_preview": notes_preview,
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


def render_slide_browsh_blocks(aspect, bg_color, text_blocks, cols=110):
    rows = max(1, int(cols * (1.0 / aspect) * 0.50))
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
    return cols, rows, bg_color, [], text_lines


def _write_shape_entry(f, s):
    fill_str = f"{{{s['fill'][0]},{s['fill'][1]},{s['fill'][2]}}}" if s.get("fill") else "nil"
    border_str = f"{{{s['border'][0]},{s['border'][1]},{s['border'][2]}}}" if s.get("border") else "nil"
    f.write(f"    {{ kind = 'shape', x = {s['x']}, y = {s['y']}, w = {s['w']}, h = {s['h']}, fill = {fill_str}, border = {border_str}, border_w = {s.get('border_w', 1)} }},\n")


def _write_image_entry(f, img):
    f.write(f"    {{ kind = 'image', x = {img['x']}, y = {img['y']}, w = {img['w']}, h = {img['h']}, tw = {img['tw']}, th = {img['th']}, spans = {{\n")
    for sp in img["spans"]:
        if len(sp) >= 8 and sp[7] < 250:
            f.write(f"      {{{sp[0]},{sp[1]},{sp[2]},{sp[3]},{sp[4]},{sp[5]},{sp[6]},{sp[7]}}},\n")
        else:
            f.write(f"      {{{sp[0]},{sp[1]},{sp[2]},{sp[3]},{sp[4]},{sp[5]},{sp[6]}}},\n")
    f.write("    } },\n")


def render_slide(pptx_path, slide_idx, out_file, width=110, mode="hd"):
    try:
        if not Presentation:
            raise RuntimeError("python-pptx is not installed.")
        prs = Presentation(pptx_path)
        if slide_idx < 0 or slide_idx >= len(prs.slides):
            raise IndexError(f"Slide index {slide_idx} out of range (0..{len(prs.slides)-1})")

        slide = prs.slides[slide_idx]
        aspect, width_pt, bg_color, notes, shapes, images, layers, text_blocks, full_text = extract_slide_structured(prs, slide)

        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write(f"  mode = '{mode}',\n")
            f.write(f"  aspect_ratio = {aspect},\n")
            f.write(f"  width_pt = {width_pt},\n")
            f.write(f"  bg = {{{bg_color[0]}, {bg_color[1]}, {bg_color[2]}}},\n")
            f.write(f"  notes = {escape_lua_string(notes)},\n")
            f.write(f"  text = {escape_lua_string(full_text)},\n")

            f.write("  layers = {\n")
            for lay in layers:
                if lay["kind"] == "shape":
                    _write_shape_entry(f, lay)
                else:
                    _write_image_entry(f, lay)
            f.write("  },\n")

            f.write("  text_blocks = {\n")
            for tb in text_blocks:
                f.write(
                    f"    {{ x = {tb['x']}, y = {tb['y']}, w = {tb['w']}, h = {tb['h']}, "
                    f"anchor = \"{tb.get('anchor', 't')}\", ins_l = {tb.get('ins_l', 0)}, ins_t = {tb.get('ins_t', 0)}, "
                    f"ins_r = {tb.get('ins_r', 0)}, ins_b = {tb.get('ins_b', 0)}, paragraphs = {{\n"
                )
                for p in tb["paragraphs"]:
                    c = p["color"]
                    spc_b = p.get("space_before", 0.0) or 0.0
                    spc_a = p.get("space_after")
                    spc_a_str = f"{spc_a}" if spc_a is not None else "nil"
                    f.write(
                        f"      {{ text = \"{sanitize_str(p['text'])}\", size = {p['size']}, bold = {'true' if p['bold'] else 'false'}, "
                        f"italic = {'true' if p.get('italic') else 'false'}, color = {{{c[0]},{c[1]},{c[2]}}}, align = \"{p['align']}\", level = {p['level']}, "
                        f"bullet = {'true' if p['bullet'] else 'false'}, font = \"{p.get('font', 'sans')}\", spc_b = {spc_b}, spc_a = {spc_a_str}"
                    )
                    if p.get("runs") and len(p["runs"]) > 1:
                        f.write(", runs = {\n")
                        for r in p["runs"]:
                            rc = r["color"]
                            f.write(f"        {{ text = \"{sanitize_str(r['text'])}\", size = {r['size']}, bold = {'true' if r['bold'] else 'false'}, italic = {'true' if r.get('italic') else 'false'}, color = {{{rc[0]},{rc[1]},{rc[2]}}}, font = \"{r.get('font', 'sans')}\" }},\n")
                        f.write("      }")
                    f.write(" },\n")
                f.write("    } },\n")
            f.write("  },\n")

            if mode == "browsh":
                cols, rows, bg, _, tlines = render_slide_browsh_blocks(aspect, bg_color, text_blocks, cols=int(width) if width else 110)
                f.write(f"  cols = {cols},\n  rows = {rows},\n  graphic_runs = {{}},\n  text_lines = {{\n")
                for tl in tlines:
                    f.write(f"    {tl},\n")
                f.write("  },\n")

            f.write("}\n")
    except Exception as e:
        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n")
            f.write(f"  error = {escape_lua_string(str(e) + chr(10) + traceback.format_exc())}\n")
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
                matches.append({"slide": idx + 1, "target": "slide", "snippet": sanitize_str(combined[:120].strip())})
                continue
            if slide.has_notes_slide and slide.notes_slide.notes_text_frame:
                n_text = slide.notes_slide.notes_text_frame.text
                if q_lower in n_text.lower():
                    matches.append({"slide": idx + 1, "target": "notes", "snippet": sanitize_str(n_text[:120].strip())})
        with open(out_file, "w", encoding="utf-8") as f:
            f.write("return {\n  matches = {\n")
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
        get_pptx_info(pptx_path, sys.argv[3])
    elif cmd == "render":
        slide_idx = int(sys.argv[3])
        out_file = sys.argv[4]
        width = int(sys.argv[5]) if len(sys.argv) > 5 else 110
        mode = sys.argv[6] if len(sys.argv) > 6 else "hd"
        render_slide(pptx_path, slide_idx, out_file, width=width, mode=mode)
    elif cmd == "search":
        search_pptx(pptx_path, sys.argv[3], sys.argv[4])
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
