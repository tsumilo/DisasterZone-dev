"""Films of the games' animated hub covers, for the launcher's game pages (launcher/ui/films/<id>.webm).

The Games hub draws three covers live in game: Azeromon's film of its real maps (DisasterZone_Azeromon/Poster.lua),
Hold the Line playing itself (HTLUI:NewPoster) and The Binding of Illidan's attract run (BoIUI:NewAttract). This
builds the addon in the test harness, gives each cover a landscape frame the size of the launcher's game hero, steps
its clock frame by frame, draws every frame with tools/ui_look.py (the real textures and fonts) and encodes a VP9
WebM that loops: the last second cross-fades into the first, so the seam can't be seen.

Usage (from dev):  luaenv\\Scripts\\python.exe tools\\film_covers.py [ids...] [--secs N] [--fps N] [--still]
                                                    [--out DIR] [--encode]
  --still   one frame per film (a few seconds in) as PNG: for judging the look and the frame's size quickly.
  --encode  only encode again from the frames a run left in <out>/_frames_<id> (e.g. after changing the bitrate).
Needs imageio-ffmpeg (pip) for the encoder. Blizzard art is read from the client like ui_audit --look does.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from PIL import Image  # noqa: E402

# the frame in UI units; ui_audit.PNG_SCALE (2) makes the video 1040 x 520, the hero's size at the default window
W, H = 520, 260
FPS = 30
STEPS = 2                 # clock steps per video frame (the covers are tuned for small steps)
BLEND = 1.0               # seconds of the loop's cross-fade
# VP9 at constant quality, held under a bitrate: the launcher ships the films (Hold the Line's busy horde took 18 MB
# at quality alone; capped it is a few MB and looks the same at the hero's size)
VIDEO = ["-crf", "36", "-b:v", "900k", "-maxrate", "1100k", "-bufsize", "2200k", "-row-mt", "1", "-deadline", "good",
         "-cpu-used", "2", "-an"]

# id -> (Lua that makes the cover on frame F and returns it, seconds of film)
FILMS = {
    "azeromon": ("return ns.AzeroPoster:New(F)", 38.4),          # 6 shots x (8 s - 1.6 s fade): one full round
    "holdtheline": ("return ns.HTLUI:NewPoster(F)", 32),
    "illidan": ("local c = CreateFrame('Frame', nil, F) c:SetAllPoints(F) c:SetClipsChildren(true) "
                "local d = ns.BoIUI:NewAttract(c) function c:Tick(e) d:Tick(e) end return c", 32),
}

SETUP = """
local F = DZFilm or CreateFrame("Frame", "DZFilm", UIParent)
F:SetSize(%d, %d)
F:ClearAllPoints()
F:SetPoint("CENTER")
F:SetClipsChildren(true)
F:Show()
local bg = F.bg or F:CreateTexture(nil, "BACKGROUND")
F.bg = bg
bg:SetAllPoints(F)
bg:SetColorTexture(0, 0, 0, 1)
local make = loadstring(...)
setfenv(make, setmetatable({ F = F, ns = ns }, { __index = _G }))
ns.__filmCover = make()
ns.__filmCover:Show()
if ns.__filmCover.Layout then ns.__filmCover:Layout(F:GetSize()) end
""" % (W, H)


def world():
    import harness
    import ui_audit
    import ui_look
    sys.path.insert(0, os.path.join(DEV, "tests", "raidplan"))
    from rp_common import World, Client
    harness.LOAD_ROOMS = False
    w = World()
    w.auto_session = False
    g = Client(w, "Gina", guild_rank=0, class_file="PALADIN",
               preload_lua=ui_audit.PRELOAD + ui_audit.metrics_preload() + ui_look.PRELOAD)
    g.load_addon()
    w.tick(3)
    return w, g


def frame(g, out_png):
    """Draw the film frame as it stands now into out_png."""
    import ui_audit
    import ui_look
    regs, ui = ui_audit.capture(g)
    _, lay = ui_audit.audit(regs, ui)
    seq = next(s for s, r in regs.items() if r.get("name") == "DZFilm")
    l, b, w, h = lay.rect(seq)
    ui_look.render(regs, lay, [], out_png, ui_look.capture(g), ui_audit, crop=(l, b, l + w, b + h))


def film(w, g, gid, secs, out_dir, still=False):
    lua, length = FILMS[gid]
    secs = secs or length
    g.eval("if ns.__filmCover then ns.__filmCover:Hide() ns.__filmCover = nil end "
           "for _, ch in ipairs({ DZFilm and DZFilm:GetChildren() or nil }) do ch:Hide() end")
    g.eval(SETUP, lua)
    step = 1.0 / (FPS * STEPS)
    tmp = os.path.join(out_dir, "_frames_" + gid)
    os.makedirs(tmp, exist_ok=True)
    if still:
        for _ in range(int(4 / step)):
            g.eval("ns.__filmCover:Tick(...)", step)
        path = os.path.join(out_dir, gid + "_still.png")
        frame(g, path)
        return path
    blend = int(BLEND * FPS)
    total = int(secs * FPS) + blend
    t0 = time.time()
    for i in range(total):
        for _ in range(STEPS):
            g.eval("ns.__filmCover:Tick(...)", step)
        frame(g, os.path.join(tmp, "%05d.png" % i))
        if i % 60 == 0:
            print("  %s %d/%d (%.1f s a frame)" % (gid, i, total, (time.time() - t0) / (i + 1)), flush=True)
    return encode(tmp, total, blend, os.path.join(out_dir, gid + ".webm"))


def encode(tmp, total, blend, out):
    """The frames as a loop: frame i of T is r[blend + i], and the last `blend` ones fade into r[0..blend)."""
    import imageio_ffmpeg
    n = total - blend

    def get(k):
        return Image.open(os.path.join(tmp, "%05d.png" % k)).convert("RGB")

    first = get(0)
    size = first.size
    wr = imageio_ffmpeg.write_frames(out, size, fps=FPS, codec="libvpx-vp9", pix_fmt_out="yuv420p", quality=None,
                                     output_params=VIDEO, macro_block_size=1)
    wr.send(None)
    for i in range(n):
        im = get(blend + i)
        k = i - (n - blend)
        if k >= 0:
            im = Image.blend(im, get(k), (k + 1) / (blend + 1))
        wr.send(im.tobytes())
    wr.close()
    first.save(out[:-5] + ".jpg", quality=88)            # (shown until the film plays, and with reduced motion)
    return out


def main():
    args = sys.argv[1:]
    ids, secs, still, only_encode = [], None, False, False
    out_dir = os.path.join(DEV, "tf_e", "films")
    global FPS
    while args:
        a = args.pop(0)
        if a == "--secs":
            secs = float(args.pop(0))
        elif a == "--fps":
            FPS = int(args.pop(0))
        elif a == "--still":
            still = True
        elif a == "--encode":
            only_encode = True
        elif a == "--out":
            out_dir = args.pop(0)
        else:
            ids.append(a)
    os.makedirs(out_dir, exist_ok=True)
    if only_encode:
        for gid in ids or list(FILMS):
            tmp = os.path.join(out_dir, "_frames_" + gid)
            total = len([f for f in os.listdir(tmp) if f.endswith(".png")])
            path = encode(tmp, total, int(BLEND * FPS), os.path.join(out_dir, gid + ".webm"))
            print("%s -> %s (%.1f MB)" % (gid, path, os.path.getsize(path) / 1048576), flush=True)
        return
    w, g = world()
    for gid in ids or list(FILMS):
        t = time.time()
        path = film(w, g, gid, secs, out_dir, still)
        print("%s -> %s (%.0f s)" % (gid, path, time.time() - t), flush=True)
    errs = w.errors()
    if errs:
        print("%d Lua error(s) (first: %s)" % (len(errs), str(errs[0])[:400]))


if __name__ == "__main__":
    main()
