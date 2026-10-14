if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/MapsBlackrock.lua", ...) then return end -- DisasterZone Games/Azeromon/MapsBlackrock.lua
-- Blackrock (Azeromon 0.25, badges 6 and 7; the maps join ns.AzeroMaps, the format is described in Maps.lua).
-- Darkshire's north road opens with the Blackwater Seal: Three Corners, Lakeshire on its lake, Lake Everstill and
-- Stonewatch Keep (Gath'Ilzogg, the Stonewatch Seal), then Render's Valley up into the Burning Steppes (Morgan's
-- Vigil, Lord Victor Nefarius on Flame Crest), Blackrock Mountain's lava cavern with its chain bridges, the Searing
-- Gorge (Thorium Point) north of it, the Imperial Seat in Blackrock Depths (Emperor Thaurissan, the Dark Iron
-- Signet), and the Molten Core below, where Magmadar waits (Lothos Riftwaker lets Signet holders down).
-- The rows are the approved mockup's (dev/art/casc/zone_mockup/blackrock/region.py): organic, never boxy.
-- Themes redridge / steppes / gorge / blackrock (Game.lua THEMES); 'w' is lava in the last three.
local addonName, ns = ...

local Maps = ns.AzeroMaps
local D = ns.AzeroData

-- A gryphon master: learns this roost's route the first time (flag), then flies to every known roost.
-- routes: { { name, map, x, y, face, cost, flag (nil = always known), text } ... }
local function Gryphons(G, who, flag, learned, routes)
    if not G:Flag(flag) then
        G:SetFlag(flag)
        G:Say(learned)
    end
    local options, dest = {}, {}
    for _, r in ipairs(routes) do
        if not r[7] or G:Flag(r[7]) then
            options[#options + 1] = r[1] .. " (" .. D.Money(r[6]) .. ")"
            dest[#dest + 1] = r
        end
    end
    options[#options + 1] = "Stay"
    local to = dest[G:Choose(who .. ": Where to?", options)]
    if not to then
        G:Say(who .. ": Mind the road, then.")
        return
    end
    if G.save.money < to[6] then
        G:Say(who .. ": That's " .. D.Money(to[6]) .. ", friend.")
        return
    end
    G.save.money = G.save.money - to[6]
    G:EnterMap(to[2], to[3], to[4], to[5])
    G:Say(to[8])
end

local TO_LAKESHIRE = { "Lakeshire", "lakeshire", 17, 22, "right", 30, "fp_lakeshire",
                       "You fly over Redridge's red hills and come down by the lake at Lakeshire." }
local TO_VIGIL = { "Morgan's Vigil", "steppes", 34, 21, "right", 30, "fp_morgansvigil",
                   "You fly north through the smoke to Morgan's Vigil, above the burning plain." }
local TO_THORIUM = { "Thorium Point", "gorge", 7, 7, "up", 40, "fp_thoriumpoint",
                     "You fly over Blackrock Mountain's peak and down onto Thorium Point's shelf." }
local TO_DARKSHIRE = { "Darkshire", "darkshire", 17, 14, "down", 30, nil,
                       "You fly south over the forest's edge, down to Darkshire's lamps." }

---------------------------------------------------------------------------
-- Redridge Mountains: Three Corners, Lakeshire, Lake Everstill, Stonewatch Keep
---------------------------------------------------------------------------

Maps.threecorners = {
    name = "Three Corners",
    music = "forest",
    outdoor = true,
    theme = "redridge",
    herbs = { "fadeleaf", "kingsblood" }, ores = { "iron" },
    nodes = { herb = { { 24, 19 }, { 4, 8 } }, ore = { { 30, 4 } } },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTT.TT....TTTTT",
        "TTTTT.TTT..TTTTTTTTTT..Twwwww..TTT",
        "TTTT...T....TTTTTTTTTT.wwwwwww..TT",
        "TTT.........TTTTTTTTTT..wwwww....T",
        "TT...........TTTTTTTTTT..........T",
        "T............TTTTTT..TT..........T",
        "T............TTTT................T",
        "T...\"\"\"......T.TTT........========",
        "TTT\"\"\"\"\"....TTT.........==========",
        "TTTTTTT\".....T.....=========\"\"\"..T",
        "TTTTTTTT..........========..\"\"\"\".T",
        "TTTTTTTTT........====.....TTTTT..T",
        "TTTTTTTTT....=======...\"\"....TTTTT",
        "TTTTTTTT....=======.\"\"\"\"\"\"\".....TT",
        "TTTTTTTT...====...T.\"\"\"\"\"\"\"..TTTTT",
        "TTTTTTT...====.\"TTTT\"\"\"\"\"\"\"..TTTTT",
        "TTTTTTT..====\"\"\"TTTT.\"\"\"\".....TTTT",
        "TTTTTT...===.\"TTTTTTTT.......TTTTT",
        "TTTTTT...==...TTTTTTTTTT.TTTTTTTTT",
        "TTTTTT...==...TTTTTTTTTTTTTTTTTTTT",
        "TTTTT....==...TTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTT==TTTTTTTTTTTTTTTTTTTTTTT",
    },
    edges = { south = { map = "darkshire", dx = 2 }, east = { map = "lakeshire", dy = 1 } },
    stamps = { { kind = "tent", x = 5, y = 5 } },          -- the poachers' camp in the gnoll hollow
    objects = { { x = 8, y = 6, tile = "crate" } },
    signs = {
        { x = 18, y = 13, text = "THREE CORNERS\nEast: Lakeshire, over the Redridge road.\nSouth: Darkshire." },
    },
    encounters = {
        { sp = "blackwhelp", min = 48, max = 50, weight = 20 },
        { sp = "mongrel", min = 48, max = 50, day = 25, night = 20 },
        { sp = "condor", min = 48, max = 50, day = 15, night = 10 },
        { sp = "tarantula", min = 48, max = 50, day = 15, night = 20 },
        { sp = "greatgoretusk", min = 49, max = 50, day = 10, night = 8 },
        { sp = "rrmystic", min = 48, max = 50, day = 0, night = 18 },
    },
    npcs = {
        { id = "rrpoacher", x = 8, y = 8, sprite = "bald", tint = { 0.72, 0.58, 0.42 }, face = "right",
          trainer = "rrpoacher", sight = 3 },
    },
}

Maps.lakeshire = {
    name = "Lakeshire",
    music = "tavern",
    outdoor = true,
    theme = "redridge",
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTT.TTT..TTTTTT..TTTTTTTTTTTTT",
        "TT...................TTTTTTTTTTTTT",
        "TT...................TTTTTTTTTTTTT",
        "T....................TTT..TTTTTTTT",
        "T....................TTT..TTTTTTTT",
        "TT.......................TTTTTTTTT",
        "TT.......................TTTTTTTTT",
        "T........................TTTTTTTTT",
        "T.l.....l......l............TTTTTT",
        "=======================.......TTTT",
        "=======================DDDDDDDDDDD",
        "T.........TT.==......==DDDDDDDDDDD",
        "T............==....l...wwwwwwwwwww",
        "T............==.......wwwwwwwwwwww",
        "TT...........==....kgwwwwwwwwwww.T",
        "TT...........==....k.wwwwwwwwwwwwT",
        "TT..........T==......wwwwwwwwwwwww",
        "TT..........T===.....wwwwwwwwwwwww",
        "TT...###...lT====.wwwwwwwwwwwwwwww",
        "TT...#......T.====wwwwwwwwwwwwwwww",
        "TT...###....T..====..wwwwwwwwwwwww",
        "TTTTTTT.....T...===..wwwwwwwwwwwww",
        "TTTTTTTTTTT.TTTT.....Twwwwwwwwwwww",
        "TTTTTTTTTTTTTTTTTT..TTwwwwwwwwwTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTwwwwwwwTTTT",
    },
    edges = { west = { map = "threecorners", dy = -1 }, east = { map = "everstill", dy = -1 } },
    stamps = {
        { kind = "rrhouse", x = 3, y = 3 },         -- the Lakeshire Inn, door (6, 8)
        { kind = "stonehouse", x = 9, y = 3 },      -- the town hall
        { kind = "rrhouse", x = 15, y = 3 },
        { kind = "rrhouse", x = 3, y = 13 },
        { kind = "tent", x = 9, y = 15 },
        { kind = "windmill", x = 16, y = 14 },
    },
    warps = { { x = 6, y = 8, map = "lakeshireinn", tx = 4, ty = 6, face = "up" } },
    objects = {
        { x = 20, y = 9, tile = "wantedboard", hint = "Read the bounty board", script = function(G) G:BountyBoard() end },
        { x = 2, y = 12, tile = "forge", station = "forge", hint = "Smelt at the forge", script = function(G) G:CraftAt("mining") end },
        { x = 3, y = 12, tile = "anvil", station = "anvil", hint = "Smith at the anvil", script = function(G) G:CraftAt("blacksmithing") end },
    },
    signs = {
        { x = 5, y = 12, text = "LAKESHIRE\nPopulation: fewer every week.\nThe bridge east leads to Lake Everstill." },
    },
    npcs = {
        { id = "solomon", name = "Magistrate Solomon", x = 11, y = 9, sprite = "hero", tint = { 0.9, 0.86, 0.7 }, face = "down",
          script = function(G)
              if G:Flag("badge_stonewatch") then
                  G:Say("Magistrate Solomon: Gath'Ilzogg beaten! Redridge breathes again, and Stormwind will hear whose doing it was.")
                  G:Say("Magistrate Solomon: The Lakeshire Guard will let you into Render's Valley now. Beyond it the Steppes burn.")
                  return
              end
              G:Say("Magistrate Solomon: You came from Darkshire? Then you know what it is to hold a town together.")
              G:Say("Magistrate Solomon: Blackrock orcs to the north, gnolls in the hills, and Stormwind sends... letters.")
              G:Say("Magistrate Solomon: Gath'Ilzogg runs Stonewatch Keep. Break him and Redridge breathes again.")
          end },
        { id = "marris", name = "Marshal Marris", x = 22, y = 10, sprite = "hero", tint = { 0.7, 0.8, 1 }, face = "down",
          script = function(G)
              G:Say("Marshal Marris: Bridge is open again, thanks to you. Yowler's lot kept knocking the planks out.")
              G:Say("Marshal Marris: Past the lake the road climbs to Stonewatch. Bring fire-proof beasts. Or water ones.")
          end },
        { id = "ariena", name = "Ariena Stormfeather", role = "gryphon", x = 18, y = 22, sprite = "girl", tint = { 1, 0.9, 0.7 }, face = "left",
          script = function(G)
              Gryphons(G, "Ariena Stormfeather", "fp_lakeshire",
                  "Ariena Stormfeather: Gryphons to Darkshire, and on from there. Lakeshire's on your flight map now.",
                  { TO_DARKSHIRE, TO_VIGIL, TO_THORIUM })
          end },
        { id = "lamar", name = "Lamar Veisilli", role = "shop", x = 7, y = 9, sprite = "bald", tint = { 0.95, 0.8, 0.7 }, face = "down",
          script = function(G)
              G:Say("Lamar Veisilli: Fresh fruit! And Greater Healing Potions, since that's what folk buy now.")
              G:Shop("Lamar Veisilli", "lakeshire")
              G:Say("Lamar Veisilli: Mind the gnolls on the road.")
          end },
        { id = "verner", name = "Verner Osgood", role = "profession", x = 4, y = 12, sprite = "bald", tint = { 0.85, 0.7, 0.6 }, face = "left",
          script = function(G)
              G:Say("Verner Osgood: Copper and tin? That's apprentice work. I teach Journeyman, up to 150, in all four trades.")
              if G.ProfessionTrainer then
                  G:ProfessionTrainer("journeyman")
              else
                  G:Say("Verner Osgood: Iron's in these hills. For Mithril and Truesilver you want the Thorium Brotherhood.")
              end
          end },
        { id = "penny", name = "Stable Hand Penny", role = "stable", x = 8, y = 20, sprite = "girl", tint = { 0.9, 0.7, 0.6 }, face = "left",
          script = function(G)
              G:Say("Penny: Your box is here too. Want to swap a beast?")
              G:Stable()
              G:Say("Penny: They'll love the lake air.")
          end },
    },
}

Maps.lakeshireinn = {
    name = "Lakeshire Inn",
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
    warps = { { x = 4, y = 7, map = "lakeshire", tx = 6, ty = 9, face = "down" } },
    npcs = {
        { id = "brianna", name = "Innkeeper Brianna", role = "inn", x = 2, y = 2, sprite = "girl", tint = { 1, 0.82, 0.68 }, face = "down",
          script = function(G)
              G:Say("Innkeeper Brianna: Welcome to the Lakeshire Inn. The view of the lake is free; the beds aren't, but for you they are.")
              if G:YesNo("Innkeeper Brianna: Let your beasts rest here?") then
                  G:HealParty()
                  G:SetRespawn("lakeshireinn", 4, 5, "up", "Lakeshire")
                  G:Say("Innkeeper Brianna: There. Rested, and a bed kept for you.")
              end
          end },
        { id = "lsbarkeep", name = "Barkeep Daniels", x = 7, y = 2, sprite = "bald", tint = { 0.9, 0.78, 0.66 }, face = "down",
          script = function(G)
              G:Say("Barkeep Daniels: The gnolls drink the lake, the orcs drink the gnolls' blood, and I sell ale. Everybody's thirsty.")
          end },
    },
}

Maps.everstill = {
    name = "Lake Everstill",
    music = "forest",
    outdoor = true,
    theme = "redridge",
    herbs = { "fadeleaf", "kingsblood" }, ores = { "iron", "gold" },
    nodes = { herb = { { 5, 13 }, { 34, 12 }, { 12, 4 } }, ore = { { 35, 7 }, { 2, 19 }, { 18, 25 } } },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTT==TTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTT..==....TTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTT..==....TTTTTT",
        "TTTTTTTTTTTTTTTT.....T....==....TTTTTT",
        "TTTTTTTTTTTT..............==....TTTTTT",
        "TTTTT\"T\"\".................==......TTTT",
        "T....\"\"..........TT.......==........TT",
        "T..............TTT.......===........TT",
        "T.......====================........TT",
        "T......====================.........TT",
        "DD========......................hh.TTT",
        "DD=======.;;;;;..................h.TTT",
        "T.....;;;;wwwww;;;;;...............TTT",
        "T.....;;wwwwwwwwwwww;;...........\"\"TTT",
        "T.....;wwwwwwwwwwwwwww;;.......TTTTTTT",
        "TTT..;;wwwwwwwwwwwwwwww;;.......TTTTTT",
        "TTT.;wwwwwwwwwwwwwwwwwww;.......TTTTTT",
        "T...;wwwwwwwwwww.wwwwwww;;.....TTTTTTT",
        "T..;wwwwwwwwwww...wwwwww;;....TTTTTTTT",
        "T...;wwwwwwwwwww.wwwwwww;;.........TTT",
        "TTTT;wwwwwwwwwwwwwwwwww;;............T",
        "TTTTT;wwwwwwwwwwwwwwww;;.............T",
        "TTTTT.;;wwwwwwwwwwwww;;.........kk...T",
        "TTTTT\"\".;ww;;wwwwwwww;;T.............T",
        "TTTTT\"\"\".;;..;www;;;;;.T\"\"\"\".........T",
        "TTTTTTTT.......;;...TTTTTTT\"\".....TTTT",
        "TTTTTTTTT..........TTTTTTTTT.....TTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    },
    edges = { west = { map = "lakeshire", dy = 1 }, north = { map = "stonewatch", dx = -17 } },
    stamps = { { kind = "windmill", x = 30, y = 7 }, { kind = "tent", x = 29, y = 20 } },   -- Alther's Mill; Yowler's camp
    signs = {
        { x = 22, y = 10, text = "LAKE EVERSTILL\nNorth: Stonewatch Keep (Blackrock territory).\nEast: Alther's Mill." },
    },
    encounters = {
        { sp = "mongrel", min = 50, max = 52, day = 22, night = 18 },
        { sp = "rrbrute", min = 51, max = 53, weight = 10 },
        { sp = "broodling", min = 51, max = 53, weight = 12 },
        { sp = "condor", min = 50, max = 52, day = 14, night = 8 },
        { sp = "greatgoretusk", min = 50, max = 52, day = 12, night = 8 },
        { sp = "tarantula", min = 50, max = 52, day = 10, night = 16 },
        { sp = "rrmystic", min = 50, max = 52, day = 0, night = 16 },
        { sp = "chatter", min = 53, max = 53, day = 0, night = 1, rare = true },
    },
    coastEncounters = {
        { sp = "netter", min = 50, max = 52, weight = 40 },
        { sp = "tidecaller", min = 51, max = 53, weight = 25 },
        { sp = "eldercroc", min = 52, max = 53, weight = 8 },
    },
    npcs = {
        { id = "yowler", x = 31, y = 21, sprite = "bald", tint = { 0.7, 0.55, 0.4 }, face = "left",
          trainer = "yowler", sight = 0 },
    },
}

Maps.stonewatch = {
    name = "Stonewatch Keep",
    music = "mine",
    outdoor = true,
    theme = "redridge",
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTT==TTTT",
        "TTTTTTTTTTT...TTTTTTTTTT..==..TT",
        "TTTTTTTTT.....TTTT.....T..==..TT",
        "TTTTTTTTT......TT.........==..TT",
        "TTTTTTTRRRRRRRRRRRRRRRRTT.==..TT",
        "TTTTTTTR..............RT.===..TT",
        "TTTTTTTR.i..........i.RT.===..TT",
        "TTTTT..R..............R..==..TTT",
        "TTTTT..R......==......R..==..TTT",
        "TTTTY..R......==......R..==..TTT",
        "TTTTT..R......==......R====.TTTT",
        "TTTTT..R......==......=====.TTTT",
        "TTTTT..R.i....==....i.===..TTTTT",
        "TTTTTT.R......==......==.YTTTTTT",
        "TTTTTT.RRRRRRR==RRRRRR==..TTTTTT",
        "TTTTTTY......i==i....===.TTTTTTT",
        "TTTTTTT.......==..TT====TTTTTTTT",
        "TTTTTTT....kk.=========TTTTTTTTT",
        "TTTTTYTTT....=========TTTTTTTTTT",
        "TTTTTTTTT...====.TgTTTTTTTTTTTTT",
        "TTTTTTTTT..====..TTTTTTTTTTTTTTT",
        "TTTTTTTT..====..TTTTTYTTTTTTTTTT",
        "TTTTTTTT.====..TTTTTTTTTTTTTTTTT",
        "TTTTTTTT.===..TTTTTTTTTTTTTTTTTT",
        "TTTTTTT..==..TTTTTTTTTTTTTTTTTTT",
        "TTTTTTT..==..TTTTTTTTTTTTTTTTTTT",
        "TTTTTTT..==..TTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTT==TTTTTTTTTTTTTTTTTTTTT",
    },
    edges = { south = { map = "everstill", dx = 17 }, north = { map = "steppes", dx = 0 } },
    -- Render's Valley: the Lakeshire Guard turns back anyone without the Stonewatch Seal
    triggers = {
        { x = 26, y = 1, cond = function(G) return not G:Flag("badge_stonewatch") end, script = function(G) G:RendersValleyGate() end },
        { x = 27, y = 1, cond = function(G) return not G:Flag("badge_stonewatch") end, script = function(G) G:RendersValleyGate() end },
    },
    stamps = {
        { kind = "throne", x = 14, y = 6 }, { kind = "banner", x = 12, y = 5 }, { kind = "banner", x = 17, y = 5 },
        { kind = "tent", x = 9, y = 7 }, { kind = "tent", x = 19, y = 9 },
        { kind = "banner", x = 12, y = 15 }, { kind = "banner", x = 17, y = 15 },
    },
    signs = {
        { x = 21, y = 17, text = "RENDER'S VALLEY\nThe pass to the Burning Steppes.\n(Lakeshire's guards turn back anyone without the Stonewatch Seal.)" },
    },
    encounters = {
        { sp = "rrbrute", min = 51, max = 53, day = 20, night = 15 },
        { sp = "broodling", min = 52, max = 53, weight = 20 },
        { sp = "firegut", min = 52, max = 53, weight = 10 },
    },
    npcs = {
        { id = "gath", x = 15, y = 8, sprite = "bald", tint = { 0.55, 0.8, 0.45 }, face = "down",
          trainer = "gath", sight = 0 },
        { id = "bwgrunt", x = 12, y = 11, sprite = "bald", tint = { 0.6, 0.82, 0.5 }, face = "right", trainer = "bwgrunt", sight = 3 },
        { id = "bwshadow", x = 17, y = 11, sprite = "bald", tint = { 0.5, 0.6, 0.55 }, face = "left", trainer = "bwshadow", sight = 3 },
        { id = "swguard", name = "Lakeshire Guard", x = 24, y = 11, sprite = "hero", tint = { 0.7, 0.8, 1 }, face = "down",
          script = function(G)
              if G:Flag("badge_stonewatch") then
                  G:Say("Lakeshire Guard: The Stonewatch Seal. On you go, then. Render's Valley climbs to the Burning Steppes.")
              else
                  G:Say("Lakeshire Guard: Render's Valley? Not without the Stonewatch Seal. Orders.")
              end
          end },
    },
}

---------------------------------------------------------------------------
-- The Burning Steppes: Flame Crest, Dreadmaul Rock, Morgan's Vigil
---------------------------------------------------------------------------

Maps.steppes = {
    name = "Burning Steppes",
    music = "haunted",
    outdoor = true,
    theme = "steppes",
    herbs = { "firebloom", "sungrass" }, ores = { "mithril", "iron" },
    nodes = { herb = { { 16, 4 }, { 35, 12 }, { 6, 24 } }, ore = { { 24, 4 }, { 2, 10 }, { 36, 19 } } },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTT......TTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTT......TTTTTTTTTTTTTTTTTT",
        "TTTTTT..wwTTTTTT......TTTTT.TTTTTTTTTTTT",
        "TTTTTTwwwwwTTTTT..===.T......RRRTTTTTRTT",
        "TTTTTTwwwwwwwww...===........RRRRRRRTTTT",
        "TTTwwwwwwwwwwwww...==..\"............TTTT",
        "TTwwwwwwwwwwwwww...==.\"\"\"\"..........TTTT",
        "TTwwwwwwwwwwwwww...==\"\"\"\"\"...wwwww...TTT",
        "T..wwwwwwwwwwwwTT..==\"\"\"\"\"..wwwwww...TTT",
        "T..TTTTwwTTwwwwTT..==.\"\"\"....wwww....TTT",
        "T...TTTTT..........==.........ww.....TTT",
        "T....T.............==................TTT",
        "T..................==.............TTTTTT",
        "===============....==..TT.........TTT.TT",
        "=======================.......\"\"\"\"TT...T",
        "T.\"\"\"\"\"......===========.....\"\"\"\"\"\"\"...T",
        "T.T\"\"\"\"\"......R......====.....\"\"\"\"\"....T",
        "T.TTT\"\"\".....RRR......=====.....\"\".....T",
        "T.TTT.........RRR......====............T",
        "T.TTTTwwwwww....RRRRRR...===..TT.....TTT",
        "T.TTTwwwwwww\"TT\"...RRRR..===.........TTT",
        "TTTTTTwwwww\"\"TT\"....RR....==.######..TTT",
        "TTTTTT...\"\"\"TTT.......TT..==.........TTT",
        "TTTTTT....\"\"TTT......TTT..==.........TTT",
        "TTTTTTTTTTTTTTT...........==i......i.TTT",
        "TTTTTTTTTTTTTT.TTTT.......==.TTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTT==TTTTTTTTTTTT",
    },
    edges = { south = { map = "stonewatch", dx = 0 }, west = { map = "brm", dy = -2 } },
    stamps = {
        { kind = "tent", x = 30, y = 23 }, { kind = "tent", x = 33, y = 23 }, { kind = "banner", x = 29, y = 23 },   -- Morgan's Vigil
    },
    signs = {
        { x = 23, y = 17, text = "BURNING STEPPES\nWest: Blackrock Mountain.  North: Flame Crest.\nSouth-east: Morgan's Vigil." },
    },
    encounters = {
        { sp = "spitter", min = 53, max = 55, day = 22, night = 18 },
        { sp = "firegut", min = 53, max = 56, day = 20, night = 16 },
        { sp = "broodling", min = 53, max = 55, day = 15, night = 12 },
        { sp = "scaldingdrake", min = 54, max = 56, day = 12, night = 10 },
        { sp = "firetail", min = 54, max = 56, weight = 14 },
        { sp = "emberworg", min = 55, max = 57, weight = 6 },
        { sp = "blackwyrmkin", min = 56, max = 57, weight = 5 },
        { sp = "burningimp", min = 53, max = 55, day = 0, night = 14 },
        { sp = "volchan", min = 58, max = 58, day = 0, night = 1, rare = true },
    },
    npcs = {
        { id = "maxwell", name = "Marshal Maxwell", role = "rest", x = 31, y = 21, sprite = "hero", tint = { 0.7, 0.8, 1 }, face = "down",
          script = function(G)
              G:Say("Marshal Maxwell: Morgan's Vigil. We hold this hill and nothing else.")
              if not G:Flag("beat_nef1") then
                  G:Say("Marshal Maxwell: A man in black was asking about you up on Flame Crest. Nobody here likes the look of him.")
              end
              if G:YesNo("Marshal Maxwell: Your beasts are singed. Rest them by our fire?") then
                  G:HealParty()
                  G:SetRespawn("steppes", 33, 21, "down", "Morgan's Vigil")
                  G:Say("Marshal Maxwell: There. Back out into the ash with you.")
              end
          end },
        { id = "borgus", name = "Borgus Stoutarm", role = "gryphon", x = 35, y = 21, sprite = "bald", tint = { 0.95, 0.8, 0.6 }, face = "down",
          script = function(G)
              Gryphons(G, "Borgus Stoutarm", "fp_morgansvigil",
                  "Borgus Stoutarm: Gryphons to Lakeshire and Thorium Point. Mind the ash in their feathers.",
                  { TO_LAKESHIRE, TO_THORIUM })
          end },
        { id = "nef1", x = 18, y = 3, sprite = "hero", tint = { 0.35, 0.3, 0.42 }, face = "down",
          trainer = "nef1", sight = 0 },
    },
}

---------------------------------------------------------------------------
-- Blackrock Mountain: the great cavern round a lava sea; the Imperial Seat in Blackrock Depths; the Molten Core
---------------------------------------------------------------------------

Maps.brm = {
    name = "Blackrock Mountain",
    music = "mine",
    theme = "blackrock",
    cave = { rate = 6 },
    ores = { "darkiron" },
    nodes = { ore = { { 28, 21 }, { 10, 21 } } },
    rows = {
        "TTTTTTTTTTTTTTTTDDTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTT.....DD.TTTTTTTTTTTTTTT",
        "TTTT.......TT...DD.TTTT.......TTTT",
        "TTTT.......TT...DD............TTTT",
        "TTTT.......T.i..DD..i.........TTTT",
        "TTTT............DD....T.......TTTT",
        "TTTT.......www..DD....T.......TTTT",
        "TTTTTiTT...wwwwwDDw.........i.TTTT",
        "TTT.TTT...wwwwwwDDww...ww......TTT",
        "TTT..TT...wwwwwwDDwww.wwww.......T",
        "TT...TTw.wwwwwwwDDwwwwwwww.......T",
        "TT...TwwwwwwwwwwDDwwwwwwww.......T",
        "TTDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
        "TTDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
        "TTTT..wwwwwwwwwwDDwwwwwwwww..T...T",
        "TTTTT..wwwwwwwwwDDwwwwwwwww..TTTTT",
        "TTTTTT.wwwwwwwwwDDwwwwwwwwwTTT...T",
        "TTTTTTwwwwwwwwwwDDwwwwwwwwTTTT...T",
        "TTTiTTTwwww..wwwDDwwwwwwwwTTTi..TT",
        "TTT...........wwDDww............TT",
        "TTT............wDDw.............TT",
        "TTT.............DD..T...........TT",
        "TTT.............DDTTT...........TT",
        "TTTTTTTT...T....TTTTT...TTTTTTTTTT",
        "TTTTTTTT..TTTT.TTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    },
    edges = { east = { map = "steppes", dy = 2 }, north = { map = "gorge", dx = 3 } },
    stamps = {
        { kind = "mineentrance", x = 4, y = 19 },       -- Blackrock Depths, door (5, 20)
        { kind = "mineentrance", x = 6, y = 2 },        -- Blackrock Spire (sealed)
        { kind = "mineentrance", x = 25, y = 2 },       -- the Molten Core's mouth (Lothos keeps it)
    },
    warps = { { x = 5, y = 20, map = "brd", tx = 12, ty = 19, face = "up" } },
    objects = {
        { x = 24, y = 20, tile = "forge", station = "blackforge", hint = "Smelt at the Black Forge",
          script = function(G) G:CraftAt("mining") end },
        { x = 25, y = 20, tile = "anvil", station = "anvil", hint = "Smith at the anvil", script = function(G) G:CraftAt("blacksmithing") end },
    },
    signs = {
        { x = 19, y = 4, text = "BLACKROCK MOUNTAIN\nWest: Blackrock Depths.  North-west: Blackrock Spire (sealed).\nNorth-east: the Molten Core (ask Lothos)." },
    },
    encounters = {
        { sp = "firewalker", min = 56, max = 58, weight = 25 },
        { sp = "rager", min = 56, max = 58, weight = 20 },
        { sp = "lavaspider", min = 56, max = 58, weight = 20 },
        { sp = "blackwyrmkin", min = 56, max = 58, weight = 15 },
        { sp = "obsidian", min = 57, max = 58, weight = 5 },
    },
    npcs = {
        { id = "lothos", name = "Lothos Riftwaker", x = 27, y = 5, sprite = "hero", tint = { 0.95, 0.6, 0.4 }, face = "down",
          script = function(G)
              if not G:Flag("badge_darkiron") then
                  G:Say("Lothos Riftwaker: The Molten Core lies below. Only those who bear the Dark Iron Signet may pass.")
                  G:Say("Lothos Riftwaker: Come back when Thaurissan kneels.")
                  return
              end
              if G:YesNo("Lothos Riftwaker: The Dark Iron Signet. Very well. Shall I take you down to the Molten Core?") then
                  G:EnterMap("moltencore", 4, 17, "up")
                  G:Say("Lothos opens a rift. Heat rolls up from below, and the rock under your feet glows.")
              else
                  G:Say("Lothos Riftwaker: The Core will wait. It has waited a long time.")
              end
          end },
        { id = "nef2", x = 17, y = 16, sprite = "hero", tint = { 0.35, 0.3, 0.42 }, face = "up",
          trainer = "nef2", sight = 2 },
        { id = "darksmith", name = "Dark Iron Smith", x = 23, y = 20, sprite = "bald", tint = { 0.5, 0.45, 0.55 }, face = "right",
          script = function(G)
              G:Say("Dark Iron Smith: The Black Forge. Only fire this hot smelts Dark Iron. Skill 160, eight ores a bar.")
          end },
    },
}

Maps.brd = {
    name = "The Imperial Seat",
    music = "haunted",
    theme = "blackrock",
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTT....TTTTTTTTTTT",
        "TTTTTTTTTT.......TTTTTTTTT",
        "TTTTTT.............TTTTTTT",
        "TTTTTT...i.......i...TTTTT",
        "TTTTT.......==.......TTTTT",
        "TTTTT.......==........TTTT",
        "TTT.T.......==........TTTT",
        "TT..T.......==........TTTT",
        "TT..i.......==.......iTTTT",
        "TTT.........==.........TTT",
        "TT..........==..........TT",
        "TT..ww......==.......w...T",
        "TTT.ww......==.......w..TT",
        "TTTTww......==.......wTTTT",
        "TTTT........==.......TTTTT",
        "TTTTT.......==.......TTTTT",
        "TTTTTTTi....==....i..TTTTT",
        "TTTTTTTTT...==......TTTTTT",
        "TTTTTTTTTT..==TTT...TTTTTT",
        "TTTTTTTTTTTT==TTTTTTTTTTTT",
    },
    warps = {
        { x = 12, y = 21, map = "brm", tx = 5, ty = 21, face = "down" },
        { x = 13, y = 21, map = "brm", tx = 5, ty = 21, face = "down" },
    },
    stamps = {
        { kind = "throne", x = 12, y = 4 }, { kind = "pillar", x = 8, y = 7 }, { kind = "pillar", x = 17, y = 7 },
        { kind = "pillar", x = 8, y = 12 }, { kind = "pillar", x = 17, y = 12 },
        { kind = "banner", x = 10, y = 4 }, { kind = "banner", x = 15, y = 4 },
    },
    npcs = {
        { id = "thaurissan", x = 13, y = 6, sprite = "bald", tint = { 0.5, 0.45, 0.6 }, face = "down",
          trainer = "thaurissan", sight = 0 },
        { id = "moira", name = "Princess Moira Bronzebeard", x = 15, y = 6, sprite = "girl", tint = { 0.8, 0.75, 0.9 }, face = "down",
          script = function(G)
              if G:Flag("beat_thaurissan") then
                  G:Say("Princess Moira: It's done, then. Go. Ironforge will want to hear it from you, not from me.")
                  return
              end
              G:Say("Princess Moira: Please. He is my husband, whatever Ironforge says.")
              G:Say("Princess Moira: Beat him if you must. I will be here after.")
          end },
        { id = "senator", x = 10, y = 10, sprite = "bald", tint = { 0.55, 0.5, 0.6 }, face = "right", trainer = "senator", sight = 3 },
        { id = "warden", x = 15, y = 15, sprite = "bald", tint = { 0.6, 0.5, 0.5 }, face = "left", trainer = "warden", sight = 3 },
    },
}

Maps.moltencore = {
    name = "Molten Core",
    music = "haunted",
    theme = "blackrock",
    cave = { rate = 6 },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTT...TTTTTT......TTTT",
        "TTTTTTT.....TTT.i.....iTTT",
        "TTT..wwwwww.i...........TT",
        "T....wwwwwww...........TTT",
        "T....wwwwwwww....===...TTT",
        "T.....wwwwww....====...TTT",
        "T.......www....====....TTT",
        "T..www.........===.......T",
        "T..www........===........T",
        "T...w........===wwwwww...T",
        "TTTT.....=======wwwwwww.TT",
        "TTTT....=======wwwwwwwwwTT",
        "TTT.=======....wwwwwwwwTTT",
        "TTi.======......wwwwwwT..T",
        "TT..==..i.T........wTTT.TT",
        "T...==....TT........TTTTTT",
        "TT..L=....TTT.TTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTT",
    },
    warps = { { x = 4, y = 18, map = "brm", tx = 27, ty = 6, face = "down" } },     -- back up to Lothos
    encounters = {
        { sp = "flameimp", min = 60, max = 62, weight = 50 },
        { sp = "corehound", min = 60, max = 62, weight = 40 },
        { sp = "lavasurger", min = 62, max = 62, weight = 3, rare = true },
    },
    npcs = {
        -- Magmadar: a scripted wild battle once per save (Lv 62, catchable; back next visit until caught)
        { id = "magmadar", name = "Magmadar", x = 19, y = 3, sprite = "bald", tint = { 1, 0.45, 0.2 }, face = "down",
          hidden = function(G) return G:Flag("caught_magmadar") end,
          script = function(G)
              G:Say("(a roar that shakes ash from the ceiling)")
              if G.LegendaryBattle then
                  G:LegendaryBattle("magmadar", 62)
              else
                  G:Say("Magmadar turns its burning eyes on you... and settles back onto the lava. Not yet.")
              end
          end },
    },
}

---------------------------------------------------------------------------
-- The Searing Gorge: Thorium Point and the Cauldron
---------------------------------------------------------------------------

Maps.gorge = {
    name = "Searing Gorge",
    music = "mine",
    outdoor = true,
    theme = "gorge",
    herbs = { "firebloom" }, ores = { "truesilver", "mithril", "darkiron" },
    nodes = { herb = { { 32, 10 }, { 8, 23 } }, ore = { { 25, 7 }, { 9, 14 }, { 29, 21 }, { 14, 23 } } },
    rows = {
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTT..TTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTT...............TTTTTTTTTTTTTTTTTTT",
        "TTTT..................TTTTTTTTTTTTTTTT",
        "TTT....................\"\"\"\"\"...TTTTTTT",
        "TT......................\"\"......TTTTTT",
        "TTT.........=========...........TTTTTT",
        "TTTT........=========............TTTTT",
        "TTTTTkkkg..........===========....TTTT",
        "TTTTT..............===========....TTTT",
        "TTTTT............wwwww......==....TTTT",
        "TTTT.........wwwwwwwwww..ww.===...TTTT",
        "TTTT.......wwwwwwwwwwwwwwwww====...TTT",
        "TTTTT.....wwwwwwwwwwwwwwwwww.===...TTT",
        "TTTT......wwwwwwwwwwwwwwwwww..==....TT",
        "TTTT.......wwwwwwwwwwwwwww..w===....TT",
        "TTTT.......wwwwwwwwwwwwwww..====...TTT",
        "TTTT.\"\"\"\"...wwwwwwwwwwwwwww===\"\"\"..TTT",
        "TTTT\"\"\"\"\"\"..T.wwwwwwwwwwwww===\"\"\"\"TTTT",
        "TTTT\"\"\"\"\"\"..TT.wwwwwwwwwww===\"\"\"\"\"TTTT",
        "TTTTT\"\"\"\"\".......wwwwwwww.==..\"\"\"TTTTT",
        "TTTTT.\"\"\"\".....TT.ww......==..\"\"\"TTTTT",
        "TTTTTTT\"\"................===....TTTTTT",
        "TTTTTT..................====...TTTTTTT",
        "TTTTTTT................====....TTTTTTT",
        "TTTTTTT............=======..n.TTTTTTTT",
        "TTTTTTTT...........======.nn.TTTTTTTTT",
        "TTTTTTTTT.....T....==.......TTTTTTTTTT",
        "TTTTTTTTTTTTTTTT...==..T.TTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTT==TTTTTTTTTTTTTTTTT",
    },
    edges = { south = { map = "brm", dx = -3 } },
    stamps = {
        { kind = "hut", x = 4, y = 2 }, { kind = "hut", x = 13, y = 2 }, { kind = "tent", x = 8, y = 3 },
        { kind = "banner", x = 11, y = 3 },                                                          -- Thorium Point
    },
    objects = {
        { x = 16, y = 4, tile = "forge", station = "forge", hint = "Smelt at the forge", script = function(G) G:CraftAt("mining") end },
        { x = 17, y = 4, tile = "anvil", station = "anvil", hint = "Smith at the anvil", script = function(G) G:CraftAt("blacksmithing") end },
        { x = 17, y = 3, tile = "alchemy", hint = "Brew at the alchemy table", script = function(G) G:CraftAt("alchemy") end },
    },
    signs = {
        { x = 21, y = 8, text = "THORIUM POINT\nThe Thorium Brotherhood welcomes those who bring ore.\nSouth: the Cauldron and Blackrock Mountain." },
    },
    encounters = {
        { sp = "glassweb", min = 54, max = 56, day = 20, night = 22 },
        { sp = "blazing", min = 54, max = 56, weight = 18 },
        { sp = "magma", min = 55, max = 57, weight = 15 },
        { sp = "temperedgolem", min = 55, max = 57, day = 15, night = 10 },
        { sp = "lavaspider", min = 56, max = 58, day = 8, night = 10 },
        { sp = "heavygolem", min = 57, max = 58, day = 5, night = 3 },
        { sp = "faultygolem", min = 58, max = 58, day = 1, night = 0, rare = true },
    },
    npcs = {
        { id = "hansel", name = "Hansel Heavyhands", role = "profession", x = 15, y = 6, sprite = "bald", tint = { 0.8, 0.65, 0.55 }, face = "down",
          script = function(G)
              G:Say("Hansel Heavyhands: The Thorium Brotherhood. We work Dark Iron, and we pay for what you dig.")
              if G.ProfessionTrainer then
                  G:ProfessionTrainer("expert")
              else
                  G:Say("Hansel Heavyhands: Expert training, up to 175. Dark Iron needs the Black Forge inside the mountain.")
              end
          end },
        { id = "lanie", name = "Lanie Reed", role = "gryphon", x = 7, y = 6, sprite = "girl", tint = { 1, 0.85, 0.7 }, face = "down",
          script = function(G)
              Gryphons(G, "Lanie Reed", "fp_thoriumpoint",
                  "Lanie Reed: Gryphons out of the Gorge. Thorium Point is on your flight map now.",
                  { TO_VIGIL, TO_LAKESHIRE })
          end },
        { id = "thoriumqm", name = "Thorium Quartermaster", role = "shop", x = 19, y = 4, sprite = "bald", tint = { 0.8, 0.72, 0.6 }, face = "left",
          script = function(G)
              G:Say("Thorium Quartermaster: Brotherhood stock. Truesilver rods, fire protection, the lot. Have a look.")
              G:Shop("Thorium Quartermaster", "thorium")
              G:Say("Thorium Quartermaster: Bring me ore and I'll remember your name.")
          end },
        { id = "dimaster", x = 24, y = 25, sprite = "bald", tint = { 0.5, 0.45, 0.55 }, face = "up", trainer = "dimaster", sight = 3 },
    },
}
