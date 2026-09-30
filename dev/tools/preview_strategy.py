"""Renders a strategy page over its floor map into a PNG, the way the board lays it out (for checking positions
offline). Usage: luaenv\\Scripts\\python.exe tools\\preview_strategy.py <BossRef> [out.png]
Loads the boss' starter strategy (Data/StarterStrategies.lua) through the addon's own loader.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(DEV, "tests", "strategy"))
sys.path.insert(0, os.path.join(DEV, "tests", "raidplan"))
sys.path.insert(0, os.path.join(DEV, "tests", "boot-ui"))
sys.path.insert(0, os.path.join(DEV, "tests", "loot-roll"))

from PIL import Image, ImageDraw  # noqa: E402
from st_common import world  # noqa: E402

COLORS = [(230, 56, 56), (64, 153, 255), (255, 153, 26), (77, 217, 77), (179, 102, 255), (255, 230, 51),
          (51, 230, 230), (255, 115, 191), (255, 255, 255), (153, 153, 153), (153, 102, 56), (13, 13, 13)]
MARKS = {1: "Star", 2: "Circle", 3: "Diamond", 4: "Triangle", 5: "Moon", 6: "Square", 7: "Cross", 8: "Skull"}


def main():
    ref = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(DEV, "art", "preview_%s.png" % ref.replace(":", "_"))
    w, c = world()
    d = c["Bob"].eval_py("local d = ns.StrategyBoard:StarterDraft(...); local maps = {}; "
                         "for _, m in ipairs(ns.Data.RaidMaps) do maps[m.id] = m.file end; "
                         "d.files = {}; for i, p in ipairs(d.p) do d.files[i] = maps[p.m] end; return d", ref)
    src_names = {"Gruul": "3923-1"}
    for pi, p in enumerate(d["p"]):
        file = d["files"][pi + 1] if isinstance(d["files"], dict) else d["files"][pi]
        src = {"Gruul": "3923-1", "Magtheridon": "3836-1"}.get(file, file)
        mp = Image.open(os.path.join(DEV, "art", "blizzard_maps", src + ".jpg")).convert("RGB").resize((1024, 683))
        BW, BH = 1000, 666
        z = p.get("vz", 100) / 100
        base = min(BW / 1024, BH / 683)
        sc = base * z
        cx, cy = p.get("vx", 500) / 1000 * 1024, p.get("vy", 500) / 1000 * 683
        ox, oy = BW / 2 - cx * sc, BH / 2 - cy * sc
        img = Image.new("RGB", (BW, BH))
        big = mp.resize((int(1024 * sc), int(683 * sc)))
        img.paste(big, (int(ox), int(oy)))
        dr = ImageDraw.Draw(img, "RGBA")
        for e in p["e"]:
            col = COLORS[(e.get("c") or (1 if e["t"] == "z" else 9)) - 1]
            if e["t"] == "z":
                box = [e["x"] - e["w"] / 2, e["y"] - e["h"] / 2, e["x"] + e["w"] / 2, e["y"] + e["h"] / 2]
                if e["s"] == "c":
                    dr.ellipse(box, fill=col + (70,), outline=col + (230,), width=3)
                else:
                    dr.rectangle(box, fill=col + (60,), outline=col + (230,), width=3)
                dr.text((e["x"] - 40, e["y"] - 6), e.get("l", ""), fill="white")
            elif e["t"] == "a":
                dr.line([e["x"], e["y"], e["x2"], e["y2"]], fill=col, width=4)
                dr.ellipse([e["x2"] - 6, e["y2"] - 6, e["x2"] + 6, e["y2"] + 6], fill=col)
            elif e["t"] == "i":
                r = e.get("z", 32) / 2
                dr.ellipse([e["x"] - r, e["y"] - r, e["x"] + r, e["y"] + r], fill=(20, 20, 20, 220), outline="yellow")
                tag = MARKS.get(e.get("rm"), "") or e["i"]
                dr.text((e["x"] - r, e["y"] - 5), tag[:10], fill="yellow")
                if e.get("l"):
                    dr.text((e["x"] - 50, e["y"] + r + 2), e["l"], fill="white")
            elif e["t"] == "x":
                dr.text((e["x"] - 120, e["y"] - 6), e["l"], fill=col)
        path = out if len(d["p"]) == 1 else out.replace(".png", "_%d.png" % (pi + 1))
        img.save(path)
        print("wrote", path)


if __name__ == "__main__":
    main()
