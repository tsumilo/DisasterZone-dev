if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Aftermath.lua", ...) then return end -- DisasterZone Games/Azeromon/Aftermath.lua
-- ns.AzeroAftermath: places heal over real days after you win there (the "Azeroth Remembers" mockup, step 1).
--   A win the world remembers (A.WINS: a badge flag) records when it happened (save.flagAt); A.Day(flag) is the
--   number of whole days since (nil before the win). An older save that won before this existed starts its week on
--   the first load after it, so everyone sees the week play out.
--   Each map's aftermath (A.MAPS) says what changes from which day:
--     field   tiles drawn over a stretch of the map by stage (a fence first, then soil, shoots, wheat); what they
--             cover (a herb or an ore vein) can't be gathered any more, and the fence is solid
--     props   things standing (the militia's standards, the harvest bonfire), drawn live by UI.lua (Amb.Props)
--     lamps   whether the map's lamp posts are lit (UI.lua covers an unlit lamp's light)
--     mist    how thick the zone's mist is (a multiplier)
--     bell    a bell toll at dusk
--   People come and go with `when = function(G) ... end` on their map entry (Game.lua G:NpcHidden, Routine.lua);
--   lines change in their scripts through G:AfterDay(flag).
-- Everything here is personal: a guildmate's world shows their own days.
local addonName, ns = ...

local A = ns:NewModule("AzeroAftermath")
local G = ns.Azero
local Maps = ns.AzeroMaps

A.DAY = 86400
A.clock = nil                -- tests: server time
A.WINS = { badge_vancleef = true, badge_nightwatch = true }

local function Now()
    if A.clock then return A.clock end
    return (GetServerTime and GetServerTime()) or (time and time()) or 0
end

local function WonAt()
    local s = G.save
    if not s then return {} end
    if type(s.flagAt) ~= "table" then s.flagAt = {} end
    return s.flagAt
end

-- A win was just recorded (G:SetFlag): remember when.
function A.Note(flag)
    if A.WINS[flag] and G.save then
        local at = WonAt()
        if not at[flag] then at[flag] = Now() end
    end
end

-- On load: a win from before the aftermath existed starts its week now.
function A.Migrate()
    local s = G.save
    if not (s and type(s.flags) == "table") then return end
    local at = WonAt()
    for flag in pairs(A.WINS) do
        if s.flags[flag] and not at[flag] then at[flag] = Now() end
    end
end

-- Whole days since the win (0 on the day itself), or nil before it.
function A.Day(flag)
    local s = G.save
    if not (s and type(s.flags) == "table" and s.flags[flag]) then return nil end
    local t = WonAt()[flag]
    if not t then return 0 end
    return math.max(0, math.floor((Now() - t) / A.DAY))
end

function G:AfterDay(flag) return A.Day(flag) end

-- The realm clock's minute (Routine.lua's), for evening-only things.
local function Minute()
    local R = ns.AzeroRoutine
    return R and R.Now() or 720
end

---------------------------------------------------------------------------
-- The maps' aftermaths
---------------------------------------------------------------------------

local function Between(day, a, b) return day ~= nil and day >= a and (not b or day <= b) end

A.MAPS = {
    -- Westfall after VanCleef: the north field west of the road is fenced, ploughed, sown and harvested
    westfall = {
        flag = "badge_vancleef",
        field = { x = 3, y = 3, w = 7, h = 5, fence = { y = 2, x0 = 3, x1 = 9 } },
        fieldStage = function(day)
            if day >= 7 then return "wheat" elseif day >= 5 then return "shoots" elseif day >= 3 then return "soil" end
            if day >= 1 then return "fenced" end
        end,
        props = function(day, minute)
            local out = {}
            if day >= 1 then
                out[#out + 1] = { kind = "standard", x = 2, y = 2 }
                out[#out + 1] = { kind = "standard", x = 10, y = 2 }
            end
            if A.FeastNow(day, minute) then out[#out + 1] = { kind = "bonfire", x = 13, y = 9, glow = true } end
            return out
        end,
    },
    -- Darkshire after Stitches: the lamps come back on, the mist thins over three nights, the bell tolls at dusk
    darkshire = {
        flag = "badge_nightwatch",
        lamps = function(day) return day ~= nil end,
        mist = function(day)
            if not day then return 1.5 end
            return ({ [0] = 1.2, [1] = 1.0, [2] = 0.8 })[day] or 0.55
        end,
        bell = function(day) return day ~= nil end,
    },
}

-- The harvest feast: the evening of the seventh day only (19:00 to midnight).
function A.FeastNow(day, minute)
    return day == 7 and (minute or Minute()) >= 19 * 60
end
function G:HarvestFeast() return A.FeastNow(A.Day("badge_vancleef")) end

local FIELD_TILES = { soil = { "field_soil" }, shoots = { "field_crop_a", "field_crop_b" } }

-- The tiles drawn over the map now (key -> atlas tile), rebuilt when the stage changes. Wheat is the farm's own
-- wheat, edged like the fields round it.
function A.Covers(m)
    local rule = A.MAPS[m.id]
    if not (rule and rule.field) then return nil end
    local day = A.Day(rule.flag)
    local stage = day and rule.fieldStage(day) or nil
    if m.afterStage == stage and m.afterCover then return m.afterCover end
    local cover, f = {}, rule.field
    if stage then
        for x = f.fence.x0, f.fence.x1 do cover[m.key(x, f.fence.y)] = "fence" end
        for y = f.y, f.y + f.h - 1 do
            for x = f.x, f.x + f.w - 1 do
                local t
                if stage == "wheat" then
                    local top, bottom, left, right = y == f.y, y == f.y + f.h - 1, x == f.x, x == f.x + f.w - 1
                    local edge = (top and (left and "tl" or right and "tr" or "t")) or (bottom and (left and "bl" or right and "br" or "b"))
                        or (left and "l") or (right and "r") or "c"
                    t = "wtall_" .. edge
                else
                    local list = FIELD_TILES[stage]
                    if list then t = list[(x + y) % #list + 1] end
                end
                if t then cover[m.key(x, y)] = t end
            end
        end
    end
    m.afterStage, m.afterCover = stage, cover
    A.Apply(m)
    return cover
end

-- Is a tile under the field (a node there can't be gathered)?
function A.Covered(mapId, x, y)
    local m = G.map
    if not (m and m.id == mapId) then
        local rule = A.MAPS[mapId]
        if not (rule and rule.field) then return false end
        m = G.Compile(mapId)
    end
    local cover = A.Covers(m)
    return cover ~= nil and cover[m.key(x, y)] ~= nil
end

-- The fence is solid while it stands (the compiled map's solid tiles, restored when it isn't there).
function A.Apply(m)
    local rule = A.MAPS[m.id]
    if not (rule and rule.field) then return end
    m.afterSolid = m.afterSolid or {}
    local f = rule.field.fence
    for x = f.x0, f.x1 do
        local k = m.key(x, f.y)
        if m.afterSolid[k] == nil then m.afterSolid[k] = m.solid[k] or false end
        local up = m.afterCover and m.afterCover[k] == "fence"
        if up then m.solid[k] = true else m.solid[k] = m.afterSolid[k] or nil end
    end
end

-- Things standing on the map now: { kind, x, y, glow }.
function A.Props(m)
    local rule = A.MAPS[m.id]
    if not (rule and rule.props) then return {} end
    local day = A.Day(rule.flag)
    if not day then return {} end
    return rule.props(day, Minute())
end

-- Is a lamp of the map lit? nil: the aftermath says nothing (Routine.lua's lamplighter decides).
function A.LampLit(mapId)
    local rule = A.MAPS[mapId]
    if not (rule and rule.lamps) then return nil end
    return rule.lamps(A.Day(rule.flag))
end

function A.Mist(mapId)
    local rule = A.MAPS[mapId]
    if not (rule and rule.mist) then return 1 end
    return rule.mist(A.Day(rule.flag))
end

-- The bell at dusk (18:00), once a day while the player is on the map; and every few seconds the map's people
-- are checked again, so someone who comes at a time (the feast's dancers) appears while you're there.
local tolled, recheck = nil, 0
function A:Update()
    local m = G.map
    recheck = recheck + 1
    if m and A.MAPS[m.id] and recheck >= 150 and G:IsFree() then
        recheck = 0
        G:RefreshNpcs()
    end
    local rule = m and A.MAPS[m.id]
    if not (rule and rule.bell and G.started) then return end
    local minute = Minute()
    local today = math.floor(Now() / A.DAY)
    if rule.bell(A.Day(rule.flag)) and minute >= 18 * 60 and minute < 18 * 60 + 2 and tolled ~= today then
        tolled = today
        if ns.AzeroSound then ns.AzeroSound:Play("bell") end
    end
end

-- For tests
A._Reset = function() tolled, recheck = nil, 0 end
