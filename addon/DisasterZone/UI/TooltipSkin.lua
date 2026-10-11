if DisasterZoneBoot and DisasterZoneBoot.Run("UI/TooltipSkin.lua", ...) then return end -- DisasterZone: UI/TooltipSkin.lua
-- The addon's tooltip look. Every tooltip the addon opens (GameTooltip owned through our code, plus the compare
-- tooltips beside it) wears the dropdowns' panel (S.C.DROP_BG with its 1px S.C.DROP_EDGE) instead of Blizzard's frame,
-- and fades in and out like a drop does (UI.DROP_TIME). A refresh (shown again at once for the same owner) does not
-- fade. Tooltips other addons or Blizzard open stay as they are.
local addonName, ns = ...

local UI = ns.UI
local S = ns.Style
local GameTooltip = GameTooltip
local GetTime = GetTime

-- Is the code that called SetOwner ours? (owner frames are mostly unnamed, so the call site tells.)
local function CalledFromUs()
    if not debugstack then return false end
    local s = debugstack(3, 6, 0) or ""
    return s:find("AddOns[/\\]" .. addonName .. "[/\\]") ~= nil
end

local function Build(tt)
    if tt.dzTip then return tt.dzTip end
    local k = { edges = {} }
    k.bg = UI:Fill(tt, "DROP_BG", "BACKGROUND", -8)
    for i, pts in ipairs({ { "TOPLEFT", "TOPRIGHT", "h" }, { "BOTTOMLEFT", "BOTTOMRIGHT", "h" },
                           { "TOPLEFT", "BOTTOMLEFT", "v" }, { "TOPRIGHT", "BOTTOMRIGHT", "v" } }) do
        local e = tt:CreateTexture(nil, "BACKGROUND", nil, 5)
        e:SetColorTexture(S:Color("DROP_EDGE"))
        e:SetPoint(pts[1]); e:SetPoint(pts[2])
        if pts[3] == "h" then e:SetHeight(1) else e:SetWidth(1) end
        k.edges[i] = e
    end
    tt.dzTip = k
    return k
end

local function SetSkin(tt, on)
    local k = on and Build(tt) or tt.dzTip
    if not k or k.on == on then return end
    k.on = on
    k.bg:SetShown(on)
    for _, e in ipairs(k.edges) do e:SetShown(on) end
    if tt.NineSlice then tt.NineSlice:SetAlpha(on and 0 or 1) end
    if tt.backdropInfo and tt.SetBackdropColor and not tt.NineSlice then
        if on then
            k.bd = { tt:GetBackdropColor() }
            k.bde = tt.GetBackdropBorderColor and { tt:GetBackdropBorderColor() }
            tt:SetBackdropColor(0, 0, 0, 0)
            if tt.SetBackdropBorderColor then tt:SetBackdropBorderColor(0, 0, 0, 0) end
        else
            if k.bd and k.bd[1] then tt:SetBackdropColor(unpack(k.bd)) end
            if k.bde and k.bde[1] then tt:SetBackdropBorderColor(unpack(k.bde)) end
        end
    end
    if not on then tt:SetAlpha(1) end
end

-- the fade -----------------------------------------------------------------------------------------------------------
-- In: an Alpha animation on the tooltip (it plays on top of whatever alpha the tooltip sets itself). Out: the game hides
-- a tooltip at once, so a ghost copy of it (same lines, same place, same skin) fades away where it was.
local SAME_OWNER = 0.1   -- shown again for the same owner this soon (a refresh): no fade either way

local function FadeAnim(f, from, to, onDone)
    local ag = f:CreateAnimationGroup()
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(from)
    a:SetToAlpha(to)
    a:SetDuration(UI.DROP_TIME or 0.14)
    if a.SetSmoothing then a:SetSmoothing(to > from and "OUT" or "IN") end
    if onDone then ag:SetScript("OnFinished", onDone) end
    return ag
end

local ghost
local function Ghost()
    if ghost then return ghost end
    ghost = CreateFrame("GameTooltip", "DisasterZoneTooltipGhost", UIParent, "GameTooltipTemplate")
    ghost:SetFrameStrata("TOOLTIP")
    if ghost.EnableMouse then ghost:EnableMouse(false) end
    ghost.dzOut = FadeAnim(ghost, 1, 0, function() ghost:Hide() end)
    return ghost
end

local function FadeOut(tt)
    local name = tt.GetName and tt:GetName()
    local l, t = tt:GetLeft(), tt:GetTop()
    if not (name and l and t and tt.NumLines and tt:NumLines() > 0) then return end
    local g = Ghost()
    g.dzOut:Stop()
    g:SetOwner(UIParent, "ANCHOR_NONE")
    g:ClearLines()
    for i = 1, tt:NumLines() do
        local L, R = _G[name .. "TextLeft" .. i], _G[name .. "TextRight" .. i]
        local lt = L and L:IsShown() and L:GetText()
        local rt = R and R:IsShown() and R:GetText()
        local lr, lg, lb = 1, 1, 1
        if L then lr, lg, lb = L:GetTextColor() end
        if rt then
            local rr, rg, rb = R:GetTextColor()
            g:AddDoubleLine(lt or " ", rt, lr, lg, lb, rr, rg, rb)
        else
            g:AddLine(lt or " ", lr, lg, lb, true)
        end
    end
    g:SetScale(tt:GetScale())
    if g.SetMinimumWidth then g:SetMinimumWidth(math.max(0, (tt:GetWidth() or 0) - 20)) end
    g:Show()
    g:ClearAllPoints()
    g:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
    SetSkin(g, true)
    g.dzOut:Play()
end

local function OnShow(tt)
    local want = tt.dzWant
    if tt ~= GameTooltip then   -- the compare tooltips follow the tooltip they sit beside
        want = GameTooltip and GameTooltip.dzWant and GameTooltip:IsShown()
    end
    SetSkin(tt, want and true or false)
    if not want then return end
    tt:SetAlpha(1)
    local refresh = tt.dzHidAt and GetTime() - tt.dzHidAt < SAME_OWNER and tt.dzLastOwner == tt:GetOwner()
    if refresh then
        if tt == GameTooltip and ghost and ghost:IsShown() then ghost.dzOut:Stop(); ghost:Hide() end
        return
    end
    tt.dzIn = tt.dzIn or FadeAnim(tt, 0, 1)
    tt.dzIn:Stop()
    tt.dzIn:Play()
end

local function OnHide(tt)
    if tt.dzIn then tt.dzIn:Stop() end
    tt.dzHidAt = GetTime()
    tt.dzLastOwner = tt.GetOwner and tt:GetOwner()
    if tt == GameTooltip and tt.dzTip and tt.dzTip.on then FadeOut(tt) end
end

local function OnSetOwner(tt) tt.dzWant = CalledFromUs() end

if GameTooltip and GameTooltip.HookScript then
    if hooksecurefunc then hooksecurefunc(GameTooltip, "SetOwner", OnSetOwner) end
    for _, tt in ipairs({ GameTooltip, _G.ShoppingTooltip1, _G.ShoppingTooltip2 }) do
        if tt and tt.HookScript then
            tt:HookScript("OnShow", OnShow)
            tt:HookScript("OnHide", OnHide)
        end
    end
end
