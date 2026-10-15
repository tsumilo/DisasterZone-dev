if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Fishing.lua", ...) then return end -- DisasterZone Games/Azeromon/Fishing.lua
-- ns.AzeroFish: Fishing, a secondary profession like the real one (it doesn't count toward the two trades).
--   Learn it from Lee Brown by Goldshire's pond, buy a Fishing Pole from Brog at the inn, face water and press
--   Space: the line goes out, the bobber floats, and when it dips (a "!" and the bite sound) press Space to hook it.
--   Too soon and nothing's on the hook; too late and it got away.
--   Each zone's water has its own catch (D.fishWaters, by the map's theme): fish, junk, now and then a Shiny
--   Bauble (a lure: faster bites for ten minutes), and sometimes a water beast that takes the bait - a wild battle.
--   Schools of fish (ripples on one stretch of shore, moving every 20 realm minutes, the same for the whole guild)
--   bite twice as fast and give the better fish.
--   Something big on the line (a water beast, or a water's prize fish: big = true) has to be reeled in: a marker
--   sweeps a bar while a gold patch drifts with the fish's pull; Space with the marker in the gold is a good pull.
--   REEL_NEED good pulls land it, REEL_MISSES misses (or REEL_TIME seconds) snap the line.
--   Fish feed beasts outside battle (a little HP; water beasts love it: twice as much) or sell at any shop.
-- Skill runs 1 - 175 like the others: Lee Brown teaches Apprentice and Journeyman, Old Man Heming on Booty Bay's
-- docks Expert. Water above your skill still bites, but most of what you hook gets away.
local addonName, ns = ...

local F = ns:NewModule("AzeroFish")
local G = ns.Azero
local D = ns.AzeroData
local C = ns.AzeroCraft

local ICON = "Interface\\Icons\\"

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

D.professions.fishing = { name = "Fishing", icon = ICON .. "Trade_Fishing", secondary = true, gather = "fish",
    trainer = "Lee Brown",
    howto = "A secondary trade: it doesn't count toward your two. Buy a Fishing Pole from Brog at the inn, face water and press Space to cast. When the bobber dips, press Space to hook it." }
D.professionOrder[#D.professionOrder + 1] = "fishing"

-- the fishing tiers (the same caps as the other trades); Lee Brown teaches the first two
F.TIERS = {
    journeyman = { teacher = "lee" },
    expert = { teacher = "heming" },
}
F.TRAINERS = {
    lee = { name = "Lee Brown", tiers = { "journeyman" },
            hello = "Quiet water, a good pole and patience. That's all fishing is. Well, and knowing when to pull.",
            done = "I've taught you all I know. Old Man Heming in Booty Bay teaches Expert, if you can stand his stories." },
    heming = { name = "Old Man Heming", tiers = { "expert" },
               hello = "The Bass and You, I call my lessons. Forty years on these docks. Expert fishing, up to 175.",
               done = "You fish as well as I do now. Don't tell anyone." },
}

local function Fish(name, icon, heal, sell, desc)
    return { name = name, price = 0, sell = sell, heal = heal, use = "heal", fish = true, icon = ICON .. icon,
             desc = desc .. string.format(" Restores %d HP to one beast (twice that to a water beast).", heal) }
end

local items = {
    fishingpole = { name = "Fishing Pole", price = 120, use = "tool", icon = ICON .. "INV_Fishingpole_02",
                    useText = "Face water and press Space to cast. Press Space again when the bobber dips.",
                    desc = "A simple pole and line. Face any water and press Space to fish." },
    smallfish = Fish("Raw Brilliant Smallfish", "INV_Misc_Fish_02", 10, 6, "A tiny, shiny fish of Elwynn's ponds."),
    mudsnapper = Fish("Raw Longjaw Mud Snapper", "INV_Misc_Fish_21", 18, 10, "It lives in the mud and tastes like it."),
    sicklyfish = Fish("Sickly Looking Fish", "INV_Misc_Fish_03", 5, 2, "It's... a fish. Technically."),
    catfish = Fish("Raw Bristle Whisker Catfish", "INV_Misc_Fish_07", 30, 16, "A whiskered catfish of the rivers."),
    blackmouth = Fish("Oily Blackmouth", "INV_Misc_Fish_05", 20, 18, "An oily coastal fish. Alchemists like its oil."),
    albacore = Fish("Raw Rainbow Fin Albacore", "INV_Misc_Fish_13", 35, 20, "A bright fish of the open sea."),
    mithrilhead = Fish("Raw Mithril Head Trout", "INV_Misc_Fish_08", 50, 30, "A trout with a head like polished metal."),
    rockscale = Fish("Raw Rockscale Cod", "INV_Misc_Fish_14", 45, 30, "A heavy cod of the southern coast."),
    firefin = Fish("Firefin Snapper", "INV_Misc_Fish_16", 40, 35, "Its fins glow like embers."),
    redgill = Fish("Raw Redgill", "INV_Misc_Fish_23", 60, 40, "A big red fish of the mountain lakes."),
    boot = { name = "Soggy Boot", price = 0, sell = 1, use = "junk", icon = ICON .. "INV_Boots_05",
             useText = "It's a boot. Full of water. A shop might take it off your hands.",
             desc = "Someone lost a boot. You found it. Nobody wins." },
    bauble = { name = "Shiny Bauble", price = 0, sell = 25, use = "lure", minutes = 10, icon = ICON .. "INV_Misc_Orb_03",
               desc = "A lure: tie it to your line and for 10 minutes fish bite faster and better (+25 skill).",
               used = "You tie the Shiny Bauble to your line. For 10 minutes, fish bite faster and better." },
}
local ORDER = { "fishingpole", "bauble", "smallfish", "mudsnapper", "sicklyfish", "catfish", "blackmouth", "albacore",
                "mithrilhead", "rockscale", "firefin", "redgill", "boot" }
for id, def in pairs(items) do D.items[id] = def end
for _, id in ipairs(ORDER) do D.itemOrder[#D.itemOrder + 1] = id end
D.shopStock[#D.shopStock + 1] = "fishingpole"          -- Brog at the Lion's Pride (and every shop without a stock list)

-- What each zone's water gives, by the map's theme: the skill it wants, then weights. `skill` on an entry: only
-- once the player's skill reaches it. `beast`: a wild battle with that species (at the map's own levels).
D.fishWaters = {
    elwynn = { skill = 1, catch = {
        { item = "smallfish", weight = 42 }, { item = "mudsnapper", weight = 24 }, { item = "sicklyfish", weight = 10 },
        { item = "boot", weight = 8 }, { item = "bauble", weight = 4 }, { beast = "murkling", weight = 12, min = 4, max = 7 } } },
    westfall = { skill = 25, catch = {
        { item = "mudsnapper", weight = 30 }, { item = "catfish", weight = 22, skill = 50, big = true }, { item = "blackmouth", weight = 18 },
        { item = "sicklyfish", weight = 8 }, { item = "boot", weight = 8 }, { item = "bauble", weight = 4 },
        { beast = "coastrunner", weight = 10 } } },
    duskwood = { skill = 50, catch = {
        { item = "catfish", weight = 36 }, { item = "mudsnapper", weight = 18 }, { item = "sicklyfish", weight = 14 },
        { item = "boot", weight = 12 }, { item = "bauble", weight = 6 }, { beast = "lurkling", weight = 14 } } },
    jungle = { skill = 100, catch = {
        { item = "rockscale", weight = 26 }, { item = "albacore", weight = 22 }, { item = "firefin", weight = 14, skill = 120, big = true },
        { item = "blackmouth", weight = 14 }, { item = "boot", weight = 8 }, { item = "bauble", weight = 4 },
        { beast = "saltwatercroc", weight = 12 } } },
    redridge = { skill = 100, catch = {
        { item = "mithrilhead", weight = 30 }, { item = "catfish", weight = 18 }, { item = "redgill", weight = 16, skill = 140, big = true },
        { item = "boot", weight = 10 }, { item = "bauble", weight = 6 }, { beast = "netter", weight = 20 } } },
}
D.fishWaters.arena = D.fishWaters.jungle

F.WINDOW = 1.1           -- seconds the bobber stays under: press Space in time
F.WAIT = { 3.5, 9 }      -- seconds before a bite (a school: half that; a lure: 0.6 of it)
F.SCHOOL_MINUTES = 20    -- a school moves on every 20 minutes (realm time)
F.REEL_NEED, F.REEL_MISSES, F.REEL_TIME = 3, 2, 12
F.REEL_SWEEP = 0.75      -- the marker's sweeps a second (a beast: faster), there and back
F.REEL_ZONE = 0.24       -- the gold patch's width, as a share of the bar (a beast: narrower)
F.rng, F.clock = nil, nil    -- tests

local function Rng(a, b) return (F.rng or G.rng or math.random)(a, b) end
local function Now()
    if F.clock then return F.clock end
    return (GetServerTime and GetServerTime()) or (time and time()) or 0
end

---------------------------------------------------------------------------
-- Water, schools
---------------------------------------------------------------------------

-- The catch table for a map's water (nil: nothing lives in it).
function F.WaterOf(m)
    if not m then return nil end
    return D.fishWaters[m.def.fishing or m.def.theme or "elwynn"]
end

-- The water tiles a player can fish from land: next to a walkable tile. Cached per compiled map.
function F.Shore(m)
    if m.shore then return m.shore end
    local list = {}
    for y = 0, m.h - 1 do
        for x = 0, m.w - 1 do
            if m.water[m.key(x, y)] then
                for _, d in pairs(G.DIRS) do
                    local nx, ny = x + d[1], y + d[2]
                    local k = m.key(nx, ny)
                    if nx >= 0 and ny >= 0 and nx < m.w and ny < m.h and not m.water[k] and not m.solid[k] then
                        list[#list + 1] = { x = x, y = y }
                        break
                    end
                end
            end
        end
    end
    m.shore = list
    return list
end

-- The school of fish on this map right now (a shore water tile), or nil.
function F.School(m)
    if not F.WaterOf(m) then return nil end
    local shore = F.Shore(m)
    if #shore == 0 then return nil end
    local slot = math.floor(Now() / (F.SCHOOL_MINUTES * 60))
    local h = 0
    for i = 1, #m.id do h = (h * 31 + m.id:byte(i)) % 1000003 end
    return shore[((slot * 2654435761 + h) % 4294967296) % #shore + 1]
end

function F.NearSchool(m, x, y)
    local s = F.School(m)
    return s and math.abs(s.x - x) <= 1 and math.abs(s.y - y) <= 1 or false
end

-- Is the player facing fishable water? Returns its tile.
function F.Facing(g)
    local m, s = g.map, g.save
    if not (m and s) then return nil end
    local d = G.DIRS[s.face]
    local x, y = s.x + d[1], s.y + d[2]
    if m.water[m.key(x, y)] then return x, y end
end

---------------------------------------------------------------------------
-- Skill
---------------------------------------------------------------------------

-- Skill-ups like the real game's: every catch at first, rarer and rarer as the skill passes the water's.
function F.SkillUpChance(skill, water)
    local over = skill - (water.skill or 1)
    if over < 25 then return 100 end
    return math.max(5, math.floor(100 - (over - 25) * 1.4))
end

function F:SkillUp(water)
    local skill = C.Skill("fishing")
    if not skill or skill >= C.Cap("fishing") then return nil end
    if Rng(1, 100) > F.SkillUpChance(skill, water) then return nil end
    G.save.prof.fishing = skill + 1
    G:Emit("skillup", { prof = "fishing", skill = skill + 1 })
    return skill + 1
end

-- How likely a hooked catch gets away: none at the water's skill, most when far below it.
function F.EscapeChance(skill, water)
    local short = (water.skill or 1) - skill
    if short <= 0 then return 0 end
    return math.min(90, short * 2 + 10)
end

function F.LureOn()
    local s = G.save
    return s and tonumber(s.lureUntil) and Now() < s.lureUntil or false
end

-- A catch from `water` for this skill: an entry of water.catch. A school gives the better half of the table a
-- second roll (the first entry that isn't junk wins).
function F.Roll(water, skill, school)
    local function roll()
        local total, list = 0, {}
        for _, e in ipairs(water.catch) do
            if not e.skill or skill >= e.skill then
                list[#list + 1] = e
                total = total + e.weight
            end
        end
        local r = Rng(1, total)
        for _, e in ipairs(list) do
            r = r - e.weight
            if r <= 0 then return e end
        end
        return list[#list]
    end
    local e = roll()
    if school and e.item and (D.items[e.item].use ~= "heal" or e.item == "sicklyfish") then e = roll() end
    return e
end

-- The level of a hooked beast: the entry's own, else the map's wild levels.
function F.BeastLevel(m, e)
    if e.min then return Rng(e.min, e.max or e.min) end
    local lo, hi
    for _, list in ipairs({ m.def.encounters or {}, m.def.coastEncounters or {} }) do
        for _, x in ipairs(list) do
            lo = math.min(lo or x.min, x.min)
            hi = math.max(hi or x.max, x.max)
        end
    end
    return Rng(lo or 5, hi or lo or 5)
end

---------------------------------------------------------------------------
-- Casting (a script: G:Run)
---------------------------------------------------------------------------

-- What pressing Space facing water says (InteractHint).
function F.Hint()
    if not C.Skill("fishing") then return "Fish  (needs Fishing)" end
    if (G.save.bag.fishingpole or 0) < 1 then return "Fish  (needs a Fishing Pole)" end
    return "Fish"
end

function F:Cast(g, x, y)
    local skill = C.Skill("fishing")
    if not skill then
        g:Say("Fish swim lazily below. Lee Brown by Goldshire's pond teaches Fishing.")
        return
    end
    if (g.save.bag.fishingpole or 0) < 1 then
        g:Say("You need a Fishing Pole. Brog Hamfist at the Lion's Pride sells them.")
        return
    end
    local water = F.WaterOf(g.map)
    if not water then
        g:Say("Nothing lives in this water.")
        return
    end
    local school, lure = F.NearSchool(g.map, x, y), F.LureOn()
    local wait = Rng(F.WAIT[1] * 10, F.WAIT[2] * 10) / 10
    if school then wait = wait / 2 end
    if lure then wait = wait * 0.6 end
    g:Sfx("fishcast")
    local r = g:Wait({ kind = "fish", x = x, y = y, t = 0, bite = wait, window = F.WINDOW, school = school })
    if r == "reel" then                     -- the player reeled in (B or walking off)
        g:Sfx("fishreel")
        return
    elseif r == "early" then
        g:Sfx("fishreel")
        g:Say("You reel in too soon. Nothing on the hook.")
        return
    elseif r ~= "hook" then
        g:Say("The bobber settles. It got away.")
        return
    end
    g:Sfx("fishreel")
    local eff = skill + (lure and 25 or 0)
    if Rng(1, 100) <= F.EscapeChance(eff, water) then
        g:Say(string.format("Something tugs hard... and slips the hook. (These waters want Fishing %d.)", water.skill))
        return
    end
    local e = F.Roll(water, eff, school)
    local beast = e.beast and ns.AzeroMon.FirstUsable(g.save.party)
    if beast or e.big then
        local r = g:Wait({ kind = "reel", t = 0, hits = 0, misses = 0, beast = beast and true or false,
                           sweep = F.REEL_SWEEP * (beast and 1.3 or 1), zone = F.REEL_ZONE * (beast and 0.8 or 1) })
        if r ~= "landed" then
            g:Sfx("fishreel")
            g:Say(r == "letgo" and "You let it go." or "The line snaps! Whatever it was, it got away.")
            return
        end
    end
    local rose = F:SkillUp(water)
    local up = rose and string.format("\nYour skill in Fishing has increased to %d.", rose) or ""
    if beast then
        local sp = D.species[e.beast]
        g:Emit("fish", { beast = e.beast })
        g:Say(string.format("Something big is on the line...\nIt's a wild %s!%s", sp and sp.name or "beast", up))
        g:WildBattle(e.beast, F.BeastLevel(g.map, e))
        return
    end
    local item = e.item or "smallfish"
    local bag = g.save.bag
    bag[item] = (bag[item] or 0) + 1
    g:Emit("fish", { item = item })
    g:Sfx("item")
    g:Say(string.format("You caught a %s!%s", D.items[item].name, up))
end

-- A lure from the bag (outside battle). Returns the message.
function F:UseLure(item)
    local def = D.items[item]
    local bag = G.save.bag
    if not def or (bag[item] or 0) < 1 then return "You don't have that." end
    bag[item] = bag[item] - 1
    if bag[item] <= 0 then bag[item] = nil end
    G.save.lureUntil = Now() + (def.minutes or 10) * 60
    G:Sfx("equip")
    return def.used
end

-- Fish heal like potions; a water beast eats twice as much (UseItemOutside asks).
function F.FeedAmount(def, mon)
    local sp = D.species[mon.sp]
    if def.fish and sp and sp.type == "WATER" then return def.heal * 2, true end
    return def.heal, false
end

---------------------------------------------------------------------------
-- Trainers (map scripts)
---------------------------------------------------------------------------

function F:TrainerTalk(g, id)
    local t = F.TRAINERS[id]
    g:Say(t.name .. ": " .. t.hello)
    local skill = C.Skill("fishing")
    if not skill then
        if id ~= "lee" then
            g:Say(t.name .. ": Learn the basics from Lee Brown in Goldshire first. Then come see me.")
            return
        end
        if not g:YesNo(string.format("Learn Fishing for %s? It doesn't count toward your two trades.", D.Money(D.PROFESSION_FEE))) then
            g:Say(t.name .. ": Come back when the fish are calling.")
            return
        end
        local ok, msg = C:Learn("fishing")
        g:Say(msg)
        if ok then
            g:Say(t.name .. ": Brog at the inn sells poles. Face the water, cast, and pull the moment the bobber dips.")
        end
        return
    end
    for _, tierId in ipairs(t.tiers) do
        local tier
        for _, x in ipairs(D.skillTiers) do if x.id == tierId then tier = x end end
        if C.Tier("fishing").cap < tier.cap then
            if skill < tier.needs then
                g:Say(string.format("%s: Come back at Fishing %d and I'll teach you %s.", t.name, tier.needs, tier.name))
                return
            end
            if not g:YesNo(string.format("Train %s Fishing (up to %d) for %s?", tier.name, tier.cap, D.Money(tier.fee))) then
                g:Say(t.name .. ": The fish will wait.")
                return
            end
            if G.save.money < tier.fee then
                g:Say("You can't afford the training (" .. D.Money(tier.fee) .. ").")
                return
            end
            G.save.money = G.save.money - tier.fee
            if type(G.save.profTier) ~= "table" then G.save.profTier = {} end
            G.save.profTier.fishing = tier.id
            G:Emit("tier", { prof = "fishing", tier = tier.id })
            g:Say(string.format("You are now a %s in Fishing! Your skill can rise to %d.", tier.name, tier.cap))
            return
        end
    end
    g:Say(t.name .. ": " .. t.done)
end

function G:FishingTrainer(id) return F:TrainerTalk(self, id) end

---------------------------------------------------------------------------
-- The waiting bobber (G:Update and the UI's keys)
---------------------------------------------------------------------------

-- Every frame while a line is out: the bite comes, then the window closes.
function F:Tick(g, p, dt)
    p.t = p.t + dt
    if not p.biting and p.t >= p.bite then
        p.biting = true
        g:Sfx("fishbite")
    elseif p.biting and p.t >= p.bite + p.window then
        g:Advance("late")
    end
end

-- Reeling: where the marker (0 - 1) and the middle of the gold patch are, `t` seconds in.
function F.ReelAt(p, t)
    local ph = (t * p.sweep) % 2
    local pos = ph < 1 and ph or 2 - ph                       -- there and back along the bar
    local mid = 0.5 + 0.3 * math.sin(t * 0.9) + 0.08 * math.sin(t * 2.3)
    return pos, mid
end

function F:ReelTick(g, p, dt)
    p.t = p.t + dt
    if p.flash then p.flash = p.flash - dt if p.flash <= 0 then p.flash = nil end end
    if p.t >= F.REEL_TIME then g:Advance("snapped") end
end

-- Space: a pull. In the gold it counts; outside it's a miss.
function F:ReelKey(g, p, key)
    if key == "B" then g:Advance("letgo") return end
    if key ~= "A" then return end
    local pos, mid = F.ReelAt(p, p.t)
    if math.abs(pos - mid) <= p.zone / 2 then
        p.hits, p.flash, p.good = p.hits + 1, 0.25, true
        g:Sfx("fishreel")
        if p.hits >= F.REEL_NEED then g:Advance("landed") end
    else
        p.misses, p.flash, p.good = p.misses + 1, 0.25, false
        g:Sfx("bump")
        if p.misses >= F.REEL_MISSES then g:Advance("snapped") end
    end
end

-- A key while the line is out: Space hooks (or reels in too soon), back reels in.
function F:Key(g, p, key)
    if key == "A" then
        g:Advance(p.biting and "hook" or "early")
    elseif key == "B" or key == "dir" then
        g:Advance("reel")
    end
end

F._Now = Now
