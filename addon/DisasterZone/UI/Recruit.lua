if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Recruit.lua", ...) then return end -- DisasterZone: UI/Recruit.lua
-- Guild > Recruitment (1.6; the GM and officers): the people they talk to (Core/Recruit.lua). A list + detail page in
-- the guest book's layout.
--   Left:  the search box (it adds a name too), Talking / Joined / Not now with counts, the people in sections
--          (Unclaimed, Needs you, Talking; Check-in due, Milestones, Gone quiet, Settling in), art rows with the class,
--          one line (spec, nights, the team they fit) and a pill (a date, "New", "Today", a milestone).
--   Right: the person. The page banner (who talks with them / who introduced or invited them, Online, spec · level ·
--          zone · tags, Whisper and ···, the step's actions), the follow-up as a notice strip, what they're looking
--          for (wants, plays, the nights they can raid on the Teams week strip, their words; click to change), the
--          story (notes, introductions, raids with us from the guest book, milestones; + Note), and on the right the
--          fit with every team (Core/Recruit.lua Fits), About, or for someone who joined: settling in and their team.
-- Recruitment never shows outsiders anything: whispers, group invites and guild invites are the game's own.
local addonName, ns = ...

local RU = ns:NewModule("RecruitUI")
local UI, S = ns.UI, ns.Style

local floor, max, min = math.floor, math.max, math.min
local tconcat, tsort = table.concat, table.sort

local DAY = 86400
local LIST_W = 250
local GAP = S.GAP
local DETAIL_W = S.INNER_W - LIST_W - GAP
local LEFT_W = 330
local SIDE_W = DETAIL_W - LEFT_W - GAP
local CLASS_TILE = "Interface\\Icons\\INV_Misc_QuestionMark"
local CELL, CELL_H = 15, 16
local STORY_MAX = 9                 -- story entries shown (the newest)

local H = {}
local state = { filter = "talk", search = "", view = "people" }
local view

local function R() return ns.Recruit end
local function Short(key) return ns.Util.ShortName(key) or tostring(key) end
local function Name(key, c) return UI:ColoredName(key, c or UI:ClassOf(key)) end
local function Me() return ns.Util.PlayerKey() end

H.SECTIONS = {
    talk = { { "unclaimed", "UNCLAIMED" }, { "need", "NEEDS YOU" }, { "talk", "TALKING" } },
    joined = { { "check", "CHECK-IN DUE" }, { "mile", "MILESTONES" }, { "quiet", "GONE QUIET" }, { "settle", "SETTLING IN" },
               { "gone", "LEFT THE GUILD" } },
    notnow = { { "notnow", "NOT NOW" } },
}
H.FILTER_OF = { unclaimed = "talk", need = "talk", talk = "talk", check = "joined", mile = "joined", quiet = "joined",
                settle = "joined", gone = "joined", notnow = "notnow" }
H.WANTS = { { "raid", "Raiding" }, { "dungeons", "Dungeons" }, { "level", "Levelling" }, { "social", "Social" } }

function H.SpecText(r)
    local spec = r.c and r.sp and ns.SPECS[r.c] and ns.SPECS[r.c][r.sp]
    local cls = r.c and ns.ClassName(r.c) or "Class unknown"
    return spec and (spec.label .. " " .. cls) or cls
end

function H.Him(r) return (r and r.she) and "her" or "them" end

function H.Day(at)
    if not at then return "" end
    local today = date("%Y%m%d", ns.Util.Now())
    local d = date("%Y%m%d", at)
    if d == today then return "Today" end
    if d == date("%Y%m%d", ns.Util.Now() + DAY) then return "Tomorrow" end
    if at > ns.Util.Now() and at < ns.Util.Now() + 6 * DAY then return date("%a", at) end
    return date("%a %d %b", at)
end

function H.NightsText(list)
    local out = {}
    for _, d in ipairs(list or {}) do out[#out + 1] = ns.RaidNights.SHORT[d] end
    return tconcat(out, " ")
end

-- The live state the friends list gives (Core/Recruit.lua Live, step 3): { online, lv, zone } or {}.
function H.Live(key)
    local Rc = R()
    return (Rc.Live and Rc:Live(key)) or {}
end

-- A person's picture: the raid they last came to with us (the guest book), else Serpentshrine for a raider,
-- Karazhan for everyone else.
function H.ArtInst(key, r)
    local GB = ns.GuestBook
    local e = GB and GB.GetEntry and GB:GetEntry(key)
    for _, z in ipairs(e and e.zones or {}) do if not z.noShow and z.inst then return z.inst end end
    return R():Wants(r, "raid") and "ssc" or "kara"
end

function H.Art(inst, grey)
    return function(tex, w, h)
        local file, l, r, t, b = ns.ItemDB:RaidArt(inst or "other", w, h, 0.5, true)
        tex:SetTexture(file)
        tex:SetTexCoord(l or 0, r or 1, t or 0, b or 1)
        tex:SetDesaturated(grey and true or false)
        tex:SetAlpha(grey and 0.6 or 1)
    end
end

function H.Whisper(key)
    local name = (Ambiguate and Ambiguate(key, "none")) or Short(key)
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if open then open("/w " .. name .. " ") end
end

function H.Try(ok, err)
    if not ok and err then ns:Print("%s", tostring(err)) end
    return ok
end

---------------------------------------------------------------------------
-- Small parts
---------------------------------------------------------------------------

local function has(list, v) for _, x in ipairs(list or {}) do if x == v then return true end end return false end

-- A week strip (the Teams raid nights' look): filled = core / picked, hollow gold = optional. onClick(day) makes the
-- cells buttons.
function H.WeekStrip(parent, scale, onClick)
    local f = CreateFrame("Frame", nil, parent)
    local w, h = floor(CELL * (scale or 1)), floor(CELL_H * (scale or 1))
    f:SetSize(7 * w + 6 * 2, h)
    f.cells = {}
    for i = 1, 7 do
        local c = CreateFrame(onClick and "Button" or "Frame", nil, f)
        c:SetSize(w, h)
        c:SetPoint("LEFT", (i - 1) * (w + 2), 0)
        c.bg = UI:Fill(c, { 0.08, 0.08, 0.09, 0.95 }, "BACKGROUND")
        c.t = UI:Text(c, "small", "DIM")
        c.t:SetPoint("CENTER", 0, 0)
        c.t:SetText(ns.RaidNights.LETTERS[i])
        if onClick then
            c:SetScript("OnClick", function() onClick(i) end)
            UI:AttachTooltip(c, ns.RaidNights.DAYS[i], { "Click: can raid that night, or not." })
        end
        f.cells[i] = c
    end
    function f:Set(core, opt)
        for i, c in ipairs(self.cells) do
            local on, o = has(core, i), has(opt, i)
            if on then
                c.bg:SetColorTexture(S:Color("GOLD_DEEP"))
                UI:SetEdges(c, S:Color("GOLD_DEEP"))
                c.t:SetTextColor(0.1, 0.08, 0)
            elseif o then
                c.bg:SetColorTexture(0.17, 0.14, 0.05, 0.95)
                UI:SetEdges(c, S:Color("GOLD_DEEP"))
                c.t:SetTextColor(S:RGB("GOLD"))
            else
                c.bg:SetColorTexture(0.08, 0.08, 0.09, 0.95)
                UI:SetEdges(c, S:Color("EDGE"))
                c.t:SetTextColor(S:RGB("DIM"))
            end
        end
    end
    return f
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

function H.Matches(r, key)
    local q = state.search
    if q == "" then return true end
    q = q:lower()
    return Short(key):lower():find(q, 1, true) ~= nil or H.SpecText(r):lower():find(q, 1, true) ~= nil
end

function H.Rows()
    local Rc = R()
    local by, counts = {}, { talk = 0, joined = 0, notnow = 0 }
    for _, r in ipairs(Rc:GetPeople()) do
        local sec = Rc:Section(r)
        local f = H.FILTER_OF[sec]
        if f then
            counts[f] = counts[f] + 1
            -- (a search looks through every tab)
            if (f == state.filter or state.search ~= "") and H.Matches(r, r.key) then
                by[sec] = by[sec] or {}
                by[sec][#by[sec] + 1] = r
            end
        end
    end
    local out = {}
    local secs = H.SECTIONS[state.filter]
    if state.search ~= "" then
        secs = {}
        for _, f in ipairs({ "talk", "joined", "notnow" }) do
            for _, s in ipairs(H.SECTIONS[f]) do secs[#secs + 1] = s end
        end
    end
    for _, s in ipairs(secs) do
        local list = by[s[1]]
        if list then
            tsort(list, function(a, b)
                local fa, fb = a.fu and a.fu.at or 2 ^ 31, b.fu and b.fu.at or 2 ^ 31
                if fa ~= fb then return fa < fb end
                return a.key < b.key
            end)
            out[#out + 1] = { head = s[2] }
            for _, r in ipairs(list) do out[#out + 1] = { r = r, sec = s[1] } end
        end
    end
    -- a name nobody has: "Add <name>"
    local q = ns.Util.Trim(state.search or "")
    if q ~= "" and #out == 0 and not q:find("[%s%d%p]") then out[#out + 1] = { add = q } end
    return out, counts
end

function H.RowLine(r, sec)
    local Rc = R()
    if sec == "unclaimed" then return r.ib and ("Introduced by " .. Short(r.ib)) or "Nobody has talked to them yet" end
    if sec == "check" then return Rc:CheckInDue(r) == "w" and "1 week in the guild" or "1 month in the guild" end
    if sec == "mile" then
        local m = Rc:RecentMilestone(r)
        return (m == 70 and "Hit 70" or m == 58 and "Hit 58" or m == "d" and "First dungeon with us" or "First raid with us")
            .. (Rc:Wants(r, "raid") and " · wants to raid" or "")
    end
    if sec == "quiet" then return "Offline " .. (Rc:QuietDays(r) or 0) .. " days" end
    if sec == "settle" then return "Joined " .. date("%d %b", r.ja or 0) .. (r.jb and (" · " .. Short(r.jb)) or "") end
    if sec == "gone" then return "Left the guild · joined " .. date("%d %b", r.ja or r.rev) end
    if sec == "notnow" then return "Not now since " .. date("%d %b", r.nn or r.rev) end
    if r.ni then
        local _, best = Rc:Fits(r)
        return H.NightsText(r.ni) .. (best and (" · fits " .. best.team.name) or "")
    end
    local w = {}
    for _, x in ipairs(H.WANTS) do if Rc:Wants(r, x[1]) then w[#w + 1] = x[2] end end
    return #w > 0 and tconcat(w, " · ") or H.SpecText(r)
end

function H.RowPill(r, sec)
    if sec == "unclaimed" then
        local days = floor((ns.Util.Now() - (r.at or r.rev)) / DAY)
        return days >= 1 and { "changed", days == 1 and "1 day" or (days .. " days") } or { "rank", "New" }
    end
    if sec == "check" then return { "live", "Today" } end
    if sec == "mile" then
        local m = R():RecentMilestone(r)
        return { "rank", type(m) == "number" and tostring(m) or (m == "d" and "Dungeon" or "Raid") }
    end
    if sec == "quiet" then return { "changed", "Quiet" } end
    if r.fu then return { sec == "need" and "rank" or "draft", H.Day(r.fu.at) } end
end

local function initRow(row, d)
    row.d = d
    if not row.ar then
        row.head = UI:Text(row, "caps", "SUB")
        row.head:SetPoint("BOTTOMLEFT", 2, 6)
        row.ar = UI:CreateArtRow(row, { selectable = true, onClick = function(self, button)
            local data = self:GetParent().d
            if not data then return end
            if data.add then RU:AddByName(data.add) return end
            if not data.r then return end
            if button == "RightButton" then RU:OpenMore(self, data.r.key) return end
            RU:Select(data.r.key)
        end })
        row.ar:SetAllPoints(row)
        row.dot = UI:CreateDot(row.ar, 9, "OK")
        row.dot:SetPoint("CENTER", row.ar.icon, "BOTTOMRIGHT", -1, 2)
    end
    if d.head then
        row.ar:Hide()
        row.head:SetText(d.head)
        row.head:Show()
        return
    end
    row.head:Hide()
    row.ar:Show()
    if d.add then
        row.ar:SetData({ art = H.Art("other"), title = S:Wrap("GOLD", "Add " .. d.add), sub = "Not in Recruitment yet",
            selected = false })
        row.ar.icon:Set(UI.ICON_ATLAS)
        UI:SetGlyph(row.ar.icon.tex, "plus", "GOLD")
        local tex = row.ar.icon.tex
        local size = floor((row.ar.icon:GetWidth() or 20) * 0.7 + 0.5)
        tex:ClearAllPoints()
        tex:SetPoint("CENTER")
        tex:SetSize(size, size)
        row.dot:Hide()
        return
    end
    local r = d.r
    row.ar:SetData({ art = H.Art(H.ArtInst(r.key, r), d.sec == "notnow" or d.sec == "quiet" or d.sec == "gone"), title = Name(r.key, r.c),
        sub = H.RowLine(r, d.sec), pill = H.RowPill(r, d.sec), selected = state.sel == r.key })
    row.ar.icon:Set(CLASS_TILE)
    row.ar.icon.tex:ClearAllPoints()
    row.ar.icon.tex:SetAllPoints()
    if r.c then UI:ClassIcon(row.ar.icon.tex, r.c) else UI:SetGlyph(row.ar.icon.tex, 11, "SUB") end
    row.dot:SetShown(H.Live(r.key).online and true or false)
end

---------------------------------------------------------------------------
-- The person: cards
---------------------------------------------------------------------------

function H.CreateLooking(parent)
    local c = UI:CreateCard(parent, { tone = "inset", title = "WHAT THEY'RE LOOKING FOR", titleStyle = "caps", width = LEFT_W, height = 120 })
    local b = c.body
    local function label(text, y)
        local t = UI:Text(b, "small", "SUB")
        t:SetPoint("TOPLEFT", 0, y)
        t:SetText(text)
        return t
    end
    label("Wants", -3)
    c.chips = {}
    local x = 56
    for _, k in ipairs(H.WANTS) do
        local what = k[1]
        local ch = UI:CreateChip(b, { text = k[2], onClick = function() RU:ToggleWant(what) end })
        ch:SetPoint("TOPLEFT", x, 0)
        x = x + ch:GetWidth() + 4
        c.chips[what] = ch
    end
    label("Plays", -25)
    c.plays = UI:CreateTextLink(b, "", function(self) RU:OpenClassMenu(self) end, { style = "body", color = "TEXT" })
    c.plays:SetPoint("TOPLEFT", 56, -22)
    label("Can raid", -46)
    c.week = H.WeekStrip(b, 1, function(day) RU:ToggleNight(day) end)
    c.week:SetPoint("TOPLEFT", 56, -44)
    c.time = UI:CreateTextLink(b, "", function() RU:EditTime() end, { style = "small", color = "SUB" })
    c.time:SetPoint("LEFT", c.week, "RIGHT", 8, 0)
    c.said = CreateFrame("Button", nil, b)
    c.said:SetPoint("TOPLEFT", 0, -68)
    c.said:SetSize(LEFT_W - 2 * S.IN, 30)
    c.said.text = UI:Text(c.said, "body", { 0.96, 0.92, 0.80 }, { wrap = true, width = LEFT_W - 2 * S.IN })
    c.said.text:SetPoint("TOPLEFT")
    c.said:SetScript("OnClick", function() RU:EditSaid() end)
    UI:AttachTooltip(c.said, "Their words", { "What they told you they're looking for. Click to change it." })
    c.saidBy = UI:Text(b, "small", "DIM")
    c.saidBy:SetPoint("TOPLEFT", c.said.text, "BOTTOMLEFT", 0, -2)
    return c
end

function H.FillLooking(c, r)
    local Rc = R()
    for what, ch in pairs(c.chips) do ch:SetSelected(Rc:Wants(r, what)) end
    local spec = H.SpecText(r)
    c.plays:SetLabel(spec)
    if r.ni or Rc:Wants(r, "raid") then
        c.week:Show()
        c.week:Set(r.ni or {}, {})
        c.time:ClearAllPoints()
        c.time:SetPoint("LEFT", c.week, "RIGHT", 8, 0)
        c.time:SetLabel(r.nt or "add a time")
    else
        c.week:Show()
        c.week:Set({}, {})
        c.time:ClearAllPoints()
        c.time:SetPoint("LEFT", c.week, "RIGHT", 8, 0)
        c.time:SetLabel("not raiding yet")
    end
    c.said.text:SetText(r.sd and ("\"" .. r.sd .. "\"") or S:Wrap("DIM", "Their words: what they're looking for (click)"))
    c.saidBy:SetText(r.sd and ("in their words · noted by " .. Short(r.w or r.by or Me())) or "")
    local th = c.said.text:GetStringHeight()
    if not th or th < 14 then th = 14 end
    c.said:SetHeight(th)
    local h = 68 + th + (r.sd and 16 or 4) + 26
    c:SetHeight(h)
    return h
end

function H.CreateFits(parent)
    local c = UI:CreateCard(parent, { tone = "inset", title = "FITS A TEAM", titleStyle = "caps", width = SIDE_W, height = 160 })
    c.rows = {}
    c.none = UI:Text(c.body, "body", "SUB", { wrap = true, width = SIDE_W - 2 * S.IN })
    c.none:SetPoint("TOPLEFT", 0, 0)
    return c
end

function H.FitRow(c, i)
    local r = c.rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, c.body)
    r:SetSize(SIDE_W - 2 * S.IN, 44)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * 46)
    r.bar = UI:Fill(r, S.C.OK, "ARTWORK")
    r.bar:ClearAllPoints()
    r.bar:SetPoint("TOPLEFT", -S.IN + 1, 0)
    r.bar:SetPoint("BOTTOMLEFT", -S.IN + 1, 2)
    r.bar:SetWidth(2)
    r.name = UI:Text(r, "body", "TEXT")
    r.name:SetPoint("TOPLEFT", 0, -1)
    r.week = H.WeekStrip(r, 0.8)
    r.week:SetPoint("TOPLEFT", 0, -15)
    r.why = UI:Text(r, "small", "SUB")
    r.why:SetPoint("TOPLEFT", 0, -31)
    UI:Rule(r, { bottom = 0, alpha = 0.06 })
    c.rows[i] = r
    return r
end

function H.FillFits(c, r)
    local Rc = R()
    for _, row in ipairs(c.rows) do row:Hide() end
    if r.st == "joined" or r.st == "gone" then
        c:SetTitle("TEAM", "caps")
        local team = r.tm and R():GetTeam(r.tm)
        c.none:Show()
        c.none:SetText(team and (S:Wrap("TEXT", team.name) .. "\n" .. S:Wrap("SUB", ns.RaidNights:DaysText(team.nights) or ""))
            or S:Wrap("SUB", "Not on a team."))
        c:SetHeight(max(56, c.none:GetStringHeight() + 36))
        return
    end
    c:SetTitle("FITS A TEAM", "caps")
    local fits = Rc:Fits(r)
    if not r.ni or #fits == 0 then
        c.none:Show()
        local teams = #R():GetTeams()
        c.none:SetText(teams == 0 and "No teams yet (Raids > Teams)." or
            (Rc:Wants(r, "raid") and "Pick the nights they can raid." or "Not raiding yet."))
        c:SetHeight(max(56, c.none:GetStringHeight() + 36))
        return
    end
    c.none:Hide()
    for i, f in ipairs(fits) do
        local row = H.FitRow(c, i)
        row:Show()
        local col = f.ok and "OK" or (f.nightsOk or f.part) and "WARN" or "DIM"
        row.bar:SetColorTexture(S:Color(col))
        row.bar:SetShown(col ~= "DIM")
        row:SetAlpha(col == "DIM" and 0.55 or 1)
        row.name:SetText(f.team.name)
        row.week:Set(Rc:TeamDays(f.team))
        local nights = not f.nights and "no raid nights set" or f.nightsOk and "their nights fit" or f.part and "some nights" or "other nights"
        row.why:SetText(S:Wrap(col == "DIM" and "SUB" or col, nights .. " · " .. (f.place and "place open" or "no open place")))
    end
    c:SetHeight(#fits * 46 + 26)
end

function H.CreateAbout(parent)
    local c = UI:CreateCard(parent, { tone = "inset", title = "ABOUT", titleStyle = "caps", width = SIDE_W, height = 76 })
    c.lines = {}
    for i = 1, 3 do
        local l = UI:Text(c.body, "small", "SUB")
        l:SetPoint("TOPLEFT", 0, -(i - 1) * 17)
        local r = UI:Text(c.body, "small", "TEXT", { justify = "RIGHT" })
        r:SetPoint("TOPRIGHT", 0, -(i - 1) * 17)
        c.lines[i] = { l, r }
    end
    return c
end

H.SRC = { whisper = "Whispers", guest = "Guest book", intro = "Introduced", name = "Added by name", trade = "Trade message" }

function H.FillAbout(c, r)
    local live = H.Live(r.key)
    local rows = {
        { "Now", live.online and S:Wrap("OK", "Online") or S:Wrap("SUB", r.la and ("Seen " .. date("%d %b", r.la)) or "Offline") },
        { "Level", tostring(live.lv or r.lv or "?") .. (r.jl and S:Wrap("DIM", "  " .. r.jl .. " when joined") or "") },
        { "Met", (H.SRC[r.src] or "") .. (r.at and (" · " .. date("%d %b", r.at)) or "") },
    }
    for i, x in ipairs(rows) do
        c.lines[i][1]:SetText(x[1])
        c.lines[i][2]:SetText(x[2])
    end
end

function H.CreateSettle(parent)
    local c = UI:CreateCard(parent, { tone = "inset", title = "SETTLING IN", titleStyle = "caps", width = LEFT_W, height = 70 })
    c.lv = UI:Text(c.body, "small", "SUB")
    c.lv:SetPoint("TOPLEFT", 0, -2)
    c.lv:SetText("Level")
    c.bar = UI:CreateProgressBar(c.body, { width = LEFT_W - 2 * S.IN - 90, height = 6, color = S.C.OK })
    c.bar:SetPoint("LEFT", c.lv, "RIGHT", 10, 0)
    c.lvt = UI:Text(c.body, "body", "TEXT")
    c.lvt:SetPoint("LEFT", c.bar, "RIGHT", 8, 0)
    c.facts = UI:Text(c.body, "small", "SUB")
    c.facts:SetPoint("TOPLEFT", 0, -20)
    return c
end

-- The story: notes, the introduction, raids with us (the guest book), milestones, joined, how we met; newest first.
function H.Story(r)
    local out = {}
    for _, n in ipairs(r.n or {}) do out[#out + 1] = { kind = "note", by = n.by, at = n.at, t = n.t } end
    if r.ib and r.it then out[#out + 1] = { kind = "intro", by = r.ib, at = r.at or r.rev, t = r.it } end
    local GB = ns.GuestBook
    local e = GB and GB.GetEntry and GB:GetEntry(r.key)
    for _, z in ipairs(e and e.zones or {}) do
        if z.at and z.inst then
            out[#out + 1] = { kind = "run", inst = z.inst, at = z.at, t = z.zone or "A raid",
                sub = z.noShow and "signed up, didn't come" or ("guest in our raid" .. (z.kills and z.kills > 0 and (" · " .. z.kills .. " kills") or "")) }
        end
    end
    local MS = { [58] = "Hit level 58 · off to Outland", [70] = "Hit level 70", d = "First dungeon with the guild", r = "First raid with the guild" }
    for k, at in pairs(r.ms or {}) do out[#out + 1] = { kind = "mile", at = at, t = MS[k] or "" } end
    if r.iv and r.iv.r ~= "sent" then
        local IV = { declined = "Declined the guild invite", ignored = "Didn't answer the guild invite",
                     guild = "Guild invite: still in another guild", offline = "Guild invite waits: they were offline" }
        out[#out + 1] = { kind = "met", at = r.iv.at, t = IV[r.iv.r] .. (r.iv.by and (" · " .. Short(r.iv.by)) or "") }
    end
    if r.ja then out[#out + 1] = { kind = "met", at = r.ja, t = "Joined the guild" .. (r.jb and (" · invited by " .. Short(r.jb)) or "") } end
    if r.at and not r.ib then out[#out + 1] = { kind = "met", at = r.at, t = "Added: " .. (H.SRC[r.src] or "by name"):lower() } end
    tsort(out, function(a, b) if a.at ~= b.at then return a.at > b.at end return a.kind < b.kind end)
    return out
end

function H.CreateStory(parent)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(LEFT_W, 300)
    s.head = UI:CreateSectionHeader(s, "Story", { style = "title", rule = true,
        action = { text = "+ Note", onClick = function() RU:WriteNote() end, tip = { "Write a note", "The GM and officers see it." } } })
    s.head:SetPoint("TOPLEFT", 0, 0)
    s.head:SetPoint("TOPRIGHT", 0, 0)
    s.line = UI:Fill(s, { 1, 1, 1, 0.1 }, "BACKGROUND")
    s.line:ClearAllPoints()
    s.line:SetWidth(1)
    s.items = {}
    s.empty = UI:Text(s, "body", "SUB", { wrap = true, width = LEFT_W })
    s.empty:SetPoint("TOPLEFT", 0, -30)
    return s
end

function H.StoryItem(s, i)
    local it = s.items[i]
    if it then return it end
    it = CreateFrame("Frame", nil, s)
    it:SetSize(LEFT_W, 36)
    it.face = it:CreateTexture(nil, "ARTWORK")
    it.face:SetSize(19, 19)
    it.face:SetPoint("TOPLEFT", 1, -1)
    it.art = it:CreateTexture(nil, "ARTWORK")
    it.art:SetSize(40, 22)
    it.art:SetPoint("TOPLEFT", 30, -2)
    it.dot = UI:CreateDot(it, 8, "SUB")
    it.dot:SetPoint("TOPLEFT", 6, -6)
    it.star = UI:CreateStar(it, 13)
    it.star:SetPoint("TOPLEFT", 4, -3)
    it.text = UI:Text(it, "body", "TEXT", { wrap = true, width = LEFT_W - 30 })
    it.sub = UI:Text(it, "small", "DIM")
    s.items[i] = it
    return it
end

function H.FillStory(s, r, maxH)
    local list = H.Story(r)
    local y = -30
    local shown = 0
    for i, e in ipairs(list) do
        if i > STORY_MAX or (maxH and -y > maxH - 30) then break end
        local it = H.StoryItem(s, i)
        it:ClearAllPoints()
        it:SetPoint("TOPLEFT", 0, y)
        it.face:Hide(); it.art:Hide(); it.dot:Hide(); it.star:Hide()
        it.text:ClearAllPoints()
        local x = 30
        if e.kind == "note" or e.kind == "intro" then
            it.face:Show()
            UI:ClassIcon(it.face, UI:ClassOf(e.by) or "PRIEST")
            if e.kind == "intro" then it.text:SetTextColor(0.96, 0.92, 0.80) else it.text:SetTextColor(S:RGB("TEXT")) end
            it.text:SetText(e.kind == "intro" and ("\"" .. e.t .. "\"") or e.t)
            it.sub:SetText(Name(e.by) .. S:Wrap("DIM", (e.kind == "intro" and " introduced them" or "") .. " · " .. date("%a %d %b", e.at)))
        elseif e.kind == "run" then
            it.art:Show()
            H.Art(e.inst)(it.art, 40, 22)
            it.dot:Show()
            x = 78
            it.text:SetTextColor(S:RGB("TEXT"))
            it.text:SetText(e.t)
            it.sub:SetText(S:Wrap("DIM", e.sub .. " · " .. date("%a %d %b", e.at)))
        elseif e.kind == "mile" then
            it.star:Show()
            it.star:SetLit(true)
            it.text:SetTextColor(0.96, 0.9, 0.69)
            it.text:SetText(e.t)
            it.sub:SetText(S:Wrap("DIM", date("%a %d %b", e.at)))
        else
            it.dot:Show()
            it.text:SetTextColor(S:RGB("SUB"))
            it.text:SetText(e.t)
            it.sub:SetText(S:Wrap("DIM", date("%a %d %b", e.at)))
        end
        it.text:SetWidth(LEFT_W - x)
        it.text:SetPoint("TOPLEFT", x, -1)
        it.sub:ClearAllPoints()
        it.sub:SetPoint("TOPLEFT", it.text, "BOTTOMLEFT", 0, -2)
        local h = max(26, (it.text:GetStringHeight() or 14) + 18)
        it:SetHeight(h)
        it:Show()
        y = y - h - 6
        shown = i
    end
    for i = shown + 1, #s.items do s.items[i]:Hide() end
    s.empty:SetShown(shown == 0)
    s.empty:SetText("Nothing yet. Write how the first chat went.")
    s.line:ClearAllPoints()
    s.line:SetPoint("TOPLEFT", 10, -36)
    s.line:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 10, y + 10)
    s.line:SetShown(shown > 1)
end

---------------------------------------------------------------------------
-- The person: banner + layout
---------------------------------------------------------------------------

function H.DecorateBanner(b)
    b.acts = {
        invite = { text = "Invite to the guild", kind = "primary", onClick = function() RU:Invite() end },
        notnow = { text = "Not now", onClick = function() RU:NotNow() end },
        reopen = { text = "Talk again", kind = "primary", onClick = function() if state.sel then H.Try(R():Reopen(state.sel)) end end },
        along = { text = "Bring along", menu = function(root) RU:BringAlongMenu(root) end },
        claim = { text = "I'll talk to them", kind = "primary", onClick = function() if state.sel then H.Try(R():Claim(state.sel)) end end },
        pass = { text = "Pass to", menu = function(root) RU:PassMenu(root) end },
        checked = { text = "Checked in", kind = "primary", onClick = function() RU:CheckedIn() end },
        later = { text = "Remind me later", onClick = function() RU:SetFollow(7, "check in") end },
    }
    b.whisperTool = { icon = "whisper", title = "Whisper", onClick = function() if state.sel then H.Whisper(state.sel) end end }
    b.moreTool = { icon = "more", title = "More", text = "Class, tags, follow-up, Not now, remove.",
        onClick = function(self) if state.sel then RU:OpenMore(self, state.sel) end end }
    return b
end

function H.Kicker(r)
    if r.st == "joined" then return "JOINED " .. date("%d %b", r.ja or r.rev):upper() .. (r.jb and (" · INVITED BY " .. Short(r.jb):upper()) or "") end
    if r.st == "gone" then return "LEFT THE GUILD · JOINED " .. date("%d %b", r.ja or r.rev):upper() end
    if r.st == "notnow" then return "NOT NOW · SINCE " .. date("%d %b", r.nn or r.rev):upper() end
    if not r.w then return (r.ib and ("INTRODUCED BY " .. Short(r.ib):upper()) or "NEW") .. " · " .. date("%d %b", r.at or r.rev):upper() end
    return "TALKING · " .. Short(r.w):upper() .. " · SINCE " .. date("%d %b", r.at or r.rev):upper()
end

function H.FillPerson()
    local Rc = R()
    local r = state.sel and Rc:Get(state.sel)
    local v = view
    v.detail:SetShown(r ~= nil)
    if not r then return end
    local live = H.Live(r.key)
    local b = v.banner
    b:SetArt(H.ArtInst(r.key, r), r.st == "notnow")
    b:SetIcon(CLASS_TILE)
    if r.c then UI:ClassIcon(b.icon.tex, r.c) else b:SetIcon(11, { glyph = "SUB" }) end
    b:SetKicker(H.Kicker(r))
    b:SetTitle(Name(r.key, r.c))
    if live.online then b:SetPill("ok", "Online") else b:SetPill(nil, nil) end
    local lv = live.lv or r.lv
    b:SetSub(H.SpecText(r) .. (lv and (" · level " .. lv) or "") .. (live.zone and (" · " .. live.zone) or "")
        .. (r.tg and S:Wrap("SUB", "  ·  " .. tconcat(r.tg, " · ")) or ""))
    b:SetTools({ b.moreTool, b.whisperTool })
    local A = b.acts
    local sec = Rc:Section(r)
    if sec == "unclaimed" then b:SetActions({ A.claim, A.pass })
    elseif r.st == "joined" then b:SetActions(Rc:CheckInDue(r) and { A.checked, A.later } or { A.later })
    elseif r.st == "notnow" then b:SetActions({ A.reopen })
    elseif r.st == "gone" then b:SetActions({})
    else b:SetActions({ A.invite, A.notnow, A.along }) end

    -- the follow-up (or the claim) as the notice strip
    local y = 0
    local note
    if sec == "unclaimed" then
        local days = floor((ns.Util.Now() - (r.at or r.rev)) / DAY)
        note = { "locked", "Nobody is talking with them yet." .. (r.ib and (" " .. Short(r.ib) .. " introduced them " ..
            (days < 1 and "today." or days == 1 and "yesterday." or (days .. " days ago."))) or "") }
    elseif R():InviteQueued(r.key) then
        note = { "info", "Invite waiting: they're offline. You'll get a reminder when they come online." }
    elseif r.iv and r.iv.r == "guild" and r.st == "talk" then
        note = { "locked", "Still in another guild: the game won't invite them. Whisper first." }
    elseif r.fu then
        note = { "info", "Follow up " .. H.Day(r.fu.at) .. (r.fu.t ~= "" and (": " .. r.fu.t) or "") ..
            S:Wrap("SUB", "  ·  " .. Short(r.w or r.jb or Me())) }
    end
    if note then
        v.notice:SetNotice(note[1], note[2])
        v.noticeBtn:Show()
        y = -(26 + GAP)
    else
        v.noticeBtn:Hide()
    end
    local ly = y
    v.settle:SetShown(r.st == "joined" and r.jl ~= nil)
    if r.st == "joined" and r.jl then
        v.settle:ClearAllPoints()
        v.settle:SetPoint("TOPLEFT", 0, ly)
        local days = floor((ns.Util.Now() - (r.ja or r.rev)) / DAY)
        v.settle:SetTitle("SETTLING IN · " .. (days >= 14 and (floor(days / 7) .. " WEEKS") or (days .. " DAYS")), "caps")
        local now = live.lv or r.lv or r.jl
        v.settle.bar:Set(r.jl >= 70 and 1 or (now - r.jl) / max(1, 70 - r.jl))
        v.settle.lvt:SetText(r.jl .. " to " .. now)
        v.settle.facts:SetText(S:Wrap("TEXT", r.la and H.Day(r.la) or "?") .. " last online")
        ly = ly - 70 - GAP
    end
    local joined = r.st == "joined" or r.st == "gone"
    v.looking:SetShown(not joined)
    if not joined then
        v.looking:ClearAllPoints()
        v.looking:SetPoint("TOPLEFT", 0, ly)
        ly = ly - H.FillLooking(v.looking, r) - GAP
    end
    v.story:ClearAllPoints()
    v.story:SetPoint("TOPLEFT", 0, ly)
    H.FillStory(v.story, r, 380 + ly)
    v.fits:ClearAllPoints()
    v.fits:SetPoint("TOPLEFT", LEFT_W + GAP, y)
    H.FillFits(v.fits, r)
    v.about:ClearAllPoints()
    v.about:SetPoint("TOPLEFT", v.fits, "BOTTOMLEFT", 0, -GAP)
    H.FillAbout(v.about, r)
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

function H.MonthLine()
    local Rc = R()
    local t = date("*t", ns.Util.Now())
    t.day, t.hour, t.min, t.sec = 1, 0, 0, 0
    local from = time(t)
    local met, joined = 0, 0
    for _, r in ipairs(Rc:GetPeople()) do
        if (r.at or 0) >= from then met = met + 1 end
        if (r.ja or 0) >= from then joined = joined + 1 end
    end
    return S:Wrap("SUB", date("%B", from) .. " · met ") .. met .. S:Wrap("SUB", " · joined ") .. joined
end

function RU:CreatePanel(parent)
    if view then return view end
    local v = CreateFrame("Frame", nil, parent)
    view = v
    local L = UI:CreateLayout("listdetail", v, { listWidth = LIST_W, width = S.PAGE_W,
        banner = { size = "hero", artFw = 0.98, artUnder = true } })
    v.layout = L
    L.toolbar:SetTabs({ { key = "people", text = "People" }, { key = "message", text = "Message" }, { key = "post", text = "Posting" },
        selected = "people" },
        function(key) RU:SetView(key) end)
    L.toolbar:SetPrimary({ text = "Add someone", icon = UI.ICON.plus, onClick = function() RU:AddByName() end })
    local lc = L.list
    v.search = UI:CreateSearchBox(lc, LIST_W, function(text)
        state.search = text or ""
        RU:Refresh()
    end, "Search or add a player")
    v.search:SetHeight(24)
    v.search:SetPoint("TOPLEFT")
    v.tabs = {}
    local prev
    for _, f in ipairs({ { "talk", "Talking" }, { "joined", "Joined" }, { "notnow", "Not now" } }) do
        local key = f[1]
        local t = UI:CreateUnderlineTab(lc, f[2], function() RU:SetFilter(key) end, "small")
        if prev then t:SetPoint("LEFT", prev, "RIGHT", 2, 0) else t:SetPoint("TOPLEFT", -4, -30) end
        v.tabs[key] = t
        prev = t
    end
    UI:Rule(lc, { top = 48, alpha = 0.1, layer = "BORDER" })
    v.list = UI:CreateScrollList(lc, S.ROW.art, initRow, function(d) return d.head and 26 or S.ROW.art end)
    v.list.frame:SetPoint("TOPLEFT", 0, -54)
    v.list.frame:SetPoint("BOTTOMLEFT", 0, 0)
    v.list.frame:SetWidth(LIST_W + 20)
    v.list.bar:ClearAllPoints()
    v.list.bar:SetPoint("TOPLEFT", v.list.box, "TOPRIGHT", 1, 0)
    v.list.bar:SetPoint("BOTTOMLEFT", v.list.box, "BOTTOMRIGHT", 1, 0)
    v.lc = lc
    v.detail = L.detail
    v.banner = H.DecorateBanner(L.banner)
    local body = L.body
    v.noticeBtn = CreateFrame("Button", nil, body)
    v.noticeBtn:SetPoint("TOPLEFT", 0, 0)
    v.noticeBtn:SetSize(DETAIL_W, 26)
    v.notice = UI:CreateNotice(v.noticeBtn, "info", "")
    v.notice:SetPoint("TOPLEFT", 0, 0)
    v.notice:SetWidth(DETAIL_W)
    v.noticeBtn:SetScript("OnClick", function(self) RU:FollowMenu(self) end)
    UI:AttachTooltip(v.noticeBtn, "Follow-up", { "Click to change the day or what it's about." })
    v.settle = H.CreateSettle(body)
    v.looking = H.CreateLooking(body)
    v.story = H.CreateStory(body)
    v.fits = H.CreateFits(body)
    v.about = H.CreateAbout(body)
    v.empty = UI:CreateEmptyState(v, { title = "Nobody yet", text = "Right-click a name in chat or a guest in Raids > Guests "
        .. "and pick Add to Recruitment, or use Add someone.", action = { text = "Add someone", onClick = function() RU:AddByName() end } })
    v.empty:SetPoint("TOP", L.detail, "TOP", 0, -80)
    v.empty:Hide()
    v.message = H.CreateMessage(v)
    v:SetScript("OnShow", function() RU:Refresh() end)
    return v
end

---------------------------------------------------------------------------
-- Message (Core/RecruitMessage.lua). Two tabs on the left, one column on the right:
--   Message: the parts as chips in their order (gold while on; click to pick one, drag to move it, right-click for
--     its menu), "+ Add a part", the picked part's editor (your words; or the team, specs / classes and the open places
--     to leave out; or the team's nights), and what joins the parts.
--   Posting: the places, each on / off with its interval (seconds or minutes) and Cities only, when it's next due;
--     the reminder; how posting works (a click or the bound key).
--   Right: the message as it reads in chat, its length, Post now; lately.
---------------------------------------------------------------------------

local MSG_LW = 450
local ROW_H = 30
local CHIP_GAP = 6

local function M() return ns.RecruitMessage end

-- The picked part (state.part, else the first).
function H.PickedPart(parts)
    for _, p in ipairs(parts) do if p.id == state.part then return p end end
    state.part = parts[1] and parts[1].id or nil
    return parts[1]
end

function H.PartLabel(p)
    if p.k == "text" then
        local t = ns.Util.Trim(p.t or "") or ""
        if t == "" then return "Your words (empty)" end
        return "\"" .. (#t > 24 and (t:sub(1, 22) .. "...") or t) .. "\""
    elseif p.k == "need" then return "Classes: " .. (p.teamName or "team gone")
    elseif p.k == "nights" then return "Nights: " .. (p.teamName or "team gone") end
    return p.label
end

-- "+ Add a part": your words, the guild's name, the classes a team needs (a team or every team), a team's nights.
function H.AddPartMenu(owner)
    local teams = R():GetTeams()
    local function added(ok, id)
        if H.Try(ok, id) then state.part = id end
        RU:Refresh()
    end
    UI:ContextMenu(owner, function(root)
        root:CreateTitle("Add a part")
        root:CreateButton(M().KINDS.text.label, function()
            added(M():AddPart("text"))
            if view and view.message then view.message.w.words:SetFocus() end
        end)
        root:CreateButton(M().KINDS.tag.label, function() added(M():AddPart("tag")) end)
        root:CreateDivider()
        if #teams == 0 then
            root:CreateButton(S:Wrap("DIM", "Classes and nights need a team (Raids > Teams)"), function() end)
            return
        end
        local need = root:CreateButton(M().KINDS.need.label)
        for _, t in ipairs(teams) do
            need:CreateButton(t.name, function() added(M():AddPart("need", { team = t.id })) end)
        end
        need:CreateDivider()
        need:CreateButton("Every team", function() added(M():AddPart("need", { team = "all" })) end)
        local nights = root:CreateButton(M().KINDS.nights.label)
        for _, t in ipairs(teams) do
            nights:CreateButton(t.name, function() added(M():AddPart("nights", { team = t.id })) end)
        end
    end)
end

function H.PartMenu(owner, id)
    local p = M():GetPart(id)
    if not p then return end
    local _, i = M():GetPart(id)
    local n = #M():GetParts()
    UI:ContextMenu(owner, function(root)
        root:CreateTitle(M().KINDS[p.k].label)
        root:CreateButton(p.off and "Put it back in" or "Leave it out", function() M():SetPart(id, { on = p.off and true or false }) end)
        if i > 1 then root:CreateButton("Move left", function() M():MovePart(id, i - 1) end) end
        if i < n then root:CreateButton("Move right", function() M():MovePart(id, i + 1) end) end
        root:CreateDivider()
        root:CreateButton(S:Wrap("BAD", "Remove"), function() M():RemovePart(id) end)
    end)
end

function H.TeamMenu(owner, p)
    UI:ContextMenu(owner, function(root)
        root:CreateTitle("Which team")
        for _, t in ipairs(R():GetTeams()) do
            root:CreateButton((p.team == t.id and S:Wrap("GOLD", t.name)) or t.name, function() M():SetPart(p.id, { team = t.id }) end)
        end
        if p.k == "need" then
            root:CreateDivider()
            root:CreateButton(p.team == "all" and S:Wrap("GOLD", "Every team") or "Every team",
                function() M():SetPart(p.id, { team = "all" }) end)
        end
    end)
end

-- Where a dragged chip lands: its index in the order, and the chip it goes before (nil: at the end).
function H.DropAt(w)
    local x, y = GetCursorPosition()
    local scale = w:GetEffectiveScale()
    x, y = x / scale, y / scale
    local best, bestD, before
    for i, c in ipairs(w.chips) do
        if c:IsShown() and c.partId then
            local l, b, cw, ch = c:GetRect()
            if l then
                local cx, cy = l + cw / 2, b + ch / 2
                local d = math.abs(cy - y) * 4 + math.abs(cx - x)
                if not bestD or d < bestD then
                    bestD = d
                    best = (x < cx) and i or i + 1
                    before = (x < cx) and c or w.chips[i + 1]
                    if before and not before:IsShown() then before = nil end
                end
            end
        end
    end
    return best, before
end

function H.PartChip(w, i)
    local c = w.chips[i]
    if c then return c end
    c = UI:CreateChip(w, { kind = "track", onClick = function(self, button)
        if w.drag then return end
        if button == "RightButton" then
            H.PartMenu(self, self.partId)
        else
            state.part = self.partId
            RU:Refresh()
        end
    end })
    c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    c:RegisterForDrag("LeftButton")
    c:SetScript("OnDragStart", function(self)
        w.drag = self.partId
        self:SetAlpha(0.45)
        w:SetScript("OnUpdate", function()
            local _, before = H.DropAt(w)
            w.dropBar:ClearAllPoints()
            if before then
                w.dropBar:SetPoint("RIGHT", before, "LEFT", -2, 0)
            else
                local last
                for _, x in ipairs(w.chips) do if x:IsShown() then last = x end end
                if last then w.dropBar:SetPoint("LEFT", last, "RIGHT", 2, 0) end
            end
            w.dropBar:Show()
        end)
    end)
    c:SetScript("OnDragStop", function(self)
        w:SetScript("OnUpdate", nil)
        w.dropBar:Hide()
        local to = H.DropAt(w)
        local id = w.drag
        w.drag = nil
        if id and to then
            local from
            for j, x in ipairs(w.chips) do if x.partId == id then from = j end end
            if from and to > from then to = to - 1 end
            M():MovePart(id, to)
        end
        RU:Refresh()
    end)
    UI:AttachTooltip(c, nil, function(self)
        local p = M():GetPart(self.partId)
        if not p then return nil end
        local said = M():PartText(p)
        return { M().KINDS[p.k].label, said and ("Says: " .. said) or S:Wrap("SUB", "Says nothing now."),
                 S:Wrap("SUB", "Click to change it. Drag to move it. Right-click: leave out, move, remove.") }
    end, { anchor = "ANCHOR_TOP" })
    w.chips[i] = c
    return c
end

-- A "leave out" chip of a Classes part: one open place (spec or class).
function H.EntryChip(w, i)
    local c = w.entries[i]
    if c then return c end
    c = UI:CreateChip(w, { kind = "track", roundIcon = true, onClick = function(self)
        if w.partId and self.entryKey then M():SetPart(w.partId, { skip = self.entryKey }) end
    end })
    UI:AttachTooltip(c, nil, function(self)
        return { self.entryName or "", S:Wrap("SUB", self.skipped and "Left out: click to put it back in." or
            "In the message: click to leave it out.") }
    end, { anchor = "ANCHOR_TOP" })
    w.entries[i] = c
    return c
end

-- One place's row: on/off, its name, "every [n] [s | min]", Cities, when it's next due, remove.
function H.PlaceRow(m, i)
    local row = m.rows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, m.placesHost)
    row:SetSize(MSG_LW, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    UI:Rule(row, { bottom = 0, alpha = 0.06 })
    row.sw = UI:CreateSwitch(row, function() local p = row.id and M():GetPlace(row.id) return p and p.on or false end,
        function(a, b)
            if type(a) == "table" then a = b end
            if row.id then M():SetPlace(row.id, { on = a }) end
        end)
    row.sw:SetPoint("LEFT", 0, 0)
    row.name = UI:Text(row, "body", "TEXT")
    row.name:SetPoint("LEFT", row.sw, "RIGHT", 8, 0)
    row.name:SetWidth(112)
    row.name:SetJustifyH("LEFT")
    row.every = UI:Text(row, "small", "SUB")
    row.every:SetPoint("LEFT", 160, 0)
    row.every:SetText("every")
    row.box = UI:CreateSleekEditBox(row, 40, 20, "GameFontHighlightSmall")
    row.box:SetPoint("LEFT", row.every, "RIGHT", 5, 0)
    row.box:SetJustifyH("CENTER")
    row.box:SetMaxLetters(3)
    if row.box.SetNumeric then row.box:SetNumeric(true) end
    local function save(self)
        local p = row.id and M():GetPlace(row.id)
        local n = tonumber(self:GetText())
        if p and n then M():SetPlace(row.id, { every = n * ((p.u or "m") == "m" and 60 or 1) }) end
    end
    row.box:SetScript("OnEnterPressed", function(self) save(self); self:ClearFocus() end)
    row.box:HookScript("OnEditFocusLost", save)
    row.unit = UI:CreateSegments(row, { { key = "s", label = "s" }, { key = "m", label = "min" } }, function(key)
        local p = row.id and M():GetPlace(row.id)
        if not p then return end
        local n = tonumber(row.box:GetText()) or 1
        M():SetPlace(row.id, { u = key, every = n * (key == "m" and 60 or 1) })
    end, { h = 20, itemW = 32 })
    row.unit:SetPoint("LEFT", row.box, "RIGHT", 5, 0)
    UI:AttachTooltip(row.unit, "Seconds or minutes", { "30 seconds at the least, 12 hours at the most." })
    row.city = UI:CreateCheckbox(row, "Cities", function() local p = row.id and M():GetPlace(row.id) return p and p.city or false end,
        function(a, b)
            if type(a) == "table" then a = b end
            if row.id then M():SetPlace(row.id, { city = a }) end
        end)
    row.city:SetPoint("LEFT", 316, 0)
    UI:AttachTooltip(row.city, "Major cities only", { "Posts only while you're in a capital: Stormwind, Orgrimmar, "
        .. "Shattrath and the others." })
    row.next = UI:Text(row, "small", "DIM", { justify = "RIGHT" })
    row.next:SetPoint("RIGHT", -24, 0)
    row.del = UI:CreateRemoveButton(row, "Remove this place")
    row.del:SetPoint("RIGHT", 0, 0)
    row.del:SetScript("OnClick", function() if row.id then M():RemovePlace(row.id) end end)
    m.rows[i] = row
    return row
end

function H.AddPlaceMenu(owner)
    UI:ContextMenu(owner, function(root)
        root:CreateTitle("Add a place")
        local have = {}
        for _, p in ipairs(M():GetPlaces()) do have[p.id] = true end
        local seen = {}
        local function add(kind, name, note)
            local id = kind == "CHANNEL" and ("ch:" .. name:lower()) or kind:lower()
            if have[id] or seen[id] then return end
            seen[id] = true
            root:CreateButton(name .. (note and S:Wrap("SUB", "  " .. note) or ""), function() H.Try(M():AddPlace(kind, name)) end)
        end
        for _, s in ipairs(M().SUGGESTED) do add(s.kind, s.name) end
        local joined = M():JoinedChannels()
        if #joined > 0 then root:CreateDivider() end
        for _, name in ipairs(joined) do add("CHANNEL", name, "you're in it") end
        root:CreateDivider()
        root:CreateButton("Another channel...", function()
            ns.Popup:Prompt({ title = "A channel", text = "The channel's name, as in /join.", maxLetters = 32, trim = true,
                validate = function(v) return v ~= "" end, onAccept = function(v) H.Try(M():AddPlace("CHANNEL", v)) end })
        end)
    end)
end

function H.PostNow()
    local ok, why, skipped = M():Post()
    if not ok then ns:Print("%s", tostring(why))
    elseif skipped and #skipped > 0 then ns:Print("Not posted: %s", table.concat(skipped, "; ")) end
end

function H.CreateWrite(m)
    local w = CreateFrame("Frame", nil, m)
    w:SetPoint("TOPLEFT", 0, 0)
    w:SetSize(MSG_LW, 400)
    w.head = UI:CreateSectionHeader(w, "Your message", { style = "caps", rule = true,
        action = { text = "+ Add a part", onClick = function(self) H.AddPartMenu(self) end,
                   tip = { "Add a part", "Your own words, or a helper that fills in the facts: the guild's name, the "
                       .. "classes a team still needs, a team's raid nights." } } })
    w.head:SetPoint("TOPLEFT", 0, 0)
    w.head:SetWidth(MSG_LW)
    w.chips, w.entries = {}, {}
    w.dropBar = w:CreateTexture(nil, "OVERLAY")
    w.dropBar:SetColorTexture(S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], 1)
    w.dropBar:SetSize(2, 20)
    w.dropBar:Hide()
    w.empty = UI:Text(w, "body", "SUB", { wrap = true, width = MSG_LW })
    w.empty:SetText("Nothing yet. + Add a part: your own words, and helpers that fill in the facts for you (the "
        .. "guild's name, the classes a team still needs, a team's raid nights). They go out in the order you put them.")
    w.edHead = UI:CreateSectionHeader(w, "", { style = "caps", rule = true,
        action = { text = "Remove", onClick = function() if w.partId then M():RemovePart(w.partId) end end,
                   tip = { "Remove", "Takes this part out of the message." } } })
    w.edHead:SetWidth(MSG_LW)
    w.words = UI:CreateSleekEditBox(w, MSG_LW, 24, "GameFontHighlightSmall")
    w.words:SetMaxLetters(200)
    UI:SetEditPlaceholder(w.words, "Your words, as they should read in chat")
    w.words:SetScript("OnTextChanged", function(self, user)
        if user and w.partId then M():SetPart(w.partId, { t = self:GetText() }) end
    end)
    w.words:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    w.team = UI:CreateSleekButton(w, "Team", 170, 22, function(self)
        local p = w.partId and M():GetPart(w.partId)
        if p then H.TeamMenu(self, p) end
    end, "secondary")
    w.by = UI:CreateSegments(w, { { key = "spec", label = "Specs" }, { key = "short", label = "Short" },
        { key = "class", label = "Classes" } }, function(key)
        if w.partId then M():SetPart(w.partId, { by = key }) end
    end, { h = 22, itemW = 64 })
    w.info = UI:Text(w, "small", "SUB", { wrap = true, width = MSG_LW })
    w.sepHead = UI:CreateSectionHeader(w, "Join the parts with", { style = "caps", rule = true })
    w.sepHead:SetWidth(MSG_LW)
    local items = {}
    for _, s in ipairs(M().SEPS) do items[#items + 1] = { key = s.key, label = s.label } end
    w.sep = UI:CreateSegments(w, items, function(key) M():SetSep(key) end, { h = 22, itemW = 56 })
    return w
end

function H.CreatePosting(m)
    local p = CreateFrame("Frame", nil, m)
    p:SetPoint("TOPLEFT", 0, 0)
    p:SetSize(MSG_LW, 400)
    m.placesHead = UI:CreateSectionHeader(p, "Where and how often", { style = "caps", rule = true,
        action = { text = "+ Add a place", onClick = function(self) H.AddPlaceMenu(self) end,
                   tip = { "Add a place", "Say, Yell, a channel (Trade, General, LookingForGroup, GuildRecruitment...) or "
                       .. "any channel you're in." } } })
    m.placesHead:SetPoint("TOPLEFT", 0, 0)
    m.placesHead:SetWidth(MSG_LW)
    m.placesHost = CreateFrame("Frame", nil, p)
    m.placesHost:SetPoint("TOPLEFT", m.placesHead, "BOTTOMLEFT", 0, -2)
    m.placesHost:SetSize(MSG_LW, ROW_H)
    m.rows = {}
    m.noPlaces = UI:Text(m.placesHost, "body", "SUB")
    m.noPlaces:SetPoint("TOPLEFT", 0, -6)
    m.noPlaces:SetText("No place yet: + Add a place.")
    m.again = UI:CreateSwitch(p, function() return M():IsRepeating() end, function(a, b)
        if type(a) == "table" then a = b end
        M():SetRepeat(a)
    end)
    m.againT = UI:Text(p, "body", "TEXT")
    m.againT:SetText("Remind me when a place is due")
    m.postNote = UI:Text(p, "small", "SUB", { wrap = true, width = MSG_LW })
    -- the due times count down
    p.elapsed = 0
    p:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        if self.elapsed < 1 then return end
        self.elapsed = 0
        H.FillDue()
    end)
    return p
end

function H.CreateMessage(v)
    local m = CreateFrame("Frame", nil, v)
    m:SetPoint("TOPLEFT", S.PAD, -36)
    m:SetPoint("BOTTOMRIGHT", -S.PAD, 4)
    m.w = H.CreateWrite(m)
    m.p = H.CreatePosting(m)
    -- right: how it reads, Post now, lately
    local RX = MSG_LW + 20
    local RW = S.INNER_W - RX
    m.prevHead = UI:CreateSectionHeader(m, "In chat", { style = "caps", rule = true })
    m.prevHead:SetPoint("TOPLEFT", RX, 0)
    m.prevHead:SetWidth(RW)
    m.prev = UI:CreateCard(m, { tone = "inset", width = RW, height = 96 })
    m.prev:SetPoint("TOPLEFT", RX, -24)
    m.prevText = UI:Text(m.prev.body, "body", { 1, 0.75, 0.75 }, { wrap = true, width = RW - 2 * S.IN })
    m.prevText:SetPoint("TOPLEFT", 0, 0)
    m.count = UI:Text(m, "small", "SUB", { justify = "RIGHT" })
    m.count:SetPoint("TOPRIGHT", m.prev, "BOTTOMRIGHT", 0, -10)
    m.post = UI:CreateSleekButton(m, "Post now", 110, S.BTN_H, function() H.PostNow() end, "primary")
    m.post:SetPoint("TOPLEFT", m.prev, "BOTTOMLEFT", 0, -6)
    m.latelyHead = UI:CreateSectionHeader(m, "Lately", { style = "caps", rule = true })
    m.latelyHead:SetPoint("TOPLEFT", m.post, "BOTTOMLEFT", 0, -18)
    m.latelyHead:SetWidth(RW)
    m.lately = {}
    for i = 1, 3 do
        local a = UI:Text(m, "body", "TEXT")
        a:SetPoint("TOPLEFT", m.latelyHead, "BOTTOMLEFT", 0, -6 - (i - 1) * 38)
        local b = UI:Text(m, "small", "DIM", { wrap = true, width = RW })
        b:SetPoint("TOPLEFT", a, "BOTTOMLEFT", 0, -2)
        m.lately[i] = { a, b }
    end
    m:Hide()
    return m
end

function H.FillPreview()
    local m = view.message
    local text, n, long = M():Compose()
    m.prevText:SetText("[2. Trade] [" .. Name(Me()) .. "|cffffbfbf]: " .. (text or S:Wrap("SUB", "(add a part to the message)")))
    m.prev:SetHeight(math.max(60, (m.prevText:GetStringHeight() or 14) + 2 * S.IN + 4))
    m.count:SetText((long and S:Wrap("BAD", "too long  ") or "") .. n .. " / " .. M().MAX_LEN)
    m.post:SetEnabled(text ~= nil and not long)
end

function H.Due(at)
    local d = at - ns.Util.Now()
    if d <= 0 then return S:Wrap("OK", "due now") end
    if d < 60 then return "in " .. d .. " s" end
    if d < 3600 then return "in " .. math.ceil(d / 60) .. " min" end
    return "at " .. date("%H:%M", at)
end

function H.FillDue()
    local m = view and view.message
    if not (m and m:IsVisible()) then return end
    for _, row in ipairs(m.rows) do
        local p = row:IsShown() and row.id and M():GetPlace(row.id)
        if p then
            local why = M():Blocker(p)
            row.next:SetText(not p.on and S:Wrap("DIM", "off") or why and S:Wrap("WARN", why == "only in major cities"
                and "not in a city" or "not joined") or H.Due(M():NextDue(p.id)))
        end
    end
end

-- The Message tab: chips, the picked part's editor, the separator.
function H.FillWrite()
    local w = view.message.w
    local parts = M():GetParts()
    local pick = H.PickedPart(parts)
    local y = 26
    local cx, cy = 0, y
    for _, c in ipairs(w.chips) do c:Hide() end
    for i, p in ipairs(parts) do
        local c = H.PartChip(w, i)
        c.partId = p.id
        local says = p.on and p.text ~= nil
        c:Set(H.PartLabel(p), says and S.C.GOLD or nil)
        c:SetSelected(pick and pick.id == p.id)
        c:SetAlpha(p.on and 1 or 0.45)
        if cx > 0 and cx + c:GetWidth() > MSG_LW then cx, cy = 0, cy + 26 end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", w, "TOPLEFT", cx, -cy)
        c:Show()
        cx = cx + c:GetWidth() + CHIP_GAP
    end
    w.empty:SetShown(#parts == 0)
    w.empty:ClearAllPoints()
    w.empty:SetPoint("TOPLEFT", 0, -y)
    y = (#parts == 0) and (y + (w.empty:GetStringHeight() or 28) + 16) or (cy + 34)
    -- the editor
    w.partId = pick and pick.id or nil
    w.edHead:SetShown(pick ~= nil)
    w.words:SetShown(pick ~= nil and pick.k == "text")
    w.team:SetShown(pick ~= nil and (pick.k == "need" or pick.k == "nights"))
    w.by:SetShown(pick ~= nil and pick.k == "need")
    w.info:SetShown(pick ~= nil and pick.k ~= "text")
    for _, c in ipairs(w.entries) do c:Hide() end
    if pick then
        w.edHead:ClearAllPoints()
        w.edHead:SetPoint("TOPLEFT", 0, -y)
        w.edHead:SetTitle(M().KINDS[pick.k].label .. (pick.on and "" or "  (left out)"))
        y = y + 26
        if pick.k == "text" then
            w.words:ClearAllPoints()
            w.words:SetPoint("TOPLEFT", 0, -y)
            if not w.words:HasFocus() then w.words:SetText(pick.t or "") end
            y = y + 32
        elseif pick.k == "tag" then
            w.info:ClearAllPoints()
            w.info:SetPoint("TOPLEFT", 0, -y)
            w.info:SetText(pick.text and ("Says " .. S:Wrap("TEXT", pick.text) .. ": the guild's name, as the game has it.")
                or "Says nothing: you're not in a guild.")
            y = y + (w.info:GetStringHeight() or 14) + 10
        else
            w.team:ClearAllPoints()
            w.team:SetPoint("TOPLEFT", 0, -y)
            w.team:SetText((pick.teamName and (pick.team == "all" and "Every team" or pick.teamName) or "Pick a team") .. "  v")
            if pick.k == "need" then
                w.by:ClearAllPoints()
                w.by:SetPoint("LEFT", w.team, "RIGHT", 10, 0)
                w.by:Select(pick.by)
            end
            y = y + 30
            local info
            if pick.k == "nights" then
                info = pick.text and ("Says " .. S:Wrap("TEXT", pick.text) .. ", from the team's raid nights.")
                    or "Says nothing: the team has no raid nights yet (Raids > Teams)."
            else
                local list = M():NeedList(M():GetPart(pick.id))
                local ex, ey = 0, y
                for i, e in ipairs(list) do
                    local c = H.EntryChip(w, i)
                    c.entryKey, c.entryName, c.skipped = e.key, e.name, e.skip
                    local icon = e.c and e.sp and ns.SpecIcon(e.c, e.sp)
                    local cc = e.c and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.c]
                    c:SetIcon(icon or nil)
                    c:Set(e.name, (not icon and cc) and { cc.r, cc.g, cc.b } or nil)
                    c:SetSelected(not e.skip)
                    c:SetAlpha(e.skip and 0.45 or 1)
                    if ex > 0 and ex + c:GetWidth() > MSG_LW then ex, ey = 0, ey + 24 end
                    c:ClearAllPoints()
                    c:SetPoint("TOPLEFT", w, "TOPLEFT", ex, -ey)
                    c:Show()
                    ex = ex + c:GetWidth() + CHIP_GAP
                end
                if #list > 0 then y = ey + 28 end
                info = #list == 0 and "Says nothing: nothing is open in the comp (Raids > Teams > Comp)."
                    or "Open in the comp now; it follows the comp as it changes. Click one to leave it out."
            end
            w.info:ClearAllPoints()
            w.info:SetPoint("TOPLEFT", 0, -y)
            w.info:SetText(info)
            y = y + (w.info:GetStringHeight() or 14) + 10
        end
    end
    -- what joins them
    y = y + 6
    w.sepHead:ClearAllPoints()
    w.sepHead:SetPoint("TOPLEFT", 0, -y)
    w.sep:ClearAllPoints()
    w.sep:SetPoint("TOPLEFT", 0, -(y + 26))
    w.sep:Select(M():GetSep())
end

-- The Posting tab: the places, the reminder, how posting works.
function H.FillPosting()
    local m = view.message
    local places = M():GetPlaces()
    for _, r in ipairs(m.rows) do r:Hide() end
    for i, p in ipairs(places) do
        local row = H.PlaceRow(m, i)
        row.id = p.id
        row.sw:Refresh()
        row.city:SetChecked(p.city)
        row.name:SetText(p.kind == "CHANNEL" and p.name or S:Wrap("GOLD", "/" .. p.name:lower()))
        if not row.box:HasFocus() then row.box:SetText(tostring(p.u == "s" and p.every or floor(p.every / 60))) end
        row.unit:Select(p.u)
        row:SetAlpha(p.on and 1 or 0.6)
        row:Show()
    end
    m.noPlaces:SetShown(#places == 0)
    m.placesHost:SetHeight(math.max(1, #places) * ROW_H)
    m.again:ClearAllPoints()
    m.again:SetPoint("TOPLEFT", m.placesHost, "BOTTOMLEFT", 0, -16)
    m.again:Refresh()
    m.againT:ClearAllPoints()
    m.againT:SetPoint("LEFT", m.again, "RIGHT", 8, 0)
    local key = H.KeyText()
    m.postNote:ClearAllPoints()
    m.postNote:SetPoint("TOPLEFT", m.again, "BOTTOMLEFT", 0, -10)
    m.postNote:SetText("The game posts in channels only from a click or a key: Post now, the reminder's click when a "
        .. "place is due, or " .. (key and ("your key, " .. S:Wrap("GOLD", key)) or
        "a key you bind in Key Bindings > AddOns > DisasterZone") .. " (it posts to the places that are due). "
        .. "Officers take turns per place.")
    H.FillDue()
end

function H.FillMessage()
    local m = view.message
    local write = state.view == "message"
    m.w:SetShown(write)
    m.p:SetShown(not write)
    if write then H.FillWrite() else H.FillPosting() end
    H.FillPreview()
    local l = M():Lately()
    local names = {}
    for i, r in ipairs(l.came) do
        if i > 4 then break end
        names[#names + 1] = Short(r.key)
    end
    local lines = {
        { (l.week == 1 and "Posted once" or ("Posted " .. l.week .. " times")) .. " this week",
          l.last and ("last " .. date("%a %H:%M", l.last)) or "not posted yet" },
        { #l.came .. (#l.came == 1 and " person" or " people") .. " whispered after a post", #names > 0 and tconcat(names, ", ") or "nobody yet" },
        { l.joined .. " joined after a post", "from the people above" },
    }
    for i, x in ipairs(lines) do
        m.lately[i][1]:SetText(x[1])
        m.lately[i][2]:SetText(x[2])
    end
end

function RU:Refresh()
    if not view or not view:IsShown() and not view.forceRefresh then return end
    local Rc = R()
    view.layout.toolbar:SetText(H.MonthLine())
    local people = state.view == "people"
    view.layout.toolbar:SelectTab(state.view)
    view.lc:SetShown(people)
    view.message:SetShown(not people)
    if not people then
        view.detail:Hide()
        view.empty:Hide()
        H.FillMessage()
        return
    end
    local rows, counts = H.Rows()
    for key, t in pairs(view.tabs) do
        t:SetActive(key == state.filter)
        UI:SetTabCount(t, counts[key] > 0 and counts[key] or nil)
    end
    -- keep a pick that is still in the list; else the first person (none while only "Add <name>" shows)
    local pick = state.sel and Rc:Get(state.sel)
    local inList = false
    for _, d in ipairs(rows) do if d.r and pick and d.r.key == pick.key then inList = true end end
    if not inList then
        state.sel = nil
        for _, d in ipairs(rows) do if d.r then state.sel = d.r.key break end end
    end
    view.list:SetData(rows)
    local any = #Rc:GetPeople() > 0
    view.empty:SetShown(not any)
    H.FillPerson()
end

function RU:Select(key)
    local r = R():Get(key)
    if not r then return end
    state.sel = r.key
    state.filter = H.FILTER_OF[R():Section(r)] or state.filter
    self:Refresh()
end

function RU:SetFilter(f)
    state.filter = f
    state.sel = nil
    self:Refresh()
end

function RU:SetView(key) state.view = key; self:Refresh() end

-- Opens Guild > Recruitment (on a person when key is given).
function RU:Open(key)
    if key then
        local r = R():Get(key)
        if r then
            state.sel = r.key
            state.filter = H.FILTER_OF[R():Section(r)] or "talk"
        end
    end
    if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open("recruit") end
    self:Refresh()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Adds a name (or asks for one), then opens them.
function RU:AddByName(name, opts)
    local function add(n)
        n = ns.Util.Trim(n or "")
        if n == "" then return end
        local key = ns.Util.NormalizeName(n)
        if R():Get(key) then
            RU:Open(key)
            return
        end
        local ok, err = R():Add(key, opts)
        if not ok then ns:Print("%s", tostring(err)) return end
        state.search = ""
        if view and view.search then view.search:SetText("") end
        RU:Open(key)
    end
    if name then return add(name) end
    ns.Popup:Prompt({ title = "Add someone", text = "Their character's name (Name or Name-Realm).", ok = "Add", trim = true,
        maxLetters = 48, validate = function(v) return v ~= "" end, onAccept = function(v) add(v) end })
end

-- From the guest book or a player menu: adds the player with what the guest book or the unit knows.
-- (stay: add without opening the page, e.g. from Raids > Guests' Recruit)
function RU:AddFrom(key, src, unit, stay)
    local opts = { src = src or "whisper" }
    local GB = ns.GuestBook
    local e = GB and GB.GetEntry and GB:GetEntry(key)
    if e then
        opts.c, opts.sp = e.c, e.sp
        if e.note then opts.note, opts.noteBy = e.note, e.noteBy end
        opts.src = "guest"
    end
    if unit and UnitExists and UnitExists(unit) then
        opts.c = opts.c or select(2, UnitClass(unit))
        opts.lv = UnitLevel(unit)
    end
    if R():Get(key) and R():Get(key).st ~= "gone" then return (not stay) and self:Open(key) or nil end
    local ok, err = R():Add(key, opts)
    if not ok then ns:Print("%s", tostring(err)) return end
    ns:Print("%s added to Recruitment.", Short(key))
    if not stay then self:Open(key) end
end

function RU:ToggleWant(what)
    local r = state.sel and R():Get(state.sel)
    if not r then return end
    local w = {}
    for _, x in ipairs(H.WANTS) do w[x[1]] = R():Wants(r, x[1]) end
    w[what] = not w[what]
    H.Try(R():Update(r.key, { wants = w }))
end

function RU:ToggleNight(day)
    local r = state.sel and R():Get(state.sel)
    if not r then return end
    local set, list = {}, {}
    for _, d in ipairs(r.ni or {}) do set[d] = true end
    set[day] = not set[day]
    for d = 1, 7 do if set[d] then list[#list + 1] = d end end
    H.Try(R():Update(r.key, { nights = list }))
end

function RU:EditTime()
    local r = state.sel and R():Get(state.sel)
    if not r then return end
    ns.Popup:Prompt({ title = "When can they raid?", text = "A short time, like \"from 19:00\" or \"late\".", default = r.nt or "",
        maxLetters = 24, trim = true, onAccept = function(v) H.Try(R():Update(r.key, { time = v })) end })
end

function RU:EditSaid()
    local r = state.sel and R():Get(state.sel)
    if not r then return end
    ns.Popup:Prompt({ title = "In their words", text = "What they told you they're looking for.", default = r.sd or "",
        maxLetters = R().MAX_SAID, multiline = true, multiHeight = 64, trim = true,
        onAccept = function(v) H.Try(R():Update(r.key, { said = v })) end })
end

function RU:WriteNote()
    local r = state.sel and R():Get(state.sel)
    if not r then return end
    ns.Popup:Prompt({ title = "Note about " .. Short(r.key), text = "The GM and officers see it.", maxLetters = R().MAX_NOTE,
        multiline = true, multiHeight = 72, trim = true, validate = function(v) return v ~= "" end,
        onAccept = function(v) H.Try(R():AddNote(r.key, v)) end })
end

-- A follow-up in n days (noon of that day), with what it's about.
function RU:SetFollow(days, what)
    local r = state.sel and R():Get(state.sel)
    if not r then return end
    if days == false then return H.Try(R():Update(r.key, { follow = false })) end
    local t = date("*t", ns.Util.Now() + days * DAY)
    t.hour, t.min, t.sec = 12, 0, 0
    H.Try(R():Update(r.key, { follow = { at = time(t), t = what or (r.fu and r.fu.t) or "" } }))
end

function RU:FollowMenu(owner)
    local r = state.sel and R():Get(state.sel)
    if not r then return end
    UI:ContextMenu(owner, function(root)
        root:CreateTitle("Follow up")
        for _, x in ipairs({ { 0, "Today" }, { 1, "Tomorrow" }, { 3, "In 3 days" }, { 7, "In a week" }, { 14, "In two weeks" } }) do
            root:CreateButton(x[2], function() RU:SetFollow(x[1]) end)
        end
        root:CreateDivider()
        root:CreateButton("What about...", function()
            ns.Popup:Prompt({ title = "Follow up about", default = r.fu and r.fu.t or "", maxLetters = 80, trim = true,
                onAccept = function(v)
                    local at = r.fu and r.fu.at
                    if not at then RU:SetFollow(1, v) else H.Try(R():Update(r.key, { follow = { at = at, t = v } })) end
                end })
        end)
        if r.fu then root:CreateButton("Clear", function() RU:SetFollow(false) end) end
    end)
end

function RU:OpenClassMenu(owner)
    local r = state.sel and R():Get(state.sel)
    if not r then return end
    UI:ContextMenu(owner, function(root)
        root:CreateTitle("Class and spec")
        for _, c in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
            local sub = root:CreateButton(UI:ColoredName(ns.ClassName(c), c))
            for sp, spec in ipairs(ns.SPECS[c] or {}) do
                sub:CreateButton(spec.label, function() H.Try(R():Update(r.key, { c = c, sp = sp })) end)
            end
        end
    end)
end

function RU:OpenMore(owner, key)
    local r = R():Get(key)
    if not r then return end
    UI:ContextMenu(owner, function(root)
        root:CreateTitle(Short(key))
        root:CreateButton(UI:AtlasIconText(UI.ICON.whisper or 42, 14) .. "  Whisper", function() H.Whisper(key) end)
        local tags = root:CreateButton("Tags")
        for _, t in ipairs(R():GetRules().tg or {}) do
            local on = has(r.tg, t)
            tags:CreateButton((on and S:Wrap("GOLD", "* ") or "   ") .. t, function()
                local list = {}
                for _, x in ipairs(r.tg or {}) do if x ~= t then list[#list + 1] = x end end
                if not on then list[#list + 1] = t end
                H.Try(R():Update(key, { tags = list }))
            end)
        end
        root:CreateButton("Class and spec...", function() state.sel = key; RU:OpenClassMenu(owner) end)
        root:CreateButton("Follow up...", function() state.sel = key; RU:FollowMenu(owner) end)
        root:CreateButton(UI:AtlasIconText(16, 14) .. "  Note", function() state.sel = key; RU:WriteNote() end)
        root:CreateDivider()
        if r.st == "talk" then root:CreateButton("Not now", function() H.Try(R():NotNow(key)) end) end
        if r.st == "notnow" then root:CreateButton("Talk again", function() H.Try(R():Reopen(key)) end) end
        root:CreateButton(UI:AtlasIconText(UI.ICON.trash, 14) .. "  Remove", function()
            ns.Popup:Confirm({ title = "Remove " .. Short(key) .. "?", text = "Their notes go too, for every officer.",
                ok = "Remove", danger = true, onAccept = function() H.Try(R():Remove(key)) end })
        end)
    end)
end

function RU:NotNow()
    if state.sel then H.Try(R():NotNow(state.sel)) end
end

function RU:CheckedIn()
    local r = state.sel and R():Get(state.sel)
    if not r then return end
    local due = R():CheckInDue(r)
    local ck = r.ck or {}
    if due then ck[due] = true end
    H.Try(R():Note(r.key, { ck = ck, fu = false }))
end

-- Pass to: the recruiters (online first).
function RU:PassMenu(root)
    local G = ns.Guild
    root:CreateTitle("Pass to")
    local list = {}
    for _, key in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        if R():IsRecruiter(key) or (ns.Util.DemoOn() and G:IsOfficer(key)) then
            local m = G:GetMember(key)
            list[#list + 1] = { key = key, online = m and m.online }
        end
    end
    tsort(list, function(a, b) if (a.online and 1 or 0) ~= (b.online and 1 or 0) then return a.online end return a.key < b.key end)
    for _, x in ipairs(list) do
        root:CreateButton(Name(x.key) .. (x.online and S:Wrap("OK", "  online") or S:Wrap("SUB", "  offline")),
            function() if state.sel then H.Try(R():PassTo(state.sel, x.key)) end end)
    end
    if #list == 0 then root:CreateTitle("Nobody else works on recruits") end
end

-- Bring along: a party invite, a guest seat in a raid (the guest book's Add to a raid), a member taking them along.
function RU:BringAlongMenu(root)
    local key = state.sel
    if not key then return end
    root:CreateTitle("Bring them along")
    root:CreateButton(UI:AtlasIconText(UI.ICON.team or 46, 14) .. "  Invite to my group", function()
        local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
        if invite then invite((Ambiguate and Ambiguate(key, "none")) or Short(key)) end
    end)
    local GUI = ns.GuestBookUI
    if GUI and GUI.BuildRaidMenu then
        local sub = root:CreateButton(UI:AtlasIconText(UI.ICON.invite or 19, 14) .. "  A guest seat in a raid")
        GUI:BuildRaidMenu(sub, key, ns.GuestBook and ns.GuestBook:GetEntry(key))
    end
    RU:AskMemberMenu(root, key)
end

-- Guild members online (not me), for "ask a member": the ones who were in a group or raid with them first is not
-- known to the addon, so: everyone online, by name.
function H.OnlineMembers()
    local G = ns.Guild
    local out = {}
    for _, k in ipairs(G and G.GetOnlineMembers and G:GetOnlineMembers() or {}) do
        if not ns.Util.IsMe(k) then out[#out + 1] = k end
    end
    tsort(out)
    return out
end

function RU:AskMemberMenu(root, key)
    local I = ns.RecruitIntro
    if not I then return end
    local list = H.OnlineMembers()
    root:CreateDivider()
    local take = root:CreateButton(UI:AtlasIconText(UI.ICON.whisper or 42, 14) .. "  Ask a member to take them along")
    local ask = root:CreateButton(UI:AtlasIconText(UI.ICON.notes or 25, 14) .. "  Ask how it went")
    for i, m in ipairs(list) do
        if i > 25 then break end
        take:CreateButton(Name(m), function() H.Try(I:AskTakeAlong(key, m)) end)
        ask:CreateButton(Name(m), function() H.Try(I:AskHowItWent(key, m)) end)
    end
    if #list == 0 then
        take:CreateTitle("Nobody else is online")
        ask:CreateTitle("Nobody else is online")
    end
end

-- Invite to the guild: one dialog (the welcome line can be changed or emptied); the game's invite goes out on its
-- button (a click: the game wants one). What happens when they accept is listed in it.
function RU:Invite()
    if state.sel then RU:ConfirmInvite(state.sel) end
end

function RU:ConfirmInvite(key, queued)
    local Rc = R()
    local r = Rc:Get(key)
    if not r then return end
    local d = queued or Rc:InviteDefaults(r.key)
    local guild = (GetGuildInfo and GetGuildInfo("player")) or "the guild"
    local lines = { "The guild invite goes out now. When they accept:",
        "- the welcome line below goes to guild chat (empty: none)",
        "- officer note: " .. S:Wrap("TEXT", "\"" .. (d.note or "") .. "\"") }
    if d.team then
        lines[#lines + 1] = "- onto " .. S:Wrap("GOLD", d.teamName or "the team") .. "'s bench; its raid leaders hear about it"
    end
    lines[#lines + 1] = "- check-ins after a week and a month, for you"
    ns.Popup:Prompt({ title = "Invite " .. Short(r.key) .. " to " .. guild .. "?", text = tconcat(lines, "\n"),
        default = d.welcome or "", ok = "Invite", maxLetters = 255, width = 420,
        onAccept = function(v)
            d.welcome = v or ""
            local ok, res = Rc:Invite(r.key, d)
            if not ok then ns:Print("%s", tostring(res))
            elseif res == "queued" then ns:Print("%s is offline: you'll get a reminder to invite them when they come online.", Short(r.key)) end
        end })
end

-- A queued invite's player came online: a toast with Invite (the click sends it).
function RU:InviteReady(key)
    local Rc = R()
    local r = Rc:Get(key)
    if not r or r.st ~= "talk" then Rc:CancelQueued(key) return end
    UI:Toast({ key = "recruit-invite-" .. key, title = Short(key) .. " is online",
        text = "Click to send the guild invite you prepared.", keepTime = 60,
        onClick = function()
            local opts = Rc:QueuedOpts(key)
            local ok, err = Rc:Invite(key, opts)
            if not ok then ns:Print("%s", tostring(err)) end
        end })
end

-- (the key binding: a key press may post in a channel) the places that are due, or every place when no reminder is on
function DisasterZone_PostRecruit()
    local M = ns.RecruitMessage
    if not (M and R() and R():CanUse()) then return end
    local ok, why, skipped = M:PostByKey()
    if not ok then ns:Print("%s", tostring(why))
    elseif skipped and #skipped > 0 then ns:Print("Not posted: %s", table.concat(skipped, "; ")) end
end
BINDING_HEADER_DISASTERZONE = BINDING_HEADER_DISASTERZONE or "DisasterZone"
BINDING_NAME_DISASTERZONE_RECRUITPOST = "Post the recruitment message"

function H.KeyText()
    local k = GetBindingKey and GetBindingKey("DISASTERZONE_RECRUITPOST")
    return k and (GetBindingText and GetBindingText(k) or k) or nil
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function RU:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("recruit", "Recruitment", 3.577, function(parent) return RU:CreatePanel(parent) end,
            function() return R():CanUse() end, { layout = "listdetail" })
    end
    for _, e in ipairs({ "RECRUIT_UPDATED", "RECRUIT_RULES_CHANGED", "RAIDPLAN_CHANGED", "GUESTBOOK_CHANGED", "RECRUIT_LIVE",
                         "RECRUIT_MSG_CHANGED", "RECRUIT_MSG_POSTED" }) do
        ns:On(e, function()
            if view and view:IsVisible() then ns.Util.Debounce("recruit-ui", 0.1, function() RU:Refresh() end) end
        end)
    end
    ns:On("RECRUIT_INVITE_READY", function(key) RU:InviteReady(key) end)
    -- the recruitment message is due again: a toast whose click posts it (the game needs a click)
    ns:On("RECRUIT_MSG_READY", function(due)
        local M = ns.RecruitMessage
        local names = {}
        for _, id in ipairs(due or {}) do
            local pl = M:GetPlace(id)
            if pl then names[#names + 1] = pl.kind == "CHANNEL" and pl.name or ("/" .. pl.name:lower()) end
        end
        UI:Toast({ key = "recruit-msg", title = "Recruitment message",
            text = "Due in " .. table.concat(names, ", ") .. ". Click to post" .. (H.KeyText() and (" or press "
                .. H.KeyText()) or "") .. ".", keepTime = 120, onClick = function()
                local ok, why = M:Post(M:Ready() or due)
                if not ok then ns:Print("%s", tostring(why)) end
            end })
    end)
    ns:RegisterSlash("recruit", function() RU:Open() end, "open Guild > Recruitment")
end

-- (tests / audit)
function RU:GetPanel() return view end
function RU:GetState() return state end
function RU:SetSearch(text)
    state.search = text or ""
    if view and view.search then view.search:SetText(state.search) end
    self:Refresh()
end
RU._H = H
