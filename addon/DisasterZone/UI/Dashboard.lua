if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Dashboard.lua", ...) then return end -- DisasterZone: UI/Dashboard.lua
-- The "Home" tab: the page the main window opens on. A Board page (UI:CreateLayout "board"); only what needs
-- attention now, top to bottom:
--   the toolbar: the greeting and the action chips (UI:CreateChip: unanswered raids, an empty BiS phase, players
--     asking to join my run or a run that needs me, a newer DisasterZone, what's new, the BiS lock);
--   the board's hero: the raids of the coming week as a carousel of page banners (UI:CreatePageBanner, the Raids
--     board's hero): when, the raid, who leads, the answers by role, my answer as its pill, Accept / Tentative as its
--     actions and "···" as its tool; on its foot the raid's note, my BiS picks that can drop there and, for the
--     council and the raid organizers, what isn't ready yet. It slides to the next raid every few seconds (not while
--     the mouse is on it); a strip of bars and two arrows at its top right pick one. While a raid session runs, the
--     raid in progress instead;
--   the body: a card with the month calendar of the planned and logged raids, the dungeon runs listed for later and
--     the guild's own events (the Events tab, purple dots), the picked day's events and the raids coming up beside it
--     (art rows under section headers);
--   the side card: recent loot (the council: everyone's; a raider: their own).
-- Every block opens the tab with the details. Read-only apart from the answer buttons. The online count is in the
-- sync icon's tooltip (UI/MainFrame.lua).
local addonName, ns = ...

local Dashboard = ns:NewModule("Dashboard")

local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat
local S = ns.Style

local HOUR, DAY = 3600, 86400
local CURRENT_FOR = 6 * HOUR       -- a raid counts as "next" until this long after it started (Raids tab: same)
local TICK = 30                     -- seconds between countdown refreshes while the tab is shown
local WEEK_DAYS = 7                 -- the banner flips through the raids of today and the next 6 days
local FLIP_EVERY = 8                -- seconds a raid stays on the banner before the next one slides in
local FLIP_TIME = 0.6               -- the slide from one raid to the next

-- The page is a Board (S.PAGE_W x S.PAGE_H): the toolbar row, the hero (a page banner and its foot), then the
-- calendar card in the body and the loot in the side card, down to the page's bottom.
local INNER_W = S.INNER_W                        -- 770
local FOOT_H = 46                                -- the hero's foot (note, BiS / readiness line), when it has lines
local BANNER_H = S.BANNER.hero + FOOT_H          -- 174: the hero never changes height; its foot is part of it
local LOOT_W = 280                               -- the side card
local CAL_W = INNER_W - LOOT_W - S.GAP           -- 482: the body
local LOWER_H = S.PAGE_H - 36 - BANNER_H - S.GAP - 4   -- 326: the cards' height before the first layout
local HEAD_H = 28                                -- a card's section header (24, from 4 down) and its hairline
local BX = 14                                    -- the banner's inner margin (UI:CreatePageBanner's)
local CELL_W, CELL_H = 28, 44                    -- a calendar day (at most: the month's weeks share the height)
local GRID_X, GRID_Y = S.IN, HEAD_H + 8 + 16     -- the first week (under the weekday letters)
local RULE_X = GRID_X + 7 * CELL_W + S.IN        -- 212: the line between the month and the day's list
local AGENDA_X = RULE_X + S.IN                   -- 220
local AGENDA_W = CAL_W - AGENDA_X - S.IN         -- 254
local DISC, DISC_Y = 24, 15                      -- today's / the picked day's disc, its centre under the cell's top
local DISC_TEX = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local ROW_GAP = 2
local MAX_DOTS = 3
local CAL_BACK = 365 * DAY          -- the raid log keeps raids a year
local CAL_AHEAD = 180 * DAY         -- raids are planned at most 180 days ahead

-- The answers: their words and colours (ns.Style tokens), and the banner pill's kind for my answer.
local STATUS = {
    A = { label = "Accepted", button = "Accept", color = "OK" },
    T = { label = "Tentative", button = "Tentative", color = "GOLD" },
    B = { label = "Bench", button = "Bench", color = "YOU" },
    X = { label = "Absent", button = "Absent", color = "BAD" },
}
local STATUS_ORDER = { "A", "T", "B", "X" }
-- the dots and the status words of the calendar (Style tokens; the guild's own events in the Events tab's purple)
local C_NEED, C_OPEN, C_PAST, C_RUN, C_LOCK = "WARN", "TEXT", "SUB", "YOU", "SUB"
local C_EVENT = { 0.73, 0.55, 1 }  -- uniformity: the Events tab's purple (no Style token)

local PILL_ICON = {
    A = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12|t",
    T = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:12|t",
    X = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:12|t",
}
-- my answer as the banner's pill (the Raids board's kinds and words)
local ANSWER_KIND = { A = "ok", T = "warn", B = "alt", X = "live", R = "review" }
local ANSWER_TEXT = { A = "Accepted", T = "Tentative", B = "Bench", X = "Absent", R = "Asked to join" }
local HEROIC_ICON = "|TInterface\\LFGFrame\\UI-LFG-ICON-HEROIC:14:11:0:0:32:32:0:16:0:20|t"

local REASON = {
    bis = { "BiS", "GOLD" }, alt = { "Alt", "YOU" }, up = { "Upgrade", "TEXT" }, os = { "Offspec", C_EVENT },
    de = { "Disenchanted", "SUB" }, bank = { "Guild bank", "SUB" },
}

local panel
local cal = {}      -- the calendar: y, m = the month shown, day = the picked day (yyyymmdd); nil = today's

local function UI() return ns.UI end
local function RP() return ns.RaidPlan end
local function DR() return ns.DungeonRuns end
local function EV() return ns.Events end
local Now = ns.Util.Now
local function Me() return ns.Util.PlayerKey() end
local function nameOf(key) return ns.Util.ShortName(key) or tostring(key) end
-- text in a Style token's colour, or in a { r, g, b } (the events' purple)
local function tint(c, text)
    if type(c) == "table" then return UI():Colorize(tostring(text), c) end
    return S:Wrap(c, text)
end
local function dim(text) return S:Wrap("SUB", text) end

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
-- Tooltips: a frame's lines in its .tip field (a list, or a function returning one), shown by UI:AttachTooltip
-- (the first line gold, the rest white)
---------------------------------------------------------------------------

local function tipFromField(self)
    local lines = self.tip
    if type(lines) == "function" then lines = lines() end
    if type(lines) ~= "table" then return false end
    UI():SetTextTooltip(self, lines, self.tipAnchor)
end

local function attachTip(f, anchor)
    f.tipAnchor = anchor
    UI():AttachTooltip(f, tipFromField, nil, { anchor = anchor })
    return f
end

local function showTip(owner, lines, anchor)
    if type(lines) == "function" then lines = lines() end
    if lines then UI():SetTextTooltip(owner, lines, anchor) end
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

-- The raids from now on (and the ones that started at most 6 hours ago), not cancelled or hidden, soonest first.
local function nextRaids()
    local out = {}
    local rp = RP()
    if not (rp and rp.GetRaids) then return out end
    for _, v in ipairs(rp:GetRaids(Now() - CURRENT_FOR)) do
        if not v.cancelled and not (rp.IsRaidHidden and rp:IsRaidHidden(v)) then out[#out + 1] = v end
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
            tip[#tip + 1] = dim("+" .. (#drops - 15) .. " more")
            break
        end
        tip[#tip + 1] = UI():ItemText(d.itemID) .. (d.which == "alt" and dim(" (alt)") or "")
            .. dim(" - " .. d.boss .. (d.via == "token" and " (token)" or ""))
    end
    tip[#tip + 1] = dim("Click to open My BiS")
    return { text = (#drops == 1 and "1 of your P%d picks can drop here" or (#drops .. " of your P%d picks can drop here"))
                        :format(phase),
             tip = tip, onClick = function() openMyBiS(phase) end }
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
    if kind == "R" then return "Asked to join", "GOLD" end
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
    return ns.ItemDB:RaidShort(v.i) or RP():GetRaidName(v)
end

-- My answer as a pill marker: a ready-check icon, "!" when I'm invited and haven't answered.
local function myMarker(v)
    local rp = RP()
    local mine = rp:GetMySignup(v.id)
    if mine then return PILL_ICON[mine.st] or tint(STATUS.B.color, "B") end
    local inv = rp:GetInvited(v)
    if inv and inv[Me() or ""] then return tint(C_NEED, "!") end
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
        names[#names + 1] = nameOf(key)
    end
    return tconcat(names, ", ")
end

-- The actions that need me now: { text, kind = warn | info | bad | plain, icon, tip = { lines }, onClick }.
-- The notification center's items that show on Home (Core/Notify.lua, kinds with home = true): what waits for me
-- first, then the news (what's new, a newer version). A kind's chip(it) gives the chip's look; the text is its short.
-- Several items of one kind make one chip (three polls are "3 polls waiting", not three chips): the kind's
-- chipGroup(items) gives its text (else "<label> (n)"), the look is its first item's chip, the tip lists them all and a
-- click runs the kind's openGroup(items), else opens its page.
local GROUP_TIP_MAX = 10

local function kindChip(def, it)
    if not def.chip then return {} end
    local ok, r = pcall(def.chip, it)
    return ok and type(r) == "table" and r or {}
end

local function groupChip(N, def, items)
    local c = kindChip(def, items[1])
    local g
    if def.chipGroup then
        local ok, r = pcall(def.chipGroup, items)
        if ok then g = r end
    end
    if type(g) == "string" then g = { text = g } end
    g = type(g) == "table" and g or {}
    local tip = { g.title or def.label }
    for i, it in ipairs(items) do
        if i > GROUP_TIP_MAX then
            tip[#tip + 1] = dim("+" .. (#items - GROUP_TIP_MAX) .. " more")
            break
        end
        tip[#tip + 1] = (it.title or it.short or "") .. (it.from and dim("  " .. nameOf(it.from)) or "")
    end
    tip[#tip + 1] = dim("Click to see them all.")
    local onClick
    if def.openGroup or def.page then
        onClick = function()
            for _, it in ipairs(items) do N:MarkSeen(it.id) end
            if def.openGroup then
                local ok, err = pcall(def.openGroup, items)
                if not ok then ns:Debug("Notify openGroup %s failed: %s", def.kind, tostring(err)) end
            elseif ns.MainFrame then
                ns.MainFrame:Open(def.page)
            end
        end
    end
    return { text = g.text or (def.label .. " (" .. #items .. ")"), kind = g.kind or c.kind or "plain",
             icon = g.icon or c.icon, tip = g.tip or tip, onClick = onClick }
end

local function feedChips(out)
    local N = ns.Notify
    if not (N and N.IsLoaded and N:IsLoaded()) then return end
    local groups, order = {}, {}
    for _, it in ipairs(N:List({ home = true })) do
        local g = groups[it.kind]
        if not g then
            g = {}
            groups[it.kind] = g
            order[#order + 1] = it.kind
        end
        g[#g + 1] = it
    end
    for _, kind in ipairs(order) do
        local items, def = groups[kind], N:GetKind(kind) or {}
        if #items > 1 then
            out[#out + 1] = groupChip(N, def, items)
        else
            local it = items[1]
            local c = kindChip(def, it)
            local tip = { it.title or "" }
            if it.text and it.text ~= "" then tip[#tip + 1] = it.text end
            local id = it.id
            out[#out + 1] = { text = c.text or it.short or it.title or "", kind = c.kind or "plain", icon = c.icon,
                              tip = c.tip or tip,
                              onClick = def.open and function() N:Open(id) end or nil }
        end
    end
end

local function collectActions(ctx)
    local out = {}
    feedChips(out)
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
    local BiS = ns.BiS
    local locked, info = false, nil
    if BiS and BiS.IsLocked then locked, info = BiS:IsLocked() end
    if locked then
        local by = type(info) == "table" and info.by and nameOf(info.by) or nil
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

---------------------------------------------------------------------------
-- The toolbar: the greeting, then the action chips (UI:CreateChip)
---------------------------------------------------------------------------

local function newChip(parent)
    local c = UI():CreateChip(parent, { kind = "you", onClick = function(self) if self.onAction then self.onAction() end end })
    c.text = c.fs
    return attachTip(c, "ANCHOR_BOTTOM")
end

local function fillChip(c, a)
    c.kind, c.tip, c.onAction = a.kind or "plain", a.tip, a.onClick
    -- (a chip's look by the action's kind: UI.CHIP_LOOK plain / warn / info / bad, the "you" chip's shape)
    local CL = UI().CHIP_LOOK
    c.look = ({ plain = CL.plain, warn = CL.warn, info = CL.info, bad = CL.bad })[c.kind] or CL.plain
    local ic = a.icon
    c:SetIcon(ic and ic.tex or nil, ic and ic.coords or nil, nil, ic and ic.desat)
    c:Set(a.text)
end

-- The greeting leads the toolbar; the chips follow it while they fit (the rest behind "+N more").
local function layoutChips(list)
    panel.greeting:SetText(greetingText())
    local _, classFile = UnitClass("player")
    panel.greetName:SetText(UnitName("player") or "")
    panel.greetName:SetTextColor(UI():ClassColor(classFile))
    local x = floor(UI():TextWidth(panel.greeting) + UI():TextWidth(panel.greetName) + 14)
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
    UI():HideFrom(panel.chips, #list + 1)
    local hidden = #list - shown
    if hidden > 0 then
        local lines = { "More to do" }
        for i = shown + 1, #list do lines[#lines + 1] = list[i].text end
        panel.moreChips:Set("+" .. hidden .. " more")
        panel.moreChips.tip = lines
        panel.moreChips:ClearAllPoints()
        panel.moreChips:SetPoint("LEFT", panel.hello, "LEFT", x, 0)
        panel.moreChips:Show()
    else
        panel.moreChips:Hide()
    end
end

-- (in the layout's toolbar row: the row's middle is 17 px down)
local function createHello(p, toolbar)
    local h = CreateFrame("Frame", nil, toolbar)
    h:SetPoint("LEFT", toolbar, "TOPLEFT", S.PAD, -UI().LAYOUT.ROW_MID)
    h:SetSize(INNER_W, 26)
    p.hello = h
    p.greeting = UI():Text(h, "title", "TEXT")
    p.greeting:SetPoint("LEFT", 0, 0)
    p.greetName = UI():Text(h, "title")
    p.greetName:SetPoint("LEFT", p.greeting, "RIGHT", 0, 0)
    p.moreChips = attachTip(UI():CreateChip(h, { kind = "track" }), "ANCHOR_BOTTOM")
    p.moreChips:Hide()
    p.chips = {}
end

---------------------------------------------------------------------------
-- The hero: the raids of the coming week, one at a time (or the raid in progress, or nothing planned). The board's
-- hero frame holds two faces, each a page banner (UI:CreatePageBanner), that take turns inside a clipping frame:
-- the next raid is drawn on the hidden one, which slides in as the other slides out.
---------------------------------------------------------------------------

-- Every answer (mine ticked) and the way to the raid's page: the banner's ··· tool and my answer's pill. The
-- banner holds still while the menu is open.
local openMenu
local function answerMenu(owner, v, current)
    openMenu = UI():ContextMenu(owner, function(root)
        root:CreateTitle(RP():GetRaidName(v))
        for _, st in ipairs(STATUS_ORDER) do
            local label = (current == st and S:Wrap("OK", STATUS[st].button .. " (yours)")) or STATUS[st].button
            root:CreateButton(label, function() answer(v.id, st) end)
        end
        if root.CreateDivider then root:CreateDivider() end
        local PUI = ns.RaidPlanUI
        if PUI and PUI.AddHideEntries then PUI:AddHideEntries(root, v) end
        root:CreateButton("Open the raid", function() openRaid(v.id) end)
    end)
end

local fillFace, refreshBanner     -- (below: the faces' contents)

-- The face's actions (UI:CreatePageBanner's, the first at the far right) under the names the face keeps for them
-- (face.accept / .tentative / .ask / .action: the shown button, else a hidden stand-in).
local ACTION_NAMES = { "accept", "tentative", "ask", "action" }
local function setActions(f, list, names)
    f:SetActions(list)
    for _, n in ipairs(ACTION_NAMES) do f[n] = f.none end
    local w = 0
    for i, n in ipairs(names or {}) do
        local b = f.actions[i]
        if b then
            f[n] = b
            w = w + b:GetWidth() + (i > 1 and 6 or 0)
        end
    end
    return w
end

-- One face of the hero (the hero's size): a page banner with my answer's pill, the answers by role at its bottom
-- left and its foot (the note; my BiS picks that drop there, the readiness or the lock). A click on it is the hero's.
local function createFace(holder)
    local f = UI():CreatePageBanner(holder.clip, { size = BANNER_H, footH = 0, artFw = 1, kickerColor = "SUB",
        width = INNER_W })
    f:SetSize(INNER_W, BANNER_H)
    f.meta = f.sub
    f.none = CreateFrame("Button", nil, f)
    f.none:Hide()
    for _, n in ipairs(ACTION_NAMES) do f[n] = f.none end
    -- the ··· tool: more answers (made once, shown while I can answer)
    f.moreTools = { { icon = "more", title = "More answers", text = "Bench or Absent, or open the raid.",
                      onClick = function(btn) if f.menuFn then f.menuFn(btn) end end } }
    f:SetTools(f.moreTools)
    f.more = f.tools[1]
    f:SetTools(nil)
    -- my answer: the banner's pill (a click changes it), the spec it is for after it
    f.pill.text = f.pill.fs
    f.pill.sub = UI():Text(f, "small", "SUB")
    f.pill.sub:SetPoint("LEFT", f.pill, "RIGHT", 6, 0)
    f.pill:EnableMouse(true)
    f.pill:SetScript("OnMouseUp", function(self) if f.pillMenu then f.pillMenu(self) end end)
    UI():AttachTooltip(f.pill, "Your answer", "Click to change it.", { anchor = "ANCHOR_TOP" })
    -- why I can't answer (bottom right, where the actions would be)
    f.why = attachTip(CreateFrame("Frame", nil, f), "ANCHOR_TOP")
    f.why:SetHeight(18)
    f.why.fs = UI():Text(f.why, "emph", "SUB")
    f.why.fs:SetPoint("RIGHT", 0, 0)
    -- the answers by role (bottom left, on the actions' row)
    f.meter = UI():Text(f, "body")
    f.meterHit = attachTip(CreateFrame("Button", nil, f), "ANCHOR_BOTTOM")
    f.meterHit:SetPoint("TOPLEFT", f.meter, "TOPLEFT", 0, 2)
    f.meterHit:SetPoint("BOTTOMRIGHT", f.meter, "BOTTOMRIGHT", 0, -2)
    f.meterHit:SetScript("OnClick", function() if f.onClick then f.onClick() end end)

    -- the foot: the raid's note; my BiS picks that drop there (left), the readiness or the lock (right)
    local foot = f.foot
    foot.rule = UI():Rule(foot, { top = 0, alpha = 0.06 })
    f.note = UI():Text(foot, "body", "SUB")
    f.bis = attachTip(CreateFrame("Button", nil, foot), "ANCHOR_TOP")
    f.bis:SetHeight(16)
    f.bis.star = f.bis:CreateTexture(nil, "ARTWORK")
    f.bis.star:SetSize(12, 12)
    f.bis.star:SetPoint("LEFT", 0, 0)
    f.bis.star:SetTexture(UI():Tex("star"))
    f.bis.fs = UI():Text(f.bis, "body", "GOLD")
    f.bis.fs:SetPoint("LEFT", f.bis.star, "RIGHT", 5, 0)
    f.bis.chev = f.bis:CreateTexture(nil, "ARTWORK")
    f.bis.chev:SetSize(9, 9)
    f.bis.chev:SetPoint("RIGHT", f.bis, "RIGHT", 0, 0)
    UI():SetChevron(f.bis.chev, true)
    f.bis.chev:SetVertexColor(S:Color("GOLD"))
    f.bis:HookScript("OnEnter", function(self) self.fs:SetTextColor(S:Color("TEXT")) end)
    f.bis:HookScript("OnLeave", function(self) self.fs:SetTextColor(S:Color("GOLD")) end)
    f.bis:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
    f.ready = attachTip(CreateFrame("Button", nil, foot), "ANCHOR_TOP")
    f.ready:SetHeight(16)
    f.ready.fs = UI():Text(f.ready, "body", "SUB", { justify = "RIGHT" })
    f.ready.fs:SetPoint("RIGHT", 0, 0)
    f.ready.icon = f.ready:CreateTexture(nil, "ARTWORK")
    f.ready.icon:SetSize(13, 13)
    f.ready.icon:SetPoint("LEFT", f.ready, "LEFT", 0, 0)
    f.ready:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
    return f
end

-- The carousel's strip (top right, left of the ··· tool, over the faces): a bar per raid, the shown one long with
-- the time to the next slide filling it in gold, and an arrow on each side. A bar or an arrow slides to that raid.
local BAR_W, BAR_ON, BAR_GAP, BAR_H = 14, 32, 5, 2
local STRIP_RIGHT = 12 + 22 + 8      -- clear of the banner's ··· tool (EDGE_X 12, a 22 px tool)

local function stripArrow(holder, dir)
    local right = dir == "right"
    local a = UI():CreateArrowButton(holder.strip, right, 18, 18, function()
        holder:Flip(holder.at + (right and 1 or -1), right and 1 or -1)
    end)
    a.tip = function()
        local list = holder.ctx and holder.ctx.slides or {}
        local n = #list
        local v = n > 0 and list[((holder.at or 1) - 1 + (right and 1 or -1)) % n + 1]
        if not v then return nil end
        return { right and "Next raid" or "Previous raid",
                 RP():GetRaidName(v) .. dim(" · " .. shortDay(v.t) .. date(" %H:%M", v.t)) }
    end
    return attachTip(a, "ANCHOR_TOP")
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
    s.fill:SetColorTexture(S:Color("GOLD"))
    s:SetScript("OnClick", function() holder:Flip(i) end)
    s:SetScript("OnEnter", function(self)
        self.hot = true
        holder:PaintStrip()
    end)
    s:SetScript("OnLeave", function(self)
        self.hot = nil
        holder:PaintStrip()
    end)
    s.tip = function()
        local v = holder.ctx and holder.ctx.slides[i]
        if not v then return nil end
        local tip = { RP():GetRaidName(v), date("%a %d %b %H:%M", v.t) .. " · " .. countdown(v.t) }
        local marker = myMarker(v)
        if marker then
            local mine = RP():GetMySignup(v.id)
            tip[#tip + 1] = marker .. " " .. (mine and (ANSWER_TEXT[mine.st] or "") or "Answer needed")
        end
        tip[#tip + 1] = dim(i == holder.at and "Shown now" or "Click to show this raid")
        return tip
    end
    return attachTip(s, "ANCHOR_TOP")
end

-- easeInOutCubic: a slow start, a glide, a soft landing.
local function ease(x)
    if x < 0.5 then return 4 * x * x * x end
    local y = 2 - 2 * x
    return 1 - y * y * y / 2
end

-- The hover look: the shown face's edge in gold while it leads somewhere.
local function paintHover(b, on)
    local f = b.face
    if on and f.onClick then UI():SetEdgeColor(f, S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], 0.55)
    else UI():SetEdgeColor(f, S:Color("EDGE")) end
end

-- b: the board's hero frame (the layout's banner), made the carousel.
local function setupBanner(p, b)
    p.banner = b
    b:EnableMouse(true)
    -- the faces slide inside the hero
    b.clip = CreateFrame("Frame", nil, b)
    b.clip:SetAllPoints()
    b.clip:SetClipsChildren(true)
    b.faces = { createFace(b), createFace(b) }
    b.face = b.faces[1]
    b.faces[2]:Hide()
    b.at, b.hold = 1, 0

    b.strip = CreateFrame("Frame", nil, b)
    b.strip:SetFrameLevel(b:GetFrameLevel() + 20)
    b.strip:SetHeight(18)
    b.strip:SetPoint("RIGHT", b, "TOPRIGHT", -STRIP_RIGHT, -20)
    b.strip:Hide()
    b.prev = stripArrow(b, "left")
    b.prev:SetPoint("LEFT", 0, 0)
    b.next = stripArrow(b, "right")
    b.bars = {}

    -- a face at x (0 = in place, -INNER_W = gone to the left)
    function b:PlaceFace(f, x)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", self.clip, "TOPLEFT", floor(x + 0.5), 0)
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
        UI():SetEdgeColor(from, S:Color("EDGE"))
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
    b:SetScript("OnEnter", function(self) paintHover(self, true) end)
    b:SetScript("OnLeave", function(self) paintHover(self, false) end)
    b:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and self.face.onClick then self.face.onClick() end
    end)
end

-- Sizes the face's foot for its lines (note: 0..2 lines; f2 = the BiS / readiness line) and places them; the face
-- keeps its height either way (the art fades into the page under the foot). Returns the foot's height.
local function layoutFoot(f, noteLines, hasF2)
    local lines = noteLines + (hasF2 and 1 or 0)
    local footH = lines == 0 and 0 or max(FOOT_H, 16 + lines * 14 + (lines - 1) * 4)
    f.opts.footH = footH
    f.foot:SetHeight(max(1, footH))
    f.foot:SetShown(footH > 0)
    -- the lines, centred in the foot
    local used = lines > 0 and (noteLines * 14 + (hasF2 and 14 or 0) + (lines - 1) * 4) or 0
    local y = floor((footH - used) / 2)
    f.note:ClearAllPoints()
    f.note:SetPoint("TOPLEFT", f.foot, "TOPLEFT", BX, -y)
    f.note:SetPoint("TOPRIGHT", f.foot, "TOPRIGHT", -BX, -y)
    if noteLines > 0 then y = y + noteLines * 14 + 4 end
    f.bis:ClearAllPoints()
    f.bis:SetPoint("LEFT", f.foot, "TOPLEFT", BX, -(y + 7))
    f.ready:ClearAllPoints()
    f.ready:SetPoint("RIGHT", f.foot, "TOPRIGHT", -BX, -(y + 7))
    f:Layout()
    return footH
end

-- The note line: one line in the body size, else smaller, else two lines (a note is at most 120 characters).
local function fitNote(f, note)
    local fs = f.note
    fs:SetText('"' .. note .. '"')
    if fs.SetMaxLines then fs:SetMaxLines(1) end
    for _, style in ipairs({ "body", "small" }) do
        UI():SetTextStyle(fs, style, "SUB")
        fs:SetWordWrap(false)
        if UI():TextWidth(fs) <= INNER_W - 2 * BX then return 1 end
    end
    fs:SetWordWrap(true)
    if fs.SetMaxLines then fs:SetMaxLines(2) end
    return 2
end

-- The answers line beside the actions (aw = their width), on the actions' row above the foot.
local function placeMeter(f, footH, aw)
    f.meter:ClearAllPoints()
    f.meter:SetPoint("LEFT", f, "BOTTOMLEFT", BX, footH + 12 + floor(S.BTN_H / 2))
    f.meter:SetWidth(max(40, INNER_W - 2 * BX - aw - 16))
    f.why:ClearAllPoints()
    f.why:SetPoint("RIGHT", f, "BOTTOMRIGHT", -12, footH + 12 + floor(S.BTN_H / 2))
end

local function hideAnswer(f)
    setActions(f, nil)
    f:SetTools(nil)
    f:SetPill(nil)
    f.pill.sub:Hide()
    f.why:Hide()
    f.menuFn, f.pillMenu = nil, nil
end

-- The foot's right side: the readiness of the next raid (organizers), what's missing first.
local function fillReadiness(f, v, ctx, room)
    local items = readiness(v, ctx)
    local r = f.ready
    local tip = { "Is the raid ready?" }
    if #items == 0 then
        -- ready: nothing to say
        r:Hide()
        return
    end
    r.icon:SetTexture(UI().ICON_WARN)
    local shown = items[1].text
    local n = 1
    for i = 2, #items do
        local cand = shown .. " · " .. items[i].text
        local rest = #items - i
        r.fs:SetText(cand .. (rest > 0 and (" · +" .. rest .. " more") or ""))
        if UI():TextWidth(r.fs) > room - 18 then break end
        shown, n = cand, i
    end
    local rest = #items - n
    r.fs:SetText(shown .. (rest > 0 and (" · +" .. rest .. " more") or ""))
    r.fs:SetTextColor(S:Color("TEXT"))          -- (the warning icon says it; the words stay calm)
    for _, it in ipairs(items) do
        tip[#tip + 1] = { it.text, S:Color("WARN") }
        tip[#tip + 1] = namesLine(it.names)
    end
    tip[#tip + 1] = dim("Click to open the raid's sign-ups")
    r.tip = tip
    r.onClick = function() openRaid(v.id) end
    r:SetWidth(floor(UI():TextWidth(r.fs) + 18))
    r:Show()
end

local function fillBisLine(f, drops)
    local b = f.bis
    if not drops then
        b:Hide()
        return 0
    end
    b.fs:SetText(drops.text)
    b.fs:SetTextColor(S:Color("GOLD"))
    b.tip, b.onClick = drops.tip, drops.onClick
    local w = floor(12 + 5 + UI():TextWidth(b.fs) + 4 + 9)
    b:SetWidth(w)
    b:Show()
    return w
end

local function fillNone(f)
    local planner = RP() and RP().CanOrganize and RP():CanOrganize()
    f.art:SetAlpha(0.6)
    f:SetArt("other", true)
    f:SetKicker(nil)
    f:SetTitle("Nothing planned")
    f:SetSub(planner and "Plan the next one: it shows here for everyone."
             or "The Guild Master and the raid leaders plan raids.")
    f.meter:SetText("")
    f.meterHit.tip = nil
    local aw = 0
    if planner then
        aw = setActions(f, { { text = "Plan a raid", kind = "primary", width = 100, onClick = function()
            openRaid(nil)
            if ns.RaidPlanUI and ns.RaidPlanUI.OpenEditor then ns.RaidPlanUI:OpenEditor() end
        end } }, { "action" })
    end
    f.onClick = nil
    f.note:SetText("")
    f.bis:Hide()
    f.ready:Hide()
    placeMeter(f, layoutFoot(f, 0, false), aw)
end

local function fillSession(f, ctx)
    local s = ctx.session
    local rp = RP()
    local planned = s.rp and rp and rp.GetRaid and rp:GetRaid(s.rp) or nil
    local instID = currentInstID()
    local inst = planned and planned.i or instKeyOf(instID)
    f.art:SetAlpha(1)
    local at = tonumber(s.at)
    f:SetKicker(S:Wrap("OK", "Raid in progress") .. "    "
        .. (at and ("started " .. duration(Now() - at) .. " ago  ·  " .. date("%a %d %b · %H:%M", at)) or "in progress"))
    local zone = GetInstanceInfo and (GetInstanceInfo()) or nil
    f:SetTitle(planned and rp:GetRaidName(planned) or zone or "Raid")
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
    f:SetSub(tconcat(parts, " · "))
    -- the bosses down so far
    local RL = ns.RaidLog
    local rec = RL and RL.GetCurrentID and RL.GetRaid and RL:GetRaid(RL:GetCurrentID() or s.id)
    local kills = rec and #(rec.bosses or {}) or nil
    local total = RL and RL.GetBossTotal and RL:GetRecordBossTotal(rec, instID)
    local down = kills and (total and ("%d of %d bosses down"):format(kills, total)
                            or ((kills == 1 and "1 boss" or (kills .. " bosses")) .. " down"))
    f.meter:SetText(down or "")
    f.meterHit.tip = nil
    hideAnswer(f)
    local aw = 0
    if isCouncil() then
        aw = setActions(f, { { text = "Loot log", width = 90, onClick = function() openTab("loot") end } }, { "action" })
    end
    f.onClick = function() if planned then openRaid(planned.id) else openRaid(nil) end end
    -- the foot: what of my list can drop here; the BiS lock
    f.note:SetText("")
    local bisW = fillBisLine(f, bisDrops(currentItemRaid() or (planned and itemRaidFor(planned))))
    local Lock = UI().GetBiSLock and UI():GetBiSLock()
    if Lock then
        f.ready.icon:SetTexture(UI().ICON_LOCK)
        f.ready.fs:SetText("BiS lists locked")
        f.ready.fs:SetTextColor(S:Color("SUB"))
        f.ready.tip = { "BiS lists are locked for this raid", "Changes wait until the raid leader unlocks them." }
        f.ready.onClick = nil
        f.ready:SetWidth(floor(UI():TextWidth(f.ready.fs) + 18))
        f.ready:Show()
    else
        f.ready:Hide()
    end
    f:SetArt(inst or "other", false)
    placeMeter(f, layoutFoot(f, 0, bisW > 0 or Lock ~= nil), aw)
end

-- "IN 13 MIN    MON 21 SEP · 16:28": the hero's kicker (the Raids board's).
local function raidKicker(v)
    return S:Wrap("GOLD", countdown(v.t)) .. "    " .. date("%a ", v.t) .. tonumber(date("%d", v.t))
        .. date(" %b · %H:%M", v.t)
end

local function fillRaid(f, ctx)
    local v = ctx.raid
    local rp = RP()
    local note = v.no and v.no ~= "" and v.no or nil
    local readyFor = canSeeReadiness()
    local drops = bisDrops(itemRaidFor(v))
    local hasF2 = drops ~= nil or readyFor
    -- the foot first
    local noteLines = note and fitNote(f, note) or 0
    if not note then f.note:SetText("") end
    local footH = layoutFoot(f, noteLines, hasF2)
    f.art:SetAlpha(1)
    f:SetArt(v.i, false)
    f:SetKicker(raidKicker(v))
    f:SetTitle(rp:GetRaidName(v))

    -- my answer
    hideAnswer(f)
    local kind, block, canAnswer, canAsk, mine = myState(v)
    local id = v.id
    local aw = 0
    if STATUS[kind] or kind == "R" then
        local sub
        if kind == "R" then
            sub = "a raid leader approves"
        elseif mine and mine.sp and mine.c and ns.SPECS[mine.c] and ns.SPECS[mine.c][mine.sp] then
            sub = "as " .. ns.SPECS[mine.c][mine.sp].label
        end
        f:SetPill(ANSWER_KIND[kind] or "review", ANSWER_TEXT[kind] or "")
        f.pill.sub:SetText(sub or "")
        f.pill.sub:SetShown(sub ~= nil)
        f.pillMenu = function(owner) answerMenu(owner, v, kind) end
    elseif canAsk then
        aw = setActions(f, { { text = "Ask to join", kind = "primary", width = 100, onClick = function() answer(id, "A") end,
            tip = { "Ask to join", "Locked to its teams: whoever runs it approves or declines." } } }, { "ask" })
    elseif canAnswer then
        aw = setActions(f, { { text = STATUS.A.button, kind = "primary", onClick = function() answer(id, "A") end },
                             { text = STATUS.T.button, onClick = function() answer(id, "T") end } },
            { "accept", "tentative" })
        f:SetTools(f.moreTools)
        f.menuFn = function(owner) answerMenu(owner, v, nil) end
    else
        local words, why = blockWords(v, block)
        f.why.fs:SetText(words or "")
        f.why.tip = why and { "You can't answer", why } or nil
        f.why:SetWidth(floor(UI():TextWidth(f.why.fs) + 2))
        f.why:SetShown(words ~= nil)
        aw = words and f.why:GetWidth() or 0
    end
    placeMeter(f, footH, aw)
    local tw = INNER_W - 2 * BX - 16

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
    if nReq > 0 then parts[#parts + 1] = { S:Wrap("GOLD", plural(nReq, "request")), 10 } end
    local function metaText()
        local out = {}
        for _, p in ipairs(parts) do out[#out + 1] = p[1] end
        return tconcat(out, " · ")
    end
    while #parts > 1 and UI():TextWidth(metaText(), "body") > tw do
        local low, at = 99, nil
        for i, p in ipairs(parts) do
            if p[2] < low then low, at = p[2], i end
        end
        table.remove(parts, at)
    end
    f:SetSub(metaText())

    -- the accepted by role and how full it is (the tooltip has every answer and who hasn't answered)
    local _, counts, roles, noAnswer = signupCounts(v)
    local size = v.sz or 25
    if counts.A == 0 and counts.T == 0 then
        f.meter:SetText(dim("No answers yet"))
    else
        local function ri(role) return UI():RoleIconText(role, 13) end
        local total = ("%d of %d"):format(counts.A, size)
        f.meter:SetText(("%s %d    %s %d    %s %d      %s"):format(ri("tank"), roles.tank, ri("healer"), roles.healer,
            ri("dps"), roles.melee + roles.ranged + roles.nospec,
            (counts.A >= size and S:Wrap("OK", total) or dim(total))
            .. (counts.T > 0 and dim(" · " .. counts.T .. " tentative") or "")))
    end
    local tip = { "Answers" }
    local roleParts = {}
    for _, r in ipairs({ { "tank", "tank" }, { "healer", "healer" }, { "melee", "melee" }, { "ranged", "ranged" } }) do
        if roles[r[1]] > 0 then roleParts[#roleParts + 1] = plural(roles[r[1]], r[2]) end
    end
    tip[#tip + 1] = tint(STATUS.A.color, counts.A .. " accepted") .. (#roleParts > 0 and dim(": " .. tconcat(roleParts, ", ")) or "")
    if roles.nospec > 0 then tip[#tip + 1] = tint(C_NEED, roles.nospec .. " accepted without a spec") end
    local others = {}
    for _, st in ipairs({ "T", "B", "X" }) do
        if counts[st] > 0 then others[#others + 1] = tint(STATUS[st].color, counts[st] .. " " .. STATUS[st].label:lower()) end
    end
    if #others > 0 then tip[#tip + 1] = tconcat(others, dim(" · ")) end
    if #noAnswer > 0 then
        tip[#tip + 1] = tint(C_NEED, #noAnswer .. " invited, no response")
        tip[#tip + 1] = namesLine(noAnswer)
    end
    f.meterHit.tip = tip
    f.onClick = function() openRaid(id) end

    -- the foot's second line: my BiS picks (left), the readiness (right, organizers)
    local bisW = fillBisLine(f, drops)
    if readyFor then
        fillReadiness(f, v, ctx, INNER_W - 2 * BX - (bisW > 0 and (bisW + 24) or 0))
    else
        f.ready:Hide()
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
    paintHover(b, b:IsMouseOver())
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
    if run.o == Me() then return "your run", "GOLD" end
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
        return (r and r.champ) and ("won by " .. nameOf(r.champ)) or "over", C_PAST
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
        tip[#tip + 1] = dim("Click to open it in the Dungeons tab")
        return tip
    end
    if ev.occ then
        local o, E = ev.occ, EV()
        local tip = { ev.name }
        local when = date("%A %d %B %H:%M", o.at)
        if o.at >= Now() then when = when .. " · " .. whenText(o.at) end
        tip[#tip + 1] = when
        local sub = { "hosted by " .. nameOf(E:HostOf(o) or "?") }
        if o.where and o.where ~= "" then sub[#sub + 1] = o.where end
        if o.ranked then sub[#sub + 1] = "ranked" end
        tip[#tip + 1] = dim(tconcat(sub, " · "))
        local label, color = occState(o)
        tip[#tip + 1] = tint(color, label)
        if o.note and o.note ~= "" then tip[#tip + 1] = dim("\"" .. o.note .. "\"") end
        tip[#tip + 1] = dim("Click to open it in the Events tab")
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
        tip[#tip + 1] = dim(tconcat(sub, " · "))
        if v.cancelled then
            tip[#tip + 1] = tint("BAD", "Cancelled")
        else
            local _, counts = signupCounts(v)
            local parts = { tint(STATUS.A.color, counts.A .. " accepted") }
            if counts.T > 0 then parts[#parts + 1] = tint(STATUS.T.color, counts.T .. " tentative") end
            if counts.B > 0 then parts[#parts + 1] = tint(STATUS.B.color, counts.B .. " bench") end
            tip[#tip + 1] = tconcat(parts, " · ")
            local label, color = answerState(v)
            tip[#tip + 1] = "Your answer: " .. tint(color, label)
        end
        if v.no and v.no ~= "" then tip[#tip + 1] = dim("\"" .. v.no .. "\"") end
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
                if i > 8 then tip[#tip + 1] = dim("+" .. (#mine - 8) .. " more") break end
                tip[#tip + 1] = "  " .. t
            end
        end
    end
    if rec and seesRaidLog() then
        tip[#tip + 1] = dim("Click to open it in the Raid log")
    elseif v then
        tip[#tip + 1] = dim("Click to open it in the Raids tab")
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
               dim(when .. " · " .. nameOf(ev.run.o) .. " · ") .. tint(color, label)
    end
    if ev.occ then
        local host = nameOf(EV():HostOf(ev.occ) or "?")
        return label == "cancelled" and dim(ev.name) or ev.name,
               dim(when .. " · " .. host .. " · ") .. tint(color, label)
    end
    local name = ev.name
    if ev.v and ev.v.cancelled then name = dim(name) end
    local status = tint(color, label)
    if ev.rec and not running(ev.rec) then
        status = dim(label .. " · " .. duration(endOf(ev.rec) - ev.rec.start))
    end
    return name, dim(when .. " · ") .. status
end

local function Row_OnClick(self)
    if self.itemID and UI():HandleModifiedItemClick(self.itemID) then return end
    if self.onClick then self.onClick() end
end

-- An agenda row: the shared art row (the event's place as its picture), or a line alone ("Nothing planned.",
-- "+3 more"). r.l1 / r.l2 = its two lines, r.thumb = its picture.
local function newAgendaRow(card)
    local r = UI():CreateArtRow(card, { width = AGENDA_W })
    r.l1, r.l2, r.thumb = r.title, r.sub, r.art.tex
    -- (a status too long for the narrow column takes a second line instead of being cut)
    -- TODO(refactor): move into UI:CreateArtRow (opts.wrapSub: the second line wraps to two lines)
    local fit = r.FitTitle
    function r:FitTitle()
        fit(self)
        self.sub:SetWordWrap(self.wrapSub and true or false)
        if self.sub.SetMaxLines then self.sub:SetMaxLines(self.wrapSub and 2 or 1) end
        if self.wrapSub then
            self.sub:SetWidth(max(20, (self:GetWidth() or 0) - self.textX - 8))
            self.sub:SetText(self.subText or "")
        end
    end
    r:SetScript("OnClick", Row_OnClick)
    return attachTip(r, "ANCHOR_RIGHT")
end

-- Fills an agenda row: { l1, l2, ev (its art), tip, onClick, past }; returns its height.
local function fillAgendaRow(r, d, width)
    local ev = d.ev
    local textX = ev and (r.art:GetWidth() + 2 + 14) or 2
    r.wrapSub = ev ~= nil and (d.l2 or "") ~= "" and UI():TextWidth(d.l2, "body") > width - textX - 8
    r:SetWidth(width)
    r:SetData({ art = ev and function(tex, w, h)
                    local file, l, rr, t, b = eventArt(ev, w, h)
                    if file then
                        tex:SetTexture(file)
                        tex:SetTexCoord(l, rr, t, b)
                    else
                        tex:SetColorTexture(S:Color("INSET"))
                    end
                end or nil,
                title = d.l1 or "", sub = (d.l2 or "") ~= "" and d.l2 or nil })
    r.art:SetShown(ev ~= nil)
    r.art.tex:SetDesaturated(d.past and true or false)
    r.art:SetAlpha(d.past and 0.6 or 1)
    local h = ev and (S.ROW.art + (r.wrapSub and 12 or 0)) or S.ROW.compact
    r:SetHeight(h)
    r.textX = textX
    if not ev then
        -- (a line alone starts at the row's left)
        r.title:ClearAllPoints()
        r.title:SetPoint("LEFT", r, "LEFT", 2, 0)
    end
    r:FitTitle()
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
        if i < #items and more and y + h + ROW_GAP + S.ROW.art > bottom then
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
    card.head:SetTitle(date("%B %Y", noon(y, m, 1)))
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
            c.disc:SetVertexColor(S:Color("GOLD"))
            c.num:SetTextColor(0.09, 0.07, 0.02)
            c.num:SetShadowOffset(0, 0)
        else
            c.disc:SetVertexColor(1, 1, 1, 0.14)
            c.num:SetTextColor(S:Color((key == picked or inMonth) and "TEXT" or "DIM"))
            c.num:SetShadowOffset(1, -1)
        end
        c.disc:SetShown(key == today or key == picked)
        local list = byDay[key] or {}
        local n = min(#list, MAX_DOTS)
        for j, dot in ipairs(c.dots) do
            if j <= n then
                if inMonth then
                    local _, color = eventState(list[j])
                    dot:SetVertexColor(S:Color(color))
                else
                    local r, g, b = S:Color(C_PAST)
                    dot:SetVertexColor(r, g, b, 0.6)
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

    local bottom = H - S.IN
    local width = AGENDA_W

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
    card.dayHead:SetTitle(dayTitle(picked))
    local items = {}
    for _, ev in ipairs(byDay[picked] or {}) do
        local l1, l2 = eventLines(ev)
        local past = ev.t < now - CURRENT_FOR and not (ev.rec and running(ev.rec))
        items[#items + 1] = { l1 = l1, l2 = l2, ev = ev, past = past, plain = date("%H:%M ", ev.t) .. ev.name,
                              tip = eventTip(ev), onClick = eventClick(ev) }
    end
    if #items == 0 then
        items[1] = { l1 = dim(picked < today and "Nothing that day." or "Nothing planned.") }
    end
    -- the day's rows leave room for the coming-up header and one raid under it
    local headY = HEAD_H + 6
    local dayBottom = bottom - (#coming > 0 and (S.GAP + 18 + 4 + S.ROW.art) or 0)
    local yy = layoutRows(card, card.agenda, items, headY + 24 + 4, dayBottom, width, function(i)
        local names = { "More that day" }
        for j = i, #items do names[#names + 1] = items[j].plain or "" end
        return { l1 = dim("+" .. (#items - i + 1) .. " more"), tip = names }
    end)

    -- what's coming (its header links to the rest when they don't all fit)
    local ch = card.comingHead
    ch:SetShown(#coming > 0)
    local titleY = yy - ROW_GAP + S.GAP
    if #coming > 0 then
        ch:ClearAllPoints()
        ch:SetPoint("TOPLEFT", card, "TOPLEFT", AGENDA_X, -titleY)
        yy = titleY + 18 + 4
    end
    local _, usedComing = layoutRows(card, card.coming, coming, yy, bottom, width, nil)
    local hidden = #coming - usedComing
    if #coming > 0 and hidden > 0 then
        local lines = { "Also coming" }
        for i = usedComing + 1, #coming do lines[#lines + 1] = coming[i].plain end
        lines[#lines + 1] = dim("Click to open the Raids tab")
        ch:SetAction({ text = hidden .. " more", onClick = function() openRaid(nil) end })
        card.comingMore = ch.action
        card.comingMore.tip = lines
        attachTip(card.comingMore, "ANCHOR_TOP")
    else
        ch:SetAction(nil)
        card.comingMore = nil
    end
end

local function createCalendar(p, body)
    local cc = UI():CreateCard(body, { pad = 0 })
    cc:SetAllPoints(body)
    p.calCard = cc
    cc.agenda, cc.coming = {}, {}
    -- the month and its arrows (and the way back to today)
    cc.head = UI():CreateSectionHeader(cc, "", { style = "title" })
    cc.head:SetPoint("TOPLEFT", S.IN, -4)
    cc.head:SetPoint("TOPRIGHT", -S.IN, -4)
    cc.title = cc.head.title
    local function month(delta)
        return function()
            local ty, tm = dayOf(Now())
            local t = date("*t", noon(cal.y or ty, (cal.m or tm) + delta, 1))
            cal.y, cal.m = t.year, t.month
            Dashboard:Refresh()
        end
    end
    cc.nextMonth = UI():CreateArrowButton(cc.head, true, 20, 20, month(1))
    cc.nextMonth:SetPoint("RIGHT", cc.head, "RIGHT", 0, 1)
    UI():AttachTooltip(cc.nextMonth, "Next month", nil, { anchor = "ANCHOR_TOP" })
    cc.prevMonth = UI():CreateArrowButton(cc.head, false, 20, 20, month(-1))
    cc.prevMonth:SetPoint("RIGHT", cc.nextMonth, "LEFT", -2, 0)
    UI():AttachTooltip(cc.prevMonth, "Previous month", nil, { anchor = "ANCHOR_TOP" })
    cc.todayBtn = UI():CreateBackLink(cc.head, "Today", function()
        cal = {}
        Dashboard:Refresh()
    end)
    cc.todayBtn:SetPoint("RIGHT", cc.prevMonth, "LEFT", -10, 0)
    -- the line between the month and the day's list
    UI():Rule(cc, { vertical = true, left = RULE_X, top = HEAD_H + 10, bottom = S.PAD })
    for i, letter in ipairs(WEEKDAYS) do
        local fs = UI():Text(cc, "small", "DIM", { justify = "CENTER", width = CELL_W })
        fs:SetPoint("TOPLEFT", GRID_X + (i - 1) * CELL_W, -(HEAD_H + 8))
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
        hl:SetVertexColor(S:Color("HOVER"))
        c.num = UI():Text(c, "emph", "TEXT", { justify = "CENTER", shadow = true })
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
        c.tip = function()
            if not (c.events and #c.events > 0) then return nil end
            local lines = { dayTitle(c.key) }
            for _, ev in ipairs(c.events) do
                local label, color = eventState(ev)
                lines[#lines + 1] = date("%H:%M ", ev.t) .. ev.name .. " · " .. tint(color, label)
            end
            return lines
        end
        attachTip(c, "ANCHOR_RIGHT")
        cc.cells[i] = c
    end
    -- the picked day, then the raids coming up
    cc.dayHead = UI():CreateSectionHeader(cc, "", { style = "title", width = AGENDA_W })
    cc.dayHead:SetPoint("TOPLEFT", AGENDA_X, -(HEAD_H + 6))
    cc.dayTitle = cc.dayHead.title
    cc.comingHead = UI():CreateSectionHeader(cc, "Coming up", { style = "caps", width = AGENDA_W })
    cc.comingHead:Hide()
end

---------------------------------------------------------------------------
-- Loot: the newest awards (the council: everyone's, with the way to the Loot log; a raider: their own), in the
-- board's side card
---------------------------------------------------------------------------

local LOOT_ROW_H = S.ROW.rich
local LOOT_ICON = 26

local function newLootRow(card)
    local r = CreateFrame("Button", nil, card)
    r:SetHeight(LOOT_ROW_H)
    UI():DecorateRow(r, { rule = true })
    r.iconFrame = UI():CreateIconTile(r, LOOT_ICON)
    r.iconFrame:SetPoint("LEFT", S.IN + 2, 0)
    r.icon = r.iconFrame.tex
    r.l1 = UI():Text(r, "emph")
    r.l1:SetPoint("TOPLEFT", S.IN + 2 + LOOT_ICON + 9, -4)
    r.l1:SetPoint("RIGHT", -S.IN, 0)
    r.l2 = UI():Text(r, "body")
    r.l2:SetPoint("TOPLEFT", r.l1, "BOTTOMLEFT", 0, -3)
    r.ago = UI():Text(r, "body", "SUB", { justify = "RIGHT" })
    r.ago:SetPoint("TOPRIGHT", r.l1, "BOTTOMRIGHT", 0, -3)
    r.l2:SetPoint("RIGHT", r.ago, "LEFT", -6, 0)
    r.rule = r.dzRule
    r:SetScript("OnClick", Row_OnClick)
    r:SetScript("OnEnter", function(self) if self.itemID then UI():SetItemTooltip(self, self.itemID) end end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return r
end

local function refreshLoot(card)
    local L = ns.Ledger
    local council = isCouncil() or isDemo()
    card.head:SetAction(council and { text = "Loot log", onClick = function() openTab("loot") end } or nil)
    card.link = card.head.action
    local entries = {}
    if L then
        if council then
            entries = L:GetVisibleEntries()
        elseif Me() then
            entries = L:GetEntries({ player = Me() })
        end
    end
    card.head:SetTitle(council and "Recent loot" or "Your loot")
    local H = card:GetHeight()
    if not H or H < 100 then H = LOWER_H end
    local fit = floor((H - HEAD_H - 4) / LOOT_ROW_H)
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
            r:SetPoint("TOPLEFT", 0, -(HEAD_H + 2 + (i - 1) * LOOT_ROW_H))
            r:SetPoint("TOPRIGHT", 0, -(HEAD_H + 2 + (i - 1) * LOOT_ROW_H))
            r.icon:SetTexture(UI():ItemIcon(e.i))
            local q = ns.ItemDB and ns.ItemDB.GetQuality and ns.ItemDB:GetQuality(e.i)
            local qr, qg, qb = UI():QualityColor(q)
            r.iconFrame.outer:SetColorTexture(qr, qg, qb, q and 0.85 or 0.4)
            r.l1:SetText(UI():ItemText(e.i))
            UI():SetTextStyle(r.l1, "emph")
            if UI():TextWidth(r.l1) > LOOT_W - 45 - 10 then UI():SetTextStyle(r.l1, "body") end
            -- who (the council) or where from (my own), and why; a disenchant / bank award says only that
            local reason = e.r and REASON[e.r]
            local why = reason and tint(reason[2], reason[1]) or nil
            local l2
            if reason and (e.r == "de" or e.r == "bank") then
                l2 = why
            elseif council then
                l2 = ((e.w == Me()) and tint(STATUS.A.color, "You") or UI():ColoredName(e.w))
                    .. (why and (dim(" · ") .. why) or "")
            else
                local ref = ns.ItemDB and ns.ItemDB.GetBossRef and ns.ItemDB:GetBossRef(e.b)
                local boss = ref and ref.boss and (ref.boss.isTrash and "Trash" or ref.boss.name)
                local parts = {}
                if why then parts[#parts + 1] = why end
                if boss then parts[#parts + 1] = dim(boss) end
                l2 = tconcat(parts, dim(" · "))
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
    card.empty:SetContent({ glyph = UI().ICON.bag, title = council and "No awards yet" or "No loot yet",
                            text = council and "No awards recorded yet." or "No loot awarded to you yet." })
    card.empty:SetShown(n == 0)
end

local function createLoot(p, side)
    local lc = side
    p.lootCard = lc
    lc.rows = {}
    lc.head = UI():CreateSectionHeader(lc, "Recent loot", { style = "title" })
    lc.head:SetPoint("TOPLEFT", S.IN, -4)
    lc.head:SetPoint("TOPRIGHT", -S.IN, -4)
    lc.title = lc.head.title
    lc.empty = UI():CreateEmptyState(lc, { compact = true, glyph = UI().ICON.bag })
    lc.empty:SetBoxWidth(LOOT_W - 40)
    lc.empty:SetPoint("TOP", lc, "TOP", 0, -(HEAD_H + 40))
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

-- The page: a Board (UI:CreateLayout "board"): the greeting and chips in its toolbar, the carousel as its hero, the
-- calendar in its body and the loot in its side card.
function Dashboard:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    panel = p
    p.elapsed, p.dirty = 0, true
    local L = UI():CreateLayout("board", p, { hero = { size = BANNER_H }, side = LOOT_W })
    p.layout = L
    createHello(p, L.toolbar)
    setupBanner(p, L.banner)
    createCalendar(p, L.body)
    createLoot(p, L.side)
    -- the cards stretch to the page's bottom: their rows need the real height
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

-- A raid's short name as the chips write it ("Sign up: Thu Kara"), for the notification feed.
function Dashboard:ShortRaidName(v) return shortRaidName(v) end
-- "in 12 min", "tomorrow", "started 20m ago": the banner's countdown to t (the main window's header line uses it).
function Dashboard:Countdown(t) return countdown(t) end

function Dashboard:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("home", "Home", 0.5, function(parent) return Dashboard:CreatePanel(parent) end, nil,
            { layout = "board" })
    end
    for _, msg in ipairs({
        "RAIDPLAN_CHANGED", "MYLIST_CHANGED", "MYLIST_COMMITTED", "OWNED_UPDATED", "LEDGER_UPDATED", "LIST_UPDATED",
        "LISTS_RESET", "CONFIG_UPDATED", "PEERS_UPDATED", "SYNC_STATUS", "GROUP_RULES_CHANGED", "BIS_LOCK_CHANGED",
        "GROUP_UPDATED", "ITEMINFO_READY", "DEMO_TOGGLED", "ROSTER_UPDATED", "RAIDLOG_CHANGED", "CHANGELOG_READ",
        "DUNGEON_RUNS_UPDATED", "EVENTS_UPDATED", "NOTIFY_CHANGED",
    }) do
        ns:On(msg, function() Dashboard:RequestRefresh() end)
    end
    ns:RegisterSlash("home", function() ns.MainFrame:Open("home") end, "open the Home dashboard")
end
