if DisasterZoneBoot and DisasterZoneBoot.Run("UI/EventPieces.lua", ...) then return end -- DisasterZone: draws event pieces.
-- Draws the event builder's pieces (Core/EventBlocks.lua) as frames, the Scratch way: a "when" piece wears a cap,
-- stack pieces have a notch on top and a tab under them, C pieces hold others in their arm, yes / no pieces are
-- hexagons and values are round. Words come from the catalogue (WC3's sentences); blanks are dark wells that take a
-- value, a typed text or a dropdown's choice (an empty one says what it takes: "player", "tag"); a tag or a place
-- picked shows as its chip (a tag's colour dot, a place's ring, and the name), and so does "players with tag ...".
-- The shapes are tinted textures of Media/Events/pieces.tga (dev/generators/gen_event_media.py, SHAPE below); bodies
-- are flat fills with a soft top light and 1px edges.
--
-- EP:DrawScript(parent, top, opts) -> frame: a whole stack (frame.at[piece] = the piece's frame, frame.blanks = list of
-- { piece, slot, frame, t }). EP:Draw(parent, piece, opts): one piece (with its insides, without what follows it).
-- EP:Release(frame) gives the frames back to the pools. opts: problems = { [piece] = text }, live = { ctx values }
-- (a practice run's last values, shown in the round pieces), hot = { piece, slot } (a blank being edited), locked
-- (a lock on the hat), static (no mouse), def (names of stages / blocks / badges / definitions),
-- onPiece(piece, frame, button, down), onBlank(piece, slot, blankFrame, button), onHover(piece, slot, blankFrame, on)
-- (the mouse over a blank, or off it), nameOf(key), wrap (EP:Draw: the piece's words in lines no wider than this:
-- the palette's column; a canvas piece is always one line).
local addonName, ns = ...

local EP = ns:NewModule("EventPieces")

local CreateFrame = CreateFrame
local floor, max, min = math.floor, math.max, math.min
local tinsert, tremove = table.insert, table.remove

local ATLAS = "Interface\\AddOns\\DisasterZone\\Media\\Events\\pieces"
local RING = "Interface\\AddOns\\DisasterZone\\Media\\Events\\ring"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
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
EP.FONT_SIZE = ns.Style.FONT.body       -- 11
EP.LINE_H = 19      -- a line of words and blanks when a piece takes more than one (the palette)
EP.LINE_GAP = 4
local spaceW        -- between two words of one sentence part drawn apart (a piece on two lines): a space's width

local function B() return ns.EventBlocks end
local function UI() return ns.UI end
local St = ns.Style

-- The pieces' own looks (a blank that needs a value, a dark well, a practice run's live value); the blank being
-- edited is edged in the design gold.
local NEED = { fill = { 1, 0.55, 0.10, 0.16 }, edge = { 1, 0.59, 0.16, 0.95 }, text = { 1, 0.83, 0.64 } }
local WELL = { fill = { 0.03, 0.03, 0.04, 0.62 }, edge = { 1, 1, 1, 0.16 }, text = { 1, 1, 1 } }
local HOT = { St.C.GOLD[1], St.C.GOLD[2], St.C.GOLD[3], 0.95 }
local LIVE = { fill = { 1, 0.94, 0.67, 0.16 }, edge = { 1, 0.9, 0.55, 0.85 }, text = { 1, 0.97, 0.84 } }

---------------------------------------------------------------------------
-- Pools
---------------------------------------------------------------------------

local holder = CreateFrame("Frame")
holder:Hide()
local pools = { piece = {}, blank = {}, script = {} }

-- A text's whole width on one line (UI:TextWidth: GetStringWidth stops at a width the string was given).
local function SW(fs) return UI():TextWidth(fs) end
EP.TextWidth = SW

-- The i-th extra texture / font string of a frame (made on first use, hidden when not used).
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
        UI():SetTextStyle(fs, EP.FONT_SIZE, WELL.text)
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 0.85)
        f.fonts[i] = fs
    end
    fs:ClearAllPoints()
    fs:SetTextColor(1, 1, 1, 1)
    fs:Show()
    return fs
end

-- What one piece's drawing uses of its frame's textures and fonts: kit.tex(i, layer, sub), kit.font(); kit.done()
-- hides the rest (a frame from the pool keeps what its last piece drew).
local function Kit(f)
    local k = { used = {}, nf = 0 }
    function k.tex(i, layer, sub)
        k.used[i] = true
        return Tex(f, i, layer, sub)
    end
    function k.font()
        k.nf = k.nf + 1
        return Font(f, k.nf)
    end
    function k.done()
        for i, t in pairs(f.texs or {}) do
            if not k.used[i] then t:Hide() end
        end
        for i = k.nf + 1, #(f.fonts or {}) do f.fonts[i]:Hide() end
    end
    return k
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
    for _, h in ipairs(f.hits or {}) do h:Hide() end
    f.pooled = nil
    f.kids = {}
    f.piece, f.slot, f.t = nil, nil, nil
    f.headW, f.headH, f.midY = nil, nil, nil     -- (a C piece's, from its last life: a value drawn on it has none)
    f.problem = nil
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

-- A texture shows a shape of the atlas (its edge, or its fill), or rows y0..y1 of it (texture px of the shape).
local function Shape(t, name, edge, y0, y1)
    local s = SHAPE[name]
    t:SetTexture(ATLAS)
    local x, y = edge and s[3] or s[1], edge and s[4] or s[2]
    y0, y1 = y0 or 0, y1 or s[6]
    t:SetTexCoord(x / 256, (x + s[5]) / 256, (y + y0) / 256, (y + y1) / 256)
    t:SetSize(s[5] / 2, (y1 - y0) / 2)
end

local function Paint(t, c, a)
    t:SetVertexColor(c[1], c[2], c[3], a or c[4] or 1)
end

-- (a vertical gradient over a shape of the atlas: UI:Gradient would swap the shape for a flat texture)
-- TODO(refactor): move into UI:Gradient (an option that keeps the texture under the gradient)
local function Grad(t, top, bottom)
    if t.SetGradient and CreateColor then
        t:SetGradient("VERTICAL", CreateColor(bottom[1], bottom[2], bottom[3], 1), CreateColor(top[1], top[2], top[3], 1))
    else
        t:SetVertexColor((top[1] + bottom[1]) / 2, (top[2] + bottom[2]) / 2, (top[3] + bottom[3]) / 2, 1)
    end
end

local function Mix(a, b, k) return { a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k } end

-- The part of a top -> bottom fill between ya and yb of a shape h high.
local function GradSpan(t, top, bottom, ya, yb, h)
    Grad(t, Mix(top, bottom, ya / h), Mix(top, bottom, yb / h))
end

-- A round shape over the whole w x h of f (a value, a well, a chip): its two ends and its middle, filled (top, bottom:
-- a fill that lights up toward the top; bottom nil: one colour with its alpha) and edged. Textures 1-7; a shape
-- taller than one line takes its ends' halves with straight sides between (textures 8-15).
local function Round(k, f, w, h, top, bottom, edge, ea)
    local function fill(t, ya, yb)
        if bottom then GradSpan(t, top, bottom, ya, yb, h) else Paint(t, top) end
    end
    local tall = h > EP.BLANK_H + 1
    for side = 1, 2 do
        local name = side == 1 and "rndL" or "rndR"
        local anchor = side == 1 and "LEFT" or "RIGHT"
        local F, E = k.tex(side, "BACKGROUND", 1), k.tex(3 + side, "BORDER", 1)
        if not tall then
            Shape(F, name); Shape(E, name, true)
            F:SetSize(10, h); E:SetSize(10, h)
            F:SetPoint(anchor, f, anchor, 0, 0); E:SetPoint(anchor, f, anchor, 0, 0)
            fill(F, 0, h)
            Paint(E, edge, ea)
        else
            -- top half, the middle row stretched, bottom half
            local half = 9
            local base = side == 1 and 8 or 12
            local parts = { { F, E, 0, 18, 0, half }, { k.tex(base, "BACKGROUND", 1), k.tex(base + 1, "BORDER", 1), 18, 20, half, h - half },
                { k.tex(base + 2, "BACKGROUND", 1), k.tex(base + 3, "BORDER", 1), 20, 38, h - half, h } }
            for _, pt in ipairs(parts) do
                local pf, pe, ty0, ty1, ya, yb = pt[1], pt[2], pt[3], pt[4], pt[5], pt[6]
                Shape(pf, name, false, ty0, ty1); Shape(pe, name, true, ty0, ty1)
                pf:SetSize(10, yb - ya); pe:SetSize(10, yb - ya)
                local p1 = side == 1 and "TOPLEFT" or "TOPRIGHT"
                pf:SetPoint(p1, f, p1, 0, -ya); pe:SetPoint(p1, f, p1, 0, -ya)
                fill(pf, ya, yb)
                Paint(pe, edge, ea)
            end
        end
    end
    local mid = k.tex(3, "BACKGROUND", 1)
    mid:SetPoint("TOPLEFT", f, "TOPLEFT", 10, 0)
    mid:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 0)
    fill(mid, 0, h)
    local t1, t2 = k.tex(6, "BORDER", 1), k.tex(7, "BORDER", 1)
    t1:SetPoint("TOPLEFT", f, "TOPLEFT", 10, 0); t1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, 0); t1:SetHeight(1)
    t2:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 0); t2:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 0); t2:SetHeight(1)
    Paint(t1, edge, ea); Paint(t2, edge, ea)
end

-- A hexagon (yes / no) over f's w x h: its pointed ends (stretched when taller) and its middle. Textures 1-7.
local function Hex(k, f, w, h, top, bottom, edge, ea)
    local function fill(t) if bottom then Grad(t, top, bottom) else Paint(t, top) end end
    local L, R = k.tex(1, "BACKGROUND", 1), k.tex(2, "BACKGROUND", 1)
    Shape(L, "hexL"); Shape(R, "hexR")
    L:SetSize(10, h); R:SetSize(10, h)
    L:SetPoint("LEFT", f, "LEFT", 0, 0); R:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    fill(L); fill(R)
    local mid = k.tex(3, "BACKGROUND", 1)
    mid:SetPoint("TOPLEFT", f, "TOPLEFT", 10, 0)
    mid:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 0)
    fill(mid)
    local eL, eR = k.tex(4, "BORDER", 1), k.tex(5, "BORDER", 1)
    Shape(eL, "hexL", true); Shape(eR, "hexR", true)
    eL:SetSize(10, h); eR:SetSize(10, h)
    eL:SetPoint("LEFT", f, "LEFT", 0, 0); eR:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    Paint(eL, edge, ea); Paint(eR, edge, ea)
    local t1, t2 = k.tex(6, "BORDER", 1), k.tex(7, "BORDER", 1)
    t1:SetPoint("TOPLEFT", f, "TOPLEFT", 10, 0); t1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, 0); t1:SetHeight(1)
    t2:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 0); t2:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 0); t2:SetHeight(1)
    Paint(t1, edge, ea); Paint(t2, edge, ea)
end

-- A flat body with a top light and 1px edges: textures from index n. Returns the next free index.
local function Body(k, f, n, x, y, w, h, f2, f1, e, opts)
    local body = k.tex(n, "BACKGROUND", 1)
    body:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
    body:SetSize(w, h)
    Grad(body, f2, f1)
    local hl = k.tex(n + 1, "BACKGROUND", 2)
    hl:SetPoint("TOPLEFT", f, "TOPLEFT", x + 1, -y - 1)
    hl:SetSize(max(1, w - 2), 1)
    hl:SetVertexColor(1, 1, 1, 0.12)
    local i = n + 2
    local function line(px, py, lw, lh)
        local t = k.tex(i, "BORDER", 1)
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
local function Notch(k, f, n, x, y, e)
    local fill = k.tex(n, "BORDER", 2)
    Shape(fill, "tab")
    fill:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
    fill:SetVertexColor(0, 0, 0, 0.5)
    local edge = k.tex(n + 1, "BORDER", 3)
    Shape(edge, "tab", true)
    edge:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
    Paint(edge, e, 0.85)
    return n + 2
end

-- The tab under a piece (over the next piece's notch).
local function TabUnder(k, f, n, x, y, f1, e)
    local fill = k.tex(n, "OVERLAY", 1)
    Shape(fill, "tab")
    fill:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(y - 1))
    Paint(fill, f1, 1)
    local edge = k.tex(n + 1, "OVERLAY", 2)
    Shape(edge, "tab", true)
    edge:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(y - 1))
    Paint(edge, e, 0.85)
    return n + 2
end

---------------------------------------------------------------------------
-- What a blank shows
---------------------------------------------------------------------------

-- Blanks whose value is picked from a list: a caret after the choice (timer: a typed name, in a box).
local DROPDOWN = { channel = true, stat = true, stage = true, marker = true, dur = true, var = true, badge = true,
    ctxname = true, varname = true, timer = true, score = true, list = true, ask = true, label = true, what = true,
    how = true, sound = true, state = true, since = true, emote = true }
local NO_CARET = { timer = true, ctxname = true, varname = true }
-- Typed in a box (text in quotes)
local BOX = { text = true, timer = true, item = true, creature = true }
-- An empty blank of these needs filling (unless the piece says it may stay empty: then it means any)
local NEED_T = { player = true, players = true, bool = true, stage = true, var = true, badge = true, block = true,
    num = true, timer = true, tag = true, score = true, place = true, where = true, list = true, ask = true, label = true,
    what = true, how = true, sound = true, state = true, item = true, since = true }
-- What an empty blank says it takes
local HINT = { player = "player", players = "players", num = "n", text = "text", any = "value", place = "place",
    where = "place", tag = "tag", score = "score", list = "list", ask = "ask", label = "button", item = "item",
    creature = "creature", emote = "emote", what = "what", how = "how", sound = "sound", state = "state", since = "since",
    timer = "name", stage = "stage", badge = "badge", var = "variable", block = "block", marker = "marker", dur = "time",
    channel = "channel", stat = "score" }
EP.HINT = HINT

local function ChoiceLabel(list, v)
    for _, c in ipairs(list or {}) do
        if c[1] == v then return c[2] end
    end
    return nil
end

-- The blank of piece p that filters blank i (a happen / touch choice's second blank), or nil.
local function FilterSlot(p, i)
    local pd = p and B().PIECES[p.k]
    for j, a in ipairs(pd and pd.args or {}) do
        if a.t == "filter" and a.of == i then return j end
    end
    return nil
end

-- The words a literal blank shows (p, i: the piece and its blank, for a choice whose words follow its filter).
function EP:BlankText(t, v, def, p, i)
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
    if t == "what" then
        local h = Bk.HAPPEN_BY[v]
        if not h then return tostring(v) end
        -- "kills a creature" alone; "kills" before the creature named in its filter
        local fi = FilterSlot(p, i)
        local fv = fi and p.a and p.a[fi]
        if fv ~= nil and fv ~= "" and h.verb then return h.verb end
        return h.label
    end
    if t == "how" then
        local h = Bk.TOUCH_BY[v]
        return h and h.label or tostring(v)
    end
    if t == "emote" then return ChoiceLabel(Bk.EMOTES, v) or string.lower(tostring(v)) end
    if t == "sound" then
        local s = Bk.SOUND_BY[v]
        return s and s[2] or tostring(v)
    end
    if t == "state" then return ChoiceLabel(Bk.STATES, v) or tostring(v) end
    if t == "since" then return v == "stage" and "this stage started" or tostring(v) end
    if t == "item" and type(v) == "number" then
        local info = C_Item and C_Item.GetItemInfo
        local name = info and info(v)
        return name or ("item " .. v)
    end
    local dk = Bk.DEF_OF_TYPE and Bk.DEF_OF_TYPE[t]
    if dk then return Bk:DefinitionName(def, dk, v) end
    if t == "where" then return Bk:DefinitionName(def, "places", v) end
    return tostring(v)
end

-- Is blank i of p drawn? A filter blank only when its choice has one and it is filled (an empty one means any: the
-- choice's words say so, "kills a creature").
local function Shown(p, i, a)
    if a.t ~= "filter" then return true end
    if not B():ArgType(p, i) then return false end
    local v = p.a and p.a[i]
    return v ~= nil and v ~= ""
end
EP.BlankShown = function(_, p, i)
    local pd = p and B().PIECES[p.k]
    local a = pd and pd.args and pd.args[i]
    return a ~= nil and Shown(p, i, a)
end

local function CtxCat(name)
    local c = B().CTX[name]
    if not c then return "pl" end
    if c.t == "player" or c.t == "players" then return "pl" end
    if c.t == "place" then return "pc" end
    return "pt"
end

-- A tag's colour, a place's ring: the chip's mark (a tag or a place picked, "players with tag ...").
local function Mark(k, f, kind, x, color)
    if kind == "tag" then
        local o = k.tex(20, "ARTWORK", 2)
        o:SetTexture(DISC)
        o:SetSize(9, 9)
        o:SetPoint("LEFT", f, "LEFT", x - 1, 0)
        o:SetVertexColor(0, 0, 0, 0.8)
        local d = k.tex(21, "ARTWORK", 3)
        d:SetTexture(DISC)
        d:SetSize(7, 7)
        d:SetPoint("LEFT", f, "LEFT", x, 0)
        d:SetVertexColor(color[1], color[2], color[3], 1)
        return x + 7 + 5
    end
    local r = k.tex(20, "ARTWORK", 2)
    r:SetTexture(RING)
    r:SetSize(9, 9)
    r:SetPoint("LEFT", f, "LEFT", x, 0)
    r:SetVertexColor(1, 1, 1, 0.92)
    return x + 9 + 5
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

-- Every frame drawn goes into ctx.all with its depth (pieces inside a C or a blank are one deeper) and its rank in its
-- stack (earlier pieces higher): Layer() gives them frame levels from that, so a piece's tab covers the next one's
-- notch and what sits inside a piece is above it.
local function Note(ctx, f, depth, isBlank)
    f.depth, f.rank, f.isBlank = depth, ctx.rank or 0, isBlank
    ctx.all[#ctx.all + 1] = f
end

-- A blank's mouse: a click opens its picker (the builder), the mouse over it lights it (and may show a place's card).
local function BlankMouse(ctx, f, piece, slot)
    if ctx.opts.static then return end
    f:EnableMouse(true)
    if f.RegisterForClicks then
        f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        f:SetScript("OnClick", function(self, button)
            if ctx.opts.onBlank then ctx.opts.onBlank(piece, slot, self, button) end
        end)
    end
    f:SetScript("OnEnter", function(self)
        if self.hl then self.hl:Show() end
        if ctx.opts.onHover then ctx.opts.onHover(piece, slot, self, true) end
    end)
    f:SetScript("OnLeave", function(self)
        if self.hl then self.hl:Hide() end
        if ctx.opts.onHover then ctx.opts.onHover(piece, slot, self, false) end
    end)
    if not f.hl then
        f.hl = f:CreateTexture(nil, "HIGHLIGHT")
        f.hl:SetTexture(WHITE)
        local r, g, b = St:Color("HAIRLINE")
        f.hl:SetVertexColor(r, g, b, 0.06)
        f.hl:SetAllPoints()
    end
end

-- A tag or a place picked in a blank: its chip (the category's round, the tag's colour dot or the place's ring, the
-- name). Still a blank: a click picks another.
local function BuildChip(ctx, parent, piece, slot, t, v, argT)
    local f = Acquire("blank", parent)
    tinsert(parent.kids, f)
    Note(ctx, f, ctx.depth, true)
    f.piece, f.slot, f.t = piece, slot, argT or t
    local k = Kit(f)
    local def = ctx.opts.def
    local Bk = B()
    local tag = t == "tag"
    local c = Bk.CAT[tag and "pl" or "pc"]
    local x = Mark(k, f, tag and "tag" or "place", 8, tag and Bk:TagColor((Bk:Definition(def, "tags", v) or {}).c) or nil)
    local fs = k.font()
    fs:SetText(Bk:DefinitionName(def, tag and "tags" or "places", v))
    fs:SetPoint("LEFT", f, "LEFT", x, 0)
    local w = floor(x + SW(fs) + 8 + 0.5)
    local h = EP.BLANK_H
    f:SetSize(w, h)
    local hot = ctx.opts.hot and ctx.opts.hot.piece == piece and ctx.opts.hot.slot == slot
    Round(k, f, w, h, c.f2, c.f, hot and HOT or c.e, hot and 0.95 or 0.85)
    k.done()
    BlankMouse(ctx, f, piece, slot)
    -- (the blank's own type: a "where" chip still takes a player dropped on it)
    ctx.blanks[#ctx.blanks + 1] = { piece = piece, slot = slot, frame = f, t = argT or t }
    return f, w, h
end

-- A blank (a well): round (values), a box (typed text, timers), with a caret (dropdowns), or a hexagon (yes / no).
-- Its content: words, or a value piece dropped in, or text with values in it.
local function BuildBlank(ctx, parent, piece, slot, a, v)
    if type(v) == "table" and v.k then
        -- a value dropped in: the piece itself sits where the blank was (a band above the piece it is in)
        ctx.depth = ctx.depth + 1
        local kid, kw, kh = Build(ctx, parent, v, true)
        ctx.depth = ctx.depth - 1
        return kid, kw, kh
    end
    local Bk = B()
    local t = (a.t == "filter" and Bk:ArgType(piece, slot)) or a.t
    local def = ctx.opts.def
    -- a tag or a place picked: its chip (one that's gone reads as an empty blank: the piece says it needs another)
    local gone = false
    if type(v) == "string" and v ~= "" and (t == "tag" or t == "place" or t == "where" or t == "score" or t == "list"
        or t == "ask") then
        local dk = (t == "where") and "places" or Bk.DEF_OF_TYPE[t]
        if def and not Bk:Definition(def, dk, v) then
            gone = true
        elseif t == "tag" or t == "place" or t == "where" then
            return BuildChip(ctx, parent, piece, slot, t == "tag" and "tag" or "place", v, t)
        end
    end
    local f = Acquire("blank", parent)
    tinsert(parent.kids, f)
    Note(ctx, f, ctx.depth, true)
    f.piece, f.slot, f.t = piece, slot, t
    local k = Kit(f)
    local pd = Bk.PIECES[piece.k]
    local hot = ctx.opts.hot and ctx.opts.hot.piece == piece and ctx.opts.hot.slot == slot
    local empty = gone or v == nil or v == ""
    -- (an empty blank is a problem only in an event's script: the palette's pieces and a dragged one show plain wells)
    local needs = empty and NEED_T[t] and not a.opt
    local required = needs and ctx.opts.problems ~= nil
    local look = required and NEED or WELL
    local hex = t == "bool"
    local box = BOX[t]
    local h = hex and EP.HEX_H or EP.BLANK_H
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
                local fs = k.font()
                local txt = seg:match("^%s*(.-)%s*$")
                fs:SetText(txt)
                fs:SetPoint("LEFT", f, "LEFT", x, 0)
                Paint(fs, look.text)
                x = x + SW(fs) + 4
                parts = parts + 1
            end
        end
        x = x - 4 + 8
        if parts == 0 then x = 34 end
    else
        local text = empty and "" or EP:BlankText(t, v, def, piece, slot)
        local hint = empty and HINT[t]
        if text ~= "" or hint then
            local fs = k.font()
            fs:SetText(text ~= "" and text or hint)
            fs:SetPoint("LEFT", f, "LEFT", x, 0)
            local c = look.text
            -- (an empty blank's word is dimmer: it says what goes there)
            fs:SetTextColor(c[1], c[2], c[3], text ~= "" and 1 or (needs and 0.8 or 0.5))
            x = x + SW(fs)
        else
            x = x + (hex and 18 or 12)
        end
        if DROPDOWN[t] and not NO_CARET[t] and not empty then
            local caret = k.tex(40, "OVERLAY", 3)
            caret:SetTexture(UI().ICON_ATLAS)
            local cc = UI():IconCoords(14)
            caret:SetTexCoord(cc[1], cc[2], cc[3], cc[4])
            caret:SetSize(9, 9)
            caret:SetPoint("LEFT", f, "LEFT", x + 3, 0)
            caret:SetVertexColor(1, 1, 1, 0.7)
            x = x + 12
        end
        x = x + (hex and 13 or 8)
    end
    w = max(hex and 36 or 22, x)
    if box and t == "text" and not empty then
        -- quotes around typed text (an empty one just says "text")
        local q1 = k.font()
        q1:SetText("\226\128\156")
        q1:SetTextColor(1, 1, 1, 0.45)
        q1:SetPoint("LEFT", f, "LEFT", 2, 0)
        local q2 = k.font()
        q2:SetText("\226\128\157")
        q2:SetTextColor(1, 1, 1, 0.45)
        q2:SetPoint("RIGHT", f, "RIGHT", -2, 0)
    end
    f:SetSize(w, h)
    -- the well
    local fill, edge = look.fill, hot and HOT or look.edge
    if ctx.opts.liveSlots and ctx.opts.liveSlots[piece] == slot then fill, edge = LIVE.fill, LIVE.edge end
    if hex then
        local cat = pd and Bk.CAT[pd.cat]
        local pe = cat and cat.e
        local ec = hot and HOT or (required and NEED.edge) or { (pe or edge)[1], (pe or edge)[2], (pe or edge)[3], 0.75 }
        Hex(k, f, w, h, fill, nil, ec)
    elseif box then
        local mid = k.tex(1, "BACKGROUND", 1)
        mid:SetAllPoints()
        Paint(mid, fill)
        for i, p in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
            { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
            local tt = k.tex(1 + i, "BORDER", 1)
            tt:SetPoint(p[1]); tt:SetPoint(p[2])
            if p[3] then tt:SetHeight(1) else tt:SetWidth(1) end
            Paint(tt, edge)
        end
    else
        Round(k, f, w, h, fill, nil, edge)
    end
    k.done()
    BlankMouse(ctx, f, piece, slot)
    ctx.blanks[#ctx.blanks + 1] = { piece = piece, slot = slot, frame = f, t = t }
    return f, w, h
end

-- A smart block named in a sentence ("when {Matches} match starts"): its value pill (icon + name). Still a blank: a
-- click picks another block of that kind.
local function BuildBlockPill(ctx, f, p, tok, v)
    local kid = Acquire("piece", f)
    tinsert(f.kids, kid)
    Note(ctx, kid, ctx.depth, true)
    local k = Kit(kid)
    local def = ctx.opts.def
    local blk = def.blocks[v]
    local c = B().CAT.sm
    local ic = k.tex(31, "OVERLAY", 1)
    ic:SetTexture(B().SMART[blk.kind].icon)
    ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    ic:SetSize(13, 13)
    ic:SetPoint("LEFT", kid, "LEFT", 5, 0)
    local fs = k.font()
    fs:SetText(B():BlockLabel(def, v))
    fs:SetPoint("LEFT", kid, "LEFT", 21, 0)
    local kw = floor(21 + SW(fs) + 8 + 0.5)
    kid:SetSize(kw, EP.BLANK_H)
    Round(k, kid, kw, EP.BLANK_H, c.f2, c.f, c.e, 0.85)
    k.done()
    if not ctx.opts.static then
        kid:EnableMouse(true)
        kid:SetScript("OnMouseUp", function(self, button)
            if ctx.opts.onBlank then ctx.opts.onBlank(p, tok, self, button) end
        end)
    end
    ctx.blanks[#ctx.blanks + 1] = { piece = p, slot = tok, frame = kid, t = "block" }
    return kid, kw
end

-- A piece's sentence as items to lay out in lines: { w, h, put(x, cy), word, tok }. split: each word on its own (a
-- piece that may take two lines breaks between words). hat: its first "when" / "every" a little dimmer (Scratch's
-- event words). value: a value piece (a smart block's name in its words is an icon and the name, not a pill).
local function Items(ctx, k, f, p, pd, split, hat, value)
    local items = {}
    local def = ctx.opts.def
    local function word(text, tok, alpha)
        local fs = k.font()
        fs:SetText(text)
        if alpha then fs:SetTextColor(1, 1, 1, alpha) end
        items[#items + 1] = { w = SW(fs), h = EP.BLANK_H, word = true, tok = tok, text = text,
            put = function(x, cy) fs:SetPoint("LEFT", f, "TOPLEFT", x, -cy) end }
    end
    for ti, tok in ipairs(Tokens(pd.text)) do
        if type(tok) == "number" then
            local a = pd.args[tok] or { t = "any" }
            local v = p.a and p.a[tok]
            if Shown(p, tok, a) then
                if a.t == "block" and value then
                    -- the block's name in the value's own words ("Matches champion"), its icon in front
                    local sm = v and def and def.blocks and def.blocks[v]
                    local ic
                    if sm and B().SMART[sm.kind] then
                        ic = k.tex(31, "OVERLAY", 1)
                        ic:SetTexture(B().SMART[sm.kind].icon)
                        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        ic:SetSize(13, 13)
                    end
                    local fs = k.font()
                    fs:SetText(def and B():BlockLabel(def, v) or "Matches")
                    local iw = ic and 14 or 0
                    items[#items + 1] = { w = iw + SW(fs), h = EP.BLANK_H, tok = ti, put = function(x, cy)
                        if ic then ic:SetPoint("LEFT", f, "TOPLEFT", x - 2, -cy) end
                        fs:SetPoint("LEFT", f, "TOPLEFT", x + iw, -cy)
                    end }
                else
                    local kid, kw
                    if a.t == "block" and v and def and def.blocks and def.blocks[v] then
                        kid, kw = BuildBlockPill(ctx, f, p, tok, v)
                    else
                        kid, kw = BuildBlank(ctx, f, p, tok, a, v)
                    end
                    local kh = kid:GetHeight() or EP.BLANK_H
                    items[#items + 1] = { w = kw, h = kh, tok = ti, put = function(x, cy) Place(kid, f, x, cy - kh / 2) end }
                end
            end
        else
            local text = tok
            if hat and ti == 1 then
                local w1, rest = text:match("^(%S+)%s+(.+)$")
                if w1 == "when" or w1 == "every" or (not rest and (text == "when" or text == "every")) then
                    word(w1 or text, 0, 0.72)
                    text = rest
                end
            end
            if text then
                if split then
                    for w in text:gmatch("%S+") do word(w, ti) end
                else
                    word(text, ti)
                end
            end
        end
    end
    return items
end

-- A space's width in the pieces' font (measured once).
local function Space()
    if spaceW then return spaceW end
    local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    UI():SetTextStyle(fs, EP.FONT_SIZE, WELL.text)
    fs:SetText("x x")
    local a = SW(fs)
    fs:SetText("xx")
    local c = SW(fs)
    spaceW = (a > c and a - c < 8) and (a - c) or 3
    return spaceW
end

-- The gap before an item: a space between two words of one part, a little more after the dim "when", else EP.GAP.
local function GapBefore(prev, it)
    if prev.word and it.word then return prev.tok == it.tok and Space() or 4 end
    return EP.GAP
end

local LINK_WORDS = { a = true, an = true, the = true, of = true, to = true, ["in"] = true, by = true, as = true,
    from = true, ["for"] = true, with = true, is = true, ["and"] = true, one = true, when = true, every = true }

-- Items in lines no wider than maxW (nil: one line): { { items, w } ... }, the widest line's width.
local function Lines(items, maxW)
    local lines, cur, x, widest = {}, {}, 0, 0
    for _, it in ipairs(items) do
        local add = (#cur > 0 and GapBefore(cur[#cur], it) or 0) + it.w
        if maxW and #cur > 0 and x + add > maxW then
            lines[#lines + 1] = { items = cur, w = x }
            widest = max(widest, x)
            cur, x = { it }, it.w
        else
            cur[#cur + 1] = it
            x = x + add
        end
    end
    lines[#lines + 1] = { items = cur, w = x }
    widest = max(widest, x)
    if #lines < 2 then return lines, widest end
    -- a line that starts with a blank takes the word before it along ("when an entrant" / "enters [place]"), when
    -- that still fits
    local function width(list)
        local w = 0
        for i, it in ipairs(list) do w = w + it.w + (i > 1 and GapBefore(list[i - 1], it) or 0) end
        return w
    end
    for li = 1, #lines - 1 do
        local a, b = lines[li].items, lines[li + 1].items
        local last, before = a[#a], a[#a - 1]
        -- (not when the line would end on "an" or "of": "when an" / "entrant [wins a duel]")
        if #a > 1 and last.word and not b[1].word and not (before.word and LINK_WORDS[before.text]) then
            tinsert(b, 1, last)
            if width(b) <= maxW then
                tremove(a)
            else
                tremove(b, 1)
            end
        end
        -- a part's last words alone on the next line take its first ones along ("when [Matches]" / "match starts")
        local alone = #b > 0
        for _, it in ipairs(b) do if not (it.word and it.tok == last.tok and last.word) then alone = false end end
        if alone and li + 1 == #lines then
            local moved = {}
            while #a > 1 and a[#a].word and a[#a].tok == b[1].tok do tinsert(moved, 1, tremove(a)) end
            if #moved > 0 then
                for i = #moved, 1, -1 do tinsert(b, 1, moved[i]) end
                if width(b) > maxW then
                    for _ = 1, #moved do tinsert(a, tremove(b, 1)) end
                end
            end
        end
    end
    widest = 0
    for _, l in ipairs(lines) do
        l.w = width(l.items)
        widest = max(widest, l.w)
    end
    return lines, widest
end

-- Puts the lines' items in place: from x0, the first line's middle at cy, each next one step lower.
local function PutLines(lines, x0, cy, step)
    for li, line in ipairs(lines) do
        local x = x0
        for i, it in ipairs(line.items) do
            if i > 1 then x = x + GapBefore(line.items[i - 1], it) end
            it.put(x, cy + (li - 1) * step)
            x = x + it.w
        end
    end
end

-- A value (round) or yes / no (hexagon) piece.
local function BuildValue(ctx, parent, p, pd)
    local wrap = ctx.wrap
    ctx.wrap = nil
    local f = Acquire("piece", parent)
    tinsert(parent.kids, f)
    Note(ctx, f, ctx.depth, false)
    f.piece = p
    ctx.at[p] = f
    local k = Kit(f)
    local hex = pd.shape == "bool"
    local cat = pd.cat
    if p.k == "ctx" then cat = CtxCat(p.a and p.a[1]) end
    if p.k == "var" then cat = "lo" end
    local Bk = B()
    local c = Bk.CAT[cat] or Bk.CAT.pl
    local h = hex and EP.HEX_H or EP.BLANK_H
    local pad = hex and 13 or 8
    local x = pad
    local def = ctx.opts.def
    local liveOn = false
    local tagId = p.k == "pl.tagged" and p.a and p.a[1]
    if p.k == "ctx" or p.k == "var" then
        local name = p.a and p.a[1]
        local label = p.k == "ctx" and (Bk.CTX[name] and Bk.CTX[name].label or tostring(name)) or tostring(name or "?")
        local fs = k.font()
        fs:SetText(label)
        fs:SetPoint("LEFT", f, "LEFT", x, 0)
        x = x + SW(fs)
        local live = ctx.opts.live
        if p.k == "ctx" and live and live[name] ~= nil then
            local val = live[name]
            local nameOf = ctx.opts.nameOf
            local text
            if type(val) == "table" and val.list then
                local names = {}
                for i = 1, #val do names[i] = nameOf and nameOf(val[i]) or tostring(val[i]) end
                text = table.concat(names, ", ")
            elseif type(val) == "table" and val.q then
                text = tostring(val.q)       -- (a list's question item: its words)
            elseif type(val) == "string" and val:find("%-") and nameOf then
                text = nameOf(val)
            elseif type(val) == "string" and def and Bk:Definition(def, "places", val) then
                text = Bk:DefinitionName(def, "places", val)
            else
                text = tostring(val)
            end
            local sep = k.tex(30, "OVERLAY", 1)
            sep:SetSize(1, h - 6)
            sep:SetPoint("LEFT", f, "LEFT", x + 6, 0)
            sep:SetVertexColor(1, 1, 1, 0.2)
            local fv = k.font()
            fv:SetText(text)
            fv:SetTextColor(1, 0.9, 0.5)
            fv:SetPoint("LEFT", f, "LEFT", x + 12, 0)
            x = x + 12 + SW(fv)
            liveOn = true
        end
        x = x + pad
    elseif type(tagId) == "string" and tagId ~= "" and (not def or Bk:Definition(def, "tags", tagId)) then
        -- "players with tag Hiders" is the tag's chip: its colour dot and its name
        x = Mark(k, f, "tag", 8, Bk:TagColor((Bk:Definition(def, "tags", tagId) or {}).c))
        local fs = k.font()
        fs:SetText(Bk:DefinitionName(def, "tags", tagId))
        fs:SetPoint("LEFT", f, "LEFT", x, 0)
        x = x + SW(fs) + 8
    else
        local items = Items(ctx, k, f, p, pd, wrap ~= nil, false, true)
        local lines, widest = Lines(items, wrap and (wrap - 2 * pad) or nil)
        local n = #lines
        if n > 1 then h = 8 + n * EP.LINE_H + (n - 1) * 3 end
        PutLines(lines, pad, n > 1 and (4 + EP.LINE_H / 2) or (h / 2), EP.LINE_H + 3)
        x = pad + widest + pad
    end
    local w = floor(max(hex and 40 or 26, x) + 0.5)
    f:SetSize(w, h)
    local ec = liveOn and LIVE.edge or c.e
    if hex then
        Hex(k, f, w, h, c.f2, c.f, ec, 0.85)
    else
        Round(k, f, w, h, c.f2, c.f, ec, 0.85)
    end
    k.done()
    EP:Interact(ctx, f, p)
    EP:Mark(ctx, f, p)
    return f, w, h
end

-- Mouse on a piece: the builder's drag and right-click.
function EP:Interact(ctx, f, p)
    if ctx.opts.static then return end
    f:EnableMouse(true)
    -- (what the piece does, when its words don't say all of it: the builder's tooltip; a problem's comes first)
    if ctx.opts.onEnter then
        f:SetScript("OnEnter", function(self) ctx.opts.onEnter(p, self, true) end)
        f:SetScript("OnLeave", function(self) ctx.opts.onEnter(p, self, false) end)
    end
    f:SetScript("OnMouseDown", function(self, button)
        if ctx.opts.onPiece then ctx.opts.onPiece(p, self, button, true) end
    end)
    f:SetScript("OnMouseUp", function(self, button)
        if ctx.opts.onPiece then ctx.opts.onPiece(p, self, button, false) end
    end)
end

-- Where a piece takes the mouse: only where it is drawn. A frame takes clicks over its whole rectangle in the game,
-- and a C piece's rectangle holds its hollow and the room right of its arms, a hat's the band right of its dome: there
-- they would take the clicks meant for another script's pieces and blanks (in game 2026-10-07: an empty text blank
-- that did nothing). So such a piece hands its mouse to child frames over its drawn parts (rects: { x, y, w, h } from
-- its top-left, y down), at its own level, each passing the mouse on to the piece's own scripts.
local HIT_EVENTS = { "OnMouseDown", "OnMouseUp", "OnEnter", "OnLeave" }
function EP:HitParts(ctx, f, rects)
    if ctx.opts.static then return end
    f.hits = f.hits or {}
    for i, r in ipairs(rects) do
        local h = f.hits[i]
        if not h then
            h = CreateFrame("Frame", nil, f)
            for _, ev in ipairs(HIT_EVENTS) do
                h:SetScript(ev, function(self, ...)
                    local piece = self:GetParent()
                    local fn = piece and piece:GetScript(ev)
                    if fn then fn(piece, ...) end
                end)
            end
            f.hits[i] = h
        end
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", f, "TOPLEFT", r[1], -r[2])
        h:SetSize(max(1, r[3]), max(1, r[4]))
        h:EnableMouse(true)
        h:Show()
        h.depth, h.rank, h.isBlank = f.depth, f.rank, false
        ctx.all[#ctx.all + 1] = h
    end
    for i = #rects + 1, #f.hits do f.hits[i]:Hide() end
    f:EnableMouse(false)
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
    local wrap = ctx.wrap
    ctx.wrap = nil
    local f = Acquire("piece", parent)
    tinsert(parent.kids, f)
    Note(ctx, f, ctx.depth, false)
    f.piece = p
    ctx.at[p] = f
    for _, t in ipairs(f.tabFrames or {}) do t:Hide() end
    local k = Kit(f)
    local c = B().CAT[pd.cat] or B().CAT.sm
    local shape = pd.shape
    local hat = shape == "hat"
    local top = hat and EP.DOME or 0
    local lockW = (ctx.opts.locked and hat) and 12 or 0
    local x0 = EP.PAD
    -- the words and blanks, in lines no wider than wrap (the palette), else one
    local items = Items(ctx, k, f, p, pd, wrap ~= nil, hat, false)
    local lines, widest = Lines(items, wrap and (wrap - x0 - EP.PAD - lockW) or nil)
    local n = #lines
    local headH = hat and EP.HAT_H or EP.H
    local cy, step = top + headH / 2 + (hat and 1 or 0), EP.LINE_H + EP.LINE_GAP
    if n > 1 then
        local padT = hat and 7 or 5
        headH = padT + n * EP.LINE_H + (n - 1) * EP.LINE_GAP + (hat and 6 or 5)
        cy = top + padT + EP.LINE_H / 2
    end
    PutLines(lines, x0, cy, step)
    local headW = max(hat and 90 or 50, x0 + widest + EP.PAD) + lockW
    local w, h = headW, top + headH
    local nt = 1
    -- (a C piece's header and else bar, for what it covers on the canvas: f.headW / headH / midY; nil for the rest)
    f.headW, f.headH, f.midY = nil, nil, nil
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
        f.headW, f.headH, f.midY = headW, top + headH, midY
        -- header body (its bottom-left joins the arm)
        nt = Body(k, f, nt, 0, top, headW, headH, c.f2, c.f, c.e, { noBottom = true })
        local hb = k.tex(nt, "BORDER", 1)       -- the header's bottom edge, right of the arm
        hb:SetPoint("TOPLEFT", f, "TOPLEFT", EP.ARM - 1, -(top + headH - 1))
        hb:SetSize(headW - EP.ARM + 1, 1)
        Paint(hb, c.e, 0.85)
        nt = nt + 1
        -- arm(s)
        local function arm(y1, y2)
            local a = k.tex(nt, "BACKGROUND", 1)
            a:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y1)
            a:SetSize(EP.ARM, y2 - y1)
            Paint(a, c.f)
            local l = k.tex(nt + 1, "BORDER", 1)
            l:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y1)
            l:SetSize(1, y2 - y1)
            Paint(l, c.e, 0.85)
            local r = k.tex(nt + 2, "BORDER", 1)
            r:SetPoint("TOPLEFT", f, "TOPLEFT", EP.ARM - 1, -y1)
            r:SetSize(1, y2 - y1)
            Paint(r, c.e, 0.85)
            nt = nt + 3
        end
        arm(top + headH, top + headH + inH1)
        if shape == "c2" then
            nt = Body(k, f, nt, 0, midY, EP.FOOT_W, EP.MID, c.f2, c.f, c.e, { noLeft = false })
            local fs = k.font()
            fs:SetText("else")
            fs:SetPoint("LEFT", f, "TOPLEFT", EP.PAD, -(midY + EP.MID / 2))
            arm(midY + EP.MID, midY + EP.MID + inH2)
        end
        nt = Body(k, f, nt, 0, footY, EP.FOOT_W, EP.FOOT, c.f2, c.f, c.e)
        -- the tabs into the arm(s) (over the first inside piece) and under the foot
        TabFrame(ctx, f, 1, EP.ARM + EP.TAB_X, top + headH, c)
        if shape == "c2" then TabFrame(ctx, f, 2, EP.ARM + EP.TAB_X, midY + EP.MID, c) end
        if not ctx.opts.noTab then nt = TabUnder(k, f, nt, EP.TAB_X, h, c.f, c.e) end
        nt = Notch(k, f, nt, EP.TAB_X, top, c.e)
    else
        nt = Body(k, f, nt, 0, top, w, headH, c.f2, c.f, c.e, hat and { noTop = true } or nil)
        if hat then
            -- the top edge right of the dome (the dome draws its own)
            local te = k.tex(nt, "BORDER", 1)
            te:SetPoint("TOPLEFT", f, "TOPLEFT", 79, -top)
            te:SetSize(max(1, w - 79), 1)
            Paint(te, c.e, 0.85)
            nt = nt + 1
            local dome = k.tex(nt, "BACKGROUND", 3)
            Shape(dome, "dome")
            dome:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
            dome:SetSize(80, 12)
            Paint(dome, c.f2)
            local de = k.tex(nt + 1, "BORDER", 2)
            Shape(de, "dome", true)
            de:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
            de:SetSize(80, 12)
            Paint(de, c.e, 0.85)
            nt = nt + 2
        else
            nt = Notch(k, f, nt, EP.TAB_X, 0, c.e)
        end
        if shape ~= "cap" then nt = TabUnder(k, f, nt, EP.TAB_X, top + headH, c.f, c.e) end
        if lockW > 0 then
            local lk = k.tex(nt, "OVERLAY", 6)
            lk:SetTexture(UI().ICON_ATLAS)
            local cc = UI():IconCoords(UI().ICON.lock or 12)
            lk:SetTexCoord(cc[1], cc[2], cc[3], cc[4])
            lk:SetSize(11, 11)
            lk:SetPoint("RIGHT", f, "TOPLEFT", w - 6, -(top + headH / 2))
            lk:SetVertexColor(0.91, 0.77, 0.35)
            nt = nt + 1
        end
    end
    f:SetSize(w, h)
    k.done()
    EP:Interact(ctx, f, p)
    EP:Mark(ctx, f, p)
    if f.headW then
        -- a C piece: its header, its arm(s) with the else bar, its foot
        local rects = { { 0, 0, f.headW, f.headH }, { 0, f.headH, EP.ARM, h - f.headH - EP.FOOT } }
        if f.midY then rects[#rects + 1] = { 0, f.midY, EP.FOOT_W, EP.MID } end
        rects[#rects + 1] = { 0, h - EP.FOOT, EP.FOOT_W, EP.FOOT }
        EP:HitParts(ctx, f, rects)
    elseif hat then
        -- a hat: its dome and its body
        EP:HitParts(ctx, f, { { 0, 0, 80, top }, { 0, top, w, h - top } })
    end
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

-- One piece, as in the palette or a review row: no tab under it unless it is part of a stack. opts.wrap: its words in
-- lines no wider than that.
function EP:Draw(parent, piece, opts)
    opts = opts or {}
    local ctx = NewCtx(opts)
    ctx.wrap = opts.wrap
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

-- A tag's or a place's chip alone (kind "tag" | "place"), as a blank shows it: the picker's rows, the cards.
function EP:DrawChip(parent, kind, id, opts)
    opts = opts or { static = true }
    local ctx = NewCtx(opts)
    local f = Acquire("script", parent)
    local kid, w, h = BuildChip(ctx, f, { k = "_chip", a = { id } }, 1, kind, id)
    kid:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f:SetSize(max(1, w), max(1, h))
    f.at, f.blanks, f.w, f.h = ctx.at, ctx.blanks, w, h
    f.ctx = ctx
    Layer(ctx, (f:GetFrameLevel() or 1) + 1)
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
