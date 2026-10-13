r"""Classic look, the Dock's art (UI/DockArt.lua; Settings > UI > Action bars > Bar art while Classic is the look).
Three sets, each one atlas of pieces the Dock puts together at any size, and a ground that tiles:
  Media/Classic/<set>.tga          the pieces (Data/ClassicArt.lua says where each one is)
  Media/Classic/<set>_ground.tga   the ground, 256 px = 128 UI px at a 36 px button
Sets: ironforge (the vanilla bar's stone, riveted steel), stormwind (night marble, gilt, sapphires), vault (the
guild bank: blued iron round a crimson inlay, brass-rimmed slots). Mockup dev/art/casc/classic_bars_mockup
(claude.ai/artifact/JpFwZd5QaaqB1eeXMgu1Fk; the user: all three, chosen while Classic is set).

Everything is drawn at 2 px per UI px of a 36 px button. Metal is coloured from a height field lit from the top left
(as gen_gilt_media.py), never tinted. Where a piece lies on the ground it holds only the shade it puts there (black
or white with alpha), so the ground tile under it shows through. The frame's pieces are cut from one plate drawn
with a step (as the crown's): runs (stretched along their edge: the moulding is the same all along it), outer
corners, the rounded joints where the step meets the plate; pillars, studs and rivets are cut as what they add.
The grounds are the client's own plaques and rock, darkened (the marble turned dark).
Run (from dev): luaenv\Scripts\python.exe generators\gen_classic_media.py"""
import math
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

DEV = Path(__file__).resolve().parents[1]
ADDON = DEV.parent / "addon" / "DisasterZone"
OUT = ADDON / "Media" / "Classic"
DATA = ADDON / "Data" / "ClassicArt.lua"
sys.path.insert(0, str(DEV / "tools"))
os.chdir(DEV)
import ui_look  # noqa: E402

LIGHT = np.array([-0.55, -0.6, 0.58])
LIGHT = LIGHT / np.linalg.norm(LIGHT)
D = 2                    # texture px per UI px (at a 36 px button)
B = 14                   # the moulding's width
F = 8                    # the shade it throws inside
TR = B + F               # a run's thickness
C = 36                   # an outer corner's size
SET_KEYS = ("ironforge", "stormwind", "vault")


def client(path):
    img = ui_look._load("Interface\\" + path.replace("/", "\\"))
    if img is None:
        raise SystemExit("missing client texture " + path)
    return img.convert("RGBA")


# ---------------------------------------------------------------------------------------------------------------
# colour
# ---------------------------------------------------------------------------------------------------------------
PAL = {
    "steel": [(0.0, (14, 15, 17)), (0.3, (58, 60, 64)), (0.55, (112, 114, 119)), (0.8, (182, 184, 189)),
              (1.0, (244, 245, 249))],
    "blued": [(0.0, (9, 11, 15)), (0.3, (36, 42, 50)), (0.58, (78, 88, 100)), (0.83, (140, 150, 162)),
              (1.0, (222, 228, 236))],
    "gold": [(0.0, (34, 22, 5)), (0.3, (94, 67, 14)), (0.6, (200, 150, 48)), (0.85, (240, 205, 110)),
             (1.0, (255, 245, 200))],
    "brass": [(0.0, (30, 18, 6)), (0.3, (88, 56, 20)), (0.6, (172, 122, 52)), (0.85, (226, 186, 112)),
              (1.0, (255, 240, 196))],
    "sapphire": [(0.0, (3, 6, 26)), (0.4, (14, 36, 112)), (0.7, (46, 96, 206)), (0.9, (150, 190, 255)),
                 (1.0, (240, 248, 255))],
    "garnet": [(0.0, (26, 2, 4)), (0.4, (104, 10, 16)), (0.7, (196, 36, 38)), (0.9, (255, 140, 120)),
               (1.0, (255, 236, 226))],
}

# per set: the moulding, the pillars' metal, the accent (hairlines, rims, lozenges), the stone in the pillars, the
# ground's mean brightness (for the light a piece adds), what lies in the experience slot
SETS = {
    "ironforge": dict(frame="steel", metal="steel", accent="steel", gem="steel", gmean=43, rivet=(7.0, 3.0),
                      trayRim=False, cells="client", band="client", caps="gryphon"),
    "stormwind": dict(frame="gold", metal="gold", accent="gold", gem="sapphire", gmean=30, rivet=None,
                      trayRim=True, cells="soft", band="pearls", caps="lion"),
    "vault": dict(frame="vault", metal="blued", accent="brass", gem="garnet", gmean=26, rivet=(3.0, 2.4),
                  trayRim=True, cells="slot", band="strap", caps="gryphon"),
}


def ramp(v, stops):
    v = np.clip(v, 0, 1)
    out = np.zeros(v.shape + (3,))
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        m = (v >= a) & (v <= b)
        t = ((v - a) / (b - a))[m][:, None]
        out[m] = np.array(ca) * (1 - t) + np.array(cb) * t
    return out


def normals(h):
    gy, gx = np.gradient(h)
    n = np.dstack([-gx, -gy, np.ones_like(h)])
    return n / np.linalg.norm(n, axis=2, keepdims=True)


def metal(n, h, stops, base=0.5, spec=0.3):
    d = n @ LIGHT
    r = 2 * d[..., None] * n - LIGHT
    s = np.clip(r[..., 2], 0, 1) ** 24
    return ramp(base + 1.1 * (d - LIGHT[2]) + 0.02 * (h - 3) + spec * s, stops)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def smooth_noise(w, h, cells, seed):
    rng = np.random.default_rng(seed)
    g = rng.random((cells, cells))
    ys, xs = np.mgrid[0:h, 0:w]
    fx, fy = xs / w * cells, ys / h * cells
    x0, y0 = np.floor(fx).astype(int), np.floor(fy).astype(int)
    tx, ty = fx - x0, fy - y0
    tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
    x1, y1 = (x0 + 1) % cells, (y0 + 1) % cells
    x0, y0 = x0 % cells, y0 % cells
    a = g[y0, x0] * (1 - tx) + g[y0, x1] * tx
    b = g[y1, x0] * (1 - tx) + g[y1, x1] * tx
    return a * (1 - ty) + b * ty


def fbm(w, h, seed, octaves):
    v, amp, tot = np.zeros((h, w)), 1.0, 0.0
    for i, c in enumerate(octaves):
        v += amp * smooth_noise(w, h, c, seed + i)
        tot += amp
        amp *= 0.55
    return v / tot


def arr(img):
    return np.asarray(img.convert("RGBA")).astype(float)


def tileable(a):
    """Four copies (none / half-shifted in x / in y / both) blended so each copy's seam sits where its weight is 0."""
    h, w = a.shape[:2]
    sx = np.sin(np.pi * (np.arange(w) + 0.5) / w) ** 2
    sy = np.sin(np.pi * (np.arange(h) + 0.5) / h) ** 2
    SX, SY = sx[None, :, None], sy[:, None, None]
    bx = np.roll(a, w // 2, 1)
    by = np.roll(a, h // 2, 0)
    bxy = np.roll(bx, h // 2, 0)
    return SX * SY * a + (1 - SX) * SY * bx + SX * (1 - SY) * by + (1 - SX) * (1 - SY) * bxy


def retone(rgb, mean, contrast):
    lum = rgb.mean(2, keepdims=True)
    out = (lum - lum.mean()) * contrast + np.array(mean)[None, None, :] + (rgb - lum) * 0.35
    return np.clip(out, 0, 255)


# ---------------------------------------------------------------------------------------------------------------
# grounds (256 x 256, tile)
# ---------------------------------------------------------------------------------------------------------------
def resized(a, size=256):
    return np.asarray(Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)).astype(float)


def ground(key):
    if key == "ironforge":
        a = arr(client("ItemTextFrame/ItemText-Stone-TopLeft"))[:, :, :3]
        return retone(resized(tileable(a[8:248, 8:248])), (43, 41, 39), 1.0)
    if key == "stormwind":
        a = 255 - arr(client("ItemTextFrame/ItemText-Marble-TopLeft"))[:, :, :3]
        a = retone(resized(tileable(a[10:246, 10:246])), (27, 29, 38), 1.3)
        return np.clip(a * np.array([0.95, 0.99, 1.12])[None, None, :], 0, 255)
    a = arr(client("FrameGeneral/UI-Background-Rock"))[:, :, :3]
    a = retone(a, (26, 24, 25), 1.4)
    return np.clip(a * (0.85 + 0.3 * fbm(256, 256, 7, (8, 16, 32)))[..., None], 0, 255)


# ---------------------------------------------------------------------------------------------------------------
# geometry
# ---------------------------------------------------------------------------------------------------------------
def seg_d(X, Y, a, b):
    (ax, ay), (bx, by) = a, b
    dx, dy = bx - ax, by - ay
    t = np.clip(((X - ax) * dx + (Y - ay) * dy) / (dx * dx + dy * dy), 0, 1)
    return np.hypot(X - (ax + t * dx), Y - (ay + t * dy))


def rect_sd(X, Y, x, y, w, h):
    qx = np.abs(X - (x + w / 2)) - w / 2
    qy = np.abs(Y - (y + h / 2)) - h / 2
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0)


class Canvas:
    """A height field (tex px), materials, the ground's own light (AO, recesses) and what is inside the plate."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.Y, self.X = np.mgrid[0:h, 0:w].astype(float) + 0.5
        self.H = np.zeros((h, w))
        self.M = np.zeros((h, w), int)          # 0 ground, 1 metal, 2 accent, 3 inlay, 4 gem
        self.ao = np.zeros((h, w))
        self.recess = np.zeros((h, w), bool)
        self.inside = np.ones((h, w), bool)
        self.edge = np.ones((h, w))             # the plate edge's anti-aliasing
        self.d = np.full((h, w), np.inf)        # distance in from the plate's edge

    def raise_(self, m, h, mat):
        upd = m & (h > self.H)
        self.H[upd] = h[upd]
        self.M[upd] = mat

    def dome(self, cx, cy, r, base, mat, k=0.9):
        rho2 = (self.X - cx) ** 2 + (self.Y - cy) ** 2
        self.raise_(rho2 < r * r, base + np.sqrt(np.maximum(r * r - rho2, 0)) * k, mat)

    def sink(self, x, y, w, h, depth, rim=None):
        sd = rect_sd(self.X, self.Y, x, y, w, h)
        m = sd < 0
        self.H[m] = np.minimum(self.H[m], -depth * smoothstep(0, 3, -sd[m]))
        self.ao[m] = np.maximum(self.ao[m], np.exp(sd[m] / 5))
        self.recess[m] = True
        if rim:
            r = (sd >= 0) & (sd < 2.2)
            self.H[r] = 1.4 * np.sin(np.pi * sd[r] / 2.2) + 0.2
            self.M[r] = rim


def frame(cv, st, poly, rects):
    """The plate (a union of rects, its outline poly) and its moulding."""
    X, Y = cv.X, cv.Y
    inside = np.zeros_like(cv.inside)
    for (x, y, w, h) in rects:
        inside |= (X >= x) & (X <= x + w) & (Y >= y) & (Y <= y + h)
    d = np.full(X.shape, np.inf)
    for a, b in zip(poly, poly[1:] + poly[:1]):
        d = np.minimum(d, seg_d(X, Y, a, b))
    cv.inside, cv.d = inside, d
    cv.edge = np.where(inside, np.clip(d + 0.5, 0, 1), 0)
    m = inside & (d < B)
    kind = st["frame"]
    if kind == "steel":
        h = np.where(d < 3, 4 * np.sin(np.pi / 2 * np.clip(d, 0, 3) / 3), 4.0)
        h = h - 1.6 * np.exp(-((d - 7.5) / 0.9) ** 2)                       # an engraved line
        h = np.where(d > B - 4, 4 - 3.2 * (d - (B - 4)) / 4, h)              # the inner chamfer
        cv.H[m], cv.M[m] = h[m], 1
    elif kind == "gold":
        outer = 4.6 * np.sqrt(np.clip(1 - ((d - 2.3) / 2.3) ** 2, 0, 1))       # the outer bead
        cove = 1.2 + 2.0 * ((d - 6.5) / 1.9) ** 2                              # a cove
        inner = 0.8 + 2.4 * np.sqrt(np.clip(1 - ((d - 11.2) / 1.8) ** 2, 0, 1))  # the inner bead
        h = np.where(d < 4.6, outer, np.where(d < 8.4, np.minimum(cove, 4), np.where(d < 9.4, 3.2, inner)))
        h = np.where(d > 13, np.maximum(0, 0.8 - (d - 13) * 0.8), h)
        cv.H[m], cv.M[m] = h[m], 2
    else:
        steel = np.where(d < 2.5, 4.5 * np.sin(np.pi / 2 * np.clip(d, 0, 2.5) / 2.5), 4.5)
        steel = np.where(d > 5, 4.5 - (d - 5) * 1.5, steel)
        h = np.where(d < 6, steel, 1.6)
        h = np.where((d >= 6) & (d < 7), 2.6, h)                               # gold hairlines
        h = np.where((d >= 12) & (d < 13), 2.4, h)
        h = np.where(d >= 13, 1.6 - (d - 13) * 1.2, h)
        cv.H[m] = h[m]
        mat = np.where(d < 6, 1, np.where((d < 7) | ((d >= 12) & (d < 13)), 2, 3))
        cv.M[m] = mat[m]


def corner_ornaments(cv, st, corners):
    """Ironforge: a bolted plate on each outer corner. Stormwind: a gilt lozenge with a sapphire."""
    X, Y = cv.X, cv.Y
    for (cx, cy, ox, oy) in corners:
        if st["frame"] == "steel":
            bx0 = cx if ox > 0 else cx - 30
            by0 = cy if oy > 0 else cy - 30
            sd = rect_sd(X, Y, bx0, by0, 30, 30)
            m = (sd < 0) & cv.inside
            h2 = 5.0 * smoothstep(0, 2.5, -sd) + 0.4
            upd = m & (h2 > cv.H - 0.3)
            cv.H[upd] = np.maximum(cv.H[upd], h2[upd])
            cv.M[upd] = 1
            cv.dome(cx + ox * 15, cy + oy * 15, 5.0, 4.6, 1)
        elif st["frame"] == "gold":
            qx, qy = cx + ox * B / 2, cy + oy * B / 2
            s = np.abs(X - qx) + np.abs(Y - qy)
            h3 = 1.0 + 5.2 * smoothstep(0, 4, 19 - s) - 1.2 * smoothstep(6, 9, 19 - s) + 1.2 * smoothstep(9, 11, 19 - s)
            cv.raise_((s < 19) & cv.inside, h3, 2)
            cv.dome(qx, qy, 5.0, 4.6, 4, 0.8)


def shade(cv, st, crimson=None):
    """RGBA: metal in colour; on the ground the shade the pieces put there (black or white with alpha)."""
    n = normals(cv.H)
    diff = (n @ LIGHT) / LIGHT[2]
    lit = np.clip(0.25 + 0.75 * diff, 0.2, 1.7)
    shadow = np.clip(np.roll(np.roll(cv.H, 3, 0), 3, 1) - cv.H - 0.4, 0, 6) / 6
    shadow = np.asarray(Image.fromarray((shadow * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.6))) / 255
    dark = 1 - 0.6 * shadow
    col = np.zeros(cv.H.shape + (3,))
    m1, m2, m3, m4 = cv.M == 1, cv.M == 2, cv.M == 3, cv.M == 4
    col[m1] = metal(n, cv.H, PAL[st["metal"] if st["frame"] != "gold" else "gold"])[m1]
    col[m2] = metal(n, cv.H, PAL[st["accent"]])[m2]
    if m3.any():
        col[m3] = (crimson * lit[..., None])[m3]
    col[m4] = metal(n, cv.H, PAL[st["gem"]], base=0.45, spec=0.6)[m4]
    col *= dark[..., None]
    rgba = np.zeros(cv.H.shape + (4,))
    solid = cv.M > 0
    rgba[solid, :3] = col[solid]
    rgba[solid, 3] = 255
    # the ground: its light (relief, recess, AO, shadow) as a black or white veil
    L = lit * (1 - 0.55 * cv.ao) * np.where(cv.recess, 0.62, 1.0) * dark
    g = ~solid
    darker = g & (L < 1)
    rgba[darker, 3] = (1 - L[darker]) * 255
    lighter = g & (L >= 1)
    rgba[lighter, :3] = 255
    gm = st["gmean"]
    rgba[lighter, 3] = np.clip((L[lighter] - 1) * gm / (255 - gm), 0, 1) * 255
    rgba[..., 3] *= cv.edge
    return rgba


def crimson_by_d(d):
    """The vault's inlay: crimson leather, darker at the hairlines; the same all along an edge (a run, a corner and
    a joint meet without a seam)."""
    t = np.clip((d - 7) / 5, 0, 1)
    k = 0.72 + 0.38 * np.sin(np.pi * t) ** 0.6
    return (np.array([118, 20, 18])[None, None, :] * k[..., None])


def additive(base, top):
    """What `top` adds over `base` (both shade() output): changed metal as it is, the ground's extra shade alone."""
    out = np.zeros_like(top)
    diff = np.abs(top - base).max(2) > 1.5
    solid = diff & (top[..., 3] >= 254) & (top[..., :3].sum(2) > 0)
    out[solid] = top[solid]
    veil = diff & ~solid
    # (shade on shade: the extra darkening of a black veil)
    ab, at = base[..., 3] / 255, top[..., 3] / 255
    blackb = base[..., :3].sum(2) == 0
    blackt = top[..., :3].sum(2) == 0
    m = veil & blackt & blackb
    add = np.clip(1 - (1 - at) / np.maximum(1 - ab, 1e-3), 0, 1)
    out[m, 3] = add[m] * 255
    m2 = veil & ~(blackt & blackb)
    out[m2] = top[m2]
    return out


# ---------------------------------------------------------------------------------------------------------------
# the pieces of a set
# ---------------------------------------------------------------------------------------------------------------
def frame_pieces(st):
    """The specimen: a plate 420 x 230 with a step 160 wide on its top (y 0 .. 70)."""
    W, Hh, pt = 420, 230, 70
    sx, sx2 = 120, 280
    cv = Canvas(W, Hh)
    poly = [(0, pt), (sx, pt), (sx, 0), (sx2, 0), (sx2, pt), (W, pt), (W, Hh), (0, Hh)]
    frame(cv, st, poly, [(0, pt, W, Hh - pt), (sx, 0, sx2 - sx, pt + 2)])
    corner_ornaments(cv, st, [(0, pt, 1, 1), (W, pt, -1, 1), (0, Hh, 1, -1), (W, Hh, -1, -1)])
    img = shade(cv, st, crimson_by_d(cv.d) if st["frame"] == "vault" else None)
    p = {}
    p["tl"] = img[pt:pt + C, 0:C]
    p["tr"] = img[pt:pt + C, W - C:W]
    p["bl"] = img[Hh - C:Hh, 0:C]
    p["br"] = img[Hh - C:Hh, W - C:W]
    p["top"] = img[pt:pt + TR, 60:64]
    p["bottom"] = img[Hh - TR:Hh, 200:204]
    p["left"] = img[150:154, 0:TR]
    p["right"] = img[150:154, W - TR:W]
    p["jl"] = img[pt:pt + TR, sx:sx + TR]
    p["jr"] = img[pt:pt + TR, sx2 - TR:sx2]
    return p


def pillar_pieces(st):
    """A pillar from the top moulding to the bottom one (collars where it meets them), the stone in its middle."""
    W, Hh, pt, cx = 120, 200, 0, 60
    def plate():
        cv = Canvas(W, Hh)
        frame(cv, st, [(-200, pt), (W + 200, pt), (W + 200, Hh), (-200, Hh)], [(-200, pt, W + 400, Hh - pt)])
        return cv
    cv0 = plate()
    base = shade(cv0, st, None if st["frame"] != "vault" else crimson_by_d(cv0.d))

    def with_pillar(stud):
        cv = plate()
        dx = np.abs(cv.X - cx)
        hw = 6.0
        m = (dx < hw) & (cv.Y > pt + B - 2) & (cv.Y < Hh - B + 2)
        mat = 2 if st["frame"] == "gold" else 1
        cv.raise_(m, 0.6 + 4.0 * np.sqrt(np.clip(1 - (dx / hw) ** 2, 0, 1)), mat)
        for cy in (pt + B + 4, Hh - B - 4):
            sd = rect_sd(cv.X, cv.Y, cx - 10, cy - 4, 20, 8)
            cv.raise_(sd < 0, 1.0 + 4.2 * smoothstep(0, 2.5, -sd), mat)
        if stud:
            cy = Hh / 2
            if st["gem"] == "sapphire":
                cv.dome(cx, cy, 8.0, 1.0, 2, 0.5)
                cv.dome(cx, cy, 5.5, 4.0, 4, 0.8)
            elif st["gem"] == "garnet":
                s = np.abs(cv.X - cx) / 11 + np.abs(cv.Y - cy) / 15
                cv.raise_(s < 1, 1.5 + 3.5 * (1 - s), 2)
                cv.dome(cx, cy, 4.5, 3.5, 4, 0.8)
            else:
                cv.dome(cx, cy, 5.5, 3.0, 1, 0.9)
        return shade(cv, st, None if st["frame"] != "vault" else crimson_by_d(cv.d))
    pl = with_pillar(False)
    ps = with_pillar(True)
    add = additive(base, pl)
    p = {}
    p["post_top"] = add[0:B + 16, cx - 14:cx + 16]
    p["post_mid"] = add[96:100, cx - 10:cx + 12]
    p["post_bot"] = add[Hh - B - 12:Hh, cx - 14:cx + 16]
    p["stud"] = additive(pl, ps)[int(Hh / 2) - 18:int(Hh / 2) + 20, cx - 16:cx + 18]
    return p


def nine(img, x0, y0, x1, y1, c):
    """A 9-slice cut of the box x0..x1, y0..y1 (corners c px; the middles 4 px slices)."""
    mx, my = (x0 + x1) // 2, (y0 + y1) // 2
    return {"tl": img[y0:y0 + c, x0:x0 + c], "t": img[y0:y0 + c, mx - 2:mx + 2], "tr": img[y0:y0 + c, x1 - c:x1],
            "l": img[my - 2:my + 2, x0:x0 + c], "c": img[my - 2:my + 2, mx - 2:mx + 2], "r": img[my - 2:my + 2, x1 - c:x1],
            "bl": img[y1 - c:y1, x0:x0 + c], "b": img[y1 - c:y1, mx - 2:mx + 2], "br": img[y1 - c:y1, x1 - c:x1]}


def sunk(st, depth, rim, out, c, inset=0):
    """A sunk box (a tray, a well, a slot) as a 9-slice of the box 100 x 80 at 30, 30 grown by `out` px; what sinks
    is that box shrunk by `inset` (a well sinks 2 px inside its cell, its rim between them)."""
    cv = Canvas(160, 140)
    cv.sink(30 + inset, 30 + inset, 100 - 2 * inset, 80 - 2 * inset, depth, rim=rim)
    img = shade(cv, st)
    return nine(img, 30 - out, 30 - out, 130 + out, 110 + out, c)


def rivet(st, r, mat, base=3.5):
    cv = Canvas(16, 16)
    cv.H[:] = base
    cv.M[:] = 0
    cv.dome(7.5, 7.5, r, base - 0.5, mat)
    img = shade(cv, st)
    # (only the rivet and its shadow: the flat round it is the run's)
    flat = Canvas(16, 16)
    flat.H[:] = base
    return additive(shade(flat, st), img)


def band(st):
    """What lies in the experience slot at max level: Stormwind's gilt pearls, the vault's stitched strap (64 x 22,
    tiles left to right). Ironforge's is the client's own max-level grooves."""
    w, h = 64, 22
    Y, X = np.mgrid[0:h, 0:w].astype(float) + 0.5
    if st["band"] == "pearls":
        per, cy = 16.0, h / 2
        u = X % per
        r = h / 2 - 2
        bead = np.sqrt(np.clip(r * r - (u - per / 2) ** 2 - (Y - cy) ** 2, 0, None)) * 0.9
        reel = 1.6 * np.sqrt(np.clip(1 - (np.minimum(u, per - u) / 2.0) ** 2 - ((Y - cy) / 4.0) ** 2, 0, None))
        hh = np.maximum(bead, reel)
        c = metal(normals(hh), hh, PAL["gold"], base=0.42)
        a = np.where(hh > 0.05, 255, 0)
        # (the pearls' shadow on the marble)
        sh = np.roll(np.roll((hh > 0.05).astype(float), 2, 0), 2, 1) * (hh <= 0.05)
        out = np.zeros((h, w, 4))
        out[..., :3] = c
        out[..., 3] = a
        out[sh > 0, :3] = 0
        out[sh > 0, 3] = 120
        return out
    n = fbm(w, h, 21, (2, 4, 8, 16))
    c = np.array([118, 20, 18])[None, None, :] * (0.62 + 0.62 * n[..., None])
    c = c * (1.0 - 0.35 * (Y / h))[..., None]
    stitch = ((X % 8) < 4) & ((np.abs(Y - 2.5) < 0.8) | (np.abs(Y - (h - 2.5)) < 0.8))
    c[stitch] = np.array([196, 160, 96])
    out = np.zeros((h, w, 4))
    out[..., :3] = c
    out[..., 3] = 255
    return out


def pieces(key):
    st = SETS[key]
    p = {}
    for k, v in frame_pieces(st).items():
        p[k] = v
    p.update(pillar_pieces(st))
    rimmed = 2 if st["trayRim"] else None
    for k, v in sunk(st, 3.0 if key != "stormwind" else 1.4, rimmed, 4, 20).items():
        p["tray_" + k] = v
    if st["cells"] == "soft":
        for k, v in sunk(st, 3.0, None, 0, 14, inset=2).items():
            p["well_" + k] = v
    elif st["cells"] == "slot":
        for k, v in sunk(st, 2.6, 2, 0, 14, inset=2).items():
            p["well_" + k] = v
        p["junction"] = rivet(st, 3.6, 2, base=0.0)
    if st["rivet"]:
        p["rivet"] = rivet(st, st["rivet"][1], 1, base=4.0 if key == "ironforge" else 4.5)
    if st["band"] not in ("client",):
        p["fill"] = band(st)
    return p


# ---------------------------------------------------------------------------------------------------------------
# the atlas
# ---------------------------------------------------------------------------------------------------------------
def pack(pcs, width=256):
    """Shelves, 2 px apart; each piece's edge pixels copied into its gap (no bleeding when stretched)."""
    items = sorted(pcs.items(), key=lambda kv: (-kv[1].shape[0], kv[0]))
    x = y = 0
    shelf = 0
    places = {}
    for name, a in items:
        h, w = a.shape[:2]
        if x + w + 2 > width:
            x, y, shelf = 0, y + shelf + 2, 0
        places[name] = (x + 1, y + 1, w, h)
        x += w + 2
        shelf = max(shelf, h)
    height = 1
    while height < y + shelf + 2:
        height *= 2
    atlas = np.zeros((height, width, 4))
    for name, (x, y, w, h) in places.items():
        a = pcs[name]
        atlas[y:y + h, x:x + w] = a
        atlas[y - 1, x:x + w] = a[0]
        atlas[y + h, x:x + w] = a[-1]
        atlas[y - 1:y + h + 1, x - 1] = atlas[y - 1:y + h + 1, x]
        atlas[y - 1:y + h + 1, x + w] = atlas[y - 1:y + h + 1, x + w - 1]
    return atlas, places


def save(a, path):
    Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA").save(path)
    print("wrote", path)


def lua_table(sets):
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("Data/ClassicArt.lua", ...) then return end -- DisasterZone: the '
        "Classic look's Dock art (UI/DockArt.lua):",
        "-- where each piece is in Media/Classic/<set>.tga (x, y, w, h in px; 2 px per UI px at a 36 px button).",
        "-- AUTO-GENERATED by gen_classic_media.py; do not edit by hand.",
        "local _, ns = ...",
        "ns.Data = ns.Data or {}",
        "ns.Data.ClassicArt = {",
        "    d = %d, B = %d, F = %d, TR = %d, C = %d," % (D, B, F, TR, C),
    ]
    for key in SET_KEYS:
        st, (w, h, places) = SETS[key], sets[key]
        lines.append("    %s = {" % key)
        lines.append('        w = %d, h = %d, caps = "%s", band = "%s", cells = "%s", rivetAt = %s,'
                     % (w, h, st["caps"], st["band"], st["cells"],
                        ("{ %g, %g }" % st["rivet"]) if st["rivet"] else "nil"))
        lines.append("        p = {")
        for name in sorted(places):
            x, y, pw, ph = places[name]
            lines.append("            %s = { %d, %d, %d, %d }," % (name, x, y, pw, ph))
        lines.append("        },")
        lines.append("    },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sets = {}
    for key in SET_KEYS:
        atlas, places = pack(pieces(key))
        save(atlas, OUT / ("%s.tga" % key))
        save(np.dstack([ground(key), np.full((256, 256), 255)]), OUT / ("%s_ground.tga" % key))
        sets[key] = (atlas.shape[1], atlas.shape[0], places)
    DATA.write_bytes(lua_table(sets).encode("utf-8"))
    print("wrote", DATA)


if __name__ == "__main__":
    main()
