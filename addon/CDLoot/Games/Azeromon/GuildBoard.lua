if CDLootBoot and CDLootBoot.Run("Games/Azeromon/GuildBoard.lua", ...) then return end -- CDLoot Games/Azeromon/GuildBoard.lua
-- ns.AzeroGuild: the guild Bestiary and leaderboard.
-- Each player's addon shares a small summary with the guild on the game prefix (CDLg):
--   AZS { v, n = tamed species, c = { dex numbers tamed }, b = badges, w/l/d = player-battle record,
--         ap = achievement points, done = time() the Bestiary was first completed (or nil) }
--   AZQ { v }   "please send me your summary" (opening the guild pages); answered from saved data, even with the
--               game closed, after a short random delay so a whole guild does not answer at once.
--   AZN { v, k, sp }  news for the guild's chat: k = "shiny" (found one) or "shinytamed". Shown to guildmates who
--               have played Azeromon.
--   (AZS also carries sh = shinies tamed, and wk / wn = the week's number and my part of the weekly guild goal;
--    older clients ignore them.)
-- Sent while Azeromon is open whenever something in it changes (at most every SEND_EVERY s) and every REFRESH s.
-- Everything received is kept (CDLootDB.games.azeromon.guild), so the board still shows offline guildmates.
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

local dirty, lastSent = true, -999
local lastQuery = -999
local replyAt = nil

local function Now() return GetTime() end
local function Clock() return (time and time()) or 0 end
local function ShortName(key) return (Ambiguate and Ambiguate(key, "short")) or (key:match("^[^-]+") or key) end

---------------------------------------------------------------------------
-- My own summary
---------------------------------------------------------------------------

-- Species that count toward "Bestiary complete": everything that is neither a rare nor a boss.
function GB.CompletableIds()
    local out = {}
    for _, id in ipairs(D.dexOrder) do
        if not D.species[id].rare and not D.species[id].boss then out[#out + 1] = id end
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

function GB:MySummary()
    local s = G.save
    local wk, wn
    local st = s and ns.AzeroBounty and ns.AzeroBounty:State()
    if st then wk, wn = st.week, st.wn or 0 end
    local nums, n = {}, 0
    if s then
        for id in pairs(s.caught) do
            local sp = D.species[id]
            if sp then
                n = n + 1
                nums[#nums + 1] = sp.num
            end
        end
    end
    table.sort(nums)
    local w, l, dr = 0, 0, 0
    local rec = G:Data().pvp
    if type(rec) == "table" then
        for _, r in pairs(rec) do
            if type(r) == "table" then w, l, dr = w + (r.w or 0), l + (r.l or 0), dr + (r.d or 0) end
        end
    end
    return { v = GB.VERSION, n = n, c = nums, b = s and G:BadgeCount() or 0, w = w, l = l, d = dr,
             ap = ns.AzeroAch and ns.AzeroAch:Points() or 0, done = G:Data().bestiaryDone,
             sh = ns.AzeroAch and ns.AzeroAch.Stat("shinies") or 0, wk = wk, wn = wn,
             ar = ns.AzeroArena and ns.AzeroArena.Best() or 0 }
end

local function HasPlayed() return type(G:Data().save) == "table" end

local function Send()
    if not (ns.Comm and IsInGuild and IsInGuild()) or not HasPlayed() then return false end
    local msg = GB:MySummary()
    msg.t = "AZS"
    local ok = ns.Comm:Send(msg, "GUILD", nil, "game")
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

local function OnSummary(sender, msg)
    if type(msg) ~= "table" or msg.v ~= GB.VERSION then return end
    local caught = {}
    if type(msg.c) == "table" then
        for i = 1, math.min(#msg.c, GB.MAX_SPECIES) do
            local id = SpeciesByNum(tonumber(msg.c[i]))
            if id then caught[id] = true end
        end
    end
    local n = 0
    for _ in pairs(caught) do n = n + 1 end
    Store()[sender] = {
        name = ShortName(sender), n = n, caught = caught,
        b = Int(msg.b, 0, 99) or 0, w = Int(msg.w, 0, 1e6) or 0, l = Int(msg.l, 0, 1e6) or 0, d = Int(msg.d, 0, 1e6) or 0,
        ap = Int(msg.ap, 0, 1e6) or 0, done = Int(msg.done, 1, 4102444800), sh = Int(msg.sh, 0, 1e6) or 0,
        wk = Int(msg.wk, 0, 1e7), wn = Int(msg.wn, 0, 1e7) or 0, ar = Int(msg.ar, 0, 1e4) or 0,
        seen = Clock(),
    }
    ns:Fire("AZERO_GUILD_UPDATED", sender)
end

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
    return ns.Comm:Send({ t = "AZQ", v = GB.VERSION }, "GUILD", nil, "game")
end

---------------------------------------------------------------------------
-- Board data
---------------------------------------------------------------------------

-- Every known player (me included, always current): { key, name, me, n, caught, b, w, l, d, ap, done }
function GB:Entries()
    local out = {}
    local mine = MyKey()
    for key, e in pairs(Store()) do
        if key ~= mine then
            local c = {}
            for k, v in pairs(e) do c[k] = v end
            c.key = key
            out[#out + 1] = c
        end
    end
    if HasPlayed() then
        local m = GB:MySummary()
        local caught = {}
        for id in pairs(G.save and G.save.caught or {}) do if D.species[id] then caught[id] = true end end
        out[#out + 1] = { key = mine, name = ShortName(mine), me = true, n = m.n, caught = caught, b = m.b,
                          w = m.w, l = m.l, d = m.d, ap = m.ap, done = m.done, sh = m.sh, wk = m.wk, wn = m.wn,
                          ar = m.ar }
    end
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
    local rows = {}
    for _, e in ipairs(GB:Entries()) do rows[#rows + 1] = { entry = e, value = cat.value(e), text = cat.text(e) } end
    table.sort(rows, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.entry.name < b.entry.name
    end)
    local rank, prev = 0, nil
    for i, r in ipairs(rows) do
        if r.value ~= prev then rank, prev = i, r.value end
        r.rank = rank
    end
    return rows
end

-- The first player known to have completed the Bestiary: entry, time (nil if nobody yet).
function GB:FirstComplete()
    local best
    for _, e in ipairs(GB:Entries()) do
        if e.done and (not best or e.done < best.done) then best = e end
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

function GB:MarkDirty() dirty = true end

---------------------------------------------------------------------------
-- Guild news (a shiny found or tamed)
---------------------------------------------------------------------------

local NEWS = {
    shiny = "%s found a shiny %s!",
    shinytamed = "%s tamed a shiny %s!",
}

function GB:Announce(kind, sp)
    if not (NEWS[kind] and D.species[sp] and ns.Comm and IsInGuild and IsInGuild()) then return false end
    return ns.Comm:Send({ t = "AZN", v = GB.VERSION, k = kind, sp = sp }, "GUILD", nil, "game")
end

local function OnNews(sender, msg)
    if type(msg) ~= "table" or msg.v ~= GB.VERSION or not HasPlayed() then return end
    if sender == MyKey() then return end
    local fmt, sp = NEWS[msg.k], D.species[msg.sp]
    if not (fmt and sp) then return end
    local text = string.format(fmt, ShortName(sender), sp.name)
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
GB._Reset = function() dirty, lastSent, lastQuery, replyAt = true, -999, -999, nil end
