if DisasterZoneBoot and DisasterZoneBoot.Run("UI/NotifySources.lua", ...) then return end -- DisasterZone UI/NotifySources.lua
-- The notification kinds of the sections that had none of their own (Core/Notify.lua explains kinds and sources).
-- Each source reads the same Core data its page does, so the bell, Home's chips and the pages always agree. The
-- order here is the order of Settings > Notifications.
local addonName, ns = ...

local NotifySources = ns:NewModule("NotifySources")

local DAY = 86400
local function Now() return (GetServerTime and GetServerTime()) or time() end
local function UI() return ns.UI end
local function Short(key) return ns.Util and ns.Util.ShortName and ns.Util.ShortName(key) or tostring(key) end
local function Me() return ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey() end

local function openTab(key) if ns.MainFrame then ns.MainFrame:Open(key) end end

local function openRaid(occId)
    openTab("raids")
    if ns.RaidsUI and ns.RaidsUI.SetView then ns.RaidsUI:SetView("upcoming") end
    local PUI = ns.RaidPlanUI
    if PUI and occId and PUI.SelectRaid then PUI:SelectRaid(occId) end
end

local function openRun(id)
    if ns.DungeonsUI and ns.DungeonsUI.Focus then ns.DungeonsUI:Focus(id) else openTab("dungeons") end
end

local function roleIcon(role)
    local l, r, t, b = UI():RoleCoords(role)
    return { tex = UI().ROLE_TEX, coords = { l, r, t, b } }
end

local function atlas(i) return { tex = UI().ICON_ATLAS, coords = UI():IconCoords(i) } end

-- A raid's name for a chip ("Kara", the raid's own short title), as Home writes it.
local function shortRaid(v)
    local D = ns.Dashboard
    if D and D.ShortRaidName then return D:ShortRaidName(v) end
    return ns.RaidPlan:GetRaidName(v)
end

local function closesText(t)
    if not t then return nil end
    local d = t - Now()
    if d <= 0 then return "closed" end
    if d < 3600 then return "closes in " .. math.max(1, math.floor(d / 60)) .. " min" end
    if d < DAY and date("%d", t) == date("%d", Now()) then return "closes today " .. date("%H:%M", t) end
    if d < 2 * DAY then return "closes tomorrow" end
    return "closes " .. date("%a %H:%M", t)
end

local KIND_WORD = { yn = "Yes or no", one = "One answer", many = "Several answers", days = "Pick days" }

local function register()
    local N = ns.Notify
    local GOLDISH = { 0.88, 0.70, 0.35 }

    -- Polls (Core/Polls.lua; the page is UI/PollsTab.lua's Guild > Polls)
    N:RegisterKind("polls", {
        section = "Polls", page = "polls", icon = { 55, 25, 6 }, color = { 1, 0.82, 0 },
        label = "Polls waiting for you", desc = "A question from the officers or the council that asks you.",
        needsYou = true, popup = true, sound = true, home = true,
        open = function(it)
            if ns.PollsUI and ns.PollsUI.OpenPoll then ns.PollsUI:OpenPoll(it.key) else openTab("polls") end
        end,
        actions = function(it)
            local P = ns.Polls
            local p = P and P.GetPoll and P:GetPoll(it.key)
            if p and p.k == "yn" then
                return { { text = "Yes", primary = true, fn = function() P:Vote(it.key, { 1 }) end },
                         { text = "No", fn = function() P:Vote(it.key, { 2 }) end } }
            end
            return { { text = "Answer", primary = true, fn = function() N:Open(it.id) end } }
        end,
        chip = function(it)
            return { text = it.from and ("Poll from " .. Short(it.from)) or "Answer a poll", kind = "warn",
                     icon = { tex = UI().ICON_ATLAS, coords = UI():IconCoords(ns:HasAssets(6) and 55 or 25) } }
        end,
        -- several on Home: one chip ("3 polls from Victhar" when one person asks them all)
        chipGroup = function(items)
            local by = items[1].from
            for _, it in ipairs(items) do if it.from ~= by then by = nil break end end
            return { text = #items .. " polls " .. (by and ("from " .. Short(by)) or "waiting"),
                     title = #items .. " polls waiting for you" }
        end,
        openGroup = function() openTab("polls") end,
    })
    N:RegisterSource("polls", function()
        local P, out = ns.Polls, {}
        if not (P and P.GetWaiting) then return out end
        for _, p in ipairs(P:GetWaiting()) do
            local parts = { KIND_WORD[p.k] or "Poll" }
            local c = closesText(p.cl)
            if c then parts[#parts + 1] = c end
            out[#out + 1] = { key = p.id, title = p.q, text = table.concat(parts, " · "), from = p.by, time = p.at,
                              expires = p.cl }
        end
        return out
    end, { "POLLS_UPDATED", "POLL_ANSWERED", "POLL_ARRIVED" })
    ns:On("POLL_NUDGED", function(id)
        N:Refresh("polls")
        C_Timer.After(0.1, function() N:Renotify("polls", id) end)
    end)

    -- Raids I'm invited to and haven't answered (the next 7 days)
    N:RegisterKind("raidAnswer", {
        section = "Raids", page = "raids", icon = { 45, 26, 4 }, color = GOLDISH,
        label = "Raid answers", desc = "Raids you're invited to and haven't answered yet.",
        needsYou = true, popup = true, sound = true, home = true,
        kicker = function() return "Your answer" end,
        open = function(it) openRaid(it.key) end,
        actions = function(it)
            local function answer(st) return function()
                if ns.RaidPlanUI and ns.RaidPlanUI.Answer then ns.RaidPlanUI:Answer(st, it.key) end
            end end
            return { { text = "Accept", primary = true, fn = answer("A") }, { text = "Tentative", fn = answer("T") } }
        end,
        chip = function() return { kind = "warn", icon = { tex = "Interface\\RaidFrame\\ReadyCheck-Ready", desat = true } } end,
        chipGroup = function(items)
            return { text = "Sign up: " .. #items .. " raids", title = #items .. " raids you haven't answered" }
        end,
        openGroup = function() openRaid() end,
    })
    N:RegisterSource("raidAnswer", function()
        local rp, out = ns.RaidPlan, {}
        if not (rp and rp.GetUnanswered) then return out end
        for _, v in ipairs(rp:GetUnanswered(7)) do
            out[#out + 1] = { key = v.id, title = rp:GetRaidName(v),
                text = date("%a %d %b · %H:%M", v.t) .. " · you haven't answered",
                short = "Sign up: " .. date("%a", v.t) .. " " .. shortRaid(v), expires = v.t }
        end
        return out
    end, { "RAIDPLAN_CHANGED" })

    -- People asking to join raids I run (locked raids)
    N:RegisterKind("raidRequests", {
        section = "Raids", page = "raids", icon = { 46, 19, 4 }, color = GOLDISH,
        label = "Join requests", desc = "People asking to join a raid you run.",
        needsYou = true, popup = true, sound = true, home = true,
        kicker = function() return "Join requests" end,
        open = function(it) openRaid(it.key) end,
        actions = function(it)
            return { { text = "Review", primary = true, fn = function() N:Open(it.id) end } }
        end,
        chip = function() return { kind = "warn", icon = atlas(UI().ICON.team or 46) } end,
        chipGroup = function(items)
            local n = 0
            for _, it in ipairs(items) do n = n + (it.n or 1) end
            return { text = n .. " join requests", title = n .. " join requests for " .. #items .. " raids you run" }
        end,
        openGroup = function() openRaid() end,
    })
    N:RegisterSource("raidRequests", function()
        local rp, out = ns.RaidPlan, {}
        if not (rp and rp.GetPendingRequests) then return out end
        local _, per = rp:GetPendingRequests()
        for occId, n in pairs(per or {}) do
            local v = rp:GetRaid(occId)
            local reqs = rp:GetRequests(occId)
            local first = reqs[1]
            if v and first then
                local who = UI():ColoredName(first.key) or Short(first.key)
                out[#out + 1] = { key = occId, n = n,
                    title = n == 1 and (who .. " asks to join") or (who .. " and " .. (n - 1) .. " more ask to join"),
                    text = rp:GetRaidName(v) .. " · " .. date("%a %d %b %H:%M", v.t) .. " · you run this raid",
                    short = n == 1 and (Short(first.key) .. " asks to join") or (n .. " join requests"),
                    time = reqs[#reqs].at }
            end
        end
        return out
    end, { "RAIDPLAN_CHANGED" })

    -- Dungeon runs: someone wants to join mine (the Dungeons tab's own pop-up stays: no pop-up from here)
    N:RegisterKind("runRequests", {
        section = "Dungeons", page = "dungeons", icon = 36, color = { 0.47, 0.83, 0.54 },
        label = "Run requests", desc = "Someone wants to join your dungeon run.",
        needsYou = true, popup = false, sound = false, home = true,
        open = function(it) openRun(it.key) end,
        chip = function(it)
            return { kind = "plain", icon = it.data and it.data.r and roleIcon(it.data.r) or nil, tip = it.data and it.data.tip }
        end,
    })
    N:RegisterSource("runRequests", function()
        local R, out = ns.DungeonRuns, {}
        local mine = R and R.GetMine and R:GetMine()
        if not mine then return out end
        local asking = R:GetRequests(mine.id) or {}
        if #asking == 0 then return out end
        local d = R:GetDungeon(mine.d)
        local name = (d and d.name or tostring(mine.d)) .. (mine.h and " (Heroic)" or "")
        local first = asking[1]
        local tip = { "Your run: " .. name }
        for _, r in ipairs(asking) do tip[#tip + 1] = (UI():ColoredName(r.key) or Short(r.key)) .. "|cff9e9e9e wants to join|r" end
        tip[#tip + 1] = "|cff9e9e9eAccept or decline them on the Dungeons tab.|r"
        out[1] = { key = mine.id, n = #asking, data = { r = first.r, tip = tip },
            title = #asking == 1 and (Short(first.key) .. " wants to join your run") or (#asking .. " want to join your run"),
            text = name .. " · accept or decline them on the Dungeons tab" }
        return out
    end, { "DUNGEON_RUNS_UPDATED", "DUNGEON_RUN_REQUEST" })

    -- Dungeon runs: one that needs my role while I'm up for a run
    N:RegisterKind("runNeedsYou", {
        section = "Dungeons", page = "dungeons", icon = 36, color = { 0.47, 0.83, 0.54 },
        label = "Runs that need you", desc = "While you're up for a run: a run that needs your role.",
        needsYou = false, popup = false, sound = false, home = true,
        open = function(it) openRun(it.key) end,
        chip = function(it) return { kind = "info", icon = it.data and roleIcon(it.data.role) or nil } end,
    })
    N:RegisterSource("runNeedsYou", function()
        local R, out = ns.DungeonRuns, {}
        if not (R and R.IsUp and not R:GetMine() and R:IsUp()) then return out end
        for _, run in ipairs(R:GetRuns()) do
            local role = R:IsNow(run) and R:FitsMe(run)
            if role and not R:GetBlocker(run.d, run.h) and not R:GetAsked(run.id) then
                local d = R:GetDungeon(run.d)
                local name = (d and d.name or tostring(run.d)) .. (run.h and " (H)" or "")
                local roleText = role == "dps" and "DPS" or role
                out[1] = { key = run.id, from = run.o, data = { role = role },
                    title = Short(run.o) .. " needs a " .. roleText .. ": " .. name,
                    text = "You're up for a run and this one needs you.",
                    short = Short(run.o) .. " needs a " .. roleText .. ": " .. name }
                break
            end
        end
        return out
    end, { "DUNGEON_RUNS_UPDATED", "DUNGEON_RUN_PING" })

    -- Karazhan Chess: my move
    N:RegisterKind("chessTurn", {
        section = "Games", page = "games", icon = 51, color = { 1, 0.7, 0.28 },
        label = "Chess: your move", desc = "A guildmate moved in your Karazhan Chess game.",
        needsYou = true, popup = false, sound = false,
        open = function(it)
            openTab("games")
            if ns.GamesUI and ns.GamesUI.Select then ns.GamesUI:Select("chess") end
            local C = ns.Chess
            local g = C and C.Get and C:Get(it.key)
            if g and ns.ChessUI and ns.ChessUI.OpenGame then ns.ChessUI:OpenGame(g) end
        end,
    })
    N:RegisterSource("chessTurn", function()
        local C, out = ns.Chess, {}
        if not (C and C.List) then return out end
        for _, g in ipairs(C:List()) do
            if g.mode ~= "ai" and C:MyTurn(g) then
                out[#out + 1] = { key = g.id, from = g.opp, title = C:OpponentName(g) .. " moved: your turn",
                                  text = "Karazhan Chess", time = g.updated }
            end
        end
        return out
    end, { "CHESS_UPDATED" })

    -- Loot: an item awarded to me (a roll or the council)
    N:RegisterKind("lootWon", {
        section = "Loot", page = "mybis", icon = 22, color = { 0.64, 0.21, 0.93 },
        label = "Loot you won", desc = "An item awarded to you, by a roll or by the council.",
        needsYou = false, popup = false, sound = false,
        open = function() openTab("mybis") end,
    })
    ns:On("ROLL_UPDATED", function(id)
        local R = ns.Roll
        local s = R and R.Get and type(id) == "string" and R:Get(id)
        if type(s) ~= "table" or s.state ~= "awarded" or not (ns.Util.IsMe and ns.Util.IsMe(s.winner)) then return end
        local itemID = tonumber(s.i)
        local name = itemID and UI():ItemText(itemID) or "An item"
        N:Post("lootWon", { key = id, title = "You won " .. name, text = "Awarded by a roll",
                            data = { item = itemID } })
    end)

    -- What's new in the release I run (until its notes are read)
    N:RegisterKind("whatsNew", {
        section = "DisasterZone", icon = 25, color = { 0.81, 0.91, 1 },
        label = "What's new", desc = "The notes of a new DisasterZone release.",
        needsYou = false, popup = false, sound = false, home = true,
        open = function(it) if ns.ChangelogUI then ns.ChangelogUI:Open(it.key) end end,
        chip = function() return { kind = "info", icon = atlas(UI().ICON.notes) } end,
    })
    N:RegisterSource("whatsNew", function()
        local C = ns.ChangelogUI
        local e = C and C.GetUnread and C:GetUnread()
        if not e then return {} end
        return { { key = e.version, title = "What's new in " .. e.version, text = e.title,
                   short = "What's new in " .. e.version } }
    end, { "CHANGELOG_READ" })

    -- A guild member runs a newer DisasterZone
    N:RegisterKind("update", {
        section = "DisasterZone", icon = 33, color = { 1, 0.55, 0.45 },
        label = "Newer version", desc = "A guild member runs a newer DisasterZone than you.",
        needsYou = false, popup = false, sound = false, home = true,
        chip = function() return { kind = "bad", icon = { tex = UI().ICON_WARN } } end,
    })
    N:RegisterSource("update", function()
        local Sync, U = ns.Sync, ns.Util
        if not (Sync and Sync.GetVersions and U and U.CompareVersions) then return {} end
        local best, cutoff = nil, Now() - 14 * DAY
        for _, e in ipairs(Sync:GetVersions()) do
            if type(e.v) == "string" and (e.lastSeen or 0) >= cutoff and U.CompareVersions(e.v, ns.version) > 0
                and (not best or U.CompareVersions(e.v, best) > 0) then
                best = e.v
            end
        end
        if not best then return {} end
        return { { key = best, title = "DisasterZone " .. best .. " is out",
                   text = "A guild member runs it; you run " .. tostring(ns.version) .. ".",
                   short = "Update DisasterZone (" .. best .. ")" } }
    end, { "PEERS_UPDATED" })

    -- An in-game update is ready (its own Reload pop-up stays: no pop-up from here)
    N:RegisterKind("patchReady", {
        section = "DisasterZone", icon = 32, color = { 0.47, 0.83, 0.54 },
        label = "Update ready", desc = "An in-game update arrived; it applies when you reload.",
        needsYou = false, popup = false, sound = false,
        actions = function()
            return { { text = "Reload", primary = true, fn = function() if ReloadUI then ReloadUI() end end } }
        end,
    })
    N:RegisterSource("patchReady", function()
        local ready = ns.Patch and ns.Patch.ready
        if not ready then return {} end
        return { { key = tostring(ready.seq or ready.version), title = "DisasterZone " .. tostring(ready.version) .. " is ready",
                   text = "Reload the interface to use it." } }
    end, { "PATCH_UPDATED" })
end

function NotifySources:OnInit()
    if ns.Notify then register() end
end
