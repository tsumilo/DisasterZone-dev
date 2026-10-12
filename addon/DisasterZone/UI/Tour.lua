if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Tour.lua", ...) then return end -- DisasterZone: UI/Tour.lua
-- Guided tours: a tutorial that runs on the real window. One control at a time is lit (the rest of the window is
-- dimmed), a box beside it says what it is for, and most steps go on once the member has done the thing themselves.
-- The engine knows nothing about what it explains; a tour is data (Data/Tours/*.lua):
--   Tour:Register(id, {
--       title = "Strategy board",
--       host = function() return frame end,     -- the window the tour runs on (what gets dimmed); nil: the screen
--       open = function(chapterIndex) end,      -- gets the window ready when the tour starts; false: can't start
--       alive = function() return bool end,     -- false: the tour ends (its window was closed, ...)
--       close = function(finished) end,
--       quiet = true,                           -- no "Tutorial finished" line (a one-step pointer, e.g. Show me)
--       chapters = { { key = "basics", title = "The basics", enter = function() end, steps = { step, ... } } },
--   })
-- A chapter may have its own host / open / alive (it runs on another window, or needs the window in another state)
-- and a group = "..." (a heading in the chapter menu, shown where it changes). open and enter run whenever the tour
-- comes into the chapter, from either side. More (1.3.5, the Welcome tour):
--       who = function() return bool end,     -- false: the chapter is left out for this player (another role's part)
--       demo = true,                          -- demo mode is on while the chapter runs (made-up data, nothing sent)
--       color = { r, g, b }, icon = atlas index,  -- the chapter's colour and icon (the box's kicker, the tour bar)
-- def.bar = true: a bar along the foot of the host shows the chapters (done, where I am) with Parts and Exit.
-- def.boxInside = true: the box stays inside the host (beside what is lit when there is room, else bottom right).
-- Tour:Start(id, chapter, opts): opts.only = { [chapter key] = true } runs only those chapters; opts.peek = true
-- runs a chapter whatever its who says (looking at another role's part, always on demo data); opts.resume = true
-- starts the chapter at the step it was left on.
--   step = {
--       title = "...", text = "..." | function(ctx),
--       anchor = function(ctx) return frame, ... end,   -- what is lit (several: the box around them all); no anchor:
--                                                       -- the whole window is dimmed and the box sits in its middle
--       side = "right" | "left" | "top" | "bottom",     -- where the box goes (when it fits)
--       hint = "...",                                   -- what to do, for a step the member does themselves
--       skip = function() return bool end,              -- true: the step is left out (nothing to show right now)
--       enter = function(ctx) end,                      -- the step starts: remember what done() compares with
--       done = function(ctx) return bool end,           -- polled; true: the step is done and the tour goes on
--                                                       -- (already true when the step starts, e.g. after Back:
--                                                       -- it waits for Next instead)
--       stay = true,                                    -- done: it waits for Next (what came of it is worth a look)
--       ghost = function(ctx) return { from = { frame, fx, fy }, to = { frame, fx, fy }, label = "Drag" } end,
--                                                       -- a cursor that shows the gesture (fx, fy: 0-1 from the
--                                                       -- frame's top left; no `to`: a click)
--   }
-- ctx is a table of the step's own (fresh each time the step starts). Finished chapters are remembered in the saved
-- variables (ns.db.tours[id]); nothing of a tour is ever sent to anyone.
local addonName, ns = ...

local Tour = ns:NewModule("Tour")

local max, min, floor = math.max, math.min, math.floor

local BOX_W = 330
local PAD = 4               -- the lit area is this much larger than the control
local MARGIN = 12           -- between the lit area and the box
local DIM = 0.62
local CHECK_EVERY = 0.15    -- seconds between two looks at done() and at where the control is
local ADVANCE_AFTER = 0.9   -- a step that was done stays this long ("Done!") before the next one
local GHOST_CYCLE = 2.6
local BAR_H = 32            -- the tour bar (def.bar)
local CHECK = "|TInterface\\RAIDFRAME\\ReadyCheck-Ready:11|t "

local S = ns.Style
local function UI() return ns.UI end

local tours, order = {}, {}
local run                   -- the tour running: { id, def, ci, si, step, ctx, doneAt, t0, moved, review }
local offer                 -- the "take the tour?" box: { id, def, anchor }
local offered = {}          -- [id] = offered this session
local ov, box, cursor, bar

---------------------------------------------------------------------------
-- Saved progress
---------------------------------------------------------------------------

local function saved(id)
    local db = ns.db
    if not db then return { done = {} } end
    if type(db.tours) ~= "table" then db.tours = {} end
    local t = db.tours[id]
    if type(t) ~= "table" then
        t = {}
        db.tours[id] = t
    end
    if type(t.done) ~= "table" then t.done = {} end
    if type(t.at) ~= "table" then t.at = {} end
    return t
end

-- The same progress for reading only: nothing is stored for a tour nobody started (demo mode saves nothing).
local function peek(id)
    local t = ns.db and type(ns.db.tours) == "table" and ns.db.tours[id]
    if type(t) ~= "table" then return { done = {}, at = {} } end
    return { seen = t.seen, done = type(t.done) == "table" and t.done or {}, at = type(t.at) == "table" and t.at or {} }
end

function Tour:Register(id, def)
    if not tours[id] then order[#order + 1] = id end
    tours[id] = def
end

function Tour:Get(id) return tours[id] end

-- { seen = was started or turned down, done = { [chapter key] = true }, at = { [chapter key] = step left on } }
function Tour:Progress(id) return saved(id) end
-- For reading only (seen, done, at): stores nothing for a tour not started.
function Tour:Peek(id) return peek(id) end

function Tour:IsRunning(id)
    return run ~= nil and (id == nil or run.id == id)
end

---------------------------------------------------------------------------
-- Where things are (in UIParent's units, from its bottom left)
---------------------------------------------------------------------------

local function rectOf(f)
    if not (type(f) == "table" and f.GetLeft and f.IsVisible and f:IsVisible()) then return nil end
    local l, b, w, h = f:GetLeft(), f:GetBottom(), f:GetWidth(), f:GetHeight()
    if not (l and b and w and h) then return nil end
    local sf = f.GetEffectiveScale and f or f:GetParent()
    local s = (sf and sf:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    return l * s, b * s, w * s, h * s
end

local function unionRect(...)
    local l, b, r, t
    for i = 1, select("#", ...) do
        local x, y, w, h = rectOf((select(i, ...)))
        if x then
            l, b = min(l or x, x), min(b or y, y)
            r, t = max(r or (x + w), x + w), max(t or (y + h), y + h)
        end
    end
    if not l then return nil end
    return l, b, r - l, t - b
end

local function screen()
    return UIParent:GetWidth() or 1024, UIParent:GetHeight() or 768
end

-- A step's function, called so that an error in a tour's data never breaks the window it explains.
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local res = { pcall(fn, ...) }
    if not res[1] then
        ns:Debug("Tour: %s", tostring(res[2]))
        return nil
    end
    return unpack(res, 2, 8)
end

---------------------------------------------------------------------------
-- Frames: the dimming, the gold frame around what is lit, the box, the cursor
---------------------------------------------------------------------------

local function put(t, l, b, w, h)
    if w < 0.5 or h < 0.5 then
        t:Hide()
        return
    end
    t:ClearAllPoints()
    t:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, b)
    t:SetSize(w, h)
    t:Show()
end

local function ensureFrames()
    if ov then return end
    -- above the windows (HIGH), below their menus, prompts and tooltips; it never takes the mouse: the lit
    -- control is the real one and is clicked through it
    ov = CreateFrame("Frame", "DisasterZoneTour", UIParent)
    ov:SetAllPoints(UIParent)
    ov:SetFrameStrata("DIALOG")
    ov:EnableMouse(false)
    ov.dim, ov.edge = {}, {}
    for i = 1, 4 do
        ov.dim[i] = ov:CreateTexture(nil, "BACKGROUND")
        ov.dim[i]:SetColorTexture(0, 0, 0, DIM)
        ov.edge[i] = ov:CreateTexture(nil, "ARTWORK")
        ov.edge[i]:SetColorTexture(S:Color("GOLD"))
    end

    -- the box: the shared HUD frame (the pop-ups' card look, its X), dragged aside when in the way (it goes back to its
    -- place at the next step); never saved anywhere
    box = UI():CreateHudFrame("DisasterZoneTourBox", { width = BOX_W, height = 120, position = false, look = "card",
        strata = "DIALOG", close = function() Tour:Stop() end })
    box:SetParent(ov)
    box:SetFrameStrata("DIALOG")
    box:SetFrameLevel(ov:GetFrameLevel() + 20)
    box:HookScript("OnDragStart", function() if run then run.moved = true end end)
    UI():AttachTooltip(box.close, "End the tutorial",
        "The chapters you finished are remembered; the Tutorial button starts it again.", { anchor = "ANCHOR_TOP" })
    box.chapter = UI():Text(box, "caps", "SUB")
    box.chapter:SetPoint("TOPLEFT", S.PAD + 2, -S.PAD)
    box.chapter:SetPoint("RIGHT", -30, 0)
    box.title = UI():Text(box, "page", "GOLD", { wrap = true, width = BOX_W - 24 })
    box.title:SetPoint("TOPLEFT", S.PAD + 2, -28)
    box.text = UI():Text(box, "body", "TEXT", { wrap = true, width = BOX_W - 24 })
    box.text:SetPoint("TOPLEFT", box.title, "BOTTOMLEFT", 0, -S.GAP)
    box.text:SetSpacing(2)
    box.hint = UI():Text(box, "emph", "GOLD", { wrap = true, width = BOX_W - 24 })
    box.hint:SetPoint("TOPLEFT", box.text, "BOTTOMLEFT", 0, -S.PAD)
    box.count = UI():Text(box, "small", "SUB")
    box.count:SetPoint("BOTTOMLEFT", S.PAD + 2, S.PAD + 6)
    box.next = UI():CreateSleekButton(box, "Next", 100, S.BTN_H, function() Tour:Next() end, "primary")
    box.next:SetPoint("BOTTOMRIGHT", -S.PAD, S.PAD)
    box.back = UI():CreateSleekButton(box, "Back", 70, S.BTN_H, function() Tour:Back() end)
    box.back:SetPoint("RIGHT", box.next, "LEFT", -6, 0)

    -- the cursor that shows a gesture: its tip is the frame's top left
    cursor = CreateFrame("Frame", nil, ov)
    cursor:SetFrameLevel(ov:GetFrameLevel() + 40)
    cursor:SetSize(28, 28)
    cursor.tex = cursor:CreateTexture(nil, "OVERLAY")
    cursor.tex:SetAllPoints()
    cursor.tex:SetTexture("Interface\\CURSOR\\Point")
    cursor.press = cursor:CreateTexture(nil, "ARTWORK")
    cursor.press:SetSize(12, 12)
    cursor.press:SetPoint("CENTER", cursor, "TOPLEFT", 2, -2)
    local gr, gg, gb = S:Color("GOLD")
    cursor.press:SetColorTexture(gr, gg, gb, 0.85)
    cursor.label = UI():Text(cursor, "small", "GOLD")
    cursor.label:SetPoint("LEFT", cursor, "RIGHT", -2, -8)
    cursor.labelBg = cursor:CreateTexture(nil, "BACKGROUND")
    cursor.labelBg:SetPoint("TOPLEFT", cursor.label, "TOPLEFT", -4, 3)
    cursor.labelBg:SetPoint("BOTTOMRIGHT", cursor.label, "BOTTOMRIGHT", 4, -3)
    cursor.labelBg:SetColorTexture(0, 0, 0, 0.8)
    cursor:Hide()

    -- the tour bar (def.bar): a chip per chapter of this run (done / where I am / to come; a click goes there),
    -- the chapter menu and Exit, along the foot of the host; the same HUD card as the box
    bar = UI():CreateHudFrame("DisasterZoneTourBar", { width = 400, height = BAR_H, position = false, look = "card",
        strata = "DIALOG", movable = false })
    bar:SetParent(ov)
    bar:SetFrameStrata("DIALOG")
    bar:SetFrameLevel(ov:GetFrameLevel() + 20)
    bar.label = UI():Text(bar, "caps", "GOLD")
    bar.label:SetPoint("LEFT", S.PAD, 0)
    bar.chips = {}
    bar.exit = UI():CreateSleekButton(bar, "Exit", 50, S.BTN_H, function() Tour:Stop() end)
    bar.exit:SetPoint("RIGHT", -4, 0)
    UI():AttachTooltip(bar.exit, "End the tour", "Where you stopped is remembered: Settings > Tutorials goes on from there.",
        { anchor = "ANCHOR_TOP" })
    bar.parts = UI():CreateSleekButton(bar, "Parts", 56, S.BTN_H, function(self) if run then Tour:Menu(self, run.id) end end)
    bar.parts:SetPoint("RIGHT", bar.exit, "LEFT", -4, 0)
    bar:Hide()

    local acc = 0
    ov:SetScript("OnUpdate", function(_, elapsed)
        Tour:Animate()
        acc = acc + (elapsed or 0)
        if acc >= CHECK_EVERY then
            acc = 0
            Tour:Tick()
        end
    end)
    ov:Hide()
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

-- The box beside the lit area (l, b, w, h), on the side asked for when it fits there; nil: the middle of the host.
-- inside (def.boxInside): the box stays inside the host (above the tour bar), else anywhere on the screen.
local function placeBox(l, b, w, h, side, hl, hb, hw, hh, inside)
    local sw, sh = screen()
    -- the area the box may use: x0..x1, y0..y1
    local x0, y0, x1, y1 = 0, 0, sw, sh
    if inside then
        x0, x1, y1 = hl + 6, hl + hw - 6, hb + hh - 6
        y0 = hb + ((bar and bar:IsShown()) and (BAR_H + 14) or 6)
    end
    local bw, bh = box:GetWidth() or BOX_W, box:GetHeight() or 120
    local x, y
    if not l then
        x, y = hl + (hw - bw) / 2, hb + (hh - bh) / 2
    else
        local fits = {
            right = l + w + MARGIN + bw <= x1,
            left = l - MARGIN - bw >= x0,
            bottom = b - MARGIN - bh >= y0,
            top = b + h + MARGIN + bh <= y1,
        }
        local pick
        for _, s in ipairs({ side or "right", "right", "left", "bottom", "top" }) do
            if fits[s] then
                pick = s
                break
            end
        end
        if pick == "right" then x, y = l + w + MARGIN, b + h - bh
        elseif pick == "left" then x, y = l - MARGIN - bw, b + h - bh
        elseif pick == "bottom" then x, y = l, b - MARGIN - bh
        elseif pick == "top" then x, y = l, b + h + MARGIN
        elseif inside then x, y = x1 - bw - MARGIN, y0 + MARGIN    -- no room around it: the host's bottom right
        else x, y = l + w - bw - MARGIN, b + MARGIN end     -- no room around it: inside, bottom right
    end
    x, y = max(x0 + 4, min(x1 - bw - 4, x)), max(y0 + 4, min(y1 - bh - 4, y))
    box:ClearAllPoints()
    box:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
end

local function hideAll(list)
    for _, t in ipairs(list) do t:Hide() end
end

local function layout()
    if not ov then return end
    local view = run or offer
    if not view then return end
    local sw, sh = screen()
    local hl, hb, hw, hh = 0, 0, sw, sh
    local ch = run and run.def.chapters[run.ci]
    local host = call(ch and ch.host or view.def.host)
    if host then
        local a, b, c, d = rectOf(host)
        if a then hl, hb, hw, hh = a, b, c, d end
    end
    local anchor = offer and offer.anchor or (run and run.step.anchor)
    local l, b, w, h
    if anchor then l, b, w, h = unionRect(call(anchor, run and run.ctx)) end
    if l then
        l, b, w, h = l - PAD, b - PAD, w + 2 * PAD, h + 2 * PAD
        -- the gold frame around it
        put(ov.edge[1], l - 2, b + h, w + 4, 2)
        put(ov.edge[2], l - 2, b - 2, w + 4, 2)
        put(ov.edge[3], l - 2, b, 2, h)
        put(ov.edge[4], l + w, b, 2, h)
    else
        hideAll(ov.edge)
    end
    if offer then
        hideAll(ov.dim)
    elseif l then
        -- the host dimmed around it
        local t, r = min(hb + hh, b + h), min(hl + hw, l + w)
        local bb, ll = max(hb, b), max(hl, l)
        put(ov.dim[1], hl, hb, hw, bb - hb)
        put(ov.dim[2], hl, t, hw, hb + hh - t)
        put(ov.dim[3], hl, bb, ll - hl, t - bb)
        put(ov.dim[4], r, bb, hl + hw - r, t - bb)
    elseif anchor then
        -- what the step shows isn't on the screen: nothing is dimmed, the window stays usable
        hideAll(ov.dim)
    else
        put(ov.dim[1], hl, hb, hw, hh)
        for i = 2, 4 do ov.dim[i]:Hide() end
    end
    if bar and bar:IsShown() then
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", hl + hw / 2, hb + 8)
    end
    if not (run and run.moved) then
        if anchor and not l then
            -- the bottom of the host, out of the way
            placeBox(hl + (hw - BOX_W) / 2, hb + 40, BOX_W, 0, "bottom", hl, hb, hw, hh, view.def.boxInside)
        else
            placeBox(l, b, w, h, offer and "bottom" or run.step.side, hl, hb, hw, hh, view.def.boxInside)
        end
    end
end

-- The texts and buttons of the box.
local function paint()
    if not box then return end
    local chapter, title, text, hint, count, nextText, backText, primary, color
    if offer then
        chapter, title = "TUTORIAL", offer.def.offerTitle or ("New to the " .. (offer.def.title or "this window") .. "?")
        text = offer.def.offerText or "Take the guided tour."
        nextText, backText, primary = "Start", "Not now", true
    elseif run then
        local def, step = run.def, run.step
        local ch = def.chapters[run.ci]
        if ch.color then
            -- a part of a tour with a bar: the part in its colour (the tour's name is on the bar)
            color = ch.color
            chapter = (ch.title or ""):upper() .. (run.peek and "  \194\183  A LOOK AROUND" or "")
            count = ("Step %d of %d"):format(run.si, #ch.steps)
        else
            chapter = ((def.title or "") .. "  \194\183  " .. (ch.title or "")):upper()
            count = ("%d / %d"):format(run.si, #ch.steps)
        end
        title = step.title or ""
        text = type(step.text) == "function" and call(step.text, run.ctx) or step.text or ""
        local lastStep, lastChapter = run.si == #ch.steps, not Tour:HasAfter(run.ci)
        if step.done and not run.doneAt and not run.review then
            hint = step.hint and ("|cffffd100Your turn:|r " .. step.hint) or nil
            nextText, primary = "Skip step", false
        else
            if run.doneAt then hint = "|cff33ff99Done!|r" end
            nextText = lastStep and (lastChapter and "Finish" or (def.bar and "Next part" or "Next chapter")) or "Next"
            primary = true
        end
        if run.si > 1 or Tour:HasBefore(run.ci) then backText = "Back" end
    else
        return
    end
    box.chapter:SetText(chapter or "")
    box.chapter:SetTextColor(S:Color(color or "SUB"))
    box.title:SetText(title or "")
    box.text:SetText(text or "")
    box.hint:SetText(hint or "")
    box.hint:SetShown(hint ~= nil)
    box.count:SetText(count or "")
    box.next:SetText(nextText)
    box.next:SetKind(primary and "primary" or "secondary")
    box.back:SetShown(backText ~= nil)
    box.back:SetText(backText or "")
    box.close:SetShown(offer == nil)
    local height = 28 + (box.title:GetStringHeight() or 16) + S.GAP + (box.text:GetStringHeight() or 14)
    if hint then height = height + S.PAD + (box.hint:GetStringHeight() or 14) end
    box:SetHeight(height + 16 + S.BTN_H + S.PAD)
    Tour:PaintBar()
    layout()
end

---------------------------------------------------------------------------
-- The cursor that shows a gesture
---------------------------------------------------------------------------

local function pointOf(p)
    if type(p) ~= "table" then return nil end
    local l, b, w, h = rectOf(p[1])
    if not l then return nil end
    return l + (p[2] or 0.5) * w, b + (1 - (p[3] or 0.5)) * h
end

function Tour:Animate()
    if not cursor then return end
    local g = run and not run.doneAt and not run.review and run.step.ghost and call(run.step.ghost, run.ctx)
    -- never over the member's own drag
    if not g or (IsMouseButtonDown and IsMouseButtonDown("LeftButton")) then
        cursor:Hide()
        return
    end
    local x1, y1 = pointOf(g.from)
    if not x1 then
        cursor:Hide()
        return
    end
    local x2, y2 = pointOf(g.to)
    local p = ((GetTime() or 0) - (run.t0 or 0)) % GHOST_CYCLE
    local alpha, x, y, pressed = 1, x1, y1, false
    if p < 0.4 then
        alpha = p / 0.4
    elseif p < 1.6 then
        local k = (p - 0.4) / 1.2
        if x2 then
            k = k * k * (3 - 2 * k)
            x, y = x1 + (x2 - x1) * k, y1 + (y2 - y1) * k
            pressed = true
        else
            -- a click: two presses
            pressed = (k > 0.15 and k < 0.4) or (k > 0.6 and k < 0.85)
        end
    else
        if x2 then x, y = x2, y2 end
        pressed = x2 ~= nil and p < 1.9
        if p > 2.1 then alpha = max(0, 1 - (p - 2.1) / 0.5) end
    end
    cursor:ClearAllPoints()
    cursor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    cursor:SetAlpha(alpha)
    cursor.press:SetShown(pressed)
    cursor.label:SetText(g.label or "")
    cursor.labelBg:SetShown(g.label ~= nil)
    cursor:Show()
end

---------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------

local function chapterIndex(def, chapter)
    if type(chapter) == "number" and def.chapters[chapter] then return chapter end
    for i, ch in ipairs(def.chapters) do
        if ch.key == chapter then return i end
    end
    return nil
end

-- Is a chapter part of this run? Not when the run picked others (opts.only), or it is another role's (who) and the
-- run isn't a look around (peek).
local function included(r, ci)
    local ch = r.def.chapters[ci]
    if not ch then return false end
    if r.only and not r.only[ch.key] then return false end
    if ch.who and not r.peek and call(ch.who) ~= true then return false end
    return true
end

-- Demo mode while a chapter needs it (ch.demo, or a look around): switched on by the tour, off again when the tour
-- leaves for a chapter without it or ends. Demo mode the member switched on themselves is left alone.
local function demoOn() return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() and true or false end
local function setDemo(r, want)
    if not (ns.Demo and ns.Demo.SetEnabled) then return end
    if want and not demoOn() then
        ns.Demo:SetEnabled(true)
        r.demoBy = true
    elseif not want and r.demoBy then
        r.demoBy = nil
        if demoOn() then ns.Demo:SetEnabled(false) end
    end
end

-- Goes to a step. dir (1 / -1): where to go on from a step that is left out. Coming into a chapter gets its window
-- ready first; when that fails the tour ends.
local function go(ci, si, dir)
    local def = run.def
    dir = dir or 1
    while true do
        local ch = def.chapters[ci]
        if not ch then return Tour:Stop(dir > 0) end
        if not included(run, ci) then
            -- another role's part, or not picked: on to the next (Back before the first: stay)
            if dir < 0 and not Tour:HasBefore(ci) then return paint() end
            ci, si = ci + dir, dir > 0 and 1 or "last"
        elseif run.opened ~= ci then
            setDemo(run, ch.demo or run.peek)
            local open = ch.open or def.open
            if open and call(open, ci) ~= true then return Tour:Stop() end
            if not run then return end
            run.opened = ci
            call(ch.enter)
        end
        if run.opened == ci then
            if si == "last" then si = #ch.steps end
            local step = ch.steps[si]
            if step and not (step.skip and call(step.skip) == true) then
                run.ci, run.si, run.step, run.ctx = ci, si, step, {}
                run.doneAt, run.moved, run.t0 = nil, nil, GetTime() or 0
                call(step.enter, run.ctx)
                -- done already (Back to it, or the member did it before it came up): it reads as a plain step and
                -- waits for Next, instead of going straight on again
                run.review = step.done ~= nil and call(step.done, run.ctx) == true
                return paint()
            end
            -- left out, or past the chapter's end
            si = si + dir
            if si > #ch.steps then
                local p = saved(run.id)
                if not run.peek then p.done[ch.key] = true end
                p.at[ch.key] = nil
                ci, si = ci + 1, 1
            elseif si < 1 then
                if not Tour:HasBefore(ci) then return paint() end     -- nothing before it: stay
                ci, si = ci - 1, "last"
            end
        end
    end
end

-- Is there a chapter of the running tour before chapter ci (one this run includes)?
function Tour:HasBefore(ci)
    if not run then return false end
    for i = (ci or run.ci) - 1, 1, -1 do
        if included(run, i) then return true end
    end
    return false
end

-- Is there a chapter of the running tour after chapter ci (one this run includes)?
function Tour:HasAfter(ci)
    if not run then return false end
    for i = (ci or run.ci) + 1, #run.def.chapters do
        if included(run, i) then return true end
    end
    return false
end

-- The chapters this run includes, in order (index list): the bar's chips, the Parts menu.
local function includedList(r)
    local out = {}
    for i in ipairs(r.def.chapters) do
        if included(r, i) then out[#out + 1] = i end
    end
    return out
end

-- The tour bar's chips: done (green, a tick), where I am (its colour, the step), to come (grey).
function Tour:PaintBar()
    if not bar then return end
    if not (run and run.def.bar) then
        bar:Hide()
        return
    end
    local def, done = run.def, saved(run.id).done
    bar.label:SetText(((def.title or "") .. (run.peek and " \194\183 a look around" or "")):upper())
    local x = 10 + (bar.label:GetStringWidth() or 80) + 10
    local list = includedList(run)
    for n, ci in ipairs(list) do
        local ch = def.chapters[ci]
        local c = bar.chips[n]
        if not c then
            c = UI():CreateChip(bar, { onClick = function(self) Tour:Jump(self.ci) end })
            UI():AttachTooltip(c, "Go to this part", "From its first step.", { anchor = "ANCHOR_TOP" })
            bar.chips[n] = c
        end
        c.ci = ci
        local col = ch.color or S.C.GOLD
        local label = ch.title or ch.key
        if ci == run.ci then
            c:Set(label .. "  " .. S:Wrap("TEXT", run.si .. "/" .. #ch.steps), col)
            c:SetSelected(true)
            c:SetAlpha(1)
        elseif done[ch.key] and not run.peek then
            c:Set(CHECK .. label, S.C.OK)
            c:SetSelected(false)
            c:SetAlpha(1)
        else
            c:Set(label, col)
            c:SetSelected(false)
            c:SetAlpha(0.6)
        end
        c:ClearAllPoints()
        c:SetPoint("LEFT", bar, "LEFT", x, 0)
        c:Show()
        x = x + c:GetWidth() + 5
    end
    for n = #list + 1, #bar.chips do bar.chips[n]:Hide() end
    bar:SetWidth(x + 6 + bar.parts:GetWidth() + 4 + bar.exit:GetWidth() + 4)
    bar:Show()
end

-- Goes to another chapter of the running tour (the bar's chips), at its first step.
function Tour:Jump(ci)
    if not run or not included(run, ci) or ci == run.ci then return end
    local r = run
    if r.si > 1 then saved(r.id).at[r.def.chapters[r.ci].key] = r.si end
    go(ci, 1, 1)
end

-- Starts a tour at a chapter (its index or key; nil: the first one not finished yet, else the first). opts: see the
-- top of the file (only, peek, resume).
function Tour:Start(id, chapter, opts)
    local def = tours[id]
    if not def then return false end
    if run then self:Stop() end
    offer = nil
    opts = type(opts) == "table" and opts or {}
    local progress = saved(id)
    local r = { id = id, def = def, only = opts.only, peek = opts.peek and true or nil }
    local ci = chapterIndex(def, chapter)
    if ci and not included(r, ci) then return false end
    if not ci then
        for i, ch in ipairs(def.chapters) do
            if included(r, i) and not progress.done[ch.key] then
                ci = i
                break
            end
        end
        if not ci then
            for i in ipairs(def.chapters) do
                if included(r, i) then
                    ci = i
                    break
                end
            end
        end
    end
    if not ci then return false end
    local si = 1
    local at = opts.resume and progress.at[def.chapters[ci].key]
    if at and def.chapters[ci].steps[at] then si = at end
    ensureFrames()
    run = r
    go(ci, si)
    if not run then return false end
    progress.seen = true
    ov:Show()
    paint()
    return true
end

function Tour:Stop(finished)
    local r = run
    run, offer = nil, nil
    if ov then ov:Hide() end
    if cursor then cursor:Hide() end
    if bar then bar:Hide() end
    if r then
        -- where an unfinished part was left (Settings > Tutorials goes on from there)
        local ch = r.ci and r.def.chapters[r.ci]
        if ch and not finished and not r.peek then
            saved(r.id).at[ch.key] = r.si > 1 and r.si or nil
        end
        setDemo(r, false)
        call(r.def.close, finished and true or false)
        if finished and not r.def.quiet then ns:Print("Tutorial finished: %s.", r.def.title or r.id) end
        ns:Fire("TOUR_CHANGED", r.id)
    end
end

function Tour:Next()
    if offer then return self:Start(offer.id) end
    if not run then return end
    go(run.ci, run.si + 1, 1)
end

function Tour:Back()
    if offer then
        saved(offer.id).seen = true
        offer = nil
        ov:Hide()
        return
    end
    if not run then return end
    if run.si > 1 or self:HasBefore(run.ci) then go(run.ci, run.si - 1, -1) end
end

-- Looks at the step: has the member done it, is its window still there, has the control moved.
function Tour:Tick()
    if offer then
        if not unionRect(call(offer.anchor)) then
            -- its button went away with its window: ask again the next time
            offered[offer.id] = nil
            offer = nil
            ov:Hide()
            return
        end
        return layout()
    end
    if not run then return end
    local alive = run.def.chapters[run.ci].alive or run.def.alive
    if alive and call(alive) ~= true then return self:Stop() end
    if run.doneAt then
        if not run.step.stay and (GetTime() or 0) - run.doneAt >= ADVANCE_AFTER then return self:Next() end
    elseif run.step.done and not run.review and call(run.step.done, run.ctx) == true then
        run.doneAt = GetTime() or 0
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        paint()
        return
    end
    layout()
end

-- Offers a tour that was never started or turned down (once per session): a box under `anchor()` with Start and
-- Not now. Returns true when the box is shown.
function Tour:Offer(id, anchor)
    local def = tours[id]
    if not def or run or offer or offered[id] or peek(id).seen then return false end
    if not unionRect(call(anchor)) then return false end
    offered[id] = true
    ensureFrames()
    offer = { id = id, def = def, anchor = anchor }
    ov:Show()
    paint()
    return true
end

-- The chapters as a menu (the Tutorial button).
-- The chapters of a tour into a menu (the tutorial's own menu, the strategy board's ? menu): grouped under grey
-- titles (def.menuGroups can word a group for the menu), the finished ones marked done; End the tutorial while it runs.
function Tour:BuildMenu(root, id)
    local def = tours[id]
    if not def then return end
    local done = peek(id).done
    -- the running tour's own chapters (its picks, a look around); else the ones for my roles
    local r = (run and run.id == id) and run or { def = def }
    local group, n = nil, 0
    for i, ch in ipairs(def.chapters) do
        if included(r, i) then
            if ch.group and ch.group ~= group then
                group = ch.group
                root:CreateTitle("|cff808080" .. (def.menuGroups and def.menuGroups[group] or group) .. "|r")
            end
            n = n + 1
            local label = ("%d. %s%s"):format(n, ch.title, done[ch.key] and "  |cff33ff99done|r" or "")
            if r == run then
                root:CreateButton(label, function() Tour:Jump(i) end)
            else
                root:CreateButton(label, function() Tour:Start(id, i) end)
            end
        end
    end
    if run and run.id == id then
        root:CreateDivider()
        root:CreateButton(def.bar and "End the tour" or "End the tutorial", function() Tour:Stop() end)
    end
end

function Tour:Menu(owner, id)
    local def = tours[id]
    if not def then return end
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(def.menuTitle or ((def.title or id) .. " tutorial"))
        Tour:BuildMenu(root, id)
    end)
end

-- Would this chapter run for me now (not another role's)? id, chapter key.
function Tour:IsForMe(id, key)
    local def = tours[id]
    local ci = def and chapterIndex(def, key)
    return ci ~= nil and included({ def = def }, ci)
end

-- What is on the screen (for tests): nil when nothing is.
function Tour:GetState()
    if offer then return { offer = offer.id } end
    if not run then return nil end
    local ch = run.def.chapters[run.ci]
    local parts = {}
    for _, i in ipairs(includedList(run)) do parts[#parts + 1] = run.def.chapters[i].key end
    return { id = run.id, chapter = ch.key, ci = run.ci, si = run.si, steps = #ch.steps, title = run.step.title,
             interactive = run.step.done ~= nil, done = run.doneAt ~= nil, review = run.review == true,
             lit = run.step.anchor ~= nil and unionRect(call(run.step.anchor, run.ctx)) ~= nil,
             anchored = run.step.anchor ~= nil, parts = parts, peek = run.peek == true,
             demo = run.demoBy == true, bar = bar ~= nil and bar:IsShown() }
end
