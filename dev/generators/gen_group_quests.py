"""Groups board: the group quests of TBC by zone -> addon/DisasterZone/Data/GroupQuests.lua.

Source: the cMaNGOS TBC world DB (tbcdb.py; quest_template) plus the client's AreaTable (db2/AreaTable.csv) for zone
names. The DB lives only in the main dev kit (git-ignored dev/art/tbcdb), so a worktree reads it from there.

A group quest = SuggestedPlayers >= 2, or Type 1 ("Group" / elite in QuestInfo) without a suggested size (players
left nil). Skipped: unused rows (BETA / OLD titles, no NPC, object or item gives it), quests in a dungeon/raid map, Type dungeon/raid/heroic/PvP/world event, dailies (QuestFlags
4096), PvP-ish flags, class quests (RequiredClasses or a negative ZoneOrSort), quests with no title.

    bash dz.sh <wt> generators/gen_group_quests.py
"""
import csv
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tbcdb  # noqa: E402

# the DB folder: this kit's own, else the main dev kit's (worktrees don't have the git-ignored copy)
for _d in (tbcdb.DIR, r"C:/Users/emilo/CDLoot-dev/dev/art/tbcdb"):
    if os.path.exists(os.path.join(_d, "tables.pickle")):
        tbcdb.DIR = _d
        tbcdb.SQL = os.path.join(_d, "tbcdb.sql")
        tbcdb.CACHE = os.path.join(_d, "tables.pickle")
        break

ADDON = os.environ.get("DISASTERZONE_ADDON_DIR") or os.path.join(HERE, "..", "..", "addon", "DisasterZone")
OUT = os.path.join(ADDON, "Data", "GroupQuests.lua")

OPEN_WORLD_MAPS = {0, 1, 530}
SKIP_TYPES = {41, 62, 81, 82, 85}       # PvP, raid, dungeon, world event, heroic
FLAG_DAILY = 4096
ALLIANCE = 1 | 4 | 8 | 64 | 1024        # human, dwarf, night elf, gnome, draenei
HORDE = 2 | 16 | 32 | 128 | 512         # orc, undead, tauren, troll, blood elf

# Outland in board order: area id, loading screen (FileDataID), crop centre. Shadowmoon Valley = Black Temple's screen.
OUTLAND = [
    (3483, "Hellfire Peninsula", 131845, 0.5, 0.45),
    (3521, "Zangarmarsh", 131832, 0.6, 0.5),
    (3519, "Terokkar Forest", 131821, 0.4, 0.5),
    (3518, "Nagrand", 131853, 0.5, 0.55),
    (3522, "Blade's Edge Mountains", 131828, 0.5, 0.5),
    (3523, "Netherstorm", 131875, 0.5, 0.45),
    (3520, "Shadowmoon Valley", 131826, 0.3, 0.56),
    (3703, "Shattrath City", 131821, 0.4, 0.5),      # (not in the list asked for: Outland, Terokkar's screen)
]
# old-world zones with a loading screen of their own already in the addon data (Caverns of Time, Quel'Danas)
OLD_WORLD_ART = {440: (131830, 0.5, 0.45), 4080: (131874, 0.5, 0.47)}
GENERIC = (131860, 0.5, 0.55)
UNUSED = re.compile(r"^(BETA|OLD|ZZ\w*|UNUSED|DEPRECATED|NYI|TEST)\b|^<|\[PH\]")


def areas():
    path = os.path.join(tbcdb.DIR, "db2", "AreaTable.csv")
    with open(path, encoding="utf-8") as f:
        return {int(r["ID"]): r for r in csv.DictReader(f)}


def zone_of(area, A):
    """the top-level zone id of an area (subzones roll up to their parent), or None."""
    seen = 0
    while area in A and int(A[area]["ParentAreaID"]) and seen < 10:
        area = int(A[area]["ParentAreaID"])
        seen += 1
    return area if area in A else None


def side_of(races):
    races = races or 0
    if not races:
        return None
    if races & ALLIANCE and not races & HORDE:
        return "A"
    if races & HORDE and not races & ALLIANCE:
        return "H"
    return None


def chains(qt):
    """{quest id: (step, steps)} from PrevQuestId / NextQuestId / NextQuestInChain."""
    nexts, prevs = {}, {}
    for q in qt.values():
        e = q["entry"]
        if q["PrevQuestId"] and q["PrevQuestId"] > 0 and q["PrevQuestId"] in qt:
            prevs.setdefault(e, set()).add(q["PrevQuestId"])
            nexts.setdefault(q["PrevQuestId"], set()).add(e)
        for k in ("NextQuestInChain", "NextQuestId"):
            n = q[k]
            if n and n > 0 and n in qt and n != e:
                nexts.setdefault(e, set()).add(n)
                prevs.setdefault(n, set()).add(e)

    def walk(e, links, prefer):
        n, seen = 0, {e}
        while True:
            opts = links.get(e)
            if not opts:
                return n
            nxt = prefer(e, opts)
            if nxt is None or nxt in seen:
                return n
            seen.add(nxt)
            e = nxt
            n += 1

    def pick_prev(e, opts):
        p = qt[e]["PrevQuestId"]
        if p and p > 0 and p in opts:
            return p
        return min(opts) if len(opts) == 1 else None

    def pick_next(e, opts):
        n = qt[e]["NextQuestInChain"]
        if n and n in opts:
            return n
        return min(opts) if len(opts) == 1 else None

    out = {}
    for e in qt:
        before = walk(e, prevs, pick_prev)
        after = walk(e, nexts, pick_next)
        if before + after >= 1:
            out[e] = (before + 1, before + after + 1)
    return out


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    db = tbcdb.load()
    A = areas()
    qt = db.index("quest_template", "entry")
    chain = chains(qt)
    odd = []

    # a quest someone can actually get: an NPC / object gives it, or an item starts it (drops unused BETA / OLD rows)
    given = {r["quest"] for t in ("creature_questrelation", "gameobject_questrelation") for r in db.rows(t)}
    given |= {r["startquest"] for r in db.rows("item_template") if r["startquest"]}

    picked = []
    for q in qt.values():
        title = (q["Title"] or "").strip()
        sp = q["SuggestedPlayers"] or 0
        if not (sp >= 2 or q["Type"] == 1):
            continue
        if not title or q["Type"] in SKIP_TYPES or (q["QuestFlags"] or 0) & FLAG_DAILY:
            continue
        if q["RequiredClasses"] or q["RequiredSkill"]:
            continue
        zos = q["ZoneOrSort"] or 0
        if zos <= 0:
            continue
        zone = zone_of(zos, A)
        if zone is None:
            odd.append("unknown area %d: %d %s" % (zos, q["entry"], title))
            continue
        if int(A[zone]["ContinentID"]) not in OPEN_WORLD_MAPS:
            continue                                     # dungeon / raid quest
        if UNUSED.match(title):
            odd.append("unused (title): %d %s%s" % (q["entry"], title, "" if q["entry"] in given else ", no giver"))
            continue
        if q["entry"] not in given:
            odd.append("no giver (dropped): %d %s" % (q["entry"], title))
            continue
        picked.append((q, zone, title, sp))

    outland_ids = [z[0] for z in OUTLAND]
    zones_present = {z for _, z, _, _ in picked}
    zone_list = [z for z in OUTLAND if z[0] in zones_present]
    others = sorted((A[z]["AreaName_lang"], z) for z in zones_present if z not in outland_ids)
    for name, z in others:
        screen, cx, cy = OLD_WORLD_ART.get(z, GENERIC)
        zone_list.append((z, name, screen, cx, cy))
    zindex = {z[0]: i + 1 for i, z in enumerate(zone_list)}

    # Alliance / Horde twins: same title, same zone, one per side
    by_key = {}
    for q, zone, title, sp in picked:
        by_key.setdefault((title, zone), []).append(q)
    twin = {}
    for (title, zone), qs in by_key.items():
        a = [q for q in qs if side_of(q["RequiredRaces"]) == "A"]
        h = [q for q in qs if side_of(q["RequiredRaces"]) == "H"]
        if len(a) == 1 and len(h) == 1:
            twin[a[0]["entry"]] = h[0]["entry"]
            twin[h[0]["entry"]] = a[0]["entry"]
        elif len(qs) > 1:
            odd.append("same title twice in one zone (no twin pair): %s %s" % (title, [q["entry"] for q in qs]))

    rows = []
    for q, zone, title, sp in picked:
        lvl = q["QuestLevel"] if q["QuestLevel"] and q["QuestLevel"] > 0 else q["MinLevel"] or 0
        if q["QuestLevel"] is None or q["QuestLevel"] <= 0:
            odd.append("no quest level (%s): %d %s" % (q["QuestLevel"], q["entry"], title))
        step, steps = chain.get(q["entry"], (None, None))
        rows.append((zindex[zone], lvl, title, q["entry"], sp if sp >= 2 else None, step, steps,
                     side_of(q["RequiredRaces"]), twin.get(q["entry"])))
    rows.sort()

    def val(v):
        if v is None:
            return "nil"
        if isinstance(v, str):
            return lua_str(v)
        return str(v)

    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("Data/GroupQuests.lua", ...) then return end '
        '-- DisasterZone Data/GroupQuests.lua',
        "-- The group quests of TBC by zone, for the Groups board (a group lists one or several quests in one zone).",
        "-- AUTO-GENERATED by dev/generators/gen_group_quests.py from the cMaNGOS TBC world DB - do not edit by hand.",
        "-- screen = the zone's loading screen (FileDataID, 2048 x 2048 shown at 4:3; cx, cy = the centre a card shows).",
        "local _, ns = ...",
        "",
        "ns.Data = ns.Data or {}",
        "ns.Data.GroupQuests = {",
        "    zones = {   -- in board order",
    ]
    for z, name, screen, cx, cy in zone_list:
        lines.append('        { key = %s, name = %s, area = %d, screen = %d, cx = %s, cy = %s },'
                     % (lua_str(name.replace(" ", "").replace("'", "")), lua_str(name), z, screen, cx, cy))
    lines += [
        "    },",
        "    -- { id, name, zone index, players (nil = a group quest with no suggested size), step, steps, side, twin }",
        "    quests = {",
    ]
    for zi, lvl, title, e, sp, step, steps, side, tw in rows:
        vals = [e, title, zi, sp, step, steps, side, tw]
        while vals and vals[-1] is None:
            vals.pop()
        lines.append("        { %s }," % ", ".join(val(v) for v in vals))
    lines += ["    },", "}", ""]
    data = "\n".join(lines).encode("utf-8")
    with open(OUT, "wb") as f:
        f.write(data)

    print("zones %d, quests %d, %d bytes -> %s" % (len(zone_list), len(rows), len(data), OUT))
    for z in zone_list:
        print("  %-28s %3d" % (z[1], sum(1 for r in rows if r[0] == zindex[z[0]])))
    for o in odd:
        print("odd:", o)


if __name__ == "__main__":
    main()
