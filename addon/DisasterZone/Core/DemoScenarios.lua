if DisasterZoneBoot and DisasterZoneBoot.Run("Core/DemoScenarios.lua", ...) then return end -- DisasterZone: Core/DemoScenarios.lua
-- Demo scenarios (1.3.5, the user: the demo should show the guild loot rules' cases instead of random rolls). Each
-- scenario stages one roll on the demo raid exactly: who takes part (the cast; nobody else shows in the roll), their
-- list for the item (a snapshot tier), attendance, raids since loot, longest use, what they roll and who the demo
-- council votes for. A chat line says what to look at and which Council > Rules choice changes the outcome.
-- The overrides only touch the cast and end with the next scenario, a plain demo roll or demo mode going off.
-- Settings > Help > Demo mode > Moments (Core/DemoParts.lua registers each as a moment) and /dz demo <scenario> run
-- them.
local addonName, ns = ...

local Demo = ns.Demo
local Util = ns.Util

local tonumber, pairs, ipairs, type = tonumber, pairs, ipairs, type

local BRACERS, DST, TOKEN = 30687, 28830, 29767   -- Ravager's Bracers, Dragonspine Trophy, Leggings of the Fallen Defender
local VOTERS = { "Aldrin", "Caelith", "Isolde" }   -- the demo's officers and class lead (demo votes always count)

-- cast rows: { name, tier (1 BiS, 2 Alt, 3 OS, 4 not on a list), attendance %, raids since loot, roll (nil = none,
-- false = pass), extra = { long = phases of longest use } }; votes = { voter = candidate }
Demo.SCENARIOS = {
    { key = "split", label = "Split vote", item = BRACERS,
      desc = "Three players get one vote each and only one of them rolled.",
      hint = "Votes split three ways and only Orinel rolled. Council > Rules > When votes split: Highest roll "
          .. "suggests Orinel, Council picks suggests nobody.",
      cast = { { "Orinel", 4, 60, 5, 93 }, { "Brakka", 4, 88, 1 }, { "Quillon", 3, 14, 5 }, { "Kaelyn", 4, 78, 0, 98 },
               { "Caelith", 3, 100, 1, 27 }, { "Mirabel", 4, 75, 5, 8 } },
      votes = { Aldrin = "Orinel", Caelith = "Brakka", Isolde = "Quillon" } },
    { key = "absent", label = "Popular but absent", item = BRACERS,
      desc = "The most-voted player rarely comes to raids.",
      hint = "Quillon has the most votes but 14% attendance. Set Council > Rules > Attendance floor to 50%: his votes "
          .. "stop counting and Caelith is suggested.",
      cast = { { "Quillon", 1, 14, 6, 71 }, { "Caelith", 1, 95, 2, 64 }, { "Elowen", 2, 100, 1, 90 },
               { "Mirabel", 4, 75, 4, 40 } },
      votes = { Aldrin = "Quillon", Isolde = "Quillon", Caelith = "Caelith" } },
    { key = "dry", label = "Dry streak vs fresh loot", item = BRACERS,
      desc = "No votes yet: a player six raids without loot rolled low, one who looted last week rolled high.",
      hint = "No votes yet, all on their BiS list. Then: Highest roll suggests Kaelyn (88); pick Council > Rules > "
          .. "Then, among them: Driest and Grimtusk (6 raids without loot) goes first.",
      cast = { { "Grimtusk", 1, 92, 6, 22 }, { "Kaelyn", 1, 85, 0, 88 }, { "Elowen", 1, 100, 3, 51 },
               { "Orinel", 4, 60, 5, 97 } },
      votes = {} },
    { key = "longest", label = "Longest use", item = BRACERS,
      desc = "Three BiS players: one keeps the item for four phases, the others replace it soon.",
      hint = "Turn on Council > Rules > Longest use: Aldrin keeps it on his list for 4 phases and goes first. Off, "
          .. "Brakka's 79 wins.",
      cast = { { "Aldrin", 1, 100, 3, 35, { long = 4 } }, { "Brakka", 1, 88, 1, 79, { long = 1 } },
               { "Caelith", 1, 100, 1, 60, { long = 2 } } },
      votes = {} },
    { key = "class", label = "Wrong class", item = TOKEN,
      desc = "A shaman gets two votes for a Warrior / Priest / Druid token.",
      hint = "Kaelyn is a shaman: she can't use this token, so her two votes don't count and she sits with the "
          .. "passes. Aldrin (BiS) is suggested.",
      cast = { { "Kaelyn", 1, 85, 4, 66 }, { "Aldrin", 1, 100, 2, 45 }, { "Isolde", 2, 88, 1, 70 },
               { "Quillon", 4, 80, 0, 92 } },
      votes = { Aldrin = "Kaelyn", Caelith = "Kaelyn", Isolde = "Aldrin" } },
    { key = "prized", label = "Prized: you qualify", item = DST,
      desc = "A prized item, and you meet its rules: its full roll window.",
      hint = "A prized item: you meet its rules (demo), so you get its roll window. Rogues and hunters come first by "
          .. "its spec order; the council decides, no rolls.",
      cast = { { "Grimtusk", 1, 92, 2, 55 }, { "Elowen", 2, 100, 0, 81 }, { "Brakka", 4, 88, 1, 30 },
               { "Mirabel", 4, 43, 4, 12 } },
      votes = { Aldrin = "Grimtusk" } },
    { key = "prizedno", label = "Prized: you don't qualify", item = DST, meFails = true,
      desc = "The same prized item, but this time you don't meet its rules.",
      hint = "You don't meet this prized item's rules: no roll window, a notice says why. Council > Rules > Prized: "
          .. "not qualified can show the window anyway.",
      cast = { { "Grimtusk", 1, 92, 2, 55 }, { "Elowen", 2, 100, 0, 81 } },
      votes = {} },
    { key = "plain", label = "Plain roll (no council)", item = BRACERS, plain = true,
      desc = "The raid rolls without the loot council.",
      hint = "Without the loot council the highest roll wins: BiS lists, votes and attendance don't count.",
      cast = { { "Caelith", 1, 100, 1, 41 }, { "Kaelyn", 4, 78, 0, 96 }, { "Orinel", 4, 60, 5, 63 },
               { "Elowen", 2, 100, 0 } },
      votes = {} },
}

local active    -- { def, byKey = { [key] = row }, sid }

local function Realm()
    return Util.GetPlayerRealm and Util.GetPlayerRealm() or ""
end

local function K(name)
    local r = Realm()
    return (r ~= "" and (name .. "-" .. r)) or name
end

function Demo:GetScenario(key)
    for _, d in ipairs(self.SCENARIOS) do
        if d.key == key then return d end
    end
end

function Demo:GetActiveScenario() return active and active.def or nil end

function Demo:ClearScenario()
    active = nil
end

-- A cast player's staged value ("att", "dry", "long"), or nil (not in the scenario).
function Demo:Override(key, field)
    if not active or not self:IsEnabled() or type(key) ~= "string" then return nil end
    local row = active.byKey[key]
    if not row then return nil end
    if field == "att" then return row[3] end
    if field == "dry" then return row[4] end
    if field == "long" then return row[6] and row[6].long or nil end
    return nil
end

-- In this scenario I don't meet the prized item's rules.
function Demo:MeFailsPrized()
    return active and active.def.meFails and self:IsEnabled() or false
end

local function BossRefOf(itemID)
    local db = ns.ItemDB
    for _, raid in ipairs(db and db:GetRaids() or {}) do
        for _, boss in ipairs(raid.bosses or {}) do
            for _, id in ipairs(boss.items or {}) do
                if id == itemID then return db:GetBossRef(raid.key .. ":" .. boss.key) end
            end
        end
    end
end

-- Stages and starts scenario key. Returns true, or false + why.
function Demo:RunScenario(key)
    local def = self:GetScenario(key)
    if not def then return false, "no such scenario" end
    if not self:IsEnabled() then self:SetEnabled(true) end
    if not self:IsEnabled() then return false, "demo mode could not be turned on" end
    local R, L = ns.Roll, ns.Loot
    if not (R and R.Start and L and L.HandleDrop and L.GetHistory) then return false, "rolls are not available" end
    local a = R.GetActive and R:GetActive()
    if a and a.demo and R.End then R:End(a.id) end
    local ref = BossRefOf(def.item)
    if not ref then return false, "the item is not in the loot data" end
    local byKey = {}
    for _, row in ipairs(def.cast) do byKey[K(row[1])] = row end
    active = { def = def, byKey = byKey, pending = true }
    ns:Fire("RAIDLOG_CHANGED")   -- (attendance / dry streak caches: the staged values)
    local me = Util.PlayerKey()
    L:HandleDrop({ s = "DEMO-" .. def.key .. "-" .. tostring(GetTime()), b = ref.key, i = { def.item },
                   ts = GetServerTime(), test = true }, me)
    local hist = L:GetHistory()
    local drop = type(hist) == "table" and hist[#hist]
    if type(drop) ~= "table" then return false, "the drop did not open" end
    local ok, err = pcall(R.Start, R, def.item, drop)
    if not ok then return false, tostring(err) end
    ns:Print("|cffffd100Demo: %s.|r %s", def.label, def.hint)
    return true
end

-- Demo:SimulateRolls hands a roll over here while a scenario is waiting for it: the staged rows, rolls and votes.
function Demo:RunScenarioRolls(session)
    local R = ns.Roll
    if not (active and active.pending and R) then return nil end
    active.pending = false
    active.sid = session.id
    local def = active.def
    local id = session.id
    session.demoCast = {}
    local me = Util.PlayerKey()
    if me then session.demoCast[me] = true end
    session.snap = session.snap or {}
    if def.plain then session.plain = true end
    local fmt = type(RANDOM_ROLL_RESULT) == "string" and RANDOM_ROLL_RESULT ~= "" and RANDOM_ROLL_RESULT
        or "%s rolls %d (%d-%d)"
    local function StillOpen()
        local cur = R.GetActive and R:GetActive()
        return self:IsEnabled() and cur ~= nil and cur.id == id
    end
    for i, row in ipairs(def.cast) do
        local key = K(row[1])
        local tier = row[2]
        session.demoCast[key] = true
        session.snap[key] = { tier = tier, which = (tier == 2 and "alt") or (tier <= 3 and "main") or nil, phase = 1,
                              os = (tier == 3) or nil, obtained = false, awarded = false }
        local roll = row[5]
        local delay = 1.2 + i * 0.7
        if roll == false then
            Util.After(delay, function() if StillOpen() then R:OnResponse(key, id, "pass") end end)
        elseif tonumber(roll) then
            local line = string.format(fmt, Util.ShortName(key), roll, 1, 100)
            Util.After(delay, function() if StillOpen() then R:OnSystemMessage(line) end end)
        end
    end
    local n = 0
    for voter, cand in pairs(def.votes or {}) do
        n = n + 1
        local v, c = K(voter), K(cand)
        session.demoCast[c] = true
        Util.After(4 + n * 0.9, function() if StillOpen() and R.OnDemoVote then R:OnDemoVote(v, id, c) end end)
    end
    ns:Fire("ROLL_UPDATED", id)   -- (the rows were drawn before the script: redraw with the cast only)
    return #def.cast
end

ns:On("DEMO_TOGGLED", function(on) if not on then active = nil end end)

---------------------------------------------------------------------------
-- /dz demo <scenario> (Demo.lua's slash hands unknown words here)
---------------------------------------------------------------------------
function Demo:ScenarioSlash(word)
    if not word or word == "" then return false end
    if word == "list" or word == "scenarios" then
        ns:Print("Demo scenarios (/dz demo <name>):")
        for _, d in ipairs(self.SCENARIOS) do ns:Print("  |cffffd100%s|r - %s", d.key, d.desc) end
        return true
    end
    if not self:GetScenario(word) then return false end
    local ok, err = self:RunScenario(word)
    if not ok then ns:Print("Demo scenario not started: %s", tostring(err)) end
    return true
end
