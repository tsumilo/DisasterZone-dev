if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UIParty.lua", ...) then return end -- DisasterZone Games/Disastercraft/UIParty.lua
-- CraftUI's party: WoW 2.x's party frames under yours (each member's pixel portrait, name, health, mana, the
-- leader's crown, greyed out of reach or dead), the unit menu (right-click a hero in the world or a frame: Invite,
-- Promote to Leader, Uninvite, Leave Party), the invite and resurrect popups, and the Social window (O): who plays
-- now, your party.
local addonName, ns = ...

local UI = ns.CraftUI
local K = UI.Kit
local Craft = ns.Craft
local Combat = Craft.Combat
local Party = Craft.Party

local floor, max, min = math.floor, math.max, math.min

local frames = {}
local menu, social

---------------------------------------------------------------------------
-- The unit menu
---------------------------------------------------------------------------

-- the entries for unit u (a hero): { { label, fn }, ... }
local function MenuFor(u)
    local out = {}
    local key = Party.KeyOf(u)
    local me = Party.Me()
    if not key then return out end
    if key == me then
        if Party.InParty() then out[#out + 1] = { "Leave Party", function() Party.Leave() end } end
        return out
    end
    if not Party.HasMember(key) or not Party.InParty() then
        if Party.IsLeader() then out[#out + 1] = { "Invite", function() Party.Invite(u) end } end
    elseif Party.IsLeader() then
        out[#out + 1] = { "Promote to Leader", function() Party.Promote(key) end }
        out[#out + 1] = { "Uninvite", function() Party.Kick(key) end }
    end
    out[#out + 1] = { "Target", function() Craft.World.SetTarget(u) end }
    return out
end

-- the menu at the cursor (WoW's UnitPopup: a dropdown list with the name on top)
function UI.UnitMenu(u)
    local items = MenuFor(u)
    if #items == 0 then return end
    if not menu then
        menu = K.Frame(UI.hudFrame, 140, 40, K.TOOLTIP_BACKDROP)
        menu:SetFrameStrata("DIALOG")
        menu:EnableMouse(true)
        menu.title = K.Text(menu, "GameFontNormalSmall", "OVERLAY", "LEFT")
        menu.title:SetPoint("TOPLEFT", 12, -10)
        menu.btns = {}
        menu:SetScript("OnUpdate", function(self)
            -- (a click anywhere else closes it)
            if not self:IsMouseOver() and IsMouseButtonDown and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then
                if not self.justOpened then self:Hide() end
            else
                self.justOpened = nil
            end
        end)
    end
    menu.title:SetText(u.name or "")
    items[#items + 1] = { "Cancel", function() end }
    for i, it in ipairs(items) do
        local b = menu.btns[i]
        if not b then
            b = CreateFrame("Button", nil, menu)
            b:SetSize(120, 16)
            b.text = K.Text(b, "GameFontHighlightSmall", "OVERLAY", "LEFT")
            b.text:SetPoint("LEFT", 4, 0)
            b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            menu.btns[i] = b
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", 10, -24 - (i - 1) * 16)
        b.text:SetText(it[1])
        b:SetScript("OnClick", function() menu:Hide() it[2]() end)
        b:Show()
    end
    for i = #items + 1, #menu.btns do menu.btns[i]:Hide() end
    menu:SetHeight(34 + #items * 16)
    local x, y = GetCursorPosition()
    local s = UI.hudFrame:GetEffectiveScale() or 1
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s + 4, y / s - 4)
    menu.justOpened = true
    menu:Show()
end

---------------------------------------------------------------------------
-- Party frames
---------------------------------------------------------------------------

-- WoW's PartyMemberFrame: Interface\TargetingFrame\UI-PartyFrame, the portrait at 7,-6, bars at 47,-12 / -19
local function MemberFrame(parent, i)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(128, 53)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -100 - (i - 1) * 56)
    f.portrait = K.Tex(f, "BACKGROUND")
    f.portrait:SetSize(37, 37)
    f.portrait:SetPoint("TOPLEFT", 7, -6)
    f.art = K.Tex(f, "BORDER", "Interface\\TargetingFrame\\UI-PartyFrame")
    f.art:SetSize(128, 64)
    f.art:SetPoint("TOPLEFT", 0, -2)
    f.hp = K.Bar(f, 70, 7, 0, 1, 0)
    f.hp:SetPoint("TOPLEFT", 47, -12)
    if f.hp.bg then f.hp.bg:Hide() end
    if f.hp.text then f.hp.text:Hide() end
    f.mp = K.Bar(f, 70, 7, 0, 0, 1)
    f.mp:SetPoint("TOPLEFT", 47, -19)
    if f.mp.bg then f.mp.bg:Hide() end
    if f.mp.text then f.mp.text:Hide() end
    f.name = K.Text(f, "GameFontNormalSmall", "OVERLAY", "LEFT")
    f.name:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 46, -10)
    f.name:SetWidth(100)
    f.leader = K.Tex(f, "OVERLAY", "Interface\\GroupFrame\\UI-Group-LeaderIcon")
    f.leader:SetSize(16, 16)
    f.leader:SetPoint("TOPLEFT", 0, 0)
    f.level = K.Text(f, "GameFontNormalSmall", "OVERLAY", "CENTER")
    f.level:SetPoint("CENTER", f, "BOTTOMLEFT", 12, 12)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:SetScript("OnClick", function(self, button)
        local u = self.unit
        if not u then return end
        if button == "RightButton" then UI.UnitMenu(u) else Craft.World.SetTarget(u) end
    end)
    f:SetScript("OnEnter", function(self) if self.unit and K.UnitTooltip then K.UnitTooltip(self, self.unit) end end)
    f:SetScript("OnLeave", K.HideTooltip)
    f:Hide()
    return f
end

function UI.BuildParty(hud)
    for i = 1, Party.MAX - 1 do frames[i] = MemberFrame(hud, i) end
end

-- a member not in this world (out of the game, out of reach): a stand-in with the name and level they told us
local function Ghost(m)
    local peer = m.peer or {}
    return { guid = "P:" .. m.key, kind = "remote", name = peer.name or Party.NameOf(m.key), level = peer.level or 1,
             class = peer.class, hp = peer.hp or 0, hpMax = peer.hpMax or 1, power = 0, powerMax = 0,
             char = { sex = peer.sex, equip = peer.equip or {}, class = peer.class }, far = true }
end

function UI.UpdateParty(dt)
    local list = Party.Members()
    local g = Party.group
    local p = Craft.player
    for i, f in ipairs(frames) do
        local m = list[i]
        if m then
            local u = m.unit or Ghost(m)
            f.unit = m.unit
            f:Show()
            local key = u.guid .. ":" .. (UI.GearKey and u.char and UI.GearKey(u.char) or "")
            if f.key ~= key then f.key = key K.SpritePortrait(f.portrait, u) end
            f.name:SetText(u.name or "")
            f.level:SetText(u.level or "")
            f.hp:SetMinMaxValues(0, max(1, u.hpMax or 1))
            f.hp:SetValue(u.dead and 0 or (u.hp or 0))
            local pm = u.powerMax or 0
            f.mp:SetShown(pm > 0)
            if pm > 0 then
                f.mp:SetMinMaxValues(0, pm)
                f.mp:SetValue(u.power or 0)
                if u.powerType == Craft.POWER_RAGE then f.mp:SetStatusBarColor(1, 0, 0) else f.mp:SetStatusBarColor(0, 0, 1) end
            end
            f.leader:SetShown(g and g.leader == m.key or false)
            -- (out of reach, out of the game or dead: greyed, like WoW's)
            local far = u.far or not p or Craft.UnitDist(p, u) > 40
            f:SetAlpha((far or u.dead or u.ghost) and 0.55 or 1)
        else
            f.unit = nil
            f.key = nil
            f:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Popups: a party invite, a resurrection
---------------------------------------------------------------------------

local function HasPopup() return UI.Popup and UI.Hud and UI.Hud.popup end

Craft:On("partyinvite", function(inv)
    if not HasPopup() then return end
    if not inv then UI.HidePopup("partyinvite") return end
    local who = inv.name or Party.NameOf(inv.from)
    UI.Popup("partyinvite", who .. " invites you to join a group.",
             { "Accept", function() Party.AcceptInvite() end }, { "Decline", function() Party.DeclineInvite() end })
    if K.Play and K.SFX and K.SFX.invite then K.Play(K.SFX.invite) end
end)

Craft:On("resoffer", function(r)
    if not HasPopup() or not r then return end
    UI.Popup("netres", (r.name or "Someone") .. " wants to resurrect you.",
             { "Accept", function() Party.AcceptResurrect() end }, { "Decline", function() Party.resOffer = nil end })
end)

Craft:On("party", function() if social and social:IsShown() then UI.RefreshSocial() end end)
Craft:On("peers", function() if social and social:IsShown() then UI.RefreshSocial() end end)

-- right-click a hero in the world: its menu
Craft:On("unitmenu", function(u) UI.UnitMenu(u) end)

---------------------------------------------------------------------------
-- The Social window (O): who plays now, your party
---------------------------------------------------------------------------

local ROWS = 12

local function Social()
    if social then return social end
    local f = K.Window(UI.hudFrame, 300, 380, "Social", function() UI.CloseWindow(social) end)
    f.head = K.Text(f, "GameFontNormalSmall", "OVERLAY", "LEFT")
    f.head:SetPoint("TOPLEFT", 22, -40)
    f.head:SetText("Playing now")
    f.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, f)
        r:SetSize(256, 20)
        r:SetPoint("TOPLEFT", 22, -58 - (i - 1) * 22)
        r.name = K.Text(r, "GameFontHighlightSmall", "OVERLAY", "LEFT")
        r.name:SetPoint("LEFT", 0, 0)
        r.name:SetWidth(170)
        r.info = K.Text(r, "GameFontDisableSmall", "OVERLAY", "LEFT")
        r.info:SetPoint("LEFT", r.name, "LEFT", 96, 0)
        r.act = K.Button(r, "", 72, 18)
        r.act:SetPoint("RIGHT", 0, 0)
        r:Hide()
        f.rows[i] = r
    end
    f.leave = K.Button(f, "Leave Party", 120, 22, function() Party.Leave() UI.RefreshSocial() end)
    f.leave:SetPoint("BOTTOM", 0, 22)
    f.empty = K.Text(f, "GameFontDisableSmall", "OVERLAY", "CENTER")
    f.empty:SetPoint("TOP", 0, -80)
    f.empty:SetWidth(240)
    f.empty:SetText("Nobody else from the guild is playing right now.")
    social = f
    return f
end

function UI.RefreshSocial()
    local f = social
    if not f or not f:IsShown() then return end
    local keys = Party.PlayingKeys()
    local me = Party.Me()
    local n = 0
    for _, key in ipairs(keys) do
        if key ~= me and n < ROWS then
            n = n + 1
            local r = f.rows[n]
            local peer = Party.peers[key] or {}
            local inParty = Party.InParty() and Party.HasMember(key)
            r.name:SetText((inParty and "|cff8888ff" or "|cffffffff") .. (peer.name or Party.NameOf(key)) .. "|r")
            r.info:SetText(string.format("%d %s", peer.level or 1, Craft.CLASS_NAMES[peer.class or 1] or ""))
            if inParty then
                r.act:SetShown(Party.IsLeader())
                r.act:SetText("Uninvite")
                r.act:SetScript("OnClick", function() Party.Kick(key) UI.RefreshSocial() end)
            else
                r.act:SetShown(Party.IsLeader())
                r.act:SetText("Invite")
                r.act:SetScript("OnClick", function() Party.Invite(Combat.units["P:" .. key] or (peer.name or key)) end)
            end
            r:Show()
        end
    end
    for i = n + 1, ROWS do f.rows[i]:Hide() end
    f.empty:SetShown(n == 0)
    f.leave:SetShown(Party.InParty())
end

function UI.ToggleParty()
    local f = Social()
    if f:IsShown() then UI.CloseWindow(f) return end
    UI.ShowWindow("party", f)
    UI.RefreshSocial()
end
