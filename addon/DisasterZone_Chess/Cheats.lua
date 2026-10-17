if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Chess/Cheats.lua", ...) then return end -- DisasterZone_Chess/Cheats.lua
-- ns.ChessCheats: Medivh cheats, as the Echo of Medivh does in Karazhan's chess event, turned into rules a game of
-- chess can take. Only in games against him with "Medivh cheats" on; never in games between guild members.
--
-- The event (AzerothCore boss_chess_event.cpp, HandleCheat, every 45-100 s of a real game) picks one of three at
-- random; here he cheats after every 8-12 of his own moves (a move in the event takes about 8 s):
--   heal  the event heals his king to full. Chess has no health: the piece you took from him last comes back, on the
--         square it fell on if that is empty, else on its starting square (a pawn: none).
--   fire  Fury of Medivh (spell 39345): fire under up to 3 of your pieces. Here: the squares of up to 3 of your pieces
--         (never your king) burn; nobody may enter a burning square and a line of fire is a wall. After your next
--         2 moves the fire flares: a piece of yours still in it is lost (unless losing it would expose your king).
--   hand  Hand of Medivh (spell 39339) on 1-4 of his pieces: they deal more damage. Here: those pieces (never his king)
--         may also step one square any way, as a king does, for his next 4 moves.
--
-- Fair limits, checked on the position after the cheat: a cheat never puts your king in check, never touches a king,
-- and never leaves you without a legal move. A cheat that cannot keep them shrinks (fewer squares) or another is
-- tried; when none can, Medivh lets it go this time.
--
-- A game stores what each cheat did ({ ply, k, sq = { "e4", ... }, p = piece }), so a game replays exactly; the
-- flaring of the fire and the end of the hand follow from the position (Tick).
local _, ns = ...

local C = {}
ns.ChessCheats = C

local R = ns.ChessRules
local abs, floor, min = math.abs, math.floor, math.min

C.EVERY_MIN, C.EVERY_MAX = 8, 12      -- his own moves between two cheats
C.FIRE_TURNS = 2                      -- your moves before the fire flares
C.HAND_TURNS = 4                      -- his moves an empowered piece keeps the gift
C.FIRE_MAX, C.HAND_MAX = 3, 4         -- as the event: up to 3 of your pieces, 1-4 of his
C.KINDS = { "heal", "fire", "hand" }

-- The Echo of Medivh's own lines (creature_text 16816 group 1, sound kits) and the spells' effect models
-- (tools/spell_visuals.py: SpellVisualEffectName.ModelFileDataID; attach 19 = the feet, 34 = the chest).
C.LINES = {
    { text = "Perhaps a change is in order.", sound = 10357 },
    { text = "Time for an alternative scenario.", sound = 10358 },
    { text = "One must not become too complacent.", sound = 10359 },
}
C.FX = {
    fire = { fdid = 165599, size = 6.6 },          -- Fury of Medivh's burning ground (39345, aura, model ~13 yd wide)
    fireImpact = { fdid = 166191 },                  -- its impact
    hand = { fdid = 166672, chest = 166692 },        -- Hand of Medivh (39339, aura at the feet / head and chest)
    healA = { fdid = 166292 },                       -- the Human Cleric's Healing (37455) where the piece returns
    healH = { fdid = 166802 },                       -- the Orc Necrolyte's Shadow Mend (37456)
}

---------------------------------------------------------------------------
-- Ticking (after every move of the game)
---------------------------------------------------------------------------

-- After a move by `mover` (1 / -1) in a game where Medivh plays `medivh`: the fire counts the player's moves and flares,
-- the hand counts his. -> list of what burned ({ sq, v }: the square, the piece; maybe empty)
function C.Tick(pos, mover, medivh)
    local burned = {}
    if mover == -medivh and pos.fire then
        local flare = {}
        for sq, left in pairs(pos.fire) do
            left = left - 1
            if left <= 0 then
                flare[#flare + 1] = sq
                pos.fire[sq] = nil
            else
                pos.fire[sq] = left
            end
        end
        table.sort(flare)
        local player = -medivh
        for _, sq in ipairs(flare) do
            local v = pos.b[sq]
            if v ~= 0 and (v > 0) == (player > 0) and abs(v) ~= 6 then
                -- (not when losing it would leave your king open: Medivh would take it next)
                pos.b[sq] = 0
                if R.Attacked(pos, pos.kings[player], medivh) then
                    pos.b[sq] = v
                else
                    burned[#burned + 1] = { sq = sq, v = v }
                    if pos.hand then pos.hand[sq] = nil end
                end
            end
        end
        if not next(pos.fire) then pos.fire = nil end
    end
    if mover == medivh and pos.hand then
        for sq, left in pairs(pos.hand) do
            local v = pos.b[sq]
            if left <= 1 or v == 0 or (v > 0) ~= (medivh > 0) then pos.hand[sq] = nil else pos.hand[sq] = left - 1 end
        end
        if not next(pos.hand) then pos.hand = nil end
    end
    return burned
end

---------------------------------------------------------------------------
-- Applying a cheat
---------------------------------------------------------------------------

-- Plays a stored cheat event on pos (replays and live alike). -> true when it did something
function C.Apply(pos, ev, medivh)
    if type(ev) ~= "table" then return false end
    local sqs = {}
    for _, name in ipairs(ev.sq or {}) do
        local sq = R.ParseSquare(name)
        if sq then sqs[#sqs + 1] = sq end
    end
    if ev.k == "fire" then
        pos.fire = pos.fire or {}
        for _, sq in ipairs(sqs) do pos.fire[sq] = C.FIRE_TURNS end
    elseif ev.k == "hand" then
        pos.hand = pos.hand or {}
        for _, sq in ipairs(sqs) do pos.hand[sq] = C.HAND_TURNS end
    elseif ev.k == "heal" then
        local sq, p = sqs[1], tonumber(ev.p)
        if not sq or not p or pos.b[sq] ~= 0 then return false end
        pos.b[sq] = p * medivh
    else
        return false
    end
    return true
end

-- Do the fair limits hold for the player after a cheat? (wasCheck: the player was in check before it)
local function Fair(pos, player, wasCheck)
    if not wasCheck and R.Attacked(pos, pos.kings[player], -player) then return false end
    return R.HasMove(pos)
end

-- Where a piece of Medivh's of kind p starts (the squares, for his colour).
local function HomeSquares(p, medivh)
    local rank = medivh == 1 and 0 or 7
    local files = ({ [2] = { 1, 6 }, [3] = { 2, 5 }, [4] = { 0, 7 }, [5] = { 3 } })[p] or {}
    local out = {}
    for _, f in ipairs(files) do out[#out + 1] = R.Square(f, rank) end
    return out
end

local function Shuffle(list, rng)
    for i = #list, 2, -1 do
        local j = floor(rng() * i) + 1
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local function Names(sqs)
    local out = {}
    for i, sq in ipairs(sqs) do out[i] = R.SquareName(sq) end
    return out
end

-- Tries a cheat of kind k on a copy of pos. lost = Medivh's pieces the player took, oldest first ({ p, sq }).
-- -> the event, or nil when it cannot be fair
local function Try(k, pos, medivh, rng, lost)
    local player = -medivh
    local wasCheck = R.Attacked(pos, pos.kings[player], medivh)
    if k == "heal" then
        for i = #lost, 1, -1 do
            local l = lost[i]
            if l.p ~= 1 and l.p ~= 6 then
                local spots = { l.sq }
                for _, h in ipairs(HomeSquares(l.p, medivh)) do spots[#spots + 1] = h end
                for _, sq in ipairs(spots) do
                    if pos.b[sq] == 0 and not (pos.fire and pos.fire[sq]) then
                        local test = R.Copy(pos)
                        local ev = { k = "heal", sq = { R.SquareName(sq) }, p = l.p }
                        C.Apply(test, ev, medivh)
                        if Fair(test, player, wasCheck) then return ev end
                    end
                end
                return nil          -- (the last piece taken, and only that one: he heals what he just lost)
            end
        end
        return nil
    end
    local cands = {}
    for i = 1, 64 do
        local sq = R.SQ[i]
        local v = pos.b[sq]
        if v ~= 0 and abs(v) ~= 6 then
            if k == "fire" and (v > 0) == (player > 0) and not (pos.fire and pos.fire[sq]) then
                cands[#cands + 1] = sq
            elseif k == "hand" and (v > 0) == (medivh > 0) and not (pos.hand and pos.hand[sq]) then
                cands[#cands + 1] = sq
            end
        end
    end
    if #cands == 0 then return nil end
    Shuffle(cands, rng)
    local want = k == "fire" and min(C.FIRE_MAX, #cands) or min(floor(rng() * C.HAND_MAX) + 1, #cands)
    -- the most squares that keep it fair: drop the last pick until it holds
    local pick = {}
    for i = 1, #cands do
        if #pick >= want then break end
        pick[#pick + 1] = cands[i]
        local test = R.Copy(pos)
        C.Apply(test, { k = k, sq = Names(pick) }, medivh)
        if not Fair(test, player, wasCheck) then pick[#pick] = nil end
    end
    if #pick == 0 then return nil end
    table.sort(pick)
    return { k = k, sq = Names(pick) }
end

-- Medivh picks a cheat for pos (his move just made; the player's turn). rng: the game's random numbers. -> the event
-- ({ k, sq, p }, not yet applied), or nil when no cheat can be fair now
function C.Choose(pos, medivh, rng, lost)
    local kinds = Shuffle({ "heal", "fire", "hand" }, rng)
    for _, k in ipairs(kinds) do
        local ev = Try(k, pos, medivh, rng, lost or {})
        if ev then return ev end
    end
    return nil
end

-- How many of his moves until the next cheat.
function C.NextIn(rng)
    return C.EVERY_MIN + floor(rng() * (C.EVERY_MAX - C.EVERY_MIN + 1))
end

-- A line of his for a cheat (the event picks one of the three at random).
function C.Line(rng)
    return C.LINES[floor(rng() * #C.LINES) + 1]
end

-- One or two sentences on what a cheat does (under his words in the game's column).
function C.Describe(ev, medivhName)
    medivhName = medivhName or "Medivh"
    local sq = table.concat(ev.sq or {}, ", ")
    if ev.k == "fire" then
        return string.format("Fire under %s: move out within %d moves or burn. Nobody may enter fire.", sq,
            C.FIRE_TURNS)
    elseif ev.k == "hand" then
        return string.format("Hand of Medivh on %s: they may also step one square any way for %d moves.", sq,
            C.HAND_TURNS)
    elseif ev.k == "heal" then
        local names = { [2] = "knight", [3] = "bishop", [4] = "rook", [5] = "queen" }
        return string.format("%s mends his army: his %s returns on %s.", medivhName, names[tonumber(ev.p)] or "piece",
            ev.sq and ev.sq[1] or "?")
    end
    return ""
end
