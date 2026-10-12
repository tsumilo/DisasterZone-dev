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
local S = ns.Style

local floor, min, max, sin, pi = math.floor, math.min, math.max, math.sin, math.pi

local PAD, GAP = 8, 8
local RAIL_W, ROW_H, ROW_GAP = 160, 42, 2
local SPOT_W, ART_H = 330, 128
local FACT_H, CHIP_H, CHIP_GAP = 46, 18, 4
local TIE_W = 44
local SWAP_TIME = 0.22          -- the spotlight's crossfade
local DRIFT_TIME = 9            -- seconds: the art's slow zoom one way (then back)
local MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"
local RADIAL = MEDIA .. "MyBiS\\Radial"
local LS = "Interface\\Glues\\LoadingScreens\\LoadScreen"

local Now = ns.Util.Now

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
    raids   = { art = 131826, cx = 0.40, icon = "calendar", accent = S.C.GOLD },
    council = { art = 131849, cx = 0.22, icon = "crown", accent = { 0.77, 0.55, 1 } },
    lootrules = { art = 131826, cx = 0.40, icon = "ballot", accent = S.C.GOLD },
    mylog   = { art = 131842, cx = 0.42, icon = "practice", accent = { 0.37, 0.82, 1 } },
    mybis   = { art = 131846, cx = 0.50, icon = "bag", accent = S.C.GOLD },
    gearsim = { art = 131873, cx = 0.55, icon = "chart", accent = { 1, 0.55, 0.25 } },
    consumables = { art = 131847, cx = 0.45, icon = "flask", accent = { 0.53, 0.85, 0.42 } },
    atlas   = { art = LS .. "Outland", cx = 0.50, icon = "eye", accent = { 0.53, 0.85, 0.42 } },
    members = { art = LS .. "EasternKingdom", cx = 0.50, icon = "team", accent = S.C.GOLD },
    map     = { art = LS .. "Kalimdor", cx = 0.55, icon = "flag", accent = { 0.37, 0.82, 1 } },
    events  = { art = LS .. "NagrandArenaBattlegrounds", cx = 0.50, icon = "trophy", accent = { 0.73, 0.55, 1 } },
    polls   = { art = LS .. "WarsongGulch", cx = 0.50, icon = "poll", accent = S.C.GOLD },
    games   = { art = 131849, cx = 0.70, icon = "games", accent = { 0.31, 0.83, 0.88 } },
}
local DEFAULT_INFO = { art = LS .. "Outland", cx = 0.5, icon = "notes", accent = S.C.GOLD }
NavMenu.INFO = INFO

local function IconIndex(name)
    local I = UI.ICON
    -- (art pack 6 icons: their stand-ins before it)
    if not (ns.HasAssets and ns:HasAssets(6)) then
        name = ({ poll = "notes", chart = "notes", flask = "bag" })[name] or name
    end
    -- (art pack 7: the ballot box of Raids > Loot rules)
    if name == "ballot" and not (ns.HasAssets and ns:HasAssets(7)) then name = (ns.HasAssets and ns:HasAssets(6)) and "poll" or "notes" end
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
                      { key = "log", label = "Loot log" }, { key = "council", label = "Loot council" },
                      { key = "rules", label = "Rules" } }
        for _, v in ipairs(out) do v.on = v.key == cur end
        return out
    end,
    lootrules = function()
        local L = ns.LootRulesUI
        local cur = L and L.GetView and L:GetView()
        return { { key = "decided", label = "How it's decided", on = cur == "decided" },
                 { key = "prized", label = "Prized items", on = cur == "prized" } }
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
    lootrules = function(v) ns.LootRulesUI:SetView(v) end,
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
        if not v.cancelled and not (RP.IsRaidHidden and RP:IsRaidHidden(v)) then
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

-- Raids > Loot rules: the prized items (and how many I qualify for), the guild's order before votes.
FACTS.lootrules = function()
    local out = {}
    local P = ns.Prized
    local items = P and P.GetItems and P:GetItems() or {}
    if #items > 0 then
        local ok, me = 0, ns.Util.PlayerKey()
        for _, it in ipairs(items) do
            if P:Check(it, me).ok == true then ok = ok + 1 end
        end
        out[#out + 1] = { Count(#items), Plural(#items, "prized item", "prized items") .. ", " .. ok .. " you qualify for" }
    end
    local G = ns.Guild
    local R = G and G.GetLootRules and G:GetLootRules()
    if R then out[#out + 1] = { R.l ~= "r" and "Lists" or "Roll", R.l ~= "r" and "first, then the roll" or "decides before votes" } end
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

FACTS.gearsim = function()
    local S = ns.SimPanel
    local res = S and S.GetResults and S:GetResults()
    if not (res and res.ref and (tonumber(res.ref.dps) or 0) > 0) then return end
    local d = floor((tonumber(res.diff) or 0) + 0.5)
    return { { (d >= 0 and "+" or "^f") .. math.abs(d) .. " DPS", "Working set vs " .. S:TargetText(res.target) } }
end

FACTS.consumables = function()
    local K = ns.Kit
    local rows = K and K.Get and K:Get()
    if not rows then return end
    local s = K:Summary(rows, "best")
    if (s.slots or 0) <= 0 then return end
    if s.ready >= s.slots then return { { "Ready", "for tonight" } } end
    return { { s.ready .. "/" .. s.slots, "in your bags" } }
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

-- An atlas glyph (UI.ICON index) on tex, tinted c (a Style token name or { r, g, b }).
local function Glyph(tex, index, c, a)
    tex:SetTexture(UI.ICON_ATLAS)
    local co = UI:IconCoords(index)
    tex:SetTexCoord(co[1], co[2], co[3], co[4])
    local r, g, b = S:Color(c)
    tex:SetVertexColor(r, g, b, a or 1)
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

-- A badge's pill kind ({ text, kind } from MainFrame's NAV_BADGES; "mute" without one).
local function BadgeKind(badge) return badge and badge.kind or "mute" end

---------------------------------------------------------------------------
-- The panel: the pages' list on the left (rows with the shared picked / hover look), the spotlight on the right (a
-- page banner over the facts as inset cards and the views as chips)
---------------------------------------------------------------------------

local f              -- the panel
local open           -- { owner, spec, focus, pages = { key -> page } }
local Paint, PaintRows, FillSpot

local function NewRow(parent, i)
    local r = CreateFrame("Button", nil, parent)
    r:SetSize(RAIL_W, ROW_H)
    r:RegisterForClicks("LeftButtonUp")
    UI:DecorateRow(r, { selectable = true })      -- (the spotlit one: the gold wash and the 2 px bar)
    r.bar = r.dzSelBar
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.icon:SetPoint("LEFT", 10, 0)
    r.icon:SetPoint("TOP", r, "TOP", 0, -8)
    r.fs = UI:Text(r, "title", "TEXT", { shadow = true })
    r.fs:SetPoint("BOTTOMLEFT", r, "LEFT", 34, 0)
    -- (the page's first live fact, at a glance without hovering it)
    r.sub = UI:Text(r, "caps", "DIM")
    r.sub:SetPoint("TOPLEFT", r, "LEFT", 34, -3)
    r.sub:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    r.count = UI:CreateCountBadge(r, 14)
    r.count:SetPoint("LEFT", r.fs, "RIGHT", 6, 0)
    r.pill = UI:CreatePill(r, nil, nil, 12)
    r.pill:SetPoint("LEFT", r.fs, "RIGHT", 6, 0)
    r.pill:Hide()
    r:SetScript("OnEnter", function(self)
        if open and self.page then NavMenu:Focus(self.page.key) end
    end)
    r:SetScript("OnClick", function(self)
        if open and self.page then NavMenu:Pick(self.page.key) end
    end)
    return r
end

local function SetPill(p, badge)
    if not badge then p:Hide() return end
    p:SetPill(BadgeKind(badge), badge.text or "")
    p:Show()
end

-- A click on a view's chip: open the page on that view.
local function PickView(c)
    if open and c.key then NavMenu:Pick(c.key, c.view and c.view.key) end
end

-- A live fact: an inset card with the value big in the page's accent and its label under it.
local function NewFact(parent)
    local b = UI:CreateCard(parent, { tone = "inset", pad = 0, height = FACT_H })
    b.body:Hide()
    b.value = UI:Text(b, "title")
    b.value:SetPoint("TOPLEFT", 9, -8)
    b.value:SetPoint("RIGHT", -8, 0)
    b.label = UI:Text(b, "caps", "SUB")
    b.label:SetPoint("TOPLEFT", b.value, "BOTTOMLEFT", 0, -6)
    b.label:SetPoint("RIGHT", -8, 0)
    return b
end

local function Build(parent)
    local p = CreateFrame("Frame", "DisasterZoneNavMenu", parent)
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:SetToplevel(true)
    p:EnableMouse(true)
    p:SetClampedToScreen(true)
    p:Hide()
    -- a dropdown's surface (UI.DROP_BG / DROP_EDGE, the menus' own) with the windows' soft shadow
    UI:SoftShadow(p, 40, 0.5, 12, 8)
    UI:SoftShadow(p, 10, 0.35, 2, 2)
    p.bg = UI:Fill(p, "DROP_BG")
    UI:AddEdges(p, "BORDER")
    UI:SetEdgeColor(p, S:Color("DROP_EDGE"))
    -- the tie: a gold piece on the top edge under the tab, fading out to both sides
    local gold, goldA, gold0 = S.C.GOLD, { S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], 0.55 },
        { S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], 0 }
    p.tie = p:CreateTexture(nil, "OVERLAY", nil, 2)
    p.tie:SetSize(TIE_W, 2)
    p.tie:SetColorTexture(gold[1], gold[2], gold[3], 1)
    p.tieGlow = p:CreateTexture(nil, "OVERLAY", nil, 1)
    p.tieGlow:SetTexture(RADIAL)
    p.tieGlow:SetBlendMode("ADD")
    p.tieGlow:SetVertexColor(gold[1], gold[2], gold[3], 0.45)
    p.tieGlow:SetSize(TIE_W + 24, 14)
    p.tieGlow:SetPoint("CENTER", p.tie, "CENTER")
    p.tieL = p:CreateTexture(nil, "OVERLAY", nil, 1)
    p.tieL:SetSize(110, 1)
    p.tieL:SetPoint("RIGHT", p.tie, "LEFT", 0, 0.5)
    UI:Gradient(p.tieL, "HORIZONTAL", gold0, goldA)
    p.tieR = p:CreateTexture(nil, "OVERLAY", nil, 1)
    p.tieR:SetSize(110, 1)
    p.tieR:SetPoint("LEFT", p.tie, "RIGHT", 0, 0.5)
    UI:Gradient(p.tieR, "HORIZONTAL", goldA, gold0)

    p.rows = {}
    -- the spotlight: an inset card; its banner, facts and views fade together on a swap (the card stays)
    local s = UI:CreateCard(p, { tone = "inset", pad = 0 })
    s:SetWidth(SPOT_W)
    s:SetPoint("TOPLEFT", PAD + RAIL_W + GAP, -PAD)
    -- the page as a banner (UI:CreatePageBanner): its loading screen drifting slowly, its icon in the gold ring,
    -- its name (and count or badge) and its line; a click on it opens the page
    local b = UI:CreatePageBanner(s.body, { size = ART_H, width = SPOT_W, icon = UI.ICON.notes, title = "", artFw = 1 })
    b:SetPoint("TOPLEFT", 0, 0)
    b:SetPoint("TOPRIGHT", 0, 0)
    b:EnableMouse(true)
    b:SetScript("OnMouseUp", function() if open and open.focus then NavMenu:Pick(open.focus) end end)
    b.sub:SetWordWrap(true)
    if b.sub.SetMaxLines then b.sub:SetMaxLines(2) end
    s.banner, s.artBtn, s.art = b, b, b.art
    s.name, s.line, s.pill = b.title, b.sub, b.pill
    s.ring = b.icon
    s.count = UI:CreateCountBadge(b, 14)
    s.count:SetPoint("LEFT", b.title, "RIGHT", 7, 0)
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
            CropArt(s.art, SPOT_W - 2, ART_H - 2, self.artInfo.cx, 1.03 + 0.10 * k, -0.05 * k)
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

-- The rows' look: the spotlit one picked (gold wash, its bar), the page shown now in gold.
PaintRows = function()
    for _, r in ipairs(f.rows) do
        local pg = r.page
        if pg then
            local lit = pg.key == open.focus
            local cur = pg.key == open.spec.current
            r:SetSelected(lit)
            local info = INFO[pg.key] or DEFAULT_INFO
            Glyph(r.icon, IconIndex(info.icon), (lit or cur) and "GOLD" or "SUB")
            r.sub:SetTextColor(S:Color(lit and "SUB" or "DIM"))
            r.fs:SetTextColor(S:Color(cur and "GOLD" or "TEXT"))
        end
    end
end

-- The spotlight's words and art for page pg; returns its height.
FillSpot = function(pg)
    local s = f.spot
    local b = s.banner
    local info = INFO[pg.key] or DEFAULT_INFO
    f.artInfo = info
    -- (a glyph, not a picture: smaller, gold, on the tile's dark ground)
    b:SetIcon(IconIndex(info.icon), { glyph = "GOLD", glyphSize = 26 })
    b:SetTitle(pg.label or pg.key)
    b:SetSub(pg.line or "")
    if (tonumber(pg.count) or 0) > 0 then
        b:SetPill(nil)
        s.count:SetCount(pg.count)
    else
        s.count:Hide()
        local badge = pg.badge
        b:SetPill(badge and BadgeKind(badge) or nil, badge and badge.text or nil)
    end
    -- (the art last: SetArt lays the banner out, the drift crops it from here on)
    b:SetArt({ info.art, 0, 1, 0, 1 })
    CropArt(b.art, SPOT_W - 2, ART_H - 2, info.cx, 1.03, 0)
    local a = info.accent or S.C.GOLD
    local y = ART_H
    -- facts
    local facts = open.facts[pg.key] or NavMenu:Facts(pg.key)
    open.facts[pg.key] = facts
    local n = min(2, #facts)
    local fw = n > 0 and floor((SPOT_W - 2 * S.PAD - (n - 1) * 6) / n) or 0
    for i, box in ipairs(s.facts) do
        local fact = facts[i]
        if i <= n and fact then
            box:ClearAllPoints()
            box:SetPoint("TOPLEFT", s, "TOPLEFT", S.PAD + (i - 1) * (fw + 6), -(y + S.PAD))
            box:SetWidth(fw)
            box.value:SetText(tostring(fact[1] or ""))
            box.value:SetTextColor(a[1], a[2], a[3])
            box.label:SetText(UI:CapsText(tostring(fact[2] or "")))
            box:Show()
        else
            box:Hide()
        end
    end
    if n > 0 then y = y + S.PAD + FACT_H end
    -- jumps into the page's views, wrapped onto as many rows as they need
    local views = Try(VIEWS[pg.key]) or {}
    local x, rowsUsed = S.PAD, 0
    local maxX = SPOT_W - S.PAD
    for i, v in ipairs(views) do
        -- (a jump into one of the page's views: a chip, gold while it is the view shown now)
        local c = s.chips[i] or UI:CreateChip(s.body, { kind = "track", onClick = PickView })
        s.chips[i] = c
        c.key, c.view = pg.key, v
        c:Set(v.label or v.key)
        c:SetSelected(v.on and true or false)
        local w = c:GetWidth()
        if rowsUsed == 0 or x + w > maxX then
            rowsUsed = rowsUsed + 1
            x = S.PAD
        end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", s, "TOPLEFT", x, -(y + S.PAD + (rowsUsed - 1) * (CHIP_H + CHIP_GAP)))
        x = x + w + CHIP_GAP
        c:Show()
    end
    UI:HideFrom(s.chips, #views + 1)
    if rowsUsed > 0 then y = y + S.PAD + rowsUsed * CHIP_H + (rowsUsed - 1) * CHIP_GAP end
    return y + S.PAD + 2
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
        r.sub:SetText(first and (S:Wrap("TEXT", tostring(first[1])) .. "  " .. tostring(first[2] or "")) or "")
        if (tonumber(pg.count) or 0) > 0 then
            r.count:SetCount(pg.count)
            r.pill:Hide()
        else
            r.count:Hide()
            SetPill(r.pill, pg.badge)
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
