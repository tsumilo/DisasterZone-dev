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

-- A group's name and its short form: "The Shattered Halls" / "Shattered Halls", "Gruul's Lair + Magtheridon's Lair" /
-- "Gruul + Mag", "Arena 3v3".
local function DungeonName(run)
    if R():GetKind(run) == "dungeon" then
        local d = R():GetDungeon(run.d)
        return d and d.name or tostring(run.d), d and d.short or nil
    end
    local short
    if run.k == "quest" and ns.GroupQuests and run.a and #run.a > 1 then
        -- several quests of one zone: the first one's name and how many more
        local first = ns.GroupQuests:GetName(run.a[1]) or R():GetName(run)
        local more = S:Wrap("GOLD", "  +" .. (#run.a - 1) .. (#run.a == 2 and " quest" or " quests"))
        return first .. more, first .. more
    end
    if run.k == "raid" and ns.ItemDB and ns.ItemDB.RaidShort then
        local parts = {}
        for _, key in ipairs(run.a or {}) do parts[#parts + 1] = ns.ItemDB:RaidShort(key) or key end
        short = tconcat(parts, " + ")
    end
    return R():GetName(run), short
end

-- What the art's corner says: "Heroic", "10 player", "Rated 1650+", "Skirmish", "Premade", "Raid, no queue",
-- "Group quest", "5 players".
local function Kicker(run)
    local kind = R():GetKind(run)
    if kind == "dungeon" then return run.h and "Heroic" or nil end
    if kind == "raid" then return R():GetSize(run) .. " player" end
    if kind == "pvp" then
        local mode
        for _, p in ipairs(R():GetActivities("pvp")) do
            if p.key == run.a[1] then mode = p.mode end
        end
        if mode == "arena" then return run.pr and ("Rated" .. (run.mr and (" " .. run.mr .. "+") or "")) or "Skirmish" end
        return mode == "world" and "Raid, no queue" or "Premade"
    end
    if kind == "quest" then
        -- (the zone the quests are in)
        local GQ = ns.GroupQuests
        local q = GQ and GQ:Get(run.a and run.a[1])
        local z = q and GQ:GetZone(q.zone)
        return z and z.name or "Group quest"
    end
    return R():GetSize(run) .. " players"
end

-- Asks to join a group; first asks me when it clashes with a raid I signed up for. done(ok) after a join (optional).
local function TryJoin(run, done)
    local function go()
        local ok, why = R():Join(run.id)
        if not ok and why then ns:Print("%s", why) end
        if done then done(ok, why) end
    end
    local clash = R():GetOverlap(run)
    if not (clash and ns.Popup and ns.Popup.Confirm) then return go() end
    local RP = ns.RaidPlan
    ns.Popup:Confirm({ key = "dz-group-clash", title = "It clashes with a raid",
        text = "You signed up for " .. ((RP and RP.GetRaidName and RP:GetRaidName(clash)) or "a raid") .. " at "
            .. date("%H:%M", clash.t) .. ", around the time of this group. Join anyway?",
        ok = "Join anyway", alert = true, onAccept = function() go() end })
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
    s:SetScript("OnMouseUp", function(self, button)
        if self.onPick then self.onPick(self)   -- (my run: the role)
        elseif button == "LeftButton" and self:GetParent().onToggle then self:GetParent().onToggle() end
    end)
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
    c.heroic = UI():Text(c, "small", "GOLD")     -- the corner's word: "Heroic", "10 player", "Rated 1650+", ...
    c.heroic:SetText("Heroic")
    -- (1.5) the instance's icon in a gold ring, top left on the art; the art again, faint, behind an opened card
    c.ring = UI():CreateFace(c, 28)
    c.ring:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -10)
    c.bg = c:CreateTexture(nil, "BACKGROUND", nil, 6)
    c.bg:SetPoint("TOPLEFT", 1, -1)
    c.bg:SetPoint("BOTTOMRIGHT", -1, 1)
    c.bgShade = c:CreateTexture(nil, "BACKGROUND", nil, 7)
    c.bgShade:SetPoint("TOPLEFT", c.bg, "TOPLEFT")
    c.bgShade:SetPoint("BOTTOMRIGHT", c.bg, "BOTTOMRIGHT")
    c.bgShade:SetColorTexture(1, 1, 1, 1)
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

-- A group's art in a w x h box (left part of the card), fading into the card on its right; its icon in the ring.
local function SetArt(c, run, w, h, bg)
    local file, l, r, t, b = R():GetGroupArt(run, w, h)
    local icon, il, ir, it, ib = R():GetGroupIcon(run)
    if icon then
        c.ring:SetPhoto(icon)
        c.ring.photo:SetTexCoord(il, ir, it, ib)
        c.ring:SetRing("GOLD")
        c.ring:Show()
    else
        c.ring:Hide()
    end
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
        local who, have = {}, { tank = 0, healer = 0, dps = 0 }
        for _, s in ipairs(R():GetSlots(run)) do
            if not s.empty then
                who[#who + 1] = UI():RoleIconText(s.role, 12) .. " " .. UI():ColoredName(s.key, s.class)
                have[s.role] = have[s.role] + 1
            end
        end
        if R():GetSize(run) > 5 then
            -- a big group: how full each role is (the opened card shows who)
            local want, parts = R():GetWant(run), {}
            for _, role in ipairs(R().ROLES) do
                if (want[role] or 0) > 0 then
                    parts[#parts + 1] = UI():RoleIconText(role, 12) .. " " .. have[role] .. "/" .. want[role]
                end
            end
            lines[#lines + 1] = tconcat(parts, "   ")
        elseif #who > 0 then
            lines[#lines + 1] = tconcat(who, "   ")
        end
        if run.no then lines[#lines + 1] = S:Wrap("SUB", "\"" .. run.no .. "\"") end
        local drops = R():GetGroupBiSDrops(run)
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

-- A raid group's loot method: "Rolls", "Soft reserve · 1", "Loot council".
local LOOT_TEXT = { roll = "Rolls", sr = "Soft reserve", lc = "Loot council" }
local function LootText(run)
    if not run.lo then return nil end
    return LOOT_TEXT[run.lo] .. (run.lo == "sr" and (" · " .. (run.lr or 1)) or "")
end

-- What a group is about when nothing else is said: a raid's loot method and bosses, else the leader's note.
local function AboutLine(run)
    if run.k == "raid" then
        local bosses = run.bo and (#run.bo .. (#run.bo == 1 and " boss" or " bosses")) or "Full clear"
        return S:Wrap("TEXT", LootText(run) or "Rolls") .. S:Wrap("SUB", " · " .. bosses)   -- (the note: its icon)
    end
    -- (the leader's own words: in quotes, as on the opened card)
    return run.no and S:Wrap("SUB", "\"" .. run.no .. "\"") or nil
end

-- The one hint under a run: what stops me, else what drops my BiS, else (a group of another kind) what it is about.
-- Returns text, itemID (for its tooltip).
local function HintFor(run)
    if run.o == Me() then return nil end
    local a = R():GetAsked(run.id)
    if a and a.st == "declined" then return S:Wrap("SUB", ns.Util.ShortName(run.o) .. " said not this time") end
    local block = R():GetGroupBlocker(run)
    if block then return S:Wrap("WARN", UI():LockIcon(12) .. " " .. block) end
    if R():IsGrouped() and not R():IsInRun(run) and R():FitsMe(run) then
        return S:Wrap("SUB", "You're in a group: leave it to join")
    end
    local drops = R():GetGroupBiSDrops(run)
    if #drops > 0 then
        local more = #drops > 1 and S:Wrap("SUB", " +" .. (#drops - 1)) or ""
        return S:Wrap("GOLD", STAR .. " Drops your BiS ") .. ItemLinkText(drops[1]) .. more, drops[1], drops
    end
    if R():GetKind(run) ~= "dungeon" then return AboutLine(run) end
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

---------------------------------------------------------------------------
-- Groups bigger than a party: a meter per role on the card; the opened card (seats up to 10, raid frames above)
---------------------------------------------------------------------------

local METER_W, METER_GAP, METER_H = 54, 10, 26
local SEAT_W, SEAT_FACE, SEAT_H = 60, 38, 64
local SEAT_GROUP_GAP = 20                -- between the role groups of seats (a faint line in the middle)
local CELL_H, CELL_GAP, CELL_COL_GAP = 21, 2, 8
local OPEN_PAD = 16
local RequestHints   -- (forward: the request rows' hints, set before FillCard)
local SEATS_MAX = 10                     -- bigger groups open as raid frames
local SEG = { 0.78, 0.78, 0.82, 0.75 }

local function ShortRole(role) return role == "dps" and "damage dealer" or role end

-- How many of each role a group has: { tank = n, healer = n, dps = n }.
local function Have(run)
    local have = { tank = 0, healer = 0, dps = 0 }
    for _, s in ipairs(R():GetSlots(run)) do
        if not s.empty then have[s.role] = have[s.role] + 1 end
    end
    return have
end

-- Three meters (tanks, healers, DPS): the role's icon, "have/want", a bar of the places (one segment each up to 16);
-- the role that wants me in gold.
local function NewMeters(c)
    local m = CreateFrame("Frame", nil, c)
    m:SetSize(3 * METER_W + 2 * METER_GAP, METER_H)
    m.cols = {}
    for i = 1, 3 do
        local col = CreateFrame("Frame", nil, m)
        col:SetSize(METER_W, METER_H)
        col.icon = col:CreateTexture(nil, "ARTWORK")
        col.icon:SetSize(15, 15)
        col.icon:SetPoint("TOPLEFT", 0, 0)
        col.text = UI():Text(col, "body", "TEXT")
        col.text:SetPoint("LEFT", col.icon, "RIGHT", 4, 0)
        col.bg = col:CreateTexture(nil, "ARTWORK")
        col.bg:SetPoint("BOTTOMLEFT", 0, 0)
        col.bg:SetSize(METER_W, 5)
        col.bg:SetColorTexture(unpack(S.C.HAIRLINE))
        col.segs = {}
        col:EnableMouse(true)
        col:SetScript("OnEnter", function(self) if self.tip then UI():SetTextTooltip(self, self.tip, "ANCHOR_TOP") end end)
        col:SetScript("OnLeave", HideTip)
        m.cols[i] = col
    end
    return m
end

local function FillMeters(m, run, fitRole, dim)
    local want, have = R():GetWant(run), Have(run)
    local shown = 0
    for _, role in ipairs(R().ROLES) do
        local w = want[role] or 0
        if w > 0 then
            shown = shown + 1
            local col = m.cols[shown]
            col:ClearAllPoints()
            col:SetPoint("TOPLEFT", m, "TOPLEFT", (shown - 1) * (METER_W + METER_GAP), 0)
            UI():SetRoleIcon(col.icon, role)
            local h, fit = have[role], fitRole == role
            local full = h >= w
            col.text:SetText(S:Wrap(fit and "GOLD" or (full and "SUB" or "TEXT"), tostring(h)) .. S:Wrap("SUB", "/" .. w))
            local n = min(w, 16)
            local segW = (METER_W - (n - 1)) / n
            local filled = floor(h * n / w + 0.5)
            for i = 1, n do
                local t = col.segs[i] or col:CreateTexture(nil, "ARTWORK", nil, 1)
                col.segs[i] = t
                t:ClearAllPoints()
                t:SetPoint("BOTTOMLEFT", col, "BOTTOMLEFT", (i - 1) * (segW + 1), 0)
                t:SetSize(segW, 5)
                if i <= filled then
                    t:SetColorTexture(SEG[1], SEG[2], SEG[3], full and 0.4 or SEG[4])
                elseif fit then
                    t:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.45)
                else
                    t:SetColorTexture(0, 0, 0, 0)
                end
                t:Show()
            end
            for i = n + 1, #col.segs do col.segs[i]:Hide() end
            col.tip = { R().ROLE_LABEL[role] .. ": " .. h .. " of " .. w, fit and S:Wrap("GOLD", "They want you.") or nil }
            col:Show()
        end
    end
    for i = shown + 1, 3 do m.cols[i]:Hide() end
    m:SetWidth(max(1, shown * METER_W + (shown - 1) * METER_GAP))
    m:SetAlpha(dim and 0.42 or 1)
    return m:GetWidth()
end

-- A seat: the player's class in a ring of their class colour, the role on its corner, the leader's crown, the name
-- under it. An open place: a faint ring with its role; the place that wants me: my own class, faded, pulsing gold.
local function NewSeat(parent)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(SEAT_W, SEAT_H)
    s.face = UI():CreateFace(s, SEAT_FACE)
    s.face:SetPoint("TOP", 0, -3)
    -- (the role badge and the crown on a frame over the face: the face is a frame of its own, drawn over the seat's
    -- own textures whatever their layer)
    s.badges = CreateFrame("Frame", nil, s)
    s.badges:SetAllPoints(s.face)
    s.badges:SetFrameLevel(s.face:GetFrameLevel() + 2)
    s.role = s.badges:CreateTexture(nil, "OVERLAY", nil, 2)
    s.role:SetSize(15, 15)
    s.role:SetPoint("CENTER", s.face, "BOTTOMRIGHT", -4, 4)
    s.crown = s.badges:CreateTexture(nil, "OVERLAY", nil, 3)
    s.crown:SetSize(13, 13)
    s.crown:SetPoint("CENTER", s.face, "TOPRIGHT", -5, -2)
    UI():SetGlyph(s.crown, "crown", "GOLD")
    s.open = s.badges:CreateTexture(nil, "OVERLAY", nil, 1)
    s.open:SetSize(18, 18)
    s.open:SetPoint("CENTER", s.face, "CENTER")
    s.name = UI():Text(s, "small", "TEXT", { justify = "CENTER" })
    s.name:SetPoint("TOP", s.face, "BOTTOM", 0, -6)
    s.pulse = s.face:CreateAnimationGroup()
    local a = s.pulse:CreateAnimation("Alpha")
    a:SetFromAlpha(0.45)
    a:SetToAlpha(0.9)
    a:SetDuration(1.2)
    s.pulse:SetLooping("BOUNCE")
    s:EnableMouse(true)
    s:SetScript("OnEnter", function(self) if self.tip then UI():SetTextTooltip(self, self.tip, "ANCHOR_TOP") end end)
    s:SetScript("OnLeave", HideTip)
    return s
end

-- d = a slot ({ key, role, class, owner } or { empty = true, role }); you = this open place is mine to take.
local function FillSeat(s, d, you)
    s.pulse:Stop()
    s.face:SetAlpha(1)
    if d.empty and not you then
        s.face:SetPhoto(nil)
        s.face.photo:Hide()
        s.face:SetRing({ 1, 1, 1, 0.16 })
        UI():SetRoleIcon(s.open, d.role)
        s.open:SetDesaturated(true)
        s.open:SetAlpha(0.35)
        s.open:Show()
        s.role:Hide()
        s.crown:Hide()
        s.name:SetText(S:Wrap("SUB", "open"))
        s.name:SetAlpha(0.6)
        s.tip = { "Open place: " .. R().ROLE_LABEL[d.role] }
        return
    end
    s.open:Hide()
    s.name:SetAlpha(1)
    s.face:SetPhoto(nil)
    local class = d.empty and R():GetClass(Me()) or d.class
    UI():ClassIcon(s.face.photo, class)
    s.face.photo:Show()
    UI():SetRoleIcon(s.role, d.role)
    s.role:Show()
    if d.empty then
        s.face:SetRing("GOLD")
        s.crown:Hide()
        s.name:SetText(S:Wrap("GOLD", "You"))
        s.pulse:Play()
        s.tip = { "Your place", "They want a " .. ShortRole(d.role) .. ": Join takes it." }
    else
        local r, g, b = UI():ClassColor(class)
        s.face:SetRing({ r, g, b, 1 })
        s.crown:SetShown(d.owner and true or false)
        s.name:SetText(UI():ColoredName(d.key, class))
        local spec = R():GetSpecLabel(d.key)
        s.tip = { UI():ColoredName(d.key, class), R().ROLE_LABEL[d.role] .. (spec and (" · " .. spec) or ""),
                  d.owner and S:Wrap("SUB", "Leads the group") or nil }
    end
end

-- A raid frame cell: a bar in the player's class colour, the role, the name, the leader's crown; open: faint;
-- mine to take: gold.
local function NewCell(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(CELL_H)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(1, 1, 1, 1)
    UI():AddEdges(f, "BORDER")
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(12, 12)
    f.icon:SetPoint("LEFT", 4, 0)
    f.name = UI():Text(f, "small", "TEXT")
    f.name:SetPoint("LEFT", f.icon, "RIGHT", 4, 0)
    f.name:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.crown = f:CreateTexture(nil, "OVERLAY")
    f.crown:SetSize(11, 11)
    f.crown:SetPoint("RIGHT", -4, 0)
    UI():SetGlyph(f.crown, "crown", "TEXT")
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self) if self.tip then UI():SetTextTooltip(self, self.tip, "ANCHOR_TOP") end end)
    f:SetScript("OnLeave", HideTip)
    return f
end

local function FillCell(f, d, you)
    UI():SetRoleIcon(f.icon, d.role)
    f.icon:SetDesaturated(d.empty and not you)
    f.icon:SetAlpha((d.empty and not you) and 0.35 or 1)
    f.crown:SetShown((not d.empty) and d.owner and true or false)
    if you then
        f.bg:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.12)
        UI():SetEdgeColor(f, GOLD[1], GOLD[2], GOLD[3], 1)
        f.name:SetText(S:Wrap("GOLD", "You · " .. ShortRole(d.role)))
        f.tip = { "Your place", "They want a " .. ShortRole(d.role) .. ": Join takes it." }
    elseif d.empty then
        f.bg:SetColorTexture(S.C.HOVER[1], S.C.HOVER[2], S.C.HOVER[3], 0.025)
        UI():SetEdgeColor(f, 1, 1, 1, 0.12)
        f.name:SetText(S:Wrap("SUB", "open"))
        f.tip = { "Open place: " .. R().ROLE_LABEL[d.role] }
    else
        local r, g, b = UI():ClassColor(d.class)
        f.bg:SetColorTexture(1, 1, 1, 1)
        UI():Gradient(f.bg, "VERTICAL", { r * 0.42, g * 0.42, b * 0.42, 1 }, { r * 0.72, g * 0.72, b * 0.72, 1 })
        UI():SetEdgeColor(f, 0, 0, 0, 0.85)
        f.name:SetText("|cffffffff" .. (ns.Util.ShortName(d.key) or d.key) .. "|r")
        local spec = R():GetSpecLabel(d.key)
        f.tip = { UI():ColoredName(d.key, d.class), R().ROLE_LABEL[d.role] .. (spec and (" · " .. spec) or ""),
                  d.owner and S:Wrap("SUB", "Leads the group") or nil }
    end
end

-- The chips of an opened card: what the group is (loot, bosses, mode, size), a glyph each.
local function OpenChips(run)
    local kind, out = R():GetKind(run), {}
    if kind == "raid" then
        local glyph = ({ roll = "games", sr = "reserve", lc = "ballot" })[run.lo or "roll"]
        out[#out + 1] = { glyph, LootText(run) or "Rolls" }
        out[#out + 1] = { "flag", run.bo and (#run.bo .. (#run.bo == 1 and " boss" or " bosses")) or "Full clear" }
    elseif kind == "dungeon" then
        out[#out + 1] = { "shield", run.h and "Heroic" or "Normal" }
    elseif kind == "quest" and ns.GroupQuests then
        -- the chain step of each quest that has one
        for _, id in ipairs(run.a or {}) do
            local q = ns.GroupQuests:Get(id)
            if q and q.step and q.steps and #out < 2 then
                out[#out + 1] = { "flag", (#run.a > 1 and (q.name .. ": ") or "") .. "part " .. q.step .. " of " .. q.steps }
            end
        end
    elseif kind == "pvp" then
        out[#out + 1] = { "trophy", Kicker(run) }
        if run.fc then out[#out + 1] = { "flag", "Flag carrier wanted" } end
    end
    out[#out + 1] = { "team", R():GetSize(run) .. " players" }
    return out
end

-- Why I fit (green) or what stops me (orange), as one line each.
local function OpenFit(run)
    local ok, bad = {}, {}
    local fits = R():FitsMe(run)
    local block = R():GetGroupBlocker(run)
    local kind = R():GetKind(run)
    if block then
        bad[#bad + 1] = block
    elseif R():IsInRun(run) then
        ok[#ok + 1] = "you're in this group"
    elseif fits then
        ok[#ok + 1] = "they want a " .. ShortRole(fits)
    else
        bad[#bad + 1] = "no open place fits your roles"
    end
    if not block and kind == "raid" then ok[#ok + 1] = "you're not saved" end
    if not block and kind == "dungeon" and run.h then ok[#ok + 1] = "not saved today" end
    if kind == "quest" and ns.GroupQuests then
        local n = 0
        for _, id in ipairs(run.a or {}) do
            if ns.GroupQuests:IsInMyLog(id) then n = n + 1 end
        end
        if n > 0 then ok[#ok + 1] = (#run.a > 1 and (n .. " of them") or "it's") .. " in your quest log" end
        if n == 0 then bad[#bad + 1] = "not in your quest log: pick it up first" end
    end
    -- (a hint, never a block: what a realm asks for changes with its phase)
    if not block and kind == "raid" then
        local miss = R():GetMissingAttunements(run)
        if #miss > 0 then bad[#bad + 1] = "check your attunement: " .. tconcat(miss, ", ") end
    end
    local lines = {}
    if #ok > 0 then lines[#lines + 1] = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12:0:0|t " .. S:Wrap("TEXT", tconcat(ok, " · ")) end
    if #bad > 0 then
        lines[#lines + 1] = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:12:12:0:0|t " .. S:Wrap("WARN", tconcat(bad, " · "))
    end
    return tconcat(lines, "\n")
end

local function NewOpen(c)
    local o = CreateFrame("Frame", nil, c)
    o.seats, o.labels, o.divs, o.cells, o.glabels, o.chips = {}, {}, {}, {}, {}, {}
    o.ruleL = o:CreateTexture(nil, "ARTWORK")
    o.ruleL:SetHeight(1)
    o.ruleR = o:CreateTexture(nil, "ARTWORK")
    o.ruleR:SetHeight(1)
    o.fit = UI():Text(o, "body", "TEXT", { wrap = true })
    o.join = UI():CreateSleekButton(o, "", 150, 26, function(self) if self.onClick then self.onClick() end end, "primary")
    o.join:SetScript("OnEnter", function(self) if self.tip then UI():SetTextTooltip(self, self.tip, "ANCHOR_TOP") end end)
    o.join:SetScript("OnLeave", HideTip)
    o.whisper = UI():CreateTipIconButton(o, 26, UI().ICON.whisper, "Whisper", "Opens a whisper to the leader.",
        function() if o.leader then
            local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
            if open then open("/w " .. ((Ambiguate and Ambiguate(o.leader, "none")) or o.leader) .. " ") end
        end end)
    if ns.Share and ns.Share.CreateButton then
        o.share = ns.Share:CreateButton(o, 26, function() return o.runId and ns.Share:RunRef(o.runId) or nil end,
            "Share this group")
    end
    return o
end

-- Lays out the opened part of a card (under its 72 px head) w wide; returns its height.
local function FillOpen(c, run, w)
    local o = c.open or NewOpen(c)
    c.open = o
    o:ClearAllPoints()
    o:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -CARD_H)
    o:SetWidth(w)
    o.runId, o.leader = run.id, run.o
    local slots = R():GetSlots(run)
    local fits = R():FitsMe(run)
    local blocked = R():GetGroupBlocker(run)
    local mineRole = (fits and not blocked and not R():IsInRun(run)) and fits or nil
    local y = 6
    local inner = w - 2 * OPEN_PAD
    for _, x in ipairs(o.seats) do x:Hide() end
    for _, x in ipairs(o.labels) do x:Hide() end
    for _, x in ipairs(o.divs) do x:Hide() end
    for _, x in ipairs(o.cells) do x:Hide() end
    for _, x in ipairs(o.glabels) do x:Hide() end
    if R():GetSize(run) <= SEATS_MAX then
        -- seats, by role, centred: TANKS 2/2 | HEALERS 1/3 | DAMAGE 4/5
        local want, have = R():GetWant(run), Have(run)
        local groups = {}
        for _, role in ipairs(R().ROLES) do
            if (want[role] or 0) > 0 or have[role] > 0 then
                local list = {}
                for _, d in ipairs(slots) do
                    if d.role == role then list[#list + 1] = d end
                end
                if #list > 0 then groups[#groups + 1] = { role = role, list = list } end
            end
        end
        local total = 0
        for i, gr in ipairs(groups) do
            gr.w = #gr.list * SEAT_W + (#gr.list - 1) * 4
            total = total + gr.w + (i > 1 and SEAT_GROUP_GAP or 0)
        end
        local x = OPEN_PAD + max(0, floor((inner - total) / 2))
        local si, li, di = 0, 0, 0
        local LABEL = { tank = "Tanks", healer = "Healers", dps = "Damage" }
        for i, gr in ipairs(groups) do
            if i > 1 then
                di = di + 1
                local d = o.divs[di] or o:CreateTexture(nil, "ARTWORK")
                o.divs[di] = d
                d:SetWidth(1)
                d:ClearAllPoints()
                d:SetPoint("TOPLEFT", o, "TOPLEFT", x + SEAT_GROUP_GAP / 2, -(y + 22))
                d:SetHeight(SEAT_H - 18)
                d:SetColorTexture(1, 1, 1, 1)
                UI():Gradient(d, "VERTICAL", { 1, 1, 1, 0 }, { 1, 1, 1, 0.12 })
                d:Show()
                x = x + SEAT_GROUP_GAP
            end
            li = li + 1
            local lb = o.labels[li] or UI():Text(o, "caps", "SUB", { justify = "CENTER" })
            o.labels[li] = lb
            local fitHere = mineRole == gr.role
            lb:SetText(UI():CapsText(LABEL[gr.role]) .. "  " .. S:Wrap(fitHere and "GOLD" or "SUB",
                (have[gr.role] or 0) .. "/" .. (want[gr.role] or 0)))
            lb:SetTextColor(S:Color(fitHere and "GOLD" or "SUB"))
            lb:ClearAllPoints()
            lb:SetPoint("TOP", o, "TOPLEFT", x + gr.w / 2, -y)
            lb:Show()
            local youDone = false
            for j, d in ipairs(gr.list) do
                si = si + 1
                local s = o.seats[si] or NewSeat(o)
                o.seats[si] = s
                local you = d.empty and mineRole == gr.role and not youDone
                if you then youDone = true end
                FillSeat(s, d, you)
                s:ClearAllPoints()
                s:SetPoint("TOPLEFT", o, "TOPLEFT", x + (j - 1) * (SEAT_W + 4), -(y + 16))
                s:Show()
            end
            x = x + gr.w
        end
        y = y + 16 + SEAT_H
    else
        -- raid frames: parties of five, as the game draws its raid frames; my place first among the open ones
        local cols = math.ceil(#slots / 5)
        local colW = floor((inner - (cols - 1) * CELL_COL_GAP) / cols)
        local youDone = false
        for gi = 1, cols do
            local gl = o.glabels[gi] or UI():Text(o, "caps", "SUB", { justify = "CENTER" })
            o.glabels[gi] = gl
            gl:SetText(UI():CapsText("Group " .. gi))
            gl:ClearAllPoints()
            gl:SetPoint("TOP", o, "TOPLEFT", OPEN_PAD + (gi - 1) * (colW + CELL_COL_GAP) + colW / 2, -y)
            gl:Show()
        end
        for i, d in ipairs(slots) do
            local f = o.cells[i] or NewCell(o)
            o.cells[i] = f
            local you = d.empty and mineRole == d.role and not youDone
            if you then youDone = true end
            FillCell(f, d, you)
            local gi, row = math.floor((i - 1) / 5), (i - 1) % 5
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", o, "TOPLEFT", OPEN_PAD + gi * (colW + CELL_COL_GAP), -(y + 15 + row * (CELL_H + CELL_GAP)))
            f:SetWidth(colW)
            f:Show()
        end
        y = y + 15 + 5 * (CELL_H + CELL_GAP)
    end
    o.ruleL:Show()
    o.ruleR:Show()
    o.fit:Show()
    -- the divider: a gold line fading out at both ends
    y = y + 10
    local half = floor(inner / 2)
    o.ruleL:ClearAllPoints()
    o.ruleL:SetPoint("TOPLEFT", o, "TOPLEFT", OPEN_PAD, -y)
    o.ruleL:SetWidth(half)
    o.ruleL:SetColorTexture(1, 1, 1, 1)
    UI():Gradient(o.ruleL, "HORIZONTAL", { GOLD[1], GOLD[2], GOLD[3], 0 }, { GOLD[1], GOLD[2], GOLD[3], 0.5 })
    o.ruleR:ClearAllPoints()
    o.ruleR:SetPoint("TOPLEFT", o.ruleL, "TOPRIGHT", 0, 0)
    o.ruleR:SetWidth(inner - half)
    o.ruleR:SetColorTexture(1, 1, 1, 1)
    UI():Gradient(o.ruleR, "HORIZONTAL", { GOLD[1], GOLD[2], GOLD[3], 0.5 }, { GOLD[1], GOLD[2], GOLD[3], 0 })
    y = y + 11
    -- the footer: the chips and why I fit on the left, the actions on the right
    local cx = OPEN_PAD
    local chips = OpenChips(run)
    for i, ch in ipairs(chips) do
        local p = o.chips[i] or UI():CreatePill(o, "mute", "", 20)
        o.chips[i] = p
        p:Set(ch[2], "mute", UI().ICON_ATLAS)
        local co = UI():IconCoords(UI().ICON[ch[1]] or UI().ICON.notes)
        p.icon:SetTexCoord(co[1], co[2], co[3], co[4])
        p.icon:SetVertexColor(S:Color("SUB"))
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", o, "TOPLEFT", cx, -y)
        p:Show()
        cx = cx + p:GetWidth() + 5
    end
    for i = #chips + 1, #o.chips do o.chips[i]:Hide() end
    local actW = 26 * 2 + 6 * 2 + 150
    o.fit:ClearAllPoints()
    o.fit:SetPoint("TOPLEFT", o, "TOPLEFT", OPEN_PAD, -(y + 27))
    o.fit:SetWidth(inner - actW - 16)
    o.fit:SetText(OpenFit(run))
    local fitH = max(14, o.fit:GetStringHeight() or 14)
    local footH = 27 + fitH
    -- Join as <role> (asked / invited: the state; a block: Whisper only)
    local a = R():GetAsked(run.id)
    o.join:SetTint(nil)
    if R():IsInRun(run) or run.o == Me() then
        o.join:Hide()
    elseif a and a.st == "asked" then
        o.join:SetText("Asked")
        o.join:SetKind("chosen")
        o.join.onClick = function() R():CancelJoin(run.id) end
        o.join.tip = { "You asked to join", "Click to take it back." }
        o.join:Show()
    elseif a and a.st == "invited" then
        o.join:SetText("Invited")
        o.join:SetKind("chosen")
        o.join:SetTint(0.3, 0.9, 0.4)
        o.join.onClick = nil
        o.join.tip = { "You're invited", "Accept the party invite to join." }
        o.join:Show()
    elseif mineRole and not R():IsGrouped() and not (a and a.st == "declined") then
        o.join:SetText("Join as " .. ShortRole(mineRole))
        o.join:SetKind("primary")
        o.join.onClick = function() TryJoin(run) end
        o.join.tip = { "Join", "Asks " .. (ns.Util.ShortName(run.o) or run.o) .. " to take you as " .. ShortRole(mineRole) .. "." }
        o.join:Show()
    else
        o.join:Hide()
    end
    local right = w - OPEN_PAD
    local by = -(y + floor((footH - 26) / 2))
    if o.share then
        o.share:ClearAllPoints()
        o.share:SetPoint("TOPRIGHT", o, "TOPLEFT", right, by)
        o.share:Show()
        right = right - 26 - 6
    end
    o.whisper:ClearAllPoints()
    o.whisper:SetPoint("TOPRIGHT", o, "TOPLEFT", right, by)
    o.whisper:SetShown(run.o ~= Me())
    right = right - 26 - 6
    o.join:ClearAllPoints()
    o.join:SetPoint("TOPRIGHT", o, "TOPLEFT", right, by)
    y = y + footH + 14
    o:SetHeight(y)
    o:Show()
    return y
end

-- The bosses on an opened raid card's head (its Encounter Journal pictures), right-aligned at `right`.
local function FillBosses(c, run, right)
    c.bossPics = c.bossPics or {}
    local list = R():GetGroupBosses(run)
    local x = right
    for i = #list, 1, -1 do
        local b = list[i]
        local f = c.bossPics[i]
        if not f then
            f = CreateFrame("Frame", nil, c)
            f:SetSize(66, 33)
            f.tex = f:CreateTexture(nil, "ARTWORK")
            f.tex:SetAllPoints()
            UI():AddEdges(f, "OVERLAY")
            UI():SetEdgeColor(f, 0, 0, 0, 0.9)
            f:EnableMouse(true)
            f:SetScript("OnEnter", function(self) if self.tip then UI():SetTextTooltip(self, self.tip, "ANCHOR_TOP") end end)
            f:SetScript("OnLeave", HideTip)
            c.bossPics[i] = f
        end
        f.tex:SetTexture(b.pic)
        f.tip = { b.name }
        f:ClearAllPoints()
        f:SetPoint("RIGHT", c, "TOPLEFT", x, -CARD_H / 2)
        f:Show()
        x = x - 66 - 4
    end
    for i = #list + 1, #c.bossPics do c.bossPics[i]:Hide() end
    -- more bosses than the three pictures (a long pick, Karazhan's full clear): "+n", every name in its tooltip
    local names = {}
    local picked = {}
    for _, key in ipairs(run.bo or {}) do picked[key] = true end
    for _, rk in ipairs(run.k == "raid" and run.a or {}) do
        local raid = ns.ItemDB and ns.ItemDB.GetRaid and ns.ItemDB:GetRaid(rk)
        for _, b in ipairs(raid and raid.bosses or {}) do
            if not b.isTrash and (run.bo == nil or picked[rk .. ":" .. tostring(b.key)]) then names[#names + 1] = b.name end
        end
    end
    local more = #names - #list
    local m = c.bossMore
    if more > 0 and #list > 0 then
        if not m then
            m = CreateFrame("Frame", nil, c)
            m:SetSize(34, 33)
            m.bg = UI():Fill(m, "CARD", "BACKGROUND")
            UI():AddEdges(m, "OVERLAY")
            UI():SetEdgeColor(m, 0, 0, 0, 0.9)
            m.text = UI():Text(m, "emph", "TEXT")
            m.text:SetPoint("CENTER")
            m:EnableMouse(true)
            m:SetScript("OnEnter", function(self) if self.tip then UI():SetTextTooltip(self, self.tip, "ANCHOR_TOP") end end)
            m:SetScript("OnLeave", HideTip)
            c.bossMore = m
        end
        m.text:SetText("+" .. more)
        local tip = { run.bo and (#names .. " bosses picked") or ("Full clear: " .. #names .. " bosses") }
        for _, n in ipairs(names) do tip[#tip + 1] = n end
        m.tip = tip
        m:ClearAllPoints()
        m:SetPoint("RIGHT", c, "TOPLEFT", right, -CARD_H / 2)
        m:Show()
        -- (the pictures move left to make room)
        for i = 1, #list do
            local f = c.bossPics[i]
            local _, _, _, px = f:GetPoint(1)
            f:ClearAllPoints()
            f:SetPoint("RIGHT", c, "TOPLEFT", (px or right) - 38, -CARD_H / 2)
        end
    elseif m then
        m:Hide()
    end
end

-- The hint after a request on my own card: fn(key, classFile) -> text or nil. On the guild's blacklist (orange); a raid
-- group's buffs nobody in it brings yet that their class brings (green, two at most).
RequestHints = function(run)
    local missing = {}
    local Comp = ns.RaidComp
    if run.k == "raid" and Comp and Comp.Coverage then
        local members = {}
        for _, d in ipairs(R():GetSlots(run)) do
            if not d.empty and d.class then members[#members + 1] = { key = d.key, c = d.class } end
        end
        -- (raid-wide buffs only: who shares a party with whom is the leader's call later)
        for _, e in ipairs(Comp:Coverage(members, "raid")) do
            if #e.providers == 0 then missing[#missing + 1] = e.buff end
        end
    end
    return function(key, classFile)
        local RP = ns.RaidPlan
        local bl = RP and RP.GetBlacklistEntry and RP:GetBlacklistEntry(key)
        if bl then
            return S:Wrap("WARN", "On the blacklist" .. (bl.by and (" (" .. (ns.Util.ShortName(bl.by) or bl.by) .. ")") or ""))
        end
        local brings = {}
        for _, b in ipairs(missing) do
            if #brings < 2 and Comp:Provides(b.key, classFile, nil) then brings[#brings + 1] = b.name end
        end
        if #brings > 0 then return S:Wrap("OK", "brings " .. tconcat(brings, ", ")) end
        return nil
    end
end

-- Fills a card. opts = { width, mine = my own run (requests + free members), compact = the sheet's preview }.
-- Returns the card's height.
local function FillCard(c, run, opts)
    local w = opts.width
    local compact = opts.compact
    local mine = opts.mine
    local kind = R():GetKind(run)
    -- (1.5) a card opens in place (one at a time): the whole group, what it is, why I fit, Join
    local open = not compact and not mine and state.open == run.id
    local chev = not compact and not mine
    local artW = compact and 112 or ART_W
    local slot = compact and 26 or SLOT
    local slotGap = compact and 4 or SLOT_GAP
    local actW = compact and 0 or (ACT_W + (chev and 14 or 0))
    c:SetWidth(w)
    c:SetTone("card")
    c:SetSelected((mine or open) and not compact)
    -- a run the page was opened on (a chat link, the calendar) lights up for a moment: the focus edge
    local focused = not compact and state.focus == run.id and GetTime() < (state.focusUntil or 0)
    if focused then UI():SetEdgeColor(c, S:Color("EDGE_FOCUS")) end
    SetArt(c, run, artW, CARD_H - 2, S.C.CARD)
    local kicker = Kicker(run)
    local skull = kind == "dungeon" and run.h and true or false
    c.skull:ClearAllPoints()
    c.skull:SetPoint("BOTTOMLEFT", c.art, "BOTTOMLEFT", 7, 7)
    c.skull:SetShown(skull)
    c.heroic:ClearAllPoints()
    if skull then
        c.heroic:SetPoint("LEFT", c.skull, "RIGHT", 2, 0)
    else
        c.heroic:SetPoint("BOTTOMLEFT", c.art, "BOTTOMLEFT", 9, 8)
    end
    c.heroic:SetText(kicker or "")
    c.heroic:SetShown(kicker ~= nil)

    -- the places, right-aligned before the action: five slots up to a party, a meter per role above, the bosses
    -- on an opened raid card (its places are in the opened part)
    local fits = R():FitsMe(run)
    local blocked = (not mine) and R():GetGroupBlocker(run)
    local dim = blocked and not compact
    local slots = R():GetSlots(run)
    local big = R():GetSize(run) > 5
    local slotsRight = w - actW - (compact and 12 or 14)
    local nSlots = (big or open) and 0 or min(#slots, #c.slots)
    local slotsW = nSlots > 0 and (nSlots * slot + (nSlots - 1) * slotGap) or 0
    for i, s in ipairs(c.slots) do
        local d = i <= nSlots and slots[i]
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
    if big and not open then
        c.meters = c.meters or NewMeters(c)
        slotsW = FillMeters(c.meters, run, (not blocked and not compact) and fits or nil, dim)
        c.meters:ClearAllPoints()
        c.meters:SetPoint("RIGHT", c, "TOPLEFT", slotsRight, -CARD_H / 2)
        c.meters:Show()
    elseif c.meters then
        c.meters:Hide()
    end
    if open and kind == "raid" then
        FillBosses(c, run, slotsRight)
        slotsW = #R():GetGroupBosses(run) * 70 + ((c.bossMore and c.bossMore:IsShown()) and 38 or 0)
    elseif c.bossPics then
        for _, f in ipairs(c.bossPics) do f:Hide() end
        if c.bossMore then c.bossMore:Hide() end
    end

    -- texts
    local textX = artW + 4
    local textW = slotsRight - slotsW - 12 - textX
    local full, short = DungeonName(run)
    -- the note's icon after the name: a dungeon's always, a raid's while closed (its third line is the loot); the
    -- other kinds say the note on their third line
    local noteIcon = run.no ~= nil and not compact and (kind == "dungeon" or (kind == "raid" and not open))
    FitName(c.t1, full, short, textW - (noteIcon and 20 or 0), compact and "emph" or "title")
    c.t1:SetTextColor(dim and 0.55 or 1, dim and 0.55 or 1, dim and 0.55 or 1)
    -- no leader on my own card, nor in the sheet's narrow preview (it's me; "Tomorrow 21:00" needs the room)
    local leader = run.o == Me() and "" or (UI():ColoredName(run.o) .. S:Wrap("SUB", " · "))
    c.t2:SetText(leader .. S:Wrap("SUB", WhenText(run)))
    c.t2:SetAlpha(dim and 0.55 or 1)
    local hint, itemID, items
    if not compact then hint, itemID, items = HintFor(run) end
    -- opened (another kind): the chips say what it is, the third line keeps the leader's note
    if open and kind ~= "dungeon" and not blocked then hint, itemID, items = run.no and S:Wrap("SUB", "\"" .. run.no .. "\"") or nil, nil, nil end
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
    c.notes:SetShown(noteIcon)

    -- the chevron: a click on the card opens it (another click, or opening another, closes it)
    if chev then
        c.cv = c.cv or c:CreateTexture(nil, "OVERLAY")
        c.cv:SetSize(10, 10)
        UI():SetGlyph(c.cv, "chevron", open and "GOLD" or "SUB")
        UI():SetChevronUp(c.cv, open)
        c.cv:ClearAllPoints()
        c.cv:SetPoint("RIGHT", c, "TOPRIGHT", -12, -CARD_H / 2)
        c.cv:Show()
        local id = run.id
        c.onToggle = function()
            state.open = (state.open ~= id) and id or nil
            ns.DungeonsUI:Refresh()
        end
        if not c.toggleHooked then
            c.toggleHooked = true
            c:SetScript("OnMouseUp", function(self, button)
                if button == "LeftButton" and self.onToggle then self.onToggle() end
            end)
        end
    else
        if c.cv then c.cv:Hide() end
        c.onToggle = nil
    end

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
        if not compact and kind == "dungeon" and GF and GF:IsAvailable() and R():IsNow(run) then
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
    elseif not compact and not open and not R():IsInRun(run) then
        local a = R():GetAsked(run.id)
        local inv = R():GetInvite()
        local tinted = false
        c.btn:ClearAllPoints()
        c.btn:SetPoint("RIGHT", c, "TOPRIGHT", chev and -28 or -12, -CARD_H / 2)
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
            c.btn.onClick = function() TryJoin(run) end
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
    if c.manage then c.manage:Hide() end
    if mine and not compact and R():GetSize(run) > 5 then
        -- (1.5) a group bigger than a party: one line here, the leader's own page for the rest (UI/GroupsLead.lua)
        local m = c.manage
        if not m then
            m = CreateFrame("Frame", nil, c)
            m:SetHeight(34)
            m.line = UI():Rule(m, { layer = "BORDER", top = 0 })
            m.text = UI():Text(m, "body", "TEXT")
            m.text:SetPoint("LEFT", 0, 0)
            m.btn = UI():CreateSleekButton(m, "Manage group", 120, S.BTN_H, function()
                if ns.GroupsLead then ns.GroupsLead:Open(m.runId) end
            end, "primary")
            m.btn:SetPoint("RIGHT", 0, 0)
            c.manage = m
        end
        m.runId = run.id
        m:ClearAllPoints()
        m:SetPoint("TOPLEFT", c, "TOPLEFT", textX, -CARD_H)
        m:SetPoint("TOPRIGHT", c, "TOPRIGHT", -12, -CARD_H)
        local reqs = R():GetRequests(run.id)
        local open = 0
        for _, d in ipairs(R():GetSlots(run)) do if d.empty then open = open + 1 end end
        m.text:SetText((#reqs > 0 and S:Wrap("GOLD", #reqs .. (#reqs == 1 and " asking" or " asking")) or
            S:Wrap("SUB", "Nobody asking yet")) .. S:Wrap("SUB", "  ·  " .. open .. (open == 1 and " open place" or
            " open places")))
        m:Show()
        h = CARD_H + 38
    elseif mine and not compact then
        local x = textX
        local y = -CARD_H + 2
        local hintsFor = RequestHints(run)
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
            -- what matters about them: on the blacklist, a buff the group lacks that they bring
            r.hint = r.hint or UI():Text(r, "small", "TEXT")
            r.hint:ClearAllPoints()
            r.hint:SetPoint("LEFT", q.b and r.tag or r.spec, "RIGHT", 9, 0)
            r.hint:SetText(hintsFor(q.key, classFile) or "")
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
            -- (1.5) up for this kind of group, and not saved there
            local kindOk = (e.kinds or { dungeon = true })[R():GetKind(run)]
            local saved = run.h and R():IsSaved(e.key, run.d)
            for _, rk in ipairs(run.k == "raid" and run.a or {}) do
                if R():IsSavedToRaid(e.key, rk) then saved = true end
            end
            if ok and kindOk and not asking[e.key] and not saved then fitting[#fitting + 1] = e end
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
    -- opened: the group under the head, the art faint behind the whole card
    if open then
        h = CARD_H + FillOpen(c, run, w)
        local file, l, r, t, b = R():GetGroupArt(run, w - 2, h - 2, 0.9)
        -- (under the loading screen's logo band, as the head's art)
        if file and t < 0.3 then t, b = 0.3, min(0.98, b + 0.3 - t) end
        if file then
            c.bg:SetTexture(file)
            c.bg:SetTexCoord(l, r, t, b)
            c.bg:SetAlpha(0.32)
            c.bg:Show()
            UI():Gradient(c.bgShade, "VERTICAL", { 0.04, 0.04, 0.05, 0.92 }, { 0.04, 0.04, 0.05, 0.55 })
            c.bgShade:Show()
        end
    else
        if c.open then c.open:Hide() end
        c.bg:Hide()
        c.bgShade:Hide()
    end
    c:SetHeight(h)
    c.tip = (not compact and not open) and CardTip(run) or nil
    return h
end


G.CARD_H, G.ART_W, G.STAR, G.ROLE_NAME, G.HEROIC_TEX = CARD_H, ART_W, STAR, ROLE_NAME, HEROIC_TEX
G.WhenText, G.DayLabel, G.DungeonName, G.ItemLinkText, G.HideTip = WhenText, DayLabel, DungeonName, ItemLinkText, HideTip
G.RedrawHoveredTip, G.HintFor, G.CardTip = RedrawHoveredTip, HintFor, CardTip
G.NewRunCard, G.FillCard, G.NewPersonChip, G.FillChip, G.Disc = NewRunCard, FillCard, NewPersonChip, FillChip, Disc
G.Kicker, G.TryJoin = Kicker, TryJoin
G.NewMeters, G.FillMeters, G.RequestHints, G.LootText = NewMeters, FillMeters, RequestHints, LootText
