"""Disastercraft together (Games/Disastercraft/Party.lua): one world for the guild, parties, shared fights.

Covers, with two or three guild members playing at once on the harness's shared clock (0.1 s latency, the
server's per-prefix throttle): everyone sees everyone (name, level, class, gear) and a hero's walk plays smoothly a
second behind; WoW's party - invite, accept / decline, leave, uninvite, promote, the leader leaving; a creature
pulled by one is run by that client only (the others show it and send their hits there), it dies once, the party
shares the experience (WoW's group formula) and the quest credit, and its loot (free for all, money split); a
creature hits a remote hero on that hero's client; heals and buffs on another hero land on theirs; two pulling at
once end with one owner; an owner who leaves lets go (the creature goes home); party chat stays in the party, /say
stays near; the messages stay within the server's budget (about one a second per prefix).

Run: luaenv\\Scripts\\python.exe tests\\games\\test_craft_party.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, no_errors, World, Client  # noqa: E402

HELPER = r"""
T_DC = {}
local Craft = ns.Craft
local seed = 1
Craft.rng = function(a, b)
  seed = (seed * 1103515245 + 12345) % 2147483648
  local f = seed / 2147483648
  if a == nil then return f end
  if b == nil then a, b = 1, a end
  return a + math.floor(f * (b - a + 1))
end
function T_DC.seed(n) seed = n end
local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, dt) if T_DC.on then Craft:Update(dt) end end)
driver:Show()
T_DC.msgs, T_DC.errors = {}, {}
Craft:On("msg", function(t) T_DC.msgs[#T_DC.msgs + 1] = t end)
Craft:On("error", function(t) T_DC.errors[#T_DC.errors + 1] = t end)
function T_DC.start(cls, sex)
  Craft:NewCharacter(cls, sex or 0)
  Craft:Login(cls)
  Craft.World.Enter(Craft.char)
  Craft.Party.OnEnterWorld()
  T_DC.on = true
  return Craft.player
end
function T_DC.rec(guid) return Craft.World.recs[guid] end
-- the living spawn of `entry` nearest a point
function T_DC.findAt(entry, x, y)
  local best, bd
  for _, rec in pairs(Craft.World.recs) do
    local u = rec.unit
    if u and u.entry == entry and not u.dead then
      local d = (u.x - x) ^ 2 + (u.y - y) ^ 2
      if not bd or d < bd then best, bd = u, d end
    end
  end
  return best
end
-- the player on a free spot about yd yards from u (dir: -1 west, 1 east)
function T_DC.near(u, yd, dir)
  local p, W = Craft.player, Craft.World
  dir = dir or -1
  for r = 0, 8 do
    local x, y = u.x + dir * (yd / Craft.YARDS + r * 0.25), u.y
    if W.Fits(u.map, x, y) then p.map, p.x, p.y = u.map, x, y return true end
  end
  p.map, p.x, p.y = u.map, u.x + dir * yd / Craft.YARDS, u.y
  return false
end
-- other creatures stay out of a test fight (on every client alike)
function T_DC.calm(exceptGuid)
  for g, rec in pairs(Craft.World.recs) do
    if rec.unit and g ~= exceptGuid then rec.unit.hostile = false end
  end
end
function T_DC.said(pattern)
  for _, m in ipairs(T_DC.msgs) do if tostring(m.text or m):find(pattern) then return true end end
  return false
end
"""

NAMES = ["Alice", "Bob", "Carol"]


def guild(n=2, classes=(1, 5, 8)):
    w = World()
    cs = [Client(w, nm, guild_rank=3) for nm in NAMES[:n]]
    for c in cs:
        c.load_addon()
    w.tick(3)
    for i, c in enumerate(cs):
        c.eval(HELPER)
        c.eval("T_DC.seed(%d)" % (i + 3))
        c.eval("T_DC.start(%d, %d)" % (classes[i], i % 2))
    return w, cs


def key(c):
    return c.eval("return ns.Craft.Party.Me()")


def party(w, leader, others):
    """leader invites each of others by hero name; they accept."""
    for o in others:
        name = o.eval("return ns.Craft.char.name")
        leader.eval("ns.Craft.Party.Invite(...)", name)
        w.tick(0.6)
        assert o.eval("return ns.Craft.Party.invite ~= nil"), name
        o.eval("ns.Craft.Party.AcceptInvite()")
        w.tick(0.6)


def members(c):
    return c.eval_py("local g = ns.Craft.Party.group if not g then return nil end "
                     "local m = {} for i, k in ipairs(g.members) do m[i] = k end return { leader = g.leader, members = m }")


@case
def everyone_playing_sees_everyone_and_walks_smoothly():
    w, (a, b) = guild(2)
    w.tick(3)
    kb = key(b)
    seen = a.eval_py("local u = ns.Craft.Combat.units['P:' .. ...] "
                     "return u and { kind = u.kind, name = u.name, level = u.level, class = u.class, "
                     "  gear = u.char.equip[16] or 0, hp = u.hp, hpMax = u.hpMax } or false", kb)
    me = b.eval_py("local p = ns.Craft.player return { name = p.name, class = p.class, hpMax = p.hpMax, "
                   "gear = ns.Craft.char.equip[16] or 0 }")
    assert seen and seen["kind"] == "remote" and seen["name"] == me["name"] and seen["class"] == me["class"], (seen, me)
    assert seen["hpMax"] == me["hpMax"] and seen["gear"] == me["gear"], (seen, me)
    # the hub counts both
    assert a.eval("return ns.Craft.Party.PlayingCount()") == 2
    # Bob walks east for 2 s: on Alice's screen he follows the same way, smoothly, a second behind
    x0 = b.eval("return ns.Craft.player.x")
    b.eval("ns.Craft.World.input.dx, ns.Craft.World.input.dy = 1, 0")
    xs = []
    for _ in range(16):
        w.tick(0.25)
        xs.append(a.eval("return ns.Craft.Combat.units['P:' .. ...].x", kb))
    b.eval("ns.Craft.World.input.dx = 0")
    x1 = b.eval("return ns.Craft.player.x")
    w.tick(2.5)
    xa = a.eval("return ns.Craft.Combat.units['P:' .. ...].x", kb)
    assert x1 - x0 > 2, (x0, x1)
    assert abs(xa - x1) < 0.2, (xa, x1)
    steps = [xs[i + 1] - xs[i] for i in range(len(xs) - 1)]
    assert all(s >= -0.01 for s in steps), steps                 # (never backwards)
    assert max(steps) < 1.2, steps                               # (no jumps)
    # leaving the world: gone for the others at once
    b.eval("ns.Craft.Party.OnLeaveWorld() ns.Craft.World.Leave() T_DC.on = false")
    w.tick(1)
    assert a.eval("return ns.Craft.Combat.units['P:' .. ...] == nil", kb)
    no_errors(w)


@case
def a_party_forms_and_changes_like_wow():
    w, (a, b, c) = guild(3)
    w.tick(2)
    ka, kb, kc = key(a), key(b), key(c)
    party(w, a, [b])
    for x in (a, b):
        assert members(x) == {"leader": ka, "members": [ka, kb]}, members(x)
    # Carol declines, then accepts
    cname = c.eval("return ns.Craft.char.name")
    a.eval("ns.Craft.Party.Invite(...)", cname)
    w.tick(0.6)
    c.eval("ns.Craft.Party.DeclineInvite()")
    w.tick(0.6)
    assert a.eval("return T_DC.said('declines your group invitation')")
    assert members(c) is None
    party(w, a, [c])
    for x in (a, b, c):
        assert members(x) == {"leader": ka, "members": [ka, kb, kc]}, members(x)
    # only the leader invites, uninvites, promotes
    assert b.eval("return ns.Craft.Party.Kick(...) == nil and #ns.Craft.Party.group.members", kc) == 3
    a.eval("ns.Craft.Party.Promote(...)", kb)
    w.tick(0.6)
    for x in (a, b, c):
        assert members(x)["leader"] == kb, members(x)
    b.eval("ns.Craft.Party.Kick(...)", kc)
    w.tick(0.6)
    assert members(c) is None and members(a)["members"] == [ka, kb], (members(a), members(c))
    # the leader leaves: one member is no party
    b.eval("ns.Craft.Party.Leave()")
    w.tick(0.6)
    assert members(a) is None and members(b) is None
    # a party is five at most
    assert a.eval("return ns.Craft.Party.MAX") == 5
    no_errors(w)


def fight_setup(w, a, b, entry=257):
    """Alice and Bob in a party, both next to the same kobold, the other creatures calm."""
    party(w, a, [b])
    g = a.eval("local u = T_DC.findAt(%d, 4121, 6185) return u.guid" % entry)
    for i, x in enumerate((a, b)):
        x.eval("T_DC.calm(...) local u = ns.Craft.Combat.units[...] T_DC.near(u, 3, %d)" % (-1 if i == 0 else 1), g, g)
    w.tick(1.5)
    return g


@case
def a_pulled_creature_is_run_by_one_client_and_the_party_shares_the_kill():
    w, (a, b) = guild(2)
    w.tick(2)
    ka, kb = key(a), key(b)
    g = fight_setup(w, a, b)
    xp0 = [x.eval("return ns.Craft.char.xp") for x in (a, b)]
    a.eval("local u = ns.Craft.Combat.units[...] ns.Craft.World.SetTarget(u) ns.Craft.Combat.StartAttack(ns.Craft.player, u)", g)
    w.tick(2.5)
    # Alice's client runs it; Bob's knows (and shows Alice's numbers)
    assert a.eval("return T_DC.rec(...).owner", g) == ka
    assert b.eval("return T_DC.rec(...).owner", g) == ka
    lv = [x.eval("local u = ns.Craft.Combat.units[...] return u.level .. '/' .. u.hpMax", g) for x in (a, b)]
    assert lv[0] == lv[1], lv
    # Bob joins in: his hits land on Alice's client
    b.eval("local u = ns.Craft.Combat.units[...] ns.Craft.World.SetTarget(u) ns.Craft.Combat.StartAttack(ns.Craft.player, u)", g)
    for _ in range(80):
        w.tick(0.5)
        if a.eval("return ns.Craft.Combat.units[...].dead", g):
            break
    w.tick(2)
    assert a.eval("return ns.Craft.Combat.units[...].dead", g), "it never died"
    assert b.eval("return ns.Craft.Combat.units[...].dead", g), "Bob's copy is still alive"
    # both got the kill's experience, the group share (same level: half each times the 2-man rate)
    xp1 = [x.eval("return ns.Craft.char.xp") for x in (a, b)]
    gained = [xp1[i] - xp0[i] for i in range(2)]
    assert gained[0] > 0 and gained[1] > 0, gained
    assert abs(gained[0] - gained[1]) <= 1, gained
    solo_xp = a.eval("local u = ns.Craft.Combat.units[...] return ns.Craft.KillXP(1, u.level, u.elite, u.cr and u.cr.xpm) * ns.Craft.XP_RATE", g)
    assert gained[0] < solo_xp, (gained, solo_xp)
    # the loot is for both (Alice's roll), free for all
    la = a.eval_py("local l = T_DC.rec(...).loot return l and { money = l.money, n = #l.items } or false", g)
    lb = b.eval_py("local l = T_DC.rec(...).loot return l and { money = l.money, n = #l.items } or false", g)
    assert la == lb, (la, lb)
    # dying once: one death each, Alice released it
    assert a.eval("return T_DC.rec(...).owner", g) is None
    no_errors(w)


@case
def a_creature_hits_the_remote_hero_it_fights_on_that_heros_client():
    w, (a, b) = guild(2)
    w.tick(2)
    kb = key(b)
    g = fight_setup(w, a, b)
    a.eval("local u = ns.Craft.Combat.units[...] ns.Craft.World.SetTarget(u) ns.Craft.Combat.StartAttack(ns.Craft.player, u)", g)
    w.tick(1)
    # Bob taunts it the hard way: lots of threat on Alice's side (he hit it hard)
    a.eval("local u = ns.Craft.Combat.units[...] local bob = ns.Craft.Combat.units['P:' .. select(2, ...)] "
           "ns.Craft.Combat.StopAttack(ns.Craft.player) ns.Craft.Combat.AddThreat(u, bob, 500)", g, kb)
    hp0 = b.eval("return ns.Craft.player.hp")
    for _ in range(20):
        w.tick(0.5)
    hp1 = b.eval("return ns.Craft.player.hp")
    assert a.eval("return ns.Craft.Combat.units[...].target and ns.Craft.Combat.units[...].target.guid", g, g) == "P:" + kb
    assert hp1 < hp0, (hp0, hp1)
    # and Alice sees Bob's health as Bob's client has it
    w.tick(1.5)
    seen = a.eval("return ns.Craft.Combat.units['P:' .. ...].hp", kb)
    real = b.eval("return ns.Craft.player.hp")
    assert abs(seen - real) <= 15, (seen, real)
    no_errors(w)


@case
def heals_and_buffs_on_another_hero_land_on_their_client():
    w, (a, b) = guild(2, classes=(1, 5, 8))
    w.tick(2)
    ka = key(a)
    party(w, a, [b])
    b.eval("local p = ns.Craft.player p.x, p.y = ns.Craft.player.x, ns.Craft.player.y")
    a.eval("ns.Craft.player.hp = 10")
    w.tick(1.5)
    # Bob heals Alice (Lesser Heal, rank 1)
    b.eval("local al = ns.Craft.Combat.units['P:' .. ...] ns.Craft.World.SetTarget(al) "
           "local ok = ns.Craft.Combat.CastSpell(ns.Craft.player, 2050, al) T_OK = ok", ka)
    assert b.eval("return T_OK")
    w.tick(4)
    assert a.eval("return ns.Craft.player.hp") > 10
    # and buffs her (Power Word: Fortitude): the aura is on her hero, with its stamina
    sta0 = a.eval("return ns.Craft.player.sta")
    b.eval("local al = ns.Craft.Combat.units['P:' .. ...] ns.Craft.player.gcdEnd = nil "
           "ns.Craft.Combat.CastSpell(ns.Craft.player, 1243, al)", ka)
    w.tick(2.5)
    assert a.eval("return ns.Craft.Combat.FindAura(ns.Craft.player, 1243) ~= nil")
    assert a.eval("return ns.Craft.player.sta") > sta0
    no_errors(w)


@case
def two_pulling_at_once_end_with_one_owner():
    w, (a, b) = guild(2)
    w.tick(2)
    ka, kb = key(a), key(b)
    g = fight_setup(w, a, b)
    for x in (a, b):
        x.eval("local u = ns.Craft.Combat.units[...] ns.Craft.World.SetTarget(u) ns.Craft.Combat.StartAttack(ns.Craft.player, u)", g)
    w.tick(4)
    oa, ob = a.eval("return T_DC.rec(...).owner", g), b.eval("return T_DC.rec(...).owner", g)
    assert oa == ob and oa in (ka, kb), (oa, ob)
    for _ in range(80):
        w.tick(0.5)
        if a.eval("return ns.Craft.Combat.units[...].dead", g) and b.eval("return ns.Craft.Combat.units[...].dead", g):
            break
    assert a.eval("return ns.Craft.Combat.units[...].dead", g) and b.eval("return ns.Craft.Combat.units[...].dead", g)
    no_errors(w)


@case
def an_owner_who_leaves_lets_go_and_the_creature_goes_home():
    w, (a, b) = guild(2)
    w.tick(2)
    g = fight_setup(w, a, b)
    a.eval("local u = ns.Craft.Combat.units[...] ns.Craft.World.SetTarget(u) ns.Craft.Combat.StartAttack(ns.Craft.player, u)", g)
    w.tick(2)
    assert b.eval("return T_DC.rec(...).owner", g) is not None
    # (Bob watches from out of its reach: next to it, it would turn on him - and his client would run it)
    b.eval("local p = ns.Craft.player p.x = p.x + 14")
    # Alice's client simply stops (a disconnect: no goodbye)
    a.eval("T_DC.on = false")
    for _ in range(30):
        w.tick(0.5)
    st = b.eval_py("local r = T_DC.rec(...) local u = r.unit return { owner = r.owner or false, state = r.state, "
                   "hp = u.hp, max = u.hpMax }", g)
    assert st["owner"] is False and st["state"] in ("idle", "return", "evade"), st
    assert st["hp"] == st["max"], st
    no_errors(w)


@case
def party_chat_stays_in_the_party_and_say_stays_near():
    w, (a, b, c) = guild(3)
    w.tick(2)
    party(w, a, [b])
    a.eval("ns.Craft.Party.Chat('party', 'pull the next one')")
    w.tick(1)
    assert b.eval("return T_DC.said('%[Party%].*pull the next one')")
    assert not c.eval("return T_DC.said('pull the next one')")
    # /say: Carol far away does not hear it, Bob next to Alice does
    c.eval("local p = ns.Craft.player p.x = p.x + 60")
    w.tick(1.5)
    a.eval("ns.Craft.Party.Chat('say', 'hello there')")
    w.tick(1)
    assert b.eval("return T_DC.said('says: hello there')")
    assert not c.eval("return T_DC.said('hello there')")
    no_errors(w)


@case
def messages_stay_within_the_servers_budget():
    """About one message a second per prefix while fighting and walking (the server's per-prefix throttle lets 10 in a
    burst, then one a second)."""
    w, (a, b) = guild(2)
    w.tick(2)
    g = fight_setup(w, a, b)
    t0 = w.now
    a.eval("local u = ns.Craft.Combat.units[...] ns.Craft.World.SetTarget(u) ns.Craft.Combat.StartAttack(ns.Craft.player, u)", g)
    b.eval("local u = ns.Craft.Combat.units[...] ns.Craft.World.SetTarget(u) ns.Craft.Combat.StartAttack(ns.Craft.player, u)", g)
    for _ in range(40):
        w.tick(0.5)
    span = w.now - t0
    for x in (a, b):
        name = x.eval("return ns.Util.PlayerKey()")
        for prefix in ("CDLx", "CDLy"):
            sent = [e for e in w.addon_log if e["time"] >= t0 and e["prefix"] == prefix and e["sender"].startswith(name.split("-")[0])]
            rate = len(sent) / span
            assert rate <= 1.15, (name, prefix, len(sent), span)
    no_errors(w)


@case
def a_party_shares_quest_credit_and_splits_the_money():
    w, (a, b) = guild(2)
    w.tick(2)
    for x in (a, b):
        x.eval("local Q = ns.Craft.Quests Q.Accept(783) Q.TurnIn(783) Q.Accept(7)")      # (Kobold Camp Cleanup)
    g = fight_setup(w, a, b, entry=6)
    m0 = [x.eval("return ns.Craft.char.money") for x in (a, b)]
    for x in (a, b):
        x.eval("local u = ns.Craft.Combat.units[...] ns.Craft.World.SetTarget(u) ns.Craft.Combat.StartAttack(ns.Craft.player, u)", g)
    for _ in range(80):
        w.tick(0.5)
        if b.eval("return ns.Craft.Combat.units[...].dead", g):
            break
    w.tick(2)
    for x in (a, b):
        assert x.eval("local q = ns.Craft.char.quests[7] return q and q.k and q.k[6] or 0") == 1, x.name
    money = b.eval("local l = T_DC.rec(...).loot return l and l.money or 0", g)
    assert money == a.eval("local l = T_DC.rec(...).loot return l and l.money or 0", g)
    if money > 0:
        b.eval("ns.Craft.Loot.open = ns.Craft.Combat.units[...] ns.Craft.Loot.TakeMoney()", g)
        w.tick(3)
        got = [x.eval("return ns.Craft.char.money") - m0[i] for i, x in enumerate((a, b))]
        assert sum(got) == money and min(got) >= money // 2, (got, money)
        assert a.eval("local l = T_DC.rec(...).loot return l and l.money or 0", g) == 0
    no_errors(w)


@case
def damage_over_time_on_someone_elses_creature_ticks_once():
    """Bob's Shadow Word: Pain on the vermin Alice runs: it ticks on Bob's client (his numbers) and each tick lands
    once on Alice's - never a second time from her copy of the aura."""
    w, (a, b) = guild(2, classes=(1, 5, 8))
    w.tick(2)
    g = fight_setup(w, a, b, entry=6)
    for x in (a, b):
        x.eval("T_TICKS = 0 local G = ... ns.Craft:On('damage', function(src, dst, amt, info) "
               "if dst and dst.guid == G and info.kind == 'dot' and not info.display then T_TICKS = T_TICKS + 1 end end)", g)
    a.eval("local u = ns.Craft.Combat.units[...] ns.Craft.World.SetTarget(u) ns.Craft.Combat.StartAttack(ns.Craft.player, u)", g)
    w.tick(1.2)
    a.eval("ns.Craft.Combat.StopAttack(ns.Craft.player)")
    hp0 = a.eval("return ns.Craft.Combat.units[...].hp", g)
    b.eval("local u = ns.Craft.Combat.units[...] ns.Craft.World.SetTarget(u) T_OK = ns.Craft.Combat.CastSpell(ns.Craft.player, 589, u)", g)
    assert b.eval("return T_OK")
    for _ in range(44):
        w.tick(0.5)
    tb, ta = b.eval("return T_TICKS"), a.eval("return T_TICKS")
    assert tb >= 4 and ta == tb, (ta, tb)
    assert a.eval("return ns.Craft.Combat.units[...].hp", g) < hp0
    no_errors(w)


if __name__ == "__main__":
    run_all("games / craft party")
