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
    # the 25-player raid: members and guests answered (the Groups tab with five groups, a pool, the buffs)
    for n, st, sp in (("Victhar", "A", 3), ("Moonwhisper", "A", 2), ("Lightbringer", "A", 2), ("Thunderhoofx", "A", 3),
                      ("Frostweaver", "A", 1), ("Shadowmelder", "A", 2), ("Vaenyria", "T", 2), ("Grumpykat", "A", 3)):
        signup(c[n], IDS["ssc"], st, sp)
    for name, cls, sp in (("Ellesara", "PRIEST", 2), ("Damazzus", "PRIEST", 3), ("Lainatukka", "PALADIN", 1),
                          ("Fazerblue", "MAGE", 1), ("Lucielen", "MAGE", 1), ("Valshares", "PRIEST", 3),
                          ("Tsumil", "PALADIN", 3), ("Dyrma", "DRUID", 2), ("Rinsan", "WARLOCK", 3),
                          ("Ciciocul", "DRUID", 2), ("Belgaegroot", "DRUID", 2), ("Shabooty", "HUNTER", 1)):
        res = grumpy.eval_py("local ok, e = ns.RaidPlan:AddGuest(...); return { ok = ok, e = e }", IDS["ssc"], name,
                             cls, sp)
        assert res["ok"] is True, res
    w.tick(2)
    # the raid's own leader ("led by" in the header), named by the GM (once the raid reached her: the sync can take
    # a few seconds more while the guild's other data goes out)
    for _ in range(10):
        if gina.eval("return ns.RaidPlan:GetRaid(...) ~= nil", occ):
            break
        w.tick(1)
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
                              'DisasterZoneRaidLeader', 'DisasterZoneShareWindow', 'DisasterZoneImportExport',
                              'DisasterZoneRunToast', 'DisasterZoneStrategyShare',
                              'DisasterZoneEventSchedule', 'DisasterZoneEventSubmit', 'DisasterZoneBadgeDesigner',
                              'DisasterZoneEventSeason', 'DisasterZoneEventConfirm' }) do
        local f = _G[name]; if f and f.Hide then f:Hide() end
      end
      if ns.StrategyBoard and ns.StrategyBoard.Close then pcall(ns.StrategyBoard.Close, ns.StrategyBoard) end
      if ns.EventBuilder and ns.EventBuilder.StopPractice then pcall(ns.EventBuilder.StopPractice, ns.EventBuilder) end
      if ns.EventLive and ns.EventLive.StopPractice then pcall(ns.EventLive.StopPractice, ns.EventLive) end
      if ns.EventTracker and ns.EventTracker.Hide then pcall(ns.EventTracker.Hide, ns.EventTracker) end
      for _, name in ipairs({ 'DisasterZoneEventBuilder', 'DisasterZoneEventPicker', 'DisasterZoneEventAskName' }) do
        local f = _G[name]; if f and f.Hide then f:Hide() end
      end
      for _, name in ipairs({ 'DisasterZoneEventBoard', 'DisasterZoneEventTracker', 'DisasterZoneEventMatchCard',
                              'DisasterZoneEventToast', 'DisasterZoneEventAsk', 'DisasterZoneEventWait',
                              'DisasterZoneEventCountdown', 'DisasterZoneEventWarning' }) do
        local f = _G[name]; if f and f.Hide then f:Hide() end
      end
      if ns.Picker and ns.Picker.Close then pcall(ns.Picker.Close, ns.Picker) end
      if ns.DungeonsUI and ns.DungeonsUI.GetSheetState and ns.DungeonsUI:GetSheetState() then ns.DungeonsUI:CloseSheet() end
      if ns.RaidPlanUI and ns.RaidPlanUI.CloseEditor then ns.RaidPlanUI:CloseEditor() end
      if ns.DungeonRuns and ns.Demo and ns.Demo:IsEnabled() then ns.DungeonRuns:Unlist(true) end
      if ns.MainFrame and ns.MainFrame.Close then ns.MainFrame:Close() end
      if ns.DropPanel and ns.DropPanel.Hide then ns.DropPanel:Hide() end
      if ns.RollFrame and ns.RollFrame.frame then ns.RollFrame.frame:Hide() end
      if ns.UI and ns.UI.CloseMenus then ns.UI:CloseMenus() end
      __MOCK.real_geometry = nil
      local rf = _G.DisasterZoneRollFrame; if rf and rf.Hide then rf:Hide() end
      if GameTooltip then GameTooltip:Hide() end""")


def tab(cl, key):
    cl.eval("ns.MainFrame:Open(...)", key)


def demo_off(w, c):
    g = c["Gina"]
    if g.eval("return ns.Demo:IsEnabled()"):
        g.slash("/dz demo off")
        w.tick(1)


GEMS_SEED = ("ns.MyBiS:SetPhase(1, true); ns.Gems:FillPhase(1, nil, true); "
             "local g = ns.BiS:GetSlot(1, 7); local e, gems = ns.BiS:GetGemSetup(g); "
             "ns.BiS:SetGemSetup(g, 0, { gems[1], 0 }); "
             "local b = ns.BiS:GetSlot(1, 4); if b then ns.BiS:SetGemSetup(b, 0, {}) end; ns.MyBiS:Refresh(); ")


# My Log: three weekly SSC runs, a TK run, tonight's run with Vashj wipes (tests/mylog/test_mylog_ui.py SEED)
MYLOG_SEED = "ns.DB:SetSetting('mylog.enabled', true) " + r"""
local now = GetServerTime()
local WEEK = 7 * 86400
local chars = DisasterZoneLogDB.chars
local key = ns.Util.PlayerKey()
local c = { n = 0, pulls = {} }
chars[key] = c
local function pull(at, enc, boss, kill, dps, opts)
  opts = opts or {}
  c.n = c.n + 1
  local p = { id = c.n, at = at, enc = enc, boss = boss, zone = opts.zone or "Serpentshrine Cavern",
    iid = opts.iid or 548, kill = kill, dur = 240, spec = opts.spec or "Destruction", role = opts.role or "caster",
    cls = "WARLOCK", ilvl = opts.ilvl or 120, pct = (not kill) and opts.pct or nil, deaths = {},
    s = { d = dps * 240, dps = dps, hps = opts.hps or 0, h = (opts.hps or 0) * 240, oh = opts.oh or 0, sh = 0,
          t = 0, dtps = opts.dtps or 100, act = opts.act or 0.9, dc = opts.dc or 0, cpm = 38, sw = 0, avd = 0 } }
  c.pulls[#c.pulls + 1] = p
  return p
end
-- three weekly SSC runs, Hydross improving; Vashj wipes in the last one; one TK run in between
for w = 3, 1, -1 do
  local t = now - w * WEEK
  pull(t, 623, "Hydross the Unstable", true, 1000 + (3 - w) * 100, { ilvl = 118 + (3 - w) })
  pull(t + 1800, 624, "The Lurker Below", true, 1300 - (3 - w) * 50, { act = 0.85 + (3 - w) * 0.02 })
end
pull(now - 2 * WEEK + 3600 * 24, 730, "Al'ar", true, 900, { zone = "Tempest Keep", iid = 550 })
local t = now - 3600
pull(t, 623, "Hydross the Unstable", true, 1400, { ilvl = 124, dc = 1 })
pull(t + 900, 624, "The Lurker Below", true, 1250)
pull(t + 2400, 628, "Lady Vashj", false, 1100, { pct = 42.5, dc = 1 })
pull(t + 3000, 628, "Lady Vashj", false, 1150, { pct = 18.3 })
ns:Fire("MYLOG_CHANGED")
"""


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


def map_view(lua=None, share="exact"):
    """Guild > Map on Gina's screen: she stands in Honor Hold and shares (`share`), the demo guild spread over
    Outland (none for "unset": the card asking first)."""
    def fn(w, c):
        g = c["Gina"]
        close_all(g)
        w.set_position(g, 1944, 0.56, 0.62, subzone="Honor Hold")
        g.eval("ns.DB:SetSetting('map.share', ...)", share)
        on = g.eval("return ns.Demo:IsEnabled()")
        if share != "unset" and not on:
            g.slash("/dz demo on")
            w.tick(1)
        elif share == "unset" and on:
            g.slash("/dz demo off")
            w.tick(1)
        tab(g, "map")
        w.tick(1)
        if lua:
            g.eval(lua)
            w.tick(0.3)
        return g
    return fn


MB = {}
MB_ENCHANTS = [("Enchant Bracer - Spellpower", 27917, None), ("Enchant Bracer - Major Healing", 27911, None),
               ("Enchant Bracer - Brawn", 27899, None), ("Enchant Weapon - Soulfrost", 27982, None),
               ("Enchant Weapon - Sunfire", 27981, None), ("Enchant Weapon - Major Healing", 34010, None),
               ("Enchant Weapon - Mongoose", 27984, None), ("Enchant Chest - Exceptional Stats", 27960, None),
               ("Enchant Boots - Boar's Speed", 34008, None), ("Enchant Cloak - Greater Agility", 34004, None),
               ("Enchant Gloves - Major Spellpower", 33997, None), ("Enchant Ring - Healing Power", 27926, None)]


def members_seed(w, c):
    """The Members tab's guild, once: professions with recipes (Enchanting on Vaenyria's card), off specs, an offline
    alt of Vaenyria (Vaelia), an officer note, someone away, an offline member without DisasterZone (Darkhollow).
    Only the Members views look at it; the extra members are offline."""
    if MB.get("done"):
        return
    MB["done"] = True
    from mb_common import open_craft, open_tradeskill, ALCHEMY, TAILORING
    every = list(c.values())

    def names(cl):
        for name, spell, _ in MB_ENCHANTS:
            cl.eval("__MOCK.SPELL_NAMES[...] = select(2, ...)", spell, name)

    skills = {
        "Gina": [("Mining", 375, 375), ("Blacksmithing", 375, 375), ("Cooking", 300, 375)],
        "Grumpykat": [("Tailoring", 375, 375), ("Enchanting", 360, 375)],
        "Victhar": [("Blacksmithing", 375, 375), ("Mining", 375, 375)],
        "Shadowmelder": [("Engineering", 375, 375), ("Mining", 350, 375)],
        "Thunderhoofx": [("Jewelcrafting", 375, 375), ("Mining", 375, 375)],
        "Moonwhisper": [("Leatherworking", 375, 375), ("Skinning", 375, 375)],
        "Lightbringer": [("Alchemy", 375, 375), ("Herbalism", 375, 375), ("First Aid", 375, 375)],
        "Frostweaver": [("Tailoring", 375, 375), ("Enchanting", 375, 375)],
        "Vaenyria": [("Enchanting", 324, 375), ("Tailoring", 375, 375), ("Cooking", 375, 375), ("Fishing", 300, 375)],
    }
    for cl in every:
        names(cl)
    for name, s in skills.items():
        set_skills(c[name], s)
    # off specs (the secondary talents; the primary ones stay as the other views know them)
    for name, pts in (("Gina", (5, 8, 48)), ("Lightbringer", (20, 41, 0)), ("Moonwhisper", (11, 0, 50)),
                      ("Thunderhoofx", (0, 5, 56)), ("Victhar", (5, 15, 41)), ("Vaenyria", (5, 41, 15))):
        c[name].eval("local a, b, cc = ...; __MOCK.talents2 = { a, b, cc }", *pts)
        c[name].set_talents(c[name].talents)
    w.tick(5)
    open_craft(c["Vaenyria"], "Enchanting", MB_ENCHANTS, rank=324)
    open_craft(c["Grumpykat"], "Enchanting", MB_ENCHANTS[:3] + MB_ENCHANTS[6:9], rank=360)
    open_craft(c["Frostweaver"], "Enchanting", MB_ENCHANTS[1:3] + MB_ENCHANTS[6:], rank=375)
    open_tradeskill(c["Lightbringer"], "Alchemy", ALCHEMY)
    w.tick(2)
    open_tradeskill(c["Vaenyria"], "Tailoring", TAILORING)
    open_tradeskill(c["Frostweaver"], "Tailoring", TAILORING[:2])
    # Vaenyria's alt: logs in once with DisasterZone, then Vaenyria names her main
    alt = Client(w, "Vaelia", guild_rank=3, class_file="PRIEST", level=64)
    alt.load_addon()
    teach_names(alt)
    names(alt)
    set_skills(alt, [("Alchemy", 290, 375), ("Herbalism", 300, 375)])
    w.tick(5)
    open_tradeskill(alt, "Alchemy", ALCHEMY[:3], rank=290)
    w.tick(200)
    alt.logout()
    w.tick(3)
    c["Vaenyria"].eval("DisasterZoneDB.prof[ns.Guild:GetGuildKey()][...].own = true", K("Vaelia"))
    c["Vaenyria"].eval("ns.Professions:SetMain(...)", K("Vaenyria"))
    w.add_offline_member("Darkhollow", "MAGE", 3)
    c["Grumpykat"].eval("ns.OfficerNotes:Set(...)", K("Vaenyria"),
                        "Swapping to Marksmanship for SSC. Trial ends 12 Oct, Grumpy and Gina decide.")
    c["Gina"].eval("__MOCK.roster_status = { ['Moonwhisper-Thunderstrike'] = 1 }; C_GuildInfo.GuildRoster()")
    w.tick(5)
    # the in-game report of 2026-10-05: a long rank (rank 4, nobody else has it), an older DisasterZone, no other
    # characters but a raid team; and offline members without DisasterZone, so the roster scrolls
    w.guild_ranks["Casual Disaster"] = ["Guild Master", "Officer", "Raider", "Member", "Unstable Spark"]
    salty = Client(w, "Saltykim", guild_rank=4, class_file="DRUID")
    salty.load_addon()
    teach_names(salty)
    names(salty)
    set_skills(salty, [("Leatherworking", 342, 375), ("Skinning", 371, 375)])
    MB["salty"] = salty
    for i, (name, cls) in enumerate((("Brakka", "WARRIOR"), ("Elowen", "HUNTER"), ("Quillon", "DRUID"),
                                     ("Rhosyn", "DRUID"), ("Caelith", "PALADIN"), ("Mirabel", "PRIEST"),
                                     ("Nortok", "SHAMAN"), ("Orinel", "WARLOCK"))):
        w.add_offline_member(name, cls, 3, level=70 if i % 3 else 68)
    team(c["Grumpykat"], "T1: Cat Aggro", ["Saltykim", "Moonwhisper", "Gina"])
    w.tick(200)


def members_view(lua=None):
    """A Members tab state on members_seed's guild; Shadowmelder and Saltykim run an older DisasterZone."""
    base = opened("members", lua)

    def fn(w, c):
        members_seed(w, c)
        c["Gina"].eval("for k, v in pairs({ ['Shadowmelder-Thunderstrike'] = '1.2.0', ['Saltykim-Thunderstrike'] = "
                       "'1.3.0' }) do local p = ns.db.peers and ns.db.peers[k]; if p then p.v = v end end")
        return base(w, c)
    return fn


# Gina's shopping list on members_seed's guild: Lightbringer's Alchemy makes the most (three), Vaenyria's Tailoring and
# Enchanting the next, an Imbued Netherweave Bag nobody knows, a Spellstrike Hood that binds when picked up. Bags hold
# a few materials; a stand-in Auctionator prices some. (The mock binds every item on pickup: the list's are BoE here.)
SHOP_SEED = r"""
for _, id in ipairs({ 21841, 22851, 22832, 22831, 21843 }) do local r = __MOCK.item_rec(id); if r then r.bind = 2 end end
ns.Shop:Clear()
ns.Shop:Add(22851, 5); ns.Shop:Add(22832, 10); ns.Shop:Add(22831, 5); ns.Shop:Add(21841, 2, 1); ns.Shop:Add(-27984)
ns.Shop:Add(21843); ns.Shop:Add(24266)
Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function(_, id)
  return ({ [22794] = 420000, [22793] = 61000, [22790] = 92000, [22789] = 38000, [22786] = 41000, [22445] = 18000,
            [22449] = 255000, [22450] = 480000, [22446] = 66000, [21877] = 9000 })[id] end } } }
"""


def shop_view(lua=None, bags=None):
    """The Atlas's shopping list (Everything, or lua after it opened) on members_seed's guild."""
    def fn(w, c):
        members_seed(w, c)
        g = c["Gina"]
        g.eval(SHOP_SEED)
        g.set_bags(bags or {(0, 1): (22794, 5), (0, 2): (21877, 20), (0, 3): (22786, 35), (0, 4): (22445, 9),
                            (0, 5): (14341, 2)})
        return opened("atlas", "ns.AtlasUI:OpenShop('all'); " + (lua or ""))(w, c)
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


def st_board(lua, viewer="Gina", before=None, after=None, tick=0.3):
    """The strategy board on its own: the main window closed after it opened (the renderer ignores strata and would
    draw the Raids tab through the board). before(w, c) runs first (other clients), after(w, c) once it is open."""
    def fn(w, c):
        g = c[viewer]
        demo_off(w, c)
        for x in c.values():
            close_all(x)
        if before:
            before(w, c)
        tab(g, "raids")
        w.tick(0.3)
        g.eval("local W = _G.DisasterZoneStrategyBoard; if W and W.canvas then W.canvas:Set3D(false, false) end")
        g.eval(lua, *[IDS.get(k) for k in ("occ", "strat", "team", "ssc")])
        w.tick(tick)
        if after:
            after(w, c)
        g.eval("if ns.MainFrame and ns.MainFrame.Close then ns.MainFrame:Close() end")
        return g
    return fn


# a new strategy (qdwq) on Teron's starter with the first table its map suggests (the mockup's Magtheridon starter
# has creatures whose names overlap on the map, which the audit would report)
ST_QDWQ = ("ns.StrategyBoard:NewStrategy('BlackTemple:Teron', 'qdwq'); "
           "local W = _G.DisasterZoneStrategyBoard; local p = ns.StrategyBoard:GetState().strat.p[1]; "
           "local sg = W.blocks:Suggestions(p)[1]; if sg then sg.apply() end; ")
# a raid's board with names: Gina assigns the SSC night's Lurker (25 players with the guests; Suggest fill)
ST_FILL = ("ns.StrategyBoard:OpenRaid(select(4, ...), 'SerpentshrineCavern:Lurker', 'fill'); ns.StrategyBoard:Suggest(); ")


def st_assigned(w, c):
    # Gina's names for the SSC night's Lurker, saved: Shadowmelder in a zone
    g = c["Gina"]
    g.eval(ST_FILL + "local s = ns.StrategyBoard:GetState(); s.assign['zn.1.1'] = ns.Util.NormalizeName('Shadowmelder'); "
           "s.assign['zn.2.2'] = ns.Util.NormalizeName('Frostweaver'); ns.StrategyBoard:MarkDirty(true); "
           "ns.StrategyBoard:Save(); ns.StrategyBoard:Close()", *[IDS.get(k) for k in ("occ", "strat", "team", "ssc")])
    w.tick(3)


def st_live_peers(w, c):
    # Victhar and Shadowmelder edit the Lurker strategy with Gina (one live board); Victhar is on its second page
    for n in ("Victhar", "Shadowmelder"):
        c[n].eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", IDS["strat"])
        w.tick(4)


def st_live_after(w, c):
    w.tick(4)
    v = c["Victhar"]
    v.eval("local s = ns.StrategyBoard:GetState(); s.page = 2; ns.StrategyBoard:Refresh()")
    w.tick(3)
    c["Gina"].eval("local s = ns.StrategyBoard:GetState(); s.strat.p[1].e[1].x = 330; ns.StrategyBoard:MarkDirty(true)")
    w.tick(2)


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


def st_drop(features, roll=False, viewer="Gina", then=None, item_lua=None):
    """then: None (the roll stays open), "closed" (End roll) or "awarded" (the suggested roller gets it).
    item_lua: Lua returning the dropped item (default: the first P1 head)."""
    def fn(w, c):
        g = raid_with_session(w, c, features)
        # a roll an earlier view left open would queue this one: end them
        g.eval("for _, s in ipairs(ns.Roll:GetQueue() or {}) do if s.id then ns.Roll:End(s.id) end end; "
               "local a = ns.Roll:GetActive(); if a then ns.Roll:End(a.id) end")
        w.tick(1)
        item = g.eval(item_lua or "return ns.ItemDB:GetCandidates(1, { maxPhase = 1 })[1].itemID")
        DROPS.append(1)
        g.open_loot([(item, 4)], source_guid="Creature-0-1-2-3-15690-%06X" % len(DROPS))
        w.tick(2)
        if roll:
            g.eval("ns.DropPanel:StartRoll(...)", item)
            w.tick(1)
            for n, v in (("Victhar", 87), ("Shadowmelder", 42), ("Pugsyhealer", 99), ("Darkstalkerr", 15)):
                w.player_roll(c[n], v)
            w.tick(1)
            if then in ("closed", "awarded"):
                g.eval("local b = ns.DropPanel.blocks[1]; ns.DropPanel:EndRoll(b.rollSession)")
                w.tick(1)
            if then == "awarded":
                g.eval("ns.DropPanel:Render(); ns.DropPanel:AwardSuggested(ns.DropPanel.blocks[1])")
                w.tick(0.5)
                for p in ("DISASTERZONE_CONFIRM_AWARD", "DISASTERZONE_GIVE_ITEM"):
                    if p in g.popups():
                        g.accept_popup(p)
                w.tick(2)
            g.eval("ns.DropPanel:Render()")
        # the mock's loot window fills the screen, so the panel (placed beside it) would sit off screen
        g.eval("local f = ns.DropPanel.frame; if f then f:ClearAllPoints(); f:SetPoint('TOPLEFT', UIParent, 'TOPLEFT', 40, -80) end")
        return c[viewer]
    return fn


def st_settings_in_raid(section):
    """Settings on Gina's screen while Grumpykat leads the raid (his loot rules: 45 s rolls, rares, phase P2)."""
    def fn(w, c):
        g, grumpy = c["Gina"], c["Grumpykat"]
        demo_off(w, c)
        close_all(g)
        for path, value in (("roll.duration", 45), ("qualityThreshold", 3), ("groupPhase", 2)):
            grumpy.eval("ns.DB:SetSetting(...)", path, value)
        w.make_raid([grumpy, g] + [c[n] for n in ("Victhar", "Shadowmelder", "Vaenyria", "Moonwhisper")],
                    leader=grumpy)
        w.tick(8)
        tab(g, "settings")
        w.tick(0.3)
        g.eval("ns.SettingsUI:SelectSection(...)", section)
        return g
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


def st_council_raid_leader(w, c):
    """The Loot council view while Gina leads a raid: both cards editable."""
    g = raid_with_session(w, c, None)
    g.eval("ns.CouncilUI:RevertCouncil('guild')")
    tab(g, "council")
    w.tick(0.3)
    g.eval("ns.CouncilUI:ShowCouncil()")
    return g


def st_council_roster_lock(w, c):
    """The Council roster while Gina leads a raid with the loot council on: the filter row carries "Lock lists"."""
    g = raid_with_session(w, c, {"loot": True, "rolls": True, "lock": False})
    tab(g, "council")
    w.tick(0.3)
    g.eval("ns.CouncilUI:SetView('roster')")
    return g


def st_council_officer(w, c):
    """Grumpykat (officer, on the guild council) looks at the Loot council view in Gina's raid: both cards
    read-only (Gina saved a raid council with Victhar)."""
    g, k = c["Gina"], c["Grumpykat"]
    demo_off(w, c)
    close_all(g)
    close_all(k)
    w.enter_instance("Karazhan", 532)
    w.make_raid([g, k, c["Victhar"], c["Shadowmelder"]], leader=g)
    w.tick(4)
    g.eval("ns.CouncilUI:RevertCouncil('raid'); ns.CouncilUI:ToggleCouncilDraft('raid', ...); "
           "ns.CouncilUI:SaveCouncil('raid')", K("Victhar"))
    w.tick(3)
    tab(k, "council")
    w.tick(0.3)
    k.eval("ns.CouncilUI:ShowCouncil()")
    return k


# Gina up for a run as tank or healer, Lower City honored (its heroics need revered)
DR_ME = ("__MOCK.factions[1011] = 5; ns.DungeonRuns:SetMyRole('tank', true); ns.DungeonRuns:SetMyRole('healer', true); "
         "ns.DungeonRuns:SetMyRole('dps', false); ")

# Gina's Pre-raid list (phase 0) from her guide's Pre-raid list
SEED_PRE_RAID = ("local d = ns.BiS:GetData(); local spec = ns.BiS:GetSpec(); "
                 "if spec == '' then spec = ns.SPECS[d.cl][1].label end; "
                 "ns.BiS:ApplyTemplate(0, ns.Loon:GetTemplate(d.cl, spec, 0) or {}, true); ")

# What the Atlas's currency bar shows: some honor, a little arena, badges in bags and bank, 4 AV marks
ATLAS_PURSE = ("__MOCK.set_currency(1901, 14230); __MOCK.set_currency(1900, 1240); "
               "__MOCK.give_item(29434, 46); __MOCK.give_item(20560, 4); "
               "__MOCK.set_bags({ { -1, 1, 29434, 30 } }, true); ")


def atlas_hover(select_lua, item_lua):
    """The Atlas with ATLAS_PURSE, a page selected, then (after the refresh what I hold triggers) a row hovered."""
    def fn(w, c):
        g = opened("atlas", ATLAS_PURSE + select_lua)(w, c)
        w.tick(0.6)
        g.eval("ns.AtlasUI:HoverItem(" + item_lua + ")")
        return g
    return fn


def st_blizzard_options(w, c):
    """DisasterZone's panel in Blizzard's Options > AddOns (UI/Settings.lua), at the canvas size the game gives it."""
    g = c["Gina"]
    demo_off(w, c)
    close_all(g)
    g.eval("local f = DisasterZoneBlizzardOptions; f:SetParent(UIParent); f:ClearAllPoints(); "
           "f:SetPoint('CENTER'); f:SetSize(860, 640); f:Hide(); f:Show()")
    w.tick(0.8)
    return g


STATES = [
    ("Blizzard options panel", st_blizzard_options),
    ("Home", opened("home")),
    # the nav strip's group menus (UI/Menu.lua's page list: title over its line, the open page with the gold bar)
    ("Nav - Guild menu", opened("home", "__MOCK.real_geometry = true; for _, t in ipairs(DisasterZoneMainFrame.Tabs) "
                                             "do if t.cdlKey == 'grp:guild' then t.IsMouseOver = function() return true end; t:Click() end end")),
    ("Nav - Raids menu", opened("home", "__MOCK.real_geometry = true; for _, t in ipairs(DisasterZoneMainFrame.Tabs) "
                                           "do if t.cdlKey == 'grp:raids' then t.IsMouseOver = function() return true end; t:Click() end end")),
    ("Home - calendar day", opened("home", "local v = ns.RaidPlan:GetRaid(select(4, ...)); "
                                           "local key = tonumber(date('%Y%m%d', v.t)); "
                                           "for _, c in ipairs(ns.Dashboard:GetPanel().calCard.cells) do "
                                           "if c.key == key then c:GetScript('OnClick')(c) end end")),
    ("My BiS", opened("mybis")),
    ("My BiS - spec menu", opened("mybis", "local o; for _, s in ipairs(ns.SPECS[ns.BiS:GetData().cl]) do "
        "if s.label ~= ns.BiS:GetSpec() then o = s.label end end; ns.BiS:SetSpec(o, 'os'); ns.MyBiS:Refresh(); "
        "ns.MyBiS:OpenSpecMenu(o)")),
    ("My BiS - off spec shown", opened("mybis", "local o; for _, s in ipairs(ns.SPECS[ns.BiS:GetData().cl]) do "
        "if s.label ~= ns.BiS:GetSpec() then o = s.label end end; ns.BiS:SetSpec(o, 'os'); ns.MyBiS:SetList('os')")),
    ("My BiS - item picker", opened("mybis", "ns.Picker:Open(1, 1, 'main')")),
    # gems and enchants: the guide's on every P1 pick, then the gloves' blue socket and the cloak's enchant emptied
    # (an empty socket, a "+"), and the editor open on the gloves
    ("My BiS - gems", opened("mybis", GEMS_SEED)),
    ("My BiS - gems tooltip", opened("mybis", GEMS_SEED + "local function find(f) if f.strip and f.sid == 3 then "
                                    "return f end for _, ch in ipairs({ f:GetChildren() }) do local r = find(ch) "
                                    "if r then return r end end end local t = find(UIParent); "
                                    "t.strip:GetScript('OnEnter')(t.strip)")),
    ("My BiS - gem editor", opened("mybis", GEMS_SEED + "local function find(f) if f.strip and f.sid == 7 then "
                                   "return f end for _, ch in ipairs({ f:GetChildren() }) do local r = find(ch) "
                                   "if r then return r end end end local t = find(UIParent); "
                                   "ns.GemEditor:Open(t, t.mainID, 1)")),
    # the addon's own menu (UI/Menu.lua): More under its button, the Copy submenu open (real geometry: the menu is
    # placed from where its button really is; close_all turns it off again)
    ("My BiS - More menu", opened("mybis", "__MOCK.real_geometry = true; "
                                           "local function find(f) if rawget(f, 'tipTitle') == 'More' and f:IsVisible() "
                                           "then return f end for _, ch in ipairs({ f:GetChildren() }) do "
                                           "local r = find(ch) if r then return r end end end "
                                           "find(UIParent):Click(); local fr = ns.UI:GetMenuFrames(); "
                                           "for _, r in ipairs(fr[1].rows) do if r.hasKids then "
                                           "r:GetScript('OnEnter')(r) end end")),
    # the Import / Export window (UI/ImportExport.lua): a That's My BiS paste over Gina's seeded P1 list, an error,
    # and the export tab
    ("My BiS - Import", opened("mybis", "ns.ImportExport:Open('import'); ns.ImportExport:SetSource([==[" + TMB_SAMPLE
                                         + "]==])")),
    ("My BiS - Import error", opened("mybis", "ns.ImportExport:Open('import'); "
                                               "ns.ImportExport:SetSource('{\"items\": [1, 2')")),
    ("My BiS - Export", opened("mybis", "ns.ImportExport:Open('export')")),
    # the same paste into the Pre-raid list (phase 0: the longest phase label in the window)
    ("My BiS - Import into Pre-raid", opened("mybis", "ns.ImportExport:Open('import'); "
                                                       "ns.ImportExport:GetImportState().phase = 0; "
                                                       "ns.ImportExport:SetSource([==[" + TMB_SAMPLE + "]==])")),
    # the Pre-raid tab (phase 0), filled from Gina's guide's Pre-raid list
    ("My BiS - Pre-raid", opened("mybis", SEED_PRE_RAID + "ns.MyBiS:SetPhase(0)")),
    ("Atlas - raid boss", opened("atlas", "ns.AtlasUI:Select('raids', 'Karazhan', 'Prince')")),
    # my marks on a heroic dungeon's items: Gina's Pre-raid list (its hands also in P2: "Pre-raid, P2")
    ("Atlas - Pre-raid marks", opened("atlas", SEED_PRE_RAID + "local g = ns.BiS:GetSlot(0, 7); "
                                               "if g then ns.BiS:SetSlot(2, 7, 'main', g) end; local page; "
                                               "for _, d in ipairs(ns.Data.Dungeons) do if d.key == 'HellfireRamparts' then "
                                               "for _, b in ipairs(d.bosses) do for _, id in ipairs(b.heroicItems or {}) do "
                                               "if id == g then page = b.key end end end end end; "
                                               "ns.AtlasUI:Select('dungeons', 'HellfireRamparts', page, true)")),
    ("Atlas - dungeon heroic", opened("atlas", "ns.AtlasUI:Select('dungeons', 'BlackMorass', nil, true)")),
    ("Atlas - reputation", opened("atlas", "ns.AtlasUI:Select('reputation', 'Shatar')")),
    ("Atlas - crafting", opened("atlas", "ns.AtlasUI:Select('crafting', 'Enchanting')")),
    ("Atlas - sets", opened("atlas", "ns.AtlasUI:Select('sets', 'Tier6')")),
    ("Atlas - arena sets", opened("atlas", "ns.AtlasUI:Select('sets', 'ArenaS4', 'Priest')")),
    ("Atlas - search", opened("atlas", "ns.AtlasUI:SetSearch('gladiator')")),
    ("Atlas - item menu", opened("atlas", "ns.AtlasUI:Select('raids', 'Karazhan', 'Attumen'); "
                                          "ns.AtlasUI:OpenMenu({ type = 'item', id = 28505 })")),
    ("Atlas - hover add", opened("atlas", "ns.AtlasUI:Select('raids', 'Karazhan', 'Attumen'); "
                                          "ns.AtlasUI:HoverItem(28477)")),
    ("Atlas - badge vendor", opened("atlas", "ns.AtlasUI:Select('vendors', 'BadgeofJustice')")),
    ("Atlas - arena vendor", opened("atlas", "ns.AtlasUI:Select('pvp', 'ArenaS2')")),
    # costs and the currency bar: some honor / arena points / badges held, a row hovered (its currencies lit)
    ("Atlas - costs hover short", atlas_hover("ns.AtlasUI:Select('pvp', 'ArenaS3')",
                                              "ns.Atlas:GetSource('pvp', 'ArenaS3').pages[1].items[1]")),
    ("Atlas - costs hover enough", atlas_hover("ns.AtlasUI:Select('vendors', 'BadgeofJustice')",
                                               "ns.Atlas:GetSource('vendors', 'BadgeofJustice').pages[1].items[1]")),
    ("Atlas - costs marks", opened("atlas", ATLAS_PURSE + "ns.AtlasUI:Select('pvp', 'Mounts')")),
    ("Atlas - set totals", opened("atlas", ATLAS_PURSE + "ns.AtlasUI:Select('sets', 'ArenaS3', 'Paladin')")),
    ("Atlas - shopping list", shop_view()),
    ("Atlas - shopping list crafter", shop_view("ns.AtlasShopUI:Select('Lightbringer-Thunderstrike')")),
    ("Atlas - shopping list empty", shop_view("ns.Shop:Clear()")),
    ("Atlas - shopping list add", shop_view("ns.AtlasUI:Select('crafting', 'Tailoring', 'Bag'); "
                                            "ns.AtlasUI:HoverItem(21841)")),
    ("Council - Loot Log", opened("council", "ns.CouncilUI:ShowLog()")),
    ("Raids - Upcoming board", opened("raids", "ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:ShowBoard()")),
    ("Raids - Upcoming", opened("raids", "ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:SelectRaid(...); "
                                          "ns.RaidPlanUI:SetDetailTab('signups')")),
    ("Raids - Upcoming - Groups", opened("raids", "ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:SelectRaid(...); "
                                                  "ns.RaidPlanUI:SetDetailTab('groups')")),
    ("Raids - Upcoming - SSC sign-ups", opened("raids", "ns.RaidsUI:SetView('upcoming'); "
                                                         "ns.RaidPlanUI:SelectRaid(select(4, ...)); "
                                                         "ns.RaidPlanUI:SetDetailTab('signups')")),
    ("Raids - Upcoming - SSC groups", opened("raids", "ns.RaidsUI:SetView('upcoming'); "
                                                       "ns.RaidPlanUI:SelectRaid(select(4, ...)); "
                                                       "ns.RaidPlanUI:SetDetailTab('groups')")),
    ("Raids - Upcoming - Assignments", opened("raids", "ns.RaidsUI:SetView('upcoming'); "
                                                       "ns.RaidPlanUI:SelectRaid(...); "
                                                       "ns.RaidPlanUI:SetDetailTab('assign')")),
    ("Raids - Upcoming - Raid leader", opened("raids", "ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:SelectRaid(...); "
                                                       "ns.RaidPlanUI:OpenLeader(...)")),
    ("Raids - Teams", opened("raids", "ns.RaidsUI:SetView('teams'); ns.RaidPlanUI:SelectTeam(select(3, ...))")),
    ("Raids - Strategies", opened("raids", "ns.RaidsUI:SetView('strategies')")),
    # (the Collaborators window of one of Gina's own strategies: only the owner opens it)
    ("Raids - Strategies - share", opened("raids", "ns.RaidsUI:SetView('strategies'); local id; "
                                                   "for _, s in ipairs(ns.Strategy:Find({ by = ns.Util.PlayerKey() })) "
                                                   "do id = s.id end; ns.MainFrame:Close(); "
                                                   "ns.StrategiesUI:OpenShare(id)")),
    # a raid unfolded with one of its bosses picked
    ("Raids - Strategies - boss", opened("raids", "ns.RaidsUI:SetView('strategies'); "
                                                  "ns.StrategiesUI:SelectBoss('Karazhan:Attumen')")),
    ("Raids - Raid log - Raids", opened("raids", "ns.RaidsUI:SetMode('raids')")),
    ("Raids - Raid log - Players", opened("raids", "ns.RaidsUI:SetMode('players')")),
    # the logged raid linked to the planned Karazhan: its sign-ups against who came (Thunderhoofx didn't)
    ("Raids - Raid log - linked", opened("raids", "local r = ns.RaidLog:GetRaids()[1]; "
                                                  "ns.RaidLog:SetPlanned(r.id, (...)); r.su = r.su or {}; "
                                                  "for _, n in ipairs({ 'Victhar', 'Shadowmelder', 'Vaenyria', "
                                                  "'Thunderhoofx', 'Moonwhisper', 'Lightbringer' }) do "
                                                  "r.su[ns.Util.NormalizeName(n)] = 'A' end; "
                                                  "r.su[ns.Util.NormalizeName('Frostweaver')] = 'T'; "
                                                  "ns.RaidsUI:Select(r.id)")),
    ("Raids - New raid", st_window("ns.RaidPlanUI:OpenEditor()")),
    ("Raids - Edit raid", st_window("ns.RaidPlanUI:OpenEditor(...)")),
    # 1.3.2: one raid of two instances (Gruul, then Magtheridon), for the teams and invited players
    ("Raids - New raid - Gruul + Mag", st_window("ns.RaidPlanUI:OpenEditor(); ns.RaidPlanUI:ToggleEditorRaid('kara'); "
                                                "ns.RaidPlanUI:ToggleEditorRaid('gruul'); "
                                                "ns.RaidPlanUI:ToggleEditorRaid('mag'); "
                                                "ns.RaidPlanUI:SetEditorAccess('locked')")),
    # 1.3.2: nine teams and two players picked: the Who row stays two lines ("+N more"), its search open
    ("Raids - New raid - many teams", st_window("local m = {}; for _, n in ipairs({ 'Victhar', 'Shadowmelder', "
                                               "'Vaenyria' }) do m[#m + 1] = ns.Util.NormalizeName(n) end; "
                                               "ns.RaidPlanUI:OpenEditor(); local ed = ns.RaidPlanUI:GetEditor(); "
                                               "ed.f.inv[ns.Util.NormalizeName('Moonwhisper')] = true; "
                                               "ed.f.inv[ns.Util.NormalizeName('Lightbringer')] = true; "
                                               "for n = 1, 9 do local ok, id = ns.RaidPlan:SaveTeam(nil, "
                                               "'Raid team ' .. n, m); if ok then ns.RaidPlanUI:PickEditorTeam(id) "
                                               "end end; ed.invPicker:Open()")),
    ("Raids - Add players - members", st_window("ns.RaidPlanUI:OpenInvites(...)")),
    ("Raids - Add players - guest", st_window("ns.RaidPlanUI:OpenInvites(...); "
                                              "ns.RaidPlanUI:GetInviteWindow().mode = 'guest'; "
                                              "ns.RaidPlanUI:RefreshInvites()")),
    ("Raids - Guests - guest book", opened("raids", "ns.GuestBookUI:Open('book')")),
    ("Raids - Guests - a guest", opened("raids", "ns.GuestBookUI:OpenGuest('Pugsyhealer')")),
    ("Raids - Guests - blacklist", opened("raids", "ns.GuestBookUI:Open('black')")),
    ("Raids - Guests - add a player", opened("raids", "ns.GuestBookUI:OpenGuest('Shadowfang'); "
                                         "ns.GuestBookUI:GetWindow().form.noteBox:SetText('Geared resto druid, wants a "
                                         "Thu + Sun guild')")),
    ("Raids - Guests - blacklist a player", opened("raids", "ns.GuestBookUI:OpenBlacklist('Grimbold')")),
    ("Raids - Raid leaders", st_window("ns.RaidLeadersUI:Open()")),
    ("Raids - Strategy board", st_board("ns.StrategyBoard:OpenStrategy(select(2, ...))")),
    ("Raids - Strategy board - edit", st_board("ns.StrategyBoard:OpenStrategy(select(2, ...), 'edit')")),
    # the strategy board's chrome (2026-10-06): the user's Magtheridon board while editing (unsaved), just saved, with
    # a selection (undo and redo, the selection's controls), three pages, a page without tables (Add a block with the
    # map's suggestions), the keys card, near the drawings limit; someone else's strategy read by a member (In raids);
    # a raid's board while assigning (the players on the panel) and as a raider reads it (your jobs); three editors on
    # one live board; the tutorial's practice board
    ("Raids - Strategy board - edit dirty", st_board(ST_QDWQ)),
    ("Raids - Strategy board - saved", st_board(ST_QDWQ + "ns.StrategyBoard:Save()")),
    ("Raids - Strategy board - selection", st_board(
        ST_QDWQ + "local B = ns.StrategyBoard; local st = B:GetState(); local W = _G.DisasterZoneStrategyBoard; "
        "local p = st.strat.p[1]; p.e[1].x = p.e[1].x + 10; B:MarkDirty(true); B:Undo(); "
        "for _, e in ipairs(B:GetState().strat.p[1].e) do if e.t == 'i' and e.l then W.canvas:Select(e); break end end; "
        "B:RefreshTools()")),
    ("Raids - Strategy board - pages", st_board(
        ST_QDWQ + "local B = ns.StrategyBoard; local st = B:GetState(); B:AddPage(); st.strat.p[2].n = 'Collapse'; "
        "B:AddPage(); st.strat.p[3].n = 'Adds'; local p = st.strat.p[2]; "
        "local k = { id = ns.Strategy:NewPartId(st.strat, 'k'), n = 'Debris', r = 5, cl = 3, i = 'i:Spell_Fire_SelfDestruct', "
        "c = { { t = 'p', n = 'Player' }, { t = 'g', n = 'Stands at' } }, d = {} }; "
        "for i = 1, 5 do k.d[i] = { [2] = { l = 'Debris ' .. i } }; p.e[#p.e + 1] = { t = 'z', s = 'c', "
        "x = 300 + (i % 3) * 180, y = 200 + math.floor(i / 3) * 200, w = 90, h = 90, c = 3, l = 'Debris ' .. i } end; "
        "p.k[1] = k; st.page = 2; B:MarkDirty(true)")),
    ("Raids - Strategy board - empty page", st_board(
        "ns.StrategyBoard:NewStrategy('BlackTemple:Teron', 'qdwq'); local B = ns.StrategyBoard; "
        "local st = B:GetState(); local p1 = st.strat.p[1]; local apply; "
        "for _, s in ipairs(_G.DisasterZoneStrategyBoard.blocks:Suggestions(p1)) do "
        "apply = apply or s.apply end; apply(); B:AddPage(); st.strat.p[2].n = 'Collapse'; "
        "local c = ns.Util.CopyTable(p1); c.id = ns.Strategy:NewPartId(st.strat, 'p'); c.n = 'Phase 2'; c.k = {}; "
        "for _, e in ipairs(c.e) do e.ln = nil end; st.strat.p[3] = c; st.page = 3; B:MarkDirty(true)")),
    ("Raids - Strategy board - keys", st_board(ST_QDWQ + "ns.StrategyBoard:ShowKeys()")),
    ("Raids - Strategy board - near limit", st_board(
        ST_QDWQ + "local st = ns.StrategyBoard:GetState(); local p = st.strat.p[1]; local n = 76 - #p.e; "
        "for i = 1, n do p.e[#p.e + 1] = { t = 'i', x = 60 + (i % 12) * 70, y = 560 + math.floor(i / 12) * 14, "
        "i = 'rt' .. (i % 8 + 1), z = 14 } end; ns.StrategyBoard:MarkDirty(true)")),
    ("Raids - Strategy board - view only", st_board(
        "local s = ns.Strategy:GetStrategies('SerpentshrineCavern:Leotheras')[1]; ns.StrategyBoard:OpenStrategy(s.id)",
        viewer="Shadowmelder")),
    ("Raids - Strategy board - fill", st_board(ST_FILL)),
    ("Raids - Strategy board - raid view", st_board(
        "ns.StrategyBoard:OpenRaid(select(4, ...), 'SerpentshrineCavern:Lurker')", viewer="Shadowmelder",
        before=st_assigned)),
    ("Raids - Strategy board - live", st_board(
        "ns.StrategyBoard:OpenStrategy(select(2, ...), 'edit')", before=st_live_peers, after=st_live_after)),
    # (in the room: on the map the five council members' names overlap where they stand together)
    ("Raids - Strategy board - practice board", st_board("ns.StrategyBoard:OpenSandbox('GruulsLair:Maulgar'); "
                                                       "_G.DisasterZoneStrategyBoard.canvas:Set3D(true, false)")),
    # a boss with a room: the 2D / 3D switch under the map, and the page in 3D (UI/StrategyMap3D.lua)
    ("Raids - Strategy board - Teron 2D", st_board("ns.StrategyBoard:NewStrategy('BlackTemple:Teron')")),
    ("Raids - Strategy board - Teron 3D", st_board("ns.StrategyBoard:NewStrategy('BlackTemple:Teron'); "
                                                   "_G.DisasterZoneStrategyBoard.canvas:Set3D(true, false)")),
    # Lady Vashj's Shield Generators (Data/EncounterObjects.lua): their models, beams and her barrier; then the walk
    # button held over the floor beside her (the landing ring and you see-through in it)
    ("Raids - Strategy board - Vashj 3D", st_board("ns.StrategyBoard:NewStrategy('SerpentshrineCavern:Vashj'); "
                                                   "_G.DisasterZoneStrategyBoard.canvas:Set3D(true, false)")),
    ("Raids - Strategy board - Vashj 3D walk drop", st_board(
        "ns.StrategyBoard:NewStrategy('SerpentshrineCavern:Vashj'); local cv = _G.DisasterZoneStrategyBoard.canvas; "
        "cv:Set3D(true, false); local v = cv.v3; v:Draw(); local s = ns.Render3D.RoomForBoss('SerpentshrineCavern:Vashj')"
        ".spot; local sx, sy = v.R.Project(s.x + 10, s.y - 6, v:Ground(s.x + 10, s.y - 6)); "
        "local es = v.view.scene:GetEffectiveScale() or 1; _G.GetCursorPosition = function() return sx * es, sy * es end; "
        "_G.IsMouseButtonDown = function() return true end; v.frame.IsMouseOver = function() return true end; "
        "v:BeginPeg(); v:Draw()")),
    ("Council - Loot Log - award dialog", opened("council", "ns.CouncilUI:ShowLog(); ns.LootLogUI:OpenAwardDialog("
                                               "ns.ItemDB:GetCandidates(1, { maxPhase = 1 })[1].itemID, "
                                               "'Shadowmelder-Thunderstrike', 'Karazhan:Prince')")),
    ("Members - roster", members_view()),
    # Guild > Map (UI/GuildMapUI.lua): the card asking first, Outland with the demo guild, Shattrath zoomed in
    ("Guild map - asks first", map_view(share="unset")),
    ("Guild map - Outland", map_view()),
    ("Guild map - Shattrath", map_view("ns.GuildMapUI:ShowZone(1955)")),
    ("Guild map - Hellfire Peninsula", map_view("ns.GuildMapUI:ShowZone(1944)")),
    ("Members - member card", members_view("ns.MembersUI:ShowMember('Vaenyria-Thunderstrike', 333)")),
    ("Members - recipes", members_view("ns.MembersUI:SetMode('recipes')")),
    # the card's other tabs, a profession filter (the rank in gold, highest first), a member without DisasterZone
    ("Members - member card - characters", members_view("ns.MembersUI:ShowMember('Vaenyria-Thunderstrike'); "
                                                         "ns.MembersUI:SetCard('chars')")),
    ("Members - member card - equipment", members_view("ns.MembersUI:ShowMember('Vaenyria-Thunderstrike'); "
                                                        "ns.MembersUI:SetCard('gear')")),
    ("Members - roster - filter", members_view("ns.MembersUI:SetProfession(333); "
                                                "ns.MembersUI:SelectMember('Frostweaver-Thunderstrike')")),
    ("Members - no addon", members_view("ns.MembersUI:ShowMember('Darkhollow-Thunderstrike'); "
                                         "ns.MembersUI:SetCard('profs')")),
    ("Members - recipe card", members_view("ns.MembersUI:ShowRecipe(27917)")),
    # a long rank and an older DisasterZone in the header, no linked characters but a raid team, a scrolling roster
    ("Members - long rank, older version", members_view("ns.MembersUI:ShowMember('Saltykim-Thunderstrike'); "
                                                         "ns.MembersUI:SetCard('chars')")),
    ("Games", opened("games")),
    ("Games - Bingo", opened("games", "ns.GamesUI:Select('bingo')")),
    # the Bingo card mid-game: a complete row (with the slam settled), a diagonal one square away, who set squares
    # off, the race and the feed
    ("Games - Bingo card live", opened("games", "local d, me, now = ns.Games:GetData('bingo'), ns.Util.PlayerKey(), time() "
                                                "d.current = { id = 'cardlive', host = me, started = now - 3600, hits = {}, who = {} } "
                                                "d.view = { g = 'cardlive', hits = {}, lines = 1 } "
                                                "local card = ns.Bingo:GetMyCard() "
                                                "local who = { 'Victhar', 'Fazerblue', 'Lady Vashj', 'Saltykim', 'Dyrma' } "
                                                "for n, i in ipairs({ 11, 12, 14, 15, 1, 7, 19, 3, 22 }) do "
                                                "  d.current.hits[card[i]] = now - 600 + n * 30 d.view.hits[card[i]] = true "
                                                "  d.current.who[card[i]] = who[(n % #who) + 1] end "
                                                "ns.GamesUI:Select('bingo')")),
    ("Games - Raid Trainer", opened("games", "ns.GamesUI:Select('trainer')")),
    ("Games - Azeromon", opened("games", "ns.GamesUI:Select('azeromon')")),
    # the Games hub's carousel with each game in front; Bingo live (a game running: a line one square away, the
    # square that just filled glowing)
    ("Games - Raid Trainer in front", opened("games", "ns.GamesUI:ShowFront('trainer')")),
    ("Games - Azeromon in front", opened("games", "ns.GamesUI:ShowFront('azeromon')")),
    ("Games - Bingo live", opened("games", "local d, me, now = ns.Games:GetData('bingo'), ns.Util.PlayerKey(), time() "
                                           "d.current = { id = 'hubdemo', host = me, started = now, hits = {} } "
                                           "local card = ns.Bingo:GetMyCard() "
                                           "for _, i in ipairs({ 1, 7, 19, 3, 10, 22 }) do d.current.hits[card[i]] = now - 600 end "
                                           "d.current.hits[card[16]] = now "
                                           "ns.GamesUI:ShowFront('bingo')")),
    # the Dungeons tab (UI/DungeonsTab.lua) on demo mode's runs: up for a run as healer (the place that wants a healer
    # glows), Lower City only honored (Shadow Labyrinth heroic blocked); my own run with two asking to join; the List
    # a run sheet (a dungeon picked, and with a picked time); the ping; the empty board of a real guild
    ("Dungeons - board", demo(DR_ME + "ns.DungeonRuns:SetUp(true)", "dungeons")),
    ("Dungeons - your run", demo(DR_ME + "ns.DungeonRuns:List({ d = 'Botanica', h = true, role = 'healer' })",
                                 "dungeons")),
    ("Dungeons - list a run", demo(DR_ME + "ns.DungeonsUI:OpenSheet(); ns.DungeonsUI:SetSheet({ d = 'Botanica' })",
                                   "dungeons")),
    ("Dungeons - list a run - later", demo(DR_ME + "ns.DungeonsUI:OpenSheet(); ns.DungeonsUI:SetSheet({ "
                                       "d = 'ShatteredHalls', when = 'later', day = 3, mins = 20 * 60 + 30, "
                                       "no = 'Badge run, fast pulls' })", "dungeons")),
    ("Dungeons - ping", demo(DR_ME + "ns.MainFrame:Close(); ns.DungeonsUI:OnPing('demo-1')")),
    # my run in the Group Finder (made-up pugs in demo mode), the sheet's Group Finder switch, a run's invite pop-up
    ("Dungeons - your run in the Group Finder", demo(DR_ME + "ns.DungeonRuns:List({ d = 'Botanica', h = true, "
                                                     "role = 'healer' }); ns.GroupFinder:List(); "
                                                     "ns.DungeonsUI:Refresh()", "dungeons")),
    ("Dungeons - list a run - Group Finder", demo(DR_ME + "ns.DungeonsUI:OpenSheet(); ns.DungeonsUI:SetSheet({ "
                                                  "d = 'Steamvault', when = 'later', day = 1, mins = 21 * 60, "
                                                  "gf = true })", "dungeons")),
    ("Dungeons - invite", demo(DR_ME + "ns.MainFrame:Close(); "
                               "ns.DungeonsUI:OnInvite('demo-1', ns.DungeonRuns:GetRun('demo-1').o)")),
    ("Dungeons - listing left behind", demo(DR_ME + "ns.MainFrame:Close(); "
                                            "ns.DungeonsUI:OnFinderLeftover({ id = 'x', d = 'Botanica', h = true })")),
    ("Dungeons - empty", opened("dungeons")),
    # the Events tab (UI/EventsTab.lua) on demo mode's events: the live cup on the banner, the week and my season; a
    # planned event's page; last week's results; the library with a card hovered; the season; the review of my own
    # event; the sheets other modules open (host it, send it for review, the badge designer)
    ("Events - upcoming", demo("ns.EventsUI:Open('upcoming')", "events")),
    ("Events - event page", demo("ns.EventsUI:OpenEvent('odemo2')", "events")),
    ("Events - results", demo("ns.EventsUI:OpenEvent('rdemo1')", "events")),
    ("Events - library", demo("ns.EventsUI:Open('library'); ns.EventsUI:SetLibraryHover('edemo1')", "events")),
    ("Events - season", demo("ns.EventsUI:Open('season')", "events")),
    ("Events - review", demo("ns.EventsUI:Open('review'); ns.EventsUI:SelectReview('edemo3')", "events")),
    ("Events - schedule sheet", demo("ns.EventsUI:Open('library'); ns.EventsUI:OpenSchedule('edemo1'); "
                                     "ns.EventsUI:SetSchedule({ where = 'Ring of Trials, Nagrand' })", "events")),
    ("Events - submit", demo("ns.EventsUI:Open('library'); ns.EventsUI:OpenSubmit('edemo3')", "events")),
    ("Events - badge designer", demo("ns.EventsUI:Open('library'); ns.EventsUI:OpenBadgeDesigner("
                                     "ns.Events:GetDef('edemo1'), 'champ', function() end)", "events")),
    # part 2's kinds on the Events tab (dev/docs/EVENTS_KINDS.md): the hide and seek's page (tags, a play area, a Hint
    # button, its Always row), the fishing derby's page, the derby's results (its Fish table, the podium from it), a
    # hide and seek played to its end by the engine (two score tables, the tags at the end, its moments), the
    # library's examples menu, the review of a changed hide and seek (its definitions in plain rows)
    ("Events - hide and seek page", demo("ns.EventsUI:OpenEvent(ns.Events:Schedule('edemo3', GetServerTime() + 2 * "
                                         "86400 + 3600, { where = 'Terrace of Light, Shattrath' }))", "events")),
    ("Events - fishing derby page", demo("ns.EventsUI:OpenEvent('odemo4')", "events")),
    ("Events - results score chase", demo("ns.EventsUI:OpenEvent('rdemo3')", "events")),
    ("Events - results hide and seek", demo("""
        local E, Ev = ns.EventEngine, ns.Events
        local names, me = ns.Demo:GetMembers(), ns.Util.PlayerKey()
        local at = GetServerTime() - 2 * 86400
        local occ = Ev:Schedule('edemo3', at, { where = 'Terrace of Light, Shattrath', noJoin = true })
        local clock, keys, nop = at, { me }, function() end
        for i = 1, 7 do keys[#keys + 1] = names[i] end
        local run = E:New(Ev:GetOcc(occ).def, { id = occ, host = me, signups = keys, now = function() return clock end,
          out = { show = nop, tell = nop, guild = nop, sound = nop, plates = nop, log = nop } })
        run:Start()
        local function adv(n) for i = 1, n do clock = clock + 1; run:Tick() end end
        adv(181)
        local seeker, hiders = run:Tagged('tg2')[1], run:Tagged('tg1')
        for i = 1, 5 do adv(90 + i * 37); run:Touch(seeker, hiders[i], 'click') end
        adv(1300)
        Ev:SaveResult(occ, run, { me })
        ns.EventsUI:OpenEvent(occ)""", "events")),
    ("Events - library examples menu", demo("ns.EventsUI:Open('library'); "
                                            "ns.EventsUI:GetViewFrame('library').examples:Click()", "events")),
    ("Events - review changed definitions", demo("""
        local B, g = ns.EventBlocks, ns.Guild:GetGuildKey()
        local s = B.Copy(ns.Events:GetDef('edemo3'))
        s.tags.tg3.n, s.tags.tg3.c = 'Caught', 'grey'
        s.tags.tg4 = { n = 'Ghosts', c = 'teal', shown = 'self' }
        s.places.pc1.r = 400
        s.scores.sc2 = nil
        for _, sc in ipairs(s.scripts) do
          B:Walk(sc.top, function(p) if p.k == 'tm.start' and p.a[2] == 'Seek' then p.a[1] = 900 end end)
        end
        ns.db.eventSnaps = ns.db.eventSnaps or {}
        ns.db.eventSnaps[g] = ns.db.eventSnaps[g] or {}
        ns.db.eventSnaps[g].edemo3 = s
        ns.EventsUI:Open('review'); ns.EventsUI:SelectReview('edemo3')""", "events")),
    # the Share window (UI/ShareWindow.lua), dropped from the icon that opened it
    ("Share - raid", opened("raids", "ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:SelectRaid(...); "
                                     "ns.ShareWindow:Open('raid:' .. (...), "
                                     "ns.MainFrame:GetShareButton())")),
    ("Share - member", members_view("ns.MembersUI:ShowMember('Vaenyria-Thunderstrike'); "
                                    "ns.ShareWindow:Open('member:Vaenyria', ns.MembersUI:GetPanel().right.share)")),
    ("Share - window alone", opened("raids", "ns.MainFrame:Close(); ns.ShareWindow:Open('raid:' .. (...)); "
                                             "ns.ShareWindow:GetWindow().msg:SetText('Sign-ups close Wednesday!')")),
    # Settings (UI/Settings.lua): one section at a time, picked in the nav on the left
    ("Settings", opened("settings", "ns.SettingsUI:SelectSection('alerts')")),
    ("Settings - Group loot rules", opened("settings", "ns.SettingsUI:SelectSection('rules')")),
    ("Settings - Rolls", opened("settings", "ns.SettingsUI:SelectSection('rolls')")),
    ("Settings - Strategy boards", opened("settings", "ns.SettingsUI:SelectSection('strategy')")),
    ("Settings - Tooltips", opened("settings", "ns.SettingsUI:SelectSection('tooltips')")),
    ("Settings - Window", opened("settings", "ns.SettingsUI:SelectSection('window')")),
    ("Settings - Loot Council", opened("settings", "ns.SettingsUI:SelectSection('council')")),
    ("Settings - Demo mode", opened("settings", "ns.SettingsUI:SelectSection('demo')")),
    ("Settings - About", opened("settings", "ns.SettingsUI:SelectSection('about')")),
    ("Changelog", opened("changelog")),
    ("My Log: off", opened("mylog")),
    ("My Log: runs", opened("mylog", MYLOG_SEED)),
    ("My Log: healing", opened("mylog", MYLOG_SEED + " ns.MyLogUI:SetView('healing')")),
    ("My Log: demo runs", opened("mylog", "ns.Demo:SetEnabled(true)")),
    ("My Log: boss detail", opened("mylog", "ns.Demo:SetEnabled(true); ns.MyLogUI:Refresh(); ns.MyLogDetail:ShowBoss(ns.MyLogUI:GetBossRows()[3])")),
    ("My Log: boss tanking", opened("mylog", "ns.Demo:SetEnabled(true); ns.MyLogUI:Refresh(); ns.MyLogDetail:ShowBoss(ns.MyLogUI:GetBossRows()[6]); ns.MyLogUI:SetView('tanking')")),
    ("My Log: deaths", opened("mylog", "ns.Demo:SetEnabled(true); ns.MyLogUI:SetMode('deaths')")),
    ("My Log: deaths of one cause", opened("mylog", "ns.Demo:SetEnabled(true); ns.MyLogUI:SetMode('deaths'); ns.MyLogDetail:PickCause('37640')")),
    ("My Log: timeline", opened("mylog", "ns.Demo:SetEnabled(true); ns.MyLogUI:Refresh(); ns.MyLogDetail:ShowBoss(ns.MyLogUI:GetBossRows()[3]); local b = ns.MyLogDetail:GetViews(); b.modeSeg.buttons[2]:Click()")),
    ("Demo - Council - roster", demo("ns.CouncilUI:SetView('roster')", "council")),
    ("Demo - Council - items", demo("ns.CouncilUI:ShowBoss('Karazhan:Prince')", "council")),
    ("Demo - Council - member", demo("ns.CouncilUI:ShowMember('Aldrin-Thunderstrike')", "council")),
    ("Demo - Council - loot council", demo("ns.CouncilUI:ShowCouncil()", "council")),
    ("Demo - Council - loot log", demo("ns.CouncilUI:ShowLog()", "council")),
    # the Council restyle (2026-10-05): a boss many want (chips on two lines, "+N"), the unfolded "nobody wants"
    # items, a member page with awards, the guild card with unsaved edits, the raid card of a raid leader
    ("Demo - Council - items busy", demo("ns.CouncilUI:ShowBoss('Karazhan:Aran')", "council")),
    ("Demo - Council - items unfolded", demo(
        "ns.CouncilUI:ShowBoss('Karazhan:Prince'); "
        "for _, r in ipairs(DisasterZoneCouncilPanel.itemsView.list.box:GetFrames()) do "
        "if r.cdlData and r.cdlData.type == 'fold' then r:GetScript('OnClick')(r, 'LeftButton') break end end",
        "council")),
    ("Council - member with awards", opened("council", "ns.CouncilUI:ShowMember('Shadowmelder-Thunderstrike')")),
    # the member's gems and enchants on the read-only doll (a setup on every pick, from their guide)
    ("Council - member gems", opened("council", "local key, r; for _, k in ipairs(ns.Store:GetAllKeys()) do "
        "local x = ns.Store:Get(k) if not r and x and x.data and next(x.data.ph or {}) then key, r = k, x end end; "
        "r.data.ge = {}; local guide = ns.Gems:GuideFor(r.data); for p = 1, 5 do "
        "for sid, s in pairs(ns.ListPhase(r.data, p) or {}) do local e, g = ns.Gems:Suggest(s[1], sid, guide, p, {}); "
        "r.data.ge[s[1]] = e .. ':' .. table.concat(g, ':') end end; "
        "ns.CouncilUI:ShowMember(key)")),
    ("Council - Loot council - unsaved", opened("council", "ns.CouncilUI:ShowCouncil(); "
                                                           "ns.CouncilUI:ToggleCouncilDraft('guild', 'Victhar-Thunderstrike')")),
    ("Council - Loot council - raid leader", st_council_raid_leader),
    ("Council - roster - raid leader", st_council_roster_lock),
    ("Council - Loot council - officer", st_council_officer),
    ("Demo - Raid log - Players", demo("ns.RaidsUI:SetMode('players')", "raids")),
    # the selected logged raid's tabs (demo mode: raids with kills and awards)
    ("Demo - Raid log - Raids", demo("ns.RaidsUI:SetMode('raids'); ns.RaidsUI:SetLogTab('att')", "raids")),
    ("Demo - Raid log - Bosses", demo("ns.RaidsUI:SetMode('raids'); ns.RaidsUI:SetLogTab('boss')", "raids")),
    ("Demo - Raid log - Awards", demo("ns.RaidsUI:SetMode('raids'); ns.RaidsUI:SetLogTab('award')", "raids")),
    ("Demo - Start raid window", demo("ns.SessionBar:OpenStart()")),
    ("Demo - test drop panel", demo("ns.Loot:SimulateDrop()")),
    # in Grumpykat's raid: the group loot rules are his (read-only values, "Set by"), the raid's council
    ("Raid - Settings - Group loot rules (raider)", st_settings_in_raid("rules")),
    ("Raid - Settings - Loot Council (raider)", st_settings_in_raid("council")),
    ("Raid - session bar", st_session_bar),
    ("Raid - drop panel (council)", st_drop({"loot": True, "rolls": True, "lock": False})),
    ("Raid - drop panel (council, rolling)", st_drop({"loot": True, "rolls": True, "lock": False}, roll=True)),
    ("Raid - roll popup (raider)", st_drop({"loot": True, "rolls": True, "lock": False}, roll=True,
                                           viewer="Shadowmelder")),
    ("Raid - drop panel (plain, rolling)", st_drop({"loot": False, "rolls": True, "lock": False}, roll=True)),
    # the in-raid makeover's other drop panel states: rolls closed (Re-roll + Award to the suggested roller), the
    # award made (folded rolls), the plain roll panel before its roll
    ("Raid - drop panel (council, rolls closed)", st_drop({"loot": True, "rolls": True, "lock": False}, roll=True,
                                                          then="closed")),
    ("Raid - drop panel (council, awarded)", st_drop({"loot": True, "rolls": True, "lock": False}, roll=True,
                                                     then="awarded")),
    ("Raid - drop panel (plain)", st_drop({"loot": False, "rolls": True, "lock": False},
                                          item_lua="return ns.ItemDB:GetCandidates(1, { maxPhase = 1 })[2].itemID")),
    # Gina's own P1 head (the longest head name) rolled: her popup's BiS pill
    ("Raid - roll popup (BiS)", st_drop({"loot": True, "rolls": True, "lock": False}, roll=True,
                                        item_lua="return (ns.BiS:GetSlot(1, 1))")),
    ("Raid - Start raid window", st_start_window),
    ("Raid - Raids tab - Upcoming (leader)", st_raids_in_raid("ns.RaidsUI:SetView('upcoming')")),
    ("Raid - Raid log - Players (leader)", st_raids_in_raid("ns.RaidsUI:SetView('log'); ns.RaidsUI:SetMode('players')")),
    ("Raid - Raid log - Raids (leader)", st_raids_in_raid("ns.RaidsUI:SetView('log'); ns.RaidsUI:SetMode('raids')")),
    # last: its raids would show in every Raids view after it
    ("Home - calendar busy", lambda w, c: st_home_busy(w, c)),
]


def st_home_busy(w, c):
    """Home with a busy calendar: two raids on one day (the picked one), a title too long for one line, a raid Gina
    was taken off, more raids later (Coming up + "n more"), and the logged Karazhan raid in the past."""
    g, k = c["Gina"], c["Grumpykat"]
    demo_off(w, c)
    close_all(g)
    t0 = now(k)
    a = create(k, i="mag", t=t0 + 5 * DAY, ti="Spark run - Maggy & Gruul")
    b = create(k, i="ssc", t=t0 + 5 * DAY + 3600, ti="Spark run - SSC (continued)")
    long = create(k, i="kara", t=t0 + 6 * DAY, ti="T3 Wrong note: Pushups at door")
    create(k, i="kara", t=t0 + 6 * DAY + 1800, ti="T1 Cat Aggro: Karazhan")
    create(k, i="tk", t=t0 + 13 * DAY, ti="TK first look")
    create(k, i="gruul", t=t0 + 20 * DAY, ti="Gruul + Mag")
    w.tick(2)
    signup(g, a, "A")
    signup(g, b, "T")
    k.eval("ns.RaidPlan:DeclineSignup(...)", long, K("Gina"))
    w.tick(3)
    tab(g, "home")
    w.tick(0.3)
    g.eval("local v = ns.RaidPlan:GetRaid(...); local key = tonumber(date('%Y%m%d', v.t)); "
           "for _, c in ipairs(ns.Dashboard:GetPanel().calCard.cells) do "
           "if c.key == key then c:GetScript('OnClick')(c) end end", a)
    return g


# ---------------------------------------------------------------------------------------------------------------
# Raids > Teams (the makeover, dev/art/casc/teams_mockup): a 25-player main team with specs and groups, an alt team
# and a 10-man team, raids that invite the main team. Last in the list: the extra guild members and raids would show
# in every view after them.
# ---------------------------------------------------------------------------------------------------------------
TEAMS = {}
# name, class, spec index (None: automatic), group (None: not in a group); online members keep their class
TEAMS_MAIN = (("Victhar", "WARRIOR", 3, 1), ("Caelith", "PALADIN", 2, 1), ("Moonwhisper", "DRUID", 3, 1),
              ("Brakka", "WARRIOR", 2, 1), ("Lorvane", "SHAMAN", 2, 1), ("Shadowmelder", "ROGUE", 2, 2),
              ("Vexis", "ROGUE", 2, 2), ("Rhosyn", "DRUID", 2, 2), ("Stormfist", "SHAMAN", 2, 2),
              ("Sunniva", "PALADIN", 3, 2), ("Grumpykat", "WARLOCK", 3, 3), ("Morrigan", "WARLOCK", 1, 3),
              ("Nyxa", "PRIEST", 3, 3), ("Ashka", "SHAMAN", 1, 3), ("Quillon", "DRUID", 1, 3),
              ("Frostweaver", "MAGE", 3, 4), ("Kaelwyn", "MAGE", 1, 4), ("Embera", "MAGE", 2, 4),
              ("Faelar", "HUNTER", 2, 4), ("Gina", "PALADIN", 1, 5), ("Lightbringer", "PRIEST", None, 5),
              ("Thunderhoofx", "SHAMAN", 3, 5), ("Isolde", "PRIEST", 1, 5), ("Kaelyn", "SHAMAN", 3, None),
              ("Rowanne", "DRUID", 4, None))
TEAMS_KARA = (("Caelith", 2, 1), ("Brakka", 2, 1), ("Rhosyn", 2, 1), ("Stormfist", 2, 1), ("Vexis", 2, 1),
              ("Gina", 1, 2), ("Rowanne", None, 2), ("Embera", 2, 2), ("Ashka", 1, 2), ("Morrigan", 1, 2),
              ("Dornak", 3, None), ("Elowen", 2, None))
TEAMS_EXTRA = (("Caelith", "PALADIN"), ("Dornak", "WARRIOR"), ("Isolde", "PRIEST"), ("Kaelyn", "SHAMAN"),
               ("Rowanne", "DRUID"), ("Elowen", "PRIEST"), ("Brakka", "WARRIOR"), ("Lorvane", "SHAMAN"),
               ("Vexis", "ROGUE"), ("Rhosyn", "DRUID"), ("Stormfist", "SHAMAN"), ("Sunniva", "PALADIN"),
               ("Morrigan", "WARLOCK"), ("Nyxa", "PRIEST"), ("Ashka", "SHAMAN"), ("Quillon", "DRUID"),
               ("Kaelwyn", "MAGE"), ("Embera", "MAGE"), ("Faelar", "HUNTER"))

SAVE_TEAM = ("local id, n, m, sz, s, g = ...; local ok, r = ns.RaidPlan:SaveTeam(id, n, m, { size = sz, specs = s, "
             "groups = g }); return { ok = ok, r = r }")


def teams_seed(w, c):
    if TEAMS.get("done"):
        return
    TEAMS["done"] = True
    k = c["Grumpykat"]
    for name, cls in TEAMS_EXTRA:
        w.add_offline_member(name, class_file=cls, rank=3)
    w.tick(3)
    main = [K(n) for n, _, _, _ in TEAMS_MAIN]
    specs = {K(n): sp for n, _, sp, _ in TEAMS_MAIN if sp}
    groups = {K(n): g for n, _, _, g in TEAMS_MAIN if g}
    res = k.eval_py(SAVE_TEAM, IDS["team"], "Main team (Thu + Sun nights)", main, 25, specs, groups)
    assert res["ok"] is True, res
    # 1.3.2: its 25 named, a second lineup (Kara A, 10) of the same roster; three players on the 25's waitlist
    res = k.eval_py("local id, g = ...; local t = ns.RaidPlan:GetTeam(id); local L = {}; for i, l in ipairs(t.lineups) do "
                    "L[i] = { id = l.id, name = l.name, size = l.size, specs = l.specs, groups = l.groups, "
                    "seats = l.seats, comp = l.comp } end; L[1].name = 'Thursday 25'; "
                    "L[#L + 1] = { name = 'Kara A', size = 10, groups = g }; "
                    "local ok, r = ns.RaidPlan:SaveTeam(id, t.name, t.members, { lineups = L }); return { ok = ok, r = r }",
                    IDS["team"], {K("Victhar"): 1, K("Caelith"): 1, K("Moonwhisper"): 1, K("Shadowmelder"): 2,
                                  K("Gina"): 2})
    assert res["ok"] is True, res
    w.tick(2)
    res = c["Vaenyria"].eval_py("local ok, e = ns.RaidPlan:JoinWaitlist(..., '1', 2); return { ok = ok, e = e }",
                                IDS["team"])
    assert res["ok"] is True, res
    w.tick(2)
    # (two players without a client, as received earlier: on Gina's screen only)
    c["Gina"].eval("local id, a, b = ...; local r = ns.db.raidplan[ns.Guild:GetGuildKey()]; local t = GetServerTime(); "
                   "r.W[id]['1'][a] = { rev = t, by = a, at = t, sp = 3 }; r.W[id]['1'][b] = { rev = t, by = b, at = t }",
                   IDS["team"], K("Dornak"), K("Elowen"))
    alt = [K(n) for n in ("Vaenyria", "Dornak", "Elowen", "Kaelyn", "Faelar", "Isolde", "Nyxa", "Brakka")]
    res = k.eval_py(SAVE_TEAM, None, "Alt team", alt, 25, {}, {})
    assert res["ok"] is True, res
    kara = [K(n) for n, _, _ in TEAMS_KARA]
    res = k.eval_py(SAVE_TEAM, None, "Kara B", kara, 10, {K(n): sp for n, sp, _ in TEAMS_KARA if sp},
                    {K(n): g for n, _, g in TEAMS_KARA if g})
    assert res["ok"] is True, res
    TEAMS["kara"] = res["r"]
    w.tick(2)
    t0 = now(k)
    TEAMS["ssc"] = create(k, i="ssc", t=t0 + 2 * DAY, tm=[IDS["team"]], lk=True)
    TEAMS["mag"] = create(k, i="mag", t=t0 + 5 * DAY, tm=[IDS["team"]])
    create(k, i="gruul", t=t0 + 12 * DAY, tm=[IDS["team"]])
    w.tick(2)
    for n, sp in (("Lightbringer", 2), ("Victhar", 3), ("Shadowmelder", 2), ("Thunderhoofx", 3), ("Moonwhisper", 3),
                  ("Frostweaver", 3), ("Grumpykat", 3), ("Gina", 1), ("Vaenyria", 2)):
        signup(c[n], TEAMS["ssc"], "A", sp)
    for n, st in (("Victhar", "A"), ("Gina", "A"), ("Grumpykat", "T"), ("Vaenyria", "A")):
        signup(c[n], TEAMS["mag"], st)
    w.tick(3)


def teams_comp(w, c, on):
    """The main team's target comp: Standard 25 (on) or none."""
    k = c["Grumpykat"]
    has = k.eval("return ns.RaidPlan:GetTeamComp(...) ~= nil", IDS["team"])
    if has == on:
        return
    res = k.eval_py("local id, on = ...; local cp = on and ns.RaidComp:GetPreset('std25').cp or false; "
                    "local ok, r = ns.RaidPlan:SetTeamComp(id, cp); return { ok = ok, r = r }", IDS["team"], on)
    assert res["ok"] is True, res
    w.tick(2)


def teams_view(viewer="Gina", lua=None, no_teams=False, party=False, comp=False, view="groups"):
    """Raids > Teams on `viewer`'s screen after the seed; lua runs on the open view (... = main team, Kara B).
    no_teams: the view as a guild without teams shows it (GetTeams answers nothing on that client); party: Gina in a
    party with Vaenyria and Dornak (Add several); comp: the main team has a target comp; view: "groups" | "comp"."""
    def fn(w, c):
        teams_seed(w, c)
        demo_off(w, c)
        teams_comp(w, c, comp)
        if w.group:
            w.disband()
            w.tick(0.5)
        if party:
            w.make_party([c["Gina"], c["Vaenyria"]], extra_members=("Dornak",))
            w.tick(0.5)
        for cl in (c["Gina"], c["Lightbringer"]):
            # back to the saved teams and no popups from the state before
            cl.eval("local RP = ns.RaidPlan; if RP.__GetTeams then RP.GetTeams, RP.__GetTeams = RP.__GetTeams, nil end; "
                    "if ns.RaidPlanUI.DiscardDraft then ns.RaidPlanUI:DiscardDraft() end")
            close_all(cl)
            cl.eval("StaticPopup_HideAll()")
        v = c[viewer]
        if no_teams:
            v.eval("local RP = ns.RaidPlan; RP.__GetTeams = RP.GetTeams; RP.GetTeams = function() return {} end")
        tab(v, "raids")
        w.tick(0.3)
        v.eval("ns.RaidsUI:SetView('teams')")
        if not no_teams:
            v.eval("ns.RaidPlanUI:SelectTeam(...)", IDS["team"])
        if v.eval("return ns.RaidPlanUI.SetTeamTab ~= nil"):
            v.eval("ns.RaidPlanUI:SetTeamTab(...)", view)
        w.tick(0.3)
        if lua:
            v.eval(lua, IDS["team"], TEAMS.get("kara"))
            w.tick(0.3)
        return v
    return fn


def teams_raid(tab_key, comp=True):
    """The main team's Serpentshrine raid (it invites the team) on Gina's screen: its Sign-ups or Groups tab."""
    def fn(w, c):
        teams_seed(w, c)
        demo_off(w, c)
        teams_comp(w, c, comp)
        g = c["Gina"]
        g.eval("if ns.RaidPlanUI.DiscardDraft then ns.RaidPlanUI:DiscardDraft() end")
        close_all(g)
        g.eval("StaticPopup_HideAll()")
        tab(g, "raids")
        w.tick(0.3)
        g.eval("ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:SelectRaid(...); ns.RaidPlanUI:SetDetailTab(select(2, ...))",
               TEAMS["ssc"], tab_key)
        w.tick(0.3)
        return g
    return fn


# (before "Home - calendar busy": it stays last)
_HOME = next(i for i, st in enumerate(STATES) if st[0] == "Home - calendar busy")
STATES[_HOME:_HOME] = [
    ("Raids - Teams - board", teams_view(lua="ns.RaidPlanUI:ShowTeamBoard()")),
    ("Raids - Teams - board (member)", teams_view("Lightbringer", comp=True, lua="ns.RaidPlanUI:ShowTeamBoard()")),
    ("Raids - Teams (member)", teams_view("Lightbringer")),
    ("Raids - Teams - organizer", teams_view()),
    # Faelar into group 4, Quillon out of group 3: changed, not saved
    ("Raids - Teams - organizer dirty", teams_view(lua="local g = ns.RaidPlanUI:GetTeamGrid(); "
                                                     "g:Drop('Faelar-Thunderstrike', nil); g:Drop('Quillon-Thunderstrike', nil); "
                                                     "g:Drop('Faelar-Thunderstrike', 4)")),
    ("Raids - Teams - add members", teams_view(lua="ns.RaidsUI:GetPanel().teams.picker:Open()", party=True)),
    ("Raids - Teams - 10-man", teams_view(lua="ns.RaidPlanUI:SelectTeam(select(2, ...))")),
    ("Raids - Teams - new team", teams_view(lua="ns.RaidPlanUI:NewTeam()")),
    ("Raids - Teams - no teams (organizer)", teams_view(no_teams=True)),
    ("Raids - Teams - no teams (member)", teams_view("Lightbringer", no_teams=True)),
    ("Raids - Teams - member, not on the team", teams_view("Lightbringer", lua="ns.RaidPlanUI:SelectTeam(select(2, ...))")),
    # the target comp (Standard 25 on the main team): the card's meter and Needs, the Comp view, the steppers, the
    # empty card, the members' read-only view, the open slots of a raid that invites the team, its Groups strip
    ("Raids - Teams - comp card (member)", teams_view("Lightbringer", comp=True)),
    ("Raids - Teams - comp groups", teams_view(comp=True)),
    ("Raids - Teams - comp", teams_view(comp=True, view="comp")),
    ("Raids - Teams - comp steppers", teams_view(comp=True, view="comp", lua=(
        "local d = ns.RaidsUI:GetPanel().teams.detail; local a = d.cols[2].add; a:GetScript('OnClick')(a, 'LeftButton'); "
        "local r = ns.RaidPlanUI:GetCompSteps().rows[1]; r.minus:GetScript('OnClick')(r.minus, 'LeftButton')"))),
    ("Raids - Teams - comp empty", teams_view(view="comp")),
    ("Raids - Teams - comp (member)", teams_view("Lightbringer", comp=True, view="comp")),
    # lineups and the waitlist (1.3.2): the second lineup open, the view of a player who isn't on the roster
    ("Raids - Teams - lineup Kara A", teams_view(lua="ns.RaidPlanUI:SelectLineup(2)")),
    ("Raids - Teams - waitlist (not on the roster)", teams_view("Vaenyria")),
    # the waitlist as an icon (2026-10-08): its dropdown open for an organizer, and for a player in line
    ("Raids - Teams - waitlist open", teams_view(lua="local b = ns.RaidsUI:GetPanel().teams.detail.wlBtn; "
                                                 "b:GetScript('OnClick')(b)")),
    ("Raids - Teams - waitlist open (in line)", teams_view("Vaenyria", lua="local b = ns.RaidsUI:GetPanel().teams.detail.wlBtn; "
                                                                        "b:GetScript('OnClick')(b)")),
    ("Raids - Upcoming - SSC sign-ups (comp)", teams_raid("signups")),
    ("Raids - Upcoming - SSC groups (comp)", teams_raid("groups")),
]


# ---------------------------------------------------------------------------------------------------------------
# Events: the live board, the host's board, the tracker, the match card, the result prompts (UI/EventBoard.lua,
# UI/EventTracker.lua; dev/art/casc/events_mockup shots 7-10). The board: demo mode's live cup on Gina's screen.
# The rest: Grumpykat hosts the starter cup with seven members (Gina stays out of it: her screen is the other
# views'), and the states play it on one after the other (a dispute, a match starting, a game counted, an ask).
# ---------------------------------------------------------------------------------------------------------------
EV = {}
EV_PLAYERS = ("Victhar", "Shadowmelder", "Vaenyria", "Thunderhoofx", "Moonwhisper", "Lightbringer", "Frostweaver")


def ev_duel(w, c, winner, loser, only=None):
    """The duelists' clients see the duel end (only: just that one's)."""
    text = "%s has defeated %s in a duel" % (winner, loser)
    for n in ([only] if only else (winner, loser)):
        c[n].fire("CHAT_MSG_SYSTEM", text)
    w.tick(1)


def ev_matches(k, occ):
    """The host's current round: [(a, b, state)] with short names."""
    return k.eval_py("""
        local st = ns.EventLive:GetState(...)
        local bk = ns.EventEngine:BracketOf(ns.EventLive:GetDef(...), st)
        local out = {}
        for _, mid in ipairs(bk and bk.rounds[bk.r] or {}) do
          local m = bk.m[mid]
          out[#out + 1] = { (tostring(m.a):gsub('%-.*', '')), (tostring(m.b):gsub('%-.*', '')), m.st }
        end
        return out""", occ) or []


def ev_seed(w, c):
    """Grumpykat's cup, started; who plays whom read from the draw (EV: host's opponent, the disputed pair, the
    first waiting pair)."""
    if EV.get("occ"):
        return EV["occ"]
    k = c["Grumpykat"]
    occ = k.eval_py("local d = ns.Events:NewDef(true); assert(ns.Events:SaveDef(d)); "
                    "return ns.Events:Schedule(d.id, GetServerTime() + 30, { where = 'Ring of Trials, Nagrand' })")
    w.tick(3)
    for n in EV_PLAYERS:
        c[n].eval("ns.Events:SignUp(..., true)", occ)
    w.tick(3)
    res = k.eval_py("return { ns.EventLive:Start(...) }", occ)
    assert res[0] is True, res
    w.tick(3)
    EV["occ"] = occ
    ms = ev_matches(k, occ)
    play = [m for m in ms if m[2] == "play"]
    mine = [m for m in play if "Grumpykat" in m[:2]]
    other = [m for m in play if "Grumpykat" not in m[:2]]
    waiting = [m for m in ms if m[2] == "wait"]
    assert mine and other and waiting, ms
    EV["kopp"] = mine[0][1] if mine[0][0] == "Grumpykat" else mine[0][0]
    EV["disp"] = other[0][:2]
    EV["next"] = waiting[0][:2]
    return occ


def ev_board_host(w, c):
    """Grumpykat's board: his match 1-0, a dispute (both players of the other match say they won game 1)."""
    occ = ev_seed(w, c)
    k = c["Grumpykat"]
    a, b = EV["disp"]
    if not EV.get("disputed"):
        EV["disputed"] = True
        ev_duel(w, c, "Grumpykat", EV["kopp"])
        ev_duel(w, c, a, b, only=a)
        w.tick(12)
        ask = c[a].eval_py("local a = ns.EventLive:MyAsk(...); return a and a.id", occ)
        if ask:
            c[a].eval("ns.EventLive:AnswerAsk(...)", occ, ask, K(a))
            c[b].eval("ns.EventLive:AnswerAsk(...)", occ, ask, K(b))
        w.tick(3)
    close_all(k)
    k.eval("ns.EventBoard:Open(...)", occ)
    return k


def ev_tracker(w, c):
    """The tracker of a player whose quarterfinal waits for the ones being played."""
    occ = ev_seed(w, c)
    v = c[EV["next"][0]]
    close_all(v)
    v.eval("ns.EventTracker:Refresh()")
    return v


def ev_match_card(w, c):
    """Grumpykat settles the dispute (game 1 to its first player) and takes his match 2-0: the waiting quarterfinal
    starts (its first player's card, the raid warning)."""
    occ = ev_seed(w, c)
    k = c["Grumpykat"]
    p1, p2 = EV["next"]
    v = c[p1]
    if not EV.get("started"):
        EV["started"] = True
        ask = k.eval_py("local a = ns.EventLive:MyAsk(...); return a and a.id", occ)
        if ask:
            k.eval("ns.EventLive:HostAnswer(...)", occ, ask, K(EV["disp"][0]))
        ev_duel(w, c, "Grumpykat", EV["kopp"])
        w.tick(3)
        k.eval("ns.EventBoard:Close()")
    close_all(v)
    v.eval("""
        local T, L = ns.EventTracker, ns.EventLive
        local occ, text = ...
        T:Refresh()
        local m, bk, st = L:MyMatch(occ)
        if m and m.st == 'play' then T:ShowMatchCard(occ, st, L:GetDef(occ), bk, m) end
        -- the raid warning as the addon draws it where the game has no raid warning frame
        local add = RaidNotice_AddMessage
        RaidNotice_AddMessage = nil
        T:Announce(text)
        RaidNotice_AddMessage = add""", occ, "Quarterfinal: %s vs %s" % (p1, p2))
    return v


def ev_prompts(w, c):
    """The disputed match's first player (1-0 up, the host's call): only the opponent's game saw game 2, so both are
    asked; with the toast of game 1 and the wait card for the look (the three prompts stacked)."""
    occ = ev_seed(w, c)
    a, b = EV["disp"]
    va = c[a]
    if not EV.get("asked"):
        EV["asked"] = True
        ev_duel(w, c, b, a, only=b)
        w.tick(12)
    close_all(va)
    va.eval("""
        local T, L = ns.EventTracker, ns.EventLive
        local occ = ...
        T:Refresh()
        local m, bk, st = L:MyMatch(occ)
        if m then
          T:ShowWait(occ, st, bk, m)
          T:ShowGameToast(occ, bk, m, true, 'host')
        end""", occ)
    return va

def ev_builder(lua, by=None):
    """The event builder on Gina's screen with a fresh Friday duel cup (saved; `by`: someone else's, read-only), then
    `lua` (... = the event's id)."""
    def fn(w, c):
        g = c["Gina"]
        demo_off(w, c)
        close_all(g)
        def_id = g.eval("local d = ns.Events:NewDef(true); local by = ...; if by then d.by = by; d.name = 'Duel cup' "
                        "else ns.Events:SaveDef(d) end; T_EV_DEF = d; return d.id", by and K(by))
        g.eval("ns.EventBuilder:Open(ns.Events:GetDef(...) or T_EV_DEF, { stage = 's2' })", def_id)
        w.tick(0.3)
        if lua:
            g.eval(lua, def_id)
            w.tick(0.5)
        return g
    return fn


# the canvas' blank the whisper of "when a match starts" asks for (emptied first), and the picker on it
EV_PICKER = """
    ns.EventBuilder:SelectStage('*')
    local S, ui = ns.EventBuilder:GetState()
    local s
    for _, x in ipairs(S.def.scripts) do if x.id == 'c3' then s = x end end
    s.top.n.a[1] = nil
    ns.EventBuilder:Refresh()
    local f = ui.scripts[s]
    local anchor
    for _, bl in ipairs(f.blanks) do if bl.piece.k == 'ch.wh' and bl.slot == 1 then anchor = bl.frame end end
    ns.EventBuilder:OpenPicker(s, s.top.n, 1, ns.EventBlocks.PIECES['ch.wh'].args[1], anchor)"""

EV_PRACTICE = """
    ns.EventBuilder:SelectStage('s1')
    ns.EventBuilder:StartPractice()
    for i = 1, 3 do ns.EventLive:PracticeSkip() end
    local run = ns.EventLive:GetPractice()
    local bk = run:MainBracket()
    local n = 0
    for _, mid in ipairs(bk.rounds[bk.r] or {}) do
      local m = bk.m[mid]
      if m.st == 'play' and n < 3 then n = n + 1; ns.EventLive:PracticeDuel(m.a, m.b) end
    end
    ns.EventLive:PracticeOffline(run.st.entrants[5], true)
    ns.EventBuilder:Refresh()"""

# (before "Home - calendar busy": it stays last)
_HOME_EV = next(i for i, st in enumerate(STATES) if st[0] == "Home - calendar busy")
STATES[_HOME_EV:_HOME_EV] = [
    ("Events - board", demo("ns.EventBoard:Open('odemo1')")),
    ("Events - board host", ev_board_host),
    ("Events - tracker", ev_tracker),
    ("Events - match card", ev_match_card),
    ("Events - prompts", ev_prompts),
    ("Events - builder", ev_builder(None)),
    ("Events - builder always", ev_builder("ns.EventBuilder:SelectStage('*')")),
    ("Events - builder picker", ev_builder(EV_PICKER)),
    ("Events - builder inside", ev_builder("ns.EventBuilder:OpenInside('b2')")),
    ("Events - builder practice", ev_builder(EV_PRACTICE)),
    ("Events - builder read-only", ev_builder(None, by="Victhar")),
    ("Events - builder empty stage", ev_builder("ns.EventBuilder:AddStage(); local S, ui = "
                                                "ns.EventBuilder:GetState(); ui.ask.field:SetText('Bonus round'); "
                                                "ui.ask:Done()")),
    ("Events - builder zoomed out", ev_builder("ns.EventBuilder:SelectStage('*'); "
                                               "ns.EventBuilder:ZoomTo(0.67, nil, nil, true)")),
]

# Events part 2 on screen (UI/EventBoard.lua, UI/EventTracker.lua; mockup shots 20-24): demo mode's boards (hide and
# seek, a race, a fishing derby) and the tracker of the first; the ask prompts, a result, a banner and the yes / no
# card from practice runs that ask Gina (their host) themselves.
EV2_ASKS = """
    local B = ns.EventBlocks
    local N, C, J = B.Build.N, B.Build.C, B.Build.J
    local d = B:Example('tmog')
    d.asks.ak4 = { n = 'Answer', q = "Which boss drops the Ashes of Al'ar?", kind = 'text', from = 'entrants', time = 30 }
    d.scripts = { d.scripts[1] }
    local function S(id, top) d.scripts[#d.scripts + 1] = { id = id, st = 's2', x = 0, y = 0, top = top } end
    S('x1', B:Stack(N('ev.start'), N('as.ask', N('pl.all'), 'ak3')))
    S('x2', B:Stack(N('ev.start'), N('as.ask', N('pl.host'), 'ak4')))
    S('x3', B:Stack(N('ev.start'), N('as.askq', N('pl.host'), 'ak2', J("Score Dummy 2's outfit, 1 to 10"))))
    ns.EventLive:StartPractice(d, 6)"""
EV2_ME_TOO = """
    local run = ns.EventLive:GetPractice()
    run.st.qa.ak3.who[ns.Util.PlayerKey()] = true
    ns.EventTracker:Refresh()
    local f
    for _, x in ipairs(ns.EventTracker:GetFrames().asks) do if x.kind == 'player' then f = x end end
    f.tiles[1]:Click(); f.tiles[3]:Click()"""
EV2_SENT = EV2_ME_TOO + """
    f.tiles[2]:Click(); f.send:Click()
    for _, x in ipairs(ns.EventTracker:GetFrames().asks) do x:Hide() end"""
EV2_YESNO = """
    local B = ns.EventBlocks
    local N, J = B.Build.N, B.Build.J
    local d = B:Example('hide')
    d.asks = { ak1 = { n = 'Round two', q = 'Same teams for round 2?', kind = 'yesno', from = 'entrants', time = 20 } }
    local function S(id, top) d.scripts[#d.scripts + 1] = { id = id, st = 's2', x = 0, y = 0, top = top } end
    S('y1', B:Stack(N('ev.start'), N('as.ask', N('pl.host'), 'ak1')))
    S('y2', B:Stack(N('ev.start'), N('ch.show', N('pl.host'), J('Hide in the play area! The seekers come in 3 minutes.'))))
    ns.EventLive:StartPractice(d, 6)"""


def ev2_practice(start, after=None, wait=0.0):
    def fn(w, c):
        g = c["Gina"]
        demo_off(w, c)
        close_all(g)
        g.eval(start)
        w.tick(1.5)
        if after:
            g.eval(after)
            w.tick(0.3 + wait)
        return g
    return fn


_EV2 = next(i for i, st in enumerate(STATES) if st[0] == "Home - calendar busy")
STATES[_EV2:_EV2] = [
    ("Events - board hide and seek", demo("ns.EventBoard:OpenDemo('kdemo-hide')")),
    ("Events - board race", demo("ns.EventBoard:OpenDemo('kdemo-race')")),
    ("Events - board fishing derby", demo("ns.EventBoard:OpenDemo('kdemo-fish')")),
    ("Events - tracker hide and seek", demo("ns.EventBoard:OpenDemo('kdemo-hide'); ns.EventBoard:Close(); "
                                            "ns.EventTracker:Refresh()")),
    ("Events - tracker race", demo("ns.EventBoard:OpenDemo('kdemo-race'); ns.EventBoard:Close(); "
                                   "ns.EventTracker:Refresh()")),
    ("Events - tracker fishing derby", demo("ns.EventBoard:OpenDemo('kdemo-fish'); ns.EventBoard:Close(); "
                                            "ns.EventTracker:Refresh()")),
    ("Events - board sign-up with places", ev2_practice("ns.EventLive:StartPractice(ns.EventBlocks:Example('redlight'), 8); "
                                                        "ns.EventBoard:Open('practice')")),
    ("Events - ask prompts", ev2_practice(EV2_ASKS, EV2_ME_TOO)),
    ("Events - ask result", ev2_practice(EV2_ASKS, EV2_SENT, 9)),
    ("Events - banner and yes or no", ev2_practice(EV2_YESNO)),
]

# Events part 2 in the builder (UI/EventBuilder.lua, UI/EventPieces.lua; mockup shots 17-19, 25): each category's
# definitions in the palette, their editors, the questions sheet, places (the Add menu, the picker, the card, the map
# sheet with Nagrand's art), the Matches card won by the pieces, "Start from an example", practice with the new facts.
EVB_MAPART = r'''
local ZN = { [1951] = "Nagrand", [1952] = "TerokkarForest", [1955] = "ShattrathCity" }
local oL, oT = C_Map.GetMapArtLayers, C_Map.GetMapArtLayerTextures
C_Map.GetMapArtLayers = function(id)
  if ZN[id] then return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256, minScale = 1, maxScale = 1 } } end
  return oL(id)
end
C_Map.GetMapArtLayerTextures = function(id, l)
  if ZN[id] then local t = {}; for i = 1, 12 do t[i] = "Interface\\WorldMap\\" .. ZN[id] .. "\\" .. ZN[id] .. i end; return t end
  return oT(id, l)
end'''
EVB_PLACES = """
    local d = ns.EventBuilder:GetState().def
    ns.EventBlocks:NewDefinition(d, 'places', { n = 'Meeting spot', map = 1951, x = 0.555, y = 0.37, r = 40, z = 'Nagrand', sz = 'Garadar' })
    ns.EventBlocks:NewDefinition(d, 'places', { n = 'Halaa town', map = 1951, x = 0.42, y = 0.452, r = 90, z = 'Nagrand', sz = 'Halaa' })
    ns.EventBuilder:Refresh()"""
EVB_PICK = """
    ns.EventBuilder:SelectStage('*')
    local S, ui = ns.EventBuilder:GetState()
    local s
    for _, x in ipairs(S.def.scripts) do if x.st == '*' and x.top.k == 'pc.leave' then s = x end end
    s.x, s.y, s.top.a[1] = 20, 20, nil
    ns.EventBuilder:Refresh()
    local bf
    for _, bl in ipairs(ui.scripts[s].blanks) do if bl.piece == s.top and bl.slot == 1 then bf = bl.frame end end
    bf:Click()"""
EVB_CARD = """
    local S, ui = ns.EventBuilder:GetState()
    local s
    for _, x in ipairs(S.def.scripts) do if x.id == 'h2' then s = x end end
    for _, bl in ipairs(ui.scripts[s].blanks) do
      if bl.piece.k == 'pc.point' and bl.slot == 2 then bl.frame:GetScript('OnEnter')(bl.frame) end
    end"""
EVB_PICKER = """
    ns.EventBuilder:SelectStage('*')
    local S, ui = ns.EventBuilder:GetState()
    local s
    for _, x in ipairs(S.def.scripts) do if x.id == 'c3' then s = x end end
    s.top.n.a[1] = nil
    ns.EventBuilder:Refresh()
    for _, bl in ipairs(ui.scripts[s].blanks) do if bl.piece.k == 'ch.show' and bl.slot == 1 then bl.frame:Click() end end"""


def evb(key, stage="s1", cat=None, lua=None, art=False, stand=False):
    """The builder with an example (B:Examples' key; None: a new event) on a stage, the palette on cat, then lua (with
    the renders' real geometry: the popovers place themselves by it)."""
    def fn(w, c):
        g = c["Gina"]
        demo_off(w, c)
        close_all(g)
        if stand:
            w.set_position("Gina", 1951, 0.345, 0.385, subzone="Halaa")
        if art:
            g.eval(EVB_MAPART)
        g.eval("local key, stage, cat = ...; local d = ns.Events:NewDef(false); if key then local ex = "
               "ns.EventBlocks:Example(key); for k, v in pairs(ex) do d[k] = v end; ns.Events:SaveDef(d) end; "
               "ns.EventBuilder:Open(key and ns.Events:GetDef(d.id) or nil, { stage = stage }); local S = "
               "ns.EventBuilder:GetState(); S.cat = cat or S.cat; ns.EventBuilder:Refresh()", key, stage, cat)
        w.tick(0.3)
        if lua:
            g.eval("__MOCK.real_geometry = true")
            g.eval(lua)
            w.tick(0.5)
        return g
    return fn


_EVB = next(i for i, st in enumerate(STATES) if st[0] == "Home - calendar busy")
STATES[_EVB:_EVB] = [
    ("Events - builder players", evb("hide", "s3", "pl")),
    ("Events - builder tag editor", evb("hide", "s3", "pl", "ns.EventBuilder.Defs:Open('tags', 'tg3')")),
    ("Events - builder score editor", evb("race", "s2", "pt", "ns.EventBuilder.Defs:Open('scores', 'sc1')")),
    ("Events - builder ask editor", evb("tmog", "s4", "as", "ns.EventBuilder.Defs:Open('asks', 'ak3')")),
    ("Events - builder ask choices", evb("tmog", "s4", "as", "ns.EventBlocks:NewDefinition(ns.EventBuilder:GetState().def, "
                                     "'asks', { n = 'Theme', q = 'Which theme next week?', kind = 'choice', choices = "
                                     "{ 'Pirates', 'Undead', 'Night elves', 'Holiday' }, votes = 2 }); "
                                     "ns.EventBuilder:Refresh(); ns.EventBuilder.Defs:Open('asks', 'ak4')")),
    ("Events - builder new ask", evb("tmog", "s4", "as", "local S, ui = ns.EventBuilder:GetState(); "
                                 "ui.pal.rowOf['add:asks']:Click()")),
    ("Events - builder list editor", evb("race", "s2", "lo", "ns.EventBuilder.Defs:Open('lists', 'ls1')")),
    ("Events - builder questions", evb("quiz", "s2", "lo", "ns.EventBuilder.QSheet:Open('ls1'); "
                                   "ns.EventBuilder.QSheet.cur.sel = 4; ns.EventBuilder.QSheet:Render()")),
    ("Events - builder places", evb("hide", "s3", "pc", EVB_PLACES + "; local S, ui = ns.EventBuilder:GetState(); "
                                "ns.EventBuilder.Defs:AddPlaceMenu(ui.pal.rowOf['add:places'])")),
    ("Events - builder place picker", evb("hide", "s3", "pc", EVB_PLACES + EVB_PICK)),
    ("Events - builder place card", evb("hide", "s2", "pc", EVB_CARD, art=True)),
    ("Events - builder map sheet", evb("hide", "s3", "pc", EVB_PLACES + "; ns.EventBuilder.MapSheet:Open({ pid = 'pc1' })",
                                   art=True, stand=True)),
    ("Events - builder new place", evb(None, "s1", "pc", "ns.EventBuilder.MapSheet:Open({ stand = true })", art=True,
                                   stand=True)),
    ("Events - builder matches card", evb("duel", "s2", "sm", "local d = ns.EventBuilder:GetState().def; "
                                      "d.blocks.b2.set.win = 'pieces'; d.blocks.b2.set.bo = 1; d.blocks.b2.set.fbo = 3; "
                                      "d.blocks.b2.set.atonce = 4; ns.EventBuilder:Refresh()")),
    ("Events - builder messages", evb("duel", "*", "ch")),
    ("Events - builder start from", evb(None, "s1", "ev")),
    ("Events - builder delete asks", evb("hide", "s3", "pl", "ns.EventBuilder.Defs:Delete('tags', 'tg1')")),
    ("Events - builder practice facts", evb("hide", "s1", "pl", "ns.EventBuilder:StartPractice(); ns.EventLive:PracticeSkip(); "
                                        "local S = ns.EventBuilder:GetState(); S.happen.kind = 'touch'; "
                                        "ns.EventBuilder:Refresh()")),
]
# (part 1's picker state named a piece part 2 migrated away: the same view on the show's players blank)
for _i, _st in enumerate(STATES):
    if _st[0] == "Events - builder picker":
        # (with the renders' real geometry: the picker places itself by the window's edges, as in the game)
        STATES[_i] = (_st[0], ev_builder("__MOCK.real_geometry = true; ns.EventBuilder:Refresh()" + EVB_PICKER))

# The final UI QA pass (2026-10-07): "Where to go" (the meeting place on the tracker, the event page's map and meta
# with "Show the way", the schedule sheet's "Meet at", the board's map with the zone and my arrow) and the edge cases
# the pass checked. A planned red light 12 minutes away (Gina, its host, a few yards from its start line); its calendar
# event is taken off again before "Home - calendar busy" (it stays last).
QA_EVENTS = []


def qa_meet(after, minutes=12, art=True, near=True):
    def fn(w, c):
        g = c["Gina"]
        demo_off(w, c)
        close_all(g)
        if art:
            g.eval(EVB_MAPART)
        did = g.eval("local d = ns.Events:NewDef(false); for k, v in pairs(ns.EventBlocks:Example('redlight')) do "
                     "d[k] = v end; ns.Events:SaveDef(d); return d.id")
        p = g.eval_py("local d = ns.Events:GetDef(...); local p = d.places[d.meet]; return { p.map, p.x, p.y }", did)
        if near:
            w.set_position("Gina", p[0], p[1] + 0.03, p[2] + 0.02, subzone="Nagrand")
        else:
            w.set_position("Gina", None)
        occ = g.eval("return ns.Events:Schedule(..., GetServerTime() + select(2, ...) * 60)", did, minutes)
        QA_EVENTS.append((occ, did))
        w.tick(1)
        g.eval("__MOCK.real_geometry = true")
        g.eval(after, occ, did)
        w.tick(0.5)
        return g
    return fn


def qa_cleanup(w, c):
    g = c["Gina"]
    w.set_position("Gina", None)
    for occ, did in QA_EVENTS:
        g.eval("ns.Events:DeleteOcc(...); ns.Events:DeleteDef(select(2, ...))", occ, did)
    del QA_EVENTS[:]
    g.eval("ns.EventTracker:Refresh()")


_QA = next(i for i, st in enumerate(STATES) if st[0] == "Home - calendar busy")
STATES[_QA:_QA] = [
    ("Events - tracker meet", qa_meet("ns.EventTracker:Refresh()")),
    ("Events - tracker meet far", qa_meet("ns.EventTracker:Refresh()", near=False)),
    ("Events - event page meet", qa_meet("ns.EventsUI:OpenEvent((...))")),
    ("Events - schedule meet at", qa_meet("ns.EventsUI:Open('library'); ns.EventsUI:OpenSchedule(select(2, ...))")),
    ("Events - board meet map", qa_meet("ns.EventTracker:Hide(); ns.EventLive:StartPractice(ns.Events:GetDef(select(2, ...)), 8); "
                                        "ns.EventBoard:Open('practice')")),
]

# The edge cases: practice runs of any size made by hand (the board only reads the state), long names (24 letters,
# the limit) for 8 tags / 8 scores / 24 places, long choices, banners over a prompt, the builder's editors full.
QA_LUA = r"""
QA = {}
local B, L, E = ns.EventBlocks, ns.EventLive, ns.EventEngine
QA.LONG = { 'Hidden in the long grass', 'Seekers of the far hills', 'Found behind the old mil', 'Out of the race for good',
  'Wardens of the green hil', 'Watchers of the dark woo', 'Keepers of the high towe', 'Runners of the long rive' }
QA.SCORES = { 'Most mushrooms gathered!', 'Longest time spent hidde', 'Fewest steps on the rout', 'Points from the judges 1',
  'Fish caught in Terokkar!', 'Gold gained in the marke', 'Ogres killed near Halaa!', 'Hints given to the seeker' }
QA.COLORS = { 'green', 'red', 'purple', 'blue', 'orange', 'yellow', 'teal', 'pink' }
function QA.Big(d, n, close)
  for _, b in pairs(d.blocks) do if b.kind == 'signup' then b.set = b.set or {}; b.set.spots = 64 end end
  L:StartPractice(d, 2)
  local _, p = L:GetPractice()
  local keys = {}
  for i = 1, n do keys[i] = 'Dummy' .. i .. '-Practice' end
  local run = E:New(d, { id = 'practice', host = ns.Util.PlayerKey(), signups = keys, out = {}, practice = true,
    now = function() return L:PracticeNow() end, nameOf = L.DisplayName })
  p.run = run
  run:Start()
  if close then for bid, b in pairs(run.st.blocks) do if b.kind == 'signup' and b.open then run:CloseSignup(bid) end end end
  run:Tick()
  L:SetPracticePaused(true)
  ns.EventBoard:Open('practice')
  ns.EventBoard:Refresh()
  return run
end
function QA.Long(d, tags, scores, places)
  if tags then d.tags = {}; for i = 1, tags do d.tags['tg' .. i] = { n = QA.LONG[i], c = QA.COLORS[i], shown = 'all' } end end
  if scores then d.scores = {}; for i = 1, scores do d.scores['sc' .. i] = { n = QA.SCORES[i], high = true, fmt = 'num', board = true } end end
  if places then
    d.places = {}
    for i = 1, places do
      d.places['pc' .. i] = { n = ('Place number %d of the hu'):format(i), map = 1951, x = 0.2 + 0.6 * ((i * 37) % 100) / 100,
        y = 0.2 + 0.6 * ((i * 61) % 100) / 100, r = 30 + (i % 4) * 40, z = 'Nagrand', sz = 'Halaa' }
    end
    d.meet = 'pc1'
  end
  return d
end
function QA.Spread(st, d)
  local tids = {}
  for id in pairs(d.tags or {}) do tids[#tids + 1] = id end
  table.sort(tids, function(a, b) return tonumber(a:match('%d+')) < tonumber(b:match('%d+')) end)
  st.tags = {}
  for _, id in ipairs(tids) do st.tags[id] = {} end
  for i, k in ipairs(st.entrants) do if #tids > 0 then st.tags[tids[((i - 1) % #tids) + 1]][k] = true end end
  st.scores = {}
  for id in pairs(d.scores or {}) do
    st.scores[id] = {}
    for i, k in ipairs(st.entrants) do st.scores[id][k] = (i * 7919) % 97 end
  end
  st.seq = (st.seq or 0) + 1
  ns.EventBoard:Refresh()
end
function QA.Choices()
  local d = B:Example('tmog')
  local me = ns.Util.PlayerKey()
  d.asks = { ak1 = { n = 'The theme of next week!!', q = 'Which theme should the next contest have?', kind = 'choice',
    from = 'entrants', votes = 1, time = 90, choices = { 'Pirates of the Barrens and Booty Bay ships',
    'The Undead of Stratholme and Scholomance', 'Night elves', 'Holiday outfits from every festival' } } }
  L:StartPractice(d, 6)
  local run = L:GetPractice()
  L:SetPracticePaused(true)
  local now = L:PracticeNow()
  run.st.entrants[#run.st.entrants + 1] = me
  run.st.qa = { ak1 = { open = true, who = { [me] = true }, q = d.asks.ak1.q, at = now, ends = now + 90, ans = {} } }
  run.st.seq = run.st.seq + 1
  ns.EventTracker:Refresh()
end
"""


def qa_edge(lua, art=False):
    def fn(w, c):
        g = c["Gina"]
        demo_off(w, c)
        close_all(g)
        if art:
            g.eval(EVB_MAPART)
        g.eval(QA_LUA)
        g.eval("__MOCK.real_geometry = true")
        g.eval(lua)
        w.tick(0.6)
        return g
    return fn


_QA2 = next(i for i, st in enumerate(STATES) if st[0] == "Home - calendar busy")
STATES[_QA2:_QA2] = [
    ("Events - board race 40 racers", qa_edge("QA.Big(ns.EventBlocks:Example('race'), 40, false)")),
    ("Events - board 8 long tags 40 players", qa_edge("local d = QA.Long(ns.EventBlocks:Example('hide'), 8, 2); "
                                                      "local run = QA.Big(d, 40, true); QA.Spread(run.st, d)")),
    ("Events - board 8 long scores", qa_edge("local d = QA.Long(ns.EventBlocks:Example('fish'), nil, 8); "
                                             "local run = QA.Big(d, 40, true); QA.Spread(run.st, d)")),
    ("Events - board 24 places", qa_edge("local d = QA.Long(ns.EventBlocks:Example('hide'), nil, nil, 24); "
                                         "QA.Big(d, 6, false)", art=True)),
    ("Events - board bracket 40", qa_edge("QA.Big(ns.EventBlocks:Example('duel'), 40, true)")),
    ("Events - ask long choices", qa_edge("QA.Choices()")),
    ("Events - banners over a prompt", qa_edge("QA.Choices(); for i = 1, 3 do ns.EventTracker:Show('practice', 'A very long "
                                               "banner text number ' .. i .. ': hide in the play area now, the seekers come "
                                               "in three minutes and they will find you') end")),
    ("Events - tracker long name", qa_edge("local d = ns.EventBlocks:Example('hide'); d.name = 'The great hide and seek of "
                                           "Nagrand'; QA.Big(d, 6, true); ns.EventBoard:Close(); local st = "
                                           "ns.EventLive:GetPractice().st; st.point = { [ns.Util.PlayerKey()] = 'pc1' }; "
                                           "st.buttons = { Hint = { [ns.Util.PlayerKey()] = true } }; ns.EventTracker:Refresh()")),
    ("Events - builder 8 long tags", evb("hide", "s3", "pl", "local d = ns.EventBuilder:GetState().def; d.tags = {}; "
                                     "for i = 1, 8 do ns.EventBlocks:NewDefinition(d, 'tags', { n = ({ 'Hidden in the long grass', "
                                     "'Seekers of the far hills', 'Found behind the old mil', 'Out of the race for good', "
                                     "'Wardens of the green hil', 'Watchers of the dark woo', 'Keepers of the high towe', "
                                     "'Runners of the long rive' })[i] }) end; ns.EventBuilder:Refresh(); "
                                     "ns.EventBuilder:CleanUp()")),       # (longer names, wider scripts: tidied)
    ("Events - builder long choices", evb("tmog", "s4", "as", "ns.EventBlocks:NewDefinition(ns.EventBuilder:GetState().def, "
                                      "'asks', { n = 'The theme of next week!!', q = 'Which theme next week?', kind = 'choice', "
                                      "choices = { 'Pirates of the Barrens and Booty Bay', 'The Undead of Stratholme and "
                                      "Scholomance', 'Night elves', 'Holiday outfits from every festival x', 'Tier four sets', "
                                      "'Anything goes this time' }, votes = 3 }); ns.EventBuilder:Refresh(); "
                                      "ns.EventBuilder.Defs:Open('asks', 'ak4')")),
    ("Events - builder map sheet 24 places", evb("hide", "s3", "pc", "local d = ns.EventBuilder:GetState().def; d.places = {}; "
                                             "for i = 1, 24 do d.places['pc' .. i] = { n = ('Place number %d of the hu'):format(i), "
                                             "map = 1951, x = 0.2 + 0.6 * ((i * 37) % 100) / 100, y = 0.2 + 0.6 * ((i * 61) % 100) "
                                             "/ 100, r = 30 + (i % 4) * 40, z = 'Nagrand' } end; d.meet = 'pc1'; "
                                             "ns.EventBuilder:Refresh(); ns.EventBuilder.MapSheet:Open({ pid = 'pc3' })", art=True)),
    ("Events - builder read-only list", evb("race", "s2", "lo", "local S = ns.EventBuilder:GetState(); S.readOnly = true; "
                                            "ns.EventBuilder:Refresh(); ns.EventBuilder.Defs:Open('lists', 'ls1')")),
]
_HOME_LAST = next(i for i, st in enumerate(STATES) if st[0] == "Home - calendar busy")
_home_fn = STATES[_HOME_LAST][1]


def _home_after_qa(w, c):
    qa_cleanup(w, c)
    return _home_fn(w, c)


STATES[_HOME_LAST] = (STATES[_HOME_LAST][0], _home_after_qa)
