if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SwingTimerHUD.lua", ...) then return end -- DisasterZone: swing timer HUD.
-- The on-screen part of Core/SwingTimer.lua, and the ring every timer class tool shares (ns.SwingRing: the hunter's
-- shot timer, UI/ShotTimerHUD.lua, is the same ring with its own driver). The swing is a ring of flat strokes around
-- the next press: gold fills clockwise from 12 o'clock, the press window orange, the server's window dim red; it
-- flashes when a swing lands and glows while the window is open.
-- The next press sits in the middle with a round cooldown swipe: dark where time is left until it is due, gone (full
-- colour, a small pop) when it is time to press. Notes from the earlier bar layout:
--   queue   NEXT: the next press large in a gold frame (its name and what to do), the three after it smaller,
--           Judgement (off the GCD) on the left
--   bar     the swing in a dark panel with a gold rim: gold fill and spark, the orange press zone (the twist window
--           moved one round trip earlier, the latency bracket under it), the server's real window as a dim red edge,
--           a blue line where a GCD pressed now would end (red when it would run through the window), the weapon on
--           the left and the seal on the right
--   dots    the last swings: green twisted, gold late, red clipped, grey plain
--   lane    the planner's next ~7 s: swings, twist windows and every GCD block it placed (fillers in blue)
-- When auto attack is not running it rests: an empty bar and nothing else moves.
-- Style (settings <prefix>.style): "bar", "lane" or "both". Moved in Edit layout (/dz edit).
-- Themes: the face and the lane come in the class tool themes (UI/RingFace.lua builds them; each timer its own,
-- <prefix>.theme; twist practice always Halo).
-- The frame is a UI:CreateHudFrame (no look of its own: the ring is the face; placed by Core/Layout.lua, item <prefix>,
-- which reads the old <prefix>.pos until it is moved; Edit layout shows it while editing). Texts are UI:Text on the type scale, the
-- lane the HUD surface (ns.Style HUD_BG), its colours the tokens (D1: the deep gold for the swing ticks). The ring's
-- cells and their colours are drawn by UI/RingFace.lua.
--
-- A driver D tells the ring what to draw (fields and methods, all required unless marked optional):
--   prefix, frameName, layoutName        settings prefix ("swing" = its layout item), the frame's global name, its name
--   layoutOrder                          (optional) its place in Edit layout's list
--   Get(path, default)                   a setting under the prefix
--   IsActive(), IsDemo(), Practicing()   the tool runs / demo mode / a practice owns the ring (optional)
--   DefaultPos()                         x, y from the screen's center when nothing is saved (optional)
--   Current()                            nil = rest; else { snap = { gcd }, plan = { steps = { { key, at } } } }
--   Face(cur, now)                       { from, to (the cycle the ring shows), z0, z1 (the press window, or nil),
--                                          hot (the window is the next press), red0 (the dim red from here to `to`),
--                                          landed (optional: the time of the last hit; the ring flashes when it
--                                          changes; without it, when `to` jumps on), extraAt (optional: flash too) }
--   Badge()                              icon, text for the small badge on the ring (nil hides it)
--   RestIcon()                           the icon in the middle while resting
--   Icon(key), Short(key), NameOf(key)   a step's icon, its lane label, its name
--   FILLERS                              keys drawn blue on the lane
--   FADE                                 optional: the press window fades from bright (its start: best) to dim (its
--                                        end: still worth it, but late), on the ring and the lane; without it the
--                                        lane's window brightens toward its end (the twist lands there)
--   Lane(cur, now)                       marks { { t, strong } } (up to 4) and windows { { t0, t1 } } for the lane
--   StepWidth(step, snap)                how long a step's lane block is (optional: the GCD)
--   VARIANT                              optional: the face's variant (UI/RingFace.lua RF.VARIANT, "warrior"), then
--   Extra(cur, now)                      what RingFace:PaintExtra draws every frame, and
--   RestExtra()                          { oh (true: show the empty off-hand cycle), rage, line } while resting
--   StanceIcon(n)                        optional: the icon of stance n for a step's .stance (warrior stance dancing)
-- A tool with situations (Core/Situation.lua, registered under its prefix) gets the situation chip under its face
-- (<prefix>.sit.show): cur.snap.sit (or cur.sit) is the situation Info; the next press flashes when it changes.
local addonName, ns = ...

local UI = ns.UI
local S = ns.Style

local floor, max, min, sin = math.floor, math.max, math.min, math.sin
local strformat = string.format

local LANE_W, LANE_SPAN, LANE_BACK = 500, 7.5, 0.5
local GOLD = S.C.GOLD_DEEP                 -- (D1: the swing ticks are fills)
local FILLER = S.C.YOU                     -- (a filler's block: the blue of "you can fit this")

local function Ease(x) return 1 - (1 - x) * (1 - x) end

-- Demo mode's keys on the next presses (made up, like an action bar's: nothing is read or bound).
local DEMO_KEYS = { sob = "2", cs = "3", soc = "1", judge = "S-E", exo = "4", cons = "5", steady = "2", arcane = "3",
                    multi = "M4", kc = "F", bt = "2", ww = "3", ms = "2", slam = "4", hs = "Q", cleave = "S-Q",
                    shout = "5", rampage = "S-5", exe = "E", op = "S-2", ham = "R", brage = "S-R", sweep = "S-F",
                    rend = "S-4", hoj = "6", volley = "S-3", etrap = "T", conc = "C", aimed = "4", vsting = "V",
                    ssting = "S-V", wclip = "Z" }

-- The chip's words and icon for a situation Info (Core/Situation.lua): kind, icon, coords, text.
local PACK_ICON, ONE_ICON = "Interface\\Icons\\Ability_Warrior_Cleave", "Interface\\Icons\\INV_Sword_27"
local CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local function ChipLook(sit)
    if sit.held then return "held", sit.held.icon, nil, strformat("%s in reach", sit.held.name or "") end
    if sit.kind == "player" then
        local c = CLASS_ICON_TCOORDS and sit.cls and CLASS_ICON_TCOORDS[sit.cls]
        return "player", c and CIRCLES or "Interface\\Icons\\Achievement_Arena_2v2_7", c,
            sit.who and strformat("Player · %s", sit.who) or "Player"
    end
    if sit.kind == "pack" then
        return "pack", PACK_ICON, nil, (sit.n or 0) > 0 and strformat("Pack · %d", sit.n) or "Pack"
    end
    return "single", ONE_ICON, nil, "One target"
end


-- ---------------------------------------------------------------------------------------------------------------
-- The ring HUD for a driver (see the header)
-- ---------------------------------------------------------------------------------------------------------------
local function NewRing(D)
    local R = { D = D }
    local frame
    local zoneWasOpen
    local lastTo, lastLanded, flashAt, shownKey, shownAt, lastExtra = nil, nil, nil, nil, 0, nil
    local swipeFrom, wasDue = nil, false   -- (the middle icon's swipe: since when this press has been the next one)
    local lastSit                          -- (the situation chip's last look: a change flashes the next press)
    local situations = ns.Situation and ns.Situation:Tool(D.prefix) ~= nil
    local rested, restIcon, restBadge, restExtra = false, nil, nil, nil   -- (Rest's look is on, for these)

    local function Get(path, default) return D.Get(path, default) end
    local function Practicing() return D.Practicing and D:Practicing() or false end

    -- The key a step's spell is on (style A: the corner of its icon), or "" (off, waiting, on no bound button).
    local function KeyOf(key)
        if key == "wait" or not Get("keys", true) then return "" end
        if D:IsDemo() then return DEMO_KEYS[key] or "1" end
        local KB = ns.KeyBinds
        return KB and KB.KeyForSpell and KB:KeyForSpell(D.NameOf(key)) or ""
    end

    -- The theme's face and lane (built once per theme, then swapped in: frame.bar / big / seal / small / lane point
    -- at the one worn now; UI/RingFace.lua).
    local faces, lanes = {}, {}
    local function Wear(key)
        if frame.themeKey == key then return end
        if frame.face then frame.face.root:Hide(); frame.lane:Hide() end
        if not faces[key] then
            faces[key] = ns.RingFace:BuildFace(frame, key, D.VARIANT)
            lanes[key] = ns.RingFace:BuildLane(frame, key, { span = LANE_SPAN, back = LANE_BACK, gold = GOLD, fade = D.FADE })
        end
        local face = faces[key]
        frame.themeKey, frame.face = key, face
        frame.bar, frame.big, frame.seal, frame.small, frame.lane = face.root, face.big, face.seal, face.small, lanes[key]
        face.root:ClearAllPoints()
        -- (a face with its next press beside it, D.VARIANT: the frame has room for that on the left)
        face.root:SetPoint("TOP", frame, "TOP", (face.geo.padL or 0) / 2, -20)
        face.root:Show()
        frame.big.cdStart, swipeFrom, wasDue, shownKey, lastTo = nil, nil, false, nil, nil
        rested = false
    end
    R.Wear = function(_, key) return Wear(key) end

    local function Build()
        -- (placed by the layout, Core/Layout.lua item D.prefix: moved in Edit layout)
        frame = UI:CreateHudFrame(D.frameName, { width = LANE_W + 40, height = 260, look = "none",
            position = false, strata = "MEDIUM", layout = D.prefix })
        frame:EnableMouse(false)
        frame.dots = {}
        if situations then frame.chip = ns.RingFace:BuildChip(frame) end
        Wear(ns.RingFace:Key(D.prefix, Practicing()))

        frame:SetScript("OnUpdate", function() R:Update() end)
    end

    -- Its place: the layout's (Edit layout), else where it was dragged before (<prefix>.pos), else the driver's
    -- default (which may change, e.g. demo mode).
    local function Place()
        if ns.Layout and ns.Layout:Item(D.prefix) and ns.Layout:Place(D.prefix) then return end
        local pos = Get("pos")
        frame:ClearAllPoints()
        if type(pos) == "table" and pos[1] then frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        else
            local x, y = 0, -170
            if D.DefaultPos then x, y = D:DefaultPos() end
            frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
        end
    end

    function R:Layout()
        rested = false
        Place()
        local practicing = Practicing()
        Wear(ns.RingFace:Key(D.prefix, practicing))
        local g = frame.face.geo
        local style = practicing and "bar" or Get("style", "bar")   -- practice puts its own parts under the ring
        frame:SetScale(tonumber(Get("scale", 1)) or 1)
        local showBar, showLane = style ~= "lane", style ~= "bar"
        if not practicing and not Get("rotation", true) then showBar, showLane = true, false end   -- no plan: the ring alone
        frame.bar:SetShown(showBar)
        frame.lane:ClearAllPoints()
        -- (the next press's name under the ring: the lane starts below it)
        local nameRoom = (frame.big.underRing and Get("names", true) and Get("rotation", true)) and 16 or 0
        -- (the situation chip under that: round and tile faces centred under the ring, flat ones at their left edge)
        local chipRoom = 0
        if frame.chip then
            frame.chip:ClearAllPoints()
            if g.round or g.path == "square" then frame.chip:SetPoint("TOP", frame.bar, "BOTTOM", 0, -4 - nameRoom)
            else frame.chip:SetPoint("TOPLEFT", frame.bar, "BOTTOMLEFT", 0, -4 - nameRoom) end
            if showBar and not practicing and Get("sit.show", true) and Get("sit.mode", "auto") ~= "off" then
                chipRoom = ns.RingFace.CHIP_H + 4
            end
        end
        nameRoom = nameRoom + chipRoom
        if showBar then frame.lane:SetPoint("TOP", frame.bar, "BOTTOM", 0, -14 - nameRoom)
        else frame.lane:SetPoint("TOP", frame, "TOP", 0, -20) end
        frame.laneWanted = showLane
        -- (as big as what shows: Edit layout's box and its snapping go by the frame; practice keeps the room below)
        local gw = g.W + (g.padL or 0)
        if showLane or practicing then frame:SetSize(max(frame.lane.W, gw) + 40, max(260, g.H + frame.lane.H + 86))
        else frame:SetSize(gw + 24, g.H + 44 + nameRoom) end
    end

    -- The ring's frame (twist practice puts its parts around it).
    function R:Ring() return frame and frame.bar end
    function R:Frame() return frame end

    function R:UpdateVisibility()
        if not frame then return end
        local show = D:IsActive() and (Practicing() or R.preview or Get("idle", false)
            or InCombatLockdown() or UnitAffectingCombat("player") or D:IsDemo())
        frame:SetShown(show and true or false)
    end

    -- Resting: auto attack is not running, so there is nothing to time. A faint empty ring, the rest hidden.
    -- (drawn once, then again only when the icon or the badge changes: repainting the 200 dots every idle frame was
    -- the addon's top CPU handler out of combat; Performance page 2026-10-11)
    -- How see-through the whole timer is (<prefix>.alpha while it runs, .restAlpha while it rests; feedback #29):
    -- practice and Edit layout always show it whole.
    local function Fade(resting)
        local a = 1
        if not Practicing() and not R.preview then
            a = tonumber(Get(resting and "restAlpha" or "alpha", 1)) or 1
        end
        if frame:GetAlpha() ~= a then frame:SetAlpha(a) end
    end

    local function Rest()
        Fade(true)
        local icon = D:RestIcon()
        local badge, badgeText = D:Badge()
        local extra = D.RestExtra and D:RestExtra()
        local ek = extra and table.concat({ tostring(extra.oh), extra.rage or 0, extra.line or 0 }, ":") or nil
        if rested and icon == restIcon and badge == restBadge and ek == restExtra then return end
        rested, restIcon, restBadge, restExtra = true, icon, badge, ek
        frame.lane:Hide()
        ns.RingFace:Rest(frame.face)
        if extra then ns.RingFace:RestExtra(frame.face, extra.oh, extra.rage, extra.line) end
        frame.big:SetScale(1)
        frame.big:Show()
        frame.big.icon:SetTexture(icon)
        frame.big.icon:SetDesaturated(true)
        frame.big.shade:SetAlpha(0)
        frame.big.cd:Hide()
        frame.big.cdStart, swipeFrom, wasDue = nil, nil, false
        frame.big.name:SetText("")
        frame.big.hint:SetText("")
        frame.big.key:SetText("")
        frame.big.stance:Set(nil)
        if frame.chip then frame.chip:Hide() end
        lastSit = nil
        for _, s in ipairs(frame.small) do s:Hide() end
        frame.seal:SetShown(badge ~= nil)
        if badge then frame.seal.icon:SetTexture(badge); frame.seal.text:SetText("") end
        lastTo, shownKey = nil, nil
    end

    -- What a step is called and what to tell the player.
    local function StepText(step)
        local key = step.key
        return key == "wait" and "Hold" or (D.NameOf(key) or key)
    end

    function R:Update()
        local now = GetTime()
        local ok, cur = pcall(D.Current, D)
        if not ok or not cur then Rest() return end
        rested = false
        Fade(false)
        local snap, steps = cur.snap, cur.plan.steps
        local face = D:Face(cur, now)
        local from, to = face.from, face.to
        local len = max(0.05, to - from)
        local frac = min(1, max(0, now - from) / len)
        local zone0, zone1 = face.z0, face.z1
        local inZone = zone0 and now >= zone0 and now <= zone1 or false
        local first = steps[1]
        local hot = face.hot
        frame.lane:SetShown(frame.laneWanted)

        -- a hit landed: the ring flashes
        if face.landed ~= nil then
            if lastLanded and face.landed ~= lastLanded then flashAt = now end
            lastLanded = face.landed
        elseif lastTo and to > lastTo + 0.2 then flashAt = now end
        lastTo = to
        -- an extra attack (Reckoning and the like): the same flash, the swing keeps its time
        local ex = face.extraAt
        if ex and ex ~= lastExtra then lastExtra, flashAt = ex, now end

        local ring = frame.bar
        ring:SetAlpha(1)
        local z0, z1 = 2, 2
        if zone0 then z0, z1 = (zone0 - from) / len, (zone1 - from) / len end
        local s0 = face.red0 and (face.red0 - from) / len or 2
        local pulse = 0.5 + 0.5 * sin(now * 9)
        ns.RingFace:Paint(frame.face, { frac = frac, z0 = z0, z1 = z1, s0 = s0, hot = hot, inZone = inZone,
            pulse = pulse, fade = D.FADE })
        local ft = flashAt and (now - flashAt) / 0.35 or 1
        ring.flash:SetAlpha(ft < 1 and 0.6 * (1 - Ease(ft)) or 0)
        if D.Extra then
            local e = D:Extra(cur, now)
            e.pulse = pulse
            ns.RingFace:PaintExtra(frame.face, e)
        end

        local badge, badgeText = D:Badge()
        frame.seal:SetShown(badge ~= nil)
        if badge then
            frame.seal.icon:SetTexture(badge)
            frame.seal.text:SetText(badgeText or "")
        end

        -- the situation (Core/Situation.lua): the chip under the face; a change flashes the ring and pops the next press
        local sit = snap.sit or cur.sit
        if frame.chip then
            local want = sit and not Practicing() and Get("sit.show", true)
                and (sit.kind ~= "single" or sit.held ~= nil or sit.locked) and frame.bar:IsShown()
            if want then
                local kind, icon, coords, text = ChipLook(sit)
                local key = kind .. "|" .. text .. "|" .. tostring(sit.locked)
                if key ~= frame.chip.paintKey then
                    ns.RingFace:PaintChip(frame.chip, kind, icon, coords, text, sit.locked)
                    frame.chip.paintKey = key
                end
                frame.chip:Show()
            elseif frame.chip:IsShown() then
                frame.chip:Hide()
                frame.chip.paintKey = nil
            end
        end
        local sk = sit and (sit.kind .. ":" .. (sit.held and sit.held.key or "") .. ":" .. tostring(sit.locked)) or nil
        if lastSit and sk ~= lastSit then flashAt, shownAt = now, now end
        lastSit = sk

        if inZone and not zoneWasOpen and Get("sound", false) and hot then
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856, "Master")
        end
        zoneWasOpen = inZone

        -- the next press in the middle: dimmed until due, a small pop when it changes
        local big = frame.big
        local showRotation = Practicing() or Get("rotation", true)
        big:SetShown(showRotation)
        if not showRotation then first = nil end
        if first then
            local dt = first.at - now
            local waiting = first.key == "wait"
            local nowPress = dt <= 0.05 and not waiting
            -- a new press to come: another spell, or the one that was due was made (the same spell again later)
            if first.key ~= shownKey or (wasDue and not nowPress) then
                shownKey, shownAt, swipeFrom = first.key, now, now
            end
            if nowPress and not wasDue then shownAt = now end      -- it pops as it lights up
            wasDue = nowPress
            local pop = min(1, (now - shownAt) / 0.18)
            big:SetScale(0.82 + 0.18 * Ease(pop))
            big.icon:SetTexture(D.Icon(first.key))
            big.icon:SetDesaturated(waiting)
            -- the swipe from when it became the next press to when it is due; full colour once due
            local swiping = not waiting and not nowPress and swipeFrom and first.at - swipeFrom > 0.1
            if swiping then
                local d = first.at - swipeFrom
                if not big.cdStart or math.abs(big.cdStart - swipeFrom) > 0.01 or math.abs(big.cdDur - d) > 0.02 then
                    big.cd:SetCooldown(swipeFrom, d)
                    big.cdStart, big.cdDur = swipeFrom, d
                end
                big.cd:Show()
            elseif big.cdStart then
                big.cd:Hide()
                big.cdStart = nil
            end
            big.shade:SetAlpha((nowPress or swiping) and 0 or 0.45)
            big.name:SetText(StepText(first))
            ns.RingFace:FitName(frame.face)
            big.name:SetShown(big.showName and (not big.under or Get("names", true)) or false)
            big.key:SetText(KeyOf(first.key))
            big.stance:Set(first.stance and D.StanceIcon and D.StanceIcon(first.stance) or nil)
            if waiting then big.name:SetTextColor(0.62, 0.58, 0.48)
            elseif hot then big.name:SetTextColor(1, 0.66, 0.34)
            else big.name:SetTextColor(1, 0.88, 0.54) end
            if waiting then big.hint:SetText("hold")
            elseif nowPress then big.hint:SetText("now")
            else big.hint:SetText(strformat("%.1f", dt)) end
            if nowPress then big.hint:SetTextColor(1, 0.86, 0.5) else big.hint:SetTextColor(0.7, 0.66, 0.56) end
        end
        local si = 1
        for i = 2, showRotation and #steps or 0 do
            if si > 2 then break end
            local st = steps[i]
            if st.key ~= "wait" then
                local sm = frame.small[si]
                sm.icon:SetTexture(D.Icon(st.key))
                sm.key:SetText(KeyOf(st.key))
                sm.stance:Set(st.stance and D.StanceIcon and D.StanceIcon(st.stance) or nil)
                sm:Show()
                si = si + 1
            end
        end
        for i = si, 3 do frame.small[i]:Hide() end

        -- lane
        local lane = frame.lane
        if lane:IsShown() then
            local lw = lane.W
            local t0 = now - LANE_BACK
            local function X(t) return (t - t0) / LANE_SPAN * lw end
            local marks, windows = D:Lane(cur, now)
            local wi = 1
            for i = 1, 4 do
                local tick = lane.ticks[i]
                local m = marks[i]
                local x = m and X(m.t)
                if x and x >= 0 and x <= lw then
                    tick:ClearAllPoints()
                    tick:SetPoint("TOP", lane, "TOPLEFT", x, 3)
                    tick:SetPoint("BOTTOM", lane, "BOTTOMLEFT", x, -3)
                    tick:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], m.strong and 1 or 0.35)
                    tick:Show()
                else
                    tick:Hide()
                end
            end
            for _, wnd in ipairs(windows) do
                if wi > #lane.windows then break end
                local wx0, wx1 = max(0, X(wnd[1])), min(lw, X(wnd[2]))
                if wx1 > wx0 then
                    local win = lane.windows[wi]
                    win:ClearAllPoints()
                    win:SetPoint("TOPLEFT", lane, "TOPLEFT", wx0, 0)
                    win:SetPoint("BOTTOMLEFT", lane, "BOTTOMLEFT", wx0, 0)
                    win:SetWidth(wx1 - wx0)
                    win:Show()
                    wi = wi + 1
                end
            end
            for i = wi, #lane.windows do lane.windows[i]:Hide() end
            local bi = 1
            for _, st in ipairs(steps) do
                if st.key ~= "wait" and bi <= #lane.blocks then
                    local b = lane.blocks[bi]
                    local at = max(st.at, now)          -- a due press sits on the now line until it is made
                    local width = D.StepWidth and D.StepWidth(st, snap) or snap.gcd
                    local x0, x1 = max(0, X(at)), min(lw, X(at + width))
                    if x1 - x0 > 6 then
                        b:ClearAllPoints()
                        b:SetPoint("LEFT", lane, "LEFT", x0 + 1, 0)
                        b:SetWidth(x1 - x0 - 2)
                        b.icon:SetTexture(D.Icon(st.key))
                        b.name:SetText((not lane.noNames and x1 - x0 > 70) and D.Short(st.key) or "")
                        if D.FILLERS[st.key] then
                            b.bg:SetVertexColor(FILLER[1], FILLER[2], FILLER[3], 0.22)
                            b.line:SetVertexColor(FILLER[1], FILLER[2], FILLER[3], 0.7)
                            b.name:SetTextColor(S:Color("YOU"))
                        else
                            b.bg:SetVertexColor(S:Color("HAIRLINE"))
                            local ln = lane.look.line
                            if ln then b.line:SetVertexColor(ln[1], ln[2], ln[3], ln[4])
                            else b.line:SetVertexColor(S:Color("EDGE")) end
                            b.name:SetTextColor(S:Color("TEXT"))
                        end
                        b:Show()
                        bi = bi + 1
                    end
                end
            end
            for i = bi, #lane.blocks do lane.blocks[i]:Hide() end
            lane.gain:SetText("")
        end
    end

    function R:Refresh()
        if not D:IsActive() then
            if frame then frame:Hide() end
            return
        end
        if not frame then Build() end
        self:Layout()
        self:UpdateVisibility()
    end

    -- Wires the ring to its tool: `stateEvent` (the tool turned on or off), its settings, entering and leaving combat.
    -- (reports, values, the place and practice settings change nothing on screen)
    function R:Hook(stateEvent, extraEvents)
        local prefix = "^" .. D.prefix
        ns.Layout:Register(D.prefix, { name = D.layoutName, group = "Class tools", order = D.layoutOrder or 30,
            frame = function() return frame end, mine = function() return D:IsActive() and true or false end,
            legacy = function()
                local pos = Get("pos")
                if type(pos) == "table" and pos[1] then return pos[1], pos[2], pos[3], pos[4] end
            end,
            default = function()
                local x, y = 0, -170
                if D.DefaultPos then x, y = D:DefaultPos() end
                return { "CENTER", x, y }
            end,
            scale = { get = function() return tonumber(Get("scale", 1)) or 1 end,
                      set = function(v) ns.DB:SetSetting(D.prefix .. ".scale", v) end },
            preview = function(on) R.preview = on and true or nil; R:Refresh() end })
        ns.RingFace:Register(D.prefix, R)
        ns:On(stateEvent, function() R:Refresh() end)
        for _, e in ipairs(extraEvents or {}) do ns:On(e, function() R:Refresh() end) end
        ns:On("SETTINGS_CHANGED", function(path)
            if type(path) == "string" and path:find(prefix .. "%.") and path ~= D.prefix .. ".reports"
                and path ~= D.prefix .. ".values" and path ~= D.prefix .. ".pos"
                and not path:find(prefix .. "%.practice") then R:Refresh() end
        end)
        ns:RegisterEvent("PLAYER_REGEN_DISABLED", function() R:UpdateVisibility() end)
        ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
            if C_Timer then C_Timer.After(1.5, function() R:UpdateVisibility() end) else R:UpdateVisibility() end
        end)
        self:Refresh()
    end

    return R
end
ns.SwingRing = NewRing

-- The rows every timer tool's Settings card starts with: look, out of combat, its place (Edit layout), size, latency. `what` names the
-- tool in the latency help ("seal casts").
function ns.SwingRingSettings(S, sec, prefix, latencyHelp)
    S:DropdownSetting(sec, "Look", "The ring, the plan lane (the next 7 seconds) or both.", prefix .. ".style", "bar", {
        { value = "bar", text = "Ring" }, { value = "lane", text = "Plan lane" }, { value = "both", text = "Both" } })
    -- (the theme is picked in Settings > Interface > Looks > Timers, with every other look)
    if S.LookLinkRow then S:LookLinkRow(sec, "Theme", "The look of this timer.", "timers") end
    S:SwitchSetting(sec, "Show rotation", "The next presses in the middle of the ring (and the plan lane). Off: only the timer.",
        prefix .. ".rotation", true)
    S:SwitchSetting(sec, "Show the key", "The key each next press is on, in its corner as on your bars (the first bound "
        .. "button holding that spell). S- Shift, C- Ctrl, A- Alt, M4 a mouse button.", prefix .. ".keys", true)
    S:SwitchSetting(sec, "Show the ability name", "The next press's name under the ring (Slate and Classic always show it).",
        prefix .. ".names", true)
    S:SwitchSetting(sec, "Show out of combat", "Keep it on screen when you are not fighting.", prefix .. ".idle", false)
    if S.EditLayoutRow then S:EditLayoutRow(sec) end
    local scales = {}
    for _, n in ipairs({ 0.8, 0.9, 1, 1.15, 1.3, 1.5 }) do scales[#scales + 1] = { value = n, text = floor(n * 100) .. "%" } end
    S:DropdownSetting(sec, "Size", "", prefix .. ".scale", 1, scales)
    local fades = {}
    for _, n in ipairs({ 1, 0.85, 0.7, 0.55, 0.4 }) do fades[#fades + 1] = { value = n, text = floor(n * 100 + 0.5) .. "%" } end
    S:DropdownSetting(sec, "Opacity in a fight", "How see-through the timer is while it runs.", prefix .. ".alpha", 1, fades)
    local rests = { { value = 1, text = "100%" }, { value = 0.6, text = "60%" }, { value = 0.35, text = "35%" },
                    { value = 0.15, text = "15%" }, { value = 0, text = "Hidden" } }
    S:DropdownSetting(sec, "Opacity at rest", "While auto attack is off (with Show out of combat on, or between pulls).",
        prefix .. ".restAlpha", 1, rests)
    local lats = { { value = 0, text = "Auto" } }
    for _, n in ipairs({ 20, 40, 60, 80, 100, 150, 200, 300 }) do lats[#lats + 1] = { value = n, text = n .. " ms" } end
    S:DropdownSetting(sec, "Latency", "Moves the press zone earlier. Auto measures it for you.",
        prefix .. ".latencyMs", 0, lats, latencyHelp)
end

-- ---------------------------------------------------------------------------------------------------------------
-- The Situations rows (Core/Situation.lua) a timer with a rotation adds to its Settings card: the switch, the chip,
-- the switch key, then under More options the pack's and the player's rows. opts: { pack (the tool has a pack),
-- packRows(S, sec), playerRows(S, sec), modeDesc }. Every number and press is a setting (the user, 2026-10-17).
-- ---------------------------------------------------------------------------------------------------------------
local function SGet(path, default)
    local v = ns.DB and ns.DB:GetSetting(path)
    if v == nil then return default end
    return v
end
local function SSet(path, v) if ns.DB then ns.DB:SetSetting(path, v) end end

local function Choices(list, fmt)
    local out = {}
    for _, v in ipairs(list) do
        if type(v) == "table" then out[#out + 1] = { value = v[1], text = v[2] }
        else out[#out + 1] = { value = v, text = strformat(fmt, v) } end
    end
    return out
end
ns.SituationChoices = Choices

local function Caps(S, sec, text)
    local h = ns.UI:CreateSectionHeader(sec, text, { style = "caps" })
    S:Place(sec, h, 20, { gap = 10 })
    return h
end
ns.SituationCaps = Caps

-- A row whose control picks several of a list (a ticked menu): items = { { key, text } }, each a switch at
-- path .. key (default on unless defaults[key] == false). Back to defaults ticks them back.
function ns.SituationPicks(S, sec, title, desc, path, items, defaults, tip)
    defaults = defaults or {}
    local row = S:Row(sec, title, desc, tip)
    local function Def(k) return defaults[k] ~= false end
    local function On(k) return SGet(path .. k, Def(k)) and true or false end
    local dd = ns.UI:CreateMultiDropdown(row, 170, function()
        local out = {}
        for _, it in ipairs(items) do out[#out + 1] = { value = it[1], text = it[2] } end
        return out
    end, On, function(k, want) SSet(path .. k, want and true or false) end, function()
        local n = 0
        for _, it in ipairs(items) do if On(it[1]) then n = n + 1 end end
        if n == #items then return "All " .. #items end
        if n == 0 then return "None" end
        return strformat("%d of %d", n, #items)
    end)
    dd:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.control = dd
    S.PlaceText(row, 170)
    row.isChanged = function()
        for _, it in ipairs(items) do if On(it[1]) ~= Def(it[1]) then return true end end
        return false
    end
    row.reset = function() for _, it in ipairs(items) do SSet(path .. it[1], nil) end end
    row.getValue = row.isChanged
    row.setting = { default = false }
    S.settingRows[#S.settingRows + 1] = row
    S.refreshers[#S.refreshers + 1] = dd
    return dd, row
end

-- The switch key's row: the key it is on (or Not bound) and a button that takes the next key pressed. Right-click
-- the button: no key. (SetBinding is not allowed in a fight: it says so.)
local capture
local function KeyRow(S, sec)
    local Sit = ns.Situation
    local row = S:Row(sec, "Switch key", "Goes Automatic, One target, Pack, Player (the situations this timer has) and "
        .. "back. Right-click the button for no key.")
    local btn
    local function Paint()
        local k = Sit:KeyText()
        if capture and capture.btn == btn and capture:IsShown() then btn:SetText("Press a key...")
        else btn:SetText(k or "Set key") end
        row.desc:SetText("Goes Automatic, One target, Pack, Player (the situations this timer has) and back. "
            .. (k and "Right-click the button for no key." or "Not bound yet."))
    end
    btn = ns.UI:CreateSleekButton(row, "Set key", 120, 22, function(self, mouse)
        if InCombatLockdown and InCombatLockdown() then ns:Print("Keys can't be set in a fight.") return end
        if mouse == "RightButton" then
            local k = GetBindingKey and GetBindingKey("DISASTERZONE_SITUATION")
            if k and SetBinding then
                SetBinding(k)
                if SaveBindings then pcall(SaveBindings, GetCurrentBindingSet and GetCurrentBindingSet() or 1) end
            end
            Paint()
            return
        end
        capture = capture or CreateFrame("Frame", nil, UIParent)
        capture:SetAllPoints(UIParent)
        capture:SetFrameStrata("FULLSCREEN_DIALOG")
        capture:EnableKeyboard(true)
        if capture.SetPropagateKeyboardInput then capture:SetPropagateKeyboardInput(false) end
        capture.btn = btn
        capture:SetScript("OnKeyDown", function(cf, key)
            if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL" or key == "LALT" or key == "RALT" then
                return
            end
            cf:Hide()
            if key ~= "ESCAPE" and SetBinding and not (InCombatLockdown and InCombatLockdown()) then
                local chord = (IsAltKeyDown and IsAltKeyDown() and "ALT-" or "")
                    .. (IsControlKeyDown and IsControlKeyDown() and "CTRL-" or "")
                    .. (IsShiftKeyDown and IsShiftKeyDown() and "SHIFT-" or "") .. key
                SetBinding(chord, "DISASTERZONE_SITUATION")
                if SaveBindings then pcall(SaveBindings, GetCurrentBindingSet and GetCurrentBindingSet() or 1) end
            end
            Paint()
        end)
        capture:Show()
        Paint()
    end, "secondary")
    if btn.RegisterForClicks then btn:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    btn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.control = btn
    S.PlaceText(row, 120)
    S.refreshers[#S.refreshers + 1] = { Refresh = Paint }
    Paint()
    return row
end

function ns.SituationSettings(S, sec, prefix, opts)
    opts = opts or {}
    local P = prefix .. ".sit."
    local function On() return SGet(P .. "mode", "auto") ~= "off" end
    Caps(S, sec, "Situations")
    S:DropdownSetting(sec, "Switch by situation", opts.modeDesc or ("Automatic: one target, a pack or a player as the "
        .. "fight changes. My key only: your switch key decides."),
        P .. "mode", "auto", Choices({ { "auto", "Automatic" }, { "key", "My key only" }, { "off", "Off" } }))
    S:Needs(select(2, S:SwitchSetting(sec, "Show the situation", "A small plate under the ring while it isn't one "
        .. "target. The next press flashes once when it changes.", P .. "show", true)), On)
    S:Needs(KeyRow(S, sec), On)
    S:Needs(select(2, S:DropdownSetting(sec, "Your pick holds", "What the switch key picked, for every timer.", "sit.hold",
        "fight", Choices({ { "fight", "Until the fight ends" }, { "key", "Until I press it again" } }))), On)
    S:Needs(select(2, S:SwitchSetting(sec, "Sound on a switch", "A short click when the timer changes situation on "
        .. "its own.", P .. "sound", false)), On)
    S:MoreOptions(sec)
    if opts.pack then
        Caps(S, sec, "Pack")
        local function R(row) return S:Needs(row, On) end
        R(select(2, S:DropdownSetting(sec, "Pack from", "How many enemies make a pack.", P .. "packFrom",
            ns.Situation:Tool(prefix).packFrom, Choices({ 2, 3, 4, 5, 6, 8 }, "%d enemies"))))
        R(select(2, S:DropdownSetting(sec, "Reach", "Where an enemy has to be to count. These are the distances the "
            .. "game can tell in a fight.", P .. "reach", ns.Situation:Tool(prefix).reach,
            Choices({ { "melee", "Melee" }, { "10", "10 yards" }, { "28", "28 yards" } }))))
        R(select(2, S:DropdownSetting(sec, "Count", "Enemy nameplates in combat, the enemies your multi-target "
            .. "attacks hit in the last 3 s, or both.", P .. "count", "both",
            Choices({ { "both", "Both" }, { "plates", "Nameplates" }, { "hits", "Hits" } }))))
        R(select(2, S:DropdownSetting(sec, "Switch to a pack after", "How long the count has to hold first.",
            P .. "inDelay", 1, Choices({ { 0, "At once" }, { 0.5, "0.5 s" }, { 1, "1 s" }, { 1.5, "1.5 s" }, { 2, "2 s" }, { 3, "3 s" } }))))
        R(select(2, S:DropdownSetting(sec, "Back to one target after", "How long the count has to stay under it.",
            P .. "outDelay", 3, Choices({ 1, 2, 3, 4, 5, 8 }, "%d s"))))
        R(select(2, S:DropdownSetting(sec, "On bosses", "Count adds: a boss with adds near you plays as a pack. My key "
            .. "only: a boss stays one target until you press your key.", P .. "bosses", "count",
            Choices({ { "count", "Count adds" }, { "key", "My key only" } }))))
        local cc = {}
        for _, c in ipairs(ns.Situation.CC) do
            cc[#cc + 1] = { c.key, (GetSpellInfo and GetSpellInfo(c.id)) or c.key }
        end
        R(select(2, ns.SituationPicks(S, sec, "Keep crowd control safe", "Any damage breaks these, so the presses that "
            .. "hit more than your target wait while one is in reach.", P .. "cc.", cc)))
        if opts.packRows then opts.packRows(S, sec, R) end
    end
    if opts.playerRows then
        Caps(S, sec, "Player")
        opts.playerRows(S, sec, function(row) return S:Needs(row, On) end)
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The Retribution swing timer's ring (Core/SwingTimer.lua)
-- ---------------------------------------------------------------------------------------------------------------
local HUD = ns:NewModule("SwingTimerHUD")
local ST                         -- ns.SwingTimer

-- Lane labels have about 60 px: the word that tells the spells apart.
local SHORT = { cs = "Strike", soc = "Command", exo = "Exorcism", cons = "Consec.", hoj = "Hammer" }

local D = {
    prefix = "swing", frameName = "DisasterZoneSwingTimer", layoutName = "Swing timer", layoutOrder = 30,
    FILLERS = { exo = true, cons = true },
}
function D.Get(path, default) return ST.Get(path, default) end
function D:IsActive() return ST.active end
function D:IsDemo() return ST:IsDemo() end
function D:Practicing() return ST.practice ~= nil end
function D:Current() return ST:Current() end
function D.Icon(key) return ST.ICONS[key] end
function D.NameOf(key) return ST.NameOf(key) end
function D.Short(key)
    if SHORT[key] then return SHORT[key] end
    local n = ST.NameOf(key) or key
    return (n:gsub("^Seal of the ", ""):gsub("^Seal of ", ""))
end
function D.StepWidth(st, snap) return st.key == "judge" and 0.4 or snap.gcd end
function D:RestIcon() return GetInventoryItemTexture("player", 16) or ST.ICONS.wait end
function D:Badge()
    local seal = ST.state.seal
    if not seal then return nil end
    local left = (ST.state.sealExpires or 0) - GetTime()
    return ST.ICONS[seal], left > 0 and left < 6 and strformat("%d", left) or ""
end
-- The swing: the twist window (one round trip early, MARGIN inside both edges) hot when the plan twists into it; the
-- server's window dim red.
function D:Face(cur, now)
    local snap, steps = cur.snap, cur.plan.steps
    local nxt = ST:NextSwing(now)
    local lat = snap.lat
    local first = steps[1]
    return { from = nxt - snap.speed, to = nxt,
             z0 = nxt - ST.OVERLAP + ST.MARGIN - lat, z1 = nxt - ST.MARGIN - lat,
             hot = first and first.key == "sob" and first.twist and true or false,
             red0 = nxt - ST.OVERLAP, extraAt = ST.state.extraAt }
end
-- Swings (bright when the plan twists into them) and the twist windows before those.
function D:Lane(cur, now)
    local snap, steps = cur.snap, cur.plan.steps
    local speed, lat = snap.speed, snap.lat
    local twistAt = {}
    for _, st in ipairs(steps) do if st.twist then twistAt[floor(st.twist * 10 + 0.5)] = true end end
    local marks, windows = {}, {}
    local ts = ST:NextSwing(now) - speed
    for i = 1, 4 do
        local tw = twistAt[floor(ts * 10 + 0.5)] or false
        marks[i] = { t = ts, strong = tw }
        if tw then windows[#windows + 1] = { ts - ST.OVERLAP - lat, ts - lat } end
        ts = ts + speed
    end
    return marks, windows
end

local ring = NewRing(D)
HUD.ring = ring
function HUD:Update() return ring:Update() end
function HUD:Layout() return ring:Layout() end
function HUD:Ring() return ring:Ring() end
function HUD:UpdateVisibility() return ring:UpdateVisibility() end
function HUD:Refresh() return ring:Refresh() end

function HUD:OnLogin()
    ST = ns.SwingTimer
    if not ST then return end
    ring:Hook("SWING_STATE", { "SWING_PRACTICE" })
end

-- The kit's Settings section (UI/Settings.lua gives every class tool one; this one shows for Retribution only).
if ns.ClassKit then ns.ClassKit:Extend("swing", { iconPath = "Interface\\Icons\\Spell_Holy_SealOfBlood",
    action = { label = "Practice", width = 90, run = function() if ns.SwingPracticeUI then ns.SwingPracticeUI:Open() end end },
    settings = function(S, sec)
    -- (on/off is the switch on the card's header: swing.enabled)
    ns.SwingRingSettings(S, sec, "swing", "Auto averages your world latency with what it measures from your own "
        .. "seal casts (the time from pressing to the seal landing). /dz swing shows both.")
    S:SwitchSetting(sec, "Exorcism", "On demons and undead. Off in WoWSims' rotation: turn on only if your sim says so.", "swing.use.exo", false)
    S:SwitchSetting(sec, "Consecration", "Off in WoWSims' rotation: turn on only if your sim says so.", "swing.use.cons", false)
    local manas = {}
    for _, n in ipairs({ 0, 20, 30, 40, 50, 60, 80 }) do manas[#manas + 1] = { value = n, text = n .. "%" } end
    S:DropdownSetting(sec, "Consecration above", "Only suggest it with at least this much mana.", "swing.consMana", 40, manas)
    S:SwitchSetting(sec, "Sound in the twist zone", "A click when it is time to twist.", "swing.sound", false)
    local row = S:Row(sec, "Last fight", "")
    row.hasDesc = true
    S.PlaceText(row, 0)
    S.refreshers[#S.refreshers + 1] = {
        Refresh = function()
            local r = ns.SwingTimer and ns.SwingTimer:Reports()[1]
            if not r then row.desc:SetText("No fight yet. /dz swing report prints the latest one.") return end
            local c = r.counts or {}
            local tw, late, clip = c.twist or 0, c.late or 0, c.clip or 0
            local f = r.fillers or {}
            local fill = (f.exo or 0) + (f.cons or 0) + (f.how or 0)
            row.desc:SetText(strformat("%s: %d/%d twists landed, %d late, %d clipped, %d fillers.",
                r.target or "Fight", tw, tw + late + clip, late, clip, fill))
        end,
    }
    -- (no pack for Ret: the twist is the same on one target or many)
    ns.SituationSettings(S, sec, "swing", {
        modeDesc = "Automatic: a player's presses while you target an enemy player. My key only: your switch key "
            .. "decides.",
        playerRows = function(S, sec, R)
            R(select(2, S:SwitchSetting(sec, "Judge Command on a stun", "A stunned or incapacitated target: judge Seal "
                .. "of Command, which does double damage then, instead of Seal of Blood.", "swing.stunJudge", true)))
            R(select(2, S:SwitchSetting(sec, "Hammer of Justice", "Suggest it to set up that Judgement (6 s stun, "
                .. "1 min cooldown).", "swing.hoj", false)))
        end })
    S:EndSection(sec)
end }) end
