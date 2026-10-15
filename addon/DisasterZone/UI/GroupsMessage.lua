if DisasterZoneBoot and DisasterZoneBoot.Run("UI/GroupsMessage.lua", ...) then return end -- DisasterZone: UI/GroupsMessage.lua
-- (1.5, feedback #8) The LFG message of my group (Core/GroupsLFG.lua), on the leader page's Message tab:
--   Looking for: what the open places add up to (tanks, healers), the damage places split into melee and ranged with
--     two steppers, and the specs I'm after as chips (+ Add a spec: a menu of classes and their specs).
--   Message: the blocks as chips in their order, gold while on (a click switches one, a drag moves it); "Your words"
--     opens a field; under them the exact text the channel gets, with its length against 255.
--   Post now, and "Post again every 30 s / 1 min / 2 min": the poster (a small bar on the screen) lights up each time
--     the message is ready and one click, or the bound key, sends it (the client posts in channels only from a click
--     or a key).
local addonName, ns = ...

local GM = ns:NewModule("GroupsMessage")
local S = ns.Style

local floor, max, min = math.floor, math.max, math.min
local tconcat = table.concat

local function L() return ns.GroupsLFG end
local function R() return ns.DungeonRuns end
local function UI() return ns.UI end

local GOLD = S.C.GOLD
local LBL = 92
local CHIP_GAP = 6

local box   -- the tab's frame (in the leader page's body)
local poster

local function HideTip() GameTooltip:Hide() end

local function PostNow()
    local ok, why = L():Post()
    if not ok and why then ns:Print("%s", why) end
    return ok
end

-- (the key binding: a key press may post in a channel)
function DisasterZone_PostLFG()
    if not (ns.GroupsLFG and ns.GroupsLFG:IsRepeating()) and not R():GetMyGroup() then return end
    PostNow()
end
BINDING_HEADER_DISASTERZONE = BINDING_HEADER_DISASTERZONE or "DisasterZone"
BINDING_NAME_DISASTERZONE_LFGPOST = "Post my group's LFG message"

local function KeyText()
    local k = GetBindingKey and GetBindingKey("DISASTERZONE_LFGPOST")
    return k and (GetBindingText and GetBindingText(k) or k) or nil
end

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------

local function Caps(parent, text)
    local h = UI():CreateSectionHeader(parent, text, { style = "caps" })
    return h
end

local function Create(parent)
    box = CreateFrame("Frame", nil, parent)
    box.lookHead = Caps(box, "Looking for")
    -- tanks / healers as text, melee / ranged as steppers, the rest as "any DPS"
    box.roles = UI():Text(box, "body", "TEXT")
    box.melee = UI():CreateStepper(box, 104, function(dir) L():StepSplit("melee", dir) end,
        { tip = { "Melee", "Damage places you want filled by melee." } })
    box.ranged = UI():CreateStepper(box, 104, function(dir) L():StepSplit("ranged", dir) end,
        { tip = { "Ranged", "Damage places you want filled by ranged: hunters and casters." } })
    box.anyDps = UI():Text(box, "small", "SUB")
    box.specsLabel = UI():Text(box, "body", "SUB")
    box.specsLabel:SetText("Specs")
    box.specChips = {}
    box.addSpec = UI():CreateSleekButton(box, "+ Add a spec", 104, 22, function(self) GM:OpenSpecMenu(self) end, "secondary")
    box.msgHead = Caps(box, "Message")
    box.chips = {}
    box.dropBar = box:CreateTexture(nil, "OVERLAY")
    box.dropBar:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    box.dropBar:SetSize(2, 22)
    box.dropBar:Hide()
    box.custom = UI():CreateSleekEditBox(box, 300, 24, "GameFontHighlightSmall")
    box.custom:SetMaxLetters(120)
    UI():SetEditPlaceholder(box.custom, "Your words, e.g. \"exp only\" or \"400+ spell power\"")
    box.custom:SetScript("OnTextChanged", function(self, user)
        if user then L():SetCustom(self:GetText()) end
    end)
    box.custom:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    -- the exact text
    box.preview = CreateFrame("Frame", nil, box)
    box.preview.bg = UI():Fill(box.preview, "CARD", "BACKGROUND")
    UI():AddEdges(box.preview, "BORDER")
    box.preview.text = UI():Text(box.preview, "body", "TEXT", { wrap = true })
    box.preview.text:SetPoint("TOPLEFT", 10, -9)
    box.preview.len = UI():Text(box.preview, "small", "SUB", { justify = "RIGHT" })
    box.preview.len:SetPoint("BOTTOMRIGHT", -8, 6)
    box.reset = UI():CreateSleekButton(box, "Reset", 60, 20, function() L():Reset() end, "secondary")
    -- posting
    box.post = UI():CreateSleekButton(box, "Post now", 110, S.BTN_H, function() PostNow() end, "primary")
    box.rep = UI():CreateSwitch(box, nil, function() GM:ToggleRepeat() end)
    box.repText = UI():Text(box, "emph", "TEXT")
    box.repText:SetText("Post again every")
    box.every = UI():CreateSegments(box, { { key = 30, label = "30 s" }, { key = 60, label = "1 min" },
        { key = 120, label = "2 min" } }, function(key) L():SetEvery(key) end, { h = 22, itemW = 52 })
    box.hint = UI():Text(box, "small", "SUB", { wrap = true })
    return box
end

---------------------------------------------------------------------------
-- The spec menu and chips
---------------------------------------------------------------------------

local CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

function GM:OpenSpecMenu(owner)
    UI():ContextMenu(owner, function(root)
        for _, c in ipairs(CLASS_ORDER) do
            local specs = ns.SPECS[c]
            if specs then
                local cls = ns.ClassName(c)
                local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[c]
                local label = color and ("|c" .. (color.colorStr or "ffffffff") .. cls .. "|r") or cls
                local sub = root:CreateButton(label)
                for sp, spec in ipairs(specs) do
                    local icon = ns.SpecIcon(c, sp)
                    sub:CreateButton((icon and ("|T" .. icon .. ":14:14:0:0:64:64:5:59:5:59|t ") or "") .. spec.label,
                        function()
                            local have = 0
                            for _, s in ipairs(L():GetSpecs()) do if s.c == c and s.sp == sp then have = s.n end end
                            L():SetSpec(c, sp, have + 1)
                        end)
                end
            end
        end
    end)
end

local function SpecChip(i)
    local c = box.specChips[i]
    if not c then
        c = UI():CreateChip(box, { kind = "track", onClick = function(self, button)
            local d = self.spec
            if not d then return end
            -- left: one more; right: one fewer (the last one takes it out)
            L():SetSpec(d.c, d.sp, d.n + (button == "RightButton" and -1 or 1))
        end })
        c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        UI():AttachTooltip(c, nil, function(self)
            return self.spec and { L():SpecName(self.spec.c, self.spec.sp),
                "Left-click: one more. Right-click: one fewer." } or nil
        end, { anchor = "ANCHOR_TOP" })
        box.specChips[i] = c
    end
    return c
end

---------------------------------------------------------------------------
-- The block chips: click to switch, drag to move
---------------------------------------------------------------------------

local drag   -- { key, chip } while a chip is dragged

-- Where a drop at the cursor lands: the index in the order, and the chip it goes before (nil: at the end).
local function DropAt()
    local x, y = GetCursorPosition()
    local scale = box:GetEffectiveScale()
    x, y = x / scale, y / scale
    local best, bestD, before
    for i, c in ipairs(box.chips) do
        if c:IsShown() and c.blockKey then
            local l, b, w, h = c:GetRect()
            if l then
                local cx, cy = l + w / 2, b + h / 2
                local d = math.abs(cy - y) * 4 + math.abs(cx - x)
                if not bestD or d < bestD then
                    bestD = d
                    best = (x < cx) and i or i + 1
                    before = (x < cx) and c or box.chips[i + 1]
                end
            end
        end
    end
    return best, before
end

local function BlockChip(i)
    local c = box.chips[i]
    if not c then
        c = UI():CreateChip(box, { kind = "track", onClick = function(self)
            if drag then return end
            L():SetBlockOn(self.blockKey, not self.on)
        end })
        c:RegisterForDrag("LeftButton")
        c:SetScript("OnDragStart", function(self)
            drag = { key = self.blockKey, chip = self }
            self:SetAlpha(0.45)
            box:SetScript("OnUpdate", function()
                local _, before = DropAt()
                box.dropBar:ClearAllPoints()
                if before then
                    box.dropBar:SetPoint("RIGHT", before, "LEFT", -2, 0)
                else
                    local last
                    for _, x in ipairs(box.chips) do if x:IsShown() then last = x end end
                    if last then box.dropBar:SetPoint("LEFT", last, "RIGHT", 2, 0) end
                end
                box.dropBar:Show()
            end)
        end)
        c:SetScript("OnDragStop", function(self)
            box:SetScript("OnUpdate", nil)
            box.dropBar:Hide()
            self:SetAlpha(1)
            local to = DropAt()
            local key = drag and drag.key
            drag = nil
            if key and to then
                -- (an index counted with the dragged chip still in place)
                local from
                for j, x in ipairs(box.chips) do if x.blockKey == key then from = j end end
                if from and to > from then to = to - 1 end
                L():MoveBlock(key, to)
            end
        end)
        UI():AttachTooltip(c, nil, function(self)
            local lines = { self.label }
            lines[#lines + 1] = self.text and ("Says: " .. self.text) or S:Wrap("SUB", "Nothing to say for this group.")
            lines[#lines + 1] = S:Wrap("SUB", (self.on and "Click to leave it out." or "Click to put it in.")
                .. " Drag to move it.")
            return lines
        end, { anchor = "ANCHOR_TOP" })
        box.chips[i] = c
    end
    return c
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

-- Lays the tab out in `parent` (the leader page's body), w wide; returns its height.
function GM:Layout(parent, w)
    if not box then Create(parent) end
    box:SetParent(parent)
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    box:SetWidth(w)
    box:Show()
    local run = R():GetMyGroup()
    local y = 0
    -- Looking for
    box.lookHead:ClearAllPoints()
    box.lookHead:SetPoint("TOPLEFT", box, "TOPLEFT", 0, -y)
    box.lookHead:SetWidth(w)
    y = y + 22
    local need = L():GetNeed(run)
    local bits = {}
    if need.tank > 0 then bits[#bits + 1] = UI():RoleIconText("tank", 14) .. " " .. need.tank end
    if need.healer > 0 then bits[#bits + 1] = UI():RoleIconText("healer", 14) .. " " .. need.healer end
    box.roles:ClearAllPoints()
    box.roles:SetPoint("TOPLEFT", box, "TOPLEFT", 0, -(y + 5))
    box.roles:SetText(#bits > 0 and tconcat(bits, "   ") or S:Wrap("SUB", "No tank or healer places open"))
    local dpsOpen = need.melee + need.ranged + need.dps
    local x = max(110, (box.roles:GetStringWidth() or 0) + 18)
    box.melee:ClearAllPoints()
    box.melee:SetPoint("TOPLEFT", box, "TOPLEFT", x, -y)
    box.melee:Set("Melee  " .. need.melee, need.melee > 0, need.dps > 0)
    box.ranged:ClearAllPoints()
    box.ranged:SetPoint("LEFT", box.melee, "RIGHT", 6, 0)
    box.ranged:Set("Ranged  " .. need.ranged, need.ranged > 0, need.dps > 0)
    box.anyDps:ClearAllPoints()
    box.anyDps:SetPoint("LEFT", box.ranged, "RIGHT", 8, 0)
    box.anyDps:SetText(dpsOpen == 0 and "no DPS places open" or (need.dps > 0 and ("+" .. need.dps .. " any DPS") or ""))
    y = y + 32
    -- specs
    box.specsLabel:ClearAllPoints()
    box.specsLabel:SetPoint("TOPLEFT", box, "TOPLEFT", 0, -(y + 4))
    local cx, cy = 60, y
    local specs = L():GetSpecs(run)
    for _, c in ipairs(box.specChips) do c:Hide() end
    for i, sdata in ipairs(specs) do
        local c = SpecChip(i)
        c.spec = sdata
        c:Set(L():SpecName(sdata.c, sdata.sp) .. (sdata.n > 1 and ("  x" .. sdata.n) or ""), nil, nil)
        local icon = ns.SpecIcon(sdata.c, sdata.sp)
        if icon and c.SetIcon then c:SetIcon(icon) end
        c:SetSelected(true)
        if cx + c:GetWidth() > w then cx, cy = 60, cy + 26 end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", box, "TOPLEFT", cx, -cy)
        c:Show()
        cx = cx + c:GetWidth() + CHIP_GAP
    end
    if cx + box.addSpec:GetWidth() > w then cx, cy = 60, cy + 26 end
    box.addSpec:ClearAllPoints()
    box.addSpec:SetPoint("TOPLEFT", box, "TOPLEFT", cx, -cy + 2)
    y = cy + 34
    -- Message
    box.msgHead:ClearAllPoints()
    box.msgHead:SetPoint("TOPLEFT", box, "TOPLEFT", 0, -y)
    box.msgHead:SetWidth(w - 70)
    box.reset:ClearAllPoints()
    box.reset:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -y + 2)
    y = y + 24
    cx, cy = 0, y
    local blocks = L():GetBlocks(run)
    for _, c in ipairs(box.chips) do c:Hide() end
    for i, b in ipairs(blocks) do
        local c = BlockChip(i)
        c.blockKey, c.on, c.label, c.text = b.key, b.on, b.label, b.text
        local empty = b.text == nil
        c:Set(b.label, b.on and not empty and GOLD or nil)
        c:SetSelected(b.on and not empty)
        c:SetAlpha(empty and 0.45 or 1)
        if cx + c:GetWidth() > w then cx, cy = 0, cy + 26 end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", box, "TOPLEFT", cx, -cy)
        c:Show()
        cx = cx + c:GetWidth() + CHIP_GAP
    end
    y = cy + 30
    -- your words
    local customOn = false
    for _, b in ipairs(blocks) do if b.key == "custom" then customOn = b.on end end
    box.custom:SetShown(customOn)
    if customOn then
        box.custom:ClearAllPoints()
        box.custom:SetPoint("TOPLEFT", box, "TOPLEFT", 0, -y)
        box.custom:SetWidth(w)
        if not box.custom:HasFocus() then box.custom:SetText(L():GetCustom()) end
        y = y + 32
    end
    -- the exact text
    local text, len, long = L():Compose(run)
    local pv = box.preview
    pv:ClearAllPoints()
    pv:SetPoint("TOPLEFT", box, "TOPLEFT", 0, -y)
    pv:SetWidth(w)
    pv.text:SetWidth(w - 20)
    pv.text:SetText(text or S:Wrap("SUB", "Switch a block on to say something."))
    pv.len:SetText(S:Wrap(long and "WARN" or "SUB", len .. " / " .. L().MAX_LEN .. (long and "  too long: the end is cut" or "")))
    local ph = (pv.text:GetStringHeight() or 14) + 34
    pv:SetHeight(ph)
    y = y + ph + 12
    -- posting
    box.post:ClearAllPoints()
    box.post:SetPoint("TOPLEFT", box, "TOPLEFT", 0, -y)
    box.post:SetEnabled(text ~= nil)
    box.rep:ClearAllPoints()
    box.rep:SetPoint("LEFT", box.post, "RIGHT", 16, 0)
    box.rep:SetOn(L():IsRepeating())
    box.repText:ClearAllPoints()
    box.repText:SetPoint("LEFT", box.rep, "RIGHT", 8, 0)
    box.repText:SetTextColor(S:Color(L():IsRepeating() and "TEXT" or "SUB"))
    box.every:ClearAllPoints()
    box.every:SetPoint("LEFT", box.repText, "RIGHT", 8, 0)
    box.every:Select(L():GetEvery())
    y = y + S.BTN_H + 8
    local key = KeyText()
    box.hint:ClearAllPoints()
    box.hint:SetPoint("TOPLEFT", box, "TOPLEFT", 0, -y)
    box.hint:SetWidth(w)
    box.hint:SetText("The game posts in channels only from a click or a key, so while this is on a small poster lights up "
        .. "each time the message is ready: click it" .. (key and (" or press " .. S:Wrap("GOLD", key)) or
        ", or bind a key in Key Bindings > AddOns > DisasterZone") .. ".")
    y = y + (box.hint:GetStringHeight() or 14) + 6
    box:SetHeight(y)
    return y
end

function GM:Hide()
    if box then box:Hide() end
end

---------------------------------------------------------------------------
-- The poster: a small bar on the screen while the repeat is on
---------------------------------------------------------------------------

local function CreatePoster()
    local f = UI():CreateHudFrame("DisasterZoneLfgPoster", { width = 300, height = 58, look = "card",
        default = { "TOP", UIParent, "TOP", 0, -150 }, close = function() L():SetRepeat(false) end })
    f.title = UI():Text(f, "caps", "GOLD")
    f.title:SetPoint("TOPLEFT", 10, -8)
    f.title:SetText("LFG message")
    f.state = UI():Text(f, "small", "SUB")
    f.state:SetPoint("LEFT", f.title, "RIGHT", 8, 0)
    f.text = UI():Text(f, "small", "TEXT")
    f.text:SetPoint("BOTTOMLEFT", 10, 9)
    f.text:SetWidth(190)
    f.text:SetWordWrap(false)
    f.btn = UI():CreateSleekButton(f, "Post", 76, 26, function() PostNow() end, "primary")
    f.btn:SetPoint("BOTTOMRIGHT", -8, 7)
    f.glow = f.btn:CreateTexture(nil, "OVERLAY")
    f.glow:SetPoint("TOPLEFT", -3, 3)
    f.glow:SetPoint("BOTTOMRIGHT", 3, -3)
    f.glow:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.35)
    f.glow:SetBlendMode("ADD")
    f.pulse = f.glow:CreateAnimationGroup()
    local a = f.pulse:CreateAnimation("Alpha")
    a:SetFromAlpha(0.1)
    a:SetToAlpha(1)
    a:SetDuration(0.7)
    f.pulse:SetLooping("BOUNCE")
    f:Hide()
    f:RestorePlace()
    f.elapsed = 0
    f:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        if self.elapsed < 0.25 then return end
        self.elapsed = 0
        GM:RefreshPoster()
    end)
    poster = f
    return f
end

function GM:RefreshPoster()
    local on = L():IsRepeating()
    if not on then
        if poster then poster:Hide() end
        return
    end
    local f = poster or CreatePoster()
    local ready = L():IsReady()
    local text = L():Compose()
    f.text:SetText(text or "")
    local key = KeyText()
    f.state:SetText(ready and S:Wrap("GOLD", "ready" .. (key and (": press " .. key) or ""))
        or ("next in " .. math.ceil(L():GetWait() or 0) .. " s"))
    f.btn:SetKind(ready and "primary" or "secondary")
    f.glow:SetShown(ready)
    if ready and not f.pulse:IsPlaying() then f.pulse:Play() elseif not ready then f.pulse:Stop() end
    f:Show()
end

function GM:GetPoster() return poster end

function GM:ToggleRepeat()
    local ok, why = L():SetRepeat(not L():IsRepeating())
    if not ok and why then ns:Print("%s", why) end
end

---------------------------------------------------------------------------

function GM:OnInit()
    local function redraw()
        if ns.GroupsLead and ns.GroupsLead:IsOpen() then ns.GroupsLead:Refresh() end
        GM:RefreshPoster()
    end
    ns:On("GROUPS_LFG_CHANGED", redraw)
    ns:On("GROUPS_LFG_REPEAT", redraw)
    ns:On("GROUPS_LFG_POSTED", redraw)
    ns:On("GROUPS_LFG_READY", function()
        if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end
        redraw()
    end)
end
