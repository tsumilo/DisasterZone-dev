if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Tooltip.lua", ...) then return end -- DisasterZone UI/Tooltip.lua
-- Adds DisasterZone lines to item tooltips: your own BiS status for everyone and, for the Loot Council,
-- who wants the item (SPEC §12.9). Uses HookScript("OnTooltipSetItem"); TooltipDataProcessor is retail-only.
local addonName, ns = ...

local Tooltip = ns:NewModule("Tooltip")

local _G = _G
local GetTime = GetTime
local format = string.format
local tconcat = table.concat
local floor, max, min = math.floor, math.max, math.min
local ipairs, pairs, type, tonumber, tostring = ipairs, pairs, type, tonumber, tostring

local MARK = "|cffff8000DisasterZone|r"       -- every DisasterZone line starts with this; also the dedupe marker
-- Texture escapes instead of star / check glyphs: the default WoW fonts do not contain them.
local STAR = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t"
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"
local GREY = 0.55
local CACHE_TTL = 2
local CACHE_MAX = 300
local TOOLTIPS = { "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2",
                   "ItemRefShoppingTooltip1", "ItemRefShoppingTooltip2" }
local VIA_TEXT = ns.VIA_TEXT or { token = "via token", upgrade = "via Sunmote upgrade", arena = "via token exchange" }

local FALLBACK_COLORS = {
    main     = { 0.98, 0.78, 0.22 },
    alt      = { 0.41, 0.80, 0.94 },
    obtained = { 0.30, 0.90, 0.40 },
    muted    = { 0.55, 0.55, 0.55 },
}

local cache, cacheSize = {}, 0
local hooked = {}                               -- [tooltip] = true
local truncated = setmetatable({}, { __mode = "k" })  -- [tooltip] = { entries, start, line } for Shift-expand

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Color(key)
    local c = ns.COLORS and ns.COLORS[key]
    return c or FALLBACK_COLORS[key] or FALLBACK_COLORS.muted
end

local function Paint(text, key)
    local c = Color(key)
    return format("|cff%02x%02x%02x%s|r", floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5),
        floor(c[3] * 255 + 0.5), text)
end

local function Setting(path, default)
    if ns.db and ns.DB and ns.DB.GetSetting then
        local v = ns.DB:GetSetting(path)
        if v ~= nil then return v end
    end
    return default
end

local function IsCouncil()
    return (ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil()) and true or false
end

local function ViewPhase()
    local p = ns.Guild and ns.Guild.GetViewPhase and ns.Guild:GetViewPhase()
    return tonumber(p) or 1
end

local function SlotLabel(sid)
    local s = ns.SLOTS and ns.SLOTS[sid]
    return s and s.label or "?"
end

local function ColoredName(key, classFile)
    if ns.UI and ns.UI.ColoredName then return ns.UI:ColoredName(key, classFile) end
    if ns.Util and ns.Util.ShortName then return ns.Util.ShortName(key) or key end
    return key
end

local function ItemText(itemID)
    if ns.UI and ns.UI.ItemText then
        local text = ns.UI:ItemText(itemID)   -- drop the extra "loading" return value
        return text
    end
    return (ns.ItemDB and ns.ItemDB.GetName and ns.ItemDB:GetName(itemID)) or ("item " .. tostring(itemID))
end

-- "Wearing: A, B" for a wanter: both items of a ring / trinket / weapon pair (ADDENDUM A §18).
-- Uses Store:GetWanters' equippedList, else the single `equipped` item. nil when nothing is worn.
local function WearingText(w)
    local list = w.equippedList
    if type(list) ~= "table" then list = { w.equipped } end
    local parts = {}
    for _, v in ipairs(list) do
        local id = tonumber(v)
        if id and id > 0 and #parts < 2 then parts[#parts + 1] = ItemText(id) end
    end
    if #parts == 0 then return nil end
    return "Wearing: " .. tconcat(parts, ", ")
end

local function ClearCache()
    for k in pairs(cache) do cache[k] = nil end
    cacheSize = 0
end

---------------------------------------------------------------------------
-- Line builders (cached per itemID)
---------------------------------------------------------------------------
-- "P2", or "Pre-raid" for phase 0.
local function PhaseText(p)
    if ns.PhaseLabel then return ns.PhaseLabel(p) end
    return "P" .. tostring(p)
end

local function BuildOwn(itemID)
    if not (ns.BiS and ns.BiS.MatchItem) then return nil end
    -- My Pre-raid list counts here (and only here: loot alerts and the roll popup stay on the raid phases).
    local matches = ns.BiS:MatchItem(itemID, { preRaid = true })
    if type(matches) ~= "table" or type(matches[1]) ~= "table" then return nil end
    local m = matches[1]
    local phase = tonumber(m.phase) or 0
    local label = PhaseText(phase)
    local text
    local anyOS = false
    for _, x in ipairs(matches) do
        if type(x) == "table" and x.os then anyOS = true end
    end
    if m.os then
        -- Only on my off-spec list (Addendum H; MatchItem lists main-spec matches first).
        local sp = ns.BiS.GetSpec and ns.BiS:GetSpec("os") or ""
        text = MARK .. " " .. Paint(format("Your %s off-spec %s%s - %s", label, m.which == "alt" and "alt" or "BiS",
            sp ~= "" and (" (" .. sp .. ")") or "", SlotLabel(m.sid)), "offspec")
    elseif m.which == "alt" then
        text = MARK .. " " .. Paint(format("Your %s alt - %s", label, SlotLabel(m.sid)), "alt")
    elseif phase == 0 then
        text = MARK .. " " .. STAR .. " " .. Paint(format("Your %s BiS - %s", label, SlotLabel(m.sid)), "main")
    else
        text = MARK .. " " .. STAR .. " " .. Paint(format("Your %s BiS (main) - %s", label, SlotLabel(m.sid)), "main")
    end
    if m.via then
        local via = VIA_TEXT[m.via] or "via token"
        local wanted = tonumber(m.wanted)
        local wantedName = wanted and wanted ~= itemID and ns.ItemDB and ns.ItemDB.GetName and ns.ItemDB:GetName(wanted)
        if wantedName then via = via .. ": " .. wantedName end
        text = text .. Paint(" (" .. via .. ")", "muted")
    end
    if m.obtained then text = text .. " " .. CHECK .. Paint("obtained", "obtained") end

    -- Other phases this item is also listed in.
    local extra, seen = {}, { [phase] = true }
    for i = 2, #matches do
        local x = matches[i]
        local p = type(x) == "table" and (x.os and true or false) == (m.os and true or false) and tonumber(x.phase)
        if p and not seen[p] then
            seen[p] = true
            extra[#extra + 1] = PhaseText(p)
        end
    end
    if #extra > 0 then text = text .. Paint("  also " .. tconcat(extra, ", "), "muted") end
    if anyOS and not m.os then text = text .. Paint("  + off spec", "offspec") end
    return text
end

local function BuildCouncil(itemID)
    if not (ns.Store and ns.Store.GetWanters) then return nil end
    local list = ns.Store:GetWanters(itemID, { includeObtained = true, list = "both" })
    if type(list) ~= "table" or #list == 0 then return nil end
    local vp = ViewPhase()
    -- One entry per player (GetWanters is sorted best first); players who need it before those who have it, and
    -- off-spec wanters (Addendum H) after both.
    local needers, have, offs, seen = {}, {}, {}, {}
    for _, w in ipairs(list) do
        if type(w) == "table" and type(w.key) == "string" and not seen[w.key] then
            seen[w.key] = true
            if w.os then
                if not w.obtained then offs[#offs + 1] = w end
            elseif w.obtained then
                have[#have + 1] = w
            else
                needers[#needers + 1] = w
            end
        end
    end
    if #needers == 0 and #have == 0 and #offs == 0 then return nil end
    local inRaid, mains = 0, 0
    for _, w in ipairs(needers) do
        if w.inRaid then inRaid = inRaid + 1 end
        if w.which ~= "alt" then mains = mains + 1 end
    end
    -- The same count as the drop panel / Items view ("N want"); alt picks are not BiS, so the mains are named.
    local header = format("%s: wanted by %d (%d in raid)", MARK, #needers, inRaid)
    if mains < #needers then header = header .. format(" · %d BiS", mains) end
    if #have > 0 then header = header .. Paint(format(", %d obtained", #have), "muted") end
    if #offs > 0 then header = header .. Paint(format(" +%d off spec", #offs), "offspec") end

    local entries = {}
    local function add(w)
        local left = "  " .. ColoredName(w.key, w.classFile)
        if w.os then
            left = left .. Paint(w.which == "alt" and " (OS alt)" or " (OS)", "offspec")
        elseif w.which == "alt" then
            left = left .. Paint(" (alt)", "alt")
        end
        local p = tonumber(w.phase)
        if p and p ~= vp then left = left .. Paint(" P" .. p, "muted") end
        local right = ""
        if w.obtained then
            right = "obtained"
        elseif w.awarded then
            right = "awarded"
        elseif w.cantUse then
            right = "can't use"
        elseif w.inRaid then
            right = "in raid"
        end
        -- What they wear now matters only for players who still need the item.
        local wear = not w.obtained and WearingText(w) or nil
        entries[#entries + 1] = { left = left, right = right, wear = wear and ("      " .. wear) or nil }
    end
    for _, w in ipairs(needers) do add(w) end
    for _, w in ipairs(have) do add(w) end
    for _, w in ipairs(offs) do add(w) end
    return { header = header, entries = entries }
end

-- "DisasterZone: made by A, B +3" for an item a guild member can craft (Core/Professions.lua), online crafters first.
local MAX_CRAFTERS = 4
local function CraftedBy(itemID)
    local Prof = ns.Professions
    local recipes = Prof and Prof.GetRecipesForItem and Prof:GetRecipesForItem(itemID)
    if not recipes then return nil end
    local Guild = ns.Guild
    local seen, online, offline = {}, {}, {}
    for _, r in ipairs(recipes) do
        for _, key in ipairs(r.crafters) do
            if not seen[key] then
                seen[key] = true
                if Guild and Guild:IsOnline(key) then
                    online[#online + 1] = ColoredName(key)
                else
                    offline[#offline + 1] = Paint(ns.Util.ShortName(key) or key, "muted")
                end
            end
        end
    end
    local total = #online + #offline
    if total == 0 then return nil end
    local names = {}
    for _, list in ipairs({ online, offline }) do
        for _, name in ipairs(list) do
            if #names < MAX_CRAFTERS then names[#names + 1] = name end
        end
    end
    local text = MARK .. ": made by " .. tconcat(names, ", ")
    if total > #names then text = text .. Paint(format(" +%d", total - #names), "muted") end
    return text
end

local function GetData(itemID)
    local now = GetTime()
    local c = cache[itemID]
    if c and now - c.t < CACHE_TTL then return c end
    if not c then
        if cacheSize >= CACHE_MAX then ClearCache() end
        cacheSize = cacheSize + 1
    end
    c = { t = now, own = BuildOwn(itemID) }
    if IsCouncil() and Setting("tooltip.council", true) then c.council = BuildCouncil(itemID) end
    cache[itemID] = c
    return c
end

---------------------------------------------------------------------------
-- Tooltip hooks
---------------------------------------------------------------------------
local function HasMarker(tt)
    local name = tt.GetName and tt:GetName()
    if not name then return false end
    for i = 1, tt:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and text:find(MARK, 1, true) then return true end
    end
    return false
end

local function MaxNames()
    local n = tonumber(Setting("tooltip.maxNames", 5)) or 5
    return max(1, min(40, floor(n)))
end

local function OnSetItem(tt)
    if not tt.GetItem then return end
    local _, link = tt:GetItem()
    if type(link) ~= "string" then return end
    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID or itemID <= 0 then return end
    if HasMarker(tt) then return end   -- hooks can fire more than once per tooltip
    Tooltip:AddLines(tt, itemID)
end

local function OnCleared(tt)
    truncated[tt] = nil
end

-- Appends the DisasterZone lines for itemID to a tooltip. Returns true if anything was added.
function Tooltip:AddLines(tt, itemID)
    if not tt or not itemID or not Setting("tooltip.enabled", true) then return false end
    local data = GetData(itemID)
    local added = false
    if data.own then
        tt:AddLine(data.own, 1, 1, 1)
        added = true
    end
    local council = data.council
    if council and Setting("tooltip.council", true) and IsCouncil() then
        tt:AddLine(council.header, 1, 1, 1)
        local entries = council.entries
        local n = #entries
        local limit = n
        local shift = _G.IsShiftKeyDown and _G.IsShiftKeyDown()
        if not shift and n > MaxNames() then limit = MaxNames() end
        for i = 1, limit do
            tt:AddDoubleLine(entries[i].left, entries[i].right, 1, 1, 1, GREY, GREY, GREY)
            -- "Wearing: ..." only while Shift is held: under every name it doubled the block and widened every
            -- bag / AH / chat-link tooltip.
            if shift and entries[i].wear then tt:AddLine(entries[i].wear, GREY, GREY, GREY) end
        end
        if limit < n then
            tt:AddLine(format("  +%d more (hold Shift)", n - limit), GREY, GREY, GREY)
            truncated[tt] = { entries = entries, start = limit + 1, line = tt:NumLines() }
        end
        added = true
    end
    -- (the Members tab lists the crafters itself)
    local crafted = not Tooltip.skipCrafters and CraftedBy(itemID)
    if crafted then
        tt:AddLine(crafted, 1, 1, 1, true)
        added = true
    end
    if added then tt:Show() end
    return added
end

-- Shift pressed while a truncated tooltip is shown: turn the "+K more" line into the next name
-- and append the rest (the tooltip itself is not re-set, so other addons' lines stay intact).
local function ExpandTruncated()
    for tt, more in pairs(truncated) do
        truncated[tt] = nil
        local name = tt.GetName and tt:GetName()
        local first = more.entries[more.start]
        if name and first and tt:IsShown() and more.line <= tt:NumLines() then
            local left = _G[name .. "TextLeft" .. more.line]
            local right = _G[name .. "TextRight" .. more.line]
            if left and left:GetText() and left:GetText():find("more (hold Shift)", 1, true) then
                left:SetText(first.left)
                left:SetTextColor(1, 1, 1)
                if right then
                    right:SetText(first.right)
                    right:SetTextColor(GREY, GREY, GREY)
                    right:Show()
                end
                if first.wear then tt:AddLine(first.wear, GREY, GREY, GREY) end
                for i = more.start + 1, #more.entries do
                    local e = more.entries[i]
                    tt:AddDoubleLine(e.left, e.right, 1, 1, 1, GREY, GREY, GREY)
                    if e.wear then tt:AddLine(e.wear, GREY, GREY, GREY) end
                end
                tt:Show()
            end
        end
    end
end

function Tooltip:HookTooltip(tt)
    if type(tt) ~= "table" or hooked[tt] or not tt.HookScript then return false end
    if tt.HasScript and not tt:HasScript("OnTooltipSetItem") then return false end
    hooked[tt] = true
    tt:HookScript("OnTooltipSetItem", OnSetItem)
    if not tt.HasScript or tt:HasScript("OnTooltipCleared") then
        tt:HookScript("OnTooltipCleared", OnCleared)
    end
    return true
end

function Tooltip:Invalidate()
    ClearCache()
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function Tooltip:OnInit()
    local function invalidate() ClearCache() end
    for _, msg in ipairs({ "LIST_UPDATED", "LISTS_RESET", "MYLIST_CHANGED", "MYLIST_COMMITTED",
                           "OWNED_UPDATED", "LEDGER_UPDATED", "CONFIG_UPDATED", "GROUP_UPDATED",
                           "SETTINGS_CHANGED", "DEMO_TOGGLED", "ITEMINFO_READY" }) do
        ns:On(msg, invalidate)
    end
end

function Tooltip:OnLogin()
    for _, name in ipairs(TOOLTIPS) do
        self:HookTooltip(_G[name])
    end
    ns:RegisterEvent("MODIFIER_STATE_CHANGED", function(_, key, down)
        if (key == "LSHIFT" or key == "RSHIFT") and (down == 1 or down == true) then
            ExpandTruncated()
        end
    end)
end
