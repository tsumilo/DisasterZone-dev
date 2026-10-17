if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/MapsStranglethorn.lua", ...) then return end -- DisasterZone_Azeromon/MapsStranglethorn.lua
-- Stranglethorn Vale (the maps join ns.AzeroMaps; the format is described in Maps.lua). The road south from
-- Darkshire opens with the Night Watch Seal. North: the Rebel Camp and Kurzen's Compound, Nesingwary's
-- Expedition and Lake Nazferiti, the Bal'lal and Zul'Mamwe troll ruins, the Mosh'Ogg ogre mound, then the
-- Gurubashi Arena. South: Mistvale Valley and Crystalvein Mine, the Wild Shore with the Ruins of Aboraz and the
-- Bloodsail camp, Booty Bay, and Jaguero Isle by boat.
-- Badges: Nesingwary's Trophy (King Bangalash, then Hemet Nesingwary Jr.) and the Blackwater Seal (the Bloodsail
-- captains, then Fleet Master Firallon on his ship).
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
    music = "arena",
    outdoor = true,
    theme = "jungle",
    herbs = { "mageroyal", "briarthorn" }, ores = { "tin", "copper" },
    nodes = { herb = { { 3, 6 }, { 20, 19 } }, ore = { { 21, 1 }, { 2, 20 } } },
    rows = {
        "TTTTTTTTTTT==TTTTTTTTTTT",
        "T..........==..........T",
        "T..\"\"\"\"....==..........T",
        "T..\"\"\"\"....==..........T",
        "T..\"\"\"\"....==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==.=========T",
        "T..........==..........T",
        "T..........==..........T",
        "T.;;;;;....==..........T",
        "T.;www;....==..........T",
        "T.;www;....==..........T",
        "T.;;;;;....==....\"\"\"\"\".T",
        "T..........==....\"\"\"\"\".T",
        "T.\"\"\"\"\"....==....\"\"\"\"\".T",
        "T.\"\"\"\"\"....==..........T",
        "T.\"\"\"\"\"....==..........T",
        "T..........==..........T",
        "TTTTTTTTTTT==TTTTTTTTTTT",
    },
    edges = { north = { map = "darkshire", dx = 0 }, south = { map = "stvnorth", dx = 0 } },
    stamps = {
        { kind = "mineentrance", x = 18, y = 2 },       -- Kurzen's Compound, door (19, 3)
        { kind = "tent", x = 15, y = 6 }, { kind = "tent", x = 19, y = 6 }, { kind = "tent", x = 15, y = 11 },
        { kind = "jbigtree", x = 5, y = 6 },
    },
    warps = { { x = 19, y = 3, map = "kurzen", tx = 3, ty = 8, face = "right" } },
    objects = {
        { x = 18, y = 11, tile = "wantedboard", hint = "Read the bounty board", script = function(G) G:BountyBoard() end },
    },
    signs = {
        { x = 10, y = 10, text = "THE REBEL CAMP\nNorth: Duskwood. South: Nesingwary's Expedition and the vale.\nEast: Kurzen's Compound. Keep out." },
        { x = 16, y = 3, text = "KURZEN'S COMPOUND\nProperty of Colonel Kurzen. Deserters will be shot." },
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
    chests = { { id = "rcnets", x = 21, y = 20, item = "net", n = 4 } },
    npcs = {
        { id = "doren", name = "Lieutenant Doren", x = 17, y = 8, sprite = "hero", tint = { 0.7, 0.8, 1 }, face = "down",
          script = function(G)
              if G:Flag("beat_kurzen") then
                  G:Say("Lieutenant Doren: Kurzen is finished? Then his men can come home. Stormwind will hear it was you.")
                  G:Say("Lieutenant Doren: The vale runs south from here, all the way to Booty Bay. Nesingwary's camp is the first stop.")
                  return
              end
              G:Say("Lieutenant Doren: We were Colonel Kurzen's men, once. The jungle got into his head, and troll medicine got into the rest of him.")
              G:Say("Lieutenant Doren: His compound is in the cave east of here. If you can fight your way to him, do what we couldn't.")
          end },
        { id = "nimetz", name = "Brother Nimetz", role = "rest", x = 21, y = 8, sprite = "bald", tint = { 0.95, 0.9, 0.8 }, face = "left",
          script = function(G)
              G:Say("Brother Nimetz: The Light keeps this camp, and so do I. Your beasts look tired.")
              if G:YesNo("Brother Nimetz: Let them rest by the fire?") then
                  G:HealParty()
                  G:SetRespawn("rebelcamp", 20, 9, "up", "the Rebel Camp")
                  G:Say("Brother Nimetz: There. The jungle can wait a little longer.")
              end
          end },
        { id = "rcquarter", name = "Corporal Sethman", role = "shop", x = 14, y = 11, sprite = "bald", tint = { 0.8, 0.75, 0.6 }, face = "right",
          script = function(G)
              G:Say("Corporal Sethman: Supplies from Darkshire, when the wagons get through. Take a look.")
              G:Shop("Corporal Sethman")
              G:Say("Corporal Sethman: Mind the tigers.")
          end },
        { id = "kaleb", x = 9, y = 7, sprite = "hero", tint = { 0.7, 0.8, 1 }, face = "right", trainer = "kaleb", sight = 2 },
        { id = "bluth", x = 14, y = 16, sprite = "hero", tint = { 0.75, 0.8, 0.95 }, face = "left", trainer = "bluth", sight = 2 },
    },
}

Maps.kurzen = {
    name = "Kurzen's Compound",
    music = "mine",
    theme = "mine",
    cave = { rate = 6 },
    ores = { "tin", "copper" },
    nodes = { ore = { { 7, 1 }, { 20, 9 } } },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTT",
        "T....S.........S.......T",
        "T......................T",
        "T..TTTT......TTTT......T",
        "T..T..T......T..T......T",
        "T..T..TTTT...T..TTTT...T",
        "T......................T",
        "T..........TTT.........T",
        "T.L........TTT.....k...T",
        "T......................T",
        "TTTTT..TTTTTTTTT..TTTTTT",
        "T......................T",
        "T..gk..............kg..T",
        "TTTTTTTTTTTTTTTTTTTTTTTT",
    },
    warps = { { x = 2, y = 8, map = "rebelcamp", tx = 19, ty = 4, face = "down" } },
    chests = { { id = "kzpotion", x = 20, y = 1, item = "superpotion", n = 2 } },
    encounters = {
        { sp = "crystalspine", min = 33, max = 35, weight = 35 },
        { sp = "pantherkit", min = 33, max = 35, weight = 30 },
        { sp = "tigercub", min = 33, max = 35, weight = 25 },
        { sp = "trollscout", min = 34, max = 35, weight = 10 },
    },
    npcs = {
        { id = "kfighter", x = 8, y = 2, sprite = "hero", tint = { 0.6, 0.7, 0.5 }, face = "down", trainer = "kfighter", sight = 3 },
        { id = "kmedicine", x = 18, y = 6, sprite = "bald", tint = { 0.6, 0.75, 0.55 }, face = "left", trainer = "kmedicine", sight = 3 },
        { id = "kheadshrinker", x = 9, y = 11, sprite = "bald", tint = { 0.55, 0.65, 0.5 }, face = "right", trainer = "kheadshrinker", sight = 3 },
        { id = "kurzen", x = 12, y = 12, sprite = "hero", tint = { 0.5, 0.6, 0.45 }, face = "left",
          trainer = "kurzen", sight = 0, hidden = Vanished("kurzen") },
    },
}

---------------------------------------------------------------------------
-- Northern Stranglethorn: Nesingwary's Expedition, Lake Nazferiti, the Bal'lal Ruins
---------------------------------------------------------------------------

Maps.stvnorth = {
    name = "Northern Stranglethorn",
    music = "arena",
    outdoor = true,
    theme = "jungle",
    herbs = { "mageroyal", "briarthorn" }, ores = { "tin", "copper" },
    nodes = { herb = { { 26, 6 }, { 2, 20 }, { 25, 31 } }, ore = { { 26, 32 }, { 2, 1 } } },
    rows = {
        "TTTTTTTTTTT==TTTTTTTTTTTTTTT",
        "T..........==..............T",
        "T..........==..............T",
        "T..........==.....\"\"\"\"\"....T",
        "T..........==.....\"\"\"\"\"....T",
        "T..==========.....\"\"\"\"\"....T",
        "T..........==..............T",
        "T..........==..............T",
        "T..........==....;;;;;;;;;.T",
        "T..........==....;wwwwwww;.T",
        "T..........==....;wwwwwww;.T",
        "T.\"\"\"\"\"....==....;wwwwwww;.T",
        "T.\"\"\"\"\"....==....;wwwwwww;.T",
        "T.\"\"\"\"\"....==....;wwwwwww;.T",
        "T..........==....;;;;;;;;;.T",
        "T..........==..............T",
        "T..........==..............T",
        "T..........=====...........T",
        "T..............==..........T",
        "T..............==...\"\"\"\"\"..T",
        "T..............==...\"\"\"\"\"..T",
        "T..............==...\"\"\"\"\"..T",
        "T..RRRRRRR.....==..........T",
        "T..R.....R.....==..........T",
        "T..R.....R.....==..........T",
        "T..R.....R.....==..........T",
        "T..RRR.RRR.....==..........T",
        "T..............==....\"\"\"\"\".T",
        "T..............==....\"\"\"\"\".T",
        "T..............==....\"\"\"\"\".T",
        "T..\"\"\"\"\"\"......==..........T",
        "T..\"\"\"\"\"\"......==..........T",
        "T..............==..........T",
        "TTTTTTTTTTTTTTT==TTTTTTTTTTT",
    },
    edges = { north = { map = "rebelcamp", dx = 0 }, south = { map = "zulmamwe", dx = -4 } },
    stamps = {
        { kind = "tent", x = 3, y = 2 }, { kind = "tent", x = 6, y = 2 }, { kind = "tent", x = 3, y = 7 },   -- Nesingwary's camp
        { kind = "jbigtree", x = 22, y = 15 }, { kind = "jbigtree", x = 3, y = 15 },
        { kind = "hut", x = 4, y = 23 },                                                                    -- Bal'lal
        { kind = "totem", x = 8, y = 23 },
    },
    signs = {
        { x = 9, y = 17, text = "NESINGWARY'S EXPEDITION: north-west, by the road.\nLAKE NAZFERITI: east.\nSouth: the Bal'lal Ruins and Zul'Mamwe." },
        { x = 17, y = 22, text = "BAL'LAL RUINS\nBloodscalp country. The trolls do not like visitors." },
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
        { id = "snnets", x = 2, y = 32, item = "greatnet", n = 2 },
        { id = "snpotion", x = 25, y = 4, item = "superpotion", n = 2 },
    },
    npcs = {
        { id = "hemet", x = 5, y = 4, sprite = "bald", tint = { 0.9, 0.8, 0.65 }, face = "down",
          trainer = "hemet", sight = 0 },
        { id = "ajeck", x = 8, y = 9, sprite = "girl", tint = { 0.9, 0.75, 0.6 }, face = "right", trainer = "ajeck", sight = 3 },
        { id = "erlgadin", x = 13, y = 3, sprite = "hero", tint = { 0.85, 0.8, 0.7 }, face = "left", trainer = "erlgadin", sight = 2 },
        { id = "barnil", x = 13, y = 15, sprite = "bald", tint = { 0.85, 0.75, 0.6 }, face = "left", trainer = "barnil", sight = 2 },
        { id = "bloodscalp1", x = 12, y = 24, sprite = "bald", tint = { 0.45, 0.65, 0.75 }, face = "right", trainer = "bloodscalp1", sight = 3 },
        { id = "bloodscalp2", x = 18, y = 27, sprite = "hero", tint = { 0.4, 0.6, 0.7 }, face = "left", trainer = "bloodscalp2", sight = 2 },
        { id = "bangalash", x = 22, y = 22, sprite = "bald", tint = { 1, 1, 1 }, face = "left",
          trainer = "bangalash", sight = 0,
          hidden = function(G) return not HuntersDone(G) or G:Flag("beat_bangalash") end },
        { id = "fisher", name = "Fisherman Moka", x = 25, y = 9, sprite = "bald", tint = { 0.8, 0.85, 0.7 }, face = "left",
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
    music = "arena",
    outdoor = true,
    theme = "jungle",
    herbs = { "briarthorn", "mageroyal" }, ores = { "tin" },
    nodes = { herb = { { 2, 10 }, { 21, 17 } }, ore = { { 2, 27 }, { 21, 27 } } },
    rows = {
        "TTTTTTTTTTT==TTTTTTTTTTT",
        "T..........==..........T",
        "T.RRRRRR...==..........T",
        "T.R....R...==...\"\"\"\"\"..T",
        "T.R....R...==...\"\"\"\"\"..T",
        "T.R....R...==...\"\"\"\"\"..T",
        "T.RR.RRR...==..........T",
        "T..........==..........T",
        "T..\"\"\"\"....==..........T",
        "T..\"\"\"\"....==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T....k.....==.....gk...T",
        "T..........==..........T",
        "T.\"\"\"\"\"....==..\"\"\"\"\"...T",
        "T.\"\"\"\"\"....==..\"\"\"\"\"...T",
        "T.\"\"\"\"\"....==..\"\"\"\"\"...T",
        "T..........==..........T",
        "T..........==..........T",
        "T..RRRRR...==...RRRRR..T",
        "T..R...R...==...R...R..T",
        "T..R...R...==...R...R..T",
        "T..RR.RR...==...RR.RR..T",
        "T..........==..........T",
        "T..........==..........T",
        "T..\"\"\"\"\"...==...\"\"\"\"\"..T",
        "T..\"\"\"\"\"...==...\"\"\"\"\"..T",
        "T..........==..........T",
        "T..........==..........T",
        "TTTTTTTTTTT==TTTTTTTTTTT",
    },
    edges = { north = { map = "stvnorth", dx = 4 }, south = { map = "arena", dx = -4 } },
    stamps = {
        { kind = "hut", x = 3, y = 3 }, { kind = "totem", x = 6, y = 3 },
        { kind = "mineentrance", x = 15, y = 8 },       -- the Mosh'Ogg mound, door (16, 9)
        { kind = "totem", x = 4, y = 20 }, { kind = "totem", x = 17, y = 20 },
    },
    warps = { { x = 16, y = 9, map = "moshogg", tx = 2, ty = 6, face = "right" } },
    signs = {
        { x = 13, y = 1, text = "RUINS OF ZUL'MAMWE\nSkullsplitter trolls hold the ruins. The Venture Company digs at Mizjah, east." },
        { x = 13, y = 10, text = "MOSH'OGG OGRE MOUND: east.\nThe ogres eat what walks in." },
        { x = 13, y = 27, text = "SOUTH: the Gurubashi Arena.\nBeast fights daily." },
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
    chests = { { id = "zmpotion", x = 21, y = 12, item = "superpotion", n = 2 } },
    npcs = {
        { id = "skull1", x = 8, y = 4, sprite = "bald", tint = { 0.4, 0.6, 0.75 }, face = "right", trainer = "skull1", sight = 3 },
        { id = "venture1", x = 7, y = 12, sprite = "bald", tint = { 0.55, 0.85, 0.45 }, face = "right", trainer = "venture1", sight = 4 },
        { id = "venture2", x = 17, y = 13, sprite = "bald", tint = { 0.6, 0.85, 0.5 }, face = "left", trainer = "venture2", sight = 5 },
        { id = "skull2", x = 5, y = 21, sprite = "hero", tint = { 0.4, 0.6, 0.75 }, face = "up", trainer = "skull2", sight = 0 },
        { id = "ganzulah", x = 18, y = 21, sprite = "hero", tint = { 0.35, 0.55, 0.7 }, face = "left",
          trainer = "ganzulah", sight = 0, hidden = Vanished("ganzulah") },
    },
}

Maps.moshogg = {
    name = "Mosh'Ogg Ogre Mound",
    music = "mine",
    theme = "mine",
    cave = { rate = 6 },
    ores = { "tin" },
    nodes = { ore = { { 17, 2 } } },
    rows = {
        "TTTTTTTTTTTTTTTTTTTT",
        "T.S..............S.T",
        "T..................T",
        "T....TTTT..........T",
        "T....T..T....TTTT..T",
        "T..................T",
        "TL.................T",
        "T.......TTT........T",
        "T..................T",
        "T..k......g........T",
        "T..................T",
        "TTTTTTTTTTTTTTTTTTTT",
    },
    warps = { { x = 1, y = 6, map = "zulmamwe", tx = 16, ty = 10, face = "down" } },
    chests = { { id = "mopotion", x = 17, y = 9, item = "superpotion", n = 3 } },
    encounters = {
        { sp = "splinterfist", min = 38, max = 41, weight = 40 },
        { sp = "crystalspine", min = 38, max = 40, weight = 25 },
        { sp = "tarantula", min = 38, max = 40, weight = 25 },
        { sp = "mauler", min = 44, max = 44, weight = 5 },
    },
    npcs = {
        { id = "ogrewd", x = 10, y = 2, sprite = "bald", tint = { 0.75, 0.6, 0.45 }, face = "down", trainer = "ogrewd", sight = 3 },
        { id = "ogreshaman", x = 16, y = 8, sprite = "bald", tint = { 0.7, 0.55, 0.4 }, face = "left", trainer = "ogreshaman", sight = 3 },
        { id = "maizoth", x = 10, y = 10, sprite = "bald", tint = { 0.65, 0.5, 0.4 }, face = "up",
          trainer = "maizoth", sight = 0, hidden = Vanished("maizoth") },
    },
}

---------------------------------------------------------------------------
-- Southern Stranglethorn: Mistvale Valley, Crystalvein Mine, the road down to the Wild Shore
---------------------------------------------------------------------------

Maps.stvsouth = {
    name = "Southern Stranglethorn",
    music = "arena",
    outdoor = true,
    theme = "jungle",
    herbs = { "briarthorn", "mageroyal" }, ores = { "tin", "copper" },
    nodes = { herb = { { 2, 9 }, { 21, 15 }, { 2, 20 } }, ore = { { 21, 1 }, { 2, 1 } } },
    rows = {
        "TTTTTTTTTTT==TTTTTTTTTTT",
        "T..........==..........T",
        "T..\"\"\"\"\"...==...\"\"\"\"\"..T",
        "T..\"\"\"\"\"...==...\"\"\"\"\"..T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==....;;;;;.T",
        "T..\"\"\"\"....==....;www;.T",
        "T..\"\"\"\"....==....;www;.T",
        "T..\"\"\"\"....==....;;;;;.T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T.\"\"\"\"\"\"...==...\"\"\"\"\"\".T",
        "T.\"\"\"\"\"\"...==...\"\"\"\"\"\".T",
        "T.\"\"\"\"\"\"...==...\"\"\"\"\"\".T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..\"\"\"\"\"...==...\"\"\"\"\"..T",
        "T..\"\"\"\"\"...==...\"\"\"\"\"..T",
        "T..........==..........T",
        "T..........==..........T",
        "TTTTTTTTTTT==TTTTTTTTTTT",
    },
    edges = { north = { map = "arena", dx = -4 }, south = { map = "wildshore", dx = 0 } },
    stamps = {
        { kind = "mineentrance", x = 17, y = 4 },       -- Crystalvein Mine, door (18, 5)
        { kind = "jbigtree", x = 5, y = 7 }, { kind = "jbigtree", x = 3, y = 22 }, { kind = "jbigtree", x = 18, y = 22 },
    },
    warps = { { x = 18, y = 5, map = "crystalvein", tx = 2, ty = 6, face = "right" } },
    signs = {
        { x = 13, y = 1, text = "SOUTHERN STRANGLETHORN\nNorth: the Gurubashi Arena. East: Crystalvein Mine.\nWest: Mistvale Valley. Mind the gorillas." },
        { x = 9, y = 27, text = "SOUTH: the Wild Shore and Booty Bay.\nBloodsail pirates hold the beach." },
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
        { id = "ssnets", x = 2, y = 28, item = "greatnet", n = 2 },
        { id = "sspotion", x = 21, y = 28, item = "superpotion", n = 2 },
    },
    npcs = {
        { id = "bighunter", x = 9, y = 5, sprite = "hero", tint = { 0.85, 0.75, 0.55 }, face = "right", trainer = "bighunter", sight = 2 },
        { id = "venture3", x = 13, y = 9, sprite = "bald", tint = { 0.55, 0.85, 0.45 }, face = "left", trainer = "venture3", sight = 2 },
        { id = "trollhunter", x = 14, y = 20, sprite = "bald", tint = { 0.4, 0.6, 0.75 }, face = "left", trainer = "trollhunter", sight = 3 },
        { id = "wrangler", name = "Mistvale Wrangler", x = 4, y = 14, sprite = "girl", tint = { 0.85, 0.8, 0.65 }, face = "right",
          script = function(G)
              G:Say("Mistvale Wrangler: The gorillas throw fruit first. If they're out of fruit, run.")
          end },
    },
}

Maps.crystalvein = {
    name = "Crystalvein Mine",
    music = "mine",
    theme = "mine",
    cave = { rate = 6 },
    ores = { "tin", "copper" },
    nodes = { ore = { { 5, 1 }, { 12, 2 }, { 18, 10 } } },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTT",
        "T.S..........S.......T",
        "T....................T",
        "T...TTTTT............T",
        "T...T...T....TTTTT...T",
        "T............T...T...T",
        "TL...................T",
        "T.......TTT..........T",
        "T....................T",
        "T..k.g.........gk....T",
        "T....................T",
        "TTTTTTTTTTTTTTTTTTTTTT",
    },
    warps = { { x = 1, y = 6, map = "stvsouth", tx = 18, ty = 6, face = "down" } },
    chests = { { id = "cvpotion", x = 19, y = 2, item = "superpotion", n = 2 } },
    encounters = {
        { sp = "coldeye", min = 42, max = 45, weight = 35 },
        { sp = "crystalspine", min = 42, max = 44, weight = 25 },
        { sp = "tarantula", min = 42, max = 44, weight = 20 },
        { sp = "shredder", min = 43, max = 45, weight = 20 },
    },
    npcs = {
        { id = "venture4", x = 10, y = 2, sprite = "bald", tint = { 0.55, 0.85, 0.45 }, face = "down", trainer = "venture4", sight = 3 },
        { id = "venture5", x = 18, y = 8, sprite = "bald", tint = { 0.6, 0.85, 0.5 }, face = "left", trainer = "venture5", sight = 4 },
        { id = "venture6", x = 6, y = 10, sprite = "bald", tint = { 0.5, 0.8, 0.45 }, face = "right", trainer = "venture6", sight = 3 },
    },
}

---------------------------------------------------------------------------
-- The Wild Shore: the Ruins of Aboraz (Zanzil's dead), the Bloodsail camp and Fleet Master Firallon's ship
---------------------------------------------------------------------------

Maps.wildshore = {
    name = "The Wild Shore",
    music = "cove",
    outdoor = true,
    theme = "jungle",
    herbs = { "briarthorn", "mageroyal" }, ores = { "tin" },
    nodes = { herb = { { 2, 17 }, { 21, 22 } }, ore = { { 21, 1 }, { 2, 1 } } },
    rows = {
        "TTTTTTTTTTT==TTTTTTTTTTT",
        "T..........==..........T",
        "T..\"\"\"\"\"...==...\"\"\"\"\"..T",
        "T..\"\"\"\"\"...==...\"\"\"\"\"..T",
        "T..........==..........T",
        "T.RRRRRRR..==..........T",
        "T.R.....R..==....sssss.T",
        "T.R.....R..==....sssss.T",
        "T.R.....R..==....sssss.T",
        "T.RRR.RRR..==....sssss.T",
        "T..........==....sssss.T",
        "T..........==....sssss.T",
        "T..\"\"\"\"\"...==....;;;;;;T",
        "T..\"\"\"\"\"...==....;wwwwwT",
        "T..........==....;DDDDwT",
        "T..........==....;wDDDwT",
        "T..........==....;;;;;;T",
        "T..........==..........T",
        "T..........==....sssss.T",
        "T..\"\"\"\"\"...==....sssss.T",
        "T..\"\"\"\"\"...==....sssss.T",
        "T..........==....sssss.T",
        "T..........==..........T",
        "T..\"\"\"\"\"...==...\"\"\"\"\"..T",
        "T..\"\"\"\"\"...==...\"\"\"\"\"..T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "TTTTTTTTTTT==TTTTTTTTTTT",
    },
    edges = { north = { map = "stvsouth", dx = 0 }, south = { map = "bootybay", dx = 0 } },
    stamps = {
        { kind = "totem", x = 3, y = 6 }, { kind = "totem", x = 7, y = 6 },
        { kind = "mast", x = 21, y = 13 },
        { kind = "tent", x = 18, y = 18 }, { kind = "tent", x = 21, y = 18 },
        { kind = "jbigtree", x = 2, y = 26 }, { kind = "jbigtree", x = 19, y = 26 },
    },
    signs = {
        { x = 13, y = 1, text = "THE WILD SHORE\nWest: the Ruins of Aboraz. East: the beach, and the Bloodsail Buccaneers." },
        { x = 9, y = 17, text = "BLOODSAIL LANDING\nThe pirates' ship lies off the beach. Their captains are aboard." },
        { x = 13, y = 27, text = "BOOTY BAY: south.\nBaron Revilgaz welcomes paying customers." },
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
        { id = "wsnets", x = 20, y = 4, item = "greatnet", n = 3 },
        { id = "wsanti", x = 2, y = 28, item = "antidote", n = 3 },
    },
    npcs = {
        { id = "zanzilwd", x = 10, y = 6, sprite = "bald", tint = { 0.45, 0.6, 0.7 }, face = "right", trainer = "zanzilwd", sight = 2 },
        { id = "zanzil", x = 5, y = 7, sprite = "bald", tint = { 0.4, 0.55, 0.65 }, face = "down",
          trainer = "zanzil", sight = 0, hidden = Vanished("zanzil") },
        { id = "seadog", x = 17, y = 20, sprite = "hero", tint = { 0.85, 0.3, 0.3 }, face = "left", trainer = "seadog", sight = 5 },
        { id = "swashbuckler", x = 14, y = 8, sprite = "hero", tint = { 0.8, 0.25, 0.35 }, face = "left", trainer = "swashbuckler", sight = 2 },
        { id = "stillwater", x = 19, y = 10, sprite = "hero", tint = { 0.75, 0.2, 0.3 }, face = "down", trainer = "stillwater", sight = 0 },
        { id = "keelhaul", x = 19, y = 15, sprite = "bald", tint = { 0.7, 0.2, 0.3 }, face = "up", trainer = "keelhaul", sight = 0 },
        { id = "firallon", x = 20, y = 14, sprite = "hero", tint = { 0.65, 0.15, 0.25 }, face = "left",
          trainer = "firallon", sight = 0, hidden = Vanished("firallon") },
    },
}

---------------------------------------------------------------------------
-- Booty Bay: the Blackwater Raiders' port. The Salty Sailor Tavern, the Baron's hall, gryphons and the boat to
-- Jaguero Isle.
---------------------------------------------------------------------------

Maps.bootybay = {
    name = "Booty Bay",
    music = "cove",
    outdoor = true,
    theme = "jungle",
    rows = {
        "TTTTTTTTTTT==TTTTTTTTTTT",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T...================...T",
        "T...================...T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "T..........==..........T",
        "TwwwwwwwDDDDDDDDwwwwwwwT",
        "TwwwwwwwDDDDDDDDwwwwwwwT",
        "TwwwwwwwwwwDDwwwwwwwwwwT",
        "TwwwwwwwwwwwwwwwwwwwwwwT",
        "TTTTTTTTTTTTTTTTTTTTTTTT",
    },
    edges = { north = { map = "wildshore", dx = 0 } },
    stamps = {
        { kind = "bbhouse", x = 2, y = 1, inn = "bootybayinn" },        -- the Salty Sailor Tavern, door (5, 6)
        { kind = "bbhouse", x = 15, y = 1 },       -- the Baron's hall, door (18, 6)
        { kind = "bbhouse", x = 2, y = 10 },       -- warehouses, door (5, 15)
        { kind = "bbhouse", x = 15, y = 10 },      -- door (18, 15)
        { kind = "mast", x = 8, y = 15 }, { kind = "mast", x = 15, y = 15 },
    },
    warps = {
        { x = 5, y = 6, map = "bootybayinn", tx = 4, ty = 6, face = "up" },
        { x = 18, y = 6, map = "bbhall", tx = 4, ty = 6, face = "up" },
    },
    objects = {
        { x = 9, y = 10, tile = "wantedboard", hint = "Read the bounty board", script = function(G) G:BountyBoard() end },
        { x = 2, y = 9, tile = "alchemy", hint = "Brew at the alchemy table", script = function(G) G:CraftAt("alchemy") end },
        { x = 20, y = 9, tile = "forge", station = "forge", hint = "Smelt at the forge", script = function(G) G:CraftAt("mining") end },
        { x = 21, y = 9, tile = "anvil", station = "anvil", hint = "Smith at the anvil", script = function(G) G:CraftAt("blacksmithing") end },
    },
    signs = {
        { x = 13, y = 7, text = "BOOTY BAY\nA Blackwater Raiders port under Baron Revilgaz.\nWest: the Salty Sailor Tavern. East: the Baron's hall. South: the docks." },
        { x = 8, y = 16, text = "THE DOCKS\nGryphons to Darkshire. The boat to Jaguero Isle leaves from the pier's end." },
    },
    npcs = {
        { id = "gringer", name = "Gringer", role = "gryphon", x = 3, y = 8, sprite = "bald", tint = { 0.6, 0.85, 0.5 }, face = "right",
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
        { id = "marine", x = 9, y = 12, sprite = "hero", tint = { 0.75, 0.8, 0.95 }, face = "right", trainer = "marine", sight = 2 },
        { id = "bruiser", x = 14, y = 4, sprite = "bald", tint = { 0.55, 0.85, 0.45 }, face = "left", trainer = "bruiser", sight = 2 },
        { id = "boatman", name = "Skipper Zinkle", x = 12, y = 19, sprite = "bald", tint = { 0.6, 0.85, 0.5 }, face = "up",
          script = function(G)
              if G:YesNo("Skipper Zinkle: Boat to Jaguero Isle? Gorillas, panthers and the big fella himself. Two silver.") then
                  if G.save.money < 200 then
                      G:Say("Skipper Zinkle: Two silver, I said. Come back with it.")
                      return
                  end
                  G.save.money = G.save.money - 200
                  G:EnterMap("jaguero", 4, 14, "up")
                  G:Say("The boat rounds the cape and grounds on Jaguero Isle's beach. Zinkle waits by the boat.")
              else
                  G:Say("Skipper Zinkle: The isle isn't going anywhere.")
              end
          end },
        { id = "heming", name = "Old Man Heming", role = "profession", x = 10, y = 18, sprite = "bald",
          -- fishes off the docks all day, tells fish stories at the Salty Sailor at night
          day = {
              { "00:00", inside = "bootybayinn", label = "Telling fish stories at the tavern" },
              { "05:30", path = { { 5, 6 }, { 5, 8 }, { 11, 8 }, { 11, 17 }, { 10, 17 }, { 10, 18 } }, face = "down",
                act = "fish", label = "Fishing off the docks", walk = "Off to the docks" },
              { "20:30", path = { { 10, 18 }, { 10, 17 }, { 11, 17 }, { 11, 8 }, { 5, 8 }, { 5, 6 } }, enter = "bootybayinn",
                label = "Telling fish stories at the tavern", walk = "Heading to the tavern" },
          },
          says = { { "06:00", "Early bite's the best bite." }, { "15:00", "That one was THIS big, I swear." } },
          tint = { 0.85, 0.82, 0.72 }, face = "down",       -- Expert Fishing
          script = function(G) G:FishingTrainer("heming") end },
        { id = "dockhand", name = "Dockhand", x = 14, y = 18, sprite = "hero", tint = { 0.7, 0.75, 0.6 }, face = "left",
          -- hauls crates up and down the pier all day; the tavern at night
          day = {
              { "00:00", inside = "bootybayinn", label = "Asleep at the tavern" },
              { "07:00", path = { { 5, 6 }, { 5, 8 }, { 11, 8 }, { 11, 17 }, { 14, 17 } }, face = "left",
                label = "On the docks", walk = "Off to the docks" },
              { "07:10", loop = { { 14, 17, wait = 3, face = "down" }, { 9, 17, wait = 3, face = "down" }, { 14, 17 } },
                label = "Hauling crates down the pier" },
              { "19:00", path = { { 14, 17 }, { 11, 17 }, { 11, 8 }, { 5, 8 }, { 5, 6 } }, enter = "bootybayinn",
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
    warps = { { x = 4, y = 7, map = "bootybay", tx = 5, ty = 7, face = "down" } },
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
    warps = { { x = 4, y = 7, map = "bootybay", tx = 18, ty = 7, face = "down" } },
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
    music = "arena",
    outdoor = true,
    theme = "jungle",
    herbs = { "briarthorn" },
    nodes = { herb = { { 4, 12 }, { 15, 3 } } },
    rows = {
        "wwwwwwwwwwwwwwwwwwww",
        "wwwwwwwwwwwwwwwwwwww",
        "wwssssssssssssssssww",
        "wws..............sww",
        "wws.\"\"\"\"\"..\"\"\"\"\".sww",
        "wws.\"\"\"\"\"..\"\"\"\"\".sww",
        "wws..............sww",
        "wws..............sww",
        "wws..............sww",
        "wws..............sww",
        "wws.\"\"\"\"\"..\"\"\"\"\".sww",
        "wws.\"\"\"\"\"..\"\"\"\"\".sww",
        "wws..............sww",
        "wwssssssssssssssssww",
        "wwsDDsssssssssssssww",
        "wwwwwwwwwwwwwwwwwwww",
    },
    stamps = { { kind = "jbigtree", x = 9, y = 7 } },
    signs = { { x = 10, y = 13, text = "JAGUERO ISLE\nBananas belong to King Mukla. So does everything else." } },
    encounters = {
        { sp = "gorilla", min = 46, max = 48, weight = 35 },
        { sp = "eldergorilla", min = 47, max = 49, weight = 15 },
        { sp = "panther", min = 46, max = 48, weight = 20 },
        { sp = "shadowmaw", min = 48, max = 49, weight = 5 },
        { sp = "lashtail", min = 46, max = 48, weight = 15 },
        { sp = "coldeye", min = 46, max = 48, weight = 10 },
    },
    chests = { { id = "jinets", x = 16, y = 3, item = "greatnet", n = 3 } },
    npcs = {
        { id = "zinkle", name = "Skipper Zinkle", x = 3, y = 14, sprite = "bald", tint = { 0.6, 0.85, 0.5 }, face = "up",
          script = function(G)
              if G:YesNo("Skipper Zinkle: Back to Booty Bay?") then
                  G:EnterMap("bootybay", 12, 18, "down")
                  G:Say("The boat carries you back round the cape to Booty Bay's docks.")
              end
          end },
        { id = "castaway", x = 12, y = 12, sprite = "hero", tint = { 0.8, 0.7, 0.55 }, face = "left", trainer = "castaway", sight = 2 },
        { id = "mukla", x = 10, y = 3, sprite = "bald", tint = { 0.5, 0.4, 0.3 }, face = "down",
          trainer = "mukla", sight = 3, hidden = Vanished("mukla") },
    },
}
