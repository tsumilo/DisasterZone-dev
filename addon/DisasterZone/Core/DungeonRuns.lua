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
--         nobody to ask: please say hello), g = 1 (I'm in a group: no invite reaches me) }   GUILD
--   DRQ {}                         WHISPER, after login, to one member known to run DisasterZone: the board, please
--   DRS { p = { { key, r, u, nn, nh, sv, g }, ... }, l = { run (as DRL, o = owner) }, dy }   WHISPER: the answer
--   DRL { id, d = dungeon index, h, at, c, no, s = { { k, r = role index, class (players outside the guild) } }, rv,
--         pv = the run it took over (the lead passed) }   GUILD, from the owner
--   DRX { id }                     GUILD: the owner took the run off the board
--   DRJ { id, r, b = 1 (BiS here) }   WHISPER to the owner: may I join as r?
--   DRC { id }                     WHISPER to the owner: never mind
--   DRA { id, ok = 1 | 0 }         WHISPER to the asker: invited / not this time
--   DRH { id, q = { { key, r, b } }, gf = 1 }   WHISPER to my party's new leader: the run is yours (the players
--                                  asking to join, and whether it was in the Group Finder)
-- A run is the owner's: only the owner changes it (a newer rv wins). The run goes with the party's lead: the new
-- leader lists it again as theirs, a new id naming the old one (pv), and every client swaps the two (asks follow). Somebody who logs in gets the whole board from one
-- member (DRS), runs of offline owners included; the owner's own profile (ids) clears the runs it no longer has.
-- Members known to run DisasterZone are remembered (db.runs[guildKey].known) so that a login asks just one of them.
--
-- The dungeon indices on the wire are the order of COMPLEXES below: never reorder, only append.
--
-- Groups (1.5): besides 5-man dungeons a run can be a raid, a group quest, PvP or anything else (Data/GroupKinds.lua).
-- Such a run has no d / h and instead k = kind key, a = { activity, ... } (raid keys | quest ids | one PvP key | one
-- "other" key), n = size, w = { tank, healer, dps } places; per kind lo = "roll" | "sr" | "lc" and lr = soft reserves
-- each (raids), bo = { boss key, ... } (raids, nil = full clear), pr = rated / mr = lowest rating / fc = wants a flag
-- carrier (PvP). On the wire DRL carries k = kind index, a = activity indices (quest ids as they are), n, w = { t, h,
-- d } and the per-kind fields, and no d: clients from before 1.5 drop such a DRL (ParseRun wants d), so they keep
-- seeing dungeon runs only. Dungeon runs go out exactly as before.
--   DRP adds uk = { kind index } (the kinds I'm up for; missing = dungeons only) and rs = { raid index } (the raids I'm
--       saved to this week); a digest entry carries them as its 8th and 9th fields.
--   DRS: a run's roster can be left out when the digest runs out of room (pt = 1, the owner only): the receiver asks
--       the owner for the whole run with DRR { id } (WHISPER), the owner whispers its DRL.
-- A run bigger than a party turns my party into a raid when the party is full; the run keeps going in the raid.
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
local REQUEST_TTL = 20 * 60        -- a request to join (both sides) is forgotten after this
local DECLINED_FOR = 10 * 60       -- "not this time": after this the player may ask again
local AUTO_ACCEPT_FOR = 10 * 60    -- the party invite of a run I asked to join this recently is accepted for me
local INVITE_FOR = 60              -- a party invite the addon answers runs out like Blizzard's pop-up (StaticPopupTimeoutSec)
local HANDOFF_WAIT = 10            -- after passing the lead: how long the new leader's DisasterZone has to take the run
local PEER_TTL = 15 * 60           -- a profile not heard of again (and its owner offline) is forgotten
local TICK = 20
local NO_GUILD = "~"
local MAX_SIZE = 40                -- the biggest group (a raid of 40)
local MAX_ACTIVITIES = 6           -- raids / quests one group lists at most
local RAID_LEVEL = 70
local ROSTER_ASK_EVERY = 30        -- a roster left out of a digest is asked for at most this often per run

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

-- Groups of the other kinds (Data/GroupKinds.lua), in wire order, plus the helpers that tell kinds apart. One table:
-- this file is close to Lua's 200 locals.
local GK = { kinds = {}, kindIndex = {}, raids = {}, raidIndex = {}, pvp = {}, pvpIndex = {}, other = {}, otherIndex = {},
             loot = {}, lootIndex = {} }
do
    local data = ns.Data and ns.Data.GroupKinds or {}
    for i, k in ipairs(data.kinds or { "dungeon" }) do GK.kinds[i] = k; GK.kindIndex[k] = i end
    for i, r in ipairs(data.raids or {}) do GK.raids[i] = r; GK.raidIndex[r.key] = i end
    for i, p in ipairs(data.pvp or {}) do GK.pvp[i] = p; GK.pvpIndex[p.key] = i end
    for i, o in ipairs(data.other or {}) do GK.other[i] = o; GK.otherIndex[o.key] = i end
    for i, l in ipairs(data.loot or {}) do GK.loot[i] = l; GK.lootIndex[l] = i end
    GK.art = data.art or {}
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

local Now, IsInt, DemoOn = Util.Now, Util.IsInt, Util.DemoOn
local function Me() return Util.PlayerKey() end
local function G() return ns.Guild end

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
    s = Util.Trim((tostring(s or ""):gsub("|", "")))
    if #s > NOTE_MAX then
        -- (1.4.1) cut between letters, never inside one (in UTF-8 the bytes 0x80-0xBF go on with the letter before);
        -- the cap stays NOTE_MAX bytes: a note that fits is kept whole
        local cut = NOTE_MAX
        while cut > 0 and (s:byte(cut + 1) or 0) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
        s = strsub(s, 1, cut)
    end
    return s
end

local function Invite(key)
    local name = Ambiguate and Ambiguate(key, "none") or key
    if C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(name) else InviteUnit(name) end
end

-- A delay of lo..hi seconds spread by my name and `salt` (members answer at different moments). Not math.random: the
-- rest of the addon draws its own jitters from it, and taking numbers out of turn would shift all of theirs.
local function Jitter(lo, hi, salt, fn)
    Util.After(lo + Util.Jitter(":" .. tostring(salt or ""), hi - lo), fn)
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
local guestRoles = {}              -- (owner) [key] = the role a player from outside the guild was invited as
local invite                       -- (me) the party invite the addon answers itself: { run = id, from = key, n }
local handoff                      -- (old owner) my run waiting for the new leader to take it: { id, to = key, n }
local demo                         -- demo mode's state (built on first use, never saved)

-- A guild member's runs before the guild key is known (GetGuildInfo answers nil for a few seconds after a login):
-- kept for this session only, and merged into the guild's bucket once the key arrives, so nothing learned in that
-- window lands in the no-guild bucket (or is lost there).
local early

local function Shape(b)
    b.list = type(b.list) == "table" and b.list or {}
    b.gone = type(b.gone) == "table" and b.gone or {}
    b.daily = type(b.daily) == "table" and b.daily or {}
    return b
end

-- The early bucket p into the guild's bucket b: runs by revision (a run gone in either stays gone), the newer daily
-- sighting, the members known to run DisasterZone.
local function MergeEarly(b, p)
    for id, x in pairs(p.gone) do
        if (tonumber(x) or 0) > (tonumber(b.gone[id]) or 0) then b.gone[id] = x end
    end
    for id, run in pairs(p.list) do
        local cur = b.list[id]
        if not ((tonumber(b.gone[id]) or 0) > Now()) and (not cur or (cur.rv or 0) < (run.rv or 0)) then
            b.list[id] = run
        end
    end
    for id in pairs(b.gone) do
        if p.gone[id] then b.list[id] = nil end
    end
    local d, e = b.daily, p.daily
    if (tonumber(e.x) or 0) > (tonumber(d.x) or 0)
        or ((tonumber(e.x) or 0) == (tonumber(d.x) or 0) and (tonumber(e.at) or 0) > (tonumber(d.at) or 0)) then
        b.daily = e
    end
    if type(p.known) == "table" then
        b.known = type(b.known) == "table" and b.known or {}
        for k, t in pairs(p.known) do
            if (tonumber(t) or 0) > (tonumber(b.known[k]) or 0) then b.known[k] = t end
        end
    end
end

local function Bucket(create)
    local db = ns.db
    if not db then return nil end
    local g = G()
    local gk = g and g.GetGuildKey and g:GetGuildKey()
    if not gk and IsInGuild() then
        if not early and create then early = Shape({}) end
        return early
    end
    gk = gk or NO_GUILD
    local b = ns.DB:GuildBucket("runs", (create or early) and true or false, gk)
    if b then Shape(b) end
    if early and b then
        local p = early
        early = nil
        MergeEarly(b, p)
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
    if guestRoles[key] then return guestRoles[key] end
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

local myNeeds = { n = {}, h = {}, r = {} }   -- [dkey] = { itemID, ... } (main picks first); r: raids (1.5)
local savedUntil = {}                -- [dkey] = server time a heroic lockout ends

-- My not-obtained picks of the view phase and of the Pre-raid list (both specs) that drop in a dungeon. Hint order:
-- the view phase's mains, its alts, then the Pre-raid mains and alts; the off spec after all of them in the same
-- order. A Pre-raid pick stops counting once I hold the view phase's main pick of that slot (I'm past it), and
-- when that slot is disabled in the view phase (it needs nothing this phase).
local function ComputeNeeds()
    BuildData()
    local out = { n = {}, h = {}, r = {} }
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
    -- (1.5) the raids: [raid key] = { { id, boss = "Raid:Boss" }, ... } (the item data's sources: tokens and
    -- upgrades count as their piece), main picks first
    local IDB = ns.ItemDB
    if IDB and IDB.GetSources then
        for _, o in ipairs(order) do
            for _, src in ipairs(IDB:GetSources(o.id, "raids")) do
                local rk = src.groupKey
                if rk and GK.raidIndex[rk] then
                    out.r[rk] = out.r[rk] or {}
                    out.r[rk][#out.r[rk] + 1] = { id = o.id, boss = src.ref and src.ref.key }
                end
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
    for key in pairs(GK.saved) do before["raid:" .. key] = true end
    wipe(savedUntil)
    wipe(GK.saved)
    if not (GetNumSavedInstances and GetSavedInstanceInfo) then return end
    local now = Now()
    local IDB = ns.ItemDB
    for i = 1, tonumber(GetNumSavedInstances()) or 0 do
        local name, _, reset, difficulty, locked, _, _, isRaid, _, difficultyName, numEncounters, encounterProgress, _,
            instanceId = GetSavedInstanceInfo(i)
        reset = tonumber(reset)
        -- (1.5) a raid lockout: by the raid's instance id (the item data's raid key)
        local raidKey = locked and isRaid and reset and reset > 0 and instanceId and IDB and IDB.ItemKeyOf
            and IDB:ItemKeyOf(instanceId)
        if raidKey and GK.raidIndex[raidKey] then
            GK.saved[raidKey] = { untilT = now + reset, done = tonumber(encounterProgress), total = tonumber(numEncounters) }
        end
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
    for key in pairs(GK.saved) do
        if not before["raid:" .. key] then changed = true end
        before["raid:" .. key] = nil
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

-- Kinds. A run without k (every run from before 1.5) is a 5-man dungeon run.
GK.saved = {}            -- my raid lockouts: [raid key] = { untilT, done, total }
GK.rosterAsked = {}      -- [run id] = Now() I last asked its owner for its roster
local GENERIC_FIELDS = { "k", "a", "n", "w", "lo", "lr", "bo", "pr", "mr", "fc", "tn" }

function GK.IsDungeon(run) return run.k == nil or run.k == "dungeon" end
function GK.Kind(run) return run.k or "dungeon" end
function GK.Size(run)
    if GK.IsDungeon(run) then return PARTY_SIZE end
    return tonumber(run.n) or PARTY_SIZE
end
-- The places per role: { tank = n, healer = n, dps = n }.
function GK.Want(run)
    if GK.IsDungeon(run) or type(run.w) ~= "table" then return NEED end
    return run.w
end

-- A copy of a run's kind fields (tables copied, not shared).
function GK.Copy(from, to)
    for _, f in ipairs(GENERIC_FIELDS) do
        local v = from[f]
        if type(v) == "table" then
            local c = {}
            for k2, x in pairs(v) do c[k2] = x end
            v = c
        end
        to[f] = v
    end
    return to
end

-- Is the run's activity one I know? (a dungeon of the list; raids of the list; quest ids; one PvP / other key)
function GK.Valid(run)
    if GK.IsDungeon(run) then return DUNGEON[run.d] ~= nil end
    local kind = run.k
    if not GK.kindIndex[kind] or type(run.a) ~= "table" or #run.a == 0 or #run.a > MAX_ACTIVITIES then return false end
    if (kind == "pvp" or kind == "other") and #run.a ~= 1 then return false end
    for _, x in ipairs(run.a) do
        if (kind == "raid" and not GK.raidIndex[x]) or (kind == "quest" and not IsInt(x, 1))
            or (kind == "pvp" and not GK.pvpIndex[x]) or (kind == "other" and not GK.otherIndex[x]) then
            return false
        end
    end
    return true
end

-- The run's name: "Botanica" / "Gruul's Lair + Magtheridon's Lair" / "Arena 3v3" / "Attunement".
function GK.Name(run)
    if GK.IsDungeon(run) then
        local d = DUNGEON[run.d]
        return d and d.name or tostring(run.d)
    end
    local parts = {}
    for _, x in ipairs(run.a or {}) do
        local name
        if run.k == "raid" then
            local raid = ns.ItemDB and ns.ItemDB.GetRaid and ns.ItemDB:GetRaid(x)
            name = raid and raid.name
        elseif run.k == "pvp" then
            name = GK.pvp[GK.pvpIndex[x] or 0] and GK.pvp[GK.pvpIndex[x]].name
        elseif run.k == "other" then
            name = GK.other[GK.otherIndex[x] or 0] and GK.other[GK.otherIndex[x]].name
        else
            local GQ = ns.GroupQuests
            name = (GQ and GQ.GetName and GQ:GetName(x)) or ("Quest " .. tostring(x))
        end
        parts[#parts + 1] = name or tostring(x)
    end
    return tconcat(parts, " + ")
end

-- The places a group of `kind` and `n` players lists by default: { tank, healer, dps }.
function GK.DefaultWant(kind, n, key)
    if kind == "pvp" then
        local p = GK.pvp[GK.pvpIndex[key] or 0]
        if p and p.mode == "arena" then return { tank = 0, healer = n >= 5 and 2 or 1, dps = n - (n >= 5 and 2 or 1) } end
        local h = floor(n * 0.27 + 0.5)
        return { tank = 0, healer = h, dps = n - h }
    end
    if n >= 40 then return { tank = 4, healer = 10, dps = n - 14 } end
    if n >= 25 then return { tank = 3, healer = 6, dps = n - 9 } end
    if n >= 10 then return { tank = 2, healer = 3, dps = n - 5 } end
    if n >= 5 then return { tank = 1, healer = 1, dps = n - 2 } end
    return { tank = n >= 3 and 1 or 0, healer = 1, dps = max(0, n - (n >= 3 and 2 or 1)) }
end

-- A group of another kind from List's options: the run's kind fields, or nil and why.
function GK.FromOpts(opts)
    local kind = opts.k
    if kind == "dungeon" or not GK.kindIndex[kind] then return nil, "Pick what the group is for." end
    local a = {}
    for _, x in ipairs(type(opts.a) == "table" and opts.a or { opts.a }) do
        if kind == "quest" and ns.GroupQuests then x = ns.GroupQuests:Key(x) or x end
        a[#a + 1] = x
    end
    local run = { k = kind, a = a }
    if not GK.Valid(run) then return nil, "Pick what the group is for." end
    local n
    if kind == "raid" then
        n = 10
        for _, x in ipairs(a) do n = max(n, GK.raids[GK.raidIndex[x]].size or 25) end
    elseif kind == "pvp" then
        n = GK.pvp[GK.pvpIndex[a[1]]].size
    elseif kind == "quest" then
        n = 2
        for _, id in ipairs(a) do
            local q = ns.GroupQuests and ns.GroupQuests:Get(id)
            n = max(n, q and q.players or 3)
        end
        n = min(n, PARTY_SIZE)
    else
        n = 5
    end
    if opts.n ~= nil and kind ~= "pvp" then n = tonumber(opts.n) end
    if not IsInt(n, 2, MAX_SIZE) then return nil, "A group is 2 to " .. MAX_SIZE .. " players." end
    local w = GK.DefaultWant(kind, n, a[1])
    if type(opts.w) == "table" then
        w = { tank = tonumber(opts.w.tank) or 0, healer = tonumber(opts.w.healer) or 0, dps = tonumber(opts.w.dps) or 0 }
    end
    if kind == "pvp" then w.tank = 0 end
    for _, role in ipairs(ROLES) do
        if not IsInt(w[role], 0, n) then return nil, "Places must be whole numbers." end
    end
    if w.tank + w.healer + w.dps > n then return nil, "More places than players." end
    run.n, run.w = n, w
    if kind == "raid" then
        run.lo = GK.lootIndex[opts.lo] and opts.lo or "roll"
        if run.lo == "sr" then run.lr = IsInt(opts.lr, 1, 3) and opts.lr or 1 end
        if type(opts.bo) == "table" and #opts.bo > 0 then
            run.bo = {}
            for i, b in ipairs(opts.bo) do
                if i <= 20 and type(b) == "string" and #b <= 48 then run.bo[#run.bo + 1] = b end
            end
        end
    elseif kind == "pvp" then
        local p = GK.pvp[GK.pvpIndex[a[1]]]
        if p.mode == "arena" and opts.pr then
            local team = ns.GroupPvP and ns.GroupPvP:GetTeam(p.bracket)
            if not team then return nil, "Rated games need your " .. p.bracket .. "v" .. p.bracket .. " team." end
            run.pr = true
            run.mr = IsInt(opts.mr, 0, 5000) and opts.mr or nil
            run.tn = team.name:sub(1, 24)
        end
        if p.mode == "bg" and opts.fc then run.fc = true end
    elseif kind == "quest" then
        local why = GK.QuestRule(a)
        if why then return nil, why end
    end
    return run
end

-- The kind fields of a DRL into run: false when malformed.
function GK.Parse(msg, run)
    local kind = IsInt(msg.k, 2, #GK.kinds) and GK.kinds[msg.k]
    if not kind or type(msg.a) ~= "table" or #msg.a < 1 or #msg.a > MAX_ACTIVITIES then return false end
    local a = {}
    for _, x in ipairs(msg.a) do
        local v
        if kind == "raid" then v = IsInt(x, 1, #GK.raids) and GK.raids[x].key
        elseif kind == "quest" then v = IsInt(x, 1, 999999) and x
        elseif kind == "pvp" then v = IsInt(x, 1, #GK.pvp) and GK.pvp[x].key
        else v = IsInt(x, 1, #GK.other) and GK.other[x].key end
        if not v then return false end
        a[#a + 1] = v
    end
    local w = msg.w
    if not IsInt(msg.n, 2, MAX_SIZE) or type(w) ~= "table" then return false end
    for i = 1, 3 do
        if not IsInt(w[i], 0, MAX_SIZE) then return false end
    end
    if w[1] + w[2] + w[3] > msg.n then return false end
    run.k, run.a, run.n, run.w = kind, a, msg.n, { tank = w[1], healer = w[2], dps = w[3] }
    if not GK.Valid(run) then return false end
    if kind == "raid" then
        run.lo = IsInt(msg.lo, 1, #GK.loot) and GK.loot[msg.lo] or nil
        run.lr = IsInt(msg.lr, 1, 3) and msg.lr or nil
        if type(msg.bo) == "table" and #msg.bo <= 20 then
            local bo = {}
            for _, b in ipairs(msg.bo) do
                if type(b) == "string" and #b <= 48 then bo[#bo + 1] = b end
            end
            run.bo = #bo > 0 and bo or nil
        end
    elseif kind == "pvp" then
        run.pr = (msg.pr == 1) or nil
        run.mr = IsInt(msg.mr, 0, 5000) and msg.mr or nil
        run.fc = (msg.fc == 1) or nil
        run.tn = (run.pr and type(msg.tn) == "string" and #msg.tn <= 24) and msg.tn or nil
    end
    return true
end

-- The kind fields of a run into a DRL.
function GK.Wire(run, msg)
    local kind = run.k
    msg.k = GK.kindIndex[kind]
    local a = {}
    for _, x in ipairs(run.a or {}) do
        if kind == "raid" then a[#a + 1] = GK.raidIndex[x]
        elseif kind == "pvp" then a[#a + 1] = GK.pvpIndex[x]
        elseif kind == "other" then a[#a + 1] = GK.otherIndex[x]
        else a[#a + 1] = x end
    end
    local w = GK.Want(run)
    msg.a, msg.n, msg.w = a, run.n, { w.tank or 0, w.healer or 0, w.dps or 0 }
    msg.lo = run.lo and GK.lootIndex[run.lo] or nil
    msg.lr, msg.bo = run.lr, run.bo
    msg.pr, msg.mr, msg.fc, msg.tn = run.pr and 1 or nil, run.mr, run.fc and 1 or nil, run.tn
end

-- Why I can't join a group, or nil (a dungeon: the heroic key, lockout, level); second return: the reason's kind.
function GK.Blocker(run)
    if GK.IsDungeon(run) then return Runs:GetBlocker(run.d, run.h) end
    if run.k == "pvp" then return GK.PvPBlocker(run) end
    if run.k ~= "raid" then return nil end
    local level = UnitLevel and tonumber(UnitLevel("player"))
    if level and level > 0 and level < RAID_LEVEL then return "Needs level " .. RAID_LEVEL, "level" end
    local saved = {}
    for _, key in ipairs(run.a or {}) do
        local s = GK.saved[key]
        if not (s and s.untilT > Now()) then return nil end
        saved[#saved + 1] = key
    end
    if #saved == 1 then
        local s = GK.saved[saved[1]]
        local raid = ns.ItemDB and ns.ItemDB.GetRaid and ns.ItemDB:GetRaid(saved[1])
        local done = (IsInt(s.total, 1) and IsInt(s.done, 0)) and (" (" .. s.done .. " of " .. s.total .. ")") or ""
        return "You're saved to " .. (raid and raid.name or saved[1]) .. done, "saved"
    end
    return "You're saved to all of them", "saved"
end

-- (1.5) Planned raids (Core/RaidPlan.lua) that fill open places: groups of the board built from the raid's own
-- roster (its Accepted and Tentative answers, its comp's open places), "rp:<raid id>"; asking is the raid's sign-up
-- (a join request for a locked raid). Within the next week, while places are open. Cached for a second.
local bridgeCache, bridgeAt = {}, -1
local COMP_ROLE = { tank = "tank", healer = "healer" }
function GK.Bridge()
    local RP = ns.RaidPlan
    if not (RP and RP.GetRaids and RP.GetRaidOpenSlots) then return {} end
    local t = GetTime and GetTime() or 0
    if t - bridgeAt < 1 then return bridgeCache end
    bridgeAt = t
    local out, now = {}, Now()
    for _, v in ipairs(RP:GetRaids(now - 3 * 3600, now + 7 * 86400)) do
        local open = v.fo and not v.cancelled and RP:GetRaidOpenSlots(v)
        if open and (open.openCount or 0) > 0 then
            local a = {}
            for _, key in ipairs(RP:GetRaidInstances(v)) do
                local rk = ns.ItemDB and ns.ItemDB.ItemKeyOf and ns.ItemDB:ItemKeyOf(key)
                if rk and GK.raidIndex[rk] then a[#a + 1] = rk end
            end
            if #a > 0 then
                local s, w = {}, { tank = 0, healer = 0, dps = 0 }
                for key, su in pairs(RP:GetSignups(v.id)) do
                    if su.st == "A" or su.st == "T" then
                        local role = ns.RaidComp and su.c and ns.RaidComp:RoleOf(su.c, su.sp)
                        role = COMP_ROLE[role] or "dps"
                        s[#s + 1] = { k = key, r = role, c = su.c }
                        w[role] = w[role] + 1
                    end
                end
                for _, slot in ipairs(open.slots or {}) do
                    local role = COMP_ROLE[slot.role] or "dps"
                    w[role] = w[role] + 1
                end
                local n = v.sz or open.size or 25
                out[#out + 1] = { id = "rp:" .. v.id, rp = v.id, o = RP:GetRaidLeader(v) or v.by, k = "raid", a = a,
                                  n = n, w = w, s = s, at = v.t, c = v.rev or now, lo = "lc", team = open.teamName,
                                  no = (open.teamName and (open.teamName .. " raid: ") or "Planned raid: ")
                                      .. open.openCount .. " open " .. (open.openCount == 1 and "place" or "places") }
            end
        end
    end
    bridgeCache = out
    return out
end

-- Asks to join a planned raid from the board: its sign-up (Accepted), a join request when the raid is locked.
function GK.BridgeJoin(run)
    local RP = ns.RaidPlan
    if not RP then return false, "The raid planner isn't loaded." end
    local block = GK.Blocker(run)
    if block then return false, block end
    local ok, err = RP:SignUp(run.rp, "A")
    bridgeAt = -1
    Changed()
    return ok and true or false, err
end

-- (1.5) A profile's group quests: { [key] = true }.
function GK.ReadQuests(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for i, id in ipairs(list) do
        if i > 30 then break end
        if IsInt(id, 1, 999999) then out[id] = true end
    end
    return out
end

-- Why quests can't be one group, or nil: quests of one zone make a group; a quest another guildie's group already
-- lists is joined there.
function GK.QuestRule(keys)
    local GQ = ns.GroupQuests
    if not GQ then return nil end
    local zone
    for _, id in ipairs(keys) do
        local q = GQ:Get(id)
        if q then
            if zone and q.zone ~= zone then return "Quests of one zone make one group." end
            zone = q.zone
        end
    end
    for _, id in ipairs(keys) do
        local other = Runs:GetQuestGroup(id)
        if other then
            return Util.ShortName(other.o) .. " already has a group for " .. (GQ:GetName(id) or "it") .. ": join it."
        end
    end
    return nil
end

-- A rated arena group is its team's: a guildie on another team of that bracket can't join.
function GK.PvPBlocker(run)
    local p = GK.pvp[GK.pvpIndex[run.a and run.a[1]] or 0]
    if not (p and p.mode == "arena" and run.pr and run.tn) then return nil end
    local mine = ns.GroupPvP and ns.GroupPvP:GetTeam(p.bracket)
    if mine and mine.name ~= run.tn then
        return "You're on another " .. p.bracket .. "v" .. p.bracket .. " team", "team"
    end
    return nil
end

-- Does a quest group want a ping from me: one of its quests is in my log.
function GK.HasQuestOf(run)
    local GQ = ns.GroupQuests
    if run.k ~= "quest" or not GQ then return false end
    for _, id in ipairs(run.a or {}) do
        if GQ:IsInMyLog(id) then return true end
    end
    return false
end

-- (owner) A newcomer to my rated arena group gets a team invite first.
function GK.TeamInvite(run, key)
    local p = GK.pvp[GK.pvpIndex[run.a and run.a[1]] or 0]
    if not (p and p.mode == "arena" and run.pr and ns.GroupPvP) then return end
    local team = ns.GroupPvP:GetTeam(p.bracket)
    if not team then return end
    for _, m in ipairs(team.members) do
        if m == key then return end
    end
    ns.GroupPvP:InviteToTeam(p.bracket, key)
end

-- (owner) I turned in a quest: my quest group ends once none of its quests is left in my log.
function GK.OnQuestDone()
    local run = Runs:GetMyGroup()
    if not run or run.k ~= "quest" or not ns.GroupQuests then return end
    if run.at and run.at > Now() then return end
    for _, id in ipairs(run.a or {}) do
        if ns.GroupQuests:IsInMyLog(id) then return end
    end
    Runs:Unlist(true)
end

-- The kinds of groups I'm up for: { dungeon = true, raid = true, ... } (dungeons and raids unless I picked).
function GK.MyKinds(p)
    if type(p.kinds) == "table" and next(p.kinds) then return p.kinds end
    return { dungeon = true, raid = true }
end

local function Expired(run, now)
    now = now or Now()
    if (run.at or 0) > 0 then return now > run.at + LATER_GRACE end
    return now > (run.c or 0) + NOW_TTL
end

-- The places of a run, tanks first: { key, role, class, you } or { empty = true, role } (the roles still open: a 5-man
-- run wants one tank, one healer, three DPS; a group of another kind its own places, GK.Want).
local function Slots(run)
    local size, need = GK.Size(run), GK.Want(run)
    local filled = {}
    for i, s in ipairs(run.s or {}) do
        if i > size then break end
        filled[#filled + 1] = { key = s.k, role = ROLE_INDEX[s.r] and s.r or "dps", class = ClassOf(s.k) or s.c,
                                you = Util.IsMe(s.k) or nil, owner = (s.k == run.o) or nil }
    end
    tsort(filled, function(a, b)
        if a.role ~= b.role then return ROLE_INDEX[a.role] < ROLE_INDEX[b.role] end
        if (a.owner and 1 or 0) ~= (b.owner and 1 or 0) then return a.owner ~= nil end
        return a.key < b.key
    end)
    local count = { tank = 0, healer = 0, dps = 0 }
    for _, f in ipairs(filled) do count[f.role] = count[f.role] + 1 end
    local free = size - #filled
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
        if role ~= "dps" then addEmpty(role, max(0, (need[role] or 0) - count[role])) end
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
    for _, x in ipairs(run.s or {}) do s[#s + 1] = { x.k, ROLE_INDEX[x.r] or 3, x.c } end
    local msg = { t = "DRL", id = run.id, at = run.at or 0, c = run.c, no = run.no, s = s, rv = run.rv,
                  o = relay and run.o or nil, pv = run.pv }
    if GK.IsDungeon(run) then
        local d = DUNGEON[run.d]
        msg.d, msg.h = d and d.i, run.h and 1 or nil
    else
        GK.Wire(run, msg)
    end
    return msg
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
    local uk, rs = {}, {}
    local kinds = GK.MyKinds(p)
    for i, kind in ipairs(GK.kinds) do
        if kinds[kind] then uk[#uk + 1] = i end
    end
    for i, raid in ipairs(GK.raids) do
        local s = GK.saved[raid.key]
        if s and s.untilT > Now() then rs[#rs + 1] = i end
    end
    local nr = {}
    for i, raid in ipairs(GK.raids) do
        if myNeeds.r and myNeeds.r[raid.key] then nr[#nr + 1] = i end
    end
    local msg = { t = "DRP", r = r, u = ((p.up or 0) > Now()) and p.up or 0, nn = nn, nh = nh, ids = ids, q = q,
                  sv = sv, g = Runs:IsGrouped() and 1 or nil, uk = uk, rs = rs, nr = nr }
    -- (1.5) the group quests in my log, my arena teams
    msg.gq = ns.GroupQuests and ns.GroupQuests:GetMine() or nil
    msg.ap = ns.GroupPvP and ns.GroupPvP:ProfileList() or nil
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
    -- (1.5) a group of another kind has k and no d; clients from before 1.5 stop at the d check below
    local generic = msg.k ~= nil
    if type(msg.id) ~= "string" or #msg.id > 64 or (not generic and not IsInt(msg.d, 1, #ORDER)) then return nil end
    if not IsInt(msg.c, 0) or not IsInt(msg.rv, 0) or (msg.at ~= nil and not IsInt(msg.at, 0)) then return nil end
    local owner = sender
    if msg.o ~= nil then
        owner = type(msg.o) == "string" and Util.NormalizeName(msg.o) or nil
        if not owner then return nil end
    end
    local s, seen = {}, {}
    local limit = generic and (IsInt(msg.n, 2, MAX_SIZE) and msg.n or 0) or PARTY_SIZE
    if type(msg.s) ~= "table" or #msg.s > limit then return nil end
    for _, x in ipairs(msg.s) do
        local k = type(x) == "table" and type(x[1]) == "string" and Util.NormalizeName(x[1])
        local r = type(x) == "table" and IsInt(x[2], 1, 3) and ROLES[x[2]]
        if not k or not r or seen[k] then return nil end
        seen[k] = true
        -- (a player from outside the guild comes with their class: nobody else's roster knows it)
        local c = type(x[3]) == "string" and CLASS_ROLES[x[3]] and x[3] or nil
        s[#s + 1] = { k = k, r = r, c = c }
    end
    local pv = (type(msg.pv) == "string" and #msg.pv <= 64 and msg.pv ~= msg.id) and msg.pv or nil
    local run = { id = msg.id, o = owner, at = msg.at or 0, c = msg.c, s = s, rv = msg.rv, pv = pv,
                  no = type(msg.no) == "string" and TrimNote(msg.no) or nil, pt = (msg.pt == 1) or nil }
    if generic then
        if not GK.Parse(msg, run) then return nil end
    else
        run.d, run.h = ORDER[msg.d], (msg.h == 1) or nil
    end
    return run
end

local Renamed   -- forward

local function StoreRun(run)
    local st = State()
    local gone = st.gone[run.id]
    if gone and (tonumber(gone) or 0) > Now() then return false end
    local cur = st.list[run.id]
    -- (a run whose roster a digest left out takes its whole roster at the same revision)
    local completes = cur and cur.pt and not run.pt and (cur.rv or 0) == (run.rv or 0)
    if cur and (cur.rv or 0) >= (run.rv or 0) and not completes then return false end
    if Expired(run) then return false end
    local fresh = cur == nil
    st.list[run.id] = run
    if run.pv then Renamed(run) end
    if run.pt then GK.AskRoster(run) end
    Changed()
    MaybePing(run, fresh)
    return true
end

-- A run whose roster a digest left out: its owner whispers the whole run (at most every ROSTER_ASK_EVERY).
function GK.AskRoster(run)
    if DemoOn() or not IsOnline(run.o) or Now() - (GK.rosterAsked[run.id] or -1e9) < ROSTER_ASK_EVERY then return end
    GK.rosterAsked[run.id] = Now()
    Send({ t = "DRR", id = run.id }, "WHISPER", run.o)
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

-- A run that took over another one (its party's lead passed: run.pv = the old id). The old run leaves the board when
-- the two parties share a member: its owner is in the new one, or the new owner was in the old one (the old owner
-- left). Only a member of the party can end a run that way. My question and my ping follow the run. The old owner
-- tells the guild its runs at once, so clients from before runs followed the lead drop the old one too.
local renamed = {}   -- [old id] = new id (share links to the old run find the new one)

Renamed = function(run)
    local pv = run.pv
    renamed[pv] = run.id
    local old = State().list[pv]
    if old and old.o ~= run.o and (InRun(run, old.o) or InRun(old, run.o)) then
        if old.o == Me() then
            handoff = nil
            ns:Print("%s leads your run now.", Util.ShortName(run.o) or run.o)
            DropRun(pv, true)
            SendProfile()
        else
            DropRun(pv, true)
        end
    end
    local asked = Asked()
    if asked[pv] then
        asked[run.id] = asked[run.id] or asked[pv]
        asked[pv] = nil
    end
    if pinged[pv] then pinged[run.id] = true end
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
local function ReadProfile(r, u, nn, nh, ids, sv, g, uk, rs, nr, gq, ap)
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
    -- (1.5) the kinds they're up for (a client from before: dungeons only) and the raids they're saved to
    local kinds, raids, raidNeeds = { dungeon = true }, {}, {}
    if type(nr) == "table" then
        for _, i in ipairs(nr) do
            if IsInt(i, 1, #GK.raids) then raidNeeds[GK.raids[i].key] = true end
        end
    end
    if type(uk) == "table" then
        kinds = {}
        for _, i in ipairs(uk) do
            if IsInt(i, 1, #GK.kinds) then kinds[GK.kinds[i]] = true end
        end
    end
    if type(rs) == "table" then
        for _, i in ipairs(rs) do
            if IsInt(i, 1, #GK.raids) then raids[GK.raids[i].key] = true end
        end
    end
    return { roles = roles, up = IsInt(u, 0) and u or 0, nn = set(nn), nh = set(nh), ids = idset, seen = Now(),
             saved = set(sv), savedUntil = Now() + left, grouped = (g == 1) or nil, kinds = kinds, raids = raids,
             raidNeeds = raidNeeds, quests = GK.ReadQuests(gq), arena = ns.GroupPvP and ns.GroupPvP:ReadList(ap) or {} }
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
    local p = ReadProfile(msg.r, msg.u, msg.nn, msg.nh, msg.ids, msg.sv, msg.g, msg.uk, msg.rs, msg.nr, msg.gq,
        msg.ap)
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
    local p = { { Me(), mine.r, mine.u, mine.nn, mine.nh, mine.sv, mine.g or false, mine.uk, mine.rs, mine.nr,
                  mine.gq or false, mine.ap or false } }
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
        local uk, rs, nr = {}, {}, {}
        for i, raid in ipairs(GK.raids) do
            if peer.raidNeeds and peer.raidNeeds[raid.key] then nr[#nr + 1] = i end
        end
        for i, kind in ipairs(GK.kinds) do
            if peer.kinds and peer.kinds[kind] then uk[#uk + 1] = i end
        end
        for i, raid in ipairs(GK.raids) do
            if (peer.savedUntil or 0) > Now() and peer.raids and peer.raids[raid.key] then rs[#rs + 1] = i end
        end
        local gq, ap = {}, {}
        for k in pairs(peer.quests or {}) do if #gq < 30 then gq[#gq + 1] = k end end
        for b, t in pairs(peer.arena or {}) do ap[#ap + 1] = { b, t.rating, t.name } end
        p[#p + 1] = { key, r, peer.up or 0, nn, nh, sv, peer.grouped and 1 or false, uk, rs, nr, gq, ap }
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
    -- small groups first: what doesn't fit goes from the end
    tsort(l, function(a, b)
        if #a.s ~= #b.s then return #a.s < #b.s end
        return a.id < b.id
    end)
    local msg = { t = "DRS", p = p, l = l, dy = mine.dy }
    local Comm = ns.Comm
    while Comm and Comm.Fits do
        local _, wire, inflated = Comm:Fits(msg)
        if (wire or 0) <= DIGEST_WIRE and (inflated or 0) <= DIGEST_INFLATED then break end
        -- first the biggest roster still in goes (its owner sends it on request), then profiles, then runs
        local big
        for _, x in ipairs(l) do
            if not x.pt and #x.s > PARTY_SIZE and (not big or #x.s > #big.s) then big = x end
        end
        if big then
            local owner = {}
            for _, x in ipairs(big.s) do
                if Util.NormalizeName(x[1]) == big.o then owner[1] = x end
            end
            big.s, big.pt = owner, 1
        elseif #p > 1 then p[#p] = nil elseif #l > 0 then l[#l] = nil else break end
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
            peers[key] = ReadProfile(e[2], e[3], e[4], e[5], nil, e[6], e[7], e[8], e[9], e[10], e[11], e[12])
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

-- (owner) Somebody got my run from a digest without its roster: the whole run, to them.
function GK.OnRosterAsk(sender, msg, dist)
    if dist ~= "WHISPER" or not InGuild(sender) or type(msg.id) ~= "string" then return end
    local mine = MyRun()
    if not mine or mine.id ~= msg.id then return end
    local Comm = ns.Comm
    if Comm and Comm.RateLimit and not Comm:RateLimit("DRR:" .. sender, 10) then return end
    Send(WireRun(mine), "WHISPER", sender)
end

local function OnUnlist(sender, msg)
    if type(msg.id) ~= "string" then return end
    local run = State().list[msg.id]
    if run and run.o == sender then DropRun(msg.id) end
end

local function OnJoin(sender, msg)
    if not InGuild(sender) then return end
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

-- (asker) The leader's answer. Invited: if I'm not in the party once an invite would have run out (it failed, or I
-- said no in Blizzard's pop-up), I'm asking again. Not this time: I may ask again after DECLINED_FOR.
local function OnAnswer(sender, msg)
    local run = type(msg.id) == "string" and State().list[msg.id]
    local a = run and Asked()[run.id]
    if not a or run.o ~= sender then return end
    if msg.ok == 1 then
        a.st = "invited"
        local id = run.id
        Util.After(INVITE_FOR + 5, function()
            local cur = Asked()[id]
            local r = Runs:GetGroup(id)
            if cur == a and a.st == "invited" and not (r and InRun(r, Me())) and not (invite and invite.run == id) then
                a.st = "asked"
                Changed()
            end
        end)
    else
        a.st, a.dt = "declined", Now()
    end
    Changed()
end

-- Blizzard's answers to my invites ("Bert declines your group invitation.", "Bert is already in a group.", "Cannot
-- find player 'Bert'."): an invite that went nowhere puts its player back to asking, so the leader can invite them
-- again; Core/GroupFinder.lua does the same for its pugs (PARTY_INVITE_FAILED).
local inviteFails

local function InviteFailPatterns()
    if inviteFails then return inviteFails end
    inviteFails = {}
    for _, fmt in ipairs({ ERR_DECLINE_GROUP_S, ERR_ALREADY_IN_GROUP_S, ERR_BAD_PLAYER_NAME_S }) do
        if type(fmt) == "string" and strfind(fmt, "%s", 1, true) then
            local pat = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)")
            inviteFails[#inviteFails + 1] = "^" .. pat .. "$"
        end
    end
    return inviteFails
end

local function OnSystem(_, text)
    if type(text) ~= "string" then return end
    for _, pat in ipairs(InviteFailPatterns()) do
        local name = string.match(text, pat)
        local key = name and Util.NormalizeName(name)
        if key then
            local run = MyRun()
            local req = run and Requests()[run.id] and Requests()[run.id][key]
            if req and req.st == "invited" then
                req.st = "asked"
                Changed()
            end
            ns:Fire("PARTY_INVITE_FAILED", key)
            return
        end
    end
end

---------------------------------------------------------------------------
-- My run and the group
---------------------------------------------------------------------------

local HandOff   -- forward

-- My run's party from my group: me, then the members (with the role each asked for / plays).
local function SyncMyParty()
    if DemoOn() then return end
    local run = MyRun()
    if not run then return end
    -- a raid: my 5-man run is over (a bigger group goes on in it); somebody else leads my group: the run goes with
    -- the lead (or ends)
    if IsInRaid() and GK.Size(run) <= PARTY_SIZE then
        Runs:Unlist(true)
        return
    end
    if IsInGroup() and not UnitIsGroupLeader("player") then
        HandOff(run)
        return
    end
    -- I left my run's party (the others stayed together, or it broke up): the one who leads it now may take the run
    -- (CheckLead on their side); mine shrinks to me only if nobody does within HANDOFF_WAIT
    if not IsInGroup() and #(run.s or {}) > 1 then
        if handoff and handoff.id == run.id and handoff.left then return end
        if not (handoff and handoff.id == run.id and handoff.done) then
            local n = ((handoff and handoff.n) or 0) + 1
            handoff = { id = run.id, left = true, n = n }
            Util.After(HANDOFF_WAIT, function()
                if handoff and handoff.n == n then
                    handoff = { id = run.id, done = true, n = n }
                    SyncMyParty()
                end
            end)
            return
        end
    end
    handoff = nil
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
        -- a player from outside the guild: their class goes with the party (nobody else's roster has it)
        local c = (not InGuild(key) and Util.group[key]) and Util.group[key].classFile or nil
        s[#s + 1] = { k = key, r = prev or RoleOf(key, run.id), c = c }
    end
    local same = #s == #(run.s or {})
    if same then
        for i, x in ipairs(s) do
            local y = run.s[i]
            if not y or y.k ~= x.k or y.r ~= x.r or y.c ~= x.c then same = false break end
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
    if #s >= GK.Size(run) then
        ns:Print("%s is full: taken off the board. Have fun!", GK.Name(run))
        Runs:Unlist(true)
        return
    end
    GK.MakeRoom(run)
    Changed()
    BroadcastRun(run)
end

-- (owner) A group bigger than a party whose party is full: my party becomes a raid. True when it converted (the
-- next invite waits for the raid).
function GK.MakeRoom(run)
    if DemoOn() or GK.Size(run) <= PARTY_SIZE or IsInRaid() or not IsInGroup() then return false end
    if (GetNumGroupMembers() or 0) < PARTY_SIZE or not UnitIsGroupLeader("player") or not ConvertToRaid then return false end
    ConvertToRaid()
    return true
end

---------------------------------------------------------------------------
-- Passing the lead: the run goes with it
---------------------------------------------------------------------------

-- My group's leader (not me), or nil. (1.5: a raid's too: a bigger group goes on in a raid.)
local function GroupLeader()
    if not IsInGroup() then return nil end
    local raid = IsInRaid()
    local n = raid and (tonumber(GetNumGroupMembers()) or 0) or (PARTY_SIZE - 1)
    for i = 1, n do
        local unit = (raid and "raid" or "party") .. i
        if UnitExists(unit) and UnitIsGroupLeader(unit) then
            local name, realm = UnitName(unit)
            if type(name) == "string" and name ~= "" and name ~= UNKNOWNOBJECT then
                local key = Util.NormalizeName((type(realm) == "string" and realm ~= "") and (name .. "-" .. realm) or name)
                if not Util.IsMe(key) then return key end
            end
        end
    end
    return nil
end

-- (owner) Somebody else leads my group now. A member of my run's party who got the lead: their DisasterZone takes
-- the run (DRH tells it who asked to join); no answer in HANDOFF_WAIT (no DisasterZone), or a leader from outside
-- the guild: the run ends. A leader from outside my run (I joined another group): the run ends.
HandOff = function(run)
    local to = GroupLeader()
    if not to then return end   -- the roster isn't in yet: the next update decides
    if not InRun(run, to) then
        handoff = nil
        ns:Print("You joined %s's group: your run is off the board.", Util.ShortName(to) or to)
        Runs:Unlist(true)
        return
    end
    if not InGuild(to) then
        handoff = nil
        ns:Print("%s leads your group now and isn't in the guild: your run is off the board.",
            Util.ShortName(to) or to)
        Runs:Unlist(true)
        return
    end
    if handoff and handoff.id == run.id and handoff.to == to then return end
    local n = ((handoff and handoff.n) or 0) + 1
    handoff = { id = run.id, to = to, n = n }
    local q = {}
    for key, r in pairs(Requests()[run.id] or {}) do
        if Now() - (r.at or 0) < REQUEST_TTL then q[#q + 1] = { key, ROLE_INDEX[r.r] or 3, r.b and 1 or nil } end
    end
    local GF = ns.GroupFinder
    local gf = (run.gf or (GF and GF.HasListed and GF:HasListed(run.id))) and 1 or nil
    Send({ t = "DRH", id = run.id, q = q, gf = gf }, "WHISPER", to)
    Changed()
    Util.After(HANDOFF_WAIT, function()
        if not (handoff and handoff.n == n) then return end
        handoff = nil
        local mine = MyRun()
        if mine and mine.id == run.id then
            -- a member whose profile I've seen runs DisasterZone, only one from before runs followed the lead
            ns:Print("%s leads your group now but %s: your run is off the board.", Util.ShortName(to) or to,
                Peers()[to] and "has an older DisasterZone" or "has no DisasterZone")
            Runs:Unlist(true)
        end
    end)
end

-- (new owner) The players who asked the old leader to join: now they ask me.
local function TakeRequests(run, q)
    if type(q) ~= "table" then return end
    local reqs = Requests()
    reqs[run.id] = reqs[run.id] or {}
    for _, e in ipairs(q) do
        local key = type(e) == "table" and type(e[1]) == "string" and Util.NormalizeName(e[1])
        if key and IsInt(e[2], 1, 3) and not Util.IsMe(key) and not InRun(run, key) and not reqs[run.id][key] then
            reqs[run.id][key] = { r = ROLES[e[2]], b = (e[3] == 1) or nil, at = Now(), st = "asked" }
        end
    end
end

-- (new leader) Takes over a run of my party whose owner no longer leads it: a run of mine (my id) that names the old
-- one, same dungeon, time, note and places. Returns the run, or nil when it isn't mine to take.
local function Adopt(old, q, gf)
    if DemoOn() or not old or old.o == Me() or Expired(old) then return nil end
    local mine = MyRun()
    if mine then
        if mine.pv ~= old.id then return nil end
        TakeRequests(mine, q)
        if gf then mine.gf = true end
        Changed()
        return mine
    end
    if (IsInRaid() and GK.Size(old) <= PARTY_SIZE) or not (IsInGroup() and UnitIsGroupLeader("player"))
        or not InRun(old, Me()) then
        return nil
    end
    local now = Now()
    local p = Prefs()
    local s = {}
    for i, x in ipairs(old.s or {}) do
        s[i] = { k = x.k, r = x.r, c = x.c }
        if Util.IsMe(x.k) and ROLE_INDEX[x.r] then p.role = x.r end   -- I keep the role I had in it
    end
    local run = { id = (Me() or "?") .. ":" .. now, o = Me(), d = old.d, h = old.h, at = old.at or 0, c = old.c or now,
                  no = old.no, s = s, rv = 1, pv = old.id, gf = gf and true or nil }
    GK.Copy(old, run)
    State().list[run.id] = run
    State().gone[run.id] = nil
    DropRun(old.id, true)
    TakeRequests(run, q)
    p.up = 0
    SyncMyParty()
    BroadcastRun(run)
    SendProfile()
    Changed()
    ns:Print("You lead the run now: %s%s.", GK.Name(run), run.h and " (Heroic)" or "")
    return run
end

local lastGroup, leftGroup = {}, {}   -- my group's members at the last check; [key] = GetTime() they left it

-- Is every member of my group (me too) in that run's party?
local function GroupInRun(run)
    for key in pairs(Util.group or {}) do
        if not InRun(run, key) then return false end
    end
    return true
end

-- The lead of my group changed (or the roster did): pass my run on, or take over the run of the group I now lead:
-- its owner is in my group (passed me the lead, or went offline), or just left it while the rest of us stayed.
local lastGrouped   -- whether I was in a group at the last check (my profile says so while I'm up for a run)

local function CheckLead()
    if DemoOn() then return end
    local grouped = Runs:IsGrouped()
    if grouped ~= lastGrouped then
        lastGrouped = grouped
        if Runs:IsUp() then SendProfile() end
    end
    local now = GetTime()
    for key in pairs(lastGroup) do
        if not (Util.group and Util.group[key]) then leftGroup[key] = now end
    end
    lastGroup = {}
    for key in pairs(Util.group or {}) do lastGroup[key] = true end
    if MyRun() then
        SyncMyParty()
        return
    end
    if not IsInGroup() or not UnitIsGroupLeader("player") then return end
    for _, run in pairs(State().list) do
        if run.o ~= Me() and not Expired(run) and InRun(run, Me()) and not (IsInRaid() and GK.Size(run) <= PARTY_SIZE) then
            local here = Util.group and Util.group[run.o]
            local left = not here and leftGroup[run.o] and now - leftGroup[run.o] < HANDOFF_WAIT and GroupInRun(run)
            if here or left then
                Adopt(run)
                return
            end
        end
    end
end

local function OnHandoff(sender, msg)
    if type(msg.id) ~= "string" then return end
    local mine = MyRun()
    if mine and mine.pv == msg.id then
        -- I took the run over already (my side saw the lead change first, or the old leader was offline and is
        -- back): the requests and the Group Finder follow, and the old leader gets my run (it names theirs)
        TakeRequests(mine, msg.q)
        if msg.gf == 1 then mine.gf = true end
        Send(WireRun(mine), "WHISPER", sender)
        Changed()
        return
    end
    local old = State().list[msg.id]
    if not old or old.o ~= sender then return end
    Adopt(old, msg.q, msg.gf == 1)
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
    if not Runs:IsUp() or Runs:IsGrouped() then return end
    if InCombat() or Util.InPartyInstance() or Util.InRaidInstance() then return end
    -- (1.5) only for the kinds of groups I'm up for; a roster still on its way first
    if run.pt or not (GK.MyKinds(Prefs())[GK.Kind(run)] or GK.HasQuestOf(run)) then return end
    if run.k == "pvp" and run.pr and run.mr then
        local p = GK.pvp[GK.pvpIndex[run.a[1]] or 0]
        local team = p and ns.GroupPvP and ns.GroupPvP:GetTeam(p.bracket)
        if team and (team.personal or 0) < run.mr then return end
    end
    local role = Runs:FitsMe(run)
    if not role or GK.Blocker(run) then return end
    if (run.at or 0) > Now() + 3600 then return end   -- a run for tomorrow is no reason to ping now
    pinged[run.id] = true
    ns:Fire("DUNGEON_RUN_PING", run.id)
end

---------------------------------------------------------------------------
-- Party invites from a run's leader: answered by the addon instead of Blizzard's pop-up
---------------------------------------------------------------------------

-- The server's invite is the only way into a party; Blizzard's pop-up is just a window over it. For an invite from
-- the leader of a listed run, the addon answers it: accepted for me when I asked to join that run a moment ago (my
-- Join was the answer), else asked in the run's own pop-up (Core fires DUNGEON_RUN_INVITE). Any other invite keeps
-- Blizzard's pop-up, and so does one whose acceptance would cost me a queue (Blizzard's text says so).

-- Closes Blizzard's PARTY_INVITE pop-up without declining: its OnHide declines an invite it did not accept itself
-- (classic_anniversary GameDialogDefs), so it is marked as answered first (as Leatrix Plus does).
local function HideBlizzardInvite()
    local dialog = StaticPopup_FindVisible and StaticPopup_FindVisible("PARTY_INVITE")
    if not dialog then return end
    dialog.inviteAccepted = 1
    if StaticPopup_Hide then StaticPopup_Hide("PARTY_INVITE") end
end

local function RunLedBy(key)
    for _, run in pairs(State().list) do
        if run.o == key and not Expired(run) then return run end
    end
    return nil
end

local function EndInvite()
    if not invite then return end
    invite = nil
    Changed()
    ns:Fire("DUNGEON_RUN_INVITE_GONE")
end

local function AnswerInvite(yes)
    if not invite then return false end
    local id, from = invite.run, invite.from
    invite = nil
    HideBlizzardInvite()
    if yes then
        if AcceptGroup then AcceptGroup() end
    else
        if DeclineGroup then DeclineGroup() end
        -- no to the invite is no to the run: my request goes (the leader's list too), Join comes back
        if Asked()[id] then
            Asked()[id] = nil
            Send({ t = "DRC", id = id }, "WHISPER", from)
        end
    end
    Changed()
    ns:Fire("DUNGEON_RUN_INVITE_GONE")
    return true
end

local function OnPartyInvite(_, name)
    if DemoOn() then return end
    local from = type(name) == "string" and Util.NormalizeName(name)
    local run = from and RunLedBy(from)
    if not run or InRun(run, Me()) then return end
    if WillAcceptInviteRemoveQueues and WillAcceptInviteRemoveQueues() then return end
    -- (1.3.3) the leader is forming a planned raid I'm in, and I didn't ask to join the run: that invite is the
    -- raid's, the game's own pop-up answers it
    local RP = ns.RaidPlan
    if Asked()[run.id] == nil and RP and RP.IsRaidInviteFrom and RP:IsRaidInviteFrom(from) then return end
    local n = ((invite and invite.n) or 0) + 1
    invite = { run = run.id, from = from, n = n }
    -- UIParent shows its pop-up for the same event (before or after this handler): close it now and next frame
    HideBlizzardInvite()
    Util.After(0, HideBlizzardInvite)
    local a = Asked()[run.id]
    if a and (a.st == "asked" or a.st == "invited") and Now() - (a.at or 0) <= AUTO_ACCEPT_FOR then
        ns:Print("Joining %s's run: %s%s.", Util.ShortName(from) or from, GK.Name(run), run.h and " (Heroic)" or "")
        AnswerInvite(true)
        return
    end
    Changed()
    ns:Fire("DUNGEON_RUN_INVITE", run.id, from)
    -- like Blizzard's pop-up: an invite nobody answers is declined when it runs out
    Util.After(INVITE_FOR, function()
        if invite and invite.n == n then AnswerInvite(false) end
    end)
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
    -- (1.5) groups of the other kinds: a Karazhan now, Gruul + Magtheridon later with pugs, two PvP groups
    local function group(id, owner, fields, at, ageMin, slots, note)
        run(id, owner, nil, nil, at, ageMin, {}, note)
        local g = demo.list[id]
        GK.Copy(fields, g)
        for _, x in ipairs(slots) do g.s[#g.s + 1] = { k = k(x[1]), r = x[2], c = x[3] } end
    end
    group("demo-r1", "Aldrin", { k = "raid", a = { "Karazhan" }, n = 10, w = { tank = 2, healer = 3, dps = 5 }, lo = "roll" },
        0, 3, { { "Aldrin", "tank" }, { "Brakka", "tank" }, { "Isolde", "healer" }, { "Grimtusk", "dps" },
                { "Mirabel", "dps" }, { "Orinel", "dps" }, { "Faelar", "dps" } }, "Alt run, full clear")
    group("demo-r2", "Caelith", { k = "raid", a = { "GruulsLair", "MagtheridonsLair" }, n = 25,
            w = { tank = 3, healer = 6, dps = 16 }, lo = "sr", lr = 1 },
        later, 20, { { "Caelith", "tank" }, { "Dornoth", "tank" }, { "Jorvik", "healer" }, { "Kaelyn", "healer" },
                     { "Lorvane", "healer" }, { "Rhosyn", "healer" }, { "Quillon", "healer" }, { "Elowen", "dps" },
                     { "Halvard", "dps" }, { "Nortok", "dps" }, { "Pyria", "dps" },
                     { "Tarnok", "dps", "SHAMAN" }, { "Lumifae", "dps", "MAGE" }, { "Darkstalkerr", "dps", "HUNTER" },
                     { "Brewbelly", "dps", "WARRIOR" }, { "Fizzlecrank", "dps", "MAGE" }, { "Nyxa", "dps", "WARLOCK" },
                     { "Rakhul", "dps", "ROGUE" } }, "Pug fill, no BoE drama")
    group("demo-p1", "Pyria", { k = "pvp", a = { "arena3" }, n = 3, w = { tank = 0, healer = 1, dps = 2 }, pr = true,
            mr = 1650 }, 0, 6, { { "Pyria", "dps" }, { "Nortok", "dps" } }, "Team: Two Casters and a Prayer")
    group("demo-p2", "Lorvane", { k = "pvp", a = { "eots" }, n = 15, w = { tank = 0, healer = 4, dps = 11 }, fc = true },
        now + 3600 - now % 900, 12, { { "Lorvane", "healer" }, { "Jorvik", "healer" }, { "Halvard", "dps" },
                                      { "Elowen", "dps" }, { "Grimtusk", "dps" }, { "Mirabel", "dps" } },
        "Flag carrier wanted")
    -- quest groups: Terokk's Downfall now, the Ring of Blood's last fight; who has which quest
    group("demo-q1", "Isolde", { k = "quest", a = { 11073 }, n = 5, w = { tank = 1, healer = 1, dps = 3 } }, 0, 5,
        { { "Isolde", "healer" } })
    group("demo-q2", "Faelar", { k = "quest", a = { 9977 }, n = 5, w = { tank = 1, healer = 1, dps = 3 } }, 0, 8,
        { { "Faelar", "dps" }, { "Orinel", "dps" }, { "Quillon", "tank" } })
    demo.peers[k("Isolde")].quests = { [11073] = true }
    demo.peers[k("Faelar")].quests = { [9977] = true }
    demo.peers[k("Orinel")].quests = { [9977] = true, [9937] = true }
    demo.peers[k("Nortok")].quests = { [9937] = true, [9853] = true }
    demo.peers[k("Quillon")].arena = { [3] = { rating = 1702, name = "Disastrous Decisions" } }
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

-- The dungeon of an instance map id (GetInstanceInfo, a Group Finder activity's mapID), or nil.
function Runs:GetDungeonByMap(mapID)
    BuildData()
    return BY_INSTANCE[tonumber(mapID) or -1]
end

-- Every dungeon key, in wire order.
function Runs:GetDungeonKeys()
    local out = {}
    for i, key in ipairs(ORDER) do out[i] = key end
    return out
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

-- Can that class play the role? (An unknown class: any.)
function Runs:CanPlayRole(classFile, role) return CanPlay(classFile, role) end

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

-- Guild members (not me) who are up for a run now, tanks and healers first: { { key, roles, class, grouped = in
-- a group (no invite reaches them) } }.
function Runs:GetUpForRun()
    local out = {}
    local now = Now()
    local busy = {}
    for _, run in pairs(State().list) do
        for _, x in ipairs(run.s or {}) do busy[x.k] = true end
    end
    for key, peer in pairs(Peers()) do
        if (peer.up or 0) > now and not Util.IsMe(key) and not busy[key] and (DemoOn() or IsOnline(key)) then
            out[#out + 1] = { key = key, roles = peer.roles or {}, class = ClassOf(key), grouped = peer.grouped,
                              kinds = peer.kinds or { dungeon = true } }
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

-- Every listed 5-man dungeon run (not expired), mine included: { run, ... } in no particular order. (Groups of the
-- other kinds: GetGroups.)
function Runs:GetRuns()
    local out = {}
    local now = Now()
    for _, run in pairs(State().list) do
        if not Expired(run, now) and GK.IsDungeon(run) and DUNGEON[run.d] then out[#out + 1] = run end
    end
    return out
end

-- (1.5) Every listed group of a kind ("dungeon" | "raid" | "quest" | "pvp" | "other"; nil = every kind).
function Runs:GetGroups(kind)
    local out = {}
    local now = Now()
    for _, run in pairs(State().list) do
        if not Expired(run, now) and GK.Valid(run) and (kind == nil or GK.Kind(run) == kind) then out[#out + 1] = run end
    end
    if kind == nil or kind == "raid" then
        for _, run in ipairs(GK.Bridge()) do out[#out + 1] = run end
    end
    return out
end

-- A group of any kind by id; one whose lead passed is found by its old id too (share links, the Home calendar).
function Runs:GetGroup(id)
    if type(id) == "string" and id:sub(1, 3) == "rp:" then
        for _, run in ipairs(GK.Bridge()) do
            if run.id == id then return run end
        end
        return nil
    end
    for _ = 1, 5 do
        local run = type(id) == "string" and State().list[id]
        if run then return (not Expired(run)) and run or nil end
        id = renamed[id]
        if not id then return nil end
    end
    return nil
end

-- A 5-man dungeon run by id (as GetGroup, for the pages that show dungeon runs only).
function Runs:GetRun(id)
    local run = self:GetGroup(id)
    return (run and GK.IsDungeon(run)) and run or nil
end

-- My dungeon run (GetMyGroup: my group of any kind).
function Runs:GetMine()
    local run = MyRun()
    return (run and GK.IsDungeon(run)) and run or nil
end
function Runs:GetMyGroup() return MyRun() end

-- A group's kind, size, places per role ({ tank, healer, dps }), name, and why I can't join it (nil = I can).
function Runs:GetKind(run) return GK.Kind(run) end
function Runs:GetSize(run) return GK.Size(run) end
function Runs:GetWant(run) return GK.Want(run) end
function Runs:GetName(run) return GK.Name(run) end
function Runs:GetGroupBlocker(run) return GK.Blocker(run) end

-- The items on my BiS lists a group's instance drops, main picks first: a dungeon's (as GetMyBiSDrops), a raid
-- group's (its raids; only the picked bosses' when it picked some).
function Runs:GetGroupBiSDrops(run)
    if GK.IsDungeon(run) then return self:GetMyBiSDrops(run.d, run.h) end
    local out, seen = {}, {}
    if run.k ~= "raid" then return out end
    local picked
    if run.bo then
        picked = {}
        for _, b in ipairs(run.bo) do picked[b] = true end
    end
    for _, rk in ipairs(run.a or {}) do
        for _, e in ipairs(myNeeds.r and myNeeds.r[rk] or {}) do
            if not seen[e.id] and (not picked or (e.boss and picked[e.boss])) then
                seen[e.id] = true
                out[#out + 1] = e.id
            end
        end
    end
    return out
end

-- Does a member (not me) have something on their BiS lists in that raid, as their DisasterZone told the guild?
function Runs:HasRaidBiS(member, raidKey)
    if Util.IsMe(member) then return (myNeeds.r and myNeeds.r[raidKey]) ~= nil end
    local peer = Peers()[member]
    return (peer and peer.raidNeeds and peer.raidNeeds[raidKey]) and true or false
end

-- The attunements a raid group needs that I haven't done: { "the Master's Key", ... } (a hint, never a block: what
-- the realm asks for changes with its phase; Data/GroupKinds.lua raids[].attune).
function Runs:GetMissingAttunements(run)
    local out = {}
    if run.k ~= "raid" or DemoOn() then return out end
    local Q = C_QuestLog
    for _, rk in ipairs(run.a or {}) do
        local raid = GK.raids[GK.raidIndex[rk] or 0]
        local at = raid and raid.attune
        if at and at.quest and Q and Q.IsQuestFlaggedCompleted and not Q.IsQuestFlaggedCompleted(at.quest) then
            out[#out + 1] = at.name
        end
    end
    return out
end

-- (owner) Starts the raid session as my raid group listed it: rolls, soft reserves (n each) or the loot council.
-- Returns ok, why.
function Runs:StartGroupSession()
    local run = MyRun()
    if not run or run.k ~= "raid" then return false, "You don't lead a raid group." end
    local GR = ns.GroupRules
    if not (GR and GR.SetSession) then return false, "The raid session isn't available." end
    local features = ({ roll = { loot = false, rolls = true, lock = false },
                        sr = { loot = true, rolls = true, lock = false, reserve = true },
                        lc = { loot = true, rolls = true, lock = false } })[run.lo or "roll"]
    local ok, err = GR:SetSession(true, nil, features)
    if not ok then return false, err end
    if run.lo == "sr" and ns.Reserves and ns.Reserves.Open then
        local ok2, err2 = ns.Reserves:Open({ rk = run.a[1], n = run.lr or 1 })
        if not ok2 and err2 then ns:Print("Reserves: %s", err2) end
    end
    GK.sessionFor = run.id
    return true
end

-- (owner) My raid group's leader just arrived in one of its raids, with no session running: the page offers to
-- start it (GROUP_RAID_ARRIVED, once per group).
function GK.CheckArrival()
    local run = MyRun()
    if not run or run.k ~= "raid" or GK.arrivedFor == run.id or DemoOn() then return end
    if not (IsInRaid() and UnitIsGroupLeader("player")) or not GetInstanceInfo then return end
    local _, itype, _, _, _, _, _, mapID = GetInstanceInfo()
    if itype ~= "raid" then return end
    local here = ns.ItemDB and ns.ItemDB.ItemKeyOf and ns.ItemDB:ItemKeyOf(mapID)
    local listed = false
    for _, rk in ipairs(run.a or {}) do
        if rk == here then listed = true end
    end
    if not listed then return end
    local GR = ns.GroupRules
    if GR and GR.GetSession and GR:GetSession() then return end
    GK.arrivedFor = run.id
    ns:Fire("GROUP_RAID_ARRIVED", run.id)
end

-- A group's art in a w x h box: file, l, r, t, b (a dungeon's or raid's loading screen, a PvP place's, else
-- Outland's); fw = the share of the screen's width (the cards' crop by default). Crops stay under the logo band.
function Runs:GetGroupArt(run, w, h, fw)
    if GK.IsDungeon(run) then return self:GetArt(run.d, w, h, fw) end
    if not w or not h or w <= 0 or h <= 0 then return nil end
    fw = fw or ART_W
    if run.k == "raid" then
        local IDB = ns.ItemDB
        if not (IDB and IDB.RaidArt) then return nil end
        return IDB:RaidArt(run.a[1], w, h, fw, true)   -- (all five values: no "and" in front of the call)
    end
    local src = run.k == "pvp" and GK.pvp[GK.pvpIndex[run.a and run.a[1]] or 0] or GK.art[run.k]
    if run.k == "quest" and ns.GroupQuests then
        local q = ns.GroupQuests:Get(run.a and run.a[1])
        local z = q and ns.GroupQuests:GetZone(q.zone)
        if z and z.screen then src = z end
    end
    if not src then return nil end
    local fh = min(fw * (4 / 3) * (h / w), 0.68)
    local l = min(max(src.cx - fw / 2, 0), 1 - fw)
    local t = min(max(src.cy - fh / 2, 0.29), 0.97 - fh)
    return src.screen, l, l + fw, t, t + fh
end

-- A group's icon: file, l, r, t, b. The LFG icons (dungeons, raids, quests, other) draw their picture in the top left
-- 52 x 47 of their 64 x 64 inside a 3 px frame: the coords keep a square of the picture only (a ring shows no frame);
-- PvP's are spell and item icons (their border cut off).
function Runs:GetGroupIcon(run)
    local l, r, t, b = 6 / 64, 45 / 64, 4 / 64, 43 / 64
    if GK.IsDungeon(run) then
        local d = DUNGEON[run.d]
        return d and d.complex.icon, l, r, t, b
    end
    if run.k == "raid" then
        local IDB = ns.ItemDB
        return IDB and IDB.RaidIcon and IDB:RaidIcon(run.a[1]), l, r, t, b
    end
    if run.k == "pvp" then
        local p = GK.pvp[GK.pvpIndex[run.a and run.a[1]] or 0]
        return p and p.icon, 0.08, 0.92, 0.08, 0.92
    end
    local o = run.k == "other" and GK.other[GK.otherIndex[run.a and run.a[1]] or 0]
    if o and o.icon then return o.icon, 0.08, 0.92, 0.08, 0.92 end
    local a = GK.art[run.k]
    return a and a.icon, l, r, t, b
end

-- The bosses a raid group shows (the picked ones, else the last ones of a full clear), at most 3, in raid order:
-- { { key = "Karazhan:Prince", name, pic = the Encounter Journal picture's file id }, ... }.
function Runs:GetGroupBosses(run)
    local out = {}
    if run.k ~= "raid" then return out end
    local IDB = ns.ItemDB
    local J = ns.Data and ns.Data.BossJournal or {}
    local picked = {}
    for _, key in ipairs(run.bo or {}) do picked[key] = true end
    local per = {}
    for _, rk in ipairs(run.a or {}) do
        local raid = IDB and IDB.GetRaid and IDB:GetRaid(rk)
        local list = {}
        for _, b in ipairs(raid and raid.bosses or {}) do
            local key = rk .. ":" .. tostring(b.key)
            if J[key] and (run.bo == nil or picked[key]) then list[#list + 1] = { key = key, name = b.name, pic = J[key] } end
        end
        per[#per + 1] = list
    end
    -- picked ones: as picked; a full clear: one raid's last three, or each raid's last ones
    local each = (run.bo or #per <= 1) and 3 or max(1, floor(3 / #per))
    for _, list in ipairs(per) do
        for i = run.bo and 1 or max(1, #list - each + 1), #list do
            if #out < 3 then out[#out + 1] = list[i] end
        end
    end
    return out
end

-- The kinds of groups (wire order) and the activities of a kind: raids { key, size }, PvP { key, name, size, mode,
-- bracket }, other { key, name }.
function Runs:GetKinds()
    local out = {}
    for i, k in ipairs(GK.kinds) do out[i] = k end
    return out
end
function Runs:GetActivities(kind)
    local list = (kind == "raid" and GK.raids) or (kind == "pvp" and GK.pvp) or (kind == "other" and GK.other) or {}
    local out = {}
    for i, x in ipairs(list) do out[i] = x end
    return out
end

-- The kinds of groups I'm up for ({ dungeon = true, ... }) and switching one (at least one stays on).
function Runs:GetMyKinds()
    local out = {}
    for k in pairs(GK.MyKinds(Prefs())) do out[k] = true end
    return out
end
function Runs:SetMyKind(kind, on)
    if not GK.kindIndex[kind] then return false end
    local p = Prefs()
    local nextSet = {}
    for k in pairs(GK.MyKinds(p)) do nextSet[k] = true end
    nextSet[kind] = on and true or nil
    if not next(nextSet) then return false end
    p.kinds = nextSet
    Changed()
    SendProfile()
    if on and self:IsUp() then
        for _, run in pairs(State().list) do MaybePing(run, false) end
    end
    return true
end

-- The places a group lists by default: { tank, healer, dps } for its kind, size and (PvP) activity.
function Runs:GetDefaultWant(kind, n, key) return GK.DefaultWant(kind, n, key) end

-- (1.5) Quests: the group (not mine) that already lists a quest, or nil; the guildies online with it in their log.
function Runs:GetQuestGroup(id)
    local key = ns.GroupQuests and ns.GroupQuests:Key(id) or id
    for _, run in pairs(State().list) do
        if run.k == "quest" and run.o ~= Me() and not Expired(run) then
            for _, x in ipairs(run.a or {}) do
                if x == key then return run end
            end
        end
    end
    return nil
end
function Runs:GetQuestHolders(id)
    local key = ns.GroupQuests and ns.GroupQuests:Key(id) or id
    local out = {}
    for k, peer in pairs(Peers()) do
        if peer.quests and peer.quests[key] and not Util.IsMe(k) and (DemoOn() or IsOnline(k)) then out[#out + 1] = k end
    end
    tsort(out)
    return out
end
-- The group quests guildies online have in their logs: { [key] = n }.
function Runs:GetGuildQuests()
    local out = {}
    for k, peer in pairs(Peers()) do
        if not Util.IsMe(k) and (DemoOn() or IsOnline(k)) then
            for key in pairs(peer.quests or {}) do out[key] = (out[key] or 0) + 1 end
        end
    end
    return out
end
-- (1.5) A planned raid I'm signed up for (Accepted or Tentative) whose time this group's would clash with: its view,
-- or nil. A group lasts 2 hours (a raid group 3.5), a planned raid 3.5.
function Runs:GetOverlap(run)
    local RP = ns.RaidPlan
    if not (RP and RP.GetRaids and RP.GetMySignup) or run.rp then return nil end
    local start = (run.at and run.at > 0) and run.at or Now()
    local dur = (run.k == "raid") and 3.5 * 3600 or 2 * 3600
    for _, v in ipairs(RP:GetRaids(start - 4 * 3600, start + dur)) do
        if not v.cancelled and v.t < start + dur and v.t + 3.5 * 3600 > start then
            local su = RP:GetMySignup(v.id)
            if su and (su.st == "A" or su.st == "T") then return v end
        end
    end
    return nil
end

-- PvP: a member's team of a bracket as their profile said: { rating, name } or nil.
function Runs:GetArenaOf(member, bracket)
    local peer = Peers()[member]
    return peer and peer.arena and peer.arena[bracket] or nil
end
-- How many guildies online have BiS in a raid.
function Runs:GetRaidNeeders(raidKey)
    local n = 0
    for k, peer in pairs(Peers()) do
        if not Util.IsMe(k) and (DemoOn() or IsOnline(k)) and peer.raidNeeds and peer.raidNeeds[raidKey] then n = n + 1 end
    end
    return n
end

-- My lockout for a raid (item key): until (server time), bosses done, bosses in all; nil when not saved.
function Runs:GetRaidSaved(key)
    local s = GK.saved[key]
    if not s or s.untilT <= Now() then return nil end
    return s.untilT, s.done, s.total
end

-- Is a member saved to that raid this week, as their DisasterZone told the guild?
function Runs:IsSavedToRaid(member, key)
    if Util.IsMe(member) then return self:GetRaidSaved(key) ~= nil end
    local peer = Peers()[member]
    return (peer and peer.raids and peer.raids[key] and (peer.savedUntil or 0) > Now()) and true or false
end
function Runs:GetSlots(run) return Slots(run) end
function Runs:GetOpenRoles(run) return OpenRoles(run) end
function Runs:IsInRun(run, key) return InRun(run, key or Me()) end

-- Does the run start now (or has its time come)?
function Runs:IsNow(run)
    return (run.at or 0) <= Now()
end

-- Am I in a group (a party or raid)? Then no invite can reach me: no Join, no pings.
function Runs:IsGrouped()
    if DemoOn() then return false end
    return (IsInGroup() or IsInRaid()) and true or false
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

-- The party invite the addon holds for me (Blizzard's pop-up closed): { run = id, from = key } or nil.
function Runs:GetInvite()
    return invite and { run = invite.run, from = invite.from } or nil
end

-- Accepts (yes) or declines the invite the addon holds. Returns false when there is none.
function Runs:AnswerInvite(yes) return AnswerInvite(yes) end

-- (owner) The role somebody from outside the guild was invited as: their place in my run once they join.
function Runs:SetGuestRole(key, role)
    if type(key) ~= "string" then return end
    guestRoles[key] = ROLE_INDEX[role] and role or nil
end

-- (owner) Sets the role somebody plays in my run (a pug who whispered me joins as DPS until I say otherwise).
-- Returns true when it changed.
function Runs:SetPartyRole(key, role)
    local run = MyRun()
    if not run or not ROLE_INDEX[role] or type(key) ~= "string" then return false end
    for _, x in ipairs(run.s or {}) do
        if x.k == key then
            if x.r == role then return false end
            x.r = role
            if Util.IsMe(key) then
                Prefs().role = role
            elseif not InGuild(key) then
                guestRoles[key] = role
            end
            run.rv = (run.rv or 0) + 1
            Changed()
            BroadcastRun(run)
            return true
        end
    end
    return false
end

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
-- no = note, role = the role I go as, gf = list it in the Group Finder too (mine only, never sent) }. Returns the
-- run, or nil and why.
-- (1.5) A group of another kind: opts.k = "raid" | "quest" | "pvp" | "other" and a = { activity, ... } (raid keys,
-- quest ids, one PvP key, one other key) instead of d / h; n = size (PvP: the bracket's / battleground's), w = { tank,
-- healer, dps } places (default from the size), raids: lo = "roll" | "sr" | "lc", lr = soft reserves each, bo = { boss
-- key, ... } (nil = full clear); PvP: pr = rated (arenas), mr = lowest rating, fc = wants a flag carrier (battlegrounds).
function Runs:List(opts)
    if type(opts) ~= "table" then return nil, "Pick a dungeon." end
    local gen, why
    if opts.k ~= nil and opts.k ~= "dungeon" then
        gen, why = GK.FromOpts(opts)
        if not gen then return nil, why end
    elseif not DUNGEON[opts.d] then
        return nil, "Pick a dungeon."
    end
    local at = tonumber(opts.at) or 0
    local now = Now()
    if at > 0 and at <= now + 60 then at = 0 end
    if at > now + AHEAD_MAX then return nil, "Runs can be listed at most a week ahead." end
    if not gen then
        if IsInRaid() or (IsInGroup() and not UnitIsGroupLeader("player")) then
            return nil, "Only the party leader can list the party's run."
        end
        local block = self:GetBlocker(opts.d, opts.h)
        if block then return nil, block end
    else
        if IsInGroup() and not UnitIsGroupLeader("player") then return nil, "Only the group's leader can list it." end
        if IsInRaid() and gen.n <= PARTY_SIZE then return nil, "A raid can't list a group of " .. gen.n .. "." end
        if IsInGroup() and (tonumber(GetNumGroupMembers()) or 0) > gen.n then
            return nil, "Your group is already bigger than " .. gen.n .. "."
        end
        local block = GK.Blocker(gen)
        if block then return nil, block end
    end
    local p = Prefs()
    if opts.role and ROLE_INDEX[opts.role] then p.role = opts.role end
    local old = MyRun()
    local run = {
        id = old and old.id or ((Me() or "?") .. ":" .. now),
        o = Me(), d = opts.d, h = opts.h and true or nil, at = floor(at), c = old and old.c or now,
        no = TrimNote(opts.no), s = old and old.s or {}, rv = old and ((old.rv or 0) + 1) or 1,
        gf = opts.gf and true or nil,
    }
    if gen then
        -- (the Group Finder lists dungeon runs only, for now)
        run.d, run.h, run.gf = nil, nil, nil
        GK.Copy(gen, run)
    end
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
    wipe(guestRoles)
    if not DemoOn() then
        Send({ t = "DRX", id = run.id }, "GUILD")
        SendProfile()
    end
    if not quiet then ns:Print("Your run is off the board.") end
    return true
end

-- Asks the owner to join as the best open role I play. Returns ok, why.
function Runs:Join(id)
    local run = self:GetGroup(id)
    if not run then return false, "That run is gone." end
    if run.rp then return GK.BridgeJoin(run) end
    if run.pt then return false, "Still getting that group's players: try again in a moment." end
    local role = self:FitsMe(run)
    if not role then return false, "No open place fits your roles." end
    local block = GK.Blocker(run)
    if block then return false, block end
    -- an invite can't reach a player in a group (my own run's party included: leading it, I'd leave it behind)
    if self:IsGrouped() then return false, "Leave your group first: an invite can't reach you while you're in one." end
    if not DemoOn() then
        if not IsOnline(run.o) then return false, "The leader is offline." end
        local b = (#self:GetGroupBiSDrops(run) > 0) and 1 or nil
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
    local run = self:GetGroup(id)
    if run and not DemoOn() then Send({ t = "DRC", id = id }, "WHISPER", run.o) end
    Changed()
    return true
end

local function CanInvite()
    -- (1.5) in a raid (a bigger group goes on in one): its leader or an assistant
    if IsInRaid() then
        return (UnitIsGroupLeader("player") or (UnitIsGroupAssistant and UnitIsGroupAssistant("player"))) and true or false
    end
    return not IsInGroup() or UnitIsGroupLeader("player")
end

-- The invite of a player to my group: right away, or a moment after my full party became a raid.
local function InviteToRun(run, key)
    if GK.MakeRoom(run) then
        Util.After(1.5, function() Invite(key) end)
    else
        Invite(key)
    end
end

-- Can I invite to my group (not in a group, or its leader; in a raid an assistant too)?
function Runs:CanInvite() return CanInvite() end

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
    InviteToRun(run, key)
    GK.TeamInvite(run, key)
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
    local peer = Peers()[key]
    if peer and peer.grouped then
        ns:Print("%s is in a group: an invite can't reach them.", Util.ShortName(key) or key)
        return false
    end
    InviteToRun(run, key)
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
    local name = GK.Name(run) .. (run.h and " (Heroic)" or "")
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
            local drop = Expired(run, now) or not GK.Valid(run)
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
        for id in pairs(GK.rosterAsked) do
            if not st.list[id] then GK.rosterAsked[id] = nil end
        end
    end
    for key, peer in pairs(peers) do
        if not IsOnline(key) and now - (peer.seen or 0) > PEER_TTL then peers[key] = nil end
    end
    -- my questions: gone with their run; a request is forgotten after REQUEST_TTL (the leader's list forgets it
    -- too), "not this time" after DECLINED_FOR (I may ask again)
    for id, a in pairs(asked) do
        local stale = (a.st == "declined" and now - (a.dt or a.at or 0) > DECLINED_FOR)
            or (a.st ~= "declined" and now - (a.at or 0) > REQUEST_TTL)
        if stale or not State().list[id] then asked[id] = nil end
    end
    UpdateUp()
    Changed()
end

local function RefreshNeeds()
    Util.Debounce("dungeon-runs-needs", 2, function()
        local before = ProfileMsg()
        myNeeds = ComputeNeeds()
        local after = ProfileMsg()
        local same = #before.nn == #after.nn and #before.nh == #after.nh and #before.nr == #after.nr
        if same then
            for i, v in ipairs(after.nn) do if before.nn[i] ~= v then same = false end end
            for i, v in ipairs(after.nh) do if before.nh[i] ~= v then same = false end end
            for i, v in ipairs(after.nr) do if before.nr[i] ~= v then same = false end end
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
        Comm:Register("DRH", OnHandoff)
        Comm:Register("DRR", GK.OnRosterAsk)
    end
    for _, msg in ipairs({ "MYLIST_CHANGED", "OWNED_UPDATED", "LISTS_RESET", "CONFIG_UPDATED" }) do
        ns:On(msg, RefreshNeeds)
    end
    ns:RegisterEvent("PARTY_INVITE_REQUEST", OnPartyInvite)
    ns:RegisterEvent("PARTY_INVITE_CANCEL", EndInvite)
    ns:RegisterEvent("CHAT_MSG_SYSTEM", OnSystem)
    ns:On("GROUP_UPDATED", function()
        if invite and IsInGroup() then EndInvite() end
        Util.Debounce("dungeon-runs-group", 0.5, function()
            CheckLead()
            UpdateUp()
            Changed()
        end)
    end)
    -- the lead can pass without the roster changing (no GROUP_UPDATED): after Util's group cache caught up (0.3 s)
    ns:RegisterEvent("PARTY_LEADER_CHANGED", function()
        Util.Debounce("dungeon-runs-lead", 0.8, function()
            CheckLead()
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
    -- (1.5) my group quests changed: the guild hears it; a quest group of mine whose quests are all done ends
    -- (demo: its made-up log came or went; nothing real changed)
    ns:On("GROUP_QUESTS_UPDATED", function(demoSwap)
        if not demoSwap and not DemoOn() then
            GK.OnQuestDone()
            SendProfile()
        end
        Changed()
    end)
    ns:On("GROUP_PVP_UPDATED", function() Util.Debounce("dungeon-runs-pvp", 2, SendProfile) end)
    ns:RegisterEvent("QUEST_DETAIL", function()
        if GetQuestID then NoteQuest(GetQuestID()) end
    end)
    ns:RegisterEvent("GOSSIP_SHOW", function()
        local list = C_GossipInfo and C_GossipInfo.GetAvailableQuests and C_GossipInfo.GetAvailableQuests()
        for _, q in ipairs(type(list) == "table" and list or {}) do
            if type(q) == "table" then NoteQuest(q.questID) end
        end
    end)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        Util.After(2, UpdateUp)
        Util.After(3, GK.CheckArrival)
    end)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() Util.After(2, GK.CheckArrival) end)
    ns:RegisterEvent("PLAYER_LEVEL_UP", Changed)
    ns:RegisterEvent("UPDATE_FACTION", function() Util.Debounce("dungeon-runs-rep", 1, Changed) end)
    ns:RegisterSlash("lfg", function() if ns.MainFrame then ns.MainFrame:Open("dungeons") end end,
        "open the Groups tab: dungeons, raids, quests and PvP groups of the guild")
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
