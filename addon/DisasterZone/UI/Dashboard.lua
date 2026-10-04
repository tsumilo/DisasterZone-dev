if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Dashboard.lua", ...) then return end -- DisasterZone: UI/Dashboard.lua
-- The "Home" tab: the page the main window opens on. Only what needs attention now: a greeting and a strip of action
-- chips (unanswered raids, an empty BiS phase, a newer DisasterZone, the raid lock), the next raid with one-click sign-up
-- (a "raid in progress" view while a raid session runs) and the BiS picks that can drop there, a calendar of the
-- planned and logged raids (past, now and ahead), recent loot, and for the council / raid organizers a readiness
-- check of the next raid (else the later raids). Every card links to the tab that holds the details. Read-only
-- apart from the sign-up buttons.
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
local cal = {}      -- the calendar: y, m = the month shown, day = the picked day (yyyymmdd); nil = today's

local function UI() return ns.UI end
local function RP() return ns.RaidPlan end
local function Now() return GetServerTime() end
local function Me() return ns.Util.PlayerKey() end
local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end
local function grey(text) return "|cff808080" .. tostring(text) .. "|r" end
local function colorize(hex, text) return "|cff" .. hex .. tostring(text) .. "|r" end

local function hexRGB(hex)
    return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end
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

-- A logged raid in the Raids tab's Raid log (its members only: the GM, the council, the raid leaders list).
local function openLog(id)
    openTab("raids")
    if ns.RaidsUI and ns.RaidsUI.Select then ns.RaidsUI:Select(id) end
end

local function seesRaidLog()
    local G = ns.Guild
    return (isDemo() or (G and G.AmIRaidLogMember and G:AmIRaidLogMember())) and true or false
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

-- The raid card's BiS row: how many of my missing picks can drop in `raid` (an ItemDB raid), each item and its boss
-- in the tooltip, a click opens My BiS on the raid's phase. nil when none can (or no raid is known).
local function bisDropRow(raid)
    if not raid then return nil end
    local phase = guildPhase()
    local raidPhase = tonumber(raid.phase)
    if raidPhase and raidPhase > phase then phase = min(raidPhase, ns.MAX_PHASE or 5) end
    local drops = dropsIn(bisSummary(phase).missing, raid)
    if #drops == 0 then return nil end
    local tip = { "Your Phase " .. phase .. " BiS picks that can drop in " .. raid.name }
    for i, d in ipairs(drops) do
        if i > 15 then
            tip[#tip + 1] = grey("+" .. (#drops - 15) .. " more")
            break
        end
        tip[#tip + 1] = UI():ItemText(d.itemID) .. (d.which == "alt" and grey(" (alt)") or "")
            .. grey(" - " .. d.boss .. (d.via == "token" and " (token)" or ""))
    end
    tip[#tip + 1] = grey("Click to open My BiS")
    return { text = grey("Your BiS: ") .. plural(#drops, "pick") .. " can drop in " .. raid.name, tip = tip,
             onClick = function() openMyBiS(phase) end }
end

-- The highest DisasterZone version seen on a guild member in the last 14 days, when it is newer than mine.
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

-- rows: { { text, right, itemID, icon, tip, onClick, indent, tall } } (a string = a plain text row). tall: the
-- text may take two lines (a note), the row is twice as high.
function CardMethods:SetRows(rows, startY)
    local y = startY or -28
    local avail = floor((self:GetHeight() + y - (self.buttonsShown and 34 or 8)) / ROW_H)
    for _, d in ipairs(rows) do
        if type(d) == "table" and d.tall then avail = avail - 1 end
    end
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
            r:SetPoint("TOPLEFT", self, "TOPLEFT", 10 + indent, y)
            r:SetPoint("TOPRIGHT", self, "TOPRIGHT", -10, y)
            r:SetHeight(d.tall and 2 * ROW_H or ROW_H)
            r.left:SetWordWrap(d.tall and true or false)
            if r.left.SetMaxLines then r.left:SetMaxLines(d.tall and 2 or 1) end
            y = y - (d.tall and 2 or 1) * ROW_H
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
    self.rowsEndY = y
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
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(CHIP_H)
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()
    UI():AddEdges(c)
    local hl = c:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
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
        out[#out + 1] = { text = "Update DisasterZone (" .. newer .. ")", kind = "bad",
                          tip = { "A guild member runs DisasterZone " .. newer, "You run " .. tostring(ns.version) } }
    end
    local unread = ns.ChangelogUI and ns.ChangelogUI.GetUnread and ns.ChangelogUI:GetUnread()
    if unread then
        out[#out + 1] = { text = "What's new in " .. unread.version, kind = "info",
                          tip = { "DisasterZone " .. unread.version .. ": " .. (unread.title or ""), "Open the Changelog" },
                          onClick = function() ns.ChangelogUI:Open(unread.version) end }
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

-- "Good evening, Name" by the player's own clock, the name in its class colour.
local function greetingText()
    local hour = tonumber(date("%H")) or 12
    local part = (hour >= 5 and hour < 12) and "morning" or (hour >= 12 and hour < 18) and "afternoon" or "evening"
    local _, classFile = UnitClass("player")
    return "Good " .. part .. ", |c" .. ns.Util.ClassColorHex(classFile) .. (UnitName("player") or "") .. "|r"
end

-- The greeting always leads the strip; the chips follow it past a thin divider, else "All caught up" sits right.
local function layoutChips(chips)
    local list = chips.list or {}
    panel.greeting:SetText(UI():SafeText(greetingText()))
    local x = floor(4 + (panel.greeting:GetStringWidth() or 0) + 21)
    panel.greetSep:SetShown(#list > 0)
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
        c.bg:SetColorTexture(col[1] * 0.22, col[2] * 0.22, col[3] * 0.22, 0.9)
        UI():SetEdgeColor(c, col[1], col[2], col[3], 0.8)
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
    -- the invited members still to answer, as the Raids tab counts them: a player who answered with another of their
    -- characters has answered; declined and blacklisted players are not waited for
    local noAnswer = {}
    local inv = rp:GetInvited(v)
    if inv then
        for key in pairs(inv) do
            if not rp:HasAnswered(ups, key) then
                local block = rp:GetSignupBlock(v, key)
                if block ~= "declined" and block ~= "blacklist" then noAnswer[#noAnswer + 1] = key end
            end
        end
        tsort(noAnswer)
    end
    return ups, counts, roles, noAnswer
end

-- The character I answer the raid with: the one my answer is for (maybe another of mine), else the one logged in.
local function myChar(v)
    return RP():GetMySignupCharacter(v.id) or Me()
end

-- Why I can't answer the raid: a few words for the card, and the Raids tab's sentence for the tooltip; nil when I can.
local function blockText(v)
    if v.cancelled then return "cancelled", "This raid was cancelled." end
    local block = RP():GetSignupBlock(v, myChar(v))
    if block == "blacklist" then return "can't sign up", "You can't sign up for raids. Contact an officer."
    elseif block == "declined" then return "taken off this raid", "You were taken off this raid."
    elseif block == "lock" and RP():GetMyRequest(v.id) then
        return "request sent", "You asked to join; a raid leader will approve it on the Raids tab."
    elseif block == "lock" and RP():CanRequest(v, myChar(v)) then
        return "ask to join", "Locked to its teams: answer on the Raids tab to ask to join."
    elseif block == "lock" then return "private, not invited", "Private: ask a raid leader for an invite."
    elseif block == "level" then
        return ("level %d only"):format(v.ml or 0), ("This raid is for level %d characters."):format(v.ml or 0)
    end
    return nil
end

local function answer(v, st)
    local rp = RP()
    local spec
    local mine = rp:GetMySignup(v.id)
    local char = myChar(v)
    if not (mine and mine.sp) and not rp:GetLastSpec(char) and ns.Util.IsMe(char) then
        -- first sign-up ever: use my BiS list's spec, like the Raids tab does
        local label = ns.BiS and ns.BiS.GetSpec and ns.BiS:GetSpec() or ""
        local _, classFile = UnitClass("player")
        for i, sp in ipairs(ns.SPECS[classFile] or {}) do
            if sp.label == label then spec = i end
        end
    end
    local ok, err = rp:SignUp(v.id, st, spec, nil, char)
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
        rows[#rows + 1] = bisDropRow(currentItemRaid() or (planned and itemRaidFor(planned.i)))
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
        -- the roles that are there, and how many accepted without a spec (their role is not known)
        local rp2, known = {}, 0
        for _, role in ipairs(ROLE_ORDER) do
            if roles[role] > 0 then rp2[#rp2 + 1] = roles[role] .. ROLE_SHORT[role] end
            known = known + roles[role]
        end
        if counts.A > known then
            rp2[#rp2 + 1] = colorize("ff9933", (counts.A - known) .. " without a spec")
        end
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
    if v.no and v.no ~= "" then
        rows[#rows + 1] = { text = grey("\"" .. v.no .. "\""), tall = true, tip = { "Note", v.no } }
    end
    -- my BiS picks that can drop there, when the row fits above my answer and the buttons
    local bisRow = bisDropRow(itemRaidFor(v.i))
    if bisRow then
        local units = 2
        for _, r in ipairs(rows) do units = units + ((type(r) == "table" and r.tall) and 2 or 1) end
        if units <= floor((CARD_H + rowsY - 34) / ROW_H) then rows[#rows + 1] = bisRow end
    end
    -- my player's answer, also one given with another of my characters
    local mine = rp:GetMySignup(v.id)
    local blocked, why = blockText(v)
    if mine and STATUS[mine.st] then
        rows[#rows + 1] = "Your answer: " .. colorize(STATUS[mine.st].color, STATUS[mine.st].label)
    elseif blocked then
        rows[#rows + 1] = { text = "Your answer: " .. colorize("ff5555", blocked), tip = { "You can't answer", why } }
    else
        rows[#rows + 1] = "Your answer: " .. colorize("ff9933", "none yet")
    end
    local open = v.t >= Now() - CURRENT_FOR
    card.buttonsShown = open
    for i, st in ipairs(STATUS_ORDER) do
        local b = card.buttons[i]
        b:SetShown(open)
        b:SetEnabled(blocked == nil)
        b.occ = v
        -- my answer in its colour (as on the Raids tab's sign-up strip)
        if mine and mine.st == st then b:SetTint(hexRGB(STATUS[st].color)) else b:SetTint(nil) end
    end
    card:SetRows(rows, rowsY)
    -- the answer buttons right under "Your answer" (not at the card's bottom, with a gap above them)
    local first = card.buttons[1]
    first:ClearAllPoints()
    first:SetPoint("TOPLEFT", card, "TOPLEFT", 10, (card.rowsEndY or rowsY) - 6)
end

---------------------------------------------------------------------------
-- Calendar: a month (Monday first) with a dot per raid on its day, and the picked day's raids beside it. Planned
-- raids (the Raids tab keeps them 15 days after they start; weekly ones show every week ahead) and the raid log's
-- raids (kept a year; a member has the ones they were in). A raid opens in the Raids tab: planned ones in Upcoming,
-- logged ones in the Raid log for its members.
---------------------------------------------------------------------------

local CAL_W, CAL_H = 28, 25         -- a day cell
local CAL_X, CAL_TOP = 10, -44      -- the first week row (under the month and the weekday letters)
local AGENDA_X = 2 * CAL_X + 7 * CAL_W + 4
local AGENDA_ROW_H = 32
local CAL_BACK = 365 * DAY          -- the raid log keeps raids a year
local CAL_AHEAD = 180 * DAY         -- raids are planned at most 180 days ahead
local MAX_DOTS = 3
local WEEKDAYS = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }

local function dayKey(t) return tonumber(date("%Y%m%d", t)) end
-- Noon of a day (noon keeps DST shifts from moving the day); y-m-d may be out of range (time() normalises it).
local function noon(y, m, d) return time({ year = y, month = m, day = d, hour = 12, min = 0, sec = 0 }) end
local function midnight(y, m, d) return time({ year = y, month = m, day = d, hour = 0, min = 0, sec = 0 }) end
local function dayOf(t)
    local d = date("*t", t)
    return d.year, d.month, d.day
end
local function keyDate(key) return floor(key / 10000), floor(key / 100) % 100, key % 100 end

-- "Today · Sat 4 Oct", "Wednesday 8 Oct".
local function dayTitle(key)
    local y, m, d = keyDate(key)
    local t = noon(y, m, d)
    local short = date("%a ", t) .. d .. date(" %b", t)
    local today = dayKey(Now())
    if key == today then return "Today · " .. short end
    if key == dayKey(noon(dayOf(Now())) + DAY) then return "Tomorrow · " .. short end
    if key == dayKey(noon(dayOf(Now())) - DAY) then return "Yesterday · " .. short end
    return date("%A ", t) .. d .. date(" %b", t)
end

-- A logged raid still being recorded (an open record with activity in the last 2 hours; one left open by a crash
-- counts as ended at its last activity).
local function running(rec)
    return not rec.stop and Now() - (tonumber(rec.last) or rec.start) < 2 * HOUR
end

local function endOf(rec)
    return rec.stop or (running(rec) and Now()) or tonumber(rec.last) or rec.start
end

local function bossText(rec)
    local kills = #(rec.bosses or {})
    local RL = ns.RaidLog
    local total = RL and RL.GetBossTotal and RL:GetBossTotal(rec.instID)
    if total then return ("%d/%d bosses"):format(kills, total) end
    return kills == 1 and "1 boss" or (kills .. " bosses")
end

-- My answer to a planned raid: words, colour.
local function answerState(v)
    if v.cancelled then return "Cancelled", "808080" end
    local rp = RP()
    local mine = rp:GetMySignup(v.id)
    if mine and STATUS[mine.st] then return STATUS[mine.st].label, STATUS[mine.st].color end
    if v.t < Now() - CURRENT_FOR then return "No answer", "808080" end
    local blocked = blockText(v)
    if blocked then return blocked, "808080" end
    local inv = rp:GetInvited(v)
    if inv and inv[Me() or ""] then return "Answer needed", "ff9933" end
    return "Open", "ffffff"
end

-- An event's status words and dot colour: my answer for a raid to come, how a logged one went (grey once over).
local function eventState(ev)
    local rec, v = ev.rec, ev.v
    if rec then return running(rec) and "in progress" or bossText(rec), running(rec) and "33ff33" or "999999" end
    if v.cancelled or v.t >= Now() - CURRENT_FOR then return answerState(v) end
    return (answerState(v)), "999999"
end

-- The raids of [from, to] by day: { [yyyymmdd] = { { t, name, v = planned raid, rec = raid log record } } }, each
-- day by start time. A logged raid linked to a planned one on the calendar is one event.
local function calendarEvents(from, to)
    local byDay = {}
    local function add(ev)
        local k = dayKey(ev.t)
        byDay[k] = byDay[k] or {}
        byDay[k][#byDay[k] + 1] = ev
    end
    local RL, rp = ns.RaidLog, RP()
    local logs, linked = {}, {}
    for _, rec in ipairs(RL and RL.GetRaids and RL:GetRaids() or {}) do
        local t = tonumber(rec.start)
        if t and t >= from and t <= to then
            logs[#logs + 1] = rec
            if rec.pl then linked[rec.pl] = rec end
        end
    end
    local shown = {}
    for _, v in ipairs(rp and rp.GetRaids and rp:GetRaids(from, to, false, true) or {}) do
        shown[v.id] = true
        add({ t = v.t, v = v, rec = linked[v.id], name = rp:GetRaidName(v) })
    end
    for _, rec in ipairs(logs) do
        if not (rec.pl and shown[rec.pl]) then add({ t = rec.start, rec = rec, name = rec.zone or "Raid" }) end
    end
    for _, list in pairs(byDay) do
        tsort(list, function(a, b) return a.t < b.t end)
    end
    return byDay
end

-- Where an event leads: a logged raid to the Raid log (its members), else the planned raid; nil = nowhere.
local function eventClick(ev)
    if ev.rec and seesRaidLog() then return function() openLog(ev.rec.id) end end
    if ev.v then return function() openRaid(ev.v.id) end end
    return nil
end

-- The agenda row's tooltip: when, the sign-ups or how it went, my answer, my loot, where a click leads.
local function eventTip(ev)
    local v, rec = ev.v, ev.rec
    local tip = { ev.name }
    if v then
        local when = date("%A %d %B %H:%M", v.t)
        if v.t >= Now() - CURRENT_FOR and not v.cancelled then when = when .. " · " .. whenText(v.t) end
        tip[#tip + 1] = when
        local sub = { (v.sz or 25) .. "-player" }
        for _, id in ipairs(v.tm or {}) do
            local team = RP():GetTeam(id)
            if team then sub[#sub + 1] = team.name end
        end
        if v.weekly then sub[#sub + 1] = "weekly" end
        tip[#tip + 1] = grey(tconcat(sub, " · "))
        if v.cancelled then
            tip[#tip + 1] = colorize("ff5555", "Cancelled")
        else
            local _, counts = signupCounts(v)
            local parts = { colorize(STATUS.A.color, counts.A .. " accepted") }
            if counts.T > 0 then parts[#parts + 1] = colorize(STATUS.T.color, counts.T .. " tentative") end
            if counts.B > 0 then parts[#parts + 1] = colorize(STATUS.B.color, counts.B .. " bench") end
            tip[#tip + 1] = tconcat(parts, " · ")
            local label, color = answerState(v)
            tip[#tip + 1] = "Your answer: " .. colorize(color, label)
        end
        if v.no and v.no ~= "" then tip[#tip + 1] = grey("\"" .. v.no .. "\"") end
    elseif rec then
        tip[#tip + 1] = date("%A %d %B %H:%M", rec.start)
    end
    if rec then
        local took = duration(endOf(rec) - rec.start)
        tip[#tip + 1] = bossText(rec) .. " · " .. (running(rec) and ("running " .. took) or took)
        local mine = {}
        for _, e in ipairs(ns.RaidLog:GetAwards(rec)) do
            if e.w == Me() then mine[#mine + 1] = UI():ItemText(e.i) end
        end
        if #mine > 0 then
            tip[#tip + 1] = "Your loot:"
            for i, text in ipairs(mine) do
                if i > 8 then tip[#tip + 1] = grey("+" .. (#mine - 8) .. " more") break end
                tip[#tip + 1] = "  " .. text
            end
        end
    end
    if rec and seesRaidLog() then
        tip[#tip + 1] = grey("Click to open it in the Raid log")
    elseif v then
        tip[#tip + 1] = grey("Click to open it in the Raids tab")
    end
    return tip
end

-- The agenda row's two lines: the raid, then its time and status.
local function eventLines(ev)
    local label, color = eventState(ev)
    local when = date("%H:%M", ev.t)
    local name = ev.name
    if ev.v and ev.v.cancelled then name = grey(name) end
    local status = colorize(color, label)
    if ev.rec and not running(ev.rec) then
        status = grey(label .. " · " .. duration(endOf(ev.rec) - ev.rec.start))
    end
    return name, grey(when .. " · ") .. status
end

local function newAgendaRow(card)
    local r = CreateFrame("Button", nil, card)
    r:SetHeight(AGENDA_ROW_H - 2)
    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetWidth(3)
    r.bar:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -3)
    r.bar:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 3)
    r.l1 = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.l1:SetPoint("TOPLEFT", r, "TOPLEFT", 9, -3)
    r.l1:SetPoint("TOPRIGHT", r, "TOPRIGHT", -2, -3)
    r.l1:SetJustifyH("LEFT")
    r.l2 = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.l2:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 9, 4)
    r.l2:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -2, 4)
    r.l2:SetJustifyH("LEFT")
    r.l2:SetWordWrap(false)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.08)
    r:SetScript("OnEnter", Row_OnEnter)
    r:SetScript("OnLeave", Row_OnLeave)
    r:SetScript("OnClick", Row_OnClick)
    return r
end

-- The picked day's raids: { { l1, l2, plain, color, tip, onClick } }; a raid name too long for one line takes two,
-- and when the rest doesn't fit, the last row says how many more there are.
local function setAgenda(card, items)
    local width = card:GetWidth() or 0
    if width < 300 then width = 388 end
    local textW = width - AGENDA_X - 8 - 11
    local tallH = AGENDA_ROW_H - 2 + 11
    local y, bottom = -30, -(CARD_H - 4)
    local used = 0
    -- the row's texts; returns its height
    local function fill(r, d)
        r.l1:SetWordWrap(false)
        r.l1:SetText(UI():SafeText(d.l1 or ""))
        local tall = (r.l1:GetStringWidth() or 0) > textW
        r.l1:SetWordWrap(tall)
        if r.l1.SetMaxLines then r.l1:SetMaxLines(tall and 2 or 1) end
        r.l2:SetText(UI():SafeText(d.l2 or ""))
        return tall and tallH or (AGENDA_ROW_H - 2)
    end
    for i, d in ipairs(items) do
        local r = card.agenda[i]
        if not r then
            r = newAgendaRow(card)
            card.agenda[i] = r
        end
        local h = fill(r, d)
        local rest = #items - i
        if rest > 0 and y - h - 2 - tallH < bottom then
            -- no room for another row after this one: this one says what else the day has
            local names = { "More that day" }
            for j = i, #items do names[#names + 1] = items[j].plain or "" end
            d = { l1 = grey("+" .. (rest + 1) .. " more"), tip = names }
            h = fill(r, d)
        end
        r:SetHeight(h)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", card, "TOPLEFT", AGENDA_X, y)
        r:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, y)
        r.bar:SetShown(d.color ~= nil)
        if d.color then r.bar:SetColorTexture(hexRGB(d.color)) end
        r.tip, r.onClick = d.tip, d.onClick
        r:EnableMouse((d.tip or d.onClick) and true or false)
        r:Show()
        y = y - h - 2
        used = i
        if d ~= items[i] then break end
    end
    for j = used + 1, #card.agenda do
        local r = card.agenda[j]
        r:Hide()
        r.tip, r.onClick = nil, nil
    end
end

local function showDay(key)
    cal.day = key
    cal.y, cal.m = floor(key / 10000), floor(key / 100) % 100
    Dashboard:Refresh()
end

local function refreshCalendarCard(card, ctx)
    local now = Now()
    local today = dayKey(now)
    local ty, tm = dayOf(now)
    local y, m = cal.y or ty, cal.m or tm
    local picked = cal.day or today
    card:SetTitle(date("%B %Y", noon(y, m, 1)))
    -- the 6 weeks around the month, Monday first
    local lead = (date("*t", noon(y, m, 1)).wday + 5) % 7
    local from = midnight(y, m, 1 - lead)
    local to = midnight(y, m, 1 - lead + 42) - 1
    local byDay = calendarEvents(from, to)
    for i, c in ipairs(card.cells) do
        local cy, cm, cd = dayOf(noon(y, m, i - lead))
        local key = cy * 10000 + cm * 100 + cd
        c.key = key
        c.num:SetText(cd)
        local inMonth = cm == m
        local shade = inMonth and 1 or 0.4
        c.num:SetTextColor(shade, shade, shade)
        c.sel:SetShown(key == picked)
        UI():SetEdgeColor(c, 1, 0.82, 0, key == today and 0.9 or 0)
        local list = byDay[key] or {}
        local n = min(#list, MAX_DOTS)
        for j, dot in ipairs(c.dots) do
            if j <= n then
                local _, color = eventState(list[j])
                local r, g, b = hexRGB(color)
                dot:SetColorTexture(r, g, b, inMonth and 1 or 0.5)
                dot:ClearAllPoints()
                dot:SetPoint("BOTTOM", c, "BOTTOM", (j - (n + 1) / 2) * 6, 3)
                dot:Show()
            else
                dot:Hide()
            end
        end
        c.events = list
    end
    -- the arrows stop where there is nothing to show: a year back, 180 days ahead
    card.prevMonth:SetEnabled(midnight(y, m, 1) - 1 >= now - CAL_BACK)
    card.nextMonth:SetEnabled(midnight(y, m + 1, 1) <= now + CAL_AHEAD)
    card.todayBtn:SetShown(picked ~= today or y ~= ty or m ~= tm)
    -- the picked day
    card.dayTitle:SetText(dayTitle(picked))
    local items = {}
    for _, ev in ipairs(byDay[picked] or {}) do
        local l1, l2 = eventLines(ev)
        local _, color = eventState(ev)
        items[#items + 1] = { l1 = l1, l2 = l2, plain = date("%H:%M ", ev.t) .. ev.name, color = color,
                              tip = eventTip(ev), onClick = eventClick(ev) }
    end
    if #items == 0 then
        local py, pm, pd = keyDate(picked)
        local dayEnd = midnight(py, pm, pd + 1)
        items[1] = { l1 = grey(picked < today and "No raids that day." or "Nothing planned.") }
        for _, v in ipairs(ctx.raids) do
            if v.t >= dayEnd then
                local key = dayKey(v.t)
                items[2] = { l1 = grey("Next: ") .. RP():GetRaidName(v),
                             l2 = grey(date("%a ", v.t) .. tonumber(date("%d", v.t)) .. date(" %b %H:%M", v.t)),
                             tip = { "Next raid", RP():GetRaidName(v), date("%A %d %B %H:%M", v.t) .. " · " .. whenText(v.t),
                                     grey("Click to show that day") },
                             onClick = function() showDay(key) end }
                break
            end
        end
    end
    setAgenda(card, items)
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
    -- only what needs attention; one "all set" line when nothing does
    local rows = {}
    local function line(list, badText, tipTitle)
        if #list == 0 then return end
        local names = {}
        for i, key in ipairs(list) do
            if i > 15 then names[#names + 1] = "..." break end
            names[#names + 1] = shortName(key)
        end
        rows[#rows + 1] = { text = colorize("ff9933", badText:format(#list)), tip = { tipTitle, tconcat(names, ", ") } }
    end
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
        line(empty, "%d coming without a Phase " .. ctx.phase .. " list", "No BiS picks for Phase " .. ctx.phase)
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
    line(noAddon, "%d coming, DisasterZone never seen", "DisasterZone not seen on")
    line(oldAddon, "%d coming on an older DisasterZone", "Older than your " .. tostring(ns.version))
    if rp:GetInvited(v) then
        line(noAnswer, "%d invited, no response", "No response yet")
    end
    local flags = ns.Store and ns.Store.GetLockFlags and ns.Store:GetLockFlags() or {}
    local flagged = {}
    for key in pairs(flags) do flagged[#flagged + 1] = key end
    tsort(flagged)
    if #flagged > 0 then
        line(flagged, "%d BiS edits during the lock", "Changed their list while locked")
    end
    local size = v.sz or 25
    if counts.A < size then
        rows[#rows + 1] = colorize("ff9933", ("%d of %d spots filled"):format(counts.A, size))
    end
    if #rows == 0 then
        rows[1] = colorize("33ff33", "All set: " .. plural(#coming, "player") .. " coming, nothing missing")
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
                local block = rp:GetSignupBlock(v)
                right = (block == "blacklist" and grey("blocked")) or (block == "declined" and grey("declined"))
                    or (rp:GetMyRequest(v.id) and colorize("ffd100", "requested"))
                    or (block == "lock" and rp:CanRequest(v) and grey("ask to join"))
                    or ((inv and inv[Me() or ""]) and colorize("ff9933", "no answer"))
                    or grey(block == nil and "open" or (block == "level" and ("level " .. v.ml .. " only") or "not invited"))
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
    panel.footerLeft:SetText("")   -- (the sync status is in the window's title bar)
    local online = 0
    for _, e in ipairs(Sync and Sync.GetVersions and Sync:GetVersions() or {}) do
        if e.online then online = online + 1 end
    end
    local G = ns.Guild
    local members = G and G.GetCouncilMembers and G:GetCouncilMembers() or {}
    local councilOnline = #(Sync and Sync.GetOnlineCouncilPeers and Sync:GetOnlineCouncilPeers() or {})
    if isCouncil() then councilOnline = councilOnline + 1 end
    local parts = { plural(online, "player") .. " online with DisasterZone" }
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
    -- The phase that matters is the raid's (the one I stand in, else the next): a Phase 2 raid needs the Phase 2 list
    -- even while the guild phase is still 1, and an older raid keeps the guild's current phase.
    local target = currentItemRaid() or (ctx.raid and itemRaidFor(ctx.raid.i))
    local raidPhase = target and tonumber(target.phase) or nil
    if raidPhase and raidPhase > ctx.phase then ctx.phase = min(raidPhase, ns.MAX_PHASE or 5) end
    ctx.bis = bisSummary(ctx.phase)
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
    refreshCalendarCard(panel.calCard, ctx)
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
    p.greeting = p.actions:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    p.greeting:SetPoint("LEFT", p.actions, "LEFT", 4, 0)
    p.greeting:SetWordWrap(false)
    p.greetSep = p.actions:CreateTexture(nil, "ARTWORK")
    p.greetSep:SetSize(1, 14)
    p.greetSep:SetPoint("LEFT", p.greeting, "RIGHT", 10, 0)
    p.greetSep:SetColorTexture(1, 1, 1, 0.15)
    p.allSet = p.actions:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.allSet:SetPoint("RIGHT", p.actions, "RIGHT", -4, 0)
    p.allSet:SetText(UI():SafeText("|cff5fa05f\226\156\147|r All caught up"))
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

    local cc = createCard(p)
    p.calCard = cc
    cc:SetPoint("TOPLEFT", p, "TOP", 3, top)
    cc:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    cc.agenda = {}
    local function arrow(dir, delta)
        local b = CreateFrame("Button", nil, cc)
        b:SetSize(20, 20)
        b:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. dir .. "Page-Up")
        b:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. dir .. "Page-Down")
        b:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. dir .. "Page-Disabled")
        b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        b:SetScript("OnClick", function()
            local ty, tm = dayOf(Now())
            local t = date("*t", noon(cal.y or ty, (cal.m or tm) + delta, 1))
            cal.y, cal.m = t.year, t.month
            Dashboard:Refresh()
        end)
        b:SetScript("OnEnter", function(self)
            UI():SetTextTooltip(self, { delta < 0 and "Previous month" or "Next month" })
        end)
        b:SetScript("OnLeave", Row_OnLeave)
        return b
    end
    local gridRight = CAL_X + 7 * CAL_W
    cc.nextMonth = arrow("Next", 1)
    cc.nextMonth:SetPoint("TOPRIGHT", cc, "TOPLEFT", gridRight + 2, -5)
    cc.prevMonth = arrow("Prev", -1)
    cc.prevMonth:SetPoint("RIGHT", cc.nextMonth, "LEFT", 2, 0)
    cc.todayBtn = CreateFrame("Button", nil, cc)
    cc.todayBtn:SetSize(36, 16)
    cc.todayBtn:SetPoint("RIGHT", cc.prevMonth, "LEFT", -2, 0)
    cc.todayBtn.text = cc.todayBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cc.todayBtn.text:SetPoint("RIGHT", cc.todayBtn, "RIGHT", 0, 0)
    cc.todayBtn.text:SetText("Today")
    cc.todayBtn:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 1, 1) end)
    cc.todayBtn:SetScript("OnLeave", function(self) self.text:SetTextColor(1, 0.82, 0) end)
    cc.todayBtn:SetScript("OnClick", function()
        cal = {}
        Dashboard:Refresh()
    end)
    cc.title:SetPoint("RIGHT", cc.todayBtn, "LEFT", -4, 0)
    for i, letter in ipairs(WEEKDAYS) do
        local fs = cc:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", cc, "TOPLEFT", CAL_X + (i - 1) * CAL_W, -29)
        fs:SetWidth(CAL_W)
        fs:SetJustifyH("CENTER")
        fs:SetText(letter)
    end
    cc.cells = {}
    for i = 1, 42 do
        local c = CreateFrame("Button", nil, cc)
        c:SetSize(CAL_W - 2, CAL_H - 2)
        c:SetPoint("TOPLEFT", cc, "TOPLEFT", CAL_X + ((i - 1) % 7) * CAL_W + 1, CAL_TOP - floor((i - 1) / 7) * CAL_H)
        c.sel = c:CreateTexture(nil, "BACKGROUND")
        c.sel:SetAllPoints()
        c.sel:SetColorTexture(1, 0.82, 0, 0.22)
        UI():AddEdges(c)
        local hl = c:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.1)
        c.num = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.num:SetPoint("TOP", c, "TOP", 0, -3)
        c.dots = {}
        for j = 1, MAX_DOTS do
            local dot = c:CreateTexture(nil, "OVERLAY")
            dot:SetSize(4, 4)
            dot:Hide()
            c.dots[j] = dot
        end
        c:SetScript("OnClick", function(self) if self.key then showDay(self.key) end end)
        c:SetScript("OnEnter", function(self)
            if not (self.events and #self.events > 0) then return end
            local lines = { dayTitle(self.key) }
            for _, ev in ipairs(self.events) do
                local label, color = eventState(ev)
                lines[#lines + 1] = date("%H:%M ", ev.t) .. ev.name .. " · " .. colorize(color, label)
            end
            UI():SetTextTooltip(self, lines)
        end)
        c:SetScript("OnLeave", Row_OnLeave)
        cc.cells[i] = c
    end
    local sep = cc:CreateTexture(nil, "ARTWORK")
    sep:SetWidth(1)
    sep:SetPoint("TOPLEFT", cc, "TOPLEFT", AGENDA_X - 7, -8)
    sep:SetPoint("BOTTOMLEFT", cc, "BOTTOMLEFT", AGENDA_X - 7, 8)
    sep:SetColorTexture(1, 1, 1, 0.08)
    cc.dayTitle = cc:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cc.dayTitle:SetPoint("TOPLEFT", cc, "TOPLEFT", AGENDA_X, -9)
    cc.dayTitle:SetPoint("RIGHT", cc, "RIGHT", -10, 0)
    cc.dayTitle:SetJustifyH("LEFT")
    cc.dayTitle:SetWordWrap(false)

    local footerH = 18
    local function lowerCard(label, left)
        local c = createCard(p, label)
        if left then
            c:SetPoint("TOPLEFT", p.raidCard, "BOTTOMLEFT", 0, -6)
            c:SetPoint("RIGHT", p, "CENTER", -3, 0)
        else
            c:SetPoint("TOPLEFT", p.calCard, "BOTTOMLEFT", 0, -6)
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
        "GROUP_UPDATED", "ITEMINFO_READY", "DEMO_TOGGLED", "ROSTER_UPDATED", "RAIDLOG_CHANGED", "CHANGELOG_READ",
    }) do
        ns:On(msg, function() Dashboard:RequestRefresh() end)
    end
    ns:RegisterSlash("home", function() ns.MainFrame:Open("home") end, "open the Home dashboard")
end
