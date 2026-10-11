"""Refactor 1.4 (1D): one table of raid information (Data/Raids.lua + ItemDB lookups), and the raid plan digest of a busy
guild.

Covers: every raid of the item data resolving both ways (item key <-> planner key, instance id), the short names
(Sunwell = "SWP", D4), the loading-screen art for either key form (Hyjal gets its own picture in Loot rules and Prized
items, not the generic one), RaidPlanUI:RaidArt as a thin wrapper, RaidPlan's INSTANCES unchanged (saved data and the
sync use its keys), and a busy guild's digest (many occurrences + teams + series) keeping every team and series, so a
member who logs in late still gets them all.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raid_meta.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "loot-roll"))

from _common import case, run_all  # noqa: E402

from rp_common import DAY, K, world, now, team, create, signup  # noqa: E402

ROOT = "ns.db.raidplan['Casual Disaster-Thunderstrike']"

# RaidPlan's instances as 1.3.5 wrote them out by hand: the keys are saved and sent, so they must never change.
OLD_INSTANCES = [
    {"key": "kara", "name": "Karazhan", "size": 10, "instID": 532},
    {"key": "gruul", "name": "Gruul's Lair", "size": 25, "instID": 565},
    {"key": "mag", "name": "Magtheridon's Lair", "size": 25, "instID": 544},
    {"key": "ssc", "name": "Serpentshrine Cavern", "size": 25, "instID": 548},
    {"key": "tk", "name": "Tempest Keep", "size": 25, "instID": 550},
    {"key": "hyjal", "name": "Mount Hyjal", "size": 25, "instID": 534},
    {"key": "bt", "name": "Black Temple", "size": 25, "instID": 564},
    {"key": "za", "name": "Zul'Aman", "size": 10, "instID": 568},
    {"key": "swp", "name": "Sunwell Plateau", "size": 25, "instID": 580},
    {"key": "other", "name": "Other", "size": 25},
]

SHORT = {"Karazhan": "Kara", "GruulsLair": "Gruul", "MagtheridonsLair": "Mag", "SerpentshrineCavern": "SSC",
         "TempestKeep": "TK", "HyjalSummit": "Hyjal", "BlackTemple": "BT", "ZulAman": "ZA", "SunwellPlateau": "SWP"}

# The loading screens 1.3.5 showed per planner key (RaidPlanUI RAID_ART): file, centre x, centre y.
OLD_ART = {"kara": (131849, 0.30, 0.45), "gruul": (131842, 0.30, 0.45), "mag": (131846, 0.50, 0.42),
           "ssc": (131832, 0.32, 0.46), "tk": (131875, 0.50, 0.40), "hyjal": (131847, 0.40, 0.45),
           "bt": (131826, 0.30, 0.56), "za": (131884, 0.30, 0.45), "swp": (131873, 0.55, 0.50),
           "other": (131860, 0.50, 0.45)}


def old_art_coords(key, w, h, fw):
    """1.3.5's RaidPlanUI artCoords, to check the crop is unchanged."""
    a = OLD_ART.get(key, OLD_ART["other"])
    fh = fw * (4 / 3) * (h / w)
    left = min(max(a[1] - fw / 2, 0), 1 - fw)
    top = min(max(a[2] - fh / 2, 0.02), 0.98 - fh)
    return [a[0], left, left + fw, top, top + fh]


def small_world():
    return world((("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE")))


# ------------------------------------------------------------------------------------------------------------------
@case
def every_raid_resolves_both_ways():
    w, c = small_world()
    g = c["Gina"]
    rows = g.eval_py("""
        local out = {}
        for _, raid in ipairs(ns.Data.Raids) do
          if raid.instanceID then
            local plan = ns.ItemDB:PlanKeyOf(raid.key)
            local byPlan, rp = ns.ItemDB:GetRaidByPlanKey(plan)
            local byInst, ri = ns.ItemDB:GetRaidByInstance(raid.instanceID)
            out[#out + 1] = {
                key = raid.key, plan = plan, inst = raid.instanceID,
                backFromPlan = ns.ItemDB:ItemKeyOf(plan), itemKeyOfItem = ns.ItemDB:ItemKeyOf(raid.key),
                itemKeyOfInst = ns.ItemDB:ItemKeyOf(raid.instanceID), planOfPlan = ns.ItemDB:PlanKeyOf(plan),
                byPlan = byPlan, samePlanRaid = rp == raid, byInst = byInst, sameInstRaid = ri == raid,
                metaInst = ns.Data.RaidMeta[raid.key] and ns.Data.RaidMeta[raid.key].instanceID,
                shortItem = ns.ItemDB:RaidShort(raid.key), shortPlan = ns.ItemDB:RaidShort(plan),
            }
          end
        end
        return out
    """)
    assert [r["key"] for r in rows] == list(SHORT), rows
    plans = [r["plan"] for r in rows]
    assert plans == [x["key"] for x in OLD_INSTANCES[:-1]], plans
    for r in rows:
        assert r["backFromPlan"] == r["key"] and r["itemKeyOfItem"] == r["key"] and r["itemKeyOfInst"] == r["key"], r
        assert r["planOfPlan"] == r["plan"], r
        assert r["byPlan"] == r["key"] and r["samePlanRaid"] is True, r
        assert r["byInst"] == r["key"] and r["sameInstRaid"] is True, r
        assert r["metaInst"] == r["inst"], r
        assert r["shortItem"] == SHORT[r["key"]] and r["shortPlan"] == SHORT[r["key"]], r
    # every meta entry is a raid of the item data (no strays), with map names and ids
    stray = g.eval_py("""
        local out = {}
        for key, m in pairs(ns.Data.RaidMeta) do
            if not ns.ItemDB:GetRaid(key) or (m.instanceID and (type(m.mapNames) ~= "table" or not m.mapNames[1]
                or type(m.mapIDs) ~= "table" or not m.mapIDs[1])) then out[#out + 1] = key end
        end
        return out
    """)
    assert stray == [], stray
    # world bosses: a raid of the item data, but no instance (no planner key, the generic picture)
    assert g.eval("return ns.ItemDB:ItemKeyOf('WorldBosses')") == "WorldBosses"
    assert g.eval("return ns.ItemDB:PlanKeyOf('WorldBosses')") is None
    assert g.eval("return ns.ItemDB:RaidShort('WorldBosses')") == "World"
    assert g.eval_py("return { ns.ItemDB:RaidArt('WorldBosses') }")[0] == 131860
    # anything else: nil (callers fall back)
    for bad in ("other", "MountHyjal", "", "nope"):
        assert g.eval("return ns.ItemDB:ItemKeyOf(...)", bad) is None, bad
        assert g.eval("return ns.ItemDB:PlanKeyOf(...)", bad) is None, bad
        assert g.eval("return ns.ItemDB:RaidShort(...)", bad) is None, bad
        assert g.eval("return ns.ItemDB:GetRaidByPlanKey(...)", bad) is None, bad
    assert g.eval("return ns.ItemDB:GetRaidByInstance(1)") is None
    assert g.eval("return ns.ItemDB:GetRaidByInstance(nil)") is None
    assert g.eval("return ns.ItemDB:RaidShort(nil)") is None
    w.assert_no_errors()


@case
def raid_art_matches_the_planner_for_either_key():
    w, c = small_world()
    g = c["Gina"]
    item_of = {v: k for k, v in g.eval_py(
        "local out = {}; for k, m in pairs(ns.Data.RaidMeta) do out[k] = m.planKey end; return out").items()}
    for plan in OLD_ART:
        for (wd, ht, fw) in ((300, 92, 0.95), (64, 38, 0.5), (770, 128, 0.95)):
            want = old_art_coords(plan, wd, ht, fw)
            got_plan = g.eval_py("return { ns.ItemDB:RaidArt(...) }", plan, wd, ht, fw)
            got_ui = g.eval_py("return { ns.RaidPlanUI:RaidArt(...) }", plan, wd, ht, fw)
            assert got_ui == got_plan, (plan, got_ui, got_plan)
            assert got_plan[0] == want[0] and all(abs(a - b) < 1e-9 for a, b in zip(got_plan[1:], want[1:])), \
                (plan, got_plan, want)
            if plan != "other":
                got_item = g.eval_py("return { ns.ItemDB:RaidArt(...) }", item_of[plan], wd, ht, fw)
                assert got_item == got_plan, (plan, got_item, got_plan)
    # the whole picture under the logo band; unknown keys get the generic screen
    assert g.eval_py("return { ns.ItemDB:RaidArt('HyjalSummit') }") == [131847, 0, 1, 0.29, 1]
    assert g.eval_py("return { ns.ItemDB:RaidArt(534) }") == [131847, 0, 1, 0.29, 1]
    for bad in ("MountHyjal", "other", "nope"):
        assert g.eval_py("return { ns.ItemDB:RaidArt(...) }", bad)[0] == 131860, bad
    assert g.eval_py("return { ns.ItemDB:RaidArt(nil, 300, 92, 0.95) }")[0] == 131860
    # under: the crop stays under the logo band (always, or only for a box lower than a height)
    top = g.eval_py("return { ns.ItemDB:RaidArt('za', 300, 300, 0.5, true) }")
    free = g.eval_py("return { ns.ItemDB:RaidArt('za', 300, 300, 0.5) }")
    assert free[3] < 0.29 and abs(top[3] - 0.29) < 1e-9, (free, top)
    assert abs((top[4] - top[3]) - (free[4] - free[3])) < 1e-9, (free, top)
    assert g.eval_py("return { ns.ItemDB:RaidArt('za', 300, 300, 0.5, 60) }") == free
    assert g.eval_py("return { ns.ItemDB:RaidArt('za', 300, 300, 0.5, 400) }") == top
    w.assert_no_errors()


@case
def hyjal_gets_its_picture_in_loot_rules_and_prized_items():
    w, c = small_world()
    g = c["Gina"]
    hyjal = old_art_coords("hyjal", 330, 30, 0.95)
    got = g.eval_py("""
        local tex = UIParent:CreateTexture()
        ns.PrizedUI:SetArt(tex, "HyjalSummit", 330, 30, 0.95)
        return { tex:GetTexture(), tex:GetTexCoord() }
    """)
    assert got[0] == hyjal[0], got
    # (cropped under the game's logo, as before)
    # (GetTexCoord gives the corners: ULx, ULy = left, top)
    assert abs(got[1] - hyjal[1]) < 1e-6, (got, hyjal)
    assert abs(got[2] - 0.29) < 1e-6 if hyjal[3] < 0.29 else abs(got[2] - hyjal[3]) < 1e-6, (got, hyjal)
    other = g.eval_py("""
        local tex = UIParent:CreateTexture()
        ns.PrizedUI:SetArt(tex, "WorldBosses", 330, 30, 0.95)
        return { tex:GetTexture() }
    """)
    assert other[0] == 131860, other
    # Loot rules: no raid art key map of its own any more (it asked for "MountHyjal", the data says "HyjalSummit")
    import harness
    for rel in ("UI/LootRulesUI.lua", "UI/PrizedUI.lua"):
        with open(os.path.join(harness.ADDON_DIR, rel), "rb") as fh:
            src = fh.read().decode("utf-8")
        assert "MountHyjal" not in src, rel
        assert "ItemDB:RaidArt(" in src, rel
    w.assert_no_errors()


@case
def planner_instances_are_unchanged():
    w, c = small_world()
    got = c["Bob"].eval_py("return ns.RaidPlan:GetInstances()")
    assert got == OLD_INSTANCES, got
    for inst in OLD_INSTANCES:
        assert c["Bob"].eval_py("return ns.RaidPlan:GetInstance(...)", inst["key"]) == inst
    w.assert_no_errors()


@case
def busy_guild_digest_keeps_every_team_and_series():
    """60 one-off raids + 12 weekly raids with sign-ups on 3 weeks each = 96 occurrences, plus 6 teams and the 12
    series: 114 items over the digest's 100. Sorted by name the occurrences (O:) came first and crowded out the series
    (S:) and every team (T:), so a member who logged in late never got them."""
    names = (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Uma", 3, "HUNTER"))
    w, c = world(names)
    bob, lee, uma = c["Bob"], c["Lee"], c["Uma"]
    uma.logout()
    w.tick(2)
    t0 = now(bob)
    tids = [team(bob, "Team %d" % i, ["Lee", "Uma"]) for i in range(6)]
    insts = ["kara", "gruul", "mag", "ssc", "tk", "hyjal", "bt", "za", "swp"]
    occs = []
    for i in range(12):
        # (a weekly raid that started under an hour ago: its first three weeks are listed and open to sign-ups)
        occ0 = create(bob, i=insts[i % len(insts)], t=t0 - 3000 + i * 60, weekly=True)
        sid = occ0.split("#")[0]
        occs += [sid + "#0", sid + "#1", sid + "#2"]
        w.tick(1)
    for i in range(60):
        occs.append(create(bob, i=insts[i % len(insts)], t=t0 + DAY + i * 3600))
        if i % 10 == 9:
            w.tick(1)
    w.tick(5)
    for occ in occs[:36]:
        res = signup(lee, occ, "A", 1)
        assert res["ok"] is True, (occ, res)
    w.tick(120)
    counts = bob.eval_py("local r = %s; local n = { T = 0, S = 0, E = 0, U = 0 }; "
                         "for k in pairs(n) do for _ in pairs(r[k]) do n[k] = n[k] + 1 end end; return n" % ROOT)
    assert counts == {"T": 6, "S": 12, "E": 60, "U": 36}, counts
    digest = bob.eval_py("return ns.RaidPlan:GetDigest()")
    assert len(digest) == 100, len(digest)
    kinds = {}
    for item in digest:
        kinds[item[0]] = kinds.get(item[0], 0) + 1
    assert kinds == {"T": 6, "S": 12, "O": 82}, kinds
    # the occurrences kept are the latest ones (the oldest go first): the weekly raids' first weeks and the two
    # earliest one-off raids drop out
    dropped = {o for o in occs if "O:" + o not in digest}
    assert dropped == {o for o in occs[:36] if o.endswith("#0")} | set(occs[36:38]), sorted(dropped)
    # the same records give the same digest on every client
    d_lee = lee.eval_py("return ns.RaidPlan:GetDigest()")
    diff = {k: (digest.get(k), d_lee.get(k)) for k in set(digest) | set(d_lee) if digest.get(k) != d_lee.get(k)}
    assert not diff, diff
    # a member who logs in late gets every team and series (and the occurrences of the digest)
    w.tick(20)
    # (the 100 items go one per whisper behind the send throttle, teams and series first)
    uma.login()
    w.tick(240)
    got = uma.eval_py("local r = %s; local n = { T = 0, S = 0 }; "
                      "for k in pairs(n) do for _ in pairs(r[k]) do n[k] = n[k] + 1 end end; return n" % ROOT)
    assert got == {"T": 6, "S": 12}, got
    held = uma.eval_py("return ns.RaidPlan:GetDigest()")
    assert set(held) == set(digest), sorted(set(digest) ^ set(held))
    assert sorted(t["id"] for t in uma.eval_py("return ns.RaidPlan:GetTeams()")) == sorted(tids)
    assert K("Uma") in uma.eval_py("return ns.RaidPlan:GetTeam(...)", tids[0])["members"]
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
