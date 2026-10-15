if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/GuildBoard.lua", ...) then return end -- DisasterZone Games/Azeromon/GuildBoard.lua
-- ns.AzeroGuild: the guild Bestiary and leaderboard.
-- Each player's addon shares a small summary with the guild on the game prefix (CDLg):
--   AZS { v, n = tamed species, c = { dex numbers tamed }, b = badges, w/l/d = player-battle record,
--         ap = achievement points, done = server time the Bestiary was first completed (or nil),
--         id = this account's Azeromon id (one save per account: alts answer with the same save, so the board keeps
--         one entry per id, under the character heard from last) }
--   A field left out keeps what was known before (a summary sent from saved data with the game closed carries
--   everything, but older clients may not).
--   AZQ { v }   "please send me your summary" (opening the guild pages); answered from saved data, even with the
--               game closed, after a short random delay so a whole guild does not answer at once.
--   AZN { v, k, sp }  news for the guild's chat: k = "shiny" (found one) or "shinytamed". Shown to guildmates who
--               have played Azeromon.
--   (AZS also carries sh = shinies tamed, and wk / wn = the week's number and my part of the weekly guild goal;
--    older clients ignore them.)
-- Sent while Azeromon is open whenever something in it changes (at most every SEND_EVERY s) and every REFRESH s.
-- Everything received is kept (DisasterZoneDB.games.azeromon.guild), so the board still shows offline guildmates;
-- players who left the guild (once the roster is in) and anyone not heard from for FORGET_AFTER are dropped.
-- Trust-based, for fun: nothing here touches loot or council data.
--
-- Leaderboard categories are one entry each in CATEGORIES below.
local addonName, ns = ...

local GB = ns:NewModule("AzeroGuild")
local G = ns.Azero
local D = ns.AzeroData

GB.VERSION = 1
GB.SEND_EVERY = 10
GB.REFRESH = 300
GB.QUERY_EVERY = 30
GB.MAX_SPECIES = 200
GB.FORGET_AFTER = 30 * 86400
GB.CACHE_FOR = 1               -- s: the board's entries and rankings (the hall's statues ask every frame)
GB.EPOCH = 1788220800          -- 1 Sep 2026: no Bestiary was completed before Azeromon existed (clamps bad clocks)

local dirty, lastSent = true, -999
local lastQuery = -999
local replyAt = nil

local function Now() return GetTime() end
local function Clock() return (GetServerTime and GetServerTime()) or (time and time()) or 0 end

---------------------------------------------------------------------------
-- My own summary
---------------------------------------------------------------------------

-- Species that count toward "Bestiary complete": everything that is neither a rare nor a boss.
function GB.CompletableIds()
    local out = {}
    for _, id in ipairs(D.dexOrder) do
        local s = D.species[id]
        if not s.rare and not s.boss and not s.legendary then out[#out + 1] = id end
    end
    return out
end

local function Store()
    local d = G:Data()
    if type(d.guild) ~= "table" then d.guild = {} end
    return d.guild
end

-- The same key the addon's messages carry for me (Name-Realm), so my saved entry and my live one never double up.
local function MyKey() return ns.Util.PlayerKey() end
GB.MyKey = MyKey

-- The save as stored: the loaded one, or (the game not opened this session) the one in saved data. Read only.
local function StoredSave()
    if type(G.save) == "table" then return G.save end
    local s = G:Data().save
    return type(s) == "table" and s or nil
end

-- This account's Azeromon id (made once, kept with the account's Azeromon data, so a New Game keeps it).
local ALNUM = "0123456789abcdefghijklmnopqrstuvwxyz"
local function MyUid()
    local d = G:Data()
    if type(d.uid) ~= "string" or not d.uid:match("^%w+$") then
        local seed, h = tostring(MyKey()) .. ":" .. tostring(Clock()) .. ":" .. tostring(Now()), 0
        for i = 1, #seed do h = (h * 31 + seed:byte(i)) % 2147483647 end
        local t = {}
        for i = 1, 10 do
            h = (h * 16807 + math.random(0, 2147483646)) % 2147483647
            local n = h % 36 + 1
            t[i] = ALNUM:sub(n, n)
        end
        d.uid = table.concat(t)
    end
    return d.uid
end
GB.MyUid = MyUid

-- My Bestiary stamp; one from a wrong clock (before Azeromon existed, or in the future) becomes now.
local function MyDone()
    local d = G:Data()
    local done = tonumber(d.bestiaryDone)
    if done and (done < GB.EPOCH or done > Clock() + 300) then
        done = Clock()
        d.bestiaryDone = done
    end
    return done
end

-- Records the first time this account completed the Bestiary.
function GB:CheckCompletion()
    local s = G.save
    if not s then return end
    for _, id in ipairs(GB.CompletableIds()) do
        if not s.caught[id] then return end
    end
    local d = G:Data()
    if not d.bestiaryDone then
        d.bestiaryDone = Clock()
        G:Emit("bestiary", { done = d.bestiaryDone })
    end
end

-- From the stored save when the game has not been opened this session (answers to AZQ), never loading it.
function GB:MySummary()
    local s = StoredSave()
    local wk, wn
    local st = s and ns.AzeroBounty and ns.AzeroBounty:State()
    if st then wk, wn = st.week, st.wn or 0 end
    local nums, n = {}, 0
    local badges = 0
    if s then
        for id in pairs(type(s.caught) == "table" and s.caught or {}) do
            local sp = D.species[id]
            if sp then
                n = n + 1
                nums[#nums + 1] = sp.num
            end
        end
        local flags = type(s.flags) == "table" and s.flags or {}
        for id in pairs(D.badges) do if flags["badge_" .. id] then badges = badges + 1 end end
    end
    table.sort(nums)
    local w, l, dr = 0, 0, 0
    local rec = G:Data().pvp
    if type(rec) == "table" then
        for _, r in pairs(rec) do
            if type(r) == "table" then w, l, dr = w + (r.w or 0), l + (r.l or 0), dr + (r.d or 0) end
        end
    end
    return { v = GB.VERSION, n = n, c = nums, b = badges, w = w, l = l, d = dr, id = MyUid(),
             ap = ns.AzeroAch and ns.AzeroAch:Points() or 0, done = MyDone(),
             sh = ns.AzeroAch and ns.AzeroAch.Stat("shinies") or 0, wk = wk, wn = wn,
             ar = ns.AzeroArena and ns.AzeroArena.Best() or 0 }
end

local function HasPlayed() return type(G:Data().save) == "table" end

local function Send()
    if not (ns.Comm and IsInGuild and IsInGuild()) or not HasPlayed() then return false end
    local msg = GB:MySummary()
    msg.t = "AZS"
    local ok = ns.Games:Send(G.GAME_ID, msg, "GUILD")
    if ok then dirty, lastSent = false, Now() end
    return ok
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local byNum
local function SpeciesByNum(num)
    if not byNum then
        byNum = {}
        for id, sp in pairs(D.species) do byNum[sp.num] = id end
    end
    return byNum[num]
end

local function Int(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    v = math.floor(v)
    if v < lo or v > hi then return nil end
    return v
end

-- The board's cache (Entries / Ranking), dropped whenever what it is made of may have changed.
local entCache, entAt, rankCache = nil, -999, {}
local function Invalidate() entCache, rankCache = nil, {} end
GB.Invalidate = Invalidate

-- A Bestiary stamp that can't be right (before Azeromon existed, or ahead of the server's clock) is not trusted.
local function SaneDone(t, now) return t and t >= GB.EPOCH and t <= now + 300 end

local function OnSummary(sender, msg)
    if type(msg) ~= "table" or msg.v ~= GB.VERSION then return end
    local store = Store()
    local old = type(store[sender]) == "table" and store[sender] or {}
    local now = Clock()
    local caught, n = {}, 0
    if type(msg.c) == "table" then
        for i = 1, math.min(#msg.c, GB.MAX_SPECIES) do
            local id = SpeciesByNum(tonumber(msg.c[i]))
            if id then caught[id] = true end
        end
    elseif type(old.caught) == "table" then
        caught = old.caught
    end
    for _ in pairs(caught) do n = n + 1 end
    -- a field left out keeps the old value; one sent but out of range counts as 0 (or none)
    local function Num(k, lo, hi, none)
        if msg[k] == nil then
            if old[k] ~= nil then return old[k] end
            return none
        end
        local v = Int(msg[k], lo, hi)
        if v == nil then return none end
        return v
    end
    local oldDone = SaneDone(tonumber(old.done), now) and tonumber(old.done) or nil
    local done = oldDone
    if msg.done ~= nil then
        done = Int(msg.done, 1, 4102444800)
        -- a wrong clock: counted from when it was first heard of, and a stamp once known never moves later
        if done and not SaneDone(done, now) then done = oldDone or now end
        if oldDone and done and oldDone < done then done = oldDone end
    end
    local id = msg.id
    if type(id) ~= "string" or #id > 16 or not id:match("^%w+$") then id = old.id end
    if id and HasPlayed() and id == MyUid() then             -- my own account (an alt of mine): that's me
        store[sender] = nil
        Invalidate()
        return
    end
    store[sender] = {
        name = ns.Util.ShortName(sender, true), n = n, caught = caught, id = id,
        b = Num("b", 0, 99, 0), w = Num("w", 0, 1e6, 0), l = Num("l", 0, 1e6, 0), d = Num("d", 0, 1e6, 0),
        ap = Num("ap", 0, 1e6, 0), done = done, sh = Num("sh", 0, 1e6, 0),
        wk = Num("wk", 0, 1e7, nil), wn = Num("wn", 0, 1e7, 0), ar = Num("ar", 0, 1e4, 0),
        seen = now,
    }
    -- the same account (an alt) under another name: only the character heard from last stays
    if id then
        for key, e in pairs(store) do
            if key ~= sender and type(e) == "table" and e.id == id then store[key] = nil end
        end
    end
    Invalidate()
    ns:Fire("AZERO_GUILD_UPDATED", sender)
end

-- Drops players who left the guild (once the roster is in) and anyone not heard from for FORGET_AFTER.
local function Prune()
    local store = Store()
    local now = Clock()
    local Guild = ns.Guild
    local roster = Guild and Guild.IsInGuild and Guild.IsReady and Guild:IsReady()
    for key, e in pairs(store) do
        if type(e) ~= "table" or (tonumber(e.seen) or 0) < now - GB.FORGET_AFTER
           or (roster and type(key) == "string" and not Guild:IsInGuild(key)) then
            store[key] = nil
        end
    end
end
GB.Prune = Prune

local function OnQuery(sender, msg)
    if type(msg) ~= "table" or msg.v ~= GB.VERSION or not HasPlayed() then return end
    -- answer after a random 0.5-4 s so a whole guild does not reply in the same instant
    replyAt = replyAt or (Now() + 0.5 + math.random() * 3.5)
end

-- Ask the guild for summaries (opening the guild pages). At most every QUERY_EVERY seconds.
function GB:Query()
    if not (ns.Comm and IsInGuild and IsInGuild()) then return false end
    if Now() - lastQuery < GB.QUERY_EVERY then return false end
    lastQuery = Now()
    return ns.Games:Send(G.GAME_ID, { t = "AZQ", v = GB.VERSION }, "GUILD")
end

---------------------------------------------------------------------------
-- Board data
---------------------------------------------------------------------------

-- Every known player (me included, always current): { key, name, me, n, caught, b, w, l, d, ap, done }
-- One entry per account (my own alts' and anyone's duplicates left out). Cached: read only, rebuilt after a change
-- (a summary, a game event, MarkDirty) or CACHE_FOR seconds.
function GB:Entries()
    local now = Now()
    if entCache and now - entAt < GB.CACHE_FOR then return entCache end
    Prune()
    local out = {}
    local mine = MyKey()
    local played = HasPlayed()
    local myId = played and MyUid() or nil
    local byId = {}
    for key, e in pairs(Store()) do
        if key ~= mine and not (myId and e.id == myId) then
            local c = {}
            for k, v in pairs(e) do c[k] = v end
            c.key = key
            local prev = c.id and byId[c.id]
            if prev and (tonumber(prev.seen) or 0) >= (tonumber(c.seen) or 0) then
                c = nil
            elseif prev then
                for i, x in ipairs(out) do if x == prev then table.remove(out, i) break end end
            end
            if c then
                if c.id then byId[c.id] = c end
                out[#out + 1] = c
            end
        end
    end
    if played then
        local m = GB:MySummary()
        local s = StoredSave()
        local caught = {}
        for id in pairs(s and type(s.caught) == "table" and s.caught or {}) do if D.species[id] then caught[id] = true end end
        out[#out + 1] = { key = mine, name = ns.Util.ShortName(mine, true), me = true, n = m.n, caught = caught, b = m.b,
                          w = m.w, l = m.l, d = m.d, ap = m.ap, done = m.done, sh = m.sh, wk = m.wk, wn = m.wn,
                          ar = m.ar, id = m.id }
    end
    entCache, entAt, rankCache = out, now, {}
    return out
end

-- Leaderboard categories: value(entry) -> number, text(entry) -> string. Add one to add a board.
GB.CATEGORIES = {
    { id = "tamed", name = "Most beasts tamed", value = function(e) return e.n or 0 end,
      text = function(e) return (e.n or 0) .. " tamed" end },
    { id = "bestiary", name = "Bestiary progress", value = function(e)
          local done, total = 0, 0
          for _, id in ipairs(GB.CompletableIds()) do
              total = total + 1
              if e.caught and e.caught[id] then done = done + 1 end
          end
          return total > 0 and math.floor(done * 100 / total) or 0
      end, text = nil },
    { id = "arena", name = "Arena streak", value = function(e) return e.ar or 0 end,
      text = function(e) return (e.ar or 0) .. " in a row" end },
    { id = "shinies", name = "Shinies tamed", value = function(e) return e.sh or 0 end,
      text = function(e) return (e.sh or 0) .. (e.sh == 1 and " shiny" or " shinies") end },
    { id = "badges", name = "Badges", value = function(e) return e.b or 0 end,
      text = function(e) return (e.b or 0) .. (e.b == 1 and " badge" or " badges") end },
    { id = "duels", name = "Battles against guildmates", value = function(e) return (e.w or 0) * 1000 - (e.l or 0) end,
      text = function(e) return string.format("%d-%d-%d", e.w or 0, e.l or 0, e.d or 0) end },
    { id = "points", name = "Achievement points", value = function(e) return e.ap or 0 end,
      text = function(e) return (e.ap or 0) .. " pts" end },
}
GB.CATEGORIES[2].text = function(e) return GB.CATEGORIES[2].value(e) .. "%" end

-- Sorted rows for a category: { rank, entry, value, text }
function GB:Ranking(catId)
    local cat
    for _, c in ipairs(GB.CATEGORIES) do if c.id == catId then cat = c end end
    if not cat then return {} end
    local entries = GB:Entries()                  -- (first: a rebuild clears the cached rankings)
    if rankCache[catId] then return rankCache[catId] end
    local rows = {}
    for _, e in ipairs(entries) do rows[#rows + 1] = { entry = e, value = cat.value(e), text = cat.text(e) } end
    table.sort(rows, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.entry.name < b.entry.name
    end)
    local rank, prev = 0, nil
    for i, r in ipairs(rows) do
        if r.value ~= prev then rank, prev = i, r.value end
        r.rank = rank
    end
    rankCache[catId] = rows
    return rows
end

-- The first player known to have completed the Bestiary: entry, time (nil if nobody yet).
function GB:FirstComplete()
    local best
    local now = Clock()
    for _, e in ipairs(GB:Entries()) do
        if SaneDone(e.done, now) and (not best or e.done < best.done) then best = e end
    end
    return best
end

-- Per species: who in the guild has tamed it. { id, count, names = { ... } } in Bestiary order.
function GB:GuildBestiary()
    local entries = GB:Entries()
    local out = {}
    for _, id in ipairs(D.dexOrder) do
        local names = {}
        for _, e in ipairs(entries) do
            if e.caught and e.caught[id] then names[#names + 1] = e.me and (e.name .. " (you)") or e.name end
        end
        table.sort(names)
        out[#out + 1] = { id = id, count = #names, names = names }
    end
    return out
end

---------------------------------------------------------------------------
-- Update (called every frame by the UI while the game is open, and by a light ticker otherwise for replies)
---------------------------------------------------------------------------

-- The weekly guild goal: everyone's part for `week` (me included) and how many took part.
function GB:WeeklyTotal(week)
    local total, people = 0, 0
    for _, e in ipairs(GB:Entries()) do
        if e.wk == week and (e.wn or 0) > 0 then
            total, people = total + e.wn, people + 1
        end
    end
    return total, people
end

function GB:MarkDirty() dirty = true Invalidate() end

---------------------------------------------------------------------------
-- Guild news (a shiny found or tamed)
---------------------------------------------------------------------------

local NEWS = {
    shiny = "%s found a shiny %s!",
    shinytamed = "%s tamed a shiny %s!",
}

function GB:Announce(kind, sp)
    if not (NEWS[kind] and D.species[sp] and ns.Comm and IsInGuild and IsInGuild()) then return false end
    return ns.Games:Send(G.GAME_ID, { t = "AZN", v = GB.VERSION, k = kind, sp = sp }, "GUILD")
end

local function OnNews(sender, msg)
    if type(msg) ~= "table" or msg.v ~= GB.VERSION or not HasPlayed() then return end
    if sender == MyKey() then return end
    local fmt, sp = NEWS[msg.k], D.species[msg.sp]
    if not (fmt and sp) then return end
    local text = string.format(fmt, ns.Util.ShortName(sender, true), sp.name)
    GB.lastNews = text
    ns:Print("|cffffd200Azeromon:|r %s", text)
    if G.started then G.banner = { text = text, t = 4, total = 4 } end
end

function GB:Update()
    local now = Now()
    if replyAt and now >= replyAt then
        replyAt = nil
        Send()
    end
    if not (ns.AzeroNet and ns.AzeroNet:IsActive()) then return end
    if (dirty and now - lastSent >= GB.SEND_EVERY) or now - lastSent >= GB.REFRESH then Send() end
end

function GB:OnInit()
    if ns.Comm then
        ns.Comm:Register("AZS", OnSummary)
        ns.Comm:Register("AZQ", OnQuery)
        ns.Comm:Register("AZN", OnNews)
    end
    for _, ev in ipairs({ "tame", "evolve", "badge", "pvp", "achievement", "load", "arena" }) do
        G:On(ev, function() dirty = true end)
    end
    G:On("*", Invalidate)                      -- anything in the game may change my own entry
    if ns.On then ns:On("ROSTER_UPDATED", function() Prune() Invalidate() end) end
    G:On("tame", function() GB:CheckCompletion() end)
    G:On("shiny", function(_, e) GB:Announce("shiny", e.mon.sp) end)
    G:On("tame", function(_, e) if e.mon and e.mon.shiny and e.how == "caught" then GB:Announce("shinytamed", e.mon.sp) end end)
    G:On("evolve", function() GB:CheckCompletion() end)
    G:On("load", function() GB:CheckCompletion() end)
    -- answers to queries also go out while the game window is closed
    local ticker = CreateFrame("Frame")
    ticker:SetScript("OnUpdate", function() if replyAt then GB:Update() end end)
end

-- For tests
GB._Reset = function() dirty, lastSent, lastQuery, replyAt = true, -999, -999, nil Invalidate() end
