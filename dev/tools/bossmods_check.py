r"""Checks the boss mods data files (addon/DisasterZone/Data/BossMods/*.lua) against dev/docs/bossmods/DATA_FORMAT.md:
every field known and of the right type, keys unique, triggers well formed, every spell id in the 2.5.6 client's
SpellName table (wago cache, see generators/spell_visuals.py), boss keys in Data/Items.lua, npc ids numbers.
Run (from dev): luaenv\Scripts\python.exe tools\bossmods_check.py [Raid ...]      exit 1 on any problem
"""
import os
import re
import sys

import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
ADDON = os.path.join(DEV, "..", "addon", "DisasterZone")
DATA = os.path.join(ADDON, "Data", "BossMods")
sys.path.insert(0, os.path.join(DEV, "generators"))

BOSS_FIELDS = {"enc", "npc", "alerts", "fn", "phases", "engage"}
ALERT_FIELDS = {"key", "kind", "spell", "icon", "text", "sub", "role", "on", "start", "cd", "stop", "after", "dur", "yd",
                "me", "meText", "phase", "setPhase", "count", "src", "once", "delay", "throttle", "loop", "learn"}
KINDS = {"bar", "warn", "you", "range"}
WORDS = {"CAST": "ids", "SUCCESS": "ids", "AURA": "ids", "AURAGONE": "ids", "SUMMON": "ids", "HIT": "ids", "HEAL": "ids",
         "DIES": "ids", "WIDGET": "ids", "UCAST": "ids", "SPAWN": "ids", "BACK": "ids", "HP": "hp", "YELL": "text",
         "EMOTE": "text", "ENGAGE": "none", "PHASE": "num"}
NOT_SPELLS = ("DIES", "WIDGET", "SPAWN", "BACK")      # (creature / widget ids)


def boss_keys():
    keys, raid = set(), None
    for line in open(os.path.join(ADDON, "Data", "Items.lua"), encoding="utf-8"):
        m = re.match(r'^  \{ key = "(\w+)"', line)
        if m:
            raid = m.group(1)
        m = re.match(r'^    \{ key = "(\w+)"', line)
        if m and raid:
            keys.add("%s:%s" % (raid, m.group(1)))
    keys.add("HyjalSummit:Waves")
    return keys


def spell_names():
    try:
        import spell_visuals
        return {int(r["ID"]): r["Name_lang"] for r in spell_visuals.table("SpellName")}
    except Exception as e:  # noqa: BLE001 (offline: skip the id check, say so)
        print("! spell table unavailable (%s): spell ids not checked" % e)
        return None


def to_py(lua, v):
    if lupa.lua_type(v) == "table":
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [to_py(lua, v[k]) for k in sorted(keys)]
        return {k: to_py(lua, v[k]) for k in keys}
    if lupa.lua_type(v) == "function":
        return "<fn>"
    return v


def triggers(v):
    if v is None:
        return []
    return [v] if isinstance(v, str) else list(v)


def check_trigger(t, where, names, out):
    parts = t.split()
    if not parts or parts[0] not in WORDS:
        out.append("%s: unknown trigger %r" % (where, t))
        return
    form, rest = WORDS[parts[0]], parts[1:]
    if form == "ids":
        if not rest or not all(p.isdigit() for p in rest):
            out.append("%s: %r needs ids" % (where, t))
        elif names is not None and parts[0] not in NOT_SPELLS:
            for p in rest:
                if int(p) not in names:
                    out.append("%s: spell %s not in the 2.5.6 client" % (where, p))
    elif form == "hp":
        if not (1 <= len(rest) <= 2 and all(p.isdigit() for p in rest)):
            out.append("%s: %r must be HP <pct> [npc]" % (where, t))
    elif form == "text":
        if not rest:
            out.append("%s: %r needs text" % (where, t))
    elif form == "num":
        if len(rest) != 1 or not rest[0].isdigit():
            out.append("%s: %r needs one number" % (where, t))
    elif rest:
        out.append("%s: %r takes nothing" % (where, t))


def seconds(v):
    if isinstance(v, (int, float)):
        return v > 0
    return isinstance(v, list) and len(v) == 2 and all(isinstance(x, (int, float)) for x in v) and 0 < v[0] <= v[1]


def check(raids):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    ns = lua.table()
    run = lua.eval("function(src, name, ns) local f, e = load(src, '@' .. name); if not f then error(e) end; f('DisasterZone', ns) end")
    out, names, known = [], spell_names(), boss_keys()
    files = sorted(f for f in os.listdir(DATA) if f.endswith(".lua")) if os.path.isdir(DATA) else []
    for f in files:
        if raids and f[:-4] not in raids:
            continue
        src = open(os.path.join(DATA, f), encoding="utf-8").read()
        first = src.split("\n", 1)[0]
        if not first.startswith('if DisasterZoneBoot and DisasterZoneBoot.Run("Data/BossMods/%s", ...) then return end' % f):
            out.append("%s: line 1 must be the boot guard for Data/BossMods/%s" % (f, f))
        try:
            run(src, f, ns)
        except lupa.LuaError as e:
            out.append("%s: %s" % (f, e))
    bm = to_py(lua, ns["Data"]["BossMods"]) if ns["Data"] and ns["Data"]["BossMods"] else {}
    n_alerts = 0
    for bk, b in sorted(bm.items()):
        if raids and bk.split(":")[0] not in raids:
            continue
        if bk not in known:
            out.append("%s: not a boss key of Data/Items.lua" % bk)
        for k in b:
            if k not in BOSS_FIELDS:
                out.append("%s: unknown boss field %r" % (bk, k))
        if not isinstance(b.get("npc"), list) or not all(isinstance(x, int) for x in b["npc"]):
            out.append("%s: npc must be a list of creature ids" % bk)
        if bk != "HyjalSummit:Waves" and (not isinstance(b.get("enc"), list) or not b["enc"]):
            out.append("%s: enc must list the encounter ids" % bk)
        seen = set()
        for i, a in enumerate(b.get("alerts") or []):
            n_alerts += 1
            w = "%s #%d %s" % (bk, i + 1, a.get("key"))
            for k in a:
                if k not in ALERT_FIELDS:
                    out.append("%s: unknown field %r" % (w, k))
            key = a.get("key")
            if not isinstance(key, str) or not re.match(r"^[a-z][a-z0-9]*$", key):
                out.append("%s: key must be lowercase letters/digits" % w)
            elif key in seen:
                out.append("%s: duplicate key" % w)
            seen.add(key)
            kind = a.get("kind")
            if kind not in KINDS:
                out.append("%s: kind must be one of %s" % (w, sorted(KINDS)))
            sp = a.get("spell")
            if sp is not None and names is not None and sp not in names:
                out.append("%s: spell %s not in the 2.5.6 client" % (w, sp))
            if sp is None and not a.get("text"):
                out.append("%s: needs a spell or a text" % w)
            if a.get("role") not in (None, "T", "H"):
                out.append("%s: role must be T or H" % w)
            for f in ("on", "stop"):
                for t in triggers(a.get(f)):
                    if not isinstance(t, str):
                        out.append("%s: %s must be strings" % (w, f))
                    else:
                        check_trigger(t, w, names, out)
            for f in ("start", "cd"):
                if a.get(f) is not None and not seconds(a[f]):
                    out.append("%s: %s must be seconds or { min, max }" % (w, f))
            if kind == "bar" and a.get("start") is None and a.get("cd") is None:
                out.append("%s: a bar needs start or cd" % w)
            if kind == "bar" and a.get("on") is not None and a.get("cd") is None:
                out.append("%s: a bar with a trigger needs cd" % w)
            if kind == "range" and not isinstance(a.get("yd"), (int, float)):
                out.append("%s: a range frame needs yd" % w)
            if kind in ("warn", "you", "range") and a.get("on") is None:
                out.append("%s: needs a trigger (on)" % w)
            if a.get("count") not in (None, True, "stack", "next"):
                out.append("%s: count must be true, 'stack' or 'next'" % w)
            for f in ("phase",):
                v = a.get(f)
                if v is not None and not (isinstance(v, int) or (isinstance(v, list) and all(isinstance(x, int) for x in v))):
                    out.append("%s: phase must be a number or a list" % w)
    for line in out:
        print(line)
    print("%d bosses, %d alerts, %d problems" % (len(bm), n_alerts, len(out)))
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(check(set(sys.argv[1:])))
