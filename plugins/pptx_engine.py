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
    bgRef = bg.find(f"{{{P_NS}}}bgRef")
    if bgRef is not None:
        for child in bgRef:
            c = _parse_color_node(child, theme_dict)
            if c is not None:
                return c
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


def _encode_rgba_rle(pil_rgba):
    """Encode an RGBA image into compact horizontal spans skipping transparent pixels."""
    w, h = pil_rgba.size
    pixels = pil_rgba.load()
    spans = []
    for py in range(h):
        in_run = False
        run_start = 0
        run_c = None
        for px in range(w):
            r, g, b, a = pixels[px, py]
            if a < 18:
                if in_run:
                    spans.append((run_start, py, px - run_start, 1, run_c[0], run_c[1], run_c[2], run_c[3]))
                    in_run = False
                continue
            cur = (r, g, b, a)
            if not in_run:
                in_run = True
                run_start = px
                run_c = cur
            else:
                if (
                    abs(r - run_c[0]) > 5
                    or abs(g - run_c[1]) > 5
                    or abs(b - run_c[2]) > 5
                    or abs(a - run_c[3]) > 8
                ):
                    spans.append((run_start, py, px - run_start, 1, run_c[0], run_c[1], run_c[2], run_c[3]))
                    run_start = px
                    run_c = cur
        if in_run:
            spans.append((run_start, py, w - run_start, 1, run_c[0], run_c[1], run_c[2], run_c[3]))
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


def _render_vector_shape_spans(geom, fill_color, border_color, border_w_pt, nw, nh, prst_av, flip_h, flip_v):
    """Render non-rectangular vector shapes with 2x supersampled anti-aliasing."""
    if Image is None:
        return None
    # Reasonable target resolution proportional to normalized slide fraction
    tw = max(24, min(520, int(round(nw * 720))))
    th = max(24, min(420, int(round(nh * 405))))
    ss = 2
    cw, ch = tw * ss, th * ss

    img = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    fill_rgba = (fill_color[0], fill_color[1], fill_color[2], 255) if fill_color else None
    stroke_rgba = (border_color[0], border_color[1], border_color[2], 255) if border_color else None
    lw = max(ss, int(round(border_w_pt * ss * (tw / max(nw * 720.0, 1.0))))) if stroke_rgba else 0
    pad = max(1, lw // 2 + 1) if stroke_rgba else 1
    x0, y0, x1, y1 = pad, pad, max(pad + 2, cw - 1 - pad), max(pad + 2, ch - 1 - pad)

    if geom == "ellipse":
        draw.ellipse([x0, y0, x1, y1], fill=fill_rgba, outline=stroke_rgba, width=lw)
    elif geom == "roundRect":
        adj = prst_av.get("adj", 16667.0) / 100000.0
        radius = max(2, int(round(min(x1 - x0, y1 - y0) * adj)))
        draw.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=fill_rgba, outline=stroke_rgba, width=lw)
    elif geom in ("rightArrow", "leftArrow", "upArrow", "downArrow"):
        head_frac = 0.42
        shaft_frac = 0.46
        if geom in ("rightArrow", "leftArrow"):
            w_span = x1 - x0
            h_span = y1 - y0
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
            w_span = x1 - x0
            h_span = y1 - y0
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
        return None

    resized = img.resize((tw, th), Image.Resampling.LANCZOS)
    img.close()
    spans = _encode_rgba_rle(resized)
    resized.close()
    return tw, th, spans


def _extract_chart_text(el):
    if el is None:
        return ""
    texts = [t.text for t in el.iter(f"{{{A_NS}}}t") if t.text]
    return "".join(texts).strip()


def _extract_chart_num_list(container_el):
    if container_el is None:
        return []
    pts = []
    for pt in container_el.findall(f".//{{{C_NS}}}pt"):
        v_el = pt.find(f"{{{C_NS}}}v")
        if v_el is not None and v_el.text is not None:
            try:
                pts.append((int(pt.attrib.get("idx", len(pts))), float(v_el.text)))
            except Exception:
                pass
    pts.sort(key=lambda x: x[0])
    return [v for _, v in pts]


def _extract_chart_str_list(container_el):
    if container_el is None:
        return []
    pts = []
    for pt in container_el.findall(f".//{{{C_NS}}}pt"):
        v_el = pt.find(f"{{{C_NS}}}v")
        if v_el is not None and v_el.text is not None:
            pts.append((int(pt.attrib.get("idx", len(pts))), v_el.text.strip()))
    pts.sort(key=lambda x: x[0])
    return [v for _, v in pts]


def _parse_spPr_stroke(spPr, theme_colors, default_color=None, default_w_pt=1.5):
    if spPr is None:
        return default_color, default_w_pt, False
    ln = spPr.find(f"{{{A_NS}}}ln")
    if ln is None:
        return default_color, default_w_pt, False
    if ln.find(f"{{{A_NS}}}noFill") is not None:
        return None, 0.0, True
    col = resolve_color(None, xml_el=ln, theme_dict=theme_colors, default=default_color)
    w_pt = default_w_pt
    if "w" in ln.attrib:
        try:
            w_pt = max(0.5, float(ln.attrib["w"]) / EMU_PER_PT)
        except Exception:
            pass
    return col, w_pt, False


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
    """Render OpenXML c:chart XML directly into anti-aliased RGBA RLE spans."""
    if Image is None or not chart_shape.has_chart:
        return None
    try:
        cs = chart_shape.chart._chartSpace
    except Exception:
        return None

    tw = max(120, min(620, int(round(nw * 720))))
    th = max(90, min(420, int(round(nh * 405))))
    ss = 2
    cw, ch = tw * ss, th * ss

    # Background from chartSpace spPr if solid, else transparent
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

    # Detect chart title
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

    # Parse axes visibility & range
    cat_ax = plot_area.find(f"{{{C_NS}}}catAx")
    val_axes = plot_area.findall(f"{{{C_NS}}}valAx")
    # Scatter charts have two valAx: first x (axPos b/t), second y (axPos l/r)
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

    # Margin allocation depending on whether title/axes exist
    pad_l = (56 if show_y else 10) * ss + (16 * ss if y_title else 0)
    pad_r = 16 * ss
    pad_t = (34 if title_text else 12) * ss
    pad_b = (32 if show_x else 10) * ss + (16 * ss if x_title else 0)

    legend_el = chart_el.find(f"{{{C_NS}}}legend")
    has_legend = legend_el is not None
    if has_legend:
        pad_t += 16 * ss

    px0, py0 = pad_l, pad_t
    px1, py1 = max(px0 + 20, cw - pad_r), max(py0 + 20, ch - pad_b)

    # Determine plot type & extract series
    line_chart = plot_area.find(f"{{{C_NS}}}lineChart")
    scatter_chart = plot_area.find(f"{{{C_NS}}}scatterChart")
    bar_chart = plot_area.find(f"{{{C_NS}}}barChart")
    area_chart = plot_area.find(f"{{{C_NS}}}areaChart")
    pie_chart = plot_area.find(f"{{{C_NS}}}pieChart") or plot_area.find(f"{{{C_NS}}}doughnutChart")

    fallback_palette = [
        theme_colors.get("accent1", (0, 104, 74)),
        theme_colors.get("accent2", (0, 237, 100)),
        theme_colors.get("accent3", (214, 57, 63)),
        theme_colors.get("accent4", (64, 160, 255)),
        theme_colors.get("accent5", (255, 175, 50)),
    ]

    # Axis colors
    bg_lum = 0.299 * effective_bg[0] + 0.587 * effective_bg[1] + 0.114 * effective_bg[2]
    axis_default = (160, 175, 185) if bg_lum < 128 else (120, 130, 140)
    grid_default = (45, 65, 78) if bg_lum < 128 else (215, 226, 220)
    lbl_default = (200, 215, 225) if bg_lum < 128 else (85, 105, 118)

    if pie_chart is not None:
        ser = pie_chart.find(f"{{{C_NS}}}ser")
        vals = _extract_chart_num_list(ser.find(f"{{{C_NS}}}val")) if ser is not None else []
        total = sum(max(0.0, v) for v in vals) or 1.0
        cx_p, cy_p = cw // 2, (py0 + py1) // 2
        rad = min(px1 - px0, py1 - py0) // 2 - 6 * ss
        start_deg = -90.0
        for idx, v in enumerate(vals):
            sweep = (max(0.0, v) / total) * 360.0
            col = fallback_palette[idx % len(fallback_palette)]
            draw.pieslice([cx_p - rad, cy_p - rad, cx_p + rad, cy_p + rad], start=start_deg, end=start_deg + sweep, fill=col + (255,), outline=canvas_bg if cs_bg else (255, 255, 255, 255), width=ss)
            start_deg += sweep
    else:
        chart_node = scatter_chart if scatter_chart is not None else (line_chart if line_chart is not None else (area_chart if area_chart is not None else bar_chart))
        if chart_node is None:
            img.close()
            return None

        ser_list = []
        cat_labels = []
        all_x, all_y = [], []

        for idx, ser in enumerate(chart_node.findall(f"{{{C_NS}}}ser")):
            def_col = fallback_palette[idx % len(fallback_palette)]
            spPr = ser.find(f"{{{C_NS}}}spPr")
            ln_col, ln_w_pt, no_ln = _parse_spPr_stroke(spPr, theme_colors, default_color=def_col, default_w_pt=2.5)
            fill_col = _parse_spPr_fill(spPr, theme_colors, default_color=ln_col or def_col)

            mk_el = ser.find(f"{{{C_NS}}}marker")
            mk_sym = "none"
            mk_size = 7
            mk_col = ln_col or fill_col or def_col
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
                    if mc is None:
                        mc, _, _ = _parse_spPr_stroke(mk_spPr, theme_colors, default_color=None)
                    if mc is not None:
                        mk_col = mc
            elif getattr(chart_shape.chart, "chart_type", None) and "MARKERS" in str(chart_shape.chart.chart_type):
                mk_sym = "circle"

            ser_name = _extract_chart_text(ser.find(f"{{{C_NS}}}tx"))

            if scatter_chart is not None:
                xs = _extract_chart_num_list(ser.find(f"{{{C_NS}}}xVal"))
                ys = _extract_chart_num_list(ser.find(f"{{{C_NS}}}yVal"))
                pts = list(zip(xs, ys))
                all_x.extend(xs)
                all_y.extend(ys)
            else:
                cats = _extract_chart_str_list(ser.find(f"{{{C_NS}}}cat"))
                if cats and not cat_labels:
                    cat_labels = cats
                ys = _extract_chart_num_list(ser.find(f"{{{C_NS}}}val"))
                xs = list(range(len(ys)))
                pts = list(zip(xs, ys))
                all_x.extend(xs)
                all_y.extend(ys)

            ser_list.append({
                "name": ser_name,
                "pts": pts,
                "line_col": None if no_ln else ln_col,
                "line_w": ln_w_pt,
                "fill_col": fill_col,
                "mk_sym": mk_sym,
                "mk_size": mk_size,
                "mk_col": mk_col,
            })

        if not all_y:
            img.close()
            return None

        # Resolve Y & X axis scaling bounds
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

        ymin, ymax = _axis_bounds(y_ax, all_y)
        if bar_chart is not None and ymin > 0:
            ymin = 0.0
        if scatter_chart is not None:
            xmin, xmax = _axis_bounds(x_ax, all_x)
        else:
            xmin, xmax = 0.0, float(max(1, (len(cat_labels) or max(all_x or [1]) + 1) - 1))

        # Gridlines & Y ticks
        y_unit = None
        if y_ax is not None:
            mu = y_ax.find(f"{{{C_NS}}}majorUnit")
            if mu is not None and "val" in mu.attrib:
                try:
                    y_unit = float(mu.attrib["val"])
                except Exception:
                    pass
        y_ticks = _nice_ticks(ymin, ymax, count=5, fixed_step=y_unit)

        if show_y:
            mg = y_ax.find(f"{{{C_NS}}}majorGridlines")
            if mg is not None:
                gcol, gw, gno = _parse_spPr_stroke(mg.find(f"{{{C_NS}}}spPr"), theme_colors, default_color=grid_default, default_w_pt=0.75)
                if gcol and not gno:
                    for yv in y_ticks:
                        yy = py1 - int(round((yv - ymin) / (ymax - ymin) * (py1 - py0)))
                        draw.line([(px0, yy), (px1, yy)], fill=gcol + (255,), width=max(1, int(gw * ss)))

        font_tick = _get_pil_font(10 * ss, bold=False)
        font_title = _get_pil_font(13 * ss, bold=True)

        # Axes lines & tick labels
        if show_x:
            xcol, xw, _ = _parse_spPr_stroke(x_ax.find(f"{{{C_NS}}}spPr"), theme_colors, default_color=axis_default, default_w_pt=1.0)
            if xcol:
                draw.line([(px0, py1), (px1, py1)], fill=xcol + (255,), width=max(ss, int(xw * ss)))
            if scatter_chart is not None:
                xt_vals = _nice_ticks(xmin, xmax, count=5)
                for xv in xt_vals:
                    xx = px0 + int(round((xv - xmin) / (xmax - xmin) * (px1 - px0)))
                    lbl = _fmt_num(xv)
                    draw.line([(xx, py1), (xx, py1 + 4 * ss)], fill=(xcol or axis_default) + (255,), width=ss)
                    if font_tick:
                        draw.text((xx, py1 + 6 * ss), lbl, fill=lbl_default + (255,), font=font_tick, anchor="ma")
            elif cat_labels:
                step = max(1, len(cat_labels) // 6)
                for ci in range(0, len(cat_labels), step):
                    xx = px0 + int(round((ci - xmin) / max(xmax - xmin, 1.0) * (px1 - px0)))
                    if font_tick:
                        draw.text((xx, py1 + 6 * ss), cat_labels[ci], fill=lbl_default + (255,), font=font_tick, anchor="ma")
            if x_title and font_tick:
                draw.text(((px0 + px1) // 2, ch - 6 * ss), x_title, fill=lbl_default + (255,), font=font_tick, anchor="mb")

        if show_y:
            ycol, yw, _ = _parse_spPr_stroke(y_ax.find(f"{{{C_NS}}}spPr"), theme_colors, default_color=axis_default, default_w_pt=1.0)
            if ycol:
                draw.line([(px0, py0), (px0, py1)], fill=ycol + (255,), width=max(ss, int(yw * ss)))
            for yv in y_ticks:
                yy = py1 - int(round((yv - ymin) / (ymax - ymin) * (py1 - py0)))
                draw.line([(px0 - 4 * ss, yy), (px0, yy)], fill=(ycol or axis_default) + (255,), width=ss)
                if font_tick:
                    draw.text((px0 - 8 * ss, yy), _fmt_num(yv), fill=lbl_default + (255,), font=font_tick, anchor="rm")
            if y_title and font_tick:
                draw.text((10 * ss, (py0 + py1) // 2), y_title, fill=lbl_default + (255,), font=font_tick, anchor="lm")

        def _to_px(vx, vy):
            sx = px0 + (vx - xmin) / max(xmax - xmin, 1e-9) * (px1 - px0)
            sy = py1 - (vy - ymin) / max(ymax - ymin, 1e-9) * (py1 - py0)
            return (sx, sy)

        # Draw data series
        if bar_chart is not None:
            n_cats = max(1, len(cat_labels) or len(ser_list[0]["pts"]))
            n_sers = max(1, len(ser_list))
            slot_w = (px1 - px0) / float(n_cats)
            bar_w = max(4 * ss, (slot_w * 0.72) / n_sers)
            y_zero = py1 - (0.0 - ymin) / max(ymax - ymin, 1e-9) * (py1 - py0)
            y_zero = max(py0, min(py1, y_zero))
            for si, s in enumerate(ser_list):
                bcol = s["fill_col"] or s["line_col"] or fallback_palette[si % len(fallback_palette)]
                for ci, (_, yv) in enumerate(s["pts"]):
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
                    smooth_pts = _catmull_rom_points(screen_pts, subdiv=5) if len(screen_pts) >= 4 else screen_pts
                    lw = max(ss, int(round(s["line_w"] * ss * 1.1)))
                    draw.line(smooth_pts, fill=s["line_col"] + (255,), width=lw, joint="curve")
                if s["mk_sym"] != "none":
                    r_mk = max(3 * ss, int(round((s["mk_size"] or 6) * ss * 0.55)))
                    mcol = s["mk_col"] + (255,)
                    for mx, my in screen_pts:
                        draw.ellipse([mx - r_mk, my - r_mk, mx + r_mk, my + r_mk], fill=mcol)

        if title_text and font_title:
            draw.text(((px0 + px1) // 2, 12 * ss), title_text, fill=title_color + (255,), font=font_title, anchor="ma")

        if has_legend and font_tick:
            lx = px0
            ly = py0 - 16 * ss
            for s in ser_list[:4]:
                if not s["name"]:
                    continue
                lcol = s["line_col"] or s["mk_col"] or fallback_palette[0]
                draw.rectangle([lx, ly, lx + 10 * ss, ly + 8 * ss], fill=lcol + (255,))
                draw.text((lx + 14 * ss, ly + 4 * ss), s["name"], fill=lbl_default + (255,), font=font_tick, anchor="lm")
                lx += (28 + len(s["name"]) * 6) * ss

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
    col = resolve_color(None, xml_el=rPr_el, theme_dict=theme_colors, default=None)
    if col is not None:
        out["color"] = col
    latin = rPr_el.find(f"{{{A_NS}}}latin")
    if latin is not None and latin.attrib.get("typeface"):
        fam = classify_font_family(latin.attrib["typeface"], theme_fonts)
        if fam:
            out["font"] = fam
    return out


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
        inherited = {"size": 18.0, "bold": False, "color": None, "font": default_ph_family}
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
            r_font = rp.get("font", p_font)
            r_color = rp.get("color") or resolve_color(r.font.color, xml_el=rPr, theme_dict=theme_colors, default=None)
            if r_color is not None and first_explicit_run_color is None:
                first_explicit_run_color = r_color
            runs_data.append({
                "text": r_text,
                "size": round(r_size, 1),
                "bold": bool(r_bold),
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

        # Accurate bullet detection: honor explicit <a:buNone/>
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

        paras.append({
            "text": final_text,
            "size": round(pt_size, 1),
            "bold": bool(is_bold),
            "color": effective_p_color,
            "align": align,
            "level": level,
            "bullet": has_bullet,
            "font": p_font,
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

        # Inspect geometry, fill, and stroke directly from spPr
        spPr = shape._element.find(f"{{{P_NS}}}spPr") if hasattr(shape, "_element") else None
        geom = "rect"
        prst_av = {}
        flip_h, flip_v = False, False
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
            xfrm = spPr.find(f"{{{A_NS}}}xfrm")
            if xfrm is not None:
                flip_h = xfrm.attrib.get("flipH") == "1"
                flip_v = xfrm.attrib.get("flipV") == "1"

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

        # Vector shapes: plain rects stay fast native rects; curved/arrow/line use AA RGBA spans
        if fill_color or border_color:
            if geom != "rect":
                rendered = _render_vector_shape_spans(geom, fill_color, border_color, border_w, nw, nh, prst_av, flip_h, flip_v)
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

        # Embedded Pictures with full RGBA alpha preservation
        if ((MSO_SHAPE_TYPE and shape.shape_type == MSO_SHAPE_TYPE.PICTURE) or hasattr(shape, "image")) and Image:
            try:
                blob = shape.image.blob
                pil_img = Image.open(io.BytesIO(blob)).convert("RGBA")
                thumb_w = min(440, max(32, int(round(nw * 720))))
                thumb_h = max(24, int(round(thumb_w * (pil_img.height / max(pil_img.width, 1)))))
                resized = pil_img.resize((thumb_w, thumb_h), Image.Resampling.BILINEAR)
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

        # Tables
        if getattr(shape, "has_table", False):
            table = shape.table
            n_rows = len(table.rows)
            n_cols = len(table.columns)
            if n_rows > 0 and n_cols > 0:
                cw = nw / n_cols
                ch = nh / n_rows
                eff_bg = bg_tracker[0] if bg_tracker else (255, 255, 255)
                bg_lum = 0.299 * eff_bg[0] + 0.587 * eff_bg[1] + 0.114 * eff_bg[2]
                tbl_default_fg = (25, 30, 38) if bg_lum >= 128 else (240, 244, 248)
                for r_idx, row in enumerate(table.rows):
                    for c_idx, cell in enumerate(row.cells):
                        cx = nx + c_idx * cw
                        cy = ny + r_idx * ch
                        cell_fill = (245, 247, 250) if r_idx == 0 else (255, 255, 255)
                        try:
                            if hasattr(cell, "fill") and cell.fill and cell.fill.type == 1:
                                cell_fill = resolve_color(cell.fill.fore_color, xml_el=getattr(cell, "_tc", None), theme_dict=theme_colors, default=cell_fill)
                        except Exception:
                            pass
                        layers.append({
                            "kind": "shape",
                            "x": round(cx, 4), "y": round(cy, 4), "w": round(cw, 4), "h": round(ch, 4),
                            "fill": cell_fill, "border": (210, 218, 226), "border_w": 1,
                        })
                        if cell.text_frame:
                            c_shape_proxy = type("_CellShape", (), {"text_frame": cell.text_frame, "_element": cell._tc})()
                            cell_paras, cell_lines = extract_paragraphs(c_shape_proxy, slide, theme_colors, theme_fonts, (25, 30, 38) if r_idx == 0 else tbl_default_fg)
                            if cell_paras:
                                full_text_lines.extend(cell_lines)
                                text_blocks.append({
                                    "x": round(cx + 0.004, 4), "y": round(cy + 0.004, 4),
                                    "w": round(max(0.01, cw - 0.008), 4), "h": round(max(0.01, ch - 0.008), 4),
                                    "anchor": "ctr",
                                    "ins_l": 0.0, "ins_t": 0.0, "ins_r": 0.0, "ins_b": 0.0,
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
                    f.write(
                        f"      {{ text = \"{sanitize_str(p['text'])}\", size = {p['size']}, bold = {'true' if p['bold'] else 'false'}, "
                        f"color = {{{c[0]},{c[1]},{c[2]}}}, align = \"{p['align']}\", level = {p['level']}, "
                        f"bullet = {'true' if p['bullet'] else 'false'}, font = \"{p.get('font', 'sans')}\""
                    )
                    if p.get("runs") and len(p["runs"]) > 1:
                        f.write(", runs = {\n")
                        for r in p["runs"]:
                            rc = r["color"]
                            f.write(f"        {{ text = \"{sanitize_str(r['text'])}\", size = {r['size']}, bold = {'true' if r['bold'] else 'false'}, color = {{{rc[0]},{rc[1]},{rc[2]}}}, font = \"{r.get('font', 'sans')}\" }},\n")
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
