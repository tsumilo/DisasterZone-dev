if DisasterZoneBoot and DisasterZoneBoot.Run("UI/EventPieces.lua", ...) then return end -- DisasterZone: draws event pieces.
-- Draws the event builder's pieces (Core/EventBlocks.lua) as frames, the Scratch way: a "when" piece wears a cap,
-- stack pieces have a notch on top and a tab under them, C pieces hold others in their arm, yes / no pieces are
-- hexagons and values are round. Words come from the catalogue (WC3's sentences); blanks are dark wells that take a
-- value, a typed text or a dropdown's choice. The shapes are tinted textures of Media/Events/pieces.tga
-- (dev/generators/gen_event_media.py, SHAPE below); bodies are flat fills with a soft top light and 1px edges.
--
-- EP:DrawScript(parent, top, opts) -> frame: a whole stack (frame.at[piece] = the piece's frame, frame.blanks = list of
-- { piece, slot, frame, t }). EP:Draw(parent, piece, opts): one piece (with its insides, without what follows it).
-- EP:Release(frame) gives the frames back to the pools. opts: problems = { [piece] = text }, live = { ctx values }
-- (a practice run's last values, shown in the round pieces), hot = { piece, slot } (a blank being edited), locked
-- (a lock on the hat), static (no mouse), def (names of stages / blocks / badges), onPiece(piece, frame, button, down),
-- onBlank(piece, slot, blankFrame, button), nameOf(key).
local addonName, ns = ...

local EP = ns:NewModule("EventPieces")

local CreateFrame = CreateFrame
local floor, max, min = math.floor, math.max, math.min
local tinsert, tremove = table.insert, table.remove

local ATLAS = "Interface\\AddOns\\DisasterZone\\Media\\Events\\pieces"
local WHITE = "Interface\\Buttons\\WHITE8X8"

-- The atlas (256 x 256): name -> fill x, y, edge x, y, w, h in texture px (2x the game size; gen_event_media.SHAPES).
local SHAPE = {
    dome = { 0, 0, 0, 24, 160, 24 },
    tab = { 0, 48, 48, 48, 40, 12 },
    hexL = { 0, 64, 24, 64, 20, 42 },
    hexR = { 48, 64, 72, 64, 20, 42 },
    rndL = { 96, 64, 120, 64, 20, 38 },
    rndR = { 144, 64, 168, 64, 20, 38 },
}

EP.H = 28           -- a stack piece
EP.HAT_H = 32       -- a hat's body (its dome stands 10 above)
EP.DOME = 10
EP.BLANK_H = 19
EP.HEX_H = 21
EP.PAD = 10
EP.GAP = 5
EP.ARM = 15         -- a C piece's arm
EP.FOOT = 15        -- its foot
EP.MID = 24         -- its "else" bar
EP.FOOT_W = 78
EP.TAB_X = 14
EP.FONT_SIZE = 11

local function B() return ns.EventBlocks end
local function UI() return ns.UI end

local NEED = { fill = { 1, 0.55, 0.10, 0.16 }, edge = { 1, 0.59, 0.16, 0.95 }, text = { 1, 0.83, 0.64 } }
local WELL = { fill = { 0.03, 0.03, 0.04, 0.62 }, edge = { 1, 1, 1, 0.16 }, text = { 1, 1, 1 } }
local HOT = { 1, 0.82, 0, 0.95 }
local LIVE = { fill = { 1, 0.94, 0.67, 0.16 }, edge = { 1, 0.9, 0.55, 0.85 }, text = { 1, 0.97, 0.84 } }

---------------------------------------------------------------------------
-- Pools
---------------------------------------------------------------------------

local holder = CreateFrame("Frame")
holder:Hide()
local pools = { piece = {}, blank = {}, script = {} }

local function Sized(fs, size)
    local path, _, flags = fs:GetFont()
    if path then fs:SetFont(path, size, flags) end
    return fs
end

-- The i-th extra texture / font string of a frame (made on first use, hidden by Trim when not used).
local function Tex(f, i, layer, sub)
    f.texs = f.texs or {}
    local t = f.texs[i]
    if not t then
        t = f:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
        f.texs[i] = t
    end
    t:ClearAllPoints()
    t:SetDrawLayer(layer or "ARTWORK", sub or 0)
    t:SetTexture(WHITE)
    t:SetTexCoord(0, 1, 0, 1)
    t:SetVertexColor(1, 1, 1, 1)
    t:SetAlpha(1)
    t:Show()
    return t
end

local function Font(f, i)
    f.fonts = f.fonts or {}
    local fs = f.fonts[i]
    if not fs then
        fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetWordWrap(false)
        fs:SetJustifyH("LEFT")
        Sized(fs, EP.FONT_SIZE)
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 0.85)
        f.fonts[i] = fs
    end
    fs:ClearAllPoints()
    fs:SetTextColor(1, 1, 1)
    fs:Show()
    return fs
end

local function Trim(f, nt, nf)
    for i = nt + 1, #(f.texs or {}) do f.texs[i]:Hide() end
    for i = nf + 1, #(f.fonts or {}) do f.fonts[i]:Hide() end
end

-- Puts a child at x, y (from its parent's top-left, y down) and remembers it: EP:Abs adds these up to the script.
local function Place(kid, parent, x, y)
    kid:ClearAllPoints()
    kid:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    kid.lx, kid.ly = x, y
end

local function Acquire(kind, parent)
    local f = tremove(pools[kind])
    if not f then
        f = CreateFrame(kind == "blank" and "Button" or "Frame", nil, holder)
        f.kind = kind
    end
    f:SetParent(parent)
    f:ClearAllPoints()
    f:SetScale(1)
    f:SetAlpha(1)
    f:Show()
    -- a frame from the pool starts bare: what its last piece drew (an icon, a warning, a C piece's tabs) must not show
    -- on this one (the tabs are child frames: they showed as stray "lips" on value pieces, in game 2026-10-06)
    for _, t in pairs(f.texs or {}) do t:Hide() end      -- sparse: icon, live value and warning sit at 30, 31, 50
    for _, fs in pairs(f.fonts or {}) do fs:Hide() end
    for _, t in pairs(f.tabFrames or {}) do t:Hide() end
    f.pooled = nil
    f.kids = {}
    f.piece, f.slot, f.t = nil, nil, nil
    f:EnableMouse(false)
    f:SetScript("OnMouseDown", nil)
    f:SetScript("OnMouseUp", nil)
    f:SetScript("OnEnter", nil)
    f:SetScript("OnLeave", nil)
    if f.SetScript and kind == "blank" then f:SetScript("OnClick", nil) end
    return f
end

-- (once: a frame in the pool twice would be handed to two pieces at once)
function EP:Release(f)
    if not f or not f.kind or f.pooled then return end
    for _, k in ipairs(f.kids or {}) do self:Release(k) end
    f.kids = {}
    f.at, f.blanks = nil, nil
    for _, t in pairs(f.tabFrames or {}) do t:Hide() end
    f:Hide()
    f:ClearAllPoints()
    f:SetParent(holder)
    f.pooled = true
    tinsert(pools[f.kind], f)
end

-- A pooled script frame (DrawScript / Draw) that is out of the pool: drawn and shown somewhere.
function EP:IsDrawn(f)
    return type(f) == "table" and f.kind == "script" and not f.pooled
end

---------------------------------------------------------------------------
-- Shapes
---------------------------------------------------------------------------

local function Shape(t, name, edge)
    local s = SHAPE[name]
    t:SetTexture(ATLAS)
    local x, y = edge and s[3] or s[1], edge and s[4] or s[2]
    t:SetTexCoord(x / 256, (x + s[5]) / 256, y / 256, (y + s[6]) / 256)
    t:SetSize(s[5] / 2, s[6] / 2)
end

local function Paint(t, c, a)
    t:SetVertexColor(c[1], c[2], c[3], a or c[4] or 1)
end

local function Grad(t, top, bottom)
    if t.SetGradient and CreateColor then
        t:SetGradient("VERTICAL", CreateColor(bottom[1], bottom[2], bottom[3], 1), CreateColor(top[1], top[2], top[3], 1))
    else
        t:SetVertexColor((top[1] + bottom[1]) / 2, (top[2] + bottom[2]) / 2, (top[3] + bottom[3]) / 2, 1)
    end
end

-- A flat body with a top light and 1px edges: textures from index n. Returns the next free index.
local function Body(f, n, x, y, w, h, f2, f1, e, opts)
    local body = Tex(f, n, "BACKGROUND", 1)
    body:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
    body:SetSize(w, h)
    Grad(body, f2, f1)
    local hl = Tex(f, n + 1, "BACKGROUND", 2)
    hl:SetPoint("TOPLEFT", f, "TOPLEFT", x + 1, -y - 1)
    hl:SetSize(max(1, w - 2), 1)
    hl:SetVertexColor(1, 1, 1, 0.12)
    local i = n + 2
    local function line(px, py, lw, lh)
        local t = Tex(f, i, "BORDER", 1)
        t:SetPoint("TOPLEFT", f, "TOPLEFT", px, -py)
        t:SetSize(lw, lh)
        Paint(t, e, 0.85)
        i = i + 1
    end
    if not (opts and opts.noTop) then line(x, y, w, 1) end
    if not (opts and opts.noBottom) then line(x, y + h - 1, w, 1) end
    if not (opts and opts.noLeft) then line(x, y, 1, h) end
    if not (opts and opts.noRight) then line(x + w - 1, y, 1, h) end
    return i
end

-- The notch on top (a dark tab shape) at x.
local function Notch(f, n, x, y, e)
    local fill = Tex(f, n, "BORDER", 2)
    Shape(fill, "tab")
    fill:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
    fill:SetVertexColor(0, 0, 0, 0.5)
    local edge = Tex(f, n + 1, "BORDER", 3)
    Shape(edge, "tab", true)
    edge:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
    Paint(edge, e, 0.85)
    return n + 2
end

-- The tab under a piece (over the next piece's notch).
local function TabUnder(f, n, x, y, f1, e)
    local fill = Tex(f, n, "OVERLAY", 1)
    Shape(fill, "tab")
    fill:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(y - 1))
    Paint(fill, f1, 1)
    local edge = Tex(f, n + 1, "OVERLAY", 2)
    Shape(edge, "tab", true)
    edge:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(y - 1))
    Paint(edge, e, 0.85)
    return n + 2
end

---------------------------------------------------------------------------
-- What a blank shows
---------------------------------------------------------------------------

local DROPDOWN = { channel = true, stat = true, stage = true, marker = true, dur = true, var = true, badge = true,
    ctxname = true, varname = true, timer = true }

local function ChoiceLabel(list, v)
    for _, c in ipairs(list or {}) do
        if c[1] == v then return c[2] end
    end
    return nil
end

-- The words a literal blank shows.
function EP:BlankText(t, v, def)
    local Bk = B()
    if v == nil or v == "" then return "" end
    if t == "channel" then return ChoiceLabel(Bk.CHANNELS, v) or tostring(v) end
    if t == "marker" then return ChoiceLabel(Bk.MARKERS, tonumber(v)) or tostring(v) end
    if t == "dur" then return Bk:DurationText(v) end
    if t == "stage" then return def and Bk:StageName(def, v) or tostring(v) end
    if t == "badge" then
        local bd = def and def.badges and def.badges[v]
        return bd and bd.n or tostring(v)
    end
    if t == "block" then return def and Bk:BlockLabel(def, v) or tostring(v) end
    return tostring(v)
end

local function CtxCat(name)
    local c = B().CTX[name]
    if not c then return "pl" end
    if c.t == "player" or c.t == "players" then return "pl" end
    return "pt"
end

---------------------------------------------------------------------------
-- Building a piece
---------------------------------------------------------------------------

local Build    -- (ctx, parent, piece, inBlank) -> frame, w, h

-- The tokens of a piece's sentence: { "words" | slot number ... }.
local tokenCache = {}
local function Tokens(text)
    local t = tokenCache[text]
    if t then return t end
    t = {}
    local pos = 1
    while true do
        local s, e, n = text:find("{(%d)}", pos)
        if not s then break end
        local words = text:sub(pos, s - 1):match("^%s*(.-)%s*$")
        if words ~= "" then t[#t + 1] = words end
        t[#t + 1] = tonumber(n)
        pos = e + 1
    end
    local rest = text:sub(pos):match("^%s*(.-)%s*$")
    if rest ~= "" then t[#t + 1] = rest end
    tokenCache[text] = t
    return t
end
EP.Tokens = Tokens

-- A blank (a well): round (values), a box (typed text, timers), with a caret (dropdowns), or a hexagon (yes / no).
-- Its content: words, or a value piece dropped in, or text with values in it.
-- Every frame drawn goes into ctx.all with its depth (pieces inside a C or a blank are one deeper) and its rank in its
-- stack (earlier pieces higher): Layer() gives them frame levels from that, so a piece's tab covers the next one's
-- notch and what sits inside a piece is above it.
local function Note(ctx, f, depth, isBlank)
    f.depth, f.rank, f.isBlank = depth, ctx.rank or 0, isBlank
    ctx.all[#ctx.all + 1] = f
end

local function BuildBlank(ctx, parent, piece, slot, a, v)
    if type(v) == "table" and v.k then
        -- a value dropped in: the piece itself sits where the blank was (a band above the piece it is in)
        ctx.depth = ctx.depth + 1
        local kid, kw, kh = Build(ctx, parent, v, true)
        ctx.depth = ctx.depth - 1
        return kid, kw, kh
    end
    local f = Acquire("blank", parent)
    tinsert(parent.kids, f)
    Note(ctx, f, ctx.depth, true)
    f.piece, f.slot, f.t = piece, slot, a.t
    local def = ctx.opts.def
    local pd = B().PIECES[piece.k]
    local hot = ctx.opts.hot and ctx.opts.hot.piece == piece and ctx.opts.hot.slot == slot
    local empty = v == nil or (v == "" and a.t ~= "text")
    local required = empty and (a.t == "player" or a.t == "players" or a.t == "bool" or a.t == "stage" or a.t == "badge"
        or a.t == "var" or a.t == "block" or a.t == "num")
    local look = required and NEED or WELL
    local hex = a.t == "bool"
    local box = a.t == "text" or a.t == "timer"
    local h = hex and EP.HEX_H or EP.BLANK_H
    local nt, nf = 1, 0
    local x = hex and 13 or 8
    local w
    -- content
    if type(v) == "table" and v.j then
        -- typed text with values in it
        local parts = 0
        for _, seg in ipairs(v.j) do
            if type(seg) == "table" and seg.k then
                ctx.depth = ctx.depth + 1
                local kid, kw, kh = Build(ctx, f, seg, true)
                ctx.depth = ctx.depth - 1
                Place(kid, f, x, ((hex and EP.HEX_H or EP.BLANK_H) - kh) / 2)
                x = x + kw + 4
                parts = parts + 1
            elseif type(seg) == "string" and seg ~= "" then
                nf = nf + 1
                local fs = Font(f, nf)
                local txt = seg:match("^%s*(.-)%s*$")
                fs:SetText(txt)
                fs:SetPoint("LEFT", f, "LEFT", x, 0)
                Paint(fs, look.text)
                x = x + (fs:GetStringWidth() or 0) + 4
                parts = parts + 1
            end
        end
        x = x - 4 + 8
        if parts == 0 then x = 34 end
    else
        local text = EP:BlankText(a.t, v, def)
        if text ~= "" then
            nf = nf + 1
            local fs = Font(f, nf)
            fs:SetText(text)
            fs:SetPoint("LEFT", f, "LEFT", x, 0)
            Paint(fs, look.text)
            x = x + (fs:GetStringWidth() or 0)
        else
            x = x + (hex and 18 or 12)
        end
        if DROPDOWN[a.t] and a.t ~= "timer" then
            local caret = Tex(f, 40, "OVERLAY", 3)
            caret:SetTexture(UI().ICON_ATLAS)
            local c = UI():IconCoords(14)
            caret:SetTexCoord(c[1], c[2], c[3], c[4])
            caret:SetSize(9, 9)
            caret:SetPoint("LEFT", f, "LEFT", x + 3, 0)
            caret:SetVertexColor(1, 1, 1, 0.7)
            x = x + 12
        else
            if f.texs and f.texs[40] then f.texs[40]:Hide() end
        end
        x = x + (hex and 13 or 8)
    end
    w = max(hex and 36 or 22, x)
    if box and a.t == "text" then
        -- quotes around typed text
        nf = nf + 1
        local q1 = Font(f, nf)
        q1:SetText("\226\128\156")
        q1:SetTextColor(1, 1, 1, 0.45)
        q1:SetPoint("LEFT", f, "LEFT", 2, 0)
        nf = nf + 1
        local q2 = Font(f, nf)
        q2:SetText("\226\128\157")
        q2:SetTextColor(1, 1, 1, 0.45)
        q2:SetPoint("RIGHT", f, "RIGHT", -2, 0)
    end
    f:SetSize(w, h)
    -- the well
    local fill, edge = look.fill, hot and HOT or look.edge
    if ctx.opts.liveSlots and ctx.opts.liveSlots[piece] == slot then fill, edge = LIVE.fill, LIVE.edge end
    if hex then
        local cat = pd and B().CAT[pd.cat]
        local pe = cat and cat.e
        local L, R = Tex(f, 1, "BACKGROUND", 1), Tex(f, 2, "BACKGROUND", 1)
        Shape(L, "hexL"); Shape(R, "hexR")
        L:SetPoint("LEFT", f, "LEFT", 0, 0); R:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        Paint(L, fill); Paint(R, fill)
        local mid = Tex(f, 3, "BACKGROUND", 1)
        mid:SetPoint("TOPLEFT", f, "TOPLEFT", 10, 0)
        mid:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 0)
        Paint(mid, fill)
        local eL, eR = Tex(f, 4, "BORDER", 1), Tex(f, 5, "BORDER", 1)
        Shape(eL, "hexL", true); Shape(eR, "hexR", true)
        eL:SetPoint("LEFT", f, "LEFT", 0, 0); eR:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        local ec = hot and HOT or (required and NEED.edge) or { (pe or edge)[1], (pe or edge)[2], (pe or edge)[3], 0.75 }
        Paint(eL, ec); Paint(eR, ec)
        local t1, t2 = Tex(f, 6, "BORDER", 1), Tex(f, 7, "BORDER", 1)
        t1:SetPoint("TOPLEFT", f, "TOPLEFT", 10, 0); t1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, 0); t1:SetHeight(1)
        t2:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 0); t2:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 0); t2:SetHeight(1)
        Paint(t1, ec); Paint(t2, ec)
        nt = 7
    elseif box then
        local mid = Tex(f, 1, "BACKGROUND", 1)
        mid:SetAllPoints()
        Paint(mid, fill)
        nt = 1
        for i, p in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
            { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
            local t = Tex(f, 1 + i, "BORDER", 1)
            t:SetPoint(p[1]); t:SetPoint(p[2])
            if p[3] then t:SetHeight(1) else t:SetWidth(1) end
            Paint(t, edge)
            nt = 1 + i
        end
    else
        local L, R = Tex(f, 1, "BACKGROUND", 1), Tex(f, 2, "BACKGROUND", 1)
        Shape(L, "rndL"); Shape(R, "rndR")
        L:SetPoint("LEFT", f, "LEFT", 0, 0); R:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        Paint(L, fill); Paint(R, fill)
        local mid = Tex(f, 3, "BACKGROUND", 1)
        mid:SetPoint("TOPLEFT", f, "TOPLEFT", 10, 0)
        mid:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 0)
        Paint(mid, fill)
        local eL, eR = Tex(f, 4, "BORDER", 1), Tex(f, 5, "BORDER", 1)
        Shape(eL, "rndL", true); Shape(eR, "rndR", true)
        eL:SetPoint("LEFT", f, "LEFT", 0, 0); eR:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        Paint(eL, edge); Paint(eR, edge)
        local t1, t2 = Tex(f, 6, "BORDER", 1), Tex(f, 7, "BORDER", 1)
        t1:SetPoint("TOPLEFT", f, "TOPLEFT", 10, 0); t1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, 0); t1:SetHeight(1)
        t2:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 0); t2:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 0); t2:SetHeight(1)
        Paint(t1, edge); Paint(t2, edge)
        nt = 7
    end
    -- keep the caret (texture 40) when used
    for i = nt + 1, #(f.texs or {}) do
        if i ~= 40 or not (DROPDOWN[a.t] and a.t ~= "timer" and not (type(v) == "table")) then f.texs[i]:Hide() end
    end
    for i = nf + 1, #(f.fonts or {}) do f.fonts[i]:Hide() end
    -- clicks
    if not ctx.opts.static then
        f:EnableMouse(true)
        f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        f:SetScript("OnClick", function(self, button)
            if ctx.opts.onBlank then ctx.opts.onBlank(piece, slot, self, button) end
        end)
        f:SetScript("OnEnter", function(self)
            if self.hl then self.hl:Show() end
        end)
        f:SetScript("OnLeave", function(self)
            if self.hl then self.hl:Hide() end
        end)
        if not f.hl then
            f.hl = f:CreateTexture(nil, "HIGHLIGHT")
            f.hl:SetTexture(WHITE)
            f.hl:SetVertexColor(1, 1, 1, 0.06)
            f.hl:SetAllPoints()
        end
    end
    ctx.blanks[#ctx.blanks + 1] = { piece = piece, slot = slot, frame = f, t = a.t }
    return f, w, h
end

-- A value (round) or yes / no (hexagon) piece.
local function BuildValue(ctx, parent, p, pd)
    local f = Acquire("piece", parent)
    tinsert(parent.kids, f)
    Note(ctx, f, ctx.depth, false)
    f.piece = p
    ctx.at[p] = f
    local hex = pd.shape == "bool"
    local cat = pd.cat
    if p.k == "ctx" then cat = CtxCat(p.a and p.a[1]) end
    if p.k == "var" then cat = "pt" end
    local c = B().CAT[cat] or B().CAT.pl
    local h = hex and EP.HEX_H or EP.BLANK_H
    local x = hex and 13 or 8
    local nf = 0
    local def = ctx.opts.def
    if p.k == "ctx" or p.k == "var" then
        local name = p.a and p.a[1]
        local label = p.k == "ctx" and (B().CTX[name] and B().CTX[name].label or tostring(name)) or tostring(name or "?")
        nf = nf + 1
        local fs = Font(f, nf)
        fs:SetText(label)
        fs:SetPoint("LEFT", f, "LEFT", x, 0)
        x = x + (fs:GetStringWidth() or 0)
        local live = ctx.opts.live
        if p.k == "ctx" and live and live[name] ~= nil then
            local val = live[name]
            local nameOf = ctx.opts.nameOf
            local text
            if type(val) == "table" and val.list then
                local names = {}
                for i = 1, #val do names[i] = nameOf and nameOf(val[i]) or tostring(val[i]) end
                text = table.concat(names, ", ")
            elseif type(val) == "string" and val:find("%-") and nameOf then
                text = nameOf(val)
            else
                text = tostring(val)
            end
            local sep = Tex(f, 30, "OVERLAY", 1)
            sep:SetSize(1, h - 6)
            sep:SetPoint("LEFT", f, "LEFT", x + 6, 0)
            sep:SetVertexColor(1, 1, 1, 0.2)
            nf = nf + 1
            local fv = Font(f, nf)
            fv:SetText(text)
            fv:SetTextColor(1, 0.9, 0.5)
            fv:SetPoint("LEFT", f, "LEFT", x + 12, 0)
            x = x + 12 + (fv:GetStringWidth() or 0)
            f.liveOn = true
        else
            f.liveOn = nil
            if f.texs and f.texs[30] then f.texs[30]:Hide() end
        end
    else
        if f.texs and f.texs[31] then f.texs[31]:Hide() end
        for _, tok in ipairs(Tokens(pd.text)) do
            if type(tok) == "number" then
                local a = pd.args[tok]
                local v = p.a and p.a[tok]
                if a and a.t == "block" then
                    -- the block's name in the value's own words ("Bracket champion"), its icon in front
                    local sm = v and def and def.blocks and def.blocks[v]
                    if sm and B().SMART[sm.kind] then
                        local ic = Tex(f, 31, "OVERLAY", 1)
                        ic:SetTexture(B().SMART[sm.kind].icon)
                        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        ic:SetSize(13, 13)
                        ic:SetPoint("LEFT", f, "LEFT", x - 2, 0)
                        x = x + 14
                    end
                    nf = nf + 1
                    local fs = Font(f, nf)
                    fs:SetText(def and B():BlockLabel(def, v) or "Bracket")
                    fs:SetPoint("LEFT", f, "LEFT", x, 0)
                    x = x + (fs:GetStringWidth() or 0) + EP.GAP
                else
                    local kid, kw = BuildBlank(ctx, f, p, tok, a or { t = "any" }, v)
                    Place(kid, f, x, (h - (kid:GetHeight() or EP.BLANK_H)) / 2)
                    x = x + kw + EP.GAP
                end
            else
                nf = nf + 1
                local fs = Font(f, nf)
                fs:SetText(tok)
                fs:SetPoint("LEFT", f, "LEFT", x, 0)
                x = x + (fs:GetStringWidth() or 0) + EP.GAP
            end
        end
        x = x - EP.GAP
        if f.texs and f.texs[30] then f.texs[30]:Hide() end
    end
    x = x + (hex and 13 or 8)
    local w = max(hex and 40 or 26, x)
    f:SetSize(w, h)
    -- the shape: ends and a middle, filled and edged in the category's colours
    local L, R = Tex(f, 1, "BACKGROUND", 1), Tex(f, 2, "BACKGROUND", 1)
    Shape(L, hex and "hexL" or "rndL"); Shape(R, hex and "hexR" or "rndR")
    L:SetPoint("LEFT", f, "LEFT", 0, 0); R:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    Grad(L, c.f2, c.f); Grad(R, c.f2, c.f)
    local mid = Tex(f, 3, "BACKGROUND", 1)
    mid:SetPoint("TOPLEFT", f, "TOPLEFT", 10, 0)
    mid:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 0)
    Grad(mid, c.f2, c.f)
    local eL, eR = Tex(f, 4, "BORDER", 1), Tex(f, 5, "BORDER", 1)
    Shape(eL, hex and "hexL" or "rndL", true); Shape(eR, hex and "hexR" or "rndR", true)
    eL:SetPoint("LEFT", f, "LEFT", 0, 0); eR:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    local ec = f.liveOn and LIVE.edge or c.e
    Paint(eL, ec, 0.85); Paint(eR, ec, 0.85)
    local t1, t2 = Tex(f, 6, "BORDER", 1), Tex(f, 7, "BORDER", 1)
    t1:SetPoint("TOPLEFT", f, "TOPLEFT", 10, 0); t1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, 0); t1:SetHeight(1)
    t2:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 0); t2:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 0); t2:SetHeight(1)
    Paint(t1, ec, 0.85); Paint(t2, ec, 0.85)
    for i = 8, #(f.texs or {}) do
        if not ((i == 30 and f.liveOn) or (i == 31 and f.texs[31]:IsShown())) then f.texs[i]:Hide() end
    end
    for i = nf + 1, #(f.fonts or {}) do f.fonts[i]:Hide() end
    EP:Interact(ctx, f, p)
    EP:Mark(ctx, f, p)
    return f, w, h
end

-- Mouse on a piece: the builder's drag and right-click.
function EP:Interact(ctx, f, p)
    if ctx.opts.static then return end
    f:EnableMouse(true)
    f:SetScript("OnMouseDown", function(self, button)
        if ctx.opts.onPiece then ctx.opts.onPiece(p, self, button, true) end
    end)
    f:SetScript("OnMouseUp", function(self, button)
        if ctx.opts.onPiece then ctx.opts.onPiece(p, self, button, false) end
    end)
end

-- A problem's warning (and its tooltip), or the lock of a built-in script.
function EP:Mark(ctx, f, p)
    local prob = ctx.opts.problems and ctx.opts.problems[p]
    if prob then
        local w = Tex(f, 50, "OVERLAY", 7)
        w:SetTexture(UI().ICON_WARN or "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
        w:SetSize(16, 16)
        w:SetPoint("CENTER", f, "TOPRIGHT", -2, -2)
        f.problem = prob
        if not ctx.opts.static then
            f:SetScript("OnEnter", function(self)
                if not self.problem then return end
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(self.problem, 1, 0.69, 0.4, true)
                GameTooltip:Show()
            end)
            f:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
    else
        f.problem = nil
        if f.texs and f.texs[50] then f.texs[50]:Hide() end
    end
end

-- The words and blanks of a stack / hat / cap / C header row, from x. Returns the row's width.
local function Row(ctx, f, p, pd, x, cy)
    local nf = 0
    local first = true
    for _, tok in ipairs(Tokens(pd.text)) do
        if type(tok) == "number" then
            local a = pd.args[tok] or { t = "any" }
            local v = p.a and p.a[tok]
            local kid, kw
            if a.t == "block" and v and ctx.opts.def and ctx.opts.def.blocks and ctx.opts.def.blocks[v] then
                -- a smart block named in a sentence: its value pill (icon + name)
                local blk = ctx.opts.def.blocks[v]
                kid = Acquire("piece", f)
                tinsert(f.kids, kid)
                Note(ctx, kid, ctx.depth, true)
                local c = B().CAT.sm
                local ic = Tex(kid, 31, "OVERLAY", 1)
                ic:SetTexture(B().SMART[blk.kind].icon)
                ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                ic:SetSize(13, 13)
                ic:SetPoint("LEFT", kid, "LEFT", 5, 0)
                local fs = Font(kid, 1)
                fs:SetText(B():BlockLabel(ctx.opts.def, v))
                fs:SetPoint("LEFT", kid, "LEFT", 21, 0)
                kw = 21 + (fs:GetStringWidth() or 0) + 8
                kid:SetSize(kw, EP.BLANK_H)
                local L, R = Tex(kid, 1, "BACKGROUND", 1), Tex(kid, 2, "BACKGROUND", 1)
                Shape(L, "rndL"); Shape(R, "rndR")
                L:SetPoint("LEFT", kid, "LEFT", 0, 0); R:SetPoint("RIGHT", kid, "RIGHT", 0, 0)
                Grad(L, c.f2, c.f); Grad(R, c.f2, c.f)
                local mid = Tex(kid, 3, "BACKGROUND", 1)
                mid:SetPoint("TOPLEFT", kid, "TOPLEFT", 10, 0)
                mid:SetPoint("BOTTOMRIGHT", kid, "BOTTOMRIGHT", -10, 0)
                Grad(mid, c.f2, c.f)
                local eL, eR = Tex(kid, 4, "BORDER", 1), Tex(kid, 5, "BORDER", 1)
                Shape(eL, "rndL", true); Shape(eR, "rndR", true)
                eL:SetPoint("LEFT", kid, "LEFT", 0, 0); eR:SetPoint("RIGHT", kid, "RIGHT", 0, 0)
                Paint(eL, c.e, 0.85); Paint(eR, c.e, 0.85)
                local t1, t2 = Tex(kid, 6, "BORDER", 1), Tex(kid, 7, "BORDER", 1)
                t1:SetPoint("TOPLEFT", kid, "TOPLEFT", 10, 0); t1:SetPoint("TOPRIGHT", kid, "TOPRIGHT", -10, 0); t1:SetHeight(1)
                t2:SetPoint("BOTTOMLEFT", kid, "BOTTOMLEFT", 10, 0); t2:SetPoint("BOTTOMRIGHT", kid, "BOTTOMRIGHT", -10, 0)
                t2:SetHeight(1)
                Paint(t1, c.e, 0.85); Paint(t2, c.e, 0.85)
                for i = 8, #(kid.texs or {}) do if i ~= 31 then kid.texs[i]:Hide() end end
                for i = 2, #(kid.fonts or {}) do kid.fonts[i]:Hide() end
                -- it is still a blank: a click picks another block of that kind
                if not ctx.opts.static then
                    kid:EnableMouse(true)
                    kid:SetScript("OnMouseUp", function(self, button)
                        if ctx.opts.onBlank then ctx.opts.onBlank(p, tok, self, button) end
                    end)
                end
                ctx.blanks[#ctx.blanks + 1] = { piece = p, slot = tok, frame = kid, t = "block" }
            else
                kid, kw = BuildBlank(ctx, f, p, tok, a, v)
            end
            Place(kid, f, x, cy - (kid:GetHeight() or EP.BLANK_H) / 2)
            x = x + kw + EP.GAP
        else
            nf = nf + 1
            local fs = Font(f, nf)
            local word = tok
            -- "when" / "every" in a hat: a little dimmer, like Scratch's event words
            if first and pd.shape == "hat" then
                local w1, rest = word:match("^(%S+)%s+(.+)$")
                if w1 == "when" or w1 == "every" or (not rest and (word == "when" or word == "every")) then
                    fs:SetText(w1 or word)
                    fs:SetTextColor(1, 1, 1, 0.72)
                    fs:SetPoint("LEFT", f, "TOPLEFT", x, -cy)
                    x = x + (fs:GetStringWidth() or 0) + 4
                    if rest then
                        nf = nf + 1
                        fs = Font(f, nf)
                        word = rest
                    else
                        word = nil
                    end
                end
            end
            if word then
                fs:SetText(word)
                fs:SetPoint("LEFT", f, "TOPLEFT", x, -cy)
                x = x + (fs:GetStringWidth() or 0) + EP.GAP
            end
        end
        first = false
    end
    return x - EP.GAP, nf
end

-- A stack, hat or cap piece (or a C piece's frame with its arms): its body, words, blanks, and the pieces inside.
local BuildStackFrom   -- (ctx, parent, p, x, y) -> height of the stack drawn at x, y of parent

-- A tab that must sit above other pieces (a C piece's tab into its arm covers the first inside piece's notch): a small
-- child frame one band deeper, at the top of that band.
local function TabFrame(ctx, f, i, x, y, c)
    f.tabFrames = f.tabFrames or {}
    local t = f.tabFrames[i]
    if not t then
        t = CreateFrame("Frame", nil, f)
        t.fill = t:CreateTexture(nil, "OVERLAY", nil, 1)
        t.edge = t:CreateTexture(nil, "OVERLAY", nil, 2)
        f.tabFrames[i] = t
    end
    t:ClearAllPoints()
    t:SetSize(20, 6)
    t:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(y - 1))
    Shape(t.fill, "tab")
    t.fill:SetPoint("TOPLEFT")
    Paint(t.fill, c.f, 1)
    Shape(t.edge, "tab", true)
    t.edge:SetPoint("TOPLEFT")
    Paint(t.edge, c.e, 0.85)
    t:Show()
    t.depth, t.rank, t.isBlank, t.top = ctx.depth + 1, 0, false, true
    ctx.all[#ctx.all + 1] = t
    return t
end

local function BuildBlock(ctx, parent, p, pd)
    local f = Acquire("piece", parent)
    tinsert(parent.kids, f)
    Note(ctx, f, ctx.depth, false)
    f.piece = p
    ctx.at[p] = f
    for _, t in ipairs(f.tabFrames or {}) do t:Hide() end
    local c = B().CAT[pd.cat] or B().CAT.sm
    local shape = pd.shape
    local hat = shape == "hat"
    local top = hat and EP.DOME or 0
    local headH = hat and EP.HAT_H or EP.H
    local x0 = EP.PAD
    local rowW, nf = Row(ctx, f, p, pd, x0, top + headH / 2 + (hat and 1 or 0))
    local headW = max(hat and 90 or 50, rowW + EP.PAD)
    if ctx.opts.locked and hat then headW = headW + 12 end
    local w, h = headW, top + headH
    local n = 1
    if shape == "c" or shape == "c2" then
        -- header, arm(s) with the pieces inside, (else bar, arm), foot
        local y = top + headH
        local innerW = 0
        local rank = ctx.rank
        ctx.depth = ctx.depth + 1
        local inH1 = BuildStackFrom(ctx, f, p.c1, EP.ARM, y)
        if not p.c1 then inH1 = 26 end
        innerW = max(innerW, EP.ARM + (ctx.lastW or 0))
        y = y + inH1
        local midY, inH2
        if shape == "c2" then
            midY = y
            y = y + EP.MID
            inH2 = BuildStackFrom(ctx, f, p.c2, EP.ARM, y)
            if not p.c2 then inH2 = 26 end
            innerW = max(innerW, EP.ARM + (ctx.lastW or 0))
            y = y + inH2
        end
        ctx.depth = ctx.depth - 1
        ctx.rank = rank
        local footY = y
        h = footY + EP.FOOT
        w = max(headW, innerW)
        -- header body (its bottom-left joins the arm)
        n = Body(f, n, 0, top, headW, headH, c.f2, c.f, c.e, { noBottom = true })
        local hb = Tex(f, n, "BORDER", 1)       -- the header's bottom edge, right of the arm
        hb:SetPoint("TOPLEFT", f, "TOPLEFT", EP.ARM - 1, -(top + headH - 1))
        hb:SetSize(headW - EP.ARM + 1, 1)
        Paint(hb, c.e, 0.85)
        n = n + 1
        -- arm(s)
        local function arm(y1, y2)
            local a = Tex(f, n, "BACKGROUND", 1)
            a:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y1)
            a:SetSize(EP.ARM, y2 - y1)
            Paint(a, c.f)
            local l = Tex(f, n + 1, "BORDER", 1)
            l:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y1)
            l:SetSize(1, y2 - y1)
            Paint(l, c.e, 0.85)
            local r = Tex(f, n + 2, "BORDER", 1)
            r:SetPoint("TOPLEFT", f, "TOPLEFT", EP.ARM - 1, -y1)
            r:SetSize(1, y2 - y1)
            Paint(r, c.e, 0.85)
            n = n + 3
        end
        arm(top + headH, top + headH + inH1)
        if shape == "c2" then
            n = Body(f, n, 0, midY, EP.FOOT_W, EP.MID, c.f2, c.f, c.e, { noLeft = false })
            local fs = Font(f, nf + 1)
            nf = nf + 1
            fs:SetText("else")
            fs:SetPoint("LEFT", f, "TOPLEFT", EP.PAD, -(midY + EP.MID / 2))
            -- hide the else bar's left edge where the arms meet it
            arm(midY + EP.MID, midY + EP.MID + inH2)
        end
        n = Body(f, n, 0, footY, EP.FOOT_W, EP.FOOT, c.f2, c.f, c.e)
        -- the tabs into the arm(s) (over the first inside piece) and under the foot
        TabFrame(ctx, f, 1, EP.ARM + EP.TAB_X, top + headH, c)
        if shape == "c2" then TabFrame(ctx, f, 2, EP.ARM + EP.TAB_X, midY + EP.MID, c) end
        if not ctx.opts.noTab then n = TabUnder(f, n, EP.TAB_X, h, c.f, c.e) end
        n = Notch(f, n, EP.TAB_X, top, c.e)
    else
        n = Body(f, n, 0, top, w, headH, c.f2, c.f, c.e, hat and { noTop = true } or nil)
        if hat then
            -- the top edge right of the dome (the dome draws its own)
            local te = Tex(f, n, "BORDER", 1)
            te:SetPoint("TOPLEFT", f, "TOPLEFT", 79, -top)
            te:SetSize(max(1, w - 79), 1)
            Paint(te, c.e, 0.85)
            n = n + 1
            local dome = Tex(f, n, "BACKGROUND", 3)
            Shape(dome, "dome")
            dome:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
            dome:SetSize(80, 12)
            Paint(dome, c.f2)
            local de = Tex(f, n + 1, "BORDER", 2)
            Shape(de, "dome", true)
            de:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
            de:SetSize(80, 12)
            Paint(de, c.e, 0.85)
            n = n + 2
        else
            n = Notch(f, n, EP.TAB_X, 0, c.e)
        end
        if shape ~= "cap" then n = TabUnder(f, n, EP.TAB_X, top + headH, c.f, c.e) end
        if ctx.opts.locked and hat then
            local lk = Tex(f, n, "OVERLAY", 6)
            lk:SetTexture(UI().ICON_ATLAS)
            local cc = UI():IconCoords(UI().ICON.lock or 12)
            lk:SetTexCoord(cc[1], cc[2], cc[3], cc[4])
            lk:SetSize(11, 11)
            lk:SetPoint("RIGHT", f, "TOPLEFT", w - 6, -(top + headH / 2))
            lk:SetVertexColor(0.91, 0.77, 0.35)
            n = n + 1
        end
    end
    f:SetSize(w, h)
    Trim(f, n - 1, nf)
    -- keep the warning mark's texture index free (Mark puts it at 50)
    EP:Interact(ctx, f, p)
    EP:Mark(ctx, f, p)
    return f, w, h
end

Build = function(ctx, parent, p, inBlank)
    local pd = B().PIECES[p.k]
    if not pd then
        -- a piece from a newer version: a grey stack piece naming its key
        pd = { cat = "sm", shape = inBlank and "value" or "stack", text = p.k, args = {} }
    end
    if pd.shape == "value" or pd.shape == "bool" or p.k == "ctx" or p.k == "var" then
        return BuildValue(ctx, parent, p, pd)
    end
    return BuildBlock(ctx, parent, p, pd)
end

-- Draws the stack starting at p (p, p.n, ...) inside parent at x, y; returns its height (ctx.lastW = its width).
-- Pieces abut: the next one starts where this one's body ends (its tab reaches into the next one's notch).
BuildStackFrom = function(ctx, parent, p, x, y)
    local h, w = 0, 0
    local count, q = 0, p
    while q do count = count + 1; q = q.n end
    local i = 0
    while p do
        i = i + 1
        ctx.rank = count - i          -- earlier pieces above later ones
        local f, fw, fh = Build(ctx, parent, p, false)
        Place(f, parent, x, y + h)
        h = h + fh
        w = max(w, fw)
        p = p.n
    end
    ctx.lastW = w
    return h
end

-- Frame levels for everything drawn: one band of 100 per depth, rank * 2 inside it, blanks one above their piece,
-- C tabs at the top of the band they reach into.
local function Layer(ctx, base)
    for _, f in ipairs(ctx.all) do
        local lvl = base + (f.depth or 0) * 100 + min(45, f.rank or 0) * 2 + (f.isBlank and 1 or 0)
        if f.top then lvl = base + (f.depth or 0) * 100 + 99 end
        f:SetFrameLevel(min(9000, lvl))
    end
end

local function NewCtx(opts)
    return { opts = opts or {}, at = {}, blanks = {}, all = {}, depth = 0, rank = 0 }
end

-- A whole script (its top piece and everything under it). frame.at[piece], frame.blanks, frame.w, frame.h.
function EP:DrawScript(parent, top, opts)
    local ctx = NewCtx(opts)
    local f = Acquire("script", parent)
    local h = BuildStackFrom(ctx, f, top, 0, 0)
    local w = ctx.lastW or 0
    f:SetSize(max(1, w), max(1, h))
    f.at, f.blanks, f.w, f.h = ctx.at, ctx.blanks, w, h
    f.ctx = ctx
    Layer(ctx, (f:GetFrameLevel() or 1) + 1)
    return f
end

-- Re-levels a script drawn earlier above a new base (the canvas raises the script being dragged).
function EP:Raise(f, base)
    if f.ctx then
        f:SetFrameLevel(base)
        Layer(f.ctx, base + 1)
    end
end

-- One piece, as in the palette or a review row: no tab under it unless it is part of a stack.
function EP:Draw(parent, piece, opts)
    opts = opts or {}
    local ctx = NewCtx(opts)
    local f = Acquire("script", parent)
    local p = piece
    if p.n then
        -- the piece alone (not what follows it)
        p = {}
        for k, v in pairs(piece) do p[k] = v end
        p.n = nil
    end
    local kid, w, h = Build(ctx, f, p, false)
    kid:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f:SetSize(max(1, w), max(1, h + 6))
    f.at, f.blanks, f.w, f.h = ctx.at, ctx.blanks, w, h
    f.ctx = ctx
    Layer(ctx, (f:GetFrameLevel() or 1) + 1)
    if opts.scale then f:SetScale(opts.scale) end
    return f
end

-- Where a drawn piece / blank sits in its script frame: x, y (y down) of its top-left.
function EP:Abs(f)
    local x, y = 0, 0
    while f and f.kind ~= "script" do
        x, y = x + (f.lx or 0), y + (f.ly or 0)
        f = f:GetParent()
    end
    return x, y
end

-- The height a piece's own row adds (for the drop targets): hats count their dome.
function EP:HeightOf(piece)
    local pd = B().PIECES[piece.k]
    if not pd then return EP.H end
    if pd.shape == "hat" then return EP.DOME + EP.HAT_H end
    return EP.H
end

function EP:OnInit() end
