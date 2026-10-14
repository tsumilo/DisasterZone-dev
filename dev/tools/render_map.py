"""Renders an Azeromon map to a PNG with the real atlas (a preview without the game client).
Run: luaenv\Scripts\python.exe tools\render_map.py <map id> <out.png> [scale]"""
import os, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "boot-ui"))
from PIL import Image
from _common import solo

ADDON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "addon", "DisasterZone")
atlas = Image.open(os.path.join(ADDON, "Media", "Azeromon", "atlas.tga")).convert("RGBA")
names = dict((m.group(1), int(m.group(2))) for m in re.finditer(r"^\s+(\w+) = (\d+),", open(os.path.join(ADDON, "Games", "Azeromon", "Atlas.lua")).read(), re.M))


def tile(name):
    i = names.get(name)
    if i is None:
        return None
    c, r = i % 16, i // 16
    return atlas.crop((c * 16, r * 16, c * 16 + 16, r * 16 + 16))


def baked_ground(c, map_id):
    """the map's baked ground (gen_azeromon_ground.py) cropped to the map itself, or None"""
    g = c.eval_py("return ns.AzeroGround and ns.AzeroGround[%r]" % map_id)
    if not g:
        return None
    W = max(x + w for x, y, w, h, tw, th in g["chunks"])
    H = max(y + h for x, y, w, h, tw, th in g["chunks"])
    out = Image.new("RGBA", (W, H))
    for x, y, w, h, tw, th in g["chunks"]:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "generators"))
        import azeromon_blp
        f = os.path.join(ADDON, "Media", "Azeromon", "Ground", "%s_%d_%d.blp" % (map_id, x // 256, y // 256))
        out.paste(azeromon_blp.read(f).crop((0, 0, w, h)), (x, y))
    ox, oy = g["mx"] * 16, g["my"] * 16
    return out.crop((ox, oy, W - ox, H - oy))


def render(map_id, out, scale=2, setup=None):
    w, c = solo("Alice", tick=2, members=[("Bob", "MAGE", 3)])
    c.eval("ns.Azero:NewGame()")
    if setup:
        c.eval(setup)
    c.eval("ns.Azero:EnterMap(%r, 1, 1, 'down', true)" % map_id)
    m = c.eval_py("""local m = ns.Azero.map
      local base, over, top = {}, {}, {}
      for y = 0, m.h - 1 do for x = 0, m.w - 1 do
        local k = m.key(x, y)
        base[#base + 1] = m.base[k] or ''
        over[#over + 1] = m.over[k] or ''
        top[#top + 1] = (m.top and m.top[k]) or ''
      end end
      return { w = m.w, h = m.h, base = base, over = over, top = top }""")
    img = Image.new("RGBA", (m["w"] * 16, m["h"] * 16), (0, 0, 0, 255))
    ground = baked_ground(c, map_id)              # the baked picture (gen_azeromon_ground.py) replaces the base tiles
    if ground:
        img.alpha_composite(ground)
    for i in range(m["w"] * m["h"]):
        x, y = (i % m["w"]) * 16, (i // m["w"]) * 16
        for name in ((None if ground else m["base"][i]), m["over"][i]):
            t = name and tile(name)
            if t:
                img.alpha_composite(t, (x, y))
    for i in range(m["w"] * m["h"]):                                  # the canopies, over everything
        t = m["top"][i] and tile(m["top"][i])
        if t:
            img.alpha_composite(t, ((i % m["w"]) * 16, (i // m["w"]) * 16))
    img = img.resize((img.size[0] * scale, img.size[1] * scale), Image.NEAREST)
    img.save(out)
    print("wrote", out, img.size)


if __name__ == "__main__":
    render(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 2, sys.argv[4] if len(sys.argv) > 4 else None)
