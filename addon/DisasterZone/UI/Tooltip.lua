if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Tooltip.lua", ...) then return end -- DisasterZone UI/Tooltip.lua
-- Adds DisasterZone lines to item tooltips: your own BiS status for everyone and, for the Loot Council,
-- who wants the item (SPEC §12.9). Uses HookScript("OnTooltipSetItem"); TooltipDataProcessor is retail-only.
-- Player tooltips get the player's title and season from the guild's events (Core/Events.lua).
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
local STAR = "|TInterface\\AddOns\\DisasterZone\\Media\\Icons\\bis:0|t"
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
local matsOn = setmetatable({}, { __mode = "k" })     -- [tooltip] = the line of its "Materials" header
local mats = { n = 1, level = 0 }                     -- the id shown, its amount and breakdown steps
local MATS_MAX = 999
-- the tooltips that get materials (not the comparison tooltips Shift also opens)
local MATS_TOOLTIPS = { "GameTooltip", "ItemRefTooltip" }

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

-- Does tt show a materials block now? (Its header line is checked: a tooltip can be re-set without a clear event.)
local function HasMaterials(tt)
    local line = matsOn[tt]
    if not line then return false end
    local name = tt.GetName and tt:GetName()
    local fs = name and line <= tt:NumLines() and _G[name .. "TextLeft" .. line]
    local text = fs and fs:GetText()
    if text and text:find("^Materials") then return true end
    matsOn[tt] = nil
    return false
end

local function OnSetItem(tt)
    if not tt.GetItem then return end
    local _, link = tt:GetItem()
    if type(link) ~= "string" then return end
    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID or itemID <= 0 then return end
    if HasMarker(tt) or HasMaterials(tt) then return end   -- hooks can fire more than once per tooltip
    Tooltip:AddLines(tt, itemID)
end

local function OnCleared(tt)
    truncated[tt] = nil
    matsOn[tt] = nil
end

-- A prized item's lines: "DisasterZone: prized item", then each rule with a tick or a cross for me (a priority rule
-- or how it's decided in grey). True when added.
local CROSS = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:0|t"
function Tooltip:AddPrized(tt, itemID)
    local P = ns.Prized
    local rec = P and P.ForItem and P:ForItem(itemID)
    if not rec then return false end
    local c = P:Check(rec, ns.Util.PlayerKey())
    tt:AddLine(MARK .. ": |cffff9a2eprized item|r (Raids > Loot rules)", 1, 1, 1)
    for _, res in ipairs(c.rules) do
        local text = P:RuleText(res.key, rec.r[res.key], rec)
        if res.info or res.m == "p" then
            tt:AddLine("  " .. text, GREY, GREY, GREY, true)
        else
            local mark = res.ok == true and CHECK or (res.ok == false and CROSS or "  ")
            local extra = ""
            if res.ok == false and res.free then extra = format(" (free again %s)", date("%d %b", res.free)) end
            local col = res.ok == false and { 1, 0.62, 0.36 } or { 0.9, 0.9, 0.9 }
            tt:AddLine(mark .. " " .. text .. extra, col[1], col[2], col[3], true)
        end
    end
    return true
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
    -- 1.3.5: a prized item (Raids > Loot rules): its rules, ticked for me
    if self:AddPrized(tt, itemID) then added = true end
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
    -- (an Atlas / Members row puts the materials under its own lines)
    if not Tooltip.noMats and (tt == _G.GameTooltip or tt == _G.ItemRefTooltip) then
        self:AddMaterials(tt, itemID)
        if HasMaterials(tt) then added = true end
    end
    if added then tt:Show() end
    return added
end

---------------------------------------------------------------------------
-- Materials (Shift): what the craft making an item needs, times an amount the mouse wheel sets over a list row
---------------------------------------------------------------------------
local function ShiftDown()
    return (_G.IsShiftKeyDown and _G.IsShiftKeyDown()) and true or false
end

local function ReagentText(id)
    local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)) or (_G.GetItemIcon and _G.GetItemIcon(id))
    local name, quality
    if C_Item and C_Item.GetItemInfo and (not C_Item.IsItemDataCachedByID or C_Item.IsItemDataCachedByID(id)) then
        local _
        name, _, quality = C_Item.GetItemInfo(id)
    end
    name = name or (ns.Atlas and ns.Atlas:GetShippedName(id)) or ("item " .. id)
    local qc = quality and _G.ITEM_QUALITY_COLORS and _G.ITEM_QUALITY_COLORS[quality]
    if qc and qc.hex then name = qc.hex .. name .. "|r" end
    return (icon and ("|T" .. icon .. ":14:14:0:0:64:64:5:59:5:59|t ") or "") .. name
end

local function HaveCount(id)
    local count = _G.GetItemCount or (C_Item and C_Item.GetItemCount)
    return tonumber(count and count(id, true)) or 0   -- bags and bank
end

local BROKEN_DOWN = { "broken down once", "broken down twice" }

-- Adds the materials of the craft that makes id (an item id, or -spellID of a craft spell) to tt while Shift is
-- held: each material with how many I have (bags and bank) and need for the amount, broken down as many steps as
-- clicked (Tooltip:CraftRow). Returns the hint lines a list row shows ("Hold Shift: materials"; with Shift: "Mouse
-- wheel: change the amount" and, when there is a step to take, "Click: break down · Right-click: back up"), or nil
-- when no craft makes id.
function Tooltip:AddMaterials(tt, id)
    local A = ns.Atlas
    local craft = tt and A and A.GetCraft and A:GetCraft(id)
    if not craft then return nil end
    if mats.id ~= id then mats.id, mats.n, mats.level = id, 1, 0 end
    if not ShiftDown() then return "Hold Shift: materials" end
    local n = mats.n
    local list, level, deeper = A:GetMaterials(id, n, mats.level)
    mats.level, mats.deeper = level, deeper
    local head = n > 1 and ("Materials ×" .. n) or "Materials"
    if level > 0 then head = head .. " · " .. (BROKEN_DOWN[level] or ("broken down " .. level .. " times")) end
    tt:AddLine(" ")
    tt:AddDoubleLine(head, craft.made > 1 and ("makes " .. craft.made * n) or "", 1, 0.82, 0, GREY, GREY, GREY)
    matsOn[tt] = tt:NumLines()
    for _, r in ipairs(list) do
        local need, have = r.count, HaveCount(r.id)
        local c = have >= need and Color("obtained") or { 0.8, 0.8, 0.8 }
        tt:AddDoubleLine(ReagentText(r.id), have .. "/" .. need, 1, 1, 1, c[1], c[2], c[3])
    end
    -- a list row (Tooltip:CraftRow) takes the mouse wheel while its materials show
    local owner = tt.GetOwner and tt:GetOwner()
    if owner and owner.__dzCraftTip then owner:EnableMouseWheel(true) end
    local steps = {}
    if deeper then steps[#steps + 1] = "Click: break down" end
    if level > 0 then steps[#steps + 1] = "Right-click: back up" end
    return "Mouse wheel: change the amount", #steps > 0 and tconcat(steps, " · ") or nil
end

-- The amount the materials are shown for (1 until the mouse wheel changes it over a craft's row) and how many steps
-- they are broken down.
function Tooltip:GetMaterialsAmount()
    return mats.n, mats.level or 0
end

-- The amount and breakdown last set for id with Shift (nil when the materials last shown were another craft's).
function Tooltip:GetMaterialsState(id)
    if mats.id == nil or mats.id ~= tonumber(id) then return nil end
    return mats.n, mats.level or 0
end

-- Turns the wheel for the nearest parent that scrolls (the list), as if the row had no wheel of its own.
local function ForwardWheel(frame, delta)
    local p = frame:GetParent()
    while p do
        local fn = p.GetScript and p:GetScript("OnMouseWheel")
        if fn then return fn(p, delta) end
        p = p:GetParent()
    end
end

local function ShowsMaterials(row)
    return ShiftDown() and GameTooltip:IsShown() and GameTooltip:IsOwned(row) and HasMaterials(GameTooltip)
end

-- A list row whose tooltip (drawn by show(row)) can show a craft's materials: pressing or releasing Shift redraws
-- it, and while the materials show (Shift held) the mouse wheel over the row changes the amount, a click breaks the
-- materials down a step and a right-click goes back up one (releasing Shift starts over). The row takes the wheel
-- only then, so otherwise the wheel scrolls the list as it always did; other clicks do what they did.
-- rightClicks: the row already takes right clicks (else it is registered for them, and they do nothing else).
function Tooltip:CraftRow(row, show, rightClicks)
    row.__dzCraftTip = show
    if row.HasScript and row:HasScript("OnClick") then
        local onClick = row:GetScript("OnClick")
        if not rightClicks then row:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
        row:SetScript("OnClick", function(self, button, ...)
            if ShowsMaterials(self) then
                if button == "RightButton" then
                    if mats.level > 0 then
                        mats.level = mats.level - 1
                        show(self)
                    end
                elseif mats.deeper then
                    mats.level = mats.level + 1
                    show(self)
                end
                return
            end
            if button == "RightButton" and not rightClicks then return end
            if onClick then return onClick(self, button, ...) end
        end)
    end
    row:SetScript("OnMouseWheel", function(self, delta)
        if ShowsMaterials(self) then
            local n = max(1, min(MATS_MAX, mats.n + (delta > 0 and 1 or -1)))
            if n ~= mats.n then
                mats.n = n
                show(self)
            end
        else
            self:EnableMouseWheel(false)
            ForwardWheel(self, delta)
        end
    end)
    row:EnableMouseWheel(false)
    row:HookScript("OnLeave", function(self) self:EnableMouseWheel(false) end)
end

-- Shift went down or up: a list row's tooltip is redrawn (with or without the materials); any other item tooltip
-- gets the materials added under it when Shift goes down. Releasing Shift undoes the breakdown.
local function MaterialsShift(down)
    if not down then mats.level = 0 end
    local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
    local redrawn = owner and owner.__dzCraftTip
    if redrawn then
        owner:EnableMouseWheel(false)   -- AddMaterials gives it back while the materials show
        owner.__dzCraftTip(owner)
    end
    if not down then return end
    for _, name in ipairs(MATS_TOOLTIPS) do
        local tt = _G[name]
        if tt and tt:IsShown() and tt.GetItem and not (redrawn and tt == GameTooltip) and not HasMaterials(tt) then
            local _, link = tt:GetItem()
            local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
            if id then
                Tooltip:AddMaterials(tt, id)
                if HasMaterials(tt) then tt:Show() end
            end
        end
    end
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

-- A player's title from the guild's events and their season (rank, badges), under their name.
function Tooltip:AddEventLines(tt, key)
    local E = ns.Events
    if not (E and key) then return false end
    local title = E:GetTitle(key)
    local badges = #E:BadgesOf(key)
    local rank = E:RankOf(key)
    if not title and badges == 0 and not rank then return false end
    if title then tt:AddLine(title, 1, 0.82, 0) end
    local parts = {}
    local season = E:GetSeason()
    if rank then parts[#parts + 1] = ("#%d in %s"):format(rank, season and season.n or "the season") end
    if badges > 0 then parts[#parts + 1] = badges == 1 and "1 badge" or (badges .. " badges") end
    if #parts > 0 then tt:AddLine(MARK .. " events: " .. tconcat(parts, " · "), GREY, GREY, GREY) end
    return true
end

local function OnSetUnit(tt)
    if not (tt and tt.GetUnit) then return end
    local _, unit = tt:GetUnit()
    if not unit or not (UnitIsPlayer and UnitIsPlayer(unit)) then return end
    local key = ns.Util.UnitKey and ns.Util.UnitKey(unit)
    local ok, added = pcall(Tooltip.AddEventLines, Tooltip, tt, key)
    if ok and added then tt:Show() end
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
    if GameTooltip and GameTooltip.HookScript then GameTooltip:HookScript("OnTooltipSetUnit", OnSetUnit) end
    ns:RegisterEvent("MODIFIER_STATE_CHANGED", function(_, key, down)
        if key == "LSHIFT" or key == "RSHIFT" then
            down = down == 1 or down == true
            MaterialsShift(down)
            if down then ExpandTruncated() end
        end
    end)
end
