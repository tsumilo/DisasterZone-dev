"""Replays a WoWCombatLog.txt through My Log (Core/MyLog.lua) in the mock client and checks its totals.

For every boss pull in the file (ENCOUNTER_START .. ENCOUNTER_END) it feeds the chosen player's view of the fight to
the real addon, then prints the addon's numbers next to a plain tally of the same lines, and the difference.
Compare the "addon" column with Warcraft Logs for the same pull: the target is within 0.1 %.

Usage (from dev):
  luaenv\\Scripts\\python.exe tools\\combatlog_replay.py <WoWCombatLog.txt> <PlayerName> [--adv N] [--json out.json]

Get a log in game with /combatlog (Logs\\WoWCombatLog.txt). Advanced combat logging (System > Network) adds a block
of unit fields after each spell prefix; the tool finds it (or pass --adv with its field count).

What it can't know from a log file: the client's cast bar events. Casts are rebuilt from SPELL_CAST_START /
SPELL_CAST_SUCCESS / SPELL_CAST_FAILED, so active time is close but not exact.
"""
import argparse
import csv
import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

MINE = 0x1
GUID_RE = re.compile(r"^(Player|Creature|Pet|Vehicle|GameObject)-|^0000000000000000$|^0$")
DAMAGE = {"SWING_DAMAGE", "SPELL_DAMAGE", "SPELL_PERIODIC_DAMAGE", "RANGE_DAMAGE", "DAMAGE_SHIELD", "DAMAGE_SPLIT",
          "SPELL_BUILDING_DAMAGE", "ENVIRONMENTAL_DAMAGE"}
HEAL = {"SPELL_HEAL", "SPELL_PERIODIC_HEAL"}
# events whose 3-field spell prefix may be followed by the advanced block
ADV_EVENTS = DAMAGE | HEAL | {"SPELL_ENERGIZE", "SPELL_PERIODIC_ENERGIZE", "SPELL_CAST_SUCCESS", "SWING_DAMAGE_LANDED"}


def parse_line(line):
    """'10/6 21:03:12.345  EVENT,a,b,...' -> (seconds, [EVENT, a, b, ...]) or None."""
    m = re.match(r"^(\d+)/(\d+)(?:/\d+)?\s+(\d+):(\d+):(\d+)\.(\d+)(?:[-+]\d+)?\s\s(.*)$", line.rstrip("\r\n"))
    if not m:
        return None
    _, _, hh, mm, ss, ms, rest = m.groups()
    t = int(hh) * 3600 + int(mm) * 60 + int(ss) + int(ms) / (10 ** len(ms))
    fields = next(csv.reader(io.StringIO(rest), skipinitialspace=False))
    return t, fields


def value(tok):
    if tok == "nil":
        return None
    if re.match(r"^-?\d+$", tok):
        return int(tok)
    if re.match(r"^0x[0-9a-fA-F]+$", tok):
        return int(tok, 16)
    if re.match(r"^-?\d+\.\d+$", tok):
        return float(tok)
    return tok


def damage_suffix(sfx):
    """File damage suffix -> the API's (amount, overkill, school, resisted, blocked, absorbed, crit, glancing,
    crushing, offhand). Newer files add baseAmount after amount: find the school (hex) to tell."""
    if len(sfx) >= 3 and sfx[2].startswith("0x"):
        out = [sfx[0]] + sfx[1:]
    elif len(sfx) >= 4 and sfx[3].startswith("0x"):
        out = [sfx[0]] + sfx[2:]          # drop baseAmount
    else:
        out = list(sfx)
    out = out + ["nil"] * (10 - len(out))
    return out[:10]


def split_event(fields, adv):
    """[EVENT, 8 unit fields, rest] -> the API payload after the 8 unit fields (advanced block removed)."""
    sub = fields[0]
    rest = fields[9:]
    has_prefix = not sub.startswith("SWING") and sub not in ("UNIT_DIED", "ENVIRONMENTAL_DAMAGE", "UNIT_DESTROYED",
                                                            "PARTY_KILL")
    if sub == "ENVIRONMENTAL_DAMAGE":
        # env type comes after the advanced block in files
        if adv and len(rest) > adv and GUID_RE.match(rest[0] or ""):
            rest = rest[adv:]
        return [rest[0]] + damage_suffix(rest[1:])
    prefix = rest[:3] if has_prefix else []
    body = rest[3:] if has_prefix else rest
    if adv and (sub in ADV_EVENTS or sub.startswith("SWING_DAMAGE")) and len(body) > adv and GUID_RE.match(body[0] or ""):
        body = body[adv:]
    if sub in DAMAGE:
        body = damage_suffix(body)
    elif sub in HEAL:
        # amount, [baseAmount], overhealing, absorbed, critical
        if len(body) >= 5:
            body = [body[0]] + body[2:5]
    return prefix + body


def guess_adv(lines):
    """Advanced block size: the gap between a SPELL_DAMAGE prefix and its damage suffix."""
    for t, f in lines:
        if f[0] == "SPELL_DAMAGE" and len(f) > 13 and GUID_RE.match(f[12] or ""):
            for n in (17, 19, 16, 18, 15):
                sfx = f[12 + n:]
                if len(sfx) >= 9 and (sfx[2].startswith("0x") or (len(sfx) > 3 and sfx[3].startswith("0x"))):
                    return n
        if f[0] == "SPELL_DAMAGE" and len(f) > 13:
            return 0
    return 0


def pulls_in(lines):
    out, cur = [], None
    for t, f in lines:
        if f[0] == "ENCOUNTER_START":
            cur = {"enc": int(f[1]), "name": f[2], "diff": int(f[3]), "size": int(f[4]), "t0": t, "lines": []}
        elif f[0] == "ENCOUNTER_END" and cur:
            cur["t1"] = t
            cur["kill"] = f[5] == "1"
            out.append(cur)
            cur = None
        elif cur:
            cur["lines"].append((t, f))
    return out


def reference(pull, me, adv):
    """Plain tally with the addon's counting rules (amount - overkill + absorbed; healing - overhealing)."""
    d = h = oh = taken = 0
    for t, f in pull["lines"]:
        sub = f[0]
        if sub not in DAMAGE and sub not in HEAL and sub != "SWING_MISSED" and sub != "SPELL_MISSED":
            continue
        src, sflags, dst = f[1], value(f[3]), f[5]
        p = [value(x) for x in split_event(f, adv)]
        mine = src == me or (isinstance(sflags, int) and sflags & MINE and not src.startswith("Player-"))
        if sub in DAMAGE:
            base = 0 if sub.startswith("SWING") else (1 if sub == "ENVIRONMENTAL_DAMAGE" else 3)
            amount, overkill, absorbed = p[base] or 0, p[base + 1] or 0, p[base + 5] or 0
            if mine and sub != "ENVIRONMENTAL_DAMAGE":
                d += max(amount - max(overkill, 0) + absorbed, 0)
            if dst == me:
                taken += amount - max(overkill, 0) + absorbed
        elif sub in HEAL and mine:
            amount, over = p[3] or 0, p[4] or 0
            h += max(amount - over, 0)
            oh += over
        elif dst == me:
            miss = p[0] if sub == "SWING_MISSED" else p[3]
            amt = p[2] if sub == "SWING_MISSED" else p[5]
            if miss == "ABSORB" and amt:
                taken += amt
    return {"d": d, "h": h, "oh": oh, "t": taken}


def replay(path, player, adv=None, quiet=False):
    from harness import World, Client
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = [x for x in (parse_line(l) for l in fh) if x]
    if adv is None:
        adv = guess_adv(lines)
    me = None
    for t, f in lines:
        if len(f) > 2 and f[2].split("-")[0] == player and f[1].startswith("Player-"):
            me = f[1]
            break
    if not me:
        raise SystemExit("player %s not found in the log" % player)
    w = World()
    w.auto_session = False
    cl = Client(w, player, class_file="WARLOCK", guild_rank=3)
    cl.load_addon()
    w.tick(2)
    cl.eval("ns.DB:SetSetting('mylog.enabled', true); ns.DB:SetSetting('mylog.heroics', true)")
    my_guid = cl.eval("return UnitGUID('player')")
    results = []
    for pull in pulls_in(lines):
        w.enter_instance("Replay", 1, "raid" if pull["size"] > 5 else "party", pull["size"], difficulty_id=pull["diff"])
        w.tick(0.1)
        cl.fire("ENCOUNTER_START", pull["enc"], pull["name"], pull["diff"], pull["size"])
        now = pull["t0"]
        casting = None
        for t, f in pull["lines"]:
            if t > now:
                w.tick(t - now, step=max(t - now, 0.05))
                now = t
            sub = f[0]
            p = [value(x) for x in split_event(f, adv)]
            src, dst = f[1], f[5]
            args = [t, sub, False,
                    my_guid if src == me else src, f[2], value(f[3]), value(f[4]),
                    my_guid if dst == me else dst, f[6], value(f[7]), value(f[8])]
            # absorbs name the caster inside the payload
            p = [my_guid if x == me else x for x in p]
            cl.combat_log(*(args + p))
            if src == me:
                if sub == "SPELL_CAST_START":
                    casting = (t, p[0])
                    cl.eval("local n = ...; __MOCK.casting = { 'x', n * 1000, (n + 2.5) * 1000, 0 }", cl.eval("return GetTime()"))
                    cl.fire("UNIT_SPELLCAST_START", "player", "r", p[0])
                elif sub == "SPELL_CAST_SUCCESS":
                    cl.eval("__MOCK.casting = nil")
                    cl.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "r", p[0])
                    casting = None
                elif sub == "SPELL_CAST_FAILED" and casting:
                    cl.eval("__MOCK.casting = nil")
                    cl.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "r", p[0])
                    casting = None
        if pull["t1"] > now:
            w.tick(pull["t1"] - now, step=max(pull["t1"] - now, 0.05))
        cl.fire("ENCOUNTER_END", pull["enc"], pull["name"], pull["diff"], pull["size"], 1 if pull["kill"] else 0)
        got = cl.eval_py("local p = ns.MyLog:GetPulls(); return p[#p]")
        ref = reference(pull, me, adv)
        results.append({"boss": pull["name"], "kill": pull["kill"], "dur": got["dur"], "addon": got["s"], "ref": ref})
    if not quiet:
        print("advanced block: %d fields" % adv)
        for r in results:
            print("\n%s (%s, %.1fs)" % (r["boss"], "kill" if r["kill"] else "wipe", r["dur"]))
            for k, label in (("d", "damage"), ("h", "healing"), ("oh", "overhealing"), ("t", "taken")):
                a, b = r["addon"].get(k, 0), r["ref"][k]
                diff = 0 if a == b else (abs(a - b) / max(b, 1) * 100)
                print("  %-12s addon %12s   tally %12s   %s" % (label, a, b, "ok" if diff <= 0.1 else "OFF %.2f%%" % diff))
            print("  DPS %.1f  HPS %.1f  active %s" % (r["addon"]["dps"], r["addon"]["hps"],
                  ("%.1f%%" % (r["addon"]["act"] * 100)) if r["addon"].get("act") is not None else "?"))
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("player")
    ap.add_argument("--adv", type=int, default=None, help="advanced logging block size (default: detect)")
    ap.add_argument("--json", help="write the results here")
    a = ap.parse_args()
    res = replay(a.log, a.player, a.adv)
    if a.json:
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump(res, fh, indent=1)
    bad = [r for r in res for k in ("d", "h", "oh", "t") if r["addon"].get(k, 0) != r["ref"][k]]
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
