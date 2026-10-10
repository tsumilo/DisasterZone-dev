if DisasterZoneBoot and DisasterZoneBoot.Run("Core/MeterDemo.lua", ...) then return end -- DisasterZone: meter demo fights.
-- While demo mode is on (Settings > Demo mode, ns.Demo), the damage and threat meters show this made-up Tempest Keep
-- night instead of my own fights: Solarian, two Al'ar pulls (a wipe at 31% and the kill), two trash packs and the
-- Void Reaver kill, 25 players with every detail (abilities with hits / crits / glancing / misses, targets, timeline,
-- healing with overhealing, damage taken, two deaths with recaps, interrupts, dispels), plus a threat table on Void
-- Reaver. The same night as the approved mockup. In memory only, the same numbers on every build (a fixed seed).
local addonName, ns = ...

local MeterDemo = ns:NewModule("MeterDemo")

local floor, max, min, sin, pi = math.floor, math.max, math.min, math.sin, math.pi
local pairs, ipairs = pairs, ipairs

local cache

local seed = 7
local function Rand()
    seed = (seed * 16807) % 2147483647
    return seed / 2147483647
end
local function Around(x, spread) return x * (1 + (Rand() * 2 - 1) * spread) end

local ME = "Player-4467-0D0D0004"      -- Gina, the demo's "me"
MeterDemo.ME = ME

-- name, class, spec, dps, hps, overheal %, dtps, active %, demo guid suffix
local RAID = {
    { "Victhar", "WARRIOR", "Protection", 742, 0, 0, 1852, 99.4 },
    { "Moonwhisper", "DRUID", "Feral (Bear)", 688, 38, 71, 905, 98.8 },
    { "Tsumil", "WARRIOR", "Fury", 1487, 0, 0, 233, 98.6 },
    { "Gina", "PALADIN", "Retribution", 1190, 0, 0, 214, 97.1 },
    { "Stonebrew", "SHAMAN", "Enhancement", 1188, 0, 0, 262, 96.0 },
    { "Shadowmelder", "ROGUE", "Combat", 1541, 0, 0, 187, 99.1 },
    { "Brakkor", "WARRIOR", "Arms", 1067, 0, 0, 226, 97.4 },
    { "Nightpaw", "DRUID", "Feral (Cat)", 1154, 0, 0, 201, 98.2 },
    { "Thunderhoofx", "SHAMAN", "Restoration", 0, 1610, 22, 84, 93.6 },
    { "Brightmend", "PALADIN", "Holy", 0, 1180, 35, 71, 91.2 },
    { "Quentrell", "HUNTER", "Beast Mastery", 1712, 0, 0, 76, 98.9 },
    { "Sylvaris", "HUNTER", "Marksmanship", 1402, 0, 0, 92, 98.4 },
    { "Darkstalkerr", "PRIEST", "Shadow", 904, 212, 64, 110, 97.7 },
    { "Lunessa", "DRUID", "Balance", 958, 0, 0, 88, 96.5 },
    { "Mendwell", "SHAMAN", "Restoration", 0, 1350, 19, 96, 92.8 },
    { "Dreadhex", "WARLOCK", "Destruction", 1655, 0, 0, 145, 98.7 },
    { "Vexmora", "WARLOCK", "Affliction", 1366, 0, 0, 104, 99.0 },
    { "Kaelthrin", "MAGE", "Fire", 1598, 0, 0, 121, 97.9 },
    { "Mirelle", "MAGE", "Fire", 1131, 0, 0, 98, 96.8 },
    { "Pugsyhealer", "PRIEST", "Holy", 0, 1420, 28, 112, 94.1 },
    { "Yubell", "MAGE", "Frost", 986, 0, 0, 340, 59.6 },
    { "Stormcall", "SHAMAN", "Elemental", 1239, 0, 0, 79, 97.2 },
    { "Treeleaf", "DRUID", "Restoration", 0, 1290, 41, 66, 95.4 },
    { "Aurelith", "PALADIN", "Holy", 0, 1050, 31, 70, 90.3 },
    { "Ashgrim", "WARLOCK", "Destruction", 1219, 0, 0, 131, 98.1 },
}

-- Damage by spec: { key (spell id; 0 melee; "p.." a pet's), share, average hit, crit %, glancing % }
local DMG = {
    Protection = { { 30356, .34, 1290, 18 }, { 30022, .27, 520, 17 }, { 30324, .21, 1110, 19 }, { 0, .18, 610, 12, 24 } },
    ["Feral (Bear)"] = { { 26996, .36, 1180, 22 }, { 33987, .27, 980, 24 }, { 33745, .21, 260, 19 }, { 26997, .16, 410, 20 } },
    Fury = { { 30335, .31, 1620, 31 }, { 0, .29, 980, 30, 24 }, { 1680, .2, 1490, 29 }, { 30324, .2, 1760, 32 } },
    Arms = { { 30330, .33, 2120, 29 }, { 0, .31, 1640, 26, 24 }, { 1680, .2, 1880, 27 }, { 25242, .16, 1910, 28 } },
    Retribution = { { 0, .315, 1021, 20.3, 24.3, 1 }, { 20424, .221, 1488, 26.9 }, { 31893, .14, 642, 21.4 },
                    { 35395, .132, 806, 30.1 }, { 20467, .079, 822, 33.0 }, { 25584, .063, 1032, 21.4 },
                    { 27173, .029, 162, 0 }, { 31898, .021, 701, 28.6 } },
    ["Beast Mastery"] = { { 75, .34, 1170, 31 }, { 34120, .28, 1290, 32 }, { "p0", .24, 410, 22, 0, 0, "Wolf" },
                          { "p34027", .14, 760, 24, 0, 0, "Wolf" } },
    Marksmanship = { { 34120, .38, 1380, 33 }, { 75, .36, 1250, 33 }, { 27019, .16, 1510, 34 }, { "p0", .1, 340, 18, 0, 0, "Cat" } },
    Combat = { { 0, .41, 640, 33, 24 }, { 26862, .27, 1240, 36 }, { 26890, .18, 380, 21 }, { 26867, .14, 610, 0 } },
    Shadow = { { 25387, .41, 590, 0 }, { 25368, .27, 520, 0 }, { 25375, .22, 1720, 15 }, { "p0", .1, 640, 0, 0, 0, "Shadowfiend" } },
    Elemental = { { 25449, .64, 1860, 29 }, { 25442, .22, 1690, 28 }, { 25464, .14, 1050, 26 } },
    Enhancement = { { 0, .38, 820, 27, 24 }, { 25584, .27, 860, 28 }, { 32175, .2, 1520, 30 }, { 25454, .15, 1290, 24 } },
    Fire = { { 27070, .63, 2380, 32 }, { 12654, .2, 690, 0 }, { 27074, .11, 1060, 33 }, { 27079, .06, 1310, 35 } },
    Frost = { { 27072, .82, 1890, 29 }, { 30455, .1, 610, 30 }, { 27070, .08, 1710, 22 } },
    Destruction = { { 27209, .74, 2310, 24 }, { 27215, .14, 1220, 18 }, { 27216, .08, 420, 0 }, { "p27267", .04, 210, 9, 0, 0, "Imp" } },
    Affliction = { { 27209, .38, 2010, 19 }, { 27216, .24, 690, 0 }, { 30405, .2, 760, 0 }, { 30911, .18, 310, 0 } },
    Balance = { { 26986, .68, 2240, 27 }, { 26988, .22, 860, 24 }, { 26985, .1, 980, 26 } },
    ["Feral (Cat)"] = { { 27002, .37, 1460, 38 }, { 0, .31, 520, 34, 24 }, { 27008, .21, 690, 0 }, { 33983, .11, 1010, 37 } },
}
-- Healing by class:spec: { spell id, share, average heal, crit % }
local HEAL = {
    ["PRIEST:Holy"] = { { 34866, .38, 1290, 12 }, { 33110, .27, 1640, 0 }, { 25222, .21, 820, 0 }, { 25213, .14, 3810, 11 } },
    ["SHAMAN:Restoration"] = { { 25423, .71, 1810, 14 }, { 379, .19, 760, 0 }, { 25396, .1, 2920, 13 } },
    ["PALADIN:Holy"] = { { 27137, .58, 1420, 17 }, { 27136, .42, 3390, 18 } },
    ["DRUID:Restoration"] = { { 33778, .44, 640, 0 }, { 26982, .33, 520, 0 }, { 26980, .23, 1460, 9 } },
    ["PRIEST:Shadow"] = { { 15290, 1, 70, 0 } },
    ["DRUID:Feral (Bear)"] = { { 34299, 1, 180, 0 } },
}
local MELEE_SPECS = { Protection = true, ["Feral (Bear)"] = true, Fury = true, Arms = true, Retribution = true,
    Enhancement = true, Combat = true, ["Feral (Cat)"] = true }

-- The night: oldest first. boss: the creature taking the damage; f: how hard the raid hit (x the base dps)
local FIGHTS = {
    { kind = "boss", name = "High Astromancer Solarian", enc = 732, ago = 3900, dur = 238, kill = true, f = 1.02,
      foes = { { "High Astromancer Solarian", .82 }, { "Solarium Agent", .12 }, { "Solarium Priest", .06 } },
      hit = { 33045, "High Astromancer Solarian" } },
    { kind = "trash", ago = 2700, dur = 52, f = 0.92,
      foes = { { "Phoenix-Hawk Hatchling", .7 }, { "Phoenix-Hawk", .3 } } },
    { kind = "boss", name = "Al'ar", enc = 730, ago = 1980, dur = 245, kill = false, pct = 31, f = 0.97,
      foes = { { "Al'ar", .86 }, { "Ember of Al'ar", .14 } }, hit = { 35383, "Al'ar" } },
    { kind = "boss", name = "Al'ar", enc = 730, ago = 1320, dur = 372, kill = true, f = 1.0,
      foes = { { "Al'ar", .84 }, { "Ember of Al'ar", .16 } }, hit = { 34229, "Al'ar" } },
    { kind = "trash", ago = 900, dur = 41, f = 0.95,
      foes = { { "Crystalcore Devastator", .52 }, { "Tempest-Smith", .2 }, { "Bloodwarder Legionnaire", .16 },
               { "Astromancer", .07 }, { "Star Scryer", .05 } } },
    { kind = "boss", name = "Void Reaver", enc = 731, ago = 0, dur = 222, kill = true, f = 1.0,
      foes = { { "Void Reaver", 1 } }, voidReaver = true },
}

local function Guid(i) return ("Player-4467-0D0D%04X"):format(i) end

local function Spread(total, dur, curve)
    -- a 5 s timeline that adds up to total, wobbling around the mean (curve(t) scales it)
    local n = max(1, math.ceil(dur / 5))
    local w, s = {}, 0
    local v = 1
    for b = 1, n do
        v = v * 0.6 + (0.55 + Rand() * 0.9) * 0.4
        local m = v * (curve and curve((b - 0.5) * 5) or 1)
        if b == 1 then m = m * 0.55 end
        w[b] = m
        s = s + m
    end
    local tl = {}
    for b = 1, n do tl[b] = floor(total * w[b] / s + 0.5) end
    return tl
end

local function DmgSpells(spec, total)
    local sp, pn = {}, nil
    for _, d in ipairs(DMG[spec] or {}) do
        local key, share, avg, crit, glance, miss, pet = d[1], d[2], d[3], d[4] or 0, d[5] or 0, d[6] or 0, d[7]
        local a = floor(total * share + 0.5)
        local critMult = (key == 0 or key == "p0") and 2 or 1.5
        local per = avg * (1 + crit / 100 * (critMult - 1) - glance / 100 * 0.25)
        local n = max(1, floor(a / per + 0.5))
        local c = floor(n * crit / 100 + 0.5)
        local g = floor(n * glance / 100 + 0.5)
        local ca = floor(c * avg * critMult + 0.5)
        local ga = floor(g * avg * 0.75 + 0.5)
        local s = { n = n, c = c, a = a, ca = min(ca, a), mx = floor(avg * critMult * 1.32) }
        if g > 0 then s.g, s.ga = g, min(ga, a - s.ca) end
        if miss > 0 then s.m = { MISS = miss } end
        if (key == 0 or key == "p0") and n > 20 then s.m = s.m or {}; s.m.DODGE = 1 end
        sp[key] = s
        if pet then pn = pn or {}; pn[key] = pet end
    end
    return sp, pn
end

local function HealSpells(key, total, ohPct)
    local hs = {}
    for _, d in ipairs(HEAL[key] or {}) do
        local id, share, avg, crit = d[1], d[2], d[3], d[4]
        local a = floor(total * share + 0.5)
        local n = max(1, floor(a / avg + 0.5))
        hs[id] = { n = n, c = floor(n * crit / 100 + 0.5), a = a, oh = floor(a * ohPct / (100 - ohPct) + 0.5),
                   mx = floor(avg * 1.9) }
    end
    return hs
end

local function Taken(spec, isTank, total, fight)
    local ts = {}
    local boss = fight.foes[1][1]
    if fight.voidReaver then
        if isTank then
            ts["mVoid Reaver"] = { n = 120, a = floor(total * .71), src = "Void Reaver" }
            ts[34162] = { n = 17, a = floor(total * .19), src = "Void Reaver" }
            ts[25778] = { n = 11, a = floor(total * .1), src = "Void Reaver" }
        elseif MELEE_SPECS[spec] then
            ts[34162] = { n = 17, a = floor(total * .88), src = "Void Reaver" }
            ts[34172] = { n = 1, a = floor(total * .12), src = "Void Reaver" }
        else
            ts[34172] = { n = 6, a = floor(total * .93), src = "Void Reaver" }
            ts[34162] = { n = 1, a = floor(total * .07), src = "Void Reaver" }
        end
    else
        local hit = fight.hit
        if isTank or not hit then
            ts["m" .. boss] = { n = 90, a = floor(total * (hit and .8 or 1)), src = boss }
            if hit then ts[hit[1]] = { n = 9, a = floor(total * .2), src = hit[2] } end
        else
            ts[hit[1]] = { n = 8, a = total, src = hit[2] }
        end
    end
    return ts
end

-- Death recaps on Void Reaver (the mockup's): Yubell to four Arcane Orbs, Stonebrew to Pounding
local RECAPS = {
    Yubell = { t = 134, by = 34172, src = "Void Reaver", hpMax = 8620, ev = {
        { -9.6, "d", 34172, 2934, "Void Reaver" }, { -8.4, "h", 25423, 1903, "Thunderhoofx" },
        { -6.1, "d", 34172, 3048, "Void Reaver" }, { -5.2, "h", 26982, 412, "Treeleaf" },
        { -3.0, "d", 34172, 3117, "Void Reaver" }, { -2.1, "h", 26982, 412, "Treeleaf" },
        { 0, "d", 34172, 2971, "Void Reaver", 723 } } },
    Stonebrew = { t = 185, by = 34162, src = "Void Reaver", hpMax = 11240, ev = {
        { -9.1, "d", 34162, 1622, "Void Reaver" }, { -7.8, "h", 25423, 1544, "Mendwell" },
        { -6.0, "d", 34162, 1688, "Void Reaver" }, { -5.5, "d", 34172, 3360, "Void Reaver" },
        { -3.1, "d", 34162, 1702, "Void Reaver" }, { -2.4, "h", 27137, 1310, "Aurelith" },
        { -1.2, "d", 34162, 1655, "Void Reaver" }, { 0, "d", 34162, 1694, "Void Reaver", 412 } } },
}

local function Recap(def)
    local hp = def.hpMax
    local ev = {}
    for _, e in ipairs(def.ev) do
        if e[2] == "d" then hp = max(0, hp - e[4]) else hp = min(def.hpMax, hp + e[4]) end
        ev[#ev + 1] = { e[1], e[2], e[3], e[4], e[5], hp, e[6] }
    end
    return ev
end

-- Interrupts and dispels (on the trash): name -> { spell id, n, what was cut / removed }
local KICKS = { Shadowmelder = { 38768, 14, 33134 }, Tsumil = { 6554, 9, 37032 }, Kaelthrin = { 2139, 7, 33134 },
    Stonebrew = { 25454, 6, 37032 }, Brakkor = { 6554, 5, 33134 }, Victhar = { 29704, 4, 37032 },
    Mirelle = { 2139, 3, 33134 }, Stormcall = { 25454, 2, 37032 } }
local DISPELS = { Brightmend = { 4987, 31, 37135 }, Pugsyhealer = { 988, 22, 37135 }, Aurelith = { 4987, 17, 37135 },
    Treeleaf = { 2782, 12, 34322 }, Thunderhoofx = { 526, 9, 37027 }, Mendwell = { 8012, 6, 37029 },
    Darkstalkerr = { 988, 4, 37135 } }

local function Build()
    seed = 7
    local now = (GetServerTime and GetServerTime()) or time()
    local base = now - 120
    local segs = {}
    for fi, F in ipairs(FIGHTS) do
        local seg = { id = fi, kind = F.kind, name = F.name, enc = F.enc, kill = F.kill, pct = F.pct,
                      at = base - F.ago - F.dur, zone = "Tempest Keep", iid = 550, itype = "raid", dur = F.dur,
                      actors = {}, foes = {}, deaths = {}, size = 25 }
        local isTrash = F.kind == "trash"
        for i, p in ipairs(RAID) do
            local name, cls, spec, dps, hps, oh, dtps, act = p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8]
            local g = Guid(i)
            local died = F.voidReaver and RECAPS[name]
            local alive = died and died.t or F.dur
            local mult = F.voidReaver and 1 or Around(F.f, 0.07)
            local d = floor(dps * F.dur * mult * (alive / F.dur) + 0.5)
            if F.voidReaver and name == "Gina" then d = floor(dps * F.dur + 0.5) end
            local a = { n = name, c = cls, s = spec, d = d, h = 0, oh = 0, t = 0, k = 0, dp = 0,
                        act = floor(F.dur * act / 100 * (alive / F.dur) * 10 + 0.5) / 10, sp = {}, hs = {}, ts = {},
                        tg = {}, tl = {}, hl = {} }
            if d > 0 then
                a.sp, a.pn = DmgSpells(spec, d)
                for _, foe in ipairs(F.foes) do a.tg[foe[1]] = floor(d * foe[2] + 0.5) end
                local curve
                if F.voidReaver and name == "Gina" then
                    curve = function(t) return (t >= 100 and t < 120) and 1.32 or 1 end   -- Avenging Wrath
                end
                local tl = Spread(d, alive, curve)
                for b, v in ipairs(tl) do a.tl[b] = v end
            end
            if hps > 0 then
                a.h = floor(hps * F.dur * mult + 0.5)
                a.oh = floor(a.h * oh / (100 - oh) + 0.5)
                a.hs = HealSpells(cls .. ":" .. spec, a.h, oh)
                for b, v in ipairs(Spread(a.h, F.dur)) do a.hl[b] = v end
            end
            local isTank = name == "Victhar" or name == "Moonwhisper"
            a.t = floor(dtps * F.dur * (alive / F.dur) * (F.voidReaver and 1 or Around(1, 0.15)) + 0.5)
            a.ts = Taken(spec, isTank, a.t, F)
            if isTrash then
                local kk, dd = KICKS[name], DISPELS[name]
                if kk then
                    local n = fi == 2 and floor(kk[2] / 2) or kk[2] - floor(kk[2] / 2)
                    if n > 0 then a.k, a.ks, a.kx = n, { [kk[1]] = n }, { [kk[3]] = n } end
                end
                if dd then
                    local n = fi == 2 and floor(dd[2] / 2) or dd[2] - floor(dd[2] / 2)
                    if n > 0 then a.dp, a.ds, a.dx = n, { [dd[1]] = n }, { [dd[3]] = n } end
                end
            end
            seg.actors[g] = a
            for foe, v in pairs(a.tg) do seg.foes[foe] = (seg.foes[foe] or 0) + v end
            if died then
                seg.deaths[#seg.deaths + 1] = { t = died.t, g = g, n = name, c = cls, by = died.by, src = died.src,
                    hpMax = died.hpMax, ev = Recap(died) }
            end
        end
        segs[#segs + 1] = seg
    end
    table.sort(segs[#segs].deaths, function(x, y) return x.t < y.t end)

    -- the whole raid: every fight added up
    local all = { id = 0, kind = "all", at = segs[1].at, zone = "Tempest Keep", iid = 550, itype = "raid", dur = 0,
                  actors = {}, foes = {}, deaths = {}, size = 25, noTl = true }
    local function addMap(dst, src) for k, v in pairs(src or {}) do dst[k] = (dst[k] or 0) + v end end
    local function addStats(dst, src)
        for k, s in pairs(src or {}) do
            local o = dst[k]
            if not o then o = {}; dst[k] = o end
            for f, v in pairs(s) do
                if type(v) == "number" then
                    if f == "mx" then o.mx = max(o.mx or 0, v) else o[f] = (o[f] or 0) + v end
                elseif type(v) == "table" then
                    o[f] = o[f] or {}
                    addMap(o[f], v)
                else
                    o[f] = v
                end
            end
        end
    end
    for _, seg in ipairs(segs) do
        for g, a in pairs(seg.actors) do
            local o = all.actors[g]
            if not o then
                o = { n = a.n, c = a.c, s = a.s, d = 0, h = 0, oh = 0, t = 0, k = 0, dp = 0, act = 0, sp = {}, hs = {},
                      ts = {}, tg = {}, tl = {}, hl = {} }
                all.actors[g] = o
            end
            for _, f in ipairs({ "d", "h", "oh", "t", "k", "dp", "act" }) do o[f] = o[f] + (a[f] or 0) end
            addStats(o.sp, a.sp); addStats(o.hs, a.hs); addStats(o.ts, a.ts)
            addMap(o.tg, a.tg)
            if a.pn then o.pn = o.pn or {}; for k, v in pairs(a.pn) do o.pn[k] = v end end
            for _, f in ipairs({ "ks", "kx", "ds", "dx" }) do
                if a[f] then o[f] = o[f] or {}; addMap(o[f], a[f]) end
            end
        end
        addMap(all.foes, seg.foes)
        for _, d in ipairs(seg.deaths) do
            local c = {}
            for k, v in pairs(d) do c[k] = v end
            c.t = all.dur + d.t
            all.deaths[#all.deaths + 1] = c
        end
        all.dur = all.dur + seg.dur
    end
    return { v = 1, segs = segs, all = all, specs = {}, me = ME }
end

function MeterDemo:Data()
    if not cache then cache = Build() end
    return cache
end

-- The demo's threat table on Void Reaver, 70 s into the pull (Gina at 68% of the tank).
local THREAT = { { "Victhar", 100, true }, { "Moonwhisper", 74 }, { "Gina", 68 }, { "Tsumil", 66 }, { "Quentrell", 66 },
    { "Dreadhex", 65 }, { "Kaelthrin", 56 }, { "Sylvaris", 51 }, { "Vexmora", 49 }, { "Shadowmelder", 45 },
    { "Stormcall", 44 } }
local MELEE = { Victhar = true, Moonwhisper = true, Gina = true, Tsumil = true, Shadowmelder = true }

function MeterDemo:Threat()
    local byName = {}
    for i, p in ipairs(RAID) do byName[p[1]] = { i = i, cls = p[2] } end
    local st = { mob = "target", name = "Void Reaver", combat = true, rows = {}, demo = true }
    local tank = 1650 * 70
    for _, t in ipairs(THREAT) do
        local p = byName[t[1]]
        local pullAt = MELEE[t[1]] and 110 or 130
        local row = { unit = "raid" .. p.i, guid = Guid(p.i), name = t[1], cls = p.cls, tank = t[3] or false,
                      raw = t[2], scaled = t[3] and 100 or floor(t[2] / pullAt * 1000 + 0.5) / 10,
                      value = floor(tank * t[2] / 100), me = (Guid(p.i) == ME) or nil }
        st.rows[#st.rows + 1] = row
        if row.me then st.me = row end
    end
    if ns.Threat then ns.Threat:Derive(st) end
    return st
end

function MeterDemo:Reset() cache = nil end
