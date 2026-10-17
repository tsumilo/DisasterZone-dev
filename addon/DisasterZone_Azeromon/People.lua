if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/People.lua", ...) then return end -- DisasterZone_Azeromon/People.lua
-- ns.AzeroPeople: people remember you (the "Azeroth Remembers" mockup, step 2).
--   Billy grows with your badges: at one he fishes with a rod of his own, at three his own Murkling (Gurgles) swims
--   by his bobber, at six he challenges you to a friendly battle (no blackout), his team just under yours.
--   Bard Willem plays the Lion's Pride in the evening and sings your ballad, built from your save: your first beast,
--   the badges you've won, your first shiny and your best catch.
--   Greetings by name: Goldshire's people notice what you do (how often you visit, what you buy, your badges, your
--   trades, your best fish) and greet you by name for it, once a day each, before their usual words.
-- Everything here is personal: it reads only your own save.
local addonName, ns = ...

local P = ns:NewModule("AzeroPeople")
local G = ns.Azero
local D = ns.AzeroData
local M = ns.AzeroMon

P.clock = nil                -- tests: server time

local function Now()
    if P.clock then return P.clock end
    return (GetServerTime and GetServerTime()) or (time and time()) or 0
end

local function Save() return G.save end

local function Table(key)
    local s = Save()
    if type(s[key]) ~= "table" then s[key] = {} end
    return s[key]
end

---------------------------------------------------------------------------
-- What the town notices
---------------------------------------------------------------------------

-- A purchase (G:Buy): how much of what, the last amount.
function P.NoteBuy(item, qty)
    if not Save() then return end
    local b = Table("bought")
    local e = type(b[item]) == "table" and b[item] or { n = 0 }
    e.n, e.last = e.n + qty, qty
    b[item] = e
end

-- A catch (Fishing.lua): the best fish so far (by what it sells for).
function P.NoteFish(item)
    local s, def = Save(), D.items[item]
    if not (s and def and def.fish) then return end
    local best = s.fishBest and D.items[s.fishBest]
    if not best or (def.sell or 0) > (best.sell or 0) then s.fishBest = item end
end

-- The thing bought most often (item id and its last amount), or nil.
function P.Usual()
    local best, n, last = nil, 0, 0
    for item, e in pairs(Save() and Save().bought or {}) do
        if type(e) == "table" and D.items[item] and e.n > n then best, n, last = item, e.n, e.last or 1 end
    end
    return best, last
end

-- The first shiny the player has (party first, then the box), or nil.
function P.FirstShiny()
    local s = Save()
    for _, list in ipairs({ s.party or {}, s.box or {} }) do
        for _, mon in ipairs(list) do if mon.shiny then return mon end end
    end
end

function P.FirstBeastName()
    local s = Save()
    local sp = s.flags and D.species[s.flags.starter or ""]
    if sp then return sp.name end
    local first = s.party and s.party[1]
    return first and D.species[first.sp] and D.species[first.sp].name or "beast"
end

---------------------------------------------------------------------------
-- Greetings by name
---------------------------------------------------------------------------

P.GREET_AFTER = 3            -- talks before someone uses your name

local function DayKey() return math.floor(Now() / 86400) end

-- npc id -> function(talks) returning a line (with {PLAYER}), or nil
P.GREETINGS = {
    clerk = function(n)
        local item, last = P.Usual()
        if n < P.GREET_AFTER or not item then return nil end
        local name = D.items[item].name
        return string.format("Back again, {PLAYER}? %s%s, as usual?", last > 1 and (last .. " ") or "a ",
            last > 1 and (name .. "s") or name)
    end,
    healer = function(n)
        local first = Save().party and Save().party[1]
        if n < P.GREET_AFTER or not first then return nil end
        return string.format("{PLAYER}! Your %s ate half my stew last time. I've hidden the rest.", M.Name(first))
    end,
    farmer = function() if G:BadgeCount() >= 2 then return "Billy hasn't stopped talking about you, {PLAYER}." end end,
    nightguard = function()
        if G:Flag("badge_nightwatch") and G:IsNight() then return "Quiet since you dealt with that thing in Darkshire, {PLAYER}." end
    end,
    guard = function() if G:Flag("badge_hogger") then return "Morning, {PLAYER}. Hogger's claw still on your belt?" end end,
    argus = function(n)
        local skill = ns.AzeroCraft and ns.AzeroCraft.Skill("mining")
        if skill and skill >= 50 then return "{PLAYER}! Your smelting's coming along. I can hear it from here." end
        if n >= P.GREET_AFTER then return "{PLAYER}! Bring me ore, bring me stories." end
    end,
    mallory = function(n)
        local skill = ns.AzeroCraft and ns.AzeroCraft.Skill("alchemy")
        if skill and skill >= 50 then return "{PLAYER}, you've the steady hands of a real alchemist now." end
        if n >= P.GREET_AFTER then return "{PLAYER}! Mind the eyebrows today." end
    end,
    leebrown = function()
        local best = Save().fishBest and D.items[Save().fishBest]
        if best then return string.format("{PLAYER}! Still telling everyone about that %s?", best.name) end
    end,
}

-- Talking to someone (Game.lua, before their script): count it, and greet by name once a day when they have
-- something to say about you.
function P.Greet(g, def)
    local id = def and def.id
    if not (id and Save()) then return end
    local talks = Table("talks")
    talks[id] = (tonumber(talks[id]) or 0) + 1
    local fn = P.GREETINGS[id]
    if not fn then return end
    local greeted = Table("greeted")
    if greeted[id] == DayKey() then return end
    local line = fn(talks[id])
    if not line then return end
    greeted[id] = DayKey()
    g:Say((G.NpcName(def) or def.name or "?") .. ": " .. line)
end

---------------------------------------------------------------------------
-- Billy
---------------------------------------------------------------------------

-- 0 dreams, 1 has a rod, 2 has Gurgles, 3 challenges you
function P.BillyStage()
    local n = G:BadgeCount()
    if n >= 6 then return 3 elseif n >= 3 then return 2 elseif n >= 1 then return 1 end
    return 0
end

D.trainers.billy = { name = "Billy Maclure", class = "farmer", prize = 80, team = {},
    intro = "Gurgles and me have been training every single day! Ready?",
    lose = "Aww... Next time, {PLAYER}. Next time!",
    win = "We won! WE WON! Gurgles, did you see that?" }

-- His team: Gurgles the Murkling and two more from Goldshire's woods, just under the player's best.
function P.BillyTeam()
    local top = 5
    for _, mon in ipairs(Save().party or {}) do top = math.max(top, mon.lvl or 5) end
    D.trainers.billy.team = { { "murkling", math.max(5, top - 1) }, { "owlet", math.max(5, top - 2) },
                              { "tuskling", math.max(5, top - 3) } }
    local team = G:TrainerTeam("billy")
    team[1].nick = "Gurgles"
    return team
end

function P.BillyTalk(g)
    local stage = P.BillyStage()
    if stage == 0 then
        g:Say("Billy Maclure: When I grow up I'm gonna tame a dragon whelp! Or a murloc! Mrgllglgl!")
    elseif stage == 1 then
        g:Say("Billy Maclure: Ma got me a rod, like yours, {PLAYER}! I fish with Lee Brown every afternoon.")
    elseif stage == 2 then
        g:Say("Billy Maclure: This is Gurgles! I hooked him in the pond, all by myself. He's mine!")
    elseif g:Flag("beat_billy") then
        g:Say("Billy Maclure: One day I'll beat you. Gurgles says so. Mrgl!")
    else
        g:Say("Billy Maclure: I've been training, {PLAYER}! Gurgles and me.")
        if not M.FirstUsable(g.save.party) then
            g:Say("Billy Maclure: Your beasts are all worn out! Rest them at the inn, then come back.")
            return
        end
        if not g:YesNo("Billy Maclure: Battle me? Please?") then
            g:Say("Billy Maclure: Aww. Tomorrow, then!")
            return
        end
        local def = g:TrainerDef("billy")
        g:Say("Billy Maclure: " .. def.intro)
        local result = g:RunBattle(P.BillyTeam(), "billy", { noBlackout = true })
        if result == "win" then
            g:SetFlag("beat_billy")
            g:Say("Billy Maclure: " .. g:Fmt(D.trainers.billy.lose))
        else
            g:HealParty()
            g:Say("Billy Maclure: " .. g:Fmt(D.trainers.billy.win))
            g:Say("Maybell Maclure (from the stall): Billy! Let them rest, now!")
        end
    end
end

---------------------------------------------------------------------------
-- The ballad
---------------------------------------------------------------------------

P.BADGE_VERSES = {
    hogger = { "They felled Hogger by the river when the Elwynn rain was grey,",
               "and Goldshire raised a cup to them before the end of day." },
    vancleef = { "They walked into the Deadmines where the Defias kept their gold,",
                 "and VanCleef fell beneath his ship, or so the tale is told." },
    nightwatch = { "In Darkshire, where the lamps went out, they stood against the dead,",
                   "and Stitches fell, and Darkshire rang its bells for them instead." },
    nesingwary = { "In Stranglethorn they hunted with old Hemet's hunting crew,",
                   "and every tiger in the vale knew {PLAYER}'s name too." },
    blackwater = { "They broke the Bloodsail captains on the shores of Booty Bay,",
                   "and Firallon's black sails were gone by break of day." },
    stonewatch = { "At Stonewatch Keep they beat Gath'Ilzogg's war drums down,",
                   "and Lakeshire mended up its bridge for the heroes of the town." },
    darkiron = { "Beneath the burning mountain, past the Black Forge and its flame,",
                 "the Emperor Thaurissan bowed down to {PLAYER}'s name." },
}

-- The ballad as couplets (each two lines), from the save.
function P.Ballad()
    local out = { { "Hear the tale of {PLAYER}, who left the Maclures' door,",
                    string.format("a %s at their heel and courage to the core.", P.FirstBeastName()) } }
    local won = {}
    for id, b in pairs(D.badges) do if G:Flag("badge_" .. id) and P.BADGE_VERSES[id] then won[#won + 1] = { id, b.order or 99 } end end
    table.sort(won, function(a, b) return a[2] < b[2] end)
    for _, w in ipairs(won) do out[#out + 1] = P.BADGE_VERSES[w[1]] end
    local shiny = P.FirstShiny()
    local fish = Save().fishBest and D.items[Save().fishBest]
    local spName = shiny and D.species[shiny.sp] and D.species[shiny.sp].name
    if spName and fish then
        out[#out + 1] = { string.format("A shiny %s, silver-bright, came to them in the reeds,", spName),
                          string.format("and the %s that they landed still hangs where Farley feeds.", fish.name) }
    elseif spName then
        out[#out + 1] = { string.format("A shiny %s, silver-bright, came to them in the reeds,", spName),
                          "and Goldshire tells it to this day to anyone who needs." }
    elseif fish then
        out[#out + 1] = { "And when the road was quiet, they would fish the Goldshire pond,",
                          string.format("and the %s that they landed is the one of which we're fond.", fish.name) }
    end
    if #won == 0 then
        out[#out + 1] = { "The road ahead is long for them, past every hill and tree,",
                          "so raise your cup to {PLAYER}, friends, and see what they will be!" }
    end
    return out
end

function P.BardTalk(g)
    g:Say("Bard Willem: A song? For you, {PLAYER}, I've been working on one. Ahem.")
    for _, c in ipairs(P.Ballad()) do g:Say(c[1] .. "\n" .. c[2]) end
    g:Say("Bard Willem: ...more verses when you've earned them. Off you go!")
end

-- For tests
P._Reset = function() end
