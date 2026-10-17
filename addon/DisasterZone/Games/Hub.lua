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

-- Returns a copy of the ordered game list (the games that run here).
function Games:GetList()
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end

---------------------------------------------------------------------------
-- Game packs: every game, installed or not
---------------------------------------------------------------------------

-- Each game is its own addon folder, a game pack (dev/docs/GAME_PACKS.md), that members install or leave out. The
-- hub knows them all, so a game that isn't here still has a poster that says how to get it. (name, tagline, icon
-- and order as the game registers itself; art = the raid loading screen its poster shows meanwhile)
local CATALOG = {
    { id = "bingo", folder = "DisasterZone_Bingo", name = "Council Bingo", order = 10, art = "kara",
      tagline = "Squares fill in as the raid happens.", icon = "Interface\\Icons\\INV_Misc_Note_02" },
    { id = "trainer", folder = "DisasterZone_Trainer", name = "Raid Trainer", order = 15, art = "ssc",
      tagline = "Practise each boss in 3D before the pull.", icon = "Interface\\Icons\\Spell_Shadow_DeathPact" },
    { id = "azeromon", folder = "DisasterZone_Azeromon", name = "Azeromon", order = 20, art = "kara",
      tagline = "Tame and battle the beasts of Elwynn.", icon = "Interface\\Icons\\Ability_Hunter_BeastTaming" },
    { id = "chess", folder = "DisasterZone_Chess", name = "Karazhan Chess", order = 25, art = "kara",
      tagline = "Play Medivh's echo, or a guildmate.", icon = "Interface\\Icons\\INV_Misc_Ogrepinata" },
    { id = "illidan", folder = "DisasterZone_Illidan", name = "The Binding of Illidan", order = 30, art = "bt",
      tagline = "Five floors of the Black Temple, new every run.", icon = "Interface\\Icons\\Spell_Shadow_Metamorphosis" },
    { id = "holdtheline", folder = "DisasterZone_HoldTheLine", name = "Hold the Line", order = 40, art = "kara",
      tagline = "Fifteen minutes. One class. The whole Scourge.", icon = "Interface\\Icons\\Spell_Holy_InnerFire" },
}
local byId = {}
for _, c in ipairs(CATALOG) do byId[c.id] = c end
Games.CATALOG = CATALOG
function Games:Catalog(id) return byId[id] end
Games.RELEASES = "github.com/tsumilo/DisasterZone-releases"    -- where the launcher and the release zip are

local function AddOnInfo(folder)
    local get = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    if not get then return nil end
    local ok, name, _, _, _, reason = pcall(get, folder)
    if not ok then return nil end
    return name, reason
end

-- Where game id stands here: "ok" (it runs), "missing" (its folder isn't installed), "off" (switched off in the
-- AddOn list), "update" (its folder is from another release: the boot loader skipped it, Core/Boot.lua CheckPack)
-- or "error" (installed and switched on, but it didn't start).
function Games:PackState(id)
    if defs[id] then return "ok" end
    local c = byId[id]
    if not c then return "missing" end
    local boot = DisasterZoneBoot
    local st = boot and boot.PackState and boot.PackState(c.folder)
    if st and st ~= "ok" then return "update" end
    local name, reason = AddOnInfo(c.folder)
    if not name or reason == "MISSING" then return "missing" end
    if reason == "DISABLED" or (type(reason) == "string" and reason:find("^DEP_")) then return "off" end
    if reason == "INTERFACE_VERSION" then return "update" end
    return "error"
end

-- What to do about a game that doesn't run here (its PackState), as one sentence; nil when it runs.
function Games:HowToGet(id)
    local c = byId[id]
    local state = self:PackState(id)
    if state == "ok" or not c then return nil end
    if state == "off" then
        return c.name .. " is switched off. Turn it on in the AddOn list, then /reload."
    elseif state == "update" then
        return c.name .. " is from another DisasterZone release. Update it in the DisasterZone launcher, or replace its "
            .. c.folder .. " folder from the newest release zip, then /reload. Your progress is kept."
    elseif state == "error" then
        return c.name .. " is installed but didn't start. Try /reload, or reinstall it from the DisasterZone launcher."
    end
    return c.name .. " isn't installed. Add it on the Games tab of the DisasterZone launcher, or copy its " .. c.folder
        .. " folder from the release zip into Interface\\AddOns, then /reload."
end

-- Every game for the hub, in order: the ones that run here (their defs) and the catalog's others as stand-ins,
-- { id, name, tagline, desc, icon, order, art, folder, missing = PackState }.
function Games:GetShelf()
    local out = {}
    for i = 1, #list do out[#out + 1] = list[i] end
    for _, c in ipairs(CATALOG) do
        if not defs[c.id] then
            out[#out + 1] = { id = c.id, name = c.name, tagline = c.tagline, desc = c.tagline, icon = c.icon,
                              order = c.order, art = c.art, folder = c.folder, missing = self:PackState(c.id) }
        end
    end
    table.sort(out, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
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

-- A game's saved table, read only: nothing is created (the hub's posters and the login checks look without writing).
-- Without saved data: a shared empty table (never write into it).
local EMPTY = {}
function Games:PeekData(id)
    local db = ns.db
    local t = db and type(db.games) == "table" and db.games[id]
    return type(t) == "table" and t or EMPTY
end

---------------------------------------------------------------------------
-- The wire: every game message goes on the "game" class
---------------------------------------------------------------------------

local wireVersion = {}   -- id -> the version stamped on every message of that id (msg.v)

-- From now on every Games:Send(id, ...) stamps msg.v = v (nil: messages keep their own v, if any).
function Games:SetWireVersion(id, v) wireVersion[id] = v end

-- Sends msg (a table with t) on the games' class: dist "WHISPER" (to = the player's key), "GUILD", "RAID", "PARTY".
-- id: the game (or a part of one) whose wire version is stamped on msg. Returns what ns.Comm:Send returns (false
-- when it cannot go: no Comm, a whisper without a target, guild talk out of a guild).
function Games:Send(id, msg, dist, to)
    local comm = ns.Comm
    if not comm or type(msg) ~= "table" then return false end
    if dist == "WHISPER" and not to then return false end
    if dist == "GUILD" and not (IsInGuild and IsInGuild()) then return false end
    local v = wireVersion[id]
    if v ~= nil then msg.v = v end
    return comm:Send(msg, dist, to, "game")
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
    -- a game that doesn't run here: what to do about it (the hub's poster opens this), with the releases address to copy
    if ns.Popup then
        ns.Popup:Register("DISASTERZONE_GAME_PACK", {
            title = "Get the game", text = "%s", button1 = "Close", hideOnEscape = true,
            hasEditBox = true, maxLetters = 80,
            OnShow = function(d)
                d.editBox:SetText(Games.RELEASES)
                d.editBox:HighlightText()
            end,
            EditBoxOnEnterPressed = function() ns.Popup:Hide("DISASTERZONE_GAME_PACK") end,
            EditBoxOnEscapePressed = function() ns.Popup:Hide("DISASTERZONE_GAME_PACK") end,
        })
    end
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function() ns:Fire("GAMES_COMBAT", true) end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() ns:Fire("GAMES_COMBAT", false) end)
    ns:RegisterSlash("play", function(rest)
        rest = rest and rest:match("^%s*(%S+)") or nil
        if rest and not defs[rest] then
            if byId[rest] then
                ns:Print("%s", Games:HowToGet(rest))   -- (the hub opens on its poster)
            else
                ns:Print("unknown game '%s'.", rest)
                rest = nil
            end
        end
        Games:Open(rest)
    end, "play [game] - open the minigames")
end
