if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Mon.lua", ...) then return end -- DisasterZone Games/Azeromon/Mon.lua
-- ns.AzeroMon: creature instances (plain tables, saved as-is) and the rules around them: Gen III stat
-- formulas, the medium-fast exp curve (level^3), learning moves on level-up and evolution.
-- mon = { sp, lvl, exp, hp, status, sleep, ivs = { 6 }, moves = { { id, pp }, ... } }
local addonName, ns = ...

local M = {}
ns.AzeroMon = M
local D = ns.AzeroData

local floor, max, min = math.floor, math.max, math.min
M.STATS = { "hp", "atk", "def", "spa", "spd", "spe" }

function M.ExpForLevel(l) return l * l * l end

function M.Species(mon) return D.species[mon.sp] end

function M.Name(mon) return mon.nick or D.species[mon.sp].name end

-- What a beast's gear and flask add to `stat` (a multiplier; see Crafting.lua).
function M.Bonus(mon, stat)
    local m = 1
    if type(mon.gear) == "table" then
        for _, slot in ipairs(D.gearSlots or {}) do        -- a fixed order: every client rounds the same way
            local g = mon.gear[slot.id] and D.items[mon.gear[slot.id]]
            if g and g.bonus and g.bonus[stat] then m = m * g.bonus[stat] end
        end
    end
    local f = mon.flask and D.items[mon.flask.id]
    if f and f.bonus and f.bonus[stat] then m = m * f.bonus[stat] end
    return m
end

function M.Stat(mon, stat)
    local s = D.species[mon.sp]
    local i
    for k, n in ipairs(M.STATS) do if n == stat then i = k end end
    local b, iv = s.base[i], (mon.ivs and mon.ivs[i]) or 0
    local core = floor((2 * b + iv) * mon.lvl / 100)
    if stat == "hp" then return floor((core + mon.lvl + 10) * M.Bonus(mon, "hp")) end
    return floor((core + 5) * M.Bonus(mon, stat))
end

function M.MaxHP(mon) return M.Stat(mon, "hp") end

-- Moves known at `lvl`: the last four learnable ones (how wild / trainer creatures get their moves).
function M.DefaultMoves(sp, lvl)
    local list = {}
    for _, e in ipairs(D.species[sp].learn) do
        if e[1] <= lvl then
            local dup
            for _, m in ipairs(list) do if m == e[2] then dup = true end end
            if not dup then list[#list + 1] = e[2] end
        end
    end
    while #list > 4 do table.remove(list, 1) end
    local out = {}
    for i, id in ipairs(list) do out[i] = { id = id, pp = D.moves[id].pp } end
    return out
end

-- rng(a, b) -> integer in [a, b] (math.random when omitted)
function M.New(sp, lvl, rng)
    rng = rng or math.random
    local ivs = {}
    for i = 1, 6 do ivs[i] = rng(0, 31) end
    local mon = { sp = sp, lvl = lvl, exp = M.ExpForLevel(lvl), ivs = ivs, moves = M.DefaultMoves(sp, lvl) }
    mon.hp = M.MaxHP(mon)
    return mon
end

function M.Heal(mon)
    mon.hp = M.MaxHP(mon)
    mon.status, mon.sleep = nil, nil
    for _, m in ipairs(mon.moves) do m.pp = D.moves[m.id].pp end
end

function M.Knows(mon, id)
    for _, m in ipairs(mon.moves) do if m.id == id then return true end end
    return false
end

-- Moves the species learns exactly at `lvl` that the creature does not know yet.
function M.NewMovesAt(mon, lvl)
    local out = {}
    for _, e in ipairs(D.species[mon.sp].learn) do
        if e[1] == lvl and not M.Knows(mon, e[2]) then out[#out + 1] = e[2] end
    end
    return out
end

-- Adds a move if there is room; returns true when learned.
function M.TryLearn(mon, id)
    if M.Knows(mon, id) or #mon.moves >= 4 then return false end
    mon.moves[#mon.moves + 1] = { id = id, pp = D.moves[id].pp }
    return true
end

function M.Replace(mon, slot, id)
    mon.moves[slot] = { id = id, pp = D.moves[id].pp }
end

-- Adds exp; returns the list of levels gained (the hp grows with the max hp, like the games).
function M.AddExp(mon, amount)
    local gained = {}
    if mon.lvl >= D.MAX_LEVEL then return gained end
    mon.exp = mon.exp + amount
    while mon.lvl < D.MAX_LEVEL and mon.exp >= M.ExpForLevel(mon.lvl + 1) do
        local before = M.MaxHP(mon)
        mon.lvl = mon.lvl + 1
        if mon.hp > 0 then mon.hp = mon.hp + (M.MaxHP(mon) - before) end
        gained[#gained + 1] = mon.lvl
    end
    if mon.lvl >= D.MAX_LEVEL then mon.exp = M.ExpForLevel(D.MAX_LEVEL) end
    return gained
end

-- Species this creature should evolve into now (or nil): by level, or a trade evolution that was stopped.
function M.EvolutionTarget(mon)
    local evo = D.species[mon.sp].evolve
    if evo and evo.level and mon.lvl >= evo.level then return evo.into end
    if evo and evo.trade and mon.tradeEvo == evo.into then return evo.into end
end

-- Species a creature evolves into when it is traded (or nil).
function M.TradeEvolution(mon)
    local evo = D.species[mon.sp].evolve
    if evo and evo.trade then return evo.into end
end

function M.Evolve(mon, into)
    local before = M.MaxHP(mon)
    mon.sp = into
    if mon.hp > 0 then mon.hp = min(M.MaxHP(mon), mon.hp + (M.MaxHP(mon) - before)) end
end

function M.Usable(mon) return mon and mon.hp > 0 end

function M.FirstUsable(party)
    for i, m in ipairs(party) do if m.hp > 0 then return i end end
end

function M.ExpProgress(mon)
    if mon.lvl >= D.MAX_LEVEL then return 1 end
    local a, b = M.ExpForLevel(mon.lvl), M.ExpForLevel(mon.lvl + 1)
    return max(0, min(1, (mon.exp - a) / (b - a)))
end

-- Every move a beast of `sp` at `lvl` can know: its own list and its earlier forms' (the pet trainer's rule).
function M.LegalMoves(sp, lvl)
    local legal, cur, guard = {}, sp, 0
    while cur and guard < 8 do
        for _, e in ipairs(D.species[cur].learn or {}) do
            if e[1] <= lvl then legal[e[2]] = true end
        end
        local prev
        for id, s in pairs(D.species) do
            if s.evolve and s.evolve.into == cur then prev = id break end
        end
        cur, guard = prev, guard + 1
    end
    return legal
end

-- Validates a saved creature (drops unknown species / moves, clamps numbers). Returns nil when unusable.
-- `foreign`: it comes from another player (a trade, a player battle): no bosses, and only moves it could know.
function M.Sanitize(mon, foreign)
    if type(mon) ~= "table" or not D.species[mon.sp] then return nil end
    if foreign and D.species[mon.sp].boss then return nil end
    mon.lvl = max(1, min(D.MAX_LEVEL, floor(tonumber(mon.lvl) or 1)))
    mon.exp = max(M.ExpForLevel(mon.lvl), tonumber(mon.exp) or 0)
    if type(mon.ivs) ~= "table" then mon.ivs = { 0, 0, 0, 0, 0, 0 } end
    local legal = foreign and M.LegalMoves(mon.sp, mon.lvl)
    local moves, known = {}, {}
    if type(mon.moves) == "table" then
        for _, m in ipairs(mon.moves) do
            if type(m) == "table" and D.moves[m.id] and #moves < 4 and not known[m.id] and (not legal or legal[m.id]) then
                known[m.id] = true
                moves[#moves + 1] = { id = m.id, pp = max(0, min(D.moves[m.id].pp, tonumber(m.pp) or 0)) }
            end
        end
    end
    if #moves == 0 then moves = M.DefaultMoves(mon.sp, mon.lvl) end
    mon.moves = moves
    mon.hp = max(0, min(M.MaxHP(mon), floor(tonumber(mon.hp) or 0)))
    if mon.status and not D.status[mon.status] then mon.status = nil end
    if mon.status == "slp" then
        mon.sleep = max(1, min(3, floor(tonumber(mon.sleep) or 1)))        -- a sleep lasts 1-3 turns
    else
        mon.sleep = nil
    end
    mon.shiny = (mon.shiny == true) or nil
    mon.evoStop = tonumber(mon.evoStop) and floor(tonumber(mon.evoStop)) or nil
    if foreign or mon.tradeEvo ~= M.TradeEvolution(mon) then mon.tradeEvo = nil end
    -- gear: { slot = item } (a single item id from before the slots goes into its slot)
    if type(mon.gear) == "string" then
        local def = D.items[mon.gear]
        mon.gear = def and def.slot and { [def.slot] = mon.gear } or nil
    end
    if type(mon.gear) == "table" then
        local gear = {}
        for slot, id in pairs(mon.gear) do
            local def = type(id) == "string" and D.items[id]
            if def and def.use == "gear" and def.slot == slot then gear[slot] = id end
        end
        mon.gear = next(gear) and gear or nil
    else
        mon.gear = nil
    end
    local f = mon.flask
    local fdef = type(f) == "table" and D.items[f.id]
    if fdef and fdef.use == "flask" and (tonumber(f.n) or 0) >= 1 then
        mon.flask = { id = f.id, n = min(99, floor(tonumber(f.n))) }
    else
        mon.flask = nil
    end
    mon.hp = max(0, min(M.MaxHP(mon), mon.hp))
    return mon
end
