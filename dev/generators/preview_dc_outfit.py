"""preview_dc_outfit.py out.png sex item,item,...: the hero sprite stacked from OutfitData.lua like Outfit.lua does
(the bare body, then the items' layers in paint order), all 8 x 4 frames, scaled up x4."""
import os
import re
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import azw_render as RD  # noqa: E402

ADDON = os.path.join(HERE, "..", "..", "addon", "DisasterZone")


def main():
    out, sex, ids = sys.argv[1], int(sys.argv[2]), [int(x) for x in sys.argv[3].split(",") if x]
    s = open(os.path.join(ADDON, "Games", "Disastercraft", "OutfitData.lua"), encoding="utf-8").read()
    layers = {int(m.group(1)): list(map(int, m.group(2).split(",")))
              for m in re.finditer(r"^L\[(\d+)\] = \{ ([\d,]+) \}", s, re.M)}
    body = {int(a): int(b) for a, b in re.findall(r"O\.body\[(\d)\] = (\d+)", s)}
    items = {(int(a), int(b)): int(c) for a, b, c in re.findall(r"O\.items\[(\d)\]\[(\d+)\] = (\d+)", s)}
    order = {int(k): int(v) for k, v in re.findall(r"\[(\d+)\] = (\d+)", re.search(r"O\.order = \{([^}]*)\}", s).group(1))}
    d = open(os.path.join(ADDON, "Games", "Disastercraft", "Data.lua"), encoding="utf-8").read()
    inv = {int(m.group(1)): int(m.group(2)) for m in re.finditer(r"^I\[(\d+)\] = \{[^\n]*?\binv = (\d+)", d, re.M)}
    sheets = {}

    def sheet(n):
        if n not in sheets:
            p = os.path.join(ADDON, "Media", "Azeromon", "Outfit", "outfit%d.blp" % n)
            sheets[n] = np.asarray(RD.open_blp(open(p, "rb").read()).convert("RGBA"))
        return sheets[n]
    worn = sorted([e for e in ids if (sex, e) in items], key=lambda e: order.get(inv.get(e, 0), 0))
    stack = [layers[body[sex]]] + [layers[items[(sex, e)]] for e in worn]
    img = Image.new("RGBA", (8 * 32, 4 * 32), (60, 90, 50, 255))
    for k in range(32):
        col, face = k // 4, k % 4
        for l in stack:
            n, x, y, w, h, ox, oy = l[k * 7:k * 7 + 7]
            if n:
                piece = Image.fromarray(sheet(n)[y:y + h, x:x + w].copy(), "RGBA")
                img.alpha_composite(piece, (col * 32 + ox, face * 32 + oy))
    img.resize((img.width * 4, img.height * 4), Image.NEAREST).save(out)


if __name__ == "__main__":
    main()
