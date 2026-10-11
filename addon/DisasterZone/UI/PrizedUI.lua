if DisasterZoneBoot and DisasterZoneBoot.Run("UI/PrizedUI.lua", ...) then return end -- DisasterZone: UI/PrizedUI.lua
-- Raids > Loot rules (1.3.5, mockup dev/art/casc/prized_mockup): the guild's prized items and their loot rules, for
-- every member (Core/Prized.lua has the data and the rule checks).
--   Left:  the prized items by raid (a strip of the raid's loading screen over each raid's items); each item with its
--          icon in a legendary-orange ring, its slot and boss, and how I stand (You qualify / Free 25 Oct / #1 in
--          queue / Yours / Hunters). The GM and the guild council see the rules' icons instead.
--   Right: the picked item. A banner (the raid's art, the icon, PRIZED ITEM, the name, the slot / boss / raid, my
--          standing as a pill), then two tabs:
--          Rules: one sentence per rule with a Required / Priority / How it's decided pill and, at the right, how I
--          stand against it (my attendance, rank, main or alt, my last prized item...); who qualifies today (the raid
--          log's readers); who set the rules and when they changed last.
--          History: every hand-out (who got it, how many agreed, an award against a rule with its reason) and every
--          rule change, newest first.
--   The GM and the guild council edit in place (Edit on the banner): the sentence opens a menu of its values, each
--   rule switches Required / Priority, the bin removes it, Add rule lists the others; Save tells the guild. Add item
--   (top right of the Raids page) opens the add form in the right column: search the raid items, pick one or two
--   (two share one set of rules: the Warglaives), start from a template.
local addonName, ns = ...

local PrizedUI = ns:NewModule("PrizedUI")

local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat
local format = string.format

local PAD, GAP = 10, 8
local LIST_W = 300
local DETAIL_W = 770 - LIST_W - GAP
local VIEW_H = 501
local ITEM_H, RAID_H = 42, 30
local BAN_H = 112
local TABS_Y = BAN_H + 4
local BODY_Y = TABS_Y + 26
local RULE_X = 36                    -- a rule's words, after its icon
local RIGHT_W = 120                  -- my standing at a rule's right end
local EDIT_W = 120                   -- the Required / Priority switch and the bin, editing
local ART_TOP = 0.29
local MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\"
local BIS_TEX = MEDIA .. "Icons\\bis"
local CHECK_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"
local CROSS_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local ORANGE = { 1, 0.5, 0 }
local ORANGE_SOFT = { 1, 0.6, 0.18 }
local EDGE = { 0.34, 0.34, 0.38, 0.7 }
local WEEK = 7 * 86400

-- Items database raid keys -> the loading screen keys of RaidPlanUI:RaidArt.
local ART = { Karazhan = "kara", GruulsLair = "gruul", MagtheridonsLair = "mag", SerpentshrineCavern = "ssc",
              TempestKeep = "tk", MountHyjal = "hyjal", BlackTemple = "bt", ZulAman = "za", SunwellPlateau = "swp" }

-- state.sel = the picked record id; state.tab = "rules" | "history"; state.draft = the rules being edited (nil = not
-- editing); state.adding = the add form { search, picked = { ids }, tpl, copyFrom }.
local state = { tab = "rules" }
local view

local function UI() return ns.UI end
local function P() return ns.Prized end
local function Util() return ns.Util end
local function Me() return ns.Util.PlayerKey() end
local function hideTooltip() GameTooltip:Hide() end
local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

local function newText(parent, font, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
    end
    return fs
end

local function gradient(tex, orient, r, g, b, a1, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if tex.SetGradient and CreateColor then tex:SetGradient(orient, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2)) end
end

-- An atlas icon (UI.ICON) on a texture; the prized-items icons (art pack 7) fall back to older ones without it.
local FALLBACK = { prized = "trophy", person = "team", shield = "lock", pair = "infinity", ballot = "poll" }
local EXTRA_ICON = { pencil = 16 }
local function iconIndex(name)
    local I = UI().ICON
    if FALLBACK[name] and not (ns.HasAssets and ns:HasAssets(7)) then name = FALLBACK[name] end
    return I[name] or EXTRA_ICON[name] or I.notes
end

local function atlasTex(tex, name, r, g, b, a)
    tex:SetTexture(UI().ICON_ATLAS)
    tex:SetTexCoord(unpack(UI():IconCoords(iconIndex(name))))
    tex:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
end

local function atlasText(name, size, color)
    return UI():AtlasIconText(iconIndex(name), size or 12, color)
end

-- A rule's icon (Prized.RULES icon names -> the atlas, or the BiS diamond).
local RULE_ICON = { att = "calendar", rank = "crown", main = "person", guild = "shield", cd = "stopwatch",
                    order = "poll", queue = "team", pair = "pair", bis = "bis", vote = "ballot" }
local function ruleTex(tex, key, r, g, b)
    if key == "bis" then
        tex:SetTexture(BIS_TEX)
        tex:SetTexCoord(0, 1, 0, 1)
        tex:SetVertexColor(r or 1, g or 1, b or 1)
        return
    end
    local name = RULE_ICON[key] or "notes"
    if name == "stopwatch" and not (ns.HasAssets and ns:HasAssets(7)) then name = "calendar" end
    atlasTex(tex, name, r, g, b)
end

-- A raid's loading screen on a texture, cropped for w x h (under the game's logo).
local function setArt(tex, raidKey, w, h, fw)
    local PlanUI = ns.RaidPlanUI
    local inst = ART[raidKey] or "other"
    if not (PlanUI and PlanUI.RaidArt) then
        tex:Hide()
        return
    end
    local file, l, r, t, b = PlanUI:RaidArt(inst, w, h, fw)
    if t < ART_TOP then t, b = ART_TOP, b + ART_TOP - t end
    tex:SetTexture(file)
    tex:SetTexCoord(l, r, t, b)
    tex:Show()
end

local function itemName(id)
    local ItemDB = ns.ItemDB
    local name = ItemDB and ItemDB.GetName and ItemDB:GetName(id)
    if not name then
        local names = ns.Data and ns.Data.AtlasNames
        name = names and names[id]
    end
    return name or ("item " .. tostring(id))
end

local function qualityColor(id)
    local ItemDB = ns.ItemDB
    local q = ItemDB and ItemDB.GetQuality and ItemDB:GetQuality(id) or 4
    return UI():QualityColor(q)
end

-- The record's display name: one item, or the pair ("Warglaives of Azzinoth" when both share a name).
local function recName(rec)
    local a = itemName(rec.ids[1])
    if #rec.ids > 1 then
        local b = itemName(rec.ids[2])
        if a == b then return (a:gsub("^(%S+)", "%1s")) end
        return a .. " + " .. b
    end
    return a
end

local function slotText(rec)
    local ItemDB = ns.ItemDB
    if #rec.ids > 1 then
        local s1 = ItemDB and ItemDB.GetEquipLoc and ItemDB:GetEquipLoc(rec.ids[1])
        local s2 = ItemDB and ItemDB.GetEquipLoc and ItemDB:GetEquipLoc(rec.ids[2])
        if s1 == "INVTYPE_WEAPONMAINHAND" or s2 == "INVTYPE_WEAPONOFFHAND" then return "Main + off hand" end
        return "Two items"
    end
    local loc = ItemDB and ItemDB.GetEquipLoc and ItemDB:GetEquipLoc(rec.ids[1])
    local name = loc and _G[loc]
    if loc == "INVTYPE_RANGEDRIGHT" or loc == "INVTYPE_RANGED" then name = "Ranged" end
    return (type(name) == "string" and name ~= "") and name or "Item"
end

local function dateText(t)
    return (date("%a %d %b", t):gsub(" 0", " "))
end

local function canEdit()
    local Pz = P()
    return Pz and Pz.CanEdit and Pz:CanEdit() or false
end

local function demoOn()
    return (ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()) and true or false
end

---------------------------------------------------------------------------
-- My standing (the list's pill and the banner's)
---------------------------------------------------------------------------

-- (short text, tag kind, long text) for me and a record; nil when there is nothing to say.
local function standing(rec)
    local Pz = P()
    local me = Me()
    if not me then return nil end
    local got = Pz:GetGiven({ i = rec.id, to = me })
    if #got > 0 and (#rec.ids == 1 or #got >= #rec.ids) then return "Yours", "mute", "Yours" end
    local c = Pz:Check(rec, me)
    local q = c.by and c.by.queue
    if c.ok ~= false then
        if q and q.pos then
            return "#" .. q.pos .. " in queue", "bis", q.pos == 1 and "You are next in the queue" or
                ("You are #" .. q.pos .. " in the queue")
        end
        if c.ok == nil then return nil end
        return "You qualify", "ok", "You meet every rule"
    end
    local k = c.failKey
    local res = c.by and c.by[k]
    if k == "cd" and res and res.free then
        local d = dateText(res.free)
        return "Free " .. d:match("%d+ %a+"), "warn", "Not yet · free again " .. d
    elseif k == "order" then
        local g = rec.r.order and rec.r.order.g and rec.r.order.g[1]
        local t = Pz:GroupText(g, true)
        if #t > 14 then t = "Other specs" end
        return t, "mute", "Only " .. Pz:GroupText(g)
    elseif k == "queue" then
        return "Not queued", "mute", "Goes to the players in the queue"
    elseif k == "pair" then
        return "Taken", "mute", res and res.why or "The other one went to someone else"
    end
    return "Not yet", "warn", "Not yet · " .. tostring(c.fail or "a rule")
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

local function buildRows()
    local out = {}
    local last
    local Pz = P()
    local items = Pz:GetItems()
    local counts = {}
    for _, rec in ipairs(items) do
        local pl = Pz:Place(rec.ids[1])
        counts[pl.raidKey] = (counts[pl.raidKey] or 0) + 1
    end
    for _, rec in ipairs(items) do
        local pl = Pz:Place(rec.ids[1])
        if pl.raidKey ~= last then
            out[#out + 1] = { kind = "raid", key = pl.raidKey, name = pl.raidName, n = counts[pl.raidKey], first = last == nil }
            last = pl.raidKey
        end
        out[#out + 1] = { kind = "item", rec = rec, place = pl }
    end
    return out
end

local function newItemIcons(parent, size, n)
    local out = {}
    for i = 1, n do
        local f = CreateFrame("Frame", nil, parent)
        f:SetSize(size + 4, size + 4)
        f.ring = f:CreateTexture(nil, "BORDER")
        f.ring:SetAllPoints()
        f.ring:SetColorTexture(ORANGE[1], ORANGE[2], ORANGE[3], 1)
        f.black = f:CreateTexture(nil, "BORDER", nil, 1)
        f.black:SetPoint("TOPLEFT", 1, -1)
        f.black:SetPoint("BOTTOMRIGHT", -1, 1)
        f.black:SetColorTexture(0, 0, 0, 1)
        f.icon = f:CreateTexture(nil, "ARTWORK")
        f.icon:SetPoint("TOPLEFT", 2, -2)
        f.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        f:EnableMouse(true)
        f:SetScript("OnEnter", function(self)
            if self.itemID then UI():SetItemTooltip(self, self.itemID) end
        end)
        f:SetScript("OnLeave", hideTooltip)
        out[i] = f
    end
    return out
end

local function setItemIcons(icons, rec, overlap)
    for i, f in ipairs(icons) do
        local id = rec and rec.ids[i]
        f:SetShown(id ~= nil)
        if id then
            f.itemID = id
            f.icon:SetTexture(ns.ItemDB:GetIcon(id))
            f:ClearAllPoints()
            if i == 1 then f:SetPoint("TOPLEFT") else f:SetPoint("LEFT", icons[i - 1], "RIGHT", -(overlap or 0), 0) end
        end
    end
end

local function iconsWidth(icons, rec, overlap)
    local w = icons[1]:GetWidth()
    if #rec.ids > 1 then w = w * 2 - (overlap or 0) end
    return w
end

local function initRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.6, 0.1, 0.09)
        row.bar = row:CreateTexture(nil, "BORDER")
        row.bar:SetPoint("TOPLEFT")
        row.bar:SetPoint("BOTTOMLEFT")
        row.bar:SetWidth(3)
        row.bar:SetColorTexture(ORANGE[1], ORANGE[2], ORANGE[3], 1)
        row.bg = row:CreateTexture(nil, "BACKGROUND", nil, 0)
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(0.07, 0.07, 0.085, 0.82)
        row.line = row:CreateTexture(nil, "BORDER", nil, 1)
        row.line:SetPoint("BOTTOMLEFT")
        row.line:SetPoint("BOTTOMRIGHT")
        row.line:SetHeight(1)
        row.line:SetColorTexture(1, 1, 1, 0.05)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 1, 1, 0.04)
        -- the raid strip
        row.art = row:CreateTexture(nil, "BACKGROUND", nil, 2)
        row.art:SetPoint("TOPLEFT", 0, -4)
        row.art:SetPoint("BOTTOMRIGHT")
        row.shade = row:CreateTexture(nil, "BACKGROUND", nil, 3)
        row.shade:SetAllPoints(row.art)
        gradient(row.shade, "HORIZONTAL", 0.04, 0.04, 0.05, 0.9, 0.45)
        row.raid = newText(row, "GameFontNormal", 12)
        row.raid:SetPoint("LEFT", row.art, "LEFT", 10, 0)
        row.count = newText(row, "GameFontHighlightSmall", 11)
        row.count:SetTextColor(0.8, 0.8, 0.82)
        row.count:SetPoint("RIGHT", row.art, "RIGHT", -10, 0)
        -- the item
        row.icons = newItemIcons(row, 26, 2)
        row.iconHolder = CreateFrame("Frame", nil, row)
        row.iconHolder:SetSize(30, 30)
        row.iconHolder:SetPoint("LEFT", 9, 0)
        for _, f in ipairs(row.icons) do f:SetParent(row.iconHolder) end
        row.name = newText(row, "GameFontHighlight", 12)
        row.sub = newText(row, "GameFontHighlightSmall", 11)
        row.sub:SetTextColor(0.72, 0.72, 0.75)
        row.pill = UI():CreateTagPill(row, 16)
        row.marks = {}
        for i = 1, 6 do
            local t = row:CreateTexture(nil, "OVERLAY")
            t:SetSize(12, 12)
            t:SetPoint("RIGHT", -10 - (i - 1) * 16, 0)
            row.marks[i] = t
        end
        row:SetScript("OnClick", function(self)
            local data = self.__cdlData
            if data and data.kind == "item" then PrizedUI:Select(data.rec.id) end
        end)
    end
    local item = d.kind == "item"
    row:EnableMouse(item)
    row.bg:SetShown(item)
    row.line:SetShown(item)
    row.hl:SetShown(item)
    row.art:SetShown(not item)
    row.shade:SetShown(not item)
    row.raid:SetShown(not item)
    row.count:SetShown(not item)
    row.iconHolder:SetShown(item)
    row.name:SetShown(item)
    row.sub:SetShown(item)
    local on = item and d.rec.id == state.sel and not state.adding
    row.sel:SetShown(on)
    row.bar:SetShown(on)
    for _, t in ipairs(row.marks) do t:Hide() end
    row.pill:Hide()
    if not item then
        setArt(row.art, d.key, LIST_W, RAID_H - 4, 0.95)
        row.raid:SetText(d.name)
        row.count:SetText(tostring(d.n or ""))
        return
    end
    local rec = d.rec
    setItemIcons(row.icons, rec, 9)
    local iw = iconsWidth(row.icons, rec, 9)
    row.iconHolder:SetWidth(iw)
    row.name:ClearAllPoints()
    row.name:SetPoint("TOPLEFT", row.iconHolder, "TOPRIGHT", 9, -1)
    row.name:SetText(recName(rec))
    row.name:SetTextColor(qualityColor(rec.ids[1]))
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
    row.sub:SetText(d.place.bossName or d.place.raidName)
    local room = LIST_W - 18 - iw - 9
    row.name:SetWidth(max(60, room))
    -- my standing at the right of the second line (the name keeps the whole width)
    local text, kind = standing(rec)
    row.pill:ClearAllPoints()
    row.pill:SetPoint("BOTTOMRIGHT", -8, 5)
    if text then
        row.pill:Set(text, kind)
        row.pill:Show()
        room = room - row.pill:GetWidth() - 10
    end
    row.sub:SetWidth(max(60, room))
end

local function rowHeight(d) return d.kind == "raid" and (d.first and RAID_H - 4 or RAID_H) or ITEM_H end

---------------------------------------------------------------------------
-- The banner
---------------------------------------------------------------------------

local function createBanner(dc)
    local b = CreateFrame("Frame", nil, dc)
    b:SetPoint("TOPLEFT")
    b:SetSize(DETAIL_W, BAN_H)
    b.art = b:CreateTexture(nil, "BACKGROUND", nil, 0)
    b.art:SetPoint("TOPLEFT", 1, -1)
    b.art:SetPoint("BOTTOMRIGHT", -1, 1)
    b.shadeB = b:CreateTexture(nil, "BACKGROUND", nil, 2)
    b.shadeB:SetAllPoints(b.art)
    gradient(b.shadeB, "VERTICAL", 0.035, 0.035, 0.043, 0.92, 0.2)
    b.shadeL = b:CreateTexture(nil, "BACKGROUND", nil, 3)
    b.shadeL:SetPoint("TOPLEFT", b.art)
    b.shadeL:SetPoint("BOTTOMLEFT", b.art)
    b.shadeL:SetWidth(360)
    gradient(b.shadeL, "HORIZONTAL", 0.035, 0.035, 0.043, 0.88, 0)
    b.glow = b:CreateTexture(nil, "BACKGROUND", nil, 4)
    b.glow:SetPoint("TOPLEFT", b.art)
    b.glow:SetPoint("BOTTOMLEFT", b.art)
    b.glow:SetWidth(240)
    gradient(b.glow, "HORIZONTAL", 1, 0.5, 0, 0.07, 0)
    UI():AddEdges(b, "BORDER")

    b.iconHolder = CreateFrame("Frame", nil, b)
    b.iconHolder:SetSize(46, 46)
    b.iconHolder:SetPoint("TOPLEFT", 12, -12)
    b.icons = newItemIcons(b.iconHolder, 42, 2)
    b.kickIcon = b:CreateTexture(nil, "ARTWORK")
    b.kickIcon:SetSize(10, 10)
    b.kicker = newText(b, "GameFontNormalSmall", 10)
    b.kicker:SetTextColor(ORANGE_SOFT[1], ORANGE_SOFT[2], ORANGE_SOFT[3])
    b.kicker:SetText("PRIZED ITEM")
    if b.kicker.SetSpacing then b.kicker:SetSpacing(0) end
    b.kicker:SetPoint("LEFT", b.kickIcon, "RIGHT", 4, 0)
    atlasTex(b.kickIcon, "prized", ORANGE_SOFT[1], ORANGE_SOFT[2], ORANGE_SOFT[3])
    b.name = newText(b, "GameFontHighlightLarge", 18)
    b.name:SetPoint("TOPLEFT", b.kickIcon, "BOTTOMLEFT", 0, -4)
    b.meta = newText(b, "GameFontHighlightSmall", 11)
    b.meta:SetTextColor(0.78, 0.78, 0.8)
    b.meta:SetPoint("TOPLEFT", b.name, "BOTTOMLEFT", 0, -4)
    b.pill = UI():CreateTagPill(b, 20)
    b.pill:SetPoint("BOTTOMLEFT", 12, 11)
    b.pill:SetBase(0.06, 0.06, 0.07)

    b.editBtn = UI():CreateSleekButton(b, "Edit", 64, 22, function() PrizedUI:StartEdit() end)
    b.editBtn:SetPoint("BOTTOMRIGHT", -12, 11)
    b.editBtn.glyph = b.editBtn:CreateTexture(nil, "ARTWORK")
    b.editBtn.glyph:SetSize(11, 11)
    atlasTex(b.editBtn.glyph, "pencil", 0.85, 0.85, 0.85)
    local fs = b.editBtn:GetFontString()
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", 7, 0)
    b.editBtn.glyph:SetPoint("RIGHT", fs, "LEFT", -5, 0)
    b.editBtn:SetWidth(floor((fs:GetStringWidth() or 24) + 11 + 5 + 24 + 0.5))
    b.editBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Edit the rules")
        GameTooltip:AddLine("Saving tells the guild what changed and adds it to the item's history.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b.editBtn:HookScript("OnLeave", hideTooltip)
    b.moreBtn = UI():CreateTipIconButton(b, 22, UI().ICON.more, "More", "Remove this item from the prized items.",
        function(self)
            UI():ContextMenu(self, function(root)
                local e = root:CreateButton("Remove from prized items", function() PrizedUI:ConfirmRemove(state.sel) end)
                e:SetTitleAndTextTooltip("Remove", "Its rules go; its history stays with the guild for a year.")
            end)
        end)
    b.moreBtn:SetPoint("TOPRIGHT", -12, -12)
    b.saveBtn = UI():CreateSleekButton(b, "Save", 64, 22, function() PrizedUI:SaveEdit() end, "primary")
    b.saveBtn:SetPoint("BOTTOMRIGHT", -12, 11)
    b.saveBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Save the rules")
        GameTooltip:AddLine("The guild gets a notification of what changed; the item's history keeps it. The new "
            .. "rules count at once, also on a drop panel that is open now.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b.saveBtn:HookScript("OnLeave", hideTooltip)
    b.cancelBtn = UI():CreateSleekButton(b, "Cancel", 64, 22, function() PrizedUI:CancelEdit() end)
    b.cancelBtn:SetPoint("RIGHT", b.saveBtn, "LEFT", -6, 0)
    return b
end

local function fillBanner(b, rec)
    local pl = P():Place(rec.ids[1])
    setArt(b.art, pl.raidKey, DETAIL_W, BAN_H, 0.95)
    setItemIcons(b.icons, rec, 14)
    local iw = iconsWidth(b.icons, rec, 14)
    b.iconHolder:SetWidth(iw)
    b.kickIcon:ClearAllPoints()
    b.kickIcon:SetPoint("TOPLEFT", b.iconHolder, "TOPRIGHT", 12, -2)
    b.name:SetText(recName(rec))
    b.name:SetTextColor(qualityColor(rec.ids[1]))
    b.name:SetWidth(DETAIL_W - iw - 12 - 12 - 12 - 30)
    b.meta:SetText(slotText(rec) .. " · " .. (pl.bossName and (pl.bossName .. " · ") or "") .. pl.raidName)
    local editing = state.draft ~= nil
    local _, kind, long = standing(rec)
    b.pill:SetShown(long ~= nil and not editing)
    if long then b.pill:Set(long, kind) end
    if editing then
        b.pill:Set("Editing the rules", "warn")
        b.pill:Show()
    end
    b.editBtn:SetShown(canEdit() and not editing)
    b.moreBtn:SetShown(canEdit() and editing)
    b.saveBtn:SetShown(editing)
    b.cancelBtn:SetShown(editing)
end

---------------------------------------------------------------------------
-- The rules (shown, or edited)
---------------------------------------------------------------------------

local rulePool, rulesUsed = {}, 0

local function newRule(parent, width)
    local r = CreateFrame("Frame", nil, parent)
    r.cdlW = width or (DETAIL_W - 16)
    r:SetWidth(r.cdlW)
    r.box = r:CreateTexture(nil, "BACKGROUND")
    r.box:SetSize(26, 26)
    r.box:SetPoint("TOPLEFT", 0, -8)
    r.box:SetColorTexture(0.09, 0.09, 0.105, 1)
    r.boxEdge = CreateFrame("Frame", nil, r)
    r.boxEdge:SetAllPoints(r.box)
    UI():AddEdges(r.boxEdge, "BORDER")
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(15, 15)
    r.icon:SetPoint("CENTER", r.box)
    -- the sentence: a button when editing (it opens the rule's values)
    r.textBtn = CreateFrame("Button", nil, r)
    r.textBtn:SetPoint("TOPLEFT", RULE_X, -6)
    r.text = newText(r.textBtn, "GameFontHighlight", 12)
    r.text:SetPoint("TOPLEFT")
    r.text:SetWordWrap(true)
    r.chev = r.textBtn:CreateTexture(nil, "ARTWORK")
    r.chev:SetSize(9, 9)
    atlasTex(r.chev, "chevron", 1, 0.82, 0)
    r.textBtn:SetScript("OnEnter", function(self)
        if not self.editable then return end
        r.text:SetTextColor(1, 0.82, 0)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Change")
        GameTooltip:AddLine("Pick this rule's values.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    r.textBtn:SetScript("OnLeave", function(self)
        r.text:SetTextColor(0.94, 0.94, 0.94)
        hideTooltip()
    end)
    r.textBtn:SetScript("OnClick", function(self)
        if self.editable and r.ruleKey then PrizedUI:OpenValueMenu(self, r.ruleKey) end
    end)
    r.pill = UI():CreateTagPill(r, 15)
    r.pill:SetBase(0.08, 0.08, 0.095)
    r.sub = newText(r, "GameFontHighlightSmall", 11)
    r.sub:SetTextColor(0.72, 0.72, 0.75)
    r.sub:SetWordWrap(true)
    -- the queue's names
    r.names = newText(r, "GameFontHighlightSmall", 11)
    r.names:SetWordWrap(true)
    -- my standing
    r.val = newText(r, "GameFontHighlight", 12)
    r.val:SetJustifyH("RIGHT")
    r.mark = r:CreateTexture(nil, "ARTWORK")
    r.mark:SetSize(13, 13)
    r.mark:SetPoint("TOPRIGHT", 0, -9)
    r.val:SetPoint("RIGHT", r.mark, "LEFT", -4, 0)
    r.note = newText(r, "GameFontHighlightSmall", 11)
    r.note:SetTextColor(0.72, 0.72, 0.75)
    r.note:SetJustifyH("RIGHT")
    r.note:SetPoint("TOPRIGHT", r.mark, "BOTTOMRIGHT", 0, -6)
    -- editing: Required / Priority, the bin
    r.modeBtn = UI():CreateSleekButton(r, "Required", 72, 20, function()
        if r.ruleKey then PrizedUI:ToggleMode(r.ruleKey) end
    end)
    r.modeBtn:SetPoint("TOPRIGHT", -26, -8)
    r.modeBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Required or Priority")
        GameTooltip:AddLine("Required: players who don't meet it can't get the item (the council can still give it "
            .. "with a reason everyone sees). Priority: it doesn't keep anyone out; who meets it goes first.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    r.modeBtn:HookScript("OnLeave", hideTooltip)
    r.bin = UI():CreateRemoveButton(r, "Remove this rule")
    r.bin:SetPoint("TOPRIGHT", 0, -9)
    r.bin:SetScript("OnClick", function() if r.ruleKey then PrizedUI:RemoveRule(r.ruleKey) end end)
    r.rule = r:CreateTexture(nil, "BORDER")
    r.rule:SetPoint("BOTTOMLEFT")
    r.rule:SetPoint("BOTTOMRIGHT")
    r.rule:SetHeight(1)
    r.rule:SetColorTexture(1, 1, 1, 0.06)
    return r
end

local MODE_PILL = { r = { "Required", "warn" }, p = { "Priority", "alt" } }

-- Fills one rule row; returns its height.
local function fillRule(r, rec, rkey, v, res, editing)
    local Pz = P()
    r.ruleKey = rkey
    ruleTex(r.icon, rkey, 0.82, 0.82, 0.85)
    local text, sub = Pz:RuleText(rkey, v, rec)
    local rightW = editing and EDIT_W or ((res and (res.value or res.ok ~= nil)) and RIGHT_W or 0)
    local textW = (r.cdlW or (DETAIL_W - 16)) - RULE_X - rightW - 8
    r.text:SetWidth(textW)
    r.text:SetText(text)
    r.text:SetTextColor(0.94, 0.94, 0.94)
    local th = max(14, r.text:GetStringHeight() or 14)
    r.textBtn:SetSize(textW, th)
    local hasValues = rkey ~= "main" and rkey ~= "guild" and rkey ~= "pair" and rkey ~= "bis"
    r.textBtn.editable = editing and hasValues
    r.chev:SetShown(editing and hasValues)
    if editing and hasValues then
        r.chev:ClearAllPoints()
        local lw = min(textW, r.text:GetStringWidth() or textW)
        r.chev:SetPoint("LEFT", r.textBtn, "TOPLEFT", lw + 5, -7)
    end
    local y = 6 + th + 5
    -- the queue: its names in order
    r.names:SetShown(rkey == "queue")
    if rkey == "queue" then
        local parts = {}
        for i, k in ipairs(v.n or {}) do
            local c = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(k)
            local name = UI():ColoredName(k, c)
            local got = #Pz:GetGiven({ i = rec.id, to = k }) >= #rec.ids
            local me = ns.Util.IsMe(k)
            parts[#parts + 1] = format("|cff8c8c91%d|r %s%s%s", i, name, me and " |cff8c8c91(you)|r" or "",
                got and " |cff8c8c91(has it)|r" or "")
        end
        r.names:SetWidth(textW)
        r.names:ClearAllPoints()
        r.names:SetPoint("TOPLEFT", RULE_X, -y)
        r.names:SetText(#parts > 0 and tconcat(parts, "   ") or "|cff8c8c91Nobody yet: add players to the queue.|r")
        y = y + (r.names:GetStringHeight() or 12) + 5
    end
    local mode = rkey == "vote" and nil or MODE_PILL[v.m or "r"]
    r.pill:ClearAllPoints()
    r.pill:SetPoint("TOPLEFT", RULE_X, -y)
    if rkey == "vote" then r.pill:Set("How it's decided", "mute") else r.pill:Set(mode[1], mode[2]) end
    r.pill:SetShown(not editing or rkey == "vote")
    r.sub:ClearAllPoints()
    if r.pill:IsShown() then
        r.sub:SetPoint("TOPLEFT", r.pill, "TOPRIGHT", 6, -2)
    else
        r.sub:SetPoint("TOPLEFT", RULE_X, -y - 2)
    end
    r.sub:SetWidth(textW - (r.pill:IsShown() and (r.pill:GetWidth() + 6) or 0))
    r.sub:SetText(sub or "")
    y = y + max(15, (r.sub:GetStringHeight() or 12) + 2) + 8
    -- my standing / the editing controls
    r.modeBtn:SetShown(editing and rkey ~= "vote")
    r.bin:SetShown(editing)
    local showMe = not editing and res ~= nil and not res.info
    r.val:SetShown(showMe)
    r.mark:SetShown(showMe and res.ok ~= nil)
    r.note:SetShown(showMe)
    if editing and rkey ~= "vote" then
        local isReq = (v.m or "r") == "r"
        r.modeBtn:SetText(isReq and "Required" or "Priority")
        r.modeBtn:SetKind(isReq and "secondary" or "chosen")
    end
    if showMe then
        r.val:SetWidth(RIGHT_W - 18)
        r.note:SetWidth(RIGHT_W)
        local col = res.ok == false and (res.m == "p" and { 0.8, 0.8, 0.82 } or { 1, 0.62, 0.36 }) or
            (res.ok and { 0.95, 0.95, 0.95 } or { 0.62, 0.62, 0.65 })
        if rkey == "att" and res.ok then col = { 0.42, 0.86, 0.52 } end
        r.val:SetText(res.value or "")
        r.val:SetTextColor(col[1], col[2], col[3])
        if res.ok == true then
            r.mark:SetTexture(CHECK_TEX)
        elseif res.ok == false then
            r.mark:SetTexture(res.m == "p" and CHECK_TEX or CROSS_TEX)
            if res.m == "p" then r.mark:Hide() end
        end
        if res.free then
            r.note:SetText("free again " .. dateText(res.free))
        elseif res.ok == nil and rkey == "att" then
            r.note:SetText("asked a raid log reader")
        else
            r.note:SetText("you")
        end
    end
    local h = max(y, 42)
    r:SetHeight(h)
    return h
end

---------------------------------------------------------------------------
-- The view
---------------------------------------------------------------------------

local function section(parent, text)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(DETAIL_W - 16, 24)
    s.title = newText(s, "GameFontHighlightSmall", 11)
    s.title:SetTextColor(0.72, 0.72, 0.75)
    s.title:SetPoint("LEFT", 0, 0)
    s.title:SetText(text)
    s.right = newText(s, "GameFontHighlightSmall", 11)
    s.right:SetTextColor(0.72, 0.72, 0.75)
    s.right:SetJustifyH("RIGHT")
    s.right:SetPoint("RIGHT", 0, 0)
    return s
end

local function newHistRow(parent, width)
    local r = CreateFrame("Frame", nil, parent)
    r.cdlW = width or (DETAIL_W - 16)
    r:SetWidth(r.cdlW)
    r.box = r:CreateTexture(nil, "BACKGROUND")
    r.box:SetSize(26, 26)
    r.box:SetPoint("TOPLEFT", 0, -8)
    r.box:SetColorTexture(0.09, 0.09, 0.105, 1)
    r.boxEdge = CreateFrame("Frame", nil, r)
    r.boxEdge:SetAllPoints(r.box)
    UI():AddEdges(r.boxEdge, "BORDER")
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(15, 15)
    r.icon:SetPoint("CENTER", r.box)
    r.title = newText(r, "GameFontHighlight", 12)
    r.title:SetPoint("TOPLEFT", RULE_X, -7)
    r.title:SetWordWrap(true)
    r.sub = newText(r, "GameFontHighlightSmall", 11)
    r.sub:SetTextColor(0.72, 0.72, 0.75)
    r.sub:SetWordWrap(true)
    r.when = newText(r, "GameFontHighlightSmall", 11)
    r.when:SetTextColor(0.72, 0.72, 0.75)
    r.when:SetJustifyH("RIGHT")
    r.when:SetPoint("TOPRIGHT", 0, -9)
    r.rule = r:CreateTexture(nil, "BORDER")
    r.rule:SetPoint("BOTTOMLEFT")
    r.rule:SetPoint("BOTTOMRIGHT")
    r.rule:SetHeight(1)
    r.rule:SetColorTexture(1, 1, 1, 0.06)
    return r
end

local function coloredKey(k)
    local c = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(k)
    return UI():ColoredName(k, c)
end

local function fillHist(r, e)
    local Pz = P()
    local w = (r.cdlW or (DETAIL_W - 16)) - RULE_X - 90
    r.title:SetWidth(w)
    r.sub:SetWidth(w)
    local h = e.rec
    if e.kind == "G" then
        atlasTex(r.icon, "trophy", h.ov and 1 or 0.85, h.ov and 0.62 or 0.85, h.ov and 0.36 or 0.85)
        local item = itemName(h.it)
        local rec = Pz:Get(h.i)
        r.title:SetText(format("%s got %s", coloredKey(h.to), (rec and #rec.ids > 1) and item or "it"))
        local agreed = (h.ag and h.of and h.of > 0) and format("%d of %d agreed", h.ag, h.of) or nil
        local parts = {}
        if h.ov then
            local labels = {}
            for _, k in ipairs(h.ov) do labels[#labels + 1] = (Pz.RULE[k] and Pz.RULE[k].label or k):lower() end
            parts[#parts + 1] = "|cffffa060Against the " .. tconcat(labels, ", ") .. " rule|r"
            if h.why then parts[#parts + 1] = "“" .. h.why .. "”" end
        else
            parts[#parts + 1] = "All rules met"
        end
        parts[#parts + 1] = (h.ov and ("by " .. coloredKey(h.by) .. (agreed and (", " .. agreed) or "")) or agreed)
        r.sub:SetText(tconcat(parts, " · "))
    else
        local made = h.t:find("^Made a prized item") ~= nil
        atlasTex(r.icon, made and "prized" or "pencil", made and ORANGE_SOFT[1] or 0.82, made and ORANGE_SOFT[2] or 0.82,
            made and ORANGE_SOFT[3] or 0.85)
        r.title:SetText(h.t)
        r.sub:SetText("by " .. coloredKey(h.by))
    end
    r.when:SetText(ns.Util.FormatAgo and ns.Util.FormatAgo(h.at) or "")
    r.sub:ClearAllPoints()
    r.sub:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -4)
    local hgt = 7 + (r.title:GetStringHeight() or 14) + 4 + (r.sub:GetStringHeight() or 12) + 9
    hgt = max(hgt, 42)
    r:SetHeight(hgt)
    return hgt
end

-- The add form (in the right column).
local function createAddForm(dc)
    local f = CreateFrame("Frame", nil, dc)
    f:SetPoint("TOPLEFT")
    f:SetSize(DETAIL_W, VIEW_H)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.065, 0.065, 0.078, 0.94)
    UI():AddEdges(f, "BORDER")
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(16, 16)
    f.icon:SetPoint("TOPLEFT", 14, -14)
    atlasTex(f.icon, "prized", ORANGE_SOFT[1], ORANGE_SOFT[2], ORANGE_SOFT[3])
    f.title = newText(f, "GameFontHighlightLarge", 16)
    f.title:SetPoint("LEFT", f.icon, "RIGHT", 8, 0)
    f.title:SetText("Add a prized item")
    f.itemLabel = newText(f, "GameFontHighlightSmall", 11)
    f.itemLabel:SetTextColor(0.72, 0.72, 0.75)
    f.itemLabel:SetPoint("TOPLEFT", 14, -44)
    f.itemLabel:SetText("ITEM (UP TO TWO: THEY SHARE ONE SET OF RULES)")
    f.search = UI():CreateSearchBox(f, DETAIL_W - 28, function(text)
        state.adding.search = text or ""
        PrizedUI:RefreshAdd()
    end, "Search the raid items")
    f.search:SetPoint("TOPLEFT", 14, -58)
    f.results = {}
    for i = 1, 6 do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(DETAIL_W - 28, 28)
        b:SetPoint("TOPLEFT", 14, -86 - (i - 1) * 29)
        b.hl = b:CreateTexture(nil, "HIGHLIGHT")
        b.hl:SetAllPoints()
        b.hl:SetColorTexture(1, 1, 1, 0.05)
        b.box = b:CreateTexture(nil, "ARTWORK")
        b.box:SetSize(14, 14)
        b.box:SetPoint("LEFT", 4, 0)
        b.box:SetColorTexture(0.1, 0.1, 0.12, 1)
        b.boxEdge = CreateFrame("Frame", nil, b)
        b.boxEdge:SetAllPoints(b.box)
        UI():AddEdges(b.boxEdge, "BORDER")
        b.check = b:CreateTexture(nil, "OVERLAY")
        b.check:SetSize(14, 14)
        b.check:SetPoint("CENTER", b.box)
        b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(22, 22)
        b.icon:SetPoint("LEFT", b.box, "RIGHT", 8, 0)
        b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        b.name = newText(b, "GameFontHighlight", 12)
        b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 8, 1)
        b.sub = newText(b, "GameFontHighlightSmall", 11)
        b.sub:SetTextColor(0.72, 0.72, 0.75)
        b.sub:SetPoint("TOPLEFT", b.name, "BOTTOMLEFT", 0, -1)
        b:SetScript("OnClick", function(self) if self.itemID then PrizedUI:TogglePick(self.itemID) end end)
        b:SetScript("OnEnter", function(self) if self.itemID then UI():SetItemTooltip(self, self.itemID) end end)
        b:SetScript("OnLeave", hideTooltip)
        f.results[i] = b
    end
    f.hint = newText(f, "GameFontHighlightSmall", 11)
    f.hint:SetTextColor(0.72, 0.72, 0.75)
    f.hint:SetPoint("TOPLEFT", 14, -90)
    f.tplLabel = newText(f, "GameFontHighlightSmall", 11)
    f.tplLabel:SetTextColor(0.72, 0.72, 0.75)
    f.tplLabel:SetPoint("TOPLEFT", 14, -292)
    f.tplLabel:SetText("START WITH")
    f.tiles = {}
    local tw = floor((DETAIL_W - 28 - 8) / 2)
    for i, t in ipairs(P().TEMPLATES) do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(tw, 64)
        b:SetPoint("TOPLEFT", 14 + ((i - 1) % 2) * (tw + 8), -306 - floor((i - 1) / 2) * 72)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        UI():AddEdges(b, "BORDER")
        b.hl = b:CreateTexture(nil, "HIGHLIGHT")
        b.hl:SetAllPoints()
        b.hl:SetColorTexture(1, 1, 1, 0.04)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(13, 13)
        b.icon:SetPoint("TOPLEFT", 10, -9)
        b.name = newText(b, "GameFontHighlight", 12)
        b.name:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
        b.desc = newText(b, "GameFontHighlightSmall", 11)
        b.desc:SetTextColor(0.72, 0.72, 0.75)
        b.desc:SetWordWrap(true)
        b.desc:SetWidth(tw - 20)
        b.desc:SetPoint("TOPLEFT", 10, -26)
        b.tpl = t
        b:SetScript("OnClick", function(self)
            if self.tpl.key == "copy" then
                UI():ContextMenu(self, function(root)
                    local any = false
                    for _, rec in ipairs(P():GetItems()) do
                        any = true
                        root:CreateRadio(recName(rec), function() return state.adding and state.adding.copyFrom == rec.id end,
                            function()
                                state.adding.tpl, state.adding.copyFrom = "copy", rec.id
                                PrizedUI:RefreshAdd()
                            end)
                    end
                    if not any then root:CreateTitle("No prized items yet") end
                end)
                return
            end
            state.adding.tpl, state.adding.copyFrom = self.tpl.key, nil
            PrizedUI:RefreshAdd()
        end)
        f.tiles[i] = b
    end
    f.cancel = UI():CreateSleekButton(f, "Cancel", 70, 24, function() PrizedUI:CancelAdd() end)
    f.add = UI():CreateSleekButton(f, "Add", 90, 24, function() PrizedUI:ConfirmAdd() end, "primary")
    f.add:SetPoint("BOTTOMRIGHT", -14, 14)
    f.cancel:SetPoint("RIGHT", f.add, "LEFT", -8, 0)
    f.note = newText(f, "GameFontHighlightSmall", 11)
    f.note:SetTextColor(0.72, 0.72, 0.75)
    f.note:SetPoint("BOTTOMLEFT", 14, 20)
    f.note:SetText("You can change every rule after adding it.")
    return f
end

function PrizedUI:CreateView(parent)
    if view then return view end
    local v = CreateFrame("Frame", nil, parent)
    view = v

    local lc = CreateFrame("Frame", nil, v)
    lc:SetPoint("TOPLEFT", PAD, 0)
    lc:SetPoint("BOTTOMLEFT", PAD, 6)
    lc:SetWidth(LIST_W)
    v.left = lc
    v.list = UI():CreateScrollList(lc, ITEM_H, initRow, rowHeight)
    v.list.frame:SetPoint("TOPLEFT", 0, 0)
    v.list.frame:SetPoint("BOTTOMLEFT", 0, 0)
    v.list.frame:SetWidth(LIST_W + 20)
    v.list.bar:ClearAllPoints()
    v.list.bar:SetPoint("TOPLEFT", v.list.box, "TOPRIGHT", 1, 0)
    v.list.bar:SetPoint("BOTTOMLEFT", v.list.box, "BOTTOMRIGHT", 1, 0)
    v.list.emptyText:ClearAllPoints()
    v.list.emptyText:SetPoint("TOPLEFT", v.list.frame, "TOPLEFT", 10, -8)
    v.list.emptyText:SetWidth(LIST_W - 20)
    v.list.emptyText:SetJustifyH("LEFT")
    v.list.emptyText:SetWordWrap(true)

    local dc = CreateFrame("Frame", nil, v)
    dc:SetPoint("TOPLEFT", PAD + LIST_W + GAP, 0)
    dc:SetPoint("BOTTOMLEFT", PAD + LIST_W + GAP, 6)
    dc:SetWidth(DETAIL_W)
    v.detail = dc
    dc.bg = dc:CreateTexture(nil, "BACKGROUND")
    dc.bg:SetAllPoints()
    dc.bg:SetColorTexture(0.06, 0.06, 0.072, 0.9)
    dc.edges = CreateFrame("Frame", nil, dc)
    dc.edges:SetAllPoints()
    UI():AddEdges(dc.edges, "BORDER")
    v.banner = createBanner(dc)
    v.rulesTab = UI():CreateUnderlineTab(dc, "Rules", function() PrizedUI:SetTab("rules") end, "small")
    v.rulesTab:SetPoint("TOPLEFT", 8, -TABS_Y)
    v.histTab = UI():CreateUnderlineTab(dc, "History", function() PrizedUI:SetTab("history") end, "small")
    v.histTab:SetPoint("LEFT", v.rulesTab, "RIGHT", 2, 0)
    v.tabRule = dc:CreateTexture(nil, "BORDER")
    v.tabRule:SetPoint("TOPLEFT", 8, -(TABS_Y + 20))
    v.tabRule:SetPoint("TOPRIGHT", -8, -(TABS_Y + 20))
    v.tabRule:SetHeight(1)
    v.tabRule:SetColorTexture(1, 1, 1, 0.08)

    local sf = UI():CreateScrollFrame(dc)
    sf:SetPoint("TOPLEFT", 8, -BODY_Y)
    sf:SetPoint("BOTTOMRIGHT", -8, 6)
    sf.ScrollBar:ClearAllPoints()
    sf.ScrollBar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 0, 0)
    sf.ScrollBar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 0, 0)
    local body = CreateFrame("Frame", nil, sf)
    body:SetSize(DETAIL_W - 16, 10)
    sf:SetScrollChild(body)
    v.scroll, v.body = sf, body
    body.rulesHead = section(body, "RULES")
    body.qualHead = section(body, "QUALIFY TODAY")
    -- (class icons with the player's name on hover; the count lists every qualifier on hover)
    local function qualTip(self)
        if not self.lines then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        for _, l in ipairs(self.lines) do GameTooltip:AddLine(l[1], l[2], l[3], l[4]) end
        GameTooltip:Show()
    end
    body.stack = {}
    for i = 1, 12 do
        local t = CreateFrame("Frame", nil, body)
        t:SetSize(20, 20)
        t.tex = t:CreateTexture(nil, "ARTWORK")
        t.tex:SetAllPoints()
        t:EnableMouse(true)
        t:SetScript("OnEnter", qualTip)
        t:SetScript("OnLeave", hideTooltip)
        body.stack[i] = t
    end
    body.qualHit = CreateFrame("Frame", nil, body)
    body.qualHit:EnableMouse(true)
    body.qualHit:SetScript("OnEnter", qualTip)
    body.qualHit:SetScript("OnLeave", hideTooltip)
    body.qualText = newText(body, "GameFontHighlight", 12)
    body.qualSub = newText(body, "GameFontHighlightSmall", 11)
    body.qualSub:SetTextColor(0.72, 0.72, 0.75)
    body.foot = newText(body, "GameFontHighlightSmall", 11)
    body.foot:SetTextColor(0.72, 0.72, 0.75)
    body.footIcon = body:CreateTexture(nil, "ARTWORK")
    body.footIcon:SetSize(11, 11)
    body.histLink = CreateFrame("Button", nil, body)
    body.histLink:SetSize(50, 14)
    body.histLink.fs = newText(body.histLink, "GameFontNormalSmall", 10)
    body.histLink.fs:SetPoint("RIGHT")
    body.histLink.fs:SetText("History")
    body.histLink:SetScript("OnClick", function() PrizedUI:SetTab("history") end)
    body.addRule = UI():CreateSleekButton(body, "Add rule", 92, 22, function(self) PrizedUI:OpenAddRuleMenu(self) end)
    body.addRule.glyph = body.addRule:CreateTexture(nil, "ARTWORK")
    body.addRule.glyph:SetSize(10, 10)
    atlasTex(body.addRule.glyph, "plus", 1, 1, 1)
    local afs = body.addRule:GetFontString()
    afs:ClearAllPoints()
    afs:SetPoint("CENTER", 7, 0)
    body.addRule.glyph:SetPoint("RIGHT", afs, "LEFT", -5, 0)
    body.save = UI():CreateSleekButton(body, "Save", 70, 22, function() PrizedUI:SaveEdit() end, "primary")
    body.undo = UI():CreateSleekButton(body, "Cancel", 70, 22, function() PrizedUI:CancelEdit() end)
    body.editNote = newText(body, "GameFontHighlightSmall", 11)
    body.editNote:SetTextColor(0.72, 0.72, 0.75)
    body.editNote:SetWordWrap(true)
    body.editNote:SetWidth(DETAIL_W - 16)
    body.editNote:SetText("Saving tells the guild what changed and adds it to the item's history. The new rules "
        .. "count at once.")
    body.empty = newText(body, "GameFontDisable", 12)
    body.empty:SetWordWrap(true)
    body.empty:SetWidth(DETAIL_W - 40)

    -- nothing picked / no items: one line in the right column
    v.none = newText(dc, "GameFontDisable", 12)
    v.none:SetPoint("TOPLEFT", 16, -16)
    v.none:SetWidth(DETAIL_W - 32)
    v.none:SetWordWrap(true)

    v.add = createAddForm(dc)
    v:SetScript("OnShow", function() PrizedUI:Refresh() end)
    return v
end

-- Puts the one view into `parent` (another page can host it: Raids > Council > Rules), filling it.
-- opts: { list = false (only the picked item's detail, at the left edge), x, y, right, bottom (insets) }.
-- The Raids tab mounts it back when its Loot rules view shows.
function PrizedUI:Mount(parent, opts)
    opts = opts or {}
    local v = self:CreateView(parent)
    if v:GetParent() ~= parent then v:SetParent(parent) end
    v:ClearAllPoints()
    v:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.x or 0, opts.y or 0)
    v:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", opts.right or 0, opts.bottom or 0)
    local list = opts.list ~= false
    state.noList = not list
    v.left:SetShown(list)
    v.detail:ClearAllPoints()
    local x = list and (PAD + LIST_W + GAP) or 0
    v.detail:SetPoint("TOPLEFT", x, 0)
    v.detail:SetPoint("BOTTOMLEFT", x, 6)
    v:Show()
    self:Refresh()
    return v
end

---------------------------------------------------------------------------
-- Filling the right column
---------------------------------------------------------------------------

local histPool, histUsed = {}, 0

-- The players who could take it today (raid log readers): the raiders of the last weeks, by the rules.
local function qualifiers(rec)
    local Att = ns.Attendance
    if not (Att and Att.CanSeeAll and Att:CanSeeAll()) then return nil end
    local rows = Att.GetStats and Att:GetStats(8) or {}
    local ok, n = {}, 0
    for _, s in ipairs(rows) do
        n = n + 1
        local c = P():Check(rec, s.key)
        if c.ok == true then ok[#ok + 1] = { key = s.key, c = c } end
    end
    tsort(ok, function(a, b)
        local first = P():Before(a.c, b.c)
        if first ~= nil then return first end
        return a.key < b.key
    end)
    return ok, n
end

local function fillRules(rec, body)
    local Pz = P()
    local editing = state.draft ~= nil
    local rules = editing and state.draft or rec.r
    local check = not editing and Pz:Check(rec, Me()) or nil
    local by = check and check.by or {}
    for _, r in ipairs(rulePool) do r:Hide() end
    rulesUsed = 0
    local y = 0
    body.rulesHead:SetPoint("TOPLEFT", 0, -y)
    local req, pri = 0, 0
    for k, v in pairs(rules) do
        if k ~= "vote" then
            if (v.m or "r") == "r" then req = req + 1 else pri = pri + 1 end
        end
    end
    body.rulesHead.right:SetText(editing and "gold words open a menu" or
        (req + pri > 0 and format("%d required · %d priority", req, pri) or ""))
    body.rulesHead:Show()
    y = y + 24
    local any = false
    for _, d in ipairs(Pz.RULES) do
        local v = rules[d.key]
        if v then
            any = true
            rulesUsed = rulesUsed + 1
            local r = rulePool[rulesUsed]
            if not r then
                r = newRule(body)
                rulePool[rulesUsed] = r
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, -y)
            local h = fillRule(r, rec, d.key, v, by[d.key], editing)
            r:Show()
            y = y + h
        end
    end
    body.empty:SetShown(not any)
    if not any then
        body.empty:ClearAllPoints()
        body.empty:SetPoint("TOPLEFT", 8, -y - 8)
        body.empty:SetText(editing and "No rules yet: Add rule picks one." or "No rules yet.")
        y = y + 40
    end
    -- editing: Add rule (Save / Cancel are on the banner)
    body.addRule:SetShown(editing)
    body.save:Hide()
    body.undo:Hide()
    body.editNote:SetShown(editing)
    if editing then
        y = y + 12
        body.addRule:ClearAllPoints()
        body.addRule:SetPoint("TOPLEFT", 0, -y)
        body.addRule:SetWidth(floor((body.addRule:GetFontString():GetStringWidth() or 50) + 15 + 24 + 0.5))
        y = y + 22 + 10
        body.editNote:ClearAllPoints()
        body.editNote:SetPoint("TOPLEFT", 0, -y)
        y = y + (body.editNote:GetStringHeight() or 24) + 8
    end
    -- who qualifies today (raid log readers)
    local ok, n = nil, 0
    if not editing then ok, n = qualifiers(rec) end
    local showQual = ok ~= nil and n > 0
    body.qualHead:SetShown(showQual)
    body.qualText:SetShown(showQual)
    body.qualHit:SetShown(showQual)
    for _, t in ipairs(body.stack) do t:Hide() end
    -- (the names line only when the priority rules give a real order among the first few; with no priority
    -- rules, or all tied, the sort is by name, so the line would claim an order that isn't there)
    local ordered = false
    if showQual then
        for i = 1, min(#ok, 5) - 1 do
            if P():Before(ok[i].c, ok[i + 1].c) ~= nil then ordered = true break end
        end
    end
    local showSub = showQual and (#ok == 0 or ordered)
    body.qualSub:SetShown(showSub)
    if showQual then
        y = y + 10
        body.qualHead:SetPoint("TOPLEFT", 0, -y)
        y = y + 26
        local function tipName(i)
            local key = ok[i].key
            local c = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)
            local cc = c and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c]
            local r, g, b = 1, 1, 1
            if cc then r, g, b = cc.r, cc.g, cc.b end
            return (ordered and (i .. ". ") or "") .. shortName(key), r, g, b, c
        end
        local x = 0
        for i = 1, min(#ok, #body.stack) do
            local t = body.stack[i]
            local name, r, g, b, c = tipName(i)
            UI():ClassIcon(t.tex, c)
            t.lines = { { name, r, g, b } }
            if ordered then t.lines[2] = { "In priority order for this item", 0.72, 0.72, 0.75 } end
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", x, -y)
            t:Show()
            x = x + 23
        end
        body.qualText:ClearAllPoints()
        body.qualText:SetPoint("TOPLEFT", x + (x > 0 and 8 or 0), -y - 3)
        body.qualText:SetText(format("%d of %d raiders", #ok, n))
        local lines = { { #ok > 0 and (ordered and "Qualify, next in line first" or "Qualify today") or
            "Nobody qualifies today", 1, 0.82, 0 } }
        for i = 1, #ok do
            local name, r, g, b = tipName(i)
            lines[#lines + 1] = { name, r, g, b }
        end
        body.qualHit.lines = lines
        body.qualHit:ClearAllPoints()
        body.qualHit:SetPoint("TOPLEFT", body.qualText, "TOPLEFT", -2, 2)
        body.qualHit:SetSize((body.qualText:GetStringWidth() or 80) + 4, 18)
        if showSub then
            local names = {}
            for i = 1, min(#ok, 4) do names[#names + 1] = shortName(ok[i].key) end
            body.qualSub:ClearAllPoints()
            body.qualSub:SetPoint("TOPLEFT", 0, -y - 26)
            body.qualSub:SetWidth(DETAIL_W - 16)
            body.qualSub:SetText(#ok > 0 and ("Next in line: " .. tconcat(names, ", ") .. (#ok > 4 and "…" or "")) or
                "Nobody meets every rule right now.")
            y = y + 44
        else
            y = y + 24
        end
    end
    -- who set the rules
    local last = Pz:LastChange(rec.id)
    body.foot:SetShown(not editing)
    body.footIcon:SetShown(not editing)
    body.histLink:SetShown(not editing)
    if not editing then
        y = y + 10
        body.footIcon:ClearAllPoints()
        body.footIcon:SetPoint("TOPLEFT", 0, -y)
        atlasTex(body.footIcon, "stopwatch", 0.56, 0.56, 0.6)
        if not (ns.HasAssets and ns:HasAssets(7)) then atlasTex(body.footIcon, "notes", 0.56, 0.56, 0.6) end
        body.foot:ClearAllPoints()
        body.foot:SetPoint("LEFT", body.footIcon, "RIGHT", 5, 0)
        body.foot:SetText("Rules by the Guild Council" .. (last and (" · changed " ..
            (ns.Util.FormatAgo and ns.Util.FormatAgo(last.at) or "") .. " by " .. coloredKey(last.by)) or ""))
        body.histLink:ClearAllPoints()
        body.histLink:SetPoint("TOPRIGHT", 0, -y + 1)
        y = y + 20
    end
    return y
end

local function fillHistory(rec, body)
    for _, r in ipairs(rulePool) do r:Hide() end
    for _, r in ipairs(histPool) do r:Hide() end
    for _, k in ipairs({ "rulesHead", "qualHead", "qualText", "qualHit", "qualSub", "foot", "footIcon", "histLink", "addRule",
                         "save", "undo", "editNote" }) do
        body[k]:Hide()
    end
    for _, t in ipairs(body.stack) do t:Hide() end
    histUsed = 0
    local y = 0
    local list = P():GetHistory(rec.id)
    for _, e in ipairs(list) do
        histUsed = histUsed + 1
        local r = histPool[histUsed]
        if not r then
            r = newHistRow(body)
            histPool[histUsed] = r
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 0, -y)
        y = y + fillHist(r, e)
        r:Show()
    end
    body.empty:SetShown(#list == 0)
    if #list == 0 then
        body.empty:ClearAllPoints()
        body.empty:SetPoint("TOPLEFT", 8, -8)
        body.empty:SetText("Nothing yet: hand-outs and rule changes show here.")
        y = 40
    end
    return y
end

function PrizedUI:RefreshAdd()
    if not view or not state.adding then return end
    local f = view.add
    local a = state.adding
    -- the raid items matching the search (names from the Atlas data, so items the client hasn't seen are found too)
    local needle = (a.search or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local found, seen = {}, {}
    local Pz = P()
    for _, id in ipairs(a.picked) do
        if not seen[id] then seen[id] = true; found[#found + 1] = id end
    end
    if needle ~= "" then
        for _, raid in ipairs(ns.Data and ns.Data.Raids or {}) do
            for _, boss in ipairs(raid.bosses or {}) do
                for _, id in ipairs(boss.items or {}) do
                    if not seen[id] and #found < #f.results and not Pz:IsPrized(id) then
                        local name = itemName(id)
                        if name:lower():find(needle, 1, true) then
                            seen[id] = true
                            found[#found + 1] = id
                        end
                    end
                end
            end
        end
    end
    local picked = {}
    for _, id in ipairs(a.picked) do picked[id] = true end
    for i, b in ipairs(f.results) do
        local id = found[i]
        b:SetShown(id ~= nil)
        b.itemID = id
        if id then
            b.icon:SetTexture(ns.ItemDB:GetIcon(id))
            b.name:SetText(itemName(id))
            b.name:SetTextColor(qualityColor(id))
            local pl = Pz:Place(id)
            local loc = ns.ItemDB.GetEquipLoc and ns.ItemDB:GetEquipLoc(id)
            local slot = loc and _G[loc]
            b.sub:SetText(((type(slot) == "string" and slot ~= "") and (slot .. " · ") or "") ..
                (pl.bossName and (pl.bossName .. " · ") or "") .. pl.raidName)
            b.check:SetShown(picked[id] and true or false)
        end
    end
    f.hint:ClearAllPoints()
    f.hint:SetPoint("TOPLEFT", 14, -86 - #found * 29 - 6)
    local n = #a.picked
    f.hint:SetText(n == 0 and (needle == "" and "Type part of a name: Dragonspine, Warglaive, Thori'dal…" or
        (#found == 0 and "No raid item by that name (or it is prized already)." or "Pick one, or two that share rules."))
        or (n == 1 and "One item picked." or "Two items picked: they share one set of rules."))
    for _, b in ipairs(f.tiles) do
        local t = b.tpl
        local on = a.tpl == t.key
        b.bg:SetColorTexture(on and 0.15 or 0.085, on and 0.1 or 0.085, on and 0.05 or 0.1, 1)
        UI():SetEdgeColor(b, on and 0.66 or 0.34, on and 0.34 or 0.34, on and 0.1 or 0.38, on and 0.9 or 0.6)
        atlasTex(b.icon, t.icon, on and ORANGE_SOFT[1] or 0.8, on and ORANGE_SOFT[2] or 0.8, on and ORANGE_SOFT[3] or 0.82)
        b.name:SetText(t.label)
        local desc = t.desc
        if t.key == "copy" and a.copyFrom then
            local rec = Pz:Get(a.copyFrom)
            desc = rec and ("the rules of " .. recName(rec)) or desc
        end
        b.desc:SetText(desc)
    end
    f.add:SetText(n > 1 and "Add 2 items" or "Add")
    f.add:SetWidth(floor((f.add:GetFontString():GetStringWidth() or 30) + 28 + 0.5))
    f.add:SetEnabled(n > 0 and a.tpl ~= nil and (a.tpl ~= "copy" or a.copyFrom ~= nil))
end

function PrizedUI:Refresh()
    if not view or not view:IsVisible() then return end
    local Pz = P()
    if not Pz then return end
    local rows = buildRows()
    local items = Pz:GetItems()
    if state.sel and not Pz:Get(state.sel) then state.sel, state.draft = nil, nil end
    if not state.sel and items[1] then state.sel = items[1].id end
    if state.adding and not canEdit() then state.adding = nil end
    view.list:SetData(rows)
    view.list:SetEmptyText(canEdit() and "No prized items yet. Add item (top right) makes one." or
        "No prized items yet. The Guild Master and the guild council choose them.")
    local rec = state.sel and Pz:Get(state.sel)
    local adding = state.adding ~= nil
    view.add:SetShown(adding)
    if adding then self:RefreshAdd() end
    local showRec = rec ~= nil and not adding
    view.banner:SetShown(showRec)
    view.rulesTab:SetShown(showRec)
    view.histTab:SetShown(showRec)
    view.tabRule:SetShown(showRec)
    view.scroll:SetShown(showRec)
    view.none:SetShown(not showRec and not adding)
    view.none:SetText(#items == 0 and (canEdit() and
        "Prized items are the few drops that get stricter loot rules (Dragonspine Trophy, the Warglaives...). " ..
        "Add item picks one; every member then sees its rules and how they stand." or
        "The Guild Master and the guild council haven't picked any prized items yet.") or "")
    if not showRec then return end
    if state.draft and state.tab ~= "rules" then state.tab = "rules" end
    fillBanner(view.banner, rec)
    view.rulesTab:SetActive(state.tab == "rules")
    view.histTab:SetActive(state.tab == "history")
    view.histTab:SetShown(state.draft == nil)
    local y
    if state.tab == "history" then
        y = fillHistory(rec, view.body)
    else
        for _, r in ipairs(histPool) do r:Hide() end
        y = fillRules(rec, view.body)
    end
    view.body:SetHeight(max(10, y))
end

function PrizedUI:RequestRefresh()
    if view and view:IsVisible() then ns.Util.Debounce("prized-ui", 0.1, function() PrizedUI:Refresh() end) end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function PrizedUI:Select(id)
    if state.draft and id ~= state.sel then
        ns:Print("Save or cancel your changes first.")
        return
    end
    state.sel = id
    state.adding = nil
    state.tab = "rules"
    if view and view.scroll then view.scroll:SetVerticalScroll(0) end
    self:Refresh()
end

function PrizedUI:GetSelected() return state.sel end

function PrizedUI:SetTab(tab)
    state.tab = tab == "history" and "history" or "rules"
    if view and view.scroll then view.scroll:SetVerticalScroll(0) end
    self:Refresh()
end

function PrizedUI:IsEditing() return state.draft ~= nil end

function PrizedUI:StartEdit()
    local rec = state.sel and P():Get(state.sel)
    if not rec or not canEdit() then return end
    state.draft = P():CopyRules(rec.r)
    state.tab = "rules"
    self:Refresh()
end

function PrizedUI:CancelEdit()
    state.draft = nil
    self:Refresh()
end

function PrizedUI:SaveEdit()
    if not state.draft or not state.sel then return end
    if P():Save(state.sel, state.draft) then
        state.draft = nil
    end
    self:Refresh()
end

-- (editing) a rule's Required / Priority switch
function PrizedUI:ToggleMode(key)
    local v = state.draft and state.draft[key]
    if not v or key == "vote" then return end
    v.m = (v.m or "r") == "r" and "p" or "r"
    self:Refresh()
end

function PrizedUI:RemoveRule(key)
    if not state.draft then return end
    state.draft[key] = nil
    self:Refresh()
end

function PrizedUI:AddRule(key)
    if not state.draft or state.draft[key] then return end
    state.draft[key] = P():DefaultRule(key)
    self:Refresh()
end

function PrizedUI:OpenAddRuleMenu(owner)
    local rec = state.sel and P():Get(state.sel)
    if not rec or not state.draft then return end
    UI():ContextMenu(owner, function(root)
        root:CreateTitle("Add a rule")
        for _, d in ipairs(P().RULES) do
            local e = root:CreateButton(d.label, function() PrizedUI:AddRule(d.key) end)
            e:SetSubtext(d.desc)
            local used = state.draft[d.key] ~= nil
            local noPair = d.key == "pair" and #rec.ids < 2
            e:SetEnabled(not used and not noPair)
            if noPair then e:SetTitleAndTextTooltip(d.label, "Needs two items sharing these rules (add both together).") end
        end
    end)
end

-- (editing) the menu of a rule's values
local SHORT_CLASS = { WARRIOR = "Warriors", PALADIN = "Paladins", HUNTER = "Hunters", ROGUE = "Rogues",
                      PRIEST = "Priests", SHAMAN = "Shamans", MAGE = "Mages", WARLOCK = "Warlocks", DRUID = "Druids" }
local CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local GROUP_NAMES = { "First", "Second", "Third" }

local function hasToken(g, tok)
    for _, t in ipairs(g or {}) do
        if t == tok then return true end
    end
    return false
end

local function toggleToken(v, gi, tok)
    v.g = v.g or {}
    for i = 1, gi do v.g[i] = v.g[i] or {} end
    -- a spec or class sits in one group only
    for i, g in ipairs(v.g) do
        if i ~= gi then
            for j = #g, 1, -1 do
                if g[j] == tok then table.remove(g, j) end
            end
        end
    end
    local g = v.g[gi]
    for j = #g, 1, -1 do
        if g[j] == tok then
            table.remove(g, j)
            return
        end
    end
    if #g < 12 then g[#g + 1] = tok end
end

function PrizedUI:OpenValueMenu(owner, key)
    local v = state.draft and state.draft[key]
    if not v then return end
    local Pz = P()
    local function refresh() PrizedUI:Refresh() end
    UI():ContextMenu(owner, function(root)
        if key == "att" then
            root:CreateTitle("At least")
            for _, p in ipairs(Pz.ATT_PCT) do
                root:CreateRadio(p .. "%", function() return v.p == p end, function() v.p = p refresh() end)
            end
            root:CreateDivider()
            root:CreateTitle("Over the last")
            for _, w in ipairs(Pz.ATT_WEEKS) do
                root:CreateRadio(w .. " weeks", function() return v.w == w end, function() v.w = w refresh() end)
            end
        elseif key == "rank" then
            root:CreateTitle("This rank or higher")
            for _, rk in ipairs(Pz:GetRanks()) do
                root:CreateRadio(rk.name, function() return v.i == rk.i end, function() v.i = rk.i refresh() end)
            end
        elseif key == "cd" then
            root:CreateTitle("No other prized item in the last")
            for _, w in ipairs(Pz.CD_WEEKS) do
                root:CreateRadio(w == 1 and "1 week" or (w .. " weeks"), function() return v.w == w end,
                    function() v.w = w refresh() end)
            end
        elseif key == "vote" then
            root:CreateTitle("Of the council members in the raid")
            for _, s in ipairs(Pz.VOTE_SHARES) do
                local e = root:CreateRadio(s.label, function() return v.s == s.key end, function() v.s = s.key refresh() end)
                e:SetTitleAndTextTooltip(s.label, s.long .. " must vote for the winner. An award against a rule needs "
                    .. "the same count, with a reason.")
            end
        elseif key == "order" then
            for gi = 1, Pz.MAX_GROUPS do
                if gi == 1 or (v.g and v.g[gi - 1] and #v.g[gi - 1] > 0) then
                    local sub = root:CreateButton(GROUP_NAMES[gi] .. (gi == 1 and "" or " after them"))
                    for _, cls in ipairs(CLASS_ORDER) do
                        local cm = sub:CreateButton(SHORT_CLASS[cls])
                        cm:CreateCheckbox("All " .. SHORT_CLASS[cls]:lower(), function() return v.g and hasToken(v.g[gi], cls) end,
                            function() toggleToken(v, gi, cls) refresh() end)
                        for _, s in ipairs(ns.SPECS and ns.SPECS[cls] or {}) do
                            local tok = cls .. ":" .. s.label
                            cm:CreateCheckbox(s.label, function() return v.g and hasToken(v.g[gi], tok) end,
                                function() toggleToken(v, gi, tok) refresh() end)
                        end
                    end
                end
            end
        elseif key == "queue" then
            v.n = v.n or {}
            for i, k in ipairs(v.n) do
                local e = root:CreateButton(format("%d  %s", i, shortName(k)))
                if i > 1 then
                    e:CreateButton("Move up", function() v.n[i], v.n[i - 1] = v.n[i - 1], v.n[i] refresh() end)
                end
                if i < #v.n then
                    e:CreateButton("Move down", function() v.n[i], v.n[i + 1] = v.n[i + 1], v.n[i] refresh() end)
                end
                e:CreateButton("Take out", function() table.remove(v.n, i) refresh() end)
            end
            if #v.n > 0 then root:CreateDivider() end
            local add = root:CreateButton("Add a player")
            add:SetEnabled(#v.n < Pz.MAX_QUEUE)
            local G = ns.Guild
            local inQueue = {}
            for _, k in ipairs(v.n) do inQueue[k] = true end
            local members = {}
            for _, k in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
                if not inQueue[k] then members[#members + 1] = k end
            end
            tsort(members, function(a, b) return shortName(a) < shortName(b) end)
            if add.SetScrollMode then add:SetScrollMode(360) end
            for _, k in ipairs(members) do
                add:CreateButton(coloredKey(k), function()
                    if #v.n < Pz.MAX_QUEUE then v.n[#v.n + 1] = k end
                    refresh()
                end)
            end
        end
    end)
end

function PrizedUI:ConfirmRemove(id)
    local rec = id and P():Get(id)
    if not rec or not ns.Popup then return end
    ns.Popup:Show("DISASTERZONE_PRIZED_REMOVE", recName(rec), nil, { id = id })
end

-- The add form (Add item at the top right of the Raids page).
function PrizedUI:StartAdd()
    if not canEdit() then return end
    if state.draft then
        ns:Print("Save or cancel your changes first.")
        return
    end
    state.adding = { search = "", picked = {}, tpl = "trinket" }
    if view and view.add then view.add.search:SetText("") end
    self:Refresh()
end

function PrizedUI:IsAdding() return state.adding ~= nil end

function PrizedUI:CancelAdd()
    state.adding = nil
    self:Refresh()
end

function PrizedUI:SetAddSearch(text)
    if not state.adding then return end
    state.adding.search = text or ""
    if view and view.add then view.add.search:SetText(text or "") end
    self:Refresh()
end

function PrizedUI:SetAddTemplate(key, copyFrom)
    if not state.adding then return end
    state.adding.tpl, state.adding.copyFrom = key, copyFrom
    self:Refresh()
end

function PrizedUI:TogglePick(itemID)
    local a = state.adding
    if not a then return end
    for i, id in ipairs(a.picked) do
        if id == itemID then
            table.remove(a.picked, i)
            self:RefreshAdd()
            return
        end
    end
    if #a.picked >= 2 then table.remove(a.picked, 1) end
    a.picked[#a.picked + 1] = itemID
    -- two items: the Legendary start (with Pair) is the likely one
    if #a.picked == 2 and a.tpl == "trinket" then a.tpl = "legendary" end
    self:RefreshAdd()
end

function PrizedUI:ConfirmAdd()
    local a = state.adding
    if not a or #a.picked == 0 or not a.tpl then return end
    local Pz = P()
    local rules, how
    for _, t in ipairs(Pz.TEMPLATES) do
        if t.key == a.tpl then
            how = t.key ~= "blank" and t.key ~= "copy" and ("“" .. t.label .. "”") or nil
            if t.rules then rules = t.rules(#a.picked) end
        end
    end
    if a.tpl == "copy" then
        local from = a.copyFrom and Pz:Get(a.copyFrom)
        if not from then return end
        rules = Pz:CopyRules(from.r)
        how = "rules of " .. recName(from)
    end
    local rec = Pz:Add(a.picked, rules or {}, how)
    if not rec then
        ns:Print("Could not add the item (only the Guild Master and the guild council can).")
        return
    end
    state.adding = nil
    state.sel = rec.id
    state.tab = "rules"
    self:Refresh()
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function PrizedUI:OnInit()
    for _, msg in ipairs({ "PRIZED_UPDATED", "ITEMINFO_READY", "ROSTER_UPDATED", "CONFIG_UPDATED", "DEMO_TOGGLED",
                           "ATTENDANCE_MINE" }) do
        ns:On(msg, function() PrizedUI:RequestRefresh() end)
    end
    ns:On("DEMO_TOGGLED", function()
        state.draft, state.adding, state.sel = nil, nil, nil
    end)
    if ns.Popup and ns.Popup.dialogs then
        ns.Popup.dialogs["DISASTERZONE_PRIZED_REMOVE"] = {
            title = "Remove a prized item",
            text = "Take %s off the prized items?\n\nIts rules go; its history stays.",
            button1 = "Remove",
            button2 = CANCEL or "Cancel",
            danger = true,
            OnAccept = function(_, data)
                if type(data) == "table" and data.id and P():Remove(data.id) then
                    if state.sel == data.id then state.sel = nil end
                    state.draft = nil
                    PrizedUI:Refresh()
                end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
end

-- (1.3.5, Raids > Loot rules for everyone, UI/LootRulesUI.lua: the same pieces at other widths)
PrizedUI.NewRuleRow = function(_, parent, width) return newRule(parent, width) end
-- Fills a rule row for rec's rule key with my standing (res from Prized:Check); returns its height.
PrizedUI.FillRuleRow = function(_, r, rec, key, res) return fillRule(r, rec, key, rec.r[key], res, false) end
PrizedUI.NewHistRow = function(_, parent, width) return newHistRow(parent, width) end
PrizedUI.FillHistRow = function(_, r, e) return fillHist(r, e) end
PrizedUI.NewItemIcons = function(_, parent, size, n) return newItemIcons(parent, size, n) end
PrizedUI.SetItemIcons = function(_, icons, rec, overlap) return setItemIcons(icons, rec, overlap) end
PrizedUI.SetArt = function(_, tex, raidKey, w, h, fw) return setArt(tex, raidKey, w, h, fw) end
PrizedUI.Standing = function(_, rec) return standing(rec) end
PrizedUI.RecName = function(_, rec) return recName(rec) end
PrizedUI.SlotText = function(_, rec) return slotText(rec) end
PrizedUI.RuleIcon = function(_, tex, key, r, g, b) return ruleTex(tex, key, r, g, b) end
