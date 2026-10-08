if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UIMain.lua", ...) then return end -- DisasterZone Games/Disastercraft/UIMain.lua
-- CraftUI's root: the panel the Games hub shows, the frame loop (the game ticks while the panel is on screen), the
-- keyboard (WoW's default keys: WASD / arrows, Tab, 1-0 - =, Shift for the second row, B C P L O, F to interact,
-- X to sit, Enter to chat, Esc to close things / the game menu) and the change between the character screens and
-- the world. While the real you is in combat the game lets go of the keyboard (WoW forbids taking it then).
local addonName, ns = ...

local UI = ns.CraftUI
local K = UI.Kit
local Craft = ns.Craft

local floor, max, min = math.floor, math.max, math.min

local root
local focused = false
local held = {}                       -- movement keys held

local MOVE = { W = { 0, -1 }, UP = { 0, -1 }, S = { 0, 1 }, DOWN = { 0, 1 }, A = { -1, 0 }, LEFT = { -1, 0 },
               D = { 1, 0 }, RIGHT = { 1, 0 } }
local ACTION_KEYS = {}
for i, k in ipairs({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=" }) do ACTION_KEYS[k] = i end

local function UpdateInput()
    local dx, dy = 0, 0
    for k in pairs(held) do
        local m = MOVE[k]
        if m then dx, dy = dx + m[1], dy + m[2] end
    end
    if Craft.World then
        Craft.World.input.dx = (dx > 0 and 1) or (dx < 0 and -1) or 0
        Craft.World.input.dy = (dy > 0 and 1) or (dy < 0 and -1) or 0
    end
end

function UI.SetFocus(on)
    if on and InCombatLockdown and InCombatLockdown() then return end
    focused = on and true or false
    if root then
        root:EnableKeyboard(focused)
        if root.paused then root.paused:SetShown(not focused and UI.inWorld) end
    end
    if not focused then for k in pairs(held) do held[k] = nil end UpdateInput() end
end

local function Propagate(yes)
    if InCombatLockdown and InCombatLockdown() then return end
    if root.SetPropagateKeyboardInput then pcall(root.SetPropagateKeyboardInput, root, yes) end
end

local function OnKeyDown(self, key)
    if not UI.inWorld then
        if key == "ESCAPE" then Propagate(true) return end
        if key == "ENTER" and UI.Glue and UI.glue and UI.glue.select:IsShown() then Propagate(false) UI.Glue.EnterWorld() return end
        Propagate(true)
        return
    end
    local p = Craft.player
    if MOVE[key] then
        held[key] = true
        UpdateInput()
        Propagate(false)
        return
    end
    local shift = IsShiftKeyDown and IsShiftKeyDown()
    local handled = true
    if key == "ESCAPE" then
        if UI.cursorItem or UI.cursorAction then UI.ClearCursorItem()
        elseif UI.Hud.popup:IsShown() and UI.Hud.popup.key ~= "release" and UI.Hud.popup.key ~= "res" then UI.Hud.popup:Hide()
        elseif UI.CloseAll() then
        elseif p and p.casting then Craft.Combat.Interrupt(p)
        elseif p and p.target then Craft.World.SetTarget(nil)
        else UI.ToggleMenu() end
    elseif key == "TAB" then
        Craft.World.TabTarget()
    elseif ACTION_KEYS[key] then
        -- (the main row follows its action page; Shift the row above)
        local b = UI.Hud.actions[ACTION_KEYS[key] + (shift and 12 or 0)]
        local slot = b and b.slot or (ACTION_KEYS[key] + (shift and 12 or 0))
        Craft.Npc.UseAction(slot)
        if b then UI.Flash(b) end
    elseif key == "B" then UI.ToggleAllBags()
    elseif key == "C" then UI.Toggle("character")
    elseif key == "P" then UI.Toggle("spellbook")
    elseif key == "N" then UI.Toggle("talents")
    elseif key == "L" then UI.Toggle("questlog")
    elseif key == "O" then UI.Toggle("party")
    elseif key == "F" or key == "SPACE" then
        local n = Craft.World.Nearest()
        if n then Craft.World.Interact(n) elseif p.target then Craft.World.Interact(p.target) end
    elseif key == "X" then Craft.World.ToggleSit()
    elseif key == "ENTER" then UI.OpenChat()
    elseif key == "T" and p.target then Craft.Combat.StartAttack(p, p.target)
    else
        handled = false
    end
    Propagate(not handled)
end

local function OnKeyUp(self, key)
    if MOVE[key] then
        held[key] = nil
        UpdateInput()
    end
end

---------------------------------------------------------------------------
-- The loop
---------------------------------------------------------------------------

local function OnUpdate(self, dt)
    if dt > 0.25 then dt = 0.25 end                  -- (a hitch: no teleporting creatures)
    if not UI.inWorld then return end
    Craft:Update(dt)
    UI.DrawWorld(dt)
    if UI.FX then UI.FX.Update() end
    UI.UpdateHud(dt)
    if UI.UpdateParty then UI.UpdateParty(dt) end
    -- the loot window closes when you walk away from the corpse
    local lo = Craft.Loot.open
    if lo and Craft.UnitDist(Craft.player, lo) > Craft.INTERACT_RANGE + 2 then Craft.Loot.Close() end
    -- NPC windows close when you walk away
    for name, f in pairs(UI.open) do
        local npc = f.npc
        if npc and Craft.UnitDist(Craft.player, npc) > 10 then UI.CloseWindow(f) end
    end
end

---------------------------------------------------------------------------
-- The character screens <-> the world
---------------------------------------------------------------------------

function UI.EnterWorld(cls)
    if not Craft:Login(cls) then return end
    Craft.World.Enter(Craft.char)
    UI.inWorld = true
    UI.glue:Hide()
    UI.world:Show()
    UI.hudFrame:Show()
    UI.SetFocus(true)
    Craft:Msg("Welcome to Disastercraft! Press Esc for the game menu and the controls.", "system")
    if Craft.Party and Craft.Party.OnEnterWorld then Craft.Party.OnEnterWorld() end
end

function UI.ToGlue()
    if UI.inWorld then
        UI.CloseAll()
        if Craft.Party and Craft.Party.OnLeaveWorld then Craft.Party.OnLeaveWorld() end
        Craft.World.Leave()
        Craft:Logout()
    end
    UI.inWorld = false
    UI.hudFrame:Hide()
    UI.world:Hide()
    UI.glue:Show()
    UI.Glue.ShowSelect()
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

function UI:CreatePanel(parent)
    if root then root:SetParent(parent) root:SetAllPoints(parent) return root end
    root = CreateFrame("Frame", nil, parent)
    root:SetAllPoints(parent)
    root:EnableMouse(true)
    root.bg = K.Tex(root, "BACKGROUND")
    root.bg:SetAllPoints()
    root.bg:SetColorTexture(0, 0, 0, 1)
    -- the world fills the panel; the HUD on top is scaled so WoW's 1024-wide bar fits
    local world = CreateFrame("Frame", nil, root)
    world:SetAllPoints()
    UI.world = world
    UI.BuildWorld(world)
    local hud = CreateFrame("Frame", nil, root)
    hud:SetAllPoints()
    hud:SetFrameLevel(root:GetFrameLevel() + 30)
    UI.hudFrame = hud
    UI.BuildHud(hud)
    UI.BuildCursor(hud)
    if UI.BuildParty then UI.BuildParty(hud) end
    UI.BuildGlue(root)
    -- "paused" when the keyboard is let go: a click on the world takes it back
    root.paused = CreateFrame("Button", nil, root)
    root.paused:SetSize(260, 40)
    root.paused:SetPoint("TOP", 0, -80)
    root.paused:SetFrameLevel(root:GetFrameLevel() + 60)
    root.paused.bg = K.Tex(root.paused, "BACKGROUND")
    root.paused.bg:SetAllPoints()
    root.paused.bg:SetColorTexture(0, 0, 0, 0.7)
    root.paused.text = K.Font(root.paused, 14, "OUTLINE")
    root.paused.text:SetPoint("CENTER")
    root.paused.text:SetText("Click here to take the keyboard back")
    root.paused:SetScript("OnClick", function() UI.SetFocus(true) end)
    root.paused:Hide()
    root:SetScript("OnKeyDown", OnKeyDown)
    root:SetScript("OnKeyUp", OnKeyUp)
    root:SetScript("OnUpdate", OnUpdate)
    root:SetScript("OnSizeChanged", function() UI.Fit() end)
    hud:Hide()
    world:Hide()
    function root:OnGameShown()
        UI.Fit()
        if UI.inWorld then UI.SetFocus(true) else UI.Glue.ShowSelect() root:EnableKeyboard(true) end
    end
    function root:OnGameHidden()
        UI.SetFocus(false)
        root:EnableKeyboard(false)
        if ResetCursor then ResetCursor() end
        K.HideTooltip()
    end
    root:SetScript("OnHide", function() UI.SetFocus(false) end)
    ns:On("GAMES_COMBAT", function(inCombat) if inCombat then UI.SetFocus(false) end end)
    UI.root = root
    UI.Glue.ShowSelect()
    UI.Fit()
    return root
end

-- WoW's frames at a size that fits the panel (the bar is 1024 wide; anything smaller scales down)
-- the panel's size (an anchored frame in the offline mock reports 0: the Games hub's usual size then)
function UI.PanelSize()
    local w, h = root and root:GetWidth() or 0, root and root:GetHeight() or 0
    if not w or w <= 0 or not h or h <= 0 then return 790, 518 end
    return w, h
end

function UI.Fit()
    if not root or not UI.hudFrame then return end
    local w, h = UI.PanelSize()
    local s = min(1, w / 1100, h / 720)
    s = max(0.55, s)
    UI.hudFrame:SetScale(s)
end

-- slash: /dz craft  (opens the game)
ns:RegisterSlash("craft", function() if ns.Games then ns.Games:Open("disastercraft") end end, "craft - play Disastercraft")
