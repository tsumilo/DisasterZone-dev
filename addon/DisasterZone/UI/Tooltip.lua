if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Tooltip.lua", ...) then return end -- DisasterZone UI/Tooltip.lua
-- Adds DisasterZone lines to item tooltips: your own BiS status for everyone and, for the Loot Council,
-- who wants the item (SPEC §12.9). Uses HookScript("OnTooltipSetItem"); TooltipDataProcessor is retail-only.
-- 1.3.5: compact by default (one line each for my BiS, a prized item's rules and the wanters); Shift shows it all.
-- Player tooltips get the player's title and season from the guild's events (Core/Events.lua).
local addonName, ns = ...

local Tooltip = ns:NewModule("Tooltip")
local S = ns.Style

local _G = _G
local GetTime = GetTime
local format = string.format
local tconcat = table.concat
local floor, max, min = math.floor, math.max, math.min
local ipairs, pairs, type, tonumber, tostring = ipairs, pairs, type, tonumber, tostring

local MARK = "|cffff8000DisasterZone|r"       -- player tooltips' events line
-- Item tooltips: every DisasterZone line starts with the small seal instead of the word (1.3.5: three orange
-- "DisasterZone" words made the block wide and loud). Its path is the dedupe marker.
local SEAL_MARK = "DisasterZone\\Media\\Launcher\\seal"
-- Texture escapes instead of star / check glyphs: the default WoW fonts do not contain them.
local STAR = "|TInterface\\AddOns\\DisasterZone\\Media\\Icons\\bis:0|t"
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"
local CROSS = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:0|t"
local GREY = 0.55
local GREYC = { GREY, GREY, GREY }
local WHITE = { 1, 1, 1 }
local WARN = { 1, 0.62, 0.36 }
local CACHE_TTL = 2
local CACHE_MAX = 300
local NAMES_CHARS = 40                          -- the compact wanters line: names up to about this many letters
local TOOLTIPS = { "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2",
                   "ItemRefShoppingTooltip1", "ItemRefShoppingTooltip2" }
-- the comparison tooltips Shift opens stay compact: the full block is for the item looked at
local COMPARE = { ShoppingTooltip1 = true, ShoppingTooltip2 = true, ItemRefShoppingTooltip1 = true,
                  ItemRefShoppingTooltip2 = true }
local VIA_TEXT = ns.VIA_TEXT or { token = "via token", upgrade = "via Sunmote upgrade", arena = "via token exchange" }

local FALLBACK_COLORS = {
    main     = { 0.98, 0.78, 0.22 },
    alt      = { 0.41, 0.80, 0.94 },
    obtained = { 0.30, 0.90, 0.40 },
    muted    = { 0.55, 0.55, 0.55 },
}

local cache, cacheSize = {}, 0
local hooked = {}                               -- [tooltip] = true
local blocks = setmetatable({}, { __mode = "k" })     -- [tooltip] = { first, n, id }: a compact block Shift expands
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

local function Seal()
    return "|TInterface\\AddOns\\DisasterZone\\Media\\Launcher\\seal" ..
        ((ns.HasAssets and ns:HasAssets(4)) and "_mm" or "") .. ":0|t "
end

local function ShiftDown()
    return (_G.IsShiftKeyDown and _G.IsShiftKeyDown()) and true or false
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

local SlotLabel = ns.SlotLabel

local function ColoredName(key, classFile) return ns.UI:ColoredName(key, classFile) end

local function ItemText(itemID)
    local text = ns.UI:ItemText(itemID)   -- drop the extra "loading" return value
    return text
end

-- "wears A, B" for a wanter: both items of a ring / trinket / weapon pair (ADDENDUM A §18).
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
    return "wears " .. tconcat(parts, ", ")
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

-- Sorted phases as short text: three or more raid phases in a row become a range ("Pre-raid, P1–P4", "P1, P3").
local function PhaseList(list)
    local out, i = {}, 1
    while i <= #list do
        local j = i
        while j < #list and list[i] > 0 and list[j + 1] == list[j] + 1 do j = j + 1 end
        if j - i >= 2 then
            out[#out + 1] = PhaseText(list[i]) .. "–" .. PhaseText(list[j])
        else
            j = i
            out[#out + 1] = PhaseText(list[i])
        end
        i = j + 1
    end
    return tconcat(out, ", ")
end

-- "★ Your BiS P1–P4 · Trinket 1": one line, every phase the item is listed in (main pick unless it says alt).
local function BuildOwn(itemID)
    if not (ns.BiS and ns.BiS.MatchItem) then return nil end
    -- My Pre-raid list counts here (and only here: loot alerts and the roll popup stay on the raid phases).
    local matches = ns.BiS:MatchItem(itemID, { preRaid = true })
    if type(matches) ~= "table" or type(matches[1]) ~= "table" then return nil end
    local m = matches[1]
    local anyOS = false
    -- The phases it is my BiS (main pick) in and those it is only my alt pick in, kept apart: "BiS P1 · alt P2, P3"
    -- (a phase where it is both counts as BiS). The slot is the BiS pick's.
    local mainP, altP, which, firstMain = {}, {}, {}, nil
    for _, x in ipairs(matches) do
        if type(x) == "table" then
            if x.os then anyOS = true end
            local p = (x.os and true or false) == (m.os and true or false) and tonumber(x.phase)
            if p and which[p] ~= "main" then
                if x.which ~= "alt" then
                    which[p] = "main"
                    firstMain = firstMain or x
                else
                    which[p] = "alt"
                end
            end
        end
    end
    for p, w in pairs(which) do
        if w == "main" then mainP[#mainP + 1] = p else altP[#altP + 1] = p end
    end
    table.sort(mainP)
    table.sort(altP)
    local lead = firstMain or m
    local slot = SlotLabel(lead.sid)
    local altText = (#mainP > 0 and #altP > 0) and Paint(" · alt " .. PhaseList(altP), m.os and "offspec" or "alt") or ""
    local text
    if m.os then
        -- Only on my off-spec list (Addendum H; MatchItem lists main-spec matches first).
        local sp = ns.BiS.GetSpec and ns.BiS:GetSpec("os") or ""
        text = Seal() .. Paint(format("Your off-spec %s %s%s · %s", #mainP > 0 and "BiS" or "alt",
            PhaseList(#mainP > 0 and mainP or altP), sp ~= "" and (" (" .. sp .. ")") or "", slot), "offspec") .. altText
    elseif #mainP == 0 then
        text = Seal() .. Paint(format("Your alt %s · %s", PhaseList(altP), slot), "alt")
    else
        text = Seal() .. STAR .. " " .. Paint(format("Your BiS %s · %s", PhaseList(mainP), slot), "main") .. altText
    end
    if lead.via then
        local via = VIA_TEXT[lead.via] or "via token"
        local wanted = tonumber(lead.wanted)
        local wantedName = wanted and wanted ~= itemID and ns.ItemDB and ns.ItemDB.GetName and ns.ItemDB:GetName(wanted)
        if wantedName then via = via .. ": " .. wantedName end
        text = text .. Paint(" (" .. via .. ")", "muted")
    end
    if m.obtained then text = text .. " " .. CHECK .. Paint("obtained", "obtained") end
    if anyOS and not m.os then text = text .. Paint(" · + off spec", "offspec") end
    return text
end

local function MaxNames()
    local n = tonumber(Setting("tooltip.maxNames", 5)) or 5
    return max(1, min(40, floor(n)))
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
    local hasIt = #have > 0 and Paint(format(" · %d %s it", #have, #have == 1 and "has" or "have"), "muted") or ""
    local offSpec = #offs > 0 and Paint(format(" · +%d off spec", #offs), "offspec") or ""
    local here = inRaid > 0 and (" · " .. Paint(format("%d here", inRaid), "main")) or ""

    -- Compact (no Shift): "14 want · 3 here: A, B, C +11" on one line, names class coloured, those in the raid first
    -- (GetWanters' order). The same count as the drop panel / Items view ("N want").
    local compact
    if #needers > 0 then
        local names, used, limit = {}, 0, MaxNames()
        for _, w in ipairs(needers) do
            local short = (ns.Util and ns.Util.ShortName and ns.Util.ShortName(w.key)) or w.key
            if #names >= limit or (#names > 0 and used + #short + 2 > NAMES_CHARS) then break end
            names[#names + 1] = ColoredName(w.key, w.classFile)
            used = used + #short + 2
        end
        compact = Seal() .. format("%d want", #needers) .. here .. ": " .. tconcat(names, ", ")
        if #needers > #names then compact = compact .. Paint(format(" +%d", #needers - #names), "muted") end
    else
        compact = Seal() .. Paint("Nobody needs it", "muted") .. hasIt .. offSpec
    end

    -- Full (Shift): the counts, then one line per player. Alt picks are not BiS, so the mains are counted.
    local header = Seal() .. format("Wanted by %d", #needers)
    if mains < #needers then header = header .. format(" · %d BiS", mains) end
    header = header .. here .. hasIt .. offSpec

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
        if wear then right = right ~= "" and (right .. " · " .. wear) or wear end
        entries[#entries + 1] = { left = left, right = right }
    end
    for _, w in ipairs(needers) do add(w) end
    for _, w in ipairs(have) do add(w) end
    for _, w in ipairs(offs) do add(w) end
    return { compact = compact, header = header, entries = entries }
end

-- "Made by A, B +3" for an item a guild member can craft (Core/Professions.lua), online crafters first.
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
    local text = Seal() .. "Made by " .. tconcat(names, ", ")
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
        if text and text:find(SEAL_MARK, 1, true) then return true end
    end
    return false
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

local Ribbon   -- (the prized ribbon, below)

local function OnSetItem(tt)
    if not tt.GetItem then return end
    local _, link = tt:GetItem()
    if type(link) ~= "string" then return end
    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID or itemID <= 0 then return end
    Ribbon.Show(tt, itemID)
    if HasMarker(tt) or HasMaterials(tt) then return end   -- hooks can fire more than once per tooltip
    Tooltip:AddLines(tt, itemID)
end

-- 1.3.5 (prized look mockup, the user picked "ribbon on top"): a prized item's tooltip, anywhere in the game, gets an
-- orange PRIZED ITEM ribbon above it (the seal, the words) and an orange edge. Hidden when the tooltip clears or hides.
Ribbon = { H = 18, EDGE = { 0.79, 0.42, 0.08, 1 },
    DARK = { 0.52, 0.25, 0.04, 1 }, BRIGHT = { 1, 0.56, 0.14, 1 },     -- the ribbon's ends and middle
    INK = { 0.12, 0.06, 0.01 } }                                       -- its words

function Ribbon.Build(tt)
    local k = CreateFrame("Frame", nil, tt)
    k:SetFrameLevel((tt:GetFrameLevel() or 1) + 5)
    k:SetPoint("TOPLEFT", tt, "TOPLEFT", 0, 0)
    k:SetPoint("BOTTOMRIGHT", tt, "BOTTOMRIGHT", 0, 0)
    -- the ribbon sits on the tooltip's top edge, as wide as the tooltip
    local band = CreateFrame("Frame", nil, k)
    band:SetPoint("BOTTOMLEFT", tt, "TOPLEFT", 0, 0)
    band:SetPoint("BOTTOMRIGHT", tt, "TOPRIGHT", 0, 0)
    band:SetHeight(Ribbon.H)
    -- dark ends, bright in the middle (two halves), inside the outline
    local B = 2
    local function half(left)
        local t = band:CreateTexture(nil, "ARTWORK")
        if left then
            t:SetPoint("TOPLEFT", band, "TOPLEFT", B, -B)
            t:SetPoint("BOTTOMRIGHT", band, "BOTTOM", 0, 0)
        else
            t:SetPoint("TOPLEFT", band, "TOP", 0, -B)
            t:SetPoint("BOTTOMRIGHT", band, "BOTTOMRIGHT", -B, 0)
        end
        local a, b = Ribbon.DARK, Ribbon.BRIGHT
        if not left then a, b = b, a end
        ns.UI:Gradient(t, "HORIZONTAL", a, b)
        return t
    end
    band.l, band.r = half(true), half(false)
    band.text = ns.UI:Text(band, "small", Ribbon.INK, { justify = "CENTER", shadow = false })
    band.text:SetText("P R I Z E D   I T E M")
    band.text:SetPoint("CENTER", band, "CENTER", 8, -1)
    -- the prized icon (the addon's icon atlas: a white glyph, tinted dark brown on the ribbon)
    band.icon = band:CreateTexture(nil, "OVERLAY")
    band.icon:SetSize(13, 13)
    local UI = ns.UI
    local idx = UI and UI.ICON and ((ns.HasAssets and ns:HasAssets(7)) and UI.ICON.prized or UI.ICON.trophy)
    if idx and UI.IconCoords then
        local c = UI:IconCoords(idx)
        band.icon:SetTexture(UI.ICON_ATLAS)
        band.icon:SetTexCoord(c[1], c[2], c[3], c[4])
    end
    band.icon:SetVertexColor(0.16, 0.08, 0.01)
    band.icon:SetPoint("RIGHT", band.text, "LEFT", -5, 0)
    k.band = band
    -- one orange outline around the ribbon and the tooltip together (the same left / right lines for both)
    k.edges = {}
    local c = Ribbon.EDGE
    local function edge(p1, rel1, p2, rel2, w, h)
        local e = k:CreateTexture(nil, "OVERLAY")
        e:SetColorTexture(c[1], c[2], c[3], c[4])
        e:SetPoint(p1, rel1, p1)
        e:SetPoint(p2, rel2, p2)
        if w then e:SetWidth(w) else e:SetHeight(h) end
        k.edges[#k.edges + 1] = e
    end
    edge("TOPLEFT", band, "TOPRIGHT", band, nil, B)          -- the ribbon's top
    edge("BOTTOMLEFT", tt, "BOTTOMRIGHT", tt, nil, B)        -- the tooltip's bottom
    edge("TOPLEFT", band, "BOTTOMLEFT", tt, B)               -- left, ribbon to bottom
    edge("TOPRIGHT", band, "BOTTOMRIGHT", tt, B)             -- right
    tt.dzPrized = k
    return k
end

function Ribbon.Show(tt, itemID)
    local P = ns.Prized
    local on = itemID and P and P.ForItem and P:ForItem(itemID) ~= nil
    local k = tt.dzPrized
    if not on then
        if k then k:Hide() end
        return false
    end
    k = k or Ribbon.Build(tt)
    k:Show()
    return true
end

function Ribbon.Hide(tt)
    if tt.dzPrized then tt.dzPrized:Hide() end
end
Tooltip.Ribbon = Ribbon

local function OnCleared(tt)
    blocks[tt] = nil
    matsOn[tt] = nil
    Ribbon.Hide(tt)
end

-- Why I miss a prized item's rule, short: "62% attendance, needs 75%", "cooldown until 14 Oct".
local function FailText(res, v)
    v = v or {}
    if res.key == "att" then
        if res.num and res.value ~= "no raids" then return format("%s attendance, needs %d%%", res.value, v.p or 0) end
        return format("no raids in the last %d weeks", v.w or 0)
    elseif res.key == "cd" and res.free then
        return "cooldown until " .. date("%d %b", res.free)   -- which item it was: the Shift lines
    elseif res.key == "bis" then
        return "not on your BiS list"
    elseif res.key == "guild" then
        return "guild members only"
    end
    return res.why or res.label or res.key
end

-- A prized item's lines (Raids > Loot rules) into out. Compact: one line, "Prized · ✓ you qualify · council decides",
-- or only the first rule I miss ("✗ 62% attendance, needs 75% +1"). Full (Shift): each rule on its own line with a
-- tick or a cross for me, priority rules in grey. True when the item is prized.
local function PrizedLines(itemID, full, out)
    local P = ns.Prized
    local rec = P and P.ForItem and P:ForItem(itemID)
    if not rec then return false end
    local c = P:Check(rec, ns.Util.PlayerKey())
    local head = Seal() .. "|cffff9a2ePrized|r"
    local vote = rec.r and rec.r.vote
    if full then
        out[#out + 1] = { l = head .. (vote and Paint(" · the Loot Council decides, no rolls", "muted") or "") }
        for _, res in ipairs(c.rules) do
            if not res.info then
                local text = P:RuleText(res.key, rec.r[res.key], rec)
                if res.m == "p" then
                    out[#out + 1] = { l = "  " .. text, c = GREYC }
                else
                    local mark = res.ok == true and CHECK or (res.ok == false and CROSS or "  ")
                    local extra = ""
                    if res.ok == false and res.free then extra = format(" (free again %s)", date("%d %b", res.free)) end
                    out[#out + 1] = { l = mark .. " " .. text .. extra, c = res.ok == false and WARN or { 0.9, 0.9, 0.9 } }
                end
            end
        end
        return true
    end
    local status
    if c.required > 0 then
        if c.ok == true then
            status = CHECK .. " " .. Paint("you qualify", "obtained")
        else
            local fails, unknown = {}, nil
            for _, res in ipairs(c.rules) do
                if not res.info and res.m == "r" then
                    if res.ok == false then fails[#fails + 1] = res
                    elseif res.ok == nil and not unknown then unknown = res end
                end
            end
            if #fails > 0 then
                local f = fails[1]
                status = CROSS .. " " .. format("|cff%02x%02x%02x%s|r", floor(WARN[1] * 255), floor(WARN[2] * 255),
                    floor(WARN[3] * 255), FailText(f, rec.r[f.key]))
                if #fails > 1 then status = status .. Paint(format(" +%d", #fails - 1), "muted") end
            elseif unknown then
                status = Paint(format("%d of %d rules met, %s unknown", c.met, c.required,
                    (unknown.label or unknown.key):lower()), "muted")
            end
        end
    end
    out[#out + 1] = { l = head .. (status and (" · " .. status) or "") ..
        (vote and Paint(" · council decides", "muted") or "") }
    return true
end

-- The DisasterZone lines for itemID as { l = left, r = right, c = left colour }: compact, or full while Shift is
-- held. Also true when the full block would show more than the compact one.
function Tooltip:BlockLines(itemID, full)
    local data = GetData(itemID)
    local out = {}
    if data.own then out[#out + 1] = { l = data.own } end
    local more = PrizedLines(itemID, full, out)
    local council = data.council
    if council and Setting("tooltip.council", true) and IsCouncil() then
        more = true
        if full then
            out[#out + 1] = { l = council.header }
            for _, e in ipairs(council.entries) do out[#out + 1] = { l = e.left, r = e.right } end
        else
            out[#out + 1] = { l = council.compact }
        end
    end
    -- (the Members tab lists the crafters itself)
    local crafted = not Tooltip.skipCrafters and CraftedBy(itemID)
    if crafted then out[#out + 1] = { l = crafted } end
    return out, more
end

local function Emit(tt, x)
    local c = x.c or WHITE
    if x.r then
        tt:AddDoubleLine(x.l, x.r, c[1], c[2], c[3], GREY, GREY, GREY)
    else
        tt:AddLine(x.l, c[1], c[2], c[3])
    end
end

-- Appends the DisasterZone lines for itemID to a tooltip. Returns true if anything was added.
function Tooltip:AddLines(tt, itemID)
    if not tt or not itemID or not Setting("tooltip.enabled", true) then return false end
    local name = tt.GetName and tt:GetName()
    local full = ShiftDown() and not COMPARE[name or ""]
    local lines, more = self:BlockLines(itemID, full)
    local first = tt:NumLines() + 1
    for _, x in ipairs(lines) do Emit(tt, x) end
    blocks[tt] = (more and not full and #lines > 0 and not COMPARE[name or ""])
        and { first = first, n = #lines, id = itemID } or nil
    local added = #lines > 0
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
    tt:AddDoubleLine(head, craft.made > 1 and ("makes " .. craft.made * n) or "", S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], GREY, GREY, GREY)
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

-- Shift pressed while a compact block is shown: its lines become the full block's first lines and the rest is
-- appended (the tooltip itself is not re-set, so other addons' lines stay intact). That needs the block to be the
-- tooltip's last lines; when another addon added lines under it, the owner redraws the tooltip if it can (bag
-- buttons do so by themselves every 0.2 s).
local function ExpandBlocks()
    for tt, b in pairs(blocks) do
        blocks[tt] = nil
        local name = tt.GetName and tt:GetName()
        if name and tt:IsShown() then
            local left1 = _G[name .. "TextLeft" .. b.first]
            local text = left1 and left1:GetText()
            local lines = Tooltip:BlockLines(b.id, true)
            if b.first + b.n - 1 == tt:NumLines() and text and text:find(SEAL_MARK, 1, true) and #lines >= b.n then
                for i, x in ipairs(lines) do
                    if i <= b.n then
                        local left = _G[name .. "TextLeft" .. (b.first + i - 1)]
                        local right = _G[name .. "TextRight" .. (b.first + i - 1)]
                        local c = x.c or WHITE
                        left:SetText(x.l)
                        left:SetTextColor(c[1], c[2], c[3])
                        if right then
                            right:SetText(x.r or "")
                            right:SetTextColor(GREY, GREY, GREY)
                            if x.r then right:Show() else right:Hide() end
                        end
                    else
                        Emit(tt, x)
                    end
                end
                tt:Show()
            else
                local owner = tt.GetOwner and tt:GetOwner()
                if owner and type(owner.UpdateTooltip) == "function" then pcall(owner.UpdateTooltip, owner) end
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
    tt:HookScript("OnHide", Ribbon.Hide)
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
    if title then tt:AddLine(title, S:Color("GOLD")) end
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
            if down then ExpandBlocks() end   -- first: the materials go under the full block
            MaterialsShift(down)
        end
    end)
end
