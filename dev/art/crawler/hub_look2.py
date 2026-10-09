"""The Portal's hub as the game camera sees it: the live floor (Portal_StairOfDestiny) + the pre-rendered facade in
the gate's plane, real textures. Run: python hub_look2.py -> shots/hub2_*.png"""
import math, os, sys
import numpy as np
from PIL import Image
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import look_render as L  # noqa: E402
import hub_look as HL  # noqa: E402
from harness import World, Client  # noqa: E402
import render_check as RC  # noqa: E402

GATE_X = 131.2
PARTS = [("Facade_Low.png", 215, -65, -2.35, 137.65), ("Facade_High.png", 215, -65, 137.65, 277.65)]


def main():
    w = World()
    c = Client(w, "Alice", class_file="PALADIN", guild_rank=3)
    c.load_addon()
    w.tick(1)
    text = c.eval(HL.SER)
    mesh = RC.Mesh.from_text(text)
    mesh.texof = np.array(text.split("|")[1].split(), int).reshape(-1, 4)[:, 3]
    quads = []
    for f, yl, yr, z0, z1 in PARTS:
        pic = np.asarray(Image.open(os.path.join(HERE, "shots", f)).convert("RGBA"), np.float32) / 255
        quads.append((((GATE_X, yl, z1), (GATE_X, yl, z0), (GATE_X, yr, z1), (GATE_X, yr, z0)), pic))
    for name, pitch, dist, px, py, pz, fov in (("hub2_start", -0.25, 40, 50, 74.3, -30 + 22, 1.4), ("hub2_mid", -0.2, 40, 85, 74.3, -15.5 + 22, 1.4)):
        L.PITCH, L.DIST, L.YAW, L.FOV = pitch, dist, 0.0, fov
        L.render(mesh, (px, py, pz + 2.2), [("You", px, py, pz - 22, (90, 230, 90))], os.path.join(HERE, "shots", name + ".png"),
                 "The Stair of Destiny (" + name.split("_")[1] + ")", quads=quads)


if __name__ == "__main__":
    main()
