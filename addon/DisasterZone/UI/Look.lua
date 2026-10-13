if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Look.lua", ...) then return end -- DisasterZone UI/Look.lua
-- The game's UI in the addon's looks (Settings > UI): the mockup of 2026-10-13, the user's picks the same day: all five
-- custom looks for every part, party and raid frames in the same set, reskin where the look can be reached and replace
-- (and work every time) where it can't, and no working with other UI addons.
-- Parts and how each gets its look:
--   units    player, target, target of target, focus, pet       replaced (UI/LookUnits.lua: secure unit buttons)
--   group    party and raid frames                                replaced (UI/LookUnits.lua: secure group headers)
--   cast     player, target and focus cast bars                   replaced (UI/LookCast.lua)
--   bags     the bag windows, key ring and bank                    replaced (UI/LookBags.lua: the game's item buttons
--            in our windows)
--   bars     action bars 1 - 5, stance and pet bars, bags, menu   reskinned (UI/LookBars.lua: Blizzard's own buttons);
--            and the experience / reputation bar                  replaced (the game's status bars retired)
--   minimap  the minimap, zone, clock and its buttons             reskinned (UI/LookMinimap.lua)
-- Looks: blizzard (the default: the game's frames, untouched), flat, halo, sigil, slate, gilded (the names of the
-- meter and class bar themes), classic (our frames in the game's own art, Look.GAME). Settings: ui.look (everything), ui.<part>.look ("inherit" = ui.look, or a look of its
-- own), ui.<part>.<option> (each part's overrides). A part that was replaced keeps its own frames until a reload: the
-- game doesn't let an addon hand its frames back (Look:NeedsReload).
--
-- This file: the looks' face data and the parts every face is drawn with, so every part draws them the same way:
--   Look:Panel(f)  a frame's ground: fill, edges, inner line, gilded corners      panel:Apply(look)
--   Look:Bar(parent)  a bar: flat | pill | lit | hair | gilt                      bar:Apply(look, kind), :SetValue
--   Look:Gilt(f, opts)  Gilded's worked gold round a frame: moulding, corners, grain  gilt:Show(on, opts)
--   Look:Icon(parent)  an icon or portrait: square | round | framed | gilt | small icon:Apply(look), :SetTexture ...
-- The round parts are the game's portrait disc (masks stripe on this client), the gilded bars its status bar
-- texture; Gilded's trim, corners, bezel and grain are art of our own (Media/Gilt).
local addonName, ns = ...

local Look = ns:NewModule("Look")
local UI, S = ns.UI, ns.Style

local floor, max, min = math.floor, math.max, math.min
local pairs, ipairs, type, tonumber, tostring = pairs, ipairs, type, tonumber, tostring

local WHITE = "Interface\\Buttons\\WHITE8X8"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SBAR = "Interface\\TargetingFrame\\UI-StatusBar"
Look.WHITE, Look.DISC, Look.SBAR = WHITE, DISC, SBAR
-- Gilded's worked gold (dev/generators/gen_gilt_media.py): moulding, filigree corners, a square bezel, damask grain
local GILT = "Interface\\AddOns\\" .. addonName .. "\\Media\\Gilt\\"
Look.GILT = GILT

-- Classic's art: the game's own textures, with the cuts the mockup measured (dev/art/casc/classic_mockup). A piece is
-- { file, texture w, texture h, x0, y0, x1, y1 } in the file's pixels; Look:GameTex(t, key) puts one on a texture.
-- Nothing here ships with the addon: every file is the client's.
local B, MB, TF, CB = "Interface\\Buttons\\", "Interface\\MainMenuBar\\", "Interface\\TargetingFrame\\", "Interface\\CastingBar\\"
local BP, BANK = "Interface\\ContainerFrame\\UI-BackpackBackground", "Interface\\ContainerFrame\\UI-Bag-Components-Bank"
Look.GAME = {
    -- action buttons: the frame is 66/36 of the button (Look.QuickFrame), the states the game's own
    quick = { B .. "UI-Quickslot2", 64, 64, 0, 0, 64, 64 },
    slot = { B .. "UI-Quickslot", 64, 64, 0, 0, 64, 64 },
    pushed = { B .. "UI-Quickslot-Depress", 64, 64, 0, 0, 64, 64 },
    hover = { B .. "ButtonHilight-Square", 64, 64, 0, 0, 64, 64 },          -- (ADD)
    checked = { B .. "CheckButtonHilight", 64, 64, 0, 0, 64, 64 },          -- (ADD)
    flash = { B .. "UI-QuickslotRed", 64, 64, 0, 0, 64, 64 },
    autocast = { B .. "UI-AutoCastableOverlay", 64, 64, 0, 0, 64, 64 },
    alert = { "Interface\\SpellActivationOverlay\\IconAlert", 128, 256, 3, 71, 67, 135 },   -- (ADD; 64 px at 36)
    -- the main bar: a stone well per button (pillar to pillar: 42 px, the game's stride at 36), the rail (its joints
    -- every 51 px are the experience bar's segments), the dark stone, the end caps (128, facing right)
    well = { MB .. "UI-MainMenuBar-Dwarf", 256, 256, 42, 148, 84, 190 },
    rail = { MB .. "UI-MainMenuBar-Dwarf", 256, 256, 2, 137, 53, 148 },
    stone = { "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", 64, 64, 0, 0, 64, 64 },
    gryphon = { MB .. "UI-MainMenuBar-EndCap-Dwarf", 128, 128, 0, 0, 128, 128 },
    lion = { MB .. "UI-MainMenuBar-EndCap-Human", 128, 128, 0, 0, 128, 128 },
    tick = { MB .. "UI-ExhaustionTickNormal", 32, 32, 0, 0, 32, 32 },
    keyring = { B .. "UI-Button-KeyRing", 32, 64, 0, 0, 18, 39 },
    backpack = { B .. "Button-Backpack-Up", 64, 64, 0, 0, 64, 64 },
    -- bags: the backpack's frame cut to grow (its header has the game's own backpack portrait in the ring; the bank's
    -- ring is open, the banker under it at 22.5, 25). A cell is the grid's period, 42 x 41: the carved recess
    -- (124..159 x 92..124 in the file) between half a pillar and half a rail on each side, the item 37 px at 2, 3
    -- covering the recess and 2 px of the rails round it, as the game's own; the money box's inside is x 17 .. w-10,
    -- 8 .. 22 down the footer.
    -- (the middle in two rows: the title bar cut short of the notch in its top line at 184, so the notch doesn't
    -- repeat; the stone row under it, bag_hs / bank_hs, in its own wider pieces)
    bag_hl = { BP, 256, 256, 66, 0, 128, 46 }, bag_hm = { BP, 256, 256, 128, 0, 182, 28 }, bag_hr = { BP, 256, 256, 212, 0, 253, 46 },
    bag_hs = { BP, 256, 256, 128, 28, 212, 46 },
    bag_cell = { BP, 256, 256, 121, 87, 163, 128 },
    bag_l = { BP, 256, 256, 66, 90, 77, 120 }, bag_r = { BP, 256, 256, 243, 90, 253, 120 },
    -- (the stone round the grid: the game's seamless rock, wrapped, tinted to the backpack's brown (1, .92, .74); the
    -- backpack's own stone strip has ends that don't meet, a seam at every piece)
    rock = { "Interface\\FrameGeneral\\UI-Background-Rock", 256, 256, 0, 0, 256, 256 },
    -- (the footer's middle two grid periods wide: the studs on its rail stay under the pillars)
    bag_fl = { BP, 256, 256, 66, 207, 112, 244 }, bag_fm = { BP, 256, 256, 112, 207, 196, 244 }, bag_fr = { BP, 256, 256, 200, 207, 253, 244 },
    bank_hl = { BANK, 256, 512, 66, 0, 128, 46 }, bank_hm = { BANK, 256, 512, 128, 0, 182, 28 }, bank_hr = { BANK, 256, 512, 212, 0, 253, 46 },
    bank_hs = { BANK, 256, 512, 128, 28, 212, 46 },
    input = { "Interface\\Common\\Common-Input-Border", 128, 32, 0, 0, 128, 20 },
    button = { B .. "UI-Panel-Button-Up", 128, 32, 2, 0, 78, 22 },
    buttonDown = { B .. "UI-Panel-Button-Down", 128, 32, 2, 0, 78, 22 },
    buttonHi = { B .. "UI-Panel-Button-Highlight", 128, 32, 2, 0, 78, 22 },
    close = { B .. "UI-Panel-MinimizeButton-Up", 32, 32, 0, 0, 32, 32 },
    closeDown = { B .. "UI-Panel-MinimizeButton-Down", 32, 32, 0, 0, 32, 32 },
    closeHi = { B .. "UI-Panel-MinimizeButton-Highlight", 32, 32, 0, 0, 32, 32 },
    iconFrame = { "Interface\\Common\\WhiteIconFrame", 64, 64, 0, 0, 64, 64 },
    gold = { "Interface\\MoneyFrame\\UI-GoldIcon", 16, 16, 0, 0, 16, 16 },
    silver = { "Interface\\MoneyFrame\\UI-SilverIcon", 16, 16, 0, 0, 16, 16 },
    copper = { "Interface\\MoneyFrame\\UI-CopperIcon", 16, 16, 0, 0, 16, 16 },
    -- unit frames: the target frame's rails stretch between their ends (left 5, right 8 px; inside: the name band
    -- 6 .. 22 from the top, health 23 .. 35, power 35 .. 46, x 4 .. w-8); the ring stays whole, 7 px over the rails'
    -- end (portrait centre 37, 39 in it, 60 px; the level circle's centre 60, 62). Elite: the dragon's ring is 4 px
    -- taller (centre 37, 43; level 60, 66). The rails start 14 (elite 18) px under the ring's top.
    tf_bars = { TF .. "UI-TargetingFrame", 256, 128, 27, 18, 150, 68 },
    tf_ring = { TF .. "UI-TargetingFrame", 256, 128, 143, 4, 220, 84 },
    tfe_bars = { TF .. "UI-TargetingFrame-Elite", 256, 128, 27, 18, 150, 68 },
    tfe_ring = { TF .. "UI-TargetingFrame-Elite", 256, 128, 143, 0, 256, 104 },
    tfr_ring = { TF .. "UI-TargetingFrame-Rare", 256, 128, 143, 0, 256, 104 },
    tfre_ring = { TF .. "UI-TargetingFrame-Rare-Elite", 256, 128, 143, 0, 256, 104 },
    -- target of target / pet / focus small, party: a ring and a short pair of rails (left 4, right 6 px)
    tot_ring = { TF .. "UI-TargetofTargetFrame", 128, 64, 0, 0, 46, 48 },
    tot_bars = { TF .. "UI-TargetofTargetFrame", 128, 64, 44, 8, 94, 36 },
    party_ring = { TF .. "UI-PartyFrame", 128, 64, 0, 2, 48, 50 },
    party_bars = { TF .. "UI-PartyFrame", 128, 64, 44, 4, 120, 34 },
    statusbar = { TF .. "UI-StatusBar", 64, 8, 0, 0, 64, 8 },
    skull = { TF .. "UI-TargetingFrame-Skull", 32, 32, 0, 0, 32, 32 },
    leader = { "Interface\\GroupFrame\\UI-Group-LeaderIcon", 16, 16, 0, 0, 16, 16 },
    -- roles: 20 px icons, healer at (20, 0), tank (0, 20), damage (20, 20)
    roles = { "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES", 64, 64, 0, 0, 40, 40 },
    circles = { TF .. "UI-Classes-Circles", 256, 256, 0, 0, 256, 256 },
    -- cast bars: the border stretches between 12 px ends, the fill inside at 9 .. w-10, 10 .. 24; the shield's left
    -- end is 50 px (the fill at 44 .. w-11, 19 .. 32, the icon 18 px at 14, 17)
    cast = { CB .. "UI-CastingBar-Border", 256, 64, 24, 14, 231, 48 },
    castFlash = { CB .. "UI-CastingBar-Flash", 256, 64, 24, 14, 231, 48 },
    castShield = { CB .. "UI-CastingBar-Small-Shield", 256, 64, 2, 6, 236, 54 },
    spark = { CB .. "UI-CastingBar-Spark", 32, 32, 0, 0, 32, 32 },
    -- raid cells
    raidFill = { "Interface\\RaidFrame\\Raid-Bar-Hp-Fill", 64, 64, 0, 0, 64, 64 },
    raidBg = { "Interface\\RaidFrame\\Raid-Bar-Hp-Bg", 32, 64, 0, 0, 32, 64 },
    raidPower = { "Interface\\RaidFrame\\Raid-Bar-Resource-Fill", 32, 8, 0, 0, 32, 8 },
    raidSelected = { "Interface\\RaidFrame\\Raid-FrameHighlights", 128, 128, 1, 37, 71, 71 },
    -- the minimap: the ring is 256 px with the map's 140 px circle at (54.5 + 44, 42 - 5) in it
    mmBorder = { "Interface\\Minimap\\UI-Minimap-Border", 256, 256, 0, 0, 256, 256 },
    tracking = { "Interface\\Minimap\\MiniMap-TrackingBorder", 64, 64, 0, 0, 64, 64 },
    zoomIn = { "Interface\\Minimap\\UI-Minimap-ZoomInButton-Up", 32, 32, 0, 0, 32, 32 },
    zoomOut = { "Interface\\Minimap\\UI-Minimap-ZoomOutButton-Up", 32, 32, 0, 0, 32, 32 },
    clock = { "Interface\\TimeManager\\ClockBackground", 64, 64, 0, 0, 64, 64 },
    -- meters: your row's gold
    questHi = { "Interface\\QuestFrame\\UI-QuestTitleHighlight", 128, 16, 0, 0, 128, 16 },
    -- the totem bar's element frames (34 x 36: the icon inset 3)
    totemEarth = { B .. "UI-TotemBar", 128, 256, 0, 172, 34, 208 },
    totemFire = { B .. "UI-TotemBar", 128, 256, 34, 172, 68, 208 },
    totemWater = { B .. "UI-TotemBar", 128, 256, 0, 208, 34, 244 },
    totemAir = { B .. "UI-TotemBar", 128, 256, 34, 136, 68, 172 },
}
local GAME = Look.GAME

-- Puts a game piece on a texture (its file and cut). Returns the piece's pixel size.
function Look:GameTex(t, key, wrapH, wrapV)
    local p = GAME[key]
    if not (t and p) then return 0, 0 end
    t:SetTexture(p[1], wrapH, wrapV)
    t:SetTexCoord(p[4] / p[2], p[6] / p[2], p[5] / p[3], p[7] / p[3])
    return p[6] - p[4], p[7] - p[5]
end

Look.PARTS = {
    { key = "units", name = "Unit frames", tip = "Player, target, target of target, focus and pet.", replaced = true },
    { key = "group", name = "Party and raid", tip = "Party frames and raid frames.", replaced = true },
    { key = "cast", name = "Cast bars", tip = "Your cast bar and the target's and focus's.", replaced = true },
    { key = "bars", name = "Action bars", tip = "Every action bar, the stance and pet bars, bags, menu and experience.",
      replaced = true },
    { key = "bags", name = "Bags", tip = "Your bags, the key ring and the bank in one window each.", replaced = true },
    { key = "minimap", name = "Minimap", tip = "The map, the zone and the clock, and the buttons around it." },
    -- (drawn by the addon over the world: UI/CombatText.lua; Blizzard = the game's own numbers)
    { key = "sct", name = "Combat text", tip = "Your hits, the hits you take, heals, procs and alerts as numbers on screen." },
}
local PART = {}
for _, p in ipairs(Look.PARTS) do PART[p.key] = p end

-- The faces. panel: bg (one colour, or bg + bg2 a top-to-bottom gradient), edge (1 px), outer (1 px outside it), inner
-- (1 px inside), corners (gilded L's); head: a header strip's gradient + line; bar: the bar kind; track: under the
-- fill; fillA: the fill's opacity; icon: square | round | framed | gilt | none; rim: the icon's edge colour; nameC: the
-- name's colour (nameClass: in class colour); upper: capitals; gap: between action buttons; plate: a ground behind
-- an action bar; studs: diamonds at a plate's ends.
Look.LOOKS = {
    { key = "blizzard", name = "Blizzard", tip = "The game's own frames, untouched." },
    { key = "flat", name = "Flat", tip = "Dark 66% panels, 1 px black edges, class-colour bars, square icons.",
      panel = { bg = { 0.039, 0.039, 0.051, 0.66 }, edge = { 0, 0, 0, 1 } },
      bar = "flat", track = { 1, 1, 1, 0.04 }, fillA = 0.74, icon = "square", rim = { 0, 0, 0, 1 },
      nameC = { 1, 1, 1 }, gap = 2, plate = true, buttonSize = 34 },
    { key = "halo", name = "Halo", tip = "Round portraits and buttons in thin rings, pill bars with a soft fade.",
      bar = "pill", track = { 0.031, 0.031, 0.043, 0.62 }, fillA = 0.9, icon = "round", rim = { 0, 0, 0, 1 },
      nameC = { 0.96, 0.86, 0.56 }, gap = 6, plate = false, buttonSize = 32, fade = true },
    { key = "sigil", name = "Sigil", tip = "Framed tiles, bars with a lit top edge, small caps. Crisp and bold.",
      panel = { bg = { 0.035, 0.035, 0.043, 0.86 }, edge = { 0, 0, 0, 1 }, inner = { 1, 1, 1, 0.07 } },
      head = { top = { 0.145, 0.145, 0.17, 1 }, bottom = { 0.078, 0.078, 0.09, 1 }, line = { 0, 0, 0, 1 } },
      bar = "lit", track = { 0.071, 0.071, 0.082, 1 }, fillA = 1, icon = "framed", rim = { 1, 0.82, 0, 0.75 },
      nameC = { 1, 0.82, 0 }, upper = true, gap = 3, plate = true, buttonSize = 34 },
    { key = "slate", name = "Slate", tip = "Text first: names in class colour, hairline bars, no portraits. The least screen.",
      panel = { bg = { 0.051, 0.051, 0.067, 0.72 }, edge = { 1, 1, 1, 0.08 } },
      bar = "hair", track = { 1, 1, 1, 0.08 }, fillA = 1, icon = "none", rim = { 0, 0, 0, 0 },
      nameC = { 1, 1, 1 }, nameClass = true, gap = 1, plate = false, buttonSize = 32 },
    { key = "gilded", name = "Gilded", tip = "Gold trim and corner studs, textured bars. The most 'WoW' of the looks.",
      panel = { bg = { 0.086, 0.063, 0.027, 0.9 }, bg2 = { 0.039, 0.031, 0.02, 0.9 }, edge = { 0.43, 0.33, 0.13, 1 },
                outer = { 0, 0, 0, 1 }, corners = { 0.89, 0.73, 0.33, 1 }, gilt = true },
      head = { top = { 0.231, 0.169, 0.059, 1 }, bottom = { 0.106, 0.078, 0.031, 1 }, line = { 0.54, 0.42, 0.15, 1 } },
      bar = "gilt", track = { 0, 0, 0, 0.45 }, fillA = 1, icon = "gilt", rim = { 0.66, 0.51, 0.17, 1 },
      nameC = { 1, 0.84, 0.42 }, gap = 3, plate = true, buttonSize = 34 },
    -- Classic: our layouts in the game's own art (mockup claude.ai/artifact/3MHRTnR18XaYMLqYj5cuHx, 2026-10-13). The
    -- panels wear the tooltip's edge, bars the game's status bar texture, icons the action button frame; each part
    -- draws its own game art from Look.GAME (game = true). Health is the game's green (raid cells: class colours)
    -- unless a part's colour option says else.
    { key = "classic", name = "Classic", tip = "The game's own art in our layouts: action button frames, the main bar's stone and gryphons, the backpack, the tooltip edge.",
      panel = { bg = { 0.035, 0.035, 0.075, 0.9 }, edge9 = "tip" },
      head = { top = { 0.1, 0.1, 0.14, 1 }, bottom = { 0.035, 0.035, 0.075, 1 }, line = { 0.36, 0.36, 0.4, 1 } },
      bar = "gilt", track = { 0, 0, 0, 0.5 }, fillA = 1, icon = "quick", rim = { 0, 0, 0, 1 },
      nameC = { 1, 0.82, 0 }, gap = 6, plate = true, buttonSize = 36, game = true, health = "green",
      healthCell = "class" },                      -- (raid cells in class colours, as the game's raid frames)
}
local BY_KEY = {}
for _, l in ipairs(Look.LOOKS) do BY_KEY[l.key] = l end
Look.BY_KEY = BY_KEY

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting(path)
    if v == nil then return default end
    return v
end
Look.Get = Get

-- The look chosen for a part ("inherit" follows Look for everything).
function Look:Chosen(part)
    local own = Get("ui." .. part .. ".look", "inherit")
    if own == nil or own == "inherit" or not BY_KEY[own] then
        local all = Get("ui.look", "blizzard")
        return BY_KEY[all] and all or "blizzard"
    end
    return own
end

-- The look a part wears now: a replaced part keeps the look it started with until a reload when it was switched to
-- or from Blizzard (its frames are the game's or ours for the whole session).
local applied = {}
function Look:Key(part)
    local chosen = self:Chosen(part)
    local p = PART[part]
    if p and p.replaced and applied[part] ~= nil then
        local was = applied[part]
        if (was == "blizzard") ~= (chosen == "blizzard") then return was end
    end
    return chosen
end

function Look:For(part) return BY_KEY[self:Key(part)] or BY_KEY.blizzard end
function Look:IsOn(part) return self:Key(part) ~= "blizzard" end

-- One look on everything that has one: every game part (each back to following ui.look) and the addon's own themed
-- parts whose theme list has it (meters, class bars, the swing and shot timers).
Look.THEMED = { { kind = "meters", setting = "meters.theme" }, { kind = "classbar", setting = "classbar.theme" },
                { kind = "ring_swing", setting = "swing.theme" }, { kind = "ring_shot", setting = "shot.theme" } }
function Look:UseEverywhere(key)
    if not (ns.DB and BY_KEY[key]) then return end
    for _, p in ipairs(Look.PARTS) do
        if Get("ui." .. p.key .. ".look", "inherit") ~= "inherit" then ns.DB:SetSetting("ui." .. p.key .. ".look", "inherit") end
    end
    ns.DB:SetSetting("ui.look", key)
    for _, t in ipairs(Look.THEMED) do
        local k = ns.Themes and ns.Themes:Kind(t.kind)
        if not k or (k.byKey and k.byKey[key]) then ns.DB:SetSetting(t.setting, key) end
    end
end

-- A part's option (Settings > UI, the part's card).
function Look:Opt(part, key, default) return Get("ui." .. part .. "." .. key, default) end

-- True when a replaced part was switched to or from Blizzard and waits for a reload.
function Look:NeedsReload(part)
    local p = PART[part]
    if not p or not p.replaced or applied[part] == nil then return false end
    return (applied[part] == "blizzard") ~= (self:Chosen(part) == "blizzard")
end

-- (the parts' files call this once their frames are up)
function Look:SetApplied(part, key) applied[part] = key end

function Look:OnInit()
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) ~= "string" or path:sub(1, 3) ~= "ui." then return end
        local reload = {}
        for _, p in ipairs(Look.PARTS) do
            if path == "ui.look" or path:find("^ui%." .. p.key .. "%.") then
                -- (restyled live: the frames wear the new look now)
                if applied[p.key] ~= nil and not Look:NeedsReload(p.key) then applied[p.key] = Look:Chosen(p.key) end
                ns:Fire("UI_LOOK_CHANGED", p.key, path)
                if Look:NeedsReload(p.key) then reload[#reload + 1] = p.name end
            end
        end
        if #reload > 0 and ns.Popup and ns.Popup.Confirm then
            ns.Popup:Confirm({ key = "uilookreload", title = "Reload to switch",
                text = ("%s switch between the game's frames and DisasterZone's after a reload."):format(
                    table.concat(reload, ", ")), ok = "Reload now", cancel = "Later",
                onAccept = function() if ReloadUI then ReloadUI() end end })
        end
    end)
end

-- The look tiles (Settings > UI): a small player frame in each look; Blizzard's says what it is.
local function PaintTile(tile, t)
    local p = tile.preview
    -- (the sample shrinks with the tile when the row has to fit more tiles)
    local k = math.min(1, (tile:GetWidth() or 88) / 88)
    if k <= 0 then k = 1 end
    if not p.host then
        p.host = CreateFrame("Frame", nil, p)
        p.host:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
        p.blizz = UI:Text(p, "small", "SUB", { justify = "CENTER" })
        p.blizz:SetPoint("TOP", tile, "TOP", 0, -16)
        p.blizz:SetText("The game's\nown frames")
        p.blizz:SetWordWrap(true)
    end
    p:SetSize(88 * k, 40)
    p.host:SetScale(0.36 * k)
    p.blizz:SetShown(t.key == "blizzard")
    if t.key == "blizzard" then if p.face then p.host:Hide() end return end
    if not ns.LookUnits then return end
    if not p.face then
        p.face = ns.LookUnits:NewFace(p.host, "big", "units", "left")
    end
    p.host:Show()
    p.face:Apply(t)
    p.face:Set(ns.LookUnits.Fake("player"))
end

function Look:Tiles(SU, sec)
    if not ns.Themes:Kind("uilook") then ns.Themes:Define("uilook", Look.LOOKS, "blizzard", { setting = "ui.look" }) end
    return ns.Themes:SettingsRow(SU, sec, "uilook", "Look for everything",
        "Every part below that follows it. Blizzard leaves the game's frames as they are.",
        { tileW = 88, tileH = 64, gap = 5, clip = true, band = true, nameY = 5, previewAt = { 6, -10 },
          paint = PaintTile })
end

---------------------------------------------------------------------------
-- Colours
---------------------------------------------------------------------------

Look.HOSTILE = { 0.78, 0.21, 0.17 }
Look.NEUTRAL = { 0.9, 0.75, 0.2 }
Look.FRIEND = { 0.3, 0.78, 0.33 }
Look.POWER = {
    [0] = { 0.24, 0.44, 0.85 }, [1] = { 0.77, 0.19, 0.17 }, [2] = { 1, 0.5, 0.25 }, [3] = { 1, 0.86, 0.25 },
    MANA = { 0.24, 0.44, 0.85 }, RAGE = { 0.77, 0.19, 0.17 }, FOCUS = { 1, 0.5, 0.25 }, ENERGY = { 1, 0.86, 0.25 },
}

function Look.ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 0.6, 0.6, 0.6
end

---------------------------------------------------------------------------
-- Panels
---------------------------------------------------------------------------

local function Tex(parent, layer, sub, path)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub or 0)
    t:SetTexture(path or WHITE)
    return t
end
Look.Tex = Tex

local function Color(t, c, a)
    if not c then t:Hide() return end
    t:SetVertexColor(c[1], c[2], c[3], a or c[4] or 1)
    t:Show()
end
Look.Color = Color

local function Gradient(t, bottom, top)
    if not (t.SetGradient and CreateColor) then Color(t, top) return end
    t:SetVertexColor(1, 1, 1, 1)
    local ok = pcall(t.SetGradient, t, "VERTICAL", CreateColor(bottom[1], bottom[2], bottom[3], bottom[4] or 1),
        CreateColor(top[1], top[2], top[3], top[4] or 1))
    if not ok then Color(t, top) end
    t:Show()
end
Look.Gradient = Gradient

-- Four 1 px lines round a frame, `out` px outside its edge (negative: inside).
local function Edges(parent, layer, sub)
    local e = {}
    for i = 1, 4 do e[i] = Tex(parent, layer or "BORDER", sub) end
    function e:Place(f, out)
        local a, b = out, -out
        e[1]:ClearAllPoints(); e[1]:SetPoint("TOPLEFT", f, "TOPLEFT", -a, a); e[1]:SetPoint("TOPRIGHT", f, "TOPRIGHT", a, a); e[1]:SetHeight(1)
        e[2]:ClearAllPoints(); e[2]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -a, b); e[2]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", a, b); e[2]:SetHeight(1)
        e[3]:ClearAllPoints(); e[3]:SetPoint("TOPLEFT", f, "TOPLEFT", -a, a); e[3]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -a, b); e[3]:SetWidth(1)
        e[4]:ClearAllPoints(); e[4]:SetPoint("TOPRIGHT", f, "TOPRIGHT", a, a); e[4]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", a, b); e[4]:SetWidth(1)
    end
    function e:Paint(c)
        for i = 1, 4 do Color(e[i], c) end
    end
    return e
end
Look.Edges = Edges

-- Halo's edges: a pill `out` px bigger than a w x h pill round frame f, drawn under it (its middle shows as a ring
-- round an opaque pill; a wide one at a low alpha is a glow). Paint(nil) hides it.
local function PillRing(parent, layer, sub)
    local p = { mid = Tex(parent, layer or "BACKGROUND", sub), l = Tex(parent, layer or "BACKGROUND", sub, DISC),
                r = Tex(parent, layer or "BACKGROUND", sub, DISC) }
    p.l:SetTexCoord(0, 0.5, 0, 1)
    p.r:SetTexCoord(0.5, 1, 0, 1)
    function p:Place(f, w, h, out)
        local H = h + 2 * out
        local R = H / 2
        self.l:ClearAllPoints(); self.l:SetSize(R, H); self.l:SetPoint("TOPLEFT", f, "TOPLEFT", -out, out)
        self.r:ClearAllPoints(); self.r:SetSize(R, H); self.r:SetPoint("TOPRIGHT", f, "TOPRIGHT", out, out)
        self.mid:ClearAllPoints()
        self.mid:SetPoint("TOPLEFT", f, "TOPLEFT", R - out, out)
        self.mid:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", out - R, -out)
        self.wide = w > h
        if not self.wide then self.mid:Hide() end
    end
    function p:Paint(c)
        Color(self.l, c); Color(self.r, c)
        if c and self.wide ~= false then Color(self.mid, c) else self.mid:Hide() end
    end
    return p
end
Look.PillRing = PillRing

---------------------------------------------------------------------------
-- Classic's game art: the tooltip's edge round a frame, a game piece tiled over an area, the action button frame
---------------------------------------------------------------------------

-- The game's backdrop edges (an edge file holds 8 squares: left, right, top, bottom and the four corners; top and
-- bottom stand up in the file and are turned). out: how far the pieces reach past the frame so the drawn line sits on
-- its edge.
local EDGE9 = { tip = { file = "Interface\\Tooltips\\UI-Tooltip-Border", e = 16, out = 4 },
                dialog = { file = "Interface\\DialogFrame\\UI-DialogBox-Border", e = 32, out = 9 } }
Look.EDGE9 = EDGE9
local Edge9Methods = {}
function Edge9Methods:Show(on)
    for _, t in ipairs(self.t) do t:SetShown(on and true or false) end
    self.on = on and true or false
end
function Edge9Methods:Paint(r, g, b, a)
    for _, t in ipairs(self.t) do t:SetVertexColor(r or 1, g or 1, b or 1, a or 1) end
end
-- (around frame `to`, its pieces size e; out as above)
function Edge9Methods:Place(to, e, out)
    local d = self.d
    e, out = e or d.e, out or d.out
    to = to or self.f
    local L, R, T, Bt, TL, TR, BL, BR = self.t[1], self.t[2], self.t[3], self.t[4], self.t[5], self.t[6], self.t[7], self.t[8]
    for _, t in ipairs(self.t) do t:ClearAllPoints() end
    TL:SetSize(e, e); TL:SetPoint("TOPLEFT", to, "TOPLEFT", -out, out)
    TR:SetSize(e, e); TR:SetPoint("TOPRIGHT", to, "TOPRIGHT", out, out)
    BL:SetSize(e, e); BL:SetPoint("BOTTOMLEFT", to, "BOTTOMLEFT", -out, -out)
    BR:SetSize(e, e); BR:SetPoint("BOTTOMRIGHT", to, "BOTTOMRIGHT", out, -out)
    -- (the sides between the corners, anchored to the frame itself)
    L:SetPoint("TOPLEFT", to, "TOPLEFT", -out, out - e); L:SetPoint("BOTTOMLEFT", to, "BOTTOMLEFT", -out, e - out); L:SetWidth(e)
    R:SetPoint("TOPRIGHT", to, "TOPRIGHT", out, out - e); R:SetPoint("BOTTOMRIGHT", to, "BOTTOMRIGHT", out, e - out); R:SetWidth(e)
    T:SetPoint("TOPLEFT", to, "TOPLEFT", e - out, out); T:SetPoint("TOPRIGHT", to, "TOPRIGHT", out - e, out); T:SetHeight(e)
    Bt:SetPoint("BOTTOMLEFT", to, "BOTTOMLEFT", e - out, -out); Bt:SetPoint("BOTTOMRIGHT", to, "BOTTOMRIGHT", out - e, -out); Bt:SetHeight(e)
end
function Look:Edge9(f, kind, layer, sub)
    local d = EDGE9[kind or "tip"] or EDGE9.tip
    local g = { f = f, d = d, t = {} }
    for k, fn in pairs(Edge9Methods) do g[k] = fn end
    for i = 1, 8 do
        local t = f:CreateTexture(nil, layer or "BORDER", nil, sub or 4)
        t:SetTexture(d.file)
        local a, b = (i - 1) / 8, i / 8
        if i == 3 or i == 4 then t:SetTexCoord(a, 1, b, 1, a, 0, b, 0)      -- (the standing piece turned: UL LL UR LR)
        else t:SetTexCoord(a, b, 0, 1) end
        g.t[i] = t
    end
    g:Place(f)
    g:Show(false)
    return g
end

-- A game piece repeated over an area (a sub-rectangle of a file can't wrap: one texture per piece, the last ones cut).
-- tile:Fill(to, x, y, w, h, pw, ph) covers w x h at (x, y) of `to` (y down) with pw x ph pieces; :Hide().
local TileMethods = {}
function TileMethods:Fill(to, x, y, w, h, pw, ph)
    local p = GAME[self.key]
    if not p or w <= 0 or h <= 0 then self:Hide() return end
    local sw, sh = p[6] - p[4], p[7] - p[5]
    pw, ph = pw or sw, ph or sh
    local n = 0
    local cols, rows = math.ceil(w / pw - 0.001), math.ceil(h / ph - 0.001)
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            n = n + 1
            local t = self.t[n]
            if not t then
                t = self.f:CreateTexture(nil, self.layer, nil, self.sub)
                t:SetTexture(p[1])
                self.t[n] = t
            end
            local tw, th = min(pw, w - c * pw), min(ph, h - r * ph)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", to, "TOPLEFT", x + c * pw, -(y + r * ph))
            t:SetSize(tw, th)
            local fx, fy = tw / pw, th / ph
            local u0, v0 = p[4] / p[2], p[5] / p[3]
            local u1 = (p[4] + sw * fx) / p[2]
            local v1 = (p[5] + sh * fy) / p[3]
            if self.flipY then t:SetTexCoord(u0, u1, v1, v0) else t:SetTexCoord(u0, u1, v0, v1) end
            if self.color then t:SetVertexColor(self.color[1], self.color[2], self.color[3], self.color[4] or 1) end
            t:Show()
        end
    end
    for i = n + 1, #self.t do self.t[i]:Hide() end
    self.n = n
end
function TileMethods:Hide() for _, t in ipairs(self.t) do t:Hide() end end
function TileMethods:SetColor(r, g, b, a) self.color = { r, g, b, a or 1 }; for _, t in ipairs(self.t) do t:SetVertexColor(r, g, b, a or 1) end end
function Look:GameTile(f, key, layer, sub)
    local g = { f = f, key = key, layer = layer or "BACKGROUND", sub = sub or 0, t = {} }
    for k, fn in pairs(TileMethods) do g[k] = fn end
    return g
end

-- A game piece that stretches between two fixed ends (a cast bar's border, the target frame's rails): three textures.
-- s:Place(to, x, y, w, h, k) puts it at (x, y) of `to` (y down), k scaling the ends (1); :Show(on), :SetBlend(mode),
-- :SetAlpha(a), :SetVertexColor(r, g, b, a), :SetFlipX(on) (the piece mirrored: the player's frame).
local Slice3Methods = {}
function Slice3Methods:Place(to, x, y, w, h, k)
    local p = GAME[self.key]
    if not p then return end
    k = k or 1
    local l, r = self.l * k, self.r * k
    local u0, u1, v0, v1 = p[4] / p[2], p[6] / p[2], p[5] / p[3], p[7] / p[3]
    local ul, ur = (p[4] + self.l) / p[2], (p[6] - self.r) / p[2]
    local L, M, R = self.t[1], self.t[2], self.t[3]
    local fl = self.flip
    -- (mirrored: the right end's art draws on the left)
    local lw, rw = fl and r or l, fl and l or r
    L:ClearAllPoints(); L:SetPoint("TOPLEFT", to, "TOPLEFT", x, -y); L:SetSize(lw, h)
    R:ClearAllPoints(); R:SetPoint("TOPLEFT", to, "TOPLEFT", x + w - rw, -y); R:SetSize(rw, h)
    M:ClearAllPoints(); M:SetPoint("TOPLEFT", to, "TOPLEFT", x + lw, -y); M:SetSize(math.max(0.01, w - lw - rw), h)
    if fl then
        L:SetTexCoord(u1, ur, v0, v1); M:SetTexCoord(ur, ul, v0, v1); R:SetTexCoord(ul, u0, v0, v1)
    else
        L:SetTexCoord(u0, ul, v0, v1); M:SetTexCoord(ul, ur, v0, v1); R:SetTexCoord(ur, u1, v0, v1)
    end
end
function Slice3Methods:Show(on) for _, t in ipairs(self.t) do t:SetShown(on and true or false) end end
function Slice3Methods:SetBlend(mode) for _, t in ipairs(self.t) do if t.SetBlendMode then t:SetBlendMode(mode) end end end
function Slice3Methods:SetAlpha(a) for _, t in ipairs(self.t) do t:SetAlpha(a) end end
function Slice3Methods:SetVertexColor(r, g, b, a) for _, t in ipairs(self.t) do t:SetVertexColor(r, g, b, a or 1) end end
function Slice3Methods:SetFlipX(on) self.flip = on and true or false end
function Look:GameSlice3(f, key, left, right, layer, sub)
    local s = { key = key, l = left, r = right, t = {} }
    for k, fn in pairs(Slice3Methods) do s[k] = fn end
    local p = GAME[key]
    for i = 1, 3 do
        local t = f:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
        if p then t:SetTexture(p[1]) end
        s.t[i] = t
    end
    return s
end

-- The action button frame (UI-Quickslot2, 66/36 of the button, centred) on texture t round frame f; again when f's
-- size changes. key: "quick" (default), "slot" (an empty slot), "pushed".
function Look:QuickFrame(t, f, key)
    self:GameTex(t, key or "quick")
    local function Fit()
        local w, h = f:GetWidth() or 0, f:GetHeight() or 0
        if w <= 0 then w = 36 end
        if h <= 0 then h = w end
        local ox, oy = w * 15 / 36, h * 15 / 36
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", f, "TOPLEFT", -ox, oy)
        t:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", ox, -oy)
    end
    Fit()
    -- (a frame refits when it changes size; a texture round which it sits is fitted again by its caller)
    if not t.dzQuickHooked and f.IsObjectType and f:IsObjectType("Frame") then
        t.dzQuickHooked = true
        f:HookScript("OnSizeChanged", Fit)
    end
end

local PanelMethods = {}

-- Paints a frame's ground in a look (nil or Blizzard: nothing).
function PanelMethods:Apply(look)
    local p = look and look.panel
    if self.e9 then self.e9:Show(p and p.edge9 and true or false) end
    if not p then
        self.bg:Hide(); self.edge:Paint(nil); self.outer:Paint(nil); self.inner:Paint(nil)
        for _, c in ipairs(self.corners) do c:Hide() end
        if self.gilt then self.gilt:Show(false) end
        return
    end
    -- (Classic: the game's tooltip edge instead of the 1 px lines)
    if p.edge9 then
        if not self.e9 then self.e9 = Look:Edge9(self.f, p.edge9, "BORDER", 4) end
        self.e9:Show(true)
        Color(self.bg, p.bg)
        self.edge:Paint(nil); self.outer:Paint(nil); self.inner:Paint(nil)
        for _, c in ipairs(self.corners) do c:Hide() end
        if self.gilt then self.gilt:Show(false) end
        return
    end
    if p.bg2 then Gradient(self.bg, p.bg2, p.bg) else Color(self.bg, p.bg) end
    -- (Gilded: the moulding and corners stand in for the edge, the outer line and the L's)
    if p.gilt and not self.gilt then self.gilt = Look:Gilt(self.f) end
    if self.gilt then self.gilt:Show(p.gilt and true or false) end
    self.edge:Paint(not p.gilt and p.edge or nil)
    self.outer:Paint(not p.gilt and p.outer or nil)
    self.inner:Paint(p.inner)
    for _, c in ipairs(self.corners) do
        if p.corners and not p.gilt then Color(c, p.corners) else c:Hide() end
    end
end

function Look:Panel(f)
    local p = { f = f }
    for k, fn in pairs(PanelMethods) do p[k] = fn end
    p.bg = Tex(f, "BACKGROUND", -6)
    p.bg:SetAllPoints(f)
    p.edge = Edges(f, "BORDER", 1); p.edge:Place(f, 0)
    p.outer = Edges(f, "BORDER", 0); p.outer:Place(f, 1)
    p.inner = Edges(f, "BORDER", 2); p.inner:Place(f, -1)
    -- gilded corners: two 2 px arms, 8 long, at the top corners
    p.corners = {}
    for i, pt in ipairs({ "TOPLEFT", "TOPRIGHT" }) do
        local sx = (i == 1) and -2 or 2
        local h = Tex(f, "OVERLAY", 3); h:SetSize(9, 2); h:SetPoint(pt, f, pt, sx, 2)
        local v = Tex(f, "OVERLAY", 3); v:SetSize(2, 9); v:SetPoint(pt, f, pt, sx, 2)
        p.corners[#p.corners + 1] = h
        p.corners[#p.corners + 1] = v
    end
    return p
end

---------------------------------------------------------------------------
-- Gilded's worked gold: a moulding round a frame (just outside its edge), a filigree piece on each corner and a
-- faint damask grain over its ground. opts: trim (px, 3; 0 = corners only), corner (px, 13), grain (alpha, 0.07;
-- false = none), layer (the trim's draw layer, "BORDER").
---------------------------------------------------------------------------

local GiltMethods = {}
-- (the textures' periods: trim_h is 64 x 16, so a t px high moulding repeats every 4t px; grain every 64 px)
function GiltMethods:Layout()
    local f, t = self.f, self.t
    local w, h = f:GetWidth() or 0, f:GetHeight() or 0
    if w <= 0 or h <= 0 then return end
    if t > 0 then
        local u = (w + 2 * t) / (4 * t)
        local v = (h + 2 * t) / (4 * t)
        self.top:SetTexCoord(0, u, 0, 1)
        self.bottom:SetTexCoord(0, u, 1, 0)
        self.left:SetTexCoord(0, 1, 0, v)
        self.right:SetTexCoord(1, 0, 0, v)
    end
    self.grain:SetTexCoord(0, w / 64, 0, h / 64)
end

function GiltMethods:Show(on, opts)
    if opts then
        self.t = opts.trim or self.t
        self.c = opts.corner or self.c
        if opts.grain ~= nil then self.ga = opts.grain end
    end
    local t, c = self.t, self.c
    local f = self.f
    for _, x in ipairs({ self.top, self.bottom, self.left, self.right }) do x:SetShown(on and t > 0) end
    for _, x in ipairs(self.cornerTex) do x:SetShown(on and c > 0) end
    self.grain:SetShown(on and self.ga and true or false)
    if not on then return end
    self.top:ClearAllPoints(); self.top:SetPoint("BOTTOMLEFT", f, "TOPLEFT", -t, 0)
    self.top:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", t, 0); self.top:SetHeight(t)
    self.bottom:ClearAllPoints(); self.bottom:SetPoint("TOPLEFT", f, "BOTTOMLEFT", -t, 0)
    self.bottom:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", t, 0); self.bottom:SetHeight(t)
    self.left:ClearAllPoints(); self.left:SetPoint("TOPRIGHT", f, "TOPLEFT", 0, 0)
    self.left:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", 0, 0); self.left:SetWidth(t)
    self.right:ClearAllPoints(); self.right:SetPoint("TOPLEFT", f, "TOPRIGHT", 0, 0)
    self.right:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", 0, 0); self.right:SetWidth(t)
    local o = t + 1           -- (the corner's stud sits on the moulding's corner)
    for i, pt in ipairs({ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }) do
        local x = self.cornerTex[i]
        local sx = (i == 1 or i == 3) and -o or o
        local sy = (i <= 2) and o or -o
        x:ClearAllPoints(); x:SetSize(c, c); x:SetPoint(pt, f, pt, sx, sy)
    end
    if self.ga then self.grain:SetVertexColor(1, 0.82, 0.4, self.ga) end
    self:Layout()
end

function Look:Gilt(f, opts)
    local g = { f = f, t = 3, c = 13, ga = 0.07, cornerTex = {} }
    for k, fn in pairs(GiltMethods) do g[k] = fn end
    local layer = opts and opts.layer or "BORDER"
    local function Trim(name)
        local x = f:CreateTexture(nil, layer, nil, 3)
        x:SetTexture(GILT .. name, "REPEAT", "REPEAT")
        return x
    end
    g.top, g.bottom = Trim("trim_h"), Trim("trim_h")
    g.left, g.right = Trim("trim_v"), Trim("trim_v")
    -- the corners mirrored from the top left's art
    local CO = { { 0, 1, 0, 1 }, { 1, 0, 0, 1 }, { 0, 1, 1, 0 }, { 1, 0, 1, 0 } }
    for i = 1, 4 do
        local x = f:CreateTexture(nil, "OVERLAY", nil, 6)
        x:SetTexture(GILT .. "corner")
        x:SetTexCoord(CO[i][1], CO[i][2], CO[i][3], CO[i][4])
        g.cornerTex[i] = x
    end
    g.grain = f:CreateTexture(nil, "BACKGROUND", nil, -5)
    g.grain:SetTexture(GILT .. "grain", "REPEAT", "REPEAT")
    g.grain:SetAllPoints(f)
    f:HookScript("OnSizeChanged", function() g:Layout() end)
    g:Show(false, opts)
    return g
end

---------------------------------------------------------------------------
-- Bars: a fill over a track, as wide as the bar's set width times the value
---------------------------------------------------------------------------

local BarMethods = {}

function BarMethods:SetWidthNow(w) self.w = w; self.f:SetWidth(w); self:Layout() end

-- kind: flat | pill | lit | hair | gilt (nil: the look's).
function BarMethods:Apply(look, kind, h)
    self.look = look
    self.kind = kind or (look and look.bar) or "flat"
    self.h = h or self.h or 10
    if self.kind == "hair" then self.f:SetHeight(max(1, self.h)) else self.f:SetHeight(self.h) end
    local tr = self.trackC or (look and look.track) or { 1, 1, 1, 0.05 }
    local pill = self.kind == "pill"
    Color(self.track, tr)
    for _, c in ipairs({ self.tcapL, self.tcapR }) do if pill then Color(c, tr) else c:Hide() end end
    self.fill:SetTexture(self.kind == "gilt" and SBAR or WHITE)
    self.lit:SetShown(self.kind == "lit")
    self.capL:SetShown(pill)
    self.capR:SetShown(pill)
    self:Paint()
    self:Layout()
end

function BarMethods:SetColor(r, g, b)
    self.r, self.g, self.b = r, g, b
    self:Paint()
end

function BarMethods:Paint()
    local r, g, b = self.r or 0.5, self.g or 0.5, self.b or 0.5
    local a = (self.look and self.look.fillA) or 1
    if self.kind == "lit" then
        Gradient(self.fill, { r * 0.62, g * 0.62, b * 0.62, a }, { min(1, r * 1.12 + 0.08), min(1, g * 1.12 + 0.08),
            min(1, b * 1.12 + 0.08), a })
        self.lit:SetVertexColor(1, 1, 1, 0.35)
    elseif self.kind == "pill" and self.look and self.look.fade then
        local from = self.fadeFrom or 0.45
        Gradient(self.fill, { r, g, b, a }, { r, g, b, a })
        if self.fill.SetGradient and CreateColor then
            pcall(self.fill.SetGradient, self.fill, "HORIZONTAL", CreateColor(r, g, b, a * from), CreateColor(r, g, b, a))
        end
        self.capL:SetVertexColor(r, g, b, a * from)
        self.capR:SetVertexColor(r, g, b, a)
    else
        self.fill:SetVertexColor(r, g, b, a)
        self.capL:SetVertexColor(r, g, b, a)
        self.capR:SetVertexColor(r, g, b, a)
    end
end

-- The fill's span: its left offset and the width a full bar fills (a pill's round ends are outside it).
function BarMethods:Span()
    local w = self.w or self.f:GetWidth() or 0
    local r = (self.kind == "pill") and floor((self.h or 0) / 2) or 0
    return r, max(0, w - 2 * r)
end

function BarMethods:SetValue(v)
    v = tonumber(v) or 0
    if v ~= v then v = 0 end
    self.v = max(0, min(1, v))
    self:Layout()
end

function BarMethods:Layout()
    local w = self.w or self.f:GetWidth() or 0
    local h = (self.kind == "hair") and max(1, self.h) or self.h
    local pill = self.kind == "pill"
    local r = pill and floor(h / 2) or 0
    self.track:ClearAllPoints()
    self.track:SetPoint("TOPLEFT", self.f, "TOPLEFT", r, 0)
    self.track:SetPoint("BOTTOMRIGHT", self.f, "BOTTOMRIGHT", -r, 0)
    if pill then
        self.tcapL:ClearAllPoints(); self.tcapL:SetSize(r, h); self.tcapL:SetPoint("LEFT", self.f, "LEFT", 0, 0)
        self.tcapR:ClearAllPoints(); self.tcapR:SetSize(r, h); self.tcapR:SetPoint("RIGHT", self.f, "RIGHT", 0, 0)
    end
    local fw = (w - 2 * r) * (self.v or 0)
    self.fill:ClearAllPoints()
    self.fill:SetPoint("TOPLEFT", self.f, "TOPLEFT", r, 0)
    self.fill:SetPoint("BOTTOMLEFT", self.f, "BOTTOMLEFT", r, 0)
    self.fill:SetWidth(max(0.01, fw))
    self.fill:SetShown(fw > 0.5)
    if self.kind == "gilt" then self.fill:SetTexCoord(0, max(0.01, self.v or 0), 0, 1) else self.fill:SetTexCoord(0, 1, 0, 1) end
    if pill then
        local on = (self.v or 0) > 0
        self.capL:ClearAllPoints(); self.capL:SetSize(r, h); self.capL:SetPoint("RIGHT", self.fill, "LEFT", 0, 0)
        self.capR:ClearAllPoints(); self.capR:SetSize(r, h); self.capR:SetPoint("LEFT", self.fill, "RIGHT", 0, 0)
        self.capL:SetShown(on); self.capR:SetShown(on)
    end
    self.lit:ClearAllPoints()
    self.lit:SetPoint("TOPLEFT", self.fill, "TOPLEFT", 0, 0)
    self.lit:SetPoint("TOPRIGHT", self.fill, "TOPRIGHT", 0, 0)
    self.lit:SetHeight(1)
    -- a part of the track drawn over the fill's end (latency on a cast bar): SetEnd(frac, r, g, b, a)
    if self.endPart and self.endFrac then
        self.endPart:ClearAllPoints()
        self.endPart:SetPoint("TOPRIGHT", self.f, "TOPRIGHT", -r, 0)
        self.endPart:SetPoint("BOTTOMRIGHT", self.f, "BOTTOMRIGHT", -r, 0)
        self.endPart:SetWidth(max(0.01, (w - 2 * r) * self.endFrac))
        -- (a pill's end is round: the wash takes the track's right cap too)
        if self.endCap then
            self.endCap:ClearAllPoints()
            self.endCap:SetSize(r, h)
            self.endCap:SetPoint("RIGHT", self.f, "RIGHT", 0, 0)
            self.endCap:SetShown(pill and self.endPart:IsShown())
        end
    end
end

-- A stretch at the bar's end in its own colour (a cast's latency); frac nil: none.
function BarMethods:SetEnd(frac, r, g, b, a)
    if not self.endPart then
        self.endPart = Tex(self.f, "ARTWORK", 0)
        self.endCap = Tex(self.f, "ARTWORK", 0, DISC)
        self.endCap:SetTexCoord(0.5, 1, 0, 1)
    end
    self.endFrac = frac
    if not frac or frac <= 0 then self.endPart:Hide(); self.endCap:Hide() return end
    self.endPart:SetVertexColor(r or 1, g or 0.25, b or 0.16, a or 0.45)
    self.endCap:SetVertexColor(r or 1, g or 0.25, b or 0.16, a or 0.45)
    self.endPart:Show()
    self:Layout()
end

function Look:Bar(parent)
    local f = CreateFrame("Frame", nil, parent)
    local b = { f = f, v = 0, h = 10 }
    for k, fn in pairs(BarMethods) do b[k] = fn end
    b.track = Tex(f, "BACKGROUND", 1)
    b.tcapL = Tex(f, "BACKGROUND", 1, DISC); b.tcapL:SetTexCoord(0, 0.5, 0, 1)
    b.tcapR = Tex(f, "BACKGROUND", 1, DISC); b.tcapR:SetTexCoord(0.5, 1, 0, 1)
    b.fill = Tex(f, "ARTWORK", 1)
    b.capL = Tex(f, "ARTWORK", 1, DISC); b.capL:SetTexCoord(0, 0.5, 0, 1)
    b.capR = Tex(f, "ARTWORK", 1, DISC); b.capR:SetTexCoord(0.5, 1, 0, 1)
    b.lit = Tex(f, "ARTWORK", 2)
    f:SetScript("OnSizeChanged", function(_, w) if w and w > 0 and not b.fixedW then b.w = w; b:Layout() end end)
    return b
end

---------------------------------------------------------------------------
-- Icons and portraits
---------------------------------------------------------------------------

local IconMethods = {}

-- shape: square | round | framed | gilt | small | none (nil: the look's).
function IconMethods:Apply(look, shape)
    self.look = look
    self.shape = shape or (look and look.icon) or "square"
    local f = self.f
    f:SetShown(self.shape ~= "none")
    local rim = look and look.rim or { 0, 0, 0, 1 }
    local round = self.shape == "round"
    self.ring:SetShown(round)
    self.ringIn:SetShown(round)
    if round then
        Color(self.ring, self.ringColor or rim)
        Color(self.ringIn, { 0, 0, 0, 1 })
        self.edge:Paint(nil); self.edge2:Paint(nil)
    elseif self.shape == "framed" then
        self.edge:Paint({ 0, 0, 0, 1 }); self.edge2:Paint(rim)
    elseif self.shape == "gilt" or self.shape == "quick" then
        self.edge:Paint(nil); self.edge2:Paint(nil)
    else
        self.edge:Paint(self.shape == "small" and nil or rim); self.edge2:Paint(nil)
    end
    -- Gilded: the worked square bezel, a pixel over the icon's edge
    if self.shape == "gilt" and not self.bezel then
        self.bezel = f:CreateTexture(nil, "OVERLAY", nil, 3)
        self.bezel:SetTexture(GILT .. "bezel")
        self.bezel:SetPoint("TOPLEFT", f, "TOPLEFT", -1, 1)
        self.bezel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 1, -1)
    end
    if self.bezel then self.bezel:SetShown(self.shape == "gilt") end
    -- Classic: the action button frame round the icon
    if self.shape == "quick" and not self.qs then
        self.qs = f:CreateTexture(nil, "OVERLAY", nil, 3)
        Look:QuickFrame(self.qs, f)
    end
    if self.qs then self.qs:SetShown(self.shape == "quick") end
    self:Refresh()
end

-- The ring's colour (Halo: the class or the rarity).
function IconMethods:SetRing(r, g, b)
    self.ringColor = r and { r, g, b, 1 } or nil
    if self.shape == "round" then Color(self.ring, self.ringColor or (self.look and self.look.rim) or { 0, 0, 0, 1 }) end
end

-- A texture (a path or file id), with tex coords for a square crop; round looks get the game's round cut.
function IconMethods:SetTexture(path, l, r, t, b)
    self.kind, self.path, self.unit = "tex", path, nil
    self.coords = l and { l, r, t, b } or nil
    self:Refresh()
end

-- A unit's 2D portrait.
function IconMethods:SetPortrait(unit)
    self.kind, self.unit, self.path = "unit", unit, nil
    self:Refresh()
end

-- The disc mask on the texture (round textures), made the first time.
function IconMethods:Mask(on)
    local t = self.tex
    if on and not self.mask and self.f.CreateMaskTexture then
        self.mask = self.f:CreateMaskTexture()
        self.mask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        self.mask:SetAllPoints(t)
    end
    if not self.mask then return end
    if on and not self.masked then pcall(t.AddMaskTexture, t, self.mask); self.masked = true
    elseif not on and self.masked then pcall(t.RemoveMaskTexture, t, self.mask); self.masked = false end
end

function IconMethods:Refresh()
    local t = self.tex
    if self.kind == "unit" and self.unit then
        self:Mask(false)
        if SetPortraitTexture then pcall(SetPortraitTexture, t, self.unit) end
        if self.shape == "round" then t:SetTexCoord(0, 1, 0, 1) else t:SetTexCoord(0.14, 0.86, 0.14, 0.86) end
    elseif self.path then
        -- (a texture with coords is a cut of a sheet, already shaped: the class circles; else a round look masks it
        -- with the portrait disc: the portrait cut did nothing to file ids in game)
        if self.shape == "round" and not self.coords then
            t:SetTexture(self.path)
            t:SetTexCoord(0.06, 0.94, 0.06, 0.94)
            self:Mask(true)
        else
            self:Mask(false)
            t:SetTexture(self.path)
            local c = self.coords
            if c then t:SetTexCoord(c[1], c[2], c[3], c[4]) else t:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
        end
    end
end

function Look:Icon(parent)
    local f = CreateFrame("Frame", nil, parent)
    local ic = { f = f }
    for k, fn in pairs(IconMethods) do ic[k] = fn end
    ic.ring = Tex(f, "BACKGROUND", 1, DISC)
    ic.ring:SetPoint("TOPLEFT", -3, 3); ic.ring:SetPoint("BOTTOMRIGHT", 3, -3)
    ic.ringIn = Tex(f, "BACKGROUND", 2, DISC)
    ic.ringIn:SetPoint("TOPLEFT", -1.5, 1.5); ic.ringIn:SetPoint("BOTTOMRIGHT", 1.5, -1.5)
    ic.tex = f:CreateTexture(nil, "ARTWORK")
    ic.tex:SetAllPoints(f)
    ic.edge = Edges(f, "OVERLAY", 1); ic.edge:Place(f, -0)
    ic.edge2 = Edges(f, "OVERLAY", 2); ic.edge2:Place(f, -1)
    return ic
end

-- A class's square icon / round circle texture and coords.
function Look.ClassIcon(class, round)
    local co = CLASS_ICON_TCOORDS and class and CLASS_ICON_TCOORDS[class]
    if not co then return nil end
    if round then return "Interface\\TargetingFrame\\UI-Classes-Circles", co[1], co[2], co[3], co[4] end
    local inset = 0.02
    return "Interface\\WorldStateFrame\\Icons-Classes", co[1] + inset, co[2] - inset, co[3] + inset, co[4] - inset
end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------

-- A unit frame's text: the type scale's size, the game's outline-ish shadow.
function Look:Text(parent, size, color, opts)
    local fs = UI:Text(parent, size or "body", color or "TEXT", { shadow = true, justify = opts and opts.justify })
    fs:SetWordWrap(false)
    return fs
end

-- A frame no one sees: what a replaced Blizzard frame is parented to.
function Look:Hidden()
    if not self.hidden then
        self.hidden = CreateFrame("Frame", "DisasterZoneLookHidden", UIParent)
        self.hidden:Hide()
    end
    return self.hidden
end

-- Takes a Blizzard frame out of play the way unit frame addons do: no events, hidden, under a hidden parent (so
-- nothing the game does to it can show it again). Out of combat only (protected frames); returns true when done.
function Look:Retire(f, keepParent)
    if type(f) == "string" then f = _G[f] end
    if not f then return true end
    if InCombatLockdown and InCombatLockdown() and f.IsProtected and f:IsProtected() then return false end
    pcall(f.UnregisterAllEvents, f)
    pcall(f.Hide, f)
    if not keepParent then pcall(f.SetParent, f, self:Hidden()) end
    return true
end
