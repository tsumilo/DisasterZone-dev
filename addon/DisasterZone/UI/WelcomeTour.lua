if DisasterZoneBoot and DisasterZoneBoot.Run("UI/WelcomeTour.lua", ...) then return end -- DisasterZone: UI/WelcomeTour.lua
-- The Welcome tour around its engine (UI/Tour.lua) and its parts (Data/Tours/Welcome.lua): which parts are mine (my
-- roles), the one-time offer, the offer of one part when I get a new role, and the Guild Master's set-up checklist.
--
-- The offer: a pop-up over the main window, the first time it opens after install (never in combat, an instance or
-- a raid group, nor over another pop-up: then the next time it opens). It lists the parts for my roles, each can be
-- left out; Start, Not now and its X all count as an answer, so it never comes back by itself. The tour stays in
-- Settings > Tutorials (and /dz tour).
-- A new role later (an officer, the guild council, the raid leaders list): a notification (a pop-up, the bell, a Home
-- chip) offers that part, once per role (Settings > Tutorials can turn these off). Not in demo mode.
-- The set-up checklist (the GM): what is left to set up, read from the guild as it is now; a Home chip until it is
-- done or hidden.
-- Saved with the tour's progress (ns.db.tours.welcome: account-wide): known = { [role] = true } (the roles the tour
-- knows about: no offer for them), roleAt = { [role] = first seen }, setupHidden.
local addonName, ns = ...

local W = ns:NewModule("WelcomeTour")
local S = ns.Style

local floor, max = math.floor, math.max

local ID = "welcome"
local DAY = 86400

local function UI() return ns.UI end
local function G() return ns.Guild end
local function Me() return ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey() end
local function T() return ns.Tour end
local function Demo() return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() and true or false end

-- The parts in order: key, label, atlas icon (art pack 7, else the older one), colour, steps' minutes, one line.
W.ORDER = { "all", "leader", "officer", "council", "gm" }
W.PARTS = {
    all = { label = "Everyone", icon = 61, old = 46, color = { 0.85, 0.85, 0.87 }, min = 3,
            line = "Raids, answers, your BiS list, loot, where things are." },
    leader = { label = "Raid leader", icon = 50, old = 50, color = { 0.50, 0.88, 0.56 }, min = 2,
               line = "Plan a raid, teams, groups, strategies, the raid log." },
    officer = { label = "Officer", icon = 62, old = 52, color = { 0.56, 0.71, 1 }, min = 2,
                line = "Every raid, raid leaders, polls, guests, attendance." },
    council = { label = "Guild council", icon = 64, old = 25, color = { 1, 0.70, 0.28 }, min = 3,
                line = "Who needs what, votes, the loot log, prized items." },
    gm = { label = "Guild Master", icon = 26, old = 26, color = S.C.GOLD, min = 2,
           line = "Set up your guild: council, rules, attendance." },
}
-- The roles a new-role offer is about (Everyone is not a role one gets).
local ROLE_NEWS = {
    leader = { title = "You're a raid leader now", text = "You can plan raids, teams and groups." },
    officer = { title = "You're an officer now", text = "You see every raid, and pick the raid leaders." },
    council = { title = "You're on the guild council now", text = "You see the lists and vote on drops." },
    gm = { title = "You're the Guild Master now", text = "Set up the council, the loot rules and attendance." },
}

function W:Icon(key)
    local p = W.PARTS[key]
    if not p then return 25 end
    return (ns.HasAssets and ns:HasAssets(7)) and p.icon or p.old
end

function W:Steps(key)
    local def = T() and T():Get(ID)
    for _, ch in ipairs(def and def.chapters or {}) do
        if ch.key == key then return #ch.steps end
    end
    return 0
end

local function Progress()
    local p = T() and T():Progress(ID) or {}
    if type(p.known) ~= "table" then p.known = {} end
    if type(p.roleAt) ~= "table" then p.roleAt = {} end
    return p
end
W.Progress = Progress

local function Settings() return ns.db and ns.db.settings end

-- New-role offers (nil = on).
function W:RoleOffersOn()
    local s = Settings()
    return not (s and s.tourRoleOffers == false)
end

function W:SetRoleOffers(on)
    local s = Settings()
    if s then s.tourRoleOffers = (not on) and false or nil end
    if ns.Notify and ns.Notify.Refresh then ns.Notify:Refresh("tourRole") end
end

---------------------------------------------------------------------------
-- Roles
---------------------------------------------------------------------------

-- The parts that are mine: { all = true, leader = true, ... }. Raid leader: the GM and the raid leaders on the list.
function W:Roles(key)
    key = key or Me()
    local out = { all = true }
    local g = G()
    if not (g and key) then return out end
    if g.IsRaidPlanner and g:IsRaidPlanner(key) then out.leader = true end
    if g.IsOfficer and g:IsOfficer(key) then out.officer = true end
    if g.IsGuildCouncil and g:IsGuildCouncil(key) then out.council = true end
    if g.IsGM and g:IsGM(key) then out.gm = true end
    return out
end

-- The roles are known once the guild roster has loaded (else everyone looks like a plain raider).
local function RolesReady()
    local g = G()
    return IsInGuild() and g ~= nil and g.IsReady ~= nil and g:IsReady() and true or false
end

-- The tour knows these roles now (answered the offer, took or turned down a part): no offer for them.
local function Learn(roles)
    local p = Progress()
    for k in pairs(roles) do p.known[k] = true end
end

---------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------

-- Starts the tour: only = { [part] = true } (nil: every part for my roles), peek = another role's part on demo data.
function W:Start(only, peek)
    -- (Close, not Hide: one hidden with the window would come back with it, over the tour)
    if ns.ChangelogPopup then ns.ChangelogPopup:Close() end
    if W.offerFrame then W.offerFrame.suspended = nil end
    if W.offerFrame and W.offerFrame:IsShown() then
        W.answering = true          -- (closing it here is no answer of its own: the tour starting is)
        W.offerFrame:Hide()
        W.answering = nil
    end
    Learn(self:Roles())
    local first
    for _, k in ipairs(W.ORDER) do
        if not only or only[k] then
            first = k
            break
        end
    end
    return T():Start(ID, only and first or nil, { only = only, peek = peek, resume = not peek })
end

-- One part (Settings > Tutorials, a new-role offer): from where it was left unless done.
function W:StartPart(key, peek)
    local p = Progress()
    if p.done[key] and not peek then p.at[key] = nil end
    return self:Start({ [key] = true }, peek)
end

function W:OnTourClosed()
    ns:Fire("TOUR_CHANGED", ID)
    if ns.Notify and ns.Notify.Refresh then
        ns.Notify:Refresh("tourRole")
        ns.Notify:Refresh("guildSetup")
    end
end

-- A part's state for Settings > Tutorials: "done" | "at" (left on step n) | "new", n, steps.
function W:PartState(key)
    local p = Progress()
    local steps = self:Steps(key)
    if p.at[key] then return "at", p.at[key], steps end
    if p.done[key] then return "done", steps, steps end
    return "new", 0, steps
end

---------------------------------------------------------------------------
-- The offer (once): a sheet over the main window (UI:CreateSheet): a tool banner, my roles as chips, a row per part
-- (ticked: in the tour), Start the tour / Not now in its foot
---------------------------------------------------------------------------

local POP_W, ROW_H = 470, 46

local function NewPartRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(ROW_H)
    UI():DecorateRow(r, { rule = true })
    r.cb = UI():CreateCheckbox(r, "", function() return r.on end, function(on)
        r.on = on and true or false
        W:PaintOffer()
    end)
    r.cb:SetPoint("LEFT", 4, 0)
    r.face = UI():CreateFace(r, 30)
    r.face:SetPoint("LEFT", 34, 0)
    r.title = UI():Text(r, "emph", "TEXT")
    r.title:SetPoint("TOPLEFT", r, "TOPLEFT", 74, -9)
    r.note = UI():Text(r, "small", "SUB")
    r.note:SetPoint("LEFT", r.title, "RIGHT", 6, 0)
    r.line = UI():Text(r, "small", "SUB")
    r.line:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -4)
    r.mins = UI():Text(r, "small", "SUB", { justify = "RIGHT" })
    r.mins:SetPoint("RIGHT", r, "RIGHT", -4, 0)
    r:SetScript("OnClick", function() r.cb:Click() end)
    return r
end

local function BuildOffer()
    local host = ns.MainFrame and ns.MainFrame:GetFrame()
    if not host then return nil end
    local sh = UI():CreateSheet(host, { name = "DisasterZoneWelcomeOffer", title = "Welcome tour", width = POP_W,
        height = 400, foot = "Asked once. It stays in Settings > Tutorials.",
        ok = { text = "Start the tour", width = 120, onClick = function() W:AnswerOffer(true) end },
        cancel = "Not now", withWindow = true })
    -- Not now, its X and Escape answer it (all go through Close). Closing the window only hides it unanswered (it
    -- goes with the window): it is offered again the next time the window opens.
    sh.Close = function() W:AnswerOffer(false) end
    sh.box = sh
    sh.start, sh.later = sh.ok, sh.cancel
    sh.top = UI():CreatePageBanner(sh.body, { size = "tool", width = POP_W - 2 * UI().SHEET.PAD,
        kicker = "Welcome to DisasterZone", sub = "It shows what you can do here, in a few minutes. You are:" })
    sh.top:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 0, 0)
    sh.top:SetPoint("TOPRIGHT", sh.body, "TOPRIGHT", 0, 0)
    sh.pills = {}
    sh.rows = {}
    return sh
end

-- Fills the offer for my roles (the rows keep their ticks while it is open).
function W:PaintOffer()
    local o = W.offerFrame
    if not o then return end
    local f = o.box
    local roles = self:Roles()
    local name = UI().ColoredName and UI():ColoredName(Me()) or (ns.Util.ShortName(Me() or ""))
    f.top:SetTitle("A short tour, made for you, " .. (name or ""))
    -- my roles as chips in the parts' colours (Everyone is not a role)
    local x, n, list = 0, 0, {}
    for _, k in ipairs({ "gm", "council", "officer", "leader" }) do
        if roles[k] then list[#list + 1] = { k, W.PARTS[k].label } end
    end
    if #list == 0 then list[1] = { "all", "A raider" } end
    for i, d in ipairs(list) do
        n = i
        local p = f.pills[i]
        if not p then
            p = UI():CreateChip(f.body)
            f.pills[i] = p
        end
        p:Set(d[2], W.PARTS[d[1]].color)
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", f.body, "TOPLEFT", x, -S.BANNER.tool - S.GAP)
        p:Show()
        x = x + p:GetWidth() + 6
    end
    UI():HideFrom(f.pills, n + 1)
    local y, k, picked = -S.BANNER.tool - S.GAP - 18 - S.GAP, 0, 0
    for _, key in ipairs(W.ORDER) do
        if roles[key] then
            k = k + 1
            local r = f.rows[k] or NewPartRow(f.body)
            f.rows[k] = r
            if r.key ~= key then
                r.key, r.on = key, true
            end
            local d = W.PARTS[key]
            r.face:SetGlyph(W:Icon(key), W.PARTS[key].color)
            r.title:SetText(d.label)
            r.note:SetText(key == "leader" and roles.gm and "as the GM you plan raids too" or "")
            r.line:SetText(d.line)
            r.mins:SetText(("%d steps \194\183 ~%d min"):format(W:Steps(key), d.min))
            r.cb:SetChecked(r.on)
            r.title:SetAlpha(r.on and 1 or 0.45)
            r.line:SetAlpha(r.on and 1 or 0.45)
            r.face:SetAlpha(r.on and 1 or 0.45)
            if r.on then picked = picked + 1 end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", f.body, "TOPLEFT", 0, y)
            r:SetPoint("RIGHT", f.body, "RIGHT", 0, 0)
            r:Show()
            y = y - ROW_H
        end
    end
    for i = k + 1, #f.rows do
        f.rows[i]:Hide()
        f.rows[i].key = nil
    end
    f.start:SetEnabled(picked > 0)
    local SH = UI().SHEET
    f:SetHeight(floor(SH.HEAD_H + SH.PAD - y + SH.PAD + SH.FOOT_H + 0.5))
end

-- Opens the offer over the main window (opening it if needed). Returns true when shown.
function W:OpenOffer()
    if ns.MainFrame and not ns.MainFrame:IsShown() then ns.MainFrame:Open("home") end
    local o = W.offerFrame or BuildOffer()
    if not o then return false end
    W.offerFrame = o
    local E = ns.EventUI
    if E and E.ArtCoords then
        local path, l, r, t, b = E:ArtCoords("outland", POP_W, S.BANNER.tool, 0.5, 0.55, 0.95)
        o.top:SetArt({ path, l, r, t, b })
    end
    for _, r in ipairs(o.box.rows) do r.key = nil end
    self:PaintOffer()
    o:Open()
    return true
end

-- Start (true) or not now (false): either way the offer is answered for good.
function W:AnswerOffer(start)
    local o = W.offerFrame
    local only
    if o then o.suspended = nil end      -- (answered while it waited for the window: it does not come back)
    if o and o:IsShown() then
        only = {}
        for _, r in ipairs(o.box.rows) do
            if r:IsShown() and r.key and r.on then only[r.key] = true end
        end
        W.answering = true
        o:Hide()
        W.answering = nil
    end
    local p = Progress()
    p.seen = true
    Learn(self:Roles())
    if start then return self:Start(only) end
    ns:Print("The Welcome tour is in Settings > Tutorials whenever you want it (or /dz tour).")
    ns:Fire("TOUR_CHANGED", ID)
    return false
end

-- Is now a good moment to ask? The window is open, nothing else is in the way, I'm not busy.
function W:CanOffer()
    if Progress().seen then return false end
    if not RolesReady() then return false end
    if InCombatLockdown() then return false end
    if IsInInstance and select(2, IsInInstance()) ~= "none" and select(2, IsInInstance()) ~= nil then return false end
    if IsInRaid and IsInRaid() then return false end
    if not (ns.MainFrame and ns.MainFrame:IsShown()) then return false end
    if T():IsRunning() then return false end
    if ns.ChangelogPopup and ns.ChangelogPopup:IsShown() then return false end
    if ns.Popup and ns.Popup.IsShown and ns.Popup:IsShown() then return false end
    return true
end

function W:MaybeOffer()
    if self:CanOffer() then return self:OpenOffer() end
    return false
end

---------------------------------------------------------------------------
-- The Guild Master's set-up checklist
---------------------------------------------------------------------------

-- { { key, label, sub, done, where, open = fn } } (the GM's; read from the guild as it is now).
function W:Checklist()
    local g, RP = G(), ns.RaidPlan
    local out = {}
    local cg = g and g.GetGuildCouncil and g:GetGuildCouncil()
    local others = 0
    for key in pairs(cg and cg.members or {}) do
        if not (g.IsGM and g:IsGM(key)) then others = others + 1 end
    end
    out[#out + 1] = { key = "council", label = "Guild council", where = "Settings",
        sub = others > 0 and (others + 1 .. " members") or "Who votes on drops besides you",
        done = cg ~= nil and others > 0, open = function() W:Go("settings/council") end }
    local leaders = g and g.GetRaidLeaders and g:GetRaidLeaders() or {}
    out[#out + 1] = { key = "leaders", label = "Raid leaders", where = "Raids",
        sub = #leaders > 0 and (#leaders .. " on the list") or "Who plans raids besides you",
        done = #leaders > 0, open = function()
            W:Go("raids")
            if ns.RaidLeadersUI then ns.RaidLeadersUI:Open() end
        end }
    local lrBy = g and g.GetLootRulesBy and g:GetLootRulesBy()
    out[#out + 1] = { key = "rules", label = "Loot rules", where = "Council",
        sub = lrBy and "Set" or "How the council's suggestion is made", done = lrBy ~= nil,
        open = function()
            W:Go("council")
            if ns.CouncilUI then ns.CouncilUI:SetView("rules") end
        end }
    local arBy = g and g.GetAttendanceRulesBy and g:GetAttendanceRulesBy()
    out[#out + 1] = { key = "attendance", label = "Attendance minutes", where = "Settings",
        sub = arBy and "Set" or "When late and left early start to count", done = arBy ~= nil,
        open = function() W:Go("settings/attendance") end }
    local raids = 0
    if RP and RP.GetRaids then
        local ok, list = pcall(RP.GetRaids, RP, ns.Util.Now() - 30 * DAY, ns.Util.Now() + 30 * DAY, true)
        raids = ok and type(list) == "table" and #list or 0
    end
    out[#out + 1] = { key = "raid", label = "A first raid night", where = "Raids",
        sub = raids > 0 and "On the calendar" or "New raid on Raids > Upcoming", done = raids > 0,
        open = function() W:Go("raids") end }
    return out
end

function W:ChecklistCount()
    local n, list = 0, self:Checklist()
    for _, it in ipairs(list) do if it.done then n = n + 1 end end
    return n, #list
end

function W:IsSetupHidden() return Progress().setupHidden == true end

function W:SetSetupHidden(on)
    Progress().setupHidden = on and true or nil
    if ns.Notify and ns.Notify.Refresh then ns.Notify:Refresh("guildSetup") end
    ns:Fire("TOUR_CHANGED", ID)
end

-- Opens a place ("home", a share-link page, "settings/<section>").
function W:Go(place)
    local MF = ns.MainFrame
    if not MF then return end
    local page, sub = string.match(place, "^(%a+)/(%a+)$")
    if page == "settings" then
        MF:Open("settings")
        if ns.SettingsUI and ns.SettingsUI.SelectSection then ns.SettingsUI:SelectSection(sub) end
    elseif ns.Share and ns.Share.PAGES and ns.Share.PAGES[place] then
        ns.Share:Open(place)
    else
        MF:Open(place)
    end
end

---------------------------------------------------------------------------
-- Notifications: a new role, the set-up checklist
---------------------------------------------------------------------------

local function atlas(i) return { tex = UI().ICON_ATLAS, coords = UI():IconCoords(i) } end

local function RegisterKinds()
    local N = ns.Notify
    if not (N and N.RegisterKind) then return end
    N:RegisterKind("tourRole", {
        section = "DisasterZone", icon = 25, color = { 1, 0.70, 0.28 },
        label = "New role", desc = "You got a new role in the guild: a short tour of what it lets you do.",
        needsYou = false, popup = true, sound = false, home = true,
        kicker = function() return "New role" end,
        open = function(it) W:TakeRole(it.key) end,
        actions = function(it)
            return { { text = "Show me", primary = true, fn = function() W:TakeRole(it.key) end },
                     { text = "No thanks", fn = function() W:SkipRole(it.key) end } }
        end,
        chip = function(it) return { kind = "info", icon = atlas(W:Icon(it.key)) } end,
    })
    N:RegisterSource("tourRole", function()
        local out = {}
        if Demo() or not W:RoleOffersOn() or not RolesReady() then return out end
        local p = Progress()
        if not p.seen then return out end           -- the first offer covers every role
        local roles = W:Roles()
        for _, k in ipairs(W.ORDER) do
            local news = ROLE_NEWS[k]
            if news and roles[k] and not p.known[k] and not p.done[k] then
                p.roleAt[k] = p.roleAt[k] or ns.Util.Now()
                out[#out + 1] = { key = k, title = news.title,
                    text = news.text .. (" A short tour shows it: %d steps."):format(W:Steps(k)),
                    short = "Tour: " .. W.PARTS[k].label, time = p.roleAt[k] }
            end
        end
        return out
    end, { "TOUR_CHANGED", "CONFIG_UPDATED", "ROSTER_UPDATED", "ACCOUNTS_UPDATED" })

    N:RegisterKind("guildSetup", {
        section = "DisasterZone", icon = 26, color = S.C.GOLD,
        label = "Set up your guild", desc = "The Guild Master's checklist: what is left to set up.",
        needsYou = false, popup = false, sound = false, home = true,
        open = function() W:Go("settings/tutorials") end,
        actions = function()
            return { { text = "Open", primary = true, fn = function() W:Go("settings/tutorials") end },
                     { text = "Hide", fn = function() W:SetSetupHidden(true) end } }
        end,
        chip = function() return { kind = "info", icon = atlas(26) } end,
    })
    N:RegisterSource("guildSetup", function()
        local g = G()
        if Demo() or W:IsSetupHidden() or not RolesReady() or not (g and g:IsGM(Me())) then return {} end
        local n, total = W:ChecklistCount()
        if n >= total then return {} end
        local title = ("Set up your guild \194\183 %d of %d"):format(n, total)
        return { { key = "setup", title = title, text = "What is left: Settings > Tutorials.", short = title } }
    end, { "TOUR_CHANGED", "CONFIG_UPDATED", "ROSTER_UPDATED", "LOOT_RULES_CHANGED",
           "ATTENDANCE_RULES_CHANGED", "RAIDPLAN_CHANGED" })
end

-- A new role's offer, taken or turned down: the tour knows the role from now on.
function W:TakeRole(key)
    Progress().known[key] = true
    if ns.Notify then ns.Notify:Refresh("tourRole") end
    return self:StartPart(key)
end

function W:SkipRole(key)
    Progress().known[key] = true
    if ns.Notify then ns.Notify:Refresh("tourRole") end
    ns:Fire("TOUR_CHANGED", ID)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function W:OnInit()
    RegisterKinds()
    ns:RegisterSlash("tour", function() W:SlashTour() end, "the Welcome tour: the parts for your roles")
end

function W:SlashTour()
    if T():IsRunning(ID) then return end
    if not Progress().seen then return self:OpenOffer() end
    if not self:Start(nil) then ns:Print("Nothing to show right now.") end
end

function W:OnLogin()
    -- the offer comes when the window opens (the first time after install), not at login
    local MF = ns.MainFrame
    if MF and MF.Open and not W.hooked then
        W.hooked = true
        hooksecurefunc(MF, "Open", function()
            if Progress().seen then return end
            C_Timer.After(0.8, function() W:MaybeOffer() end)
        end)
    end
end
