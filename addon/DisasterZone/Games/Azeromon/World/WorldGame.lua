if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/World/WorldGame.lua", ...) then return end -- DisasterZone Games/Azeromon/World/WorldGame.lua
-- ns.AzeroWorldGame: the game on the real map (World.lua) - its people, its creatures and its quests, all from the
-- generated data (World/<Region>.lua, Species.lua, Quests.lua):
--   NPCs     stand where they stand in WoW, with their real name, <title> and greeting; what they offer comes
--            from their NPC flags (vendor -> shop, innkeeper -> rest, stable master, priest / paladin trainers
--            tend your beasts like the Abbey's healers would).
--   Mobs     every spawn is on the map at its spawn point and wanders its real radius. Walking into one (or A on
--            it) starts the battle; a hostile one (red in WoW) notices you within its aggro range and comes for
--            you. A beaten or tamed mob is gone until its real respawn time has passed (realm time).
--   Quests   the zone's real quests, texts and all: kill objectives count battles won against that creature (a
--            tamed one counts too), quest items drop from it at the database's chance or are picked up from
--            their objects; the quest log is in the start menu.
local addonName, ns = ...

local G = ns.Azero
local D = ns.AzeroData
local M = ns.AzeroMon
local Maps = ns.AzeroMaps
local W = ns.AzeroWorldData
local WS = ns.AzeroLand

local WG = {}
ns.AzeroWorldGame = WG

local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt
local DIRS, OPPOSITE = G.DIRS, G.OPPOSITE

local function Now() return (time and time()) or 0 end

---------------------------------------------------------------------------
-- Species: the real creatures become the game's species (the old hand-made ones stay loaded for the old maps,
-- but the Bestiary lists the real ones)
---------------------------------------------------------------------------

local S = D.worldSpecies or {}
local byEntry = S._byEntry or {}
WG.byEntry = byEntry
for key, sp in pairs(S) do
    if key ~= "_byEntry" then
        sp.id = key
        sp.world = true
        sp.desc = sp.desc or string.format("Level %d%s %s of the real Azeroth.", sp.lvl and sp.lvl[1] or 1,
            (sp.lvl and sp.lvl[2] and sp.lvl[2] ~= sp.lvl[1]) and ("-" .. sp.lvl[2]) or "",
            sp.untameable and "foe" or "creature")
        D.species[key] = sp
    end
end
do
    local order = {}
    for key, sp in pairs(S) do if key ~= "_byEntry" then order[#order + 1] = key end end
    table.sort(order, function(a, b) return D.species[a].num < D.species[b].num end)
    if #order > 0 then
        D.legacyDexOrder = D.dexOrder          -- (the old maps' Bestiary, for their test suites)
        D.dexOrder = order
    end
end

-- The beasts Eagan Peltskinner has caught around the Abbey (the starters): Northshire's own creatures.
WG.STARTERS = { "young_wolf", "kobold_vermin" }
WG.STARTER_LEVEL = 3

---------------------------------------------------------------------------
-- Maps: the world, its interiors, the start
---------------------------------------------------------------------------

local NAMES = { [10286] = "Northshire Abbey" }          -- (interiors whose door area name is the valley's)

Maps.LEGACY_START, Maps.LEGACY_RESPAWN = Maps.START, Maps.RESPAWN     -- (the old made-up maps, for their suites)
Maps.world = { world = true, outdoor = true, name = "Northshire Valley", music = "forest" }
Maps.START = { map = "world", x = 4127, y = 6243, face = "up" }     -- a human's real first step (playercreateinfo)
Maps.RESPAWN = { map = "world", x = 4127, y = 6243, face = "up" }

local function InteriorWarpTarget(def, x, y)
    -- the floor tile next to (x, y) to land on (not the mat / stairs itself)
    for _, d in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
        local row = def.rows[y + 1 + d[2]]
        local ch = row and row:sub(x + 1 + d[1], x + 1 + d[1])
        if ch == "f" then return x + d[1], y + d[2] end
    end
    return x, y
end

local function BuildInteriors()
    for id, def in pairs(W.interiors) do
        local uid = tonumber(id:match("^i(%d+)_"))
        local name = NAMES[uid] or def.name
        local map = { name = name, music = "tavern", rows = def.rows, warps = {}, npcs = {},
                      interior = true, uid = uid, level = def.level }
        -- what it is built of: the Abbey's stone, a mine's rock, a house's planks
        if name:find("Abbey") or name:find("Cathedral") or name:find("Keep") then
            map.floorTile, map.wallTile = "sfloor", "swall"
        elseif name:find("Mine") or name:find("Cave") then
            map.floorTile, map.wallTile, map.music = "mfloor1", "mwall", "mine"
        end
        for _, st in ipairs(def.stairs or {}) do
            local other = W.interiors[st.map]
            local tx, ty = st.tx, st.ty
            if other then tx, ty = InteriorWarpTarget(other, st.tx, st.ty) end
            map.warps[#map.warps + 1] = { x = st.x, y = st.y, map = st.map, tx = tx, ty = ty, face = "down" }
        end
        map.art = W.interiorArt and W.interiorArt[id]       -- (its floor drawn from the building's own model)
        Maps[id] = map
    end
    for _, d in pairs(W.doors) do
        local def = d.map and W.interiors[d.map]
        local map = d.map and Maps[d.map]
        if map then
            d.tx, d.ty = InteriorWarpTarget(def, d.ix, d.iy)
            map.warps[#map.warps + 1] = { x = d.ix, y = d.iy, map = "world", tx = d.ox, ty = d.oy, face = "down" }
            map.name = NAMES[map.uid] or map.name
        end
    end
end

-- A door on the world map: inside if the building has an interior, else nothing (a locked house).
function WS.DoorWarp(d)
    if not d.map or not Maps[d.map] then return nil end
    return { map = d.map, tx = d.tx or d.ix, ty = d.ty or d.iy, face = "up" }
end

---------------------------------------------------------------------------
-- Text: WoW's placeholders
---------------------------------------------------------------------------

local CLASS_MASK = { WARRIOR = 1, PALADIN = 2, HUNTER = 4, ROGUE = 8, PRIEST = 16, SHAMAN = 64, MAGE = 128,
                     WARLOCK = 256, DRUID = 1024 }

function WG.Text(g, s)
    if not s then return "" end
    local name = g:PlayerName()
    local class = (UnitClass and UnitClass("player")) or "adventurer"
    local race = (UnitRace and UnitRace("player")) or "Human"
    local female = UnitSex and UnitSex("player") == 3
    s = s:gsub("%$[Bb]", "\n"):gsub("%$[Nn]", name):gsub("%$[Cc]", class):gsub("%$[Rr]", race)
    s = s:gsub("%$[Gg]%s*([^:;]*):([^;]*);", function(m, f) return female and f or m end)
    return s
end

-- long WoW texts in boxes that fit the dialogue window (paragraph by paragraph)
function WG.SayLong(g, text, who)
    text = WG.Text(g, text)
    local first = true
    for para in (text .. "\n"):gmatch("(.-)\n") do
        para = para:gsub("^%s+", ""):gsub("%s+$", "")
        if para ~= "" then
            g:Say((first and who) and (who .. ": " .. para) or para)
            first = false
        end
    end
end

---------------------------------------------------------------------------
-- Live entities near the player
---------------------------------------------------------------------------

local live = {}              -- guid -> runtime npc (kept while the session lasts, so a mob keeps its spot)
WG.live = live
local ACTIVE_RADIUS = 26

local function SpeciesOf(e) return byEntry[e.e] end

local function MobSprite(e)
    local sp = D.species[SpeciesOf(e) or ""]
    if sp and sp.spr then return sp.spr end          -- (its own model, drawn by gen_azeromon_world.py)
    local name = (sp and sp.name or ""):lower()
    if name:find("spider") then return "spider" end
    if sp and sp.untameable then return "bald" end
    return "skel"
end

local function Tint(e)
    if e.k == "mob" then
        local sp = D.species[SpeciesOf(e) or ""]
        if sp and not sp.spr and (e.n or sp.name or ""):find("Defias") then return { 1, 0.55, 0.5 } end   -- red bandanas
        if e.h and not (sp and sp.spr) then return { 1, 0.78, 0.78 } end
        return nil
    end
    local t = (e.t or ""):lower()
    if e.n and e.n:find("Guard") then return { 0.62, 0.72, 1 } end
    if t:find("priest") or (e.n or ""):find("Brother") or (e.n or ""):find("Priestess") then return { 1, 1, 0.82 } end
    if t:find("trainer") then return { 0.85, 0.95, 0.75 } end
    if t:find("merchant") or t:find("supplies") or t:find("smith") then return { 1, 0.86, 0.66 } end
    return nil
end

local function RoleOf(e)
    local roles = {}
    for _, r in ipairs(e.roles or {}) do roles[r] = true end
    if roles.inn then return "inn" end
    if roles.stable then return "stable" end
    if roles.flight then return "gryphon" end
    if roles.vendor then return "shop" end
    if roles.classtrainer and (e.cls == 5 or e.cls == 2) then return "rest" end      -- priests / paladins heal
    return nil
end

local function MakeDef(e)
    if e.k == "npc" then
        -- (e.spr: drawn from the NPC's own model; else the old pixel people, tinted by trade)
        return { id = "g" .. e.g, ent = e, name = e.n, title = e.t, x = e.x, y = e.y, face = e.f,
                 sprite = e.spr or ((e.sex == 1) and "girl" or "bald"), tint = not e.spr and Tint(e) or nil,
                 wander = e.w and true or nil,
                 wanderR = e.w, role = RoleOf(e),
                 script = function(g, npc) WG.Talk(g, npc) end }
    end
    if e.k == "critter" then          -- a rabbit, a deer: it wanders, it is not fought, it has no plate
        return { id = "g" .. e.g, ent = e, critter = true, name = "", x = e.x, y = e.y, face = e.f,
                 sprite = e.spr or "skel", wander = e.w and true or nil, wanderR = e.w or 0, noPlate = true,
                 script = function() end }
    end
    local key = SpeciesOf(e)
    local sp = key and D.species[key]
    return { id = "g" .. e.g, ent = e, mob = true, name = sp and sp.name or "?", x = e.x, y = e.y, face = e.f,
             sprite = MobSprite(e), tint = Tint(e), wander = e.w and true or nil, wanderR = e.w or 0,
             species = key, hostile = e.h and true or nil, noPlate = not e.h }
end

local function Runtime(e, g)
    local n = live[e.g]
    if n then return n end
    local def = MakeDef(e)
    n = { def = def, id = def.id, x = def.x, y = def.y, face = def.face or "down", homeX = def.x, homeY = def.y,
          wanderIn = 1 + g.rng(0, 40) / 10 }
    live[e.g] = n
    return n
end

function WG.IsDead(g, e)
    local dead = g.save and g.save.dead
    local t = dead and dead[e.g]
    return t ~= nil and t > Now()
end

local function Refresh(g)
    local s = g.save
    local list = {}
    for _, e in ipairs(WS.EntitiesNear(s.x, s.y, ACTIVE_RADIUS)) do
        if (e.k == "npc" or e.k == "mob" or e.k == "critter") and not e.map then
            local n = Runtime(e, g)
            n.hidden = (e.k == "mob") and WG.IsDead(g, e) or nil
            list[#list + 1] = n
        end
    end
    g.npcs = list
    WG.center = { x = s.x, y = s.y }
end
WG.Refresh = Refresh

-- interior maps: their NPCs (once per map)
local interiorNpcs = {}
local function InteriorList(id)
    local list = interiorNpcs[id]
    if list then return list end
    list = {}
    for _, e in ipairs(W.ents) do
        if e.map == id and (e.k == "npc" or e.k == "mob") then list[#list + 1] = MakeDef(e) end
    end
    interiorNpcs[id] = list
    return list
end

-- called by G:EnterMap after it built the map's NPCs
function WG.OnEnterMap(g, m)
    if m.world then
        Refresh(g)
        WG.area = nil
        WG.CheckArea(g, true)
    elseif m.def.interior then
        g.npcs = {}
        for _, def in ipairs(InteriorList(m.id)) do
            g.npcs[#g.npcs + 1] = { def = def, id = def.id, x = def.x, y = def.y, face = def.face or "down",
                                    homeX = def.x, homeY = def.y, wanderIn = 2 }
        end
    end
end

-- the area banner (Northshire Valley, Northshire Abbey, Echo Ridge Mine...)
function WG.CheckArea(g, quiet)
    local s = g.save
    local name, zone, id = WS.AreaName(s.x, s.y)
    if id and id ~= WG.area then
        WG.area = id
        Maps.world.name = name
        if not quiet or not g.banner then
            g.banner = { text = name, t = 2.2, total = 2.2 }
        end
        g:Emit("area", { id = id, name = name, zone = zone })
    end
end

function WG.OnArrive(g)
    local s = g.save
    local c = WG.center
    if not c or abs(s.x - c.x) + abs(s.y - c.y) >= 8 then Refresh(g) end
    WG.CheckArea(g)
end

---------------------------------------------------------------------------
-- Mobs: wandering, noticing you, the fight, death and respawn
---------------------------------------------------------------------------

local function LeadLevel(g)
    local i = M.FirstUsable(g.save.party)
    return i and g.save.party[i].lvl or 1
end

-- WoW's aggro radius: 20 yards at an even level, a yard less per level you are above the mob, 5 yards at least
function WG.AggroTiles(g, mobLvl)
    local yd = 20 + (mobLvl - LeadLevel(g))
    yd = max(5, min(45, yd))
    return yd / WS.YARDS
end

function WG.Fight(g, n)
    local e = n.def.ent
    local key = n.def.species
    if not key or not D.species[key] then return end
    if not M.FirstUsable(g.save.party) then
        g:Say("You have no beast to fight with! Eagan Peltskinner, behind the Abbey, has a few to spare.")
        n.cool = 6
        return
    end
    local lvl = g.rng(e.lv and e.lv[1] or 1, e.lv and e.lv[2] or 1)
    local result = g:WildBattle(key, lvl)
    if result == "win" or result == "caught" then
        g.save.dead = g.save.dead or {}
        g.save.dead[e.g] = Now() + (e.r or 300)
        n.hidden = true
        n.x, n.y = n.homeX, n.homeY
        WG.Credit(g, e, result)
    else
        n.cool = 8
    end
end

-- A hostile mob that sees you comes over (like a trainer), then the fight.
local function Charge(g, n)
    n.exclaim = 0.8
    g:Sfx("spotted")
    g:Sleep(0.6)
    local s = g.save
    local path = {}
    local x, y = n.x, n.y
    for _ = 1, 14 do
        local dx, dy = s.x - x, s.y - y
        if abs(dx) + abs(dy) <= 1 then break end
        local dir
        if abs(dx) >= abs(dy) then dir = dx > 0 and "right" or "left" else dir = dy > 0 and "down" or "up" end
        local d = DIRS[dir]
        if g:Blocked(x + d[1], y + d[2]) and not (x + d[1] == s.x and y + d[2] == s.y) then
            -- try the other axis
            if abs(dx) >= abs(dy) and dy ~= 0 then dir = dy > 0 and "down" or "up"
            elseif dx ~= 0 then dir = dx > 0 and "right" or "left" end
            d = DIRS[dir]
            if g:Blocked(x + d[1], y + d[2]) then break end
        end
        path[#path + 1] = dir
        x, y = x + d[1], y + d[2]
    end
    if #path > 0 then
        n.path = path
        g:Wait({ kind = "walk", npc = n })
    end
    local dx, dy = s.x - n.x, s.y - n.y
    if abs(dx) + abs(dy) == 1 then
        n.face = (dx == 1 and "right") or (dx == -1 and "left") or (dy == 1 and "down") or "up"
        s.face = OPPOSITE[n.face]
    end
    WG.Fight(g, n)
end

local aggroTick = 0
function WG.Update(g, dt)
    local m = g.map
    if not (m and m.world) then return end
    for _, n in ipairs(g.npcs or {}) do
        if n.cool then
            n.cool = n.cool - dt
            if n.cool <= 0 then n.cool = nil end
        end
    end
    aggroTick = aggroTick + dt
    if aggroTick < 0.2 then return end
    aggroTick = 0
    -- respawns
    local t = Now()
    for _, n in ipairs(g.npcs or {}) do
        local e = n.def.ent
        if n.hidden and e and e.k == "mob" and not WG.IsDead(g, e) then n.hidden = nil end
    end
    if not g:IsFree() or not M.FirstUsable(g.save.party) then return end
    local s = g.save
    for _, n in ipairs(g.npcs or {}) do
        if n.def.hostile and not n.hidden and not n.cool and not n.moving then
            local e = n.def.ent
            local range = WG.AggroTiles(g, e.lv and e.lv[2] or 1)
            local dx, dy = s.x - n.x, s.y - n.y
            if dx * dx + dy * dy <= range * range then
                g:Run(function(gg) Charge(gg, n) end)
                return
            end
        end
    end
end

---------------------------------------------------------------------------
-- Quests
---------------------------------------------------------------------------

local Q = W.quests or {}
WG.quests = Q

local function QState(g, id)
    local qs = g.save.quests
    return qs and qs[id]
end

local function ClassOk(g, q)
    if not q.classes then return true end
    local mask = CLASS_MASK[g:ClassFile() or ""] or 0
    return bit and bit.band and bit.band(q.classes, mask) ~= 0 or (q.classes % (mask * 2) >= mask)
end

function WG.Available(g, q)
    if QState(g, q.id) then return false end
    if q.prev and q.prev > 0 then
        local p = QState(g, q.prev)
        if not (p and p.s == "done") then return false end
    elseif q.prev and q.prev < 0 then              -- (negative: the other quest must be active)
        local p = QState(g, -q.prev)
        if not p then return false end
    end
    return ClassOk(g, q)
end

function WG.Complete(g, q)
    local st = QState(g, q.id)
    if not st or st.s ~= "on" then return false end
    for _, k in ipairs(q.kill or {}) do
        if (st.k and st.k[k.entry] or 0) < k.count then return false end
    end
    for _, it in ipairs(q.items or {}) do
        if (st.i and st.i[it.id] or 0) < it.count then return false end
    end
    return true
end

-- "Kobold Vermin slain: 3/10"
function WG.Progress(g, q)
    local st = QState(g, q.id)
    local lines = {}
    for _, k in ipairs(q.kill or {}) do
        lines[#lines + 1] = string.format("%s defeated: %d/%d", k.name, min(k.count, st and st.k and st.k[k.entry] or 0), k.count)
    end
    for _, it in ipairs(q.items or {}) do
        lines[#lines + 1] = string.format("%s: %d/%d", it.name, min(it.count, st and st.i and st.i[it.id] or 0), it.count)
    end
    return lines
end

function WG.Accept(g, q)
    g.save.quests = g.save.quests or {}
    g.save.quests[q.id] = { s = "on", k = {}, i = {} }
    g:Sfx("item")
    g:Say("Quest accepted: " .. q.title)
    g:Emit("quest", { id = q.id, state = "on" })
end

function WG.TurnIn(g, q, who)
    local st = QState(g, q.id)
    if q.done then WG.SayLong(g, q.done, who) end
    st.s = "done"
    st.k, st.i = nil, nil
    local lines = { "Quest complete: " .. q.title }
    if q.money then
        local money = q.money * 10
        g.save.money = g.save.money + money
        lines[#lines + 1] = "You receive " .. D.Money(money) .. "."
    end
    -- experience for the beasts in the party: the quest's level, like WoW's quest experience
    local exp = floor((q.lvl or 1) * 30)
    local grew = {}
    for _, mon in ipairs(g.save.party) do
        if mon.hp > 0 then
            for _, lvl in ipairs(M.AddExp(mon, exp)) do
                grew[#grew + 1] = string.format("%s grew to level %d!", M.Name(mon), lvl)
                for _, id in ipairs(M.NewMovesAt(mon, lvl)) do
                    if M.TryLearn(mon, id) then grew[#grew + 1] = string.format("%s learned %s!", M.Name(mon), D.moves[id].name) end
                end
            end
        end
    end
    if #g.save.party > 0 then lines[#lines + 1] = string.format("Your beasts gain %d experience.", exp) end
    g:Sfx("levelup")
    g:Say(table.concat(lines, "\n"))
    if #grew > 0 then g:Say(table.concat(grew, "\n")) end
    if q.rewards then g:Give("potion", 1) end
    g:Emit("quest", { id = q.id, state = "done" })
    g:Evolutions()
end

-- after a won / taming battle against mob e: kill credit and quest item drops
function WG.Credit(g, e, how)
    local out = {}
    for id, st in pairs(g.save.quests or {}) do
        local q = Q[id]
        if q and st.s == "on" then
            for _, k in ipairs(q.kill or {}) do
                if k.entry == e.e and (st.k[k.entry] or 0) < k.count then
                    st.k[k.entry] = (st.k[k.entry] or 0) + 1
                    out[#out + 1] = string.format("%s defeated: %d/%d", k.name, st.k[k.entry], k.count)
                end
            end
            for _, it in ipairs(q.items or {}) do
                if (st.i[it.id] or 0) < it.count then
                    for _, src in ipairs(it.from or {}) do
                        if src[1] == e.e and g.rng(1, 100) <= src[2] then
                            st.i[it.id] = (st.i[it.id] or 0) + 1
                            out[#out + 1] = string.format("%s: %d/%d", it.name, st.i[it.id], it.count)
                            break
                        end
                    end
                end
            end
            if WG.Complete(g, q) then out[#out + 1] = q.title .. ": complete!" end
        end
    end
    if #out > 0 then g:Say(table.concat(out, "\n")) end
end

-- an object of the world (a crate of Milly's Harvest, a chest): what A on it does
local objectDefs = {}
function WS.ObjectDef(e)
    local def = objectDefs[e.g]
    if def then return def end
    if e.kind == "mail" or e.kind == "read" then return nil end
    def = { tile = (e.kind == "chest") and "chest" or "crate", ent = e,
            hint = (e.kind == "quest") and ("Take " .. e.n) or ("Open " .. e.n),
            script = function(g) WG.UseObject(g, e) end }
    objectDefs[e.g] = def
    return def
end

function WG.UseObject(g, e)
    if WG.IsDead(g, e) then g:Say("Nothing left here.") return end
    if e.kind == "chest" then
        g.save.dead = g.save.dead or {}
        g.save.dead[e.g] = Now() + 600
        g:Give(g.rng(1, 3) == 1 and "superpotion" or "potion", 1)
        return
    end
    for id, st in pairs(g.save.quests or {}) do
        local q = Q[id]
        if q and st.s == "on" then
            for _, it in ipairs(q.items or {}) do
                for _, src in ipairs(it.from or {}) do
                    if src[1] == -e.e and (st.i[it.id] or 0) < it.count then
                        st.i[it.id] = (st.i[it.id] or 0) + 1
                        g.save.dead = g.save.dead or {}
                        g.save.dead[e.g] = Now() + 120
                        g:Sfx("item")
                        local line = string.format("%s: %d/%d", it.name, st.i[it.id], it.count)
                        if WG.Complete(g, q) then line = line .. "\n" .. q.title .. ": complete!" end
                        g:Say(line)
                        return
                    end
                end
            end
        end
    end
    g:Say(e.n .. ". You have no use for it right now.")
end

-- the player's level for quests: their strongest beast
function WG.PlayerLevel(g)
    local best = 1
    for _, mon in ipairs(g.save.party or {}) do if mon.lvl > best then best = mon.lvl end end
    return best
end

-- the marker over an NPC: "?" (yellow: one to hand in; grey: one under way) or "!" (yellow: one to take; grey: one
-- you are too low for), and whether it is grey
function WG.Marker(g, e)
    if not g.save then return nil end
    local lvl = WG.PlayerLevel(g)
    local turnIn, under, offer, low
    for id, q in pairs(Q) do
        local st = QState(g, id)
        if st and st.s == "on" and q.ender == e.e then
            if WG.Complete(g, q) or (not q.kill and not q.items) then turnIn = true else under = true end
        elseif q.giver == e.e and WG.Available(g, q) then
            if (q.min or 1) <= lvl then offer = true else low = true end
        end
    end
    if e.e == 196 and not g:Flag("starter") then offer = true end        -- (Eagan has a beast for you)
    if turnIn then return "?", false end
    if offer then return "!", false end
    if under then return "?", true end
    if low then return "!", true end
    return nil
end

-- every quest in the log, for the start menu: { { title, lines, done } }
function WG.Log(g)
    local out = {}
    for id, st in pairs(g.save.quests or {}) do
        local q = Q[id]
        if q and st.s == "on" then
            local lines = WG.Progress(g, q)
            if #lines == 0 then lines = { WG.Text(g, q.goal or "") } end
            out[#out + 1] = { id = id, title = q.title, lines = lines, done = WG.Complete(g, q),
                              goal = WG.Text(g, q.goal or "") }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

---------------------------------------------------------------------------
-- Talking to people
---------------------------------------------------------------------------

local function GiveStarter(g, npc)
    local who = npc.def.name
    g:Say(who .. ": You there! Heading out among the wolves and kobolds with empty hands? Not in my valley.")
    g:Say(who .. ": I've been trapping around the Abbey. Pick one of these and it's yours - treat it well.")
    local opts = {}
    for i, sp in ipairs(WG.STARTERS) do
        local d = D.species[sp]
        opts[i] = string.format("%s (%s)", d and d.name or sp, d and D.types[d.type] and D.types[d.type].name or "?")
    end
    while true do
        local pick = g:Choose(who .. ": Which one will it be?", opts)
        if not pick then
            g:Say(who .. ": Take your time. They aren't going anywhere.")
            return
        end
        local sp = WG.STARTERS[pick]
        g:ShowSpecies(sp)
        local ok = g:YesNo(string.format("%s: The %s? Good choice?", who, D.species[sp].name))
        g:ShowSpecies(nil)
        if ok then
            g:GiveMon(sp, WG.STARTER_LEVEL, true)
            g:SetFlag("starter", sp)
            g:Say(who .. ": Here. And take these Taming Rods: wear a wild one down, then use one to tame it.")
            g:Give("net", 5)
            g:Give("potion", 2)
            g:Say(who .. ": People can't be tamed, mind - the Defias in the vineyard you'll just have to beat.")
            return
        end
    end
end

function WG.Talk(g, npc)
    local e = npc.def.ent
    local who = npc.def.name
    -- the starter (Eagan Peltskinner, outside the Abbey)
    if e.e == 196 and not g:Flag("starter") then
        GiveStarter(g, npc)
        return
    end
    -- turn-ins first, then quests in progress, then new quests
    local done, going, offer = {}, {}, {}
    for id, q in pairs(Q) do
        local st = QState(g, id)
        if st and st.s == "on" and q.ender == e.e then
            if WG.Complete(g, q) or (not q.kill and not q.items) then done[#done + 1] = q else going[#going + 1] = q end
        elseif q.giver == e.e and WG.Available(g, q) and (q.min or 1) <= WG.PlayerLevel(g) then
            offer[#offer + 1] = q
        end
    end
    table.sort(done, function(a, b) return a.id < b.id end)
    table.sort(offer, function(a, b) return a.id < b.id end)
    for _, q in ipairs(done) do
        WG.TurnIn(g, q, who)
        return
    end
    if #offer > 0 then
        local q = offer[1]
        if #offer > 1 then
            local opts = {}
            for i, o in ipairs(offer) do opts[i] = o.title end
            local pick = g:Choose(who .. ": " .. (e.say and WG.Text(g, e.say):sub(1, 80) or "What can I do for you?"), opts)
            if not pick then return end
            q = offer[pick]
        end
        WG.SayLong(g, q.text, who)
        if q.goal then g:Say(WG.Text(g, q.goal)) end
        if g:YesNo("Accept \"" .. q.title .. "\"?") then
            WG.Accept(g, q)
            -- a "go and talk to" quest whose ender is right here is done at once (none in Northshire)
        end
        return
    end
    if #going > 0 then
        local q = going[1]
        if q.ask then WG.SayLong(g, q.ask, who) else g:Say(who .. ": " .. WG.Text(g, q.goal or "")) end
        local lines = WG.Progress(g, q)
        if #lines > 0 then g:Say(table.concat(lines, "\n")) end
        return
    end
    -- what the NPC offers
    local role = npc.def.role
    if e.say then WG.SayLong(g, e.say, who) end
    if role == "shop" then
        g:Shop(who)
        g:Say(who .. ": Safe travels.")
    elseif role == "rest" or role == "inn" then
        if g:YesNo(who .. ": Your beasts look tired. Shall I tend to them?") then
            g:HealParty()
            g:SetRespawn(g.save.map, g.save.x, g.save.y, g.save.face, npc.def.name)
            g:Say(who .. ": There. They are rested, and the Light watches over them.")
        end
    elseif role == "stable" then
        g:Stable()
    elseif not e.say then
        g:Say(who .. ": " .. (npc.def.title and ("Greetings. I am a " .. npc.def.title:lower() .. ".") or "Light be with you."))
    end
end

---------------------------------------------------------------------------
-- Load
---------------------------------------------------------------------------

BuildInteriors()
