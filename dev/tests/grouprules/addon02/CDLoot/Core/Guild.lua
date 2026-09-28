-- CDLoot: guild roster cache, the guild-info config tag CDL{...} (council ranks / names, phase)
-- and council checks. Every other module asks ns.Guild who is council and who is online.
local addonName, ns = ...

local Guild = ns:NewModule("Guild")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, next = type, pairs, ipairs, tonumber, tostring, next
local strlower, strsub, strmatch = string.lower, string.sub, string.match
local tsort, tconcat = table.sort, table.concat

local DEFAULT_RANK = 1          -- ranks 0 (GM) and 1 are council when no tag exists
local DEFAULT_PHASE = 1
local MAX_RANK_INDEX = 20
local MAX_INFO_LEN = 500        -- guild info text limit (refuse to write longer)
local ROSTER_REQUEST_INTERVAL = 15
local ROSTER_POLL_INTERVAL = 60
local ROSTER_RETRY_DELAY = 10   -- while the roster is still empty after login
local CACHE_GRACE = 60          -- seconds after login during which an empty info text falls back to the cache
local PENDING_WRITE_GRACE = 30  -- seconds our own freshly written text wins over a stale server copy

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local roster = {}               -- [key] = { rankIndex, rankName, classFile, online, level }
local lowerIndex = {}           -- [lowercased key] = key (resolves tag names typed with odd casing)
local ready = false
local guildName                 -- cached guild name
local lastRequest = -1000
local loginTime = 0
local cfg                       -- current parsed config
local addLower, removeLower = {}, {}
local configSignature           -- tag + resolved council set + my status; change => CONFIG_UPDATED
local pendingText, pendingUntil -- text we just wrote into the Guild Information
local pollTicker

local function MaxPhase()
    return ns.MAX_PHASE or 5
end

-- Guild Information text. 2.5.6 has C_GuildInfo.GetInfoText / SetInfoText; the old globals only
-- exist as deprecation fallbacks (CVar loadDeprecationFallbacks) and are used only as a fallback.
local function InfoTextGetter()
    return (C_GuildInfo and C_GuildInfo.GetInfoText) or GetGuildInfoText
end

local function InfoTextSetter()
    return (C_GuildInfo and C_GuildInfo.SetInfoText) or SetGuildInfoText
end

local function ReadInfoText()
    local get = InfoTextGetter()
    local text = get and get() or nil
    return type(text) == "string" and text or nil
end

local function DefaultConfig()
    return { rank = DEFAULT_RANK, phase = DEFAULT_PHASE, add = {}, remove = {}, raw = nil }
end

cfg = DefaultConfig()

local function DemoRoster()
    local Demo = ns.Demo
    if Demo and Demo.IsEnabled and Demo:IsEnabled() and Demo.GetRoster then
        local r = Demo:GetRoster()
        if type(r) == "table" then return r end
    end
    return nil
end

local function CopyConfig(c)
    local out = { rank = c.rank, phase = c.phase, raw = c.raw, add = {}, remove = {} }
    for k in pairs(c.add) do out.add[k] = true end
    for k in pairs(c.remove) do out.remove[k] = true end
    return out
end

---------------------------------------------------------------------------
-- Config tag
---------------------------------------------------------------------------

local function ResolveName(name)
    local key = Util.NormalizeName(name)
    if not key then return nil end
    return lowerIndex[strlower(key)] or key
end

-- Parses the first CDL{...} tag in `text`. Unknown tokens are ignored.
local function ParseConfig(text)
    local c = DefaultConfig()
    if type(text) ~= "string" then return c end
    local body = strmatch(text, "CDL(%b{})")
    if not body then return c end
    c.raw = "CDL" .. body
    for tok in strsub(body, 2, -2):gmatch("[^%s,]+") do
        local first = strsub(tok, 1, 1)
        if first == "+" or first == "-" then
            local name = strsub(tok, 2)
            if name ~= "" and #name <= 64 and not name:find("[%c|{}]") then
                local key = ResolveName(name)
                if key then
                    if first == "+" then c.add[key] = true else c.remove[key] = true end
                end
            end
        else
            local letter, num = strmatch(tok, "^(%a)(%d+)$")
            num = tonumber(num)
            if letter and num then
                letter = strlower(letter)
                if letter == "r" and num <= MAX_RANK_INDEX then
                    c.rank = num
                elseif letter == "p" and num >= 1 and num <= MaxPhase() then
                    c.phase = num
                end
            end
        end
    end
    return c
end

local function SortedNames(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = Util.ShortName(k) end
    tsort(out)
    return out
end

-- Canonical tag: r, p, +names sorted, -names sorted (own realm stripped).
function Guild:BuildTag(c)
    c = type(c) == "table" and c or cfg
    local parts = {}
    local rank = tonumber(c.rank) or DEFAULT_RANK
    local phase = tonumber(c.phase) or DEFAULT_PHASE
    parts[#parts + 1] = "r" .. math.floor(rank)
    parts[#parts + 1] = "p" .. math.floor(phase)
    if type(c.add) == "table" then
        for _, n in ipairs(SortedNames(c.add)) do parts[#parts + 1] = "+" .. n end
    end
    if type(c.remove) == "table" then
        for _, n in ipairs(SortedNames(c.remove)) do parts[#parts + 1] = "-" .. n end
    end
    return "CDL{" .. tconcat(parts, " ") .. "}"
end

local function SetConfig(c)
    cfg = c
    addLower, removeLower = {}, {}
    for k in pairs(c.add) do addLower[strlower(k)] = true end
    for k in pairs(c.remove) do removeLower[strlower(k)] = true end
end

---------------------------------------------------------------------------
-- Roster
---------------------------------------------------------------------------

local function GuildKey()
    if not guildName then return nil end
    return guildName .. "-" .. (Util.GetPlayerRealm() or "")
end

local function RefreshGuildName()
    if IsInGuild() and GetGuildInfo then
        local name = GetGuildInfo("player")
        if type(name) == "string" and name ~= "" then
            guildName = name
        end
    end
end

local function SameEntry(a, b)
    return a and b and a.rankIndex == b.rankIndex and a.online == b.online and a.classFile == b.classFile
        and a.rankName == b.rankName and a.level == b.level
end

-- Rebuilds `roster` from the client's guild roster. Returns true if anything changed.
local function BuildRoster()
    local total = GetNumGuildMembers and GetNumGuildMembers()
    total = tonumber(total) or 0
    if total <= 0 then return false end

    local newRoster, newLower, count = {}, {}, 0
    for i = 1, total do
        local name, rankName, rankIndex, level, _, _, _, _, isOnline, _, classFile = GetGuildRosterInfo(i)
        local key = type(name) == "string" and Util.NormalizeName(name) or nil
        if key then
            newRoster[key] = {
                rankIndex = tonumber(rankIndex) or 99,
                rankName = rankName,
                classFile = classFile,
                online = isOnline and true or false,
                level = tonumber(level),
            }
            newLower[strlower(key)] = key
            count = count + 1
        end
    end
    if count == 0 then return false end

    local changed = not ready
    if not changed then
        for key, entry in pairs(newRoster) do
            if not SameEntry(entry, roster[key]) then changed = true break end
        end
        if not changed then
            for key in pairs(roster) do
                if not newRoster[key] then changed = true break end
            end
        end
    end
    roster, lowerIndex = newRoster, newLower
    ready = true
    return changed
end

local function CouncilSignature()
    local keys = {}
    for key in pairs(roster) do
        if Guild:IsCouncil(key, true) then keys[#keys + 1] = key end
    end
    tsort(keys)
    return tconcat(keys, ",")
end

-- Re-reads the guild info text, parses the tag and fires CONFIG_UPDATED when the result
-- (or the resolved council set / my own status) changed.
local function ApplyConfig()
    local text = ReadInfoText() or ""
    local now = GetTime()
    if text ~= "" and Guild.NoteInfoTextSeen then Guild:NoteInfoTextSeen(text) end

    if pendingText then
        if text == pendingText or now > (pendingUntil or 0) then
            pendingText, pendingUntil = nil, nil
        else
            text = pendingText
        end
    end

    local db = ns.db
    local cache = db and db.guildCfg
    local gkey = GuildKey()
    if text == "" and now - loginTime < CACHE_GRACE and type(cache) == "table"
        and cache.guild and cache.guild == gkey and type(cache.raw) == "string" then
        -- The info text often arrives after the roster; use the last known tag meanwhile.
        text = cache.raw
    elseif db and gkey and text ~= "" then
        local c = ParseConfig(text)
        db.guildCfg = { raw = c.raw, cfg = CopyConfig(c), fetchedAt = GetServerTime(), guild = gkey }
    end

    SetConfig(ParseConfig(text))

    local me = Util.PlayerKey()
    local sig = Guild:BuildTag(cfg) .. "|" .. CouncilSignature() .. "|" .. tostring(me and Guild:IsCouncil(me, true))
    if sig ~= configSignature then
        configSignature = sig
        ns:Fire("CONFIG_UPDATED", CopyConfig(cfg))
    end
end

local function ResetGuild()
    local hadData = ready or next(roster) ~= nil
    roster, lowerIndex = {}, {}
    ready = false
    guildName = nil
    pendingText, pendingUntil = nil, nil
    SetConfig(DefaultConfig())
    if hadData then
        ns:Fire("ROSTER_UPDATED")
    end
    local sig = Guild:BuildTag(cfg) .. "||false"
    if sig ~= configSignature then
        configSignature = sig
        ns:Fire("CONFIG_UPDATED", CopyConfig(cfg))
    end
end

local function OnRosterUpdate(_, canRequestRosterUpdate)
    if not ns.loggedIn then return end
    if not IsInGuild() then
        if ready then ResetGuild() end
        return
    end
    RefreshGuildName()
    local changed = BuildRoster()
    if not ready then
        -- The roster can come back empty right after login; keep asking until it is filled.
        Util.Debounce("guild-roster-retry", ROSTER_RETRY_DELAY, function()
            if not ready and IsInGuild() then Guild:RequestRoster(true) end
        end)
        return
    end
    if changed then
        ns:Fire("ROSTER_UPDATED")
    end
    ApplyConfig()
    if Guild.OnInfoTextMaybeLoaded then Guild:OnInfoTextMaybeLoaded() end
    if canRequestRosterUpdate then
        Guild:RequestRoster()
    end
end

local function OnGuildChanged(_, unit)
    if not ns.loggedIn then return end
    if unit ~= nil and unit ~= "player" then return end
    if not IsInGuild() then
        ResetGuild()
    else
        RefreshGuildName()
        Guild:RequestRoster(true)
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Guild:OnInit()
    if ns.db and type(ns.db.guildCfg) ~= "table" then
        ns.db.guildCfg = {}
    end
    ns:RegisterEvent("GUILD_ROSTER_UPDATE", OnRosterUpdate)
    ns:RegisterEvent("PLAYER_GUILD_UPDATE", OnGuildChanged)
end

function Guild:OnLogin()
    loginTime = GetTime()
    RefreshGuildName()
    if IsInGuild() then
        -- Pre-seed the phase from the cached tag of this guild until the real text arrives.
        local cache = ns.db and ns.db.guildCfg
        local gkey = GuildKey()
        if type(cache) == "table" and gkey and cache.guild == gkey and type(cache.raw) == "string" then
            SetConfig(ParseConfig(cache.raw))
        end
        Guild:RequestRoster(true)
        Util.Debounce("guild-roster-retry", ROSTER_RETRY_DELAY, function()
            if not ready and IsInGuild() then Guild:RequestRoster(true) end
        end)
    end
    if not pollTicker and C_Timer and C_Timer.NewTicker then
        -- Keeps online flags fresh; the request itself is cheap and throttled.
        pollTicker = C_Timer.NewTicker(ROSTER_POLL_INTERVAL, function()
            if IsInGuild() then Guild:RequestRoster() end
        end)
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Asks the server for a fresh roster (at most every 15s unless forced).
function Guild:RequestRoster(force)
    if not IsInGuild() then return false end
    local now = GetTime()
    if not force and now - lastRequest < ROSTER_REQUEST_INTERVAL then return false end
    lastRequest = now
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
        return true
    end
    return false
end

function Guild:IsReady()
    return ready
end

function Guild:GetGuildName()
    if not guildName then RefreshGuildName() end
    return guildName
end

-- "Guild Name-Realm" of the player's current guild, or nil (scopes account-wide data per guild).
function Guild:GetGuildKey()
    if not guildName then RefreshGuildName() end
    return GuildKey()
end

-- `real` (optional, CDLoot extension): ignore Demo data. Network code always passes true.
function Guild:GetMember(key, real)
    if type(key) ~= "string" then return nil end
    local m = roster[key]
    if m then return m end
    if not real then
        local demo = DemoRoster()
        local d = demo and demo[key]
        if type(d) == "table" then return d end
    end
    return nil
end

function Guild:IsInGuild(key, real)
    return Guild:GetMember(key, real) ~= nil
end

function Guild:IsOnline(key, real)
    if type(key) ~= "string" then return false end
    if Util.IsMe(key) then return true end
    local m = Guild:GetMember(key, real)
    return (m and m.online) and true or false
end

function Guild:GetClass(key)
    local m = Guild:GetMember(key)
    return m and m.classFile or nil
end

function Guild:GetRankName(key)
    local m = Guild:GetMember(key)
    return m and m.rankName or nil
end

function Guild:GetMembers()
    local keys = {}
    for key in pairs(roster) do keys[#keys + 1] = key end
    local demo = DemoRoster()
    if demo then
        for key in pairs(demo) do
            if type(key) == "string" and not roster[key] then keys[#keys + 1] = key end
        end
    end
    tsort(keys)
    return keys
end

function Guild:GetConfig()
    return CopyConfig(cfg)
end

function Guild:IsCouncil(key, real)
    if type(key) ~= "string" then return false end
    if not real and Util.IsMe(key) then
        local Demo = ns.Demo
        if Demo and Demo.IsEnabled and Demo:IsEnabled() then return true end
    end
    local m = Guild:GetMember(key, real)
    if type(m) ~= "table" then return false end
    local lk = strlower(key)
    if cfg.remove[key] or removeLower[lk] then return false end
    if cfg.add[key] or addLower[lk] then return true end
    local rankIndex = tonumber(m.rankIndex)
    return rankIndex ~= nil and rankIndex <= cfg.rank
end

function Guild:AmICouncil(real)
    local me = Util.PlayerKey()
    return me ~= nil and Guild:IsCouncil(me, real)
end

function Guild:GetCouncilMembers()
    local out = {}
    for _, key in ipairs(Guild:GetMembers()) do
        if Guild:IsCouncil(key) then out[#out + 1] = key end
    end
    return out
end

function Guild:GetGuildPhase()
    return cfg.phase or DEFAULT_PHASE
end

function Guild:GetViewPhase()
    local settings = ns.db and ns.db.settings
    local vp = settings and tonumber(settings.viewPhase)
    if vp and vp >= 1 and vp <= MaxPhase() and vp == math.floor(vp) then
        return vp
    end
    return cfg.phase or DEFAULT_PHASE
end

function Guild:CanEditConfig()
    return (IsInGuild() and CanEditGuildInfo and CanEditGuildInfo()) and true or false
end

-- Writing the Guild Information ---------------------------------------------------------------
-- The game can only replace the WHOLE text, so the write is "read current text, swap in the tag,
-- write it back". Right after login the client may still report the text as "" because it
-- hasn't arrived from the server yet; writing then would erase the guild's text. Therefore:
--   * a non-empty read is written immediately (tag replaced in place / appended),
--   * an empty read triggers a fresh roster request and the write is retried once the text
--     arrives; if it is still empty we refuse when we have seen text for this guild before,
--     otherwise we ask for an explicit confirmation,
--   * the previous text is backed up before every write (/cdl guildinfo to list / restore).
local MAX_INFO_BACKUPS = 5
local WRITE_RETRY_TIMEOUT = 8
local deferredWrite             -- { cfg = c, deadline = GetTime() + timeout } while waiting for the text

local function ServerTime()
    return GetServerTime and GetServerTime() or time()
end

local function NormalizedWriteConfig(newCfg)
    return {
        rank = tonumber(newCfg.rank) or DEFAULT_RANK,
        phase = tonumber(newCfg.phase) or DEFAULT_PHASE,
        add = type(newCfg.add) == "table" and newCfg.add or {},
        remove = type(newCfg.remove) == "table" and newCfg.remove or {},
    }
end

local function Backups()
    local db = ns.db
    if not db then return {} end
    if type(db.guildInfoBackups) ~= "table" then db.guildInfoBackups = {} end
    return db.guildInfoBackups
end

local function PushBackup(text)
    if type(text) ~= "string" or text == "" then return end
    local list = Backups()
    local last = list[#list]
    if last and last.text == text and last.guild == GuildKey() then return end
    list[#list + 1] = { guild = GuildKey(), text = text, ts = ServerTime(), by = Util.PlayerKey() }
    while #list > MAX_INFO_BACKUPS do table.remove(list, 1) end
end

-- Remembers that this guild's info text has been non-empty (evidence for the empty-read guard).
local function NoteInfoTextSeen(text)
    local db = ns.db
    local gkey = GuildKey()
    if db and gkey and type(text) == "string" and text ~= "" then
        db.guildInfoSeen = db.guildInfoSeen or {}
        db.guildInfoSeen[gkey] = true   -- a flag, not a timestamp: keeps SavedVariables stable across relogs
    end
end

local function HaveSeenInfoText()
    local db = ns.db
    local gkey = GuildKey()
    return db and gkey and type(db.guildInfoSeen) == "table" and db.guildInfoSeen[gkey] ~= nil or false
end

local function CommitInfoText(c, current)
    local setInfoText = InfoTextSetter()
    if not setInfoText then return false end
    local tag = Guild:BuildTag(c)
    local text = current or ""
    local s, e = text:find("CDL%b{}")
    if s then
        text = strsub(text, 1, s - 1) .. tag .. strsub(text, e + 1)
    else
        if text ~= "" and not text:find("\n$") then text = text .. "\n" end
        text = text .. tag
    end
    if #text > MAX_INFO_LEN then
        ns:Print("The Guild Information text would be too long (%d / %d characters). Shorten it first.", #text, MAX_INFO_LEN)
        return false
    end
    PushBackup(current)
    setInfoText(text)
    pendingText, pendingUntil = text, GetTime() + PENDING_WRITE_GRACE
    ApplyConfig()
    Guild:RequestRoster(true)
    return true
end

local function EnsureInfoPopups()
    local dialogs = StaticPopupDialogs
    if type(dialogs) ~= "table" then return false end
    if not dialogs.CDLOOT_GUILDINFO_EMPTY then
        dialogs.CDLOOT_GUILDINFO_EMPTY = {
            text = "CDLoot: your Guild Information text reads as EMPTY.\n\n"
                .. "If your guild has text there, press Cancel, open the Guild window's Guild Info once "
                .. "and try again.\n\nWrite only the tag %s?",
            button1 = YES or "Yes",
            button2 = CANCEL or "Cancel",
            OnAccept = function(self, data)
                local c = data or self.data
                if type(c) == "table" and Guild:CanEditConfig() and CommitInfoText(c, ReadInfoText() or "") then
                    ns:Print("Loot Council settings saved to the Guild Information.")
                end
            end,
            timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        }
    end
    if not dialogs.CDLOOT_GUILDINFO_RESTORE then
        dialogs.CDLOOT_GUILDINFO_RESTORE = {
            text = "CDLoot: replace the current Guild Information text with the backup from %s?",
            button1 = ACCEPT or "Accept",
            button2 = CANCEL or "Cancel",
            OnAccept = function(self, data)
                local b = data or self.data
                local setInfoText = InfoTextSetter()
                if type(b) ~= "table" or type(b.text) ~= "string" or not setInfoText
                    or not Guild:CanEditConfig() then return end
                PushBackup(ReadInfoText())
                setInfoText(b.text)
                pendingText, pendingUntil = b.text, GetTime() + PENDING_WRITE_GRACE
                ApplyConfig()
                Guild:RequestRoster(true)
                ns:Print("Guild Information restored from the backup.")
            end,
            timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        }
    end
    return true
end

-- Called when a deferred write is due (fresh roster arrived, or timed out).
local function FinishDeferredWrite(timedOut)
    local job = deferredWrite
    if not job then return end
    local text = ReadInfoText()
    if (text == nil or text == "") and not timedOut and GetTime() < job.deadline then
        return -- keep waiting for a roster update that carries the text
    end
    deferredWrite = nil
    if not Guild:CanEditConfig() then
        ns:Print("You don't have permission to edit the Guild Information text.")
        return
    end
    if text and text ~= "" then
        if CommitInfoText(job.cfg, text) then
            ns:Print("Loot Council settings saved to the Guild Information.")
        end
    elseif HaveSeenInfoText() then
        ns:Print("Couldn't read your Guild Information text yet, so nothing was written (to avoid erasing it). "
            .. "Open the Guild window's Guild Info once, then press Save again.")
    elseif EnsureInfoPopups() and StaticPopup_Show then
        StaticPopup_Show("CDLOOT_GUILDINFO_EMPTY", Guild:BuildTag(job.cfg), nil, job.cfg)
    end
end

-- Writes the tag into the Guild Information text (replacing an existing CDL{...} tag in place and
-- keeping every other character). Returns true when written now; false when refused or when the
-- write was deferred until the current text has loaded (the outcome is then printed).
function Guild:WriteConfig(newCfg)
    if type(newCfg) ~= "table" then return false end
    if not Guild:CanEditConfig() or not InfoTextSetter() then
        ns:Print("You don't have permission to edit the Guild Information text.")
        return false
    end
    local c = NormalizedWriteConfig(newCfg)
    local text = ReadInfoText()
    if text and text ~= "" then
        return CommitInfoText(c, text)
    end
    -- Empty read: fetch the current text from the server first, then decide. Poll once a second
    -- (the text can become readable independently of the order of GUILD_ROSTER_UPDATE handlers).
    local job = { cfg = c, deadline = GetTime() + WRITE_RETRY_TIMEOUT }
    deferredWrite = job
    ns:Print("Loading the current Guild Information before saving…")
    Guild:RequestRoster(true)
    local function Poll()
        if deferredWrite ~= job then return end
        FinishDeferredWrite(GetTime() >= job.deadline)
        if deferredWrite == job then Util.After(1, Poll) end
    end
    Util.After(1, Poll)
    return false
end

-- Backups of the Guild Information text taken before each CDLoot write (newest last).
function Guild:GetInfoBackups()
    local out = {}
    for _, b in ipairs(Backups()) do
        if type(b) == "table" and type(b.text) == "string" then out[#out + 1] = b end
    end
    return out
end

function Guild:RestoreInfoBackup(index)
    local list = Guild:GetInfoBackups()
    local b = list[tonumber(index) or #list]
    if not b then
        ns:Print("No Guild Information backup #%s.", tostring(index))
        return false
    end
    if not Guild:CanEditConfig() then
        ns:Print("You don't have permission to edit the Guild Information text.")
        return false
    end
    if EnsureInfoPopups() and StaticPopup_Show then
        StaticPopup_Show("CDLOOT_GUILDINFO_RESTORE", date("%Y-%m-%d %H:%M", b.ts or 0), nil, b)
        return true
    end
    return false
end

local function GuildInfoSlash(rest)
    local cmd, arg = strmatch(rest or "", "^%s*(%S*)%s*(.-)%s*$")
    cmd = strlower(cmd or "")
    local list = Guild:GetInfoBackups()
    if cmd == "restore" then
        Guild:RestoreInfoBackup(arg ~= "" and arg or nil)
        return
    end
    if #list == 0 then
        ns:Print("No Guild Information backups yet (one is taken before every CDLoot save).")
        return
    end
    ns:Print("Guild Information backups (newest last) — /cdl guildinfo restore <n>:")
    for i, b in ipairs(list) do
        local preview = b.text:gsub("\n", " / ")
        if #preview > 60 then preview = strsub(preview, 1, 57) .. "..." end
        ns:Print("%d) %s — %d chars: %s", i, date("%Y-%m-%d %H:%M", b.ts or 0), #b.text, preview)
    end
end

-- Hooks used by functions defined earlier in this file (Lua locals aren't visible upward).
function Guild:NoteInfoTextSeen(text)
    NoteInfoTextSeen(text)
end

function Guild:OnInfoTextMaybeLoaded()
    if deferredWrite then FinishDeferredWrite(false) end
end

ns:RegisterSlash("guildinfo", GuildInfoSlash, "list or restore Guild Information backups (taken before each CDLoot save)")

-- CDLoot extensions used by Comm (not in the spec): a whisper/addon message from someone proves
-- they are online; a "No player named ..." system message proves they are not.
function Guild:MarkOnline(key)
    local m = type(key) == "string" and roster[key]
    if m then m.online = true end
end

function Guild:MarkOffline(key)
    local m = type(key) == "string" and roster[key]
    if m then m.online = false end
end
