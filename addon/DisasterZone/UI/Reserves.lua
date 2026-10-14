if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Reserves.lua", ...) then return end -- DisasterZone: UI/Reserves.lua
-- The loot reserves window (1.4.3, ns.ReservesUI; the list is Core/Reserves.lua's). A tool window on the raid's art:
--   My reserves: the raid's loot boss by boss (the Atlas's tables) with the reserves on it: how many players are on each
--     item (class dots), a star on what is on my BiS list (the star tool shows only those), the guild's items greyed
--     out. A click reserves or takes back; my picks sit at the foot. The host also marks the guild's items here
--     ("Guild items" on the tool row: a click holds / frees an item).
--   Reserves: every reserved item with its reservers, each with a mark for how it came in (DisasterZone, LootReserve, a
--     whisper, an import); who still has reserves to pick (the host whispers them); a blacklist heads-up. The host
--     right-clicks a name to take a reserve back.
--   Wrap-up: the night's reserve rolls, who got the item and how; posted to raid chat or exported.
-- The host's ··· menu: Import (softres.it, Gargul, LootReserve), Export, post the list / the rules, whisper the
-- players who still have reserves, close / reopen, clear. /dz reserves opens it (demo: /dz reserves demo).
local addonName, ns = ...

local RUI = ns:NewModule("ReservesUI")
local S = ns.Style

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local W, H = 760, 540
local CONTENT_W = W - 10
local RAIL_W, RAIL_ROW = 172, 38
local TILE_H, TILE_GAP, ICON = 46, 5, 34
local LIST_ROW, SIDE_W = 40, 236
local FOOT_H = 44
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SRC_TAG = { d = "DZ", l = "LR", w = "W", s = "SR", h = "LD" }

local win
local st = { view = "pick", boss = nil, onlyBiS = false, holdMode = false }

local function UI() return ns.UI end
local function Res() return ns.Reserves end

local function Name(key)
    return UI():ColoredName(key)
end

local function ItemName(itemID)
    return (UI():ItemText(itemID))
end

local function IsMine(itemID)
    local BiS = ns.BiS
    local m = BiS and BiS.MatchItem and BiS:MatchItem(itemID)
    if type(m) ~= "table" then return nil end
    for _, x in ipairs(m) do
        if type(x) == "table" and not x.obtained then return x end
    end
    return nil
end

local function RaidName(rk)
    local DB = ns.ItemDB
    local raid = rk and DB and DB.GetRaid and DB:GetRaid(rk)
    return raid and raid.name or "Raid"
end

local function Portrait(rk, bossKey)
    local J = ns.Data and ns.Data.BossJournal
    return J and rk and bossKey and J[rk .. ":" .. bossKey] or nil
end

local function Tip(owner, title, lines)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, S:Color("GOLD"))
    for _, l in ipairs(lines or {}) do GameTooltip:AddLine(l, 0.8, 0.8, 0.8, true) end
    GameTooltip:Show()
end

-- "Soft reserve · 2 each · open · closes at the first pull".
function RUI:RulesLine(L)
    L = L or Res():Get()
    if not L then return "No reserves in this raid." end
    local parts = { "Soft reserve", (L.n == 1 and "1 each" or (L.n .. " each")) }
    if #(L.h or {}) > 0 then parts[#parts + 1] = #L.h .. " held for the guild" end
    if L.foreign then
        parts[#parts + 1] = "LootReserve, run by " .. ns.Util.ShortName(L.foreign)
    elseif L.o then
        parts[#parts + 1] = "open · closes at the first pull"
    else
        parts[#parts + 1] = "closed"
    end
    return tconcat(parts, " · ")
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------
local Build = {}

function Build.Window()
    local f = UI():CreateWindow("DisasterZoneReserves", "Reserves", W, H)
    f:Hide()
    local c = f.content or f
    local L = UI():CreateLayout("tool", c, { width = CONTENT_W, toolbar = true,
        banner = { size = "tool", kicker = "Loot reserves", title = "Reserves", icon = "reserve" } })
    f.layout = L
    local bar = L.toolbar
    bar:SetTabs({ { key = "pick", text = "My reserves" }, { key = "list", text = "Reserves" },
                  { key = "wrap", text = "Wrap-up" }, selected = st.view }, function(key) RUI:Show(key) end)
    f.holdBtn = UI():CreateSleekButton(bar, "Guild items", 92, S.BTN_H, function() RUI:ToggleHoldMode() end)
    UI():AttachTooltip(f.holdBtn, "Guild items", { "Click items to hold them for the guild: nobody can reserve "
        .. "them, and the loot council decides them among guild members. Click again to be done." })
    bar:SetFilters({ f.holdBtn })
    bar:SetMore(function(root) RUI:MoreMenu(root) end, "Import, export, post, whisper, close, clear")
    f.body = L.body
    Build.Pick(f)
    Build.List(f)
    Build.Wrap(f)
    f:HookScript("OnHide", function() st.holdMode = false end)
    ns:On("RESERVES_CHANGED", function() RUI:RequestRefresh() end)
    ns:On("ROLL_UPDATED", function() if st.view == "wrap" then RUI:RequestRefresh() end end)
    ns:On("ITEMINFO_READY", function() RUI:RequestRefresh() end)
    win = f
    return f
end

---------------------------------------------------------------------------
-- My reserves: the boss rail and the item tiles
---------------------------------------------------------------------------
function Build.Pick(f)
    local p = CreateFrame("Frame", nil, f.body)
    p:SetAllPoints(f.body)
    f.pick = p
    p.rail, p.tiles = {}, {}
    -- the bosses scroll (Karazhan has 13 and its trash)
    p.railScroll = UI():CreateScrollFrame(p, "DisasterZoneReservesRail")
    p.railScroll:SetPoint("TOPLEFT", 0, 0)
    p.railScroll:SetPoint("BOTTOMLEFT", 0, FOOT_H + 4)
    p.railScroll:SetWidth(RAIL_W - 8)
    p.railScroll.scrollBarHideable = true
    p.railFrame = CreateFrame("Frame", nil, p.railScroll)
    p.railFrame:SetSize(RAIL_W - 8, 1)
    p.railScroll:SetScrollChild(p.railFrame)
    local scroll = UI():CreateScrollFrame(p, "DisasterZoneReservesTiles")
    scroll:SetPoint("TOPLEFT", p, "TOPLEFT", RAIL_W + 10, 0)
    scroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -12, FOOT_H)
    scroll.scrollBarHideable = true
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CONTENT_W - 2 * S.PAD - RAIL_W - 22, 1)
    scroll:SetScrollChild(child)
    p.scroll, p.child = scroll, child
    -- the foot: my picks
    local foot = CreateFrame("Frame", nil, p)
    foot:SetPoint("BOTTOMLEFT", 0, 0)
    foot:SetPoint("BOTTOMRIGHT", 0, 0)
    foot:SetHeight(FOOT_H)
    UI():Rule(foot, { top = 0 })
    foot.label = UI():Text(foot, "small", "SUB", { text = "Your reserves" })
    foot.label:SetPoint("LEFT", 0, -2)
    foot.slots = {}
    foot.note = UI():Text(foot, "small", "DIM")
    foot.note:SetPoint("RIGHT", foot, "RIGHT", 0, -2)
    foot.note:SetJustifyH("RIGHT")
    p.foot = foot
    p.empty = UI():Text(p, "body", "SUB")
    p.empty:SetPoint("TOP", scroll, "TOP", 0, -60)
    p.empty:SetWidth(360)
    p.empty:SetWordWrap(true)
    p.empty:SetJustifyH("CENTER")
end

local function RailRow(p, i)
    local r = p.rail[i]
    if r then return r end
    r = CreateFrame("Button", nil, p.railFrame)
    r:SetHeight(RAIL_ROW - 2)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * RAIL_ROW)
    r:SetPoint("TOPRIGHT", 0, -(i - 1) * RAIL_ROW)
    UI():DecorateRow(r, { selectable = true })
    r.face = r:CreateTexture(nil, "ARTWORK")
    r.face:SetSize(26, 26)
    r.face:SetPoint("LEFT", 6, 0)
    if r.CreateMaskTexture then
        local m = r:CreateMaskTexture()
        m:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        m:SetAllPoints(r.face)
        r.face:AddMaskTexture(m)
    end
    r.name = UI():Text(r, "body")
    r.name:SetPoint("LEFT", 38, 0)
    r.name:SetWidth(RAIL_W - 8 - 38 - 24)
    r.name:SetWordWrap(true)
    if r.name.SetMaxLines then r.name:SetMaxLines(2) end
    r.name:SetJustifyH("LEFT")
    r.badge = UI():CreateCountBadge(r, 15)
    r.badge:SetPoint("RIGHT", -6, 0)
    r:SetScript("OnClick", function(self)
        st.boss = self.key
        RUI:Refresh()
    end)
    p.rail[i] = r
    return r
end

local function Tile(p, i)
    local t = p.tiles[i]
    if t then return t end
    t = CreateFrame("Button", nil, p.child)
    t:SetHeight(TILE_H)
    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    t.bg = UI():Fill(t, "CARD", "BACKGROUND")
    UI():AddEdges(t, "BORDER")
    UI():DecorateRow(t, {})
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(ICON, ICON)
    t.icon:SetPoint("LEFT", 6, 0)
    t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    t.name = UI():Text(t, "body")
    t.name:SetPoint("TOPLEFT", ICON + 14, -7)
    t.name:SetWordWrap(false)
    t.line = UI():Text(t, "small", "SUB")
    t.line:SetPoint("TOPLEFT", ICON + 14, -25)
    t.line:SetWordWrap(false)
    t.dots = {}
    t:SetScript("OnEnter", function(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID) end
        local keys = Res():Reservers(self.itemID)
        if Res():IsHeld(self.itemID) then
            GameTooltip:AddLine("Held for the guild: the loot council decides it.", 1, 0.55, 0.45, true)
        elseif #keys > 0 then
            local names = {}
            for k, key in ipairs(keys) do names[k] = Name(key) end
            GameTooltip:AddLine("Reserved by " .. tconcat(names, ", "), S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], true)
        end
        if self.hint then GameTooltip:AddLine(self.hint, 0.6, 0.6, 0.62, true) end
        GameTooltip:Show()
    end)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    t:SetScript("OnClick", function(self, button)
        if UI().HandleModifiedItemClick and UI():HandleModifiedItemClick(self.itemID) then return end
        RUI:ClickItem(self.itemID, button)
    end)
    p.tiles[i] = t
    return t
end

local function Dot(t, k)
    local d = t.dots[k]
    if d then return d end
    d = UI():CreateDot(t, 9, "SUB")
    t.dots[k] = d
    return d
end

function RUI:FillPick()
    local f, p = win, win.pick
    local R = Res()
    local L = R:Get()
    if not L then
        for _, r in ipairs(p.rail) do r:Hide() end
        for _, t in ipairs(p.tiles) do t:Hide() end
        p.empty:SetText(R:IsHost() and "No reserves yet. Open them from the session crest's drawer, or with the "
            .. "button above." or "Reserves aren't open in this raid.")
        p.empty:Show()
        p.foot:Hide()
        return
    end
    p.empty:Hide()
    p.foot:Show()
    local me = ns.Util.PlayerKey()
    local bosses = R:Bosses(L.rk)
    local byItem = R:ByItem()
    if not st.boss then
        st.boss = bosses[1] and bosses[1].key
        -- (the boss with my picks first)
        for _, b in ipairs(bosses) do
            for _, id in ipairs(b.items) do
                if R:SourceOf(me, id) then st.boss = st.boss and b.key end
            end
        end
    end
    local cur
    for i, b in ipairs(bosses) do
        local r = RailRow(p, i)
        r.key = b.key
        local n = 0
        for _, id in ipairs(b.items) do n = n + #(byItem[id] or {}) end
        local pic = Portrait(L.rk, b.key)
        if pic then
            r.face:SetTexture(pic)
            r.face:SetTexCoord(0.25, 0.75, 0, 1)
        else
            r.face:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")
            r.face:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        r.name:SetText(b.name)
        r.badge:SetCount(n)
        r.badge:SetShown(n > 0)
        r:SetSelected(b.key == st.boss)
        r:Show()
        if b.key == st.boss then cur = b end
    end
    for i = #bosses + 1, #p.rail do p.rail[i]:Hide() end
    p.railFrame:SetHeight(max(1, #bosses * RAIL_ROW))
    for i, b in ipairs(bosses) do
        if b.key == st.boss then
            local top, view = (i - 1) * RAIL_ROW, p.railScroll:GetHeight() or 0
            local now = p.railScroll:GetVerticalScroll() or 0
            if view > 0 and (top < now or top + RAIL_ROW > now + view) then
                p.railScroll:SetVerticalScroll(max(0, min(top - RAIL_ROW, #bosses * RAIL_ROW - view)))
            end
        end
    end
    cur = cur or bosses[1]
    -- the items: gear first (patterns and the like after), guild items last
    local items = {}
    for _, id in ipairs(cur and cur.items or {}) do
        if not st.onlyBiS or IsMine(id) then items[#items + 1] = id end
    end
    local colW = floor((p.child:GetWidth() - TILE_GAP) / 2)
    local y = 0
    for i, id in ipairs(items) do
        local t = Tile(p, i)
        t.itemID = id
        local col = (i - 1) % 2
        if col == 0 and i > 1 then y = y + TILE_H + TILE_GAP end
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", p.child, "TOPLEFT", col * (colW + TILE_GAP), -y)
        t:SetWidth(colW)
        t.icon:SetTexture(UI():ItemIcon(id))
        t.name:SetText(ItemName(id))
        local keys = byItem[id] or {}
        local held = R:IsHeld(id)
        local dotsW = (held or #keys == 0) and 4 or (min(#keys, 6) * 7 + 12)
        t.name:SetWidth(colW - ICON - 18 - dotsW)
        t.line:SetWidth(colW - ICON - 18 - dotsW)
        local mine = R:SourceOf(me, id) ~= nil
        local bis = IsMine(id)
        local line
        if held then
            line = S:Wrap("WARN", "Held for the guild")
        elseif mine then
            line = S:Wrap("GOLD", "Your reserve") .. (#keys > 1 and S:Wrap("SUB", (" · %d more"):format(#keys - 1)) or "")
        elseif #keys > 0 then
            line = ("%d reserved"):format(#keys)
        else
            line = S:Wrap("DIM", "nobody yet")
        end
        if bis then line = line .. S:Wrap("SUB", " · ") .. S:Wrap("GOLD", bis.os and "your OS list" or "your BiS list") end
        t.line:SetText(line)
        t.icon:SetDesaturated(held and not st.holdMode)
        t:SetAlpha((held and not st.holdMode) and 0.55 or 1)
        if mine then
            UI():SetEdgeColor(t, S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], 0.9)
        elseif held and st.holdMode then
            UI():SetEdgeColor(t, S.C.WARN[1], S.C.WARN[2], S.C.WARN[3], 0.8)
        else
            UI():SetEdgeColor(t, S:Color("EDGE_QUIET"))
        end
        for k, d in ipairs(t.dots) do d:Hide() end
        if not held then
            for k = 1, min(#keys, 6) do
                local d = Dot(t, k)
                local cls = UI():ClassOf(keys[k])
                local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
                if c then d:SetVertexColor(c.r, c.g, c.b, 1) else d:SetVertexColor(0.6, 0.6, 0.62, 1) end
                d:ClearAllPoints()
                d:SetPoint("RIGHT", t, "RIGHT", -8 - (k - 1) * 7, 0)
                d:Show()
            end
        end
        if st.holdMode then
            t.hint = held and "Click: no longer held for the guild." or "Click: hold it for the guild."
        elseif L.foreign then
            t.hint = "Reserves run in LootReserve tonight: reserve there."
        elseif held then
            t.hint = nil
        elseif mine then
            t.hint = L.o and "Click: take your reserve back." or "Reserves are closed."
        else
            t.hint = L.o and (R:Left(me) > 0 and "Click: reserve it." or "You have no reserves left: take one back first.")
                or "Reserves are closed."
        end
        t:Show()
    end
    for i = #items + 1, #p.tiles do p.tiles[i]:Hide() end
    p.child:SetHeight(max(1, y + TILE_H))
    -- the foot
    local foot = p.foot
    for _, s in ipairs(foot.slots) do s:Hide() end
    local x = (foot.label:GetStringWidth() or 80) + 12
    local mineList = R:Of(me)
    for k = 1, max(L.n or 1, #mineList) do
        local s = foot.slots[k]
        if not s then
            s = CreateFrame("Button", nil, foot)
            s:SetHeight(30)
            s.bg = UI():Fill(s, S:WithAlpha("GOLD", 0.06), "BACKGROUND")
            UI():AddEdges(s, "BORDER")
            s.icon = s:CreateTexture(nil, "ARTWORK")
            s.icon:SetSize(22, 22)
            s.icon:SetPoint("LEFT", 4, 0)
            s.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            s.text = UI():Text(s, "body")
            s.text:SetPoint("LEFT", 32, 0)
            s:SetScript("OnClick", function(self) if self.itemID then RUI:ClickItem(self.itemID) end end)
            s:SetScript("OnEnter", function(self)
                if not self.itemID then return end
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID) end
                GameTooltip:AddLine("Click: take it back.", 0.6, 0.6, 0.62)
                GameTooltip:Show()
            end)
            s:SetScript("OnLeave", function() GameTooltip:Hide() end)
            foot.slots[k] = s
        end
        local id = mineList[k]
        s.itemID = id
        if id then
            s.icon:SetTexture(UI():ItemIcon(id))
            s.icon:Show()
            s.text:SetText(ItemName(id))
            s.text:SetPoint("LEFT", 32, 0)
            s.bg:Show()
            UI():SetEdgeColor(s, S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], 0.6)
        else
            s.icon:Hide()
            s.text:SetText(S:Wrap("DIM", "pick one"))
            s.text:SetPoint("LEFT", 10, 0)
            s.bg:Hide()
            UI():SetEdgeColor(s, 0.5, 0.5, 0.55, 0.45)
        end
        local w = min(200, floor((s.text:GetStringWidth() or 60) + (id and 44 or 22)))
        s:SetWidth(w)
        s:ClearAllPoints()
        s:SetPoint("LEFT", foot, "LEFT", x, -2)
        x = x + w + 6
        s:Show()
    end
    foot.note:SetText(L.o and (R:Left(me) > 0 and ("%d left · closes at the first pull"):format(R:Left(me))
        or "closes at the first pull") or "closed")
end

-- A tile clicked: reserve / take back (the host's Guild items mode: hold / free).
function RUI:ClickItem(itemID, button)
    local R = Res()
    if st.holdMode and R:IsHost() then
        R:ToggleHeld(itemID)
        return
    end
    local me = ns.Util.PlayerKey()
    local ok, code
    if R:SourceOf(me, itemID) then
        ok, code = R:Cancel(itemID)
    else
        ok, code = R:Reserve(itemID)
    end
    if not ok then
        local t = R.CODE_TEXT[code] or "That didn't work."
        if t:find("^%l") then t = ItemName(itemID) .. " " .. t end
        ns:Print("%s", t)
    end
end

function RUI:ToggleHoldMode()
    if not Res():IsHost() then return end
    st.holdMode = not st.holdMode
    if st.holdMode then st.view = "pick" end
    self:Refresh()
end

---------------------------------------------------------------------------
-- Reserves: the list
---------------------------------------------------------------------------
function Build.List(f)
    local p = CreateFrame("Frame", nil, f.body)
    p:SetAllPoints(f.body)
    f.list = p
    local scroll = UI():CreateScrollFrame(p, "DisasterZoneReservesList")
    scroll:SetPoint("TOPLEFT", 0, -20)
    scroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -(SIDE_W + 22), 0)
    scroll.scrollBarHideable = true
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CONTENT_W - 2 * S.PAD - SIDE_W - 22, 1)
    scroll:SetScrollChild(child)
    p.scroll, p.child, p.rows = scroll, child, {}
    p.head = UI():CreateColumnHeader(p, 18)
    p.head:SetPoint("TOPLEFT", 0, 0)
    p.head:SetPoint("TOPRIGHT", p, "TOPRIGHT", -(SIDE_W + 22), 0)
    p.head:AddColumn("Item", 38)
    p.head:AddColumn("Reserved by", 236)
    -- the side: the count by source, who hasn't reserved, the heads-up
    local side = CreateFrame("Frame", nil, p)
    side:SetPoint("TOPRIGHT", 0, 0)
    side:SetPoint("BOTTOMRIGHT", 0, 0)
    side:SetWidth(SIDE_W)
    p.side = side
    side.count = UI():CreateCard(side, { title = "Reserved" })
    side.count:SetPoint("TOPLEFT", 0, 0)
    side.count:SetPoint("TOPRIGHT", 0, 0)
    side.count:SetHeight(134)
    side.count.lines = {}
    for k = 1, 6 do
        local fs = UI():Text(side.count, k == 1 and "body" or "small", k == 1 and "TEXT" or "SUB")
        fs:SetPoint("TOPLEFT", side.count, "TOPLEFT", S.IN, -(30 + (k - 1) * 16))
        fs:SetWidth(SIDE_W - 2 * S.IN)
        fs:SetJustifyH("LEFT")
        side.count.lines[k] = fs
    end
    side.missing = UI():CreateCard(side, { title = "Still to pick" })
    side.missing:SetPoint("TOPLEFT", side.count, "BOTTOMLEFT", 0, -S.GAP)
    side.missing:SetPoint("TOPRIGHT", side.count, "BOTTOMRIGHT", 0, -S.GAP)
    side.missing:SetHeight(132)
    side.missing.text = UI():Text(side.missing, "body")
    side.missing.text:SetPoint("TOPLEFT", side.missing, "TOPLEFT", S.IN, -30)
    side.missing.text:SetWidth(SIDE_W - 2 * S.IN)
    side.missing.text:SetWordWrap(true)
    side.missing.text:SetJustifyH("LEFT")
    side.missing.btn = UI():CreateSleekButton(side.missing, "Whisper them", 104, S.BTN_H - 2, function()
        local n = ns.ReserveChat:NudgeMissing()
        ns:Print("Whispered %d player%s who still have reserves to pick.", n, n == 1 and "" or "s")
    end)
    side.missing.btn:SetPoint("BOTTOMRIGHT", -S.IN, S.IN)
    side.heads = UI():CreateCard(side, { title = "Heads-up" })
    side.heads:SetPoint("TOPLEFT", side.missing, "BOTTOMLEFT", 0, -S.GAP)
    side.heads:SetPoint("TOPRIGHT", side.missing, "BOTTOMRIGHT", 0, -S.GAP)
    side.heads:SetHeight(90)
    side.heads.text = UI():Text(side.heads, "small", "SUB")
    side.heads.text:SetPoint("TOPLEFT", side.heads, "TOPLEFT", S.IN, -30)
    side.heads.text:SetWidth(SIDE_W - 2 * S.IN)
    side.heads.text:SetWordWrap(true)
    side.heads.text:SetJustifyH("LEFT")
    p.empty = UI():Text(p, "body", "SUB")
    p.empty:SetPoint("TOP", scroll, "TOP", 0, -60)
    p.empty:SetWidth(320)
    p.empty:SetWordWrap(true)
    p.empty:SetJustifyH("CENTER")
end

local function SourceMark(src)
    local t = SRC_TAG[src] or "?"
    local col = ({ d = "GOLD", l = "OK", w = "YOU", s = "TEXT", h = "SUB" })[src] or "SUB"
    return S:Wrap(col, t)
end

local function ListRow(p, i)
    local r = p.rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, p.child)
    r:SetHeight(LIST_ROW)
    UI():DecorateRow(r, { rule = true })
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(28, 28)
    r.icon:SetPoint("LEFT", 2, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.name = UI():Text(r, "body")
    r.name:SetPoint("TOPLEFT", 38, -5)
    r.name:SetWidth(190)
    r.name:SetWordWrap(false)
    r.boss = UI():Text(r, "small", "DIM")
    r.boss:SetPoint("TOPLEFT", 38, -22)
    r.boss:SetWidth(190)
    r.boss:SetWordWrap(false)
    r.who = UI():Text(r, "body")
    r.who:SetPoint("LEFT", 236, 0)
    r.who:SetJustifyH("LEFT")
    r.who:SetWordWrap(true)
    r.n = UI():Text(r, "num")
    r.n:SetPoint("RIGHT", -6, 0)
    r:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" and self.itemID then RUI:RowMenu(self) end
    end)
    r:SetScript("OnEnter", function(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID) end
        if Res():IsHost() and #Res():Reservers(self.itemID) > 0 then
            GameTooltip:AddLine("Right-click: take a reserve back.", 0.6, 0.6, 0.62)
        end
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p.rows[i] = r
    return r
end

function RUI:FillList()
    local p = win.list
    local R = Res()
    local L = R:Get()
    if not L then
        for _, r in ipairs(p.rows) do r:Hide() end
        p.side:Hide()
        p.empty:SetText("Reserves aren't open in this raid.")
        p.empty:Show()
        return
    end
    p.empty:Hide()
    p.side:Show()
    local byItem = R:ByItem()
    local loot = R:RaidLoot(L.rk)
    local ids = {}
    for id in pairs(byItem) do ids[#ids + 1] = id end
    tsort(ids, function(a, b)
        local na, nb = #byItem[a], #byItem[b]
        if na ~= nb then return na > nb end
        return a < b
    end)
    for _, id in ipairs(L.h or {}) do ids[#ids + 1] = id end
    local w = p.child:GetWidth()
    local DB = ns.ItemDB
    for i, id in ipairs(ids) do
        local r = ListRow(p, i)
        r.itemID = id
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p.child, "TOPLEFT", 0, -(i - 1) * LIST_ROW)
        r:SetWidth(w)
        r.icon:SetTexture(UI():ItemIcon(id))
        r.name:SetText(ItemName(id))
        local bk = loot[id]
        local ref = bk and DB and DB.GetBossRef and DB:GetBossRef(L.rk .. ":" .. bk)
        r.boss:SetText(type(ref) == "table" and ref.boss and ref.boss.name or (bk or ""))
        r.who:SetWidth(w - 236 - 34)
        if R:IsHeld(id) and not byItem[id] then
            r.who:SetText(S:Wrap("WARN", "Held for the guild") .. S:Wrap("SUB", " · the loot council decides"))
            r.n:SetText(S:Wrap("WARN", "HR"))
        else
            local parts = {}
            for _, key in ipairs(byItem[id] or {}) do
                parts[#parts + 1] = SourceMark(R:SourceOf(key, id)) .. " " .. Name(key) .. UI():GuestTag(key)
            end
            r.who:SetText(tconcat(parts, "   "))
            local n = #(byItem[id] or {})
            r.n:SetText(n > 2 and S:Wrap("WARN", n) or n)
        end
        r:Show()
    end
    for i = #ids + 1, #p.rows do p.rows[i]:Hide() end
    p.child:SetHeight(max(1, #ids * LIST_ROW))
    if #ids == 0 then
        p.empty:SetText("Nobody has reserved anything yet.")
        p.empty:Show()
    end
    -- the side
    local counts, total = R:SourceCounts()
    local missing, done, size = R:Missing()
    local cl = p.side.count.lines
    cl[1]:SetText(("%d of %d players  ·  %d reserves"):format(done, size, total))
    cl[2]:SetText(SourceMark("d") .. "  DisasterZone  " .. counts.d)
    cl[3]:SetText(SourceMark("l") .. "  LootReserve  " .. counts.l)
    cl[4]:SetText(SourceMark("w") .. "  Whisper !sr  " .. counts.w)
    cl[5]:SetText(SourceMark("s") .. "  Imported  " .. counts.s)
    cl[6]:SetText(counts.h > 0 and (SourceMark("h") .. "  Set by the leader  " .. counts.h) or "")
    local names = {}
    for k, key in ipairs(missing) do
        if k > 12 then
            names[#names + 1] = ("%d more"):format(#missing - 12)
            break
        end
        names[#names + 1] = Name(key)
    end
    p.side.missing.text:SetText(#names > 0 and tconcat(names, ", ") or S:Wrap("OK", "Everyone has picked."))
    p.side.missing.btn:SetShown(R:IsHost() and #missing > 0 and L.o and true or false)
    -- heads-up: blacklisted players with a reserve, a second LootReserve host
    local heads = {}
    local RP = ns.RaidPlan
    for key in pairs(L.r or {}) do
        local e = RP and RP.GetBlacklistEntry and RP:GetBlacklistEntry(key)
        if e then heads[#heads + 1] = Name(key) .. " is on the blacklist" .. (e.reason and (": " .. e.reason) or "") end
    end
    local fh = ns.ReserveLR and ns.ReserveLR.ForeignHost and ns.ReserveLR.ForeignHost()
    if fh and R:IsHost() then heads[#heads + 1] = Name(fh) .. " runs LootReserve too: its players see theirs." end
    p.side.heads.text:SetText(#heads > 0 and tconcat(heads, "\n") or S:Wrap("DIM", "Nothing to watch out for."))
end

function RUI:RowMenu(row)
    local R = Res()
    if not R:IsHost() then return end
    local id = row.itemID
    UI():ContextMenu(row, function(root)
        root:CreateTitle(ItemName(id))
        for _, key in ipairs(R:Reservers(id)) do
            root:CreateButton("Take back " .. Name(key) .. "'s reserve", function() R:CancelFor(key, id, true) end)
        end
        root:CreateDivider()
        root:CreateButton(R:IsHeld(id) and "No longer held for the guild" or "Hold it for the guild",
            function() R:ToggleHeld(id) end)
    end)
end

---------------------------------------------------------------------------
-- Wrap-up
---------------------------------------------------------------------------
function Build.Wrap(f)
    local p = CreateFrame("Frame", nil, f.body)
    p:SetAllPoints(f.body)
    f.wrap = p
    local scroll = UI():CreateScrollFrame(p, "DisasterZoneReservesWrap")
    scroll:SetPoint("TOPLEFT", 0, -20)
    scroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -12, FOOT_H)
    scroll.scrollBarHideable = true
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CONTENT_W - 2 * S.PAD - 12, 1)
    scroll:SetScrollChild(child)
    p.scroll, p.child, p.rows = scroll, child, {}
    p.head = UI():CreateColumnHeader(p, 18)
    p.head:SetPoint("TOPLEFT", 0, 0)
    p.head:SetPoint("TOPRIGHT", -12, 0)
    for _, c in ipairs({ { "Item", 38 }, { "Reserved by", 250 }, { "Went to", 470 }, { "How", 610 } }) do
        p.head:AddColumn(c[1], c[2])
    end
    local foot = CreateFrame("Frame", nil, p)
    foot:SetPoint("BOTTOMLEFT", 0, 0)
    foot:SetPoint("BOTTOMRIGHT", 0, 0)
    foot:SetHeight(FOOT_H)
    UI():Rule(foot, { top = 0 })
    local x = 0
    foot.btns = {}
    for _, b in ipairs({ { "Post to raid", function() RUI:PostWrap() end },
                         { "softres.it CSV", function() RUI:ShowExport("csv") end },
                         { "LootReserve", function() RUI:ShowExport("lootreserve") end },
                         { "Gargul", function() RUI:ShowExport("gargul") end } }) do
        local btn = UI():CreateSleekButton(foot, b[1], 0, S.BTN_H, b[2])
        local w = floor((btn:GetFontString():GetStringWidth() or 60) + 26)
        btn:SetWidth(w)
        btn:SetPoint("LEFT", foot, "LEFT", x, -2)
        x = x + w + 6
        foot.btns[#foot.btns + 1] = btn
    end
    p.foot = foot
    p.empty = UI():Text(p, "body", "SUB")
    p.empty:SetPoint("TOP", scroll, "TOP", 0, -60)
    p.empty:SetWidth(360)
    p.empty:SetWordWrap(true)
    p.empty:SetJustifyH("CENTER")
end

function RUI:FillWrap()
    local p = win.wrap
    local rows = ns.ReserveIO:WrapUp()
    local w = p.child:GetWidth()
    for i, row in ipairs(rows) do
        local r = p.rows[i]
        if not r then
            r = CreateFrame("Frame", nil, p.child)
            r:SetHeight(LIST_ROW)
            UI():DecorateRow(r, { rule = true })
            r.icon = r:CreateTexture(nil, "ARTWORK")
            r.icon:SetSize(28, 28)
            r.icon:SetPoint("LEFT", 2, 0)
            r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            r.name = UI():Text(r, "body")
            r.name:SetPoint("LEFT", 38, 0)
            r.name:SetWidth(200)
            r.name:SetWordWrap(false)
            r.res = UI():Text(r, "small", "SUB")
            r.res:SetPoint("LEFT", 250, 0)
            r.res:SetWidth(210)
            r.res:SetWordWrap(false)
            r.to = UI():Text(r, "body")
            r.to:SetPoint("LEFT", 470, 0)
            r.to:SetWidth(134)
            r.to:SetWordWrap(false)
            r.how = UI():Text(r, "small", "SUB")
            r.how:SetPoint("LEFT", 610, 0)
            p.rows[i] = r
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p.child, "TOPLEFT", 0, -(i - 1) * LIST_ROW)
        r:SetWidth(w)
        r.icon:SetTexture(UI():ItemIcon(row.itemID))
        r.name:SetText(ItemName(row.itemID))
        local names = {}
        for k, key in ipairs(row.reservers) do names[k] = ns.Util.ShortName(key) end
        r.res:SetText(row.kind == "g" and "Held for the guild" or (#names > 0 and tconcat(names, ", ") or "Nobody"))
        r.to:SetText(row.winner and (Name(row.winner) .. (row.roll and S:Wrap("SUB", " " .. row.roll) or ""))
            or S:Wrap("DIM", row.state == "awarded" and "?" or "not yet"))
        r.how:SetText(row.how)
        r:Show()
    end
    for i = #rows + 1, #p.rows do p.rows[i]:Hide() end
    p.child:SetHeight(max(1, #rows * LIST_ROW))
    p.empty:SetShown(#rows == 0)
    p.empty:SetText("No loot has been rolled by reserves yet.")
end

function RUI:PostWrap()
    local Chat = ns.ReserveChat
    for _, line in ipairs(ns.ReserveIO:WrapUpLines()) do Chat:Announce(line) end
end

---------------------------------------------------------------------------
-- Import / export / the ··· menu
---------------------------------------------------------------------------
function RUI:ShowImport()
    if not Res():IsHost() then return end
    ns.Popup:Prompt({
        key = "RESERVES_IMPORT",
        title = "Import reserves",
        text = "Paste a softres.it export (CSV or the Gargul string), LootReserve's CSV or Gargul's CSV.",
        multiline = true, multiHeight = 180, width = 560, ok = "Import",
        onAccept = function(v)
            local ok, summary = ns.ReserveIO:Import(v)
            ns:Print("%s", ok and ("Reserves: " .. summary) or ("Reserves: " .. tostring(summary)))
        end,
    })
end

function RUI:ShowExport(format)
    local text = ns.ReserveIO:Export(format)
    local what = ({ csv = "softres.it CSV", lootreserve = "LootReserve CSV", gargul = "Gargul string" })[format] or "CSV"
    ns.Popup:Prompt({
        key = "RESERVES_EXPORT",
        title = "Export reserves · " .. what,
        text = "Ctrl+C copies it.",
        multiline = true, multiHeight = 180, width = 560, ok = "Done", default = text,
        onAccept = function() end,
    })
end

function RUI:MoreMenu(root)
    local R = Res()
    local L = R:Get()
    local host = R:IsHost()
    if host then
        root:CreateButton("Import", function() RUI:ShowImport() end)
    end
    root:CreateButton("Try the demo", function() if ns.ReserveDemo then ns.ReserveDemo:Start() end end)
    local ex = root:CreateButton("Export")
    ex:CreateButton("softres.it CSV", function() RUI:ShowExport("csv") end)
    ex:CreateButton("LootReserve CSV", function() RUI:ShowExport("lootreserve") end)
    ex:CreateButton("Gargul string", function() RUI:ShowExport("gargul") end)
    if host and L then
        root:CreateDivider()
        root:CreateButton("Post the rules", function() ns.ReserveChat:AnnounceRules() end)
        root:CreateButton("Post the list", function()
            for _, line in ipairs(ns.ReserveIO:ChatLines()) do ns.ReserveChat:Announce(line) end
        end)
        root:CreateButton("Whisper who hasn't picked", function() ns.ReserveChat:NudgeMissing() end)
        root:CreateDivider()
        if L.o then
            root:CreateButton("Close reserves", function() R:Close(); ns.ReserveChat:AnnounceClosed() end)
        else
            root:CreateButton("Reopen reserves", function() R:Open({}) end)
        end
        root:CreateButton(S:Wrap("BAD", "Clear reserves"), function()
            ns.Popup:Confirm({ key = "RESERVES_CLEAR", title = "Clear the reserves?",
                text = "Every reserve in this raid is thrown away, for everyone.", ok = "Clear", danger = true,
                onAccept = function() R:Clear() end })
        end)
    end
end

---------------------------------------------------------------------------
-- Showing
---------------------------------------------------------------------------
local refreshPending = false
function RUI:RequestRefresh()
    if refreshPending or not (win and win:IsShown()) then return end
    refreshPending = true
    ns.Util.After(0.1, function()
        refreshPending = false
        RUI:Refresh()
    end)
end

function RUI:Refresh()
    if not (win and win:IsShown()) then return end
    local R = Res()
    local L = R:Get()
    local ly = win.layout
    local ban = ly.banner
    ban:SetArt(L and L.rk or nil)
    ban:SetTitle(L and RaidName(L.rk) or "Reserves")
    ban:SetSub(self:RulesLine(L))
    ban:SetKicker(st.holdMode and "Guild items · click to hold" or "Loot reserves")
    local host = R:IsHost()
    local bar = ly.toolbar
    local missing, done, size = R:Missing()
    bar:SetTabCount("list", L and done or nil)
    win.holdBtn:SetShown(host and L ~= nil and not (L and L.foreign))
    if win.holdBtn.SetKind then win.holdBtn:SetKind(st.holdMode and "chosen" or "secondary") end
    -- the one main action
    if host and not L then
        bar:SetPrimary({ text = "Open reserves", width = 110, onClick = function() RUI:OpenReserves() end })
    elseif host and L and not L.foreign and st.view == "list" then
        bar:SetPrimary({ text = "Post the rules", width = 110, onClick = function() ns.ReserveChat:AnnounceRules() end })
    elseif st.view == "pick" and L then
        bar:SetPrimary({ text = st.onlyBiS and "All items" or "My BiS only", width = 100,
            onClick = function() st.onlyBiS = not st.onlyBiS; RUI:Refresh() end, kind = "secondary" })
    else
        bar:SetPrimary(nil)
    end
    win.pick:SetShown(st.view == "pick")
    win.list:SetShown(st.view == "list")
    win.wrap:SetShown(st.view == "wrap")
    if st.view == "pick" then self:FillPick() elseif st.view == "list" then self:FillList() else self:FillWrap() end
end

-- The host's Open reserves (the raid's guess, 1 per player for a 10, 2 for a 25).
function RUI:OpenReserves()
    local R = Res()
    local ok, err = R:Open({})
    if not ok then
        ns:Print("Reserves: %s", tostring(err))
        return false
    end
    ns.ReserveChat:AnnounceRules()
    self:Show("list")
    return true
end

-- Opens the window at view ("pick" | "list" | "wrap"; default: the host's list, everyone else's picks).
function RUI:Show(view)
    local f = win or Build.Window()
    st.view = view or (Res():IsHost() and Res():Get() and "list" or "pick")
    if st.view ~= "pick" then st.holdMode = false end
    f.layout.toolbar:SelectTab(st.view)
    f:Show()
    if f.Raise then f:Raise() end
    self:Refresh()
    return f
end

function RUI:Toggle(view)
    if win and win:IsShown() and (view == nil or view == st.view) then
        win:Hide()
        return
    end
    self:Show(view)
end

function RUI:GetFrame() return win end
function RUI:GetState() return st end

---------------------------------------------------------------------------
-- The demo's panel (Core/ReserveDemo.lua): the step, what it shows, Back / Next, whose eyes, and the chat a pug reads
---------------------------------------------------------------------------
local DEMO_W, DEMO_H, CHAT_LINES = 400, 330, 8
local CHAT_COLOR = { rw = "ff4809", raid = "ff7f00", to = "ff80ff", from = "ff80ff", sys = "ffff00" }
local demoPanel

local function DemoPanel()
    if demoPanel then return demoPanel end
    local u = UI()
    local f = u:CreateHudFrame("DisasterZoneReserveDemo", { width = DEMO_W, height = DEMO_H, look = "card",
        strata = "HIGH", toplevel = true, position = false })
    f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -40, -170)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f.kicker = u:Text(f, "caps", "GOLD")
    f.kicker:SetPoint("TOPLEFT", S.PAD + 2, -S.PAD)
    f.close = u:CreateCloseButton(f)
    f.close:SetPoint("TOPRIGHT", -4, -4)
    f.close:SetScript("OnClick", function() ns.ReserveDemo:Stop() end)
    f.title = u:Text(f, "title")
    f.title:SetPoint("TOPLEFT", S.PAD + 2, -S.PAD - 18)
    f.text = u:Text(f, "body", "SUB")
    f.text:SetPoint("TOPLEFT", S.PAD + 2, -S.PAD - 42)
    f.text:SetWidth(DEMO_W - 2 * S.PAD - 4)
    f.text:SetWordWrap(true)
    f.text:SetJustifyH("LEFT")
    f.views = {}
    local x = S.PAD + 2
    for i, v in ipairs(ns.ReserveDemo.VIEWS) do
        local b = u:CreateSleekButton(f, v[2], 0, S.BTN_H - 2, function() ns.ReserveDemo:SetView(v[1]) end)
        local w = floor((b:GetFontString():GetStringWidth() or 60) + 24)
        b:SetWidth(w)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -S.PAD - 116)
        b.view = v[1]
        x = x + w + 4
        f.views[i] = b
    end
    f.chat = CreateFrame("Frame", nil, f)
    f.chat:SetPoint("TOPLEFT", S.PAD, -S.PAD - 146)
    f.chat:SetPoint("TOPRIGHT", -S.PAD, -S.PAD - 146)
    f.chat:SetHeight(CHAT_LINES * 15 + 24)
    u:Fill(f.chat, "INSET", "BACKGROUND")
    f.chat.head = u:Text(f.chat, "caps", "DIM", { text = "What a pug reads in chat" })
    f.chat.head:SetPoint("TOPLEFT", 6, -5)
    f.chat.lines = {}
    for k = 1, CHAT_LINES do
        local fs = f.chat:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
        fs:SetPoint("TOPLEFT", 6, -21 - (k - 1) * 15)
        fs:SetWidth(DEMO_W - 2 * S.PAD - 12)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        f.chat.lines[k] = fs
    end
    f.back = u:CreateSleekButton(f, "Back", 70, S.BTN_H, function() ns.ReserveDemo:Back() end)
    f.back:SetPoint("BOTTOMLEFT", S.PAD, S.PAD)
    f.next = u:CreateSleekButton(f, "Next", 90, S.BTN_H, function()
        local d = ns.ReserveDemo:GetState()
        if d.step >= #ns.ReserveDemo.STEPS then ns.ReserveDemo:Stop() else ns.ReserveDemo:Next() end
    end, "primary")
    f.next:SetPoint("BOTTOMRIGHT", -S.PAD, S.PAD)
    f.hint = u:Text(f, "small", "DIM")
    f.hint:SetPoint("LEFT", f.back, "RIGHT", 10, 0)
    f.hint:SetPoint("RIGHT", f.next, "LEFT", -10, 0)
    f.hint:SetJustifyH("CENTER")
    f:Hide()
    demoPanel = f
    return f
end

-- Opens what the step's person has on their screen.
local function ShowDemoView(d)
    local key = ns.ReserveDemo.STEPS[d.step].key
    local view = d.view
    local DP, SB = ns.DropPanel, ns.SessionBar
    if win then win:Hide() end
    if DP and DP.Hide then DP:Hide() end
    if view == "pug" then return end
    if key == "setup" then
        -- the crest before the start, Reserves picked on its line, the drawer open (the leader's)
        if SB and SB.Demo then
            SB:Demo("idle")
            local p = SB.GetPick and SB:GetPick()
            if not (p and p.reserve) and SB.FlipPick then SB:FlipPick("reserve") end
            if view == "lead" and SB.ToggleDrawer then SB:ToggleDrawer(true) end
        end
    elseif key == "open" then
        if view == "lead" then
            RUI:Show("list")
        else
            local L = Res():Get()
            UI():Toast({ key = "dz-reserves-open", kicker = "Reserves open · by " .. ns.Util.ShortName(L and L.by or "?"),
                title = RaidName(L and L.rk), text = RUI:RulesLine(L), duration = 12,
                buttons = { { text = "Reserve", kind = "primary", onClick = function() RUI:Show("pick") end },
                            { text = "Later", kind = "link" } } })
        end
    elseif key == "reserve" or key == "pull" then
        RUI:Show(view == "lead" and "list" or "pick")
    elseif key == "mine" then
        st.boss = "Vashj"
        RUI:Show("pick")
    elseif key == "drop" then
        if view == "lead" then
            if DP and DP.ShowDrop and d.drop then DP:ShowDrop(d.drop) end
        elseif d.drop and ns.Roll and ns.Roll.StartAll and not d.rolledAll then
            d.rolledAll = true
            ns.Roll:StartAll(d.drop)
        end
    elseif key == "wrap" then
        RUI:Show("wrap")
    end
end

function RUI:RefreshDemo(n)
    local RD = ns.ReserveDemo
    if not (RD and RD:IsRunning()) or n == 0 then
        if demoPanel and demoPanel:IsShown() then
            demoPanel:Hide()
            demoPanel.lastStep = nil
            local SB = ns.SessionBar
            if SB and SB.Demo then pcall(SB.Demo, SB, "off") end
        end
        return
    end
    local f = DemoPanel()
    local d = RD:GetState()
    local step = RD.STEPS[d.step]
    f.kicker:SetText(("Reserves demo · step %d of %d"):format(d.step, #RD.STEPS))
    f.title:SetText(step.title)
    f.text:SetText(step.text)
    for _, b in ipairs(f.views) do
        if b.SetKind then b:SetKind(b.view == d.view and "chosen" or "secondary") end
    end
    local lines = RD:Lines()
    local first = max(1, #lines - CHAT_LINES + 1)
    local L = Res():Get()
    local lead = ns.Util.ShortName((L and L.by) or ns.Util.PlayerKey() or "?")
    for k = 1, CHAT_LINES do
        local e = lines[first + k - 1]
        local fs = f.chat.lines[k]
        if e then
            local pre = ({ rw = "[Raid Warning] [" .. lead .. "]: ", raid = "[Raid] ", to = "To [" .. lead .. "]: ",
                           from = "[" .. lead .. "] whispers: ", sys = "" })[e.kind] or ""
            fs:SetText("|cff" .. (CHAT_COLOR[e.kind] or "ffffff") .. pre .. e.text .. "|r")
        else
            fs:SetText("")
        end
    end
    f.back:SetEnabled(d.step > 1)
    f.next:SetText(d.step >= #RD.STEPS and "Done" or "Next")
    f.hint:SetText(d.view == "pug" and "A pug without any addon: chat only"
        or (d.view == "raider" and "A raider with DisasterZone" or "You, running the raid"))
    f:Show()
    if f.lastStep ~= d.step or f.lastView ~= d.view then
        f.lastStep, f.lastView = d.step, d.view
        ShowDemoView(d)
    end
end

---------------------------------------------------------------------------
-- The raider's pop-up when reserves open, /dz reserves
---------------------------------------------------------------------------
local toasted = {}
local function MaybeToast(L)
    if not (L and L.o) or toasted[L.id] or Res():IsHost() or ns.Util.DemoOn() then return end
    toasted[L.id] = true
    local u = UI()
    if not (u and u.Toast) then return end
    local art
    if ns.ItemDB and ns.ItemDB.RaidArt and L.rk then
        local file, l, r, t, b = ns.ItemDB:RaidArt(L.rk, 112, 64)
        if file then art = { file, l, r, t, b } end
    end
    u:Toast({ key = "dz-reserves-open", kicker = "Reserves open · by " .. ns.Util.ShortName(L.by or "?"),
        title = RaidName(L.rk), text = RUI:RulesLine(L), art = art, duration = 20,
        buttons = { { text = "Reserve", kind = "primary", onClick = function() RUI:Show("pick") end },
                    { text = "Later", kind = "link" } } })
end

function RUI:OnInit()
    ns:On("RESERVES_OPENED", function(L) ns.Util.After(1, function() MaybeToast(L) end) end)
    ns:On("RESERVE_DEMO_STEP", function(n) RUI:RefreshDemo(n) end)
    ns:RegisterSlash("reserves", function(arg)
        arg = (arg or ""):lower()
        if arg == "demo" then
            if ns.ReserveDemo then ns.ReserveDemo:Start() end
        elseif arg == "open" then
            RUI:OpenReserves()
        elseif arg == "list" or arg == "wrap" or arg == "pick" then
            RUI:Show(arg)
        elseif arg == "import" then
            RUI:ShowImport()
        else
            RUI:Toggle()
        end
    end, "reserves [open|list|wrap|import|demo]: the loot reserves window")
end
