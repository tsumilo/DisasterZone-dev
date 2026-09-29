-- CDLoot Games/Murloc/UI.lua
-- ns.MurlocUI: the lobby (map, hero card with your own model, reputation, achievements, players) and the game
-- board: terrain lanes, defenders (rank pips, hp, nets), murlocs as 3D models (icon fallback), heroes as the
-- players' own character models, projectiles / floating combat text / banners driven by the sim's fx events,
-- and panels for tower upgrade / sell, hero talents and the party boon vote.
local addonName, ns = ...

local MurlocUI = ns:NewModule("MurlocUI")
local D = ns.MurlocData
local Sim = ns.MurlocSim

local LABEL_W = 92
local MAX_MODELS = 40             -- 3D murlocs on screen at once (the rest use icons)
-- AnimationData IDs
local ANIM = { stand = 0, walk = 4, stun = 14, unarmed = 16, oneHand = 17, readyUnarmed = 25, ready1H = 26,
               bow = 46, rifle = 49, castDirected = 53, castOmni = 54 }
local ATTACK_HOLD = 0.7            -- seconds an attack animation plays after a hit
local attackAt, biteAt = {}, {}    -- ["lane:col"] / [mob id] = GetTime() of the last attack
local ATTACK_ANIM = {
    footman = ANIM.oneHand, rifleman = ANIM.rifle, frostmage = ANIM.castDirected, acolyte = ANIM.castOmni,
    tank = ANIM.oneHand, melee = ANIM.oneHand, ranged = ANIM.bow, caster = ANIM.castDirected, healer = ANIM.castOmni,
}

local root, lobbyView, gameView
local lobbyW = {}                 -- lobby widgets
local header, board, overlay, buildBar, lustBtn, quitBtn, resultText, banner, towerPanel, talentPanel, boonPanel, xpText
local lanes = {}
local towerPool, mobPool, modelPool, projPool, textPool = {}, {}, {}, {}, {}
local projs, texts = {}, {}
local selectedKind, selectedTower = 1, nil
local geo = { laneH = 60, areaW = 400, colW = 40 }

local ROLE_LABEL = { tank = "Tank", healer = "Healer", melee = "Melee", caster = "Caster", ranged = "Ranged" }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function ClassColor(class)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
    return "|cffffffff"
end

local function Short(key) return (type(key) == "string" and key:match("^([^%-]+)")) or tostring(key) end

local function ClassIcon(tex, class)
    tex:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
    local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if c then tex:SetTexCoord(unpack(c)) else tex:SetTexCoord(0, 1, 0, 1) end
end

local function Sound(id)
    if not PlaySoundFile then return end
    pcall(PlaySoundFile, id, "SFX")
end

local soundAt = {}
local function Throttled(key, gap)
    local now = GetTime()
    if soundAt[key] and now - soundAt[key] < gap then return false end
    soundAt[key] = now
    return true
end

-- Unit token of a group member by name key (for their character model), or nil.
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

local function HeroLine(h)
    if not h then return "|cff888888(joining...)|r" end
    local st = D.HeroStats({ role = h.role, class = h.class, power = tonumber(h.power) or 100 })
    local what = st.heal and ("heals " .. st.heal) or ("hits " .. st.dmg)
    return string.format("%s%s|r  %s%s  |cffffd100%d%%|r  (%d hp, %s)", ClassColor(h.class), h.name or "?",
        h.spec and h.spec ~= "" and (h.spec .. " ") or "", ROLE_LABEL[h.role] or h.role, h.power or 100, st.hp, what)
end

---------------------------------------------------------------------------
-- Lobby
---------------------------------------------------------------------------

local function RefreshLobby()
    local M = ns.Murloc
    local me = M:GetMyHero()
    local W = lobbyW
    W.hero:SetText(HeroLine(me) .. string.format("\n|cff888888Average item level %d: better gear, stronger hero "
        .. "(60-200%%). Levels up in the game and learns talents.|r", me.ilvl or 0))
    pcall(W.model.SetUnit, W.model, "player")

    -- reputation
    local rep, tier = M:GetRep(), M:GetRepTier()
    local cur, nxt = D.REP_TIERS[tier + 1], D.REP_TIERS[tier + 2]
    local pct = nxt and (rep - cur.at) / (nxt.at - cur.at) or 1
    W.repBar:SetWidth(math.max(1, 240 * pct))
    W.repText:SetText(string.format("Southshore Militia: |cff33ff99%s|r  %s", cur.name,
        nxt and string.format("%d / %d", rep - cur.at, nxt.at - cur.at) or "(max)"))

    -- achievements
    local have = 0
    for _, a in ipairs(D.achievements) do if M:HasAchievement(a.id) then have = have + 1 end end
    W.ach:SetText(string.format("Achievements: |cffffd100%d / %d|r", have, #D.achievements))

    -- maps
    local lobby = M:GetLobby()
    local myKey = ns.Util.PlayerKey()
    local isHost = lobby and lobby.host == myKey
    local current = lobby and lobby.map or M:GetMap()
    for i, b in ipairs(W.maps) do
        local unlocked = M:MapUnlocked(i)
        b:SetEnabled(unlocked and (not lobby or isHost) and true or false)
        b.sel:SetShown(i == current)
        b.lock:SetShown(not unlocked)
    end
    local m = D.maps[current] or D.maps[1]
    W.blurb:SetText(m.blurb)

    -- players
    local lines = {}
    local inLobby = false
    if lobby then
        lines[1] = string.format("|cffffd100Lobby|r (host %s, %d/%d):", Short(lobby.host), #lobby.players, D.MAX_PLAYERS)
        for i, key in ipairs(lobby.players) do
            lines[#lines + 1] = string.format("  Lane %d:  %s", i, HeroLine(lobby.heroes[key]))
            if key == myKey then inLobby = true end
        end
    else
        lines[1] = "|cff888888No lobby open. Host one for your group, or play solo.|r"
    end
    W.players:SetText(table.concat(lines, "\n"))
    W.host:SetEnabled(not lobby and IsInGroup())
    W.solo:SetEnabled(not lobby)
    W.join:SetEnabled(lobby ~= nil and not inLobby and #lobby.players < D.MAX_PLAYERS)
    W.start:SetEnabled(isHost and true or false)
    W.leave:SetEnabled(inLobby)
    local best = ns.Games:GetData("murloc").best
    W.best:SetText(best and ("Personal best: wave " .. best) or "")
end

local function CreateLobby(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    local W = lobbyW
    local M = ns.Murloc

    local title = ns.UI:CreateLabel(v, "Mrglglgl! Murloc Defense", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -12)
    W.blurb = ns.UI:CreateLabel(v, "", "GameFontHighlightSmall")
    W.blurb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)

    -- map picker
    W.maps = {}
    for i, m in ipairs(D.maps) do
        local b = ns.UI:CreateButton(v, m.name, 150, 22, function() M:SetMap(i) end)
        b:SetPoint("TOPLEFT", 12 + (i - 1) * 156, -52)
        b.sel = b:CreateTexture(nil, "OVERLAY")
        b.sel:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        b.sel:SetBlendMode("ADD")
        b.sel:SetAllPoints()
        b.lock = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        b.lock:SetPoint("TOP", b, "BOTTOM", 0, -1)
        b.lock:SetText("(" .. D.REP_TIERS[m.rep + 1].name .. ")")
        W.maps[i] = b
    end

    -- hero card with my own character model
    local card = ns.UI:CreatePanel(v)
    card:SetPoint("TOPLEFT", 12, -92)
    card:SetPoint("RIGHT", -12, 0)
    card:SetHeight(120)
    W.model = CreateFrame("PlayerModel", nil, card)
    W.model:SetSize(90, 112)
    W.model:SetPoint("LEFT", 4, 0)
    local heroTitle = ns.UI:CreateLabel(card, "Your hero", "GameFontNormal")
    heroTitle:SetPoint("TOPLEFT", 100, -8)
    W.hero = ns.UI:CreateLabel(card, "", "GameFontHighlight")
    W.hero:SetPoint("TOPLEFT", heroTitle, "BOTTOMLEFT", 0, -4)
    W.hero:SetPoint("RIGHT", -8, 0)
    -- reputation bar
    local repBg = card:CreateTexture(nil, "ARTWORK")
    repBg:SetColorTexture(0, 0, 0, 0.6)
    repBg:SetSize(240, 12)
    repBg:SetPoint("BOTTOMLEFT", 100, 10)
    W.repBar = card:CreateTexture(nil, "OVERLAY")
    W.repBar:SetColorTexture(0.1, 0.7, 0.1, 0.9)
    W.repBar:SetHeight(12)
    W.repBar:SetPoint("LEFT", repBg, "LEFT")
    W.repText = ns.UI:CreateLabel(card, "", "GameFontHighlightSmall")
    W.repText:SetPoint("BOTTOMLEFT", repBg, "TOPLEFT", 0, 2)
    W.ach = CreateFrame("Button", nil, card)
    W.ach:SetSize(160, 16)
    W.ach:SetPoint("BOTTOMRIGHT", -8, 8)
    local achText = W.ach:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    achText:SetPoint("RIGHT")
    W.ach.SetText = function(_, t) achText:SetText(t) end
    W.ach:SetScript("OnEnter", function(self)
        local lines = { "Murloc Defense achievements" }
        for _, a in ipairs(D.achievements) do
            local done = M:HasAchievement(a.id)
            lines[#lines + 1] = (done and "|cff33ff99" or "|cff888888") .. a.name .. "|r: " .. a.desc
        end
        ns.UI:SetTextTooltip(self, lines)
    end)
    W.ach:SetScript("OnLeave", function() ns.UI:HideTooltip() end)

    W.players = ns.UI:CreateLabel(v, "", "GameFontHighlight")
    W.players:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -12)
    W.players:SetPoint("RIGHT", -12, 0)

    W.solo = ns.UI:CreateButton(v, "Play solo", 100, 24, function() M:PlaySolo() end)
    W.solo:SetPoint("BOTTOMLEFT", 12, 12)
    W.host = ns.UI:CreateButton(v, "Host for group", 120, 24, function() M:Host() end)
    W.host:SetPoint("LEFT", W.solo, "RIGHT", 6, 0)
    W.join = ns.UI:CreateButton(v, "Join", 70, 24, function() M:Join() end)
    W.join:SetPoint("LEFT", W.host, "RIGHT", 6, 0)
    W.start = ns.UI:CreateButton(v, "Start!", 70, 24, function() M:Start() end)
    W.start:SetPoint("LEFT", W.join, "RIGHT", 6, 0)
    W.leave = ns.UI:CreateButton(v, "Leave", 70, 24, function() M:LeaveLobby() end)
    W.leave:SetPoint("LEFT", W.start, "RIGHT", 6, 0)
    W.best = ns.UI:CreateLabel(v, "", "GameFontDisableSmall")
    W.best:SetPoint("BOTTOMRIGHT", -12, 18)
    return v
end

---------------------------------------------------------------------------
-- Board geometry
---------------------------------------------------------------------------

local function LaneY(lane) return -((lane - 1) * geo.laneH + geo.laneH / 2) end
local function SimX(x) return LABEL_W + x / D.LANE * geo.areaW end

---------------------------------------------------------------------------
-- Effects: projectiles, floating text, banners
---------------------------------------------------------------------------

local PROJ = {
    bullet   = { tex = "Interface\\Buttons\\WHITE8X8", w = 10, h = 2, color = { 1, 0.9, 0.4 }, dur = 0.12 },
    frost    = { tex = "Interface\\Icons\\Spell_Frost_FrostBolt02", w = 14, h = 14, dur = 0.3 },
    holy     = { tex = "Interface\\Icons\\Spell_Holy_HolyBolt", w = 12, h = 12, dur = 0.25 },
    melee    = { tex = "Interface\\Cooldown\\star4", w = 26, h = 26, color = { 1, 1, 1 }, dur = 0.15, impact = true },
    boom     = { tex = "Interface\\Cooldown\\star4", w = 90, h = 90, color = { 1, 0.5, 0.1 }, dur = 0.4, impact = true },
    ["hero:tank"]   = { tex = "Interface\\Cooldown\\star4", w = 30, h = 30, color = { 1, 0.8, 0.5 }, dur = 0.15, impact = true },
    ["hero:melee"]  = { tex = "Interface\\Cooldown\\star4", w = 30, h = 30, color = { 1, 0.3, 0.3 }, dur = 0.15, impact = true },
    ["hero:caster"] = { tex = "Interface\\Icons\\Spell_Fire_FireBolt02", w = 16, h = 16, dur = 0.3 },
    ["hero:ranged"] = { tex = "Interface\\Buttons\\WHITE8X8", w = 14, h = 2, color = { 0.8, 1, 0.5 }, dur = 0.12 },
    ["hero:healer"] = { tex = "Interface\\Icons\\Spell_Holy_HolyBolt", w = 14, h = 14, dur = 0.25 },
}

local function Proj(kind, lane1, x1, lane2, x2)
    local def = PROJ[kind]
    if not def then return end
    local p = table.remove(projPool) or overlay:CreateTexture(nil, "OVERLAY")
    p:SetTexture(def.tex)
    if def.color then p:SetVertexColor(def.color[1], def.color[2], def.color[3], 1) else p:SetVertexColor(1, 1, 1, 1) end
    p:SetBlendMode(def.impact and "ADD" or "BLEND")
    p:SetSize(def.w, def.h)
    p:Show()
    projs[#projs + 1] = { tex = p, x1 = SimX(x1), y1 = LaneY(lane1), x2 = SimX(x2), y2 = LaneY(lane2),
                          t0 = GetTime(), dur = def.dur, impact = def.impact, w = def.w }
end

local function Float(text, lane, x, r, g, b, big)
    local fs = table.remove(textPool) or overlay:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(big and "GameFontNormalLarge" or "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetTextColor(r, g, b, 1)
    fs:Show()
    texts[#texts + 1] = { fs = fs, x = SimX(x) + math.random(-6, 6), y = LaneY(lane) + 10, t0 = GetTime(),
                          dur = big and 1.4 or 0.9 }
end

local bannerUntil = 0
local function Banner(text, secs)
    banner:SetText(text)
    banner:SetAlpha(1)
    banner:Show()
    bannerUntil = GetTime() + (secs or 2.5)
end

local function AnimateFx()
    local now = GetTime()
    for i = #projs, 1, -1 do
        local p = projs[i]
        local f = (now - p.t0) / p.dur
        if f >= 1 then
            p.tex:Hide()
            projPool[#projPool + 1] = p.tex
            table.remove(projs, i)
        else
            p.tex:ClearAllPoints()
            if p.impact then
                local s = p.w * (0.6 + f * 0.8)
                p.tex:SetSize(s, s)
                p.tex:SetAlpha(1 - f)
                p.tex:SetPoint("CENTER", overlay, "TOPLEFT", p.x2, p.y2)
            else
                p.tex:SetPoint("CENTER", overlay, "TOPLEFT", p.x1 + (p.x2 - p.x1) * f, p.y1 + (p.y2 - p.y1) * f)
            end
        end
    end
    for i = #texts, 1, -1 do
        local t = texts[i]
        local f = (now - t.t0) / t.dur
        if f >= 1 then
            t.fs:Hide()
            textPool[#textPool + 1] = t.fs
            table.remove(texts, i)
        else
            t.fs:ClearAllPoints()
            t.fs:SetPoint("CENTER", overlay, "TOPLEFT", t.x, t.y + f * 22)
            t.fs:SetAlpha(f < 0.7 and 1 or (1 - (f - 0.7) / 0.3))
        end
    end
    if banner:IsShown() then
        local left = bannerUntil - now
        if left <= 0 then banner:Hide() elseif left < 0.5 then banner:SetAlpha(left / 0.5) end
    end
end

local function HandleFx(game, e)
    local me = game.me
    local k = e.k
    if k == "shot" then
        attackAt[e.lane .. ":" .. (math.floor(e.x1 / D.COL) + 1)] = GetTime()
        Proj(e.proj, e.lane, e.x1, e.lane, e.x2)
        if e.crit then
            Float("*" .. e.dmg .. "*", e.lane, e.x2, 1, 0.85, 0.1, true)
        elseif e.lane == me then
            Float(tostring(e.dmg), e.lane, e.x2, 1, 1, 1)
        end
        if e.proj == "boom" then Float("BOOM!", e.lane, e.x2, 1, 0.5, 0.1, true) end
    elseif k == "splash" then
        Proj("boom", e.lane, e.x, e.lane, e.x)
    elseif k == "heal" then
        attackAt[(e.fromLane or e.lane) .. ":" .. (math.floor((e.from or e.x) / D.COL) + 1)] = GetTime()
        Proj("holy", e.fromLane or e.lane, e.from or e.x, e.lane, e.x)
        Float("+" .. e.amt, e.lane, e.x, 0.3, 1, 0.3)
    elseif k == "mheal" then
        Float("+", e.lane, e.x, 0.3, 0.9, 1)
    elseif k == "die" then
        if e.lane == me then
            local def = D.murlocs[e.kind]
            Float(string.format("+%dg", def.bounty), e.lane, e.x, 1, 0.82, 0)
        end
        if math.random(1, 6) == 1 then Float(D.QUOTES[math.random(#D.QUOTES)], e.lane, e.x, 0.6, 0.9, 1) end
    elseif k == "leak" then
        Float("-" .. D.murlocs[e.kind].leak .. " life", e.lane, 300, 1, 0.2, 0.2, true)
        if Throttled("leak", 1) and PlaySound and SOUNDKIT then pcall(PlaySound, SOUNDKIT.RAID_WARNING or 8959) end
    elseif k == "net" then
        Float("Netted!", e.lane, e.x, 0.8, 0.8, 1)
    elseif k == "leap" then
        Float("Leap!", e.lane, e.x, 0.6, 1, 1)
    elseif k == "bite" then
        if e.id then biteAt[e.id] = GetTime() end
    elseif k == "fall" then
        Float(e.kind == 0 and "Hero down!" or "Fallen!", e.lane, e.x, 1, 0.3, 0.3, e.kind == 0)
    elseif k == "level" then
        local S = game.S
        Banner(string.format("%s reached level %d!", S.heroes[e.p].name, e.n), 2)
        if e.p == me and PlaySound and SOUNDKIT and SOUNDKIT.UI_LEVELUP then pcall(PlaySound, SOUNDKIT.UI_LEVELUP) end
    elseif k == "boon" then
        Banner("|cff33ff99" .. D.boons[e.b].name .. "!|r  " .. D.boons[e.b].desc, 3)
    elseif k == "wave" then
        local text = "|cffffd100Wave " .. e.n .. "|r"
        if e.boss then text = text .. "  |cffff8000" .. D.murlocs[e.boss].name .. " approaches!|r" end
        Banner(text, 3)
        Sound(416)   -- Mrglglgl
    elseif k == "hop" then
        Banner(string.format("|cffff8000King Mrgl-Mrgl leaps into lane %d!|r", e.to), 2)
    elseif k == "lust" then
        Banner("|cffff4040BLOODLUST!|r", 2)
        if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then pcall(PlaySound, SOUNDKIT.RAID_WARNING) end
    elseif k == "gift" then
        Float("+" .. D.GIFT .. "g", e.to, 500, 1, 0.82, 0, true)
    elseif k == "upgrade" then
        Float("Rank " .. e.rank .. "!", e.lane, Sim.SlotX(e.col), 0.4, 0.8, 1, true)
    end
end

---------------------------------------------------------------------------
-- Board: lanes, terrain, defenders, murlocs
---------------------------------------------------------------------------

local function SlotClicked(i, col)
    local g = ns.Murloc:GetGame()
    if not g or i ~= g.me then return end
    local t = g.S.towers[i][col]
    if t then
        selectedTower = (selectedTower and selectedTower.col == col) and nil or { lane = i, col = col }
    else
        selectedTower = nil
        ns.Murloc:Act("b", i, col, selectedKind)
    end
end

-- Tiled texture helper (falls back to a stretch when the client can't repeat).
local function Tile(tex, path, w, h, tw, th)
    if not pcall(tex.SetTexture, tex, path, "REPEAT", "REPEAT") then tex:SetTexture(path) end
    tex:SetTexCoord(0, math.max(1, w / tw), 0, math.max(1, h / th))
end

local function BuildLanes(game)
    local S = game.S
    local h = board:GetHeight()
    geo.laneH = math.min(84, math.floor(h / S.players))
    geo.areaW = board:GetWidth() - LABEL_W
    geo.colW = geo.areaW / (D.LANE / D.COL)
    local laneH, colW = geo.laneH, geo.colW
    local map = D.maps[S.map]
    local media = D.MEDIA
    for i = 1, D.MAX_PLAYERS do
        local L = lanes[i]
        if not L then
            L = { slots = {} }
            L.frame = CreateFrame("Frame", nil, board)
            L.base = L.frame:CreateTexture(nil, "BACKGROUND", nil, -1)
            L.base:SetAllPoints()
            L.ground = L.frame:CreateTexture(nil, "BACKGROUND", nil, 0)
            L.ground:SetAllPoints()
            L.fade = L.frame:CreateTexture(nil, "BACKGROUND", nil, 2)
            L.fade:SetAllPoints()
            L.fade:SetTexture(media .. "lanefade")
            L.line = L.frame:CreateTexture(nil, "BORDER")
            L.line:SetColorTexture(0, 0, 0, 0.6)
            L.line:SetHeight(2)
            L.line:SetPoint("BOTTOMLEFT")
            L.line:SetPoint("BOTTOMRIGHT")
            L.mine = L.frame:CreateTexture(nil, "BORDER")
            L.mine:SetColorTexture(1, 0.8, 0.2, 0.7)
            L.mine:SetWidth(3)
            L.mine:SetPoint("TOPLEFT")
            L.mine:SetPoint("BOTTOMLEFT")
            L.plate = L.frame:CreateTexture(nil, "BACKGROUND", nil, 3)
            L.plate:SetColorTexture(0, 0, 0, 0.45)
            L.plate:SetPoint("TOPLEFT")
            L.plate:SetPoint("BOTTOMLEFT")
            L.plate:SetWidth(LABEL_W)
            L.label = ns.UI:CreateLabel(L.frame, "", "GameFontHighlightSmall")
            L.label:SetPoint("TOPLEFT", 6, -4)
            L.label:SetWidth(LABEL_W - 8)
            L.gift = ns.UI:CreateButton(L.frame, "+" .. D.GIFT .. "g", 50, 18, function() ns.Murloc:Act("g", i) end)
            L.gift:SetPoint("BOTTOMLEFT", 6, 4)
            L.gift:SetScript("OnEnter", function(self)
                ns.UI:SetTextTooltip(self, { "Gift " .. D.GIFT .. " gold", "Send some of your gold to this lane." })
            end)
            L.gift:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
            L.area = CreateFrame("Frame", nil, L.frame)
            for col = 1, D.SLOTS do
                local b = CreateFrame("Button", nil, L.area)
                b.plate = b:CreateTexture(nil, "BACKGROUND", nil, 4)
                b.plate:SetTexture(media .. "slot")
                b.plate:SetPoint("CENTER")
                b.decal = b:CreateTexture(nil, "BORDER")
                b.decal:SetPoint("CENTER")
                b.hl = b:CreateTexture(nil, "HIGHLIGHT")
                b.hl:SetColorTexture(1, 1, 1, 0.12)
                b.hl:SetAllPoints()
                b:SetScript("OnClick", function() SlotClicked(i, col) end)
                b:SetScript("OnEnter", function(self)
                    if self.terrain then
                        local t = D.terrain[self.terrain]
                        ns.UI:SetTextTooltip(self, { t.name, t.desc })
                    end
                end)
                b:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
                L.slots[col] = b
            end
            lanes[i] = L
        end
        if i <= S.players then
            local mine = i == game.me
            L.frame:ClearAllPoints()
            L.frame:SetPoint("TOPLEFT", 0, -(i - 1) * laneH)
            L.frame:SetSize(board:GetWidth(), laneH)
            local c = map.lane
            L.base:SetColorTexture(c[1] * 2, c[2] * 2, c[3] * 2, 1)
            Tile(L.ground, media .. (map.ground or "sand"), board:GetWidth(), laneH, 256, 128)
            local shade = mine and 1 or 0.8
            L.ground:SetVertexColor(shade, shade, shade)
            L.mine:SetShown(mine)
            L.area:ClearAllPoints()
            L.area:SetPoint("TOPLEFT", LABEL_W, 0)
            L.area:SetSize(geo.areaW, laneH)
            local plate = math.min(colW - 4, laneH - 8)
            for col = 1, D.SLOTS do
                local b = L.slots[col]
                local terrain = S.terrain[i][col] or nil
                b.terrain = terrain
                b:ClearAllPoints()
                b:SetPoint("LEFT", (col - 1) * colW, 0)
                b:SetSize(colW, laneH)
                b.plate:SetSize(plate, plate)
                b.plate:SetAlpha(mine and 0.9 or 0.55)
                b.plate:SetShown(terrain ~= "rocks")
                if terrain then
                    b.decal:SetTexture(media .. terrain)
                    b.decal:SetSize(plate, plate)
                    b.decal:Show()
                else
                    b.decal:Hide()
                end
            end
            L.gift:SetShown(not mine)
            L.frame:Show()
        else
            L.frame:Hide()
        end
    end
    if not board.surf then
        board.surf = board:CreateTexture(nil, "BACKGROUND", nil, 5)
        board.shore = board:CreateTexture(nil, "BACKGROUND", nil, 6)
        board.shore:SetTexture(media .. "shore")
        board.shore:SetTexCoord(1, 0, 0, 1)      -- foam on the beach side
        board.lust = board:CreateTexture(nil, "OVERLAY")
        board.lust:SetColorTexture(1, 0.1, 0.05, 0.12)
        board.lust:SetAllPoints()
    end
    local surfW = geo.areaW - D.SLOTS * colW
    board.surf:ClearAllPoints()
    board.surf:SetPoint("TOPLEFT", LABEL_W + D.SLOTS * colW, 0)
    board.surf:SetSize(surfW, laneH * S.players)
    Tile(board.surf, media .. "surf", surfW, laneH * S.players, 128, 128)
    board.shore:ClearAllPoints()
    board.shore:SetPoint("TOPRIGHT", board.surf, "TOPLEFT", 12, 0)
    board.shore:SetSize(28, laneH * S.players)
    board.builtFor = game.id .. ":" .. S.players .. ":" .. board:GetWidth() .. ":" .. board:GetHeight()
end

---------------------------------------------------------------------------
-- Models
---------------------------------------------------------------------------

-- Full-body camera that fits the frame (a model keeps a stale, zoomed-in camera after SetUnit / TryOn
-- otherwise and draws far outside its box).
local function FitCamera(m)
    pcall(m.SetPortraitZoom, m, 0)
    pcall(m.SetCamDistanceScale, m, m.camScale or 1)
    pcall(m.SetPosition, m, 0, 0, 0)
    if m.RefreshCamera then pcall(m.RefreshCamera, m) end
end

local function NewModel(parent, dressable)
    local ok, m = pcall(CreateFrame, dressable and "DressUpModel" or "PlayerModel", nil, parent)
    if not ok or not m then m = CreateFrame("PlayerModel", nil, parent) end
    pcall(m.SetScript, m, "OnModelLoaded", function(self)
        FitCamera(self)
        if self.facing then pcall(self.SetFacing, self, self.facing) end
    end)
    return m
end

local function SetAnim(m, anim)
    if m.anim ~= anim and m.SetAnimation then
        m.anim = anim
        pcall(m.SetAnimation, m, anim)
    end
end

-- Creature display candidates for a unit key ("forager", "totem", ...): a saved override first.
local modelState = {}          -- [key] = { idx = n, ok = bool }
local function Candidates(key, list)
    local over = ns.Games:GetData("murloc").displays
    local id = type(over) == "table" and tonumber(over[key])
    if id then return { id } end
    return list or {}
end

function MurlocUI:ResetModels() wipe(modelState) end

-- Points `m` at the first working creature display for `key`. A display that still has no model file
-- 1.5s after being set is skipped (models load asynchronously). Returns false when none is left.
local function ApplyCreature(m, key, list)
    local st = modelState[key]
    if not st then
        st = { idx = 1 }
        modelState[key] = st
    end
    local ids = Candidates(key, list)
    local id = ids[st.idx]
    if not id then return false end
    if m.displayId ~= id then
        pcall(m.SetDisplayInfo, m, id)
        m.displayId, m.setAt, m.anim, m.sig = id, GetTime(), nil, nil
        FitCamera(m)
    end
    if not st.ok and m:IsVisible() and GetTime() - m.setAt > 1.5 then
        local file = m.GetModelFileID and m:GetModelFileID()
        if not m.GetModelFileID or (file and file ~= 0) then
            st.ok = true
        else
            st.idx = st.idx + 1
            m.displayId = nil
        end
    end
    return true
end

-- A race model in an outfit (spec = { race, sex, items }) or a live unit (spec.unit). Set once per signature;
-- items are tried on again a few times because uncached items only appear once the client has them.
local function ApplyDressed(m, sig, spec)
    if m.sig ~= sig then
        m.sig, m.displayId, m.anim, m.facing = sig, nil, nil, nil
        m.dressAt, m.redress = GetTime(), 0
        if spec.unit then
            m.camScale = 1
            pcall(m.SetUnit, m, spec.unit)
            FitCamera(m)
        else
            m.camScale = tonumber(ns.Games:GetData("murloc").dressZoom) or 2
            -- a race model when the client supports it; otherwise my own character as the mannequin
            local raced = m.SetCustomRace and spec.race and pcall(m.SetCustomRace, m, spec.race, spec.sex or 0)
            if not raced then pcall(m.SetUnit, m, "player") end
            if not m.TryOn then
                m.sig = nil
                return false
            end
            m.redress = 4
        end
    end
    if m.redress > 0 and GetTime() >= m.dressAt then
        -- (re)dress a few times: the model loads asynchronously and uncached items appear late
        m.redress = m.redress - 1
        m.dressAt = GetTime() + 1
        if m.Undress then pcall(m.Undress, m) end
        for _, id in ipairs(spec.items or {}) do
            if id and id > 0 then pcall(m.TryOn, m, "item:" .. id) end
        end
        FitCamera(m)
    end
    return true
end

local function Facing(m, dir)
    local flip = ns.Games:GetData("murloc").flipFacing and -1 or 1
    local want = dir * flip * math.pi / 2
    if m.facing ~= want then
        m.facing = want
        pcall(m.SetFacing, m, want)
    end
end

local function Outfit(kindId)
    local faction = UnitFactionGroup and UnitFactionGroup("player") or "Alliance"
    local set = D.outfits[faction] or D.outfits.Alliance
    return set[kindId]
end

---------------------------------------------------------------------------
-- Units
---------------------------------------------------------------------------

local function AcquireIcon(pool, i, parent)
    local f = pool[i]
    if not f then
        f = CreateFrame("Frame", nil, parent)
        f.shadow = f:CreateTexture(nil, "BACKGROUND")
        f.shadow:SetTexture(D.MEDIA .. "shadow")
        f.icon = f:CreateTexture(nil, "ARTWORK")
        f.icon:SetAllPoints()
        f.barBg = f:CreateTexture(nil, "OVERLAY", nil, 1)
        f.barBg:SetColorTexture(0, 0, 0, 0.7)
        f.barBg:SetHeight(4)
        f.bar = f:CreateTexture(nil, "OVERLAY", nil, 2)
        f.bar:SetHeight(2)
        f.tag = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.pips = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.net = f:CreateTexture(nil, "OVERLAY")
        f.net:SetTexture("Interface\\Icons\\INV_Misc_Net_01")
        f.net:SetAlpha(0.7)
        f.sel = f:CreateTexture(nil, "OVERLAY")
        f.sel:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        f.sel:SetBlendMode("ADD")
        f.sel:SetAllPoints()
        pool[i] = f
    end
    f:SetParent(parent)
    f:Show()
    return f
end

-- Lays out the parts of a unit frame of size s (model box is bigger than the footprint).
local function Layout(f, s)
    f:SetSize(s, s)
    f.shadow:ClearAllPoints()
    f.shadow:SetSize(s * 1.1, s * 0.55)
    f.shadow:SetPoint("CENTER", f, "BOTTOM", 0, s * 0.12)
    f.barBg:ClearAllPoints()
    f.barBg:SetWidth(s)
    f.barBg:SetPoint("BOTTOM", f, "TOP", 0, 2)
    f.bar:ClearAllPoints()
    f.bar:SetPoint("LEFT", f.barBg, "LEFT", 1, 0)
    f.tag:ClearAllPoints()
    f.tag:SetPoint("TOP", f, "BOTTOM", 0, -1)
    f.pips:ClearAllPoints()
    f.pips:SetPoint("TOPRIGHT", 4, 4)
    f.net:ClearAllPoints()
    f.net:SetAllPoints()
end

local function SetBar(f, hp, maxHp, w)
    local pct = maxHp > 0 and math.max(0, math.min(1, hp / maxHp)) or 0
    f.bar:SetWidth(math.max(1, (w - 2) * pct))
    f.bar:SetColorTexture(1 - pct, 0.2 + 0.7 * pct, 0.1, 0.95)
end

local towerModels = {}        -- ["lane:col"] = model
local function TowerModel(key, parent)
    local m = towerModels[key]
    if not m then
        m = NewModel(parent, true)
        towerModels[key] = m
    end
    m:SetParent(parent)
    return m
end

local function DrawTowers(game)
    local S = game.S
    local laneH, colW = geo.laneH, geo.colW
    local n = 0
    local used = {}
    local size = math.min(colW - 6, laneH - 28)
    for lane = 1, S.players do
        for col = 1, D.SLOTS do
            local t = S.towers[lane][col]
            if t then
                n = n + 1
                local key = lane .. ":" .. col
                used[key] = true
                local f = AcquireIcon(towerPool, n, lanes[lane].area)
                f:SetFrameLevel(lanes[lane].area:GetFrameLevel() + 5)
                f:EnableMouse(false)
                local s = t.kind == 0 and math.min(colW, laneH - 26) or size
                Layout(f, s)
                f:ClearAllPoints()
                f:SetPoint("CENTER", lanes[lane].area, "LEFT", (col - 0.5) * colW, 0)
                local m = TowerModel(key, f)
                m:ClearAllPoints()
                m:SetPoint("CENTER", f, "CENTER", 0, 0)
                m:SetSize(laneH - 4, laneH - 4)
                m:SetFrameLevel(f:GetFrameLevel() + 1)
                local shown
                if t.kind == 0 then
                    local hero = S.heroes[t.owner]
                    local info = game.heroInfo and game.heroInfo[t.owner] or {}
                    local unit = UnitFor(game.players[t.owner])
                    if unit == "player" or (unit and UnitIsVisible and UnitIsVisible(unit)) then
                        shown = ApplyDressed(m, "unit:" .. unit, { unit = unit })
                    else
                        shown = ApplyDressed(m, "hero:" .. t.owner, { race = info.race, sex = info.sex, items = info.gear })
                    end
                    f.tag:SetText(string.format("|cffffd100%s|r |cff888888%d|r", hero.name, S.heroLevel[t.owner]))
                    f.pips:SetText("")
                    if not shown then ClassIcon(f.icon, hero.class) end
                else
                    local def = D.defenders[t.kind]
                    local outfit = Outfit(def.id)
                    if outfit then
                        shown = ApplyDressed(m, "def:" .. def.id, outfit)
                    elseif D.creatureModels[def.id] then
                        shown = ApplyCreature(m, def.id, D.creatureModels[def.id])
                    end
                    if not shown then
                        f.icon:SetTexture(def.icon)
                        f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                    end
                    f.tag:SetText("")
                    f.pips:SetText(string.rep("*", t.rank))
                end
                if shown then
                    Facing(m, 1)
                    local anim = ANIM.stand
                    if (t.stun or 0) > 0 then
                        anim = ANIM.stun
                    elseif GetTime() - (attackAt[key] or 0) < ATTACK_HOLD then
                        local what = t.kind == 0 and S.heroes[t.owner].role or D.defenders[t.kind].id
                        anim = ATTACK_ANIM[what] or ANIM.oneHand
                    end
                    SetAnim(m, anim)
                    m:Show()
                    f.icon:Hide()
                else
                    m:Hide()
                    f.icon:Show()
                end
                f.net:SetShown((t.stun or 0) > 0)
                f.sel:SetShown(selectedTower ~= nil and selectedTower.lane == lane and selectedTower.col == col)
                SetBar(f, t.hp, t.max, s)
            end
        end
    end
    for i = n + 1, #towerPool do towerPool[i]:Hide() end
    for key, m in pairs(towerModels) do
        if not used[key] then
            m:Hide()
            m.sig = nil
        end
    end
end

-- Murloc models belong to one murloc (by sim id) for its whole life; freed models are reused by kind.
local mobModels, freeModels = {}, {}

local function MobModel(m, kindKey)
    local model = mobModels[m.id]
    if model then return model end
    local free = freeModels[kindKey]
    model = free and table.remove(free)
    if not model then
        local count = 0
        for _ in pairs(mobModels) do count = count + 1 end
        if count >= MAX_MODELS then return nil end
        model = NewModel(overlay, false)
    end
    model.kindKey = kindKey
    mobModels[m.id] = model
    return model
end

local function DrawMurlocs(game, frac)
    local S = game.S
    local laneH = geo.laneH
    local seen = {}
    local k = 0
    for _, m in ipairs(S.mobs) do
        local def = D.murlocs[m.kind]
        k = k + 1
        seen[m.id] = true
        local s = math.min(def.size + 8, laneH - 28)
        local x = m.px + (m.x - m.px) * frac
        local f = AcquireIcon(mobPool, k, overlay)
        f:SetFrameLevel(overlay:GetFrameLevel() + 2)
        Layout(f, s)
        f:ClearAllPoints()
        f:SetPoint("CENTER", overlay, "TOPLEFT", SimX(x), LaneY(m.lane))
        f.pips:SetText("")
        f.net:Hide()
        f.sel:Hide()
        local model = MobModel(m, def.id)
        local shown = model and ApplyCreature(model, def.id, def.display)
        if shown then
            model:SetParent(overlay)
            model:SetFrameLevel(overlay:GetFrameLevel() + 3)
            model:ClearAllPoints()
            model:SetPoint("CENTER", f, "CENTER", 0, 0)
            model:SetSize(s * 1.6, s * 1.6)
            Facing(model, -1)
            local anim = ANIM.walk
            if GetTime() - (biteAt[m.id] or 0) < ATTACK_HOLD then
                anim = ANIM.unarmed
            elseif m.x == m.px then
                anim = ANIM.readyUnarmed
            end
            SetAnim(model, anim)
            model:Show()
            f.icon:Hide()
        else
            if model then model:Hide() end
            f.icon:Show()
            f.icon:SetTexture(def.icon)
            f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        end
        f.icon:SetVertexColor(m.slow > 0 and 0.6 or 1, m.slow > 0 and 0.8 or 1, 1)
        f.tag:SetText(def.boss and ("|cffff8000" .. def.name .. "|r") or "")
        SetBar(f, m.hp, m.max, s)
    end
    for i = k + 1, #mobPool do mobPool[i]:Hide() end
    for id, model in pairs(mobModels) do
        if not seen[id] then
            biteAt[id] = nil
            model:Hide()
            mobModels[id] = nil
            local list = freeModels[model.kindKey] or {}
            freeModels[model.kindKey] = list
            list[#list + 1] = model
        end
    end
end

---------------------------------------------------------------------------
-- Panels: tower, talents, boons, build bar, header
---------------------------------------------------------------------------

local function Choice(parent, i, onClick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(170, 44)
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    b:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    b:SetBackdropBorderColor(1, 0.8, 0.2, 0.8)
    b:SetPoint("TOPLEFT", 8 + (i - 1) * 176, -24)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(36, 36)
    b.icon:SetPoint("LEFT", 4, 0)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 4, 0)
    b.name:SetPoint("RIGHT", -4, 0)
    b.name:SetJustifyH("LEFT")
    b.sub = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.sub:SetPoint("BOTTOMLEFT", b.icon, "BOTTOMRIGHT", 4, 0)
    b.sub:SetPoint("RIGHT", -4, 0)
    b.sub:SetJustifyH("LEFT")
    b:SetScript("OnClick", function() onClick(i) end)
    b:SetScript("OnEnter", function(self) if self.tip then ns.UI:SetTextTooltip(self, self.tip) end end)
    b:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    return b
end

local function ChoicePanel(parent, title, onClick)
    local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    p:SetSize(544, 76)
    p:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    p:SetBackdropColor(0, 0, 0, 0.85)
    p:SetBackdropBorderColor(1, 0.5, 0, 0.9)
    p:SetFrameStrata("DIALOG")
    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.title:SetPoint("TOPLEFT", 8, -6)
    p.title:SetText(title)
    p.buttons = {}
    for i = 1, 3 do p.buttons[i] = Choice(p, i, onClick) end
    p:Hide()
    return p
end

local function TalentDesc(t)
    local parts = {}
    if t.hp then parts[#parts + 1] = "+" .. t.hp .. "% health" end
    if t.dmg then parts[#parts + 1] = "+" .. t.dmg .. "% damage" end
    if t.heal then parts[#parts + 1] = "+" .. t.heal .. "% healing" end
    if t.haste then parts[#parts + 1] = t.haste .. "% faster" end
    if t.splash then parts[#parts + 1] = "splash " .. t.splash end
    if t.slow then parts[#parts + 1] = "slows" end
    if t.chain then parts[#parts + 1] = "+1 heal target" end
    if t.cross then parts[#parts + 1] = "heals neighbouring lanes" end
    if t.lifesteal then parts[#parts + 1] = t.lifesteal .. "% lifesteal" end
    if t.crit then parts[#parts + 1] = "+" .. t.crit .. "% crit" end
    return table.concat(parts, ", ")
end

local function DrawPanels(game)
    local S = game.S
    local me = game.me
    -- talents
    local offer = S.talentOffer[me]
    if offer and not S.over then
        local pool = D.talents[S.heroes[me].role]
        for i, b in ipairs(talentPanel.buttons) do
            local idx = offer[i]
            local t = idx and pool[idx]
            b:SetShown(t ~= nil)
            if t then
                b.icon:SetTexture(t.icon)
                b.name:SetText(t.name)
                b.sub:SetText(string.format("Rank %d/%d", (S.talentPicks[me][idx] or 0) + 1, D.TALENT_MAX))
                b.tip = { t.name, TalentDesc(t) }
            end
        end
        talentPanel.title:SetText(string.format("|cffffd100Level %d!|r Choose a talent for your hero", S.heroLevel[me]))
        talentPanel:Show()
    else
        talentPanel:Hide()
    end
    -- boons (during the break)
    local boons = S.boonOffer
    if boons and S.phase == "break" and not S.over then
        for i, b in ipairs(boonPanel.buttons) do
            local def = D.boons[boons[i]]
            local votes = 0
            for p = 1, S.players do if S.votes[p] == i then votes = votes + 1 end end
            b.icon:SetTexture(def.icon)
            b.name:SetText(def.name)
            b.sub:SetText(string.format("%d vote%s%s", votes, votes == 1 and "" or "s",
                S.votes[me] == i and "  |cff33ff99(yours)|r" or ""))
            b.tip = { def.name, def.desc }
        end
        boonPanel.title:SetText(string.format("Vote for a party boon (next wave in %ds)",
            math.max(0, math.ceil((S.phaseEnd - S.tick) / D.TICK_RATE))))
        boonPanel:SetShown(not talentPanel:IsShown())
    else
        boonPanel:Hide()
    end
    -- selected tower
    local sel = selectedTower
    local t = sel and S.towers[sel.lane] and S.towers[sel.lane][sel.col]
    if not t then selectedTower = nil end
    if t and not S.over then
        local name
        if t.kind == 0 then
            name = S.heroes[me].name .. " (hero, level " .. S.heroLevel[me] .. ")"
        else
            name = D.defenders[t.kind].ranks[t.rank]
        end
        towerPanel.text:SetText(string.format("|cffffd100%s|r\n%d/%d hp  %s%s", name, t.hp, t.max,
            t.dmg > 0 and (t.dmg .. " dmg  ") or "", t.heal and (t.heal .. " heal") or ""))
        local cost = Sim.UpgradeCost(S, sel.lane, sel.col)
        towerPanel.up:SetText(cost and ("Upgrade " .. cost .. "g") or "Max rank")
        towerPanel.up:SetEnabled(Sim.CanUpgrade(S, me, sel.lane, sel.col))
        local value = Sim.SellValue(S, sel.lane, sel.col)
        towerPanel.sell:SetText(value and ("Sell " .. value .. "g") or "Sell")
        towerPanel.sell:SetEnabled(value ~= nil)
        towerPanel:Show()
    else
        towerPanel:Hide()
    end
    -- build bar
    for _, b in ipairs(buildBar.buttons) do
        local ok
        if b.kind == 0 then
            ok = Sim.HeroReady(S, me)
            local wait = (S.heroReady[me] or 0) - S.tick
            b.cost:SetText(S.heroUp[me] and "on field" or (wait > 0 and (math.ceil(wait / D.TICK_RATE) .. "s") or "free"))
        else
            local unlocked = Sim.Unlocked(S, me, b.kind)
            ok = unlocked and (S.gold[me] or 0) >= D.defenders[b.kind].cost and not S.over
            b.lock:SetShown(not unlocked)
        end
        b.icon:SetDesaturated(not ok)
        b.sel:SetShown(selectedKind == b.kind)
    end
    local need = D.XpForLevel(S.heroLevel[me])
    xpText:SetText(S.heroLevel[me] >= D.HERO_MAX_LEVEL and string.format("Hero level %d (max)", S.heroLevel[me])
        or string.format("Hero level %d  ·  %d/%d kills to next", S.heroLevel[me], S.heroXp[me], need))
end

local function DrawHeader(game)
    local S = game.S
    local hearts = string.rep("|TInterface\\Icons\\INV_ValentinesCandy:13|t", S.lives)
    local phase
    if S.over then
        phase = "|cffff4040" .. D.maps[S.map].name .. " has fallen|r"
    elseif S.phase == "break" then
        phase = string.format("Next wave in %ds", math.max(0, math.ceil((S.phaseEnd - S.tick) / D.TICK_RATE)))
    else
        phase = "|cffff8000Murlocs incoming!|r"
    end
    header:SetText(string.format("|cffffd100Wave %d|r  %s  |cffffd100%dg|r  %s%s", S.wave, hearts, S.gold[game.me] or 0,
        phase, game.isPaused and not game.ended and "  |cff888888(paused: combat)|r" or ""))
    local ready = Sim.LustReady(S)
    lustBtn:SetEnabled(ready)
    if S.over then lustBtn.text:SetText("") end
    lustBtn.icon:SetDesaturated(not ready)
    local lusting = S.tick < S.lustUntil
    board.lust:SetShown(lusting)
    if lusting then
        lustBtn.text:SetText("|cffff4040!|r")
    elseif ready or S.over then
        lustBtn.text:SetText("")
    else
        lustBtn.text:SetText(math.ceil((S.lustReady - S.tick) / D.TICK_RATE))
    end
    for i = 1, S.players do
        local hero = S.heroes[i]
        lanes[i].label:SetText(string.format("%s%s|r\n|cffffd100%dg|r", ClassColor(hero.class),
            Short(game.players[i]), S.gold[i] or 0))
        lanes[i].gift:SetEnabled(not S.over and (S.gold[game.me] or 0) >= D.GIFT)
    end
    resultText:SetShown(game.ended and true or false)
    if game.ended then
        local best = ns.Games:GetData("murloc").best
        resultText:SetText(string.format("Wave %d reached, %d murlocs slain.\nPersonal best: wave %d.", S.wave, S.kills,
            best or S.wave))
    end
end

local function DrawBoard()
    local game = ns.Murloc:GetGame()
    if not game then return end
    local S = game.S
    local key = game.id .. ":" .. S.players .. ":" .. board:GetWidth() .. ":" .. board:GetHeight()
    if board.builtFor ~= key then BuildLanes(game) end
    local fx = S.fx
    if fx and #fx > 0 then
        S.fx = {}
        for _, e in ipairs(fx) do HandleFx(game, e) end
    end
    local frac = math.max(0, math.min(1, (game.acc or 0) * D.TICK_RATE))
    if game.isPaused or game.ended then frac = 1 end
    DrawTowers(game)
    DrawMurlocs(game, frac)
    DrawPanels(game)
    DrawHeader(game)
    AnimateFx()
end

local function CreateGame(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()
    header = ns.UI:CreateLabel(v, "", "GameFontNormal")
    header:SetPoint("TOPLEFT", 10, -12)

    quitBtn = ns.UI:CreateButton(v, "Leave game", 90, 22, function() ns.Murloc:Quit() end)
    quitBtn:SetPoint("TOPRIGHT", -8, -6)

    lustBtn = CreateFrame("Button", nil, v)
    lustBtn:SetSize(28, 28)
    lustBtn:SetPoint("RIGHT", quitBtn, "LEFT", -8, 0)
    lustBtn.icon = lustBtn:CreateTexture(nil, "ARTWORK")
    lustBtn.icon:SetAllPoints()
    lustBtn.icon:SetTexture(D.LUST.icon)
    lustBtn.text = lustBtn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    lustBtn.text:SetPoint("CENTER")
    lustBtn:SetScript("OnClick", function() ns.Murloc:Act("l") end)
    lustBtn:SetScript("OnEnter", function(self)
        ns.UI:SetTextTooltip(self, { D.LUST.name, "Party ability: every defender attacks twice as fast for 15s.",
            "Shared 2 minute cooldown. Anyone can press it, so talk it over!" })
    end)
    lustBtn:SetScript("OnLeave", function() ns.UI:HideTooltip() end)

    board = CreateFrame("Frame", nil, v)
    board:SetPoint("TOPLEFT", 6, -38)
    board:SetPoint("BOTTOMRIGHT", -6, 58)
    if board.SetClipsChildren then board:SetClipsChildren(true) end
    overlay = CreateFrame("Frame", nil, board)
    overlay:SetAllPoints()
    overlay:SetFrameLevel(board:GetFrameLevel() + 20)

    banner = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    banner:SetPoint("TOP", 0, -8)
    banner:Hide()

    buildBar = CreateFrame("Frame", nil, v)
    buildBar:SetPoint("BOTTOMLEFT", 8, 18)
    buildBar:SetSize(560, 36)
    buildBar.buttons = {}
    local kinds = { 0 }
    for i = 1, #D.defenders do kinds[#kinds + 1] = i end
    for i, kind in ipairs(kinds) do
        local b = CreateFrame("Button", nil, buildBar)
        b:SetSize(30, 30)
        b:SetPoint("LEFT", (i - 1) * 74, 0)
        b.kind = kind
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        b.sel = b:CreateTexture(nil, "OVERLAY")
        b.sel:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        b.sel:SetBlendMode("ADD")
        b.sel:SetAllPoints()
        b.lock = b:CreateTexture(nil, "OVERLAY")
        b.lock:SetTexture("Interface\\PetBattles\\PetBattle-LockIcon")
        b.lock:SetSize(16, 16)
        b.lock:SetPoint("BOTTOMRIGHT", 2, -2)
        b.lock:Hide()
        b.cost = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.cost:SetPoint("LEFT", b, "RIGHT", 3, 0)
        if kind ~= 0 then
            b.icon:SetTexture(D.defenders[kind].icon)
            b.cost:SetText("|cffffd100" .. D.defenders[kind].cost .. "g|r")
        end
        b:SetScript("OnClick", function() selectedKind = kind end)
        b:SetScript("OnEnter", function(self)
            if kind == 0 then
                local g = ns.Murloc:GetGame()
                local h = g and g.S.heroes[g.me]
                ns.UI:SetTextTooltip(self, { "Your hero", h and HeroLine(h) or "",
                    "One copy of you, free. Levels up from kills in your lane. Respawns 30s after falling." })
            else
                local d = D.defenders[kind]
                local lines = { d.name .. "  (" .. d.cost .. "g)", d.desc, string.format("%d hp, %d damage", d.hp, d.dmg) }
                if d.rep > 0 then lines[#lines + 1] = "Requires " .. D.REP_TIERS[d.rep + 1].name .. " with the Southshore Militia" end
                ns.UI:SetTextTooltip(self, lines)
            end
        end)
        b:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
        buildBar.buttons[i] = b
    end
    xpText = ns.UI:CreateLabel(v, "", "GameFontHighlightSmall")
    xpText:SetPoint("BOTTOMLEFT", 10, 4)
    local hint = ns.UI:CreateLabel(v, "Pick a defender, click a slot. Click a defender to upgrade or sell.", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMRIGHT", -10, 4)

    towerPanel = CreateFrame("Frame", nil, v, "BackdropTemplate")
    towerPanel:SetSize(170, 74)
    towerPanel:SetPoint("BOTTOMRIGHT", board, "BOTTOMRIGHT", -4, 4)
    towerPanel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    towerPanel:SetBackdropColor(0, 0, 0, 0.9)
    towerPanel:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.9)
    towerPanel:SetFrameStrata("DIALOG")
    towerPanel.text = ns.UI:CreateLabel(towerPanel, "", "GameFontHighlightSmall")
    towerPanel.text:SetPoint("TOPLEFT", 6, -6)
    towerPanel.text:SetPoint("RIGHT", -6, 0)
    towerPanel.up = ns.UI:CreateButton(towerPanel, "Upgrade", 88, 20, function()
        if selectedTower then ns.Murloc:Act("u", selectedTower.lane, selectedTower.col) end
    end)
    towerPanel.up:SetPoint("BOTTOMLEFT", 4, 4)
    towerPanel.sell = ns.UI:CreateButton(towerPanel, "Sell", 70, 20, function()
        if selectedTower then ns.Murloc:Act("s", selectedTower.lane, selectedTower.col) selectedTower = nil end
    end)
    towerPanel.sell:SetPoint("BOTTOMRIGHT", -4, 4)
    towerPanel:Hide()

    talentPanel = ChoicePanel(v, "Choose a talent", function(i) ns.Murloc:Act("t", i) end)
    talentPanel:SetPoint("BOTTOM", board, "BOTTOM", 0, 6)
    boonPanel = ChoicePanel(v, "Vote for a party boon", function(i) ns.Murloc:Act("v", i) end)
    boonPanel:SetPoint("BOTTOM", board, "BOTTOM", 0, 6)

    resultText = ns.UI:CreateLabel(v, "", "GameFontNormalHuge")
    resultText:SetJustifyH("CENTER")
    resultText:SetPoint("CENTER", board, "CENTER")
    resultText:Hide()

    v:SetScript("OnUpdate", DrawBoard)
    return v
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

function MurlocUI:Refresh()
    if not root then return end
    local game = ns.Murloc:GetGame()
    gameView:SetShown(game ~= nil)
    lobbyView:SetShown(game == nil)
    if game then
        local heroBtn = buildBar.buttons[1]
        ClassIcon(heroBtn.icon, game.S.heroes[game.me].class)
        board.builtFor = nil
    else
        selectedTower = nil
        RefreshLobby()
    end
end

function MurlocUI:CreatePanel(parent)
    root = CreateFrame("Frame", nil, parent)
    lobbyView = CreateLobby(root)
    gameView = CreateGame(root)
    root:SetScript("OnShow", function()
        local g = ns.Murloc:GetGame()
        if g then g.S.fx = {} end        -- don't replay what happened while the window was closed
        MurlocUI:Refresh()
    end)
    root.OnGameShown = function() MurlocUI:Refresh() end
    MurlocUI:Refresh()
    return root
end

-- /cdl murlocmodels [key id | flip | reset]: inspect / override the creature display IDs in-game.
local function ModelsSlash(rest)
    local data = ns.Games:GetData("murloc")
    data.displays = type(data.displays) == "table" and data.displays or {}
    local a, b = (rest or ""):match("^%s*(%S*)%s*(%S*)")
    if a == "zoom" and tonumber(b) then
        data.dressZoom = tonumber(b)
        for _, m in pairs(towerModels) do m.sig = nil end
        ns:Print("Murloc Defense: dressed defenders use camera distance %.1f (default 2).", tonumber(b))
    elseif a == "flip" then
        data.flipFacing = not data.flipFacing
        ns:Print("Murloc Defense models now face the %s way.", data.flipFacing and "other" or "default")
    elseif a == "reset" then
        wipe(data.displays)
        MurlocUI:ResetModels()
        ns:Print("Murloc Defense model overrides cleared.")
    elseif a ~= "" and tonumber(b) then
        data.displays[a] = tonumber(b)
        MurlocUI:ResetModels()
        ns:Print("Murloc Defense: '%s' now uses display %d.", a, tonumber(b))
    else
        ns:Print("Murloc Defense creature models (override: /cdl murlocmodels <key> <displayID>, 'flip', 'reset'):")
        for _, m in ipairs(D.murlocs) do
            ns:Print("  %s: %s", m.id, table.concat(m.display or {}, ", ") .. (data.displays[m.id] and
                ("  |cff33ff99override " .. data.displays[m.id] .. "|r") or ""))
        end
        for key, list in pairs(D.creatureModels) do
            ns:Print("  %s: %s", key, table.concat(list, ", ") .. (data.displays[key] and
                ("  |cff33ff99override " .. data.displays[key] .. "|r") or ""))
        end
    end
end

function MurlocUI:OnInit()
    ns:On("MURLOC_UPDATED", function()
        if root and root:IsVisible() then MurlocUI:Refresh() end
    end)
    ns:RegisterSlash("murlocmodels", ModelsSlash, "murlocmodels [key id|zoom n|flip|reset] - Murloc Defense models")
end

-- Ask the client for the outfit items early so the dressed defenders have their gear when a game starts.
function MurlocUI:OnLogin()
    local ItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    for _, set in pairs(D.outfits) do
        for _, o in pairs(set) do
            for _, id in ipairs(o.items) do pcall(ItemInfo, id) end
        end
    end
end
