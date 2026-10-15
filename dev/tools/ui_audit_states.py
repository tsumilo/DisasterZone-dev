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
                              'DisasterZoneEventSeason', 'DisasterZoneEventConfirm', 'DisasterZoneSimBuffs', 'DisasterZoneFeedbackSheet', 'DisasterZoneFeedbackToast', 'DisasterZoneFeedbackPointer', 'DisasterZoneFeedbackPointerBar',
                              'DisasterZonePollToast', 'DisasterZoneNotifyToast', 'DisasterZoneNotifyTray',
                              'DisasterZoneTotems', 'DisasterZoneTotemBar', 'DisasterZoneTotemRange',
                              'DisasterZoneAttendanceLeader', 'DisasterZoneAttendanceLeftEarly',
                              'DisasterZoneAttendancePicker', 'DisasterZoneAttendanceAway',
                              'DisasterZoneGalleryComponents', 'DisasterZoneGalleryLayouts', 'DZLookGallery', 'DZLookLongNames', 'DZAuditFull', 'DZGroupStage',
                              'DisasterZoneWardrobeBar', 'DisasterZoneWardrobePicker', 'DisasterZoneWardrobeIcons', 'DisasterZoneReserves', 'DisasterZoneReserveDemo' }) do
        local f = _G[name]; if f and f.Hide then f:Hide() end
      end
      -- (the shared pop-ups of UI:Toast, which replaced some of the named ones above)
      if ns.UI and ns.UI.ShownToasts then for _, t in ipairs(ns.UI:ShownToasts()) do t:Hide() end end
      if ns.StrategyBoard and ns.StrategyBoard.Close then pcall(ns.StrategyBoard.Close, ns.StrategyBoard) end
      if ns.SwingPractice and ns.SwingPractice.run then pcall(ns.SwingPractice.Stop, ns.SwingPractice, 'closed') end
      if DisasterZoneSwingPractice then DisasterZoneSwingPractice:Hide() end
      if ns.NavMenu and ns.NavMenu.Close then pcall(ns.NavMenu.Close, ns.NavMenu) end
      if ns.Tour and ns.Tour.IsRunning and ns.Tour:IsRunning() then pcall(ns.Tour.Stop, ns.Tour) end
      for o in pairs(__tourRects or {}) do
        o.GetLeft, o.GetBottom, o.GetWidth, o.GetHeight = nil, nil, nil, nil
      end
      __tourRects = nil
      if DisasterZoneWelcomeOffer then DisasterZoneWelcomeOffer:Hide() end
      if ns.WelcomeTour then
        -- (answered as the game answers it: seen, and my roles known, so no "New role" offers for roles I hold)
        local p = ns.WelcomeTour.Progress()
        p.seen = true
        local ok, roles = pcall(ns.WelcomeTour.Roles, ns.WelcomeTour)
        if ok and type(roles) == 'table' and type(p.known) == 'table' then
          for k in pairs(roles) do p.known[k] = true end
        end
      end
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
      if ns.WardrobeUI and ns.WardrobeUI.HideBar then ns.WardrobeUI:HideBar() end
      if ns.EditMode and ns.EditMode.IsActive and ns.EditMode:IsActive() then pcall(ns.EditMode.Close, ns.EditMode) end
      -- (My BiS's Equipped views: back to the list, the mock's own links)
      if __WORN_ORIG then GetInventoryItemLink = __WORN_ORIG; __WORN_ORIG = nil end
      if ns.MyBiS and ns.MyBiS.SetWorn then pcall(ns.MyBiS.SetWorn, ns.MyBiS, false) end
      if ns.DungeonsUI and ns.DungeonsUI.GetSheetState and ns.DungeonsUI:GetSheetState() then ns.DungeonsUI:CloseSheet() end
      if ns.RaidPlanUI and ns.RaidPlanUI.CloseEditor then ns.RaidPlanUI:CloseEditor() end
      if ns.DungeonRuns and ns.Demo and ns.Demo:IsEnabled() then ns.DungeonRuns:Unlist(true) end
      if ns.MainFrame and ns.MainFrame.Close then ns.MainFrame:Close() end
      if ns.DropPanel and ns.DropPanel.Hide then ns.DropPanel:Hide() end
      if ns.RollFrame and ns.RollFrame.frame then ns.RollFrame.frame:Hide() end
      if ns.UI and ns.UI.CloseMenus then ns.UI:CloseMenus() end
      __MOCK.real_geometry = nil
      local rf = _G.DisasterZoneRollFrame; if rf and rf.Hide then rf:Hide() end
      if ns.Popup then ns.Popup:HideAll() end
      if GameTooltip then GameTooltip:Hide() end
      if __MOCK.mods and __MOCK.mods.shift then __MOCK.set_modifiers() end""")


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


# Karazhan Chess: a game against Medivh (Magus, cheats) twelve moves in with his fire on c4 and f3, a guild invite,
# a guild game waiting for the opponent, a finished one
CHESS_GAMES = ("T_AUD = T_AUD or {} local C = ns.Chess local d = C.Data() d.games = {} "
               "local g = C:NewAIGame(1, 'magus', true) T_AUD.g = g "
               "g.moves = { 'e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'g8f6', 'd2d3', 'f8c5', 'c2c3', 'd7d6', 'b1d2', 'a7a6' } "
               "g.events = { { ply = 12, k = 'fire', sq = { 'c4', 'f3' }, line = 2 } } "
               "d.games['inv1'] = { id = 'inv1', mode = 'guild', me = -1, opp = 'Victhar-Thunderstrike', moves = {}, "
               "  created = time() - 60, updated = time() - 60, status = 'invited', acked = 0 } "
               "d.games['gg1'] = { id = 'gg1', mode = 'guild', me = 1, opp = 'Fazerblue-Thunderstrike', "
               "  moves = { 'd2d4', 'd7d5', 'c2c4' }, created = time() - 9000, updated = time() - 3000, status = 'active', acked = 2 } "
               "d.games['ov1'] = { id = 'ov1', mode = 'ai', me = -1, opp = 'Medivh', strength = 'guardian', cheats = false, seed = 5, "
               "  moves = { 'f2f3', 'e7e5', 'g2g4', 'd8h4' }, events = {}, created = time() - 90000, updated = time() - 86000, "
               "  status = 'over', result = '0-1', reason = 'checkmate' } ")
# ... and a guild ladder of six members
CHESS_LADDER = ("local res = C.Data().results local names = { 'Victhar', 'Fazerblue', 'Saltykim', 'Dyrma', 'Frostweaver' } "
                "local me = ns.Util.PlayerKey() for i = 1, 24 do local a = names[(i % 5) + 1] .. '-Thunderstrike' "
                "local b = (i % 3 == 0) and me or (names[((i * 2) % 5) + 1] .. '-Thunderstrike') "
                "if a ~= b then res['r' .. i] = { w = a, b = b, r = (i % 4 == 0) and '1/2-1/2' or ((i % 3 == 1) and '1-0' or '0-1'), "
                "  at = time() - 100000 + i * 1000, n = 40 + i } end end C.ratings = nil ")


# Council Bingo audit states: a live game in the SSC deck (row 3 complete, column O 4 of 5), a legendary hit with
# Fated, and a season / Codex to show (T_BINGO.leg = my legendary's id).
BINGO_LIVE = ("local d, me, now = ns.Games:GetData('bingo'), ns.Util.PlayerKey(), time() "
              "d.current = { id = 'cardlive', host = me, started = now - 3600, hits = {}, who = {}, raid = 'ssc' } "
              "d.view = { g = 'cardlive', hits = {}, lines = 1 } "
              "local card = ns.Bingo:GetMyCard() "
              "local who = { 'Victhar', 'Fazerblue', 'Lady Vashj', 'Saltykim', 'Dyrma', 'Lidevna' } "
              "T_BINGO = { leg = ns.Bingo:GetLegendary(me) } "
              "local n = 0 "
              "for _, i in ipairs({ 11, 12, 14, 15, 5, 10, 20, 1, 7, 22, 18 }) do "
              "  local id = card[i] "
              "  if id ~= T_BINGO.leg then n = n + 1 "
              "    d.current.hits[id] = now - 900 + n * 60 d.view.hits[id] = true "
              "    d.current.who[id] = who[(n % #who) + 1] end end ")
BINGO_LEGENDARY = ("local g, me, now = ns.Bingo:GetGame(), ns.Util.PlayerKey(), time() "
                   "g.hits[T_BINGO.leg] = now g.who[T_BINGO.leg] = 'Lainatukka' "
                   "local card = ns.Bingo:GetMyCard() "
                   "local marks = ns.BingoCard.Marks(card, g.hits) "
                   "g.fated = { [me] = ns.BingoCard.BestGap(marks) } ns.Games:GetData('bingo').view.lines = 9 ")
BINGO_CODEX = ("local d, me, now = ns.Games:GetData('bingo'), ns.Util.PlayerKey(), time() "
               "local realm = me:match('%-(.+)$') or 'Thunderstrike' "
               "d.games = 31 d.codex = {} "
               "for i, sq in ipairs(ns.BingoSquares.list) do "
               "  local keep = (sq.q == 'c' and i % 5 ~= 0) or (sq.q == 'u' and i % 3 ~= 0) or (sq.q == 'r' and i % 2 == 0) "
               "    or (sq.q == 'e' and i % 3 == 0) "
               "  if keep then d.codex[sq.id] = { n = 1 + (i * 7) % 20, t = now - i * 86400, who = 'Dyrma' } end end "
               "d.codex.bubble_hearth = { n = 1, t = now - 3 * 86400, who = 'Lainatukka', raid = 'ssc' } "
               "d.codex.blizzard = { n = 1, t = now - 17 * 86400, raid = 'tk' } "
               "d.codex.beat_clock = { n = 1, t = now - 38 * 86400, who = 'Prince Malchezaar', raid = 'kara' } "
               "d.season = {} "
               "for i, r in ipairs({ { 'Gina', 412, 9, 2 }, { 'Saltykim', 377, 7, 1 }, { 'Tsumil', 351, 6, 1 }, "
               "  { 'Dyrma', 322, 6, 0 }, { 'Fazerblue', 298, 5, 1 }, { 'Lidevna', 270, 4, 0 }, { 'Victhar', 256, 4, 0 }, "
               "  { 'Xiavor', 231, 3, 0 }, { 'Valshares', 120, 1, 0 } }) do "
               "  local key = r[1] == me:match('^[^-]+') and me or (r[1] .. '-' .. realm) "
               "  d.season[key] = { points = r[2], bingos = r[3], legendaries = r[4], firsts = r[3] > 5 and 2 or 0, blackouts = 0 } "
               "end ")


# The Binding of Illidan: a run put in a room or before a boss and stepped (simple aim: shoot up, drift)
BOI_AUD = ("BOI_AUD = BOI_AUD or {} local E = ns.BoI "
           "function BOI_AUD.start(n) ns.GamesUI:Select('illidan') local r = E.New({ class = 'MAGE', seed = 777 }) "
           "  if n > 1 then E.EnterFloor(r, n) end r.mode, r.god = 'play', true r.items = { 'eye' } r.has.eye = true "
           "  ns.BoIUI._SetRun(r) ns.BoIUI._Focus(true) return r end "
           "function BOI_AUD.run(r, frames) for i = 1, frames do E.Step(r, { shoot = 'up', mx = (i % 120 < 60) and 0.6 or -0.6 }) end "
           "  ns.BoIUI._Draw() end "
           "function BOI_AUD.room(n, frames) local r = BOI_AUD.start(n) "
           "  for _, nb in ipairs(E.Neighbours(r.map, r.room)) do if nb.room.type == 'normal' then E.ChangeRoom(r, nb.dir) break end end "
           "  r.mode = 'play' BOI_AUD.run(r, frames) end "
           "function BOI_AUD.boss(n, frames, setup) local r = BOI_AUD.start(n) local boss "
           "  for _, x in ipairs(r.map.list) do if x.type == 'boss' then boss = x end end "
           "  local nb = E.Neighbours(r.map, boss, true)[1] r.room = nb.room r.room.cleared = true E.ChangeRoom(r, E.OPP[nb.dir]) "
           "  r.mode = 'play' if setup then setup(r.bossF, r) end BOI_AUD.run(r, frames) end ")
BOI_BOARD = ("do local B, day, realm = ns.BoIBoard, ns.BoIBoard:Today(), '-' .. ns.Util.GetPlayerRealm() "
             "for _, e in ipairs({ { 'Xiavor', { c = 'MAGE', f = 5, w = true, t = 702, k = 61, i = 7 } }, "
             "  { 'Yubell', { c = 'WARLOCK', f = 5, w = true, t = 785, k = 70, i = 9 } }, "
             "  { 'Dinalingus', { c = 'PALADIN', f = 4, t = 640, k = 44, i = 5, by = 'Mother Shahraz' } }, "
             "  { 'Quentrell', { c = 'HUNTER', f = 2, t = 260, k = 19, i = 2, by = 'Supremus' } }, "
             "  { 'Lidevna', { c = 'SHAMAN', f = 1, t = 95, k = 6, i = 0, by = 'Felhunter' } } }) do "
             "  B._Store(day, e[1] .. realm, e[2]) end end ")


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


def azero_battle(map_id, x, y, foe, then=None):
    """a wild battle on map_id, at the action menu (FIGHT / BAG / PARTY / RUN)"""
    def fn(w, c):
        g = azero_at(map_id, x, y, "local M = ns.AzeroMon ns.Azero.save.party = { M.New('murkling', 12, ns.Azero.rng) }")(w, c)
        import importlib.util
        spec = importlib.util.spec_from_file_location("_azero_bot", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                      "..", "tests", "games", "_azero_bot.py"))
        bot = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bot)
        g.eval(bot.BOT)
        g.eval("T_AZ.settle()")                              # past the opening tips
        g.eval("ns.AzeroUI._Focus(true)")
        g.eval("ns.Azero:Run(function(gm) gm:WildBattle(%r, 8) end)" % foe)
        for _ in range(80):
            w.tick(0.2)
            st = g.eval_py("return ns.AzeroUI._State()")
            if st.get("battle") and st.get("actionOpen"):
                break
            g.eval("ns.AzeroUI._HandleKey('A')")
        if then:
            g.eval(then)
        w.tick(0.6)
        g.eval("ns.AzeroUI._Focus(true)")                 # no "paused" veil over the picture
        return g
    return fn


def azero_at(map_id, x, y, lua=None):
    """Azeromon running in the Games tab, the player standing on map_id at x, y (a new game)"""
    def fn(w, c):
        g = opened("games", "ns.Azero:NewGame()")(w, c)
        g.slash("/dz play azeromon")
        w.tick(0.3)
        g.eval("ns.AzeroUI._HandleKey('A')")               # CONTINUE
        w.tick(0.5)
        g.eval("ns.Azero:EnterMap(%r, %d, %d, 'down', true)" % (map_id, x, y))
        g.eval("ns.Azero.clockHour = 12")                 # by day, unless the state says otherwise
        if lua:
            g.eval(lua)
        w.tick(0.3)
        return g
    return fn


def azero_menu(hour):
    """Azeromon's start menu over Goldshire at `hour` (the money box: money, badges, realm clock + sky icon)"""
    def fn(w, c):
        g = azero_at("town", 12, 11, "ns.AzeroUI.tipsOff = true")(w, c)
        for _ in range(6):                                 # a tip from before tipsOff: read it away
            st = g.eval_py("return ns.AzeroUI._State()")
            if not st.get("msg") and not st.get("text") and not st.get("stack"):
                break
            g.eval("ns.AzeroUI._HandleKey('%s')" % ('B' if st.get("stack") else 'A'))
            w.tick(0.6)
        g.eval("ns.Azero.clockHour = %d ns.AzeroUI._HandleKey('START') ns.AzeroUI._Focus(true)" % hour)
        w.tick(0.2)
        return g
    return fn


def azero_poster(shot, t=3):
    """The Games hub with Azeromon's poster in front, its film (Games/Azeromon/Poster.lua) t s into shot `shot`"""
    seek = ("ns.GamesUI:ShowFront('azeromon') ns.GamesUI:PauseAnim(true) "
            "for _, p in ipairs(ns.GamesUI.__posters) do if p.id == 'azeromon' and p.cover.Seek then "
            "p.cover:Seek(%d, %s) p.cover:Tick(0.01) end end" % (shot, t))
    return opened("games", seek)


def tour_view(key, lua):
    """A tutorial step (UI/Tour.lua) on Gina's window: the mock's frames have no real positions (GetLeft is 0), so
    the audit's own layout is handed to the frames on screen (GetLeft / GetBottom / GetWidth / GetHeight, cleared again
    by close_all) and the tour looks again: its dimming, gold frame, box and bar land where the game puts them."""
    def fn(w, c):
        import ui_audit as A
        g = opened(key, lua)(w, c)
        w.tick(0.5)
        regs, ui = A.capture(g)
        lay = A.Layout(regs, ui)
        out = []
        for seq, r in regs.items():
            if r["kind"] in ("FontString", "Texture", "MaskTexture") or not r["vis"]:
                continue
            rc = lay.rect(seq)
            if rc:
                out.append("%d,%.2f,%.2f,%.2f,%.2f" % ((seq,) + tuple(rc)))
        g.eval("""
          local M, data = __MOCK, ...
          local by = {}
          for _, o in ipairs(M.all_objects) do local st = M.OBJ[o]; if st then by[st.seq] = o end end
          __tourRects = {}
          for seq, l, b, w, h in data:gmatch("(%d+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)") do
            local o = by[tonumber(seq)]
            if o then
              l, b, w, h = tonumber(l), tonumber(b), tonumber(w), tonumber(h)
              o.GetLeft = function() return l end
              o.GetBottom = function() return b end
              o.GetWidth = function() return w end
              o.GetHeight = function() return h end
              __tourRects[o] = true
            end
          end
          ns.Tour:Tick()""", ";".join(out))
        w.tick(0.2)
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
        g.eval("ns.Azero.clockHour = 12")                 # by day, unless the state says otherwise
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



# Guild > Polls (UI/PollsTab.lua): Grumpykat (officer) asks the guild a Pick days poll, a yes / no, a raid pick Gina
# answered, a one-answer she hasn't and a closed one; Gina (GM) asks the Main team about loot. Everyone answers some.
POLLS = {}


def polls_seed(w, c):
    if POLLS:
        return
    g, k = c["Gina"], c["Grumpykat"]
    now_days = k.eval("""
        local t = GetServerTime()
        local out = {}
        for _, off in ipairs({ 3, 5, 6, 8, 9 }) do
          out[#out + 1] = date('%Y-%m-%d', t + off * 86400) .. (off >= 8 and ' 19:30' or ' 20:00')
        end
        return table.concat(out, ',')""").split(",")

    def ask(cl, q, kind, o, a, cl_in, rv="vote", ch=True, mx=0):
        return cl.eval("""
            local q, kind, o, a, cl, rv, ch, mx = ...
            return (ns.Polls:Create({ q = q, k = kind, o = o, a = a, cl = GetServerTime() + cl, rv = rv, ch = ch,
                                      mx = mx }))""", q, kind, o, a, cl_in, rv, ch, mx)
    POLLS["days"] = ask(k, "Which nights can you raid SSC next week?", "days", now_days, [["g"]], 4 * 86400, "live")
    POLLS["yn"] = ask(k, "Should we start Thursdays 30 minutes earlier?", "yn", None, [["g"]], 86400 + 3600)
    POLLS["raid"] = ask(k, "Which raid should we do next Wednesday?", "one",
                        ["Gruul's Lair", "Magtheridon's Lair", "Karazhan", "A night off"], [["g"]], 2 * 86400)
    POLLS["night"] = ask(k, "Which night should we move SSC to?", "one",
                         ["Wednesday", "Thursday", "Sunday", "Keep it on Monday"],
                         [["t", IDS["team"], False, "Main team"], ["r", "leader"]], 3 * 86400)
    POLLS["bank"] = ask(k, "Which consumables should the guild bank stock?", "many",
                        ["Flasks of Supreme Power", "Elixirs of Major Agility", "Super Mana Potions",
                         "Fel Mana Potions"], [["g"]], 5 * 86400, "close", True, 2)
    POLLS["closed"] = ask(k, "Bring back the Sunday alt raid?", "yn", None, [["g"]], 3600)
    POLLS["loot"] = ask(g, "Loot: allow off-spec rolls on tier tokens?", "one",
                        ["Yes, after main spec", "No, main spec only", "The council decides"],
                        [["t", IDS["team"], False, "Main team"], ["r", "officer"]], 3 * 86400)
    # (1.4.1) a poll of three questions (Victhar's idea, feedback #7)
    POLLS["plan"] = k.eval("""
        local days = ...
        return (ns.Polls:Create({ qs = {
            { q = "Would you like a second raid night for progression?", k = "yn" },
            { q = "Which nights would suit you best?", k = "days", o = days },
            { q = "What start time (realm time) suits you?", k = "one", o = { "19:00", "19:30", "20:00", "20:30" } },
          }, a = { { "g" } }, cl = GetServerTime() + 5 * 86400, rv = "live", ch = true }))""", now_days[:4])
    w.tick(12)                     # (ten polls queue behind the comm throttle)
    plan = k.eval("local id = ...; local out = {}; for i, q in ipairs(ns.Polls:Questions(ns.Polls:GetPoll(id))) do "
                  "out[i] = q and q.id or '' end; return table.concat(out, ',')", POLLS["plan"]).split(",")
    POLLS["plan1"], POLLS["plan2"], POLLS["plan3"] = plan[0], plan[1], plan[2]
    votes = {
        "Grumpykat": {"days": [1, 1, 1, 2, 1], "raid": [1], "night": [2], "loot": [1], "closed": [1], "yn": [1],
                      "plan1": [1], "plan2": [1, 1, 0, 2], "plan3": [3]},
        "Victhar": {"days": [1, 0, 1, 1, 1], "raid": [2], "night": [2], "loot": [1], "closed": [2], "yn": [1],
                    "plan1": [1], "plan2": [1, 0, 1, 1], "plan3": [3]},
        "Shadowmelder": {"days": [1, 0, 1, 2, 1], "raid": [1], "night": [1], "loot": [2], "closed": [1]},
        "Vaenyria": {"days": [1, 1, 1, 1, 1], "raid": [1], "night": [2], "loot": [1], "yn": [2], "plan1": [2],
                     "plan2": [0, 1, 1, 0], "plan3": [2]},
        "Thunderhoofx": {"days": [1, 0, 1, 0, 1], "raid": [3], "night": [1], "yn": [1], "plan1": [1]},
        "Moonwhisper": {"days": [1, 2, 1, 1, 0], "raid": [1], "night": [3], "loot": [3]},
        "Lightbringer": {"days": [0, 1, 1, 2, 1], "night": [2]},
    }
    for name, vs in votes.items():
        for key, choice in vs.items():
            if key in POLLS and POLLS[key]:
                c[name].eval("ns.Polls:Vote(...)", POLLS[key], choice)
    g.eval("ns.Polls:Vote(...)", POLLS["raid"], [1])
    g.eval("ns.Polls:Vote(...)", POLLS["loot"], [1])
    g.eval("ns.Polls:Vote(...)", POLLS["bank"], [1, 3])
    g.eval("ns.Polls:Vote(...)", POLLS["plan1"], [1])
    w.tick(3)
    k.eval("ns.Polls:Close(...)", POLLS["closed"])
    w.tick(8)


def polls_view(lua=None, viewer="Gina"):
    def fn(w, c):
        polls_seed(w, c)
        cl = c[viewer]
        demo_off(w, c)
        close_all(cl)
        cl.eval("ns.PollsUI:SetDraft(nil); ns.PollsUI:ShowList('open')")
        tab(cl, "polls")
        if lua:
            w.tick(0.3)
            cl.eval(lua, *[POLLS.get(x) for x in ("days", "yn", "raid", "night", "bank", "closed", "loot", "plan1",
                                                "plan2", "plan3")])
        return cl
    return fn


def polls_toast(w, c):
    polls_seed(w, c)
    g = c["Gina"]
    demo_off(w, c)
    close_all(g)
    g.eval("ns.MainFrame:Close(); ns.PollsUI:ShowToast(ns.Polls:GetPoll(...))", POLLS["yn"])
    return g


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
# (st_drop's item_lua) the first P1 head, made a prized item by Gina (the GM) before it drops
PRIZED_ITEM = ("local id = ns.ItemDB:GetCandidates(1, { maxPhase = 1 })[1].itemID; "
               "if not ns.Prized:ForItem(id) then ns.Prized:Add({ id }, { rank = { m = 'r', i = 1 }, "
               "main = { m = 'r' }, cd = { m = 'r', w = 4 }, vote = { s = 'all' } }) end; return id")


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


# Crafting materials (2026-10-10): a Nether Vortex from SSC trash. Lists: Shadowmelder Belt of Deep Shadow (holds 1:
# this one completes it), Victhar Red Belt of Battle + Lionheart Executioner (alt), Moonwhisper Belt of Natural Power,
# Lightbringer Belt of the Long Road, Frostweaver (not in the raid) Belt of Blasting. Moonwhisper crafts the
# leatherworking belts, Grumpykat (not in the raid) the tailoring ones.
MAT_LISTS = {"Shadowmelder": [(2, 8, "main", 30040)], "Victhar": [(2, 8, "main", 30032), (2, 15, "alt", 28430)],
             "Moonwhisper": [(2, 8, "main", 30042)], "Lightbringer": [(2, 8, "main", 30036)],
             "Frostweaver": [(2, 8, "main", 30038)]}
MAT_RECIPES = {"Moonwhisper": ("Leatherworking", [("Belt of Deep Shadow", 36351, 30040),
                                                  ("Belt of Natural Power", 36349, 30042)]),
               "Grumpykat": ("Tailoring", [("Belt of Blasting", 36315, 30038), ("Belt of the Long Road", 36316, 30036)])}


def seed_materials(w, c):
    if IDS.get("materials"):
        return
    IDS["materials"] = True
    for name, picks in MAT_LISTS.items():
        for phase, sid, which, item in picks:
            c[name].eval("ns.BiS:SetSlot(...)", phase, sid, which, item)
        c[name].eval("ns.BiS:Commit()")
    for name, (prof, recipes) in MAT_RECIPES.items():
        cl = c[name]
        for rname, spell, _ in recipes:
            cl.eval("__MOCK.SPELL_NAMES[...] = select(2, ...)", spell, rname)
        set_skills(cl, [(prof, 375, 375)])
        cl.eval("local name, rows = ...; __MOCK.tradeskill = { name = name, rank = 375, max = 375, rows = rows }", prof,
                [{"name": "Recipes", "header": True}] + [{"name": n, "spell": sp, "item": it} for n, sp, it in recipes])
        cl.fire("TRADE_SKILL_SHOW")
    for x in c.values():
        x.eval("ns.BiS:Commit()")
    w.tick(1)
    for x in c.values():
        x.slash("/dz sync")
        w.tick(0.3)
    w.tick(45)


def st_material(stage):
    """stage: "panel" (the council's card), "rolling" (Shadowmelder, Victhar, Lightbringer rolled), "popup" (Victhar's
    roll popup), "awarded" (awarded to Shadowmelder: the craft line with Whisper)."""
    def fn(w, c):
        g = c["Gina"]
        demo_off(w, c)
        close_all(g)
        seed_materials(w, c)
        members = [g] + [c[n] for n in ("Victhar", "Shadowmelder", "Vaenyria", "Moonwhisper", "Lightbringer",
                                         "Pugsyhealer", "Darkstalkerr")]
        w.enter_instance("Serpentshrine Cavern", 548, max_players=25)
        w.make_raid(members, leader=g)
        w.tick(4)
        if g.eval("return ns.GroupRules:GetSession() ~= nil"):
            g.eval("ns.RaidLog:End()")
            w.tick(2)
        g.eval("ns.GroupRules:SetSession(true, nil, ...)", {"loot": True, "rolls": True, "lock": False})
        w.tick(3)
        g.eval("for _, s in ipairs(ns.Roll:GetQueue() or {}) do if s.id then ns.Roll:End(s.id) end end; "
               "local a = ns.Roll:GetActive(); if a then ns.Roll:End(a.id) end")
        for x in c.values():
            x.eval("ns.Materials:Reset()")
        c["Shadowmelder"].set_bags({(0, 1): (30183, 1)})
        w.tick(1)
        DROPS.append(1)
        g.open_loot([(30183, 4)], source_guid="Creature-0-1-2-3-21251-%06X" % len(DROPS))
        w.tick(3)
        viewer = g
        if stage in ("rolling", "popup", "awarded"):
            g.eval("ns.DropPanel:StartRoll(30183)")
            w.tick(1)
            if stage != "popup":
                for n, v in (("Victhar", 91), ("Shadowmelder", 34), ("Lightbringer", 66)):
                    w.player_roll(c[n], v)
                w.tick(2)
            else:
                viewer = c["Victhar"]
        if stage == "awarded":
            g.eval("local b = ns.DropPanel.blocks[1]; ns.DropPanel:EndRoll(b.rollSession)")
            w.tick(1)
            g.eval("ns.DropPanel:Render(); ns.DropPanel:AwardSuggested(ns.DropPanel.blocks[1])")
            w.tick(0.5)
            for p in ("DISASTERZONE_CONFIRM_AWARD", "DISASTERZONE_GIVE_ITEM"):
                if p in g.popups():
                    g.accept_popup(p)
            w.tick(2)
        g.eval("ns.DropPanel:Render()")
        g.eval("local f = ns.DropPanel.frame; if f then f:ClearAllPoints(); f:SetPoint('TOPLEFT', UIParent, 'TOPLEFT', 40, -80) end")
        return viewer
    return fn


def st_demo_roll(w, c):
    """The demo raid rolling on Ravager's Bracers (Alt / OS wanters), 12 s in: passes, a double roll, a bad range,
    the demo council's votes; the council's view (vote rail, attendance rings, dry streaks, roll meters)."""
    g = c["Gina"]
    close_all(g)
    if not g.eval("return ns.Demo:IsEnabled()"):
        g.slash("/dz demo on")
        w.tick(1)
    g.eval("""
        local db = ns.ItemDB
        for _, raid in ipairs(db:GetRaids()) do for _, boss in ipairs(raid.bosses or {}) do
            for _, id in ipairs(boss.items or {}) do
                if db:GetName(id) == "Ravager's Bracers" then
                    local ref = db:GetBossRef(raid.key .. ":" .. boss.key)
                    ns.Loot:HandleDrop({ s = "TEST-roll-rows", b = ref.key, i = { id }, ts = GetServerTime(),
                        test = true }, ns.Util.PlayerKey())
                    return
                end
            end
        end end""")
    w.tick(1)
    g.eval("local b = ns.DropPanel.blocks[1]; ns.DropPanel:StartRoll(b.itemID)")
    w.tick(12, 1)
    g.eval("local f = _G.DisasterZoneRollFrame; if f then f:Hide() end")
    g.eval("local f = ns.DropPanel.frame; if f then f:ClearAllPoints(); f:SetPoint('TOPLEFT', UIParent, 'TOPLEFT', 40, -60) end")
    return g


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
    """The session crest of a running raid (loot council off), hovered: the line beside the seal."""
    g = raid_with_session(w, c, {"loot": False, "rolls": True, "lock": False})
    g.eval("__MOCK.real_geometry = true; ns.SessionBar:Update(); ns.SessionBar:Peek(true)")
    return g


# Loot reserves (1.4.3): Gina hosts reserves in Karazhan (2 each, the Champion helm held for the guild); the raid
# reserved by every way there is (the picker, LootReserve, whispers, an import). Keys come from the group itself (a
# pug from another realm).
RESERVES_SEED = r"""
local R = ns.Reserves
R:_Reset()
R:Open({ rk = 'Karazhan', n = 2, hr = { 29760 } })
local keys = {}
for _, k in ipairs(ns.Util.GetGroupKeys()) do keys[ns.Util.ShortName(k)] = k end
for _, e in ipairs({ { 'Victhar', 28766, 'd' }, { 'Victhar', 28770, 'd' }, { 'Shadowmelder', 28770, 'l' },
                     { 'Vaenyria', 28764, 'w' }, { 'Moonwhisper', 28766, 'd' }, { 'Lightbringer', 28763, 's' },
                     { 'Pugsyhealer', 28766, 'w' }, { 'Darkstalkerr', 28764, 'l' }, { 'Gina', 28757, 'd' },
                     { 'Lightbringer', 28477, 'h' } }) do
  if keys[e[1]] then R:AddFor(keys[e[1]], e[2], e[3], true) end
end
"""


def st_reserves(view, viewer="Gina", lua=""):
    """The reserves window: view "pick" (My reserves, at Prince), "list" or "wrap"; lua runs on the host after the seed."""
    def fn(w, c):
        g = raid_with_session(w, c, {"loot": True, "rolls": True, "lock": False, "reserve": True})
        g.eval(RESERVES_SEED + lua)
        w.tick(3)
        v = c[viewer]
        close_all(v)
        v.eval("__MOCK.real_geometry = true; ns.ReservesUI:GetState().boss = 'Prince'; ns.ReservesUI:Show(...)", view)
        w.tick(0.5)
        return v
    return fn


def st_reserve_crest(idle):
    """The crest's drawer with reserves: before the start (Reserves picked on the line, none open yet) or running (the
    seeded list)."""
    def fn(w, c):
        g = raid_with_session(w, c, None if idle else {"loot": True, "rolls": True, "lock": False, "reserve": True})
        g.eval("ns.Reserves:_Reset()")
        if idle:
            g.eval("local p = ns.SessionBar:GetPick(); if not (p and p.reserve) then ns.SessionBar:FlipPick('reserve') end")
        else:
            g.eval(RESERVES_SEED)
        w.tick(2)
        g.eval("__MOCK.real_geometry = true; ns.SessionBar:Update(); ns.SessionBar:Peek(true); "
               "ns.SessionBar:ToggleDrawer(true)")
        return g
    return fn


def st_reserve_drop(roll=False, viewer="Gina"):
    """The drop panel of a Prince kill under reserves: the seeded list (Ruby Drape 3 reservers, Mindblade 2, the Jade
    Ring 1, the Champion helm held, Malchazeen nobody); roll = the Ruby Drape rolling (reservers and one who didn't)."""
    def fn(w, c):
        g = raid_with_session(w, c, {"loot": True, "rolls": True, "lock": False, "reserve": True})
        g.eval("for _, s in ipairs(ns.Roll:GetQueue() or {}) do if s.id then ns.Roll:End(s.id) end end; "
               "local a = ns.Roll:GetActive(); if a then ns.Roll:End(a.id) end")
        g.eval(RESERVES_SEED)
        w.tick(2)
        DROPS.append(1)
        g.open_loot([(28766, 4), (28770, 4), (28763, 4), (29760, 4), (28767, 4)],
                    source_guid="Creature-0-1-2-3-15690-%06X" % len(DROPS))
        w.tick(2)
        # (the start-of-raid pop-ups are long gone by the first boss)
        c[viewer].eval("if ns.UI and ns.UI.ShownToasts then for _, t in ipairs(ns.UI:ShownToasts()) do t:Hide() end end")
        if roll:
            g.eval("ns.DropPanel:StartRoll(28766)")
            w.tick(1)
            for n, v in (("Victhar", 64), ("Moonwhisper", 88), ("Shadowmelder", 97)):
                w.player_roll(c[n], v)
            w.tick(1)
            g.eval("ns.DropPanel:Render()")
        g.eval("local f = ns.DropPanel.frame; if f then f:ClearAllPoints(); f:SetPoint('TOPLEFT', UIParent, 'TOPLEFT', 40, -80) end")
        return c[viewer]
    return fn


def st_reserve_demo(step, view="lead"):
    """The reserves demo (/dz reserves demo) at a step, seen as view."""
    def fn(w, c):
        g = c["Gina"]
        demo_off(w, c)
        close_all(g)
        g.eval("__MOCK.real_geometry = true; ns.ReserveDemo:Start(); ns.ReserveDemo:SetView(...)", view)
        for n in range(2, step + 1):
            g.eval("ns.ReserveDemo:Go(...)", n)
            w.tick(4 if n != 6 else 2)
        if step == 6 and view == "lead":
            g.eval("ns.DropPanel:RollAll()")
            w.tick(6)
        g.eval("local f = ns.DropPanel.frame; if f then f:ClearAllPoints(); f:SetPoint('TOPLEFT', UIParent, 'TOPLEFT', 40, -80) end")
        return g
    return fn


def st_session_crest(open_=False, idle=False):
    """The session crest in Gina's raid: before the start (the line with the switches) or running, its drawer open."""
    def fn(w, c):
        g = raid_with_session(w, c, None if idle else {"loot": True, "rolls": True, "lock": True})
        g.eval("__MOCK.real_geometry = true; ns.SessionBar:Update(); ns.SessionBar:Peek(true)")
        if open_:
            g.eval("ns.SessionBar:ToggleDrawer(true)")
        return g
    return fn


def st_crest_demo(moment, open_=True):
    """Demo mode's made-up night in Serpentshrine Cavern (/dz raid bar <moment>), its drawer open."""
    lua = ("__MOCK.real_geometry = true; ns.SessionBar:Demo('%s'); ns.SessionBar:Peek(true)" % moment
           + ("; ns.SessionBar:ToggleDrawer(true)" if open_ else ""))
    return demo(lua)


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


SIM_P1 = {1: 29073, 2: 28745, 3: 29075, 15: 24259, 5: 29071, 9: 28795, 10: 30644, 6: 28779, 7: 30257, 8: 28608,
          11: 28757, 12: 30834, 13: 29383, 14: 28830, 16: 28429, 18: 27484}


# Socketed / enchanted in the worn links (by sid): the guide's best for these, nothing on the rest.
WORN_SOCKETED = "{ [1] = true, [3] = true, [5] = true, [9] = true, [15] = true }"


def worn_view(lua=None):
    """My BiS's Equipped tab: Gina (Ret) in SIM_P1, the WORN_SOCKETED items' links carrying the guide's gems and
    enchant (the mock's links have none), then optional Lua."""
    def fn(w, c):
        g = opened("mybis", "ns.BiS:SetSpec('Retribution'); ns.MyBiS:SetPhase(1, true)")(w, c)
        g.equip(SIM_P1)
        w.tick(0.3)
        g.eval("""local W, G = ns.WornGems, ns.Gems
            local eq = W:Equipped()
            local sug = G:FillSetups(W:View(nil, true, eq), 1, nil, true) or {}
            local on = """ + WORN_SOCKETED + """
            local orig = __WORN_ORIG or GetInventoryItemLink
            __WORN_ORIG = orig
            local function n(v) return (v and v ~= 0) and tostring(v) or "" end
            GetInventoryItemLink = function(unit, slot)
              local l = orig(unit, slot)
              for sid, s in ipairs(ns.SLOTS) do
                local e = eq[sid]
                local su = e and on[sid] and sug[e.id]
                if s.invSlot == slot and su and l then
                  local gm = su.gems or {}
                  l = l:gsub("item:(%d+):[^|]*", function(id)
                    return ("item:%s:%s:%s:%s:%s:%s:::70"):format(id, n(su.enchant), n(gm[1]), n(gm[2]), n(gm[3]),
                      n(gm[4])) end, 1)
                end
              end
              return l
            end
            ns.MyBiS:SetWorn(true)
            ns.MyBiS:Refresh()""")
        if lua:
            w.tick(0.3)
            g.eval(lua)
        return g
    return fn


def sim_mode(run=True, stale=False, picker=False, meta_off=False, running=False, nerd=None, history=None):
    """My BiS in Sim mode (UI/SimPanel.lua): Gina in WoWSims' P1 Ret gear, Hourglass in the Working set's Trinket 1,
    a short run against My gear; stale = a slot changed after the run; picker = Trinket 1's picker after Best;
    history = Recent runs (UI/SimHistory.lua) after two earlier runs (Abacus, then two trinkets swapped): "two" = the
    newest two compared, "one" = the newest alone, "link" = the result page with its Recent runs link."""
    def fn(w, c):
        g = opened("mybis", "ns.BiS:SetSpec('Retribution'); ns.MyBiS:SetPhase(1, true)")(w, c)
        g.equip(SIM_P1)
        g.set_bags({(0, 1): 28034, (0, 2): 28288})
        if history:
            g.eval("ns.SimRunner.DEFAULT_ITERATIONS = 60; ns.SimPanel:ResetTo(ns.SimRunner:EquippedSet()); "
                   "local t1, t2; for i, s in ipairs(ns.SLOTS) do if s.invSlot == 13 then t1 = i end "
                   "if s.invSlot == 14 then t2 = i end end; "
                   "ns.SimPanel:SetWorkingSlot(t1, ns.SimRunner:FillEntry(28288, t1)); ns.SimPanel:Run()")
            for _ in range(400):
                if not g.eval("return ns.SimRunner:IsRunning()"):
                    break
                w.tick(0.05, 0.05)
            g.eval("local t1, t2; for i, s in ipairs(ns.SLOTS) do if s.invSlot == 13 then t1 = i end "
                   "if s.invSlot == 14 then t2 = i end end; "
                   "ns.SimPanel:SetWorkingSlot(t2, ns.SimRunner:FillEntry(28034, t2)); ns.SimPanel:Run()")
            for _ in range(400):
                if not g.eval("return ns.SimRunner:IsRunning()"):
                    break
                w.tick(0.05, 0.05)
            w.tick(3, 0.05)
        g.eval("ns.SimRunner.DEFAULT_ITERATIONS = 60; ns.SimPanel.PICK_ITERATIONS = 20; "
               "ns.SimPanel:ResetTo(ns.SimRunner:EquippedSet()); "
               "local sid; for i, s in ipairs(ns.SLOTS) do if s.invSlot == 13 then sid = i end end; "
               "ns.SimPanel:SetWorkingSlot(sid, ns.SimRunner:FillEntry(28034, sid)); "
               "ns.SimPanel:SetActive(true); ns.MyBiS:Refresh()")
        w.tick(0.3)
        g.eval("ns.SimStage.holdAt = nil")
        if running:
            g.eval("ns.SimStage.holdAt = 0.62; ns.SimPanel:Run()")
            for _ in range(40):
                w.tick(0.05, 0.05)
            return g
        if run:
            g.eval("ns.SimPanel:Run()")
            for _ in range(400):
                if not g.eval("return ns.SimRunner:IsRunning()"):
                    break
                w.tick(0.05, 0.05)
            # the stage's sweep, the flash and the moves into the result (UI/SimStage.lua)
            for _ in range(80):
                if g.eval("return ns.SimStage.mode ~= 'run' and next(ns.SimStage._tweens()) == nil"):
                    break
                w.tick(0.05, 0.05)
        if meta_off:
            g.eval("local h, s; for i, x in ipairs(ns.SLOTS) do if x.invSlot == 1 then h = i end if x.invSlot == 3 then s = i end end; "
                   "ns.SimPanel:SetWorkingSlot(h, { id = 29073, enchant = 3003, gems = { 32409, 24054 } }); "
                   "ns.SimPanel:SetWorkingSlot(s, { id = 30055, enchant = 2986, gems = { 24027 } }); "
                   "ns.SimPanel._state().stale = false; ns.SimPanel:UpdateCard()")
        if stale:
            g.eval("local sid; for i, s in ipairs(ns.SLOTS) do if s.invSlot == 1 then sid = i end end; "
                   "ns.SimPanel:SetWorkingSlot(sid, ns.SimRunner:FillEntry(32235, sid)); ns.MyBiS:Refresh()")
        if picker:
            g.eval("local sid; for i, s in ipairs(ns.SLOTS) do if s.invSlot == 13 then sid = i end end; "
                   "ns.SimPanel:OnSlotClick(sid, 'main', 'LeftButton', nil, ns.MyBiS:GetPanel()); ns.SimPanel._runBest()")
            for _ in range(400):
                if not g.eval("return ns.SimRunner:IsRunning()"):
                    break
                w.tick(0.05, 0.05)
        if nerd:
            if nerd == "stats":
                g.eval("ns.SimNerd:CalcWeights()")
                for _ in range(400):
                    if not g.eval("return ns.SimRunner:IsRunning()"):
                        break
                    w.tick(0.05, 0.05)
            g.eval("ns.SimNerd:Open('%s')" % nerd)
            w.tick(0.8, 0.05)
        if history == "gems":
            g.eval("local sid; for i, s in ipairs(ns.SLOTS) do if s.invSlot == 1 then sid = i end end "
                   "T_TILE = nil local function walk(f) if f.strip and f.sid == sid and f.mainID then T_TILE = f end "
                   "for _, ch in ipairs({ f:GetChildren() }) do walk(ch) end end walk(UIParent) "
                   "ns.SimPanel:OpenGems(sid, T_TILE) local f = ns.GemEditor:GetFrame() f.choices[1]:Click()")
            w.tick(0.5, 0.05)
        if history in ("one", "two"):
            g.eval("ns.SimHistoryUI:Open()")
            if history == "one":
                g.eval("ns.SimHistoryUI:Pick(ns.SimHistoryUI._picked()[2])")
            w.tick(0.8, 0.05)
        w.tick(0.3)
        return g
    return fn


def kit_view(run=False, spec="Retribution", lua=None):
    """My BiS > Consumables (UI/KitView.lua): Gina in WoWSims' P1 Ret gear, a flask, Haste Potions and Ravager Dogs in
    her bags; run = after a short kit sim."""
    def fn(w, c):
        g = opened("mybis", "ns.BiS:SetSpec('%s'); ns.MyBiS:SetPhase(1, true)" % spec)(w, c)
        g.equip(SIM_P1)
        g.set_bags({(0, 1): (22854, 2), (0, 2): (22838, 5), (0, 3): (27655, 6), (0, 4): (22832, 2)})
        g.eval("ns.Kit.ITERATIONS = 12; ns.Kit:ClearResults(); ns.KitView:SetActive(true)")
        g.eval("ns.Azero.clockHour = 12")                 # by day, unless the state says otherwise
        if lua:
            g.eval(lua)
        w.tick(0.3)
        if run:
            g.eval("ns.KitView:Run()")
            for _ in range(600):
                if not g.eval("return ns.Kit:IsRunning()"):
                    break
                w.tick(0.05, 0.05)
        w.tick(0.3)
        return g
    return fn


def sim_buffs(kind):
    """The gear sim's buffs (Sim/BuffPresets.lua, UI/SimBuffs.lua) on Gina's screen, after the teams seed (she is in
    group 5 of the main team's Thursday 25, with its Standard 25 comp: open slots): kind "menu" = the card's buffs
    menu with two presets of hers; "team" = the editor following the Thursday 25; "preset" = the editor on a preset."""
    def fn(w, c):
        teams_seed(w, c)
        teams_comp(w, c, True)
        g = sim_mode(run=False)(w, c)
        g.eval("for _, p in ipairs(ns.SimBuffs:GetPresets()) do ns.SimBuffs:DeletePreset(p.id) end; "
               "ns.SimBuffs:SavePreset(nil, 'Pug SSC', ns.SimRunner:BaseConfig('raid10')); "
               "ns.SimBuffs:SavePreset(nil, 'Kara alts', ns.SimRunner:BaseConfig('solo'))")
        if kind == "menu":
            g.eval("ns.SimPanel:SetBuffs(ns.SimBuffs:MyLineups()[1].key); ns.SimPanel._card().buffs:OpenMenu()")
        elif kind == "team":
            g.eval("ns.SimBuffsUI:Open(ns.SimBuffs:MyLineups()[1].key)")
        else:
            g.eval("ns.SimBuffsUI:Open(ns.SimBuffs:GetPresets()[2].key)")
        w.tick(0.3)
        return g
    return fn


def st_blizzard_options(w, c):
    """DisasterZone's panel in Blizzard's Options > AddOns (UI/Settings.lua), at the canvas size the game gives it."""
    g = c["Gina"]
    demo_off(w, c)
    close_all(g)
    g.eval("__MOCK.real_geometry = true; local f = DisasterZoneBlizzardOptions; f:SetParent(UIParent); f:ClearAllPoints(); "
           "f:SetPoint('CENTER'); f:SetSize(680, 600); f:Hide(); f:Show()")   # measured in game 2026-10-11
    w.tick(0.8)
    return g


SWING_HUD = ("__MOCK.real_geometry = true; __MOCK.swing_speed = 3.5; "
             "local names = { [20375] = 'Seal of Command', [31892] = 'Seal of Blood', [35395] = 'Crusader Strike', "
             "[20271] = 'Judgement', [879] = 'Exorcism', [26573] = 'Consecration', [24275] = 'Hammer of Wrath' }; "
             "local old = GetSpellInfo; GetSpellInfo = function(x, ...) if names[x] then return names[x] end "
             "for _, n in pairs(names) do if n == x then return n end end return old(x, ...) end; "
             "UnitCreatureType = function() return 'Demon' end; GetSpellTexture = function() return nil end; "
             "local ST = ns.SwingTimer; ST.IsRet = function() return true end; ns.DB:SetSetting('swing.idle', true); "
             "ns.DB:SetSetting('swing.style', 'STYLE'); ST:Refresh(); "
             "ST.state.seal = 'soc'; ST.state.last = GetTime() - %s; ST.state.sealExpires = GetTime() + 22; "
             "for i, k in ipairs({ 'twist', 'twist', 'late', 'twist', 'plain', 'twist', 'clip', 'twist', 'twist' }) do "
             "ST:Recent()[i] = { t = 0, kind = k } end; ns.SwingTimerHUD:Update()")


# Shot timer (Core/ShotTimer.lua, UI/ShotTimerHUD.lua): Gina as a Hunter with a 3.0 bow at 2.2 s, Hawk up, nothing on
# cooldown, the last Auto Shot %s s ago.
SHOT_HUD = ("__MOCK.real_geometry = true; __MOCK.ranged_speed = 2.2; "
            "local names = { [75] = 'Auto Shot', [34120] = 'Steady Shot', [27021] = 'Multi-Shot', [27019] = 'Arcane Shot', "
            "[34026] = 'Kill Command', [27044] = 'Aspect of the Hawk', [34074] = 'Aspect of the Viper' }; "
            "local old = GetSpellInfo; GetSpellInfo = function(x, ...) if names[x] then return names[x] end "
            "for _, n in pairs(names) do if n == x then return n end end return old(x, ...) end; "
            "__MOCK.spell_cd = __MOCK.spell_cd or {}; "
            "for id, n in pairs(names) do __MOCK.known_spells[id] = true; __MOCK.spell_cd[n] = { 0, 0 } end; "
            "__MOCK.fire('SPELLS_CHANGED'); GetSpellTexture = function() return nil end; "
            "local ST = ns.ShotTimer; ST.IsMine = function() return true end; ST.Haste = function() return 3.0 / 2.2 end; "
            "ns.DB:SetSetting('shot.idle', true); ns.DB:SetSetting('shot.style', 'STYLE'); ST:Refresh(); "
            "ST.state.aspect = 'hawk'; ST.state.auto = true; ST.OnShot(GetTime() - %s); ns.ShotTimerHUD:Update()")



# The Dock (UI/LookDock.lua): the game's bottom bars stood in for (containers of 45 px buttons with a Ret paladin's
# icons, 3 stances, bags, menu), the bars part in look LOOK, then the Dock laid out.
DOCK_ICONS = ["Spell_Holy_CrusaderStrike", "Spell_Holy_RighteousFury", "Ability_Warrior_InnerRage", "Spell_Holy_SealOfBlood",
              "Spell_Holy_Excorcism_02", "Spell_Holy_InnerFire", "Ability_ThunderClap", "Spell_Holy_SealOfMight",
              "Spell_Holy_AvengersShield", "INV_Potion_108", "INV_Potion_137", "INV_Misc_Drum_02",
              "Spell_Holy_HolyBolt", "Spell_Holy_FlashHeal", "Spell_Holy_Renew", "Spell_Holy_SealOfValor",
              "Spell_Holy_SealOfProtection", "Spell_Holy_DivineIntervention", "Spell_Holy_LayOnHands",
              "Spell_Holy_PrayerOfHealing", "Spell_Holy_TurnUndead", "Ability_ThunderBolt", "Spell_Holy_RighteousnessAura",
              "Spell_Holy_HealingAura"]
DOCK_STATE = (
    "local ICONS = { " + ", ".join("'Interface\\\\Icons\\\\%s'" % n for n in DOCK_ICONS) + " }; "
    "local function Bar(name, prefix, n, shown, size, off) "
    "  local bar = CreateFrame('Frame', name, UIParent); bar:SetSize(500, 50); bar:SetPoint('BOTTOM'); "
    "  for i = 1, n do "
    "    local cont = CreateFrame('Frame', name .. 'ButtonContainer' .. i, bar); cont:SetSize(size or 45, size or 45); "
    "    cont:SetPoint('LEFT', bar, 'LEFT', (i - 1) * 47, 0); "
    "    local b = CreateFrame('CheckButton', prefix .. i, cont); b:SetSize(size or 45, size or 45); b:SetPoint('CENTER'); "
    "    b.container, b.index = cont, i; b.icon = b:CreateTexture(nil, 'ARTWORK'); b.icon:SetAllPoints(); "
    "    if (i + (off or 0)) % 7 ~= 0 then b.icon:SetTexture(ICONS[((i + (off or 0)) % #ICONS) + 1]) end; "
    "    b.HotKey = b:CreateFontString(nil, 'OVERLAY', 'NumberFontNormalSmallGray'); b.HotKey:SetText(off == 0 and tostring(i % 10) or (off == 12 and 'S' .. (i % 10) or '')); "
    "    b.Count = b:CreateFontString(nil, 'OVERLAY', 'NumberFontNormal'); "
    "    b.action = i + (off or 0); function b:Update() end; function b:UpdateUsable() end; "
    "  end; bar:SetShown(shown); return bar "
    "end; "
    "if not _G.DisasterZoneDockFakes then DisasterZoneDockFakes = true; "
    "Bar('MainActionBar', 'ActionButton', 12, true, nil, 0); Bar('MultiBarBottomLeft', 'MultiBarBottomLeftButton', 12, true, nil, 12); "
    "Bar('MultiBarBottomRight', 'MultiBarBottomRightButton', 12, true, nil, 5); Bar('MultiBarRight', 'MultiBarRightButton', 12, true, nil, 9); "
    "Bar('StanceBar', 'StanceButton', 10, true, 30, 20); for i = 4, 10 do _G['StanceButton' .. i].container:Hide() end; "
    "ActionButton3.GetChecked = function() return true end; "
    "local bags = CreateFrame('Frame', 'BagsBar', UIParent); bags:SetSize(200, 40); bags:SetPoint('BOTTOMRIGHT'); "
    "for _, n in ipairs({ 'MainMenuBarBackpackButton', 'CharacterBag0Slot', 'CharacterBag1Slot', 'CharacterBag2Slot', 'CharacterBag3Slot', 'KeyRingButton' }) do "
    "  local b = CreateFrame('Button', n, bags); b:SetSize(40, 40); b:SetPoint('LEFT'); b.Icon = b:CreateTexture(); "
    "  b.Icon:SetTexture('Interface\\\\Icons\\\\INV_Misc_Bag_10_Blue') end; "
    "local menu = CreateFrame('Frame', 'MicroMenuContainer', UIParent); menu:SetSize(300, 40); menu:SetPoint('BOTTOMRIGHT'); "
    "for _, n in ipairs({ 'CharacterMicroButton', 'SpellbookMicroButton', 'TalentMicroButton', 'QuestLogMicroButton', "
    "  'SocialsMicroButton', 'GuildMicroButton', 'WorldMapMicroButton', 'LFGMicroButton', 'PVPMicroButton', 'MainMenuMicroButton', 'HelpMicroButton' }) do "
    "  local b = CreateFrame('Button', n, menu); b:SetSize(28, 36); b:SetPoint('LEFT') end; end; "
    "ns.DB:SetSetting('ui.bars.look', 'LOOK'); ns.Look:SetApplied('bars', 'LOOK'); ns.LookBars:Restyle(); "
    "ns.LookDock:Start(); ns.LookDock:Layout(); ns.MainFrame:Close()")


# Bags (UI/LookBags.lua): Gina's bags filled with a Ret paladin's items (icons by item id), the bags part in look
# LOOK and layout LAYOUT, the Bags window open.
BAGS_STATE = (
    "local D = __MOCK.define_item; "
    "D(28830, 'Dragonspine Trophy', 4, 'INVTYPE_NON_EQUIP_IGNORE', 4, 0, 'itemicon:28830'); "
    "D(29383, 'Bloodlust Brooch', 4, 'INVTYPE_NON_EQUIP_IGNORE', 4, 0, 'itemicon:29383'); "
    "D(22838, 'Haste Potion', 1, 'INVTYPE_NON_EQUIP_IGNORE', 0, 0, 'itemicon:22838'); "
    "D(22832, 'Super Mana Potion', 1, 'INVTYPE_NON_EQUIP_IGNORE', 0, 0, 'itemicon:22832'); "
    "D(22854, 'Flask of Relentless Assault', 1, 'INVTYPE_NON_EQUIP_IGNORE', 0, 0, 'itemicon:22854'); "
    "D(30106, 'Belt of One-Hundred Deaths', 4, 'INVTYPE_NON_EQUIP_IGNORE', 4, 0, 'itemicon:30106'); "
    "D(27658, 'Roasted Clefthoof', 1, 'INVTYPE_NON_EQUIP_IGNORE', 0, 0, 'itemicon:27658'); "
    "D(23445, 'Fel Iron Bar', 1, 'INVTYPE_NON_EQUIP_IGNORE', 7, 0, 'itemicon:23445'); "
    "D(21877, 'Netherweave Cloth', 1, 'INVTYPE_NON_EQUIP_IGNORE', 7, 0, 'itemicon:21877'); "
    "D(28429, 'Lionheart Champion', 4, 'INVTYPE_NON_EQUIP_IGNORE', 2, 0, 'itemicon:28429'); "
    "D(29529, 'Drums of Battle', 3, 'INVTYPE_NON_EQUIP_IGNORE', 0, 0, 'itemicon:29529'); "
    "D(22450, 'Void Crystal', 4, 'INVTYPE_NON_EQUIP_IGNORE', 7, 0, 'itemicon:22450'); "
    "D(21884, 'Primal Fire', 2, 'INVTYPE_NON_EQUIP_IGNORE', 7, 0, 'itemicon:21884'); "
    "D(24027, 'Bold Living Ruby', 3, 'INVTYPE_NON_EQUIP_IGNORE', 3, 0, 'itemicon:24027'); "
    "D(23441, 'Nightseye', 3, 'INVTYPE_NON_EQUIP_IGNORE', 3, 0, 'itemicon:23441'); "
    "D(29760, 'Helm of the Fallen Champion', 4, 'INVTYPE_NON_EQUIP_IGNORE', 12, 0, 'itemicon:29760'); "
    "D(3300, 'Rabbit\\'s Foot', 0, 'INVTYPE_NON_EQUIP_IGNORE', 15, 0, 'itemicon:3300'); "
    "D(4865, 'Ruined Pelt', 0, 'INVTYPE_NON_EQUIP_IGNORE', 15, 0, 'itemicon:4865'); "
    "__MOCK.bags[1] = __MOCK.bags[1] or { size = 16, slots = {} }; __MOCK.bags[1].size = 16; "
    "__MOCK.set_bags({ { 0, 1, 28830, 1 }, { 0, 2, 29383, 1 }, { 0, 3, 22838, 10 }, { 0, 4, 22832, 14 }, { 0, 5, 22854, 4 }, { 0, 6, 30106, 1 }, { 0, 7, 27658, 20 }, { 0, 8, 23445, 14 }, { 0, 9, 21877, 20 }, { 0, 10, 28429, 1 }, { 0, 11, 29529, 2 }, { 0, 12, 22450, 2 }, { 0, 13, 21884, 7 }, { 0, 14, 24027, 2 }, { 1, 1, 23441, 3 }, { 1, 2, 29760, 1 }, { 1, 3, 3300, 2 }, { 1, 4, 4865, 5 } }); "
    "ns.DB:SetSetting('ui.bags.look', 'LOOK'); ns.DB:SetSetting('ui.bags.layout', 'LAYOUT'); "
    "ns.Look:SetApplied('bags', 'LOOK'); ns.LookBags:Start(); ns.MainFrame:Close(); ns.LookBags:Open('bags'); "
    "ns.LookBags:Refresh('bags')")

# Twist practice: Gina as a Ret paladin with keys on her bars, some lessons done.
PRACTICE = (SWING_HUD.replace("ST.state.seal = 'soc'; ST.state.last = GetTime() - %s; ST.state.sealExpires = GetTime() + 22; ", "")
            .replace("ns.SwingTimerHUD:Update()", "")
            .replace("ns.DB:SetSetting('swing.idle', true); ", "").replace("STYLE", "bar") +
            "__MOCK.swing_speed = 3.6; __MOCK.actions[2] = { 'spell', 20375 }; __MOCK.actions[3] = { 'spell', 31892 }; "
            "__MOCK.actions[1] = { 'spell', 35395 }; __MOCK.actions[4] = { 'spell', 20271 }; "
            "__MOCK.bindings = { { 'ACTIONBUTTON1', '1' }, { 'ACTIONBUTTON2', '2' }, { 'ACTIONBUTTON3', '3' }, "
            "{ 'ACTIONBUTTON4', 'SHIFT-E' } }; "
            "local me = UnitName('player') .. '-' .. GetRealmName(); "
            "ns.DB:SetSetting('swing.practice.best', { [me] = { twist = { stars = 3, grade = 0.97, score = 900 }, "
            "command = { stars = 2, grade = 0.86, score = 1100 } } }); ")
# ... played into lesson 3 by a near-perfect player (a bot pressing what the ring asks, one twist skipped) until just
# after the 5th swing, so the word for it shows. (The world ticks: the harness resets the clock to the world's.)
# The ring sits lower in its frame here only so the render has room for the coach card over it.
PRACTICE_BOT = (
    "ns.MainFrame:Close(); local f = DisasterZoneSwingTimer; local SP, ST = ns.SwingPractice, ns.SwingTimer; "
    "SP:Start('strike'); f:SetHeight(470); f.bar:ClearAllPoints(); f.bar:SetPoint('TOP', f, 'TOP', 0, -150); "
    "local pressed = {}; local bot = CreateFrame('Frame'); "
    "bot:SetScript('OnUpdate', function() local run = SP.run; if not run or _G.__pracDone then return end; "
    "  if GetTime() < run.go then return end; local cur = ST:Current(); local s = cur and cur.plan.steps[1]; "
    "  if s and s.key ~= 'wait' and s.at <= GetTime() + 0.001 and pressed[s.key] ~= s.at then pressed[s.key] = s.at; "
    "    if not (s.key == 'sob' and #run.results == 2) then SP:Press(s.key) end end; "
    "  if #run.results >= 5 and GetTime() >= run.vLast + 0.3 then _G.__pracDone = true end end)")


def practice_play(w, c):
    g = c["Gina"]
    demo_off(w, c)
    close_all(g)
    tab(g, "home")
    w.tick(0.3)
    g.eval(PRACTICE)
    g.fire("SPELLS_CHANGED")
    g.eval(PRACTICE_BOT)
    for _ in range(2000):
        if g.eval("return _G.__pracDone == true"):
            break
        w.tick(0.03, step=0.03)
    return g


PRACTICE_RESULT = PRACTICE + (
    "__MOCK.fire('SPELLS_CHANGED'); ns.MainFrame:Close(); local SP = ns.SwingPractice; "
    "local res = { lesson = 'strike', n = 3, title = 'Crusader Strike', score = 1480, ideal = 1650, grade = 0.897, "
    "stars = 2, expected = 10, twists = 8, swings = 10, bestStreak = 5, ghostCs = 6, ghostJudge = 0, done = true, newBest = true, "
    "counts = { twist = 8, perfect = 6, early = 1, late = 0, miss = 0, clip = 1, nocmd = 0, cs = 5, judge = 0 }, "
    "offsets = { { d = -0.31, kind = 'perfect' }, { d = -0.22, kind = 'perfect' }, { d = -0.55, kind = 'early' }, "
    "{ d = -0.27, kind = 'perfect' }, { d = -0.03, kind = 'twist' }, { d = -0.18, kind = 'perfect' }, "
    "{ d = -0.36, kind = 'twist' }, { d = -0.25, kind = 'perfect' }, { d = -0.29, kind = 'perfect' } } }; "
    "ns.SwingPracticeUI:ShowResult(res); local r = DisasterZoneSwingPractice.content and nil; "
    "__MOCK.now = __MOCK.now + 2; ns.SwingPracticeUI:AnimateResult(ns.SwingPracticeUI:Frame().result)")

TIP_ITEM = ("local it = ns.Prized:GetItems()[1]; local id = it and it.ids[1] or 32385; "
            "local sid = ns.ItemDB:GetSlotsForItem(id)[1]; if sid then ns.BiS:SetSlot(1, sid, 'main', id) end; "
            "ns.Tooltip:Invalidate(); GameTooltip:SetOwner(UIParent, 'ANCHOR_NONE'); GameTooltip:ClearAllPoints(); "
            "GameTooltip:SetPoint('CENTER', UIParent, 'CENTER'); GameTooltip:SetItemByID(id)")

MET = ("ns.Demo:SetEnabled(true); ns.DB:SetSetting('meters.dmg', true); ns.DB:SetSetting('meters.thr', true); "
       "ns.MeterPanels:ResetLayout(); ")
# (the class tool bars off, so a meter render shows only the meters)
METQ = ("ns.DB:SetSetting('meters.ooc', 'stay'); for _, k in ipairs({ 'bless', 'totems', 'swing' }) do pcall(function() ns.ClassKit:SetOn(k, false) end) end; ")
# (an invisible named frame around the first stack: ui_look crops a render to named windows)
METBOX = ("local s1 = ns.MeterPanels._Stacks()[1]; local bx = _G.AuditMeterBox or CreateFrame('Frame', 'AuditMeterBox', UIParent); "
          "bx:ClearAllPoints(); bx:SetPoint('TOPLEFT', s1, 'TOPLEFT', -24, 24); bx:SetPoint('BOTTOMRIGHT', s1, 'BOTTOMRIGHT', 24, -24); bx:Show()")

STATES = [
    ("Blizzard options panel", st_blizzard_options),
    ("Home", opened("home")),
    # the nav strip's group menus (UI/Menu.lua's page list: title over its line, the open page with the gold bar)
    ("Nav - Guild menu", opened("home", "__MOCK.real_geometry = true; for _, t in ipairs(DisasterZoneMainFrame.Tabs) "
                                             "do if t.cdlKey == 'grp:guild' then t.IsMouseOver = function() return true end; t:Click(); ns.MainFrame:OpenGroupMenu('grp:guild') end end")),
    ("Nav - Gear menu", opened("mybis", "__MOCK.real_geometry = true; for _, t in ipairs(DisasterZoneMainFrame.Tabs) "
                                         "do if t.cdlKey == 'grp:gear' then t.IsMouseOver = function() return true end; t:Click(); ns.MainFrame:OpenGroupMenu('grp:gear') end end")),
    ("Nav - Gear menu, Gear sim", opened("gearsim", "__MOCK.real_geometry = true; for _, t in ipairs(DisasterZoneMainFrame.Tabs) "
                                         "do if t.cdlKey == 'grp:gear' then t.IsMouseOver = function() return true end; t:Click(); ns.MainFrame:OpenGroupMenu('grp:gear') end end; ns.NavMenu:Focus('consumables')")),
    ("Nav - Raids menu", opened("home", "__MOCK.real_geometry = true; for _, t in ipairs(DisasterZoneMainFrame.Tabs) "
                                           "do if t.cdlKey == 'grp:raids' then t.IsMouseOver = function() return true end; t:Click(); ns.MainFrame:OpenGroupMenu('grp:raids') end end")),
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
    # Equipped (Core/WornGems.lua): Gina in P1 Ret gear, half of it socketed / enchanted with the guide's picks;
    # then Suggest's plan for the rest (two items left unplanned), and the editor on the gloves' worn host
    ("My BiS - equipped", worn_view()),
    ("My BiS - equipped, to apply", worn_view("ns.WornGems:Fill(nil, 1, false); "
        "local eq = ns.WornGems:Equipped(); ns.WornGems:ClearPlan(eq[10] and eq[10].id); "
        "ns.WornGems:ClearPlan(eq[4] and eq[4].id); ns.MyBiS:Refresh()")),
    ("My BiS - equipped, gem editor", worn_view("ns.WornGems:Fill(nil, 1, false); ns.MyBiS:Refresh(); "
        "local function find(f) if f.strip and f.sid == 7 then return f end for _, ch in ipairs({ f:GetChildren() }) "
        "do local r = find(ch) if r then return r end end end local t = find(UIParent); "
        "t.strip:GetScript('OnClick')(t.strip, 'LeftButton')")),
    # gem quality (feedback #4): P3 filled with Uncommon gems, the editor on the head (the switch on Uncommon, the meta
    # still active); the Suggest menu with Epic / Rare / Uncommon
    ("My BiS - gem editor uncommon", opened("mybis", "ns.MyBiS:ApplySuggestion(3, true); ns.MyBiS:SetPhase(3, true); "
        "ns.Gems:FillPhase(3, nil, true, 2); ns.MyBiS:Refresh(); local function find(f) if f.strip and f.sid == 1 "
        "and f.mainID then return f end for _, ch in ipairs({ f:GetChildren() }) do local r = find(ch) "
        "if r then return r end end end local t = find(UIParent); ns.GemEditor:Open(t, t.mainID, 3)")),
    ("My BiS - Suggest menu", opened("mybis", "ns.MyBiS:ApplySuggestion(3, true); ns.MyBiS:SetPhase(3, true); "
        "__MOCK.real_geometry = true; local function find(f) local fs = f.GetFontString and f:GetFontString() "
        "if fs and fs:GetText() == 'Suggest' and f:IsVisible() then return f end "
        "for _, ch in ipairs({ f:GetChildren() }) do local r = find(ch) if r then return r end end end "
        "find(UIParent):Click()")),
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
    # gear sim mockup base: Gina's main list as Retribution with WoWSims' Ret P1 preset (tools/gearsim)
    ("My BiS - Ret P1 (sim base)", opened("mybis", "ns.BiS:SetSpec('Retribution'); "
     "for sid, id in ipairs({29073, 28745, 29075, 24259, 29071, 28795, 30644, 28779, 30257, 28608, 28757, 30834, "
     "29383, 28830, 28429, 0, 27484}) do if id > 0 then ns.BiS:SetSlot(1, sid, 'main', id) end end; "
     "ns.MyBiS:SetPhase(1, true); ns.MyBiS:Refresh()")),
    ("My BiS - Ret P1 working (sim base)", opened("mybis", "ns.BiS:SetSpec('Retribution'); "
     "for sid, id in ipairs({29073, 28745, 29075, 24259, 29071, 28795, 30644, 28779, 30257, 28608, 28757, 30834, "
     "28034, 28830, 28429, 0, 27484}) do if id > 0 then ns.BiS:SetSlot(1, sid, 'main', id) end end; "
     "ns.MyBiS:SetPhase(1, true); ns.MyBiS:Refresh()")),
    ("My BiS - Sim before run", sim_mode(run=False)),
    ("My BiS - Sim running", sim_mode(running=True)),
    ("My BiS - Sim results", sim_mode()),
    ("My BiS - Sim stale", sim_mode(stale=True)),
    ("My BiS - Sim nerd overview", sim_mode(nerd="overview")),
    ("My BiS - Sim nerd abilities", sim_mode(nerd="abilities")),
    ("My BiS - Sim nerd buffs", sim_mode(nerd="buffs")),
    ("My BiS - Sim nerd mana", sim_mode(nerd="mana")),
    ("My BiS - Sim nerd stats", sim_mode(nerd="stats")),
    ("My BiS - Sim nerd run", sim_mode(nerd="run")),
    ("My BiS - Sim meta off", sim_mode(meta_off=True)),
    ("My BiS - Sim picker", sim_mode(picker=True)),
    ("My BiS - Sim recent runs", sim_mode(history="two")),
    ("My BiS - Sim recent runs one", sim_mode(history="one")),
    ("My BiS - Sim results recent link", sim_mode(history="link")),
    ("My BiS - Sim gem editor", sim_mode(history="gems")),
    ("My BiS - Consumables", kit_view()),
    ("My BiS - Consumables simmed", kit_view(run=True)),
    ("My BiS - Consumables healer", kit_view(spec="Holy")),
    ("My BiS - Consumables picker", kit_view(lua="ns.Kit:SetPick('best', 'food', { 33872 }); "
                                               "ns.KitView:OpenPicker('best', 'flask', ns.MyBiS:GetPanel())")),
    ("My BiS - Consumables left out",kit_view(lua="ns.Kit:SetOff('best', 'food', true); ns.Kit:SetOff('budget', 'scroll', true)")),
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
    # the Bingo card mid-game in the Serpentshrine deck: a complete row (the slam settled), column O one square away,
    # who set squares off, the race and the moments
    ("Games - Bingo card live", opened("games", BINGO_LIVE + "ns.GamesUI:Select('bingo')")),
    # a legendary goes off: the takeover over the card (Fated lights the square it daubed)
    ("Games - Bingo legendary", opened("games", BINGO_LIVE + BINGO_LEGENDARY + "ns.GamesUI:Select('bingo') "
                                       "ns.BingoUI:ShowTakeover(T_BINGO.leg, 'Lainatukka') ns.UI:StopTween('bingoTakeover') "
                                       "W_TO = ns.BingoUI:GetWidgets().takeover W_TO:SetAlpha(1)")),
    # an epic moment's toast on screen (the window closed)
    ("Games - Bingo epic toast", opened("games", BINGO_LIVE + "ns.MainFrame:Close() "
                                        "ns.BingoUI:ToastMoment('ankh', 'Saltykim')")),
    # demo mode with no game of your own: the made-up game in the SSC deck and the "Try a moment" action
    ("Games - Bingo demo", opened("games", "ns.Games:GetData('bingo').current = nil ns.Demo:SetEnabled(true) "
                                  "ns.GamesUI:Select('bingo')")),
    # the Codex: the season ladder, the legendaries witnessed, the set with what this character has seen
    ("Games - Bingo codex", opened("games", BINGO_LIVE + BINGO_CODEX + "ns.GamesUI:Select('bingo') "
                                   "ns.BingoUI:SetView('codex')")),
    ("Games - Raid Trainer", opened("games", "ns.GamesUI:Select('trainer')")),
    ("Games - Azeromon", opened("games", "ns.GamesUI:Select('azeromon')")),
    ("Games - Azeromon title", opened("games", "ns.GamesUI:Select('azeromon') ns.AzeroUI._Focus(true)")),
    ("Games - Azeromon poster Goldshire", azero_poster(1)),
    ("Games - Azeromon poster Elwynn", azero_poster(2)),
    ("Games - Azeromon poster Westfall dusk", azero_poster(3)),
    ("Games - Azeromon poster Darkshire night", azero_poster(4)),
    ("Games - Azeromon poster Stranglethorn", azero_poster(5)),
    ("Games - Azeromon poster Wildshore", azero_poster(6)),
    ("Games - Azeromon poster crossfade", azero_poster(3, 7.2)),
    # (Azeromon's poster on the side: a still of its film, no painting behind it)
    ("Games - Azeromon poster side", opened("games", "ns.GamesUI:ShowFront('chess') ns.GamesUI:PauseAnim(true)")),
    # the overworld on maps with a baked ground (gen_azeromon_ground.py): Goldshire's square, Route 1's meadows
    ("Games - Azeromon world map", azero_at("town", 12, 11, "local g = ns.Azero g.save.visited = {} for id in pairs(ns.AzeroMaps) do g.save.visited[id] = true end ns.AzeroWorld:Open() ns.AzeroUI._Focus(true)")),
    # the painted world map (gen_azeromon_worldmap.py): a new game under mist, by night, a place being revealed
    ("Games - Azeromon world map new game", azero_at("route1", 11, 20, "ns.AzeroWorld:Open() ns.AzeroUI._Focus(true)")),
    ("Games - Azeromon world map night", azero_at("sentinel", 5, 9, "ns.Azero.clockHour = 23 ns.Azero:EnterMap('westfall', 5, 5, 'down', true) ns.Azero:EnterMap('sentinel', 5, 9, 'down', true) ns.AzeroWorld:Open() ns.AzeroUI._Focus(true)")),
    ("Games - Azeromon world map reveal", azero_at("route1", 11, 20, "ns.AzeroWorld:Open() ns.AzeroUI._HandleKey('B') ns.Azero:EnterMap('forestedge', 5, 5, 'down', true) ns.AzeroUI._HandleKey('START') ns.AzeroWorld:Open() ns.AzeroWorld.frame.clock = ns.AzeroWorld.frame.clock + 1.1 ns.AzeroWorld:Animate(0) ns.AzeroUI._Focus(true)")),
    ("Games - Azeromon Goldshire", azero_at("town", 12, 11)),
    ("Games - Azeromon Goldshire edge", azero_at("town", 2, 8)),
    ("Games - Azeromon start menu night", azero_menu(1)),
    ("Games - Azeromon start menu dawn", azero_menu(6)),
    ("Games - Azeromon start menu midday", azero_menu(12)),
    ("Games - Azeromon start menu dusk", azero_menu(19)),
    ("Games - Azeromon Goldshire north road", azero_at("town", 17, 2)),
    ("Games - Azeromon Goldshire inn", azero_at("town", 9, 23)),
    ("Games - Azeromon Lion's Pride inside", azero_at("post", 7, 8)),
    # daily routines (Routine.lua): the market at noon, the lamplighter's round at dusk, the night patrol, the inn
    ("Games - Azeromon Goldshire market noon", azero_at("town", 19, 19, "ns.Azero.clockHour = 12 ns.Azero:EnterMap('town', 19, 19, 'down', true)")),
    ("Games - Azeromon Goldshire dusk lamps", azero_at("town", 17, 15, "ns.Azero.clockHour = 18 + 1.5 / 60 ns.Azero:EnterMap('town', 17, 15, 'down', true)")),
    ("Games - Azeromon Goldshire night patrol", azero_at("town", 17, 12, "ns.Azero.clockHour = 23.2 ns.Azero:EnterMap('town', 17, 12, 'down', true)")),
    ("Games - Azeromon Goldshire square", azero_at("town", 18, 12, "ns.Azero.clockHour = 12 ns.Azero:EnterMap('town', 18, 12, 'down', true)")),
    ("Games - Azeromon Goldshire inn at night", azero_at("town", 9, 24, "ns.Azero.clockHour = 22 ns.Azero:EnterMap('town', 9, 24, 'down', true)")),
    ("Games - Azeromon Lion's Pride evening", azero_at("post", 7, 8, "ns.Azero.clockHour = 22 ns.Azero:EnterMap('post', 7, 8, 'down', true)")),
    ("Games - Azeromon Goldshire night", azero_at("town", 13, 10, "ns.Azero.clockHour = 23")),
    ("Games - Azeromon Route 1 meadow", azero_at("route1", 4, 10)),
    ("Games - Azeromon home", azero_at("home", 4, 5)),
    ("Games - Azeromon battle", azero_battle("route1", 11, 20, "kobling")),
    ("Games - Azeromon fight menu", azero_battle("route1", 11, 20, "kobling", "ns.AzeroUI._HandleKey('A')")),
    ("Games - Azeromon inn evening", azero_at("post", 4, 5, "ns.Azero.clockHour = 21")),
    ("Games - Azeromon Route 1", azero_at("route1", 6, 9)),
    ("Games - Azeromon Darkshire", azero_at("darkshire", 7, 8)),
    # Blackrock (0.25): Lakeshire by day, the Steppes' ash and lava, the mountain's cavern, Thorium Point
    ("Games - Azeromon Lakeshire", azero_at("lakeshire", 12, 10, "ns.Azero.clockHour = 12")),
    ("Games - Azeromon Burning Steppes", azero_at("steppes", 20, 13, "ns.Azero.clockHour = 12")),
    ("Games - Azeromon Blackrock Mountain", azero_at("brm", 18, 13, "ns.Azero.clockHour = 12")),
    ("Games - Azeromon Searing Gorge", azero_at("gorge", 12, 7, "ns.Azero.clockHour = 12")),
    # the Guild Hall: by day from the dais steps (wings shut, nothing killed); at night in Karazhan's wing with
    # Karazhan, Gruul and Magtheridon cleared; down the nave by the rotunda
    ("Games - Azeromon Guild Hall", azero_at("hideout", 17, 8)),
    ("Games - Azeromon Guild Hall night", azero_at("hideout", 10, 10, "local now = GetServerTime() local b = {} for _, e in ipairs({ 649, 650, 651, 652, 653, 654, 655, 656, 657, 658, 659, 660, 661, 662 }) do b[#b + 1] = { enc = e, ts = now - 86400 * 3, dur = 300 } end ns.db.raids.aud = { id = 'aud', start = now - 86400 * 3, stop = now - 86400 * 3 + 9000, zone = 'Karazhan', att = {}, bosses = b } ns.AzeroHideout.Invalidate() ns.Azero:EnterMap('hideout', 10, 10, 'down', true) ns.Azero.clockHour = 23")),
    ("Games - Azeromon Guild Hall rotunda", azero_at("hideout", 17, 22, "local now = GetServerTime() local b = {} for _, e in ipairs({ 649, 650, 651, 652, 653, 654, 655, 656, 657, 658, 659, 660, 661, 662 }) do b[#b + 1] = { enc = e, ts = now - 86400 * 3, dur = 300 } end ns.db.raids.aud = { id = 'aud', start = now - 86400 * 3, stop = now - 86400 * 3 + 9000, zone = 'Karazhan', att = {}, bosses = b } ns.AzeroHideout.Invalidate()  ns.Azero.clockHour = 12")),
    # Karazhan Chess (Games/Chess): the lobby with games in every state; a game against Medivh mid-way with his fire
    # on two of your pieces and his line (the flat board: the audit has no 3D rooms); the guild ladder
    ("Games - Chess lobby", opened("games", CHESS_GAMES + "ns.Chess:Prefs().flat = true ns.GamesUI:Select('chess') "
                                   "ns.ChessUI:OpenLobby()")),
    ("Games - Chess game", opened("games", CHESS_GAMES + "ns.Chess:Prefs().flat = true ns.GamesUI:Select('chess') "
                                  "ns.ChessUI:OpenGame(T_AUD.g) ns.ChessUI._Note(T_AUD.g.events[1]) "
                                  "ns.ChessUI.Say({ 'Time for an alternative scenario.' }) ns.ChessUI._OnSquare(ns.ChessRules.ParseSquare('f3'))")),
    # ... with the moves drawer open; a finished game's card (Medivh mated as Black in four)
    ("Games - Chess moves", opened("games", CHESS_GAMES + "ns.Chess:Prefs().flat = true ns.Chess:Prefs().moves = true "
                                   "ns.GamesUI:Select('chess') ns.ChessUI:OpenGame(T_AUD.g)")),
    ("Games - Chess over", opened("games", CHESS_GAMES + "ns.Chess:Prefs().flat = true ns.Chess:Prefs().moves = nil "
                                  "ns.GamesUI:Select('chess') ns.ChessUI:OpenGame(ns.Chess:Get('ov1'))")),
    # The Binding of Illidan: the title, a fight in a room, the bosses (god mode, a few seconds in)
    ("Games - Illidan title", opened("games", BOI_BOARD + "ns.GamesUI:Select('illidan') ns.BoIUI._Focus(true) ns.BoIUI._Draw()")),
    ("Games - Illidan grave", opened("games", BOI_BOARD + BOI_AUD + "local r = BOI_AUD.start(1) r.mode = 'play' "
                                     "r.graves = { { f = 1, rx = r.room.x, ry = r.room.y, x = 200, y = 330, who = 'Xiavor', cls = 'MAGE', by = 'Felhunter' } } "
                                     "r.daily, r.counted = ns.BoIBoard:Today(), true BOI_AUD.run(r, 30)")),
    ("Games - Illidan room", opened("games", BOI_AUD + "BOI_AUD.room(1, 120)")),
    ("Games - Illidan Magtheridon", opened("games", BOI_AUD + "BOI_AUD.boss(1, 300)")),
    ("Games - Illidan Supremus", opened("games", BOI_AUD + "BOI_AUD.boss(2, 200, function(f) f.sw = 2 end)")),
    ("Games - Illidan Teron", opened("games", BOI_AUD + "BOI_AUD.boss(3, 330, function(f) f.sodT = 1 end)")),
    ("Games - Illidan Shahraz", opened("games", BOI_AUD + "BOI_AUD.boss(4, 150)")),
    ("Games - Illidan Illidan", opened("games", BOI_AUD + "BOI_AUD.boss(5, 100, function(f, r) f.hp = f.max * 0.64 "
                                       "ns.BoI.Step(r, {}) f.eye = 1 end)")),
    ("Games - Illidan dying", opened("games", BOI_AUD + "BOI_AUD.room(2, 60) local r = ns.BoIUI._Run() r.god = nil "
                                     "r.hp, r.soul, r.p.inv = 1, 0, 0 ns.BoI.Hurt(r, r.room.foes[1].d) "
                                     "for _ = 1, 95 do ns.BoI.Step(r, {}) end ns.BoIUI._Focus(false) ns.BoIUI._Draw()")),
    ("Games - Illidan dead", opened("games", BOI_AUD + "BOI_AUD.room(2, 60) local r = ns.BoIUI._Run() r.god = nil "
                                    "r.items = { 'eye', 'pws', 'chain' } r.hp, r.soul, r.p.inv = 1, 0, 0 ns.BoI.Hurt(r, r.room.foes[1].d) "
                                    "for _ = 1, ns.BoI.DYING + 99 do ns.BoI.Step(r, {}) end r.newBest = true "
                                    "ns.BoIUI._Focus(false) ns.BoIUI._Draw()")),
    # the vault's padlocked portcullis, seen from the room next to it
    ("Games - Illidan vault door", opened("games", BOI_AUD + "local r = BOI_AUD.start(1) local v "
                                          "for _, x in ipairs(r.map.list) do if x.type == 'treasure' then v = x end end "
                                          "local nb = ns.BoI.Neighbours(r.map, v, true)[1] r.room = nb.room r.room.cleared, r.room.foes = true, {} "
                                          "r.p.x, r.p.y = ns.BoI.CX, ns.BoI.CY BOI_AUD.run(r, 10)")),
    # an enemy bursting (a few frames after its death) with tears splashing round it
    # every kind of stain an enemy leaves, a few seconds old (blood, fel, shadow, embers, bone dust; a boss's big one)
    ("Games - Illidan stains", opened("games", BOI_AUD + "BOI_AUD.room(1, 30) local r = ns.BoIUI._Run() r.room.foes = {} "
                                      "r.room.cleared = true r.room.decals = {} local K = { 'brute', 'imp', 'void', 'abyssal', 'dead', 'bat' } "
                                      "for i, k in ipairs(K) do ns.BoI.Die(r, r.room, { kind = k, x = 130 + (i - 1) * 92, y = 150 + (i % 2) * 70, r = 14, d = {} }) end "
                                      "ns.BoI.Die(r, r.room, { kind = 'boss', x = 360, y = 330, r = 26, d = {} }) "
                                      "for _, dc in ipairs(r.room.decals) do dc.t = 240 end r.fx = {} ns.BoIUI._Draw()")),
    ("Games - Illidan burst", opened("games", BOI_AUD + "BOI_AUD.room(1, 90) local r = ns.BoIUI._Run() "
                                     "for i = 1, 2 do if r.room.foes[i] then r.room.foes[i].hp = 0 end end "
                                     "r.room.cleared = true for _ = 1, 7 do ns.BoI.Step(r, { shoot = 'up' }) end ns.BoIUI._Focus(false) r.mode = 'dying' r.dyingT = 999 "
                                     "r.mode = 'play' ns.BoIUI._Focus(true) ns.BoIUI._Draw()")),
    # the poster in front: the game playing itself, four seconds in
    ("Games - Illidan in front", opened("games", "local d = ns.Games:GetData('illidan') d.best, d.runs = 3, 4 "
                                        "ns.GamesUI:ShowHub() ns.GamesUI:ShowFront('illidan') "
                                        "for _, p in ipairs(ns.GamesUI.__posters) do if p.id == 'illidan' then for _ = 1, 240 do p.cover:Tick(1 / 60) end end end")),
    ("Games - Illidan won", opened("games", BOI_AUD + "local r = BOI_AUD.start(5) r.items = { 'eye', 'pws', 'chain', 'glaive', 'mongoose' } "
                                   "r.mode, r.wonT, r.time, r.kills, r.gold = 'won', 99, 1385 * 60, 212, 14 "
                                   "ns.BoIUI._Focus(false) ns.BoIUI._Draw()")),
    ("Games - Chess ladder", opened("games", CHESS_GAMES + CHESS_LADDER + "ns.GamesUI:Select('chess') "
                                    "ns.ChessUI:OpenLobby() ns.ChessUI._Tab('ladder')")),
    ("Games - Chess in front", opened("games", CHESS_GAMES + "ns.Chess:Prefs().flat = nil ns.GamesUI:ShowHub() "
                                      "ns.GamesUI:ShowFront('chess')")),
    # walking diagonally (down-left): the eighth facings
    # talent rows: a level 8 mage with three rows chosen, row 3 open without a choice, row 5 (level 10) locked
    # Deputy Willem's gossip once his first quest is done: the greeting and two quests on the parchment
    # the client's own frames built from Layouts.lua (UILayout.lua), shown as they come
    # inside the Abbey, walked in place: its roof gone, the ground floor cut away over head height; then upstairs
    # down Echo Ridge Mine: its tunnels on black, the kobolds in them
    # outdoors by the Abbey's east end: Eagan Peltskinner under the roof (it fades round him), trees behind it
    # /collision: the solid ~1 yd cells (azw_collide) over the pictures - trunks, props, the Abbey's walls
    # the world map (M) with Northshire and Goldshire explored; the minimap shows in every world view
    # the Games hub's carousel with each game in front; Bingo live (a game running: a line one square away, the
    # square that just filled glowing)
    ("Games - Raid Trainer in front", opened("games", "ns.GamesUI:ShowFront('trainer')")),
    ("Games - Azeromon in front", opened("games", "ns.GamesUI:ShowFront('azeromon')")),
    # its poster's film of Northshire, a moment into each shot (the audit ticks 0.6 s more after the state)
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
    # Guild > Polls (UI/PollsTab.lua, polls_seed): the list, closed polls, answering one, my poll's results, a Pick
    # days poll, the New poll sheet (who votes open; Pick days), the pop-up, a member who isn't asked anything
    ("Polls", polls_view()),
    ("Polls - closed", polls_view("ns.PollsUI:ShowList('closed')")),
    ("Polls - answering", polls_view("local d, yn, raid, night = ...; ns.PollsUI:OpenPoll(night); ns.PollsUI:Pick(2)")),
    ("Polls - results (asker)", polls_view("local _, _, _, _, _, _, loot = ...; ns.PollsUI:OpenPoll(loot)")),
    ("Polls - answered, results wait", polls_view("local _, _, _, _, bank = ...; ns.PollsUI:OpenPoll(bank)")),
    ("Polls - pick days", polls_view("local d = ...; ns.PollsUI:OpenPoll(d); "
                                     "ns.PollsUI:SetDays({ 1, 0, 1, 2, 1 })")),
    ("Polls - new poll, who votes", polls_view(
        "ns.PollsUI:OpenNew(); ns.PollsUI:SetDraft({ q = 'Which consumables should the guild bank stock?', k = 'many', "
        "o = { 'Flasks of Supreme Power', 'Elixirs of Major Agility', 'Super Mana Potions', 'Fel Mana Potions' }, "
        "a = { { 't', ns.RaidPlan:GetTeams()[1].id, false, 'Main team' }, { 'r', 'leader' } } }); "
        "ns.PollsUI:OpenAudience()")),
    ("Polls - new poll, pick days", polls_view(
        "ns.PollsUI:OpenNew(); local t = GetServerTime(); local function d(o) return { d = date('%Y-%m-%d', t + o * 86400), "
        "t = '20:00' } end; ns.PollsUI:SetDraft({ q = 'Which nights can you raid SSC next week?', k = 'days', rv = 'live', "
        "days = { d(3), d(5), d(6), d(8) }, a = { { 'r', 'leader' }, { 'r', 'officer' }, { 'p', 'Lightbringer-' .. ns.Util.GetPlayerRealm() } } })")),
    ("Polls - pop-up", polls_toast),
    # (1.4.1) a poll of three questions: answering it (question 1 answered: it opens on question 2), the asker's
    # results on question 3, the New poll sheet with three questions
    ("Polls - several questions", polls_view("local p = select(8, ...); ns.PollsUI:OpenPoll(p); "
                                             "ns.PollsUI:SetDays({ 1, 2, 1, 0 })")),
    ("Polls - several questions, asker", polls_view("local p = select(10, ...); ns.PollsUI:OpenPoll(p, true)",
                                                    viewer="Grumpykat")),
    ("Polls - new poll, several questions", polls_view(
        "ns.PollsUI:OpenNew(); ns.PollsUI:SetDraft({ cur = 3, a = { { 'g' } }, rv = 'live', qs = { "
        "{ q = 'Would you like a second raid night for progression?', k = 'yn' }, "
        "{ q = 'Which nights would suit you best?', k = 'days' }, "
        "{ q = 'What start time (realm time) suits you?', k = 'one', o = { '19:00', '19:30', '20:00', '20:30' } } } })")),
    # five questions: the tabs share the strip, each with its x
    ("Polls - new poll, five questions", polls_view(
        "ns.PollsUI:OpenNew(); ns.PollsUI:SetDraft({ cur = 5, a = { { 'g' } }, qs = { { q = 'One?', k = 'yn' }, "
        "{ q = 'Two?', k = 'yn' }, { q = 'Three?', k = 'yn' }, { q = 'Four?', k = 'yn' }, "
        "{ q = 'Which night should we move SSC to?', k = 'one', o = { 'Wednesday', 'Thursday' } } } })")),
    # Home with several polls waiting: one chip for them all
    ("Home - polls waiting", polls_view("ns.MainFrame:Open('home')")),
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
    # 1.3.5 compact item tooltip (UI/Tooltip.lua): demo's first prized item, on Gina's BiS list; then with Shift held
    ("Tooltip - item compact", demo(TIP_ITEM)),
    ("Tooltip - item Shift", demo("__MOCK.set_modifiers(true); " + TIP_ITEM)),
    ("Settings - Swing timer", opened("settings", "ns.SettingsUI:SelectSection('swing')")),
    ("Swing timer - both, in the zone", opened("home", "ns.MainFrame:Close(); " + (SWING_HUD % "3.13").replace("STYLE", "both"))),
    ("Swing timer - bar, early swing", opened("home", "ns.MainFrame:Close(); " + (SWING_HUD % "1.2").replace("STYLE", "bar"))),
    ("Swing timer - lane", opened("home", "ns.MainFrame:Close(); " + (SWING_HUD % "2.0").replace("STYLE", "lane"))),
    ("Swing timer theme - sigil", opened("home", "ns.MainFrame:Close(); ns.DB:SetSetting('swing.theme', 'sigil'); " + (SWING_HUD % "3.13").replace("STYLE", "both"))),
    ("Swing timer theme - slate", opened("home", "ns.MainFrame:Close(); ns.DB:SetSetting('swing.theme', 'slate'); " + (SWING_HUD % "3.13").replace("STYLE", "both"))),
    ("Swing timer theme - gilded", opened("home", "ns.MainFrame:Close(); ns.DB:SetSetting('swing.theme', 'gilded'); " + (SWING_HUD % "3.13").replace("STYLE", "both"))),
    ("Swing timer theme - pips", opened("home", "ns.MainFrame:Close(); ns.DB:SetSetting('swing.theme', 'pips'); " + (SWING_HUD % "3.13").replace("STYLE", "both"))),
    ("Shot timer theme - sigil", opened("home", "ns.MainFrame:Close(); ns.DB:SetSetting('shot.theme', 'sigil'); " + (SHOT_HUD % "0.25").replace("STYLE", "both"))),
    ("Shot timer theme - slate", opened("home", "ns.MainFrame:Close(); ns.DB:SetSetting('shot.theme', 'slate'); " + (SHOT_HUD % "0.25").replace("STYLE", "both"))),
    ("Shot timer theme - gilded", opened("home", "ns.MainFrame:Close(); ns.DB:SetSetting('shot.theme', 'gilded'); " + (SHOT_HUD % "0.25").replace("STYLE", "both"))),
    ("Swing timer theme - classic", opened("home", "ns.MainFrame:Close(); ns.DB:SetSetting('swing.theme', 'classic'); " + (SWING_HUD % "3.13").replace("STYLE", "both"))),
    ("Shot timer theme - classic", opened("home", "ns.MainFrame:Close(); ns.DB:SetSetting('shot.theme', 'classic'); " + (SHOT_HUD % "0.25").replace("STYLE", "both"))),
    ("Shot timer theme - pips", opened("home", "ns.MainFrame:Close(); ns.DB:SetSetting('shot.theme', 'pips'); " + (SHOT_HUD % "0.25").replace("STYLE", "both"))),
    ("Dock - flat", opened("home", DOCK_STATE.replace("LOOK", "flat"))),
    ("Dock - halo", opened("home", DOCK_STATE.replace("LOOK", "halo"))),
    ("Dock - sigil", opened("home", DOCK_STATE.replace("LOOK", "sigil"))),
    ("Dock - slate", opened("home", DOCK_STATE.replace("LOOK", "slate"))),
    ("Dock - gilded", opened("home", DOCK_STATE.replace("LOOK", "gilded"))),
    ("Dock - classic", opened("home", DOCK_STATE.replace("LOOK", "classic"))),
    # Classic's Dock art (UI/DockArt.lua): the other two sets (Ironforge is the default above)
    ("Dock - classic stormwind", opened("home", DOCK_STATE.replace("LOOK", "classic").replace(
        "ns.DB:SetSetting('ui.bars.look'", "ns.DB:SetSetting('ui.bars.art', 'stormwind'); ns.DB:SetSetting('ui.bars.look'"))),
    ("Dock - classic vault", opened("home", DOCK_STATE.replace("LOOK", "classic").replace(
        "ns.DB:SetSetting('ui.bars.look'", "ns.DB:SetSetting('ui.bars.art', 'vault'); ns.DB:SetSetting('ui.bars.look'"))),
    ("Bags - flat one", opened("home", BAGS_STATE.replace("LOOK", "flat").replace("LAYOUT", "one"))),
    ("Bags - halo one", opened("home", BAGS_STATE.replace("LOOK", "halo").replace("LAYOUT", "one"))),
    ("Bags - sigil shelves", opened("home", BAGS_STATE.replace("LOOK", "sigil").replace("LAYOUT", "shelves"))),
    ("Bags - slate shelves", opened("home", BAGS_STATE.replace("LOOK", "slate").replace("LAYOUT", "shelves"))),
    ("Bags - gilded shelves", opened("home", BAGS_STATE.replace("LOOK", "gilded").replace("LAYOUT", "shelves"))),
    ("Bags - gilded bags", opened("home", BAGS_STATE.replace("LOOK", "gilded").replace("LAYOUT", "bags"))),
    ("Bags - classic one", opened("home", BAGS_STATE.replace("LOOK", "classic").replace("LAYOUT", "one"))),
    ("Bags - classic shelves", opened("home", BAGS_STATE.replace("LOOK", "classic").replace("LAYOUT", "shelves"))),
    ("Bags - classic bags", opened("home", BAGS_STATE.replace("LOOK", "classic").replace("LAYOUT", "bags"))),
    # (the bank in Classic: the banker in the open ring of the bank's header)
    ("Bags - classic bank", opened("home", BAGS_STATE.replace("LOOK", "classic").replace("LAYOUT", "one") +
        "; ns.LookBags:Close('bags'); __MOCK.set_bags({ { -1, 1, 28830, 1 }, { -1, 2, 22838, 10 }, { -1, 3, 23445, 14 }, "
        "{ -1, 5, 29760, 1 }, { -1, 9, 4865, 5 } }, true); ns.LookBags:Refresh('bank')")),
    ("Settings - Shot timer", demo("ns.SettingsUI:SelectSection('shot')", "settings")),
    ("Shot timer - both, Steady now", opened("home", "ns.MainFrame:Close(); " + (SHOT_HUD % "0.25").replace("STYLE", "both"))),
    ("Shot timer - bar, late in the shot", opened("home", "ns.MainFrame:Close(); " + (SHOT_HUD % "1.6").replace("STYLE", "bar"))),
    ("Shot timer - demo beside the swing timer", demo("ns.MainFrame:Close(); ns.DB:SetSetting('swing.enabled', true); "
                                                      "ns.DB:SetSetting('shot.style', 'bar')")),
    ("Swing practice - lessons", opened("home", PRACTICE + "__MOCK.fire('SPELLS_CHANGED'); ns.MainFrame:Close(); "
                                        "ns.SwingPracticeUI:Open()")),
    ("Swing practice - in play", practice_play),
    ("Swing practice - result", opened("home", PRACTICE_RESULT)),
    ("Settings - Window", opened("settings", "ns.SettingsUI:SelectSection('window')")),
    ("Settings - Meters", opened("settings", "ns.SettingsUI:SelectSection('meters')")),
    # (Settings 1.4.2: the meters' look is their page in Interface > Looks)
    ("Settings - Meters look", opened("settings", "ns.DB:SetSetting('meters.dmg', true); ns.SettingsUI:OpenPart('meters')")),
    # meters (UI/MeterPanels.lua, UI/MeterDetail.lua) on the demo night
    ("Meters - panels", opened("home", "ns.MainFrame:Close(); " + MET +
        "local L = ns.MeterPanels.Layout(); L.stacks[1].x, L.stacks[1].y = 900, 560; "
        "L.stacks[1].panels[2].tabs[2] = { view = 'healing', seg = 'cur' }; "
        "L.stacks[2] = { x = 560, y = 560, w = 240, panels = { { tabs = { { view = 'deaths', seg = 'cur' } } }, "
        "{ tabs = { { view = 'kicks', seg = 'all' } }, rows = 4 } } }; ns.MeterPanels:Rebuild()")),
    # meter themes (UI/MeterTheme.lua): one stack, Threat over Damage done, each theme; then the overrides
] + [("Meters - theme " + _k, opened("home", "ns.MainFrame:Close(); " + MET + METQ +
        "ns.DB:SetSetting('meters.theme', '" + _k + "'); "
        "local L = ns.MeterPanels.Layout(); L.stacks[1].x, L.stacks[1].y, L.stacks[1].w = 560, 620, 280; "
        "ns.MeterPanels:Rebuild(); " + METBOX)) for _k in ("flat", "halo", "sigil", "slate", "gilded", "pips", "classic")] + [
    ("Meters - theme overrides", opened("home", "ns.MainFrame:Close(); " + MET + METQ +
        "ns.DB:SetSetting('meters.theme', 'halo'); ns.DB:SetSetting('meters.barColor', 'role'); "
        "ns.DB:SetSetting('meters.icons', 'class'); ns.DB:SetSetting('meters.rowSize', 'roomy'); "
        "ns.DB:SetSetting('meters.numbers', 'full'); ns.DB:SetSetting('meters.bg', 90); "
        "local L = ns.MeterPanels.Layout(); L.stacks[1].x, L.stacks[1].y, L.stacks[1].w = 560, 620, 280; "
        "ns.MeterPanels:Rebuild(); " + METBOX)),
    ("Meters - unlocked, tank view", opened("home", "ns.MainFrame:Close(); " + MET +
        "ns.EditMode:Open(); ns.DB:SetSetting('meters.tankView', 'always'); "
        "local L = ns.MeterPanels.Layout(); L.stacks[1].x, L.stacks[1].y = 900, 560; ns.MeterPanels:Rebuild()")),
    ("Meters - empty", opened("home", "ns.MainFrame:Close(); ns.DB:SetSetting('meters.dmg', true); "
        "ns.DB:SetSetting('meters.thr', true); ns.DB:SetSetting('meters.show', 'always'); ns.MeterPanels:ResetLayout(); "
        "local L = ns.MeterPanels.Layout(); L.stacks[1].x, L.stacks[1].y = 900, 560; ns.MeterPanels:Rebuild()")),
    ("Meters - breakdown", opened("home", "ns.MainFrame:Close(); " + MET + "ns.MeterDetail:Open('cur', ns.MeterDemo.ME, 'damage')")),
    ("Meters - breakdown over time", opened("home", "ns.MainFrame:Close(); " + MET + "ns.MeterDetail:Open('cur', ns.MeterDemo.ME, 'damage'); "
        "ns.MeterDetail:GetState().tab = 'time'; ns.MeterDetail:Draw()")),
    ("Meters - breakdown targets", opened("home", "ns.MainFrame:Close(); " + MET + "ns.MeterDetail:Open('all', ns.MeterDemo.ME, 'damage'); "
        "ns.MeterDetail:GetState().tab = 'targets'; ns.MeterDetail:Draw()")),
    ("Meters - healer breakdown", opened("home", "ns.MainFrame:Close(); " + MET +
        "local g; for k, a in pairs(ns.Meter:GetSegment('cur').actors) do if a.n == 'Thunderhoofx' then g = k end end; "
        "ns.MeterDetail:Open('cur', g, 'healing')")),
    ("Meters - bar tooltip", opened("home", "ns.MainFrame:Close(); " + MET +
        "local L = ns.MeterPanels.Layout(); L.stacks[1].x, L.stacks[1].y = 960, 560; ns.MeterPanels:Rebuild(); ns.MeterPanels:Draw(); local pf = ns.MeterPanels._Panel('damage'); local g = ns.MeterDemo.ME; ns.MeterPanels.ShowRowTip(pf.rowsByKey[g])")),
    ("Meters - bar tooltip, died", opened("home", "ns.MainFrame:Close(); " + MET +
        "local yb; for k, a in pairs(ns.Meter:GetSegment('cur').actors) do if a.n == 'Yubell' then yb = k end end; "
        "local L = ns.MeterPanels.Layout(); L.stacks[1].x, L.stacks[1].y = 960, 560; ns.MeterPanels:Rebuild(); ns.MeterPanels:Draw(); local pf = ns.MeterPanels._Panel('damage'); local g = yb; ns.MeterPanels.ShowRowTip(pf.rowsByKey[g])")),
    ("Meters - fight list", opened("home", "ns.MainFrame:Close(); " + MET +
        "local L = ns.MeterPanels.Layout(); L.stacks[1].x, L.stacks[1].y = 760, 900; ns.MeterPanels:Rebuild(); ns.MeterPanels:Draw(); local pf = ns.MeterPanels._Panel('damage'); ns.MeterPanels:FightMenu(pf, pf.fl.lab)")),
    ("Meters - interrupts breakdown", opened("home", "ns.MainFrame:Close(); " + MET + "local g; for k, a in pairs(ns.Meter:GetSegment('all').actors) do if a.n == 'Shadowmelder' then g = k end end; ns.MeterDetail:Open('all', g, 'kicks')")),
    ("Meters - dispels breakdown", opened("home", "ns.MainFrame:Close(); " + MET + "local g; for k, a in pairs(ns.Meter:GetSegment('all').actors) do if a.n == 'Brightmend' then g = k end end; ns.MeterDetail:Open('all', g, 'dispels')")),
    ("Meters - active time breakdown", opened("home", "ns.MainFrame:Close(); " + MET + "local g; for k, a in pairs(ns.Meter:GetSegment('cur').actors) do if a.n == 'Yubell' then g = k end end; ns.MeterDetail:Open('cur', g, 'active')")),
    ("Meters - death recap", opened("home", "ns.MainFrame:Close(); " + MET +
        "ns.MeterDetail:OpenDeath('cur', ns.Meter:GetSegment('cur').deaths[1])")),
    ("Settings - Loot Council", opened("settings", "ns.SettingsUI:SelectSection('council')")),
    ("Settings - Attendance", opened("settings", "ns.SettingsUI:SelectSection('attendance')")),
    # Settings 1.4.2 (the "Spotlight" makeover): the groups, Guild as the Guild Master (the set-up checklist card)
    ("Settings - General", opened("settings", "ns.SettingsUI:SelectSection('general')")),
    ("Settings - Loot", opened("settings", "ns.SettingsUI:SelectSection('loot')")),
    ("Settings - Guild (GM)", opened("settings", "ns.SettingsUI:Refresh(); ns.SettingsUI:SelectSection('guild')")),
    ("Settings - Guild set-up (GM)", opened("settings", "ns.SettingsUI:Refresh(); ns.SettingsUI:SelectSection('setup')")),
    ("Settings - Help", opened("settings", "ns.SettingsUI:SelectSection('help')")),
    ("Settings - Search", opened("settings", "ns.SettingsUI.searchBox:SetText('sound'); ns.SettingsUI:Search('sound')")),
    ("Settings - Search (look)", opened("settings", "ns.SettingsUI.searchBox:SetText('look'); ns.SettingsUI:Search('look')")),
    ("Settings - Search (nothing)", opened("settings", "ns.SettingsUI.searchBox:SetText('zzz'); ns.SettingsUI:Search('zzz')")),
    ("Settings - Changed rows", opened("settings", "ns.DB:SetSetting('tooltip.maxNames', 8); ns.DB:SetSetting('minimap.hide', true); "
        "ns.SettingsUI:SelectSection('tooltips'); ns.SettingsUI:Refresh()")),
    ("Settings - Attendance (member)", opened("settings", "ns.Guild.IsGM = function() return false end; "
        "ns.SettingsUI:SelectSection('attendance'); ns.SettingsUI:Refresh()")),
    ("Settings - Demo mode", opened("settings", "ns.SettingsUI:SelectSection('demo')")),
    ("Settings - About", opened("settings", "ns.SettingsUI:SelectSection('about')")),
    # Settings, the clean-up (mockup "B · Feature tiles"): a group's tiles, a card's page with More options, a page
    # whose master switch is off (one box), options hidden while the switch they need is off, a search result in a fold
    ("Settings - Combat tiles", opened("settings", "ns.DB:SetSetting('meters.dmg', true); ns.DB:SetSetting('meters.thr', false); "
        "ns.DB:SetSetting('bossmods.on', true); ns.SettingsUI:Refresh(); ns.SettingsUI:SelectSection('combat')")),
    ("Settings - Combat tiles (off)", opened("settings", "ns.DB:SetSetting('meters.dmg', false); ns.DB:SetSetting('bossmods.on', false); "
        "ns.DB:SetSetting('mylog.enabled', false); ns.SettingsUI:Refresh(); ns.SettingsUI:SelectSection('combat')")),
    ("Settings - Boss mods (off)", opened("settings", "ns.DB:SetSetting('bossmods.on', false); ns.SettingsUI:Refresh(); "
        "ns.SettingsUI:SelectSection('bossmods')")),
    ("Settings - Boss mods (on)", opened("settings", "ns.DB:SetSetting('bossmods.on', true); "
        "ns.DB:SetSetting('settingsMore.bossmods', nil); ns.SettingsUI:Refresh(); ns.SettingsUI:SelectSection('bossmods')")),
    ("Settings - Boss mods (more open)", opened("settings", "ns.DB:SetSetting('bossmods.on', true); "
        "ns.DB:SetSetting('settingsMore.bossmods', true); ns.SettingsUI:Refresh(); ns.SettingsUI:SelectSection('bossmods')")),
    ("Settings - Meters (threat off)", opened("settings", "ns.DB:SetSetting('meters.dmg', true); ns.DB:SetSetting('meters.thr', false); "
        "ns.DB:SetSetting('settingsMore.meters', nil); ns.SettingsUI:Refresh(); ns.SettingsUI:SelectSection('meters')")),
    ("Settings - Meters (more open)", opened("settings", "ns.DB:SetSetting('meters.dmg', true); ns.DB:SetSetting('meters.thr', true); "
        "ns.DB:SetSetting('settingsMore.meters', true); ns.SettingsUI:Refresh(); ns.SettingsUI:SelectSection('meters')")),
    ("Settings - Search into More options", opened("settings", "ns.DB:SetSetting('meters.thr', true); "
        "ns.DB:SetSetting('settingsMore.meters', nil); ns.SettingsUI:Refresh(); "
        "ns.SettingsUI.searchBox:SetText('tank view'); ns.SettingsUI:Search('tank view'); "
        "for _, e in ipairs(ns.SettingsUI.index) do if e.title == 'Tank view' then ns.SettingsUI:Jump(e) end end")),
    ("Settings - My Log (off)", opened("settings", "ns.DB:SetSetting('mylog.enabled', false); ns.SettingsUI:Refresh(); "
        "ns.SettingsUI:SelectSection('mylog')")),
    ("Settings - Alerts grid", opened("settings", "ns.DB:SetSetting('settingsMore.reach', nil); ns.SettingsUI:Refresh(); "
        "ns.SettingsUI:SelectSection('reach')")),
    ("Settings - Combat text (off)", opened("settings", "ns.DB:SetSetting('ui.sct.on', false); ns.Popup:HideAll(); "
        "ns.SettingsUI:Refresh(); ns.SettingsUI:OpenPart('sct')")),
    # the Welcome tour (UI/WelcomeTour.lua, Data/Tours/Welcome.lua): the one-time offer as the GM (every part), a
    # step of Everyone on Home, a council step on demo data, the GM's last step (the set-up checklist), Settings >
    # Tutorials
    ("Welcome - offer", opened("home", "ns.WelcomeTour:OpenOffer()")),
    ("Welcome - Everyone step", tour_view("home", "ns.WelcomeTour:Start(nil); ns.Tour:Next()")),
    ("Welcome - menus step", tour_view("home", "ns.WelcomeTour:Start(nil); for i = 1, 4 do ns.Tour:Next() end")),
    ("Welcome - council step", tour_view("home", "ns.WelcomeTour:StartPart('council'); ns.Tour:Next()")),
    ("Welcome - leader step", tour_view("home", "ns.WelcomeTour:StartPart('leader')")),
    ("Welcome - GM checklist", tour_view("home", "ns.WelcomeTour:StartPart('gm'); "
                                         "for i = 1, 4 do ns.Tour:Next() end")),
    ("Settings - Tutorials", opened("settings", "ns.SettingsUI:SelectSection('tutorials')")),
    ("Changelog", opened("changelog")),
    ("Changelog - since your last visit", opened("changelog", "ns.ChangelogUI.ResetSession(); "
                                          "ns.db.settings.changelogSeen = '1.3.1'; ns.ChangelogUI:Select('since')")),
    ("Changelog - sections opened", opened("changelog", "ns.ChangelogUI:Select(ns.version); "
                                    "local st = ns.ChangelogUI:GetState(); local n = 0; "
                                    "for _, s in ipairs(ns.ChangelogUI.Norm().by[ns.version].sections) do "
                                    "if not s.hi and n < 2 then st.open[s.id] = true; n = n + 1 end end; "
                                    "ns.ChangelogUI:Render()")),
    ("Changelog - search", opened("changelog", "local p = ns.MainFrame:GetPanel('changelog'); "
                           "p.search:SetText('attendance'); ns.ChangelogUI:SetSearch('attendance')")),
    ("Changelog - from your feedback", opened("changelog", "local e; for _, x in ipairs(ns.CHANGELOG) do "
                                       "if x.version == ns.version then e = x end end; table.insert(e.sections[1].lines, "
                                       "{ 'Built-in meters: no need for Details or a threat addon.', fb = { 3 }, "
                                       "by = { 'Gina' }, k = 'idea' }); table.insert(e.sections[2].lines, "
                                       "{ 'Meters dock to the side of your screen.', fb = { 3 }, by = { 'Gina' }, "
                                       "k = 'idea' }); ns.ChangelogUI.ResetIndex(); "
                                       "ns.ChangelogUI:Select('feedback')")),
    ("Changelog - newest version", opened("changelog", "ns.ChangelogUI:Select(ns.CHANGELOG[1].version)")),
    ("Changelog - pop-up", opened("home", "ns.ChangelogUI.ResetSession(); ns.db.settings.changelogSeen = '1.3.1'; "
                           "ns.ChangelogUI:OpenPopup()")),
    ("Changelog - show me", opened("changelog", "for _, s in ipairs(ns.ChangelogUI.Norm().by[ns.version].sections) do "
                            "if s.open == 'gearsim' then ns.ChangelogUI:ShowMe(s) break end end")),
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
    # 1.3.5 Council > Rules: the GM's loot rules with the example roll, a draft that changes the order, a prized item
    ("Demo - Council - rules", demo("ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select('winner')", "council")),
    ("Demo - Council - rules changed", demo("ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select('winner'); "
                                            "ns.CouncilRulesUI:SetChoice('f', 50); ns.CouncilRulesUI:SetChoice('s', 'p')",
                                            "council")),
    # longevity (Longest use, counted up to P4): the "count up to" line shows and the example re-ranks
    ("Demo - Council - rules longest use", demo("ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select('winner'); "
                                                "ns.CouncilRulesUI:SetScene('none'); ns.CouncilRulesUI:SetChoice('o', 4)",
                                                "council")),
    # 1.3.5 Raids > Loot rules (everyone, read-only): how it's decided, the prized items gallery, an item
    ("Demo - Loot rules page - decided", demo("ns.LootRulesUI:SetView('decided')", "lootrules")),
    ("Demo - Loot rules page - decided longest use", demo("ns.Guild:SetLootRules({ f = 50, s = 'r', l = 'l', w = 'd', "
                                                          "y = 'n', o = 4 }); ns.LootRulesUI:SetView('decided')", "lootrules")),
    ("Demo - Loot rules page - prized", demo("ns.LootRulesUI:SetView('prized')", "lootrules")),
    ("Demo - Loot rules page - item", demo("ns.LootRulesUI:OpenItem('32505')", "lootrules")),
    ("Loot rules page - raider", opened("lootrules", "ns.LootRulesUI:SetView('decided')")),
    # the worst case for Where you stand: the dry streak, longest use and a list with 1 slot picked (16 empty)
    ("Demo - Loot rules page - 1 picked", demo(
        "ns.Guild:SetLootRules({ f = 50, s = 'r', l = 'l', w = 'd', y = 'n', o = 4 }); "
        "local ph = ns.Guild:GetViewPhase() or 1; "
        "for _, sl in ipairs(ns.SLOTS) do ns.BiS:ClearSlot(ph, sl.id) end; "
        "ns.BiS:SetSlot(ph, 1, 'main', 29011); ns.BiS:Commit(); ns.LootRulesUI:SetView('decided')", "lootrules")),
    ("Demo - Council - rules no votes", demo("ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select('winner'); "
                                             "ns.CouncilRulesUI:SetScene('none')", "council")),
    ("Demo - Council - rules prized", demo("ns.CouncilUI:SetView('rules'); "
                                           "local it = ns.Prized:GetItems()[1]; ns.CouncilRulesUI:Select(it and it.id)",
                                           "council")),
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
    # 1.3.5 prized items (Council > Rules, UI/PrizedUI.lua in UI/CouncilRules.lua) on the demo guild's made-up items
    ("Demo - Loot rules", demo("ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select('28830')", "council")),
    ("Demo - Loot rules - Warglaives", demo("ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select('32837')", "council")),
    ("Demo - Loot rules - recipe", demo("ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select('22559')", "council")),
    ("Demo - Loot rules - recipe editing", demo("ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select('22559'); "
                                                "ns.PrizedUI:StartEdit()", "council")),
    ("Demo - Loot rules - history", demo("ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select('28830'); "
                                         "ns.PrizedUI:SetTab('history')", "council")),
    ("Demo - Loot rules - editing", demo("ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select('28830'); "
                                         "ns.PrizedUI:StartEdit()", "council")),
    ("Demo - Loot rules - add", demo("ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select('prized'); ns.PrizedUI:CancelEdit(); ns.PrizedUI:StartAdd(); "
                                     "ns.PrizedUI:SetAddSearch('warglaive'); ns.PrizedUI:TogglePick(32837); "
                                     "ns.PrizedUI:TogglePick(32838)", "council")),
    # 1.3.5 time-based attendance (UI/AttendanceUI.lua): a member's page, the reviews, the chat picker, the prompts
    ("Demo - Raid log - Attendance player", demo("ns.RaidsUI:SetMode('players'); "
        "local s = ns.Attendance:GetStats(8); local k; for _, r in ipairs(s) do if r.pending > 0 then k = r.key end end; "
        "ns.RaidsUI:ShowAttendancePlayer(k or s[1].key)", "raids")),
    ("Demo - Raid log - Reviews", demo("ns.RaidsUI:SetMode('reviews')", "raids")),
    ("Demo - Raid log - Reviews picker", demo("ns.RaidsUI:SetMode('reviews'); "
        "local r; for _, x in ipairs(ns.Attendance:GetReviews().pending) do if x.reason then r = x end end; "
        "ns.AttendanceUI:OpenPicker(nil, r or ns.Attendance:GetReviews().pending[1])", "raids")),
    ("Demo - Attendance prompts", demo("ns.AttendanceUI:ShowDemo()", "raids")),
    ("Demo - Attendance away period", demo("ns.RaidsUI:SetMode('players'); local k = ns.Attendance:GetStats(8)[3].key; "
        "ns.RaidsUI:ShowAttendancePlayer(k); ns.AttendanceUI:OpenAwayDialog(k); "
        "local f = DisasterZoneAttendanceAway; f.pick(f.from - 3 * 86400); f.pick(f.from + 9 * 86400)", "raids")),
    ("Demo - Members - member card - attendance", demo("local k = ns.Attendance:GetStats(8)[9].key; "
        "ns.MembersUI:ShowMember(k); ns.MembersUI:SetCard('att')", "members")),
    # the selected logged raid's tabs (demo mode: raids with kills and awards)
    ("Demo - Raid log - Raids", demo("ns.RaidsUI:SetMode('raids'); ns.RaidsUI:SetLogTab('att')", "raids")),
    ("Demo - Raid log - Bosses", demo("ns.RaidsUI:SetMode('raids'); ns.RaidsUI:SetLogTab('boss')", "raids")),
    ("Demo - Raid log - Awards", demo("ns.RaidsUI:SetMode('raids'); ns.RaidsUI:SetLogTab('award')", "raids")),
    # a night of two logged raids (the demo's Thu 17 Gruul + Mag joined by one planned-raid link): split art, "Gruul + Mag"
    ("Demo - Raid log - combined night", demo("for _, r in ipairs(ns.RaidLog:GetRaids()) do "
        "if date('%d', r.start) == '17' then r.pl = 'demo-combo' end end; "
        "ns:Fire('RAIDLOG_CHANGED'); ns.RaidsUI:SetMode('raids'); ns.RaidsUI:SetLogTab('att'); "
        "for _, x in ipairs(ns.Attendance:GetNights()) do if x.pl == 'demo-combo' then "
        "ns.RaidsUI:Select(ns.Attendance:NightView(x).id) end end", "raids")),
    ("Demo - Start raid window", demo("ns.SessionBar:OpenStart()")),
    ("Demo - test drop panel", demo("ns.Loot:SimulateDrop()")),
    # the roll rows makeover (1.3.5, layout B): a full demo raid rolling, the council's view
    ("Demo - drop panel rolling", st_demo_roll),
    # in Grumpykat's raid: the group loot rules are his (read-only values, "Set by"), the raid's council
    ("Raid - Settings - Group loot rules (raider)", st_settings_in_raid("rules")),
    ("Raid - Settings - Loot Council (raider)", st_settings_in_raid("council")),
    ("Raid - session bar", st_session_bar),
    ("Raid - session crest (before the start)", st_session_crest(idle=True)),
    ("Raid - session crest (drawer)", st_session_crest(open_=True)),
    ("Raid - session crest (before the start, drawer)", st_session_crest(open_=True, idle=True)),
    ("Demo - session crest (loot)", st_crest_demo("loot")),
    ("Demo - session crest (after Vashj)", st_crest_demo("done")),
    ("Demo - session crest (boss fight)", st_crest_demo("pull", open_=False)),
    ("Demo - session crest (between bosses)", st_crest_demo("between", open_=False)),
    ("Reserves - my reserves (raider)", st_reserves("pick", "Victhar")),
    ("Reserves - my reserves (guild items)", st_reserves("pick", "Gina", "ns.ReservesUI:GetState().holdMode = true")),
    ("Reserves - list (host)", st_reserves("list")),
    ("Reserves - list (raider)", st_reserves("list", "Moonwhisper")),
    ("Reserves - wrap-up", st_reserves("wrap")),
    ("Reserves - crest drawer (before the start)", st_reserve_crest(True)),
    ("Reserves - crest drawer (running)", st_reserve_crest(False)),
    ("Reserves - drop panel", st_reserve_drop()),
    ("Reserves - drop panel (rolling)", st_reserve_drop(True)),
    ("Reserves - roll popup (reserver)", st_reserve_drop(True, "Moonwhisper")),
    ("Reserves - demo (set up)", st_reserve_demo(1)),
    ("Reserves - demo (players reserve, pug)", st_reserve_demo(3, "pug")),
    ("Reserves - demo (Vashj drops)", st_reserve_demo(6)),
    ("Reserves - demo (wrap-up)", st_reserve_demo(7)),
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
    # 1.3.5 prized items: the head is prized (rank Officer or higher, the council decides); pugs and lower ranks
    # break a rule
    ("Raid - drop panel (prized, rolling)", st_drop({"loot": True, "rolls": True, "lock": False}, roll=True,
        item_lua=PRIZED_ITEM)),
    ("Raid - roll popup (prized, blocked)", st_drop({"loot": True, "rolls": True, "lock": False}, roll=True,
        viewer="Victhar", item_lua=PRIZED_ITEM)),
    ("Raid - drop panel (material)", st_material("panel")),
    ("Raid - drop panel (material, rolling)", st_material("rolling")),
    ("Raid - roll popup (material)", st_material("popup")),
    ("Raid - drop panel (material, awarded)", st_material("awarded")),
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
    TEAMS["alt"] = res["r"]
    kara = [K(n) for n, _, _ in TEAMS_KARA]
    res = k.eval_py(SAVE_TEAM, None, "Kara B", kara, 10, {K(n): sp for n, sp, _ in TEAMS_KARA if sp},
                    {K(n): g for n, _, g in TEAMS_KARA if g})
    assert res["ok"] is True, res
    TEAMS["kara"] = res["r"]
    # 1.3.5: raid nights (Thu + an optional Sun for the main team, Mon + Wed for Kara B)
    for tid, nts, note in ((IDS["team"], [{"w": 3 * 1440 + 1170, "m": 210}, {"w": 6 * 1440 + 1170, "m": 210, "o": True}],
                            "Online 15 min before invites. Flasks and food on progression nights."),
                           (TEAMS["kara"], [{"w": 1200, "m": 180}, {"w": 2 * 1440 + 1200, "m": 210}], None)):
        res = k.eval_py("local id, nt, nn = ...; local t = ns.RaidPlan:GetTeam(id); local ok, r = ns.RaidPlan:SaveTeam("
                        "id, t.name, t.members, { nights = nt, note = nn }); return { ok = ok, r = r }", tid, nts, note)
        assert res["ok"] is True, res
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
            cl.eval("StaticPopup_HideAll(); if ns.Popup then ns.Popup:HideAll() end")
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
            v.eval(lua, IDS["team"], TEAMS.get("kara"), TEAMS.get("alt"))
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
        g.eval("StaticPopup_HideAll(); if ns.Popup then ns.Popup:HideAll() end")
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
    # 1.3.5: raid nights: the editor (organizer), a team without nights, Join with the nights above it
    ("Raids - Teams - raid nights editor", teams_view(lua="ns.RaidPlanUI:OpenNightsEditor()")),
    ("Raids - Teams - raid nights none", teams_view(lua="ns.RaidPlanUI:SelectTeam(select(3, ...))")),
    ("Raids - Teams - raid nights join", teams_view("Vaenyria", lua="local id = ...; ns.RaidPlan:LeaveWaitlist(id, '1'); "
                                                    "ns.RaidPlanUI:RefreshTeams(); local b = ns.RaidsUI:GetPanel()"
                                                    ".teams.detail.wlBtn; b:Click()")),
    # 1.3.5: the addon's own dialogs (UI/Popup.lua): three buttons, a deletion (red), a field
    ("Dialog - unsaved changes", teams_view(lua="ns.RaidPlanUI:ToggleDraftNight(2); ns.RaidPlanUI:ShowTeamBoard()")),
    ("Dialog - delete team", teams_view(lua="ns.RaidPlanUI:DeleteTeam()")),
    ("Dialog - lineup name", teams_view(lua="ns.Popup:Show('DISASTERZONE_LINEUP_NAME', nil, nil, { i = 2, name = 'Kara A' })")),
    ("Raids - Upcoming - SSC sign-ups (comp)", teams_raid("signups")),
    ("Raids - Upcoming - SSC groups (comp)", teams_raid("groups")),
    # the gear sim's buffs: the card's menu (presets + teams), the editor on a team lineup and on a preset
    ("My BiS - Sim buffs menu", sim_buffs("menu")),
    ("My BiS - Sim buffs team", sim_buffs("team")),
    ("My BiS - Sim buffs preset", sim_buffs("preset")),
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


# ---------------------------------------------------------------- Feedback (Core/Feedback.lua, UI/Feedback*.lua)
FB_CLOSE = ("for _, n in ipairs({ 'DisasterZoneFeedbackSheet', 'DisasterZoneFeedbackToast', 'DisasterZoneFeedbackPointer', 'DisasterZoneFeedbackPointerBar', 'DisasterZoneFeedbackPointer' }) "
            "do local f = _G[n]; if f then f:Hide() end end ")
FB_PICK = ("local want = ...; for _, v in ipairs(ns.Feedback:List()) do if v.text:find(want, 1, true) then "
           "ns.FeedbackUI:Select(v.id) end end ")


def fb_view(lua=None, demo_on=True, tab="all"):
    def fn(w, c):
        g = c["Gina"]
        close_all(g)
        g.eval(FB_CLOSE)
        on = g.eval("return ns.Demo:IsEnabled()")
        if demo_on and not on:
            g.slash("/dz demo on")
            w.tick(1)
        elif not demo_on and on:
            g.slash("/dz demo off")
            w.tick(1)
        g.eval("ns.FeedbackUI:Open(...)", tab)
        w.tick(0.3)
        g.eval("ns.Azero.clockHour = 12")                 # by day, unless the state says otherwise
        if lua:
            g.eval(lua)
            w.tick(0.3)
        return g
    return fn


FB_SHEET = ("ns.Feedback.NoteError('Interface/AddOns/DisasterZone/UI/RollFrame.lua:412: attempt to index field "
            "session (a nil value)', 'stack'); ns.FeedbackSheet:Open({ kind = 'bug', about = 'Roll popup › Need', "
            "text = 'The roll popup closed when I pulled aggro in phase 2, so I could not roll on the belt' }); "
            "ns.FeedbackSheet:LayoutSimilar(); ns.MainFrame:Close(); local t = _G.DisasterZoneFeedbackToast; "
            "if t then t:Hide() end")
_FB_AT = next(i for i, st in enumerate(STATES) if st[0] == "Home - calendar busy")
STATES[_FB_AT:_FB_AT] = [
    ("Feedback - everything (demo)", fb_view(FB_PICK.replace("...", "'roll popup closed'"))),
    ("Feedback - inbox (demo)", fb_view(tab="inbox")),
    ("Feedback - yours (demo)", fb_view(tab="mine")),
    ("Feedback - empty", fb_view(demo_on=False)),
    ("Feedback - form", fb_view(FB_SHEET)),
    ("Feedback - sent", fb_view(FB_SHEET + "; ns.FeedbackSheet:Send()")),
    ("Feedback - answered pop-up", fb_view("ns.FeedbackSheet:Toast({ icon = ns.Feedback.KIND_INFO.change.icon, "
                                           "color = ns.Feedback.KIND_INFO.change.color, title = 'Caelith answered your "
                                           "feedback', text = '\"Settings > Swing timer has a Size option.\"', button = "
                                           "'See it' })")),
    ("Changelog - feedback credits", fb_view("local e; for _, x in ipairs(ns.CHANGELOG) do if x.version == ns.version "
                                             "then e = x end end; table.insert(e.sections[1].lines, 1, { 'The roll popup "
                                             "waits until you leave combat.', fb = { 12 }, by = { 'Gina', 'Grimtusk' }, "
                                             "mt = 3, k = 'bug' }); table.insert(e.sections[1].lines, 2, { 'Boss tiles "
                                             "show who still needs a token.', fb = { 14 }, by = { 'Isolde' }, mt = 6, k = "
                                             "'idea' }); ns.ChangelogUI:Open(ns.version)")),
]


# ---------------------------------------------------------------- Notifications (Core/Notify.lua, UI/Notify.lua)
# The mockup's feed (art/casc/notify_mockup) posted into the real kinds: what needs Gina and the week's news.
NOTIFY_SEED = """
local N, now = ns.Notify, time()
N:SetWants('polls', 'popup', false); N:SetWants('raidAnswer', 'popup', false); N:SetWants('raidRequests', 'popup', false)
N:Post('polls', { key = 'audit-p1', title = 'Should we start Thursdays 30 minutes earlier?',
  text = 'Yes or no · closes tomorrow', from = 'Victhar-Thunderstrike', time = now - 240, needsYou = true })
N:Post('raidAnswer', { key = 'audit-r1', title = 'Kara full clear + Gruul if time',
  text = [[Mon 21 Sep · 19:45 · you haven't answered]], time = now - 3600, needsYou = true })
N:Post('raidRequests', { key = 'audit-q1', n = 3, title = '|cffffffffPugsyhealer|r and 2 more ask to join',
  text = 'Karazhan · Thu 24 Sep 20:00 · you run this raid', time = now - 720, needsYou = true })
N:Post('lootWon', { key = 'audit-l1', title = 'You won |cffa335ee[Bladed Shoulderpads of the Merciless]|r',
  text = 'Awarded by a roll', time = now - 60 })
N:Post('chessTurn', { key = 'audit-c1', title = 'Saltykim moved: your turn', text = 'Karazhan Chess',
  from = 'Shadowmelder-Thunderstrike', time = now - 7200, needsYou = false })
N:Post('runNeedsYou', { key = 'audit-d1', title = 'Frostweaver needs a tank: Shattered Halls (H)',
  text = [[You're up for a run and this one needs you.]], time = now - 10800 })
"""


def notify_view(lua=None, key="home", window=True):
    def fn(w, c):
        g = c["Gina"]
        demo_off(w, c)
        close_all(g)
        g.eval("if ns.NotifyUI and ns.NotifyUI:GetTray() then ns.NotifyUI:CloseTray() end; "
               "local t = _G.DisasterZoneNotifyToast; if t then t:Hide() end")
        if not g.eval("return __notifySeeded"):
            g.eval(NOTIFY_SEED + "; __notifySeeded = true")
            w.tick(0.5)
        if window:
            tab(g, key)
            w.tick(0.3)
        g.eval("ns.Azero.clockHour = 12")                 # by day, unless the state says otherwise
        if lua:
            g.eval(lua)
            w.tick(0.3)
        return g
    return fn


STATES += [
    ("Notify - bell", notify_view()),
    ("Notify - tray", notify_view("ns.NotifyUI:OpenTray('needs')")),
    ("Notify - tray everything", notify_view("ns.NotifyUI:OpenTray('all')")),
    ("Notify - guild menu", notify_view("local t = ns.MainFrame:GetNavTabs()['grp:guild']; ns.UI:ContextMenu(t, "
                                        "function(root) for i, k in ipairs({ 'Members', 'Map', 'Events', 'Polls' }) do "
                                        "local e = root:CreateRadio(k, function() return i == 1 end, function() end); "
                                        "e:SetSubtext('The guild page ' .. k .. '.'); if k == 'Polls' then e:SetCount(3) "
                                        "elseif k == 'Events' then e:SetBadge('BETA', { 0.73, 0.55, 1 }) end end end)")),
    ("Notify - page", notify_view("ns.NotifyUI:OpenPage('needs')")),
    ("Notify - page everything", notify_view("ns.NotifyUI:OpenPage('all')")),
    ("Notify - pop-up", notify_view("ns.Notify:SetWants('polls', 'popup', true); ns.Notify:Post('polls', { key = "
                                    "'audit-p2', title = 'Which nights can you raid SSC next week?', text = 'Pick days "
                                    "· closes Fri 20:00', from = 'Gina-Thunderstrike', needsYou = true })",
                                    window=False)),
    ("Settings - Notifications", notify_view("ns.SettingsUI:SelectSection('notify')", key="settings")),
]


# ------------------------------------------------------------------------------------------------------------------
# Blessings (Core/Blessings.lua, UI/BlessingsUI.lua, UI/BlessingsBar.lua): a 25-man Black Temple plan on Gina's
# screen, as in the mockup (dev/art/casc/pally_mockup): four paladins, tanks on Light instead of Salvation, a hunter
# missing Might, two mages missing Salvation, priests' Wisdom running out, two paladins on Devotion in one party.
# The roster and who has what are stubbed on Gina's Blessings module (the raid itself is a few real clients).
BLESS_SEED = """
local B = ns.Blessings
local lead = ...
local classes = { { 'WARRIOR', { 'Victhar', 'Brakka', 'Kordan', 'Ulfric' } }, { 'ROGUE', { 'Shadowmelder', 'Vexis' } },
  { 'HUNTER', { 'Faelar', 'Tarrow' } }, { 'DRUID', { 'Moonwhisper', 'Rhosyn', 'Quillon' } },
  { 'SHAMAN', { 'Stormfist', 'Thunderhoofx' } }, { 'PALADIN', { 'Caelith', 'Lightbringer', 'Sunniva', 'Gina' } },
  { 'PRIEST', { 'Isolde', 'Nyxa', 'Seraphel' } }, { 'MAGE', { 'Embera', 'Frostweaver', 'Kaelwyn' } },
  { 'WARLOCK', { 'Grumpykat', 'Morrigan' } } }
local R, byUnit, i = {}, {}, 0
for _, e in ipairs(classes) do
  for _, n in ipairs(e[2]) do
    i = i + 1
    local m = { unit = 'raid' .. i, name = n, class = e[1], ci = B.CLASS_INDEX[e[1]], subgroup = math.floor((i - 1) / 5) + 1,
      level = 70, online = true, dead = false,
      tank = (n == 'Victhar' or n == 'Caelith' or n == 'Moonwhisper') or nil }
    R[#R + 1] = m
    byUnit[m.unit] = m
  end
end
B.Roster = function() return R end
B.BuffLeft = function(_, unit, bi)
  local m = byUnit[unit]
  if not m then return nil end
  if m.name == 'Tarrow' and bi == 2 then return nil end
  if (m.name == 'Embera' or m.name == 'Kaelwyn') and bi == 4 then return nil end
  if m.class == 'PRIEST' and bi == 1 then return 185 end
  return 1500
end
B.IsLeader = function(_, n) return n == lead end
B.LeaderName = function() return lead end
B.CanEdit = function(_, n) return lead == 'Gina' or n == 'Gina' end
B.CanEditAny = function() return true end
B.ScanSelf = function() return false end
B.SpecOf = function(_, n)
  return ({ Caelith = 'Protection', Sunniva = 'Retribution', Gina = 'Holy', Lightbringer = 'Holy' })[n] or 'Holy'
end
local function pal(name, bless, aura, sym)
  local p = { name = name, bless = bless, aura = aura, symbols = sym, free = false, cd = {}, seen = GetTime() }
  B.pals[name] = p
end
for k in pairs(B.pals) do B.pals[k] = nil end
pal('Caelith', { { 7, 0 }, { 8, 0 }, { 1, 0 }, { 1, 0 }, { 4, 0 }, { 5, 1 } }, { { 8, 5 }, { 6, 0 }, { 1, 0 } }, 142)
pal('Sunniva', { { 7, 0 }, { 8, 5 }, nil, { 1, 0 }, { 4, 0 } }, { { 8, 0 }, { 6, 0 }, { 1, 0 }, [7] = { 1, 0 } }, 88)
pal('Gina', { { 7, 2 }, { 8, 0 }, nil, { 1, 0 }, { 4, 0 } }, { { 8, 0 }, { 6, 0 }, { 1, 3 } }, 196)
pal('Lightbringer', { { 7, 1 }, { 8, 0 }, nil, { 1, 0 }, { 4, 0 } }, { { 8, 0 }, { 6, 0 }, { 1, 0 } }, 12)
local s = B.Store()
s.assign, s.single, s.aura = {}, {}, {}
local function row(name, list)
  s.assign[name] = {}
  for j, cls in ipairs(B.D.DISPLAY) do s.assign[name][B.CLASS_INDEX[cls]] = list[j] end
end
row('Caelith', { 3, 3, 3, 3, 3, 3, 3, 3, 3 })
row('Sunniva', { 2, 2, 2, 2, 2, 2, 5, 5, 5 })
row('Gina', { 5, 5, 1, 1, 1, 1, 1, 1, 1 })
row('Lightbringer', { 4, 4, 4, 4, 4, 4, 4, 4, 4 })
s.single.Lightbringer = { [1] = { Victhar = 5 }, [5] = { Caelith = 5 }, [4] = { Moonwhisper = 5 } }
s.aura = { Caelith = 1, Sunniva = 7, Gina = 3, Lightbringer = 1 }
-- Caelith and Lightbringer share a party (the Devotion clash)
for _, m in ipairs(R) do if m.name == 'Lightbringer' or m.name == 'Caelith' then m.subgroup = 1 end end
"""


def bless_view(lead="Gina", lua=None, bar=False, theme="halo"):
    def fn(w, c):
        g = c["Gina"]
        demo_off(w, c)
        close_all(g)
        g.eval("ns.MainFrame:Close()")
        w.enter_instance("Black Temple", 564)
        w.make_raid([g] + [c[n] for n in ("Victhar", "Shadowmelder", "Moonwhisper", "Lightbringer", "Grumpykat")],
                    leader=g)
        w.tick(1)
        g.eval("ns.DB:SetSetting('bless.bar', ...); ns.DB:SetSetting('bless.layout', 'vertical')", "group" if bar else "off")
        g.eval("ns.DB:SetSetting('classbar.theme', ...)", theme)
        g.eval(BLESS_SEED, lead)
        if not bar:
            g.eval("ns.BlessingsUI:Open(); ns.BlessingsUI:Refresh()")
        else:
            g.eval("if ns.BlessingsUI:IsShown() then ns.BlessingsUI:Close() end; ns.BlessingsBar:Update()")
        g.eval("ns.Azero.clockHour = 12")                 # by day, unless the state says otherwise
        if lua:
            g.eval(lua)
        w.tick(0.3)
        return g
    return fn


STATES += [
    ("Blessings - planner (leader)", bless_view("Gina")),
    ("Blessings - planner (member)", bless_view("Lightbringer")),
    ("Blessings - planner, cell menu", bless_view("Gina", "local r = ns.BlessingsUI:GetFrame().rows[2]; "
                                                  "r.cells[1]:Click('LeftButton')")),
    ("Blessings - buff bar", bless_view("Gina", bar=True)),
    ("Blessings - buff bar, hunters", bless_view("Gina", "local f = ns.BlessingsBar:GetFrame(); for i = 1, 20 do "
                                                 "local r = _G['DisasterZoneBlessRow' .. i]; if r and r.data and "
                                                 "r.data.cls == 'HUNTER' then ns.BlessingsBar:TogglePop(r, true) end end",
                                                 bar=True)),
    ("Settings - Blessings", opened("settings", "ns.SettingsUI:SelectSection('bless')")),
]

STATES += [
    ("Settings - Class tools", opened("settings", "ns.SettingsUI:SelectSection('classtools')")),
    ("Settings - Class tools (demo)", demo("ns.SettingsUI:SelectSection('classtools')", key="settings")),
    ("Blessings - demo planner", demo("ns.MainFrame:Close(); ns.BlessingsUI:Open()")),
]

STATES += [
    ("Blessings - strip bar", bless_view("Gina", "ns.DB:SetSetting('bless.layout', 'horizontal'); ns.BlessingsBar:Update()",
                                         bar=True)),
    ("Blessings - strip bar, hunters", bless_view("Gina", "ns.DB:SetSetting('bless.layout', 'horizontal'); "
                                                  "ns.BlessingsBar:Update(); for i = 1, 20 do local r = _G['DisasterZoneBlessRow' .. i]; "
                                                  "if r and r.data and r.data.cls == 'HUNTER' then ns.BlessingsBar:TogglePop(r, true) end end", bar=True)),
]

# Totems (Core/Totems.lua, UI/TotemsUI.lua, UI/TotemBar.lua): the demo's 25-man Serpentshrine plan (four shamans, me
# the Enhancement one twisting, group 4 without a shaman, Hydross changing two totems). TOTEM_TWIST puts the demo's
# Windfury clock half a second from "drop now".
TOTEM_TWIST = "local d = ns.Totems:DemoState(); if d then d.started = GetTime() - 0.1 end"
STATES += [
    ("Totems - demo planner", demo("ns.MainFrame:Close(); ns.TotemsUI:SetBossTab(nil); ns.TotemsUI:Open()")),
    ("Totems - demo planner, Hydross", demo("ns.MainFrame:Close(); ns.TotemsUI:Open(); "
                                            "ns.TotemsUI:SetBossTab('SerpentshrineCavern:Hydross')")),
    ("Totems - demo planner, earth menu", demo("ns.MainFrame:Close(); ns.TotemsUI:SetBossTab(nil); ns.TotemsUI:Open(); "
                                               "ns.TotemsUI:GetFrame().rows[3].cells[1]:Click('LeftButton')")),
    ("Totems - demo rail", demo("ns.MainFrame:Close(); ns.TotemsUI:Close(); ns.DB:SetSetting('totems.layout', 'vertical'); "
                                + TOTEM_TWIST + "; ns.TotemBar:Update()")),
    ("Totems - demo rail, range", demo("ns.MainFrame:Close(); ns.TotemsUI:Close(); ns.DB:SetSetting('totems.layout', 'vertical'); "
                                       + TOTEM_TWIST + "; ns.TotemBar:Update(); ns.TotemBar:Hover(ns.TotemBar:Button('el3'), true)")),
    ("Totems - demo strip", demo("ns.MainFrame:Close(); ns.TotemsUI:Close(); ns.DB:SetSetting('totems.layout', 'horizontal'); "
                                 "ns.DB:SetSetting('totems.imbue', true); " + TOTEM_TWIST + "; ns.TotemBar:Update()")),
    ("Settings - Totems (demo)", demo("ns.DB:SetSetting('totems.layout', 'vertical'); ns.DB:SetSetting('totems.imbue', false); "
                                      "ns.SettingsUI:SelectSection('totems')", key="settings")),
]

# Meters for every demo player (DZ_AUDIT_METERS=1, not in the default run): the breakdown in each mode and tab, every
# bar's tooltip, both death recaps. Finds labels that outgrow their cards for some class / spec.
if os.environ.get("DZ_AUDIT_METERS"):
    _M_DPS = ("Victhar", "Moonwhisper", "Tsumil", "Gina", "Stonebrew", "Shadowmelder", "Brakkor", "Nightpaw",
              "Quentrell", "Sylvaris", "Darkstalkerr", "Lunessa", "Dreadhex", "Vexmora", "Kaelthrin", "Mirelle",
              "Yubell", "Stormcall", "Ashgrim")
    _M_HEAL = ("Thunderhoofx", "Brightmend", "Mendwell", "Pugsyhealer", "Treeleaf", "Aurelith", "Darkstalkerr",
               "Moonwhisper")
    _M_FIND = "local g; for k, a in pairs(ns.Meter:GetSegment('%s').actors) do if a.n == '%s' then g = k end end; "

    def _m_detail(name, mode, tab, sel="cur"):
        return opened("home", "ns.MainFrame:Close(); " + MET + (_M_FIND % (sel, name)) +
                      "ns.MeterDetail:Open('%s', g, '%s'); ns.MeterDetail:GetState().tab = '%s'; ns.MeterDetail:Draw()"
                      % (sel, mode, tab))

    def _m_tip(name, view, sel="cur"):
        return opened("home", "ns.MainFrame:Close(); " + MET + (_M_FIND % (sel, name)) +
                      "local L = ns.MeterPanels.Layout(); L.stacks[1].x, L.stacks[1].b, L.stacks[1].y = 700, 40, nil; "
                      "local p = L.stacks[1].panels[2]; p.rows = 25; p.tabs[1].view = '%s'; p.tabs[1].seg = '%s'; "
                      "ns.MeterPanels:Rebuild(); ns.MeterPanels:Draw(); local pf = ns.MeterPanels._Panel('%s'); "
                      "local row = pf.rowsByKey[g]; if not row then for _, x in pairs(pf.rowsByKey) do "
                      "if x.data and x.data.d and x.data.d.n == '%s' then row = x end end end; "
                      "if row then ns.MeterPanels.ShowRowTip(row) end" % (view, sel, view, name))

    for _n in _M_DPS:
        STATES.append(("Meters all - %s damage abilities" % _n, _m_detail(_n, "damage", "abilities")))
        STATES.append(("Meters all - %s damage targets (whole raid)" % _n, _m_detail(_n, "damage", "targets", "all")))
        STATES.append(("Meters all - %s damage over time" % _n, _m_detail(_n, "damage", "time")))
        STATES.append(("Meters all - %s tip damage" % _n, _m_tip(_n, "damage")))
    for _n in _M_HEAL:
        STATES.append(("Meters all - %s healing abilities" % _n, _m_detail(_n, "healing", "abilities")))
        STATES.append(("Meters all - %s tip healing" % _n, _m_tip(_n, "healing")))
    for _n in _M_DPS + ("Thunderhoofx", "Pugsyhealer"):
        STATES.append(("Meters all - %s taken abilities" % _n, _m_detail(_n, "taken", "abilities")))
        STATES.append(("Meters all - %s tip taken" % _n, _m_tip(_n, "taken")))
    for _n in ("Shadowmelder", "Brightmend", "Victhar"):
        STATES.append(("Meters all - %s tip interrupts / dispels" % _n, _m_tip(_n, "kicks" if _n != "Brightmend" else "dispels", "all")))
    for _n in ("Yubell", "Stonebrew"):
        STATES.append(("Meters all - %s tip death" % _n, _m_tip(_n, "deaths")))
        STATES.append(("Meters all - %s death recap" % _n, opened("home", "ns.MainFrame:Close(); " + MET +
            "for _, d in ipairs(ns.Meter:GetSegment('cur').deaths) do if d.n == '%s' then ns.MeterDetail:OpenDeath('cur', d) end end" % _n)))


BLESS_HOVER = ("local r = DisasterZoneBlessRow2; ns.BlessingsBar:Hover(r, true); "
               "for i = 1, 40 do ns.BlessingsBar.Step(r.face, 0.05) end")
STATES += [
    ("Blessings - buff bar, hover", bless_view("Gina", BLESS_HOVER, bar=True)),
    ("Blessings - strip bar, hover", bless_view("Gina", "ns.DB:SetSetting('bless.layout', 'horizontal'); "
                                                "ns.BlessingsBar:Update(); " + BLESS_HOVER, bar=True)),
]


# Class tool bar themes (UI/BarFace.lua): every theme on both bars, rail and strip (the same cells; only the axis turns)
for _t in ("halo", "sigil", "slate", "gilded", "pips", "classic"):
    STATES += [
        ("Bar themes - %s blessings rail" % _t, bless_view("Gina", bar=True, theme=_t)),
        ("Bar themes - %s blessings strip" % _t, bless_view("Gina", "ns.DB:SetSetting('bless.layout', 'horizontal'); "
                                                           "ns.BlessingsBar:Update()", bar=True, theme=_t)),
        ("Bar themes - %s totems rail" % _t, demo("ns.MainFrame:Close(); ns.TotemsUI:Close(); "
                                                  "ns.DB:SetSetting('classbar.theme', '%s'); "
                                                  "ns.DB:SetSetting('totems.layout', 'vertical'); " % _t
                                                  + TOTEM_TWIST + "; ns.TotemBar:Update()")),
        ("Bar themes - %s totems strip" % _t, demo("ns.MainFrame:Close(); ns.TotemsUI:Close(); "
                                                   "ns.DB:SetSetting('classbar.theme', '%s'); "
                                                   "ns.DB:SetSetting('totems.layout', 'horizontal'); " % _t
                                                   + TOTEM_TWIST + "; ns.TotemBar:Update()")),
    ]
STATES += [
    ("Bar themes - settings card", demo("ns.DB:SetSetting('classbar.theme', 'halo'); ns.DB:SetSetting('totems.layout', "
                                        "'vertical'); ns.SettingsUI:OpenKit('bless')", key="settings")),
]

# The developer's Performance page (Core/Perf.lua, UI/PerfUI.lua): only Tsumil has it, so a Tsumil client joins the
# guild (once), takes a few minutes of samples (garbage piling up, the game cleaning up), cleans up once and measures
# for 5 s while events fire before the page opens on a tab.
# (the mock has no addon profiler: a made-up one for the Tsumil client, so the CPU views have numbers to show)
PERF_PROFILER = """
Enum = Enum or {}
Enum.AddOnProfilerMetric = { SessionAverageTime = 0, RecentAverageTime = 1, EncounterAverageTime = 2, LastTime = 3,
  PeakTime = 4, CountTimeOver1Ms = 5, CountTimeOver5Ms = 6, CountTimeOver10Ms = 7, CountTimeOver50Ms = 8,
  CountTimeOver100Ms = 9 }
local V = { [0] = 0.41, [1] = 0.66, [2] = 0.92, [3] = 0.5, [4] = 38.2, [5] = 214, [6] = 12, [7] = 4, [8] = 1, [9] = 0 }
C_AddOnProfiler = { IsEnabled = function() return true end,
  GetAddOnMetric = function(name, m) local v = V[m] or 0 if m == 1 then v = v + 0.1 * math.sin(GetTime() / 30) end return v end,
  GetApplicationMetric = function(m) return 16.6 end }
"""
# addon messages over the last minutes (made up): guild data and control traffic, a few players
PERF_TRAFFIC = ("for i = 1, 20 do ns.PerfNet('in', 'CDLd', 480, 'Victhar-Thunderstrike') end "
                "for i = 1, 9 do ns.PerfNet('in', 'CDLd', 300, 'Grumpykat-Thunderstrike') end "
                "for i = 1, 14 do ns.PerfNet('in', 'CDLc', 60, 'Shadowmelder-Thunderstrike') end "
                "for i = 1, 6 do ns.PerfNet('in', 'CDLc', 60, 'Vaenyria-Thunderstrike') end "
                "for i = 1, 4 do ns.PerfNet('in', 'CDLa', 120, 'Moonwhisper-Thunderstrike') end "
                "for i = 1, 5 do ns.PerfNet('out', 'CDLd', 11000, 'GUILD') end "
                "for i = 1, 3 do ns.PerfNet('out', 'CDLc', 60, 'GUILD') end")


def perf_view(mode="overview"):
    def fn(w, c):
        t = c.get("Tsumil")
        if t is None:
            t = Client(w, "Tsumil", guild_rank=0, class_file="PALADIN",
                       preload_lua=(c["Gina"].preload_lua or "") + PERF_PROFILER)
            t.load_addon()
            teach_names(t)
            c["Tsumil"] = t
            for i in range(18):
                t.eval("__JUNK = __JUNK or {} for i = 1, 4000 do __JUNK[#__JUNK + 1] = { i } end")
                if i % 6 == 5:
                    t.eval("__JUNK = nil collectgarbage('collect')")
                w.tick(10)
            t.eval("__JUNK = nil ns.Perf:CleanUp()")
            for _ in range(6):
                t.eval("__JUNK = __JUNK or {} for i = 1, 3000 do __JUNK[#__JUNK + 1] = { i } end")
                t.eval(PERF_TRAFFIC)
                w.tick(10)
            t.eval("ns.Perf:Measure(5)")
            for _ in range(4):
                t.fire("PLAYER_TARGET_CHANGED")
                t.fire("GROUP_ROSTER_UPDATE")
                t.eval("ns.PerfComm('BLL', function() local x = {} for i = 1, 200 do x[i] = { i } end end, "
                       "'Victhar-Thunderstrike', { t = 'BLL', rev = 1791642530 }, 'GUILD') "
                       "ns.Comm:Send({ t = 'BLL', rev = 1791642531 }, 'GUILD', nil, 'data')")
                w.tick(1.5)
        close_all(t)
        t.slash("/dz perf")
        w.tick(0.6)
        if mode == "empty":                     # (the window with an empty body: a backdrop for page mockups)
            t.eval("ns.PerfUI._panel():Hide()")
        else:
            t.click(t.eval("return ns.PerfUI._panel().tabs.%s" % mode))
            w.tick(0.2)
        return t
    return fn


STATES += [
    ("Performance (Tsumil)", perf_view("overview")),
    ("Performance - garbage", perf_view("garbage")),
    ("Performance - memory", perf_view("memory")),
    ("Performance - network", perf_view("network")),
    ("Performance - cpu", perf_view("cpu")),
    ("Window - empty body (mock backdrop)", perf_view("empty")),
]


# The component gallery (refactor 1.4): every shared component and every page layout in a plain window
# (dev/tools/ui_gallery.py).
from ui_gallery import gallery  # noqa: E402

STATES += [
    ("Gallery - components", gallery("components")),
    ("Gallery - layouts", gallery("layouts")),
]

# Edit layout (UI/EditMode.lua, /dz edit) over the demo night, the quiet look: dashed outlines, the slim bar at the
# top with the picked frames' tools, Names, the Frames panel, the bar stepping back (a picked frame under it, a drag).
# (each state starts fresh: closed first, the session bar back at its own place, Names and the grid off)
EDIT = ("ns.MainFrame:Close(); __MOCK.real_geometry = true; ns.EditMode:Close(); ns.Layout:Reset('session'); "
        "ns.DB:SetSetting('editlayout.names', false); ns.DB:SetSetting('editlayout.grid', 0); ns.EditMode:Open(); "
        # (ui_look crops to named windows under 1900 wide: an invisible one nearly the whole screen)
        "local fb = DZAuditFull or CreateFrame('Frame', 'DZAuditFull', UIParent); fb:SetSize(1898, 1078); "
        "fb:SetPoint('CENTER'); fb:Show(); ")
# (the grid on: it shows while something is dragged)
EDIT_DRAG = (EDIT + "ns.EditMode:CycleGrid(); ns.EditMode:CycleGrid(); "
             "local l, b, w, h = ns.Layout:Rect('session'); __MOCK.cursor = { l + w / 2, b + h / 2 }; "
             "ns.EditMode:OnMoverDown('session', 'LeftButton'); __MOCK.cursor = { l + w / 2 - 3, b + h / 2 - 260 }; "
             "ns.EditMode:StepDrag()")
EDIT_UNDER = (EDIT + "local l, b, w, h = ns.Layout:Rect('session'); local W, H = ns.Layout.Screen(); "
              "ns.Layout:MoveTo('session', l, H - h - 8); ns.EditMode:Select({ 'session' })")
STATES += [
    ("Edit layout - open", demo(EDIT)),
    ("Edit layout - one picked", demo(EDIT + "ns.EditMode:Select({ 'session' })")),
    ("Edit layout - several picked", demo(EDIT + "ns.EditMode:Select({ 'session', 'roll', 'reminder' })")),
    # (the meters on too: their outline's chip, "drag by a header")
    ("Edit layout - names", demo("ns.DB:SetSetting('meters.dmg', true); ns.DB:SetSetting('meters.thr', true); "
                                 + EDIT + "ns.EditMode:Select({ 'roll' }); ns.EditMode:ToggleNames()")),
    ("Edit layout - frames menu", demo(EDIT + "ns.EditMode:Select({ 'session' }); ns.EditMode:ShowFrames(true)")),
    ("Edit layout - picked under the bar", demo(EDIT_UNDER)),
    ("Edit layout - mirror hint", demo(EDIT + "ns.EditMode:Select({ 'roll' }); ns.EditMode:GetBar().b.mirror1:Click()")),
    ("Edit layout - dragging", demo(EDIT_DRAG)),
    ("Settings - Layout", opened("settings", "ns.EditMode:Close(); ns.Layout:Reset('session'); "
                                             "ns.SettingsUI:SelectSection('layout')")),
]

# UI looks (UI/Look.lua, LookUnits / LookCast): every part's face in the five looks, made-up units
LOOK_GALLERY = r"""
ns.MainFrame:Close(); __MOCK.real_geometry = true
local p = DZLookGallery or CreateFrame('Frame', 'DZLookGallery', UIParent)
p:SetSize(1240, 640); p:ClearAllPoints(); p:SetPoint('CENTER'); p:Show()
if not p.bg then p.bg = p:CreateTexture(nil, 'BACKGROUND'); p.bg:SetAllPoints(); p.bg:SetColorTexture(0.16, 0.12, 0.2, 1) end
local U, C = ns.LookUnits, ns.LookCast
for i, key in ipairs(LOOKLIST) do
  local look = ns.Look.BY_KEY[key]
  local x = 16 + (i - 1) * 246
  local function face(kind, side, y, fake, w, xo)
    local h = CreateFrame('Frame', nil, p); h:SetPoint('TOPLEFT', p, 'TOPLEFT', x + (xo or 0), y)
    local f = U:NewFace(h, kind, kind == 'cell' and 'group' or 'units', side)
    f.width = w
    if fake.auras then f.showAuras = true; f.showCombo = true end
    f:Apply(look); f:Set(fake); return f
  end
  face('big', 'left', -24, U.Fake('player'))
  face('big', 'right', -94, U.Fake('target'))
  face('small', 'left', -190, U.Fake('tot'))
  face('small', 'left', -190, U.Fake('pet'), nil, 116)
  face('big', 'left', -230, U.Fake('member', 2), 184)
  for j = 1, 6 do
    face('cell', 'left', -300 - math.floor((j - 1) / 3) * 40, U.Fake('member', j + 2), 72, ((j - 1) % 3) * 76)
  end
  local cb = C:Sample(p, 'player', look); cb:SetPoint('TOPLEFT', p, 'TOPLEFT', x, -400)
  local ct = C:Sample(p, 'target', look); ct:SetPoint('TOPLEFT', p, 'TOPLEFT', x, -440)
  -- the bottom bar: action buttons, the menu (glyph tiles), the bags and the key ring
  local icons = { 132340, 132355, 132363, 132326, 135358, 136105 }
  for j, ic in ipairs(icons) do
    local b = CreateFrame('Button', nil, p); b:SetSize(32, 32)
    b:SetPoint('TOPLEFT', p, 'TOPLEFT', x + (j - 1) * 38, -486)
    b.icon = b:CreateTexture(nil, 'BACKGROUND'); b.icon:SetAllPoints(); b.icon:SetTexture(ic)
    b.HotKey = b:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight'); b.HotKey:SetText(tostring(j))
    b.NormalTexture = b:CreateTexture()
    ns.LookBars:Apply(b, look)
  end
  local menu = { 'CharacterMicroButton', 'SpellbookMicroButton', 'TalentMicroButton', 'QuestLogMicroButton',
                 'SocialsMicroButton', 'WorldMapMicroButton', 'MainMenuMicroButton', 'HelpMicroButton' }
  for j, n in ipairs(menu) do
    local b = CreateFrame('Button', nil, p); b:SetSize(28, 36); b.dzName = n
    b:SetPoint('TOPLEFT', p, 'TOPLEFT', x + (j - 1) * 29, -530)
    ns.LookBars:Tile(b, look)
  end
  local kr = CreateFrame('Button', nil, p); kr:SetSize(18, 36); kr.dzName = 'KeyRingButton'
  kr:SetPoint('TOPLEFT', p, 'TOPLEFT', x, -580); ns.LookBars:Tile(kr, look)
  for j, ic in ipairs({ 133628, 133633, 133640, 133639 }) do
    local b = CreateFrame('Button', nil, p); b:SetSize(30, 30); b.dzName = 'CharacterBag' .. (j - 1) .. 'Slot'
    b.Icon = b:CreateTexture(); b.Icon:SetTexture(ic)
    b:SetPoint('TOPLEFT', p, 'TOPLEFT', x + 24 + (j - 1) * 34, -583)
    ns.LookBars:Tile(b, look)
  end
end
"""
# Unit frames with long mob names (the numbers sit in the health bar; the name stops before whatever shares its row):
# the in-game case (Dreadfang Lurker under 3623 66%), a full-health elite (numbers over the bright fill), long small
# frames, Offline on the small row.
LOOK_LONG_NAMES = r"""
ns.MainFrame:Close(); __MOCK.real_geometry = true
local p = DZLookLongNames or CreateFrame('Frame', 'DZLookLongNames', UIParent)
p:SetSize(1530, 330); p:ClearAllPoints(); p:SetPoint('CENTER'); p:Show()
if not p.bg then p.bg = p:CreateTexture(nil, 'BACKGROUND'); p.bg:SetAllPoints(); p.bg:SetColorTexture(0.16, 0.12, 0.2, 1) end
local U = ns.LookUnits
local function mob(name, level, hp, hpMax, classif)
  return { exists = true, name = name, level = level, classif = classif, hp = hp, hpMax = hpMax, pt = 0, pw = 1,
           pwMax = 1, reaction = 2, isPlayer = false, portrait = 'Interface\\Icons\\Ability_Hunter_Pet_Spider' }
end
for i, key in ipairs({ 'flat', 'halo', 'sigil', 'slate', 'gilded', 'classic' }) do
  local look = ns.Look.BY_KEY[key]
  local x = 16 + (i - 1) * 246
  local function face(kind, side, y, d, w, xo)
    local h = CreateFrame('Frame', nil, p); h:SetPoint('TOPLEFT', p, 'TOPLEFT', x + (xo or 0), y)
    local f = U:NewFace(h, kind, 'units', side)
    f.width = w
    f:Apply(look); f:Set(d); return f
  end
  face('big', 'right', -16, mob('Dreadfang Lurker', 63, 3623, 5490))
  face('big', 'right', -76, mob('Ashtongue Deathsworn', 70, 9840, 9840, 'elite'))
  face('big', 'left', -136, mob('Shattered Hand Legionnaire', 70, 21000, 42000, 'elite'))
  face('small', 'left', -196, mob('Coilfang Myrmidon', 70, 5000, 9000))
  face('small', 'left', -196, { exists = true, name = 'Shadowmelder', class = 'ROGUE', isPlayer = true, level = 70,
                                hp = 0, hpMax = 9000, offline = true }, nil, 116)
  local m = U.Fake('member', 2); m.name = 'Moonwhisperwind'
  face('big', 'left', -236, m, 184)
end
"""
# Classic (UI/Look.lua look "classic"): every part's face in the game's own art, spaced for the game's bigger frames
CLASSIC_GALLERY = r"""
ns.MainFrame:Close(); __MOCK.real_geometry = true
local p = DZLookGallery or CreateFrame('Frame', 'DZLookGallery', UIParent)
p:SetSize(1240, 560); p:ClearAllPoints(); p:SetPoint('CENTER'); p:Show()
if not p.bg then p.bg = p:CreateTexture(nil, 'BACKGROUND'); p.bg:SetAllPoints(); p.bg:SetColorTexture(0.16, 0.12, 0.2, 1) end
local U, C = ns.LookUnits, ns.LookCast
local look = ns.Look.BY_KEY['classic']
local function face(kind, side, x, y, fake, w)
  local h = CreateFrame('Frame', nil, p); h:SetPoint('TOPLEFT', p, 'TOPLEFT', x, y)
  local f = U:NewFace(h, kind, kind == 'cell' and 'group' or 'units', side)
  f.width = w
  if fake.auras then f.showAuras = true; f.showCombo = true end
  f:Apply(look); f:Set(fake); return f
end
face('big', 'left', 20, -20, U.Fake('player'))
face('big', 'right', 270, -20, U.Fake('target'))
face('small', 'left', 300, -140, U.Fake('tot'))
face('big', 'right', 560, -20, U.Fake('focus'))
face('small', 'left', 20, -120, U.Fake('pet'))
for j = 1, 4 do face('big', 'left', 20, -190 - (j - 1) * 64, U.Fake('member', j), 184) end
for j = 1, 9 do
  face('cell', 'left', 270 + ((j - 1) % 3) * 92, -220 - math.floor((j - 1) / 3) * 42, U.Fake('member', j + 4), 86)
end
local cb = C:Sample(p, 'player', look); cb:SetPoint('TOPLEFT', p, 'TOPLEFT', 270, -360)
local ct = C:Sample(p, 'target', look); ct:SetPoint('TOPLEFT', p, 'TOPLEFT', 270, -420)
local icons = { 132340, 132355, 132363, 132326, 135358, 136105 }
for j, ic in ipairs(icons) do
  local b = CreateFrame('Button', nil, p); b:SetSize(36, 36)
  b:SetPoint('TOPLEFT', p, 'TOPLEFT', 860 + (j - 1) * 42, -40)
  b.icon = b:CreateTexture(nil, 'BACKGROUND'); b.icon:SetAllPoints(); b.icon:SetTexture(ic)
  b.HotKey = b:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight'); b.HotKey:SetText(tostring(j))
  b.NormalTexture = b:CreateTexture()
  ns.LookBars:Apply(b, look)
end
local menu = { 'CharacterMicroButton', 'SpellbookMicroButton', 'TalentMicroButton', 'QuestLogMicroButton',
               'SocialsMicroButton', 'WorldMapMicroButton', 'MainMenuMicroButton', 'HelpMicroButton' }
for j, n in ipairs(menu) do
  local b = CreateFrame('Button', nil, p); b:SetSize(28, 36); b.dzName = n
  b:SetPoint('TOPLEFT', p, 'TOPLEFT', 860 + (j - 1) * 32, -110)
  ns.LookBars:Tile(b, look)
end
local kr = CreateFrame('Button', nil, p); kr:SetSize(18, 36); kr.dzName = 'KeyRingButton'
kr:SetPoint('TOPLEFT', p, 'TOPLEFT', 860, -170); ns.LookBars:Tile(kr, look)
for j, ic in ipairs({ 133628, 133633, 133640, 133639 }) do
  local b = CreateFrame('Button', nil, p); b:SetSize(36, 36); b.dzName = 'CharacterBag' .. (j - 1) .. 'Slot'
  b.Icon = b:CreateTexture(); b.Icon:SetTexture(ic)
  b:SetPoint('TOPLEFT', p, 'TOPLEFT', 890 + (j - 1) * 42, -170)
  ns.LookBars:Tile(b, look)
end
"""
STATES += [
    ("UI looks - gallery", opened("home", LOOK_GALLERY.replace("LOOKLIST", "{ 'flat', 'halo', 'sigil', 'slate', 'gilded' }"))),
    ("UI looks - classic", opened("home", CLASSIC_GALLERY)),
    ("UI looks - long names", opened("home", LOOK_LONG_NAMES)),
    ("Settings - UI", opened("settings", "ns.SettingsUI:SelectSection('ui')")),
    # Interface > Looks in Halo and the parts' pages (a look set before the panel shows: no reload pop-up kept)
    ("Settings - Looks (Halo)", opened("settings", "ns.DB:SetSetting('ui.look', 'halo'); ns.Popup:HideAll(); "
        "ns.SettingsUI:SelectSection('looks'); ns.SettingsUI:Refresh()")),
    ("Settings - Look page (unit frames)", opened("settings", "ns.DB:SetSetting('ui.look', 'halo'); ns.Popup:HideAll(); "
        "ns.SettingsUI:OpenPart('units')")),
    ("Settings - Look page (party and raid)", opened("settings", "ns.DB:SetSetting('ui.look', 'gilded'); ns.Popup:HideAll(); "
        "ns.SettingsUI:OpenPart('group')")),
    ("Settings - Look page (cast bars)", opened("settings", "ns.DB:SetSetting('ui.look', 'sigil'); ns.Popup:HideAll(); "
        "ns.SettingsUI:OpenPart('cast')")),
    ("Settings - Look page (action bars)", opened("settings", "ns.DB:SetSetting('ui.look', 'classic'); ns.Popup:HideAll(); "
        "ns.SettingsUI:OpenPart('bars')")),
    ("Settings - Look page (combat text)", opened("settings", "ns.DB:SetSetting('ui.look', nil); ns.Popup:HideAll(); ns.SettingsUI:OpenPart('sct')")),
    ("Settings - Look page (timers, demo)", demo("ns.SettingsUI:OpenPart('timers')", key="settings")),
    ("Settings - Look page (class bars, demo)", demo("ns.SettingsUI:OpenPart('classbars')", key="settings")),
]

# Party and raid frames (UI/LookUnits.lua) in look LOOK: the made-up raid of 25 (as Edit layout shows it) and the
# party of 4 over a loading screen (the world behind them), laid out as the live headers lay them out.
GROUP_STATE = r"""
ns.MainFrame:Close(); __MOCK.real_geometry = true
local st = DZGroupStage or CreateFrame('Frame', 'DZGroupStage', UIParent)
st:SetSize(900, 430); st:ClearAllPoints(); st:SetPoint('CENTER'); st:Show()
if not st.bg then
  st.bg = st:CreateTexture(nil, 'BACKGROUND'); st.bg:SetAllPoints()
  st.bg:SetTexture('Interface' .. string.char(92) .. 'Glues' .. string.char(92) .. 'LoadingScreens' .. string.char(92) .. 'LoadScreenOutland')
  st.bg:SetTexCoord(0.05, 0.75, 0.25, 0.75)
end
for _, c in ipairs(st.cells or {}) do c:Hide() end
st.cells = st.cells or {}
local U, look = ns.LookUnits, ns.Look.BY_KEY['LOOK']
local gap = math.max(2, look.gap or 2)
for i = 1, 29 do
  local raid = i <= 25
  local c = st.cells[i]
  if not c then
    c = CreateFrame('Frame', nil, st)
    c.face = U:NewFace(c, raid and 'cell' or 'big', 'group', 'left')
    c.face.width = raid and 72 or 184
    st.cells[i] = c
  end
  c.face:Apply(look)
  local w, h = c:GetWidth(), c:GetHeight()
  c:ClearAllPoints()
  if raid then
    local col, row = math.floor((i - 1) / 5), (i - 1) % 5
    c:SetPoint('TOPLEFT', st, 'TOPLEFT', 16 + col * (w + gap), -16 - row * (h + gap))
  else
    c:SetPoint('TOPLEFT', st, 'TOPLEFT', 690, -16 - (i - 26) * (h + 10))
  end
  local d = U.Fake('member', raid and (i + 4) or (i - 25))
  if i == 1 then d.leader = true end
  if i == 9 then d.offline = true end
  if i == 19 then d.heal = d.hpMax * 0.2 end
  if i == 12 then d.dispel = 'Magic' end
  if i == 23 then d.dispel = 'Curse' end
  if i == 21 then d.raidIcon = 8 end
  if i == 17 then d.threat = 3 end
  c.face:Set(d)
  c:Show()
end
"""
STATES += [("Group frames - " + k, opened("home", GROUP_STATE.replace("LOOK", k)))
           for k in ("halo", "flat", "sigil", "slate", "gilded", "classic")]

# The main tanks block (UI/LookTanks.lua) over the raid frames in look LOOK, drawn with the same faces and data the
# live rows use: a mob on its tank (88%), one on a non-tank (red, "on Dreadhex"), one on another main tank (grey),
# a tank without a target (the plan's job, greyed). Under it the raid frames with the shields, my target (Torvald) and
# the cell under the mouse (Nyx). At the right: nobody set yet, the plan greyed with the leader's button.
TANKS_STATE = r"""
ns.MainFrame:Close(); __MOCK.real_geometry = true
local st = DZTankStage or CreateFrame('Frame', 'DZTankStage', UIParent)
st:SetSize(900, 470); st:ClearAllPoints(); st:SetPoint('CENTER'); st:Show()
if not st.bg then
  st.bg = st:CreateTexture(nil, 'BACKGROUND'); st.bg:SetAllPoints()
  st.bg:SetTexture('Interface' .. string.char(92) .. 'Glues' .. string.char(92) .. 'LoadingScreens' .. string.char(92) .. 'LoadScreenOutland')
  st.bg:SetTexCoord(0.05, 0.75, 0.25, 0.75)
end
for _, f in ipairs(st.parts or {}) do f:Hide() end
st.parts = {}
local U, LT, look = ns.LookUnits, ns.LookTanks, ns.Look.BY_KEY['LOOK']
local cw, ch = U.CellSize(look)
local gap = math.max(2, look.gap or 2)
local function Cell(x, y)
  local c = CreateFrame('Frame', nil, st)
  c.face = U:NewFace(c, 'cell', 'group', 'left')
  c.face:Apply(look)
  c:ClearAllPoints(); c:SetPoint('TOPLEFT', st, 'TOPLEFT', x, -y)
  st.parts[#st.parts + 1] = c
  return c
end
local RED, GREY = { 1, 0.42, 0.36 }, { 0.62, 0.6, 0.55 }
local rows = {
  { 'Victhar', 'WARRIOR', 0.72, { name = 'Maulgar', raidIcon = 8, hp = 0.88, statusText = '88%' } },
  { 'Ironbark', 'WARRIOR', 0.93, { name = 'Blindeye', raidIcon = 7, hp = 0.33, statusText = 'on Dreadhex', statusColor = RED, threat = 3 } },
  { 'Moonwhisper', 'DRUID', 0.88, { name = 'Olm', raidIcon = 6, hp = 0.9, statusText = 'on Victhar', statusColor = GREY } },
  { 'Brannoc', 'WARRIOR', 1, { name = 'Kiggler', raidIcon = 5, hp = 0, statusText = 'planned', statusColor = GREY, plan = true } },
}
for i, r in ipairs(rows) do
  local y = 16 + (i - 1) * (ch + gap)
  local t = Cell(16, y)
  t.face:Set({ exists = true, name = r[1], class = r[2], isPlayer = true, hp = math.floor(16000 * r[3]), hpMax = 16000, mt = i })
  local m = Cell(16 + cw + 2, y)
  local d = r[4]
  m.face:Set({ exists = true, name = d.name, isPlayer = false, reaction = 2, hp = d.hp * 1e6, hpMax = 1e6, raidIcon = d.raidIcon,
               statusText = d.statusText, statusColor = d.statusColor, threat = d.threat, selected = (i == 1) })
  if d.plan then m:SetAlpha(0.55) end
end
local top = 16 + #rows * (ch + gap) + 12
for i = 1, 25 do
  local col, row = math.floor((i - 1) / 5), (i - 1) % 5
  local c = Cell(16 + col * (cw + gap), top + row * (ch + gap))
  local d = U.Fake('member', i)
  d.far = nil
  if d.name == 'Victhar' then d.mt = 1 elseif d.name == 'Ironbark' then d.mt = 2 elseif d.name == 'Moonwhisper' then d.mt = 3 end
  if d.name == 'Brannoc' then d.mt = 4 end
  if d.name == 'Dreadhex' then d.threat = 3 end
  if d.name == 'Torvald' then d.selected = true end
  c.face:Set(d)
  if d.name == 'Nyx' then c.face:SetHover(true) end
end
-- nobody set yet: the plan, greyed, and the leader's button
local px = 520
for i, p in ipairs({ { 'Victhar', 'WARRIOR', 'Maulgar', 8 }, { 'Ironbark', 'WARRIOR', 'Blindeye', 7 } }) do
  local y = 16 + (i - 1) * (ch + gap)
  local t = Cell(px, y); t:SetAlpha(0.55)
  t.face:Set({ exists = true, name = p[1], class = p[2], isPlayer = true, hp = 0, hpMax = 1, statusText = '' })
  local m = Cell(px + cw + 2, y); m:SetAlpha(0.55)
  m.face:Set({ exists = true, name = p[3], isPlayer = false, reaction = 2, hp = 0, hpMax = 1, raidIcon = p[4],
               statusText = 'planned', statusColor = GREY })
end
local b = ns.UI:CreateSleekButton(st, 'Set as main tanks', 130, 22, nil, 'primary')
b:SetPoint('TOPLEFT', st, 'TOPLEFT', px, -(16 + 2 * (ch + gap)))
st.parts[#st.parts + 1] = b
local note = ns.UI:Text(st, 'small', 'SUB'); note:SetPoint('LEFT', b, 'RIGHT', 8, 0); note:SetText('From the plan')
local nf = CreateFrame('Frame', nil, st); st.parts[#st.parts + 1] = nf
"""
STATES += [("Main tanks - " + k, opened("home", TANKS_STATE.replace("LOOK", k)))
           for k in ("halo", "flat", "sigil", "slate", "gilded", "classic")]


# ---------------------------------------------------------------------------------------------------------------
# Gear > Wardrobe (Core/Wardrobe.lua, UI/Wardrobe.lua; mockup dev/art/casc/wardrobe_mockup)
# ---------------------------------------------------------------------------------------------------------------
WARDROBE_SEED = """
  local W = ns.Wardrobe
  local I = 'Interface' .. string.char(92) .. 'Icons' .. string.char(92)
  local key = ns.Util.PlayerKey()
  ns.db.wardrobe = ns.db.wardrobe or {}
  local old = ns.db.wardrobe[key]
  ns.db.wardrobe[key] = { outfits = {}, n = 0, bank = old and old.bank }
  local function slots(t)
    local s = {}
    for inv, id in pairs(t) do s[inv] = id and { id = id } or false end
    return s
  end
  local ret = W:SaveWorn('Raid \\226\\128\\148 Retribution')
  ret.icon = I .. 'Spell_Holy_AuraOfLight'
  W:SetRule(ret.id, 'spec', 'Retribution')
  local p = W:Add('Tank \\226\\128\\148 Protection', slots({ [1] = 29068, [3] = 29070, [15] = 28660, [5] = 29066,
    [9] = 29252, [10] = 29067, [6] = 30034, [7] = 29069, [8] = 33523, [11] = 28757, [12] = 29279, [13] = 28528,
    [16] = 28749, [17] = 28825, [18] = 29388, [2] = 28745 }), I .. 'Spell_Holy_DevotionAura')
  W:SetRule(p.id, 'spec', 'Protection')
  local h = W:Add('Hydross \\226\\128\\148 Nature res', slots({ [1] = 29508, [5] = 31364, [7] = 31367 }),
    I .. 'Spell_Nature_ResistNature')
  W:SetRule(h.id, 'boss', { kind = 'boss', name = 'Hydross the Unstable' })
  local f = W:Add('Fishing', slots({ [1] = 33820, [16] = 19970, [17] = false }), I .. 'Trade_Fishing')
  W:SetRule(f.id, 'pole', true)
  W:SetBar(true)
"""
# the Prot pieces in the bags, its main hand in the bank (seen last time it was open), Hydross's helm and legs in bags
WARDROBE_BAGS = {(0, 1): 29068, (0, 2): 29070, (0, 3): 28660, (0, 4): 29066, (0, 5): 29252, (0, 6): 29067,
                 (0, 7): 30034, (0, 8): 29069, (0, 9): 33523, (0, 10): 29279, (0, 11): 28528, (0, 12): 28825,
                 (0, 13): 29388, (0, 14): 29508, (0, 15): 31367, (0, 16): 33820, (1, 1): 19970, (1, 2): 28430,
                 (1, 3): 29171}


def wardrobe_view(lua=None, empty=False):
    """Gear > Wardrobe on Gina's screen: P1 Ret gear worn, four outfits (Ret worn, Prot from the bags + its main
    hand in the bank, Hydross missing its chest, Fishing); empty = no outfits yet."""
    def fn(w, c):
        g = c["Gina"]
        demo_off(w, c)
        close_all(g)
        g.equip(SIM_P1)
        g.set_bags(WARDROBE_BAGS)
        g.set_bank({(-1, 1): 28749})
        w.tick(0.3)
        g.close_bank()
        w.tick(0.3)
        if empty:
            g.eval("ns.db.wardrobe = ns.db.wardrobe or {}; ns.db.wardrobe[ns.Util.PlayerKey()] = nil; "
                   "ns.Wardrobe.Changed()")
        else:
            g.eval(WARDROBE_SEED)
        tab(g, "wardrobe")
        w.tick(0.3)
        g.eval("ns.Azero.clockHour = 12")                 # by day, unless the state says otherwise
        if lua:
            g.eval(lua)
        w.tick(0.3)
        return g
    return fn


STATES += [
    ("Wardrobe", wardrobe_view("local W = ns.Wardrobe; ns.WardrobeUI:Select(W:List()[2].id); "
                               "ns.WardrobeUI:SetTab('outfit')")),
    ("Wardrobe - rules", wardrobe_view("ns.WardrobeUI:Select(ns.Wardrobe:List()[1].id); "
                                       "ns.WardrobeUI:SetTab('auto')")),
    ("Wardrobe - picker", wardrobe_view("ns.WardrobeUI:Select(ns.Wardrobe:List()[2].id); "
                                        "ns.WardrobeUI:SetTab('outfit'); "
                                        "ns.WardrobeUI:OpenPicker(ns.WardrobeUI.view.body.tiles[15])")),
    ("Wardrobe - demo", demo("if DisasterZoneBlessBar then DisasterZoneBlessBar:Hide() end; "
                                 "ns.WardrobeUI:Select('prot'); ns.WardrobeUI:SetTab('outfit')", "wardrobe")),
    ("Wardrobe - empty", wardrobe_view(empty=True)),
    ("Wardrobe - bar", wardrobe_view("ns.MainFrame:Close(); ns.WardrobeUI:UpdateBar()")),
]

# Combat text (UI/CombatText.lua + UI/CombatTextLooks.lua): the mockup's Void Reaver pull (the demo pull) in each look,
# stopped at a moment: AuditCTBox = a named 900 x 540 (mockup px) frame over the stage with Tempest Keep's loading
# screen behind (ui_look crops to named windows), the target spot / you / alerts spots placed as in the mockup.
def sct_view(look, t=5.95, place="plate", extra=""):
    lua = ("ns.MainFrame:Close(); __MOCK.real_geometry = true; ns.DB:SetSetting('ui.sct.place', '%s'); "
           "ns.DB:SetSetting('ui.sct.look', '%s'); if ns.Popup then ns.Popup:HideAll() end; local CT = ns.CombatTextUI; CT:Restyle(); "
           "local o = ns.CTPen:Overlay(); local k = o:GetScale(); local H = UIParent:GetHeight(); "
           "for key, d in pairs(CT.SPOTS) do local f = CT.spots[key]; if f then f:ClearAllPoints(); "
           "if d.bottom then f:SetPoint('CENTER', UIParent, 'BOTTOM', 0, (d.bottom + 52 - 150) * k) "
           "else f:SetPoint('CENTER', UIParent, 'TOP', 0, -d.top * k) end end end; "
           "local bx = _G.AuditCTBox or CreateFrame('Frame', 'AuditCTBox', UIParent); bx:SetFrameStrata('BACKGROUND'); "
           "bx:ClearAllPoints(); bx:SetPoint('TOP', UIParent, 'TOP', 0, 0); bx:SetSize(940 * k, 540 * k); "
           "if not bx.bg then bx.bg = bx:CreateTexture(nil, 'BACKGROUND'); bx.bg:SetAllPoints(bx); "
           "bx.bg:SetTexture(131875); bx.bg:SetTexCoord(38 / 512, 474 / 512, 140 / 512, 385 / 512); "
           "bx.dim = bx:CreateTexture(nil, 'BORDER'); bx.dim:SetAllPoints(bx); bx.dim:SetColorTexture(0.03, 0.02, 0.055, 0.6) end; "
           "bx:Show(); for _, f in pairs(CT.spots) do f:SetFrameStrata('BACKGROUND') end; %s CT:QueuePull(false); for i = 1, %d do CT:Tick(1 / 60) end; o:SetScript('OnUpdate', nil)"
           % (place, look, extra, int(t * 60)))
    return opened("home", lua)


STATES += [("Combat text - %s" % _l, sct_view(_l)) for _l in ("flat", "halo", "sigil", "slate", "gilded", "classic")]
STATES += [("Combat text - %s ticks" % _l, sct_view(_l, 4.9)) for _l in ("flat", "halo", "sigil", "slate", "gilded")]
STATES += [("Combat text - %s end" % _l, sct_view(_l, 10.9)) for _l in ("flat", "halo", "sigil", "slate", "gilded", "classic")]
STATES += [("Combat text - %s alert" % _l, sct_view(_l, 7.95)) for _l in ("flat", "halo", "sigil", "slate", "gilded", "classic")]

# Nameplates (UI/Plates.lua): the demo's Maulgar council stopped at a moment (t: 1.3 casts, 6.3 threat, 11.3 execute
# range) over a named box with Gruul's Lair's loading screen behind (ui_look crops to named windows).
def plates_view(look, t=1.3, role="dps", plain=False):
    # plain: no marks, full health, nobody targeted (the plates a player sees most: dimmed, unmarked)
    pre = ("local P0 = ns.Plates; local dp = P0.DemoPlate; P0.DemoPlate = function(self, ...) local p = dp(self, ...); "
           "p.mark, p.hp, p.target, p.dim, p.auras, p.castInfo, p.glow = nil, 1, false, true, {}, nil, nil; return p end; ") if plain else ""
    lua = (pre + "ns.MainFrame:Close(); __MOCK.real_geometry = true; ns.DB:SetSetting('bossmods.role', '%s'); "
           "ns.DB:SetSetting('ui.plates.look', '%s'); if ns.Popup then ns.Popup:HideAll() end; local P = ns.Plates; "
           "local bx = _G.AuditPlatesBox or CreateFrame('Frame', 'AuditPlatesBox', UIParent); bx:SetFrameStrata('BACKGROUND'); "
           "local k = (UIParent:GetHeight() or 768) / 768; "
           "bx:ClearAllPoints(); bx:SetPoint('CENTER', UIParent, 'CENTER', 50 * k, 10 * k); bx:SetSize(900 * k, 360 * k); "
           "if not bx.bg then bx.bg = bx:CreateTexture(nil, 'BACKGROUND'); bx.bg:SetAllPoints(bx); "
           "bx.bg:SetTexture('Interface\\\\Glues\\\\LoadingScreens\\\\LoadScreenGruulsLair'); bx.bg:SetTexCoord(190 / 512, 1, 160 / 512, 300 / 512); "
           "bx.dim = bx:CreateTexture(nil, 'BORDER'); bx.dim:SetAllPoints(bx); bx.dim:SetColorTexture(0.03, 0.025, 0.02, 0.62) end; "
           "bx:Show(); P:TryIt('%s'); P.demo.anim = nil; P:DrawDemo(%s); _G.DisasterZonePlatesDemo:SetScript('OnUpdate', nil)"
           % (role, look, look, t))
    return opened("home", lua)


for _l in ("flat", "halo", "sigil", "slate", "gilded", "classic"):
    STATES += [("Nameplates - %s" % _l, plates_view(_l)), ("Nameplates - %s threat tank" % _l, plates_view(_l, 6.3, "tank")),
               ("Nameplates - %s threat" % _l, plates_view(_l, 6.3)), ("Nameplates - %s execute" % _l, plates_view(_l, 11.3)),
               ("Nameplates - %s plain" % _l, plates_view(_l, 0.5, plain=True))]

