"""Portal crawler prototype: renders the Ramparts encounter (Games/Trainer/Encounters/HellfireRamparts.lua) from the
mock with render_check's two renderers (truth: the room z-buffered with its real textures; painter: what the addon's
UI widgets draw), at the entrance and in the middle of the fight, plus Lua time per frame. Models are drawn as
flat magenta stand-ins (the mock has no 3D models): judge the room, the camera and where everyone stands.
Run: python proto_render.py -> shots/*.png"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))
import render_check as RC  # noqa: E402

RC.ENC_DIFF["ramparts"] = "p0"
OUT = os.path.join(HERE, "shots")


def shot(sess, name):
    counts, ms = sess.frame()
    cap = sess.capture()
    tr, pt, res = RC.analyse(sess, cap, backfaces=True)
    base = os.path.join(OUT, name)
    RC.save_png(base + "_truth.png", RC.picture_truth(sess.mesh, tr, sess.g))
    RC.save_png(base + "_painter.png", RC.picture_painter(sess.mesh, cap, pt, sess.g))
    print("%-10s lua %.1f ms/frame, %d API calls, wrong %.1f%%, holes %.1f%%" % (
        name, ms, sum(counts.values()), res.get("wrongSurfacePct", 0), res.get("holesPct", 0)))


def main():
    os.makedirs(OUT, exist_ok=True)
    sess = RC.Session("ramparts", (960, 600), 1.0)
    c = sess.c
    for _ in range(3):
        sess.frame()
    shot(sess, "1_entrance")
    # walk north-west toward the pack (the keys move on the screen's directions) and let the fight start
    c.eval("ns.TrainerUI._Sim():SetMove(-0.55, 1)")
    for _ in range(60):
        c.eval("ns.TrainerUI._Tick(0.05)")
    c.eval("local s = ns.TrainerUI._Sim(); s:SetMove(0, 0); for _, u in ipairs(s.units) do "
           "if u.kind == 'mob' and not u.dead then s:SetTarget(u) break end end")
    for _ in range(30):
        c.eval("ns.TrainerUI._Tick(0.05)")
    print(c.eval("local s = ns.TrainerUI._Sim(); local o = {} for _, u in ipairs(s.units) do "
                 "o[#o+1] = string.format('%s %.0f,%.0f hp %s%s', u.name, u.x, u.y, tostring(u.hp), u.dead and ' dead' or '') "
                 "end return table.concat(o, ' | ')"))
    shot(sess, "2_fight")


if __name__ == "__main__":
    main()
