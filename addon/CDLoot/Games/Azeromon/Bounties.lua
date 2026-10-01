if CDLootBoot and CDLootBoot.Run("Games/Azeromon/Bounties.lua", ...) then return end -- CDLoot Games/Azeromon/Bounties.lua
-- ns.AzeroBounty: the bounty board by the Lion's Pride Inn in Goldshire (and BOUNTIES in the start menu).
--   Daily:  D.BOUNTIES_PER_DAY bounties drawn from D.bounties with the day's number, so the whole guild gets the
--           same ones. Progress comes from the event feed; a finished bounty pays out at once (toast + the quest
--           complete sound), wherever the player is.
--   Weekly: one goal from D.guildGoals (by the week's number) that the guild works on together. Each player counts
--           their own part; the guild summaries (GuildBoard: AZS wk / wn) add everyone's up. Each tier the guild
--           reaches pays every player who helped (at least one), once.
-- Days and weeks follow WoW's own resets: the daily quest reset (GetQuestResetTime), and the weekly reset on that
-- same hour on Wednesday in Europe, Tuesday elsewhere.
local addonName, ns = ...

local B = ns:NewModule("AzeroBounty")
local G = ns.Azero
local D = ns.AzeroData

local DAY, HOUR = 86400, 3600
local ICON_BOUNTY = "Interface\\Icons\\INV_Misc_Note_01"
local ICON_GUILD = "Interface\\Icons\\INV_Shirt_GuildTabard_01"
local SOUND_DONE = 878                      -- IG_QUEST_LIST_COMPLETE

B.clock, B.resetIn, B.region = nil, nil, nil       -- tests: fixed time / seconds to reset / region

local TEMPLATE = {}
for _, t in ipairs(D.bounties) do TEMPLATE[t.id] = t end

---------------------------------------------------------------------------
-- Days and weeks
---------------------------------------------------------------------------

local function Now()
    if B.clock then return B.clock end
    return (GetServerTime and GetServerTime()) or (time and time()) or 0
end

-- Seconds until the next daily reset (to midnight UTC if the client doesn't say).
function B.ResetIn()
    local left = B.resetIn or (GetQuestResetTime and tonumber(GetQuestResetTime()))
    if not left or left <= 0 or left > DAY then left = DAY - Now() % DAY end
    return left
end

-- The day: the hour of the next daily reset, the same number for everyone in the region.
function B.DayKey()
    return math.floor((Now() + B.ResetIn()) / HOUR + 0.5)
end

local function WeeklyResetWeekday()           -- 0 = Sunday
    local region = B.region or (GetCurrentRegion and GetCurrentRegion())
    return region == 3 and 3 or 2
end

-- The week counts up at each weekly reset: the block of daily resets that follow it. Also returns the seconds
-- until the next weekly reset.
function B.WeekKey()
    local nextReset = Now() + B.ResetIn()
    local day = math.floor(nextReset / DAY)                    -- the date of the next daily reset
    local weekday = (day + 4) % 7                               -- the epoch's day 0 was a Thursday
    local since = (weekday - (WeeklyResetWeekday() + 1)) % 7   -- days since the week's first reset date
    local first = day - since
    return math.floor(first / 7), B.ResetIn() + (first + 6 - day) * DAY
end

---------------------------------------------------------------------------
-- State (in the save): { day, list = { { id, arg, n, got, done, money, item, count } }, week, wn, tiers = {} }
---------------------------------------------------------------------------

local function Roll(day)
    local rng = ns.AzeroPvP.NewRng(day * 7919 + 17)
    local pool = {}
    for i = 1, #D.bounties do pool[i] = i end
    local list = {}
    for k = 1, math.min(D.BOUNTIES_PER_DAY, #pool) do
        local t = D.bounties[table.remove(pool, rng(1, #pool))]
        local n = rng(t.n[1], t.n[2])
        local arg = t.args and t.args[rng(1, #t.args)] or nil
        local reward = D.bountyItems[rng(1, #D.bountyItems)]
        list[k] = { id = t.id, arg = arg, n = n, got = 0, money = math.floor(t.pay * n / 10 + 0.5) * 10,
                    item = reward[1], count = reward[2] }
    end
    return list
end

function B.Goal(week) return D.guildGoals[(week % #D.guildGoals) + 1] end

function B:State()
    local s = G.save
    if type(s) ~= "table" then return nil end
    local st = s.bounty
    local day = B.DayKey()
    if type(st) ~= "table" or st.day ~= day or type(st.list) ~= "table" then
        local old = type(st) == "table" and st or {}
        st = { day = day, list = Roll(day), week = old.week, wn = old.wn, tiers = old.tiers }
        s.bounty = st
    end
    local week = B.WeekKey()
    if st.week ~= week or type(st.tiers) ~= "table" then st.week, st.wn, st.tiers = week, 0, {} end
    return st
end

function B.Text(b)
    local t = TEMPLATE[b.id]
    return t and t.text(b.n, b.arg) or "?"
end

function B.RewardText(money, item, count)
    local parts = {}
    if money and money > 0 then parts[#parts + 1] = D.Money(money) end
    local def = item and D.items[item]
    if def then parts[#parts + 1] = (count or 1) > 1 and (count .. " " .. def.name .. "s") or def.name end
    return table.concat(parts, " and ")
end

-- My part of the week and the guild's total (everyone's latest summary for this week, me included).
function B:Weekly()
    local st = B:State()
    if not st then return 0, 0, 0 end
    local total, people = st.wn or 0, (st.wn or 0) > 0 and 1 or 0
    if ns.AzeroGuild and ns.AzeroGuild.WeeklyTotal then total, people = ns.AzeroGuild:WeeklyTotal(st.week) end
    return st.wn or 0, total, people
end

-- The tier reached (0 - 3) and the next tier's target (nil at the top).
function B:Tier()
    local st = B:State()
    if not st then return 0, nil end
    local goal = B.Goal(st.week)
    local _, total = B:Weekly()
    local reached = 0
    for i, need in ipairs(goal.tiers) do if total >= need then reached = i end end
    return reached, goal.tiers[reached + 1]
end

---------------------------------------------------------------------------
-- Paying out
---------------------------------------------------------------------------

local function Pay(money, items)
    local s = G.save
    s.money = s.money + (money or 0)
    for item, n in pairs(items or {}) do s.bag[item] = (s.bag[item] or 0) + n end
end

local function Toast(label, name, icon)
    if ns.AzeroAch and ns.AzeroAch.Notify then
        ns.AzeroAch:Notify({ label = label, name = name, icon = icon, sound = SOUND_DONE, open = function()
            if ns.AzeroUI and ns.AzeroUI.OpenBountiesPage then ns.AzeroUI:OpenBountiesPage() end
        end })
    end
end

function B:Complete(b)
    b.done = true
    Pay(b.money, { [b.item] = b.count })
    Toast("Bounty Complete", B.Text(b), ICON_BOUNTY)
    G:Emit("bounty", { id = b.id })
end

function B:CheckTiers()
    local st = B:State()
    if not st or (st.wn or 0) < 1 then return end
    local reached = B:Tier()
    for i = 1, reached do
        if not st.tiers[i] then
            st.tiers[i] = true
            local r = D.guildTierRewards[i]
            Pay(r.money, r.items)
            Toast("Guild Goal: " .. D.guildTierNames[i], B.Goal(st.week).name, ICON_GUILD)
            G:Emit("guildtier", { tier = i })
        end
    end
end

local function OnEvent(g, e)
    local st = B:State()
    if not st then return end
    for _, b in ipairs(st.list) do
        local t = TEMPLATE[b.id]
        if t and not b.done and t.on == e.event and t.test(e, b.arg) then
            b.got = math.min(b.n, b.got + 1)
            if b.got >= b.n then B:Complete(b) end
        end
    end
    local goal = B.Goal(st.week)
    if goal.on == e.event and goal.test(e) then
        st.wn = (st.wn or 0) + 1
        if ns.AzeroGuild and ns.AzeroGuild.MarkDirty then ns.AzeroGuild:MarkDirty() end
        B:CheckTiers()
    end
end

---------------------------------------------------------------------------
-- Illusion Dust (a Gold reward): shiny beasts twice as likely for a while
---------------------------------------------------------------------------

function G:ShinyBoosted()
    return self.save and (tonumber(self.save.shinyBoostUntil) or 0) > Now()
end

-- Returns the message.
function G:UseCharm(item)
    local def = D.items[item]
    local bag = self.save.bag
    if not def or def.use ~= "charm" or (bag[item] or 0) <= 0 then return "It won't have any effect." end
    bag[item] = bag[item] - 1
    if bag[item] <= 0 then bag[item] = nil end
    self.save.shinyBoostUntil = math.max(tonumber(self.save.shinyBoostUntil) or 0, Now()) + def.minutes * 60
    return def.used
end

function G:ShinyBoostLeft()
    return math.max(0, (tonumber(self.save and self.save.shinyBoostUntil) or 0) - Now())
end

---------------------------------------------------------------------------
-- The board (from the map object: G:BountyBoard() waits while the UI shows it)
---------------------------------------------------------------------------

function G:BountyBoard() return self:Wait({ kind = "bounties" }) end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function B:OnInit()
    local events = {}
    for _, t in ipairs(D.bounties) do events[t.on] = true end
    for _, t in ipairs(D.guildGoals) do events[t.on] = true end
    for ev in pairs(events) do G:On(ev, OnEvent) end
    G:On("load", function() B:CheckTiers() end)
    if ns.On then ns:On("AZERO_GUILD_UPDATED", function() B:CheckTiers() end) end
end
