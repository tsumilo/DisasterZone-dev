"""Extracts Blizzard's own interface code (FrameXML: the XML layouts and Lua of the default UI) from the installed
client's CASC storage into dev/art/framexml (git-ignored, Blizzard's files): the reference for Disastercraft's
WoW-exact window layouts. Files are found through each Blizzard addon's .toc (no listfile needed).

    luaenv/Scripts/python.exe generators/extract_framexml.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import casc_local as C  # noqa: E402

OUT = os.path.join(HERE, "..", "art", "framexml")
ADDONS = """Blizzard_UIPanels_Game Blizzard_ActionBar Blizzard_UnitFrame Blizzard_FrameXML Blizzard_FrameXMLBase
Blizzard_SharedXML Blizzard_SharedXMLBase Blizzard_SharedXMLGame Blizzard_TrainerUI Blizzard_GroupLoot Blizzard_LootFrame
Blizzard_BuffFrame Blizzard_ChatFrame Blizzard_ChatFrameBase Blizzard_UIParent Blizzard_UIPanelTemplates
Blizzard_GameTooltip Blizzard_Minimap Blizzard_MapCanvas Blizzard_WorldMap Blizzard_QuestLog Blizzard_CharacterFrame
Blizzard_SpellBook Blizzard_PartyFrame Blizzard_StaticPopup Blizzard_StaticPopup_Game Blizzard_Fonts_Shared
Blizzard_MoneyFrame Blizzard_ItemButton Blizzard_CastingBar Blizzard_PlayerFrame Blizzard_TargetFrame
Blizzard_ZoneText Blizzard_UIErrors Blizzard_GameMenu Blizzard_QuestFrame Blizzard_GossipFrame Blizzard_Merchant
Blizzard_ContainerFrame Blizzard_MainMenuBar Blizzard_MicroMenu Blizzard_ClassTrainerUI Blizzard_CombatText
Blizzard_ItemTextFrame Blizzard_QuestTimer Blizzard_WatchFrame Blizzard_QuestWatch Blizzard_UnitPopup""".split()
SUFFIX = ["", "_TBC", "_Vanilla", "_Classic", "_Mainline", "_Wrath", "_Cata"]


def read(path):
    fid = C.fdid_of(path)
    if not fid:
        return None
    try:
        return C.read_fid(fid)
    except Exception:  # noqa: BLE001
        return None


def save(path, data):
    p = os.path.join(OUT, *path.split("/"))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "wb").write(data)


def main():
    got = 0
    seen = set()
    for a in ADDONS:
        base = "Interface/AddOns/%s/" % a
        for s in SUFFIX:
            toc = base + a + s + ".toc"
            data = read(toc)
            if not data:
                continue
            save(toc, data)
            for line in data.decode("utf-8", "replace").splitlines():
                line = line.strip().replace("\\", "/")
                m = re.match(r"^(.*?\.(?:xml|lua))\s*(?:\[(.*)\])?$", line, re.I)
                if not line or line.startswith("#") or not m:
                    continue
                cond = (m.group(2) or "").lower()
                # (only what the TBC client loads: no flag, or a game-type list that holds tbc)
                if "allowloadgametype" in cond and "tbc" not in cond:
                    continue
                path = base + m.group(1).replace("[Game]", "TBC")
                if path in seen:
                    continue
                seen.add(path)
                d = read(path)
                if d:
                    save(path, d)
                    got += 1
                    # files an XML file includes
                    if path.lower().endswith(".xml"):
                        for inc in re.findall(r'<(?:Include|Script) file="([^"]+)"', d.decode("utf-8", "replace")):
                            ip = os.path.dirname(path) + "/" + inc.replace("\\", "/")
                            if ip not in seen:
                                seen.add(ip)
                                dd = read(ip)
                                if dd:
                                    save(ip, dd)
                                    got += 1
    print("extracted", got, "files into", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
