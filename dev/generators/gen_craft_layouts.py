"""Disastercraft's windows and HUD, laid out exactly like the client's own: Blizzard's FrameXML (extracted by
extract_framexml.py into dev/art/framexml) is parsed, every template a frame inherits is expanded into concrete
regions (sizes, anchors, textures with their files / atlases / tex coords, font strings with their font objects),
and the result is written as Lua data to addon/DisasterZone/Games/Disastercraft/Layouts.lua. UILayout.lua builds
frames from it at run time; scripts and mixins are left out (the game's own behaviour lives in UIWindows.lua).

    luaenv/Scripts/python.exe generators/gen_craft_layouts.py
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
SRC = os.path.join(DEV, "art", "framexml", "Interface", "AddOns")
OUT = os.path.join(DEV, "..", "addon", "DisasterZone", "Games", "Disastercraft", "Layouts.lua")
NS = "{http://www.blizzard.com/wow/ui/}"

# the frames Disastercraft draws (root name -> what it is called in Layouts.lua)
ROOTS = [
    "LootFrame", "ContainerFrameTemplate", "MerchantFrame", "QuestFrame", "GossipFrame", "QuestLogFrame",
    "ClassTrainerFrame", "SpellBookFrame", "CharacterFrame", "PaperDollFrame", "PlayerFrame", "TargetFrame", "PlayerCastingBarFrame",
    "MainMenuBar", "AuraButtonTemplate", "StaticPopupTemplate", "GroupLootFrameTemplate", "PartyMemberFrameTemplate",
    "BagsBar", "ActionBarButtonTemplate", "MainMenuBarMicroButton", "CharacterMicroButton", "SpellbookMicroButton",
    "QuestLogMicroButton", "SocialsMicroButton", "MainMenuMicroButton", "ExpStatusBarTemplate",
    "CastingBarFrameTemplate", "SmallCastingBarFrameTemplate", "ItemButtonTemplate",
    "QuestInfoFrame", "QuestInfoRewardsFrame", "LargeQuestRewardItemButtonTemplate", "MoneyFrameTemplate",
    "GossipGreetingTextTemplate", "GossipSpacerFrameTemplate", "GossipTitleButtonTemplate",
]
FRAME_TYPES = {"Frame", "Button", "CheckButton", "ScrollFrame", "StatusBar", "EditBox", "Slider", "PlayerModel",
               "DressUpModel", "ModelScene", "Cooldown", "MessageFrame", "ScrollingMessageFrame", "SimpleHTML",
               "ItemButton", "DropdownButton", "EventFrame", "EventButton", "ContainedAlertFrame", "GameTooltip",
               "Model", "TabardModel", "CinematicModel", "ColorSelect", "MovieFrame", "Browser", "OffScreenFrame",
               "ScopedModifier", "Minimap", "ArchaeologyDigSiteFrame", "QuestPOIFrame", "UnitButton", "CheckButton",
               "EventEditBox", "ScrollingMessageFrame", "FogOfWarFrame", "UnitPositionFrame",
               "UIThemeContainerFrame"}
REGION_TYPES = {"Texture", "FontString", "MaskTexture", "Line"}
BUTTON_TEX = {"NormalTexture", "PushedTexture", "DisabledTexture", "HighlightTexture", "CheckedTexture",
              "DisabledCheckedTexture", "ThumbTexture", "BarTexture"}


def tag(e):
    return e.tag.replace(NS, "")


# ---------------------------------------------------------------------------------------------------------------
# Load every XML file; index named elements (virtual templates and named frames)
# ---------------------------------------------------------------------------------------------------------------

BY_NAME = {}


def load_all():
    for root, _, files in os.walk(SRC):
        for f in files:
            if not f.lower().endswith(".xml"):
                continue
            path = os.path.join(root, f)
            # (a newer flavour's copy must not shadow the TBC / Classic / Vanilla one)
            rank = 0
            low = path.replace("\\", "/").lower()
            if "/mainline/" in low or "/cata/" in low or "/mists/" in low or "/wrath/" in low:
                rank = 3
            elif "/tbc/" in low:
                rank = -2
            elif "/classic/" in low:
                rank = -1
            elif "/vanilla/" in low:
                rank = 0
            try:
                text = open(path, encoding="utf-8-sig", errors="replace").read()
                text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
                tree = ET.fromstring(text)
            except ET.ParseError:
                continue
            for e in tree.iter():
                n = e.get("name")
                if n and tag(e) in FRAME_TYPES | REGION_TYPES | {"Font"}:
                    cur = BY_NAME.get(n)
                    if cur is None or rank < cur[1]:
                        BY_NAME[n] = (e, rank, path)


# ---------------------------------------------------------------------------------------------------------------
# Expanding templates
# ---------------------------------------------------------------------------------------------------------------

def num(v, d=0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return d


def read_size(e):
    s = None
    for c in e:
        if tag(c) == "Size":
            x, y = c.get("x"), c.get("y")
            for a in c:
                if tag(a) == "AbsDimension":
                    x, y = a.get("x"), a.get("y")
            s = [num(x, None) if x is not None else None, num(y, None) if y is not None else None]
    return s


def read_anchors(e):
    out = None
    for c in e:
        if tag(c) == "Anchors":
            out = []
            for a in c:
                if tag(a) != "Anchor":
                    continue
                x, y = a.get("x"), a.get("y")
                for o in a:
                    if tag(o) == "Offset":
                        x = o.get("x", x)
                        y = o.get("y", y)
                        for d in o:
                            if tag(d) == "AbsDimension":
                                x, y = d.get("x"), d.get("y")
                out.append({"p": a.get("point"), "to": a.get("relativeTo"), "key": a.get("relativeKey"),
                            "rp": a.get("relativePoint"), "x": num(x), "y": num(y)})
    return out


def merge(base, over):
    """over's fields replace base's; lists of children append (layers / frames)."""
    out = dict(base)
    for k, v in over.items():
        if v is None:
            continue
        if k in ("regions", "frames") and k in out:
            # (a widget defined again under the same name / key - templates inherited along two paths, or a
            # frame overriding its template's piece - replaces the earlier one, merged)
            lst = list(out[k])
            for item in v:
                ident = item.get("name") or (("key", item.get("key")) if item.get("key") else None)
                hit = None
                if ident:
                    for i, old in enumerate(lst):
                        if (old.get("name") or (("key", old.get("key")) if old.get("key") else None)) == ident:
                            hit = i
                if hit is not None:
                    lst[hit] = merge(lst[hit], item)
                else:
                    lst.append(item)
            out[k] = lst
        elif k == "btex" and k in out:
            d = dict(out[k])
            d.update(v)
            out[k] = d
        else:
            out[k] = v
    return out


def color_of(e, name="Color"):
    for c in e:
        if tag(c) == name:
            if c.get("color"):
                return c.get("color")
            return [num(c.get("r"), 1), num(c.get("g"), 1), num(c.get("b"), 1), num(c.get("a"), 1)]
    return None


def coords_of(e):
    for c in e:
        if tag(c) == "TexCoords":
            if c.get("left") is not None:
                return [num(c.get("left")), num(c.get("right"), 1), num(c.get("top")), num(c.get("bottom"), 1)]
            for r in c:
                if tag(r) == "Rect":
                    return [num(r.get(k)) for k in ("ULx", "ULy", "LLx", "LLy", "URx", "URy", "LRx", "LRy")]
    return None


def region(e, layer, sub, stack):
    """A Texture / FontString / MaskTexture element (and its inherited templates) -> dict."""
    t = tag(e)
    d = {"t": t}
    for inh in [x.strip() for x in (e.get("inherits") or "").split(",") if x.strip()]:
        tpl = BY_NAME.get(inh)
        if tpl and tag(tpl[0]) in REGION_TYPES and inh not in stack:
            d = merge(d, region(tpl[0], layer, sub, stack + [inh]))
        elif t == "FontString":
            d["font"] = inh                       # a Font object (GameFontNormal ...)
    a = e.attrib
    d = merge(d, {
        "name": a.get("name"), "key": a.get("parentKey"), "arr": a.get("parentArray"),
        "layer": layer, "sub": int(sub) if sub not in (None, "") else None,
        "file": a.get("file"), "atlas": a.get("atlas"), "useAtlasSize": a.get("useAtlasSize") == "true" or None,
        "blend": a.get("alphaMode"), "alpha": num(a.get("alpha"), None) if a.get("alpha") else None,
        "hidden": a.get("hidden") == "true" or None, "all": a.get("setAllPoints") == "true" or None,
        "hTile": a.get("horizTile") == "true" or None, "vTile": a.get("vertTile") == "true" or None,
        "text": a.get("text"), "jh": a.get("justifyH"), "jv": a.get("justifyV"),
        "lines": int(a.get("maxLines")) if a.get("maxLines") else None,
        "wrap": (a.get("wordwrap") == "true") if a.get("wordwrap") else None,
        "desat": a.get("desaturated") == "true" or None,
        "size": read_size(e), "anchors": read_anchors(e), "coords": coords_of(e),
        "color": color_of(e) if t != "FontString" else None, "tcolor": color_of(e) if t == "FontString" else None,
    })
    if t == "FontString" and a.get("inherits") and "font" not in d:
        d["font"] = a.get("inherits")
    if t == "FontString":
        for c in e:
            if tag(c) == "Shadow":
                d["shadow"] = True
    if t == "MaskTexture":                        # the regions it masks, by parentKey / name
        masked = [m.get("childKey") or m.get("name") for c in e if tag(c) == "MaskedTextures"
                  for m in c if tag(m) == "MaskedTexture"]
        if masked:
            d["masked"] = [x for x in masked if x]
    return d


def frame(e, stack, kind=None):
    """A frame element with its templates expanded -> dict."""
    t = kind or tag(e)
    d = {"t": t}
    inherits = [x.strip() for x in (e.get("inherits") or "").split(",") if x.strip()]
    for inh in inherits:
        tpl = BY_NAME.get(inh)
        if tpl and inh not in stack:
            sub = frame(tpl[0], stack + [inh], None)
            sub["t"] = t if t != "Frame" or sub["t"] == "Frame" else sub["t"]
            d = merge(d, sub)
        else:
            d.setdefault("missing", []).append(inh)
    a = e.attrib
    over = {
        "name": a.get("name") if a.get("virtual") != "true" else None,
        "key": a.get("parentKey"), "arr": a.get("parentArray"),
        "hidden": (a.get("hidden") == "true") if a.get("hidden") else None,
        "all": a.get("setAllPoints") == "true" or None,
        "strata": a.get("frameStrata"), "level": int(a.get("frameLevel")) if a.get("frameLevel") else None,
        "useParentLevel": a.get("useParentLevel") == "true" or None,
        "mouse": (a.get("enableMouse") == "true") if a.get("enableMouse") else None,
        "text": a.get("text"), "id": int(a.get("id")) if a.get("id") and a.get("id").isdigit() else None,
        "alpha": num(a.get("alpha"), None) if a.get("alpha") else None,
        "size": read_size(e), "anchors": read_anchors(e),
    }
    if t == "Frame" and tag(e) in FRAME_TYPES and tag(e) != "Frame":
        over["t"] = tag(e)
    if tag(e) in FRAME_TYPES:
        over["t"] = {"ItemButton": "Button", "UIThemeContainerFrame": "Frame", "DropdownButton": "Button",
                     "EventFrame": "Frame", "EventButton": "Button", "ContainedAlertFrame": "Frame",
                     "UnitButton": "Button", "EventEditBox": "EditBox"}.get(tag(e), tag(e))
    regions, frames, btex = [], [], {}
    for c in e:
        ct = tag(c)
        if ct == "Layers":
            for layer in c:
                lv, sub = layer.get("level", "ARTWORK"), layer.get("textureSubLevel")
                for r in layer:
                    if tag(r) in REGION_TYPES:
                        regions.append(region(r, lv, sub, []))
        elif ct == "Frames":
            for f in c:
                if tag(f) in FRAME_TYPES:
                    frames.append(frame(f, stack, None))
        elif ct == "ScrollChild":
            for f in c:
                if tag(f) in FRAME_TYPES:
                    sc = frame(f, stack, None)
                    sc["scrollChild"] = True
                    frames.append(sc)
        elif ct in BUTTON_TEX:
            btex[ct] = region(c, "ARTWORK", None, [])
            btex[ct]["t"] = "Texture"
        elif ct == "ButtonText":
            bt = region(c, "OVERLAY", None, [])
            bt["t"] = "FontString"
            over["buttonText"] = bt
        elif ct in ("NormalFont", "HighlightFont", "DisabledFont"):
            over.setdefault("fonts", {})[ct] = c.get("style")
        elif ct == "BarColor":
            over["barColor"] = color_of(e, "BarColor")
        elif ct == "HitRectInsets":
            over["hit"] = [num(c.get("left")), num(c.get("right")), num(c.get("top")), num(c.get("bottom"))]
        elif ct == "KeyValues":
            kv = {}
            for k in c:
                if tag(k) == "KeyValue" and k.get("type") in (None, "number", "string", "boolean"):
                    v = k.get("value")
                    if k.get("type") == "number":
                        v = num(v)
                    elif k.get("type") == "boolean":
                        v = v == "true"
                    kv[k.get("key")] = v
            if kv:
                over["kv"] = kv
        elif ct == "FontString" and t in ("EditBox", "MessageFrame"):
            pass
    over["regions"] = regions or None
    over["frames"] = frames or None
    over["btex"] = btex or None
    return merge(d, over)


# ---------------------------------------------------------------------------------------------------------------
# Names: $parent resolved to the Blizzard name each widget would get (for anchors relativeTo, and our refs)
# ---------------------------------------------------------------------------------------------------------------

def resolve_names(d, parent_name):
    if d.get("name"):
        d["name"] = d["name"].replace("$parent", parent_name or "")
    my = d.get("name") or (parent_name + "!" + (d.get("key") or "?") if parent_name else None)
    for r in d.get("regions") or []:
        if r.get("name"):
            r["name"] = r["name"].replace("$parent", my or "")
    for r in (d.get("btex") or {}).values():
        if r.get("name"):
            r["name"] = r["name"].replace("$parent", my or "")
    if d.get("buttonText") and d["buttonText"].get("name"):
        d["buttonText"]["name"] = d["buttonText"]["name"].replace("$parent", my or "")
    for f in d.get("frames") or []:
        resolve_names(f, my)
    for lst in ((d.get("regions") or []), (d.get("frames") or [])):
        for x in lst:
            for an in x.get("anchors") or []:
                if an.get("to"):
                    an["to"] = an["to"].replace("$parent", my or "")
    for an in d.get("anchors") or []:
        if an.get("to"):
            an["to"] = an["to"].replace("$parent", parent_name or "")


# ---------------------------------------------------------------------------------------------------------------
# Lua output
# ---------------------------------------------------------------------------------------------------------------

def lua(v):
    if v is None:
        return "nil"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, float):
        if v == int(v):
            return str(int(v))
        return ("%.6f" % v).rstrip("0").rstrip(".")
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    if isinstance(v, list):
        return "{" + ",".join(lua(x) for x in v) + "}"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            if x is None or x == [] or x == {}:
                continue
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
                parts.append("%s=%s" % (k, lua(x)))
            else:
                parts.append("[%s]=%s" % (lua(k), lua(x)))
        return "{" + ",".join(parts) + "}"
    raise TypeError(type(v))


def main():
    load_all()
    out = ['if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Layouts.lua", ...) then return end '
           '-- DisasterZone Games/Disastercraft/Layouts.lua  (GENERATED by dev/generators/gen_craft_layouts.py - do not edit)',
           "-- The client's own frame layouts (Blizzard FrameXML of the TBC Anniversary client, templates expanded): sizes,",
           "-- anchors, textures and font strings. UILayout.lua builds frames from them.",
           "local addonName, ns = ...",
           "local L = {}",
           "ns.CraftLayouts = L"]
    missing = set()
    for r in ROOTS:
        hit = BY_NAME.get(r)
        if not hit:
            print("not found:", r)
            continue
        e = hit[0]
        d = frame(e, [r], None)
        d["name"] = r
        resolve_names(d, None)

        def collect(x):
            for m in x.get("missing") or []:
                missing.add(m)
            for f in x.get("frames") or []:
                collect(f)
        collect(d)
        out.append("L[%s] = %s" % (lua(r), lua(d)))
        print("%-28s %s (%d bytes)" % (r, os.path.relpath(hit[2], SRC), len(out[-1])))
    open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
    print("templates not found (kept by name):", sorted(missing))
    print("wrote", OUT, os.path.getsize(OUT))


if __name__ == "__main__":
    main()
