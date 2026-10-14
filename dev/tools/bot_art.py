"""Exports the art the Discord bot draws its pictures with (launcher host mode, src-tauri/src/render) from the installed
game client into the launcher's folder on this PC: %APPDATA%\\DisasterZoneLauncher\\bot_art. The art is Blizzard's,
so it is never shipped with the public launcher: the host runs this once (and again after a client patch).

  load_<planKey>.jpg   each raid's loading screen at 4:3 (Data/Raids.lua art ids) + art.json { planKey: { cx, cy, top } }
  class_<CLASS>.png    the class icons;  spec_<CLASS>_<i>.png  the spec icons (Core/Constants.lua SPEC_ICONS, ns.SPECS order)
  ui_<name>.png        ready check, role icons, skull, hourglass
  item_<id>.png        the icon of every item in Data/Items.lua (icon names: ui_look's cache, else Wowhead's tooltips)
  friz.ttf, sans*.ttf  the game's Friz Quadrata (from the client) and Noto Sans (OFL, downloaded once)

Run: luaenv\\Scripts\\python.exe tools\\bot_art.py [--out DIR] [--no-items]
"""
import argparse
import io
import json
import os
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from PIL import Image

DEV = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone")
sys.path.insert(0, os.path.join(DEV, "tools"))
sys.path.insert(0, os.path.join(DEV, "generators"))
os.chdir(DEV)
import ui_look  # noqa: E402
import casc_local as C  # noqa: E402

CLASS_ORDER = ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID"]
SPEC_LABELS = {  # ns.SPECS order (Core/Constants.lua): the spec index the bot and the addon share
    "WARRIOR": ["Arms", "Fury", "Protection"], "PALADIN": ["Holy", "Protection", "Retribution"],
    "HUNTER": ["Beast Mastery", "Marksmanship", "Survival"], "ROGUE": ["Assassination", "Combat", "Subtlety"],
    "PRIEST": ["Discipline", "Holy", "Shadow"], "SHAMAN": ["Elemental", "Enhancement", "Restoration"],
    "MAGE": ["Arcane", "Fire", "Frost"], "WARLOCK": ["Affliction", "Demonology", "Destruction"],
    "DRUID": ["Balance", "Feral (Cat)", "Feral (Bear)", "Restoration"],
}
UI = {"ready": r"Interface\RaidFrame\ReadyCheck-Ready", "notready": r"Interface\RaidFrame\ReadyCheck-NotReady",
      "waiting": r"Interface\RaidFrame\ReadyCheck-Waiting", "roles": r"Interface\LFGFrame\UI-LFG-ICON-ROLES",
      "skull": r"Interface\TargetingFrame\UI-TargetingFrame-Skull", "hourglass": r"Interface\Icons\INV_Misc_PocketWatch_01"}
SANS = {"sans.ttf": "NotoSans-Regular.ttf", "sans_semibold.ttf": "NotoSans-SemiBold.ttf", "sans_bold.ttf": "NotoSans-Bold.ttf"}
SANS_URL = "https://github.com/notofonts/notofonts.github.io/raw/main/fonts/NotoSans/hinted/ttf/"


def out_dir(arg):
    if arg:
        return arg
    return os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "DisasterZoneLauncher", "bot_art")


def save_tex(path, dest, size=None):
    try:
        im = ui_look.load(path)
    except Exception:  # noqa: BLE001
        im = None
    if im is None:
        return False
    if size:
        im = im.resize(size, Image.LANCZOS)
    if dest.endswith(".jpg"):
        im.convert("RGB").save(dest, quality=88)
    else:
        im.convert("RGBA").save(dest)
    return True


def raids():
    """[(planKey, fdid, cx, cy)] from Data/Raids.lua, plus the 'other' screen."""
    t = open(os.path.join(ADDON, "Data", "Raids.lua"), encoding="utf-8").read()
    out = [(m.group(1), int(m.group(2)), float(m.group(3)), float(m.group(4)))
           for m in re.finditer(r'planKey = "(\w+)".*?art = Art\((\d+), ([\d.]+), ([\d.]+)\)', t)]
    top = float(re.search(r"local ART_TOP = ([\d.]+)", t).group(1))
    return out, top


def spec_icons():
    t = open(os.path.join(ADDON, "Core", "Constants.lua"), encoding="utf-8").read()
    block = t[t.index("local SPEC_ICONS"):]
    block = block[:block.index("\n    }\n")]
    out = {}
    for cls in CLASS_ORDER:
        m = re.search(r"\b%s = \{(.*?)\}" % cls, block, re.S)
        pairs = {k.strip(): v for k, v in re.findall(r'\[?"?([\w ()]+?)"?\]? = "(\w+)"', m.group(1))} if m else {}
        out[cls] = [pairs.get(label) for label in SPEC_LABELS[cls]]
    return out


def item_ids():
    t = open(os.path.join(ADDON, "Data", "Items.lua"), encoding="utf-8").read()
    return sorted({int(x) for x in re.findall(r"^\s+(\d{4,6}),", t, re.M)})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out")
    ap.add_argument("--no-items", action="store_true")
    a = ap.parse_args()
    out = out_dir(a.out)
    os.makedirs(out, exist_ok=True)
    miss = []

    # raids: the 2048 x 2048 texture is shown at 4:3
    meta = {}
    rs, top = raids()
    for key, fdid, cx, cy in rs:
        try:
            im = Image.open(io.BytesIO(C.read_fid(fdid)))
            im.load()
            im.convert("RGB").resize((1024, 768), Image.LANCZOS).save(os.path.join(out, "load_%s.jpg" % key), quality=88)
            meta[key] = {"cx": cx, "cy": cy, "top": top}
        except Exception as e:  # noqa: BLE001
            miss.append("raid %s (%s)" % (key, type(e).__name__))
    json.dump(meta, open(os.path.join(out, "art.json"), "w"), indent=1)

    for cls in CLASS_ORDER:
        if not save_tex("Interface\\Icons\\ClassIcon_" + cls.capitalize(), os.path.join(out, "class_%s.png" % cls)):
            miss.append("class " + cls)
    for cls, icons in spec_icons().items():
        for i, icon in enumerate(icons, 1):
            if not icon or not save_tex("Interface\\Icons\\" + icon, os.path.join(out, "spec_%s_%d.png" % (cls, i))):
                miss.append("spec %s %d (%s)" % (cls, i, icon))
    for k, p in UI.items():
        if not save_tex(p, os.path.join(out, "ui_%s.png" % k)):
            miss.append("ui " + k)

    # fonts: Friz from the client, Noto Sans (OFL) from its project
    f = C.fdid_of("Fonts/FRIZQT__.TTF")
    if f:
        open(os.path.join(out, "friz.ttf"), "wb").write(C.read_fid(f))
    else:
        miss.append("Fonts/FRIZQT__.TTF")
    for dest, name in SANS.items():
        p = os.path.join(out, dest)
        if not os.path.isfile(p):
            try:
                req = urllib.request.Request(SANS_URL + name, headers={"User-Agent": "Mozilla/5.0"})
                open(p, "wb").write(urllib.request.urlopen(req, timeout=30).read())
            except Exception as e:  # noqa: BLE001
                miss.append("%s (%s)" % (name, e))

    if not a.no_items:
        ids = [i for i in item_ids() if not os.path.isfile(os.path.join(out, "item_%d.png" % i))]
        print("item icons to export:", len(ids))
        names = {}
        with ThreadPoolExecutor(8) as pool:   # (Wowhead lookups for names not in the cache yet)
            for iid, n in zip(ids, pool.map(ui_look.item_icon_name, ids)):
                names[iid] = n
        for iid in ids:
            n = names.get(iid)
            if not n or not save_tex("Interface\\Icons\\" + n, os.path.join(out, "item_%d.png" % iid)):
                miss.append("item %d (%s)" % (iid, n))
    print("bot art in", out)
    print("%d missing%s" % (len(miss), (": " + ", ".join(miss[:30]) + (" ..." if len(miss) > 30 else "")) if miss else ""))


if __name__ == "__main__":
    main()
