if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Chess/UI.lua", ...) then return end -- DisasterZone Games/Chess/UI.lua
-- ns.ChessUI: the Karazhan Chess panel in the Games hub. The board on the left (the Gamesman's Hall in 3D,
-- Games/Chess/Board3D.lua, or a flat board: before a client restart, or when you pick it), a column on the right:
-- the lobby (play the Echo of Medivh, challenge a guild member, your games, the guild ladder) or the game you opened
-- (whose move, Medivh's words, the moves, what was taken, resign / draw).
--
-- Click a piece of yours, then where it goes (its moves are marked on the board); a right-click lets go. The Echo of
-- Medivh speaks his own lines from the event (creature_text 16816, sound kits) when pieces fall and when he cheats.
local _, ns = ...

local UI = {}
ns.ChessUI = UI

local R = ns.ChessRules
local floor, min, max, abs = math.floor, math.min, math.max, math.abs

local PAD = 12
local SIDE_W = 256
local DRAWER_W = 226          -- the moves drawer over the board while playing
local FALLBACK_W, FALLBACK_H = 786, 518     -- the stage before the client lays it out
local ROW_H = 42
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local VIOLET = { 0.74, 0.58, 1 }
local GOLD = { 1, 0.82, 0 }
local SIDE_NAME = { [1] = "Alliance", [-1] = "Horde" }
local SIDE_COLOR = { [1] = { 0.45, 0.66, 1 }, [-1] = { 1, 0.42, 0.32 } }
local PIECE_NAME = { "pawn", "knight", "bishop", "rook", "queen", "king" }
local REASON = { checkmate = "checkmate", stalemate = "stalemate", fifty = "the fifty-move rule",
                 repetition = "repetition", material = "too little left to mate", resign = "resignation",
                 agreed = "agreement" }

-- The Echo of Medivh's lines (AzerothCore creature_text, entry 16816: group, text, sound kit). Lost pieces: the
-- player's (groups 3-8) and his own (9-14).
local LINES = {
    begin = { { "Very well. Let the game begin.", 10338 } },
    playerLost = {
        [1] = { { "Let us see.", 10340 }, { "A transparent stratagem.", 10339 }, { "Ah, the wheels have begun to turn.", 10341 } },
        [4] = { { "Foolish! Very foolish!", 10345 } },
        [2] = { { "Yes... all according to plan.", 10349 } },
        [3] = { { "The slightest loss of concentration is all it takes.", 10347 } },
        [5] = { { "Now it gets interesting.", 10351 } },
        [6] = { { "As it should be.", 10354 } },
    },
    medivhLost = {
        [1] = { { "Hmm.", 10342 }, { "No matter.", 10344 }, { "Interesting.", 10343 } },
        [4] = { { "A minor concern.", 10346 } },
        [2] = { { "Yes...of course.", 10350 } },
        [3] = { { "A necessary sacrifice.", 10348 } },
        [5] = { { "Ahh, I should have known.", 10352 } },
        [6] = { { "And so, the end draws near", 10353 } },
    },
}
UI.LINES = LINES
local PAWN_QUIET = 15          -- s between two of his remarks on a pawn

local root, side, boardArea, board3d, flat, promo
local lobby, hud = {}, {}
local state = { sel = nil, targets = {}, tab = "games", listOff = 0, moveOff = 0, cardOff = {} }
local W, H = FALLBACK_W, FALLBACK_H

local function Chess() return ns.Chess end
local function Prefs() return ns.Chess:Prefs() end

local function Label(parent, size, font, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
    end
    return fs
end

local function Hex(c) return string.format("|cff%02x%02x%02x", floor(c[1] * 255), floor(c[2] * 255), floor(c[3] * 255)) end

local function Portrait(tex, display)
    if display and SetPortraitTextureFromCreatureDisplayID then
        local ok = pcall(SetPortraitTextureFromCreatureDisplayID, tex, display)
        if ok then return true end
    end
    tex:SetColorTexture(0.2, 0.2, 0.25, 1)
    return false
end

local function PieceDisplay(v)
    local P = ns.ChessBoard3D and ns.ChessBoard3D.PIECES
    local def = P and P[v > 0 and 1 or -1][abs(v)]
    return def and def.display, def and def.name
end

---------------------------------------------------------------------------
-- Medivh speaks
---------------------------------------------------------------------------

local function Say(line)
    if not line then return end
    local text, sound = line[1], line[2]
    state.said, state.saidAt = text, GetTime()
    if sound and PlaySound then pcall(PlaySound, sound, "Master") end
    UI:Subtitle(text)
    UI:RefreshSide()
end
UI.Say = Say

local function Pick(list)
    if not list or #list == 0 then return nil end
    return list[floor(math.random() * #list) + 1]
end

-- His remark on a fallen piece (games against him): v = the piece that fell.
local function Remark(g, v)
    if not g or g.mode ~= "ai" or not v or v == 0 then return end
    local p = abs(v)
    local mine = (v > 0) == (g.me > 0)
    if p == 1 then
        if state.pawnAt and GetTime() - state.pawnAt < PAWN_QUIET then return end
        state.pawnAt = GetTime()
    end
    Say(Pick((mine and LINES.playerLost or LINES.medivhLost)[p]))
end

---------------------------------------------------------------------------
-- The flat board (2D): before a client restart, or picked in the board's corner
---------------------------------------------------------------------------

local Flat = {}
Flat.__index = Flat

function Flat.New(parent, onSquare)
    local self = setmetatable({ cells = {}, onSquare = onSquare, me = 1 }, Flat)
    local f = CreateFrame("Frame", nil, parent)
    self.frame = f
    for i = 1, 64 do
        local b = CreateFrame("Button", nil, f)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.tint = b:CreateTexture(nil, "BORDER")
        b.tint:SetAllPoints()
        b.tint:Hide()
        b.face = b:CreateTexture(nil, "ARTWORK")
        pcall(b.face.SetMask, b.face, CIRCLE)
        b.ring = b:CreateTexture(nil, "ARTWORK", nil, -1)
        b.ring:SetTexture(CIRCLE)
        b.letter = Label(b, 10, "GameFontHighlightSmall", "OVERLAY")
        b.letter:SetPoint("BOTTOMRIGHT", -2, 2)
        b.dot = b:CreateTexture(nil, "OVERLAY")
        b.dot:SetTexture(CIRCLE)
        b.dot:SetPoint("CENTER")
        b.dot:Hide()
        b:SetScript("OnClick", function(_, button)
            if self.onSquare then self.onSquare(b.sq, button) end
        end)
        self.cells[i] = b
    end
    self.files, self.ranks = {}, {}
    for i = 1, 8 do
        self.files[i] = Label(f, 10, "GameFontNormalSmall")
        self.ranks[i] = Label(f, 10, "GameFontNormalSmall")
    end
    return self
end

function Flat:Layout(size)
    self.size = size
    local cs = size / 8
    self.frame:SetSize(size, size)
    for i, b in ipairs(self.cells) do
        local row, col = floor((i - 1) / 8), (i - 1) % 8
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", self.frame, "TOPLEFT", col * cs, -row * cs)
        b:SetSize(cs, cs)
        b.face:ClearAllPoints()
        b.face:SetPoint("CENTER")
        b.face:SetSize(cs * 0.78, cs * 0.78)
        b.ring:ClearAllPoints()
        b.ring:SetPoint("CENTER")
        b.ring:SetSize(cs * 0.86, cs * 0.86)
        b.dot:SetSize(cs * 0.26, cs * 0.26)
    end
    for i = 1, 8 do
        self.files[i]:ClearAllPoints()
        self.files[i]:SetPoint("TOP", self.frame, "BOTTOMLEFT", (i - 0.5) * cs, -3)
        self.ranks[i]:ClearAllPoints()
        self.ranks[i]:SetPoint("RIGHT", self.frame, "TOPLEFT", -4, -(i - 0.5) * cs)
    end
end

-- The square shown at grid cell i (your side at the bottom).
function Flat:SquareOf(i)
    local row, col = floor((i - 1) / 8), (i - 1) % 8
    local rank, file = self.me == 1 and (7 - row) or row, self.me == 1 and col or (7 - col)
    return R.Square(file, rank), file, rank
end

function Flat:SetPosition(pos, me)
    self.pos, self.me = pos, me or 1
    for i = 1, 8 do
        self.files[i]:SetText(string.char(96 + (self.me == 1 and i or 9 - i)))
        self.ranks[i]:SetText(tostring(self.me == 1 and 9 - i or i))
    end
    self:Paint()
end

function Flat:SetMarks(marks)
    self.marks = marks or {}
    self:Paint()
end

function Flat:Paint()
    local pos, m = self.pos, self.marks or {}
    if not pos then return end
    for i, b in ipairs(self.cells) do
        local sq, file, rank = self:SquareOf(i)
        b.sq = sq
        local light = (file + rank) % 2 == 1
        if light then b.bg:SetColorTexture(0.70, 0.67, 0.63, 1) else b.bg:SetColorTexture(0.16, 0.15, 0.17, 1) end
        local tint
        if m.check == sq then tint = { 1, 0.15, 0.1, 0.55 }
        elseif m.sel == sq then tint = { 1, 0.82, 0.25, 0.5 }
        elseif m.last and (m.last[1] == sq or m.last[2] == sq) then tint = { 0.6, 0.45, 1, 0.38 }
        elseif pos.fire and pos.fire[sq] then tint = { 1, 0.45, 0.05, 0.5 } end
        if tint then
            b.tint:SetColorTexture(tint[1], tint[2], tint[3], tint[4])
            b.tint:Show()
        else
            b.tint:Hide()
        end
        local v = pos.b[sq]
        if v ~= 0 then
            local display = PieceDisplay(v)
            if b.display ~= display then
                b.display = display
                Portrait(b.face, display)
            end
            local c = SIDE_COLOR[v > 0 and 1 or -1]
            local hand = pos.hand and pos.hand[sq]
            b.ring:SetVertexColor(hand and 0.74 or c[1], hand and 0.58 or c[2], hand and 1 or c[3], 1)
            b.letter:SetText(R.LETTER[abs(v)]:upper())
            b.letter:SetTextColor(c[1], c[2], c[3])
            b.face:Show()
            b.ring:Show()
            b.letter:Show()
        else
            b.face:Hide()
            b.ring:Hide()
            b.letter:Hide()
        end
        local mv = m.moves and m.moves[sq]
        if mv then
            if mv == "cap" then b.dot:SetVertexColor(1, 0.35, 0.3, 0.95) else b.dot:SetVertexColor(0.55, 0.85, 1, 0.9) end
            b.dot:Show()
        else
            b.dot:Hide()
        end
    end
end

function Flat:Busy() return false end

---------------------------------------------------------------------------
-- The board: which one, its marks, clicks
---------------------------------------------------------------------------

local function Use3D()
    return board3d ~= nil and not Prefs().flat
end

local function Board()
    if Use3D() then return board3d end
    return flat
end

-- Lays the boards out in the board area (the whole page while playing, beside the lobby's column otherwise): the
-- flat one square, under the top row (TOP_H) and over its file letters and the bottom row (BOTTOM_H), centred across.
local function LayoutBoard()
    local w = (W > 0 and W or FALLBACK_W) - (state.immersive and 0 or SIDE_W)
    local h = H > 0 and H or FALLBACK_H
    local top, bottom = state.immersive and 52 or 48, state.immersive and 70 or 40
    -- (the moves drawer open: the flat board moves over to stay clear of it)
    local drawer = (state.immersive and Prefs().moves) and (DRAWER_W + 24) or 0
    local size = floor(min(w - drawer - 2 * PAD - 24, h - top - bottom))
    if flat then
        flat:Layout(max(160, size))
        flat.frame:ClearAllPoints()
        flat.frame:SetPoint("TOP", boardArea, "TOP", 10 - drawer / 2, -top)
    end
    if board3d then board3d.dirty = true end
end

-- Playing (the board on the whole page, the light layer over it) or the lobby (the column beside the board).
function UI:SetImmersive(on)
    state.immersive = on and true or false
    boardArea:ClearAllPoints()
    boardArea:SetPoint("TOPLEFT", 0, 0)
    boardArea:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", on and 0 or -SIDE_W, 0)
    side:SetShown(not on)
    if hud.frame then hud.frame:SetShown(on) end
    if UI.modeButton then UI.modeButton:SetShown(not on and board3d ~= nil) end
    if UI.hint then UI.hint:SetShown(not on) end
    LayoutBoard()
end

-- The marks for the open game: the last move, a king in check, your selection and where it can go.
local function Marks()
    local g = state.game
    local m = { moves = {} }
    if not g then return m end
    local pos = Chess():Position(g)
    local last = g.moves[#g.moves]
    if last then m.last = { R.ParseSquare(last:sub(1, 2)), R.ParseSquare(last:sub(3, 4)) } end
    if R.InCheck(pos) then m.check = pos.kings[pos.side] end
    if state.sel then
        m.sel = state.sel
        for to, list in pairs(state.targets) do
            local mv = list[1]
            m.moves[to] = (pos.b[to] ~= 0 or R.Flag(mv) == 1) and "cap" or "move"
        end
    end
    return m
end

local function ShowMarks()
    local b = Board()
    if b then b:SetMarks(Marks()) end
end

-- The board shows the open game's position now (or the opening, in the lobby).
local function ShowPosition()
    local g = state.game
    local pos = g and Chess():Position(g) or R.New()
    if board3d then
        if not board3d:Busy() then board3d:SetPosition(pos) end
        board3d.side = g and g.me or 1
    end
    if flat then flat:SetPosition(pos, g and g.me or 1) end
    ShowMarks()
end

local function ClearSelection()
    state.sel, state.targets = nil, {}
    if promo then promo:Hide() end
    ShowMarks()
end

-- Can I touch the board now?
local function CanMove()
    local g = state.game
    if not g or not Chess():MyTurn(g) then return false end
    local b = Board()
    if b and b.Busy and b:Busy() then return false end
    return true
end

local function Select(sq)
    local g = state.game
    local pos = Chess():Position(g)
    state.sel, state.targets = sq, {}
    for _, m in ipairs(R.Legal(pos)) do
        if R.From(m) == sq then
            local to = R.To(m)
            state.targets[to] = state.targets[to] or {}
            table.insert(state.targets[to], m)
        end
    end
    ShowMarks()
end

local function PlayMove(text)
    local g = state.game
    state.sel, state.targets = nil, {}
    if promo then promo:Hide() end
    local ok, why = Chess():Play(g, text)
    if not ok then
        ns:Print("Karazhan Chess: that move is not possible (%s).", tostring(why))
        ShowMarks()
    end
end

local function OnSquare(sq, button)
    if button == "RightButton" or not sq then
        ClearSelection()
        return
    end
    if not CanMove() then return end
    local g = state.game
    local pos = Chess():Position(g)
    local list = state.sel and state.targets[sq]
    if list then
        local m = list[1]
        if #list > 1 and R.Promo(m) > 0 then
            UI:AskPromotion(R.SquareName(state.sel) .. R.SquareName(sq))
            return
        end
        PlayMove(R.MoveText(m))
        return
    end
    local v = pos.b[sq]
    if v ~= 0 and (v > 0) == (g.me > 0) then
        if state.sel == sq then ClearSelection() else Select(sq) end
    else
        ClearSelection()
    end
end

-- The promotion choice: queen, rook, bishop or knight (portraits of your side's pieces).
function UI:AskPromotion(base)
    local g = state.game
    if not promo then
        promo = CreateFrame("Frame", nil, boardArea)
        promo:SetSize(4 * 58 + 20, 92)
        promo:SetPoint("CENTER")
        promo:SetFrameLevel(boardArea:GetFrameLevel() + 500)
        local bg = promo:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.05, 0.09, 0.96)
        ns.UI:AddEdges(promo)
        ns.UI:SetEdgeColor(promo, VIOLET[1], VIOLET[2], VIOLET[3], 0.8)
        promo.title = Label(promo, 12, "GameFontNormal")
        promo.title:SetPoint("TOP", 0, -8)
        promo.title:SetText("Promote to")
        promo.buttons = {}
        for i, p in ipairs({ 5, 4, 3, 2 }) do
            local b = CreateFrame("Button", nil, promo)
            b:SetSize(50, 50)
            b:SetPoint("TOPLEFT", 10 + (i - 1) * 58, -28)
            b.face = b:CreateTexture(nil, "ARTWORK")
            b.face:SetAllPoints()
            pcall(b.face.SetMask, b.face, CIRCLE)
            b.hl = b:CreateTexture(nil, "HIGHLIGHT")
            b.hl:SetAllPoints()
            b.hl:SetTexture(CIRCLE)
            b.hl:SetVertexColor(1, 1, 1, 0.25)
            b.name = Label(b, 10, "GameFontHighlightSmall")
            b.name:SetPoint("TOP", b, "BOTTOM", 0, -1)
            b.name:SetText(PIECE_NAME[p]:gsub("^%l", string.upper))
            b.p = p
            b:SetScript("OnClick", function() PlayMove(promo.base .. R.LETTER[p]) end)
            promo.buttons[i] = b
        end
    end
    promo.base = base
    for _, b in ipairs(promo.buttons) do Portrait(b.face, (PieceDisplay(b.p * g.me))) end
    promo:Show()
end

---------------------------------------------------------------------------
-- The side column: lobby
---------------------------------------------------------------------------

local function Section(parent, text)
    local fs = Label(parent, 11, "GameFontNormalSmall")
    fs:SetText(text:upper())
    fs:SetTextColor(VIOLET[1], VIOLET[2], VIOLET[3])
    return fs
end

-- A row of choice buttons (one chosen): defs = { { text, value } }, get(), set(v).
local function Choices(parent, defs, width, get, set)
    local row = { buttons = {} }
    local bw = floor((width - (#defs - 1) * 4) / #defs)
    for i, d in ipairs(defs) do
        local b = ns.UI:CreateSleekButton(parent, d[1], bw, 22, function()
            set(d[2])
            row:Refresh()
        end)
        b.value = d[2]
        row.buttons[i] = b
    end
    function row:Refresh()
        local v = get()
        for _, b in ipairs(self.buttons) do b:SetKind(b.value == v and "chosen" or "secondary") end
    end
    function row:Place(anchor, dy)
        for i, b in ipairs(self.buttons) do
            b:ClearAllPoints()
            if i == 1 then b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, dy or -6)
            else b:SetPoint("LEFT", self.buttons[i - 1], "RIGHT", 4, 0) end
        end
    end
    row:Refresh()
    return row
end

local function GameStatusText(g)
    local C = Chess()
    local name = C:OpponentName(g)
    if g.status == "invited" then return "|cffc9a2ffInvites you|r" end
    if g.status == "asked" then return "|cff8a8a8aWaiting to accept|r" end
    if g.status == "over" then
        local r = C:MyResult(g)
        if r == "win" then return "|cff5fd35fWon|r" elseif r == "loss" then return "|cffff6a5aLost|r" end
        return "|cffd0d0d0Draw|r"
    end
    if C:MyTurn(g) then return "|cffffd100Your move|r" end
    if g.mode == "ai" then return "|cff8a8a8aThinking|r" end
    return "|cff8a8a8a" .. name .. "'s move|r"
end

-- How many list rows fit under the lobby's controls (the list starts about 262 px down the column).
local function RowsVisible()
    local h = lobby.list and lobby.list:GetHeight() or 0
    if h <= 0 then h = (H > 0 and H or FALLBACK_H) - 262 - PAD end
    return max(3, floor((h + 4) / ROW_H))
end

local function MakeRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(ROW_H - 4)
    r:RegisterForClicks("LeftButtonUp")
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetColorTexture(1, 1, 1, 0.035)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(VIOLET[1], VIOLET[2], VIOLET[3], 0.12)
    r.name = Label(r, 12)
    r.name:SetPoint("TOPLEFT", 8, -7)
    r.sub = Label(r, 10, "GameFontDisableSmall")
    r.sub:SetPoint("BOTTOMLEFT", 8, 7)
    r.right = Label(r, 11)
    r.right:SetJustifyH("RIGHT")
    r.right:SetPoint("TOPRIGHT", -8, -7)          -- (on the name's line: the line under it runs the whole row)
    r.name:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
    r.sub:SetPoint("RIGHT", r, "RIGHT", -8, 0)
    return r
end

local function BuildLobby()
    local f = CreateFrame("Frame", nil, side)
    f:SetAllPoints()
    lobby.frame = f
    local inner = SIDE_W - 2 * PAD
    lobby.title = Label(f, 18, "GameFontNormalLarge")
    lobby.title:SetPoint("TOPLEFT", PAD, -PAD)
    lobby.title:SetText("Karazhan Chess")
    lobby.title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

    lobby.aiHead = Section(f, "Play the Echo of Medivh")
    lobby.aiHead:SetPoint("TOPLEFT", lobby.title, "BOTTOMLEFT", 0, -14)
    local S = ns.ChessAI.STRENGTH
    lobby.strength = Choices(f, { { S.apprentice.name, "apprentice" }, { S.magus.name, "magus" },
                                  { S.guardian.name, "guardian" } }, inner,
        function() return Prefs().strength end, function(v) Prefs().strength = v end)
    lobby.strength:Place(lobby.aiHead, -6)
    lobby.color = Choices(f, { { "Alliance", 1 }, { "Horde", -1 }, { "Random", 0 } }, inner,
        function() return Prefs().color end, function(v) Prefs().color = v end)
    lobby.color:Place(lobby.strength.buttons[1], -6)
    lobby.cheats = ns.UI:CreateSwitch(f, function() return Prefs().cheats end,
        function(v) Prefs().cheats = v and true or false end, "Medivh cheats")
    lobby.cheats:SetPoint("TOPLEFT", lobby.color.buttons[1], "BOTTOMLEFT", 0, -10)
    lobby.play = ns.UI:CreateSleekButton(f, "Play", inner, 26, function()
        local p = Prefs()
        local g, why = Chess():NewAIGame(p.color, p.strength, p.cheats)
        if not g then
            ns:Print("Karazhan Chess: too many open games (%d); finish or resign one first.", Chess().MAX_ACTIVE)
            return
        end
        UI:OpenGame(g)
        Say(LINES.begin[1])
    end, "primary")
    lobby.play:SetPoint("TOPLEFT", lobby.cheats, "BOTTOMLEFT", 0, -10)

    lobby.guildHead = Section(f, "Challenge a guild member")
    lobby.guildHead:SetPoint("TOPLEFT", lobby.play, "BOTTOMLEFT", 0, -16)
    lobby.who = ns.UI:CreateSleekDropdown(f, inner - 70, function()
        local out = {}
        local me = ns.Util.PlayerKey()
        for _, key in ipairs(ns.Guild and ns.Guild:GetOnlineMembers() or {}) do
            if key ~= me then out[#out + 1] = { text = ns.Util.ShortName(key) or key, value = key } end
        end
        if #out == 0 then out[1] = { text = "Nobody else is on", value = nil, disabled = true } end
        return out
    end, function() return state.invitee end, function(v) state.invitee = v end)
    lobby.who:SetDefaultText("Online members")
    lobby.who:SetPoint("TOPLEFT", lobby.guildHead, "BOTTOMLEFT", 0, -6)
    lobby.invite = ns.UI:CreateSleekButton(f, "Invite", 64, 22, function()
        if not state.invitee then return end
        local g, why = Chess():Invite(state.invitee, Prefs().color)
        if g then
            ns:Print("Chess invite sent to %s.", ns.Util.ShortName(state.invitee) or state.invitee)
        else
            ns:Print("Karazhan Chess: could not invite (%s).", tostring(why))
        end
    end)
    lobby.invite:SetPoint("LEFT", lobby.who, "RIGHT", 6, 0)

    lobby.tabGames = ns.UI:CreateUnderlineTab(f, "Your games", function() state.tab, state.listOff = "games", 0 UI:RefreshSide() end, "small")
    lobby.tabGames:SetPoint("TOPLEFT", lobby.who, "BOTTOMLEFT", 0, -14)
    lobby.tabLadder = ns.UI:CreateUnderlineTab(f, "Guild ladder", function() state.tab, state.listOff = "ladder", 0 UI:RefreshSide() end, "small")
    lobby.tabLadder:SetPoint("LEFT", lobby.tabGames, "RIGHT", 10, 0)

    lobby.list = CreateFrame("Frame", nil, f)
    lobby.list:SetPoint("TOPLEFT", lobby.tabGames, "BOTTOMLEFT", 0, -6)
    lobby.list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD)
    lobby.list:EnableMouseWheel(true)
    lobby.list:SetScript("OnMouseWheel", function(_, d)
        state.listOff = max(0, state.listOff - d)
        UI:RefreshSide()
    end)
    lobby.rows = {}
    lobby.empty = Label(lobby.list, 11, "GameFontDisableSmall")
    lobby.empty:SetPoint("TOPLEFT", 4, -6)
    lobby.empty:SetWidth(inner - 8)
    lobby.empty:SetWordWrap(true)
end

local function LobbyRow(i)
    local r = lobby.rows[i]
    if r then return r end
    r = MakeRow(lobby.list)
    r:SetPoint("TOPLEFT", lobby.list, "TOPLEFT", 0, -(i - 1) * ROW_H)
    r:SetPoint("RIGHT", lobby.list, "RIGHT", 0, 0)
    r.accept = ns.UI:CreateSleekButton(r, "Accept", 54, 20, function() if r.game then Chess():Accept(r.game) UI:OpenGame(r.game) end end, "primary")
    r.accept:SetPoint("RIGHT", -62, 0)
    r.decline = ns.UI:CreateSleekButton(r, "No", 50, 20, function() if r.game then Chess():Decline(r.game) end end)
    r.decline:SetPoint("RIGHT", -6, 0)
    r:SetScript("OnClick", function(_, button)
        if r.game and r.game.status ~= "invited" then UI:OpenGame(r.game) end
    end)
    lobby.rows[i] = r
    return r
end

local function RefreshLobby()
    local C = Chess()
    lobby.strength:Refresh()
    lobby.color:Refresh()
    lobby.who:Refresh()
    lobby.invite:SetEnabled(state.invitee ~= nil)
    lobby.tabGames:SetActive(state.tab == "games")
    lobby.tabLadder:SetActive(state.tab == "ladder")
    local show = RowsVisible()
    local items = {}
    if state.tab == "games" then
        for _, g in ipairs(C:List()) do items[#items + 1] = g end
        lobby.empty:SetText(#items == 0 and "No games yet. Play the Echo of Medivh, or invite someone who is on." or "")
    else
        items = C:Ratings()
        lobby.empty:SetText(#items == 0 and "No guild games played yet. Results of games between guild members show here, rated for everyone the same way." or "")
    end
    state.listOff = max(0, min(state.listOff, #items - show))
    for i = 1, max(#lobby.rows, show) do
        local r = (i <= show) and LobbyRow(i) or lobby.rows[i]
        local it = items[i + state.listOff]
        if r then
            if i <= show and it then
                r.game = nil
                r.accept:Hide()
                r.decline:Hide()
                r.right:Show()
                if state.tab == "games" then
                    local g = it
                    r.game = g
                    local opp = C:OpponentName(g)
                    local cls = g.mode == "guild" and ns.Guild and ns.Guild:GetClass(g.opp)
                    local hex = cls and ns.Util.ClassColorHex and ns.Util.ClassColorHex(cls)
                    r.name:SetText((hex and ("|c" .. hex) or "") .. opp .. (hex and "|r" or ""))
                    local sub = {}
                    sub[#sub + 1] = "as " .. SIDE_NAME[g.me]
                    if g.mode == "ai" then
                        sub[#sub + 1] = ns.ChessAI.STRENGTH[g.strength] and ns.ChessAI.STRENGTH[g.strength].name or ""
                        if g.cheats then sub[#sub + 1] = "cheats" end
                    end
                    if #g.moves > 0 then sub[#sub + 1] = "move " .. (floor((#g.moves - 1) / 2) + 1) end
                    r.sub:SetText(table.concat(sub, "  \194\183  "))
                    r.right:SetText(GameStatusText(g))
                    if g.status == "invited" then
                        r.right:Hide()
                        r.accept:Show()
                        r.decline:Show()
                    end
                else
                    local p = it
                    local me = ns.Util.IsMe(p.key)
                    r.name:SetText(string.format("%d. %s%s", i + state.listOff, me and "|cffffd100" or "",
                        (ns.Util.ShortName(p.key) or p.key) .. (me and "|r" or "")))
                    r.sub:SetText(string.format("%d won  \194\183  %d lost  \194\183  %d drawn", p.w, p.l, p.d))
                    r.right:SetText("|cffffffff" .. p.rating .. "|r")
                end
                r:Show()
            else
                r:Hide()
            end
        end
    end
end

---------------------------------------------------------------------------
-- The side column: a game
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Playing: the board fills the page, with a light layer over it (no column): who and whose move top left, a few
-- small buttons top right, Medivh's words as subtitles at the bottom, the taken pieces in the bottom corners, the
-- moves in a see-through drawer when asked for, and a card in the middle only when something needs an answer
---------------------------------------------------------------------------

local LINE_H = 17
local SUB_TIME = 7             -- s Medivh's words stay before they fade
local HINT_TIME = 7            -- s the controls hint shows after a game opens

local gradA = CreateColor and CreateColor(0, 0, 0, 0)
local gradB = CreateColor and CreateColor(0, 0, 0, 0)
-- A gradient (orient "VERTICAL": colour 1 at the bottom) or, without SetGradient, its midpoint.
local function Gradient(tex, orient, r1, g1, b1, a1, r2, g2, b2, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if gradA and tex.SetGradient then
        gradA:SetRGBA(r1, g1, b1, a1)
        gradB:SetRGBA(r2, g2, b2, a2)
        tex:SetGradient(orient, gradA, gradB)
    else
        tex:SetColorTexture((r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2, (a1 + a2) / 2)
    end
end

local function Shadowed(fs)
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 1)
    return fs
end

-- The spells' own icons (Fury of Medivh 39345, Hand of Medivh 39339, the Cleric's Healing 37455)
local CHEAT_ICON = { fire = 135819, hand = 136130, heal = 135915 }

-- One short line for a cheat in the move list (the whole sentence is under Medivh's words when it happens).
local function CheatLine(ev)
    local sq = table.concat(ev.sq or {}, ", ")
    local text
    if ev.k == "fire" then text = "Fire under " .. sq
    elseif ev.k == "hand" then text = "Hand of Medivh: " .. sq
    else text = "His " .. (PIECE_NAME[tonumber(ev.p) or 0] or "piece") .. " returns on " .. sq end
    return string.format("|T%d:12:12|t |cffc9a2ff%s|r", CHEAT_ICON[ev.k] or CHEAT_ICON.fire, text)
end

-- The move list's lines: "12. Nf3  e5", Medivh's cheats and the fire's victims between them.
local function MoveLines(g, info)
    local out = {}
    local n = #g.moves
    for i = 1, n, 2 do
        local a, b = info.sans[i] or g.moves[i], info.sans[i + 1] or g.moves[i + 1] or ""
        out[#out + 1] = string.format("|cff8a8a8a%d.|r  %s%s|r  %s%s|r", floor(i / 2) + 1,
            i == n and "|cffffffff" or "|cffd8d8d8", a, i + 1 == n and "|cffffffff" or "|cffd8d8d8", b)
        for k = i, min(n, i + 1) do
            local ev = info.cheatAt[k]
            if ev then out[#out + 1] = "  " .. CheatLine(ev) end
            for _, bu in ipairs(info.burned[k] or {}) do
                out[#out + 1] = string.format("  |T%d:12:12|t |cffff8a3aBurned: %s on %s|r", CHEAT_ICON.fire,
                    PIECE_NAME[abs(bu.v)], R.SquareName(bu.sq))
            end
        end
    end
    return out
end

-- Whose move, in a few words (under the opponent's name).
local function StatusText(g)
    local C = Chess()
    local name = C:OpponentName(g)
    if g.status == "invited" then return "|cffc9a2ffInvites you to a game|r" end
    if g.status == "asked" then return "|cff8a8a8aInvite sent|r" end
    if g.status == "over" then
        local r = C:MyResult(g)
        local why = REASON[g.reason] or g.reason or ""
        if r == "win" then return "|cff5fd35fYou won|r by " .. why end
        if r == "loss" then return "|cffff6a5a" .. name .. " won|r by " .. why end
        return "|cffd0d0d0Draw|r by " .. why
    end
    local pos = C:Position(g)
    local check = R.InCheck(pos) and "  \194\183  |cffff6a5aCheck|r" or ""
    if C:MyTurn(g) then return "|cffffd100Your move|r" .. check end
    if g.mode == "ai" then return "|cffc9a2ffMedivh is thinking...|r" .. check end
    local pending = #g.moves > (tonumber(g.acked) or 0)
    return "|cffd0d0d0" .. name .. "'s move|r" .. check
        .. (pending and "  \194\183  |cff8a8a8aon its way to them|r" or "")
end

local function MoreMenu(owner)
    local g = state.game
    if not g then return end
    ns.UI:ContextMenu(owner, function(m)
        if g.mode == "guild" and g.status == "active" then
            local theirs = g.drawFrom and g.drawFrom ~= ns.Util.PlayerKey()
            if theirs then
                m:CreateButton("Accept the draw", function() Chess():AnswerDraw(g, true) end)
            elseif not g.drawFrom then
                m:CreateButton("Offer a draw", function() Chess():OfferDraw(g) end)
            end
        end
        if g.status == "active" then
            m:CreateButton("|cffff6a5aResign|r", function() Chess():Resign(g) end)
        elseif g.status == "asked" then
            m:CreateButton("Cancel the invite", function() Chess():Delete(g) UI:OpenLobby() end)
        elseif g.status == "over" then
            m:CreateButton("Play again", function() UI:PlayAgain(g) end)
            m:CreateButton("Remove this game", function() Chess():Delete(g) UI:OpenLobby() end)
        end
        m:CreateDivider()
        m:CreateButton("Back to the games", function() UI:OpenLobby() end)
    end)
end

function UI:PlayAgain(g)
    if g.mode == "ai" then
        local ng = Chess():NewAIGame(-g.me, g.strength, g.cheats)
        if ng then UI:OpenGame(ng) Say(LINES.begin[1]) end
    else
        local ng = Chess():Invite(g.opp, -g.me)
        if ng then UI:OpenGame(ng) end
    end
end

local function TakenRow(parent, anchor, x, dir)
    local row = { icons = {} }
    for i = 1, 15 do
        local t = parent:CreateTexture(nil, "ARTWORK")
        t:SetSize(18, 18)
        pcall(t.SetMask, t, CIRCLE)
        t:SetPoint(anchor, parent, anchor, x + dir * (i - 1) * 15, 12)
        t:Hide()
        row.icons[i] = t
    end
    row.diff = Shadowed(Label(parent, 11, "GameFontHighlightSmall"))
    row.dir, row.anchor = dir, anchor
    return row
end

local function BuildHud()
    local f = CreateFrame("Frame", nil, boardArea)
    f:SetAllPoints()
    f:SetFrameLevel(boardArea:GetFrameLevel() + 450)
    hud.frame = f
    -- soft shade along the top and bottom edges: the words read over the hall
    local top = f:CreateTexture(nil, "BACKGROUND")
    top:SetPoint("TOPLEFT")
    top:SetPoint("TOPRIGHT")
    top:SetHeight(70)
    Gradient(top, "VERTICAL", 0, 0, 0, 0, 0, 0, 0, 0.6)
    local bottom = f:CreateTexture(nil, "BACKGROUND")
    bottom:SetPoint("BOTTOMLEFT")
    bottom:SetPoint("BOTTOMRIGHT")
    bottom:SetHeight(80)
    Gradient(bottom, "VERTICAL", 0, 0, 0, 0.62, 0, 0, 0, 0)

    -- top left: back to the games, who, whose move
    hud.back = ns.UI:CreateSleekButton(f, "\226\128\185 Games", 66, 22, function() UI:OpenLobby() end)
    hud.back:SetPoint("TOPLEFT", 12, -12)
    hud.vs = Shadowed(Label(f, 15, "GameFontNormalLarge"))
    hud.vs:SetPoint("TOPLEFT", hud.back, "TOPRIGHT", 10, 1)
    hud.status = Shadowed(Label(f, 11))
    hud.status:SetPoint("TOPLEFT", hud.vs, "BOTTOMLEFT", 0, -3)

    -- top right: the moves, the board turned, 3D or flat, the rest
    hud.more = ns.UI:CreateSleekButton(f, "\194\183\194\183\194\183", 30, 22, function(b) MoreMenu(b) end)
    hud.more:SetPoint("TOPRIGHT", -12, -12)
    hud.mode = ns.UI:CreateSleekButton(f, "Flat", 46, 22, function()
        Prefs().flat = not Prefs().flat
        UI:ApplyBoardMode()
    end)
    hud.mode:SetPoint("RIGHT", hud.more, "LEFT", -4, 0)
    hud.turn = ns.UI:CreateSleekButton(f, "Turn", 46, 22, function()
        if board3d and Use3D() then board3d:Flip() elseif flat then
            flat.me = -flat.me
            flat:SetPosition(flat.pos, flat.me)
        end
    end)
    hud.turn:SetPoint("RIGHT", hud.mode, "LEFT", -4, 0)
    hud.moves = ns.UI:CreateSleekButton(f, "Moves", 56, 22, function()
        Prefs().moves = not Prefs().moves
        LayoutBoard()
        UI:RefreshSide()
    end)
    hud.moves:SetPoint("RIGHT", hud.turn, "LEFT", -4, 0)

    -- the moves: a see-through drawer down the right side
    local d = CreateFrame("Frame", nil, f)
    d:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -42)
    d:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 64)
    d:SetWidth(DRAWER_W)
    local dbg = d:CreateTexture(nil, "BACKGROUND")
    dbg:SetAllPoints()
    dbg:SetColorTexture(0.03, 0.025, 0.05, 0.84)
    ns.UI:AddEdges(d)
    ns.UI:SetEdgeColor(d, VIOLET[1], VIOLET[2], VIOLET[3], 0.3)
    d:EnableMouseWheel(true)
    d:SetScript("OnMouseWheel", function(_, delta)
        state.moveOff = max(0, state.moveOff - delta)
        state.moveFollow = false
        UI:RefreshSide()
    end)
    d.lines = {}
    hud.drawer = d

    -- the bottom: Medivh's words (fading), what a cheat does (until the next move), the hint at first
    hud.sub = Shadowed(Label(f, 14))
    hud.sub:SetPoint("BOTTOM", f, "BOTTOM", 0, 34)
    hud.sub:SetJustifyH("CENTER")
    hud.sub:SetWidth(540)
    hud.sub:SetWordWrap(true)
    hud.note = Shadowed(Label(f, 11, "GameFontHighlightSmall"))
    hud.note:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    hud.note:SetJustifyH("CENTER")
    hud.note:SetWidth(520)
    hud.note:SetWordWrap(true)

    -- the taken pieces: yours of theirs bottom left, theirs of yours bottom right
    hud.taken = { TakenRow(f, "BOTTOMLEFT", 14, 1), TakenRow(f, "BOTTOMRIGHT", -14, -1) }

    -- a card in the middle, only when something needs an answer (an invite, a draw offered, the end)
    local card = CreateFrame("Frame", nil, f)
    card:SetSize(320, 118)
    card:SetPoint("CENTER", f, "CENTER", 0, 10)
    card:SetFrameLevel(f:GetFrameLevel() + 20)
    card:EnableMouse(true)
    local cbg = card:CreateTexture(nil, "BACKGROUND")
    cbg:SetAllPoints()
    cbg:SetColorTexture(0.045, 0.035, 0.07, 0.94)
    ns.UI:AddEdges(card)
    ns.UI:SetEdgeColor(card, VIOLET[1], VIOLET[2], VIOLET[3], 0.6)
    card.title = Label(card, 17, "GameFontNormalLarge")
    card.title:SetPoint("TOP", 0, -16)
    card.title:SetJustifyH("CENTER")
    card.text = Label(card, 11, "GameFontHighlightSmall")
    card.text:SetPoint("TOP", card.title, "BOTTOM", 0, -8)
    card.text:SetWidth(290)
    card.text:SetWordWrap(true)
    card.text:SetJustifyH("CENTER")
    card.b1 = ns.UI:CreateSleekButton(card, "", 112, 24, function() if card.do1 then card.do1() end end, "primary")
    card.b2 = ns.UI:CreateSleekButton(card, "", 112, 24, function() if card.do2 then card.do2() end end)
    card.b1:SetPoint("BOTTOMRIGHT", card, "BOTTOM", -4, 14)
    card.b2:SetPoint("BOTTOMLEFT", card, "BOTTOM", 4, 14)
    card.close = ns.UI:CreateSleekButton(card, "\195\151", 22, 20, function()
        if state.game then state.cardOff[state.game.id] = true end
        UI:RefreshSide()
    end)
    card.close:SetPoint("TOPRIGHT", -6, -6)
    card:Hide()
    hud.card = card

    f:SetScript("OnUpdate", function()
        local now = GetTime()
        if hud.subUntil and now > hud.subUntil then
            local a = 1 - min(1, (now - hud.subUntil) / 0.8)
            hud.sub:SetAlpha(a)
            if a <= 0 then hud.subUntil = nil hud.sub:SetText("") hud.sub:SetAlpha(1) end
        end
        if state.hintUntil and now > state.hintUntil then
            state.hintUntil = nil
            UI:RefreshSide()
        end
    end)
    f:Hide()
end

-- Medivh's words at the bottom of the board.
function UI:Subtitle(text)
    if not hud.sub then return end
    hud.sub:SetText(text and ("|cffc9a2ffEcho of Medivh:|r  " .. text) or "")
    hud.sub:SetAlpha(1)
    hud.subUntil = text and (GetTime() + SUB_TIME) or nil
end

local function ShowCard(title, text, b1, do1, b2, do2, closable)
    local c = hud.card
    c.title:SetText(title)
    c.text:SetText(text or "")
    c.b1:SetText(b1 or "")
    c.b1:SetShown(b1 ~= nil)
    c.b2:SetText(b2 or "")
    c.b2:SetShown(b2 ~= nil)
    c.do1, c.do2 = do1, do2
    c.close:SetShown(closable and true or false)
    c:SetHeight(max(104, 76 + (c.text:GetStringHeight() or 14)))
    c:Show()
end

local function RefreshCard(g)
    local C = Chess()
    local name = C:OpponentName(g)
    local theirDraw = g.drawFrom and g.drawFrom ~= ns.Util.PlayerKey()
    if g.status == "invited" then
        ShowCard("A game with " .. name, string.format("%s invites you to chess. You would play the %s.", name,
            SIDE_NAME[g.me]), "Accept", function() C:Accept(g) end, "Decline",
            function() C:Decline(g) UI:OpenLobby() end)
    elseif g.status == "asked" then
        ShowCard("Waiting for " .. name, "They see your invite now, or when they next log in.", "Back to games",
            function() UI:OpenLobby() end, "Cancel invite", function() C:Delete(g) UI:OpenLobby() end)
    elseif g.status == "active" and theirDraw then
        ShowCard("A draw?", name .. " offers a draw.", "Accept draw", function() C:AnswerDraw(g, true) end,
            "Play on", function() C:AnswerDraw(g, false) end)
    elseif g.status == "over" and not state.cardOff[g.id] then
        local r = C:MyResult(g)
        local title = r == "win" and "|cff5fd35fYou won|r" or (r == "loss" and ("|cffff6a5a" .. name .. " won|r")
            or "Draw")
        ShowCard(title, "by " .. (REASON[g.reason] or g.reason or "") .. ".", "Play again",
            function() UI:PlayAgain(g) end, "Back to games", function() UI:OpenLobby() end, true)
    else
        hud.card:Hide()
    end
end

local function RefreshGame()
    local g = state.game
    if not g then return end
    local C = Chess()
    local _, info = C:Position(g)
    local name = C:OpponentName(g)
    local theirC = SIDE_COLOR[-g.me]
    local bits = {}
    if g.mode == "ai" then
        local st = ns.ChessAI.STRENGTH[g.strength]
        bits[#bits + 1] = st and st.name or g.strength
        if g.cheats then bits[#bits + 1] = "he cheats" end
    else
        bits[#bits + 1] = "guild game"
    end
    hud.vs:SetText(string.format("%s%s|r  |cff8a8a8a%s|r", Hex(theirC), name, table.concat(bits, "  \194\183  ")))
    hud.status:SetText(string.format("%sYou|r |cff8a8a8a(%s)|r  %s", Hex(SIDE_COLOR[g.me]), SIDE_NAME[g.me],
        StatusText(g)))
    -- what a cheat does, else the hint for the first moments
    local note = state.note
    if not note and state.hintUntil then
        note = "|cff9a9a9a" .. (Use3D() and "Click a piece, then its square.  Right-drag turns the camera, the wheel zooms."
            or "Click a piece, then its square.  A right-click lets go.") .. "|r"
    end
    hud.note:SetText(note or "")
    -- the moves drawer
    local open = Prefs().moves and true or false
    hud.drawer:SetShown(open)
    hud.moves:SetKind(open and "chosen" or "secondary")
    if open then
        local d = hud.drawer
        local h = d:GetHeight() or 0
        if h <= 0 then h = (H > 0 and H or FALLBACK_H) - 106 end
        local rows = max(4, floor((h - 12) / LINE_H))
        local lines = MoveLines(g, info)
        if state.moveFollow ~= false then state.moveOff = max(0, #lines - rows) end
        state.moveOff = max(0, min(state.moveOff, #lines - rows))
        for i = 1, max(rows, #d.lines) do
            local fs = d.lines[i]
            if not fs and i <= rows then
                fs = Label(d, 11)
                fs:SetPoint("TOPLEFT", 10, -6 - (i - 1) * LINE_H)
                fs:SetWidth(DRAWER_W - 20)
                d.lines[i] = fs
            end
            if fs then
                local t = i <= rows and lines[i + state.moveOff] or nil
                fs:SetText(t or (i == 1 and #lines == 0 and "|cff8a8a8aNo moves yet.|r" or ""))
            end
        end
    end
    -- the taken pieces, biggest first, and who is ahead
    local VAL = { 1, 3, 3, 5, 9, 0 }
    local sums = {}
    for k, lostSide in ipairs({ -g.me, g.me }) do
        local row = hud.taken[k]
        local list = {}
        for _, p in ipairs(info.taken[lostSide] or {}) do list[#list + 1] = p end
        table.sort(list, function(a, b) return a > b end)
        local s = 0
        for i, icon in ipairs(row.icons) do
            local p = list[i]
            if p then
                Portrait(icon, (PieceDisplay(p * lostSide)))
                icon:Show()
                s = s + VAL[p]
            else
                icon:Hide()
            end
        end
        sums[k] = s
        row.diff:ClearAllPoints()
        local last = row.icons[min(15, max(1, #list))]
        if row.dir > 0 then
            row.diff:SetPoint("LEFT", last, #list > 0 and "RIGHT" or "LEFT", 5, 0)
        else
            row.diff:SetPoint("RIGHT", last, #list > 0 and "LEFT" or "RIGHT", -5, 0)
        end
    end
    local lead = sums[1] - sums[2]
    hud.taken[1].diff:SetText(lead > 0 and ("+" .. lead) or "")
    hud.taken[2].diff:SetText(lead < 0 and ("+" .. -lead) or "")
    hud.mode:SetText(Use3D() and "Flat" or "3D")
    hud.mode:SetShown(board3d ~= nil)
    RefreshCard(g)
end

function UI:RefreshSide()
    if not root then return end
    local playing = state.game ~= nil
    if playing ~= state.immersive then UI:SetImmersive(playing) end
    if playing then
        lobby.frame:Hide()
        RefreshGame()
    else
        lobby.frame:Show()
        RefreshLobby()
    end
end

---------------------------------------------------------------------------
-- Opening games, the lobby
---------------------------------------------------------------------------

function UI:OpenGame(g)
    if state.game ~= g then state.note = nil end
    state.game = g
    state.sel, state.targets = nil, {}
    state.moveFollow = true
    state.hintUntil = GetTime() + HINT_TIME
    if promo then promo:Hide() end
    if board3d then board3d:FaceSide(g.me, true) end
    ShowPosition()
    self:RefreshSide()
end

function UI:OpenLobby()
    state.game = nil
    state.sel, state.targets = nil, {}
    if promo then promo:Hide() end
    ShowPosition()
    self:RefreshSide()
end

function UI:Game() return state.game end

-- After a move was shown on the board: Medivh's cheat (his cast, his line, the effect), his remark on a fallen piece.
local function AfterMove(g, mi)
    if state.game ~= g then return end
    ShowPosition()
    if mi.cheat then
        local C = ns.ChessCheats
        state.note = C.Describe(mi.cheat, "Medivh")
        local line = C.LINES[tonumber(mi.cheat.line) or 1] or C.LINES[1]
        Say({ line.text, line.sound })
        if board3d then
            board3d:MedivhCast()
            if mi.cheat.k == "heal" then
                local sq = R.ParseSquare(mi.cheat.sq and mi.cheat.sq[1] or "")
                local fx = (g.me == 1) and C.FX.healH or C.FX.healA
                if sq then board3d:Flash(fx.fdid, sq, 1.6, 2.5) end
            end
        end
    elseif mi.cap and mi.cap ~= 0 then
        Remark(g, mi.cap)
    end
    if g.status == "over" and g.mode == "ai" then
        local r = Chess():MyResult(g)
        if r == "win" then Say(LINES.medivhLost[6][1]) elseif r == "loss" then Say(LINES.playerLost[6][1]) end
    end
    UI:RefreshSide()
end

local function OnUpdated(id, what, mi)
    if not root or not root:IsShown() then return end
    local g = state.game
    if g and not Chess():Get(g.id) then
        UI:OpenLobby()
        return
    end
    if g and id == g.id then
        if what == "move" and mi then
            state.sel, state.targets = nil, {}
            state.note = nil
            if promo then promo:Hide() end
            local pos = Chess():Position(g)
            if board3d and Use3D() then
                board3d.opts.onAnimDone = function() AfterMove(g, mi) end
                board3d:Animate(mi, pos)
                if flat then flat:SetPosition(pos, flat.me) end
                ShowMarks()
            else
                AfterMove(g, mi)
            end
        else
            ShowPosition()
        end
    elseif not g and what ~= "thinking" then
        ShowPosition()
    end
    UI:RefreshSide()
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

local function ApplyBoardMode()
    local use3d = Use3D()
    if state.immersive then UI:RefreshSide() end
    if board3d then if use3d then board3d:Show() else board3d:Hide() end end
    if flat then flat.frame:SetShown(not use3d) end
    if UI.modeButton then
        UI.modeButton:SetText(use3d and "Flat board" or "3D hall")
        UI.modeButton:SetShown(board3d ~= nil and not state.immersive)
    end
    if UI.hint then
        if use3d then
            UI.hint:SetText("Click a piece, then its square.  Right-drag: turn the camera.  Wheel: zoom.")
        elseif state.restartNote then
            UI.hint:SetText("Restart the game client once to see the Gamesman's Hall in 3D.")
        else
            UI.hint:SetText("Click a piece, then its square.  Right-click lets go.")
        end
    end
    ShowPosition()
end
function UI:ApplyBoardMode() ApplyBoardMode() end

function UI:CreatePanel(parent)
    root = CreateFrame("Frame", nil, parent)
    root:SetAllPoints()
    local bg = root:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    bg:SetColorTexture(0.035, 0.03, 0.05, 0.96)

    boardArea = CreateFrame("Frame", nil, root)
    boardArea:SetPoint("TOPLEFT", 0, 0)
    boardArea:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -SIDE_W, 0)
    boardArea:SetClipsChildren(true)

    side = CreateFrame("Frame", nil, root)
    side:SetPoint("TOPLEFT", boardArea, "TOPRIGHT", 0, 0)
    side:SetPoint("BOTTOMRIGHT", 0, 0)
    local sbg = side:CreateTexture(nil, "BACKGROUND")
    sbg:SetAllPoints()
    sbg:SetColorTexture(0.06, 0.05, 0.08, 0.98)
    local rule = side:CreateTexture(nil, "BORDER")
    rule:SetPoint("TOPLEFT")
    rule:SetPoint("BOTTOMLEFT")
    rule:SetWidth(1)
    rule:SetColorTexture(VIOLET[1], VIOLET[2], VIOLET[3], 0.35)

    flat = Flat.New(boardArea, OnSquare)
    board3d = ns.ChessBoard3D and ns.ChessBoard3D.New(boardArea, { onSquare = OnSquare })
    if not board3d and not (ns.ChessBoard3D and ns.ChessBoard3D.Available()) then
        state.restartNote = true
    end
    -- the board's own controls (over the board, top right)
    UI.modeButton = ns.UI:CreateSleekButton(boardArea, "Flat board", 84, 20, function()
        Prefs().flat = not Prefs().flat
        ApplyBoardMode()
    end)
    UI.modeButton:SetPoint("TOPRIGHT", -8, -8)
    UI.modeButton:SetFrameLevel(boardArea:GetFrameLevel() + 460)
    UI.hint = Label(boardArea, 10, "GameFontDisableSmall")
    UI.hint:SetPoint("BOTTOMLEFT", 10, 8)
    -- (a hint line over the 3D view's frames)
    local hintHost = CreateFrame("Frame", nil, boardArea)
    hintHost:SetAllPoints()
    hintHost:SetFrameLevel(boardArea:GetFrameLevel() + 450)
    UI.hint:SetParent(hintHost)

    BuildLobby()
    BuildHud()

    root:SetScript("OnSizeChanged", function(self, w, h)
        if w and w > 0 then W = w end
        if h and h > 0 then H = h end
        LayoutBoard()
        UI:RefreshSide()
    end)
    LayoutBoard()
    ns:On("CHESS_UPDATED", OnUpdated)
    ns:On("ROSTER_UPDATED", function() if root:IsShown() and not state.game then UI:RefreshSide() end end)
    -- Medivh waits while a move is still being shown
    ns.Chess.hold = function(id)
        return root:IsShown() and state.game ~= nil and state.game.id == id and board3d ~= nil and Use3D()
            and board3d:Busy()
    end
    function root:OnGameShown()
        ApplyBoardMode()
        UI:RefreshSide()
    end
    function root:OnGameHidden()
        if promo then promo:Hide() end
    end
    root:SetScript("OnShow", function() ApplyBoardMode() UI:RefreshSide() end)
    -- open on the game waiting for you, else the lobby
    local first
    for _, g in ipairs(Chess():List()) do
        if Chess():MyTurn(g) then first = g break end
    end
    if first then self:OpenGame(first) else self:OpenLobby() end
    ApplyBoardMode()
    return root
end

-- (tests and the audit) the panel's state
function UI:_State()
    return { game = state.game and state.game.id, sel = state.sel, use3d = Use3D(), has3d = board3d ~= nil,
             tab = state.tab }
end
UI._OnSquare = function(sq, button) OnSquare(sq, button) end
UI._Board3D = function() return board3d end
UI._Flat = function() return flat end
UI._Promo = function() return promo end
UI._Tab = function(tab)
    state.tab, state.listOff = tab, 0
    UI:RefreshSide()
end
UI._Note = function(ev)
    state.note = ev and ns.ChessCheats.Describe(ev, "Medivh") or nil
    UI:RefreshSide()
end
UI._Hud = function() return hud end
