-- CDLoot Games/Azeromon/Maps.lua
-- ns.AzeroMaps: the overworld. Each map is a grid of characters plus objects:
--   .  grass            "  tall grass (encounters)     =  dirt path       T  tree        w  water
--   W  wall   f  floor   r  exit mat   b  bed   d  shelf   p  pot   t  table   C  chest   c  counter   X  void
-- stamps   { kind = "house"|"bigtree"|"mailbox", x, y }        (house door: x + 3, y + 5)
-- signs    { x, y, text }
-- npcs     { id, x, y, sprite, face, tint, script = fn(G, npc), trainer, sight, hidden = fn(G) }
-- chests   { id, x, y, item, n } (opened once)   objects { x, y, tile, script } (solid, interactable)
-- warps    { x, y, map, tx, ty, face }           edges { north|south = { map, dx } }
-- triggers { x, y, script = fn(G), cond = fn(G) } run when the player steps on the tile
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
    warps = {
        { x = 5, y = 6, map = "home", tx = 4, ty = 6, face = "up" },
        { x = 17, y = 6, map = "lab", tx = 4, ty = 6, face = "up" },
        { x = 5, y = 16, map = "post", tx = 4, ty = 6, face = "up" },
    },
    edges = { north = { map = "route1", dx = 0 } },
    npcs = {
        { id = "guard", x = 12, y = 1, sprite = "bald", tint = { 0.55, 0.65, 1 }, face = "left",   -- Marshal Dughan
          script = function(G)
              if G:Flag("starter") then
                  G:Say("Marshal Dughan: The road north runs through Elwynn Forest toward Westfall. Mind the tall grass, and keep an eye out for Hogger.")
              else
                  G:Say("Marshal Dughan: Wolves, kobolds and worse lurk in the forest.\nNobody leaves Goldshire without a beast of their own.")
              end
          end },
        { id = "farmer", x = 8, y = 12, sprite = "bald", tint = { 1, 0.85, 0.6 }, face = "down", wander = true,
          script = function(G)
              G:Say("Maybell Maclure: Huntmaster Aldric can tame anything, they say. His lodge is in the northeast.\nIf you see Tommy Joe Stonefield... never mind.")
          end },
        { id = "kid", x = 14, y = 9, sprite = "hero", tint = { 1, 0.75, 0.75 }, face = "left", wander = true,
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
        { id = "mom", x = 6, y = 4, sprite = "girl", tint = { 0.85, 0.75, 1 }, face = "left",
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
        { id = "aldric", x = 4, y = 3, sprite = "bald", tint = { 0.95, 0.95, 0.8 }, face = "down",
          script = function(G)
              if not G:Flag("starter") then
                  G:Say("Huntmaster Aldric: Ah, {PLAYER}! I've been expecting you.")
                  G:Say("Huntmaster Aldric: Every hunter of the Alliance begins with a single beast. Today, so do you.")
                  G:Say("Huntmaster Aldric: A red whelp, a murloc from Crystal Lake and a bloodpetal from Un'Goro. Pick one of these crates!")
              else
                  G:Say("Huntmaster Aldric: A hunter and a beast that fight together grow stronger together.\nFill that Bestiary for me!")
                  G:ShowDexSummary()
              end
          end },
        { id = "rival", x = 7, y = 5, sprite = "girl", face = "left",
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
    warps = { { x = 4, y = 7, map = "town", tx = 5, ty = 17, face = "down" } },
    npcs = {
        { id = "healer", x = 2, y = 2, sprite = "girl", tint = { 1, 0.8, 0.85 }, face = "down",
          script = function(G)
              G:Say("Innkeeper Farley: Welcome to the Lion's Pride Inn!")
              if G:YesNo("Innkeeper Farley: Shall I give your beasts a warm meal and a place by the fire?") then
                  G:HealParty()
                  G:SetRespawn("post", 4, 5, "up", "the Lion's Pride Inn")
                  G:Say("Innkeeper Farley: Your beasts are fighting fit! Come back anytime.")
              else
                  G:Say("Innkeeper Farley: Come back anytime.")
              end
          end },
        { id = "clerk", x = 7, y = 2, sprite = "bald", tint = { 0.7, 1, 0.7 }, face = "down",
          script = function(G)
              G:Say("Brog Hamfist: Welcome! Potions, rods, the finest goods in Goldshire.")
              G:Shop()
              G:Say("Brog Hamfist: Come again!")
          end },
    },
}

---------------------------------------------------------------------------
-- Elwynn Forest
---------------------------------------------------------------------------

Maps.route1 = {
    name = "Elwynn Forest",
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
    encounters = {
        { sp = "wolfpup", min = 2, max = 4, weight = 30 },
        { sp = "owlet", min = 2, max = 4, weight = 25 },
        { sp = "kobling", min = 3, max = 5, weight = 20 },
        { sp = "webling", min = 3, max = 5, weight = 15 },
        { sp = "tuskling", min = 4, max = 5, weight = 10 },
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
        { sp = "coyote", min = 9, max = 12, weight = 30 },
        { sp = "fleshripper", min = 9, max = 12, weight = 20 },
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
        { id = "furlbrow", x = 14, y = 5, sprite = "bald", tint = { 1, 0.85, 0.65 }, face = "right",
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
        { id = "salma", x = 6, y = 4, sprite = "girl", tint = { 1, 0.85, 0.75 }, face = "left",
          script = function(G)
              G:Say("Salma Saldean: You look half starved, and so do your beasts. Sit down, I've a stew on.")
              G:HealParty()
              G:Say("Your beasts are fully rested! Salma's stew is famous all over Westfall.")
          end },
        { id = "saldean", x = 2, y = 3, sprite = "bald", tint = { 1, 0.9, 0.75 }, face = "down",
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
        "T=================.T",
        "T=================.T",
        "T........==........T",
        "T.h......==......h.T",
        "T.......h==h.......T",
        "T........==........T",
        "TTTTTTTTT==TTTTTTTTT",
    },
    edges = { south = { map = "westfall", dx = 2 } },
    stamps = {
        { kind = "stonehouse", x = 2, y = 3 },              -- the inn, door (5, 8)
        { kind = "stonehouse", x = 12, y = 3 },             -- militia barracks, door (15, 8)
        { kind = "wbigtree", x = 8, y = 1 },
    },
    warps = {
        { x = 5, y = 8, map = "sentinelinn", tx = 4, ty = 6, face = "up" },
    },
    signs = {
        { x = 8, y = 11, text = "SENTINEL HILL\nHeadquarters of the People's Militia." },
        { x = 1, y = 8, text = "MOONBROOK and THE DEADMINES: west.\nDefias territory. The road is watched.\n\n(Coming soon to Azeromon!)" },
    },
    npcs = {
        { id = "gryan", x = 11, y = 6, sprite = "hero", tint = { 0.75, 0.75, 1 }, face = "down",
          script = function(G)
              if G:Flag("beat_militia1") then
                  G:Say("Gryan Stoutmantle: So you're the tamer who beat Sergeant Dane. The Light knows we could use you.")
              else
                  G:Say("Gryan Stoutmantle: Welcome to Sentinel Hill, stranger. Stormwind has forgotten Westfall, but the People's Militia has not.")
              end
              G:Say("Gryan Stoutmantle: Edwin VanCleef and his Brotherhood hide in the Deadmines under Moonbrook. One day we'll root them out.")
          end },
        { id = "danuvin", x = 4, y = 12, sprite = "bald", tint = { 0.65, 0.7, 1 }, face = "right",
          script = function(G)
              G:Say("Captain Danuvin: The Defias grow bolder every day. Keep your beasts close on the road.")
          end },
    },
}

Maps.sentinelinn = {
    name = "Sentinel Hill Inn",
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
        { id = "heather", x = 2, y = 2, sprite = "girl", tint = { 1, 0.85, 0.7 }, face = "down",
          script = function(G)
              G:Say("Innkeeper Heather: Welcome to Sentinel Hill! It's not Stormwind, but the beds are warm.")
              if G:YesNo("Innkeeper Heather: Let your beasts rest here?") then
                  G:HealParty()
                  G:SetRespawn("sentinelinn", 4, 5, "up", "Sentinel Hill")
                  G:Say("Innkeeper Heather: All rested! I'll keep a bed for you, should you come back in a hurry.")
              end
          end },
        { id = "lewis", x = 7, y = 2, sprite = "bald", tint = { 0.8, 0.85, 1 }, face = "down",
          script = function(G)
              G:Say("Quartermaster Lewis: The Militia's stores are open to friends of Sentinel Hill.")
              G:Shop()
              G:Say("Quartermaster Lewis: Stay safe out there.")
          end },
    },
}
