if DisasterZoneBoot and DisasterZoneBoot.Run("Core/DungeonRuns.lua", ...) then return end -- DisasterZone: guild LFG for 5-man runs (the Dungeons tab's data).
-- Members list a dungeon run (now or at a time), the others ask to join, the lister accepts and the invite goes out.
-- "I'm up for a run" tells the guild you are free (with the roles you play) and lets the addon ping you when a run
-- needs one of them. Everything stays inside the guild. Nothing here touches loot state.
--
-- What each client knows only about itself and shares: the roles it is up for, until when, and which dungeons drop
-- something on its BiS lists (dungeon level only, never the items: the lists stay with the loot council). What it
-- keeps to itself: its heroic keys (reputation), its lockouts and its level (the "can I go" checks are local).
--
-- Data (SavedVariables db.runs):
--   [guildKey] = { list = { [id] = run }, gone = { [id] = expires }, daily = { h = key, n = key, x = expires, at } }
--   me = { [charKey] = { roles = { tank = true, ... }, role = "healer", up = until | 0 } }
--   run = { id, o = owner key, d = dungeon key, h = true (heroic) | nil, at = start (server time; 0 = now),
--           c = created, no = note, s = { { k = key, r = "tank" | "healer" | "dps" }, ... } (the party, owner
--           first), rv = revision }
--
-- Messages (their own prefix, class "run"):
--   DRP { r = { role index }, u = up until, nn / nh = { dungeon index } (BiS there, normal / heroic), ids = { id },
--         dy = { h, n, x, at } (today's dailies), sv = { dungeon index } (heroics I'm saved to), q = 1 (I know
--         nobody to ask: please say hello) }   GUILD
--   DRQ {}                         WHISPER, after login, to one member known to run DisasterZone: the board, please
--   DRS { p = { { key, r, u, nn, nh, sv }, ... }, l = { run (as DRL, o = owner) }, dy }   WHISPER: the answer
--   DRL { id, d = dungeon index, h, at, c, no, s = { { k, r = role index } }, rv }   GUILD, from the owner
--   DRX { id }                     GUILD: the owner took the run off the board
--   DRJ { id, r, b = 1 (BiS here) }   WHISPER to the owner: may I join as r?
--   DRC { id }                     WHISPER to the owner: never mind
--   DRA { id, ok = 1 | 0 }         WHISPER to the asker: invited / not this time
-- A run is the owner's: only the owner changes it (a newer rv wins). Somebody who logs in gets the whole board from one
-- member (DRS), runs of offline owners included; the owner's own profile (ids) clears the runs it no longer has.
-- Members known to run DisasterZone are remembered (db.runs[guildKey].known) so that a login asks just one of them.
--
-- The dungeon indices on the wire are the order of COMPLEXES below: never reorder, only append.
local addonName, ns = ...

local Runs = ns:NewModule("DungeonRuns")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, next = type, pairs, ipairs, tonumber, tostring, next
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat, wipe = table.sort, table.concat, wipe or function(t) for k in pairs(t) do t[k] = nil end end
local strlower, strfind, strsub = string.lower, string.find, string.sub

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local ROLES = { "tank", "healer", "dps" }
local ROLE_INDEX = { tank = 1, healer = 2, dps = 3 }
local ROLE_LABEL = { tank = "Tank", healer = "Healer", dps = "DPS" }
local NEED = { tank = 1, healer = 1, dps = 3 }
local PARTY_SIZE = 5
local SPEC_ROLE = { tank = "tank", healer = "healer", melee = "dps", caster = "dps", ranged = "dps" }
local CLASS_ROLES = {
    WARRIOR = { tank = true, dps = true }, PALADIN = { tank = true, healer = true, dps = true },
    HUNTER = { dps = true }, ROGUE = { dps = true }, PRIEST = { healer = true, dps = true },
    SHAMAN = { healer = true, dps = true }, MAGE = { dps = true }, WARLOCK = { dps = true },
    DRUID = { tank = true, healer = true, dps = true },
}

local HEROIC_LEVEL = 70
local REVERED = 7
local NOTE_MAX = 40
local UP_FOR = 2 * 3600            -- "I'm up for a run" lasts this long (switching it on again restarts it)
local NOW_TTL = 3 * 3600           -- a run listed for "now" leaves the board after this
local LATER_GRACE = 3600           -- a run for later stays this long past its start
local AHEAD_MAX = 7 * 86400        -- runs are listed at most a week ahead
local OWNER_GONE = 120             -- a "now" run whose owner went offline this long ago leaves the board
local REQUEST_TTL = 20 * 60
local PEER_TTL = 15 * 60           -- a profile not heard of again (and its owner offline) is forgotten
local TICK = 20
local NO_GUILD = "~"

-- Every 5-man of TBC by complex: the old LFG icon, the loading screen, the reputation behind the heroic key, and per
-- dungeon its short name and the part of the loading screen its card shows (cx, cy = centre, as a share of the
-- texture). Loading screens are 2048x2048 textures shown at 4:3.
local COMPLEXES = {
    { key = "hfc", name = "Hellfire Citadel", icon = 136339, screen = 131845, cy = 0.42,
      rep = { Alliance = 946, Horde = 947 }, repName = { Alliance = "Honor Hold", Horde = "Thrallmar" },
      dungeons = { { "HellfireRamparts", "Ramparts", 0.26, 0.42 }, { "BloodFurnace", "Blood Furnace", 0.50, 0.45 },
                   { "ShatteredHalls", "Shattered Halls", 0.74, 0.43 } } },
    { key = "cr", name = "Coilfang Reservoir", icon = 136331, screen = 131832, cy = 0.52,
      rep = 942, repName = "Cenarion Expedition",
      dungeons = { { "SlavePens", "Slave Pens", 0.28, 0.36 }, { "Underbog", "Underbog", 0.50, 0.50 },
                   { "Steamvault", "Steamvault", 0.70, 0.55 } } },
    { key = "auch", name = "Auchindoun", icon = 136323, screen = 131821, cy = 0.45,
      rep = 1011, repName = "Lower City",
      dungeons = { { "ManaTombs", "Mana-Tombs", 0.27, 0.45 }, { "AuchenaiCrypts", "Auchenai Crypts", 0.40, 0.50 },
                   { "SethekkHalls", "Sethekk Halls", 0.70, 0.50 }, { "ShadowLabyrinth", "Shadow Lab", 0.52, 0.42 } } },
    { key = "tk", name = "Tempest Keep", icon = 136362, screen = 131875, cy = 0.42,
      rep = 935, repName = "The Sha'tar",
      dungeons = { { "Mechanar", "Mechanar", 0.27, 0.45 }, { "Botanica", "Botanica", 0.50, 0.40 },
                   { "Arcatraz", "Arcatraz", 0.73, 0.45 } } },
    { key = "cot", name = "Caverns of Time", icon = 136330, screen = 131830, cy = 0.45,
      rep = 989, repName = "Keepers of Time",
      dungeons = { { "OldHillsbrad", "Old Hillsbrad", 0.70, 0.45 }, { "BlackMorass", "Black Morass", 0.30, 0.47 } } },
    { key = "mgt", name = "Isle of Quel'Danas", icon = 136344, screen = 131874, cy = 0.47,
      rep = 1077, repName = "Shattered Sun Offensive",
      dungeons = { { "MagistersTerrace", "Magisters' Terrace", 0.62, 0.47 } } },
}
local ART_W = 0.46                 -- a card's crop: this share of the loading screen's width

-- What the raid info calls each dungeon (TBC prefixes the complex: "Auchindoun: Mana-Tombs"), lower case.
local SAVED_WORDS = {
    HellfireRamparts = "ramparts", BloodFurnace = "blood furnace", ShatteredHalls = "shattered halls",
    SlavePens = "slave pens", Underbog = "underbog", Steamvault = "steamvault", ManaTombs = "mana-tombs",
    AuchenaiCrypts = "auchenai crypts", SethekkHalls = "sethekk halls", ShadowLabyrinth = "shadow labyrinth",
    Mechanar = "mechanar", Botanica = "botanica", Arcatraz = "arcatraz", OldHillsbrad = "hillsbrad",
    BlackMorass = "black morass", MagistersTerrace = "magisters",
}

-- The dungeon dailies: Wind Trader Zephyr (heroic) and Nether-Stalker Mah'duun (normal) in Shattrath, by quest id
-- (AzerothCore creature_queststarter 24369 / 24370).
local DAILY_HEROIC = {
    [11354] = "HellfireRamparts", [11362] = "BloodFurnace", [11363] = "ShatteredHalls", [11368] = "SlavePens",
    [11369] = "Underbog", [11370] = "Steamvault", [11372] = "SethekkHalls", [11373] = "ManaTombs",
    [11374] = "AuchenaiCrypts", [11375] = "ShadowLabyrinth", [11378] = "OldHillsbrad", [11382] = "BlackMorass",
    [11384] = "Botanica", [11386] = "Mechanar", [11388] = "Arcatraz", [11499] = "MagistersTerrace",
}
local DAILY_NORMAL = {
    [11364] = "ShatteredHalls", [11371] = "Steamvault", [11376] = "ShadowLabyrinth", [11383] = "BlackMorass",
    [11385] = "Botanica", [11387] = "Mechanar", [11389] = "Arcatraz", [11500] = "MagistersTerrace",
}

local DAILY_QUEST = { h = {}, n = {} }   -- [dungeon key] = the daily's quest id
for id, key in pairs(DAILY_HEROIC) do DAILY_QUEST.h[key] = id end
for id, key in pairs(DAILY_NORMAL) do DAILY_QUEST.n[key] = id end

local ORDER = {}                   -- dungeon keys in wire order
local DUNGEON = {}                 -- [key] = { key, i, name, short, complex, cx, cy, instanceID, phase }
local BY_INSTANCE = {}
for _, c in ipairs(COMPLEXES) do
    for _, d in ipairs(c.dungeons) do
        local key = d[1]
        ORDER[#ORDER + 1] = key
        DUNGEON[key] = { key = key, i = #ORDER, short = d[2], name = d[2], complex = c, cx = d[3], cy = d[4],
                         phase = 1 }
    end
end

local dataBuilt = false
local drops                        -- [key] = { n = { [itemID] = true }, h = { ... } }

-- Names, instance ids, phases and drops from the embedded dungeon loot data (Data/Dungeons.lua).
local function BuildData()
    if dataBuilt then return end
    dataBuilt = true
    drops = {}
    for _, d in ipairs(ns.Data and ns.Data.Dungeons or {}) do
        local info = DUNGEON[d.key]
        if info then
            info.name = d.name or info.name
            info.instanceID = tonumber(d.instanceID)
            info.phase = tonumber(d.phase) or 1
            if info.instanceID then BY_INSTANCE[info.instanceID] = info end
            local n, h = {}, {}
            for _, b in ipairs(d.bosses or {}) do
                for _, id in ipairs(b.items or {}) do n[id] = true end
                for _, id in ipairs(b.heroicItems or {}) do h[id] = true end
            end
            drops[d.key] = { n = n, h = h }
        end
    end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Now() return (GetServerTime and GetServerTime()) or time() end
local function Me() return Util.PlayerKey() end
local function IsInt(n, lo, hi)
    return type(n) == "number" and n == floor(n) and (lo == nil or n >= lo) and (hi == nil or n <= hi)
end
local function G() return ns.Guild end
local function DemoOn() local D = ns.Demo; return (D and D.IsEnabled and D:IsEnabled()) and true or false end

local function Send(msg, dist, target)
    if DemoOn() then return false end
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, dist, target, "run")) and true or false
end

local function IsOnline(key)
    local g = G()
    return (g and g.IsOnline and g:IsOnline(key)) and true or false
end

local function InGuild(key)
    local g = G()
    return (g and g.IsInGuild and g:IsInGuild(key)) and true or false
end

local function ClassOf(key)
    if Util.IsMe(key) and UnitClass then return select(2, UnitClass("player")) end
    local g = G()
    local c = g and g.GetClass and g:GetClass(key)
    if not c and Util.group and Util.group[key] then c = Util.group[key].classFile end
    return c
end

local function Changed()
    Util.Debounce("dungeon-runs-changed", 0.15, function() ns:Fire("DUNGEON_RUNS_UPDATED") end)
end

local function TrimNote(s)
    s = Util.Trim(tostring(s or ""):gsub("|", ""))
    if #s > NOTE_MAX then s = strsub(s, 1, NOTE_MAX) end
    return s
end

local function Invite(key)
    local name = Ambiguate and Ambiguate(key, "none") or key
    if C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(name) else InviteUnit(name) end
end

-- A delay of lo..hi seconds spread by my name and `salt` (members answer at different moments). Not math.random: the
-- rest of the addon draws its own jitters from it, and taking numbers out of turn would shift all of theirs.
local function Jitter(lo, hi, salt, fn)
    local h = Util.Adler32((Me() or "?") .. ":" .. tostring(salt or ""))
    Util.After(lo + (h % 1000) / 1000 * (hi - lo), fn)
end

local function InCombat()
    return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player"))
end

---------------------------------------------------------------------------
-- State: the saved runs (or demo mode's), the members' profiles (memory), my own settings
---------------------------------------------------------------------------

local peers = {}                   -- [key] = { roles = { role = true }, up, nn = { [dkey] = true }, nh, ids, seen }
local requests = {}                -- (owner) [id] = { [key] = { r = role, b = true|nil, at, st = "asked"|"invited" } }
local asked = {}                   -- (asker) [id] = { st = "asked" | "invited" | "declined", r = role, at }
local pinged = {}                  -- [id] = true: the toast for this run was shown
local demo                         -- demo mode's state (built on first use, never saved)

local function Bucket(create)
    local db = ns.db
    if not db then return nil end
    if not db.runs then
        if not create then return nil end
        db.runs = {}
    end
    local g = G()
    local gk = (g and g.GetGuildKey and g:GetGuildKey()) or NO_GUILD
    local b = db.runs[gk]
    if not b and create then
        b = { list = {}, gone = {}, daily = {} }
        db.runs[gk] = b
    end
    if b then
        b.list = type(b.list) == "table" and b.list or {}
        b.gone = type(b.gone) == "table" and b.gone or {}
        b.daily = type(b.daily) == "table" and b.daily or {}
    end
    return b
end

local BuildDemo   -- forward

-- The runs in use: demo mode's while it is on, else the guild's.
local function State()
    if DemoOn() then
        if not demo then BuildDemo() end
        return demo
    end
    return Bucket(true) or { list = {}, gone = {}, daily = {} }
end

local function Peers()
    if DemoOn() then
        if not demo then BuildDemo() end
        return demo.peers
    end
    return peers
end

local function Requests()
    if DemoOn() then
        if not demo then BuildDemo() end
        return demo.requests
    end
    return requests
end

local function Asked()
    if DemoOn() then
        if not demo then BuildDemo() end
        return demo.asked
    end
    return asked
end

-- My character's settings: the roles I am up for, the role I go as when I list, and until when I am up.
local function Prefs()
    local db = ns.db
    local key = Me()
    if not db or not key then return { roles = {}, up = 0 } end
    db.runs = db.runs or {}
    db.runs.me = type(db.runs.me) == "table" and db.runs.me or {}
    local p = db.runs.me[key]
    if type(p) ~= "table" then
        p = { up = 0 }
        db.runs.me[key] = p
    end
    if type(p.roles) ~= "table" then p.roles = nil end
    return p
end

---------------------------------------------------------------------------
-- Roles
---------------------------------------------------------------------------

local function CanPlay(classFile, role)
    local set = classFile and CLASS_ROLES[classFile]
    return (set == nil or set[role]) and true or false
end

-- A member's roles from their specs (Core/Professions.lua shares main and off spec): { role = true } or nil.
local function SpecRoles(key)
    local P = ns.Professions
    local specs = P and P.GetSpecs and P:GetSpecs(key)
    local classFile = ClassOf(key)
    local list = classFile and ns.SPECS and ns.SPECS[classFile]
    if not specs or not list then return nil end
    local out, any = {}, false
    for _, s in ipairs(specs) do
        local spec = s.sp and list[s.sp]
        if not spec then
            for _, cand in ipairs(list) do
                if cand.tab == s.tab then spec = cand break end
            end
        end
        local role = spec and SPEC_ROLE[spec.role]
        if role then out[role], any = true, true end
    end
    return any and out or nil
end

-- The roles I am up for (my pick, else my specs', else what my class plays most).
local function MyRoles()
    local p = Prefs()
    local classFile = ClassOf(Me() or "")
    if p.roles and next(p.roles) then
        local out = {}
        for role in pairs(p.roles) do
            if ROLE_INDEX[role] and CanPlay(classFile, role) then out[role] = true end
        end
        if next(out) then return out end
    end
    local spec = SpecRoles(Me() or "")
    if spec then return spec end
    local set = classFile and CLASS_ROLES[classFile]
    if set and not set.dps then return { healer = true } end
    return { dps = true }
end

-- The role somebody plays in a run: what they asked for, else the one role they are up for, else their main spec's.
local function RoleOf(key, id)
    if Util.IsMe(key) then
        local p = Prefs()
        if p.role and ROLE_INDEX[p.role] then return p.role end
        for _, role in ipairs(ROLES) do
            if MyRoles()[role] then return role end
        end
    end
    local req = id and Requests()[id] and Requests()[id][key]
    if req and ROLE_INDEX[req.r] then return req.r end
    local peer = Peers()[key]
    if peer and peer.roles then
        local only, n = nil, 0
        for role in pairs(peer.roles) do only, n = role, n + 1 end
        if n == 1 then return only end
    end
    local P = ns.Professions
    local specs = P and P.GetSpecs and P:GetSpecs(key)
    local classFile = ClassOf(key)
    local list = classFile and ns.SPECS and ns.SPECS[classFile]
    local main = specs and specs[1]
    if main and list then
        local spec = main.sp and list[main.sp]
        if not spec then
            for _, cand in ipairs(list) do
                if cand.tab == main.tab then spec = cand break end
            end
        end
        if spec and SPEC_ROLE[spec.role] then return SPEC_ROLE[spec.role] end
    end
    if peer and peer.roles then
        for _, role in ipairs(ROLES) do
            if peer.roles[role] then return role end
        end
    end
    return "dps"
end

---------------------------------------------------------------------------
-- What drops my BiS, heroic keys, lockouts, dailies
---------------------------------------------------------------------------

local myNeeds = { n = {}, h = {} }   -- [dkey] = { itemID, ... } (main picks first)
local savedUntil = {}                -- [dkey] = server time a heroic lockout ends

-- My not-obtained picks of the view phase and of the Pre-raid list (both specs) that drop in a dungeon. Hint order:
-- the view phase's mains, its alts, then the Pre-raid mains and alts; the off spec after all of them in the same
-- order. A Pre-raid pick stops counting once I hold the view phase's main pick of that slot (I'm past it), and
-- when that slot is disabled in the view phase (it needs nothing this phase).
local function ComputeNeeds()
    BuildData()
    local out = { n = {}, h = {} }
    local BiS = ns.BiS
    if not BiS or not BiS.GetPhaseItems then return out end
    local g = G()
    local phase = (g and g.GetViewPhase and g:GetViewPhase()) or 1
    local preRaid = ns.PRE_RAID or 0
    local function Obtained(id) return (BiS.IsObtained and BiS:IsObtained(id)) and true or false end
    local wanted, order = {}, {}
    local lists = { false }
    if BiS.HasOffSpec and BiS:HasOffSpec() then lists[2] = "os" end
    for li, list in ipairs(lists) do
        local L = list or nil
        for pass, p in ipairs({ phase, preRaid }) do
            for _, pick in ipairs(BiS:GetPhaseItems(p, L)) do
                local id = pick.itemID
                local skip = pick.disabled or wanted[id] or Obtained(id)
                if not skip and p == preRaid then
                    local main = BiS.GetSlot and BiS:GetSlot(phase, pick.sid, L)
                    skip = (main and Obtained(main)) or (BiS.IsSlotDisabled and BiS:IsSlotDisabled(phase, pick.sid, L))
                end
                if id and not skip then
                    wanted[id] = true
                    local rank = (li - 1) * 4 + (pass - 1) * 2 + (pick.which == "main" and 0 or 1)
                    order[#order + 1] = { id = id, rank = rank, sid = pick.sid }
                end
            end
        end
    end
    tsort(order, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.sid < b.sid
    end)
    for _, key in ipairs(ORDER) do
        local dd = drops and drops[key]
        if dd then
            for _, o in ipairs(order) do
                if dd.n[o.id] then out.n[key] = out.n[key] or {}; out.n[key][#out.n[key] + 1] = o.id end
                if dd.h[o.id] then out.h[key] = out.h[key] or {}; out.h[key][#out.h[key] + 1] = o.id end
            end
        end
    end
    return out
end

local function RepFor(complex)
    local rep, name = complex.rep, complex.repName
    if type(rep) == "table" then
        local faction = UnitFactionGroup and UnitFactionGroup("player")
        rep, name = rep[faction or "Alliance"], name[faction or "Alliance"]
    end
    return rep, name
end

local SendProfile   -- forward

local helloSent = false   -- my hello went out on the guild channel (profiles before it would crowd the login sync)

local function ScanSaved()
    BuildData()
    local before = {}
    for key in pairs(savedUntil) do before[key] = true end
    wipe(savedUntil)
    if not (GetNumSavedInstances and GetSavedInstanceInfo) then return end
    local now = Now()
    for i = 1, tonumber(GetNumSavedInstances()) or 0 do
        local name, _, reset, difficulty, locked, _, _, isRaid, _, difficultyName, _, _, _, instanceId =
            GetSavedInstanceInfo(i)
        reset = tonumber(reset)
        if locked and not isRaid and reset and reset > 0 then
            local heroic = difficulty == 2
                or (type(difficultyName) == "string" and strfind(strlower(difficultyName), "heroic", 1, true) ~= nil)
            local info = instanceId and BY_INSTANCE[instanceId]
            if not info and type(name) == "string" then
                local lname = strlower(name)
                for key, word in pairs(SAVED_WORDS) do
                    if strfind(lname, word, 1, true) then info = DUNGEON[key] break end
                end
            end
            if info and heroic then savedUntil[info.key] = now + reset end
        end
    end
    Changed()
    local changed = false
    for key in pairs(savedUntil) do
        if not before[key] then changed = true end
        before[key] = nil
    end
    if (changed or next(before) ~= nil) and helloSent and SendProfile then SendProfile() end
end

-- Today's dailies (seen by anyone in the guild): heroic = true for Wind Trader Zephyr's.
local function Daily()
    local d = State().daily or {}
    if (tonumber(d.x) or 0) <= Now() then return {} end
    return d
end

local function NoteDaily(kind, key)
    if not DUNGEON[key] or DemoOn() then return end
    local b = Bucket(true)
    if not b then return end
    local left = GetQuestResetTime and tonumber(GetQuestResetTime())
    if not left or left <= 0 then return end
    local x = Now() + left
    local d = b.daily
    if math.abs((tonumber(d.x) or 0) - x) > 600 then
        b.daily = { x = x, at = Now() }
        d = b.daily
    end
    if d[kind] == key then return end
    d[kind], d.at = key, Now()
    Changed()
    SendProfile()
end

local function NoteQuest(questID)
    questID = tonumber(questID)
    if not questID then return end
    if DAILY_HEROIC[questID] then NoteDaily("h", DAILY_HEROIC[questID]) end
    if DAILY_NORMAL[questID] then NoteDaily("n", DAILY_NORMAL[questID]) end
end

---------------------------------------------------------------------------
-- Runs: slots, fit, blockers
---------------------------------------------------------------------------

local function Expired(run, now)
    now = now or Now()
    if (run.at or 0) > 0 then return now > run.at + LATER_GRACE end
    return now > (run.c or 0) + NOW_TTL
end

-- The five places of a run, tanks first: { key, role, class, you } or { empty = true, role } (the roles still open:
-- one tank, one healer, three DPS).
local function Slots(run)
    local filled = {}
    for i, s in ipairs(run.s or {}) do
        if i > PARTY_SIZE then break end
        filled[#filled + 1] = { key = s.k, role = ROLE_INDEX[s.r] and s.r or "dps", class = ClassOf(s.k),
                                you = Util.IsMe(s.k) or nil, owner = (s.k == run.o) or nil }
    end
    tsort(filled, function(a, b)
        if a.role ~= b.role then return ROLE_INDEX[a.role] < ROLE_INDEX[b.role] end
        if (a.owner and 1 or 0) ~= (b.owner and 1 or 0) then return a.owner ~= nil end
        return a.key < b.key
    end)
    local count = { tank = 0, healer = 0, dps = 0 }
    for _, f in ipairs(filled) do count[f.role] = count[f.role] + 1 end
    local free = PARTY_SIZE - #filled
    local out = {}
    local function addEmpty(role, n)
        for _ = 1, n do
            if free <= 0 then return end
            out[#out + 1] = { empty = true, role = role }
            free = free - 1
        end
    end
    for _, role in ipairs(ROLES) do
        for _, f in ipairs(filled) do
            if f.role == role then out[#out + 1] = f end
        end
        if role ~= "dps" then addEmpty(role, max(0, NEED[role] - count[role])) end
    end
    addEmpty("dps", free)
    -- an extra tank or healer pushes the open DPS places out: keep empties after the filled ones of their role
    return out
end

local function OpenRoles(run)
    local open = {}
    for _, s in ipairs(Slots(run)) do
        if s.empty then open[s.role] = (open[s.role] or 0) + 1 end
    end
    return open
end

local function InRun(run, key)
    for _, s in ipairs(run.s or {}) do
        if s.k == key then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------

local function WireRun(run, relay)
    local s = {}
    for _, x in ipairs(run.s or {}) do s[#s + 1] = { x.k, ROLE_INDEX[x.r] or 3 } end
    local d = DUNGEON[run.d]
    return { t = "DRL", id = run.id, d = d and d.i, h = run.h and 1 or nil, at = run.at or 0, c = run.c, no = run.no,
             s = s, rv = run.rv, o = relay and run.o or nil }
end

local function MyRun()
    local me = Me()
    for _, run in pairs(State().list) do
        if run.o == me and not Expired(run) then return run end
    end
    return nil
end

local function ProfileMsg(q)
    local p = Prefs()
    local r = {}
    for _, role in ipairs(ROLES) do
        if MyRoles()[role] then r[#r + 1] = ROLE_INDEX[role] end
    end
    local nn, nh = {}, {}
    for _, key in ipairs(ORDER) do
        if myNeeds.n[key] then nn[#nn + 1] = DUNGEON[key].i end
        if myNeeds.h[key] then nh[#nh + 1] = DUNGEON[key].i end
    end
    local ids = {}
    local mine = MyRun()
    if mine then ids[1] = mine.id end
    local sv = {}
    for _, key in ipairs(ORDER) do
        if (savedUntil[key] or 0) > Now() then sv[#sv + 1] = DUNGEON[key].i end
    end
    local msg = { t = "DRP", r = r, u = ((p.up or 0) > Now()) and p.up or 0, nn = nn, nh = nh, ids = ids, q = q,
                  sv = sv }
    local d = Daily()
    if d.x then
        local function index(key) return key and DUNGEON[key] and DUNGEON[key].i or nil end
        msg.dy = { h = index(d.h), n = index(d.n), x = d.x, at = d.at }
    end
    return msg
end

local lastGuildProfile = -1000   -- GetTime() of my last profile on the guild channel

local function SendProfileNow(q)
    if DemoOn() then return end
    if Send(ProfileMsg(q), "GUILD") then
        lastGuildProfile = GetTime()
        helloSent = true
    end
end

SendProfile = function()
    if DemoOn() or not ns.loggedIn or not helloSent then return end
    Util.Debounce("dungeon-runs-profile", 2, function() SendProfileNow() end)
end

local function BroadcastRun(run)
    if DemoOn() or not run then return end
    Util.Debounce("dungeon-runs-mine", 1, function()
        local cur = MyRun()
        if cur then Send(WireRun(cur), "GUILD") end
    end)
end

local MaybePing   -- forward

-- A DRL's run, or nil when malformed.
local function ParseRun(msg, sender)
    if type(msg.id) ~= "string" or #msg.id > 64 or not IsInt(msg.d, 1, #ORDER) then return nil end
    if not IsInt(msg.c, 0) or not IsInt(msg.rv, 0) or (msg.at ~= nil and not IsInt(msg.at, 0)) then return nil end
    local owner = sender
    if msg.o ~= nil then
        owner = type(msg.o) == "string" and Util.NormalizeName(msg.o) or nil
        if not owner then return nil end
    end
    local s, seen = {}, {}
    if type(msg.s) ~= "table" or #msg.s > PARTY_SIZE then return nil end
    for _, x in ipairs(msg.s) do
        local k = type(x) == "table" and type(x[1]) == "string" and Util.NormalizeName(x[1])
        local r = type(x) == "table" and IsInt(x[2], 1, 3) and ROLES[x[2]]
        if not k or not r or seen[k] then return nil end
        seen[k] = true
        s[#s + 1] = { k = k, r = r }
    end
    return { id = msg.id, o = owner, d = ORDER[msg.d], h = (msg.h == 1) or nil, at = msg.at or 0, c = msg.c,
             no = type(msg.no) == "string" and TrimNote(msg.no) or nil, s = s, rv = msg.rv }
end

local function StoreRun(run)
    local st = State()
    local gone = st.gone[run.id]
    if gone and (tonumber(gone) or 0) > Now() then return false end
    local cur = st.list[run.id]
    if cur and (cur.rv or 0) >= (run.rv or 0) then return false end
    if Expired(run) then return false end
    local fresh = cur == nil
    st.list[run.id] = run
    Changed()
    MaybePing(run, fresh)
    return true
end

local function DropRun(id, quiet)
    local st = State()
    local run = st.list[id]
    if not run then return end
    st.list[id] = nil
    st.gone[id] = Now() + max(NOW_TTL, ((run.at or 0) > 0 and (run.at + LATER_GRACE - Now()) or 0))
    Requests()[id] = nil
    if not quiet then Changed() end
end

-- Members known to run DisasterZone (kept between sessions): whom to ask for the board when I log in.
local function Known()
    local b = Bucket(true)
    if not b then return {} end
    b.known = type(b.known) == "table" and b.known or {}
    return b.known
end

-- A profile's fields (DRP, or one entry of a digest) as a peer record. sv: the heroics they are saved to, until the
-- next daily reset (by my clock).
local function ReadProfile(r, u, nn, nh, ids, sv)
    local roles = {}
    if type(r) == "table" then
        for _, i in ipairs(r) do
            if IsInt(i, 1, 3) then roles[ROLES[i]] = true end
        end
    end
    local function set(list)
        local out = {}
        if type(list) == "table" then
            for _, i in ipairs(list) do
                if IsInt(i, 1, #ORDER) then out[ORDER[i]] = true end
            end
        end
        return out
    end
    local idset
    if type(ids) == "table" then
        idset = {}
        for _, id in ipairs(ids) do
            if type(id) == "string" then idset[id] = true end
        end
    end
    local left = GetQuestResetTime and tonumber(GetQuestResetTime()) or 86400
    return { roles = roles, up = IsInt(u, 0) and u or 0, nn = set(nn), nh = set(nh), ids = idset, seen = Now(),
             saved = set(sv), savedUntil = Now() + left }
end

-- Today's dailies as somebody saw them: the newest sighting of the current day wins.
local function MergeDaily(dy)
    if type(dy) ~= "table" or not IsInt(dy.x) or dy.x <= Now() or dy.x > Now() + 26 * 3600 then return end
    local b = Bucket(true)
    local d = b and b.daily
    if not d or (tonumber(d.x) or 0) > dy.x then return end
    local newer = (tonumber(d.x) or 0) < dy.x or (IsInt(dy.at) and dy.at > (tonumber(d.at) or 0))
    if not newer then return end
    local same = (tonumber(d.x) or 0) == dy.x
    b.daily = { x = dy.x, at = IsInt(dy.at) and dy.at or Now(),
                h = IsInt(dy.h, 1, #ORDER) and ORDER[dy.h] or (same and d.h or nil),
                n = IsInt(dy.n, 1, #ORDER) and ORDER[dy.n] or (same and d.n or nil) }
end

local Digest   -- forward

local function OnProfile(sender, msg, dist)
    if not InGuild(sender) then return end
    local p = ReadProfile(msg.r, msg.u, msg.nn, msg.nh, msg.ids, msg.sv)
    peers[sender] = p
    Known()[sender] = Now()
    -- the owner's own list of runs: theirs that it no longer names are gone
    if p.ids then
        local st = Bucket(true)
        for id, run in pairs(st and st.list or {}) do
            if run.o == sender and not p.ids[id] then DropRun(id, true) end
        end
    end
    MergeDaily(msg.dy)
    Changed()
    if msg.q == 1 and dist == "GUILD" then
        -- somebody who knows nobody to ask yet: the first online member by name sends them the board (runs of
        -- offline owners included); everyone says hello once (unless it just went out) and owners whisper their run
        local elected = true
        for key in pairs(peers) do
            if key ~= sender and key < (Me() or "") and IsOnline(key) then elected = false break end
        end
        if elected then
            Jitter(1, 3, "board" .. sender, function()
                if IsOnline(sender) then Send(Digest(), "WHISPER", sender) end
            end)
        end
        Jitter(2, 8, sender, function()
            if GetTime() - lastGuildProfile > 30 then SendProfileNow() end
        end)
        if MyRun() then
            Jitter(1, 4, "run" .. sender, function()
                local mine = MyRun()
                if mine then Send(WireRun(mine), "WHISPER", sender) end
            end)
        end
    end
end

local function OnRun(sender, msg)
    if not InGuild(sender) then return end
    local run = ParseRun(msg, sender)
    if not run or run.o ~= sender or run.o == Me() then return end
    StoreRun(run)
end

-- The board as I know it, for a member who just logged in: the profiles of the members online (me first), every run
-- and today's dailies; trimmed to what any member's client takes from me.
local DIGEST_WIRE, DIGEST_INFLATED = 3800, 15000

Digest = function()
    local mine = ProfileMsg()
    local p = { { Me(), mine.r, mine.u, mine.nn, mine.nh, mine.sv } }
    local keys = {}
    for key in pairs(peers) do
        if IsOnline(key) and not Util.IsMe(key) then keys[#keys + 1] = key end
    end
    tsort(keys, function(a, b) return (peers[a].seen or 0) > (peers[b].seen or 0) end)
    for _, key in ipairs(keys) do
        local peer = peers[key]
        local r, nn, nh, sv = {}, {}, {}, {}
        for _, role in ipairs(ROLES) do
            if peer.roles and peer.roles[role] then r[#r + 1] = ROLE_INDEX[role] end
        end
        local saved = (peer.savedUntil or 0) > Now() and peer.saved or {}
        for _, k in ipairs(ORDER) do
            if peer.nn and peer.nn[k] then nn[#nn + 1] = DUNGEON[k].i end
            if peer.nh and peer.nh[k] then nh[#nh + 1] = DUNGEON[k].i end
            if saved[k] then sv[#sv + 1] = DUNGEON[k].i end
        end
        p[#p + 1] = { key, r, peer.up or 0, nn, nh, sv }
    end
    local l = {}
    local now = Now()
    for _, run in pairs((Bucket(true) or { list = {} }).list) do
        if not Expired(run, now) then
            local w = WireRun(run, true)
            w.t, w.o = nil, run.o
            l[#l + 1] = w
        end
    end
    local msg = { t = "DRS", p = p, l = l, dy = mine.dy }
    local Comm = ns.Comm
    while Comm and Comm.Fits do
        local _, wire, inflated = Comm:Fits(msg)
        if (wire or 0) <= DIGEST_WIRE and (inflated or 0) <= DIGEST_INFLATED then break end
        if #p > 1 then p[#p] = nil elseif #l > 0 then l[#l] = nil else break end
    end
    return msg
end

local function OnQuery(sender, msg, dist)
    if dist ~= "WHISPER" or not InGuild(sender) then return end
    local Comm = ns.Comm
    if Comm and Comm.RateLimit and not Comm:RateLimit("DRQ:" .. sender, 20) then return end
    Send(Digest(), "WHISPER", sender)
end

local asking = { tried = {}, tries = 0 }   -- my question for the board after login

local function OnDigest(sender, msg)
    if not InGuild(sender) then return end
    asking.got = true
    Known()[sender] = Now()
    local now = Now()
    for _, e in ipairs(type(msg.p) == "table" and msg.p or {}) do
        local key = type(e) == "table" and type(e[1]) == "string" and Util.NormalizeName(e[1])
        -- what a member told me themselves a moment ago beats the copy in the digest
        if key and not Util.IsMe(key) and InGuild(key) and not (peers[key] and now - (peers[key].seen or 0) < 10) then
            peers[key] = ReadProfile(e[2], e[3], e[4], e[5], nil, e[6])
            Known()[key] = now
        end
    end
    for _, w in ipairs(type(msg.l) == "table" and msg.l or {}) do
        if type(w) == "table" then
            local run = ParseRun(w, sender)
            if run and run.o ~= Me() and InGuild(run.o) then StoreRun(run) end
        end
    end
    MergeDaily(msg.dy)
    Changed()
end

-- Asks a member known to run DisasterZone (the most recently seen one online) for the board; the next one when no
-- answer comes. Returns false when there is nobody to ask.
local function AskNext()
    if asking.got or asking.tries >= 3 then return false end
    local cands = {}
    for key, t in pairs(Known()) do
        if not Util.IsMe(key) and not asking.tried[key] and IsOnline(key) then
            cands[#cands + 1] = { key = key, t = tonumber(t) or 0 }
        end
    end
    tsort(cands, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return a.key < b.key
    end)
    local c = cands[1]
    if not c then return false end
    asking.tried[c.key] = true
    asking.tries = asking.tries + 1
    Send({ t = "DRQ" }, "WHISPER", c.key)
    Util.After(8, function()
        if not asking.got then AskNext() end
    end)
    return true
end

local function OnUnlist(sender, msg)
    if type(msg.id) ~= "string" then return end
    local run = State().list[msg.id]
    if run and run.o == sender then DropRun(msg.id) end
end

local function OnJoin(sender, msg)
    local run = type(msg.id) == "string" and State().list[msg.id]
    if not run or run.o ~= Me() or not IsInt(msg.r, 1, 3) then return end
    local reqs = Requests()
    reqs[run.id] = reqs[run.id] or {}
    local fresh = reqs[run.id][sender] == nil
    reqs[run.id][sender] = { r = ROLES[msg.r], b = (msg.b == 1) or nil, at = Now(), st = "asked" }
    Changed()
    if fresh then ns:Fire("DUNGEON_RUN_REQUEST", run.id, sender) end
end

local function OnCancel(sender, msg)
    local reqs = type(msg.id) == "string" and Requests()[msg.id]
    if reqs and reqs[sender] then
        reqs[sender] = nil
        Changed()
    end
end

local function OnAnswer(sender, msg)
    local run = type(msg.id) == "string" and State().list[msg.id]
    local a = run and Asked()[run.id]
    if not a or run.o ~= sender then return end
    a.st = (msg.ok == 1) and "invited" or "declined"
    Changed()
end

---------------------------------------------------------------------------
-- My run and the group
---------------------------------------------------------------------------

-- My run's party from my group: me, then the members (with the role each asked for / plays).
local function SyncMyParty()
    if DemoOn() then return end
    local run = MyRun()
    if not run then return end
    -- in somebody else's group, or a raid: my run is over
    if IsInRaid() or (IsInGroup() and not UnitIsGroupLeader("player")) then
        Runs:Unlist(true)
        return
    end
    local s = { { k = Me(), r = RoleOf(Me()) } }
    local keys = {}
    for key in pairs(Util.group or {}) do
        if not Util.IsMe(key) then keys[#keys + 1] = key end
    end
    tsort(keys)
    for _, key in ipairs(keys) do
        local prev
        for _, x in ipairs(run.s or {}) do
            if x.k == key then prev = x.r end
        end
        s[#s + 1] = { k = key, r = prev or RoleOf(key, run.id) }
    end
    local same = #s == #(run.s or {})
    if same then
        for i, x in ipairs(s) do
            local y = run.s[i]
            if not y or y.k ~= x.k or y.r ~= x.r then same = false break end
        end
    end
    -- whoever joined is no longer asking
    local reqs = Requests()[run.id]
    for _, x in ipairs(s) do
        if reqs and reqs[x.k] then reqs[x.k] = nil; same = false end
    end
    if same then return end
    run.s = s
    run.rv = (run.rv or 0) + 1
    if #s >= PARTY_SIZE then
        ns:Print("%s is full: taken off the board. Have fun!", DUNGEON[run.d] and DUNGEON[run.d].name or "Your run")
        Runs:Unlist(true)
        return
    end
    Changed()
    BroadcastRun(run)
end

local function UpdateUp()
    local p = Prefs()
    if (p.up or 0) <= 0 then return end
    local over = (p.up or 0) <= Now()
    -- a full party, or a dungeon: no longer free
    if IsInRaid() or (IsInGroup() and (GetNumGroupMembers() or 0) >= PARTY_SIZE) or Util.InPartyInstance() then
        over = true
    end
    if over then
        p.up = 0
        Changed()
        SendProfile()
    end
end

---------------------------------------------------------------------------
-- Pings: a run that needs me while I am up for one
---------------------------------------------------------------------------

MaybePing = function(run, fresh)
    if pinged[run.id] or run.o == Me() or InRun(run, Me()) then return end
    if not Runs:IsUp() then return end
    if InCombat() or Util.InPartyInstance() or Util.InRaidInstance() then return end
    local role = Runs:FitsMe(run)
    if not role or Runs:GetBlocker(run.d, run.h) then return end
    if (run.at or 0) > Now() + 3600 then return end   -- a run for tomorrow is no reason to ping now
    pinged[run.id] = true
    ns:Fire("DUNGEON_RUN_PING", run.id)
end

---------------------------------------------------------------------------
-- Demo mode: a few made-up runs and members (UI previews, trying the page solo); nothing is sent
---------------------------------------------------------------------------

BuildDemo = function()
    BuildData()
    demo = { list = {}, gone = {}, daily = {}, peers = {}, requests = {}, asked = {} }
    local D = ns.Demo
    local members = (D and D.GetMembers and D:GetMembers()) or {}
    local by = {}
    for _, key in ipairs(members) do by[(Util.ShortName(key) or key)] = key end
    local function k(name) return by[name] or name end
    local now = Now()
    local function run(id, owner, d, h, at, ageMin, slots, note)
        local s = {}
        for _, x in ipairs(slots) do s[#s + 1] = { k = k(x[1]), r = x[2] } end
        demo.list[id] = { id = id, o = k(owner), d = d, h = h or nil, at = at, c = now - ageMin * 60, s = s, rv = 1,
                          no = note }
    end
    run("demo-1", "Aldrin", "ShatteredHalls", true, 0, 4,
        { { "Aldrin", "tank" }, { "Grimtusk", "dps" }, { "Elowen", "dps" }, { "Dornoth", "dps" } },
        "Badge run, we know the gauntlet")
    run("demo-2", "Kaelyn", "BlackMorass", true, 0, 9,
        { { "Kaelyn", "healer" }, { "Brakka", "tank" }, { "Halvard", "dps" } })
    run("demo-3", "Mirabel", "ShadowLabyrinth", true, 0, 15, { { "Mirabel", "dps" }, { "Jorvik", "healer" } })
    local later = now + 2 * 3600 - now % 1800
    run("demo-4", "Caelith", "Steamvault", nil, later, 30, { { "Caelith", "tank" } })
    local function peer(name, roles, up)
        local set = {}
        for _, r in ipairs(roles) do set[r] = true end
        demo.peers[k(name)] = { roles = set, up = up and (now + 3600) or 0, nn = {}, nh = {}, seen = now }
    end
    peer("Isolde", { "healer" }, true)
    peer("Nortok", { "dps" }, true)
    peer("Orinel", { "dps" }, true)
    peer("Quillon", { "tank", "healer" }, true)
    peer("Faelar", { "dps" }, true)
    peer("Pyria", { "dps" }, false)
    demo.peers[k("Grimtusk")] = { roles = { dps = true }, up = 0, nn = {},
                                  nh = { ShatteredHalls = true, Botanica = true }, seen = now }
    demo.peers[k("Nortok")].nh = { Botanica = true, ShadowLabyrinth = true }
    demo.peers[k("Orinel")].nh = { Botanica = true }
    demo.asked["demo-4"] = { st = "asked", r = "healer", at = now - 300 }
    demo.peers[k("Faelar")].saved = { Botanica = true }
    demo.peers[k("Faelar")].savedUntil = now + 6 * 3600
    demo.daily = { x = now + 6 * 3600, at = now, h = "SethekkHalls", n = "Botanica" }
end

local function DemoRequests(run)
    local D = ns.Demo
    local by = {}
    for _, key in ipairs((D and D.GetMembers and D:GetMembers()) or {}) do by[Util.ShortName(key) or key] = key end
    local reqs = {}
    if by.Nortok then reqs[by.Nortok] = { r = "dps", b = true, at = Now() - 60, st = "asked" } end
    if by.Orinel then reqs[by.Orinel] = { r = "dps", at = Now() - 20, st = "asked" } end
    demo.requests[run.id] = reqs
end

---------------------------------------------------------------------------
-- Public API: the dungeons
---------------------------------------------------------------------------

Runs.ROLES = ROLES
Runs.ROLE_LABEL = ROLE_LABEL
Runs.NOTE_MAX = NOTE_MAX
Runs.AHEAD_MAX = AHEAD_MAX

-- The complexes in order with their dungeons the guild's phase has opened:
-- { { key, name, icon, screen, cy, repName, dungeons = { info, ... } }, ... }
function Runs:GetComplexes()
    BuildData()
    local g = G()
    local phase = (g and g.GetGuildPhase and g:GetGuildPhase()) or 1
    local out = {}
    for _, c in ipairs(COMPLEXES) do
        local list = {}
        for _, d in ipairs(c.dungeons) do
            local info = DUNGEON[d[1]]
            if (info.phase or 1) <= phase then list[#list + 1] = info end
        end
        if #list > 0 then
            local _, repName = RepFor(c)
            out[#out + 1] = { key = c.key, name = c.name, icon = c.icon, screen = c.screen, cy = c.cy,
                              repName = repName, dungeons = list }
        end
    end
    return out
end

function Runs:GetDungeon(key)
    BuildData()
    return DUNGEON[key]
end

-- The loading screen and tex coords (left, right, top, bottom) that show a dungeon in a w x h frame; fw = the share
-- of the screen's width (default the cards' crop). For a complex row (complex = true) the full width at its height.
function Runs:GetArt(key, w, h, fw)
    local info = DUNGEON[key]
    if not info or not w or not h or w <= 0 or h <= 0 then return nil end
    fw = fw or ART_W
    local fh = fw * (4 / 3) * (h / w)
    local l, t = info.cx - fw / 2, info.cy - fh / 2
    l = min(max(l, 0), 1 - fw)
    t = min(max(t, 0.02), 0.98 - fh)
    return info.complex.screen, l, l + fw, t, t + fh
end

function Runs:GetComplexArt(complexKey, w, h)
    for _, c in ipairs(COMPLEXES) do
        if c.key == complexKey then
            local fw = 0.98
            local fh = fw * (4 / 3) * (h / w)
            local t = min(max(c.cy - fh / 2, 0.02), 0.98 - fh)
            return c.screen, 0.01, 0.01 + fw, t, t + fh
        end
    end
    return nil
end

-- Why I can't run this heroic, or nil: "Needs level 70" / "Needs Revered with Lower City" / "Saved until 09:00";
-- second return: "level" | "rep" | "saved".
function Runs:GetBlocker(key, heroic)
    local info = DUNGEON[key]
    if not info or not heroic then return nil end
    local level = UnitLevel and tonumber(UnitLevel("player"))
    if level and level > 0 and level < HEROIC_LEVEL then return "Needs level " .. HEROIC_LEVEL, "level" end
    local rep, repName = RepFor(info.complex)
    if rep and GetFactionInfoByID then
        local name, _, standing = GetFactionInfoByID(rep)
        if not standing or standing < REVERED then
            return "Needs Revered with " .. ((type(name) == "string" and name ~= "") and name or repName), "rep"
        end
    end
    local untilT = savedUntil[key]
    if untilT and untilT > Now() then return "You're saved until " .. date("%H:%M", untilT), "saved" end
    return nil
end

-- The items on my BiS lists (this phase, not obtained) that drop there, main picks first.
function Runs:GetMyBiSDrops(key, heroic)
    local list = (heroic and myNeeds.h or myNeeds.n)[key]
    return list or {}
end

-- Online guild members (not me) with something on their BiS lists there: count, sorted keys.
function Runs:GetNeeders(key, heroic)
    local out = {}
    for k, peer in pairs(Peers()) do
        local set = heroic and peer.nh or peer.nn
        if set and set[key] and (DemoOn() or IsOnline(k)) and not Util.IsMe(k)
            and not (heroic and Runs:IsSaved(k, key)) then
            out[#out + 1] = k
        end
    end
    tsort(out)
    return #out, out
end

-- Today's daily dungeon (heroic = Wind Trader Zephyr's), as somebody in the guild saw it; nil when unknown.
function Runs:GetDaily(heroic)
    local d = Daily()
    return heroic and d.h or d.n
end

-- Is that dungeon's daily mine to do? "log" = its quest is in my quest log (taken today or on an earlier day),
-- "today" = it is today's and I haven't done it, "done" = today's and I did it; nil = no daily for me there.
function Runs:GetMyDaily(key, heroic)
    local qid = DAILY_QUEST[heroic and "h" or "n"][key]
    if not qid then return nil end
    local Q = C_QuestLog
    if Q and Q.IsOnQuest and Q.IsOnQuest(qid) then return "log" end
    if self:GetDaily(heroic) ~= key then return nil end
    if Q and Q.IsQuestFlaggedCompleted and Q.IsQuestFlaggedCompleted(qid) then return "done" end
    return "today"
end

-- Until when I am saved to that heroic (server time), or nil.
function Runs:GetSavedUntil(key)
    local t = savedUntil[key]
    return (t and t > Now()) and t or nil
end

-- Is a member (not me) saved to that heroic, as their DisasterZone told the guild?
function Runs:IsSaved(member, key)
    if Util.IsMe(member) then return self:GetSavedUntil(key) ~= nil end
    local peer = Peers()[member]
    return (peer and peer.saved and peer.saved[key] and (peer.savedUntil or 0) > Now()) and true or false
end

---------------------------------------------------------------------------
-- Public API: me
---------------------------------------------------------------------------

function Runs:GetMyRoles() return MyRoles() end

-- The role I go as in my own run (my last pick, else my first role).
function Runs:GetGoAs() return RoleOf(Me() or "") end

-- The role somebody would play in a run (what they asked for, the one role they are up for, their main spec).
function Runs:GetRoleOf(key, id) return RoleOf(key, id) end

-- A member's spec label ("Restoration") from what their DisasterZone shares, or nil.
function Runs:GetSpecLabel(key)
    local P = ns.Professions
    local specs = P and P.GetSpecs and P:GetSpecs(key)
    local classFile = ClassOf(key)
    local list = classFile and ns.SPECS and ns.SPECS[classFile]
    local main = specs and specs[1]
    if not main or not list then return nil end
    local spec = main.sp and list[main.sp]
    if not spec then
        for _, cand in ipairs(list) do
            if cand.tab == main.tab then spec = cand break end
        end
    end
    return spec and spec.label or nil
end

function Runs:GetClass(key) return ClassOf(key) end

-- The roles my class can play, in order.
function Runs:GetPlayableRoles()
    local classFile = ClassOf(Me() or "")
    local out = {}
    for _, role in ipairs(ROLES) do
        if CanPlay(classFile, role) then out[#out + 1] = role end
    end
    return out
end

-- Turns one of my roles on or off (at least one stays on).
function Runs:SetMyRole(role, on)
    if not ROLE_INDEX[role] then return false end
    local p = Prefs()
    local cur = MyRoles()
    local nextSet = {}
    for r in pairs(cur) do nextSet[r] = true end
    nextSet[role] = on and true or nil
    if not next(nextSet) then return false end
    p.roles = nextSet
    if p.role and not nextSet[p.role] then p.role = nil end
    Changed()
    SendProfile()
    local mine = MyRun()
    if mine then
        for _, x in ipairs(mine.s or {}) do
            if Util.IsMe(x.k) and not nextSet[x.r] then
                x.r = RoleOf(Me())
                mine.rv = (mine.rv or 0) + 1
                BroadcastRun(mine)
            end
        end
    end
    return true
end

function Runs:IsUp()
    return (Prefs().up or 0) > Now()
end

-- Until when I am up for a run (server time), or nil.
function Runs:GetUpUntil()
    local up = Prefs().up or 0
    return up > Now() and up or nil
end

function Runs:SetUp(on)
    local p = Prefs()
    p.up = on and (Now() + UP_FOR) or 0
    if on then wipe(pinged) end
    Changed()
    SendProfile()
    if on then
        for _, run in pairs(State().list) do MaybePing(run, false) end
    end
end

-- Guild members (not me) who are up for a run now, tanks and healers first: { { key, roles, class } }.
function Runs:GetUpForRun()
    local out = {}
    local now = Now()
    local busy = {}
    for _, run in pairs(State().list) do
        for _, x in ipairs(run.s or {}) do busy[x.k] = true end
    end
    for key, peer in pairs(Peers()) do
        if (peer.up or 0) > now and not Util.IsMe(key) and not busy[key] and (DemoOn() or IsOnline(key)) then
            out[#out + 1] = { key = key, roles = peer.roles or {}, class = ClassOf(key) }
        end
    end
    local function rank(e)
        if e.roles.tank then return 1 end
        if e.roles.healer then return 2 end
        return 3
    end
    tsort(out, function(a, b)
        if rank(a) ~= rank(b) then return rank(a) < rank(b) end
        return a.key < b.key
    end)
    return out
end

---------------------------------------------------------------------------
-- Public API: runs
---------------------------------------------------------------------------

-- Every listed run (not expired), mine included: { run, ... } in no particular order.
function Runs:GetRuns()
    local out = {}
    local now = Now()
    for _, run in pairs(State().list) do
        if not Expired(run, now) and DUNGEON[run.d] then out[#out + 1] = run end
    end
    return out
end

function Runs:GetRun(id)
    local run = type(id) == "string" and State().list[id]
    if run and not Expired(run) then return run end
    return nil
end

function Runs:GetMine() return MyRun() end
function Runs:GetSlots(run) return Slots(run) end
function Runs:GetOpenRoles(run) return OpenRoles(run) end
function Runs:IsInRun(run, key) return InRun(run, key or Me()) end

-- Does the run start now (or has its time come)?
function Runs:IsNow(run)
    return (run.at or 0) <= Now()
end

-- The role I would join as (the scarcest open one I play), or nil when no open place fits me.
function Runs:FitsMe(run)
    if not run or run.o == Me() or InRun(run, Me()) then return nil end
    local open = OpenRoles(run)
    local mine = MyRoles()
    for _, role in ipairs(ROLES) do
        if open[role] and mine[role] then return role end
    end
    return nil
end

-- My question to this run: { st = "asked" | "invited" | "declined", r, at } or nil.
function Runs:GetAsked(id) return Asked()[id] end

-- The players asking to join my run, oldest first: { { key, r, b, at, st } }.
function Runs:GetRequests(id)
    local out = {}
    for key, r in pairs(Requests()[id] or {}) do
        if Now() - (r.at or 0) < REQUEST_TTL then
            out[#out + 1] = { key = key, r = r.r, b = r.b, at = r.at, st = r.st }
        end
    end
    tsort(out, function(a, b) return (a.at or 0) < (b.at or 0) end)
    return out
end

-- Lists my run (replacing the one I had). opts = { d = dungeon key, h = heroic, at = server time | 0 (now),
-- no = note, role = the role I go as }. Returns the run, or nil and why.
function Runs:List(opts)
    if type(opts) ~= "table" or not DUNGEON[opts.d] then return nil, "Pick a dungeon." end
    local at = tonumber(opts.at) or 0
    local now = Now()
    if at > 0 and at <= now + 60 then at = 0 end
    if at > now + AHEAD_MAX then return nil, "Runs can be listed at most a week ahead." end
    if IsInRaid() or (IsInGroup() and not UnitIsGroupLeader("player")) then
        return nil, "Only the party leader can list the party's run."
    end
    local block = self:GetBlocker(opts.d, opts.h)
    if block then return nil, block end
    local p = Prefs()
    if opts.role and ROLE_INDEX[opts.role] then p.role = opts.role end
    local old = MyRun()
    local run = {
        id = old and old.id or ((Me() or "?") .. ":" .. now),
        o = Me(), d = opts.d, h = opts.h and true or nil, at = floor(at), c = old and old.c or now,
        no = TrimNote(opts.no), s = old and old.s or {}, rv = old and ((old.rv or 0) + 1) or 1,
    }
    if run.no == "" then run.no = nil end
    if old and old.at == 0 and run.at > 0 then run.c = now end
    State().list[run.id] = run
    State().gone[run.id] = nil
    p.up = 0
    if DemoOn() then
        run.s = { { k = Me(), r = RoleOf(Me()) } }
        if not old then DemoRequests(run) end
    else
        run.s = nil
        SyncMyParty()
        if not run.s or #run.s == 0 then run.s = { { k = Me(), r = RoleOf(Me()) } } end
        BroadcastRun(run)
        SendProfile()
    end
    Changed()
    return run
end

-- Takes my run off the board. quiet: no chat line.
function Runs:Unlist(quiet)
    local run = MyRun()
    if not run then return false end
    DropRun(run.id)
    if not DemoOn() then
        Send({ t = "DRX", id = run.id }, "GUILD")
        SendProfile()
    end
    if not quiet then ns:Print("Your run is off the board.") end
    return true
end

-- Asks the owner to join as the best open role I play. Returns ok, why.
function Runs:Join(id)
    local run = self:GetRun(id)
    if not run then return false, "That run is gone." end
    local role = self:FitsMe(run)
    if not role then return false, "No open place fits your roles." end
    local block = self:GetBlocker(run.d, run.h)
    if block then return false, block end
    if not DemoOn() then
        if not IsOnline(run.o) then return false, "The leader is offline." end
        local b = (#self:GetMyBiSDrops(run.d, run.h) > 0) and 1 or nil
        if not Send({ t = "DRJ", id = id, r = ROLE_INDEX[role], b = b }, "WHISPER", run.o) then
            return false, "Could not reach the leader."
        end
    end
    Asked()[id] = { st = "asked", r = role, at = Now() }
    Changed()
    return true
end

function Runs:CancelJoin(id)
    local a = Asked()[id]
    if not a then return false end
    Asked()[id] = nil
    local run = self:GetRun(id)
    if run and not DemoOn() then Send({ t = "DRC", id = id }, "WHISPER", run.o) end
    Changed()
    return true
end

local function CanInvite()
    if IsInRaid() then return false end
    return not IsInGroup() or UnitIsGroupLeader("player")
end

-- (owner) Invites somebody who asked; the invite goes out right away.
function Runs:Accept(id, key)
    local run = MyRun()
    local req = run and run.id == id and Requests()[id] and Requests()[id][key]
    if not req then return false end
    if DemoOn() then
        Requests()[id][key] = nil
        run.s[#run.s + 1] = { k = key, r = req.r }
        Changed()
        return true
    end
    if not CanInvite() then
        ns:Print("Only the party leader can invite.")
        return false
    end
    Invite(key)
    req.st = "invited"
    Send({ t = "DRA", id = id, ok = 1 }, "WHISPER", key)
    Changed()
    return true
end

function Runs:Decline(id, key)
    local reqs = Requests()[id]
    if not reqs or not reqs[key] then return false end
    reqs[key] = nil
    if not DemoOn() then Send({ t = "DRA", id = id, ok = 0 }, "WHISPER", key) end
    Changed()
    return true
end

-- (owner) Invites a guild member who is up for a run straight away.
function Runs:InviteFree(key)
    local run = MyRun()
    if not run then return false end
    if DemoOn() then
        local peer = Peers()[key]
        local role
        local open = OpenRoles(run)
        for _, r in ipairs(ROLES) do
            if open[r] and peer and peer.roles and peer.roles[r] and not role then role = r end
        end
        run.s[#run.s + 1] = { k = key, r = role or "dps" }
        if peer then peer.up = 0 end
        Changed()
        return true
    end
    if not CanInvite() then
        ns:Print("Only the party leader can invite.")
        return false
    end
    Invite(key)
    return true
end

-- (owner) The text for the LookingForGroup channel: "LFM Shattered Halls (Heroic): tank, healer, 2 DPS".
function Runs:GetChannelText()
    local run = MyRun()
    if not run then return nil end
    local open = OpenRoles(run)
    local parts = {}
    for _, role in ipairs(ROLES) do
        local n = open[role]
        if n then parts[#parts + 1] = (n > 1 and (n .. " ") or "") .. ROLE_LABEL[role] end
    end
    if #parts == 0 then return nil end
    local name = DUNGEON[run.d].name .. (run.h and " (Heroic)" or "")
    local when = (run.at or 0) > Now() and (" at " .. date("%H:%M", run.at)) or ""
    return "LFM " .. name .. when .. ": " .. tconcat(parts, ", ")
end

-- Posts my run in the LookingForGroup channel (a click: the channel needs a hardware event). Returns ok, why.
function Runs:PostToChannel()
    local text = self:GetChannelText()
    if not text then return false, "Your run has no open places." end
    local id = GetChannelName and GetChannelName("LookingForGroup")
    id = tonumber(id)
    if not id or id == 0 then return false, "Join the LookingForGroup channel first: /join LookingForGroup" end
    if DemoOn() then return false, "Demo mode: nothing is sent." end
    SendChatMessage(text, "CHANNEL", nil, id)
    return true
end

-- For the harness: the profile a member shared ({ roles, up, nn, nh }) or nil.
function Runs:GetPeer(key) return Peers()[key] end
function Runs:ComputeNeeds() myNeeds = ComputeNeeds(); return myNeeds end
function Runs:ScanSaved() ScanSaved() end
function Runs:NoteQuest(questID) NoteQuest(questID) end

---------------------------------------------------------------------------
-- Housekeeping
---------------------------------------------------------------------------

local ownerOffline = {}   -- [owner] = Now() when first seen offline

local function Tick()
    local now = Now()
    local st = Bucket(true)
    if st then
        for id, run in pairs(st.list) do
            local drop = Expired(run, now) or not DUNGEON[run.d]
            if not drop and run.o ~= Me() and (run.at or 0) <= now then
                -- a run happening now dies with its owner going offline
                if IsOnline(run.o) then
                    ownerOffline[run.o] = nil
                else
                    ownerOffline[run.o] = ownerOffline[run.o] or now
                    drop = now - ownerOffline[run.o] >= OWNER_GONE
                end
            end
            if drop then DropRun(id, true) end
        end
        for id, x in pairs(st.gone) do
            if (tonumber(x) or 0) <= now then st.gone[id] = nil end
        end
    end
    for key, peer in pairs(peers) do
        if not IsOnline(key) and now - (peer.seen or 0) > PEER_TTL then peers[key] = nil end
    end
    for id in pairs(asked) do
        if not Runs:GetRun(id) then asked[id] = nil end
    end
    UpdateUp()
    Changed()
end

local function RefreshNeeds()
    Util.Debounce("dungeon-runs-needs", 2, function()
        local before = ProfileMsg()
        myNeeds = ComputeNeeds()
        local after = ProfileMsg()
        local same = #before.nn == #after.nn and #before.nh == #after.nh
        if same then
            for i, v in ipairs(after.nn) do if before.nn[i] ~= v then same = false end end
            for i, v in ipairs(after.nh) do if before.nh[i] ~= v then same = false end end
        end
        if not same then SendProfile() end
        Changed()
    end)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Runs:OnInit()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("DRP", OnProfile)
        Comm:Register("DRQ", OnQuery)
        Comm:Register("DRS", OnDigest)
        Comm:Register("DRL", OnRun)
        Comm:Register("DRX", OnUnlist)
        Comm:Register("DRJ", OnJoin)
        Comm:Register("DRC", OnCancel)
        Comm:Register("DRA", OnAnswer)
    end
    for _, msg in ipairs({ "MYLIST_CHANGED", "OWNED_UPDATED", "LISTS_RESET", "CONFIG_UPDATED" }) do
        ns:On(msg, RefreshNeeds)
    end
    ns:On("GROUP_UPDATED", function()
        Util.Debounce("dungeon-runs-group", 0.5, function()
            SyncMyParty()
            UpdateUp()
            Changed()
        end)
    end)
    ns:On("ROSTER_UPDATED", Changed)
    ns:On("DEMO_TOGGLED", function(on)
        if not on then demo = nil end
        Changed()
    end)
    ns:RegisterEvent("UPDATE_INSTANCE_INFO", ScanSaved)
    ns:RegisterEvent("QUEST_ACCEPTED", function(_, a, b)
        NoteQuest(b or a)
        Changed()
    end)
    for _, ev in ipairs({ "QUEST_TURNED_IN", "QUEST_REMOVED" }) do
        ns:RegisterEvent(ev, function() Util.Debounce("dungeon-runs-quests", 0.5, Changed) end)
    end
    ns:RegisterEvent("QUEST_DETAIL", function()
        if GetQuestID then NoteQuest(GetQuestID()) end
    end)
    ns:RegisterEvent("GOSSIP_SHOW", function()
        local list = C_GossipInfo and C_GossipInfo.GetAvailableQuests and C_GossipInfo.GetAvailableQuests()
        for _, q in ipairs(type(list) == "table" and list or {}) do
            if type(q) == "table" then NoteQuest(q.questID) end
        end
    end)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() Util.After(2, UpdateUp) end)
    ns:RegisterEvent("PLAYER_LEVEL_UP", Changed)
    ns:RegisterEvent("UPDATE_FACTION", function() Util.Debounce("dungeon-runs-rep", 1, Changed) end)
    ns:RegisterSlash("lfg", function() if ns.MainFrame then ns.MainFrame:Open("dungeons") end end,
        "open the Dungeons tab: list a 5-man run or join one")
end

function Runs:OnLogin()
    BuildData()
    myNeeds = ComputeNeeds()
    if RequestRaidInfo then RequestRaidInfo() end
    ScanSaved()
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(TICK, Tick) end
    -- Once the roster is in: ask one member I know for the board (one whisper each way). The hello on the guild
    -- channel waits until the login sync of the rest of the addon is over: in a login wave every member's client
    -- holds the guild's messages until its own roster arrives, and the loot council's must not be crowded out.
    asking = { tried = {}, tries = 0 }
    local waited = 0
    local function whenReady()
        local g = G()
        if not IsInGuild() then return end
        if not (g and g.IsReady and g:IsReady()) and waited < 60 then
            waited = waited + 2
            Util.After(2, whenReady)
            return
        end
        Jitter(3, 8, "ask", function() asking.early = AskNext() end)
    end
    Util.After(2, whenReady)
    Jitter(30, 45, "hello", function()
        if not IsInGuild() then return end
        SendProfileNow((not asking.early and not asking.got) and 1 or nil)
        local mine = MyRun()
        if mine then
            mine.rv = (mine.rv or 0) + 1
            SyncMyParty()
            if MyRun() then Send(WireRun(MyRun()), "GUILD") end
        end
    end)
end
