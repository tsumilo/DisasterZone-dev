if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Dashboard.lua", ...) then return end -- DisasterZone: UI/Dashboard.lua
-- The "Home" tab: the page the main window opens on. Only what needs attention now, top to bottom:
--   the greeting and a strip of action chips (unanswered raids, an empty BiS phase, players asking to join my run or a
--     run that needs me, a newer DisasterZone, what's new, the BiS lock);
--   the raids of the coming week as a banner carousel with their loading screens, like the Raids board: the date, who
--     leads, the answers by role and my answer in its corner; under it the raid's note, my BiS picks that can drop
--     there and, for the council and the raid organizers, what isn't ready yet. It slides to the next raid every few
--     seconds (not while the mouse is on it); a strip of bars and two arrows pick one. While a raid session runs, the
--     raid in progress instead;
--   a month calendar of the planned and logged raids, the dungeon runs listed for later and the guild's own events
--     (the Events tab, purple dots), the picked day's events and the raids coming up beside it;
--   recent loot (the council: everyone's; a raider: their own).
-- Every block opens the tab with the details. Read-only apart from the answer buttons. The online count is in the
-- sync icon's tooltip (UI/MainFrame.lua).
local addonName, ns = ...

local Dashboard = ns:NewModule("Dashboard")

local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local HOUR, DAY = 3600, 86400
local CURRENT_FOR = 6 * HOUR       -- a raid counts as "next" until this long after it started (Raids tab: same)
local TICK = 30                     -- seconds between countdown refreshes while the tab is shown
local WEEK_DAYS = 7                 -- the banner flips through the raids of today and the next 6 days
local FLIP_EVERY = 8                -- seconds a raid stays on the banner before the next one slides in
local FLIP_TIME = 0.6               -- the slide from one raid to the next

-- One grid for the page (its content area is 790 x 548): PAD at the sides and the bottom, GAP between blocks.
local PAGE_H = 548
local PAD, GAP = 10, 8
local INNER_W = 790 - 2 * PAD                    -- 770
local HELLO_Y, HELLO_H = 6, 26
local BANNER_Y = HELLO_Y + HELLO_H + GAP         -- 40
local BANNER_H, FOOT_H = 164, 46                 -- the banner never changes height; its foot is part of it
local LOWER_Y = BANNER_Y + BANNER_H + GAP        -- 212
local LOWER_H = PAGE_H - LOWER_Y - PAD           -- 326: the calendar and the loot reach the page's bottom
local CAL_W = 470
local LOOT_W = INNER_W - CAL_W - GAP             -- 292
local HEAD_H = 28                                -- a box's title row
local IN = 12                                    -- the padding inside the banner
local DATE_W = 64                                -- the banner's date column; its texts start at DATE_W + 13
local CELL_W, CELL_H = 29, 44                    -- a calendar day (at most: the month's weeks share the height)
local GRID_X, GRID_Y = 10, HEAD_H + 8 + 16       -- the first week (under the weekday letters)
local RULE_X = GRID_X + 7 * CELL_W + 10          -- 223: the line between the month and the day's list
local AGENDA_X = RULE_X + 12                     -- 235
local DISC, DISC_Y = 24, 15                      -- today's / the picked day's disc, its centre under the cell's top
local DISC_TEX = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local THUMB_W, THUMB_H = 46, 32
local ROW_GAP = 6
local LOOT_ROW_H = 36
local CHIP_H = 22
local MAX_DOTS = 3
local CAL_BACK = 365 * DAY          -- the raid log keeps raids a year
local CAL_AHEAD = 180 * DAY         -- raids are planned at most 180 days ahead

local PANEL_BG = { 0.08, 0.08, 0.095, 0.9 }
local CARD_BG = { 0.10, 0.10, 0.12, 0.92 }
local EDGE = { 0.34, 0.34, 0.38, 0.5 }
local INK = { 0.035, 0.035, 0.043 }              -- the banner's shades

local STATUS = {
    A = { label = "Accepted", button = "Accept", color = "4fd36b" },
    T = { label = "Tentative", button = "Tentative", color = "ffd84a" },
    B = { label = "Bench", button = "Bench", color = "99bbff" },
    X = { label = "Absent", button = "Absent", color = "ff6b5e" },
}
local STATUS_ORDER = { "A", "T", "B", "X" }
-- the dots and the status words of the calendar
local C_NEED, C_OPEN, C_PAST, C_RUN, C_LOCK = "ff8c1a", "d8d8d8", "8a8a8e", "66b8ff", "8a8a90"
local C_EVENT = "b98cff"           -- the guild's own events (the Events tab)

local SHORT_NAME = { kara = "Kara", gruul = "Gruul", mag = "Mag", ssc = "SSC", tk = "TK", hyjal = "Hyjal", bt = "BT",
                     za = "ZA", swp = "SWP" }
local PILL_ICON = {
    A = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12|t",
    T = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:12|t",
    X = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:12|t",
}
-- my answer as the Raids board's pill shows it: fill r, g, b, edge alpha, edge r, g, b, text
local ANSWER_PILL = {
    A = { 0.16, 0.43, 0.22, 0.35, 0.35, 0.86, 0.47, "b7f5c3" }, T = { 0.47, 0.39, 0.08, 0.35, 1, 0.82, 0, "ffe680" },
    B = { 0.20, 0.27, 0.45, 0.35, 0.6, 0.73, 1, "c4d6ff" }, X = { 0.45, 0.10, 0.10, 0.35, 1, 0.33, 0.33, "ffb0b0" },
    R = { 0.47, 0.39, 0.08, 0.35, 1, 0.82, 0, "ffe680" },
}
local ANSWER_TEXT = { A = "Accepted", T = "Tentative", B = "Bench", X = "Absent", R = "Asked to join" }
local ANSWER_ICON = { A = "Interface\\RaidFrame\\ReadyCheck-Ready", T = "Interface\\RaidFrame\\ReadyCheck-Waiting",
                      X = "Interface\\RaidFrame\\ReadyCheck-NotReady" }
local HEROIC_ICON = "|TInterface\\LFGFrame\\UI-LFG-ICON-HEROIC:14:11:0:0:32:32:0:16:0:20|t"

local REASON = {
    bis = { "BiS", "ffd100" }, alt = { "Alt", "8fc8ff" }, up = { "Upgrade", "e0e0e0" }, os = { "Offspec", "c9a6ff" },
    de = { "Disenchanted", "9e9e9e" }, bank = { "Guild bank", "9e9e9e" },
}

local panel
local cal = {}      -- the calendar: y, m = the month shown, day = the picked day (yyyymmdd); nil = today's

local function UI() return ns.UI end
local function RP() return ns.RaidPlan end
local function DR() return ns.DungeonRuns end
local function EV() return ns.Events end
local function Now() return GetServerTime() end
local function Me() return ns.Util.PlayerKey() end
local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end
local function grey(text) return "|cff9e9e9e" .. tostring(text) .. "|r" end
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

-- Raid organizers (GM, raid leaders) and group editors see the readiness of the next raid too, without the BiS-list
-- line (that one is the council's).
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

local function dayKey(t) return tonumber(date("%Y%m%d", t)) end
-- Noon of a day (noon keeps DST shifts from moving the day); y-m-d may be out of range (time() normalises it).
local function noon(y, m, d) return time({ year = y, month = m, day = d, hour = 12, min = 0, sec = 0 }) end
local function midnight(y, m, d) return time({ year = y, month = m, day = d, hour = 0, min = 0, sec = 0 }) end
local function dayOf(t)
    local d = date("*t", t)
    return d.year, d.month, d.day
end
local function keyDate(key) return floor(key / 10000), floor(key / 100) % 100, key % 100 end
-- Calendar days from today to t (0 = today, 1 = tomorrow, -1 = yesterday).
local function daysAway(t)
    return floor((noon(dayOf(t)) - noon(dayOf(Now()))) / DAY + 0.5)
end

-- The banner's countdown: "in 3 days", "tomorrow", "in 3h 10m", "in 12 min", "started 20m ago".
local function countdown(t)
    local diff = t - Now()
    if diff <= -60 then return "started " .. duration(-diff) .. " ago" end
    if diff < 60 then return "starting now" end
    if diff < HOUR then return "in " .. floor(diff / 60) .. " min" end
    local days = daysAway(t)
    if days <= 0 then return "in " .. duration(diff) end
    if days == 1 then return "tomorrow" end
    return "in " .. days .. " days"
end

-- "Sun 11", the short day of an upcoming event.
local function shortDay(t) return date("%a ", t) .. tonumber(date("%d", t)) end

-- When a loot award was: "5m ago" / "3h ago" today, the weekday this week, else "12 Oct".
local function agoText(ts)
    ts = tonumber(ts) or 0
    local diff = Now() - ts
    if diff < DAY then return ns.Util.FormatAgo(ts) end
    if diff < 6 * DAY then return date("%a", ts) end
    return tonumber(date("%d", ts)) .. date(" %b", ts)
end

---------------------------------------------------------------------------
-- Small widgets
---------------------------------------------------------------------------

local function text(parent, size, font, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
    end
    return fs
end

local function setSize(fs, size)
    local path, _, flags = fs:GetFont()
    if path then fs:SetFont(path, size, flags) end
end

-- The width of a text on one line, whatever the width of its region.
local function strW(fs)
    return (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()) or fs:GetStringWidth() or 0
end

local function gradient(tex, orient, c, a1, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if tex.SetGradient and CreateColor then tex:SetGradient(orient, CreateColor(c[1], c[2], c[3], a1), CreateColor(c[1], c[2], c[3], a2)) end
end

-- A flat box: dark fill, 1px edges.
local function flatBox(f, bg, edge)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    bg = bg or PANEL_BG
    f.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    UI():AddEdges(f, "BORDER")
    edge = edge or EDGE
    UI():SetEdgeColor(f, edge[1], edge[2], edge[3], edge[4])
end

-- The atlas chevron (it points down) turned to point "left" or "right".
local function chevron(tex, dir)
    local c = UI():IconCoords(UI().ICON.chevron)
    local l, r, t, b = c[1], c[2], c[3], c[4]
    tex:SetTexture(UI().ICON_ATLAS)
    if dir == "left" then tex:SetTexCoord(l, b, r, b, l, t, r, t) else tex:SetTexCoord(r, t, l, t, r, b, l, b) end
end

local function hideTip() GameTooltip:Hide() end

local function showTip(owner, lines, anchor)
    if type(lines) == "function" then lines = lines() end
    if lines then UI():SetTextTooltip(owner, lines, anchor) end
end

-- A text link with a chevron ("Loot log >"): grey, gold on hover.
local function newLink(parent, label, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(18)
    b.fs = text(b, 11, "GameFontHighlightSmall")
    b.fs:SetPoint("LEFT", 0, 0)
    b.chev = b:CreateTexture(nil, "ARTWORK")
    b.chev:SetSize(9, 9)
    b.chev:SetPoint("LEFT", b.fs, "RIGHT", 3, 0)
    chevron(b.chev, "right")
    local function paint(self, on)
        local c = on and { 1, 0.82, 0 } or { 0.74, 0.74, 0.74 }
        self.fs:SetTextColor(c[1], c[2], c[3])
        self.chev:SetVertexColor(c[1], c[2], c[3])
    end
    function b:SetLabel(t)
        self.fs:SetText(t or "")
        self:SetWidth(floor(strW(self.fs) + (self.chev:IsShown() and 12 or 0)))
    end
    b:SetScript("OnEnter", function(self)
        paint(self, true)
        if self.tip then showTip(self, self.tip, "ANCHOR_TOP") end
    end)
    b:SetScript("OnLeave", function(self)
        paint(self, false)
        hideTip()
    end)
    b:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
    b.onClick = onClick
    b:SetLabel(label)
    paint(b, false)
    return b
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------

local function openTab(key)
    if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open(key) end
end

local function openRun(id)
    if ns.DungeonsUI and ns.DungeonsUI.Focus then ns.DungeonsUI:Focus(id) else openTab("dungeons") end
end

local function openEvent(occId)
    if ns.EventsUI and ns.EventsUI.OpenEvent then ns.EventsUI:OpenEvent(occId) else openTab("events") end
end

local function openRaid(occId)
    openTab("raids")
    if ns.RaidsUI and ns.RaidsUI.SetView then ns.RaidsUI:SetView("upcoming") end
    local PUI = ns.RaidPlanUI
    if not PUI then return end
    if occId and PUI.SelectRaid then
        PUI:SelectRaid(occId)
    elseif PUI.ShowBoard then
        PUI:ShowBoard()
    end
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

-- My answer to a raid, as the Raids board answers it (the character my answer is for, its spec).
local function answer(occId, st)
    local PUI = ns.RaidPlanUI
    if PUI and PUI.Answer then PUI:Answer(st, occId) end
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

-- The raids from now on (and the ones that started at most 6 hours ago), not cancelled, soonest first.
local function nextRaids()
    local out = {}
    local rp = RP()
    if not (rp and rp.GetRaids) then return out end
    for _, v in ipairs(rp:GetRaids(Now() - CURRENT_FOR)) do
        if not v.cancelled then out[#out + 1] = v end
    end
    return out
end

-- The planned instance key of a map id ("kara"), or nil.
local function instKeyOf(instID)
    instID = tonumber(instID)
    local rp = RP()
    if not (instID and rp and rp.GetInstances) then return nil end
    for _, inst in ipairs(rp:GetInstances()) do
        if inst.instID == instID then return inst.key end
    end
    return nil
end

-- The planned instance of a raid view -> ItemDB raid (by map id), or nil. A raid view (a table) -> the ItemDB raids
-- of all its instances, in the night's order (1.3.2: a raid can hold several, e.g. Gruul + Mag), with the highest
-- phase among them as list.phase (an empty list: none known).
local function itemRaidFor(instKey)
    local rp, ItemDB = RP(), ns.ItemDB
    if type(instKey) == "table" then
        local out = {}
        for _, key in ipairs(rp and rp.GetRaidInstances and rp:GetRaidInstances(instKey) or { instKey.i }) do
            local raid = itemRaidFor(key)
            if raid then
                out[#out + 1] = raid
                local ph = tonumber(raid.phase)
                if ph and ph > (out.phase or 0) then out.phase = ph end
            end
        end
        return out
    end
    local inst = rp and rp.GetInstance and rp:GetInstance(instKey)
    if not (inst and inst.instID and ItemDB) then return nil end
    for _, raid in ipairs(ItemDB:GetRaids()) do
        if raid.instanceID == inst.instID then return raid end
    end
    return nil
end

-- The map id of the raid instance I am standing in, or nil.
local function currentInstID()
    if not (IsInInstance and GetInstanceInfo) then return nil end
    local inInstance, kind = IsInInstance()
    if not inInstance or kind ~= "raid" then return nil end
    return tonumber((select(8, GetInstanceInfo())))
end

-- The ItemDB raid I am standing in (raid instances only), or nil.
local function currentItemRaid()
    local instID = currentInstID()
    if not (instID and ns.ItemDB) then return nil end
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

-- How many of my missing picks can drop in `raid` (an ItemDB raid, or a list of them: a night of several, itemRaidFor
-- of a view): { text, tip, onClick } for the banner's foot (each item and its boss in the tooltip, a click opens My
-- BiS on the raid's phase), or nil when none can.
local function bisDrops(raid)
    if not raid then return nil end
    local list = raid.bosses and { raid } or raid
    if #list == 0 then return nil end
    local phase = guildPhase()
    local raidPhase = 0
    for _, r in ipairs(list) do raidPhase = max(raidPhase, tonumber(r.phase) or 0) end
    if raidPhase > phase then phase = min(raidPhase, ns.MAX_PHASE or 5) end
    local missing = bisSummary(phase).missing
    local drops, names = {}, {}
    for _, r in ipairs(list) do
        names[#names + 1] = r.name
        for _, d in ipairs(dropsIn(missing, r)) do drops[#drops + 1] = d end
    end
    if #drops == 0 then return nil end
    local tip = { "Your Phase " .. phase .. " BiS picks that can drop in " .. tconcat(names, " or ") }
    for i, d in ipairs(drops) do
        if i > 15 then
            tip[#tip + 1] = grey("+" .. (#drops - 15) .. " more")
            break
        end
        tip[#tip + 1] = UI():ItemText(d.itemID) .. (d.which == "alt" and grey(" (alt)") or "")
            .. grey(" - " .. d.boss .. (d.via == "token" and " (token)" or ""))
    end
    tip[#tip + 1] = grey("Click to open My BiS")
    return { text = (#drops == 1 and "1 of your P%d picks can drop here" or (#drops .. " of your P%d picks can drop here"))
                        :format(phase),
             tip = tip, onClick = function() openMyBiS(phase) end }
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

-- The spec of a sign-up -> tank / healer / melee / ranged (casters count as ranged), nil without a spec.
local function roleOf(s)
    local specs = s and s.c and ns.SPECS and ns.SPECS[s.c]
    local spec = specs and s.sp and specs[s.sp]
    if not spec then return nil end
    return spec.role == "caster" and "ranged" or spec.role
end

-- A raid's answers: the sign-ups, counts by answer, the accepted by role (nospec = without a spec), and the invited
-- members still to answer, as the Raids tab counts them (a player who answered with another of their characters has
-- answered; declined and blacklisted players are not waited for).
local function signupCounts(v)
    local rp = RP()
    local ups = rp:GetSignups(v.id)
    local counts = { A = 0, T = 0, B = 0, X = 0 }
    local roles = { tank = 0, healer = 0, melee = 0, ranged = 0, nospec = 0 }
    for _, s in pairs(ups) do
        if counts[s.st] then counts[s.st] = counts[s.st] + 1 end
        if s.st == "A" then
            local role = roleOf(s) or "nospec"
            roles[role] = roles[role] + 1
        end
    end
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

-- My answer to a raid, as the Raids board shows it: kind ("A" | "T" | "B" | "X" | "R" asked to join | "N" no answer
-- yet), the block reason, whether I can answer, whether I can ask to join, my sign-up.
local function myState(v)
    local rp = RP()
    local char = myChar(v)
    local mine = rp:GetMySignup(v.id)
    local block = rp:GetSignupBlock(v, char)
    local canAsk = block == "lock" and rp:CanRequest(v, char)
    if mine then return mine.st, block, true, canAsk, mine end
    if canAsk and rp:GetMyRequest(v.id) then return "R", block, true, canAsk, nil end
    return "N", block, block == nil or canAsk, canAsk, nil
end

-- Why I can't answer: a few words (the banner), a sentence (its tooltip); nil when I can.
local function blockWords(v, block)
    if block == "blacklist" then return "Can't sign up", "You can't sign up for raids. Contact an officer." end
    if block == "declined" then return "Taken off this raid", "You were taken off this raid." end
    if block == "level" then
        return ("Level %d only"):format(v.ml or 0), ("This raid is for level %d characters."):format(v.ml or 0)
    end
    if block == "lock" then
        if RP():CanManageRaid(v) then
            return "Not invited", (v.pv and "Private" or "Locked") .. ": you are not in this raid (Add players adds you)."
        end
        return v.pv and "Private" or "Locked to its teams", "Ask a raid leader for an invite."
    end
    return nil
end

-- My answer to a planned raid in words and colour (the calendar, the tooltips).
local function answerState(v)
    if v.cancelled then return "Cancelled", C_PAST end
    local rp = RP()
    local mine = rp:GetMySignup(v.id)
    if mine and STATUS[mine.st] then return STATUS[mine.st].label, STATUS[mine.st].color end
    if v.t < Now() - CURRENT_FOR then return "No answer", C_PAST end
    local kind, block = myState(v)
    if kind == "R" then return "Asked to join", "ffd100" end
    local words = blockWords(v, block)
    if words and block == "lock" and rp:CanRequest(v, myChar(v)) then words = "Ask to join" end
    if words then return words, C_LOCK end
    local inv = rp:GetInvited(v)
    if inv and inv[Me() or ""] then return "Answer needed", C_NEED end
    return "Open", C_OPEN
end

-- "Kara", "SSC", or a short custom title (a chip has little room).
local function shortRaidName(v)
    if v.ti and #v.ti <= 14 then return v.ti end
    if type(v.ix) == "table" and v.ix[1] then return ns.RaidComp:ShortRaidName(v) end
    return SHORT_NAME[v.i] or RP():GetRaidName(v)
end

-- My answer as a pill marker: a ready-check icon, "!" when I'm invited and haven't answered.
local function myMarker(v)
    local rp = RP()
    local mine = rp:GetMySignup(v.id)
    if mine then return PILL_ICON[mine.st] or colorize(STATUS.B.color, "B") end
    local inv = rp:GetInvited(v)
    if inv and inv[Me() or ""] then return colorize(C_NEED, "!") end
    return nil
end

-- "Main team, Alt team" (nil for a raid open to everyone).
local function teamsText(v)
    local names = {}
    for _, id in ipairs(v.tm or {}) do
        local t = RP():GetTeam(id)
        if t then names[#names + 1] = t.name end
    end
    return #names > 0 and tconcat(names, ", ") or nil
end

-- The next raid's readiness, for the council and the organizers: { { text, title, names } } (only what needs
-- attention), and how many players are coming.
local function readiness(v, ctx)
    local ups, _, _, noAnswer = signupCounts(v)
    local coming = {}
    for key, s in pairs(ups) do
        if s.st == "A" or s.st == "T" then coming[#coming + 1] = key end
    end
    tsort(coming)
    local items = {}
    local function add(list, fmt, title)
        if #list > 0 then items[#items + 1] = { text = fmt:format(#list), title = title, names = list } end
    end
    if isCouncil() then
        local Store = ns.Store
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
        add(empty, "%d without a P" .. ctx.phase .. " list", "No BiS picks for Phase " .. ctx.phase)
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
    add(noAddon, "%d without DisasterZone", "DisasterZone never seen on")
    add(oldAddon, "%d on an older version", "Older than your " .. tostring(ns.version))
    if RP():GetInvited(v) then add(noAnswer, "%d not answered", "No response yet") end
    local flags = ns.Store and ns.Store.GetLockFlags and ns.Store:GetLockFlags() or {}
    local flagged = {}
    for key in pairs(flags) do flagged[#flagged + 1] = key end
    tsort(flagged)
    add(flagged, "%d edited while locked", "Changed their list while locked")
    return items, #coming
end

local function namesLine(list)
    local names = {}
    for i, key in ipairs(list) do
        if i > 15 then
            names[#names + 1] = "+" .. (#list - 15) .. " more"
            break
        end
        names[#names + 1] = shortName(key)
    end
    return tconcat(names, ", ")
end

---------------------------------------------------------------------------
-- The greeting and the action chips
---------------------------------------------------------------------------

local CHIP_STYLE = {
    plain = { edge = { 0.43, 0.43, 0.47, 0.6 }, text = { 0.91, 0.91, 0.91 } },
    warn  = { edge = { 1, 0.55, 0.10, 0.7 }, text = { 1, 0.82, 0.65 } },
    info  = { edge = { 0.40, 0.72, 1, 0.55 }, text = { 0.81, 0.91, 1 } },
    bad   = { edge = { 0.89, 0.36, 0.31, 0.85 }, text = { 1, 0.82, 0.78 } },
}

local function paintChip(c)
    local hover = c.hovered and c.onClick
    local f = hover and { 0.18, 0.18, 0.21, 0.95 } or CARD_BG
    local s = CHIP_STYLE[c.kind] or CHIP_STYLE.plain
    c:SetPillColors(f, s.edge)
end

local function newChip(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(CHIP_H)
    UI():AddPillShape(c, CHIP_H)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(13, 13)
    c.icon:SetPoint("LEFT", 7, 0)
    c.text = text(c, 11, "GameFontHighlightSmall")
    c:SetScript("OnEnter", function(self)
        self.hovered = true
        paintChip(self)
        if self.tip then showTip(self, self.tip, "ANCHOR_BOTTOM") end
    end)
    c:SetScript("OnLeave", function(self)
        self.hovered = false
        paintChip(self)
        hideTip()
    end)
    c:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
    return c
end

local function fillChip(c, a)
    c.kind, c.tip, c.onClick = a.kind or "plain", a.tip, a.onClick
    local s = CHIP_STYLE[c.kind] or CHIP_STYLE.plain
    local ic = a.icon
    c.icon:SetShown(ic ~= nil)
    c.text:ClearAllPoints()
    if ic then
        c.icon:SetTexture(ic.tex)
        if ic.coords then c.icon:SetTexCoord(ic.coords[1], ic.coords[2], ic.coords[3], ic.coords[4])
        else c.icon:SetTexCoord(0, 1, 0, 1) end
        c.icon:SetDesaturated(ic.desat and true or false)
        c.text:SetPoint("LEFT", c.icon, "RIGHT", 5, 0)
    else
        c.text:SetPoint("LEFT", 10, 0)
    end
    c.text:SetText(a.text)
    c.text:SetTextColor(s.text[1], s.text[2], s.text[3])
    c:SetWidth(floor((ic and (7 + 13 + 5) or 10) + strW(c.text) + 10))
    paintChip(c)
end

local function roleIcon(role)
    local l, r, t, b = UI():RoleCoords(role)
    return { tex = UI().ROLE_TEX, coords = { l, r, t, b } }
end

-- The actions that need me now: { text, kind = warn | info | bad | plain, icon, tip = { lines }, onClick }.
local function collectActions(ctx)
    local out = {}
    local rp = RP()
    for _, v in ipairs(rp and rp.GetUnanswered and rp:GetUnanswered(7) or {}) do
        out[#out + 1] = {
            text = "Sign up: " .. date("%a", v.t) .. " " .. shortRaidName(v), kind = "warn",
            icon = { tex = "Interface\\RaidFrame\\ReadyCheck-Ready", desat = true },
            tip = { rp:GetRaidName(v), date("%a %d %b %H:%M", v.t) .. " · " .. whenText(v.t),
                    "You're invited and haven't answered." },
            onClick = function() openRaid(v.id) end,
        }
    end
    local s = ctx.bis
    local star = { tex = UI():Tex("star") }
    if s.filled == 0 then
        out[#out + 1] = { text = "Pick your Phase " .. ctx.phase .. " BiS", kind = "warn", icon = star,
                          tip = { "Your Phase " .. ctx.phase .. " list is empty", "The council can't see what you need." },
                          onClick = function() openMyBiS(ctx.phase) end }
    elseif s.filled < s.total then
        local empty = s.total - s.filled
        out[#out + 1] = { text = "Phase " .. ctx.phase .. ": " .. plural(empty, "empty slot"), kind = "info", icon = star,
                          tip = { "Fill or disable the empty slots of your Phase " .. ctx.phase .. " list" },
                          onClick = function() openMyBiS(ctx.phase) end }
    end
    local R = DR()
    local mine = R and R:GetMine()
    local asking = mine and R:GetRequests(mine.id) or {}
    if #asking > 0 then
        local first = asking[1]
        local d = R:GetDungeon(mine.d)
        local name = (d and d.name or tostring(mine.d)) .. (mine.h and " (Heroic)" or "")
        local tip = { "Your run: " .. name }
        for _, r in ipairs(asking) do tip[#tip + 1] = UI():ColoredName(r.key) .. grey(" wants to join") end
        tip[#tip + 1] = grey("Accept or decline them on the Dungeons tab.")
        out[#out + 1] = { text = #asking == 1 and (shortName(first.key) .. " wants to join your run")
                                  or (#asking .. " want to join your run"),
                          icon = first.r and roleIcon(first.r) or nil, tip = tip,
                          onClick = function() openRun(mine.id) end }
    end
    if R and not mine and R:IsUp() then
        for _, run in ipairs(R:GetRuns()) do
            local role = R:IsNow(run) and R:FitsMe(run)
            if role and not R:GetBlocker(run.d, run.h) and not R:GetAsked(run.id) then
                local id = run.id
                local d = R:GetDungeon(run.d)
                local name = (d and d.name or tostring(run.d)) .. (run.h and " (H)" or "")
                out[#out + 1] = { text = shortName(run.o) .. " needs a " .. (role == "dps" and "DPS" or role) .. ": " .. name,
                                  kind = "info", icon = roleIcon(role),
                                  tip = { name, "You're up for a run and this one needs you." },
                                  onClick = function() openRun(id) end }
                break
            end
        end
    end
    local newer = newerVersion()
    if newer then
        out[#out + 1] = { text = "Update DisasterZone (" .. newer .. ")", kind = "bad", icon = { tex = UI().ICON_WARN },
                          tip = { "A guild member runs DisasterZone " .. newer, "You run " .. tostring(ns.version) } }
    end
    local unread = ns.ChangelogUI and ns.ChangelogUI.GetUnread and ns.ChangelogUI:GetUnread()
    if unread then
        out[#out + 1] = { text = "What's new in " .. unread.version, kind = "info",
                          icon = { tex = UI().ICON_ATLAS, coords = UI():IconCoords(UI().ICON.notes) },
                          tip = { "DisasterZone " .. unread.version .. ": " .. (unread.title or ""), "Open the Changelog" },
                          onClick = function() ns.ChangelogUI:Open(unread.version) end }
    end
    local BiS = ns.BiS
    local locked, info = false, nil
    if BiS and BiS.IsLocked then locked, info = BiS:IsLocked() end
    if locked then
        local by = type(info) == "table" and info.by and shortName(info.by) or nil
        out[#out + 1] = { text = "BiS lists locked", icon = { tex = UI().ICON_LOCK },
                          tip = { "BiS lists are locked for this raid" .. (by and (" by " .. by) or ""),
                                  "Changes wait until the raid leader unlocks them." } }
    end
    return out
end

-- "Good evening, " by the player's own clock; the name follows in its class colour.
local function greetingText()
    local hour = tonumber(date("%H")) or 12
    local part = (hour >= 5 and hour < 12) and "morning" or (hour >= 12 and hour < 18) and "afternoon" or "evening"
    return "Good " .. part .. ", "
end

-- The greeting leads the strip; the chips follow it, else "All caught up" sits right.
local function layoutChips(list)
    panel.greeting:SetText(greetingText())
    local _, classFile = UnitClass("player")
    panel.greetName:SetText(UnitName("player") or "")
    panel.greetName:SetTextColor(UI():ClassColor(classFile))
    local x = floor(strW(panel.greeting) + strW(panel.greetName) + 14)
    local shown = 0
    for i, a in ipairs(list) do
        local c = panel.chips[i]
        if not c then
            c = newChip(panel.hello)
            panel.chips[i] = c
        end
        fillChip(c, a)
        local w = c:GetWidth()
        -- room for "+N more" after it, unless it is the last one
        local room = INNER_W - ((i < #list) and 64 or 0)
        c:ClearAllPoints()
        if shown == i - 1 and x + w <= room then
            c:SetPoint("LEFT", panel.hello, "LEFT", x, 0)
            c:Show()
            x = x + w + 6
            shown = i
        else
            c:Hide()
        end
    end
    for i = #list + 1, #panel.chips do panel.chips[i]:Hide() end
    local hidden = #list - shown
    if hidden > 0 then
        local lines = { "More to do" }
        for i = shown + 1, #list do lines[#lines + 1] = list[i].text end
        panel.moreChips:SetLabel("+" .. hidden .. " more")
        panel.moreChips.tip = lines
        panel.moreChips:ClearAllPoints()
        panel.moreChips:SetPoint("LEFT", panel.hello, "LEFT", x + 2, 0)
        panel.moreChips:Show()
    else
        panel.moreChips:Hide()
    end
    panel.allSet:SetShown(false)          -- (nothing to do says itself: no line for it)
end

local function createHello(p)
    local h = CreateFrame("Frame", nil, p)
    h:SetPoint("TOPLEFT", PAD, -HELLO_Y)
    h:SetSize(INNER_W, HELLO_H)
    p.hello = h
    p.greeting = text(h, 14, "GameFontHighlight")
    p.greeting:SetTextColor(0.91, 0.91, 0.91)
    p.greeting:SetPoint("LEFT", 0, 0)
    p.greetName = text(h, 14, "GameFontHighlight")
    p.greetName:SetPoint("LEFT", p.greeting, "RIGHT", 0, 0)
    p.allSet = CreateFrame("Frame", nil, h)
    p.allSet:SetSize(110, 18)
    p.allSet:SetPoint("RIGHT", 0, 0)
    p.allSet.icon = p.allSet:CreateTexture(nil, "ARTWORK")
    p.allSet.icon:SetSize(13, 13)
    p.allSet.icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    p.allSet.fs = text(p.allSet, 11, "GameFontHighlightSmall")
    p.allSet.fs:SetTextColor(0.62, 0.62, 0.62)
    p.allSet.fs:SetPoint("RIGHT", 0, 0)
    p.allSet.fs:SetText("All caught up")
    p.allSet.icon:SetPoint("RIGHT", p.allSet.fs, "LEFT", -5, 0)
    p.moreChips = newLink(h, "+1 more")
    p.moreChips.chev:Hide()
    p.moreChips:Hide()
    p.chips = {}
end

---------------------------------------------------------------------------
-- The banner: the raids of the coming week, one at a time (or the raid in progress, or nothing planned). Two faces
-- take turns inside a clipping frame: the next raid is drawn on the hidden one, which slides in as the other slides
-- out.
---------------------------------------------------------------------------

-- The raid's loading screen cropped for the banner (from the Raids board).
local function setArt(tex, inst, w, h, fw)
    local PUI = ns.RaidPlanUI
    local file, l, r, t, b
    if PUI and PUI.RaidArt then file, l, r, t, b = PUI:RaidArt(inst or "other", w, h, fw) end
    if file then
        tex:SetTexture(file)
        tex:SetTexCoord(l, r, t, b)
        tex:Show()
    else
        tex:Hide()
    end
end

-- My answer's pill (as on the Raids board): p:Set(kind, sub)
local function newAnswerPill(parent)
    local p = CreateFrame("Button", nil, parent)
    p:SetHeight(24)
    UI():AddPillShape(p, 24)
    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(14, 14)
    p.icon:SetPoint("LEFT", 8, 0)
    p.text = text(p, 12, "GameFontHighlight")
    p.sub = text(parent, 11, "GameFontHighlightSmall")
    p.sub:SetTextColor(0.62, 0.62, 0.62)
    p.sub:SetJustifyH("RIGHT")
    p.sub:SetPoint("TOPRIGHT", p, "BOTTOMRIGHT", -4, -3)
    function p:Set(kind, sub)
        local c = ANSWER_PILL[kind] or ANSWER_PILL.R
        self:SetPillColors({ c[1], c[2], c[3], 0.95 }, { c[5], c[6], c[7], c[4] + 0.3 })
        self.text:SetText("|cff" .. c[8] .. (ANSWER_TEXT[kind] or "") .. "|r")
        local icon = ANSWER_ICON[kind]
        self.icon:SetShown(icon ~= nil)
        self.text:ClearAllPoints()
        if icon then
            self.icon:SetTexture(icon)
            self.text:SetPoint("LEFT", self.icon, "RIGHT", 5, 0)
        else
            self.text:SetPoint("LEFT", 11, 0)
        end
        self:SetWidth(floor((icon and (8 + 14 + 5) or 11) + strW(self.text) + 11))
        self.sub:SetText(sub or "")
        self.sub:SetShown(sub ~= nil)
    end
    function p:SetPillShown(on)
        self:SetShown(on)
        if not on then self.sub:Hide() end
    end
    return p
end

-- Every answer (mine ticked) and the way to the raid's page: the banner's ... button and my answer's pill. The
-- banner holds still while the menu is open.
local openMenu
local function answerMenu(owner, v, current)
    openMenu = UI():ContextMenu(owner, function(root)
        root:CreateTitle(RP():GetRaidName(v))
        for _, st in ipairs(STATUS_ORDER) do
            local label = (current == st and ("|cff33ff33" .. STATUS[st].button .. " (yours)|r")) or STATUS[st].button
            root:CreateButton(label, function() answer(v.id, st) end)
        end
        if root.CreateDivider then root:CreateDivider() end
        root:CreateButton("Open the raid", function() openRaid(v.id) end)
    end)
end

local fillFace, refreshBanner     -- (below: the faces' contents)

-- One face of the banner (the banner's size, so its texts sit where the banner's would): the art, the texts, my
-- answer and the foot. A click on it is the banner's.
local function createFace(holder)
    local b = CreateFrame("Frame", nil, holder.clip)
    b:SetSize(INNER_W, BANNER_H)
    local ban = CreateFrame("Frame", nil, b)
    ban:SetPoint("TOPLEFT", 0, 0)
    ban:SetPoint("TOPRIGHT", 0, 0)
    ban:SetHeight(BANNER_H - FOOT_H)
    b.ban = ban
    -- the art (inside the banner's 1px edges), shaded so the texts read on any loading screen
    b.art = ban:CreateTexture(nil, "BACKGROUND", nil, 0)
    b.art:SetPoint("TOPLEFT", 1, -1)
    b.art:SetPoint("BOTTOMRIGHT", -1, 0)
    b.shadeLow = ban:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.shadeLow:SetPoint("BOTTOMLEFT", b.art)
    b.shadeLow:SetPoint("BOTTOMRIGHT", b.art)
    gradient(b.shadeLow, "VERTICAL", INK, 0.95, 0.5)
    b.shadeHigh = ban:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.shadeHigh:SetPoint("TOPLEFT", b.art)
    b.shadeHigh:SetPoint("TOPRIGHT", b.art)
    b.shadeHigh:SetPoint("BOTTOM", b.shadeLow, "TOP")
    gradient(b.shadeHigh, "VERTICAL", INK, 0.5, 0.15)
    b.shadeLeft = ban:CreateTexture(nil, "BACKGROUND", nil, 2)
    b.shadeLeft:SetPoint("TOPLEFT", b.art)
    b.shadeLeft:SetPoint("BOTTOMLEFT", b.art)
    b.shadeLeft:SetWidth(floor(INNER_W * 0.6))
    gradient(b.shadeLeft, "HORIZONTAL", INK, 0.8, 0)

    -- the top row: what it is (the carousel's strip is the banner's, over it), the countdown
    b.kick = text(ban, 10, "GameFontNormalSmall")
    b.kick:SetPoint("TOPLEFT", IN, -12)
    b.cd = CreateFrame("Frame", nil, ban)
    b.cd:SetHeight(19)
    b.cd:SetPoint("TOPRIGHT", -IN, -8)
    UI():AddPillShape(b.cd, 19)
    b.cd:SetPillColors({ INK[1], INK[2], INK[3], 0.6 }, { 1, 0.82, 0, 0.35 })
    b.cd.fs = text(b.cd, 11, "GameFontNormalSmall")
    b.cd.fs:SetPoint("CENTER", 0, 0)

    -- the date column, then the raid: title, who / what, the answers by role
    b.tm = text(ban, 11, "GameFontHighlightSmall")
    b.tm:SetTextColor(0.81, 0.81, 0.81)
    b.tm:SetJustifyH("CENTER")
    b.tm:SetPoint("BOTTOM", ban, "BOTTOMLEFT", DATE_W / 2, IN)
    b.dn = text(ban, 26, "GameFontHighlightLarge")
    b.dn:SetJustifyH("CENTER")
    b.dn:SetPoint("BOTTOM", b.tm, "TOP", 0, 0)
    b.wd = text(ban, 10, "GameFontNormalSmall")
    b.wd:SetJustifyH("CENTER")
    b.wd:SetPoint("BOTTOM", b.dn, "TOP", 0, 1)
    b.div = ban:CreateTexture(nil, "ARTWORK")
    b.div:SetColorTexture(1, 1, 1, 0.14)
    b.div:SetSize(1, 54)
    b.div:SetPoint("BOTTOMLEFT", DATE_W, IN)
    b.meter = text(ban, 11, "GameFontHighlightSmall")
    b.meterHit = CreateFrame("Button", nil, ban)
    b.meterHit:SetPoint("TOPLEFT", b.meter, "TOPLEFT", 0, 2)
    b.meterHit:SetPoint("BOTTOMRIGHT", b.meter, "BOTTOMRIGHT", 0, -2)
    b.meterHit:SetScript("OnEnter", function(self) if self.tip then showTip(self, self.tip, "ANCHOR_BOTTOM") end end)
    b.meterHit:SetScript("OnLeave", hideTip)
    b.meterHit:SetScript("OnClick", function() holder:Click() end)
    b.meta = text(ban, 11, "GameFontHighlightSmall")
    b.meta:SetTextColor(0.82, 0.82, 0.82)
    b.meta:SetPoint("BOTTOMLEFT", b.meter, "TOPLEFT", 0, 6)
    b.title = text(ban, 17, "GameFontHighlightLarge")
    b.title:SetPoint("BOTTOMLEFT", b.meta, "TOPLEFT", 0, 4)

    -- my answer, bottom right: Accept / Tentative / ..., my answer's pill, Ask to join, or why I can't
    b.more = UI():CreateTipIconButton(ban, 26, UI().ICON.more, "More answers", "Bench or Absent, or open the raid.")
    b.more:SetPoint("BOTTOMRIGHT", -IN, IN)
    b.tentative = UI():CreateSleekButton(ban, STATUS.T.button, 80, 26, nil)
    b.tentative:SetPoint("RIGHT", b.more, "LEFT", -4, 0)
    b.accept = UI():CreateSleekButton(ban, STATUS.A.button, 70, 26, nil, "primary")
    b.accept:SetPoint("RIGHT", b.tentative, "LEFT", -4, 0)
    b.ask = UI():CreateSleekButton(ban, "Ask to join", 100, 26, nil, "primary")
    b.ask:SetPoint("BOTTOMRIGHT", -IN, IN)
    b.action = UI():CreateSleekButton(ban, "", 100, 26, nil)
    b.action:SetPoint("BOTTOMRIGHT", -IN, IN)
    b.pill = newAnswerPill(ban)
    b.why = CreateFrame("Frame", nil, ban)
    b.why:SetHeight(18)
    b.why:SetPoint("BOTTOMRIGHT", -IN, IN + 4)
    b.why.fs = text(b.why, 12, "GameFontHighlight")
    b.why.fs:SetTextColor(0.74, 0.74, 0.74)
    b.why.fs:SetPoint("RIGHT", 0, 0)
    b.why:EnableMouse(true)
    b.why:SetScript("OnEnter", function(self) if self.tip then showTip(self, self.tip, "ANCHOR_TOP") end end)
    b.why:SetScript("OnLeave", hideTip)

    -- the foot: the raid's note; my BiS picks that drop there (left), the readiness or the lock (right)
    b.footLine = b:CreateTexture(nil, "ARTWORK")
    b.footLine:SetColorTexture(1, 1, 1, 0.06)
    b.footLine:SetHeight(1)
    b.note = text(b, 11, "GameFontHighlightSmall")
    b.note:SetTextColor(0.74, 0.74, 0.74)
    b.bis = CreateFrame("Button", nil, b)
    b.bis:SetHeight(16)
    b.bis.star = b.bis:CreateTexture(nil, "ARTWORK")
    b.bis.star:SetSize(12, 12)
    b.bis.star:SetPoint("LEFT", 0, 0)
    b.bis.star:SetTexture(UI():Tex("star"))
    b.bis.fs = text(b.bis, 11, "GameFontNormalSmall")
    b.bis.fs:SetPoint("LEFT", b.bis.star, "RIGHT", 5, 0)
    b.bis.chev = b.bis:CreateTexture(nil, "ARTWORK")
    b.bis.chev:SetSize(9, 9)
    b.bis.chev:SetPoint("LEFT", b.bis.fs, "RIGHT", 4, 0)
    chevron(b.bis.chev, "right")
    b.bis.chev:SetVertexColor(1, 0.82, 0)
    b.bis:SetScript("OnEnter", function(self)
        self.fs:SetTextColor(1, 1, 1)
        if self.tip then showTip(self, self.tip, "ANCHOR_TOP") end
    end)
    b.bis:SetScript("OnLeave", function(self)
        self.fs:SetTextColor(1, 0.82, 0)
        hideTip()
    end)
    b.bis:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
    b.ready = CreateFrame("Button", nil, b)
    b.ready:SetHeight(16)
    b.ready.fs = text(b.ready, 11, "GameFontHighlightSmall")
    b.ready.fs:SetJustifyH("RIGHT")
    b.ready.fs:SetPoint("RIGHT", 0, 0)
    b.ready.icon = b.ready:CreateTexture(nil, "ARTWORK")
    b.ready.icon:SetSize(13, 13)
    b.ready.icon:SetPoint("RIGHT", b.ready.fs, "LEFT", -5, 0)
    b.ready:SetScript("OnEnter", function(self) if self.tip then showTip(self, self.tip, "ANCHOR_TOP") end end)
    b.ready:SetScript("OnLeave", hideTip)
    b.ready:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
    return b
end

-- The carousel's strip (top left, over the faces): a bar per raid, the shown one long with the time to the next
-- slide filling it in gold, and an arrow on each side. A bar or an arrow slides to that raid.
local BAR_W, BAR_ON, BAR_GAP, BAR_H = 14, 32, 5, 2
local STRIP_X = IN - 5               -- the left arrow's glyph lines up with the texts below

local function stripArrow(holder, dir)
    local a = CreateFrame("Button", nil, holder.strip)
    a:SetSize(18, 18)
    a.icon = a:CreateTexture(nil, "ARTWORK")
    a.icon:SetSize(9, 9)
    a.icon:SetPoint("CENTER")
    chevron(a.icon, dir)
    a.icon:SetVertexColor(0.80, 0.80, 0.80)
    a:SetScript("OnClick", function() holder:Flip(holder.at + (dir == "left" and -1 or 1), dir == "left" and -1 or 1) end)
    a:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(1, 0.82, 0)
        local list = holder.ctx and holder.ctx.slides or {}
        local n = #list
        local v = n > 0 and list[((holder.at or 1) - 1 + (dir == "left" and -1 or 1)) % n + 1]
        if v then
            showTip(self, { dir == "left" and "Previous raid" or "Next raid",
                            RP():GetRaidName(v) .. grey(" · " .. shortDay(v.t) .. date(" %H:%M", v.t)) }, "ANCHOR_TOP")
        end
    end)
    a:SetScript("OnLeave", function(self)
        self.icon:SetVertexColor(0.80, 0.80, 0.80)
        hideTip()
    end)
    return a
end

local function stripBar(holder, i)
    local s = CreateFrame("Button", nil, holder.strip)
    s:SetHeight(14)
    s.track = s:CreateTexture(nil, "ARTWORK")
    s.track:SetHeight(BAR_H)
    s.track:SetPoint("LEFT", 0, 0)
    s.track:SetPoint("RIGHT", 0, 0)
    s.fill = s:CreateTexture(nil, "OVERLAY")
    s.fill:SetHeight(BAR_H)
    s.fill:SetPoint("LEFT", 0, 0)
    s.fill:SetColorTexture(1, 0.82, 0, 0.95)
    s:SetScript("OnClick", function() holder:Flip(i) end)
    s:SetScript("OnEnter", function(self)
        self.hot = true
        holder:PaintStrip()
        local v = holder.ctx and holder.ctx.slides[i]
        if v then
            local tip = { RP():GetRaidName(v), date("%a %d %b %H:%M", v.t) .. " · " .. countdown(v.t) }
            local marker = myMarker(v)
            if marker then
                local mine = RP():GetMySignup(v.id)
                tip[#tip + 1] = marker .. " " .. (mine and (ANSWER_TEXT[mine.st] or "") or "Answer needed")
            end
            tip[#tip + 1] = grey(i == holder.at and "Shown now" or "Click to show this raid")
            showTip(self, tip, "ANCHOR_TOP")
        end
    end)
    s:SetScript("OnLeave", function(self)
        self.hot = nil
        holder:PaintStrip()
        hideTip()
    end)
    return s
end

-- easeInOutCubic: a slow start, a glide, a soft landing.
local function ease(x)
    if x < 0.5 then return 4 * x * x * x end
    local y = 2 - 2 * x
    return 1 - y * y * y / 2
end

local function createBanner(p)
    local b = CreateFrame("Button", nil, p)
    b:SetPoint("TOPLEFT", PAD, -BANNER_Y)
    b:SetSize(INNER_W, BANNER_H)
    b:RegisterForClicks("LeftButtonUp")
    flatBox(b, CARD_BG, { EDGE[1], EDGE[2], EDGE[3], 0.7 })
    p.banner = b
    -- the faces slide inside the banner's 1px edges
    b.clip = CreateFrame("Frame", nil, b)
    b.clip:SetPoint("TOPLEFT", 1, -1)
    b.clip:SetPoint("BOTTOMRIGHT", -1, 1)
    b.clip:SetClipsChildren(true)
    b.faces = { createFace(b), createFace(b) }
    b.face = b.faces[1]
    b.faces[2]:Hide()
    b.at, b.hold = 1, 0

    b.strip = CreateFrame("Frame", nil, b)
    b.strip:SetFrameLevel(b:GetFrameLevel() + 20)
    b.strip:SetHeight(18)
    b.strip:SetPoint("LEFT", b, "TOPLEFT", STRIP_X, -17)
    b.strip:Hide()
    b.prev = stripArrow(b, "left")
    b.prev:SetPoint("LEFT", 0, 0)
    b.next = stripArrow(b, "right")
    b.bars = {}

    -- a face at x (0 = in place, -INNER_W = gone to the left)
    function b:PlaceFace(f, x)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", self.clip, "TOPLEFT", floor(x + 0.5) - 1, 1)
    end

    -- The bars: their widths (the shown one long; during a slide the old one shrinks as the new one grows) and the
    -- gold fill of the time left on the shown raid.
    function b:PaintStrip()
        local n = self.ctx and #self.ctx.slides or 0
        local a = self.anim
        local e = a and ease(min(1, a.t / FLIP_TIME)) or 1
        local x = 18 + 2
        for i = 1, n do
            local s = self.bars[i]
            local on = (i == self.at and e) or (a and i == a.fromAt and (1 - e)) or 0
            local w = floor(BAR_W + (BAR_ON - BAR_W) * on + 0.5)
            s:SetWidth(w)
            s:ClearAllPoints()
            s:SetPoint("LEFT", self.strip, "LEFT", x, 0)
            s.track:SetColorTexture(1, 1, 1, s.hot and 0.6 or (0.22 + 0.14 * on))
            local f = (i == self.at and not a) and min(1, self.hold / FLIP_EVERY) or 0
            s.fill:SetWidth(max(0.01, w * f))
            s.fill:SetShown(f > 0)
            x = x + w + BAR_GAP
        end
        self.next:ClearAllPoints()
        self.next:SetPoint("LEFT", self.strip, "LEFT", x - BAR_GAP + 2, 0)
        self.strip:SetWidth(x - BAR_GAP + 2 + 18)
    end

    -- only the shown bar's fill (between slides)
    function b:PaintFill()
        local s = self.bars[self.at]
        if not s then return end
        local f = min(1, self.hold / FLIP_EVERY)
        s.fill:SetWidth(max(0.01, s:GetWidth() * f))
        s.fill:SetShown(f > 0)
    end

    function b:LayoutStrip()
        local n = self.ctx and #self.ctx.slides or 0
        for i = #self.bars + 1, n do self.bars[i] = stripBar(self, i) end
        for i, s in ipairs(self.bars) do s:SetShown(i <= n) end
        self.strip:SetShown(n > 1)
        if n > 1 then self:PaintStrip() end
    end

    -- Slides to raid `to` (wraps around); dir 1 = the new raid comes in from the right.
    function b:Flip(to, dir)
        local list = self.ctx and self.ctx.slides or {}
        local n = #list
        if self.anim or n < 2 then return end
        to = (to - 1) % n + 1
        if to == self.at then return end
        dir = dir or (to > self.at and 1 or -1)
        local from = self.face
        local into = from == self.faces[1] and self.faces[2] or self.faces[1]
        fillFace(into, self.ctx, list[to])
        self:PlaceFace(into, dir * INNER_W)
        into:SetAlpha(0.4)
        into:Show()
        self.anim = { from = from, into = into, dir = dir, t = 0, fromAt = self.at }
        self.face, self.at, self.shownId, self.hold = into, to, list[to].id, 0
        self:PaintStrip()
    end

    b:SetScript("OnUpdate", function(self, elapsed)
        local a = self.anim
        if a then
            a.t = a.t + (elapsed or 0)
            local e = ease(min(1, a.t / FLIP_TIME))
            self:PlaceFace(a.from, -a.dir * INNER_W * e)
            self:PlaceFace(a.into, a.dir * INNER_W * (1 - e))
            a.from:SetAlpha(1 - 0.6 * e)
            a.into:SetAlpha(0.4 + 0.6 * e)
            if a.t >= FLIP_TIME then
                a.from:Hide()
                a.from:SetAlpha(1)
                self:PlaceFace(a.from, 0)
                self.anim = nil
                -- a refresh that came during the slide
                if self.stale then
                    self.stale = nil
                    refreshBanner(self, self.ctx)
                end
            end
            self:PaintStrip()
            return
        end
        if not self.strip:IsShown() then return end
        -- the shown raid's time runs while nobody looks at it closely
        local menu = openMenu and openMenu.IsShown and openMenu:IsShown()
        if self:IsMouseOver() or menu then return end
        self.hold = self.hold + (elapsed or 0)
        if self.hold >= FLIP_EVERY then self:Flip(self.at + 1, 1) else self:PaintFill() end
    end)
    b:SetScript("OnEnter", function(self)
        if self.face.onClick then UI():SetEdgeColor(self, 1, 0.82, 0, 0.55) end
    end)
    b:SetScript("OnLeave", function(self) UI():SetEdgeColor(self, EDGE[1], EDGE[2], EDGE[3], 0.7) end)
    b:SetScript("OnClick", function(self) if self.face.onClick then self.face.onClick() end end)
end

-- Places the foot's lines (note: 0..2 lines, f2 = the BiS / readiness line) and sizes the art part above it; the
-- banner keeps its height either way.
local function layoutFoot(b, noteLines, hasF2)
    local lines = noteLines + (hasF2 and 1 or 0)
    local footH = lines == 0 and 0 or max(FOOT_H, 16 + lines * 14 + (lines - 1) * 4)
    local banH = BANNER_H - footH
    b.ban:SetHeight(banH)
    b.shadeLow:SetHeight(floor((banH - 1) * 0.62))
    b.footLine:SetShown(footH > 0)
    b.footLine:ClearAllPoints()
    b.footLine:SetPoint("TOPLEFT", 1, -banH)
    b.footLine:SetPoint("TOPRIGHT", -1, -banH)
    -- the lines, centred in the foot
    local used = lines > 0 and (noteLines * 14 + (hasF2 and 14 or 0) + (lines - 1) * 4) or 0
    local y = banH + floor((footH - used) / 2)
    b.note:ClearAllPoints()
    b.note:SetPoint("TOPLEFT", IN, -y)
    b.note:SetPoint("TOPRIGHT", -IN, -y)
    if noteLines > 0 then y = y + noteLines * 14 + 4 end
    b.bis:ClearAllPoints()
    b.bis:SetPoint("LEFT", b, "TOPLEFT", IN, -(y + 7))
    b.ready:ClearAllPoints()
    b.ready:SetPoint("RIGHT", b, "TOPRIGHT", -IN, -(y + 7))
    return banH
end

-- The note line: one line at 11, else at 10, else two lines (a note is at most 120 characters).
local function fitNote(b, note)
    local fs = b.note
    fs:SetText('"' .. note .. '"')
    if fs.SetMaxLines then fs:SetMaxLines(1) end
    for _, size in ipairs({ 11, 10 }) do
        setSize(fs, size)
        fs:SetWordWrap(false)
        if strW(fs) <= INNER_W - 2 * IN then return 1 end
    end
    fs:SetWordWrap(true)
    if fs.SetMaxLines then fs:SetMaxLines(2) end
    return 2
end

-- The texts' left edge: beside the date column, or at the banner's padding without one.
local function placeTexts(b, withDate)
    for _, fs in ipairs({ b.wd, b.dn, b.tm, b.div }) do fs:SetShown(withDate) end
    b.meter:ClearAllPoints()
    b.meter:SetPoint("BOTTOMLEFT", withDate and (DATE_W + 13) or IN, IN + 1)
end

-- Fits the title / meta / meter beside the answer area (aw = its width).
local function textWidth(b, withDate, aw)
    local w = INNER_W - (withDate and (DATE_W + 13) or IN) - IN - aw - 16
    for _, fs in ipairs({ b.title, b.meta, b.meter }) do fs:SetWidth(w) end
    return w
end

local function hideAnswer(b)
    for _, w in ipairs({ b.accept, b.tentative, b.more, b.ask, b.action, b.why }) do w:Hide() end
    b.pill:SetPillShown(false)
end

-- The foot's right side: the readiness of the next raid (organizers), what's missing first.
local function fillReadiness(b, v, ctx, room)
    local items, coming = readiness(v, ctx)
    local r = b.ready
    local tip = { "Is the raid ready?" }
    if #items == 0 then
        -- ready: nothing to say
        r:Hide()
        return
    else
        r.icon:SetTexture(UI().ICON_WARN)
        local shown = items[1].text
        local n = 1
        for i = 2, #items do
            local cand = shown .. " · " .. items[i].text
            local rest = #items - i
            r.fs:SetText(cand .. (rest > 0 and (" · +" .. rest .. " more") or ""))
            if strW(r.fs) > room - 18 then break end
            shown, n = cand, i
        end
        local rest = #items - n
        r.fs:SetText(shown .. (rest > 0 and (" · +" .. rest .. " more") or ""))
        r.fs:SetTextColor(0.80, 0.80, 0.80)          -- (the warning icon says it; the words stay calm)
        for _, it in ipairs(items) do
            tip[#tip + 1] = { it.text, 1, 0.55, 0.1 }
            tip[#tip + 1] = namesLine(it.names)
        end
    end
    tip[#tip + 1] = grey("Click to open the raid's sign-ups")
    r.tip = tip
    r.onClick = function() openRaid(v.id) end
    r:SetWidth(floor(strW(r.fs) + 18))
    r:Show()
end

local function fillBisLine(b, drops)
    local f = b.bis
    if not drops then
        f:Hide()
        return 0
    end
    f.fs:SetText(drops.text)
    f.fs:SetTextColor(1, 0.82, 0)
    f.tip, f.onClick = drops.tip, drops.onClick
    local w = floor(12 + 5 + strW(f.fs) + 4 + 9)
    f:SetWidth(w)
    f:Show()
    return w
end

local function fillNone(b)
    local planner = RP() and RP().CanOrganize and RP():CanOrganize()
    setArt(b.art, "other", INNER_W - 2, BANNER_H - 1, 1)
    b.art:SetDesaturated(true)
    b.art:SetAlpha(0.6)
    b.kick:SetText("")
    b.cd:Hide()
    placeTexts(b, false)
    b.title:SetText("Nothing planned")
    b.meta:SetText(planner and "Plan the next one: it shows here for everyone."
                   or "The Guild Master and the raid leaders plan raids.")
    b.meter:SetText("")
    b.meterHit.tip = nil
    local aw = 0
    if planner then
        b.action:SetText("Plan a raid")
        b.action:SetKind("primary")
        b.action:SetWidth(100)
        b.action:SetScript("OnClick", function()
            openRaid(nil)
            if ns.RaidPlanUI and ns.RaidPlanUI.OpenEditor then ns.RaidPlanUI:OpenEditor() end
        end)
        b.action:Show()
        aw = 100
    end
    textWidth(b, false, aw)
    b.onClick = nil
    b.note:SetText("")
    b.bis:Hide()
    b.ready:Hide()
    layoutFoot(b, 0, false)
end

local function fillSession(b, ctx)
    local s = ctx.session
    local rp = RP()
    local planned = s.rp and rp and rp.GetRaid and rp:GetRaid(s.rp) or nil
    local instID = currentInstID()
    local inst = planned and planned.i or instKeyOf(instID)
    b.art:SetDesaturated(false)
    b.art:SetAlpha(1)
    b.kick:SetText(colorize("8fe39d", "RAID IN PROGRESS"))
    local at = tonumber(s.at)
    b.cd.fs:SetText(at and ("started " .. duration(Now() - at) .. " ago") or "in progress")
    b.cd:SetWidth(floor(strW(b.cd.fs) + 18))
    b.cd:Show()
    placeTexts(b, at ~= nil)
    if at then
        b.wd:SetText(date("%a", at):upper())
        b.dn:SetText(tonumber(date("%d", at)))
        b.tm:SetText(date("%H:%M", at))
    end
    local zone = GetInstanceInfo and (GetInstanceInfo()) or nil
    b.title:SetText(planned and rp:GetRaidName(planned) or zone or "Raid")
    -- who leads it, the loot handed out so far (mine too)
    local parts = {}
    if s.by then parts[#parts + 1] = UI():ColoredName(s.by) .. " leads" end
    local L = ns.Ledger
    if L and L.GetVisibleEntries then
        local n, mine = 0, 0
        for _, e in ipairs(L:GetVisibleEntries()) do
            if e.rid == s.id then
                n = n + 1
                if e.w == Me() then mine = mine + 1 end
            end
        end
        parts[#parts + 1] = plural(n, "item") .. " awarded" .. (mine > 0 and (" · " .. mine .. " to you") or "")
    end
    b.meta:SetText(tconcat(parts, " · "))
    -- the bosses down so far
    local RL = ns.RaidLog
    local rec = RL and RL.GetCurrentID and RL.GetRaid and RL:GetRaid(RL:GetCurrentID() or s.id)
    local kills = rec and #(rec.bosses or {}) or nil
    local total = RL and RL.GetBossTotal and RL:GetRecordBossTotal(rec, instID)
    local down = kills and (total and ("%d of %d bosses down"):format(kills, total)
                            or ((kills == 1 and "1 boss" or (kills .. " bosses")) .. " down"))
    b.meter:SetText(down or "")
    b.meterHit.tip = nil
    hideAnswer(b)
    local aw = 0
    local council = isCouncil()
    if council then
        b.action:SetText("Loot log")
        b.action:SetKind("secondary")
        b.action:SetWidth(90)
        b.action:SetScript("OnClick", function() openTab("loot") end)
        b.action:Show()
        aw = 90
    end
    textWidth(b, at ~= nil, aw)
    b.onClick = function() if planned then openRaid(planned.id) else openRaid(nil) end end
    -- the foot: what of my list can drop here; the BiS lock
    b.note:SetText("")
    local bisW = fillBisLine(b, bisDrops(currentItemRaid() or (planned and itemRaidFor(planned))))
    local Lock = UI().GetBiSLock and UI():GetBiSLock()
    if Lock then
        b.ready.icon:SetTexture(UI().ICON_LOCK)
        b.ready.fs:SetText("BiS lists locked")
        b.ready.fs:SetTextColor(0.74, 0.74, 0.74)
        b.ready.tip = { "BiS lists are locked for this raid", "Changes wait until the raid leader unlocks them." }
        b.ready.onClick = nil
        b.ready:SetWidth(floor(strW(b.ready.fs) + 18))
        b.ready:Show()
    else
        b.ready:Hide()
    end
    local banH = layoutFoot(b, 0, bisW > 0 or Lock ~= nil)
    setArt(b.art, inst, INNER_W - 2, banH - 1, 1)
end

local function fillRaid(b, ctx)
    local v = ctx.raid
    local rp = RP()
    local note = v.no and v.no ~= "" and v.no or nil
    local readyFor = canSeeReadiness()
    local drops = bisDrops(itemRaidFor(v))
    local hasF2 = drops ~= nil or readyFor
    -- the foot first (the art's height depends on it)
    local noteLines = note and fitNote(b, note) or 0
    if not note then b.note:SetText("") end
    local banH = layoutFoot(b, noteLines, hasF2)
    setArt(b.art, v.i, INNER_W - 2, banH - 1, 1)
    b.art:SetDesaturated(false)
    b.art:SetAlpha(1)
    b.kick:SetText("")
    b.cd.fs:SetText(countdown(v.t))
    b.cd:SetWidth(floor(strW(b.cd.fs) + 18))
    b.cd:Show()
    placeTexts(b, true)
    b.wd:SetText(date("%a", v.t):upper())
    b.dn:SetText(tonumber(date("%d", v.t)))
    b.tm:SetText(date("%H:%M", v.t))
    b.title:SetText(rp:GetRaidName(v))

    -- my answer
    hideAnswer(b)
    local kind, block, canAnswer, canAsk, mine = myState(v)
    local id = v.id
    local aw
    if STATUS[kind] or kind == "R" then
        local sub
        if kind == "R" then
            sub = "a raid leader approves"
        elseif mine and mine.sp and mine.c and ns.SPECS[mine.c] and ns.SPECS[mine.c][mine.sp] then
            sub = "as " .. ns.SPECS[mine.c][mine.sp].label
        end
        b.pill:Set(kind, sub)
        b.pill:ClearAllPoints()
        b.pill:SetPoint("BOTTOMRIGHT", -IN, sub and (IN + 14) or (IN + 1))
        b.pill:SetPillShown(true)
        b.pill:SetScript("OnClick", function(self) answerMenu(self, v, kind) end)
        b.pill:SetScript("OnEnter", function(self)
            showTip(self, { "Your answer", "Click to change it." }, "ANCHOR_TOP")
        end)
        b.pill:SetScript("OnLeave", hideTip)
        aw = max(b.pill:GetWidth(), sub and (strW(b.pill.sub) + 4) or 0)
    elseif canAsk then
        b.ask:SetScript("OnClick", function() answer(id, "A") end)
        b.ask:SetScript("OnEnter", function(self)
            showTip(self, { "Ask to join", "Locked to its teams: whoever runs it approves or declines." }, "ANCHOR_TOP")
        end)
        b.ask:SetScript("OnLeave", hideTip)
        b.ask:Show()
        aw = b.ask:GetWidth()
    elseif canAnswer then
        b.accept:SetScript("OnClick", function() answer(id, "A") end)
        b.tentative:SetScript("OnClick", function() answer(id, "T") end)
        b.more:SetScript("OnClick", function(self) answerMenu(self, v, nil) end)
        b.accept:Show()
        b.tentative:Show()
        b.more:Show()
        aw = b.accept:GetWidth() + b.tentative:GetWidth() + b.more:GetWidth() + 8
    else
        local words, why = blockWords(v, block)
        b.why.fs:SetText(words or "")
        b.why.tip = why and { "You can't answer", why } or nil
        b.why:SetWidth(floor(strW(b.why.fs) + 2))
        b.why:SetShown(words ~= nil)
        aw = words and b.why:GetWidth() or 0
    end
    local tw = textWidth(b, true, aw)

    -- who / what: the instance (under a custom title), size, who leads, the teams; for who runs it, the requests
    local parts = {}
    local names = {}
    for _, key in ipairs(rp:GetRaidInstances(v)) do
        local inst = rp:GetInstance(key)
        if inst and key ~= "other" then names[#names + 1] = inst.name end
    end
    if (v.ti or #names > 1) and #names > 0 then parts[#parts + 1] = { tconcat(names, " + "), 9 } end
    parts[#parts + 1] = { (v.sz or 25) .. "-player", 3 }
    if v.rl then parts[#parts + 1] = { UI():ColoredName(v.rl) .. " leads", 8 } end
    local teams = teamsText(v)
    if teams then parts[#parts + 1] = { teams, 5 } end
    if v.weekly then parts[#parts + 1] = { "weekly", 2 } end
    local nReq = (v.lk and rp:CanManageRaid(v)) and #rp:GetRequests(v.id) or 0
    if nReq > 0 then parts[#parts + 1] = { colorize("ffd100", plural(nReq, "request")), 10 } end
    local function metaText()
        local out = {}
        for _, p in ipairs(parts) do out[#out + 1] = p[1] end
        return tconcat(out, " · ")
    end
    b.meta:SetText(metaText())
    while #parts > 1 and strW(b.meta) > tw do
        local low, at = 99, nil
        for i, p in ipairs(parts) do
            if p[2] < low then low, at = p[2], i end
        end
        table.remove(parts, at)
        b.meta:SetText(metaText())
    end

    -- the accepted by role and how full it is (the tooltip has every answer and who hasn't answered)
    local _, counts, roles, noAnswer = signupCounts(v)
    local size = v.sz or 25
    if counts.A == 0 and counts.T == 0 then
        b.meter:SetText(grey("No answers yet"))
    else
        local function ri(role) return UI():RoleIconText(role, 13) end
        local total = ("%d of %d"):format(counts.A, size)
        b.meter:SetText(("%s %d    %s %d    %s %d      %s"):format(ri("tank"), roles.tank, ri("healer"), roles.healer,
            ri("dps"), roles.melee + roles.ranged + roles.nospec,
            (counts.A >= size and colorize("8fe39d", total) or grey(total))
            .. (counts.T > 0 and grey(" · " .. counts.T .. " tentative") or "")))
    end
    local tip = { "Answers" }
    local roleParts = {}
    for _, r in ipairs({ { "tank", "tank" }, { "healer", "healer" }, { "melee", "melee" }, { "ranged", "ranged" } }) do
        if roles[r[1]] > 0 then roleParts[#roleParts + 1] = plural(roles[r[1]], r[2]) end
    end
    tip[#tip + 1] = colorize(STATUS.A.color, counts.A .. " accepted") .. (#roleParts > 0 and grey(": " .. tconcat(roleParts, ", ")) or "")
    if roles.nospec > 0 then tip[#tip + 1] = colorize(C_NEED, roles.nospec .. " accepted without a spec") end
    local others = {}
    for _, st in ipairs({ "T", "B", "X" }) do
        if counts[st] > 0 then others[#others + 1] = colorize(STATUS[st].color, counts[st] .. " " .. STATUS[st].label:lower()) end
    end
    if #others > 0 then tip[#tip + 1] = tconcat(others, grey(" · ")) end
    if #noAnswer > 0 then
        tip[#tip + 1] = colorize(C_NEED, #noAnswer .. " invited, no response")
        tip[#tip + 1] = namesLine(noAnswer)
    end
    b.meterHit.tip = tip
    b.onClick = function() openRaid(id) end

    -- the foot's second line: my BiS picks (left), the readiness (right, organizers)
    local bisW = fillBisLine(b, drops)
    if readyFor then
        fillReadiness(b, v, ctx, INNER_W - 2 * IN - (bisW > 0 and (bisW + 24) or 0))
    else
        b.ready:Hide()
    end
end

-- A face shows the raid in progress, raid v, or nothing planned. The phase that matters for v is its own: a Phase 2
-- raid's readiness asks for Phase 2 lists even while the guild phase is still 1.
function fillFace(f, ctx, v)
    hideAnswer(f)
    if ctx.session then
        fillSession(f, ctx)
    elseif v then
        local rc = setmetatable({ raid = v }, { __index = ctx })
        local target = itemRaidFor(v)
        local phase, raidPhase = guildPhase(), target.phase
        if raidPhase and raidPhase > phase then phase = min(raidPhase, ns.MAX_PHASE or 5) end
        if phase ~= ctx.phase then rc.phase, rc.bis = phase, bisSummary(phase) end
        fillRaid(f, rc)
    else
        fillNone(f)
    end
end

-- Draws the shown raid again (the soonest when it is gone); a refresh during a slide waits for its end.
function refreshBanner(b, ctx)
    b.ctx = ctx
    if b.anim then
        b.stale = true
        return
    end
    local list = ctx.slides
    local at
    for i, v in ipairs(list) do
        if v.id == b.shownId then at = i end
    end
    if not at then b.hold = 0 end
    b.at = at or 1
    b.shownId = list[b.at] and list[b.at].id
    fillFace(b.face, ctx, list[b.at])
    b:PlaceFace(b.face, 0)
    b.face:SetAlpha(1)
    b.face:Show()
    for _, f in ipairs(b.faces) do
        if f ~= b.face then f:Hide() end
    end
    b:LayoutStrip()
    UI():SetEdgeColor(b, EDGE[1], EDGE[2], EDGE[3], 0.7)
end

---------------------------------------------------------------------------
-- Calendar: a month (Monday first) with a dot per event on its day; beside it the picked day's events and the raids
-- coming up. Planned raids (the Raids tab keeps them 15 days after they start; weekly ones show every week ahead),
-- the raid log's raids (kept a year; a member has the ones they were in) and dungeon runs listed for later. A raid
-- opens in the Raids tab: planned ones in Upcoming, logged ones in the Raid log for its members.
---------------------------------------------------------------------------

local WEEKDAYS = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }

-- "Today · Sat 4 Oct", "Wednesday 8 Oct".
local function dayTitle(key)
    local y, m, d = keyDate(key)
    local t = noon(y, m, d)
    local short = date("%a ", t) .. d .. date(" %b", t)
    local away = daysAway(t)
    if away == 0 then return "Today · " .. short end
    if away == 1 then return "Tomorrow · " .. short end
    if away == -1 then return "Yesterday · " .. short end
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
    local total = RL and RL.GetBossTotal and RL:GetRecordBossTotal(rec)
    if total then return ("%d/%d bosses"):format(kills, total) end
    return kills == 1 and "1 boss" or (kills .. " bosses")
end

-- A dungeon run's status: mine, I'm in, else the places still open ("needs healer, 2 DPS" / "full").
local function runState(run)
    local R = DR()
    if run.o == Me() then return "your run", "ffd100" end
    if R:IsInRun(run) then return "you're in", STATUS.A.color end
    local open, parts = R:GetOpenRoles(run), {}
    for _, role in ipairs(R.ROLES) do
        local n = open[role]
        if n then parts[#parts + 1] = (n > 1 and (n .. " ") or "") .. (role == "dps" and "DPS" or role) end
    end
    if #parts == 0 then return "full", C_RUN end
    return "needs " .. tconcat(parts, ", "), C_RUN
end

local function runName(run)
    local d = DR() and DR():GetDungeon(run.d)
    return d and d.name or tostring(run.d)
end

-- A guild event's status (Events tab): live, my sign-up, who won once over.
local function occState(o)
    local E = EV()
    local st = E:OccState(o)
    if st == "live" then return "live now", STATUS.A.color end
    if st == "cancelled" then return "cancelled", C_PAST end
    if st == "done" then
        local r = E:GetResult(o.id)
        return (r and r.champ) and ("won by " .. shortName(r.champ)) or "over", C_PAST
    end
    if st == "missed" then return "didn't run", C_PAST end
    if E:IsSignedUp(o.id) then return "you're signed up", C_EVENT end
    local closes = E:ClosesAt(o)
    if closes and closes <= Now() then return "sign-ups closed", C_EVENT end
    return plural(#E:GetSignups(o.id), "sign-up"), C_EVENT
end

-- An event's status words and dot colour: my answer for a raid to come, how a logged one went (grey once over).
local function eventState(ev)
    if ev.run then return runState(ev.run) end
    if ev.occ then return occState(ev.occ) end
    local rec, v = ev.rec, ev.v
    if rec then return running(rec) and "in progress" or bossText(rec), running(rec) and STATUS.A.color or C_PAST end
    if v.cancelled or v.t >= Now() - CURRENT_FOR then return answerState(v) end
    return (answerState(v)), C_PAST
end

-- The events of [from, to] by day: { [yyyymmdd] = { { t, name, v = planned raid, rec = raid log record, run } } },
-- each day by start time. A logged raid linked to a planned one on the calendar is one event.
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
    for _, run in ipairs(DR() and DR():GetRuns() or {}) do
        local t = run.at or 0
        if t > 0 and t >= from and t <= to then add({ t = t, run = run, name = runName(run) }) end
    end
    for _, o in ipairs(EV() and EV():GetOccurrences(from, to) or {}) do
        if o.at and o.def then add({ t = o.at, occ = o, name = o.def.name or "Event" }) end
    end
    for _, list in pairs(byDay) do
        tsort(list, function(a, b) return a.t < b.t end)
    end
    return byDay
end

-- Where an event leads: a logged raid to the Raid log (its members), else the planned raid; nil = nowhere.
local function eventClick(ev)
    if ev.run then return function() openRun(ev.run.id) end end
    if ev.occ then return function() openEvent(ev.occ.id) end end
    if ev.rec and seesRaidLog() then return function() openLog(ev.rec.id) end end
    if ev.v then return function() openRaid(ev.v.id) end end
    return nil
end

-- An event's tooltip: when, the sign-ups or how it went, my answer, my loot, where a click leads.
local function eventTip(ev)
    if ev.run then
        local tip = ns.DungeonsUI and ns.DungeonsUI.GetRunTip and ns.DungeonsUI:GetRunTip(ev.run) or { ev.name }
        tip[#tip + 1] = grey("Click to open it in the Dungeons tab")
        return tip
    end
    if ev.occ then
        local o, E = ev.occ, EV()
        local tip = { ev.name }
        local when = date("%A %d %B %H:%M", o.at)
        if o.at >= Now() then when = when .. " · " .. whenText(o.at) end
        tip[#tip + 1] = when
        local sub = { "hosted by " .. shortName(E:HostOf(o) or "?") }
        if o.where and o.where ~= "" then sub[#sub + 1] = o.where end
        if o.ranked then sub[#sub + 1] = "ranked" end
        tip[#tip + 1] = grey(tconcat(sub, " · "))
        local label, color = occState(o)
        tip[#tip + 1] = colorize(color, label)
        if o.note and o.note ~= "" then tip[#tip + 1] = grey("\"" .. o.note .. "\"") end
        tip[#tip + 1] = grey("Click to open it in the Events tab")
        return tip
    end
    local v, rec = ev.v, ev.rec
    local tip = { ev.name }
    if v then
        local when = date("%A %d %B %H:%M", v.t)
        if v.t >= Now() - CURRENT_FOR and not v.cancelled then when = when .. " · " .. whenText(v.t) end
        tip[#tip + 1] = when
        local sub = { (v.sz or 25) .. "-player" }
        local teams = teamsText(v)
        if teams then sub[#sub + 1] = teams end
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
            for i, t in ipairs(mine) do
                if i > 8 then tip[#tip + 1] = grey("+" .. (#mine - 8) .. " more") break end
                tip[#tip + 1] = "  " .. t
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

-- The art of an event's place: { file, l, r, t, b } for a w x h thumbnail.
local function eventArt(ev, w, h)
    if ev.run then
        local file, l, r, t, b = DR():GetArt(ev.run.d, w, h)
        if file then return file, l, r, t, b end
        return nil
    end
    if ev.occ then
        -- (not "return EventUI and EventUI:ArtCoords(...)": "and" keeps only the first value, the file)
        if not ns.EventUI then return nil end
        return ns.EventUI:ArtCoords(ev.occ.def.art, w, h)
    end
    local inst = ev.v and ev.v.i or (ev.rec and instKeyOf(ev.rec.instID)) or "other"
    local PUI = ns.RaidPlanUI
    if PUI and PUI.RaidArt then return PUI:RaidArt(inst, w, h, 0.5) end
    return nil
end

-- An agenda row's two lines: the event (a heroic run with its skull), then when and its status.
local SHORT_STATE = { ["Taken off this raid"] = "Taken off", ["Locked to its teams"] = "Locked" }

local function eventLines(ev, withDay)
    local label, color = eventState(ev)
    label = SHORT_STATE[label] or label
    local when = date("%H:%M", ev.t)
    if withDay then when = shortDay(ev.t) .. " · " .. when end
    if ev.run then
        return ev.name .. (ev.run.h and (" " .. HEROIC_ICON) or ""),
               grey(when .. " · " .. shortName(ev.run.o) .. " · ") .. colorize(color, label)
    end
    if ev.occ then
        local host = shortName(EV():HostOf(ev.occ) or "?")
        return label == "cancelled" and grey(ev.name) or ev.name,
               grey(when .. " · " .. host .. " · ") .. colorize(color, label)
    end
    local name = ev.name
    if ev.v and ev.v.cancelled then name = grey(name) end
    local status = colorize(color, label)
    if ev.rec and not running(ev.rec) then
        status = grey(label .. " · " .. duration(endOf(ev.rec) - ev.rec.start))
    end
    return name, grey(when .. " · ") .. status
end

local function Row_OnEnter(self)
    if self.itemID then
        UI():SetItemTooltip(self, self.itemID)
    elseif self.tip then
        showTip(self, self.tip)
    end
end

local function Row_OnClick(self)
    if self.itemID and UI():HandleModifiedItemClick(self.itemID) then return end
    if self.onClick then self.onClick() end
end

local function newAgendaRow(card)
    local r = CreateFrame("Button", nil, card)
    r:SetHeight(THUMB_H)
    r.thumb = r:CreateTexture(nil, "ARTWORK", nil, 0)
    r.thumb:SetSize(THUMB_W, THUMB_H)
    r.thumb:SetPoint("LEFT", 0, 0)
    r.fade = r:CreateTexture(nil, "ARTWORK", nil, 1)
    r.fade:SetPoint("TOPRIGHT", r.thumb, "TOPRIGHT")
    r.fade:SetPoint("BOTTOMRIGHT", r.thumb, "BOTTOMRIGHT")
    r.fade:SetWidth(floor(THUMB_W * 0.45))
    gradient(r.fade, "HORIZONTAL", PANEL_BG, 0, 1)
    r.l1 = text(r, 12, "GameFontHighlight")
    r.l2 = text(r, 11, "GameFontHighlightSmall")
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.06)
    r:SetScript("OnEnter", Row_OnEnter)
    r:SetScript("OnLeave", hideTip)
    r:SetScript("OnClick", Row_OnClick)
    return r
end

-- Sets a text that may take a second line (never "..."); true when it does. The wrap is set before the text: the
-- game keeps the layout it made when the text was set.
local function setLines(fs, s, width)
    fs:SetWidth(width)
    fs:SetWordWrap(true)
    if fs.SetMaxLines then fs:SetMaxLines(2) end
    fs:SetText(s or "")
    return strW(fs) > width
end

-- Fills an agenda row: { l1, l2, ev (its art), tip, onClick, past }; returns its height. A line too long for the row
-- takes two (the row grows).
local function fillAgendaRow(r, d, width)
    local thumb = d.ev and true or false
    local x = thumb and (THUMB_W + 8) or 0
    local textW = width - x
    r.thumb:SetShown(thumb)
    r.fade:SetShown(thumb)
    if thumb then
        local file, l, rr, t, b = eventArt(d.ev, THUMB_W, THUMB_H)
        if file then
            r.thumb:SetTexture(file)
            r.thumb:SetTexCoord(l, rr, t, b)
        else
            r.thumb:SetColorTexture(0.15, 0.15, 0.17, 1)
        end
        r.thumb:SetDesaturated(d.past and true or false)
        r.thumb:SetAlpha(d.past and 0.6 or 1)
    end
    local tall = setLines(r.l1, d.l1, textW)
    local tall2 = setLines(r.l2, d.l2, textW)
    local hasL2 = (d.l2 or "") ~= ""
    local textH = (tall and 30 or 15) + (hasL2 and (tall2 and 28 or 14) or 0)
    local h = max(thumb and THUMB_H or 15, textH)
    -- (a size of its own: a frame anchored by one corner has none, and the game draws nothing of it)
    r:SetSize(width, h)
    r.l1:ClearAllPoints()
    r.l1:SetPoint("TOPLEFT", x, -floor((h - textH) / 2))
    r.l2:ClearAllPoints()
    r.l2:SetPoint("TOPLEFT", r.l1, "BOTTOMLEFT", 0, -1)
    r.tip, r.onClick = d.tip, d.onClick
    r:EnableMouse((d.tip or d.onClick) and true or false)
    return h
end

local function showDay(key)
    cal.day = key
    cal.y, cal.m = floor(key / 10000), floor(key / 100) % 100
    Dashboard:Refresh()
end

-- The rows of a list (rows: the pool; items: what to show) from y down to at most `bottom`; when the rest doesn't fit,
-- the last row says how many more there are (more = fn(rest) -> its row). Returns the y under the last row shown.
local function layoutRows(card, pool, items, y, bottom, width, more)
    local used = 0
    for i, d in ipairs(items) do
        local r = pool[i]
        if not r then
            r = newAgendaRow(card)
            pool[i] = r
        end
        local h = fillAgendaRow(r, d, width)
        local last = false
        if i < #items and more and y + h + ROW_GAP + THUMB_H > bottom then
            -- no room for another row after this one: this one says what else there is
            h = fillAgendaRow(r, more(i), width)
            last = true
        end
        if y + h > bottom then break end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", card, "TOPLEFT", AGENDA_X, -y)
        r:Show()
        y = y + h + ROW_GAP
        used = i
        if last then break end
    end
    for j = used + 1, #pool do
        local r = pool[j]
        r:Hide()
        r.tip, r.onClick = nil, nil
    end
    return y, used
end

local function refreshCalendar(card, ctx)
    local now = Now()
    local today = dayKey(now)
    local ty, tm = dayOf(now)
    local y, m = cal.y or ty, cal.m or tm
    local picked = cal.day or today
    card.title:SetText(date("%B %Y", noon(y, m, 1)))
    -- the 6 weeks around the month, Monday first
    local lead = (date("*t", noon(y, m, 1)).wday + 5) % 7
    local from = midnight(y, m, 1 - lead)
    local to = midnight(y, m, 1 - lead + 42) - 1
    local byDay = calendarEvents(from, to)
    local H = card:GetHeight()
    if not H or H < 100 then H = LOWER_H end
    -- only the month's weeks, sharing the height (at most CELL_H each)
    local days = tonumber(date("%d", midnight(y, m + 1, 1) - 1))
    local weeks = math.ceil((lead + days) / 7)
    local rowH = min(CELL_H, floor((H - GRID_Y - 10) / weeks))
    local pr, pg, pb = hexRGB(C_PAST)
    for i, c in ipairs(card.cells) do
        local row = floor((i - 1) / 7)
        c:ClearAllPoints()
        c:SetSize(CELL_W, rowH)
        c:SetPoint("TOPLEFT", GRID_X + ((i - 1) % 7) * CELL_W, -(GRID_Y + row * rowH))
        c:SetShown(row < weeks)
        local cy, cm, cd = dayOf(noon(y, m, i - lead))
        local key = cy * 10000 + cm * 100 + cd
        c.key = key
        c.num:SetText(cd)
        local inMonth = cm == m
        -- today: a gold disc; the picked day: a soft one
        if key == today then
            c.disc:SetVertexColor(1, 0.82, 0, 1)
            c.num:SetTextColor(0.09, 0.07, 0.02)
            c.num:SetShadowOffset(0, 0)
        else
            c.disc:SetVertexColor(1, 1, 1, 0.14)
            local shade = (key == picked and 1) or (inMonth and 0.86) or 0.3
            c.num:SetTextColor(shade, shade, shade)
            c.num:SetShadowOffset(1, -1)
        end
        c.disc:SetShown(key == today or key == picked)
        local list = byDay[key] or {}
        local n = min(#list, MAX_DOTS)
        for j, dot in ipairs(c.dots) do
            if j <= n then
                if inMonth then
                    local _, color = eventState(list[j])
                    dot:SetVertexColor(hexRGB(color))
                else
                    dot:SetVertexColor(pr, pg, pb, 0.6)
                end
                dot:ClearAllPoints()
                dot:SetPoint("CENTER", c, "TOP", (j - (n + 1) / 2) * 7, -(DISC_Y + DISC / 2 + 5))
                dot:Show()
            else
                dot:Hide()
            end
        end
        c.events = list
    end
    -- the arrows stop where there is nothing to show: a year back, 180 days ahead
    card.prevMonth:SetShown(midnight(y, m, 1) - 1 >= now - CAL_BACK)
    card.nextMonth:SetShown(midnight(y, m + 1, 1) <= now + CAL_AHEAD)
    card.todayBtn:SetShown(picked ~= today or y ~= ty or m ~= tm)

    local bottom = H - 10
    local width = CAL_W - AGENDA_X - 10

    -- the raids coming up (not the banner's week, not the picked day's): what the old Later raids card listed
    local onBanner = {}
    for _, v in ipairs(ctx.slides) do onBanner[v.id] = true end
    local coming = {}
    for _, v in ipairs(ctx.raids) do
        if not onBanner[v.id] and dayKey(v.t) ~= picked then
            local ev = { t = v.t, v = v, name = RP():GetRaidName(v) }
            local l1, l2 = eventLines(ev, true)
            coming[#coming + 1] = { l1 = l1, l2 = l2, ev = ev, tip = eventTip(ev), onClick = eventClick(ev),
                                    plain = shortDay(v.t) .. date(" %H:%M ", v.t) .. ev.name }
        end
    end

    -- the picked day
    card.dayTitle:SetText(dayTitle(picked))
    local items = {}
    for _, ev in ipairs(byDay[picked] or {}) do
        local l1, l2 = eventLines(ev)
        local past = ev.t < now - CURRENT_FOR and not (ev.rec and running(ev.rec))
        items[#items + 1] = { l1 = l1, l2 = l2, ev = ev, past = past, plain = date("%H:%M ", ev.t) .. ev.name,
                              tip = eventTip(ev), onClick = eventClick(ev) }
    end
    if #items == 0 then
        items[1] = { l1 = grey(picked < today and "Nothing that day." or "Nothing planned.") }
    end
    -- the day's rows leave room for the coming-up title and one raid under it
    local dayBottom = bottom - (#coming > 0 and (8 + 14 + 6 + THUMB_H) or 0)
    local yy = layoutRows(card, card.agenda, items, GRID_Y + 2, dayBottom, width, function(i)
        local names = { "More that day" }
        for j = i, #items do names[#names + 1] = items[j].plain or "" end
        return { l1 = grey("+" .. (#items - i + 1) .. " more"), tip = names }
    end)

    -- what's coming (a link to the rest on its title's row when they don't all fit)
    card.comingTitle:SetShown(#coming > 0)
    local titleY = yy - ROW_GAP + 10
    if #coming > 0 then
        card.comingTitle:ClearAllPoints()
        card.comingTitle:SetPoint("TOPLEFT", AGENDA_X, -titleY)
        yy = titleY + 14 + 6
    end
    local _, usedComing = layoutRows(card, card.coming, coming, yy, bottom, width, nil)
    local hidden = #coming - usedComing
    if #coming > 0 and hidden > 0 then
        local lines = { "Also coming" }
        for i = usedComing + 1, #coming do lines[#lines + 1] = coming[i].plain end
        lines[#lines + 1] = grey("Click to open the Raids tab")
        card.comingMore:SetLabel(hidden .. " more")
        card.comingMore.tip = lines
        card.comingMore:ClearAllPoints()
        card.comingMore:SetPoint("RIGHT", card, "TOPRIGHT", -10, -(titleY + 6))
        card.comingMore:Show()
    else
        card.comingMore:Hide()
    end
end

local function createCalendar(p)
    local cc = CreateFrame("Frame", nil, p)
    cc:SetPoint("TOPLEFT", PAD, -LOWER_Y)
    cc:SetPoint("BOTTOMLEFT", PAD, PAD)
    cc:SetWidth(CAL_W)
    flatBox(cc)
    p.calCard = cc
    cc.agenda, cc.coming = {}, {}
    cc.title = text(cc, 13, "GameFontNormal")
    cc.title:SetPoint("LEFT", cc, "TOPLEFT", 10, -HEAD_H / 2)
    local rule = cc:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(1, 1, 1, 0.07)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 1, -HEAD_H)
    rule:SetPoint("TOPRIGHT", -1, -HEAD_H)
    -- the months: flat chevrons, gold on hover
    local function arrow(dir, delta)
        local b = CreateFrame("Button", nil, cc)
        b:SetSize(20, 20)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(10, 10)
        b.icon:SetPoint("CENTER")
        chevron(b.icon, dir)
        b.icon:SetVertexColor(0.74, 0.74, 0.74)
        b:SetScript("OnClick", function()
            local ty, tm = dayOf(Now())
            local t = date("*t", noon(cal.y or ty, (cal.m or tm) + delta, 1))
            cal.y, cal.m = t.year, t.month
            Dashboard:Refresh()
        end)
        b:SetScript("OnEnter", function(self)
            self.icon:SetVertexColor(1, 0.82, 0)
            showTip(self, { delta < 0 and "Previous month" or "Next month" }, "ANCHOR_TOP")
        end)
        b:SetScript("OnLeave", function(self)
            self.icon:SetVertexColor(0.74, 0.74, 0.74)
            hideTip()
        end)
        return b
    end
    cc.nextMonth = arrow("right", 1)
    cc.nextMonth:SetPoint("RIGHT", cc, "TOPRIGHT", -6, -HEAD_H / 2)
    cc.prevMonth = arrow("left", -1)
    cc.prevMonth:SetPoint("RIGHT", cc, "TOPRIGHT", -6 - 20 - 2, -HEAD_H / 2)
    cc.todayBtn = newLink(cc, "Today", function()
        cal = {}
        Dashboard:Refresh()
    end)
    cc.todayBtn.chev:Hide()
    cc.todayBtn:SetPoint("RIGHT", cc, "TOPRIGHT", -6 - 42 - 10, -HEAD_H / 2)
    local line = cc:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.06)
    line:SetWidth(1)
    line:SetPoint("TOPLEFT", RULE_X, -(HEAD_H + 10))
    line:SetPoint("BOTTOMLEFT", RULE_X, 10)
    for i, letter in ipairs(WEEKDAYS) do
        local fs = text(cc, 10, "GameFontHighlightSmall")
        fs:SetTextColor(0.5, 0.5, 0.5)
        fs:SetPoint("TOPLEFT", GRID_X + (i - 1) * CELL_W, -(HEAD_H + 8))
        fs:SetWidth(CELL_W)
        fs:SetJustifyH("CENTER")
        fs:SetText(letter)
    end
    cc.cells = {}
    for i = 1, 42 do
        -- (placed and sized by refreshCalendar: the month's weeks share the height)
        local c = CreateFrame("Button", nil, cc)
        c:SetSize(CELL_W, CELL_H)
        c:SetPoint("TOPLEFT", GRID_X + ((i - 1) % 7) * CELL_W, -(GRID_Y + floor((i - 1) / 7) * CELL_H))
        c.disc = c:CreateTexture(nil, "BACKGROUND")
        c.disc:SetTexture(DISC_TEX)
        c.disc:SetSize(DISC, DISC)
        c.disc:SetPoint("CENTER", c, "TOP", 0, -DISC_Y)
        local hl = c:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture(DISC_TEX)
        hl:SetSize(DISC, DISC)
        hl:SetPoint("CENTER", c, "TOP", 0, -DISC_Y)
        hl:SetVertexColor(1, 1, 1, 0.08)
        c.num = text(c, 12, "GameFontHighlight")
        c.num:SetJustifyH("CENTER")
        c.num:SetShadowOffset(1, -1)
        c.num:SetPoint("CENTER", c, "TOP", 0, -DISC_Y)
        c.dots = {}
        for j = 1, MAX_DOTS do
            local dot = c:CreateTexture(nil, "OVERLAY")
            dot:SetTexture(DISC_TEX)
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
            showTip(self, lines)
        end)
        c:SetScript("OnLeave", hideTip)
        cc.cells[i] = c
    end
    cc.dayTitle = text(cc, 12, "GameFontHighlight")
    cc.dayTitle:SetPoint("TOPLEFT", AGENDA_X, -(HEAD_H + 7))
    cc.comingTitle = text(cc, 11, "GameFontHighlightSmall")
    cc.comingTitle:SetTextColor(0.62, 0.62, 0.62)
    cc.comingTitle:SetText("Coming up")
    cc.comingMore = newLink(cc, "1 more", function() openRaid(nil) end)
end

---------------------------------------------------------------------------
-- Loot: the newest awards (the council: everyone's, with the way to the Loot log; a raider: their own)
---------------------------------------------------------------------------

local function newLootRow(card)
    local r = CreateFrame("Button", nil, card)
    r:SetHeight(LOOT_ROW_H)
    r.iconFrame = CreateFrame("Frame", nil, r)
    r.iconFrame:SetSize(26, 26)
    r.iconFrame:SetPoint("LEFT", 10, 0)
    r.icon = r.iconFrame:CreateTexture(nil, "ARTWORK")
    r.icon:SetAllPoints()
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    UI():AddEdges(r.iconFrame, "OVERLAY")
    r.l1 = text(r, 12, "GameFontHighlight")
    r.l1:SetPoint("TOPLEFT", 10 + 26 + 9, -4)
    r.l1:SetPoint("RIGHT", -10, 0)
    r.l2 = text(r, 11, "GameFontHighlightSmall")
    r.l2:SetPoint("TOPLEFT", r.l1, "BOTTOMLEFT", 0, -2)
    r.ago = text(r, 11, "GameFontHighlightSmall")
    r.ago:SetTextColor(0.62, 0.62, 0.62)
    r.ago:SetJustifyH("RIGHT")
    r.ago:SetPoint("TOPRIGHT", r.l1, "BOTTOMRIGHT", 0, -2)
    r.l2:SetPoint("RIGHT", r.ago, "LEFT", -6, 0)
    r.rule = r:CreateTexture(nil, "ARTWORK")
    r.rule:SetColorTexture(1, 1, 1, 0.045)
    r.rule:SetHeight(1)
    r.rule:SetPoint("BOTTOMLEFT", 1, 0)
    r.rule:SetPoint("BOTTOMRIGHT", -1, 0)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.06)
    r:SetScript("OnEnter", Row_OnEnter)
    r:SetScript("OnLeave", hideTip)
    r:SetScript("OnClick", Row_OnClick)
    return r
end

local function refreshLoot(card)
    local L = ns.Ledger
    local council = isCouncil() or isDemo()
    card.link:SetShown(council)
    local entries = {}
    if L then
        if council then
            entries = L:GetVisibleEntries()
        elseif Me() then
            entries = L:GetEntries({ player = Me() })
        end
    end
    card.title:SetText(council and "Recent loot" or "Your loot")
    local H = card:GetHeight()
    if not H or H < 100 then H = LOWER_H end
    local fit = floor((H - HEAD_H - 1) / LOOT_ROW_H)
    local n = min(#entries, fit)
    for i = 1, max(n, #card.rows) do
        local r = card.rows[i]
        local e = entries[i]
        if i <= n and e then
            if not r then
                r = newLootRow(card)
                card.rows[i] = r
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, -(HEAD_H + 1 + (i - 1) * LOOT_ROW_H))
            r:SetPoint("TOPRIGHT", 0, -(HEAD_H + 1 + (i - 1) * LOOT_ROW_H))
            local icon = ns.ItemDB and ns.ItemDB:GetIcon(e.i)
            r.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            local q = ns.ItemDB and ns.ItemDB.GetQuality and ns.ItemDB:GetQuality(e.i)
            local qr, qg, qb = UI():QualityColor(q)
            UI():SetEdgeColor(r.iconFrame, qr, qg, qb, q and 0.85 or 0.4)
            r.l1:SetText(UI():ItemText(e.i))
            setSize(r.l1, 12)
            if strW(r.l1) > LOOT_W - 45 - 10 then setSize(r.l1, 11) end
            -- who (the council) or where from (my own), and why; a disenchant / bank award says only that
            local reason = e.r and REASON[e.r]
            local why = reason and colorize(reason[2], reason[1]) or nil
            local l2
            if reason and (e.r == "de" or e.r == "bank") then
                l2 = why
            elseif council then
                l2 = ((e.w == Me()) and colorize(STATUS.A.color, "You") or UI():ColoredName(e.w))
                    .. (why and (grey(" · ") .. why) or "")
            else
                local ref = ns.ItemDB and ns.ItemDB.GetBossRef and ns.ItemDB:GetBossRef(e.b)
                local boss = ref and ref.boss and (ref.boss.isTrash and "Trash" or ref.boss.name)
                local parts = {}
                if why then parts[#parts + 1] = why end
                if boss then parts[#parts + 1] = grey(boss) end
                l2 = tconcat(parts, grey(" · "))
            end
            r.l2:SetText(l2 or "")
            r.ago:SetText(agoText(e.ts))
            r.rule:SetShown(i < n)
            r.itemID = e.i
            r:Show()
        elseif r then
            r:Hide()
            r.itemID = nil
        end
    end
    card.empty:SetShown(n == 0)
    card.empty:SetText(council and "No awards recorded yet." or "No loot awarded to you yet.")
end

local function createLoot(p)
    local lc = CreateFrame("Frame", nil, p)
    lc:SetPoint("TOPRIGHT", -PAD, -LOWER_Y)
    lc:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    lc:SetWidth(LOOT_W)
    flatBox(lc)
    p.lootCard = lc
    lc.rows = {}
    lc.title = text(lc, 13, "GameFontNormal")
    lc.title:SetPoint("LEFT", lc, "TOPLEFT", 10, -HEAD_H / 2)
    local rule = lc:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(1, 1, 1, 0.07)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 1, -HEAD_H)
    rule:SetPoint("TOPRIGHT", -1, -HEAD_H)
    lc.link = newLink(lc, "Loot log", function() openTab("loot") end)
    lc.link:SetPoint("RIGHT", lc, "TOPRIGHT", -10, -HEAD_H / 2)
    lc.empty = text(lc, 12, "GameFontHighlight")
    lc.empty:SetTextColor(0.55, 0.55, 0.55)
    lc.empty:SetPoint("TOPLEFT", 10, -(HEAD_H + 12))
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
        slides = {},
    }
    -- The banner's raids: today's and the next 6 days' (none of those: the soonest alone); the raid in progress
    -- instead while a session runs.
    if not ctx.session then
        for _, v in ipairs(raids) do
            if daysAway(v.t) < WEEK_DAYS then ctx.slides[#ctx.slides + 1] = v end
        end
        if #ctx.slides == 0 then ctx.slides[1] = raids[1] end
    end
    -- The phase that matters is the raid's (the one I stand in, else the next): a Phase 2 raid needs the Phase 2 list
    -- even while the guild phase is still 1, and an older raid keeps the guild's current phase.
    local here = currentItemRaid()
    local raidPhase = (here and tonumber(here.phase)) or (ctx.raid and itemRaidFor(ctx.raid).phase) or nil
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
    layoutChips(collectActions(ctx))
    refreshBanner(panel.banner, ctx)
    refreshCalendar(panel.calCard, ctx)
    refreshLoot(panel.lootCard)
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
    p.elapsed, p.dirty = 0, true
    createHello(p)
    createBanner(p)
    createCalendar(p)
    createLoot(p)
    -- the lower boxes stretch to the page's bottom: their rows need the real height
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
        "DUNGEON_RUNS_UPDATED", "EVENTS_UPDATED",
    }) do
        ns:On(msg, function() Dashboard:RequestRefresh() end)
    end
    ns:RegisterSlash("home", function() ns.MainFrame:Open("home") end, "open the Home dashboard")
end
