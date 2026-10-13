if DisasterZoneBoot and DisasterZoneBoot.Run("UI/BossLearnUI.lua", ...) then return end -- DisasterZone UI/BossLearnUI.lua
-- What boss mods learned, on screen (ns.BossLearnUI; the learning itself is Core/BossLearn.lua). Mockup:
-- cleanup_template.html section 3 (Settings > Boss mods > Bosses > Gruul).
--   settings   two rows in the boss mods card, after the role rows: "Learn from our pulls" (bossmods.learn) and
--              "Share what we learn" (bossmods.learnShare, dimmed while learning is off)
--   bosses     each boss in the Bosses list wears a pill ("Learned · 7 pulls", "Learning · 2 of 3", nothing before its
--              first pull; the developer's "1 fix to review") and opens its page on a click
--   page       over the cards: per timer the data's numbers as grey ticks on a 0..N s track, what our pulls showed as a
--              striped teal band, and a plain status ("Learned 34–37 s", "Learning · 2 of 3", "Fixed · 10 s", "Far
--              from DBM"). The developer alone sees the review: never-fired alerts with the spell the boss really
--              cast ("Use 36240" / "Ignore"), unknown casts and yells.
--   pop-up     after a pull that changed something: "<Boss> · what we learned" in the notification center (kind
--              bossLearned, Settings > Alerts > What reaches you); Try it ends with a made-up one (nothing saved).
--   the line   "Recording pull 7 · learning waits for the end" over the timer bars (UI/BossModUI.lua draws it).
local addonName, ns = ...

local BLU = ns:NewModule("BossLearnUI")
local UI, S = ns.UI, ns.Style
local Math = ns.BossLearnMath

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local ipairs, pairs, type, tostring, tonumber = ipairs, pairs, type, tostring, tonumber

local function L() return ns.BossLearn end
local function BM() return ns.BossMod end
local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting(path)
    if v == nil then return default end
    return v
end

local TEAL = { 0.31, 0.84, 0.78 }         -- what our pulls showed (the striped band; the bars' band too)
local TEAL_DARK = { 0.12, 0.42, 0.40 }
local AMBER = { 1, 0.69, 0.4 }            -- measured but not used (far from the data, varies)
local TICK = { 0.62, 0.62, 0.66 }
local DEMO_BOSS = "GruulsLair:Gruul"
local KIND_WORD = { bar = "Timer bar", warn = "Warning", you = "On you", range = "Range frame" }
local ROW_H, NAME_W, STATUS_W, SWITCH_W = 40, 150, 178, 46
local Range = Math.Range

BLU.TEAL = TEAL

---------------------------------------------------------------------------
-- Words
---------------------------------------------------------------------------

local function BossName(def)
    if not def then return "" end
    if def.name then return def.name end
    local k = def.key:match(":(%w+)$") or def.key
    return k == "Waves" and "Trash waves" or k
end
BLU.BossName = BossName

local function SpellName(id) return L() and L().SpellName(id) or nil end

-- An alert's name for these pages (its text without the counters, else its spell's name).
local function AlertName(a)
    local t = a.text or SpellName(a.spell) or a.key
    t = tostring(t):gsub("%s*%(%%n%)", ""):gsub("%%n", "#"):gsub("%%t", "someone")
    t = t:gsub("%%s", SpellName(a.spell) or "")
    if a.kind == "range" then t = "Range frame" .. (a.yd and (" · " .. a.yd .. " yd") or "") end
    return t
end
BLU.AlertName = AlertName

local function FieldName(a, field)
    local name = AlertName(a)
    if a.start ~= nil and a.cd ~= nil then return name .. (field == "start" and ", first" or ", again") end
    return name
end
BLU.FieldName = FieldName

local function W(v)
    local lo, hi = Math.Window(v)
    return lo and Range(lo, hi) or ""
end

-- The pill and the line under it for one timer: kind, text, note.
function BLU:FieldStatus(def, a, field)
    local fit = L():Fit(def.key, a.key, field)
    local src = a[field]
    local spec = Math.Spec(a)
    if spec and spec.fixed and field == "cd" then
        local note = W(src) .. " after " .. (a.on and "its trigger" or "the last one")
        if fit and fit.mlo then note = "measured " .. Range(fit.mlo, fit.mhi) end
        return "alt", "Fixed · " .. W(src), note
    end
    if not fit then return "mute", "Learning · 0 of " .. Math.NEED_PULLS, "on " .. W(src) .. " for now" end
    local pulls = (fit.p or 0) .. ((fit.p or 0) == 1 and " pull" or " pulls")
    if fit.state == "ok" then
        return "ok", "Learned " .. Range(fit.lo, fit.hi), "was " .. W(src) .. " · " .. pulls
    elseif fit.state == "far" then
        return "warn", "Far from DBM", "we see " .. Range(fit.mlo, fit.mhi) .. " · kept " .. W(src)
    elseif fit.state == "varies" then
        return "warn", "Varies", "we see " .. Range(fit.mlo, fit.mhi) .. " · kept " .. W(src)
    end
    return "mute", ("Learning · %d of %d"):format(min(fit.p or 0, Math.NEED_PULLS - 1), Math.NEED_PULLS),
        "on " .. W(src) .. " for now"
end

-- The boss's pill: kind, text (nil = none).
function BLU:BossPill(key)
    local st = L():BossStatus(key)
    if st.fixes and st.fixes > 0 then
        return "bis", st.fixes == 1 and "1 fix to review" or (st.fixes .. " fixes to review")
    end
    if not st.state then return nil end
    if st.state == "learned" then
        return "ok", "Learned · " .. st.usable .. (st.usable == 1 and " pull" or " pulls")
    end
    return "mute", ("Learning · %d of %d"):format(min(st.usable, Math.NEED_PULLS - 1), Math.NEED_PULLS)
end

---------------------------------------------------------------------------
-- Settings rows (UI/BossModSettings.lua calls this after its role rows)
---------------------------------------------------------------------------

function BLU:AddSettingsRows(SU, sec, Dim)
    local _, row = SU:SwitchSetting(sec, "Learn from our pulls",
        "Timers tighten after 3 clean pulls that agree. Nothing changes during a pull.", "bossmods.learn", true,
        "We measure when each boss really casts in our raids. A pull always runs on the numbers it started with, and a "
            .. "timer never moves more than a quarter away from DBM's and BigWigs'. Off: their numbers only.")
    if Dim then Dim(nil, row) end
    local _, share = SU:SwitchSetting(sec, "Share what we learn",
        "Your pulls fill the gaps in your guildmates' and theirs in yours. Checked before it counts.",
        "bossmods.learnShare", true, "A few hundred bytes a pull on the guild channel, after the pull, never during one.")
    SU.refreshers[#SU.refreshers + 1] = { Refresh = function()
        local on = Get("bossmods.on", false) and Get("bossmods.learn", true)
        share:SetAlpha(on and 1 or 0.42)
    end }
    return row, share
end

---------------------------------------------------------------------------
-- The Bosses list: a pill and a way in per boss (UI/BossModSettings.lua Fill calls this per boss head)
---------------------------------------------------------------------------

local heads = {}

local function PaintHead(head)
    local kind, text = BLU:BossPill(head.dzBoss)
    if kind then
        head.dzPill:SetPill(kind, text)
        head.dzPill:Show()
    else
        head.dzPill:Hide()
    end
end

function BLU:DecorateBossHead(head, def)
    if not (head and def) or head.dzPill then return end
    head.dzBoss = def.key
    head.dzPill = UI:CreatePill(head, 16)
    head.dzPill:SetPoint("RIGHT", head.try or head, head.try and "LEFT" or "RIGHT", -8, 0)
    local hit = CreateFrame("Button", nil, head)
    hit:SetPoint("TOPLEFT", head, "TOPLEFT", 0, 0)
    hit:SetPoint("BOTTOMRIGHT", head.dzPill, "BOTTOMRIGHT", 0, -3)
    hit:SetScript("OnClick", function() BLU:Open(def.key) end)
    UI:AttachTooltip(hit, BossName(def), "What our pulls taught its timers.")
    head.dzOpen = hit
    heads[#heads + 1] = head
    PaintHead(head)
end

function BLU:RefreshHeads()
    for _, h in ipairs(heads) do PaintHead(h) end
end

---------------------------------------------------------------------------
-- The boss page
---------------------------------------------------------------------------

local page
BLU.ROW_H = ROW_H

local function Tex(parent, layer, color, a)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(color[1], color[2], color[3], a or color[4] or 1)
    return t
end

-- A row's track: textures made once, placed on each fill.
local function Track(row)
    local tr = CreateFrame("Frame", nil, row)
    tr.line = Tex(tr, "BORDER", { 1, 1, 1 }, 0.14)
    tr.line:SetHeight(1)
    tr.line:SetPoint("LEFT", tr, "LEFT", 0, 0)
    tr.line:SetPoint("RIGHT", tr, "RIGHT", 0, 0)
    tr.ticks, tr.stripes = {}, {}
    tr.band = Tex(tr, "ARTWORK", TEAL, 0.22)
    tr.bandL = Tex(tr, "OVERLAY", TEAL, 1)
    tr.bandR = Tex(tr, "OVERLAY", TEAL, 1)
    return tr
end

local function Tick(tr, i)
    local t = tr.ticks[i]
    if not t then t = Tex(tr, "ARTWORK", TICK, 0.9); t:SetSize(2, 12); tr.ticks[i] = t end
    return t
end

local function Stripe(tr, i)
    local t = tr.stripes[i]
    if not t then t = Tex(tr, "OVERLAY", TEAL, 0.75); t:SetSize(1, 10); tr.stripes[i] = t end
    return t
end

-- Draws the data's numbers (ticks) and the measured window (band) on a 0..scale s track `w` wide.
local function FillTrack(tr, w, scale, src, fit, color)
    for _, t in ipairs(tr.ticks) do t:Hide() end
    for _, t in ipairs(tr.stripes) do t:Hide() end
    tr.band:Hide(); tr.bandL:Hide(); tr.bandR:Hide()
    local function X(v) return floor(max(0, min(1, v / scale)) * w + 0.5) end
    local lo, hi = Math.Window(src)
    if lo then
        local tk = Tick(tr, 1)
        tk:ClearAllPoints(); tk:SetPoint("CENTER", tr, "LEFT", X(lo), 0); tk:Show()
        if hi ~= lo then
            tk = Tick(tr, 2)
            tk:ClearAllPoints(); tk:SetPoint("CENTER", tr, "LEFT", X(hi), 0); tk:Show()
        end
    end
    local blo = fit and (fit.applied and fit.lo or fit.mlo)
    local bhi = fit and (fit.applied and fit.hi or fit.mhi)
    if blo and bhi then
        local x0, x1 = X(blo), max(X(blo) + 3, X(bhi))
        local c = color or TEAL
        tr.band:SetColorTexture(c[1], c[2], c[3], 0.22)
        tr.band:ClearAllPoints()
        tr.band:SetPoint("LEFT", tr, "LEFT", x0, 0)
        tr.band:SetSize(x1 - x0, 10)
        tr.band:Show()
        for _, e in ipairs({ { tr.bandL, x0 }, { tr.bandR, x1 - 1 } }) do
            e[1]:SetColorTexture(c[1], c[2], c[3], 1)
            e[1]:ClearAllPoints()
            e[1]:SetPoint("LEFT", tr, "LEFT", e[2], 0)
            e[1]:SetSize(1, 10)
            e[1]:Show()
        end
        local n = 0
        for x = x0 + 3, x1 - 3, 3 do
            n = n + 1
            local st = Stripe(tr, n)
            st:SetColorTexture(c[1], c[2], c[3], 0.6)
            st:ClearAllPoints()
            st:SetPoint("LEFT", tr, "LEFT", x, 0)
            st:Show()
        end
    end
end
BLU.FillTrack = FillTrack

local function NewRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(ROW_H)
    r.rule = Tex(r, "BORDER", { 1, 1, 1 }, 0.06)
    r.rule:SetHeight(1)
    r.rule:SetPoint("BOTTOMLEFT"); r.rule:SetPoint("BOTTOMRIGHT")
    r.name = UI:Text(r, "emph", "TEXT")
    r.name:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -6)
    r.name:SetWidth(NAME_W - 8)
    r.kind = UI:Text(r, "small", "SUB")
    r.kind:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
    r.kind:SetWidth(NAME_W - 8)
    r.track = Track(r)
    r.track:SetHeight(14)
    r.pill = UI:CreatePill(r, 16)
    r.note = UI:Text(r, "small", "SUB")
    r.note:SetWidth(STATUS_W)
    return r
end

-- The rows of a boss: { a, field | nil, label }.
local function RowsOf(def)
    local out = {}
    local dev = L():IsDev()
    local never = dev and L():NeverFired(def.key) or {}
    for _, a in ipairs(def.alerts or {}) do
        if a.kind == "bar" then
            local any = false
            for _, f in ipairs({ "start", "cd" }) do
                if a[f] ~= nil then
                    any = true
                    out[#out + 1] = { a = a, field = f, label = FieldName(a, f) }
                end
            end
            if not any then out[#out + 1] = { a = a, label = AlertName(a) } end
        elseif never[a.key] then
            out[#out + 1] = { a = a, label = AlertName(a), never = never[a.key] }
        end
    end
    return out
end
BLU.RowsOf = RowsOf

-- The track's end: 0..N s with N the next 20 above every number shown.
local function Scale(def, rows)
    local top = 20
    for _, r in ipairs(rows) do
        if r.field then
            local _, hi = Math.Window(r.a[r.field])
            local fit = L():Fit(def.key, r.a.key, r.field)
            top = max(top, hi or 0, fit and (fit.mhi or fit.hi) or 0)
        end
    end
    return ceil(top / 20) * 20
end

local function NoticeBox(parent)
    local n = CreateFrame("Frame", nil, parent)
    n.bg = Tex(n, "BACKGROUND", S.C.GOLD, 0.07)
    n.bg:SetAllPoints()
    n.bar = Tex(n, "BORDER", S.C.GOLD, 0.9)
    n.bar:SetWidth(2)
    n.bar:SetPoint("TOPLEFT"); n.bar:SetPoint("BOTTOMLEFT")
    n.text = UI:Text(n, "body", "TEXT", { wrap = true })
    n.text:SetPoint("TOPLEFT", n, "TOPLEFT", 12, -9)
    n.use = UI:CreateSleekButton(n, "Use", 96, 22, function() end, "primary")
    n.use:SetPoint("BOTTOMLEFT", n, "BOTTOMLEFT", 12, 8)
    n.ignore = UI:CreateSleekButton(n, "Ignore", 70, 22, function() end, "secondary")
    return n
end

-- An alert's name where its spell matters (a fix to review: "Cave In", not its warning's "Cave In on you").
local function SpellOrAlert(a, fallback)
    if not a then return tostring(fallback) end
    return SpellName(a.spell) or AlertName(a)
end

local function SuggestionText(def, s)
    local a = def.byKey and def.byKey[s.alert]
    if s.kind == "spell" then
        return ("%s never fired. In %d of our pulls the boss cast a spell called %s with the id %d. Our data has %s.")
            :format(SpellOrAlert(a, s.alert), s.seen or s.pulls or 0, tostring(s.name), s.use, tostring(s.from))
    elseif s.kind == "cast" then
        return ("The boss cast %s (%d) in %d pulls, %d times. Our data doesn't know it.")
            :format(tostring(s.name or "a spell"), s.id, s.pulls or 0, s.n or 0)
    end
    return ("A boss line no trigger knows, in %d pulls: \"%s\""):format(s.pulls or 0, tostring(s.text))
end
BLU.SuggestionText = SuggestionText

local function Build()
    if page then return page end
    local SU = ns.SettingsUI
    local panel, scroll = SU and SU.panel, SU and SU.scroll
    local f = CreateFrame("Frame", "DisasterZoneBossLearnPage", panel or UIParent)
    if panel and scroll then
        f:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
        f:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 14, 0)
        f:SetFrameLevel((panel:GetFrameLevel() or 0) + 60)
    else
        f:SetSize(640, 480)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
    end
    f:EnableMouse(true)
    f.bg = UI:Fill(f, "SURFACE_WINDOW", "BACKGROUND")
    f.back = UI:CreateBackLink(f, "Boss mods", function() BLU:Close() end)
    f.back:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -2)
    f.title = UI:Text(f, "page", "GOLD")
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -22)
    f.pill = UI:CreatePill(f, 16)
    f.pill:SetPoint("LEFT", f.title, "RIGHT", 10, 0)
    f.lead = UI:Text(f, "body", "SUB", { wrap = true })
    f.lead:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -46)
    f.lead:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.notices = {}
    f.head = CreateFrame("Frame", nil, f)
    f.head:SetHeight(18)
    f.head.alert = UI:Text(f.head, "small", "SUB")
    f.head.alert:SetPoint("LEFT", f.head, "LEFT", 0, 0)
    f.head.alert:SetText("Alert")
    f.head.know = UI:Text(f.head, "small", "SUB")
    f.head.know:SetText("What we know")
    f.head.marks = {}
    f.scroll = UI:CreateScrollFrame(f)
    f.child = CreateFrame("Frame", nil, f.scroll)
    f.child:SetSize(400, 10)
    f.scroll:SetScrollChild(f.child)
    f.rows = {}
    f:Hide()
    if panel then panel:HookScript("OnHide", function() BLU:Close() end) end
    -- (going anywhere else in Settings closes it first, so that page finds the cards as it left them)
    if SU then
        for _, fn in ipairs({ "SelectSection", "OpenCategory", "OpenPart", "OpenKit" }) do
            local orig = SU[fn]
            if type(orig) == "function" then
                SU[fn] = function(...) BLU:Close(); return orig(...) end
            end
        end
    end
    page = f
    return f
end

function BLU:IsOpen() return page and page:IsShown() and page.boss or nil end
function BLU:GetPage() return page end

-- (the cards under the page step aside while it shows: nothing of them is drawn or hovered under it)
local cardsWere
local function Cards(shown)
    local SU = ns.SettingsUI
    local sc = SU and SU.scroll
    if not sc then return end
    if not shown then
        if cardsWere == nil then cardsWere = { sc:IsShown(), sc.ScrollBar and sc.ScrollBar:IsShown() } end
        sc:Hide()
        if sc.ScrollBar then sc.ScrollBar:Hide() end
    elseif cardsWere then
        sc:SetShown(cardsWere[1] and true or false)
        if sc.ScrollBar then sc.ScrollBar:SetShown(cardsWere[2] and true or false) end
        cardsWere = nil
    end
end

function BLU:Close()
    if page and page:IsShown() then
        page:Hide()
        Cards(true)
    end
end

-- Opens a boss's page (in Settings, over the cards; Settings opens first when it is closed).
function BLU:Open(key)
    local bm = BM()
    local def = bm and bm:Mod(key)
    if not def then return false end
    local SU = ns.SettingsUI
    if SU and not (SU.panel and SU.panel:IsVisible()) and SU.OpenBossMods then
        local raid = key:match("^(%w+):")
        pcall(SU.OpenBossMods, SU, raid)
    end
    local f = Build()
    f.boss = key
    f:Show()
    if f:GetParent() ~= UIParent then Cards(false) end
    self:Fill()
    return true
end

-- (Re)fills the open page.
function BLU:Fill()
    local f = page
    if not (f and f.boss) then return end
    local def = BM():Mod(f.boss)
    if not def then return end
    local learn = L()
    local dev = learn:IsDev()
    -- (its width: its own once laid out, else the cards' (Settings: their rows' width and margins) and its 14 px)
    local w = floor(f:GetWidth() or 0)
    if w < 300 then
        local SU = ns.SettingsUI
        w = floor(((SU and SU.BodyWidth and SU:BodyWidth()) or 522) + 24 + 14)
    end
    f.title:SetText(BossName(def))
    local kind, text = self:BossPill(def.key)
    if kind then f.pill:SetPill(kind, text); f.pill:Show() else f.pill:Hide() end
    local st = learn:BossStatus(def.key)
    local lead
    if not Get("bossmods.learn", true) then
        lead = "Learning is off: its timers are the DBM and BigWigs numbers."
    elseif st.pulls == 0 then
        lead = "No pulls yet. Its timers are DBM's and BigWigs' numbers until 3 clean pulls agree."
    else
        lead = ("Learned from %d %s."):format(st.usable, st.usable == 1 and "pull" or "pulls")
        if st.last and date then lead = lead .. " The last one was on " .. date("%A at %H:%M", st.last) .. "." end
    end
    f.lead:SetText(lead)
    local y = 46 + max(14, floor((f.lead:GetStringHeight() or 14) + 0.5)) + 12
    -- the developer's review
    for _, n in ipairs(f.notices) do n:Hide() end
    if dev then
        local shown = 0
        for _, s in ipairs(learn:Suggestions(def.key)) do
            if shown >= 3 then break end
            shown = shown + 1
            local n = f.notices[shown]
            if not n then n = NoticeBox(f); f.notices[shown] = n end
            n:ClearAllPoints()
            n:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y)
            n:SetPoint("RIGHT", f, "RIGHT", -16, 0)
            n.text:SetWidth(w - 16 - 24)
            n.text:SetText(SuggestionText(def, s))
            local th = max(14, floor((n.text:GetStringHeight() or 14) + 0.5))
            n:SetHeight(th + 9 + 8 + 22 + 8)
            local boss, key = def.key, s.key
            if s.kind == "spell" then
                n.use:SetText("Use " .. s.use)
                n.use:SetScript("OnClick", function() learn:Decide(boss, key, "use"); BLU:Fill() end)
                n.use:Show()
                n.ignore:ClearAllPoints()
                n.ignore:SetPoint("LEFT", n.use, "RIGHT", 6, 0)
            else
                n.use:Hide()
                n.ignore:ClearAllPoints()
                n.ignore:SetPoint("BOTTOMLEFT", n, "BOTTOMLEFT", 12, 8)
            end
            n.ignore:SetScript("OnClick", function() learn:Decide(boss, key, "ignore"); BLU:Fill() end)
            n:Show()
            y = y + n:GetHeight() + 8
        end
    end
    -- the table
    local trackX = NAME_W
    local trackW = max(100, w - 16 - NAME_W - STATUS_W - SWITCH_W - 32)
    local statusX = trackX + trackW + 24
    local rows = RowsOf(def)
    local scale = Scale(def, rows)
    f.head:ClearAllPoints()
    f.head:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y)
    f.head:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.head.know:ClearAllPoints()
    f.head.know:SetPoint("LEFT", f.head, "LEFT", statusX, 0)
    for _, m in ipairs(f.head.marks) do m:Hide() end
    -- (the scale's marks: every 20 s, 40 s or 60 s, so they never crowd)
    local step = scale <= 100 and 20 or scale <= 200 and 40 or 60
    local last = floor(scale / step)
    for i = 0, last do
        local m = f.head.marks[i + 1]
        if not m then m = UI:Text(f.head, "small", "SUB", { justify = "CENTER" }); f.head.marks[i + 1] = m end
        m:ClearAllPoints()
        m:SetPoint("CENTER", f.head, "LEFT", trackX + floor(i * step / scale * trackW + 0.5), 0)
        m:SetText(i == last and (i * step .. " s") or tostring(i * step))
        m:Show()
    end
    y = y + 20
    f.scroll:ClearAllPoints()
    f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y)
    f.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 0)
    f.child:SetWidth(w - 16)
    for _, r in ipairs(f.rows) do r:Hide() end
    local ry = 0
    for i, info in ipairs(rows) do
        local r = f.rows[i]
        if not r then r = NewRow(f.child); f.rows[i] = r end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", f.child, "TOPLEFT", 0, -ry)
        r:SetPoint("RIGHT", f.child, "RIGHT", 0, 0)
        local a = info.a
        r.name:SetText(info.label)
        local kw = KIND_WORD[a.kind] or a.kind
        if a.role then kw = kw .. (a.role == "T" and " · tanks" or " · healers") end
        r.kind:SetText(kw)
        r.track:ClearAllPoints()
        r.track:SetPoint("LEFT", r, "LEFT", trackX, 0)
        r.track:SetWidth(trackW)
        r.pill:ClearAllPoints()
        r.pill:SetPoint("TOPLEFT", r, "TOPLEFT", statusX, -5)
        r.note:ClearAllPoints()
        r.note:SetPoint("TOPLEFT", r.pill, "BOTTOMLEFT", 0, -3)
        local pk, pt, note
        if info.never then
            pk, pt = "warn", "Never fired"
            local first
            for _, t in ipairs(Math.Triggers(a.on)) do
                local word, ids = Math.Ids(t)
                if word and Math.SUBWORD[word] and ids[1] then first = ids[1] break end
            end
            note = first and ("spell " .. first .. " in our data") or ("in " .. info.never .. " pulls")
            r.track:Hide()
        elseif info.field then
            local ok, why = Math.Learnable(a)
            if ok then
                pk, pt, note = self:FieldStatus(def, a, info.field)
                local fit = L():Fit(def.key, a.key, info.field)
                local color = (fit and not fit.applied and (fit.state == "far" or fit.state == "varies")) and AMBER
                    or (fit and fit.state == "fixed") and TEAL_DARK or TEAL
                FillTrack(r.track, trackW, scale, a[info.field], fit, color)
            else
                pk, pt = "mute", "Not learned"
                note = why == "learn = false" and "the fight's script sets it" or why
                FillTrack(r.track, trackW, scale, a[info.field], nil)
            end
            r.track:Show()
        else
            pk, pt, note = "mute", "Not learned", "no timer of its own"
            r.track:Hide()
        end
        r.pill:SetPill(pk, pt)
        r.note:SetText(note or "")
        r.bossKey, r.alertKey = def.key, a.key
        if not r.switch then
            -- (the alert's own switch, the same as in the Bosses list)
            r.switch = UI:CreateSwitch(r, function() return BM():AlertOn(r.bossKey, r.alertKey) end,
                function(v, b)
                    local on = v
                    if type(b) == "boolean" then on = b end
                    BM():SetAlertOn(r.bossKey, r.alertKey, on and true or false)
                end)
            r.switch:SetPoint("RIGHT", r, "RIGHT", 0, 0)
            r.switch:SetScale(0.85)
        end
        r.switch:Refresh()
        r:Show()
        ry = ry + ROW_H
    end
    f.child:SetHeight(max(10, ry))
end

---------------------------------------------------------------------------
-- The recording line over the bars (UI/BossModUI.lua asks each frame while it draws)
---------------------------------------------------------------------------

-- { text, sub, noted } or nil (asked every frame: the same table while nothing changes). tryLearn: Try it's made-up
-- Gruul pull is playing (its own line, nothing recorded).
local line, lineNum, lineU = {}, nil, nil
local function Line(num, unknown)
    if lineNum ~= num or lineU ~= unknown then
        lineNum, lineU = num, unknown
        line = { text = "Recording pull " .. num, noted = unknown > 0,
                 sub = unknown > 0 and ((unknown == 1 and "1 cast we don't know" or (unknown .. " casts we don't know"))
                     .. ", noted") or "learning waits for the end" }
    end
    return line
end

function BLU:RecLine(tryLearn)
    local learn = L()
    if not learn then return nil end
    local num, _, unknown = learn:Status()
    if num then return Line(num, learn:IsDev() and unknown or 0) end
    if tryLearn then
        local m = BM() and BM():Active()
        if m and m.demo and m.def.key == DEMO_BOSS then
            return Line(7, (learn:IsDev() and (GetTime() - (m.t0 or GetTime())) >= 10.5) and 1 or 0)
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- The pop-up after a pull
---------------------------------------------------------------------------

local KIND = "bossLearned"
local FOOT = "Used from the next pull. Nothing changed during this one."

-- The lines of a report: up to 3 changed timers, and for the developer up to 2 review lines.
function BLU:ReportLines(info)
    local def = BM():Mod(info.boss)
    local lines = {}
    for i, c in ipairs(info.changes or {}) do
        if i > 3 then
            lines[#lines] = lines[#lines] .. ("  (+%d more)"):format(#info.changes - 3)
            break
        end
        local a = def and def.byKey[c.key]
        local name = a and FieldName(a, c.field) or c.key
        local now = c.to and W(c.to) or ("back to " .. W(c.src))
        lines[#lines + 1] = ("%s: %s, was %s"):format(name, now, W(c.from or c.src))
    end
    for i, s in ipairs(info.review or {}) do
        if i > 2 then break end
        if s.kind == "spell" then
            local a = def and def.byKey[s.alert]
            lines[#lines + 1] = ("%s: never fired · spell %d seen · review it"):format(SpellOrAlert(a, s.alert), s.use)
        elseif s.kind == "cast" then
            lines[#lines + 1] = ("A cast we don't know: %s (%d)"):format(tostring(s.name or "?"), s.id)
        else
            lines[#lines + 1] = "A line we don't know: \"" .. tostring(s.text):sub(1, 40) .. "\""
        end
    end
    return lines
end

function BLU:OnReport(info)
    local N = ns.Notify
    if not (N and N.Post and type(info) == "table" and info.boss) then return end
    local def = BM():Mod(info.boss)
    if not def then return end
    local lines = self:ReportLines(info)
    if #lines == 0 then return end
    lines[#lines + 1] = FOOT
    local now = ns.Util.Now()
    N:Post(KIND, { key = info.boss .. ":" .. now, title = BossName(def) .. " · what we learned",
                   text = table.concat(lines, "\n"), time = now,
                   short = BossName(def) .. ": timers learned", data = { boss = info.boss, review = #(info.review or {}) } })
end

-- Try it's ending: a made-up note on the shared toast (not the notification center: nothing is saved or sent).
function BLU:DemoReport()
    local lines = { "Ground Slam, first: 34" .. "\226\128\147" .. "37 s, was 33" .. "\226\128\147" .. "40 s",
                    "Growth: 30 s, as DBM says", FOOT }
    UI:Toast({ key = "bosslearn:demo", kind = "info", icon = UI.ICON_ATLAS, iconSize = 14,
               iconCoords = UI:IconCoords(UI.ICON.notes), kicker = "Try it · made up",
               title = "Gruul · what we learned", text = table.concat(lines, "\n"), lines = 4, duration = 10,
               timeBar = true })
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function BLU:OnInit()
    local N = ns.Notify
    if N and N.RegisterKind then
        N:RegisterKind(KIND, {
            section = "Boss mods", icon = { 37, 25, 4 }, color = TEAL, lines = 6,
            label = "What boss mods learned",
            desc = "After a pull: the timers that changed, from what our pulls showed.",
            needsYou = false, popup = true, sound = false, chat = false,
            open = function(it) if it and it.data and it.data.boss then BLU:Open(it.data.boss) end end,
            actions = function(it)
                if it and it.data and (it.data.review or 0) > 0 and L() and L():IsDev() then
                    return { { text = "Review", primary = true, fn = function() BLU:Open(it.data.boss) end } }
                end
                return {}
            end,
        })
    end
end

function BLU:OnLogin()
    ns:On("BOSSLEARN_REPORT", function(info) BLU:OnReport(info) end)
    ns:On("BOSSLEARN_CHANGED", function(boss)
        BLU:RefreshHeads()
        if page and page:IsShown() and (boss == nil or page.boss == boss) then BLU:Fill() end
    end)
end
