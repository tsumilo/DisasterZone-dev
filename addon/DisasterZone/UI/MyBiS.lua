if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MyBiS.lua", ...) then return end -- DisasterZone UI/MyBiS.lua
-- ns.MyBiS: the "My BiS" tab. A top bar (the phases, Main spec / Off spec, the spec, Suggest, More: import, export,
-- copy, clear), the editable paper doll (every slot says where its item comes from) and the centre: how much of the
-- phase is obtained, the character wearing the picks, and what is still to get by source (hover a count for the items).
-- ADDENDUM F: slots can be disabled per phase from the tile menu (§36; left out of the progress), crafted /
-- reputation / badge / PvP items count under their own source (§37), and while the group's raid leader locks the BiS
-- lists the top bar says so and only what still works is offered (§38).
-- ADDENDUM H: the spec tabs switch the whole tab (doll, spec, tools, centre) between the two lists.
-- Gems and enchants: every pick's strip on its tile (UI/PaperDoll.lua) opens the editor (UI/GemEditor.lua); the
-- centre says how many gems and enchants the phase has under the obtained count; Suggest also fills them.
-- The first phase tab is the Pre-raid list (phase 0: dungeons, reputation, crafting, badges; only its owner sees it).
-- My BiS reopens there when it was the last phase picked, else on the guild's phase.
-- One spacing grid (the Raids and Dungeons tabs' too): PAD at the page's sides, GAP between blocks, every tile 48 high.
local addonName, ns = ...

local MyBiS = {}
ns.MyBiS = MyBiS

local floor, min, max = math.floor, math.min, math.max

local NUM_SLOTS = 17

local PAD, GAP = 10, 8
local TOP_Y, BAR_H = -8, 24              -- the top bar
local DOLL_Y = TOP_Y - BAR_H - GAP       -- the doll: 770 x 496 from here (UI/PaperDoll.lua "page" layout)
local SEG_W, SEG_STAR_W = 34, 46         -- a phase button (with the guild phase's star)
local SUGGEST_W = 84
local ROW_H, MAX_ROWS = 18, 4             -- the centre's still-to-get rows
local LIST_COL_W = 172                    -- their width
local BAR_W = 140
local PLATFORM_W, PLATFORM_Y = 180, 14    -- the pedestal under the model (texture centre above the model place's bottom)

local GOLD = { 1, 0.82, 0 }
local RED = { 0.92, 0.38, 0.32 }
local CELL_BG = { 0.08, 0.08, 0.095, 0.9 }
local EDGE = { 0.34, 0.34, 0.38, 0.5 }

-- Icons (file IDs from the installed client; Interface\Icons and Interface\LFGFrame).
local ICON = {
    badge = 135884,     -- Spell_Holy_ChampionsBond (Badge of Justice)
    rep = 134411,       -- INV_Misc_Ribbon_01
    pvp = 132486,       -- INV_BannerPVP_02
    craft = 136241,     -- Trade_BlackSmithing
    dungeon = 136334,   -- LFGIcon-Dungeon
    raid = 136351,      -- LFGIcon-Raid
    other = 134400,     -- INV_Misc_QuestionMark
    copy = 17,          -- (UI.ICON_ATLAS index: two sheets)
}
local RAID_ICON = {
    Karazhan = 136343, GruulsLair = 136337, MagtheridonsLair = 136340, SerpentshrineCavern = 136356,
    TempestKeep = 136362, HyjalSummit = 136341, BlackTemple = 136328, ZulAman = 136367, SunwellPlateau = 136361,
}
-- the raid as a slot's line names it (else its own name), and as a count in the centre says it
local RAID_NAME = { MagtheridonsLair = "Magtheridon", SerpentshrineCavern = "Serpentshrine", HyjalSummit = "Hyjal",
                    SunwellPlateau = "Sunwell", WorldBosses = "World boss" }
local RAID_SHORT = { Karazhan = "Kara", GruulsLair = "Gruul", MagtheridonsLair = "Mag", SerpentshrineCavern = "SSC",
                     TempestKeep = "TK", HyjalSummit = "Hyjal", BlackTemple = "BT", ZulAman = "ZA",
                     SunwellPlateau = "Sunwell", WorldBosses = "World" }
local BADGE_ITEM = 29434                 -- Badge of Justice
local STANDINGS = { "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted" }

-- What is still to get, by source (the centre's counts), after the raids (by phase).
local KIND_GROUP = {
    dungeon = { key = "dungeon", label = "dungeons", name = "5-man dungeons", order = 100, icon = ICON.dungeon },
    craft = { key = "craft", label = "crafted", name = "Crafted", order = 101, icon = ICON.craft },
    rep = { key = "rep", label = "reputation", name = "Reputation", order = 102, icon = ICON.rep },
    badge = { key = "badge", label = "badges", name = "Badge of Justice vendors", order = 103, icon = ICON.badge },
    pvp = { key = "pvp", label = "PvP", name = "PvP", order = 104, icon = ICON.pvp },
    other = { key = "other", label = "other", name = "Other sources", order = 105, icon = ICON.other },
}

local panel, bar, doll, card
local phaseButtons = {}
local suggestBtn, moreBtn, lockChip
local selectedPhase, userPickedPhase
local selectedList = "ms"   -- Addendum H: "ms" | "os" (session only)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function MaxPhase() return ns.MAX_PHASE or 5 end

local PRE_RAID = ns.PRE_RAID or 0

-- A list phase: Pre-raid (0) or a raid phase 1..5.
local function ClampPhase(p)
    p = tonumber(p) or 1
    if p < PRE_RAID then p = PRE_RAID end
    if p > MaxPhase() then p = MaxPhase() end
    return math.floor(p)
end

-- "Pre-raid" / "P2".
local function PL(p)
    if ns.PhaseLabel then return ns.PhaseLabel(p) end
    return "P" .. tostring(p)
end

-- The list's phases, Pre-raid first.
local function ListPhases()
    return ns.LIST_PHASES or { 1, 2, 3, 4, 5 }
end

-- The phase strip, left to right: { phase, label, name }: Pre-raid (its own saved fields, not ph[0]), then P1..P5.
local function PhaseEntries()
    local out = {}
    for _, p in ipairs(ListPhases()) do
        local info = ns.PHASE_INFO and ns.PHASE_INFO[p]
        out[#out + 1] = { phase = p, label = info and info.short or PL(p), name = info and info.name or ("Phase " .. p) }
    end
    return out
end

local function PhaseName(p)
    for _, e in ipairs(PhaseEntries()) do
        if e.phase == p then return e.name, e.label end
    end
    return "Phase " .. tostring(p), "P" .. tostring(p)
end

local function GuildPhase()
    if ns.Guild and ns.Guild.GetGuildPhase then
        local p = ns.Guild:GetGuildPhase()
        if tonumber(p) then return ClampPhase(p) end
    end
    return nil
end

-- The Pre-raid list was the last phase this character picked (db.mybisPreRaid[charKey], never synced): My BiS reopens
-- there; any other pick goes back to following the guild phase.
local function PreRaidKey()
    local key = ns.loggedIn and ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey()
    local db = ns.db
    if not (key and db) then return nil, nil end
    if type(db.mybisPreRaid) ~= "table" then db.mybisPreRaid = {} end
    return db.mybisPreRaid, key
end

local function LeftOnPreRaid()
    local t, key = PreRaidKey()
    return (t and t[key] == true) and true or false
end

local function RememberPhase(p)
    local t, key = PreRaidKey()
    if t then t[key] = (p == PRE_RAID) or nil end
end

-- The phase My BiS opens on (and follows until the player picks one): the Pre-raid list when it was the last phase
-- picked, else the guild's (or the group's) phase.
local function OpeningPhase()
    if LeftOnPreRaid() then
        userPickedPhase = true
        return PRE_RAID
    end
    return GuildPhase() or 1
end

local function CurrentPhase()
    if not selectedPhase then selectedPhase = OpeningPhase() end
    return selectedPhase
end

-- The list argument for BiS calls: "os" while the off-spec list is shown, else nil (the main spec).
local function ListArg()
    return selectedList == "os" and "os" or nil
end

local function IsOffSpecView()
    return selectedList == "os"
end

local function HasOffSpec()
    return ns.BiS and ns.BiS.HasOffSpec and ns.BiS:HasOffSpec() or false
end

local function MyClass()
    local data = ns.BiS and ns.BiS.GetData and ns.BiS:GetData()
    if data and type(data.cl) == "string" and data.cl ~= "" then return data.cl end
    local _, classFile = UnitClass("player")
    return classFile
end

local function SlotLabel(sid)
    local s = ns.SLOTS and ns.SLOTS[sid]
    return s and s.label or ("Slot " .. tostring(sid))
end

local function PhaseItems(p)
    if not (ns.BiS and ns.BiS.GetPhaseItems) then return {} end
    return ns.BiS:GetPhaseItems(p, ListArg()) or {}
end

-- The picks { [sid] = { main, alt } } of a phase of the shown list's data (a ns.ListView), Pre-raid included.
local function PhaseSlots(data, phase)
    if ns.ListPhase then return ns.ListPhase(data, phase) end
    local t = type(data) == "table" and type(data.ph) == "table" and data.ph[phase]
    return type(t) == "table" and t or nil
end

local function Grey(text) return "|cff9e9e9e" .. tostring(text) .. "|r" end
local function Soft(text) return "|cffa8a8a8" .. tostring(text) .. "|r" end
local function Green(text) return "|cff4fd36b" .. tostring(text) .. "|r" end

-- "Prince Malchezaar" -> "Malchezaar", "The Curator" -> "Curator", "High King Maulgar" -> "Maulgar".
local TITLE_WORDS = {
    ["The"] = true, ["High"] = true, ["King"] = true, ["Lady"] = true, ["Prince"] = true,
    ["Mother"] = true, ["Fathom-Lord"] = true, ["Astromancer"] = true, ["Warlord"] = true, ["Lord"] = true,
}
local function ShortBossName(name)
    if type(name) ~= "string" then return "?" end
    for word in name:gmatch("%S+") do
        if not TITLE_WORDS[word] then return word end
    end
    return name
end

local function Debounce(key, sec, fn)
    if ns.Util and ns.Util.Debounce then
        ns.Util.Debounce(key, sec, fn)
    else
        C_Timer.After(sec, fn)
    end
end

local function Sized(fs, size)
    local path, _, flags = fs:GetFont()
    if path and size then fs:SetFont(path, size, flags) end
    return fs
end

local function Text(parent, font, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then Sized(fs, size) end
    return fs
end

local function Flat(f, bg, edge)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    bg = bg or CELL_BG
    f.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    ns.UI:AddEdges(f, "BORDER")
    edge = edge or EDGE
    ns.UI:SetEdgeColor(f, edge[1], edge[2], edge[3], edge[4])
end

-- An icon inside text (the borders of the game's icons trimmed).
local function IconText(tex, size)
    size = size or 12
    return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(tostring(tex), size, size)
end

-- §38: my list is locked by the group's raid leader (BiS:IsLocked). locked, { by, at } | nil.
local function ListLocked()
    if ns.UI and ns.UI.IsMyListLocked then return ns.UI:IsMyListLocked() end
    return false, nil
end

local function LockLine()
    local _, info = ListLocked()
    return ns.UI:LockIcon(12) .. " |cffff9a4dLocked by " .. ns.UI:LockByText(info) .. "|r"
end

-- §36: the slot is disabled in that phase (BiS:IsSlotDisabled; else the own record's dx).
local function SlotDisabled(phase, sid)
    local BiS = ns.BiS
    if not BiS then return false end
    if type(BiS.IsSlotDisabled) == "function" then return BiS:IsSlotDisabled(phase, sid, ListArg()) and true or false end
    local PD = ns.PaperDoll
    if PD and PD.IsSlotDisabled and BiS.GetRecord then return PD:IsSlotDisabled(BiS:GetRecord(), phase, sid) end
    return false
end

local function DisabledInAllPhases(sid)
    for _, p in ipairs(ListPhases()) do
        if not SlotDisabled(p, sid) then return false end
    end
    return true
end

local function CanDisableSlots()
    local BiS = ns.BiS
    return BiS and type(BiS.SetSlotDisabled) == "function" and type(BiS.SetSlotDisabledAllPhases) == "function"
end

local function SetSlotDisabled(phase, sid, disabled)
    if not CanDisableSlots() then
        ns:Print("This DisasterZone version can't disable slots.")
        return false
    end
    return ns.BiS:SetSlotDisabled(phase, sid, disabled and true or false, ListArg())
end

local function SetSlotDisabledAll(sid, disabled)
    if not CanDisableSlots() then
        ns:Print("This DisasterZone version can't disable slots.")
        return false
    end
    return ns.BiS:SetSlotDisabledAllPhases(sid, disabled and true or false, ListArg())
end

---------------------------------------------------------------------------
-- Where an item comes from (§37): the line under a slot's item, its tooltip, and the centre's group. Everything
-- here is read locally: the item database, the guild's shared recipes (Members tab data), my badges and standing.
---------------------------------------------------------------------------

-- The entry ItemDB describes an item by: the first source, except that an arena piece reached only through a tier
-- token's arena exchange is described by its own source (PvP).
local function PrimarySource(itemID)
    local sources = ns.ItemDB and ns.ItemDB.GetSources and ns.ItemDB:GetSources(itemID) or {}
    local first = sources[1]
    if first and first.via == "arena" then
        for i = 2, #sources do
            if sources[i].via ~= "arena" then return sources[i], sources end
        end
    end
    return first, sources
end

local function SourceKindOf(src)
    if type(src) ~= "table" then return nil end
    if type(src.kind) == "string" then return src.kind end
    if type(src.ref) == "table" then return src.ref.dungeon == true and "dungeon" or "raid" end
    return nil
end

local function BadgeCount()
    local n = GetItemCount and GetItemCount(BADGE_ITEM, true) or 0
    return tonumber(n) or 0
end

local function StandingIndex(text)
    for i, s in ipairs(STANDINGS) do
        if s == text then return i end
    end
    return nil
end

local function StandingName(i)
    local label = i and _G["FACTION_STANDING_LABEL" .. i]
    return (type(label) == "string" and label ~= "") and label or (i and STANDINGS[i]) or "?"
end

-- My standing with a faction (1 hated .. 8 exalted), or nil when the client doesn't know it.
local function MyStanding(factionID)
    if not (factionID and GetFactionInfoByID) then return nil end
    local _, _, standing = GetFactionInfoByID(factionID)
    return tonumber(standing)
end

-- Guild members who shared a recipe that makes the item (Members tab data): me first, then who is online.
local function Crafters(itemID)
    local P = ns.Professions
    local recipes = P and P.GetRecipesForItem and P:GetRecipesForItem(itemID)
    local out, seen = {}, {}
    for _, r in ipairs(recipes or {}) do
        for _, key in ipairs(r.crafters or {}) do
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = key
            end
        end
    end
    local Util, G = ns.Util, ns.Guild
    local function rank(key)
        if Util and Util.IsMe and Util.IsMe(key) then return 0 end
        if G and G.IsOnline and G:IsOnline(key) then return 1 end
        return 2
    end
    table.sort(out, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    return out
end

local function CrafterName(key)
    if ns.Util and ns.Util.IsMe and ns.Util.IsMe(key) then return "you" end
    return (ns.Util and ns.Util.DisplayName and ns.Util.DisplayName(key)) or key
end

local function ProfessionIcon(name)
    local P = ns.Professions
    for _, def in ipairs(P and P.GetProfessions and P:GetProfessions() or {}) do
        if def.name == name then return def.icon end
    end
    return ICON.craft
end

local function DungeonInfo(ref)
    local key = ref and ref.raid and ref.raid.key
    local info = key and ns.DungeonRuns and ns.DungeonRuns.GetDungeon and ns.DungeonRuns:GetDungeon(key)
    local name = info and info.short or ((ref and ref.raid and ref.raid.name) or "?"):gsub("^The ", "")
    local icon = info and info.complex and info.complex.icon or ICON.dungeon
    return name, icon
end

local function RaidLabel(ref)
    local raid = ref.raid or {}
    return RAID_NAME[raid.key] or raid.name or raid.key or "?"
end

-- d = { kind, icon, text (the slot's line), short (when text is too wide), group = KIND_GROUP-like table,
--       where (the item's line in the centre's tooltip) }
local function Describe(itemID)
    local src = PrimarySource(itemID)
    local kind = SourceKindOf(src)
    local d = { kind = kind or "other" }
    if kind == "raid" then
        local ref = src.ref
        local raid = ref.raid or {}
        local boss = ref.boss or {}
        -- "Shade of Aran · Kara" (the raid by its short name), else "Aran · Kara" when that doesn't fit
        local short = RAID_SHORT[raid.key] or RaidLabel(ref)
        local prefix = (src.via == "token" or src.via == "arena") and "Token · " or (src.via == "upgrade" and "Sunmote · ") or ""
        local zone = (boss.isTrash or raid.key == "WorldBosses") and "" or (" · " .. short)
        d.icon = RAID_ICON[raid.key] or ICON.raid
        if boss.isTrash then
            d.text = prefix .. short .. " trash"
            d.short = d.text
        else
            d.text = prefix .. (boss.name or "?") .. zone
            d.short = prefix .. ShortBossName(boss.name or "?") .. zone
        end
        d.where = prefix .. (boss.isTrash and "trash" or ShortBossName(boss.name))
        d.group = { key = "raid:" .. tostring(raid.key), label = RAID_SHORT[raid.key] or RaidLabel(ref),
                    name = raid.name or RaidLabel(ref), order = (tonumber(raid.phase) or 9) * 10, icon = d.icon }
    elseif kind == "dungeon" then
        local name, icon = DungeonInfo(src.ref)
        d.icon = icon
        d.text = (src.heroic and "Heroic " or "") .. name
        d.where = name .. (src.heroic and " (H)" or "")
        d.group = KIND_GROUP.dungeon
    elseif kind == "craft" then
        local crafters = Crafters(itemID)
        local prof = src.groupName or "Crafted"
        d.icon = ProfessionIcon(prof)
        if #crafters > 0 then
            d.text = "Crafted · " .. CrafterName(crafters[1]) .. (#crafters > 1 and (" +" .. (#crafters - 1)) or "")
            d.short = "Crafted · " .. CrafterName(crafters[1])
            d.where = CrafterName(crafters[1])
        else
            d.text = prof .. (src.skill and (" " .. tostring(src.skill)) or "")
            d.where = prof
        end
        d.crafters = crafters
        d.group = KIND_GROUP.craft
    elseif kind == "rep" then
        local need = StandingIndex(src.standing)
        local mine = MyStanding(src.factionID)
        local standing = src.standing or "?"
        if need and mine and mine >= need then standing = Green(standing) end
        d.icon = ICON.rep
        d.text = (src.groupName or "?") .. " · " .. standing
        d.short = standing
        d.where = (src.groupName or "?") .. " · " .. (src.standing or "?")
        d.need, d.mine = need, mine
        d.group = KIND_GROUP.rep
    elseif kind == "badge" then
        local have = BadgeCount()
        local cost = tonumber(src.cost)
        d.icon = ICON.badge
        if cost then
            local haveText = "you have " .. have
            if have >= cost then haveText = Green(haveText) end
            d.text = cost .. " badges · " .. haveText
            d.short = cost .. " badges"
            d.where = cost .. " badges"
        else
            d.text = src.groupName or "Badge vendor"
            d.where = d.text
        end
        d.have, d.cost = have, cost
        d.group = KIND_GROUP.badge
    elseif kind == "pvp" then
        local text = ns.ItemDB:FormatSource(src, true) or "PvP"
        d.icon = ICON.pvp
        d.text = text
        d.where = text
        d.group = KIND_GROUP.pvp
    else
        d.text = "Other source"
        d.where = ""
        d.group = KIND_GROUP.other
    end
    return d
end

-- ctx.source for the doll: the line under a pick that isn't obtained yet, fitted to the tile.
-- (words only: every line with the same raid's icon was noise)
local function SlotSourceText(itemID, _, fs, width)
    local d = Describe(itemID)
    local full = Soft(d.text)
    if d.short and fs and width and fs.GetStringWidth then
        fs:SetText(full)
        -- (unbounded: GetStringWidth stops at the width the line already has)
        local tw = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
        if (tonumber(tw) or 0) > width then return Soft(d.short) end
    end
    return full
end

-- ctx.sourceTip: every source (at most 4), then what is mine to know (badges, standing, the guild's crafters).
local function SlotSourceTip(itemID, tt)
    local ItemDB = ns.ItemDB
    local sources = ItemDB and ItemDB.GetSources and ItemDB:GetSources(itemID) or {}
    if #sources == 0 then
        tt:AddLine("Not in DisasterZone's loot tables: a quest, vendor or world drop.", 0.7, 0.7, 0.7, true)
        return
    end
    for i = 1, min(#sources, 4) do
        tt:AddLine(ItemDB:FormatSource(sources[i], false) or "?", 0.8, 0.8, 0.8, true)
    end
    if #sources > 4 then tt:AddLine(("+%d more"):format(#sources - 4), 0.6, 0.6, 0.6) end
    local d = Describe(itemID)
    if d.kind == "badge" then
        tt:AddLine(("You have %d Badges of Justice"):format(d.have or 0), 0.6, 0.6, 0.6)
    elseif d.kind == "rep" and d.mine then
        local src = PrimarySource(itemID)
        tt:AddLine(("You are %s with %s"):format(StandingName(d.mine), src.groupName or "?"), 0.6, 0.6, 0.6, true)
    elseif d.kind == "craft" then
        if d.crafters and #d.crafters > 0 then
            local names = {}
            for i = 1, min(#d.crafters, 6) do names[i] = CrafterName(d.crafters[i]) end
            local more = #d.crafters > 6 and (" +" .. (#d.crafters - 6)) or ""
            tt:AddLine("Can craft it: " .. table.concat(names, ", ") .. more, 0.6, 0.6, 0.6, true)
        else
            tt:AddLine("Nobody in the guild has shared this recipe yet.", 0.6, 0.6, 0.6, true)
        end
    end
end

---------------------------------------------------------------------------
-- Popups (defined lazily; only DISASTERZONE_* names)
---------------------------------------------------------------------------

local popupsReady = false
local function EnsurePopups()
    if popupsReady then return end
    popupsReady = true
    StaticPopupDialogs["DISASTERZONE_CLEAR_PHASE"] = {
        text = "Clear every main and alt pick in %s?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, data)
            if data and data.phase and ns.BiS then ns.BiS:ClearPhase(data.phase, data.list) end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopupDialogs["DISASTERZONE_REPLACE_TEMPLATE"] = {
        text = "Replace every pick in %s with the suggested BiS list for %s?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function(_, data)
            if data then MyBiS:ApplySuggestion(data.phase, true, data.list) end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopupDialogs["DISASTERZONE_RELABEL_LIST"] = {
        text = "Your %s picks become your %s list (they stay as they are: Suggest can fill it from that spec's "
            .. "guide).",
        button1 = OKAY or "Okay",
        button2 = CANCEL or "Cancel",
        OnAccept = function(_, data) if data and data.fn then data.fn() end end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopupDialogs["DISASTERZONE_REMOVE_OFFSPEC"] = {
        text = "Remove your off-spec list and all its picks?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function()
            if ns.BiS and ns.BiS:RemoveOffSpec() then
                selectedList = "ms"
                MyBiS:Refresh()
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function OpenPicker(sid, which, tile)
    if not (ns.Picker and ns.Picker.Open) then return end
    -- The picker refuses (and says why) while the lists are locked (§38).
    if ns.Picker:Open(CurrentPhase(), sid, which, tile, ListArg()) == false then return end
    if doll then doll:SetHighlight(sid) end
end

function MyBiS:OnPickerClosed()
    if doll then doll:SetHighlight(nil) end
end

-- list: "os" = fill the off-spec list from its spec (default: the list shown).
function MyBiS:ApplySuggestion(phase, overwrite, list)
    local BiS, Loon = ns.BiS, ns.Loon
    if not (BiS and Loon and Loon.IsAvailable and Loon:IsAvailable()) then
        ns:Print("The suggested BiS lists are missing: reinstall DisasterZone.")
        return
    end
    if list == nil then list = ListArg() end
    local spec = BiS:GetSpec(list) or ""
    if spec == "" then
        ns:Print("Choose your spec first (Spec dropdown).")
        return
    end
    phase = ClampPhase(phase or CurrentPhase())
    local template = Loon:GetTemplate(MyClass(), spec, phase)
    if type(template) ~= "table" or next(template) == nil then
        ns:Print("There is no suggested %s list for %s.", spec, PL(phase))
        return
    end
    -- false: refused (the lists were locked meanwhile, e.g. while the "Replace all" popup was open; §38)
    if BiS:ApplyTemplate(phase, template, overwrite and true or false, list) == false then return end
    if overwrite then
        ns:Print("Replaced %s with the suggested %s list.", PL(phase), spec)
    else
        ns:Print("Filled empty %s slots from the suggested %s list.", PL(phase), spec)
    end
end

-- "Disable slot (P1)" / "Enable slot (Pre-raid)" and "Disable in all phases" / "Enable in all phases" (§36).
local function AddDisableEntries(root, phase, sid)
    if not CanDisableSlots() then return end
    if SlotDisabled(phase, sid) then
        root:CreateButton(("Enable slot (%s)"):format(PL(phase)), function() SetSlotDisabled(phase, sid, false) end)
    else
        root:CreateButton(("Disable slot (%s)"):format(PL(phase)), function() SetSlotDisabled(phase, sid, true) end)
    end
    if DisabledInAllPhases(sid) then
        root:CreateButton("Enable in all phases", function() SetSlotDisabledAll(sid, false) end)
    else
        root:CreateButton("Disable in all phases", function() SetSlotDisabledAll(sid, true) end)
    end
end

-- While the lists are locked (§38) a menu offers only what still works, under one line that says why.
local function ShowSlotMenu(sid, tile)
    local BiS = ns.BiS
    if not BiS then return end
    local phase = CurrentPhase()
    local list = ListArg()
    local main, alt = BiS:GetSlot(phase, sid, list)
    local locked = ListLocked()
    local disabled = SlotDisabled(phase, sid)
    local suffix = list and "  ·  Off spec" or ""
    ns.UI:ContextMenu(tile, function(root)
        if disabled then
            -- A disabled slot only offers to enable it (its picks are kept).
            root:CreateTitle(SlotLabel(sid) .. "  ·  " .. PL(phase) .. suffix .. "  ·  disabled")
            if locked then
                root:CreateTitle(LockLine())
            else
                AddDisableEntries(root, phase, sid)
                if main or alt then
                    if root.CreateDivider then root:CreateDivider() end
                    root:CreateButton("Clear slot", function() BiS:ClearSlot(phase, sid, list) end)
                end
            end
            if main then
                root:CreateButton("Link main in chat", function() ns.UI:LinkInChat(main) end)
            end
            return
        end
        root:CreateTitle(SlotLabel(sid) .. "  ·  " .. PL(phase) .. suffix)
        if locked then
            root:CreateTitle(LockLine())
        else
            root:CreateButton("Choose main...", function() OpenPicker(sid, "main", tile) end)
            root:CreateButton("Choose alt...", function() OpenPicker(sid, "alt", tile) end)
            if main or alt then
                root:CreateButton("Swap main / alt", function() BiS:SwapMainAlt(phase, sid, list) end)
            end
            if main and tile.strip and tile.strip:IsShown() and ns.GemEditor then
                root:CreateButton("Gems and enchant...", function() ns.GemEditor:Open(tile, main, phase, list) end)
            end
        end
        if main then
            -- Manual "obtained" marks still work while the lists are locked (§38).
            local state = BiS:GetObtainedState(main)
            if state == nil then
                root:CreateButton("Mark obtained", function() BiS:SetManualObtained(main, true) end)
            elseif state == "manual" then
                root:CreateButton("Mark not obtained", function() BiS:SetManualObtained(main, false) end)
            else
                root:CreateTitle("Obtained: " .. (ns.UI.OBTAINED_LABELS[state] or state))
            end
        end
        if (main or alt) and not locked then
            root:CreateButton("Clear slot", function() BiS:ClearSlot(phase, sid, list) end)
        end
        if main then
            root:CreateButton("Link main in chat", function() ns.UI:LinkInChat(main) end)
        end
        if CanDisableSlots() and not locked then
            if root.CreateDivider then root:CreateDivider() end
            AddDisableEntries(root, phase, sid)
        end
    end)
end

local function OnSlotClick(sid, which, mouseButton, tile)
    if mouseButton == "RightButton" or SlotDisabled(CurrentPhase(), sid) then
        -- clicking a disabled slot offers "Enable slot"
        ShowSlotMenu(sid, tile)
    else
        OpenPicker(sid, which, tile)
    end
end

local function OnSlotReceiveItem(sid, itemID, which)
    if not ns.BiS then return end
    local phase = CurrentPhase()
    if SlotDisabled(phase, sid) then
        ns:Print("%s is disabled in %s: enable the slot first (click it).", SlotLabel(sid), PL(phase))
        return
    end
    ns.BiS:SetSlot(phase, sid, which == "alt" and "alt" or "main", itemID, ListArg())
end

function MyBiS:SetPhase(p, byUser)
    p = ClampPhase(p)
    if byUser then
        userPickedPhase = true
        RememberPhase(p)
    end
    if p == selectedPhase and panel then
        self:Refresh()
        return
    end
    selectedPhase = p
    if ns.Picker and ns.Picker.IsOpen and ns.Picker:IsOpen() then ns.Picker:Close() end
    self:Refresh()
end

function MyBiS:GetPhase()
    return CurrentPhase()
end

-- Addendum H: show the main-spec ("ms") or the off-spec ("os") list.
function MyBiS:SetList(list)
    list = (list == "os") and "os" or "ms"
    if list == selectedList then return end
    selectedList = list
    if ns.Picker and ns.Picker.IsOpen and ns.Picker:IsOpen() then ns.Picker:Close() end
    self:Refresh()
end

function MyBiS:GetList()
    return selectedList
end

-- "Remove off-spec list..." (the off-spec spec dropdown): asks, then deletes the list and shows the main spec.
function MyBiS:ConfirmRemoveOffSpec()
    if not HasOffSpec() then return false end
    EnsurePopups()
    StaticPopup_Show("DISASTERZONE_REMOVE_OFFSPEC")
    return true
end

---------------------------------------------------------------------------
-- Menus & dropdown content
---------------------------------------------------------------------------

local function SelectedSpec()
    return ns.BiS and ns.BiS.GetSpec and ns.BiS:GetSpec(ListArg()) or nil
end

local function SpecIcon(label)
    local class = MyClass()
    local RC = ns.RaidComp
    if not (label and RC and RC.SpecIcon and ns.SPECS and ns.SPECS[class]) then return nil end
    for i, s in ipairs(ns.SPECS[class]) do
        if s.label == label then return RC:SpecIcon(class, i) end
    end
    return nil
end

-- The spec tabs: every spec of the class in a row after the phases, in the phase tabs' look. The spec whose list is
-- shown carries its name and the underline (gold = main spec, silver = off spec); the others are icons only, a spec
-- that is neither list dimmed. Click a spec with a list to show it; right-click (or click an unused spec) for its
-- menu: make it the main spec (the off spec trades places with it, picks and all), make it the off spec, remove.
local SPEC_ICON, SPEC_TAB_GAP, SPEC_NAME_GAP = 18, 8, 6
local MS_COLOR = { 1, 0.82, 0 }
local OS_COLOR = { 0.74, 0.77, 0.82 }

local specRow, specTabs = nil, {}

local function Ease(t) return 1 - (1 - t) ^ 3 end
local function MainLabel() return ns.BiS and ns.BiS:GetSpec() or "" end
local function OffLabel() return HasOffSpec() and ns.BiS:GetSpec("os") or nil end

-- Any pick in the list ("os" = the off spec), any phase.
local function ListHasPicks(list)
    local data = ns.BiS and ns.BiS:GetData()
    for p = PRE_RAID, MaxPhase() do
        local t = ns.ListPhase(data, p, list)
        for _, v in pairs(t or {}) do
            if type(v) == "table" and ((tonumber(v[1]) or 0) ~= 0 or (tonumber(v[2]) or 0) ~= 0) then return true end
        end
    end
    return false
end

-- A list's picks and its spec belong together: giving a list with picks a spec that is neither list's relabels
-- those picks, so it asks first.
local function Relabel(list, from, to, fn)
    if from ~= "" and ListHasPicks(list) then
        EnsurePopups()
        StaticPopup_Show("DISASTERZONE_RELABEL_LIST", from, to, { fn = fn })
    else
        fn()
    end
end

-- the main spec becomes `label`: the off spec trades places with it (picks and all) when that is the off spec
local function MakeMain(label)
    local BiS = ns.BiS
    if label == OffLabel() then
        if BiS:SwapLists() then selectedList = "ms" end
        MyBiS:Refresh()
        return
    end
    Relabel(nil, MainLabel(), label, function()
        if BiS:SetSpec(label) then selectedList = "ms" end
        MyBiS:Refresh()
    end)
end

local function MakeOff(label)
    local BiS = ns.BiS
    if label == MainLabel() then
        if HasOffSpec() and BiS:SwapLists() then selectedList = "os" end
        MyBiS:Refresh()
        return
    end
    Relabel("os", OffLabel() or "", label, function()
        if BiS:SetSpec(label, "os") then selectedList = "os" end
        MyBiS:Refresh()
    end)
end

local function BuildSpecMenu(label)
    return function(root)
        root:CreateTitle(label)
        if ListLocked() then
            root:CreateTitle(LockLine())
            return
        end
        local main, off = MainLabel(), OffLabel()
        if label ~= main then
            root:CreateButton(label == off and "Make main spec (swap the lists)" or "Make main spec",
                function() MakeMain(label) end)
        end
        if label ~= off and (label ~= main or off) then
            root:CreateButton(label == main and "Make off spec (swap the lists)" or "Make off spec",
                function() MakeOff(label) end)
        end
        if label == off then
            root:CreateButton("Remove off-spec list...", function() MyBiS:ConfirmRemoveOffSpec() end)
        end
        root:CreateDivider()
        root:CreateButton("Detect main spec from talents", function()
            local spec = ns.BiS and ns.BiS:DetectSpec()
            if spec and spec ~= "" then
                if spec ~= MainLabel() then MakeMain(spec) end
            else
                ns:Print("Couldn't detect a spec (no talent points spent yet).")
            end
        end)
    end
end

-- a tab's width: icon, and while shown its name and tag
local function SpecTabWidth(t, open)
    if not open then return SPEC_ICON + 4 end
    return floor(SPEC_ICON + SPEC_NAME_GAP + (tonumber(t.name:GetStringWidth()) or 60) + 5
        + (tonumber(t.tag:GetStringWidth()) or 24) + 4 + 0.5)
end

local function CreateSpecTab(parent)
    local t = CreateFrame("Button", nil, parent)
    t:SetHeight(BAR_H)
    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    t:SetClipsChildren(true)
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(SPEC_ICON, SPEC_ICON)
    t.icon:SetPoint("LEFT", 2, 1)
    t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    t.name = Text(t, "GameFontHighlight")
    t.name:SetPoint("LEFT", t.icon, "RIGHT", SPEC_NAME_GAP, 0)
    t.tag = Text(t, "GameFontNormalSmall", 10)
    t.tag:SetPoint("LEFT", t.name, "RIGHT", 5, 0)
    t.line = t:CreateTexture(nil, "OVERLAY")
    t.line:SetHeight(2)
    t.line:SetPoint("BOTTOMLEFT", 0, 0)
    t.line:SetPoint("BOTTOMRIGHT", 0, 0)
    t.hl = t:CreateTexture(nil, "HIGHLIGHT")
    t.hl:SetPoint("TOPLEFT", t.icon)
    t.hl:SetPoint("BOTTOMRIGHT", t.icon)
    t.hl:SetColorTexture(1, 1, 1, 0.15)
    t:SetScript("OnClick", function(self, button)
        local main, off = MainLabel(), OffLabel()
        if button == "LeftButton" and (self.spec == main or self.spec == off) then
            MyBiS:SetList(self.spec == main and "ms" or "os")
        else
            GameTooltip:Hide()
            ns.UI:ContextMenu(self, BuildSpecMenu(self.spec))
        end
    end)
    t:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        local main, off = MainLabel(), OffLabel()
        local isM, isO = self.spec == main, self.spec == off
        GameTooltip:AddLine(self.spec .. (isM and "  ·  main spec" or isO and "  ·  off spec" or ""), 1, 0.82, 0)
        if isM then
            GameTooltip:AddLine("The council ranks these picks first.", 1, 1, 1, true)
        elseif isO then
            GameTooltip:AddLine("Seen after everyone's main-spec wants; such an award counts as Offspec.", 1, 1, 1, true)
        else
            GameTooltip:AddLine("Not one of your lists.", 0.7, 0.7, 0.7)
        end
        GameTooltip:AddLine((isM or isO) and "Click: show the list  ·  Right-click: options" or "Click: options",
            0.55, 0.55, 0.55)
        GameTooltip:Show()
    end)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- the width eases to its target (the shown spec opens, the one before closes)
    function t:Grow(target)
        self.target = target
        local from = self:GetWidth() or target
        if not self:IsVisible() or from == 0 or from == target then
            self:SetWidth(target)
            self:SetScript("OnUpdate", nil)
            return
        end
        self.from, self.el = from, 0
        self:SetScript("OnUpdate", function(f, e)
            f.el = f.el + e
            local k = Ease(min(1, f.el / 0.22))
            f:SetWidth(floor(f.from + (f.target - f.from) * k + 0.5))
            if k >= 1 then f:SetScript("OnUpdate", nil) end
        end)
    end
    return t
end

local function RefreshSpecTabs()
    if not specRow then return end
    local specs = ns.SPECS and ns.SPECS[MyClass()] or {}
    local main, off = MainLabel(), OffLabel()
    local shown = SelectedSpec() or ""
    local os = IsOffSpecView()
    local prev
    for i, s in ipairs(specs) do
        local t = specTabs[i]
        if not t then
            t = CreateSpecTab(specRow)
            specTabs[i] = t
        end
        t.spec = s.label
        local isM, isO = s.label == main, s.label == off
        local open = s.label == shown and (os and isO or (not os and isM))
        t.icon:SetTexture(SpecIcon(s.label) or 134400)
        t.icon:SetDesaturated(not (isM or isO))
        t.icon:SetAlpha((isM or isO) and 1 or 0.4)
        t.name:SetText(s.label)
        t.name:SetShown(open)
        t.tag:SetText(isM and "Main" or isO and "Off" or "")
        t.tag:SetShown(open)
        local c = isM and MS_COLOR or OS_COLOR
        t.tag:SetTextColor(c[1], c[2], c[3])
        t.line:SetColorTexture(c[1], c[2], c[3], 1)
        t.line:SetShown(open)
        t:ClearAllPoints()
        if prev then t:SetPoint("LEFT", prev, "RIGHT", SPEC_TAB_GAP, 0) else t:SetPoint("LEFT", specRow, "LEFT", 0, 0) end
        t:Grow(SpecTabWidth(t, open))
        t:Show()
        prev = t
    end
    for i = #specs + 1, #specTabs do specTabs[i]:Hide() end
end

local function CreateSpecRow(p)
    specRow = CreateFrame("Frame", nil, p)
    specRow:SetSize(260, BAR_H)
    specRow.sep = specRow:CreateTexture(nil, "ARTWORK")
    specRow.sep:SetSize(1, 14)
    specRow.sep:SetPoint("RIGHT", specRow, "LEFT", -10, 0)
    specRow.sep:SetColorTexture(1, 1, 1, 0.14)
    RefreshSpecTabs()
    return specRow
end

-- The spec tabs (tests, the UI audit): { { btn, spec, main, off, open } } in order.
function MyBiS:GetSpecTabs()
    local out = {}
    for _, t in ipairs(specTabs) do
        if t:IsShown() then
            out[#out + 1] = { btn = t, spec = t.spec, main = t.spec == MainLabel(), off = t.spec == OffLabel(),
                              open = t.name:IsShown() }
        end
    end
    return out
end

-- Opens a spec tab's menu (tests, the UI audit).
function MyBiS:OpenSpecMenu(label)
    for _, t in ipairs(specTabs) do
        if t.spec == label and t:IsShown() then ns.UI:ContextMenu(t, BuildSpecMenu(label)) return end
    end
end

-- The phases another phase can copy from: the raid phases, and the Pre-raid list into P1 (it comes first there: your
-- Pre-raid gear is where P1 starts); the Pre-raid list copies from any raid phase.
local function CopySources(phase)
    local out = {}
    for _, p in ipairs(ListPhases()) do
        if p ~= phase and (p ~= PRE_RAID or phase == 1) then out[#out + 1] = p end
    end
    return out
end

local function BuildCopyMenu(root)
    local BiS = ns.BiS
    local phase = CurrentPhase()
    local list = ListArg()
    root:CreateTitle("Copy into " .. PL(phase) .. (list and " (off spec)" or ""))
    local any = false
    for _, p in ipairs(CopySources(phase)) do
        if #PhaseItems(p) > 0 then
            any = true
            root:CreateButton(("Copy %s (fill empty)"):format(PL(p)), function()
                if BiS then BiS:CopyPhase(p, phase, false, list) end
            end)
            root:CreateButton(("Copy %s (overwrite)"):format(PL(p)), function()
                if BiS then BiS:CopyPhase(p, phase, true, list) end
            end)
        end
    end
    -- Addendum H: the other list of the same phase (shared items such as rings, trinkets and cloaks).
    local other = (not list) and "os" or nil
    local otherName = list and "main spec" or "off spec"
    if BiS and (list or HasOffSpec()) and #(BiS:GetPhaseItems(phase, other) or {}) > 0 then
        any = true
        if root.CreateDivider then root:CreateDivider() end
        root:CreateButton(("Copy %s %s (fill empty)"):format(otherName, PL(phase)), function()
            BiS:CopyPhase(phase, phase, false, list, other)
        end)
        root:CreateButton(("Copy %s %s (overwrite)"):format(otherName, PL(phase)), function()
            BiS:CopyPhase(phase, phase, true, list, other)
        end)
    end
    if not any then
        root:CreateTitle("No other phase has items yet")
    end
end

local function BuildSuggestMenu(root)
    local phase = CurrentPhase()
    local spec = SelectedSpec() or ""
    root:CreateTitle("Suggested BiS list")
    if not (ns.Loon and ns.Loon.IsAvailable and ns.Loon:IsAvailable()) then
        root:CreateTitle("The lists are missing: reinstall DisasterZone")
        return
    end
    if spec == "" then
        root:CreateTitle("Choose your spec first")
        return
    end
    root:CreateButton(("Fill empty slots (%s %s)"):format(spec, PL(phase)), function()
        MyBiS:ApplySuggestion(phase, false)
    end)
    root:CreateButton("Replace all (confirm)", function()
        EnsurePopups()
        StaticPopup_Show("DISASTERZONE_REPLACE_TEMPLATE", PL(phase) .. (ListArg() and " (off spec)" or ""), spec,
            { phase = phase, list = ListArg() })
    end)
    -- gems and enchants of the phase's picks, from the same guide
    if ns.Gems and ns.Gems:GuideFor(ns.BiS:GetListView(ListArg())) then
        if root.CreateDivider then root:CreateDivider() end
        root:CreateTitle("Gems and enchants")
        local b = root:CreateButton(("Fill empty sockets and enchants (%s)"):format(PL(phase)), function()
            local n = ns.Gems:FillPhase(phase, ListArg(), false)
            if n == 0 then ns:Print("Every socket and enchant of %s is already chosen.", PL(phase)) end
        end)
        if b and b.SetTooltip then
            b:SetTooltip(function(tt)
                tt:AddLine("Gems and enchants", 1, 0.82, 0)
                tt:AddLine(("Puts the %s guide's gems and enchants on every pick of %s that has an empty socket or "
                    .. "no enchant. What you chose stays."):format(spec, PL(phase)), 1, 1, 1, true)
            end)
        end
        root:CreateButton("Replace all gems and enchants", function()
            ns.Gems:FillPhase(phase, ListArg(), true)
        end)
    end
end

-- More (...): lists from other sites in, my gear / BiS list out to WoWSims and Wowhead (UI/ImportExport.lua), copy
-- from another phase or list, and clearing the phase (asked again in a popup). An icon and a word per entry; what it
-- does is in its tooltip. While the lists are locked only Export is offered, under the line that says why.
local function BuildMoreMenu(root)
    local UI = ns.UI
    local phase = CurrentPhase()
    local locked = ListLocked()
    local which = PL(phase) .. (ListArg() and " (off spec)" or "")
    local function entry(icon, text, color, tip, fn)
        local b = root:CreateButton(UI:AtlasIconText(icon, 14, color) .. "  " .. text, fn)
        if b and b.SetTooltip then
            b:SetTooltip(function(tooltip)
                tooltip:AddLine(text, 1, 0.82, 0)
                tooltip:AddLine(tip, 1, 1, 1, true)
            end)
        end
        return b
    end
    local function openWindow(tab)
        if ns.ImportExport then ns.ImportExport:Open(tab) end
    end
    if locked then
        root:CreateTitle(LockLine())
    else
        entry(UI.ICON.import, "Import", GOLD, "Bring in a BiS list from That's My BiS, Sixty Upgrades, WoWSims, "
            .. "a Wowhead gear planner link or item links. You see what changes first.", function() openWindow("import") end)
    end
    entry(UI.ICON.export, "Export", GOLD, "Your BiS list or the gear you wear, for WoWSims (wowsims.com/tbc) or "
        .. "Wowhead's gear planner.", function() openWindow("export") end)
    if locked then return end
    local copy = entry(ICON.copy, "Copy", GOLD, "Fill " .. which .. " from another phase, or from your other list.")
    if copy then BuildCopyMenu(copy) end
    if root.CreateDivider then root:CreateDivider() end
    entry(UI.ICON.trash, "Clear " .. which, RED, "Removes every pick in " .. which .. ". Asks first.", function()
        if #PhaseItems(phase) == 0 then
            ns:Print("%s has no picks to clear.", PL(phase))
            return
        end
        EnsurePopups()
        StaticPopup_Show("DISASTERZONE_CLEAR_PHASE", which, nil, { phase = phase, list = ListArg() })
    end)
end

---------------------------------------------------------------------------
-- Progress: what is obtained, and what is still to get by source
---------------------------------------------------------------------------

local function ComputeProgress(phase)
    local BiS = ns.BiS
    local result = { filled = 0, obtained = 0, total = NUM_SLOTS, disabled = 0, groups = {}, empty = 0,
                     twoHand = false }
    local data = BiS and (BiS.GetListView and BiS:GetListView(ListArg()) or BiS:GetData())
    for sid = 1, NUM_SLOTS do
        if SlotDisabled(phase, sid) then result.disabled = result.disabled + 1 end
    end
    result.total = NUM_SLOTS - result.disabled
    local ph = PhaseSlots(data, phase)
    if type(ph) ~= "table" then
        result.empty = result.total
        return result
    end

    local byKey = {}
    for sid = 1, NUM_SLOTS do
        local e = ph[sid]
        local main = type(e) == "table" and tonumber(e[1]) or nil
        if main and main > 0 and not SlotDisabled(phase, sid) then
            result.filled = result.filled + 1
            if BiS:IsObtained(main) then
                result.obtained = result.obtained + 1
            else
                local d = Describe(main)
                local g = byKey[d.group.key]
                if not g then
                    g = { key = d.group.key, label = d.group.label, name = d.group.name, order = d.group.order,
                          icon = d.group.icon, count = 0, items = {} }
                    byKey[g.key] = g
                    result.groups[#result.groups + 1] = g
                end
                g.count = g.count + 1
                g.items[#g.items + 1] = { itemID = main, where = d.where, sid = sid }
            end
        end
    end

    -- a two-hander leaves the off hand intentionally empty (unless one of them is disabled anyway)
    local ItemDB = ns.ItemDB
    local mh = type(ph[15]) == "table" and tonumber(ph[15][1]) or nil
    local oh = type(ph[16]) == "table" and tonumber(ph[16][1]) or nil
    if mh and mh > 0 and not (oh and oh > 0) and ItemDB and ItemDB:GetEquipLoc(mh) == "INVTYPE_2HWEAPON"
        and not SlotDisabled(phase, 15) and not SlotDisabled(phase, 16) then
        result.total = result.total - 1
        result.twoHand = true
    end
    result.empty = max(0, result.total - result.filled)

    table.sort(result.groups, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        if a.count ~= b.count then return a.count > b.count end
        return (a.name or "") < (b.name or "")
    end)
    return result
end

---------------------------------------------------------------------------
-- The centre: phase and progress, the model wearing the picks, what is still to get
---------------------------------------------------------------------------

-- The art behind the model: the phase's raids' loading screens (dungeon zones for Pre-raid), crossfading every
-- ART_HOLD seconds inside a soft circle that fades into the window's backdrop.
-- (by FileDataID: the client doesn't resolve these loading screens by path)
local LS = {
    HellfireCitadel = 131844, CoilFang = 131832, Auchindoun = 131821, TempestKeep = 131875, Karazhan = 131849,
    GruulsLair = 131842, HellfireCitadelRaid = 131846, Hyjal = 131847, BlackTemple = 131826, ZulAman = 131884,
    Sunwell = 131873,
}
local PHASE_ART = {
    [0] = { "HellfireCitadel", "CoilFang", "Auchindoun", "TempestKeep" },
    [1] = { "Karazhan", "GruulsLair", "HellfireCitadelRaid" },
    [2] = { "CoilFang", "TempestKeep" },
    [3] = { "Hyjal", "BlackTemple" },
    [4] = { "ZulAman" },
    [5] = { "Sunwell" },
}
local ART_SIZE, ART_ALPHA, ART_HOLD, ART_FADE = 620, 0.55, 8, 1.5
local RADIAL = "Interface\\AddOns\\" .. addonName .. "\\Media\\MyBiS\\Radial"

local function CreateArt(c, anchor)
    local f = CreateFrame("Frame", nil, c)
    f:SetSize(ART_SIZE, ART_SIZE)
    f:SetPoint("CENTER", anchor, "CENTER", 0, 0)
    f:SetFrameLevel(c:GetFrameLevel())
    local mask = f.CreateMaskTexture and f:CreateMaskTexture()
    f.mask = mask
    if mask then
        mask:SetTexture(RADIAL, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints()
    end
    f.tex = {}
    for i = 1, 2 do
        local t = f:CreateTexture(nil, "BACKGROUND", nil, -7)
        t:SetAllPoints()
        t:SetTexCoord(0.25, 0.75, 0.3, 0.97)   -- (a 4:3 screen stored square: a square below the logo)
        t:SetVertexColor(0.85, 0.85, 0.85)
        t:SetAlpha(0)
        if mask and t.AddMaskTexture then t:AddMaskTexture(mask) end
        f.tex[i] = t
    end
    f.cur, f.idx, f.clock = 1, 1, 0
    function f:SetPhase(phase)
        local list = PHASE_ART[phase] or PHASE_ART[1]
        if self.list == list then return end
        self.list, self.idx, self.clock = list, 1, 0
        self.tex[self.cur]:SetTexture(LS[list[1]])
        self.tex[self.cur]:SetAlpha(ART_ALPHA)
        self.tex[3 - self.cur]:SetAlpha(0)
        self.fading = nil
    end
    f:SetScript("OnUpdate", function(self, elapsed)
        local list = self.list
        if not list or #list < 2 then return end
        self.clock = self.clock + elapsed
        if self.fading then
            local t = min(1, self.clock / ART_FADE)
            self.tex[self.cur]:SetAlpha(ART_ALPHA * t)
            self.tex[3 - self.cur]:SetAlpha(ART_ALPHA * (1 - t))
            if t >= 1 then self.fading, self.clock = nil, 0 end
        elseif self.clock >= ART_HOLD then
            self.idx = self.idx % #list + 1
            self.cur = 3 - self.cur
            self.tex[self.cur]:SetTexture(LS[list[self.idx]])
            self.fading, self.clock = true, 0
        end
    end)
    return f
end

local function RowTooltip(row)
    local g = row.group
    if not g then return end
    GameTooltip:SetOwner(row, "ANCHOR_TOP")
    if g.rest then
        GameTooltip:AddLine("Also still to get", 1, 0.82, 0)
        for _, x in ipairs(g.rest) do
            GameTooltip:AddDoubleLine(x.name, tostring(x.count), 1, 1, 1, 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
        return
    end
    GameTooltip:AddLine(g.name, 1, 0.82, 0)
    for _, it in ipairs(g.items) do
        local text = ns.UI:ItemText(it.itemID)
        GameTooltip:AddDoubleLine(text, it.where or "", 1, 1, 1, 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

-- One row of what is still to get: the source's icon and name, the count on the right (its items on hover).
local function CreateRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetSize(LIST_COL_W, ROW_H)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.05)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(14, 14)
    r.icon:SetPoint("LEFT", 4, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.name = Text(r, "GameFontHighlightSmall", 11)
    r.name:SetTextColor(0.78, 0.78, 0.78)
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 7, 0)
    r.count = Text(r, "GameFontHighlight", 12)
    r.count:SetJustifyH("RIGHT")
    r.count:SetPoint("RIGHT", -4, 0)
    r:SetScript("OnEnter", RowTooltip)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return r
end

-- The progress line's tooltip: what the count leaves out.
local function ProgressTooltip(owner)
    local info = owner.info
    if not info then return end
    local name = PhaseName(owner.phase)
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    GameTooltip:AddLine((IsOffSpecView() and "Off spec  ·  " or "") .. name, 1, 0.82, 0)
    GameTooltip:AddLine(("%d of %d slots obtained"):format(info.obtained, info.total), 1, 1, 1)
    if info.empty > 0 then
        GameTooltip:AddLine(info.empty == 1 and "1 slot has no pick yet" or (info.empty .. " slots have no pick yet"),
            0.7, 0.7, 0.7)
    end
    if info.disabled > 0 then
        GameTooltip:AddLine(info.disabled == 1 and "1 slot not needed" or (info.disabled .. " slots not needed"),
            0.7, 0.7, 0.7)
    end
    if info.twoHand then GameTooltip:AddLine("Off hand not counted: a two-hander is picked", 0.7, 0.7, 0.7, true) end
    GameTooltip:Show()
end

-- The centre (w x h, between the columns, above the ranged slot): how much is obtained and a slim bar; the character
-- wearing the picks; what is still to get, by source. card.model, card.count, card.rows, card.lockBanner (§38).
local function CreateCard(parent, w, h)
    local UI = ns.UI
    local c = CreateFrame("Frame", nil, parent)
    c:SetAllPoints(parent)
    c.w, c.h = w, h

    c.count = Text(c, "GameFontHighlight", 12)
    c.count:SetJustifyH("CENTER")
    c.count:SetPoint("TOP", c, "TOP", 0, -4)
    c.title = c.count                       -- (older callers)
    c.track = c:CreateTexture(nil, "ARTWORK")
    c.track:SetSize(BAR_W, 3)
    c.track:SetPoint("TOP", c.count, "BOTTOM", 0, -7)
    c.track:SetColorTexture(1, 1, 1, 0.08)
    c.fill = c:CreateTexture(nil, "ARTWORK", nil, 1)
    c.fill:SetHeight(3)
    c.fill:SetPoint("LEFT", c.track, "LEFT", 0, 0)
    c.fill:SetColorTexture(1, 0.82, 0, 0.95)
    c.progress = CreateFrame("Frame", nil, c)
    c.progress:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
    c.progress:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, 0)
    c.progress:SetHeight(26)
    c.progress:EnableMouse(true)
    c.progress:SetScript("OnEnter", ProgressTooltip)
    c.progress:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- what is still to get, at the bottom: a few rows on one width, centred
    local listH = 16 + (MAX_ROWS + 1) * ROW_H
    c.listTop = h - listH
    c.listHead = Text(c, "GameFontHighlightSmall", 10)
    c.listHead:SetTextColor(0.55, 0.55, 0.55)
    c.listHead:SetJustifyH("CENTER")
    c.listHead:SetText("STILL TO GET")
    c.rows = {}
    for i = 1, MAX_ROWS + 1 do
        c.rows[i] = CreateRow(c)
        c.rows[i]:Hide()
    end
    -- instead of the rows: nothing picked yet / everything obtained
    c.note1 = Text(c, "GameFontHighlight", 12)
    c.note1:SetJustifyH("CENTER")
    c.note1:SetWidth(w)
    c.note2 = Text(c, "GameFontDisableSmall", 10)
    c.note2:SetJustifyH("CENTER")
    c.note2:SetWidth(w - 16)
    c.note2:SetWordWrap(true)
    if c.note2.SetMaxLines then c.note2:SetMaxLines(2) end
    c.note2:SetPoint("TOP", c.note1, "BOTTOM", 0, -4)

    -- The model draws in a frame larger than its place (and above the slot tiles) so a long weapon reaches over the
    -- columns; the camera backs off by the same ratio so the character keeps its size. It takes no mouse: the drag
    -- lives on `hit`, the model's own place.
    local EX, EY = 130, 60
    local placeH = c.listTop - 36
    local m = UI:CreateBiSModel(c)
    m.camScale = (placeH + 2 * EY) / placeH
    m:SetPoint("TOPLEFT", c, "TOPLEFT", -EX, -30 + EY)
    m:SetPoint("BOTTOMRIGHT", c, "TOPRIGHT", EX, -(c.listTop - 6) - EY)
    m:SetFrameLevel(c:GetFrameLevel() + 40)
    m:EnableMouse(false)
    m:SetScript("OnShow", function() c.dressKey = nil; if c.phase then c:Dress(c.phase) end end)
    local hit = CreateFrame("Frame", nil, c)
    hit:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -30)
    hit:SetPoint("BOTTOMRIGHT", c, "TOPRIGHT", 0, -(c.listTop - 6))
    hit:EnableMouse(true)
    hit:SetScript("OnMouseDown", function() m.dragX = GetCursorPosition() end)
    hit:SetScript("OnMouseUp", function() m.dragX = nil end)
    -- the character stands on a stone pedestal with a soft shadow (under the model, over the art)
    hit.platform = hit:CreateTexture(nil, "ARTWORK")
    hit.platform:SetTexture("Interface\\AddOns\\DisasterZone\\Media\\MyBiS\\platform")
    hit.platform:SetSize(PLATFORM_W, PLATFORM_W / 2)
    hit.platform:SetPoint("CENTER", hit, "BOTTOM", 0, PLATFORM_Y)
    c.hit = hit
    c.art = CreateArt(c, hit)
    MyBiS.art = c.art                       -- (debugging: DisasterZone.MyBiS.art)
    c.model = m

    -- gems and enchants of the phase (under the obtained count, above the model)
    local fin = CreateFrame("Frame", nil, c)
    fin:SetFrameLevel(m:GetFrameLevel() + 2)
    fin:SetSize(w, 14)
    fin:SetPoint("TOP", c.track, "BOTTOM", 0, -6)
    fin:EnableMouse(true)
    fin.text = Text(fin, "GameFontHighlightSmall", 10)
    fin.text:SetJustifyH("CENTER")
    fin.text:SetPoint("CENTER", fin, "CENTER", 0, 0)
    fin:SetScript("OnEnter", function(self) MyBiS:FinishTooltip(self) end)
    fin:SetScript("OnMouseUp", function(self) MyBiS:OpenFinishMenu(self) end)
    fin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    c.finish = fin

    -- The model wears the phase's picks. A slot that is empty, disabled or holds something that can't be worn (a tier
    -- token) keeps the currently equipped item.
    function c:Dress(phase)
        self.phase = phase
        self.art:SetPhase(phase)
        if not self.model:IsVisible() then return end
        local BiS = ns.BiS
        local data = BiS and (BiS.GetListView and BiS:GetListView(ListArg()) or BiS:GetData())
        local ph = PhaseSlots(data, phase)
        local function pick(sid)
            local e = type(ph) == "table" and ph[sid]
            local itemID = type(e) == "table" and tonumber(e[1]) or nil
            if itemID and itemID > 0 and not SlotDisabled(phase, sid) then return itemID end
        end
        -- Re-dressing reloads the model (it blinks), and the tab refreshes on every bag scan, item info or guild
        -- sync: only dress again when the outfit (the picks, and what is worn under empty slots) changed.
        local key = {}
        for sid = 1, NUM_SLOTS do
            local slot = ns.SLOTS and ns.SLOTS[sid]
            local worn = slot and slot.invSlot and GetInventoryItemID("player", slot.invSlot) or 0
            key[sid] = tostring(pick(sid) or 0) .. ":" .. tostring(worn or 0)
        end
        key = table.concat(key, ",")
        if key == self.dressKey then return end
        if self.model:DressBiS("player", pick) then self.dressKey = key end
    end

    return c
end

-- The still-to-get rows (bottom-aligned above the ranged slot), at most MAX_ROWS sources and "N more" for the rest.
local function ShowRows(groups)
    local shown = {}
    if #groups <= MAX_ROWS + 1 then
        for i = 1, #groups do shown[i] = groups[i] end
    else
        for i = 1, MAX_ROWS do shown[i] = groups[i] end
        local rest, count = {}, 0
        for i = MAX_ROWS + 1, #groups do
            rest[#rest + 1] = groups[i]
            count = count + groups[i].count
        end
        shown[MAX_ROWS + 1] = { name = "Other sources", short = (#groups - MAX_ROWS) .. " more", count = count,
                                icon = ICON.other, rest = rest }
    end
    local n = #shown
    local x0 = floor((card.w - LIST_COL_W) / 2 + 0.5)
    local top = card.h - n * ROW_H
    card.listHead:ClearAllPoints()
    card.listHead:SetPoint("BOTTOM", card, "TOP", 0, -(top - 6))
    card.listHead:SetShown(n > 0)
    for i, row in ipairs(card.rows) do
        local g = shown[i]
        row.group = g
        if g then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", card, "TOPLEFT", x0, -(top + (i - 1) * ROW_H))
            row.icon:SetTexture(g.icon)
            -- (a raid by its name, a kind of source by its label: Dungeons, Crafted, Reputation, Badges)
            local raid = type(g.key) == "string" and g.key:find("^raid:")
            row.name:SetText(g.short or (raid and g.name)
                or (g.label and (g.label:sub(1, 1):upper() .. g.label:sub(2))) or g.name or "?")
            row.count:SetText(tostring(g.count))
            row:Show()
        else
            row:Hide()
        end
    end
end

local function UpdateCard(phase)
    if not card then return end
    local info = ComputeProgress(phase)
    -- (the phase and the list are the top bar's: the centre only says how far along)
    card.count:SetText((IsOffSpecView() and (ns.UI:Colorize("Off spec", ns.COLORS and ns.COLORS.offspec)
        .. "|cff9e9e9e  ·  |r") or "")
        .. ("|cffffffff%d|r |cff9e9e9eof|r |cffffffff%d|r |cff9e9e9eobtained|r"):format(info.obtained, info.total))
    -- nothing picked: no count (the note under the model says what to do)
    card.count:SetShown(info.filled > 0)
    card.track:SetShown(info.filled > 0)
    local share = info.total > 0 and min(1, info.obtained / info.total) or 0
    card.fill:SetWidth(max(1, floor(BAR_W * share + 0.5)))
    card.fill:SetShown(share > 0)
    card.progress.info, card.progress.phase = info, phase
    MyBiS:UpdateFinish(phase, info.filled > 0)

    local groups = info.groups
    local locked = ListLocked()
    card.note1:SetText("")
    card.note2:SetText("")
    card.note1:ClearAllPoints()
    card.note1:SetPoint("TOP", card, "TOP", 0, -(card.h - 44))
    if #groups > 0 then
        ShowRows(groups)
    else
        ShowRows({})
        local _, label = PhaseName(phase)
        if info.filled == 0 then
            card.note1:SetText("Nothing picked for " .. label .. " yet")
            if not locked then
                local loon = ns.Loon and ns.Loon.IsAvailable and ns.Loon:IsAvailable()
                card.note2:SetText(loon and "Click a slot to choose, or let Suggest fill the list."
                    or "Click a slot to choose an item.")
            end
        else
            card.note1:SetText(Green(info.filled == 1 and "Your pick is obtained" or "Every pick is obtained"))
            if info.empty > 0 then
                card.note2:SetText(info.empty == 1 and "1 slot has no pick yet" or (info.empty .. " slots have no pick yet"))
            end
        end
    end
    card:Dress(phase)
end

---------------------------------------------------------------------------
-- Top bar
---------------------------------------------------------------------------

local function PhaseButtonTooltip(button)
    local p = button.phase
    local pinfo = ns.PHASE_INFO and ns.PHASE_INFO[p]
    GameTooltip:SetOwner(button, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(pinfo and pinfo.name or ("Phase " .. p), 1, 0.82, 0)
    if pinfo and pinfo.raids then GameTooltip:AddLine(pinfo.raids, 1, 1, 1, true) end
    local main, alt = 0, 0
    for _, e in ipairs(PhaseItems(p)) do
        if e.which == "alt" then alt = alt + 1 else main = main + 1 end
    end
    GameTooltip:AddLine(("%d main  ·  %d alt picks"):format(main, alt), 0.7, 0.7, 0.7)
    if p == PRE_RAID then
        GameTooltip:AddLine("Just for you: the council doesn't see this list and it raises no drop alerts.",
            0.7, 0.7, 0.7, true)
    end
    if GuildPhase() == p then
        -- GetGuildPhase() is the group's phase while the group's loot rules set one (Addendum E §32).
        local GR = ns.GroupRules
        local groupSet = type(GR) == "table" and type(GR.GetRulePhase) == "function" and GR:GetRulePhase() ~= nil
        local text = "Guild's current phase"
        if groupSet then
            local status, from = "own", nil
            if type(GR.GetStatus) == "function" then status, from = GR:GetStatus() end
            if status == "remote" and type(from) == "string" then
                text = "Your group's current phase (set by " .. ns.Util.ShortName(from) .. ")"
            elseif status == "mine" then
                text = "Your group's current phase (set by you)"
            else
                text = "Your group's current phase"
            end
        end
        GameTooltip:AddLine(text, ns.UI:Color("main"))
    end
    GameTooltip:Show()
end

-- A label offset inside a sleek button (the phase buttons make room for the guild phase's star); the pressed look
-- keeps it.
local function SetLabelOffset(b, x)
    local fs = b:GetFontString()
    b.labelX = x
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", x, 0)
end

local function UpdatePhaseButtons()
    local phase = CurrentPhase()
    local guildPhase = GuildPhase()
    for _, b in ipairs(phaseButtons) do
        -- the shown phase underlined; the guild's (or the group's) phase with its star after the label
        local marked = guildPhase == b.phase
        local fs = b:GetFontString()
        b.marker:SetShown(marked)
        b:SetWidth(floor((tonumber(fs:GetStringWidth()) or 14) + 16 + (marked and 13 or 0) + 0.5))
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", marked and -6 or 0, 1)
        b:SetActive(b.phase == phase)
    end
end

local function CreateLockChip(p)
    local UI = ns.UI
    local chip = CreateFrame("Frame", nil, p)
    chip:SetHeight(BAR_H)
    Flat(chip, { 0.24, 0.10, 0.03, 0.9 }, { 1, 0.55, 0.2, 0.85 })
    chip.icon = chip:CreateTexture(nil, "ARTWORK")
    chip.icon:SetSize(14, 14)
    chip.icon:SetPoint("LEFT", 7, 0)
    chip.icon:SetTexture(UI.ICON_LOCK or "Interface\\PetBattles\\PetBattle-LockIcon")
    chip.title = Text(chip, "GameFontHighlight", 12)
    chip.title:SetTextColor(1, 0.8, 0.62)
    chip.title:SetPoint("LEFT", chip.icon, "RIGHT", 5, 0)
    chip:EnableMouse(true)
    function chip:SetLock(info)
        self.title:SetText("Locked by " .. UI:LockByText(info))
        self:SetWidth(floor(7 + 14 + 5 + (tonumber(self.title:GetStringWidth()) or 60) + 10 + 0.5))
    end
    chip:SetScript("OnEnter", function(self)
        local _, info = ListLocked()
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("BiS lists are locked", 1, 0.82, 0)
        GameTooltip:AddLine(("%s locked every BiS list in the group for the raid. You can't change picks, "
            .. "spec or disabled slots until they unlock the lists or the group disbands. Items you get "
            .. "(and \"Mark obtained\" in a slot's right-click menu) still update."):format(UI:LockByText(info, true)),
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    chip:Hide()
    return chip
end

local function CreateTopBar(p)
    local UI = ns.UI
    bar = CreateFrame("Frame", nil, p)
    bar:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, TOP_Y)
    bar:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, TOP_Y)
    bar:SetHeight(BAR_H)

    -- the phases (from PhaseEntries: a Pre-raid entry would come first)
    for i, e in ipairs(PhaseEntries()) do
        local phase = e.phase
        local b = UI:CreateUnderlineTab(bar, e.label, function() MyBiS:SetPhase(phase, true) end, "page")
        b.phase, b.label = phase, e.label
        b.marker = b:CreateTexture(nil, "OVERLAY")
        b.marker:SetTexture(UI:Tex("star"))
        b.marker:SetSize(10, 10)
        b.marker:SetPoint("LEFT", b:GetFontString(), "RIGHT", 3, 0)
        b.marker:Hide()
        if i == 1 then b:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", -4, 0)
        else b:SetPoint("LEFT", phaseButtons[i - 1], "RIGHT", 2, 0) end
        b:HookScript("OnEnter", PhaseButtonTooltip)
        b:HookScript("OnLeave", function() GameTooltip:Hide() end)
        phaseButtons[i] = b
    end

    -- Addendum H: the spec tabs (which list the tab shows, both specs, a menu to change them)
    CreateSpecRow(bar):SetPoint("LEFT", phaseButtons[#phaseButtons], "RIGHT", 22, 0)

    moreBtn = UI:CreateTipIconButton(bar, BAR_H, UI.ICON.more, "More", "Import a BiS list from another site, export "
        .. "yours to WoWSims or Wowhead, copy another phase or list, or clear this phase's picks.", function(self)
        UI:ContextMenu(self, BuildMoreMenu)
    end)
    moreBtn:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    p.moreBtn = moreBtn

    suggestBtn = UI:CreateSleekMenuButton(bar, "Suggest", SUGGEST_W, BuildSuggestMenu, BAR_H)
    suggestBtn:GetFontString():SetFontObject("GameFontHighlight")
    suggestBtn:SetPoint("RIGHT", moreBtn, "LEFT", -6, 0)
    suggestBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Suggest", 1, 0.82, 0)
        GameTooltip:AddLine("Fill this phase from your spec's best-in-slot guide (shipped with DisasterZone).",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    suggestBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- §38: while my list is locked the chip takes Suggest's place
    lockChip = CreateLockChip(bar)
    lockChip:SetPoint("RIGHT", moreBtn, "LEFT", -6, 0)
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

function MyBiS:CreatePanel(parent)
    if panel then return panel end
    panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints(parent)

    CreateTopBar(panel)

    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, DOLL_Y)
    body:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, 0)

    doll = ns.PaperDoll:Create(body, {
        readOnly = false,
        layout = "page",
        onSlotClick = OnSlotClick,
        onSlotReceiveItem = OnSlotReceiveItem,
        onGemsClick = function(sid, tile)
            if tile.mainID and ns.GemEditor then ns.GemEditor:Open(tile, tile.mainID, CurrentPhase(), ListArg()) end
        end,
    })
    card = CreateCard(doll.center, doll.centerWidth or 252, doll.centerHeight or 440)
    card.lockBanner = lockChip

    panel:SetScript("OnShow", function(self)
        if self.dirty then MyBiS:Refresh() end
    end)
    panel:SetScript("OnHide", function()
        if ns.Picker and ns.Picker.IsOpen and ns.Picker:IsOpen() then ns.Picker:Close() end
    end)
    panel.OnPanelShown = function(self)
        if self.dirty then MyBiS:Refresh() end
    end

    panel.dirty = true
    return panel
end

function MyBiS:Refresh()
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    panel.dirty = false
    local BiS = ns.BiS
    if not BiS then return end

    local phase = CurrentPhase()
    UpdatePhaseButtons()
    RefreshSpecTabs()   -- Addendum H: the spec tabs show the shown list and both specs

    -- §38: while the lists are locked the chip says so in Suggest's place, and the menus offer what still works.
    local locked, info = ListLocked()
    local loon = ns.Loon and ns.Loon.IsAvailable and ns.Loon:IsAvailable()
    suggestBtn:SetShown((loon and not locked) and true or false)
    -- an empty phase: Suggest is the next step (the page's one gold button)
    if suggestBtn.SetKind then
        local info = ComputeProgress(phase)
        suggestBtn:SetKind(info.filled == 0 and "primary" or "secondary")
    end
    if locked then lockChip:SetLock(info) end
    lockChip:SetShown(locked and true or false)
    if locked and ns.Picker and ns.Picker.IsOpen and ns.Picker:IsOpen() then ns.Picker:Close() end

    local record = ns.ListRecordView(BiS:GetRecord(), ListArg())
    if doll.SetLocked then doll:SetLocked(locked) end
    doll:Update(record, phase, {
        obtainedState = function(itemID) return BiS:GetObtainedState(itemID) end,
        showEquipped = true,
        isDisabled = function(sid) return SlotDisabled(phase, sid) end,
        source = SlotSourceText,
        sourceTip = SlotSourceTip,
        gems = true,
    })
    -- the gem editor follows the shown phase and list (else it closes)
    local GE = ns.GemEditor
    if GE and GE:IsShown() then
        local _, st = GE:GetFrame()
        if st.phase ~= phase or st.list ~= ListArg() or locked then GE:Close() end
    end
    UpdateCard(phase)
end

-- The centre's gems and enchants line: "Gems 6 of 9  ·  Enchants 6 of 9" (green when complete); hidden while the phase
-- has no pick that takes either.
function MyBiS:UpdateFinish(phase, anyPick)
    local fin = card and card.finish
    local G, BiS = ns.Gems, ns.BiS
    if not (fin and G and BiS) then return end
    local view = BiS:GetListView(ListArg())
    local gems, sockets, enchants, enchantable = G:Progress(view, phase, function(sid) return SlotDisabled(phase, sid) end)
    fin.phase = phase
    local parts = {}
    local function part(word, have, of)
        if of == 0 then return end
        local done = have >= of
        parts[#parts + 1] = done and Green(("%s %d of %d"):format(word, have, of))
            or ("|cff9e9e9e%s|r |cffffffff%d|r |cff9e9e9eof %d|r"):format(word, have, of)
    end
    part("Gems", gems, sockets)
    part("Enchants", enchants, enchantable)
    fin.text:SetText(table.concat(parts, "|cff9e9e9e  ·  |r"))
    fin:SetShown(anyPick and #parts > 0)
end

-- (tests) the centre's gems and enchants line: shown, text without colour codes.
function MyBiS:GetFinish()
    local fin = card and card.finish
    if not fin then return nil end
    local text = (fin.text:GetText() or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return fin:IsShown(), text
end

-- The gems line's menu: fill the empty ones from the guide, put what they take on the shopping list.
function MyBiS:OpenFinishMenu(owner)
    local G = ns.Gems
    local phase = owner.phase or CurrentPhase()
    local list = ListArg()
    GameTooltip:Hide()
    ns.UI:ContextMenu(owner, function(root)
        root:CreateTitle("Gems and enchants - " .. PL(phase))
        if not ListLocked() and G:GuideFor(ns.BiS:GetListView(list)) then
            root:CreateButton("Fill empty from the guide", function() G:FillPhase(phase, list, false) end)
        end
        local needs = G:ShoppingNeeds(phase, list)
        local count = 0
        for _, n in pairs(needs) do count = count + n end
        local b = root:CreateButton(count > 0 and ("Add to shopping list (%d)"):format(count) or "Add to shopping list",
            function()
                local n, other = G:AddToShoppingList(phase, list)
                ns:Print("Added %d gems and enchants to your shopping list (Atlas).%s", n,
                    other > 0 and (" %d more come from drops, vendors or reputation."):format(other) or "")
            end)
        if count == 0 and b and b.SetEnabled then b:SetEnabled(false) end
    end)
end

-- What the phase's picks still lack (the line's tooltip).
function MyBiS:FinishTooltip(owner)
    local G, BiS = ns.Gems, ns.BiS
    local phase = owner.phase or CurrentPhase()
    local view = BiS:GetListView(ListArg())
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Gems and enchants - " .. PL(phase), 1, 0.82, 0)
    local any = false
    local picks = G:CountedPicks(view, phase, function(sid) return SlotDisabled(phase, sid) end)
    for sid = 1, NUM_SLOTS do
        local itemID = picks[sid]
        if itemID then
            local st = G:State(view, itemID)
            local missing = {}
            if st.filled < st.sockets then
                local n = st.sockets - st.filled
                missing[#missing + 1] = n == 1 and "1 gem" or (n .. " gems")
            end
            if st.enchantable and not st.enchanted then missing[#missing + 1] = "enchant" end
            if #missing > 0 then
                any = true
                local name = ns.UI:ItemText(itemID)
                GameTooltip:AddDoubleLine(name, table.concat(missing, ", "), 1, 1, 1, 0.65, 0.65, 0.68)
            end
        end
    end
    if not any then
        GameTooltip:AddLine("Every pick has its gems and enchant.", 0.3, 0.9, 0.3)
    end
    GameTooltip:AddLine("Click: fill from the guide, or put them on the shopping list", 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
end

-- DisasterZone extension (§36): the progress numbers of a phase as the centre shows them (for tests / tooltips).
function MyBiS:GetProgress(phase)
    local info = ComputeProgress(ClampPhase(phase or CurrentPhase()))
    return { filled = info.filled, obtained = info.obtained, total = info.total, disabled = info.disabled }
end

-- What is still to get in a phase, by source as the centre counts it: { { label, name, count }, ... } (tests).
function MyBiS:GetStillToGet(phase)
    local out = {}
    for _, g in ipairs(ComputeProgress(ClampPhase(phase or CurrentPhase())).groups) do
        out[#out + 1] = { label = g.label, name = g.name, count = g.count }
    end
    return out
end

local function RequestRefresh()
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    Debounce("mybis-refresh", 0.05, function() MyBiS:Refresh() end)
end

---------------------------------------------------------------------------
-- Registration & messages
---------------------------------------------------------------------------

if ns.MainFrame and ns.MainFrame.RegisterTab then
    ns.MainFrame:RegisterTab("mybis", "My BiS", 1, function(parent) return MyBiS:CreatePanel(parent) end)
end

ns:On("MYLIST_CHANGED", RequestRefresh)
ns:On("OWNED_UPDATED", RequestRefresh)
ns:On("ITEMINFO_READY", RequestRefresh)
ns:On("LISTS_RESET", RequestRefresh)
ns:On("PROFESSIONS_UPDATED", RequestRefresh)   -- (who in the guild can craft a pick)
ns:On("CONFIG_UPDATED", function()
    -- follow the guild phase until the player picks one themselves (or reopen on the Pre-raid list left last time)
    if not userPickedPhase then
        local p = LeftOnPreRaid() and OpeningPhase() or GuildPhase()
        if p then selectedPhase = p end
    end
    RequestRefresh()
end)
-- §38: the raid lock started / ended (GS lk from the group's loot authority).
ns:On("BIS_LOCK_CHANGED", RequestRefresh)
ns:On("GROUP_RULES_CHANGED", RequestRefresh)
ns:On("GROUP_UPDATED", RequestRefresh)
