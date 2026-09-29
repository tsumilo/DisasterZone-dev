-- CDLoot: UI/Dashboard.lua
-- The "Home" tab: the page the main window opens on. Only what needs attention now: a strip of action chips
-- (unanswered raids, an empty BiS phase, a newer CDLoot, the raid lock), the next raid with one-click sign-up
-- (a "raid in progress" view while a raid session runs), BiS progress with the picks that can drop in that raid,
-- recent loot, and for the council / raid organizers a readiness check of the next raid (else the later raids).
-- Every card links to the tab that holds the details. Read-only apart from the sign-up buttons.
local addonName, ns = ...

local Dashboard = ns:NewModule("Dashboard")

local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local HOUR, DAY = 3600, 86400
local CURRENT_FOR = 6 * HOUR       -- a raid counts as "next" until this long after it started (Raids tab: same)
local ROW_H = 17
local CARD_H = 232
local CHIP_H = 22
local MAX_CHIPS = 4
local TICK = 30                     -- seconds between countdown refreshes while the tab is shown

local STATUS = {
    A = { label = "Accepted", button = "Accept", color = "33ff33" },
    T = { label = "Tentative", button = "Tentative", color = "ffd100" },
    B = { label = "Bench", button = "Bench", color = "99bbff" },
    X = { label = "Absent", button = "Absent", color = "ff5555" },
}
local STATUS_ORDER = { "A", "T", "B", "X" }
local ROLE_SHORT = { tank = "T", healer = "H", melee = "M", ranged = "R" }
local ROLE_ORDER = { "tank", "healer", "melee", "ranged" }

local SHORT_NAME = { kara = "Kara", gruul = "Gruul", mag = "Mag", ssc = "SSC", tk = "TK", hyjal = "Hyjal", bt = "BT",
                     za = "ZA", swp = "SWP" }
local MAX_PILLS = 4
local PILL_ICON = {
    A = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12|t",
    T = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:12|t",
    X = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:12|t",
}

local panel
local pickedOcc     -- the raid picked among several on the same day (nil = the soonest)

local function UI() return ns.UI end
local function RP() return ns.RaidPlan end
local function Now() return GetServerTime() end
local function Me() return ns.Util.PlayerKey() end
local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end
local function grey(text) return "|cff808080" .. tostring(text) .. "|r" end
local function colorize(hex, text) return "|cff" .. hex .. tostring(text) .. "|r" end
local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

local function isCouncil()
    local G = ns.Guild
    return (G and G.AmICouncil and G:AmICouncil()) and true or false
end

local function isDemo()
    return (ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()) and true or false
end

-- Raid organizers (GM, raid leaders) and group editors see the readiness card too, without the BiS-list line.
local function canSeeReadiness()
    if isCouncil() then return true end
    local rp = RP()
    return rp and ((rp.CanOrganize and rp:CanOrganize()) or (rp.CanEditGroups and rp:CanEditGroups())) or false
end

-- "2d 4h", "3h 10m", "12m".
local function duration(sec)
    sec = max(0, floor(sec))
    if sec >= DAY then
        local d, h = floor(sec / DAY), floor((sec % DAY) / HOUR)
        return h > 0 and (d .. "d " .. h .. "h") or (d .. "d")
    end
    if sec >= HOUR then
        local h, m = floor(sec / HOUR), floor((sec % HOUR) / 60)
        return m > 0 and (h .. "h " .. m .. "m") or (h .. "h")
    end
    return max(1, floor(sec / 60)) .. "m"
end

local function whenText(t)
    local diff = t - Now()
    if diff > 60 then return "in " .. duration(diff) end
    if diff > -60 then return "starting now" end
    return "started " .. duration(-diff) .. " ago"
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------

local function openTab(key)
    if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open(key) end
end

local function openRaid(occId)
    openTab("raids")
    if ns.RaidsUI and ns.RaidsUI.SetView then ns.RaidsUI:SetView("upcoming") end
    if occId and ns.RaidPlanUI and ns.RaidPlanUI.SelectRaid then ns.RaidPlanUI:SelectRaid(occId) end
end

local function openMyBiS(phase)
    openTab("mybis")
    if phase and ns.MyBiS and ns.MyBiS.SetPhase then ns.MyBiS:SetPhase(phase, true) end
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

-- The next raid (the soonest one not cancelled that started at most 6 hours ago), or nil.
local function nextRaids()
    local out = {}
    local rp = RP()
    if not (rp and rp.GetRaids) then return out end
    local now = Now()
    for _, v in ipairs(rp:GetRaids(now - CURRENT_FOR)) do
        if not v.cancelled then out[#out + 1] = v end
    end
    return out
end

-- The planned instance of a raid view -> ItemDB raid (by map id), or nil.
local function itemRaidFor(instKey)
    local rp, ItemDB = RP(), ns.ItemDB
    local inst = rp and rp.GetInstance and rp:GetInstance(instKey)
    if not (inst and inst.instID and ItemDB) then return nil end
    for _, raid in ipairs(ItemDB:GetRaids()) do
        if raid.instanceID == inst.instID then return raid end
    end
    return nil
end

-- The ItemDB raid I am standing in (raid instances only), or nil.
local function currentItemRaid()
    if not (IsInInstance and GetInstanceInfo and ns.ItemDB) then return nil end
    local inInstance, kind = IsInInstance()
    if not inInstance or kind ~= "raid" then return nil end
    local instID = select(8, GetInstanceInfo())
    instID = tonumber(instID)
    for _, raid in ipairs(ns.ItemDB:GetRaids()) do
        if raid.instanceID == instID then return raid end
    end
    return nil
end

local function guildPhase()
    local G = ns.Guild
    return G and G.GetGuildPhase and G:GetGuildPhase() or 1
end

-- My main-spec picks of a phase: counts plus the unobtained picks (main and alt) of enabled slots.
local function bisSummary(phase)
    local BiS = ns.BiS
    local s = { filled = 0, obtained = 0, total = ns.NUM_SLOTS or 17, missing = {} }
    if not BiS then return s end
    local disabled = 0
    for sid = 1, ns.NUM_SLOTS or 17 do
        if BiS:IsSlotDisabled(phase, sid) then disabled = disabled + 1 end
    end
    s.total = s.total - disabled
    for _, p in ipairs(BiS:GetPhaseItems(phase)) do
        if not p.disabled then
            local have = BiS:IsObtained(p.itemID)
            if p.which == "main" then
                s.filled = s.filled + 1
                if have then s.obtained = s.obtained + 1 end
            end
            if not have then s.missing[#s.missing + 1] = p end
        end
    end
    return s
end

-- Missing picks that drop in `raid`: { itemID, which, boss, bossIndex, via }, main picks first, then boss order.
local function dropsIn(missing, raid)
    local out, seen = {}, {}
    local ItemDB = ns.ItemDB
    if not (raid and ItemDB) then return out end
    local order = {}
    for i, boss in ipairs(raid.bosses or {}) do order[boss] = i end
    for _, p in ipairs(missing) do
        if not seen[p.itemID] then
            for _, src in ipairs(ItemDB:GetSources(p.itemID, "raids")) do
                local ref = src.ref
                if ref and ref.raid == raid and ref.boss then
                    seen[p.itemID] = true
                    out[#out + 1] = { itemID = p.itemID, which = p.which, boss = ref.boss.isTrash and "Trash" or ref.boss.name,
                                      bossIndex = order[ref.boss] or 99, via = src.via }
                    break
                end
            end
        end
    end
    tsort(out, function(a, b)
        if a.which ~= b.which then return a.which == "main" end
        if a.bossIndex ~= b.bossIndex then return a.bossIndex < b.bossIndex end
        return a.itemID < b.itemID
    end)
    return out
end

-- Missing main picks grouped by where they come from: { { name, count } } most first.
local function missingBySource(missing)
    local counts, names = {}, {}
    local ItemDB = ns.ItemDB
    for _, p in ipairs(missing) do
        if p.which == "main" then
            local src = ItemDB and ItemDB:GetSources(p.itemID)[1]
            local key, name
            if src and src.kind == "raid" then key, name = "r:" .. src.groupKey, src.groupName
            elseif src and src.kind == "dungeon" then key, name = "dungeon", "5-man dungeons"
            elseif src and src.kind == "craft" then key, name = "craft", "Crafted"
            elseif src and src.kind == "rep" then key, name = "rep", "Reputation"
            elseif src and src.kind == "badge" then key, name = "badge", "Badge vendors"
            elseif src and src.kind == "pvp" then key, name = "pvp", "PvP"
            else key, name = "other", "Other"
            end
            counts[key] = (counts[key] or 0) + 1
            names[key] = name
        end
    end
    local out = {}
    for key, n in pairs(counts) do out[#out + 1] = { name = names[key], count = n } end
    tsort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    return out
end

-- The highest CDLoot version seen on a guild member in the last 14 days, when it is newer than mine.
local function newerVersion()
    local Sync = ns.Sync
    if not (Sync and Sync.GetVersions) then return nil end
    local best
    local cutoff = Now() - 14 * DAY
    for _, e in ipairs(Sync:GetVersions()) do
        if type(e.v) == "string" and (e.lastSeen or 0) >= cutoff and ns.Util.CompareVersions(e.v, ns.version) > 0
            and (not best or ns.Util.CompareVersions(e.v, best) > 0) then
            best = e.v
        end
    end
    return best
end

---------------------------------------------------------------------------
-- Widgets: cards with a pool of rows
---------------------------------------------------------------------------

local function Row_OnEnter(self)
    if self.itemID then
        UI():SetItemTooltip(self, self.itemID)
    elseif self.tip then
        UI():SetTextTooltip(self, self.tip)
    end
end

local function Row_OnLeave() GameTooltip:Hide() end

local function Row_OnClick(self)
    if self.itemID and UI():HandleModifiedItemClick(self.itemID) then return end
    if self.onClick then self.onClick() end
end

local function newRow(card)
    local r = CreateFrame("Button", nil, card)
    r:SetHeight(ROW_H)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(14, 14)
    r.icon:SetPoint("LEFT", r, "LEFT", 0, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.right:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    r.right:SetJustifyH("RIGHT")
    r.right:SetWordWrap(false)
    r.left = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.left:SetJustifyH("LEFT")
    r.left:SetWordWrap(false)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.08)
    r:SetScript("OnEnter", Row_OnEnter)
    r:SetScript("OnLeave", Row_OnLeave)
    r:SetScript("OnClick", Row_OnClick)
    return r
end

local CardMethods = {}

-- rows: { { text, right, itemID, icon, tip, onClick, indent } } (a string = a plain text row).
function CardMethods:SetRows(rows, startY)
    local y = startY or -28
    local avail = floor((self:GetHeight() + y - (self.buttonsShown and 34 or 8)) / ROW_H)
    local n = #rows
    if n > avail and avail > 0 then
        local extra = n - avail + 1
        local shown = {}
        for i = 1, avail - 1 do shown[i] = rows[i] end
        local hidden = {}
        for i = avail, n do
            local r = rows[i]
            hidden[#hidden + 1] = type(r) == "table" and (r.plain or r.text) or r
        end
        shown[avail] = { text = grey("+" .. extra .. " more"), tip = hidden, onClick = self.onOpen }
        rows = shown
        n = avail
    end
    for i = 1, max(n, #self.rows) do
        local d = rows[i]
        local r = self.rows[i]
        if d then
            if not r then
                r = newRow(self)
                self.rows[i] = r
            end
            if type(d) == "string" then d = { text = d } end
            local indent = d.indent or 0
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", self, "TOPLEFT", 10 + indent, y - (i - 1) * ROW_H)
            r:SetPoint("TOPRIGHT", self, "TOPRIGHT", -10, y - (i - 1) * ROW_H)
            local iconTex = d.icon
            if d.itemID and not iconTex and ns.ItemDB then iconTex = ns.ItemDB:GetIcon(d.itemID) end
            r.left:ClearAllPoints()
            if iconTex then
                r.icon:SetTexture(iconTex)
                r.icon:Show()
                r.left:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
            else
                r.icon:Hide()
                r.left:SetPoint("LEFT", r, "LEFT", 0, 0)
            end
            r.left:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
            r.left:SetText(UI():SafeText(d.text or ""))
            r.right:SetText(UI():SafeText(d.right or ""))
            r.itemID, r.tip, r.onClick = d.itemID, d.tip, d.onClick
            r:EnableMouse((d.itemID or d.tip or d.onClick) and true or false)
            r:Show()
        elseif r then
            r:Hide()
            r.itemID, r.tip, r.onClick = nil, nil, nil
        end
    end
end

function CardMethods:SetTitle(text, big)
    self.title:SetText(UI():SafeText(text or ""))
    self.big:SetText(UI():SafeText(big or ""))
    self.big:SetShown(big ~= nil and big ~= "")
end

local function createCard(parent, openLabel, onOpen)
    local card = UI():CreatePanel(parent)
    card:SetHeight(CARD_H)
    card.rows = {}
    card.onOpen = onOpen
    for k, fn in pairs(CardMethods) do card[k] = fn end
    card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    card.title:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -9)
    card.title:SetPoint("RIGHT", card, "RIGHT", -70, 0)
    card.title:SetJustifyH("LEFT")
    card.title:SetWordWrap(false)
    card.big = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    card.big:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -27)
    card.big:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    card.big:SetJustifyH("LEFT")
    card.big:SetWordWrap(false)
    if openLabel then
        local link = CreateFrame("Button", nil, card)
        link:SetSize(64, 16)
        link:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -8)
        link.text = link:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        link.text:SetPoint("RIGHT", link, "RIGHT", 0, 0)
        link.text:SetJustifyH("RIGHT")
        link.text:SetText(openLabel .. " >")
        link:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 1, 1) end)
        link:SetScript("OnLeave", function(self) self.text:SetTextColor(1, 0.82, 0) end)
        link:SetScript("OnClick", function() if card.onOpen then card.onOpen() end end)
        card.link = link
    end
    return card
end

---------------------------------------------------------------------------
-- Action chips
---------------------------------------------------------------------------

local CHIP_COLORS = {
    warn = { 1.00, 0.55, 0.20 },
    bad  = { 1.00, 0.30, 0.30 },
    info = { 0.41, 0.80, 0.94 },
    ok   = { 0.30, 0.90, 0.40 },
}

local function newChip(parent)
    local c = CreateFrame("Button", nil, parent, "BackdropTemplate")
    c:SetHeight(CHIP_H)
    c:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    c.text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.text:SetPoint("CENTER", c, "CENTER", 0, 0)
    c.text:SetWordWrap(false)
    c:SetScript("OnEnter", function(self)
        if self.tip then UI():SetTextTooltip(self, self.tip) end
    end)
    c:SetScript("OnLeave", Row_OnLeave)
    c:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
    return c
end

-- The actions that need me now: { text, kind = warn|bad|info, tip = { lines }, onClick }.
local function collectActions(ctx)
    local out = {}
    local rp = RP()
    for _, v in ipairs(rp and rp.GetUnanswered and rp:GetUnanswered(7) or {}) do
        out[#out + 1] = {
            text = "Sign up: " .. date("%a", v.t) .. " " .. rp:GetRaidName(v), kind = "warn",
            tip = { "You're invited and haven't answered", date("%a %d %b %H:%M", v.t) .. " · " .. whenText(v.t) },
            onClick = function() openRaid(v.id) end,
        }
    end
    local s = ctx.bis
    if s.filled == 0 then
        out[#out + 1] = { text = "Pick your Phase " .. ctx.phase .. " BiS", kind = "warn",
                          tip = { "Your Phase " .. ctx.phase .. " list is empty", "The council can't see what you need." },
                          onClick = function() openMyBiS(ctx.phase) end }
    elseif s.filled < s.total then
        local empty = s.total - s.filled
        out[#out + 1] = { text = "Phase " .. ctx.phase .. ": " .. plural(empty, "empty slot"), kind = "info",
                          tip = { "Fill or disable the empty slots of your Phase " .. ctx.phase .. " list" },
                          onClick = function() openMyBiS(ctx.phase) end }
    end
    local newer = newerVersion()
    if newer then
        out[#out + 1] = { text = "Update CDLoot (" .. newer .. ")", kind = "bad",
                          tip = { "A guild member runs CDLoot " .. newer, "You run " .. tostring(ns.version) } }
    end
    local BiS = ns.BiS
    local locked, info = false, nil
    if BiS and BiS.IsLocked then locked, info = BiS:IsLocked() end
    if locked then
        local by = type(info) == "table" and info.by and shortName(info.by) or nil
        out[#out + 1] = { text = UI():LockIcon(12) .. " BiS lists locked", kind = "info",
                          tip = { "BiS lists are locked for this raid" .. (by and (" by " .. by) or ""),
                                  "Changes wait until the raid leader unlocks them." } }
    end
    return out
end

local function layoutChips(chips)
    local list = chips.list or {}
    local x = 0
    local width = panel.actions:GetWidth()
    if not width or width < 50 then width = 760 end
    local shown = 0
    for i, a in ipairs(list) do
        local c = panel.chips[i]
        if not c then
            c = newChip(panel.actions)
            panel.chips[i] = c
        end
        c.text:SetText(UI():SafeText(a.text))
        local w = floor((c.text:GetStringWidth() or 80) + 22)
        local col = CHIP_COLORS[a.kind] or CHIP_COLORS.info
        c:SetBackdropColor(col[1] * 0.25, col[2] * 0.25, col[3] * 0.25, 0.85)
        c:SetBackdropBorderColor(col[1], col[2], col[3], 0.9)
        c.text:SetTextColor(min(1, col[1] + 0.3), min(1, col[2] + 0.3), min(1, col[3] + 0.3))
        c.tip, c.onClick = a.tip, a.onClick
        c:SetWidth(w)
        c:ClearAllPoints()
        if shown < MAX_CHIPS and x + w <= width then
            c:SetPoint("LEFT", panel.actions, "LEFT", x, 0)
            c:Show()
            x = x + w + 6
            shown = shown + 1
        else
            c:Hide()
        end
    end
    for i = #list + 1, #panel.chips do panel.chips[i]:Hide() end
    local hidden = #list - shown
    if hidden > 0 then
        local lines = {}
        for i = shown + 1, #list do lines[#lines + 1] = list[i].text end
        panel.moreChips:SetText("+" .. hidden .. " more")
        panel.moreChips.tip = lines
        panel.moreChips:ClearAllPoints()
        panel.moreChips:SetPoint("LEFT", panel.actions, "LEFT", x, 0)
        panel.moreChips:Show()
    else
        panel.moreChips:Hide()
    end
    panel.allSet:SetShown(#list == 0)
end

---------------------------------------------------------------------------
-- Cards
---------------------------------------------------------------------------

local function signupCounts(v)
    local rp = RP()
    local ups = rp:GetSignups(v.id)
    local counts = { A = 0, T = 0, B = 0, X = 0 }
    local roles = { tank = 0, healer = 0, melee = 0, ranged = 0 }
    local RC = ns.RaidComp
    for _, s in pairs(ups) do
        if counts[s.st] then counts[s.st] = counts[s.st] + 1 end
        if s.st == "A" and RC and RC.RoleOf and s.c and s.sp then
            local role = RC:RoleOf(s.c, s.sp)
            if roles[role] then roles[role] = roles[role] + 1 end
        end
    end
    local noAnswer = {}
    local inv = rp:GetInvited(v)
    if inv then
        for key in pairs(inv) do
            if not ups[key] then noAnswer[#noAnswer + 1] = key end
        end
        tsort(noAnswer)
    end
    return ups, counts, roles, noAnswer
end

local function answer(v, st)
    local rp = RP()
    local spec
    local mine = rp:GetMySignup(v.id)
    if not (mine and mine.sp) and not rp:GetLastSpec() then
        -- first sign-up ever: use my BiS list's spec, like the Raids tab does
        local label = ns.BiS and ns.BiS.GetSpec and ns.BiS:GetSpec() or ""
        local _, classFile = UnitClass("player")
        for i, sp in ipairs(ns.SPECS[classFile] or {}) do
            if sp.label == label then spec = i end
        end
    end
    local ok, err = rp:SignUp(v.id, st, spec)
    if not ok then ns:Print(err or "Could not save your answer.") end
end

-- "Kara", "SSC", a custom title (cut to 12 characters).
local function shortRaidName(v)
    if v.ti then return #v.ti > 12 and (v.ti:sub(1, 11) .. "...") or v.ti end
    return SHORT_NAME[v.i] or RP():GetRaidName(v)
end

-- My answer as a pill / row marker: a ready-check icon, "!" when I'm invited and haven't answered.
local function myMarker(v)
    local rp = RP()
    local mine = rp:GetMySignup(v.id)
    if mine then return PILL_ICON[mine.st] or colorize(STATUS.B.color, "B") end
    local inv = rp:GetInvited(v)
    if inv and inv[Me() or ""] then return colorize("ff9933", "!") end
    return nil
end

local function newPill(card)
    local b = CreateFrame("Button", nil, card, "BackdropTemplate")
    b:SetHeight(18)
    b:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.text:SetWordWrap(false)
    b:SetScript("OnEnter", function(self) if self.tip then UI():SetTextTooltip(self, self.tip) end end)
    b:SetScript("OnLeave", Row_OnLeave)
    b:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
    return b
end

-- The pill row of a day with several raids (hidden otherwise). Returns where the card's rows start.
local function refreshPills(card, ctx)
    local list = ctx.session and {} or ctx.dayRaids
    local show = #list > 1
    local x, y = 10, -48
    local n = 0
    for i, v in ipairs(show and list or {}) do
        local b = card.pills[i]
        if not b then
            b = newPill(card)
            card.pills[i] = b
        end
        if i > MAX_PILLS then
            b:Hide()
        else
            n = i
            local marker = myMarker(v)
            b.text:SetText(UI():SafeText((marker and (marker .. " ") or "") .. date("%H:%M", v.t) .. " " .. shortRaidName(v)))
            b:SetWidth(floor((b.text:GetStringWidth() or 60) + 16))
            local picked = v.id == ctx.raid.id
            if picked then
                b:SetBackdropColor(1, 0.5, 0, 0.35)
                b:SetBackdropBorderColor(1, 0.5, 0, 1)
            else
                b:SetBackdropColor(0, 0, 0, 0.5)
                b:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
            end
            b.tip = { RP():GetRaidName(v), date("%a %d %b %H:%M", v.t) .. " · " .. whenText(v.t),
                      picked and "Shown below" or "Click to show this raid" }
            b.onClick = function()
                pickedOcc = v.id
                Dashboard:Refresh()
            end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", card, "TOPLEFT", x, y)
            b:Show()
            x = x + b:GetWidth() + 4
        end
    end
    for i = (show and #list or 0) + 1, #card.pills do card.pills[i]:Hide() end
    if show and #list > MAX_PILLS then
        local more = card.pills[MAX_PILLS + 1]
        more.text:SetText("+" .. (#list - MAX_PILLS))
        more:SetWidth(30)
        more:SetBackdropColor(0, 0, 0, 0.5)
        more:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
        more.tip = { "More raids that day", "Open the Raids tab to see them all" }
        more.onClick = function() openRaid(nil) end
        more:ClearAllPoints()
        more:SetPoint("TOPLEFT", card, "TOPLEFT", x, y)
        more:Show()
    end
    return (show and n > 0) and -70 or -50
end

local function refreshRaidCard(card, ctx)
    local v = ctx.raid
    local session = ctx.session
    local rows = {}
    for _, b in ipairs(card.buttons) do b:Hide() end
    card.buttonsShown = false
    local rowsY = refreshPills(card, ctx)
    if session then
        local rp = RP()
        local planned = session.rp and rp and rp.GetRaid and rp:GetRaid(session.rp) or nil
        card.onOpen = function() openTab(isCouncil() and "loot" or "raids") end
        card.link.text:SetText((isCouncil() and "Loot log" or "Raids") .. " >")
        card:SetTitle("Raid in progress", planned and rp:GetRaidName(planned) or (GetInstanceInfo and GetInstanceInfo()) or "Raid")
        if session.at then rows[#rows + 1] = "Started " .. duration(Now() - session.at) .. " ago" end
        if session.by then rows[#rows + 1] = "Raid leader: " .. UI():ColoredName(session.by) end
        local L = ns.Ledger
        if L and L.GetVisibleEntries then
            local n, mine = 0, 0
            for _, e in ipairs(L:GetVisibleEntries()) do
                if e.rid == session.id then
                    n = n + 1
                    if e.w == Me() then mine = mine + 1 end
                end
            end
            rows[#rows + 1] = plural(n, "item") .. " awarded this raid" .. (mine > 0 and (" · " .. mine .. " to you") or "")
        end
        local Lock = UI().GetBiSLock and UI():GetBiSLock()
        if Lock then rows[#rows + 1] = UI():LockIcon(12) .. " BiS lists locked" end
        local today = date("%Y%m%d", Now())
        for _, o in ipairs(ctx.raids) do
            if o.t > Now() and date("%Y%m%d", o.t) == today and not (planned and planned.id == o.id) then
                local marker = myMarker(o)
                rows[#rows + 1] = { text = "Later today: " .. date("%H:%M", o.t) .. " " .. rp:GetRaidName(o)
                                        .. (marker and ("  " .. marker) or ""),
                                    onClick = function() openRaid(o.id) end }
            end
        end
        card:SetRows(rows, -50)
        return
    end
    card.link.text:SetText("Raids >")
    if not v then
        card.onOpen = function() openRaid(nil) end
        local planner = RP() and RP().CanOrganize and RP():CanOrganize()
        card:SetTitle("Next raid", "Nothing planned")
        card:SetRows({ grey(planner and "Plan one in the Raids tab." or "The Guild Master and the raid leaders plan raids."),
                       { text = colorize("ffd100", "Open the Raids tab"), onClick = function() openRaid(nil) end } }, -50)
        return
    end
    card.onOpen = function() openRaid(v.id) end
    local rp = RP()
    local title = "Next raid"
    if #ctx.dayRaids > 1 then
        local today = date("%Y%m%d", Now()) == date("%Y%m%d", v.t)
        title = (today and "Today" or date("%A", v.t)) .. " · " .. #ctx.dayRaids .. " raids"
    end
    card:SetTitle(title, rp:GetRaidName(v) .. " · " .. date("%a %H:%M", v.t))
    local sub = { whenText(v.t), date("%a %d %b", v.t), (v.sz or 25) .. "-player" }
    local teams = {}
    for _, id in ipairs(v.tm or {}) do
        local t = rp:GetTeam(id)
        if t then teams[#teams + 1] = t.name end
    end
    if #teams > 0 then sub[#sub + 1] = tconcat(teams, ", ") end
    rows[#rows + 1] = grey(tconcat(sub, " · "))
    local ups, counts, roles, noAnswer = signupCounts(v)
    local parts = { colorize(STATUS.A.color, counts.A .. " accepted") }
    if counts.T > 0 then parts[#parts + 1] = colorize(STATUS.T.color, counts.T .. " tentative") end
    if counts.B > 0 then parts[#parts + 1] = colorize(STATUS.B.color, counts.B .. " bench") end
    if counts.X > 0 then parts[#parts + 1] = colorize(STATUS.X.color, counts.X .. " absent") end
    rows[#rows + 1] = tconcat(parts, " · ")
    if counts.A > 0 then
        local rp2 = {}
        for _, role in ipairs(ROLE_ORDER) do rp2[#rp2 + 1] = roles[role] .. ROLE_SHORT[role] end
        rows[#rows + 1] = { text = grey("Roles: ") .. tconcat(rp2, "  "),
                            tip = { "Accepted by role", "T tank · H healer · M melee · R ranged" } }
    end
    if #noAnswer > 0 then
        local names = {}
        for i, key in ipairs(noAnswer) do
            if i > 15 then names[#names + 1] = "..." break end
            names[#names + 1] = shortName(key)
        end
        rows[#rows + 1] = { text = colorize("ff9933", #noAnswer .. " invited, no response"),
                            tip = { "No response yet", tconcat(names, ", ") } }
    end
    if v.no and v.no ~= "" then rows[#rows + 1] = grey("\"" .. v.no .. "\"") end
    local mine = ups[Me() or ""]
    if mine and STATUS[mine.st] then
        rows[#rows + 1] = "Your answer: " .. colorize(STATUS[mine.st].color, STATUS[mine.st].label)
    else
        rows[#rows + 1] = "Your answer: " .. colorize("ff9933", "none yet")
    end
    local open = v.t >= Now() - CURRENT_FOR
    card.buttonsShown = open
    for i, st in ipairs(STATUS_ORDER) do
        local b = card.buttons[i]
        b:SetShown(open)
        b.occ = v
        if mine and mine.st == st then b:LockHighlight() else b:UnlockHighlight() end
    end
    card:SetRows(rows, rowsY)
end

local function refreshBiSCard(card, ctx)
    local s, phase = ctx.bis, ctx.phase
    card.onOpen = function() openMyBiS(phase) end
    card:SetTitle("Your BiS · Phase " .. phase,
        s.filled == 0 and "No picks yet" or (s.obtained .. " / " .. s.total .. " obtained"))
    local pct = s.total > 0 and (s.obtained / s.total) or 0
    card.bar:SetShown(s.filled > 0)
    card.barFill:SetShown(s.filled > 0 and pct > 0)
    card.barFill:SetWidth(max(1, floor((card.bar:GetWidth() or 300) * pct)))
    local rows = {}
    if s.filled == 0 then
        rows[#rows + 1] = grey("Pick your best-in-slot items so the council knows what you need.")
        rows[#rows + 1] = { text = colorize("ffd100", "Open My BiS"), onClick = card.onOpen }
        card:SetRows(rows, -50)
        return
    end
    local raid, where = ctx.targetRaid, ctx.targetLabel
    if raid then
        local drops = dropsIn(s.missing, raid)
        if #drops == 0 then
            rows[#rows + 1] = grey("None of your missing picks drop in " .. raid.name .. ".")
        else
            rows[#rows + 1] = grey("Can drop " .. where .. " (" .. #drops .. ")")
            for _, d in ipairs(drops) do
                local text = UI():ItemText(d.itemID)
                if d.which == "alt" then text = text .. grey(" (alt)") end
                local right = d.boss
                if d.via == "token" then right = right .. grey(" · token") end
                rows[#rows + 1] = { text = text, right = right, itemID = d.itemID, indent = 4,
                                    plain = (ns.ItemDB:GetName(d.itemID) or "?") .. " - " .. d.boss }
            end
        end
    else
        local groups = missingBySource(s.missing)
        if #groups == 0 then
            rows[#rows + 1] = colorize("33ff33", "Everything on your list is obtained.")
        else
            rows[#rows + 1] = grey("Still needed, by source")
            for _, g in ipairs(groups) do
                rows[#rows + 1] = { text = g.name, right = plural(g.count, "item"), indent = 4 }
            end
        end
    end
    card:SetRows(rows, -58)
end

local REASON_SHORT = { bis = "BiS", alt = "Alt", up = "Upgrade", os = "Offspec", de = "DE", bank = "Bank" }

local function refreshLootCard(card, ctx)
    local L = ns.Ledger
    local council = isCouncil() or isDemo()
    card.onOpen = council and function() openTab("loot") end or nil
    card.link:SetShown(council)
    local entries = {}
    if L then
        if council then
            entries = L:GetVisibleEntries()
        elseif Me() then
            entries = L:GetEntries({ player = Me() })
        end
    end
    card:SetTitle(council and "Recent loot" or "Your loot")
    local rows = {}
    for i, e in ipairs(entries) do
        if i > 12 then break end
        local who = council and (UI():ColoredName(e.w) .. " ") or ""
        local reason = e.r and REASON_SHORT[e.r] or nil
        local right = (reason and (reason .. " · ") or "") .. ns.Util.FormatAgo(e.ts)
        local text = UI():ItemText(e.i)
        if council and e.w == Me() then who = colorize("33ff33", "You ") end
        rows[#rows + 1] = { text = who .. text, right = grey(right), itemID = e.i,
                            plain = shortName(e.w) .. ": " .. (ns.ItemDB:GetName(e.i) or "?") }
    end
    if #rows == 0 then
        rows[1] = grey(council and "No awards recorded yet." or "No loot awarded to you yet.")
    end
    card:SetRows(rows, -28)
end

-- Council / organizers: is the next raid ready?
local function refreshReadinessCard(card, ctx)
    local v = ctx.raid
    card.onOpen = function() openRaid(v and v.id) end
    local rp = RP()
    if not v then
        card:SetTitle("Raid readiness")
        card:SetRows({ grey("No raid planned.") }, -28)
        return
    end
    card:SetTitle("Raid readiness · " .. rp:GetRaidName(v) .. " " .. date("%a", v.t))
    local ups, counts, _, noAnswer = signupCounts(v)
    local coming = {}
    for key, s in pairs(ups) do
        if s.st == "A" or s.st == "T" then coming[#coming + 1] = key end
    end
    tsort(coming)
    local rows = {}
    local function line(list, okText, badText, tipTitle)
        if #list == 0 then
            rows[#rows + 1] = colorize("33ff33", okText)
            return
        end
        local names = {}
        for i, key in ipairs(list) do
            if i > 15 then names[#names + 1] = "..." break end
            names[#names + 1] = shortName(key)
        end
        rows[#rows + 1] = { text = colorize("ff9933", badText:format(#list)), tip = { tipTitle, tconcat(names, ", ") } }
    end
    rows[#rows + 1] = grey(plural(#coming, "player") .. " coming (accepted or tentative)")
    if isCouncil() then
        local Store, BiS = ns.Store, ns.BiS
        local empty = {}
        for _, key in ipairs(coming) do
            local filled
            if ns.Util.IsMe(key) then
                filled = ctx.bis.filled
            else
                local sum = Store and Store.Get and Store:Get(key) and Store:GetPlayerSummary(key, ctx.phase)
                filled = sum and sum.filled or 0
            end
            if filled == 0 then empty[#empty + 1] = key end
        end
        line(empty, "Everyone coming has a Phase " .. ctx.phase .. " list",
             "%d coming without a Phase " .. ctx.phase .. " list", "No BiS picks for Phase " .. ctx.phase)
    end
    local Sync = ns.Sync
    local noAddon, oldAddon = {}, {}
    for _, key in ipairs(coming) do
        local p = Sync and Sync.GetPeer and Sync:GetPeer(key)
        if not p or not p.v then
            noAddon[#noAddon + 1] = key
        elseif ns.Util.CompareVersions(p.v, ns.version) < 0 then
            oldAddon[#oldAddon + 1] = key
        end
    end
    line(noAddon, "Everyone coming has CDLoot", "%d coming, CDLoot never seen", "CDLoot not seen on")
    line(oldAddon, "Nobody coming is on an older CDLoot", "%d coming on an older CDLoot",
         "Older than your " .. tostring(ns.version))
    if rp:GetInvited(v) then
        line(noAnswer, "Every invited player answered", "%d invited, no response", "No response yet")
    end
    local flags = ns.Store and ns.Store.GetLockFlags and ns.Store:GetLockFlags() or {}
    local flagged = {}
    for key in pairs(flags) do flagged[#flagged + 1] = key end
    tsort(flagged)
    if #flagged > 0 then
        line(flagged, "", "%d BiS edits during the lock", "Changed their list while locked")
    end
    local size = v.sz or 25
    if counts.A < size then
        rows[#rows + 1] = grey(("%d of %d spots filled by accepted players"):format(counts.A, size))
    end
    card:SetRows(rows, -28)
end

-- Raiders: the raids after the next one.
local function refreshLaterCard(card, ctx)
    card.onOpen = function() openRaid(nil) end
    card:SetTitle("Later raids")
    local rows = {}
    local rp = RP()
    local onCard = {}
    for _, v in ipairs(ctx.dayRaids) do onCard[v.id] = true end
    if ctx.raid then onCard[ctx.raid.id] = true end
    for _, v in ipairs(ctx.raids) do
        if not onCard[v.id] then
            local mine = rp:GetMySignup(v.id)
            local right
            if mine and STATUS[mine.st] then
                right = colorize(STATUS[mine.st].color, STATUS[mine.st].label)
            else
                local inv = rp:GetInvited(v)
                right = (inv and inv[Me() or ""]) and colorize("ff9933", "no answer") or grey("open")
            end
            rows[#rows + 1] = { text = date("%a %d %b %H:%M", v.t) .. "  " .. rp:GetRaidName(v), right = right,
                                onClick = function() openRaid(v.id) end }
        end
    end
    if #rows == 0 then rows[1] = grey("Nothing else planned in the next two weeks.") end
    card:SetRows(rows, -28)
end

local function refreshFooter(ctx)
    local Sync = ns.Sync
    panel.footerLeft:SetText(UI():SafeText(Sync and Sync.GetStatusText and Sync:GetStatusText() or ""))
    local online = 0
    for _, e in ipairs(Sync and Sync.GetVersions and Sync:GetVersions() or {}) do
        if e.online then online = online + 1 end
    end
    local G = ns.Guild
    local members = G and G.GetCouncilMembers and G:GetCouncilMembers() or {}
    local councilOnline = #(Sync and Sync.GetOnlineCouncilPeers and Sync:GetOnlineCouncilPeers() or {})
    if isCouncil() then councilOnline = councilOnline + 1 end
    local parts = { plural(online, "player") .. " online with CDLoot" }
    if #members > 0 then parts[#parts + 1] = ("council online %d/%d"):format(min(councilOnline, #members), #members) end
    panel.footerRight:SetText(tconcat(parts, " · "))
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local function buildContext()
    local raids = nextRaids()
    local GR = ns.GroupRules
    local ctx = {
        phase = guildPhase(),
        raids = raids,
        raid = raids[1],
        session = GR and GR.GetSession and GR:GetSession() or nil,
        dayRaids = {},
    }
    -- Several raids on the day of the next one: the card shows pills to switch between them.
    if raids[1] then
        local day = date("%Y%m%d", raids[1].t)
        for _, v in ipairs(raids) do
            if date("%Y%m%d", v.t) == day then ctx.dayRaids[#ctx.dayRaids + 1] = v end
        end
        for _, v in ipairs(ctx.dayRaids) do
            if v.id == pickedOcc then ctx.raid = v end
        end
        if ctx.raid.id ~= pickedOcc then pickedOcc = nil end
    end
    ctx.bis = bisSummary(ctx.phase)
    local here = currentItemRaid()
    if here then
        ctx.targetRaid, ctx.targetLabel = here, "here"
    elseif ctx.raid then
        local raid = itemRaidFor(ctx.raid.i)
        if raid then
            ctx.targetRaid = raid
            local diff = ctx.raid.t - Now()
            ctx.targetLabel = diff < DAY and diff > -CURRENT_FOR and ("in " .. raid.name .. " tonight")
                or ("in " .. raid.name .. " " .. date("%A", ctx.raid.t))
        end
    end
    return ctx
end

function Dashboard:Refresh()
    if not panel or not panel:IsVisible() then
        if panel then panel.dirty = true end
        return
    end
    panel.dirty = false
    panel.elapsed = 0
    local ctx = buildContext()
    panel.chipData.list = collectActions(ctx)
    layoutChips(panel.chipData)
    refreshRaidCard(panel.raidCard, ctx)
    refreshBiSCard(panel.bisCard, ctx)
    refreshLootCard(panel.lootCard, ctx)
    local ready = canSeeReadiness()
    panel.readyCard:SetShown(ready)
    panel.laterCard:SetShown(not ready)
    if ready then refreshReadinessCard(panel.readyCard, ctx) else refreshLaterCard(panel.laterCard, ctx) end
    refreshFooter(ctx)
end

function Dashboard:RequestRefresh()
    if not panel then return end
    if not panel:IsVisible() then
        panel.dirty = true
        return
    end
    ns.Util.Debounce("dashboard-refresh", 0.15, function() Dashboard:Refresh() end)
end

function Dashboard:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    panel = p
    p.chips, p.chipData, p.elapsed, p.dirty = {}, {}, 0, true

    p.actions = CreateFrame("Frame", nil, p)
    p.actions:SetPoint("TOPLEFT", p, "TOPLEFT", 6, -6)
    p.actions:SetPoint("TOPRIGHT", p, "TOPRIGHT", -6, -6)
    p.actions:SetHeight(CHIP_H)
    p.allSet = p.actions:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.allSet:SetPoint("LEFT", p.actions, "LEFT", 4, 0)
    p.allSet:SetText(UI():SafeText("|cff33ff33\226\156\147|r You're all set: nothing needs you right now."))
    p.moreChips = CreateFrame("Button", nil, p.actions)
    p.moreChips:SetSize(60, CHIP_H)
    p.moreChips.text = p.moreChips:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.moreChips.text:SetPoint("LEFT", p.moreChips, "LEFT", 2, 0)
    p.moreChips.SetText = function(self, t) self.text:SetText(t) end
    p.moreChips:SetScript("OnEnter", function(self) UI():SetTextTooltip(self, self.tip or {}) end)
    p.moreChips:SetScript("OnLeave", Row_OnLeave)
    p.moreChips:Hide()

    local top = -(CHIP_H + 12)
    p.raidCard = createCard(p, "Raids")
    p.raidCard:SetPoint("TOPLEFT", p, "TOPLEFT", 4, top)
    p.raidCard:SetPoint("RIGHT", p, "CENTER", -3, 0)
    p.raidCard.buttons = {}
    p.raidCard.pills = {}
    local prev
    for i, st in ipairs(STATUS_ORDER) do
        local b = UI():CreateButton(p.raidCard, STATUS[st].button, 82, 22, function(self)
            if self.occ then answer(self.occ, st) end
        end)
        if prev then
            b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            b:SetPoint("BOTTOMLEFT", p.raidCard, "BOTTOMLEFT", 10, 9)
        end
        b:Hide()
        p.raidCard.buttons[i] = b
        prev = b
    end

    p.bisCard = createCard(p, "My BiS")
    p.bisCard:SetPoint("TOPLEFT", p, "TOP", 3, top)
    p.bisCard:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    local bar = CreateFrame("Frame", nil, p.bisCard)
    bar:SetHeight(6)
    bar:SetPoint("TOPLEFT", p.bisCard, "TOPLEFT", 10, -46)
    bar:SetPoint("TOPRIGHT", p.bisCard, "TOPRIGHT", -10, -46)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(1, 1, 1, 0.1)
    local fill = bar:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    fill:SetColorTexture(0.30, 0.90, 0.40, 0.9)
    p.bisCard.bar, p.bisCard.barFill = bar, fill

    local footerH = 18
    local function lowerCard(label, left)
        local c = createCard(p, label)
        if left then
            c:SetPoint("TOPLEFT", p.raidCard, "BOTTOMLEFT", 0, -6)
            c:SetPoint("RIGHT", p, "CENTER", -3, 0)
        else
            c:SetPoint("TOPLEFT", p.bisCard, "BOTTOMLEFT", 0, -6)
            c:SetPoint("RIGHT", p, "RIGHT", -4, 0)
        end
        c:SetPoint("BOTTOM", p, "BOTTOM", 0, footerH + 6)
        return c
    end
    p.lootCard = lowerCard("Loot log", true)
    p.readyCard = lowerCard("Raids", false)
    p.laterCard = lowerCard("Raids", false)

    p.footerLeft = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.footerLeft:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 8, 6)
    p.footerLeft:SetJustifyH("LEFT")
    p.footerRight = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.footerRight:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -8, 6)
    p.footerRight:SetJustifyH("RIGHT")

    -- card heights depend on the content frame; the lower row stretches, so its rows need a real height
    p:SetScript("OnSizeChanged", function() Dashboard:RequestRefresh() end)
    p:SetScript("OnShow", function(self)
        if self.dirty then Dashboard:RequestRefresh() end
    end)
    p:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = (self.elapsed or 0) + (elapsed or 0)
        if self.elapsed >= TICK then Dashboard:Refresh() end
    end)
    function p:OnPanelShown()
        Dashboard:Refresh()
    end
    return p
end

function Dashboard:GetPanel() return panel end

function Dashboard:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("home", "Home", 0.5, function(parent) return Dashboard:CreatePanel(parent) end)
    end
    for _, msg in ipairs({
        "RAIDPLAN_CHANGED", "MYLIST_CHANGED", "MYLIST_COMMITTED", "OWNED_UPDATED", "LEDGER_UPDATED", "LIST_UPDATED",
        "LISTS_RESET", "CONFIG_UPDATED", "PEERS_UPDATED", "SYNC_STATUS", "GROUP_RULES_CHANGED", "BIS_LOCK_CHANGED",
        "GROUP_UPDATED", "ITEMINFO_READY", "DEMO_TOGGLED", "ROSTER_UPDATED", "RAIDLOG_CHANGED",
    }) do
        ns:On(msg, function() Dashboard:RequestRefresh() end)
    end
    ns:RegisterSlash("home", function() ns.MainFrame:Open("home") end, "open the Home dashboard")
end
