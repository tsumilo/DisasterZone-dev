if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Comp/Overlays.lua", ...) then return end -- DisasterZone UI/Comp/Overlays.lua
-- overlays: sheet, toast, HUD frame (refactor phase 2).
local addonName, ns = ...

-- The things that float over the game and the addon's windows, one shape each (the dialogs themselves live in
-- UI/Popup.lua: ns.Popup:Confirm / ns.Popup:Prompt):
--   UI:Toast(opts)                 a pop-up at the top of the screen: one look, one stack, replaced by its key
--   UI:CreateSheet(parent, opts)   a sheet: a form of its own over a window (dimmed under it) or over a panel
--   UI:CreateHudFrame(name, opts)  a small frame on the screen: dragged, locked, its place kept (UI:SavePosition)
-- Every value comes from ns.Style (UI/Style.lua).
local UI = ns.UI
local S = ns.Style

local floor, max, min = math.floor, math.max, math.min
local tinsert, tremove = table.insert, table.remove

-- (one table of helpers: the file stays well under the client's upvalue limits)
local H = {}

-- Runs a caller's callback; an error goes to the error handler and the overlay carries on.
function H.Safe(what, fn, ...)
    if type(fn) ~= "function" then return true, nil end
    local ok, r = pcall(fn, ...)
    if not ok then
        local eh = geterrorhandler and geterrorhandler()
        if eh then eh(("%s: %s"):format(what, tostring(r))) end
    end
    return ok, r
end

function H.InCombat() return InCombatLockdown and InCombatLockdown() and true or false end

-- A sound by SOUNDKIT name ("TELL_MESSAGE") or id.
function H.Play(sound)
    if not sound or not PlaySound then return end
    local id = sound
    if type(sound) == "string" then id = SOUNDKIT and SOUNDKIT[sound] end
    if id then pcall(PlaySound, id) end
end

-- Escape closes `f` with closeFn and goes no further; other keys go on to the game (the dialogs' way).
function H.EscapeCloses(f, closeFn)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            if not H.InCombat() then self:SetPropagateKeyboardInput(false) end
            closeFn(self)
        elseif not H.InCombat() then
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:HookScript("OnShow", function(self)
        if not H.InCombat() then
            self:EnableKeyboard(true)
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:HookScript("OnHide", function(self)
        if not H.InCombat() then self:EnableKeyboard(false) end
    end)
end

-- A colour from a kind word or a token / table.
local KIND_COLOR = { info = "GOLD", gold = "GOLD", ok = "OK", warn = "WARN", bad = "BAD", live = "LIVE", you = "YOU" }
function H.KindColor(kind)
    if type(kind) == "table" then return kind end
    return KIND_COLOR[kind or "info"] or (S.C[kind] and kind) or "GOLD"
end

---------------------------------------------------------------------------
-- Toasts
---------------------------------------------------------------------------
-- UI:Toast(opts) -> the toast (nil while it waits: in combat, or behind UI.TOAST.MAX shown ones)
--   key        a toast with this key on screen is filled again in place (no second one, no new sound); one still
--              waiting is replaced in the queue
--   kind       "info" (gold, default) | "ok" | "warn" | "bad" | "live" | "you" | a colour token / { r, g, b }:
--              the edge and the kicker
--   kicker     a small capitals line over the title;  title;  text (grey, wraps, `lines` lines at most: 3)
--   icon       a texture (path / file id) at the left, iconSize (32) and iconCoords ({ l, r, t, b }; trimmed
--              by default); art = { file, l, r, t, b } a picture down the left side instead (artWidth 112)
--   buttons    { { text, kind = "primary" | "secondary" | "danger" | "link", onClick(toast), width }, ... }: one
--              sleek button sits at the right, middle (buttonRow = true: along the foot); more go along the foot
--              (the sleek ones from the left, the links at the right). A click runs onClick, then the toast goes
--              unless onClick returned true
--   onClick    a click on the toast itself (same rule)
--   onClose(toast, reason)  when it goes: "timeout" | "close" (its X) | "click" | "button" | "hide" (UI:HideToast /
--              :Hide()) - not when it is filled again by its key
--   duration   seconds on screen (12; 0 or false: until it is answered); the time stands still under the mouse
--   progress   0..1: a thin bar along the foot (progressColor, default "OK"); timeBar = true: the time left instead
--   sound      a SOUNDKIT name or id, played when it appears;  noClose: no X;  width (380);  minHeight
--   combat     false: waits until the fight is over
--   itemID     the item's tooltip while hovered (tipLine: a grey line under it);  rightClose: a right-click dismisses it
--   onShow(toast)  after it is filled and on screen (also when it waited in the queue first): the caller's own
--              touches (its slot pieces, an icon tint)
-- toast.slot is a frame over the toast for a caller's own pieces (emptied each time the toast is filled again).
-- UI:HideToast(key | toast, reason), UI:GetToast(key), UI:ShownToasts(), UI:ToastQueue().
UI.TOAST = { W = 380, TOP = -120, GAP = 8, MAX = 3, PAD = 12, ICON = 32, ART = 112, DURATION = 12, BTN_H = 22,
    BG = { 0.043, 0.043, 0.051, 0.95 } }
local T = UI.TOAST

local toastFrames = {}     -- every toast frame made (reused)
local shownToasts = {}     -- on screen, top to bottom
local toastQueue = {}      -- waiting opts

-- Places the shown toasts down from the top of the screen.
function H.Restack()
    local prev
    for _, t in ipairs(shownToasts) do
        t:ClearAllPoints()
        if prev then t:SetPoint("TOP", prev, "BOTTOM", 0, -T.GAP)
        else t:SetPoint("TOP", UIParent, "TOP", 0, T.TOP) end
        prev = t
    end
end

-- A quiet text button ("Later"): dim, gold under the mouse.
function H.NewLink(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(16)
    b.fs = UI:Text(b, "small", "DIM", { justify = "RIGHT" })
    b.fs:SetPoint("RIGHT")
    b:SetFontString(b.fs)
    b:SetScript("OnEnter", function(self) self.fs:SetTextColor(S:Color("GOLD")) end)
    b:SetScript("OnLeave", function(self) self.fs:SetTextColor(S:Color("DIM")) end)
    return b
end

function H.NewToast(i)
    local t = CreateFrame("Button", "DisasterZoneToast" .. i, UIParent)
    t:SetSize(T.W, 76)
    t:SetFrameStrata("DIALOG")
    t:SetFrameLevel(3200)      -- over a sheet and its dim (UI:CreateSheet: 3000 / 3010): a pop-up is never dimmed
    t:SetToplevel(true)
    t:SetClampedToScreen(true)
    t:EnableMouse(true)
    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    t.bg = UI:Fill(t, T.BG, "BACKGROUND")
    UI:AddEdges(t, "BORDER")
    t.art = t:CreateTexture(nil, "ARTWORK", nil, 0)
    t.art:SetPoint("TOPLEFT", 1, -1)
    t.art:SetPoint("BOTTOMLEFT", 1, 1)
    t.artFade = t:CreateTexture(nil, "ARTWORK", nil, 2)
    t.artFade:SetPoint("TOPRIGHT", t.art, "TOPRIGHT")
    t.artFade:SetPoint("BOTTOMRIGHT", t.art, "BOTTOMRIGHT")
    UI:Gradient(t.artFade, "HORIZONTAL", { T.BG[1], T.BG[2], T.BG[3], 0 }, { T.BG[1], T.BG[2], T.BG[3], 1 })
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.kick = UI:Text(t, "caps", "GOLD")
    t.title = UI:Text(t, "title", "TEXT")
    t.text = UI:Text(t, "sub", "SUB", { wrap = true })
    t.text:SetJustifyV("TOP")
    t.text:SetSpacing(2)
    t.close = UI:CreateCloseButton(t, 16, function() UI:HideToast(t, "close") end)
    t.close:SetPoint("TOPRIGHT", -3, -3)
    t.bar = t:CreateTexture(nil, "OVERLAY")
    t.bar:SetPoint("BOTTOMLEFT", 1, 1)
    t.bar:SetHeight(2)
    t.slot = CreateFrame("Frame", nil, t)
    t.slot:SetAllPoints()
    t.slot:SetFrameLevel(t:GetFrameLevel() + 5)
    t.btns, t.links = {}, {}
    t:SetScript("OnClick", function(self, button)
        local o = self.opts
        if button == "RightButton" then
            if o and o.rightClose then UI:HideToast(self, "close") end
            return
        end
        if not (o and o.onClick) then return end
        local ok, keep = H.Safe("Toast onClick", o.onClick, self)
        if not (ok and keep) and self:IsShown() and self.opts == o then UI:HideToast(self, "click") end
    end)
    t:SetScript("OnUpdate", function(self, dt)
        local left = self.left
        if not left then return end
        if not self:IsMouseOver() then
            left = left - (dt or 0)
            self.left = left
        end
        if self.opts and self.opts.timeBar and self.total and self.total > 0 then
            self.bar:SetWidth(max(1, (self:GetWidth() - 2) * max(0, left) / self.total))
        end
        if left <= 0 then UI:HideToast(self, "timeout") end
    end)
    -- an item's tooltip while hovered (opts.itemID; opts.tipLine under it)
    t:SetScript("OnEnter", function(self)
        local o = self.opts
        if not (o and o.itemID) then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetItemByID(o.itemID)
        if o.tipLine then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(o.tipLine, S:RGB("SUB"))
        end
        GameTooltip:Show()
    end)
    t:SetScript("OnLeave", function(self)
        if self.opts and self.opts.itemID then GameTooltip:Hide() end
    end)
    -- (hidden with the whole UI, Alt+Z: it is still shown, keeps its place in the stack and its time waits)
    t:SetScript("OnHide", function(self)
        if self:IsShown() then return end
        H.ToastGone(self)
    end)
    t:Hide()
    toastFrames[i] = t
    return t
end

-- The button of the toast for spec `spec` (index i among its kind), made or reused.
function H.ToastButton(t, i, spec)
    local isLink = spec.kind == "link"
    local list = isLink and t.links or t.btns
    local b = list[i]
    if not b then
        if isLink then b = H.NewLink(t)
        else b = UI:CreateSleekButton(t, "", 60, T.BTN_H, nil, "secondary") end
        b:SetFrameLevel(t:GetFrameLevel() + 8)
        list[i] = b
    end
    b:SetText(spec.text or "")
    if isLink then
        b:SetWidth(spec.width or max(30, floor(UI:TextWidth(spec.text or "", "small") + 12)))
    else
        b:SetKind(spec.kind or (i == 1 and "primary" or "secondary"))
        local fs = b:GetFontString()
        b:SetWidth(spec.width or max(60, floor((fs and fs:GetStringWidth() or 40) + 28 + 0.5)))
    end
    b:SetScript("OnClick", function()
        local o = t.opts
        local ok, keep = H.Safe("Toast button", spec.onClick, t)
        if not (ok and keep) and t:IsShown() and t.opts == o then UI:HideToast(t, "button") end
    end)
    b:Show()
    return b
end

-- Lays out the toast's buttons; returns the one at the side (or nil), the sleek and the link lists.
function H.ToastButtons(t, o)
    for _, list in ipairs({ t.btns, t.links }) do
        for _, btn in ipairs(list) do btn:Hide() end
    end
    local sleek, links = {}, {}
    for _, spec in ipairs(o.buttons or {}) do
        if spec.kind == "link" then links[#links + 1] = H.ToastButton(t, #links + 1, spec)
        else sleek[#sleek + 1] = H.ToastButton(t, #sleek + 1, spec) end
    end
    local side = (#sleek == 1 and #links == 0 and not o.buttonRow) and sleek[1] or nil
    return side, sleek, links
end

-- The left of the toast: its art or its icon. Returns where the words start.
function H.ToastLeft(t, o)
    local art = type(o.art) == "table" and o.art or (o.art and { o.art }) or nil
    t.art:SetShown(art ~= nil)
    t.artFade:SetShown(art ~= nil)
    t.icon:SetShown(art == nil and o.icon ~= nil)
    if art then
        local aw = o.artWidth or T.ART
        t.art:SetWidth(aw)
        t.art:SetTexture(art[1] or art.file)
        t.art:SetTexCoord(art[2] or 0, art[3] or 1, art[4] or 0, art[5] or 1)
        t.artFade:SetWidth(floor(aw * 0.45))
        return aw + 10, true
    elseif o.icon then
        local size = o.iconSize or T.ICON
        t.icon:SetTexture(o.icon)
        local ic = o.iconCoords or { 0.08, 0.92, 0.08, 0.92 }
        t.icon:SetTexCoord(ic[1], ic[2], ic[3], ic[4])
        t.icon:SetSize(size, size)
        t.icon:ClearAllPoints()
        t.icon:SetPoint("TOPLEFT", T.PAD, -T.PAD)
        return T.PAD + size + 10, false
    end
    return T.PAD, false
end

-- Fills toast t from opts o and sizes it.
function H.FillToast(t, o)
    local w = o.width or T.W
    local PAD = T.PAD
    t:SetWidth(w)
    t.key, t.opts = o.key, o
    local r, g, b = S:Color(H.KindColor(o.kind))
    UI:SetEdgeColor(t, r, g, b, 0.6)
    local x, hasArt = H.ToastLeft(t, o)
    local side, sleek, links = H.ToastButtons(t, o)
    local right = w - PAD - (o.noClose and 0 or 12)
    if side then right = w - PAD - side:GetWidth() - 12 end
    local textW = max(40, right - x)
    -- the words, top down
    local y = PAD
    t.kick:SetShown(o.kicker ~= nil)
    if o.kicker then
        t.kick:SetTextColor(r, g, b)
        t.kick:SetText(tostring(o.kicker):upper())
        t.kick:ClearAllPoints()
        t.kick:SetPoint("TOPLEFT", x, -y)
        t.kick:SetWidth(textW)
        y = y + 10 + 5
    end
    t.title:SetShown(o.title ~= nil)
    if o.title then
        t.title:ClearAllPoints()
        t.title:SetPoint("TOPLEFT", x, -y)
        t.title:SetWidth(textW)
        UI:FitText(t.title, o.title, textW)
        y = y + 14 + 4
    end
    t.text:SetShown(o.text ~= nil)
    if o.text then
        t.text:ClearAllPoints()
        t.text:SetPoint("TOPLEFT", x, -y)
        t.text:SetWidth(textW)
        if t.text.SetMaxLines then t.text:SetMaxLines(o.lines or 3) end
        t.text:SetText(o.text)
        local th = t.text:GetStringHeight() or 12
        if th < 1 then th = 12 end
        y = y + min(th, (o.lines or 3) * 14)
    end
    -- the foot row
    if (#sleek > 0 or #links > 0) and not side then
        y = y + 10
        local prev
        for i = 1, #sleek do
            local btn = sleek[i]
            btn:ClearAllPoints()
            if prev then btn:SetPoint("LEFT", prev, "RIGHT", 6, 0)
            else btn:SetPoint("TOPLEFT", t, "TOPLEFT", x, -y) end
            prev = btn
        end
        prev = nil
        for i = #links, 1, -1 do
            local btn = links[i]
            btn:ClearAllPoints()
            if prev then btn:SetPoint("RIGHT", prev, "LEFT", -10, 0)
            else btn:SetPoint("TOPRIGHT", t, "TOPRIGHT", -PAD, -(y + 3)) end
            prev = btn
        end
        y = y + T.BTN_H
    end
    local h = y + PAD
    if o.icon and not hasArt then h = max(h, (o.iconSize or T.ICON) + 2 * PAD) end
    if hasArt then h = max(h, 76) end
    t:SetHeight(floor(max(h, o.minHeight or 0) + 0.5))
    if side then
        side:ClearAllPoints()
        side:SetPoint("RIGHT", t, "RIGHT", -PAD - (o.noClose and 0 or 2), 0)
    end
    t.close:SetShown(not o.noClose)
    H.ToastTimer(t, o, w)
    -- the caller's own pieces start again
    for _, child in ipairs({ t.slot:GetChildren() }) do child:Hide() end
    for _, region in ipairs({ t.slot:GetRegions() }) do region:Hide() end
    t:SetAlpha(1)
end

-- The time on screen and the foot bar (progress or the time left).
function H.ToastTimer(t, o, w)
    local d = o.duration
    if d == nil then d = T.DURATION end
    t.total = (d and d > 0) and d or nil
    t.left = t.total
    if o.timeBar and t.total then
        t.bar:SetColorTexture(S:Color("GOLD"))
        t.bar:SetWidth(max(1, w - 2))
        t.bar:Show()
    elseif o.progress then
        t.bar:SetColorTexture(S:Color(o.progressColor or "OK"))
        t.bar:SetWidth(max(1, (w - 2) * max(0, min(1, o.progress))))
        t.bar:Show()
    else
        t.bar:Hide()
    end
end

-- A toast went (hidden by anyone): the stack closes up, its onClose, a waiting one comes.
function H.ToastGone(t)
    local o = t.opts
    for i = #shownToasts, 1, -1 do
        if shownToasts[i] == t then tremove(shownToasts, i) end
    end
    local reason = t.hideReason or "hide"
    t.hideReason, t.opts, t.key, t.left = nil, nil, nil, nil
    H.Restack()
    if o and o.onClose then H.Safe("Toast onClose", o.onClose, t, reason) end
    if C_Timer and C_Timer.After then C_Timer.After(0.3, H.Pump) else H.Pump() end
end

function H.FreeToast()
    for _, t in ipairs(toastFrames) do
        if not t:IsShown() then return t end
    end
    return H.NewToast(#toastFrames + 1)
end

function H.CanShow(o)
    if o.combat == false and H.InCombat() then return false end
    return #shownToasts < T.MAX
end

function H.Present(o)
    local t = H.FreeToast()
    H.FillToast(t, o)
    shownToasts[#shownToasts + 1] = t
    H.Restack()
    t:Show()
    t:Raise()
    H.Play(o.sound)
    if o.onShow then H.Safe("Toast onShow", o.onShow, t) end
    return t
end

-- Shows the waiting toasts that can come now (in order; one held for the fight's end lets the others pass).
function H.Pump()
    local i = 1
    while i <= #toastQueue do
        if #shownToasts >= T.MAX then return end
        local o = toastQueue[i]
        if H.CanShow(o) then
            tremove(toastQueue, i)
            H.Present(o)
        else
            i = i + 1
        end
    end
end

function UI:Toast(o)
    if type(o) ~= "table" then return nil end
    if o.key ~= nil then
        local t = self:GetToast(o.key)
        if t then
            H.FillToast(t, o)
            H.Restack()
            if o.onShow then H.Safe("Toast onShow", o.onShow, t) end
            return t
        end
        for i, q in ipairs(toastQueue) do
            if q.key == o.key then
                toastQueue[i] = o
                H.Pump()
                return self:GetToast(o.key)
            end
        end
    end
    if #toastQueue == 0 and H.CanShow(o) then return H.Present(o) end
    toastQueue[#toastQueue + 1] = o
    H.Pump()
    for _, t in ipairs(shownToasts) do
        if t.opts == o then return t end
    end
    return nil
end

-- The shown toast with this key (nil when none).
function UI:GetToast(key)
    if key == nil then return nil end
    for _, t in ipairs(shownToasts) do
        if t.key == key then return t end
    end
    return nil
end

-- Hides a toast (by key or the frame; one waiting under that key leaves the queue). reason goes to its onClose
-- ("hide" by default). True when one was on screen.
function UI:HideToast(which, reason)
    local t = which
    if type(which) ~= "table" then
        for i = #toastQueue, 1, -1 do
            if toastQueue[i].key == which then tremove(toastQueue, i) end
        end
        t = self:GetToast(which)
    end
    if not (t and t.IsShown and t:IsShown()) then return false end
    t.hideReason = reason or "hide"
    t:Hide()
    return true
end

function UI:ShownToasts()
    local out = {}
    for i, t in ipairs(shownToasts) do out[i] = t end
    return out
end

function UI:ToastQueue() return toastQueue end

if ns.RegisterEvent then
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() H.Pump() end)
end

---------------------------------------------------------------------------
-- Sheets
---------------------------------------------------------------------------
-- UI:CreateSheet(parent, opts) -> sheet: a form of its own (the Events sheets' look). Two ways:
--   floating (default): over the window `parent` (or opts.owner: a frame or a function returning one; else the main
--     window when it is shown), centred on it with the window dimmed under it; on the screen when there is none.
--     In the dialogs' strata (higher when its window is higher).
--   opts.cover = true: inside `parent`, covering it (a panel's own sheet, like the Dungeons tab's).
--   opts.child = true: floating, but a child of `parent`: closing that window hides it unanswered (no onClose) and
--     opening the window again shows it again (an offer that waits for the window).
-- opts: { title, width (460), height (330), onClose(sheet), name (a global name), pill = { kind, text },
--   ok = text | { text, kind, width, onClick(sheet) } | false, cancel = text | false ("Cancel" with an ok; closes),
--   foot = text (grey, left of the foot), bg (the cover's fill), rule = false (no hairline under the header) }
-- sheet.body: the content area (inside the header and the foot, 12 px in); sheet.title, .close, .ok, .cancel, .foot,
-- .footIcon, .err, .dim, .fields (edit boxes that lose the focus when it closes: add yours).
-- sheet:Open(), :Close(), :IsOpen(), :SetTitle(text), :Error(text | nil), :SetFoot(text, icon), :SetPill(kind, text)
-- Escape closes it. UI.SHEET.HEAD_H / FOOT_H: the header's and the foot's heights.
UI.SHEET = { W = 460, H = 330, HEAD_H = 40, FOOT_H = 46, PAD = 12 }
local SH = UI.SHEET
local STRATA_RANK = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7,
    TOOLTIP = 8 }

function H.SheetOwner(sh)
    local o = sh.ownerOpt
    if type(o) == "function" then
        local ok, f = pcall(o, sh)
        o = ok and f or nil
    end
    o = o or sh.ownerFrame or _G.DisasterZoneMainFrame
    if type(o) == "table" and o ~= UIParent and o.IsShown and o:IsShown() then return o end
    return nil
end

function H.SheetFoot(sh, opts)
    sh.fline = UI:Rule(sh, { bottom = SH.FOOT_H, left = 1, right = 1 })
    sh.foot = UI:Text(sh, "body", "SUB")
    sh.foot:SetPoint("BOTTOMLEFT", SH.PAD, 17)
    sh.foot:SetText(opts.foot or "")
    sh.footIcon = sh:CreateTexture(nil, "ARTWORK")
    sh.footIcon:SetSize(14, 14)
    sh.footIcon:SetPoint("BOTTOMLEFT", SH.PAD, 16)
    sh.footIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    sh.footIcon:Hide()
    local okSpec = opts.ok
    if okSpec ~= nil and okSpec ~= false and type(okSpec) ~= "table" then okSpec = { text = okSpec } end
    if okSpec then
        sh.ok = UI:CreateSleekButton(sh, okSpec.text or "Save", okSpec.width or 110, 26, function()
            if okSpec.onClick then H.Safe("Sheet ok", okSpec.onClick, sh) end
        end, okSpec.kind or "primary")
        sh.ok:SetPoint("BOTTOMRIGHT", -SH.PAD, 10)
    end
    local cancel = opts.cancel
    if cancel == nil and okSpec then cancel = _G.CANCEL or "Cancel" end
    if cancel then
        sh.cancel = UI:CreateSleekButton(sh, cancel, 80, 26, function() sh:Close() end, "secondary")
        if sh.ok then sh.cancel:SetPoint("RIGHT", sh.ok, "LEFT", -6, 0)
        else sh.cancel:SetPoint("BOTTOMRIGHT", -SH.PAD, 10) end
    end
    local anchor = sh.cancel or sh.ok
    sh.err = UI:Text(sh, "body", "WARN", { justify = "RIGHT" })
    if anchor then sh.err:SetPoint("RIGHT", anchor, "LEFT", -10, 0)
    else sh.err:SetPoint("BOTTOMRIGHT", -SH.PAD, 17) end
    sh.err:Hide()
end

-- The floating sheet's frame: the dim, the panel (a 1 px black ring, the slate's gradient, a light edge).
function H.FloatingSheet(parent, opts)
    -- opts.child: made inside `parent` (still floating, dimming it), so it hides and comes back with that window
    local home = (opts.child and parent and parent ~= UIParent) and parent or UIParent
    local dim = CreateFrame("Frame", nil, home)
    dim:SetFrameStrata("DIALOG")
    dim:SetFrameLevel(3000)
    dim:EnableMouse(true)
    dim.bg = UI:Fill(dim, { 0, 0, 0, 0.6 }, "BACKGROUND")
    dim:Hide()
    local sh = CreateFrame("Frame", opts.name, home)
    sh:SetSize(opts.width or SH.W, opts.height or SH.H)
    sh:SetFrameStrata("DIALOG")
    sh:SetFrameLevel(3010)      -- high in its strata, so what is made in it climbs from there
    sh:SetToplevel(true)
    sh:SetClampedToScreen(true)
    sh.dim = dim
    sh.shadow = UI:Fill(sh, { 0, 0, 0, 1 }, "BACKGROUND", -8)
    sh.shadow:ClearAllPoints()
    sh.shadow:SetPoint("TOPLEFT", -1, 1)
    sh.shadow:SetPoint("BOTTOMRIGHT", 1, -1)
    sh.bg = sh:CreateTexture(nil, "BACKGROUND", nil, -7)
    sh.bg:SetAllPoints()
    UI:Gradient(sh.bg, "VERTICAL", { 0.078, 0.078, 0.094, 1 }, { 0.11, 0.11, 0.13, 1 })
    UI:AddEdges(sh, "BORDER")
    UI:SetEdgeColor(sh, 0.47, 0.47, 0.51, 0.75)
    sh.ownerOpt = opts.owner
    sh.ownerFrame = (parent and parent ~= UIParent) and parent or nil
    return sh
end

local SheetMethods = {}

function SheetMethods:Close() self:Hide() end
function SheetMethods:IsOpen() return self:IsShown() end
function SheetMethods:SetTitle(text)
    self.title:SetText(text or "")
    if self.pill then
        self.pill:ClearAllPoints()
        self.pill:SetPoint("LEFT", self.title, "LEFT", (self.title:GetStringWidth() or 0) + 9, 0)
    end
end
function SheetMethods:Error(text)
    self.err:SetText(text or "")
    self.err:SetShown(text ~= nil)
end
function SheetMethods:SetFoot(text, icon)
    if not self.foot then return end
    self.foot:SetText(text or "")
    self.footIcon:SetShown(icon ~= nil)
    self.foot:ClearAllPoints()
    if icon then
        self.footIcon:SetTexture(icon)
        self.foot:SetPoint("LEFT", self.footIcon, "RIGHT", 6, 0)
    else
        self.foot:SetPoint("BOTTOMLEFT", SH.PAD, 17)
    end
end
-- A pill after the title (UI:CreatePill); kind nil hides it.
function SheetMethods:SetPill(kind, text)
    if not self.pill then
        if not (kind and UI.CreatePill) then return end
        self.pill = UI:CreatePill(self, kind, text)
    elseif kind then
        if self.pill.SetPill then self.pill:SetPill(kind, text)
        else
            if self.pill.SetKind then self.pill:SetKind(kind) end
            if self.pill.SetText then self.pill:SetText(text) end
        end
    end
    self.pill:ClearAllPoints()
    self.pill:SetPoint("LEFT", self.title, "LEFT", (self.title:GetStringWidth() or 0) + 9, 0)
    self.pill:SetShown(kind ~= nil)
end
-- Over the window it belongs to (dimmed under it), or on the screen; a cover sheet just shows.
function SheetMethods:Open()
    if not self.cover then
        local owner = H.SheetOwner(self)
        local strata = "DIALOG"
        if owner and (STRATA_RANK[owner:GetFrameStrata()] or 0) > STRATA_RANK.DIALOG then
            strata = owner:GetFrameStrata()
        end
        if self:GetFrameStrata() ~= strata then
            self.dim:SetFrameStrata(strata)
            self:SetFrameStrata(strata)
        end
        self:ClearAllPoints()
        if owner then
            self:SetPoint("CENTER", owner, "CENTER", 0, 0)
            self.dim:ClearAllPoints()
            self.dim:SetAllPoints(owner)
            self.dim:Show()
        else
            self:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
            self.dim:Hide()
        end
    end
    self:Error(nil)
    self:Show()
    self:Raise()
end

function UI:CreateSheet(parent, opts)
    opts = opts or {}
    local cover = opts.cover and parent and parent ~= UIParent
    local sh
    if cover then
        sh = CreateFrame("Frame", opts.name, parent)
        sh:SetAllPoints(parent)
        sh:SetFrameLevel(parent:GetFrameLevel() + 20)
        sh.bg = UI:Fill(sh, opts.bg or "SURFACE_WINDOW", "BACKGROUND")
    else
        sh = H.FloatingSheet(parent, opts)
    end
    for k, fn in pairs(SheetMethods) do sh[k] = fn end
    sh:EnableMouse(true)
    sh.cover = cover and true or nil
    sh.fields = {}
    sh.title = UI:Text(sh, "title", "GOLD")
    sh.title:SetPoint("TOPLEFT", SH.PAD, -13)
    sh.title:SetText(opts.title or "")
    sh.close = UI:CreateCloseButton(sh, 20, function() sh:Close() end)
    sh.close:SetPoint("TOPRIGHT", -9, -10)
    if opts.rule ~= false then sh.hline = UI:Rule(sh, { top = SH.HEAD_H, left = 1, right = 1 }) end
    local hasFoot = (opts.ok ~= nil and opts.ok ~= false) or opts.cancel or opts.foot ~= nil
    if hasFoot then
        H.SheetFoot(sh, opts)
    else
        sh.err = UI:Text(sh, "body", "WARN", { justify = "RIGHT" })
        sh.err:SetPoint("BOTTOMRIGHT", -SH.PAD, 12)
        sh.err:Hide()
    end
    sh.body = CreateFrame("Frame", nil, sh)
    sh.body:SetPoint("TOPLEFT", SH.PAD, -(SH.HEAD_H + SH.PAD))
    sh.body:SetPoint("BOTTOMRIGHT", -SH.PAD, hasFoot and (SH.FOOT_H + SH.PAD) or SH.PAD)
    sh.onClose = opts.onClose
    sh:Hide()
    H.EscapeCloses(sh, function(self) self:Close() end)
    sh.child = (not cover and opts.child and parent and parent ~= UIParent) and true or nil
    sh:HookScript("OnHide", function(self)
        for _, eb in ipairs(self.fields or {}) do if eb.ClearFocus then eb:ClearFocus() end end
        -- a child sheet hidden only with its window is not closed: it (and its dim) come back with the window
        if self.child and self:IsShown() then return end
        if self.dim then self.dim:Hide() end
        if self.onClose then H.Safe("Sheet onClose", self.onClose, self) end
    end)
    if opts.pill then sh:SetPill(opts.pill[1] or opts.pill.kind, opts.pill[2] or opts.pill.text) end
    return sh
end

---------------------------------------------------------------------------
-- HUD frames
---------------------------------------------------------------------------
-- UI:CreateHudFrame(name, opts) -> frame: a small frame on the screen (a roll, the session bar, a meter's detail).
-- opts: { width (200), height (40), position (the key its place is kept under, UI:SavePosition; default the name;
--   false: none), default = { point, relTo, relPoint, x, y } (where it is without a saved place; else the centre),
--   strata ("MEDIUM"), toplevel, movable (true), isLocked = function(frame) -> bool (no drag while locked),
--   onMoved(frame) (after a drag, its place saved), escape (true: Escape closes it; needs a name),
--   close = true | function(frame) (the flat X, UI.HUD.CLOSE px, top right; true hides the frame),
--   look = "hud" (default: the HUD slate and edge) | "card" (the pop-ups' dark card with a gold edge) | "none",
--   clamp (true) }
-- frame:SetDragHandle(region) drags it by another frame (a banner); frame:SetLocked(b), :IsLocked(), :SavePlace(),
-- :RestorePlace(), :ResetPlace() (forgets the saved place and goes to the default).
-- UI:CreatePopover(w, h, opts) -> panel: what drops from a control (a list, a small editor): the dropdowns' surface
-- (DROP_BG, a 1 px DROP_EDGE, a soft shadow) on UIParent, clamped to the screen, hidden at first. The caller places
-- it (and sets panel.owner) and shows it. opts: { strata ("DIALOG"), name (a global name), shadow (true),
-- close = "catcher" (default: a click anywhere else closes it; a full-screen catcher under it takes that click) |
-- "through" (a click elsewhere closes it and still reaches what it was on; a click on panel.owner does not close it) |
-- false (the caller closes it) }. panel.catcher (with "catcher").
function UI:CreatePopover(w, h, opts)
    opts = opts or {}
    local strata = opts.strata or "DIALOG"
    local p = CreateFrame("Frame", opts.name, UIParent)
    p:SetFrameStrata(strata)
    p:SetToplevel(true)
    p:SetClampedToScreen(true)
    p:EnableMouse(true)
    p:SetSize(w or 200, h or 100)
    if opts.shadow ~= false and UI.SoftShadow then UI:SoftShadow(p, 12, 0.45, -4, 2) end
    p.bg = UI:Fill(p, "DROP_BG")
    UI:AddEdges(p, "BORDER")
    UI:SetEdgeColor(p, S:Color("DROP_EDGE"))
    p:Hide()
    local close = opts.close
    if close == nil then close = "catcher" end
    if close == "through" then
        p:SetScript("OnShow", function(self)
            if not C_EventUtils or not C_EventUtils.IsEventValid or C_EventUtils.IsEventValid("GLOBAL_MOUSE_DOWN") then
                self:RegisterEvent("GLOBAL_MOUSE_DOWN")
            end
        end)
        p:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
        p:SetScript("OnEvent", function(self)
            if not self:IsMouseOver() and not (self.owner and self.owner:IsMouseOver()) then self:Hide() end
        end)
    elseif close == "catcher" then
        local catcher = CreateFrame("Button", nil, UIParent)
        catcher:SetAllPoints(UIParent)
        catcher:SetFrameStrata(strata)
        catcher:SetFrameLevel(math.max(0, p:GetFrameLevel() - 1))
        catcher:RegisterForClicks("AnyUp")
        catcher:SetScript("OnClick", function() p:Hide() end)
        catcher:Hide()
        p.catcher = catcher
        p:SetScript("OnShow", function() catcher:Show() end)
        p:SetScript("OnHide", function() catcher:Hide() end)
    end
    return p
end

UI.HUD = { CLOSE = 18 }

function H.HudDragStart(f)
    if f:IsLocked() or not f:IsMovable() then return end
    f.cdlMoving = true
    f:StartMoving()
end

function H.HudDragStop(f)
    if not f.cdlMoving then return end
    f.cdlMoving = nil
    f:StopMovingOrSizing()
    f:SavePlace()
    if f.cdlOnMoved then H.Safe("HUD onMoved", f.cdlOnMoved, f) end
end

local HudMethods = {}

function HudMethods:IsLocked()
    if self.cdlLocked then return true end
    if self.cdlIsLocked then
        local ok, r = pcall(self.cdlIsLocked, self)
        return ok and r and true or false
    end
    return false
end
function HudMethods:SetLocked(b) self.cdlLocked = b and true or nil end
function HudMethods:SavePlace()
    if not self.cdlPosKey then return false end
    return UI:SavePosition(self, self.cdlPosKey)
end
function HudMethods:RestorePlace()
    local d = self.cdlDefault
    if self.cdlPosKey then
        if d then return UI:RestorePosition(self, self.cdlPosKey, d[1], d[2] or UIParent, d[3] or d[1], d[4] or 0, d[5] or 0) end
        return UI:RestorePosition(self, self.cdlPosKey)
    end
    self:ClearAllPoints()
    if d then self:SetPoint(d[1], d[2] or UIParent, d[3] or d[1], d[4] or 0, d[5] or 0)
    else self:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end
    return false
end
function HudMethods:ResetPlace()
    local windows = ns.db and ns.db.settings and ns.db.settings.windows
    if self.cdlPosKey and type(windows) == "table" then windows[self.cdlPosKey] = nil end
    return self:RestorePlace()
end
function HudMethods:SetDragHandle(region)
    local f = self
    region:EnableMouse(true)
    region:RegisterForDrag("LeftButton")
    region:SetScript("OnDragStart", function() H.HudDragStart(f) end)
    region:SetScript("OnDragStop", function() H.HudDragStop(f) end)
end

function UI:CreateHudFrame(name, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", name, UIParent)
    for k, fn in pairs(HudMethods) do f[k] = fn end
    local key = opts.position
    if key == nil then key = name end
    f.cdlPosKey = key or nil
    f.cdlDefault = opts.default
    f:SetSize(opts.width or 200, opts.height or 40)
    f:SetFrameStrata(opts.strata or "MEDIUM")
    if opts.toplevel then f:SetToplevel(true) end
    f:SetClampedToScreen(opts.clamp ~= false)
    f:EnableMouse(true)
    f.cdlOnMoved = opts.onMoved
    f.cdlIsLocked = opts.isLocked
    local look = opts.look or "hud"
    if look == "hud" then
        f.bg = UI:Fill(f, "HUD_BG", "BACKGROUND")
        UI:AddEdges(f, "BORDER")
        UI:SetEdgeColor(f, S:Color("HUD_EDGE"))
    elseif look == "card" then
        f.bg = UI:Fill(f, T.BG, "BACKGROUND")
        UI:AddEdges(f, "BORDER")
        local r, g, b = S:Color("GOLD")
        UI:SetEdgeColor(f, r, g, b, 0.55)
    end
    if opts.movable ~= false then
        f:SetMovable(true)
        f:SetDragHandle(f)
    end
    if opts.close then
        local fn = type(opts.close) == "function" and function() opts.close(f) end or nil
        f.close = UI:CreateCloseButton(f, UI.HUD.CLOSE, fn)
        f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -3)
    end
    if opts.escape and name and UISpecialFrames then tinsert(UISpecialFrames, name) end
    f:RestorePlace()
    return f
end
