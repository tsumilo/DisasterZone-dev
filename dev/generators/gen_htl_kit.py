r"""Hold the Line's UI pieces (cards, medal rings, gems, chips, buttons, loot rows, the level digits, the title...)
drawn by the mockup's own CSS: dev/art/casc/survivors_mockup/kit.html (with v2.css put in) is screenshot by headless
Chrome on a clear background, cut into its cells and packed into DXT5 pages:
  Media/HoldTheLine/Kit_<n>.blp   +   Games/HoldTheLine/Kit.lua (ns.HTLKit[name] = { file, u0, u1, v0, v1, w, h, pad })
w, h are the cell's size in CSS px (pad included: the room left round it for shadows and glows).
Run from dev: luaenv\Scripts\python.exe generators\gen_htl_kit.py"""
import json
import re
import subprocess
import sys
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gen_htl_media as M  # noqa: E402

MOCK = M.MOCK
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
OUT_LUA = M.ADDON / "Games" / "HoldTheLine" / "Kit.lua"


def shoot(html, name, height):
    built = MOCK / (name + "_built.html")
    built.write_bytes(html.encode("utf-8"))
    url = built.resolve().as_uri()
    common = [CHROME, "--headless=new", "--allow-file-access-from-files", "--hide-scrollbars", "--window-size=2000,%d" % height,
              "--force-device-scale-factor=1", "--default-background-color=00000000", "--virtual-time-budget=4000"]
    dom = subprocess.run(common + ["--dump-dom", url], capture_output=True, text=True, encoding="utf-8", timeout=120).stdout
    man = json.loads(re.search(r'<pre id="manifest"[^>]*>(.*?)</pre>', dom, re.S).group(1))
    shot = MOCK / (name + ".png")
    subprocess.run(common + [f"--screenshot={shot}", url], capture_output=True, timeout=120)
    img = Image.open(shot).convert("RGBA")
    return [(k, img.crop((round(v[0]), round(v[1]), round(v[0] + v[2]), round(v[1] + v[3])))) for k, v in man.items()], man


def main():
    html = (MOCK / "kit.html").read_text(encoding="utf-8").replace("/*V2CSS*/", (MOCK / "v2.css").read_text(encoding="utf-8"))
    pieces, man = shoot(html, "kit", 2400)
    # kit 2: the redesigned cards, header, buttons, logo and title pieces - title_design.html's own rules and logo
    design = (MOCK / "title_design.html").read_text(encoding="utf-8")
    css = re.search(r"<style>(.*?)</style>", design, re.S).group(1)
    logo = re.search(r'<div class="logo" id="logo">\s*(.*?)\s*</div>\s*<!-- 2\.', design, re.S).group(1)
    html2 = (MOCK / "kit2.html").read_text(encoding="utf-8").replace("/*DESIGNCSS*/", css).replace("LOGOHTML", json.dumps(logo))
    p2, man2 = shoot(html2, "kit2", 3000)
    # the hub poster's logo: the wordmark alone, its own texture (Media/HoldTheLine/logo.blp, 512 x 256) - the letters'
    # box is printed for Games/HubUI.lua's LOGOS (k = 2: two texture px per UI px)
    for i, (k, im) in enumerate(p2):
        if k == "poster_logo":
            p2.pop(i)
            box = im.getbbox()
            im = im.crop(box)
            page = Image.new("RGBA", (512, 256), (0, 0, 0, 0))
            ox, oy = (512 - im.width) // 2, (256 - im.height) // 2
            page.alpha_composite(im, (ox, oy))
            solid = page.split()[3].point(lambda v: 255 if v > 200 else 0).getbbox()
            M.write_dxt5_flat(page, M.OUT / "logo.blp")
            print("poster logo letters box l, t, r, b =", solid)
            break
    pieces += p2
    man.update(man2)
    pk = M.Packer()
    at = pk.pack(pieces)
    names = []
    for i, page in enumerate(pk.images()):
        n = "Kit_%d" % (i + 1)
        M.write_dxt5_flat(page, M.OUT / (n + ".blp"))
        names.append((n, page.width, page.height))
    rows = []
    for name, crop in pieces:
        p, x, y = at[name]
        n, pw, ph = names[p]
        pad = man[name][4]
        rows.append('K.%s = { "%s%s", %s, %s, %s, %s, %d, %d, %d }' % (
            name, M.GAME, n, M.lua_num(round(x / pw, 5)), M.lua_num(round((x + crop.width) / pw, 5)),
            M.lua_num(round(y / ph, 5)), M.lua_num(round((y + crop.height) / ph, 5)), crop.width, crop.height, pad))
    body = ['if DisasterZoneBoot and DisasterZoneBoot.Run("Games/HoldTheLine/Kit.lua", ...) then return end -- DisasterZone Games/HoldTheLine/Kit.lua',
            "-- ns.HTLKit: Hold the Line's UI pieces, cut from the mockup's CSS (dev/generators/gen_htl_kit.py) - do not edit.",
            "-- K[name] = { file, u0, u1, v0, v1, w, h, pad }: w, h in CSS px with pad px of room round the piece (its glow / shadow).",
            "local _, ns = ...", "local K = {}", "ns.HTLKit = K"] + rows
    base = ["%s = %s" % (k, M.lua_num(round(v[5], 1))) for k, v in man.items() if len(v) > 5]
    if base: body.append("K._base = { " + ", ".join(base) + " }   -- the baseline of the level word and digits, px from the element's top")
    OUT_LUA.write_bytes(("\n".join(body) + "\n").encode("utf-8"))
    print(len(pieces), "pieces on", len(names), "pages", [n[1:] for n in names])


if __name__ == "__main__":
    main()
