"""Refactor 1.4, phase 2: the theme registry + tile picker (UI/Comp/Themes.lua) and the map art helpers
(UI/Comp/MapArt.lua) that replace the copies in MeterTheme / BarFace and StrategyMap / EventWidgets / GuildMapUI /
EventBuilder.

The saved setting keys and values stay what they were (meters.theme, classbar.theme), each picker keeps its tile size,
and MapArt lays tiles out exactly as the copies did.

Run: luaenv\\Scripts\\python.exe tests\\style\\test_themes_mapart.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402


# ------------------------------------------------------------------------------------------------------------------
# Themes
# ------------------------------------------------------------------------------------------------------------------
@case
def both_kinds_share_one_registry_with_their_old_keys():
    w, c = solo()
    got = c.eval_py("""
        local T = ns.Themes
        local o = {}
        for _, kind in ipairs({ 'meters', 'classbar' }) do
            local k = T:Kind(kind)
            o[kind] = { setting = k.setting, default = k.default, n = #k.list,
                        unknown = T:Get(kind, 'nope').key, cur = T:Current(kind).key }
        end
        o.sameMeters = ns.MeterTheme.BY_KEY == T:Kind('meters').byKey
        o.sameBars = ns.BarFace and (ns.BarFace.BY_KEY == T:Kind('classbar').byKey) or 'n/a'
        return o""")
    assert got["meters"] == {"setting": "meters.theme", "default": "flat", "n": 7, "unknown": "flat",
                             "cur": "flat"}, got
    assert got["classbar"]["setting"] == "classbar.theme", got
    assert got["classbar"]["default"] == "halo" and got["classbar"]["unknown"] == "halo", got
    assert got["sameMeters"] is True and got["sameBars"] is True, got
    no_errors(w)


@case
def a_preview_changes_the_look_but_not_the_setting():
    w, c = solo()
    c.eval("ns.DB:SetSetting('meters.theme', 'sigil')")
    got = c.eval_py("""
        local o = { saved = ns.Themes:Saved('meters'), before = ns.MeterTheme:Theme().key }
        ns.MeterTheme:SetPreview('pips')
        o.during = ns.MeterTheme:Theme().key
        o.preview = ns.Themes:Preview('meters')
        o.setting = ns.DB:GetSetting('meters.theme')
        ns.MeterTheme:SetPreview(nil)
        o.after = ns.MeterTheme:Theme().key
        o.metricsOther = ns.MeterTheme:Metrics(ns.MeterTheme.BY_KEY.pips).row ~= ns.MeterTheme:Metrics().row
        o.stillSigil = ns.MeterTheme:Theme().key
        return o""")
    assert got == {"saved": "sigil", "before": "sigil", "during": "pips", "preview": "pips", "setting": "sigil",
                   "after": "sigil", "metricsOther": True, "stillSigil": "sigil"}, got
    no_errors(w)


@case
def a_tile_click_saves_the_key_and_tiles_keep_their_sizes():
    w, c = solo()
    got = c.eval_py("""
        local p = CreateFrame('Frame', nil, UIParent); p:SetSize(800, 200)
        local picked
        local m = ns.UI:CreateThemeTiles(p, 'meters', { tileW = 84, tileH = 74, gap = 6, onPick = function(k) picked = k end })
        local b = ns.UI:CreateThemeTiles(p, 'classbar', { tileW = 96, tileH = 66, gap = 8 })
        local o = { mN = #m.tiles, mW = m.tiles[1]:GetWidth(), mH = m.tiles[1]:GetHeight(),
                    bW = b.tiles[1]:GetWidth(), bH = b.tiles[1]:GetHeight() }
        local _, _, _, x2 = m.tiles[2]:GetPoint(1); o.mX2 = x2
        local _, _, _, bx2 = b.tiles[2]:GetPoint(1); o.bX2 = bx2
        m.tiles[3]:GetScript('OnEnter')(m.tiles[3])
        o.previewing = ns.Themes:Preview('meters')
        m.tiles[3]:GetScript('OnClick')(m.tiles[3])
        o.saved = ns.DB:GetSetting('meters.theme'); o.picked = picked
        o.previewAfter = ns.Themes:Preview('meters') or false
        o.gold = select(1, m.tiles[3].name:GetTextColor()) > 0.9
        b.tiles[4]:GetScript('OnClick')(b.tiles[4])
        o.bar = ns.DB:GetSetting('classbar.theme')
        return o""")
    assert got["mN"] == 7 and got["mW"] == 84 and got["mH"] == 74 and got["mX2"] == 90, got
    assert got["bW"] == 96 and got["bH"] == 66 and got["bX2"] == 104, got
    assert got["previewing"] == "sigil", got
    assert got["saved"] == "sigil" and got["picked"] == "sigil" and got["previewAfter"] is False, got
    assert got["gold"] is True, got
    bars = c.eval_py("local o = {}; for _, t in ipairs(ns.Themes:Kind('classbar').list) do o[#o + 1] = t.key end; "
                     "return o")
    assert got["bar"] == bars[3], (got, bars)
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# MapArt
# ------------------------------------------------------------------------------------------------------------------
@case
def tiles_lay_out_row_by_row_and_reuse_the_pool():
    w, c = solo()
    got = c.eval_py("""
        local p = CreateFrame('Frame', nil, UIParent); p:SetSize(600, 400)
        local L = { layerWidth = 600, layerHeight = 300, tileWidth = 256, tileHeight = 256 }
        local files = { 'a', 'b', 'c', 'd', 'e', 'f' }
        local pool = {}
        local o = {}
        o.n = ns.MapArt.Tiles(pool, p, L, files, 10, 20, 0.5, { color = { 0.5, 0.5, 0.5 } })
        local _, _, _, x, y = pool[5]:GetPoint(1); o.x5, o.y5 = x, y
        o.w5 = pool[5]:GetWidth()
        o.n2 = ns.MapArt.Tiles(pool, p, L, files, 0, 0, 1, { view = { 300, 200 } })
        o.pool = #pool
        o.n3 = ns.MapArt.Tiles(pool, p, L, { 'a', 'b' }, 0, 0, 1, { lastRowFile = 256 })
        local q = {}
        ns.MapArt.Tiles(q, p, { layerWidth = 256, layerHeight = 300, tileWidth = 256, tileHeight = 256 },
            { 'top', 'rest' }, 0, 0, 1, { lastRowFile = 256 })
        local _, _, _, bottom = q[2]:GetTexCoord(); o.cut = bottom; o.cutH = q[2]:GetHeight()
        return o""")
    assert got["n"] == 6 and got["x5"] == 10 + 128 and got["y5"] == -(20 + 128) and got["w5"] == 128, got
    assert got["n2"] == 2 and got["pool"] == 6, got          # only the two tiles inside 300 x 200
    assert got["n3"] == 2, got
    assert abs(got["cut"] - 44 / 256) < 1e-6 and got["cutH"] == 44, got
    no_errors(w)


@case
def layer_and_yards_read_the_game_and_cache():
    w, c = solo()
    got = c.eval_py("""
        local o = {}
        o.none = ns.MapArt.Layer(0) == nil and ns.MapArt.Layer('x') == nil and ns.MapArt.Files(nil) == nil
        local S = ns.EventSensors
        local real = S and S.World
        local calls = 0
        if S then
            S.World = function(map, x, y) calls = calls + 1; return 1, x * 300, y * 200 end
        end
        local w1, h1 = ns.MapArt.Yards(987654)
        local w2, h2 = ns.MapArt.Yards(987654)
        if S then S.World = real end
        o.w, o.h, o.same, o.calls = w1, h1, (w1 == w2 and h1 == h2), calls
        o.sheet = ns.EventBuilder and ns.EventBuilder.MapSheet and ns.EventBuilder.MapSheet.Yards
                  and ns.EventBuilder.MapSheet.Yards(987654) or 300
        return o""")
    assert got["none"] is True, got
    assert got["w"] == 300 and got["h"] == 200 and got["same"] is True and got["calls"] == 3, got
    assert got["sheet"] == 300, got
    no_errors(w)


if __name__ == "__main__":
    run_all()
