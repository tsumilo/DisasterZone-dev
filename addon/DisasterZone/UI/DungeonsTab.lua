if DisasterZoneBoot and DisasterZoneBoot.Run("UI/DungeonsTab.lua", ...) then return end -- DisasterZone: the "Dungeons" tab (everyone).
-- The guild's 5-man runs (Core/DungeonRuns.lua) as cards: the dungeon's loading-screen art, the leader and when, at
-- most one hint (what stops me, else what drops my BiS) and the five places of the party; the empty place that wants
-- one of my roles glows. Join asks the leader. My own run sits on top with the players asking to join and the
-- members up for a run who fit. "List a run" opens a sheet: the dungeons by complex, when, a note, my role and a
-- preview that is exactly the card the guild will see. A small pop-up pings me when a run needs me while I'm up for
-- one, and the leader when somebody asks to join; a run's party invite is a pop-up too. The eye on my run lists it
-- in Blizzard's Group Finder (it looks around while listed) and the players from outside the guild show up under it.
local addonName, ns = ...

local DungeonsUI = ns:NewModule("DungeonsUI")

local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local PAD = 10
local TOP_H = 34                 -- the "I'm up for a run" bar
local STRIP_H = 30               -- the members up for a run
local CARD_H = 72
local ART_W = 180
local TEXT_X = ART_W + 4
local SLOT, SLOT_GAP = 30, 5
local ACT_W = 92
local GAP = 6
local SECTION_H = 26
local REQ_H = 30
local ROW_H, ROW_GAP = 50, 6     -- the sheet's complex rows
local TILE_W, TILE_H, TILE_GAP = 136, 34, 6
local TOAST_W, TOAST_H, TOAST_ART = 440, 76, 112
local TOAST_FOR = 25

local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local ROLE_TEX = "Interface\\LFGFrame\\UI-LFG-ICON-ROLES"
local HEROIC_TEX = "Interface\\LFGFrame\\UI-LFG-ICON-HEROIC"
local STAR_TEX = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local NO_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local STAR = "|T" .. STAR_TEX .. ":11:11:0:0|t"
local ROLE_TOKEN = { tank = "TANK", healer = "HEALER", dps = "DAMAGER" }
local ROLE_COORDS = {   -- GetTexCoordsForRole's (a 256x256 texture of 67x67 cells), for a client without it
    TANK = { 0, 67 / 256, 67 / 256, 134 / 256 }, HEALER = { 67 / 256, 134 / 256, 0, 67 / 256 },
    DAMAGER = { 67 / 256, 134 / 256, 67 / 256, 134 / 256 },
}
local ROLE_NAME = { tank = "tank", healer = "healer", dps = "DPS" }

local GOLD = { 1, 0.82, 0 }
local CARD_BG = { 0.10, 0.10, 0.12, 0.92 }
local MINE_BG = { 0.13, 0.12, 0.08, 0.94 }
local SHEET_BG = { 0.035, 0.035, 0.043, 0.985 }

local panel, toast
local state = { sheet = nil, invited = {} }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function R() return ns.DungeonRuns end
local function UI() return ns.UI end
local function Now() return (GetServerTime and GetServerTime()) or time() end
local function Me() return ns.Util.PlayerKey() end
local function grey(text) return "|cff9e9e9e" .. tostring(text) .. "|r" end
local function gold(text) return "|cffffd100" .. tostring(text) .. "|r" end
local function orange(text) return "|cffff8c1a" .. tostring(text) .. "|r" end
local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

local function Sized(fs, size)
    local path, _, flags = fs:GetFont()
    if path then fs:SetFont(path, size, flags) end
    return fs
end

local function Text(parent, font, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then Sized(fs, size) end
    return fs
end

local function RoleCoords(role)
    local token = ROLE_TOKEN[role] or "DAMAGER"
    if GetTexCoordsForRole then
        local l, r, t, b = GetTexCoordsForRole(token)
        if l then return l, r, t, b end
    end
    local c = ROLE_COORDS[token]
    return c[1], c[2], c[3], c[4]
end

local function SetRole(tex, role)
    tex:SetTexture(ROLE_TEX)
    tex:SetTexCoord(RoleCoords(role))
end

local function RoleIconText(role, size)
    local l, r, t, b = RoleCoords(role)
    size = size or 13
    return ("|T%s:%d:%d:0:0:256:256:%d:%d:%d:%d|t"):format(ROLE_TEX, size, size, floor(l * 256 + 0.5),
        floor(r * 256 + 0.5), floor(t * 256 + 0.5), floor(b * 256 + 0.5))
end

local function Disc(parent, layer, sub, size, c)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(DISC)
    t:SetSize(size, size)
    t:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
    return t
end

-- A text that fits: the full name, else the short one, else the short one a size smaller.
local function FitText(fs, full, short, width, size)
    Sized(fs, size)
    fs:SetText(full)
    if (fs:GetStringWidth() or 0) <= width or not short then return end
    fs:SetText(short)
    if (fs:GetStringWidth() or 0) <= width then return end
    Sized(fs, size - 2)
end

local function ItemLinkText(itemID)
    local name, quality
    if ns.ItemDB and ns.ItemDB.GetInfo then
        local n, _, q = ns.ItemDB:GetInfo(itemID)
        name, quality = n, q
    end
    if not name then return grey("Loading...") end
    local r, g, b = UI():QualityColor(quality)
    return ("|cff%02x%02x%02x[%s]|r"):format(floor(r * 255), floor(g * 255), floor(b * 255), name)
end

-- "starting now", "listed 25 min ago", "20:30, in 2 h", "Tomorrow 20:30", "Sat 20:30", "started 10 min ago".
local function WhenText(run)
    local now = Now()
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
    local now = Now()
    if date("%Y%m%d", now) == date("%Y%m%d", at) then return "today" end
    if date("%Y%m%d", now + 86400) == date("%Y%m%d", at) then return "Tomorrow" end
    return date("%A ", at) .. tonumber(date("%d", at)) .. date(" %b", at)
end

local function DungeonName(run)
    local d = R():GetDungeon(run.d)
    return d and d.name or tostring(run.d), d and d.short or nil
end

local function Tip(owner, lines, anchor)
    UI():SetTextTooltip(owner, lines, anchor or "ANCHOR_RIGHT")
end

local function HideTip() GameTooltip:Hide() end

-- A rounded pill (edge + fill) drawn from discs and a bar: f:SetPillColors(fill, edge).
local function AddPill(f, h)
    local function part(layer, sub, inset)
        local l = f:CreateTexture(nil, layer, nil, sub)
        l:SetTexture(DISC)
        l:SetSize(h - 2 * inset, h - 2 * inset)
        l:SetPoint("LEFT", inset, 0)
        local r = f:CreateTexture(nil, layer, nil, sub)
        r:SetTexture(DISC)
        r:SetSize(h - 2 * inset, h - 2 * inset)
        r:SetPoint("RIGHT", -inset, 0)
        local m = f:CreateTexture(nil, layer, nil, sub)
        m:SetColorTexture(1, 1, 1, 1)
        m:SetPoint("TOPLEFT", f, "TOPLEFT", h / 2, -inset)
        m:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -h / 2, inset)
        return { l, r, m }
    end
    f.pillEdge = part("BACKGROUND", 1, 0)
    f.pillFill = part("BACKGROUND", 2, 1)
    function f:SetPillColors(fill, edge)
        for _, t in ipairs(self.pillFill) do t:SetVertexColor(fill[1], fill[2], fill[3], fill[4] or 1) end
        for _, t in ipairs(self.pillEdge) do t:SetVertexColor(edge[1], edge[2], edge[3], edge[4] or 1) end
    end
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
    s:SetScript("OnEnter", function(self) if self.tip then Tip(self, self.tip, "ANCHOR_TOP") end end)
    s:SetScript("OnLeave", HideTip)
    return s
end

-- d = { key, role, class, you } or { empty = true, role }; wants = this empty place wants me.
local function FillSlot(s, d, wants, dim)
    s:SetAlpha(dim and 0.42 or 1)
    if d.empty then
        s.class:Hide()
        s.badge:Hide()
        s.role:Show()
        SetRole(s.role, d.role)
        s.fill:SetVertexColor(0.07, 0.07, 0.08, 1)
        if wants then
            s.ring:SetVertexColor(1, 0.82, 0, 0.75)
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
        SetRole(s.badge, d.role)
        s.ring:SetVertexColor(d.you and 1 or 0, d.you and 0.82 or 0, 0, d.you and 0.9 or 1)
        local spec = R():GetSpecLabel(d.key)
        local line = R().ROLE_LABEL[d.role] .. (spec and (" · " .. spec) or "")
        s.tip = { UI():ColoredName(d.key, d.class), line, d.owner and grey("Leads the run") or nil }
    end
end

---------------------------------------------------------------------------
-- Cards
---------------------------------------------------------------------------

local function NewButton(parent, text, w, h, kind, onClick)
    return UI():CreateSleekButton(parent, text, w, h, onClick, kind)
end

local function NewCard(parent)
    local c = CreateFrame("Button", nil, parent)
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()
    UI():AddEdges(c, "BORDER")
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
    c.heroic = Text(c, "GameFontNormalSmall")
    c.heroic:SetText("Heroic")
    c.heroic:SetPoint("LEFT", c.skull, "RIGHT", 2, 0)
    c.t1 = Text(c, "GameFontHighlight", 15)
    c.notes = CreateFrame("Frame", nil, c)
    c.notes:SetSize(14, 14)
    c.notes.icon = c.notes:CreateTexture(nil, "OVERLAY")
    c.notes.icon:SetAllPoints()
    c.notes.icon:SetTexture(UI().ICON_ATLAS)
    c.notes.icon:SetTexCoord(unpack(UI():IconCoords(UI().ICON.notes)))
    c.notes.icon:SetVertexColor(0.7, 0.7, 0.7, 0.8)
    c.notes:EnableMouse(true)
    c.notes:SetScript("OnEnter", function(self)
        if self.note then Tip(self, { "Note", self.note }, "ANCHOR_TOP") end
    end)
    c.notes:SetScript("OnLeave", HideTip)
    c.t2 = Text(c, "GameFontHighlightSmall", 11)
    c.t2:SetTextColor(0.62, 0.62, 0.62)
    c.t3 = Text(c, "GameFontHighlightSmall", 11)
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
    c.btn = NewButton(c, "", 80, 26, "primary")
    c.more = UI():CreateTipIconButton(c, 26, UI().ICON.more, "Your run", "Edit it, post it in the LookingForGroup "
        .. "channel, or take it off the board.")
    if ns.Share and ns.Share.CreateButton then
        c.share = ns.Share:CreateButton(c, 26, function() return c.runId and ns.Share:RunRef(c.runId) or nil end,
            "Share your run")
    end
    c.reqs, c.free = {}, {}
    c:SetScript("OnEnter", function(self) if self.tip then Tip(self, self.tip()) end end)
    c:SetScript("OnLeave", HideTip)
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
    if c.fade.SetGradient and CreateColor then
        c.fade:SetGradient("HORIZONTAL", CreateColor(bg[1], bg[2], bg[3], 0), CreateColor(bg[1], bg[2], bg[3], 1))
    end
    c.shade:ClearAllPoints()
    c.shade:SetPoint("BOTTOMLEFT", c.art, "BOTTOMLEFT")
    c.shade:SetPoint("BOTTOMRIGHT", c.art, "BOTTOMRIGHT")
    c.shade:SetHeight(26)
    if c.shade.SetGradient and CreateColor then
        c.shade:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.75), CreateColor(0, 0, 0, 0))
    end
end

-- What a card's tooltip says: the dungeon, the leader, when, the party, the note.
local function CardTip(run)
    return function()
        local name = DungeonName(run)
        local lines = { name .. (run.h and " (Heroic)" or "") }
        lines[#lines + 1] = "Led by " .. UI():ColoredName(run.o) .. " · " .. WhenText(run)
        local who = {}
        for _, s in ipairs(R():GetSlots(run)) do
            if not s.empty then who[#who + 1] = RoleIconText(s.role, 12) .. " " .. UI():ColoredName(s.key, s.class) end
        end
        if #who > 0 then lines[#lines + 1] = tconcat(who, "   ") end
        if run.no then lines[#lines + 1] = grey("\"" .. run.no .. "\"") end
        local drops = R():GetMyBiSDrops(run.d, run.h)
        if #drops > 0 and run.o ~= Me() then
            lines[#lines + 1] = gold("Drops your BiS:")
            for i, id in ipairs(drops) do
                if i > 6 then lines[#lines + 1] = grey("+" .. (#drops - 6) .. " more") break end
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
    if a and a.st == "declined" then return grey(shortName(run.o) .. " said not this time") end
    local block = R():GetBlocker(run.d, run.h)
    if block then return orange(UI():LockIcon(12) .. " " .. block) end
    if R():IsGrouped() and not R():IsInRun(run) and R():FitsMe(run) then
        return grey("You're in a group: leave it to join")
    end
    local drops = R():GetMyBiSDrops(run.d, run.h)
    if #drops > 0 then
        local more = #drops > 1 and grey(" +" .. (#drops - 1)) or ""
        return gold(STAR .. " Drops your BiS ") .. ItemLinkText(drops[1]) .. more, drops[1], drops
    end
    local daily = R():GetMyDaily(run.d, run.h)
    if daily == "log" or daily == "today" then
        return "|TInterface\\GossipFrame\\DailyQuestIcon:12:12:0:0|t " .. gold(run.h and "Your daily heroic"
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
    r.line = r:CreateTexture(nil, "BORDER")
    r.line:SetColorTexture(1, 1, 1, 0.07)
    r.line:SetHeight(1)
    r.line:SetPoint("TOPLEFT")
    r.line:SetPoint("TOPRIGHT")
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(22, 22)
    r.icon:SetPoint("LEFT", 0, 0)
    r.name = Text(r, "GameFontHighlight", 12)
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
    r.spec = Text(r, "GameFontHighlightSmall", 11)
    r.spec:SetTextColor(0.62, 0.62, 0.62)
    r.spec:SetPoint("LEFT", r.name, "RIGHT", 7, 0)
    r.tag = CreateFrame("Frame", nil, r)
    r.tag:SetHeight(16)
    AddPill(r.tag, 16)
    r.tag:SetPillColors({ 0.16, 0.13, 0.03, 1 }, { 1, 0.82, 0, 0.45 })
    r.tag.text = Text(r.tag, "GameFontNormalSmall", 10)
    r.tag.text:SetPoint("CENTER", 0, 0)
    r.tag.text:SetText(STAR .. " BiS here")
    r.tag:SetWidth((r.tag.text:GetStringWidth() or 50) + 14)
    r.tag:SetPoint("LEFT", r.spec, "RIGHT", 9, 0)
    r.tag:EnableMouse(true)
    r.tag:SetScript("OnEnter", function(self)
        Tip(self, { "BiS here", "Something on " .. (self.who or "their") .. " BiS list drops in this dungeon." },
            "ANCHOR_TOP")
    end)
    r.tag:SetScript("OnLeave", HideTip)
    r.no = UI():CreateIconButton(r, 22, NO_TEX, nil, function(self) if self.onClick then self.onClick() end end)
    r.no.icon:ClearAllPoints()
    r.no.icon:SetPoint("TOPLEFT", 4, -4)
    r.no.icon:SetPoint("BOTTOMRIGHT", -4, 4)
    r.no:SetPoint("RIGHT", 0, 0)
    r.no:SetScript("OnEnter", function(self)
        Tip(self, { "Not this time", "Lets them know, kindly." }, "ANCHOR_TOP")
    end)
    r.no:SetScript("OnLeave", HideTip)
    r.yes = NewButton(r, "Accept", 70, 22, "primary", function(self) if self.onClick then self.onClick() end end)
    r.yes:SetPoint("RIGHT", r.no, "LEFT", -5, 0)
    r.state = Text(r, "GameFontHighlightSmall", 11)
    r.state:SetPoint("RIGHT", r.no, "LEFT", -10, 0)
    return r
end

-- A person chip: class circle, name in class colour, role icons. Width fits the content.
local function NewChip(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetHeight(24)
    AddPill(f, 24)
    f:SetPillColors({ 0.10, 0.10, 0.12, 0.92 }, { 0.34, 0.34, 0.38, 0.6 })
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(20, 20)
    f.icon:SetPoint("LEFT", 2, 0)
    f.name = Text(f, "GameFontHighlight", 12)
    f.name:SetPoint("LEFT", f.icon, "RIGHT", 6, 0)
    f.roles = Text(f, "GameFontHighlightSmall")
    f.roles:SetPoint("LEFT", f.name, "RIGHT", 4, 0)
    f:SetScript("OnEnter", function(self) if self.tip then Tip(self, self.tip, "ANCHOR_TOP") end end)
    f:SetScript("OnLeave", HideTip)
    return f
end

local function FillChip(f, e)
    UI():ClassIcon(f.icon, e.class)
    f.name:SetText(UI():ColoredName(e.key, e.class))
    local icons, words = {}, {}
    for _, role in ipairs(R().ROLES) do
        if e.roles[role] then
            icons[#icons + 1] = RoleIconText(role, 13)
            words[#words + 1] = R().ROLE_LABEL[role]
        end
    end
    f.roles:SetText(tconcat(icons, ""))
    f:SetWidth(floor(2 + 20 + 6 + (f.name:GetStringWidth() or 40) + 4 + (f.roles:GetStringWidth() or 0) + 9))
    f.key = e.key
    f.tip = { UI():ColoredName(e.key, e.class), "Up for a run: " .. tconcat(words, ", "), grey("Click to whisper") }
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
    b:HookScript("OnEnter", function(self) if self.tipLines then Tip(self, self.tipLines, "ANCHOR_TOP") end end)
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
        local mins = since and max(1, floor((Now() - since) / 60))
        local n = #GF:GetCandidates(run)
        eye.tipLines = { "In the Group Finder" .. (mins and grey(" · " .. mins .. " min") or ""),
            "Listed as " .. where .. ". Players looking for it there, and anyone who whispers you, show up on your run.",
            -- (only PUG_ROWS fit under the run: setting some aside shows the next ones)
            n > PUG_ROWS and gold(n .. " players found: the first " .. PUG_ROWS .. " show under your run. Set some "
                .. "aside to see the others.") or nil,
            grey("Click to take it out. It stays on the guild's board.") }
    else
        eye.tipLines = { "Group Finder", "Lists your run in Blizzard's Group Finder as " .. where .. ". Players looking "
            .. "for it there, and anyone who whispers you, show up on your run.",
            listed and grey("Your group is listed there for another dungeon: this switches it.") or nil }
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
    r.line = r:CreateTexture(nil, "BORDER")
    r.line:SetColorTexture(1, 1, 1, 0.07)
    r.line:SetHeight(1)
    r.line:SetPoint("TOPLEFT")
    r.line:SetPoint("TOPRIGHT")
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(22, 22)
    r.icon:SetPoint("LEFT", 0, 0)
    r.name = Text(r, "GameFontHighlight", 12)
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
    r.info = Text(r, "GameFontHighlightSmall", 11)
    r.info:SetPoint("LEFT", r.name, "RIGHT", 7, 0)
    r.info:SetTextColor(0.62, 0.62, 0.62)
    r.text = Text(r, "GameFontHighlightSmall", 11)
    r.text:SetPoint("LEFT", r.info, "RIGHT", 8, 0)
    r.text:SetTextColor(0.78, 0.78, 0.78)
    r.no = UI():CreateIconButton(r, 22, NO_TEX, nil, function(self) if self.onClick then self.onClick() end end)
    r.no.icon:ClearAllPoints()
    r.no.icon:SetPoint("TOPLEFT", 4, -4)
    r.no.icon:SetPoint("BOTTOMRIGHT", -4, 4)
    r.no:SetPoint("RIGHT", 0, 0)
    HookTip(r.no, { "Not this one", "Sets them aside for this run." })
    r.say = UI():CreateTipIconButton(r, 22, UI().ICON.whisper, "Whisper", "Starts a whisper to them in the chat box.",
        function(self) if self.onClick then self.onClick() end end)
    r.say:SetPoint("RIGHT", r.no, "LEFT", -4, 0)
    r.yes = NewButton(r, "Invite", 62, 22, "secondary", function(self) if self.onClick then self.onClick() end end)
    r.yes:SetPoint("RIGHT", r.say, "LEFT", -5, 0)
    r.state = Text(r, "GameFontHighlightSmall", 11)
    r.state:SetPoint("RIGHT", r.say, "LEFT", -10, 0)
    r:SetScript("OnEnter", function(self) if self.tip then Tip(self, self.tip, "ANCHOR_TOP") end end)
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
    if e.role and not e.invited then lines[#lines + 1] = grey("Invite takes them as " .. ROLE_NAME[e.role] .. ".") end
    lines[#lines + 1] = grey("Click to whisper")
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
            if e.roles[role] then icons[#icons + 1] = RoleIconText(role, 12) end
        end
        local info = tconcat(icons, "")
        if e.level then info = info .. (info ~= "" and " " or "") .. e.level end
        r.info:SetText(info)
        local key = e.key
        local rightW = 22 + 4 + 22 + 5 + 62
        if e.invited then
            r.yes:Hide()
            r.state:SetText(grey("Invited"))
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
    local bg = mine and MINE_BG or CARD_BG
    c:SetWidth(w)
    c.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    local focused = not compact and state.focus == run.id and GetTime() < (state.focusUntil or 0)
    if focused then
        UI():SetEdgeColor(c, 1, 0.9, 0.4, 1)
        c.bg:SetColorTexture(bg[1] + 0.07, bg[2] + 0.06, bg[3] + 0.02, bg[4])
    elseif mine then
        UI():SetEdgeColor(c, 1, 0.82, 0, 0.75)
    else
        UI():SetEdgeColor(c, 0.34, 0.34, 0.38, 0.55)
    end
    SetArt(c, run.d, artW, CARD_H - 2, bg)
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
            s:Show()
        else
            s:Hide()
        end
    end

    -- texts
    local textX = artW + 4
    local textW = slotsRight - slotsW - 12 - textX
    local full, short = DungeonName(run)
    FitText(c.t1, full, short, textW - (run.no and 20 or 0), compact and 14 or 15)
    c.t1:SetTextColor(dim and 0.55 or 1, dim and 0.55 or 1, dim and 0.55 or 1)
    -- no leader on my own card, nor in the sheet's narrow preview (it's me; "Tomorrow 21:00" needs the room)
    local leader = run.o == Me() and "" or (UI():ColoredName(run.o) .. grey(" · "))
    c.t2:SetText(leader .. grey(WhenText(run)))
    c.t2:SetAlpha(dim and 0.55 or 1)
    local hint, itemID, items
    if not compact then hint, itemID, items = HintFor(run) end
    c.t3:SetText(hint or "")
    c.t3:SetShown(hint ~= nil)
    c.hint.itemID = itemID
    c.hint.extra = items and #items > 1 and function(tt)
        tt:AddLine(" ")
        tt:AddLine("Also drops your BiS:", 1, 0.82, 0)
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
        c.more:SetScript("OnClick", function(self) DungeonsUI:OpenMineMenu(self) end)
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
            c.btn.tip = { UI():ColoredName(inv.from) .. grey(" invites you"), "Click to join the party. The cross on "
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
            c.btn.tip = { "Join", "Asks " .. shortName(run.o) .. " to take you as " .. ROLE_NAME[fits] .. ".",
                R():GetMine() and orange("Your own run comes off the board when you join.") or nil }
            c.btn:Show()
        end
        if c.btn:IsShown() then
            if not tinted then c.btn:SetTint(nil) end
            c.btn:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
            c.btn:SetScript("OnEnter", function(self) if self.tip then Tip(self, self.tip, "ANCHOR_TOP") end end)
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
            r.spec:SetText(RoleIconText(q.r, 12) .. " " .. (spec or R().ROLE_LABEL[q.r]))
            r.tag:SetShown(q.b and true or false)
            r.tag.who = shortName(q.key) .. "'s"
            local key = q.key
            if q.st == "invited" then
                r.yes:Hide()
                r.state:SetText(grey("Invited"))
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
                r.line = r:CreateTexture(nil, "BORDER")
                r.line:SetColorTexture(1, 1, 1, 0.07)
                r.line:SetHeight(1)
                r.line:SetPoint("TOPLEFT")
                r.line:SetPoint("TOPRIGHT")
                r.label = Text(r, "GameFontHighlightSmall", 11)
                r.label:SetTextColor(0.62, 0.62, 0.62)
                r.label:SetPoint("LEFT", 0, 0)
                r.label:SetText("Up for a run")
                r.chips, r.invites = {}, {}
                c.free[1] = r
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", c, "TOPLEFT", x, y)
            r:SetPoint("TOPRIGHT", c, "TOPRIGHT", -12, y)
            local cx = (r.label:GetStringWidth() or 60) + 10
            local room = w - x - 12
            for i = 1, max(#r.chips, #fitting) do
                local e = fitting[i]
                local chip, inv = r.chips[i], r.invites[i]
                if e then
                    if not chip then
                        chip = NewChip(r)
                        inv = NewButton(r, "Invite", 56, 22, "secondary")
                        r.chips[i], r.invites[i] = chip, inv
                    end
                    FillChip(chip, e)
                    local need = chip:GetWidth() + 4 + 56 + 10
                    if cx + need <= room then
                        chip:ClearAllPoints()
                        chip:SetPoint("LEFT", r, "LEFT", cx, 0)
                        inv:ClearAllPoints()
                        inv:SetPoint("LEFT", chip, "RIGHT", 4, 0)
                        local key = e.key
                        local done = state.invited[key]
                        inv:SetText(done and "Invited" or "Invite")
                        inv:SetEnabled(not done)
                        inv:SetScript("OnClick", function()
                            if R():InviteFree(key) then
                                state.invited[key] = true
                                DungeonsUI:Refresh()
                            end
                        end)
                        chip:SetScript("OnClick", nil)
                        chip:Show()
                        inv:Show()
                        cx = cx + need
                    else
                        chip:Hide()
                        inv:Hide()
                    end
                elseif chip then
                    chip:Hide()
                    inv:Hide()
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

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

local function NewRoleChip(parent, role, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(24, 24)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    UI():AddEdges(b)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("CENTER")
    SetRole(b.icon, role)
    b.role = role
    function b:SetOn(on)
        self.on = on and true or false
        local s = UI().SLEEK[self.on and "chosen" or "secondary"]
        self.bg:SetColorTexture(s.bg[1], s.bg[2], s.bg[3], s.bg[4])
        UI():SetEdgeColor(self, s.edge[1], s.edge[2], s.edge[3], s.edge[4])
        self.icon:SetDesaturated(not self.on)
        self.icon:SetAlpha(self.on and 1 or 0.3)
    end
    b:SetScript("OnClick", function(self) onClick(self) end)
    b:SetScript("OnEnter", function(self)
        Tip(self, { R().ROLE_LABEL[role], self.on and "You're up for this role. Click to drop it."
            or "Click to add this role." }, "ANCHOR_TOP")
    end)
    b:SetScript("OnLeave", HideTip)
    b:SetOn(false)
    return b
end

-- The on / off switch: a pill with a knob.
local function NewSwitch(parent, onClick)
    local s = CreateFrame("Button", nil, parent)
    s:SetSize(34, 18)
    AddPill(s, 18)
    s.knob = Disc(s, "ARTWORK", 0, 12, { 0.54, 0.54, 0.56, 1 })
    function s:SetOn(on)
        self.on = on and true or false
        if self.on then
            self:SetPillColors({ 0.11, 0.47, 0.20, 0.95 }, { 0.35, 0.86, 0.47, 0.8 })
            self.knob:SetVertexColor(0.92, 1, 0.94, 1)
            self.knob:ClearAllPoints()
            self.knob:SetPoint("RIGHT", -3, 0)
        else
            self:SetPillColors({ 0.16, 0.16, 0.18, 0.95 }, { 0.34, 0.34, 0.38, 0.9 })
            self.knob:SetVertexColor(0.54, 0.54, 0.56, 1)
            self.knob:ClearAllPoints()
            self.knob:SetPoint("LEFT", 3, 0)
        end
    end
    s:SetScript("OnClick", function() onClick() end)
    s:SetOn(false)
    return s
end

local function UpTip(owner)
    local untilT = R():GetUpUntil()
    local lines = { "I'm up for a run" }
    if untilT then
        local left = max(1, floor((untilT - Now()) / 60))
        lines[#lines + 1] = "The guild sees you're free for another " .. (left >= 60 and (floor(left / 60) .. " h "
            .. (left % 60) .. " min") or (left .. " min")) .. ", and you get a ping when a run needs one of your roles."
        lines[#lines + 1] = grey("It switches off in a full party or a dungeon.")
    else
        lines[#lines + 1] = "Switch it on to show the guild you're free for 2 hours, with the roles beside it. You get "
            .. "a ping when a run needs one of them."
    end
    Tip(owner, lines, "ANCHOR_BOTTOMLEFT")
end

local function CreateTop(p)
    local top = CreateFrame("Frame", nil, p)
    top:SetPoint("TOPLEFT", PAD, -6)
    top:SetPoint("TOPRIGHT", -PAD, -6)
    top:SetHeight(TOP_H - 4)
    p.top = top
    top.switch = NewSwitch(top, function() R():SetUp(not R():IsUp()) end)
    top.switch:SetPoint("LEFT", 0, 0)
    top.switch:SetScript("OnEnter", UpTip)
    top.switch:SetScript("OnLeave", HideTip)
    top.label = CreateFrame("Button", nil, top)
    top.label.text = Text(top.label, "GameFontHighlight", 13)
    top.label.text:SetPoint("LEFT")
    top.label.text:SetText("I'm up for a run")
    top.label:SetSize((top.label.text:GetStringWidth() or 100) + 4, 20)
    top.label:SetPoint("LEFT", top.switch, "RIGHT", 9, 0)
    top.label:SetScript("OnClick", function() R():SetUp(not R():IsUp()) end)
    top.label:SetScript("OnEnter", UpTip)
    top.label:SetScript("OnLeave", HideTip)
    top.roles = {}
    for _, role in ipairs(R().ROLES) do
        top.roles[role] = NewRoleChip(top, role, function(self) R():SetMyRole(role, not self.on) end)
    end
    top.list = NewButton(top, "List a run", 110, 28, "primary", function() DungeonsUI:OpenSheet() end)
    top.list:SetPoint("RIGHT", 0, 0)
end

local function UpdateTop(p)
    local top = p.top
    top.switch:SetOn(R():IsUp())
    top.label.text:SetTextColor(R():IsUp() and 1 or 0.62, R():IsUp() and 1 or 0.62, R():IsUp() and 1 or 0.62)
    local mine = R():GetMyRoles()
    local x = top.label:GetWidth() + 9 + 34 + 12
    for _, role in ipairs(R().ROLES) do top.roles[role]:Hide() end
    for _, role in ipairs(R():GetPlayableRoles()) do
        local b = top.roles[role]
        b:SetOn(mine[role])
        b:ClearAllPoints()
        b:SetPoint("LEFT", top, "LEFT", x, 0)
        b:Show()
        x = x + 28
    end
end

local function UpdateStrip(p, width)
    local strip = p.strip
    local list = R():GetUpForRun()
    strip.chips = strip.chips or {}
    local x = (strip.label:GetStringWidth() or 70) + 10
    local shown = 0
    for i, e in ipairs(list) do
        local chip = strip.chips[i]
        if not chip then
            chip = NewChip(strip)
            strip.chips[i] = chip
            chip:SetScript("OnClick", function(self)
                local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
                if self.key and open then open("/w " .. ((Ambiguate and Ambiguate(self.key, "none")) or self.key) .. " ") end
            end)
        end
        FillChip(chip, e)
        local w = chip:GetWidth()
        if x + w <= width - 40 then
            chip:ClearAllPoints()
            chip:SetPoint("LEFT", strip, "LEFT", x, 0)
            chip:Show()
            x = x + w + 6
            shown = shown + 1
        else
            chip:Hide()
        end
    end
    for i = #list + 1, #strip.chips do strip.chips[i]:Hide() end
    local rest = #list - shown
    strip.more:SetShown(rest > 0)
    if rest > 0 then
        strip.more.text:SetText("+" .. rest)
        strip.more:SetWidth((strip.more.text:GetStringWidth() or 20) + 8)
        strip.more:ClearAllPoints()
        strip.more:SetPoint("LEFT", strip, "LEFT", x, 0)
        local names = { "Also up for a run" }
        for i = shown + 1, #list do names[#names + 1] = UI():ColoredName(list[i].key, list[i].class) end
        strip.more.tip = names
    end
    return #list > 0
end

local function CreateStrip(p)
    local strip = CreateFrame("Frame", nil, p)
    strip:SetHeight(STRIP_H)
    p.strip = strip
    strip.label = Text(strip, "GameFontHighlightSmall", 11)
    strip.label:SetTextColor(0.62, 0.62, 0.62)
    strip.label:SetPoint("LEFT", 0, 0)
    strip.label:SetText("Up for a run")
    strip.more = CreateFrame("Frame", nil, strip)
    strip.more:SetHeight(20)
    strip.more.text = Text(strip.more, "GameFontHighlightSmall", 11)
    strip.more.text:SetTextColor(0.62, 0.62, 0.62)
    strip.more.text:SetPoint("LEFT", 4, 0)
    strip.more:EnableMouse(true)
    strip.more:SetScript("OnEnter", function(self) Tip(self, self.tip or {}, "ANCHOR_TOP") end)
    strip.more:SetScript("OnLeave", HideTip)
end

local function SectionHeader(p, i)
    p.headers[i] = p.headers[i] or Text(p.content, "GameFontNormal", 13)
    return p.headers[i]
end

-- The runs to show, by section: mine, now (joinable first, blocked last), later (by start).
local function Sections()
    local mine, now, later = nil, {}, {}
    for _, run in ipairs(R():GetRuns()) do
        if run.o == Me() then
            mine = run
        elseif R():IsNow(run) then
            now[#now + 1] = run
        else
            later[#later + 1] = run
        end
    end
    local function rank(run)
        if R():GetBlocker(run.d, run.h) then return 4 end
        if R():IsInRun(run) then return 0 end
        local fits = R():FitsMe(run) ~= nil
        local bis = #R():GetMyBiSDrops(run.d, run.h) > 0
        if fits and bis then return 1 end
        if fits then return 2 end
        return 3
    end
    tsort(now, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return (a.c or 0) > (b.c or 0)
    end)
    tsort(later, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.id < b.id
    end)
    return mine, now, later
end

function DungeonsUI:Refresh()
    if not panel or not panel:IsVisible() then return end
    local p = panel
    if state.sheet then self:RefreshSheet() end
    local width = p:GetWidth()
    if not width or width < 300 then width = 780 end
    local mine, now, later = Sections()
    -- the bar and the strip are for finding a run: my own run takes their place
    p.top:SetShown(mine == nil)
    local y = -6
    if mine == nil then
        UpdateTop(p)
        y = -(TOP_H + 4)
        p.strip:ClearAllPoints()
        p.strip:SetPoint("TOPLEFT", PAD, y)
        p.strip:SetPoint("TOPRIGHT", -PAD, y)
        if UpdateStrip(p, width - 2 * PAD) then
            p.strip:Show()
            y = y - STRIP_H - 2
        else
            p.strip:Hide()
        end
    else
        p.strip:Hide()
    end
    p.scroll:ClearAllPoints()
    p.scroll:SetPoint("TOPLEFT", PAD, y - 2)
    p.scroll:SetPoint("BOTTOMRIGHT", -PAD - 16, 6)
    local cw = width - 2 * PAD - 16
    p.content:SetWidth(cw)

    local cy, hi, ci = 0, 0, 0
    local function header(text, sub)
        hi = hi + 1
        local fs = SectionHeader(p, hi)
        fs:SetText(text .. (sub and ("  " .. grey(sub)) or ""))
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", p.content, "TOPLEFT", 0, -cy - 6)
        fs:Show()
        cy = cy + SECTION_H
    end
    local function card(run, opts)
        ci = ci + 1
        local c = p.cards[ci]
        if not c then
            c = NewCard(p.content)
            p.cards[ci] = c
        end
        opts.width = cw
        local h = FillCard(c, run, opts)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", p.content, "TOPLEFT", 0, -cy)
        c:Show()
        if run.id == state.focus then state.focusY = cy end
        cy = cy + h + GAP
    end
    if mine then
        header("Your run")
        card(mine, { mine = true })
        cy = cy + 4
    end
    if #now > 0 then
        header("Now")
        for _, run in ipairs(now) do card(run, {}) end
    end
    -- later runs by day: "Later  today", then "Tomorrow", "Saturday 11 Oct", ...
    local lastDay
    for _, run in ipairs(later) do
        local day = DayLabel(run.at)
        if day ~= lastDay then
            if lastDay == nil then header("Later", day) else header(day) end
            lastDay = day
        end
        card(run, {})
    end
    for i = hi + 1, #p.headers do p.headers[i]:Hide() end
    for i = ci + 1, #p.cards do p.cards[i]:Hide() end
    p.content:SetHeight(max(cy, 1))

    -- nothing on the board
    local empty = mine == nil and #now == 0 and #later == 0
    p.empty:SetShown(empty)
    if empty then
        p.empty.title:SetText("No runs listed right now.")
        p.empty.sub:SetText(R():IsUp() and "You'll get a ping as soon as a run needs one of your roles."
            or "List one, or switch on \"I'm up for a run\" to get a ping when a run needs you.")
    end
end

function DungeonsUI:RequestRefresh()
    if panel and panel:IsVisible() then
        ns.Util.Debounce("dungeons-ui", 0.1, function() DungeonsUI:Refresh() end)
    end
    -- a ping or a request goes with its run (an invite, or the Group Finder's word on an ended run, doesn't)
    if toast and toast:IsShown() and toast.run and toast.mode == nil then
        local run = R():GetRun(toast.run)
        if not run then toast:Hide() end
    end
end

-- Opens the tab on a run (a chat link, the Home calendar): scrolls to it and lights it up for a moment. Returns false
-- when the run is not on the board (over, or not here yet).
function DungeonsUI:Focus(id)
    if ns.MainFrame then ns.MainFrame:Open("dungeons") end
    if state.sheet then self:CloseSheet() end
    local run = R():GetRun(id)   -- (a run whose lead passed is found by its old id: focus the run as it is now)
    if not run then return false end
    state.focus, state.focusUntil, state.focusY = run.id, GetTime() + 2.5, nil
    self:Refresh()
    if panel and state.focusY then
        local range = panel.scroll:GetVerticalScrollRange() or 0
        panel.scroll:SetVerticalScroll(min(range, max(0, state.focusY - 30)))
    end
    ns.Util.After(2.6, function() DungeonsUI:Refresh() end)
    return true
end

-- What a run's card tooltip says (the Home calendar uses it too).
function DungeonsUI:GetRunTip(run)
    return CardTip(run)()
end

-- My run's More menu: Edit, Post in LookingForGroup, (listed in the Group Finder:) Look again, Note, Unlist.
function DungeonsUI:OpenMineMenu(owner)
    local Ui = UI()
    Ui:ContextMenu(owner, function(root)
        local function entry(icon, text, tip, fn, color)
            local b = root:CreateButton(Ui:AtlasIconText(icon, 14, color or GOLD) .. "  " .. text, fn)
            if b and b.SetTooltip then
                b:SetTooltip(function(tt)
                    tt:AddLine(text, 1, 0.82, 0)
                    tt:AddLine(tip, 1, 1, 1, true)
                end)
            end
        end
        entry(16, "Edit", "Change the dungeon, the time, the note or your role.",
            function() DungeonsUI:OpenSheet(true) end)
        entry(18, "Post in LFG", "Posts the open places in the LookingForGroup channel: "
            .. (R():GetChannelText() or "nothing is open") .. ".", function()
                local ok, why = R():PostToChannel()
                if not ok and why then ns:Print("%s", why) end
            end)
        -- listed in the Group Finder (the eye on the card): search again, and the note only the player can type
        local GF, mine = ns.GroupFinder, R():GetMine()
        if GF and mine and select(2, GF:GetListing(mine)) then
            entry(Ui.ICON.eye, "Look again", "Searches the Group Finder again for players who want this dungeon.",
                function() GF:Search(mine) end)
            entry(Ui.ICON.notes, "Note", "Opens Blizzard's Group Finder on your listing to write its note. Only you "
                .. "can type it: addons aren't allowed to.", function()
                    if not GF:OpenBlizzard() then ns:Print("Blizzard's Group Finder didn't open.") end
                end)
        end
        if root.CreateDivider then root:CreateDivider() end
        entry(Ui.ICON.trash, "Unlist", "Takes your run off the board, and out of the Group Finder.", function()
            -- (a click: the Group Finder takes listings down only inside one)
            if GF and mine and select(2, GF:GetListing(mine)) then GF:Unlist() end
            R():Unlist()
        end, { 1, 0.4, 0.35 })
    end)
end

function DungeonsUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", "DisasterZoneDungeonsPanel", parent)
    p:SetAllPoints(parent)
    panel = p
    p.headers, p.cards = {}, {}
    CreateTop(p)
    CreateStrip(p)
    p.scroll = UI():CreateScrollFrame(p)
    p.content = CreateFrame("Frame", nil, p.scroll)
    p.content:SetSize(760, 10)
    p.scroll:SetScrollChild(p.content)
    p.empty = CreateFrame("Frame", nil, p)
    p.empty:SetPoint("TOPLEFT", 0, -120)
    p.empty:SetPoint("TOPRIGHT", 0, -120)
    p.empty:SetHeight(60)
    p.empty.title = p.empty:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p.empty.title:SetPoint("TOP", 0, 0)
    p.empty.sub = p.empty:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.empty.sub:SetPoint("TOP", p.empty.title, "BOTTOM", 0, -8)
    p.empty.sub:SetTextColor(0.62, 0.62, 0.62)
    p.empty:Hide()
    p:SetScript("OnShow", function() DungeonsUI:Refresh() end)
    p.OnPanelShown = function() DungeonsUI:Refresh() end
    p.elapsed = 0
    p:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        if self.elapsed >= 30 then
            self.elapsed = 0
            DungeonsUI:Refresh()
        end
    end)
    return p
end

---------------------------------------------------------------------------
-- List a run: the sheet
---------------------------------------------------------------------------

local WHEN = { { key = "now", text = "Now" }, { key = "30", text = "In 30 min" }, { key = "60", text = "In 1 h" },
               { key = "later", text = "Later" } }
local FORM_LABEL_W = 62
local FORM_W = 286
local DAYS_AHEAD = 6
local DAILY_ICON = "|TInterface\\GossipFrame\\DailyQuestIcon:12:12:0:0|t"

-- Minutes after midnight of now (local clock).
local function NowMinutes()
    local t = date("*t", Now())
    return t.hour * 60 + t.min
end

-- The earliest start a later run can have on day `day` (0 = today): a quarter of an hour from now, on a quarter.
local function MinMinutes(day)
    if day > 0 then return 0 end
    return math.ceil((NowMinutes() + 15) / 15) * 15
end

local function DayTime(day, mins)
    local t = date("*t", Now())
    return time({ year = t.year, month = t.month, day = t.day + day, hour = floor(mins / 60), min = mins % 60,
                  sec = 0 })
end

local function SheetTime(s)
    if s.when == "now" then return 0 end
    if s.when == "30" then return Now() + 1800 end
    if s.when == "60" then return Now() + 3600 end
    return DayTime(s.day or 0, s.mins or 0)
end

-- A later run's first suggestion: the next full hour at least an hour away (tomorrow when today is over).
local function DefaultLater(s)
    local mins = math.ceil((NowMinutes() + 60) / 60) * 60
    if mins >= 24 * 60 then
        s.day, s.mins = 1, 20 * 60
    else
        s.day, s.mins = 0, mins
    end
end

-- Keeps day / time valid: today never before now + 15 min.
local function ClampLater(s)
    s.day = min(max(s.day or 0, 0), DAYS_AHEAD)
    if MinMinutes(s.day) >= 24 * 60 then s.day = s.day + 1 end
    s.mins = min(max(s.mins or 0, MinMinutes(s.day)), 24 * 60 - 15)
end

local function DayText(day)
    if day == 0 then return "Today" end
    if day == 1 then return "Tomorrow" end
    local t = DayTime(day, 12 * 60)
    return date("%a ", t) .. tonumber(date("%d", t)) .. date(" %b", t)
end

-- A flat stepper: a value between two chevrons; the chevrons and the mouse wheel step it.
local function Chevron(parent, dir)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(22, 22)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.07)
    b.lines = {}
    for i = 1, 2 do
        local l = b:CreateLine(nil, "ARTWORK")
        l:SetThickness(2)
        l:SetColorTexture(1, 0.82, 0, 1)
        b.lines[i] = l
    end
    local x = dir < 0 and 3 or -3
    b.lines[1]:SetStartPoint("CENTER", x, 5)
    b.lines[1]:SetEndPoint("CENTER", -x, 0)
    b.lines[2]:SetStartPoint("CENTER", -x, 0)
    b.lines[2]:SetEndPoint("CENTER", x, -5)
    function b:SetOn(on)
        self:SetEnabled(on)
        for _, l in ipairs(self.lines) do l:SetAlpha(on and 1 or 0.25) end
    end
    return b
end

local function NewStepper(parent, width, onStep, tip)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width, 24)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.10, 0.10, 0.12, 0.92)
    UI():AddEdges(f)
    UI():SetEdgeColor(f, 0.34, 0.34, 0.38, 0.9)
    f.text = Text(f, "GameFontHighlight", 12)
    f.text:SetPoint("CENTER", 0, 0)
    f.text:SetJustifyH("CENTER")
    f.prev = Chevron(f, -1)
    f.prev:SetPoint("LEFT", 1, 0)
    f.prev:SetScript("OnClick", function() onStep(-1) end)
    f.next = Chevron(f, 1)
    f.next:SetPoint("RIGHT", -1, 0)
    f.next:SetScript("OnClick", function() onStep(1) end)
    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, delta) onStep(delta > 0 and 1 or -1) end)
    f:SetScript("OnEnter", function(self)
        UI():SetEdgeColor(self, 1, 0.82, 0, 0.6)
        Tip(self, tip, "ANCHOR_TOP")
    end)
    f:SetScript("OnLeave", function(self)
        UI():SetEdgeColor(self, 0.34, 0.34, 0.38, 0.9)
        HideTip()
    end)
    function f:Set(text, canPrev, canNext)
        self.text:SetText(text)
        self.prev:SetOn(canPrev)
        self.next:SetOn(canNext)
    end
    return f
end

-- A dungeon tile: the short name, then at most one badge (★ guildies with BiS there, or "Saved"), DAILY on its edge.
local function NewTile(parent)
    local t = CreateFrame("Button", nil, parent)
    t:SetSize(TILE_W, TILE_H)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    UI():AddEdges(t, "BORDER")
    t.name = Text(t, "GameFontHighlight", 12)
    t.name:SetPoint("LEFT", 10, 0)
    t.count = Text(t, "GameFontNormalSmall", 12)
    t.count:SetPoint("RIGHT", -9, 0)
    t.star = t:CreateTexture(nil, "OVERLAY")
    t.star:SetTexture(STAR_TEX)
    t.star:SetSize(11, 11)
    t.star:SetPoint("RIGHT", t.count, "LEFT", -2, 0)
    t.saved = Text(t, "GameFontHighlightSmall", 10)
    t.saved:SetTextColor(0.62, 0.62, 0.62)
    t.saved:SetPoint("RIGHT", -8, 0)
    t.saved:SetText("Saved")
    t.lock = t:CreateTexture(nil, "OVERLAY")
    t.lock:SetTexture(UI().ICON_LOCK)
    t.lock:SetSize(12, 12)
    t.lock:SetPoint("RIGHT", t.saved, "LEFT", -2, 0)
    t.daily = CreateFrame("Frame", nil, t)
    t.daily:SetSize(34, 11)
    t.daily:SetPoint("TOPRIGHT", t, "TOPRIGHT", -8, 6)
    t.daily:SetFrameLevel(t:GetFrameLevel() + 2)
    t.daily.bg = t.daily:CreateTexture(nil, "BACKGROUND")
    t.daily.bg:SetAllPoints()
    t.daily.bg:SetColorTexture(1, 0.82, 0, 1)
    t.daily.text = Text(t.daily, "GameFontNormalSmall", 8)
    t.daily.text:SetPoint("CENTER", 0, 0)
    t.daily.text:SetTextColor(0.1, 0.08, 0)
    t.daily.text:SetText("DAILY")
    t.daily:SetWidth((t.daily.text:GetStringWidth() or 26) + 8)
    t:SetScript("OnEnter", function(self)
        local lines = self.tip and self.tip()
        if lines then Tip(self, lines, "ANCHOR_TOP") end
    end)
    t:SetScript("OnLeave", HideTip)
    return t
end

local DAILY_WORDS = {
    log = "Your daily quest for it is in your quest log.",
    today = "Today's daily: you haven't done it yet.",
    done = "Today's daily: done.",
}

-- The tile's tooltip, or nil when it would only repeat the name on the tile.
local function TileTip(info, heroic)
    return function()
        local lines = { info.name .. (heroic and " (Heroic)" or "") }
        local block, kind = R():GetBlocker(info.key, heroic)
        if kind == "saved" then
            lines[#lines + 1] = orange(block) .. grey(" (the daily reset)")
        elseif block then
            lines[#lines + 1] = orange(block)
        end
        local daily = R():GetMyDaily(info.key, heroic)
        if daily then
            lines[#lines + 1] = (daily == "done" and grey(DAILY_WORDS.done))
                or (DAILY_ICON .. " " .. gold(DAILY_WORDS[daily]))
        end
        local n, who = R():GetNeeders(info.key, heroic)
        if n > 0 then
            local names = {}
            for i, k in ipairs(who) do
                if i > 8 then names[#names + 1] = "+" .. (#who - 8) break end
                names[#names + 1] = UI():ColoredName(k)
            end
            lines[#lines + 1] = STAR .. " " .. n .. (n == 1 and " guildie online has" or " guildies online have")
                .. " BiS here: " .. tconcat(names, ", ")
        end
        local drops = R():GetMyBiSDrops(info.key, heroic)
        if #drops > 0 then
            lines[#lines + 1] = gold("Drops your BiS:")
            for i, id in ipairs(drops) do
                if i > 6 then lines[#lines + 1] = grey("+" .. (#drops - 6) .. " more") break end
                lines[#lines + 1] = "  " .. ItemLinkText(id)
            end
        end
        if #lines == 1 and info.short == info.name then return nil end
        return lines
    end
end

local function NewComplexRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(ROW_H)
    r.art = r:CreateTexture(nil, "BACKGROUND", nil, 0)
    r.art:SetAllPoints()
    r.shadeL = r:CreateTexture(nil, "BACKGROUND", nil, 1)
    r.shadeL:SetColorTexture(0.035, 0.035, 0.043, 0.94)
    r.shadeL:SetPoint("TOPLEFT")
    r.shadeL:SetPoint("BOTTOMLEFT")
    r.shadeL:SetWidth(170)
    r.shadeR = r:CreateTexture(nil, "BACKGROUND", nil, 1)
    r.shadeR:SetColorTexture(1, 1, 1, 1)
    r.shadeR:SetPoint("TOPLEFT", r.shadeL, "TOPRIGHT")
    r.shadeR:SetPoint("BOTTOMRIGHT")
    if r.shadeR.SetGradient and CreateColor then
        r.shadeR:SetGradient("HORIZONTAL", CreateColor(0.035, 0.035, 0.043, 0.8), CreateColor(0.035, 0.035, 0.043, 0.4))
    end
    UI():AddEdges(r, "BORDER")
    UI():SetEdgeColor(r, 0.34, 0.34, 0.38, 0.5)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(30, 30)
    r.icon:SetPoint("LEFT", 9, 0)
    r.name = Text(r, "GameFontNormal", 12)
    r.why = Text(r, "GameFontHighlightSmall", 10)
    r.why:SetTextColor(1, 0.55, 0.1)
    r.whyHit = CreateFrame("Frame", nil, r)
    r.whyHit:SetPoint("TOPLEFT", r.why, "TOPLEFT")
    r.whyHit:SetPoint("BOTTOMRIGHT", r.why, "BOTTOMRIGHT")
    r.whyHit:EnableMouse(true)
    r.whyHit:SetScript("OnEnter", function(self) if self.tip then Tip(self, self.tip, "ANCHOR_TOP") end end)
    r.whyHit:SetScript("OnLeave", HideTip)
    r.tiles = {}
    return r
end

local function SheetSelect(key)
    local s = state.sheet
    if not s then return end
    s.d = key
    s.err = nil
    DungeonsUI:RefreshSheet()
end

local function FormLabel(parent, text)
    local fs = Text(parent, "GameFontHighlightSmall", 11)
    fs:SetTextColor(0.62, 0.62, 0.62)
    fs:SetText(text)
    return fs
end

local function CreateSheet(p)
    local sh = CreateFrame("Frame", nil, p)
    sh:SetAllPoints(p)
    sh:SetFrameLevel(p:GetFrameLevel() + 20)
    sh:EnableMouse(true)
    sh.bg = sh:CreateTexture(nil, "BACKGROUND")
    sh.bg:SetAllPoints()
    sh.bg:SetColorTexture(SHEET_BG[1], SHEET_BG[2], SHEET_BG[3], SHEET_BG[4])
    sh.title = Text(sh, "GameFontNormal", 15)
    sh.title:SetPoint("TOPLEFT", PAD, -12)
    sh.normal = NewButton(sh, "Normal", 82, 24, "secondary", function()
        state.sheet.h = false
        state.sheet.err = nil
        DungeonsUI:RefreshSheet()
    end)
    sh.heroic = NewButton(sh, "Heroic", 82, 24, "secondary", function()
        state.sheet.h = true
        state.sheet.err = nil
        DungeonsUI:RefreshSheet()
    end)
    sh.heroic.skull = sh.heroic:CreateTexture(nil, "OVERLAY")
    sh.heroic.skull:SetTexture(HEROIC_TEX)
    sh.heroic.skull:SetTexCoord(0, 0.5, 0, 0.625)
    sh.heroic.skull:SetSize(10, 13)
    sh.heroic.skull:SetPoint("RIGHT", sh.heroic:GetFontString(), "LEFT", -3, 0)
    sh.close = UI():CreateIconButton(sh, 24, NO_TEX, nil, function() DungeonsUI:CloseSheet() end)
    sh.close.icon:SetDesaturated(true)
    sh.close:SetPoint("TOPRIGHT", -PAD, -9)
    sh.close:SetScript("OnEnter", function(self) Tip(self, { "Close", "Nothing is listed." }, "ANCHOR_LEFT") end)
    sh.close:SetScript("OnLeave", HideTip)
    sh.rows = {}

    -- the form: When, (At), Note, You go as; its rows anchored once inside sh.form
    local form = CreateFrame("Frame", nil, sh)
    form:SetSize(FORM_LABEL_W + FORM_W, 140)
    sh.form = form
    sh.whenLabel = FormLabel(form, "When")
    sh.whenLabel:SetPoint("TOPLEFT", 0, -6)
    sh.when = {}
    local prev
    for i, def in ipairs(WHEN) do
        local key = def.key
        local b = NewButton(form, def.text, nil, 24, "secondary", function()
            local s = state.sheet
            if s.when == key then return end
            s.when = key
            if key == "later" and not s.mins then DefaultLater(s) end
            DungeonsUI:RefreshSheet()
        end)
        b.key = key
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", FORM_LABEL_W, 0) end
        sh.when[i] = b
        prev = b
    end
    sh.atRow = CreateFrame("Frame", nil, form)
    sh.atRow:SetSize(FORM_LABEL_W + FORM_W, 24)
    sh.atRow:SetPoint("TOPLEFT", 0, -33)
    sh.atLabel = FormLabel(sh.atRow, "At")
    sh.atLabel:SetPoint("LEFT", 0, 0)
    local stepTip = { "Pick the time", "Click the arrows or scroll. Your clock; everybody sees it in theirs." }
    sh.day = NewStepper(sh.atRow, 150, function(dir)
        local s = state.sheet
        s.day = (s.day or 0) + dir
        ClampLater(s)
        DungeonsUI:RefreshSheet()
    end, stepTip)
    sh.day:SetPoint("LEFT", FORM_LABEL_W, 0)
    sh.time = NewStepper(sh.atRow, 96, function(dir)
        local s = state.sheet
        s.mins = (s.mins or 0) + dir * 15
        ClampLater(s)
        DungeonsUI:RefreshSheet()
    end, stepTip)
    sh.time:SetPoint("LEFT", sh.day, "RIGHT", 6, 0)
    sh.noteRow = CreateFrame("Frame", nil, form)
    sh.noteRow:SetSize(FORM_LABEL_W + FORM_W, 24)
    sh.noteLabel = FormLabel(sh.noteRow, "Note")
    sh.noteLabel:SetPoint("LEFT", 0, 0)
    sh.note = UI():CreateSleekEditBox(sh.noteRow, FORM_W, 24, "GameFontHighlightSmall")
    sh.note:SetPoint("LEFT", FORM_LABEL_W, 0)
    sh.note:SetMaxLetters(R().NOTE_MAX)
    sh.note:SetScript("OnTextChanged", function(self)
        if state.sheet then state.sheet.no = self:GetText() end
        DungeonsUI:RefreshSheetPreview()
    end)
    UI():SetEditPlaceholder(sh.note, "Optional, e.g. \"badge run, fast pulls\"")
    sh.roleRow = CreateFrame("Frame", nil, form)
    sh.roleRow:SetSize(FORM_LABEL_W + FORM_W, 24)
    sh.roleRow:SetPoint("TOPLEFT", sh.noteRow, "BOTTOMLEFT", 0, -9)
    sh.roleLabel = FormLabel(sh.roleRow, "You go as")
    sh.roleLabel:SetPoint("LEFT", 0, 0)
    sh.roles = {}
    for _, role in ipairs(R().ROLES) do
        sh.roles[role] = NewRoleChip(sh.roleRow, role, function()
            state.sheet.role = role
            DungeonsUI:RefreshSheet()
        end)
        sh.roles[role]:SetScript("OnEnter", function(self)
            Tip(self, { R().ROLE_LABEL[role], "The role you play in this run." }, "ANCHOR_TOP")
        end)
    end
    -- the Group Finder too (a run for now: listed with the same click; for later: a pop-up when it starts)
    sh.gfRow = CreateFrame("Frame", nil, form)
    sh.gfRow:SetSize(FORM_LABEL_W + FORM_W, 24)
    sh.gfRow:SetPoint("TOPLEFT", sh.roleRow, "BOTTOMLEFT", 0, -9)
    sh.gfLabel = FormLabel(sh.gfRow, "Pugs")
    sh.gfLabel:SetPoint("LEFT", 0, 0)
    local function flip()
        state.sheet.gf = not state.sheet.gf
        DungeonsUI:RefreshSheet()
    end
    local function gfTip(self)
        Tip(self, { "Group Finder", "Also puts your run in Blizzard's Group Finder, for players outside the guild. "
            .. "Whoever looks for this dungeon there, or whispers you, shows up on your run.",
            grey("A run for later: you get a pop-up when it starts.") }, "ANCHOR_TOP")
    end
    sh.gf = NewSwitch(sh.gfRow, flip)
    sh.gf:SetPoint("LEFT", FORM_LABEL_W, 0)
    sh.gf:SetScript("OnEnter", gfTip)
    sh.gf:SetScript("OnLeave", HideTip)
    sh.gfText = CreateFrame("Button", nil, sh.gfRow)
    sh.gfText.text = Text(sh.gfText, "GameFontHighlightSmall", 12)
    sh.gfText.text:SetPoint("LEFT")
    sh.gfText:SetPoint("LEFT", sh.gf, "RIGHT", 8, 0)
    sh.gfText:SetScript("OnClick", flip)
    sh.gfText:SetScript("OnEnter", gfTip)
    sh.gfText:SetScript("OnLeave", HideTip)

    -- the preview and the button
    sh.previewLabel = FormLabel(sh, "Preview")
    sh.preview = NewCard(sh)
    sh.preview:EnableMouse(false)
    sh.pick = Text(sh, "GameFontHighlightSmall", 12)
    sh.pick:SetTextColor(0.62, 0.62, 0.62)
    sh.pick:SetText("Pick a dungeon above.")
    sh.err = Text(sh, "GameFontHighlightSmall", 11)
    sh.err:SetTextColor(1, 0.55, 0.1)
    sh.go = NewButton(sh, "List run", 130, 28, "primary", function() DungeonsUI:SubmitSheet() end)
    sh:Hide()
    p.sheet = sh
    return sh
end

function DungeonsUI:RefreshSheetPreview()
    local sh = panel and panel.sheet
    local s = state.sheet
    if not sh or not s then return end
    local info = s.d and R():GetDungeon(s.d)
    sh.preview:SetShown(info ~= nil)
    sh.pick:SetShown(info == nil)
    if not info then return end
    local party = { { k = Me(), r = s.role } }
    for key in pairs(ns.Util.group or {}) do
        if not ns.Util.IsMe(key) then party[#party + 1] = { k = key, r = R():GetRoleOf(key) } end
    end
    local mine = R():GetMine()
    local run = { id = "preview", o = Me(), d = s.d, h = s.h or nil, at = SheetTime(s), c = mine and mine.c or Now(),
                  no = (s.no and ns.Util.Trim(s.no) ~= "") and ns.Util.Trim(s.no) or nil, s = party }
    if run.at > 0 and run.at <= Now() + 60 then run.at = 0 end
    FillCard(sh.preview, run, { width = sh.previewW or 390, compact = true })
end

-- Lays out the complex rows; returns the y under them.
local function SheetRows(sh, s, width)
    local y = -44
    local rowW = width - 2 * PAD
    local ri = 0
    for _, c in ipairs(R():GetComplexes()) do
        ri = ri + 1
        local r = sh.rows[ri] or NewComplexRow(sh)
        sh.rows[ri] = r
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, y)
        r:SetWidth(rowW)
        local file, l, rr, t, b = R():GetComplexArt(c.key, rowW, ROW_H)
        if file then
            r.art:SetTexture(file)
            r.art:SetTexCoord(l, rr, t, b)
        end
        r.icon:SetTexture(c.icon)
        r.name:SetText(c.name)
        -- the heroic key or the level holds back the whole complex: said once, on the row
        local whyAll, whyTip
        if s.h then
            local text, kind = R():GetBlocker(c.dungeons[1].key, true)
            if kind == "rep" or kind == "level" then
                whyAll = kind == "rep" and "Needs Revered" or text
                whyTip = { c.name, text .. (kind == "rep" and " for the heroic key." or ".") }
            end
        end
        r.name:ClearAllPoints()
        if whyAll then
            r.name:SetPoint("BOTTOMLEFT", r.icon, "RIGHT", 9, 1)
            r.why:SetText(whyAll)
            r.why:ClearAllPoints()
            r.why:SetPoint("TOPLEFT", r.icon, "RIGHT", 9, -1)
            r.why:Show()
            r.whyHit.tip = whyTip
            r.whyHit:Show()
        else
            r.name:SetPoint("LEFT", r.icon, "RIGHT", 9, 0)
            r.why:Hide()
            r.whyHit:Hide()
        end
        for i, info in ipairs(c.dungeons) do
            local tile = r.tiles[i] or NewTile(r)
            r.tiles[i] = tile
            tile:ClearAllPoints()
            tile:SetPoint("LEFT", r, "LEFT", 178 + (i - 1) * (TILE_W + TILE_GAP), 0)
            tile.name:SetText(info.short)
            local block, kind = R():GetBlocker(info.key, s.h)
            local daily = R():GetMyDaily(info.key, s.h)
            local n = R():GetNeeders(info.key, s.h)
            local sel = s.d == info.key
            local off = block ~= nil
            if off then
                tile.bg:SetColorTexture(0.055, 0.055, 0.067, 0.7)
                UI():SetEdgeColor(tile, 0.34, 0.34, 0.38, 0.45)
                tile.name:SetTextColor(0.47, 0.47, 0.49)
            elseif sel then
                tile.bg:SetColorTexture(0.27, 0.23, 0.09, 0.92)
                UI():SetEdgeColor(tile, 1, 0.82, 0, 0.9)
                tile.name:SetTextColor(1, 1, 1)
            else
                tile.bg:SetColorTexture(0.055, 0.055, 0.067, 0.86)
                UI():SetEdgeColor(tile, 0.34, 0.34, 0.38, 0.85)
                tile.name:SetTextColor(1, 1, 1)
            end
            local saved = kind == "saved"
            tile.saved:SetShown(saved)
            tile.lock:SetShown(saved)
            local showCount = n > 0 and not off
            tile.count:SetShown(showCount)
            tile.star:SetShown(showCount)
            tile.count:SetText(n)
            tile.daily:SetShown((daily == "log" or daily == "today") and not off)
            tile.tip = TileTip(info, s.h)
            local key = info.key
            tile:SetScript("OnClick", function() if not off then SheetSelect(key) end end)
            tile:Show()
        end
        for i = #c.dungeons + 1, #r.tiles do r.tiles[i]:Hide() end
        r:Show()
        y = y - ROW_H - ROW_GAP
    end
    for i = ri + 1, #sh.rows do sh.rows[i]:Hide() end
    return y
end

function DungeonsUI:RefreshSheet()
    local sh = panel and panel.sheet
    local s = state.sheet
    if not sh or not s then return end
    local width = panel:GetWidth()
    if not width or width < 300 then width = 780 end
    sh.title:SetText(s.edit and "Edit your run" or "List a run")
    sh.normal:ClearAllPoints()
    sh.normal:SetPoint("LEFT", sh.title, "RIGHT", 18, 0)
    sh.heroic:ClearAllPoints()
    sh.heroic:SetPoint("LEFT", sh.normal, "RIGHT", -1, 0)
    sh.normal:SetKind(s.h and "secondary" or "chosen")
    sh.heroic:SetKind(s.h and "chosen" or "secondary")
    sh.heroic.skull:SetAlpha(s.h and 1 or 0.45)

    local y = SheetRows(sh, s, width)
    -- a picked dungeon the switch to heroic made impossible is dropped
    if s.d and R():GetBlocker(s.d, s.h) then s.d = nil end

    -- the form (left) and the preview (right)
    y = y - 8
    sh.form:ClearAllPoints()
    sh.form:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, y)
    for _, b in ipairs(sh.when) do b:SetKind(s.when == b.key and "chosen" or "secondary") end
    local later = s.when == "later"
    sh.atRow:SetShown(later)
    if later then
        ClampLater(s)
        local minDay = MinMinutes(0) >= 24 * 60 and 1 or 0
        sh.day:Set(DayText(s.day), s.day > minDay, s.day < DAYS_AHEAD)
        sh.time:Set(("%02d:%02d"):format(floor(s.mins / 60), s.mins % 60), s.mins > MinMinutes(s.day),
            s.mins < 24 * 60 - 15)
    end
    sh.noteRow:ClearAllPoints()
    sh.noteRow:SetPoint("TOPLEFT", sh.form, "TOPLEFT", 0, later and -66 or -33)
    local x = FORM_LABEL_W
    for _, role in ipairs(R().ROLES) do sh.roles[role]:Hide() end
    for _, role in ipairs(R():GetPlayableRoles()) do
        local b = sh.roles[role]
        b:ClearAllPoints()
        b:SetPoint("LEFT", sh.roleRow, "LEFT", x, 0)
        b:SetOn(s.role == role)
        b:Show()
        x = x + 28
    end
    local GF = ns.GroupFinder
    sh.gfRow:SetShown(GF ~= nil and GF:IsAvailable())
    sh.gf:SetOn(s.gf)
    sh.gfText.text:SetText(later and "List it in the Group Finder when it starts" or "Also list it in the Group Finder")
    sh.gfText.text:SetTextColor(s.gf and 1 or 0.62, s.gf and 1 or 0.62, s.gf and 1 or 0.62)
    sh.gfText:SetSize((sh.gfText.text:GetStringWidth() or 200) + 2, 20)

    local px = PAD + FORM_LABEL_W + FORM_W + 24
    sh.previewW = width - PAD - px
    sh.previewLabel:ClearAllPoints()
    sh.previewLabel:SetPoint("TOPLEFT", sh, "TOPLEFT", px, y - 2)
    sh.preview:ClearAllPoints()
    sh.preview:SetPoint("TOPLEFT", sh, "TOPLEFT", px, y - 18)
    sh.pick:ClearAllPoints()
    sh.pick:SetPoint("TOPLEFT", sh, "TOPLEFT", px, y - 44)
    sh.go:ClearAllPoints()
    sh.go:SetPoint("TOPRIGHT", sh, "TOPRIGHT", -PAD, y - 18 - CARD_H - 8)
    sh.go:SetText(s.edit and "Save" or "List run")
    sh.go:SetEnabled(s.d ~= nil)
    sh.err:ClearAllPoints()
    sh.err:SetPoint("RIGHT", sh.go, "LEFT", -10, 0)
    sh.err:SetText(s.err or "")
    sh.err:SetShown(s.err ~= nil)
    self:RefreshSheetPreview()
end

function DungeonsUI:OpenSheet(edit)
    if not panel then
        if ns.MainFrame then ns.MainFrame:Open("dungeons") end
        if not panel then return end
    end
    local mine = R():GetMine()
    local level = UnitLevel and tonumber(UnitLevel("player")) or 70
    local s = { h = level >= 70, when = "now", role = R():GetGoAs(), edit = edit and mine ~= nil or nil }
    if s.edit then
        s.d, s.h, s.no, s.gf = mine.d, mine.h and true or false, mine.no, mine.gf
        if (mine.at or 0) > Now() then
            local t, n = date("*t", mine.at), date("*t", Now())
            s.when = "later"
            s.day = floor((time({ year = t.year, month = t.month, day = t.day, hour = 12 })
                - time({ year = n.year, month = n.month, day = n.day, hour = 12 })) / 86400 + 0.5)
            s.mins = t.hour * 60 + t.min - t.min % 15
        end
    else
        -- today's daily that is still mine to do, when I can go
        for _, c in ipairs(R():GetComplexes()) do
            for _, info in ipairs(c.dungeons) do
                local daily = R():GetMyDaily(info.key, s.h)
                if not s.d and (daily == "log" or daily == "today") and not R():GetBlocker(info.key, s.h) then
                    s.d = info.key
                end
            end
        end
    end
    if not R():GetMyRoles()[s.role] then
        for _, role in ipairs(R().ROLES) do
            if R():GetMyRoles()[role] then s.role = role break end
        end
    end
    state.sheet = s
    local sh = panel.sheet or CreateSheet(panel)
    sh.note:SetText(s.no or "")
    sh:Show()
    self:RefreshSheet()
end

function DungeonsUI:CloseSheet()
    state.sheet = nil
    if panel and panel.sheet then
        panel.sheet.note:ClearFocus()
        panel.sheet:Hide()
    end
    self:Refresh()
end

function DungeonsUI:SubmitSheet()
    local s = state.sheet
    if not s or not s.d then return end
    local GF = ns.GroupFinder
    local before = R():GetMine()
    local wasListed = GF and before and select(2, GF:GetListing(before)) or false
    local run, why = R():List({ d = s.d, h = s.h, at = SheetTime(s), no = s.no, role = s.role, gf = s.gf })
    if not run then
        s.err = why
        self:RefreshSheet()
        return
    end
    -- the Group Finder follows the run, with this very click (the client lists only inside one): a run for now that
    -- was listed, or is meant to be, is listed as its dungeon (switched when that changed); one moved to later
    -- comes out
    if GF and R():IsNow(run) and (s.gf or wasListed) and not select(2, GF:GetListing(run)) then
        local ok, gfWhy = GF:List(run)
        if not ok and gfWhy then ns:Print("%s", gfWhy) end
    elseif GF and wasListed and not R():IsNow(run) then
        GF:Unlist()
    end
    self:CloseSheet()
end

---------------------------------------------------------------------------
-- The pop-up: a run needs me / somebody asks to join my run
---------------------------------------------------------------------------

local function CreateToast()
    local t = CreateFrame("Button", "DisasterZoneRunToast", UIParent)
    t:SetSize(TOAST_W, TOAST_H)
    t:SetPoint("TOP", UIParent, "TOP", 0, -120)
    t:SetFrameStrata("DIALOG")
    t:SetClampedToScreen(true)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    t.bg:SetColorTexture(0.043, 0.043, 0.051, 0.95)
    UI():AddEdges(t, "BORDER")
    UI():SetEdgeColor(t, 1, 0.82, 0, 0.55)
    t.art = t:CreateTexture(nil, "ARTWORK", nil, 0)
    t.art:SetPoint("TOPLEFT", 1, -1)
    t.fade = t:CreateTexture(nil, "ARTWORK", nil, 2)
    t.fade:SetColorTexture(1, 1, 1, 1)
    t.shade = t:CreateTexture(nil, "ARTWORK", nil, 1)
    t.shade:SetColorTexture(1, 1, 1, 1)
    t.skull = t:CreateTexture(nil, "OVERLAY")
    t.skull:SetTexture(HEROIC_TEX)
    t.skull:SetTexCoord(0, 0.5, 0, 0.625)
    t.skull:SetSize(11, 14)
    t.skull:SetPoint("BOTTOMLEFT", t.art, "BOTTOMLEFT", 7, 7)
    t.heroic = Text(t, "GameFontNormalSmall")
    t.heroic:SetText("Heroic")
    t.heroic:SetPoint("LEFT", t.skull, "RIGHT", 2, 0)
    t.t1 = Text(t, "GameFontHighlight", 13)
    t.t1:SetPoint("TOPLEFT", TOAST_ART + 4, -12)
    t.t2 = Text(t, "GameFontHighlightSmall", 11)
    t.t2:SetPoint("TOPLEFT", t.t1, "BOTTOMLEFT", 0, -3)
    t.t3 = Text(t, "GameFontHighlightSmall", 11)
    t.t3:SetPoint("TOPLEFT", t.t2, "BOTTOMLEFT", 0, -3)
    t.btn = NewButton(t, "Join", 70, 26, "primary")
    t.btn:SetPoint("RIGHT", -14, 0)
    -- the cross: closes the pop-up; on a party invite it declines (the invite is the pop-up's whole point)
    t.x = UI():CreateIconButton(t, 16, NO_TEX, nil, function()
        if t.mode == "invite" then R():AnswerInvite(false) end
        t:Hide()
    end)
    t.x.bg:SetAlpha(0)
    t.x.icon:SetDesaturated(true)
    t.x:SetPoint("TOPRIGHT", -3, -3)
    t.x:SetScript("OnEnter", function(self)
        if t.mode == "invite" then Tip(self, { "Decline", "Says no to the party invite." }, "ANCHOR_TOP") end
    end)
    t.x:SetScript("OnLeave", HideTip)
    t:SetScript("OnClick", function()
        if ns.MainFrame then ns.MainFrame:Open("dungeons") end
        if t.mode ~= "invite" then t:Hide() end
    end)
    t:SetScript("OnUpdate", function(self, dt)
        if self.mode == "invite" then return end   -- an invite stays until it is answered or runs out
        self.left = (self.left or TOAST_FOR) - dt
        if self.left <= 0 then self:Hide() end
    end)
    t:SetScript("OnEnter", function(self) self.left = max(self.left or 0, 8) end)
    t:Hide()
    return t
end

local function Chime()
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_PLAYER_INVITE then PlaySound(SOUNDKIT.IG_PLAYER_INVITE) end
end

-- mode: "invite" (a party invite: no countdown, the cross declines, no chime: Blizzard's invite sound already played)
local function ShowToast(run, l2, l3, btnText, onClick, mode)
    -- a party invite waiting for its answer is never pushed out by a ping
    if mode ~= "invite" and toast and toast:IsShown() and toast.mode == "invite" then
        Chime()
        return
    end
    toast = toast or CreateToast()
    local t = toast
    t.mode = mode
    local file, l, r, tt, b = R():GetArt(run.d, TOAST_ART, TOAST_H - 2)
    t.art:SetSize(TOAST_ART, TOAST_H - 2)
    if file then
        t.art:SetTexture(file)
        t.art:SetTexCoord(l, r, tt, b)
    end
    t.fade:ClearAllPoints()
    t.fade:SetPoint("TOPRIGHT", t.art, "TOPRIGHT")
    t.fade:SetPoint("BOTTOMRIGHT", t.art, "BOTTOMRIGHT")
    t.fade:SetWidth(floor(TOAST_ART * 0.45))
    if t.fade.SetGradient and CreateColor then
        t.fade:SetGradient("HORIZONTAL", CreateColor(0.043, 0.043, 0.051, 0), CreateColor(0.043, 0.043, 0.051, 1))
    end
    t.shade:ClearAllPoints()
    t.shade:SetPoint("BOTTOMLEFT", t.art, "BOTTOMLEFT")
    t.shade:SetPoint("BOTTOMRIGHT", t.art, "BOTTOMRIGHT")
    t.shade:SetHeight(26)
    if t.shade.SetGradient and CreateColor then
        t.shade:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.75), CreateColor(0, 0, 0, 0))
    end
    t.skull:SetShown(run.h and true or false)
    t.heroic:SetShown(run.h and true or false)
    local textW = TOAST_W - TOAST_ART - 4 - 100
    local full, short = DungeonName(run)
    FitText(t.t1, full, short, textW, 13)
    t.t2:SetText(l2 or "")
    t.t3:SetText(l3 or "")
    t.t3:SetShown(l3 ~= nil)
    for _, fs in ipairs({ t.t2, t.t3 }) do fs:SetWidth(textW) end
    t.t1:ClearAllPoints()
    t.t1:SetPoint("TOPLEFT", TOAST_ART + 4, l3 and -12 or -20)
    t.btn:SetText(btnText)
    t.btn:SetScript("OnClick", function()
        onClick()
        t:Hide()
    end)
    t.run = run.id
    t.left = TOAST_FOR
    t:Show()
    if mode ~= "invite" then Chime() end
end

-- True while the Dungeons tab is on screen: the board itself shows what a pop-up would say.
local function BoardShown()
    return panel ~= nil and panel:IsVisible() and not state.sheet
end

function DungeonsUI:OnPing(id)
    local run = R():GetRun(id)
    if not run or BoardShown() then return end
    local role = R():FitsMe(run)
    if not role then return end
    local hint = HintFor(run)
    ShowToast(run, UI():ColoredName(run.o) .. grey(" needs a " .. ROLE_NAME[role]), hint, "Join", function()
        local ok, why = R():Join(id)
        if not ok and why then ns:Print("%s", why) end
    end)
end

function DungeonsUI:OnRequest(id, key)
    local run = R():GetRun(id)
    if not run or run.o ~= Me() then return end
    if BoardShown() then
        Chime()
        return
    end
    local req
    for _, q in ipairs(R():GetRequests(id)) do
        if q.key == key then req = q end
    end
    if not req then return end
    local spec = R():GetSpecLabel(key)
    local l3 = RoleIconText(req.r, 12) .. " " .. grey((spec and (spec .. " ") or "") .. R().ROLE_LABEL[req.r])
    if req.b then l3 = l3 .. "   " .. gold(STAR .. " BiS here") end
    ShowToast(run, UI():ColoredName(key) .. grey(" wants to join"), l3, "Accept", function() R():Accept(id, key) end)
end

-- A run's leader invites me (Blizzard's pop-up closed by Core): this pop-up is the invite, even over the board.
function DungeonsUI:OnInvite(id, from)
    local run = R():GetRun(id)
    if not run then return end
    local a = R():GetAsked(id)
    local role = (a and a.r) or R():FitsMe(run)
    local l3 = role and (RoleIconText(role, 12) .. " " .. grey("as " .. R().ROLE_LABEL[role])) or nil
    ShowToast(run, UI():ColoredName(from) .. grey(" invites you"), l3, "Accept", function() R():AnswerInvite(true) end,
        "invite")
    if panel and panel:IsVisible() then self:RequestRefresh() end
end

function DungeonsUI:OnInviteGone()
    if toast and toast:IsShown() and toast.mode == "invite" then toast:Hide() end
    self:RequestRefresh()
end

-- My run is meant for the Group Finder but isn't listed there (a run for later that started, or one I took over
-- with the lead: Blizzard delists a party whose leader changes): one click lists it.
function DungeonsUI:OnFinderPrompt(id)
    local run = R():GetRun(id)
    local GF = ns.GroupFinder
    if not run or not GF then return end
    local parts = {}
    local open = R():GetOpenRoles(run)
    for _, role in ipairs(R().ROLES) do
        local n = open[role]
        if n then parts[#parts + 1] = (n > 1 and (n .. " ") or "") .. R().ROLE_LABEL[role] end
    end
    ShowToast(run, tconcat(parts, ", ") .. grey(" open in your run"),
        grey("List it in the Group Finder for pugs?"), "List", function()
            local ok, why = GF:List(run)
            if not ok and why then ns:Print("%s", why) end
        end)
end

-- My run ended by itself (full, time up, a raid) but its Group Finder listing is still up: one click takes it down.
-- old = { id, d, h } (the run is gone).
function DungeonsUI:OnFinderLeftover(old)
    local GF = ns.GroupFinder
    if not GF or not old or not R():GetDungeon(old.d) then return end
    ShowToast(old, grey("Your run is over, but it's"), grey("still in the Group Finder."), "Remove",
        function() GF:RemoveLeftover(old) end, "finder")
end

-- For the harness / UI audit.
function DungeonsUI:GetPanel() return panel end
function DungeonsUI:GetToast() return toast end
function DungeonsUI:GetSheetState() return state.sheet end
function DungeonsUI:SetSheet(fields)
    for k, v in pairs(fields or {}) do state.sheet[k] = v end
    self:RefreshSheet()
end

function DungeonsUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("dungeons", "Dungeons", 3.55,
            function(parent) return DungeonsUI:CreatePanel(parent) end,
            function() return (IsInGuild() or (ns.Demo and ns.Demo:IsEnabled())) and true or false end)
    end
    local function refresh() DungeonsUI:RequestRefresh() end
    for _, msg in ipairs({ "DUNGEON_RUNS_UPDATED", "ROSTER_UPDATED", "GROUP_UPDATED", "ITEMINFO_READY",
                           "DEMO_TOGGLED", "PROFESSIONS_UPDATED", "GROUP_FINDER_UPDATED" }) do
        ns:On(msg, refresh)
    end
    ns:On("DUNGEON_RUN_PING", function(id) DungeonsUI:OnPing(id) end)
    ns:On("DUNGEON_RUN_REQUEST", function(id, key) DungeonsUI:OnRequest(id, key) end)
    ns:On("DUNGEON_RUN_INVITE", function(id, from) DungeonsUI:OnInvite(id, from) end)
    ns:On("DUNGEON_RUN_INVITE_GONE", function() DungeonsUI:OnInviteGone() end)
    ns:On("GROUP_FINDER_PROMPT", function(id) DungeonsUI:OnFinderPrompt(id) end)
    ns:On("GROUP_FINDER_LEFTOVER", function(old) DungeonsUI:OnFinderLeftover(old) end)
end
