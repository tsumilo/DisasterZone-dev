if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LootRulesUI.lua", ...) then return end -- DisasterZone: UI/LootRulesUI.lua
-- Raids > Loot rules (1.3.5, the user's pick "the path", mockup dev/art/casc/lootrules_mockup): the guild's loot rules
-- for every member, read-only (Council > Rules is where the Guild Master and the council set them). Two views:
--   How it's decided: a banner, then the rules as numbered steps along a gold line, in plain words and built from the
--     guild's rules as they are (Guild:GetLootRules): who can be suggested, the council's votes first, your list sets
--     your group, then inside a group (longest use, driest, the roll: only those switched on). On the right, Where you
--     stand: my own numbers against them (attendance and the floor, raids since my last item when this client knows
--     it, my BiS list for the phase, how long my picks last when Longest use is on, the prized items I qualify for).
--   Prized items: a gallery of cards (the raid's art, the item in its orange ring, my standing, the rules' icons); a
--     card opens the item over the page: its rules with how I stand (left) and its history (right), "< All prized
--     items" back. The rule and history rows are UI/PrizedUI.lua's own.
local addonName, ns = ...

local LootRulesUI = ns:NewModule("LootRulesUI")

local UI = ns.UI
local S = ns.Style

local floor, max, min = math.floor, math.max, math.min
local format, tconcat = string.format, table.concat

local K = { W = S.INNER_W, GAP = S.GAP, BAN_H = S.BANNER.tool, LEFT_W = 480, NODE = 34, CARD_W = 251, CARD_H = 150,
            ART_H = 74, ITEM_BAN_H = 100, FADE = 0.16 }
K.RIGHT_X = K.LEFT_W + K.GAP
K.RIGHT_W = K.W - K.RIGHT_X
local MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\"
local PRIZED = { 1, 0.6, 0.18 }               -- the prized items' orange (the kicker, the intro's icon)
local PRIZED_EDGE = { 1, 0.5, 0, 0.9 }        -- a gallery card under the mouse
local ICON_TINT = { 1, 0.86, 0.4 }            -- an atlas icon in a gold ring
local TRACK = { 0.18, 0.18, 0.2, 1 }          -- an empty bar (the BiS track, the dry streak's unlit bars)

local state = { view = "decided", item = nil }
local panel

local function Me() return ns.Util.PlayerKey() end

-- (art pack 7's icons fall back without it)
local ICON_FALLBACK = { ballot = "poll", prized = "trophy", stopwatch = "calendar" }
local function IconName(name)
    if ICON_FALLBACK[name] and not (ns.HasAssets and ns:HasAssets(7)) then return ICON_FALLBACK[name] end
    return name
end

local function AtlasIcon(tex, name, color)
    if name == "bis" then
        tex:SetTexture(MEDIA .. "Icons\\bis")
        tex:SetTexCoord(0, 1, 0, 1)
    else
        local I = UI.ICON
        tex:SetTexture(UI.ICON_ATLAS)
        tex:SetTexCoord(unpack(UI:IconCoords(I[IconName(name)] or I.notes)))
    end
    tex:SetVertexColor(S:Color(color or { 1, 1, 1 }))
end

local function Plural(n, one, many) return n == 1 and ("1 " .. one) or (n .. " " .. (many or (one .. "s"))) end

-- (raidKey: the item data's raid key or the planner's, ItemDB:RaidArt; the crop stays under the game's logo)
local function SetArt(tex, raidKey, w, h)
    local ItemDB = ns.ItemDB
    if not (ItemDB and ItemDB.RaidArt) then
        tex:SetColorTexture(S:Color("CARD"))
        return
    end
    local file, l, r, t, b = ItemDB:RaidArt(raidKey or "other", w, h, 0.95, true)
    tex:SetTexture(file)
    tex:SetTexCoord(l, r, t, b)
end

-- A banner pill in any PILL_LOOK kind (Banner:SetPill only knows the events' kinds).
-- TODO(refactor): move into CreatePageBanner (SetPill with every pill kind: "bis")
local function BannerPill(b, kind, text)
    b.pill:SetPill(kind, text)
    b.pill:SetShown(text ~= nil and text ~= "")
    b:Layout()
end

-- A soft fade-in of a view when it shows (one shared driver).
local fades = {}
local driver
local function FadeIn(f)
    if not f:IsVisible() then return end
    f:SetAlpha(0)
    fades[f] = 0
    driver = driver or CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(_, dt)
        for frame, t in pairs(fades) do
            t = t + (dt or 0)
            local p = min(1, t / K.FADE)
            frame:SetAlpha(1 - (1 - p) ^ 3)
            fades[frame] = p < 1 and t or nil
        end
        if not next(fades) then driver:SetScript("OnUpdate", nil) end
    end)
end

local function Rules()
    local G = ns.Guild
    return G and G.GetLootRules and G:GetLootRules() or { f = 0, s = "r", l = "l", w = "r", y = "n", o = 0, q = "h" }
end

---------------------------------------------------------------------------
-- How it's decided
---------------------------------------------------------------------------

-- A pool of tag pills on a parent (reused on every fill).
local function NewStepPill(parent)
    local p = UI:CreatePill(parent, 20)
    p:SetBase(S:Color("INSET"))
    return p
end

local function PillPool(parent) return UI:Pool(parent, NewStepPill) end

local CHECK = "Interface\\RaidFrame\\ReadyCheck-Ready"

-- The steps, as words, from the rules: { { title, chips = { { text, kind, icon } ... }, sep = "›" (chips in an order),
-- text } }.
local function StepDefs(R)
    local steps = {}
    local floorPct = tonumber(R.f) or 0
    local who = { { "Didn't pass", "ok", CHECK }, { "In the raid", "ok", CHECK }, { "Can use it", "ok", CHECK } }
    if floorPct > 0 then who[#who + 1] = { floorPct .. "%+ attendance", "ok", CHECK } end
    steps[#steps + 1] = { title = "Who can be suggested", chips = who,
        text = floorPct > 0 and format("Under %d%% attendance you are still listed, with a warning, but never the "
            .. "suggestion.", floorPct) or "Anyone who rolled, still in the raid and able to use it." }
    steps[#steps + 1] = { title = "The council's votes come first", sep = true,
        chips = { { "Most votes", "bis" }, { R.s == "p" and "A tie: the council picks" or "A tie: the highest roll", "mute" } },
        text = R.s == "p" and "Most votes is the suggestion. When votes tie, the council picks one of them."
            or "Most votes is the suggestion. A tie goes to the highest roll among them; whoever didn't roll never "
            .. "wins a tie." }
    if R.l ~= "r" then
        steps[#steps + 1] = { title = "No votes yet? Your list sets your group", sep = true,
            chips = { { "BiS", "bis" }, { "Alt", "alt" }, { "Off-spec", "os" }, { "Everyone else", "mute" } },
            text = "Players with it as a BiS pick come before alts, off-spec lists, then everyone else." }
    else
        steps[#steps + 1] = { title = "No votes yet? The roll decides", chips = { { "Lists don't matter", "mute" } },
            text = "Whoever's list it is on doesn't matter: the highest roll is the suggestion." }
    end
    local chain, words = {}, {}
    local upTo = tonumber(R.o) or 0
    if upTo > 0 then
        chain[#chain + 1] = { "Longest use, to P" .. upTo, "mute" }
        words[#words + 1] = format("who keeps it on their list longest (to P%d)", upTo)
    end
    if R.w == "d" then
        chain[#chain + 1] = { "Driest first", "mute" }
        words[#words + 1] = "the most raids since their last item"
    end
    chain[#chain + 1] = { "Highest roll", "mute" }
    local text
    if #words == 0 then
        text = "The highest roll wins."
    else
        text = "First " .. tconcat(words, ", then ") .. "; the roll breaks the last tie."
    end
    steps[#steps + 1] = { title = R.l ~= "r" and "Then, inside a group" or "The roll", sep = true, chips = chain, text = text }
    return steps
end

local function BuildBanner(parent)
    local b = UI:CreatePageBanner(parent, { size = "tool", art = "BlackTemple", width = K.W, icon = IconName("ballot"),
        kicker = "Loot rules", title = "How the winner is picked", titleColor = "TEXT",
        sub = "The loot council decides. These rules make the drop panel's suggestion, the same for everyone." })
    if b.icon then b.icon.tex:SetVertexColor(S:Color(ICON_TINT)) end
    return b
end

-- The panels' look: the inset well of a page.
local function Panel(parent) return UI:CreateCard(parent, { tone = "inset" }) end

local function BuildPath(parent)
    local p = Panel(parent)
    p.line = p:CreateTexture(nil, "ARTWORK")
    p.line:SetWidth(2)
    local gd = S.C.GOLD_DEEP
    UI:Gradient(p.line, "VERTICAL", { gd[1], gd[2], gd[3], 0.25 }, { gd[1], gd[2], gd[3], 1 })
    p.steps = {}
    for i = 1, 4 do
        local s = CreateFrame("Frame", nil, p)
        s.node = CreateFrame("Frame", nil, s)
        s.node:SetSize(K.NODE, K.NODE)
        s.node:SetPoint("TOPLEFT", s, "TOPLEFT", 0, 0)
        s.node.disc = s.node:CreateTexture(nil, "ARTWORK", nil, 0)
        s.node.disc:SetTexture(MEDIA .. "Strategy\\disc")
        s.node.disc:SetVertexColor(S:Color("INSET"))
        s.node.disc:SetAllPoints()
        s.node.ring = s.node:CreateTexture(nil, "ARTWORK", nil, 1)
        s.node.ring:SetTexture(MEDIA .. "Events\\ring")
        s.node.ring:SetVertexColor(S:Color("GOLD_DEEP"))
        s.node.ring:SetAllPoints()
        s.node.n = UI:Text(s.node, 16, "GOLD")
        s.node.n:SetPoint("CENTER", 0, 0)
        s.node.n:SetJustifyH("CENTER")
        s.node.n:SetText(tostring(i))
        s.title = UI:Text(s, "title", "TEXT")
        s.title:SetPoint("TOPLEFT", s, "TOPLEFT", K.NODE + 14, -2)
        s.pills = PillPool(s)
        s.seps = {}
        s.text = UI:Text(s, "sub")
        s.text:SetWordWrap(true)
        p.steps[i] = s
    end
    p.foot = UI:Text(p, "sub")
    p.foot:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 16, 12)
    p.foot:SetText("The loot council decides in the end: this is only how its suggestion is made.")
    return p
end

local function FillPath(p, R)
    local defs = StepDefs(R)
    local w = K.LEFT_W - 32
    local textX = K.NODE + 14
    local y = -16
    local firstY, lastY
    for i, s in ipairs(p.steps) do
        local d = defs[i]
        s:SetShown(d ~= nil)
        if d then
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", p, "TOPLEFT", 16, y)
            s:SetWidth(w)
            s.title:SetText(d.title)
            s.pills:ReleaseAll()
            for _, t in ipairs(s.seps) do t:Hide() end
            local x, rowY = textX, -22
            for j, c in ipairs(d.chips) do
                local pill = s.pills:Acquire()
                pill:Set(c[1], c[2], c[3])
                if x + pill:GetWidth() > w and x > textX then
                    x, rowY = textX, rowY - 24
                end
                pill:ClearAllPoints()
                pill:SetPoint("TOPLEFT", s, "TOPLEFT", x, rowY)
                x = x + pill:GetWidth() + 6
                if d.sep and j < #d.chips then
                    local sep = s.seps[j]
                    if not sep then
                        sep = UI:Text(s, "title", "DIM")
                        sep:SetText("›")
                        s.seps[j] = sep
                    end
                    sep:ClearAllPoints()
                    sep:SetPoint("TOPLEFT", s, "TOPLEFT", x - 1, rowY - 3)
                    sep:Show()
                    x = x + 10
                end
            end
            s.text:ClearAllPoints()
            s.text:SetPoint("TOPLEFT", s, "TOPLEFT", textX, rowY - 26)
            s.text:SetWidth(w - textX)
            s.text:SetText(d.text)
            local h = -(rowY - 26) + (s.text:GetStringHeight() or 13) + 4
            h = max(h, K.NODE + 6)
            s:SetHeight(h)
            local cy = y - K.NODE / 2
            firstY = firstY or cy
            lastY = cy
            y = y - h - 12
        end
    end
    p.line:ClearAllPoints()
    p.line:SetPoint("TOP", p, "TOPLEFT", 16 + K.NODE / 2, firstY or 0)
    p.line:SetPoint("BOTTOM", p, "TOPLEFT", 16 + K.NODE / 2, lastY or 0)
end

-- Where you stand: the rows (built once, shown when they have something to say).
local function WRow(parent, label)
    local r = CreateFrame("Frame", nil, parent)
    r.label = UI:Text(r, "caps")
    r.label:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -10)
    r.label:SetText(label)
    r.big = UI:Text(r, "page", "TEXT")
    r.big:SetPoint("TOPLEFT", r.label, "BOTTOMLEFT", 0, -5)
    r.after = UI:Text(r, "sub")
    r.after:SetPoint("BOTTOMLEFT", r.big, "BOTTOMRIGHT", 8, 1)
    r.note = UI:Text(r, "sub")
    r.note:SetWordWrap(true)
    r.line = UI:Rule(r, { bottom = 0, layer = "BORDER" })
    return r
end

local function BuildYou(parent)
    local p = Panel(parent)
    p.cls = p:CreateTexture(nil, "ARTWORK")
    p.cls:SetSize(30, 30)
    p.cls:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -12)
    p.name = UI:Text(p, "title", "TEXT")
    p.name:SetPoint("TOPLEFT", p.cls, "TOPRIGHT", 10, 0)
    p.spec = UI:Text(p, "sub")
    p.spec:SetPoint("TOPLEFT", p.name, "BOTTOMLEFT", 0, -2)
    p.kick = UI:Text(p, "caps")
    p.kick:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, -16)
    p.kick:SetText("WHERE YOU STAND")
    p.head = UI:Rule(p, { top = 52, layer = "BORDER" })
    p.att = WRow(p, "ATTENDANCE")
    p.att.pill = UI:CreatePill(p.att, 18)
    p.att.pill:SetBase(S:Color("INSET"))
    p.att.pill:SetPoint("RIGHT", p.att, "TOPRIGHT", 0, -36)
    p.dry = WRow(p, "SINCE YOUR LAST ITEM")
    p.dry.bars = {}
    for i = 1, 6 do
        local t = p.dry:CreateTexture(nil, "ARTWORK")
        t:SetSize(7, 16)
        p.dry.bars[i] = t
    end
    p.bis = WRow(p, "YOUR BIS LIST")
    p.bis.track = p.bis:CreateTexture(nil, "ARTWORK", nil, 0)
    p.bis.track:SetHeight(5)
    p.bis.track:SetColorTexture(S:Color(TRACK))
    p.bis.fill = p.bis:CreateTexture(nil, "ARTWORK", nil, 1)
    p.bis.fill:SetHeight(5)
    UI:Gradient(p.bis.fill, "HORIZONTAL", "GOLD_DEEP", "GOLD")
    p.bis.open = CreateFrame("Button", nil, p.bis)
    p.bis.open:SetSize(90, 16)
    p.bis.open:SetPoint("TOPRIGHT", p.bis, "TOPRIGHT", 0, -8)
    p.bis.open.fs = UI:Text(p.bis.open, "body", "GOLD")
    p.bis.open.fs:SetPoint("RIGHT")
    p.bis.open.fs:SetText("Open My BiS ›")
    p.bis.open:SetScript("OnClick", function() if ns.MainFrame then ns.MainFrame:Open("mybis") end end)
    p.lng = WRow(p, "LONGEST USE")
    p.prz = WRow(p, "PRIZED ITEMS")
    p.prz.icons = {}
    for i = 1, 6 do
        local f = CreateFrame("Frame", nil, p.prz)
        f:SetSize(26, 26)
        f.ring = f:CreateTexture(nil, "BORDER")
        f.ring:SetAllPoints()
        f.ring:SetColorTexture(PRIZED_EDGE[1], PRIZED_EDGE[2], PRIZED_EDGE[3], 1)
        f.icon = f:CreateTexture(nil, "ARTWORK")
        f.icon:SetPoint("TOPLEFT", 2, -2)
        f.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        f:SetPoint("TOPLEFT", p.prz.label, "BOTTOMLEFT", (i - 1) * 32, -8)
        p.prz.icons[i] = f
    end
    p.prz.go = CreateFrame("Button", nil, p.prz)
    p.prz.go:SetSize(120, 16)
    p.prz.go:SetPoint("TOPRIGHT", p.prz, "TOPRIGHT", 0, -8)
    p.prz.go.fs = UI:Text(p.prz.go, "body", "GOLD")
    p.prz.go.fs:SetPoint("RIGHT")
    p.prz.go:SetScript("OnClick", function() LootRulesUI:SetView("prized") end)
    p.prz.line:Hide()
    return p
end

-- My attendance % (the raid log's, or the copy a reader sent me) or nil.
local function MyAttendance()
    local Att, RL, me = ns.Attendance, ns.RaidLog, Me()
    if Att and Att.CanSeeAll and Att:CanSeeAll() and RL and RL.GetAttendance then
        return (RL:GetAttendance(me, 8))
    end
    local mine = Att and Att.GetMine and Att:GetMine()
    if not mine and Att and Att.RequestMine then Att:RequestMine() end
    return mine and mine.p or nil
end

local function FillYou(p, R)
    local me = Me()
    local G, Store = ns.Guild, ns.Store
    local rec = Store and Store.Get and me and Store:Get(me)
    local data = rec and rec.data
    local cls = (data and data.cl) or (G and G.GetClass and me and G:GetClass(me))
    if cls then UI:ClassIcon(p.cls, cls) end
    p.name:SetText(me and UI:ColoredName(me, cls) or "You")
    local className = cls and ns.CLASS_NAMES and ns.CLASS_NAMES[cls] or ""
    p.spec:SetText(((data and data.sp) and (data.sp .. " ") or "") .. className)
    local w = K.RIGHT_W - 28
    local y = -52
    -- (each row as tall as its texts really are: the game's fonts run taller than they look)
    local function sh(fs) return fs and fs:IsShown() and fs:GetText() and fs:GetText() ~= "" and (fs:GetStringHeight() or 0) or 0 end
    local function head(r) return 10 + max(sh(r.label), 10) + 5 + max(sh(r.big), 18) end
    -- (rows are measured first, then laid out: under a tight panel the gaps shrink, then the prized row goes)
    local rows = {}
    local function place(r, h)
        r:SetWidth(w)
        rows[#rows + 1] = { r = r, h = h }
    end
    -- attendance against the floor
    local att = MyAttendance()
    local floorPct = tonumber(R.f) or 0
    if att then
        p.att.big:SetText(att .. "%")
        p.att.big:SetTextColor(S:Color(att >= 90 and "OK" or "TEXT"))
        p.att.after:SetText("last 8 raids")
    else
        p.att.big:SetText("–")
        p.att.big:SetTextColor(S:Color("SUB"))
        p.att.after:SetText("asking a raid log reader")
    end
    p.att.pill:SetShown(floorPct > 0 and att ~= nil)
    if floorPct > 0 and att then
        if att >= floorPct then
            p.att.pill:Set("above the " .. floorPct .. "% floor", "ok", CHECK)
        else
            p.att.pill:Set("under the " .. floorPct .. "% floor", "warn")
        end
    end
    p.att.note:Hide()
    place(p.att, head(p.att))
    -- raids since my last item (only where this client keeps the loot log: the council)
    local Att = ns.Attendance
    local d = Att and Att.CanSeeDryStreaks and Att:CanSeeDryStreaks() and me and Att:GetDryStreak(me) or nil
    if d then
        local n = tonumber(d.nights) or 0
        p.dry.big:ClearAllPoints()
        p.dry.big:SetPoint("TOPLEFT", p.dry.label, "BOTTOMLEFT", 6 * 9 + 6, -5)
        for i, t in ipairs(p.dry.bars) do
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", p.dry.label, "BOTTOMLEFT", (i - 1) * 9, -7)
            t:SetColorTexture(S:Color(i <= min(n, 6) and PRIZED or TRACK))
        end
        p.dry.big:SetText(Plural(n, "raid"))
        p.dry.after:SetText("")
        local last = d.last
        local ItemDB = ns.ItemDB
        local nm = last and ItemDB and ItemDB.GetName and ItemDB:GetName(last.i)
        p.dry.note:ClearAllPoints()
        p.dry.note:SetPoint("TOPLEFT", p.dry.big, "BOTTOMLEFT", -(6 * 9 + 6), -4)
        p.dry.note:SetWidth(w)
        p.dry.note:SetText(nm and ("Last: " .. nm .. ", " .. (ns.Util.FormatAgo and ns.Util.FormatAgo(last.ts) or "")) or
            "No item on record yet.")
        p.dry.note:Show()
        place(p.dry, head(p.dry) + 4 + max(sh(p.dry.note), 11))
    else
        p.dry:Hide()
    end
    -- my BiS list for the phase
    local phase = G and G.GetViewPhase and G:GetViewPhase() or 1
    local picked, total, empty = 0, 0, {}
    local ph = data and type(data.ph) == "table" and data.ph[phase]
    -- (a two-hander leaves the off hand empty on purpose, as My BiS counts it)
    local mh = type(ph) == "table" and type(ph[15]) == "table" and tonumber(ph[15][1]) or 0
    local twoHand = mh > 0 and ns.ItemDB and ns.ItemDB:GetEquipLoc(mh) == "INVTYPE_2HWEAPON"
    for _, slot in ipairs(ns.SLOTS or {}) do
        local skip = twoHand and slot.id == 16 and not (type(ph[16]) == "table" and (tonumber(ph[16][1]) or 0) > 0)
        if not skip and not (Store and Store.IsSlotDisabled and data and Store:IsSlotDisabled(data, phase, slot.id)) then
            total = total + 1
            local e = type(ph) == "table" and ph[slot.id]
            if type(e) == "table" and (tonumber(e[1]) or 0) > 0 then
                picked = picked + 1
            else
                empty[#empty + 1] = slot.label
            end
        end
    end
    p.bis.label:SetText("YOUR BIS LIST · P" .. phase)
    p.bis.big:SetText(picked .. S:Wrap("SUB", " / " .. total .. " picked"))
    p.bis.after:SetText("")
    p.bis.track:ClearAllPoints()
    p.bis.track:SetPoint("TOPLEFT", p.bis.big, "BOTTOMLEFT", 0, -6)
    p.bis.track:SetWidth(w)
    p.bis.fill:ClearAllPoints()
    p.bis.fill:SetPoint("TOPLEFT", p.bis.track)
    p.bis.fill:SetWidth(max(1, w * (total > 0 and picked / total or 0)))
    p.bis.fill:SetShown(picked > 0)
    p.bis.note:ClearAllPoints()
    p.bis.note:SetPoint("TOPLEFT", p.bis.track, "BOTTOMLEFT", 0, -6)
    p.bis.note:SetWidth(w)
    if #empty == 0 then
        p.bis.note:SetText(R.l ~= "r" and "Every slot picked: lists come first." or "Every slot picked.")
    else
        local list = {}
        for i = 1, min(#empty, 3) do list[i] = empty[i] end
        p.bis.note:SetText("Empty: " .. tconcat(list, ", ") .. (#empty > 3 and (" and " .. (#empty - 3) .. " more") or ""))
    end
    p.bis.note:Show()
    place(p.bis, head(p.bis) + 6 + 5 + 6 + max(sh(p.bis.note), 11))
    -- longest use: my picks kept to the last phase counted
    local upTo = tonumber(R.o) or 0
    if upTo > 0 and Store and Store.Longevity and type(ph) == "table" then
        local kept, n = 0, 0
        for sid, e in pairs(ph) do
            local id = type(e) == "table" and tonumber(e[1])
            if id and id > 0 then
                n = n + 1
                local _, _, last = Store:Longevity(me, id, phase, upTo)
                if last and last >= upTo then kept = kept + 1 end
            end
        end
        p.lng.label:SetText("LONGEST USE · COUNTED TO P" .. upTo)
        p.lng.big:SetText(Plural(kept, "pick"))
        p.lng.after:SetText(format("kept on your list to P%d, out of %d", upTo, n))
        p.lng.note:Hide()
        place(p.lng, head(p.lng))
    else
        p.lng:Hide()
    end
    -- the prized items I qualify for
    local P = ns.Prized
    local items = P and P.GetItems and P:GetItems() or {}
    if #items > 0 then
        local ok = 0
        for i, it in ipairs(items) do
            local c = P:Check(it, me)
            if c.ok == true then ok = ok + 1 end
            local f = p.prz.icons[i]
            if f then
                f.icon:SetTexture(ns.ItemDB:GetIcon(it.ids[1]))
                f:SetAlpha(c.ok == false and 0.4 or 1)
                f:Show()
            end
        end
        for i = #items + 1, #p.prz.icons do p.prz.icons[i]:Hide() end
        p.prz.big:SetText("")
        p.prz.after:SetText("")
        p.prz.note:Hide()
        p.prz.go.fs:SetText(format("%d of %d you qualify for ›", ok, #items))
        place(p.prz, 10 + max(sh(p.prz.label), 10) + 8 + 26)
    else
        p.prz:Hide()
    end
    local room = (p:GetHeight() or 0) + y - 8
    local sum = 0
    for _, it in ipairs(rows) do sum = sum + it.h end
    local pad = 14
    if room > 0 and sum + pad * #rows > room then
        pad = max(6, floor((room - sum) / #rows))
        if sum + pad * #rows > room and #rows > 1 and rows[#rows].r == p.prz then
            p.prz:Hide()
            sum = sum - rows[#rows].h
            rows[#rows] = nil
            pad = min(14, max(6, floor((room - sum) / #rows)))
        end
    end
    for _, it in ipairs(rows) do
        it.r:ClearAllPoints()
        it.r:SetPoint("TOPLEFT", p, "TOPLEFT", 14, y)
        it.r:SetHeight(it.h + pad)
        it.r:Show()
        y = y - it.h - pad
    end
end

---------------------------------------------------------------------------
-- Prized items: the gallery and an item
---------------------------------------------------------------------------

local function NewCard(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(K.CARD_W, K.CARD_H)
    c.bg = UI:Fill(c, "CARD")
    c.art = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.art:SetPoint("TOPLEFT", 1, -1)
    c.art:SetPoint("TOPRIGHT", -1, -1)
    c.art:SetHeight(K.ART_H)
    c.fade = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.fade:SetAllPoints(c.art)
    local cc = S.C.CARD
    UI:Gradient(c.fade, "VERTICAL", { cc[1], cc[2], cc[3], 1 }, { cc[1], cc[2], cc[3], 0.1 })
    UI:AddEdges(c, "BORDER")
    UI:SetEdgeColor(c, S:Color("EDGE"))
    -- the hover: an orange edge and a glow along the top (eased)
    c.glow = c:CreateTexture(nil, "OVERLAY")
    c.glow:SetPoint("TOPLEFT", 1, -1)
    c.glow:SetPoint("TOPRIGHT", -1, -1)
    c.glow:SetHeight(2)
    UI:Gradient(c.glow, "HORIZONTAL", { 1, 0.5, 0, 0.2 }, { 1, 0.62, 0.2, 0.9 })
    c.glow:SetAlpha(0)
    c.raid = UI:Text(c, "small", "GOLD")
    c.raid:SetPoint("TOPLEFT", c, "TOPLEFT", 11, -9)
    c.iconHolder = CreateFrame("Frame", nil, c)
    c.iconHolder:SetSize(40, 40)
    c.iconHolder:SetPoint("TOPLEFT", c, "TOPLEFT", 11, -38)
    c.icons = ns.PrizedUI:NewItemIcons(c.iconHolder, 36, 2)
    c.name = UI:Text(c, "title", "TEXT")
    c.name:SetPoint("TOPLEFT", c, "TOPLEFT", 11, -88)
    c.name:SetWidth(K.CARD_W - 22)
    c.boss = UI:Text(c, "sub")
    c.boss:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -3)
    c.pill = UI:CreatePill(c, 18)
    c.pill:SetBase(S:Color("CARD"))
    c.pill:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 11, 9)
    c.marks = {}
    for i = 1, 6 do
        local t = c:CreateTexture(nil, "ARTWORK")
        t:SetSize(11, 11)
        t:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -11 - (i - 1) * 15, 13)
        c.marks[i] = t
    end
    c:SetScript("OnEnter", function(self)
        UI:SetEdgeColor(self, S:Color(PRIZED_EDGE))
        self.glow:SetAlpha(1)
    end)
    c:SetScript("OnLeave", function(self)
        UI:SetEdgeColor(self, S:Color("EDGE"))
        self.glow:SetAlpha(0)
    end)
    c:SetScript("OnClick", function(self) if self.recId then LootRulesUI:OpenItem(self.recId) end end)
    return c
end

local function FillCard(c, rec)
    local P, PU = ns.Prized, ns.PrizedUI
    c.recId = rec.id
    local pl = P:Place(rec.ids[1])
    SetArt(c.art, pl.raidKey, K.CARD_W, K.ART_H)
    c.raid:SetText((pl.raidName or ""):upper())
    PU:SetItemIcons(c.icons, rec, 10)
    c.name:SetText(PU:RecName(rec))
    local q = ns.ItemDB and ns.ItemDB.GetQuality and ns.ItemDB:GetQuality(rec.ids[1]) or 4
    c.name:SetTextColor(UI:QualityColor(q))
    c.boss:SetText(pl.bossName or pl.raidName or "")
    local text, kind = PU:Standing(rec)
    c.pill:SetShown(text ~= nil)
    if text then c.pill:Set(text, kind) end
    local keys = {}
    for _, d in ipairs(P.RULES) do
        if rec.r[d.key] then keys[#keys + 1] = d.key end
    end
    for i, t in ipairs(c.marks) do
        local k = keys[#keys - i + 1]
        t:SetShown(k ~= nil and i <= 6)
        if k then PU:RuleIcon(t, k, S:Color("SUB")) end
    end
end

local function BuildGallery(parent)
    local g = CreateFrame("Frame", nil, parent)
    local sf = UI:CreateScrollFrame(g)
    sf:SetPoint("TOPLEFT", g, "TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", -2, 0)
    local body = CreateFrame("Frame", nil, sf)
    body:SetSize(K.W, 10)
    sf:SetScrollChild(body)
    g.scroll, g.body, g.cards = sf, body, {}
    g.intro = CreateFrame("Frame", nil, body)
    g.intro:SetSize(K.W, 40)
    g.intro.icon = g.intro:CreateTexture(nil, "ARTWORK")
    g.intro.icon:SetSize(16, 16)
    g.intro.icon:SetPoint("TOPLEFT", 2, -2)
    AtlasIcon(g.intro.icon, "prized", PRIZED)
    g.intro.text = UI:Text(g.intro, "sub")
    g.intro.text:SetWordWrap(true)
    g.intro.text:SetWidth(K.W - 30)
    g.intro.text:SetPoint("TOPLEFT", g.intro.icon, "TOPRIGHT", 8, 0)
    g.intro.text:SetText("A few drops have stricter rules, set by the Guild Master and the guild council. Click one "
        .. "to see each rule and how you stand.")
    return g
end

-- (true when the gallery has cards; the page shows its empty state otherwise)
local function FillGallery(g)
    local P = ns.Prized
    local items = P and P.GetItems and P:GetItems() or {}
    g.intro:ClearAllPoints()
    g.intro:SetPoint("TOPLEFT", g.body, "TOPLEFT", 0, 0)
    g.intro:SetShown(#items > 0)
    local top = #items > 0 and (g.intro.text:GetStringHeight() or 26) + 12 or 0
    local y = top
    for i, rec in ipairs(items) do
        local c = g.cards[i]
        if not c then
            c = NewCard(g.body)
            g.cards[i] = c
        end
        local col = (i - 1) % 3
        local row = floor((i - 1) / 3)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", g.body, "TOPLEFT", col * (K.CARD_W + 8), -(top + row * (K.CARD_H + 8)))
        FillCard(c, rec)
        c:Show()
        y = top + (row + 1) * (K.CARD_H + 8)
    end
    for i = #items + 1, #g.cards do g.cards[i]:Hide() end
    g.body:SetHeight(y + 4)
    return #items > 0
end

-- An item over the Prized items view: a detail page (its banner with the way back, then the rules and the history).
local function BuildItem(parent)
    local f = UI:CreateLayout("detail", parent, { pad = 0, bottom = 0, toolbar = false, width = K.W,
        banner = { size = K.ITEM_BAN_H, kicker = "Prized item", kickerColor = PRIZED, title = " " },
        back = { text = "All prized items", onClick = function() LootRulesUI:OpenItem(nil) end } })
    f.tabs:Hide()
    f:Layout()
    local b = f.banner
    -- the item's icons in the banner's icon place (one, or the pieces of a set side by side)
    -- TODO(refactor): move into CreatePageBanner (an icon slot that takes several item icons)
    b.iconHolder = CreateFrame("Frame", nil, b)
    b.iconHolder:SetSize(52, 48)
    b.icons = ns.PrizedUI:NewItemIcons(b.iconHolder, 48, 2)
    b.icon = b.iconHolder
    b:Layout()
    -- the rules and the history
    local function column(x, w, title)
        local p = Panel(f.body)
        p:SetPoint("TOPLEFT", f.body, "TOPLEFT", x, 0)
        p:SetPoint("BOTTOM", f.body, "BOTTOM", 0, 0)
        p:SetWidth(w)
        p.head = UI:CreateSectionHeader(p, title, { style = "caps" })
        p.head:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -4)
        p.head:SetPoint("TOPRIGHT", p, "TOPRIGHT", -12, -4)
        local sf = UI:CreateScrollFrame(p)
        sf:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -26)
        sf:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -16, 6)
        local body = CreateFrame("Frame", nil, sf)
        body:SetSize(w - 30, 10)
        sf:SetScrollChild(body)
        p.scroll, p.body, p.rows = sf, body, {}
        return p
    end
    f.rules = column(0, K.LEFT_W, "Rules")
    f.hist = column(K.RIGHT_X, K.RIGHT_W, "History")
    return f
end

local function FillItem(f, rec)
    local P, PU = ns.Prized, ns.PrizedUI
    local b = f.banner
    local pl = P:Place(rec.ids[1])
    PU:SetItemIcons(b.icons, rec, 14)
    b.iconHolder:SetWidth(#rec.ids > 1 and 86 or 52)
    b:SetArt(pl.raidKey or "other")
    b:SetTitle(PU:RecName(rec))
    local q = ns.ItemDB and ns.ItemDB.GetQuality and ns.ItemDB:GetQuality(rec.ids[1]) or 4
    b.title:SetTextColor(UI:QualityColor(q))
    b:SetSub(PU:SlotText(rec) .. " · " .. (pl.bossName and (pl.bossName .. " · ") or "") .. (pl.raidName or ""))
    b:SetKicker("Prized item")
    local _, kind, long = PU:Standing(rec)
    BannerPill(b, kind, long)
    -- the rules, with how I stand
    local check = P:Check(rec, Me())
    local by = check.by or {}
    local body = f.rules.body
    for _, r in ipairs(f.rules.rows) do r:Hide() end
    local y, n, req, pri = 0, 0, 0, 0
    for _, d in ipairs(P.RULES) do
        local v = rec.r[d.key]
        if v then
            n = n + 1
            local r = f.rules.rows[n]
            if not r then
                r = PU:NewRuleRow(body, K.LEFT_W - 30)
                f.rules.rows[n] = r
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
            y = y + PU:FillRuleRow(r, rec, d.key, by[d.key])
            r:Show()
            if d.key ~= "vote" then
                if (v.m or "r") == "r" then req = req + 1 else pri = pri + 1 end
            end
        end
    end
    body:SetHeight(max(10, y))
    f.rules.head:SetRight(format("%d required · %d priority", req, pri))
    -- the history
    local hb = f.hist.body
    for _, r in ipairs(f.hist.rows) do r:Hide() end
    y = 0
    for i, e in ipairs(P:GetHistory(rec.id)) do
        local r = f.hist.rows[i]
        if not r then
            r = PU:NewHistRow(hb, K.RIGHT_W - 30)
            f.hist.rows[i] = r
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", hb, "TOPLEFT", 0, -y)
        y = y + PU:FillHistRow(r, e)
        r:Show()
    end
    hb:SetHeight(max(10, y))
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

function LootRulesUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", "DisasterZoneLootRulesPanel", parent)
    p:SetAllPoints(parent)
    panel = p
    -- the board layout: the two views as the toolbar's tabs, who set the rules after them, the view under it
    local L = UI:CreateLayout("board", p)
    p.layout = L
    L.toolbar:SetTabs({ { key = "decided", text = "How it's decided" }, { key = "prized", text = "Prized items" },
        selected = "decided" }, function(key) LootRulesUI:SetView(key) end)
    local body = L.body
    p.body = body
    -- How it's decided
    local d = CreateFrame("Frame", nil, body)
    d:SetAllPoints()
    p.decided = d
    d.banner = BuildBanner(d)
    d.banner:SetPoint("TOPLEFT", d, "TOPLEFT", 0, 0)
    d.banner:SetPoint("TOPRIGHT", d, "TOPRIGHT", 0, 0)
    d.path = BuildPath(d)
    d.path:SetPoint("TOPLEFT", d, "TOPLEFT", 0, -(K.BAN_H + K.GAP))
    d.path:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 0, 0)
    d.path:SetWidth(K.LEFT_W)
    d.you = BuildYou(d)
    d.you:SetPoint("TOPLEFT", d, "TOPLEFT", K.RIGHT_X, -(K.BAN_H + K.GAP))
    d.you:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", 0, 0)
    -- Prized items
    p.gallery = BuildGallery(body)
    p.gallery:SetAllPoints()
    p.item = BuildItem(body)
    -- (MainFrame calls this on every show, the first one too: OnShow set here would miss that one)
    p.OnPanelShown = function() LootRulesUI:Refresh() end
    return p
end

function LootRulesUI:Refresh()
    local p = panel
    if not p or not p:IsVisible() then return end
    local R = Rules()
    local G = ns.Guild
    local L = p.layout
    local by = G and G.GetLootRulesBy and G:GetLootRulesBy()
    L.toolbar:SetText("Set by " .. (by and UI:ColoredName(by, G:GetClass(by)) or "the Guild Master") ..
        " · the same for everyone")
    local decided = state.view ~= "prized"
    L.toolbar:SelectTab(decided and "decided" or "prized")
    p.decided:SetShown(decided)
    local P = ns.Prized
    local rec = not decided and state.item and P and P.Get and P:Get(state.item) or nil
    if not decided and state.item and not rec then state.item = nil end
    p.gallery:SetShown(not decided and rec == nil)
    p.item:SetShown(rec ~= nil)
    local empty = false
    if decided then
        local d = p.decided
        BannerPill(d.banner, "bis", R.l ~= "r" and "Lists first" or "The roll decides")
        FillPath(d.path, R)
        FillYou(d.you, R)
    elseif rec then
        FillItem(p.item, rec)
    else
        empty = not FillGallery(p.gallery)
    end
    if empty then
        L:ShowEmpty({ glyph = UI.ICON[IconName("prized")], title = "No prized items yet",
            text = "Every drop follows the guild's rules (How it's decided)." })
    elseif L:IsEmptyShown() then
        L:HideEmpty()
    end
end

function LootRulesUI:RequestRefresh()
    if panel and panel:IsVisible() then ns.Util.Debounce("lootrules-ui", 0.15, function() LootRulesUI:Refresh() end) end
end

-- "decided" | "prized".
function LootRulesUI:SetView(view)
    local changed = state.view ~= view
    state.view = view == "prized" and "prized" or "decided"
    if state.view == "decided" then state.item = nil end
    self:Refresh()
    if changed and panel then FadeIn(state.view == "prized" and panel.gallery or panel.decided) end
end

function LootRulesUI:GetView() return state.view end

-- Opens a prized item over the Prized items view (nil: back to the gallery).
function LootRulesUI:OpenItem(id)
    state.view, state.item = "prized", id
    self:Refresh()
    if panel then FadeIn(id and panel.item or panel.gallery) end
end

function LootRulesUI:GetItem() return state.item end

function LootRulesUI:IsAvailable()
    return (IsInGuild() or ns.Util.DemoOn()) and true or false
end

function LootRulesUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("lootrules", "Loot rules", 3.51,
            function(parent) return LootRulesUI:CreatePanel(parent) end,
            function() return LootRulesUI:IsAvailable() end, { layout = "board" })
    end
    for _, m in ipairs({ "LOOT_RULES_CHANGED", "PRIZED_UPDATED", "ATTENDANCE_MINE", "RAIDLOG_CHANGED", "LEDGER_UPDATED",
                         "MYLIST_COMMITTED", "MYLIST_CHANGED", "DEMO_TOGGLED", "ITEMINFO_READY", "ROSTER_UPDATED" }) do
        ns:On(m, function() LootRulesUI:RequestRefresh() end)
    end
    ns:RegisterSlash("lootrules", function()
        ns.MainFrame:Open("lootrules")
        LootRulesUI:SetView("decided")
    end, "open Raids > Loot rules: how the loot council's suggestion is made, and the prized items")
end
