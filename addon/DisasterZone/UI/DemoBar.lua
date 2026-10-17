if DisasterZoneBoot and DisasterZoneBoot.Run("UI/DemoBar.lua", ...) then return end -- DisasterZone UI/DemoBar.lua
-- The demo bar (the Demo picker, Core/DemoParts.lua; mockup claude.ai/artifact/TDAHyoxc54tzx3zTcFDHzn): a slim strip at
-- the top of the screen while a demo part or moment plays. "DEMO", a chip per part playing (a click stops that one),
-- the moment playing, the one pull's countdown, Again, Stop and the Demo page. Hidden while nothing plays (the demo
-- guild alone stays quiet: the window's status line says it). Edit layout moves it (id "demobar").
local addonName, ns = ...

local DemoBar = ns:NewModule("DemoBar")
local UI, S = ns.UI, ns.Style

local floor, max, min = math.floor, math.max, math.min
local ipairs, format = ipairs, string.format

local H, MAX_CHIPS, GAP = 30, 5, 6
local bar

local function D() return ns.Demo end

local function Tip(frame, title, text)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(title, S:RGB("GOLD"))
        if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Build()
    if bar then return bar end
    bar = UI:CreateHudFrame("DisasterZoneDemoBar", { width = 300, height = H, position = false, layout = "demobar",
        look = "card", strata = "MEDIUM", default = { "TOP", UIParent, "TOP", 0, -8 } })
    bar.tag = UI:Text(bar, "caps", "GOLD")
    bar.tag:SetPoint("LEFT", bar, "LEFT", 10, 0)
    bar.tag:SetText("DEMO")
    bar.chips = {}
    for i = 1, MAX_CHIPS + 1 do
        local chip = UI:CreateChip(bar, { kind = "plain", text = "", onClick = function(self)
            if self.more then D():OpenPage() return end
            if self.moment then D():StopMoment() return end
            if self.key then D():SetOn(self.key, false) end
        end })
        chip:Hide()
        Tip(chip, "Stop it", "Takes just this one off the screen. The Demo page (/dz demo) has the rest.")
        bar.chips[i] = chip
    end
    bar.time = UI:Text(bar, "small", "TEXT")
    bar.track = UI:CreateProgressBar(bar, { width = 54, height = 3, color = "GOLD", track = "HAIRLINE" })
    bar.again = ns.UI:CreateSleekButton(bar, "Again", 58, 20, function() D():StartPull() end)
    Tip(bar.again, "Play the pull again", "The combat parts play their made-up pull from the start.")
    bar.stop = ns.UI:CreateSleekButton(bar, "Stop", 50, 20, function() D():StopAll(true) end)
    Tip(bar.stop, "Stop all", "Every demo part and moment off, and the demo guild too. Your picks are kept.")
    bar.page = UI:CreateTipIconButton(bar, 20, UI.ICON.gear, "The Demo page", "Pick what plays: Settings > Help > Demo mode.",
        function() D():OpenPage() end)
    bar:SetScript("OnUpdate", function(f, el)
        f.acc = (f.acc or 0) + el
        if f.acc < 0.25 then return end
        f.acc = 0
        DemoBar:PaintTime()
    end)
    bar:Hide()
    return bar
end

-- The countdown: the one pull's seconds left, "Loop", or the moment's. force: while it is laid out (not shown yet).
function DemoBar:PaintTime(force)
    if not (bar and (force or bar:IsShown())) then return end
    local Dm = D()
    local text, frac
    if Dm:AnyPull() then
        if Dm:IsLooping() then
            text = "Loop"
        else
            local left = Dm:PullLeft()
            if left and left > 0 then
                text = format("One pull 0:%02d", floor(Dm.PULL - left + 0.5))
                frac = 1 - left / Dm.PULL
            else
                text, frac = S:Wrap("GOLD", "Pull over"), 1
            end
        end
    else
        local t, dur = Dm:MomentTime()
        if t and dur then
            text = format("0:%02d", max(0, floor(dur - t + 0.5)))
            frac = min(1, t / dur)
        end
    end
    bar.time:SetText(text or "")
    bar.time:SetShown(text ~= nil)
    bar.track:SetShown(frac ~= nil)
    if frac then bar.track:Set(frac) end
end

function DemoBar:Update()
    local Dm = D()
    if not (Dm and Dm.OnList) then return end
    local list = Dm:OnList()
    local mKey = Dm:GetMoment()
    local want = (#list > 0 or mKey ~= nil) or (bar and bar.previewing)
    if not want then
        if bar then bar:Hide() end
        return
    end
    Build()
    local x = 10 + UI:TextWidth(bar.tag) + 10
    local n = 0
    local function chip(text, key, moment, more)
        n = n + 1
        local c = bar.chips[n]
        c.key, c.moment, c.more = key, moment, more
        c:Set(text .. (more and "" or S:Wrap("SUB", "  \195\151")))
        c:SetSelected(moment and true or false)
        c:ClearAllPoints()
        c:SetPoint("LEFT", bar, "LEFT", x, 0)
        c:Show()
        x = x + (c:GetWidth() or 60) + GAP
    end
    if bar.previewing and #list == 0 and not mKey then
        chip("Damage meter")
        chip("Nameplates")
    end
    for i, d in ipairs(list) do
        if i > MAX_CHIPS - (mKey and 1 or 0) then
            chip(format("+%d", #list - i + 1), nil, nil, true)
            break
        end
        chip(d.label, d.key)
    end
    if mKey then
        local md = Dm:GetPart(mKey)
        chip(UI:AtlasIconText(UI.ICON.play, 10, S.C.GOLD) .. " " .. (md and md.label or mKey), nil, true)
    end
    for i = n + 1, #bar.chips do bar.chips[i]:Hide() end
    x = x + 4
    bar.time:ClearAllPoints()
    bar.time:SetPoint("LEFT", bar, "LEFT", x, 1)
    self:PaintTime(true)
    local tw = (bar.time:GetText() or "") ~= "" and max(UI:TextWidth(bar.time), 60) or 0
    bar.track:ClearAllPoints()
    bar.track:SetPoint("TOPLEFT", bar.time, "BOTTOMLEFT", 0, -2)
    if tw > 0 then x = x + tw + 10 end
    bar.again:SetShown(Dm:AnyPull())
    local right = {}
    if bar.again:IsShown() then right[#right + 1] = bar.again end
    right[#right + 1] = bar.stop
    right[#right + 1] = bar.page
    for _, b in ipairs(right) do
        b:ClearAllPoints()
        b:SetPoint("LEFT", bar, "LEFT", x, 0)
        x = x + (b:GetWidth() or 20) + GAP
    end
    bar:SetWidth(x + 4)
    bar:Show()
end

function DemoBar:Preview(on)
    Build()
    bar.previewing = on and true or nil
    self:Update()
end

function DemoBar:GetFrame() return bar end

function DemoBar:OnInit()
    ns.Layout:Register("demobar", { name = "Demo bar", group = "Game frames", order = 90, when = "while a demo plays",
        frame = function() return bar end, default = { "TOP", 0, -8 },
        preview = function(on) DemoBar:Preview(on) end })
end

function DemoBar:OnLogin()
    local function update() DemoBar:Update() end
    for _, m in ipairs({ "DEMO_PARTS_CHANGED", "DEMO_MOMENT", "DEMO_PULL", "DEMO_TOGGLED" }) do ns:On(m, update) end
end
