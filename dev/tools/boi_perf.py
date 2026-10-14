"""The Binding of Illidan's frame cost in the harness: per scenario (a room fight, each boss), 600 frames (10 s of
game time) of E.Step + the panel's Draw, timed apart, the garbage each makes (GC stopped while measuring) and the
textures drawn. The mock's widget calls make garbage the client's C calls don't (128-224 B each: printed first), so
they are swapped for no-ops while measuring; what is left is the game's own. Timings are the harness's Lua, a rough
guide only (+-30 % run to run); the game's Performance page (/dz perf, Measure) is the real measure.
Run (from dev): luaenv\Scripts\python.exe tools\boi_perf.py          the table
                luaenv\Scripts\python.exe tools\boi_perf.py lines    garbage by source line (60 frames)"""
import os
import sys
import time

DEV = os.getcwd()
sys.path.insert(0, os.path.join(DEV, "tools"))
sys.path.insert(0, os.path.join(DEV, "tools", "wowmock"))
import ui_audit  # noqa: E402,F401  (sets up paths)
import harness  # noqa: E402
harness.LOAD_ROOMS = False
from ui_audit_states import build_world, opened, BOI_AUD  # noqa: E402

MEASURE = r"""
local E, UI = ns.BoI, ns.BoIUI
local r = UI._Run()
local frames = 600
local clock = ...
local function textures()
  local n = 0
  for _, p in pairs(UI._Pools()) do n = n + (p.n or 0) end
  return n
end
-- warm up (pools filled, first textures created)
for i = 1, 60 do E.Step(r, { shoot = 'up', mx = (i % 120 < 60) and 0.6 or -0.6 }) UI._Draw() end
-- the mock's widget calls make garbage the client's C calls don't: swap them for no-ops while measuring
local NOOP = function() end
local probe = { UI._Pools().floorGlow.items[1] or CreateFrame('Frame'):CreateTexture() }
local swapped = {}
do
  local seen = {}
  local function swap(obj)
    local st = __MOCK and __MOCK.OBJ[obj]
    local idx = st and st.methods
    if type(idx) ~= 'table' or seen[idx] then return end
    seen[idx] = true
    for _, k in ipairs({ 'SetVertexColor', 'ClearAllPoints', 'SetPoint', 'SetSize', 'SetTexCoord', 'Show', 'Hide',
        'SetColorTexture', 'SetTexture', 'SetAlpha', 'SetText', 'SetTextColor', 'SetFont', 'SetStartPoint', 'SetEndPoint',
        'SetThickness', 'SetShown', 'SetScale', 'SetBlendMode', 'SetWidth', 'SetHeight', 'SetDesaturated', 'SetJustifyH',
        'SetGradient', 'SetDrawLayer', 'SetFrameLevel', 'SetAllPoints', 'SetRotation' }) do
      if rawget(idx, k) then swapped[#swapped + 1] = { idx, k, rawget(idx, k) } rawset(idx, k, NOOP) end
    end
  end
  for _, p in pairs(UI._Pools()) do for _, it in ipairs(p.items) do
    if type(it) == 'table' and it.Show and getmetatable(it) then swap(it) end
    if type(it) == 'table' and it.pic then for _, v in pairs(it) do if type(v) == 'table' and getmetatable(v) then swap(v) end end end
  end end
  for _, fs in pairs(UI._Hud()) do if type(fs) == 'table' and getmetatable(fs) then swap(fs) end end
end
collectgarbage('collect') collectgarbage('stop')
local tStep, tDraw, gStep, gDraw, texMax, texSum = 0, 0, 0, 0, 0, 0
for i = 1, frames do
  local g0, c0 = collectgarbage('count'), clock()
  E.Step(r, { shoot = (i % 40 < 20) and 'up' or 'left', mx = (i % 120 < 60) and 0.6 or -0.6, my = (i % 90 < 45) and 0.4 or -0.4 })
  local c1, g1 = clock(), collectgarbage('count')
  UI._Draw()
  local c2, g2 = clock(), collectgarbage('count')
  tStep, tDraw = tStep + (c1 - c0), tDraw + (c2 - c1)
  gStep, gDraw = gStep + (g1 - g0), gDraw + (g2 - g1)
  local t = textures() texMax = math.max(texMax, t) texSum = texSum + t
end
collectgarbage('restart')
for _, sw in ipairs(swapped) do rawset(sw[1], sw[2], sw[3]) end
return string.format('%d|%.3f|%.3f|%.2f|%.2f|%d|%d|%d', #swapped, tStep / frames * 1000, tDraw / frames * 1000, gStep / frames, gDraw / frames, texSum / frames, texMax, #(r.room.decals or {}))
"""

SCEN = [
    ("Room fight, floor 1", "BOI_AUD.room(1, 1)"),
    ("Magtheridon", "BOI_AUD.boss(1, 1)"),
    ("Supremus", "BOI_AUD.boss(2, 1)"),
    ("Teron", "BOI_AUD.boss(3, 1)"),
    ("Shahraz", "BOI_AUD.boss(4, 1)"),
    ("Illidan", "BOI_AUD.boss(5, 1, function(f) f.hp = f.max * 0.64 end)"),
]


MOCKCOST = r'''
local f = CreateFrame('Frame', nil, UIParent) local t = f:CreateTexture() local l = f:CreateLine()
local clock = ...
collectgarbage('collect') collectgarbage('stop')
local out = {}
local function m(name, fn) local g0, c0 = collectgarbage('count'), clock() for i = 1, 2000 do fn(i) end
  out[#out + 1] = string.format('%s %.0f B %.2f us', name, (collectgarbage('count') - g0) * 1024 / 2000, (clock() - c0) / 2000 * 1e6) end
m('SetVertexColor', function(i) t:SetVertexColor(1, 0.5, 0.2, 0.8) end)
m('ClearAllPoints+SetPoint', function(i) t:ClearAllPoints() t:SetPoint('CENTER', f, 'TOPLEFT', i, -i) end)
m('SetSize', function(i) t:SetSize(i, i) end)
m('SetTexCoord', function(i) t:SetTexCoord(0, 1, 0, 1) end)
m('Show', function(i) t:Show() end)
m('SetColorTexture', function(i) t:SetColorTexture(1, 1, 1, 1) end)
m('table {r,g,b}', function(i) local x = { 1, 0.5, i } end)
collectgarbage('restart')
return table.concat(out, '; ')
'''


def main():
    w, c = build_world(ui_audit.PRELOAD)
    print(c["Gina"].eval(MOCKCOST, time.perf_counter))
    print(f"{'scenario':22} {'step ms':>8} {'draw ms':>8} {'KB/frame':>9} {'tex avg':>8} {'tex max':>8}")
    for name, lua in SCEN:
        g = opened("games", BOI_AUD + lua)(w, c)
        out = g.eval(MEASURE, time.perf_counter)
        nsw, ts, td, gs, gd, ta, tm, dc = out.split("|")
        print(f"{name:22} {float(ts):8.3f} {float(td):8.3f} {float(gs) + float(gd):9.2f} {ta:>8} {tm:>8}"
              f"   (step {float(gs):.2f} KB, draw {float(gd):.2f} KB, stains {dc}, swapped {nsw})")


LINES = r'''
local E, UI = ns.BoI, ns.BoIUI
local r = UI._Run()
local frames = 60
local clock = ...
local function textures()
  local n = 0
  for _, p in pairs(UI._Pools()) do n = n + (p.n or 0) end
  return n
end
-- warm up (pools filled, first textures created)
for i = 1, 60 do E.Step(r, { shoot = 'up', mx = (i % 120 < 60) and 0.6 or -0.6 }) UI._Draw() end
-- the mock's widget calls make garbage the client's C calls don't: swap them for no-ops while measuring
local NOOP = function() end
local probe = { UI._Pools().floorGlow.items[1] or CreateFrame('Frame'):CreateTexture() }
local swapped = {}
do
  local seen = {}
  local function swap(obj)
    local st = __MOCK and __MOCK.OBJ[obj]
    local idx = st and st.methods
    if type(idx) ~= 'table' or seen[idx] then return end
    seen[idx] = true
    for _, k in ipairs({ 'SetVertexColor', 'ClearAllPoints', 'SetPoint', 'SetSize', 'SetTexCoord', 'Show', 'Hide',
        'SetColorTexture', 'SetTexture', 'SetAlpha', 'SetText', 'SetTextColor', 'SetFont', 'SetStartPoint', 'SetEndPoint',
        'SetThickness', 'SetShown', 'SetScale', 'SetBlendMode', 'SetWidth', 'SetHeight', 'SetDesaturated', 'SetJustifyH',
        'SetGradient', 'SetDrawLayer', 'SetFrameLevel', 'SetAllPoints', 'SetRotation' }) do
      if rawget(idx, k) then swapped[#swapped + 1] = { idx, k, rawget(idx, k) } rawset(idx, k, NOOP) end
    end
  end
  for _, p in pairs(UI._Pools()) do for _, it in ipairs(p.items) do
    if type(it) == 'table' and it.Show and getmetatable(it) then swap(it) end
    if type(it) == 'table' and it.pic then for _, v in pairs(it) do if type(v) == 'table' and getmetatable(v) then swap(v) end end end
  end end
  for _, fs in pairs(UI._Hud()) do if type(fs) == 'table' and getmetatable(fs) then swap(fs) end end
end
collectgarbage('collect') collectgarbage('stop')
local acc, lastKey, lastG = {}, nil, 0
local function hook(ev, line)
  local g = collectgarbage('count')
  if lastKey then acc[lastKey] = (acc[lastKey] or 0) + (g - lastG) end
  local info = debug.getinfo(2, 'S')
  lastKey = info.short_src:match('[^/' .. string.char(92) .. ']+$') .. ':' .. line
  lastG = collectgarbage('count')
end
debug.sethook(hook, 'l')
local tStep, tDraw, gStep, gDraw, texMax, texSum = 0, 0, 0, 0, 0, 0
for i = 1, frames do
  local g0, c0 = collectgarbage('count'), clock()
  E.Step(r, { shoot = (i % 40 < 20) and 'up' or 'left', mx = (i % 120 < 60) and 0.6 or -0.6, my = (i % 90 < 45) and 0.4 or -0.4 })
  local c1, g1 = clock(), collectgarbage('count')
  UI._Draw()
  local c2, g2 = clock(), collectgarbage('count')
  tStep, tDraw = tStep + (c1 - c0), tDraw + (c2 - c1)
  gStep, gDraw = gStep + (g1 - g0), gDraw + (g2 - g1)
  local t = textures() texMax = math.max(texMax, t) texSum = texSum + t
end
debug.sethook()
local top = {}
for k, v in pairs(acc) do if v > 0.05 and not k:match('^objects') and not k:match('^mock') then top[#top + 1] = { k, v } end end
table.sort(top, function(a, b) return a[2] > b[2] end)
local o = {}
for i = 1, math.min(25, #top) do o[#o + 1] = string.format('%7.2f KB/frame  %s', top[i][2] / frames, top[i][1]) end
collectgarbage('restart')
for _, sw in ipairs(swapped) do rawset(sw[1], sw[2], sw[3]) end
do return table.concat(o, string.char(10)) end
for _, sw in ipairs(swapped) do rawset(sw[1], sw[2], sw[3]) end
return string.format('%d|%.3f|%.3f|%.2f|%.2f|%d|%d|%d', #swapped, tStep / frames * 1000, tDraw / frames * 1000, gStep / frames, gDraw / frames, texSum / frames, texMax, #(r.room.decals or {}))
'''

def lines():
    w, c = build_world(ui_audit.PRELOAD)
    for name, lua in (SCEN[0], SCEN[5]):
        g = opened("games", BOI_AUD + lua)(w, c)
        print("==", name)
        print(g.eval(LINES, time.perf_counter))


if len(sys.argv) > 1 and sys.argv[1] == "lines":
    lines()
else:
    main()
