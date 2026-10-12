if DisasterZoneBoot and DisasterZoneBoot.Run("UI/PrizedUI.lua", ...) then return end -- DisasterZone: UI/PrizedUI.lua
-- Raids > Loot rules (1.3.5, mockup dev/art/casc/prized_mockup): the guild's prized items and their loot rules, for
-- every member (Core/Prized.lua has the data and the rule checks).
--   Left:  the prized items by raid (a section header per raid, with how many); each item with its icon in a
--          legendary-orange ring, its slot and boss, and how I stand (You qualify / Free 25 Oct / #1 in queue / Yours /
--          Hunters).
--   Right: the picked item. A banner (the raid's art, the icon, PRIZED ITEM, the name, the slot / boss / raid, my
--          standing as a pill), then two tabs:
--          Rules: one sentence per rule with a Required / Priority / How it's decided pill and, at the right, how I
--          stand against it (my attendance, rank, main or alt, my last prized item...); who qualifies today (the raid
--          log's readers); who set the rules and when they changed last.
--          History: every hand-out (who got it, how many agreed, an award against a rule with its reason) and every
--          rule change, newest first.
--   The GM and the guild council edit in place (Edit on the banner): the sentence opens a menu of its values, each
--   rule switches Required / Priority, the bin removes it, Add rule lists the others; Save tells the guild. Add item
--   (top right of the Raids page) opens the add form in the right column under the same banner (Add / Cancel):
--   search the raid items, pick one or two (two share one set of rules: the Warglaives), start from a template.
-- 1.4: a list + detail layout (UI:CreateLayout): section headers, the shared row looks and pills, the page banner with
-- the tabs on its foot, inset icon wells (UI:CreateCard), compact empty states, every colour a ns.Style token.
local addonName, ns = ...

local PrizedUI = ns:NewModule("PrizedUI")

local S = ns.Style
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat
local format = string.format

local GAP = S.GAP
local LIST_W = 300
local DETAIL_W = S.INNER_W - LIST_W - GAP
local ITEM_H = 42
local SECT_H = 24                    -- a section header (a raid in the list, the form's sections)
local RULE_X = 36                    -- a rule's words, after its icon
local RIGHT_W = 120                  -- my standing at a rule's right end
local EDIT_W = 120                   -- the Required / Priority switch and the bin, editing
local MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\"
local BIS_TEX = MEDIA .. "Icons\\bis"
local CHECK_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"
local CROSS_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local ORANGE = { 1, 0.5, 0 }
local ORANGE_SOFT = { 1, 0.6, 0.18 }

-- state.sel = the picked record id; state.tab = "rules" | "history"; state.draft = the rules being edited (nil = not
-- editing); state.adding = the add form { search, picked = { ids }, tpl, copyFrom }.
local state = { tab = "rules" }
local view
local H = {}           -- (the file's small helpers: the main chunk keeps few locals)

local function UI() return ns.UI end
local function P() return ns.Prized end
local function Me() return ns.Util.PlayerKey() end
local function short(key) return ns.Util.ShortName(key) or tostring(key) end

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

-- A raid's loading screen on a texture, cropped for w x h (under the game's logo). raidKey: the items database's raid
-- key (ItemDB:RaidArt; anything else gets the generic picture).
local function setArt(tex, raidKey, w, h, fw)
    local ItemDB = ns.ItemDB
    if not (ItemDB and ItemDB.RaidArt) then
        tex:Hide()
        return
    end
    local file, l, r, t, b = ItemDB:RaidArt(raidKey or "other", w, h, fw, true)
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

-- An item's icon tiles (a pair: two, overlapping), each in the legendary-orange ring of the prized items: the shared
-- icon tile (UI:CreateIconTile) with an orange edge. f.icon is the texture; f.itemID its item (the tooltip).
local function newItemIcons(parent, size, n)
    local out = {}
    for i = 1, n do
        local f = UI():CreateIconTile(parent, size + 2)
        f.outer:SetColorTexture(ORANGE[1], ORANGE[2], ORANGE[3], 1)   -- uniformity: the prized items' orange ring
        f.icon = f.tex
        UI():AttachTooltip(f, function(self) if self.itemID then UI():SetItemTooltip(self, self.itemID) end end)
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
            if i == 1 then f:SetPoint("TOPLEFT", 1, -1) else f:SetPoint("LEFT", icons[i - 1], "RIGHT", 2 - (overlap or 0), 0) end
        end
    end
end

local function iconsWidth(icons, rec, overlap)
    local w = icons[1]:GetWidth() + 2
    if #rec.ids > 1 then w = w * 2 - (overlap or 0) end
    return w
end

-- A row of the list: a raid's section header (the raid, how many of its items are prized) or an item (its icons, the
-- name in its quality colour, the boss, my standing as a pill), the shared row looks (hover, the picked one).
local function initRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        UI():DecorateRow(row, { selectable = true, rule = true })
        row.head = UI():CreateSectionHeader(row, "")
        row.head:SetPoint("BOTTOMLEFT", 0, 2)
        row.head:SetPoint("BOTTOMRIGHT", 0, 2)
        row.icons = newItemIcons(row, 26, 2)
        row.iconHolder = CreateFrame("Frame", nil, row)
        row.iconHolder:SetSize(30, 30)
        row.iconHolder:SetPoint("LEFT", 9, 0)
        for _, f in ipairs(row.icons) do f:SetParent(row.iconHolder) end
        row.name = UI():Text(row, "emph", "TEXT")
        row.sub = UI():Text(row, "body", "SUB")
        row.pill = UI():CreatePill(row, 16)
        row:SetScript("OnClick", function(self)
            local data = self.__cdlData
            if data and data.kind == "item" then PrizedUI:Select(data.rec.id) end
        end)
    end
    local item = d.kind == "item"
    row:EnableMouse(item)
    row.dzHover:SetShown(item)
    row.dzRule:SetShown(item)
    row.head:SetShown(not item)
    row.iconHolder:SetShown(item)
    row.name:SetShown(item)
    row.sub:SetShown(item)
    row:SetSelected(item and d.rec.id == state.sel and not state.adding)
    row.pill:Hide()
    if not item then
        row.head:SetTitle(d.name)
        row.head:SetCount(d.n)
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

local function rowHeight(d) return d.kind == "raid" and (d.first and SECT_H or SECT_H + GAP) or ITEM_H end
---------------------------------------------------------------------------
-- The banner
---------------------------------------------------------------------------

-- The picked item's banner is the layout's page banner (the raid's art, the item's icon in an orange ring, PRIZED
-- ITEM, the name in its quality colour with my standing as its pill, slot / boss / raid); Edit (or Save / Cancel while
-- editing) are its actions, More (Remove) its tool. The add form has it too (Add a prized item, Add / Cancel).
local function decorateBanner(b)
    b.editActions = { { text = "Edit", onClick = function() PrizedUI:StartEdit() end,
        tip = { "Edit the rules", "Saving tells the guild what changed and adds it to the item's history." } } }
    b.saveActions = {
        { text = "Save", kind = "primary", onClick = function() PrizedUI:SaveEdit() end,
          tip = { "Save the rules", "The guild gets a notification of what changed; the item's history keeps it. The "
              .. "new rules count at once, also on a drop panel that is open now." } },
        { text = "Cancel", onClick = function() PrizedUI:CancelEdit() end },
    }
    b.addAction = { text = "Add", kind = "primary", onClick = function() PrizedUI:ConfirmAdd() end }
    b.cancelAddAction = { text = "Cancel", onClick = function() PrizedUI:CancelAdd() end }
    b.moreTools = { { icon = "more", title = "More", text = "Remove this item from the prized items.",
        menu = function(root)
            local e = root:CreateButton("Remove from prized items", function() PrizedUI:ConfirmRemove(state.sel) end)
            e:SetTitleAndTextTooltip("Remove", "Its rules go; its history stays with the guild for a year.")
        end } }
    return b
end

local function fillBanner(b, rec)
    local pl = P():Place(rec.ids[1])
    b:SetArt(pl.raidKey or "other")
    b:SetKicker("PRIZED ITEM")
    b:SetIcon(ns.ItemDB:GetIcon(rec.ids[1]))
    if not b.icon.cdlItemTip then
        b.icon.cdlItemTip = true
        UI():AttachTooltip(b.icon, function(self) if self.itemID then UI():SetItemTooltip(self, self.itemID) end end)
    end
    b.icon.itemID = rec.ids[1]
    -- a pair (the Warglaives): the second item as a smaller tile on the first one's corner
    local id2 = rec.ids[2]
    b:SetSecondIcon(id2 and ns.ItemDB:GetIcon(id2), id2)
    local r, g, bl = qualityColor(rec.ids[1])
    b:SetTitle(("|cff%02x%02x%02x%s|r"):format(floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(bl * 255 + 0.5),
        recName(rec)))
    b:SetSub(slotText(rec) .. " · " .. (pl.bossName and (pl.bossName .. " · ") or "") .. pl.raidName)
    -- my standing (the list's words), or that the rules are being edited
    local editing = state.draft ~= nil
    local text, kind = standing(rec)
    if editing then
        b:SetPill("warn", "Editing the rules")
    else
        b:SetPill(text and kind or nil, text)
    end
    b:SetActions(editing and b.saveActions or (canEdit() and b.editActions) or nil)
    b:SetTools((canEdit() and editing) and b.moreTools or nil)
end

-- The add form's banner: no art, the prized icon, Add a prized item; Add (its words follow the picks) and Cancel.
local function fillAddBanner(b, n, enabled)
    b:SetArt(nil)
    b:SetSecondIcon(nil)
    b:SetKicker("PRIZED ITEM")
    b:SetIcon(iconIndex("prized"))
    if b.icon then b.icon.itemID = nil end
    b:SetTitle("Add a prized item")
    b:SetSub("You can change every rule after adding it.")
    b:SetPill(nil, nil)
    b.addAction.text = n > 1 and "Add 2 items" or "Add"
    b.addAction.enabled = enabled
    b:SetActions({ b.addAction, b.cancelAddAction })
    b:SetTools(nil)
end
---------------------------------------------------------------------------
-- The rules (shown, or edited)
---------------------------------------------------------------------------

local rulePool, rulesUsed = {}, 0

-- A rule's or a hand-out's icon in a small inset well (a card in its inset tone) at the row's top left.
local function newWell(r)
    r.well = UI():CreateCard(r, { tone = "inset", width = 26, height = 26 })
    r.well:SetPoint("TOPLEFT", 0, -8)
    r.icon = r.well:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(15, 15)
    r.icon:SetPoint("CENTER")
end

local function newRule(parent, width)
    local r = CreateFrame("Frame", nil, parent)
    r.cdlW = width or (DETAIL_W - 16)
    r:SetWidth(r.cdlW)
    newWell(r)
    -- the sentence: a button when editing (it opens the rule's values)
    r.textBtn = CreateFrame("Button", nil, r)
    r.textBtn:SetPoint("TOPLEFT", RULE_X, -6)
    r.text = UI():Text(r.textBtn, "emph", "TEXT")
    r.text:SetPoint("TOPLEFT")
    r.text:SetWordWrap(true)
    r.chev = r.textBtn:CreateTexture(nil, "ARTWORK")
    r.chev:SetSize(9, 9)
    atlasTex(r.chev, "chevron", S:Color("GOLD"))
    r.textBtn:SetScript("OnEnter", function(self)
        if self.editable then r.text:SetTextColor(S:Color("GOLD")) end
    end)
    r.textBtn:SetScript("OnLeave", function() r.text:SetTextColor(S:Color("TEXT")) end)
    UI():AttachTooltip(r.textBtn, function(self, tt)
        if not self.editable then return false end
        tt:AddLine("Change", S:RGB("GOLD"))
        tt:AddLine("Pick this rule's values.", 1, 1, 1, true)
    end, nil, { anchor = "ANCHOR_TOP" })
    r.textBtn:SetScript("OnClick", function(self)
        if self.editable and r.ruleKey then PrizedUI:OpenValueMenu(self, r.ruleKey) end
    end)
    r.pill = UI():CreatePill(r, 15)
    r.sub = UI():Text(r, "body", "SUB")
    r.sub:SetWordWrap(true)
    -- the queue's names
    r.names = UI():Text(r, "body", "TEXT")
    r.names:SetWordWrap(true)
    -- my standing
    r.val = UI():Text(r, "emph", "TEXT")
    r.val:SetJustifyH("RIGHT")
    r.mark = r:CreateTexture(nil, "ARTWORK")
    r.mark:SetSize(13, 13)
    r.mark:SetPoint("TOPRIGHT", 0, -9)
    r.val:SetPoint("RIGHT", r.mark, "LEFT", -4, 0)
    r.note = UI():Text(r, "body", "SUB")
    r.note:SetJustifyH("RIGHT")
    r.note:SetPoint("TOPRIGHT", r.mark, "BOTTOMRIGHT", 0, -6)
    -- editing: Required / Priority, the bin
    r.modeBtn = UI():CreateSleekButton(r, "Required", 72, 20, function()
        if r.ruleKey then PrizedUI:ToggleMode(r.ruleKey) end
    end)
    r.modeBtn:SetPoint("TOPRIGHT", -26, -8)
    UI():AttachTooltip(r.modeBtn, "Required or Priority", "Required: players who don't meet it can't get the item "
        .. "(the council can still give it with a reason everyone sees). Priority: it doesn't keep anyone out; who meets "
        .. "it goes first.", { anchor = "ANCHOR_TOP" })
    r.bin = UI():CreateRemoveButton(r, "Remove this rule")
    r.bin:SetPoint("TOPRIGHT", 0, -9)
    r.bin:SetScript("OnClick", function() if r.ruleKey then PrizedUI:RemoveRule(r.ruleKey) end end)
    r.rule = UI():Rule(r, { bottom = 0, layer = "BORDER" })
    return r
end

local MODE_PILL = { r = { "Required", "warn" }, p = { "Priority", "alt" } }

-- Fills one rule row; returns its height.
local function fillRule(r, rec, rkey, v, res, editing)
    local Pz = P()
    r.ruleKey = rkey
    ruleTex(r.icon, rkey, S:Color("TEXT"))
    local text, sub = Pz:RuleText(rkey, v, rec)
    local rightW = editing and EDIT_W or ((res and (res.value or res.ok ~= nil)) and RIGHT_W or 0)
    local textW = (r.cdlW or (DETAIL_W - 16)) - RULE_X - rightW - 8
    r.text:SetWidth(textW)
    r.text:SetText(text)
    r.text:SetTextColor(S:Color("TEXT"))
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
            local name = UI():ColoredName(k)
            local got = #Pz:GetGiven({ i = rec.id, to = k }) >= #rec.ids
            local me = ns.Util.IsMe(k)
            parts[#parts + 1] = format("%s %s%s%s", S:Wrap("SUB", i), name, me and (" " .. S:Wrap("SUB", "(you)")) or "",
                got and (" " .. S:Wrap("SUB", "(has it)")) or "")
        end
        r.names:SetWidth(textW)
        r.names:ClearAllPoints()
        r.names:SetPoint("TOPLEFT", RULE_X, -y)
        r.names:SetText(#parts > 0 and tconcat(parts, "   ") or S:Wrap("SUB", "Nobody yet: add players to the queue."))
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
        -- (missed: amber for a required rule, grey for a priority one; met: white, the attendance green)
        local col = res.ok == false and (res.m == "p" and "SUB" or "WARN") or (res.ok and "TEXT" or "SUB")
        if rkey == "att" and res.ok then col = "OK" end
        r.val:SetText(res.value or "")
        r.val:SetTextColor(S:Color(col))
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

local function section(parent, text, opts)
    local o = { style = "caps" }
    for k, v in pairs(opts or {}) do o[k] = v end
    local s = UI():CreateSectionHeader(parent, text, o)
    s:SetWidth(DETAIL_W - 16)
    return s
end

local function newHistRow(parent, width)
    local r = CreateFrame("Frame", nil, parent)
    r.cdlW = width or (DETAIL_W - 16)
    r:SetWidth(r.cdlW)
    newWell(r)
    r.title = UI():Text(r, "emph", "TEXT")
    r.title:SetPoint("TOPLEFT", RULE_X, -7)
    r.title:SetWordWrap(true)
    r.sub = UI():Text(r, "body", "SUB")
    r.sub:SetWordWrap(true)
    r.when = UI():Text(r, "body", "SUB", { justify = "RIGHT" })
    r.when:SetPoint("TOPRIGHT", 0, -9)
    r.rule = UI():Rule(r, { bottom = 0, layer = "BORDER" })
    return r
end

local function coloredKey(k) return UI():ColoredName(k) end

local function fillHist(r, e)
    local Pz = P()
    local w = (r.cdlW or (DETAIL_W - 16)) - RULE_X - 90
    r.title:SetWidth(w)
    r.sub:SetWidth(w)
    local h = e.rec
    if e.kind == "G" then
        -- (an award against a rule: amber)
        atlasTex(r.icon, "trophy", S:Color(h.ov and "WARN" or "TEXT"))
        local item = itemName(h.it)
        local rec = Pz:Get(h.i)
        r.title:SetText(format("%s got %s", coloredKey(h.to), (rec and #rec.ids > 1) and item or "it"))
        local agreed = (h.ag and h.of and h.of > 0) and format("%d of %d agreed", h.ag, h.of) or nil
        local parts = {}
        if h.ov then
            local labels = {}
            for _, k in ipairs(h.ov) do labels[#labels + 1] = (Pz.RULE[k] and Pz.RULE[k].label or k):lower() end
            parts[#parts + 1] = S:Wrap("WARN", "Against the " .. tconcat(labels, ", ") .. " rule")
            if h.why then parts[#parts + 1] = "“" .. h.why .. "”" end
        else
            parts[#parts + 1] = "All rules met"
        end
        parts[#parts + 1] = (h.ov and ("by " .. coloredKey(h.by) .. (agreed and (", " .. agreed) or "")) or agreed)
        r.sub:SetText(tconcat(parts, " · "))
    else
        local made = h.t:find("^Made a prized item") ~= nil
        if made then atlasTex(r.icon, "prized", ORANGE_SOFT[1], ORANGE_SOFT[2], ORANGE_SOFT[3])
        else atlasTex(r.icon, "pencil", S:Color("TEXT")) end
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

-- The add form (the detail's body; its banner says Add a prized item, with Add / Cancel): the raid items matching the
-- search (picked ones lit with the shared selected look), then the templates to start from.
local function createAddForm(dc)
    -- (it scrolls like the rules: the results and the templates may be taller than the room under the banner)
    local sf = UI():CreateScrollFrame(dc)
    sf:SetPoint("TOPLEFT", 8, 0)
    sf:SetPoint("BOTTOMRIGHT", -8, 6)
    sf.ScrollBar:ClearAllPoints()
    sf.ScrollBar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 0, 0)
    sf.ScrollBar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 0, 0)
    local W = DETAIL_W - 16
    local f = CreateFrame("Frame", nil, sf)
    f:SetSize(W, 400)
    sf:SetScrollChild(f)
    f.scroll = sf
    f.itemHead = section(f, "Item (up to two: they share one set of rules)")
    f.itemHead:SetPoint("TOPLEFT", 0, 0)
    f.search = UI():CreateSearchBox(f, W, function(text)
        state.adding.search = text or ""
        PrizedUI:RefreshAdd()
    end, "Search the raid items")
    f.search:SetPoint("TOPLEFT", 0, -(SECT_H))
    f.results = {}
    for i = 1, 6 do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(W, 30)
        b:SetPoint("TOPLEFT", 0, -(SECT_H + 28) - (i - 1) * 30)
        UI():DecorateRow(b, { selectable = true })
        b.icon = UI():CreateIconTile(b, 22)
        b.icon:SetPoint("LEFT", 10, 0)
        b.name = UI():Text(b, "emph", "TEXT")
        b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 8, 2)
        b.sub = UI():Text(b, "small", "SUB")
        b.sub:SetPoint("TOPLEFT", b.name, "BOTTOMLEFT", 0, -1)
        b:SetScript("OnClick", function(self) if self.itemID then PrizedUI:TogglePick(self.itemID) end end)
        UI():AttachTooltip(b, function(self) if self.itemID then UI():SetItemTooltip(self, self.itemID) end end)
        f.results[i] = b
    end
    f.hint = UI():Text(f, "body", "SUB")
    f.hint:SetPoint("TOPLEFT", 0, -(SECT_H + 32))
    f.tplHead = section(f, "Start with")
    f.tiles = {}
    local tw = floor((W - GAP) / 2)
    for i, t in ipairs(P().TEMPLATES) do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(tw, 64)
        b.col, b.row = (i - 1) % 2, floor((i - 1) / 2)
        b.x = b.col * (tw + GAP)
        b.card = UI():CreateCard(b, { tone = "inset" })
        b.card:SetAllPoints()
        b.card:SetFrameLevel(b:GetFrameLevel())
        UI():DecorateRow(b, { selectable = true })
        b.icon = b:CreateTexture(nil, "OVERLAY")
        b.icon:SetSize(13, 13)
        b.icon:SetPoint("TOPLEFT", 10, -9)
        b.name = UI():Text(b, "emph", "TEXT")
        b.name:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
        b.desc = UI():Text(b, "body", "SUB", { wrap = true, width = tw - 20 })
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
    return f
end

-- (the add form and a fresh view have no tabs: the strip gives its room back)
function H.SetTabsShown(on)
    view.layout:SetTabsShown(on)
end

function PrizedUI:CreateView(parent)
    if view then return view end
    local v = CreateFrame("Frame", nil, parent)
    view = v
    -- a list + detail page: the items by raid, the picked one (its banner with the Rules / History tabs on its foot,
    -- then the open tab), or the add form under the same banner
    local L = UI():CreateLayout("listdetail", v, { toolbar = false, listWidth = LIST_W,
        banner = { size = "hero", kickerColor = ORANGE_SOFT, iconRing = { 1, 0.5, 0, 0.9 }, artFw = 0.95, artUnder = true },
        tabs = { { key = "rules", text = "Rules" }, { key = "history", text = "History" } },
        onTab = function(key) PrizedUI:SetTab(key) end, noAnchor = true })
    -- (the page's width from the view's left edge, as before: a host narrower than the page keeps the columns' widths)
    L:SetPoint("TOPLEFT", v, "TOPLEFT", 0, 0)
    L:SetPoint("BOTTOMLEFT", v, "BOTTOMLEFT", 0, 0)
    L:SetWidth(S.PAGE_W)
    v.layout = L

    local lc = L.list
    v.left = lc
    v.list = UI():CreateScrollList(lc, ITEM_H, initRow, rowHeight)
    v.list.frame:SetPoint("TOPLEFT", 0, 0)
    v.list.frame:SetPoint("BOTTOMLEFT", 0, 0)
    v.list.frame:SetWidth(LIST_W + 20)
    v.list.bar:ClearAllPoints()
    v.list.bar:SetPoint("TOPLEFT", v.list.box, "TOPRIGHT", 1, 0)
    v.list.bar:SetPoint("BOTTOMLEFT", v.list.box, "BOTTOMRIGHT", 1, 0)

    local dc = L.detail
    v.detail = dc
    v.banner = decorateBanner(L.banner)
    v.tabs = L.tabs
    v.rulesTab, v.histTab = L.tabs:GetTab("rules"), L.tabs:GetTab("history")

    local sf = UI():CreateScrollFrame(L.body)
    sf:SetPoint("TOPLEFT", 8, 0)
    sf:SetPoint("BOTTOMRIGHT", -8, 6)
    sf.ScrollBar:ClearAllPoints()
    sf.ScrollBar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 0, 0)
    sf.ScrollBar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 0, 0)
    local body = CreateFrame("Frame", nil, sf)
    body:SetSize(DETAIL_W - 16, 10)
    sf:SetScrollChild(body)
    v.scroll, v.body = sf, body
    body.rulesHead = section(body, "Rules")
    body.qualHead = section(body, "Qualify today")
    -- (class icons with the player's name on hover; the count lists every qualifier on hover)
    local function qualLines(self) return self.lines end
    body.stack = {}
    for i = 1, 12 do
        local t = CreateFrame("Frame", nil, body)
        t:SetSize(20, 20)
        t.tex = t:CreateTexture(nil, "ARTWORK")
        t.tex:SetAllPoints()
        UI():AttachTooltip(t, nil, qualLines, { anchor = "ANCHOR_TOP" })
        body.stack[i] = t
    end
    body.qualHit = CreateFrame("Frame", nil, body)
    UI():AttachTooltip(body.qualHit, nil, qualLines, { anchor = "ANCHOR_TOP" })
    body.qualText = UI():Text(body, "emph", "TEXT")
    body.qualSub = UI():Text(body, "body", "SUB")
    -- who set the rules, and the way to the History tab
    body.foot = section(body, "", { rule = false, action = { text = "History",
        onClick = function() PrizedUI:SetTab("history") end } })
    body.histLink = body.foot.action
    body.addRule = UI():CreateSleekButton(body, UI():AtlasIconText(iconIndex("plus"), 10) .. "  Add rule", 92, S.BTN_H,
        function(self) PrizedUI:OpenAddRuleMenu(self) end)
    body.editNote = UI():Text(body, "body", "SUB", { wrap = true, width = DETAIL_W - 16 })
    body.editNote:SetText("Saving tells the guild what changed and adds it to the item's history. The new rules "
        .. "count at once.")
    -- no rules / no history yet: a compact illustrated state
    body.empty = UI():CreateEmptyState(body, { compact = true, glyph = iconIndex("prized") })
    body.empty:SetBoxWidth(DETAIL_W - 60)

    -- nothing picked / no items: an illustrated empty state in the right column
    v.none = UI():CreateEmptyState(dc, { compact = true, glyph = iconIndex("prized") })
    v.none:SetPoint("TOP", dc, "TOP", 0, -60)
    v.none:SetBoxWidth(DETAIL_W - 60)
    v.none:Hide()

    v.add = createAddForm(L.body)
    v.addScroll = v.add.scroll
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
    -- (no list: the detail takes the list's place)
    v.layout.listW = list and LIST_W or -GAP
    v.layout:Layout()
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

-- The compact illustrated state in the body (no rules / no history yet) at y; returns its height.
local function showEmpty(body, y, title, text)
    local e = body.empty
    e:SetContent({ glyph = iconIndex("prized"), title = title, text = text })
    e:ClearAllPoints()
    e:SetPoint("TOP", body, "TOP", 0, -y - 12)
    e:Show()
    return (e:GetHeight() or 80) + 24
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
    body.rulesHead:SetRight(editing and "gold words open a menu" or
        (req + pri > 0 and format("%d required · %d priority", req, pri) or nil))
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
    body.empty:Hide()
    if not any then
        y = y + showEmpty(body, y, "No rules yet", editing and "Add rule picks one." or nil)
    end
    -- editing: Add rule (Save / Cancel are on the banner)
    body.addRule:SetShown(editing)
    body.editNote:SetShown(editing)
    if editing then
        y = y + 12
        body.addRule:ClearAllPoints()
        body.addRule:SetPoint("TOPLEFT", 0, -y)
        body.addRule:SetWidth(floor(UI():TextWidth("Add rule", "body") + 10 + 6 + 28 + 0.5))
        y = y + S.BTN_H + 10
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
            local r, g, b = UI():ClassColor(c)
            return (ordered and (i .. ". ") or "") .. short(key), r or 1, g or 1, b or 1, c
        end
        local x = 0
        for i = 1, min(#ok, #body.stack) do
            local t = body.stack[i]
            local name, r, g, b, c = tipName(i)
            UI():ClassIcon(t.tex, c)
            t.lines = { { name, r, g, b } }
            if ordered then t.lines[2] = { "In priority order for this item", "SUB" } end
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", x, -y)
            t:Show()
            x = x + 23
        end
        body.qualText:ClearAllPoints()
        body.qualText:SetPoint("TOPLEFT", x + (x > 0 and 8 or 0), -y - 3)
        body.qualText:SetText(format("%d of %d raiders", #ok, n))
        local lines = { { #ok > 0 and (ordered and "Qualify, next in line first" or "Qualify today") or
            "Nobody qualifies today", "GOLD" } }
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
            for i = 1, min(#ok, 4) do names[#names + 1] = short(ok[i].key) end
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
    -- who set the rules, and the History link
    local last = Pz:LastChange(rec.id)
    body.foot:SetShown(not editing)
    if not editing then
        y = y + 10
        body.foot:ClearAllPoints()
        body.foot:SetPoint("TOPLEFT", 0, -y)
        body.foot:SetPoint("TOPRIGHT", 0, -y)
        body.foot:SetTitle("Rules by the Guild Council" .. (last and (" · changed " ..
            (ns.Util.FormatAgo and ns.Util.FormatAgo(last.at) or "") .. " by " .. coloredKey(last.by)) or ""))
        y = y + 20
    end
    return y
end

local function fillHistory(rec, body)
    for _, r in ipairs(rulePool) do r:Hide() end
    for _, r in ipairs(histPool) do r:Hide() end
    for _, k in ipairs({ "rulesHead", "qualHead", "qualText", "qualHit", "qualSub", "foot", "addRule", "editNote",
                         "empty" }) do
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
    if #list == 0 then
        y = showEmpty(body, 0, "Nothing yet", "Hand-outs and rule changes show here.")
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
            b.icon:Set(ns.ItemDB:GetIcon(id))
            b.name:SetText(itemName(id))
            b.name:SetTextColor(qualityColor(id))
            local pl = Pz:Place(id)
            local loc = ns.ItemDB.GetEquipLoc and ns.ItemDB:GetEquipLoc(id)
            local slot = loc and _G[loc]
            b.sub:SetText(((type(slot) == "string" and slot ~= "") and (slot .. " · ") or "") ..
                (pl.bossName and (pl.bossName .. " · ") or "") .. pl.raidName)
            b:SetSelected(picked[id] and true or false)
        end
    end
    f.hint:ClearAllPoints()
    local hy = SECT_H + 28 + #found * 30 + 6
    f.hint:SetPoint("TOPLEFT", 10, -hy)
    -- the templates under the hint
    local ty = hy + 20 + GAP
    f.tplHead:ClearAllPoints()
    f.tplHead:SetPoint("TOPLEFT", 0, -ty)
    ty = ty + SECT_H
    for _, b in ipairs(f.tiles) do
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", b.x, -(ty + b.row * (64 + GAP)))
    end
    f:SetHeight(ty + floor((#f.tiles + 1) / 2) * (64 + GAP))
    local n = #a.picked
    f.hint:SetText(n == 0 and (needle == "" and "Type part of a name: Dragonspine, Warglaive, Thori'dal…" or
        (#found == 0 and "No raid item by that name (or it is prized already)." or "Pick one, or two that share rules."))
        or (n == 1 and "One item picked." or "Two items picked: they share one set of rules."))
    for _, b in ipairs(f.tiles) do
        local t = b.tpl
        local on = a.tpl == t.key
        b:SetSelected(on)
        if on then atlasTex(b.icon, t.icon, S:Color("GOLD")) else atlasTex(b.icon, t.icon, S:Color("SUB")) end
        b.name:SetText(t.label)
        local desc = t.desc
        if t.key == "copy" and a.copyFrom then
            local rec = Pz:Get(a.copyFrom)
            desc = rec and ("the rules of " .. recName(rec)) or desc
        end
        b.desc:SetText(desc)
    end
    -- the banner: Add (its words follow the picks) and Cancel
    fillAddBanner(view.banner, n, n > 0 and a.tpl ~= nil and (a.tpl ~= "copy" or a.copyFrom ~= nil))
    f.add, f.cancel = view.banner.actions[1], view.banner.actions[2]
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
    local showRec = rec ~= nil and not adding
    view.addScroll:SetShown(adding)
    view.banner:SetShown(showRec or adding)
    H.SetTabsShown(showRec)
    view.scroll:SetShown(showRec)
    if adding then self:RefreshAdd() end
    local noneText = #items == 0 and (canEdit() and
        "Prized items are the few drops that get stricter loot rules (Dragonspine Trophy, the Warglaives...). " ..
        "Add item picks one; every member then sees its rules and how they stand." or
        "The Guild Master and the guild council haven't picked any prized items yet.") or nil
    view.none:SetShown(not showRec and not adding and noneText ~= nil)
    if noneText then view.none:SetContent({ glyph = iconIndex("prized"), title = "No prized items yet", text = noneText }) end
    if not showRec then return end
    if state.draft and state.tab ~= "rules" then state.tab = "rules" end
    fillBanner(view.banner, rec)
    -- (the block tabs count the rules and the history's entries)
    local nRules = 0
    for k in pairs(state.draft or rec.r) do if k then nRules = nRules + 1 end end
    view.tabs:SetTabCount("rules", nRules)
    view.tabs:SetTabCount("history", #P():GetHistory(rec.id))
    view.tabs:SetTabShown("history", state.draft == nil)
    view.tabs:SelectTab(state.tab)
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
                local e = root:CreateButton(format("%d  %s", i, short(k)))
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
            tsort(members, function(a, b) return short(a) < short(b) end)
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
    ns.Popup:Confirm({ key = "PRIZED_REMOVE", title = "Remove a prized item", danger = true,
        text = ("Take %s off the prized items?\n\nIts rules go; its history stays."):format(recName(rec)),
        ok = "Remove", onAccept = function()
            if P():Remove(id) then
                if state.sel == id then state.sel = nil end
                state.draft = nil
                PrizedUI:Refresh()
            end
        end })
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
