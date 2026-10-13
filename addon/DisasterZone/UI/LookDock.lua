if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LookDock.lua", ...) then return end -- DisasterZone UI/LookDock.lua
-- The Dock (Settings > UI > Action bars > Dock): every bar at the bottom of the screen laid out from one grid, in the
-- part's look. Mockup dev/art/casc/actionbar_mockup (claude.ai/artifact/NpR2NQjpYrNjP71SCfZR8t, user: "build it").
-- Four numbers per look (at a 36 px button; all of them scale with the button size): S the button, G the gap
-- between buttons, P the plate's padding, R the space between clusters. Five rules:
--   1  the bottom bars are one block: action bar 1 at the bottom, 2 over it, 3 over that (the ones the game shows:
--      Options > Action Bars), 12 columns, S wide, G apart
--   2  the wings fill the block's height: the bags on the left, the game menu (and a DisasterZone tile) on the
--      right, S tiles in as many rows as the block has
--   3  the crown lines up: the stance bar (0.75 S) one R over the block from its left edge, the pet bar ending at its
--      right edge
--   4  the experience bar is the block's width, one G under action bar 1 (reputation under it)
--   5  one plate behind it all with a seam in the middle of each R (Halo: no plate, a soft shadow under the rings)
-- Action bars 4 and 5 stand as a rail at the right edge: 2 columns, the same S and G.
-- How: the buttons stay the game's (secure, on their own bars: paging, visibility, key binds, all unchanged). The
-- game puts each action button in a container frame and lays the containers out; the Dock scales those containers
-- and anchors them to its own frame instead (plain frames, no Edit Mode code runs: nothing is tainted), the bags and
-- menu buttons the same, and does it again after every layout of the game's (hooks) - only out of combat: in
-- combat it waits for the fight to end. Turning the Dock off hands the bars back after a reload.
local addonName, ns = ...

local Dock = ns:NewModule("LookDock")
local UI = ns.UI

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local pairs, ipairs = pairs, ipairs

local function Look() return ns.Look end
local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end

-- the looks' numbers at S = 36 (the mockup's)
Dock.TOKENS = {
    flat = { G = 2, P = 5, R = 12, xp = 5 },
    halo = { G = 10, P = 10, R = 18, xp = 5 },       -- (G holds the key binds under the rings)
    sigil = { G = 3, P = 6, R = 14, xp = 6 },
    slate = { G = 2, P = 3, R = 14, xp = 3 },
    gilded = { G = 4, P = 9, R = 16, xp = 7 },
}
Dock.SIZES = { 30, 33, 36, 39, 42 }
Dock.DEFAULT_SIZE = 36

-- the block's rows from the top (shown bars only), the crown's, the rail's
local ROWS = { { "MultiBarBottomRight", "MultiBarBottomRightButton" }, { "MultiBarBottomLeft", "MultiBarBottomLeftButton" },
               { "MainActionBar", "ActionButton" } }
local RAIL = { { "MultiBarRight", "MultiBarRightButton" }, { "MultiBarLeft", "MultiBarLeftButton" } }
local BAGS = { "MainMenuBarBackpackButton", "CharacterBag0Slot", "CharacterBag1Slot", "CharacterBag2Slot",
               "CharacterBag3Slot", "KeyRingButton" }
local MENU = { "CharacterMicroButton", "SpellbookMicroButton", "PlayerSpellsMicroButton", "TalentMicroButton",
               "QuestLogMicroButton", "SocialsMicroButton", "GuildMicroButton", "WorldMapMicroButton", "LFGMicroButton",
               "LFDMicroButton", "PVPMicroButton", "MainMenuMicroButton", "HelpMicroButton" }
-- the Edit layout items the Dock stands in for while it is on
local BLIZZ = { "MainActionBar", "MultiBarBottomLeft", "MultiBarBottomRight", "StanceBar", "PetActionBar",
                "MicroMenuContainer", "BagsBar" }
local BLIZZ_RAIL = { "MultiBarRight", "MultiBarLeft" }

Dock.placed = {}          -- frame -> true (the frames the Dock has moved: told apart from the game's own)

---------------------------------------------------------------------------
-- On / off, the numbers
---------------------------------------------------------------------------

-- The Dock is on: the part has a look and the option is on. (Off after it was on: the game's places after a reload.)
function Dock:Wanted()
    local L = Look()
    return L and L:IsOn("bars") and L:Opt("bars", "dock", true) and true or false
end

function Dock:Size()
    local s = tonumber(Look():Opt("bars", "size", Dock.DEFAULT_SIZE)) or Dock.DEFAULT_SIZE
    return max(24, min(48, floor(s + 0.5)))
end

-- The numbers for a look and size: S, G, P, R, s (the crown's buttons), xp (the bar's height).
function Dock.Tokens(key, S)
    local t = Dock.TOKENS[key] or Dock.TOKENS.flat
    local k = S / 36
    return { S = S, G = floor(t.G * k + 0.5), P = floor(t.P * k + 0.5), R = floor(t.R * k + 0.5),
             s = floor(S * 0.75 + 0.5), xp = max(2, floor(t.xp * k + 0.5)) }
end

---------------------------------------------------------------------------
-- The grid: pure maths (tests and the Settings preview use it too)
---------------------------------------------------------------------------

-- Where everything goes, from the top-left of the dock (y down). n = { rows (1-3), bags, menu, stance, pet (counts),
-- rep (a reputation bar under the experience bar), pager (action bar 1's page switcher) }. Returns { w, h, block,
-- bags = { {x, y} }, menu, stance, pet, rows = { y of each row from the top }, seams = { x }, xp = { x, y, w, h },
-- rep, pager = { x, y, w, h }, plateTop }.
-- The page switcher is a strip half a button wide, G left of the block and its full height: up at its top, the page
-- in the middle, down at its foot.
function Dock.Grid(T, n)
    local S, G, P, R, s = T.S, T.G, T.P, T.R, T.s
    local rows = max(1, min(3, n.rows or 1))
    local g = { rows = {}, bags = {}, menu = {}, stance = {}, pet = {} }
    local bw, bh = 12 * S + 11 * G, rows * S + (rows - 1) * G
    local bagCols = n.bags > 0 and ceil(n.bags / rows) or 0
    local menuCols = n.menu > 0 and ceil(n.menu / rows) or 0
    local bagW = bagCols > 0 and (bagCols * S + (bagCols - 1) * G) or 0
    local menuW = menuCols > 0 and (menuCols * S + (menuCols - 1) * G) or 0
    local crown = (n.stance > 0 or n.pet > 0) and (s + R) or 0
    local top = P + crown
    local bagX = P
    local pw0 = n.pager and floor(S * 0.5 + 0.5) or 0
    local pagerX = bagX + (bagW > 0 and bagW + R or 0)
    local blockX = pagerX + (pw0 > 0 and pw0 + max(G, 2) or 0)
    local menuX = blockX + bw + R
    g.w = (menuW > 0) and (menuX + menuW + P) or (blockX + bw + P)
    g.block = { x = blockX, y = top, w = bw, h = bh }
    if pw0 > 0 then g.pager = { x = pagerX, y = top, w = pw0, h = bh } end
    g.plateTop = top - P
    for i = 1, rows do g.rows[i] = top + (i - 1) * (S + G) end
    -- the wings: column-major from the bottom left (the backpack by the block); the menu row by row from the top
    for i = 1, n.bags do
        local c, r = floor((i - 1) / rows), (i - 1) % rows
        g.bags[i] = { bagX + c * (S + G), top + bh - S - r * (S + G) }
    end
    for i = 1, n.menu do
        local r, c = floor((i - 1) / menuCols), (i - 1) % menuCols
        g.menu[i] = { menuX + c * (S + G), top + r * (S + G) }
    end
    for i = 1, n.stance do g.stance[i] = { blockX + (i - 1) * (s + G), P } end
    local pw = n.pet * s + max(0, n.pet - 1) * G
    for i = 1, n.pet do g.pet[i] = { blockX + bw - pw + (i - 1) * (s + G), P } end
    if bagW > 0 then g.seams = { bagX + bagW + R / 2 } else g.seams = {} end
    if menuW > 0 then g.seams[#g.seams + 1] = blockX + bw + R / 2 end
    g.xp = { x = blockX, y = top + bh + G, w = bw, h = T.xp }
    local bottom = g.xp.y + T.xp
    if n.rep then
        g.rep = { x = blockX, y = bottom + 2, w = bw, h = max(2, T.xp - 2) }
        bottom = g.rep.y + g.rep.h
    end
    g.h = bottom + max(P, 2)
    g.menuX, g.menuW, g.bagW = menuX, menuW, bagW
    return g
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

local function Tex(parent, layer, sub, path)
    return Look().Tex(parent, layer, sub, path)
end

-- The dock's own frame: the plate, the seams, Halo's floor (under the game's bars: a lower strata).
local function Shell(name)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetFrameStrata("BACKGROUND")
    f:SetFrameLevel(2)
    f:SetSize(100, 40)
    f.plate = CreateFrame("Frame", nil, f)
    f.panel = Look():Panel(f.plate)
    f.floor = Tex(f, "BACKGROUND", -8, "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow")
    f.floor:SetPoint("CENTER")
    f.seams = {}
    return f
end

function Dock:Frames()
    if self.f then return self.f, self.rail end
    self.f = Shell("DisasterZoneDock")
    self.rail = Shell("DisasterZoneDockRail")
    -- the DisasterZone tile on the menu (opens the addon), drawn like the game's menu tiles
    local b = CreateFrame("Button", "DisasterZoneDockMenuButton", self.f)
    b:SetSize(32, 32)
    b:RegisterForClicks("AnyUp")
    b:SetScript("OnClick", function() if ns.MainFrame and ns.MainFrame.Toggle then ns.MainFrame:Toggle() end end)
    b:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_TOP")
        GameTooltip:AddLine("DisasterZone")
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.dzGlyph = "dz"
    self.dzButton = b
    return self.f, self.rail
end

---------------------------------------------------------------------------
-- Putting the game's frames on the grid
---------------------------------------------------------------------------

-- f's natural size (before our scale): a container is the button's size; a menu button is made square first.
local function Base(f)
    local h = f:GetHeight() or 0
    if h <= 0 then h = 36 end
    return h
end

-- Puts f with its top-left at (x, y) of `to` (dock units, y down), S units square.
local function Place(f, to, x, y, S)
    if not f then return end
    local base = f.dzBase or Base(f)
    f.dzBase = base
    local pes = (f:GetParent() and f:GetParent():GetEffectiveScale()) or 1
    local tes = to:GetEffectiveScale() or 1
    local k = (S * tes) / (base * pes)
    if k <= 0 then return end
    f:SetScale(k)
    local es = f:GetEffectiveScale() or (pes * k)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", to, "TOPLEFT", x * tes / es, -y * tes / es)
    Dock.placed[f] = true
end
Dock.Place = Place

local function Shown(f) return f and f:IsShown() and true or false end

-- The containers of a bar's buttons that the game shows (its own count: Edit Mode's "# of icons", stances, pets).
local function Containers(prefix, n)
    local out = {}
    for i = 1, n or 12 do
        local b = _G[prefix .. i]
        local c = b and (b.container or b:GetParent())
        if c and Shown(c) then out[#out + 1] = c end
    end
    return out
end

local function MenuButtons()
    local out = {}
    for _, name in ipairs(MENU) do
        local b = _G[name]
        if b and Shown(b) then
            if not b.dzSquare then b.dzSquare = true; b:SetWidth(b:GetHeight() or 32) end
            out[#out + 1] = b
        end
    end
    if Dock.dzButton then out[#out + 1] = Dock.dzButton end
    return out
end

local function BagButtons()
    local out = {}
    for _, name in ipairs(BAGS) do
        local b = _G[name]
        if b and Shown(b) then
            -- (the key ring is tall and thin in the game's bag bar, and the bar sizes it again on every layout of its
            -- own: square it each time, it fills its cell like a bag)
            local bw, bh = b:GetWidth() or 0, b:GetHeight() or 0
            if bw ~= bh and bh > 0 then b:SetWidth(bh) end
            out[#out + 1] = b
        end
    end
    return out
end

-- What the dock holds now: the shown rows (top first), the wings' and the crown's buttons.
function Dock:Contents()
    local c = { rows = {}, bags = BagButtons(), menu = MenuButtons(), stance = {}, pet = {}, rail = {} }
    for _, r in ipairs(ROWS) do
        local bar = _G[r[1]]
        if bar and (Shown(bar) or r[1] == "MainActionBar") then c.rows[#c.rows + 1] = { bar = bar, prefix = r[2] } end
    end
    if Shown(_G.StanceBar) then c.stance = Containers("StanceButton", 10) end
    if Shown(_G.PetActionBar) then c.pet = Containers("PetActionButton", 10) end
    for _, r in ipairs(RAIL) do
        local bar = _G[r[1]]
        if bar and Shown(bar) then c.rail[#c.rail + 1] = { bar = bar, prefix = r[2] } end
    end
    return c
end

---------------------------------------------------------------------------
-- Action bar 1's page switcher: the game's own (its arrows page the bar, its key binds stay), moved into its strip
---------------------------------------------------------------------------

function Dock:PageFrame()
    local bar = _G.MainActionBar
    return bar and bar.ActionBarPageNumber or nil
end

-- the page number's colour per look (the looks' name colour)
local PAGE_C = { flat = { 0.86, 0.84, 0.78 }, halo = { 0.96, 0.9, 0.72 }, sigil = { 1, 0.82, 0 },
                 slate = { 0.74, 0.72, 0.65 }, gilded = { 1, 0.84, 0.42 } }

function Dock:Pager(f, box, look)
    local pn = self:PageFrame()
    if not pn or not box then return end
    local L = Look()
    -- (in dock units: its scale undoes its parent's, so a dock pixel is its pixel)
    local pes = (pn:GetParent() and pn:GetParent():GetEffectiveScale()) or 1
    local k = (f:GetEffectiveScale() or 1) / pes
    pn:SetScale(k)
    pn:ClearAllPoints()
    pn:SetPoint("TOPLEFT", f, "TOPLEFT", box.x, -box.y)
    pn:SetSize(box.w, box.h)
    self.placed[pn] = true
    local aw = box.w
    local ah = max(10, floor(min(box.h / 3, aw * 0.8) + 0.5))
    for i, b in ipairs({ pn.UpButton, pn.DownButton }) do
        if b then
            -- (the game's sleek arrows, not the stone bar's)
            if b.SwapToAlternateAtlas then pcall(b.SwapToAlternateAtlas, b) end
            b:ClearAllPoints()
            b:SetSize(aw, ah)
            b:SetPoint(i == 1 and "TOP" or "BOTTOM", pn, i == 1 and "TOP" or "BOTTOM", 0, 0)
            for _, t in ipairs({ b:GetNormalTexture(), b:GetPushedTexture(), b:GetHighlightTexture(),
                                 b.GetDisabledTexture and b:GetDisabledTexture() or nil }) do
                if t then t:ClearAllPoints(); t:SetAllPoints(b) end
            end
            Dock.placed[b] = true
        end
    end
    if pn.Text then
        pn.Text:ClearAllPoints()
        pn.Text:SetPoint("CENTER", pn, "CENTER", 0, 0)
        pn.Text:SetSize(aw + 6, 12)
        local c = PAGE_C[look.key] or PAGE_C.flat
        pn.Text:SetTextColor(c[1], c[2], c[3])
    end
    -- its strip on the plate: a faint track the arrows sit on (Halo: a thin line)
    f.pagerTrack = f.pagerTrack or Tex(f, "BORDER", 2)
    local t = f.pagerTrack
    t:SetTexture(L.WHITE)
    t:ClearAllPoints()
    if look.key == "halo" then
        t:SetSize(1, max(1, box.h - 2 * ah - 8))
        t:SetPoint("CENTER", f, "TOPLEFT", box.x + box.w / 2, -(box.y + box.h / 2))
        L.Color(t, { 0.96, 0.9, 0.72, 0.18 })
    else
        t:SetPoint("TOPLEFT", f, "TOPLEFT", box.x, -box.y)
        t:SetSize(box.w, box.h)
        L.Color(t, look.key == "gilded" and { 0, 0, 0, 0.35 } or { 1, 1, 1, 0.04 })
    end
end

---------------------------------------------------------------------------
-- The ground: plate, seams, floor
---------------------------------------------------------------------------

local SEAM = { flat = { 0, 0, 0, 0.9 }, sigil = { 1, 0.82, 0, 0.35 }, slate = { 1, 1, 1, 0.1 }, halo = { 0.96, 0.9, 0.72, 0.35 } }

local function Ground(f, look, x, y, w, h, seams, seamTop, seamH)
    local L = Look()
    local k = look.key
    f.plate:ClearAllPoints()
    f.plate:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
    f.plate:SetSize(max(1, w), max(1, h))
    if k == "halo" then
        f.panel:Apply(nil)
        f.floor:ClearAllPoints()
        f.floor:SetPoint("CENTER", f.plate, "CENTER", 0, -4)
        f.floor:SetSize(w + 120, h + 90)
        f.floor:SetVertexColor(0, 0, 0, 0.75)
        f.floor:Show()
    else
        f.floor:Hide()
        f.panel:Apply(look)
    end
    for i = 1, max(#f.seams, #(seams or {})) do
        local t = f.seams[i]
        local sx = seams and seams[i]
        if sx then
            if not t then t = Tex(f, "BORDER", 3); f.seams[i] = t end
            t:ClearAllPoints()
            if k == "halo" then
                t:SetTexture(L.DISC)
                t:SetSize(4, 4)
                t:SetPoint("CENTER", f, "TOPLEFT", sx, -(seamTop + seamH / 2))
                L.Color(t, SEAM.halo)
            elseif k == "gilded" then
                t:SetTexture(L.GILT .. "trim_v")
                t:SetVertexColor(1, 1, 1, 0.85)
                t:SetSize(5, seamH)
                t:SetTexCoord(0, 1, 0, seamH / 20)
                t:SetPoint("TOP", f, "TOPLEFT", sx, -seamTop)
                t:Show()
            else
                t:SetTexture(L.WHITE)
                t:SetTexCoord(0, 1, 0, 1)
                t:SetSize(1, max(1, seamH - 4))
                t:SetPoint("TOP", f, "TOPLEFT", sx, -(seamTop + 2))
                L.Color(t, SEAM[k] or SEAM.flat)
            end
        elseif t then
            t:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Laying it out
---------------------------------------------------------------------------

function Dock:Layout()
    if not self:Wanted() then return false end
    if InCombat() then self.pending = true return false end
    self.pending = false
    local f, rail = self:Frames()
    local L = Look()
    local look = L:For("bars")
    local S = self:Size()
    local T = Dock.Tokens(look.key, S)
    local c = self:Contents()
    local repOn = ns.LookBars and ns.LookBars.WatchingRep and ns.LookBars:WatchingRep() or false
    local g = Dock.Grid(T, { rows = #c.rows, bags = #c.bags, menu = #c.menu, stance = #c.stance, pet = #c.pet,
                             rep = repOn and L:Opt("bars", "xp", true), pager = Dock:PageFrame() ~= nil })
    self.grid, self.T = g, T
    f:SetSize(g.w, g.h)
    f:Show()
    -- the plate from P over the block to the bottom, the whole width (the crown floats over it)
    Ground(f, look, 0, g.plateTop, g.w, g.h - g.plateTop, g.seams, g.block.y, g.block.h)
    for i, r in ipairs(c.rows) do
        -- (a bar showing fewer icons keeps its columns: icon j stays in column j)
        for j = 1, 12 do
            local b = _G[r.prefix .. j]
            local cont = b and (b.container or b:GetParent())
            if cont and Shown(cont) then Place(cont, f, g.block.x + (j - 1) * (S + T.G), g.rows[i], S) end
        end
    end
    for i, b in ipairs(c.bags) do Place(b, f, g.bags[i][1], g.bags[i][2], S) end
    self:Pager(f, g.pager, look)
    for i, b in ipairs(c.menu) do Place(b, f, g.menu[i][1], g.menu[i][2], S) end
    for i, cont in ipairs(c.stance) do Place(cont, f, g.stance[i][1], g.stance[i][2], T.s) end
    for i, cont in ipairs(c.pet) do Place(cont, f, g.pet[i][1], g.pet[i][2], T.s) end
    -- the rail: one column per shown bar (4 then 5), 12 rows
    if L:Opt("bars", "rail", true) and #c.rail > 0 then
        local rw = #c.rail * S + (#c.rail - 1) * T.G
        local rh = 12 * S + 11 * T.G
        rail:SetSize(rw + 2 * T.P, rh + 2 * T.P)
        rail:Show()
        Ground(rail, look, 0, 0, rw + 2 * T.P, rh + 2 * T.P, nil, 0, 0)
        for ci, r in ipairs(c.rail) do
            for j = 1, 12 do
                local b = _G[r.prefix .. j]
                local cont = b and (b.container or b:GetParent())
                if cont and Shown(cont) then Place(cont, rail, T.P + (ci - 1) * (S + T.G), T.P + (j - 1) * (S + T.G), S) end
            end
        end
        self.railOn = true
    else
        rail:Hide()
        self.railOn = false
    end
    -- the DisasterZone tile and the bags / menu tiles in the look (sized by their buttons)
    if ns.LookBars and ns.LookBars.Tile then
        for _, b in ipairs(c.menu) do ns.LookBars:Tile(b, look) end
        for _, b in ipairs(c.bags) do ns.LookBars:Tile(b, look) end
    end
    if ns.LookBars and ns.LookBars.XP then ns.LookBars:XP() end
    self:Claim(true)
    ns:Fire("DOCK_LAID_OUT")
    return true
end

-- The experience bar's box while the Dock is on (LookBars:XP reads it): frame, x, y, w, h, repH.
function Dock:XPBox()
    if not self.active or not self.grid or not self.f then return nil end
    local g = self.grid
    return self.f, g.xp.x, g.xp.y, g.xp.w, g.xp.h, g.rep and g.rep.h or nil
end

-- Edit layout: the dock and the rail are items; the game's bars they hold are not (their Edit Mode boxes would be
-- empty). Turning the Dock off brings those back (after the reload that hands the bars back).
function Dock:Claim(on)
    local Lay = ns.Layout
    if not Lay then return end
    if on == self.claimed then return end
    self.claimed = on
    Lay.held = Lay.held or {}
    for _, name in ipairs(BLIZZ) do Lay.held[name] = on or nil end
    for _, name in ipairs(BLIZZ_RAIL) do Lay.held[name] = on or nil end
    if on then
        for _, name in ipairs(BLIZZ) do Lay:Unregister("blizz:" .. name) end
        for _, name in ipairs(BLIZZ_RAIL) do Lay:Unregister("blizz:" .. name) end
        Lay:Unregister("bars.xp")
        Lay:Register("bars.dock", { name = "Action bars", group = "Game frames", order = 6, noHide = true,
            protected = true, default = { "BOTTOM", 0, 8 }, frame = function() return Dock.f end,
            scale = { get = function() return Dock:Size() / 36 end,
                      set = function(s) ns.DB:SetSetting("ui.bars.size", max(24, min(48, floor(36 * s + 0.5)))) end } })
        Lay:Register("bars.rail", { name = "Action bars 4 and 5", group = "Game frames", order = 7, noHide = true,
            protected = true, default = { "RIGHT", -8, 40 }, frame = function() return Dock.rail end,
            mine = function() return Dock.railOn and true or false end })
    else
        Lay:Unregister("bars.dock")
        Lay:Unregister("bars.rail")
        if Lay.RegisterBlizzard then Lay:RegisterBlizzard() end
    end
end

-- Lays out again soon (once per frame at most; after the game's own layout ran).
function Dock:Queue()
    if not self.active then return end
    if InCombat() then self.pending = true return end
    if self.queued then return end
    self.queued = true
    local run = function() Dock.queued = false; Dock:Layout() end
    if C_Timer and C_Timer.After then C_Timer.After(0, run) else run() end
end

-- After the game lays its bars out (or changes their icon size, or the menu / bags), ours again.
local function HookAll()
    local function H(obj, fn)
        if obj and type(obj[fn]) == "function" then pcall(hooksecurefunc, obj, fn, function() Dock:Queue() end) end
    end
    H(_G.MainActionBar, "EditModeSetScale"); H(_G.MainActionBar, "UpdateEndCaps")
    for _, r in ipairs(ROWS) do H(_G[r[1]], "UpdateGridLayout"); H(_G[r[1]], "UpdateSystemSettingIconSize"); H(_G[r[1]], "UpdateShownButtons") end
    for _, r in ipairs(RAIL) do H(_G[r[1]], "UpdateGridLayout"); H(_G[r[1]], "UpdateSystemSettingIconSize"); H(_G[r[1]], "UpdateShownButtons") end
    for _, n in ipairs({ "StanceBar", "PetActionBar" }) do
        H(_G[n], "UpdateGridLayout"); H(_G[n], "UpdateSystemSettingIconSize"); H(_G[n], "UpdateShownButtons")
    end
    H(_G.MicroMenuContainer, "Layout"); H(_G.MicroMenu, "Layout"); H(_G.BagsBar, "Layout")
    H(_G.KeyRingButton, "UpdateOrientation")
    -- (picking an item up expands the game's bag bar: its layout runs from a callback it took at load time, not
    -- through the method hooked above)
    if EventRegistry and EventRegistry.RegisterCallback then
        pcall(EventRegistry.RegisterCallback, EventRegistry, "MainMenuBarManager.OnExpandChanged",
            function() Dock:Queue() end, Dock)
    end
    for _, fn in ipairs({ "UpdateMicroButtonsParent", "MoveMicroButtons", "MultiActionBar_Update" }) do
        if type(_G[fn]) == "function" then pcall(hooksecurefunc, fn, function() Dock:Queue() end) end
    end
    local ev = CreateFrame("Frame")
    for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "CURSOR_CHANGED", "UPDATE_SHAPESHIFT_FORMS", "PET_BAR_UPDATE",
                         "UNIT_PET", "BAG_UPDATE_DELAYED", "UPDATE_FACTION", "DISPLAY_SIZE_CHANGED", "UI_SCALE_CHANGED" }) do
        pcall(ev.RegisterEvent, ev, e)
    end
    ev:SetScript("OnEvent", function(_, e)
        if e == "PLAYER_REGEN_ENABLED" then
            if Dock.pending then Dock:Layout() end
            return
        end
        Dock:Queue()
    end)
end

function Dock:Start()
    if self.active or not self:Wanted() then return end
    self.active = true
    self:Frames()
    if not self.hooked then self.hooked = true; HookAll() end
    if ns.Layout then
        -- (the dock and the rail are placed by the layout like every frame of ours)
        self:Claim(true)
        ns.Layout:Place("bars.dock")
        ns.Layout:Place("bars.rail")
    end
    self:Layout()
end

function Dock:OnLogin()
    if self:Wanted() then self:Start() end
    ns:On("UI_LOOK_CHANGED", function(part, path)
        if part ~= "bars" then return end
        if Dock:Wanted() then
            if Dock.active then Dock:Queue() else Dock:Start() end
        elseif Dock.active then
            -- (handing the bars back to the game's layout takes a reload: its Edit Mode code isn't ours to run)
            Dock:Stop()
        end
    end)
end

-- Off: our frames hidden; the game's bars go back to their places after a reload (asked once).
function Dock:Stop()
    self.active = false
    if self.f then self.f:Hide() end
    if self.rail then self.rail:Hide() end
    self:Claim(false)
    if ns.LookBars and ns.LookBars.XP then ns.LookBars:XP() end
    if next(self.placed) and ns.Popup and ns.Popup.Confirm then
        ns.Popup:Confirm({ key = "dockreload", title = "Reload to hand the bars back",
            text = "The action bars go back to the game's places after a reload.", ok = "Reload now", cancel = "Later",
            onAccept = function() if ReloadUI then ReloadUI() end end })
    end
end
