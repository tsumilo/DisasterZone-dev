"""Encounter objects and models by ID on the strategy boards (Core/StrategyObjects.lua, Data/ModelIndex.lua,
Data/EncounterObjects.lua), on the real addon.

Covers: the model index (NPC -> display, object -> model file and box, creature sizes, which displays exist); the save
check (obj: icons, their state st, dropped elsewhere); Lady Vashj's starter with her four Shield Generators where the
server spawns them; the 2D map (an object's icon, greyed when switched off, beams to Vashj while on); the State menu
(every selected generator at once) and the "Encounter objects" / "From a model ID" icon menus (NPC, object, display,
a pasted Wowhead link, an unknown ID); the 3D room (each generator its own model file at its size and height, a beam
from its top to Vashj's chest while on, the barrier on her while any is on, occluders cut at the floor); an object
strategy saved and received by another member.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_objects.py [-k name]
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import world, strategies  # noqa: E402
from _common import case, run_all, no_errors, menu_texts, strip_codes  # noqa: E402
import harness  # noqa: E402

harness.LOAD_ROOMS = True                      # (the mock leaves the board's rooms out unless asked)

VASHJ = "SerpentshrineCavern:Vashj"
W = "_G.DisasterZoneStrategyBoard"
CV = W + ".canvas"
GENERATORS = ["obj:185051", "obj:185052", "obj:185053", "obj:185054"]
BEAM = (0.45, 0.78, 1)

HELPERS = r"""
T = {}
function T.cv() return _G.DisasterZoneStrategyBoard.canvas end
function T.v() return T.cv().v3 end
function T.page() return ns.StrategyBoard:GetState().strat.p[ns.StrategyBoard:GetState().page] end
function T.elems() return T.page().e end
function T.find(key) for _, e in ipairs(T.elems()) do if e.i == key then return e end end end
function T.gens() local out = {} for _, e in ipairs(T.elems()) do if (e.i or ''):find('^obj:') then out[#out + 1] = e end end return out end
function T.vashj() for _, e in ipairs(T.elems()) do if e.i == 'boss:20748' then return e end end end
function T.menu(prefix)
  local found
  local function strip(s)
    return ((s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("^%s+", ""))
  end
  local function walk(d)
    for _, c in ipairs(d.children) do
      if found then return end
      if strip(c.text):sub(1, #prefix) == prefix and (c.callback or c.setSelected) then found = c; return end
      walk(c)
    end
  end
  walk(__MOCK.last_menu)
  if not found then error("no menu entry starting with " .. prefix) end
  return __MOCK.menu_select(found.text, found.parent)
end
-- the beams the room drew on its last pass (lines in the beam's colour)
function T.spyLines()
  local R = T.v().R
  if R._spied then return end
  R._spied = true
  local old = R.Line
  T.beams = {}
  R.Line = function(x1, y1, z1, x2, y2, z2, r, g, b, ...)
    if math.abs(r - 0.45) < 1e-6 and math.abs(g - 0.78) < 1e-6 and math.abs(b - 1) < 1e-6 then
      T.beams[#T.beams + 1] = { x1, y1, z1, x2, y2, z2 }
    end
    return old(x1, y1, z1, x2, y2, z2, r, g, b, ...)
  end
end
function T.redraw() T.beams = {} T.cv():Render() end
"""


def boot(boss=VASHJ):
    w, c = world()
    bob = c["Bob"]
    bob.eval(HELPERS)
    bob.eval("ns.StrategyBoard:NewStrategy(...)", boss)
    w.tick(0.2)
    return w, c, bob


def tick(w, secs):
    for _ in range(int(secs / 0.05 + 0.5)):
        w.tick(0.05)


def go3d(w, bob):
    assert bob.eval("return T.cv():Set3D(true, false)") is True
    tick(w, 0.3)
    bob.eval("T.spyLines()")


def beams3d(w, bob):
    """The beams of the room's last drawing (each pass draws them once; a frame can hold two passes)."""
    bob.eval("T.redraw()")
    tick(w, 0.1)
    return sorted({tuple(round(v, 4) for v in b) for b in bob.eval_py("return T.beams")})


# ------------------------------------------------------------------------------------------------------------------
@case
def the_model_index_finds_npcs_objects_and_sizes():
    w, c = world()
    bob = c["Bob"]
    res = bob.eval_py("""
        local SO = ns.StrategyObjects
        local d, pct = SO.Npc(21212)
        local o = SO.Object(185051)
        return { vashj = d, vashjPct = pct, none = SO.Npc(99999999) == nil, zero = SO.Npc(0) == nil,
                 obj = o and { o.display, o.size, o.fdid, o.box } or false, noObj = SO.Object(123456789) == nil,
                 shown = SO.IsDisplay(20748), missing = SO.IsDisplay(1679615), neg = SO.IsDisplay(-3),
                 scale = SO.DisplayScale(20748), plain = SO.DisplayScale(49) }
    """)
    assert res["vashj"] == 20748 and res["vashjPct"] == 100, res
    assert res["none"] and res["zero"] and res["noObj"], res
    disp, size, fdid, box = res["obj"]
    assert disp == 7265 and abs(size - 2.1) < 1e-9 and fdid == 191730, res["obj"]
    # GameObjectDisplayInfo 7265's GeoBox (model units)
    assert all(abs(a - b) < 0.006 for a, b in zip(box, (-0.805, -1.093, -1.354, 1.088, 1.093, 1.398))), box
    assert res["shown"] is True and res["missing"] is False and res["neg"] is False, res
    assert abs(res["scale"] - 3.5) < 1e-9 and res["plain"] == 1, res
    no_errors(w)


@case
def the_save_check_keeps_objects_and_their_state_only():
    w, c = world()
    bob = c["Bob"]
    res = bob.eval_py("""
        local function try(e)
            local d = { b = 'SerpentshrineCavern:Vashj', n = 'Objects',
                        p = { { id = 'p1', n = 'P1', m = 0, vx = 500, vy = 500, vz = 100, e = { e }, k = {} } } }
            local ok, r = ns.Strategy:SaveStrategy(d)
            if not ok then return 'rejected' end
            return ns.Strategy:GetStrategy(r).p[1].e[1]
        end
        return {
            off = try({ t = 'i', x = 10, y = 10, i = 'obj:185051', st = 2 }),
            first = try({ t = 'i', x = 10, y = 10, i = 'obj:185051', st = 1 }),
            bad = try({ t = 'i', x = 10, y = 10, i = 'obj:185051', st = 9 }),
            mark = try({ t = 'i', x = 10, y = 10, i = 'rt1', st = 2 }),
            long = try({ t = 'i', x = 10, y = 10, i = 'obj:1234567' }),
        }
    """)
    assert res["off"]["i"] == "obj:185051" and res["off"]["st"] == 2, res
    assert "st" not in res["first"] and "st" not in res["bad"] and "st" not in res["mark"], res
    assert res["long"] == "rejected", res
    no_errors(w)


@case
def vashj_starts_with_her_four_generators_where_the_server_spawns_them():
    w, c, bob = boot()
    gens = bob.eval_py("return T.gens()")
    assert sorted(g["i"] for g in gens) == GENERATORS, gens
    assert all(g.get("l") == "Generator" and "st" not in g and g["z"] == 32 for g in gens), gens
    # a square round her on the map: each corner about 31.8 yd from her (the spawns: 22.2 and 22.8 yd off her
    # on each axis), facing as spawned (orientation 5.99871 rad from north -> 74 degrees from east)
    tick(w, 0.1)
    go3d(w, bob)
    pts = bob.eval_py("local R3, v = ns.Render3D, T.v() local out = {} "
                      "for _, e in ipairs(T.elems()) do local x, y = R3.BoardToRoom(v.room, T.page(), e.x, e.y) "
                      "out[e.i] = { x, y } end return out")
    vx, vy = pts["boss:20748"]
    for key in GENERATORS:
        d = math.hypot(pts[key][0] - vx, pts[key][1] - vy)
        assert abs(d - 31.8) < 2.5, (key, d)
    assert bob.eval_py("return T.find('obj:185051').f") == 74
    no_errors(w)


@case
def generators_are_their_own_model_with_beams_and_vashjs_barrier():
    w, c, bob = boot()
    go3d(w, bob)
    tick(w, 0.5)
    acts = bob.eval_py("""
        local v, out = T.v(), {}
        for _, e in ipairs(T.gens()) do
            local a, g = v.actors[e], v:Geo(e)
            local px, py, pz = a:GetPosition()
            out[#out + 1] = { file = a.fileID, scale = a.scale, z = pz * a.scale, ground = g.z, top = g.top,
                              shown = a.shown, anim = a.anim, display = a.display or false }
        end
        return out
    """)
    assert len(acts) == 4, acts
    for a in acts:
        assert a["file"] == 191730 and abs(a["scale"] - 2.1) < 1e-9 and a["shown"] and a["anim"] == 0, a
        assert a["display"] is False, a
        # on the ring 1.41 yd under Vashj's floor, its origin 2.43 yd over it (spawn z 44.0 against her 42.99); its
        # top: the parts' top x 2.1
        assert abs(a["ground"] + 1.41) < 0.02, a
        assert abs(a["z"] - (a["ground"] + 2.43)) < 1e-6, a
        assert abs(a["top"] - (a["ground"] + 2.43 + 1.4 * 2.1)) < 1e-6, a
    # a beam from each generator's top to Vashj's chest (1.74 x 3.5 over her feet)
    b = beams3d(w, bob)
    assert len(b) == 4, b
    vz = bob.eval_py("local g = T.v():Geo(T.vashj()) return { g.x, g.y, g.z }")
    for x1, y1, z1, x2, y2, z2 in b:
        assert abs(x2 - vz[0]) < 1e-3 and abs(y2 - vz[1]) < 1e-3 and abs(z2 - (vz[2] + 1.74 * 3.5)) < 1e-3
    # the barrier on her chest, her size
    fx = bob.eval_py("local a = T.v().fxActors[T.vashj()].t local px, py, pz = a:GetPosition() "
                     "return { file = a.fileID, shown = a.shown, z = pz * a.scale, s = a.scale }")
    assert fx["file"] == 166541 and fx["shown"] and abs(fx["s"] - 3.5) < 1e-9, fx
    assert abs(fx["z"] - (vz[2] + 1.74 * 3.5)) < 1e-6, fx
    # occluders: two parts per generator, none under the floor; one for the barrier
    occ = bob.eval_py("""
        local v, out = T.v(), { gen = 0, under = 0, fx = 0 }
        local gens = {}
        for _, e in ipairs(T.gens()) do gens[e] = v:Geo(e) end
        for i = 1, v.nOcc do
            local o = v.occ[i]
            local g = gens[o.group]
            if g then
                out.gen = out.gen + 1
                if o.z < g.z then out.under = out.under + 1 end
            elseif o.id == v.fxActors[T.vashj()].t then out.fx = out.fx + 1 end
        end
        return out
    """)
    assert occ == {"gen": 8, "under": 0, "fx": 1}, occ
    # one generator off: three beams, the barrier stays; all off: none, and the barrier goes
    bob.eval("T.find('obj:185051').st = 2")
    assert len(beams3d(w, bob)) == 3
    assert bob.eval_py("return T.v().fxActors[T.vashj()].t.shown") is True
    bob.eval("for _, e in ipairs(T.gens()) do e.st = 2 end")
    assert len(beams3d(w, bob)) == 0
    assert bob.eval_py("return T.v().fxActors[T.vashj()] == nil") is True
    # Vashj taken off the page: no beams anywhere, no errors
    bob.eval("for _, e in ipairs(T.gens()) do e.st = nil end "
             "for i, e in ipairs(T.elems()) do if e.i == 'boss:20748' then table.remove(T.elems(), i) break end end")
    assert len(beams3d(w, bob)) == 0
    no_errors(w)


@case
def the_2d_map_greys_a_switched_off_generator_and_draws_its_beam():
    w, c, bob = boot()
    tick(w, 0.2)
    get = ("local cv, out = T.cv(), { beams = 0, desat = 0, icons = 0 } "
           "for _, o in ipairs(cv.pools.beam or {}) do if o.line:IsShown() then out.beams = out.beams + 1 end end "
           "for _, o in ipairs(cv.pools.icon or {}) do if o.tex:IsShown() then out.icons = out.icons + 1 "
           "if o.tex:IsDesaturated() then out.desat = out.desat + 1 end end end return out")
    s = bob.eval_py(get)
    assert s == {"beams": 4, "desat": 0, "icons": 5}, s
    tex = bob.eval_py("for _, o in ipairs(T.cv().pools.icon) do if o.tex:IsShown() and "
                      "(o.tex:GetTexture() or ''):find('ChillingArmor') then return o.tex:GetTexture() end end")
    assert tex == "Interface\\Icons\\Spell_Frost_ChillingArmor", tex
    bob.eval("T.find('obj:185052').st = 2 T.cv():Render()")
    assert bob.eval_py(get) == {"beams": 3, "desat": 1, "icons": 5}
    no_errors(w)


@case
def the_state_menu_switches_every_selected_generator():
    w, c, bob = boot()
    bob.eval("local cv = T.cv() local g = T.find('obj:185051') cv:Select(g) cv:ElementMenu(g)")
    texts = [strip_codes(t[2]).strip() for t in menu_texts(bob.last_menu()) if t[2]]
    assert "State  Active" in texts and "Inactive" in texts, texts
    bob.eval("T.menu('Inactive')")
    assert bob.eval_py("return T.find('obj:185051').st") == 2
    assert bob.eval_py("return T.find('obj:185052').st") is None
    # all four selected (and Vashj): one switch for the generators, Vashj untouched
    bob.eval("local cv = T.cv() cv:SelectAll() cv:ElementMenu(T.find('obj:185052'))")
    bob.eval("T.menu('Inactive')")
    assert bob.eval_py("local n = 0 for _, e in ipairs(T.gens()) do if e.st == 2 then n = n + 1 end end return n") == 4
    assert bob.eval_py("return T.vashj().st") is None
    bob.eval("local cv = T.cv() cv:ElementMenu(T.find('obj:185052'))")
    bob.eval("T.menu('Active')")
    assert bob.eval_py("local n = 0 for _, e in ipairs(T.gens()) do if e.st == nil then n = n + 1 end end return n") == 4
    no_errors(w)


@case
def icons_by_model_id_and_the_encounter_objects_menu():
    w, c, bob = boot()
    prompt = "ns.StrategyBoard:GetPrompt()"

    def add(entry, text):
        bob.eval("T.cv():BackgroundMenu(300, 200)")
        bob.eval("T.menu(...)", entry)
        assert bob.eval("return %s:IsShown()" % prompt) is True
        bob.type_text(bob.eval("return %s.editBox" % prompt), text, enter=True)
        w.tick(0.3)
        return bob.eval_py("return T.elems()[#T.elems()]")

    n0 = bob.eval_py("return #T.elems()")
    bob.eval("T.cv():BackgroundMenu(300, 200)")
    texts = [strip_codes(t[2]).strip() for t in menu_texts(bob.last_menu()) if t[2]]
    assert "Encounter objects" in texts and "From a model ID" in texts, texts
    bob.eval("T.menu('Shield Generator')")
    e = bob.eval_py("return T.elems()[#T.elems()]")
    assert e["i"] == "obj:185051" and e["l"] == "Shield Generator" and e["z"] == 32, e
    e = add("NPC ID...", "https://www.wowhead.com/tbc/npc=21212/lady-vashj")
    assert e["i"] == "boss:20748" and e["l"] == "Lady Vashj" and e["z"] == 48 and "ms" not in e, e
    e = add("Object ID...", "185053")
    assert e["i"] == "obj:185053" and e["l"] == "Shield Generator", e
    e = add("Display ID...", "  21254 ")
    assert e["i"] == "boss:21254" and e["l"] == "Teron Gorefiend", e
    e = add("NPC ID...", "wowhead.com/tbc/object=185054")          # (a link names its own kind)
    assert e["i"] == "obj:185054", e
    n1 = bob.eval_py("return #T.elems()")
    chat0 = len(bob.chat_frame)
    add("Display ID...", "1679615")
    assert bob.eval_py("return #T.elems()") == n1
    assert any("no creature model 1679615" in str(x) for x in bob.chat_frame[chat0:]), bob.chat_frame[chat0:]
    assert n1 == n0 + 5
    # an NPC the server draws bigger or smaller than its model: that size comes along (e.ms, percent)
    pct = bob.eval_py("local SO = ns.StrategyObjects for id = 15000, 26000 do local d, p = SO.Npc(id) "
                      "if d and p and p ~= 100 and p >= 25 and p <= 400 then return { id, p } end end")
    e = add("NPC ID...", str(pct[0]))
    assert e.get("ms") == pct[1], (e, pct)
    no_errors(w)


@case
def an_object_strategy_reaches_the_guild_with_its_states():
    w, c, bob = boot()
    bob.eval("T.find('obj:185053').st = 2 T.cv():Changed()")
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(2)
    got = strategies(c["Sam"], VASHJ)
    assert got, "Sam has no Vashj strategy"
    e = {x["i"]: x for x in got[0]["p"][0]["e"]}
    assert set(GENERATORS) <= set(e), e
    assert e["obj:185053"]["st"] == 2 and "st" not in e["obj:185051"], e
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# The engine with definitions of its own (the data of every encounter is checked by the starters suite): a creature
# asset that channels into Vashj or lies dead, an object whose second state shows an effect on itself.
TEST_DEFS = r"""
local D = ns.Data.EncounterObjects
D.defs.testChanneler = { name = "Test Channeler", states = {
    { name = "Channelling", beam = { to = "boss:20748", at = "chest", color = { 0.6, 0.2, 0.9 } } },
    { name = "Dead", anim = 6, dim = true } } }
D.defs.testOrb = { name = "Test Orb", icon = "INV_Misc_Orb_05", states = {
    { name = "Dormant" }, { name = "Ready", fx = { fdid = 166541, at = "origin", size = { 1, 1 } } } } }
D.defs.testSpot = { name = "Test Spot", icon = "Spell_Fire_Fire", marker = true, states = {
    { name = "Warning", fx = { fdid = 166541, size = { 1, 1 } } } } }
D.npcs[21212] = "testChanneler"
D.npcs[17474] = "testSpot"
D.entries[187869] = "testOrb"
-- every line the room draws, by colour
local R = T.v() and T.v().R
T.lines = {}
function T.spyAll()
  local R = T.v().R
  if R._spyAll then return end
  R._spyAll = true
  local old = R.Line
  R.Line = function(x1, y1, z1, x2, y2, z2, r, g, b, ...)
    local k = string.format('%.2f,%.2f,%.2f', r, g, b)
    T.lines[k] = T.lines[k] or {}
    table.insert(T.lines[k], { x1, y1, z1, x2, y2, z2 })
    return old(x1, y1, z1, x2, y2, z2, r, g, b, ...)
  end
end
"""


@case
def a_creature_asset_channels_into_its_target_or_lies_dead():
    w, c, bob = boot()
    go3d(w, bob)
    bob.eval(TEST_DEFS)
    bob.eval("T.spyAll() table.insert(T.elems(), { t = 'i', x = 380, y = 220, i = 'npc:21212', z = 40 }) "
             "T.lines = {} T.cv():Render()")
    tick(w, 0.3)
    s = bob.eval_py("""
        local v = T.v() local e = T.find('npc:21212') local a, g = v.actors[e], v:Geo(e)
        local d, pct = ns.StrategyObjects.Npc(21212)
        return { display = a.display, scale = a.scale, want = 3.5 * pct / 100, anim = a.anim,
                 beams = #(T.lines['0.60,0.20,0.90'] or {}) }
    """)
    assert s["display"] == 20748 and abs(s["scale"] - s["want"]) < 1e-9 and s["anim"] == 0, s
    assert s["beams"] >= 1, s
    bob.eval("T.find('npc:21212').st = 2 T.lines = {} T.cv():Render()")
    tick(w, 0.2)
    s = bob.eval_py("local v = T.v() local a = v.actors[T.find('npc:21212')] "
                    "return { anim = a.anim, beams = #(T.lines['0.60,0.20,0.90'] or {}) }")
    assert s == {"anim": 6, "beams": 0}, s
    # on the 2D map: its portrait, greyed while dead
    bob.eval("T.cv():Set3D(false)")
    tick(w, 0.6)
    d = bob.eval_py("for _, o in ipairs(T.cv().pools.icon) do if o.tex:IsShown() and o.tex:IsDesaturated() then "
                    "return true end end return false")
    assert d is True
    no_errors(w)


@case
def an_object_state_can_show_an_effect_on_the_object_itself():
    w, c, bob = boot()
    go3d(w, bob)
    bob.eval(TEST_DEFS)
    bob.eval("table.insert(T.elems(), { t = 'i', x = 380, y = 220, i = 'obj:187869', z = 32 }) T.cv():Render()")
    tick(w, 0.3)
    assert bob.eval_py("local s = T.v().fxActors[T.find('obj:187869')] return s == nil") is True
    bob.eval("T.find('obj:187869').st = 2 T.cv():Render()")
    tick(w, 0.3)
    s = bob.eval_py("""
        local v = T.v() local e = T.find('obj:187869') local a, g = v.fxActors[e].s, v:Geo(e)
        local px, py, pz = a:GetPosition()
        local occ = false
        for i = 1, v.nOcc do if v.occ[i].id == a then occ = true end end
        return { file = a.fileID, shown = a.shown, z = pz * a.scale, ground = g.z, occ = occ,
                 model = v.actors[e].fileID }
    """)
    assert s["file"] == 166541 and s["shown"] and s["model"] == 203892 and s["occ"], s
    assert abs(s["z"] - s["ground"]) < 1e-6, s
    # a marker (a trigger the game never shows): no model, an icon on a post, its effect still on its spot
    bob.eval("table.insert(T.elems(), { t = 'i', x = 420, y = 240, i = 'npc:17474', z = 32 }) T.cv():Render()")
    tick(w, 0.3)
    s = bob.eval_py("""
        local v = T.v() local e = T.find('npc:17474') local g = v:Geo(e) local slot = v.fxActors[e]
        local a = slot and slot.s
        local px, py, pz = 0, 0, 0
        if a then px, py, pz = a:GetPosition() end
        return { actor = v.actors[e] ~= nil, marker = g.marker or false, post = g.post, fx = a and a.fileID,
                 z = a and pz * a.scale, ground = g.z }
    """)
    assert s["actor"] is False and s["marker"] is True and s["post"] and s["fx"] == 166541, s
    assert abs(s["z"] - s["ground"]) < 1e-6, s
    no_errors(w)


@case
def a_group_of_assets_goes_where_the_script_puts_it():
    w, c, bob = boot()
    bob.eval(TEST_DEFS)
    bob.eval("local sp = ns.Data.EncounterSpawns['SerpentshrineCavern:Vashj'] "
             "table.insert(sp.groups, { n = 'Test spots', e = { { i = 'npc:21212', mx = 720, my = 590, f = 90, st = 2 }, "
             "{ i = 'obj:187869', mx = 730, my = 600, f = 0 } } })")
    n0 = bob.eval_py("return #T.elems()")
    bob.eval("T.cv():BackgroundMenu(300, 200)")
    texts = [strip_codes(t[2]).strip() for t in menu_texts(bob.last_menu()) if t[2]]
    assert "Test spots at their spots (2)" in texts and "Shield Generators at their spots (4)" in texts, texts
    bob.eval("T.menu('Test spots at their spots')")
    els = bob.eval_py("return T.elems()")
    assert len(els) == n0 + 2, els
    page = bob.eval_py("local p = T.page() return { p.vx, p.vy, p.vz }")

    def board(mx, my):
        # the board's map math (gen_starter_strategies.py to_board)
        sc = min(1000 / 1024, 666 / 683) * page[2] / 100
        return (math.floor(500 + (mx - page[0]) / 1000 * 1024 * sc + 0.5),
                math.floor(333 + (my - page[1]) / 1000 * 683 * sc + 0.5))

    a, b = els[-2], els[-1]
    assert a["i"] == "npc:21212" and (a["x"], a["y"]) == board(720, 590) and a["f"] == 90 and a["st"] == 2, a
    assert a["l"] == "Test Channeler" and a["z"] == 40, a
    assert b["i"] == "obj:187869" and (b["x"], b["y"]) == board(730, 600) and b["f"] == 0 and "st" not in b, b
    assert bob.eval_py("return T.cv():SelectionCount()") == 2
    # a page on another map: nothing placed, and why
    bob.eval("T.page().m = 0")
    chat0 = len(bob.chat_frame)
    bob.eval("T.cv():BackgroundMenu(300, 200)")
    bob.eval("T.menu('Test spots at their spots')")
    assert bob.eval_py("return #T.elems()") == n0 + 2
    assert any("Serpentshrine" in str(x) and "map" in str(x) for x in bob.chat_frame[chat0:]), bob.chat_frame[chat0:]
    no_errors(w)


@case
def every_encounters_assets_draw_in_2d_and_3d_in_every_state():
    # every encounter with assets (Data/EncounterSpawns.lua): its starter, every group placed where the script puts
    # it (as many as fit the page's 80 drawings), every asset in each of its states, on the map and in the room
    w, c = world()
    bob = c["Bob"]
    bob.eval(HELPERS)
    refs = bob.eval_py("local out = {} for ref in pairs(ns.Data.EncounterSpawns) do out[#out + 1] = ref end "
                       "table.sort(out) return out")
    assert len(refs) >= 30, refs
    seen, opened = {}, []
    for ref in refs:
        bob.eval("ns.StrategyBoard:NewStrategy(...)", ref)
        w.tick(0.2)
        bob.eval("""
            local sp = ns.StrategyObjects.Spawns(...)
            for _, g in ipairs(sp.groups) do
                if #T.elems() + #g.e <= 80 then T.cv():PlaceSpawns(g) end
            end
            T.cv():Render()
        """, ref)
        in3d = bob.eval("return T.cv():Set3D(true, false)") is True
        tick(w, 0.3)
        if in3d:
            drawn = bob.eval_py("local n = 0 for e in pairs(T.v().actors) do n = n + 1 end "
                                "return { actors = n, measured = T.v().measured or false }")
            assert drawn["measured"] and drawn["actors"] >= 1, (ref, drawn)
            opened.append(ref)
        for n in range(1, 5):
            got = bob.eval_py("""
                local n, count = ..., 0
                for _, e in ipairs(T.elems()) do
                    local def = ns.StrategyObjects.DefOf(e.i)
                    if def and def.states and def.states[n] then e.st = n > 1 and n or nil count = count + 1 end
                end
                T.cv():Render()
                return count
            """, n)
            tick(w, 0.15)
            if got:
                seen[ref] = max(seen.get(ref, 0), n)
        if in3d:
            bob.eval("T.cv():Set3D(false)")
            tick(w, 0.6)
        no_errors(w)
    # the encounters whose assets have states went through them
    for ref in ("MagtheridonsLair:Magtheridon", "SerpentshrineCavern:Vashj", "BlackTemple:ShadeOfAkama",
                "ZulAman:Zuljin", "SunwellPlateau:Kiljaeden", "Karazhan:Netherspite", "SunwellPlateau:Muru"):
        assert seen.get(ref, 0) >= 2, (ref, seen.get(ref))
    assert len(opened) == len(refs), sorted(set(refs) - set(opened))
    no_errors(w)


if __name__ == "__main__":
    run_all()
