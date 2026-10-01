if CDLootBoot and CDLootBoot.Run("Core/StrategyPractice.lua", ...) then return end -- CDLoot: Core/StrategyPractice.lua
-- Practice (Addendum K): try a strategy's encounter helpers alone, anywhere (a target dummy is ideal).
-- The player takes the first row of every tracked table (and a plain job); demo players fill the other slots.
-- A scripted minute: the boss is near, the pull, the rotation's target casting every few seconds (demo players kick
-- on their turns, the player's real interrupt counts on any target), demo misdirects / cooldowns / a curse falling
-- off, then the kill. Whatever the player targets gets the plan's next raid mark, to see marking work solo.
-- Everything goes through Core/StrategyLive.lua exactly like a real encounter; nothing is sent to anyone.
local addonName, ns = ...

local Practice = ns:NewModule("StrategyPractice")
local Util = ns.Util

local LENGTH = 60           -- seconds from the pull to the kill
local PULL_AFTER = 4        -- seconds of "near the boss" before the pull
local CAST_EVERY = 7        -- the rotation target casts this often
local DEMO_REACTION = 1.2   -- a demo player kicks this long after the cast started

local DEMO = { "Aldren", "Brisa", "Corvin", "Dessa", "Eldor", "Fenna", "Gorim", "Halvi", "Isolde", "Joren", "Kaela",
               "Lirra", "Morn", "Nessa", "Orrin", "Pella", "Quen", "Rusk", "Sella", "Tavin", "Ulma", "Varn", "Wynne",
               "Yara", "Zorin", "Ansel", "Bryn", "Cato", "Dara", "Emrys" }

local CAST_NAMES = { "Circle of Healing", "Divine Wrath", "Prayer of Healing", "Greater Heal" }

local function S() return ns.Strategy end
local function Live() return ns.StrategyLive end

local run                   -- { token, boss, marks = { guid -> mark }, markNext }

local function Spell(id)
    return (GetSpellInfo and GetSpellInfo(id)) or tostring(id)
end

local function DemoGUID(key)
    return "Player-0-PRAC" .. (Util.Hash(key):sub(1, 6))
end

local function NpcGUID(npc)
    return "Creature-0-0-0-0-" .. tostring(npc or 0) .. "-00000PRACT"
end

local function ShortName(key) return Util.ShortName(key) or key end

-- Names for a practice run: me in the first row of each tracked table (its first player column) and in the first
-- plain slot; demo players everywhere else.
function Practice:Assign(s)
    local me = Util.PlayerKey()
    local a, n = {}, 0
    local tracked, firstCol = {}, {}
    for _, p in ipairs(s.p or {}) do
        for _, k in ipairs(p.k or {}) do
            if S().TrackKind(k) then tracked[k.id] = true end
            for ci, col in ipairs(k.c) do
                if col.t == "p" and not firstCol[k.id] then firstCol[k.id] = ci end
            end
        end
    end
    -- the slots other rows point at (a misdirect's tank, a healer's tank): my plain job is one nobody points at
    local pointed = {}
    for _, p in ipairs(s.p or {}) do
        for _, k in ipairs(p.k or {}) do
            for _, cells in pairs(k.d or {}) do
                for _, v in pairs(cells) do
                    if type(v) == "table" and v.s then pointed[v.s] = true end
                end
            end
        end
    end
    local gavePlain = false
    for _, slot in ipairs(S():GetSlots(s)) do
        local mine = false
        if tracked[slot.block] then
            mine = slot.row == 1 and slot.col == firstCol[slot.block]
        elseif not gavePlain and not pointed[slot.ref] then
            mine, gavePlain = true, true
        end
        if mine then
            a[slot.ref] = me
        else
            n = n + 1
            a[slot.ref] = Util.NormalizeName(DEMO[(n - 1) % #DEMO + 1])
        end
    end
    -- a row of mine that points at another slot (misdirect onto a tank, Innervate on a healer): that slot goes to a
    -- demo player, so I never misdirect onto myself
    for _, p in ipairs(s.p or {}) do
        for _, k in ipairs(p.k or {}) do
            for row, cells in pairs(k.d or {}) do
                local mineRow = false
                for ci, col in ipairs(k.c) do
                    if col.t == "p" and a[S().SlotRef(k.id, row, ci)] == me then mineRow = true end
                end
                if mineRow then
                    for _, v in pairs(cells) do
                        if type(v) == "table" and v.s and a[v.s] == me then
                            n = n + 1
                            a[v.s] = Util.NormalizeName(DEMO[(n - 1) % #DEMO + 1])
                        end
                    end
                end
            end
        end
    end
    return a
end

local function Alive(token)
    return run ~= nil and run.token == token
end

local function At(token, sec, fn)
    Util.After(sec, function()
        if Alive(token) and Live():GetCurrent() and Live():GetCurrent().practice then fn() end
    end)
end

-- A demo player's cast, through the combat log path.
local function DemoCast(key, sub, spell, targetNpc, targetName, spellId)
    Live():Handle(sub, DemoGUID(key), ShortName(key), targetNpc and NpcGUID(targetNpc) or nil, targetName, spell, spellId)
end

local function Script(token)
    local c = Live():GetCurrent()
    At(token, PULL_AFTER, function() Live():Engage() end)
    local t0 = PULL_AFTER
    -- the rotations: the target casts every few seconds; a demo player on turn kicks it
    local casts = 0
    for t = t0 + 2, t0 + LENGTH - 5, CAST_EVERY do
        casts = casts + 1
        local castN = casts
        At(token, t, function()
            for _, tr in ipairs(Live():GetCurrent().trackers) do
                if tr.kind == "rot" and #tr.order > 0 then
                    local npc = tr.npc or 0
                    -- the table's own abilities when it picked some, else a few healer casts
                    local castId, castName
                    if tr.abilityIds and #tr.abilityIds > 0 then
                        castId = tr.abilityIds[(castN - 1) % #tr.abilityIds + 1]
                        castName = Spell(castId)
                    else
                        castName = CAST_NAMES[(castN - 1) % #CAST_NAMES + 1]
                    end
                    Live():Handle("SPELL_CAST_START", NpcGUID(npc), "Practice target", nil, nil, castName, castId)
                    local r = tr.order[tr.cur]
                    if r and r.player ~= Util.PlayerKey() then
                        At(token, DEMO_REACTION, function()
                            DemoCast(r.player, "SPELL_CAST_SUCCESS", Spell(1766), npc, "Practice target")
                        end)
                    end
                end
            end
        end)
    end
    -- halfway: the rotation's target gains an immunity from its boss' list (e.g. Blessing of Protection) for 12 s,
    -- so the kickers it stops step aside
    local known = ns.Data and ns.Data.BossAbilities and ns.Data.BossAbilities[c.boss]
    local immuneId
    for _, id in ipairs(known and known.a or {}) do
        if Live().IMMUNE[id] and not immuneId then immuneId = id end
    end
    if immuneId then
        for _, tr in ipairs(c.trackers) do
            if tr.kind == "rot" then
                local npc = tr.npc or 0
                At(token, t0 + 22, function()
                    Live():Handle("SPELL_AURA_APPLIED", NpcGUID(npc), "Practice target", NpcGUID(npc), "Practice target",
                        Spell(immuneId), immuneId)
                end)
                At(token, t0 + 34, function()
                    Live():Handle("SPELL_AURA_REMOVED", NpcGUID(npc), "Practice target", NpcGUID(npc), "Practice target",
                        Spell(immuneId), immuneId)
                end)
            end
        end
    end
    -- the other tables: demo players do their part
    for _, tr in ipairs(c.trackers) do
        for i, r in ipairs(tr.rows) do
            if r.player and r.player ~= Util.PlayerKey() then
                local when = t0 + 3 + i * 2
                if tr.kind == "md" then
                    At(token, when, function() DemoCast(r.player, "SPELL_CAST_SUCCESS", Spell(34477)) end)
                elseif tr.kind == "bl" then
                    local planned = Live():PlannedAt(r) or 10
                    At(token, t0 + planned, function() DemoCast(r.player, "SPELL_CAST_SUCCESS", Spell(2825)) end)
                elseif tr.kind == "pi" then
                    At(token, when + 4, function() DemoCast(r.player, "SPELL_CAST_SUCCESS", Spell(10060)) end)
                elseif tr.kind == "iv" then
                    At(token, when + 10, function() DemoCast(r.player, "SPELL_CAST_SUCCESS", Spell(29166)) end)
                elseif tr.kind == "curse" and r.curse then
                    local name = r.curseId and Spell(r.curseId) or (r.label and r.label:match("(Curse of [%a ]+)")) or r.curse
                    At(token, when, function() DemoCast(r.player, "SPELL_AURA_APPLIED", name, r.npc) end)
                    At(token, when + 14, function() DemoCast(r.player, "SPELL_AURA_REMOVED", name, r.npc) end)
                    At(token, when + 19, function() DemoCast(r.player, "SPELL_AURA_APPLIED", name, r.npc) end)
                end
            end
        end
    end
    At(token, t0 + LENGTH, function()
        Live():EndEncounter(true)
        ns:Print("Practice over: the boss \"died\". The panel fades in a few seconds.")
        run = nil
    end)
end

-- Starts a practice run of a strategy (a saved one, or the board's draft).
function Practice:Start(s)
    if type(s) ~= "table" or not s.b then
        ns:Print("Open a strategy on the board (or name a boss) to practice it.")
        return false
    end
    local c = Live():GetCurrent()
    if c and c.engaged and not c.practice then
        ns:Print("Not during a real encounter.")
        return false
    end
    Live():Reset()
    local anyTracked = false
    for _, p in ipairs(s.p or {}) do
        for _, k in ipairs(p.k or {}) do
            if S().TrackKind(k) then anyTracked = true end
        end
    end
    if not anyTracked then
        ns:Print("This strategy has no tables the encounter helpers follow, so practice only shows your job. In the "
            .. "editor, open a table's gear menu > Track in fight (e.g. Interrupt rotation), or pick the boss "
            .. "abilities in its target cells.")
    end
    local a = self:Assign(s)
    c = Live():StartPractice(s, a)
    if not c then return false end
    run = { token = {}, boss = s.b, marks = {}, markNext = 1 }
    ns:Print("Practice: %s (\"%s\"). Your jobs are in the panel; demo players have the rest. When it's your turn, "
        .. "use your real interrupt / Misdirection / curse on a target dummy. Target mobs to see the marks. "
        .. "/cdl strat stop ends it.", c.name, s.n)
    Script(run.token)
    return true
end

function Practice:Stop()
    if not run and not (Live():GetCurrent() and Live():GetCurrent().practice) then return false end
    run = nil
    Live():Reset()
    ns:Print("Practice stopped.")
    return true
end

function Practice:IsRunning() return run ~= nil end

-- Practice marking: the targeted unit gets the plan's next raid mark (players and pets are left alone).
local function OnTarget()
    if not run then return end
    local c = Live():GetCurrent()
    if not (c and c.practice) then return end
    local guid = UnitGUID("target")
    if not guid or (UnitIsPlayer and UnitIsPlayer("target")) then return end
    if run.marks[guid] then return end
    if IsInGroup() and not (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then return end
    local order = Live():MarkOrder()
    if #order == 0 then return end
    local mark = order[(run.markNext - 1) % #order + 1]
    run.markNext = run.markNext + 1
    run.marks[guid] = mark
    SetRaidTarget("target", mark)
end

local function Slash(rest)
    local arg = Util.Trim(rest or "")
    if arg:lower() == "stop" then
        if not Practice:Stop() then ns:Print("No practice running.") end
        return
    end
    -- the board's strategy, else the named boss' first strategy
    local Board = ns.StrategyBoard
    local st = Board and Board.GetState and Board:GetState()
    local s = (Board and Board:IsShown() and st and st.strat) or nil
    if arg ~= "" then
        local want = arg:lower()
        for _, raid in ipairs(S():GetRaidTree()) do
            for _, b in ipairs(raid.bosses) do
                if b.name:lower():find(want, 1, true) then s = S():GetStrategies(b.ref)[1] or s end
            end
        end
    end
    if not s then
        ns:Print("Usage: open a strategy on the board, then /cdl strat practice (or /cdl strat practice <boss name>).")
        return
    end
    Practice:Start(s)
end

Practice.Slash = Slash

function Practice:OnInit()
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_TARGET_CHANGED")
    f:SetScript("OnEvent", OnTarget)
end
