if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Marks.lua", ...) then return end -- DisasterZone Games/Azeromon/Marks.lua
-- ns.AzeroMarks: the guild's marks on the world.
--   Last seen: where each guildmate last stood (from presence, Net.lua) is remembered on this account
--              (DisasterZoneDB.games.azeromon.lastSeen); once they are gone a small rune stone stands on that spot
--              with "Name · 3 h ago" under it, for up to KEEP_DAYS days. Nothing is sent: each client remembers
--              what it saw.
--   The statue: Goldshire's statue follows the week's guild goal (Bounties.lua): scaffolding until the first tier,
--              the plinth with a block being carved after it, the finished knight once the top tier is reached. A
--              finished statue stands on through the next week until that week's goal is done too.
--   The chronicle: for CHRONICLE_DAYS after a guild raid kill (the raid log, as the Guild Hall's trophies count
--              them) Goldshire celebrates: a town crier by the bounty board cries the kills and the guild's other
--              news (a boss's echo roaming, the weekly statue done, guildmates' shinies), pennants fly from the lamp
--              posts, a standard stands by the statue, a toast says so on arrival, and the townsfolk mention it once
--              each. Everyone in the guild sees the same: it all comes from the shared raid log and guild news.
local addonName, ns = ...

local Marks = ns:NewModule("AzeroMarks")
local G = ns.Azero
local Maps = ns.AzeroMaps

Marks.KEEP_DAYS = 7
Marks.MAX_KEPT = 60          -- guildmates remembered (the oldest forgotten first)
Marks.PER_MAP = 6            -- markers drawn on one map (the newest)
Marks.EVERY = 1              -- seconds between looks at who is around
Marks.clock = nil            -- tests: server time

local acc = 0

local function Now()
    if Marks.clock then return Marks.clock end
    return (GetServerTime and GetServerTime()) or (time and time()) or 0
end

local function Store()
    local d = G:Data()
    if type(d.lastSeen) ~= "table" then d.lastSeen = {} end
    return d.lastSeen
end

---------------------------------------------------------------------------
-- Last seen
---------------------------------------------------------------------------

-- Notes where every guildmate in view is (called by the UI every frame; looks once a second).
function Marks:Update(dt)
    acc = acc + (dt or 0)
    if acc < Marks.EVERY then return end
    acc = 0
    local Net = ns.AzeroNet
    if not (Net and Net.AllPeers) then return end
    local store, now = Store(), Now()
    for key, p in pairs(Net:AllPeers()) do
        if p.map and p.x and p.y then
            local def = Maps[p.map]
            store[key] = { m = p.map, x = p.x, y = p.y, t = now, c = p.class, n = p.name,
                           r = type(def) == "table" and def.rev or nil }
        end
    end
    -- forget the oldest past MAX_KEPT, and anyone not seen for KEEP_DAYS
    local list = {}
    for key, e in pairs(store) do
        if type(e) ~= "table" or now - (tonumber(e.t) or 0) > Marks.KEEP_DAYS * 86400 then
            store[key] = nil
        else
            list[#list + 1] = { key = key, t = e.t }
        end
    end
    if #list > Marks.MAX_KEPT then
        table.sort(list, function(a, b) return a.t > b.t end)
        for i = Marks.MAX_KEPT + 1, #list do store[list[i].key] = nil end
    end
end

-- "just now", "25 min ago", "3 h ago", "yesterday", "4 days ago"
function Marks.Ago(secs)
    secs = math.max(0, secs or 0)
    if secs < 120 then return "just now" end
    if secs < 3600 then return string.format("%d min ago", math.floor(secs / 60)) end
    if secs < 86400 then return string.format("%d h ago", math.floor(secs / 3600)) end
    if secs < 2 * 86400 then return "yesterday" end
    return string.format("%d days ago", math.floor(secs / 86400))
end

-- The markers to draw on a map: { key, x, y, name, class, label }, newest first, at most PER_MAP, one per tile.
-- Guildmates still around (presence) have no marker: they are standing there themselves.
function Marks:On(mapId)
    local out, now, Net = {}, Now(), ns.AzeroNet
    local def = Maps[mapId]
    local rev = type(def) == "table" and def.rev or nil
    local m = G.Compile and G.Compile(mapId)
    for key, e in pairs(Store()) do
        local here = Net and Net.Peer and Net:Peer(key)
        if type(e) == "table" and e.m == mapId and e.r == rev and not here and m
            and e.x >= 0 and e.y >= 0 and e.x < m.w and e.y < m.h and not m.solid[m.key(e.x, e.y)] then
            out[#out + 1] = { key = key, x = e.x, y = e.y, t = e.t, name = e.n or key, class = e.c }
        end
    end
    table.sort(out, function(a, b) return a.t > b.t end)
    local kept, taken = {}, {}
    for _, e in ipairs(out) do
        local spot = e.x .. ":" .. e.y
        if not taken[spot] and #kept < Marks.PER_MAP then
            taken[spot] = true
            e.label = e.name .. " · " .. Marks.Ago(now - e.t)
            kept[#kept + 1] = e
        end
    end
    return kept
end

---------------------------------------------------------------------------
-- The guild statue
---------------------------------------------------------------------------

-- 0 scaffolding, 1 the plinth, 2 the finished statue.
function Marks.StatueStage()
    local B = ns.AzeroBounty
    if not B then return 0 end
    local reached = B:Tier() or 0
    local stage = reached >= 3 and 2 or reached >= 1 and 1 or 0
    if stage < 2 then                        -- last week's finished statue stands until this week's is done too
        local st = B:State()
        local last = st and type(st.weeks) == "table" and st.weeks[(st.week or 0) - 1]
        if type(last) == "table" and type(last.tiers) == "table" and last.tiers[3] then stage = 2 end
    end
    return stage
end

-- The plaque on the statue's plinth (a map script).
function G:GuildStatue()
    local B = ns.AzeroBounty
    local st = B and B:State()
    if not st then
        self:Say("A statue for the guild is going up here.")
        return
    end
    local goal = B.Goal(st.week)
    local _, total = B:Weekly()
    local reached, nextNeed = B:Tier()
    local stage = Marks.StatueStage()
    local head = ({ "Scaffolding stands round a rough block of stone.",
                    "The plinth is up; masons are carving the block.",
                    "A knight of the guild stands on the plinth, sword planted." })[stage + 1]
    local line
    if nextNeed then
        line = string.format("This week's guild goal: %s.\n%d so far. %s at %d.", goal.name, total,
            ns.AzeroData.guildTierNames[reached + 1], nextNeed)
    else
        line = string.format("This week's guild goal: %s.\nDone: %d! Gold for the whole guild.", goal.name, total)
    end
    self:Say(head)
    self:Say(line)
end

---------------------------------------------------------------------------
-- The chronicle
---------------------------------------------------------------------------

Marks.CHRONICLE_DAYS = 7
Marks.CRY_EVERY = 6              -- seconds a line of the crier's stays in his bubble
Marks.NEWS_KEEP = 10             -- guild news lines kept (shinies: GuildBoard.lua)
Marks.PENNANTS = { { 16, 6 }, { 22, 9 }, { 11, 13 }, { 19, 22 }, { 26, 9 }, { 6, 24 } }   -- Goldshire's lamp posts
Marks.STANDARD = { 26, 14 }      -- the standard by the statue

-- The guild's raid kills in the last CHRONICLE_DAYS, newest first: { enc, name, raid, ts, id }.
function Marks.RecentKills()
    local H = ns.AzeroHideout
    if not (H and H.Trophies) then return {} end
    local now, out = Now(), {}
    for enc, t in pairs(H.Trophies()) do
        local ts = tonumber(t.last)
        if ts and now - ts <= Marks.CHRONICLE_DAYS * 86400 and ts <= now + 300 then
            out[#out + 1] = { enc = enc, name = t.boss.name, raid = t.boss.raidName, ts = ts, id = enc .. ":" .. ts }
        end
    end
    table.sort(out, function(a, b) return a.ts > b.ts end)
    return out
end

function Marks.CrierOn() return #Marks.RecentKills() > 0 end

-- A guildmate's news (GuildBoard.lua AZN: a shiny found or tamed), kept a while for the crier.
function Marks.AddNews(text)
    local d = G:Data()
    if type(d.guildNews) ~= "table" then d.guildNews = {} end
    table.insert(d.guildNews, 1, { text = text, t = Now() })
    while #d.guildNews > Marks.NEWS_KEEP do table.remove(d.guildNews) end
end

-- Everything the crier has to cry, in order.
function Marks.News()
    local out, now = {}, Now()
    for _, k in ipairs(Marks.RecentKills()) do
        out[#out + 1] = string.format("Hear ye! The guild slew %s%s!", k.name, k.raid and (" in " .. k.raid) or "")
    end
    local D, store = ns.AzeroData, G.RaidRareStore and G:RaidRareStore() or {}
    for _, r in ipairs(D.raidRares or {}) do
        local untilT, sp, def = tonumber(store[r.sp]), D.species[r.sp], Maps[r.map]
        if untilT and untilT > now and sp and type(def) == "table" then
            out[#out + 1] = string.format("The echo of %s roams %s!", sp.name, def.name)
        end
    end
    local B = ns.AzeroBounty
    if B and B.Tier and G.save and (B:Tier() or 0) >= 3 then out[#out + 1] = "The statue's done! Gold for the guild this week!" end
    local news = G:Data().guildNews
    for _, n in ipairs(type(news) == "table" and news or {}) do
        if now - (tonumber(n.t) or 0) <= Marks.CHRONICLE_DAYS * 86400 then out[#out + 1] = "Hear ye! " .. n.text end
    end
    return out
end

-- The line in the crier's bubble now (one after another, CRY_EVERY seconds each, a short breath between).
function Marks.CrierLine()
    local news = Marks.News()
    if #news == 0 then return nil end
    local t = GetTime and GetTime() or 0
    local slot = math.floor(t / Marks.CRY_EVERY)
    if (t % Marks.CRY_EVERY) > Marks.CRY_EVERY - 1 then return nil end
    return news[slot % #news + 1]
end

-- Talking to the crier: everything, read out.
function Marks.CrierTalk(g)
    local news = Marks.News()
    if #news == 0 then
        g:Say("Town Crier: Nothing to cry today. Go and do something worth crying about!")
        return
    end
    g:Sfx("bell")
    for _, line in ipairs(news) do g:Say("Town Crier: " .. line) end
end

-- Pennants on the lamp posts and the standard by the statue (UI.lua draws them with the aftermath's props).
function Marks.Props(m)
    if not (m and m.id == "town" and Marks.CrierOn()) then return {} end
    local out = {}
    for _, p in ipairs(Marks.PENNANTS) do out[#out + 1] = { kind = "pennant", x = p[1], y = p[2] } end
    out[#out + 1] = { kind = "standard_red", x = Marks.STANDARD[1], y = Marks.STANDARD[2] }
    return out
end

-- The townsfolk mention the newest kill, once each (Goldshire and the Lion's Pride; not trainers, not the crier).
Marks.GOSSIP = {
    "Did you hear? The guild slew %s!",
    "%s, dead! Your guild's the talk of Goldshire.",
    "They say %s fell to your guild. Is it true?",
    "The crier's been shouting about %s all day. Well done, the lot of you.",
}
function Marks.Gossip(g, def)
    local m = g.map
    if not (m and (m.id == "town" or m.id == "post") and def and not def.trainer and def.gossip ~= false) then return end
    local kill = Marks.RecentKills()[1]
    if not kill then return end
    local d = G:Data()
    if type(d.gossipSeen) ~= "table" then d.gossipSeen = {} end
    local key = (def.id or def.name or "?") .. "@" .. kill.id
    if d.gossipSeen[key] then return end
    d.gossipSeen[key] = true
    local who = G.NpcName(def) or def.name or "Someone"
    local i = (#(def.id or "") + kill.enc) % #Marks.GOSSIP + 1
    g:Say(who .. ": " .. string.format(Marks.GOSSIP[i], kill.name))
end

-- Arriving in Goldshire after a new kill: a toast, once per kill.
function Marks.Arrived(m)
    if not (m and (m.id == "town" or m.id == "post")) then return end
    local kill = Marks.RecentKills()[1]
    if not kill then return end
    local d = G:Data()
    if d.crierToast == kill.id then return end
    d.crierToast = kill.id
    if ns.AzeroAch and ns.AzeroAch.Notify then
        ns.AzeroAch:Notify({ label = "Guild news", name = string.format("%s has fallen. Goldshire celebrates for %d days.",
            kill.name, Marks.CHRONICLE_DAYS), icon = "Interface\\Icons\\INV_Shirt_GuildTabard_01" })
    end
end

-- For tests
Marks._Reset = function() acc = 0 end
