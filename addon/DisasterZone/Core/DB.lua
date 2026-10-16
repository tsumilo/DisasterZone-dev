if DisasterZoneBoot and DisasterZoneBoot.Run("Core/DB.lua", ...) then return end -- DisasterZone: SavedVariables (ns.DB).
-- Creates DisasterZoneDB, deep-fills defaults without overwriting saved values, runs schema
-- migrations and exposes ns.db plus dotted-path setting accessors. DB:GetEffective(path) is the read
-- every consumer uses for the group-rule settings (Addendum D §26: the loot authority's values while
-- group rules are active, else my own).
local addonName, ns = ...

local DB = ns:NewModule("DB")

local type, pairs, tostring, tonumber, next = type, pairs, tostring, tonumber, next

local SCHEMA = 2

local DEFAULTS = {
    schema = SCHEMA,
    settings = {
        minimap = { hide = false },          -- LibDBIcon storage table
        alerts = {
            councilPanel = true,   -- show drop panel (council only)
            personalToast = true,  -- "On your BiS!" toast
            sound = true,
            glow = true,           -- glow loot button for own BiS
            chat = true,           -- chat line for own BiS drops
            lootBadges = true,     -- badges on default loot frame buttons
            offspec = true,        -- Addendum H: toast / chat line for items on my off-spec list too
        },
        openOn = "home",         -- the tab the main window opens on: "home" (the dashboard) | "last" (the tab used last)
        dropPanelMode = "auto",  -- "auto" (anchor to LootFrame when it is open, else floating) | "floating"
        tooltip = { enabled = true, council = true, maxNames = 5 },
        announceChannel = "RAID",-- "RAID" | "RAID_WARNING"
        qualityThreshold = 4,    -- 4 = epic, 3 = rare
        viewPhase = nil,         -- nil = follow guild phase; else 1..5 (council views & alerts)
        groupPhase = nil,        -- Addendum E §32: the phase I set for my group while I am its loot
                                 -- authority (GS field ph); nil = use the guild phase
        roll = {
            duration = 30,       -- seconds a roll stays open (Settings: 15/20/30/45/60)
            announce = true,     -- post the roll start / winner lines in raid chat
            popup = true,        -- show the Roll / Pass popup when a roll starts
        },
        reserves = {             -- 1.4.3: loot reserves (Core/Reserves.lua and friends)
            lootReserve = true,  -- answer LootReserve players as their host / read another LootReserve host
            showWhispers = false,-- show the !sr whispers to me and my [DZ] answers in my chat frame
        },
        dungeon = {              -- Addendum B §22: dungeon mode (5-man loot sharing & rolls)
            enabled = false,     -- my switch (the party leader / council also tell the party: DM message)
            quality = 3,         -- minimum drop quality inside 5-man instances (3 = Rare, 4 = Epic)
        },
        pickerSources = {        -- Addendum F §35: item picker "Sources" (ItemDB:GetCandidates filter.sources)
            raids = true, dungeons = true, crafted = false, rep = false, badges = false, pvp = false,
        },
        atlas = { show = "all" },      -- Atlas tab: Show "all" | "class" | "spec" | "os" (off spec)
        raidlog = { keepDays = 365 },  -- Addendum I §49: whole raids older than this are dropped from the raid log
        mylog = { enabled = false, heroics = false, keepWeeks = 12 },  -- My Log (Core/MyLog.lua): opt-in, off
        -- Meters (Core/Meter.lua, Core/Threat.lua, UI/MeterPanels.lua): both opt-in, off. layout = the panels (MeterPanels).
        -- dmg / thr = the damage / threat window; show "group" | "always" | "instance"; ooc (out of combat) "fade" |
        -- "hide" | "stay"; keep = fights kept; split "all" (every combat its own fight) | "boss" (trash adds up
        -- between bosses); warn = % of my pull point (0 off); tankView "auto" | "always" | "never"; size "small" |
        -- "normal" | "large"
        meters = { dmg = false, thr = false, show = "group", ooc = "fade", keep = 25, split = "all", warn = 85,
                   sound = true, flash = true, tankView = "auto", size = "normal", rate = "fight" },
        -- Swing timer (Core/SwingTimer.lua, UI/SwingTimerHUD.lua): Retribution only. style "bar" | "lane" | "both";
        -- latencyMs 0 = auto; use.exo / use.cons = the optional fillers (off, as in WoWSims' rotation); consMana =
        -- Consecration only above this mana %; reports / pos are kept here too
        swing = { enabled = false, style = "bar", idle = false, scale = 1, latencyMs = 0,
                  use = { exo = false, cons = false }, consMana = 40,
                  sound = false, mobType = "Demon" },
        -- Shot timer (Core/ShotTimer.lua, UI/ShotTimerHUD.lua): every Hunter. style / idle / scale /
        -- latencyMs / sound as the swing timer's; use.* = the shots the planner may suggest (all on, as in WoWSims'
        -- rotation); aspects = Viper / Hawk hints, Viper below viperStart %, Hawk again from viperStop %; base =
        -- the ranged weapon's own speed learned from Steady Shot casts [itemID]; reactMs = a cast is only suggested
        -- with this long to press it (0 = WoWSims' bot); reports / pos are kept here too
        shot = { enabled = false, style = "bar", idle = false, scale = 1, latencyMs = 0, reactMs = 250,
                 use = { multi = true, arcane = true, kc = true }, aspects = true, viperStart = 5, viperStop = 25,
                 sound = false },
        -- Warrior swing timer (Core/WarriorSwing.lua, UI/WarriorSwingHUD.lua): Arms and Fury. style / idle / scale /
        -- latencyMs / sound as the swing timer's; hsLine = the Heroic Strike line in rage (0 = WoWSims': 40, two-handed
        -- Arms 80); number = rage in numbers; motion = the rage globe / bar moves (eases, sways, bubbles);
        -- ohBright = the off-hand ring brightens while Heroic Strike is queued;
        -- use.* = the presses the planner may suggest (Hamstring weaving off, as it only pays with Sword Spec / WF)
        war = { enabled = false, style = "bar", idle = false, scale = 1, latencyMs = 0, hsLine = 0, number = true,
                motion = true, ohBright = true, sound = false,
                use = { bt = true, ms = true, ww = true, slam = true, exe = true, rampage = true, shout = true,
                        brage = true, ham = false, hs = true } },
        -- Blessings (Core/Blessings.lua, UI/BlessingsBar.lua): paladins. bar "group" (party and raid) | "raid" | "off";
        -- warnMin = a blessing counts as running out this many minutes before it ends; free = anyone may assign
        -- me (Pally Power's Free Assignment); symbols = warn under this many Symbols of Kings; pets = pets count
        -- in their class; pos = the bar's place before 1.4.2 (Core/Layout.lua keeps it now; places of frames are moved in
        -- Edit layout, so there is no "locked" any more)
        bless = { bar = "group", layout = "vertical", warnMin = 5, free = false, symbols = 20, pets = true,
                  scale = 1 },
        -- Guild > Map (Core/GuildMap.lua): share "unset" (not asked yet) | "off" | "zone" | "exact"; blizzard: dots on
        -- the game's world map too
        map = { share = "unset", blizzard = true },
        strategy = {             -- Addendum K encounter helpers (Core/StrategyLive.lua)
            autoMark = true,     -- as raid leader: put the plan's raid marks on the mobs
            reminder = true,     -- near a planned boss: my jobs (and the leader's overview)
        },
        debug = false,
        windows = {},            -- [frameName] = {point, relPoint, x, y}
    },
    chars = {},        -- [nameKey] = own record (§8), one per own character
    lists = {},        -- [nameKey] = cached record of other players (council only)
    ledger = {},       -- [id] = award entry (§11)
    peers = {},        -- [nameKey] = { v="0.1.0", c=bool, lastSeen=serverTime }
    council = {},      -- Addendum E §29/§31 (Core/Guild.lua):
                       --   guild = { rev, members = {[key]=true}, phase, by, recvAt, g = guild key }
                       --   myRaidList = { rev, members = {[key]=true} } (my own raid list, "until changed")
                       --   gm = { key, g } the last Guild Master seen (offline rows may be hidden)
    raids = {},        -- [id] = raid session record (Addendum I §49, Core/RaidLog.lua)
    -- raidCurrent (no default): id of the raid session being recorded (open record)
    raidplan = {},     -- [guildKey] = { T = teams, S = weekly series, E = events, U = sign-ups } (Addendum J §54,
                       -- Core/RaidPlan.lua)
    raidplanSpec = {}, -- [charKey] = spec index last used for a raid sign-up (personal, never synced)
    mybisPreRaid = {}, -- [charKey] = true: My BiS was left on the Pre-raid list and reopens there (UI/MyBiS.lua),
                       -- never synced
    gemQuality = {},   -- [charKey] / [charKey .. ":os"] = 3 or 2: Suggest's gems are Rare / Uncommon at most (nil =
                       -- Epic; Core/Gems.lua), never synced
    strategyDraft = {},-- [charKey] = { [draftId] = unsaved work on the strategy board } (UI/StrategyBoard.lua),
                       -- never synced
    tours = {},        -- [tourId] = { seen = true, done = { [chapterKey] = true } } (UI/Tour.lua), never synced
    shopping = {},     -- [charKey] = { { id, n, d }, ... } the Atlas shopping list (Core/ShoppingList.lua), never synced
    simRuns = {},      -- [charKey] = the gear sim's last runs, their results and the seed (Sim/History.lua), never synced
    prices = {},       -- [itemID] = "cost|time" what a vendor asked (Core/Currency.lua), account wide, never synced
    blessings = {},    -- paladin blessings (Core/Blessings.lua), account wide as Pally Power's: assign / single / aura
                       -- by paladin name (Pally Power's wire names), presets; synced with Pally Power's protocol
    prof = {},         -- [guildKey] ={ [charKey] = professions and recipes } (Core/Professions.lua)
    -- mapSeen (no default): [guildKey] = { [charKey] = { m, i, n, t } } the zone a guildmate was last seen in
    -- (Core/GuildMap.lua), only learned while I share
    games = {},        -- [gameId] = per-game saved data (Games/Hub.lua): best, plays, ...
    dropHistory = {},  -- array of recent drops (§10.2), newest last, max 40, pruned > 24h
    -- groupLock (no default): { by = key, at = serverTime } while this character, as the raid's loot
    -- authority, holds the BiS list lock (Addendum F §38, Core/GroupRules.lua; restored after a /reload)
}

-- MIGRATIONS[n] upgrades a saved table from schema n-1 to n.
local MIGRATIONS = {
    -- 2 (1.5.2): class tools start off, turned on by choice. Saved data copied the old "on" default in, so every
    -- class tool is switched off once; a player turns on the ones they want in Settings > Class tools.
    [2] = function(db)
        local s = type(db.settings) == "table" and db.settings or nil
        if not s then return end
        for _, key in ipairs({ "swing", "shot", "war", "bless", "totems" }) do
            if type(s[key]) == "table" then s[key].enabled = false end
        end
    end,
}

-- Group-rule settings (Addendum D §24-26 + E §32) -> field of the GS message.
local GROUP_RULE_PATHS = {
    ["roll.duration"] = true,
    qualityThreshold = true,
    ["dungeon.enabled"] = true,
    ["dungeon.quality"] = true,
    phase = true,
}

-- Addendum E §33: DisasterZone no longer reads or writes the Guild Information text. Drops the old tag cache
-- and the guild-info safety data (idempotent, runs at every load; the notice is printed once at login by
-- Guild when the cache held a tag).
local function CleanupGuildInfo(db)
    local cfg = db.guildCfg
    if cfg ~= nil then
        local raw = type(cfg) == "table" and cfg.raw
        if type(raw) == "string" and raw:find("^CDL{") then
            DB.legacyTagNotice = true
        end
        db.guildCfg = nil
    end
    db.guildInfoSeen = nil
    db.guildInfoBackups = nil
end

---------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------

local function CopyDefault(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, sub in pairs(v) do out[k] = CopyDefault(sub) end
    return out
end

-- Adds missing keys from `defaults` into `dst`; existing values are kept. A value whose
-- default is a table but which is not a table itself (corrupt file) is replaced.
local function FillDefaults(dst, defaults, path)
    for k, def in pairs(defaults) do
        local cur = dst[k]
        if type(def) == "table" then
            if type(cur) ~= "table" then
                if cur ~= nil then
                    ns:Debug("DB: replacing invalid saved value at %s%s", path, tostring(k))
                end
                cur = {}
                dst[k] = cur
            end
            FillDefaults(cur, def, path .. tostring(k) .. ".")
        elseif cur == nil then
            dst[k] = def
        end
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function DB:OnInit()
    if type(DisasterZoneDB) ~= "table" then
        DisasterZoneDB = {}
    end
    local db = DisasterZoneDB
    -- Publish first so later modules always find ns.db even if something below fails.
    ns.db = db

    local fresh = db.schema == nil and next(db) == nil
    local from = tonumber(db.schema) or (fresh and SCHEMA or 0)

    FillDefaults(db, DEFAULTS, "")

    if from > SCHEMA then
        -- Saved by a newer DisasterZone: keep the data untouched, just warn.
        ns:Print("your saved data comes from a newer DisasterZone version; please update the addon.")
        db.schema = from
    else
        for version = from + 1, SCHEMA do
            local migrate = MIGRATIONS[version]
            if migrate then
                migrate(db)
                ns:Debug("DB: migrated saved data to schema %d", version)
            end
        end
        db.schema = SCHEMA
    end
    CleanupGuildInfo(db)
end

---------------------------------------------------------------------------
-- Settings access
---------------------------------------------------------------------------

-- A dotted path's parts, split once per path and kept (read-only: callers never change them). Settings are read
-- every frame in places (the meters' OnUpdate), and a new table per read was steady garbage. The paths are a fixed
-- set, but the cache starts over past 512 so made-up paths cannot grow it.
local splitCache, splitCount = {}, 0
local function SplitPath(path)
    local parts = splitCache[path]
    if parts then return parts end
    parts = {}
    for part in tostring(path):gmatch("[^%.]+") do
        parts[#parts + 1] = part
    end
    if splitCount >= 512 then splitCache, splitCount = {}, 0 end
    splitCache[path], splitCount = parts, splitCount + 1
    return parts
end

local function SettingsRoot()
    local db = ns.db
    if db and type(db.settings) == "table" then return db.settings end
    return nil
end

local function Lookup(root, parts)
    local node = root
    for i = 1, #parts do
        if type(node) ~= "table" then return nil end
        node = node[parts[i]]
    end
    return node
end

-- Default value for a dotted settings path (a copy for tables).
function DB:GetDefault(path)
    if path == nil or path == "" then return CopyDefault(DEFAULTS.settings) end
    return CopyDefault(Lookup(DEFAULTS.settings, SplitPath(path)))
end

-- Dotted path under settings, e.g. "alerts.sound". Falls back to the default before
-- SavedVariables are loaded. nil / "" returns the whole settings table.
function DB:GetSetting(path)
    local root = SettingsRoot()
    if path == nil or path == "" then
        return root or DEFAULTS.settings
    end
    local parts = SplitPath(path)
    if not root then
        return Lookup(DEFAULTS.settings, parts)
    end
    return Lookup(root, parts)
end

-- Sets a dotted settings path (creating intermediate tables) and fires SETTINGS_CHANGED(path)
-- when the value changed. Returns true if it changed.
function DB:SetSetting(path, value)
    local root = SettingsRoot()
    if not root or path == nil or path == "" then return false end
    local parts = SplitPath(path)
    local node = root
    for i = 1, #parts - 1 do
        local key = parts[i]
        if type(node[key]) ~= "table" then
            node[key] = {}
        end
        node = node[key]
    end
    local last = parts[#parts]
    if node[last] == value and type(value) ~= "table" then
        return false
    end
    node[last] = value
    ns:Fire("SETTINGS_CHANGED", path)
    return true
end

-- True for the dotted paths the group's loot authority controls (Addendum D §24 + E §32).
function DB:IsGroupRulePath(path)
    return GROUP_RULE_PATHS[path] == true
end

-- Effective value of a setting (Addendum D §26). For the group-rule paths ("roll.duration",
-- "qualityThreshold", "dungeon.enabled", "dungeon.quality", "phase") this is the group value while rules
-- from the loot authority are active; otherwise (and for every other path) it is GetSetting(path).
-- "phase" has no personal setting: the authority's phase for the group (GS ph, or my "groupPhase" while
-- I am the authority), else the guild council phase, else 1.
function DB:GetEffective(path)
    if GROUP_RULE_PATHS[path] then
        local GR = ns.GroupRules
        if path == "phase" then
            local p = GR and GR.GetRulePhase and GR:GetRulePhase()
            if p then return p end
            local Guild = ns.Guild
            p = Guild and Guild.GetCouncilPhase and tonumber(Guild:GetCouncilPhase())
            return p or 1
        end
        if GR and GR.GetRemoteValue then
            local v = GR:GetRemoteValue(path)
            if v ~= nil then return v end
        end
    end
    return DB:GetSetting(path)
end

---------------------------------------------------------------------------
-- Per-guild saved tables
---------------------------------------------------------------------------

-- This guild's saved table for `key`: ns.db[key][guild key] (e.g. DB:GuildBucket("events", true) is
-- db.events["Guild Name-Realm"]). create: make db[key] and the guild's table when missing (or not tables); without
-- it a missing one gives nil and nothing is written. nil (even with create) before the saved variables are loaded or
-- while the guild key is unknown (not in a guild, or the guild name not yet known after a login). guildKey
-- (optional) names another bucket than the current guild's. Returns the table and the guild key it belongs to.
function DB:GuildBucket(key, create, guildKey)
    local db = ns.db
    if type(db) ~= "table" or key == nil then return nil end
    local g = guildKey
    if g == nil then
        local Guild = ns.Guild
        g = Guild and Guild.GetGuildKey and Guild:GetGuildKey() or nil
    end
    if type(g) ~= "string" or g == "" then return nil end
    local root = db[key]
    if type(root) ~= "table" then
        if not create then return nil end
        root = {}
        db[key] = root
    end
    local b = root[g]
    if type(b) ~= "table" then
        if not create then return nil end
        b = {}
        root[g] = b
    end
    return b, g
end
