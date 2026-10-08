"""Guild > Map (Core/GuildMap.lua, UI/GuildMapUI.lua): guildmates who share where they are, give to get (only sharers
see each other), zone only, instances at their entrance, hidden in battlegrounds, the Members card's "In ..." /
"Last seen in ...", and the map page itself.

Run: luaenv\\Scripts\\python.exe tests\\members\\test_guildmap.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from mb_common import case, run_all, K, guild  # noqa: E402

M = "ns.GuildMap"
NAGRAND, SHATT, OUTLAND, TEROKKAR = 1951, 1955, 1945, 1952


def trio():
    w, c = guild([("Gina", "PALADIN"), ("Alfa", "MAGE"), ("Bert", "ROGUE")])
    w.set_position(c["Gina"], SHATT, 0.5, 0.45, subzone="Terrace of Light")
    w.set_position(c["Alfa"], NAGRAND, 0.42, 0.44, subzone="Halaa")
    w.set_position(c["Bert"], NAGRAND, 0.55, 0.37, subzone="Garadar")
    return w, c["Gina"], c["Alfa"], c["Bert"]


def share(cl, mode):
    cl.eval("%s:SetShare(...)" % M, mode)


def entries(cl):
    return cl.eval_py("local o = {} for k, e in pairs(%s:GetEntries()) do o[ns.Util.ShortName(k)] = "
                      "{ m = e.m, x = e.x, y = e.y, s = e.s, z = e.z or false, i = e.i, a = e.a or false } end "
                      "return o" % M) or {}


def map_msgs(w, start=0):
    return [e for e in w.addon_log[start:] if e["prefix"] == "CDLq"]


def look(cl, on=True):
    cl.eval("%s:SetViewing(...)" % M, on)


@case
def nobody_shares_until_asked_and_nothing_goes_out():
    w, g, a, b = trio()
    assert g.eval_py("return %s:GetShare()" % M) == "unset"
    look(g)
    w.tick(60)
    assert map_msgs(w) == [], map_msgs(w)
    assert entries(g) == {}
    w.assert_no_errors()


@case
def sharers_see_each_other_live():
    w, g, a, b = trio()
    share(g, "exact")
    share(a, "exact")
    w.tick(5)
    look(g)
    w.tick(5)
    e = entries(g)
    assert set(e) == {"Gina", "Alfa"}, e
    assert e["Alfa"]["m"] == NAGRAND and abs(e["Alfa"]["x"] - 0.42) < 0.001 and e["Alfa"]["s"] == "Halaa", e
    # Alfa walks: it streams while Gina looks
    w.set_position(a, NAGRAND, 0.47, 0.50, subzone="Halaa")
    w.tick(5)
    assert abs(entries(g)["Alfa"]["x"] - 0.47) < 0.001, entries(g)
    # on the continent: Nagrand's spot translated onto Outland
    xy = g.eval_py("local e = %s:GetEntries()[...]; return { %s:PlaceOn(e, %d) }" % (M, M, OUTLAND), K("Alfa"))
    assert xy and 0 < xy[0] < 1 and 0 < xy[1] < 1, xy
    # nobody looks any more: the stream stops after a while
    look(g, False)
    w.tick(120)
    n = len(map_msgs(w))
    w.set_position(a, NAGRAND, 0.30, 0.30)
    w.tick(30)
    assert len(map_msgs(w)) == n, map_msgs(w)[n:]
    w.assert_no_errors()


@case
def give_to_get_a_non_sharer_sees_nobody():
    w, g, a, b = trio()
    share(g, "exact")
    share(a, "exact")
    share(b, "off")
    look(g)
    look(b)
    w.tick(10)
    assert entries(b) == {}, entries(b)
    assert b.eval_py("return %s:GetWhere(...)" % M, K("Alfa")) is None
    # the map page: the card instead of the map
    b.eval("ns.MainFrame:Open('map')")
    w.tick(1)
    assert b.eval_py("return ns.GuildMapUI:GetPanel().veil:IsShown()") is True
    # Bert asks nobody; sharers don't answer an ask from someone who doesn't share
    assert not [m for m in map_msgs(w) if m["sender"] == K("Bert")], map_msgs(w)
    w.assert_no_errors()


@case
def zone_only_shows_a_zone_and_sees_by_zone():
    w, g, a, b = trio()
    share(g, "exact")
    share(a, "zone")
    share(b, "exact")
    look(g)
    look(a)
    w.tick(10)
    e = entries(g)
    assert e["Alfa"]["z"] is True and e["Alfa"].get("x") is None, e     # no spot on the wire
    assert e["Bert"].get("x") is not None, e
    # Alfa only shares a zone: everyone is a zone to Alfa
    ea = entries(a)
    assert ea["Bert"]["z"] is True and ea["Bert"].get("x") is None, ea
    w.assert_no_errors()


@case
def an_instance_stands_at_its_entrance_and_battlegrounds_hide():
    w, g, a, b = trio()
    share(g, "exact")
    share(a, "exact")
    look(g)
    w.tick(5)
    w.enter_instance("Shadow Labyrinth", 555, "party", 5, clients=[a])
    w.tick(10)
    e = entries(g)["Alfa"]
    assert e.get("i") == 555 and e.get("m") is None, e
    xy = g.eval_py("local e = %s:GetEntries()[...]; return { %s:PlaceOn(e, %d) }" % (M, M, OUTLAND), K("Alfa"))
    assert xy and 0 < xy[0] < 1, xy
    w.leave_instance([a])
    w.enter_instance("Eye of the Storm", 566, "pvp", 15, clients=[a])
    w.tick(10)
    assert "Alfa" not in entries(g), entries(g)
    w.assert_no_errors()


@case
def stopping_drops_me_everywhere():
    w, g, a, b = trio()
    share(g, "exact")
    share(a, "exact")
    look(g)
    w.tick(5)
    assert "Alfa" in entries(g)
    share(a, "off")
    w.tick(2)
    assert "Alfa" not in entries(g), entries(g)
    assert entries(a) == {}
    w.assert_no_errors()


@case
def members_card_says_where_and_where_last_seen():
    w, g, a, b = trio()
    share(g, "exact")
    share(a, "exact")
    look(g)
    w.tick(5)
    g.eval("ns.MainFrame:Open('members'); ns.MembersUI:SelectMember(...)", K("Alfa"))
    w.tick(1)
    parts = g.eval_py("return ns.MembersUI:GetPanel().right.metaParts")
    assert "In Halaa, Nagrand" in parts, parts
    assert g.eval_py("return ns.MembersUI:GetPanel().right.onMap:IsShown()") is True
    a.logout()
    w.tick(5)
    g.eval("ns.MembersUI:Refresh()")
    parts = g.eval_py("return ns.MembersUI:GetPanel().right.metaParts")
    assert any(p.startswith("Last seen in Nagrand") for p in parts), parts
    assert g.eval_py("return ns.MembersUI:GetPanel().right.onMap:IsShown()") is False
    # a /reload keeps it (saved)
    g.relog()
    w.tick(3)
    where = g.eval_py("return %s:GetWhere(...)" % M, K("Alfa"))
    assert where and where["zone"] == "Nagrand" and where["live"] is False, where
    w.assert_no_errors()


@case
def the_map_page_pins_crowds_and_zooms():
    w, g, a, b = trio()
    w.set_position(b, NAGRAND, 0.421, 0.442, subzone="Halaa")      # right next to Alfa: one crowd
    for cl in (g, a, b):
        share(cl, "exact")
    g.eval("ns.MainFrame:Open('map')")
    w.tick(6)
    ui = g.eval_py("""
      local p = ns.GuildMapUI:GetPanel()
      local o = { veil = p.veil:IsShown(), pins = {}, zones = {} }
      for _, b in ipairs(p.pins) do if b:IsShown() then
        o.pins[#o.pins + 1] = { kind = b.data.kind, n = b.data.keys and #b.data.keys or 1 } end end
      for _, z in ipairs(p.zones) do o.zones[#o.zones + 1] = { z.name, #z.keys } end
      local tabs = {} for _, t in ipairs(p.tabs) do tabs[#tabs + 1] = t:GetText() end
      o.tabs = tabs
      return o""")
    assert ui["veil"] is False
    kinds = sorted((p["kind"], p["n"]) for p in ui["pins"])
    assert kinds == [("crowd", 2), ("me", 1)], ui
    assert ui["zones"][0] == ["Nagrand", 2], ui
    assert any("Outland" in t and "3" in t for t in ui["tabs"]), ui["tabs"]
    # into Nagrand: two dots with their names, the list by subzone
    g.eval("ns.GuildMapUI:ShowZone(%d)" % NAGRAND)
    w.tick(1)
    z = g.eval_py("""
      local p = ns.GuildMapUI:GetPanel()
      local o = { labels = {}, zones = {}, crumb = p.crumb:IsShown() }
      for _, b in ipairs(p.pins) do if b:IsShown() and b.data.kind == "dot" then
        o.labels[#o.labels + 1] = ns.Util.ShortName(b.data.key) end end
      for _, z in ipairs(p.zones) do o.zones[#o.zones + 1] = z.name end
      return o""")
    assert sorted(z["labels"]) == ["Alfa", "Bert"] and z["zones"] == ["Halaa"] and z["crumb"] is True, z
    # (they stood a pixel apart: two dots nudged apart, no names on top of each other)
    gap = g.eval_py("""local o = {} for _, b in ipairs(ns.GuildMapUI:GetPanel().pins) do
      if b:IsShown() and b.data.kind == "dot" then o[#o + 1] = { b.data.px, b.data.py, b.data.label or false } end end
      return o""")
    assert ((gap[0][0] - gap[1][0]) ** 2 + (gap[0][1] - gap[1][1]) ** 2) ** 0.5 >= 15, gap
    w.assert_no_errors()


@case
def regions_open_like_the_games_map():
    """A region of the continent opens its map (Hellfire Peninsula), a city in a zone too (Shattrath in Terokkar);
    the crumb and a right-click go back up one step at a time."""
    w, g, a, b = trio()
    share(g, "exact")
    g.eval("ns.MainFrame:Open('map')")
    w.tick(1)
    hell = g.eval_py("return { ns.GuildMapUI:RegionAt(%d, ...) }" % OUTLAND,
                     *g.eval_py("return { ns.GuildMap:Translate(1944, 0.5, 0.5, %d) }" % OUTLAND))
    assert hell == [1944, "Hellfire Peninsula"], hell
    shat = g.eval_py("return { ns.GuildMapUI:RegionAt(%d, ...) }" % TEROKKAR,
                     *g.eval_py("return { ns.GuildMap:Translate(1955, 0.5, 0.95, %d) }" % TEROKKAR))
    assert shat == [SHATT, "Shattrath City"], shat
    assert g.eval_py("return { ns.GuildMapUI:RegionAt(%d, 0.98, 0.05) }" % OUTLAND) == []   # the sky: nothing
    g.eval("ns.GuildMapUI:ShowZone(%d)" % SHATT)
    w.tick(0.3)
    crumb = g.eval_py("return ns.GuildMapUI:GetPanel().crumb.text:GetText()")
    assert "Outland" in crumb and "Terokkar Forest" in crumb and crumb.endswith("Shattrath City"), crumb
    g.eval("ns.GuildMapUI:ZoomOut()")
    assert g.eval_py("return ns.GuildMapUI:GetState().zone") == TEROKKAR
    g.eval("ns.GuildMapUI:ZoomOut()")
    assert g.eval_py("return ns.GuildMapUI:GetState().zone") is None
    assert g.eval_py("return ns.GuildMapUI:GetState().cont") == OUTLAND
    w.assert_no_errors()


@case
def demo_mode_fills_the_map_crowded_without_asking():
    w, g, a, b = trio()
    g.slash("/dz demo on")
    w.tick(1)
    e = entries(g)                                   # (Gina doesn't share: demo shows its guild anyway)
    assert len(e) > 60, len(e)
    insts = {x.get("i") for x in e.values()}
    assert {555, 564, 532} <= insts, insts
    g.eval("ns.MainFrame:Open('map')")
    w.tick(1)
    ui = g.eval_py("""
      local p = ns.GuildMapUI:GetPanel()
      local o = { veil = p.veil:IsShown(), crowds = 0, dungeons = 0 }
      for _, b in ipairs(p.pins) do if b:IsShown() then
        if b.data.kind == "crowd" then o.crowds = o.crowds + 1 end
        if b.data.kind == "dungeon" then o.dungeons = o.dungeons + 1 end end end
      return o""")
    assert ui["veil"] is False and ui["crowds"] >= 2 and ui["dungeons"] >= 3, ui
    # demo walkers move: the same member stands elsewhere a few seconds later
    walker = g.eval_py("for k, e in pairs(ns.GuildMap:GetEntries()) do if e.demo and e.s == 'Halaa' then return k end end")
    x1 = g.eval_py("return ns.GuildMap:GetEntries()[...].x", walker)
    w.tick(5)
    assert g.eval_py("return ns.GuildMap:GetEntries()[...].x", walker) != x1
    g.slash("/dz demo off")
    w.tick(1)
    assert entries(g) == {}
    w.assert_no_errors()


@case
def dots_glide_to_their_new_place():
    w, g, a, b = trio()
    share(g, "exact")
    share(a, "exact")
    g.eval("ns.MainFrame:Open('map'); ns.GuildMapUI:ShowZone(%d)" % NAGRAND)
    w.tick(5)
    pin = "for _, b in ipairs(ns.GuildMapUI:GetPanel().pins) do if b:IsShown() and b.data.key == ... then "           "return { b.glide.x, b.glide.tx } end end"
    x0, _ = g.eval_py(pin, K("Alfa"))
    w.set_position(a, NAGRAND, 0.60, 0.44, subzone="Halaa")
    w.tick(3.2)                 # the next report arrives (<= 2 s) and the dot is on its way
    x, tx = g.eval_py(pin, K("Alfa"))
    assert tx > x0 + 20, (x0, tx)
    w.tick(2.5)
    x2, tx2 = g.eval_py(pin, K("Alfa"))
    assert abs(x2 - tx2) < 0.01, (x2, tx2)    # arrived
    w.assert_no_errors()


@case
def the_games_world_map_groups_like_the_map_page():
    """Blizzard's world map (M) gets the same pins: crowds on a continent and one pin per instance with its count (the
    bug: every member drawn on their own, an instance's people stacked as many "1" badges)."""
    w, g, a, b = trio()
    g.slash("/dz demo on")
    w.tick(1)
    # (a stand-in for WorldMapFrame: a canvas 1002 x 668 at zoom 1 showing Outland)
    ui = g.eval_py("""
      local mapID = ...
      local wm = CreateFrame("Frame", "WorldMapFrame", UIParent)
      local canvas = CreateFrame("Frame", nil, wm)
      canvas:SetSize(1002, 668)
      wm.GetCanvas = function() return canvas end
      wm.GetMapID = function() return mapID end
      wm.GetCanvasScale = function() return 1 end
      wm.IsShown = function() return true end
      local W = ns.GuildMapUI.WorldMap
      W:Refresh()
      local o = { n = W.count, kinds = {} }
      for _, b in ipairs(W.pins) do if b:IsShown() then
        local d = b.data
        local k = d.kind .. (d.kind == "dungeon" and (":" .. #d.keys) or "")
        o.kinds[k] = (o.kinds[k] or 0) + 1 end end
      return o""", OUTLAND)
    kinds = ui["kinds"]
    assert kinds.get("dungeon:10") == 1 and kinds.get("dungeon:6") == 1 and kinds.get("dungeon:3") == 1, kinds
    assert kinds.get("crowd", 0) >= 2 and "me" not in kinds, kinds
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()
