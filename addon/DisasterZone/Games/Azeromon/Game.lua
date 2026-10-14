if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Game.lua", ...) then return end -- DisasterZone Games/Azeromon/Game.lua
-- ns.Azero: the game controller, frame-free so the tests can drive it. The UI renders its state and
-- forwards input:
--   G:Update(dt)                 advance movement / waits (call every frame)
--   G.input.dir = "up"|...|nil   held direction;  G.input.run = bool (hold B to run)
--   G:PressA()                   interact / advance text
--   G.pending                    what the UI must show: text, choice, battle, shop, wait (nil = free roam)
--   G:Advance(value)             answer the pending prompt (choice index, battle result, ...)
-- Story scripts (Maps.lua) run as coroutines: G:Say / G:YesNo / G:Battle pause until answered.
-- The save lives in DisasterZoneDB.games.azeromon.save and is written live (SavedVariables flush at logout).
local addonName, ns = ...

local G = ns:NewModule("Azero")
local D = ns.AzeroData
local M = ns.AzeroMon
local Maps = ns.AzeroMaps
local A = ns.AzeroAtlas

G.GAME_ID = "azeromon"
G.STEP_TIME = 0.24
G.RUN_TIME = 0.13
G.TURN_DELAY = 0.09         -- a tap turns in place; holding longer walks
G.ENCOUNTER_PCT = 12

local DIRS = {
    up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 },
}
local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }
G.DIRS, G.OPPOSITE = DIRS, OPPOSITE

G.rng = math.random
G.input = { dir = nil, run = false, held = 0 }

---------------------------------------------------------------------------
-- Event feed: the game announces what happens; features (achievements, the guild leaderboard, ...) listen
-- instead of being wired into the battle / map code. A failing listener never breaks the game.
--   tame { mon, how = "caught"|"gift" }   seen { sp }            map { id }        load {}
--   battle { result, wild, trainer, used = { species... }, party, lastStanding = mon|nil }
--   level { mon, lvl }   evolve { mon, from, into }   badge { id }   pvp { result, opp }
--   blackout {}          chest { id }      beaten { trainer }  (after the "beat_" flag is set)
--   relearn { mon, move }  (the pet trainer reminded a beast of a move)      rematch { trainer }
--   shiny { mon }        a shiny wild beast appeared
--   step {}              the player walked a tile        bounty { id }   guildtier { tier }
---------------------------------------------------------------------------

local listeners = {}

function G:On(event, fn)
    listeners[event] = listeners[event] or {}
    table.insert(listeners[event], fn)
end

function G:Emit(event, e)
    e = e or {}
    e.event = event
    for _, fn in ipairs(listeners[event] or {}) do
        local ok, err = pcall(fn, self, e)
        if not ok then
            local handler = geterrorhandler and geterrorhandler()
            if handler then handler(err) end
        end
    end
    for _, fn in ipairs(listeners["*"] or {}) do pcall(fn, self, e) end
end

---------------------------------------------------------------------------
-- Map compilation (tile layers + collision), cached per map
---------------------------------------------------------------------------

local SOLID_CHARS = { T = true, w = true, W = true, X = true, b = true, d = true, p = true, t = true, C = true, c = true,
                      ["#"] = true, h = true, o = true, i = true, R = true, S = true, k = true, g = true, n = true,
                      G = true, l = true, Y = true }
local OVER_CHARS = { T = "tree", b = "bed", d = "dresser", p = "pot", t = "table", C = "chest", c = "counter",
                     ["#"] = "fence", h = "hay", o = "pumpkin", i = "torch1", k = "crate", g = "barrel", n = "cannon",
                     L = "stairs", G = "gravestone", l = "lamppost", Y = "deadtree", ["*"] = "chandelier" }
-- G gravestone, l lamp post, Y dead tree (Duskwood); '#' is the theme's fence (Duskwood: wrought iron)
-- R rock, S timber support (both solid walls), D ship deck, L ladder (a warp), k crate, g powder barrel, n cannon
local STAMP_SIZE = { house = { 5, 6 }, farmhouse = { 5, 6 }, stonehouse = { 5, 6 }, bigtree = { 3, 3 },
                     wbigtree = { 3, 3 }, mailbox = { 1, 2 }, scarecrow = { 1, 2 }, windmill = { 2, 3 }, tent = { 2, 2 },
                     ruinhouse = { 5, 6 }, mineentrance = { 3, 2 }, mast = { 1, 3 }, darkhouse = { 5, 6 },
                     dbigtree = { 3, 3 }, jbigtree = { 3, 3 }, bbhouse = { 5, 6 }, hut = { 3, 3 }, totem = { 1, 2 },
                     banner = { 1, 2 }, bannerblue = { 1, 2 }, window = { 1, 2 }, crest = { 2, 2 }, pillar = { 1, 2 },
                     fireplace = { 2, 2 }, throne = { 2, 1 } }
local HOUSES = { house = true, farmhouse = true, stonehouse = true, ruinhouse = true, darkhouse = true, bbhouse = true }
-- the walkable doorway tile of a stamp (dx, dy), if it has one
local function IsDoor(kind, dx, dy)
    if HOUSES[kind] then return dx == 3 and dy == 5 end
    if kind == "mineentrance" then return dx == 1 and dy == 1 end
    if kind == "hut" then return dx == 1 and dy == 2 end
    return false
end
-- Map themes swap the outdoor tile set. Westfall: dry golden grass, wheat for tall grass, olive trees.
local THEMES = {
    elwynn = { grass1 = "grass1", grass2 = "grass2", tall = "tall_", path = "path_", tree = "tree" },
    westfall = { grass1 = "wgrass1", grass2 = "wgrass2", tall = "wtall_", path = "wpath_", tree = "wtree" },
    -- the Deadmines: 'T' is rock, '=' is mine rails over the floor, dark water
    mine = { grass1 = "mfloor1", grass2 = "mfloor2", tall = "tall_", path = "rail", tree = nil, wall = "mwall",
             rails = true, water = { "dwater1", "dwater2" } },
    -- the Gurubashi Arena: sand, and 'T' is the stone wall
    arena = { grass1 = "sand1", grass2 = "sand2", tall = "tall_", path = "path_", tree = nil, wall = "arenawall" },
    -- Duskwood: dark grass, black pines, iron fences
    duskwood = { grass1 = "dgrass1", grass2 = "dgrass2", tall = "dtall_", path = "dpath_", tree = "dtree",
                 fence = "ironfence" },
    -- Stranglethorn Vale: deep green, palms, red earth; 'R' is a troll ruin's stone
    jungle = { grass1 = "jgrass1", grass2 = "jgrass2", tall = "jtall_", path = "jpath_", tree = "jtree",
               rock = "ruinwall" },
    -- the Guild Hall: flagstones, a red carpet for '=', brick walls for 'T'
    hall = { grass1 = "hallfloor1", grass2 = "hallfloor2", tall = "tall_", path = "carpet_", tree = nil, wall = "hallwall" },
}
G.THEMES = THEMES

local compiled = {}

local function Autotile(rows, w, h, x, y, ch, prefix, inner)
    local function same(xx, yy)
        if xx < 0 or yy < 0 or xx >= w or yy >= h then return true end
        return rows[yy + 1]:sub(xx + 1, xx + 1) == ch
    end
    local n, s, e, wv = same(x, y - 1), same(x, y + 1), same(x + 1, y), same(x - 1, y)
    if n and s and e and wv then
        if inner then
            if not same(x - 1, y - 1) then return prefix .. "inw" end
            if not same(x + 1, y - 1) then return prefix .. "ine" end
            if not same(x - 1, y + 1) then return prefix .. "isw" end
            if not same(x + 1, y + 1) then return prefix .. "ise" end
        end
        return prefix .. "c"
    end
    if not n and not wv then return prefix .. "tl" end
    if not n and not e then return prefix .. "tr" end
    if not s and not wv then return prefix .. "bl" end
    if not s and not e then return prefix .. "br" end
    if not n then return prefix .. "t" end
    if not s then return prefix .. "b" end
    if not wv then return prefix .. "l" end
    if not e then return prefix .. "r" end
    return prefix .. "c"
end

function G.Compile(id)
    local def = Maps[id]
    if compiled[id] and not (type(def) == "table" and def.dynamic) then return compiled[id] end
    if type(def) ~= "table" or not def.rows then return nil end
    if def.dynamic and def.prepare then def.prepare(def) end      -- (the Guild Hall: ropes across its shut wings)
    local rows = def.rows
    local h, w = #rows, #rows[1]
    local m = { id = id, def = def, w = w, h = h, base = {}, over = {}, solid = {}, tall = {}, water = {},
                sign = {}, warp = {}, chest = {}, object = {}, trigger = {} }
    local function key(x, y) return y * w + x end
    m.key = key
    local th = THEMES[def.theme or "elwynn"] or THEMES.elwynn
    m.theme = th
    for y = 0, h - 1 do
        local row = rows[y + 1]
        for x = 0, w - 1 do
            local ch = row:sub(x + 1, x + 1)
            local k = key(x, y)
            local base
            if ch == "\"" or ch == ";" then
                -- tall grass / wheat; ";" is shore grass with its own encounter table (def.coastEncounters)
                -- shore grass is green scrub (the Elwynn bush), so it reads apart from the wheat
                base = Autotile(rows, w, h, x, y, ch, (ch == ";") and "tall_" or th.tall, false)
                m.tall[k] = (ch == ";") and "coast" or "main"
            elseif ch == "=" and th.rails then
                -- rails: straight along the neighbouring rails, a crossing where they meet
                local function rail(xx, yy) return rows[yy + 1] and rows[yy + 1]:sub(xx + 1, xx + 1) == "=" end
                local horiz = rail(x - 1, y) or rail(x + 1, y)
                local vert = rail(x, y - 1) or rail(x, y + 1)
                base = th.grass1
                m.railOver = m.railOver or {}
                m.railOver[k] = (horiz and vert) and "rail_x" or (vert and "rail_v" or "rail_h")
            elseif ch == "=" then
                base = Autotile(rows, w, h, x, y, ch, th.path, true)
            elseif ch == "R" then
                base = th.rock or "mwall"
            elseif ch == "T" and th.wall then
                base = th.wall
            elseif ch == "S" then
                base = "msupport"
            elseif ch == "D" then
                base = "deck"
            elseif ch == "s" then
                base = "sand"
            elseif ch == "w" then
                base = "water1"
                m.water[k] = true
            elseif ch == "W" then base = "wall"
            elseif ch == "r" then base = "rug"
            elseif ch == "X" then base = "void"
            elseif def.outdoor or def.theme then       -- outdoor ground, or a themed cave floor
                base = ((x * 7 + y * 13) % 5 == 0) and th.grass2 or th.grass1
            else
                base = "floor"
            end
            m.base[k] = base
            if ch == "T" then m.over[k] = th.tree else m.over[k] = OVER_CHARS[ch] end   -- (no tree in a mine)
            if ch == "#" and th.fence then m.over[k] = th.fence end
            if m.railOver and m.railOver[k] then m.over[k] = m.railOver[k] end
            if SOLID_CHARS[ch] then m.solid[k] = true end
        end
    end
    for _, st in ipairs(def.stamps or {}) do
        local size = STAMP_SIZE[st.kind]
        for dy = 0, size[2] - 1 do
            for dx = 0, size[1] - 1 do
                local k = key(st.x + dx, st.y + dy)
                m.over[k] = string.format("%s_%d_%d", st.kind, dx, dy)
                if IsDoor(st.kind, dx, dy) then m.solid[k] = nil else m.solid[k] = true end
            end
        end
    end
    for _, s in ipairs(def.signs or {}) do
        local k = key(s.x, s.y)
        m.sign[k] = s
        m.over[k] = "sign"
        m.solid[k] = true
    end
    for _, c in ipairs(def.chests or {}) do
        local k = key(c.x, c.y)
        m.chest[k] = c
        m.solid[k] = true
    end
    for _, o in ipairs(def.objects or {}) do
        local k = key(o.x, o.y)
        m.object[k] = o
        m.over[k] = (type(o.tile) == "function") and o.tile(G) or o.tile     -- (a plinth: trophy or empty)
        m.solid[k] = true
    end
    -- herb and ore nodes (Crafting.lua): def.nodes = { herb = { {x, y}, ... }, ore = { ... } } with the map's
    -- def.herbs / def.ores as what grows there
    m.node = {}
    for kind, spots in pairs(def.nodes or {}) do
        local list = (kind == "herb") and def.herbs or def.ores
        if list then
            for _, p in ipairs(spots) do m.node[key(p[1], p[2])] = { x = p[1], y = p[2], kind = kind, list = list } end
        end
    end
    for _, wp in ipairs(def.warps or {}) do m.warp[key(wp.x, wp.y)] = wp end
    for _, tr in ipairs(def.triggers or {}) do m.trigger[key(tr.x, tr.y)] = tr end
    compiled[id] = m
    return m
end

---------------------------------------------------------------------------
-- Save
---------------------------------------------------------------------------

function G:Data() return ns.Games:GetData(G.GAME_ID) end

-- A sound effect (Sound.lua's S.SFX name).
function G:Sfx(name, arg) if ns.AzeroSound then ns.AzeroSound:Play(name, arg) end end

-- Any save counts, from any version: Load repairs what it can (an unknown map sends the player home), so CONTINUE
-- is offered and NEW GAME always asks before erasing it.
function G:HasSave()
    self:RestoreUndo()
    return type(self:Data().save) == "table"
end

-- A /reload (or a disconnect) in the middle of a script - a talk, a battle, a gift - must not keep half of it: a
-- starter given before its flag, a prize paid before the trainer counts as beaten, a gate's text cut before the
-- push back. While a script runs, data.undo holds the save as it was when the script started; the script's end
-- drops it, and a load that finds one puts it back. G:Checkpoint() makes the save as it is now the state to go back
-- to (what another player already saw happen: a trade's swap, a player battle's result).
local function Copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = Copy(x) end
    return t
end

function G:Checkpoint()
    local data = self:Data()
    data.undo = (self.co and type(self.save) == "table") and { save = Copy(self.save) } or nil
end

function G:RestoreUndo()
    if self.co then return end                     -- (only a fresh load: never under a running script)
    local data = self:Data()
    local u = data.undo
    data.undo = nil
    if type(u) == "table" and type(u.save) == "table" then data.save = u.save end
end

-- The nearest open tile to (x, y) on compiled map `m` (itself when open): a saved spot that is a wall now, a map
-- edge that lands in a tree. nil when the map has no open tile.
function G.OpenSpot(m, x, y)
    local npcAt = {}
    for _, n in ipairs(m.def.npcs or {}) do npcAt[m.key(n.x, n.y)] = true end
    local function open(tx, ty)
        if tx < 0 or ty < 0 or tx >= m.w or ty >= m.h then return false end
        local k = m.key(tx, ty)
        return not m.solid[k] and not npcAt[k] and not m.trigger[k]
    end
    x = math.max(0, math.min(m.w - 1, math.floor(tonumber(x) or 0)))
    y = math.max(0, math.min(m.h - 1, math.floor(tonumber(y) or 0)))
    if open(x, y) then return x, y end
    for r = 1, m.w + m.h do
        for dx = -r, r do
            local dy = r - math.abs(dx)
            if open(x + dx, y + dy) then return x + dx, y + dy end
            if dy ~= 0 and open(x + dx, y - dy) then return x + dx, y - dy end
        end
    end
end

function G:PlayerName()
    local n = UnitName and UnitName("player")
    return (n and n ~= "") and n or "Tamer"
end

function G:NewGame()
    local data = self:Data()
    data.undo = nil
    data.save = {
        v = D.SAVE_VERSION,
        map = Maps.START.map, x = Maps.START.x, y = Maps.START.y, face = Maps.START.face,
        party = {}, box = {}, bag = {}, money = D.START_MONEY,
        flags = {}, seen = {}, caught = {}, steps = 0, time = 0,
    }
    self:Load()
end

-- Validates the save (unknown species / maps are dropped), then enters the saved map.
function G:Load()
    self.co, self.pending = nil, nil
    self:RestoreUndo()
    local s = self:Data().save
    self.save = s
    s.v = D.SAVE_VERSION
    local function clean(list)
        local out = {}
        if type(list) == "table" then
            for _, mon in ipairs(list) do
                local ok = M.Sanitize(mon)
                if ok then out[#out + 1] = ok end
            end
        end
        return out
    end
    s.party = clean(s.party)
    s.box = clean(s.box)
    while #s.party > D.MAX_PARTY do table.insert(s.box, table.remove(s.party)) end
    if type(s.bag) ~= "table" then s.bag = {} end
    for item, n in pairs(s.bag) do
        if not D.items[item] or type(n) ~= "number" or n <= 0 then s.bag[item] = nil end
    end
    for _, k in ipairs({ "flags", "seen", "caught" }) do
        if type(s[k]) ~= "table" then s[k] = {} end
    end
    s.money = math.max(0, math.floor(tonumber(s.money) or 0))
    -- a beast to play with: one from the stable when the party is empty, the starter again when every saved beast
    -- was dropped (a species gone from the game); a party that can't fight (a save from mid-battle) is rested
    if #s.party == 0 and #s.box > 0 then table.insert(s.party, table.remove(s.box, 1)) end
    if #s.party == 0 and s.flags.starter then
        if D.species[s.flags.starter] then table.insert(s.party, M.New(s.flags.starter, 5, self.rng))
        else s.flags.starter = nil end
    end
    if #s.party > 0 and not M.FirstUsable(s.party) then
        for _, mon in ipairs(s.party) do M.Heal(mon) end
    end
    local m = G.Compile(s.map)
    if not m then
        s.map, s.x, s.y, s.face = Maps.START.map, Maps.START.x, Maps.START.y, Maps.START.face
        m = G.Compile(s.map)
    end
    s.x, s.y = G.OpenSpot(m, s.x, s.y)
    if not DIRS[s.face] then s.face = "down" end
    if type(s.respawn) == "table" and not G.Compile(s.respawn.map) then s.respawn = nil end
    self.moving, self.fade = nil, nil
    self.input.dir, self.input.held = nil, 0
    self:EnterMap(s.map, s.x, s.y, s.face, true)
    self.started = true
    self:Emit("load")
end

-- NPC name plates (drawn over the sprites): the name from the map's NPC (or its trainer), a WoW-style
-- <title> from the NPC's role, its trainer's kind, or the tables here.
local ROLE_TITLES = { inn = "Innkeeper", shop = "Trade Goods", stable = "Stable Master", gryphon = "Gryphon Master",
                      rest = "Rest", profession = "Profession Trainer", pettrainer = "Pet Trainer", arena = "Arena Master" }
local CLASS_TITLES = { rival = "Rival", hunter = "Hunter", druid = "Druid", miner = "Miner", captain = "Stormwind Guard",
                       gnoll = "Riverpaw Gnoll", defias = "Defias Brotherhood", farmer = "Farmer", goblin = "Goblin",
                       watch = "Night Watch", ogre = "Ogre", militia = "People's Militia", kurzen = "Kurzen's Expedition",
                       troll = "Troll", pirate = "Bloodsail Buccaneers", redridge = "Redridge Gnoll",
                       blackrock = "Blackrock Clan", darkiron = "Dark Iron Dwarf" }
local TRAINER_TITLES = { marine = "Blackwater Raiders", bruiser = "Blackwater Raiders", castaway = "Castaway",
                         venture1 = "Venture Company", venture2 = "Venture Company", venture3 = "Venture Company",
                         venture4 = "Venture Company", venture5 = "Venture Company", venture6 = "Venture Company",
                         ogre1 = "Splinter Fist", ogrewd = "Mosh'Ogg", ogreshaman = "Mosh'Ogg",
                         skull1 = "Skullsplitter", skull2 = "Skullsplitter", trollhunter = "Skullsplitter",
                         bloodscalp1 = "Bloodscalp", bloodscalp2 = "Bloodscalp", zanzilwd = "Zanzil's Outcasts",
                         bighunter = "Big Game Hunter", yowler = "Redridge Gnoll Chief",
                         gath = "Warlord of the Blackrock Clan", nef1 = "Lord of Blackrock", nef2 = "Lord of Blackrock",
                         thaurissan = "Emperor of the Dark Iron", senator = "Shadowforge City", warden = "Anvilrage Guard" }
local NPC_TITLES = { guard = "Stormwind Guard", farmer = "Farmer", furlbrow = "Farmer", saldean = "Farmer", sven = "Farmer",
                     aldric = "Huntmaster", gryan = "People's Militia", danuvin = "People's Militia", galiaan = "Scout",
                     abercrombie = "Hermit", watchguard = "Night Watch", dsguard = "Night Watch", ello = "Lord of Darkshire",
                     althea = "Night Watch Commander", eva = "Fortune Teller", doren = "Rebel Leader", fisher = "Fisherman",
                     wrangler = "Beast Wrangler", boatman = "Ferry to Jaguero Isle", zinkle = "Ferry to Booty Bay",
                     dockhand = "Dockhand", revilgaz = "Baron of Booty Bay", fleetmaster = "Blackwater Raiders" }
function G.NpcName(def)
    if type(def.name) == "function" then return def.name(G) end
    if def.name then return def.name end
    local t = def.trainer and D.trainers[def.trainer]
    return t and t.name or nil
end
function G.NpcTitle(def)
    if type(def.title) == "function" then return def.title(G) end
    if def.title then return def.title end
    if NPC_TITLES[def.id] then return NPC_TITLES[def.id] end
    if def.role and ROLE_TITLES[def.role] then return ROLE_TITLES[def.role] end
    if def.trainer then
        local t = D.trainers[def.trainer]
        return TRAINER_TITLES[def.trainer] or (t and CLASS_TITLES[t.class]) or nil
    end
    return nil
end

function G:Flag(name) return self.save and self.save.flags[name] end
function G:SetFlag(name, v) if v == nil then v = true end self.save.flags[name] = v end

---------------------------------------------------------------------------
-- Map state
---------------------------------------------------------------------------

function G:EnterMap(id, x, y, face, silent)
    local m = G.Compile(id)
    self.map = m
    local s = self.save
    s.map, s.x, s.y, s.face = id, x, y, face or s.face or "down"
    if type(s.visited) == "table" then s.visited[id] = true end        -- the world map (made on load: WorldMap.lua)
    self.moving = nil
    self.npcs = {}
    for _, def in ipairs(m.def.npcs or {}) do
        local hidden = self:NpcHidden(def)
        self.npcs[#self.npcs + 1] = { def = def, id = def.id, x = def.x, y = def.y, face = def.face or "down",
            homeX = def.x, homeY = def.y, hidden = hidden, wanderIn = 2 + self.rng(0, 30) / 10 }
    end
    if not silent then
        self.fade = 0.3
        if m.def.outdoor then
            local rare = #self:ActiveRaidRares(id) > 0
            local t = rare and 3.5 or 2.2
            self.banner = { text = m.def.name .. (rare and "  -  a rare roams here!" or ""), t = t, total = t }
        end
    end
    ns:Fire("AZERO_MAP", id)
    self:Emit("map", { id = id })
end

-- An NPC is gone when its map says so, or when it is a trainer who leaves once beaten (a boss, a pirate captain).
function G:NpcHidden(def)
    if def.hidden and def.hidden(self) then return true end
    local t = def.trainer and D.trainers[def.trainer]
    return (t and t.vanish and self:Flag("beat_" .. def.trainer)) and true or false
end

-- After a script: NPCs that a story flag sent away or brought (a boss who shows once his hunters are beaten)
-- change at once, not on the next visit. One that would appear on the player's tile waits for the next visit.
function G:RefreshNpcs()
    local s = self.save
    for _, n in ipairs(self.npcs or {}) do
        local hidden = self:NpcHidden(n.def)
        if hidden then
            n.hidden = true
        elseif n.hidden and not (s and n.x == s.x and n.y == s.y) then
            n.hidden = false
        end
    end
end

function G:NpcAt(x, y)
    for _, n in ipairs(self.npcs or {}) do
        if not n.hidden and ((n.x == x and n.y == y) or (n.moving and n.fromX == x and n.fromY == y)) then return n end
    end
end

function G:Blocked(x, y)
    local m = self.map
    if x < 0 or y < 0 or x >= m.w or y >= m.h then return true end
    if m.solid[m.key(x, y)] then return true end
    if self:SolidNode(x, y) then return true end
    if self:NpcAt(x, y) then return true end
    if self.save.x == x and self.save.y == y then return true end
    return false
end

-- An ore vein that is there blocks the way (herbs are walkable). Used by walking and by G:Blocked.
function G:SolidNode(x, y)
    local m = self.map
    local node = m and m.node and m.node[m.key(x, y)]
    return node ~= nil and node.kind == "ore" and ns.AzeroCraft ~= nil and ns.AzeroCraft:NodeState(m.id, node) == true
end

function G:IsFree()
    return self.started and not self.pending and not self.co and not self.moving
end

---------------------------------------------------------------------------
-- Script runner
---------------------------------------------------------------------------

-- `self.runFrom` = { x, y }: where a reload puts the player back (a step trigger: the tile before it).
function G:Run(fn, ...)
    if self.co then return false end
    local args = { ... }
    local n = select("#", ...)
    self.co = coroutine.create(function() fn(self, unpack(args, 1, n)) end)
    self:Checkpoint()
    local from, undo = self.runFrom, self:Data().undo
    self.runFrom = nil
    if from and undo then undo.save.x, undo.save.y = from[1], from[2] end
    self:Resume()
    return true
end

function G:Resume(...)
    local co = self.co
    if not co then return end
    local ok, err = coroutine.resume(co, ...)
    if not ok then
        self.co, self.pending = nil, nil
        self:Data().undo = nil
        local handler = geterrorhandler and geterrorhandler()
        if handler then handler(err) else error(err) end
        return
    end
    if coroutine.status(co) == "dead" and self.co == co then
        self.co, self.pending = nil, nil
        self.showSpecies = nil
        self:Data().undo = nil
        self:RefreshNpcs()
    end
end

-- Pauses the running script until G:Advance(value).
function G:Wait(p)
    self.pending = p
    return coroutine.yield()
end

function G:Advance(value)
    if not self.pending then return end
    self.pending = nil
    self:Resume(value)
end

function G:Fmt(text)
    text = tostring(text or "")
    text = text:gsub("{PLAYER}", self:PlayerName()):gsub("{RIVAL}", D.RIVAL_NAME)
    return text
end

function G:Say(text) return self:Wait({ kind = "text", text = self:Fmt(text) }) end

function G:YesNo(text)
    return self:Wait({ kind = "choice", text = self:Fmt(text), options = { "Yes", "No" }, cancel = 2 }) == 1
end

-- Returns the chosen index, or nil when cancelled.
function G:Choose(text, options)
    local i = self:Wait({ kind = "choice", text = self:Fmt(text), options = options, cancel = #options + 1 })
    if i and i >= 1 and i <= #options then return i end
end

function G:Sleep(secs) return self:Wait({ kind = "wait", t = secs }) end

-- The beast shown over the world (starter choice, evolution); `nxt` = the form it is about to become (the UI
-- loads it early, so the evolution animation can swap between the two).
function G:ShowSpecies(sp, shiny, nxt) self.showSpecies, self.showShiny, self.showNext = sp, shiny, nxt end

-- stockId: a shelf from D.shopStocks ("lakeshire", "thorium"); none = D.shopStock.
function G:Shop(keeper, stockId) return self:Wait({ kind = "shop", keeper = keeper, stock = stockId }) end

-- The pet trainer's lessons (the UI picks the beast and the move, then calls G:Relearn). Returns true when a
-- beast was taught something.
function G:PetTrainer() return self:Wait({ kind = "relearn" }) end

function G:HealParty()
    for _, mon in ipairs(self.save.party) do M.Heal(mon) end
    self:Sfx("heal")
end

function G:Give(item, n)
    n = n or 1
    local bag = self.save.bag
    bag[item] = (bag[item] or 0) + n
    self:Sfx("item")
    local name = D.items[item].name
    self:Say(n > 1 and string.format("{PLAYER} received %d %ss!", n, name) or string.format("{PLAYER} received a %s!", name))
end

function G:AddMon(mon, how)
    self.save.seen[mon.sp] = true
    self.save.caught[mon.sp] = true
    if mon.shiny then
        if type(self.save.shinyCaught) ~= "table" then self.save.shinyCaught = {} end
        self.save.shinyCaught[mon.sp] = true
    end
    local where = "box"
    if #self.save.party < D.MAX_PARTY then
        table.insert(self.save.party, mon)
        where = "party"
    else
        table.insert(self.save.box, mon)
    end
    self:Emit("tame", { mon = mon, how = how or "caught" })
    return where
end

function G:GiveMon(sp, lvl, silent)
    local mon = M.New(sp, lvl, self.rng)
    self:AddMon(mon, "gift")
    self:Say(string.format("{PLAYER} received %s!", D.species[sp].name))
    return mon
end

function G:ShowDexSummary()
    local seen, caught = 0, 0
    for _ in pairs(self.save.seen) do seen = seen + 1 end
    for _ in pairs(self.save.caught) do caught = caught + 1 end
    self:Say(string.format("Bestiary: %d seen, %d tamed, out of %d known beasts.", seen, caught, #D.dexOrder))
end

-- Player walks one tile under script control.
function G:PushPlayer(dir)
    self.save.face = dir
    local d = DIRS[dir]
    local nx, ny = self.save.x + d[1], self.save.y + d[2]
    if self:Blocked(nx, ny) then return end
    self:StartStep(dir, false, true)
    self:Wait({ kind = "walk" })
end

function G:StopAtGuard()
    self:Say("Marshal Dughan: Hold it! The forest is no place to wander without a beast at your side.")
    self:Say("Marshal Dughan: Huntmaster Aldric's lodge is to the east. Go see him first.")
    self:PushPlayer("down")
end

---------------------------------------------------------------------------
-- Battles
---------------------------------------------------------------------------

function G:TrainerDef(id)
    local def = D.trainers[id]
    local t = {}
    for k, v in pairs(def) do t[k] = v end
    t.name = self:Fmt(def.name)
    t.intro = def.intro and self:Fmt(def.intro)
    t.lose = def.lose and self:Fmt(def.lose)
    t.win = def.win and self:Fmt(def.win)
    return t
end

function G:TrainerTeam(id)
    local def = D.trainers[id]
    local team = {}
    if def.team == "rival" then
        team[1] = M.New(self:Flag("rivalStarter") or "murkling", 5, self.rng)
    else
        for i, e in ipairs(def.team) do team[i] = M.New(e[1], e[2], self.rng) end
    end
    return team
end

-- Runs a battle to the end; returns "win" | "lose" | "run" | "caught".
-- opts.noBlackout: a loss does not send the player back (the first rival battle).
function G:RunBattle(foes, trainerId, opts)
    local s = self.save
    if not M.FirstUsable(s.party) then              -- (callers check first; a battle needs a beast that can fight)
        self:Say("None of your beasts can fight!")
        return "none"
    end
    local b = ns.AzeroBattle.New({
        party = s.party, foes = foes, wild = trainerId == nil,
        trainer = trainerId and self:TrainerDef(trainerId), bag = s.bag, rng = self.rng,
        catchMult = self:Perk("catch"), expMult = self:Perk("exp"), startAtk = self:Perk("startAtk"),
        prizeMult = self:Perk("prize"), perk = self:PerkInfo(),
        rare = opts and opts.rare, legendary = opts and opts.legendary,
        onSeen = function(sp) s.seen[sp] = true self:Emit("seen", { sp = sp }) end,
        onCaught = function(mon) return self:AddMon(mon, "caught") end,
    })
    self.battle = b
    local result = self:Wait({ kind = "battle", battle = b }) or b.result
    self.battle = nil
    for _, mon in ipairs(s.party) do          -- volatile state ends with the battle
        if mon.status == "slp" and mon.hp <= 0 then mon.status, mon.sleep = nil, nil end
    end
    if result == "win" and b.prize then s.money = s.money + b.prize end      -- (a Rogue's Pick Pocket is in it)
    self:AfterBattlePerks(result)
    local used, standing, foeSp = {}, {}, {}
    for _, f in ipairs(foes) do foeSp[#foeSp + 1] = f.sp end
    for idx in pairs(b.used or {}) do
        if s.party[idx] then used[#used + 1] = s.party[idx].sp end
    end
    for _, mon in ipairs(s.party) do if mon.hp > 0 then standing[#standing + 1] = mon end end
    self:Emit("battle", { result = result, wild = trainerId == nil, trainer = trainerId, used = used, foes = foeSp,
                          party = s.party, lastStanding = (#standing == 1) and standing[1] or nil })
    for mon in pairs(b.leveled or {}) do self:Emit("level", { mon = mon, lvl = mon.lvl }) end
    if ns.AzeroCraft then
        if result == "win" and trainerId == nil then ns.AzeroCraft:BeastDrops(self, foes) end
        ns.AzeroCraft:AfterBattle(self)
    end
    if result == "lose" and not (opts and opts.noBlackout) then
        self:Emit("blackout")
        self:Blackout()
        return result
    end
    self:Evolutions()
    return result
end

-- Every beast still standing that has reached its evolution level evolves - not only the ones that levelled in this
-- battle, so one that fainted on the way (or levelled before its evolution existed) catches up after its next fight.
function G:Evolutions()
    for _, mon in ipairs(self.save.party) do
        if mon.hp > 0 then
            -- (one stopped with X waits until it has gained a level); a beast past several thresholds at once
            -- climbs its whole chain, one form at a time
            for _ = 1, 4 do
                local into = M.EvolutionTarget(mon)
                if not (into and (tonumber(mon.evoStop) or 0) < mon.lvl) then break end
                if not self:EvolveNow(mon, into) then break end
            end
        end
    end
end

function G:Battle(trainerId)
    local opts = trainerId == "rival1" and { noBlackout = true } or nil
    return self:RunBattle(self:TrainerTeam(trainerId), trainerId, opts)
end

-- 1 in D.SHINY_ODDS (G.shinyOdds overrides it; Illusion Dust halves it). Its own random numbers, so a shiny
-- roll never shifts the encounters and battles that follow.
function G:RollShiny()
    local odds = self.shinyOdds or D.SHINY_ODDS
    if self.ShinyBoosted and self:ShinyBoosted() then odds = odds / 2 end
    odds = math.max(1, math.floor(odds))
    return (self.shinyRng or math.random)(1, odds) == 1
end

-- The evolution scene (after a battle, or a trade). During the "evolve" wait the UI plays the animation; it ends
-- by itself after EVOLVE_TIME, and X stops it (G:Advance("cancel")): the beast then waits for its next level.
-- Returns true when it evolved.
G.EVOLVE_TIME = 4.2

function G:EvolveNow(mon, into, byItem)
    local old = M.Name(mon)
    self:ShowSpecies(mon.sp, mon.shiny, into)
    self:Sfx("evolve")
    self:Say(string.format("What? %s is evolving!", old))
    if self:Wait({ kind = "evolve", t = G.EVOLVE_TIME, mon = mon, from = mon.sp, into = into }) == "cancel" then
        -- it waits for its next level; at the top level there is none, so it asks again after its next battle.
        -- A trade evolution stopped here is kept (tradeEvo) and comes back the same way.
        -- (an item evolution stopped here just keeps the item: the level evolution is not held back)
        if not byItem then mon.evoStop = (mon.lvl >= D.MAX_LEVEL) and (mon.lvl - 1) or mon.lvl end
        if M.TradeEvolution(mon) == into then mon.tradeEvo = into end
        self:ShowSpecies(mon.sp, mon.shiny)
        self:Say(string.format("Huh? %s stopped evolving!", old))
        self:ShowSpecies(nil)
        return false
    end
    mon.evoStop, mon.tradeEvo = nil, nil
    local from = mon.sp
    M.Evolve(mon, into)
    self.save.seen[into], self.save.caught[into] = true, true
    if mon.shiny then
        if type(self.save.shinyCaught) ~= "table" then self.save.shinyCaught = {} end
        self.save.shinyCaught[into] = true
    end
    self:Emit("evolve", { mon = mon, from = from, into = into })
    self:ShowSpecies(into, mon.shiny)
    self:Say(string.format("Congratulations! Your %s evolved into %s!", old, D.species[into].name))
    self:ShowSpecies(nil)
    return true
end

-- An evolution item used from the bag on party beast `idx` (inside a script: the evolution scene plays). The
-- item is used up only when the beast evolves. Returns true when it evolved.
function G:UseEvolveItem(idx, item)
    local mon = self.save.party[idx]
    local into = mon and M.ItemEvolution(mon, item)
    if not into or (self.save.bag[item] or 0) <= 0 then
        self:Sfx("error")
        self:Say("It won't have any effect.")
        return false
    end
    if not self:EvolveNow(mon, into, true) then return false end
    local bag = self.save.bag
    bag[item] = bag[item] - 1
    if bag[item] <= 0 then bag[item] = nil end
    -- the moves the new form learns at this level (Gen III: evolving teaches them); no room = the pet trainer
    for _, id in ipairs(M.NewMovesAt(mon, mon.lvl)) do
        if M.TryLearn(mon, id) then self:Say(string.format("%s learned %s!", M.Name(mon), D.moves[id].name)) end
    end
    return true
end

-- A legendary beast (species with legendary = true), met by a map script: one scripted wild battle. Tamed, it is
-- gone for good (flag caught_<sp>); beaten or fled from, it waits there for the next visit.
-- Returns the battle's result, or "gone" when it was tamed before.
function G:LegendaryBattle(sp, level)
    if self:Flag("caught_" .. sp) then return "gone" end
    local mon = M.New(sp, level, self.rng)
    local result = self:RunBattle({ mon }, nil, { legendary = true, rare = true })
    if result == "caught" then
        self:SetFlag("caught_" .. sp)
        self:Emit("legendary", { sp = sp })
    end
    return result
end

function G:WildBattle(sp, lvl, rare)
    local mon = M.New(sp, lvl, self.rng)
    if self:RollShiny() then
        mon.shiny = true
        self:Emit("shiny", { mon = mon })
    end
    return self:RunBattle({ mon }, nil, { rare = rare or (D.species[sp] and D.species[sp].rare) })
end

function G:Blackout()
    local s = self.save
    local lost = self:Perk("keepMoney") and 0 or math.floor(s.money / 2)
    s.money = s.money - lost
    self:HealParty()
    local r = s.respawn
    if type(r) ~= "table" or not G.Compile(r.map) then r = Maps.RESPAWN end
    self:EnterMap(r.map, r.x, r.y, r.face)
    if self:Perk("keepMoney") then
        self:Say(string.format("%s: {PLAYER} kept every coin and fled back to %s...", self:PerkInfo().name,
            r.name or "the Lion's Pride Inn"))
    else
        self:Say(string.format("{PLAYER} dropped %s in the scramble and fled back to %s...", D.Money(lost),
            r.name or "the Lion's Pride Inn"))
    end
    self:Say("Your beasts have been rested. Be more careful out there!")
end

-- Where a blackout sends you: the last inn you rested at.
function G:SetRespawn(map, x, y, face, name)
    self.save.respawn = { map = map, x = x, y = y, face = face, name = name }
end

-- Deputy Rainer keeps the Westfall road closed until Hogger is beaten.
function G:HoggerGate()
    self:Say("Deputy Rainer: Hold on! Hogger's gnolls have been raiding this road. Nobody goes to Westfall until he's dealt with.")
    self:Say("Deputy Rainer: His camp is at Forest's Edge, just west of here. Bring me proof you've bested him!")
    self:PushPlayer("down")
end

-- Scout Galiaan keeps the road east to Duskwood closed until VanCleef is beaten.
function G:DuskwoodGate()
    self:Say("Scout Galiaan: The road east runs to Duskwood. Darkshire has asked Sentinel Hill for help, but we can't spare anyone.")
    self:Say("Scout Galiaan: Not while VanCleef's Brotherhood sits in the Deadmines at our backs. Break them first.")
    self:PushPlayer("left")
end

-- The Night Watch keeps the road south to Stranglethorn closed until Stitches is beaten.
function G:StranglethornGate()
    self:Say("Night Watch Guard: The road south runs into Stranglethorn Vale. Commander Ebonlocke has it closed while Stitches walks.")
    self:Say("Night Watch Guard: Put the haunts to rest and bring her the Night Watch Seal. Then the jungle's all yours.")
    self:PushPlayer("up")
end

-- Why a trainer won't fight yet (their `requires` not all beaten, or the player lacks their `needFlag`), or nil.
function G:TrainerLocked(id)
    local def = D.trainers[id]
    if not def or self:Flag("beat_" .. id) then return nil end
    local locked = def.needFlag and not self:Flag(def.needFlag)
    for _, other in ipairs(def.requires or {}) do
        if not self:Flag("beat_" .. other) then locked = true end
    end
    if locked then return def.notYet or "Not yet." end
end

-- Trainer NPC spots the player (or is talked to): walk over, talk, battle.
function G:TrainerEncounter(npc, spotted)
    local id = npc.def.trainer
    if spotted then
        npc.exclaim = 0.8
        self:Sfx("spotted")
        self:Sleep(0.8)
        local d = DIRS[npc.face]
        local path = {}
        local x, y = npc.x, npc.y
        while true do
            local nx, ny = x + d[1], y + d[2]
            if nx == self.save.x and ny == self.save.y then break end
            path[#path + 1] = npc.face
            x, y = nx, ny
            if #path > 10 then break end
        end
        if #path > 0 then
            npc.path = path
            self:Wait({ kind = "walk", npc = npc })
        end
        self.save.face = OPPOSITE[npc.face]
    end
    local def = D.trainers[id]
    self:Say(self:TrainerDef(id).name .. ": " .. self:Fmt(def.intro))
    local result = self:Battle(id)
    if result == "win" then
        self:SetFlag("beat_" .. id)
        self:Emit("beaten", { trainer = id })
        if def.vanish then                          -- a boss leaves the passage (and stays gone)
            npc.hidden = true
            self:Say(def.vanishText and self:Fmt(def.vanishText) or (self:TrainerDef(id).name .. " retreats deeper into the mine..."))
        end
        local badge = def.badge and D.badges[def.badge]
        if badge and not self:Flag("badge_" .. def.badge) then
            self:SetFlag("badge_" .. def.badge)
            self:Emit("badge", { id = def.badge })
            self:Say(string.format("{PLAYER} received %s!", badge.name))
            if badge.text then self:Say(badge.text) end
        end
        self:TrainerCache(def)
    end
end

-- def.cache = { needs = { trainer ids }, flag, items = { id = n }, text }: once every trainer in `needs` is beaten,
-- the first win that completes the set gives the items (once per save).
function G:TrainerCache(def)
    local c = def.cache
    if not c or self:Flag(c.flag) then return end
    for _, id in ipairs(c.needs or {}) do
        if not self:Flag("beat_" .. id) then return end
    end
    self:SetFlag(c.flag)
    if c.text then self:Say(self:Fmt(c.text)) end
    local ids = {}
    for item in pairs(c.items) do ids[#ids + 1] = item end
    table.sort(ids)
    for _, item in ipairs(ids) do
        if D.items[item] then self:Give(item, c.items[item]) end
    end
end

-- Rematches: a beaten trainer (not a boss who left, not the rival's first battle) fights again once a day (WoW's
-- daily reset), their beasts grown to about the player's strongest and evolved where the level allows.
function G:RematchReady(id)
    local def = D.trainers[id]
    if not def or def.vanish or def.team == "rival" or def.noRematch then return false end
    local day = ns.AzeroBounty and ns.AzeroBounty.DayKey() or 0
    return not (type(self.save.rematch) == "table" and self.save.rematch[id] == day)
end

function G:RematchTeam(id)
    local def = D.trainers[id]
    local best = 1
    for _, m in ipairs(self.save.party) do best = math.max(best, m.lvl) end
    local team, n = {}, #def.team
    for i, e in ipairs(def.team) do
        local lvl = math.min(D.MAX_LEVEL, math.max(e[2], best - 1 - (n - i)))     -- their ace just under yours
        local sp = e[1]
        for _ = 1, 3 do
            local evo = D.species[sp].evolve
            if evo and evo.level and lvl >= evo.level then sp = evo.into else break end
        end
        team[i] = M.New(sp, lvl, self.rng)
    end
    return team
end

-- Talking to a beaten trainer.
function G:TrainerAgain(npc)
    local id = npc.def.trainer
    local def = D.trainers[id]
    local name = self:TrainerDef(id).name
    if not self:RematchReady(id) then
        if def.vanish or def.team == "rival" or def.noRematch then
            self:Say(name .. ": " .. self:Fmt(def.lose))
        else
            self:Say(name .. ": That's enough for today. Tomorrow, though... I'll be ready.")
        end
        return
    end
    if not self:YesNo(name .. ": " .. self:Fmt(def.rematch or "I've been training since last time. A rematch?")) then
        self:Say(name .. ": Another time, then.")
        return
    end
    local result = self:RunBattle(self:RematchTeam(id), id)
    if result == "win" then
        if type(self.save.rematch) ~= "table" then self.save.rematch = {} end
        self.save.rematch[id] = ns.AzeroBounty and ns.AzeroBounty.DayKey() or 0
        self:Emit("rematch", { trainer = id })
    end
end

function G:BadgeCount()
    local n = 0
    for id in pairs(D.badges) do if self:Flag("badge_" .. id) then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------
-- Movement
---------------------------------------------------------------------------

function G:StartStep(dir, run, forced)
    local s = self.save
    local d = DIRS[dir]
    local dur = (run and G.RUN_TIME or G.STEP_TIME) * (self:Perk("walk") or 1)
    self.moving = { fromX = s.x, fromY = s.y, t = 0, dur = dur, forced = forced }
    s.x, s.y = s.x + d[1], s.y + d[2]
    s.face = dir
    self.stepParity = not self.stepParity
    if ns.AzeroNet then ns.AzeroNet:NoteStep(dir) end
end

-- Tries to walk toward `dir`. Returns "moved" | "turned" | "blocked" | "edge".
function G:TryStep(dir, run)
    if not self:IsFree() then return nil end
    local s = self.save
    local d = DIRS[dir]
    if not d then return nil end
    s.face = dir
    local nx, ny = s.x + d[1], s.y + d[2]
    local m = self.map
    if nx < 0 or ny < 0 or nx >= m.w or ny >= m.h then
        local side = ({ up = "north", down = "south", left = "west", right = "east" })[dir]
        local edge = m.def.edges and m.def.edges[side]
        if edge and edge.open and not edge.open(self) then      -- a road the story keeps closed for now
            self:Run(function(g) g:Say(edge.closed or "The way is closed.") end)
            return "blocked"
        end
        if edge then
            -- north / south keep x (shifted by dx); west / east keep y (shifted by dy); a tile that is a tree
            -- or a wall on the other side gives the nearest open one
            local target = G.Compile(edge.map)
            local tx, ty
            if dir == "up" or dir == "down" then
                tx, ty = nx + (edge.dx or 0), (dir == "up") and (target.h - 1) or 0
            else
                tx, ty = (dir == "left") and (target.w - 1) or 0, ny + (edge.dy or 0)
            end
            tx, ty = G.OpenSpot(target, tx, ty)
            self:EnterMap(edge.map, tx, ty, dir)
            return "edge"
        end
        if not self.bump then self:Sfx("bump") end
        self.bump = 0.2
        return "blocked"
    end
    if m.solid[m.key(nx, ny)] or self:NpcAt(nx, ny) or self:SolidNode(nx, ny) then
        if not self.bump then self:Sfx("bump") end
        self.bump = 0.2
        return "blocked"
    end
    self:StartStep(dir, run)
    return "moved"
end

-- fromX, fromY: the tile the step started on (a gate's trigger sends a reloaded player back there).
function G:OnArrive(forced, fromX, fromY)
    local s = self.save
    local m = self.map
    local k = m.key(s.x, s.y)
    s.steps = (s.steps or 0) + 1
    if forced then return end
    local wp = m.warp[k]
    if wp then
        self:Sfx("door")
        self:EnterMap(wp.map, wp.tx, wp.ty, wp.face)
        return
    end
    local tr = m.trigger[k]
    if tr and (not tr.cond or tr.cond(self)) then
        if fromX then self.runFrom = { fromX, fromY } end
        self:Run(tr.script)
        return
    end
    if self:CheckTrainers() then return end
    local coast = m.tall[k] == "coast"
    local list = self:EncounterList(m, coast)
    local wildTile = m.tall[k] or (m.def.cave and not m.solid[k])
    local rate = m.tall[k] and G.ENCOUNTER_PCT or (m.def.cave and m.def.cave.rate) or G.ENCOUNTER_PCT
    if wildTile and #list > 0 and M.FirstUsable(s.party) and self.rng(1, 100) <= rate then
        local sp, lvl, e = self:RollEncounter(list)
        if sp then self:Run(function(g) g:WildBattle(sp, lvl, e and e.rare) end) end      -- (nil: nothing out now)
    end
end

-- The weight of an encounter entry right now: its day / night weight at that time of (realm) day, doubled
-- for the warlock's type; 0 = cannot appear now.
function G:EncounterWeight(e)
    local w = e.weight or 0
    if self:IsNight() then
        if e.night then w = e.night end
    elseif e.day then
        w = e.day
    end
    local more = self:Perk("moreType")
    if more and not e.rare and D.species[e.sp] and D.species[e.sp].type == more then w = w * 2 end
    return w
end

-- The encounter table for this spot: the map's (tall or shore grass) plus any raid rare roaming here.
function G:EncounterList(m, coast)
    local base = (coast and m.def.coastEncounters or m.def.encounters) or {}
    local list = {}
    for _, e in ipairs(base) do list[#list + 1] = e end
    for _, r in ipairs(self:ActiveRaidRares(m.id, coast)) do
        list[#list + 1] = { sp = r.sp, min = r.level, max = r.level, weight = D.RAID_RARE_WEIGHT, rare = true }
    end
    return list
end

-- Returns sp, level, entry.
function G:RollEncounter(list)
    local total = 0
    for _, e in ipairs(list) do total = total + self:EncounterWeight(e) end
    if total <= 0 then return nil end
    local r = self.rng(1, total)
    for _, e in ipairs(list) do
        r = r - self:EncounterWeight(e)
        if r <= 0 then return e.sp, self.rng(e.min, e.max), e end
    end
end

-- A trainer who can see the player starts a battle. Returns true when one did.
function G:CheckTrainers()
    if not M.FirstUsable(self.save.party) then return false end
    local s = self.save
    for _, n in ipairs(self.npcs) do
        local id = n.def.trainer
        if id and not n.hidden and not self:Flag("beat_" .. id) and not self:TrainerLocked(id) then
            local d = DIRS[n.face]
            local x, y = n.x, n.y
            for _ = 1, n.def.sight or 3 do
                x, y = x + d[1], y + d[2]
                if x == s.x and y == s.y then
                    self:Run(function(g) g:TrainerEncounter(n, true) end)
                    return true
                end
                if self.map.solid[self.map.key(x, y)] or self:NpcAt(x, y) then break end
            end
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Interaction
---------------------------------------------------------------------------

function G:PressA()
    if self.pending then
        if self.pending.kind == "text" then self:Advance() end
        return
    end
    if not self:IsFree() then return end
    local s = self.save
    local m = self.map
    local d = DIRS[s.face]
    local x, y = s.x + d[1], s.y + d[2]
    local k = m.key(x, y)
    local peer = ns.AzeroNet and ns.AzeroNet:PeerAt(m.id, x, y)
    if peer and not self:NpcAt(x, y) then            -- another player (guildmate)
        if peer.status == "pvp" and ns.AzeroWatch then
            self:Run(function(g)
                local vs = peer.vs and ((Ambiguate and Ambiguate(peer.vs, "short")) or peer.vs:match("^[^-]+")) or "someone"
                if g:YesNo(string.format("%s is battling %s. Watch the battle?", peer.name, vs)) then
                    ns.AzeroWatch:Watch(g, peer)
                end
            end)
            return
        elseif peer.status then
            local what = { battle = "is in a battle", trade = "is trading", watch = "is watching a battle" }
            self:Run(function(g) g:Say(string.format("%s %s right now.", peer.name, what[peer.status] or "is busy")) end)
            return
        end
        self:Run(function(g)
            local pick = g:Choose(string.format("Challenge %s to a battle, or trade beasts?", peer.name),
                { "Battle", "Trade" })
            if pick == 1 then
                ns.AzeroPvP:Challenge(g, peer, true)
            elseif pick == 2 and ns.AzeroTrade then
                ns.AzeroTrade:Ask(g, peer)
            end
        end)
        return
    end
    local npc = self:NpcAt(x, y)
    if not npc and m.over[k] == "counter" then        -- talk across a counter
        npc = self:NpcAt(x + d[1], y + d[2])
    end
    if npc then
        npc.face = OPPOSITE[s.face]
        local id = npc.def.trainer
        local line = id and self:TrainerLocked(id)
        if line then
            self:Run(function(g) g:Say(g:TrainerDef(id).name .. ": " .. g:Fmt(line)) end)
            return
        end
        if id and not M.FirstUsable(s.party) and (not self:Flag("beat_" .. id) or self:RematchReady(id)) then
            self:Run(function(g) g:Say(g:TrainerDef(id).name .. ": Your beasts can't fight like that. Rest them at an inn, then come back.") end)
        elseif id and not self:Flag("beat_" .. id) then
            self:Run(function(g) g:TrainerEncounter(npc, false) end)
        elseif id then
            self:Run(function(g) g:TrainerAgain(npc) end)
        elseif npc.def.script then
            self:Run(npc.def.script, npc)
        end
        return
    end
    if m.sign[k] then
        local text = m.sign[k].text
        self:Run(function(g) g:Say(text) end)
        return
    end
    local node = m.node and m.node[k]
    if node and ns.AzeroCraft and ns.AzeroCraft:NodeState(m.id, node) then
        self:Run(function(g) ns.AzeroCraft:Gather(g, node) end)
        return
    end
    local chest = m.chest[k]
    if chest then
        if self:Flag("chest_" .. chest.id) then
            self:Run(function(g) g:Say("It's empty.") end)
        else
            self:Run(function(g)
                g:SetFlag("chest_" .. chest.id)
                g:Emit("chest", { id = chest.id })
                g:Give(chest.item, chest.n)
            end)
        end
        return
    end
    local obj = m.object[k]
    if obj and obj.script then
        self:Run(obj.script)
        return
    end
    -- a herb underfoot
    local here = m.node and m.node[m.key(s.x, s.y)]
    if here and here.kind == "herb" and ns.AzeroCraft and ns.AzeroCraft:NodeState(m.id, here) then
        self:Run(function(g) ns.AzeroCraft:Gather(g, here) end)
    end
end

-- What pressing A would do right now, for the on-screen hint: text, tile x, tile y (nil when nothing).
function G:InteractHint()
    if not self:IsFree() or not self.map or not ns.AzeroCraft then return nil end
    local s, m = self.save, self.map
    local d = DIRS[s.face]
    local x, y = s.x + d[1], s.y + d[2]
    local k = m.key(x, y)
    local node = m.node and m.node[k]
    if node then
        local up, res = ns.AzeroCraft:NodeState(m.id, node)
        if up then return ns.AzeroCraft:GatherHint(res), x, y end
    end
    local obj = m.object[k]
    if obj and obj.hint then return obj.hint, x, y end
    local peer = ns.AzeroNet and ns.AzeroNet:PeerAt(m.id, x, y)
    if peer and peer.status == "pvp" and not self:NpcAt(x, y) then return "Watch the battle", x, y end
    local here = m.node and m.node[m.key(s.x, s.y)]
    if here and here.kind == "herb" then
        local up, res = ns.AzeroCraft:NodeState(m.id, here)
        if up then return ns.AzeroCraft:GatherHint(res), s.x, s.y end
    end
    return nil
end

---------------------------------------------------------------------------
-- Frame update
---------------------------------------------------------------------------

function G:UpdateNpcs(dt)
    for _, n in ipairs(self.npcs or {}) do
        if n.exclaim then
            n.exclaim = n.exclaim - dt
            if n.exclaim <= 0 then n.exclaim = nil end
        end
        if n.moving then
            n.moving.t = n.moving.t + dt
            if n.moving.t >= n.moving.dur then n.moving = nil end
        end
        if not n.moving and n.path and #n.path > 0 then
            local dir = table.remove(n.path, 1)
            local d = DIRS[dir]
            n.face = dir
            n.moving = { fromX = n.x, fromY = n.y, t = 0, dur = G.STEP_TIME }
            n.fromX, n.fromY = n.x, n.y
            n.x, n.y = n.x + d[1], n.y + d[2]
        elseif not n.moving and n.path and #n.path == 0 then
            n.path = nil
            if self.pending and self.pending.kind == "walk" and self.pending.npc == n then self:Advance() end
        elseif not n.moving and n.def.wander and not n.hidden and not self.pending and not self.co then
            n.wanderIn = n.wanderIn - dt
            if n.wanderIn <= 0 then
                n.wanderIn = 1.5 + self.rng(0, 30) / 10
                local dirs = { "up", "down", "left", "right" }
                local dir = dirs[self.rng(1, 4)]
                local d = DIRS[dir]
                local nx, ny = n.x + d[1], n.y + d[2]
                n.face = dir
                if math.abs(nx - n.homeX) <= 2 and math.abs(ny - n.homeY) <= 2 and not self:Blocked(nx, ny)
                    and not self.map.warp[self.map.key(nx, ny)] and not self.map.trigger[self.map.key(nx, ny)] then
                    n.moving = { t = 0, dur = G.STEP_TIME * 1.5 }
                    n.fromX, n.fromY = n.x, n.y
                    n.x, n.y = nx, ny
                end
            end
        end
    end
end

function G:Update(dt)
    if not self.started then return end
    self.save.time = (self.save.time or 0) + dt
    if self.fade then
        self.fade = self.fade - dt
        if self.fade <= 0 then self.fade = nil end
    end
    if self.banner then
        self.banner.t = self.banner.t - dt
        if self.banner.t <= 0 then self.banner = nil end
    end
    if self.bump then
        self.bump = self.bump - dt
        if self.bump <= 0 then self.bump = nil end
    end
    self:UpdateNpcs(dt)

    local p = self.pending
    if p and (p.kind == "wait" or p.kind == "evolve") then
        p.t = p.t - dt
        if p.t <= 0 then self:Advance() end
    end

    if self.moving then
        local mv = self.moving
        mv.t = mv.t + dt
        if mv.t >= mv.dur then
            self.moving = nil
            self:OnArrive(mv.forced, mv.fromX, mv.fromY)
            if not mv.forced then self:Emit("step") end
            if self.pending and self.pending.kind == "walk" and not self.pending.npc then self:Advance() end
        end
    end

    local inp = self.input
    if inp.dir then
        inp.held = (inp.held or 0) + dt
        if self:IsFree() and not self.bump then
            if self.save.face ~= inp.dir and inp.held < G.TURN_DELAY and not self.justWalked then
                self.save.face = inp.dir
            elseif inp.held >= G.TURN_DELAY or self.justWalked or self.save.face == inp.dir then
                local r = self:TryStep(inp.dir, inp.run)
                self.justWalked = (r == "moved" or r == "edge")
            end
        end
    else
        inp.held = 0
        if self:IsFree() then self.justWalked = false end
    end
end

-- Direction press / release from the UI.
function G:SetDir(dir)
    if dir ~= self.input.dir then
        self.input.dir = dir
        self.input.held = 0
    end
end

---------------------------------------------------------------------------
-- Menus (called by the UI while free)
---------------------------------------------------------------------------

-- Uses a bag item on a party creature outside battle. Returns a message.
function G:UseItemOutside(item, idx)
    local def = D.items[item]
    local mon = self.save.party[idx]
    local bag = self.save.bag
    if not def or not mon or (bag[item] or 0) <= 0 then self:Sfx("error") return "It won't have any effect." end
    if def.use == "heal" then
        if mon.hp <= 0 or mon.hp >= M.MaxHP(mon) then self:Sfx("error") return "It won't have any effect." end
        self:Sfx("heal")
        local before = mon.hp
        mon.hp = math.min(M.MaxHP(mon), mon.hp + def.heal)
        bag[item] = bag[item] - 1
        if bag[item] <= 0 then bag[item] = nil end
        return string.format("%s's HP was restored by %d points.", M.Name(mon), mon.hp - before)
    elseif def.use == "rejuv" then
        if mon.hp <= 0 or (mon.hp >= M.MaxHP(mon) and not mon.status) then self:Sfx("error") return "It won't have any effect." end
        self:Sfx("heal")
        mon.hp = math.min(M.MaxHP(mon), mon.hp + def.heal)
        mon.status, mon.sleep = nil, nil
        bag[item] = bag[item] - 1
        if bag[item] <= 0 then bag[item] = nil end
        return string.format("%s was rejuvenated!", M.Name(mon))
    elseif def.use == "cure" then
        if mon.status ~= def.cures then self:Sfx("error") return "It won't have any effect." end
        self:Sfx("cure")
        mon.status = nil
        bag[item] = bag[item] - 1
        if bag[item] <= 0 then bag[item] = nil end
        return string.format("%s was cured!", M.Name(mon))
    end
    return "You can't use that here."
end

function G:SwapParty(i, j)
    local p = self.save.party
    if p[i] and p[j] and i ~= j then p[i], p[j] = p[j], p[i] return true end
    return false
end

-- Returns ok, message.
function G:Buy(item, qty)
    local def = D.items[item]
    qty = math.max(1, math.floor(qty or 1))
    if not def then return false, "?" end
    local cost = def.price * qty
    if self.save.money < cost then self:Sfx("error") return false, "You don't have enough money." end
    self.save.money = self.save.money - cost
    self:Sfx("buy")
    self.save.bag[item] = (self.save.bag[item] or 0) + qty
    return true, string.format("Here you go! %d %s%s.", qty, def.name, qty > 1 and "s" or "")
end

-- The pet trainer: a beast can be reminded of any move it could know by its level, from its own list or its
-- earlier form's, for a fee.
G.RELEARN_PRICE = 500

function G:RelearnableMoves(mon)
    -- its own list and every earlier form's (a Tidecaller remembers the Murkling's moves too; a Heavy War Golem
    -- both the Tempered War Golem's and the Harvest Watcher's)
    local lists = {}
    for _, sp in ipairs(M.Lineage(mon.sp)) do lists[#lists + 1] = D.species[sp].learn end
    local found, order = {}, {}
    for _, learn in ipairs(lists) do
        for _, e in ipairs(learn) do
            local lvl, id = e[1], e[2]
            if lvl <= mon.lvl and D.moves[id] and not M.Knows(mon, id) then
                if not found[id] then order[#order + 1] = id end
                found[id] = math.min(found[id] or lvl, lvl)
            end
        end
    end
    local pos = {}
    for i, id in ipairs(order) do pos[id] = i end
    table.sort(order, function(a, b)
        if found[a] ~= found[b] then return found[a] < found[b] end
        return pos[a] < pos[b]
    end)
    return order
end

-- Teaches party beast `idx` the move `id`; once it knows four moves, `forgetSlot` says which one goes.
-- Returns ok, message.
function G:Relearn(idx, id, forgetSlot)
    local mon = self.save.party[idx]
    if not mon or not D.moves[id] then return false, "?" end
    local can = false
    for _, m in ipairs(self:RelearnableMoves(mon)) do if m == id then can = true end end
    if not can then return false, string.format("%s can't learn %s.", M.Name(mon), D.moves[id].name) end
    if self.save.money < self.RELEARN_PRICE then return false, "You don't have enough money." end
    local msg
    if #mon.moves < 4 then
        M.TryLearn(mon, id)
        msg = string.format("%s learned %s!", M.Name(mon), D.moves[id].name)
    elseif forgetSlot and mon.moves[forgetSlot] then
        local old = D.moves[mon.moves[forgetSlot].id].name
        M.Replace(mon, forgetSlot, id)
        msg = string.format("1, 2 and... Poof! %s forgot %s. And... %s learned %s!", M.Name(mon), old, M.Name(mon),
            D.moves[id].name)
    else
        return false, "?"
    end
    self.save.money = self.save.money - self.RELEARN_PRICE
    self:Emit("relearn", { mon = mon, move = id })
    return true, msg
end

-- The stable (Pokemon's PC): beasts beyond the party wait here; the Stable Master at any inn swaps them.
function G:Stable() return self:Wait({ kind = "stable" }) end

-- Leave party beast `idx` in the stable. Returns ok, message.
function G:Deposit(idx)
    local party = self.save.party
    local mon = party[idx]
    if not mon then return false, "?" end
    local fighter = false
    for i, m in ipairs(party) do if i ~= idx and m.hp > 0 then fighter = true end end
    if not fighter then return false, "Keep at least one beast that can fight with you." end
    table.remove(party, idx)
    table.insert(self.save.box, mon)
    return true, string.format("%s is resting in the stable.", M.Name(mon))
end

-- Take stabled beast `idx` into the party. Returns ok, message.
function G:Withdraw(idx)
    local mon = self.save.box[idx]
    if not mon then return false, "?" end
    if #self.save.party >= D.MAX_PARTY then return false, "Your party is full. Leave a beast in the stable first." end
    table.remove(self.save.box, idx)
    table.insert(self.save.party, mon)
    return true, string.format("%s rejoined your party.", M.Name(mon))
end

-- What a shop pays for one: an item's own sell value, else half its price (0: they won't buy it).
function G:SellPrice(item)
    local def = D.items[item]
    if not def then return 0 end
    return def.sell or math.floor((def.price or 0) / 2)
end

-- Returns ok, message.
function G:Sell(item, qty)
    local def = D.items[item]
    local each = self:SellPrice(item)
    qty = math.max(1, math.floor(qty or 1))
    local have = self.save.bag[item] or 0
    if not def or each <= 0 then return false, "They won't buy that." end
    if have < qty then return false, "You don't have that many." end
    self.save.bag[item] = have - qty
    if self.save.bag[item] <= 0 then self.save.bag[item] = nil end
    self.save.money = self.save.money + each * qty
    self:Emit("sell", { item = item, n = qty, money = each * qty })
    return true, string.format("Sold %s%s for %s.", def.name, qty > 1 and (" x" .. qty) or "", D.Money(each * qty))
end

function G:CleanBag()
    for item, n in pairs(self.save.bag) do if n <= 0 then self.save.bag[item] = nil end end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function G:OnInit()
    ns:RegisterEvent("ENCOUNTER_END", function(_, encounterID, encounterName, _, _, success)
        G:OnEncounterEnd(encounterID, encounterName, success)
    end)
    ns.Games:Register(G.GAME_ID, {
        name = "Azeromon",
        desc = "Tame, train and battle the beasts of Elwynn Forest, Pokemon style. Arrow keys / WASD to move, Space to interact.",
        tagline = "Tame, train and battle the beasts of Elwynn Forest.",
        icon = "Interface\\Icons\\Ability_Hunter_BeastTaming",
        order = 20,
        create = function(parent) return ns.AzeroUI:CreatePanel(parent) end,
        status = function()
            local n = ns.AzeroNet and ns.AzeroNet:PlayingNow() or 0
            if n > 0 then return string.format("|cff5fd35f%d playing now|r", n) end
            return "|cff888888No one playing|r"
        end,
    })
end

---------------------------------------------------------------------------
-- Time of day (realm time, GetGameTime). G.clockHour overrides it (tests).
--   dawn 5-7, day 7-18, dusk 18-21, night 21-5; "night" encounters: dusk and night
---------------------------------------------------------------------------

function G:Hour()
    if self.clockHour then return self.clockHour end
    local h, m = 12, 0
    if GetGameTime then h, m = GetGameTime() end
    return (tonumber(h) or 12) + (tonumber(m) or 0) / 60
end

function G:Period()
    local h = self:Hour()
    if h >= 21 or h < 5 then return "night" end
    if h < 7 then return "dawn" end
    if h < 18 then return "day" end
    return "dusk"
end

function G:IsNight()
    local p = self:Period()
    return p == "night" or p == "dusk"
end

---------------------------------------------------------------------------
-- Class perks (D.classPerks) and class lines (D.classLines)
---------------------------------------------------------------------------

function G:ClassFile()
    if self.classOverride then return self.classOverride end
    if not UnitClass then return nil end
    local _, class = UnitClass("player")         -- (not "UnitClass and UnitClass(...)": that keeps one value)
    return class
end

-- The perk value for `key` for the player's class (nil when the class has no such perk).
function G:Perk(key)
    local p = D.classPerks[self:ClassFile() or ""]
    return p and p[key]
end

function G:PerkInfo() return D.classPerks[self:ClassFile() or ""] end

-- Says the NPC's line for the player's class, if it has one.
function G:ClassSay(npc)
    local lines = D.classLines[npc]
    local line = lines and lines[self:ClassFile() or ""]
    if line then self:Say(line) end
end

-- Druid and Paladin perks after a battle; each says so (one line) when it actually did something.
function G:AfterBattlePerks(result)
    local heal, cure = self:Perk("healAfter"), self:Perk("cureAfter")
    local healed, cured = false, {}
    for _, mon in ipairs(self.save.party) do
        if mon.hp > 0 then
            if heal and result == "win" and mon.hp < M.MaxHP(mon) then
                mon.hp = math.min(M.MaxHP(mon), mon.hp + math.max(1, math.floor(M.MaxHP(mon) * heal / 100)))
                healed = true
            end
            if cure and (mon.status == "psn" or mon.status == "brn" or mon.status == "par") then
                mon.status = nil
                cured[#cured + 1] = M.Name(mon)
            end
        end
    end
    local p = self:PerkInfo()
    if healed and p then self:Say(p.name .. ": your beasts recovered a little.") end
    if #cured > 0 and p then self:Say(string.format("%s: %s %s cured.", p.name, table.concat(cured, " and "), #cured == 1 and "is" or "are")) end
end

---------------------------------------------------------------------------
-- Raid rares (D.raidRares): a boss kill in a raid lets its creature roam an area for a while.
-- Stored account-wide (DisasterZoneDB.games.azeromon.raidRares[sp] = expiry time()), so it works whether or not the
-- game is open during the raid. Only boss kills are read: no loot or council data.
---------------------------------------------------------------------------

local encounterOf        -- boss key -> encounter ID, from DisasterZone's raid data

local function EncounterIDFor(bossKey)
    if not encounterOf then
        encounterOf = {}
        for _, raid in ipairs(ns.Data and ns.Data.Raids or {}) do
            for _, boss in ipairs(raid.bosses or {}) do
                if boss.key and boss.encounterID then encounterOf[boss.key] = boss.encounterID end
            end
        end
    end
    return encounterOf[bossKey]
end
G.EncounterIDFor = EncounterIDFor

-- realm time, so a PC clock set back doesn't keep a rare roaming
local function Now() return (GetServerTime and GetServerTime()) or (time and time()) or 0 end

function G:RaidRareStore()
    local d = self:Data()
    if type(d.raidRares) ~= "table" then d.raidRares = {} end
    return d.raidRares
end

-- Raid rares roaming `mapId` now (coast: the shore-grass ones; nil: any).
function G:ActiveRaidRares(mapId, coast)
    local out, store, now = {}, self:RaidRareStore(), Now()
    for _, r in ipairs(D.raidRares) do
        local untilT = store[r.sp]
        if untilT and untilT > now and r.map == mapId and (coast == nil or (r.coast and true or false) == coast) then
            out[#out + 1] = r
        end
    end
    return out
end

function G:OnEncounterEnd(encounterID, encounterName, success)
    if success ~= 1 and success ~= true then return end
    local inRaid = IsInRaid and IsInRaid()
    local itype
    if IsInInstance then
        local _, t = IsInInstance()
        itype = t
    end
    if not inRaid or itype ~= "raid" then return end
    for _, r in ipairs(D.raidRares) do
        if EncounterIDFor(r.boss) == encounterID then
            self:RaidRareStore()[r.sp] = Now() + (r.hours or 24) * 3600
            local where = Maps[r.map] and Maps[r.map].name or r.map
            ns:Print("Azeromon: %s has fallen! A rare %s roams %s for the next %d hours.",
                tostring(encounterName or r.boss), D.species[r.sp].name, where, r.hours or 24)
            self:Emit("raidkill", { boss = r.boss, sp = r.sp })
        end
    end
end
