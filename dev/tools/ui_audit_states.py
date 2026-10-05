"""The views tools/ui_audit.py opens, and the guild it opens them in (realistic data, long names on purpose).

build_world(preload) -> world, clients. STATES: a list of (name, fn(world, clients) -> the client whose screen is
audited). Every fn starts from a clean screen (close_all) and opens one view.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
for sub in ("raidplan", "boot-ui", "loot-roll", "strategy", "members"):
    sys.path.insert(0, os.path.join(DEV, "tests", sub))

from rp_common import World, Client, gm_pick, set_raid_leaders, K, DAY, now, create, signup, team  # noqa: E402
from st_common import COUNCIL  # noqa: E402
from mb_common import set_skills, teach_names  # noqa: E402

# Gina = GM (the screen we look at), Grumpykat = officer + guild council + raid leader; long names on purpose.
MEMBERS = (("Gina", 0, "PALADIN"), ("Grumpykat", 1, "WARLOCK"), ("Victhar", 2, "WARRIOR"),
           ("Shadowmelder", 3, "ROGUE"), ("Vaenyria", 3, "HUNTER"), ("Thunderhoofx", 3, "SHAMAN"),
           ("Moonwhisper", 3, "DRUID"), ("Lightbringer", 3, "PRIEST"), ("Frostweaver", 3, "MAGE"))
PUGS = (("Pugsyhealer", "PRIEST", None), ("Darkstalkerr", "HUNTER", "Pyrewood Village"))

IDS = {}


def build_world(preload):
    w = World()
    w.auto_session = False
    c = {}
    for name, rank, cls in MEMBERS:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls, preload_lua=preload)
    for name, cls, realm in PUGS:
        kw = {"realm": realm} if realm else {}
        c[name] = Client(w, name, guild=None, class_file=cls, preload_lua=preload, **kw)
    for x in c.values():
        x.load_addon()
        teach_names(x)
        set_skills(x, [])
    w.tick(3)
    gina = c["Gina"]
    gm_pick(w, gina, ["Grumpykat"])
    set_raid_leaders(w, gina, ("Grumpykat",))
    w.tick(2)
    seed(w, c)
    return w, c


def save_strategy(cl, boss, name, collaborators=()):
    res = cl.eval_py("local d = (loadstring(...))(); d.b = select(2, ...); d.n = select(3, ...); "
                     "local ok, r = ns.Strategy:SaveStrategy(d); return { ok = ok, r = r }", COUNCIL, boss, name)
    assert res["ok"] is True, res
    if collaborators:
        cl.eval("ns.Strategy:SetCollaborators(...)", res["r"], [K(n) for n in collaborators])
    return res["r"]


def seed(w, c):
    gina, grumpy = c["Gina"], c["Grumpykat"]
    # strategies: shared ones (the "shared with you" tag), long names
    save_strategy(c["Victhar"], "Karazhan:Attumen", "Solo tanking")
    # a second one for Attumen (the raid's Assignments row: a pick, "not picked yet"), the longest name allowed
    save_strategy(grumpy, "Karazhan:Attumen", "Attumen and Midnight split pulls")
    IDS["strat"] = save_strategy(grumpy, "SerpentshrineCavern:Lurker", "The Lurker Below raiding tactics",
                                 ("Gina", "Victhar", "Shadowmelder"))
    save_strategy(grumpy, "SerpentshrineCavern:Leotheras", "Tactics and positioning", ("Gina", "Victhar", "Vaenyria"))
    save_strategy(gina, "TempestKeep:VoidReaver", "Positioning & Tactics")
    w.tick(3)
    # raids: a planned raid now with sign-ups, a long title and note, guests, a blacklist entry
    occ = create(grumpy, i="kara", t=now(grumpy) + 900, ti="Kara full clear + Gruul if time",
                 no="Bring flasks, food and pots. Pull at 20:00 sharp, invites from 19:45. Tanks: Victhar, Moonwhisper.")
    IDS["occ"] = occ
    IDS["ssc"] = create(grumpy, i="ssc", t=now(grumpy) + 3 * DAY, ti="SSC progression night")
    IDS["team"] = team(grumpy, "Main team (Thu + Sun nights)",
                       ["Victhar", "Shadowmelder", "Vaenyria", "Thunderhoofx", "Moonwhisper", "Lightbringer",
                        "Frostweaver", "Grumpykat", "Gina"])
    w.tick(2)
    for n in ("Victhar", "Shadowmelder", "Vaenyria", "Thunderhoofx", "Moonwhisper", "Lightbringer"):
        signup(c[n], occ, "A", None, "might be 10 min late" if n == "Vaenyria" else None)
    signup(c["Frostweaver"], occ, "T")
    w.tick(2)
    # the raid's own leader ("led by" in the header), named by the GM
    res = gina.eval_py("local o, k = ...; local ok, e = ns.RaidPlan:EditRaid(o, { rl = k }); return { ok = ok, e = e }",
                       occ, K("Shadowmelder"))
    assert res["ok"] is True, res
    w.tick(2)
    grumpy.eval("ns.RaidPlan:SetBlacklisted('Badlooterxx', 'ninja looted Gruul twice and left mid raid without a word')")
    grumpy.eval("ns.GuestBook:SetNote('Pugsyhealer', 'great resto priest, wants to join after Gruul', true)")
    w.tick(2)
    # a logged raid with pugs (the Players list, the guest book)
    w.enter_instance("Karazhan", 532)
    members = [grumpy, c["Victhar"], c["Shadowmelder"], c["Vaenyria"], c["Moonwhisper"], c["Lightbringer"],
               c["Pugsyhealer"], c["Darkstalkerr"], gina]
    w.make_raid(members, leader=grumpy)
    w.tick(6)
    grumpy.eval("ns.GroupRules:SetSession(true, nil, { loot = false, rolls = true, lock = false })")
    w.tick(3)
    w.encounter(652, "Attumen the Huntsman", clients=members)
    w.tick(3)
    grumpy.eval("ns.RaidLog:End()")
    w.tick(3)
    w.disband()
    w.leave_instance()
    w.tick(3)
    # professions: Enchanting 324/375 without recipes shared yet
    set_skills(c["Vaenyria"], [("Enchanting", 324, 375), ("Tailoring", 375, 375)])
    # stress: Gina's Phase 1 list with the longest item name of every slot (main) and alt picks
    gina.eval("""
      for sid = 1, 19 do
        local best, bestLen, second
        for _, cand in ipairs(ns.ItemDB:GetCandidates(sid, { maxPhase = 1 }) or {}) do
          local n = ns.ItemDB:GetName(cand.itemID) or ""
          if not bestLen or #n > bestLen then second, best, bestLen = best, cand.itemID, #n end
        end
        if best then ns.BiS:SetSlot(1, sid, "main", best) end
        if second then ns.BiS:SetSlot(1, sid, "alt", second) end
      end
      ns.BiS:Commit()""")
    # stress: loot log awards with long item names, a note and reasons, to members and a pug
    gina.eval("""
      local long = {}
      for sid = 1, 19 do
        for _, cand in ipairs(ns.ItemDB:GetCandidates(sid, { maxPhase = 1 }) or {}) do long[#long + 1] = cand.itemID end
      end
      table.sort(long, function(a, b) return #(ns.ItemDB:GetName(a) or "") > #(ns.ItemDB:GetName(b) or "") end)
      local who = { 'Shadowmelder-Thunderstrike', 'Thunderhoofx-Thunderstrike', 'Pugsyhealer-Thunderstrike',
                    'Darkstalkerr-PyrewoodVillage', 'Lightbringer-Thunderstrike' }
      local why = { 'bis', 'alt', 'up', 'os', 'de' }
      for i = 1, 5 do
        if long[i] then ns.Ledger:Award(long[i], who[i], 'Karazhan:Prince', i == 1 and 'won the roll after a tie, 2nd BiS piece' or nil, nil, why[i]) end
      end""")
    w.tick(65)


def close_all(cl):
    cl.eval("""
      for _, name in ipairs({ 'DisasterZoneGuests', 'DisasterZoneRaidInvites', 'DisasterZoneRaidStart',
                              'DisasterZoneRaidLeaders', 'DisasterZoneRaidEditor', 'DisasterZoneAwardDialog',
                              'DisasterZoneRaidLeader', 'DisasterZoneShareWindow', 'DisasterZoneImportExport' }) do
        local f = _G[name]; if f and f.Hide then f:Hide() end
      end
      if ns.StrategyBoard and ns.StrategyBoard.Close then pcall(ns.StrategyBoard.Close, ns.StrategyBoard) end
      if ns.Picker and ns.Picker.Close then pcall(ns.Picker.Close, ns.Picker) end
      if ns.MainFrame and ns.MainFrame.Close then ns.MainFrame:Close() end
      if ns.DropPanel and ns.DropPanel.Hide then ns.DropPanel:Hide() end
      if ns.RollFrame and ns.RollFrame.frame then ns.RollFrame.frame:Hide() end
      local rf = _G.DisasterZoneRollFrame; if rf and rf.Hide then rf:Hide() end
      if GameTooltip then GameTooltip:Hide() end""")


def tab(cl, key):
    cl.eval("ns.MainFrame:Open(...)", key)


def demo_off(w, c):
    g = c["Gina"]
    if g.eval("return ns.Demo:IsEnabled()"):
        g.slash("/dz demo off")
        w.tick(1)


def opened(key, lua=None):
    """A state: Gina's main window on tab `key`, then optional Lua (... = occ, strategy id, team id, ssc occ)."""
    def fn(w, c):
        g = c["Gina"]
        demo_off(w, c)
        close_all(g)
        tab(g, key)
        if lua:
            w.tick(0.3)
            g.eval(lua, *[IDS.get(k) for k in ("occ", "strat", "team", "ssc")])
        return g
    return fn


def demo(fn_lua, key=None):
    """A state in demo mode (the fake guild: lists, council data, loot log), on Gina's screen."""
    def fn(w, c):
        g = c["Gina"]
        close_all(g)
        if not g.eval("return ns.Demo:IsEnabled()"):
            g.slash("/dz demo on")
            w.tick(1)
        if key:
            tab(g, key)
            w.tick(0.3)
        if fn_lua:
            g.eval(fn_lua)
        return g
    return fn


def st_window(lua):
    def fn(w, c):
        g = c["Gina"]
        demo_off(w, c)
        close_all(g)
        tab(g, "raids")
        w.tick(0.3)
        g.eval(lua, *[IDS.get(k) for k in ("occ", "strat", "team", "ssc")])
        return g
    return fn


def raid_with_session(w, c, features):
    g = c["Gina"]
    demo_off(w, c)
    close_all(g)
    members = [g] + [c[n] for n in ("Victhar", "Shadowmelder", "Vaenyria", "Moonwhisper", "Lightbringer",
                                     "Pugsyhealer", "Darkstalkerr")]
    w.enter_instance("Karazhan", 532)
    w.make_raid(members, leader=g)
    w.tick(4)
    if g.eval("return ns.GroupRules:GetSession() ~= nil"):
        g.eval("ns.RaidLog:End()")
        w.tick(2)
    if features:
        g.eval("ns.GroupRules:SetSession(true, nil, ...)", features)
        w.tick(3)
    return g


DROPS = []


def st_drop(features, roll=False, viewer="Gina"):
    def fn(w, c):
        g = raid_with_session(w, c, features)
        item = g.eval("return ns.ItemDB:GetCandidates(1, { maxPhase = 1 })[1].itemID")
        DROPS.append(1)
        g.open_loot([(item, 4)], source_guid="Creature-0-1-2-3-15690-%06X" % len(DROPS))
        w.tick(2)
        if roll:
            g.eval("ns.DropPanel:StartRoll(...)", item)
            w.tick(1)
            for n, v in (("Victhar", 87), ("Shadowmelder", 42), ("Pugsyhealer", 99), ("Darkstalkerr", 15)):
                w.player_roll(c[n], v)
            w.tick(1)
            g.eval("ns.DropPanel:Render()")
        return c[viewer]
    return fn


def st_session_bar(w, c):
    return raid_with_session(w, c, {"loot": False, "rolls": True, "lock": False})


def st_raids_in_raid(lua):
    """The Raids tab while Gina leads a raid with a running session (Start raid / End raid at the top right)."""
    def fn(w, c):
        g = raid_with_session(w, c, {"loot": True, "rolls": True, "lock": False})
        tab(g, "raids")
        w.tick(0.3)
        g.eval(lua)
        w.tick(0.5)
        return g
    return fn


TMB_SAMPLE = "\n".join([
    "type,raid_group_name,member_name,character_name,character_class,character_is_alt,character_inactive_at,"
    "character_note,sort_order,item_name,item_id,is_offspec,note,received_at,import_id,item_note,item_prio_note,"
    "item_tier,item_tier_label,created_at,updated_at",
] + ["wishlist,Main,m,%s,Paladin,0,,,%d,\"x\",%d,%d,,,,,,,,," % (who, n, item, os_) for who, n, item, os_ in (
    ("Gina", 1, 28593, 0), ("Gina", 2, 28586, 0), ("Gina", 3, 28510, 0), ("Gina", 4, 28649, 0), ("Gina", 5, 28661, 0),
    ("Gina", 6, 28528, 0), ("Gina", 7, 28573, 0), ("Gina", 8, 28754, 0), ("Gina", 9, 28507, 1), ("Gina", 10, 28568, 0),
    ("Grumpykat", 1, 28510, 0))] + ["received,Main,m,Gina,Paladin,0,,,0,\"x\",28510,0,,,,,,,,,"])


def st_start_window(w, c):
    g = raid_with_session(w, c, None)
    g.eval("ns.SessionBar:OpenStart()")
    return g


STATES = [
    ("Home", opened("home")),
    ("Home - calendar day", opened("home", "local v = ns.RaidPlan:GetRaid(select(4, ...)); "
                                           "local key = tonumber(date('%Y%m%d', v.t)); "
                                           "for _, c in ipairs(ns.Dashboard:GetPanel().calCard.cells) do "
                                           "if c.key == key then c:GetScript('OnClick')(c) end end")),
    ("My BiS", opened("mybis")),
    ("My BiS - item picker", opened("mybis", "ns.Picker:Open(1, 1, 'main')")),
    # the Import / Export window (UI/ImportExport.lua): a That's My BiS paste over Gina's seeded P1 list, an error,
    # and the export tab
    ("My BiS - Import", opened("mybis", "ns.ImportExport:Open('import'); ns.ImportExport:SetSource([==[" + TMB_SAMPLE
                                         + "]==])")),
    ("My BiS - Import error", opened("mybis", "ns.ImportExport:Open('import'); "
                                               "ns.ImportExport:SetSource('{\"items\": [1, 2')")),
    ("My BiS - Export", opened("mybis", "ns.ImportExport:Open('export')")),
    ("Atlas - raid boss", opened("atlas", "ns.AtlasUI:Select('raids', 'Karazhan', 'Prince')")),
    ("Atlas - dungeon heroic", opened("atlas", "ns.AtlasUI:Select('dungeons', 'BlackMorass', nil, true)")),
    ("Atlas - reputation", opened("atlas", "ns.AtlasUI:Select('reputation', 'Shatar')")),
    ("Atlas - crafting", opened("atlas", "ns.AtlasUI:Select('crafting', 'Enchanting')")),
    ("Atlas - sets", opened("atlas", "ns.AtlasUI:Select('sets', 'Tier6')")),
    ("Atlas - arena sets", opened("atlas", "ns.AtlasUI:Select('sets', 'ArenaS4', 'Priest')")),
    ("Atlas - search", opened("atlas", "ns.AtlasUI:SetSearch('gladiator')")),
    ("Atlas - item menu", opened("atlas", "ns.AtlasUI:Select('raids', 'Karazhan', 'Attumen'); "
                                          "ns.AtlasUI:OpenMenu({ type = 'item', id = 28505 })")),
    ("Council - Loot Log", opened("council", "ns.CouncilUI:ShowLog()")),
    ("Raids - Upcoming", opened("raids", "ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:SelectRaid(...); "
                                          "ns.RaidPlanUI:SetDetailTab('signups')")),
    ("Raids - Upcoming - Groups", opened("raids", "ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:SelectRaid(...); "
                                                  "ns.RaidPlanUI:SetDetailTab('groups')")),
    ("Raids - Upcoming - Assignments", opened("raids", "ns.RaidsUI:SetView('upcoming'); "
                                                       "ns.RaidPlanUI:SelectRaid(...); "
                                                       "ns.RaidPlanUI:SetDetailTab('assign')")),
    ("Raids - Upcoming - Raid leader", opened("raids", "ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:SelectRaid(...); "
                                                       "ns.RaidPlanUI:OpenLeader(...)")),
    ("Raids - Teams", opened("raids", "ns.RaidsUI:SetView('teams'); ns.RaidPlanUI:SelectTeam(select(3, ...))")),
    ("Raids - Strategies", opened("raids", "ns.RaidsUI:SetView('strategies')")),
    ("Raids - Strategies - share", opened("raids", "ns.RaidsUI:SetView('strategies'); "
                                                   "ns.StrategiesUI:OpenShare(select(2, ...))")),
    ("Raids - Raid log - Raids", opened("raids", "ns.RaidsUI:SetMode('raids')")),
    ("Raids - Raid log - Players", opened("raids", "ns.RaidsUI:SetMode('players')")),
    ("Raids - New raid", st_window("ns.RaidPlanUI:OpenEditor()")),
    ("Raids - Edit raid", st_window("ns.RaidPlanUI:OpenEditor(...)")),
    ("Raids - Add players - members", st_window("ns.RaidPlanUI:OpenInvites(...)")),
    ("Raids - Add players - guest", st_window("ns.RaidPlanUI:OpenInvites(...); "
                                              "ns.RaidPlanUI:GetInviteWindow().mode = 'guest'; "
                                              "ns.RaidPlanUI:RefreshInvites()")),
    ("Raids - Guests - guest book", st_window("ns.GuestBookUI:Open('book')")),
    ("Raids - Guests - blacklist", st_window("ns.GuestBookUI:Open('black')")),
    ("Raids - Raid leaders", st_window("ns.RaidLeadersUI:Open()")),
    ("Raids - Strategy board", st_window("ns.StrategyBoard:OpenStrategy(select(2, ...))")),
    ("Raids - Strategy board - edit", st_window("ns.StrategyBoard:OpenStrategy(select(2, ...), 'edit')")),
    # a boss with a room: the 2D / 3D switch on the map, and the page in 3D (UI/StrategyMap3D.lua)
    ("Raids - Strategy board - Teron 2D", st_window("ns.StrategyBoard:NewStrategy('BlackTemple:Teron')")),
    ("Raids - Strategy board - Teron 3D", st_window("ns.StrategyBoard:NewStrategy('BlackTemple:Teron'); "
                                                    "_G.DisasterZoneStrategyBoard.canvas:Set3D(true, false)")),
    # Lady Vashj's Shield Generators (Data/EncounterObjects.lua): their models, beams and her barrier; then the walk
    # button held over the floor beside her (the landing ring and you see-through in it)
    ("Raids - Strategy board - Vashj 3D", st_window("ns.StrategyBoard:NewStrategy('SerpentshrineCavern:Vashj'); "
                                                    "_G.DisasterZoneStrategyBoard.canvas:Set3D(true, false)")),
    ("Raids - Strategy board - Vashj 3D walk drop", st_window(
        "ns.StrategyBoard:NewStrategy('SerpentshrineCavern:Vashj'); local cv = _G.DisasterZoneStrategyBoard.canvas; "
        "cv:Set3D(true, false); local v = cv.v3; v:Draw(); local s = ns.Render3D.RoomForBoss('SerpentshrineCavern:Vashj')"
        ".spot; local sx, sy = v.R.Project(s.x + 10, s.y - 6, v:Ground(s.x + 10, s.y - 6)); "
        "local es = v.view.scene:GetEffectiveScale() or 1; _G.GetCursorPosition = function() return sx * es, sy * es end; "
        "_G.IsMouseButtonDown = function() return true end; v.frame.IsMouseOver = function() return true end; "
        "v:BeginPeg(); v:Draw()")),
    ("Council - Loot Log - award dialog", opened("council", "ns.CouncilUI:ShowLog(); ns.LootLogUI:OpenAwardDialog("
                                               "ns.ItemDB:GetCandidates(1, { maxPhase = 1 })[1].itemID, "
                                               "'Shadowmelder-Thunderstrike', 'Karazhan:Prince')")),
    ("Members - roster", opened("members")),
    ("Members - member card", opened("members", "ns.MembersUI:ShowMember('Vaenyria-Thunderstrike')")),
    ("Members - recipes", opened("members", "ns.MembersUI:SetMode('recipes')")),
    ("Games", opened("games")),
    # the Share window (UI/ShareWindow.lua), dropped from the icon that opened it
    ("Share - raid", opened("raids", "ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:SelectRaid(...); "
                                     "ns.ShareWindow:Open('raid:' .. (...), "
                                     "ns.RaidsUI:GetPanel().upcoming.detail.shareBtn)")),
    ("Share - member", opened("members", "ns.MembersUI:ShowMember('Vaenyria-Thunderstrike'); "
                                         "ns.ShareWindow:Open('member:Vaenyria', ns.MembersUI:GetPanel().right.share)")),
    ("Share - window alone", opened("raids", "ns.MainFrame:Close(); ns.ShareWindow:Open('raid:' .. (...)); "
                                             "ns.ShareWindow:GetWindow().msg:SetText('Sign-ups close Wednesday!')")),
    ("Settings", opened("settings")),
    ("Changelog", opened("changelog")),
    ("Demo - Council - roster", demo("ns.CouncilUI:SetView('roster')", "council")),
    ("Demo - Council - items", demo("ns.CouncilUI:ShowBoss('Karazhan:Prince')", "council")),
    ("Demo - Council - member", demo("ns.CouncilUI:ShowMember('Aldrin-Thunderstrike')", "council")),
    ("Demo - Council - loot council", demo("ns.CouncilUI:ShowCouncil()", "council")),
    ("Demo - Council - loot log", demo("ns.CouncilUI:ShowLog()", "council")),
    ("Demo - Raid log - Players", demo("ns.RaidsUI:SetMode('players')", "raids")),
    ("Demo - Start raid window", demo("ns.SessionBar:OpenStart()")),
    ("Demo - test drop panel", demo("ns.Loot:SimulateDrop()")),
    ("Raid - session bar", st_session_bar),
    ("Raid - drop panel (council)", st_drop({"loot": True, "rolls": True, "lock": False})),
    ("Raid - drop panel (council, rolling)", st_drop({"loot": True, "rolls": True, "lock": False}, roll=True)),
    ("Raid - roll popup (raider)", st_drop({"loot": True, "rolls": True, "lock": False}, roll=True,
                                           viewer="Shadowmelder")),
    ("Raid - drop panel (plain, rolling)", st_drop({"loot": False, "rolls": True, "lock": False}, roll=True)),
    ("Raid - Start raid window", st_start_window),
    ("Raid - Raids tab - Upcoming (leader)", st_raids_in_raid("ns.RaidsUI:SetView('upcoming')")),
    ("Raid - Raid log - Players (leader)", st_raids_in_raid("ns.RaidsUI:SetView('log'); ns.RaidsUI:SetMode('players')")),
    ("Raid - Raid log - Raids (leader)", st_raids_in_raid("ns.RaidsUI:SetView('log'); ns.RaidsUI:SetMode('raids')")),
]
