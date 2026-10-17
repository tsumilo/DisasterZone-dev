"""Redraw the 5 in Azeromon's Pixelify Sans cuts (DisasterZone_Azeromon/Media/fonts).

The static Medium / SemiBold instances shipped with a broken "five": a rounded top and a step in the middle, so it read
as a mirrored S next to the other digits. This replaces it with a plain pixel 5 on the same grid as that cut's 6
(square top bar and stem, the 6's middle bar and bowl, the 3/9 bottom-left hook). Safe to run again: the outline is
rebuilt from the 6 every time.

    python generators/azeromon_font_five.py
"""
import os

from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

FONTS = os.path.join(os.path.dirname(__file__), "..", "..", "addon", "DisasterZone_Azeromon", "Media", "fonts")
CUTS = ("PixelifySans-Medium.ttf", "PixelifySans-SemiBold.ttf")


def grid_from_six(font):
    """The 6's columns and rows: outer/inner/corner x, and the bottom, bowl, middle bar and top y."""
    pen = RecordingPen()
    font.getGlyphSet()["six"].draw(pen)
    outer = [args[0] for op, args in pen.value if args][:20]   # first contour = the outline, second = the bowl
    # six: (cx,y0) (cx,yc) (x0,yc) (x0,yC) (cx,yC) (cx,y7) (rx,y7) (rx,yC) (x1,yC) (x1,..) (ri,..) (ri,y6) (xi,y6)
    #      (xi,ym) (rx,ym) (rx,yb) (x1,yb) (x1,yc) (rx,yc) (rx,y0)
    (cx, y0), (_, yc), (x0, _), _, _, (_, y7), (rx, _), (_, yC), (x1, _), _, (ri, _), (_, y6), (xi, _), \
        (_, ym), _, (_, yb), _, _, _, _ = outer
    bowl = [args[0] for op, args in pen.value if args][20:]
    (_, yi), _, (_, yt), _ = bowl                              # bowl inside: bottom and top
    return dict(x0=x0, xi=xi, cx=cx, ri=ri, rx=rx, x1=x1, y0=y0, yc=yc, yi=yi, yt=yt, yb=yb, ym=ym, y6=y6, y7=y7)


def hook_top(font):
    """How high the bottom-left hook of the 3 reaches (the 9 and the old 5 share it)."""
    pen = RecordingPen()
    font.getGlyphSet()["three"].draw(pen)
    return [args[0] for op, args in pen.value if args][3][1]


def five_points(g, hook):
    """One clockwise contour: bottom bar with the hook, bowl, middle bar, stem, flat top bar."""
    return [
        (g["cx"], g["y0"]), (g["cx"], g["yc"]), (g["x0"], g["yc"]), (g["x0"], hook), (g["xi"], hook),
        (g["xi"], g["yi"]), (g["ri"], g["yi"]), (g["ri"], g["yt"]), (g["x0"], g["yt"]), (g["x0"], g["y7"]),
        (g["x1"], g["y7"]), (g["x1"], g["y6"]), (g["xi"], g["y6"]), (g["xi"], g["ym"]), (g["rx"], g["ym"]),
        (g["rx"], g["yb"]), (g["x1"], g["yb"]), (g["x1"], g["yc"]), (g["rx"], g["yc"]), (g["rx"], g["y0"]),
    ]


def fix(path):
    font = TTFont(path)
    pts = five_points(grid_from_six(font), hook_top(font))
    pen = TTGlyphPen(font.getGlyphSet())
    pen.moveTo(pts[0])
    for p in pts[1:]:
        pen.lineTo(p)
    pen.closePath()
    glyph = pen.glyph()
    font["glyf"]["five"] = glyph
    glyph.recalcBounds(font["glyf"])
    adv, _ = font["hmtx"]["five"]
    font["hmtx"]["five"] = (adv, glyph.xMin)
    font.save(path)
    print("redrew five in", os.path.basename(path), pts)


if __name__ == "__main__":
    for cut in CUTS:
        fix(os.path.normpath(os.path.join(FONTS, cut)))
