"""Dry streaks (1.3.5): how long a player has gone without loot, for the drop panel (Core/Attendance.lua
GetDryStreak, UI/DropPanel.lua Dry).

Covers: raids counted only after the last item (and only those the player came to, not benched; the night running now
never), boss kills added up, no item on record, offspec / disenchant / guild bank / dungeon awards and non-gear (bags, recipes, mounts) not ending a streak,
an item on an account-linked character ending it (a one-sided main claim does not), the guild council only (members
and raid-scope council see nothing), the cache following new awards, and the drop panel's meter + tooltip lines.

Run: luaenv\\Scripts\\python.exe tests\\attendance\\test_dry_streak.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(TESTS, "raidplan"))

from rp_common import World, Client, gm_pick, set_raid_leaders, K  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402

DAY = 86400
ITEM = 28510
# Gina = GM, Olly = officer (not on any list), Bob = guild council + raid leader, the rest members
NAMES = (("Gina", 0, "PALADIN"), ("Olly", 1, "DRUID"), ("Bob", 2, "MAGE"), ("Tank", 3, "WARRIOR"),
         ("Heal", 3, "PRIEST"), ("Dps", 3, "ROGUE"), ("Kai", 3, "HUNTER"))


def world():
    w = World()
    w.auto_session = False
    c = {}
    for name, rank, cls in NAMES:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ["Bob"])
    w.tick(2)
    return w, c


def now(cl):
    return cl.eval("return GetServerTime()")

# nights: [{ id, start (days ago), att: { name: kills | "bench" } }]; open = no stop (the night running now)
INJECT = """
local nights = ...
local g = ns.Guild:GetGuildKey()
local now = GetServerTime()
for _, n in ipairs(nights) do
    local start = now - n.ago * 86400
    local att = {}
    for name, k in pairs(n.att) do
        att[name] = { j = start, l = start + 3 * 3600, k = k == 'bench' and 0 or k, b = k == 'bench' or nil,
                      s = { start, start + 3 * 3600 } }
    end
    ns.db.raids[n.id] = { id = n.id, g = g, start = start, stop = (not n.open) and (start + 3 * 3600) or nil,
        zone = 'Karazhan', att = att, bosses = {}, endedBy = (not n.open) and 'x' or nil }
end
ns:Fire('RAIDLOG_CHANGED')
"""


def nights(cl, specs):
    fixed = []
    for n in specs:
        n = dict(n)
        n["att"] = {K(name): k for name, k in n["att"].items()}
        fixed.append(n)
    cl.eval(INJECT, fixed)


def award(cl, name, days_ago, reason=None, dg=None, sid=None, item=ITEM):
    e = cl.eval_py("local sid, i, w, ts, dg, r = ...; "
                   "return ns.Ledger:RecordRollAward(sid, i, w, '', nil, nil, ts, false, dg, r)",
                   sid or ("s-%s-%s-%s" % (name, days_ago, item)), item, K(name), now(cl) - int(days_ago * DAY), dg, reason)
    assert e, "award not recorded"
    return e


def dry(cl, name):
    return cl.eval_py("return ns.Attendance:GetDryStreak(...)", K(name))


# Bob = guild council. Five closed nights 14, 11, 7, 4 and 1 days ago.
FIVE = [{"id": "n14", "ago": 14, "att": {"Tank": 4, "Heal": 4, "Dps": 4}},
        {"id": "n11", "ago": 11, "att": {"Tank": 3, "Heal": 3, "Dps": "bench"}},
        {"id": "n7", "ago": 7, "att": {"Tank": 5, "Heal": 5}},
        {"id": "n4", "ago": 4, "att": {"Tank": 2, "Dps": 2}},
        {"id": "n1", "ago": 1, "att": {"Tank": 6, "Heal": 6, "Dps": 6}}]


@case
def raids_after_the_last_item_count():
    w, c = world()
    bob = c["Bob"]
    nights(bob, FIVE)
    award(bob, "Tank", 10)        # between n11 and n7
    d = dry(bob, "Tank")
    assert d["nights"] == 3 and d["bosses"] == 5 + 2 + 6, d
    assert d["last"]["w"] == K("Tank") and d["last"]["i"] == ITEM, d


@case
def no_item_on_record_counts_every_night_they_came():
    w, c = world()
    bob = c["Bob"]
    nights(bob, FIVE)
    d = dry(bob, "Heal")          # came to n14, n11, n7, n1
    assert d["nights"] == 4 and d["bosses"] == 18 and not d.get("last"), d


@case
def bench_and_absent_nights_do_not_count():
    w, c = world()
    bob = c["Bob"]
    nights(bob, FIVE)
    d = dry(bob, "Dps")           # n11 benched, n7 absent
    assert d["nights"] == 3 and d["bosses"] == 12, d


@case
def the_night_running_now_is_not_counted():
    w, c = world()
    bob = c["Bob"]
    nights(bob, FIVE + [{"id": "now", "ago": 0.05, "open": True, "att": {"Tank": 3}}])
    award(bob, "Tank", 10)
    assert dry(bob, "Tank")["nights"] == 3


@case
def offspec_disenchant_bank_and_dungeon_loot_do_not_end_it():
    w, c = world()
    bob = c["Bob"]
    nights(bob, FIVE)
    award(bob, "Tank", 12)
    award(bob, "Tank", 5, reason="os")
    award(bob, "Tank", 3, reason="de")
    award(bob, "Tank", 2, reason="bank")
    award(bob, "Tank", 0.5, dg=True)
    d = dry(bob, "Tank")
    assert d["nights"] == 4 and d["bosses"] == 3 + 5 + 2 + 6, d    # n11, n7, n4, n1 since the award 12 days ago
    award(bob, "Tank", 0.5, reason="up", sid="real")
    assert dry(bob, "Tank")["nights"] == 0   # (the cache follows the new award)


@case
def only_gear_ends_it():
    """A bag (Pit Lord's Satchel), a raid pattern and a mount are not loot received: no streak ends, "won N" and the
    raid log's items leave them out. A tier token and Magtheridon's Head turn into gear: they count."""
    w, c = world()
    bob = c["Bob"]
    nights(bob, FIVE)
    award(bob, "Tank", 12)
    since = now(bob) - 13 * DAY
    for item in (34845, 30280, 32458):        # Pit Lord's Satchel, Pattern: Belt of Blasting, Ashes of Al'ar
        award(bob, "Tank", 3, item=item)
    d = dry(bob, "Tank")
    assert d["nights"] == 4 and d["last"]["i"] == ITEM, d
    assert bob.eval("return ns.Ledger:CountSince(...)", K("Tank"), since) == 1
    assert bob.eval("return ns.ItemDB:IsGear(34845) == false and ns.ItemDB:IsGear(30280) == false "
                    "and ns.ItemDB:IsGear(28789) and ns.ItemDB:IsGear(29753) and ns.ItemDB:IsGear(32385)")
    award(bob, "Tank", 2, item=29753)          # Chestguard of the Fallen Defender (token)
    d = dry(bob, "Tank")
    assert d["nights"] == 1 and d["last"]["i"] == 29753, d
    award(bob, "Tank", 0.5, item=32385)        # Magtheridon's Head
    assert dry(bob, "Tank")["nights"] == 0
    assert bob.eval("return ns.Ledger:CountSince(...)", K("Tank"), since) == 3


@case
def an_item_on_a_linked_character_ends_it():
    w, c = world()
    bob = c["Bob"]
    nights(bob, FIVE)
    # Kai is Tank's alt, linked both ways (the guild's account link)
    bob.eval("local a, b = ...; local G = ns.Guild; local old = G.GetLinkedCharacters; "
             "G.GetLinkedCharacters = function(self, k) if k == a then return { b } elseif k == b then return { a } end "
             "return old(self, k) end", K("Tank"), K("Kai"))
    award(bob, "Kai", 5)
    d = dry(bob, "Tank")
    assert d["nights"] == 2 and d["last"]["w"] == K("Kai"), d


@case
def a_one_sided_main_claim_does_not():
    w, c = world()
    bob = c["Bob"]
    nights(bob, FIVE)
    # Kai names Tank as its main (Members tab), Tank never vouched for Kai
    bob.eval("local alt, main = ...; local P = ns.Professions; local old = P.GetMain; "
             "P.GetMain = function(self, k) if k == alt then return main end return old(self, k) end",
             K("Kai"), K("Tank"))
    award(bob, "Kai", 2)
    d = dry(bob, "Tank")
    assert d["nights"] == 5 and not d.get("last"), d


@case
def only_the_guild_council_sees_streaks():
    w, c = world()
    for name in ("Bob", "Gina", "Tank"):
        nights(c[name], FIVE)
    assert dry(c["Gina"], "Heal")["nights"] == 4          # the GM
    assert dry(c["Tank"], "Heal") is None                 # a member
    assert c["Olly"].eval("return ns.Attendance:CanSeeDryStreaks()") is False   # an officer off the lists
    # no closed night logged: nothing to say
    assert dry(c["Olly"], "Heal") is None


@case
def drop_panel_shows_the_meter_and_the_tooltip():
    w, c = world()
    bob = c["Bob"]
    bob.slash("/dz demo on")
    w.tick(2)
    bob.eval("ns.Loot:SimulateDrop()")
    w.tick(2)
    rows = bob.eval_py("""
        local out = {}
        for _, b in ipairs(ns.DropPanel.blocks or {}) do
            for _, r in ipairs(b.rows or {}) do
                if r:IsShown() and r.data and r.dry then
                    local d = ns.Attendance:GetDryStreak(r.data.key)
                    out[#out + 1] = { key = r.data.key, shown = r.dry:IsShown(), text = r.dry.fs:GetText(),
                                      status = r.status:GetText(), nights = d and d.nights }
                end
            end
        end
        return out""")
    rows = list(rows.values()) if isinstance(rows, dict) else list(rows or [])
    shown = [r for r in rows if r["shown"]]
    assert shown, rows
    for r in shown:
        n = r["nights"]
        assert r["text"] == "%d %s" % (n, "raid" if n == 1 else "raids"), r
        assert not r.get("status"), r            # (only where the status column is free)
    for r in rows:
        if r.get("status"):
            assert not r["shown"], r
    # the tooltip names the last item (or says there is none) and the raids since
    lines = bob.eval_py("""
        local key = ...
        for _, b in ipairs(ns.DropPanel.blocks or {}) do
            for _, r in ipairs(b.rows or {}) do
                if r:IsShown() and r.data and r.data.key == key then
                    r:GetScript('OnEnter')(r)
                    local out = {}
                    for i = 1, GameTooltip:NumLines() do
                        local fs = _G['GameTooltipTextLeft' .. i]
                        out[#out + 1] = fs and fs:GetText() or ''
                    end
                    return out
                end
            end
        end""", shown[0]["key"])
    text = " | ".join(strip_codes(x or "") for x in (list(lines.values()) if isinstance(lines, dict) else lines))
    assert ("Last item" in text and "Since then:" in text) or "No item on record" in text, text



@case
def drop_panel_roll_rows_columns():
    """1.3.5 layout B: the council's roll rows carry the vote rail, the attendance %, a short spec, the dry streak and
    the roll; the card has its column titles."""
    w, c = world()
    bob = c["Bob"]
    bob.slash("/dz demo on")
    w.tick(2)
    bob.eval("ns.Loot:SimulateDrop()")
    w.tick(1)
    bob.eval("local b = ns.DropPanel.blocks[1]; ns.DropPanel:StartRoll(b.itemID)")
    w.tick(12, 1)
    bob.eval("ns.DropPanel:Render()")
    rows = bob.eval_py("""
        local out = {}
        local b = ns.DropPanel.blocks[1]
        for _, r in ipairs(b.rows or {}) do
            if r:IsShown() and r.rollRow and r.data then
                out[#out + 1] = { key = r.data.key, spec = r.spec:GetText() or "", att = r.att:GetText() or "",
                    roll = r.roll:GetText() or "", rail = r.vBox:IsShown() or r.voteHint:IsShown(),
                    data = { spec = r.data.spec, roll = r.data.roll, response = r.data.response } }
            end
        end
        local titles = {}
        for _, fs in ipairs(b.colHead and b.colHead.fs or {}) do
            if fs:IsShown() then titles[#titles + 1] = fs:GetText() end
        end
        return { rows = out, titles = titles }""")
    lst = lambda v: list(v.values()) if isinstance(v, dict) else list(v or [])
    titles = lst(rows["titles"])
    assert titles == ["VOTE", "ATT", "SINCE LOOT", "ROLL"], titles
    rr = lst(rows["rows"])
    assert rr, rows
    for r in rr:
        assert strip_codes(r["att"]).endswith("%"), r
        spec = r["data"].get("spec") or ""
        short = {"Protection": "Prot", "Restoration": "Resto", "Marksmanship": "MM", "Destruction": "Destro"}
        if spec in short:
            assert r["spec"] == short[spec], r
        if r["data"].get("roll") is not None:
            assert strip_codes(r["roll"]) == str(r["data"]["roll"]), r
    assert any(r["rail"] for r in rr), rr        # (Bob is on the council: the squares he may vote in)

if __name__ == "__main__":
    run_all(globals())
