#!/usr/bin/env python3
"""
Generator for Data/AtlasPortraits.lua: a portrait for every raid and dungeon boss the Atlas lists (both eras), for its
boss heroes, boss picker, section headers and search rows.

1. Encounter Journal art (UI-EJ-BOSS-*, 128 x 64), as FileDataIDs. The TBC Anniversary client ships the modern Journal
   art but no API to find it, so it is looked up here:
   a. by file name in the installed client's CASC (dev/generators/casc_local.py): the boss's name and its variants;
   b. by the retail Journal tables (JournalEncounterCreature / JournalEncounter from wago.tools, downloaded into
      dev/art/dc_db2 when missing): a creature or encounter of that name gives its portrait's FileDataID, kept when the
      file is in the local client.
2. Bosses the Journal never had (removed or redesigned before it: the old Zul'Gurub priests, old Shadowfang Keep,
   world bosses, rare spawns): the creature display id AtlasLoot lists for them (AtlasLootClassic_DungeonsAndRaids
   data.lua / data-tbc.lua, read from the anniversary or classic_era AddOns folder). The addon paints a round portrait
   from the model (SetPortraitTextureFromCreatureDisplayID).
Pages that are not a creature (chests, books, Tier 0.5 summons, "Trash") get nothing and show their name alone.

Reads: <ADDON>/Data/Items.lua, Data/Dungeons.lua, Data/AtlasClassic.lua (page names), the files above.
Writes: <ADDON>/Data/AtlasPortraits.lua
Run from dev: luaenv\\Scripts\\python.exe generators\\gen_atlas_portraits.py
"""
import csv
import os
import re
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
import casc_local as C  # noqa: E402

DEV = HERE.parent
ADDON = HERE.parents[1] / "addon" / "DisasterZone"
SOURCES = ["Data/Items.lua", "Data/Dungeons.lua", "Data/AtlasClassic.lua"]
OUT = ADDON / "Data" / "AtlasPortraits.lua"
EJ = "Interface/EncounterJournal/UI-EJ-BOSS-%s.blp"
DB2 = DEV / "art" / "dc_db2"
WAGO = "https://wago.tools/db2/%s/csv"          # (the retail build: the 2.5.x builds have no Journal tables)
ADDON_DIRS = [r"C:\World of Warcraft\_anniversary_\Interface\AddOns", r"C:\World of Warcraft\_classic_era_\Interface\AddOns"]
AL_FILES = ["AtlasLootClassic_DungeonsAndRaids/data.lua", "AtlasLootClassic_DungeonsAndRaids/data-tbc.lua"]
NAME = r'name = "((?:[^"\\]|\\.)+)"'


def variants(name):
    """The names the Journal may file a boss under: as written, without "The", without a bracket, either half of
    "A & B" / "A and B" / "A / B", without an epithet after a comma."""
    out = [name]
    base = re.sub(r"\s*\(.*\)$", "", name)
    out.append(base)
    out.append(re.sub(r"^The ", "", base))
    for sep in (" & ", " and ", " / ", "/"):
        if sep in base:
            out.extend(p.strip() for p in base.split(sep))
    out.append(base.split(",")[0])
    out.append(base.split(" - ")[0])                     # ("Theldren - Tier 0.5 Sets")
    out.append(re.sub(r"'s Heirlooms$", "", base.split(" - ")[0]))
    seen, uniq = set(), []
    for v in out:
        if v and v not in seen:
            seen.add(v)
            uniq.append(v)
    return uniq


def norm(s):
    s = s.lower().replace("the ", "")
    return re.sub(r"[^a-z0-9 ]", "", s).strip()


def boss_names():
    """Every raid / dungeon page name (Classic: up to the professions' tree), in file order."""
    names = []
    for rel in SOURCES:
        text = (ADDON / rel).read_text(encoding="utf-8", errors="replace")
        if rel.endswith("AtlasClassic.lua"):
            cut = text.find('kind = "crafting"')
            text = text[:cut] if cut > 0 else text
        for m in re.finditer(NAME, text):
            n = m.group(1).replace('\\"', '"')
            if n not in names:
                names.append(n)
    return names


def journal_tables():
    """{norm name: [file ids]} of the Journal's creatures, {norm encounter name: its first creature's file id}."""
    DB2.mkdir(parents=True, exist_ok=True)
    for t in ("JournalEncounterCreature", "JournalEncounter"):
        path = DB2 / (t + ".csv")
        if not path.exists() or path.stat().st_size < 1000:
            req = urllib.request.Request(WAGO % t, headers={"User-Agent": "Mozilla/5.0"})
            path.write_bytes(urllib.request.urlopen(req, timeout=60).read())
    cre, first = {}, {}
    for r in csv.DictReader(open(DB2 / "JournalEncounterCreature.csv", encoding="utf-8")):
        fid = int(r["FileDataID"] or 0)
        cre.setdefault(norm(r["Name_lang"]), []).append(fid)
        if int(r["OrderIndex"] or 0) == 0:
            first[int(r["JournalEncounterID"])] = fid
    enc = {}
    for r in csv.DictReader(open(DB2 / "JournalEncounter.csv", encoding="utf-8")):
        e = int(r["ID"])
        if first.get(e):
            enc.setdefault(norm(r["Name_lang"]), first[e])
    return cre, enc


def atlasloot_displays():
    """{norm boss name: display id} from AtlasLoot's raid / dungeon tables (first install found)."""
    out = {}
    for d in ADDON_DIRS:
        for rel in AL_FILES:
            path = os.path.join(d, *rel.split("/"))
            if not os.path.isfile(path):
                continue
            text = open(path, encoding="utf-8", errors="replace").read()
            # (each boss's own block: from its name to the next name)
            starts = [m for m in re.finditer(r'name = AL\["((?:[^"\\]|\\.)+)"\]', text)]
            for i, m in enumerate(starts):
                end = starts[i + 1].start() if i + 1 < len(starts) else len(text)
                found = re.search(r"DisplayIDs = \{\{\s*(\d+)", text[m.end():end])
                if found:
                    out.setdefault(norm(m.group(1).replace('\\"', '"')), int(found.group(1)))
        if out:
            break
    return out


_have = {}


def in_client(fid):
    if fid not in _have:
        try:
            C.read_fid(fid)
            _have[fid] = True
        except Exception:  # noqa: BLE001
            _have[fid] = False
    return _have[fid]


def main():
    names = boss_names()
    cre, enc = journal_tables()
    displays = atlasloot_displays()
    art, model = {}, {}
    for n in names:
        if n in ("Trash", "Trash Mobs"):
            continue
        vs = variants(n)
        hit = None
        for v in vs:
            hit = C.fdid_of(EJ % v)
            if hit:
                break
        if not hit:
            for v in vs:
                for fid in cre.get(norm(v), []) + ([enc[norm(v)]] if norm(v) in enc else []):
                    if fid and in_client(fid):
                        hit = fid
                        break
                if hit:
                    break
        if hit:
            art[n] = hit
            continue
        for v in vs:
            d = displays.get(norm(v))
            if d:
                model[n] = d
                break
    default = C.fdid_of(EJ % "Default")
    esc = lambda s: s.replace("\\", "\\\\").replace('"', '\\"')
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("Data/AtlasPortraits.lua", ...) then return end -- DisasterZone '
        "Atlas boss portraits",
        "-- AUTO-GENERATED by gen_atlas_portraits.py - do not edit by hand; re-run the generator instead.",
        "-- ns.Data.AtlasPortraits[page name] = the FileDataID of its Encounter Journal portrait (UI-EJ-BOSS-*, 128 x 64);",
        "-- .display[page name] = a creature display id for a boss the Journal never had (a round portrait from its model);",
        "-- DEFAULT = the Journal's own stand-in.",
        "local _, ns = ...",
        "ns.Data = ns.Data or {}",
        "",
        "ns.Data.AtlasPortraits = {",
        "  DEFAULT = %d," % default,
    ]
    for n in sorted(art):
        lines.append('  ["%s"] = %d,' % (esc(n), art[n]))
    lines.append("  display = {")
    for n in sorted(model):
        lines.append('    ["%s"] = %d,' % (esc(n), model[n]))
    lines.append("  },")
    lines.append("}")
    OUT.write_bytes(("\n".join(lines) + "\n").encode("utf-8"))
    rest = [n for n in names if n not in art and n not in model and n not in ("Trash", "Trash Mobs")]
    print("%d boss pages: %d Journal portraits, %d model portraits, %d without (not creatures or unknown) -> %s"
          % (len(names), len(art), len(model), len(rest), OUT))
    print("without:", rest)


if __name__ == "__main__":
    main()
