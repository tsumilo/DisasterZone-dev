-- CDLoot Games/Azeromon/Crafting.lua
-- ns.AzeroCraft: professions, like the real ones.
--   Gathering: Herbalism and Mining. Herb and ore nodes stand on the maps (def.nodes); A on one gathers it, and it
--              grows back RESPAWN seconds later (per player, on realm time) - sometimes as another herb of the map.
--   Crafting:  Alchemy (anywhere), Mining's Smelting (at a forge) and Blacksmithing (at an anvil), from recipes.
--   Gear:      Blacksmithing makes gear a beast wears, one piece per slot (D.gearSlots: claws, shoulders, chest,
--              wrists, waist); Alchemy makes elixirs (a stat up in battle), potions and flasks (a bonus for the
--              beast's next battles, shown as a sixth slot).
-- Skill runs 1 - D.SKILL_MAX. A node or recipe is orange (always a skill-up) until 10 points past its level, yellow
-- (75%) until 20, green (25%) until 35, then grey (nothing) - the real game's colours.
-- Everything below is data: add a herb, a recipe or a piece of gear by adding a line.
local addonName, ns = ...

local C = ns:NewModule("AzeroCraft")
local G = ns.Azero
local D = ns.AzeroData
local M = ns.AzeroMon

local ICON = "Interface\\Icons\\"

---------------------------------------------------------------------------
-- Data: professions, trainers, resources
---------------------------------------------------------------------------

D.SKILL_MAX = 100
D.PROFESSION_FEE = 50
D.MAX_PROFESSIONS = 2          -- like the real game: forget one to learn another

D.professions = {
    herbalism = { name = "Herbalism", icon = ICON .. "Trade_Herbalism", gather = "herb", trainer = "Alchemist Mallory",
                  howto = "Herbs grow wild on the roads out of town. Face one, or stand on it, and press Space to pick it." },
    alchemy = { name = "Alchemy", icon = ICON .. "Trade_Alchemy", trainer = "Alchemist Mallory",
                howto = "Brew from PROFESSIONS in the menu, wherever you are." },
    mining = { name = "Mining", icon = ICON .. "Trade_Mining", gather = "ore", trainer = "Smith Argus",
               howto = "Face an ore vein (a rock with coloured specks) and press Space to mine it. Smelt the ore into bars at a forge." },
    blacksmithing = { name = "Blacksmithing", icon = ICON .. "Trade_BlackSmithing", trainer = "Smith Argus",
                      howto = "Work your bars into gear for your beasts at an anvil." },
}
D.professionOrder = { "herbalism", "alchemy", "mining", "blacksmithing" }

D.craftTrainers = {
    argus = { name = "Smith Argus", teaches = { "mining", "blacksmithing" },
              hello = "Copper from the hills, fire from the forge. Every tamer's beast deserves a good bit of armour.",
              done = "You know all I can teach. The rest is hammer and patience." },
    mallory = { name = "Alchemist Mallory", teaches = { "herbalism", "alchemy" },
                hello = "Peacebloom, Silverleaf, a steady hand... that's half of alchemy. The other half is not blowing up.",
                done = "You know all I can teach. Go on, practise - and mind your eyebrows." },
}

-- kind, the skill a node needs, what one gives (item = the resource's own id unless set), and a sometimes-extra
D.resources = {
    peacebloom = { name = "Peacebloom", kind = "herb", skill = 1, yield = { 1, 2 }, tile = "node_peacebloom" },
    silverleaf = { name = "Silverleaf", kind = "herb", skill = 1, yield = { 1, 3 }, tile = "node_silverleaf" },
    earthroot = { name = "Earthroot", kind = "herb", skill = 15, yield = { 1, 2 }, tile = "node_earthroot" },
    mageroyal = { name = "Mageroyal", kind = "herb", skill = 50, yield = { 1, 2 }, tile = "node_mageroyal" },
    briarthorn = { name = "Briarthorn", kind = "herb", skill = 70, yield = { 1, 2 }, tile = "node_briarthorn" },
    copper = { name = "Copper Vein", kind = "ore", skill = 1, yield = { 1, 3 }, item = "copperore",
               extra = { item = "roughstone", chance = 50 }, tile = "node_copper" },
    tin = { name = "Tin Vein", kind = "ore", skill = 50, yield = { 1, 2 }, item = "tinore",
            extra = { item = "coarsestone", chance = 50 }, tile = "node_tin" },
}

---------------------------------------------------------------------------
-- Data: items (icons from Wowhead TBC)
---------------------------------------------------------------------------

-- The gear slots, in the fixed order bonuses are applied (the same on every client: player battles).
-- inv = the character sheet's slot whose empty icon the gear page shows.
D.gearSlots = {
    { id = "claws", name = "Claws", inv = "MainHandSlot", fallback = "MainHand" },
    { id = "shoulders", name = "Shoulders", inv = "ShoulderSlot", fallback = "Shoulder" },
    { id = "chest", name = "Chest", inv = "ChestSlot", fallback = "Chest" },
    { id = "wrists", name = "Wrists", inv = "WristSlot", fallback = "Wrists" },
    { id = "waist", name = "Waist", inv = "WaistSlot", fallback = "Waist" },
}

local function Mat(name, icon, desc) return { name = name, price = 0, use = "material", icon = ICON .. icon, desc = desc } end

local items = {
    -- herbs, ore, stone, bars
    peacebloom = Mat("Peacebloom", "INV_Misc_Flower_02", "A common flower of Elwynn. Alchemists use it in healing potions."),
    silverleaf = Mat("Silverleaf", "INV_Misc_Herb_10", "A pale herb found almost everywhere. Every alchemist's first ingredient."),
    earthroot = Mat("Earthroot", "INV_Misc_Herb_07", "A thick root that grows near stones. Brewed for strength."),
    mageroyal = Mat("Mageroyal", "INV_Jewelry_Talisman_03", "A violet flower of Westfall, prized for restoring potions."),
    briarthorn = Mat("Briarthorn", "INV_Misc_Root_01", "A thorny bramble. Stronger potions need it."),
    copperore = Mat("Copper Ore", "INV_Ore_Copper_01", "Smelt it at a forge into Copper Bars."),
    tinore = Mat("Tin Ore", "INV_Ore_Tin_01", "Smelt it at a forge into Tin Bars."),
    roughstone = Mat("Rough Stone", "INV_Stone_06", "Found while mining copper. Blacksmiths grind it into sharpening stones."),
    coarsestone = Mat("Coarse Stone", "INV_Stone_09", "Found while mining tin. Harder than Rough Stone."),
    copperbar = Mat("Copper Bar", "INV_Ingot_02", "Blacksmiths work it into gear at an anvil."),
    tinbar = Mat("Tin Bar", "INV_Ingot_05", "Smelted with copper into Bronze."),
    bronzebar = Mat("Bronze Bar", "INV_Ingot_Bronze", "Copper and tin together: stronger gear."),

    -- elixirs: in battle, one stat up a stage for the beast fighting
    lionsstrength = { name = "Elixir of Lion's Strength", price = 0, use = "boost", stat = "atk", icon = ICON .. "INV_Potion_56",
                      desc = "In battle: raises your beast's Attack." },
    minordefense = { name = "Elixir of Minor Defense", price = 0, use = "boost", stat = "def", icon = ICON .. "INV_Potion_63",
                     desc = "In battle: raises your beast's Defense." },
    lesseragility = { name = "Elixir of Lesser Agility", price = 0, use = "boost", stat = "spe", icon = ICON .. "INV_Potion_92",
                      desc = "In battle: raises your beast's Speed." },
    rejuv = { name = "Minor Rejuvenation Potion", price = 0, use = "rejuv", heal = 40, icon = ICON .. "INV_Potion_02",
              desc = "Restores 40 HP and cures poison, burns, paralysis and sleep." },
    -- flasks: a bonus for the beast's next `battles` battles (never in battles between players)
    flasktitans = { name = "Flask of the Titans", price = 0, use = "flask", battles = 10, bonus = { hp = 1.2 },
                    icon = ICON .. "INV_Potion_62", desc = "+20% max HP for the beast's next 10 battles." },
    flasksupreme = { name = "Flask of Supreme Power", price = 0, use = "flask", battles = 10, bonus = { spa = 1.2 },
                     icon = ICON .. "INV_Potion_41", desc = "+20% Sp. Atk for the beast's next 10 battles." },
    flaskassault = { name = "Flask of Relentless Assault", price = 0, use = "flask", battles = 10, bonus = { atk = 1.2 },
                     icon = ICON .. "INV_Potion_117", desc = "+20% Attack for the beast's next 10 battles." },

    -- gear: one piece per beast
    roughsharpening = { name = "Rough Sharpening Stone", price = 0, use = "gear", slot = "claws", bonus = { atk = 1.1 },
                        icon = ICON .. "INV_Stone_SharpeningStone_01", desc = "Gear: sharpened claws, +10% Attack." },
    copperchainbelt = { name = "Copper Chain Belt", price = 0, use = "gear", slot = "waist", bonus = { spe = 1.1 },
                        icon = ICON .. "INV_Belt_02", desc = "Gear: +10% Speed." },
    runedcopperbracers = { name = "Runed Copper Bracers", price = 0, use = "gear", slot = "wrists", bonus = { spa = 1.1 },
                           icon = ICON .. "INV_Bracer_03", desc = "Gear: +10% Sp. Atk." },
    copperchainvest = { name = "Copper Chain Vest", price = 0, use = "gear", slot = "chest", bonus = { def = 1.1, spd = 1.1 },
                        icon = ICON .. "INV_Chest_Chain", desc = "Gear: +10% Defense and Sp. Def." },
    coarsesharpening = { name = "Coarse Sharpening Stone", price = 0, use = "gear", slot = "claws", bonus = { atk = 1.2 },
                         icon = ICON .. "INV_Stone_SharpeningStone_02", desc = "Gear: +20% Attack." },
    roughbronzeshoulders = { name = "Rough Bronze Shoulders", price = 0, use = "gear", slot = "shoulders",
                             bonus = { def = 1.15, spd = 1.15 },
                             icon = ICON .. "INV_Shoulder_05", desc = "Gear: +15% Defense and Sp. Def." },
    patternedbronzebracers = { name = "Patterned Bronze Bracers", price = 0, use = "gear", slot = "wrists",
                               bonus = { spa = 1.15, spe = 1.15 },
                               icon = ICON .. "INV_Bracer_07", desc = "Gear: +15% Sp. Atk and Speed." },
}
local ORDER = { "rejuv", "lionsstrength", "minordefense", "lesseragility", "flasktitans", "flasksupreme", "flaskassault",
                "roughsharpening", "copperchainbelt", "runedcopperbracers", "copperchainvest", "coarsesharpening",
                "roughbronzeshoulders", "patternedbronzebracers",
                "peacebloom", "silverleaf", "earthroot", "mageroyal", "briarthorn",
                "copperore", "tinore", "roughstone", "coarsestone", "copperbar", "tinbar", "bronzebar" }
for id, def in pairs(items) do D.items[id] = def end
for _, id in ipairs(ORDER) do D.itemOrder[#D.itemOrder + 1] = id end

---------------------------------------------------------------------------
-- Data: recipes (skill = the recipe's level; station = where it's made)
---------------------------------------------------------------------------

D.recipes = {
    -- Mining: smelting, at a forge
    { id = "smeltcopper", prof = "mining", skill = 1, makes = "copperbar", mats = { copperore = 1 }, station = "forge" },
    { id = "smelttin", prof = "mining", skill = 50, makes = "tinbar", mats = { tinore = 1 }, station = "forge" },
    { id = "smeltbronze", prof = "mining", skill = 55, makes = "bronzebar", n = 2, mats = { copperbar = 1, tinbar = 1 },
      station = "forge" },
    -- Blacksmithing, at an anvil
    { id = "roughsharpening", prof = "blacksmithing", skill = 1, makes = "roughsharpening", mats = { roughstone = 2 }, station = "anvil" },
    { id = "copperchainbelt", prof = "blacksmithing", skill = 10, makes = "copperchainbelt", mats = { copperbar = 3 }, station = "anvil" },
    { id = "runedcopperbracers", prof = "blacksmithing", skill = 25, makes = "runedcopperbracers",
      mats = { copperbar = 3, roughstone = 2 }, station = "anvil" },
    { id = "copperchainvest", prof = "blacksmithing", skill = 35, makes = "copperchainvest",
      mats = { copperbar = 5, roughstone = 2 }, station = "anvil" },
    { id = "coarsesharpening", prof = "blacksmithing", skill = 55, makes = "coarsesharpening", mats = { coarsestone = 2 }, station = "anvil" },
    { id = "roughbronzeshoulders", prof = "blacksmithing", skill = 65, makes = "roughbronzeshoulders",
      mats = { bronzebar = 4 }, station = "anvil" },
    { id = "patternedbronzebracers", prof = "blacksmithing", skill = 80, makes = "patternedbronzebracers",
      mats = { bronzebar = 4, coarsestone = 2 }, station = "anvil" },
    -- Alchemy, anywhere
    { id = "minorhealing", prof = "alchemy", skill = 1, makes = "potion", mats = { peacebloom = 1, silverleaf = 1 } },
    { id = "minordefense", prof = "alchemy", skill = 1, makes = "minordefense", mats = { silverleaf = 2 } },
    { id = "lionsstrength", prof = "alchemy", skill = 10, makes = "lionsstrength", mats = { earthroot = 1, silverleaf = 1 } },
    { id = "rejuv", prof = "alchemy", skill = 40, makes = "rejuv", mats = { mageroyal = 2, peacebloom = 1 } },
    { id = "lesseragility", prof = "alchemy", skill = 50, makes = "lesseragility", mats = { mageroyal = 1, silverleaf = 1 } },
    { id = "lesserhealing", prof = "alchemy", skill = 55, makes = "superpotion", mats = { potion = 1, briarthorn = 1 } },
    { id = "flasktitans", prof = "alchemy", skill = 80, makes = "flasktitans", mats = { earthroot = 3, briarthorn = 2, mageroyal = 2 } },
    { id = "flasksupreme", prof = "alchemy", skill = 85, makes = "flasksupreme", mats = { mageroyal = 3, briarthorn = 2, silverleaf = 1 } },
    { id = "flaskassault", prof = "alchemy", skill = 90, makes = "flaskassault", mats = { briarthorn = 3, earthroot = 2, peacebloom = 1 } },
}
D.recipeStations = { forge = "a forge", anvil = "an anvil" }

---------------------------------------------------------------------------
-- Skill
---------------------------------------------------------------------------

C.RESPAWN = 600                -- seconds (realm time) before a gathered node grows back
C.SKILLUP = { orange = 100, yellow = 75, green = 25, grey = 0 }
C.clock, C.rng = nil, nil      -- tests

local function Now()
    if C.clock then return C.clock end
    return (GetServerTime and GetServerTime()) or (time and time()) or 0
end
local function Rng(a, b) return (C.rng or math.random)(a, b) end

local function Profs()
    local s = G.save
    if type(s.prof) ~= "table" then s.prof = {} end
    return s.prof
end

-- The player's skill in `prof`, nil when not learned.
function C.Skill(prof)
    local s = G.save
    return s and type(s.prof) == "table" and tonumber(s.prof[prof]) or nil
end

function C.Difficulty(req, skill)
    local d = (skill or 0) - req
    if d < 10 then return "orange" elseif d < 20 then return "yellow" elseif d < 35 then return "green" end
    return "grey"
end

-- Rolls a skill-up for something of level `req`; returns the new skill when it rose.
function C:SkillUp(prof, req)
    local skill = C.Skill(prof)
    if not skill or skill >= D.SKILL_MAX then return nil end
    if Rng(1, 100) > C.SKILLUP[C.Difficulty(req, skill)] then return nil end
    Profs()[prof] = skill + 1
    G:Emit("skillup", { prof = prof, skill = skill + 1 })
    return skill + 1
end

-- The professions the player knows, in menu order.
function C.Known()
    local out = {}
    for _, id in ipairs(D.professionOrder) do if C.Skill(id) then out[#out + 1] = id end end
    return out
end

-- Returns ok, message.
function C:Learn(prof)
    local p = D.professions[prof]
    if not p then return false, "?" end
    if C.Skill(prof) then return false, "You already know " .. p.name .. "." end
    if #C.Known() >= D.MAX_PROFESSIONS then
        return false, "You can only know two professions. Forget one first."
    end
    if G.save.money < D.PROFESSION_FEE then return false, "You can't afford the training (" .. D.Money(D.PROFESSION_FEE) .. ")." end
    G.save.money = G.save.money - D.PROFESSION_FEE
    Profs()[prof] = 1
    G:Emit("learn", { prof = prof })
    return true, "You have learned " .. p.name .. "!"
end

-- Forgets a profession and its skill. Returns ok, message.
function C:Unlearn(prof)
    local p = D.professions[prof]
    if not p or not C.Skill(prof) then return false, "?" end
    Profs()[prof] = nil
    return true, "You have unlearned " .. p.name .. "."
end

-- The hint over a node: "Pick Peacebloom", with what's missing when it can't be gathered yet.
function C:GatherHint(resId)
    local res = D.resources[resId]
    if not res then return nil end
    local profId = res.kind == "herb" and "herbalism" or "mining"
    local prof = D.professions[profId]
    local skill = C.Skill(profId)
    local text = (res.kind == "herb" and "Pick " or "Mine ") .. res.name
    if not skill then
        text = text .. "  (needs " .. prof.name .. ")"
    elseif skill < res.skill then
        text = text .. string.format("  (needs %s %d)", prof.name, res.skill)
    end
    return text
end

-- The trainer's conversation (from the map script).
function C:TrainerTalk(g, id)
    local t = D.craftTrainers[id]
    g:Say(t.name .. ": " .. t.hello)
    local options, profs = {}, {}
    for _, p in ipairs(t.teaches) do
        if not C.Skill(p) then
            options[#options + 1] = "Learn " .. D.professions[p].name
            profs[#profs + 1] = p
        end
    end
    if #options == 0 then
        g:Say(t.name .. ": " .. t.done)
        return
    end
    -- two professions already: offer to forget one first
    local known = C.Known()
    if #known >= D.MAX_PROFESSIONS then
        local names, forget = {}, {}
        for i, p in ipairs(known) do
            names[i] = D.professions[p].name
            forget[i] = "Forget " .. D.professions[p].name
        end
        g:Say(string.format("%s: You already know %s. A tamer can only keep two trades.", t.name, table.concat(names, " and ")))
        local which = g:Choose(t.name .. ": Forget one to make room?", forget)
        if not which then
            g:Say(t.name .. ": Wise. Come back if you change your mind.")
            return
        end
        local p = known[which]
        if not g:YesNo(string.format("Forget %s? Your skill of %d will be lost.", D.professions[p].name, C.Skill(p))) then
            g:Say(t.name .. ": Come back if you change your mind.")
            return
        end
        local _, msg = C:Unlearn(p)
        g:Say(msg)
    end
    local pick = g:Choose(string.format("%s: Care to learn a trade? %s each.", t.name, D.Money(D.PROFESSION_FEE)), options)
    if not pick then
        g:Say(t.name .. ": Come back anytime.")
        return
    end
    local ok, msg = C:Learn(profs[pick])
    g:Say(msg)
    if ok then g:Say(t.name .. ": " .. D.professions[profs[pick]].howto) end
end

---------------------------------------------------------------------------
-- Nodes
---------------------------------------------------------------------------

local function NodeKey(mapId, node) return mapId .. ":" .. node.x .. ":" .. node.y end

-- Whether the node is there to gather, and what it is right now.
function C:NodeState(mapId, node)
    local s = G.save
    local st = type(s.nodes) == "table" and s.nodes[NodeKey(mapId, node)]
    local up = not st or Now() - (tonumber(st.t) or 0) >= C.RESPAWN
    local list = node.list
    local res = list[((node.x * 7 + node.y * 13) + (st and st.n or 0)) % #list + 1]
    return up, res
end

local function Give(item, n)
    local bag = G.save.bag
    bag[item] = (bag[item] or 0) + n
end

-- A on a node (inside the game's script).
function C:Gather(g, node)
    local mapId = g.map.id
    local up, resId = C:NodeState(mapId, node)
    local res = D.resources[resId]
    if not up or not res then return end
    local profId = res.kind == "herb" and "herbalism" or "mining"
    local prof = D.professions[profId]
    local skill = C.Skill(profId)
    if not skill then
        g:Say(string.format("%s. It takes %s to gather it: %s in Goldshire teaches it.", res.name, prof.name, prof.trainer))
        return
    end
    if skill < res.skill then
        g:Say(string.format("%s: requires %s (%d). Your skill is %d.", res.name, prof.name, res.skill, skill))
        return
    end
    local n = Rng(res.yield[1], res.yield[2])
    local item = res.item or resId
    Give(item, n)
    local lines = { string.format("You %s %s x%d.", res.kind == "herb" and "picked" or "mined", D.items[item].name, n) }
    if res.extra and Rng(1, 100) <= res.extra.chance then
        Give(res.extra.item, 1)
        lines[#lines + 1] = string.format("You also found %s.", D.items[res.extra.item].name)
    end
    local s = G.save
    if type(s.nodes) ~= "table" then s.nodes = {} end
    local key = NodeKey(mapId, node)
    local st = type(s.nodes[key]) == "table" and s.nodes[key] or {}
    st.t, st.n = Now(), (st.n or 0) + 1
    s.nodes[key] = st
    local rose = C:SkillUp(profId, res.skill)
    if rose then lines[#lines + 1] = string.format("Your skill in %s has increased to %d.", prof.name, rose) end
    G:Emit("gather", { res = resId, item = item, n = n, prof = profId })
    g:Say(table.concat(lines, "\n"))
end

---------------------------------------------------------------------------
-- Crafting
---------------------------------------------------------------------------

C.byProf = {}
for _, r in ipairs(D.recipes) do
    C.byProf[r.prof] = C.byProf[r.prof] or {}
    table.insert(C.byProf[r.prof], r)
end

-- Is a crafting station of `kind` (map objects with station = kind) within two tiles?
function C:NearStation(kind)
    local m = G.map
    if not (m and G.save) then return false end
    for _, o in ipairs(m.def.objects or {}) do
        if o.station == kind and math.abs(o.x - G.save.x) <= 2 and math.abs(o.y - G.save.y) <= 2 then return true end
    end
    return false
end

-- How many the bag has materials for.
function C.CanMake(r)
    local bag = G.save.bag
    local most = math.huge
    for item, n in pairs(r.mats) do most = math.min(most, math.floor((bag[item] or 0) / n)) end
    return most == math.huge and 0 or most
end

-- ok, or false and why: "unknown" | "skill" | "station" | "mats"
function C:Check(r)
    local skill = C.Skill(r.prof)
    if not skill then return false, "unknown" end
    if skill < r.skill then return false, "skill" end
    if r.station and not C:NearStation(r.station) then return false, "station" end
    if C.CanMake(r) < 1 then return false, "mats" end
    return true
end

-- Makes one. Returns ok, message.
function C:Craft(r)
    local ok, why = C:Check(r)
    if not ok then
        if why == "skill" then return false, string.format("Requires %s (%d).", D.professions[r.prof].name, r.skill) end
        if why == "station" then return false, "You need to be at " .. D.recipeStations[r.station] .. "." end
        if why == "mats" then return false, "You don't have the materials." end
        return false, "You don't know " .. D.professions[r.prof].name .. "."
    end
    local bag = G.save.bag
    for item, n in pairs(r.mats) do
        bag[item] = bag[item] - n
        if bag[item] <= 0 then bag[item] = nil end
    end
    local n = r.n or 1
    Give(r.makes, n)
    local msg = string.format("You create %s%s.", D.items[r.makes].name, n > 1 and (" x" .. n) or "")
    local rose = C:SkillUp(r.prof, r.skill)
    if rose then msg = msg .. string.format("\nYour skill in %s has increased to %d.", D.professions[r.prof].name, rose) end
    G:Emit("craft", { recipe = r.id, item = r.makes, n = n, prof = r.prof })
    return true, msg
end

-- A forge / anvil / alchemy table on the map opens that profession's recipes.
function G:CraftAt(prof) return self:Wait({ kind = "craft", prof = prof }) end

---------------------------------------------------------------------------
-- Gear and flasks
---------------------------------------------------------------------------

local function Take(item)
    local bag = G.save.bag
    if (bag[item] or 0) <= 0 then return false end
    bag[item] = bag[item] - 1
    if bag[item] <= 0 then bag[item] = nil end
    return true
end

local function ClampHP(mon) mon.hp = math.min(mon.hp, M.MaxHP(mon)) end

-- Puts `item` on party beast `idx` in its slot; what that slot held goes back in the bag. Returns ok, message.
function G:Equip(idx, item)
    local mon = self.save.party[idx]
    local def = D.items[item]
    if not mon or not def or def.use ~= "gear" or not def.slot or not Take(item) then return false, "It won't have any effect." end
    if type(mon.gear) ~= "table" then mon.gear = {} end
    local old = mon.gear[def.slot]
    if old then Give(old, 1) end
    mon.gear[def.slot] = item
    ClampHP(mon)
    self:Emit("equip", { mon = mon, item = item })
    if old then
        return true, string.format("%s took off the %s and put on the %s.", M.Name(mon), D.items[old].name, def.name)
    end
    return true, string.format("%s is now wearing the %s.", M.Name(mon), def.name)
end

function G:Unequip(idx, slot)
    local mon = self.save.party[idx]
    local old = mon and type(mon.gear) == "table" and mon.gear[slot]
    if not old then return false, "Nothing to take off there." end
    Give(old, 1)
    mon.gear[slot] = nil
    if not next(mon.gear) then mon.gear = nil end
    ClampHP(mon)
    return true, string.format("You took the %s off %s.", D.items[old].name, M.Name(mon))
end

function G:UseFlask(idx, item)
    local mon = self.save.party[idx]
    local def = D.items[item]
    if not mon or not def or def.use ~= "flask" or mon.hp <= 0 or not Take(item) then return false, "It won't have any effect." end
    mon.flask = { id = item, n = def.battles }
    return true, string.format("%s drank the %s. (%d battles)", M.Name(mon), def.name, def.battles)
end

-- After each battle (not between players): flasks count down. Says when one wears off.
function C:AfterBattle(g)
    for _, mon in ipairs(G.save.party) do
        local f = mon.flask
        if f then
            f.n = (f.n or 1) - 1
            if f.n <= 0 then
                mon.flask = nil
                ClampHP(mon)
                if D.items[f.id] then g:Say(string.format("The %s on %s wore off.", D.items[f.id].name, M.Name(mon))) end
            end
        end
    end
end

-- For tests
C._Now = Now
