"""Azeromon: light on people (Light.lua, 0.44).

Covers: the art (chars_clean / chars_sil / LightArt.lua) matches the people sheet and has no blob left; a lamp's pull
falls smoothly to nothing at the edge of its reach; walking past lamps never makes a shadow or rim jump (every number
eased, no "nearest two" cut, no snapping when a light is beside someone); a lantern lights everyone but its
carrier; on a lit map at night people get shadows, contact shadows and rims instead of the old blob, by day one sun
shadow each, at dawn the sun shadow points west; the switch and an old art set bring the blob back; the shadows'
slanted texture corners stay inside each silhouette's padded cell; /dz azeromon sky sets the hour and the rain.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_light.py [-k name]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
DEV = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from PIL import Image  # noqa: E402

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

PACK = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone_Azeromon")
MEDIA = os.path.join(PACK, "Media")
BLOB = (117, 113, 97)


def play(map_id, x, y, hour=None):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(3)")
    c.eval("ns.Azero:NewGame()")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    if hour is not None:
        c.eval("ns.Azero.clockHour = %r ns.Azero.forceRain = false" % hour)
    c.eval("ns.Azero:EnterMap(%r, %d, %d, 'down', true)" % (map_id, x, y))
    w.tick(0.4)
    return w, c


def light(c):
    return c.eval_py("return ns.AzeroUI._Light()")


@case
def the_art_matches_the_people_sheet():
    chars = Image.open(os.path.join(MEDIA, "chars.tga")).convert("RGBA")
    clean = Image.open(os.path.join(MEDIA, "chars_clean.tga")).convert("RGBA")
    sil = Image.open(os.path.join(MEDIA, "chars_sil.tga")).convert("RGBA")
    assert chars.size == clean.size == (256, 128), (chars.size, clean.size)
    assert sil.size == (1024, 256), sil.size
    a, b = chars.load(), clean.load()
    removed = kept = 0
    for y in range(128):
        for x in range(256):
            if a[x, y][3] and not b[x, y][3]:
                assert a[x, y][:3] == BLOB, (x, y, a[x, y])          # only the blob goes
                removed += 1
            elif a[x, y][3]:
                assert a[x, y] == b[x, y], (x, y)
                kept += 1
    assert removed > 300 and kept > 3000, (removed, kept)
    src = open(os.path.join(PACK, "LightArt.lua"), encoding="utf-8").read()
    assert "asset = 17" in src, "LightArt.lua's art set"
    cells = re.findall(r"\[(\d+)\] = \"([^\"]*)\"", src)
    assert len(cells) == 96, len(cells)
    _, cl = solo("Alice", tick=2)
    art = cl.eval_py("local a = ns.AzeroLightArt return { cw = a.cw, ch = a.ch, padx = a.padx, pady = a.pady, perRow = a.perRow }")
    s = sil.load()
    for c_, edges in cells:
        c_ = int(c_)
        ox, oy = (c_ % art["perRow"]) * art["cw"] + art["padx"], (c_ // art["perRow"]) * art["ch"] + art["pady"]
        cx, cy = (c_ % 16) * 16, (c_ // 16) * 16
        for y in range(16):
            for x in range(16):
                assert (s[ox + x, oy + y][3] == 255) == (b[cx + x, cy + y][3] > 0), (c_, x, y)
        assert edges and len(edges) % 2 == 0, c_


@case
def a_lights_pull_fades_smoothly_to_nothing_at_its_reach():
    _, c = solo("Alice", tick=2)
    r = c.eval_py("""local L, out = ns.AzeroLight, {}
      for i = 0, 140 do
        local d = i * 0.5
        local t = L.Target(100 + d, 100, 100, 100, 100, 89, 70, 1, { 1, 1, 1 })
        out[#out + 1] = t and t.a or 0
      end
      return out""")
    assert r[0] > 0.5 and r[-1] == 0, (r[0], r[-1])
    for i in range(1, len(r)):
        assert r[i] <= r[i - 1] + 1e-9, (i, r[i - 1], r[i])            # never stronger further away
        assert r[i - 1] - r[i] < 0.02, (i, r[i - 1], r[i])             # no step
    assert r[138] < 0.005, r[138]                                       # all but gone right at the edge


@case
def walking_past_lamps_never_makes_a_shadow_or_rim_jump():
    _, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.Azero.clockHour = 23 ns.Azero:EnterMap('town', 17, 11, 'down', true)")
    worst = c.eval_py("""local L, G = ns.AzeroLight, ns.Azero
      local g = ns.AzeroGround.town
      local lamps = {}
      for i, l in ipairs(g.lights) do
        if l[5] ~= 1 then lamps[#lamps + 1] = { key = 'l' .. i, x = l[1] - g.mx * 16, y = l[2] - g.my * 16 } end
      end
      local state, worst = {}, { kx = 0, ky = 0, a = 0, rw = 0 }
      local prev
      -- along the main road (row 11), half a pixel a frame at 60 fps, past both lamps of row 9
      for step = 0, 2 * 16 * 12 do
        local fx, fy = (17 + 8) * 16 + 8 + step * 0.5, (11 + 5) * 16 + 15 - (5 * 16)
        fx = fx - 8 * 16
        local targets = {}
        for _, l in ipairs(lamps) do
          local t = L.Target(fx, fy, l.x, l.y + 11, l.x, l.y, 70, 1, { 1, 1, 1 })
          if t then targets[l.key] = t end
        end
        L.Ease(state, targets, 1 / 60)
        local now = {}
        for k, s in pairs(state) do now[k] = { kx = s.kx, ky = s.ky, a = s.a, rw = s.rw } end
        if prev then
          for k, s in pairs(now) do
            local p = prev[k] or { kx = s.kx, ky = s.ky, a = 0, rw = 0 }
            for _, f in ipairs({ 'kx', 'ky', 'a', 'rw' }) do
              local d = math.abs(s[f] - p[f])
              if f == 'kx' or f == 'ky' then d = d * math.min(1, (s.a + p.a) * 4) end   -- (a slant only shows with strength)
              if d > worst[f] then worst[f] = d end
            end
          end
        end
        prev = now
      end
      return worst""")
    assert worst["a"] < 0.02 and worst["rw"] < 0.03, worst
    assert worst["kx"] < 0.06 and worst["ky"] < 0.06, worst


@case
def a_light_beside_someone_lays_the_shadow_down_steadily():
    _, c = solo("Alice", tick=2)
    ky = c.eval_py("""local L, out = ns.AzeroLight, {}
      for i = -40, 40 do                       -- the light passes from above to below someone, right beside them
        local t = L.Target(100, 100, 80, 100 + i * 0.5, 80, 89 + i * 0.5, 70, 1, { 1, 1, 1 })
        out[#out + 1] = t.ky
      end
      return out""")
    for i in range(1, len(ky)):
        assert abs(ky[i] - ky[i - 1]) < 0.05, (i, ky[i - 1], ky[i])


@case
def a_lantern_lights_everyone_but_its_carrier():
    w, c = play("town", 17, 11, hour=23)
    c.eval("ns.AzeroLight.Begin({ m = ns.Azero.map, g = ns.AzeroGround.town, now = 1, period = 'night', outdoor = true, dark = 'n',"
           " toScreen = function(x, y) return x, y end })")
    c.eval("ns.AzeroLight.AddLight('guard', 400, 300)")
    c.eval("ns.AzeroLight.Person('guard', 3, 392, 290, {}) ns.AzeroLight.Person('crier', 3, 420, 290, {})")
    guard = c.eval_py("return ns.AzeroLight.State('guard')") or {}
    crier = c.eval_py("return ns.AzeroLight.State('crier')") or {}
    assert "vguard" not in guard, guard
    assert "vguard" in crier and crier["vguard"]["a"] > 0.1, crier
    no_errors(w)


@case
def people_at_night_get_shadows_and_rims_instead_of_the_blob():
    w, c = play("town", 23, 10, hour=23)           # between Goldshire's two lamps on row 9
    st = light(c)
    assert st["on"], st
    assert st["contacts"] >= 1 and st["shadows"] >= 1 and st["rims"] > 0, st
    assert not st["playerBlob"] and st["playerFile"].endswith("chars_clean"), st
    assert c.eval("return ns.AzeroUI._ShadowsShown()") == 0
    assert st["lights"] >= 2 and st["live"] >= 1, st         # the lamps in view, the player's lantern
    no_errors(w)


@case
def by_day_everyone_has_one_sun_shadow_and_at_dawn_it_points_west():
    w, c = play("town", 17, 12, hour=12)
    w.tick(0.6)
    st = light(c)
    assert st["sun"] and st["shadows"] == st["contacts"] >= 1, st
    me = c.eval_py("return ns.AzeroLight.State('me')")
    assert set(me) == {"sun"} and me["sun"]["kx"] > 0.5, me             # down and right, like the props' shadows
    c.eval("ns.Azero.clockHour = 6")
    w.tick(1.0)
    me = c.eval_py("return ns.AzeroLight.State('me')")
    assert me["sun"]["kx"] < -0.5, me
    no_errors(w)


@case
def the_rain_and_indoors_have_no_sun():
    w, c = play("town", 17, 12, hour=12)
    c.eval("ns.Azero.forceRain = true")
    w.tick(1.2)
    st = light(c)
    assert not st["sun"] and st["shadows"] == 0 and st["contacts"] >= 1, st
    no_errors(w)


@case
def the_switch_and_an_old_art_set_bring_the_blob_back():
    w, c = play("town", 23, 10, hour=23)
    c.eval("ns.Azero:Data().lights = false")
    w.tick(0.2)
    st = light(c)
    assert not st["on"] and st["shadows"] == 0 and st["rims"] == 0 and st["contacts"] == 0, st
    assert st["playerBlob"] and st["playerFile"].endswith("chars"), st
    assert c.eval("return ns.AzeroUI._ShadowsShown()") >= 1
    c.eval("ns.Azero:Data().lights = nil ns.assetPack = 16")
    w.tick(0.2)
    assert not light(c)["on"]
    c.eval("ns.assetPack = 17")
    w.tick(0.2)
    assert light(c)["on"]
    no_errors(w)


@case
def a_slanted_shadow_stays_inside_its_padded_cell():
    _, c = solo("Alice", tick=2)
    bad = c.eval_py("""local L, art = ns.AzeroLight, ns.AzeroLightArt
      local made = {}
      local fake = { CreateTexture = function()
        local t = {}
        function t.SetTexCoord(self, ...) self.tc = { ... } end
        function t.SetSize() end function t.ClearAllPoints() end function t.SetPoint() end function t.Show() end
        function t.SetVertexColor() end function t.SetGradient() end function t.Hide() end function t.SetBlendMode() end
        function t.IsShown() return true end function t.SetColorTexture() end
        made[#made + 1] = t
        return t
      end }
      L.Attach(fake, 3, function() return true end)
      L.Begin({ now = 1, period = 'day', outdoor = true, toScreen = function(x, y) return x, y end })
      local bad = {}
      for _, k in ipairs({ { 0.7, 0.34 }, { 1.2, 0.36 }, { -1.2, 0.36 }, { 1.15, -0.9 }, { -0.4, 0.92 }, { 0.9, 0.02 } }) do
        L.SUN.day = { kx = k[1], ky = k[2], a = 0.3, rx = 0, ry = -1, rw = 0, col = { 1, 1, 1 } }
        L.Reset()
        L.Begin({ now = 1, period = 'day', outdoor = true, toScreen = function(x, y) return x, y end })
        L.Person('p', 37, 0, 0, {})
        for _, t in ipairs(made) do
          if t.tc and #t.tc == 8 then
            local ox = (37 % art.perRow) * art.cw / art.w
            local oy = math.floor(37 / art.perRow) * art.ch / art.h
            for i = 1, 8, 2 do
              local u, v = t.tc[i] - ox, t.tc[i + 1] - oy
              if u < -0.0001 or u > art.cw / art.w + 0.0001 or v < -0.0001 or v > art.ch / art.h + 0.0001 then
                bad[#bad + 1] = string.format('%.2f,%.2f: %.4f %.4f', k[1], k[2], u, v)
              end
            end
          end
          t.tc = nil
        end
      end
      return bad""")
    assert bad == [], bad


@case
def the_sky_command_sets_the_hour_and_the_rain():
    w, c = play("town", 17, 12)
    c.slash("/dz azeromon sky night")
    assert c.eval("return ns.Azero:Period()") == "night"
    c.slash("/dz azeromon sky rain")
    assert c.eval("return ns.Azero.forceRain") is True
    c.slash("/dz azeromon sky auto")
    assert c.eval("return ns.Azero.clockHour") is None and c.eval("return ns.Azero.forceRain") is None
    no_errors(w)


if __name__ == "__main__":
    run_all()
