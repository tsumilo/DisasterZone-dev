"""The Portal's hub: renders the Stair of Destiny room (Render3D/Rooms/Portal_StairOfDestiny.lua, gen_dungeon_proto.py
hub) with the real textures: a high overview to read the layout, and the game's own fixed camera at the arrival point.
Run: python hub_look.py -> shots/hub_*.png"""
import os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import look_render as L  # noqa: E402  (sets DISASTERZONE_ROOMS, imports the harness)
from harness import World, Client  # noqa: E402
import render_check as RC  # noqa: E402

KEY = "Portal_StairOfDestiny"
SER = """
local m = ns.Render3D.Floor({ floor = '%s' }).mesh
local fmt = string.format
local v, t, x = {}, {}, {}
for i = 1, #m.verts do v[i] = fmt('%%.10g', m.verts[i]) end
for i = 1, #m.tris do t[i] = tostring(m.tris[i]) end
for i = 1, #m.textures do x[i] = tostring(m.textures[i]) end
return table.concat(v, ' ') .. '|' .. table.concat(t, ' ') .. '|' .. table.concat(x, ' ')
""" % KEY


def main():
    w = World()
    c = Client(w, "Alice", class_file="PALADIN", guild_rank=3)
    c.load_addon()
    w.tick(1)
    text = c.eval(SER)
    mesh = RC.Mesh.from_text(text)
    mesh.texof = np.array(text.split("|")[1].split(), int).reshape(-1, 4)[:, 3]
    out = os.path.join(HERE, "shots")
    ex, ey = 64.8, 49.55
    import math
    for name, pitch, dist, tx, ty in (("hub_game", 0.45, 55, ex, ey), ("hub_close", 0.7, 30, ex, ey)):
        L.PITCH, L.DIST, L.YAW = pitch, dist, math.pi
        L.render(mesh, (tx, ty, 2.2), [("You arrive here", ex, ey, 0, (90, 230, 90))], os.path.join(out, name + ".png"),
                 "The Stair of Destiny (%s)" % name.split("_")[1])


if __name__ == "__main__":
    main()
