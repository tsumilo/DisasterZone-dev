"""ui_audit --look: renders a view the way the game draws it, close enough to judge spacing and polish offline.

On top of the audit's layout (tools/ui_audit.py Layout) it draws every shown texture with its real image (game files
read from the installed client's CASC storage through generators/casc_local.py, the addon's own media from disk),
tex coords, vertex colour, gradient, desaturation, alpha (the parents' too), circle masks and ADD blending, in the
client's order (strata, frame level, draw layer, sublevel); texts in Friz Quadrata with their colours, inline |T
icons and the 1px shadow. Highlight layers are left out (nothing is hovered).

Images are cached as PNG under dev/art/casc/tex (git-ignored, Blizzard art). The fonts come from
dev/art/casc/lfg_mockup/art (frizqt.ttf, arialn.ttf); without them it falls back to Segoe UI.
"""
import io
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
ADDON = os.path.join(DEV, "..", "addon", "DisasterZone")
CACHE = os.path.join(DEV, "art", "casc", "tex")
FONT_DIR = os.path.join(DEV, "art", "casc", "lfg_mockup", "art")
FRIZ = os.path.join(FONT_DIR, "frizqt.ttf")
ARIALN = os.path.join(FONT_DIR, "arialn.ttf")
FALLBACK = "C:/Windows/Fonts/segoeui.ttf"

STRATA = ["BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP"]
LAYERS = {"BACKGROUND": 0, "BORDER": 1, "ARTWORK": 2, "OVERLAY": 3, "HIGHLIGHT": 4}
FONT_COLORS = {"Normal": (1, 0.82, 0), "Highlight": (1, 1, 1), "Disable": (0.5, 0.5, 0.5), "Green": (0.1, 1, 0.1),
               "Red": (1, 0.1, 0.1), "White": (1, 1, 1), "Black": (0, 0, 0), "DarkGray": (0.35, 0.35, 0.35)}

# Loaded before the addon in --look mode: item icons become "itemicon:<id>" (the mock's own are placeholders), so
# the render can draw the real icon (its name from Wowhead's tooltip data, cached; the image from the client).
PRELOAD = r"""
local M = __MOCK
for id, r in pairs(M.ITEMS) do r.icon = "itemicon:" .. id end
setmetatable(M.ITEMS, { __newindex = function(t, id, r)
  if type(r) == "table" then r.icon = "itemicon:" .. tostring(id) end
  rawset(t, id, r)
end })
"""

ICON_CACHE = os.path.join(DEV, "art", "casc", "item_icons.json")
_icons = None


def item_icon_name(item_id):
    """The icon file name of an item (e.g. inv_helmet_15), from the cache or Wowhead's tooltip data."""
    global _icons
    import json
    if _icons is None:
        _icons = {}
        for path in (ICON_CACHE, os.path.join(DEV, "art", "casc", "makeover_mockup", "items.json")):
            if os.path.isfile(path):
                try:
                    data = json.load(open(path, encoding="utf-8"))
                    for k, v in data.items():
                        _icons.setdefault(str(k), v.get("icon") if isinstance(v, dict) else v)
                except Exception:  # noqa: BLE001
                    pass
    key = str(item_id)
    if key not in _icons:
        name = None
        try:
            import urllib.request
            req = urllib.request.Request("https://nether.wowhead.com/tbc/tooltip/item/%s" % key,
                                         headers={"User-Agent": "Mozilla/5.0"})
            name = json.loads(urllib.request.urlopen(req, timeout=15).read()).get("icon")
        except Exception:  # noqa: BLE001
            name = None
        _icons[key] = name
        try:
            os.makedirs(os.path.dirname(ICON_CACHE), exist_ok=True)
            json.dump(_icons, open(ICON_CACHE, "w", encoding="utf-8"), indent=0, sort_keys=True)
        except Exception:  # noqa: BLE001
            pass
    return _icons.get(key)


CAPTURE = r"""
local M = __MOCK
local OBJ = M.OBJ
local out = {}
-- a button's highlight / pushed textures only show under the mouse or while pressed; disabled / checked ones by state
local skip = {}
for _, o in ipairs(M.all_objects) do
  local st = OBJ[o]
  if st then
    if st.hltex then skip[st.hltex] = true end
    if st.pushedtex then skip[st.pushedtex] = true end
    if st.distex and st.enabled ~= false then skip[st.distex] = true end
    if st.checkedtex and not st.checked then skip[st.checkedtex] = true end
    if st.dischecktex then skip[st.dischecktex] = true end
  end
end
local function effalpha(st)
  local a = 1
  while st do
    a = a * (st.alpha or 1)
    st = st.parent and OBJ[st.parent]
  end
  return a
end
for _, o in ipairs(M.all_objects) do
  local st = OBJ[o]
  local kind = st and st.kind
  if kind == "Line" and o.IsVisible and o:IsVisible() and M.line_points then
    -- a line: its two ends (UIParent units), thickness and colour; drawn in its frame's order
    local x1, y1, x2, y2 = M.line_points(o)
    local par = st.parent and OBJ[st.parent]
    if x1 and par then
      out[#out + 1] = { seq = st.seq, a = effalpha(st), layer = st.layer, sub = st.sublayer, line = { x1, y1, x2, y2 },
        thick = st.thickness or 1, lcolor = st.color, vc = st.vcolor, pseq = par.seq }
    end
  end
  if (kind == "Texture" or kind == "FontString" or kind == "EditBox") and o.IsVisible and o:IsVisible()
     and not skip[o] then
    local rec = { seq = st.seq, a = effalpha(st), layer = st.layer, sub = st.sublayer }
    if kind == "Texture" then
      rec.rot = st.rotation
      local t = st.texture
      rec.tex = t ~= nil and tostring(t) or nil
      rec.atlas = st.atlas
      rec.tc = st.texcoord
      rec.vc = st.vcolor
      rec.desat = st.desat
      rec.blend = st.blend
      rec.grad = st.gradient
      local m = st.masks and st.masks[1]
      if m and OBJ[m] then rec.mask = OBJ[m].texture and tostring(OBJ[m].texture) or nil end
    else
      rec.tcolor = st.tcolor
      local fo = st.fontobj
      rec.fobj = (fo and OBJ[fo] and OBJ[fo].name) or st.template
      if kind == "EditBox" then rec.text = o:GetText() or "" end
    end
    out[#out + 1] = rec
  end
end
return out
"""


def capture(client):
    """seq -> what the game needs to draw the region (texture, colours, alpha, layer...)."""
    rows = client.eval_py(CAPTURE) or []
    if isinstance(rows, dict):
        rows = list(rows.values())
    return {int(r["seq"]): r for r in rows}


# ---------------------------------------------------------------------------------------------------------------
# Textures
# ---------------------------------------------------------------------------------------------------------------
_mem = {}
_casc = None


def _casc_mod():
    global _casc
    if _casc is None:
        sys.path.insert(0, os.path.join(DEV, "generators"))
        import casc_local  # noqa: E402
        _casc = casc_local
    return _casc


def _open_bytes(b):
    im = Image.open(io.BytesIO(b))
    im.load()
    return im.convert("RGBA")


def load(tex):
    """The image for a texture path / file ID, or None."""
    if tex is None:
        return None
    key = str(tex).strip().lower().replace("/", "\\")
    if key in _mem:
        return _mem[key]
    img = None
    try:
        img = _load(key)
    except Exception:  # noqa: BLE001
        img = None
    _mem[key] = img
    return img


def _load(key):
    os.makedirs(CACHE, exist_ok=True)
    if key.startswith("itemicon:"):
        name = item_icon_name(key.split(":", 1)[1])
        return load("Interface\\Icons\\" + name) if name else None
    if re.fullmatch(r"\d+(\.0)?", key):
        fid = int(float(key))
        name = "fid_%d" % fid
        path = None
    else:
        path = key
        name = re.sub(r"[^a-z0-9]+", "_", path).strip("_")
        addon = "interface\\addons\\disasterzone\\"
        if path.startswith(addon):
            base = os.path.join(ADDON, *path[len(addon):].split("\\"))
            for ext in ("", ".tga", ".blp", ".png"):
                if os.path.isfile(base + ext):
                    return Image.open(base + ext).convert("RGBA")
            return None
        fid = None
    cached = os.path.join(CACHE, name + ".png")
    if os.path.isfile(cached):
        return Image.open(cached).convert("RGBA")
    casc = _casc_mod()
    if fid is None:
        p = path if re.search(r"\.(blp|tga)$", path) else path + ".blp"
        fid = casc.fdid_of(p)
        if fid is None:
            return None
    img = _open_bytes(casc.read_fid(fid))
    img.save(cached)
    return img


def _coords(tc):
    """(l, t, r, b) from a 4- or 8-value SetTexCoord."""
    if not tc:
        return 0.0, 0.0, 1.0, 1.0
    v = [float(x) for x in (tc.values() if isinstance(tc, dict) else tc)]
    if len(v) >= 8:
        return v[0], v[1], v[6], v[7]
    if len(v) >= 4:
        return v[0], v[2], v[1], v[3]
    return 0.0, 0.0, 1.0, 1.0


def _rgba(c, default=(1, 1, 1, 1)):
    if not c:
        return default
    v = list(c.values()) if isinstance(c, dict) else list(c)
    v = [float(x) if x is not None else 1.0 for x in v] + [1.0] * 4
    return tuple(v[:4])


def _gradient(size, orient, c1, c2):
    w, h = size
    horiz = str(orient).upper().startswith("H")
    n = w if horiz else h
    strip = Image.new("RGBA", (n, 1) if horiz else (1, n))
    px = strip.load()
    for i in range(n):
        f = i / max(1, n - 1)
        if not horiz:
            f = 1 - f          # VERTICAL: min colour at the bottom
        col = tuple(int(255 * (c1[k] + (c2[k] - c1[k]) * f)) for k in range(4))
        px[(i, 0) if horiz else (0, i)] = col
    return strip.resize((w, h), Image.BILINEAR)


def _tint(im, rgba):
    r, g, b, a = rgba
    if (r, g, b, a) == (1, 1, 1, 1):
        return im
    bands = im.split()
    out = [bands[0].point(lambda x: int(x * r)), bands[1].point(lambda x: int(x * g)),
           bands[2].point(lambda x: int(x * b)), bands[3].point(lambda x: int(x * a))]
    return Image.merge("RGBA", out)


def texture_image(r, w, h):
    """The region's pixels at w x h (RGBA), or None (nothing to draw)."""
    if w <= 0 or h <= 0:
        return None
    tex = r.get("tex")
    if tex == "Color":
        col = _rgba(r.get("color_rgba"))
        if r.get("grad"):
            g = r["grad"]
            g = list(g.values()) if isinstance(g, dict) else list(g)
            im = _gradient((w, h), g[0], _rgba(g[1]), _rgba(g[2]))
            im = _tint(im, col)
        else:
            im = Image.new("RGBA", (w, h), tuple(int(255 * x) for x in col))
    else:
        src = load(tex)
        if src is None:
            return None
        W, H = src.size
        tc = r.get("tc")
        tcv = [float(x) for x in (tc.values() if isinstance(tc, dict) else tc)] if tc else []
        if len(tcv) >= 8:
            # corners UL, LL, UR, LR: a box of the texture, maybe turned or mirrored
            xs, ys = tcv[0::2][:4], tcv[1::2][:4]
            x0, x1, y0, y1 = min(xs) * W, max(xs) * W, min(ys) * H, max(ys) * H
            crop = src.crop((int(round(x0)), int(round(y0)), max(int(round(x0)) + 1, int(round(x1))),
                             max(int(round(y0)) + 1, int(round(y1)))))
            ul = (tcv[0] > min(xs), tcv[1] > min(ys))          # (right?, bottom?) of the box at the top left
            ur = (tcv[4] > min(xs), tcv[5] > min(ys))
            ops = {((False, False), (True, False)): [], ((True, False), (False, False)): [Image.FLIP_LEFT_RIGHT],
                   ((False, True), (True, True)): [Image.FLIP_TOP_BOTTOM],
                   ((True, True), (False, True)): [Image.ROTATE_180],
                   ((False, True), (False, False)): [Image.ROTATE_270], ((True, False), (True, True)): [Image.ROTATE_90],
                   ((False, False), (False, True)): [Image.TRANSPOSE], ((True, True), (True, False)): [Image.TRANSVERSE]}
            for op in ops.get((ul, ur), []):
                crop = crop.transpose(op)
        else:
            l, t, rr, b = _coords(tc)
            flip_x, flip_y = rr < l, b < t
            x0, x1 = sorted((l * W, rr * W))
            y0, y1 = sorted((t * H, b * H))
            crop = src.crop((int(round(x0)), int(round(y0)), max(int(round(x0)) + 1, int(round(x1))),
                             max(int(round(y0)) + 1, int(round(y1)))))
            if flip_x:
                crop = crop.transpose(Image.FLIP_LEFT_RIGHT)
            if flip_y:
                crop = crop.transpose(Image.FLIP_TOP_BOTTOM)
        im = crop.resize((w, h), Image.LANCZOS)
        if r.get("desat"):
            a = im.split()[3]
            gray = im.convert("L")
            im = Image.merge("RGBA", (gray, gray, gray, a))
        im = _tint(im, _rgba(r.get("vc")))
        if r.get("grad"):
            g = r["grad"]
            g = list(g.values()) if isinstance(g, dict) else list(g)
            gi = _gradient((w, h), g[0], _rgba(g[1]), _rgba(g[2]))
            im = ImageChops.multiply(im, gi)
    if r.get("tex") == "Color" and r.get("vc"):
        im = _tint(im, _rgba(r.get("vc")))
    if r.get("rot"):
        import math
        im = im.rotate(math.degrees(float(r["rot"])), resample=Image.BICUBIC, expand=False)
    if r.get("mask"):
        m = load(r["mask"])
        if m is not None:
            ma = m.resize((w, h), Image.LANCZOS).split()[3]
            a = ImageChops.multiply(im.split()[3], ma)
            im.putalpha(a)
    alpha = float(1 if r.get("a") is None else r.get("a"))
    if alpha < 0.999:
        im.putalpha(im.split()[3].point(lambda x: int(x * alpha)))
    return im


# ---------------------------------------------------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------------------------------------------------
_fonts = {}


def font(px, narrow=False):
    path = ARIALN if narrow else FRIZ
    if not os.path.isfile(path):
        path = FALLBACK
    key = (path, px)
    if key not in _fonts:
        _fonts[key] = ImageFont.truetype(path, max(6, px))
    return _fonts[key]


TOKEN = re.compile(r"\|c([0-9a-fA-F]{8})|\|r|\|T([^|]*)\|t|\|A([^|]*)\|a|\|H[^|]*\|h|\|h|\|n")


def runs(text, base):
    """[(kind, value, colour)]: kind "t" = text, "i" = inline texture spec."""
    out, stack = [], [base]
    pos = 0
    text = text.replace("||", "\x02")
    for m in TOKEN.finditer(text):
        if m.start() > pos:
            out.append(("t", text[pos:m.start()].replace("\x02", "|"), stack[-1]))
        tok = m.group(0)
        if m.group(1):
            h = m.group(1)
            stack.append((int(h[2:4], 16) / 255, int(h[4:6], 16) / 255, int(h[6:8], 16) / 255))
        elif tok == "|r":
            if len(stack) > 1:
                stack.pop()
        elif m.group(2) is not None:
            out.append(("i", m.group(2), stack[-1]))
        pos = m.end()
    if pos < len(text):
        out.append(("t", text[pos:].replace("\x02", "|"), stack[-1]))
    return out


def inline_icon(spec, line_px, scale):
    """An |T path:h:w:x:y:tw:th:l:r:t:b |t icon as an image."""
    parts = spec.split(":")
    if parts[0] == "itemicon" and len(parts) > 1:
        parts = [parts[0] + ":" + parts[1]] + parts[2:]
    path = parts[0]
    try:
        h = float(parts[1]) if len(parts) > 1 and parts[1] else 0
    except ValueError:
        h = 0
    try:
        w = float(parts[2]) if len(parts) > 2 and parts[2] else h
    except ValueError:
        w = h
    hp = int(round((h if h > 0 else line_px / scale) * scale))
    wp = int(round((w if w > 0 else h if h > 0 else line_px / scale) * scale))
    r = {"tex": path, "a": 1}
    if len(parts) >= 11:
        try:
            tw, th = float(parts[5]), float(parts[6])
            l, rr, t, b = (float(x) for x in parts[7:11])
            r["tc"] = [l / tw, rr / tw, t / th, b / th]
        except ValueError:
            pass
    return texture_image(r, max(1, wp), max(1, hp))


def fs_color(r, look):
    tc = look.get("tcolor")
    if tc:
        c = _rgba(tc)
        return c[:3], c[3]
    name = look.get("fobj") or r.get("font") or ""
    for k, col in FONT_COLORS.items():
        if k in name:
            return col, 1
    return (1, 1, 1), 1


# ---------------------------------------------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------------------------------------------
def _paste(img, im, x, y, clip_px, blend=None):
    """Composites im at (x, y), cut to clip_px (x0, y0, x1, y1) when given."""
    w, h = im.size
    x0, y0, x1, y1 = x, y, x + w, y + h
    if clip_px:
        x0, y0 = max(x0, clip_px[0]), max(y0, clip_px[1])
        x1, y1 = min(x1, clip_px[2]), min(y1, clip_px[3])
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(img.size[0], x1), min(img.size[1], y1)
    if x1 <= x0 or y1 <= y0:
        return
    part = im.crop((x0 - x, y0 - y, x1 - x, y1 - y))
    if blend == "ADD":
        base = img.crop((x0, y0, x1, y1))
        a = part.split()[3]
        rgb = Image.merge("RGB", part.split()[:3])
        pre = ImageChops.multiply(rgb, Image.merge("RGB", (a, a, a)))
        out = ImageChops.add(base.convert("RGB"), pre)
        img.paste(out, (x0, y0))
    else:
        img.alpha_composite(part, (x0, y0))


def render(regs, lay, findings, path, look, A, crop=None):
    """A PNG of the view as drawn in game (see the module doc). A = the ui_audit module (layout + text helpers)."""
    S = A.PNG_SCALE
    shown = [s for s in regs if regs[s]["vis"] and lay.rect(s)]
    wins = {lay.window(s) for s in shown if regs[s]["kind"] != "FontString"}
    boxes = []
    for w in wins:
        r = lay.rect(w)
        if r and regs[w]["name"] not in ("", "UIParent") and r[2] > 20 and r[3] > 20 and r[2] < 1900:
            boxes.append((w, r))
    if crop is None:
        if not boxes:
            return
        l = min(b[0] for _, b in boxes)
        bt = min(b[1] for _, b in boxes)
        r_ = max(b[0] + b[2] for _, b in boxes)
        t = max(b[1] + b[3] for _, b in boxes)
        crop = (max(0, l - 10), max(0, bt - 10), min(1920, r_ + 10), min(1080, t + 10))
    cl, cb, cr, ct = crop
    W, H = int((cr - cl) * S), int((ct - cb) * S)
    if W <= 0 or H <= 0 or W > 5000 or H > 4000:
        return
    img = Image.new("RGBA", (W, H), (34, 34, 38, 255))

    def box(rc):
        return ((rc[0] - cl) * S, (ct - rc[1] - rc[3]) * S, (rc[0] + rc[2] - cl) * S, (ct - rc[1]) * S)

    def ibox(rc):
        x0, y0, x1, y1 = box(rc)
        return int(round(x0)), int(round(y0)), int(round(x1)), int(round(y1))

    dr = ImageDraw.Draw(img, "RGBA")
    # the windows: the game's dark stone, approximated flat, and a thin frame
    for w, rc in boxes:
        x0, y0, x1, y1 = ibox(rc)
        dr.rectangle((x0, y0, x1 - 1, y1 - 1), fill=(20, 20, 23, 255), outline=(92, 92, 96, 255), width=max(1, S))

    entries = []
    for s in shown:
        r = regs[s]
        lk = look.get(s)
        if not lk:
            continue
        kind = r["kind"]
        frame = s if kind == "EditBox" else r["parent"]
        fr = regs.get(frame, {})
        st = fr.get("strata") or "MEDIUM"
        strata = STRATA.index(st) if st in STRATA else 2
        level = float(fr.get("level") or 0)
        lname = lk.get("layer") or ("ARTWORK" if kind == "Texture" else "OVERLAY")
        layer = LAYERS.get(lname, 2)
        if layer == 4:
            continue                      # HIGHLIGHT: only while hovered
        if kind == "EditBox":
            layer = 3.5
        entries.append(((strata, level, layer, float(lk.get("sub") or 0), s), s))
    # lines (Line regions): in their frame's strata and level
    queued = {e[1] for e in entries}
    for s, lk in look.items():
        if not lk.get("line") or s in queued:
            continue
        fr = regs.get(int(lk.get("pseq") or 0))
        if not fr or not fr.get("vis"):
            continue
        st = fr.get("strata") or "MEDIUM"
        strata = STRATA.index(st) if st in STRATA else 2
        level = float(fr.get("level") or 0)
        layer = LAYERS.get(lk.get("layer") or "ARTWORK", 2)
        entries.append(((strata, level, layer, float(lk.get("sub") or 0), s), s))
    entries.sort()

    for _, s in entries:
        lk = look[s]
        if lk.get("line"):
            pseq = int(lk.get("pseq") or 0)
            clip = lay.clip(pseq) if pseq in regs else None
            _draw_line(img, lk, (cl, ct), S, ibox(clip) if clip else None)
            continue
        r = regs[s]
        rc = lay.rect(s)
        clip = lay.clip(s)
        clip_px = ibox(clip) if clip else None
        if r["kind"] == "Texture":
            x0, y0, x1, y1 = ibox(rc)
            d = dict(lk)
            d["color_rgba"] = r.get("color")
            im = texture_image(d, x1 - x0, y1 - y0)
            if im is not None:
                _paste(img, im, x0, y0, clip_px, lk.get("blend"))
        elif r["kind"] == "FontString":
            _draw_text(img, r, lk, rc, clip_px, lay, A, box)
        elif r["kind"] == "EditBox":
            text = lk.get("text") or ""
            if text:
                rr = dict(r)
                rr["text"], rr["jh"], rr["wrap"] = text, "LEFT", False
                inner = (rc[0] + 6, rc[1], max(1, rc[2] - 12), rc[3])
                _draw_text(img, rr, lk, inner, ibox(rc), lay, A, box)
    dr = ImageDraw.Draw(img, "RGBA")
    for i, f in enumerate(findings, 1):
        x0, y0, x1, y1 = box(f["rect"])
        x0, x1 = min(x0, x1), max(x0, x1)
        y0, y1 = min(y0, y1), max(y0, y1)
        dr.rectangle((x0 - 1, y0 - 1, x1 + 1, y1 + 1), outline=(255, 40, 40, 255), width=2)
        dr.text((x0, max(0, y0 - 14)), str(i), font=font(13), fill=(255, 80, 80))
    img.convert("RGB").save(path)


def _draw_line(img, lk, origin, S, clip_px):
    """A Line region: a bar `thick` wide between its two ends, anti-aliased (drawn 4x, scaled down)."""
    import math
    v = lk["line"]
    x1, y1, x2, y2 = [float(t) for t in (v.values() if isinstance(v, dict) else v)]
    cl, ct = origin
    ax, ay, bx, by = (x1 - cl) * S, (ct - y1) * S, (x2 - cl) * S, (ct - y2) * S
    th = max(0.5, float(lk.get("thick") or 1)) * S
    col = _rgba(lk.get("lcolor"))
    vc = _rgba(lk.get("vc"))
    col = tuple(col[i] * vc[i] for i in range(4))
    alpha = col[3] * float(1 if lk.get("a") is None else lk.get("a"))
    if alpha <= 0.003:
        return
    dx, dy = bx - ax, by - ay
    ln = math.hypot(dx, dy)
    if ln < 0.01:
        return
    nx, ny = -dy / ln * th / 2, dx / ln * th / 2
    poly = [(ax + nx, ay + ny), (bx + nx, by + ny), (bx - nx, by - ny), (ax - nx, ay - ny)]
    x0 = int(math.floor(min(p[0] for p in poly))) - 1
    y0 = int(math.floor(min(p[1] for p in poly))) - 1
    x1_ = int(math.ceil(max(p[0] for p in poly))) + 1
    y1_ = int(math.ceil(max(p[1] for p in poly))) + 1
    w, h = x1_ - x0, y1_ - y0
    if w <= 0 or h <= 0 or w > 6000 or h > 6000:
        return
    K = 4
    big = Image.new("L", (w * K, h * K), 0)
    ImageDraw.Draw(big).polygon([((px - x0) * K, (py - y0) * K) for px, py in poly], fill=int(255 * alpha))
    mask = big.resize((w, h), Image.LANCZOS)
    patch = Image.new("RGBA", (w, h), tuple(int(255 * c) for c in col[:3]) + (0,))
    patch.putalpha(mask)
    _paste(img, patch, x0, y0, clip_px)


def _draw_text(img, r, lk, rc, clip_px, lay, A, box):
    text = r["text"] or ""
    if not A.plain_text(text).strip():
        return
    S = A.PNG_SCALE
    size, narrow = A.font_of(r)
    k = lay.scale(r["seq"])
    px = size * k * S
    fnt = font(int(round(px)), narrow)
    base, a0 = fs_color(r, lk)
    alpha = a0 * float(1 if lk.get("a") is None else lk.get("a"))
    ink = A.drawn_text_rect(lay, r, rc)
    x0, y0, x1, y1 = box(ink)
    lh = A.line_height(size) * k * S
    plain = A.plain_text(text)
    constrained = lay.width_constrained(r)
    too_wide = constrained and A.text_width(plain, size, narrow) * k > rc[2] + 1
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    sh = max(1, int(round(S * 0.75)))

    def put(x, y, s, col):
        fill = tuple(int(255 * c) for c in col) + (int(255 * alpha),)
        d.text((x + sh, y + sh), s, font=fnt, fill=(0, 0, 0, int(220 * alpha)), anchor="lm")
        d.text((x, y), s, font=fnt, fill=fill, anchor="lm")

    if "\n" not in plain and not too_wide:
        x, y = x0, y0 + lh / 2
        # right / centre justified: place by the real font's width, not the audit's estimate (else right-aligned
        # columns end a few px short of their edge)
        if r["jh"] in ("RIGHT", "CENTER"):
            total = 0.0
            for kind, val, _ in runs(text, base):
                if kind == "t":
                    total += fnt.getlength(val) if val else 0
                else:
                    ic = inline_icon(val, lh, k * S)
                    total += (ic.size[0] + S) if ic is not None else 0
            x = (x1 - total) if r["jh"] == "RIGHT" else ((x0 + x1) / 2 - total / 2)
        for kind, val, col in runs(text, base):
            if kind == "t":
                if val:
                    put(x, y, val, col)
                    x += fnt.getlength(val)
            else:
                ic = inline_icon(val, lh, k * S)
                if ic is not None:
                    layer.alpha_composite(ic, (int(round(x)), int(round(y - ic.size[1] / 2))))
                    x += ic.size[0] + S
    else:
        lines = plain.replace("\x01", "").split("\n")
        if r["wrap"] and constrained:
            wrapped = []
            for para in lines:
                cur = ""
                for wd in para.split(" "):
                    cand = wd if not cur else cur + " " + wd
                    if A.text_width(cand, size, narrow) * k <= rc[2] + 0.5 or not cur:
                        cur = cand
                    else:
                        wrapped.append(cur)
                        cur = wd
                wrapped.append(cur)
            lines = wrapped
        m = re.search(r"\|c[0-9a-fA-F]{2}([0-9a-fA-F]{6})", text)
        col = (int(m.group(1)[0:2], 16) / 255, int(m.group(1)[2:4], 16) / 255, int(m.group(1)[4:6], 16) / 255) \
            if m else base
        # each character's colour (the game colours wrapped lines run by run, as it does one line): found again in
        # the plain text line by line; without that (inline icons), the first colour for all of it
        cols, starts = None, []
        if "\x01" not in plain:
            cc = []
            for kind, val, c in runs(text, base):
                if kind == "t":
                    cc.extend([c] * len(val))
            if len(cc) == len(plain):
                at = 0
                for ln in lines:
                    i = plain.find(ln, at)
                    if i < 0:
                        starts = None
                        break
                    starts.append(i)
                    at = i + len(ln)
                cols = cc if starts is not None else None
        room = max(1, int(round((y1 - y0) / lh))) if lay.height_constrained(r) else len(lines)
        for i, ln in enumerate(lines[:room]):
            cut = False
            if constrained and A.text_width(ln, size, narrow) * k > rc[2] + 1:
                ln = A.fit_prefix(ln, size, rc[2] / k, narrow) + "..."
                cut = True
            w = fnt.getlength(ln)
            if r["jh"] == "RIGHT":
                x = x1 - w
            elif r["jh"] == "LEFT":
                x = x0
            else:
                x = (x0 + x1) / 2 - w / 2
            y = y0 + (i + 0.5) * lh
            if cols and not cut:
                s0, j = starts[i], 0
                while j < len(ln):
                    c0 = cols[s0 + j]
                    e = j
                    while e < len(ln) and cols[s0 + e] == c0:
                        e += 1
                    put(x, y, ln[j:e], c0)
                    x += fnt.getlength(ln[j:e])
                    j = e
            else:
                put(x, y, ln, cols[starts[i]] if (cols and ln and starts[i] < len(cols)) else col)
    if clip_px:
        mask = Image.new("L", img.size, 0)
        ImageDraw.Draw(mask).rectangle((clip_px[0], clip_px[1], clip_px[2] - 1, clip_px[3] - 1), fill=255)
        layer.putalpha(ImageChops.multiply(layer.split()[3], mask))
    img.alpha_composite(layer)
