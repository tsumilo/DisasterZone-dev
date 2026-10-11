if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Style.lua", ...) then return end -- DisasterZone UI/Style.lua
-- design values: colours, type scale, spacing, row and banner sizes (refactor 1A).
local addonName, ns = ...

-- ns.Style (local alias in files: `local S = ns.Style`): the one home of the addon's design values. The values are
-- the ones the code typed most often before 1.4, so moving a caller onto a token keeps its look. The older homes
-- (EUI.GOLD / GREY / CARD / EDGE ..., UI.WIN_BG / HUD_BG / DROP_BG / DROP_EDGE ...) are the SAME tables as these
-- (set in Widgets.lua / EventWidgets.lua), so old reads keep working while callers move over. Treat every colour
-- table as read-only: they are shared.
local S = {}
ns.Style = S

local floor, abs, format = math.floor, math.abs, string.format

---------------------------------------------------------------------------
-- Colours: { r, g, b [, a] }. A colour without an alpha is opaque (S:Color returns 1). The ones that were EUI / UI
-- fields keep exactly their old numbers AND their old length (3 or 4 values), since callers unpack them.
---------------------------------------------------------------------------

S.C = {
    -- text and accents
    GOLD       = { 1, 0.82, 0 },              -- D1: text and accents (EUI.GOLD); typed 552 times as 1, 0.82, 0
    GOLD_DEEP  = { 0.91, 0.73, 0.14 },        -- D1: only for fills and edges
    TEXT       = { 0.88, 0.88, 0.88 },        -- EUI.TEXT (the commonest literal is 0.85: kept EUI's 0.88)
    SUB        = { 0.62, 0.62, 0.62 },        -- secondary text (EUI.GREY)
    DIM        = { 0.44, 0.44, 0.46 },        -- quiet hints, disabled (EUI.DIM)
    YOU        = { 0.4, 0.72, 1 },            -- "You" everywhere (EUI.YOU)
    LIVE       = { 1, 0.35, 0.27 },           -- live / now (EUI.LIVE)
    OK         = { 0.30, 0.90, 0.40 },        -- = ns.COLORS.obtained
    WARN       = { 1.00, 0.55, 0.20 },        -- = ns.COLORS.warn
    BAD        = { 1.00, 0.30, 0.30 },        -- = ns.COLORS.bad

    -- surfaces
    SURFACE_WINDOW = { 0.078, 0.078, 0.09 },  -- the windows' slate (UI.WIN_BG, UI.COUNT_SURFACE)
    CARD       = { 0.10, 0.10, 0.12, 0.92 },  -- a card on a page (EUI.CARD)
    INSET      = { 0.06, 0.06, 0.07, 1 },     -- a well inside a card
    QUIET      = { 1, 1, 1, 0.03 },           -- a faint lift (an empty slot, a quiet row)
    STRIPE     = { 1, 1, 1, 0.025 },          -- every other row of a list
    HUD_BG     = { 0.04, 0.04, 0.05, 0.82 },  -- the slim in-raid frames (UI.HUD_BG)
    DROP_BG    = { 0.06, 0.06, 0.07, 0.98 },  -- what drops from a dropdown (UI.DROP_BG)

    -- edges and lines
    EDGE       = { 0.34, 0.34, 0.38, 0.55 },  -- a card's 1 px edge (EUI.EDGE)
    EDGE_QUIET = { 0.34, 0.34, 0.38, 0.45 },
    EDGE_STRONG = { 0.34, 0.34, 0.38, 0.9 },  -- a field's / a dropdown's edge
    EDGE_FOCUS = { 1, 0.82, 0, 0.75 },        -- a field being typed in, a dropdown while its list is open
    DROP_EDGE  = { 0.34, 0.34, 0.38, 1 },     -- (UI.DROP_EDGE)
    HUD_EDGE   = { 0.4, 0.4, 0.4, 0.9 },      -- (UI.HUD_BORDER)
    HAIRLINE   = { 1, 1, 1, 0.07 },           -- a divider (UI:Rule)

    -- states
    HOVER      = { 1, 1, 1, 0.05 },           -- under the mouse
    SELECT     = { 1, 0.82, 0, 0.10 },        -- the picked row's fill ...
}
S.C.SELECT_BAR = S.C.GOLD                     -- ... and its 2 px bar
S.C.GREY = S.C.SUB                            -- (EUI's name)

-- The hex of every colour, for |cff codes: S.HEX.GOLD = "ffd100".
local function Byte(v) return floor((v or 1) * 255 + 0.5) end
S.HEX = {}
for name, c in pairs(S.C) do
    S.HEX[name] = format("%02x%02x%02x", Byte(c[1]), Byte(c[2]), Byte(c[3]))
end

-- A colour by token name, or a { r, g, b [, a] } table as is (nil for anything else).
function S:Resolve(color)
    if type(color) == "string" then return self.C[color] end
    if type(color) == "table" then return color end
    return nil
end

-- r, g, b, a of a token name or colour table (white for unknown; a = 1 when the colour has none).
function S:Color(color)
    local c = self:Resolve(color)
    if not c then return 1, 1, 1, 1 end
    return c[1], c[2], c[3], c[4] or 1
end

-- "|cffffd100" (without the closing "|r"); unknown names give white.
function S:Hex(name)
    return "|cff" .. (self.HEX[name] or "ffffff")
end

-- text wrapped in a token's colour: "|cffffd100text|r".
function S:Wrap(name, text)
    return self:Hex(name) .. tostring(text == nil and "" or text) .. "|r"
end

---------------------------------------------------------------------------
-- Type scale (D2): the only sizes. Any other size (the legacy 9, 10.5, 11.5, 12.5, 14 ...) snaps to the nearest step;
-- a tie goes to the smaller step (a text that fitted at 10.5 still fits at 10). Sizes past S.FONT_DISPLAY are display
-- numerals (a countdown, a game's big digits), not text: they pass through unchanged.
---------------------------------------------------------------------------

S.FONT = { hero = 19, page = 17, title = 13, emph = 12, body = 11, small = 10, caps = 9.5 }
S.FONT_STEPS = { 9.5, 10, 11, 12, 13, 17, 19 }        -- the scale, ascending
S.FONT_DISPLAY = 21                                   -- above this a size is left alone

-- The snap table: S.SNAP[size] for every half size from 0.5 up to S.FONT_DISPLAY.
S.SNAP = {}
do
    local steps = S.FONT_STEPS
    for h = 1, S.FONT_DISPLAY * 2 do
        local size = h / 2
        local best, bestD
        for i = 1, #steps do
            local d = abs(steps[i] - size)
            if not bestD or d < bestD - 1e-9 then best, bestD = steps[i], d end   -- (only a closer step wins: ties keep the smaller)
        end
        S.SNAP[size] = best
    end
end

-- The scale step for a size (a number, or a S.FONT / S.STYLE name).
function S:Size(size)
    if type(size) == "string" then
        local st = self.STYLE[size]
        return self.FONT[size] or (st and st.size) or self.FONT.body
    end
    size = tonumber(size)
    if not size then return self.FONT.body end
    if size > self.FONT_DISPLAY then return size end
    return self.SNAP[floor(size * 2 + 0.5) / 2] or self.FONT_STEPS[1]
end

-- Fonts: a style without a font uses the client's text font (taken from GameFontHighlight, so other locales keep their
-- glyphs); FONT_NUM = the narrow digits of the count badges, meters and tables.
S.FONT_NUM = "Fonts\\ARIALN.TTF"

-- Named text styles (UI:Text / UI:SetTextStyle): size, font (nil = the text font), color (a token name), caps (UI:Text
-- upper-cases the text it is given), spacing (line spacing), flags (font flags, "" by default).
S.STYLE = {
    hero  = { size = S.FONT.hero,  color = "TEXT" },
    page  = { size = S.FONT.page,  color = "GOLD" },
    title = { size = S.FONT.title, color = "GOLD" },
    emph  = { size = S.FONT.emph,  color = "TEXT" },
    body  = { size = S.FONT.body,  color = "TEXT" },
    sub   = { size = S.FONT.body,  color = "SUB" },
    small = { size = S.FONT.small, color = "SUB" },
    caps  = { size = S.FONT.caps,  color = "SUB", caps = true },
    num   = { size = S.FONT.body,  color = "TEXT", font = S.FONT_NUM },
    link  = { size = S.FONT.body,  color = "YOU" },
}

---------------------------------------------------------------------------
-- Spacing and sizes
---------------------------------------------------------------------------

S.PAD, S.GAP, S.IN = 10, 8, 8                        -- page padding, gap between blocks, a card's inner padding
S.ROW = { compact = 22, list = 26, rich = 38, art = 50 }
S.BANNER = { hero = 128, tool = 84, strip = 46 }
S.BTN_H = 24                                         -- the one height of a page's main action
S.PAGE_W, S.PAGE_H = 790, 548                        -- the main window's page area (UI/MainFrame.lua)
S.INNER_W = S.PAGE_W - 2 * S.PAD                     -- 770: a page's content width inside its padding
