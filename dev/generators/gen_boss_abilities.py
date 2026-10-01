"""Boss abilities for the strategy boards (Addendum K): what each TBC raid boss casts and which buffs go on it, from the
installed DBM-Raids-BC modules (GPL-style addon data; only spell ids are taken).

Per module: SetEncounterID / SetCreatureID say which boss it is (matched to Data/Items.lua by encounter id, else by
creature id); the combat events it registers give the casts (SPELL_CAST_START / _SUCCESS) and the auras
(SPELL_AURA_APPLIED / _REMOVED / _APPLIED_DOSE); NewSpecialWarningInterrupt marks the interruptible casts;
NewCDTimer / NewNextTimer give a cast's cooldown.
The effects players can remove (dispel tables): every cast / aura id with a dispel type on wowhead's TBC spell page
(Magic, Curse, Poison, Disease, Enrage), cached in generators/data/spell_dispel.json as { "<id>": [name, type] }
("n/a" = not removable). wowhead answers 403 to scripts, so the cache is filled through a browser (same-origin
fetch of /tbc/spell=<id>, the cell after "Dispel type"); ids missing from the cache are printed. An effect DBM
warns the dispellers of the boss about (NewSpecialWarningDispel ... "MagicDispeller"), and every Enrage, sits on
the enemy (en = true).
Writes addon/CDLoot/Data/BossAbilities.lua:
  ns.Data.BossAbilities["<Raid>:<Boss>"] = { c = { { id, int = true, cd = 14 }, ... }, a = { id, ... },
                                             d = { { id, t = "m" | "c" | "p" | "d" | "e", en = true }, ... } }
Spell names and icons are read from the client at runtime (localized).
Run: luaenv\\Scripts\\python.exe generators\\gen_boss_abilities.py
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, "..", "..", "addon", "CDLoot")
DBM = os.path.join(r"C:\World of Warcraft\_anniversary_\Interface\AddOns", "DBM-Raids-BC")
OUT = os.path.join(ADDON, "Data", "BossAbilities.lua")
DISPEL_CACHE = os.path.join(HERE, "data", "spell_dispel.json")
DISPEL_CODE = {"Magic": "m", "Curse": "c", "Poison": "p", "Disease": "d", "Enrage": "e"}


def nums(s):
    return [int(x) for x in re.findall(r"\d+", s)]


def load_bosses():
    """[(ref, encounterID or None, npc set)] from Data/Items.lua."""
    out, raid = [], None
    for line in open(os.path.join(ADDON, "Data", "Items.lua"), encoding="utf-8"):
        m = re.match(r'^  \{ key = "(\w+)"', line)
        if m:
            raid = m.group(1)
            continue
        m = re.match(r'^    \{ key = "(\w+)", name = "[^"]*", npcIDs = \{([^}]*)\}(.*)', line)
        if m and raid:
            enc = re.search(r"encounterID = (\d+)", m.group(3))
            out.append(("%s:%s" % (raid, m.group(1)), int(enc.group(1)) if enc else None, set(nums(m.group(2)))))
    return out


def parse_mod(text):
    enc = re.search(r"SetEncounterID\((\d+)", text)
    cre = re.search(r"SetCreatureID\(([^)]*)\)", text)
    events = {}
    for block in re.findall(r"Register(?:EventsInCombat|Events)\((.*?)\)", text, re.S):
        for s in re.findall(r'"([A-Z_]+)((?: \d+)+)"', block):
            events.setdefault(s[0], set()).update(nums(s[1]))
    interrupts = set(int(x) for x in re.findall(r"NewSpecialWarningInterrupt\((\d+)", text))
    on_enemy = set(int(x) for x in re.findall(r'NewSpecialWarningDispel\((\d+),\s*"(?:MagicDispeller|RemoveEnrage)"', text))
    cds = {}
    for cd, sid in re.findall(r"New(?:CD|Next)Timer\(([\d.]+),\s*(\d+)", text):
        cds.setdefault(int(sid), float(cd))
    casts = set()
    for ev in ("SPELL_CAST_START", "SPELL_CAST_SUCCESS"):
        casts |= events.get(ev, set())
    casts |= interrupts
    auras = set()
    for ev in ("SPELL_AURA_APPLIED", "SPELL_AURA_REMOVED", "SPELL_AURA_APPLIED_DOSE", "SPELL_AURA_REFRESH"):
        auras |= events.get(ev, set())
    return {
        "enc": int(enc.group(1)) if enc else None,
        "npcs": set(nums(cre.group(1))) if cre else set(),
        "casts": casts, "auras": auras, "int": interrupts, "cd": cds, "enemy": on_enemy,
    }


# Casts DBM doesn't register, checked on wowhead (TBC): { ref: { spellID: interruptible } }.
EXTRA = {
    "BlackTemple:Council": {41472: True, 41471: False},     # Lady Malande: Divine Wrath, Empowered Smite
}


def main():
    bosses = load_bosses()
    by_enc = {}
    for ref, enc, npcs in bosses:
        if enc:
            by_enc.setdefault(enc, []).append(ref)
    data, unmatched = {}, []
    dispel = json.load(open(DISPEL_CACHE, encoding="utf-8")) if os.path.exists(DISPEL_CACHE) else {}
    unchecked = set()
    for root, _, files in os.walk(DBM):
        for f in sorted(files):
            if not f.endswith(".lua") or f.startswith("localization") or f.endswith("Frame.lua"):
                continue
            mod = parse_mod(open(os.path.join(root, f), encoding="utf-8", errors="replace").read())
            refs = by_enc.get(mod["enc"]) or [ref for ref, _, npcs in bosses if npcs & mod["npcs"]]
            if not refs:
                if mod["casts"] or mod["auras"]:
                    unmatched.append(f)
                continue
            for ref in refs:
                d = data.setdefault(ref, {"casts": set(), "auras": set(), "int": set(), "cd": {}, "enemy": set()})
                d["casts"] |= mod["casts"]
                d["enemy"] |= mod["enemy"]
                d["auras"] |= mod["auras"]
                d["int"] |= mod["int"]
                d["cd"].update(mod["cd"])
    for ref, extra in EXTRA.items():
        d = data.setdefault(ref, {"casts": set(), "auras": set(), "int": set(), "cd": {}, "enemy": set()})
        for sid, interruptible in extra.items():
            d["casts"].add(sid)
            if interruptible:
                d["int"].add(sid)
    lines = [
        "-- CDLoot: boss abilities for the strategy boards (Addendum K): per boss the casts (int = DBM warns to",
        "-- interrupt it, cd = its cooldown in seconds), the auras that go on its creatures, and d = the effects players",
        "-- can remove (t = m Magic / c Curse / p Poison / d Disease / e Enrage, en = it sits on the enemy). Spell ids",
        "-- only; names and icons come from the client. AUTO-GENERATED by gen_boss_abilities.py from DBM-Raids-BC and",
        "-- wowhead's dispel types; do not edit.",
        "local _, ns = ...",
        "ns.Data = ns.Data or {}",
        "ns.Data.BossAbilities = {",
    ]
    for ref, _, _ in bosses:
        d = data.get(ref)
        if not d or not (d["casts"] or d["auras"]):
            continue
        casts = []
        # interrupts first, then the rest by id
        for sid in sorted(d["casts"], key=lambda x: (x not in d["int"], x)):
            parts = ["id = %d" % sid]
            if sid in d["int"]:
                parts.append("int = true")
            if sid in d["cd"]:
                cd = d["cd"][sid]
                parts.append("cd = %s" % (int(cd) if cd == int(cd) else cd))
            casts.append("{ %s }" % ", ".join(parts))
        auras = sorted(d["auras"] - d["casts"])
        removable = []
        for sid in sorted(d["auras"] | d["casts"]):
            known = dispel.get(str(sid))
            if not known:
                unchecked.add(sid)
                continue
            code = DISPEL_CODE.get(known[1])
            if code:
                on_enemy = code == "e" or sid in d["enemy"]
                removable.append('{ id = %d, t = "%s"%s }' % (sid, code, ", en = true" if on_enemy else ""))
        lines.append('  ["%s"] = { c = { %s }, a = { %s }, d = { %s } },'
                     % (ref, ", ".join(casts), ", ".join(str(a) for a in auras), ", ".join(removable)))
    lines.append("}")
    open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print("bosses: %d" % sum(1 for l in lines if l.startswith('  ["')))
    if unchecked:
        print("no dispel type cached (generators/data/spell_dispel.json):", ", ".join(str(x) for x in sorted(unchecked)))
    if unmatched:
        print("unmatched modules:", ", ".join(unmatched))


if __name__ == "__main__":
    main()
