if DisasterZoneBoot and DisasterZoneBoot.Run("Core/StrategyObjects.lua", ...) then return end -- DisasterZone: the models the strategy boards can place by ID, and the encounter objects with their states.
--  * Data/ModelIndex.lua (generated): NPC ID -> creature display, object entry -> its model file and box, the creature
--    models' sizes. Read in place by binary search (fixed-width base-36 records); nothing is unpacked.
--  * Data/EncounterObjects.lua (hand-written): what an "obj:<entry>" icon is and the states a plan can put it in.
--  * Data/EncounterSpawns.lua (generated): the assets each encounter's script puts at fixed spots, in groups.
-- A creature on a board is "boss:<display>" (any client can read it); a game object is "obj:<entry>" and a creature
-- the boss' script puts in the fight "npc:<id>", each with its state in the icon's st (1 = its first state when nil).
-- Only model files listed in the index are ever given to SetModelByFileID: any other number can crash the client
-- (WoWUIBugs #67).
local _, ns = ...

local SO = {}
ns.StrategyObjects = SO

local floor, tonumber, type = math.floor, tonumber, type

local MAX_ID = 36 ^ 4 - 1                  -- the largest key the index can hold (4 base-36 digits)
local BOX_BIAS = 23328                     -- a box value is round(v * 100) + this (gen_model_index.py)

local function Index() return ns.Data and ns.Data.ModelIndex end
local function Objects() return ns.Data and ns.Data.EncounterObjects end

-- The record of a table with the largest key <= key: its piece and the offset before it; nil when there is none.
local function Seek(sec, key)
    if type(sec) ~= "table" or not sec[1] then return nil end
    local kw, w = sec.k, sec.w
    if tonumber(sec[1]:sub(1, kw), 36) > key then return nil end
    local lo, hi = 1, #sec
    while lo < hi do
        local mid = floor((lo + hi + 1) / 2)
        if tonumber(sec[mid]:sub(1, kw), 36) <= key then lo = mid else hi = mid - 1 end
    end
    local s = sec[lo]
    local a, b = 0, #s / w - 1
    while a < b do
        local m = floor((a + b + 1) / 2)
        if tonumber(s:sub(m * w + 1, m * w + kw), 36) <= key then a = m else b = m - 1 end
    end
    return s, a * w
end

local function Field(s, off, from, width)
    return tonumber(s:sub(off + from, off + from + width - 1), 36)
end

-- The record whose key is exactly key, or nil.
local function Exact(sec, key)
    key = tonumber(key)
    if not key or key < 0 or key > MAX_ID or key ~= floor(key) then return nil end
    local s, off = Seek(sec, key)
    if s and Field(s, off, 1, sec.k) == key then return s, off end
    return nil
end

---------------------------------------------------------------------------
-- Models by ID
---------------------------------------------------------------------------

-- An NPC ID -> its creature display ID and the NPC's own scale (percent); nil when the index has no model for it.
function SO.Npc(id)
    local idx = Index()
    local s, off = Exact(idx and idx.npc, id)
    if not s then return nil end
    return Field(s, off, 5, 4), Field(s, off, 9, 3)
end

-- Does this client have a creature display with this ID?
function SO.IsDisplay(display)
    display = tonumber(display)
    local idx = Index()
    if not display or display < 1 or display > MAX_ID or display ~= floor(display) or not idx then return false end
    local s, off = Seek(idx.cdisp, display)
    if not s then return false end
    return display < Field(s, off, 1, 4) + Field(s, off, 5, 3)
end

-- A creature display's CreatureModelScale (the client's actors draw every model at 1): 1 when it is not listed.
function SO.DisplayScale(display)
    local idx = Index()
    local s, off = Exact(idx and idx.cscale, display)
    return s and Field(s, off, 5, 3) / 100 or 1
end

-- An object entry -> { entry, display, size, fdid (its model file), box = { x0, y0, z0, x1, y1, z1 } (model units) };
-- nil when the index has no model for it (only checked M2 files are in it).
local objCache = {}
function SO.Object(entry)
    entry = tonumber(entry)
    if not entry then return nil end
    local o = objCache[entry]
    if o ~= nil then return o or nil end
    local idx = Index()
    local s, off = Exact(idx and idx.obj, entry)
    local d, ds, doff = nil, nil, nil
    if s then
        d = Field(s, off, 5, 4)
        ds, doff = Exact(idx.odisp, d)
    end
    if not ds then
        objCache[entry] = false
        return nil
    end
    local box = {}
    for k = 0, 5 do box[k + 1] = (Field(ds, doff, 10 + 3 * k, 3) - BOX_BIAS) / 100 end
    o = { entry = entry, display = d, size = Field(s, off, 9, 3) / 100, fdid = Field(ds, doff, 5, 5), box = box }
    objCache[entry] = o
    return o
end

---------------------------------------------------------------------------
-- Encounter objects and their states
---------------------------------------------------------------------------

-- The entry of an "obj:<entry>" icon key, else nil.
function SO.EntryOf(key)
    return type(key) == "string" and tonumber(key:match("^obj:(%d+)$")) or nil
end

-- The definition of an object entry (Data/EncounterObjects.lua), or nil.
function SO.Def(entry)
    return SO.DefOf("obj:" .. tostring(entry))
end

-- An encounter asset's icon key -> "obj", its entry ("obj:<entry>": a game object) or "npc", its NPC ID
-- ("npc:<id>": a creature the boss' script puts in the fight, drawn as its model, with states); else nil.
function SO.Parse(key)
    if type(key) ~= "string" then return nil end
    local kind, id = key:match("^(%l%l%l):(%d+)$")
    if kind == "obj" or kind == "npc" then return kind, tonumber(id) end
    return nil
end

-- The definition of an asset's icon key (Data/EncounterObjects.lua: entries for objects, npcs for creatures), or nil.
function SO.DefOf(key)
    local kind, id = SO.Parse(key)
    local data = Objects()
    local list = kind and data and data[kind == "obj" and "entries" or "npcs"]
    local name = list and list[id]
    return name and data.defs and data.defs[name] or nil
end

-- The assets the icon menu offers for an encounter: { icon key, ... } ({ } when none).
function SO.ForEncounter(bossRef)
    local data = Objects()
    return type(bossRef) == "string" and data and data.encounters and data.encounters[bossRef] or {}
end

-- The groups of assets an encounter's script puts at fixed spots (Data/EncounterSpawns.lua: { map = the floor map
-- file they are on, groups = { { n = name, e = { { i = icon key, mx, my (map units 0-1000), f, st }, ... } } } }), or nil.
function SO.Spawns(bossRef)
    local data = ns.Data and ns.Data.EncounterSpawns
    return type(bossRef) == "string" and data and data[bossRef] or nil
end

-- A short name of an object entry: its definition's, else "Object <entry>".
function SO.Name(entry)
    local def = SO.Def(entry)
    return def and def.name or ("Object " .. tostring(entry))
end

-- A short name of an asset's icon key: its definition's, else a creature's from the boss portraits
-- (Data/BossPortraits.lua), else "Object <entry>" / "NPC <id>".
function SO.KeyName(key)
    local kind, id = SO.Parse(key)
    local def = SO.DefOf(key)
    if def and def.name then return def.name end
    if kind == "npc" then
        for _, list in pairs(ns.Data and ns.Data.BossPortraits or {}) do
            for _, c in ipairs(list) do
                if c.id == id then return c.n end
            end
        end
        return "NPC " .. tostring(id)
    end
    return "Object " .. tostring(id)
end

-- A creature asset ("npc:<id>") -> its creature display and the NPC's own scale (percent), or nil.
function SO.Creature(key)
    local kind, id = SO.Parse(key)
    if kind ~= "npc" then return nil end
    return SO.Npc(id)
end

-- An icon's state: its number and its definition (nil for an asset without states or not an asset).
function SO.StateOf(e)
    local def = e and SO.DefOf(e.i)
    local states = def and def.states
    if not states or #states == 0 then return nil end
    local n = e.st or 1
    if not states[n] then n = 1 end
    return n, states[n]
end

-- The beams on a page: { { src = the asset's icon, dst = its target's icon, beam = the state's beam } }, each
-- asset in a state with a beam joined to the nearest icon of its target kind (none when the page has none).
function SO.Beams(page)
    local out = {}
    local list = page and page.e
    if not list then return out end
    for _, e in ipairs(list) do
        if e.t == "i" then
            local _, st = SO.StateOf(e)
            local beam = st and st.beam
            if beam and beam.to then
                local best, bd
                for _, t in ipairs(list) do
                    if t ~= e and t.t == "i" and t.i == beam.to then
                        local d = (t.x - e.x) ^ 2 + (t.y - e.y) ^ 2
                        if not bd or d < bd then best, bd = t, d end
                    end
                end
                if best then out[#out + 1] = { src = e, dst = best, beam = beam } end
            end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Placing a model by ID
---------------------------------------------------------------------------

-- What a typed ID (or a pasted Wowhead link: npc=, object=) of a kind ("npc", "obj", "display") places:
-- -> icon key, { ms = the NPC's size in percent when not 100, label = a known name else "NPC <id>" / "Object <id>" /
-- "Model <id>" }; nil, why when there is none.
function SO.Resolve(kind, text)
    text = type(text) == "string" and text or ""
    local npc, obj = text:match("npc=(%d+)"), text:match("object=(%d+)")
    if npc then kind, text = "npc", npc elseif obj then kind, text = "obj", obj end
    local id = tonumber(text:match("^%s*(%d+)%s*$"))
    if not id or id < 1 then return nil, "Type a number." end
    if kind == "npc" then
        local d, pct = SO.Npc(id)
        if not d then return nil, ("No creature model is known for NPC %d."):format(id) end
        local extra = { label = "NPC " .. id }
        if pct and pct ~= 100 and pct >= 25 and pct <= 400 then extra.ms = pct end
        return "boss:" .. d, extra
    elseif kind == "obj" then
        if not SO.Object(id) then return nil, ("No model is known for object %d."):format(id) end
        return "obj:" .. id, { label = SO.Name(id) }
    elseif kind == "display" then
        if not SO.IsDisplay(id) then return nil, ("This client has no creature model %d."):format(id) end
        return "boss:" .. id, { label = "Model " .. id }
    end
    return nil, "Unknown kind."
end
