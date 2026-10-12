"""Regression cases for the 1.4.1 bug fixes (architecture run, phase P1):

- D3: strategies, polls and events belong to the player, not the character: the owner's alt (Guild:SameAccount)
  edits and deletes them, on every 1.4.1 client; another member still cannot (nor with a forged message)
- D4: the attendance reviewer check takes the debug role for me only (IsOfficer(key, not IsMe(key)))
- the next raid's countdown (Blizzard Options > DisasterZone) and "Pause pop-ups for an hour" use server time, not
  the computer's clock
- a dungeon run's note is cut between letters (UTF-8), never shorter than the 40-byte cap for a note that fits
- UI:ColoredName goes through UI:ClassOf: a pug (a guest of the raid) gets their class colour
- the Events and Dungeons pages paint once per switch (an OnShow and OnPanelShown both refreshed them)
- Chess: Resign asks first; cancelling keeps the game

Run: luaenv\\Scripts\\python.exe tests\\regressions\\test_p1_bugs.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import World, Client, case, run_all, solo, no_errors, install_helpers, menu_pick, strip_codes  # noqa: E402

REALM = "Thunderstrike"


def K(name):
    return name + "-" + REALM


def own(cl, *alts):
    """As if those characters had logged in on cl's account (the saved variables are per account)."""
    cl.eval("local gk = ns.Guild:GetGuildKey(); ns.db.accounts = ns.db.accounts or {}; "
            "ns.db.accounts[gk] = ns.db.accounts[gk] or { mine = {}, v = {} }; "
            "for _, k in ipairs({...}) do ns.db.accounts[gk].mine[k] = true end", *[K(a) for a in alts])


# Gina the GM; Olaf an officer (polls) and his alt Oalt; Lee a member and his alt Lalt; Rita and Sam other members.
NAMES = (("Gina", 0, "PALADIN"), ("Olaf", 1, "WARRIOR"), ("Oalt", 4, "ROGUE"), ("Lee", 4, "WARRIOR"),
         ("Lalt", 4, "WARLOCK"), ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"))
PAIRS = (("Olaf", "Oalt"), ("Lee", "Lalt"))


def accounts_world():
    w = World()
    c = {}
    for name, rank, cls in NAMES:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    for main, alt in PAIRS:
        own(c[main], alt)
        own(c[alt], main)
    w.tick(50)          # everyone's own entry (the vouches) goes out 25-45 s after login
    for viewer in c.values():
        assert viewer.eval("return ns.Guild:SameAccount(...)", K("Lee"), K("Lalt")) is True, viewer.name
        assert viewer.eval("return ns.Guild:SameAccount(...)", K("Olaf"), K("Oalt")) is True, viewer.name
        assert viewer.eval("return ns.Guild:SameAccount(...)", K("Lee"), K("Rita")) is False, viewer.name
    return w, c


# ------------------------------------------------------------------------------------------------------------------
STRAT = """
local name = ...
return { b = 'BlackTemple:Council', n = name, p = { { id = 'p1', n = 'P1', m = 0, e = {}, k = {} } } }
"""


def strat(cl, sid):
    return cl.eval_py("local s = ns.Strategy:GetStrategy(...); return s and { n = s.n, ow = s.ow, by = s.by, "
                      "co = s.co } or false", sid)


def save_strat(cl, sid=None, name="Council farm"):
    return cl.eval_py("local src, id, n = ...; local d = id and ns.Strategy:GetStrategy(id) or (loadstring(src))(n); "
                      "d.n = n; local ok, r = ns.Strategy:SaveStrategy(d); return { ok = ok, r = r }", STRAT, sid, name)


@case
def an_owners_alt_edits_and_deletes_their_strategy_and_nobody_else_does():
    w, c = accounts_world()
    lee, lalt, rita, sam = c["Lee"], c["Lalt"], c["Rita"], c["Sam"]
    res = save_strat(lee)
    assert res["ok"] is True, res
    sid = res["r"]
    w.tick(3)
    assert lalt.eval("return ns.Strategy:IsOwner(...)", sid) is True
    assert lalt.eval("return ns.Strategy:CanEditStrategy(...)", sid) is True
    assert lalt.eval("return ns.Strategy:CanDeleteStrategy(...)", sid) is True
    assert rita.eval("return ns.Strategy:CanEditStrategy(...)", sid) is False
    assert rita.eval("return ns.Strategy:IsOwner(...)", sid) is False
    # the alt renames it: every client takes it, the owner stays Lee
    assert save_strat(lalt, sid, "Council by the alt")["ok"] is True
    w.tick(3)
    for n, x in c.items():
        s = strat(x, sid)
        assert s and s["n"] == "Council by the alt" and s["ow"] == K("Lee") and s["by"] == K("Lalt"), (n, s)
    # the alt picks the collaborators (the owner stays Lee: everyone takes it)
    res = lalt.eval_py("local ok, e = ns.Strategy:SetCollaborators(..., { select(2, ...) }); return { ok = ok, e = e }",
                       sid, K("Rita"))
    assert res["ok"] is True, res
    w.tick(3)
    for n, x in c.items():
        s = strat(x, sid)
        assert s["co"] == [K("Rita")] and s["ow"] == K("Lee"), (n, s)
    # another member can't change it, on their own client or with a forged message
    res = save_strat(sam, sid, "Sam's now")
    assert res["ok"] is False, res
    sam.eval("local id = ...; local d = ns.Strategy:GetStrategy(id); d.rev = d.rev + 10; d.n = 'forged'; "
             "d.by = ns.Util.PlayerKey(); ns.Comm:Send({ t = 'SBU', k = 'B', r = d }, 'GUILD', nil, 'data')", sid)
    w.tick(3)
    for n, x in c.items():
        if n != "Sam":
            assert strat(x, sid)["n"] == "Council by the alt", n
    assert sam.eval_py("local ok, e = ns.Strategy:DeleteStrategy(...); return ok", sid) is False
    # the alt deletes it, for everyone
    assert lalt.eval_py("local ok, e = ns.Strategy:DeleteStrategy(...); return { ok = ok, e = e }", sid)["ok"] is True
    w.tick(3)
    for n, x in c.items():
        assert strat(x, sid) is False, n
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
def poll(cl, pid):
    return cl.eval_py("local p = ns.Polls:GetPoll(...); return p and { by = p.by, cl = p.cl, q = p.q } or false", pid)


@case
def an_askers_alt_closes_and_removes_their_poll_and_a_member_does_not():
    w, c = accounts_world()
    olaf, oalt, rita, lee = c["Olaf"], c["Oalt"], c["Rita"], c["Lee"]
    pid = olaf.eval("""
        local id, why = ns.Polls:Create({ q = 'Raid on Sunday?', k = 'yn', a = { { 'p', ... } },
                                          cl = GetServerTime() + 3600, rv = 'vote', ch = true, mx = 0 })
        return id or ('ERR ' .. tostring(why))""", K("Rita"))
    assert pid and not str(pid).startswith("ERR"), pid
    w.tick(3)
    assert poll(rita, pid)["by"] == K("Olaf")
    p = "local p = ns.Polls:GetPoll(...); "
    assert oalt.eval(p + "return ns.Polls:CanManage(p)", pid) is True
    assert oalt.eval(p + "return ns.Polls:IsVisible(p)", pid) is True
    assert oalt.eval(p + "return ns.Polls:IsAsker(p)", pid) is True
    assert lee.eval(p + "return ns.Polls:CanManage(p)", pid) is False
    assert lee.eval("return ns.Polls:Close(...)", pid) is False
    # the alt closes it: everyone takes the change (written as the alt, the sender)
    assert oalt.eval("return ns.Polls:Close(...)", pid) is True
    w.tick(3)
    for n in ("Olaf", "Oalt", "Rita", "Gina"):
        x = poll(c[n], pid)
        assert x and x["by"] == K("Oalt") and c[n].eval(p + "return ns.Polls:IsOpen(p)", pid) is False, (n, x)
    # the main still manages it after the alt wrote it
    assert olaf.eval(p + "return ns.Polls:CanManage(p)", pid) is True
    # a member can't remove it; the alt can
    assert lee.eval("return ns.Polls:Delete(...)", pid) is False
    assert oalt.eval("return ns.Polls:Delete(...)", pid) is True
    w.tick(3)
    for n in ("Olaf", "Rita", "Gina", "Lee"):
        assert poll(c[n], pid) is False, n
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
def event(cl, eid):
    return cl.eval_py("local d = ns.Events:GetDef(...); return d and { name = d.name, by = d.by } or false", eid)


@case
def a_creators_alt_edits_and_deletes_their_event_and_a_member_does_not():
    w, c = accounts_world()
    lee, lalt, rita = c["Lee"], c["Lalt"], c["Rita"]
    eid = lee.eval("local d = ns.Events:NewDef(true); d.name = 'Lee cup'; assert(ns.Events:SaveDef(d)); return d.id")
    w.tick(3)
    assert event(rita, eid)["name"] == "Lee cup"
    get = "local d = ns.Events:GetDef(...); "
    assert lalt.eval(get + "return ns.Events:IsMine(d)", eid) is True
    assert rita.eval(get + "return ns.Events:IsMine(d)", eid) is False
    # a member can't save over it
    assert rita.eval("local d = ns.EventBlocks.Copy(ns.Events:GetDef(...)); d.name = 'Rita cup'; "
                     "return ns.Events:SaveDef(d)", eid) is False
    # the alt can: every client takes it
    assert lalt.eval("local d = ns.EventBlocks.Copy(ns.Events:GetDef(...)); d.name = 'Lee cup II'; "
                     "return ns.Events:SaveDef(d)", eid) is True
    w.tick(3)
    for n, x in c.items():
        e = event(x, eid)
        assert e and e["name"] == "Lee cup II" and e["by"] == K("Lalt"), (n, e)
    # the main still edits it after the alt did; the alt sends it in for review; a member can't delete it
    assert lee.eval(get + "return ns.Events:IsMine(d)", eid) is True
    assert lalt.eval("return ns.Events:SubmitForReview(..., 'please')", eid) is True
    w.tick(3)
    assert rita.eval(get + "return ns.Events:ReviewState(d)", eid) == "review"
    assert rita.eval("return ns.Events:DeleteDef(...)", eid) is False
    assert lalt.eval("return ns.Events:DeleteDef(...)", eid) is True
    w.tick(3)
    for n, x in c.items():
        assert event(x, eid) is False, n
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
@case
def the_debug_role_makes_only_me_an_attendance_reviewer():
    w = World()
    t = Client(w, "Tsumil", guild_rank=4, class_file="PALADIN")
    sam = Client(w, "Sam", guild_rank=4, class_file="ROGUE")
    for x in (t, sam):
        x.load_addon()
    w.tick(3)
    assert t.eval("return ns.Guild:IsAttendanceReviewer(...)", K("Tsumil")) is False
    t.slash("/dz role officer")
    w.tick(0.5)
    assert t.eval("return ns.db.debugRole") == "officer"
    assert t.eval("return ns.Guild:IsAttendanceReviewer(...)", K("Tsumil")) is True
    assert t.eval("return ns.Guild:IsAttendanceReviewer(...)", K("Sam")) is False
    # the other clients see Tsumil's real rank
    assert sam.eval("return ns.Guild:IsAttendanceReviewer(...)", K("Tsumil")) is False
    t.slash("/dz role off")
    assert t.eval("return ns.Guild:IsAttendanceReviewer(...)", K("Tsumil")) is False
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
LOCAL_CLOCK_BEHIND = r"""
-- the computer's clock 5 hours behind the realm's (time() only; GetServerTime is the realm's)
local real = time
time = function(t) if t ~= nil then return real(t) end return real() - 5 * 3600 end
"""

SWITCH_HELPERS = r"""
function T_settings() return ns.MainFrame:GetPanel("settings") end
function T_show_section_of(f)
  local p = f
  while p do
    local k = rawget(p, "key")
    if k and ns.SettingsUI.sections[k] == p then ns.SettingsUI:SelectSection(k); return k end
    p = p:GetParent()
  end
end
"""


@case
def the_next_raid_countdown_and_the_pop_up_pause_use_server_time():
    w, c = solo("Gina", guild_rank=0, tick=3)
    install_helpers(c)
    c.eval(LOCAL_CLOCK_BEHIND)
    res = c.eval_py("local ok, r = ns.RaidPlan:CreateRaid({ i = 'kara', t = GetServerTime() + 3 * 3600 + 1800 }); "
                    "return { ok = ok, r = r }")
    assert res["ok"] is True, res
    w.tick(1)
    c.eval("DisasterZoneBlizzardOptions:Hide(); DisasterZoneBlizzardOptions:Show()")
    w.tick(0.3)
    facts = [strip_codes(c.eval("local r = ...; return r:GetText()", r)) for r in c.find_text("Next raid")]
    assert facts and any("in 3h 29m" in f or "in 3h 30m" in f for f in facts), facts
    assert not any("in 8h" in f for f in facts), facts
    # Settings > Notifications: "Pause pop-ups for an hour" pauses for an hour of server time
    c.eval(SWITCH_HELPERS)
    c.slash("/dz settings")
    w.tick(0.5)
    sw = c.eval("return T_checkbox(T_settings(), ...)", "Pause pop-ups for an hour")
    assert sw is not None
    c.eval("T_show_section_of(...)", sw)
    w.tick(0.2)
    c.click(sw)
    w.tick(0.2)
    until = c.eval("return ns.db.settings.notify.dndUntil")
    srv = c.eval("return GetServerTime()")
    assert until is not None and abs(until - (srv + 3600)) <= 5, (until, srv)
    assert c.eval("local b = ...; return b:GetChecked()", sw) is True
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
@case
def a_dungeon_run_note_is_cut_between_letters():
    w = World()
    g = Client(w, "Gina", class_file="PALADIN", guild_rank=0)
    a = Client(w, "Alfa", class_file="PRIEST", guild_rank=3)
    for x in (g, a):
        x.load_addon()
    w.tick(50)
    cap = g.eval("return ns.DungeonRuns.NOTE_MAX")
    assert cap == 40, cap
    # 39 letters and an "é" (2 bytes: 40-41): the cut at 40 would split it; it goes whole
    note = "a" * 39 + "é" + "tc"
    rid = g.eval_py("local r, why = ns.DungeonRuns:List({ d = 'Botanica', h = true, role = 'healer', no = ... }); "
                    "return r and r.id or why", note)
    assert isinstance(rid, str) and ":" in rid, rid
    w.tick(3)
    check = ("local r = ns.DungeonRuns:GetRun(...); local s = r and r.no or ''; "
             "return { n = #s, last = s:byte(#s), ok = s == string.rep('a', 39) }")
    for x in (g, a):
        got = x.eval_py(check, rid)
        assert got == {"n": 39, "last": 97, "ok": True}, (x.name, got)
    # a note that fits (38 letters + "é" = 40 bytes) is kept whole: the cap is not smaller than 1.4.0's
    fits = "b" * 38 + "é"
    rid = g.eval_py("local r, why = ns.DungeonRuns:List({ d = 'Botanica', h = true, role = 'healer', no = ... }); "
                    "return r and r.id or why", fits)
    w.tick(3)
    for x in (g, a):
        got = x.eval_py("local r = ns.DungeonRuns:GetRun(...); local s = r.no; "
                        "return { n = #s, ok = s == select(2, ...) }", rid, fits)
        assert got == {"n": 40, "ok": True}, (x.name, got)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
@case
def a_pug_in_my_raid_gets_a_coloured_name():
    w = World()
    gina = Client(w, "Gina", guild_rank=0, class_file="PALADIN")
    pug = Client(w, "Pug", guild=None, class_file="WARLOCK")
    for x in (gina, pug):
        x.load_addon()
    w.tick(3)
    w.make_raid([gina, pug], leader=gina)
    w.tick(3)
    assert gina.eval("return ns.UI:IsGuest(...)", K("Pug")) is True
    out = gina.eval_py("""
        local key = ...
        local r, g, b = ns.UI:ClassColor('WARLOCK')
        return { name = ns.UI:ColoredName(key), cls = ns.UI:ClassOf(key),
                 hex = ('%02x%02x%02x'):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
                                              math.floor(b * 255 + 0.5)) }""", K("Pug"))
    assert out["cls"] == "WARLOCK", out
    assert out["name"].lower().startswith("|cff" + out["hex"]) and "Pug" in out["name"], out
    # a class given still wins, and a stranger nobody knows stays plain (white)
    assert gina.eval("local k = ...; return ns.UI:ColoredName(k, 'MAGE') == ns.UI:ColoredName('Pug', 'MAGE'):gsub("
                     "'Pug', ns.Util.DisplayName(k))", K("Pug")) is True
    assert gina.eval("return ns.UI:ClassOf(...)", K("Nobody")) is None
    assert gina.eval("return ns.UI:ColoredName(...)", K("Nobody")).lower().startswith("|cffffffff")
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
COUNT_REFRESH = r"""
local mod, page = ...
T_RF = T_RF or {}
T_RF[mod] = 0
local M = ns[mod]
if not M['T_orig_refresh'] then
  M['T_orig_refresh'] = M.Refresh
  M.Refresh = function(self, ...)
    local p = ns.MainFrame:GetPanel(page)
    if p and p:IsVisible() then T_RF[mod] = T_RF[mod] + 1 end
    return M['T_orig_refresh'](self, ...)
  end
end
"""


@case
def the_events_and_dungeons_pages_paint_once_per_switch():
    w, c = solo("Gina", guild_rank=0, tick=3)
    for mod, page in (("EventsUI", "events"), ("DungeonsUI", "dungeons")):
        c.eval(COUNT_REFRESH, mod, page)
        n = "return T_RF['%s']" % mod
        reset = "T_RF['%s'] = 0" % mod
        # the first visit (the page is built), a switch away and back, the window closed and opened again on it
        c.eval(reset + "; ns.MainFrame:Open(...)", page)
        assert c.eval(n) == 1, (page, "first visit", c.eval(n))
        c.eval("ns.MainFrame:Open('home')")
        c.eval(reset + "; ns.MainFrame:Open(...)", page)
        assert c.eval(n) == 1, (page, "switch", c.eval(n))
        c.eval("ns.MainFrame:Close()")
        c.eval(reset + "; ns.MainFrame:Open(...)", page)
        assert c.eval(n) == 1, (page, "reopen", c.eval(n))
        c.eval("ns.MainFrame:Close()")
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
@case
def chess_resign_asks_first_and_cancel_keeps_the_game():
    w, c = solo("Alice")
    c.eval("ns.MainFrame:Open('games') ns.GamesUI:Select('chess')")
    w.tick(1)
    gid = c.eval("local g = ns.Chess:NewAIGame(1, 'apprentice', false) ns.ChessUI:OpenGame(g) return g.id")
    w.tick(0.5)
    status = "return ns.Chess:Get(...).status"
    which = "DISASTERZONE_CONFIRM_DZ_CHESS_RESIGN"
    # the game's More menu: Resign opens the question, the game goes on
    more = [c.eval("local f = ...; if f.GetObjectType and f:GetObjectType() == 'FontString' then f = f:GetParent() end "
                   "return f", f) for f in c.find_text("···")]
    assert more, "no More button"
    c.click(more[-1])
    menu_pick(c, "Resign")
    assert c.eval("return ns.Popup:Visible(...) ~= nil", which) is True
    assert c.eval(status, gid) == "active"
    # Keep playing: the game goes on
    c.eval("local _, f = ns.Popup:Visible(...); ns.Popup:Click(f, 2)", which)
    assert c.eval("return ns.Popup:Visible(...) ~= nil", which) is False
    assert c.eval(status, gid) == "active"
    # Escape keeps it too
    c.eval("ns.ChessUI:ConfirmResign(ns.Chess:Get(...))", gid)
    c.eval("ns.Popup:EscapePressed()")
    assert c.eval(status, gid) == "active"
    # Resign: the game is over
    c.eval("ns.ChessUI:ConfirmResign(ns.Chess:Get(...))", gid)
    c.eval("local _, f = ns.Popup:Visible(...); ns.Popup:Click(f, 1)", which)
    assert c.eval(status, gid) == "over"
    no_errors(w)


if __name__ == "__main__":
    run_all()
