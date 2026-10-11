if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RaidsTab.lua", ...) then return end -- DisasterZone: "Raids" tab. Three views (Addendum J §58):
--   Upcoming - planned raids and sign-ups (everyone; UI/RaidPlanUI.lua)
--   Teams    - the raid teams (everyone can look; organizers edit; UI/RaidPlanUI.lua)
--   Strategies - the strategy boards per boss (everyone looks and builds, each changes their own; Addendum K,
--               UI/StrategiesView.lua)
--   Guests   - the guest book and the raid blacklist (the GM, officers and the raid leaders; UI/GuestBook.lua)
--   Raid log - council only (Addendum I §51), with two modes:
--     Raids   - the raid sessions (newest first) as art rows and, for the selected one, a banner (when, how long, who
--               started it, a bin to delete it), its tabs (Attendance, Bosses, Awards), then the planned raid it is
--               linked to (a picker) and how its sign-ups turned out, then the open tab: Attendance (a time bar per
--               player; bench marks, right-click to change), Bosses (the kills) and Awards (the items given during it).
--     Attendance - 1.3.5 (UI/AttendanceUI.lua): every member's time-based attendance over the last N raids, a click
--               opens their page; the selected raid's Attendance tab is a time bar per player.
--     Reviews - 1.3.5: early leaves and reasons waiting for the GM, an officer or the guild council.
-- Start / End raid for the raid's authority sits in the toolbar. The Raid log is for raid log members (GM, guild
-- council, raid leaders; Addendum J §62) and, since 1.3.5, the officers (attendance reviewers), its awarded items for
-- the loot council only.
-- 1.4: the tab's view row is a layout toolbar (UI:CreateLayout, its tabs and the controls at its right, the main
-- action far right), the Raid log's Raids mode a list + detail layout (art rows, the detail's banner and block tabs).
local addonName, ns = ...

local RaidsUI = ns:NewModule("RaidsUI")

local S = ns.Style
local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tconcat = table.concat

-- The Raid log on the Raids tab's spacing grid (S.PAD at the page's sides, S.GAP between blocks).
local GAP = S.GAP
local INNER_W = S.INNER_W            -- the page inside its sides (the mock's anchored frames have no width)
local LOG_W = 244                    -- the logged raids column (1.3.5: 236; an art row's picture + gap is 8 wider)
local DETAIL_W = INNER_W - LOG_W - GAP
local CARD_H = S.ROW.art             -- a logged raid: an art row
local TEXT_X = 80                    -- where an art row's text starts (its 64 px picture, the gap)
local LINK_H = 22                    -- the planned raid it is linked to, and how the sign-ups turned out
local HEAD_H = 18                    -- a table's column titles
local ROW_H = S.ROW.compact
local TOP = 36                       -- the views start under the Raids tab's view row (the layout's toolbar)
local RANGES = { 4, 8, 12, 0 }   -- 0 = all raids

-- The tables, columns left to right: one (flex) takes the room the others leave, so the last column ends at the table's
-- right edge; numbers are right-aligned (r), under a right-aligned title. icon: a class circle / an item's icon first.
-- opt: a column shown only when the table needs it (somebody left early, somebody was offline at a kill).
local COL_GAP = 16
local TABLES = {
    att = { { "Player", flex = true, icon = true }, { "Boss kills", w = 64, r = true }, { "Joined", w = 52, r = true },
            { "Left", w = 52, r = true, opt = true } },
    boss = { { "Time", w = 44 }, { "Boss", flex = true }, { "Raiders", w = 60, r = true },
             { "Offline", w = 60, r = true, opt = true } },
    award = { { "Item", flex = true, icon = true }, { "Winner", w = 120 }, { "Reason", w = 84 },
              { "Time", w = 44, r = true } },
}

local state = { view = "upcoming", mode = "raids", selected = nil, range = 8, showGuests = false, tab = "att",
                player = nil, lineup = nil }
local panel

-- (the file's helpers in one table: the main chunk keeps few locals)
local H = {}

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

function H.Dim(text) return S:Wrap("DIM", text) end

function H.Short(key) return ns.Util.ShortName(key) or tostring(key) end

-- The class the guild knows for a player, unless the record has it. TODO(refactor): move into UI:ClassOf (the API
-- names it; only EUI:ClassOf exists so far).
function H.Class(key, classFile)
    return classFile or (ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)) or nil
end

-- The name in its class colour. (Other lists mark a player from another realm "Name*"; the raid log's tables leave
-- the mark out: the GUEST tag says they are outside the guild, the row's tooltip names the realm.)
function H.Colored(key, classFile)
    local text = ns.UI:ColoredName(key, H.Class(key, classFile))
    return (text:gsub("%*|r$", "|r"))
end

-- "Darkstalkerr", and "from Pyrewood Village" for a player from another realm (tooltips).
function H.NameLines(tt, key)
    tt:AddLine((H.Short(key):match("^([^%-]+)") or H.Short(key)))
    local realm = ns.Util.RealmOf and ns.Util.RealmOf(key)
    if realm then tt:AddLine("from " .. realm:gsub("(%l)(%u)", "%1 %2"), 1, 1, 1) end
end

-- "3 h 17 min", "45 min".
function H.Duration(sec)
    sec = floor(max(0, sec or 0))
    local h, m = floor(sec / 3600), floor(sec % 3600 / 60)
    return h > 0 and ("%d h %02d min"):format(h, m) or (m .. " min")
end

function H.Time(ts, fmt) return ts and date(fmt or "%H:%M", ts) or "-" end

local function RL() return ns.RaidLog end

function H.RangeLabel(n) return n == 0 and "All raids" or ("Last " .. n .. " raids") end

-- The first of the texts that fits in `room` (the last one when none does): never cut off with "...".
-- (measured without its colour codes: the game's width ignores them, the test harness's doesn't)
function H.FitVariants(fs, variants, room)
    for i, text in ipairs(variants) do
        fs:SetText((text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
        local fits = (fs:GetStringWidth() or 0) <= room
        fs:SetText(text)
        if i == #variants or fits then return text end
    end
end

-- The same, measured in a text style (for a component that sets the text itself).
function H.PickVariant(variants, room, style)
    for i, text in ipairs(variants) do
        local plain = (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
        if i == #variants or ns.UI:TextWidth(plain, style) <= room then return text end
    end
end

-- The Raid log view (Addendum J §62): the GM, the guild council and the raid leaders list (not whoever happens to
-- lead a group: that is loot council for one raid only).
local function isCouncil()
    local G = ns.Guild
    if ns.Util.DemoOn() then return true end
    if G and G.AmIRaidLogReader then return G:AmIRaidLogReader() and true or false end
    return (G and G.AmIRaidLogMember and G:AmIRaidLogMember()) and true or false
end

-- Linking and bench marks: the raid log's members (not the officers who only review attendance), and the demo.
function H.LogMember()
    local G = ns.Guild
    return (ns.Util.DemoOn() or (G and G.AmIRaidLogMember and G:AmIRaidLogMember())) and true or false
end

local function AUI() return ns.AttendanceUI end
local function Att() return ns.Attendance end

-- Awarded items in the raid log: loot council data (GM / guild council), not for raid leaders.
local function seesItems()
    local G = ns.Guild
    return (ns.Util.DemoOn() or (G and G.IsGuildCouncil and G:IsGuildCouncil(ns.Util.PlayerKey()))) and true or false
end

-- A logged raid's instance (the raid plan's key: its loading screen) and its name, full and short.
function H.InstOf(rec)
    local RP = ns.RaidPlan
    for _, inst in ipairs(RP and RP.GetInstances and RP:GetInstances() or {}) do
        if inst.instID and inst.instID == rec.instID then return inst.key end
    end
    return "other"
end

-- The instances a logged raid covered (a night of Mag + Gruul: both), else the one it was recorded in.
function H.InstsOf(rec)
    local keys = RL().GetRecordInstances and RL():GetRecordInstances(rec) or {}
    if #keys == 0 then keys = { H.InstOf(rec) } end
    return keys
end

-- A raid's loading screen cropped for w x h (a small crop stays under the game's logo): path, l, r, t, b.
function H.ArtCrop(key, w, h, fw)
    return ns.ItemDB:RaidArt(key, w, h, fw, 60)
end

function H.PaintArt(tex, key, w, h, fw)
    local file, l, r, t, b = H.ArtCrop(key, w, h, fw)
    tex:SetTexture(file)
    tex:SetTexCoord(l or 0, r or 1, t or 0, b or 1)
    tex:Show()
end

-- A second picture beside a texture (a night of two instances: the Upcoming cards' look): the right half and the
-- dark line between them, made on first use. TODO(refactor): move into UI:CreateArtRow / UI:CreatePageBanner (a
-- two-picture art).
function H.SecondArt(host, base, layer, sub)
    if not host.dzArt2 then
        host.dzArt2 = host:CreateTexture(nil, layer, nil, sub)
        host.dzArt2:SetPoint("TOPLEFT", base, "TOPRIGHT")
        host.dzArtLine = host:CreateTexture(nil, layer, nil, sub + 1)
        host.dzArtLine:SetColorTexture(0, 0, 0, 0.6)
        host.dzArtLine:SetWidth(2)
        host.dzArtLine:SetPoint("TOPLEFT", host.dzArt2, "TOPLEFT", -1, 0)
        host.dzArtLine:SetPoint("BOTTOMLEFT", host.dzArt2, "BOTTOMLEFT", -1, 0)
    end
    return host.dzArt2, host.dzArtLine
end

function H.KillsText(rec)
    local kills = #(rec.bosses or {})
    local total = RL():GetRecordBossTotal(rec)
    return total and ("%d/%d bosses"):format(kills, total) or (kills == 1 and "1 boss" or (kills .. " bosses"))
end

----------------------------------------------------------------------------
-- Raid list (left): an art row per logged raid
----------------------------------------------------------------------------

-- The row's picture: the raid's loading screen; a night of two instances: the first two side by side.
function H.RowArt(row, rec)
    return function(tex, w, h)
        local keys = H.InstsOf(rec)
        local two = #keys > 1
        local art2, line = H.SecondArt(row.ar.art, tex, "ARTWORK", 1)
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT")
        tex:SetPoint("BOTTOMLEFT")
        local aw = two and floor(w / 2) or w
        tex:SetWidth(aw)
        H.PaintArt(tex, keys[1], aw, h, 0.36 * aw / w)
        art2:SetShown(two)
        line:SetShown(two)
        if two then
            art2:SetSize(w - aw, h)
            H.PaintArt(art2, keys[2], w - aw, h, 0.36 * (w - aw) / w)
        end
    end
end

local function initRaidRow(row, d)
    if not row.ar then
        row.ar = ns.UI:CreateArtRow(row, { selectable = true, onClick = function(self)
            local data = self:GetParent().cdlRec
            state.selected = data and data.id
            RaidsUI:Refresh()
        end })
        row.ar:SetAllPoints(row)
    end
    local rec = d.rec
    row.cdlRec = rec
    -- a raid still going / ended when the group broke up
    local pill
    if not rec.stop then pill = { "live", "live" }
    elseif rec.autoEnded then pill = { "mute", "auto-ended" } end
    -- the start time, at the right, when another raid was logged that day
    local right = d.sameDay and H.Time(rec.start) or nil
    local room = LOG_W - TEXT_X - 8 - (right and (ns.UI:TextWidth(right, "sub") + 16) or 0)
    local pillRoom = pill and (ns.UI:TextWidth(pill[2], "small") + 14 + 7) or 0
    -- its name (a night's planned raid or its zones), else the instances' short names: "Mag + Gruul", never one of them
    local zone = rec.zone or "Raid"
    local shorts = {}
    for i, key in ipairs(H.InstsOf(rec)) do shorts[i] = ns.ItemDB:RaidShort(key) or zone end
    local short = #shorts > 1 and tconcat(shorts, " + ") or (shorts[1] or zone)
    local title = H.PickVariant({ zone, short }, room - pillRoom, "emph")
    -- the day, the kills
    local kills = H.KillsText(rec)
    local day = H.Time(rec.start, "%a ") .. tonumber(H.Time(rec.start, "%d")) .. H.Time(rec.start, " %b")
    local sub = H.PickVariant({ day .. " · " .. kills, ((day .. " · " .. kills):gsub(" bosses?$", "")) }, room, "sub")
    row.ar:SetData({ art = H.RowArt(row, rec), title = title, sub = sub, right = right, pill = pill,
                     selected = rec.id == state.selected })
end

----------------------------------------------------------------------------
-- The tables (the selected raid's tabs, the Players view): rows without boxes, columns per TABLES
----------------------------------------------------------------------------

-- Where a table's columns go in `width`: { [i] = { x, w, r, icon } } for the shown ones (show[i] for the opt ones).
function H.PlaceColumns(key, width, show)
    local def = TABLES[key]
    local fixed, n = 0, 0
    for i, c in ipairs(def) do
        if not c.opt or (show and show[i]) then
            n = n + 1
            if not c.flex then fixed = fixed + c.w end
        end
    end
    local out, x = { key = key }, 0
    for i, c in ipairs(def) do
        if not c.opt or (show and show[i]) then
            local w = c.flex and (width - fixed - COL_GAP * (n - 1)) or c.w
            out[i] = { x = x, w = w, r = c.r, icon = c.icon, title = c[1] }
            x = x + w + COL_GAP
        end
    end
    return out
end

-- A cell's text in its column: 12, else 11, else 10, else two lines (never cut off).
function H.FitCell(fs, text, width)
    fs:SetWordWrap(false)
    fs:SetWidth(0)
    fs:SetText(text or "")
    for _, style in ipairs({ "emph", "body", "small" }) do
        ns.UI:SetTextStyle(fs, style, "TEXT")
        if (fs:GetStringWidth() or 0) <= width then return end
    end
    fs:SetWidth(width)
    fs:SetWordWrap(true)
end

function H.RowClick(self, button)
    if button == "RightButton" and self.cdlMenu then self.cdlMenu(self) end
end

function H.RowTip(self, tt)
    local d = self.__cdlData
    if not d then return false end
    if d.itemID then
        ns.UI:SetItemTooltip(self, d.itemID)     -- (it owns and shows the tooltip itself)
        return
    end
    if not d.tip then return false end
    d.tip(tt)
end

local function initColRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        local UI = ns.UI
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        UI:DecorateRow(row, { rule = true })
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 0, 0)
        row.cols = {}
        for i = 1, 5 do row.cols[i] = UI:Text(row, "emph", "TEXT") end
        row.tag = UI:Text(row, "caps", { 0.4, 0.8, 1 })
        row.tag:SetText("GUEST")
        row.pill = UI:CreatePill(row)
        row:SetScript("OnClick", H.RowClick)
        UI:AttachTooltip(row, H.RowTip)
    end
    local L = d.place
    -- the icon column: a class circle or an item's icon before the name / item
    row.icon:SetShown(false)
    if d.class then
        ns.UI:ClassIcon(row.icon, d.class)
    elseif d.itemID and d.place.key == "award" then
        row.icon:SetTexture(ns.UI:ItemIcon(d.itemID))
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.icon:Show()
    end
    -- after the name: GUEST, a bench tag
    row.tag:SetShown(d.guest and true or false)
    if d.pill then row.pill:Set(d.pill, "bis") end
    row.pill:SetShown(d.pill ~= nil)
    local tags = (d.guest and ((row.tag:GetStringWidth() or 30) + 6) or 0) + (d.pill and (row.pill:GetWidth() + 8) or 0)
    local first
    for i, fs in ipairs(row.cols) do
        local c = L[i]
        local text = d.cols[i]
        fs:SetShown(c ~= nil and text ~= nil and text ~= "")
        if c and text and text ~= "" then
            local indent = c.icon and 22 or 0
            fs:ClearAllPoints()
            if c.r then
                fs:SetJustifyH("RIGHT")
                fs:SetPoint("RIGHT", row, "LEFT", c.x + c.w, 0)
            else
                fs:SetJustifyH("LEFT")
                fs:SetPoint("LEFT", c.x + indent, 0)
            end
            H.FitCell(fs, text, c.w - indent - (c.icon and tags or 0))
            if c.r and not fs:CanWordWrap() then fs:SetWidth(c.w) end
            if c.icon then
                first = fs
                row.icon:ClearAllPoints()
                row.icon:SetPoint("LEFT", c.x, 0)
            end
        end
    end
    local prev = first
    if d.guest and prev then
        row.tag:ClearAllPoints()
        row.tag:SetPoint("LEFT", prev, "RIGHT", 6, 0)
        prev = row.tag
    end
    if d.pill and prev then
        row.pill:ClearAllPoints()
        row.pill:SetPoint("LEFT", prev, "RIGHT", 8, 0)
    end
    row.cdlMenu = d.menu
end

-- The column titles over a table (gold, a hairline under them).
function H.NewHead(parent)
    local UI = ns.UI
    local h = CreateFrame("Frame", nil, parent)
    h:SetHeight(HEAD_H)
    h.line = UI:Rule(h, { bottom = 0, alpha = 0.08, layer = "BACKGROUND" })
    h.cols = {}
    for i = 1, 5 do h.cols[i] = UI:Text(h, "body", "GOLD") end
    -- (titles over numbers are right-aligned like them; a title over an icon column starts where the icon does)
    function h:SetPlace(L)
        for i, fs in ipairs(self.cols) do
            local c = L[i]
            fs:SetShown(c ~= nil)
            if c then
                fs:ClearAllPoints()
                if c.r then
                    fs:SetJustifyH("RIGHT")
                    fs:SetPoint("RIGHT", self, "LEFT", c.x + c.w, 1)
                else
                    fs:SetJustifyH("LEFT")
                    fs:SetPoint("LEFT", c.x, 1)
                end
                fs:SetText(c.title)
                if c.r then fs:SetWidth(max(c.w, ceil(fs:GetStringWidth() or 0))) else fs:SetWidth(0) end
            end
        end
    end
    return h
end

----------------------------------------------------------------------------
-- The selected raid: banner, tabs, link
----------------------------------------------------------------------------

function H.BenchMenu(row, rec, key, a)
    ns.UI:ContextMenu(row, function(root)
        root:CreateTitle(H.Short(key))
        if a and a.b then
            root:CreateButton("Remove bench mark", function() RL():SetBench(rec.id, key, false) end)
        else
            root:CreateButton("Mark as bench / standby", function() RL():SetBench(rec.id, key, true) end)
        end
    end)
end

-- Addendum J §61: link a logged raid to a planned raid (raid log members). The running session is relinked for the
-- whole raid (GS: by the raid's authority, at the request of anyone else with the raid log; 1.3); any other record is
-- changed here and reaches the raid planners through the raid log sync.
function H.PlanMenu(root, rec)
    local RP = ns.RaidPlan
    if not RP then return end
    local function set(occ)
        local GR = ns.GroupRules
        local s = GR and GR:GetSession()
        for _, id in ipairs(rec.ids or { rec.id }) do
            if s and s.id == id and GR:IsAuthority() then
                ns.RaidLink:SetLink(occ)
            else
                RL():SetPlanned(id, occ)
            end
        end
    end
    root:CreateTitle("Planned raid")
    for _, v in ipairs(RP:GetRaids((rec.start or 0) - 2 * 86400, (rec.start or 0) + 2 * 86400)) do
        local label = ("%s  %s"):format(date("%a %d %b %H:%M", v.t), RP:GetRaidName(v))
        root:CreateRadio(label, function() return rec.pl == v.id end, function() set(v.id) end)
    end
    root:CreateRadio("Not linked", function() return rec.pl == nil end, function() set(nil) end)
end

-- The link picker's text: "Linked to  <planned raid>", or that it isn't linked.
function H.LinkText(rec)
    local RP = ns.RaidPlan
    local v = rec.pl and RP and RP:GetRaid(rec.pl)
    if v then return S:Wrap("SUB", "Linked to") .. "  " .. RP:GetRaidName(v), v end
    if rec.pl then return S:Wrap("SUB", "Linked to") .. "  " .. H.Dim("a raid no longer planned") end
    return H.Dim("Not linked to a planned raid")
end

-- How the sign-ups turned out: "8 of 9 came · no-show A, B" (nil when the raid had no sign-ups), and the no-shows.
function H.SignupCheck(rec)
    if not rec.su then return nil end
    local acc, came, noShow = 0, 0, {}
    for key, st in pairs(rec.su) do
        if st == "A" then
            acc = acc + 1
            if rec.att and rec.att[key] then came = came + 1 else noShow[#noShow + 1] = key end
        end
    end
    if acc == 0 then return nil end
    table.sort(noShow, function(a, b) return H.Short(a):lower() < H.Short(b):lower() end)
    return acc, came, noShow
end

local DASH = S:Wrap("DIM", "-")        -- nothing to say in a cell: a dim dash

-- The selected raid's open tab as rows, and where its columns go.
function H.DetailRows(rec)
    local rows = {}
    if state.tab == "boss" then
        -- (Offline only when somebody was offline at a kill)
        local offs, anyOff = {}, false
        for i, b in ipairs(rec.bosses or {}) do
            local n = 0
            for _ in pairs(b.off or {}) do n = n + 1 end
            offs[i], anyOff = n, anyOff or n > 0
        end
        local place = H.PlaceColumns("boss", DETAIL_W, { [4] = anyOff })
        for i, b in ipairs(rec.bosses or {}) do
            rows[#rows + 1] = { place = place, cols = { H.Dim(H.Time(b.ts)), b.name or ("Encounter " .. tostring(b.enc)),
                b.roster and tostring(#b.roster) or DASH, offs[i] > 0 and S:Wrap("BAD", offs[i]) or DASH } }
        end
        return rows, place
    elseif state.tab == "award" and seesItems() then
        local place = H.PlaceColumns("award", DETAIL_W)
        for _, e in ipairs(RL():GetAwards(rec)) do
            rows[#rows + 1] = { place = place, itemID = e.i, cols = { ns.UI:ItemText(e.i), H.Colored(e.w)
                .. (ns.UI:IsGuest(e.w) and H.Dim(" guest") or ""), ns.ReasonLabel and ns.ReasonLabel(e.r) or "",
                e.vd and H.Dim("void") or H.Dim(H.Time(e.ts)) } }
        end
        return rows, place
    end
    -- Attendance (Left only when somebody left before the end: a dash for who stayed)
    local nBoss = #(rec.bosses or {})
    local keys = ns.Util.Keys(rec.att or {})
    table.sort(keys, function(a, b) return H.Short(a):lower() < H.Short(b):lower() end)
    local function leftEarly(a) return a.j ~= nil and a.l ~= nil and a.l ~= rec.stop end
    local anyLeft = false
    for _, key in ipairs(keys) do anyLeft = anyLeft or leftEarly(rec.att[key]) end
    local place = H.PlaceColumns("att", DETAIL_W, { [4] = anyLeft })
    for _, key in ipairs(keys) do
        local a = rec.att[key]
        rows[#rows + 1] = { place = place, key = key, class = H.Class(key, a.c), guest = ns.UI:IsGuest(key),
            cols = { H.Colored(key, a.c), ("%d/%d"):format(tonumber(a.k) or 0, nBoss), a.j and H.Time(a.j) or DASH,
                     leftEarly(a) and H.Time(a.l) or DASH },
            pill = a.b and "bench" or nil,
            menu = function(row) H.BenchMenu(row, rec, key, a) end,
            tip = function(tt)
                H.NameLines(tt, key)
                tt:AddLine(a.b and "Right-click to remove the bench mark." or "Right-click to mark as bench / standby.",
                    S:Color("SUB"))
            end }
    end
    return rows, place
end

-- The banner's picture: the raid's loading screen; a night of two instances: the first two side by side.
function H.BannerArt(b, rec)
    local keys = H.InstsOf(rec)
    local W, Hh = DETAIL_W - 2, b:GetHeight() - 2
    local art2, line = H.SecondArt(b, b.art, "BACKGROUND", 2)
    b.art:ClearAllPoints()
    b.art:SetPoint("TOPLEFT", 1, -1)
    if #keys > 1 then
        local aw = floor(W / 2)
        b.art:SetPoint("BOTTOMLEFT", 1, 1)
        b.art:SetWidth(aw)
        art2:SetPoint("BOTTOMRIGHT", -1, 1)
        H.PaintArt(art2, keys[2], W - aw, Hh, 0.98 * (W - aw) / W)
        art2:Show()
        line:Show()
        b:SetArt({ H.ArtCrop(keys[1], aw, Hh, 0.98 * aw / W) })
    else
        b.art:SetPoint("BOTTOMRIGHT", -1, 1)
        art2:Hide()
        line:Hide()
        b:SetArt({ H.ArtCrop(keys[1], W, Hh, 0.98) })
    end
end

-- The selected raid's banner: its art, the raid and whether it is still going, when / how long / who started it.
function H.FillBanner(p, rec)
    local b = p.banner
    H.BannerArt(b, rec)
    if not rec.stop then b:SetPill("live", "in progress")
    elseif rec.autoEnded then b:SetPill("ended", "auto-ended")
    else b:SetPill(nil, nil) end
    b:SetTitle(rec.zone or "Raid")
    -- "Thursday 1 October · 19:45 – 23:02 · 3 h 17 min · started by X" (who ended it when someone else did)
    local day = H.Time(rec.start, "%A ") .. tonumber(H.Time(rec.start, "%d")) .. H.Time(rec.start, " %B")
    local span = H.Time(rec.start) .. " – " .. (rec.stop and H.Time(rec.stop) or "now")
    local parts = { day, span, H.Duration((rec.stop or ns.Util.Now()) - (rec.start or 0)) }
    local by = rec.by and H.Short(rec.by)
    if by then parts[#parts + 1] = "started by " .. H.Colored(rec.by) end
    if rec.stop and rec.endedBy and rec.endedBy ~= rec.by then
        parts[#parts + 1] = "ended by " .. H.Colored(rec.endedBy)
    elseif rec.autoEnded then
        parts[#parts + 1] = "ended when the group broke up"
    end
    local full = tconcat(parts, " · ")
    b:SetSub(H.PickVariant({ full, (full:gsub(H.Time(rec.start, "%A "), H.Time(rec.start, "%a "))) },
        DETAIL_W - 28, "body"))
    -- GM / guild council: delete the logged raid
    b:SetTools((rec.stop ~= nil and RL():CanDelete()) and p.deleteTools or nil)
end

function H.FillLink(p, rec)
    local text = H.LinkText(rec)
    local btn = p.linkBtn
    btn:SetText(text)
    -- (1.3.5: only those who may link raids get the picker: the raid leaders and the guild council, not demo)
    local G = ns.Guild
    btn:SetEnabled(not ns.Util.DemoOn() and G and G.AmIRaidLogMember and G:AmIRaidLogMember() and true or false)
    local fs = btn:GetFontString()
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", 8, 0)
    local w = min(300, max(180, floor((fs:GetStringWidth() or 0) + 34 + 0.5)))
    btn:SetWidth(w)
    fs:SetPoint("RIGHT", -20, 0)
    -- how the sign-ups turned out, at the right of the same row
    local acc, came, noShow = H.SignupCheck(rec)
    local line = p.signupLine
    line.noShow = noShow
    line:SetShown(acc ~= nil)
    if not acc then return end
    local head = came == acc and S:Wrap("OK", ("%d of %d came"):format(came, acc)) or ("%d of %d came"):format(came, acc)
    local room = DETAIL_W - w - 16
    local variants = { head }
    if #noShow > 0 then
        local names = {}
        for _, key in ipairs(noShow) do names[#names + 1] = H.Colored(key) end
        variants = {}
        for n = #names, 1, -1 do
            local shown = { unpack(names, 1, n) }
            variants[#variants + 1] = head .. H.Dim(" · no-show ") .. tconcat(shown, ", ")
                .. (n < #names and H.Dim(" +" .. (#names - n)) or "")
        end
        variants[#variants + 1] = head .. H.Dim(" · " .. #names .. " no-show")
    end
    H.FitVariants(line.fs, variants, room)
    line.fs:SetWidth(room)
    line:SetWidth(room)
end

function H.FillTabs(p, rec)
    local tabs = p.logLayout.tabs
    local kills = #(rec.bosses or {})
    local total = RL():GetRecordBossTotal(rec)
    tabs:SetTabCount("att", ns.Util.Count(rec.att or {}))
    tabs:SetTabCount("boss", total and { kills, total } or kills)
    local items = seesItems()
    tabs:SetTabShown("award", items)
    if items then tabs:SetTabCount("award", #RL():GetAwards(rec)) end
    if state.tab == "award" and not items then state.tab = "att" end
    tabs:SelectTab(state.tab)
    if state.tab == "boss" then
        p.detail:SetEmptyText("No boss kills logged.")
    elseif state.tab == "award" then
        p.detail:SetEmptyText("No awards during this raid.")
    else
        p.detail:SetEmptyText("Nobody was logged in this raid.")
    end
end

----------------------------------------------------------------------------
-- Panel
----------------------------------------------------------------------------

local function canOrganize()
    local RP = ns.RaidPlan
    return RP and RP.CanOrganize and RP:CanOrganize() or false
end

local function canTeams()
    local RP = ns.RaidPlan
    return RP and RP.CanManageTeams and RP:CanManageTeams() or false
end

local function canRoster()
    local RP = ns.RaidPlan
    return RP and RP.CanManageRoster and RP:CanManageRoster() or false
end

-- The view row: the page's views (the Raid log's own modes as small tabs after them), the controls at the right.
function H.UpdateToolbar(p)
    if state.view == "log" and not isCouncil() then state.view = "upcoming" end
    if state.view == "guests" and not canRoster() then state.view = "upcoming" end
    local log = state.view == "log"
    local bar = p.toolbar
    bar:SetTabShown("guests", canRoster())
    bar:SetTabShown("log", isCouncil())
    for _, key in ipairs({ "raids", "players", "reviews" }) do bar:SetTabShown(key, log) end
    -- TODO(refactor): move into the layout toolbar (LayoutTabs leaves the separator of a hidden small-tab group shown)
    if not log then
        for _, sep in ipairs(bar.tabSeps or {}) do sep:Hide() end
    end
    -- the current view's tab is the lit one
    bar:SelectTab(state.view)
    bar:SelectTab(state.mode)
    -- (1.3.5: the reviews waiting for a decision, gold for those who decide)
    local Att_ = Att()
    local pending = log and Att_ and Att_.CanReview and Att_:CanReview() and Att_:PendingCount() or 0
    bar:SetTabCount("reviews", pending > 0 and pending or nil)
    local overview = log and state.mode == "players" and not state.player
    p.rangeBtn:SetShown(overview)
    p.rangeBtn:SetText(H.RangeLabel(state.range))
    p.lineupBtn:SetShown(overview)
    p.lineupBtn:SetText(state.lineup and state.lineup.label or "All lineups")
    local GR = ns.GroupRules
    local auth = IsInRaid() and GR and GR:IsAuthority()
    -- (1.3.5: not on the Raid log's Attendance and Reviews pages, which need the row for their filters; the
    -- session bar has Start / End raid too)
    if log and state.mode ~= "raids" then auth = false end
    p.sessionBtn:SetShown(auth and true or false)
    p.sessionBtn:SetText(GR and GR:GetSession() and "End raid" or "Start raid")
    local RP = ns.RaidPlan
    p.newRaidBtn:SetShown(canOrganize() and state.view == "upcoming")
    -- (no teams yet: the Teams view's empty card has the New team button)
    p.newTeamBtn:SetShown(canTeams() and state.view == "teams" and RP ~= nil and #RP:GetTeams() > 0)
    p.leadersBtn:SetShown(state.view == "teams")
    bar:LayoutRight()
end

-- The Raids view of the Raid log: the logged raids on the left, the selected one on the right (a list + detail
-- layout: the banner, its tabs, then the link row and the open tab).
function H.CreateLogRaids(p)
    local UI = ns.UI
    local L = UI:CreateLayout("listdetail", p, {
        toolbar = false, top = TOP, listWidth = LOG_W,
        banner = { size = "tool", titleColor = { 1, 1, 1 } },
        tabs = { { key = "att", text = "Attendance" }, { key = "boss", text = "Bosses" }, { key = "award", text = "Awards" } },
        onTab = function(key)
            state.tab = key
            RaidsUI:Refresh()
        end,
    })
    p.logLayout = L
    p.raidList = UI:CreateScrollList(L.list, CARD_H, initRaidRow)
    p.raidList.frame:SetPoint("TOPLEFT")
    p.raidList.frame:SetPoint("BOTTOMLEFT")
    p.raidList.frame:SetWidth(LOG_W + 20)
    -- (its bar in the gap beside the column)
    p.raidList.bar:ClearAllPoints()
    p.raidList.bar:SetPoint("TOPLEFT", p.raidList.box, "TOPRIGHT", 1, 0)
    p.raidList.bar:SetPoint("BOTTOMLEFT", p.raidList.box, "BOTTOMRIGHT", 1, 0)

    p.logDetail = L.detail
    p.banner = L.banner
    p.tabAtt, p.tabBoss, p.tabAward = L.tabs:GetTab("att"), L.tabs:GetTab("boss"), L.tabs:GetTab("award")
    -- GM / guild council: delete the logged raid (the banner's bin)
    p.deleteTools = { { icon = "trash", title = "Delete this raid from the log",
        text = "Removes the logged raid for every raid planner: its boss kills and attendance no longer count. Awards "
            .. "stay in the Loot Log. This can't be undone.", onClick = function() H.ConfirmDelete(p) end } }
    p.banner:SetTools(p.deleteTools)
    p.deleteLogBtn = p.banner.tools[1]
    p.banner:SetTools(nil)

    local body = L.body
    -- the planned raid it is linked to (a picker), how its sign-ups turned out on the right
    p.linkBtn = UI:CreateSleekMenuButton(body, "", 240, function(root)
        local rec = state.selected and RL():GetRaid(state.selected)
        if rec then H.PlanMenu(root, rec) end
    end, LINK_H)
    p.linkBtn:SetPoint("TOPLEFT", 0, 0)
    UI:AttachTooltip(p.linkBtn, "Planned raid", "The raid on the Upcoming board this one was: its sign-ups tell who "
        .. "came and who didn't. Pick another to relink it.", { anchor = "ANCHOR_TOP" })
    local sl = CreateFrame("Frame", nil, body)
    sl:SetHeight(LINK_H)
    sl:SetPoint("TOPRIGHT", 0, 0)
    sl.fs = UI:Text(sl, "body", "TEXT", { justify = "RIGHT" })
    sl.fs:SetPoint("RIGHT", 0, 0)
    UI:AttachTooltip(sl, function(self, tt)
        if not (self.noShow and #self.noShow > 0) then return false end
        tt:AddLine("Accepted but didn't come")
        for _, key in ipairs(self.noShow) do tt:AddLine(H.Colored(key)) end
    end, nil, { anchor = "ANCHOR_TOP" })
    p.signupLine = sl

    local top = LINK_H + GAP
    p.logHead = H.NewHead(body)
    p.logHead:SetPoint("TOPLEFT", 0, -top)
    p.logHead:SetPoint("TOPRIGHT", 0, -top)
    p.detail = UI:CreateScrollList(body, ROW_H, initColRow)
    p.detail.frame:SetPoint("TOPLEFT", 0, -(top + HEAD_H + 2))
    p.detail.frame:SetPoint("BOTTOMRIGHT", 20, 0)
    p.detail.bar:ClearAllPoints()
    p.detail.bar:SetPoint("TOPLEFT", p.detail.box, "TOPRIGHT", 4, 0)
    p.detail.bar:SetPoint("BOTTOMLEFT", p.detail.box, "BOTTOMRIGHT", 4, 0)
    -- 1.3.5: the Attendance tab is a time bar per player (UI/AttendanceUI.lua)
    p.timeline = AUI():CreateTimeline(body, DETAIL_W)
    p.timeline:SetPoint("TOPLEFT", 0, -top)
    p.timeline:SetPoint("BOTTOMRIGHT", 0, 0)
    p.timeline.menuExtra = function(root, r)
        local view = p.selView
        if not (view and H.LogMember()) then return end
        -- (a night logged as several raids: the log that holds the player, else the newest)
        local holder, benched
        for _, id in ipairs(view.ids or { view.id }) do
            local rec = RL():GetRaid(id)
            local a = rec and rec.att and rec.att[r.key]
            if a then
                holder = holder or rec
                if a.b then holder, benched = rec, true end
            end
        end
        holder = holder or RL():GetRaid(view.id)
        if not holder then return end
        if benched then
            root:CreateButton("Remove bench mark", function() RL():SetBench(holder.id, r.key, false) end)
        else
            root:CreateButton("Mark as bench / standby", function() RL():SetBench(holder.id, r.key, true) end)
        end
    end
end

-- The bin: asks first (the raid planners' confirm), then deletes every log of the night.
function H.ConfirmDelete(p)
    local rec = p.selView
    if not rec then return end
    local ids = rec.ids or { rec.id }
    ns.Popup:Confirm({ title = "Delete a logged raid", ok = "Delete", danger = true,
        text = ("Delete the logged raid %s (%s)?\n\nIts boss kills and attendance are removed for everyone. Awards "
            .. "stay in the Loot Log. This can't be undone."):format(rec.zone or "Raid", H.Time(rec.start, "%a %d %b"))
            .. (#ids > 1 and ("\n\nIt was logged as " .. #ids .. " raids: all are deleted.") or ""),
        onAccept = function()
            for _, id in ipairs(ids) do
                local ok, err = RL():Delete(id)
                if not ok then ns:Print("%s", err or "Could not delete the raid.") end
            end
        end })
end

-- The Attendance view of the Raid log (1.3.5, UI/AttendanceUI.lua): every member, or one member's page.
function H.CreateLogPlayers(p)
    local f = CreateFrame("Frame", nil, p)
    f:SetPoint("TOPLEFT", S.PAD, -TOP)
    f:SetPoint("BOTTOMRIGHT", -S.PAD, 4)
    p.playersView = f
    p.overview = AUI():CreateOverview(f, INNER_W)
    p.overview:SetPoint("TOPLEFT")
    p.overview:SetPoint("BOTTOMRIGHT")
    p.overview.onPick = function(key)
        state.player = key
        RaidsUI:Refresh()
    end
    p.playerPage = AUI():CreatePlayerPage(f, INNER_W)
    p.playerPage:SetPoint("TOPLEFT")
    p.playerPage:SetPoint("BOTTOMRIGHT")
    p.playerPage.onBack = function()
        state.player = nil
        RaidsUI:Refresh()
    end
    -- Reviews: what waits for a decision, then what was decided
    p.reviews = AUI():CreateReviews(p, INNER_W)
    p.reviews:SetPoint("TOPLEFT", S.PAD, -TOP)
    p.reviews:SetPoint("BOTTOMRIGHT", -S.PAD, 4)
end

-- The lineups to filter the Attendance view by: every team's lineups.
function H.LineupMenu(root)
    root:CreateRadio("All lineups", function() return state.lineup == nil end, function()
        state.lineup = nil
        RaidsUI:Refresh()
    end)
    local RP = ns.RaidPlan
    for _, t in ipairs(RP and RP.GetTeams and RP:GetTeams() or {}) do
        for _, l in ipairs(t.lineups or {}) do
            local label = t.name .. " · " .. (RP:LineupName(t, l) or "")
            root:CreateRadio(label, function() return state.lineup and state.lineup.id == l.id and state.lineup.team == t.id end,
                function()
                    state.lineup = { team = t.id, id = l.id, label = label }
                    RaidsUI:Refresh()
                end)
        end
    end
end

-- The players view's range menu: how many raids count, and the guests (pugs).
function H.RangeMenu(root)
    for _, n in ipairs(RANGES) do
        root:CreateRadio(H.RangeLabel(n), function() return state.range == n end, function()
            state.range = n
            RaidsUI:Refresh()
        end)
    end
    -- 1.3.5: players outside the guild (pugs), left out unless asked for
    root:CreateDivider()
    local cb = root:CreateCheckbox("Show guests", function() return state.showGuests end, function()
        state.showGuests = not state.showGuests
        RaidsUI:Refresh()
    end)
    cb:SetTitleAndTextTooltip("Show guests", "Players outside the guild (pugs) who raided with us.")
end

-- A view tab clicked: the page's views go through SetView (Teams may ask first), the Raid log's modes switch here.
function H.OnTab(key)
    if key == "raids" then
        state.mode = "raids"
        RaidsUI:Refresh()
    elseif key == "players" then
        state.mode, state.player = "players", nil
        RaidsUI:Refresh()
    elseif key == "reviews" then
        state.mode = "reviews"
        RaidsUI:Refresh()
    else
        RaidsUI:SetView(key)
    end
    -- (a view that didn't change, e.g. Teams kept by its unsaved changes: its tab stays lit)
    if panel then
        panel.toolbar:SelectTab(state.view)
        panel.toolbar:SelectTab(state.mode)
    end
end

function RaidsUI:CreatePanel(parent)
    if panel then return panel end
    local UI = ns.UI
    local p = CreateFrame("Frame", "DisasterZoneRaidsPanel", parent)
    p:SetAllPoints(parent)
    panel = p

    -- the page's views (text tabs); the Raid log's own Raids / Attendance / Reviews modes are smaller tabs after them
    p.layout = UI:CreateLayout("board", p)
    local bar = p.layout.toolbar
    p.toolbar = bar
    bar:SetTabs({
        { key = "upcoming", text = "Upcoming" }, { key = "teams", text = "Teams" },
        { key = "strategies", text = "Strategies" },
        -- 1.3.2: the guest book and the blacklist (players kept out of every raid), for the GM, officers and the raid
        -- leaders. (1.3.5: the prized items' Loot rules view moved to Council > Rules, UI/CouncilRules.lua)
        { key = "guests", text = "Guests" }, { key = "log", text = "Raid log" },
        { key = "raids", text = "Raids", small = true }, { key = "players", text = "Attendance", small = true },
        { key = "reviews", text = "Reviews", small = true },
    }, H.OnTab)
    p.upcomingBtn, p.teamsBtn, p.stratBtn = bar:GetTab("upcoming"), bar:GetTab("teams"), bar:GetTab("strategies")
    p.guestsBtn, p.logBtn = bar:GetTab("guests"), bar:GetTab("log")
    p.raidsBtn, p.playersBtn, p.reviewsBtn = bar:GetTab("raids"), bar:GetTab("players"), bar:GetTab("reviews")

    -- the controls at the row's right (the layout places the shown ones; the main action far right): the Players
    -- view's filters, the raid leaders, Start / End raid, New team / New raid
    p.lineupBtn = UI:CreateSleekMenuButton(bar, "All lineups", 116, H.LineupMenu, S.BTN_H)
    p.rangeBtn = UI:CreateSleekMenuButton(bar, H.RangeLabel(state.range), 110, H.RangeMenu, S.BTN_H)
    -- Addendum J §62: who the raid leaders are (everyone can look; the GM edits)
    p.leadersBtn = UI:CreateTipIconButton(bar, S.BTN_H, UI.ICON.crown, "Raid leaders", "Who plans and leads raids. "
        .. "Everyone can look; officers and the Guild Master change the list.", function() ns.RaidLeadersUI:Open() end)
    p.sessionBtn = UI:CreateSleekButton(bar, "Start raid", 88, S.BTN_H, function()
        if ns.GroupRules:GetSession() then
            ns.SessionBar:ConfirmEnd()
        else
            ns.SessionBar:OpenStart()
        end
    end)
    p.newTeamBtn = UI:CreateSleekButton(bar, "New team", 90, S.BTN_H, function() ns.RaidPlanUI:NewTeam() end, "primary")
    p.newRaidBtn = UI:CreateSleekButton(bar, "New raid", 90, S.BTN_H, function() ns.RaidPlanUI:OpenEditor() end, "primary")
    bar:SetFilters({ p.lineupBtn, p.rangeBtn, p.leadersBtn, p.sessionBtn, p.newTeamBtn, p.newRaidBtn })

    local PlanUI = ns.RaidPlanUI
    p.upcoming = PlanUI:CreateUpcoming(p)
    p.upcoming:SetPoint("TOPLEFT", 0, -TOP)
    p.upcoming:SetPoint("BOTTOMRIGHT", 0, 4)
    p.teams = PlanUI:CreateTeams(p)
    p.teams:SetPoint("TOPLEFT", 0, -TOP)
    p.teams:SetPoint("BOTTOMRIGHT", 0, 4)
    p.strategies = ns.StrategiesUI:CreateLibrary(p)
    p.strategies:SetPoint("TOPLEFT", 0, -TOP)
    p.strategies:SetPoint("BOTTOMRIGHT", 0, 4)
    p.guests = ns.GuestBookUI:CreateView(p)
    p.guests:SetPoint("TOPLEFT", 0, -TOP)
    p.guests:SetPoint("BOTTOMRIGHT", 0, 4)

    H.CreateLogRaids(p)
    H.CreateLogPlayers(p)

    -- (a page switch shows the panel, then calls OnPanelShown: one refresh per frame is enough)
    p:SetScript("OnShow", function(self)
        self.shownAt = GetTime()
        RaidsUI:Refresh()
    end)
    -- 1.3.5: the attendance picker and dialogs close with the page
    p:SetScript("OnHide", function() if ns.AttendanceUI then ns.AttendanceUI:CloseFloating() end end)
    function p:OnPanelShown()
        if self.shownAt ~= GetTime() then RaidsUI:Refresh() end
    end
    C_Timer.After(0, function() RaidsUI:Refresh() end)
    return p
end

function H.RefreshLogRaids(p)
    local L = p.logLayout
    -- 1.3.5: one card per night (a planned raid's logged raids together: a Gruul + Mag run, a restart)
    local raids = {}
    local A = Att()
    if A and A.GetNights then
        for _, n in ipairs(A:GetNights()) do raids[#raids + 1] = A:NightView(n) end
    else
        raids = RL():GetRaids()
    end
    local found = false
    for _, rec in ipairs(raids) do
        for _, id in ipairs(rec.ids or { rec.id }) do
            if id == state.selected then
                found = true
                state.selected = rec.id
            end
        end
    end
    if not found then state.selected = raids[1] and raids[1].id or nil end
    -- (a day with more than one logged raid: their rows say the time)
    local perDay = {}
    for _, rec in ipairs(raids) do
        local day = H.Time(rec.start, "%Y%m%d")
        perDay[day] = (perDay[day] or 0) + 1
    end
    local rows = {}
    for _, rec in ipairs(raids) do
        rows[#rows + 1] = { rec = rec, sameDay = perDay[H.Time(rec.start, "%Y%m%d")] > 1 }
    end
    p.raidList:SetData(rows)
    local sel
    for _, rec in ipairs(raids) do
        if rec.id == state.selected then sel = rec end
    end
    p.selView = sel
    -- nothing logged yet: one illustrated line across the page instead of an empty column and an empty detail
    if #raids == 0 then
        L:ShowEmpty({ glyph = ns.UI.ICON.notes, title = "No raids logged yet",
            text = "The raid leader starts one with Start raid (or /dz raid start)." })
    else
        L:HideEmpty()
    end
    -- the officers who review attendance but don't keep the log: what they see is read only
    if #raids > 0 and not H.LogMember() then
        L:ShowNotice("readonly", "Read only: the raid leaders and the guild council link raids and mark the bench.")
    else
        L:HideNotice()
    end
    p.logDetail:SetShown(sel ~= nil)
    if not sel then
        p.banner:SetTools(nil)
        p.detail:SetData({})
        return
    end
    H.FillBanner(p, sel)
    H.FillLink(p, sel)
    H.FillTabs(p, sel)
    -- 1.3.5: the Attendance tab draws the night's time bars; the link row says how it went
    local att = state.tab == "att" and Att() ~= nil
    p.timeline:SetShown(att)
    p.logHead:SetShown(not att)
    p.detail.frame:SetShown(not att)
    if att then
        local night = Att():NightOf(sel)
        if night then
            local sum = p.timeline:SetNight(night)
            local text = AUI():SummaryText(sum)
            local line = p.signupLine
            if text then
                local room = DETAIL_W - p.linkBtn:GetWidth() - 16
                line.noShow = nil
                line:SetShown(true)
                H.FitVariants(line.fs, { text, AUI():SummaryText(sum, true) or text }, room - 56)   -- (coloured text measures narrow)
                line.fs:SetWidth(room)
                line:SetWidth(room)
            end
        end
        return
    end
    local rows2, place = H.DetailRows(sel)
    p.logHead:SetPlace(place)
    p.detail:SetData(rows2)
end

function RaidsUI:Refresh()
    if not panel or not panel:IsVisible() then return end
    -- (the New / Edit raid sheet covers the tab: the page under it comes back when it closes)
    if ns.RaidPlanUI and ns.RaidPlanUI.IsEditorOpen and ns.RaidPlanUI:IsEditorOpen() then return end
    H.UpdateToolbar(panel)
    local log = state.view == "log"
    panel.upcoming:SetShown(state.view == "upcoming")
    panel.teams:SetShown(state.view == "teams")
    panel.strategies:SetShown(state.view == "strategies")
    panel.guests:SetShown(state.view == "guests")
    local raidsMode = state.mode == "raids"
    panel.logLayout:SetShown(log and raidsMode)
    panel.playersView:SetShown(log and state.mode == "players")
    panel.reviews:SetShown(log and state.mode == "reviews")
    if state.view == "strategies" then
        ns.StrategiesUI:RefreshLibrary()
    elseif state.view == "guests" then
        ns.GuestBookUI:Refresh()
    elseif not log then
        ns.RaidPlanUI:Refresh()
    elseif raidsMode then
        H.RefreshLogRaids(panel)
    elseif state.mode == "reviews" then
        panel.reviews:Refresh()
    else
        panel.overview:SetShown(state.player == nil)
        panel.playerPage:SetShown(state.player ~= nil)
        if state.player then
            panel.playerPage:SetPlayer(state.player)
        else
            panel.overview.state.range = state.range
            panel.overview.state.guests = state.showGuests
            panel.overview.state.lineup = state.lineup
            panel.overview:Refresh()
        end
    end
end

function RaidsUI:RequestRefresh()
    if panel and panel:IsVisible() then ns.Util.Debounce("raids-ui", 0.2, function() RaidsUI:Refresh() end) end
end

-- For tests / other modules: selects a logged raid (and the Raid log's Raids mode).
function RaidsUI:Select(id)
    state.view, state.mode, state.selected, state.tab = "log", "raids", id, "att"
    self:Refresh()
end

-- For tests / other modules: the Raid log's Raids (on a raid's Attendance), Attendance ("players") or Reviews view.
function RaidsUI:SetMode(mode, range)
    state.view, state.tab = "log", "att"
    state.mode = (mode == "players" or mode == "reviews") and mode or "raids"
    state.player = nil
    if range then state.range = range end
    self:Refresh()
end

-- 1.3.5: the Attendance view lists players outside the guild (pugs) too.
function RaidsUI:SetShowGuests(on)
    state.showGuests = on and true or false
    self:Refresh()
end

-- 1.3.5: a member's attendance page (Raid log > Attendance).
function RaidsUI:ShowAttendancePlayer(key)
    state.view, state.mode, state.player = "log", "players", key
    self:Refresh()
end

-- The member whose attendance page is open (or nil).
function RaidsUI:GetAttendancePlayer() return state.player end

-- The Attendance view's lineup filter: { team, id, label } or nil.
function RaidsUI:SetLineupFilter(f)
    state.lineup = f
    self:Refresh()
end

-- The selected logged raid's tab: "att" (Attendance) | "boss" (Bosses) | "award" (Awards).
function RaidsUI:SetLogTab(tab)
    state.tab = (tab == "boss" or tab == "award") and tab or "att"
    self:Refresh()
end

-- "upcoming" | "teams" | "strategies" | "guests" (roster managers) | "log" (the log is council only). ("rules", the old
-- Loot rules view, opens Council > Rules.)
function RaidsUI:SetView(view)
    if view == "rules" then
        if ns.MainFrame then ns.MainFrame:Open("council") end
        if ns.CouncilUI then ns.CouncilUI:SetView("rules") end
        return
    end
    if view ~= "teams" and view ~= "log" and view ~= "strategies" and view ~= "guests" then
        view = "upcoming"
    end
    -- leaving Teams with unsaved changes asks first (Save / Discard / Cancel)
    if state.view == "teams" and view ~= "teams" and panel and panel:IsVisible() and ns.RaidPlanUI.GuardDraft then
        return ns.RaidPlanUI:GuardDraft(function()
            state.view = view
            RaidsUI:Refresh()
        end)
    end
    state.view = view
    self:Refresh()
end

function RaidsUI:GetView() return state.view end

function RaidsUI:GetPanel() return panel end

-- Everyone in a guild plans raids here; the raid log inside stays council only.
function RaidsUI:IsAvailable()
    return (IsInGuild() or isCouncil()) and true or false
end

function RaidsUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("raids", "Raids", 3.5,
            function(parent) return RaidsUI:CreatePanel(parent) end,
            function() return RaidsUI:IsAvailable() end, { layout = "board" })
    end
    local function refresh() RaidsUI:RequestRefresh() end
    for _, msg in ipairs({ "RAIDLOG_CHANGED", "LEDGER_UPDATED", "GROUP_RULES_CHANGED", "ROSTER_UPDATED", "ITEMINFO_READY",
                           "DEMO_TOGGLED", "CONFIG_UPDATED", "ATTENDANCE_RULES_CHANGED" }) do
        ns:On(msg, refresh)
    end
    ns:RegisterSlash("raids", function()
        state.view = "upcoming"
        ns.MainFrame:Open("raids")
        RaidsUI:Refresh()
    end, "open the Raids tab: upcoming raids and sign-ups")
end
