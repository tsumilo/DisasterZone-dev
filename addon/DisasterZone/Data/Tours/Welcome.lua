if DisasterZoneBoot and DisasterZoneBoot.Run("Data/Tours/Welcome.lua", ...) then return end -- DisasterZone: Data/Tours/Welcome.lua
-- The Welcome tour (1.3.5; the engine: UI/Tour.lua, the offer and Settings > Tutorials: UI/WelcomeTour.lua). One part
-- (a chapter) per role: Everyone, Raid leader, Officer, Guild council, Guild Master. A player runs the parts of the
-- roles they hold (who); roles stack, so the GM gets all five. Each step opens the page it is about on the main
-- window and lights a real control; nothing here changes how a page works, and no step sends or saves anything: the
-- council part runs on demo data (demo = true), the rest only explains. Controls are looked up while the step runs
-- (by their field, else by their text), so a page that isn't built yet or a control that isn't there for this player
-- leaves the box at the foot of the window instead.
local addonName, ns = ...

local function MF() return ns.MainFrame end
local function G() return ns.Guild end
local function Me() return ns.Util.PlayerKey() end

-- Opens a place: a page key ("home"), a share-link page ("raidlog", "teams"), or "settings/<section>".
local function go(place)
    local mf = MF()
    if not mf then return end
    local page, sub = string.match(place, "^(%a+)/(%a+)$")
    if page == "settings" then
        mf:Open("settings")
        if ns.SettingsUI and ns.SettingsUI.SelectSection then ns.SettingsUI:SelectSection(sub) end
        return
    end
    local Share = ns.Share
    if Share and Share.PAGES and Share.PAGES[place] then
        Share:Open(place)
        return
    end
    mf:Open(place)
end

local function shown(f) return type(f) == "table" and f.IsVisible and f:IsVisible() and f or nil end
local function panel(key) return shown(MF() and MF():GetPanel(key)) end
local function navTab(key) return shown(MF() and MF():GetNavTabs()[key]) end

-- The first visible frame under root (depth first) whose text is `text` (a button, a tab).
local function findText(root, text, depth)
    depth = depth or 0
    if not shown(root) or depth > 12 then return nil end
    if root.GetText then
        local ok, t = pcall(root.GetText, root)
        if ok and t == text then return root end
    end
    for _, child in ipairs({ root:GetChildren() }) do
        local hit = findText(child, text, depth + 1)
        if hit then return hit end
    end
    return nil
end

-- An anchor for a step: fn() looks the control up; it is kept in the step's ctx while it stays on screen.
local function spot(fn)
    return function(ctx)
        if ctx and shown(ctx.f) then return ctx.f end
        local f = fn()
        if ctx then ctx.f = f end
        return f
    end
end
local function byText(pageKey, text)
    return spot(function() return findText(panel(pageKey), text) end)
end

local function raidsView(view)
    return function()
        go("raids")
        if ns.RaidsUI and ns.RaidsUI.SetView then ns.RaidsUI:SetView(view) end
    end
end
local function raidsField(field)
    return spot(function()
        local p = ns.RaidsUI and ns.RaidsUI:GetPanel()
        return p and shown(p[field])
    end)
end
local function councilView(view)
    return function()
        go("council")
        if ns.CouncilUI and ns.CouncilUI.SetView then ns.CouncilUI:SetView(view) end
    end
end
local function section(key)
    return spot(function()
        local S = ns.SettingsUI
        return S and S.sections and shown(S.sections[key])
    end)
end

local GREY = "|cff9e9e9e"

---------------------------------------------------------------------------
-- Everyone
---------------------------------------------------------------------------

local everyone = {
    { title = "Welcome to DisasterZone",
      text = "Your guild's raids, loot council, BiS lists and more, in one window. This part shows where things are.\n\n"
          .. "Next and Back move through it, the bar at the foot jumps between parts, and Exit stops it: Settings > "
          .. "Help goes on from where you stopped.",
      enter = function() go("home") end },
    { title = "Your next raid", side = "bottom",
      text = "The guild's next raids slide by here. Accept, Tentative, or the ··· button for Decline and a note: the "
          .. "raid leader sees your answer at once.",
      enter = function() go("home") end,
      anchor = spot(function() local p = panel("home"); return p and shown(p.banner) end) },
    { title = "What needs you", side = "bottom",
      text = "Chips beside the greeting say what waits for you: a raid to answer, a poll, an empty BiS phase, news. "
          .. "Click one to go there.",
      enter = function() go("home") end,
      anchor = spot(function() local p = panel("home"); return p and shown(p.hello) end) },
    { title = "The guild's calendar", side = "right",
      text = "Raids, events and dungeon runs by day. Click a day to see what's on it.",
      enter = function() go("home") end,
      anchor = spot(function() local p = panel("home"); return p and shown(p.calCard) end) },
    { title = "The menus", side = "bottom",
      text = "Raids, Gear and Guild each hold several pages. Rest the mouse on one to see them, click it to open "
          .. "the page you used last.",
      hint = "rest the mouse on Raids.",
      enter = function() go("home") end,
      anchor = function() return navTab("grp:raids"), navTab("grp:gear"), navTab("grp:guild") end,
      done = function() return ns.NavMenu ~= nil and ns.NavMenu:IsOpen() end, stay = true },
    { title = "Your BiS list", side = "left",
      text = "Pick your best in slot items for each phase. The loot council reads these lists when a drop is handed "
          .. "out: an empty list means they can't see what you need.",
      enter = function() go("mybis") end,
      anchor = spot(function() return panel("mybis") end) },
    { title = "How loot is decided", side = "left",
      text = "The guild's loot rules, the same for everyone: how the council's suggestion is made, the prized items "
          .. "and where you stand for each one.",
      skip = function() return not (MF() and MF():IsPageShown("lootrules")) end,
      enter = function() go("lootrules") end,
      anchor = spot(function() return panel("lootrules") end) },
    { title = "When a boss drops loot",
      text = "In a raid, the drop panel opens with the boss's items. Answer on the ones you want; the loot council "
          .. "or a roll decides who gets each, and you see it there.\n\n" .. GREY .. "Settings > Loot changes how "
          .. "it looks.|r",
      enter = function() go("home") end },
    { title = "Notifications", side = "bottom",
      text = "The bell counts what needs you: raids to answer, polls, votes, reviews. Click it for the list; "
          .. "Settings > Alerts chooses what pops up.",
      anchor = function() return ns.NotifyUI and shown(ns.NotifyUI:GetBell()) end },
    { title = "Feedback, news and settings", side = "bottom",
      text = "Send the developer a bug or an idea (the speech bubble), read what's new (the page) and change your "
          .. "settings (the cog). Settings > Help has this tour and the strategy board's.",
      anchor = function() return navTab("feedback"), navTab("changelog"), navTab("settings") end },
}

---------------------------------------------------------------------------
-- Raid leader (the GM and the raid leaders on the list)
---------------------------------------------------------------------------

local leader = {
    { title = "Plan a raid", side = "bottom",
      text = "New raid opens a sheet: the instance, the night, the team and who leads it. A weekly raid repeats by "
          .. "itself, and the players of its team get the sign-up reminder.",
      enter = raidsView("upcoming"), anchor = raidsField("newRaidBtn") },
    { title = "Teams", side = "bottom",
      text = "A team is one roster with lineups for 10 and 25 players, and a waitlist. Its raid nights show on the "
          .. "board before anyone joins.",
      enter = raidsView("upcoming"), anchor = raidsField("teamsBtn") },
    { title = "Sign-ups and groups",
      text = "Open a raid for its sign-ups. Groups places the players in the raid's groups, Assignments fills the "
          .. "bosses' strategies with them.",
      enter = raidsView("upcoming"),
      anchor = spot(function() return panel("raids") end) },
    { title = "Strategies", side = "bottom",
      text = "The boss strategy boards. On a raid's page you pick the ones it uses; its players see their own jobs "
          .. "on them. The board has its own tutorial (its ? button).",
      enter = raidsView("upcoming"), anchor = raidsField("stratBtn") },
    { title = "Running the raid",
      text = "When the group is formed, the WoW group leader starts the raid from the bar at the top of the screen: "
          .. "attendance and boss kills are logged from then on, and loot council sessions start.\n\n" .. GREY
          .. "End raid stops it; a raid left running ends by itself.|r" },
    { title = "The raid log", side = "bottom",
      text = "Every raid the guild ran: who came, who was late or left early, the bosses and the loot.",
      enter = raidsView("upcoming"), anchor = raidsField("logBtn") },
}

---------------------------------------------------------------------------
-- Officer
---------------------------------------------------------------------------

local officer = {
    { title = "Every raid",
      text = "Officers see every raid on the board, the locked ones too, and can add players to any raid.",
      enter = raidsView("upcoming"),
      anchor = spot(function() return panel("raids") end) },
    { title = "Raid leaders", side = "bottom",
      text = "The crown on Raids > Teams: who plans and leads raids besides the Guild Master. Officers and the GM "
          .. "change the list; the people on it make raids, teams and groups.",
      enter = raidsView("teams"), anchor = raidsField("leadersBtn") },
    { title = "Polls", side = "bottom",
      text = "Ask the guild: yes or no, one answer, several, or pick days. You see who answered; they see the "
          .. "results when you choose.",
      skip = function() return not (MF() and MF():IsPageShown("polls")) end,
      enter = function() go("polls") end, anchor = byText("polls", "New poll") },
    { title = "Guests and the blacklist", side = "bottom",
      text = "Players from outside the guild who raided with you, with notes, and the blacklist: a blacklisted "
          .. "player can't be invited or sign up.",
      skip = function() return not (ns.RaidPlan and ns.RaidPlan:CanManageRoster()) end,
      enter = raidsView("upcoming"), anchor = raidsField("guestsBtn") },
    { title = "Attendance reviews", side = "bottom",
      text = "When a raider comes late or leaves early it waits under Raid log > Reviews for the GM, an officer or "
          .. "the guild council. Excuse it and it never counts; Counts puts it in their attendance.",
      enter = raidsView("upcoming"), anchor = raidsField("logBtn") },
}

---------------------------------------------------------------------------
-- Guild council (runs on demo data)
---------------------------------------------------------------------------

local council = {
    { title = "On demo data",
      text = "This part runs on demo data: made-up raiders, lists and loot, so every view has something in it. "
          .. "Nothing is sent or saved, and demo mode switches off again when the part ends.",
      enter = councilView("items") },
    { title = "Who needs what", side = "left",
      text = "Each boss's drops and the raiders who have them on their BiS list (alt marks an alt's list). Click a "
          .. "name for that raider's whole list.",
      enter = councilView("items"), anchor = spot(function() return panel("council") end) },
    { title = "The roster", side = "left",
      text = "Every raider: their lists, how many slots are filled, their attendance and what they got.",
      enter = councilView("roster"), anchor = spot(function() return panel("council") end) },
    { title = "Voting on a drop",
      text = "In a raid with the loot council on, each drop shows on the drop panel with everyone who wants it, "
          .. "ranked by the guild's rules. Council members vote; the suggestion is on top, and the master looter "
          .. "hands it out.\n\n" .. GREY .. "Settings > Help > Demo a roll shows one.|r",
      enter = councilView("items") },
    { title = "The loot log", side = "left",
      text = "Everything handed out: who got what, as what (BiS, upgrade, off spec), and the votes.",
      enter = councilView("log"), anchor = spot(function() return panel("council") end) },
    { title = "Rules and prized items", side = "left",
      text = "How the suggestion is made: the Guild Master's rules. Prized items (a legendary, a trophy) get stricter "
          .. "rules of their own, which the guild council can change.",
      enter = councilView("rules"), anchor = spot(function() return panel("council") end) },
}

---------------------------------------------------------------------------
-- Guild Master
---------------------------------------------------------------------------

local function checklistText()
    local W = ns.WelcomeTour
    local items = W and W:Checklist() or {}
    local lines, n = {}, 0
    for _, it in ipairs(items) do
        if it.done then n = n + 1 end
        lines[#lines + 1] = (it.done and "|TInterface\\RAIDFRAME\\ReadyCheck-Ready:12|t " or "|cff9e9e9e-|r ") .. it.label
            .. (it.done and "" or (GREY .. "  " .. it.where .. "|r"))
    end
    return ("%d of %d done. Each line here opens its page, and Home shows a chip until it's all done.\n\n")
        :format(n, #items) .. table.concat(lines, "\n")
end

local gm = {
    { title = "Who decides the loot", side = "left",
      text = "Your guild council votes on drops in every raid. You are on it; Edit council adds officers or trusted "
          .. "raiders, and only you can change it.",
      enter = function() go("settings/council") end,
      anchor = spot(function() return findText(panel("settings"), "Edit council") end) },
    { title = "The loot rules", side = "left",
      text = "How the council's suggestion is made: the order of the checks, votes, attendance, longest use. Only "
          .. "you change them; everyone can read them on Raids > Loot rules.",
      enter = councilView("rules"), anchor = spot(function() return panel("council") end) },
    { title = "Attendance", side = "left",
      text = "How many minutes late or how long a disconnect counts against someone. Everyone sees these numbers.",
      enter = function() go("settings/attendance") end, anchor = section("attendance") },
    { title = "Group loot rules", side = "left",
      text = "What the addon does with the game's loot settings in a raid (master looter, threshold).",
      enter = function() go("settings/rules") end, anchor = section("rules") },
    { title = "Set up your guild", side = "left",
      text = function() return checklistText() end,
      enter = function()
          go("settings/setup")          -- (Settings > Guild > Guild set-up)
          if ns.SettingsUI and ns.SettingsUI.ShowSetupChecklist then ns.SettingsUI:ShowSetupChecklist() end
      end,
      anchor = function()
          local t = ns.SettingsUI and ns.SettingsUI.tut
          if not t then return nil end
          return shown(t.setupHead), shown(t.setup[1]), shown(t.setup[2]), shown(t.setup[3]), shown(t.setup[4]),
              shown(t.setup[5])
      end },
}

---------------------------------------------------------------------------

local PART = {
    all     = { "Everyone", { 0.85, 0.85, 0.87 } },
    leader  = { "Raid leader", { 0.50, 0.88, 0.56 } },
    officer = { "Officer", { 0.56, 0.71, 1 } },
    council = { "Guild council", { 1, 0.70, 0.28 } },
    gm      = { "Guild Master", ns.Style.C.GOLD },
}

local function who(role)
    return function()
        local W = ns.WelcomeTour
        return W ~= nil and W:Roles()[role] == true
    end
end

ns.Tour:Register("welcome", {
    title = "Welcome tour", menuTitle = "Welcome tour", bar = true, boxInside = true,
    host = function() return MF() and MF():GetFrame() end,
    open = function()
        if not MF() then return false end
        if not MF():IsShown() then MF():Open("home") end
        return MF():IsShown() and true or false
    end,
    alive = function() return MF() ~= nil and MF():IsShown() end,
    close = function() if ns.WelcomeTour then ns.WelcomeTour:OnTourClosed() end end,
    chapters = {
        { key = "all", title = PART.all[1], color = PART.all[2], steps = everyone },
        { key = "leader", title = PART.leader[1], color = PART.leader[2], who = who("leader"), steps = leader },
        { key = "officer", title = PART.officer[1], color = PART.officer[2], who = who("officer"), steps = officer },
        { key = "council", title = PART.council[1], color = PART.council[2], who = who("council"), demo = true,
          steps = council },
        { key = "gm", title = PART.gm[1], color = PART.gm[2], who = who("gm"), steps = gm },
    },
})
