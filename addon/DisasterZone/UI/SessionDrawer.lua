if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SessionDrawer.lua", ...) then return end -- DisasterZone: UI/SessionDrawer.lua
-- The raid session crest's drawer (1.4.2; UI/SessionBar.lua opens it with a click on the seal or its line): the whole
-- night at a glance, drawn from Core/SessionInfo.lua's table. Bosses as round faces (gold ring: killed, with the
-- fight's length; the next one named, with Strategy, and Pull 10 / Break 5 for the leader); the drops waiting (Vote
-- when one waits on my vote, else Open: the drop panel); Free for All loot still to trade (Whisper the winner); the
-- raid (the council in it, who left or never came, the planned raid it is linked to; the leader changes the link);
-- and what the raid runs: switches for the leader (they apply at once; turning the loot council off asks first), a
-- read-only line for the council, End raid. Before the start: the lineup, the council, the planned raid and the
-- same three switches the line has.
local addonName, ns = ...

local D = ns:NewModule("SessionDrawer")

local S = ns.Style
local floor, max, min = math.floor, math.max, math.min
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local PEN = "Interface\\AddOns\\DisasterZone\\Media\\Pen\\"

local W, PAD, GAP = 470, 12, 8
local FACE, FACE_SLOT, FACE_GAP = 30, 38, 2
local ROW_H, ICON, BTN_H, PROW_H, LABEL_W = 30, 24, 20, 22, 86

local frame
local opts, data                  -- what Show was given

local function UI() return ns.UI end
local function SB() return ns.SessionBar end
local function SI() return ns.SessionInfo end

---------------------------------------------------------------------------
-- Pools: every piece is made once and reused; whatever a fill does not touch is hidden after it
---------------------------------------------------------------------------
local P = { used = {} }

function P.Use(r) P.used[r] = true; r:Show(); return r end

function P.Get(kind, make)
    frame.pool[kind] = frame.pool[kind] or { n = 0 }
    local pool = frame.pool[kind]
    pool.n = pool.n + 1
    local r = pool[pool.n]
    if not r then
        r = make()
        pool[pool.n] = r
        frame.all[#frame.all + 1] = r
    end
    return P.Use(r)
end

function P.Begin()
    P.used = {}
    for _, pool in pairs(frame.pool) do pool.n = 0 end
end

function P.Finish()
    for _, r in ipairs(frame.all) do
        if not P.used[r] then r:Hide() end
    end
end

function P.Smooth() return ns.HasAssets and ns:HasAssets(10) and ns.CTPen and ns.CTPen.RingTex and true or false end

---------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------
-- A caps header with a grey note at its right.
function P.Head(y, left, right, tip)
    local h = P.Get("head", function()
        local f = CreateFrame("Frame", nil, frame)
        f:SetHeight(14)
        f.l = UI():Text(f, "caps")
        f.l:SetPoint("LEFT", 0, 0)
        f.r = UI():Text(f, "small")
        f.r:SetPoint("RIGHT", 0, 0)
        f:SetScript("OnEnter", function(self)
            if not self.tip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tip[1], S:Color("GOLD"))
            for k = 2, #self.tip do GameTooltip:AddLine(self.tip[k], 0.8, 0.8, 0.8, true) end
            GameTooltip:Show()
        end)
        f:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return f
    end)
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -y)
    h:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -y)
    h.l:SetText(left:upper())
    h.r:SetText(right or "")
    h.tip = tip
    h:EnableMouse(tip ~= nil)
    return y + 14 + 6
end

-- A hairline between sections.
function P.Rule(y)
    local r = P.Get("rule", function()
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetHeight(1)
        t:SetColorTexture(S:Color("HAIRLINE"))
        return t
    end)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -y)
    r:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -y)
    return y + 1 + GAP
end

function P.Button(text, width, kind, onClick, tip)
    local b = P.Get("btn:" .. (kind or "secondary"), function()
        local x = UI():CreateSleekButton(frame, text, width, BTN_H, function(self) if self.run then self.run(self) end end,
            kind)
        UI():SetTextStyle(x:GetFontString(), "body")
        x:HookScript("OnEnter", function(self)
            SB():Peek(true)
            if not self.tip then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(self.tip[1], S:Color("GOLD"))
            for k = 2, #self.tip do GameTooltip:AddLine(self.tip[k], 0.8, 0.8, 0.8, true) end
            GameTooltip:Show()
        end)
        x:HookScript("OnLeave", function() GameTooltip:Hide() end)
        return x
    end)
    b:SetText(text)
    b:SetWidth(width)
    b.run, b.tip = onClick, tip
    b:ClearAllPoints()
    return b
end

function P.Text(style, color)
    local fs = P.Get("text:" .. style, function() return UI():Text(frame, style, color) end)
    fs:SetTextColor(S:Color(color or (S.STYLE[style] and S.STYLE[style].color) or "TEXT"))
    fs:ClearAllPoints()
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    fs:SetWidth(0)
    return fs
end

-- A round face: a boss's picture in a ring.
function P.Face(b, state)
    local f = P.Get("face", function()
        local x = CreateFrame("Button", nil, frame)
        x:SetSize(FACE + 4, FACE + 4)
        x.bg = x:CreateTexture(nil, "BACKGROUND")
        x.bg:SetTexture(MASK)
        x.bg:SetAllPoints()
        x.bg:SetVertexColor(0, 0, 0, 0.85)
        x.pic = x:CreateTexture(nil, "ARTWORK")
        x.pic:SetSize(FACE, FACE)
        x.pic:SetPoint("CENTER")
        if x.CreateMaskTexture then
            x.mask = x:CreateMaskTexture()
            x.mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            x.mask:SetAllPoints(x.pic)
            x.pic:AddMaskTexture(x.mask)
        end
        x.ring = x:CreateTexture(nil, "OVERLAY")
        x.ring:SetPoint("CENTER")
        x:SetScript("OnEnter", function(self)
            SB():Peek(true)
            local bb = self.boss
            if not bb then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(bb.name or "?", S:Color("GOLD"))
            GameTooltip:AddLine(self.line or "", 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        x:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return x
    end)
    f.boss = b
    if b.portrait then
        f.pic:SetTexture(b.portrait)
        f.pic:SetTexCoord(0.25, 0.75, 0, 1)
    else
        f.pic:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        f.pic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    local c = state == "k" and S.C.GOLD or (state == "l" and S.C.LIVE or (state == "n" and { 0.95, 0.86, 0.58 }
        or { 0.4, 0.4, 0.44 }))
    f.pic:SetDesaturated(state == "a" or state == "n")
    f.pic:SetVertexColor(state == "a" and 0.5 or 1, state == "a" and 0.5 or 1, state == "a" and 0.5 or 1)
    if P.Smooth() then
        local tex, size = ns.CTPen.RingTex(FACE / 2 + 0.8, 1.5)
        f.ring:SetTexture(tex)
        f.ring:SetSize(size, size)
        f.ring:SetVertexColor(c[1], c[2], c[3], 1)
        f.ring:Show()
    else
        f.ring:Hide()
    end
    f:ClearAllPoints()
    return f
end

-- A row with an item: icon, name, a status line under it, a button at the right.
function P.ItemRow(y, itemID, status, btn)
    local r = P.Get("item", function()
        local x = CreateFrame("Frame", nil, frame)
        x:SetHeight(ROW_H)
        x.hit = CreateFrame("Frame", nil, x)
        x.hit:SetPoint("TOPLEFT")
        x.hit:SetPoint("BOTTOMLEFT")
        x.hit:EnableMouse(true)
        x.icon = x:CreateTexture(nil, "ARTWORK")
        x.icon:SetSize(ICON, ICON)
        x.icon:SetPoint("LEFT", 0, 0)
        x.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        x.name = UI():Text(x, "body")
        x.name:SetPoint("TOPLEFT", x, "TOPLEFT", ICON + 8, -2)
        x.st = UI():Text(x, "small")
        x.st:SetPoint("TOPLEFT", x, "TOPLEFT", ICON + 8, -16)
        x.hit:SetScript("OnEnter", function(self)
            SB():Peek(true)
            local id = self:GetParent().itemID
            if not id then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if GameTooltip.SetItemByID then GameTooltip:SetItemByID(id) end
            GameTooltip:Show()
        end)
        x.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return x
    end)
    r.itemID = itemID
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -y)
    r:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -y)
    r.icon:SetTexture(UI():ItemIcon(itemID))
    r.name:SetText((UI():ItemText(itemID)))
    r.st:SetText(status or "")
    local right = 0
    if btn then
        btn:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        right = btn:GetWidth() + 8
    end
    r.hit:SetWidth(W - 2 * PAD - right)
    r.name:SetWidth(W - 2 * PAD - ICON - 8 - right)
    r.st:SetWidth(W - 2 * PAD - ICON - 8 - right)
    r.name:SetWordWrap(false)
    r.st:SetWordWrap(false)
    return y + ROW_H + 4
end

-- A label / value row; returns the value's left edge and the row (for discs and a button).
function P.Prow(y, label, value, btn)
    local k = P.Text("small", "DIM")
    k:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(y + 5))
    k:SetText(label)
    local v = P.Text("body")
    v:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + LABEL_W, -(y + 4))
    v:SetText(value or "")
    local right = 0
    if btn then
        btn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -(y + 1))
        right = btn:GetWidth() + 8
    end
    v:SetWidth(W - 2 * PAD - LABEL_W - right)
    return y + PROW_H + 2, v
end

-- Class-coloured discs for a list of players (the council here), dimmed ones for those away.
function P.Discs(x, y, here, away)
    local n = 0
    local function disc(key, dim)
        local t = P.Get("disc", function()
            local d = frame:CreateTexture(nil, "ARTWORK")
            d:SetTexture(P.Smooth() and (PEN .. "disc") or MASK)
            d:SetSize(12, 12)
            return d
        end)
        local cls = UI():ClassOf(key, data.cls and data.cls[key])
        local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
        if dim or not c then t:SetVertexColor(0.3, 0.3, 0.33, 1) else t:SetVertexColor(c.r, c.g, c.b, 1) end
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", frame, "TOPLEFT", x + n * 10, -(y + 5))
        n = n + 1
    end
    for _, k in ipairs(here) do disc(k, false) end
    for _, k in ipairs(away) do disc(k, true) end
    return n > 0 and (n * 10 + 6) or 0
end

local function Names(keys, max_)
    local out = {}
    for i, k in ipairs(keys or {}) do
        if max_ and i > max_ then
            out[#out + 1] = ("%d more"):format(#keys - max_)
            break
        end
        out[#out + 1] = opts.name(k)
    end
    if #out == 0 then return "" end
    if #out == 1 then return out[1] end
    return table.concat(out, ", ", 1, #out - 1) .. " and " .. out[#out]
end

local function Clock(sec, short) return SI():Clock(sec, short) end

---------------------------------------------------------------------------
-- Sections
---------------------------------------------------------------------------
local Sec = {}

function Sec.Bosses(y)
    local i, lead = data, opts.aud == "lead"
    local bosses = i.bosses or {}
    local n = #bosses
    y = P.Head(y, "Bosses", ("%d of %d · %s"):format(i.kills or 0, i.total or n, Clock(i.el or 0)))
    local nextB
    for k, b in ipairs(bosses) do
        if not b.killed then nextB = nextB or b end
        local st = b.killed and "k" or (b == nextB and "n" or "a")
        local f = P.Face(b, st)
        f:SetPoint("TOP", frame, "TOPLEFT", PAD + (k - 1) * (FACE_SLOT + FACE_GAP) + FACE_SLOT / 2, -y)
        f.line = b.killed and ("Killed · %s fight"):format(b.dur and Clock(b.dur, true) or "?")
            or (b == nextB and "Next" or "Not killed yet")
        local lab = P.Text("small", b.killed and "GOLD" or "SUB")
        lab:SetPoint("TOP", f, "BOTTOM", 0, -1)
        lab:SetText(b.killed and (b.dur and Clock(b.dur, true) or "") or (b == nextB and "next" or ""))
        if b.killed then lab:SetTextColor(0.95, 0.86, 0.58) end
    end
    local facesW = n * (FACE_SLOT + FACE_GAP)
    local side = facesW + 190 <= W - 2 * PAD
    local ny = side and y or (y + FACE + 4 + 16)
    local right = W - PAD
    if nextB then
        local t = P.Text("body")
        t:SetPoint("TOPRIGHT", frame, "TOPLEFT", right, -(ny + 2))
        t:SetText(S:Wrap("SUB", "Next") .. "  " .. (nextB.name or "?"))
        t:SetJustifyH("RIGHT")
        local bx = right
        local by = ny + 20
        local function place(b)
            b:SetPoint("TOPRIGHT", frame, "TOPLEFT", bx, -by)
            bx = bx - b:GetWidth() - 4
        end
        if lead and not (i.fight) then
            place(P.Button("Break 5", 56, nil, function() SB():Break(5) end,
                { "Break 5", "A 5 minute break bar for the raid (DBM and BigWigs users see it too)." }))
            place(P.Button("Pull 10", 56, nil, function() SB():Pull(10) end,
                { "Pull 10", "The game's 10 second pull countdown for the raid." }))
        end
        local linked = i.link and i.link.occ
        local sb = P.Button("Strategy", 70, nil, function() SB():OpenStrategy(nextB.ref) end,
            { "Strategy", linked and ("The strategy board for " .. (nextB.name or "the boss") .. " with tonight's names.")
                or "Link the raid to a planned raid first: the board fills in its names." })
        sb:SetEnabled(linked and true or false)
        place(sb)
    else
        local t = P.Text("body")
        t:SetPoint("TOPRIGHT", frame, "TOPLEFT", right, -(ny + 2))
        t:SetJustifyH("RIGHT")
        t:SetText(n > 0 and S:Wrap("GOLD", ("All %d down"):format(n)) or "")
        local fast, slow
        for _, b in ipairs(bosses) do
            if b.dur then
                if not fast or b.dur < fast.dur then fast = b end
                if not slow or b.dur > slow.dur then slow = b end
            end
        end
        if fast and slow and fast ~= slow then
            local t2 = P.Text("small")
            t2:SetPoint("TOPRIGHT", frame, "TOPLEFT", right, -(ny + 18))
            t2:SetJustifyH("RIGHT")
            t2:SetText(("fastest %s · longest %s"):format(Clock(fast.dur, true), Clock(slow.dur, true)))
        end
    end
    y = side and (y + FACE + 4 + 16) or (ny + 20 + BTN_H)
    return P.Rule(y + 4)
end

function Sec.Drops(y)
    local drops = data.drops or {}
    if #drops == 0 then return y end
    y = P.Head(y, "Loot", ("%d waiting"):format(#drops))
    for k, e in ipairs(drops) do
        if k > 5 then
            local t = P.Text("small")
            t:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + ICON + 8, -y)
            t:SetText(("%d more in the drop panel"):format(#drops - 5))
            y = y + 16
            break
        end
        local st
        if e.state == "open" or e.state == "closed" then
            if e.plain then
                st = "Rolling" .. (e.left and (" · " .. S:Wrap("GOLD", floor(e.left) .. " s")) or "")
            else
                st = ("Voting · %d %s"):format(e.votes or 0, (e.votes or 0) == 1 and "vote" or "votes")
                if e.needMe then st = st .. " · " .. S:Wrap("GOLD", "you haven't voted")
                elseif e.mine then st = st .. " · you picked " .. opts.name(e.mine) end
            end
        elseif e.state == "queued" then
            st = "Queued"
        else
            st = "Not rolled yet"
        end
        local b = P.Button(e.needMe and "Vote" or "Open", 56, e.needMe and "primary" or nil,
            function() SB():OpenDrops() end, { e.needMe and "Vote" or "Open", "The drop panel at this drop." })
        y = P.ItemRow(y, e.itemID, st, b)
    end
    return P.Rule(y + 2)
end

function Sec.Trades(y)
    local trades = data.trades or {}
    if #trades == 0 then return y end
    y = P.Head(y, "Loot · Free for All", ("%d to trade"):format(#trades))
    for _, t in ipairs(trades) do
        local where = t.mine and "in your bags" or ("in %s's bags"):format(opts.name(t.holder))
        local st = ("%s · %s · %s"):format(opts.name(t.to), where,
            S:Wrap("GOLD", "trade within " .. Clock(t.expires - GetServerTime())))
        local b = t.mine and P.Button("Whisper", 66, nil, function() SB():WhisperTrade(t) end,
            { "Whisper", "Tells " .. opts.name(t.to) .. " to come and trade you." }) or nil
        y = P.ItemRow(y, t.itemID, st, b)
    end
    return P.Rule(y + 2)
end

function Sec.Raid(y, idle)
    local i, lead = data, opts.aud == "lead"
    local a = i.addon or { have = 0, total = 0, without = {} }
    y = P.Head(y, idle and "Before you start" or "Raid", ("%d of %d have DisasterZone"):format(a.have, a.total),
        #a.without > 0 and { "Without DisasterZone", Names(a.without, 8), "They type /roll; their rolls still count." }
        or nil)
    local lu = idle and i.lineup
    if idle then
        local v
        if lu and (lu.total or 0) > 0 then
            y, v = P.Prow(y, "Lineup", ("%d of %d here"):format(lu.here, lu.total)
                .. (#(lu.missing or {}) > 0 and (S:Wrap("SUB", " · missing ") .. Names(lu.missing, 4)) or ""))
        end
    end
    -- the council in the raid
    local c = i.council or { here = {}, away = {} }
    local total = #c.here + #c.away
    local _, v = P.Prow(y, "Council here", "")
    local dx = P.Discs(PAD + LABEL_W, y, c.here, c.away)
    v:ClearAllPoints()
    v:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + LABEL_W + dx, -(y + 4))
    -- (who of the council signed up for tonight and isn't here; without a planned raid, who is here)
    if #c.here == 0 then
        v:SetText(S:Wrap("WARN", "nobody from the council is here") .. S:Wrap("SUB", " · rolls only"))
    elseif #c.away > 0 then
        v:SetText(("%d of %d"):format(#c.here, total) .. S:Wrap("SUB", " · ") .. Names(c.away, 2)
            .. S:Wrap("SUB", " not here"))
    else
        v:SetText(("%d here"):format(#c.here) .. S:Wrap("SUB", " · ") .. Names(c.here, 2))
    end
    v:SetWidth(W - 2 * PAD - LABEL_W - dx)
    y = y + PROW_H + 2
    -- who left, who never came
    if not idle and (#(i.left or {}) + #(i.missing or {})) > 0 then
        local parts = {}
        for _, l in ipairs(i.left or {}) do parts[#parts + 1] = opts.name(l.key) .. S:Wrap("SUB", date(" left %H:%M", l.at)) end
        if #(i.missing or {}) > 0 then parts[#parts + 1] = Names(i.missing, 3) .. S:Wrap("SUB", " not here") end
        local b = lead and P.Button("Review", 60, nil, function() SB():OpenAttendance() end,
            { "Review", "Tick what they said, swap someone in, or leave it to the officers." }) or nil
        y = P.Prow(y, "Attendance", table.concat(parts, ", "), b)
    end
    -- the planned raid
    local plan = idle and lu or i.link
    local text
    if plan then
        text = plan.title .. (plan.team and (" · " .. plan.team) or "") .. (plan.t and date(" · %H:%M", plan.t) or "")
    elseif idle then
        text = S:Wrap("SUB", "no planned raid matches yet")
    else
        text = S:Wrap(i.unlinked and "WARN" or "SUB", "not linked to a planned raid")
    end
    local b = (lead and not idle) and P.Button(plan and "Change" or "Link", 60, nil,
        function(self) SB():OpenLinkMenu(self) end, { "Planned raid", "Pick the planned raid this night counts for." })
        or nil
    y = P.Prow(y, idle and "Will link to" or "Linked to", text, b)
    return P.Rule(y + 4)
end

-- What the raid runs: the leader's switches (the idle line's, or the running raid's), else a line.
local SWITCHES = { { "loot", "Loot council" }, { "rolls", "Rolls" }, { "lock", "BiS lists locked" } }
function Sec.Runs(y, idle)
    local i, lead = data, opts.aud == "lead"
    local feats = idle and (SB():GetPick() or SB():LastFeatures()) or (i.feats or {})
    if lead then
        local x = PAD
        for k, sw in ipairs(SWITCHES) do
            local key = sw[1]
            local s = P.Get("switch" .. k, function()
                local o = UI():CreateSwitch(frame, nil, function(on)
                    if opts.state == "idle" then SB():FlipPick(key) else SB():SetFeature(key, on) end
                end, sw[2])
                return o
            end)
            s:SetChecked(feats[key] and true or false)
            local can = key ~= "lock" or (feats.loot and not feats.reserve)
            s:SetEnabled(can and true or false)
            if s.label then s.label:SetTextColor(S:Color(can and "TEXT" or "DIM")) end
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -(y + 2))
            x = x + 34 + 9 + (s.label and s.label:GetStringWidth() or 60) + 16
        end
        if not idle then
            local e = P.Button("End raid", 66, "danger", function() SB():ConfirmEnd() end,
                { "End raid", "Ends the raid log and unlocks the BiS lists (asks first)." })
            e:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -y)
        end
        y = y + BTN_H + 4
        if idle then
            local t = P.Text("small", "DIM")
            t:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -y)
            t:SetText("Attendance, boss kills and the loot handed out are always logged.")
            y = y + 14
        end
        return y
    end
    local parts = {}
    parts[#parts + 1] = "Loot council " .. (feats.loot and S:Wrap("OK", "on") or S:Wrap("SUB", "off"))
    parts[#parts + 1] = "Rolls " .. (feats.rolls and S:Wrap("OK", "on") or S:Wrap("SUB", "off"))
    parts[#parts + 1] = "BiS lists " .. (feats.lock and S:Wrap("WARN", "locked") or S:Wrap("SUB", "open"))
    local t = P.Text("body")
    t:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(y + 3))
    t:SetText(table.concat(parts, S:Wrap("DIM", "  ·  ")))
    local by = P.Text("small", "DIM")
    by:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -(y + 4))
    by:SetJustifyH("RIGHT")
    by:SetText(i.leader and ("set by " .. opts.name(i.leader)) or "")
    return y + BTN_H + 2
end

-- 1.4.3: loot reserves (Core/Reserves.lua): the leader's switch and rules (per player, the guild's items, what
-- happens to the rest, the ways in) and the list's buttons; everyone else a line and My reserves.
function Sec.Reserves(y, idle)
    local i, lead = data, opts.aud == "lead"
    local R, RUI = ns.Reserves, ns.ReservesUI
    if not (R and RUI) then return y end
    local feats = idle and (SB():GetPick() or SB():LastFeatures()) or (i.feats or {})
    local L = R:Get()
    local on = feats.reserve and true or false
    if not lead and not (on or L) then return y end
    y = P.Rule(y + 4)
    local right
    if L then
        local _, done, size = R:Missing()
        right = ("%d of %d reserved · %s"):format(done, size, L.foreign and "LootReserve"
            or (L.o and "open" or "closed"))
    else
        right = on and "not open yet" or "off"
    end
    y = P.Head(y, "Reserves", right)
    if not lead then
        local b = P.Button("My reserves", 92, nil, function() RUI:Show("pick") end,
            { "My reserves", "Pick what you reserve tonight from the raid's loot." })
        y = P.Prow(y, "Tonight", RUI:RulesLine(L), b)
        return y
    end
    -- the switch: reserves decide the loot (the council keeps the guild's items)
    local s = P.Get("switchReserve", function()
        return UI():CreateSwitch(frame, nil, function(v)
            if opts.state == "idle" then SB():FlipPick("reserve") else SB():SetFeature("reserve", v) end
        end, "Reserves decide the loot")
    end)
    s:SetChecked(on)
    s:ClearAllPoints()
    s:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(y + 2))
    local act
    if not L then
        act = P.Button("Open reserves", 104, "primary", function() RUI:OpenReserves() end,
            { "Open reserves", "Posts the rules in raid chat. Players reserve in DisasterZone, LootReserve, by "
                .. "whisper (!sr), or you import softres.it. They close at the first pull." })
    else
        act = P.Button("Reserves", 80, nil, function() RUI:Show("list") end, { "Reserves", "The whole list." })
    end
    act:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -y)
    y = y + BTN_H + 6
    if not (on or L) then
        local t = P.Text("small", "DIM")
        t:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -y)
        t:SetText("For pug nights: whoever reserved an item rolls on it, the rest is up for grabs.")
        return y + 14
    end
    if L and not L.foreign then
        -- soft reserves per player
        local _, v = P.Prow(y, "Soft reserves", "")
        local x = PAD + LABEL_W
        for n = 1, 3 do
            local b = P.Button(tostring(n), 26, L.n == n and "chosen" or nil, function() R:SetPerPlayer(n) end,
                { n .. " each", "How many items each player may soft reserve." })
            b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -(y + 1))
            x = x + 30
        end
        v:ClearAllPoints()
        v:SetPoint("TOPLEFT", frame, "TOPLEFT", x + 6, -(y + 4))
        v:SetText(S:Wrap("SUB", "each · only who reserved an item rolls on it"))
        v:SetWidth(W - PAD - x - 6 - PAD)
        y = y + PROW_H + 2
    end
    -- the guild's items
    local held = L and L.h or {}
    local pickBtn = (L and not L.foreign) and P.Button("Pick", 50, nil, function()
        RUI:Show("pick")
        if not RUI:GetState().holdMode then RUI:ToggleHoldMode() end
    end, { "Guild items", "Click items to hold them for the guild: the loot council decides them among guild "
        .. "members, nobody can reserve them." }) or nil
    local _, v = P.Prow(y, "Guild items", "", pickBtn)
    local x = PAD + LABEL_W
    for k = 1, math.min(#held, 8) do
        local t = P.Get("heldIcon", function()
            local tex = frame:CreateTexture(nil, "ARTWORK")
            tex:SetSize(18, 18)
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            return tex
        end)
        t:SetTexture(UI():ItemIcon(held[k]))
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -(y + 2))
        x = x + 21
    end
    v:ClearAllPoints()
    v:SetPoint("TOPLEFT", frame, "TOPLEFT", x + (#held > 0 and 4 or 0), -(y + 4))
    v:SetText(#held > 0 and S:Wrap("SUB", "the loot council decides these")
        or S:Wrap("SUB", L and "none · the council decides what you hold" or "pick them once reserves are open"))
    v:SetWidth(W - PAD - x - 8 - (pickBtn and 58 or 0) - PAD)
    y = y + PROW_H + 2
    y = P.Prow(y, "Unreserved","Up for grabs" .. S:Wrap("SUB", " · everyone rolls, highest wins"))
    local imp = (L and not L.foreign) and P.Button("Import", 60, nil, function() RUI:ShowImport() end,
        { "Import", "A softres.it sheet (CSV or the Gargul string), LootReserve's or Gargul's CSV." }) or nil
    y = P.Prow(y, "Ways in", "Whisper !sr" .. S:Wrap("SUB", " · ") .. "LootReserve" .. S:Wrap("SUB", " · ")
        .. "softres.it", imp)
    if L and not L.foreign then
        local post = P.Button("Post the rules", 100, nil, function() ns.ReserveChat:AnnounceRules() end,
            { "Post the rules", "The rules in raid warning, for the players without DisasterZone." })
        post:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -y)
        local oc = P.Button(L.o and "Close now" or "Reopen", 76, nil, function()
            if L.o then
                R:Close()
                ns.ReserveChat:AnnounceClosed()
            else
                R:Open({})
            end
        end, L.o and { "Close now", "Reserves close by themselves at the first pull." } or
            { "Reopen", "Take reserves again (you can always change any player's)." })
        oc:SetPoint("TOPRIGHT", post, "TOPLEFT", -6, 0)
        y = y + BTN_H + 2
    end
    return y
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------
local function Create()
    if frame then return frame end
    local f = CreateFrame("Frame", "DisasterZoneSessionDrawer", UIParent)
    f:SetWidth(W)
    f:SetFrameStrata("MEDIUM")
    f:EnableMouse(true)
    f.bg = UI():Fill(f, "DROP_BG", "BACKGROUND")
    UI():AddEdges(f, "BORDER")
    local g = S.C.GOLD
    UI():SetEdgeColor(f, g[1], g[2], g[3], 0.5)
    f.pool, f.all = {}, {}
    f:SetScript("OnEnter", function() SB():Peek(true) end)
    f:SetScript("OnLeave", function() SB():Peek(false) end)
    f:Hide()
    frame = f
    return f
end

-- Shows the drawer under (or over) the crest's line. o = { state, aud, left, up, name(key) }.
function D:Show(crest, i, o)
    local f = Create()
    opts, data = o, i
    P.Begin()
    local y = 6
    local idle = o.state == "idle"
    if not idle then
        y = Sec.Bosses(y)
        y = Sec.Drops(y)
        y = Sec.Trades(y)
    end
    y = Sec.Raid(y, idle)
    if idle then y = P.Head(y, "This raid runs", "the line's switches, spelled out") end
    y = Sec.Runs(y, idle)
    y = Sec.Reserves(y, idle)
    P.Finish()
    f:SetHeight(floor(y + PAD - 2))
    f:ClearAllPoints()
    local line = crest.line
    if o.up then
        f:SetPoint(o.left and "BOTTOMRIGHT" or "BOTTOMLEFT", line, o.left and "TOPRIGHT" or "TOPLEFT", 0, 4)
    else
        f:SetPoint(o.left and "TOPRIGHT" or "TOPLEFT", line, o.left and "BOTTOMRIGHT" or "BOTTOMLEFT", 0, -4)
    end
    f:Show()
    return f
end

function D:Hide()
    if frame then frame:Hide() end
end

function D:IsShown() return frame and frame:IsShown() or false end

function D:IsMouseOver()
    return frame and frame:IsShown() and frame.IsMouseOver and frame:IsMouseOver() or false
end

function D:GetFrame() return frame end
