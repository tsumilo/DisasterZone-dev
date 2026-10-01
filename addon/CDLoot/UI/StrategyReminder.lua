if CDLootBoot and CDLootBoot.Run("UI/StrategyReminder.lua", ...) then return end -- CDLoot: UI/StrategyReminder.lua
-- The encounter reminder (Addendum K): a slim panel near a planned boss with my jobs from the raid's strategy and the
-- live state of the tracked tables I'm in (whose kick it is, my misdirect done, Innervate ready, my curse up). The
-- raid leader also sees the tracked tables they are not in. It stays through the fight and fades after it; the body is
-- click-through, the header drags it and opens the board.
-- Items() is the content (rows with an icon, text and status); Lines() flattens it for tests and chat;
-- Core/StrategyLive.lua holds the state.
local addonName, ns = ...

local Reminder = ns:NewModule("StrategyReminder")

local floor, max, min, abs, sin = math.floor, math.max, math.min, math.abs, math.sin
local tconcat = table.concat

local WIDTH = 270
local ROW_H = 20
local CHIP_H = 16
local PAD = 8
local NAME = "CDLootStrategyReminder"

local OK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t"
local NO = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t"
local WAIT = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14|t"

local function Live() return ns.StrategyLive end
local function S() return ns.Strategy end
local function MapUI() return ns.StrategyMapUI end
local function grey(t) return "|cff8c8c8c" .. tostring(t) .. "|r" end
local function green(t) return "|cff40ff70" .. tostring(t) .. "|r" end
local function red(t) return "|cffff4a40" .. tostring(t) .. "|r" end
local function gold(t) return "|cffffd100" .. tostring(t) .. "|r" end
local function orange(t) return "|cffff9933" .. tostring(t) .. "|r" end

-- The icon of a tracked table without one of its own: its spell.
local KIND_ICON = {
    rot = "i:Ability_Kick", md = "i:Ability_Hunter_Misdirection", bl = "i:Spell_Nature_BloodLust",
    pi = "i:Spell_Holy_PowerInfusion", iv = "i:Spell_Nature_Lightning", curse = "i:Spell_Shadow_CurseOfTounges",
    dsp = "i:Spell_Holy_DispelMagic",
}

-- What removing an effect is called, by its dispel type (from the enemy: purge / tranquilize).
local DISPEL_VERB = { m = "Dispel", c = "Decurse", p = "Cure", d = "Cure", e = "Tranq" }

local function Me() return ns.Util.PlayerKey() end

local function ClassName(key)
    local class = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)
    return ns.UI:ColoredName(key, class)
end

local function Name(key)
    if not key then return grey("nobody") end
    if key == Me() then return green("You") end
    return ClassName(key)
end

-- The same, lower case "you" inside a sentence ("onto you").
local function NameIn(key)
    if key == Me() then return green("you") end
    return Name(key)
end

-- A short name for a row's mob: the Target cell's label when short ("Gathios ->" -> "Gathios"), else the first word
-- of it ("Attumen the Huntsman" -> "Attumen").
local function Short(label)
    if not label or label == "" then return nil end
    label = label:gsub("%s*%-*>%s*$", "")
    if #label <= 24 then return label end
    return label:match("^(%S+)") or label
end

local function Clock(sec)
    sec = max(0, floor(sec + 0.5))
    if sec < 60 then return sec .. " s" end
    return ("%d:%02d"):format(floor(sec / 60), sec % 60)
end

---------------------------------------------------------------------------
-- Content
---------------------------------------------------------------------------

-- A tracked row's status: text + whether it wants attention.
local function RowStatus(c, tr, r)
    local L = Live()
    if tr.kind == "md" then
        if r.done then
            if r.onto and r.dest and r.dest ~= r.onto then
                return orange("onto " .. ns.Util.ShortName(r.dest) .. ", not " .. ns.Util.ShortName(r.onto))
            end
            return green("done ") .. OK
        end
        if not c.engaged then return gold("on pull") end
        if GetTime() - (c.pullAt or 0) < L.PULL_WINDOW then return gold("now") end
        return grey("not cast")
    elseif tr.kind == "bl" then
        if r.done then return green("done ") .. OK end
        local at = L:PlannedAt(r)
        if c.engaged and at then
            local left = at - (GetTime() - c.pullAt)
            if left > 0 then return grey("in " .. Clock(left)) end
            return gold("NOW")
        end
        return WAIT
    elseif tr.kind == "pi" or tr.kind == "iv" then
        local cd = L:Cooldown(r)
        if cd > 0 then return grey(Clock(cd)) end
        return green("ready")
    elseif tr.kind == "curse" then
        if r.up then return OK end
        if r.fellAt then return red("fell off"), true end
        return c.engaged and orange("not up") or gold("on pull")
    end
    return ""
end

-- What a tracked row of mine says.
local function RowText(tr, r)
    if tr.kind == "md" then
        local mob = Short(r.label) or (r.target and r.target.i and Short(MapUI():IconName(r.target.i, Live():GetCurrent() and Live():GetCurrent().boss)))
        return "Misdirect" .. (mob and (" " .. mob) or "") .. (r.onto and (" onto " .. NameIn(r.onto)) or "")
    elseif tr.kind == "pi" then
        return "Power Infusion on " .. NameIn(r.onto)
    elseif tr.kind == "iv" then
        return "Innervate on " .. NameIn(r.onto)
    elseif tr.kind == "bl" then
        return "Bloodlust"
    elseif tr.kind == "curse" then
        -- "Curse of Tongues on Malande" when the curse was picked; the label else
        local mob = r.target and r.target.i and Short(MapUI():IconName(r.target.i, Live():GetCurrent() and Live():GetCurrent().boss))
        if r.curseId then return GetSpellInfo(r.curseId) .. (mob and (" on " .. mob) or "") end
        return r.label or "Curse"
    end
    return r.label or tr.name
end

-- A dispel table's job in words ("Decurse Curse of Doom", "Purge Pyrogenics +1") and its icon.
local function DispelText(tr)
    local verb = (tr.enemy and tr.dtype == "m") and "Purge" or DISPEL_VERB[tr.dtype] or "Remove"
    local first = tr.effectIds[1]
    if not first then return verb .. ": " .. tr.name, tr.icon or KIND_ICON.dsp end
    local name = GetSpellInfo(first) or ("spell " .. first)
    return verb .. " " .. name .. (#tr.effectIds > 1 and (" +" .. (#tr.effectIds - 1)) or ""), tr.icon or ("sp:" .. first)
end

-- Who carries it now, in short: "Aldren, Brisa +2".
local function DispelTargets(list)
    local names = {}
    for i, e in ipairs(list) do
        if i > 2 then break end
        names[i] = ns.Util.ShortName(tostring(e.name or "?")) or tostring(e.name or "?")
    end
    return tconcat(names, ", ") .. (#list > 2 and (" +" .. (#list - 2)) or "")
end

-- The rotation's chips: the designated kickers, then the backups. { text, current, me, dead, backup, cd }.
local function Chips(tr, pick)
    local out = {}
    local now = GetTime()
    for _, list in ipairs({ tr.order, tr.backups or {} }) do
        for _, r in ipairs(list) do
            local text = r.player == Me() and green("You") or ClassName(r.player)
            if r.dead then text = grey(ns.Util.ShortName(r.player)) end
            out[#out + 1] = { text = text, current = r == pick, me = r.player == Me(), dead = r.dead,
                              backup = r.backup, cd = Live().CdLeft(r, now) }
        end
    end
    return out
end

-- Am I in this rotation (designated or backup)?
local function InRotation(tr, me)
    for _, list in ipairs({ tr.order, tr.backups or {} }) do
        for _, r in ipairs(list) do
            if r.player == me then return r end
        end
    end
    return nil
end

-- Short job text from a slot: the row's job (and the table as the grey part).
local function JobParts(slot)
    local parts = {}
    for part in (slot.label .. " \194\183 "):gmatch("(.-) \194\183 ") do parts[#parts + 1] = part end
    if #parts >= 2 then return parts[2], parts[1] end
    return slot.label, nil
end

-- The icon of a plain job: the row's target (a boss portrait, a raid mark), else the table's icon.
local function JobIcon(c, slot)
    local k = S():FindBlock(c.s, slot.block)
    local cell = k and k.d and k.d[slot.row]
    if cell then
        for ci, col in ipairs(k.c) do
            if col.t == "g" and type(cell[ci]) == "table" and cell[ci].i then return cell[ci].i end
        end
    end
    return k and k.i or nil
end

-- The content: { title, state, practice, boss, occ, strat, items = { ... }, flash } or nil when nothing to show.
-- item kinds: job { icon, text, sub }; row { icon, text, status, alert }; rot { icon, text, status, alert, chips };
-- header { text } (the raid section).
function Reminder:Items()
    local c = Live():GetCurrent()
    if not c then return nil end
    local DB = ns.DB
    if DB and DB.GetSetting and DB:GetSetting("strategy.reminder") == false then return nil end
    local me = Me()
    local items, flash = {}, nil
    local tracked, mineIn = {}, {}
    for _, tr in ipairs(c.trackers) do tracked[tr.id] = tr end
    -- my plain jobs
    for _, slot in ipairs(Live():MySlots()) do
        if not tracked[slot.block] then
            local text, sub = JobParts(slot)
            items[#items + 1] = { kind = "job", icon = JobIcon(c, slot), text = text, sub = sub }
        end
    end
    -- my tracked rows
    for _, tr in ipairs(c.trackers) do
        if tr.kind == "rot" then
            local mineRow = InRotation(tr, me)
            if mineRow then
                mineIn[tr.id] = true
                local pick, how = Live():Turn(tr)
                local myTurn = pick == mineRow
                local status, alert
                if myTurn and tr.flash and tr.castStart then
                    status, alert = red("KICK NOW"), true
                    flash = "KICK NOW" .. (tr.castName and (": " .. tr.castName) or "")
                elseif myTurn and how == "cond" then
                    status = gold(Live():CondShort(mineRow.cond) .. ": your turn")
                elseif myTurn then
                    status = how == "backup" and gold("backup: you're next") or green("your turn")
                elseif Live().School(mineRow) and Live():Immunities(tr.npc)[Live().School(mineRow)] then
                    status = grey("immune to yours")
                elseif mineRow.cond and not Live():CondHolds(mineRow, tr) then
                    status = grey("only when " .. Live():CondShort(mineRow.cond))
                elseif Live().CdLeft(mineRow) > 0 then
                    status = grey("ready in " .. Clock(Live().CdLeft(mineRow)))
                elseif pick then
                    status = grey(ns.Util.ShortName(pick.player) .. "'s turn" .. (how == "backup" and " (backup)" or ""))
                end
                items[#items + 1] = { kind = "rot", icon = tr.icon or KIND_ICON.rot, text = tr.name,
                                      status = status, alert = alert, chips = Chips(tr, pick), tr = tr, myTurn = myTurn,
                                      backupTurn = myTurn and how == "backup" }
            end
        elseif tr.kind == "dsp" then
            -- everyone responsible is told at once while the effect is up
            if Live():DispelMine(tr) then
                mineIn[tr.id] = true
                local text, icon = DispelText(tr)
                local active = Live():DispelActive(tr)
                local status, alert
                if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then
                    status = grey("you're dead")
                elseif #active > 0 then
                    status, alert = red("NOW: " .. DispelTargets(active)), true
                    flash = flash or (text .. (tr.enemy and " on " or " from ") .. DispelTargets(active))
                else
                    status = c.engaged and grey("clear") or gold("watch for it")
                end
                items[#items + 1] = { kind = "row", icon = icon, text = text, status = status, alert = alert, tr = tr }
            end
        else
            for _, r in ipairs(tr.rows) do
                if r.player == me then
                    mineIn[tr.id] = true
                    local status, alert = RowStatus(c, tr, r)
                    local icon = tr.icon or KIND_ICON[tr.kind]
                    if tr.kind == "curse" and r.curseId then icon = "sp:" .. r.curseId
                    elseif tr.kind == "curse" and r.target and r.target.i then icon = r.target.i end
                    items[#items + 1] = { kind = "row", icon = icon, text = RowText(tr, r), status = status,
                                          alert = alert, tr = tr, r = r }
                    if tr.kind == "curse" and r.fellAt and c.engaged and not r.up then
                        flash = flash or ("Your " .. (r.curseId and GetSpellInfo(r.curseId) or r.label or "curse") .. " fell off")
                    end
                end
            end
        end
    end
    local mine = #items > 0
    -- the raid leader: the tracked tables I'm not in
    if Live():IsMarker() or c.practice then
        local first = true
        for _, tr in ipairs(c.trackers) do
            if not mineIn[tr.id] then
                if first then
                    items[#items + 1] = { kind = "header", text = "Raid" }
                    first = false
                end
                if tr.kind == "rot" then
                    local pick, how = Live():Turn(tr)
                    local status = pick and (ns.Util.ShortName(pick.player) .. "'s turn") or ""
                    if how == "cond" then status = gold(status .. " (" .. Live():CondShort(pick.cond) .. ")")
                    elseif how == "backup" then status = gold(status .. " (backup)") elseif how == "late" then
                        status = red(status .. " (not ready)") else status = grey(status) end
                    items[#items + 1] = { kind = "rot", icon = tr.icon or KIND_ICON.rot, text = tr.name,
                                          status = status, chips = Chips(tr, pick), tr = tr, overview = true }
                elseif tr.kind == "dsp" then
                    local names = {}
                    for _, r in ipairs(tr.order) do names[#names + 1] = ns.Util.ShortName(r.player) end
                    local active = Live():DispelActive(tr)
                    local _, icon = DispelText(tr)
                    items[#items + 1] = { kind = "row", icon = icon, text = tr.name,
                                          status = #active > 0 and orange("on " .. DispelTargets(active)) or grey("clear"),
                                          detail = (#names > 0 and tconcat(names, ", ") or "everyone who can") .. "  ",
                                          tr = tr, overview = true }
                else
                    local parts, alert = {}, false
                    for _, r in ipairs(tr.rows) do
                        if r.player then
                            local st, a = RowStatus(c, tr, r)
                            alert = alert or a
                            parts[#parts + 1] = ns.Util.ShortName(r.player) .. " " .. st
                        end
                    end
                    items[#items + 1] = { kind = "row", icon = tr.icon or KIND_ICON[tr.kind], text = tr.name,
                                          status = #parts == 0 and grey("nobody") or "", detail = tconcat(parts, "  "),
                                          tr = tr, overview = true, alert = alert }
                end
            end
        end
    end
    if #items == 0 then return nil end
    local state = c.engaged and "engaged" or (c.ended and (c.success and "killed" or "wipe") or "next")
    local boss = ns.Data and ns.Data.BossPortraits and ns.Data.BossPortraits[c.boss]
    return {
        title = c.name, state = state, practice = c.practice, mine = mine, items = items, flash = flash,
        portrait = boss and boss[1] and ("boss:" .. boss[1].d) or nil,
        boss = c.boss, occ = c.occ, strat = c.s.id, strategy = c.s.n, linked = c.occ ~= nil,
    }
end

-- The content as plain lines (tests, chat): { title, sub, lines, flash, ... }.
function Reminder:Lines()
    local d = self:Items()
    if not d then return nil end
    local lines = {}
    for _, it in ipairs(d.items) do
        if it.kind == "job" then
            lines[#lines + 1] = "- " .. (it.sub and (it.sub .. ": ") or "") .. it.text
        elseif it.kind == "header" then
            lines[#lines + 1] = it.text
        elseif it.kind == "rot" then
            local mains, backs = {}, {}
            for _, ch in ipairs(it.chips) do
                local t = ch.me and "YOU" or ch.text
                if ch.dead then t = t .. " (dead)" end
                t = ch.current and ("[" .. t .. "]") or t
                if ch.backup then backs[#backs + 1] = t else mains[#mains + 1] = t end
            end
            lines[#lines + 1] = (it.overview and "  " or "") .. it.text .. ": " .. tconcat(mains, " > ")
                .. (#backs > 0 and (" | backup: " .. tconcat(backs, ", ")) or "")
            if it.myTurn and not it.alert then
                lines[#lines + 1] = it.backupTurn and "  Backup: your kick is next" or "  Your kick is next"
            end
        else
            lines[#lines + 1] = (it.overview and ("  " .. it.text .. ": " .. (it.detail or "") .. it.status))
                or (it.text .. ": " .. it.status)
        end
    end
    return {
        title = d.title .. "  " .. d.state,
        sub = (d.practice and "PRACTICE  " or "") .. (d.mine and "Your jobs" or "Overview") .. "  \194\183  "
            .. d.strategy .. ((d.linked or d.practice) and "" or " (no raid linked)"),
        lines = lines, flash = d.flash, boss = d.boss, occ = d.occ, strat = d.strat,
    }
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local frame

local function SavePos(f)
    local point, _, relPoint, x, y = f:GetPoint(1)
    if not point or not (ns.db and ns.db.settings) then return end
    ns.db.settings.windows = ns.db.settings.windows or {}
    ns.db.settings.windows[NAME] = { point, relPoint or point, floor((x or 0) + 0.5), floor((y or 0) + 0.5) }
end

local STATE_COLOR = {
    next = { 0.55, 0.55, 0.55 }, engaged = { 0.25, 0.85, 0.35 }, killed = { 0.25, 0.85, 0.35 },
    wipe = { 0.85, 0.3, 0.25 }, practice = { 1, 0.6, 0.15 },
}

local function NewRow(f)
    local r = CreateFrame("Frame", nil, f)
    r:SetHeight(ROW_H)
    r:EnableMouse(false)
    r.hl = r:CreateTexture(nil, "BACKGROUND")
    r.hl:SetAllPoints()
    r.hl:Hide()
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.icon:SetPoint("TOPLEFT", 0, -2)
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.text:SetJustifyH("LEFT")
    r.text:SetWordWrap(false)
    r.status = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.status:SetPoint("TOPRIGHT", -2, -4)
    r.status:SetJustifyH("RIGHT")
    r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.sub:SetJustifyH("LEFT")
    r.sub:SetWordWrap(false)
    r.chips = {}
    return r
end

local function Chip(row, i)
    local ch = row.chips[i]
    if ch then return ch end
    ch = CreateFrame("Frame", nil, row)
    ch:SetHeight(CHIP_H)
    ch.bg = ch:CreateTexture(nil, "BACKGROUND")
    ch.bg:SetAllPoints()
    ch.fs = ch:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ch.fs:SetPoint("CENTER")
    row.chips[i] = ch
    return ch
end

local function Create()
    local f = CreateFrame("Frame", NAME, UIParent, "BackdropTemplate")
    f.cdlName = NAME
    f:SetSize(WIDTH, 60)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(false)            -- click-through body
    ns.UI:StyleHud(f)          -- the same slim style as the raid session bar
    -- header: portrait, boss name, a state tag; drag to move, click to open the board
    local h = CreateFrame("Button", nil, f)
    h:SetPoint("TOPLEFT", PAD, -PAD + 2)
    h:SetPoint("TOPRIGHT", -PAD, -PAD + 2)
    h:SetHeight(24)
    h:RegisterForDrag("LeftButton")
    h:RegisterForClicks("LeftButtonUp")
    h.portrait = h:CreateTexture(nil, "ARTWORK")
    h.portrait:SetSize(22, 22)
    h.portrait:SetPoint("LEFT", -2, 0)
    h.fs = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h.fs:SetPoint("LEFT", h.portrait, "RIGHT", 6, 0)
    h.fs:SetJustifyH("LEFT")
    h.fs:SetWordWrap(false)
    h.tag = CreateFrame("Frame", nil, h)
    h.tag:SetHeight(14)
    h.tag:SetPoint("RIGHT", 0, 0)
    h.tag.bg = h.tag:CreateTexture(nil, "BACKGROUND")
    h.tag.bg:SetAllPoints()
    h.tag.fs = h.tag:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    h.tag.fs:SetPoint("CENTER")
    h.fs:SetPoint("RIGHT", h.tag, "LEFT", -8, 0)
    h:SetScript("OnDragStart", function() f:StartMoving() end)
    h:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        SavePos(f)
    end)
    h:SetScript("OnClick", function()
        local d = f.data
        if not d then return end
        if d.occ then ns.StrategyBoard:OpenRaid(d.occ, d.boss) elseif d.strat then ns.StrategyBoard:OpenStrategy(d.strat) end
    end)
    h:SetScript("OnEnter", function(self)
        local d = f.data
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(d and d.strategy or "Strategy board")
        if d and not d.linked and not d.practice then
            GameTooltip:AddLine("No planned raid is linked to this raid session, so there are no names.", 1, 0.6, 0.2, true)
        end
        GameTooltip:AddLine("Click to open the board; drag to move.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    h:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.header = h
    f.sep = f:CreateTexture(nil, "ARTWORK")
    f.sep:SetHeight(1)
    f.sep:SetPoint("TOPLEFT", PAD, -PAD - 26)
    f.sep:SetPoint("TOPRIGHT", -PAD, -PAD - 26)
    f.sep:SetColorTexture(1, 1, 1, 0.12)
    f.rows = {}
    ns.UI:RestorePosition(f)
    local pos = ns.db and ns.db.settings and ns.db.settings.windows and ns.db.settings.windows[NAME]
    if not pos then
        f:ClearAllPoints()
        f:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end
    local acc = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        acc = acc + elapsed
        if self.fading then
            local a = max(0, self:GetAlpha() - elapsed / 1.5)
            self:SetAlpha(a)
            if a <= 0 then
                self.fading = nil
                self:Hide()
            end
            return
        end
        if self.alert and self.SetBackdropBorderColor then
            local p = 0.5 + 0.5 * abs(sin(GetTime() * 6))
            self:SetBackdropBorderColor(1, 0.25 + 0.2 * p, 0.2, 0.6 + 0.4 * p)
        end
        if acc >= 0.25 then
            acc = 0
            Reminder:Refresh()
        end
    end)
    f:Hide()
    frame = f
    return f
end

local function Layout(f, d)
    local y = -PAD - 32
    local used = 0
    local inner = WIDTH - 2 * PAD
    for _, it in ipairs(d.items) do
        used = used + 1
        local r = f.rows[used]
        if not r then
            r = NewRow(f)
            f.rows[used] = r
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
        r:SetWidth(inner)
        r.hl:Hide()
        r.sub:Hide()
        for _, ch in ipairs(r.chips) do ch:Hide() end
        r.text:ClearAllPoints()
        if it.kind == "header" then
            -- the raid section: a small caption with a divider
            r:SetHeight(16)
            r.icon:Hide()
            r.text:SetFontObject("GameFontNormalSmall")
            r.text:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -3)
            r.text:SetText(it.text)
            r.status:SetText("")
            r.hl:SetColorTexture(1, 1, 1, 0.08)
            r.hl:ClearAllPoints()
            r.hl:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 1)
            r.hl:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, 1)
            r.hl:SetHeight(1)
            r.hl:Show()
            y = y - 18
        else
            r:SetHeight(ROW_H)
            r.hl:ClearAllPoints()
            r.hl:SetAllPoints()
            if it.icon then
                MapUI():SetIcon(r.icon, it.icon)
                r.icon:Show()
                r.text:SetPoint("TOPLEFT", r, "TOPLEFT", 22, -3)
            else
                r.icon:Hide()
                r.text:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -3)
            end
            r.text:SetFontObject(it.overview and "GameFontHighlightSmall" or "GameFontHighlight")
            r.text:SetPoint("RIGHT", r.status, "LEFT", -6, 0)
            r.text:SetWordWrap(false)
            r.text:SetText(it.text)
            r.status:SetText(it.status or "")
            local room = inner - (it.icon and 22 or 0) - (r.status:GetStringWidth() or 0) - 8
            local wraps = (r.text:GetStringWidth() or 0) > room
            if it.alert then
                r.hl:SetColorTexture(0.9, 0.15, 0.1, 0.25)
                r.hl:Show()
            elseif it.myTurn then
                r.hl:SetColorTexture(0.2, 0.9, 0.3, 0.12)
                r.hl:Show()
            end
            local h = ROW_H
            if it.kind == "job" and it.sub then
                r.sub:ClearAllPoints()
                r.sub:SetPoint("TOPLEFT", r, "TOPLEFT", 22, -15)
                r.sub:SetText(it.sub)
                r.sub:Show()
                r.text:ClearAllPoints()
                r.text:SetPoint("TOPLEFT", r, "TOPLEFT", 22, 0)
                r.text:SetPoint("RIGHT", r.status, "LEFT", -6, 0)
                h = ROW_H + 8
            elseif it.detail and it.detail ~= "" then
                r.sub:ClearAllPoints()
                r.sub:SetPoint("TOPLEFT", r, "TOPLEFT", 22, -15)
                r.sub:SetPoint("RIGHT", r, "RIGHT", 0, 0)
                r.sub:SetText(it.detail)
                r.sub:Show()
                r.text:ClearAllPoints()
                r.text:SetPoint("TOPLEFT", r, "TOPLEFT", 22, 0)
                r.text:SetPoint("RIGHT", r.status, "LEFT", -6, 0)
                h = ROW_H + 8
            elseif it.kind == "rot" then
                -- the name chips under the rotation's name
                local x = 22
                for i, c in ipairs(it.chips) do
                    local ch = Chip(r, i)
                    local label = c.text
                    if c.cd and c.cd > 0 and not c.dead then label = label .. grey(" " .. floor(c.cd + 0.5)) end
                    if c.backup and i > 1 and not it.chips[i - 1].backup then x = x + 6 end
                    ch.fs:SetText(label)
                    local w = (ch.fs:GetStringWidth() or 30) + 12
                    if x + w > inner then break end
                    ch:SetWidth(w)
                    ch:ClearAllPoints()
                    ch:SetPoint("TOPLEFT", r, "TOPLEFT", x, -(ROW_H + 1))
                    if c.current then
                        ch.bg:SetColorTexture(1, 0.82, 0, it.alert and 0.55 or 0.3)
                    elseif c.backup then
                        ch.bg:SetColorTexture(0.6, 0.45, 1, 0.14)
                    else
                        ch.bg:SetColorTexture(1, 1, 1, 0.06)
                    end
                    ch:Show()
                    x = x + w + 4
                end
                h = ROW_H + CHIP_H + 4
            elseif wraps then
                r.text:SetWordWrap(true)
                h = ROW_H + 13
            end
            r:SetHeight(h)
            y = y - h - 2
        end
        r:Show()
    end
    for i = used + 1, #f.rows do f.rows[i]:Hide() end
    f:SetHeight(-y + PAD - 2)
end

function Reminder:Refresh()
    local d = self:Items()
    if not d then
        if frame and frame:IsShown() and not frame.fading then frame.fading = true end
        return
    end
    local f = frame or Create()
    f.data = d
    f.fading = nil
    f:SetAlpha(1)
    local h = f.header
    if d.portrait then
        MapUI():SetIcon(h.portrait, d.portrait)
        h.portrait:Show()
    else
        h.portrait:Hide()
    end
    h.fs:SetText(d.title)
    local tag = d.practice and "practice" or d.state
    local col = STATE_COLOR[tag] or STATE_COLOR.next
    h.tag.fs:SetText(tag:upper())
    h.tag:SetWidth((h.tag.fs:GetStringWidth() or 40) + 10)
    h.tag.bg:SetColorTexture(col[1], col[2], col[3], 0.35)
    Layout(f, d)
    local alert = false
    for _, it in ipairs(d.items) do
        if it.alert and not it.overview then alert = true end
    end
    if alert and not f.alert and PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
    f.alert = alert
    if not alert and f.SetBackdropBorderColor then f:SetBackdropBorderColor(unpack(ns.UI.HUD_BORDER)) end
    f:Show()
end

function Reminder:GetFrame() return frame end

function Reminder:OnInit()
    ns:On("STRATEGY_LIVE", function() Reminder:Refresh() end)
end
