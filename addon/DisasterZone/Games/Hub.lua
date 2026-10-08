if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Hub.lua", ...) then return end -- DisasterZone Games/Hub.lua
-- ns.Games: registry for the "waste your time" minigames. Each game registers itself with an id and a
-- panel factory; the hub owns the per-game SavedVariables namespace (DisasterZoneDB.games[id]), highscores and
-- the combat guard (GAMES_COMBAT fires on entering / leaving combat so games can pause or shrink).
-- Games never touch Council / Loot state: they are strictly for fun.
local addonName, ns = ...

local Games = ns:NewModule("Games")

local defs = {}     -- id -> { id, name, desc, icon, order, create }
local list = {}     -- defs sorted by order

local function SortList()
    table.sort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
end

-- def = { name = "Council Bingo", desc = "...", icon = "Interface\\Icons\\...", order = 10,
--         tagline = "...",                               (optional: the poster's one line; nil = desc)
--         create = function(parent) return frame end,   (frame may implement :OnGameShown / :OnGameHidden)
--         status = function() return text end }          (optional: the line under the name, e.g. "2 playing now";
--                                                           nil falls back to the best score)
function Games:Register(id, def)
    if type(id) ~= "string" or type(def) ~= "table" or type(def.create) ~= "function" then
        error("DisasterZone Games:Register(id, def): bad arguments", 2)
    end
    local d = defs[id]
    if not d then
        d = { id = id }
        defs[id] = d
        list[#list + 1] = d
    end
    d.name = def.name or id
    d.desc = def.desc or ""
    d.tagline = def.tagline
    d.icon = def.icon or "Interface\\Icons\\INV_Misc_Dice_01"
    d.order = tonumber(def.order) or (#list * 10)
    d.create = def.create
    d.status = def.status
    SortList()
    ns:Fire("GAMES_UPDATED")
end

function Games:Get(id) return defs[id] end

-- Returns a copy of the ordered game list.
function Games:GetList()
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end

-- Per-game saved table (created on first use).
function Games:GetData(id)
    local db = ns.db
    if not db then return {} end
    if type(db.games) ~= "table" then db.games = {} end
    local t = db.games[id]
    if type(t) ~= "table" then
        t = {}
        db.games[id] = t
    end
    return t
end

-- Records a score; returns true when it is a new personal best.
function Games:SubmitScore(id, score)
    score = tonumber(score)
    if not score then return false end
    local data = self:GetData(id)
    data.plays = (data.plays or 0) + 1
    if not data.best or score > data.best then
        data.best = score
        ns:Fire("GAMES_UPDATED")
        return true
    end
    return false
end

function Games:InCombat()
    return InCombatLockdown and InCombatLockdown() or false
end

function Games:Open(id)
    if not ns.MainFrame or not ns.MainFrame.Open then return end
    ns.MainFrame:Open("games")
    if id and ns.GamesUI and ns.GamesUI.Select then ns.GamesUI:Select(id) end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Games:OnInit()
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function() ns:Fire("GAMES_COMBAT", true) end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() ns:Fire("GAMES_COMBAT", false) end)
    ns:RegisterSlash("play", function(rest)
        rest = rest and rest:match("^%s*(%S+)") or nil
        if rest and not defs[rest] then
            ns:Print("unknown game '%s'.", rest)
            rest = nil
        end
        Games:Open(rest)
    end, "play [game] - open the minigames")
end
