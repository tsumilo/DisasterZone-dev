if DisasterZoneBoot and DisasterZoneBoot.Run("UI/GroupsCard.lua", ...) then return end -- DisasterZone: a group's card (the Groups tab).
-- A group's card on the Groups tab (UI/DungeonsTab.lua builds the page): the art, the texts, the places and the action;
-- my own group's card adds the players asking to join, the members up for a run who fit and the Group Finder eye. The
-- helpers the page, its sheet and its pop-ups share live here too (ns.GroupsCard).
local addonName, ns = ...

local G = {}
ns.GroupsCard = G
local S = ns.Style

local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local CARD_H = 72
local ART_W = 180
local SLOT, SLOT_GAP = 30, 5
local ACT_W = 92
local REQ_H = 30

local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local HEROIC_TEX = "Interface\\LFGFrame\\UI-LFG-ICON-HEROIC"
local STAR_TEX = "Interface\\AddOns\\DisasterZone\\Media\\Icons\\bis"
local NO_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local STAR = "|T" .. STAR_TEX .. ":11:11:0:0|t"
local ROLE_NAME = { tank = "tank", healer = "healer", dps = "DPS" }

local GOLD = S.C.GOLD

-- What the page and the card share: the page that was opened on a group (focus), the members I invited.
local state = { invited = {} }
G.state = state

local function R() return ns.DungeonRuns end
local function UI() return ns.UI end
local function Me() return ns.Util.PlayerKey() end

local function Disc(parent, layer, sub, size, c)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(DISC)
    t:SetSize(size, size)
    t:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
    return t
end

-- A dungeon's name that fits: the full name, else the short one, else the short one a step down the type scale.
local NEXT_STYLE = { title = "emph", emph = "body" }
local function FitName(fs, full, short, width, style)
    UI():SetTextStyle(fs, style, "TEXT")
    fs:SetText(full)
    if (fs:GetStringWidth() or 0) <= width or not short then return end
    fs:SetText(short)
    if (fs:GetStringWidth() or 0) <= width then return end
    UI():SetTextStyle(fs, NEXT_STYLE[style] or style, "TEXT")
end

local function ItemLinkText(itemID)
    local name, quality
    if ns.ItemDB and ns.ItemDB.GetInfo then
        local n, _, q = ns.ItemDB:GetInfo(itemID)
        name, quality = n, q
    end
    if not name then return S:Wrap("SUB", "Loading...") end
    local r, g, b = UI():QualityColor(quality)
    return ("|cff%02x%02x%02x[%s]|r"):format(floor(r * 255), floor(g * 255), floor(b * 255), name)
end

-- "starting now", "listed 25 min ago", "20:30, in 2 h", "Tomorrow 20:30", "Sat 20:30", "started 10 min ago".
local function WhenText(run)
    local now = ns.Util.Now()
    local at = run.at or 0
    if at == 0 then
        local age = floor((now - (run.c or now)) / 60)
        if age < 10 then return "starting now" end
        if age < 60 then return "listed " .. age .. " min ago" end
        return "listed " .. floor(age / 60) .. " h ago"
    end
    local clock = date("%H:%M", at)
    if at <= now then
        local ago = floor((now - at) / 60)
        return ago < 1 and "starting now" or ("started " .. ago .. " min ago")
    end
    local left = at - now
    local today = date("%Y%m%d", now) == date("%Y%m%d", at)
    if today then
        if left < 3600 then return clock .. ", in " .. max(1, floor(left / 60)) .. " min" end
        return clock .. ", in " .. floor(left / 3600 + 0.5) .. " h"
    end
    if date("%Y%m%d", now + 86400) == date("%Y%m%d", at) then return "Tomorrow " .. clock end
    return date("%a ", at) .. clock
end

-- The day label of a later run's section: "today", "Tomorrow", "Saturday 11 Oct".
local function DayLabel(at)
    local now = ns.Util.Now()
    if date("%Y%m%d", now) == date("%Y%m%d", at) then return "today" end
    if date("%Y%m%d", now + 86400) == date("%Y%m%d", at) then return "Tomorrow" end
    return date("%A ", at) .. tonumber(date("%d", at)) .. date(" %b", at)
end

local function DungeonName(run)
    local d = R():GetDungeon(run.d)
    return d and d.name or tostring(run.d), d and d.short or nil
end

-- (an OnLeave handler: the shared tooltip goes)
local function HideTip() UI():HideTooltip() end

-- A tooltip built by a function (a card's, a tile's) can say "Loading..." for an item not cached yet: once the
-- page refreshes (item info arrived, or anything else), the tooltip still under the mouse is built again.
local function RedrawHoveredTip()
    if not (GameTooltip:IsShown() and GameTooltip.GetOwner) then return end
    local owner = GameTooltip:GetOwner()
    if not (owner and owner.liveTip and type(owner.tip) == "function") then return end
    if not (owner:IsVisible() and owner.IsMouseOver and owner:IsMouseOver()) then return end
    local onEnter = owner:GetScript("OnEnter")
    if onEnter then onEnter(owner) end
end


---------------------------------------------------------------------------
-- Slots: a class circle with a role badge, or an empty ring with the role it wants (gold when it wants me)
---------------------------------------------------------------------------

-- The place that wants me: two small sparks circle its ring, each with a fading tail (the autocast shine of the
-- socketing window, as LibCustomGlow uses it). One turn takes ORBIT_TURN seconds; nothing pulses.
local SHINE = "Interface\\ItemSocketingFrame\\UI-ItemSockets"
local SHINE_COORDS = { 0.3984375, 0.4453125, 0.40234375, 0.44921875 }
local ORBIT_TURN = 3.2
local TAIL = { { size = 9, alpha = 1 }, { size = 6, alpha = 0.5 }, { size = 4, alpha = 0.25 } }
local TAIL_STEP = 0.2   -- radians between a spark and its tail dots

local function OrbitUpdate(o, dt)
    o.angle = (o.angle + dt * 2 * math.pi / ORBIT_TURN) % (2 * math.pi)
    local r = o.radius or 15
    for _, d in ipairs(o.dots) do
        local a = o.angle + d.offset
        d.tex:SetPoint("CENTER", o, "CENTER", r * math.cos(a), r * math.sin(a))
    end
end

local function NewOrbit(s)
    local o = CreateFrame("Frame", nil, s)
    o:SetAllPoints(s)
    o:SetFrameLevel(s:GetFrameLevel() + 2)
    o.dots, o.angle = {}, 0
    for spark = 0, 1 do
        for i, t in ipairs(TAIL) do
            local tex = o:CreateTexture(nil, "OVERLAY")
            tex:SetTexture(SHINE)
            tex:SetTexCoord(SHINE_COORDS[1], SHINE_COORDS[2], SHINE_COORDS[3], SHINE_COORDS[4])
            tex:SetBlendMode("ADD")
            tex:SetVertexColor(1, 0.86, 0.35, t.alpha)
            tex:SetSize(t.size, t.size)
            o.dots[#o.dots + 1] = { tex = tex, offset = spark * math.pi - (i - 1) * TAIL_STEP }
        end
    end
    o:Hide()
    function o:Start(radius)
        self.radius = radius
        if not self:IsShown() then
            self.angle = (GetTime() % ORBIT_TURN) / ORBIT_TURN * 2 * math.pi   -- every ring turns in step
            self:Show()
            self:SetScript("OnUpdate", OrbitUpdate)
            OrbitUpdate(self, 0)
        end
    end
    function o:Stop()
        self:SetScript("OnUpdate", nil)
        self:Hide()
    end
    return o
end

local function NewSlot(parent, size)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(size, size)
    s.ring = Disc(s, "BACKGROUND", 2, size, { 1, 1, 1, 0.22 })
    s.ring:SetPoint("CENTER")
    s.fill = Disc(s, "BACKGROUND", 3, size - 2, { 0.07, 0.07, 0.08, 1 })
    s.fill:SetPoint("CENTER")
    s.class = s:CreateTexture(nil, "ARTWORK")
    s.class:SetSize(size - 2, size - 2)
    s.class:SetPoint("CENTER")
    s.role = s:CreateTexture(nil, "ARTWORK", nil, 1)
    s.role:SetSize(floor(size * 0.66), floor(size * 0.66))
    s.role:SetPoint("CENTER")
    s.badge = s:CreateTexture(nil, "OVERLAY")
    s.badge:SetSize(floor(size * 0.47), floor(size * 0.47))
    s.badge:SetPoint("BOTTOMRIGHT", s, "BOTTOMRIGHT", 3, -3)
    s.orbit = NewOrbit(s)
    s:EnableMouse(true)
    s:SetScript("OnEnter", function(self) if self.tip then UI():SetTextTooltip(self, self.tip, "ANCHOR_TOP") end end)
    s:SetScript("OnLeave", HideTip)
    s:SetScript("OnMouseUp", function(self) if self.onPick then self.onPick(self) end end)   -- (my run: the role)
    return s
end

-- d = { key, role, class, you } or { empty = true, role }; wants = this empty place wants me.
local function FillSlot(s, d, wants, dim)
    s:SetAlpha(dim and 0.42 or 1)
    s.onPick = nil
    if d.empty then
        s.class:Hide()
        s.badge:Hide()
        s.role:Show()
        UI():SetRoleIcon(s.role, d.role)
        s.fill:SetVertexColor(0.07, 0.07, 0.08, 1)
        if wants then
            s.ring:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.75)
            s.role:SetVertexColor(1, 1, 1)
            s.role:SetDesaturated(false)
            s.role:SetAlpha(1)
            s.orbit:Start(s:GetWidth() / 2)
        else
            s.ring:SetVertexColor(1, 1, 1, 0.22)
            s.role:SetDesaturated(true)
            s.role:SetAlpha(0.4)
            s.orbit:Stop()
        end
        s.tip = { "Open place: " .. R().ROLE_LABEL[d.role], wants and "That's you." or nil }
    else
        s.orbit:Stop()
        s.role:Hide()
        s.class:Show()
        UI():ClassIcon(s.class, d.class)
        if not d.class then s.class:Hide() end
        s.badge:Show()
        UI():SetRoleIcon(s.badge, d.role)
        s.ring:SetVertexColor(d.you and GOLD[1] or 0, d.you and GOLD[2] or 0, d.you and GOLD[3] or 0, d.you and 0.9 or 1)
        local spec = R():GetSpecLabel(d.key)
        local line = R().ROLE_LABEL[d.role] .. (spec and (" · " .. spec) or "")
        s.tip = { UI():ColoredName(d.key, d.class), line, d.owner and S:Wrap("SUB", "Leads the run") or nil }
    end
end

---------------------------------------------------------------------------
-- Cards
---------------------------------------------------------------------------

-- A run's card: the shared card (UI:CreateCard) with the shared row looks (the hover; my own run wears the picked
-- look, the gold wash and bar), the dungeon's art on its left fading into the card, the texts, the five places and
-- the action.
local function NewRunCard(parent)
    local c = UI():CreateCard(parent, { tone = "card", pad = 0 })
    c:EnableMouse(true)
    c.liveTip = true
    c:SetScript("OnEnter", function(self) if self.tip then UI():SetTextTooltip(self, self.tip(), "ANCHOR_RIGHT") end end)
    c:SetScript("OnLeave", UI().HideTooltip)
    UI():DecorateRow(c, { selectable = true })
    c.art = c:CreateTexture(nil, "ARTWORK", nil, 0)
    c.art:SetPoint("TOPLEFT", 1, -1)
    c.fade = c:CreateTexture(nil, "ARTWORK", nil, 2)
    c.fade:SetColorTexture(1, 1, 1, 1)
    c.shade = c:CreateTexture(nil, "ARTWORK", nil, 1)     -- darkens the art's bottom under "Heroic"
    c.shade:SetColorTexture(1, 1, 1, 1)
    c.skull = c:CreateTexture(nil, "OVERLAY")
    c.skull:SetTexture(HEROIC_TEX)
    c.skull:SetTexCoord(0, 0.5, 0, 0.625)
    c.skull:SetSize(11, 14)
    c.heroic = UI():Text(c, "small", "GOLD")
    c.heroic:SetText("Heroic")
    c.heroic:SetPoint("LEFT", c.skull, "RIGHT", 2, 0)
    c.t1 = UI():Text(c, "title", "TEXT")
    c.notes = CreateFrame("Frame", nil, c)
    c.notes:SetSize(14, 14)
    c.notes.icon = c.notes:CreateTexture(nil, "OVERLAY")
    c.notes.icon:SetAllPoints()
    c.notes.icon:SetTexture(UI().ICON_ATLAS)
    c.notes.icon:SetTexCoord(unpack(UI():IconCoords(UI().ICON.notes)))
    c.notes.icon:SetVertexColor(0.7, 0.7, 0.7, 0.8)
    c.notes:EnableMouse(true)
    c.notes:SetScript("OnEnter", function(self)
        if self.note then UI():SetTextTooltip(self, { "Note", self.note }, "ANCHOR_TOP") end
    end)
    c.notes:SetScript("OnLeave", HideTip)
    c.t2 = UI():Text(c, "body", "SUB")
    c.t3 = UI():Text(c, "body", "TEXT")
    c.hint = CreateFrame("Frame", nil, c)            -- the BiS item's tooltip
    c.hint:SetPoint("TOPLEFT", c.t3, "TOPLEFT")
    c.hint:SetPoint("BOTTOMRIGHT", c.t3, "BOTTOMRIGHT")
    c.hint:EnableMouse(true)
    c.hint:SetScript("OnEnter", function(self)
        if self.itemID then UI():SetItemTooltip(self, self.itemID, self.extra) end
    end)
    c.hint:SetScript("OnLeave", HideTip)
    c.slots = {}
    for i = 1, 5 do c.slots[i] = NewSlot(c, SLOT) end
    c.btn = UI():CreateSleekButton(c, "", 80, S.BTN_H, nil, "primary")
    c.more = UI():CreateTipIconButton(c, 26, UI().ICON.more, "Your run", "Edit it, post it in the LookingForGroup "
        .. "channel, or take it off the board.")
    if ns.Share and ns.Share.CreateButton then
        c.share = ns.Share:CreateButton(c, 26, function() return c.runId and ns.Share:RunRef(c.runId) or nil end,
            "Share your run")
    end
    c.reqs, c.free = {}, {}
    return c
end

-- The dungeon's art in a w x h box (left part of the card), fading into the card on its right.
local function SetArt(c, key, w, h, bg)
    local file, l, r, t, b = R():GetArt(key, w, h)
    c.art:SetSize(w, h)
    if file then
        c.art:SetTexture(file)
        c.art:SetTexCoord(l, r, t, b)
        c.art:Show()
    else
        c.art:Hide()
    end
    c.fade:ClearAllPoints()
    c.fade:SetPoint("TOPRIGHT", c.art, "TOPRIGHT")
    c.fade:SetPoint("BOTTOMRIGHT", c.art, "BOTTOMRIGHT")
    c.fade:SetWidth(floor(w * 0.42))
    UI():Gradient(c.fade, "HORIZONTAL", { bg[1], bg[2], bg[3], 0 }, { bg[1], bg[2], bg[3], 1 })
    c.shade:ClearAllPoints()
    c.shade:SetPoint("BOTTOMLEFT", c.art, "BOTTOMLEFT")
    c.shade:SetPoint("BOTTOMRIGHT", c.art, "BOTTOMRIGHT")
    c.shade:SetHeight(26)
    UI():Gradient(c.shade, "VERTICAL", { 0, 0, 0, 0.75 }, { 0, 0, 0, 0 })
end

-- What a card's tooltip says: the dungeon, the leader, when, the party, the note.
local function CardTip(run)
    return function()
        local name = DungeonName(run)
        local lines = { name .. (run.h and " (Heroic)" or "") }
        lines[#lines + 1] = "Led by " .. UI():ColoredName(run.o) .. " · " .. WhenText(run)
        local who = {}
        for _, s in ipairs(R():GetSlots(run)) do
            if not s.empty then who[#who + 1] = UI():RoleIconText(s.role, 12) .. " " .. UI():ColoredName(s.key, s.class) end
        end
        if #who > 0 then lines[#lines + 1] = tconcat(who, "   ") end
        if run.no then lines[#lines + 1] = S:Wrap("SUB", "\"" .. run.no .. "\"") end
        local drops = R():GetMyBiSDrops(run.d, run.h)
        if #drops > 0 and run.o ~= Me() then
            lines[#lines + 1] = S:Wrap("GOLD", "Drops your BiS:")
            for i, id in ipairs(drops) do
                if i > 6 then lines[#lines + 1] = S:Wrap("SUB", "+" .. (#drops - 6) .. " more") break end
                lines[#lines + 1] = "  " .. ItemLinkText(id)
            end
        end
        return lines
    end
end

-- The one hint under a run: what stops me, else what drops my BiS. Returns text, itemID (for its tooltip).
local function HintFor(run)
    if run.o == Me() then return nil end
    local a = R():GetAsked(run.id)
    if a and a.st == "declined" then return S:Wrap("SUB", ns.Util.ShortName(run.o) .. " said not this time") end
    local block = R():GetBlocker(run.d, run.h)
    if block then return S:Wrap("WARN", UI():LockIcon(12) .. " " .. block) end
    if R():IsGrouped() and not R():IsInRun(run) and R():FitsMe(run) then
        return S:Wrap("SUB", "You're in a group: leave it to join")
    end
    local drops = R():GetMyBiSDrops(run.d, run.h)
    if #drops > 0 then
        local more = #drops > 1 and S:Wrap("SUB", " +" .. (#drops - 1)) or ""
        return S:Wrap("GOLD", STAR .. " Drops your BiS ") .. ItemLinkText(drops[1]) .. more, drops[1], drops
    end
    local daily = R():GetMyDaily(run.d, run.h)
    if daily == "log" or daily == "today" then
        return "|TInterface\\GossipFrame\\DailyQuestIcon:12:12:0:0|t " .. S:Wrap("GOLD", run.h and "Your daily heroic"
            or "Your daily dungeon")
    end
    return nil
end

local function HideReqRows(c)
    for _, r in ipairs(c.reqs) do r:Hide() end
    for _, r in ipairs(c.free) do r:Hide() end
    for _, r in ipairs(c.pugs or {}) do r:Hide() end
end

-- A request row on my own card: class, name, spec, "BiS here", Accept, decline.
local function NewReqRow(c)
    local r = CreateFrame("Frame", nil, c)
    r:SetHeight(REQ_H)
    r.line = UI():Rule(r, { layer = "BORDER" })
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(22, 22)
    r.icon:SetPoint("LEFT", 0, 0)
    r.name = UI():Text(r, "emph", "TEXT")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
    r.spec = UI():Text(r, "body", "SUB")
    r.spec:SetPoint("LEFT", r.name, "RIGHT", 7, 0)
    r.tag = UI():CreatePill(r, "bis", STAR .. " BiS here")
    r.tag:SetPoint("LEFT", r.spec, "RIGHT", 9, 0)
    UI():AttachTooltip(r.tag, "BiS here", function(self)
        return { "Something on " .. (self.who or "their") .. " BiS list drops in this dungeon." }
    end, { anchor = "ANCHOR_TOP" })
    r.no = UI():CreateIconButton(r, 22, NO_TEX, nil, function(self) if self.onClick then self.onClick() end end)
    r.no.icon:ClearAllPoints()
    r.no.icon:SetPoint("TOPLEFT", 4, -4)
    r.no.icon:SetPoint("BOTTOMRIGHT", -4, 4)
    r.no:SetPoint("RIGHT", 0, 0)
    r.no:SetScript("OnEnter", function(self)
        UI():SetTextTooltip(self, { "Not this time", "Lets them know, kindly." }, "ANCHOR_TOP")
    end)
    r.no:SetScript("OnLeave", HideTip)
    r.yes = UI():CreateSleekButton(r, "Accept", 70, 22, function(self) if self.onClick then self.onClick() end end, "primary")
    r.yes:SetPoint("RIGHT", r.no, "LEFT", -5, 0)
    r.state = UI():Text(r, "body", "TEXT")
    r.state:SetPoint("RIGHT", r.no, "LEFT", -10, 0)
    return r
end

-- A person chip (UI:CreateChip: the class circle, the name in class colour, the role icons after it; it fits its
-- content). onClick: a click whispers them (the strip); none on my run's card (Invite sits beside it).
local function NewPersonChip(parent, onClick)
    local f = UI():CreateChip(parent, { kind = "track", onClick = onClick })
    UI():AttachTooltip(f, nil, function(self) return self.tipLines end, { anchor = "ANCHOR_TOP" })
    return f
end

local function FillChip(f, e)
    local icons, words = {}, {}
    for _, role in ipairs(R().ROLES) do
        if e.roles[role] then
            icons[#icons + 1] = UI():RoleIconText(role, 13)
            words[#words + 1] = R().ROLE_LABEL[role]
        end
    end
    f:Set(UI():ColoredName(e.key, e.class) .. " " .. tconcat(icons, ""), nil, e.key)
    f.key = e.key
    f.tipLines = { { UI():ColoredName(e.key, e.class) }, "Up for a run: " .. tconcat(words, ", "),
        e.grouped and S:Wrap("WARN", "In a group right now: an invite can't reach them.") or S:Wrap("SUB", "Click to whisper"),
        e.grouped and S:Wrap("SUB", "Click to whisper") or nil }
    f:SetAlpha(e.grouped and 0.55 or 1)
end

---------------------------------------------------------------------------
-- My run in the Group Finder (Core/GroupFinder.lua): the eye between Share and More lists it there or takes it out
-- (its iris looks left and right while listed, like Blizzard's LFG eye); the players from outside the guild who
-- could fill it show up under the run (whispers first, then solo players listed for the dungeon)
---------------------------------------------------------------------------

local PUG_ROWS = 5
-- the iris's glance: { time (s), where (-1 left .. 1 right) }, eased between, one look around per EYE_TURN seconds
local EYE_KEYS = { { 0, 0 }, { 0.7, 0 }, { 1.0, -1 }, { 1.8, -1 }, { 2.2, 1 }, { 3.0, 1 }, { 3.4, 0 }, { 4.2, 0 } }
local EYE_TURN = 4.2
local EYE_REACH = 10 / 64   -- how far the iris travels, as a share of the icon's width (the generator's 10 units)

local function GFm() return ns.GroupFinder end

local function HookTip(b, lines)
    b.tipLines = lines
    b:HookScript("OnEnter", function(self) if self.tipLines then UI():SetTextTooltip(self, self.tipLines, "ANCHOR_TOP") end end)
    b:HookScript("OnLeave", HideTip)
end

local function EyeAt(t)
    t = t % EYE_TURN
    for i = 2, #EYE_KEYS do
        local a, b = EYE_KEYS[i - 1], EYE_KEYS[i]
        if t <= b[1] then
            local f = (t - a[1]) / (b[1] - a[1])
            f = f * f * (3 - 2 * f)
            return a[2] + (b[2] - a[2]) * f
        end
    end
    return 0
end

-- The eye: art pack 4 draws it in two parts (lids, iris); an older art pack shows the plain eye, still.
local function NewEye(parent)
    local Ui = UI()
    local split = ns:HasAssets(4)
    local b = Ui:CreateIconButton(parent, 26, Ui.ICON_ATLAS, Ui:IconCoords(split and Ui.ICON.finder or Ui.ICON.eye),
        function(self) if self.onClick then self.onClick() end end)
    if split then
        b.iris = b:CreateTexture(nil, "OVERLAY")
        b.iris:SetTexture(Ui.ICON_ATLAS)
        local c = Ui:IconCoords(Ui.ICON.finderIris)
        b.iris:SetTexCoord(c[1], c[2], c[3], c[4])
    end
    -- (the icon fills the button but 5 px on each side: its width is known before any layout)
    function b:PlaceIris()
        local iris = self.iris
        if not iris then return end
        local x = self.looking and EyeAt(self.t or 0) * EYE_REACH * max(1, (self:GetWidth() or 26) - 10) or 0
        iris:ClearAllPoints()
        iris:SetPoint("TOPLEFT", self.icon, "TOPLEFT", x, 0)
        iris:SetPoint("BOTTOMRIGHT", self.icon, "BOTTOMRIGHT", x, 0)
        iris:SetVertexColor(self.icon:GetVertexColor())
    end
    local function look(self, dt)
        self.t = (self.t or 0) + dt
        self:PlaceIris()
    end
    -- listed: the button looks chosen and the iris looks around
    function b:SetLooking(on)
        self.looking = on and true or false
        self:SetActive(self.looking)
        if self.iris then self:SetScript("OnUpdate", self.looking and look or nil) end
        self:PlaceIris()
    end
    b:HookScript("OnEnter", function(self) self:PlaceIris() end)
    b:HookScript("OnLeave", function(self) self:PlaceIris() end)
    HookTip(b, nil)
    return b
end

-- The eye on my run's card: what it says and what a click does.
local function FillEye(eye, run)
    local GF = GFm()
    local listed, forRun, since = GF:GetListing(run)
    local d = R():GetDungeon(run.d)
    local where = (d and d.name or run.d) .. (run.h and " (Heroic)" or "")
    eye:SetLooking(forRun)
    if forRun then
        local mins = since and max(1, floor((ns.Util.Now() - since) / 60))
        local n = #GF:GetCandidates(run)
        local lines = { "In the Group Finder" .. (mins and S:Wrap("SUB", " · " .. mins .. " min") or ""),
            "Listed as " .. where .. ". Players looking for it there, and anyone who whispers you, show up on your run." }
        -- (only PUG_ROWS fit under the run: setting some aside shows the next ones)
        if n > PUG_ROWS then
            lines[#lines + 1] = S:Wrap("GOLD", n .. " players found: the first " .. PUG_ROWS .. " show under your run. Set some "
                .. "aside to see the others.")
        end
        lines[#lines + 1] = S:Wrap("SUB", "Click to take it out. It stays on the guild's board.")
        eye.tipLines = lines
    else
        eye.tipLines = { "Group Finder", "Lists your run in Blizzard's Group Finder as " .. where .. ". Players looking "
            .. "for it there, and anyone who whispers you, show up on your run.",
            listed and S:Wrap("SUB", "Your group is listed there for another dungeon: this switches it.") or nil }
    end
    eye.onClick = function()
        if select(2, GF:GetListing(run)) then
            GF:Unlist()
        else
            local ok, why = GF:List(run)
            if not ok and why then ns:Print("%s", why) end
        end
        HideTip()
    end
end

-- A player from outside the guild: class, name, level and roles, what they whispered or wrote, Invite, whisper, set
-- aside. The row's tooltip has all of it.
local function NewPugRow(c)
    local r = CreateFrame("Button", nil, c)
    r:SetHeight(REQ_H)
    r.line = UI():Rule(r, { layer = "BORDER" })
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(22, 22)
    r.icon:SetPoint("LEFT", 0, 0)
    r.name = UI():Text(r, "emph", "TEXT")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
    r.info = UI():Text(r, "body", "SUB")
    r.info:SetPoint("LEFT", r.name, "RIGHT", 7, 0)
    r.text = UI():Text(r, "body", "TEXT")
    r.text:SetPoint("LEFT", r.info, "RIGHT", 8, 0)
    r.no = UI():CreateIconButton(r, 22, NO_TEX, nil, function(self) if self.onClick then self.onClick() end end)
    r.no.icon:ClearAllPoints()
    r.no.icon:SetPoint("TOPLEFT", 4, -4)
    r.no.icon:SetPoint("BOTTOMRIGHT", -4, 4)
    r.no:SetPoint("RIGHT", 0, 0)
    HookTip(r.no, { "Not this one", "Sets them aside for this run." })
    r.say = UI():CreateTipIconButton(r, 22, UI().ICON.whisper, "Whisper", "Starts a whisper to them in the chat box.",
        function(self) if self.onClick then self.onClick() end end)
    r.say:SetPoint("RIGHT", r.no, "LEFT", -4, 0)
    r.yes = UI():CreateSleekButton(r, "Invite", 62, 22, function(self) if self.onClick then self.onClick() end end,
        "secondary")
    r.yes:SetPoint("RIGHT", r.say, "LEFT", -5, 0)
    r.state = UI():Text(r, "body", "TEXT")
    r.state:SetPoint("RIGHT", r.say, "LEFT", -10, 0)
    r:SetScript("OnEnter", function(self) if self.tip then UI():SetTextTooltip(self, self.tip, "ANCHOR_TOP") end end)
    r:SetScript("OnLeave", HideTip)
    r:SetScript("OnClick", function(self) if self.key then GFm():Whisper(self.key) end end)
    return r
end

-- The words of a whisper or note that fit in `width` (whole words, "..." when cut); full = it all fitted.
local function FitWords(fs, text, width)
    fs:SetText(text)
    if (fs:GetStringWidth() or 0) <= width then return true end
    local words = {}
    for w in text:gmatch("%S+") do words[#words + 1] = w end
    for n = #words - 1, 1, -1 do
        fs:SetText(tconcat(words, " ", 1, n) .. "...")
        if (fs:GetStringWidth() or 0) <= width then return false end
    end
    fs:SetText("")
    return false
end

local function PugTip(e)
    local lines = { UI():ColoredName(e.key, e.class) }
    local roles = {}
    for _, role in ipairs(R().ROLES) do
        if e.roles and e.roles[role] then roles[#roles + 1] = R().ROLE_LABEL[role] end
    end
    local bits = {}
    if e.level then bits[#bits + 1] = "Level " .. e.level end
    if e.area then bits[#bits + 1] = e.area end
    if #bits > 0 then lines[#lines + 1] = tconcat(bits, " · ") end
    if #roles > 0 then lines[#lines + 1] = "Listed as " .. tconcat(roles, ", ") end
    if e.text then lines[#lines + 1] = (e.whispered and "Whispered you: " or "Their note: ") .. "\"" .. e.text .. "\"" end
    if e.role and not e.invited then lines[#lines + 1] = S:Wrap("SUB", "Invite takes them as " .. ROLE_NAME[e.role] .. ".") end
    lines[#lines + 1] = S:Wrap("SUB", "Click to whisper")
    return lines
end

-- The Group Finder players of my run from y down (x = the rows' left edge), while it is listed there; returns the y
-- under them.
local function FillFinder(c, run, x, y, w)
    local GF = GFm()
    c.pugs = c.pugs or {}
    for _, r in ipairs(c.pugs) do r:Hide() end
    if not (GF and GF:IsAvailable() and R():IsNow(run)) or not select(2, GF:GetListing(run)) then return y end
    local cands = GF:GetCandidates(run)
    local canInvite = R():CanInvite()
    for i = 1, min(#cands, PUG_ROWS) do
        local e = cands[i]
        local r = c.pugs[i] or NewPugRow(c)
        c.pugs[i] = r
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", c, "TOPLEFT", x, y)
        r:SetPoint("TOPRIGHT", c, "TOPRIGHT", -12, y)
        r.key = e.key
        if e.class then UI():ClassIcon(r.icon, e.class) else r.icon:Hide() end
        r.name:SetText(UI():ColoredName(e.key, e.class))
        local icons = {}
        for _, role in ipairs(R().ROLES) do
            if e.roles[role] then icons[#icons + 1] = UI():RoleIconText(role, 12) end
        end
        local info = tconcat(icons, "")
        if e.level then info = info .. (info ~= "" and " " or "") .. e.level end
        r.info:SetText(info)
        local key = e.key
        local rightW = 22 + 4 + 22 + 5 + 62
        if e.invited then
            r.yes:Hide()
            r.state:SetText(S:Wrap("SUB", "Invited"))
            r.state:Show()
            rightW = 22 + 4 + 22 + 10 + (r.state:GetStringWidth() or 40)
        else
            r.state:Hide()
            r.yes:Show()
            r.yes:SetEnabled(canInvite)
            r.yes.onClick = function()
                local ok, why = GF:Invite(key)
                if not ok and why then ns:Print("%s", why) end
            end
        end
        r.say.onClick = function() GF:Whisper(key) end
        r.no.onClick = function() GF:Dismiss(key) end
        local left = 22 + 8 + (r.name:GetStringWidth() or 60) + 7 + (r.info:GetStringWidth() or 0) + 8
        local room = (w - x - 12) - left - rightW - 10
        local quote = e.text and ((e.whispered and (UI():AtlasIconText(UI().ICON.whisper, 11, GOLD) .. " ") or "")
            .. "\"" .. e.text .. "\"") or nil
        if quote and room > 40 then
            r.text:SetWidth(room)
            FitWords(r.text, quote, room)
            r.text:Show()
        else
            r.text:Hide()
        end
        r.tip = PugTip(e)
        r:Show()
        y = y - REQ_H
    end
    return y
end

-- Fills a card. opts = { width, mine = my own run (requests + free members), compact = the sheet's preview }.
-- Returns the card's height.
local function FillCard(c, run, opts)
    local w = opts.width
    local compact = opts.compact
    local mine = opts.mine
    local artW = compact and 112 or ART_W
    local slot = compact and 26 or SLOT
    local slotGap = compact and 4 or SLOT_GAP
    local actW = compact and 0 or ACT_W
    c:SetWidth(w)
    c:SetTone("card")
    c:SetSelected(mine and not compact)
    -- a run the page was opened on (a chat link, the calendar) lights up for a moment: the focus edge
    local focused = not compact and state.focus == run.id and GetTime() < (state.focusUntil or 0)
    if focused then UI():SetEdgeColor(c, S:Color("EDGE_FOCUS")) end
    SetArt(c, run.d, artW, CARD_H - 2, S.C.CARD)
    c.skull:ClearAllPoints()
    c.skull:SetPoint("BOTTOMLEFT", c.art, "BOTTOMLEFT", 7, 7)
    c.skull:SetShown(run.h and true or false)
    c.heroic:SetShown(run.h and true or false)

    -- the slots, right-aligned before the action
    local fits = R():FitsMe(run)
    local blocked = (not mine) and R():GetBlocker(run.d, run.h)
    local dim = blocked and not compact
    local slots = R():GetSlots(run)
    local slotsW = 5 * slot + 4 * slotGap
    local slotsRight = w - actW - (compact and 12 or 14)
    for i, s in ipairs(c.slots) do
        local d = slots[i]
        s:SetSize(slot, slot)
        s.ring:SetSize(slot, slot)
        s.fill:SetSize(slot - 2, slot - 2)
        s.class:SetSize(slot - 2, slot - 2)
        s:ClearAllPoints()
        s:SetPoint("TOPLEFT", c, "TOPLEFT", slotsRight - slotsW + (i - 1) * (slot + slotGap), -(CARD_H - slot) / 2)
        if d then
            local wants = d.empty and fits == d.role and not blocked and not compact
            FillSlot(s, d, wants, dim)
            -- my run: a click on somebody's place sets the role they play (a pug who whispered me is DPS until then)
            if mine and not compact and not d.empty then
                local key = d.key
                s.onPick = function(self) ns.DungeonsUI:OpenRoleMenu(self, key) end
                s.tip[#s.tip + 1] = S:Wrap("SUB", "Click to change the role")
            end
            s:Show()
        else
            s:Hide()
        end
    end

    -- texts
    local textX = artW + 4
    local textW = slotsRight - slotsW - 12 - textX
    local full, short = DungeonName(run)
    FitName(c.t1, full, short, textW - (run.no and 20 or 0), compact and "emph" or "title")
    c.t1:SetTextColor(dim and 0.55 or 1, dim and 0.55 or 1, dim and 0.55 or 1)
    -- no leader on my own card, nor in the sheet's narrow preview (it's me; "Tomorrow 21:00" needs the room)
    local leader = run.o == Me() and "" or (UI():ColoredName(run.o) .. S:Wrap("SUB", " · "))
    c.t2:SetText(leader .. S:Wrap("SUB", WhenText(run)))
    c.t2:SetAlpha(dim and 0.55 or 1)
    local hint, itemID, items
    if not compact then hint, itemID, items = HintFor(run) end
    c.t3:SetText(hint or "")
    c.t3:SetShown(hint ~= nil)
    c.hint.itemID = itemID
    c.hint.extra = items and #items > 1 and function(tt)
        tt:AddLine(" ")
        tt:AddLine("Also drops your BiS:", S:RGB("GOLD"))
        for i = 2, #items do tt:AddLine(ItemLinkText(items[i])) end
    end or nil
    c.hint:SetShown(itemID ~= nil)
    local lines = hint and 3 or 2
    local top = (CARD_H - (lines == 3 and 54 or 36)) / 2
    c.t1:ClearAllPoints()
    c.t1:SetPoint("TOPLEFT", c, "TOPLEFT", textX, -top)
    c.t2:ClearAllPoints()
    c.t2:SetPoint("TOPLEFT", c.t1, "BOTTOMLEFT", 0, -3)
    c.t2:SetWidth(textW)
    c.t3:ClearAllPoints()
    c.t3:SetPoint("TOPLEFT", c.t2, "BOTTOMLEFT", 0, -3)
    c.t3:SetWidth(textW)
    c.notes:ClearAllPoints()
    c.notes:SetPoint("LEFT", c.t1, "LEFT", min(c.t1:GetStringWidth() or 0, textW - 18) + 6, 0)
    c.notes.note = run.no
    c.notes:SetShown(run.no ~= nil and not compact)

    -- the action
    c.btn:Hide()
    c.more:Hide()
    if c.share then c.share:Hide() end
    if c.eye then
        c.eye:SetLooking(false)
        c.eye:Hide()
    end
    c.runId = run.id
    if mine then
        c.more:ClearAllPoints()
        c.more:SetPoint("RIGHT", c, "TOPRIGHT", -12, -CARD_H / 2)
        c.more:SetScript("OnClick", function(self) ns.DungeonsUI:OpenMineMenu(self) end)
        c.more:Show()
        -- Share, the Group Finder eye (a run happening now), More
        local left = c.more
        local GF = GFm()
        if not compact and GF and GF:IsAvailable() and R():IsNow(run) then
            c.eye = c.eye or NewEye(c)
            c.eye:ClearAllPoints()
            c.eye:SetPoint("RIGHT", c.more, "LEFT", -4, 0)
            FillEye(c.eye, run)
            c.eye:Show()
            left = c.eye
        end
        if c.share then
            c.share:ClearAllPoints()
            c.share:SetPoint("RIGHT", left, "LEFT", -4, 0)
            c.share:Show()
        end
    elseif not compact and not R():IsInRun(run) then
        local a = R():GetAsked(run.id)
        local inv = R():GetInvite()
        local tinted = false
        c.btn:ClearAllPoints()
        c.btn:SetPoint("RIGHT", c, "TOPRIGHT", -12, -CARD_H / 2)
        if inv and inv.run == run.id then
            c.btn:SetText("Accept")
            c.btn:SetKind("primary")
            c.btn:SetTint(0.3, 0.9, 0.4)
            tinted = true
            c.btn.onClick = function() R():AnswerInvite(true) end
            c.btn.tip = { UI():ColoredName(inv.from) .. S:Wrap("SUB", " invites you"), "Click to join the party. The cross on "
                .. "the pop-up declines." }
            c.btn:Show()
        elseif a and a.st == "asked" then
            c.btn:SetText("Asked")
            c.btn:SetKind("chosen")
            c.btn.onClick = function() R():CancelJoin(run.id) end
            c.btn.tip = { "You asked to join", "Click to take it back." }
            c.btn:Show()
        elseif a and a.st == "invited" then
            c.btn:SetText("Invited")
            c.btn:SetKind("chosen")
            c.btn:SetTint(0.3, 0.9, 0.4)
            tinted = true
            c.btn.onClick = nil
            c.btn.tip = { "You're invited", "Accept the party invite to join." }
            c.btn:Show()
        elseif fits and not blocked and not (a and a.st == "declined") and not R():IsGrouped() then
            c.btn:SetText("Join")
            c.btn:SetKind("primary")
            c.btn:SetTint(nil)
            c.btn.onClick = function()
                local ok, why = R():Join(run.id)
                if not ok and why then ns:Print("%s", why) end
            end
            c.btn.tip = { "Join", "Asks " .. ns.Util.ShortName(run.o) .. " to take you as " .. ROLE_NAME[fits] .. ".",
                R():GetMine() and S:Wrap("WARN", "Your own run comes off the board when you join.") or nil }
            c.btn:Show()
        end
        if c.btn:IsShown() then
            if not tinted then c.btn:SetTint(nil) end
            c.btn:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
            c.btn:SetScript("OnEnter", function(self) if self.tip then UI():SetTextTooltip(self, self.tip, "ANCHOR_TOP") end end)
            c.btn:SetScript("OnLeave", HideTip)
        end
    end

    -- my run: who asks, and who is up for a run and fits
    HideReqRows(c)
    local h = CARD_H
    if mine and not compact then
        local x = textX
        local y = -CARD_H + 2
        local reqs = R():GetRequests(run.id)
        for i, q in ipairs(reqs) do
            local r = c.reqs[i] or NewReqRow(c)
            c.reqs[i] = r
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", c, "TOPLEFT", x, y)
            r:SetPoint("TOPRIGHT", c, "TOPRIGHT", -12, y)
            local classFile = R():GetClass(q.key)
            UI():ClassIcon(r.icon, classFile)
            r.name:SetText(UI():ColoredName(q.key, classFile))
            local spec = R():GetSpecLabel(q.key)
            r.spec:SetText(UI():RoleIconText(q.r, 12) .. " " .. (spec or R().ROLE_LABEL[q.r]))
            r.tag:SetShown(q.b and true or false)
            r.tag.who = ns.Util.ShortName(q.key) .. "'s"
            local key = q.key
            if q.st == "invited" then
                r.yes:Hide()
                r.state:SetText(S:Wrap("SUB", "Invited"))
                r.state:Show()
            else
                r.state:Hide()
                r.yes:Show()
                r.yes.onClick = function() R():Accept(run.id, key) end
            end
            r.no.onClick = function() R():Decline(run.id, key) end
            r:Show()
            y = y - REQ_H
        end
        -- members up for a run whose role is open (not asking already)
        local open = R():GetOpenRoles(run)
        local asking = {}
        for _, q in ipairs(reqs) do asking[q.key] = true end
        local fitting = {}
        for _, e in ipairs(R():GetUpForRun()) do
            local ok = false
            for role in pairs(e.roles) do if open[role] then ok = true end end
            if ok and not asking[e.key] and not (run.h and R():IsSaved(e.key, run.d)) then fitting[#fitting + 1] = e end
        end
        if #fitting > 0 then
            local r = c.free[1]
            if not r then
                r = CreateFrame("Frame", nil, c)
                r:SetHeight(REQ_H)
                r.line = UI():Rule(r, { layer = "BORDER" })
                r.label = UI():Text(r, "body", "SUB")
                r.label:SetPoint("LEFT", 0, 0)
                r.label:SetText("Up for a run")
                r.chips, r.invites, r.busy = {}, {}, {}
                c.free[1] = r
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", c, "TOPLEFT", x, y)
            r:SetPoint("TOPRIGHT", c, "TOPRIGHT", -12, y)
            local cx = (r.label:GetStringWidth() or 60) + 10
            local room = w - x - 12
            for i = 1, max(#r.chips, #fitting) do
                local e = fitting[i]
                local chip, inv, busy = r.chips[i], r.invites[i], r.busy[i]
                if e then
                    if not chip then
                        chip = NewPersonChip(r)
                        inv = UI():CreateSleekButton(r, "Invite", 56, 22, nil, "secondary")
                        busy = UI():Text(r, "body", "TEXT")
                        busy:SetText(S:Wrap("SUB", "In a group"))
                        r.chips[i], r.invites[i], r.busy[i] = chip, inv, busy
                    end
                    FillChip(chip, e)
                    -- in a group: no invite reaches them, so no Invite (they show as busy)
                    local need = chip:GetWidth() + 4 + (e.grouped and (busy:GetStringWidth() or 60) + 2 or 56) + 10
                    if cx + need <= room then
                        chip:ClearAllPoints()
                        chip:SetPoint("LEFT", r, "LEFT", cx, 0)
                        local key = e.key
                        if e.grouped then
                            inv:Hide()
                            busy:ClearAllPoints()
                            busy:SetPoint("LEFT", chip, "RIGHT", 6, 0)
                            busy:Show()
                        else
                            busy:Hide()
                            inv:ClearAllPoints()
                            inv:SetPoint("LEFT", chip, "RIGHT", 4, 0)
                            local done = state.invited[key]
                            inv:SetText(done and "Invited" or "Invite")
                            inv:SetEnabled(not done)
                            inv:SetScript("OnClick", function()
                                if R():InviteFree(key) then
                                    state.invited[key] = true
                                    ns.DungeonsUI:Refresh()
                                end
                            end)
                            inv:Show()
                        end
                        chip:Show()
                        cx = cx + need
                    else
                        chip:Hide()
                        inv:Hide()
                        busy:Hide()
                    end
                elseif chip then
                    chip:Hide()
                    inv:Hide()
                    busy:Hide()
                end
            end
            r:Show()
            y = y - REQ_H
        end
        y = FillFinder(c, run, x, y, w)
        h = -y + ((y < -CARD_H + 2) and 8 or 0)
        if h < CARD_H then h = CARD_H end
    end
    c:SetHeight(h)
    c.tip = (not compact) and CardTip(run) or nil
    return h
end


G.CARD_H, G.ART_W, G.STAR, G.ROLE_NAME, G.HEROIC_TEX = CARD_H, ART_W, STAR, ROLE_NAME, HEROIC_TEX
G.WhenText, G.DayLabel, G.DungeonName, G.ItemLinkText, G.HideTip = WhenText, DayLabel, DungeonName, ItemLinkText, HideTip
G.RedrawHoveredTip, G.HintFor, G.CardTip = RedrawHoveredTip, HintFor, CardTip
G.NewRunCard, G.FillCard, G.NewPersonChip, G.FillChip, G.Disc = NewRunCard, FillCard, NewPersonChip, FillChip, Disc
