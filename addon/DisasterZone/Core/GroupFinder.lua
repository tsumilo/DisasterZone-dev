if DisasterZoneBoot and DisasterZoneBoot.Run("Core/GroupFinder.lua", ...) then return end -- DisasterZone: my dungeon run in Blizzard's Group Finder.
-- When the guild can't fill my run, it goes into Blizzard's Group Finder. In this client (2.5.6) that is a bulletin
-- board: groups and solo players list themselves for dungeons, people whisper a group's leader, and a leader invites
-- solo players straight away. There are no applications to answer.
--
-- What the client lets an addon do (classic_anniversary source): create, update and remove a listing, and search,
-- only inside a click (a hardware event; CreateListing, UpdateListing, RemoveListing and Search). The listing's comment
-- box refuses text from addons (SetSecurityDisableSetText), so a note is the player's to type in Blizzard's window.
-- Reading the listing and the search results (name, class, level, roles, zone and comment of each solo player) is
-- free, and so is inviting.
--
-- The candidates for my run: the solo players listed for its dungeon (from my last search; the client keeps them up to
-- date while they stay in the results) and whoever whispers me while my listing is up, guild members and my party
-- left out. Nothing here goes to the guild: Core/DungeonRuns.lua picks the pugs up from the party like anyone else,
-- with the role they were invited as.
local addonName, ns = ...

local GF = ns:NewModule("GroupFinder")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, select = type, pairs, ipairs, tonumber, tostring, select
local tsort, wipe = table.sort, wipe or function(t) for k in pairs(t) do t[k] = nil end end
local strlower, strfind, strsub, strgsub = string.lower, string.find, string.sub, string.gsub

local WHISPER_TTL = 20 * 60        -- a whisper stays a candidate this long
local TEXT_MAX = 120               -- characters kept of a whisper or a listing's comment
local SEARCH_GAP = 3               -- seconds between two searches of mine (the server throttles them)
local PROMPT_TICK = 15
local HEROIC_LEVEL = 70
local ROLE_RANK = { tank = 1, healer = 2, dps = 3 }

local function R() return ns.DungeonRuns end
local function Now() return (GetServerTime and GetServerTime()) or time() end
local function DemoOn() local D = ns.Demo; return (D and D.IsEnabled and D:IsEnabled()) and true or false end

local function Changed()
    Util.Debounce("group-finder-changed", 0.15, function() ns:Fire("GROUP_FINDER_UPDATED") end)
end

local function InGuild(key)
    local g = ns.Guild
    return (g and g.IsInGuild and g:IsInGuild(key)) and true or false
end

local function InParty(key)
    return (Util.group and Util.group[key]) and true or false
end

-- A whisper or a comment as one plain line: links keep their [name], colours / textures / escape codes go, no line
-- breaks, at most TEXT_MAX characters; nil if empty.
local function Clean(text)
    if type(text) ~= "string" then return nil end
    text = strgsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = strgsub(text, "|r", "")
    text = strgsub(text, "|H.-|h(.-)|h", "%1")
    text = strgsub(text, "|[TA].-|[ta]", "")
    text = strgsub(text, "|K.-|k", "?")
    text = strgsub(text, "|n", " ")
    text = strgsub(strgsub(text, "|", ""), "[\r\n]+", " ")
    text = Util.Trim(text)
    if #text > TEXT_MAX then text = strsub(text, 1, TEXT_MAX) end
    return text ~= "" and text or nil
end

local function RunName(run)
    local d = R():GetDungeon(run.d)
    return (d and d.name or tostring(run.d)) .. (run.h and " (Heroic)" or "")
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local activities                   -- ["ShatteredHalls:h"] = { id, cat, name } (built once the client knows them)
local found = {}                   -- [key] = { key, class, level, roles, text, area, rid, at } (solo players listed)
local whispers = {}                -- [key] = { key, class, text, at }
local invited = {}                 -- [key] = { at, role }
local hidden = {}                  -- [key] = true: set aside by me for this run
local entry = {}                   -- my listing as this session made it: { run = id, at = since }
local search = {}                  -- my last search: { busy, t = GetTime(), run = id, activity }
local prompted = {}                -- [run id] = true: asked once whether to list it, or listed / unlisted by hand
local listedRuns = {}              -- [run id] = true: I listed it in the Group Finder (until I take it out)
local demo = {}                    -- demo mode: { listed, at }

---------------------------------------------------------------------------
-- Activities: which Group Finder entry is which dungeon
---------------------------------------------------------------------------

local function Slot(dkey, heroic) return dkey .. (heroic and ":h" or ":n") end

-- The client's 5-man activities matched to the dungeons, by instance map id, else by name.
local function BuildActivities()
    local L = C_LFGList
    if not (L and L.GetAvailableActivities and L.GetActivityInfoTable) then return end
    local ids, seen = {}, {}
    local function take(list)
        for _, id in ipairs(type(list) == "table" and list or {}) do
            if not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    local cats = L.GetAvailableCategories and L.GetAvailableCategories()
    for _, cat in ipairs(type(cats) == "table" and cats or {}) do take(L.GetAvailableActivities(cat)) end
    if #ids == 0 then take(L.GetAvailableActivities()) end
    local words = {}
    for _, key in ipairs(R():GetDungeonKeys()) do
        local d = R():GetDungeon(key)
        words[#words + 1] = { key = key, word = strlower((strgsub(d and d.name or key, "^The ", ""))) }
    end
    local out, any = {}, false
    for _, id in ipairs(ids) do
        local a = L.GetActivityInfoTable(id)
        if type(a) == "table" and (tonumber(a.maxNumPlayers) or 5) <= 5 then
            local full = strlower(tostring(a.fullName or ""))
            local d = R():GetDungeonByMap(a.mapID)
            if not d then
                for _, w in ipairs(words) do
                    if strfind(full, w.word, 1, true) then d = R():GetDungeon(w.key) break end
                end
            end
            if d then
                local heroic = a.isHeroicActivity or a.difficultyID == 2 or strfind(full, "heroic", 1, true) ~= nil
                local slot = Slot(d.key, heroic and true or false)
                if not out[slot] then
                    out[slot] = { id = id, cat = a.categoryID, name = a.fullName }
                    any = true
                end
            end
        end
    end
    if any then activities = out end   -- else: the client doesn't know them yet, try again next time
end

-- The Group Finder activity of a dungeon (heroic or normal): id, category id; nil when the client has none.
function GF:GetActivity(dkey, heroic)
    if not activities then BuildActivities() end
    local a = activities and activities[Slot(dkey, heroic and true or false)]
    if a then return a.id, a.cat end
    return nil
end

---------------------------------------------------------------------------
-- Listing and search (clicks only)
---------------------------------------------------------------------------

-- Can I use the Group Finder at all here?
function GF:IsAvailable()
    if DemoOn() then return true end
    local L = C_LFGList
    if not (L and L.CreateListing and L.Search and L.HasActiveEntryInfo) then return false end
    if C_LFGInfo and C_LFGInfo.CanPlayerUsePremadeGroup and not C_LFGInfo.CanPlayerUsePremadeGroup() then
        return false
    end
    return true
end

-- My party's listing: listed (anything), forRun (for that run's dungeon), since (when I listed it for that run, this
-- session; nil when unknown).
function GF:GetListing(run)
    if DemoOn() then
        local on = demo.listed and true or false
        return on, on, on and demo.at or nil
    end
    local L = C_LFGList
    if not (L and L.HasActiveEntryInfo and L.HasActiveEntryInfo()) then return false, false, nil end
    local info = L.GetActiveEntryInfo and L.GetActiveEntryInfo()
    local id = run and self:GetActivity(run.d, run.h)
    local match = false
    local list = type(info) == "table" and info.activityIDs
    for _, a in ipairs(type(list) == "table" and list or {}) do
        if id and a == id then match = true end
    end
    local since = (match and run and entry.run == run.id) and entry.at or nil
    return true, match, since
end

-- Looks for solo players listed for my run's dungeon. A click only. force: even right after another search (the one
-- that comes with listing). Returns true when the search went out.
function GF:Search(run, force)
    run = run or R():GetMine()
    if not run then return false end
    if DemoOn() then
        Changed()
        return true
    end
    local id, cat = self:GetActivity(run.d, run.h)
    local L = C_LFGList
    if not id or not cat or not (L and L.Search) then return false end
    if not force and search.busy and GetTime() - (search.t or 0) < SEARCH_GAP then return false end
    search.busy, search.t, search.run, search.activity = true, GetTime(), run.id, id
    L.Search(cat, 0, 0, nil, false, nil, { id })
    Changed()
    return true
end

-- Is a search of mine on its way?
function GF:IsSearching()
    return (search.busy and GetTime() - (search.t or 0) < 15) and true or false
end

-- Lists my party in the Group Finder as my run's dungeon (or switches the listing to it), then searches for solo
-- players there. A click only: the client takes listings inside a hardware event. Returns ok, why.
function GF:List(run)
    run = run or R():GetMine()
    if not run then return false, "List your run first." end
    if not self:IsAvailable() then return false, "The Group Finder isn't open to you here." end
    if not R():CanInvite() then return false, "Only the party leader can list the party." end
    prompted[run.id] = true
    if DemoOn() then
        demo.listed, demo.at = true, Now()
        Changed()
        return true
    end
    local id = self:GetActivity(run.d, run.h)
    if not id then return false, "The Group Finder has no entry for " .. RunName(run) .. "." end
    local L = C_LFGList
    local data = { activityIDs = { id }, newPlayerFriendly = false }
    local listed = L.HasActiveEntryInfo()
    if listed then
        L.UpdateListing(data)
    else
        -- a note left in Blizzard's window from another listing would go out with this one: start without
        if L.ClearCreationTextFields then L.ClearCreationTextFields() end
        L.CreateListing(data)
    end
    if entry.run ~= run.id or not listed then entry.at = Now() end
    entry.run = run.id
    listedRuns[run.id] = true
    wipe(hidden)
    self:Search(run, true)
    Changed()
    return true
end

-- Takes my party out of the Group Finder. A click only.
function GF:Unlist()
    local run = R():GetMine()
    if run then
        prompted[run.id] = true
        listedRuns[run.id] = nil
    end
    entry.run, entry.at = nil, nil
    if DemoOn() then
        demo.listed = false
        Changed()
        return true
    end
    local L = C_LFGList
    if L and L.HasActiveEntryInfo and L.HasActiveEntryInfo() and L.RemoveListing then L.RemoveListing() end
    Changed()
    return true
end

-- Did I put that run in the Group Finder (and not take it out)? The listing itself is gone once the lead passes:
-- the new leader is asked to list it again.
function GF:HasListed(runId) return listedRuns[runId] and true or false end

-- Opens Blizzard's Group Finder on my listing (to write its note: only the player can).
function GF:OpenBlizzard()
    if not LFGParentFrame then
        local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
        if load then pcall(load, "Blizzard_GroupFinder_VanillaStyle") end
    end
    if ShowLFGParentFrame then
        ShowLFGParentFrame(1)
        return true
    end
    if ToggleLFGParentFrame then
        ToggleLFGParentFrame(1)
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Candidates: solo players from the search, whispers while listed
---------------------------------------------------------------------------

local function HasActivity(info, id)
    local list = type(info) == "table" and info.activityIDs
    if type(list) ~= "table" then return id == nil end
    for _, a in ipairs(list) do
        if a == id then return true end
    end
    return false
end

local function ReadResult(rid)
    for key, e in pairs(found) do
        if e.rid == rid then found[key] = nil end
    end
    local L = C_LFGList
    local info = L.GetSearchResultInfo(rid)
    if type(info) ~= "table" or info.isDelisted or info.hasSelf or (tonumber(info.numMembers) or 0) ~= 1 then return end
    if not HasActivity(info, search.activity) then return end
    local p = L.GetSearchResultPlayerInfo and L.GetSearchResultPlayerInfo(rid, 1)
    p = type(p) == "table" and p or {}
    local key = Util.NormalizeName(p.name or info.leaderName)
    if not key or Util.IsMe(key) or InGuild(key) then return end
    local lr = type(p.lfgRoles) == "table" and p.lfgRoles or {}
    found[key] = {
        key = key, class = p.classFilename, level = tonumber(p.level), area = Clean(p.areaName), rid = rid,
        roles = { tank = lr.tank and true or nil, healer = lr.healer and true or nil, dps = lr.dps and true or nil },
        text = Clean(info.comment), at = Now() - (tonumber(info.age) or 0),
    }
end

local function OnResults()
    local L = C_LFGList
    if not (L and L.GetSearchResults and search.run) then return end
    -- my own search replaces what I had; one from Blizzard's window only adds the matching players to it
    if search.busy then wipe(found) end
    search.busy = false
    local _, list = L.GetSearchResults()
    for _, rid in ipairs(type(list) == "table" and list or {}) do ReadResult(rid) end
    Changed()
end

local function OnWhisper(_, text, sender, ...)
    local guid = select(10, ...)   -- CHAT_MSG_WHISPER's 12th argument
    local run = R():GetMine()
    if not run or not GF:GetListing(run) then return end
    local key = type(sender) == "string" and Util.NormalizeName(sender)
    if not key or Util.IsMe(key) or InGuild(key) or InParty(key) then return end
    local class = whispers[key] and whispers[key].class
    if type(guid) == "string" and guid ~= "" and GetPlayerInfoByGUID then
        local _, c = GetPlayerInfoByGUID(guid)
        class = c or class
    end
    whispers[key] = { key = key, class = class or (found[key] and found[key].class), text = Clean(text), at = Now() }
    hidden[key] = nil
    Changed()
end

local DEMO_PUGS = {
    { "Thalindra", "PRIEST", 70, { healer = true }, "holy priest, can heal it, inv pls", 2, true },
    { "Brokkar", "WARRIOR", 70, { tank = true, dps = true }, "LF heroics, have the keys", 9 },
    { "Seraphine", "MAGE", 70, { dps = true }, nil, 14 },
    { "Kezzik", "ROGUE", 69, { dps = true }, "need 1 more level, any dungeon", 21 },
}

local function DemoCandidates(run)
    if not demo.listed then return {}, {}, {} end
    local w, f = {}, {}
    for _, x in ipairs(DEMO_PUGS) do
        local key = Util.NormalizeName(x[1])
        if x[7] then
            w[key] = { key = key, class = x[2], text = x[5], at = Now() - x[6] * 60 }
        end
        f[key] = { key = key, class = x[2], level = x[3], roles = x[4], text = (not x[7]) and x[5] or nil,
                   area = "Shattrath City", at = Now() - x[6] * 60 }
    end
    return w, f
end

local function Fit(open, roles)
    for _, role in ipairs(R().ROLES) do
        if open[role] and roles and roles[role] then return role end
    end
    return nil
end

-- The players outside the guild who could fill my run: whoever whispered me while listed (newest first), then the
-- solo players listed there whose roles fit an open place (tanks, healers, then DPS). Set-aside players and my party
-- are left out. { { key, class, level, roles, text, area, at, whispered, role = the open role they fit, invited } }.
function GF:GetCandidates(run)
    run = run or R():GetMine()
    if not run then return {} end
    local ws, fs = whispers, found
    if DemoOn() then ws, fs = DemoCandidates(run) end
    local open = R():GetOpenRoles(run)
    local now = Now()
    local out, seen = {}, {}
    local function add(key, w, f)
        if seen[key] or hidden[key] or InParty(key) or R():IsInRun(run, key) then return end
        seen[key] = true
        local roles = (f and f.roles) or {}
        out[#out + 1] = {
            key = key, class = (w and w.class) or (f and f.class), level = f and f.level, roles = roles,
            text = (w and w.text) or (f and f.text), area = f and f.area, at = (w and w.at) or (f and f.at),
            whispered = w ~= nil or nil, role = Fit(open, roles), invited = invited[key] ~= nil or nil,
        }
    end
    local wl = {}
    for _, w in pairs(ws) do
        if now - (w.at or 0) <= WHISPER_TTL then wl[#wl + 1] = w end
    end
    tsort(wl, function(a, b)
        if a.at ~= b.at then return a.at > b.at end
        return a.key < b.key
    end)
    for _, w in ipairs(wl) do add(w.key, w, fs[w.key]) end
    local fl = {}
    for _, f in pairs(fs) do
        local ok = Fit(open, f.roles) ~= nil and not (run.h and f.level and f.level < HEROIC_LEVEL)
        if ok then fl[#fl + 1] = f end
    end
    tsort(fl, function(a, b)
        local ra, rb = ROLE_RANK[Fit(open, a.roles)], ROLE_RANK[Fit(open, b.roles)]
        if ra ~= rb then return ra < rb end
        if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
        return a.key < b.key
    end)
    for _, f in ipairs(fl) do add(f.key, nil, f) end
    return out
end

-- Invites a candidate to my party (as the open role their listing fits). Returns ok, why.
function GF:Invite(key)
    local run = R():GetMine()
    if not run or type(key) ~= "string" then return false, "List your run first." end
    if not R():CanInvite() then return false, "Only the party leader can invite." end
    local role
    for _, c in ipairs(self:GetCandidates(run)) do
        if c.key == key then role = c.role end
    end
    if DemoOn() then
        run.s[#run.s + 1] = { k = key, r = role or "dps" }
        invited[key] = { at = Now(), role = role }
        ns:Fire("DUNGEON_RUNS_UPDATED")
        Changed()
        return true
    end
    R():SetGuestRole(key, role)
    local name = (Ambiguate and Ambiguate(key, "none")) or key
    if C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(name) else InviteUnit(name) end
    invited[key] = { at = Now(), role = role }
    Changed()
    return true
end

-- Sets a candidate aside for this run (until they whisper again).
function GF:Dismiss(key)
    if type(key) ~= "string" then return end
    hidden[key] = true
    Changed()
end

-- Starts a whisper to somebody in the chat box.
function GF:Whisper(key)
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if open and type(key) == "string" then open("/w " .. ((Ambiguate and Ambiguate(key, "none")) or key) .. " ") end
end

---------------------------------------------------------------------------
-- A run for later that should go to the Group Finder when it starts: one prompt (a click lists it)
---------------------------------------------------------------------------

local function CheckPrompt()
    local run = R():GetMine()
    if not run or not run.gf or prompted[run.id] or not R():IsNow(run) then return end
    if not GF:IsAvailable() or GF:GetListing(run) then return end
    local open = 0
    for _, n in pairs(R():GetOpenRoles(run)) do open = open + n end
    if open == 0 then return end
    prompted[run.id] = true
    ns:Fire("GROUP_FINDER_PROMPT", run.id)
end

local lastRun   -- my run as it was last seen ({ id, d, h }): what a listing left behind was for

-- A run of mine that ended by itself (party full, time up, a raid) but that I listed here: the listing stays up (only
-- a click takes it down), so pugs keep coming. Once the client had a moment to delist it on its own, ask once.
local function CheckLeftover(old)
    Util.After(2, function()
        if R():GetMine() or not listedRuns[old.id] then return end
        local L = C_LFGList
        if not (L and L.HasActiveEntryInfo and L.HasActiveEntryInfo()) then
            listedRuns[old.id] = nil
            return
        end
        if IsInGroup() and not UnitIsGroupLeader("player") then return end   -- the party's listing isn't mine now
        ns:Fire("GROUP_FINDER_LEFTOVER", old)
    end)
end

-- Takes down the listing my ended run (old = { id, d, h }) left behind. A click only.
function GF:RemoveLeftover(old)
    if old then listedRuns[old.id] = nil end
    local L = C_LFGList
    if L and L.HasActiveEntryInfo and L.HasActiveEntryInfo() and L.RemoveListing then L.RemoveListing() end
    Changed()
end

-- Forgets what belonged to a run that is no longer mine.
local function CheckRun()
    local run = R() and R():GetMine()
    if not run then
        if lastRun and not DemoOn() then
            CheckLeftover(lastRun)
        end
        lastRun = nil
        if next(found) or next(whispers) or next(hidden) or next(invited) or entry.run or demo.listed then
            wipe(found)
            wipe(whispers)
            wipe(hidden)
            wipe(invited)
            entry.run, entry.at, search.run, demo.listed = nil, nil, nil, nil
            Changed()
        end
        return
    end
    lastRun = { id = run.id, d = run.d, h = run.h }
    if search.run and search.run ~= run.id then
        wipe(found)
        search.run = nil
        Changed()
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function GF:OnInit()
    ns:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED", OnResults)
    ns:RegisterEvent("LFG_LIST_SEARCH_FAILED", function()
        search.busy = false
        Changed()
    end)
    ns:RegisterEvent("LFG_LIST_SEARCH_RESULT_UPDATED", function(_, rid)
        if search.run and C_LFGList and C_LFGList.GetSearchResultInfo then
            ReadResult(rid)
            Changed()
        end
    end)
    ns:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE", function()
        if not (C_LFGList and C_LFGList.HasActiveEntryInfo and C_LFGList.HasActiveEntryInfo()) then
            entry.run, entry.at = nil, nil
        end
        Changed()
    end)
    ns:RegisterEvent("LFG_LIST_ENTRY_EXPIRED_TIMEOUT", function()
        if R():GetMine() then ns:Print("Your Group Finder listing ran out.") end
        Changed()
    end)
    ns:RegisterEvent("LFG_LIST_ENTRY_CREATION_FAILED", function()
        ns:Print("The Group Finder didn't take the listing.")
        Changed()
    end)
    ns:RegisterEvent("LFG_LIST_AVAILABILITY_UPDATE", function() activities = nil end)
    ns:RegisterEvent("CHAT_MSG_WHISPER", OnWhisper)
    ns:On("DUNGEON_RUNS_UPDATED", CheckRun)
    ns:On("GROUP_UPDATED", Changed)
    -- my invite didn't reach a pug (they said no, are in a group, or went offline): Invite again
    ns:On("PARTY_INVITE_FAILED", function(key)
        if invited[key] then
            invited[key] = nil
            Changed()
        end
    end)
    ns:On("DEMO_TOGGLED", function()
        demo = {}
        Changed()
    end)
end

function GF:OnLogin()
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(PROMPT_TICK, CheckPrompt) end
end
