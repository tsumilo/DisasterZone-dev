"""tools/combatlog_replay.py on written WoWCombatLog.txt files: plain and with advanced logging (17 unit fields after
the spell prefix), with and without the newer baseAmount field; a kill and a wipe; the addon's totals equal to the
tally of the lines.

Run: luaenv\\Scripts\\python.exe tests\\mylog\\test_replay.py [-k name]
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all  # noqa: E402
import combatlog_replay as R  # noqa: E402  (tools is on the path through _common)

ME = "Player-4000-0A1B2C3D"
BOSS = "Creature-0-4000-548-100-21216-0000AB1234"
PET = "Pet-0-4000-548-100-17252-0100AB0001"
OTHER = "Player-4000-0BEEF002"


def adv_block():
    return [ME, "0000000000000000", "9000", "9000", "100", "1200", "3000", "0", "8000", "8000", "0",
            "-12.5", "45.25", "0", "1.5", "70", "128"][:17]


def write_log(adv=False, base=False):
    lines = []
    t = [21 * 3600 + 3 * 60]

    def at(dt, text):
        t[0] += dt
        s = t[0]
        hh, mm, ss = int(s // 3600), int(s % 3600 // 60), s % 60
        lines.append("10/6 %02d:%02d:%06.3f  %s" % (hh, mm, ss, text))

    def unit(src, sname, sflags, dst, dname, dflags):
        return '%s,"%s",%s,0x0,%s,"%s",%s,0x0' % (src, sname, sflags, dst, dname, dflags)

    def spell_dmg(dt, src, sname, sflags, dst, dname, dflags, sid, name, amount, overkill="-1", absorbed="0",
                  crit="nil"):
        mid = (",".join(adv_block()) + ",") if adv else ""
        b = ("%s," % amount) if base else ""
        at(dt, 'SPELL_DAMAGE,%s,%d,"%s",0x20,%s%s,%s%s,0x20,0,0,%s,%s,nil,nil'
           % (unit(src, sname, sflags, dst, dname, dflags), sid, name, mid, amount, b, overkill, absorbed, crit))

    def heal(dt, src, dst, amount, over):
        mid = (",".join(adv_block()) + ",") if adv else ""
        b = ("%s," % amount) if base else ""
        at(dt, 'SPELL_HEAL,%s,25235,"Flash Heal",0x2,%s%s,%s%s,0,nil'
           % (unit(src, "Lux", "0x511", dst, "Holyvee", "0x514"), mid, amount, b, over))

    for enc, name, kill in ((623, "Hydross the Unstable", True), (628, "Lady Vashj", False)):
        at(1, 'ENCOUNTER_START,%d,"%s",4,25' % (enc, name))
        spell_dmg(0.5, ME, "Lux-Thunderstrike", "0x511", BOSS, name, "0xa48", 27209, "Shadow Bolt", 2000)
        spell_dmg(1.2, ME, "Lux-Thunderstrike", "0x511", BOSS, name, "0xa48", 27209, "Shadow Bolt", 3100, crit="1")
        spell_dmg(1.0, ME, "Lux-Thunderstrike", "0x511", BOSS, name, "0xa48", 27209, "Shadow Bolt", 1800, "800")
        spell_dmg(0.3, PET, "Grimgor", "0x1111", BOSS, name, "0xa48", 30213, "Legion Strike", 700, absorbed="50")
        spell_dmg(0.3, OTHER, "Bob-Thunderstrike", "0x514", BOSS, name, "0xa48", 27209, "Shadow Bolt", 9999)
        spell_dmg(0.4, BOSS, name, "0xa48", ME, "Lux-Thunderstrike", "0x511", 38235, "Water Tomb", 1500, absorbed="200")
        heal(0.5, ME, OTHER, 3000, 1200)
        at(0.2, 'SWING_MISSED,%s,ABSORB,nil,900' % unit(BOSS, name, "0xa48", ME, "Lux-Thunderstrike", "0x511"))
        at(6, 'ENCOUNTER_END,%d,"%s",4,25,%d' % (enc, name, 1 if kill else 0))
    fd, path = tempfile.mkstemp(suffix=".txt")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    return path


def check(res):
    assert len(res) == 2, res
    assert res[0]["kill"] is True and res[1]["kill"] is False
    for r in res:
        a, ref = r["addon"], r["ref"]
        assert ref["d"] == 2000 + 3100 + 1000 + 750, ref
        assert ref["h"] == 1800 and ref["oh"] == 1200 and ref["t"] == 1700 + 900, ref
        for k in ("d", "h", "oh", "t"):
            assert a[k] == ref[k], (k, a, ref)


@case
def plain_log():
    path = write_log()
    try:
        assert R.guess_adv([x for x in (R.parse_line(l) for l in open(path)) if x]) == 0
        check(R.replay(path, "Lux", quiet=True))
    finally:
        os.remove(path)


@case
def advanced_logging():
    path = write_log(adv=True)
    try:
        assert R.guess_adv([x for x in (R.parse_line(l) for l in open(path)) if x]) == 17
        check(R.replay(path, "Lux", quiet=True))
    finally:
        os.remove(path)


@case
def advanced_logging_with_base_amount():
    path = write_log(adv=True, base=True)
    try:
        check(R.replay(path, "Lux", quiet=True))
    finally:
        os.remove(path)


if __name__ == "__main__":
    run_all()
