if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Hideout.lua", ...) then return end -- DisasterZone Games/Azeromon/Hideout.lua
-- ns.AzeroHideout: the Guild Hall under the Lion's Pride Inn. A plinth for every raid boss: a trophy stands on it
-- once the guild has killed that boss, read from DisasterZone's raid log (Core/RaidLog.lua: every kill with the roster
-- at the kill and, from 0.9.0 on, how long the fight took). A kill is the guild's when more than half of the
-- roster were guildmates. Statues in the Hall of Champions name the guild's record holders (GuildBoard.lua) and
-- the Bestiary board counts what the guild has tamed together. Raid events only: no loot decisions live here.
local addonName, ns = ...

local H = {}
ns.AzeroHideout = H
local G, D, Maps = ns.Azero, ns.AzeroData, ns.AzeroMaps

---------------------------------------------------------------------------
-- The bosses with a plinth: every raid boss with an encounter id (the Opera's three variants share one; the Chess
-- Event is a chest in the loot data but a real encounter the raid log counts)
---------------------------------------------------------------------------

H.RAIDS = {}                  -- { key, name, bosses = { { key, name, enc, raid } } } in raid order
local byEnc = {}

local function Build()
    if #H.RAIDS > 0 then return end
    for _, raid in ipairs(ns.Data and ns.Data.Raids or {}) do
        local r = { key = raid.key, name = raid.name, bosses = {} }
        local seen = {}
        for _, b in ipairs(raid.bosses or {}) do
            local enc = tonumber(b.encounterID)
            if enc and not b.isTrash and not seen[enc] then
                seen[enc] = true
                local e = { key = b.key, name = (enc == 655) and "The Opera Event" or b.name, enc = enc, raid = raid.key,
                            raidName = raid.name }
                r.bosses[#r.bosses + 1] = e
                byEnc[enc] = e
            end
        end
        if #r.bosses > 0 then H.RAIDS[#H.RAIDS + 1] = r end
    end
end
H.Build = Build

function H.Boss(enc) Build() return byEnc[enc] end

-- The boss's creature display (Data/BossPortraits.lua: the encounter's creatures, the boss first).
function H.Display(boss)
    local p = ns.Data and ns.Data.BossPortraits and ns.Data.BossPortraits[boss.raid .. ":" .. boss.key]
    return p and p[1] and p[1].d or nil
end

---------------------------------------------------------------------------
-- Trophies from the raid log
---------------------------------------------------------------------------

-- A kill counts for the guild when more than half of the roster at the kill were guildmates. A kill whose roster
-- the log has already dropped (older than 90 days) counts: the log is the guild's own.
-- The live guild roster judges it, so: while the roster is not in yet (just after login or a /reload) a kill counts
-- (judged again once it is); a kill once judged the guild's is remembered (DisasterZoneDB.games.azeromon.hallKills),
-- so it keeps its trophy when raiders leave the guild later. A count of guildmates stored with the kill (gn) wins.
local function KillId(b) return tostring(b.enc) .. ":" .. tostring(b.ts) end

local function Remembered()
    local d = G:Data()
    if type(d.hallKills) ~= "table" then d.hallKills = {} end
    return d.hallKills
end

local function GuildKill(b)
    local Guild = ns.Guild
    if type(b.roster) ~= "table" or #b.roster == 0 then return true end
    local gn = tonumber(b.gn)
    if gn then return gn * 2 > #b.roster end
    if Remembered()[KillId(b)] then return true end
    if not (Guild and Guild.IsInGuild) then return true end
    if Guild.IsReady and not Guild:IsReady() then return true end          -- unknown yet: not a failure
    local n = 0
    local Util = ns.Util
    for _, key in ipairs(b.roster) do
        local k = (Util and Util.NormalizeName) and Util.NormalizeName(key) or key
        if Guild:IsInGuild(k) or (Util and Util.IsMe and Util.IsMe(k)) then n = n + 1 end
    end
    local yes = n * 2 > #b.roster
    if yes then Remembered()[KillId(b)] = true end
    return yes
end

local cache, cacheAt

-- [enc] = { boss, kills, first = { ts, roster, dur }, best = { dur, ts }, last = ts }
function H.Trophies(fresh)
    Build()
    local now = GetTime and GetTime() or 0
    if cache and not fresh and cacheAt == now then return cache end
    local out = {}
    local RaidLog = ns.RaidLog
    local raids = RaidLog and RaidLog.GetRaids and RaidLog:GetRaids() or {}
    for _, rec in pairs(raids) do
        for _, b in ipairs(type(rec) == "table" and rec.bosses or {}) do
            local boss = byEnc[tonumber(b.enc)]
            if boss and GuildKill(b) then
                local t = out[boss.enc]
                if not t then
                    t = { boss = boss, kills = 0 }
                    out[boss.enc] = t
                end
                t.kills = t.kills + 1
                local ts = tonumber(b.ts) or 0
                if not t.first or ts < t.first.ts then t.first = { ts = ts, roster = b.roster, dur = tonumber(b.dur) } end
                if not t.last or ts > t.last then t.last = ts end
                local dur = tonumber(b.dur)
                if dur and (not t.best or dur < t.best.dur) then t.best = { dur = dur, ts = ts } end
            end
        end
    end
    cache, cacheAt = out, now
    return out
end

function H.Trophy(enc) return H.Trophies()[enc] end
function H.Invalidate() cache = nil end

-- The roster came in (or changed) while the hall is on screen: the plinths look again (Game.lua compiles them on
-- entering the map, the UI draws m.over every frame).
local function RefreshPlinths()
    cache = nil
    local m = G.map
    if not (m and m.id == "hideout" and m.object and m.over) then return end
    for k, o in pairs(m.object) do
        if type(o.tile) == "function" then m.over[k] = o.tile(G) end
    end
end
H.RefreshPlinths = RefreshPlinths
if ns.On then ns:On("ROSTER_UPDATED", RefreshPlinths) end

function H.FormatDuration(sec)
    sec = math.floor(math.max(0, tonumber(sec) or 0))
    if sec >= 3600 then return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60) end
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

function H.FormatDate(ts)
    ts = tonumber(ts)
    if not ts or ts <= 0 then return "an unknown day" end
    local f = date or os.date
    return f("%d %b %Y", ts)
end

-- The plaque under a trophy: what the panel shows.
function H.Lines(enc)
    local boss = H.Boss(enc)
    if not boss then return {} end
    local t = H.Trophy(enc)
    if not t then
        return { "An empty plinth.", string.format("The guild has not brought %s down yet.", boss.name) }
    end
    local lines = {}
    lines[#lines + 1] = string.format("Killed %d %s by the guild.", t.kills, t.kills == 1 and "time" or "times")
    local first = "First kill: " .. H.FormatDate(t.first.ts)
    if t.first.dur then first = first .. string.format(" in %s", H.FormatDuration(t.first.dur)) end
    lines[#lines + 1] = first
    if t.best then
        lines[#lines + 1] = string.format("Fastest: %s (%s)", H.FormatDuration(t.best.dur), H.FormatDate(t.best.ts))
    else
        lines[#lines + 1] = "Fight time: not recorded yet (kills from 0.9.0 on are timed)."
    end
    if t.kills > 1 then lines[#lines + 1] = "Last kill: " .. H.FormatDate(t.last) end
    if type(t.first.roster) == "table" and #t.first.roster > 0 then
        local names = {}
        for i, key in ipairs(t.first.roster) do
            if i > 12 then names[#names + 1] = string.format("and %d more", #t.first.roster - 12) break end
            names[#names + 1] = ns.Util.ShortName(tostring(key), true)
        end
        lines[#lines + 1] = "There for the first: " .. table.concat(names, ", ")
    end
    return lines
end

---------------------------------------------------------------------------
-- The Hall of Champions: the guild's record holders (GuildBoard.lua categories)
---------------------------------------------------------------------------

H.CHAMPIONS = {
    { cat = "tamed", title = "Champion Tamer", what = "the most beasts tamed" },
    { cat = "arena", title = "Arena Champion", what = "the longest arena streak" },
    { cat = "badges", title = "Champion of Azeroth", what = "the most badges" },
    { cat = "duels", title = "Duelling Champion", what = "the best record against guildmates" },
    { cat = "points", title = "Champion of Deeds", what = "the most achievement points" },
}

-- The leader of a category: { name, text } or nil when nobody has a score yet.
function H.Champion(cat)
    local GB = ns.AzeroGuild
    if not (GB and GB.Ranking) then return nil end
    local rows = GB:Ranking(cat)
    local top = rows[1]
    if not top or (tonumber(top.value) or 0) <= 0 then return nil end
    return { name = top.entry.name or "?", text = top.text or "" }
end

---------------------------------------------------------------------------
-- The Guild Bestiary board
---------------------------------------------------------------------------

function H.BestiaryText()
    local GB = ns.AzeroGuild
    if not (GB and GB.GuildBestiary) then return "GUILD BESTIARY\nNobody has tamed anything yet." end
    local done, total, missing = 0, 0, {}
    local completable = {}
    for _, id in ipairs(GB.CompletableIds and GB.CompletableIds() or {}) do completable[id] = true end
    for _, row in ipairs(GB:GuildBestiary()) do
        if completable[row.id] then
            total = total + 1
            if row.count > 0 then done = done + 1 elseif #missing < 8 then missing[#missing + 1] = D.species[row.id].name end
        end
    end
    local text = string.format("GUILD BESTIARY\nTogether the guild has tamed %d of %d kinds of beast.", done, total)
    if #missing > 0 then text = text .. "\nStill wild: " .. table.concat(missing, ", ") .. (done + #missing < total and "..." or ".") end
    if done >= total and total > 0 then text = text .. "\nEvery beast of Azeroth has a name in this guild." end
    return text
end

---------------------------------------------------------------------------
-- The hall itself (Maps.lua format), painted by dev/generators/azeromon_hall.py and baked like an interior
-- (Ground.lua: hideout; HallArt.lua: its wings, props, fires and lights). A cathedral nave runs from the stairs to
-- the throne dais; eight raid wings open off it, four a side, and Sunwell's plinths flank the throne. A wing is
-- shut (dust sheets, scaffolding, a rope across its mouth) until the guild has killed one of its raid's bosses.
---------------------------------------------------------------------------

-- 36 x 34, X solid. The painter's collision grid (the hideout test checks this copy against it).
local ROWS = {
    "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    "X..XX..X.X.......XX.......X.X..XX..X",
    "X...........XXXX.XX.XXXX...........X",
    "XXXXXXXXXXXXX..........XXXXXXXXXXXXX",
    "XXXXXXXXXXXXX..........XXXXXXXXXXXXX",
    "XX.X.X.X.X.X......................XX",
    "X.......................X..X..X..X.X",
    "X.X.X.X.X.X..X........X...........XX",
    "XXXXXXXXXXXXX..........XXXXXXXXXXXXX",
    "XXXXXXXXXXXXX..........XXXXXXXXXXXXX",
    "XXX.......................X..X..X..X",
    "XXX.X...X.....X......X.............X",
    "X..........................X...X...X",
    "XXXXXXXXXXXXX..........XXXXXXXXXXXXX",
    "XXXXXXXXXXXXX..........XXXXXXXXXXXXX",
    "X.......................X.X..X..X.XX",
    "X.....X............................X",
    "X.......................XX.X..X..XXX",
    "XXXXXXXXXXXXX..........XXXXXXXXXXXXX",
    "XXXXXXXXXXXXX..........XXXXXXXXXXXXX",
    "X..X..X..X....X......X....X..X..X.XX",
    "X..................................X",
    "X..X..X..X................X..X..X.XX",
    "XXXXXXXXXXXXXX........XXXXXXXXXXXXXX",
    "X..................................X",
    "X...............................X..X",
    "X..................................X",
    "X.XXXXXXXX...............XXXXXXXX..X",
    "XXXXXXXXXXXXXXXXX..XXXXXXXXXXXXXXXXX",
    "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
}

local ART = ns.AzeroHallArt or { plinths = {}, wings = {} }
H.ART = ART

Build()
local raidByKey = {}
for _, r in ipairs(H.RAIDS) do raidByKey[r.key] = r end

-- A wing is open once the guild has killed one of its raid's bosses.
function H.WingOpen(key)
    local r = raidByKey[key]
    if not r then return true end
    for _, b in ipairs(r.bosses) do if H.Trophy(b.enc) then return true end end
    return false
end

-- trophies standing in a raid's wing / its plinth count
function H.WingCount(key)
    local r = raidByKey[key]
    if not r then return 0, 0 end
    local n = 0
    for _, b in ipairs(r.bosses) do if H.Trophy(b.enc) then n = n + 1 end end
    return n, #r.bosses
end

-- what the wing's banner (and the banner over the screen on walking in) says
function H.WingLine(key)
    local r = raidByKey[key]
    if not r then return "" end
    local n, total = H.WingCount(key)
    if n == 0 then return r.name .. ": sealed until the guild's first kill there" end
    if n == total then return string.format("%s: all %d trophies", r.name, total) end
    return string.format("%s: %d of %d trophies", r.name, n, total)
end

local objects = {}
for _, p in ipairs(ART.plinths) do
    local raid = raidByKey[p[1]]
    local boss = raid and raid.bosses[p[2]]
    if boss then
        local enc = boss.enc
        objects[#objects + 1] = { x = p[3], y = p[4], boss = boss, theme = p[5],
            tile = function() return H.Trophy(enc) and "plinth" or "plinthempty" end,
            hint = "Look at the " .. boss.name .. " plinth",
            script = function(g)
                if not H.WingOpen(raid.key) then
                    g:Say(string.format("A plinth under a dust sheet. %s opens when the guild kills one of its bosses.", raid.name))
                else
                    g:Wait({ kind = "trophy", enc = enc })
                end
            end }
    end
end
-- each wing's banner at its mouth reads the wing's count
for _, w in ipairs(ART.wings) do
    if w.mouth then
        for dy = 0, 1 do
            objects[#objects + 1] = { x = w.mouth, y = w.y0 + dy, hint = "Read the banner",
                script = function(g) g:Say(H.WingLine(w.key) .. ".") end }
        end
    end
end
objects[#objects + 1] = { x = 32, y = 29, hint = "Read the Guild Bestiary",
    script = function(g) g:Say(H.BestiaryText()) end }

local npcs = {}
local STATUE_X = { 3, 6, 9, 26, 29 }
for i, ch in ipairs(H.CHAMPIONS) do
    npcs[#npcs + 1] = { id = "statue" .. i, x = STATUE_X[i], y = 29, sprite = "hero", tint = { 0.86, 0.88, 0.94 },
        face = "down", statue = true, stone = true, lift = 7,
        name = function() local c = H.Champion(ch.cat) return c and c.name or "Unclaimed" end,
        title = ch.title,
        script = function(g)
            local c = H.Champion(ch.cat)
            if c then
                g:Say(string.format("The plaque reads: %s, %s. %s: %s.", c.name, ch.title, ch.what:sub(1, 1):upper() .. ch.what:sub(2), c.text))
            else
                g:Say(string.format("An empty plinth. The plaque reads: %s. Whoever has %s stands here.", ch.title, ch.what))
            end
        end }
end
npcs[#npcs + 1] = { id = "steward", name = "Steward Marlon", title = "Guild Hall Keeper", x = 20, y = 30, sprite = "bald",
    tint = { 0.9, 0.85, 0.7 }, face = "left",
    script = function(g)
        local n = 0
        for _ in pairs(H.Trophies()) do n = n + 1 end
        g:Say("Steward Marlon: Welcome to the Guild Hall. Every raid boss has a plinth here; the guild's kills put a trophy on it.")
        g:Say("Steward Marlon: Each raid has its own wing. A wing stays sealed until the guild draws first blood there, and Sunwell's light waits for the plateau.")
        g:Say(string.format("Steward Marlon: The trophies come from the guild's raid log. %s", n == 0 and "None yet. Go kill something." or (n .. " stand here now. Press Space at one to read its plaque.")))
        g:Say("Steward Marlon: The statues are our champions, and the lectern by the east table is what the guild has tamed together.")
    end }

-- Every visit: a shut wing's mouth is roped off (solid), and the rope says why.
local function Prepare(def)
    local rows = {}
    for i, r in ipairs(ROWS) do rows[i] = r end
    local objs = {}
    for i, o in ipairs(objects) do objs[i] = o end
    for _, w in ipairs(ART.wings) do
        if w.mouth and not H.WingOpen(w.key) then
            local name = raidByKey[w.key] and raidByKey[w.key].name or w.name
            for y = w.y0 + 2, w.y0 + 4 do
                local r = rows[y + 1]
                rows[y + 1] = r:sub(1, w.mouth) .. "X" .. r:sub(w.mouth + 2)
                objs[#objs + 1] = { x = w.mouth, y = y, rope = w.key, hint = "Look at the rope",
                    script = function(g) g:Say(string.format("Dust sheets and scaffolding. The %s wing opens when the guild kills one of its bosses.", name)) end }
            end
        end
    end
    def.rows, def.objects = rows, objs
end
H.Prepare = Prepare
H.ROWS = ROWS

Maps.hideout = {
    name = "The Guild Hall",
    music = "title",
    theme = "hall",
    hall = true,                         -- drawn from its bake (UI: Amb.Hall); the plinth tiles stay hidden
    dynamic = true,                      -- compiled afresh on every visit: the trophies and wings follow the raid log
    prepare = Prepare,
    rows = ROWS,
    warps = { { x = 17, y = 32, map = "post", tx = 10, ty = 3, face = "down" },      -- up the inn's stairs (0.27 layout)
              { x = 18, y = 32, map = "post", tx = 10, ty = 3, face = "down" } },
    objects = objects,
    npcs = npcs,
}
