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

local function ShortName(key) return (tostring(key):match("^[^-]+")) or tostring(key) end

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
            names[#names + 1] = ShortName(key)
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
-- The hall itself (Maps.lua format). Plinths in raid order, a row per raid, the raid's name on a sign at the
-- row's start; the champions' statues along the south wall, the Bestiary board and the steward by the stairs.
---------------------------------------------------------------------------

-- 30 x 24. Three rows of wall with the crest, banners and windows; the throne under the crest; the carpet down
-- the nave between two wings of plinths (raids 1-5 left, 6-9 right), pillars and chandeliers along it; the lower
-- hall with two hearths, feast tables, the champions' statues, the Bestiary board and the stairs up.
local rows = {
    "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    "Tp..........................pT",
    "T.............==.............T",
    "T.............==.............T",
    "T.............==.............T",
    "T............*==*............T",
    "T.............==.............T",
    "T.............==.............T",
    "T.............==.............T",
    "T............*==*............T",
    "T.............==.............T",
    "T.............==.............T",
    "T.............==.............T",
    "T.............==.............T",
    "T.............==.............T",
    "T..ttt..ttt...==...ttt..ttt..T",
    "T.............==.............T",
    "T.............==.............T",
    "T.............==.............T",
    "T.............==.............T",
    "Tp............==............pT",
    "TTTTTTTTTTTTTTrTTTTTTTTTTTTTTT",
}

local stamps = {
    { kind = "crest", x = 14, y = 1 },
    { kind = "throne", x = 14, y = 3 },
    { kind = "banner", x = 3, y = 1 }, { kind = "window", x = 6, y = 1 }, { kind = "bannerblue", x = 9, y = 1 },
    { kind = "window", x = 12, y = 1 }, { kind = "window", x = 17, y = 1 }, { kind = "bannerblue", x = 20, y = 1 },
    { kind = "window", x = 23, y = 1 }, { kind = "banner", x = 26, y = 1 },
    { kind = "pillar", x = 13, y = 5 }, { kind = "pillar", x = 16, y = 5 },
    { kind = "pillar", x = 13, y = 9 }, { kind = "pillar", x = 16, y = 9 },
    { kind = "pillar", x = 13, y = 13 }, { kind = "pillar", x = 16, y = 13 },
    { kind = "fireplace", x = 1, y = 14 }, { kind = "fireplace", x = 27, y = 14 },
}

local objects, signs = {}, {}
Build()
for i, raid in ipairs(H.RAIDS) do
    local left = i <= 5
    local y = left and (2 + 2 * i) or (2 + 2 * (i - 5))
    local signX = left and 1 or 28
    signs[#signs + 1] = { x = signX, y = y, text = raid.name:upper() .. "\n" .. #raid.bosses .. " plinths. Press Space at one." }
    for j, boss in ipairs(raid.bosses) do
        local enc = boss.enc
        objects[#objects + 1] = { x = left and (1 + j) or (16 + j), y = y, boss = boss,
            tile = function() return H.Trophy(enc) and "plinth" or "plinthempty" end,
            hint = "Look at the " .. boss.name .. " plinth",
            script = function(g) g:Wait({ kind = "trophy", enc = enc }) end }
    end
end
objects[#objects + 1] = { x = 25, y = 19, tile = "trophyboard", hint = "Read the Guild Bestiary",
    script = function(g) g:Say(H.BestiaryText()) end }

local npcs = {}
local STATUE_X = { 4, 7, 10, 19, 22 }
for i, ch in ipairs(H.CHAMPIONS) do
    npcs[#npcs + 1] = { id = "statue" .. i, x = STATUE_X[i], y = 19, sprite = "hero", tint = { 0.62, 0.64, 0.72 },
        face = "down", statue = true,
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
npcs[#npcs + 1] = { id = "steward", name = "Steward Marlon", title = "Guild Hall Keeper", x = 17, y = 21, sprite = "bald",
    tint = { 0.9, 0.85, 0.7 }, face = "left",
    script = function(g)
        local n = 0
        for _ in pairs(H.Trophies()) do n = n + 1 end
        g:Say("Steward Marlon: Welcome to the guild hall. Every raid boss has a plinth here; the guild's kills put a trophy on it.")
        g:Say(string.format("Steward Marlon: The trophies come from the guild's raid log. %s", n == 0 and "None yet. Go kill something." or (n .. " stand here now. Press Space at one to read its plaque.")))
        g:Say("Steward Marlon: The statues are our champions, and the board by the east hearth is what the guild has tamed together.")
    end }

Maps.hideout = {
    name = "The Guild Hall",
    music = "title",
    theme = "hall",
    dynamic = true,                      -- compiled afresh on every visit: the plinths follow the raid log
    rows = rows,
    stamps = stamps,
    warps = { { x = 14, y = 23, map = "post", tx = 5, ty = 3, face = "down" } },
    signs = signs,
    objects = objects,
    npcs = npcs,
}
