-- CDLoot Games/Azeromon/Maps.lua
-- ns.AzeroMaps: the overworld. Each map is a grid of characters plus objects:
--   .  grass            "  tall grass (encounters)     =  dirt path       T  tree        w  water
--   W  wall   f  floor   r  exit mat   b  bed   d  shelf   p  pot   t  table   C  chest   c  counter   X  void
-- stamps   { kind = "house"|"bigtree"|"mailbox", x, y }        (house door: x + 3, y + 5)
-- signs    { x, y, text }
-- npcs     { id, x, y, sprite, face, tint, script = fn(G, npc), trainer, sight, hidden = fn(G) }
--          role: what the NPC offers, listed on the world map ("inn", "rest", "shop", "stable", "gryphon",
--          "profession", "pettrainer", "arena")
-- chests   { id, x, y, item, n } (opened once)   objects { x, y, tile, script } (solid, interactable)
-- warps    { x, y, map, tx, ty, face }           edges { north|south = { map, dx } }
-- triggers { x, y, script = fn(G), cond = fn(G) } run when the player steps on the tile
-- music    a Sound.lua track ("forest", "plains", "tavern", "mine", "cove", ...)
-- Scripts run as coroutines: G:Say / G:YesNo / G:Battle ... pause until the player answers.
local addonName, ns = ...

local Maps = {}
ns.AzeroMaps = Maps

Maps.START = { map = "home", x = 3, y = 3, face = "down" }
Maps.RESPAWN = { map = "post", x = 4, y = 5, face = "up" }

---------------------------------------------------------------------------
-- Goldshire (town)
---------------------------------------------------------------------------

Maps.town = {
    name = "Goldshire",
    music = "forest",
    outdoor = true,
    rows = {
        "TTTTTTTTTT==TTTTTTTTTT",
        "T.........==.........T",
        "T.........==.........T",
        "T.........==.........T",
        "T.........==.........T",
        "T.........==.........T",
        "T.........==.........T",
        "T...===============..T",
        "T...===============..T",
        "T.........==.........T",
        "T.........==....www..T",
        "T.........==...wwwww.T",
        "T.........==...wwwww.T",
        "T.........==....www..T",
        "T.........==.........T",
        "T.........==.........T",
        "T.........==.........T",
        "T...========.........T",
        "T...========.........T",
        "TTTTTTTTTTTTTTTTTTTTTT",
    },
    stamps = {
        { kind = "house", x = 2, y = 1 },       -- home, door (5, 6)
        { kind = "house", x = 14, y = 1 },      -- Huntmaster Aldric's lodge, door (17, 6)
        { kind = "house", x = 2, y = 11 },      -- the Lion's Pride Inn, door (5, 16)
        { kind = "mailbox", x = 7, y = 5 },
        { kind = "bigtree", x = 15, y = 14 },
    },
    signs = {
        { x = 12, y = 9, text = "GOLDSHIRE\nElwynn Forest. Stormwind City lies to the north, Westfall to the west." },
        { x = 13, y = 6, text = "HUNTMASTER ALDRIC'S LODGE\nBeast training for aspiring hunters of the Alliance." },
        { x = 7, y = 15, text = "THE LION'S PRIDE INN\nRest your beasts. Brog Hamfist sells general goods inside." },
    },
    objects = {
        { x = 9, y = 15, tile = "wantedboard", hint = "Read the bounty board", script = function(G) G:BountyBoard() end },   -- the bounty board (every town has one)
        { x = 9, y = 3, tile = "alchemy", hint = "Brew at the alchemy table", script = function(G) G:CraftAt("alchemy") end },   -- Mallory's table
        { x = 17, y = 17, tile = "anvil", station = "anvil", hint = "Smith at the anvil", script = function(G) G:CraftAt("blacksmithing") end },
        { x = 19, y = 17, tile = "forge", station = "forge", hint = "Smelt at the forge", script = function(G) G:CraftAt("mining") end },
    },
    warps = {
        { x = 5, y = 6, map = "home", tx = 4, ty = 6, face = "up" },
        { x = 17, y = 6, map = "lab", tx = 4, ty = 6, face = "up" },
        { x = 5, y = 16, map = "post", tx = 4, ty = 6, face = "up" },
    },
    edges = { north = { map = "route1", dx = 0 } },
    npcs = {
        { id = "guard", name = "Marshal Dughan", x = 12, y = 1, sprite = "bald", tint = { 0.55, 0.65, 1 }, face = "left",   -- Marshal Dughan
          script = function(G)
              if G:Flag("starter") then
                  G:Say("Marshal Dughan: The road north runs through Elwynn Forest toward Westfall. Mind the tall grass, and keep an eye out for Hogger.")
              else
                  G:ClassSay("dughan")
                  G:Say("Marshal Dughan: Wolves, kobolds and worse lurk in the forest.\nNobody leaves Goldshire without a beast of their own.")
              end
          end },
        { id = "farmer", name = "Maybell Maclure", x = 8, y = 12, sprite = "bald", tint = { 1, 0.85, 0.6 }, face = "down", wander = true,
          script = function(G)
              G:Say("Maybell Maclure: Huntmaster Aldric can tame anything, they say. His lodge is in the northeast.\nIf you see Tommy Joe Stonefield... never mind.")
          end },
        { id = "mallory", name = "Alchemist Mallory", role = "profession", x = 8, y = 3, sprite = "girl", tint = { 0.85, 0.75, 1 }, face = "down",       -- Herbalism, Alchemy
          script = function(G) ns.AzeroCraft:TrainerTalk(G, "mallory") end },
        { id = "argus", name = "Smith Argus", role = "profession", x = 18, y = 17, sprite = "bald", tint = { 0.85, 0.72, 0.6 }, face = "down",      -- Mining, Blacksmithing
          script = function(G) ns.AzeroCraft:TrainerTalk(G, "argus") end },
        { id = "kid", name = "Billy Maclure", x = 14, y = 9, sprite = "hero", tint = { 1, 0.75, 0.75 }, face = "left", wander = true,
          script = function(G)
              G:Say("Billy Maclure: When I grow up I'm gonna tame a dragon whelp! Or a murloc! Mrgllglgl!")
          end },
    },
    triggers = {
        { x = 10, y = 1, cond = function(G) return not G:Flag("starter") end,
          script = function(G) G:StopAtGuard() end },
        { x = 11, y = 1, cond = function(G) return not G:Flag("starter") end,
          script = function(G) G:StopAtGuard() end },
    },
}

---------------------------------------------------------------------------
-- Interiors
---------------------------------------------------------------------------

Maps.home = {
    name = "Your House",
    music = "tavern",
    rows = {
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "fbffffffdf",
        "ffffffffff",
        "ffftffffff",
        "ffffffffpf",
        "ffffffffff",
        "WWWWrWWWWW",
    },
    warps = { { x = 4, y = 7, map = "town", tx = 5, ty = 7, face = "down" } },
    npcs = {
        { id = "mom", name = "Mom", x = 6, y = 4, sprite = "girl", tint = { 0.85, 0.75, 1 }, face = "left",
          script = function(G)
              if not G:Flag("starter") then
                  G:Say("Mom: Morning, {PLAYER}! Huntmaster Aldric came by looking for you.\nHis lodge is across the road.")
              else
                  G:Say("Mom: {PLAYER}, you look tired. Sit by the hearth and let your beasts rest a moment.")
                  G:HealParty()
                  G:Say("Your beasts are fully rested! Light keep you, dear.")
              end
          end },
    },
}

local function PickStarter(G, sp)
    if G:Flag("starter") then
        G:Say("An empty crate. Its beast is already with {PLAYER}.")
        return
    end
    local s = ns.AzeroData.species[sp]
    G:ShowSpecies(sp)
    if not G:YesNo(string.format("Huntmaster Aldric: So you'd like %s, the %s-type beast?", s.name,
        ns.AzeroData.types[s.type].name)) then
        G:ShowSpecies(nil)
        return
    end
    G:ShowSpecies(nil)
    G:GiveMon(sp, 5, true)
    G:SetFlag("starter", sp)
    G:Say("Huntmaster Aldric: A fine choice! Treat it well and it will never leave your side.")
    local rivalSp = ns.AzeroData.rivalStarter[sp]
    G:SetFlag("rivalStarter", rivalSp)
    G:Say("{RIVAL}: Then I'll take this one! " .. ns.AzeroData.species[rivalSp].name .. ", you're with me!")
    G:Say("{RIVAL}: {PLAYER}! Let's see whose beast is stronger!")
    local result = G:Battle("rival1")
    G:HealParty()
    if result == "win" then
        G:Say("{RIVAL}: Hmph. Beginner's luck! I'll get stronger, you'll see!")
    else
        G:Say("{RIVAL}: Yes! I knew I picked the better one! Don't feel bad, {PLAYER}.")
    end
    G:Say("Huntmaster Aldric: Splendid! Spoken like true hunters. I've tended to both your beasts.")
    G:Say("Huntmaster Aldric: Take these Taming Rods. Weaken a wild beast, then use one to tame it, as every hunter does.")
    G:Give("net", 5)
    G:Give("potion", 2)
    G:Say("Huntmaster Aldric: Elwynn Forest is full of wild beasts. Deputy Rainer guards the road to Westfall. Good hunting, {PLAYER}!")
    G:SetFlag("rivalDone", true)
end

Maps.lab = {
    name = "Huntmaster Aldric's Lodge",
    music = "tavern",
    rows = {
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "fddffffddf",
        "ffffffffff",
        "fffCCCffff",
        "ffffffffff",
        "ffffffffff",
        "WWWWrWWWWW",
    },
    warps = { { x = 4, y = 7, map = "town", tx = 17, ty = 7, face = "down" } },
    objects = {
        { x = 3, y = 4, tile = "chest", script = function(G) PickStarter(G, "emberwhelp") end },
        { x = 4, y = 4, tile = "chest", script = function(G) PickStarter(G, "murkling") end },
        { x = 5, y = 4, tile = "chest", script = function(G) PickStarter(G, "lashling") end },
    },
    npcs = {
        { id = "aldric", name = "Huntmaster Aldric", x = 4, y = 3, sprite = "bald", tint = { 0.95, 0.95, 0.8 }, face = "down",
          script = function(G)
              if not G:Flag("starter") then
                  G:Say("Huntmaster Aldric: Ah, {PLAYER}! I've been expecting you.")
                  G:ClassSay("aldric")
                  G:Say("Huntmaster Aldric: Every hunter of the Alliance begins with a single beast. Today, so do you.")
                  G:Say("Huntmaster Aldric: A red whelp, a murloc from Crystal Lake and a bloodpetal from Un'Goro. Pick one of these crates!")
              else
                  G:Say("Huntmaster Aldric: A hunter and a beast that fight together grow stronger together.\nFill that Bestiary for me!")
                  G:ShowDexSummary()
              end
          end },
        { id = "rival", name = "Vera", x = 7, y = 5, sprite = "girl", face = "left",
          hidden = function(G) return G:Flag("rivalDone") end,
          script = function(G)
              if G:Flag("starter") then
                  G:Say("{RIVAL}: I'll beat you next time!")
              else
                  G:Say("{RIVAL}: Grandpa Aldric says I get to pick after you. Hurry up, {PLAYER}!")
              end
          end },
    },
}

Maps.post = {
    name = "Lion's Pride Inn",
    music = "tavern",
    rows = {
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "fffffLffff",
        "fcccffcccf",
        "ffffffffff",
        "ffffffffff",
        "pffffffffp",
        "WWWWrWWWWW",
    },
    warps = { { x = 4, y = 7, map = "town", tx = 5, ty = 17, face = "down" },
              { x = 5, y = 2, map = "hideout", tx = 14, ty = 22, face = "up" } },           -- the Guild Hall below
    signs = { { x = 6, y = 2, text = "THE GUILD HALL\nDown the stairs: the guild's raid trophies and its champions." } },
    npcs = {
        { id = "healer", name = "Innkeeper Farley", role = "inn", x = 2, y = 2, sprite = "girl", tint = { 1, 0.8, 0.85 }, face = "down",
          script = function(G)
              G:Say("Innkeeper Farley: Welcome to the Lion's Pride Inn!")
              G:ClassSay("farley")
              if G:YesNo("Innkeeper Farley: Shall I give your beasts a warm meal and a place by the fire?") then
                  G:HealParty()
                  G:SetRespawn("post", 4, 5, "up", "the Lion's Pride Inn")
                  G:Say("Innkeeper Farley: Your beasts are fighting fit! Come back anytime.")
              else
                  G:Say("Innkeeper Farley: Come back anytime.")
              end
          end },
        { id = "clerk", name = "Brog Hamfist", role = "shop", x = 7, y = 2, sprite = "bald", tint = { 0.7, 1, 0.7 }, face = "down",
          script = function(G)
              G:Say("Brog Hamfist: Welcome! Potions, rods, the finest goods in Goldshire. And I buy, too.")
              G:Shop("Brog Hamfist")
              G:Say("Brog Hamfist: Come again!")
          end },
        { id = "erma", name = "Erma", role = "stable", x = 8, y = 5, sprite = "girl", tint = { 0.85, 0.95, 0.75 }, face = "left",      -- stable master
          script = function(G)
              G:Say("Erma: Stable Master Erma, at your service. I'll mind any beasts you can't take along.")
              G:Stable()
              G:Say("Erma: They'll be well looked after. Come back anytime.")
          end },
        { id = "pettrainer", name = "Gorvin Wildhammer", role = "pettrainer", x = 1, y = 5, sprite = "bald", tint = { 0.86, 0.66, 0.46 }, face = "right",
          script = function(G)
              local who = "Gorvin Wildhammer: "
              G:Say(who .. "Pet trainer, down from Aerie Peak. Wildhammers raise gryphons; beasts I understand.")
              G:ClassSay("gorvin")
              if #G.save.party == 0 then
                  G:Say(who .. "Come back when ye've a beast of yer own.")
                  return
              end
              G:Say(who .. "A beast never forgets what it's learned. Sometimes it just needs remindin'.")
              local price = ns.AzeroData.Money(G.RELEARN_PRICE)
              if not G:YesNo(who .. price .. " a lesson. Shall I remind one of yer beasts of a move?") then
                  G:Say(who .. "Suit yerself.")
                  return
              end
              if G.save.money < G.RELEARN_PRICE then
                  G:Say(who .. "Ye're short on coin, friend. " .. price .. ", no less.")
                  return
              end
              if G:PetTrainer() then
                  G:Say(who .. "Good as new. Off ye go!")
              else
                  G:Say(who .. "Come back anytime.")
              end
          end },
    },
}

---------------------------------------------------------------------------
-- The Gurubashi Arena (Stranglethorn Vale): Short John Mithril's gauntlet (Arena.lua)
---------------------------------------------------------------------------

Maps.arena = {
    name = "Gurubashi Arena",
    music = "arena",
    outdoor = true,
    theme = "arena",
    rows = {
        "TTTTTTT..TTTTTTT",
        "TiTTTTTTTTTTTTiT",
        "T..............T",
        "T..............T",
        "T..............T",
        "T..............T",
        "T..............T",
        "T..............T",
        "T..............T",
        "T..............T",
        "TiTTTTT..TTTTTiT",
        "T..............T",
        "TTTTTTT..TTTTTTT",
    },
    -- the road through the arena: Zul'Mamwe to the north, Southern Stranglethorn to the south
    edges = { north = { map = "zulmamwe", dx = 4 }, south = { map = "stvsouth", dx = 4 } },
    signs = {
        { x = 9, y = 10, text = "THE GURUBASHI ARENA\nBeast fights daily. See Short John Mithril in the ring." },
    },
    npcs = {
        { id = "mithril", name = "Short John Mithril", role = "arena", x = 7, y = 3, sprite = "bald", tint = { 1, 0.85, 0.5 }, face = "down",
          script = function(G) ns.AzeroArena:Run(G) end },
        { id = "skindle", name = "Innkeeper Skindle", role = "inn", x = 3, y = 11, sprite = "girl", tint = { 0.8, 1, 0.7 }, face = "right",
          script = function(G)
              G:Say("Innkeeper Skindle: Up from Booty Bay for the fights. I patch up the losers, and the winners.")
              if G:YesNo("Innkeeper Skindle: Rest your beasts?") then
                  G:HealParty()
                  G:SetRespawn("arena", 7, 11, "up", "the Gurubashi Arena")
                  G:Say("Innkeeper Skindle: Good as new. Go get 'em.")
              end
          end },
        { id = "gyll", name = "Gyll", role = "gryphon", x = 12, y = 11, sprite = "bald", tint = { 0.8, 0.9, 1 }, face = "left",
          script = function(G)
              if G:YesNo("Gyll: Gryphon back to Sentinel Hill? It's on the house.") then
                  G:EnterMap("sentinel", 17, 4, "right")
                  G:Say("You fly back north to Westfall.")
              end
          end },
    },
}

---------------------------------------------------------------------------
-- Elwynn Forest
---------------------------------------------------------------------------

Maps.route1 = {
    name = "Elwynn Forest",
    music = "forest",
    herbs = { "peacebloom", "silverleaf", "earthroot" }, ores = { "copper" },
    nodes = { herb = { { 1, 9 }, { 20, 9 }, { 20, 16 }, { 1, 15 }, { 4, 26 }, { 20, 30 }, { 1, 30 } },
              ore = { { 16, 11 }, { 5, 22 }, { 9, 23 } } },
    outdoor = true,
    rows = {
        "TTTTTTTTTT==TTTTTTTTTT",
        "TTTTTTTTTT==TTTTTTTTTT",
        ".........====........T",
        ".........====........T",
        "T..\"\"\"\"...==...\"\"\"\"..T",
        "T..\"\"\"\"...==...\"\"\"\"..T",
        "T..\"\"\"\"...==...\"\"\"\"..T",
        "T.........==.........T",
        "TTTTTTT...==...TTTTTTT",
        "T.........==.........T",
        "T.\"\"\"\"\"\"..==.........T",
        "T.\"\"\"\"\"\"..==..TT.....T",
        "T.\"\"\"\"\"\"..==..TT.....T",
        "T.\"\"\"\"\"\"..==.........T",
        "T.........======.....T",
        "T.........======.....T",
        "TTTT..........==.....T",
        "T.............==..\"\"\"T",
        "T..\"\"\"\"\"\"\"\"...==..\"\"\"T",
        "T..\"\"\"\"\"\"\"\"...==..\"\"\"T",
        "T..\"\"\"\"\"\"\"\"...==.....T",
        "T.............==.....T",
        "T.....TTT.....==.....T",
        "T.....TTT.....==.....T",
        "T.........======.....T",
        "T.........======.....T",
        "T.........==.........T",
        "T.\"\"\"\"....==..\"\"\"\"\"\".T",
        "T.\"\"\"\"....==..\"\"\"\"\"\".T",
        "T.\"\"\"\"....==..\"\"\"\"\"\".T",
        "T.........==.........T",
        "T.........==.........T",
        "TTTTTTTTTT==TTTTTTTTTT",
    },
    edges = { south = { map = "town", dx = 0 }, north = { map = "westfall", dx = 1 }, west = { map = "forestedge", dy = 4 } },
    triggers = {
        { x = 10, y = 1, cond = function(G) return not G:Flag("badge_hogger") end, script = function(G) G:HoggerGate() end },
        { x = 11, y = 1, cond = function(G) return not G:Flag("badge_hogger") end, script = function(G) G:HoggerGate() end },
    },
    -- weight: always; day / night: the weight in that part of the (realm) day instead; rare: rare-spawn alert
    encounters = {
        { sp = "wolfpup", min = 2, max = 4, weight = 30 },
        { sp = "owlet", min = 2, max = 4, day = 5, night = 40 },
        { sp = "kobling", min = 3, max = 5, weight = 20 },
        { sp = "webling", min = 3, max = 5, day = 8, night = 25 },
        { sp = "tuskling", min = 4, max = 5, day = 12, night = 5 },
        { sp = "motherfang", min = 9, max = 10, day = 0, night = 2, rare = true },
    },
    signs = {
        { x = 8, y = 2, text = "ROAD TO WESTFALL: north.\nFOREST'S EDGE: west.\n\nBy order of Marshal Dughan, the road is closed while Hogger's gnolls roam free." },
        { x = 12, y = 30, text = "ELWYNN FOREST\nNorth: Road to Westfall    South: Goldshire" },
    },
    chests = {
        { id = "r1potion", x = 19, y = 11, item = "potion", n = 1 },
        { id = "r1nets", x = 3, y = 21, item = "net", n = 3 },
    },
    npcs = {
        { id = "hunter1", x = 8, y = 11, sprite = "hero", tint = { 0.8, 1, 0.7 }, face = "right",
          trainer = "hunter1", sight = 3 },
        { id = "druid1", x = 16, y = 19, sprite = "girl", tint = { 0.7, 1, 0.8 }, face = "left",
          trainer = "druid1", sight = 3 },
        { id = "miner1", x = 12, y = 28, sprite = "bald", tint = { 0.9, 0.75, 0.55 }, face = "left",
          trainer = "miner1", sight = 2 },
        { id = "captain", x = 13, y = 2, sprite = "hero", tint = { 0.7, 0.8, 1 }, face = "left",
          trainer = "captain", sight = 3 },
    },
}

---------------------------------------------------------------------------
-- Forest's Edge: Hogger's camp (south-western Elwynn)
---------------------------------------------------------------------------

Maps.forestedge = {
    name = "Forest's Edge",
    music = "forest",
    herbs = { "silverleaf", "earthroot", "peacebloom" }, ores = { "copper" },
    nodes = { herb = { { 18, 4 }, { 18, 12 }, { 1, 8 } }, ore = { { 18, 2 }, { 3, 12 } } },
    outdoor = true,
    rows = {
        "TTTTTTTTTTTTTTTTTTTT",
        "T..........\"\"\"\"..T.T",
        "T..........\"\"\"\"....T",
        "T..........\"\"\"\"....T",
        "T..................T",
        "T..i...i...........T",
        "T.......===========.",
        "T.......===========.",
        "T..................T",
        "T..i...i....\"\"\"\"\"..T",
        "T...........\"\"\"\"\"..T",
        "T...........\"\"\"\"\"..T",
        "T.T................T",
        "TTTTTTTTTTTTTTTTTTTT",
    },
    edges = { east = { map = "route1", dy = -4 } },
    stamps = {
        { kind = "tent", x = 2, y = 1 }, { kind = "tent", x = 6, y = 1 }, { kind = "tent", x = 2, y = 10 },
        { kind = "tent", x = 15, y = 1 },
    },
    signs = {
        { x = 17, y = 5, text = "FOREST'S EDGE\nHogger's camp lies ahead. Enter at your own risk!\n- Marshal Dughan" },
    },
    encounters = {
        { sp = "runt", min = 6, max = 8, weight = 40 },
        { sp = "wolfpup", min = 6, max = 8, weight = 30 },
        { sp = "scout", min = 7, max = 8, weight = 20 },
        { sp = "webling", min = 7, max = 8, weight = 10 },
    },
    npcs = {
        { id = "gnoll1", x = 10, y = 5, sprite = "bald", tint = { 0.75, 0.55, 0.35 }, face = "down",
          trainer = "gnoll1", sight = 2 },
        { id = "gnoll2", x = 8, y = 9, sprite = "bald", tint = { 0.6, 0.5, 0.7 }, face = "up",
          trainer = "gnoll2", sight = 2 },
        { id = "hogger", x = 4, y = 7, sprite = "bald", tint = { 0.85, 0.45, 0.3 }, face = "right",
          trainer = "hogger", sight = 0 },
    },
    chests = {
        { id = "fepotion", x = 17, y = 11, item = "superpotion", n = 1 },
    },
}

---------------------------------------------------------------------------
-- Westfall
---------------------------------------------------------------------------

Maps.westfall = {
    name = "Westfall",
    music = "plains",
    herbs = { "mageroyal", "briarthorn", "earthroot", "silverleaf" }, ores = { "copper", "tin" },
    nodes = { herb = { { 8, 2 }, { 22, 8 }, { 22, 13 }, { 5, 29 }, { 13, 29 } },
              ore = { { 9, 5 }, { 5, 31 }, { 22, 19 } } },
    outdoor = true,
    theme = "westfall",
    rows = {
        "wwsTTTTTTTT==TTTTTTTTTTT",
        "wws........==..........T",
        "wws........==.########.T",
        "wws........==..o.o.o...T",
        "wws........==...o.o.o..T",
        "wws........==..o.o.o...T",
        "wws........==...o.o.o..T",
        "wws........==..........T",
        "wws;;......==..........T",
        "wws;;......==..........T",
        "wws;;......==..........T",
        "wws;;......==..........T",
        "wws;;......==..........T",
        "wws;;......==..........T",
        "wws;;......==..........T",
        "wws;;......==..h.......T",
        "wws;;#####.==........h.T",
        "wws;;\"\"\"\"\".==..........T",
        "wws;;\"\"\"\"\".==..........T",
        "wws;;\"\"\"\"\".==..........T",
        "wws;;\"\"\"\"\".==..........T",
        "wws;;\"\"\"\"\".==........h.T",
        "wws;;\"\"\"\"\".==..........T",
        "wws;;\"\"\"\"\".==========..T",
        "wws;;\"\"\"\"\".==========..T",
        "wws;;#####.==..........T",
        "wws;;...h..==.#########T",
        "wws;;......==.#\"\"\"\"\"\"\"TT",
        "wws;;......==.#\"\"\"\"\"\"\"TT",
        "wws........==..\"\"\"\"\"\"\"TT",
        "wws........==.#\"\"\"\"\"\"\"TT",
        "wws........==.#\"\"\"\"\"\"\"TT",
        "wws........==.#########T",
        "wwsTTTTTTTT==TTTTTTTTTTT",
    },
    edges = { south = { map = "route1", dx = -1 }, north = { map = "sentinel", dx = -2 } },
    stamps = {
        { kind = "farmhouse", x = 16, y = 17 },             -- Saldean's farm, door (19, 22)
        { kind = "windmill", x = 19, y = 9 },
        { kind = "windmill", x = 6, y = 10 },
        { kind = "scarecrow", x = 7, y = 20 },
        { kind = "wbigtree", x = 15, y = 11 },
    },
    warps = {
        { x = 19, y = 22, map = "saldean", tx = 4, ty = 6, face = "up" },
    },
    signs = {
        { x = 13, y = 31, text = "WESTFALL\nNorth: Sentinel Hill\nSouth: Elwynn Forest" },
        { x = 15, y = 21, text = "SALDEAN'S FARM\nFresh vegetables. Please don't let the goretusks in." },
        { x = 13, y = 3, text = "FURLBROW'S PUMPKIN FARM\nDefias keep out!" },
    },
    encounters = {
        { sp = "coyote", min = 9, max = 12, day = 20, night = 35 },
        { sp = "fleshripper", min = 9, max = 12, day = 25, night = 8 },
        { sp = "ghostpaw", min = 13, max = 14, day = 0, night = 2, rare = true },
        { sp = "rustgolem", min = 10, max = 13, weight = 20 },
        { sp = "dustdevil", min = 11, max = 13, weight = 10 },
        { sp = "scout", min = 10, max = 12, weight = 10 },
        { sp = "tuskling", min = 10, max = 12, weight = 10 },
    },
    coastEncounters = {
        { sp = "crawler", min = 9, max = 12, weight = 45 },
        { sp = "coastrunner", min = 10, max = 13, weight = 40 },
        { sp = "fleshripper", min = 10, max = 12, weight = 15 },
    },
    chests = {
        { id = "wfnet", x = 21, y = 1, item = "greatnet", n = 2 },
        { id = "wfbeach", x = 3, y = 30, item = "superpotion", n = 1 },
    },
    npcs = {
        { id = "furlbrow", name = "Farmer Furlbrow", x = 14, y = 5, sprite = "bald", tint = { 1, 0.85, 0.65 }, face = "right",
          script = function(G)
              G:Say("Farmer Furlbrow: The Defias ran my wife and me off our own farm, and they took Old Blanchy too!")
              G:Say("Farmer Furlbrow: At least they left the pumpkins. Nobody wants the pumpkins.")
          end },
        { id = "defias1", x = 10, y = 28, sprite = "hero", tint = { 0.85, 0.3, 0.3 }, face = "right",
          trainer = "defias1", sight = 2 },
        { id = "defias2", x = 10, y = 20, sprite = "hero", tint = { 0.8, 0.35, 0.35 }, face = "left",
          trainer = "defias2", sight = 3 },
        { id = "defias3", x = 5, y = 12, sprite = "hero", tint = { 0.75, 0.3, 0.4 }, face = "left",
          trainer = "defias3", sight = 2 },
        { id = "farmer1", x = 18, y = 14, sprite = "girl", tint = { 1, 0.9, 0.7 }, face = "down",
          trainer = "farmer1", sight = 3 },
        { id = "militia1", x = 13, y = 8, sprite = "bald", tint = { 0.6, 0.7, 1 }, face = "left",
          trainer = "militia1", sight = 2 },
    },
}

Maps.saldean = {
    name = "Saldean's Farm",
    music = "plains",
    rows = {
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "fbffffffdf",
        "ffffffffff",
        "ffftffffff",
        "ffffffffpf",
        "ffffffffff",
        "WWWWrWWWWW",
    },
    warps = { { x = 4, y = 7, map = "westfall", tx = 19, ty = 23, face = "down" } },
    npcs = {
        { id = "salma", name = "Salma Saldean", role = "rest", x = 6, y = 4, sprite = "girl", tint = { 1, 0.85, 0.75 }, face = "left",
          script = function(G)
              G:Say("Salma Saldean: You look half starved, and so do your beasts. Sit down, I've a stew on.")
              G:HealParty()
              G:Say("Your beasts are fully rested! Salma's stew is famous all over Westfall.")
          end },
        { id = "saldean", name = "Farmer Saldean", x = 2, y = 3, sprite = "bald", tint = { 1, 0.9, 0.75 }, face = "down",
          script = function(G)
              G:Say("Farmer Saldean: The Defias have taken half the farms in Westfall. The People's Militia is all that stands against them.")
              G:Say("Farmer Saldean: Gryan Stoutmantle leads them from Sentinel Hill, up the road north.")
          end },
    },
}

---------------------------------------------------------------------------
-- Sentinel Hill
---------------------------------------------------------------------------

Maps.sentinel = {
    name = "Sentinel Hill",
    music = "plains",
    outdoor = true,
    theme = "westfall",
    rows = {
        "TTTTTTTTTTTTTTTTTTTT",
        "T..................T",
        "T..................T",
        "T..................T",
        "T..................T",
        "T..................T",
        "T..................T",
        "T..................T",
        "T..................T",
        "====================",
        "====================",
        "T........==........T",
        "T.h......==......h.T",
        "T.......h==h.......T",
        "T........==........T",
        "TTTTTTTTT==TTTTTTTTT",
    },
    edges = { south = { map = "westfall", dx = 2 }, west = { map = "moonbrook", dy = -2 },
              east = { map = "ravenhill", dy = 0 } },
    triggers = {
        { x = 19, y = 9, cond = function(G) return not G:Flag("badge_vancleef") end, script = function(G) G:DuskwoodGate() end },
        { x = 19, y = 10, cond = function(G) return not G:Flag("badge_vancleef") end, script = function(G) G:DuskwoodGate() end },
    },
    stamps = {
        { kind = "stonehouse", x = 2, y = 3 },              -- the inn, door (5, 8)
        { kind = "stonehouse", x = 12, y = 3 },             -- militia barracks, door (15, 8)
        { kind = "wbigtree", x = 8, y = 1 },
    },
    warps = {
        { x = 5, y = 8, map = "sentinelinn", tx = 4, ty = 6, face = "up" },
    },
    objects = {
        { x = 7, y = 8, tile = "wantedboard", hint = "Read the bounty board", script = function(G) G:BountyBoard() end },    -- the same bounty board
        { x = 17, y = 7, tile = "anvil", station = "anvil", hint = "Smith at the anvil", script = function(G) G:CraftAt("blacksmithing") end },
        { x = 18, y = 7, tile = "forge", station = "forge", hint = "Smelt at the forge", script = function(G) G:CraftAt("mining") end },
    },
    signs = {
        { x = 8, y = 11, text = "SENTINEL HILL\nHeadquarters of the People's Militia." },
        { x = 1, y = 8, text = "MOONBROOK and THE DEADMINES: west.\nDefias territory. The road is watched." },
        { x = 18, y = 11, text = "DUSKWOOD: east.\nRaven Hill, then Darkshire." },
    },
    npcs = {
        { id = "gryan", name = "Gryan Stoutmantle", x = 11, y = 6, sprite = "hero", tint = { 0.75, 0.75, 1 }, face = "down",
          script = function(G)
              if G:Flag("badge_vancleef") then
                  G:Say("Gryan Stoutmantle: VanCleef's bandana... then it's true. The Brotherhood is broken!")
                  G:Say("Gryan Stoutmantle: Westfall owes you more than it can pay, {PLAYER}. The People's Militia salutes you.")
                  if not G:Flag("badge_nightwatch") then
                      G:Say("Gryan Stoutmantle: Now Darkshire needs help. The dead walk in Duskwood. Scout Galiaan will let you through on the east road.")
                  end
                  return
              end
              if G:Flag("beat_militia1") then
                  G:Say("Gryan Stoutmantle: So you're the tamer who beat Sergeant Dane. The Light knows we could use you.")
              else
                  G:Say("Gryan Stoutmantle: Welcome to Sentinel Hill, stranger. Stormwind has forgotten Westfall, but the People's Militia has not.")
              end
              G:Say("Gryan Stoutmantle: Edwin VanCleef and his Brotherhood hide in the Deadmines under Moonbrook. One day we'll root them out.")
          end },
        { id = "thor", name = "Thor", role = "gryphon", x = 18, y = 4, sprite = "bald", tint = { 0.95, 0.85, 0.6 }, face = "left",      -- gryphon master
          script = function(G)
              G:Say("Thor: Gryphons to Stranglethorn. Short John Mithril runs beast fights at the Gurubashi Arena these days.")
              if G:Flag("fp_darkshire") then                  -- Felicia Maline sent word: Darkshire too
                  local D = ns.AzeroData
                  local i = G:Choose("Thor: Where to?", { "Gurubashi Arena (" .. D.Money(50) .. ")",
                                                         "Darkshire (" .. D.Money(30) .. ")", "Stay" })
                  if i == 2 then
                      if G.save.money < 30 then
                          G:Say("Thor: That's " .. D.Money(30) .. ", friend.")
                          return
                      end
                      G.save.money = G.save.money - 30
                      G:EnterMap("darkshire", 17, 14, "down")
                      G:Say("You fly east over Duskwood's black treetops. Darkshire's lamps glow below.")
                      return
                  elseif i ~= 1 then
                      G:Say("Thor: Safe travels on foot, then.")
                      return
                  end
              elseif not G:YesNo("Thor: Fly to the Gurubashi Arena? " .. ns.AzeroData.Money(50) .. ".") then
                  G:Say("Thor: Safe travels on foot, then.")
                  return
              end
              if G.save.money < 50 then
                  G:Say("Thor: That's " .. ns.AzeroData.Money(50) .. ", friend.")
                  return
              end
              G.save.money = G.save.money - 50
              G:EnterMap("arena", 7, 11, "up")
              G:Say("You fly south over the Westfall coast, all the way to Stranglethorn Vale...")
          end },
        { id = "galiaan", name = "Scout Galiaan", x = 18, y = 8, sprite = "girl", tint = { 0.75, 0.65, 0.95 }, face = "down",
          script = function(G)
              if G:Flag("badge_vancleef") then
                  G:Say("Scout Galiaan: The road east is open. Duskwood is dark even at noon, so keep your beasts close.")
              else
                  G:DuskwoodGate()
              end
          end },
        { id = "danuvin", name = "Captain Danuvin", x = 4, y = 12, sprite = "bald", tint = { 0.65, 0.7, 1 }, face = "right",
          script = function(G)
              G:Say("Captain Danuvin: The Defias grow bolder every day. Keep your beasts close on the road.")
          end },
    },
}

Maps.sentinelinn = {
    name = "Sentinel Hill Inn",
    music = "tavern",
    rows = {
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "ffffffffff",
        "fcccffcccf",
        "ffffffffff",
        "ffffffffff",
        "pffffffffp",
        "WWWWrWWWWW",
    },
    warps = { { x = 4, y = 7, map = "sentinel", tx = 5, ty = 9, face = "down" } },
    npcs = {
        { id = "heather", name = "Innkeeper Heather", role = "inn", x = 2, y = 2, sprite = "girl", tint = { 1, 0.85, 0.7 }, face = "down",
          script = function(G)
              G:Say("Innkeeper Heather: Welcome to Sentinel Hill! It's not Stormwind, but the beds are warm.")
              if G:YesNo("Innkeeper Heather: Let your beasts rest here?") then
                  G:HealParty()
                  G:SetRespawn("sentinelinn", 4, 5, "up", "Sentinel Hill")
                  G:Say("Innkeeper Heather: All rested! I'll keep a bed for you, should you come back in a hurry.")
              end
          end },
        { id = "lewis", name = "Quartermaster Lewis", role = "shop", x = 7, y = 2, sprite = "bald", tint = { 0.8, 0.85, 1 }, face = "down",
          script = function(G)
              G:Say("Quartermaster Lewis: The Militia's stores are open to friends of Sentinel Hill.")
              G:Shop("Quartermaster Lewis")
              G:Say("Quartermaster Lewis: Stay safe out there.")
          end },
        { id = "kirk", name = "Kirk Maxwell", role = "stable", x = 8, y = 5, sprite = "bald", tint = { 0.95, 0.85, 0.7 }, face = "left",       -- stable master
          script = function(G)
              G:Say("Kirk Maxwell: Kirk Maxwell, stable master. Same stable as Goldshire's, we share the ledger.")
              G:Stable()
              G:Say("Kirk Maxwell: They'll be well looked after. Come back anytime.")
          end },
    },
}

---------------------------------------------------------------------------
-- Moonbrook: the Defias town over the Deadmines
---------------------------------------------------------------------------

Maps.moonbrook = {
    name = "Moonbrook",
    music = "plains",
    herbs = { "briarthorn", "mageroyal" }, ores = { "tin", "copper" },
    nodes = { herb = { { 22, 14 }, { 4, 12 } }, ore = { { 4, 3 }, { 22, 2 } } },
    outdoor = true,
    theme = "westfall",
    rows = {
        "RRRRTTTTTTTTTTTTTTTTTTTT",
        "RRRR...................T",
        "RRRR...................T",
        "RRRR...................T",
        "RRRR...................T",
        "RRRR...................T",
        "RRRR...................T",
        "R=======================",
        "R=======================",
        "RRRR...................T",
        "RRRR................\"\"\"T",
        "RRRR................\"\"\"T",
        "RRRR................\"\"\"T",
        "RRRR................\"\"\"T",
        "RRRR...................T",
        "RRRRTTTTTTTTTTTTTTTTTTTT",
    },
    edges = { east = { map = "sentinel", dy = 2 } },
    stamps = {
        { kind = "mineentrance", x = 1, y = 5 },       -- the door is (2, 6), right on the road
        { kind = "ruinhouse", x = 6, y = 1 }, { kind = "ruinhouse", x = 13, y = 1 },
        { kind = "ruinhouse", x = 6, y = 9 }, { kind = "ruinhouse", x = 13, y = 9 },
    },
    warps = { { x = 2, y = 6, map = "dm1", tx = 23, ty = 13, face = "up" } },
    signs = {
        { x = 21, y = 6, text = "MOONBROOK\nOnce a proud town. Now the Defias Brotherhood's." },
        { x = 4, y = 9, text = "THE DEADMINES\nKeep out. By order of the Brotherhood." },
    },
    encounters = {
        { sp = "coyote", min = 14, max = 16, weight = 40 },
        { sp = "fleshripper", min = 14, max = 16, day = 30, night = 10 },
        { sp = "dustdevil", min = 15, max = 16, weight = 20 },
    },
    npcs = {
        { id = "defias4", x = 19, y = 6, sprite = "hero", tint = { 0.85, 0.3, 0.3 }, face = "down",
          trainer = "defias4", sight = 2 },
        { id = "defias5", x = 11, y = 9, sprite = "bald", tint = { 0.8, 0.35, 0.3 }, face = "up",
          trainer = "defias5", sight = 2 },
    },
}

---------------------------------------------------------------------------
-- The Deadmines (caves: wild beasts on any floor tile)
---------------------------------------------------------------------------

local function Vanished(id) return function(G) return G:Flag("beat_" .. id) end end

Maps.dm1 = {
    name = "The Deadmines",
    music = "mine",
    ores = { "copper", "tin" },
    nodes = { ore = { { 5, 5 }, { 19, 12 }, { 24, 12 } } },
    theme = "mine",
    cave = { rate = 6 },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTSTTTSTTTSTTTSTTTTTTT",
        "TTTT....................TT",
        "TTTT.==================.TT",
        "TTTT..................=.TT",
        "TTg....gTTTTTTTTTTTTT.=.TT",
        "TT......TTTTTTTTTTTTS.=.TT",
        "TT......TTTTTTTTTTTTT.=.TT",
        "TT......TTTTTTTTTTTTT.=.TT",
        "TT......TTTTTTTTTTTTS.=.ST",
        "TT......TTTTTTTTTTTk..=.kT",
        "TT......TTTTTTTTTTT...=..T",
        "TTT.TTTTTTTTTTTTTTT...=..T",
        "TTTLTTTTTTTTTTTTTTTg....LT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTT",
    },
    warps = {
        { x = 24, y = 14, map = "moonbrook", tx = 2, ty = 7, face = "down" },
        { x = 3, y = 14, map = "dm2", tx = 2, ty = 2, face = "down" },
    },
    encounters = {
        { sp = "tunneler", min = 15, max = 17, weight = 30 },
        { sp = "minespider", min = 15, max = 17, weight = 35 },
        { sp = "kobling", min = 14, max = 16, weight = 20 },
        { sp = "webling", min = 14, max = 16, weight = 15 },
    },
    npcs = {
        { id = "miner2", x = 12, y = 3, sprite = "bald", tint = { 0.8, 0.6, 0.4 }, face = "down", trainer = "miner2", sight = 2 },
        { id = "miner3", x = 21, y = 7, sprite = "hero", tint = { 0.8, 0.35, 0.3 }, face = "right", trainer = "miner3", sight = 2 },
        { id = "rhahkzor", x = 3, y = 13, sprite = "bald", tint = { 0.55, 0.75, 0.45 }, face = "up",
          trainer = "rhahkzor", sight = 0, hidden = Vanished("rhahkzor") },
    },
}

Maps.dm2 = {
    name = "The Deadmines: Goblin Foundry",
    music = "mine",
    ores = { "tin", "copper" },
    nodes = { ore = { { 22, 2 }, { 1, 9 }, { 22, 12 } } },
    theme = "mine",
    cave = { rate = 6 },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTT",
        "T.L..S...S.....S...S...T",
        "T......................T",
        "T.===================..T",
        "T......................T",
        "T............gk........T",
        "T...kkg.............kg.T",
        "T...k..................T",
        "TTTTTTTTTTTT.TTTTTTTTTTT",
        "T.................T....T",
        "T.................T....T",
        "T.......kkg.......T....T",
        "T......................T",
        "T.gk..........gk..T....T",
        "T.................T..L.T",
        "TTTTTTTTTTTTTTTTTTTTTTTT",
    },
    warps = {
        { x = 2, y = 1, map = "dm1", tx = 3, ty = 13, face = "up" },
        { x = 21, y = 14, map = "dm3", tx = 2, ty = 10, face = "right" },
    },
    encounters = {
        { sp = "minespider", min = 17, max = 19, weight = 35 },
        { sp = "tunneler", min = 17, max = 19, weight = 30 },
        { sp = "rustgolem", min = 17, max = 19, weight = 25 },
        { sp = "shredder", min = 18, max = 19, weight = 10 },
    },
    npcs = {
        { id = "goblin1", x = 6, y = 4, sprite = "bald", tint = { 0.55, 0.85, 0.45 }, face = "right", trainer = "goblin1", sight = 3 },
        { id = "sneed", x = 12, y = 8, sprite = "bald", tint = { 0.55, 0.85, 0.45 }, face = "up",
          trainer = "sneed", sight = 0, hidden = Vanished("sneed") },
        { id = "gilnid", x = 18, y = 12, sprite = "bald", tint = { 0.6, 0.8, 0.4 }, face = "left",
          trainer = "gilnid", sight = 0, hidden = Vanished("gilnid") },
    },
}

Maps.dm3 = {
    name = "The Deadmines: Ironclad Cove",
    music = "cove",
    theme = "mine",
    cave = { rate = 5 },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTwwwwwwwwwwwwwwwwwwwwwwwT",
        "TTTTwwwwwwwwwwwwwwwwwwwwwwwT",
        "TTTTwwwwwwwwwwwwwwwwwwwwwwwT",
        "TTTTwwwwwwwDDDDDDnDDDDDDDwwT",
        "TTTTwwwwwwwDDDDDDDDDDDgDDwwT",
        "TTTTwwwwwwwnDDDDDDDDDDDDnwwT",
        "TTTTwwwwwwwDDDDDDDDDDDDDDwwT",
        "TTTTwwwwwwwDDDDDDDDDDDDDDwwT",
        "T........wwDDDDDDDDDDDDDDwwT",
        "TL.......DDDDDDDDDDDDDDDDwwT",
        "T........wwDDDDDDDDDDDDDDwwT",
        "TTTTwwwwwwwDDDDDDDDDDDDDDwwT",
        "TTTTwwwwwwwnDDDDDDDDDDDDnwwT",
        "TTTTwwwwwwwDDDDDDDDDDDDDDwwT",
        "TTTTwwwwwwwDgkgDDDDDDDDDDwwT",
        "TTTTwwwwwwwDDDDDDnDDDDDDDwwT",
        "TTTTwwwwwwwwwwwwwwwwwwwwwwwT",
        "TTTTwwwwwwwwwwwwwwwwwwwwwwwT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    },
    stamps = { { kind = "mast", x = 16, y = 5 }, { kind = "mast", x = 20, y = 11 } },
    warps = { { x = 1, y = 10, map = "dm2", tx = 21, ty = 13, face = "up" } },
    encounters = {
        { sp = "parrot", min = 19, max = 21, weight = 40 },
        { sp = "coastrunner", min = 19, max = 21, weight = 30 },
        { sp = "crawler", min = 19, max = 20, weight = 20 },
        { sp = "tidehunter", min = 20, max = 21, weight = 10 },
    },
    npcs = {
        { id = "smite", x = 10, y = 10, sprite = "bald", tint = { 0.75, 0.6, 0.45 }, face = "left",
          trainer = "smite", sight = 0, hidden = Vanished("smite") },
        { id = "pirate1", x = 13, y = 5, sprite = "hero", tint = { 0.85, 0.3, 0.3 }, face = "down", trainer = "pirate1", sight = 3 },
        { id = "pirate2", x = 22, y = 12, sprite = "hero", tint = { 0.4, 0.5, 0.9 }, face = "left", trainer = "pirate2", sight = 3 },
        { id = "greenskin", x = 18, y = 7, sprite = "bald", tint = { 0.5, 0.85, 0.45 }, face = "down",
          trainer = "greenskin", sight = 0, hidden = Vanished("greenskin") },
        { id = "cookie", x = 13, y = 14, sprite = "bald", tint = { 0.45, 0.65, 0.95 }, face = "down",
          trainer = "cookie", sight = 0, hidden = Vanished("cookie") },
        { id = "vancleef", x = 23, y = 9, sprite = "hero", tint = { 0.85, 0.25, 0.25 }, face = "left",
          trainer = "vancleef", sight = 0, hidden = Vanished("vancleef") },
    },
}

---------------------------------------------------------------------------
-- Duskwood: Raven Hill, the Duskwood road, Manor Mistmantle and Darkshire. The road opens once VanCleef is
-- beaten (Scout Galiaan at Sentinel Hill). Three haunts - Mor'Ladim, Morbent Fel (Sven Yorgen's Bane first) and
-- Stalvan Mistmantle - bring Stitches to Darkshire's gate; beating him earns the Night Watch Seal.
-- gloom = how dark Duskwood's endless dusk is, even at noon (the sky tint never gets lighter than this).
---------------------------------------------------------------------------

local function HauntsDone(G)
    return G:Flag("beat_morladim") and G:Flag("beat_morbentfel") and G:Flag("beat_stalvan") and true or false
end
Maps.HauntsDone = HauntsDone

Maps.ravenhill = {
    name = "Raven Hill",
    music = "duskwood",
    outdoor = true,
    theme = "duskwood",
    gloom = 0.32,
    herbs = { "briarthorn", "mageroyal" }, ores = { "tin" },
    nodes = { herb = { { 22, 12 }, { 1, 4 }, { 9, 20 } }, ore = { { 22, 20 } } },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTT",
        "T......................T",
        "T.....................YT",
        "T......................T",
        "T......................T",
        "T......................T",
        "T...................Y..T",
        "T....\"\"\"\"......\"\"\"\"....T",
        "T....\"\"\"\"......\"\"\"\"....T",
        "========================",
        "========================",
        "T.....\"\"\"\"....\"\"\"\"..Y..T",
        "T..Y..\"\"\"\"....\"\"\"\".....T",
        "T..#######..#######....T",
        "T..#G.G.G.....G.G.#.\"\".T",
        "T..#.............G#.\"\".T",
        "T..#G.G.......G.G.#.\"\".T",
        "T..#..............#.\"\".T",
        "T..#G.G.G....G.G.G#....T",
        "T..################.Y..T",
        "TY.....................T",
        "TTTTTTTTTTTTTTTTTTTTTTTT",
    },
    edges = { west = { map = "sentinel", dy = 0 }, east = { map = "duskwood", dy = 0 } },
    stamps = {
        { kind = "darkhouse", x = 2, y = 1 }, { kind = "darkhouse", x = 9, y = 1 },     -- Raven Hill's empty houses
        { kind = "tent", x = 17, y = 2 },                                                 -- Sven's camp
    },
    signs = {
        { x = 2, y = 8, text = "RAVEN HILL\nMost folk left when the dead began to walk." },
        { x = 12, y = 12, text = "RAVEN HILL CEMETERY\nBy order of the Night Watch: do not disturb the dead." },
    },
    encounters = {
        { sp = "skeleton", min = 22, max = 24, day = 20, night = 40 },
        { sp = "flesheater", min = 22, max = 24, weight = 25 },
        { sp = "pygmyweb", min = 21, max = 23, weight = 30 },
        { sp = "ravager", min = 22, max = 24, day = 20, night = 10 },
        { sp = "worm", min = 22, max = 23, weight = 10 },
    },
    npcs = {
        { id = "sven", name = "Sven Yorgen", x = 19, y = 4, sprite = "bald", tint = { 0.85, 0.75, 0.6 }, face = "left",
          script = function(G)
              if G:Flag("beat_morbentfel") then
                  G:Say("Sven Yorgen: Morbent Fel is gone? Then the farm is mine again. I'll go home... once my hands stop shaking.")
                  return
              end
              if G:Flag("morbentbane") then
                  G:Say("Sven Yorgen: Hold Morbent's Bane high when you face him. His shadows can't hide him from it.")
                  return
              end
              G:Say("Sven Yorgen: The necromancer Morbent Fel drove me off my own farm. It's east of here, south of the road.")
              if not G:Flag("beat_morladim") then
                  G:Say("Sven Yorgen: Blades pass right through him. I know how to fix that... but not while Mor'Ladim walks the cemetery below. His dead would follow me.")
                  return
              end
              G:Say("Sven Yorgen: Mor'Ladim is at rest? Then take this. I had it made in Darkshire, for the day I found the nerve.")
              G:SetFlag("morbentbane")
              G:Say("{PLAYER} received Morbent's Bane!")
          end },
        { id = "nightrunner", x = 13, y = 8, sprite = "hero", tint = { 0.55, 0.3, 0.35 }, face = "down",
          trainer = "nightrunner", sight = 2 },
        { id = "ladimore", x = 5, y = 15, sprite = "hero", tint = { 0.65, 0.85, 1 }, face = "right",
          trainer = "ladimore", sight = 5 },
        { id = "morladim", x = 11, y = 16, sprite = "bald", tint = { 0.55, 0.6, 0.7 }, face = "up",
          trainer = "morladim", sight = 0, hidden = Vanished("morladim") },
        { id = "jitters", name = "Jitters", x = 16, y = 5, sprite = "bald", tint = { 0.9, 0.85, 0.75 }, face = "down",
          script = function(G)
              G:Say("Jitters: The ravens... they're watching. They're always watching. Don't go into the cemetery. Don't!")
          end },
    },
}

Maps.duskwood = {
    name = "Duskwood",
    music = "duskwood",
    outdoor = true,
    theme = "duskwood",
    gloom = 0.34,
    herbs = { "briarthorn", "mageroyal" }, ores = { "tin", "copper" },
    nodes = { herb = { { 1, 3 }, { 16, 16 }, { 24, 22 } }, ore = { { 20, 13 }, { 2, 13 } } },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "T...............TT.........T",
        "T........Y......TT.........T",
        "T.........\"\"\"\"\".........TTTT",
        "T.........\"\"\"\"\".........TTTT",
        "T.........\"\"\"\"\".........TTTT",
        "T...........\"\"\"\"...........T",
        "T......TT.............=....T",
        "T.....................=....T",
        "============================",
        "============================",
        "T..........................T",
        "TY...........\"\"\"\"\"\"TT.....YT",
        "T.........TT.\"\"\"\"\"\"........T",
        "T.........TT.\"\"\"\"\"\"........T",
        "TTT........................T",
        "TTT.......Y..Y.............T",
        "TTT...............Y........T",
        "TTT...........TTTT..\"\"\"\"\"\".T",
        "T...........Y.TTTT..\"\"\"\"\"\".T",
        "T\"\"\"..........TTTT..\"\"\"\"\"\".T",
        "T\"\"\".Y...Y....TTTT..\"\"\"\"\"\".T",
        "T\"\"\"..................Y....T",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    },
    edges = { west = { map = "ravenhill", dy = 0 }, east = { map = "darkshire", dy = 0 } },
    stamps = {
        { kind = "darkhouse", x = 2, y = 1 },       -- Addle's Stead
        { kind = "darkhouse", x = 19, y = 1 },      -- Manor Mistmantle, door (22, 6)
        { kind = "darkhouse", x = 4, y = 14 },      -- the Yorgen farmhouse
        { kind = "dbigtree", x = 23, y = 14 },
    },
    warps = { { x = 22, y = 6, map = "mistmantle", tx = 4, ty = 6, face = "up" } },
    signs = {
        { x = 1, y = 8, text = "DUSKWOOD\nWest: Raven Hill and Westfall. East: Darkshire." },
        { x = 26, y = 11, text = "DARKSHIRE: east.\nThe Night Watch keeps the lamps lit." },
    },
    encounters = {
        { sp = "darkrunner", min = 24, max = 26, day = 10, night = 35 },
        { sp = "ravager", min = 24, max = 26, weight = 25 },
        { sp = "pygmyweb", min = 23, max = 25, weight = 20 },
        { sp = "venomweb", min = 25, max = 26, weight = 12 },
        { sp = "worm", min = 24, max = 25, weight = 15 },
        { sp = "splinterfist", min = 25, max = 26, day = 10, night = 5 },
        { sp = "lupos", min = 27, max = 27, day = 0, night = 2, rare = true },
    },
    npcs = {
        { id = "abercrombie", name = "Abercrombie", x = 8, y = 5, sprite = "bald", tint = { 0.75, 0.8, 0.7 }, face = "down",
          script = function(G)
              if G:Flag("beat_stitches") then
                  G:Say("Abercrombie: You broke my friend! All those stitches... do you know how long that took?")
              elseif HauntsDone(G) then
                  G:Say("Abercrombie: My friend is finished at last! He's gone for a walk. Toward Darkshire. Isn't that nice?")
              else
                  G:Say("Abercrombie: Hello, hello! Just gathering a few... supplies. For a friend. A very big friend.")
              end
          end },
        { id = "nightblade", x = 9, y = 11, sprite = "hero", tint = { 0.45, 0.3, 0.4 }, face = "up",
          trainer = "nightblade", sight = 2 },
        { id = "dodds", x = 15, y = 8, sprite = "hero", tint = { 0.7, 0.75, 0.95 }, face = "down",
          trainer = "dodds", sight = 3 },
        { id = "ogre1", x = 22, y = 17, sprite = "bald", tint = { 0.75, 0.6, 0.45 }, face = "left",
          trainer = "ogre1", sight = 3 },
        { id = "morbentfel", x = 11, y = 18, sprite = "hero", tint = { 0.45, 0.35, 0.6 }, face = "left",
          trainer = "morbentfel", sight = 0, hidden = Vanished("morbentfel") },
        { id = "watchguard", name = "Night Watch Guard", x = 25, y = 8, sprite = "hero", tint = { 0.7, 0.75, 0.95 }, face = "down",
          script = function(G)
              G:Say("Night Watch Guard: Darkshire's just east. Stay on the road and stay near the lamps.")
          end },
    },
}

Maps.mistmantle = {
    name = "Manor Mistmantle",
    music = "haunted",
    rows = {
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "fdffffffdf",
        "ffffffffff",
        "ftffffffbf",
        "ffffffffff",
        "pffffffffp",
        "WWWWrWWWWW",
    },
    warps = { { x = 4, y = 7, map = "duskwood", tx = 22, ty = 7, face = "down" } },
    chests = { { id = "mmpotion", x = 7, y = 3, item = "superpotion", n = 2 } },
    npcs = {
        { id = "stalvan", x = 4, y = 3, sprite = "hero", tint = { 0.6, 0.7, 0.9 }, face = "down",
          trainer = "stalvan", sight = 2, hidden = Vanished("stalvan") },
    },
}

Maps.darkshire = {
    name = "Darkshire",
    music = "duskwood",
    outdoor = true,
    theme = "duskwood",
    gloom = 0.26,
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTT",
        "T.....................YT",
        "T......................T",
        "T......................T",
        "T......................T",
        "T......................T",
        "T......................T",
        "T.....=..........=.....T",
        "T.l...=..l....l..=...l.T",
        "=======================T",
        "=======================T",
        "T...l......==...l...l..T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "TY......Y..==.........YT",
        "T..........==..........T",
        "TTTTTTTTTTT==TTTTTTTTTTT",
    },
    edges = { west = { map = "duskwood", dy = 0 }, south = { map = "rebelcamp", dx = 0 } },
    triggers = {
        { x = 11, y = 18, cond = function(G) return not G:Flag("badge_nightwatch") end, script = function(G) G:StranglethornGate() end },
        { x = 12, y = 18, cond = function(G) return not G:Flag("badge_nightwatch") end, script = function(G) G:StranglethornGate() end },
    },
    stamps = {
        { kind = "darkhouse", x = 3, y = 1 },       -- the Scarlet Raven Tavern, door (6, 6)
        { kind = "darkhouse", x = 14, y = 1 },      -- the town hall
        { kind = "tent", x = 4, y = 14 },           -- Madame Eva's wagon
    },
    warps = { { x = 6, y = 6, map = "darkshireinn", tx = 4, ty = 6, face = "up" } },
    objects = {
        { x = 10, y = 8, tile = "wantedboard", hint = "Read the bounty board", script = function(G) G:BountyBoard() end },
    },
    signs = {
        { x = 1, y = 8, text = "DARKSHIRE\nSeat of the Night Watch. The lamps burn all night, every night." },
        { x = 13, y = 11, text = "SOUTH: Madame Eva, fortunes told.\nGryphons to Sentinel Hill." },
    },
    npcs = {
        { id = "stitches", x = 3, y = 9, sprite = "bald", tint = { 0.6, 0.72, 0.55 }, face = "left",
          trainer = "stitches", sight = 3,
          hidden = function(G) return not HauntsDone(G) or G:Flag("beat_stitches") end },
        { id = "ello", name = "Lord Ello Ebonlocke", x = 15, y = 8, sprite = "hero", tint = { 0.95, 0.85, 0.6 }, face = "down",
          script = function(G)
              G:Say("Lord Ello Ebonlocke: Welcome to Darkshire. We hold on because the Night Watch holds on.")
              G:Say("Lord Ello Ebonlocke: Commander Ebonlocke runs the Watch. If you mean to help, talk to her.")
          end },
        { id = "althea", name = "Commander Althea Ebonlocke", x = 18, y = 8, sprite = "girl", tint = { 0.75, 0.8, 1 }, face = "down",
          script = function(G)
              if G:Flag("badge_nightwatch") then
                  G:Say("Commander Althea Ebonlocke: Watcher {PLAYER}. It has a ring to it. Darkshire won't forget what you did.")
                  G:Say("Commander Althea Ebonlocke: The road south is open to you now. Stranglethorn Vale... mind the tigers, Watcher.")
                  return
              end
              if HauntsDone(G) then
                  G:Say("Commander Althea Ebonlocke: Hear the bells? Stitches is at the west gate! {PLAYER}, the Watch needs your beasts!")
                  return
              end
              G:Say("Commander Althea Ebonlocke: So Stoutmantle sent help. Good. Duskwood's dead won't stay buried.")
              local left = {}
              if not G:Flag("beat_morladim") then left[#left + 1] = "Mor'Ladim in the Raven Hill cemetery" end
              if not G:Flag("beat_morbentfel") then left[#left + 1] = "Morbent Fel on the Yorgen farm" end
              if not G:Flag("beat_stalvan") then left[#left + 1] = "whatever haunts Manor Mistmantle" end
              G:Say("Commander Althea Ebonlocke: Three haunts feed this darkness. Still out there: " .. table.concat(left, "; ") .. ".")
          end },
        { id = "eva", name = "Madame Eva", x = 6, y = 16, sprite = "girl", tint = { 0.85, 0.6, 0.9 }, face = "up",
          script = function(G)
              G:Say("Madame Eva: Sit, child. Let the cards speak...")
              if G:Flag("badge_nightwatch") then
                  G:Say("Madame Eva: The cards are quiet tonight. For once.")
              elseif HauntsDone(G) then
                  G:Say("Madame Eva: I see a thing sewn from many... it walks toward our gate. Toward YOU.")
              elseif not G:Flag("beat_morladim") then
                  G:Say("Madame Eva: A grave on Raven Hill that will not stay closed. Start there.")
              elseif not G:Flag("beat_morbentfel") and not G:Flag("morbentbane") then
                  G:Say("Madame Eva: A frightened farmer camps at Raven Hill. He holds a blade that cuts shadow. Ask Sven.")
              elseif not G:Flag("beat_morbentfel") then
                  G:Say("Madame Eva: The Yorgen farm, south of the road. A man of shadows waits for his Bane.")
              else
                  G:Say("Madame Eva: A manor north of the road. Its master never left... and never will, unless you make him.")
              end
          end },
        { id = "felicia", name = "Felicia Maline", role = "gryphon", x = 17, y = 15, sprite = "girl", tint = { 1, 0.9, 0.75 }, face = "left",      -- gryphon master
          script = function(G)
              local D = ns.AzeroData
              if not G:Flag("fp_darkshire") then
                  G:SetFlag("fp_darkshire")
                  G:Say("Felicia Maline: New in Darkshire? I'll send word to Thor at Sentinel Hill. His gryphons can bring you here now.")
              end
              local options, dest = { "Sentinel Hill (" .. D.Money(30) .. ")" }, { "sentinel" }
              if G:Flag("fp_bootybay") then
                  options[#options + 1] = "Booty Bay (" .. D.Money(40) .. ")"
                  dest[#dest + 1] = "bootybay"
              end
              options[#options + 1] = "Stay"
              local to = dest[G:Choose("Felicia Maline: Where to?", options)]
              if not to then
                  G:Say("Felicia Maline: Mind the dark, then.")
                  return
              end
              local cost = (to == "bootybay") and 40 or 30
              if G.save.money < cost then
                  G:Say("Felicia Maline: That's " .. D.Money(cost) .. ", dear.")
                  return
              end
              G.save.money = G.save.money - cost
              if to == "bootybay" then
                  G:EnterMap("bootybay", 3, 9, "down")
                  G:Say("You fly south over the whole of Stranglethorn, down to Booty Bay's docks.")
              else
                  G:EnterMap("sentinel", 17, 4, "right")
                  G:Say("You fly west over the dark treetops, all the way to Sentinel Hill.")
              end
          end },
        { id = "backus", x = 13, y = 12, sprite = "hero", tint = { 0.7, 0.75, 0.95 }, face = "left",
          trainer = "backus", sight = 2 },
        { id = "paige", x = 9, y = 13, sprite = "girl", tint = { 0.7, 0.75, 0.95 }, face = "right",
          trainer = "paige", sight = 2 },
        { id = "dsguard", name = "Night Watch Guard", x = 21, y = 12, sprite = "hero", tint = { 0.7, 0.75, 0.95 }, face = "left",
          script = function(G)
              G:Say("Night Watch Guard: East is Deadwind Pass. Nobody goes there. South is Stranglethorn Vale, once the Commander says so.")
          end },
    },
}

Maps.darkshireinn = {
    name = "Scarlet Raven Tavern",
    music = "tavern",
    rows = {
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "ffffffffff",
        "fcccffcccf",
        "ffffffffff",
        "ffffffffff",
        "pffffffffp",
        "WWWWrWWWWW",
    },
    warps = { { x = 4, y = 7, map = "darkshire", tx = 6, ty = 7, face = "down" } },
    npcs = {
        { id = "trelayne", name = "Innkeeper Trelayne", role = "inn", x = 2, y = 2, sprite = "girl", tint = { 0.95, 0.8, 0.75 }, face = "down",
          script = function(G)
              G:Say("Innkeeper Trelayne: Welcome to the Scarlet Raven. Warm beds, and the doors lock at night.")
              if G:YesNo("Innkeeper Trelayne: Let your beasts rest here?") then
                  G:HealParty()
                  G:SetRespawn("darkshireinn", 4, 5, "up", "Darkshire")
                  G:Say("Innkeeper Trelayne: There. Rested, and safe behind the Watch's walls.")
              end
          end },
        { id = "hann", name = "Barkeep Hann", role = "shop", x = 7, y = 2, sprite = "bald", tint = { 0.9, 0.8, 0.7 }, face = "down",
          script = function(G)
              G:Say("Barkeep Hann: Supplies for the road? You'll want them out there.")
              G:Shop("Barkeep Hann")
              G:Say("Barkeep Hann: Come back in one piece.")
          end },
        { id = "dsstable", name = "Stable Master", role = "stable", x = 8, y = 5, sprite = "bald", tint = { 0.8, 0.8, 0.9 }, face = "left",     -- stable master
          script = function(G)
              G:Say("Stable Master: Same stable ledger as Goldshire's and Sentinel Hill's. Your beasts are safe with me.")
              G:Stable()
              G:Say("Stable Master: Come back anytime.")
          end },
    },
}
