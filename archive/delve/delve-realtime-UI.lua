-- CDLoot Games/RPG/UI.lua
-- ns.RPGUI: the Delve lobby (your hero card + model, class kit, heroic, reputation, party) and the battlefield:
-- party frames (model, hp / resource / cast bars, status) on the left, enemies (creature models, cast bars,
-- target line) on the right, an ability bar (keys 1-4), click targeting, floating combat text, and overlays for
-- the path vote, loot, talents and the end screen. Everything is driven by RPGSim state + its fx events.
local addonName, ns = ...

local RPGUI = ns:NewModule("RPGUI")
local D = ns.RPGData
local Sim = ns.RPGSim

local ANIM = { stand = 0, death = 1, stun = 14, unarmed = 16, oneHand = 17, readyUnarmed = 25,
               bow = 46, rifle = 49, castDirected = 53, castOmni = 54 }
local HOLD = 0.8
local ROLE_LABEL = { tank = "Tank", healer = "Healer", melee = "Melee", caster = "Caster", ranged = "Ranged" }
local ROLE_ANIM = { tank = ANIM.oneHand, melee = ANIM.oneHand, ranged = ANIM.bow, caster = ANIM.castDirected,
                    healer = ANIM.castOmni }

local root, lobbyView, gameView
local W = {}                       -- lobby widgets
local G = {}                       -- game widgets
local heroFrames, enemyFrames, abilityButtons = {}, {}, {}
local texts, textPool = {}, {}
local selEnemy, selAlly = nil, nil
local actAt = {}                   -- ["h1"] / ["e3"] = GetTime() of the last attack / cast (animations)
local bannerUntil = 0

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function ClassColor(class)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    return c and string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) or "|cffffffff"
end

local function ClassIcon(tex, class)
    tex:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
    local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if c then tex:SetTexCoord(unpack(c)) else tex:SetTexCoord(0, 1, 0, 1) end
end

local function Short(key) return (type(key) == "string" and key:match("^([^%-]+)")) or tostring(key) end

local function UnitFor(key)
    if key == ns.Util.PlayerKey() then return "player" end
    local prefix, n = "party", 4
    if IsInRaid() then prefix, n = "raid", 40 end
    for i = 1, n do
        local u = prefix .. i
        if UnitExists(u) and ns.Util.UnitKey(u) == key then return u end
    end
    return nil
end

local function Bar(parent, h, r, g, b)
    local bg = parent:CreateTexture(nil, "ARTWORK", nil, 1)
    bg:SetColorTexture(0, 0, 0, 0.75)
    bg:SetHeight(h)
    local fill = parent:CreateTexture(nil, "ARTWORK", nil, 2)
    fill:SetColorTexture(r, g, b, 0.95)
    fill:SetHeight(h - 2)
    fill:SetPoint("LEFT", bg, "LEFT", 1, 0)
    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("CENTER", bg, "CENTER")
    return { bg = bg, fill = fill, text = text,
             Set = function(self, v, m, label)
                 local w = self.bg:GetWidth() - 2
                 local pct = (m and m > 0) and math.max(0, math.min(1, v / m)) or 0
                 self.fill:SetWidth(math.max(0.01, w * pct))
                 self.fill:SetShown(pct > 0)
                 self.text:SetText(label or "")
             end,
             Show = function(self, on) self.bg:SetShown(on) self.fill:SetShown(on) self.text:SetShown(on) end }
end

---------------------------------------------------------------------------
-- Models
---------------------------------------------------------------------------

local function FitCamera(m)
    pcall(m.SetPortraitZoom, m, 0)
    pcall(m.SetCamDistanceScale, m, 1.3)      -- a little headroom so big models / weapons / glows fit
    pcall(m.SetPosition, m, 0, 0, 0)
    if m.RefreshCamera then pcall(m.RefreshCamera, m) end
end

-- Draw weapons: only sticks once the model has loaded, so it is repeated from OnModelLoaded.
local function Unsheathe(m)
    if m.unit and m.SetSheathed then pcall(m.SetSheathed, m, false) end
end

-- dressable: a DressUpModel (supports SetSheathed) for player characters.
local function NewModel(parent, dressable)
    local ok, m = pcall(CreateFrame, dressable and "DressUpModel" or "PlayerModel", nil, parent)
    if not ok or not m then m = CreateFrame("PlayerModel", nil, parent) end
    pcall(m.SetScript, m, "OnModelLoaded", function(self)
        FitCamera(self)
        Unsheathe(self)
        if self.facing then pcall(self.SetFacing, self, self.facing) end
        if self.anim then local a = self.anim self.anim = nil pcall(self.SetAnimation, self, a) self.anim = a end
    end)
    return m
end

local function Facing(m, dir)
    local flip = ns.Games:GetData("rpg").flipFacing and -1 or 1
    local want = dir * flip * math.pi / 2
    if m.facing ~= want then
        m.facing = want
        pcall(m.SetFacing, m, want)
    end
end

local function SetAnim(m, anim)
    if m.anim ~= anim and m.SetAnimation then
        m.anim = anim
        pcall(m.SetAnimation, m, anim)
    end
end

local modelState = {}   -- [enemy id] = { idx, ok }
local function Candidates(key, list)
    local over = ns.Games:GetData("rpg").displays
    local id = type(over) == "table" and tonumber(over[key])
    return id and { id } or (list or {})
end

-- First working creature display for `key`, validated 1.5s after it is set (models load asynchronously).
local function ApplyCreature(m, key, list)
    local st = modelState[key]
    if not st then st = { idx = 1 } modelState[key] = st end
    local id = Candidates(key, list)[st.idx]
    if not id then return false end
    if m.displayId ~= id then
        pcall(m.SetDisplayInfo, m, id)
        m.displayId, m.setAt, m.anim, m.unit = id, GetTime(), nil, nil
        FitCamera(m)
    end
    if not st.ok and m:IsVisible() and GetTime() - m.setAt > 1.5 then
        local file = m.GetModelFileID and m:GetModelFileID()
        if not m.GetModelFileID or (file and file ~= 0) then st.ok = true
        else st.idx, m.displayId = st.idx + 1, nil end
    end
    return true
end

local function ApplyUnit(m, unit)
    if m.unit ~= unit then
        m.unit, m.displayId, m.anim, m.sheathed = unit, nil, nil, nil
        pcall(m.SetUnit, m, unit)
        FitCamera(m)
        m.unsheatheAt = GetTime() + 0.5
    end
    -- fight with weapons drawn (re-applied shortly after load in case the load event came early)
    if m.unsheatheAt and GetTime() >= m.unsheatheAt then
        m.unsheatheAt = nil
        Unsheathe(m)
    end
end

---------------------------------------------------------------------------
-- Floating text + banner
---------------------------------------------------------------------------

local function Float(anchor, text, r, g, b, big)
    if not anchor or not anchor:IsVisible() then return end
    local fs = table.remove(textPool) or G.fx:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(big and "GameFontNormalLarge" or "GameFontNormal")
    fs:SetText(text)
    fs:SetTextColor(r, g, b, 1)
    fs:Show()
    local x, y = anchor:GetCenter()
    local bx, by = G.fx:GetLeft(), G.fx:GetTop()
    if not x or not bx then fs:Hide() textPool[#textPool + 1] = fs return end
    texts[#texts + 1] = { fs = fs, x = x - bx + math.random(-12, 12), y = y - by + 20, t0 = GetTime(), dur = big and 1.5 or 1.0 }
end

local function Banner(text, secs)
    G.banner:SetText(text)
    G.banner:SetAlpha(1)
    G.banner:Show()
    bannerUntil = GetTime() + (secs or 2.5)
end

local function AnimateTexts()
    local now = GetTime()
    for i = #texts, 1, -1 do
        local t = texts[i]
        local f = (now - t.t0) / t.dur
        if f >= 1 then
            t.fs:Hide()
            textPool[#textPool + 1] = t.fs
            table.remove(texts, i)
        else
            t.fs:ClearAllPoints()
            t.fs:SetPoint("CENTER", G.fx, "TOPLEFT", t.x, t.y + f * 30)
            t.fs:SetAlpha(f < 0.7 and 1 or (1 - (f - 0.7) / 0.3))
        end
    end
    if G.banner:IsShown() then
        local left = bannerUntil - now
        if left <= 0 then G.banner:Hide() elseif left < 0.5 then G.banner:SetAlpha(left / 0.5) end
    end
end

local function HandleFx(game, e)
    local S = game.S
    local k = e.k
    if k == "hit" then
        local f = enemyFrames[e.e]
        if e.p then actAt["h" .. e.p] = GetTime() end
        local mine = e.p == game.me
        if e.crit then Float(f, e.amt .. "!", 1, 0.85, 0.1, true)
        elseif mine or e.label ~= "auto" then Float(f, tostring(e.amt), mine and 1 or 0.8, mine and 1 or 0.8, mine and 1 or 0.8) end
    elseif k == "hurt" then
        local f = heroFrames[e.p]
        if e.amt > 0 then Float(f, "-" .. e.amt, 1, 0.25, 0.25, e.label ~= nil) end
        if e.absorbed then Float(f, "(" .. e.absorbed .. " absorbed)", 0.6, 0.8, 1) end
        if e.label then Float(f, e.label, 1, 0.5, 0.2) end
    elseif k == "heal" then
        if e.from then actAt["h" .. e.from] = GetTime() end
        if e.amt > 0 then Float(heroFrames[e.p], "+" .. e.amt, 0.3, 1, 0.3, e.crit) end
    elseif k == "swing" then
        actAt["e" .. e.e] = GetTime()
    elseif k == "cast" then
        actAt["h" .. e.p] = GetTime()
    elseif k == "ecast" then
        local def = D.enemies[S.enemies[e.e].kind]
        if def.boss then Banner("|cffff8000" .. def.name .. " begins to cast " .. e.name .. "!|r", 2) end
    elseif k == "interrupt" then
        Float(enemyFrames[e.e], "Interrupted!", 0.4, 0.8, 1, true)
    elseif k == "cc" then
        Float(enemyFrames[e.e], "Crowd controlled", 0.8, 0.5, 1)
    elseif k == "slow" then
        Float(enemyFrames[e.e], "Slowed", 0.6, 0.8, 1)
    elseif k == "taunt" then
        Float(enemyFrames[e.e], "Taunted", 1, 0.6, 0.2)
    elseif k == "enrage" then
        Banner("|cffff4040" .. D.enemies[S.enemies[e.e].kind].name .. ": " .. e.name .. "!|r", 2.5)
    elseif k == "summon" then
        Banner("|cffff8000" .. e.name .. "|r", 2.5)
    elseif k == "stun" then
        Banner("|cffff4040" .. e.name .. "! The party is stunned.|r", 2)
    elseif k == "herodie" then
        Float(heroFrames[e.p], "Dead", 1, 0.2, 0.2, true)
    elseif k == "die" then
        Float(enemyFrames[e.e], "Slain", 0.8, 0.8, 0.8)
    elseif k == "level" then
        Banner(string.format("%s reached level %d!", S.party[e.p].name, e.n), 2)
        if e.p == game.me and PlaySound and SOUNDKIT and SOUNDKIT.UI_LEVELUP then pcall(PlaySound, SOUNDKIT.UI_LEVELUP) end
    elseif k == "blessing" then
        Banner("|cff33ff99" .. D.blessings[e.b].name .. "|r for the whole party!", 3)
    elseif k == "rest" then
        Banner("|cff33ff99The party rests by the fire.|r", 2.5)
    elseif k == "room" then
        Banner(string.format("|cffffd100%s|r", D.rooms[e.room].name), 2)
    elseif k == "boss" then
        Banner("|cffff8000" .. D.enemies[e.kind].name .. "|r", 2.5)
    elseif k == "victory" then
        Banner("|cff33ff99Victory!|r", 2)
    elseif k == "wipe" then
        Banner("|cffff4040The party has fallen.|r", 4)
    end
end

---------------------------------------------------------------------------
-- Lobby
---------------------------------------------------------------------------

local function KitLine(hero)
    local parts = {}
    for i = 1, 4 do
        local _, icon = D.AbilityLabel(hero.class, D.kits[hero.role][i].id)
        parts[#parts + 1] = "|T" .. icon .. ":18|t"
    end
    return table.concat(parts, " ")
end

local function HeroLine(h)
    if not h then return "|cff888888(joining...)|r" end
    return string.format("%s%s|r  %s%s  |cffffd100%d%%|r power  %s", ClassColor(h.class), h.name or "?",
        (h.spec and h.spec ~= "") and (h.spec .. " ") or "", ROLE_LABEL[h.role] or h.role, h.power or 100, KitLine(h))
end

local function RefreshLobby()
    local R = ns.RPG
    local me = R:GetMyHero()
    W.hero:SetText(HeroLine(me) .. string.format("\n|cff888888Average item level %d: better gear, more power "
        .. "(60-200%%). Your spec picks your abilities (set it in My BiS).|r", me.ilvl or 0))
    if not W.modelSet then
        pcall(W.model.SetUnit, W.model, "player")
        FitCamera(W.model)
        W.modelSet = true
    end
    local rep, tier = R:GetRep(), R:GetRepTier()
    local cur, nxt = D.REP_TIERS[tier + 1], D.REP_TIERS[tier + 2]
    W.repBar:Set(nxt and (rep - cur.at) or 1, nxt and (nxt.at - cur.at) or 1,
        string.format("Westfall Brigade: %s  %s", cur.name, nxt and string.format("%d/%d", rep - cur.at, nxt.at - cur.at) or ""))
    local have = 0
    for _, a in ipairs(D.achievements) do if R:HasAchievement(a.id) then have = have + 1 end end
    W.achText:SetText(string.format("Achievements: |cffffd100%d / %d|r", have, #D.achievements))
    local lobby = R:GetLobby()
    local myKey = ns.Util.PlayerKey()
    local isHost = lobby and lobby.host == myKey
    W.heroic:SetEnabled(R:CanHeroic() and (not lobby or isHost) and true or false)
    W.heroic:SetChecked(lobby and lobby.heroic or (not lobby and R:GetHeroic()))
    local lines, inLobby = {}, false
    if lobby then
        lines[1] = string.format("|cffffd100Party|r (leader %s, %d/%d)%s:", Short(lobby.host), #lobby.players, D.MAX_PLAYERS,
            lobby.heroic and "  |cffff4040Heroic|r" or "")
        for _, key in ipairs(lobby.players) do
            lines[#lines + 1] = "   " .. HeroLine(lobby.heroes[key])
            if key == myKey then inLobby = true end
        end
    else
        lines[1] = "|cff888888No party yet. Gather one for your group, or delve alone.|r"
    end
    W.players:SetText(table.concat(lines, "\n"))
    W.host:SetEnabled(not lobby and IsInGroup())
    W.solo:SetEnabled(not lobby)
    W.join:SetEnabled(lobby ~= nil and not inLobby and #lobby.players < D.MAX_PLAYERS)
    W.start:SetEnabled(isHost and true or false)
    W.leave:SetEnabled(inLobby)
    local best = ns.Games:GetData("rpg").best
    W.best:SetText(best and ("Deepest run: " .. best .. " rooms") or "")
end

local function CreateLobby(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    local R = ns.RPG
    local title = ns.UI:CreateLabel(v, "Delve: The Deadmines", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -12)
    local blurb = ns.UI:CreateLabel(v, "The Defias Brotherhood has taken the mines under Moonbrook. Fight your way down "
        .. "as yourself, gather loot, learn talents, and bring Edwin VanCleef to justice.", "GameFontHighlightSmall")
    blurb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    blurb:SetPoint("RIGHT", -12, 0)

    local card = ns.UI:CreatePanel(v)
    card:SetPoint("TOPLEFT", 12, -64)
    card:SetPoint("RIGHT", -12, 0)
    card:SetHeight(150)
    W.model = NewModel(card)
    W.model:SetSize(110, 140)
    W.model:SetPoint("LEFT", 6, 0)
    local ht = ns.UI:CreateLabel(card, "You", "GameFontNormal")
    ht:SetPoint("TOPLEFT", 124, -10)
    W.hero = ns.UI:CreateLabel(card, "", "GameFontHighlight")
    W.hero:SetPoint("TOPLEFT", ht, "BOTTOMLEFT", 0, -4)
    W.hero:SetPoint("RIGHT", -10, 0)
    local repHost = CreateFrame("Frame", nil, card)
    repHost:SetPoint("BOTTOMLEFT", 124, 12)
    repHost:SetSize(260, 14)
    W.repBar = Bar(repHost, 14, 0.1, 0.7, 0.1)
    W.repBar.bg:SetPoint("LEFT")
    W.repBar.bg:SetWidth(260)
    W.achBtn = CreateFrame("Button", nil, card)
    W.achBtn:SetSize(170, 16)
    W.achBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    W.achText = W.achBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    W.achText:SetPoint("RIGHT")
    W.achBtn:SetScript("OnEnter", function(self)
        local lines = { "Delve achievements" }
        for _, a in ipairs(D.achievements) do
            lines[#lines + 1] = (R:HasAchievement(a.id) and "|cff33ff99" or "|cff888888") .. a.name .. "|r: " .. a.desc
        end
        ns.UI:SetTextTooltip(self, lines)
    end)
    W.achBtn:SetScript("OnLeave", function() ns.UI:HideTooltip() end)

    W.heroic = ns.UI:CreateCheckbox(v, "Heroic (Honored): +40% enemy health, +25% damage, double reputation",
        function() return R:GetHeroic() end, function(on) R:SetHeroic(on) end)
    W.heroic:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -6)

    W.players = ns.UI:CreateLabel(v, "", "GameFontHighlight")
    W.players:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 4, -36)
    W.players:SetPoint("RIGHT", -12, 0)

    W.solo = ns.UI:CreateButton(v, "Delve solo", 100, 24, function() R:PlaySolo() end)
    W.solo:SetPoint("BOTTOMLEFT", 12, 12)
    W.host = ns.UI:CreateButton(v, "Gather a party", 120, 24, function() R:Host() end)
    W.host:SetPoint("LEFT", W.solo, "RIGHT", 6, 0)
    W.join = ns.UI:CreateButton(v, "Join", 70, 24, function() R:Join() end)
    W.join:SetPoint("LEFT", W.host, "RIGHT", 6, 0)
    W.start = ns.UI:CreateButton(v, "Enter!", 70, 24, function() R:Start() end)
    W.start:SetPoint("LEFT", W.join, "RIGHT", 6, 0)
    W.leave = ns.UI:CreateButton(v, "Leave", 70, 24, function() R:LeaveLobby() end)
    W.leave:SetPoint("LEFT", W.start, "RIGHT", 6, 0)
    W.best = ns.UI:CreateLabel(v, "", "GameFontDisableSmall")
    W.best:SetPoint("BOTTOMRIGHT", -12, 18)
    return v
end

---------------------------------------------------------------------------
-- Battlefield: unit frames
---------------------------------------------------------------------------

local UNIT_W, UNIT_H = 120, 190

local function UnitFrame(parent, isEnemy, index)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(UNIT_W, UNIT_H)
    f.shadow = f:CreateTexture(nil, "BORDER")
    f.shadow:SetColorTexture(0, 0, 0, 0.35)
    f.shadow:SetSize(70, 8)
    f.shadow:SetPoint("BOTTOM", 0, 26)
    f.sel = f:CreateTexture(nil, "BORDER", nil, 1)       -- selected target: a gold bar under the feet
    f.sel:SetColorTexture(1, 0.82, 0.1, 0.9)
    f.sel:SetSize(80, 3)
    f.sel:SetPoint("BOTTOM", 0, 24)
    -- the model's drawing box is much bigger than the footprint (a model frame clips at its edges; it is
    -- transparent, so neighbours overlapping it is fine)
    f.model = NewModel(f, not isEnemy)
    f.model:SetPoint("TOPLEFT", -50, 10)
    f.model:SetPoint("BOTTOMRIGHT", 50, 8)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(44, 44)
    f.icon:SetPoint("CENTER", 0, 12)
    f.name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.name:SetPoint("BOTTOM", f, "TOP", 0, 14)
    f.name:SetWidth(120)
    f.hp = Bar(f, 12, 0.1, 0.8, 0.1)
    f.hp.bg:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 2)
    f.hp.bg:SetWidth(f:GetWidth())
    f.res = Bar(f, 6, 0.2, 0.4, 1)
    f.res.bg:SetPoint("BOTTOMLEFT", 0, 18)
    f.res.bg:SetWidth(f:GetWidth())
    f.cast = Bar(f, 12, 1, 0.7, 0)
    f.cast.bg:SetPoint("BOTTOMLEFT", 0, 4)
    f.cast.bg:SetWidth(f:GetWidth())
    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.status:SetPoint("TOPRIGHT", -2, -2)
    f.targetOf = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.targetOf:SetPoint("TOP", f, "BOTTOM", 0, 0)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:SetScript("OnClick", function()
        if isEnemy then selEnemy = index else selAlly = index end
    end)
    f:SetScript("OnEnter", function(self)
        local g = ns.RPG:GetGame()
        if not g then return end
        if isEnemy then
            local e = g.S.enemies[index]
            local def = e and D.enemies[e.kind]
            if not def then return end
            local lines = { def.name, string.format("%d / %d health", e.hp, e.max) }
            for _, ab in ipairs(def.abilities or {}) do
                lines[#lines + 1] = "|cffff8000" .. ab.name .. "|r" .. (ab.interruptible and " (interruptible)" or "")
            end
            ns.UI:SetTextTooltip(self, lines)
        else
            local h = g.S.party[index]
            if not h then return end
            local lines = { h.name .. "  level " .. h.level, string.format("%d / %d health", h.hp, h.max) }
            for _, id in ipairs(h.loot) do lines[#lines + 1] = "|cffa335ee" .. D.loot[id].name .. "|r" end
            ns.UI:SetTextTooltip(self, lines)
        end
    end)
    f:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    return f
end

local function LayoutUnits(S)
    local w, h = G.field:GetWidth(), G.field:GetHeight()
    local function place(frames, n, left)
        local cols = n > 3 and 2 or 1
        local perCol = math.ceil(n / cols)
        for i = 1, n do
            local col = math.floor((i - 1) / perCol)
            local row = (i - 1) % perCol
            local f = frames[i]
            f:ClearAllPoints()
            local step = math.min(UNIT_H + 60, (h - 40) / math.max(1, perCol))
            local x = left and (30 + col * 130 + (row % 2) * 20) or (w - UNIT_W - 30 - col * 130 - (row % 2) * 20)
            local y = -34 - row * step
            if perCol == 1 then y = -(h - UNIT_H) / 2 end
            f:SetPoint("TOPLEFT", G.field, "TOPLEFT", x, y)
        end
    end
    for i = 1, D.MAX_PLAYERS do
        if not heroFrames[i] then heroFrames[i] = UnitFrame(G.field, false, i) end
        heroFrames[i]:SetShown(i <= S.players)
    end
    place(heroFrames, S.players, true)
    local n = #S.enemies
    for i = 1, math.max(n, #enemyFrames) do
        if not enemyFrames[i] and i <= n then enemyFrames[i] = UnitFrame(G.field, true, i) end
        if enemyFrames[i] then enemyFrames[i]:SetShown(i <= n) end
    end
    if n > 0 then place(enemyFrames, n, false) end
    G.layoutFor = S.players .. ":" .. n .. ":" .. w .. ":" .. h
end

local function DrawHero(game, p)
    local S = game.S
    local h = S.party[p]
    local f = heroFrames[p]
    local unit = UnitFor(game.players[p])
    local visible = unit == "player" or (unit and UnitIsVisible and UnitIsVisible(unit))
    if visible then
        ApplyUnit(f.model, unit)
        Facing(f.model, 1)
        local anim = ANIM.stand
        if h.dead then anim = ANIM.death
        elseif S.tick < h.stunUntil then anim = ANIM.stun
        elseif h.cast then anim = ANIM.castDirected
        elseif GetTime() - (actAt["h" .. p] or 0) < HOLD then anim = ROLE_ANIM[h.role] or ANIM.oneHand end
        SetAnim(f.model, anim)
        f.model:Show()
        f.icon:Hide()
    else
        f.model:Hide()
        f.icon:Show()
        ClassIcon(f.icon, h.class)
        f.icon:SetDesaturated(h.dead)
    end
    f.name:SetText(string.format("%s%s|r |cff888888%d|r", ClassColor(h.class), h.name, h.level))
    f.hp:Set(h.hp, h.max, h.dead and "Dead" or (h.absorb > 0 and string.format("%d (+%d)", h.hp, h.absorb) or tostring(h.hp)))
    local rc = D.resources[h.resType].color
    f.res.fill:SetColorTexture(rc[1], rc[2], rc[3], 0.95)
    f.res:Set(h.res, h.resMax)
    if h.cast then
        f.cast:Show(true)
        local name = D.AbilityLabel(h.class, D.kits[h.role][h.cast.a].id)
        f.cast:Set(S.tick - h.cast.start, h.cast.stop - h.cast.start, name)
    else
        f.cast:Show(false)
    end
    local st = {}
    if h.absorb > 0 then st[#st + 1] = "|TInterface\\Icons\\Spell_Holy_PowerWordShield:14|t" end
    if #h.hots > 0 then st[#st + 1] = "|TInterface\\Icons\\Spell_Holy_Renew:14|t" end
    if S.tick < h.drUntil then st[#st + 1] = "|TInterface\\Icons\\Ability_Warrior_ShieldWall:14|t" end
    if S.tick < h.buffUntil then st[#st + 1] = "|TInterface\\Icons\\Ability_Warrior_PunishingBlow:14|t" end
    if S.tick < h.stunUntil then st[#st + 1] = "|TInterface\\Icons\\Spell_Frost_Stun:14|t" end
    f.status:SetText(table.concat(st))
    f.sel:SetShown(selAlly == p)
    f.targetOf:SetText(p == game.me and "|cffffd100(you)|r" or "")
end

local function DrawEnemy(game, i)
    local S = game.S
    local e = S.enemies[i]
    local f = enemyFrames[i]
    local def = D.enemies[e.kind]
    local ok = not e.dead and ApplyCreature(f.model, def.id, def.display)
    if ok then
        Facing(f.model, -1)
        local anim = ANIM.readyUnarmed
        if S.tick < e.ccUntil or S.tick < e.stunUntil then anim = ANIM.stun
        elseif e.cast then anim = ANIM.castOmni
        elseif GetTime() - (actAt["e" .. i] or 0) < HOLD then anim = ANIM.oneHand end
        SetAnim(f.model, anim)
        f.model:Show()
        f.icon:Hide()
    else
        f.model:Hide()
        f.icon:Show()
        f.icon:SetTexture(def.icon)
        f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        f.icon:SetDesaturated(e.dead)
    end
    f:SetAlpha(e.dead and 0.35 or 1)
    f.name:SetText((def.boss and "|cffff8000" or "|cffff5050") .. def.name .. (e.enraged and " (enraged)" or "") .. "|r")
    f.hp.fill:SetColorTexture(0.8, 0.15, 0.1, 0.95)
    f.hp:Set(e.hp, e.max, e.dead and "Dead" or tostring(e.hp))
    f.res:Show(false)
    if e.cast and not e.dead then
        f.cast:Show(true)
        local ab = def.abilities[e.cast.ab]
        f.cast.fill:SetColorTexture(e.cast.interruptible and 1 or 0.6, e.cast.interruptible and 0.7 or 0.6,
            e.cast.interruptible and 0 or 0.6, 0.95)
        f.cast:Set(S.tick - e.cast.start, e.cast.stop - e.cast.start, ab.name .. (e.cast.interruptible and " !" or ""))
    else
        f.cast:Show(false)
    end
    local st = ""
    if S.tick < e.ccUntil then st = "|TInterface\\Icons\\Spell_Nature_Polymorph:14|t" end
    if e.tauntP > 0 and S.tick < e.tauntUntil then st = st .. "|TInterface\\Icons\\Spell_Nature_Reincarnation:14|t" end
    f.status:SetText(st)
    f.sel:SetShown(selEnemy == i)
    -- who is it hitting?
    local target
    if not e.dead then
        if e.tauntP > 0 and S.tick < e.tauntUntil then target = e.tauntP else
            local best = -1
            for p = 1, S.players do
                if not S.party[p].dead and e.threat[p] > best then target, best = p, e.threat[p] end
            end
        end
    end
    f.targetOf:SetText(target and ("-> " .. (target == game.me and "|cffff4040YOU|r" or S.party[target].name)) or "")
end

---------------------------------------------------------------------------
-- Ability bar, overlays
---------------------------------------------------------------------------

local function DefaultEnemy(S)
    if selEnemy and S.enemies[selEnemy] and not S.enemies[selEnemy].dead then return selEnemy end
    for i, e in ipairs(S.enemies) do if not e.dead then selEnemy = i return i end end
    return nil
end

local function DefaultAlly(game)
    local S = game.S
    if selAlly and S.party[selAlly] and not S.party[selAlly].dead then return selAlly end
    return game.me
end

local function UseAbility(a)
    local game = ns.RPG:GetGame()
    if not game or game.ended then return end
    local h = game.S.party[game.me]
    local ab = D.kits[h.role][a]
    local target = ab.tgt == "enemy" and DefaultEnemy(game.S) or (ab.tgt == "ally" and DefaultAlly(game) or game.me)
    if target then ns.RPG:Cast(a, target) end
end

local function DrawAbilities(game)
    local S = game.S
    local h = S.party[game.me]
    for a = 1, D.ABILITIES do
        local b = abilityButtons[a]
        local ab = D.kits[h.role][a]
        local name, icon = D.AbilityLabel(h.class, ab.id)
        b.icon:SetTexture(icon)
        b.name = name
        b.ab = ab
        local cd = math.max(h.cds[a] - S.tick, 0)
        local gcd = math.max(h.gcd - S.tick, 0)
        b.cd:SetText(cd > 0 and (ab.kind == "potion" and "used" or tostring(math.ceil(cd / D.TICK_RATE))) or "")
        local target = ab.tgt == "enemy" and DefaultEnemy(S) or (ab.tgt == "ally" and DefaultAlly(game) or game.me)
        local usable = Sim.CanCast(S, game.me, a, target)
        b.icon:SetDesaturated(not usable and (cd > 0 or h.res < (ab.cost or 0) or h.dead))
        b.dim:SetShown(not usable)
        b.gcd:SetShown(gcd > 0 and cd == 0)
        b.cost:SetText((ab.cost or 0) > 0 and tostring(ab.cost) or "")
    end
end

local function ChoiceCard(parent, onClick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(160, 118)
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    b:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
    b:SetBackdropBorderColor(1, 0.8, 0.2, 0.8)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(40, 40)
    b.icon:SetPoint("TOP", 0, -8)
    b.title = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.title:SetPoint("TOP", b.icon, "BOTTOM", 0, -4)
    b.title:SetWidth(150)
    b.desc = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.desc:SetPoint("TOP", b.title, "BOTTOM", 0, -4)
    b.desc:SetWidth(150)
    b:SetScript("OnClick", function(self) onClick(self.index) end)
    b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(1, 1, 0.6, 1) end)
    b:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(1, 0.8, 0.2, 0.8) end)
    return b
end

local function ModsText(m)
    local parts = {}
    local names = { dmg = "% damage", heal = "% healing", hp = "% health", haste = "% haste", crit = "% crit",
                    regen = " mana regen", leech = "% leech", thorns = " thorns", dr = "% less damage taken" }
    for _, k in ipairs({ "dmg", "heal", "hp", "haste", "crit", "regen", "leech", "thorns", "dr" }) do
        if m[k] then parts[#parts + 1] = "+" .. m[k] .. names[k] end
    end
    return table.concat(parts, "\n")
end

local function ShowChoices(title, cards)
    G.choiceTitle:SetText(title)
    for i = 1, 3 do
        local b = G.cards[i]
        local c = cards[i]
        b:SetShown(c ~= nil)
        if c then
            b.index = i
            b.icon:SetTexture(c.icon)
            b.title:SetText(c.title)
            b.desc:SetText(c.desc)
            b:ClearAllPoints()
            b:SetPoint("TOP", G.choices, "TOP", (i - (#cards + 1) / 2) * 170, -30)
        end
    end
    G.choices:Show()
end

local function DrawOverlay(game)
    local S = game.S
    local h = S.party[game.me]
    G.choiceMode = nil
    if h.talentOffer and not S.over then
        local cards = {}
        for i, idx in ipairs(h.talentOffer) do
            local t = D.talents[h.role][idx]
            cards[i] = { icon = "Interface\\Icons\\" .. t[2], title = t[1],
                         desc = ModsText(t[3]) .. string.format("\n|cff888888Rank %d/%d|r", h.talents[idx] + 1, D.TALENT_MAX) }
        end
        G.choiceMode = "t"
        ShowChoices(string.format("|cffffd100Level %d!|r Choose a talent", h.level), cards)
    elseif S.phase == "loot" and not h.lootTaken and h.lootOffer then
        local cards = {}
        for i, id in ipairs(h.lootOffer) do
            local l = D.loot[id]
            cards[i] = { icon = l.icon, title = "|cffa335ee" .. l.name .. "|r", desc = ModsText(l) }
        end
        G.choiceMode = "l"
        ShowChoices(string.format("Loot! Take one  |cff888888(%ds)|r", math.ceil((S.phaseEnd - S.tick) / D.TICK_RATE)), cards)
    elseif S.phase == "path" and S.pathOffer then
        local cards = {}
        for i, kind in ipairs(S.pathOffer) do
            local r = D.rooms[kind]
            local votes = 0
            for p = 1, S.players do if S.party[p].vote == i then votes = votes + 1 end end
            cards[i] = { icon = "Interface\\Icons\\" .. r.icon, title = r.name,
                         desc = r.desc .. string.format("\n\n%d vote%s%s", votes, votes == 1 and "" or "s",
                             h.vote == i and "  |cff33ff99(yours)|r" or "") }
        end
        G.choiceMode = "v"
        ShowChoices(string.format("Where next? Room %d  |cff888888(%ds)|r", S.depth + 1,
            math.max(0, math.ceil((S.phaseEnd - S.tick) / D.TICK_RATE))), cards)
    elseif S.phase == "loot" then
        G.choices:Hide()
        G.waiting:SetText("Waiting for the party to pick loot...")
    else
        G.choices:Hide()
    end
    G.waiting:SetShown(S.phase == "loot" and h.lootTaken and not h.talentOffer)
    G.result:SetShown(game.ended and true or false)
    if game.ended then
        G.result:SetText(S.won and "|cff33ff99VICTORY|r\nThe Deadmines are cleared!"
            or string.format("|cffff4040DEFEAT|r\nYou reached room %d.", S.depth))
    end
end

local function DrawGame()
    local game = ns.RPG:GetGame()
    if not game then return end
    local S = game.S
    if G.layoutFor ~= (S.players .. ":" .. #S.enemies .. ":" .. G.field:GetWidth() .. ":" .. G.field:GetHeight()) then
        LayoutUnits(S)
    end
    local fx = S.fx
    if #fx > 0 then
        S.fx = {}
        for _, e in ipairs(fx) do HandleFx(game, e) end
    end
    for p = 1, S.players do DrawHero(game, p) end
    for i = 1, #S.enemies do DrawEnemy(game, i) end
    DrawAbilities(game)
    DrawOverlay(game)
    local phaseText = S.phase == "combat" and "|cffff8000In combat|r" or (S.phase == "path" and "Choosing a path"
        or (S.phase == "loot" and "Looting" or ""))
    G.header:SetText(string.format("|cffffd100%s|r%s   Room %d / %d   %s%s", D.dungeons[S.dungeon].name,
        S.heroic and " |cffff4040(Heroic)|r" or "", math.min(S.depth + (S.phase == "combat" and 1 or 0), D.dungeons[S.dungeon].depth + 1),
        D.dungeons[S.dungeon].depth + 1, phaseText, game.isPaused and not game.ended and "  |cff888888(paused)|r" or ""))
    AnimateTexts()
end

local function CreateGame(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    G.header = ns.UI:CreateLabel(v, "", "GameFontNormal")
    G.header:SetPoint("TOPLEFT", 10, -12)
    local quit = ns.UI:CreateButton(v, "Leave run", 90, 22, function() ns.RPG:Quit() end)
    quit:SetPoint("TOPRIGHT", -8, -6)

    G.field = CreateFrame("Frame", nil, v)
    G.field:SetPoint("TOPLEFT", 6, -36)
    G.field:SetPoint("BOTTOMRIGHT", -6, 62)
    local bg = G.field:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.12, 0.1, 0.08, 1)
    local floor = G.field:CreateTexture(nil, "BACKGROUND", nil, 1)
    floor:SetPoint("BOTTOMLEFT")
    floor:SetPoint("BOTTOMRIGHT")
    floor:SetHeight(90)
    floor:SetColorTexture(0.2, 0.16, 0.11, 1)
    local beam = G.field:CreateTexture(nil, "BACKGROUND", nil, 2)
    beam:SetPoint("TOPLEFT")
    beam:SetPoint("TOPRIGHT")
    beam:SetHeight(18)
    beam:SetColorTexture(0.28, 0.2, 0.12, 1)
    G.fx = CreateFrame("Frame", nil, G.field)
    G.fx:SetAllPoints()
    G.fx:SetFrameLevel(G.field:GetFrameLevel() + 30)
    G.banner = G.fx:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    G.banner:SetPoint("TOP", 0, -24)
    G.banner:Hide()

    -- ability bar
    for a = 1, D.ABILITIES do
        local b = CreateFrame("Button", nil, v)
        b:SetSize(40, 40)
        b:SetPoint("BOTTOMLEFT", 12 + (a - 1) * 48 + (a == D.ABILITIES and 16 or 0), 14)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        b.dim = b:CreateTexture(nil, "OVERLAY")
        b.dim:SetColorTexture(0, 0, 0, 0.45)
        b.dim:SetAllPoints()
        b.gcd = b:CreateTexture(nil, "OVERLAY")
        b.gcd:SetColorTexture(0, 0, 0, 0.3)
        b.gcd:SetAllPoints()
        b.cd = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
        b.cd:SetPoint("CENTER")
        b.key = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        b.key:SetPoint("TOPLEFT", 2, -2)
        b.key:SetText(tostring(a))
        b.cost = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        b.cost:SetPoint("BOTTOMRIGHT", -2, 2)
        b:SetScript("OnClick", function() UseAbility(a) end)
        b:SetScript("OnEnter", function(self)
            local ab = self.ab
            if not ab then return end
            local lines = { self.name }
            local what = { dmg = "Damage", aoe = "Damage all enemies", heal = "Heal", hot = "Heal over time",
                           shield = "Absorb shield", taunt = "Taunt: forces the enemy to attack you",
                           interrupt = "Interrupt an enemy cast", cc = "Crowd control (bosses are slowed instead)",
                           potion = "Restores " .. (ab.amt or 0) .. "% of your health. One per fight.",
                           buff = "+" .. (ab.amt or 0) .. "% damage", selfdr = "-" .. (ab.amt or 0) .. "% damage taken" }
            lines[#lines + 1] = what[ab.kind] .. ((ab.amt and ab.kind ~= "buff" and ab.kind ~= "selfdr" and ab.kind ~= "potion") and (" " .. ab.amt) or "")
            if (ab.cast or 0) > 0 then lines[#lines + 1] = string.format("%.1fs cast", ab.cast / 10) end
            if (ab.cd or 0) > 0 then lines[#lines + 1] = string.format("%ds cooldown", ab.cd / 10) end
            lines[#lines + 1] = ab.tgt == "ally" and "|cff888888Target: click a party member|r"
                or (ab.tgt == "enemy" and "|cff888888Target: click an enemy|r" or "")
            ns.UI:SetTextTooltip(self, lines)
        end)
        b:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
        abilityButtons[a] = b
    end
    local hint = ns.UI:CreateLabel(v, "Keys 1-5 cast (5 = potion). Click enemies / party members to target.", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMRIGHT", -10, 20)

    -- choices overlay
    G.choices = CreateFrame("Frame", nil, v, "BackdropTemplate")
    G.choices:SetPoint("TOPLEFT", G.field, "TOPLEFT", 20, -40)
    G.choices:SetPoint("BOTTOMRIGHT", G.field, "BOTTOMRIGHT", -20, 40)
    G.choices:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    G.choices:SetBackdropColor(0, 0, 0, 0.75)
    G.choices:SetFrameLevel(G.field:GetFrameLevel() + 40)
    G.choiceTitle = G.choices:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    G.choiceTitle:SetPoint("TOP", 0, -8)
    G.cards = {}
    for i = 1, 3 do
        G.cards[i] = ChoiceCard(G.choices, function(idx)
            if G.choiceMode then ns.RPG:Act(G.choiceMode, idx) end
        end)
    end
    G.choices:Hide()
    G.waiting = ns.UI:CreateLabel(G.fx, "", "GameFontNormalLarge")
    G.waiting:SetPoint("CENTER")
    G.result = ns.UI:CreateLabel(G.fx, "", "GameFontNormalHuge")
    G.result:SetJustifyH("CENTER")
    G.result:SetPoint("CENTER", 0, 20)
    G.result:Hide()

    -- keys 1-4 while the window is focused (other keys pass through)
    v:EnableKeyboard(true)
    v:SetScript("OnKeyDown", function(self, key)
        local a = tonumber(key)
        local handled = a and a >= 1 and a <= D.ABILITIES and ns.RPG:IsPlaying()
        if not InCombatLockdown() and self.SetPropagateKeyboardInput then
            pcall(self.SetPropagateKeyboardInput, self, not handled)
        end
        if handled then UseAbility(a) end
    end)

    v:SetScript("OnUpdate", DrawGame)
    return v
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

function RPGUI:Refresh()
    if not root then return end
    local game = ns.RPG:GetGame()
    gameView:SetShown(game ~= nil)
    lobbyView:SetShown(game == nil)
    if game then
        G.layoutFor = nil
    else
        selEnemy, selAlly = nil, nil
        RefreshLobby()
    end
end

function RPGUI:CreatePanel(parent)
    root = CreateFrame("Frame", nil, parent)
    lobbyView = CreateLobby(root)
    gameView = CreateGame(root)
    root:SetScript("OnShow", function()
        local g = ns.RPG:GetGame()
        if g then g.S.fx = {} end
        RPGUI:Refresh()
    end)
    root.OnGameShown = function() RPGUI:Refresh() end
    RPGUI:Refresh()
    return root
end

-- /cdl rpgmodels [enemyId displayID | flip | reset]
local function ModelsSlash(rest)
    local data = ns.Games:GetData("rpg")
    data.displays = type(data.displays) == "table" and data.displays or {}
    local a, b = (rest or ""):match("^%s*(%S*)%s*(%S*)")
    if a == "flip" then
        data.flipFacing = not data.flipFacing
        ns:Print("Delve models now face the %s way.", data.flipFacing and "other" or "default")
    elseif a == "reset" then
        wipe(data.displays)
        wipe(modelState)
        ns:Print("Delve model overrides cleared.")
    elseif a ~= "" and tonumber(b) then
        data.displays[a] = tonumber(b)
        modelState[a] = nil
        ns:Print("Delve: '%s' now uses display %d.", a, tonumber(b))
    else
        ns:Print("Delve enemy models (override: /cdl rpgmodels <enemy> <displayID>, 'flip', 'reset'):")
        for _, e in ipairs(D.enemies) do
            local st = modelState[e.id]
            ns:Print("  %s: %s%s", e.id, table.concat(e.display or {}, ", "),
                data.displays[e.id] and ("  |cff33ff99override " .. data.displays[e.id] .. "|r")
                or (st and st.ok and ("  (using " .. tostring((e.display or {})[st.idx]) .. ")") or ""))
        end
    end
end

function RPGUI:OnInit()
    ns:On("RPG_UPDATED", function()
        if root and root:IsVisible() then RPGUI:Refresh() end
    end)
    ns:RegisterSlash("rpgmodels", ModelsSlash, "rpgmodels [enemy id|flip|reset] - Delve enemy models")
end
