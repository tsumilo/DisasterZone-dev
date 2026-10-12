if DisasterZoneBoot and DisasterZoneBoot.Run("Core/MyLogDemo.lua", ...) then return end -- DisasterZone: My Log demo pulls.
-- While demo mode is on (Settings > Demo mode, ns.Demo), MyLog:GetPulls returns these made-up pulls instead of my
-- own: six weeks of Serpentshrine Cavern for a Destruction warlock getting better week by week, a Tempest Keep night
-- and tonight's run with Lady Vashj wipes, every pull with full detail (abilities, timeline, gaps, uptime, deaths).
-- In memory only: never saved, never mixed into the real log. Same numbers on every build (a fixed seed).
local addonName, ns = ...

local MyLogDemo = ns:NewModule("MyLogDemo")
local Util = ns.Util

local floor, max, min, sin = math.floor, math.max, math.min, math.sin

local cache

-- A small deterministic generator (Park-Miller, Util.NewRng), so the demo looks the same every time. (NewRng(n)
-- starts at n + 1: the seeds below are one less than the numbers the demo was drawn from.)
local rng = Util.NewRng(0)
local function Rand() return rng.Next() end
local function Around(x, spread) return x * (1 + (Rand() * 2 - 1) * spread) end

local NAMES = {
    ["0"] = "Melee", ["27209"] = "Shadow Bolt", ["27215"] = "Immolate", ["27216"] = "Corruption",
    ["27218"] = "Curse of Agony", ["27228"] = "Curse of the Elements", ["27222"] = "Life Tap",
    ["p27267"] = "Firebolt (Imp)", ["17628"] = "Flask of Pure Death", ["33263"] = "Well Fed",
    ["2825"] = "Bloodlust", ["25898"] = "Greater Blessing of Kings", ["28508"] = "Destruction Potion",
    ["38235"] = "Water Tomb", ["37433"] = "Spout", ["37478"] = "Geyser", ["37640"] = "Whirlwind",
    ["37675"] = "Chaos Blast", ["38441"] = "Cataclysmic Bolt", ["37730"] = "Tidal Wave", ["38575"] = "Toxic Spores",
    ["38253"] = "Poison Bolt", ["35383"] = "Flame Patch", ["34229"] = "Flame Quills", ["33076"] = "Prayer of Mending",
    ["25235"] = "Flash Heal", ["38112"] = "Magic Barrier", ["35181"] = "Dive Bomb",
    -- what else kills me in the demo (ids checked on Wowhead, TBC)
    ["38246"] = "Vile Sludge", ["37660"] = "Whirl", ["37676"] = "Insidious Whisper", ["38234"] = "Frost Shock",
    ["38374"] = "Hurl Trident", ["38358"] = "Tidal Surge", ["37764"] = "Earthquake", ["38049"] = "Watery Grave",
    ["38280"] = "Static Charge", ["38509"] = "Shock Blast", ["38145"] = "Forked Lightning", ["38310"] = "Multi-Shot",
    ["34341"] = "Ember Blast", ["34121"] = "Flame Buffet",
}

-- What kills me per boss (encounter id): { spell key, source, weight }. Many causes on purpose, so the Deaths page
-- shows how it copes with a long list.
local KILLERS = {
    [623] = { { "38235", "Hydross the Unstable", 1 }, { "38246", "Tainted Spawn of Hydross", 1 } },
    [624] = { { "37433", "The Lurker Below", 1 }, { "37478", "The Lurker Below", 1 }, { "37660", "The Lurker Below", 1 } },
    [625] = { { "37640", "Leotheras the Blind", 3 }, { "37675", "Leotheras the Blind", 1 }, { "37676", "Inner Demon", 1 } },
    [626] = { { "38441", "Fathom-Lord Karathress", 1 }, { "38234", "Fathom-Guard Tidalvess", 1 },
              { "38374", "Fathom-Guard Sharkkis", 1 }, { "38358", "Fathom-Guard Caribdis", 1 } },
    [627] = { { "37730", "Morogrim Tidewalker", 1 }, { "37764", "Morogrim Tidewalker", 1 }, { "38049", "Morogrim Tidewalker", 1 },
              { "0", "Tidewalker Lurker", 1 } },
    [628] = { { "38575", "Lady Vashj", 2 }, { "38253", "Tainted Elemental", 1 }, { "38280", "Lady Vashj", 1 },
              { "38509", "Lady Vashj", 1 }, { "38145", "Lady Vashj", 1 }, { "38310", "Lady Vashj", 1 }, { "0", "Coilfang Strider", 1 } },
    [730] = { { "35383", "Al'ar", 1 }, { "34229", "Al'ar", 1 }, { "35181", "Al'ar", 1 }, { "34341", "Ember of Al'ar", 1 },
              { "34121", "Al'ar", 1 } },
}

-- The extra deaths draw from their own generator, so the rest of the demo stays the same number for number.
local drng = Util.NewRng(0)
local function DRand() return drng.Next() end

local HP = 9200
local HEALS = { { "33076", "Holyvee" }, { "25235", "Brightpaw" } }

-- A boss's killer, by weight; nil when it has none.
local function PickKiller(enc)
    local list = KILLERS[enc]
    if not list then return nil end
    local sum = 0
    for _, k in ipairs(list) do sum = sum + k[3] end
    local r = DRand() * sum
    for _, k in ipairs(list) do
        r = r - k[3]
        if r <= 0 then return k end
    end
    return list[#list]
end

-- The last 10 seconds before a death by killer k on boss b: the boss's usual hits, a heal or two, my casts, then
-- the killer's hit(s); the amounts are fitted so I stay alive until the last line and that one kills.
local function MakeDeath(b, k, at)
    local ev = {}
    local function add(t, kind, key, amount, who) ev[#ev + 1] = { floor(t * 10 + 0.5) / 10, kind, key, amount, who } end
    local hits = b.hits or {}
    local t = -9.6 + DRand() * 1.2
    local hurt = false                                -- (no heals at full health: they would heal nothing)
    while t < -2.5 do
        local r = DRand()
        if r < 0.3 or (r < 0.5 and not hurt) then
            add(t, "c", DRand() < 0.8 and "27209" or "27222")
        elseif r < 0.5 then
            local h = HEALS[1 + floor(DRand() * #HEALS)]
            add(t, "h", h[1], floor(900 + DRand() * 1400), h[2])
        elseif k[1] == "0" or #hits == 0 then
            add(t, "d", "0", floor(700 + DRand() * 900), k[2])
            hurt = true
        else
            local h = hits[1 + floor(DRand() * #hits)]
            add(t, "d", tostring(h[1]), floor(h[3] * (0.7 + DRand() * 0.6)), h[2])
            hurt = true
        end
        t = t + 0.8 + DRand() * 1.4
    end
    local before = 0
    for _, e in ipairs(ev) do if e[2] == "d" then before = before + 1 end end
    -- (amounts fitted below; two killer hits when few hits came before, so no single hit is absurdly big)
    if before < 3 or DRand() < 0.6 then add(-1.2 + DRand() * 0.8, "d", k[1], 0, k[2]) end
    add(0, "d", k[1], 0, k[2])
    -- fit: the hits before the killer's take me down to 25-45 % (with the heals in between); then the killer's
    -- hits take the rest, the last one killing
    local target = floor(HP * (0.25 + DRand() * 0.2))
    local heal, weight, pre = 0, 0, 0
    for _, e in ipairs(ev) do
        if e[2] == "h" then
            e[4] = min(e[4], floor(target * 0.6) - heal)
            heal = heal + max(0, e[4])
        elseif e[2] == "d" and e[4] > 0 then
            weight, pre = weight + e[4], pre + 1
        end
    end
    if pre == 0 then                                  -- (always at least one hit before the killer's)
        table.insert(ev, 1, { -9.4, "d", k[1] == "0" and "0" or tostring((b.hits[1] or { 0 })[1]), 1000,
            k[1] == "0" and k[2] or (b.hits[1] or { 0, k[2] })[2] })
        weight = 1000
    end
    local need = HP + heal - target
    local hp = HP
    for i, e in ipairs(ev) do
        if e[2] == "h" then
            if e[4] <= 0 then e[2] = "c"; e[3] = "27209"; e[4] = nil else hp = min(HP, hp + e[4]) end
        elseif e[2] == "d" then
            if e[4] == 0 then
                if i == #ev then e[4] = hp + floor(DRand() * 600)
                else e[4] = max(1, floor(hp * (0.45 + DRand() * 0.25))) end
            else
                e[4] = max(1, min(floor(need * e[4] / weight), hp - 400, floor(2500 + DRand() * 1200)))
            end
            hp = hp - e[4]
        end
    end
    return { t = at, by = k[1], events = ev }
end


-- Per boss: encounter id, kill time (s), the hits that land on me (spell id, source, average, per minute,
-- avoidable) and the moments my damage drops (start, length in s), like Leotheras' whirlwinds.
local BOSSES = {
    { enc = 623, boss = "Hydross the Unstable", dur = 290,
      hits = { { 38235, "Hydross the Unstable", 1650, 0.6 } } },
    { enc = 624, boss = "The Lurker Below", dur = 250,
      hits = { { 37433, "The Lurker Below", 3800, 0.15, true }, { 37478, "The Lurker Below", 1900, 0.5 } } },
    { enc = 625, boss = "Leotheras the Blind", dur = 300,
      hits = { { 37640, "Leotheras the Blind", 2400, 0.4, true }, { 37675, "Leotheras the Blind", 1400, 0.5 } },
      dips = { { 60, 15 }, { 150, 15 }, { 240, 15 } }, mech = 37640,
      yell = "I am the master! Do you hear me? I am the master!", adds = { 21875, "Shadow of Leotheras", 90 } },
    { enc = 626, boss = "Fathom-Lord Karathress", dur = 260,
      hits = { { 38441, "Fathom-Lord Karathress", 5200, 0.12 } } },
    { enc = 627, boss = "Morogrim Tidewalker", dur = 280,
      hits = { { 37730, "Morogrim Tidewalker", 2600, 0.3 } } },
    { enc = 628, boss = "Lady Vashj", dur = 560,
      hits = { { 38575, "Lady Vashj", 2900, 0.35, true }, { 38253, "Tainted Elemental", 1200, 0.6 } },
      dips = { { 150, 40 }, { 330, 40 } }, mech = 38112,
      yell = "The time is now! Leave none standing!", adds = { 22009, "Tainted Elemental", 55 } },
}
local ALAR = { enc = 730, boss = "Al'ar", dur = 330, hits = { { 35383, "Al'ar", 1700, 0.5, true },
    { 34229, "Al'ar", 2200, 0.2 } }, dips = { { 120, 20 } }, mech = 35181 }

local function NewPull(at, b, zone, iid, kill, dps, skill, opts)
    opts = opts or {}
    local dur = kill and floor(Around(b.dur / (0.9 + skill * 0.12), 0.04)) or (opts.wipeAt or floor(b.dur * 0.6))
    local p = {
        at = at, enc = b.enc, boss = b.boss, zone = zone, iid = iid, diff = 4, size = 25, kill = kill, dur = dur,
        cls = "WARLOCK", spec = "Destruction", role = "caster", tal = "0/21/40", ilvl = opts.ilvl,
        buffs = { 17628, 33263, 25898 }, pct = (not kill) and opts.pct or nil,
        dmg = {}, pet = {}, heal = {}, shield = {}, taken = {}, names = {}, avoid = {}, healIn = {},
        casts = {}, kicks = {}, disp = {}, gain = {}, up = { me = {}, out = {} }, tgt = {},
        tl = { d = {}, h = {}, t = {}, p = {} }, gaps = {}, deaths = {}, mech = {}, bev = {}, ct = {},
    }
    for k, v in pairs(NAMES) do p.names[k] = v end
    -- timeline: damage per 5 s, dips where the boss forces me off it, a slow start
    local buckets = floor(dur / 5) + 1
    local total = 0
    for i = 1, buckets do
        local t = (i - 1) * 5
        local f = min(1, 0.55 + t / 25) * (1 + 0.12 * sin(i * 0.7))
        for _, dip in ipairs(b.dips or {}) do
            if t >= dip[1] and t < dip[1] + dip[2] then f = f * (0.25 + skill * 0.35) end
        end
        local v = floor(Around(dps * min(5, dur - t) * f, 0.08))        -- (the last bucket is only part filled)
        p.tl.d[i] = v
        total = total + v
        p.tl.p[i] = max(5, floor(100 - (t / dur) * 70 + 20 * sin(i * 0.4)))
    end
    -- abilities sum up to the timeline total
    local function hits(key, share, avg, critRate, castsPerHit, ticks)
        local amount = floor(total * share)
        local n = max(1, floor(amount / avg))
        local c = floor(n * critRate)
        local s = { n = n, c = c, a = amount, ca = floor(c * avg * 1.5), mx = floor(avg * 1.62) }
        if key == "27209" then s.r = floor(amount * 0.03); s.m = { RESIST = 2 }; s.ma = floor(avg * 2) end
        p.dmg[key] = s
        if not ticks then p.casts[tonumber(key)] = floor(n * (castsPerHit or 1)) end
    end
    hits("27209", 0.74 + skill * 0.04, 1690, 0.22 + skill * 0.03)
    hits("27215", 0.08, 980, 0.2)
    hits("27216", 0.06 - skill * 0.01, 165, 0, nil, true)
    hits("27218", 0.04, 200, 0, nil, true)
    local pet = floor(total * (0.08 - skill * 0.02))
    p.pet["p27267"] = { n = floor(pet / 190), c = floor(pet / 190 * 0.1), a = pet, mx = 260 }
    p.casts[27216] = floor(dur / 18)
    p.casts[27218] = floor(dur / 24)
    p.casts[27228] = floor(dur / 300) + 1
    p.casts[27222] = floor(Around(dur / 25, 0.2))
    p.tgt[b.enc * 10] = { n = b.boss, a = total }
    -- damage taken
    for _, h in ipairs(b.hits) do
        local id, src, avg, perMin, avoidable = h[1], h[2], h[3], h[4], h[5]
        local rate = avoidable and perMin * (1.2 - skill) or perMin
        local n = max(0, floor(dur / 60 * rate + 0.5))
        if n > 0 then
            local a = floor(n * Around(avg, 0.1))
            p.taken[tostring(id)] = { n = n, c = 0, a = a, mx = floor(avg * 1.3), src = src }
            for i = 1, n do
                local at2 = floor(Rand() * buckets) + 1
                p.tl.t[at2] = (p.tl.t[at2] or 0) + floor(a / n)
            end
        end
    end
    p.healIn = { Holyvee = floor(total * 0.04), Brightpaw = floor(total * 0.025) }
    p.gain[27222] = { n = p.casts[27222], a = p.casts[27222] * 1580, o = floor(Rand() * 900) }
    -- uptime: the flask and Kings all fight, Bloodlust 40 s, my Curse of the Elements on the boss
    p.up.me["17628"] = dur
    p.up.me["25898"] = dur
    p.up.me["2825"] = 40
    p.up.out["27228"] = floor(dur * (0.84 + skill * 0.14))
    -- idle gaps: fewer as the weeks go by
    local gapCount = floor(Around(7 - skill * 5, 0.2) + 0.5)
    local idle = 0
    for i = 1, gapCount do
        local len = floor(Around(2.6 + (1 - skill) * 1.5, 0.3) * 10) / 10
        p.gaps[#p.gaps + 1] = { at = floor((i / (gapCount + 1)) * dur), len = len }
        idle = idle + len
    end
    for _, dip in ipairs(b.dips or {}) do
        local lost = dip[2] * (0.6 - skill * 0.4)
        p.gaps[#p.gaps + 1] = { at = dip[1] + 1, len = floor(lost * 10) / 10 }
        idle = idle + lost
        if b.mech and dip[1] < dur then p.mech[#p.mech + 1] = { dip[1], b.mech } end
    end
    table.sort(p.gaps, function(x, y) return x.at < y.at end)
    p.actSec = max(0, dur - idle - dur * (0.03 - skill * 0.02))
    -- the boss side: its auras over the dips, yells, its casts, adds dying
    for _, dip in ipairs(b.dips or {}) do
        if dip[1] < dur then
            if b.mech then p.bev[#p.bev + 1] = { dip[1], "a", b.mech, min(dip[2], dur - dip[1]) } end
            if b.yell then p.bev[#p.bev + 1] = { dip[1], "y", b.boss, b.yell } end
        end
    end
    for _, h in ipairs(b.hits) do
        if not h[5] and h[2] == b.boss then
            local every = max(8, 60 / h[4])
            local t = every * (0.6 + Rand() * 0.4)
            while t < dur - 3 do
                p.bev[#p.bev + 1] = { floor(t * 10) / 10, "c", h[1] }
                t = t + every * (0.85 + Rand() * 0.3)
            end
        end
    end
    if b.adds then
        local npc, name, every = b.adds[1], b.adds[2], b.adds[3]
        p.names["n" .. npc] = name
        local t = every
        while t < dur - 5 do
            p.bev[#p.bev + 1] = { floor(t * 10) / 10, "d", npc }
            t = t + every * (0.9 + Rand() * 0.2)
        end
    end
    table.sort(p.bev, function(x, y) return x[1] < y[1] end)
    -- my casts in order: Curse of the Elements first, dots kept up, Immolate, Life Tap, Shadow Bolt between;
    -- nothing while idle
    local function idleAt(t)
        for _, g in ipairs(p.gaps) do if t >= g.at and t < g.at + g.len then return g.at + g.len end end
        return nil
    end
    local t, nextCor, nextCoa, nextImm, nextTap = 0.3, 2, 4, 6, 20
    p.ct[1] = { 0, 27228 }
    local counts = { [27228] = 1 }
    local sbLen = 2.5 - skill * 0.25
    while t < dur - 1 and #p.ct < 400 do
        local skip = idleAt(t)
        if skip then
            t = skip
        else
            local id, len
            if t >= nextCor then id, nextCor = 27216, t + 18
            elseif t >= nextCoa then id, nextCoa = 27218, t + 24
            elseif t >= nextImm then id, len, nextImm = 27215, 1.9, t + 12 + Rand() * 4
            elseif t >= nextTap then id, nextTap = 27222, t + 22 + Rand() * 8
            else id, len = 27209, sbLen end
            p.ct[#p.ct + 1] = { floor(t * 10 + 0.5) / 10, id, len }
            counts[id] = (counts[id] or 0) + 1
            t = t + max(len or 1.5, 1.5) + 0.05 + Rand() * (0.3 - skill * 0.2)
        end
    end
    for id, n in pairs(counts) do p.casts[id] = n end
    -- a death: the last 10 seconds before it
    if opts.killer then
        opts.death = MakeDeath(b, opts.killer, kill and floor(dur * (0.2 + DRand() * 0.7)) or max(30, dur - floor(DRand() * 25)))
    end
    if opts.death then
        local d = opts.death
        local hp = HP
        local ring = {}
        for _, e in ipairs(d.events) do
            if e[2] == "d" then hp = max(0, hp - e[4]) elseif e[2] == "h" then hp = min(HP, hp + e[4]) end
            ring[#ring + 1] = { e[1], e[2], e[3], e[4], hp, e[5], e[6] }
        end
        p.deaths[1] = { t = d.t, by = d.by, ring = ring, hpMax = HP }
        p.dead = d.t
        if not kill then p.dur = max(p.dur, d.t + 20) end
        local after = p.dur - d.t
        p.actSec = max(0, p.actSec - after)
    end
    ns.MyLog:Summarize(p)
    return p
end

local VASHJ_DEATH = {
    t = 228.4, by = "38575",
    events = {
        { -9.6, "h", "33076", 1840, "Holyvee" },
        { -7.9, "c", "27209" },
        { -6.2, "d", "38253", 2410, "Tainted Elemental" },
        { -5.4, "c", "27222" },
        { -4.0, "d", "38253", 1980, "Tainted Elemental" },
        { -2.6, "h", "25235", 1200, "Brightpaw", 0 },
        { -2.1, "c", "27209" },
        { -0.8, "d", "38575", 2950, "Lady Vashj" },
        { 0, "d", "38575", 3130, "Lady Vashj" },
    },
}
local LEO_DEATH = {
    t = 152.0, by = "37640",
    events = {
        { -8.8, "c", "27209" },
        { -6.0, "d", "37675", 1450, "Leotheras the Blind" },
        { -4.1, "h", "25235", 2100, "Brightpaw" },
        { -3.0, "c", "27209" },
        { -1.4, "d", "37640", 2600, "Leotheras the Blind" },
        { -0.6, "d", "37640", 2700, "Leotheras the Blind" },
        { 0, "d", "37640", 2550, "Leotheras the Blind" },
    },
}

local function Build()
    rng = Util.NewRng(20261006)
    drng = Util.NewRng(4241)
    local pulls = {}
    local now = Util.Now()
    local day = 86400
    local tonight = now - 2 * 3600
    local id = 0
    -- extra pulls drawn from a seed of their own, so the pulls after them stay the same number for number
    local function aside(fn)
        local keep = rng
        rng = Util.NewRng(floor(DRand() * 2147483000))
        fn()
        rng = keep
    end
    local function add(p)
        id = id + 1
        p.id = id
        pulls[#pulls + 1] = p
    end
    -- six weekly SSC nights before tonight, skill 0 -> 0.75
    for w = 6, 1, -1 do
        local skill = (6 - w) / 8
        local t = tonight - w * 7 * day
        local ilvl = 115 + (6 - w) * 1.6
        for i, b in ipairs(BOSSES) do
            if b.enc ~= 628 then
                local opts = { ilvl = ilvl }
                if b.enc == 625 and w == 4 then
                    opts.death = LEO_DEATH
                elseif DRand() < 0.95 - skill * 0.75 then
                    opts.killer = PickKiller(b.enc)
                end
                if b.enc == 625 and w >= 5 then
                    add(NewPull(t + i * 1500, b, "Serpentshrine Cavern", 548, false, 1000 + skill * 400, skill,
                        { ilvl = ilvl, pct = 31 - w, wipeAt = 170, killer = PickKiller(625) }))
                end
                add(NewPull(t + i * 1500 + 600, b, "Serpentshrine Cavern", 548, true,
                    Around(1020 + skill * 360, 0.03), skill, opts))
            end
        end
        if w == 3 then
            aside(function()                                        -- three wipes on Al'ar before the kill
                for n = 1, 3 do
                    add(NewPull(t + 2 * day + n * 700 - 2800, ALAR, "Tempest Keep", 550, false, 960, skill,
                        { ilvl = ilvl, pct = 70 - n * 15, wipeAt = 150 + n * 30, killer = PickKiller(730) }))
                end
            end)
            add(NewPull(t + 2 * day, ALAR, "Tempest Keep", 550, true, 980, skill, { ilvl = ilvl, killer = PickKiller(730) }))
        end
        if w <= 3 then
            aside(function()                                        -- first tries on Lady Vashj, from week 3 on
                for n = 1, 4 - w do
                    add(NewPull(t + 9000 + n * 800, BOSSES[6], "Serpentshrine Cavern", 548, false, 1050 + skill * 300, skill,
                        { ilvl = ilvl, pct = 92 - (4 - w) * 12 - n * 5, wipeAt = 140 + n * 40, killer = PickKiller(628) }))
                end
            end)
        end
    end
    -- tonight: everything down, then Lady Vashj wipes
    local skill = 0.8
    for i, b in ipairs(BOSSES) do
        if b.enc ~= 628 then
            add(NewPull(tonight + i * 1400, b, "Serpentshrine Cavern", 548, true, Around(1420, 0.03), skill,
                { ilvl = 125.4 }))
        end
    end
    local vashj = BOSSES[6]
    add(NewPull(tonight + 9000, vashj, "Serpentshrine Cavern", 548, false, 1180, skill,
        { ilvl = 125.4, pct = 64.2, wipeAt = 190, death = VASHJ_DEATH }))
    add(NewPull(tonight + 9900, vashj, "Serpentshrine Cavern", 548, false, 1230, skill,
        { ilvl = 125.4, pct = 38.5, wipeAt = 310, killer = KILLERS[628][4] }))     -- Shock Blast
    add(NewPull(tonight + 10800, vashj, "Serpentshrine Cavern", 548, false, 1260, skill,
        { ilvl = 125.4, pct = 17.9, wipeAt = 420, killer = KILLERS[628][3] }))     -- Static Charge
    return pulls
end

function MyLogDemo:IsActive()
    return Util.DemoOn()
end

function MyLogDemo:GetPulls()
    if not cache then cache = Build() end
    return cache
end

function MyLogDemo:OnInit()
    ns:On("DEMO_TOGGLED", function() ns:Fire("MYLOG_CHANGED") end)
end
