if DisasterZoneBoot and DisasterZoneBoot.Run("UI/KeyBinds.lua", ...) then return end -- DisasterZone UI/KeyBinds.lua
-- Key binds (/dz keys, the Esc menu, a minimap pin, Settings > Layout, a key binding): the addon's own quick key bind
-- mode, built 2026-10-15 after the game's Quick Keybind Mode broke on this client (ActionButton.lua:1371, Vic: its
-- C_ActionBar.PutActionInSlot fails when an ability is dropped). Its own mode, apart from Edit layout (the user's pick:
-- moving frames and binding keys don't share a screen); the game's own mode stays as it is (UI/LookBars.lua guards it).
-- The screen: the edges darken (a vignette, the middle clear), every bindable button on the screen wears a quiet edge
-- and its key as a small cap under it (gold "s" / "c" / "a" for the modifiers); the button under the mouse lights up
-- gold, glows and breathes (it is listening). Press a key (modifiers, the middle and side mouse buttons, the wheel) and
-- it is that button's key: the cap pops in, the button flashes. A key that was on another button moves here: that one
-- flashes rose and a note under the bar says where it came from. Right-click or Esc on a button clears its key; Esc
-- elsewhere is Done. Drag an ability onto another to swap them (PickupAction / PlaceAction: never the game's broken
-- call); a click with an ability on the cursor drops it there.
-- The bar at the screen's top (Edit layout's own, EditMode.BarKit): "Key binds", the readout (the button under the
-- mouse: its bar and number, what is on it, its keys; else what to do), This character (keys for this character only:
-- the game's character binding set), undo / redo (Ctrl+Z / Ctrl+Y), Discard (the keys as they were when it opened)
-- and Done (saves them in the game's binding set). A fight closes it (the game forbids binding keys then) and keeps
-- what was bound.
-- The buttons: the game's five action bars (whatever look or Dock they wear: binders sit over the buttons, nothing of
-- theirs is touched), the stance and pet bars, and the addon's buttons that register (KB:Register: the totem rows).
-- Demo mode: made-up keys on every button, kept in memory only; nothing is bound or saved.
local addonName, ns = ...

local KB = ns:NewModule("KeyBinds")
local UI, S = ns.UI, ns.Style

local floor, max, min, abs, sin = math.floor, math.max, math.min, math.abs, math.sin
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local tremove = table.remove

local GOLD = S.C.GOLD
local GOLD_DEEP = S.C.GOLD_DEEP
local ROSE = { 1, 0.42, 0.6 }
local RADIAL = "Interface\\AddOns\\DisasterZone\\Media\\MyBiS\\Radial"
local QUIET_EDGE = { 0.93, 0.91, 0.86, 0.16 }
local BOUND_EDGE = { 0.91, 0.73, 0.14, 0.42 }
local FLASH_T, WARN_T, NOTE_T = 0.45, 0.9, 4      -- seconds: the bound flash, the rose flash, the note under the bar
local MOD_HEX = "|cffb39556"                       -- the modifiers on a key cap (a muted gold)

-- The game's bars: button name prefix, binding command prefix, count, readout name, holds actions (drag / drop).
local BARS = {
    { "ActionButton", "ACTIONBUTTON", 12, "Action bar", true },
    { "MultiBarBottomLeftButton", "MULTIACTIONBAR1BUTTON", 12, "Bottom left bar", true },
    { "MultiBarBottomRightButton", "MULTIACTIONBAR2BUTTON", 12, "Bottom right bar", true },
    { "MultiBarRightButton", "MULTIACTIONBAR3BUTTON", 12, "Right bar", true },
    { "MultiBarLeftButton", "MULTIACTIONBAR4BUTTON", 12, "Right bar 2", true },
    { "StanceButton", "SHAPESHIFTBUTTON", 10, "Stance bar" },
    { "PetActionButton", "BONUSACTIONBUTTON", 10, "Pet bar" },
}
-- keys that are never a binding of their own (held with another key, or the mouse's two main buttons)
local IGNORED = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true, LMETA = true,
    RMETA = true, UNKNOWN = true, BUTTON1 = true, BUTTON2 = true }
local MOUSE = { MiddleButton = "BUTTON3", Button3 = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }

local overlay, bar, note
local active = false
local binders = {}        -- target frame -> binder
local extras = {}         -- KB:Register: { frame, label }
local hovered             -- the binder under the mouse
local undo, redo = {}, {}
local targetSet           -- the binding set Done saves into (1 account, 2 this character)
local dirty = false
local demoKeys            -- demo mode: command -> { keys } (in memory only)
local noteUntil = 0

local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end
local function Clock() return GetTime and GetTime() or 0 end
local function Demo() return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() and true or false end
local function Kit() return ns.EditMode and ns.EditMode.BarKit end

function KB:IsActive() return active end

---------------------------------------------------------------------------
-- Keys: the game's bindings, or demo mode's made-up ones
---------------------------------------------------------------------------

-- The keys on a command, in order.
function KB:Keys(cmd)
    if not cmd then return {} end
    if demoKeys then
        local out = {}
        for i, k in ipairs(demoKeys[cmd] or {}) do out[i] = k end
        return out
    end
    return GetBindingKey and { GetBindingKey(cmd) } or {}
end

-- The command a key runs (nil: none).
function KB:ActionOf(key)
    if demoKeys then
        for cmd, keys in pairs(demoKeys) do
            for _, k in ipairs(keys) do if k == key then return cmd end end
        end
        return nil
    end
    local a = GetBindingAction and GetBindingAction(key)
    return (a and a ~= "") and a or nil
end

-- Puts a key on a command (nil: the key runs nothing).
local function SetKey(key, cmd)
    if demoKeys then
        for _, keys in pairs(demoKeys) do
            for i = #keys, 1, -1 do if keys[i] == key then tremove(keys, i) end end
        end
        if cmd then
            demoKeys[cmd] = demoKeys[cmd] or {}
            local t = demoKeys[cmd]
            t[#t + 1] = key
        end
        return true
    end
    if InCombat() or not SetBinding then return false end
    if cmd then return SetBinding(key, cmd) end
    return SetBinding(key)
end

-- A set of changes { { key, before, after } }: forth = after, back = before (in reverse).
local function Apply(changes, back)
    if back then
        for i = #changes, 1, -1 do SetKey(changes[i][1], changes[i][2]) end
    else
        for _, c in ipairs(changes) do SetKey(c[1], c[3]) end
    end
    dirty = true
end

-- The key as a short cap: "s1", "cQ", "aWU", "M4"; the modifiers in muted gold.
function KB.Short(key)
    if not key or key == "" then return "" end
    local mods, base = key:match("^(.-)([^%-]+)$")
    if not base then return key end
    if base == "" then base, mods = "-", mods:sub(1, -2) end
    local m = (mods or ""):gsub("ALT%-", "a"):gsub("CTRL%-", "c"):gsub("SHIFT%-", "s"):gsub("META%-", "m")
    base = base:gsub("^NUMPAD", "N"):gsub("MOUSEWHEELUP", "WU"):gsub("MOUSEWHEELDOWN", "WD"):gsub("^BUTTON", "M")
        :gsub("SPACE", "Spc"):gsub("BACKSPACE", "Bks"):gsub("CAPSLOCK", "Caps"):gsub("PAGEUP", "PgU")
        :gsub("PAGEDOWN", "PgD"):gsub("INSERT", "Ins"):gsub("DELETE", "Del"):gsub("HOME", "Hm"):gsub("ENTER", "Ent")
        :gsub("TAB", "Tab")
    if m == "" then return base end
    return MOD_HEX .. m .. "|r" .. base
end

-- The key in words: "Shift-1", "Mouse Wheel Up".
local function Words(key)
    if not key then return "" end
    local t = GetBindingText and GetBindingText(key)
    return (t and t ~= "") and t or key
end

-- The key held now (the modifiers in the game's order: ALT, CTRL, SHIFT).
local function Chord(key)
    return (IsAltKeyDown and IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown and IsControlKeyDown() and "CTRL-" or "")
        .. (IsShiftKeyDown and IsShiftKeyDown() and "SHIFT-" or "") .. key
end

---------------------------------------------------------------------------
-- The buttons
---------------------------------------------------------------------------

-- An addon button that takes a key (a secure button with a global name): label = its name in the readout.
function KB:Register(frame, label)
    if not frame or not frame.GetName or not frame:GetName() then return end
    for _, e in ipairs(extras) do if e.frame == frame then e.label = label return end end
    extras[#extras + 1] = { frame = frame, label = label }
end

-- Every bindable button: { frame, cmd, label, slot (an action slot: drag and drop), kind ("action"|"stance"|"pet"|
-- "click"), index }.
function KB:Targets()
    local out = {}
    for _, b in ipairs(BARS) do
        for i = 1, b[3] do
            local f = _G[b[1] .. i]
            if f then
                local cmd = type(f.commandName) == "string" and f.commandName or (b[2] .. i)
                out[#out + 1] = { frame = f, cmd = cmd, label = b[4] .. " " .. i, bar = b[4], index = i,
                    kind = b[5] and "action" or (b[1] == "StanceButton" and "stance" or "pet") }
            end
        end
    end
    for _, e in ipairs(extras) do
        out[#out + 1] = { frame = e.frame, cmd = "CLICK " .. e.frame:GetName() .. ":LeftButton", label = e.label,
            kind = "click" }
    end
    return out
end

-- Every binding command Key binds manages, shown or not (UI profiles save their keys: Core/Profiles.lua).
function KB:Commands()
    local out = {}
    for _, b in ipairs(BARS) do
        for i = 1, b[3] do
            local f = _G[b[1] .. i]
            out[#out + 1] = f and type(f.commandName) == "string" and f.commandName or (b[2] .. i)
        end
    end
    for _, e in ipairs(extras) do out[#out + 1] = "CLICK " .. e.frame:GetName() .. ":LeftButton" end
    return out
end

-- The action slot a game action button shows now (paging, stances).
local function SlotOf(t)
    if t.kind ~= "action" then return nil end
    local f = t.frame
    local slot = f.action
    if (not slot or slot == 0) and f.CalculateAction then
        local ok, s = pcall(f.CalculateAction, f, "LeftButton")
        if ok then slot = s end
    end
    return (tonumber(slot) or 0) > 0 and slot or nil
end

-- What is on a button, in words (nil: nothing).
local function WhatIsOn(t)
    if t.kind == "action" then
        local slot = SlotOf(t)
        if not slot or not GetActionInfo then return nil end
        local kind, id = GetActionInfo(slot)
        if kind == "spell" and GetSpellInfo then return (GetSpellInfo(id)) end
        if kind == "macro" and GetMacroInfo then return (GetMacroInfo(id)) end
        local ItemInfo = C_Item and C_Item.GetItemInfo
        if kind == "item" and ItemInfo then return (ItemInfo(id)) end
        return nil
    elseif t.kind == "stance" and GetShapeshiftFormInfo then
        local _, _, _, spellId = GetShapeshiftFormInfo(t.index)
        return spellId and GetSpellInfo and (GetSpellInfo(spellId)) or nil
    elseif t.kind == "pet" and GetPetActionInfo then
        local name, _, isToken = GetPetActionInfo(t.index)
        if isToken and name and _G[name] then return _G[name] end
        return name
    end
    return nil
end

---------------------------------------------------------------------------
-- A binder: drawn over a button, it hears the keys, the mouse and the drag
---------------------------------------------------------------------------

local function Paint(bd)
    local now = Clock()
    local hot = hovered == bd
    local flash = bd.flashAt and max(0, 1 - (now - bd.flashAt) / FLASH_T) or 0
    local warn = bd.warnAt and max(0, 1 - (now - bd.warnAt) / WARN_T) or 0
    local bound = bd.keys and #bd.keys > 0
    -- the edge: rose while warned, gold under the mouse, deep gold when bound, faint when not
    local e = warn > 0 and { ROSE[1], ROSE[2], ROSE[3], 0.5 + 0.5 * warn }
        or hot and { GOLD[1], GOLD[2], GOLD[3], 1 } or bound and BOUND_EDGE or QUIET_EDGE
    UI:SetEdgeColor(bd, e[1], e[2], e[3], e[4])
    -- the fill: a breath of gold under the mouse, the flash on top
    local breathe = hot and (0.10 + 0.05 * sin(now * 5)) or 0
    local fa = breathe + 0.42 * flash
    if warn > 0 then
        bd.fill:SetColorTexture(ROSE[1], ROSE[2], ROSE[3], 0.3 * warn)
    else
        bd.fill:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], fa)
    end
    bd.glow:SetAlpha(hot and (0.55 + 0.2 * sin(now * 5)) or 0.6 * flash)
    -- the listening ring: a second edge just outside, breathing
    UI:SetEdgeColor(bd.ring, GOLD[1], GOLD[2], GOLD[3], hot and (0.25 + 0.2 * sin(now * 5 + 1.2)) or 0)
    -- the key cap pops in after a bind
    local pop = flash > 0 and (1 + 0.35 * flash * flash) or 1
    bd.cap:SetScale(pop)
    bd.animating = (hot or flash > 0 or warn > 0) and true or nil
end

-- The button's own key text steps back while the caps show (put back on close).
local hushed = {}
local function Hush(f)
    local hk = f and f.HotKey
    if hk and hushed[hk] == nil and hk.GetAlpha then
        hushed[hk] = hk:GetAlpha() or 1
        hk:SetAlpha(0)
    end
end
local function Unhush()
    for hk, a in pairs(hushed) do hk:SetAlpha(a) end
    for k in pairs(hushed) do hushed[k] = nil end
end

local function SetCap(bd, keys)
    bd.keys = keys
    local k = keys[1]
    if not k then bd.cap:Hide() return end
    bd.cap.fs:SetText(KB.Short(k) .. (keys[2] and (MOD_HEX .. " +" .. (#keys - 1) .. "|r") or ""))
    local w = bd.cap.fs:GetStringWidth() or 0
    if w <= 0 then w = #k * 6 end
    bd.cap:SetWidth(floor(w + 8.5))
    bd.cap:Show()
end

local function NewBinder()
    local bd = CreateFrame("Button", nil, overlay)
    bd:SetFrameLevel(overlay:GetFrameLevel() + 20)
    bd:EnableMouse(true)
    if bd.EnableMouseWheel then bd:EnableMouseWheel(true) end
    bd:RegisterForDrag("LeftButton")
    bd.glow = bd:CreateTexture(nil, "BACKGROUND")
    bd.glow:SetTexture(RADIAL)
    bd.glow:SetBlendMode("ADD")
    bd.glow:SetVertexColor(GOLD_DEEP[1], GOLD_DEEP[2], GOLD_DEEP[3])
    bd.glow:SetPoint("TOPLEFT", -14, 14)
    bd.glow:SetPoint("BOTTOMRIGHT", 14, -14)
    bd.glow:SetAlpha(0)
    bd.fill = bd:CreateTexture(nil, "ARTWORK")
    bd.fill:SetAllPoints()
    bd.fill:SetColorTexture(0, 0, 0, 0)
    UI:AddEdges(bd, "OVERLAY")
    bd.ring = CreateFrame("Frame", nil, bd)
    bd.ring:SetPoint("TOPLEFT", -3, 3)
    bd.ring:SetPoint("BOTTOMRIGHT", 3, -3)
    UI:AddEdges(bd.ring, "OVERLAY")
    -- the key cap: a small dark plate under the button's bottom edge
    local cap = CreateFrame("Frame", nil, bd)
    cap:SetFrameLevel(bd:GetFrameLevel() + 3)
    cap:SetHeight(13)
    cap:SetPoint("BOTTOM", bd, "BOTTOM", 0, 2)
    cap.bg = cap:CreateTexture(nil, "BACKGROUND")
    cap.bg:SetAllPoints()
    UI:Gradient(cap.bg, "VERTICAL", S:WithAlpha("INSET", 0.96), S:WithAlpha("CARD", 0.96))
    UI:AddEdges(cap, "BORDER", true)
    UI:SetEdgeColor(cap, GOLD_DEEP[1], GOLD_DEEP[2], GOLD_DEEP[3], 0.55)
    cap.fs = UI:Text(cap, "small", GOLD, { shadow = false, font = S.FONT_NUM })
    UI:SetTextSize(cap.fs, 11)
    cap.fs:SetPoint("CENTER", 0, 0)
    cap:Hide()
    bd.cap = cap
    bd:SetScript("OnEnter", function(self)
        hovered = self
        KB:UpdateBar()
        Paint(self)
    end)
    bd:SetScript("OnLeave", function(self)
        if hovered == self then hovered = nil end
        KB:UpdateBar()
        Paint(self)
    end)
    bd:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then KB:Clear(self.t) return end
        if button == "LeftButton" then return end
        local k = MOUSE[button] or (button and button:match("^Button%d+$") and button:upper())
        if k then KB:Bind(self.t, Chord(k)) end
    end)
    bd:SetScript("OnMouseUp", function(self, button)
        -- an ability on the cursor drops here (a click, or a drag let go over the button)
        if button == "LeftButton" and GetCursorInfo and GetCursorInfo() then KB:Drop(self.t) end
    end)
    bd:SetScript("OnReceiveDrag", function(self) KB:Drop(self.t) end)
    bd:SetScript("OnDragStart", function(self) KB:PickUp(self.t) end)
    bd:SetScript("OnMouseWheel", function(self, delta)
        KB:Bind(self.t, Chord(delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN"))
    end)
    return bd
end

-- The binders follow the buttons on the screen (a page turned, a bar shown or hidden, a look changed).
function KB:Scan()
    if not overlay then return end
    local seen = {}
    for _, t in ipairs(self:Targets()) do
        local f = t.frame
        local visible = f.IsVisible and f:IsVisible() and (not f.GetEffectiveAlpha or f:GetEffectiveAlpha() > 0.05)
        if visible then
            local bd = binders[f]
            if not bd then
                bd = NewBinder()
                binders[f] = bd
                bd:SetAllPoints(f)
            end
            bd.t = t
            Hush(f)
            SetCap(bd, self:Keys(t.cmd))
            bd:Show()
            Paint(bd)
            seen[f] = true
        end
    end
    for f, bd in pairs(binders) do
        if not seen[f] then
            bd:Hide()
            if hovered == bd then hovered = nil end
        end
    end
end

function KB:Binder(frame) return binders[frame] end
function KB:Hovered() return hovered end

---------------------------------------------------------------------------
-- Binding
---------------------------------------------------------------------------

local function Push(changes)
    undo[#undo + 1] = changes
    for k in pairs(redo) do redo[k] = nil end
end

local function BinderOfCmd(cmd)
    for _, bd in pairs(binders) do
        if bd:IsShown() and bd.t and bd.t.cmd == cmd then return bd end
    end
end

-- Puts key on the button (its old keys come off: one press, one key). A key that ran something else moves here.
function KB:Bind(t, key)
    if not active or not t or not key then return false end
    local base = key:match("([^%-]+)$") or key
    if IGNORED[base] then return false end
    if not demoKeys and InCombat() then return false end
    local was = self:ActionOf(key)
    local mine = self:Keys(t.cmd)
    if was == t.cmd and #mine == 1 then
        local bd = binders[t.frame]
        if bd then bd.flashAt = Clock(); Paint(bd) end
        return true
    end
    local changes = { { key, was, t.cmd } }
    for _, k in ipairs(mine) do
        if k ~= key then changes[#changes + 1] = { k, t.cmd, nil } end
    end
    -- (the new key first: Apply undoes in reverse, so the old keys come back before the moved key goes home)
    Apply(changes)
    Push(changes)
    local bd = binders[t.frame]
    if bd then bd.flashAt = Clock() end
    if was and was ~= t.cmd then
        local from = BinderOfCmd(was)
        if from then from.warnAt = Clock() end
        local label = from and from.t.label or (GetBindingName and GetBindingName(was)) or was
        self:Note(("%s moved here from %s"):format(Words(key), label))
    else
        self:Note(nil)
    end
    self:Scan()
    self:UpdateBar()
    if PlaySound and SOUNDKIT and SOUNDKIT.U_CHAT_SCROLL_BUTTON then PlaySound(SOUNDKIT.U_CHAT_SCROLL_BUTTON) end
    return true
end

-- Takes every key off the button.
function KB:Clear(t)
    if not active or not t then return false end
    if not demoKeys and InCombat() then return false end
    local mine = self:Keys(t.cmd)
    if #mine == 0 then return false end
    local changes = {}
    for _, k in ipairs(mine) do changes[#changes + 1] = { k, t.cmd, nil } end
    Apply(changes)
    Push(changes)
    local bd = binders[t.frame]
    if bd then bd.warnAt = Clock() end
    self:Note(#mine == 1 and (Words(mine[1]) .. " cleared") or (#mine .. " keys cleared"))
    self:Scan()
    self:UpdateBar()
    return true
end

function KB:Undo()
    local c = tremove(undo)
    if not c then return end
    Apply(c, true)
    redo[#redo + 1] = c
    self:Note(nil)
    self:Scan()
    self:UpdateBar()
end

function KB:Redo()
    local c = tremove(redo)
    if not c then return end
    Apply(c)
    undo[#undo + 1] = c
    self:Scan()
    self:UpdateBar()
end

-- An ability onto a game action button: placed with PlaceAction (the old one comes onto the cursor, as a drag does).
function KB:Drop(t)
    if not active or demoKeys or InCombat() or not t then return false end
    local slot = SlotOf(t)
    if not slot or not PlaceAction or not (GetCursorInfo and GetCursorInfo()) then return false end
    PlaceAction(slot)
    local bd = binders[t.frame]
    if bd then bd.flashAt = Clock(); Paint(bd) end
    self:UpdateBar()
    return true
end

function KB:PickUp(t)
    if not active or demoKeys or InCombat() or not t then return false end
    local slot = SlotOf(t)
    if not slot or not PickupAction or (HasAction and not HasAction(slot)) then return false end
    PickupAction(slot)
    self:UpdateBar()
    return true
end

-- Keys pressed while the mode is open: true when it took the key (else it goes on to the game).
function KB:OnKey(key)
    if not key or IGNORED[key] then return false end
    if key == "PRINTSCREEN" then return false end
    if hovered and hovered:IsShown() then
        if key == "ESCAPE" then self:Clear(hovered.t) return true end
        self:Bind(hovered.t, Chord(key))
        return true
    end
    if key == "ESCAPE" then self:Close(true) return true end
    if IsControlKeyDown and IsControlKeyDown() and key == "Z" then
        if IsShiftKeyDown() then self:Redo() else self:Undo() end
        return true
    end
    if IsControlKeyDown and IsControlKeyDown() and key == "Y" then self:Redo() return true end
    if key == "ENTER" then self:Close(true) return true end
    return true
end

---------------------------------------------------------------------------
-- The bar and the note
---------------------------------------------------------------------------

function KB:Readout()
    local bd = hovered
    if not (bd and bd:IsShown() and bd.t) then
        return "|cffd9d1bfPoint at a button and press a key|r   |cff6f6a62\194\183   right-click clears   \194\183   "
            .. "drag an ability to swap|r"
    end
    local t = bd.t
    local what = WhatIsOn(t)
    local keys = self:Keys(t.cmd)
    local ks = {}
    for i, k in ipairs(keys) do ks[i] = Words(k) end
    local out = "|cffffffff" .. t.label .. "|r"
    if what then out = out .. "   |cffd9d1bf" .. what .. "|r" end
    out = out .. "   |cff6f6a62\194\183|r   " .. (#ks > 0 and ("|cffffd100" .. table.concat(ks, ", ") .. "|r")
        or "|cff8a857cNo key: press one|r")
    return out
end

function KB:UpdateBar()
    if not bar then return end
    local B = bar.b
    local x = 10
    local nSep = 0
    local function add(c, gap)
        c:ClearAllPoints()
        c:SetPoint("LEFT", bar, "LEFT", x, 0)
        c:Show()
        x = x + c:GetWidth() + (gap or 1)
    end
    local function sep()
        nSep = nSep + 1
        local s = bar.seps[nSep]
        if not s then
            s = bar:CreateTexture(nil, "ARTWORK")
            s:SetSize(1, 16)
            s:SetColorTexture(0.17, 0.17, 0.2, 1)
            bar.seps[nSep] = s
        end
        x = x + 4
        s:ClearAllPoints()
        s:SetPoint("LEFT", bar, "LEFT", x, 0)
        s:Show()
        x = x + 5
    end
    bar.title:ClearAllPoints()
    bar.title:SetPoint("LEFT", bar, "LEFT", x, 0)
    x = x + floor((bar.title:GetStringWidth() or 56) + 0.5) + 8
    if demoKeys then
        bar.demo:ClearAllPoints()
        bar.demo:SetPoint("LEFT", bar, "LEFT", x, 0)
        bar.demo:Show()
        x = x + bar.demo:GetWidth() + 8
    else
        bar.demo:Hide()
    end
    -- the readout keeps the widest it has been while open (the buttons after it don't jump from button to button)
    bar.read:SetWidth(0)
    bar.read:SetText(self:Readout())
    local rw = floor((bar.read:GetStringWidth() or 300) + 0.5)
    if rw <= 0 then rw = 300 end
    rw = max(rw, bar.readW or 0)
    bar.readW = rw
    bar.read:SetWidth(rw + 2)
    bar.read:ClearAllPoints()
    bar.read:SetPoint("LEFT", bar, "LEFT", x, 0)
    x = x + rw + 8
    sep()
    if ns.ProfilesUI then
        B.profile:SetLabel("|cffffd100" .. ns.ProfilesUI:InUseName() .. "|r")
        add(B.profile)
    end
    B.char:SetLit(targetSet == 2)
    B.char:SetEnabled(not demoKeys)
    add(B.char)
    sep()
    B.undo:SetEnabled(#undo > 0); B.redo:SetEnabled(#redo > 0)
    B.undo:Paint(); B.redo:Paint()
    add(B.undo); add(B.redo)
    sep()
    B.discard:SetEnabled(dirty)
    B.discard:Paint()
    add(B.discard, 4)
    add(B.done, 0)
    for i = nSep + 1, #bar.seps do bar.seps[i]:Hide() end
    bar:SetWidth(x + 4)
end

-- A line under the bar for a while (nil: gone).
function KB:Note(text)
    if not note then return end
    if not text then note:Hide() return end
    note.fs:SetText(text)
    local w = note.fs:GetStringWidth() or 0
    if w <= 0 then w = #text * 6 end
    note:SetWidth(floor(w + 24.5))
    note:SetAlpha(1)
    note:Show()
    noteUntil = Clock() + NOTE_T
end
function KB:NoteText() return note and note:IsShown() and note.fs:GetText() or nil end

---------------------------------------------------------------------------
-- The overlay
---------------------------------------------------------------------------

-- The vignette: soft gradients from the screen's top and sides, the middle and the bottom (the bars) clear.
local function Vignette(f)
    local function side(p1, p2, horiz, size, dir)
        local t = f:CreateTexture(nil, "BACKGROUND")
        t:SetPoint(p1); t:SetPoint(p2)
        if horiz then t:SetHeight(size) else t:SetWidth(size) end
        if dir == "up" then
            UI:GradientRGBA(t, "VERTICAL", 0, 0, 0, 0.55, 0, 0, 0, 0)
        elseif dir == "down" then
            UI:GradientRGBA(t, "VERTICAL", 0, 0, 0, 0, 0, 0, 0, 0.5)
        elseif dir == "right" then
            UI:GradientRGBA(t, "HORIZONTAL", 0, 0, 0, 0.45, 0, 0, 0, 0)
        else
            UI:GradientRGBA(t, "HORIZONTAL", 0, 0, 0, 0, 0, 0, 0, 0.45)
        end
        return t
    end
    -- (none along the bottom: the bars sit there)
    f.vigT = side("TOPLEFT", "TOPRIGHT", true, 200, "down")
    f.vigL = side("TOPLEFT", "BOTTOMLEFT", false, 320, "right")
    f.vigR = side("TOPRIGHT", "BOTTOMRIGHT", false, 320, "left")
    f.dim = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    f.dim:SetAllPoints()
    f.dim:SetColorTexture(0, 0, 0, 0.12)
end

local function BuildBar(K)
    bar = K.TopBar(overlay, "DisasterZoneKeyBindsBar", "Key binds")
    bar.read = UI:Text(bar, "small", { 0.6, 0.58, 0.54 }, { shadow = false })
    bar.seps = {}
    bar.demo = CreateFrame("Frame", nil, bar)
    bar.demo:SetSize(38, 16)
    bar.demo.bg = bar.demo:CreateTexture(nil, "BACKGROUND")
    bar.demo.bg:SetAllPoints()
    bar.demo.bg:SetColorTexture(S:Alpha("YOU", 0.18))
    bar.demo.fs = UI:Text(bar.demo, "small", "YOU", { shadow = false, text = "Demo" })
    bar.demo.fs:SetPoint("CENTER")
    UI:AttachTooltip(bar.demo, "Demo mode", { "Made-up keys: nothing is bound or saved." }, { anchor = "ANCHOR_BOTTOM" })
    local B = {}
    B.char = K.Button(bar, "This character", function() KB:ToggleCharacter() end, "Keys for this character",
        "On: the keys you set here are for this character only. Off: every character of the account shares them.")
    B.undo = K.Icon(bar, 9, "Undo", "Ctrl+Z", function() KB:Undo() end)
    B.redo = K.Icon(bar, 10, "Redo", "Ctrl+Y", function() KB:Redo() end)
    B.profile = K.Button(bar, "Profile", function(b)
        if ns.ProfilesUI then UI:ContextMenu(b, function(root) ns.ProfilesUI:FillMenu(root) end) end
    end, "Profile", "The keys you set here save into this profile. Switch to another or start a new one.", true)
    B.discard = K.Button(bar, "Discard", function() KB:Close(false) end, "Discard",
        "Every key back as it was when you opened Key binds.")
    B.done = UI:CreateSleekButton(bar, "Done", 54, 22, function() KB:Close(true) end, "primary")
    UI:SetTextSize(B.done:GetFontString(), "small")
    UI:AttachTooltip(B.done, "Done", { "Saves the keys. Esc or Enter too (Esc over a button clears its key)." },
        { anchor = "ANCHOR_BOTTOM" })
    for _, b in pairs(B) do b:Hide() end
    bar.b = B
    note = CreateFrame("Frame", nil, overlay)
    note:SetFrameLevel(overlay:GetFrameLevel() + 105)
    note:SetHeight(18)
    note:SetPoint("TOP", bar, "BOTTOM", 0, -6)
    note.bg = note:CreateTexture(nil, "BACKGROUND")
    note.bg:SetAllPoints()
    note.bg:SetColorTexture(S:Alpha("GOLD", 0.95))
    note.fs = UI:Text(note, "small", "TEXT", { shadow = false })
    note.fs:SetTextColor(0.08, 0.08, 0.08)
    note.fs:SetPoint("CENTER", 0, 0)
    note:Hide()
end

local function BuildOverlay()
    local K = Kit()
    overlay = CreateFrame("Frame", "DisasterZoneKeyBinds", UIParent)
    overlay:SetAllPoints(UIParent)
    overlay:SetFrameStrata("FULLSCREEN")
    overlay:SetFrameLevel(1)
    -- (the mouse goes through to the world: only the binders and the bar take it)
    overlay:EnableMouse(false)
    overlay:EnableKeyboard(true)
    Vignette(overlay)
    overlay:SetScript("OnKeyDown", function(self, key)
        local handled = KB:OnKey(key)
        if not InCombat() then self:SetPropagateKeyboardInput(not handled) end
    end)
    local since = 0
    overlay:SetScript("OnUpdate", function(_, elapsed)
        for _, bd in pairs(binders) do if bd.animating and bd:IsShown() then Paint(bd) end end
        if note:IsShown() then
            local left = noteUntil - Clock()
            if left <= 0 then note:Hide() elseif left < 0.4 then note:SetAlpha(left / 0.4) end
        end
        since = since + (elapsed or 0)
        if since > 0.5 then since = 0; KB:Scan() end
    end)
    BuildBar(K)
    overlay:Hide()
end

---------------------------------------------------------------------------
-- Demo keys: the usual layout of a player's keys, over every button
---------------------------------------------------------------------------

local DEMO_ROWS = {
    ACTIONBUTTON = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=" },
    MULTIACTIONBAR1BUTTON = { "SHIFT-1", "SHIFT-2", "SHIFT-3", "SHIFT-4", "SHIFT-5", "Q", "E", "R", "F", "G", "T",
        "SHIFT-Q" },
    MULTIACTIONBAR2BUTTON = { "CTRL-1", "CTRL-2", "CTRL-3", "Z", "X", "C", "V", "ALT-Q", "ALT-E", "MOUSEWHEELUP",
        "MOUSEWHEELDOWN", "BUTTON4" },
    SHAPESHIFTBUTTON = { "ALT-1", "ALT-2", "ALT-3" },
}

local function DemoSeed()
    local keys = {}
    for _, t in ipairs(KB:Targets()) do
        local prefix, i = t.cmd:match("^(%u+%d?BUTTON)(%d+)$")
        local row = prefix and DEMO_ROWS[prefix]
        local k = row and row[tonumber(i)]
        if k then keys[t.cmd] = { k } end
    end
    return keys
end

---------------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------------

function KB:Open()
    if active then return true end
    if InCombat() then
        ns:Print("Key binds opens after the fight (the game doesn't let keys change in combat).")
        return false
    end
    if not Kit() then return false end
    if ns.EditMode and ns.EditMode:IsActive() then ns.EditMode:Close() end
    if not overlay then BuildOverlay() end
    active = true
    hovered = nil
    dirty = false
    for k in pairs(undo) do undo[k] = nil end
    for k in pairs(redo) do redo[k] = nil end
    demoKeys = Demo() and DemoSeed() or nil
    targetSet = GetCurrentBindingSet and GetCurrentBindingSet() or 1
    if ns.UI.CloseMenus then ns.UI:CloseMenus() end
    -- the DisasterZone window steps aside, as it does for Edit layout, and comes back after
    local mf = ns.MainFrame
    self.windowPage = nil
    if mf and mf.IsShown and mf:IsShown() then
        self.windowPage = mf:GetSelectedTab() or "home"
        mf:Close()
    end
    if GameTooltip then GameTooltip:Hide() end
    bar.readW = nil
    note:Hide()
    overlay:SetAlpha(0)
    overlay:Show()
    UI:Tween(overlay, 0.18, function(e) overlay:SetAlpha(e) end)
    self:Scan()
    self:UpdateBar()
    ns:Fire("KEY_BINDS", true)
    return true
end

-- Closes it: save = keep the keys (saved in the binding set), else every key back as it was.
function KB:Close(save)
    if not active then return end
    if save == false and #undo > 0 then
        while #undo > 0 do
            local c = tremove(undo)
            Apply(c, true)
        end
    elseif save ~= false and dirty and not demoKeys and SaveBindings then
        pcall(SaveBindings, targetSet or 1)
    end
    active = false
    hovered = nil
    demoKeys = nil
    dirty = false
    for k in pairs(undo) do undo[k] = nil end
    for k in pairs(redo) do redo[k] = nil end
    if overlay then
        note:Hide()
        overlay:Hide()
    end
    Unhush()
    if GameTooltip then GameTooltip:Hide() end
    ns:Fire("KEY_BINDS", false)
    local page = self.windowPage
    self.windowPage = nil
    if page and not InCombat() and ns.MainFrame and not ns.MainFrame:IsShown() then ns.MainFrame:Open(page) end
end

function KB:Toggle()
    if active then self:Close(true) else self:Open() end
end

-- This character: on, Done saves the keys in this character's own set; off (from this character's set), the
-- account's keys come back (asked first: this character's own keys are dropped).
function KB:ToggleCharacter()
    if not active or demoKeys then return end
    if targetSet ~= 2 then
        targetSet = 2
        dirty = true
        self:Note("Saved for this character when you press Done")
        self:UpdateBar()
        return
    end
    local current = GetCurrentBindingSet and GetCurrentBindingSet() or 1
    if current ~= 2 then
        targetSet = 1
        self:UpdateBar()
        return
    end
    ns.Popup:Confirm({ title = "Use the account's keys?", key = "KEYBINDS_ACCOUNT",
        text = "This character's own keys are dropped and every character shares the account's keys again.",
        ok = "Use the account's", onAccept = function()
            if InCombat() then return end
            if LoadBindings then LoadBindings(1) end
            if SaveBindings then SaveBindings(1) end
            targetSet = 1
            dirty = false
            for k in pairs(undo) do undo[k] = nil end
            for k in pairs(redo) do redo[k] = nil end
            KB:Scan()
            KB:UpdateBar()
        end })
end
function KB:TargetSet() return targetSet end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- The key a spell is on (the timers' next presses wear it, UI/RingFace.lua)
---------------------------------------------------------------------------

-- Binding commands of bar buttons: the action slot of button n ("page" = the main bar: its page, or the stance bar
-- a warrior / druid / rogue form swaps in).
local SLOT_CMD = {
    { "^ACTIONBUTTON(%d+)$", "page" }, { "^MULTIACTIONBAR1BUTTON(%d+)$", 60 }, { "^MULTIACTIONBAR2BUTTON(%d+)$", 48 },
    { "^MULTIACTIONBAR3BUTTON(%d+)$", 24 }, { "^MULTIACTIONBAR4BUTTON(%d+)$", 36 },
    { "^CLICK BT4Button(%d+):", 0 }, { "^CLICK DominosActionButton(%d+):", 0 }, { "^CLICK ElvUI_Bar1Button(%d+):", 0 },
}
local spellKeys                     -- { [spell name] = short key } until the bars or the bindings change

-- The spell on an action slot (a macro's spell too), by name.
local function SlotSpellName(slot)
    if not GetActionInfo then return nil end
    local kind, id = GetActionInfo(slot)
    if kind == "spell" and id then return GetSpellInfo(id) end
    if kind == "macro" and id and GetMacroSpell then
        local r = GetMacroSpell(id)
        if type(r) == "number" then r = GetSpellInfo(r) end
        return r
    end
    return nil
end

local function MainSlot(n)
    local bonus = GetBonusBarOffset and GetBonusBarOffset() or 0
    if bonus > 0 and (not GetActionBarPage or GetActionBarPage() == 1) then return 72 + (bonus - 1) * 12 + n end
    return ((GetActionBarPage and GetActionBarPage() or 1) - 1) * 12 + n
end

-- A key as an action button writes it: "S-E", "C-2", "A-Q", "M4", "WU", "N5".
function KB.ShortKey(key)
    if type(key) ~= "string" or key == "" then return nil end
    local mods, base
    if key:sub(-1) == "-" then mods, base = key:sub(1, -2), "-"      -- (the minus key: "SHIFT--")
    else mods, base = key:match("^(.-)([^%-]+)$") end
    if not base then return key end
    local m = (mods or ""):gsub("ALT%-", "A-"):gsub("CTRL%-", "C-"):gsub("SHIFT%-", "S-"):gsub("META%-", "M-")
    base = base:gsub("^NUMPAD", "N"):gsub("MOUSEWHEELUP", "WU"):gsub("MOUSEWHEELDOWN", "WD"):gsub("^BUTTON", "M")
        :gsub("^MIDDLEBUTTON$", "M3"):gsub("SPACE", "Spc"):gsub("BACKSPACE", "Bks"):gsub("CAPSLOCK", "Caps")
        :gsub("PAGEUP", "PgU"):gsub("PAGEDOWN", "PgD"):gsub("INSERT", "Ins"):gsub("DELETE", "Del"):gsub("HOME", "Hm")
        :gsub("ENTER", "Ent")
    return m .. base
end

-- The short key of the first binding that presses this spell (a bar button holding it, a SPELL or MACRO binding),
-- or nil when it is on no bound button.
function KB:KeyForSpell(name)
    if not name then return nil end
    if not spellKeys then
        spellKeys = {}
        if GetNumBindings and GetBinding then
            for i = 1, GetNumBindings() do
                local cmd, _, k1, k2 = GetBinding(i)
                local key = k1 or k2
                if type(cmd) == "string" and key then
                    local spell
                    for _, b in ipairs(SLOT_CMD) do
                        local n = tonumber(cmd:match(b[1]))
                        if n then
                            spell = SlotSpellName(b[2] == "page" and MainSlot(n) or (b[2] + n))
                            break
                        end
                    end
                    if not spell then
                        spell = cmd:match("^SPELL (.+)$")
                        local mname = cmd:match("^MACRO (.+)$")
                        if mname and GetMacroIndexByName and GetMacroSpell then
                            local r = GetMacroSpell(GetMacroIndexByName(mname))
                            spell = type(r) == "number" and GetSpellInfo(r) or r
                        end
                    end
                    if spell and not spellKeys[spell] then spellKeys[spell] = KB.ShortKey(key) end
                end
            end
        end
    end
    return spellKeys[name]
end

function KB:ForgetSpellKeys() spellKeys = nil end

function KB:OnLogin()
    for _, e in ipairs({ "UPDATE_BINDINGS", "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR",
                         "UPDATE_SHAPESHIFT_FORM", "UPDATE_MACROS", "LEARNED_SPELL_IN_TAB" }) do
        ns:RegisterEvent(e, function() spellKeys = nil end)
    end
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if active then
            KB:Close(true)
            ns:Print("Key binds closed for the fight. Your keys are kept.")
        end
    end)
    ns:On("DEMO_TOGGLED", function()
        if active then KB:Close(false); KB:Open() end
    end)
    -- (another profile put on while binding: its keys are the ones now; what was undone before is gone)
    ns:On("PROFILE_CHANGED", function()
        if not active then return end
        for k in pairs(undo) do undo[k] = nil end
        for k in pairs(redo) do redo[k] = nil end
        dirty = false
        KB:Scan()
        KB:UpdateBar()
    end)
end

ns:RegisterSlash("keys", function() KB:Toggle() end,
    "bind keys: point at any action button and press a key (Key binds)")

BINDING_NAME_DISASTERZONE_KEYBINDS = "Key binds (point at a button, press a key)"
function DisasterZone_ToggleKeyBinds() KB:Toggle() end
