-- CDLoot: SavedVariables (ns.DB).
-- Creates CDLootDB, deep-fills defaults without overwriting saved values, runs schema
-- migrations and exposes ns.db plus dotted-path setting accessors. DB:GetEffective(path) is the read
-- every consumer uses for the group-rule settings (Addendum D §26: the loot authority's values while
-- group rules are active, else my own).
local addonName, ns = ...

local DB = ns:NewModule("DB")

local type, pairs, tostring, tonumber, next = type, pairs, tostring, tonumber, next

local SCHEMA = 1

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
        },
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
        dungeon = {              -- Addendum B §22: dungeon mode (5-man loot sharing & rolls)
            enabled = false,     -- my switch (the party leader / council also tell the party: DM message)
            quality = 3,         -- minimum drop quality inside 5-man instances (3 = Rare, 4 = Epic)
        },
        pickerSources = {        -- Addendum F §35: item picker "Sources" (ItemDB:GetCandidates filter.sources)
            raids = true, dungeons = true, crafted = false, rep = false, badges = false, pvp = false,
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
    dropHistory = {},  -- array of recent drops (§10.2), newest last, max 40, pruned > 24h
    -- groupLock (no default): { by = key, at = serverTime } while this character, as the raid's loot
    -- authority, holds the BiS list lock (Addendum F §38, Core/GroupRules.lua; restored after a /reload)
}

-- MIGRATIONS[n] upgrades a saved table from schema n-1 to n. None yet (schema 1 is the first).
local MIGRATIONS = {}

-- Group-rule settings (Addendum D §24-26 + E §32) -> field of the GS message.
local GROUP_RULE_PATHS = {
    ["roll.duration"] = true,
    qualityThreshold = true,
    ["dungeon.enabled"] = true,
    ["dungeon.quality"] = true,
    phase = true,
}

-- Addendum E §33: CDLoot no longer reads or writes the Guild Information text. Drops the old tag cache
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
    if type(CDLootDB) ~= "table" then
        CDLootDB = {}
    end
    local db = CDLootDB
    -- Publish first so later modules always find ns.db even if something below fails.
    ns.db = db

    local fresh = db.schema == nil and next(db) == nil
    local from = tonumber(db.schema) or (fresh and SCHEMA or 0)

    FillDefaults(db, DEFAULTS, "")

    if from > SCHEMA then
        -- Saved by a newer CDLoot: keep the data untouched, just warn.
        ns:Print("your saved data comes from a newer CDLoot version; please update the addon.")
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

local function SplitPath(path)
    local parts = {}
    for part in tostring(path):gmatch("[^%.]+") do
        parts[#parts + 1] = part
    end
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
