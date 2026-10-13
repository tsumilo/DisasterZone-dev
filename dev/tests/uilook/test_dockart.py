#!/usr/bin/env python
"""Classic's Dock art (UI/DockArt.lua; Settings > UI > Action bars > Bar art while Classic is the look): three sets
from Media/Classic (dev/generators/gen_classic_media.py) put together on the Dock's grid, a step under the crown, a
pillar in each cluster gap, the band in the experience slot while the bar is hidden, the end caps following the set;
without art pack 9 the plain stone.

Run: luaenv\\Scripts\\python.exe tests\\uilook\\test_dockart.py [-k name]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))
sys.path.insert(0, HERE)

import _common  # noqa: E402
from _common import case, run_all, solo  # noqa: E402
import test_dock  # noqa: E402  (its stand-ins for the game's bars)

del _common._CASES[:]          # (only this file's cases)
ADDON = os.path.join(HERE, "..", "..", "..", "addon", "DisasterZone")
SETS = ("ironforge", "stormwind", "vault")


def art(set_key="ironforge", size=36):
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.look', 'classic')")
    c.eval("ns.DB:SetSetting('ui.bars.art', ...)", set_key)
    c.eval("ns.DB:SetSetting('ui.bars.size', ...)", size)
    c.relog()
    w.tick(2)
    c.eval("__MOCK.real_geometry = true")
    c.eval(test_dock.FAKE_BARS)
    c.eval("ns.LookBars:Restyle(); ns.LookDock:Start(); ns.LookDock:Layout()")
    return w, c


# the art's shown textures on a frame: file name -> count
FILES = """
    local f = ...
    f = type(f) == 'string' and _G[f] or f
    local out = {}
    for _, field in ipairs({ 'dzArt', 'dzBand' }) do
        local pool = f[field]
        if pool then
            for i = 1, pool.n do
                local t = pool.t[i]
                if t:IsShown() then
                    local n = tostring(t:GetTexture() or '?'):gsub('^.*[\\\\/]', '')
                    out[n] = (out[n] or 0) + 1
                end
            end
        end
    end
    return out
"""

# every shown art texture's box against the frame's (dock units): the worst overhang on each side (rivets left out:
# their box is mostly clear round a small dome, which sits on the moulding)
INSIDE = """
    local f = _G[...]
    local worst = { 0, 0, 0, 0 }
    local small = 8.5 * ns.LookDock:Size() / 36
    for _, field in ipairs({ 'dzArt', 'dzBand' }) do
        for i = 1, (f[field] and f[field].n or 0) do
            local t = f[field].t[i]
            if t:IsShown() and not (t:GetWidth() <= small and t:GetHeight() <= small) then
                worst[1] = math.max(worst[1], f:GetLeft() - t:GetLeft())
                worst[2] = math.max(worst[2], t:GetRight() - f:GetRight())
                worst[3] = math.max(worst[3], t:GetTop() - f:GetTop())
                worst[4] = math.max(worst[4], f:GetBottom() - t:GetBottom())
            end
        end
    end
    return worst
"""


# ------------------------------------------------------------------------------------------------------------------
@case
def every_set_draws_its_plate_from_its_own_pieces():
    for key in SETS:
        w, c = art(key)
        assert c.eval("return ns.DockArt:Ready() and DisasterZoneDock.dzArtOn") is True, key
        files = c.eval_py(FILES, "DisasterZoneDock")
        assert files.get(key, 0) > 30 and files.get(key + "_ground", 0) >= 1, (key, files)
        # the wells: 36 in the block, 6 bags, 3 stances (the vanilla bar's own wells, the bank's relief, ours)
        if key == "ironforge":
            assert files.get("UI-MainMenuBar-Dwarf") == 45 and files.get("UI-MainMenuBar-MaxLevel", 0) >= 1, files
        elif key == "vault":
            assert files.get("UI-GuildBankFrame-Slots") == 45 and "UI-MainMenuBar-Dwarf" not in files, files
        else:
            assert "UI-MainMenuBar-Dwarf" not in files and "UI-GuildBankFrame-Slots" not in files, files
        # no plain stone, no tooltip edge, the old wells hidden
        r = c.eval_py("""
            local f = DisasterZoneDock
            return { f.stone == nil or not f.stone.t[1] or not f.stone.t[1]:IsShown(),
                     f.wells == nil or not f.wells.t[1] or not f.wells.t[1]:IsShown() }""")
        assert r == [True, True], (key, r)
        # nothing drawn outside the dock's frame (the caps stand outside it in their own frame)
        out = c.eval_py(INSIDE, "DisasterZoneDock")
        assert max(out) < 0.51, (key, out)
        # the caps: lions with Stormwind, gryphons with the others ("Match the art")
        cap = c.eval("return DisasterZoneDock.capL:GetTexture()")
        assert cap.endswith("EndCap-Human" if key == "stormwind" else "EndCap-Dwarf"), (key, cap)
        # the rail wears the set too
        files = c.eval_py(FILES, "DisasterZoneDockRail")
        assert files.get(key, 0) > 8, (key, files)
        w.assert_no_errors()


@case
def every_button_size_draws_a_bounded_plate():
    # (2026-10-13 in game: the ground's tiles were laid by a running sum that stopped moving at sizes like 42 - the
    # client froze for minutes and the Dock never laid out)
    for size in (30, 33, 39, 42, 45, 47):
        w, c = art("vault", size)
        n = c.eval("return DisasterZoneDock.dzArtOn and DisasterZoneDock.dzArt.n or -1")
        assert 50 < n < 1500, (size, n)
        out = c.eval_py(INSIDE, "DisasterZoneDock")
        assert max(out) < 0.51, (size, out)
        w.assert_no_errors()


@case
def a_failing_art_leaves_the_dock_laid_out_in_plain_stone():
    w, c = art("ironforge")
    c.eval("ns.DockArt.Spec = function() error('broken art') end; ns.LookDock:Layout()")
    assert c.eval("return DisasterZoneDock.dzArtOn") is False
    assert c.eval("return DisasterZoneDock.stone.t[1]:IsShown()") is True
    # (the buttons still sit on the grid)
    g = c.eval_py("return ns.LookDock.grid")
    b = test_dock.box(c, "ActionButton1")
    assert abs(b[0] - g["block"]["x"]) < 0.01, (b, g["block"])
    w.clear_errors() if hasattr(w, "clear_errors") else None


@case
def the_crown_stands_on_a_step_and_pillars_split_the_clusters():
    w, c = art("ironforge")
    s = c.eval_py("""
        local D = ns.LookDock
        local spec = ns.DockArt:Spec(D.T, D.grid, 3)
        return { steps = spec.steps, posts = spec.posts, top = spec.top, g = D.grid, T = D.T, cells = #spec.cells }""")
    T, g, st = s["T"], s["g"], s["steps"]
    assert (T["P"], T["R"]) == (12, 16), T
    # one step round the 3 stance buttons, P out to the sides and up, from the plate's top
    assert len(st) == 1, st
    assert st[0]["x0"] == g["stance"][0][0] - 12 and st[0]["x1"] == g["stance"][2][0] + 27 + 12, st
    assert st[0]["y0"] == 0 and s["top"] == g["plateTop"] == 27 + 16, (st, s["top"])
    # a pillar in the middle of each gap (bags | pager, block | menu)
    assert s["posts"] == g["seams"] and len(s["posts"]) == 2, s["posts"]
    assert s["cells"] == 36 + 6 + 3
    # a stance and a pet bar that nearly touch share one step; far apart, two
    two = c.eval_py("""
        local D = ns.LookDock
        local T = D.Tokens('classic', 36)
        local g = D.Grid(T, { rows = 3, bags = 6, menu = 12, stance = 3, pet = 10, pager = true })
        local g2 = D.Grid(T, { rows = 3, bags = 6, menu = 12, stance = 10, pet = 10, pager = true })
        return { #ns.DockArt:Spec(T, g, 3).steps, #ns.DockArt:Spec(T, g2, 3).steps }""")
    assert two == [2, 1], two
    w.assert_no_errors()


@case
def the_band_lies_in_the_slot_only_while_the_bar_is_hidden():
    w, c = art("stormwind")
    # level 70, nothing watched: the bar is hidden, the gilt pearls lie in its slot
    assert c.eval("return DisasterZoneXPBar:IsShown()") is False
    band = "local p = DisasterZoneDock.dzBand local n = 0 for i = 1, p.n do if p.t[i]:IsShown() then n = n + 1 end end return n"
    assert c.eval(band) > 0
    # levelling: the bar shows in the sunk slot (no main-bar rail over it), the band goes
    c.eval("""
        local real = UnitLevel
        UnitLevel = function(u) if u == 'player' then return 60 end return real(u) end
        UnitXP = function() return 41000 end
        UnitXPMax = function() return 100000 end
        GetXPExhaustion = function() return 12000 end
        ns.LookBars:XP()""")
    assert c.eval("return DisasterZoneXPBar:IsShown()") is True
    assert c.eval(band) == 0
    assert c.eval("local f = DisasterZoneXPBar return f.railFrame == nil or not f.railFrame:IsShown()") is True
    g = c.eval_py("return ns.LookDock.grid.xp")
    b = test_dock.box(c, "DisasterZoneXPBar")
    assert abs(b[0] - g["x"]) < 0.01 and abs(b[1] - g["y"]) < 0.01 and abs(b[2] - g["w"]) < 0.01, (b, g)
    # the experience bar switched off: the band again
    c.eval("ns.DB:SetSetting('ui.bars.xp', false); ns.LookBars:XP()")
    assert c.eval(band) > 0
    w.assert_no_errors()


@case
def picking_a_set_redraws_the_dock_and_the_caps_follow():
    w, c = art("ironforge")
    c.eval("ns.DB:SetSetting('ui.bars.art', 'stormwind')")
    w.tick(0.2)
    files = c.eval_py(FILES, "DisasterZoneDock")
    assert files.get("stormwind", 0) > 30 and "ironforge" not in files, files
    assert c.eval("return DisasterZoneDock.capL:GetTexture()").endswith("EndCap-Human")
    # caps chosen by hand stay
    c.eval("ns.DB:SetSetting('ui.bars.caps', 'gryphon')")
    w.tick(0.2)
    assert c.eval("return DisasterZoneDock.capL:GetTexture()").endswith("EndCap-Dwarf")
    c.eval("ns.DB:SetSetting('ui.bars.caps', 'none')")
    w.tick(0.2)
    assert c.eval("return DisasterZoneDock.caps:IsShown()") is False
    # another look: the art goes
    c.eval("ns.DB:SetSetting('ui.bars.look', 'flat')")
    w.tick(0.2)
    assert c.eval_py(FILES, "DisasterZoneDock") == {} or c.eval_py(FILES, "DisasterZoneDock") == []
    assert c.eval("return DisasterZoneDock.dzArtOn") is False
    w.assert_no_errors()


@case
def without_art_pack_9_the_dock_keeps_the_plain_stone():
    w, c = art("vault")
    c.eval("ns.assetPack = 8; ns.LookDock:Layout()")
    assert c.eval("return ns.DockArt:Ready()") is False
    assert c.eval("return DisasterZoneDock.dzArtOn") is False
    files = c.eval_py(FILES, "DisasterZoneDock")
    assert files == {} or files == [], files
    assert c.eval("return DisasterZoneDock.stone.t[1]:IsShown()") is True
    assert c.eval("return DisasterZoneDock.capL:GetTexture()").endswith("EndCap-Dwarf")   # ("match": gryphons)
    w.assert_no_errors()


@case
def settings_offer_the_sets_only_while_classic_is_set():
    w, c = art("ironforge")
    c.eval("ns.MainFrame:Open('settings'); ns.SettingsUI:SelectSection('ui')")
    w.tick(0.3)
    ROW = """
        local want = ...
        for _, r in ipairs(ns.SettingsUI.sections.ui.rows) do
            if r.title and r.title:GetText() == want then
                return { r.readOnly == true, r.control:IsShown(), r.value and r.value:IsShown() and r.value:GetText() or false }
            end
        end
        return 'missing'"""
    assert c.eval_py(ROW, "Bar art") == [False, True, False]
    assert c.eval_py(ROW, "End caps") == [False, True, False]
    c.eval("ns.DB:SetSetting('ui.bars.look', 'flat')")
    w.tick(0.3)
    assert c.eval_py(ROW, "Bar art") == [True, False, "With Classic"]
    assert c.eval_py(ROW, "End caps") == [True, False, "With Classic"]
    # (another part's look leaves them be)
    c.eval("ns.DB:SetSetting('ui.bars.look', 'inherit')")
    w.tick(0.3)
    assert c.eval_py(ROW, "Bar art") == [False, True, False]
    w.assert_no_errors()


@case
def the_atlas_pieces_lie_inside_their_files():
    from PIL import Image
    src = open(os.path.join(ADDON, "Data", "ClassicArt.lua"), encoding="utf-8").read()
    need = {"tl", "tr", "bl", "br", "top", "bottom", "left", "right", "jl", "jr", "post_top", "post_mid", "post_bot",
            "stud"} | {"tray_" + p for p in ("tl", "t", "tr", "l", "c", "r", "bl", "b", "br")}
    for key in SETS:
        block = re.search(r"\n    %s = \{(.*?)\n    \}," % key, src, re.S).group(1)
        w, h = (int(v) for v in re.search(r"w = (\d+), h = (\d+)", block).groups())
        img = Image.open(os.path.join(ADDON, "Media", "Classic", key + ".tga"))
        assert img.size == (w, h) and img.mode == "RGBA", (key, img.size, img.mode)
        g = Image.open(os.path.join(ADDON, "Media", "Classic", key + "_ground.tga"))
        assert g.size == (256, 256), (key, g.size)
        pieces = {m[0]: tuple(int(v) for v in m[1:]) for m in
                  re.findall(r"(\w+) = \{ (\d+), (\d+), (\d+), (\d+) \}", block)}
        want = set(need)
        if key != "ironforge":
            want |= {"well_" + p for p in ("tl", "t", "tr", "l", "c", "r", "bl", "b", "br")} | {"fill"}
        if key != "stormwind":
            want.add("rivet")
        if key == "vault":
            want.add("junction")
        assert want <= set(pieces), (key, want - set(pieces))
        for name, (x, y, pw, ph) in pieces.items():
            assert x >= 1 and y >= 1 and x + pw <= w - 1 and y + ph <= h - 1, (key, name, (x, y, pw, ph))


if __name__ == "__main__":
    run_all()
