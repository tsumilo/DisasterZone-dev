if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/MapsStranglethorn.lua", ...) then return end -- DisasterZone_Azeromon/MapsStranglethorn.lua
-- Stranglethorn Vale (the maps join ns.AzeroMaps; the format is described in Maps.lua). The road south from
-- Darkshire opens with the Night Watch Seal. North: the Rebel Camp and Kurzen's Compound, Nesingwary's
-- Expedition and Lake Nazferiti, the Bal'lal and Zul'Mamwe troll ruins, the Mosh'Ogg ogre mound, then the
-- Gurubashi Arena. South: Mistvale Valley and Crystalvein Mine, the Wild Shore with the Ruins of Aboraz and the
-- Bloodsail camp, Booty Bay, and Jaguero Isle by boat.
-- Badges: Nesingwary's Trophy (King Bangalash, then Hemet Nesingwary Jr.) and the Blackwater Seal (the Bloodsail
-- captains, then Fleet Master Firallon on his ship).
-- 0.48: every map redrawn organic like Blackrock's - carved out of the jungle, winding roads, a real lake and coast,
-- caves you walk through, Booty Bay round its harbour (dev/art/casc/zone_mockup/stranglethorn: layout.py draws them,
-- apply.py writes them here). rev = 2 on each: presence and guild marks hide spots from the old layout (Net.lua),
-- and saves standing on one move to its nearest road (Game.lua G.MigrateStranglethorn).
local addonName, ns = ...

local Maps = ns.AzeroMaps
local D = ns.AzeroData

local function Vanished(id) return function(G) return G:Flag("beat_" .. id) end end

-- Nesingwary's three hunters: beaten, King Bangalash comes out of the jungle.
local function HuntersDone(G)
    return G:Flag("beat_ajeck") and G:Flag("beat_erlgadin") and G:Flag("beat_barnil") and true or false
end
Maps.HuntersDone = HuntersDone

local function CaptainsDone(G)
    return G:Flag("beat_keelhaul") and G:Flag("beat_stillwater") and true or false
end
Maps.CaptainsDone = CaptainsDone

---------------------------------------------------------------------------
-- The Rebel Camp: Lieutenant Doren's deserters from Kurzen's expedition, just over the Duskwood border
---------------------------------------------------------------------------

Maps.rebelcamp = {
    name = "The Rebel Camp",
    rev = 2,                -- 2: redrawn organic (0.48)
    music = "arena",
    outdoor = true,
    theme = "jungle",
    herbs = { "mageroyal", "briarthorn" }, ores = { "tin", "copper" },
    nodes = { herb = { { 4, 14 }, { 20, 15 } }, ore = { { 28, 3 }, { 1, 13 } } },
    rows = {
        "TTTTTTTTTTTTTT==TTTTTTTTTTTTTT",
        "TTTTTTTTTTTT..==....TTTTTTTTTT",
        "TTTTTTTTT.....==...\"TTTTTTTTTT",
        "T.............==...\"TTT......T",
        "T.............==...\"TTT......T",
        "T.............==..T.TT.......T",
        "T............===..TT.........T",
        "T............===.............T",
        "T...........===TT.....##...##T",
        "T.....i.i...===TT........k...T",
        "Tkk.........==.........\"\"\"TTTT",
        "T...........==......\"\"\"\"\"\"TTTT",
        "T...........===.....\"\"\"\"\"\"\";;T",
        "T...........===......\"\"\";;;;ww",
        "TTTT.........===......;;;wwwww",
        "TTTTTT\"\".....====....;;wwwwwwT",
        "TTTTTT\"\"\"..;;;====;;;wwwww;;;T",
        "TTTTT\"\"\";;;;wwwwDDwwwww;;;;TTT",
        "T;;;;;;;;wwwwwwwDDwww;;TTTTTTT",
        "wwwwwwwwwwwww;;;==;;;TTTTTTTTT",
        "wwwwwww;;;;;;;..==..TTTTTTTTTT",
        "T;;;;;;TTT......==..TTTTTTTTTT",
        "TTTTTTTTTT..TT..==..TTTTTTTTTT",
        "TTTTTTTTTTTTTTTT==TTTTTTTTTTTT",
    },
    edges = { north = { map = "darkshire", dx = -3 }, south = { map = "stvnorth", dx = 0 } },
    stamps = {
        { kind = "mineentrance", x = 24, y = 4 },               -- Kurzen's Compound, door (25, 5)
        { kind = "tent", x = 2, y = 4 }, { kind = "tent", x = 6, y = 3 }, -- the deserters' tents round the fire
        { kind = "tent", x = 2, y = 11 },
        { kind = "jbigtree", x = 7, y = 11 },
    },
    warps = { { x = 25, y = 5, map = "kurzen", tx = 4, ty = 16, face = "right" } },
    objects = {
        { x = 10, y = 7, tile = "wantedboard", hint = "Read the bounty board", script = function(G) G:BountyBoard() end },
    },
    signs = {
        { x = 12, y = 4, text = "THE REBEL CAMP\nNorth: Duskwood. South: Nesingwary's Expedition and the vale.\nEast: Kurzen's Compound. Keep out." },
        { x = 22, y = 7, text = "KURZEN'S COMPOUND\nProperty of Colonel Kurzen. Deserters will be shot." },
    },
    encounters = {
        { sp = "tigercub", min = 30, max = 32, weight = 30 },
        { sp = "pantherkit", min = 30, max = 32, day = 10, night = 30 },
        { sp = "raptorling", min = 31, max = 33, weight = 20 },
        { sp = "trollscout", min = 31, max = 33, day = 10, night = 20 },
        { sp = "crystalspine", min = 32, max = 33, weight = 10 },
    },
    coastEncounters = {
        { sp = "rivercroc", min = 31, max = 33, weight = 60 },
        { sp = "tidehunter", min = 31, max = 33, weight = 25 },
        { sp = "crawler", min = 30, max = 32, weight = 15 },
    },
    chests = { { id = "rcnets", x = 19, y = 21, item = "net", n = 4 } },
    npcs = {
        { id = "doren", name = "Lieutenant Doren", x = 10, y = 10, sprite = "hero", tint = { 0.7, 0.8, 1 }, face = "left",
          script = function(G)
              if G:Flag("beat_kurzen") then
                  G:Say("Lieutenant Doren: Kurzen is finished? Then his men can come home. Stormwind will hear it was you.")
                  G:Say("Lieutenant Doren: The vale runs south from here, all the way to Booty Bay. Nesingwary's camp is the first stop.")
                  return
              end
              G:Say("Lieutenant Doren: We were Colonel Kurzen's men, once. The jungle got into his head, and troll medicine got into the rest of him.")
              G:Say("Lieutenant Doren: His compound is in the cave east of here. If you can fight your way to him, do what we couldn't.")
          end },
        { id = "nimetz", name = "Brother Nimetz", role = "rest", x = 7, y = 8, sprite = "bald", tint = { 0.95, 0.9, 0.8 }, face = "down",
          script = function(G)
              G:Say("Brother Nimetz: The Light keeps this camp, and so do I. Your beasts look tired.")
              if G:YesNo("Brother Nimetz: Let them rest by the fire?") then
                  G:HealParty()
                  G:SetRespawn("rebelcamp", 7, 9, "up", "the Rebel Camp")       -- by the fire, under his tree
                  G:Say("Brother Nimetz: There. The jungle can wait a little longer.")
              end
          end },
        { id = "rcquarter", name = "Corporal Sethman", role = "shop", x = 4, y = 9, sprite = "bald", tint = { 0.8, 0.75, 0.6 }, face = "right",
          script = function(G)
              G:Say("Corporal Sethman: Supplies from Darkshire, when the wagons get through. Take a look.")
              G:Shop("Corporal Sethman")
              G:Say("Corporal Sethman: Mind the tigers.")
          end },
        { id = "kaleb", x = 12, y = 12, sprite = "hero", tint = { 0.7, 0.8, 1 }, face = "right", trainer = "kaleb", sight = 2 },
        { id = "bluth", x = 18, y = 20, sprite = "hero", tint = { 0.75, 0.8, 0.95 }, face = "left", trainer = "bluth", sight = 2 },
    },
}

Maps.kurzen = {
    name = "Kurzen's Compound",
    rev = 2,                -- 2: redrawn organic (0.48)
    music = "mine",
    theme = "mine",
    cave = { rate = 6 },
    ores = { "tin", "copper" },
    nodes = { ore = { { 16, 4 }, { 11, 16 } } },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTSTT",
        "TTTTTTTTTTk.TTTTTTTTTTTTTT..TT",
        "TTTTTTTTik..gSTTTTTTTTTTS...TT",
        "TTTTTTT..........TTTTTTT...TTT",
        "TTTTTT............STTTT...TTTT",
        "TTTTTT.==========...iTS...TTTT",
        "TTTTTT.=.................TTiTT",
        "TTTTT..=.......kg...........TT",
        "TTTTT===TT.....TTT..........TT",
        "TTTTS=.TTTTTTTiTTT..........ST",
        "TTTT.=.TTTTTTS...............T",
        "TTTT.=.TTT...................T",
        "TTik.=.TS....................T",
        "TT...........www..TTT.......TT",
        "TT..........wwwww.TTTT......TT",
        "TT.L.........www.TTTTTTTT..TTT",
        "TTT.....TTTT...TTTTTTTTTTTTTTT",
        "TTTT...TTTTTT.TTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    },
    warps = { { x = 3, y = 16, map = "rebelcamp", tx = 25, ty = 6, face = "down" } },
    chests = { { id = "kzpotion", x = 26, y = 2, item = "superpotion", n = 2 } },
    encounters = {
        { sp = "crystalspine", min = 33, max = 35, weight = 35 },
        { sp = "pantherkit", min = 33, max = 35, weight = 30 },
        { sp = "tigercub", min = 33, max = 35, weight = 25 },
        { sp = "trollscout", min = 34, max = 35, weight = 10 },
    },
    npcs = {
        { id = "kfighter", x = 12, y = 4, sprite = "hero", tint = { 0.6, 0.7, 0.5 }, face = "down", trainer = "kfighter", sight = 3 },
        { id = "kmedicine", x = 16, y = 13, sprite = "bald", tint = { 0.6, 0.75, 0.55 }, face = "left", trainer = "kmedicine", sight = 3 },
        { id = "kheadshrinker", x = 19, y = 10, sprite = "bald", tint = { 0.55, 0.65, 0.5 }, face = "right", trainer = "kheadshrinker", sight = 3 },
        { id = "kurzen", x = 26, y = 12, sprite = "hero", tint = { 0.5, 0.6, 0.45 }, face = "left",
          trainer = "kurzen", sight = 0, hidden = Vanished("kurzen") },
    },
}

---------------------------------------------------------------------------
-- Northern Stranglethorn: Nesingwary's Expedition, Lake Nazferiti, the Bal'lal Ruins
---------------------------------------------------------------------------

Maps.stvnorth = {
    name = "Northern Stranglethorn",
    rev = 2,                -- 2: redrawn organic (0.48)
    music = "arena",
    outdoor = true,
    theme = "jungle",
    herbs = { "mageroyal", "briarthorn" }, ores = { "tin", "copper" },
    nodes = { herb = { { 30, 20 }, { 2, 17 }, { 25, 29 } }, ore = { { 31, 27 }, { 1, 1 } } },
    rows = {
        "TTTTTTTTTTTTTTTT==TTTTTTTTTTTTTTTT",
        "T...........TT..==..TTTTTTTTTTTTTT",
        "T...........TT..==....TTTTTTTTTTTT",
        "T........k..TT.T==..TT.TTTTTTTTTTT",
        "T..k.........TTT==TTTTTTTTTTTTTTTT",
        "T.............T===TT.;;.T.TTTTTTTT",
        "T..............===.;;;;;;;...T...T",
        "T.............===;;;;wwwww;;;;...T",
        "T............====;;wwwwwwwwwwww;TT",
        "T............===;;wwwwwwwwwwwwww;T",
        "TTT..........==;;wwwwwwwwwwwwwww;T",
        "T...\".....TT.==;;wwwwwwwww..wwwwwT",
        "T...T\"....TT.==.;wwwwwwwwwwwwwwwwT",
        "T...T\"\"......==.;wwwwwwwwwwwwwwwwT",
        "T.TT\"\"\"\"\"\"\"\"===..;wwwwwwwwwwwwww;T",
        "TTTT..\"\"\"\"\"\"===..;;wwwwwwwwwwww;TT",
        "TTT...\"\"\"\"\"\"==....;;wwwwwwwwww;;.T",
        "TT.....\"\"\"\".==....;;;;wwwwwwww;;.T",
        "T...........===...;;..;;;ww;;;;.TT",
        "T....TT.....====........;;;;;;..TT",
        "T..RRR..RRRR.====..\"\"\"\".........TT",
        "T..R.......R..====\"\"\"\"\"\"........TT",
        "TT.R.......R...====\"\"\"\"........TTT",
        "TT.R..........T.====...........TTT",
        "T................===...........TTT",
        "TT...........R....==.............T",
        "TT.R.......R..T...==.............T",
        "TT.RRR...RRR..T..===.............T",
        "TT...........T..====.\"\"\".......TTT",
        "TT...........TR.===TT\"\"\"\"......TTT",
        "TTTTTT..........==.\"\"\"\"\"T\"....TTTT",
        "TTTTTTTTT.......==..\"TTTTT.TTTTTTT",
        "TTTTTTTTT.......==...TTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTT==TTTTTTTTTTTTTTTT",
    },
    edges = { north = { map = "rebelcamp", dx = 0 }, south = { map = "zulmamwe", dx = -1 } },
    stamps = {
        { kind = "tent", x = 2, y = 1 }, { kind = "tent", x = 5, y = 1 }, -- Nesingwary's camp
        { kind = "tent", x = 8, y = 1 },
        { kind = "jbigtree", x = 27, y = 21 }, { kind = "jbigtree", x = 1, y = 11 },
        { kind = "hut", x = 5, y = 21 },                        -- Bal'lal
        { kind = "totem", x = 9, y = 22 },
    },
    signs = {
        { x = 11, y = 18, text = "NESINGWARY'S EXPEDITION: north-west, by the road.\nLAKE NAZFERITI: east.\nSouth: the Bal'lal Ruins and Zul'Mamwe." },
        { x = 13, y = 23, text = "BAL'LAL RUINS\nBloodscalp country. The trolls do not like visitors." },
    },
    encounters = {
        { sp = "tigercub", min = 32, max = 35, weight = 25 },
        { sp = "pantherkit", min = 32, max = 35, day = 10, night = 25 },
        { sp = "raptorling", min = 33, max = 36, weight = 20 },
        { sp = "trollscout", min = 33, max = 36, day = 8, night = 15 },
        { sp = "crystalspine", min = 34, max = 36, weight = 12 },
        { sp = "tiger", min = 36, max = 36, weight = 5 },
        { sp = "bhagthera", min = 40, max = 40, day = 0, night = 2, rare = true },
    },
    coastEncounters = {
        { sp = "rivercroc", min = 33, max = 35, weight = 50 },
        { sp = "tidehunter", min = 33, max = 35, weight = 20 },
        { sp = "coastrunner", min = 32, max = 34, weight = 15 },
        { sp = "crawler", min = 32, max = 34, weight = 15 },
    },
    chests = {
        { id = "snnets", x = 2, y = 29, item = "greatnet", n = 2 },
        { id = "snpotion", x = 30, y = 6, item = "superpotion", n = 2 },
    },
    npcs = {
        { id = "hemet", x = 6, y = 4, sprite = "bald", tint = { 0.9, 0.8, 0.65 }, face = "down",
          trainer = "hemet", sight = 0 },
        { id = "ajeck", x = 9, y = 7, sprite = "girl", tint = { 0.9, 0.75, 0.6 }, face = "right", trainer = "ajeck", sight = 3 },
        { id = "erlgadin", x = 14, y = 3, sprite = "hero", tint = { 0.85, 0.8, 0.7 }, face = "left", trainer = "erlgadin", sight = 2 },
        { id = "barnil", x = 16, y = 17, sprite = "bald", tint = { 0.85, 0.75, 0.6 }, face = "right", trainer = "barnil", sight = 2 },
        { id = "bloodscalp1", x = 12, y = 24, sprite = "bald", tint = { 0.45, 0.65, 0.75 }, face = "right", trainer = "bloodscalp1", sight = 3 },
        { id = "bloodscalp2", x = 8, y = 28, sprite = "hero", tint = { 0.4, 0.6, 0.7 }, face = "up", trainer = "bloodscalp2", sight = 2 },
        { id = "bangalash", x = 28, y = 25, sprite = "bald", tint = { 1, 1, 1 }, face = "left",
          trainer = "bangalash", sight = 0,
          hidden = function(G) return not HuntersDone(G) or G:Flag("beat_bangalash") end },
        { id = "fisher", name = "Fisherman Moka", x = 15, y = 11, sprite = "bald", tint = { 0.8, 0.85, 0.7 }, face = "right",
          script = function(G)
              G:Say("Fisherman Moka: Lake Nazferiti. Best fishing in the vale, if the crocolisks leave you your arms.")
          end },
    },
}

---------------------------------------------------------------------------
-- The Ruins of Zul'Mamwe: Skullsplitter trolls, the Venture Co. dig at Mizjah, and the Mosh'Ogg ogre mound
---------------------------------------------------------------------------

Maps.zulmamwe = {
    name = "Ruins of Zul'Mamwe",
    rev = 2,                -- 2: redrawn organic (0.48)
    music = "arena",
    outdoor = true,
    theme = "jungle",
    herbs = { "briarthorn", "mageroyal" }, ores = { "tin" },
    nodes = { herb = { { 3, 11 }, { 28, 11 } }, ore = { { 2, 21 }, { 30, 26 } } },
    rows = {
        "TTTTTTTTTTTTTTT==TTTTTTTTTTTTTTT",
        "TTTTT...TTTT.T.==..TTTTTTTTTTTTT",
        "T..............==.T...........TT",
        "T..........\"\"\".==.T...........TT",
        "T..........\"\"\"\"==.T...........TT",
        "T..........\"\"\".==.T...........TT",
        "T..............==..............T",
        "T...........TT.===.............T",
        "T...........TT.=====.....\".....T",
        "T...............====.\"\"\"\"\"\"....T",
        "T.T...............==.\"\"\"\"\"\"\".TTT",
        "TTT...............==.\"\"\"\"\"\"T.TTT",
        "TT................==.T.\"...T...T",
        "TTT...............==TTT........T",
        "TTTT.............T=RRR.......RRT",
        "TTT..............T=R..........RT",
        "TT..kkg..........==R..........RT",
        "T............T..====...........T",
        "T............T.====...RR...RR..T",
        "TT........g...====.............T",
        "TT........kk.====..............T",
        "TT...........===...R..........RT",
        "TTT\"\"\"\"\".....==....RRR......RRRT",
        "TTTTT\"\"\"TT...==................T",
        "TTTTTT\"\"TTT..==................T",
        "TTTTTTTTTT.TT==................T",
        "TTTTTTTT.....==................T",
        "TTTTTTTT.....==...TTTT\"\"\".TTTTTT",
        "TTTTTTTT.....==..TTTT\"\"\"..TTTTTT",
        "TTTTTTTTTTTTT==TTTTTTTTTTTTTTTTT",
    },
    edges = { north = { map = "stvnorth", dx = 1 }, south = { map = "arena", dx = -6 } },
    stamps = {
        { kind = "hut", x = 3, y = 3 },                         -- the Skullsplitter outpost
        { kind = "totem", x = 7, y = 3 },
        { kind = "mineentrance", x = 25, y = 3 },               -- the Mosh'Ogg mound, door (26, 4)
        { kind = "hut", x = 24, y = 15 },                       -- the ruins' courts round Gan'zulah's altar
        { kind = "totem", x = 22, y = 15 }, { kind = "totem", x = 28, y = 15 },
        { kind = "totem", x = 23, y = 19 }, { kind = "totem", x = 27, y = 19 },
        { kind = "tent", x = 7, y = 16 },                       -- the Venture Co. dig
    },
    warps = { { x = 26, y = 4, map = "moshogg", tx = 3, ty = 9, face = "right" } },
    signs = {
        { x = 17, y = 2, text = "RUINS OF ZUL'MAMWE\nSkullsplitter trolls hold the ruins. The Venture Company digs at Mizjah, east." },
        { x = 22, y = 8, text = "MOSH'OGG OGRE MOUND: east.\nThe ogres eat what walks in." },
        { x = 16, y = 25, text = "SOUTH: the Gurubashi Arena.\nBeast fights daily." },
    },
    encounters = {
        { sp = "trollscout", min = 36, max = 39, weight = 25 },
        { sp = "tiger", min = 37, max = 39, weight = 20 },
        { sp = "panther", min = 37, max = 39, day = 10, night = 25 },
        { sp = "lashtail", min = 38, max = 40, weight = 15 },
        { sp = "raptorling", min = 36, max = 38, weight = 10 },
        { sp = "crystalspine", min = 37, max = 39, weight = 10 },
        { sp = "tethis", min = 43, max = 43, day = 1, night = 2, rare = true },
    },
    chests = { { id = "zmpotion", x = 29, y = 25, item = "superpotion", n = 2 } },
    npcs = {
        { id = "skull1", x = 9, y = 6, sprite = "bald", tint = { 0.4, 0.6, 0.75 }, face = "right", trainer = "skull1", sight = 3 },
        { id = "venture1", x = 5, y = 19, sprite = "bald", tint = { 0.55, 0.85, 0.45 }, face = "right", trainer = "venture1", sight = 4 },
        { id = "venture2", x = 11, y = 17, sprite = "bald", tint = { 0.6, 0.85, 0.5 }, face = "left", trainer = "venture2", sight = 5 },
        { id = "skull2", x = 20, y = 19, sprite = "hero", tint = { 0.4, 0.6, 0.75 }, face = "right", trainer = "skull2", sight = 0 },
        { id = "ganzulah", x = 25, y = 20, sprite = "hero", tint = { 0.35, 0.55, 0.7 }, face = "down",
          trainer = "ganzulah", sight = 0, hidden = Vanished("ganzulah") },
    },
}

Maps.moshogg = {
    name = "Mosh'Ogg Ogre Mound",
    rev = 2,                -- 2: redrawn organic (0.48)
    music = "mine",
    theme = "mine",
    cave = { rate = 6 },
    ores = { "tin" },
    nodes = { ore = { { 25, 11 } } },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTSTTTTSTTTTTTTT",
        "TTTTTTTTTTTTT........TTTTTTT",
        "TTTTTTTTTTi..........STTTTTT",
        "TTTTTTTTTT............TTTTTT",
        "TTTTSTTT.....TTTT......TiTTT",
        "TTT..TST.....iTT.........TTT",
        "TT............S..........TTT",
        "T.L......................kiT",
        "T..........................T",
        "TT....TT...TT......i.......T",
        "TTTTTTT...TT...............T",
        "TTTTg....TTTTTi............T",
        "TTT......TTTTT............TT",
        "TTTTk.....TTTTT.TT.......TTT",
        "TTTT.g..kTTTTTTTT....TTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    },
    warps = { { x = 2, y = 9, map = "zulmamwe", tx = 26, ty = 5, face = "down" } },
    chests = { { id = "mopotion", x = 4, y = 14, item = "superpotion", n = 3 } },
    encounters = {
        { sp = "splinterfist", min = 38, max = 41, weight = 40 },
        { sp = "crystalspine", min = 38, max = 40, weight = 25 },
        { sp = "tarantula", min = 38, max = 40, weight = 25 },
        { sp = "mauler", min = 44, max = 44, weight = 5 },
    },
    npcs = {
        { id = "ogrewd", x = 16, y = 4, sprite = "bald", tint = { 0.75, 0.6, 0.45 }, face = "down", trainer = "ogrewd", sight = 3 },
        { id = "ogreshaman", x = 15, y = 10, sprite = "bald", tint = { 0.7, 0.55, 0.4 }, face = "right", trainer = "ogreshaman", sight = 3 },
        { id = "maizoth", x = 23, y = 11, sprite = "bald", tint = { 0.65, 0.5, 0.4 }, face = "left",
          trainer = "maizoth", sight = 0, hidden = Vanished("maizoth") },
    },
}

---------------------------------------------------------------------------
-- Southern Stranglethorn: Mistvale Valley, Crystalvein Mine, the road down to the Wild Shore
---------------------------------------------------------------------------

Maps.stvsouth = {
    name = "Southern Stranglethorn",
    rev = 2,                -- 2: redrawn organic (0.48)
    music = "arena",
    outdoor = true,
    theme = "jungle",
    herbs = { "briarthorn", "mageroyal" }, ores = { "tin", "copper" },
    nodes = { herb = { { 2, 15 }, { 27, 13 }, { 10, 25 } }, ore = { { 27, 3 }, { 5, 3 } } },
    rows = {
        "TTTTTTTTTTTTT==TTTTTTTTTTTTTTT",
        "TTTTTT.......==..TTTTTTTTTTTTT",
        "TTTTTT..TTT..==....TT.......TT",
        "TTTTT...TTT..==.....T.......TT",
        "T...T..\"TTT\".==.....T.......TT",
        "T...T..\"TTTT.==.............TT",
        "T...T....T.TT==.............TT",
        "TTTTT....T...==.............TT",
        "TTTT.;;......==.......k...k..T",
        "TT;;;w;;.....===.............T",
        "TT;wwwww;....====............T",
        "TTwwwwww;.....====....\"......T",
        "TT;wwwww;..TT..===.\"\"\"\"\"\"\"...T",
        "T.;;ww;;........==.\"\"\"\"\"\"\"...T",
        "T...;;..........==..\"\"\"\"\"\".TTT",
        "T...............==.TTT..TTTTTT",
        "T..............===..TT...T.TTT",
        "T..............===......TTTT.T",
        "T....\"\"\"\"\"\"\"...==.....RR..R..T",
        "T.T..\"\"\"\"\"\"\"\"..==.........R.TT",
        "TTT.\"\"\"\"\"\"\"\"\"..==...........TT",
        "TTTT\"\"\"\"\"\"\"\"...==...........TT",
        "TTTT..\"\"\"\"\"....====...R..RR.TT",
        "TTTT\"\"\".TTT.T..====..........T",
        "TT...\"\"....TT....==..........T",
        "TT...\".....TTT...==..TT......T",
        "TT.........TT....==...\"T...TTT",
        "TTT........TTT.====..\"\"TTTTTTT",
        "TTTTT......TTT.====...\"TTTTTTT",
        "TTTTTTTTTTTTTTT==TTTTTTTTTTTTT",
    },
    edges = { north = { map = "arena", dx = -6 }, south = { map = "wildshore", dx = 0 } },
    stamps = {
        { kind = "mineentrance", x = 23, y = 4 },               -- Crystalvein Mine, door (24, 5)
        { kind = "jbigtree", x = 1, y = 4 }, { kind = "jbigtree", x = 24, y = 24 },
        { kind = "jbigtree", x = 2, y = 24 },
    },
    warps = { { x = 24, y = 5, map = "crystalvein", tx = 3, ty = 8, face = "right" } },
    signs = {
        { x = 15, y = 2, text = "SOUTHERN STRANGLETHORN\nNorth: the Gurubashi Arena. East: Crystalvein Mine.\nWest: Mistvale Valley. Mind the gorillas." },
        { x = 14, y = 26, text = "SOUTH: the Wild Shore and Booty Bay.\nBloodsail pirates hold the beach." },
    },
    encounters = {
        { sp = "gorilla", min = 40, max = 43, weight = 30 },
        { sp = "panther", min = 40, max = 42, day = 10, night = 25 },
        { sp = "tiger", min = 40, max = 42, weight = 15 },
        { sp = "lashtail", min = 41, max = 43, weight = 15 },
        { sp = "coldeye", min = 42, max = 43, weight = 8 },
        { sp = "crystalspine", min = 40, max = 42, weight = 7 },
        { sp = "bhagthera", min = 44, max = 44, day = 0, night = 1, rare = true },
    },
    coastEncounters = {
        { sp = "saltwatercroc", min = 41, max = 43, weight = 50 },
        { sp = "snapjaw", min = 42, max = 44, weight = 20 },
        { sp = "tidehunter", min = 41, max = 43, weight = 30 },
    },
    chests = {
        { id = "ssnets", x = 3, y = 27, item = "greatnet", n = 2 },
        { id = "sspotion", x = 27, y = 25, item = "superpotion", n = 2 },
    },
    npcs = {
        { id = "bighunter", x = 10, y = 6, sprite = "hero", tint = { 0.85, 0.75, 0.55 }, face = "right", trainer = "bighunter", sight = 2 },
        { id = "venture3", x = 20, y = 8, sprite = "bald", tint = { 0.55, 0.85, 0.45 }, face = "left", trainer = "venture3", sight = 2 },
        { id = "trollhunter", x = 21, y = 20, sprite = "bald", tint = { 0.4, 0.6, 0.75 }, face = "left", trainer = "trollhunter", sight = 3 },
        { id = "wrangler", name = "Mistvale Wrangler", x = 7, y = 16, sprite = "girl", tint = { 0.85, 0.8, 0.65 }, face = "right",
          script = function(G)
              G:Say("Mistvale Wrangler: The gorillas throw fruit first. If they're out of fruit, run.")
          end },
    },
}

Maps.crystalvein = {
    name = "Crystalvein Mine",
    rev = 2,                -- 2: redrawn organic (0.48)
    music = "mine",
    theme = "mine",
    cave = { rate = 6 },
    ores = { "tin", "copper" },
    nodes = { ore = { { 17, 6 }, { 21, 14 }, { 26, 12 } } },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTSTT",
        "TTTTTTTTTTTTTTTTiTTTTTTTSTk..T",
        "TTTTTTTTTTTTTTkg.STTTST=====.T",
        "TTTTTTTTTTTT..=========......T",
        "TTTSiTTSiTT...=..............T",
        "TT............=..T.......TTTTT",
        "TSL============.TTTTTT...i.TTT",
        "T...........TTTTTTTTTT......TT",
        "TT...kTT.....TTTTSTTTTT......T",
        "TTT.TTTT.....iSTT...TSTk....TT",
        "TTTTTTTTT...................TT",
        "TTTTTTTTT........www.......TTT",
        "TTTTTTTTTT.......www.....TTTTT",
        "TTTTTTTTTTTTT.......gTTTTTTTTT",
        "TTTTTTTTTTTTTTTT...TTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    },
    warps = { { x = 2, y = 8, map = "stvsouth", tx = 24, ty = 6, face = "down" } },
    chests = { { id = "cvpotion", x = 28, y = 4, item = "superpotion", n = 2 } },
    encounters = {
        { sp = "coldeye", min = 42, max = 45, weight = 35 },
        { sp = "crystalspine", min = 42, max = 44, weight = 25 },
        { sp = "tarantula", min = 42, max = 44, weight = 20 },
        { sp = "shredder", min = 43, max = 45, weight = 20 },
    },
    npcs = {
        { id = "venture4", x = 12, y = 6, sprite = "bald", tint = { 0.55, 0.85, 0.45 }, face = "down", trainer = "venture4", sight = 3 },
        { id = "venture5", x = 23, y = 7, sprite = "bald", tint = { 0.6, 0.85, 0.5 }, face = "left", trainer = "venture5", sight = 4 },
        { id = "venture6", x = 12, y = 12, sprite = "bald", tint = { 0.5, 0.8, 0.45 }, face = "right", trainer = "venture6", sight = 3 },
    },
}

---------------------------------------------------------------------------
-- The Wild Shore: the Ruins of Aboraz (Zanzil's dead), the Bloodsail camp and Fleet Master Firallon's ship
---------------------------------------------------------------------------

Maps.wildshore = {
    name = "The Wild Shore",
    rev = 2,                -- 2: redrawn organic (0.48)
    music = "cove",
    outdoor = true,
    theme = "jungle",
    herbs = { "briarthorn", "mageroyal" }, ores = { "tin" },
    nodes = { herb = { { 3, 14 }, { 11, 22 } }, ore = { { 17, 2 }, { 1, 4 } } },
    rows = {
        "TTTTTTTTTTTTTTT==TTTTTTTTTTwwwww",
        "TTTTTTTTTTTTTT.==.TTTT;;;sswwwww",
        "TTTTTT......T..==.TTTT;;;sswwwww",
        "TTTTT..........==.TTTTT;;ssswwww",
        "T...........TT.==...TT;;;sswwwww",
        "T.RRR....RR.T..==.\"\"TTssswwwwwww",
        "T.R.......R....==\"\"\";;ssswwwwwww",
        "T.R.......R..TT==.\"\";;ssswwwwwww",
        "T..............==...;;;sswwwwwww",
        "T..............==...;;ssswwwDwww",
        "T.............===...;;ssswwDDDww",
        "T.R.......R..====..;;ssswwDDDDDw",
        "T.RR.....RR.====...;;ssswwDDDDDw",
        "T...........===..........DDDDDDw",
        "TT..........==...........wDDDDDw",
        "TTTTT...TTT.==...........wDDDDDw",
        "TTTTT...TTT.==...........wwDDDww",
        "TTTT\"\"\".....===..........wwwwwww",
        "TTT\"\"\"\"\"....===..........wwwwwww",
        "TTT\"\"\"\"......==..........wwwwwww",
        "TTT..\".......==..........wwwwwww",
        "TT...TT......==......ssswwwwwwww",
        "TTT...TTT....==.......sswwwwwwww",
        "TTTTT.\"\"\"\"\"..==.......sswwwwwwww",
        "TTTTTT\"\"\"\"\"..===....;;ssswwwwwww",
        "TT...T\"\"\"\"..T===....;;.sswwwwwww",
        "TT...TTTTTT.TT==....;;;sswwwwwww",
        "TT...TTTTTT...==....T;ssswwwwwww",
        "TTT..TTTTTT..===...;Tssswwwwwwww",
        "TTTTTTTTTTTTTT==TTTTTTTwwwwwwwww",
    },
    edges = { north = { map = "stvsouth", dx = 0 }, south = { map = "bootybay", dx = 4 } },
    stamps = {
        { kind = "totem", x = 3, y = 6 }, { kind = "totem", x = 8, y = 6 }, -- the Ruins of Aboraz
        { kind = "mast", x = 28, y = 11 },                      -- the Bloodsail ship at anchor
        { kind = "tent", x = 19, y = 15 }, { kind = "tent", x = 22, y = 17 }, -- the Bloodsail camp on the beach
        { kind = "jbigtree", x = 2, y = 25 }, { kind = "jbigtree", x = 17, y = 25 },
    },
    signs = {
        { x = 16, y = 2, text = "THE WILD SHORE\nWest: the Ruins of Aboraz. East: the beach, and the Bloodsail Buccaneers." },
        { x = 18, y = 12, text = "BLOODSAIL LANDING\nThe pirates' ship lies off the beach. Their captains are aboard." },
        { x = 15, y = 27, text = "BOOTY BAY: south.\nBaron Revilgaz welcomes paying customers." },
    },
    encounters = {
        { sp = "zombie", min = 44, max = 46, day = 15, night = 35 },
        { sp = "panther", min = 43, max = 45, weight = 15 },
        { sp = "tiger", min = 43, max = 45, weight = 15 },
        { sp = "lashtail", min = 44, max = 46, weight = 15 },
        { sp = "coldeye", min = 44, max = 46, weight = 10 },
        { sp = "gorilla", min = 43, max = 45, weight = 10 },
        { sp = "berserker", min = 46, max = 46, weight = 5 },
    },
    coastEncounters = {
        { sp = "snapjaw", min = 45, max = 47, weight = 35 },
        { sp = "saltwatercroc", min = 44, max = 46, weight = 35 },
        { sp = "sandcrawler", min = 44, max = 46, weight = 20 },
        { sp = "tidecaller", min = 45, max = 46, weight = 10 },
    },
    chests = {
        { id = "wsnets", x = 18, y = 4, item = "greatnet", n = 3 },
        { id = "wsanti", x = 3, y = 22, item = "antidote", n = 3 },
    },
    npcs = {
        { id = "zanzilwd", x = 9, y = 9, sprite = "bald", tint = { 0.45, 0.6, 0.7 }, face = "right", trainer = "zanzilwd", sight = 2 },
        { id = "zanzil", x = 5, y = 8, sprite = "bald", tint = { 0.4, 0.55, 0.65 }, face = "down",
          trainer = "zanzil", sight = 0, hidden = Vanished("zanzil") },
        { id = "seadog", x = 21, y = 20, sprite = "hero", tint = { 0.85, 0.3, 0.3 }, face = "left", trainer = "seadog", sight = 5 },
        { id = "swashbuckler", x = 17, y = 9, sprite = "hero", tint = { 0.8, 0.25, 0.35 }, face = "left", trainer = "swashbuckler", sight = 2 },
        { id = "stillwater", x = 27, y = 12, sprite = "hero", tint = { 0.75, 0.2, 0.3 }, face = "down", trainer = "stillwater", sight = 0 },
        { id = "keelhaul", x = 29, y = 15, sprite = "bald", tint = { 0.7, 0.2, 0.3 }, face = "up", trainer = "keelhaul", sight = 0 },
        { id = "firallon", x = 27, y = 14, sprite = "hero", tint = { 0.65, 0.15, 0.25 }, face = "left",
          trainer = "firallon", sight = 0, hidden = Vanished("firallon") },
    },
}

---------------------------------------------------------------------------
-- Booty Bay: the Blackwater Raiders' port. The Salty Sailor Tavern, the Baron's hall, gryphons and the boat to
-- Jaguero Isle.
---------------------------------------------------------------------------

Maps.bootybay = {
    name = "Booty Bay",
    rev = 2,                -- 2: redrawn organic (0.48)
    music = "cove",
    outdoor = true,
    theme = "jungle",
    rows = {
        "TTTTTTTTTTTTTTTTTT==TTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTT==TTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTT.==.TTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTT.....==......TTTTTTTTTTTT",
        "TTTTTTTTTTTTT.....==......TTTTTTTTTTTT",
        "TTTTTTTTTTTTT.....==...........TTTTTTT",
        "TTTTTT.....TT.....==...........TTTTTTT",
        "TTTTTT.....TT.....==...........TTTTTTT",
        "TTTTTT.....TT.....DDDDDD.......TTTTTTT",
        "TTTTTT.....TDDDDDDDDDDDDDD.....TTTTTTT",
        "TTTTTT.....DDDDDDDDDDDDDDD.....TTTTTTT",
        "TTTTTT.....DDDDDDDDDDDDDDDDDDDTTTTTTTT",
        "TTTTTTTTTDDDDDDDDDDwwwwDDDDDDDTTTTTTTT",
        "TTT.....DDDDDDDDwwwwwwwDDDDDDDD.....TT",
        "TTT.....DDDDwwDDwwwwwwwDDwDDDDD.....TT",
        "TTT.....DDwwwDDDwwwwwwwDDwwDDDD.....TT",
        "TTT.....DwwwwDDDwwwwwwwDDDwwDDD.....TT",
        "TTT.....DwwwwDDDwwwwwwwDDDwwwDD.....TT",
        "TTT.....DwwwwwDDwwwwwwwDDDwwwDD.....TT",
        "TTTTTTDDDwwwwwDDwwwwwwwDDwwwwDDDDDDTTT",
        "TTTTTTDDDDwwwwwwwwwwwwwDDwwwwDDDDDTTTT",
        "TTTTTTDDDDDwwwwwwwwwwwwwwwwwwDDDDDTTTT",
        "TTTTTTTTTDDDDwwwwwwwwwwwwwwwwwwTTTTTTT",
        "TTTTTTTTTTDDDDDwwwwwwwwwwwwwwwwTTTTTTT",
        "TTTTTTTTTTTDDDDwwwwwwwwwwwwwwwwwwwTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTwwwwwwwwwwwwww",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTwwwwwwwwwwww",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTwwwwwwwwww",
    },
    edges = { north = { map = "wildshore", dx = -4 } },
    stamps = {
        { kind = "bbhouse", x = 6, y = 6, inn = "bootybayinn" }, -- the Salty Sailor Tavern, door (9, 11)
        { kind = "bbhouse", x = 26, y = 5 },                    -- the Baron's hall, door (29, 10)
        { kind = "bbhouse", x = 3, y = 13 },                    -- a warehouse, door (6, 18)
        { kind = "bbhouse", x = 31, y = 13 },                   -- a warehouse, door (34, 18)
        { kind = "mast", x = 13, y = 15 }, { kind = "mast", x = 25, y = 16 },
    },
    warps = {
        { x = 9, y = 11, map = "bootybayinn", tx = 4, ty = 6, face = "up" },
        { x = 29, y = 10, map = "bbhall", tx = 4, ty = 6, face = "up" },
    },
    objects = {
        { x = 16, y = 7, tile = "wantedboard", hint = "Read the bounty board", script = function(G) G:BountyBoard() end },
        { x = 12, y = 11, tile = "alchemy", hint = "Brew at the alchemy table", script = function(G) G:CraftAt("alchemy") end },
        { x = 31, y = 21, tile = "forge", station = "forge", hint = "Smelt at the forge", script = function(G) G:CraftAt("mining") end },
        { x = 32, y = 21, tile = "anvil", station = "anvil", hint = "Smith at the anvil", script = function(G) G:CraftAt("blacksmithing") end },
    },
    signs = {
        { x = 20, y = 4, text = "BOOTY BAY\nA Blackwater Raiders port under Baron Revilgaz.\nWest: the Salty Sailor Tavern. East: the Baron's hall. South: the docks." },
        { x = 17, y = 11, text = "THE DOCKS\nThe boat to Jaguero Isle leaves from the east pier's end.\nGryphons to Darkshire: up on the landing." },
    },
    npcs = {
        { id = "gringer", name = "Gringer", role = "gryphon", x = 23, y = 5, sprite = "bald", tint = { 0.6, 0.85, 0.5 }, face = "left",
          script = function(G)
              if not G:Flag("fp_bootybay") then
                  G:SetFlag("fp_bootybay")
                  G:Say("Gringer: First time in Booty Bay? I'll wire Felicia in Darkshire. Her gryphons know the way here now.")
              end
              if G:Choose("Gringer: Where to?", { "Darkshire (" .. D.Money(40) .. ")", "Stay" }) ~= 1 then
                  G:Say("Gringer: Suit yourself. Mind the goblins.")
                  return
              end
              if G.save.money < 40 then
                  G:Say("Gringer: That's " .. D.Money(40) .. ", friend. No credit.")
                  return
              end
              G.save.money = G.save.money - 40
              G:EnterMap("darkshire", 17, 14, "left")
              G:Say("You fly north over the whole vale, all the way to Darkshire's lamps.")
          end },
        { id = "marine", x = 11, y = 14, sprite = "hero", tint = { 0.75, 0.8, 0.95 }, face = "right", trainer = "marine", sight = 2 },
        { id = "bruiser", x = 27, y = 12, sprite = "bald", tint = { 0.55, 0.85, 0.45 }, face = "left", trainer = "bruiser", sight = 2 },
        { id = "boatman", name = "Skipper Zinkle", x = 24, y = 20, sprite = "bald", tint = { 0.6, 0.85, 0.5 }, face = "down",
          script = function(G)
              if G:YesNo("Skipper Zinkle: Boat to Jaguero Isle? Gorillas, panthers and the big fella himself. Two silver.") then
                  if G.save.money < 200 then
                      G:Say("Skipper Zinkle: Two silver, I said. Come back with it.")
                      return
                  end
                  G.save.money = G.save.money - 200
                  G:EnterMap("jaguero", 4, 16, "up")
                  G:Say("The boat rounds the cape and ties up at Jaguero Isle's jetty. Zinkle waits on the beach.")
              else
                  G:Say("Skipper Zinkle: The isle isn't going anywhere.")
              end
          end },
        { id = "heming", name = "Old Man Heming", role = "profession", x = 14, y = 19, sprite = "bald",
          -- fishes off the west pier's end all day, tells fish stories at the Salty Sailor at night
          day = {
              { "00:00", inside = "bootybayinn", label = "Telling fish stories at the tavern" },
              { "05:30", path = { { 9, 11 }, { 9, 12 }, { 14, 12 }, { 14, 19 } }, face = "down",
                act = "fish", label = "Fishing off the docks", walk = "Off to the docks" },
              { "20:30", path = { { 14, 19 }, { 14, 12 }, { 9, 12 }, { 9, 11 } }, enter = "bootybayinn",
                label = "Telling fish stories at the tavern", walk = "Heading to the tavern" },
          },
          says = { { "06:00", "Early bite's the best bite." }, { "15:00", "That one was THIS big, I swear." } },
          tint = { 0.85, 0.82, 0.72 }, face = "down",       -- Expert Fishing
          script = function(G) G:FishingTrainer("heming") end },
        { id = "dockhand", name = "Dockhand", x = 23, y = 12, sprite = "hero", tint = { 0.7, 0.75, 0.6 }, face = "down",
          -- hauls crates up and down the east pier all day; the tavern at night
          day = {
              { "00:00", inside = "bootybayinn", label = "Asleep at the tavern" },
              { "07:00", path = { { 9, 11 }, { 9, 12 }, { 11, 12 }, { 11, 10 }, { 23, 10 }, { 23, 12 } }, face = "down",
                label = "On the docks", walk = "Off to the docks" },
              { "07:10", loop = { { 23, 12, wait = 3, face = "down" }, { 23, 19, wait = 3, face = "down" }, { 23, 12 } },
                label = "Hauling crates down the pier" },
              { "19:00", path = { { 23, 12 }, { 23, 10 }, { 11, 10 }, { 11, 12 }, { 9, 12 }, { 9, 11 } }, enter = "bootybayinn",
                label = "A drink at the tavern", walk = "Done for the day" },
          },
          says = { { "10:00", "Heave! ...ho." }, { "18:40", "Last crate. Grog time." } },
          script = function(G)
              if G:Flag("badge_blackwater") then
                  G:Say("Dockhand: The Bloodsail fleet turned tail! Drinks are on the Baron tonight. Well. One drink.")
              else
                  G:Say("Dockhand: Bloodsail sails off the Wild Shore, north of here. If they take the bay, we're all fish food.")
              end
          end },
    },
}

Maps.bootybayinn = {
    -- daily routines (Routine.lua): whoever's day has them in here sits at these
    seats = { { 1, 4, "up" }, { 3, 4, "up" }, { 6, 4, "up" }, { 8, 4, "up" } },
    name = "Salty Sailor Tavern",
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
    warps = { { x = 4, y = 7, map = "bootybay", tx = 9, ty = 12, face = "down" } },
    npcs = {
        { id = "nixxrax", name = "Nixxrax Fillamug", role = "inn", x = 2, y = 2, sprite = "bald", tint = { 0.6, 0.85, 0.5 }, face = "down",
          script = function(G)
              G:Say("Nixxrax Fillamug: Welcome to the Salty Sailor! Rooms upstairs, rum downstairs, and I don't ask questions.")
              if G:InnChoice("Nixxrax Fillamug", "bootybay", "Nixxrax Fillamug: Let your beasts rest here?") then
                  G:HealParty()
                  G:SetRespawn("bootybayinn", 4, 5, "up", "Booty Bay")
                  G:Say("Nixxrax Fillamug: All patched up. Try the rum.")
              end
          end },
        { id = "goodstitch", name = "Blixrez Goodstitch", role = "shop", x = 7, y = 2, sprite = "girl", tint = { 0.7, 0.9, 0.6 }, face = "down",
          script = function(G)
              G:Say("Blixrez Goodstitch: Nets, potions, whatever fell off a boat this week. Have a look!")
              G:Shop("Blixrez Goodstitch")
              G:Say("Blixrez Goodstitch: Pleasure doing business!")
          end },
        { id = "bbstable", name = "Stable Master Deeg", role = "stable", x = 8, y = 5, sprite = "bald", tint = { 0.8, 0.8, 0.9 }, face = "left",
          script = function(G)
              G:Say("Stable Master Deeg: Same ledger as every stable from here to Goldshire. Your beasts are safe with me.")
              G:Stable()
              G:Say("Stable Master Deeg: Come back anytime.")
          end },
    },
}

Maps.bbhall = {
    name = "The Baron's Hall",
    music = "tavern",
    rows = {
        "WWWWWWWWWW",
        "WWWWWWWWWW",
        "fdffffffdf",
        "ffffffffff",
        "ftffffffff",
        "ffffffffff",
        "pffffffffp",
        "WWWWrWWWWW",
    },
    warps = { { x = 4, y = 7, map = "bootybay", tx = 29, ty = 11, face = "down" } },
    chests = { { id = "bbgold", x = 8, y = 4, item = "illusiondust", n = 1 } },
    npcs = {
        { id = "revilgaz", name = "Baron Revilgaz", x = 4, y = 3, sprite = "bald", tint = { 0.55, 0.85, 0.45 }, face = "down",
          script = function(G)
              if G:Flag("badge_blackwater") then
                  G:Say("Baron Revilgaz: The Blackwater Seal! Firallon's fleet is limping home, and Booty Bay owes you a drink and a discount.")
                  G:Say("Baron Revilgaz: You've walked the vale end to end, tamer. From here the world only gets bigger.")
                  G:Say("(You have finished Stranglethorn Vale. Thank you for playing! More of Azeroth is coming.)")
                  return
              end
              if CaptainsDone(G) then
                  G:Say("Baron Revilgaz: Keelhaul and Stillwater beaten? Then Firallon has nobody left to hide behind. He's on his ship off the Wild Shore.")
                  return
              end
              G:Say("Baron Revilgaz: The Bloodsail Buccaneers want my port. Fleet Master Firallon sits off the Wild Shore with three ships.")
              G:Say("Baron Revilgaz: His captains, Keelhaul and Stillwater, are in the camp on the beach. Take them apart and he'll come out to fight.")
          end },
        { id = "fleetmaster", name = "Fleet Master Seahorn", x = 7, y = 3, sprite = "hero", tint = { 0.75, 0.8, 0.95 }, face = "down",
          script = function(G)
              G:Say("Fleet Master Seahorn: Every pirate the Baron catches, I hang. Every one you beat, I don't have to.")
          end },
    },
}

---------------------------------------------------------------------------
-- Jaguero Isle: King Mukla's kingdom, off the cape
---------------------------------------------------------------------------

Maps.jaguero = {
    name = "Jaguero Isle",
    rev = 2,                -- 2: redrawn organic (0.48)
    music = "arena",
    outdoor = true,
    theme = "jungle",
    herbs = { "briarthorn" },
    nodes = { herb = { { 6, 9 }, { 20, 7 } } },
    rows = {
        "wwwwwwwwwwwwwwwwwwwwwwwwww",
        "wwwwwwwwwwsswwwwwwwwwwwwww",
        "wwwwwwwwss..s...swwwwwwwww",
        "wwwwwwws.........swwwwwwww",
        "wwwwwwws.........sssswwwww",
        "wwwswwws..........T.sssssw",
        "wwwsswsTT........TTTsssssw",
        "wwwwssTTTTTTT....TTsssssww",
        "wwwwsT.T.........TTTTsssww",
        "wwssss.\"\"\"\"\"........Tsssww",
        "wss.ss.\"\"\"\"\".........sssww",
        "wsssss..\"\"\"\"....\"\"\"\"...sww",
        "wwwsssT....TTT..\"\"\"\"\"sswww",
        "wwwwws...TTTTTT..\"\"\"swwwww",
        "wwwwws....TTTTTTTTTTsswwww",
        "wwwws.s....sssTTT.ssssswww",
        "wwwDDswss.swwwsssssssswwww",
        "wwwDDwwssswwwssssssswwwwww",
        "wwwwwwsssswwwwssswwwwwwwww",
        "wwwwwwwwwwwwwwwwwwwwwwwwww",
    },
    stamps = { { kind = "jbigtree", x = 13, y = 2 } },
    signs = { { x = 8, y = 14, text = "JAGUERO ISLE\nBananas belong to King Mukla. So does everything else." } },
    encounters = {
        { sp = "gorilla", min = 46, max = 48, weight = 35 },
        { sp = "eldergorilla", min = 47, max = 49, weight = 15 },
        { sp = "panther", min = 46, max = 48, weight = 20 },
        { sp = "shadowmaw", min = 48, max = 49, weight = 5 },
        { sp = "lashtail", min = 46, max = 48, weight = 15 },
        { sp = "coldeye", min = 46, max = 48, weight = 10 },
    },
    chests = { { id = "jinets", x = 20, y = 14, item = "greatnet", n = 3 } },
    npcs = {
        { id = "zinkle", name = "Skipper Zinkle", x = 4, y = 15, sprite = "bald", tint = { 0.6, 0.85, 0.5 }, face = "up",
          script = function(G)
              if G:YesNo("Skipper Zinkle: Back to Booty Bay?") then
                  G:EnterMap("bootybay", 24, 19, "down")
                  G:Say("The boat carries you back round the cape to Booty Bay's docks.")
              end
          end },
        { id = "castaway", x = 17, y = 10, sprite = "hero", tint = { 0.8, 0.7, 0.55 }, face = "left", trainer = "castaway", sight = 2 },
        { id = "mukla", x = 11, y = 5, sprite = "bald", tint = { 0.5, 0.4, 0.3 }, face = "down",
          trainer = "mukla", sight = 3, hidden = Vanished("mukla") },
    },
}
