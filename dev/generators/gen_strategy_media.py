"""Draws the strategy board's shape textures (Addendum K) into addon/DisasterZone/Media/Strategy/.

disc.tga  - a white filled circle with a soft edge (zones, tinted by vertex colour)
ring.tga  - a white circle outline (zone borders)
arrow.tga - a white arrowhead pointing up (arrow ends, rotated in game)
sync.tga  - the top bar's sync mark: two arrows chasing clockwise (spun in game)
check.tga - the top bar's "shared" check (drawn on left to right in game)
The shapes are 128x128 32-bit TGA (power of two, straight alpha), drawn 4x oversampled for smooth edges.
tools.tga - the addon's icons (UI.ICON_ATLAS): a 256x1024 grid of 4x16 cells of 64px, white on transparent (tinted
            in game), in the order of TOOL_ICONS below (UI:IconCoords(index); UI.ICON names the shared ones).
"""
import math
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "addon", "DisasterZone", "Media", "Strategy")
SIZE, OS = 128, 4


def shape(draw_fn):
    big = Image.new("L", (SIZE * OS, SIZE * OS), 0)
    draw_fn(ImageDraw.Draw(big), SIZE * OS)
    alpha = big.resize((SIZE, SIZE), Image.LANCZOS)
    img = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    img.putalpha(alpha)
    return img


def disc(d, n):
    m = n * 0.02
    d.ellipse([m, m, n - m, n - m], fill=255)


def ring(d, n):
    m = n * 0.02
    w = n * 0.06
    d.ellipse([m, m, n - m, n - m], fill=255)
    d.ellipse([m + w, m + w, n - m - w, n - m - w], fill=0)


def arrow(d, n):
    d.polygon([(n * 0.5, n * 0.06), (n * 0.92, n * 0.94), (n * 0.5, n * 0.74), (n * 0.08, n * 0.94)], fill=255)


def sync(d, n):
    # the sync mark (UI/MainFrame.lua): two arrows chasing each other clockwise, symmetric under a half turn and
    # inside the inscribed circle, so it can spin on its own texture
    c, r, w = n / 2, n * 0.31, n * 0.09
    head, half = n * 0.17, n * 0.125
    for start in (196, 16):
        end = start + 122
        d.arc([c - r, c - r, c + r, c + r], start, end, fill=255, width=int(w))
        a = math.radians(end - 3)                  # the head's base sits on the stroke's end
        bx, by = c + r * math.cos(a), c + r * math.sin(a)
        nx, ny = math.cos(a), math.sin(a)          # outward
        tx, ty = -math.sin(a), math.cos(a)         # clockwise (screen y down)
        d.polygon([(bx + tx * head, by + ty * head), (bx + nx * half, by + ny * half),
                   (bx - nx * half, by - ny * half)], fill=255)


def check(d, n):
    # the "shared" check (UI/MainFrame.lua): drawn left to right in game, so the short stroke comes first
    pts = [(n * 0.13, n * 0.53), (n * 0.38, n * 0.78), (n * 0.87, n * 0.25)]
    w = n * 0.125
    d.line(pts, fill=255, width=int(w), joint="curve")
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)


# --- toolbar icons, drawn in a 64-unit box scaled by k ---
def _w(k, v):
    return max(1, int(round(v * k)))


def _pts(k, pts):
    return [(x * k, y * k) for x, y in pts]


def ic_select(d, k):
    d.polygon(_pts(k, [(18, 6), (18, 52), (29, 42), (37, 58), (45, 54), (37, 39), (51, 39)]), fill=255)


def ic_pan(d, k):
    c = 32
    d.line(_pts(k, [(c, 12), (c, 52)]), fill=255, width=_w(k, 5))
    d.line(_pts(k, [(12, c), (52, c)]), fill=255, width=_w(k, 5))
    for x, y, ang in ((c, 5, 0), (c, 59, 180), (5, c, 270), (59, c, 90)):
        a = math.radians(ang)
        tri = [(0, 0), (-9, 11), (9, 11)]
        d.polygon(_pts(k, [(x + px * math.cos(a) - py * math.sin(a), y + px * math.sin(a) + py * math.cos(a))
                           for px, py in tri]), fill=255)


def ic_circle(d, k):
    d.ellipse(_pts(k, [(10, 10), (54, 54)]), outline=255, width=_w(k, 5))


def ic_rect(d, k):
    d.rectangle(_pts(k, [(9, 14), (55, 50)]), outline=255, width=_w(k, 5))


def ic_arrow(d, k):
    d.line(_pts(k, [(12, 52), (42, 22)]), fill=255, width=_w(k, 5))
    d.polygon(_pts(k, [(54, 10), (28, 16), (48, 36)]), fill=255)


def ic_line(d, k):
    d.line(_pts(k, [(12, 52), (52, 12)]), fill=255, width=_w(k, 5))
    for x, y in ((12, 52), (52, 12)):
        d.ellipse(_pts(k, [(x - 6, y - 6), (x + 6, y + 6)]), fill=255)


def ic_icon(d, k):
    # a map pin
    d.ellipse(_pts(k, [(15, 5), (49, 39)]), fill=255)
    d.polygon(_pts(k, [(17, 28), (47, 28), (32, 59)]), fill=255)
    d.ellipse(_pts(k, [(25, 15), (39, 29)]), fill=0)


def _glyph(d, k, ch, size):
    f = ImageFont.truetype("arialbd.ttf", int(size * k))
    l, t, r, b = d.textbbox((0, 0), ch, font=f)
    d.text(((64 * k - (r - l)) / 2 - l, (64 * k - (b - t)) / 2 - t), ch, font=f, fill=255)


def ic_text(d, k):
    _glyph(d, k, "T", 48)


def ic_undo(d, k):
    d.arc(_pts(k, [(14, 16), (54, 56)]), 190, 90, fill=255, width=_w(k, 5))
    d.polygon(_pts(k, [(4, 34), (26, 34), (15, 18)]), fill=255)


def ic_redo(d, k):
    d.arc(_pts(k, [(10, 16), (50, 56)]), 90, 350, fill=255, width=_w(k, 5))
    d.polygon(_pts(k, [(60, 34), (38, 34), (49, 18)]), fill=255)


def ic_help(d, k):
    d.ellipse(_pts(k, [(5, 5), (59, 59)]), outline=255, width=_w(k, 4))
    _glyph(d, k, "?", 36)


def ic_trash(d, k):
    d.rectangle(_pts(k, [(11, 13), (53, 19)]), fill=255)
    d.rectangle(_pts(k, [(25, 7), (39, 13)]), fill=255)
    d.polygon(_pts(k, [(15, 22), (49, 22), (46, 58), (18, 58)]), fill=255)
    for x in (25, 32, 39):
        d.line(_pts(k, [(x, 28), (x, 52)]), fill=0, width=_w(k, 3))


def ic_gear(d, k):
    c = 32
    for i in range(8):
        a = math.radians(i * 45)
        pts = []
        for da, r in ((-13, 18), (-9, 29), (9, 29), (13, 18)):
            aa = a + math.radians(da)
            pts.append((c + r * math.cos(aa), c + r * math.sin(aa)))
        d.polygon(_pts(k, pts), fill=255)
    d.ellipse(_pts(k, [(12, 12), (52, 52)]), fill=255)
    d.ellipse(_pts(k, [(23, 23), (41, 41)]), fill=0)


def ic_chevron(d, k):
    d.line(_pts(k, [(14, 24), (32, 42), (50, 24)]), fill=255, width=_w(k, 7), joint="curve")


def ic_eye(d, k):
    # open (look at it): an almond with a pupil
    lens = [(32 + 34 * math.cos(math.radians(a)), 49 + 34 * math.sin(math.radians(a))) for a in range(210, 331, 4)]
    lens += [(32 + 34 * math.cos(math.radians(a)), 15 + 34 * math.sin(math.radians(a))) for a in range(30, 151, 4)]
    d.polygon(_pts(k, lens), fill=255)
    d.ellipse(_pts(k, [(21, 21), (43, 43)]), fill=0)
    d.ellipse(_pts(k, [(27, 27), (37, 37)]), fill=255)


def ic_pencil(d, k):
    d.polygon(_pts(k, [(16, 38), (40, 14), (50, 24), (26, 48)]), fill=255)
    d.polygon(_pts(k, [(8, 56), (13, 41), (23, 51)]), fill=255)
    d.polygon(_pts(k, [(43, 11), (48, 6), (58, 16), (53, 21)]), fill=255)


def ic_copy(d, k):
    d.rectangle(_pts(k, [(8, 6), (40, 44)]), outline=255, width=_w(k, 5))
    d.rectangle(_pts(k, [(19, 15), (60, 62)]), fill=0)
    d.rectangle(_pts(k, [(24, 20), (56, 58)]), fill=255)


def ic_share(d, k):
    # one to two: three dots and their links
    d.line(_pts(k, [(48, 13), (15, 32), (48, 51)]), fill=255, width=_w(k, 4), joint="curve")
    for x, y in ((48, 13), (15, 32), (48, 51)):
        d.ellipse(_pts(k, [(x - 9, y - 9), (x + 9, y + 9)]), fill=255)


def ic_invite(d, k):
    # a player and a plus
    d.ellipse(_pts(k, [(11, 8), (35, 32)]), fill=255)
    d.pieslice(_pts(k, [(3, 36), (43, 80)]), 180, 360, fill=255)
    d.line(_pts(k, [(50, 20), (50, 44)]), fill=255, width=_w(k, 6))
    d.line(_pts(k, [(38, 32), (62, 32)]), fill=255, width=_w(k, 6))


def ic_calloff(d, k):
    # a calendar page with a cross
    d.rectangle(_pts(k, [(8, 12), (56, 57)]), outline=255, width=_w(k, 5))
    d.rectangle(_pts(k, [(8, 12), (56, 24)]), fill=255)
    for x in (20, 44):
        d.rectangle(_pts(k, [(x - 3, 5), (x + 3, 16)]), fill=255)
    d.line(_pts(k, [(23, 32), (41, 49)]), fill=255, width=_w(k, 5))
    d.line(_pts(k, [(41, 32), (23, 49)]), fill=255, width=_w(k, 5))


def ic_dice(d, k):
    # games: a die showing five
    d.rounded_rectangle(_pts(k, [(8, 8), (56, 56)]), radius=10 * k, fill=255)
    for x, y in ((20, 20), (44, 20), (32, 32), (20, 44), (44, 44)):
        d.ellipse(_pts(k, [(x - 5, y - 5), (x + 5, y + 5)]), fill=0)


def _star4(d, k, cx, cy, r, w):
    d.polygon(_pts(k, [(cx, cy - r), (cx + w, cy - w), (cx + r, cy), (cx + w, cy + w),
                       (cx, cy + r), (cx - w, cy + w), (cx - r, cy), (cx - w, cy - w)]), fill=255)


def ic_disenchant(d, k):
    # disenchant: a big and a small sparkle
    _star4(d, k, 26, 36, 22, 6)
    _star4(d, k, 48, 14, 11, 3)


def ic_bank(d, k):
    # guild bank: a roof, four columns and a base
    d.polygon(_pts(k, [(32, 4), (60, 20), (4, 20)]), fill=255)
    for x in (12, 25, 39, 52):
        d.rectangle(_pts(k, [(x - 4, 24), (x + 4, 48)]), fill=255)
    d.rectangle(_pts(k, [(4, 52), (60, 60)]), fill=255)


def ic_more(d, k):
    # more actions: three dots
    for x in (12, 32, 52):
        d.ellipse(_pts(k, [(x - 7, 25), (x + 7, 39)]), fill=255)


def ic_notes(d, k):
    # what's new: a page with a folded corner and text lines
    d.polygon(_pts(k, [(10, 4), (42, 4), (54, 16), (54, 60), (10, 60)]), fill=255)
    d.polygon(_pts(k, [(42, 4), (42, 16), (54, 16)]), fill=0)
    for y, x2 in ((26, 44), (36, 44), (46, 34)):
        d.rectangle(_pts(k, [(18, y), (x2, y + 4)]), fill=0)


def ic_crown(d, k):
    # the raid leader: a crown with three points on a band
    d.polygon(_pts(k, [(6, 18), (20, 32), (32, 10), (44, 32), (58, 18), (52, 48), (12, 48)]), fill=255)
    d.rectangle(_pts(k, [(12, 52), (52, 58)]), fill=255)
    for x, y in ((6, 18), (32, 10), (58, 18)):
        d.ellipse(_pts(k, [(x - 5, y - 5), (x + 5, y + 5)]), fill=255)


def _turn(d, k, sign):
    # the 3D view's turn buttons: a circular arrow, round the left (sign 1) or the right (-1)
    box = _pts(k, [(10, 12), (54, 56)])
    if sign > 0:
        d.arc(box, 300, 200, fill=255, width=_w(k, 5))
        d.polygon(_pts(k, [(4, 26), (22, 26), (11, 9)]), fill=255)
    else:
        d.arc(box, 340, 240, fill=255, width=_w(k, 5))
        d.polygon(_pts(k, [(60, 26), (42, 26), (53, 9)]), fill=255)


def ic_turn_left(d, k):
    _turn(d, k, 1)


def ic_turn_right(d, k):
    _turn(d, k, -1)


def ic_top(d, k):
    # from above: an arrow down onto the floor seen at a slant
    d.polygon(_pts(k, [(14, 44), (58, 44), (50, 60), (6, 60)]), outline=255, width=_w(k, 4))
    d.line(_pts(k, [(32, 4), (32, 30)]), fill=255, width=_w(k, 6))
    d.polygon(_pts(k, [(20, 26), (44, 26), (32, 40)]), fill=255)


def ic_home(d, k):
    # the whole room: a house
    d.polygon(_pts(k, [(32, 6), (60, 30), (4, 30)]), fill=255)
    d.rectangle(_pts(k, [(12, 30), (52, 58)]), fill=255)
    d.rectangle(_pts(k, [(26, 40), (38, 58)]), fill=0)


def ic_minimap(d, k):
    # the small map: a framed map with where you are on it
    d.rectangle(_pts(k, [(6, 10), (58, 54)]), outline=255, width=_w(k, 4))
    d.line(_pts(k, [(6, 32), (30, 24), (58, 36)]), fill=255, width=_w(k, 2))
    d.polygon(_pts(k, [(36, 18), (44, 40), (36, 34), (28, 40)]), fill=255)


def _tray(d, k):
    # an open tray: the bottom and two short sides
    d.line(_pts(k, [(8, 36), (8, 57), (56, 57), (56, 36)]), fill=255, width=_w(k, 6), joint="curve")


def ic_import(d, k):
    # import (My BiS): an arrow down into a tray
    d.line(_pts(k, [(32, 4), (32, 32)]), fill=255, width=_w(k, 7))
    d.polygon(_pts(k, [(19, 27), (45, 27), (32, 44)]), fill=255)
    _tray(d, k)


def ic_export(d, k):
    # export (My BiS): an arrow up out of a tray
    d.line(_pts(k, [(32, 46), (32, 18)]), fill=255, width=_w(k, 7))
    d.polygon(_pts(k, [(19, 21), (45, 21), (32, 4)]), fill=255)
    _tray(d, k)


def ic_handle_turn(d, k):
    # a 3D model's turn knob: a ring of arrow, a head at either end (it turns both ways)
    d.arc(_pts(k, [(10, 10), (54, 54)]), 190, 330, fill=255, width=_w(k, 7))
    d.arc(_pts(k, [(10, 10), (54, 54)]), 10, 150, fill=255, width=_w(k, 7))
    d.polygon(_pts(k, [(40, 22), (62, 22), (51, 38)]), fill=255)
    d.polygon(_pts(k, [(2, 42), (24, 42), (13, 26)]), fill=255)


def ic_handle_size(d, k):
    # a 3D model's size knob: a diagonal arrow with a head at both ends (bigger or smaller)
    d.line(_pts(k, [(18, 46), (46, 18)]), fill=255, width=_w(k, 7))
    d.polygon(_pts(k, [(6, 58), (6, 32), (32, 58)]), fill=255)
    d.polygon(_pts(k, [(58, 6), (58, 32), (32, 6)]), fill=255)


def _limb(d, k, pts, w):
    # a line through pts with round ends and joints
    d.line(_pts(k, pts), fill=255, width=_w(k, w))
    for x, y in pts:
        d.ellipse(_pts(k, [(x - w / 2, y - w / 2), (x + w / 2, y + w / 2)]), fill=255)


def ic_walk(d, k):
    # the 3D view's walk button: a figure striding out over the ring it lands in (dragged into the room)
    d.ellipse(_pts(k, [(8, 52), (56, 63)]), outline=255, width=_w(k, 3))
    d.ellipse(_pts(k, [(30, 1), (42, 13)]), fill=255)                  # head
    _limb(d, k, [(34, 19), (30, 34)], 9)                              # body
    _limb(d, k, [(33, 22), (40, 29), (46, 27)], 5)                    # front arm
    _limb(d, k, [(32, 22), (25, 29), (21, 35)], 5)                    # back arm
    _limb(d, k, [(30, 35), (38, 44), (41, 55)], 6)                    # front leg
    _limb(d, k, [(29, 35), (24, 45), (16, 52)], 6)                    # back leg


# (the strategy board's chrome, 2026-10-06; every new cell keeps 4 units clear of its edges, so the cells around it
# come out byte for byte as before)
def ic_target(d, k):
    # Practice: a target, two rings and four ticks
    for r in (22, 10):
        d.ellipse(_pts(k, [(32 - r - 3, 32 - r - 3), (32 + r + 3, 32 + r + 3)]), outline=255, width=_w(k, 6))
    for a, b in (((32, 4), (32, 16)), ((32, 48), (32, 60)), ((4, 32), (16, 32)), ((48, 32), (60, 32))):
        d.line(_pts(k, [a, b]), fill=255, width=_w(k, 6))


def ic_keys(d, k):
    # Keyboard and mouse: a keyboard, a row of keys and the space bar
    d.rounded_rectangle(_pts(k, [(4, 14), (60, 50)]), radius=6 * k, outline=255, width=_w(k, 5))
    for x0, x1 in ((13, 20), (24, 31), (35, 42), (46, 52)):
        d.rectangle(_pts(k, [(x0, 22), (x1, 29)]), fill=255)
    d.rectangle(_pts(k, [(18, 35), (46, 42)]), fill=255)


def ic_plus(d, k):
    # New strategy: a plus
    d.rectangle(_pts(k, [(28, 8), (36, 56)]), fill=255)
    d.rectangle(_pts(k, [(8, 28), (56, 36)]), fill=255)


def _bag(d, k):
    # a shopping bag: an outlined body, narrower at the bottom, and a handle over it
    d.line(_pts(k, [(10, 22), (54, 22), (50, 58), (14, 58), (10, 22)]), fill=255, width=_w(k, 6), joint="curve")
    d.arc(_pts(k, [(21, 6), (43, 32)]), 180, 360, fill=255, width=_w(k, 6))
    d.line(_pts(k, [(21, 19), (21, 30)]), fill=255, width=_w(k, 6))
    d.line(_pts(k, [(43, 19), (43, 30)]), fill=255, width=_w(k, 6))


def ic_bag(d, k):
    # the shopping list (Atlas)
    _bag(d, k)


def ic_bag_add(d, k):
    # add to the shopping list: the bag with a plus inside
    _bag(d, k)
    d.rectangle(_pts(k, [(29, 31), (35, 51)]), fill=255)
    d.rectangle(_pts(k, [(22, 38), (42, 44)]), fill=255)


def ic_whisper(d, k):
    # whisper: a speech bubble with its tail at the bottom left
    d.rounded_rectangle(_pts(k, [(6, 8), (58, 44)]), radius=_w(k, 9), fill=255)
    d.polygon(_pts(k, [(14, 40), (30, 40), (12, 58)]), fill=255)


def _almond():
    # the lids of an eye: two arcs meeting at the corners (2.6, 32) and (61.4, 32), 15..49 tall
    upper = [(32 + 34 * math.cos(math.radians(a)), 49 + 34 * math.sin(math.radians(a))) for a in range(210, 331, 3)]
    lower = [(32 + 34 * math.cos(math.radians(a)), 15 + 34 * math.sin(math.radians(a))) for a in range(30, 151, 3)]
    return upper + lower


def ic_finder_eye(d, k):
    # the Group Finder (Blizzard's LFG eye, flat): the lids only; its iris is the next cell, moved in game
    pts = _pts(k, _almond())
    d.line(pts + [pts[0]], fill=255, width=_w(k, 5), joint="curve")


def ic_finder_iris(d, k):
    # the Group Finder eye's iris: drawn over the lids, it looks left and right (up to 10 units) while listed
    d.ellipse(_pts(k, [(22, 22), (42, 42)]), fill=255)


TOOL_ICONS = [ic_select, ic_pan, ic_circle, ic_rect, ic_arrow, ic_line, ic_icon, ic_text,
              ic_undo, ic_redo, ic_help, ic_trash, ic_gear, ic_chevron, ic_eye, ic_pencil,
              ic_copy, ic_share, ic_invite, ic_calloff, ic_dice, ic_disenchant, ic_bank, ic_more,
              ic_notes, ic_crown, ic_turn_left, ic_turn_right, ic_top, ic_home, ic_minimap, ic_import,
              ic_export, ic_handle_turn, ic_handle_size, ic_walk, ic_target, ic_keys, ic_plus,
              ic_bag, ic_bag_add, ic_whisper, ic_finder_eye, ic_finder_iris]
TOOL_ROWS = 16   # power of two (the texture is 256 x 64*rows); UI/Widgets.lua UI.ICON_ROWS must match


def tool_atlas():
    cell = 64
    big = Image.new("L", (cell * 4 * OS, cell * TOOL_ROWS * OS), 0)
    for i, fn in enumerate(TOOL_ICONS):
        sub = Image.new("L", (cell * OS, cell * OS), 0)
        fn(ImageDraw.Draw(sub), OS)
        big.paste(sub, ((i % 4) * cell * OS, (i // 4) * cell * OS))
    alpha = big.resize((cell * 4, cell * TOOL_ROWS), Image.LANCZOS)
    img = Image.new("RGBA", alpha.size, (255, 255, 255, 0))
    img.putalpha(alpha)
    return img


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in (("disc", disc), ("ring", ring), ("arrow", arrow), ("sync", sync), ("check", check)):
        shape(fn).save(os.path.join(OUT, name + ".tga"))
        print("wrote", name)
    tool_atlas().save(os.path.join(OUT, "tools.tga"))
    print("wrote tools")
