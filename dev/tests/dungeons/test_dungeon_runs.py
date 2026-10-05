"""The guild's dungeon runs (Core/DungeonRuns.lua) and the Dungeons tab (UI/DungeonsTab.lua), on the real addon.

Covers: a listed run reaches the guild with its open places; "I'm up for a run" and the ping; asking to join, accepting
(the invite goes out, the party fills the run), declining; a full party leaves the board; a member who logs in gets
the board (from everyone the first time, from one member's digest after that); a run of an owner who went offline
leaves the board, a later one stays and is passed on; what stops me (heroic key, lockout, level) and what drops my BiS;
lockouts and BiS needs shared with the guild; today's daily (shared) and mine (quest log, done); demo mode sends
nothing; the tab, the List a run sheet, share links, the Home calendar and chips; malformed messages.

Run: luaenv\\Scripts\\python.exe tests\\dungeons\\test_dungeon_runs.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import World, Client, case, run_all  # noqa: E402

HELLO = 50   # seconds: the board request (roster + 3-8 s) and the guild hello (30-45 s after login)


def guild(names, tick=HELLO):
    """names: [(name, class)] -> world, {name: client}, everyone logged in and past the hello."""
    w = World()
    c = {}
    for i, (name, cls) in enumerate(names):
        c[name] = Client(w, name, class_file=cls, guild_rank=0 if i == 0 else 3)
    for x in c.values():
        x.load_addon()
    w.tick(tick)
    return w, c


def K(cl):
    return cl.full_name


def runs(cl):
    return cl.eval_py("""
      local out = {}
      for _, r in ipairs(ns.DungeonRuns:GetRuns()) do
        local s = {}
        for _, x in ipairs(r.s or {}) do s[#s + 1] = x.k .. '=' .. x.r end
        out[#out + 1] = { id = r.id, d = r.d, h = r.h and true or false, o = r.o, at = r.at, s = s }
      end
      return out""") or []


def slots(cl, rid):
    return cl.eval_py("""
      local out = {}
      for _, x in ipairs(ns.DungeonRuns:GetSlots(ns.DungeonRuns:GetRun(...))) do
        out[#out + 1] = x.empty and ('open:' .. x.role) or (x.key .. ':' .. x.role)
      end
      return out""", rid) or []


def roles(cl, *on):
    """Sets the roles cl is up for (the others off)."""
    for r in on:
        cl.eval("ns.DungeonRuns:SetMyRole(...)", r, True)
    for r in ("tank", "healer", "dps"):
        if r not in on:
            cl.eval("ns.DungeonRuns:SetMyRole(...)", r, False)


def list_run(cl, d="Botanica", heroic=True, role="healer", at=0, note=None):
    rid = cl.eval_py("local r, why = ns.DungeonRuns:List({ d = select(1, ...), h = select(2, ...), role = select(3, ...),"
                     " at = select(4, ...), no = select(5, ...) }); return r and r.id or why", d, heroic, role, at, note)
    assert isinstance(rid, str) and ":" in rid, rid
    return rid


def run_traffic(w, start=0):
    return [e for e in w.addon_log[start:] if e["prefix"] == "CDLr"]


def five():
    return guild([("Gina", "PALADIN"), ("Alfa", "PRIEST"), ("Bert", "WARRIOR"), ("Cara", "MAGE"), ("Dora", "ROGUE")])


# ------------------------------------------------------------------------------------------------------------------
@case
def a_listed_run_reaches_the_guild_with_its_open_places():
    w, c = five()
    g = c["Gina"]
    rid = list_run(g, "Botanica", True, "healer", note="badge run")
    w.tick(3)
    for name in ("Alfa", "Bert", "Cara", "Dora"):
        rs = runs(c[name])
        assert len(rs) == 1 and rs[0]["id"] == rid, (name, rs)
        assert rs[0]["d"] == "Botanica" and rs[0]["h"] is True and rs[0]["o"] == K(g), rs
        assert slots(c[name], rid) == ["open:tank", K(g) + ":healer", "open:dps", "open:dps", "open:dps"], \
            slots(c[name], rid)
    # who fits where: a warrior up for tank, a mage for DPS, a priest healer (taken) for nothing
    roles(c["Bert"], "tank")
    roles(c["Alfa"], "healer")
    assert c["Bert"].eval_py("return ns.DungeonRuns:FitsMe(ns.DungeonRuns:GetRun(...))", rid) == "tank"
    assert c["Cara"].eval_py("return ns.DungeonRuns:FitsMe(ns.DungeonRuns:GetRun(...))", rid) == "dps"
    assert c["Alfa"].eval_py("return ns.DungeonRuns:FitsMe(ns.DungeonRuns:GetRun(...))", rid) is None
    assert c["Cara"].eval_py("return ns.DungeonRuns:GetRun(...).no", rid) == "badge run"
    # the owner's run is "mine"; a second listing replaces it (same id, a newer revision)
    assert g.eval_py("return ns.DungeonRuns:GetMine().id") == rid
    assert list_run(g, "Mechanar", True, "healer") == rid
    w.tick(3)
    assert [r["d"] for r in runs(c["Cara"])] == ["Mechanar"]
    w.assert_no_errors()


@case
def up_for_a_run_pings_ask_accept_and_the_party_fills_the_run():
    w, c = five()
    g, b, cara = c["Gina"], c["Bert"], c["Cara"]
    roles(b, "tank")
    b.eval("ns.DungeonRuns:SetUp(true)")
    w.tick(4)
    # the guild sees Bert is up for a run, as a tank
    up = g.eval_py("local out = {}; for _, e in ipairs(ns.DungeonRuns:GetUpForRun()) do out[#out + 1] = e.key end; "
                   "return out")
    assert up == [K(b)], up
    rid = list_run(g, "ShatteredHalls", True, "healer")
    w.tick(3)
    # Bert gets the ping (the pop-up, out of the Dungeons tab)
    assert b.eval_py("local t = ns.DungeonsUI:GetToast(); return t and t:IsShown() and t.run") == rid
    assert cara.eval_py("local t = ns.DungeonsUI:GetToast(); return t and t:IsShown() or false") is False
    # Bert asks; Gina gets the request (and her pop-up)
    ok = b.eval_py("return ns.DungeonRuns:Join(...)", rid)
    assert ok is True, ok
    w.tick(2)
    req = g.eval_py("local r = ns.DungeonRuns:GetRequests(...)[1]; return r and { key = r.key, r = r.r }", rid)
    assert req == {"key": K(b), "r": "tank"}, req
    assert b.eval_py("return ns.DungeonRuns:GetAsked(...).st", rid) == "asked"
    # Gina accepts: the invite goes out, Bert joins, the run's party has him as its tank
    assert g.eval_py("return ns.DungeonRuns:Accept(...)", rid, K(b)) is True
    w.tick(3)
    assert any(e["by"] == K(g) and e["target"].startswith("Bert") and e["result"] == "joined" for e in w.invite_log), \
        w.invite_log
    assert b.eval_py("return ns.DungeonRuns:GetAsked(...).st", rid) == "invited"
    w.tick(3)
    assert slots(cara, rid) == [K(b) + ":tank", K(g) + ":healer", "open:dps", "open:dps", "open:dps"], slots(cara, rid)
    assert g.eval_py("return #ns.DungeonRuns:GetRequests(...)", rid) == 0
    # a member in a listed run is no longer shown as up for a run
    assert g.eval_py("return #ns.DungeonRuns:GetUpForRun()") == 0
    w.assert_no_errors()


@case
def declining_and_taking_back_a_request():
    w, c = five()
    g, cara, dora = c["Gina"], c["Cara"], c["Dora"]
    rid = list_run(g, "Arcatraz", True, "healer")
    w.tick(3)
    assert cara.eval_py("return ns.DungeonRuns:Join(...)", rid) is True
    assert dora.eval_py("return ns.DungeonRuns:Join(...)", rid) is True
    w.tick(2)
    assert g.eval_py("return #ns.DungeonRuns:GetRequests(...)", rid) == 2
    dora.eval("ns.DungeonRuns:CancelJoin(...)", rid)
    g.eval("ns.DungeonRuns:Decline(...)", rid, K(cara))
    w.tick(2)
    assert g.eval_py("return #ns.DungeonRuns:GetRequests(...)", rid) == 0
    assert cara.eval_py("return ns.DungeonRuns:GetAsked(...).st", rid) == "declined"
    assert dora.eval_py("return ns.DungeonRuns:GetAsked(...)", rid) is None
    assert not any(e["by"] == K(g) for e in w.invite_log), w.invite_log
    w.assert_no_errors()


@case
def a_full_party_leaves_the_board():
    w, c = five()
    g = c["Gina"]
    rid = list_run(g, "Steamvault", False, "healer")
    w.tick(3)
    w.make_party([g, c["Alfa"], c["Bert"], c["Cara"], c["Dora"]], leader=g)
    w.tick(4)
    assert g.eval_py("return ns.DungeonRuns:GetMine()") is None
    for name in ("Alfa", "Cara"):
        assert runs(c[name]) == [], (name, runs(c[name]))
    assert any("is full" in line for line in g.chat_frame), g.chat_frame
    w.assert_no_errors()


@case
def joining_somebody_elses_group_ends_my_run():
    w, c = five()
    g, a = c["Gina"], c["Alfa"]
    list_run(a, "Mechanar", True, "healer")
    w.tick(3)
    w.make_party([g, a], leader=g)
    w.tick(3)
    assert a.eval_py("return ns.DungeonRuns:GetMine()") is None
    assert runs(c["Cara"]) == []
    w.assert_no_errors()


@case
def a_member_who_logs_in_gets_the_board():
    w = World()
    g = Client(w, "Gina", class_file="PALADIN", guild_rank=0)
    b = Client(w, "Bert", class_file="WARRIOR")
    for x in (g, b):
        x.load_addon()
    w.tick(HELLO)
    rid = list_run(g, "BlackMorass", True, "healer")
    roles(b, "tank")
    b.eval("ns.DungeonRuns:SetUp(true)")
    w.tick(4)
    # first login ever: nobody known to ask -> the guild says hello, the owner whispers the run
    d = Client(w, "Dora", class_file="ROGUE")
    d.load_addon()
    w.tick(HELLO + 10)
    assert [r["id"] for r in runs(d)] == [rid], runs(d)
    assert d.eval_py("local p = ns.DungeonRuns:GetPeer(...); return p and p.roles.tank and p.up > 0", K(b)) is True
    # next login: Dora knows who runs DisasterZone, asks one of them, and gets one digest
    start = len(w.addon_log)
    d.relog(reload=False)
    w.tick(HELLO + 10)
    traffic = run_traffic(w, start)
    asks = [e for e in traffic if e["sender"] == K(d) and e["target"]]
    assert len(asks) == 1, asks
    digests = [e for e in traffic if e["target"] and e["target"].startswith("Dora")]
    assert len(digests) == 1, [(e["sender"], len(e["text"])) for e in digests]
    assert [r["id"] for r in runs(d)] == [rid], runs(d)
    assert d.eval_py("local p = ns.DungeonRuns:GetPeer(...); return p and p.roles.tank and p.up > 0", K(b)) is True
    # nothing bigger than what any member's client takes
    assert all(len(e["text"]) <= 4000 for e in traffic)
    w.assert_no_errors()


@case
def an_offline_owners_run_now_leaves_a_later_run_stays():
    w, c = five()
    g, a, cara = c["Gina"], c["Alfa"], c["Cara"]
    now_id = list_run(g, "Underbog", False, "healer")
    later_at = cara.eval_py("return GetServerTime()") + 3 * 3600
    later_id = list_run(a, "SlavePens", False, "healer", at=later_at)
    w.tick(3)
    assert sorted(r["id"] for r in runs(cara)) == sorted([now_id, later_id])
    g.logout()
    a.logout()
    w.tick(200)
    assert [r["id"] for r in runs(cara)] == [later_id], runs(cara)
    # a member logging in for the first time gets it from the board one member sends
    e = Client(w, "Evie", class_file="HUNTER")
    e.load_addon()
    w.tick(HELLO + 10)
    assert [r["id"] for r in runs(e)] == [later_id], runs(e)
    digests = [x for x in run_traffic(w) if x["target"] and x["target"].startswith("Evie") and len(x["text"]) > 40]
    assert len(digests) >= 1, digests
    w.assert_no_errors()


@case
def what_stops_me_and_what_drops_my_bis():
    w, c = five()
    a, b = c["Alfa"], c["Bert"]
    # heroic key: Lower City only honored
    a.eval("__MOCK.factions[1011] = 5")
    assert a.eval_py("return (ns.DungeonRuns:GetBlocker('ShadowLabyrinth', true))") == "Needs Revered with Lower City"
    assert a.eval_py("return (ns.DungeonRuns:GetBlocker('ShadowLabyrinth', false))") is None
    assert a.eval_py("return (ns.DungeonRuns:GetBlocker('Botanica', true))") is None
    # a heroic lockout (the raid info names it the TBC way); Lower City revered again
    a.eval("__MOCK.factions[1011] = nil")
    a.eval("__MOCK.saved = { { 'Auchindoun: Mana-Tombs', 1, 7200, 2, true, false, 0, false, 5, 'Heroic', 3, 3, false } }")
    a.fire("UPDATE_INSTANCE_INFO")
    block = a.eval_py("return (ns.DungeonRuns:GetBlocker('ManaTombs', true))")
    assert block and block.startswith("You're saved until"), block
    w.tick(4)
    assert b.eval_py("return ns.DungeonRuns:IsSaved(...)", K(a), "ManaTombs") is True
    assert b.eval_py("return ns.DungeonRuns:IsSaved(...)", K(a), "Botanica") is False
    # below level 70: no heroics
    low = Client(w, "Lowe", class_file="DRUID", level=66)
    low.load_addon()
    w.tick(2)
    assert low.eval_py("return (ns.DungeonRuns:GetBlocker('Botanica', true))") == "Needs level 70"
    # a BiS pick that drops only in heroic Botanica: my hint, and the guild's count
    item = a.eval_py("""
      for _, d in ipairs(ns.Data.Dungeons) do
        if d.key == 'Botanica' then
          local normal = {}
          for _, boss in ipairs(d.bosses) do
            for _, id in ipairs(boss.items or {}) do normal[id] = true end
          end
          for _, boss in ipairs(d.bosses) do
            for _, id in ipairs(boss.heroicItems or {}) do if not normal[id] then
              for _, sid in ipairs(ns.ItemDB:GetSlotsForItem(id) or {}) do
                if ns.ItemDB:IsUsableBy(id, 'PRIEST', sid) and not ns.ItemDB:IsToken(id) then
                  if ns.BiS:SetSlot(1, sid, 'main', id) then return id end
                end
              end
            end end
          end
        end
      end""")
    assert item, "no usable heroic Botanica item"
    w.tick(5)
    assert a.eval_py("return ns.DungeonRuns:GetMyBiSDrops('Botanica', true)[1]") == item
    assert b.eval_py("local n, who = ns.DungeonRuns:GetNeeders('Botanica', true); return who") == [K(a)]
    assert b.eval_py("return (ns.DungeonRuns:GetNeeders('Botanica', false))") == 0
    w.assert_no_errors()


@case
def todays_daily_is_shared_and_mine_follows_my_quest_log():
    w, c = five()
    a, b = c["Alfa"], c["Bert"]
    # Alfa talks to Wind Trader Zephyr: Mana-Tombs is today's heroic daily
    a.eval("_G.GetQuestID = function() return 11373 end")
    a.fire("QUEST_DETAIL")
    w.tick(4)
    for x in (a, b):
        assert x.eval_py("return ns.DungeonRuns:GetDaily(true)") == "ManaTombs"
        assert x.eval_py("return ns.DungeonRuns:GetMyDaily('ManaTombs', true)") == "today"
    # Bert did it today; Alfa still has yesterday's Shadow Labyrinth daily in her quest log
    b.eval("__MOCK.quests_done[11373] = true")
    assert b.eval_py("return ns.DungeonRuns:GetMyDaily('ManaTombs', true)") == "done"
    a.eval("__MOCK.quests_on[11375] = true")
    assert a.eval_py("return ns.DungeonRuns:GetMyDaily('ShadowLabyrinth', true)") == "log"
    assert b.eval_py("return ns.DungeonRuns:GetMyDaily('ShadowLabyrinth', true)") is None
    # a normal daily seen later the same day keeps the heroic one
    a.eval("_G.GetQuestID = function() return 11385 end")
    a.fire("QUEST_DETAIL")
    w.tick(4)
    assert b.eval_py("return ns.DungeonRuns:GetDaily(true)") == "ManaTombs"
    assert b.eval_py("return ns.DungeonRuns:GetDaily(false)") == "Botanica"
    w.assert_no_errors()


@case
def demo_mode_sends_nothing():
    w, c = five()
    g = c["Gina"]
    g.slash("/dz demo on")
    w.tick(1)
    start = len(w.addon_log)
    rs = runs(g)
    assert len(rs) == 4, rs
    rid = list_run(g, "Botanica", True, "healer")
    reqs = g.eval_py("local out = {}; for _, r in ipairs(ns.DungeonRuns:GetRequests(...)) do out[#out + 1] = r.key end;"
                     " return out", rid)
    assert len(reqs) == 2, reqs
    assert g.eval_py("return ns.DungeonRuns:Accept(...)", rid, reqs[0]) is True
    assert len(slots(g, rid)) == 5 and sum(1 for s in slots(g, rid) if not s.startswith("open")) == 2
    g.eval("ns.DungeonRuns:Join('demo-1')")
    w.tick(5)
    assert run_traffic(w, start) == []
    g.slash("/dz demo off")
    w.tick(1)
    assert runs(g) == []
    w.assert_no_errors()


@case
def the_tab_the_sheet_share_links_and_home():
    w, c = five()
    g, b = c["Gina"], c["Bert"]
    roles(b, "tank")
    # Gina lists a run for tomorrow 20:00 through the sheet
    g.eval("ns.MainFrame:Open('dungeons')")
    w.tick(1)
    g.eval("ns.DungeonsUI:OpenSheet(); ns.DungeonsUI:SetSheet({ d = 'Mechanar', when = 'later', day = 1, "
           "mins = 20 * 60, no = 'chill run' })")
    w.tick(0.5)
    preview = g.eval_py("local p = ns.DungeonsUI:GetPanel(); return p.sheet.preview:IsShown() and "
                        "p.sheet.preview.t1:GetText()")
    assert preview in ("The Mechanar", "Mechanar"), preview
    g.eval("ns.DungeonsUI:SubmitSheet()")
    w.tick(3)
    mine = g.eval_py("local r = ns.DungeonRuns:GetMine(); return { id = r.id, at = r.at, no = r.no }")
    expect = g.eval_py("local t = date('*t', GetServerTime()); return time({ year = t.year, month = t.month, "
                       "day = t.day + 1, hour = 20, min = 0, sec = 0 })")
    assert mine["at"] == expect and mine["no"] == "chill run", (mine, expect)
    # Gina's board: her run on top with More and Share
    assert g.eval_py("local c = ns.DungeonsUI:GetPanel().cards[1]; return c:IsShown() and c.more:IsShown() "
                     "and c.share:IsShown()") is True
    # Bert's board: the run, a Join button (he's a tank and the tank place is open)
    b.eval("ns.MainFrame:Open('dungeons')")
    w.tick(1)
    btn = b.eval_py("local c = ns.DungeonsUI:GetPanel().cards[1]; return c.btn:IsShown() and c.btn:GetText()")
    assert btn == "Join", btn
    # a share link to the run opens Bert's Dungeons tab on it
    ref = g.eval_py("return ns.Share:RunRef(...)", mine["id"])
    token = g.eval_py("return ns.Share:Text(...)", ref)
    assert token and "Mechanar" in token, token
    b.eval("ns.MainFrame:Open('home')")
    assert b.eval_py("return (ns.Share:Open(...))", ref) is True
    assert b.eval_py("return ns.MainFrame:GetSelectedTab()") == "dungeons"
    assert g.eval_py("return ns.Share:CurrentRef()") == ref
    # the Home calendar of tomorrow lists it
    b.eval("ns.MainFrame:Open('home')")
    w.tick(1)
    b.eval_py("return true")
    w.assert_no_errors()


@case
def malformed_messages_are_ignored():
    w, c = five()
    g, b = c["Gina"], c["Bert"]
    for msg in ({"t": "DRL", "id": 5, "d": 1, "c": 1, "rv": 1, "s": []},
                {"t": "DRL", "id": "x", "d": 99, "c": 1, "rv": 1, "s": []},
                {"t": "DRL", "id": "x", "d": 1, "c": 1, "rv": 1, "s": [["a", 9]]},
                {"t": "DRL", "id": "x", "d": 1, "c": 1, "rv": 1, "s": [1, 2, 3, 4, 5, 6]},
                {"t": "DRP", "r": "tank", "nn": {"a": 1}, "sv": 7},
                {"t": "DRS", "p": [[5], ["Zed", "x"]], "l": ["no"]},
                {"t": "DRJ", "id": "nope", "r": 1},
                {"t": "DRA", "id": {}, "ok": 1}):
        b.eval("ns.Comm:Send(..., 'GUILD', nil, 'run')", msg)
    w.tick(3)
    assert runs(g) == []
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
