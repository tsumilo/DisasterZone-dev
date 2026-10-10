if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MeterDetail.lua", ...) then return end -- DisasterZone: meter breakdown + death recap.
-- The window a click on a meter bar opens (the approved mockup, My BiS / My Log look): a banner of the raid's loading
-- screen with the player's class in a gold ring, their spec and the fight; arrows through the players in the mode's
-- order; a chip to switch fights; four stat cards; underline tabs:
--   Abilities  every ability with its share; picking one shows how it hit (hits, crits, glancing, misses with their
--              averages, the biggest hit, the share of all) in a card on the right
--   Targets    damage by enemy (the boss's journal picture, a skull for the rest)       (damage modes only)
--   Over time  the player's damage (or healing) per 5 s against the raid's average     (not for Whole raid)
-- In Deaths mode a click opens the death recap instead: health over the last 10 seconds and every hit and heal that
-- landed, newest first, the killing blow marked; arrows through the fight's deaths.
local addonName, ns = ...

local MD = ns:NewModule("MeterDetail")

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local pairs, ipairs, type, tonumber, tostring = pairs, ipairs, type, tonumber, tostring
local strformat = string.format
local tsort = table.sort

local W, H = 780, 586
local BANNER_H = 112
local PAD = 18
local CARD_Y, CARD_H = -BANNER_H - 8, 58
local TABS_Y = CARD_Y - CARD_H - 14
local BODY_Y = TABS_Y - 30
local ROW_H, TROW_H, EROW_H = 46, 52, 32
local DETAIL_W = 300
local CLASS_CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"

-- Raid instance ids -> the Raids page's art keys (RaidPlanUI:RaidArt)
local ART_KEY = { [532] = "kara", [565] = "gruul", [544] = "mag", [548] = "ssc", [550] = "tk", [534] = "hyjal",
                  [564] = "bt", [568] = "za", [580] = "swp" }

local Meter, K, Kit
local frame
local S = { sel = "cur", guid = nil, mode = "damage", tab = "abilities", ab = nil, view = "player", death = nil }

local function C3(c) return c[1], c[2], c[3] end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- "1 hit", "3 hits" (word = the plural)
local function Count(n, word)
    if n == 1 then word = word:gsub("es$", ""):gsub("s$", "") end
    return K.Int(n) .. " " .. word
end

local function Ordinal(n)
    local s = (n % 10 == 1 and n % 100 ~= 11) and "st" or (n % 10 == 2 and n % 100 ~= 12) and "nd"
        or (n % 10 == 3 and n % 100 ~= 13) and "rd" or "th"
    return n .. s
end

local function SpecText(a)
    local cls = a.c and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[a.c] or a.c) or ""
    local spec = a.s and (a.s:gsub(" %((.-)%)", "")) or nil
    if a.s == "Feral (Bear)" then spec = "Guardian" end
    return spec and (spec .. " " .. cls) or cls
end

local function FightText(seg)
    if not seg then return "" end
    local parts = { Meter:SegName(seg) }
    if seg.kind == "boss" and not seg.live then
        parts[#parts + 1] = seg.kill and "|cff45d474Kill|r" or ("|cffff7e6bWipe" .. (seg.pct and strformat(" %d%%", floor(seg.pct + 0.5)) or "") .. "|r")
    elseif seg.live then
        parts[#parts + 1] = "|cffff6a55Live|r"
    end
    parts[#parts + 1] = K.Clock(Meter:Duration(seg))
    return table.concat(parts, " · ")
end

local function JournalArt(name)
    local key = name and ns.MyLog and ns.MyLog.BossDataKey and ns.MyLog:BossDataKey(name)
    return key and ns.Data and ns.Data.BossJournal and ns.Data.BossJournal[key]
end

-- The mode's rows (players with something to show), for the arrows and the rank.
local function Ranked(seg, mode)
    local m = (mode == "dps") and "damage" or mode
    if m == "deaths" or m == "active" then m = "damage" end
    local rows = Meter:Rows(seg, m)
    return rows, m
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

local function Text(parent, size, c, font)
    local fs = K.Font(parent, font or K.FRIZ, size, c)
    fs:SetJustifyH("LEFT")
    return fs
end

local function NewCard(parent)
    local c = Kit.Card(parent, { 0.102, 0.102, 0.122 }, 0.07)
    c:SetHeight(CARD_H)
    c.icon = Kit.Icon(c, 34)
    c.icon:SetPoint("LEFT", c, "LEFT", 12, 0)
    c.num = Text(c, 20, { 1, 1, 1 })
    c.num:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 11, 1)
    c.extra = Text(c, 13, K.GREEN)
    c.extra:SetPoint("BOTTOMLEFT", c.num, "BOTTOMRIGHT", 6, 1)
    c.lab = Text(c, 12.5, K.DIM)
    c.lab:SetPoint("BOTTOMLEFT", c.icon, "BOTTOMRIGHT", 11, 0)
    return c
end

local function Build()
    K, Kit = ns.MeterWindow.K, ns.MyLogKit
    frame = CreateFrame("Frame", "DisasterZoneMeterDetail", UIParent)
    frame:SetSize(W, H)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    if UISpecialFrames then tinsert(UISpecialFrames, "DisasterZoneMeterDetail") end
    K.Panel(frame, 0.98)
    frame.fill:SetVertexColor(0.078, 0.078, 0.09, 0.98)
    frame:SetEdge(0.24, 0.24, 0.27, 1)

    -- banner
    local banner = CreateFrame("Button", nil, frame)
    banner:SetPoint("TOPLEFT", 1, -1)
    banner:SetPoint("TOPRIGHT", -1, -1)
    banner:SetHeight(BANNER_H)
    banner:RegisterForDrag("LeftButton")
    banner:SetScript("OnDragStart", function() frame:StartMoving() end)
    banner:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    if banner.SetClipsChildren then banner:SetClipsChildren(true) end
    banner.art = banner:CreateTexture(nil, "BACKGROUND", nil, -8)
    banner.art:SetAllPoints()
    banner.shade = banner:CreateTexture(nil, "BACKGROUND", nil, -6)
    banner.shade:SetAllPoints()
    K.Gradient(banner.shade, "HORIZONTAL", { 0.055, 0.055, 0.067, 0.96 }, { 0.055, 0.055, 0.067, 0.2 })
    banner.fade = banner:CreateTexture(nil, "BACKGROUND", nil, -5)
    banner.fade:SetPoint("BOTTOMLEFT")
    banner.fade:SetPoint("BOTTOMRIGHT")
    banner.fade:SetHeight(56)
    K.Gradient(banner.fade, "VERTICAL", { 0.078, 0.078, 0.09, 1 }, { 0.078, 0.078, 0.09, 0 })
    -- the class in a gold ring
    banner.ringGold = K.Tex(banner, "ARTWORK", K.DISC, 0.72, 0.56, 0.17, 1, 1)
    banner.ringGold:SetSize(66, 66)
    banner.ringGold:SetPoint("LEFT", banner, "LEFT", 22, 4)
    banner.ringGap = K.Tex(banner, "ARTWORK", K.DISC, 0, 0, 0, 1, 2)
    banner.ringGap:SetSize(62, 62)
    banner.ringGap:SetPoint("CENTER", banner.ringGold)
    banner.cls = banner:CreateTexture(nil, "ARTWORK", nil, 3)
    banner.cls:SetSize(58, 58)
    banner.cls:SetPoint("CENTER", banner.ringGold)
    banner.name = Text(banner, 24, { 1, 1, 1 })
    banner.name:SetPoint("TOPLEFT", banner.ringGold, "TOPRIGHT", 14, -8)
    banner.sub = Text(banner, 14, K.DIM)
    banner.sub:SetPoint("TOPLEFT", banner.name, "BOTTOMLEFT", 0, -6)
    banner.sub:SetWidth(W - 360)
    -- right: arrows, the fight, close
    local close = CreateFrame("Button", nil, banner, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", banner, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() frame:Hide() end)
    banner.fight = ns.UI:CreateSleekMenuButton(banner, "Void Reaver", 150, function(root) MD:FightMenu(root) end, 28)
    banner.fight:SetPoint("TOPRIGHT", banner, "TOPRIGHT", -40, -16)
    banner.next = ns.UI:CreateArrowButton(banner, true, 28, 28, function() MD:Step(1) end)
    banner.next:SetPoint("RIGHT", banner.fight, "LEFT", -8, 0)
    banner.step = Text(banner, 13, K.INK)
    banner.step:SetPoint("RIGHT", banner.next, "LEFT", -8, 0)
    banner.prev = ns.UI:CreateArrowButton(banner, false, 28, 28, function() MD:Step(-1) end)
    banner.prev:SetPoint("RIGHT", banner.step, "LEFT", -8, 0)
    frame.banner = banner

    -- stat cards
    frame.cards = {}
    local cw = (W - PAD * 2 - 8 * 3) / 4
    for i = 1, 4 do
        local c = NewCard(frame)
        c:SetWidth(cw)
        c:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (i - 1) * (cw + 8), CARD_Y)
        frame.cards[i] = c
    end

    -- tabs
    frame.tabs = Kit.Tabs(frame, { { key = "abilities", label = "Abilities" }, { key = "targets", label = "Targets" },
        { key = "time", label = "Over time" } }, function(key) S.tab = key; MD:Draw() end)
    frame.tabs:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, TABS_Y)
    frame.tabRule = K.Tex(frame, "BORDER", K.WHITE, 1, 1, 1, 0.07)
    frame.tabRule:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, TABS_Y - 24)
    frame.tabRule:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, TABS_Y - 24)
    frame.tabRule:SetHeight(1)
    frame.tabNote = Text(frame, 13, K.DIM)
    frame.tabNote:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, TABS_Y - 4)
    frame.tabNote:SetJustifyH("RIGHT")

    -- body: list (scrolling), detail card, chart
    local listW = W - PAD * 2 - DETAIL_W - 22
    local sf = ns.UI:CreateScrollFrame(frame, nil)
    sf:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, BODY_Y)
    sf:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 14)
    sf:SetWidth(listW)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(listW, 10)
    sf:SetScrollChild(child)
    frame.list, frame.listChild, frame.listW = sf, child, listW
    frame.rows = {}

    local det = Kit.Card(frame, { 0.098, 0.098, 0.118 }, 0.07)
    det:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, BODY_Y)
    det:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 14)
    det:SetWidth(DETAIL_W)
    det.icon = Kit.Icon(det, 40)
    det.icon:SetPoint("TOPLEFT", det, "TOPLEFT", 16, -14)
    det.name = Text(det, 16.5, { 1, 1, 1 })
    det.name:SetPoint("TOPLEFT", det.icon, "TOPRIGHT", 11, -2)
    det.name:SetWidth(DETAIL_W - 90)
    det.sub = Text(det, 13, K.DIM)
    det.sub:SetPoint("TOPLEFT", det.name, "BOTTOMLEFT", 0, -4)
    det.dist = CreateFrame("Frame", nil, det)
    det.dist:SetPoint("TOPLEFT", det, "TOPLEFT", 16, -72)
    det.dist:SetPoint("TOPRIGHT", det, "TOPRIGHT", -16, -72)
    det.dist:SetHeight(10)
    det.parts = {}
    det.head = {}
    local cols = { { "How it hit", 34, "LEFT" }, { "Count", 150, "RIGHT" }, { "Average", 208, "RIGHT" }, { "Share", 268, "RIGHT" } }
    for i, c in ipairs(cols) do
        local fs = Text(det, 12, { 0.43, 0.42, 0.39 })
        if c[3] == "LEFT" then fs:SetPoint("TOPLEFT", det, "TOPLEFT", c[2], -96)
        else fs:SetPoint("TOPRIGHT", det, "TOPLEFT", c[2], -96); fs:SetJustifyH("RIGHT") end
        fs:SetText(c[1])
        det.head[i] = fs
    end
    det.lines = {}
    for i = 1, 5 do
        local y = -116 - (i - 1) * 21
        local ln = { key = K.Tex(det, "ARTWORK", K.WHITE) }
        ln.key:SetSize(9, 9)
        ln.key:SetPoint("TOPLEFT", det, "TOPLEFT", 18, y - 3)
        ln.name = Text(det, 13, K.INK)
        ln.name:SetPoint("TOPLEFT", det, "TOPLEFT", 34, y)
        ln.n = Text(det, 13, K.INK)
        ln.n:SetPoint("TOPRIGHT", det, "TOPLEFT", 150, y)
        ln.avg = Text(det, 13, K.INK)
        ln.avg:SetPoint("TOPRIGHT", det, "TOPLEFT", 208, y)
        ln.share = Text(det, 13, K.INK)
        ln.share:SetPoint("TOPRIGHT", det, "TOPLEFT", 268, y)
        for _, f in ipairs({ ln.n, ln.avg, ln.share }) do f:SetJustifyH("RIGHT") end
        det.lines[i] = ln
    end
    det.facts = {}
    for i = 1, 4 do
        local f = Kit.Card(det, { 0.078, 0.078, 0.094 }, 0.04)
        f:SetSize((DETAIL_W - 32 - 8) / 2, 46)
        local col, rw = (i - 1) % 2, floor((i - 1) / 2)
        f:SetPoint("BOTTOMLEFT", det, "BOTTOMLEFT", 16 + col * ((DETAIL_W - 32 - 8) / 2 + 8), 16 + (1 - rw) * 54)
        f.num = Text(f, 16, { 1, 1, 1 })
        f.num:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -7)
        f.lab = Text(f, 12, K.DIM)
        f.lab:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 7)
        det.facts[i] = f
    end
    frame.det = det

    local chart = Kit.Chart(frame)
    chart:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 46, BODY_Y - 34)
    chart:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 40)
    chart.fallback = { W - PAD * 2 - 46, H + BODY_Y - 34 - 40 }
    frame.chart = chart
    frame.legend = Text(frame, 13, K.DIM)
    frame.legend:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, BODY_Y - 6)
    frame.yLabs, frame.xLabs = {}, {}
    for i = 1, 5 do
        frame.yLabs[i] = Text(frame, 12, { 0.55, 0.54, 0.5 })
        frame.yLabs[i]:SetJustifyH("RIGHT")
        frame.xLabs[i] = Text(frame, 12, { 0.55, 0.54, 0.5 })
    end

    -- death recap
    frame.deathChart = Kit.Chart(frame)
    frame.deathChart:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 4, -BANNER_H - 30)
    frame.deathChart:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD - 4, -BANNER_H - 30)
    frame.deathChart:SetHeight(128)
    frame.deathChart.fallback = { W - PAD * 2 - 8, 128 }
    frame.deathLabs = {}
    for i = 1, 6 do frame.deathLabs[i] = Text(frame, 12, { 0.55, 0.54, 0.5 }) end
    frame.deathHp = Text(frame, 12, { 0.55, 0.54, 0.5 })
    frame.deathHp:SetPoint("BOTTOMRIGHT", frame.deathChart, "TOPRIGHT", 0, 4)
    frame.deathHp:SetJustifyH("RIGHT")
    local esf = ns.UI:CreateScrollFrame(frame, nil)
    esf:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -BANNER_H - 196)
    esf:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD - 10, 14)
    local echild = CreateFrame("Frame", nil, esf)
    echild:SetSize(W - PAD * 2 - 10, 10)
    esf:SetScrollChild(echild)
    frame.events, frame.eventsChild, frame.evRows = esf, echild, {}

    frame.empty = Text(frame, 14, K.DIM)
    frame.empty:SetPoint("TOP", frame, "TOP", 0, BODY_Y - 60)
    frame.empty:SetJustifyH("CENTER")
    frame:Hide()
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function AbilityRow(i)
    local r = frame.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, frame.listChild)
    r:SetHeight(ROW_H)
    r.bg = K.Tex(r, "BACKGROUND", K.WHITE, 1, 1, 1, 0)
    r.bg:SetAllPoints()
    r.bar = K.Tex(r, "ARTWORK", K.WHITE, K.GOLD[1], K.GOLD[2], K.GOLD[3], 1)
    r.bar:SetPoint("TOPLEFT")
    r.bar:SetPoint("BOTTOMLEFT")
    r.bar:SetWidth(2)
    r.rank = Text(r, 13, { 0.43, 0.42, 0.39 })
    r.rank:SetPoint("LEFT", r, "LEFT", 4, 0)
    r.rank:SetWidth(14)
    r.rank:SetJustifyH("RIGHT")
    r.icon = Kit.Icon(r, 32)
    r.icon:SetPoint("LEFT", r, "LEFT", 26, 0)
    r.thumb = r:CreateTexture(nil, "ARTWORK")
    r.thumb:SetSize(76, 40)
    r.thumb:SetPoint("LEFT", r, "LEFT", 6, 0)
    r.name = Text(r, 14.5, { 1, 1, 1 })
    r.sub = Text(r, 12.5, K.DIM)
    r.amount = Text(r, 16.5, { 1, 1, 1 })
    r.amount:SetPoint("TOPRIGHT", r, "TOPRIGHT", -10, -7)
    r.amount:SetJustifyH("RIGHT")
    r.pct = Text(r, 12.5, K.DIM)
    r.pct:SetPoint("TOPRIGHT", r.amount, "BOTTOMRIGHT", 0, -2)
    r.pct:SetJustifyH("RIGHT")
    r.track = K.Tex(r, "ARTWORK", K.WHITE, 0.15, 0.15, 0.18, 1)
    r.track:SetHeight(6)
    r.fill = r:CreateTexture(nil, "ARTWORK", nil, 1)
    r.fill:SetHeight(6)
    K.Gradient(r.fill, "HORIZONTAL", { 0.65, 0.48, 0.07, 1 }, { 1, 0.82, 0, 1 })
    r.fill:SetPoint("LEFT", r.track, "LEFT")
    r:SetScript("OnEnter", function(self) if not self.on then self.bg:SetVertexColor(1, 1, 1, 0.03) end end)
    r:SetScript("OnLeave", function(self) if not self.on then self.bg:SetVertexColor(1, 1, 1, 0) end end)
    r:SetScript("OnClick", function(self) if self.key ~= nil then S.ab = self.key; MD:Draw() end end)
    frame.rows[i] = r
    return r
end

local function PlaceRowText(r, x, w)
    r.name:ClearAllPoints()
    r.name:SetPoint("TOPLEFT", r, "TOPLEFT", x, -7)
    r.name:SetWidth(w)
    r.sub:ClearAllPoints()
    r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
    r.sub:SetWidth(w)
    r.track:ClearAllPoints()
    r.track:SetPoint("LEFT", r, "LEFT", x + w + 12, 0)
    r.track:SetPoint("RIGHT", r, "RIGHT", -96, 0)
end

local function EventRow(i)
    local r = frame.evRows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, frame.eventsChild)
    r:SetHeight(EROW_H)
    r.bg = K.Tex(r, "BACKGROUND", K.WHITE, 1, 1, 1, 0)
    r.bg:SetAllPoints()
    r.mark = K.Tex(r, "ARTWORK", K.WHITE, 1, 0.35, 0.29, 1)
    r.mark:SetPoint("TOPLEFT")
    r.mark:SetPoint("BOTTOMLEFT")
    r.mark:SetWidth(2)
    r.t = Text(r, 13.5, K.DIM)
    r.t:SetPoint("RIGHT", r, "LEFT", 58, 0)
    r.t:SetJustifyH("RIGHT")
    r.icon = Kit.Icon(r, 20)
    r.icon:SetPoint("LEFT", r, "LEFT", 68, 0)
    r.what = Text(r, 13.5, { 1, 1, 1 })
    r.what:SetPoint("LEFT", r.icon, "RIGHT", 10, 0)
    r.what:SetWidth(W - PAD * 2 - 10 - 68 - 30 - 220)
    r.amount = Text(r, 14, K.RED)
    r.amount:SetPoint("RIGHT", r, "RIGHT", -120, 0)
    r.amount:SetJustifyH("RIGHT")
    r.hpTrack = K.Tex(r, "ARTWORK", K.WHITE, 0.16, 0.16, 0.19, 1)
    r.hpTrack:SetSize(64, 5)
    r.hpTrack:SetPoint("RIGHT", r, "RIGHT", -44, 0)
    r.hpFill = r:CreateTexture(nil, "ARTWORK", nil, 1)
    r.hpFill:SetTexture(K.WHITE)
    r.hpFill:SetHeight(5)
    r.hpFill:SetPoint("LEFT", r.hpTrack, "LEFT")
    r.hp = Text(r, 12.5, K.DIM)
    r.hp:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    r.hp:SetJustifyH("RIGHT")
    frame.evRows[i] = r
    return r
end

---------------------------------------------------------------------------
-- Drawing a player
---------------------------------------------------------------------------

local function SetBanner(seg, a)
    local b = frame.banner
    local key = seg and seg.iid and ART_KEY[seg.iid]
    if key and ns.RaidPlanUI and ns.RaidPlanUI.RaidArt then
        local fid, l, r, t, bt = ns.RaidPlanUI:RaidArt(key, W, BANNER_H, 0.62)
        b.art:SetTexture(fid)
        b.art:SetTexCoord(l, r, t, bt)
        b.art:Show()
    else
        b.art:SetTexture("Interface\\Glues\\LoadingScreens\\LoadScreenOutland")
        b.art:SetTexCoord(0, 1, 0.3, 0.3 + BANNER_H / W * 0.75)
    end
    local coords = a and a.c and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[a.c]
    if coords then
        b.cls:SetTexture(CLASS_CIRCLES)
        b.cls:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        b.cls:SetTexture(134400)
    end
    b.name:SetText(a and a.n or "?")
    if a then b.name:SetTextColor(K.ClassColor(a.c)) end
end

local function SetCard(c, icon, num, extra, lab)
    c.icon:SetIcon(icon)
    c.num:SetText(num)
    c.extra:SetText(extra or "")
    c.lab:SetText(lab)
end

-- The ability list of a mode: { key, a (amount), n, sub, s (the stat) }
local function Abilities(a, mode, dur)
    local list = {}
    if mode == "healing" then
        for k, s in pairs(a.hs or {}) do
            local tot = s.a + (s.oh or 0)
            local sub
            if s.sh then sub = Count(s.n, "absorbs")
            else sub = strformat("%s · %d%% over", Count(s.n, "heals"), tot > 0 and floor((s.oh or 0) / tot * 100 + 0.5) or 0) end
            list[#list + 1] = { key = k, a = s.a, sub = sub, s = s }
        end
    elseif mode == "taken" then
        for k, s in pairs(a.ts or {}) do
            list[#list + 1] = { key = k, a = s.a, sub = Count(s.n, "hits") .. (s.src and (" · " .. s.src) or ""), s = s }
        end
    else
        for k, s in pairs(a.sp or {}) do
            local miss = 0
            for _, n in pairs(s.m or {}) do miss = miss + n end
            local unit = (k == 0 or k == "p0") and "swings" or "hits"
            local crit = s.n > 0 and s.c / s.n * 100 or 0
            list[#list + 1] = { key = k, a = s.a, s = s,
                sub = strformat("%s · %s", Count(s.n + miss, unit), s.c > 0 and strformat("%.1f%% crit", crit) or "no crits") }
        end
    end
    tsort(list, function(x, y)
        if x.a ~= y.a then return x.a > y.a end
        return tostring(x.key) < tostring(y.key)
    end)
    return list
end

local HIT_COLORS = { hit = { 0.85, 0.76, 0.48 }, crit = { 1, 0.82, 0 }, glance = { 0.56, 0.48, 0.27 },
                     miss = { 0.35, 0.35, 0.39 } }

local function DrawDetail(e, total, mode, dur, a)
    local det = frame.det
    if not e then det:Hide() return end
    det:Show()
    local s = e.s
    det.icon:SetIcon(K.SpellIcon(e.key, a))
    det.name:SetText(K.SpellName(e.key, a.pn))
    local per = mode == "taken" and dur or MD.act or dur
    det.sub:SetText(strformat("%s · %s per second", K.Fmt(e.a), K.Int(e.a / per)))
    local parts = {}
    if mode == "taken" then
        parts[#parts + 1] = { "Hit", s.n, s.n > 0 and s.a / s.n or 0, HIT_COLORS.hit }
    else
        local miss = 0
        for _, n in pairs(s.m or {}) do miss = miss + n end
        local crits, glances = s.c or 0, s.g or 0
        local hits = max(0, s.n - crits - glances)
        local ca, ga = s.ca or 0, s.ga or 0
        local ha = max(0, s.a - ca - ga)
        if mode == "healing" then ha = s.a - (ca) end
        parts[#parts + 1] = { "Hit", hits, hits > 0 and ha / hits or 0, HIT_COLORS.hit }
        if crits > 0 then parts[#parts + 1] = { "Crit", crits, ca > 0 and ca / crits or (s.a / max(1, s.n)) * 1.5, HIT_COLORS.crit } end
        if glances > 0 then parts[#parts + 1] = { "Glancing", glances, ga / glances, HIT_COLORS.glance } end
        for mt, n in pairs(s.m or {}) do
            parts[#parts + 1] = { mt:sub(1, 1) .. mt:sub(2):lower(), n, nil, HIT_COLORS.miss }
        end
    end
    local n = 0
    for _, p in ipairs(parts) do n = n + p[2] end
    if n <= 0 then n = 1 end
    -- the distribution bar
    for _, t in ipairs(det.parts) do t:Hide() end
    local x = 0
    local bw = DETAIL_W - 32
    for i, p in ipairs(parts) do
        local t = det.parts[i]
        if not t then t = K.Tex(det.dist, "ARTWORK", K.WHITE); det.parts[i] = t end
        local w = max(1, bw * p[2] / n - (i < #parts and 1 or 0))
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", det.dist, "TOPLEFT", x, 0)
        t:SetSize(w, 10)
        t:SetVertexColor(p[4][1], p[4][2], p[4][3], 1)
        t:Show()
        x = x + bw * p[2] / n
    end
    for i, ln in ipairs(det.lines) do
        local p = parts[i]
        local on = p ~= nil
        for _, f in ipairs({ ln.key, ln.name, ln.n, ln.avg, ln.share }) do f:SetShown(on) end
        if on then
            ln.key:SetVertexColor(p[4][1], p[4][2], p[4][3], 1)
            ln.name:SetText(p[1])
            ln.n:SetText(K.Int(p[2]))
            ln.avg:SetText(p[3] and K.Int(p[3]) or "–")
            ln.share:SetText(strformat("%.1f%%", p[2] / n * 100))
        end
    end
    local f = det.facts
    local hits = max(1, s.n)
    if mode == "healing" then
        local tot = s.a + (s.oh or 0)
        f[1].num:SetText(K.Int(s.mx or 0)); f[1].lab:SetText("Biggest heal")
        f[2].num:SetText(strformat("%d%%", tot > 0 and floor((s.oh or 0) / tot * 100 + 0.5) or 0)); f[2].lab:SetText("Overhealing")
        f[3].num:SetText(K.Int(s.a / hits)); f[3].lab:SetText("Average heal")
    elseif mode == "taken" then
        f[1].num:SetText(K.Int(s.n)); f[1].lab:SetText("Hits")
        f[2].num:SetText(strformat("%.1f s", dur / hits)); f[2].lab:SetText("Between hits")
        f[3].num:SetText(K.Int(s.a / hits)); f[3].lab:SetText("Average hit")
    else
        f[1].num:SetText(K.Int(s.mx or 0)); f[1].lab:SetText("Biggest hit")
        local unit = (e.key == 0 or e.key == "p0") and "swings" or "hits"
        f[2].num:SetText(strformat("%.1f s", dur / hits)); f[2].lab:SetText("Between " .. unit)
        f[3].num:SetText(K.Int(s.a / hits)); f[3].lab:SetText("Average per " .. unit:gsub("s$", ""))
    end
    f[4].num:SetText(strformat("%.1f%%", total > 0 and e.a / total * 100 or 0))
    f[4].lab:SetText(mode == "healing" and "Of all healing" or mode == "taken" and "Of all taken" or "Of all damage")
end

local function DrawAbilities(a, mode, dur)
    local list = Abilities(a, mode, dur)
    local total = 0
    for _, e in ipairs(list) do total = total + e.a end
    local sel
    for _, e in ipairs(list) do if e.key == S.ab then sel = e end end
    if not sel then sel = list[1]; S.ab = sel and sel.key end
    local top = list[1] and list[1].a or 1
    local textW = 196
    for i, e in ipairs(list) do
        local r = AbilityRow(i)
        r.key = e.key
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", frame.listChild, "TOPLEFT", 0, -(i - 1) * ROW_H)
        r:SetWidth(frame.listW)
        r.thumb:Hide()
        r.icon:Show()
        r.icon:SetIcon(K.SpellIcon(e.key, a))
        r.rank:SetText(i)
        r.rank:Show()
        r.name:SetText(K.SpellName(e.key, a.pn))
        r.sub:SetText(e.sub)
        PlaceRowText(r, 70, textW)
        r.amount:SetText(K.Fmt(e.a))
        r.pct:SetText(strformat("%.1f%%", total > 0 and e.a / total * 100 or 0))
        local tw = max(10, frame.listW - 70 - textW - 12 - 96)
        r.fill:SetWidth(max(1, tw * e.a / top))
        r.on = e == sel
        r.bg:SetVertexColor(1, 1, 1, r.on and 0.06 or 0)
        r.bar:SetShown(r.on)
        r:Show()
    end
    for i = #list + 1, #frame.rows do frame.rows[i]:Hide() end
    frame.listChild:SetHeight(max(10, #list * ROW_H))
    DrawDetail(sel, total, mode, dur, a)
    local hits = 0
    for _, e in ipairs(list) do hits = hits + (e.s.n or 0) end
    frame.tabNote:SetText(strformat("%d %s · %s %s", #list, #list == 1 and "ability" or "abilities", K.Int(hits),
        mode == "healing" and "heals" or "hits"))
    frame.empty:SetShown(#list == 0)
    frame.empty:SetText("Nothing to break down in this fight.")
end

local function DrawTargets(a)
    local list = {}
    local total = 0
    for name, v in pairs(a.tg or {}) do list[#list + 1] = { name = name, a = v }; total = total + v end
    tsort(list, function(x, y) return x.a > y.a end)
    local top = list[1] and list[1].a or 1
    for i, e in ipairs(list) do
        local r = AbilityRow(i)
        r.key = nil
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", frame.listChild, "TOPLEFT", 0, -(i - 1) * TROW_H)
        r:SetWidth(W - PAD * 2 - 12)
        r:SetHeight(TROW_H)
        r.icon:Hide()
        r.rank:Hide()
        local fid = JournalArt(e.name)
        if fid then
            r.thumb:SetTexture(fid)
            r.thumb:SetTexCoord(0, 1, 0, 1)
            r.thumb:SetVertexColor(1, 1, 1)
        else
            r.thumb:SetTexture(K.SKULL)
            r.thumb:SetTexCoord(-0.6, 1.6, -0.1, 1.1)
            r.thumb:SetVertexColor(0.55, 0.55, 0.58)
        end
        r.thumb:Show()
        r.name:SetText(e.name)
        r.sub:SetText(fid and "boss" or "")
        PlaceRowText(r, 96, 230)
        r.amount:SetText(K.Fmt(e.a))
        r.pct:SetText(strformat("%.1f%%", total > 0 and e.a / total * 100 or 0))
        r.track:ClearAllPoints()
        r.track:SetPoint("LEFT", r, "LEFT", 96 + 230 + 12, 0)
        r.track:SetPoint("RIGHT", r, "RIGHT", -110, 0)
        local tw = max(10, (W - PAD * 2 - 12) - 96 - 230 - 12 - 110)
        r.fill:SetWidth(max(1, tw * e.a / top))
        r.on = false
        r.bg:SetVertexColor(1, 1, 1, 0)
        r.bar:Hide()
        r:Show()
    end
    for i = #list + 1, #frame.rows do frame.rows[i]:Hide() end
    frame.listChild:SetHeight(max(10, #list * TROW_H))
    frame.tabNote:SetText(strformat("%d %s", #list, #list == 1 and "target" or "targets"))
    frame.empty:SetShown(#list == 0)
    frame.empty:SetText("No targets in this fight.")
end

local function DrawTime(seg, a, mode, dur)
    local field = mode == "healing" and "hl" or "tl"
    local own = a[field] or {}
    local nb = max(1, math.ceil(dur / Meter.BUCKET))
    local pts, avg = {}, {}
    local others = {}
    for _, o in pairs(seg.actors) do
        if (mode == "healing" and (o.h or 0) > 0) or (mode ~= "healing" and (o.d or 0) > 0) then others[#others + 1] = o end
    end
    local hi = 1
    for b = 1, nb do
        local x = min(dur, (b - 0.5) * Meter.BUCKET)
        local span = min(Meter.BUCKET, dur - (b - 1) * Meter.BUCKET)
        if span <= 0 then span = Meter.BUCKET end
        local v = (own[b] or 0) / span
        local s = 0
        for _, o in ipairs(others) do s = s + ((o[field] or {})[b] or 0) end
        local m = #others > 0 and s / #others / span or 0
        pts[#pts + 1] = { x, v }
        avg[#avg + 1] = { x, m }
        hi = max(hi, v, m)
    end
    local step = Kit.NiceStep and Kit.NiceStep(hi * 1.1, 4) or hi / 4
    local y1 = step * math.ceil(hi * 1.1 / step)
    frame.chart:SetData({
        x0 = 0, x1 = dur, y1 = y1, grid = true,
        series = {
            { points = pts, color = Kit.C.gold, width = 1.8, fill = true, fillAlpha = 0.16, smooth = true, glow = true, endDot = true },
            { points = avg, color = { 0.62, 0.6, 0.55 }, width = 1.2, alpha = 0.6, smooth = true },
        },
        hover = function(x)
            local yp, ya = Kit.YAt(pts, x), Kit.YAt(avg, x)
            return { { K.Clock(x), Kit.C.mute }, { strformat("%s %s", K.Int(yp or 0), mode == "healing" and "HPS" or "DPS"), Kit.C.gold },
                     { strformat("%s raid average", K.Int(ya or 0)), Kit.C.mute } }
        end,
    })
    local metric = mode == "healing" and "healing per second" or "damage per second"
    frame.legend:SetText(strformat("|cffffd100—|r %s's %s     |cff9e998c—|r the raid's average", a.n or "?", metric))
    local ch = frame.chart
    local chH = (ch:GetHeight() or 0) > 0 and ch:GetHeight() or ch.fallback[2]
    local chW = (ch:GetWidth() or 0) > 0 and ch:GetWidth() or ch.fallback[1]
    for i = 1, 5 do
        local v = y1 * (i - 1) / 4
        local lab = frame.yLabs[i]
        lab:ClearAllPoints()
        lab:SetPoint("RIGHT", ch, "BOTTOMLEFT", -8, 2 + (chH - 10) * (i - 1) / 4)
        lab:SetText(i == 1 and "" or K.Int(v))
        lab:Show()
        local xl = frame.xLabs[i]
        xl:ClearAllPoints()
        xl:SetPoint("TOP", ch, "BOTTOMLEFT", chW * (i - 1) / 4, -6)
        xl:SetText(K.Clock(dur * (i - 1) / 4))
        xl:Show()
    end
    frame.tabNote:SetText("5-second steps")
end

function MD:Draw()
    if not frame or not frame:IsShown() then return end
    if S.view == "death" then return self:DrawDeath() end
    local seg = Meter:GetSegment(S.sel)
    local a = seg and seg.actors[S.guid]
    local mode = S.mode
    if mode == "dps" or mode == "deaths" or mode == "active" or mode == "kicks" or mode == "dispels" then mode = "damage" end
    if mode == "damage" and a and (a.d or 0) == 0 and (a.h or 0) > 0 then mode = "healing" end
    local dur = Meter:Duration(seg)
    SetBanner(seg, a or { n = "?" })
    local b = frame.banner
    b.sub:SetText(a and ("|cffecdfc8" .. SpecText(a) .. "|r · " .. FightText(seg)) or FightText(seg))
    b.fight:SetText(seg and (seg.live and "Current fight" or Meter:SegName(seg)) or "No fights")
    local ranked = Ranked(seg, mode)
    local idx
    for i, r in ipairs(ranked) do if r.g == S.guid then idx = i end end
    b.step:SetText(idx and (Ordinal(idx) .. " of " .. #ranked) or "")
    b.prev:SetShown(#ranked > 1)
    b.next:SetShown(#ranked > 1)
    b.step:SetShown(true)
    for _, c in ipairs(frame.cards) do c:Show() end
    frame.tabs:Show()
    frame.tabRule:Show()
    frame.tabNote:Show()
    frame.deathChart:Hide()
    frame.events:Hide()
    frame.events.ScrollBar:Hide()
    frame.deathHp:Hide()
    for _, l in ipairs(frame.deathLabs) do l:Hide() end
    if not a then
        for _, c in ipairs(frame.cards) do c:Hide() end
        frame.tabs:Hide(); frame.tabRule:Hide(); frame.tabNote:Hide()
        frame.list:Hide(); frame.list.ScrollBar:Hide(); frame.det:Hide(); frame.chart:Hide(); frame.legend:Hide()
        for i = 1, 5 do frame.yLabs[i]:Hide(); frame.xLabs[i]:Hide() end
        frame.empty:SetText("They were not in this fight.")
        frame.empty:Show()
        return
    end

    -- cards
    local c = frame.cards
    local specIcon = K.SpecIcon(a.c, a.s) or "Interface\\Icons\\Ability_Warrior_SavageBlow"
    local act = Meter:ActiveTime(seg, a)
    MD.act = act
    if mode == "healing" then
        local tot = a.h + a.oh
        local crits, n = 0, 0
        for _, s in pairs(a.hs or {}) do if not s.sh then crits = crits + (s.c or 0); n = n + s.n end end
        SetCard(c[1], specIcon, K.Fmt(a.h), nil, "Healing done")
        SetCard(c[2], "Interface\\Icons\\Spell_Holy_FlashHeal", K.Int(a.h / act), idx and Ordinal(idx) or nil, "Healing per second")
        SetCard(c[3], "Interface\\Icons\\Spell_Holy_Renew", strformat("%d%%", tot > 0 and floor(a.oh / tot * 100 + 0.5) or 0), nil, "Overhealing")
        SetCard(c[4], "Interface\\Icons\\Spell_Holy_SealOfMight", strformat("%.1f%%", n > 0 and crits / n * 100 or 0), nil, "Crit, all heals")
    elseif mode == "taken" then
        local big = 0
        for _, s in pairs(a.ts or {}) do big = max(big, s.a / max(1, s.n)) end
        SetCard(c[1], specIcon, K.Fmt(a.t), nil, "Damage taken")
        SetCard(c[2], "Interface\\Icons\\Ability_Warrior_DefensiveStance", K.Int(a.t / dur), idx and Ordinal(idx) or nil, "Taken per second")
        SetCard(c[3], "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01", tostring(Meter.IsDead and Meter:IsDead(seg, S.guid) and 1 or 0), nil, "Deaths")
        SetCard(c[4], "Interface\\Icons\\Spell_Holy_SealOfMight", K.Int(big), nil, "Average hit, worst ability")
    else
        local crits, n = 0, 0
        for _, s in pairs(a.sp or {}) do crits = crits + (s.c or 0); n = n + (s.n or 0) end
        SetCard(c[1], specIcon, K.Fmt(a.d), nil, "Damage done")
        SetCard(c[2], "Interface\\Icons\\Spell_Nature_BloodLust", K.Int(a.d / act), idx and Ordinal(idx) or nil, "DPS in the raid")
        SetCard(c[3], "Interface\\Icons\\Spell_Holy_BlessingOfStrength", K.Pct(min(100, (a.act or 0) / dur * 100)), nil, "Active time")
        SetCard(c[4], "Interface\\Icons\\Spell_Holy_SealOfMight", strformat("%.1f%%", n > 0 and crits / n * 100 or 0), nil, "Crit, all hits")
    end

    -- tabs: Targets for damage only, Over time not for Whole raid
    local canTargets = mode == "damage"
    local canTime = not seg.noTl and mode ~= "taken"
    frame.tabs.buttons[2]:SetShown(canTargets)
    frame.tabs.buttons[3]:SetShown(canTime)
    frame.tabs.buttons[3]:ClearAllPoints()
    frame.tabs.buttons[3]:SetPoint("LEFT", canTargets and frame.tabs.buttons[2] or frame.tabs.buttons[1], "RIGHT", 4, 0)
    if (S.tab == "targets" and not canTargets) or (S.tab == "time" and not canTime) then S.tab = "abilities" end
    frame.tabs:SetSelected(S.tab)

    local isList = S.tab ~= "time"
    frame.list:SetShown(isList)
    frame.list.ScrollBar:SetShown(isList)
    frame.chart:SetShown(not isList)
    frame.legend:SetShown(not isList)
    for i = 1, 5 do frame.yLabs[i]:SetShown(not isList); frame.xLabs[i]:SetShown(not isList) end
    frame.empty:Hide()
    if S.tab == "abilities" then
        frame.list:SetWidth(frame.listW)
        frame.listChild:SetWidth(frame.listW)
        for _, r in ipairs(frame.rows) do r:SetHeight(ROW_H) end
        DrawAbilities(a, mode, dur)
    elseif S.tab == "targets" then
        frame.det:Hide()
        frame.list:SetWidth(W - PAD * 2 - 12)
        frame.listChild:SetWidth(W - PAD * 2 - 12)
        DrawTargets(a)
    else
        frame.det:Hide()
        DrawTime(seg, a, mode, dur)
    end
end

---------------------------------------------------------------------------
-- The death recap
---------------------------------------------------------------------------

local function DeathsOf(seg)
    local list = {}
    for _, d in ipairs(seg and seg.deaths or {}) do list[#list + 1] = d end
    return list
end

function MD:DrawDeath()
    local seg = Meter:GetSegment(S.sel)
    local d = S.death
    local deaths = DeathsOf(seg)
    local idx
    for i, x in ipairs(deaths) do if x == d then idx = i end end
    if not idx and d and seg then
        for i, x in ipairs(deaths) do if x.g == d.g and x.t == d.t then idx = i; d = x; S.death = x end end
    end
    if not d then frame:Hide() return end
    local a = (seg and seg.actors[d.g]) or { n = d.n, c = d.c }
    SetBanner(seg, a)
    local b = frame.banner
    local took, healed = 0, 0
    for _, e in ipairs(d.ev or {}) do
        if e[2] == "d" then took = took + (e[4] or 0) else healed = healed + (e[4] or 0) end
    end
    b.sub:SetText(strformat("Died at |cffecdfc8%s|r to |cffff8a70%s|r · took |cffecdfc8%s|r in %d s, healing brought back |cffecdfc8%s|r",
        K.Clock(d.t), d.by and K.SpellName(d.by) or "?", K.Int(took), Meter.RECAP, K.Int(healed)))
    b.fight:SetText(seg and (seg.live and "Current fight" or Meter:SegName(seg)) or "")
    b.step:SetText(idx and (Ordinal(idx) .. " of " .. #deaths) or "")
    b.prev:SetShown(#deaths > 1)
    b.next:SetShown(#deaths > 1)
    for _, c in ipairs(frame.cards) do c:Hide() end
    frame.tabs:Hide(); frame.tabRule:Hide(); frame.tabNote:Hide()
    frame.list:Hide(); frame.list.ScrollBar:Hide(); frame.det:Hide(); frame.chart:Hide(); frame.legend:Hide()
    for i = 1, 5 do frame.yLabs[i]:Hide(); frame.xLabs[i]:Hide() end
    frame.empty:Hide()

    -- health over the last seconds (a step line; the start is worked back from the first event)
    local ev = d.ev or {}
    local hpMax = (d.hpMax and d.hpMax > 0) and d.hpMax or 0
    if hpMax <= 0 then for _, e in ipairs(ev) do hpMax = max(hpMax, e[6] or 0) end end
    if hpMax <= 0 then hpMax = 1 end
    local function pct(v) return min(100, max(0, (v or 0) / hpMax * 100)) end
    local pts, dots = {}, {}
    local first = ev[1]
    local start = hpMax
    if first then
        start = (first[6] or 0) + (first[2] == "d" and (first[4] or 0) or -(first[4] or 0))
        start = min(hpMax, max(0, start))
    end
    pts[1] = { -Meter.RECAP, pct(start) }
    local prev = pct(start)
    for _, e in ipairs(ev) do
        pts[#pts + 1] = { e[1], prev }
        local now = pct(e[6])
        pts[#pts + 1] = { e[1], now }
        dots[#dots + 1] = { e[1], now, e[2] == "d" and Kit.C.down or Kit.C.up, 8 }
        prev = now
    end
    local dc = frame.deathChart
    dc:Show()
    dc:SetData({
        x0 = -Meter.RECAP, x1 = 0.3, y1 = 112, grid = true,
        series = { { points = pts, color = Kit.C.up, width = 2, fill = true, fillAlpha = 0.18 } },
        dots = dots,
        hover = function(x)
            local best, bd
            for _, e in ipairs(ev) do
                local dd = abs(e[1] - x)
                if not bd or dd < bd then best, bd = e, dd end
            end
            if not best or bd > 0.8 then return nil end
            return { { strformat("%.1f s", best[1]), Kit.C.mute },
                     { K.SpellName(best[3]) .. "  " .. (best[2] == "d" and "-" or "+") .. K.Int(best[4]), best[2] == "d" and Kit.C.down or Kit.C.up },
                     { strformat("health %s", K.Int(best[6] or 0)), Kit.C.mute } }
        end,
    })
    frame.deathHp:SetText(K.Int(hpMax) .. " health")
    frame.deathHp:Show()
    local dW = (dc:GetWidth() or 0) > 0 and dc:GetWidth() or dc.fallback[1]
    for i = 1, 6 do
        local s = -Meter.RECAP + (i - 1) * 2
        local lab = frame.deathLabs[i]
        lab:ClearAllPoints()
        lab:SetPoint("TOP", dc, "BOTTOMLEFT", dW * (s + Meter.RECAP) / (Meter.RECAP + 0.3), -5)
        lab:SetText(s == 0 and "death" or (s .. " s"))
        lab:Show()
    end

    -- every event, newest first
    frame.events:Show()
    frame.events.ScrollBar:Show()
    local n = #ev
    for i = 1, n do
        local e = ev[n - i + 1]
        local r = EventRow(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", frame.eventsChild, "TOPLEFT", 0, -(i - 1) * EROW_H)
        r:SetWidth(W - PAD * 2 - 10)
        local killing = i == 1 and e[2] == "d"
        r.bg:SetVertexColor(killing and 1 or 1, killing and 0.24 or 1, killing and 0.16 or 1, killing and 0.09 or (i % 2 == 1 and 0.02 or 0))
        r.mark:SetShown(killing)
        r.t:SetText(strformat("%.1f s", e[1]))
        r.icon:SetIcon(K.SpellIcon(e[3]))
        local extra = ""
        if e[2] == "d" and e[7] then extra = " · overkill " .. K.Int(e[7]) end
        if e[2] == "h" and e[7] then extra = " · " .. K.Int(e[7]) .. " over" end
        r.what:SetText(strformat("%s |cffa29d90%s %s%s|r", K.SpellName(e[3]), e[2] == "d" and "from" or "by", e[5] or "?", extra))
        r.amount:SetText((e[2] == "d" and "−" or "+") .. K.Int(e[4]))
        if e[2] == "d" then r.amount:SetTextColor(C3(K.RED)) else r.amount:SetTextColor(C3(K.GREEN)) end
        local p = pct(e[6])
        r.hpFill:SetWidth(max(0.01, 64 * p / 100))
        r.hpFill:SetShown(p > 0)
        if p < 30 then r.hpFill:SetVertexColor(1, 0.36, 0.3) else r.hpFill:SetVertexColor(0.27, 0.83, 0.45) end
        r.hp:SetText(floor(p + 0.5) .. "%")
        r:Show()
    end
    for i = n + 1, #frame.evRows do frame.evRows[i]:Hide() end
    frame.eventsChild:SetHeight(max(10, n * EROW_H))
end

---------------------------------------------------------------------------
-- Opening, arrows, fights
---------------------------------------------------------------------------

function MD:Open(sel, guid, mode)
    if not frame then Build() end
    S.view, S.sel, S.guid, S.mode = "player", sel or "cur", guid, mode or "damage"
    S.ab = nil
    if S.mode == "healing" or S.mode == "taken" then S.tab = "abilities" end
    frame:Show()
    frame:Raise()
    self:Draw()
end

function MD:OpenDeath(sel, death)
    if not frame then Build() end
    S.view, S.sel, S.death = "death", sel or "cur", death
    frame:Show()
    frame:Raise()
    self:Draw()
end

function MD:Step(dir)
    local seg = Meter:GetSegment(S.sel)
    if S.view == "death" then
        local list = DeathsOf(seg)
        if #list == 0 then return end
        local i = 1
        for j, d in ipairs(list) do if d == S.death then i = j end end
        S.death = list[(i - 1 + dir) % #list + 1]
    else
        local mode = S.mode
        if mode == "dps" or mode == "deaths" or mode == "active" or mode == "kicks" or mode == "dispels" then mode = "damage" end
        local list = Ranked(seg, mode)
        if #list == 0 then return end
        local i = 1
        for j, r in ipairs(list) do if r.g == S.guid then i = j end end
        S.guid = list[(i - 1 + dir) % #list + 1].g
        S.ab = nil
    end
    self:Draw()
end

function MD:FightMenu(root)
    local fights, all = Meter:GetFights()
    for i, seg in ipairs(fights) do
        local e = root:CreateRadio(seg.live and "Current fight" or Meter:SegName(seg), function()
            local cur = Meter:GetSegment(S.sel)
            return cur == seg
        end, function()
            S.sel = (i == 1) and "cur" or seg.id
            MD:Draw()
        end, seg.id)
        e:SetSubtext(FightText(seg):gsub("^[^·]+· ", ""))
    end
    if all then
        root:CreateDivider()
        local e = root:CreateRadio(Meter:SegName(all), function() return S.sel == "all" end,
            function() S.sel = "all"; MD:Draw() end, "all")
        e:SetSubtext(K.Clock(Meter:Duration(all)))
    end
end

function MD:GetFrame() return frame end
function MD:GetState() return S end

function MD:OnLogin()
    Meter = ns.Meter
    Meter:OnChange(function(what)
        if frame and frame:IsShown() and (what == "end" or what == "clear") then MD:Draw() end
    end)
end
