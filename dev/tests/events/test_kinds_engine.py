"""Events, part 2: the general building blocks (Core/EventBlocks.lua, Core/EventEngine.lua), run straight on
ns.EventEngine:New with a fake clock, a made-up world (map positions in yards) and an out adapter that records what
the addon would show, tell, play and post.

Covers: the catalogue (11 categories, every palette piece, its blanks and what it gives, "happen" by its choice), the
definitions (tags, scores, places, lists, asks: built-in ones, new ids, names, uses), Migrate (part 1's pieces, in place
and once), Senses, the checks (gone definitions, an ask with no question, an empty walked list, Entrants given), the
plain words, the diff and kinds of the new blocks; the engine for every family: tags (split, gets, no one has),
scores (many players, places with ties, totals, reaches, the lead, caps), lists (items, questions, walking per
player), asks (every kind, votes, secret, time-out, close), buttons, places and the arrow, yards / nearest / warmer /
zones, touches, the radar, things that happen with filters, World's states / items / gold / nameplates, messages
(grouped, per player, the guild post's limit), timers (since, shown, a pause), Matches won by the pieces; and the
eight examples played end to end by made-up entrants: who won, scores, tags, moments, what was shown, told and posted.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_kinds_engine.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

# K.mk(def, n, opts): a live run of n players P1..Pn (already signed up, in that order) hosted by Host (not an
# entrant), a fake clock K.clock and a world of 1000 x 1000 yards maps; what the addon would do in K.shown
# ({ to = "P1,P2", text }), K.told ({ k, text } a player), K.posts (guild chat), K.sounds, K.plates, its log K.logs.
HELPERS = r"""
K = {}
local E, B = ns.EventEngine, ns.EventBlocks
N, C, V, J, If, IfElse, Each, ForItems, T = B.Build.N, B.Build.C, B.Build.V, B.Build.J, B.Build.If, B.Build.IfElse,
  B.Build.Each, B.Build.ForItems, B.Build.T
S = function(...) return B:Stack(...) end
HOST = "Host-Thunderstrike"
function K.short(k) return type(k) == "string" and (k:gsub("%-.*", "")) or tostring(k) end
function K.keys(list) local o = {} for i, k in ipairs(list or {}) do o[i] = K.short(k) end return table.concat(o, ",") end
function K.P(i) return "P" .. i .. "-Thunderstrike" end
function K.mk(def, n, opts)
  opts = opts or {}
  local names = {}
  for i = 1, n do names[i] = K.P(i) end
  K.clock = 1000
  K.shown, K.told, K.posts, K.sounds, K.plates, K.logs, K.asked = {}, {}, {}, {}, {}, {}, {}
  K.out = {
    show = function(keys, text) K.shown[#K.shown + 1] = { to = K.keys(keys), text = text } end,
    tell = function(keys, text) for _, k in ipairs(keys) do K.told[#K.told + 1] = { k = K.short(k), text = text } end end,
    guild = function(text) K.posts[#K.posts + 1] = text end,
    sound = function(keys, s) K.sounds[#K.sounds + 1] = K.keys(keys) .. ":" .. s end,
    plates = function(keys, off) K.plates[#K.plates + 1] = K.keys(keys) .. ":" .. tostring(off) end,
    asked = function(aid, a) K.asked[#K.asked + 1] = aid .. ":" .. tostring(a.q) end,
    zoneOf = function(k) return opts.zones and opts.zones[K.short(k)] end,
    log = function(kind, text) K.logs[#K.logs + 1] = kind .. ": " .. tostring(text) end,
  }
  K.run = E:New(def, { id = opts.id or "k", host = HOST, signups = opts.signups or names, out = K.out,
    now = function() return K.clock end, nameOf = K.short, practice = opts.practice,
    worldPos = function(map, x, y) return 1, x * 1000, y * 1000 end })
  K.names = names
  if not opts.noStart then K.run:Start() end
  return K.run, names
end
function K.adv(sec) for i = 1, sec do K.clock = K.clock + 1; K.run:Tick() end end
-- ticks a second at a time until fn() (at most max seconds): true if it came
function K.untilit(fn, max) for i = 1, max or 600 do if fn() then return true end K.adv(1) end return fn() and true or false end
function K.errors()
  local out = {}
  for _, l in ipairs(K.logs) do if l:find("^error") then out[#out + 1] = l end end
  return out
end
function K.tags(tid) return K.keys(K.run:Tagged(tid)) end
function K.score(sid, i) return K.run:GetScore(sid, K.P(i)) end
function K.scores(sid)
  local o = {}
  for _, r in ipairs(K.run:Ranked(sid)) do o[#o + 1] = K.short(r.key) .. "=" .. r.n end
  return table.concat(o, " ")
end
function K.told_to(who) local o = {} for _, t in ipairs(K.told) do if t.k == who then o[#o + 1] = t.text end end return o end
function K.texts(list) local o = {} for _, x in ipairs(list) do o[#o + 1] = x.text end return o end
function K.moments() local o = {} for _, m in ipairs(K.run.st.moments) do o[#o + 1] = m.text end return o end
function K.awards()
  local o = {}
  for _, a in ipairs(K.run.st.awards) do o[#o + 1] = K.short(a.p) .. ":" .. a.b end
  table.sort(o)
  return o
end
function K.season()
  local o = {}
  for k, n in pairs(K.run.st.stats[B.SEASON] or {}) do o[K.short(k)] = n end
  return o
end
function K.has(list, text) for _, x in ipairs(list) do if x == text then return true end end return false end
-- a bare event: stages s1, s2 (no sign-up block: the players are its entrants), scripts in s1 (top pieces)
function K.bare(...)
  local d = B:Blank("t")
  d.scripts = {}
  for i, top in ipairs({ ... }) do d.scripts[i] = { id = "x" .. i, st = "*", top = top } end
  return d
end
"""


def one():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(2)
    c.eval(HELPERS)
    return w, c


# ------------------------------------------------------------------------------------------------------------------
# The catalogue, definitions, Migrate, Senses, checks
# ------------------------------------------------------------------------------------------------------------------

@case
def the_catalogue_has_eleven_categories_and_every_piece_is_whole():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local cats = {}
        for _, x in ipairs(B.CATS) do cats[#cats + 1] = x.label end
        local bad = {}
        local inPalette = {}
        for cat, list in pairs(B.PALETTE) do
          if not B.CAT[cat] then bad[#bad + 1] = "no category " .. cat end
          for _, k in ipairs(list) do
            local p = B.PIECES[k]
            inPalette[k] = true
            if not p then bad[#bad + 1] = "missing " .. k
            elseif p.hide then bad[#bad + 1] = "hidden in the palette " .. k end
          end
        end
        for k, p in pairs(B.PIECES) do
          -- every blank in the words, and every word's blank a blank
          local seen = {}
          for n in p.text:gmatch("{(%d)}") do seen[tonumber(n)] = true end
          for i = 1, #(p.args or {}) do if not seen[i] then bad[#bad + 1] = k .. " has no {" .. i .. "}" end end
          for n in pairs(seen) do if not (p.args and p.args[n]) then bad[#bad + 1] = k .. " has no blank " .. n end end
          if not B.CAT[p.cat] then bad[#bad + 1] = k .. ": category " .. tostring(p.cat) end
          if (p.shape == "value") and not p.vt and k ~= "ctx" and k ~= "var" then bad[#bad + 1] = k .. " gives no type" end
          for _, g in ipairs(p.gives or {}) do if not B.CTX[g] then bad[#bad + 1] = k .. " gives " .. g end end
          if #p.text > 60 then bad[#bad + 1] = k .. " words too long" end
          if not inPalette[k] and not p.hide and not p.inner then bad[#bad + 1] = "not in the palette " .. k end
        end
        for _, h in ipairs(B.HAPPEN) do
          for _, g in ipairs(h.gives) do if not B.CTX[g] then bad[#bad + 1] = h.key .. " gives " .. g end end
        end
        -- part 1's pieces are gone (Migrate turns them into these)
        for _, k in ipairs({ "ch.say", "ch.wh", "ch.rw", "ev.duel", "ev.off", "ev.on", "ev.ready", "pt.vset" }) do
          if B.PIECES[k] then bad[#bad + 1] = "still there: " .. k end
        end
        local p = B:New("ev.happen")
        local g1 = table.concat(B:Gives(p), ",")
        p.a[1] = "loot"
        local g2 = table.concat(B:Gives(p), ",")
        local t2 = B:ArgType(p, 2)
        p.a[1] = "die"
        local t3 = B:ArgType(p, 2)
        local touch = B:New("pl.touch")
        local tt = { B:ArgType(touch, 4) or "none" }
        touch.a[3] = "emote"
        tt[2] = B:ArgType(touch, 4)
        return { cats = cats, bad = bad, g1 = g1, g2 = g2, t2 = t2, t3 = t3 or "none", tt = tt,
          happen = #B.HAPPEN, sounds = #B.SOUNDS, label = B.SMART.bracket.label,
          fits = { B:Fits("num", "any"), B:Fits("bool", "any"), B:Fits("where", "player"), B:Fits("place", "player"),
                   B:Fits("place", "place"), B:TakesPieces("place"), B:TakesPieces("tag") } }""")
    assert out["cats"] == ["Events", "Stages", "Logic", "Players", "Scores", "Places", "Ask", "Messages", "Timers",
                           "World", "Smart"], out["cats"]
    assert out["bad"] == [], out["bad"]
    assert out["g1"] == "player,other" and out["g2"] == "player,item,count", out
    assert out["t2"] == "item" and out["t3"] == "none" and out["tt"] == ["none", "emote"], out
    assert out["happen"] == 14 and out["sounds"] >= 5 and out["label"] == "Matches", out
    assert out["fits"] == [True, False, True, False, True, True, False], out["fits"]
    w.assert_no_errors()


@case
def definitions_have_built_in_ones_new_ids_names_and_uses():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local d = B:Blank("t")
        local t1 = B:NewDefinition(d, "tags", { n = "Hiders", c = "green" })
        local t2 = B:NewDefinition(d, "tags", { n = "A very long tag name that goes on and on" })
        local s1 = B:NewDefinition(d, "scores", { n = "Time", high = false, fmt = "time" })
        local a1 = B:NewDefinition(d, "asks", { n = "Best", q = "Who?" })
        local l1 = B:NewDefinition(d, "lists", { n = "Route", kind = "place" })
        local tags = {}
        for _, x in ipairs(B:Defs(d, "tags")) do tags[#tags + 1] = x.id .. "=" .. x.n .. (x.builtin and "*" or "") end
        local scores = {}
        for _, x in ipairs(B:Defs(d, "scores")) do scores[#scores + 1] = x.id .. "=" .. x.n end
        d.scripts = { { id = "x", st = "s1", top = S(N("ev.start"), N("pl.tag", N("pl.all"), t1),
          N("pl.untag", T(t1), t1), N("pt.add", 1, s1, N("pl.all"))) } }
        B:RemoveDefinition(d, "tags", t2)
        local defaults = d.asks[a1]
        return { ids = { t1, t2, s1, a1, l1 }, tags = tags, scores = scores,
          own = #B:Defs(d, "tags", true), uses = B:DefinitionUses(d, "tags", t1), name = B:DefinitionName(d, "tags", B.ENTRANTS),
          season = B:DefinitionName(d, "scores", B.SEASON), ask = { defaults.kind, defaults.votes, defaults.time,
          defaults.secret, defaults.self }, items = #d.lists[l1].items,
          fmt = { B:FormatScore(d, s1, 75), B:FormatScore(d, s1, 3725), B:FormatScore(d, B.SEASON, 2.5) } }""")
    assert out["ids"] == ["tg1", "tg2", "sc1", "ak1", "ls1"], out
    assert out["tags"] == ["entrants=Entrants*", "tg2=A very long tag name tha", "tg1=Hiders"], out["tags"]
    assert out["scores"] == ["Season points=Season points", "sc1=Time"], out
    assert out["own"] == 1 and out["uses"] == 3 and out["name"] == "Entrants" and out["season"] == "Season points", out
    assert out["ask"] == ["player", 1, 60, False, False] and out["items"] == 0, out
    assert out["fmt"] == ["1:15", "1:02:05", "2.5"], out
    w.assert_no_errors()


# A part 1 event as it was stored: its pieces as plain tables
PART1 = r"""
local function P(k, ...) return { k = k, a = { ... } } end
local function st(...) local first, last for _, p in ipairs({ ... }) do if last then last.n = p else first = p end last = p end return first end
OLD = ns.EventBlocks:Blank("Old cup")
OLD.vars = { { n = "Best", t = "player" } }
OLD.scripts = {
  { id = "a", st = "*", top = st(P("ev.duel"), P("ch.say", { j = { P("ctx", "winner"), " beats ", P("ctx", "loser") } }, "GUILD"),
      P("pt.add", 1, "Wins", P("ctx", "winner")), P("pt.vset", "Best", P("ctx", "winner"))) },
  { id = "b", st = "*", top = st(P("ev.off"), P("ch.wh", P("pl.host"), { j = { P("ctx", "player"), " is gone" } }),
      P("ch.say", "raid line", "RAID")) },
  { id = "c", st = "*", top = st(P("ev.on"), P("ch.rw", "back"), P("pt.set", "Points", P("ctx", "player"), 3)) },
  { id = "d", st = "*", top = st(P("ev.ready"), P("ch.moment", { j = { P("ctx", "player"), " is ready (", P("pt.get", P("ctx", "player"), "Wins"), ")" } }),
      P("ch.say", { j = { "top: ", P("pl.top", 1, "Wins") } }, "YELL")) },
}
"""


@case
def migrate_turns_part_1_pieces_into_the_new_ones_once():
    w, c = one()
    c.eval(PART1)
    out = c.eval_py("""
        local B = ns.EventBlocks
        local orig = B.Copy(OLD)
        -- a run migrates its own copy: what it was given is left as it was
        local run = K.mk(OLD, 2)
        local untouched = OLD.scripts[1].top.k == "ev.duel"
        local d = B.Copy(orig)
        local changed = B:Migrate(d)
        local keys = {}
        for _, s in ipairs(d.scripts) do
          local o = {}
          B:Walk(s.top, function(p) o[#o + 1] = p.k .. (p.k == "ctx" and ("(" .. p.a[1] .. ")") or "") end)
          keys[#keys + 1] = table.concat(o, " ")
        end
        local snap = B.Copy(d)
        local again = B:Migrate(d)
        local same = B.Words and true
        local function v(x) return type(x) == "table" and "t" or tostring(x) end
        local function sig(x) local o = {} B:Walk(x, function(p) o[#o + 1] = p.k .. ":" .. v(p.a[1]) .. ":" .. v(p.a[2]) .. ":" .. v(p.a[3]) end) return table.concat(o, ";") end
        for i, s in ipairs(d.scripts) do if sig(s.top) ~= sig(snap.scripts[i].top) then same = false end end
        local scores = {}
        for _, x in ipairs(B:Defs(d, "scores", true)) do scores[#scores + 1] = x.id .. "=" .. x.n end
        -- the migrated run plays: "is ready", a duel fires "wins a duel" with player and other, offline and back
        run:SetReady(K.P(1))
        run:Duel(K.P(1), K.P(2), true)
        run:SetOnline(K.P(2), false)
        run:SetOnline(K.P(2), true)
        return { untouched = untouched, changed = changed, again = again, same = same, keys = keys, scores = scores,
          probs = #B:Problems(d), posts = K.posts, told = K.told, shown = K.shown, moments = K.moments(),
          wins = K.scores(run:ScoreId("Wins")), best = K.short(run.st.vars.Best), err = K.errors() }""")
    assert out["untouched"] and out["changed"] is True and out["again"] is False and out["same"], out
    assert out["keys"] == [
        "ev.happen ch.guild ctx(player) ctx(other) pt.add ctx(player) lo.vset ctx(player)",
        "ev.happen ch.tell pl.host ctx(player) ch.show pl.all",
        "ev.happen ch.show pl.all pt.set ctx(player)",
        "ev.happen ch.moment ctx(player) pt.get ctx(player) ch.guild pl.top"], out["keys"]
    assert out["scores"] == ["sc2=Points", "sc1=Wins"], out["scores"]
    assert out["probs"] == 0, out
    assert out["posts"] == ["top: ", "P1 beats P2"], out["posts"]
    assert out["told"] == [{"k": "Host", "text": "P2 is gone"}], out["told"]
    assert [x["text"] for x in out["shown"]] == ["raid line", "back"] and out["shown"][0]["to"] == "P1,P2", out["shown"]
    assert out["moments"] == ["P1 is ready (0)"] and out["wins"] == "P1=1" and out["best"] == "P1", out
    assert out["err"] == [], out
    w.assert_no_errors()


@case
def senses_say_what_an_entrants_client_watches():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local function flat(s)
          local function keys(t) local o = {} for k, v in pairs(t) do if v then o[#o + 1] = tostring(k) end end table.sort(o) return table.concat(o, ",") end
          return { happen = keys(s.happen), places = keys(s.places), touch = keys(s.touch), radar = s.radar, pos = s.pos,
            zone = s.zone, flags = s.flags, items = keys(s.items), gold = s.gold, asks = s.asks, buttons = s.buttons }
        end
        local out = {}
        for _, e in ipairs(B:Examples()) do out[e.key] = flat(B:Senses(e.def)) end
        local d = K.bare(S(N("ev.start"), N("lo.vset", "x", N("wo.items", 23424, N("pl.host")))),
          S(N("ev.start"), N("lo.if", N("wo.is", N("pl.host"), "flying"))), S(N("ev.start"), N("lo.vset", "x", N("wo.gold", N("pl.host")))))
        d.vars = { { n = "x", t = "num" } }
        out.world = flat(B:Senses(d))
        return out""")
    assert out["duel"] == {"happen": "", "places": "", "touch": "", "radar": False, "pos": False, "zone": False,
                           "flags": False, "items": "", "gold": False, "asks": False, "buttons": False}, out["duel"]
    h = out["hide"]
    assert h["touch"] == "click" and h["radar"] and h["pos"] and h["zone"] and h["buttons"] and h["places"] == "pc1", h
    assert out["race"]["happen"] == "dismount" and out["race"]["places"] == "pc1,pc2,pc3,pc4,pc5,pc6,pc7,pc8", out["race"]
    assert out["fish"]["happen"] == "fish" and not out["fish"]["pos"], out["fish"]
    assert out["quiz"]["asks"] and not out["quiz"]["buttons"], out["quiz"]
    assert out["tmog"]["asks"], out["tmog"]
    assert out["redlight"]["happen"] == "move,stop" and out["redlight"]["places"] == "pc1,pc2", out["redlight"]
    assert out["world"]["items"] == "23424" and out["world"]["flags"] and out["world"]["gold"], out["world"]
    w.assert_no_errors()


@case
def the_checks_see_gone_definitions_empty_lists_and_asks_with_no_question():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local function texts(d) local o = {} for _, p in ipairs(B:Problems(d)) do o[#o + 1] = (p.script or "-") .. ":" .. tostring(p.slot) .. ": " .. p.text end return o end
        local r = {}
        local d = K.bare(S(N("ev.start"), N("pl.tag", N("pl.all"), "tg9"), N("pt.add", 1, "sc9", N("pl.all")),
          N("pc.point", N("pl.all"), "pc9"), N("lo.lnext", N("pl.all"), "ls9"), N("as.ask", N("pl.all"), "ak9")))
        r.gone = texts(d)
        d = K.bare(S(N("ev.start"), N("pl.tag", N("pl.all"), B.ENTRANTS), N("pt.add", 1, B.SEASON, T(B.ENTRANTS))))
        r.entrants = texts(d)
        d = B:Blank("t")
        local l = B:NewDefinition(d, "lists", { n = "Empty" })
        local a = B:NewDefinition(d, "asks", { n = "Nothing", q = "  " })
        local a2 = B:NewDefinition(d, "asks", { n = "Pick", q = "Which?", kind = "choice" })
        local p = B:NewDefinition(d, "places", { n = "Nowhere" })
        d.scripts = { { id = "x", st = "s1", top = S(N("ev.start"), ForItems(l, N("ch.moment", "x")), N("as.ask", N("pl.all"), a),
          N("as.askq", N("pl.all"), a), N("as.ask", N("pl.all"), a2), N("pc.point", N("pl.all"), p), N("as.give", N("pl.all"), "  "),
          N("ev.happen")) } }
        d.scripts[1].top.n.n.n.n.n.n.n = { k = "ev.happen", a = { "zz" } }
        r.empty = texts(d)
        -- optional blanks: "enters {any place}", "touches" with no players, "happen" with no filter
        d = B:Blank("t")
        B:NewDefinition(d, "places", { n = "Here", map = 1951, x = 0.5, y = 0.5 })
        d.scripts = { { id = "x", st = "s1", top = S(N("pc.enter"), N("ch.moment", J(C("player"), C("place")))) },
          { id = "y", st = "s1", top = S(N("pl.touch"), N("ch.moment", J(C("toucher"), C("touched")))) },
          { id = "z", st = "s1", top = S(N("ev.happen", "kill"), N("ch.moment", J(C("creature")))) },
          { id = "w", st = "s1", top = S(N("ev.happen", "die"), N("ch.moment", J(C("creature")))) } }
        r.optional = texts(d)
        d = B:Blank("t")
        local l2 = B:NewDefinition(d, "lists", { n = "Route", kind = "place", items = { "pc4" } })
        r.listPlace = texts(d)
        return r""")
    assert out["gone"] == ["x1:2: That tag is gone.", "x1:2: That score is gone.", "x1:2: That place is gone.",
                           "x1:2: That list is gone.", "x1:2: That ask is gone."], out["gone"]
    assert out["entrants"] == ["x1:2: Everyone in the event has Entrants: it can't be given or taken."], out["entrants"]
    assert out["empty"] == [
        "x:1: That list is empty.",
        "x:2: This ask has no question: type one in the ask, or use \"ask ... with\".",
        "x:3: Needs the question here.",
        "x:2: That ask has no choices to pick from.",
        "x:2: That place isn't on a map yet.",
        "x:2: Needs the button's name here.",
        "x:1: That choice is from a newer version of DisasterZone."], out["empty"]
    # (a filter of "dies" isn't there: the creature isn't known in that script)
    assert out["optional"] == ["w:nil: \"creature\" isn't known in this script."], out["optional"]
    assert out["listPlace"] == ["-:nil: The list Route has a place that's gone."], out["listPlace"]
    w.assert_no_errors()


@case
def the_examples_have_no_problems_and_read_in_plain_words():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local r = {}
        for _, e in ipairs(B:Examples()) do
          local probs = {}
          for _, p in ipairs(B:Problems(e.def)) do probs[#probs + 1] = p.text end
          local words = {}
          for _, s in ipairs(B:Describe(e.def)) do words[#words + 1] = s.name .. ": " .. s.text end
          r[#r + 1] = { key = e.key, name = e.name, icon = e.icon:sub(1, 16), art = B.ART_BY[e.art] ~= nil, desc = e.desc,
            probs = probs, words = words, grant = B:MaxSeasonGrant(e.def), kinds = table.concat(B:Kinds(e.def, true), ","),
            named = e.def.name == e.name }
        end
        local function sig(d) local o = {} for _, s in ipairs(d.scripts) do B:Walk(s.top, function(p) o[#o + 1] = p.k end) end return table.concat(o, ",") end
        return { r = r, starter = sig(B:Starter()) == sig(B:Examples()[1].def), example = B:Example("quiz").name,
          none = B:Example("zz") == nil }""")
    keys = [e["key"] for e in out["r"]]
    assert keys == ["duel", "hide", "infect", "race", "fish", "tmog", "quiz", "redlight"], keys
    for e in out["r"]:
        assert e["probs"] == [] and e["art"] and e["named"] and e["icon"] == "Interface\\Icons\\", e
        assert 0 < e["grant"] <= 100 and len(e["desc"]) <= 64, e
    assert out["starter"] and out["example"] == "Trivia night" and out["none"], out
    words = {e["key"]: e["words"] for e in out["r"]}
    assert "Bracket: Single elimination, best of 3, the final best of 5, seeded by season rank." in words["duel"], words["duel"]
    assert "Seek: Tags: Found. Most Finds wins." in words["hide"], words["hide"]
    assert "Race: Tags: Racing and Out. Fastest Time wins." in words["race"], words["race"]
    assert "Quiz: Most Right wins. Questions to answer." in words["quiz"], words["quiz"]
    assert out["r"][3]["kinds"] == "signup,tags,scores,places,lists", out["r"][3]
    w.assert_no_errors()


@case
def the_diff_shows_definitions_and_words_of_new_blocks():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local a = B:Example("hide")
        local b = B.Copy(a)
        b.tags.tg3.n = "Caught"
        b.tags.tg4 = { n = "Ghosts", c = "grey", shown = "all" }
        b.places.pc1.r = 400
        b.scores.sc2 = nil
        b.scripts[1].st = "*"
        local o = {}
        for _, x in ipairs((B:Diff(a, b))) do o[#o + 1] = x.kind .. "|" .. (x.text or x.piece.k) end
        table.sort(o)
        local touch = B.Words(nil, a, a.scripts[6].top)
        local happen = B.Words(nil, a, N("ev.happen", "fish", "Mr. Pinchy"))
        local die = B.Words(nil, a, N("ev.happen", "die"))
        return { o = o, touch = touch, happen = happen, die = die }""")
    assert out["o"] == ["add|New tag: Ghosts", "chg|Moved here from Sign-up: when Sign-up closes", "chg|Place: Play area",
                        "chg|Tag: Caught (was Found)", "del|Score taken out: Hidden"], out["o"]
    assert out["touch"] == "when one of ... touches one of ... by a click", out
    assert out["happen"] == "when an entrant catches a fish Mr. Pinchy" and out["die"] == "when an entrant dies", out
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# The engine, family by family
# ------------------------------------------------------------------------------------------------------------------

@case
def tags_split_evenly_tell_who_gets_one_and_when_no_one_has():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local d = K.bare(
          S(N("ev.start"), N("pl.split", N("pl.all"), "tg1", "tg2")),
          S(N("pl.gettag", "tg1"), N("ch.moment", J("red ", C("player")))),
          S(N("pl.notag", "tg1"), N("ch.moment", J("no reds"))),
          S(N("pl.notag", "tg3"), N("ch.moment", J("no greens"))))
        d.tags = { tg1 = { n = "Red", c = "red" }, tg2 = { n = "Blue", c = "blue" }, tg3 = { n = "Green", c = "green" } }
        local run = K.mk(d, 5)
        local r = { red = K.tags("tg1"), blue = K.tags("tg2"), moments = K.moments() }
        -- tag, has tag, players with tag, how many; Entrants is everyone and can't be given
        local p = { k = "pl.has", a = { K.P(1), "tg1" } }
        r.has = { run:HasTag("tg1", K.P(1)) or run:HasTag("tg2", K.P(1)), run:HasTag(B.ENTRANTS, K.P(3)), run:HasTag(B.ENTRANTS, HOST) }
        run:Tag(B.ENTRANTS, { "Out-Thunderstrike" })
        run:Tag("tg3", { K.P(1), "Nobody-Thunderstrike" })
        r.green = K.tags("tg3")
        -- the last red leaves the tag: "no one has" once
        run:Untag("tg1", run:Tagged("tg1"))
        run:Untag("tg1", { K.P(1) })
        run:Pump()
        r.after = K.moments()
        -- splitting again: only who changes side counts
        local before = #K.moments()
        run:Split(run:Tagged(B.ENTRANTS), "tg1", "tg2")
        run:Pump()
        r.again = { K.tags("tg1"), K.tags("tg2"), #K.moments() - before }
        -- leaving the event takes the tags with it
        run.st.entrantsSet = true
        run:Untag("tg3", {})
        run:Leave(K.P(1))
        r.left = { K.tags("tg3"), K.moments()[#K.moments()] }
        r.err = K.errors()
        return r""")
    reds, blues = out["red"].split(","), out["blue"].split(",")
    assert len(reds) == 3 and len(blues) == 2 and not set(reds) & set(blues), out
    assert sorted(m for m in out["moments"] if m.startswith("red ")) == sorted("red " + x for x in reds), out
    assert out["has"] == [True, True, False] and out["green"] == "P1", out
    assert out["after"].count("no reds") == 1 and "no greens" not in out["after"], out["after"]
    assert len(out["again"][0].split(",")) == 3 and out["again"][2] == 3, out["again"]   # three new reds, no "no one"
    assert out["left"] == ["", "no greens"] and out["err"] == [], out
    w.assert_no_errors()


@case
def scores_for_many_players_places_totals_reaches_and_the_lead():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local d = K.bare(
          S(N("ev.start"), N("pt.add", 2, "sc1", N("pl.all")), N("pt.set", "sc1", K.P(2), 5),
            N("pt.add", 1, "sc1", N("pl.top", 2, "sc1"))),
          S(N("pt.reach", "sc1", 5), N("ch.moment", J(C("player"), " reached 5"))),
          S(N("pt.lead", "sc1"), N("ch.moment", J(C("player"), " leads"))))
        d.scores = { sc1 = { n = "Fish", high = true, fmt = "num", board = true },
                     sc2 = { n = "Time", high = false, fmt = "time", board = true },
                     sc3 = { n = "Capped", high = true, cap = 10 } }
        local run = K.mk(d, 4)
        local r = { fish = K.scores("sc1"), moments = K.moments() }
        -- P2 6, then P1 3, P3 3, P4 2 (P1 first of the two by entrant order): places 1, 2, 2, 4
        r.place = { run:PlaceBy("sc1", K.P(2)), run:PlaceBy("sc1", K.P(1)), run:PlaceBy("sc1", K.P(3)), run:PlaceBy("sc1", K.P(4)) }
        -- a tie doesn't take the lead; passing does
        run:SetScore("sc1", K.P(3), 6); run:Pump()
        local m1 = K.moments()[#K.moments()]
        run:SetScore("sc1", K.P(3), 7); run:Pump()
        r.lead = { m1, K.moments()[#K.moments()] }
        -- lower wins; only who has the score is ranked; caps; season points are held per grant
        run:SetScore("sc2", K.P(4), 90); run:SetScore("sc2", K.P(1), 120)
        r.time = K.scores("sc2")
        run:SetScore("sc3", K.P(1), 50); run:SetScore("sc3", K.P(2), -50)
        r.capped = K.scores("sc3")
        run:SetScore(B.SEASON, K.P(1), 500, true); run:SetScore(B.SEASON, K.P(1), 500, true)
        r.season = K.season()
        local th = { ctx = {}, steps = 0 }
        local top = run:Ranked("sc2")
        r.top = { #top, run:PlaceBy("sc2", K.P(2)) }
        r.total = run:GetScore("sc1", K.P(1)) + run:GetScore("sc1", K.P(2))
        local res = run:Result()
        r.res = { K.short(res.champ), K.short(res.second), res.by, res.scores.sc1 ~= nil }
        r.unknown = { run:SetScore("zz", K.P(1), 3), run:GetScore("zz", K.P(1)) }
        r.err = K.errors()
        return r""")
    assert out["fish"] == "P2=6 P1=3 P3=2 P4=2" or out["fish"] == "P2=6 P1=3 P3=3 P4=2", out["fish"]
    # (2 each, P2 set to 5, then +1 to the top two: P2 and P1)
    assert out["fish"] == "P2=6 P1=3 P3=2 P4=2", out["fish"]
    assert out["moments"] == ["P1 leads", "P2 reached 5", "P2 leads"], out["moments"]
    assert out["place"] == [1, 2, 3, 3], out["place"]
    # (P3 at 6 ties the leader and reached 5 on the way; at 7 it leads)
    assert out["lead"] == ["P3 reached 5", "P3 leads"], out["lead"]
    assert out["time"] == "P4=90 P1=120" and out["capped"] == "P1=10 P2=-10", out
    assert out["season"] == {"P1": 200}, out["season"]
    assert out["top"] == [2, 0] and out["total"] == 9, out
    assert out["res"] == ["P3", "P2", "sc1", True], out["res"]
    assert out["err"] == [], out
    w.assert_no_errors()


@case
def lists_items_questions_and_walking_one_player_at_a_time():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local d = K.bare(
          S(N("ev.start"), ForItems("ls1", N("ch.moment", J("text ", C("item")))),
            ForItems("ls2", N("ch.moment", J("place ", C("item")))),
            N("lo.vset", "q", N("lo.litem", 2, "ls3")),
            N("ch.moment", J(N("lo.lcount", "ls1"), " ", N("lo.litem", 3, "ls1"), " ", V("q")))),
          S(N("lo.lend", "ls2"), N("ch.moment", J(C("player"), " is through"))))
        d.vars = { { n = "q", t = "text" } }
        d.places = { pc1 = { n = "Garadar", map = 1951, x = 0.5, y = 0.4 }, pc2 = { n = "Halaa", map = 1951, x = 0.4, y = 0.5 } }
        d.lists = { ls1 = { n = "Words", kind = "text", items = { "a", "b", "c" } },
                    ls2 = { n = "Route", kind = "place", items = { "pc2", "pc1" } },
                    ls3 = { n = "Quiz", kind = "question", items = { { q = "One?", a = { "1", "one" }, pts = 1 },
                            { q = "Two?", a = { "Two Times", "2" }, pts = 3 } } } }
        local run = K.mk(d, 2)
        local r = { moments = K.moments() }
        -- walking: each player at their own item; the end once
        local P1, P2 = K.P(1), K.P(2)
        local mine = function(k) return run:ItemValue("ls2", run:ListPos("ls2", k)) end
        r.start = { mine(P1), mine(P2), run:ListPos("ls2", P1) }
        run:ListNext("ls2", P1)
        r.next = { mine(P1), mine(P2), run:ListPos("ls2", P1) }
        run:ListNext("ls2", P1); run:ListNext("ls2", P1); run:Pump()
        r.done = { mine(P1) == nil, run:ListPos("ls2", P1), K.moments()[#K.moments()] }
        -- a question as a value: its words, its points, where it's from (never its answers)
        local q = run.st.vars.q
        r.q = { q.q, q.pts, q.ql, q.qi, q.a == nil }
        return r""")
    assert out["moments"] == ["text a", "text b", "text c", "place Halaa", "place Garadar", "3 c Two?"], out["moments"]
    assert out["start"] == ["pc2", "pc2", 1] and out["next"] == ["pc1", "pc2", 2], out
    assert out["done"] == [True, 3, "P1 is through"], out["done"]
    assert out["q"] == ["Two?", 3, "ls3", 2, True], out["q"]
    # "matches": capitals and spaces don't count; a question's answers or "a / b / c"; a question adds its points
    out = c.eval_py("""
        local d = K.bare(S(N("ev.start"),
          N("lo.vset", "q", N("lo.litem", 2, "ls1")),
          If(N("lo.match", "  two  TIMES ", V("q")), N("ch.moment", "a")),
          If(N("lo.match", "2", V("q")), N("ch.moment", "b")),
          If(N("lo.match", "three", V("q")), N("ch.moment", "c")),
          If(N("lo.match", "Kael thas", "Kael'thas / kaelthas / Kael"), N("ch.moment", "d")),
          If(N("lo.match", "", ""), N("ch.moment", "e")),
          N("pt.add", V("q"), "sc1", N("pl.all"))))
        d.vars = { { n = "q", t = "text" } }
        d.scores = { sc1 = { n = "Right" } }
        d.lists = { ls1 = { n = "Quiz", kind = "question", items = { { q = "One?", a = { "1" }, pts = 1 },
                    { q = "Two?", a = { "Two Times", "2" }, pts = 3 } } } }
        K.mk(d, 1)
        return { K.moments(), K.score("sc1", 1), K.errors() }""")
    assert out == [["a", "b", "d"], 3, []], out
    w.assert_no_errors()


@case
def asks_of_every_kind_take_one_valid_answer_and_close_by_themselves():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local d = K.bare(
          S(N("ev.start"), N("as.ask", N("pl.all"), "ak1"), N("ch.moment", J("vote over: ", N("as.top", "ak1"), " ",
            N("as.count", K.P(2), "ak1"))),
            N("as.askq", N("pl.all"), "ak2", "Pick a colour"), N("ch.moment", J("colour: ", N("as.top", "ak2"))),
            N("as.ask", N("pl.all"), "ak3"), N("ch.moment", J("typed: ", N("as.answer", K.P(1), "ak3"))),
            N("as.ask", N("pl.all"), "ak4"), N("ch.moment", J("yes or no: ", N("as.answer", K.P(1), "ak4"))),
            N("as.ask", N("pl.all"), "ak5"), N("ch.moment", J("number: ", N("as.answer", K.P(2), "ak5")))),
          S(N("as.on", "ak1"), N("ch.moment", J(C("player"), " voted ", C("answer")))),
          S(N("as.closed", "ak1"), N("ch.moment", J("ak1 closed"))))
        d.tags = { tg1 = { n = "Models" } }
        d.asks = {
          ak1 = { n = "Best", q = "Who?", kind = "player", from = "tg1", votes = 2, self = false, time = 60, secret = true },
          ak2 = { n = "Colour", q = "", kind = "choice", choices = { "Red", "Blue" }, time = 30 },
          ak3 = { n = "Typed", q = "Say it", kind = "text", time = 30 },
          ak4 = { n = "Yes", q = "Again?", kind = "yesno", time = 30 },
          ak5 = { n = "Num", q = "1 to 10", kind = "number", time = 20 } }
        d.scripts[1].top.n = S(N("pl.tag", { k = "pl.seed", a = { 2 } }, "tg1"), N("pl.tag", { k = "pl.seed", a = { 3 } }, "tg1"), d.scripts[1].top.n)
        local run = K.mk(d, 3)
        local P1, P2, P3 = K.P(1), K.P(2), K.P(3)
        local r = { asked = K.asked[1], open = run.st.qa.ak1.open, who = run.st.qa.ak1.n }
        -- not one of the models, oneself, too many, a non-entrant: refused; a second answer too
        r.refused = { run:AskAnswer("ak1", P1, P1), run:AskAnswer("ak1", P2, P2), run:AskAnswer("ak1", P1, { P2, P3, P2, P1 }),
          run:AskAnswer("ak1", "Out-Thunderstrike", P2), run:AskAnswer("ak1", P1, "Out-Thunderstrike") }
        r.ok = { run:AskAnswer("ak1", P1, { P2, P3 }), run:AskAnswer("ak1", P1, P2), run:AskAnswer("ak1", P3, P2) }
        -- secret: the state that goes out shows only who answered
        local snap = run:Snapshot()
        r.secret = { snap.qa.ak1.ans[P1], run.st.qa.ak1.ans[P1].list, run:Snapshot(true).qa.ak1.ans[P3] }
        run:AskAnswer("ak1", P2, P3)
        r.after1 = K.moments()
        r.closedSnap = run:Snapshot().qa.ak1.ans[P3]
        -- the choice: one of its choices (any case); a time-out closes it with who answered
        r.choice = { run:AskAnswer("ak2", P1, "Green"), run:AskAnswer("ak2", P1, "blue"), run.st.qa.ak2.ans[P1] }
        K.adv(31)
        r.typed = { run:AskAnswer("ak3", P1, "  |cffhello  "), run:AskAnswer("ak3", P2, "") }
        run:CloseAsk("ak3"); run:Resume()
        r.yes = { run:AskAnswer("ak4", P1, "maybe"), run:AskAnswer("ak4", P1, "no") }
        K.adv(31)
        r.num = { run:AskAnswer("ak5", P2, 11), run:AskAnswer("ak5", P2, 2.5), run:AskAnswer("ak5", P2, 7) }
        K.adv(21)
        r.moments = K.moments()
        r.err = K.errors()
        return r""")
    assert out["asked"] == "ak1:Who?" and out["open"] and out["who"] == 3, out
    assert out["refused"] == [False, False, False, False, False], out["refused"]
    assert out["ok"] == [True, False, True], out["ok"]
    # (an ask of several votes keeps a list, one pick or more)
    assert out["secret"][:2] == [True, True] and out["secret"][2] == {1: "P2-Thunderstrike", "list": True}, out["secret"]
    assert out["closedSnap"] == {1: "P2-Thunderstrike", "list": True}, out
    assert out["choice"] == [False, True, "Blue"], out["choice"]
    assert out["typed"] == [True, False] and out["yes"] == [False, True], out
    assert out["num"] == [False, False, True], out["num"]
    assert out["moments"] == [
        "P1 voted P2, P3", "P3 voted P2", "P2 voted P3", "ak1 closed", "vote over: P2 2", "colour: Blue",
        "typed: cffhello", "yes or no: no", "number: 7"], out["moments"]
    assert out["err"] == [], out
    w.assert_no_errors()


@case
def an_ask_closes_when_a_restore_comes_and_a_paused_one_waits():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(S(N("ev.start"), N("as.ask", N("pl.all"), "ak1"), N("ch.moment", "after")))
        d.asks = { ak1 = { n = "Q", q = "Ready?", kind = "yesno", time = 30 } }
        local run = K.mk(d, 2)
        -- a pause: the ask waits 30 s more than it would
        run.st.paused = K.clock
        K.clock = K.clock + 100
        run:Resume()
        local paused = run.st.qa.ak1.open
        run:Shift(100)
        run.st.paused = nil
        K.adv(20)
        local mid = { run.st.qa.ak1.open, run.st.qa.ak1.ends - K.clock }
        K.adv(15)
        local closed = { run.st.qa.ak1.open, K.moments() }
        -- a restored run: the open ask is closed (the script waiting for it is gone)
        local run2 = K.mk(d, 2)
        local r2 = ns.EventEngine:Restore(d, run2:Snapshot(true), { now = function() return K.clock end, out = K.out })
        return { paused = paused, mid = mid, closed = closed, restored = r2.st.qa.ak1.open, err = K.errors() }""")
    assert out["paused"] is True and out["mid"][0] is True and out["mid"][1] == 10, out
    assert out["closed"] == [False, ["after"]] and out["restored"] is False and out["err"] == [], out
    w.assert_no_errors()


@case
def buttons_are_given_pressed_and_taken_with_a_cooldown_of_general_pieces():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(
          S(N("ev.start"), N("as.give", N("pl.all"), "  Hint |"), N("as.give", N("pl.host"), "Hint")),
          S(N("as.press", "Hint"), N("ch.tell", C("player"), "a hint"), N("as.take", "Hint", C("player")), N("tm.wait", 60),
            N("as.give", C("player"), "Hint")))
        local run = K.mk(d, 2)
        local P1, P2 = K.P(1), K.P(2)
        local r = { holders = K.keys((function() local o = {} for k in pairs(run.st.buttons.Hint) do o[#o + 1] = k end table.sort(o) return o end)()) }
        r.press = { run:Press(P1, "Hint"), run:Press(P1, "Hint"), run:Press("Out-Thunderstrike", "Hint"), run:Press(P2, "Other") }
        K.adv(30)
        r.mid = run.st.buttons.Hint[P1] or false
        K.adv(31)
        r.back = { run.st.buttons.Hint[P1] or false, run:Press(P1, "  Hint ") }
        r.told = #K.told_to("P1")
        r.err = K.errors()
        return r""")
    assert out["holders"] == "Host,P1,P2", out
    assert out["press"] == [True, False, False, False] and out["mid"] is False, out
    assert out["back"] == [True, True] and out["told"] == 2 and out["err"] == [], out
    w.assert_no_errors()


@case
def places_the_arrow_yards_nearest_warmer_and_zones():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(
          S(N("pc.enter", "pc1"), N("ch.moment", J(C("player"), " in ", C("place")))),
          S(N("pc.enter"), N("ch.moment", J(C("player"), " anywhere ", C("place")))),
          S(N("pc.leave", "pc1"), N("ch.moment", J(C("player"), " left ", C("place")))),
          S(N("ev.start"), N("pc.point", N("pl.all"), "pc1")))
        d.places = { pc1 = { n = "Ring", map = 1951, x = 0.5, y = 0.5, r = 30 }, pc2 = { n = "Hut", map = 1951, x = 0.6, y = 0.5, r = 20 } }
        local run = K.mk(d, 3, { zones = { P3 = "Terokkar Forest" } })
        local P1, P2, P3 = K.P(1), K.P(2), K.P(3)
        local r = { point = run.st.point[P1] }
        run:Place(P1, "pc1", true); run:Place(P1, "pc1", true); run:Place(P2, "pc2", true); run:Place(P1, "pc1", false)
        run:Place("Out-Thunderstrike", "pc1", true); run:Place(P1, "pc9", true)
        r.moments = K.moments()
        r.arrow = { run.st.point[P1] or false, run.st.point[P2] }
        -- positions (host only): yards, the nearest, warmer / colder, subzone and zone (the roster's when not sensed),
        -- read by a script that runs again after each change
        local s = K.bare(S(N("ev.start"),
          N("ch.moment", J("yards ", N("pc.yards", P1, P2), " ", N("pc.yards", P1, "pc2"), " ", N("pc.yards", P3, "pc1"))),
          N("ch.moment", J("nearest ", N("pc.near", N("pl.all"), P1))),
          N("ch.moment", J("warm ", N("pc.warm", P2, P1))),
          N("ch.moment", J("in ", { k = "pc.in", a = { P1, "pc1" } }, " ", { k = "pc.in", a = { P2, "pc1" } })),
          N("ch.moment", J("zones ", N("pc.sub", P1), "/", N("pc.zone", P1), "/", N("pc.zone", P3), "/", N("pc.sub", P3), "."))))
        s.places = d.places
        local run2 = K.mk(s, 3, { zones = { P3 = "Terokkar Forest" }, noStart = true })
        -- (a position before the event is live is dropped)
        r.early = run2:Pos(P1, { map = 1951, x = 0.50, y = 0.50 })
        run2:Start()
        r.first = K.moments()[1]
        r.posOk = { run2:Pos(P1, { map = 1951, x = 0.50, y = 0.50, z = "Nagrand", sz = "Halaa" }),
          run2:Pos(P2, { map = 1951, x = 0.53, y = 0.54 }), run2:Pos("Out-Thunderstrike", { map = 1951, x = 0, y = 0 }) }
        run2:Place(P1, "pc1", true)
        local again = function() run2:Fire("ev.start", {}); run2:Pump(); return K.moments() end
        local m2 = again()
        run2:Pos(P2, { map = 1951, x = 0.51, y = 0.505 })
        local m3 = again()
        r.m2 = m2
        r.m3 = m3
        r.snap = { run2:Snapshot().pos == nil, run2:Snapshot().inplace == nil, run2:Snapshot(true).pos[P2] ~= nil }
        r.err = K.errors()
        return r""")
    assert out["point"] == "pc1" and out["arrow"] == [False, "pc1"], out
    assert out["moments"] == ["P1 in Ring", "P1 anywhere Ring", "P2 anywhere Hut", "P1 left Ring"], out["moments"]
    assert out["early"] is False and out["posOk"] == [True, True, False], out
    assert out["first"] == "yards 9999 9999 9999", out["first"]
    # P1 (500, 500), P2 (530, 540): 50 yards; the hut at (600, 500): 100; P3 isn't sensed: 9999
    m2 = out["m2"][-5:]
    assert m2 == ["yards 50 100 9999", "nearest P2", "warm the same", "in yes no",
                  "zones Halaa/Nagrand/Terokkar Forest/."], m2
    m3 = out["m3"][-5:]
    assert m3[0] == "yards 11 100 9999" and m3[2] == "warm warmer", m3
    assert out["snap"] == [True, True, True] and out["err"] == [], out
    w.assert_no_errors()


@case
def touches_the_radar_and_things_that_happen_with_their_filters():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(
          S(N("pl.touch", T("tg1"), T("tg2"), "click"), N("ch.moment", J(C("toucher"), " clicked ", C("touched")))),
          S(N("pl.touch", nil, nil, "emote", "WAVE"), N("ch.moment", J(C("toucher"), " waved at ", C("touched")))),
          S(N("pl.radar", T("tg1")), N("ch.moment", J(C("who"), " targeted ", C("whom")))),
          S(N("ev.happen", "kill", "Hogger"), N("ch.moment", J(C("player"), " killed ", C("creature")))),
          S(N("ev.happen", "kill"), N("ch.moment", J(C("player"), " killed something: ", C("creature")))),
          S(N("ev.happen", "loot", 23424), N("ch.moment", J(C("player"), " looted ore x", C("count")))),
          S(N("ev.happen", "fish", "mr. pinchy"), N("ch.moment", J(C("player"), " fished ", C("item")))),
          S(N("ev.happen", "emote", "dance"), N("ch.moment", J(C("player"), " danced with ", C("other")))),
          S(N("ev.happen", "die"), N("ch.moment", J(C("player"), " died"))))
        d.tags = { tg1 = { n = "Seekers" }, tg2 = { n = "Hiders" } }
        local run = K.mk(d, 3)
        local P1, P2, P3 = K.P(1), K.P(2), K.P(3)
        run:Tag("tg1", { P1 }); run:Tag("tg2", { P2, P3 })
        local r = {}
        r.ok = { run:Touch(P1, P2, "click"), run:Touch(P2, P3, "click"), run:Touch(P1, P3, "point"), run:Touch(P3, P1, "emote", "wave"),
          run:Touch(P1, P1, "click"), run:Touch(P1, "Out-Thunderstrike", "click"), run:Touch(P1, P2, "lick"),
          run:Radar(P1, P3), run:Radar(P2, P3) }
        run:Happen(P1, "kill", { creature = "hogger" })
        run:Happen(P2, "kill", { creature = "Murloc" })
        run:Happen(P2, "loot", { item = 23424, name = "Fel Iron Ore", count = 3 })
        run:Happen(P2, "loot", { item = 23425, name = "Adamantite Ore", count = 2 })
        run:Happen(P3, "fish", { item = 27388, name = "Mr. Pinchy" })
        run:Happen(P3, "emote", { emote = "DANCE", other = P1 })
        run:Happen(P1, "die")
        run:Happen("Out-Thunderstrike", "die")
        run:Happen(P1, "zz")
        r.moments = K.moments()
        -- states: mounted / moving from "happen", flying / swimming / in combat from positions, items and gold
        run:Happen(P1, "mount"); run:Happen(P2, "move"); run:Happen(P2, "stop")
        run:Pos(P3, { fl = true, cb = true, items = { [23424] = 7 }, gold = 12345 })
        local s = K.bare(S(N("ev.start"),
          N("ch.moment", J(N("wo.is", P1, "mounted"), N("wo.is", P2, "moving"), N("wo.is", P3, "flying"), N("wo.is", P3, "combat"),
            N("wo.is", P3, "swimming"), N("wo.is", P1, "dead"), " ", N("wo.items", 23424, P3), " ", N("wo.gold", P3)))))
        run.byHat["ev.start"] = nil
        for _, x in ipairs(s.scripts) do table.insert(run.def.scripts, x) end
        run:IndexScripts()
        run:Fire("ev.start", {}); run:Pump()
        r.states = K.moments()[#K.moments()]
        r.err = K.errors()
        return r""")
    assert out["ok"] == [True, True, True, True, False, False, False, True, True], out["ok"]
    assert out["moments"] == [
        "P1 clicked P2", "P3 waved at P1", "P1 targeted P3",
        "P1 killed hogger", "P1 killed something: hogger", "P2 killed something: Murloc", "P2 looted ore x3",
        "P3 fished Mr. Pinchy", "P3 danced with P1", "P1 died"], out["moments"]
    assert out["states"] == "yesnoyesyesnoyes 7 12345", out["states"]
    assert out["err"] == [], out
    w.assert_no_errors()


@case
def messages_are_grouped_said_per_player_and_the_guild_post_is_held_to_its_limit():
    w, c = one()
    out = c.eval_py("""
        local d = ns.EventBlocks:Starter()
        d.blocks.b2.set.seed = "order"; d.blocks.b2.set.bo = 1
        table.insert(d.scripts, { id = "m1", st = "*", top = S(N("bk.start", "b2"),
          N("ch.tell", C("both"), J("You're up vs ", C("opponent"))), N("ch.show", N("pl.all"), J("Match: ", C("player1"))),
          N("ch.sound", "ready", C("both")), N("ch.sound", "nope", C("both")), N("ch.tell", "Out-Thunderstrike", "x")) })
        table.insert(d.scripts, { id = "m2", st = "s2", top = S(N("ev.start"), N("lo.rep", 25), N("wo.plates", N("pl.all"))) })
        d.scripts[#d.scripts].top.n.c1 = N("ch.guild", "spam")
        local run = K.mk(d, 4)
        local r = { told = K.told, shown = K.shown, sounds = K.sounds, posts = #K.posts, plates = K.plates }
        -- practice: the posts are logged, never sent
        local p = K.mk(d, 4, { practice = true })
        local logged = 0
        for _, l in ipairs(K.logs) do if l == "guild: spam" then logged = logged + 1 end end
        r.practice = { #K.posts, logged }
        -- the end gives the nameplates back
        local run3 = K.mk(d, 4)
        run3:End()
        r.back = K.plates
        return r""")
    assert out["told"][:4] == [{"k": "P1", "text": "You're up vs P4"}, {"k": "P4", "text": "You're up vs P1"},
                               {"k": "P2", "text": "You're up vs P3"}, {"k": "P3", "text": "You're up vs P2"}], out["told"]
    assert len(out["told"]) == 4, out["told"]
    assert out["shown"][0] == {"to": "P1,P2,P3,P4", "text": "Match: P1"}, out["shown"]
    assert out["sounds"] == ["P1,P4:ready", "P2,P3:ready"] and out["posts"] == 20, out
    assert out["plates"] == ["P1,P2,P3,P4:true"], out["plates"]
    assert out["practice"] == [0, 20] and out["back"] == ["P1,P2,P3,P4:true", "P1,P2,P3,P4:false"], out
    w.assert_no_errors()


@case
def timers_say_seconds_since_and_show_on_the_board():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(
          S(N("ev.start"), N("tm.start", 100, "Seek"), N("tm.show", "Seek"), N("tm.wait", 30),
            N("ch.moment", J(N("tm.since", "Seek"), " ", N("tm.since", "stage"), " ", N("tm.left", "Seek"), " ", N("tm.since", "Never")))),
          S(N("ev.timer", "Seek"), N("ch.moment", J("done ", N("tm.since", "Seek")))))
        local run = K.mk(d, 1)
        K.adv(30)
        local shown = run.st.shown.Seek
        K.adv(80)
        return { K.moments(), shown, K.errors() }""")
    assert out == [["30 30 70 0", "done 100"], True, []], out
    w.assert_no_errors()


@case
def matches_won_by_the_pieces_ignore_duels_and_take_an_award():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        -- a fishing duel: the same Matches block, won by the pieces (first to 3 fish takes the match)
        local d = B:Blank("Fishing duels")
        d.stages = { { id = "s1", name = "Duels" } }
        d.scores = { sc1 = { n = "Fish", board = true } }
        d.blocks = { b1 = { kind = "bracket", stage = "s1", x = 0, y = 0, set = { seed = "order", win = "pieces", atonce = 8 } } }
        d.scripts = {
          { id = "a", st = "*", top = S(N("bk.start", "b1"), N("pt.set", "sc1", C("both"), 0)) },
          { id = "b", st = "*", top = S(N("ev.happen", "fish"), N("pt.add", 1, "sc1", C("player"))) },
          { id = "c", st = "*", top = S(N("pt.reach", "sc1", 3), N("bk.award", C("player"))) },
          { id = "d", st = "*", top = S(N("bk.end", "b1"), N("ch.moment", J(C("winner"), " beats ", C("loser"), " ", C("score")))) },
          { id = "e", st = "*", top = S(N("bk.done", "b1"), N("sg.end")) } }
        local probs = #B:Problems(d)
        local run = K.mk(d, 4)
        local bk = run:MainBracket()
        local P = K.P
        -- a duel counts for nothing here
        run:Duel(P(1), P(4), true); run:Duel(P(1), P(4), true)
        local afterDuels = { bk.m[1].wa, bk.m[1].st }
        for i = 1, 3 do run:Happen(P(4), "fish", { name = "Trout" }) end
        for i = 1, 3 do run:Happen(P(2), "fish", { name = "Trout" }) end
        -- the final: P4 vs P2, fish start again from 0
        local fin = { K.score("sc1", 4), K.score("sc1", 2) }
        for i = 1, 2 do run:Happen(P(4), "fish", { name = "Trout" }) end
        for i = 1, 3 do run:Happen(P(2), "fish", { name = "Trout" }) end
        local beforeBronze = { bk.done, run.st.phase }
        -- the bronze match: P1 vs P3
        for i = 1, 3 do run:Happen(P(1), "fish", { name = "Trout" }) end
        local m = bk.m[1]
        return { probs = probs, afterDuels = afterDuels, m1 = { m.st, K.short(m.win), m.wo or false, m.wa, m.wb }, fin = fin,
          champ = K.short(bk.champ), third = K.short(bk.third), beforeBronze = beforeBronze, moments = K.moments(),
          phase = run.st.phase, err = K.errors() }""")
    assert out["probs"] == 0 and out["afterDuels"] == [0, "play"], out
    assert out["m1"] == ["done", "P4", False, 0, 1], out["m1"]
    assert out["fin"] == [0, 0] and out["beforeBronze"] == [False, "live"], out
    assert out["champ"] == "P2" and out["third"] == "P1", out
    assert out["moments"] == ["P4 beats P1 1-0", "P2 beats P3 1-0", "P2 beats P4 1-0", "P1 beats P3 1-0"], out["moments"]
    assert out["phase"] == "done" and out["err"] == [], out
    w.assert_no_errors()


# Part 1's starter as the testers' libraries hold it (its old pieces as plain tables)
PART1_STARTER = r"""
local B = ns.EventBlocks
local SEASON = B.SEASON
local function P(k, ...) return { k = k, a = { ... } } end
OLDCUP = B:Example("duel")
OLDCUP.blocks.b2.set.win = nil
local BRK = "b2"
OLDCUP.scripts = {
  { id = "c1", st = "s1", x = 370, y = 20, top = S(N("su.join", "b1"),
      P("ch.wh", C("player"), J("You're in the Friday duel cup. Seeds are set when sign-up closes."))) },
  { id = "c2", st = "s1", x = 370, y = 150, top = S(N("su.close", "b1"),
      IfElse(N("lo.lt", N("su.count", "b1"), 4), N("sg.cancel", "Not enough duelists"), N("sg.go", "s2"))) },
  { id = "c3", st = "*", x = 20, y = 22, top = S(N("bk.start", BRK),
      P("ch.wh", C("both"), J("You're up vs ", C("opponent"), ". Duel at the Ring of Trials."))) },
  { id = "c4", st = "*", x = 20, y = 150, top = S(N("bk.end", BRK), N("pt.add", 5, SEASON, C("winner")),
      P("ch.say", J(C("winner"), " beats ", C("loser"), " ", C("score")), "GUILD"),
      If(N("pl.below", C("winner"), 4, C("loser")), P("ch.rw", J("Upset! ", C("winner"), " knocks out ", C("loser"))),
        N("ch.moment", J("Upset: ", C("winner"), " knocked out ", C("loser"))), P("pt.vset", "Biggest upset", C("winner")))) },
  { id = "c5", st = "s2", x = 370, y = 190, top = S(N("bk.final", BRK), N("sg.go", "s3")) },
  { id = "c6", st = "s3", x = 20, y = 22, top = S(N("ev.start"),
      P("ch.rw", J("Final: ", N("bk.fin1", BRK), " vs ", N("bk.fin2", BRK))), N("tm.count", 10, N("pl.all"))) },
  { id = "c7", st = "*", x = 520, y = 22, top = S(N("bk.done", BRK), N("sg.go", "s4")) },
  { id = "c8", st = "s4", x = 20, y = 22, top = S(N("ev.start"),
      N("pt.badge", "champ", N("bk.champ", BRK)), N("pt.add", 50, SEASON, N("bk.champ", BRK)),
      N("pt.badge", "second", N("bk.second", BRK)), N("pt.add", 30, SEASON, N("bk.second", BRK)),
      N("pt.badge", "third", N("bk.third", BRK)), N("pt.add", 20, SEASON, N("bk.third", BRK)),
      If(N("lo.set", V("Biggest upset")), N("pt.badge", "upset", V("Biggest upset")), N("pt.add", 10, SEASON, V("Biggest upset"))),
      P("ch.say", J("GG! ", N("bk.champ", BRK), " wins the Friday duel cup"), "GUILD"), N("sg.end")) },
  { id = "c9", st = "s1", x = 20, y = 210, top = S(N("ev.start"),
      P("ch.say", J("Sign-up for the Friday duel cup is open: 16 spots"), "GUILD")) },
  { id = "c10", st = "s2", x = 370, y = 22, top = S(N("ev.start"), Each(N("pl.all"), N("pt.add", 5, SEASON, C("each")))) },
}
-- the lower seed wins every duel, but P7 knocks out P2
function PLAYCUP(run)
  local bk = run:MainBracket()
  for guard = 1, 200 do
    if run.st.phase ~= "live" then break end
    local any = false
    for _, mid in ipairs(bk.rounds[bk.r] or {}) do
      local m = bk.m[mid]
      if m.st == "play" then
        any = true
        local a, b = tonumber(m.a:match("P(%d)")), tonumber(m.b:match("P(%d)"))
        local w, l = m.a, m.b
        if b < a then w, l = m.b, m.a end
        if (a == 7 and b == 2) or (a == 2 and b == 7) then w, l = K.P(7), K.P(2) end
        run:Duel(w, l, true)
      end
    end
    if not any then K.adv(5) end
  end
end
"""


@case
def part_1s_starter_still_plays_the_same_cup_after_migrating():
    # the event testers saved before part 2: its whispers are "tell" lines now, its guild lines posts, its raid
    # warnings banners, and it gives the same places, badges and season points
    w, c = one()
    c.eval(PART1_STARTER)
    out = c.eval_py("""
        local B = ns.EventBlocks
        local d = B.Copy(OLDCUP)
        local before = B:Problems(B.Copy(OLDCUP))
        d.blocks.b2.set.seed = "order"
        local run = K.mk(d, 8)
        PLAYCUP(run)
        local bk = run:MainBracket()
        return { probs = #before, phase = run.st.phase, places = { K.short(bk.champ), K.short(bk.second), K.short(bk.third) },
          posts = K.posts, shown = K.texts(K.shown), told = K.told, season = K.season(), awards = K.awards(), err = K.errors() }""")
    assert out["probs"] == 0 and out["phase"] == "done" and out["places"] == ["P1", "P3", "P4"], out
    posts = out["posts"]
    assert posts[0] == "Sign-up for the Friday duel cup is open: 16 spots" and posts[-1] == "GG! P1 wins the Friday duel cup", posts
    assert len(posts) == 10 and "P7 beats P2 2-0" in posts, posts
    assert out["shown"] == ["Upset! P7 knocks out P2", "Final: P1 vs P3"], out["shown"]
    assert {"k": "P1", "text": "You're up vs P8. Duel at the Ring of Trials."} in out["told"], out["told"]
    assert {"k": "P8", "text": "You're up vs P1. Duel at the Ring of Trials."} in out["told"], out["told"]
    assert out["season"] == {"P1": 70, "P2": 5, "P3": 45, "P4": 35, "P5": 5, "P6": 5, "P7": 20, "P8": 5}, out["season"]
    assert out["awards"] == ["P1:champ", "P3:second", "P4:third", "P7:upset"] and out["err"] == [], out
    w.assert_no_errors()


@case
def a_restored_run_keeps_tags_scores_lists_buttons_and_the_arrow():
    # (a /reload of the host or a takeover: the waiting scripts are gone, the rest goes on)
    w, c = one()
    out = c.eval_py("""
        local B, E = ns.EventBlocks, ns.EventEngine
        local def = B:Example("hide")
        local run = K.mk(def, 4)
        local seeker = run:Tagged("tg2")[1]
        local hiders = run:Tagged("tg1")
        K.adv(181)
        run:Touch(seeker, hiders[1], "click")
        run:Place(hiders[2], "pc1", true); run:Place(hiders[2], "pc1", false)
        local snap = run:Snapshot()
        local run2 = E:Restore(def, snap, { now = function() return K.clock end, out = K.out, nameOf = K.short })
        K.run = run2
        local r = { tags = { #run2:Tagged("tg1"), #run2:Tagged("tg3") }, finds = run2:GetScore("sc1", seeker),
          button = run2.st.buttons.Hint[seeker] or false, point = run2.st.point[hiders[2]], seek = run2.st.shown.Seek,
          stage = run2.st.stage }
        -- it goes on: the next finds count and the last one ends the seek
        run2:Touch(seeker, hiders[2], "click"); run2:Touch(seeker, hiders[3], "click")
        r.final = { run2.st.phase, run2.st.stage, run2:GetScore("sc1", seeker) }
        r.err = K.errors()
        return r""")
    assert out["tags"] == [2, 1] and out["finds"] == 1 and out["button"] is True, out
    assert out["point"] == "pc1" and out["seek"] is True and out["stage"] == "s3", out
    assert out["final"] == ["done", "s4", 3] and out["err"] == [], out
    w.assert_no_errors()


@case
def a_restore_survives_broken_parts_of_the_new_state():
    # (a state from another client: a tag that isn't a set, a score that isn't a number, an ask that isn't one ...)
    w, c = one()
    out = c.eval_py("""
        local B, E = ns.EventBlocks, ns.EventEngine
        local def = B:Example("hide")
        K.mk(B:Blank("t"), 1)   -- (the recorders)
        K.logs = {}
        local P1, P2 = K.P(1), K.P(2)
        local st = { id = "x", phase = "live", seq = 3, entrants = { P1, P2 }, blocks = {}, stage = "s3", timers = {},
          tags = { tg1 = "junk", tg2 = { [P1] = true } }, scores = { sc1 = { [P1] = "x", [P2] = 2 }, sc2 = 5 },
          lists = { ls1 = 3 }, qa = { ak1 = "x", ak2 = { open = true, who = 4 } }, buttons = { Hint = 5, Go = { [P1] = true } },
          point = { [P1] = 7, [P2] = "pc1" }, shown = { [1] = true }, pos = { [P1] = "here" }, flags = { [P2] = 1 },
          inplace = { pc1 = "x" }, plates = {}, tstart = {}, lead = {} }
        local run = E:Restore(def, st, { now = function() return 5000 end, out = K.out })
        K.run = run
        local errs = {}
        for _, f in ipairs({
          function() run:Tick() end,
          function() run:Touch(P1, P2, "click") end,
          function() run:Press(P1, "Hint"); run:Press(P1, "Go") end,
          function() run:Place(P2, "pc1", false) end,
          function() run:Pos(P1, { map = 1951, x = 0.5, y = 0.5 }) end,
          function() run:AskAnswer("ak2", P1, P2) end,
          function() run:Leave(P2) end,
          function() run:Snapshot(); run:Result() end,
          function() run:End() end,
        }) do
          local ok, e = pcall(f)
          if not ok then errs[#errs + 1] = tostring(e) end
        end
        return { errs = errs, finds = run:GetScore("sc1", P1), phase = run.st.phase, logErr = K.errors() }""")
    assert out["errs"] == [] and out["logErr"] == [] and out["phase"] == "done", out
    w.assert_no_errors()


@case
def every_example_saves_to_the_library_and_comes_back_whole():
    # (Events.lua's CleanDef keeps every definition and piece the examples use: what another member receives)
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local function sig(x)
          if type(x) ~= "table" then return tostring(x) end
          local keys = {}
          for k in pairs(x) do keys[#keys + 1] = k end
          table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
          local o = {}
          for _, k in ipairs(keys) do
            -- (an ask with no choices may come back with an empty list of them)
            if not (k == "choices" and type(x[k]) == "table" and next(x[k]) == nil) then o[#o + 1] = tostring(k) .. "=" .. sig(x[k]) end
          end
          return "{" .. table.concat(o, ",") .. "}"
        end
        local r = {}
        for _, e in ipairs(B:Examples()) do
          local d = ns.Events:NewDef(false)
          for k, v in pairs(e.def) do d[k] = B.Copy(v) end
          local ok = ns.Events:SaveDef(d)
          local back = ns.Events:GetDef(d.id)
          local diffs = {}
          for _, kind in ipairs({ "tags", "scores", "places", "lists", "asks", "vars", "badges", "blocks", "stages", "scripts" }) do
            if sig(e.def[kind] or {}) ~= sig(back and back[kind] or {}) then diffs[#diffs + 1] = kind end
          end
          r[#r + 1] = { e.key, ok and true or false, diffs, back and #B:Problems(back) or -1 }
        end
        return r""")
    for key, ok, diffs, probs in out:
        assert ok is True and diffs == [] and probs == 0, (key, ok, diffs, probs)
    w.assert_no_errors()


@case
def every_example_runs_as_a_practice_run_without_errors():
    # the builder's practice run (EventLive's own adapter: dummies, nothing sent) takes every example
    w, c = one()
    n0 = len(w.chat_log)
    out = c.eval_py("""
        local L, B = ns.EventLive, ns.EventBlocks
        local r = {}
        for _, e in ipairs(B:Examples()) do
          local run = L:StartPractice(e.def, 6)
          local ok, err = pcall(function()
            for i = 1, 12 do
              if run.st.phase ~= "live" then break end
              if run.st.blocks.b1 and run.st.blocks.b1.open then run:CloseSignup("b1"); run:Pump() end
              local bk = run:MainBracket()
              for _, mid in ipairs(bk and bk.rounds[bk.r] or {}) do
                local m = bk.m[mid]
                if m.st == "play" then L:PracticeDuel(m.a, m.b) end
              end
              L:PracticeSkip()
            end
          end)
          local errs = {}
          for _, l in ipairs(run.log) do if l.kind == "error" then errs[#errs + 1] = l.text end end
          r[#r + 1] = { e.key, ok and true or tostring(err), errs, run.st.stage }
          L:StopPractice()
        end
        return r""")
    for key, ok, errs, stage in out:
        assert ok is True and errs == [], (key, ok, errs)
    assert len(w.chat_log) == n0, w.chat_log[n0:]
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# The eight examples, end to end
# ------------------------------------------------------------------------------------------------------------------

@case
def example_friday_duel_cup_end_to_end():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local d = B:Example("duel")
        d.blocks.b2.set.seed = "order"
        local run = K.mk(d, 8)
        local bk = run:MainBracket()
        local P = K.P
        local r = { stage = run.st.stage }
        -- the lower seed wins every duel, but P7 knocks out P2 (5 seeds below: an upset)
        local guard = 0
        while run.st.phase == "live" and guard < 200 do
          guard = guard + 1
          local any = false
          for _, mid in ipairs(bk.rounds[bk.r] or {}) do
            local m = bk.m[mid]
            if m.st == "play" then
              any = true
              local a, b = tonumber(m.a:match("P(%d)")), tonumber(m.b:match("P(%d)"))
              local w, l = m.a, m.b
              if b < a then w, l = m.b, m.a end
              if (a == 7 and b == 2) or (a == 2 and b == 7) then w, l = P(7), P(2) end
              run:Duel(w, l, true)
            end
          end
          -- P3 drops off in the semi-finals for a moment (the host is told), P8 (out already) too (nobody is)
          if bk.r == 2 and not r.off then
            r.off = true
            run:SetOnline(P(3), false); run:SetOnline(P(3), true)
            run:SetOnline(P(8), false)
          end
          if not any then K.adv(5) end
        end
        r.phase, r.final = run.st.phase, run.st.stage
        r.places = { K.short(bk.champ), K.short(bk.second), K.short(bk.third) }
        r.moments = K.moments()
        r.shown = K.texts(K.shown)
        r.shownTo = K.shown[1] and K.shown[1].to
        r.posts = K.posts
        r.told = K.told
        r.awards = K.awards()
        r.season = K.season()
        r.upset = K.short(run.st.vars["Biggest upset"])
        r.cd = run.st.cd and run.st.cd.n
        r.err = K.errors()
        return r""")
    assert out["stage"] == "s2" and out["phase"] == "done" and out["final"] == "s4", out
    assert out["places"] == ["P1", "P3", "P4"], out["places"]
    assert "P1 beats P8 2-0" in out["moments"] and "P7 beats P2 2-0" in out["moments"], out["moments"]
    # (the final and the bronze match are best of 5)
    assert "P1 beats P3 3-0" in out["moments"] and "P4 beats P7 3-0" in out["moments"], out["moments"]
    assert len(out["moments"]) == 8, out["moments"]
    assert out["shown"] == ["Upset! P7 knocks out P2", "Final: P1 vs P3"], out["shown"]
    assert out["shownTo"] == "P1,P2,P3,P4,P5,P6,P7,P8", out
    assert out["posts"] == ["P1 wins the Friday duel cup!"], out["posts"]
    assert out["told"] == [{"k": "Host", "text": "P3 went offline"}], out["told"]
    assert out["awards"] == ["P1:champ", "P3:second", "P4:third", "P7:upset"], out["awards"]
    # 5 for playing, 5 a match won, 50 / 30 / 20 for the places, 10 for the giant slayer
    assert out["season"] == {"P1": 70, "P2": 5, "P3": 45, "P4": 35, "P5": 5, "P6": 5, "P7": 20, "P8": 5}, out["season"]
    assert out["upset"] == "P7" and out["cd"] == 10 and out["err"] == [], out
    w.assert_no_errors()


@case
def example_hide_and_seek_end_to_end():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local run = K.mk(B:Example("hide"), 5)
        local r = { stage = run.st.stage }
        local seeker = run:Tagged("tg2")[1]
        local hiders = run:Tagged("tg1")
        r.teams = { #run:Tagged("tg2"), #hiders, run:HasTag("tg1", seeker) }
        r.hideShown = K.texts(K.shown)
        r.pointed = run.st.point[hiders[1]]
        -- the hiders go into the play area (the arrow goes), one wanders off and is told and pointed back
        for _, h in ipairs(hiders) do run:Place(h, "pc1", true) end
        r.arrowGone = run.st.point[hiders[1]] or false
        run:Place(hiders[1], "pc1", false)
        r.back = { K.told_to(K.short(hiders[1]))[1], run.st.point[hiders[1]] }
        run:Place(hiders[1], "pc1", true)
        K.adv(181)
        r.seek = { run.st.stage, run.st.buttons.Hint[seeker] or false, K.plates[1] == K.short(seeker) .. ":true", run.st.shown.Seek }
        -- the Hint: the nearest hider's subzone, then a minute without the button
        run:Pos(seeker, { map = 1951, x = 0.40, y = 0.40, sz = "Halaa" })
        for i, h in ipairs(hiders) do run:Pos(h, { map = 1951, x = 0.40 + i * 0.02, y = 0.40, sz = "Spot " .. i }) end
        r.hint = { run:Press(seeker, "Hint"), run:Press(seeker, "Hint") }
        K.adv(61)
        r.hintBack = run.st.buttons.Hint[seeker] or false
        -- targeting a hider without clicking: told it doesn't count
        run:Radar(seeker, hiders[2])
        -- finds: a click on each, a minute apart (a hider's touch of another counts for nothing)
        run:Touch(hiders[1], hiders[2], "click")
        for i, h in ipairs(hiders) do
          K.adv(60)
          run:Touch(seeker, h, "click")
        end
        r.final = { run.st.phase, run.st.stage, K.tags("tg1"), #run:Tagged("tg3") }
        r.finds = K.score("sc1", tonumber(seeker:match("P(%d)")))
        r.hidden = K.scores("sc2")
        r.seekerTold = K.told_to(K.short(seeker))
        r.moments = K.moments()
        r.awards = K.awards()
        r.posts = K.posts
        r.plates = K.plates
        r.seeker, r.last = K.short(seeker), K.short(hiders[#hiders])
        r.season = K.season()
        r.err = K.errors()
        return r""")
    assert out["stage"] == "s2" and out["teams"] == [1, 4, False], out
    assert out["hideShown"] == ["Hide in the play area! The seekers come in 3 minutes.",
                                "You seek. Wait for the timer, then click the hiders you find."], out["hideShown"]
    assert out["pointed"] == "pc1" and out["arrowGone"] is False and out["back"] == ["Go back to the play area", "pc1"], out
    assert out["seek"] == ["s3", True, True, True], out["seek"]
    assert out["hint"] == [True, False] and out["hintBack"] is True, out
    seeker, last = out["seeker"], out["last"]
    assert out["seekerTold"] == ["Nearest hider: Spot 1", "Click them to find them. Macros don't count"], out["seekerTold"]
    assert out["final"] == ["done", "s4", "", 4] and out["finds"] == 4, out
    # found a minute apart from 61 + 1 s into the seek: 62+60, ... (the last one hid the longest)
    hidden = dict(x.split("=") for x in out["hidden"].split(" "))
    assert len(hidden) == 4 and max(hidden, key=lambda k: int(hidden[k])) == last, out["hidden"]
    assert out["moments"][0] == "%s found %s" % (seeker, out["moments"][0].split(" found ")[1]) and len(out["moments"]) == 4, out
    assert out["awards"] == sorted(["%s:seeker" % seeker, "%s:hider" % last]), out["awards"]
    assert out["posts"] == ["%s stayed hidden the longest in hide and seek!" % last], out["posts"]
    assert out["plates"] == ["%s:true" % seeker, "%s:false" % seeker], out["plates"]
    assert out["season"][seeker] == 25 and out["season"][last] == 25, out["season"]
    assert out["err"] == [], out
    w.assert_no_errors()


@case
def example_infection_end_to_end():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local run = K.mk(B:Example("infect"), 4)
        local zero = run:Tagged("tg2")[1]
        local r = { start = { #run:Tagged("tg2"), #run:Tagged("tg1") } }
        K.adv(121)
        r.stage = run.st.stage
        -- patient zero infects one; the infected infect the rest
        local hiders = run:Tagged("tg1")
        K.adv(30); run:Touch(zero, hiders[1], "click")
        K.adv(30); run:Touch(hiders[1], hiders[2], "click")
        r.mid = { K.tags("tg1"), #run:Tagged("tg2") }
        K.adv(30); run:Touch(zero, hiders[3], "click")
        r.final = { run.st.phase, run.st.stage }
        r.infections = K.scores("sc1")
        r.survived = K.scores("sc2")
        r.shown = K.texts(K.shown)
        r.zero, r.last = K.short(zero), K.short(hiders[3])
        r.awards = K.awards()
        r.posts = K.posts
        r.err = K.errors()
        return r""")
    assert out["start"] == [1, 3] and out["stage"] == "s3", out
    assert out["mid"][1] == 3 and len(out["mid"][0].split(",")) == 1, out["mid"]
    assert out["final"] == ["done", "s4"], out
    zero, last = out["zero"], out["last"]
    assert out["infections"].startswith(zero + "=2"), out["infections"]
    assert out["survived"].startswith(last + "=91"), out["survived"]
    assert out["shown"][-3:] == ["You're infected! Now catch the others.", "Last one standing: " + last,
                                 "You're infected! Now catch the others."], out["shown"]
    assert out["awards"] == sorted([zero + ":zero", last + ":last"]), out["awards"]
    assert out["posts"] == [last + " held out the longest against the infection!"] and out["err"] == [], out
    w.assert_no_errors()


@case
def example_mount_race_end_to_end():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local run = K.mk(B:Example("race"), 3, { signups = { K.P(1), K.P(2) } })
        local P = K.P
        local r = { stage = run.st.stage, point = run.st.point[P(1)] }
        -- a late racer joins; the host closes the sign-up and the race begins
        run:Join(P(3))
        r.lateTold = K.told_to("P3")[1]
        run:CloseSignup("b1"); run:Pump()
        r.race = { run.st.stage, K.tags("tg1"), run.st.cd and run.st.cd.n }
        K.adv(11)
        r.go = { run.st.point[P(1)], K.texts(K.shown)[1] }
        -- P1 rides the whole route; P2 too, slower (and one wrong place on the way: it counts for nothing)
        local route = run.def.lists.ls1.items
        for i, pid in ipairs(route) do
          K.adv(30); run:Place(P(1), pid, true); run:Place(P(1), pid, false)
        end
        run:Place(P(2), "pc5", true); run:Place(P(2), "pc5", false)
        r.wrong = run:ListPos("ls1", P(2))
        -- P3 gets off the mount halfway: out
        run:Place(P(3), route[1], true)
        run:Happen(P(3), "dismount")
        for i, pid in ipairs(route) do
          K.adv(5); run:Place(P(2), pid, true); run:Place(P(2), pid, false)
        end
        r.final = { run.st.phase, run.st.stage }
        r.times = K.scores("sc1")
        r.out = { K.tags("tg2"), run.st.point[P(3)] or false, K.told_to("P3")[#K.told_to("P3")] }
        r.p1told = K.told_to("P1")
        r.moments = K.moments()
        r.awards = K.awards()
        r.posts = K.posts
        r.lists = { run:ListPos("ls1", P(1)), run:ListPos("ls1", P(2)), run:ListPos("ls1", P(3)) }
        r.err = K.errors()
        return r""")
    assert out["stage"] == "s1" and out["point"] == "pc1", out
    assert out["lateTold"] == "Meet at Garadar on a ground mount. The race starts when the host closes the sign-up.", out
    assert out["race"] == ["s2", "P1,P2,P3", 10], out["race"]
    assert out["go"] == ["pc2", "Go! Follow the arrow round Nagrand."], out["go"]
    assert out["wrong"] == 1, out
    assert out["final"] == ["done", "s3"], out
    # P1: 8 places, 30 s apart, from a second after the timer started with "Go": 241; P2 finishes 40 s later
    assert out["times"] == "P1=241 P2=281", out["times"]
    assert out["out"] == ["P3", False, "You got off your mount: you're out of the race"], out["out"]
    assert out["p1told"][-1] == "You finish in place 1", out["p1told"]
    assert out["moments"] == ["P1 crosses the finish line", "P3 is out: off the mount", "P2 crosses the finish line"], out
    assert out["awards"] == ["P1:gold", "P2:silver"] and out["posts"] == ["P1 wins the mount race!"], out
    assert out["lists"] == [9, 9, 2] and out["err"] == [], out
    w.assert_no_errors()


@case
def example_fishing_derby_end_to_end():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local run = K.mk(B:Example("fish"), 4)
        local P = K.P
        local r = { stage = run.st.stage, shown = run.st.shown.Derby }
        local catch = function(i, name) run:Happen(P(i), "fish", { item = 1, name = name or "Barbed Gill Trout" }) end
        catch(1); K.adv(60); catch(2); catch(2); K.adv(60); catch(1); catch(3, "Mr. Pinchy"); catch(2); catch(1); catch(1)
        r.leads = {}
        for _, t in ipairs(K.told) do if t.k == "P4" then r.leads[#r.leads + 1] = t.text end end
        K.adv(1800)
        r.final = { run.st.phase, run.st.stage }
        r.fish = K.scores("sc1")
        r.moments = K.moments()
        r.awards = K.awards()
        r.season = K.season()
        r.posts = K.posts
        r.err = K.errors()
        return r""")
    assert out["stage"] == "s2" and out["shown"] is True, out
    assert out["leads"] == ["P1 leads with 1 fish", "P2 leads with 2 fish", "P1 leads with 4 fish"], out["leads"]
    assert out["final"] == ["done", "s3"] and out["fish"] == "P1=4 P2=3 P3=1", out
    assert out["moments"] == ["P3 fished up Mr. Pinchy"], out["moments"]
    assert out["awards"] == ["P1:gold", "P2:silver", "P3:bronze"], out["awards"]
    assert out["season"] == {"P1": 35, "P2": 25, "P3": 15}, out["season"]
    assert out["posts"] == ["P1 wins the fishing derby with 4 fish!"] and out["err"] == [], out
    w.assert_no_errors()


@case
def example_transmog_contest_end_to_end():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local run = K.mk(B:Example("tmog"), 4)
        local P = K.P
        local r = { stage = run.st.stage, asked = K.asked[1] }
        -- the host picks two judges (an entrant on the list can be judged too)
        r.pick = { run:AskAnswer("ak1", P(1), { P(2) }), run:AskAnswer("ak1", HOST, { P(1), P(2) }) }
        r.judges = { K.tags("tg1"), run.st.stage, K.texts(K.shown)[1] }
        -- the catwalk: each model in turn, the judges score 1 to 10 (a judge's own outfit doesn't count)
        local marks = { { 8, 6 }, { 9, 10 }, { 7, 7 }, { 5, 4 } }
        r.questions = {}
        for i = 1, 4 do
          r.questions[i] = run.st.qa.ak2.q
          if i == 1 then r.notJudge = run:AskAnswer("ak2", P(3), 10) end
          run:AskAnswer("ak2", P(1), marks[i][1]); run:AskAnswer("ak2", P(2), marks[i][2])
        end
        r.votes1 = K.scores("sc1")
        -- the vote: up to three picks each, never oneself
        r.self = run:AskAnswer("ak3", P(3), { P(3) })
        run:AskAnswer("ak3", P(1), { P(3), P(2) }); run:AskAnswer("ak3", P(2), { P(3) })
        run:AskAnswer("ak3", P(3), { P(1), P(2), P(4) }); run:AskAnswer("ak3", P(4), { P(3), P(3) })
        r.final = { run.st.phase, run.st.stage }
        r.votes = K.scores("sc1")
        r.shown = K.texts(K.shown)
        r.awards = K.awards()
        r.posts = K.posts
        r.err = K.errors()
        return r""")
    assert out["stage"] == "s2" and out["asked"] == "ak1:Who judges? Pick up to 3", out
    assert out["pick"] == [False, True] and out["judges"] == ["P1,P2", "s3", "The judges: P1, P2"], out
    assert out["questions"] == ["Score P1's outfit, 1 to 10", "Score P2's outfit, 1 to 10", "Score P3's outfit, 1 to 10",
                                "Score P4's outfit, 1 to 10"], out["questions"]
    assert out["notJudge"] is False, out
    assert out["votes1"] == "P3=14 P2=9 P4=9 P1=6", out["votes1"]
    assert out["self"] is False and out["final"] == ["done", "s5"], out
    assert out["votes"] == "P3=19 P2=9 P4=9 P1=6", out["votes"]
    assert out["shown"][-1] == "P3 wore it best", out["shown"]
    # P2 and P4 tie for second: both get silver; nobody is third
    assert out["awards"] == ["P2:silver", "P3:gold", "P4:silver"], out["awards"]
    assert out["posts"] == ["P3 wins the transmog contest!"] and out["err"] == [], out
    w.assert_no_errors()


@case
def example_trivia_night_end_to_end():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local run = K.mk(B:Example("quiz"), 3)
        local P = K.P
        local items = run.def.lists.ls1.items
        local r = { stage = run.st.stage, questions = {} }
        -- P1 knows them all (any capitals, spaces), P2 every other one, P3 never answers (each question times out)
        for i = 1, #items do
          K.untilit(function() return run.st.qa.ak1 and run.st.qa.ak1.open and run.st.qa.ak1.q == items[i].q end, 20)
          r.questions[#r.questions + 1] = run.st.qa.ak1.q
          local a = items[i].a[#items[i].a]
          run:AskAnswer("ak1", P(1), "  " .. a:upper():gsub("(%w)(%w)", "%1 %2", 1) .. " ")
          if i == 1 then r.secret = { run:Snapshot().qa.ak1.ans[P(1)], run.st.qa.ak1.ans[P(1)] ~= true } end
          run:AskAnswer("ak1", P(2), i % 2 == 1 and items[i].a[1] or "no idea")
          K.adv(31)
        end
        K.untilit(function() return run.st.phase ~= "live" end, 60)
        r.final = { run.st.phase, run.st.stage }
        r.right = K.scores("sc1")
        r.p1right = #K.told_to("P1")
        r.awards = K.awards()
        r.season = K.season()
        r.posts = K.posts
        r.err = K.errors()
        return r""")
    assert out["stage"] == "s2" and len(out["questions"]) == 10, out
    assert out["questions"][3] == "Which boss drops the Ashes of Al'ar?", out["questions"]
    assert out["secret"] == [True, True], out
    assert out["final"] == ["done", "s3"] and out["right"] == "P1=10 P2=5", out
    assert out["p1right"] == 10 and out["awards"] == ["P1:gold", "P2:silver"], out
    assert out["season"] == {"P1": 35, "P2": 25}, out["season"]
    assert out["posts"] == ["P1 wins trivia night!"] and out["err"] == [], out
    w.assert_no_errors()


@case
def example_red_light_green_light_end_to_end():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local run = K.mk(B:Example("redlight"), 3)
        local P = K.P
        local r = { stage = run.st.stage, told = K.told_to("P2")[1] }
        run:CloseSignup("b1"); run:Pump()
        r.go = { run.st.stage, run.st.vars.Light, K.tags("tg1"), run.st.point[P(1)] }
        -- green: everyone moves; P2 stops in time, P1 keeps going
        run:Happen(P(1), "move"); run:Happen(P(2), "move"); run:Happen(P(3), "move")
        run:Happen(P(2), "stop"); run:Happen(P(3), "stop")
        r.turning = K.untilit(function() return run.st.vars.Light == "turning" end, 30)
        r.redShown = K.texts(K.shown)[#K.shown]
        r.sound = K.sounds[1]
        K.untilit(function() return run.st.vars.Light == "red" end, 5)
        K.adv(1)
        r.p1 = { run:HasTag("tg2", P(1)), K.told_to("P1")[#K.told_to("P1")] }
        -- P3 starts moving on red: out too
        run:Happen(P(3), "move")
        r.p3 = { run:HasTag("tg2", P(3)), K.told_to("P3")[#K.told_to("P3")] }
        -- green again: P2 runs to the finish line
        K.untilit(function() return run.st.vars.Light == "green" end, 30)
        run:Happen(P(2), "move")
        K.adv(3)
        run:Place(P(2), "pc2", true)
        r.final = { run.st.phase, run.st.stage }
        r.made = K.tags("tg3")
        r.finish = K.run:GetScore("sc1", P(2)) ~= nil
        r.moments = K.moments()
        r.awards = K.awards()
        r.posts = K.posts
        r.err = K.errors()
        return r""")
    assert out["stage"] == "s1" and out["told"] == "Line up at the start line. The game starts when the host closes the sign-up.", out
    assert out["go"] == ["s2", "green", "P1,P2,P3", "pc2"], out["go"]
    assert out["turning"] and out["redShown"] == "Red light! Stop!" and out["sound"] == "P1,P2,P3:warning", out
    assert out["p1"] == [True, "You kept moving on red: you're out"], out["p1"]
    assert out["p3"] == [True, "You moved on red: you're out"], out["p3"]
    assert out["final"] == ["done", "s3"] and out["made"] == "P2" and out["finish"], out
    assert out["moments"] == ["P1 kept moving on red", "P3 moved on red", "P2 made it to the finish line"], out["moments"]
    assert out["awards"] == ["P2:gold"] and out["posts"] == ["P2 wins red light, green light!"] and out["err"] == [], out
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
