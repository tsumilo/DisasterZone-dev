if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SessionBar.lua", ...) then return end -- DisasterZone: UI/SessionBar.lua
-- The raid session crest (Addendum I §51; 1.4.2 look B "Crest" of the mockup claude.ai/artifact/2jy2CFhKHvwJVDxHeEYA3T):
-- a small round seal for whoever runs the raid or the loot. The raid's art in a circle, a bead per boss round it
-- (gold: killed, red: being fought), the time under it and a gold count when something waits on me. Hovering it
-- slides out one line (the raid, its bosses, chips that show only while they have something to say: drops waiting
-- with my vote, Free for All loot to trade, who left, an unlinked raid; End raid once every boss is down); a click
-- opens the drawer (UI/SessionDrawer.lua: bosses with Strategy / Pull 10 / Break 5, the loot, the council, the
-- attendance, the link, what the raid runs and End raid). In a boss fight it shows the boss and the fight's time,
-- dimmed, and nothing else. What it shows comes from Core/SessionInfo.lua (one table; demo mode draws a made-up one).
-- Who sees it (settings "sessionBar.show"): "auto" = whoever runs the session and the council / GM / officers (read
-- only); "always" adds a light crest for raiders; "lead" = only when I run it; "never". Raiders who don't see it get
-- one pop-up when the raid starts (what runs, their BiS list locked). Right-click: hide it for this raid, its
-- settings, Edit layout. Before the start the leader's line holds the planned raid, who is here, the three switches
-- (loot council, rolls, BiS lock) and Start raid: one click, no window. The Start raid window stays for the Raids
-- tab's Start raid and /dz raid options (1.2: what the session runs; 1.3: the loot council, the lock needs it).
local addonName, ns = ...

local SessionBar = ns:NewModule("SessionBar")

local S = ns.Style
local FRAME_NAME = "DisasterZoneSessionBar"
local floor, max, min = math.floor, math.max, math.min
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local RING = "Interface\\AddOns\\DisasterZone\\Media\\Events\\ring"
local PEN = "Interface\\AddOns\\DisasterZone\\Media\\Pen\\"
local GOLD, LIVE = S.C.GOLD, S.C.LIVE

-- The crest's sizes: the seal, the raid art inside it, the beads round it, the time pill, the line, its chips.
local C = { SEAL = 44, ART = 30, BEAD_R = 19.5, BEAD = 6, BEAD_SM = 4, TIME_H = 14, LINE_H = 28, LINE_X = 10,
            GAP = 6, CHIP_H = 20, CHIP_GAP = 5, ICON = 14, TOGGLE_W = 24, X_W = 16 }
local BAR = { H = C.SEAL + 2 + C.TIME_H }

local crest                     -- the HUD frame (the seal, the time, the line, the drawer)
local info                      -- the last SessionInfo table drawn
local idleDismissed = false     -- the idle crest's X: hidden until the next instance
local hiddenFor                 -- "Hide for this raid": the session id (or "idle")
local toasted = {}              -- session ids whose start pop-up I got
local pick                      -- the idle switches: { loot, rolls, lock }

local function FormatDuration(sec)
    sec = floor(math.max(0, sec or 0))
    return ("%d:%02d:%02d"):format(floor(sec / 3600), floor(sec % 3600 / 60), sec % 60)
end

local function Session()
    return ns.GroupRules and ns.GroupRules.GetSession and ns.GroupRules:GetSession() or nil
end

local function IsAuthority()
    return ns.GroupRules and ns.GroupRules.IsAuthority and ns.GroupRules:IsAuthority() or false
end

local function SI() return ns.SessionInfo end

-- "Karazhan · 1:42:13 · 4/11 bosses · BiS locked" for the running session.
function SessionBar:GetText()
    local s = Session()
    if not s then return "No raid session" end
    local RL = ns.RaidLog
    local rec = RL and RL:GetRaid(s.id)
    local parts = { (rec and rec.zone) or "Raid" }
    parts[#parts + 1] = FormatDuration(GetServerTime() - (s.at or GetServerTime()))
    local kills = rec and #(rec.bosses or {}) or 0
    local total = rec and RL:GetRecordBossTotal(rec)
    parts[#parts + 1] = total and ("%d/%d bosses"):format(kills, total) or (kills == 1 and "1 boss" or (kills .. " bosses"))
    if ns.GroupRules:IsLocked() then parts[#parts + 1] = "BiS locked" end
    return table.concat(parts, " · ")
end

---------------------------------------------------------------------------
-- The Start raid window: what the raid session runs. Loot distribution and rolls are off in a raid until the raid
-- leader starts the session, and the leader picks here which of them it runs (GroupRules:IsFeatureOn). The same
-- window changes the features of a running session ("Options" on the bar). In demo mode outside a raid it opens as
-- a preview, so the flow can be shown without a raid.
---------------------------------------------------------------------------

-- 1.3: loot handed out is recorded in the loot log whatever runs; "loot" is the loot council (wire letter l as
-- before). Without it, rolls are plain (the highest roll wins) and the BiS lock has nothing to protect.
local FEATURES = {
    { key = "loot", label = "Loot council", desc = "BiS candidates and council votes on every drop",
      tip = "The council sees who has each drop on their BiS list, votes, and rolls rank BiS lists first. "
          .. "Off: no BiS candidates or votes; rolls (when on) go to the highest roll. "
          .. "Loot handed out is recorded in the loot log either way." },
    { key = "rolls", label = "Rolls", desc = "Roll / Pass popups for everyone in the raid",
      tip = "The drop panel opens for the raid leader and the council to start rolls; raiders get the Roll / Pass "
          .. "popup, players without DisasterZone type /roll. Off: no roll popups." },
    { key = "lock", label = "Lock everyone's BiS lists", desc = "Nobody edits their list until the raid ends",
      off = "Needs the loot council", offReserve = "Reserves don't use BiS lists",
      tip = "Nobody changes their BiS list while the raid runs (it unlocks when the raid ends). "
          .. "Needs the loot council." },
    -- 1.4.3: reserves (Core/Reserves.lua): only when picked (optIn); they keep the council for the guild's items
    { key = "reserve", label = "Reserves", desc = "Soft reserves decide; the council keeps the guild's items",
      optIn = true,
      tip = "Whoever soft reserved an item rolls on it; nobody reserved it: everyone rolls. Items the guild holds "
          .. "go to the loot council among guild members. Pugs reserve by whisper, in LootReserve or softres.it." },
}

-- The window: a tool window of W (its content W - 10), the switches as rich rows under a caps header (18 high).
local START = { W = 420, SWITCH_W = 34, HEAD_H = 18 }
START.H = ns.UI.WIN_HEAD + 1 + S.PAD + S.BANNER.tool + S.GAP + START.HEAD_H + S.GAP
    + #FEATURES * S.ROW.rich + (#FEATURES - 1) * S.GAP + S.GAP + 14 + S.PAD + 5

local startWin

-- What I picked the last time (everything, the first time): { loot=, rolls=, lock= }.
local function LastFeatures()
    local saved = ns.db and ns.db.settings and ns.db.settings.raidStart
    local f = {}
    for _, feat in ipairs(FEATURES) do
        if feat.optIn then
            f[feat.key] = type(saved) == "table" and saved[feat.key] == true
        else
            f[feat.key] = type(saved) ~= "table" or saved[feat.key] ~= false
        end
    end
    if f.reserve then f.loot, f.lock = true, false end
    return f
end

-- The features a pick / the window / a switch hands GroupRules (reserves keep the council on, the lock off).
local function CleanPick(p)
    local f = { loot = p.loot and true or false, rolls = p.rolls and true or false,
                lock = (p.loot and p.lock and not p.reserve) and true or false, reserve = p.reserve and true or false }
    if f.reserve then f.loot, f.rolls = true, true end
    return f
end

-- The raid the window is about: the instance I stand in (its art on the banner) and its name; nil outside a raid
-- instance.
local function CurrentRaid()
    if not (GetInstanceInfo and ns.ItemDB and ns.ItemDB.GetRaidByInstance) then return nil end
    local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    local key = ns.ItemDB:GetRaidByInstance(tonumber(instanceID))
    if not key then return nil end
    return key, name
end

-- One switch row: the switch, its name (emph) and a one-line description under it (sub).
local function NewSwitchRow(w, body, i, feat)
    local UI = ns.UI
    local key = feat.key
    local y = START.HEAD_H + S.GAP + (i - 1) * (S.ROW.rich + S.GAP)
    local row = CreateFrame("Frame", nil, body)
    row:SetHeight(S.ROW.rich)
    row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    row:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -y)
    local get = function() return w.f[key] end
    local set = function(on)
        w.f[key] = on and true or false
        if key == "reserve" and on then w.f.loot = true end
        if key == "loot" and not on then w.f.reserve = false end
        if key == "loot" or key == "reserve" then SessionBar:SyncLockBox() end
    end
    local cb = UI.CreateSwitch and UI:CreateSwitch(row, get, set) or UI:CreateCheckbox(row, "", get, set)
    cb:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
    local textX = START.SWITCH_W + 12
    local label = UI:Text(row, "emph", "TEXT", { text = feat.label })
    label:SetPoint("TOPLEFT", row, "TOPLEFT", textX, 0)
    local desc = UI:Text(row, "sub", nil, { text = feat.desc })
    desc:SetPoint("TOPLEFT", row, "TOPLEFT", textX, -17)
    desc:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    cb.label = label
    if cb.SetHitRectInsets then cb:SetHitRectInsets(-2, -((label:GetStringWidth() or 0) + 14), -3, -3) end
    cb.tooltipText = feat.tip
    -- (the checkbox fallback has its own tooltip from tooltipText)
    if UI.CreateSwitch and cb.SetHover then UI:AttachTooltip(cb, feat.label, { feat.tip }) end
    w.boxes[key], w.labels[key], w.descs[key], w.rows[key] = cb, label, desc, row
end

-- The tool window: the raid's banner (what the session is, the note, the one action: Start raid / Apply), then the
-- three switches under "This raid runs". The window's X cancels.
local function CreateStartWindow()
    local UI = ns.UI
    local w = UI:CreateWindow("DisasterZoneRaidStart", "Start raid", START.W, START.H, { noSavePosition = true })
    w.f = LastFeatures()
    w.boxes, w.labels, w.descs, w.rows = {}, {}, {}, {}
    w.layout = UI:CreateLayout("tool", w.content, {
        width = START.W - 10,
        banner = { icon = UI.ICON.crown, kicker = "Raid session", title = "Start raid" },
    })
    local body = w.layout.body
    w.head = UI:CreateSectionHeader(body, "This raid runs", { style = "caps" })
    w.head:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    w.head:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
    for i, feat in ipairs(FEATURES) do NewSwitchRow(w, body, i, feat) end
    -- one quiet line under the switches: what is always logged / what Apply does / that the demo starts nothing
    w.note = UI:Text(body, "small", "DIM")
    w.note:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    w.note:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    w:Hide()
    startWin = w
    return w
end

-- The BiS lock needs the loot council (1.3): off and dimmed while the loot council is, its line says why.
function SessionBar:SyncLockBox()
    local w = startWin
    local cb = w and w.boxes and w.boxes.lock
    if not cb then return end
    local on = (w.f.loot and not w.f.reserve) and true or false
    if not on then w.f.lock = false end
    cb:SetEnabled(on)
    if w.labels and w.labels.lock then w.labels.lock:SetTextColor(S:Color(on and "TEXT" or "DIM")) end
    if w.descs and w.descs.lock then
        for _, feat in ipairs(FEATURES) do
            if feat.key == "lock" then
                w.descs.lock:SetText(on and feat.desc or (w.f.reserve and feat.offReserve or feat.off))
            end
        end
    end
    cb:Refresh()
    for _, k in ipairs({ "loot", "reserve" }) do
        local b = w.boxes[k]
        if b and b.Refresh then b:Refresh() end
    end
end

-- mode: "start" | "change" | "demo".
local function ShowStartWindow(mode, features)
    local w = startWin or CreateStartWindow()
    w.mode = mode
    w.f = features
    local title = mode == "change" and "Raid options" or (mode == "demo" and "Start raid (demo)" or "Start raid")
    w:SetWindowTitle(title)
    local banner = w.layout.banner
    local raidKey, zone = CurrentRaid()
    banner:SetArt(raidKey)
    banner:SetTitle(title)
    banner:SetSub(mode == "demo" and "Demo preview" or zone or "What this raid runs")
    w.note:SetText(mode == "demo" and "Demo: this only shows the window; nothing is started."
        or (mode == "change" and "Changes reach the raid at once." or
            "Attendance, boss kills and the loot handed out are always logged."))
    banner:SetActions({ { text = mode == "change" and "Apply" or "Start raid", kind = "primary", width = 110,
                          onClick = function() SessionBar:ConfirmStart() end } })
    w.startBtn = banner.actions[1]
    for _, cb in pairs(w.boxes) do
        if cb.Refresh then cb:Refresh() end
    end
    SessionBar:SyncLockBox()
    if not w:IsShown() then
        w:ClearAllPoints()
        w:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    end
    w:Show()
    w:Raise()
    return w
end

-- The Start raid button (the bar, the Raids tab): asks what the session runs, then starts it. true when the window
-- opened.
function SessionBar:OpenStart()
    if not IsInRaid() then
        if ns.Util.DemoOn() then
            ShowStartWindow("demo", LastFeatures())
            return true
        end
        ns:Print("A raid session can only run in a raid. (/dz demo on, then /dz raid options, shows the window.)")
        return false
    end
    if not IsAuthority() then
        ns:Print("Only the raid leader (the raid's loot authority) can start the raid.")
        return false
    end
    if Session() then return self:OpenOptions() end
    ShowStartWindow("start", LastFeatures())
    return true
end

-- The features of the running session (the authority); without a session the Start raid window.
function SessionBar:OpenOptions()
    if not (IsInRaid() and Session()) then return self:OpenStart() end
    if not IsAuthority() then
        ns:Print("Only the raid leader (the raid's loot authority) can change what the raid runs.")
        return false
    end
    local cur = ns.GroupRules:GetSessionFeatures() or LastFeatures()
    ShowStartWindow("change", { loot = cur.loot, rolls = cur.rolls, lock = cur.lock, reserve = cur.reserve })
    return true
end

-- The window's Start raid / Apply button.
function SessionBar:ConfirmStart()
    local w = startWin
    if not w then return false end
    local f = CleanPick(w.f)
    if w.mode == "demo" then
        ns:Print("Demo: a real raid would start now with %s.", SessionBar:DescribeFeatures(f))
        w:Hide()
        return true
    end
    if ns.db and ns.db.settings then ns.db.settings.raidStart = f end
    local ok, err
    if w.mode == "change" then
        ok, err = ns.GroupRules:SetSessionFeatures(f)
        if not ok then ns:Print("%s", tostring(err)) end
    else
        ok = ns.RaidLog:Start(nil, f)
    end
    if ok then w:Hide() end
    return ok and true or false
end

function SessionBar:GetStartWindow()
    return startWin
end

-- "loot council and rolls on, BiS lists locked" / "loot council and rolls off, BiS lists open".
function SessionBar:DescribeFeatures(f)
    local on, off = {}, {}
    for _, feat in ipairs({ { "loot", "loot council" }, { "rolls", "rolls" } }) do
        local list = f[feat[1]] and on or off
        list[#list + 1] = feat[2]
    end
    local parts = {}
    if #on > 0 then parts[#parts + 1] = table.concat(on, " and ") .. " on" end
    if #off > 0 then parts[#parts + 1] = table.concat(off, " and ") .. " off" end
    parts[#parts + 1] = f.lock and "BiS lists locked" or "BiS lists open"
    if f.reserve then return "reserves (the council keeps the guild's items), " .. table.concat(parts, ", ") end
    return table.concat(parts, ", ")
end

local function ConfirmEnd()
    if not (ns.Popup and ns.Popup.Confirm) then
        ns.RaidLog:End()
        return
    end
    ns.Popup:Confirm({
        key = "RAID_END",
        title = "End the raid",
        text = SessionBar:GetText() .. "\n\nThis finishes the raid log and unlocks the BiS lists.",
        ok = "End raid",
        onAccept = function() ns.RaidLog:End() end,
    })
end

-- The zone and the details of the running session, apart (the bar shows the zone as its title).
function SessionBar:GetParts()
    local s = Session()
    if not s then return nil end
    local RL = ns.RaidLog
    local rec = RL and RL:GetRaid(s.id)
    local kills = rec and #(rec.bosses or {}) or 0
    local total = rec and RL:GetRecordBossTotal(rec)
    return (rec and rec.zone) or "Raid", FormatDuration(GetServerTime() - (s.at or GetServerTime())),
        total and ("%d/%d bosses"):format(kills, total) or (kills == 1 and "1 boss" or (kills .. " bosses")),
        ns.GroupRules:IsLocked()
end

---------------------------------------------------------------------------
-- Who sees the crest
---------------------------------------------------------------------------
SessionBar.SHOW_OPTIONS = {
    { value = "auto", text = "When I lead or sit on the council" },
    { value = "always", text = "Always in a raid" },
    { value = "lead", text = "Only when I lead" },
    { value = "never", text = "Never" },
}

function SessionBar:ShowMode()
    local v = ns.DB and ns.DB.GetSetting and ns.DB:GetSetting("sessionBar.show")
    if v == "always" or v == "lead" or v == "never" then return v end
    return "auto"
end

-- "lead" (I run the session) | "council" (the loot council, the GM, an officer) | "raider".
function SessionBar:Audience()
    if IsAuthority() then return "lead" end
    local G, me = ns.Guild, ns.Util.PlayerKey()
    if G and me and ((G.AmICouncil and G:AmICouncil()) or (G.IsGM and G:IsGM(me))
        or (G.IsOfficer and G:IsOfficer(me))) then
        return "council"
    end
    return "raider"
end

-- "session" | "idle" (no session yet, inside a raid instance) | "light" (a raider who asked for it) | nil.
function SessionBar:GetState()
    local D = SI() and SI():IsDemo()
    if D then return D == "idle" and "idle" or "session" end
    if not IsInRaid() then return nil end
    local mode, aud = self:ShowMode(), self:Audience()
    if mode == "never" or (mode == "lead" and aud ~= "lead") then return nil end
    local s = Session()
    if s then
        if hiddenFor == s.id then return nil end
        if aud == "raider" then return mode == "always" and "light" or nil end
        return "session"
    end
    if aud == "raider" or idleDismissed or hiddenFor == "idle" or not ns.Util.InRaidInstance() then return nil end
    return "idle"
end

---------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------
local B = {}

function B.UI() return ns.UI end
function B.Smooth() return ns.HasAssets and ns:HasAssets(10) and ns.CTPen and ns.CTPen.RingTex and true or false end
function B.DiscTex() return B.Smooth() and (PEN .. "disc") or DISC end

-- A ring of radius r and stroke w on `parent`, centred on `on` (the smooth Pen ring; nil without art pack 10).
function B.Ring(parent, layer, sub)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:Hide()
    return t
end
function B.SetRing(t, on, r, w, cr, cg, cb, a)
    if not B.Smooth() then t:Hide() return end
    local tex, size = ns.CTPen.RingTex(r, w)
    t:SetTexture(tex)
    t:ClearAllPoints()
    t:SetPoint("CENTER", on, "CENTER", 0, 0)
    t:SetSize(size, size)
    t:SetVertexColor(cr, cg, cb, a or 1)
    t:Show()
end

function B.Demo() return SI() and SI():IsDemo() end
function B.DemoSays(what)
    ns:Print("Demo: %s (nothing is sent or started).", what)
end

-- The edge of a flat frame (1 px, a colour token or rgba).
function B.Edge(f, r, g, b, a)
    if not f.cdlEdges then B.UI():AddEdges(f, "BORDER") ; f.cdlEdges = true end
    B.UI():SetEdgeColor(f, r, g, b, a)
end

function B.Glyph(tex, icon, color)
    local UI = B.UI()
    local i = type(icon) == "string" and UI.ICON[icon] or icon
    UI:SetGlyph(tex, i, color)
end

function B.Name(key)
    local cls = info and info.cls and info.cls[key]
    return B.UI():ColoredName(key, cls)
end

function B.Over(fr)
    return fr and fr:IsShown() and fr.IsMouseOver and fr:IsMouseOver() and true or false
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------
local function Create()
    if crest then return crest end
    local UI = ns.UI
    -- (the place stays under the bar's frame name in settings.windows, as before 1.4)
    local f = UI:CreateHudFrame(FRAME_NAME, {
        width = C.SEAL, height = BAR.H, position = FRAME_NAME, look = "none", layout = "session",
        default = { "TOP", UIParent, "TOP", 0, ns.UI.TOAST.TOP + BAR.H + 8 },
    })
    f.cdlName = FRAME_NAME
    f:EnableMouse(false)

    -- the seal: a dark disc, the raid's art in a circle, a bead per boss round it, a count when something waits on me
    local seal = CreateFrame("Button", nil, f)
    seal:SetSize(C.SEAL, C.SEAL)
    seal:SetPoint("TOP", f, "TOP", 0, 0)
    seal:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    seal.bg = seal:CreateTexture(nil, "BACKGROUND", nil, 0)
    seal.bg:SetAllPoints()
    seal.bg:SetTexture(B.DiscTex())
    seal.bg:SetVertexColor(0.035, 0.035, 0.045, 0.9)
    seal.track = B.Ring(seal, "BORDER", 0)
    seal.art = seal:CreateTexture(nil, "ARTWORK", nil, 1)
    seal.art:SetSize(C.ART, C.ART)
    seal.art:SetPoint("CENTER")
    if seal.CreateMaskTexture then
        seal.mask = seal:CreateMaskTexture()
        seal.mask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        seal.mask:SetAllPoints(seal.art)
        seal.art:AddMaskTexture(seal.mask)
    end
    seal.edge = B.Ring(seal, "ARTWORK", 3)
    seal.beads = {}
    seal.badge = UI:CreateCountBadge(seal, 14)
    seal.badge:SetPoint("TOPRIGHT", seal, "TOPRIGHT", 3, 2)
    f.seal = seal

    -- the time under it (the fight's in red with a dot)
    local tp = CreateFrame("Frame", nil, f)
    tp:SetHeight(C.TIME_H)
    tp:SetPoint("TOP", seal, "BOTTOM", 0, -2)
    tp.bg = UI:Fill(tp, "HUD_BG", "BACKGROUND")
    B.Edge(tp, 0.4, 0.4, 0.42, 0.45)
    tp.text = UI:Text(tp, "num", "SUB")
    UI:SetTextSize(tp.text, "small")
    tp.text:SetPoint("CENTER", 0, 0)
    tp.dot = tp:CreateTexture(nil, "ARTWORK")
    tp.dot:SetTexture(B.DiscTex())
    tp.dot:SetSize(5, 5)
    tp.dot:SetVertexColor(S:Color("LIVE"))
    tp.dot:SetPoint("RIGHT", tp.text, "LEFT", -3, 0)
    f.time = tp

    -- the line beside the seal (hover / the drawer / before the start)
    -- (a frame of its own on the screen, so the seal's box stays the seal: Edit layout moves the seal, the line and
    -- the drawer follow it; hidden with it)
    local line = CreateFrame("Button", "DisasterZoneSessionLine", UIParent)
    line:SetFrameStrata("MEDIUM")
    line:SetHeight(C.LINE_H)
    line:Hide()
    line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    line.bg = UI:Fill(line, "HUD_BG", "BACKGROUND")
    line.zone = UI:Text(line, "title", "GOLD")
    line.meta = UI:Text(line, "sub")
    line.dots = {}
    line.chips = {}
    line.toggles = {}
    line.start = UI:CreateSleekButton(line, "Start raid", 76, C.CHIP_H, function() SessionBar:StartNow() end, "primary")
    line["end"] = UI:CreateSleekButton(line, "End raid", 66, C.CHIP_H, function() SessionBar:ConfirmEnd() end, "danger")
    line.x = CreateFrame("Button", nil, line)
    line.x:SetSize(C.X_W, C.X_W)
    line.x.icon = line.x:CreateTexture(nil, "ARTWORK")
    line.x.icon:SetAllPoints()
    line.x.icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
    line.x.icon:SetDesaturated(true)
    line.x.icon:SetAlpha(0.6)
    line.x:SetScript("OnClick", function()
        idleDismissed = true
        SessionBar:Update()
    end)
    UI:AttachTooltip(line.x, "Hide until the next instance")
    line.chev = line:CreateTexture(nil, "ARTWORK")
    line.chev:SetSize(11, 11)
    B.Glyph(line.chev, "chevron", "SUB")
    f.line = line

    -- hover slides the line out; leaving the seal, the line and the drawer slides it back
    local function enter() SessionBar:Peek(true) end
    local function leave() SessionBar:Peek(false) end
    seal:SetScript("OnEnter", enter)
    seal:SetScript("OnLeave", leave)
    line:SetScript("OnEnter", enter)
    line:SetScript("OnLeave", leave)
    local function click(_, button)
        if button == "RightButton" then SessionBar:OpenMenu(seal) else SessionBar:ToggleDrawer() end
    end
    seal:SetScript("OnClick", click)
    line:SetScript("OnClick", click)

    f:HookScript("OnHide", function()
        line:Hide()
        if ns.SessionDrawer then ns.SessionDrawer:Hide() end
    end)
    f:Hide()
    crest = f
    return f
end

-- A chip of the line: an edge, a glyph or item icons, a text, an optional count.
function B.Chip(line, i)
    local c = line.chips[i]
    if c then return c end
    local UI = B.UI()
    c = CreateFrame("Button", nil, line)
    c:SetHeight(C.CHIP_H)
    c.bg = UI:Fill(c, "QUIET", "BACKGROUND")
    c.glyph = c:CreateTexture(nil, "ARTWORK")
    c.glyph:SetSize(12, 12)
    c.icons = {}
    for k = 1, 3 do
        local t = c:CreateTexture(nil, "ARTWORK", nil, k)
        t:SetSize(C.ICON, C.ICON)
        t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        c.icons[k] = t
    end
    c.text = UI:Text(c, "body")
    c.badge = UI:CreateCountBadge(c, 13)
    c.after = UI:Text(c, "body", "GOLD")
    c:SetScript("OnEnter", function(self)
        SessionBar:Peek(true)
        if self.tip then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(self.tip[1], S:Color("GOLD"))
            for k = 2, #self.tip do GameTooltip:AddLine(self.tip[k], 0.8, 0.8, 0.8, true) end
            GameTooltip:Show()
        end
    end)
    c:SetScript("OnLeave", function()
        GameTooltip:Hide()
        SessionBar:Peek(false)
    end)
    c:SetScript("OnClick", function(self) if self.onClick then self.onClick(self) end end)
    line.chips[i] = c
    return c
end

-- o = { kind = "gold" | "warn" | "quiet", glyph, icons = { itemIDs }, text, count, after, tip = { title, lines... },
-- onClick }. Returns its width.
function B.FillChip(c, o)
    local UI = B.UI()
    local edge = o.kind == "gold" and S:WithAlpha("GOLD", 0.6) or (o.kind == "warn" and S:WithAlpha("WARN", 0.6))
        or { 0.43, 0.43, 0.46, 0.6 }
    B.Edge(c, edge[1], edge[2], edge[3], edge[4])
    c.bg:SetColorTexture(edge[1], edge[2], edge[3], o.kind == "quiet" and 0.04 or 0.07)
    local x = 6
    for k = 1, 3 do
        local id = o.icons and o.icons[k]
        local t = c.icons[k]
        t:ClearAllPoints()
        if id then
            t:SetTexture(UI:ItemIcon(id))
            t:SetPoint("LEFT", c, "LEFT", x, 0)
            x = x + C.ICON - 4
            t:Show()
        else
            t:Hide()
        end
    end
    if o.icons and o.icons[1] then x = x + 8 end
    c.glyph:ClearAllPoints()
    if o.glyph and not (o.icons and o.icons[1]) then
        B.Glyph(c.glyph, o.glyph, o.kind == "gold" and "GOLD" or (o.kind == "warn" and "WARN" or "SUB"))
        c.glyph:SetPoint("LEFT", c, "LEFT", x, 0)
        c.glyph:Show()
        x = x + 12 + 5
    else
        c.glyph:Hide()
    end
    c.text:SetText(o.text or "")
    c.text:ClearAllPoints()
    c.text:SetPoint("LEFT", c, "LEFT", x, 0)
    x = x + (c.text:GetStringWidth() or 0)
    c.badge:ClearAllPoints()
    if o.count and o.count > 0 then
        c.badge:SetCount(o.count)
        c.badge:SetPoint("LEFT", c, "LEFT", x + 6, 0)
        x = x + 6 + c.badge:GetWidth()
    else
        c.badge:SetCount(0)
    end
    c.after:SetText(o.after or "")
    c.after:ClearAllPoints()
    if o.after then
        c.after:SetPoint("LEFT", c, "LEFT", x + 4, 0)
        x = x + 4 + (c.after:GetStringWidth() or 0)
        c.after:Show()
    else
        c.after:Hide()
    end
    c.tip, c.onClick = o.tip, o.onClick
    local w = x + 8
    c:SetWidth(w)
    return w
end

-- An idle switch on the line (loot council / rolls / BiS lock): gold while on.
local TOGGLES = {
    { key = "loot", glyph = "ballot", title = "Loot council",
      on = "On: BiS candidates and council votes on every drop.", off = "Off: no BiS candidates or votes." },
    { key = "rolls", glyph = "games", title = "Rolls",
      on = "On: Roll / Pass pop-ups for everyone in the raid.", off = "Off: no roll pop-ups." },
    { key = "reserve", glyph = "reserve", title = "Reserves",
      on = "On: soft reserves decide the loot; the council keeps the guild's items.",
      off = "Off: the loot council and rolls as usual." },
    { key = "lock", glyph = "lock", title = "Lock everyone's BiS lists",
      on = "On: nobody edits their list until the raid ends.", off = "Off: lists stay open.",
      needs = "Needs the loot council (and no reserves)." },
}
function B.Toggle(line, i)
    local t = line.toggles[i]
    if t then return t end
    local UI = B.UI()
    t = CreateFrame("Button", nil, line)
    t:SetSize(C.TOGGLE_W, C.CHIP_H)
    t.bg = UI:Fill(t, S:WithAlpha("GOLD", 0.08), "BACKGROUND")
    t.glyph = t:CreateTexture(nil, "ARTWORK")
    t.glyph:SetSize(13, 13)
    t.glyph:SetPoint("CENTER")
    t.def = TOGGLES[i]
    t:SetScript("OnClick", function(self) SessionBar:FlipPick(self.def.key) end)
    t:SetScript("OnEnter", function(self)
        SessionBar:Peek(true)
        local d, on = self.def, pick and pick[self.def.key]
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(d.title, S:Color("GOLD"))
        GameTooltip:AddLine(on and d.on or d.off, 0.8, 0.8, 0.8, true)
        if d.needs and not (pick and pick.loot and not pick.reserve) then GameTooltip:AddLine(d.needs, S.C.WARN[1], S.C.WARN[2], S.C.WARN[3], true) end
        GameTooltip:AddLine("Click to turn it " .. (on and "off" or "on") .. ".", 0.5, 0.5, 0.52, true)
        GameTooltip:Show()
    end)
    t:SetScript("OnLeave", function()
        GameTooltip:Hide()
        SessionBar:Peek(false)
    end)
    line.toggles[i] = t
    return t
end

function B.PaintToggle(t)
    local key = t.def.key
    local on = pick and pick[key] and true or false
    local can = key ~= "lock" or (pick and pick.loot and not pick.reserve)
    if on then
        B.Edge(t, GOLD[1], GOLD[2], GOLD[3], 0.65)
        t.bg:Show()
        B.Glyph(t.glyph, t.def.glyph, "GOLD")
    else
        B.Edge(t, 0.43, 0.43, 0.46, can and 0.55 or 0.3)
        t.bg:Hide()
        B.Glyph(t.glyph, t.def.glyph, can and "SUB" or "DIM")
    end
    t:SetEnabled(can and true or false)
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
-- The seal's picture: the raid's art, or the boss's face while it is fought.
function B.SealArt(f, i, fighting)
    local seal = f.seal
    local b = fighting and i.fight and i.fight.i and i.bosses[i.fight.i]
    if b and b.portrait then
        seal.art:SetTexture(b.portrait)
        seal.art:SetTexCoord(0.25, 0.75, 0, 1)
    else
        local file, l, r, t, bt
        if ns.ItemDB and ns.ItemDB.RaidArt and i.raidKey then file, l, r, t, bt = ns.ItemDB:RaidArt(i.raidKey, 64, 64, 0.32) end
        if file then
            seal.art:SetTexture(file)
            seal.art:SetTexCoord(l or 0, r or 1, t or 0, bt or 1)
        else
            seal.art:SetTexture(ns.ItemDB and ns.ItemDB.RaidIcon and i.raidKey and ns.ItemDB:RaidIcon(i.raidKey)
                or "Interface\\Icons\\INV_Misc_QuestionMark")
            seal.art:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
    end
    -- (a dark gap between the picture and the ring, as in the mockup; the ring alone carries the colour)
    B.SetRing(seal.edge, seal.art, C.ART / 2 + 1, 2, 0.04, 0.04, 0.05, 0.9)
end

-- The ring round the seal: a segment per boss, clockwise from the top (gold killed, red fought now, grey still
-- ahead), the mockup's arcs: Media/Pen/arc<n> is segment 1 of a ring cut in n, turned into place for the others.
-- Without art pack 10 (or past 12 bosses): a bead per boss on a faint track instead.
local ARC_MID = (128 - 1 - 9.6) / 256         -- the arc's stroke middle, as a share of its texture (gen_pen_media)
function B.Beads(f, i, fighting)
    local seal = f.seal
    local n = #(i.bosses or {})
    if n == 0 then n = i.total or 0 end
    local arcs = B.Smooth() and n >= 1 and n <= 12
    B.SetRing(seal.track, seal, C.BEAD_R, 1, 0.6, 0.6, 0.64, (n > 0 and not arcs) and 0.28 or 0)
    seal.arcs = seal.arcs or {}
    local size = C.BEAD_R / ARC_MID
    for k = 1, max(n, #seal.beads, #seal.arcs) do
        local t, s = seal.beads[k], seal.arcs[k]
        if k <= n then
            local b = i.bosses and i.bosses[k]
            local killed = (b and b.killed) or (not b and k <= (i.kills or 0))
            local live = fighting and i.fight and i.fight.i == k
            local r, g, bl, a = 0.59, 0.59, 0.62, 0.45
            if live then r, g, bl, a = LIVE[1], LIVE[2], LIVE[3], 1
            elseif killed then r, g, bl, a = GOLD[1], GOLD[2], GOLD[3], 1 end
            if arcs then
                if not s then
                    s = seal:CreateTexture(nil, "OVERLAY", nil, 1)
                    seal.arcs[k] = s
                end
                s:SetTexture(PEN .. "arc" .. n)
                s:SetSize(size, size)
                s:ClearAllPoints()
                s:SetPoint("CENTER", seal, "CENTER", 0, 0)
                if s.SetRotation then s:SetRotation(n > 1 and -(k - 0.5) / n * 2 * math.pi or 0) end
                s:SetVertexColor(r, g, bl, a)
                s:Show()
                if t then t:Hide() end
            else
                if not t then
                    t = seal:CreateTexture(nil, "OVERLAY", nil, 1)
                    t:SetTexture(B.DiscTex())
                    seal.beads[k] = t
                end
                local ang = (k - 0.5) / n * 2 * math.pi
                local sz = (killed or live) and C.BEAD or C.BEAD_SM
                t:SetSize(sz, sz)
                t:ClearAllPoints()
                t:SetPoint("CENTER", seal, "CENTER", math.sin(ang) * C.BEAD_R, math.cos(ang) * C.BEAD_R)
                t:SetVertexColor(r, g, bl, math.max(a, 0.75))
                t:Show()
                if s then s:Hide() end
            end
        else
            if t then t:Hide() end
            if s then s:Hide() end
        end
    end
end

-- The time pill: the session's h:mm, the fight's m:ss (red), "not started".
function B.Time(f, i, state, fighting)
    local tp = f.time
    local Info = SI()
    local text
    if fighting and i.fight then
        text = Info:Clock(GetTime() - (i.fight.since or GetTime()), true)
        tp.text:SetTextColor(1, 0.69, 0.65)
        B.Edge(tp, LIVE[1], LIVE[2], LIVE[3], 0.5)
    else
        if state == "idle" then
            text = "not started"
        else
            local el = i.el or 0
            if i.at then el = max(0, GetServerTime() - i.at) end
            text = Info:Clock(el)
        end
        tp.text:SetTextColor(S:Color("SUB"))
        B.Edge(tp, 0.4, 0.4, 0.42, 0.45)
    end
    tp.text:SetText(text)
    tp.dot:SetShown(fighting and true or false)
    tp:SetWidth(floor((tp.text:GetStringWidth() or 30) + (fighting and 18 or 12)))
end

-- The line's chips while the raid runs (only what has something to say).
function B.Chips(i, aud)
    local out = {}
    local lead = aud == "lead"
    local drops = i.drops or {}
    if #drops > 0 and aud ~= "raider" then
        local icons = {}
        for k = 1, min(3, #drops) do icons[k] = drops[k].itemID end
        local need = i.needVote or 0
        out[#out + 1] = { kind = (need > 0 or lead) and "gold" or "quiet", icons = icons,
            text = #drops == 1 and "1 drop" or (#drops .. " drops"), count = need > 0 and need or nil,
            after = need > 0 and "your vote" or nil,
            tip = { #drops == 1 and "1 drop waiting" or (#drops .. " drops waiting"),
                    need > 0 and ("%d %s on your vote."):format(need, need == 1 and "waits" or "wait") or "Nobody has them yet.",
                    "Click: the drop panel." },
            onClick = function() SessionBar:OpenDrops() end }
    end
    local trades = i.trades or {}
    if #trades > 0 and (lead or (i.myTrades or 0) > 0) then
        local soon = trades[1].expires - GetServerTime()
        out[#out + 1] = { kind = "gold", glyph = "bag", text = #trades .. " to trade",
            after = SI():Clock(soon) .. " left",
            tip = { #trades .. " to trade", "Awarded under Free for All and still in the looter's bags. "
                .. "The trade window closes in " .. SI():Clock(soon) .. ".", "Click: the list." },
            onClick = function() SessionBar:ToggleDrawer(true) end }
    end
    if lead then
        local left, missing = #(i.left or {}), #(i.missing or {})
        if left + missing > 0 then
            local parts = {}
            if left > 0 then parts[#parts + 1] = left .. " left" end
            if missing > 0 then parts[#parts + 1] = missing .. " missing" end
            local names = {}
            for _, l in ipairs(i.left or {}) do names[#names + 1] = B.Name(l.key) .. " left" end
            for _, k in ipairs(i.missing or {}) do names[#names + 1] = B.Name(k) .. " isn't here" end
            out[#out + 1] = { kind = "quiet", glyph = "team", text = table.concat(parts, " · "),
                tip = { "Attendance", table.concat(names, ", "), "Click: tick what they said or swap someone in." },
                onClick = function() SessionBar:OpenAttendance() end }
        end
        if i.unlinked then
            out[#out + 1] = { kind = "warn", glyph = "calendar", text = "Not linked",
                tip = { "Not linked to a planned raid", "Attendance and boss reminders need the planned raid.",
                        "Click: pick it." },
                onClick = function(self) SessionBar:OpenLinkMenu(self) end }
        end
    end
    return out
end

-- The line: what it holds by state and audience, laid out left to right; returns its width.
function B.FillLine(f, i, state, aud)
    local line = f.line
    local UI = B.UI()
    local x = C.LINE_X
    local used = {}
    local function put(fr, w, gap)
        fr:ClearAllPoints()
        fr:SetPoint("LEFT", line, "LEFT", x, 0)
        fr:Show()
        used[fr] = true
        x = x + w + (gap or C.CHIP_GAP)
    end
    line.zone:SetText(i.zone or "Raid")
    local quiet = state == "light" or (state == "idle" and aud ~= "lead")
    line.zone:SetTextColor(S:Color(quiet and "TEXT" or "GOLD"))
    put(line.zone, line.zone:GetStringWidth() or 100, 8)
    local nChips = 0
    if state == "idle" then
        if aud == "lead" then
            local lu = i.lineup
            if lu then
                nChips = nChips + 1
                local c = B.Chip(line, nChips)
                put(c, B.FillChip(c, { kind = "quiet", glyph = "pair", text = lu.title .. (lu.team and (" · " .. lu.team) or ""),
                    tip = { "Planned raid", "Starting now links the raid to " .. lu.title .. (lu.t and date(" (%H:%M)", lu.t) or "")
                        .. ". Attendance counts against its lineup." } }))
                if (lu.total or 0) > 0 then
                    nChips = nChips + 1
                    local names = {}
                    for _, k in ipairs(lu.missing or {}) do names[#names + 1] = B.Name(k) end
                    c = B.Chip(line, nChips)
                    put(c, B.FillChip(c, { kind = "quiet", glyph = "team", text = ("%d of %d here"):format(lu.here, lu.total),
                        tip = { ("%d of %d signed up are here"):format(lu.here, lu.total),
                                #names > 0 and ("Not here: " .. table.concat(names, ", ")) or "Everyone who signed up is here." } }))
                end
            end
            for k = 1, #TOGGLES do
                local t = B.Toggle(line, k)
                B.PaintToggle(t)
                put(t, C.TOGGLE_W, k == #TOGGLES and 8 or 3)
            end
            put(line.start, line.start:GetWidth(), 4)
        else
            line.meta:SetText("not started · the loot council is off until "
                .. (i.leader and B.Name(i.leader) or "the raid leader") .. " starts the raid")
            put(line.meta, line.meta:GetStringWidth() or 200, 6)
        end
        put(line.x, C.X_W, 0)
        x = x + 6
    else
        -- the bosses as dots (the seal's beads, in a row)
        -- (the mockup's diamonds: gold killed, an outline for the next one and the rest; dots without the art)
        local n = #(i.bosses or {})
        local nextK
        for k = 1, n do if not i.bosses[k].killed then nextK = k break end end
        for k = 1, max(n, #line.dots) do
            local d = line.dots[k]
            if k <= n then
                if not d then
                    d = line:CreateTexture(nil, "ARTWORK")
                    line.dots[k] = d
                end
                local killed = i.bosses[k].killed
                if B.Smooth() then
                    d:SetTexture(PEN .. (killed and "diamond" or "diamondline"))
                    d:SetSize(9, 9)
                else
                    d:SetTexture(B.DiscTex())
                    d:SetSize(killed and 6 or 5, killed and 6 or 5)
                end
                if killed then d:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
                elseif k == nextK then d:SetVertexColor(0.95, 0.86, 0.58, 1)
                else d:SetVertexColor(0.42, 0.42, 0.45, 1) end
                put(d, B.Smooth() and 9 or 6, k == n and 8 or 2)
            elseif d then
                d:Hide()
            end
        end
        if state == "light" then
            line.meta:SetText(SI():Clock(i.el or 0))
            put(line.meta, line.meta:GetStringWidth() or 30, 6)
        else
            for _, o in ipairs(B.Chips(i, aud)) do
                nChips = nChips + 1
                local c = B.Chip(line, nChips)
                put(c, B.FillChip(c, o))
            end
            -- (every boss down: End raid on the line; the open drawer has its own)
            if aud == "lead" and not f.open and (i.total or 0) > 0 and (i.kills or 0) >= i.total then
                put(line["end"], line["end"]:GetWidth(), 6)
            end
            line.chev:ClearAllPoints()
            line.chev:SetPoint("LEFT", line, "LEFT", x + 1, 0)
            if f.open then line.chev:SetTexCoord(B.ChevCoords(true)) else line.chev:SetTexCoord(B.ChevCoords(false)) end
            line.chev:Show()
            used[line.chev] = true
            x = x + 13 + 4
        end
    end
    -- whatever this state did not use goes
    for k = nChips + 1, #line.chips do line.chips[k]:Hide() end
    for _, fr in ipairs({ line.meta, line.start, line["end"], line.x, line.chev }) do
        if not used[fr] then fr:Hide() end
    end
    for _, t in ipairs(line.toggles) do if not used[t] then t:Hide() end end
    for _, d in ipairs(line.dots) do if not used[d] then d:Hide() end end
    local w = floor(x + C.LINE_X - C.CHIP_GAP)
    line:SetWidth(w)
    line.bg:SetColorTexture(S:Color("HUD_BG"))
    if quiet then B.Edge(line, 0.43, 0.43, 0.46, 0.55) else B.Edge(line, GOLD[1], GOLD[2], GOLD[3], 0.55) end
    return w
end

-- The chevron glyph pointing down (closed) or up (open).
function B.ChevCoords(up)
    local c = B.UI():IconCoords(B.UI().ICON.chevron)
    if up then return c[1], c[2], c[4], c[3] end
    return c[1], c[2], c[3], c[4]
end

-- Which way the line and the drawer open: toward the middle of the screen.
function B.Sides(f)
    local cx, cy = f:GetCenter()
    local W, H = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
    local left = cx and W > 0 and cx > W / 2 or false
    local up = cy and H > 0 and cy < H * 0.4 or false
    return left, up
end

function B.PlaceLine(f, left)
    local line = f.line
    line:ClearAllPoints()
    if left then
        line:SetPoint("RIGHT", f.seal, "LEFT", -C.GAP, 0)
    else
        line:SetPoint("LEFT", f.seal, "RIGHT", C.GAP, 0)
    end
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
-- Draws the crest from `info` (SessionBar:Update builds it).
function SessionBar:Render()
    local f = crest
    if not (f and info) then return end
    local state = self.state or "session"
    local aud = B.Demo() and "lead" or (self.previewing and "lead") or self:Audience()
    local fighting = state ~= "idle" and info.fight ~= nil
    B.SealArt(f, info, fighting)
    B.Beads(f, info, fighting)
    B.Time(f, info, state, fighting)
    local need = (state == "session" and not fighting and SI()) and SI():NeedsMe(info) or 0
    f.seal.badge:SetCount(need)
    local left, up = B.Sides(f)
    local showLine = not fighting and not self.previewing and (state == "idle" or f.peek or f.open)
    if fighting then f.open = false end
    if showLine then
        B.PlaceLine(f, left)
        B.FillLine(f, info, state, aud)
    end
    f.line:SetShown(showLine and true or false)
    local D = ns.SessionDrawer
    if D then
        if showLine and f.open and state ~= "light" then
            D:Show(f, info, { state = state, aud = aud, left = left, up = up, name = B.Name })
        else
            D:Hide()
        end
    end
    f:SetAlpha(fighting and 0.75 or 1)
end

-- Builds the table and draws it (or hides the crest).
function SessionBar:Update()
    if self.previewing then return end
    local state = self:GetState()
    self:MaybeToast(state)
    if not state then
        if crest then
            crest:Hide()
            crest.open, crest.peek = false, false
            if ns.SessionDrawer then ns.SessionDrawer:Hide() end
        end
        B.StopTicker()
        return
    end
    local f = Create()
    self.state = state
    info = SI() and SI():Get() or nil
    if not info then
        f:Hide()
        B.StopTicker()
        return
    end
    if state == "idle" and not pick then pick = self:LastFeatures() end
    if state ~= "idle" then pick = nil end
    f:Show()
    self:Render()
    B.StartTicker()
end

function SessionBar:RequestUpdate()
    ns.Util.Debounce("dz-session-crest", 0.2, function() SessionBar:Update() end)
end

-- Every second the time; every 15 s (and on events) the whole table.
function B.StartTicker()
    if B.ticker or not (C_Timer and C_Timer.NewTicker) then return end
    local n = 0
    B.ticker = C_Timer.NewTicker(1, function()
        if not (crest and crest:IsShown() and info) then return end
        n = n + 1
        if n % 15 == 0 then SessionBar:Update() return end
        local fighting = SessionBar.state ~= "idle" and info.fight ~= nil
        B.Time(crest, info, SessionBar.state, fighting)
    end)
end

function B.StopTicker()
    if B.ticker then B.ticker:Cancel() end
    B.ticker = nil
end

function SessionBar:Peek(on)
    local f = crest
    if not f then return end
    if on then
        if not f.peek then
            f.peek = true
            self:Render()
        end
        return
    end
    if not (C_Timer and C_Timer.After) then return end
    C_Timer.After(0.35, function()
        if not (crest and crest.peek) then return end
        local D = ns.SessionDrawer
        if B.Over(crest.seal) or B.Over(crest.line) or (D and D.IsMouseOver and D:IsMouseOver()) then return end
        crest.peek = false
        SessionBar:Render()
    end)
end

-- The drawer opens and closes on a click (on = force it open).
function SessionBar:ToggleDrawer(on)
    local f = crest
    if not (f and info) or self.state == "light" then return end
    if self.state ~= "idle" and info.fight then return end
    if on then f.open = true else f.open = not f.open end
    self:Render()
end

function SessionBar:IsDrawerOpen() return crest and crest.open or false end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------
function SessionBar:LastFeatures() return LastFeatures() end

-- An idle switch flipped (the lock needs the loot council).
function SessionBar:FlipPick(key)
    pick = pick or LastFeatures()
    if key == "lock" and not (pick.loot and not pick.reserve) then return end
    pick[key] = not pick[key]
    if key == "loot" and not pick.loot then pick.lock, pick.reserve = false, false end
    if key == "reserve" and pick.reserve then pick.loot, pick.rolls, pick.lock = true, true, false end
    self:Render()
    ns:Fire("RESERVES_CHANGED")
end

function SessionBar:GetPick() return pick end

-- Start raid on the line: what the switches say, no window.
function SessionBar:StartNow()
    pick = pick or LastFeatures()
    local f = CleanPick(pick)
    if B.Demo() then
        B.DemoSays("a real raid would start now with " .. self:DescribeFeatures(f))
        return true
    end
    if not IsAuthority() then
        ns:Print("Only the raid leader (the raid's loot authority) can start the raid.")
        return false
    end
    if ns.db and ns.db.settings then ns.db.settings.raidStart = f end
    return ns.RaidLog:Start(nil, f) and true or false
end

-- A switch in the drawer: changes what the running raid runs at once (turning the loot council off asks first).
function SessionBar:SetFeature(key, on)
    if B.Demo() then
        B.DemoSays(("%s would turn %s"):format(key == "loot" and "the loot council" or key, on and "on" or "off"))
        return true
    end
    if not (Session() and IsAuthority()) then return false end
    local cur = ns.GroupRules:GetSessionFeatures() or LastFeatures()
    local f = { loot = cur.loot and true or false, rolls = cur.rolls and true or false,
                lock = ns.GroupRules:IsLocked() and true or false, reserve = cur.reserve and true or false }
    f[key] = on and true or false
    if not f.loot then f.lock, f.reserve = false, false end
    f = CleanPick(f)
    local function apply()
        local ok, err = ns.GroupRules:SetSessionFeatures(f)
        if ok then
            if ns.db and ns.db.settings then ns.db.settings.raidStart = f end
        elseif err then
            ns:Print("%s", tostring(err))
        end
        SessionBar:Update()
    end
    if key == "loot" and not on and cur.loot and ns.Popup and ns.Popup.Confirm then
        ns.Popup:Confirm({
            key = "RAID_COUNCIL_OFF",
            title = "Turn the loot council off?",
            text = "From now on drops get no BiS candidates or council votes; rolls (when on) go to the highest "
                .. "roll. The BiS lists unlock.",
            ok = "Turn it off",
            onAccept = apply,
            onCancel = function() SessionBar:Update() end,
        })
        return true
    end
    apply()
    return true
end

-- The drop panel at the newest drop that waits on me (else the newest waiting one).
function SessionBar:OpenDrops()
    local drops = info and info.drops or {}
    local e
    for _, d in ipairs(drops) do if d.needMe then e = d break end end
    e = e or drops[1]
    if not e then return end
    if B.Demo() or e.demo then B.DemoSays("the drop panel would open on that drop") return end
    if ns.DropPanel and ns.DropPanel.ShowDrop and e.drop then ns.DropPanel:ShowDrop(e.drop) end
end

function SessionBar:OpenAttendance()
    if B.Demo() then B.DemoSays("the attendance prompt would open") return end
    if ns.AttendanceUI and ns.AttendanceUI.ShowLeaderPrompt then ns.AttendanceUI:ShowLeaderPrompt() end
end

-- The planned raids near the session's start; picking one links the raid (the leader for everyone).
function SessionBar:OpenLinkMenu(owner)
    local RP = ns.RaidPlan
    local s = Session()
    if B.Demo() then B.DemoSays("the planned raids of tonight would be listed") return end
    if not (RP and s and ns.UI.ContextMenu) then return end
    ns.UI:ContextMenu(owner, function(root)
        root:CreateTitle("Planned raid")
        for _, v in ipairs(RP:GetRaids((s.at or 0) - 4 * 3600, (s.at or 0) + 3 * 3600)) do
            root:CreateRadio(("%s  %s"):format(date("%a %H:%M", v.t), RP:GetRaidName(v)),
                function() return s.rp == v.id end, function() ns.RaidLink:SetLink(v.id) end)
        end
        root:CreateRadio("Not linked", function() return s.rp == nil end, function() ns.RaidLink:SetLink(nil) end)
    end)
end

function SessionBar:Pull(secs)
    if B.Demo() then B.DemoSays(("a %d s pull timer would start"):format(secs)) return end
    if ns.BossMod and ns.BossMod.SendPull then ns.BossMod:SendPull(secs) end
end

function SessionBar:Break(minutes)
    if B.Demo() then B.DemoSays(("a %d minute break would start"):format(minutes)) return end
    if ns.BossMod and ns.BossMod.SendBreak then ns.BossMod:SendBreak(minutes) end
end

function SessionBar:OpenStrategy(bossRef)
    if B.Demo() then B.DemoSays("the strategy board would open on that boss") return end
    local occ = info and info.link and info.link.occ
    if occ and ns.StrategyBoard and ns.StrategyBoard.OpenRaid then ns.StrategyBoard:OpenRaid(occ, bossRef) end
end

-- "Come and trade me for <item>" to the winner.
function SessionBar:WhisperTrade(t)
    if B.Demo() then B.DemoSays("a whisper would go out") return end
    local name = t and t.to and ns.Util.ShortName(t.to, true)
    if not (name and SendChatMessage) then return end
    local link = C_Item and C_Item.GetItemInfo and select(2, C_Item.GetItemInfo(t.itemID)) or ns.UI:ItemName(t.itemID) or "your item"
    SendChatMessage(("I have %s for you: open a trade with me."):format(link), "WHISPER", nil, name)
end

-- Right-click: hide it for this raid, its settings, Edit layout.
function SessionBar:OpenMenu(owner)
    local UI = ns.UI
    if not UI.ContextMenu then return end
    UI:ContextMenu(owner, function(root)
        root:CreateButton(UI:AtlasIconText(UI.ICON.eye, 14) .. " Hide for this raid", function()
            local s = Session()
            hiddenFor = s and s.id or "idle"
            if B.Demo() then SI():SetDemo(nil) end
            SessionBar:Update()
        end)
        root:CreateButton(UI:AtlasIconText(UI.ICON.gear, 14) .. " Session bar settings", function()
            if not ns.MainFrame then return end
            ns.MainFrame:Open("settings")
            if ns.SettingsUI and ns.SettingsUI.SelectSection then ns.SettingsUI:SelectSection("session") end
        end)
        root:CreateButton(UI:AtlasIconText(UI.ICON.more, 14) .. " Move it (Edit layout)", function()
            local EM = ns.EditMode
            if EM and EM.Open then
                EM:Open()
                if EM.Select then pcall(EM.Select, EM, { "session" }) end
            end
        end)
    end)
end

-- Raiders who don't see the crest get one pop-up when the raid starts: what runs, their list locked.
function SessionBar:MaybeToast(state)
    local s = Session()
    if not s or toasted[s.id] or B.Demo() then return end
    if state or IsAuthority() or not IsInRaid() then
        toasted[s.id] = true
        return
    end
    toasted[s.id] = true
    if GetServerTime() - (s.at or 0) > 120 then return end      -- (a /reload mid-raid: no pop-up)
    local UI = ns.UI
    if not (UI and UI.Toast) then return end
    local feats = ns.GroupRules:GetSessionFeatures() or {}
    local on = {}
    if feats.loot then on[#on + 1] = "Loot council" end
    if feats.rolls then on[#on + 1] = (#on > 0 and "rolls" or "Rolls") end
    local text = #on > 0 and (table.concat(on, " and ") .. " on") or "No loot council or rolls tonight"
    if ns.GroupRules:IsLocked() then text = text .. " · your BiS list is locked until the raid ends" end
    if feats.reserve then text = "Soft reserves decide the loot · the council keeps the guild's items" end
    local now = SI() and SI():Get()
    local key = now and now.raidKey
    local art
    if key and ns.ItemDB and ns.ItemDB.RaidArt then
        local file, l, r, t, b = ns.ItemDB:RaidArt(key, 112, 64)
        if file then art = { file, l, r, t, b } end
    end
    local rec = ns.RaidLog and ns.RaidLog:GetRaid(s.id)
    UI:Toast({ key = "dz-raid-start", kicker = "Raid started · by " .. (ns.Util.ShortName(s.by) or "?"),
               title = (rec and rec.zone) or "Raid", text = text, art = art, duration = 10 })
end

---------------------------------------------------------------------------
-- Demo, Edit layout, settings
---------------------------------------------------------------------------
-- /dz raid bar <moment> in demo mode: the crest with a made-up night (idle, between, pull, loot, done; off).
function SessionBar:Demo(moment)
    local Info = SI()
    if not Info then return false end
    if moment == "off" or moment == nil or moment == "" then
        Info:SetDemo(nil)
        self:Update()
        return true
    end
    if not ns.Util.DemoOn() then
        ns:Print("Turn demo mode on first (/dz demo on), then /dz raid bar idle | between | pull | loot | done.")
        return false
    end
    if not Info.DEMO_MOMENTS or not ({ idle = 1, between = 1, pull = 1, loot = 1, done = 1 })[moment] then
        ns:Print("/dz raid bar idle | between | pull | loot | done | off")
        return false
    end
    hiddenFor, idleDismissed = nil, false
    Info:SetDemo(moment)
    self:Update()
    if crest and moment == "loot" then crest.open = true; self:Render() end
    return true
end

-- Edit layout: the crest with made-up facts while it isn't up (Core/Layout.lua "session").
function SessionBar:Preview(on)
    if not on then
        if self.previewing then
            self.previewing = nil
            self:Update()
        end
        return
    end
    if crest and crest:IsShown() then return end
    local f = Create()
    self.previewing = true
    self.state = "session"
    info = SI():Demo("between")
    f.open, f.peek = false, false
    f:Show()
    self:Render()
end

function SessionBar:GetFrame()
    return crest
end

function SessionBar:GetInfo() return info end

function SessionBar:ConfirmEnd()
    if B.Demo() then B.DemoSays("the raid would end (after a confirmation)") return end
    ConfirmEnd()
end

-- Settings > Loot > Raid session (UI/Settings.lua's card "session").
function SessionBar:BuildSettings(SU, sec)
    sec.y = sec.y - 4
    SU:DropdownSetting(sec, "Show the session crest", "Raiders who don't see it get one pop-up when the raid starts.",
        "sessionBar.show", "auto", SessionBar.SHOW_OPTIONS,
        "Who runs the raid and the council see what waits on them: drops, votes, trades, who left. "
        .. "Right-click the crest to hide it for one raid.")
    SU:EndSection(sec)
end

function SessionBar:OnInit()
    ns.Layout:Register("session", { name = "Raid session crest", group = "Loot", order = 10, when = "in a raid",
        frame = function() return crest end, default = { "TOP", 0, ns.UI.TOAST.TOP + BAR.H + 8 },
        legacy = function()
            local p = ns.UI:SavedPosition(FRAME_NAME)
            if p then return p[1], p[2], p[3], p[4] end
        end,
        preview = function(on) SessionBar:Preview(on) end })
    local function update() SessionBar:Update() end
    local function soon() SessionBar:RequestUpdate() end
    ns:On("GROUP_RULES_CHANGED", update)
    ns:On("RAIDLOG_CHANGED", update)
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", update)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if not ns.Util.InRaidInstance() then
            idleDismissed = false
            if hiddenFor == "idle" then hiddenFor = nil end
        end
        update()
    end)
    for _, m in ipairs({ "SESSION_INFO_CHANGED", "ROLL_UPDATED", "ROLL_STARTED", "DROP", "LEDGER_UPDATED",
                         "RAIDPLAN_CHANGED", "DEMO_TOGGLED", "SETTINGS_CHANGED" }) do
        ns:On(m, soon)
    end
end

function SessionBar:OnLogin()
    self:Update()
end
