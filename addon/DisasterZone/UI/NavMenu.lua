if DisasterZoneBoot and DisasterZoneBoot.Run("UI/NavMenu.lua", ...) then return end -- DisasterZone UI/NavMenu.lua
-- ns.NavMenu: the nav strip's group menus (Raids / Gear / Guild) as a spotlight: the group's pages in a short list on
-- the left, the page under the mouse shown big on the right: its loading-screen art drifting slowly, an icon in a
-- gold ring, its line, up to two live facts and jumps straight into its views. Moving down the list crossfades the
-- spotlight. It hangs under its tab with a gold tie to the tab's underline and drops in like every menu.
--   NavMenu:Open(owner, spec): spec = { pages = { { key, label, line, count, badge = { text, color } }, ... },
--     current = the page shown now, focus = the page to spotlight first, onPick(key, view) = open a page (view: a
--     jump's key) }. NavMenu:Close(), NavMenu:IsOpenFor(owner), NavMenu:IsMouseOver(), NavMenu:Focus(key).
--   A click outside, Escape or the owner hiding closes it (as UI:ContextMenu's menus).
-- Per page (INFO): the art, the icon, the accent, facts() -> { { value, label }, ... } and views() -> { { key, label,
-- on }, ... }; every call into a page's module is guarded (a missing module or an error shows nothing).
local addonName, ns = ...

local NavMenu = ns:NewModule("NavMenu")
local UI = ns.UI

local floor, min, max, sin, pi = math.floor, math.min, math.max, math.sin, math.pi

local PAD, GAP = 8, 8
local RAIL_W, ROW_H, ROW_GAP = 160, 42, 2
local SPOT_W, ART_H = 330, 128
local FACT_H, CHIP_H, CHIP_GAP = 46, 18, 4
local TIE_W = 44
local SWAP_TIME = 0.22          -- the spotlight's crossfade
local DRIFT_TIME = 9            -- seconds: the art's slow zoom one way (then back)
local GOLD = { 1, 0.82, 0 }
local WHITE8 = "Interface\\Buttons\\WHITE8X8"
local MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"
local RADIAL = MEDIA .. "MyBiS\\Radial"
local RING = MEDIA .. "Events\\ring"
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local LS = "Interface\\Glues\\LoadingScreens\\LoadScreen"

local function Now() return (GetServerTime and GetServerTime()) or time() end

-- Calls fn(...) safely: nil when it fails.
local function Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    ns:Debug("nav menu: %s", tostring(a))
    return nil
end

local function Count(n) return tostring(floor(tonumber(n) or 0)) end

---------------------------------------------------------------------------
-- The pages: art, icon, accent, live facts, views
---------------------------------------------------------------------------

-- Raid loading screens by FileDataID (the client doesn't resolve them by path), the others by path; cx = where the
-- painting's subject stands across it.
local INFO = {
    raids   = { art = 131826, cx = 0.40, icon = "calendar", accent = { 1, 0.82, 0 } },
    council = { art = 131849, cx = 0.22, icon = "crown", accent = { 0.77, 0.55, 1 } },
    mylog   = { art = 131842, cx = 0.42, icon = "practice", accent = { 0.37, 0.82, 1 } },
    mybis   = { art = 131846, cx = 0.50, icon = "bag", accent = { 1, 0.82, 0 } },
    atlas   = { art = LS .. "Outland", cx = 0.50, icon = "eye", accent = { 0.53, 0.85, 0.42 } },
    members = { art = LS .. "EasternKingdom", cx = 0.50, icon = "team", accent = { 1, 0.82, 0 } },
    map     = { art = LS .. "Kalimdor", cx = 0.55, icon = "flag", accent = { 0.37, 0.82, 1 } },
    events  = { art = LS .. "NagrandArenaBattlegrounds", cx = 0.50, icon = "trophy", accent = { 0.73, 0.55, 1 } },
    polls   = { art = LS .. "WarsongGulch", cx = 0.50, icon = "poll", accent = { 1, 0.82, 0 } },
    games   = { art = 131849, cx = 0.70, icon = "games", accent = { 0.31, 0.83, 0.88 } },
}
local DEFAULT_INFO = { art = LS .. "Outland", cx = 0.5, icon = "notes", accent = GOLD }
NavMenu.INFO = INFO

local function IconIndex(name)
    local I = UI.ICON
    if name == "poll" and not (ns.HasAssets and ns:HasAssets(6)) then name = "notes" end
    return I[name] or I.notes
end

-- Views (the page's own tabs), in its order; on = the one it shows now. Only views the player can open.
local VIEWS = {
    raids = function()
        local R, RP, G = ns.RaidsUI, ns.RaidPlan, ns.Guild
        local cur = R and R.GetView and R:GetView()
        local out = { { key = "upcoming", label = "Upcoming" }, { key = "teams", label = "Teams" },
                      { key = "strategies", label = "Strategies" } }
        if RP and RP.CanManageRoster and RP:CanManageRoster() then out[#out + 1] = { key = "guests", label = "Guests" } end
        local demo = ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
        if demo or (G and G.AmIRaidLogMember and G:AmIRaidLogMember()) then
            out[#out + 1] = { key = "log", label = "Raid log" }
        end
        for _, v in ipairs(out) do v.on = v.key == cur end
        return out
    end,
    council = function()
        local C = ns.CouncilUI
        local cur = C and C.GetView and C:GetView()
        local out = { { key = "roster", label = "Roster" }, { key = "items", label = "Items" },
                      { key = "log", label = "Loot log" }, { key = "council", label = "Loot council" } }
        for _, v in ipairs(out) do v.on = v.key == cur end
        return out
    end,
    members = function()
        local M = ns.MembersUI
        local cur = M and M.GetMode and M:GetMode()
        return { { key = "roster", label = "Roster", on = cur == "roster" },
                 { key = "recipes", label = "Recipes", on = cur == "recipes" } }
    end,
    events = function()
        local E = ns.EventsUI
        local cur = E and E.GetView and E:GetView()
        return { { key = "upcoming", label = "Upcoming", on = cur == "upcoming" },
                 { key = "library", label = "Library", on = cur == "library" },
                 { key = "season", label = "Season", on = cur == "season" } }
    end,
    atlas = function()
        return { { key = "shop", label = "Shopping list" } }
    end,
    games = function()
        local out = {}
        local Gm = ns.Games
        local open = ns.GamesUI and ns.GamesUI.GetSelected and ns.GamesUI:GetSelected()
        for _, d in ipairs(Gm and Gm.GetList and Gm:GetList() or {}) do
            out[#out + 1] = { key = d.id, label = d.name, on = d.id == open }
        end
        return out
    end,
}

-- Opens view key of page (after the page itself is shown).
local OPEN_VIEW = {
    raids = function(v) ns.RaidsUI:SetView(v) end,
    council = function(v) ns.CouncilUI:SetView(v) end,
    members = function(v) ns.MembersUI:SetMode(v) end,
    events = function(v) ns.EventsUI:SetView(v) end,
    atlas = function() ns.AtlasUI:OpenShop() end,
    games = function(v) ns.GamesUI:Select(v) end,
}
NavMenu.VIEWS, NavMenu.OPEN_VIEW = VIEWS, OPEN_VIEW

-- Live facts: { { value, label }, ... } (at most two shown). Filled in below (FACTS[key] = function).
local FACTS = {}
NavMenu.FACTS = FACTS

local function Demo() return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() or false end
local function Plural(n, one, many) return n == 1 and one or many end

-- "in 13 min", "in 3 days", "now"; "started" for a raid under way.
local function Relative(t)
    if t <= Now() then return "Now" end
    local E = ns.EventUI
    return E and E.Relative and E:Relative(t) or date("%a %H:%M", t)
end

-- The raid's instance(s), short ("Karazhan", "Gruul + Mag"): the custom titles can be long.
local function RaidShort(v)
    local RP, RC = ns.RaidPlan, ns.RaidComp
    if v.ix and RC and RC.ShortRaidName then return RC:ShortRaidName(v) end
    local inst = RP and RP.GetInstance and RP:GetInstance(v.i)
    return inst and inst.name or (RP and RP:GetRaidName(v)) or "Raid"
end

FACTS.raids = function()
    local RP = ns.RaidPlan
    if not (RP and RP.GetRaids) then return end
    local now = Now()
    for _, v in ipairs(RP:GetRaids(now - 3 * 3600)) do
        if not v.cancelled then
            local out = { { Relative(v.t), RaidShort(v) } }
            local acc = 0
            for _, s in pairs(RP:GetSignups(v.id) or {}) do
                if s.st == "A" then acc = acc + 1 end
            end
            out[2] = { acc .. "/" .. (tonumber(v.sz) or 25), "accepted" }
            return out
        end
    end
    return { { "None", "planned yet" } }
end

FACTS.council = function()
    local out = {}
    local R = ns.Roll
    local n = (R and R.GetActive and R:GetActive() and 1 or 0) + #(R and R.GetQueue and R:GetQueue() or {})
    if n > 0 then out[#out + 1] = { Count(n), Plural(n, "item to decide", "items to decide") } end
    local L = ns.Ledger
    if L and L.GetVisibleEntries then
        local k = 0
        for _, e in ipairs(L:GetVisibleEntries({ since = Now() - 7 * 86400, excludeDungeon = true }) or {}) do
            if not e.vd then k = k + 1 end
        end
        out[#out + 1] = { Count(k), "awarded in 7 days" }
    end
    return out
end

FACTS.mylog = function()
    local L, Kit = ns.MyLog, ns.MyLogKit
    if not L then return end
    if not (L.IsEnabled and L:IsEnabled()) and not Demo() then return { { "Off", "nothing is recorded" } } end
    local pulls = L:GetPulls() or {}
    local out = {}
    for i = #pulls, 1, -1 do
        local p = pulls[i]
        if p.kill and not p.cut then
            out[1] = { Kit and Kit.Clock and Kit.Clock(p.dur or 0) or Count(p.dur), "last kill: " .. tostring(p.boss or "?") }
            break
        end
    end
    local runs = 0
    for _, inst in ipairs(L:GetInstances() or {}) do runs = runs + #(L:GetRuns(inst.key) or {}) end
    if runs > 0 then out[#out + 1] = { Count(runs), Plural(runs, "run logged", "runs logged") } end
    return out
end

FACTS.mybis = function()
    local B = ns.MyBiS
    local pr = B and B.GetProgress and B:GetProgress()
    if not pr or (tonumber(pr.total) or 0) <= 0 then return end
    local ph = B.GetPhase and B:GetPhase()
    return { { (pr.obtained or 0) .. "/" .. pr.total, ph == 0 and "obtained, pre-raid" or ("obtained, phase " .. tostring(ph or 1)) } }
end

FACTS.atlas = function()
    local n = ns.Shop and ns.Shop.Count and ns.Shop:Count() or 0
    if n > 0 then return { { Count(n), Plural(n, "item to get", "items to get") } } end
end

FACTS.members = function()
    local G = ns.Guild
    if not (G and G.GetMembers) then return end
    local all, on = G:GetMembers() or {}, 0
    for _, key in ipairs(all) do
        if G:IsOnline(key) then on = on + 1 end
    end
    return { { Count(on), "online now" }, { Count(#all), "characters" } }
end

FACTS.map = function()
    local M = ns.GuildMap
    if not (M and M.GetEntries) then return end
    if M.IsSharing and not M:IsSharing() and not Demo() then return { { "Off", "not sharing" } } end
    local n = 0
    for _ in pairs(M:GetEntries() or {}) do n = n + 1 end
    return { { Count(n), "on the map" } }
end

FACTS.events = function()
    local E = ns.Events
    if not (E and E.GetOccurrences) then return end
    local now = Now()
    for _, o in ipairs(E:GetOccurrences(now - 6 * 3600, now + 60 * 86400) or {}) do
        local st = E:OccState(o)
        if st == "planned" or st == "live" then
            local name = o.def and o.def.name or "Event"
            local n = #(E:GetSignups(o.id) or {})
            return { { st == "live" and "Live" or date("%a %H:%M", o.at), name }, { Count(n), "signed up" } }
        end
    end
    return { { "None", "planned yet" } }
end

FACTS.polls = function()
    local P = ns.Polls
    if not (P and P.GetPolls) then return end
    local out = {}
    local w = P.WaitingCount and P:WaitingCount() or 0
    if w > 0 then out[#out + 1] = { Count(w), Plural(w, "waits for you", "wait for you") } end
    local n = 0
    for _, p in ipairs(P:GetPolls() or {}) do
        if P:IsOpen(p) then n = n + 1 end
    end
    out[#out + 1] = { Count(n), Plural(n, "open poll", "open polls") }
    return out
end

FACTS.games = function()
    local out = {}
    if ns.Bingo and ns.Bingo.IsActive and ns.Bingo:IsActive() then out[#out + 1] = { "Live", "Bingo, this raid" } end
    local C = ns.Chess
    local n = C and C.MyTurnCount and C:MyTurnCount() or 0
    if n > 0 then out[#out + 1] = { Count(n), Plural(n, "chess game: your move", "chess games: your move") } end
    return out
end

function NavMenu:Facts(key)
    local out = Try(FACTS[key])
    if type(out) ~= "table" then out = {} end
    -- what waits for me on the page (the notification center's count) when the page has nothing of its own to say
    if #out == 0 then
        local N = ns.Notify
        local n = N and N.IsLoaded and N:IsLoaded() and Try(function() return N:Count({ page = key }) end) or 0
        if (tonumber(n) or 0) > 0 then out[1] = { Count(n), "new for you" } end
    end
    return out
end

function NavMenu:OpenView(key, view)
    if view and OPEN_VIEW[key] then Try(OPEN_VIEW[key], view) end
end

---------------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------------

local gradA = CreateColor and CreateColor(0, 0, 0, 0)
local gradB = CreateColor and CreateColor(0, 0, 0, 0)
local function Gradient(tex, orient, r1, g1, b1, a1, r2, g2, b2, a2)
    tex:SetTexture(WHITE8)
    if gradA and tex.SetGradient then
        gradA:SetRGBA(r1, g1, b1, a1)
        gradB:SetRGBA(r2, g2, b2, a2)
        tex:SetGradient(orient, gradA, gradB)
    else
        tex:SetVertexColor((r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2, (a1 + a2) / 2)
    end
end

local function Font(fs, size)
    local path, _, flags = fs:GetFont()
    fs:SetFont(path or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, flags or "")
end

local function Glyph(tex, index, c, a)
    tex:SetTexture(UI.ICON_ATLAS)
    local co = UI:IconCoords(index)
    tex:SetTexCoord(co[1], co[2], co[3], co[4])
    tex:SetVertexColor(c[1], c[2], c[3], a or 1)
end

-- A soft shadow round frame f: a 9-slice of the radial texture's falloff (as the Games hub's posters).
local SH_IN, SH_OUT = 0.5 - 0.125, 0.5 - 0.406
local function SoftShadow(f, r, alpha, dy, inset)
    local function piece(l, rr, t, b)
        local tex = f:CreateTexture(nil, "BACKGROUND", nil, -8)
        tex:SetTexture(RADIAL)
        tex:SetVertexColor(0, 0, 0, alpha)
        tex:SetTexCoord(l, rr, t, b)
        return tex
    end
    local m1, m2 = 0.499, 0.501
    local a, b, c, d = SH_OUT, SH_IN, 1 - SH_IN, 1 - SH_OUT
    local L, R, T, B = inset, -inset, -inset - dy, inset - dy
    local tl = piece(a, b, a, b)
    tl:SetPoint("BOTTOMRIGHT", f, "TOPLEFT", L, T)
    tl:SetSize(r, r)
    local tr = piece(c, d, a, b)
    tr:SetPoint("BOTTOMLEFT", f, "TOPRIGHT", R, T)
    tr:SetSize(r, r)
    local bl = piece(a, b, c, d)
    bl:SetPoint("TOPRIGHT", f, "BOTTOMLEFT", L, B)
    bl:SetSize(r, r)
    local br = piece(c, d, c, d)
    br:SetPoint("TOPLEFT", f, "BOTTOMRIGHT", R, B)
    br:SetSize(r, r)
    local top = piece(m1, m2, a, b)
    top:SetPoint("BOTTOMLEFT", tl, "BOTTOMRIGHT")
    top:SetPoint("TOPRIGHT", tr, "TOPLEFT")
    local bottom = piece(m1, m2, c, d)
    bottom:SetPoint("TOPLEFT", bl, "TOPRIGHT")
    bottom:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
    local left = piece(a, b, m1, m2)
    left:SetPoint("TOPRIGHT", tl, "BOTTOMRIGHT")
    left:SetPoint("BOTTOMLEFT", bl, "TOPLEFT")
    local right = piece(c, d, m1, m2)
    right:SetPoint("TOPLEFT", tr, "BOTTOMLEFT")
    right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
    local mid = piece(m1, m2, m1, m2)
    mid:SetPoint("TOPLEFT", tl, "BOTTOMRIGHT")
    mid:SetPoint("BOTTOMRIGHT", br, "TOPLEFT")
end

-- The loading screen's painting sits between 25% and 78.5% of the stored square, shown at 4:3: crop it to w x h
-- around cx, zoomed in by z (1 = the whole band's height) and nudged by dx (a share of the width).
local function CropArt(tex, w, h, cx, z, dx)
    if w <= 0 or h <= 0 then return end
    local fh = 0.535 / (z or 1)
    local fw = fh * 3 * w / (4 * h)
    if fw > 0.94 then fw, fh = 0.94, 0.94 * 4 * h / (3 * w) end
    local l = max(0.03, min(0.97 - fw, (cx or 0.5) - fw / 2 + (dx or 0) * fw))
    local t = 0.25 + (0.535 - fh) * 0.5
    tex:SetTexCoord(l, l + fw, t, t + fh)
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

local f              -- the panel
local open           -- { owner, spec, focus, pages = { key -> page } }
local Paint, PaintRows, FillSpot

local function NewRow(parent, i)
    local r = CreateFrame("Button", nil, parent)
    r:SetSize(RAIL_W, ROW_H)
    r:RegisterForClicks("LeftButtonUp")
    r.wash = r:CreateTexture(nil, "BACKGROUND")
    r.wash:SetAllPoints()
    Gradient(r.wash, "HORIZONTAL", 1, 0.82, 0, 0.16, 1, 0.82, 0, 0.02)
    r.hl = r:CreateTexture(nil, "BACKGROUND", nil, 1)
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.04)
    r.hl:Hide()
    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetPoint("TOPLEFT", 0, -4)
    r.bar:SetPoint("BOTTOMLEFT", 0, 4)
    r.bar:SetWidth(2)
    r.bar:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    r.glow = r:CreateTexture(nil, "ARTWORK", nil, -1)
    r.glow:SetTexture(RADIAL)
    r.glow:SetBlendMode("ADD")
    r.glow:SetVertexColor(1, 0.82, 0, 0.35)
    r.glow:SetPoint("CENTER", r.bar, "CENTER", 0, 0)
    r.glow:SetSize(14, ROW_H)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.icon:SetPoint("LEFT", 10, 0)
    r.icon:SetPoint("TOP", r, "TOP", 0, -8)
    r.fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    Font(r.fs, 13)
    r.fs:SetPoint("BOTTOMLEFT", r, "LEFT", 34, 0)
    r.fs:SetJustifyH("LEFT")
    r.fs:SetWordWrap(false)
    r.fs:SetShadowOffset(1, -1)
    -- (the page's first live fact, at a glance without hovering it)
    r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    Font(r.sub, 9.5)
    r.sub:SetPoint("TOPLEFT", r, "LEFT", 34, -3)
    r.sub:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    r.sub:SetJustifyH("LEFT")
    r.sub:SetWordWrap(false)
    r.count = UI:CreateCountBadge(r, 14)
    r.count:SetPoint("LEFT", r.fs, "RIGHT", 6, 0)
    r.pill = CreateFrame("Frame", nil, r)
    r.pill:SetHeight(11)
    if UI.AddPillShape then UI:AddPillShape(r.pill, 11) end
    r.pill.fs = r.pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    Font(r.pill.fs, 7.5)
    r.pill.fs:SetPoint("CENTER", 0.5, 0)
    r.pill:SetPoint("LEFT", r.fs, "RIGHT", 6, 0)
    r.pill:Hide()
    r:SetScript("OnEnter", function(self)
        self.hl:Show()
        if open and self.page then NavMenu:Focus(self.page.key) end
    end)
    r:SetScript("OnLeave", function(self) self.hl:Hide() end)
    r:SetScript("OnClick", function(self)
        if open and self.page then NavMenu:Pick(self.page.key) end
    end)
    return r
end

local function SetPill(r, badge)
    local p = r.pill
    if not badge then p:Hide() return end
    local c = badge.color or GOLD
    if p.SetPillColors then
        p:SetPillColors({ 0.1 + (c[1] - 0.1) * 0.16, 0.1 + (c[2] - 0.1) * 0.16, 0.12 + (c[3] - 0.12) * 0.16, 1 },
            { c[1], c[2], c[3], 0.5 })
    end
    p.fs:SetText(badge.text or "")
    p.fs:SetTextColor(c[1], c[2], c[3])
    p:SetWidth(floor((p.fs:GetStringWidth() or 18) + 8 + 0.5))
    p:Show()
end

local function NewChip(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(CHIP_H)
    UI:AddPillShape(c, CHIP_H)
    c.fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    Font(c.fs, 10)
    c.fs:SetPoint("CENTER", -3, 0)
    c.arrow = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    Font(c.arrow, 10)
    c.arrow:SetText("\226\128\186")     -- ›
    c.arrow:SetPoint("LEFT", c.fs, "RIGHT", 3, 0)
    function c:Paint()
        local on, hot = self.view and self.view.on, self.hot
        if on then
            self:SetPillColors({ 0.2, 0.17, 0.06, 1 }, { 1, 0.82, 0, hot and 0.9 or 0.6 })
            self.fs:SetTextColor(1, 0.82, 0)
        else
            self:SetPillColors(hot and { 0.17, 0.17, 0.19, 1 } or { 0.12, 0.12, 0.135, 1 },
                hot and { 1, 0.82, 0, 0.55 } or { 1, 1, 1, 0.16 })
            if hot then self.fs:SetTextColor(1, 1, 1) else self.fs:SetTextColor(0.81, 0.81, 0.83) end
        end
        self.arrow:SetTextColor(0.47, 0.47, 0.49)
    end
    c:SetScript("OnEnter", function(self) self.hot = true self:Paint() end)
    c:SetScript("OnLeave", function(self) self.hot = false self:Paint() end)
    c:SetScript("OnClick", function(self)
        if open and self.key then NavMenu:Pick(self.key, self.view and self.view.key) end
    end)
    return c
end

local function NewFact(parent)
    local b = CreateFrame("Frame", nil, parent)
    b:SetHeight(FACT_H)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0.114, 0.114, 0.13, 1)
    UI:AddEdges(b, "BORDER")
    UI:SetEdgeColor(b, 1, 1, 1, 0.07)
    b.value = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    Font(b.value, 15)
    b.value:SetPoint("TOPLEFT", 9, -8)
    b.value:SetPoint("RIGHT", -8, 0)
    b.value:SetJustifyH("LEFT")
    b.value:SetWordWrap(false)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    Font(b.label, 9.5)
    b.label:SetPoint("TOPLEFT", b.value, "BOTTOMLEFT", 0, -5)
    b.label:SetPoint("RIGHT", -8, 0)
    b.label:SetJustifyH("LEFT")
    b.label:SetWordWrap(false)
    b.label:SetTextColor(0.56, 0.56, 0.59)
    return b
end

local function Build(parent)
    local p = CreateFrame("Frame", "DisasterZoneNavMenu", parent)
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:SetToplevel(true)
    p:EnableMouse(true)
    p:SetClampedToScreen(true)
    p:Hide()
    SoftShadow(p, 40, 0.5, 12, 8)
    SoftShadow(p, 10, 0.35, 2, 2)
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    Gradient(p.bg, "VERTICAL", 0.07, 0.07, 0.08, 0.985, 0.106, 0.106, 0.122, 0.985)
    UI:AddEdges(p, "BORDER")
    UI:SetEdgeColor(p, 0.23, 0.23, 0.25, 1)
    -- the tie: a gold piece on the top edge under the tab, fading out to both sides
    p.tie = p:CreateTexture(nil, "OVERLAY", nil, 2)
    p.tie:SetSize(TIE_W, 2)
    p.tie:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    p.tieGlow = p:CreateTexture(nil, "OVERLAY", nil, 1)
    p.tieGlow:SetTexture(RADIAL)
    p.tieGlow:SetBlendMode("ADD")
    p.tieGlow:SetVertexColor(1, 0.82, 0, 0.45)
    p.tieGlow:SetSize(TIE_W + 24, 14)
    p.tieGlow:SetPoint("CENTER", p.tie, "CENTER")
    p.tieL = p:CreateTexture(nil, "OVERLAY", nil, 1)
    p.tieL:SetSize(110, 1)
    p.tieL:SetPoint("RIGHT", p.tie, "LEFT", 0, 0.5)
    Gradient(p.tieL, "HORIZONTAL", 1, 0.82, 0, 0, 1, 0.82, 0, 0.55)
    p.tieR = p:CreateTexture(nil, "OVERLAY", nil, 1)
    p.tieR:SetSize(110, 1)
    p.tieR:SetPoint("LEFT", p.tie, "RIGHT", 0, 0.5)
    Gradient(p.tieR, "HORIZONTAL", 1, 0.82, 0, 0.55, 1, 0.82, 0, 0)

    p.rows = {}
    -- the spotlight
    local s = CreateFrame("Frame", nil, p)
    s:SetWidth(SPOT_W)
    s:SetPoint("TOPLEFT", PAD + RAIL_W + GAP, -PAD)
    s.bg = s:CreateTexture(nil, "BACKGROUND")
    s.bg:SetAllPoints()
    s.bg:SetColorTexture(0.086, 0.086, 0.098, 1)
    UI:AddEdges(s, "OVERLAY")
    UI:SetEdgeColor(s, 1, 1, 1, 0.09)
    -- (the words and art fade together on a swap; the frame and its edges stay)
    s.body = CreateFrame("Frame", nil, s)
    s.body:SetAllPoints()
    local artBtn = CreateFrame("Button", nil, s.body)
    artBtn:SetPoint("TOPLEFT", 1, -1)
    artBtn:SetPoint("TOPRIGHT", -1, -1)
    artBtn:SetHeight(ART_H)
    artBtn:SetScript("OnClick", function() if open and open.focus then NavMenu:Pick(open.focus) end end)
    s.artBtn = artBtn
    s.art = artBtn:CreateTexture(nil, "BACKGROUND")
    s.art:SetAllPoints()
    s.shadeB = artBtn:CreateTexture(nil, "BORDER")
    s.shadeB:SetPoint("BOTTOMLEFT")
    s.shadeB:SetPoint("BOTTOMRIGHT")
    s.shadeB:SetHeight(ART_H * 0.8)
    Gradient(s.shadeB, "VERTICAL", 0.055, 0.055, 0.063, 0.94, 0.055, 0.055, 0.063, 0)
    s.shadeL = artBtn:CreateTexture(nil, "BORDER", nil, 1)
    s.shadeL:SetPoint("TOPLEFT")
    s.shadeL:SetPoint("BOTTOMLEFT")
    s.shadeL:SetWidth(SPOT_W * 0.6)
    Gradient(s.shadeL, "HORIZONTAL", 0, 0, 0, 0.35, 0, 0, 0, 0)
    -- the icon in its ring (a dark disc, the events' metal ring tinted gold, a soft gold glow behind)
    local ring = CreateFrame("Frame", nil, artBtn)
    ring:SetSize(38, 38)
    ring:SetPoint("BOTTOMLEFT", 12, 10)
    ring.glow = ring:CreateTexture(nil, "BACKGROUND")
    ring.glow:SetTexture(RADIAL)
    ring.glow:SetBlendMode("ADD")
    ring.glow:SetSize(70, 70)
    ring.glow:SetPoint("CENTER")
    ring.disc = ring:CreateTexture(nil, "ARTWORK")
    ring.disc:SetTexture(WHITE8)
    ring.disc:SetVertexColor(0.07, 0.07, 0.08, 1)
    ring.disc:SetPoint("CENTER")
    ring.disc:SetSize(34, 34)
    if ring.CreateMaskTexture then
        ring.mask = ring:CreateMaskTexture()
        ring.mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        ring.mask:SetAllPoints(ring.disc)
        ring.disc:AddMaskTexture(ring.mask)
    end
    ring.ring = ring:CreateTexture(nil, "OVERLAY")
    ring.ring:SetTexture(RING)
    ring.ring:SetAllPoints()
    ring.icon = ring:CreateTexture(nil, "OVERLAY", nil, 1)
    ring.icon:SetSize(20, 20)
    ring.icon:SetPoint("CENTER")
    s.ring = ring
    s.name = artBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    Font(s.name, 19)
    s.name:SetPoint("BOTTOMLEFT", 0, 0)   -- (placed over the line, FillSpot)
    s.name:SetJustifyH("LEFT")
    s.name:SetWordWrap(false)
    s.name:SetShadowOffset(1, -1)
    s.count = UI:CreateCountBadge(artBtn, 14)
    s.count:SetPoint("LEFT", s.name, "RIGHT", 7, 0)
    s.pill = CreateFrame("Frame", nil, artBtn)
    s.pill:SetHeight(12)
    if UI.AddPillShape then UI:AddPillShape(s.pill, 12) end
    s.pill.fs = s.pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    Font(s.pill.fs, 8)
    s.pill.fs:SetPoint("CENTER", 0.5, 0)
    s.pill:SetPoint("LEFT", s.name, "RIGHT", 7, 0)
    s.line = artBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    Font(s.line, 10)
    s.line:SetPoint("BOTTOMLEFT", ring, "BOTTOMRIGHT", 10, 3)
    s.line:SetWidth(SPOT_W - 2 - 12 - 38 - 10 - 12)
    s.line:SetJustifyH("LEFT")
    s.line:SetJustifyV("BOTTOM")
    s.line:SetWordWrap(true)
    if s.line.SetMaxLines then s.line:SetMaxLines(2) end
    s.name:ClearAllPoints()
    s.name:SetPoint("BOTTOMLEFT", s.line, "TOPLEFT", 0, 3)
    s.line:SetTextColor(0.79, 0.79, 0.8)
    s.line:SetShadowOffset(1, -1)
    s.facts = { NewFact(s.body), NewFact(s.body) }
    s.chips = {}
    p.spot = s

    -- motion: the swap's crossfade, the art's slow drift (zoom in and back, a small pan with it)
    p.t, p.swapT = 0, nil
    p:SetScript("OnUpdate", function(self, elapsed)
        elapsed = elapsed or 0
        self.t = self.t + elapsed
        if self.swapT then
            self.swapT = self.swapT + elapsed
            local e = min(1, self.swapT / SWAP_TIME)
            e = 1 - (1 - e) * (1 - e)
            s.body:SetAlpha(0.15 + 0.85 * e)
            if e >= 1 then self.swapT = nil end
        end
        local k = 0.5 - 0.5 * math.cos(self.t * pi / DRIFT_TIME)     -- 0 .. 1 .. 0, eased at both ends
        if self.artInfo then
            CropArt(s.art, SPOT_W - 2, ART_H, self.artInfo.cx, 1.03 + 0.10 * k, -0.05 * k)
        end
        -- the owner hiding closes it
        local o = open and open.owner
        if o and o.IsVisible and not o:IsVisible() then NavMenu:Close() end
    end)
    p:SetScript("OnShow", function(self)
        if C_EventUtils == nil or not C_EventUtils.IsEventValid or C_EventUtils.IsEventValid("GLOBAL_MOUSE_DOWN") then
            self:RegisterEvent("GLOBAL_MOUSE_DOWN")
        end
        if not InCombatLockdown() then
            self:EnableKeyboard(true)
            self:SetPropagateKeyboardInput(true)
        end
    end)
    p:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        if not InCombatLockdown() then self:EnableKeyboard(false) end
        if open then NavMenu:Close() end
    end)
    p:SetScript("OnKeyDown", function(self, key)
        if key ~= "ESCAPE" then return end
        if not InCombatLockdown() then self:SetPropagateKeyboardInput(false) end
        NavMenu:Close()
    end)
    p:SetScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" or not open then return end
        if self:IsMouseOver() then return end
        local o = open.owner
        if o and o:IsVisible() and o:IsMouseOver() then return end    -- (the tab's own click keeps it)
        NavMenu:Close()
    end)
    return p
end

-- The rows' look: the spotlit one gold-washed with its bar, the page shown now in gold.
PaintRows = function()
    for _, r in ipairs(f.rows) do
        local pg = r.page
        if pg then
            local lit = pg.key == open.focus
            local cur = pg.key == open.spec.current
            r.wash:SetShown(lit)
            r.bar:SetShown(lit)
            r.glow:SetShown(lit)
            local info = INFO[pg.key] or DEFAULT_INFO
            Glyph(r.icon, IconIndex(info.icon), lit and GOLD or (cur and GOLD) or { 0.78, 0.78, 0.8 })
            if lit then r.sub:SetTextColor(0.72, 0.72, 0.75) else r.sub:SetTextColor(0.5, 0.5, 0.53) end
            if cur then r.fs:SetTextColor(1, 0.82, 0)
            elseif lit then r.fs:SetTextColor(1, 1, 1)
            else r.fs:SetTextColor(0.77, 0.77, 0.78) end
        end
    end
end

-- The spotlight's words and art for page pg; returns its height.
FillSpot = function(pg)
    local s = f.spot
    local info = INFO[pg.key] or DEFAULT_INFO
    f.artInfo = info
    s.art:SetTexture(info.art)
    CropArt(s.art, SPOT_W - 2, ART_H, info.cx, 1.03, 0)
    local a = info.accent or GOLD
    s.ring.glow:SetVertexColor(a[1], a[2], a[3], 0.32)
    s.ring.ring:SetVertexColor(1, 0.84, 0.36)
    Glyph(s.ring.icon, IconIndex(info.icon), GOLD)
    s.name:SetText(pg.label or pg.key)
    s.name:SetTextColor(1, 1, 1)
    s.line:SetText(pg.line or "")
    if (tonumber(pg.count) or 0) > 0 then
        s.count:SetCount(pg.count)
        s.pill:Hide()
    else
        s.count:Hide()
        local b = pg.badge
        if b then
            local c = b.color or GOLD
            if s.pill.SetPillColors then
                s.pill:SetPillColors({ 0.1 + (c[1] - 0.1) * 0.2, 0.1 + (c[2] - 0.1) * 0.2, 0.12 + (c[3] - 0.12) * 0.2, 1 },
                    { c[1], c[2], c[3], 0.6 })
            end
            s.pill.fs:SetText(b.text or "")
            s.pill.fs:SetTextColor(c[1], c[2], c[3])
            s.pill:SetWidth(floor((s.pill.fs:GetStringWidth() or 18) + 9 + 0.5))
            s.pill:Show()
        else
            s.pill:Hide()
        end
    end
    local y = ART_H + 1
    -- facts
    local facts = open.facts[pg.key] or NavMenu:Facts(pg.key)
    open.facts[pg.key] = facts
    local n = min(2, #facts)
    local fw = n > 0 and floor((SPOT_W - 24 - (n - 1) * 6) / n) or 0
    for i, b in ipairs(s.facts) do
        local fact = facts[i]
        if i <= n and fact then
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", s, "TOPLEFT", 12 + (i - 1) * (fw + 6), -(y + 10))
            b:SetWidth(fw)
            b.value:SetText(tostring(fact[1] or ""))
            b.value:SetTextColor(a[1], a[2], a[3])
            b.label:SetText(tostring(fact[2] or ""))
            b:Show()
        else
            b:Hide()
        end
    end
    if n > 0 then y = y + 10 + FACT_H end
    -- jumps into the page's views, wrapped onto as many rows as they need
    local views = Try(VIEWS[pg.key]) or {}
    local x, rowsUsed = 12, 0
    local maxX = SPOT_W - 12
    for i, v in ipairs(views) do
        local c = s.chips[i] or NewChip(s.body)
        s.chips[i] = c
        c.key, c.view, c.hot = pg.key, v, false
        c.fs:SetText(v.label or v.key)
        local w = floor((c.fs:GetStringWidth() or 30) + 26 + 0.5)
        c:SetWidth(w)
        if rowsUsed == 0 or x + w > maxX then
            rowsUsed = rowsUsed + 1
            x = 12
        end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", s, "TOPLEFT", x, -(y + 10 + (rowsUsed - 1) * (CHIP_H + CHIP_GAP)))
        x = x + w + CHIP_GAP
        c:Paint()
        c:Show()
    end
    for i = #views + 1, #s.chips do s.chips[i]:Hide() end
    if rowsUsed > 0 then y = y + 10 + rowsUsed * CHIP_H + (rowsUsed - 1) * CHIP_GAP end
    return y + 12
end

-- Lays the panel out for open.spec: the rows, the spotlight, the size, the tie under the owner.
Paint = function()
    local spec = open.spec
    for i, pg in ipairs(spec.pages) do
        local r = f.rows[i] or NewRow(f, i)
        f.rows[i] = r
        r.page = pg
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(PAD + (i - 1) * (ROW_H + ROW_GAP)))
        r.fs:SetText(pg.label or pg.key)
        local facts = NavMenu:Facts(pg.key)
        open.facts[pg.key] = facts
        local first = facts[1]
        r.sub:SetText(first and ("|cffd2d2d6%s|r  %s"):format(tostring(first[1]), tostring(first[2] or "")) or "")
        if (tonumber(pg.count) or 0) > 0 then
            r.count:SetCount(pg.count)
            r.pill:Hide()
        else
            r.count:Hide()
            SetPill(r, pg.badge)
        end
        r:Show()
    end
    for i = #spec.pages + 1, #f.rows do
        f.rows[i]:Hide()
        f.rows[i].page = nil
    end
    PaintRows()
    local railH = #spec.pages * ROW_H + max(0, #spec.pages - 1) * ROW_GAP
    -- the spotlight keeps the tallest page's height, so moving down the list never makes the panel jump
    local h = 0
    for _, pg in ipairs(spec.pages) do
        if pg.key ~= open.focus then h = max(h, FillSpot(pg)) end
    end
    h = max(h, FillSpot(open.pages[open.focus]))
    f.spot:SetHeight(h)
    f:SetSize(PAD + RAIL_W + GAP + SPOT_W + PAD, PAD + max(railH, h) + PAD)
end

local function Place(x, y)
    local o = open and open.owner
    if not o then return end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", o, "BOTTOMLEFT", -10 + (open.shift or 0) + x, -UI.DROP_GAP + y)
end

---------------------------------------------------------------------------
-- The calls
---------------------------------------------------------------------------

function NavMenu:Open(owner, spec)
    if not owner or type(spec) ~= "table" or type(spec.pages) ~= "table" or #spec.pages == 0 then return nil end
    if UI.CloseMenus then UI:CloseMenus() end
    if open and open.owner ~= owner then self:Close() end
    f = f or Build(UIParent)
    local pages = {}
    for _, pg in ipairs(spec.pages) do pages[pg.key] = pg end
    local again = open and open.owner == owner
    local focus = (again and pages[open.focus] and open.focus) or (pages[spec.focus] and spec.focus)
        or (pages[spec.current] and spec.current) or spec.pages[1].key
    open = { owner = owner, spec = spec, pages = pages, focus = focus, facts = {} }
    f:SetScale((owner:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1))
    Paint()
    -- keep it inside the owner's window (shift left when it would pass the window's right edge)
    local win = owner.GetParent and owner:GetParent()
    while win and win.GetParent and win:GetParent() and win:GetParent() ~= UIParent do win = win:GetParent() end
    open.shift = 0
    local ol, wr = owner:GetLeft(), win and win.GetRight and win:GetRight()
    if ol and wr and wr > 0 then
        local over = (ol - 10) + f:GetWidth() - (wr - 6)
        if over > 0 then open.shift = -over end
    end
    -- the tie under the tab's middle
    local ow = owner:GetWidth() or 0
    local line = owner.line
    local cx = 10 - (open.shift or 0) + ow / 2
    if line and line.GetCenter and owner.GetCenter then
        local lx, ox = line:GetCenter(), owner:GetCenter()
        if lx and ox then cx = cx + (lx - ox) end
    end
    -- (the tie and its fading lines stay on the panel's top edge: never past its corners, out of the window)
    local pw = f:GetWidth() or 0
    cx = max(TIE_W / 2 + 1, min(pw - TIE_W / 2 - 1, cx))
    f.tie:ClearAllPoints()
    f.tie:SetPoint("CENTER", f, "TOPLEFT", cx, -1)
    local lw, rw = min(110, cx - TIE_W / 2 - 1), min(110, pw - cx - TIE_W / 2 - 1)
    f.tieL:SetWidth(max(1, lw))
    f.tieL:SetShown(lw >= 1)
    f.tieR:SetWidth(max(1, rw))
    f.tieR:SetShown(rw >= 1)
    if again and f:IsShown() then
        Place(0, 0)
        return open
    end
    f.t = 0
    f.swapT = nil
    f.spot.body:SetAlpha(1)
    f:Show()
    f:Raise()
    UI:DropIn(f, Place, 0, UI.DROP_FALL)
    if owner.OnMenuShown then owner:OnMenuShown(true) end
    if owner.SetLit then owner:SetLit(true) end
    return open
end

function NavMenu:Close()
    local o = open
    if not o then return end
    open = nil
    if f and f:IsShown() then f:Hide() end
    if o.owner then
        if o.owner.OnMenuShown then o.owner:OnMenuShown(false) end
        if o.owner.SetLit then o.owner:SetLit(false) end
    end
end

-- Spotlights page key (the mouse on its row; tests and the audit).
function NavMenu:Focus(key)
    if not open or not open.pages[key] or open.focus == key then return end
    open.focus = key
    PaintRows()
    FillSpot(open.pages[key])
    f.swapT = 0
    f.spot.body:SetAlpha(0.15)
end

-- Opens page key (and its view), then closes.
function NavMenu:Pick(key, view)
    local o = open
    if not o then return end
    self:Close()
    if o.spec.onPick then Try(o.spec.onPick, key, view) end
end

function NavMenu:IsOpenFor(owner) return open ~= nil and open.owner == owner end
function NavMenu:IsOpen() return open ~= nil end
function NavMenu:IsMouseOver() return f ~= nil and f:IsShown() and f:IsMouseOver() or false end
function NavMenu:GetFrame() return f end
function NavMenu:GetFocus() return open and open.focus end

-- The open menu's page labels in order ({} when closed): tests.
function NavMenu:GetPages()
    local out = {}
    if open then
        for _, pg in ipairs(open.spec.pages) do out[#out + 1] = pg.label end
    end
    return out
end
