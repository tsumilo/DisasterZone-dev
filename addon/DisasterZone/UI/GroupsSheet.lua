if DisasterZoneBoot and DisasterZoneBoot.Run("UI/GroupsSheet.lua", ...) then return end -- DisasterZone: UI/GroupsSheet.lua
-- (1.5) List a group: the sheet over the Groups tab (a cover: UI:CreateSheet), one sheet for every kind. Its head:
-- "List a group" and the kinds as underline tabs (Dungeon / Raid / Quest / PvP / Other), the pick's art as a faint
-- band behind it. Dungeon is the 1.4 sheet (complex rows, the form on the left, the preview on the right); the
-- other kinds lay out top down: their picker (raid tiles; the quest picker with its rail; PvP modes; other kinds),
-- the rows they need (when, places per role as steppers, bosses, loot, note, my role), then the preview (exactly the
-- card the guild sees) with List group beside it and one line on who gets a ping. State: ns.GroupsCard.state.sheet;
-- DungeonsUI keeps its calls (OpenSheet, SetSheet, SubmitSheet, GetSheetState, ...) and forwards them here.
local addonName, ns = ...

local GS = {}
ns.GroupsSheet = GS
local S = ns.Style

local floor, max, min = math.floor, math.max, math.min
local tconcat, tremove = table.concat, table.remove

local function R() return ns.DungeonRuns end
local function UI() return ns.UI end
local function Me() return ns.Util.PlayerKey() end
local function DUI() return ns.DungeonsUI end
local function G() return ns.GroupsCard end

local PAD = S.PAD
local CARD_H = 72
local GOLD = S.C.GOLD
local SHEET_BG = { 0.035, 0.035, 0.043, 1 }
local HEAD_H = 38                 -- the title and the kind tabs
local LBL = 92                    -- the rows' label column
local ROW = 33                    -- a row's step
local GO_W = 150
local BAND_H = 190
local STAR_TEX = "Interface\\AddOns\\DisasterZone\\Media\\Icons\\bis"
local HEROIC_TEX = "Interface\\LFGFrame\\UI-LFG-ICON-HEROIC"
local HEROIC_ICON = "|T" .. HEROIC_TEX .. ":13:10:0:0:32:32:0:16:0:20|t"
local DAILY_ICON = "|TInterface\\GossipFrame\\DailyQuestIcon:12:12:0:0|t"
local TILE_W, TILE_H, TILE_GAP = 130, 34, 5          -- a dungeon tile
local ROW_H, ROW_GAP = S.ROW.art, 6                  -- a complex row
local FORM_LABEL_W, FORM_W = 62, 286                 -- the dungeon form
local DAYS_AHEAD = 6

local KINDS = { { "dungeon", "Dungeon" }, { "raid", "Raid" }, { "quest", "Quest" }, { "pvp", "PvP" },
                { "other", "Other" } }
local WHEN = { { key = "now", text = "Now" }, { key = "30", text = "In 30 min" }, { key = "60", text = "In 1 h" },
               { key = "later", text = "Later" } }
local LOOT_ITEMS = { { key = "roll", label = "Rolls" }, { key = "sr", label = "Soft reserve" },
                     { key = "lc", label = "Loot council" } }
local PVP_MODES = {
    { key = "arena", title = "Arena", sub = "2v2 · 3v3 · 5v5", art = "arena3", icon = "arena3" },
    { key = "bg", title = "Battlegrounds", sub = "4 battlegrounds", art = "eots", icon = "towers" },
    { key = "world", title = "World PvP", sub = "Halaa · Spirit Towers", art = "halaa", icon = "halaa" },
}

local state = ns.GroupsCard.state
local sh   -- the sheet (one, made on the first open)

local function Refresh() GS:Refresh() end
local function HideTip() GameTooltip:Hide() end

---------------------------------------------------------------------------
-- Time (the When row)
---------------------------------------------------------------------------

local function NowMinutes()
    local t = date("*t", ns.Util.Now())
    return t.hour * 60 + t.min
end
local function MinMinutes(day)
    if day > 0 then return 0 end
    return math.ceil((NowMinutes() + 15) / 15) * 15
end
local function DayTime(day, mins)
    local t = date("*t", ns.Util.Now())
    return time({ year = t.year, month = t.month, day = t.day + day, hour = floor(mins / 60), min = mins % 60, sec = 0 })
end
local function SheetTime(s)
    if s.when == "now" then return 0 end
    if s.when == "30" then return ns.Util.Now() + 1800 end
    if s.when == "60" then return ns.Util.Now() + 3600 end
    return DayTime(s.day or 0, s.mins or 0)
end
local function DefaultLater(s)
    local mins = math.ceil((NowMinutes() + 60) / 60) * 60
    if mins >= 24 * 60 then s.day, s.mins = 1, 20 * 60 else s.day, s.mins = 0, mins end
end
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
GS.SheetTime = SheetTime

---------------------------------------------------------------------------
-- Small parts
---------------------------------------------------------------------------

-- A row: its grey label on the left, the controls from x = LBL.
local function NewRow(parent, label)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(26)
    r.label = UI():Text(r, "body", "SUB")
    r.label:SetPoint("LEFT", 0, 0)
    r.label:SetText(label or "")
    r:Hide()
    return r
end

-- A gold 2 px frame round a tile (shown while it is picked).
local function AddPickFrame(t)
    t.pick = {}
    local function edge(p1, p2, horiz)
        local e = t:CreateTexture(nil, "OVERLAY", nil, 3)
        e:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
        e:SetPoint(p1)
        e:SetPoint(p2)
        if horiz then e:SetHeight(2) else e:SetWidth(2) end
        t.pick[#t.pick + 1] = e
    end
    edge("TOPLEFT", "TOPRIGHT", true)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
    edge("TOPLEFT", "BOTTOMLEFT", false)
    edge("TOPRIGHT", "BOTTOMRIGHT", false)
    function t:SetPicked(on)
        for _, e in ipairs(self.pick) do e:SetShown(on and true or false) end
    end
    t:SetPicked(false)
end

local function TipScripts(f)
    f:SetScript("OnEnter", function(self)
        local lines = self.tip and self.tip()
        if lines then UI():SetTextTooltip(self, lines, "ANCHOR_TOP") end
    end)
    f:SetScript("OnLeave", HideTip)
end

-- An art tile (raids, PvP modes, other kinds): the picture under a shade, the name and a line under it, a corner
-- (★ n or a lock), the gold frame while picked; dimmed while it can't be picked.
local function NewArtTile(parent)
    local t = CreateFrame("Button", nil, parent)
    t.art = t:CreateTexture(nil, "BACKGROUND")
    t.art:SetAllPoints()
    t.shade = t:CreateTexture(nil, "BORDER")
    t.shade:SetAllPoints()
    t.shade:SetColorTexture(1, 1, 1, 1)
    UI():Gradient(t.shade, "VERTICAL", { 0.02, 0.02, 0.03, 0.92 }, { 0.02, 0.02, 0.03, 0.1 })
    UI():AddEdges(t, "ARTWORK")
    UI():SetEdgeColor(t, unpack(S.C.EDGE))
    t.name = UI():Text(t, "emph", "TEXT")
    t.name:SetPoint("BOTTOMLEFT", 9, 20)
    t.name:SetPoint("RIGHT", -6, 0)
    t.name:SetJustifyH("LEFT")
    t.sub = UI():Text(t, "small", "SUB")
    t.sub:SetPoint("BOTTOMLEFT", 9, 6)
    t.corner = UI():Text(t, "small", "GOLD")
    t.corner:SetPoint("TOPRIGHT", -7, -6)
    t.star = t:CreateTexture(nil, "OVERLAY")
    t.star:SetTexture(STAR_TEX)
    t.star:SetSize(11, 11)
    t.star:SetPoint("RIGHT", t.corner, "LEFT", -2, 0)
    t.lock = t:CreateTexture(nil, "OVERLAY")
    t.lock:SetTexture(UI().ICON_LOCK)
    t.lock:SetSize(13, 13)
    t.lock:SetPoint("TOPRIGHT", -7, -6)
    t.hl = t:CreateTexture(nil, "HIGHLIGHT")
    t.hl:SetAllPoints()
    t.hl:SetColorTexture(S.C.HOVER[1], S.C.HOVER[2], S.C.HOVER[3], S.C.HOVER[4])
    AddPickFrame(t)
    TipScripts(t)
    return t
end

-- Fills an art tile: run = a group of that activity (its art), off = can't be picked.
local function FillArtTile(t, run, name, sub, picked, off, corner)
    local w, h = t:GetWidth(), t:GetHeight()
    local file, l, r, tt, b = R():GetGroupArt(run, w, h)
    t.art:SetTexture(file)
    if file then t.art:SetTexCoord(l, r, tt, b) end
    t.art:SetDesaturated(off and true or false)
    t.art:SetAlpha(off and 0.45 or 1)
    t.name:SetText(name)
    t.name:SetTextColor(S:Color(off and "DIM" or "TEXT"))
    t.sub:SetText(sub or "")
    t:SetPicked(picked and not off)
    t.lock:SetShown(corner == "lock")
    local n = type(corner) == "number" and corner or 0
    t.corner:SetShown(n > 0)
    t.star:SetShown(n > 0)
    t.corner:SetText(n > 0 and tostring(n) or "")
end

-- A role's places: a stepper with the role's icon before the number.
local function NewRoleStepper(parent, role)
    local st = UI():CreateStepper(parent, 92, function(dir) GS:StepPlaces(role, dir) end,
        { tip = { R().ROLE_LABEL[role], "Places for this role (you count in yours)." } })
    st.role = role
    return st
end

-- Things the page asks the core for, on the generic shape of a sheet's group.
local function Kind() return state.sheet and state.sheet.kind or "dungeon" end

---------------------------------------------------------------------------
-- Places (every kind but dungeons): the size and the places per role
---------------------------------------------------------------------------

local function PvPEntry(key)
    for _, p in ipairs(R():GetActivities("pvp")) do
        if p.key == key then return p end
    end
    return nil
end

local function RaidSize(s)
    local n = 10
    for _, rk in ipairs(s.ra or {}) do
        for _, r in ipairs(R():GetActivities("raid")) do
            if r.key == rk then n = max(n, r.size or 25) end
        end
    end
    return n
end

-- The group's size and the activity that sets its default places.
local function SheetSize(s)
    local kind = s.kind
    if kind == "raid" then return RaidSize(s), nil end
    if kind == "pvp" then
        local p = PvPEntry(s.pa)
        return p and p.size or 3, s.pa
    end
    if kind == "quest" then
        local n = 2
        for _, id in ipairs(s.qs or {}) do
            local q = ns.GroupQuests and ns.GroupQuests:Get(id)
            n = max(n, q and q.players or 3)
        end
        return min(s.n or n, 5), nil
    end
    return s.n or 5, nil
end

-- n and the places { tank, healer, dps } (the ones set with the steppers, else the defaults for the size).
local function SheetPlaces(s)
    local n, key = SheetSize(s)
    local w = s.w
    if not w or s.wn ~= n then
        local d = R():GetDefaultWant(s.kind, n, key)
        w = { tank = d.tank, healer = d.healer, dps = d.dps }
        s.w, s.wn = w, n
    end
    return n, w
end

function GS:StepPlaces(role, dir)
    local s = state.sheet
    if not s then return end
    local n, w = SheetPlaces(s)
    local v = (w[role] or 0) + dir
    if v < 0 or (dir > 0 and w.tank + w.healer + w.dps >= n) then return end
    w[role] = v
    Refresh()
end

---------------------------------------------------------------------------
-- Raids
---------------------------------------------------------------------------

local function GuildPhase()
    local Gd = ns.Guild
    return Gd and Gd.GetGuildPhase and tonumber(Gd:GetGuildPhase()) or 5
end

local function RaidInfo(key)
    return ns.ItemDB and ns.ItemDB.GetRaid and ns.ItemDB:GetRaid(key)
end

-- The bosses of the picked raids that count for a clear: { { key = "Karazhan:Attumen", name } }.
local function RaidBosses(keys)
    local out = {}
    for _, rk in ipairs(keys or {}) do
        local raid = RaidInfo(rk)
        for _, b in ipairs(raid and raid.bosses or {}) do
            if not b.isTrash then out[#out + 1] = { key = rk .. ":" .. tostring(b.key), name = b.name } end
        end
    end
    return out
end

-- Why a raid can't be picked ("saved", "phase"), or nil; the attunement I miss (a hint) second.
local function RaidState(key)
    local info = RaidInfo(key)
    if R():GetRaidSaved(key) then return "saved" end
    if info and info.phase and info.phase > GuildPhase() then return "phase" end
    local miss = R():GetMissingAttunements({ k = "raid", a = { key } })
    return nil, miss[1]
end

local function RaidTileTip(key, size)
    return function()
        local info = RaidInfo(key)
        local lines = { { info and info.name or key, S:Color("GOLD") },
            size .. " players" .. (info and info.phase and (" · Phase " .. info.phase) or "") }
        local why, attune = RaidState(key)
        if why == "phase" then
            lines[#lines + 1] = S:Wrap("WARN", "Not open yet: your guild is in phase " .. GuildPhase() .. ".")
        end
        local untilT, done, total = R():GetRaidSaved(key)
        if untilT then
            lines[#lines + 1] = S:Wrap("WARN", "You're saved here" .. ((done and total)
                and (" (" .. done .. " of " .. total .. ")") or "") .. ".")
        end
        if attune then lines[#lines + 1] = S:Wrap("WARN", "You haven't done " .. attune .. ".") end
        local n = R():GetRaidNeeders(key)
        if n > 0 then
            lines[#lines + 1] = "|T" .. STAR_TEX .. ":11:11:0:0|t " .. n .. (n == 1 and " guildie online has" or
                " guildies online have") .. " BiS here"
        end
        local drops = R():GetGroupBiSDrops({ k = "raid", a = { key } })
        if #drops > 0 then
            lines[#lines + 1] = S:Wrap("GOLD", "Drops your BiS:")
            for i, id in ipairs(drops) do
                if i > 6 then lines[#lines + 1] = S:Wrap("SUB", "+" .. (#drops - 6) .. " more") break end
                lines[#lines + 1] = "  " .. G().ItemLinkText(id)
            end
        end
        if #lines > 1 then lines[#lines + 1] = S:Wrap("SUB", "Pick a few of one size: one night, one group.") end
        return lines
    end
end

local function ToggleRaid(key, size)
    local s = state.sheet
    local at
    for i, rk in ipairs(s.ra) do if rk == key then at = i end end
    if at then
        tremove(s.ra, at)
    else
        if #s.ra > 0 and RaidSize(s) ~= size then s.ra = {} end
        if #s.ra < 6 then s.ra[#s.ra + 1] = key end
    end
    if s.bo then
        local keep = {}
        for _, b in ipairs(RaidBosses(s.ra)) do keep[b.key] = s.bo[b.key] end
        s.bo = keep
    end
    s.err = nil
    Refresh()
end

---------------------------------------------------------------------------
-- The sheet's group as List takes it, and the preview's run
---------------------------------------------------------------------------

local function Opts(s)
    local kind = s.kind
    local o = { at = SheetTime(s), no = s.no, role = s.role }
    if kind == "dungeon" then
        if not s.d then return nil end
        o.d, o.h, o.gf = s.d, s.h, s.gf
        return o
    end
    o.k = kind
    local n, w = SheetPlaces(s)
    o.n, o.w = n, { tank = w.tank, healer = w.healer, dps = w.dps }
    if kind == "raid" then
        if #s.ra == 0 then return nil end
        o.a = {}
        for i, rk in ipairs(s.ra) do o.a[i] = rk end
        o.lo = s.lo or "roll"
        o.lr = o.lo == "sr" and (s.lr or 1) or nil
        if s.bo then
            local bo = {}
            for _, b in ipairs(RaidBosses(s.ra)) do
                if s.bo[b.key] then bo[#bo + 1] = b.key end
            end
            o.bo = #bo > 0 and bo or nil
        end
    elseif kind == "quest" then
        if #(s.qs or {}) == 0 then return nil end
        o.a = {}
        for i, id in ipairs(s.qs) do o.a[i] = id end
    elseif kind == "pvp" then
        if not s.pa then return nil end
        o.a = { s.pa }
        o.n = nil
        local p = PvPEntry(s.pa)
        if p and p.mode == "arena" and s.pr then o.pr, o.mr = true, s.mr end
        if p and p.mode == "bg" then o.fc = s.fc end
    else
        if not s.oa then return nil end
        o.a = { s.oa }
    end
    return o
end
GS.Opts = Opts

-- The card the guild will see (exactly FillCard's), as a run built from the sheet: nil while nothing is picked.
local function PreviewRun(s)
    local o = Opts(s)
    if not o then return nil end
    local party = { { k = Me(), r = s.role } }
    for key in pairs(ns.Util.group or {}) do
        if not ns.Util.IsMe(key) then party[#party + 1] = { k = key, r = R():GetRoleOf(key) } end
    end
    local mine = R():GetMyGroup()
    local run = { id = "preview", o = Me(), at = o.at, c = mine and mine.c or ns.Util.Now(), s = party,
                  no = (s.no and ns.Util.Trim(s.no) ~= "") and ns.Util.Trim(s.no) or nil }
    if run.at > 0 and run.at <= ns.Util.Now() + 60 then run.at = 0 end
    if o.k == nil then
        run.d, run.h = o.d, o.h or nil
        return run
    end
    run.k, run.a, run.n, run.w = o.k, o.a, o.n, o.w
    run.lo, run.lr, run.bo, run.pr, run.mr, run.fc = o.lo, o.lr, o.bo, o.pr, o.mr, o.fc
    if o.k == "quest" and ns.GroupQuests then
        for i, id in ipairs(run.a) do run.a[i] = ns.GroupQuests:Key(id) or id end
    end
    if o.k == "pvp" then
        local p = PvPEntry(s.pa)
        run.n = p and p.size or 3
        if run.pr then
            local team = ns.GroupPvP and ns.GroupPvP:GetTeam(p.bracket)
            run.tn = team and team.name or nil
        end
    end
    return run
end
GS.PreviewRun = PreviewRun

---------------------------------------------------------------------------
-- Building the sheet
---------------------------------------------------------------------------

local function CreateDungeonParts()
    -- Normal / Heroic, on the head's right
    sh.mode = UI():CreateSegments(sh, { { key = "normal", label = "Normal" },
        { key = "heroic", label = HEROIC_ICON .. " Heroic" } }, function(key)
        state.sheet.h = key == "heroic"
        state.sheet.err = nil
        Refresh()
    end, { h = S.BTN_H, itemW = 82 })
    sh.rows = {}
    -- the form (left): When, (At), Note, You go as, Pugs
    local form = CreateFrame("Frame", nil, sh)
    form:SetSize(FORM_LABEL_W + FORM_W, 140)
    sh.form = form
    sh.gfRow = CreateFrame("Frame", nil, form)
    sh.gfRow:SetSize(FORM_LABEL_W + FORM_W, 24)
    sh.gfLabel = UI():Text(sh.gfRow, "body", "SUB")
    sh.gfLabel:SetText("Pugs")
    sh.gfLabel:SetPoint("LEFT", 0, 0)
    local function flip()
        state.sheet.gf = not state.sheet.gf
        Refresh()
    end
    local function gfTip(self)
        UI():SetTextTooltip(self, { "Group Finder", "Also puts your run in Blizzard's Group Finder, for players outside "
            .. "the guild. Whoever looks for this dungeon there, or whispers you, shows up on your run.",
            S:Wrap("SUB", "A run for later: you get a pop-up when it starts.") }, "ANCHOR_TOP")
    end
    sh.gf = UI():CreateSwitch(sh.gfRow, nil, function() flip() end)
    sh.gf:SetPoint("LEFT", FORM_LABEL_W, 0)
    sh.gf:SetScript("OnEnter", gfTip)
    sh.gf:SetScript("OnLeave", HideTip)
    sh.gfText = CreateFrame("Button", nil, sh.gfRow)
    sh.gfText.text = UI():Text(sh.gfText, "emph", "TEXT")
    sh.gfText.text:SetPoint("LEFT")
    sh.gfText:SetPoint("LEFT", sh.gf, "RIGHT", 8, 0)
    sh.gfText:SetScript("OnClick", flip)
    sh.gfText:SetScript("OnEnter", gfTip)
    sh.gfText:SetScript("OnLeave", HideTip)
end

-- The rows every kind shares (When + At, Note, You go as), made once and placed per kind.
local function CreateSharedRows()
    sh.whenRow = NewRow(sh, "When")
    local items = {}
    for i, def in ipairs(WHEN) do items[i] = { key = def.key, label = def.text } end
    sh.when = UI():CreateSegments(sh.whenRow, items, function(key)
        local s = state.sheet
        if s.when == key then return end
        s.when = key
        if key == "later" and not s.mins then DefaultLater(s) end
        Refresh()
    end, { h = S.BTN_H })
    local stepTip = { "Pick the time", "Click the arrows or scroll. Your clock; everybody sees it in theirs." }
    sh.day = UI():CreateStepper(sh.whenRow, 150, function(dir)
        local s = state.sheet
        s.day = (s.day or 0) + dir
        ClampLater(s)
        Refresh()
    end, { tip = stepTip })
    sh.time = UI():CreateStepper(sh.whenRow, 96, function(dir)
        local s = state.sheet
        s.mins = (s.mins or 0) + dir * 15
        ClampLater(s)
        Refresh()
    end, { tip = stepTip })
    sh.noteRow = NewRow(sh, "Note")
    sh.note = UI():CreateSleekEditBox(sh.noteRow, FORM_W, 24, "GameFontHighlightSmall")
    sh.note:SetMaxLetters(R().NOTE_MAX)
    sh.fields[#sh.fields + 1] = sh.note
    sh.note:SetScript("OnTextChanged", function(self)
        if state.sheet then state.sheet.no = self:GetText() end
        GS:RefreshPreview()
    end)
    UI():SetEditPlaceholder(sh.note, "Optional, e.g. \"badge run, fast pulls\"")
    sh.roleRow = NewRow(sh, "You go as")
    sh.roles = UI():CreateSegments(sh.roleRow, {}, function(key)
        state.sheet.role = key
        Refresh()
    end, { h = S.BTN_H, itemW = 34 })
end

local function CreateRaidParts()
    sh.raidTiles = {}
    sh.placesRow = NewRow(sh, "Places")
    sh.steppers = {}
    for _, role in ipairs(R().ROLES) do sh.steppers[role] = NewRoleStepper(sh.placesRow, role) end
    sh.placesText = UI():Text(sh.placesRow, "small", "SUB")
    sh.bossRow = NewRow(sh, "Bosses")
    sh.bossMode = UI():CreateSegments(sh.bossRow, { { key = "all", label = "Full clear" }, { key = "pick", label = "Pick" } },
        function(key)
            local s = state.sheet
            s.bo = key == "pick" and (s.bo or {}) or nil
            Refresh()
        end, { h = S.BTN_H, itemW = 82 })
    sh.bossMode:SetPoint("LEFT", LBL, 0)
    sh.bossPick = UI():CreateMultiDropdown(sh.bossRow, 240, function()
        local out = {}
        for _, b in ipairs(RaidBosses(state.sheet and state.sheet.ra)) do out[#out + 1] = { value = b.key, text = b.name } end
        return out
    end, function(v) return state.sheet and state.sheet.bo and state.sheet.bo[v] end, function(v, on)
        local s = state.sheet
        if s and s.bo then
            s.bo[v] = on or nil
            Refresh()
        end
    end, function()
        local s = state.sheet
        local all, n = RaidBosses(s and s.ra), 0
        for _, b in ipairs(all) do if s.bo and s.bo[b.key] then n = n + 1 end end
        return n == 0 and "Pick the bosses" or (n .. " of " .. #all .. " bosses")
    end)
    sh.bossPick:SetPoint("LEFT", sh.bossMode, "RIGHT", 10, 0)
    sh.lootRow = NewRow(sh, "Loot")
    sh.loot = UI():CreateSegments(sh.lootRow, LOOT_ITEMS, function(key)
        state.sheet.lo = key
        Refresh()
    end, { h = S.BTN_H })
    sh.loot:SetPoint("LEFT", LBL, 0)
    sh.reserves = UI():CreateStepper(sh.lootRow, 70, function(dir)
        local s = state.sheet
        local lr = (s.lr or 1) + dir
        if lr < 1 or lr > 3 then return end
        s.lr = lr
        Refresh()
    end, { tip = "Items each player can soft reserve." })
    sh.reserves:SetPoint("LEFT", sh.loot, "RIGHT", 12, 0)
    sh.reservesText = UI():Text(sh.lootRow, "small", "SUB")
    sh.reservesText:SetPoint("LEFT", sh.reserves, "RIGHT", 8, 0)
    sh.reservesText:SetText("each")
end

-- The quest picker: the rail (my log, guildies, zones), the search box, the list (scrolls), the picked chips.
local function CreateQuestParts()
    local q = CreateFrame("Frame", nil, sh)
    sh.quest = q
    q.rail = UI():CreateScrollFrame(q)
    q.railBody = CreateFrame("Frame", nil, q.rail)
    q.railBody:SetSize(200, 10)
    q.rail:SetScrollChild(q.railBody)
    q.railItems = {}
    q.search = UI():CreateSearchBox(q, 260, function(text)
        local s = state.sheet
        if not s then return end
        s.qsearch = text
        if text ~= "" then s.qview = "search" elseif s.qview == "search" then s.qview = "log" end
        Refresh()
    end, "Search group quests")
    sh.fields[#sh.fields + 1] = q.search
    q.caption = UI():Text(q, "body", "SUB")
    q.list = UI():CreateScrollFrame(q)
    q.body = CreateFrame("Frame", nil, q.list)
    q.body:SetSize(400, 10)
    q.list:SetScrollChild(q.body)
    q.rows, q.heads = {}, {}
    sh.pickedRow = NewRow(sh, "Picked")
    sh.pickedChips = {}
    sh.pickedPill = UI():CreatePill(sh.pickedRow, "bis", "")
end

local function CreatePvPParts()
    sh.pvpTiles = {}
    sh.bracketRow = NewRow(sh, "Bracket")
    sh.bracket = UI():CreateSegments(sh.bracketRow, {}, function(key)
        state.sheet.pa = key
        state.sheet.err = nil
        Refresh()
    end, { h = S.BTN_H })
    sh.bracket:SetPoint("LEFT", LBL, 0)
    sh.gamesLabel = UI():Text(sh.bracketRow, "body", "SUB")
    sh.gamesLabel:SetText("Games")
    sh.games = UI():CreateSegments(sh.bracketRow, { { key = "skirmish", label = "Skirmish" }, { key = "rated", label = "Rated" } },
        function(key)
            state.sheet.pr = key == "rated"
            state.sheet.err = nil
            Refresh()
        end, { h = S.BTN_H, itemW = 76 })
    sh.fcSwitch = UI():CreateSwitch(sh.bracketRow, nil, function()
        state.sheet.fc = not state.sheet.fc
        Refresh()
    end)
    sh.fcText = UI():Text(sh.bracketRow, "emph", "TEXT")
    sh.fcText:SetText("Flag carrier wanted")
    -- the rated team strip
    local t = CreateFrame("Frame", nil, sh)
    t:SetHeight(46)
    t.bg = UI():Fill(t, "CARD", "BACKGROUND")
    UI():AddEdges(t, "BORDER")
    UI():SetEdgeColor(t, GOLD[1], GOLD[2], GOLD[3], 0.45)
    t.face = UI():CreateFace(t, 30)
    t.face:SetPoint("LEFT", 10, 0)
    t.title = UI():Text(t, "emph", "TEXT")
    t.title:SetPoint("TOPLEFT", t.face, "TOPRIGHT", 12, 2)
    t.sub = UI():Text(t, "small", "SUB")
    t.sub:SetPoint("TOPLEFT", t.title, "BOTTOMLEFT", 0, -3)
    t.rating = UI():CreateStepper(t, 110, function(dir)
        local s = state.sheet
        s.mr = min(max((s.mr or 1500) + dir * 50, 0), 3000)
        Refresh()
    end, { tip = { "Lowest rating", "Pings go to guildies whose rating for this bracket is this or more." } })
    t.rating:SetPoint("RIGHT", -10, 0)
    sh.team = t
    sh.alreadyRow = NewRow(sh, "Already listed")
    sh.alreadyRow:SetHeight(34)
    sh.already = {}
end

local function CreateOtherParts()
    sh.otherTiles = {}
    sh.sizeRow = NewRow(sh, "Players")
    sh.size = UI():CreateStepper(sh.sizeRow, 92, function(dir)
        local s = state.sheet
        local n = SheetSize(s)
        s.n = min(max(n + dir, 2), 40)
        Refresh()
    end, { tip = "How many players the group wants, you included." })
    sh.size:SetPoint("LEFT", LBL, 0)
end

local function CreateSheet(p)
    sh = UI():CreateSheet(p, { cover = true, bg = SHEET_BG, rule = false, onClose = function()
        if state.sheet and p:IsVisible() then GS:Close() end
    end })
    UI():AttachTooltip(sh.close, "Close", "Nothing is listed.", { anchor = "ANCHOR_LEFT" })
    sh.title:SetText("List a group")
    -- the pick's art, faint, behind the head
    sh.band = sh:CreateTexture(nil, "BACKGROUND", nil, 2)
    sh.band:SetPoint("TOPLEFT", 1, -1)
    sh.band:SetPoint("TOPRIGHT", -1, -1)
    sh.band:SetHeight(BAND_H)
    sh.band:SetAlpha(0.3)
    sh.bandShade = sh:CreateTexture(nil, "BACKGROUND", nil, 3)
    sh.bandShade:SetAllPoints(sh.band)
    sh.bandShade:SetColorTexture(1, 1, 1, 1)
    UI():Gradient(sh.bandShade, "VERTICAL", SHEET_BG, { SHEET_BG[1], SHEET_BG[2], SHEET_BG[3], 0.2 })
    -- the kinds
    sh.tabs = {}
    for _, k in ipairs(KINDS) do
        local key = k[1]
        local b = UI():CreateUnderlineTab(sh, k[2], function()
            local s = state.sheet
            if not s or s.kind == key or s.edit then return end
            s.kind = key
            s.err = nil
            Refresh()
        end)
        b.key = key
        sh.tabs[#sh.tabs + 1] = b
    end
    sh.headRule = UI():Rule(sh, { top = HEAD_H, left = PAD, right = PAD })
    sh.fields = sh.fields or {}
    CreateSharedRows()
    CreateDungeonParts()
    CreateRaidParts()
    CreateQuestParts()
    CreatePvPParts()
    CreateOtherParts()
    -- the preview, its button and the line on who gets a ping
    sh.previewRule = UI():Rule(sh, { layer = "BORDER" })
    sh.previewLabel = UI():CreateSectionHeader(sh, "Preview", { style = "caps" })
    sh.preview = G().NewRunCard(sh)
    sh.preview:EnableMouse(false)
    sh.pick = UI():Text(sh, "emph", "SUB")
    sh.foot = UI():Text(sh, "small", "SUB", { wrap = true })
    sh.go = UI():CreateSleekButton(sh, "List group", GO_W, S.BTN_H + 6, function() GS:Submit() end, "primary")
    sh.err:ClearAllPoints()
    sh:Hide()
    p.sheet = sh
    return sh
end

---------------------------------------------------------------------------
-- Laying it out
---------------------------------------------------------------------------

local function Width()
    local p = DUI():GetPanel()
    local w = p and p:GetWidth()
    return (w and w >= 300) and w or 780
end
local function Height()
    local p = DUI():GetPanel()
    local h = p and p:GetHeight()
    return (h and h >= 300) and h or 540
end

local function HideKindParts()
    for _, r in ipairs(sh.rows) do r:Hide() end
    sh.form:Hide()
    sh.mode:Hide()
    for _, t in ipairs(sh.raidTiles) do t:Hide() end
    for _, t in ipairs(sh.pvpTiles) do t:Hide() end
    for _, t in ipairs(sh.otherTiles) do t:Hide() end
    for _, r in ipairs({ sh.whenRow, sh.noteRow, sh.roleRow, sh.placesRow, sh.bossRow, sh.lootRow, sh.pickedRow,
                         sh.bracketRow, sh.alreadyRow, sh.sizeRow }) do r:Hide() end
    sh.quest:Hide()
    sh.team:Hide()
end

-- Places a row at y (from the sheet's top), full width; returns the y under it.
local function Place(row, y, width)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, y)
    row:SetWidth(width or (Width() - 2 * PAD))
    row:Show()
    return y - ROW
end

local function FillWhen(s, x)
    sh.when:ClearAllPoints()
    sh.when:SetPoint("LEFT", sh.whenRow, "LEFT", x or LBL, 0)
    sh.when:Select(s.when)
    local later = s.when == "later"
    sh.day:SetShown(later)
    sh.time:SetShown(later)
    if later then
        ClampLater(s)
        local minDay = MinMinutes(0) >= 24 * 60 and 1 or 0
        sh.day:ClearAllPoints()
        sh.day:SetPoint("LEFT", sh.when, "RIGHT", 10, 0)
        sh.day:Set(DayText(s.day), s.day > minDay, s.day < DAYS_AHEAD)
        sh.time:ClearAllPoints()
        sh.time:SetPoint("LEFT", sh.day, "RIGHT", 6, 0)
        sh.time:Set(("%02d:%02d"):format(floor(s.mins / 60), s.mins % 60), s.mins > MinMinutes(s.day), s.mins < 24 * 60 - 15)
    end
end

local function FillRoles(s, only)
    local roles = {}
    for _, role in ipairs(R():GetPlayableRoles()) do
        if not only or only[role] then
            roles[#roles + 1] = { key = role, label = UI():RoleIconText(role, 16), tip = R().ROLE_LABEL[role]
                .. ": the role you play in this group." }
        end
    end
    if #roles == 0 then roles[1] = { key = "dps", label = UI():RoleIconText("dps", 16) } end
    local ok = false
    for _, r in ipairs(roles) do if r.key == s.role then ok = true end end
    if not ok then s.role = roles[1].key end
    sh.roles:SetItems(roles)
    sh.roles:Select(s.role)
    sh.roles:ClearAllPoints()
    sh.roles:SetPoint("LEFT", sh.roleRow, "LEFT", LBL, 0)
end

-- Places: the role steppers (no tanks in PvP) and "n of size".
local function FillPlaces(s, noTanks)
    local n, w = SheetPlaces(s)
    if noTanks and w.tank > 0 then
        w.dps, w.tank = w.dps + w.tank, 0
    end
    local x = LBL
    local sum = w.tank + w.healer + w.dps
    for _, role in ipairs(R().ROLES) do
        local st = sh.steppers[role]
        if noTanks and role == "tank" then
            st:Hide()
        else
            st:ClearAllPoints()
            st:SetPoint("LEFT", sh.placesRow, "LEFT", x, 0)
            st:Set(UI():RoleIconText(role, 14) .. "  " .. w[role], w[role] > 0, sum < n)
            st:Show()
            x = x + 98
        end
    end
    sh.placesText:ClearAllPoints()
    sh.placesText:SetPoint("LEFT", sh.placesRow, "LEFT", x + 6, 0)
    sh.placesText:SetText(sum .. " of " .. n .. (noTanks and "   ·   No tanks in PvP" or ""))
    return x + 6 + (sh.placesText:GetStringWidth() or 60)
end

-- The raid tiles: two rows of five; returns the y under them.
local function LayoutRaidTiles(s, y)
    local width = Width() - 2 * PAD
    local per, gap = 5, 8
    local tw = floor((width - (per - 1) * gap) / per)
    local th = 56
    local picked = {}
    for _, rk in ipairs(s.ra) do picked[rk] = true end
    for i, r in ipairs(R():GetActivities("raid")) do
        local t = sh.raidTiles[i] or NewArtTile(sh)
        sh.raidTiles[i] = t
        t:SetSize(tw, th)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD + ((i - 1) % per) * (tw + gap), y - floor((i - 1) / per) * (th + gap))
        local info = RaidInfo(r.key)
        local why, attune = RaidState(r.key)
        local sub = r.size .. " player" .. ((why == "saved" and " · saved") or (why == "phase" and (" · phase "
            .. (info and info.phase or "?"))) or (attune and " · attune") or "")
        local needers = R():GetRaidNeeders(r.key)
        FillArtTile(t, { k = "raid", a = { r.key } }, info and info.name or r.key, sub, picked[r.key], why ~= nil,
            (why or attune) and "lock" or needers)
        t.tip = RaidTileTip(r.key, r.size)
        local key, size, off = r.key, r.size, why ~= nil
        t:SetScript("OnClick", function() if not off then ToggleRaid(key, size) end end)
        t:Show()
    end
    local rows = math.ceil(#R():GetActivities("raid") / per)
    return y - rows * (th + gap) - 4
end

local function LayoutRaid(s, y)
    for i = #s.ra, 1, -1 do
        if RaidState(s.ra[i]) then tremove(s.ra, i) end
    end
    y = LayoutRaidTiles(s, y)
    y = Place(sh.whenRow, y)
    FillWhen(s)
    y = Place(sh.placesRow, y)
    FillPlaces(s)
    y = Place(sh.bossRow, y)
    sh.bossMode:Select(s.bo and "pick" or "all")
    sh.bossPick:SetShown(s.bo ~= nil and #s.ra > 0)
    if sh.bossPick.Refresh then sh.bossPick:Refresh() end
    y = Place(sh.lootRow, y)
    sh.loot:Select(s.lo or "roll")
    sh.reserves:SetShown(s.lo == "sr")
    sh.reservesText:SetShown(s.lo == "sr")
    local lr = s.lr or 1
    sh.reserves:Set(tostring(lr), lr > 1, lr < 3)
    y = Place(sh.noteRow, y)
    sh.note:ClearAllPoints()
    sh.note:SetPoint("LEFT", sh.noteRow, "LEFT", LBL, 0)
    sh.note:SetWidth(Width() - 2 * PAD - LBL)
    y = Place(sh.roleRow, y)
    FillRoles(s)
    return y
end

---------------------------------------------------------------------------
-- Quests
---------------------------------------------------------------------------

local RAIL_W = 220
local QROW_H = 46

-- The quests a view shows: { { zone, quests = { records } } } by zone.
local function QuestView(s)
    local GQ = ns.GroupQuests
    if not GQ then return {} end
    local recs = {}
    local view = s.qview or "log"
    if view == "search" then
        recs = GQ:Search(s.qsearch or "", 60)
    elseif view == "log" then
        for _, k in ipairs(GQ:GetMine()) do recs[#recs + 1] = GQ:Get(k) end
    elseif view == "guild" then
        for k in pairs(R():GetGuildQuests()) do recs[#recs + 1] = GQ:Get(k) end
    elseif type(view) == "number" then
        recs = GQ:GetZoneQuests(view)
    end
    GQ:Sort(recs)
    local out, byZone = {}, {}
    for _, q in ipairs(recs) do
        local z = byZone[q.zone]
        if not z then
            z = { zone = GQ:GetZone(q.zone), quests = {} }
            byZone[q.zone] = z
            out[#out + 1] = z
        end
        z.quests[#z.quests + 1] = q
    end
    return out
end

local function QuestPicked(s, key)
    for i, k in ipairs(s.qs) do if k == key then return i end end
    return nil
end

local function ToggleQuest(q)
    local s = state.sheet
    local at = QuestPicked(s, q.key)
    if at then
        tremove(s.qs, at)
    else
        -- quests of one zone make one group: another zone starts the pick over
        local first = s.qs[1] and ns.GroupQuests:Get(s.qs[1])
        if first and first.zone ~= q.zone then s.qs = {} end
        if #s.qs < 6 then s.qs[#s.qs + 1] = q.key end
    end
    s.n, s.err = nil, nil
    Refresh()
end

local function RailItem(i)
    local q = sh.quest
    local it = q.railItems[i]
    if not it then
        it = CreateFrame("Button", nil, q.railBody)
        it:SetHeight(26)
        UI():DecorateRow(it, { hover = true, selectable = true })
        it.thumb = it:CreateTexture(nil, "ARTWORK")
        it.thumb:SetSize(30, 18)
        it.thumb:SetPoint("LEFT", 6, 0)
        it.name = UI():Text(it, "body", "TEXT")
        it.name:SetPoint("LEFT", it.thumb, "RIGHT", 8, 0)
        it.name:SetPoint("RIGHT", -28, 0)
        it.name:SetJustifyH("LEFT")
        it.count = UI():Text(it, "small", "SUB")
        it.count:SetPoint("RIGHT", -8, 0)
        it.caps = UI():Text(it, "caps", "SUB")
        it.caps:SetPoint("BOTTOMLEFT", 6, 4)
        q.railItems[i] = it
    end
    return it
end

local function LayoutRail(s, height)
    local q = sh.quest
    local GQ = ns.GroupQuests
    local y, i = 0, 0
    local function item(view, name, count, thumbRun, icon)
        i = i + 1
        local it = RailItem(i)
        it:ClearAllPoints()
        it:SetPoint("TOPLEFT", q.railBody, "TOPLEFT", 0, -y)
        it:SetPoint("RIGHT", q.railBody, "RIGHT", 0, 0)
        it:SetHeight(26)
        it.caps:Hide()
        it.thumb:Show()
        it.name:Show()
        it.count:Show()
        if icon then
            it.thumb:SetSize(18, 18)
            it.thumb:SetTexture(icon[1])
            it.thumb:SetTexCoord(icon[2], icon[3], icon[4], icon[5])
        else
            it.thumb:SetSize(30, 18)
            local file, l, r, t, b = R():GetGroupArt(thumbRun, 30, 18)
            it.thumb:SetTexture(file)
            if file then it.thumb:SetTexCoord(l, r, t, b) end
        end
        it.name:SetText(name)
        it.count:SetText(tostring(count))
        local sel = s.qview == view
        if it.SetSelected then it:SetSelected(sel) end
        it.name:SetTextColor(S:Color(sel and "GOLD" or "TEXT"))
        it:SetScript("OnClick", function()
            s.qview = view
            s.qsearch = nil
            q.search:SetText("")
            Refresh()
        end)
        it:Show()
        y = y + 28
    end
    local mine = GQ and GQ:GetMine() or {}
    local guild = 0
    for _ in pairs(R():GetGuildQuests()) do guild = guild + 1 end
    item("log", "In your quest log", #mine, nil, { R():GetGroupIcon({ k = "quest", a = {} }) })
    item("guild", "Guildies have them", guild, nil, { "Interface\\FriendsFrame\\UI-Toast-FriendOnlineIcon", 0, 1, 0, 1 })
    i = i + 1
    local head = RailItem(i)
    head:ClearAllPoints()
    head:SetPoint("TOPLEFT", q.railBody, "TOPLEFT", 0, -y)
    head:SetPoint("RIGHT", q.railBody, "RIGHT", 0, 0)
    head:SetHeight(24)
    head.thumb:Hide()
    head.name:Hide()
    head.count:Hide()
    head.caps:SetText("ZONES")
    head.caps:Show()
    if head.SetSelected then head:SetSelected(false) end
    head:SetScript("OnClick", nil)
    head:Show()
    y = y + 24
    for _, z in ipairs(GQ and GQ:GetZones() or {}) do
        local list = GQ:GetZoneQuests(z.index)
        if #list > 0 then
            item(z.index, z.name, #list, { k = "quest", a = { list[1].id } })
        end
    end
    for j = i + 1, #q.railItems do q.railItems[j]:Hide() end
    q.railBody:SetHeight(max(y, height))
end

-- One quest row: the check, the zone's art, the name, "In your log" + players / chain step; on the right the group
-- that already lists it (Join), else the guildies who have it.
local function QuestRow(i)
    local q = sh.quest
    local r = q.rows[i]
    if not r then
        r = CreateFrame("Button", nil, q.body)
        r:SetHeight(QROW_H - 4)
        r.bg = UI():Fill(r, "CARD", "BACKGROUND")
        UI():AddEdges(r, "BORDER")
        r.check = CreateFrame("Frame", nil, r)
        r.check:SetSize(16, 16)
        r.check:SetPoint("LEFT", 10, 0)
        UI():AddEdges(r.check, "BORDER")
        r.check.bg = UI():Fill(r.check, "DROP_BG", "BACKGROUND")
        r.check.mark = r.check:CreateTexture(nil, "OVERLAY")
        r.check.mark:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        r.check.mark:SetPoint("CENTER")
        r.check.mark:SetSize(20, 20)
        r.thumb = r:CreateTexture(nil, "ARTWORK")
        r.thumb:SetSize(56, 32)
        r.thumb:SetPoint("LEFT", r.check, "RIGHT", 10, 0)
        r.name = UI():Text(r, "emph", "TEXT")
        r.name:SetPoint("TOPLEFT", r.thumb, "TOPRIGHT", 10, 1)
        r.name:SetJustifyH("LEFT")
        r.pill = UI():CreatePill(r, "bis", "In your log")
        r.pill:SetPoint("BOTTOMLEFT", r.thumb, "BOTTOMRIGHT", 10, 0)
        r.line = UI():Text(r, "small", "SUB")
        r.right = UI():Text(r, "small", "SUB", { justify = "RIGHT" })
        r.right:SetPoint("RIGHT", -10, 0)
        r.join = UI():CreateSleekButton(r, "Join", 56, 22, nil, "secondary")
        r.join:SetPoint("RIGHT", -8, 0)
        r.faces = {}
        AddPickFrame(r)
        TipScripts(r)
        q.rows[i] = r
    end
    return r
end

local function FillQuestRow(r, qrec, s, width)
    local GQ = ns.GroupQuests
    r:SetWidth(width)
    local picked = QuestPicked(s, qrec.key) ~= nil
    local other = R():GetQuestGroup(qrec.key)
    local file, l, rr, t, b = R():GetGroupArt({ k = "quest", a = { qrec.id } }, 56, 32)
    r.thumb:SetTexture(file)
    if file then r.thumb:SetTexCoord(l, rr, t, b) end
    r.name:SetText(qrec.name)
    r.name:SetWidth(width - 300)
    local inLog = GQ:IsInMyLog(qrec.key)
    r.pill:SetShown(inLog)
    r.line:ClearAllPoints()
    if inLog then
        r.line:SetPoint("LEFT", r.pill, "RIGHT", 8, 0)
    else
        r.line:SetPoint("BOTTOMLEFT", r.thumb, "BOTTOMRIGHT", 10, 1)
    end
    r.line:SetText(qrec.players .. " players" .. ((qrec.step and qrec.steps) and (" · Part " .. qrec.step .. " of "
        .. qrec.steps) or ""))
    r.check.mark:SetShown(picked)
    r.check:SetShown(other == nil)
    r:SetPicked(picked)
    r.bg:SetAlpha(picked and 1 or 0.7)
    for _, f in ipairs(r.faces) do f:Hide() end
    if other then
        r.join:Show()
        r.join:SetText("Join")
        r.join:SetScript("OnClick", function()
            G().TryJoin(other, function(ok, why)
                if ok then return GS:Close() end
                s.err = why
                Refresh()
            end)
        end)
        local filled = 0
        for _, x in ipairs(R():GetSlots(other)) do if not x.empty then filled = filled + 1 end end
        r.right:ClearAllPoints()
        r.right:SetPoint("RIGHT", r.join, "LEFT", -10, 0)
        r.right:SetText(UI():ColoredName(other.o) .. S:Wrap("TEXT", "'s group") .. "\n" .. filled .. "/"
            .. R():GetSize(other) .. " · " .. G().WhenText(other))
        r.tip = function() return { qrec.name, ns.Util.ShortName(other.o) .. " already has a group for it: join it." } end
    else
        r.join:Hide()
        local who = R():GetQuestHolders(qrec.key)
        r.right:ClearAllPoints()
        r.right:SetPoint("RIGHT", -10, -7)
        if #who > 0 then
            local x = -10
            for j = 1, min(3, #who) do
                local f = r.faces[j] or UI():CreateAvatar(r, 22)
                r.faces[j] = f
                f:Set(who[j])
                f:ClearAllPoints()
                f:SetPoint("TOPRIGHT", r, "TOPRIGHT", x, -4)
                f:Show()
                x = x - 25
            end
            r.right:SetText(#who > 3 and ("+" .. (#who - 3) .. " have it") or "has it")
        else
            r.right:SetText(inLog and "nobody else yet" or "")
        end
        r.tip = function()
            local lines = { qrec.name, (GQ:GetZone(qrec.zone) or {}).name or "" }
            if #who > 0 then
                local names = {}
                for _, k in ipairs(who) do names[#names + 1] = UI():ColoredName(k) end
                lines[#lines + 1] = "In their log: " .. tconcat(names, ", ")
            end
            return lines
        end
    end
    r:SetScript("OnClick", function() if not other then ToggleQuest(qrec) end end)
    r:Show()
end

local function LayoutQuestList(s, width, height)
    local q = sh.quest
    local view = QuestView(s)
    local y, ri, hi = 0, 0, 0
    for _, z in ipairs(view) do
        hi = hi + 1
        local h = q.heads[hi] or UI():Text(q.body, "caps", "GOLD")
        q.heads[hi] = h
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", q.body, "TOPLEFT", 2, -y - 4)
        h:SetText((z.zone and z.zone.name or ""):upper())
        h:Show()
        y = y + 22
        for _, qrec in ipairs(z.quests) do
            ri = ri + 1
            local r = QuestRow(ri)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", q.body, "TOPLEFT", 0, -y)
            FillQuestRow(r, qrec, s, width - 14)
            y = y + QROW_H
        end
    end
    for j = ri + 1, #q.rows do q.rows[j]:Hide() end
    for j = hi + 1, #q.heads do q.heads[j]:Hide() end
    q.body:SetSize(width - 14, max(y, 10))
    q.empty = q.empty or UI():Text(q.body, "body", "SUB", { wrap = true })
    q.empty:ClearAllPoints()
    q.empty:SetPoint("TOPLEFT", 4, -8)
    q.empty:SetWidth(width - 30)
    q.empty:SetShown(ri == 0)
    q.empty:SetText((s.qview == "log" and "No group quests in your quest log. Pick a zone on the left, or search.")
        or (s.qview == "guild" and "No guildie online has a group quest in their log right now.")
        or (s.qview == "search" and "No group quest by that name.") or "Nothing here.")
end

local function LayoutQuest(s, y, bottom)
    local q = sh.quest
    local width = Width() - 2 * PAD
    local h = Height() + y - bottom - 2 * ROW - 8
    q:ClearAllPoints()
    q:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, y)
    q:SetSize(width, h)
    q:Show()
    q.rail:ClearAllPoints()
    q.rail:SetPoint("TOPLEFT", q, "TOPLEFT", 0, 0)
    q.rail:SetSize(RAIL_W, h)
    q.railBody:SetWidth(RAIL_W - 12)
    LayoutRail(s, h)
    local lx = RAIL_W + 16
    q.search:ClearAllPoints()
    q.search:SetPoint("TOPLEFT", q, "TOPLEFT", lx, 0)
    q.caption:ClearAllPoints()
    q.caption:SetPoint("LEFT", q.search, "RIGHT", 14, 0)
    local GQ = ns.GroupQuests
    local captions = { log = "Group quests in your log, any zone", guild = "Group quests guildies online have",
                       search = "Every group quest" }
    local zone = type(s.qview) == "number" and GQ and GQ:GetZone(s.qview)
    q.caption:SetText(zone and ("Group quests in " .. zone.name) or captions[s.qview or "log"] or "")
    if q.search.Instructions then
        q.search.Instructions:SetText("Search " .. (GQ and GQ:Count() or 0) .. " group quests")
    end
    q.list:ClearAllPoints()
    q.list:SetPoint("TOPLEFT", q, "TOPLEFT", lx, -30)
    q.list:SetSize(width - lx, h - 30)
    LayoutQuestList(s, width - lx, h - 30)
    y = y - h - 6
    -- picked
    y = Place(sh.pickedRow, y)
    local x = LBL
    for _, c in ipairs(sh.pickedChips) do c:Hide() end
    for i, key in ipairs(s.qs) do
        local c = sh.pickedChips[i]
        if not c then
            c = UI():CreateChip(sh.pickedRow, { kind = "track", onClick = function(self)
                local st = state.sheet
                local at = QuestPicked(st, self.questKey)
                if at then tremove(st.qs, at) end
                Refresh()
            end })
            sh.pickedChips[i] = c
        end
        c.questKey = key
        c:Set((GQ:GetName(key) or tostring(key)) .. "  " .. S:Wrap("SUB", "x"), GOLD)
        c:SetSelected(true)
        c:ClearAllPoints()
        c:SetPoint("LEFT", sh.pickedRow, "LEFT", x, 0)
        c:Show()
        x = x + c:GetWidth() + 6
    end
    sh.pickedPill:ClearAllPoints()
    sh.pickedPill:SetPoint("LEFT", sh.pickedRow, "LEFT", x + 4, 0)
    sh.pickedPill:SetShown(#s.qs > 1)
    sh.pickedPill:SetPill("bis", #s.qs .. " quests, one group")
    sh.pickedRow.label:SetText(#s.qs > 0 and "Picked" or "")
    if #s.qs == 0 then
        sh.pickedPill:Show()
        sh.pickedPill:SetPill("mute", "Tick a quest above: several of one zone make one group")
    end
    -- places and when, one row
    y = Place(sh.placesRow, y)
    local right = FillPlaces(s)
    sh.whenRow:ClearAllPoints()
    sh.whenRow:SetPoint("LEFT", sh.placesRow, "LEFT", right + 20, 0)
    sh.whenRow:SetWidth(400)
    sh.whenRow:Show()
    sh.whenRow.label:SetText("When")
    FillWhen(s, (sh.whenRow.label:GetStringWidth() or 40) + 10)
    return y
end

---------------------------------------------------------------------------
-- PvP and Other
---------------------------------------------------------------------------

local function LayoutPvP(s, y)
    local width = Width() - 2 * PAD
    local gap = 10
    local tw = floor((width - 2 * gap) / 3)
    s.pm = s.pm or "arena"
    for i, m in ipairs(PVP_MODES) do
        local t = sh.pvpTiles[i]
        if not t then
            t = NewArtTile(sh)
            t.face = UI():CreateFace(t, 40)
            t.face:SetPoint("LEFT", 12, 0)
            t.name:ClearAllPoints()
            t.name:SetPoint("TOPLEFT", t.face, "TOPRIGHT", 12, -1)
            t.sub:ClearAllPoints()
            t.sub:SetPoint("TOPLEFT", t.name, "BOTTOMLEFT", 0, -4)
            sh.pvpTiles[i] = t
        end
        t:SetSize(tw, 64)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD + (i - 1) * (tw + gap), y)
        FillArtTile(t, { k = "pvp", a = { m.art } }, m.title, m.sub, s.pm == m.key, false)
        local file, l, r, tt, b = R():GetGroupIcon({ k = "pvp", a = { m.icon } })
        if file then t.face:SetPhoto(file) end
        if t.face.photo and l then t.face.photo:SetTexCoord(l, r, tt, b) end
        t.tip = nil
        local key = m.key
        t:SetScript("OnClick", function()
            if s.pm == key then return end
            s.pm, s.pa, s.pr, s.err = key, nil, nil, nil
            Refresh()
        end)
        t:Show()
    end
    y = y - 64 - 12
    -- the activities of the mode: brackets / battlegrounds / places
    local items = {}
    for _, p in ipairs(R():GetActivities("pvp")) do
        local mode = p.mode == "arena" and "arena" or (p.mode == "bg" and "bg" or "world")
        if mode == s.pm then
            items[#items + 1] = { key = p.key, label = "|T" .. p.icon .. ":16:16:0:0:64:64:5:59:5:59|t " ..
                (p.mode == "arena" and (p.bracket .. "v" .. p.bracket) or p.name) }
        end
    end
    local found = false
    for _, it in ipairs(items) do if it.key == s.pa then found = true end end
    if not found then s.pa = items[1] and items[1].key end
    if s.pm == "arena" and not s.paSet and items[2] then s.pa = items[2].key; s.paSet = true end
    y = Place(sh.bracketRow, y)
    sh.bracketRow.label:SetText(s.pm == "arena" and "Bracket" or (s.pm == "bg" and "Battleground" or "Where"))
    sh.bracket:SetItems(items)
    sh.bracket:Select(s.pa)
    local p = PvPEntry(s.pa)
    local arena = p and p.mode == "arena"
    sh.gamesLabel:SetShown(arena)
    sh.games:SetShown(arena)
    sh.fcSwitch:SetShown(p and p.mode == "bg")
    sh.fcText:SetShown(p and p.mode == "bg")
    sh.gamesLabel:ClearAllPoints()
    sh.gamesLabel:SetPoint("LEFT", sh.bracket, "RIGHT", 22, 0)
    sh.games:ClearAllPoints()
    sh.games:SetPoint("LEFT", sh.gamesLabel, "RIGHT", 10, 0)
    sh.games:Select(s.pr and "rated" or "skirmish")
    sh.fcSwitch:ClearAllPoints()
    sh.fcSwitch:SetPoint("LEFT", sh.bracket, "RIGHT", 22, 0)
    sh.fcSwitch:SetOn(s.fc and true or false)
    sh.fcText:ClearAllPoints()
    sh.fcText:SetPoint("LEFT", sh.fcSwitch, "RIGHT", 8, 0)
    -- rated: the team strip
    if arena and s.pr then
        local team = ns.GroupPvP and ns.GroupPvP:GetTeam(p.bracket)
        local t = sh.team
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, y)
        t:SetWidth(width)
        local file, l, r, tt, b = R():GetGroupIcon({ k = "pvp", a = { s.pa } })
        if file then t.face:SetPhoto(file) end
        if t.face.photo and l then t.face.photo:SetTexCoord(l, r, tt, b) end
        local br = p.bracket .. "v" .. p.bracket
        if team then
            s.mr = s.mr or floor(((team.personal or team.rating or 1500) - 100) / 50) * 50
            t.title:SetText(team.name .. S:Wrap("SUB", " · your " .. br .. " team · ") .. S:Wrap("GOLD", tostring(team.rating)))
            t.sub:SetText("Rated games are for team members only. Someone who joins gets a team invite from you first.")
            t.rating:Show()
            t.rating:Set(s.mr .. "+", s.mr > 0, s.mr < 3000)
        else
            t.title:SetText(S:Wrap("WARN", "You have no " .. br .. " team"))
            t.sub:SetText("Rated games need one. Make a team at an arena master, or list a skirmish.")
            t.rating:Hide()
        end
        t:Show()
        y = y - 46 - 10
    end
    y = Place(sh.placesRow, y)
    FillPlaces(s, true)
    y = Place(sh.roleRow, y)
    FillRoles(s, { healer = true, dps = true })
    -- the PvP groups already listed for this mode: Join
    local list = {}
    for _, run in ipairs(R():GetGroups("pvp")) do
        local q = PvPEntry(run.a and run.a[1])
        local mode = q and (q.mode == "arena" and "arena" or (q.mode == "bg" and "bg" or "world"))
        if mode == s.pm and run.o ~= Me() then list[#list + 1] = run end
    end
    for _, c in ipairs(sh.already) do c:Hide() end
    if #list > 0 then
        y = Place(sh.alreadyRow, y - 4)
        local x = LBL
        for i, run in ipairs(list) do
            if i > 3 then break end
            local c = sh.already[i]
            if not c then
                c = CreateFrame("Frame", nil, sh.alreadyRow)
                c:SetHeight(32)
                c.bg = UI():Fill(c, "CARD", "BACKGROUND")
                UI():AddEdges(c, "BORDER")
                c.face = UI():CreateFace(c, 24)
                c.face:SetPoint("LEFT", 5, 0)
                c.t1 = UI():Text(c, "body", "TEXT")
                c.t1:SetPoint("TOPLEFT", c.face, "TOPRIGHT", 8, 3)
                c.t2 = UI():Text(c, "small", "SUB")
                c.t2:SetPoint("TOPLEFT", c.t1, "BOTTOMLEFT", 0, -2)
                c.join = UI():CreateSleekButton(c, "Join", 50, 22, nil, "secondary")
                c.join:SetPoint("RIGHT", -6, 0)
                sh.already[i] = c
            end
            local file, l, r, tt, b = R():GetGroupIcon(run)
            if file then c.face:SetPhoto(file) end
            if c.face.photo and l then c.face.photo:SetTexCoord(l, r, tt, b) end
            c.t1:SetText(UI():ColoredName(run.o) .. S:Wrap("TEXT", "'s " .. R():GetName(run)))
            local filled = 0
            for _, x2 in ipairs(R():GetSlots(run)) do if not x2.empty then filled = filled + 1 end end
            local fits = R():FitsMe(run)
            c.t2:SetText(G().Kicker(run) .. " · " .. filled .. "/" .. R():GetSize(run)
                .. (fits and S:Wrap("GOLD", " · wants a " .. (fits == "dps" and "DPS" or fits)) or ""))
            c:SetWidth(max(c.t1:GetStringWidth() or 0, c.t2:GetStringWidth() or 0) + 100)
            c:ClearAllPoints()
            c:SetPoint("LEFT", sh.alreadyRow, "LEFT", x, 0)
            local id = run.id
            c.join:SetScript("OnClick", function()
                G().TryJoin(R():GetGroup(id) or run, function(ok, why)
                    if ok then return GS:Close() end
                    s.err = why
                    Refresh()
                end)
            end)
            c:Show()
            x = x + c:GetWidth() + 8
        end
        y = y - 6
    end
    return y
end

local function LayoutOther(s, y)
    local width = Width() - 2 * PAD
    local acts = R():GetActivities("other")
    local gap = 8
    local tw = floor((width - (#acts - 1) * gap) / max(#acts, 1))
    s.oa = s.oa or (acts[1] and acts[1].key)
    for i, a in ipairs(acts) do
        local t = sh.otherTiles[i]
        if not t then
            t = NewArtTile(sh)
            t.face = UI():CreateFace(t, 30)
            t.face:SetPoint("LEFT", 10, 0)
            t.name:ClearAllPoints()
            t.name:SetPoint("LEFT", t.face, "RIGHT", 10, 0)
            t.name:SetPoint("RIGHT", -6, 0)
            sh.otherTiles[i] = t
        end
        t:SetSize(tw, 50)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD + (i - 1) * (tw + gap), y)
        FillArtTile(t, { k = "other", a = { a.key } }, a.name, nil, s.oa == a.key, false)
        local file, l, r, tt, b = R():GetGroupIcon({ k = "other", a = { a.key } })
        if file then t.face:SetPhoto(file) end
        if t.face.photo and l then t.face.photo:SetTexCoord(l, r, tt, b) end
        local key = a.key
        t:SetScript("OnClick", function()
            s.oa, s.err = key, nil
            Refresh()
        end)
        t:Show()
    end
    y = y - 50 - 12
    y = Place(sh.noteRow, y)
    for _, a in ipairs(acts) do
        if a.key == s.oa and a.hint then UI():SetEditPlaceholder(sh.note, a.hint) end
    end
    sh.note:ClearAllPoints()
    sh.note:SetPoint("LEFT", sh.noteRow, "LEFT", LBL, 0)
    sh.note:SetWidth(width - LBL)
    y = Place(sh.sizeRow, y)
    local n = SheetSize(s)
    sh.size:Set(n .. " players", n > 2, n < 40)
    y = Place(sh.placesRow, y)
    FillPlaces(s)
    y = Place(sh.whenRow, y)
    FillWhen(s)
    y = Place(sh.roleRow, y)
    FillRoles(s)
    return y
end

---------------------------------------------------------------------------
-- Dungeons (the 1.4 sheet: complex rows, the form left, the preview right)
---------------------------------------------------------------------------

local function NewTile(parent)
    local t = CreateFrame("Button", nil, parent)
    t:SetSize(TILE_W, TILE_H)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    UI():AddEdges(t, "BORDER")
    t.name = UI():Text(t, "emph", "TEXT")
    t.name:SetPoint("LEFT", 10, 0)
    t.count = UI():Text(t, "emph", "GOLD")
    t.count:SetPoint("RIGHT", -9, 0)
    t.star = t:CreateTexture(nil, "OVERLAY")
    t.star:SetTexture(STAR_TEX)
    t.star:SetSize(11, 11)
    t.star:SetPoint("RIGHT", t.count, "LEFT", -2, 0)
    t.saved = UI():Text(t, "small", "SUB")
    t.saved:SetPoint("RIGHT", -8, 0)
    t.saved:SetText("Saved")
    t.lock = t:CreateTexture(nil, "OVERLAY")
    t.lock:SetTexture(UI().ICON_LOCK)
    t.lock:SetSize(12, 12)
    t.lock:SetPoint("RIGHT", t.saved, "LEFT", -2, 0)
    t.daily = UI():CreatePill(t, "bis", "DAILY")
    t.daily:SetPoint("TOPRIGHT", t, "TOPRIGHT", -8, 7)
    t.daily:SetFrameLevel(t:GetFrameLevel() + 2)
    TipScripts(t)
    return t
end

local DAILY_WORDS = {
    log = "Your daily quest for it is in your quest log.",
    today = "Today's daily: you haven't done it yet.",
    done = "Today's daily: done.",
}

local function TileTip(info, heroic)
    return function()
        local lines = { info.name .. (heroic and " (Heroic)" or "") }
        local block, kind = R():GetBlocker(info.key, heroic)
        if kind == "saved" then
            lines[#lines + 1] = S:Wrap("WARN", block) .. S:Wrap("SUB", " (the daily reset)")
        elseif block then
            lines[#lines + 1] = S:Wrap("WARN", block)
        end
        local daily = R():GetMyDaily(info.key, heroic)
        if daily then
            lines[#lines + 1] = (daily == "done" and S:Wrap("SUB", DAILY_WORDS.done))
                or (DAILY_ICON .. " " .. S:Wrap("GOLD", DAILY_WORDS[daily]))
        end
        local n, who = R():GetNeeders(info.key, heroic)
        if n > 0 then
            local names = {}
            for i, k in ipairs(who) do
                if i > 8 then names[#names + 1] = "+" .. (#who - 8) break end
                names[#names + 1] = UI():ColoredName(k)
            end
            lines[#lines + 1] = "|T" .. STAR_TEX .. ":11:11:0:0|t " .. n .. (n == 1 and " guildie online has"
                or " guildies online have") .. " BiS here: " .. tconcat(names, ", ")
        end
        local drops = R():GetMyBiSDrops(info.key, heroic)
        if #drops > 0 then
            lines[#lines + 1] = S:Wrap("GOLD", "Drops your BiS:")
            for i, id in ipairs(drops) do
                if i > 6 then lines[#lines + 1] = S:Wrap("SUB", "+" .. (#drops - 6) .. " more") break end
                lines[#lines + 1] = "  " .. G().ItemLinkText(id)
            end
        end
        if #lines == 1 and info.short == info.name then return nil end
        return lines
    end
end

local function NewComplexRow(parent)
    local r = UI():CreateArtRow(parent, { rule = false })
    UI():AttachTooltip(r, nil, function(self) return self.whyTip end, { anchor = "ANCHOR_TOP" })
    r.tiles = {}
    return r
end

local function DungeonRows(s, width)
    local y = -HEAD_H - 8
    local rowW = width - 2 * PAD
    local tilesW = 4 * (TILE_W + TILE_GAP)
    local ri = 0
    for _, c in ipairs(R():GetComplexes()) do
        ri = ri + 1
        local r = sh.rows[ri] or NewComplexRow(sh)
        sh.rows[ri] = r
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, y)
        r:SetWidth(rowW)
        local whyAll, whyTip
        if s.h then
            local text, kind = R():GetBlocker(c.dungeons[1].key, true)
            if kind == "rep" or kind == "level" then
                whyAll = kind == "rep" and "Needs Revered" or text
                whyTip = { { c.name, S:Color("GOLD") }, text .. (kind == "rep" and " for the heroic key." or ".") }
            end
        end
        local first = c.dungeons[1] and c.dungeons[1].key
        r:SetData({ art = function(tex, w, h)
                local file, l, rr, t, b = R():GetArt(first, w, h)
                tex:SetTexture(file)
                if file then tex:SetTexCoord(l, rr, t, b) end
            end, icon = c.icon, title = c.name, sub = whyAll and S:Wrap("WARN", whyAll) or nil })
        r.title:SetTextColor(S:Color("GOLD"))
        r.whyTip = whyTip
        r:SetRightWidth(tilesW)
        for i, info in ipairs(c.dungeons) do
            local tile = r.tiles[i] or NewTile(r.right)
            r.tiles[i] = tile
            tile:ClearAllPoints()
            tile:SetPoint("LEFT", r.right, "RIGHT", -tilesW + (i - 1) * (TILE_W + TILE_GAP), 0)
            tile.name:SetText(info.short)
            local block, kind = R():GetBlocker(info.key, s.h)
            local daily = R():GetMyDaily(info.key, s.h)
            local n = R():GetNeeders(info.key, s.h)
            local sel = s.d == info.key
            local off = block ~= nil
            UI():PaintSleek(tile, sel and not off and "primary" or "secondary", false, off and 0.3 or nil)
            tile.bg:SetAlpha(off and 0.6 or 1)
            tile.name:SetTextColor(S:Color(off and "DIM" or "TEXT"))
            local saved = kind == "saved"
            tile.saved:SetShown(saved)
            tile.lock:SetShown(saved)
            local showCount = n > 0 and not off
            tile.count:SetShown(showCount)
            tile.star:SetShown(showCount)
            tile.count:SetText(n)
            tile.daily:SetShown((daily == "log" or daily == "today") and not off)
            tile.tip = TileTip(info, s.h)
            local dkey = info.key
            tile:SetScript("OnClick", function()
                if off then return end
                s.d, s.err = dkey, nil
                Refresh()
            end)
            tile:Show()
        end
        for i = #c.dungeons + 1, #r.tiles do r.tiles[i]:Hide() end
        r:Show()
        y = y - ROW_H - ROW_GAP
    end
    for i = ri + 1, #sh.rows do sh.rows[i]:Hide() end
    return y
end

local function LayoutDungeon(s, width)
    sh.mode:ClearAllPoints()
    sh.mode:SetPoint("RIGHT", sh.close, "LEFT", -14, 0)
    sh.mode:Select(s.h and "heroic" or "normal")
    sh.mode:Show()
    local y = DungeonRows(s, width)
    if s.d and R():GetBlocker(s.d, s.h) then s.d = nil end
    y = y - 8
    -- the form: When (+ At on its own line), Note, You go as, Pugs
    local fw = FORM_LABEL_W + FORM_W
    local function frow(row, yy)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, yy)
        row:SetWidth(fw)
        row.label:SetWidth(FORM_LABEL_W)
        row:Show()
        return yy - ROW
    end
    local later = s.when == "later"
    local yy = frow(sh.whenRow, y)
    FillWhen(s, FORM_LABEL_W)
    if later then
        -- (At on a line of its own: the form is narrow)
        sh.day:ClearAllPoints()
        sh.day:SetPoint("TOPLEFT", sh.whenRow, "BOTTOMLEFT", FORM_LABEL_W, -7)
        yy = yy - ROW
    end
    yy = frow(sh.noteRow, yy)
    sh.note:ClearAllPoints()
    sh.note:SetPoint("LEFT", sh.noteRow, "LEFT", FORM_LABEL_W, 0)
    sh.note:SetWidth(FORM_W)
    yy = frow(sh.roleRow, yy)
    FillRoles(s)
    sh.roles:ClearAllPoints()
    sh.roles:SetPoint("LEFT", sh.roleRow, "LEFT", FORM_LABEL_W, 0)
    sh.form:ClearAllPoints()
    sh.form:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, yy)
    sh.form:Show()
    sh.gfRow:ClearAllPoints()
    sh.gfRow:SetPoint("TOPLEFT", sh.form, "TOPLEFT", 0, 0)
    local later2 = later
    local GF = ns.GroupFinder
    sh.gfRow:SetShown(GF ~= nil and GF:IsAvailable())
    sh.gf:SetOn(s.gf)
    sh.gfText.text:SetText(later2 and "List it in the Group Finder when it starts" or "Also list it in the Group Finder")
    sh.gfText.text:SetTextColor(S:Color(s.gf and "TEXT" or "SUB"))
    sh.gfText:SetSize((sh.gfText.text:GetStringWidth() or 200) + 2, 20)
    -- the preview on the right
    local px = PAD + fw + 24
    local pw = width - PAD - px
    sh.previewRule:Hide()
    sh.previewLabel:ClearAllPoints()
    sh.previewLabel:SetPoint("TOPLEFT", sh, "TOPLEFT", px, y + 2)
    sh.previewLabel:SetWidth(pw)
    sh.preview:ClearAllPoints()
    sh.preview:SetPoint("TOPLEFT", sh, "TOPLEFT", px, y - 18)
    sh.pick:ClearAllPoints()
    sh.pick:SetPoint("TOPLEFT", sh, "TOPLEFT", px, y - 44)
    sh.go:ClearAllPoints()
    sh.go:SetPoint("TOPRIGHT", sh, "TOPRIGHT", -PAD, y - 18 - CARD_H - 8)
    sh.foot:ClearAllPoints()
    sh.foot:SetPoint("TOPLEFT", sh, "TOPLEFT", px, y - 18 - CARD_H - 44)
    sh.foot:SetWidth(pw)
    return pw
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

-- The line under the preview: who gets a ping; what listing replaces.
local function FootText(s, run)
    local kind = s.kind
    local parts = {}
    local mine = R():GetMyGroup()
    if mine and not s.edit then
        parts[#parts + 1] = "One group at a time: listing this replaces your " .. R():GetName(mine) .. " group."
    end
    if kind == "raid" then
        parts[#parts + 1] = "Guildies who are " .. S:Wrap("TEXT", "up for raids") .. " as a role you still need get a ping."
    elseif kind == "quest" then
        local names = {}
        for _, k in ipairs(s.qs) do
            for _, who in ipairs(R():GetQuestHolders(k)) do
                local n = ns.Util.ShortName(who)
                local dup = false
                for _, x in ipairs(names) do if x == n then dup = true end end
                if #names < 4 and not dup then names[#names + 1] = n end
            end
        end
        parts[#parts + 1] = "Pings go to guildies who have these quests in their log" .. (#names > 0 and (" ("
            .. tconcat(names, ", ") .. ")") or "") .. " and anyone " .. S:Wrap("TEXT", "up for quests") .. "."
    elseif kind == "pvp" then
        local p = PvPEntry(s.pa)
        if p and p.mode == "arena" and s.pr then
            local br = p.bracket .. "v" .. p.bracket
            parts[#parts + 1] = "Pings go to guildies up for PvP whose " .. br .. " rating is " .. (s.mr or 0)
                .. " or more, and who aren't on another " .. br .. " team."
        else
            parts[#parts + 1] = "Pings go to guildies " .. S:Wrap("TEXT", "up for PvP") .. " as a role you still need."
        end
    elseif kind == "other" then
        parts[#parts + 1] = "Say what it's for in the note. Guildies up for a group as a role you need get a ping."
    else
        parts[#parts + 1] = "Guildies who are " .. S:Wrap("TEXT", "up for a run") .. " as a role you still need get a ping."
    end
    return tconcat(parts, " ")
end

function GS:RefreshPreview()
    local s = state.sheet
    if not sh or not s then return end
    local run = PreviewRun(s)
    sh.preview:SetShown(run ~= nil)
    sh.pick:SetShown(run == nil)
    local words = { dungeon = "Pick a dungeon above.", raid = "Pick a raid above.", quest = "Tick a quest above.",
                    pvp = "Pick what you play above.", other = "Pick what the group is for above." }
    sh.pick:SetText(words[s.kind] or "")
    sh.foot:SetText(FootText(s, run))
    if not run then return end
    G().FillCard(sh.preview, run, { width = sh.previewW or 390, compact = true })
end

function GS:Refresh()
    local s = state.sheet
    if not sh or not s then return end
    s.ra, s.qs = s.ra or {}, s.qs or {}
    local width, height = Width(), Height()
    -- the head: the title, the kinds (only my group's own while editing)
    sh.title:SetText(s.edit and "Edit your group" or "List a group")
    local x = PAD + (sh.title:GetStringWidth() or 100) + 26
    for _, b in ipairs(sh.tabs) do
        b:ClearAllPoints()
        b:SetPoint("LEFT", sh, "TOPLEFT", x, -21)
        b:SetActive(s.kind == b.key)
        b:SetShown(not s.edit or s.kind == b.key)
        if b:IsShown() then x = x + b:GetWidth() + 10 end
    end
    HideKindParts()
    UI():SetEditPlaceholder(sh.note, s.kind == "raid" and "Optional, e.g. \"Pug fill, no BoE drama\""
        or "Optional, e.g. \"badge run, fast pulls\"")
    -- the pick's art in the band
    local band = PreviewRun(s) or ({ dungeon = nil, raid = { k = "raid", a = { "Karazhan" } },
        quest = { k = "quest", a = {} }, pvp = { k = "pvp", a = { "arena3" } }, other = { k = "other", a = { "any" } } })[s.kind]
    local file, l, r, t, b
    if band then file, l, r, t, b = R():GetGroupArt(band, width, BAND_H, 1) end
    sh.band:SetTexture(file)
    if file then sh.band:SetTexCoord(l, r, t, b) end
    sh.band:SetShown(file ~= nil)
    sh.bandShade:SetShown(file ~= nil)

    if s.kind == "dungeon" then
        sh.previewW = LayoutDungeon(s, width)
    else
        -- top down: the picker and rows, then the preview with its button, and the line on pings
        local bottomH = 18 + CARD_H + 26 + 34
        local y = -HEAD_H - 10
        if s.kind == "raid" then
            LayoutRaid(s, y)
        elseif s.kind == "quest" then
            LayoutQuest(s, y, bottomH)
        elseif s.kind == "pvp" then
            LayoutPvP(s, y)
        else
            LayoutOther(s, y)
        end
        local cardY = -(height - bottomH) - 18
        sh.previewW = width - 2 * PAD - GO_W - 20
        sh.previewRule:ClearAllPoints()
        sh.previewRule:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, cardY + 26)
        sh.previewRule:SetPoint("TOPRIGHT", sh, "TOPRIGHT", -PAD, cardY + 26)
        sh.previewRule:Show()
        sh.previewLabel:ClearAllPoints()
        sh.previewLabel:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, cardY + 18)
        sh.previewLabel:SetWidth(sh.previewW)
        sh.preview:ClearAllPoints()
        sh.preview:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, cardY)
        sh.pick:ClearAllPoints()
        sh.pick:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, cardY - 26)
        sh.go:ClearAllPoints()
        sh.go:SetPoint("TOPRIGHT", sh, "TOPRIGHT", -PAD, cardY - (CARD_H - S.BTN_H - 6) / 2)
        sh.foot:ClearAllPoints()
        sh.foot:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, cardY - CARD_H - 8)
        sh.foot:SetWidth(width - 2 * PAD)
    end
    sh.go:SetText(s.edit and "Save" or "List group")
    sh.go:SetEnabled(Opts(s) ~= nil and not (s.kind == "pvp" and s.pr and not (ns.GroupPvP and ns.GroupPvP:GetTeam(
        (PvPEntry(s.pa) or {}).bracket))))
    sh.err:ClearAllPoints()
    sh.err:SetPoint("BOTTOMRIGHT", sh.go, "TOPRIGHT", 0, 6)
    sh.err:SetText(s.err or "")
    sh.err:SetShown(s.err ~= nil)
    self:RefreshPreview()
end

---------------------------------------------------------------------------
-- Open, close, submit
---------------------------------------------------------------------------

function GS:Get() return sh end

function GS:Open(panel, edit)
    local mine = R():GetMyGroup()
    local level = UnitLevel and tonumber(UnitLevel("player")) or 70
    local tab = state.tab
    local s = { h = level >= 70, when = "now", role = R():GetGoAs(), edit = edit and mine ~= nil or nil,
                kind = (tab == "raid" or tab == "quest" or tab == "pvp") and tab or "dungeon", ra = {}, qs = {},
                qview = "log" }
    if s.edit then
        s.kind = R():GetKind(mine)
        s.no = mine.no
        if (mine.at or 0) > ns.Util.Now() then
            local t, n = date("*t", mine.at), date("*t", ns.Util.Now())
            s.when = "later"
            s.day = floor((time({ year = t.year, month = t.month, day = t.day, hour = 12 })
                - time({ year = n.year, month = n.month, day = n.day, hour = 12 })) / 86400 + 0.5)
            s.mins = t.hour * 60 + t.min - t.min % 15
        end
        if s.kind == "dungeon" then
            s.d, s.h, s.gf = mine.d, mine.h and true or false, mine.gf
        else
            local w = R():GetWant(mine)
            s.w, s.wn = { tank = w.tank, healer = w.healer, dps = w.dps }, R():GetSize(mine)
            if s.kind == "raid" then
                for i, rk in ipairs(mine.a or {}) do s.ra[i] = rk end
                s.lo, s.lr = mine.lo, mine.lr
                if mine.bo then
                    s.bo = {}
                    for _, b in ipairs(mine.bo) do s.bo[b] = true end
                end
            elseif s.kind == "quest" then
                for i, k in ipairs(mine.a or {}) do s.qs[i] = k end
                s.n = R():GetSize(mine)
            elseif s.kind == "pvp" then
                s.pa, s.paSet, s.pr, s.mr, s.fc = mine.a[1], true, mine.pr, mine.mr, mine.fc
                local p = PvPEntry(s.pa)
                s.pm = p and (p.mode == "arena" and "arena" or (p.mode == "bg" and "bg" or "world")) or "arena"
            else
                s.oa, s.n = mine.a[1], R():GetSize(mine)
            end
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
    if not sh then CreateSheet(panel) end
    sh.note:SetText(s.no or "")
    sh.quest.search:SetText("")
    sh:Open()
    -- (the sheet covers the page: the toolbar and the tabs under it go, so nothing under the cover takes a click)
    panel.layout.toolbar:Hide()
    if panel.tabsRow then panel.tabsRow:Hide() end
    self:Refresh()
end

function GS:Close()
    state.sheet = nil
    local panel = DUI():GetPanel()
    if sh then
        sh.note:ClearFocus()
        sh.quest.search:ClearFocus()
        sh:Close()
        if panel then
            panel.layout.toolbar:Show()
            if panel.tabsRow then panel.tabsRow:Show() end
        end
    end
    DUI():Refresh()
end

function GS:Submit()
    local s = state.sheet
    if not s then return end
    local o = Opts(s)
    if not o then return end
    if s.kind ~= "dungeon" then
        if s.kind == "other" and o.a[1] == "any" and not (s.no and ns.Util.Trim(s.no) ~= "") then
            s.err = "Say what the group is for in the note."
            Refresh()
            return
        end
        local run, why = R():List(o)
        if not run then
            s.err = why
            Refresh()
            return
        end
        self:Close()
        -- a group bigger than a party: straight to its page (the roster, the requests)
        if R():GetSize(run) > 5 and ns.GroupsLead then ns.GroupsLead:Open(run.id) end
        return
    end
    local GF = ns.GroupFinder
    local before = R():GetMine()
    local wasListed = GF and before and select(2, GF:GetListing(before)) or false
    local run, why = R():List(o)
    if not run then
        s.err = why
        Refresh()
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
    self:Close()
end
