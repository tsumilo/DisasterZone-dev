if DisasterZoneBoot and DisasterZoneBoot.Run("Core/EventBlocks.lua", ...) then return end -- DisasterZone: the event builder's pieces.
-- The catalogue of pieces an event is built from (Scratch's shapes, WC3's words): the categories and their colours,
-- every piece's shape, words and blanks, what each "when" piece gives its script (winner, loser, ...), the smart blocks
-- (Sign-up, Bracket) with their settings, the starter event (Friday duel cup), the checks (a blank left empty, a stage
-- that is gone) and the plain words an event's page shows for each stage. Data and pure functions only:
-- Core/EventEngine.lua runs the pieces, UI/EventPieces.lua draws them, Core/Events.lua stores and syncs events.
--
-- An event (a "def"):
--   { id, rev, by, at, name, icon, art, stages = { { id, name, desc } ... }, scripts = { script ... },
--     blocks = { [bid] = { kind, stage, x, y, set = { ... }, inner = { script ... } | nil } },
--     vars = { { n = name, t = "player" | "num" | "text" } ... }, badges = { [badgeId] = { n, i, f, ti } },
--     notes = { { st, x, y, text } ... }, review = { rev, at, note } | nil }
-- A script: { id, st = stageId | "*" (Always), x, y, top = piece }.
-- A piece: { k = key, a = { arg ... }, n = next piece, c1 = first piece inside, c2 = first piece of "else" }.
-- An arg is nil (an empty blank), a number, a string (typed text or a dropdown's choice), a piece (a value dropped in)
-- or { j = { "text", piece, "text" ... } } (text with values in it).
local addonName, ns = ...

local B = ns:NewModule("EventBlocks")

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local tinsert, tremove, tconcat, tsort = table.insert, table.remove, table.concat, table.sort
local strformat, floor, max = string.format, math.floor, math.max

---------------------------------------------------------------------------
-- Categories (the palette's circles) and their colours: fill (bottom), fill (top), edge
---------------------------------------------------------------------------

local function rgb(hex) return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255 } end

B.CATS = {
    { key = "ev", label = "Events", f = rgb("6b4f0f"), f2 = rgb("8c6914"), e = rgb("f0be40") },
    { key = "sg", label = "Stages", f = rgb("6a1e22"), f2 = rgb("87282c"), e = rgb("f27468") },
    { key = "lo", label = "Logic", f = rgb("74390f"), f2 = rgb("924a16"), e = rgb("f08e48") },
    { key = "pl", label = "Players", f = rgb("183f6e"), f2 = rgb("22548f"), e = rgb("6cb6ff") },
    { key = "pt", label = "Points", f = rgb("62204a"), f2 = rgb("7d2c5f"), e = rgb("e67cba") },
    { key = "ch", label = "Chat", f = rgb("382f78"), f2 = rgb("463c94"), e = rgb("a094ff") },
    { key = "tm", label = "Timers", f = rgb("0d554b"), f2 = rgb("136d60"), e = rgb("50d6ba") },
    { key = "wo", label = "World", f = rgb("285317"), f2 = rgb("336a1e"), e = rgb("94d96b") },
    { key = "sm", label = "Smart", f = rgb("26262d"), f2 = rgb("32323a"), e = rgb("d6ae42") },
}
B.CAT = {}
for i, c in ipairs(B.CATS) do c.order = i; B.CAT[c.key] = c end

---------------------------------------------------------------------------
-- Value types and the dropdowns' choices
---------------------------------------------------------------------------

-- What a blank takes: player (a round player piece), players (a player or a list), num, text (anything, shown as
-- text), any, bool (a hexagon), and the dropdown kinds below (their choices are words, stored as the key).
B.CHANNELS = { { "GUILD", "Guild" }, { "RAID", "Raid" }, { "PARTY", "Party" }, { "SAY", "Say" } }
B.MARKERS = { { 1, "star" }, { 2, "circle" }, { 3, "diamond" }, { 4, "triangle" }, { 5, "moon" }, { 6, "square" },
    { 7, "cross" }, { 8, "skull" } }
B.DURATIONS = { 10, 30, 60, 120, 180, 300, 600, 900, 1800, 3600 }
B.STATS = { "Season points", "Wins", "Points", "Upsets", "Laps", "Fish caught", "Kills" }
B.SEASON = "Season points"   -- the one stat that counts for the season (ranked events only)

function B:DurationText(sec)
    sec = tonumber(sec) or 0
    if sec >= 3600 and sec % 3600 == 0 then return (sec / 3600) .. (sec == 3600 and " hour" or " hours") end
    if sec >= 60 and sec % 60 == 0 then return (sec / 60) .. " min" end
    if sec >= 60 then return strformat("%d:%02d", floor(sec / 60), sec % 60) end
    return sec .. " sec"
end

---------------------------------------------------------------------------
-- What "when" pieces give their script (values the picker offers there)
---------------------------------------------------------------------------

-- name -> { label, t = type }
B.CTX = {
    winner = { label = "winner", t = "player" },
    loser = { label = "loser", t = "player" },
    player1 = { label = "player 1", t = "player" },
    player2 = { label = "player 2", t = "player" },
    both = { label = "both players", t = "players" },
    opponent = { label = "opponent", t = "player" },
    score = { label = "score", t = "text" },
    game = { label = "game", t = "num" },
    match = { label = "match", t = "num" },
    round = { label = "round", t = "num" },
    finalist1 = { label = "finalist 1", t = "player" },
    finalist2 = { label = "finalist 2", t = "player" },
    champion = { label = "champion", t = "player" },
    runnerup = { label = "runner-up", t = "player" },
    third = { label = "third place", t = "player" },
    player = { label = "player", t = "player" },
    each = { label = "each player", t = "player" },
    answer = { label = "the answer", t = "player" },
}
B.CTX_ORDER = { "winner", "loser", "player1", "player2", "both", "opponent", "score", "game", "match", "round",
    "finalist1", "finalist2", "champion", "runnerup", "third", "player", "each", "answer" }

---------------------------------------------------------------------------
-- Smart blocks
---------------------------------------------------------------------------

-- settings: { key, label, kind = "num" | "choice" | "bool" | "dur" | "time", choices, d (default) }
B.SMART = {
    signup = {
        label = "Sign-up", icon = "Interface\\Icons\\INV_Misc_Note_01", order = 1,
        settings = {
            { key = "spots", label = "Spots", kind = "num", d = 16, min = 2, max = 40 },
            { key = "closes", label = "Closes", kind = "choice", d = "start",
              choices = { { "start", "When the event starts" }, { "early", "15 min before" }, { "host", "When the host closes it" } } },
            { key = "lvl70", label = "Level 70", kind = "bool", d = true },
        },
        gives = { "someone joins", "someone leaves", "sign-up closes" },
    },
    bracket = {
        label = "Bracket", icon = "Interface\\Icons\\INV_BannerPVP_01", order = 2,
        settings = {
            { key = "fmt", label = "Format", kind = "choice", d = "single",
              choices = { { "single", "Single elimination" }, { "robin", "Round robin" } } },
            { key = "bo", label = "Best of", kind = "choice", d = 3, choices = { { 1, "1" }, { 3, "3" }, { 5, "5" }, { 7, "7" } } },
            { key = "fbo", label = "Final", kind = "choice", d = 5, choices = { { 1, "1" }, { 3, "3" }, { 5, "5" }, { 7, "7" } } },
            { key = "seed", label = "Seeding", kind = "choice", d = "season",
              choices = { { "season", "Season rank" }, { "random", "Random" }, { "order", "Sign-up order" } } },
            { key = "noshow", label = "No-show", kind = "dur", d = 300, choices = { 120, 180, 300, 600, 900 } },
            { key = "atonce", label = "At once", kind = "choice", d = 2,
              choices = { { 1, "1 match" }, { 2, "2 matches" }, { 3, "3 matches" }, { 4, "4 matches" }, { 8, "8 matches" } } },
            { key = "bronze", label = "Bronze", kind = "bool", d = true },
        },
        gives = { "match starts", "game ends", "match ends", "final is set", "bracket done" },
    },
}
B.SMART_ORDER = { "signup", "bracket" }

function B:SmartDefaults(kind)
    local s = self.SMART[kind]
    local out = {}
    for _, o in ipairs(s and s.settings or {}) do out[o.key] = o.d end
    return out
end

function B:SmartSetting(block, key)
    local v = block and block.set and block.set[key]
    if v ~= nil then return v end
    local s = block and self.SMART[block.kind]
    for _, o in ipairs(s and s.settings or {}) do
        if o.key == key then return o.d end
    end
    return nil
end

---------------------------------------------------------------------------
-- The pieces
---------------------------------------------------------------------------

-- shape: hat (starts a script), stack, cap (ends one), c (holds pieces), c2 (if / else), bool (a hexagon), value
-- (round). text: the words, {n} = blank n. args[n]: { t = type, d = default, kind = smart block kind, o = choices }.
-- gives: values a hat gives its script. vt: what a value / bool piece gives. inner: shown only inside that smart
-- block (its own pieces). hide: never in the palette (internal).
local P = {}
B.PIECES = P

local function def(key, t)
    t.key = key
    P[key] = t
end

local BR = { t = "block", kind = "bracket" }
local SU = { t = "block", kind = "signup" }

-- Events
def("ev.start", { cat = "ev", shape = "hat", text = "when this stage starts", args = {}, gives = {} })
def("ev.duel", { cat = "ev", shape = "hat", text = "when a duel ends", args = {}, gives = { "winner", "loser" } })
def("ev.off", { cat = "ev", shape = "hat", text = "when an entrant goes offline", args = {}, gives = { "player" } })
def("ev.on", { cat = "ev", shape = "hat", text = "when an entrant comes back online", args = {}, gives = { "player" } })
def("ev.ready", { cat = "ev", shape = "hat", text = "when an entrant is ready", args = {}, gives = { "player" } })
def("ev.timer", { cat = "ev", shape = "hat", text = "when timer {1} runs out", args = { { t = "timer", d = "timer" } },
    gives = { "player" } })
def("ev.every", { cat = "ev", shape = "hat", text = "every {1}", args = { { t = "dur", d = 300 } }, gives = {} })
def("su.join", { cat = "ev", shape = "hat", text = "when someone joins {1}", args = { SU }, gives = { "player" } })
def("su.leave", { cat = "ev", shape = "hat", text = "when someone leaves {1}", args = { SU }, gives = { "player" } })
def("su.close", { cat = "ev", shape = "hat", text = "when {1} closes", args = { SU }, gives = {} })
def("bk.start", { cat = "ev", shape = "hat", text = "when {1} match starts", args = { BR },
    gives = { "player1", "player2", "both", "opponent", "match", "round" } })
def("bk.game", { cat = "ev", shape = "hat", text = "when {1} game ends", args = { BR },
    gives = { "winner", "loser", "score", "game", "match" } })
def("bk.end", { cat = "ev", shape = "hat", text = "when {1} match ends", args = { BR },
    gives = { "winner", "loser", "score", "match", "round" } })
def("bk.final", { cat = "ev", shape = "hat", text = "when {1} final is set", args = { BR }, gives = { "finalist1", "finalist2" } })
def("bk.done", { cat = "ev", shape = "hat", text = "when {1} is done", args = { BR }, gives = { "champion", "runnerup", "third" } })

-- Stages
def("sg.go", { cat = "sg", shape = "cap", text = "go to stage {1}", args = { { t = "stage" } } })
def("sg.next", { cat = "sg", shape = "cap", text = "go to the next stage", args = {} })
def("sg.end", { cat = "sg", shape = "cap", text = "end the event", args = {} })
def("sg.cancel", { cat = "sg", shape = "cap", text = "cancel the event: {1}", args = { { t = "text", d = "Not enough players" } } })

-- Logic
def("lo.if", { cat = "lo", shape = "c", text = "if {1} then", args = { { t = "bool" } } })
def("lo.ifelse", { cat = "lo", shape = "c2", text = "if {1} then", args = { { t = "bool" } } })
def("lo.rep", { cat = "lo", shape = "c", text = "repeat {1} times", args = { { t = "num", d = 3 } } })
def("lo.each", { cat = "lo", shape = "c", text = "for each player in {1}", args = { { t = "players" } }, gives = { "each" } })
def("lo.stop", { cat = "lo", shape = "cap", text = "stop this script", args = {} })
def("lo.and", { cat = "lo", shape = "bool", text = "{1} and {2}", args = { { t = "bool" }, { t = "bool" } } })
def("lo.or", { cat = "lo", shape = "bool", text = "{1} or {2}", args = { { t = "bool" }, { t = "bool" } } })
def("lo.not", { cat = "lo", shape = "bool", text = "not {1}", args = { { t = "bool" } } })
def("lo.gt", { cat = "lo", shape = "bool", text = "{1} > {2}", args = { { t = "num" }, { t = "num", d = 0 } } })
def("lo.lt", { cat = "lo", shape = "bool", text = "{1} < {2}", args = { { t = "num" }, { t = "num", d = 4 } } })
def("lo.eq", { cat = "lo", shape = "bool", text = "{1} = {2}", args = { { t = "any" }, { t = "any" } } })
def("lo.add", { cat = "lo", shape = "value", vt = "num", text = "{1} + {2}", args = { { t = "num", d = 1 }, { t = "num", d = 1 } } })
def("lo.sub", { cat = "lo", shape = "value", vt = "num", text = "{1} - {2}", args = { { t = "num", d = 1 }, { t = "num", d = 1 } } })
def("lo.rand", { cat = "lo", shape = "value", vt = "num", text = "pick random {1} to {2}",
    args = { { t = "num", d = 1 }, { t = "num", d = 10 } } })

-- Players
def("pl.host", { cat = "pl", shape = "value", vt = "player", text = "the host", args = {} })
def("pl.all", { cat = "pl", shape = "value", vt = "players", text = "every entrant", args = {} })
def("pl.rand", { cat = "pl", shape = "value", vt = "player", text = "a random entrant", args = {} })
def("pl.count", { cat = "pl", shape = "value", vt = "num", text = "number of entrants", args = {} })
def("pl.seed", { cat = "pl", shape = "value", vt = "player", text = "entrant #{1}", args = { { t = "num", d = 1 } } })
def("pl.online", { cat = "pl", shape = "bool", text = "{1} is online", args = { { t = "player" } } })
def("pl.ready", { cat = "pl", shape = "bool", text = "{1} is ready", args = { { t = "player" } } })
def("pl.notready", { cat = "pl", shape = "bool", text = "{1} isn't ready", args = { { t = "player" } } })
def("pl.is", { cat = "pl", shape = "bool", text = "{1} is {2}", args = { { t = "player" }, { t = "player" } } })
def("pl.in", { cat = "pl", shape = "bool", text = "{1} is one of {2}", args = { { t = "player" }, { t = "players" } } })
def("pl.below", { cat = "pt", shape = "bool", text = "{1} was seeded {2} or more below {3}",
    args = { { t = "player" }, { t = "num", d = 4 }, { t = "player" } } })
def("pl.top", { cat = "pl", shape = "value", vt = "players", text = "top {1} by {2}", args = { { t = "num", d = 3 }, { t = "stat", d = "Wins" } } })
def("ctx", { cat = "pl", shape = "value", text = "{1}", args = { { t = "ctxname" } }, hide = true })

-- Points
def("pt.add", { cat = "pt", shape = "stack", text = "add {1} {2} to {3}",
    args = { { t = "num", d = 1 }, { t = "stat", d = "Wins" }, { t = "player" } } })
def("pt.set", { cat = "pt", shape = "stack", text = "set {1} of {2} to {3}",
    args = { { t = "stat", d = "Points" }, { t = "player" }, { t = "num", d = 0 } } })
def("pt.get", { cat = "pt", shape = "value", vt = "num", text = "{1}'s {2}", args = { { t = "player" }, { t = "stat", d = "Wins" } } })
def("pt.vset", { cat = "pt", shape = "stack", text = "set {1} to {2}", args = { { t = "var" }, { t = "any" } } })
def("var", { cat = "pt", shape = "value", text = "{1}", args = { { t = "varname" } }, hide = true })
def("pt.badge", { cat = "pt", shape = "stack", text = "give badge {1} to {2}", args = { { t = "badge" }, { t = "player" } } })

-- Chat
def("ch.say", { cat = "ch", shape = "stack", text = "say {1} in {2}",
    args = { { t = "text", d = "" }, { t = "channel", d = "GUILD" } } })
def("ch.wh", { cat = "ch", shape = "stack", text = "whisper {1} {2}", args = { { t = "players" }, { t = "text", d = "" } } })
def("ch.rw", { cat = "ch", shape = "stack", text = "raid warning {1}", args = { { t = "text", d = "" } } })
def("ch.moment", { cat = "ch", shape = "stack", text = "add a moment: {1}", args = { { t = "text", d = "" } } })

-- Timers
def("tm.wait", { cat = "tm", shape = "stack", text = "wait {1}", args = { { t = "dur", d = 30 } } })
def("tm.start", { cat = "tm", shape = "stack", text = "start timer {1} named {2}",
    args = { { t = "dur", d = 300 }, { t = "timer", d = "timer" } } })
def("tm.startp", { cat = "tm", shape = "stack", text = "start timer {1} named {2} for {3}",
    args = { { t = "dur", d = 300 }, { t = "timer", d = "timer" }, { t = "player" } } })
def("tm.stop", { cat = "tm", shape = "stack", text = "stop timer {1}", args = { { t = "timer", d = "timer" } } })
def("tm.left", { cat = "tm", shape = "value", vt = "num", text = "seconds left on {1}", args = { { t = "timer", d = "timer" } } })
def("tm.count", { cat = "tm", shape = "stack", text = "count down {1} for {2}", args = { { t = "num", d = 10 }, { t = "players" } } })

-- World
def("wo.zone", { cat = "wo", shape = "bool", text = "{1} is in {2}", args = { { t = "player" }, { t = "text", d = "Nagrand" } } })
def("wo.inv", { cat = "wo", shape = "stack", text = "invite {1} to a group", args = { { t = "players" } } })
def("wo.mark", { cat = "wo", shape = "stack", text = "mark {1} with {2}", args = { { t = "player" }, { t = "marker", d = 8 } } })

-- Smart blocks: their values and actions
def("su.list", { cat = "sm", shape = "value", vt = "players", text = "{1} list", args = { SU } })
def("su.count", { cat = "sm", shape = "value", vt = "num", text = "number in {1}", args = { SU } })
def("su.closeit", { cat = "sm", shape = "stack", text = "close {1}", args = { SU } })
def("bk.award", { cat = "sm", shape = "stack", text = "award the match to {1}", args = { { t = "player" } } })
def("bk.out", { cat = "sm", shape = "stack", text = "take {1} out of the bracket", args = { { t = "player" } } })
def("bk.champ", { cat = "sm", shape = "value", vt = "player", text = "{1} champion", args = { BR } })
def("bk.second", { cat = "sm", shape = "value", vt = "player", text = "{1} runner-up", args = { BR } })
def("bk.third", { cat = "sm", shape = "value", vt = "player", text = "{1} third place", args = { BR } })
def("bk.fin1", { cat = "sm", shape = "value", vt = "player", text = "{1} finalist 1", args = { BR } })
def("bk.fin2", { cat = "sm", shape = "value", vt = "player", text = "{1} finalist 2", args = { BR } })
def("bk.left", { cat = "sm", shape = "value", vt = "players", text = "players still in {1}", args = { BR } })
def("bk.round", { cat = "sm", shape = "value", vt = "num", text = "{1} round", args = { BR } })
def("bk.still", { cat = "sm", shape = "bool", text = "{1} is still in {2}", args = { { t = "player" }, BR } })

-- The Bracket's own pieces (inside it): how a duel becomes a game win, a game win a match, a round the next one
def("bk.iduel", { cat = "ev", shape = "hat", text = "when a duel ends in a match", args = {}, inner = "bracket",
    gives = { "winner", "loser", "both", "match" } })
def("bk.iwin", { cat = "ev", shape = "hat", text = "when a player wins a game", args = {}, inner = "bracket",
    gives = { "player", "match" } })
def("bk.istart", { cat = "ev", shape = "hat", text = "when a match starts", args = {}, inner = "bracket",
    gives = { "player1", "player2", "both", "match" } })
def("bk.iround", { cat = "ev", shape = "hat", text = "when every match in the round is done", args = {}, inner = "bracket",
    gives = { "round" } })
def("bk.agree", { cat = "sm", shape = "bool", text = "both duelists' games agree on {1}", args = { { t = "player" } }, inner = "bracket" })
def("bk.gwin", { cat = "sm", shape = "stack", text = "add a game win to {1}", args = { { t = "player" } }, inner = "bracket" })
def("bk.ask", { cat = "sm", shape = "stack", text = "ask {1} who won", args = { { t = "players" } }, inner = "bracket",
    gives = { "answer" } })
def("bk.asked", { cat = "sm", shape = "bool", text = "the answers agree", args = {}, inner = "bracket" })
def("bk.wins", { cat = "sm", shape = "bool", text = "{1} has won {2} games", args = { { t = "player" }, { t = "num", d = 2 } },
    inner = "bracket" })
def("bk.need", { cat = "sm", shape = "value", vt = "num", text = "wins needed", args = {}, inner = "bracket" })
def("bk.noshow", { cat = "sm", shape = "value", vt = "num", text = "the no-show time", args = {}, inner = "bracket" })
def("bk.finish", { cat = "sm", shape = "stack", text = "finish the match: {1} moves on", args = { { t = "player" } }, inner = "bracket" })
def("bk.last", { cat = "sm", shape = "bool", text = "this was the last round", args = {}, inner = "bracket" })
def("bk.next", { cat = "sm", shape = "stack", text = "start the next round", args = {}, inner = "bracket" })
def("bk.close", { cat = "sm", shape = "cap", text = "finish the bracket", args = {}, inner = "bracket" })

-- The palette's order per category (pieces not listed here are not in the palette)
B.PALETTE = {
    ev = { "ev.start", "ev.duel", "ev.off", "ev.on", "ev.ready", "ev.timer", "ev.every" },
    sg = { "sg.go", "sg.next", "sg.end", "sg.cancel" },
    lo = { "lo.if", "lo.ifelse", "lo.rep", "lo.each", "lo.stop", "lo.and", "lo.or", "lo.not", "lo.gt", "lo.lt", "lo.eq",
           "lo.add", "lo.sub", "lo.rand" },
    pl = { "pl.host", "pl.all", "pl.rand", "pl.count", "pl.seed", "pl.online", "pl.ready", "pl.notready", "pl.is", "pl.in",
           "pl.top" },
    pt = { "pt.add", "pt.set", "pt.get", "pt.vset", "pt.badge", "pl.below" },
    ch = { "ch.say", "ch.wh", "ch.rw", "ch.moment" },
    tm = { "tm.wait", "tm.start", "tm.startp", "tm.stop", "tm.left", "tm.count" },
    wo = { "wo.zone", "wo.inv", "wo.mark" },
    sm = { "su.join", "su.leave", "su.close", "su.list", "su.count", "su.closeit", "bk.start", "bk.game", "bk.end",
           "bk.final", "bk.done", "bk.award", "bk.out", "bk.champ", "bk.second", "bk.third", "bk.fin1", "bk.fin2", "bk.left",
           "bk.round", "bk.still" },
}
-- Inside a smart block: its own pieces first
B.INNER_PALETTE = {
    bracket = { "bk.iduel", "bk.iwin", "bk.istart", "bk.iround", "bk.agree", "bk.gwin", "bk.ask", "bk.asked", "bk.wins",
                "bk.need", "bk.noshow", "bk.finish", "bk.last", "bk.next", "bk.close" },
}

function B:Piece(key) return P[key] end

-- The type a value / bool piece gives.
function B:ValueType(p)
    if type(p) ~= "table" then return nil end
    local d = P[p.k]
    if not d then return nil end
    if d.shape == "bool" then return "bool" end
    if p.k == "ctx" then
        local c = self.CTX[p.a and p.a[1]]
        return c and c.t or "any"
    end
    return d.vt or "any"
end

-- May a piece giving type `vt` go into a blank of type `t`?
function B:Fits(t, vt)
    if not vt then return false end
    if t == "any" or t == "text" then return vt ~= "bool" or t == "any" end
    if t == "players" then return vt == "player" or vt == "players" end
    if t == "num" then return vt == "num" end
    return t == vt
end

-- Blanks that take a dropped-in value (the rest are dropdowns / fields only).
local DROP_TYPES = { player = true, players = true, num = true, text = true, any = true, bool = true }
function B:TakesPieces(t) return DROP_TYPES[t] == true end

---------------------------------------------------------------------------
-- Piece trees
---------------------------------------------------------------------------

local function Copy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = Copy(x) end
    return o
end
B.Copy = Copy

-- A new piece with its blanks at their defaults.
function B:New(key)
    local d = P[key]
    if not d then return nil end
    local p = { k = key, a = {} }
    for i, a in ipairs(d.args or {}) do
        if a.d ~= nil then p.a[i] = a.d end
    end
    return p
end

-- Calls fn(piece, parent, slot) for every piece under p (its args, its insides, then what follows it).
function B:Walk(p, fn, parent, slot)
    if type(p) ~= "table" or not p.k then return end
    fn(p, parent, slot)
    for i, a in pairs(p.a or {}) do
        if type(a) == "table" then
            if a.k then
                self:Walk(a, fn, p, i)
            elseif type(a.j) == "table" then
                for _, x in ipairs(a.j) do
                    if type(x) == "table" and x.k then self:Walk(x, fn, p, i) end
                end
            end
        end
    end
    if p.c1 then self:Walk(p.c1, fn, p, "c1") end
    if p.c2 then self:Walk(p.c2, fn, p, "c2") end
    if p.n then self:Walk(p.n, fn, p, "n") end
end

-- Links pieces into one stack: Stack(a, b, c) -> a (a.n = b, b.n = c). nil entries are skipped.
function B:Stack(...)
    local first, last
    for i = 1, select("#", ...) do
        local p = select(i, ...)
        if p then
            if last then last.n = p else first = p end
            last = p
            while last.n do last = last.n end
        end
    end
    return first
end

-- Number of pieces in a tree (the size check).
function B:Count(p)
    local n = 0
    self:Walk(p, function() n = n + 1 end)
    return n
end

---------------------------------------------------------------------------
-- Building pieces in code (the starter event, the Bracket's own scripts, demo data)
---------------------------------------------------------------------------

local function N(key, ...)
    local p = B:New(key)
    local n = select("#", ...)
    for i = 1, n do
        local v = select(i, ...)
        if v ~= nil then p.a[i] = v end
    end
    return p
end
local function C(name) return { k = "ctx", a = { name } } end
local function V(name) return { k = "var", a = { name } } end
local function J(...) return { j = { ... } } end
local function If(cond, ...) local p = N("lo.if", cond); p.c1 = B:Stack(...); return p end
local function IfElse(cond, yes, no) local p = N("lo.ifelse", cond); p.c1 = yes; p.c2 = no; return p end
B.Build = { N = N, C = C, V = V, J = J, If = If, IfElse = IfElse }

-- The Bracket's own scripts: what "Open" shows, and what runs unless the event has its own copy.
function B:BracketInner()
    return {
        { id = "i1", st = "*", x = 20, y = 70, top = B:Stack(
            N("bk.iduel"),
            IfElse(N("bk.agree", C("winner")),
                N("bk.gwin", C("winner")),
                B:Stack(N("bk.ask", C("both")),
                    IfElse(N("bk.asked"),
                        N("bk.gwin", C("answer")),
                        B:Stack(N("bk.ask", N("pl.host")), N("bk.gwin", C("answer"))))))) },
        { id = "i2", st = "*", x = 420, y = 70, top = B:Stack(
            N("bk.iwin"),
            If(N("bk.wins", C("player"), N("bk.need")), N("bk.finish", C("player")))) },
        { id = "i3", st = "*", x = 420, y = 230, top = B:Stack(
            N("bk.istart"),
            N("tm.start", N("bk.noshow"), "no-show")) },
        { id = "i4", st = "*", x = 20, y = 380, top = B:Stack(
            N("ev.timer", "no-show"),
            If(N("lo.and", N("pl.ready", C("player1")), N("pl.notready", C("player2"))), N("bk.award", C("player1"))),
            If(N("lo.and", N("pl.ready", C("player2")), N("pl.notready", C("player1"))), N("bk.award", C("player2")))) },
        { id = "i5", st = "*", x = 420, y = 380, top = B:Stack(
            N("bk.iround"),
            IfElse(N("bk.last"), N("bk.close"), N("bk.next"))) },
    }
end

B.ART = {   -- the event's banner: a loading screen of the client
    { "nagrand", "Nagrand Arena", "Interface\\Glues\\LoadingScreens\\LoadScreenNagrandArenaBattlegrounds" },
    { "blades", "Blade's Edge Arena", "Interface\\Glues\\LoadingScreens\\LoadScreenBladesEdgeArena" },
    { "ruins", "Ruins of Lordaeron", "Interface\\Glues\\LoadingScreens\\LoadScreenRuinsofLordaeronBattlegrounds" },
    { "wsg", "Warsong Gulch", "Interface\\Glues\\LoadingScreens\\LoadScreenWarsongGulch" },
    { "ab", "Arathi Basin", "Interface\\Glues\\LoadingScreens\\LoadScreenArathiBasin" },
    { "eots", "Eye of the Storm", "Interface\\Glues\\LoadingScreens\\LoadScreenNetherBattlegrounds" },
    { "pvp", "Alterac Valley", "Interface\\Glues\\LoadingScreens\\LoadScreenPVPBattleground" },
    { "outland", "Outland", "Interface\\Glues\\LoadingScreens\\LoadScreenOutland" },
    { "kalimdor", "Kalimdor", "Interface\\Glues\\LoadingScreens\\LoadScreenKalimdor" },
    { "ek", "Eastern Kingdoms", "Interface\\Glues\\LoadingScreens\\LoadScreenEasternKingdom" },
}
B.ART_BY = {}
for _, a in ipairs(B.ART) do B.ART_BY[a[1]] = a end

function B:ArtPath(key)
    local a = self.ART_BY[key] or self.ART[1]
    return a[3]
end

B.FRAMES = { { "gold", "Gold" }, { "silver", "Silver" }, { "bronze", "Bronze" }, { "fel", "Fel" }, { "arcane", "Arcane" },
    { "blood", "Blood" } }
B.FRAME_COLOR = { gold = { 1, 0.84, 0.36 }, silver = { 0.86, 0.89, 0.95 }, bronze = { 0.86, 0.56, 0.32 },
    fel = { 0.55, 0.92, 0.32 }, arcane = { 0.72, 0.48, 1 }, blood = { 0.95, 0.34, 0.26 } }

-- The starter event: the Friday duel cup of the mockups (a 16-player single elimination bracket).
function B:Starter()
    local d = {
        name = "Friday duel cup", icon = "Interface\\Icons\\Ability_DualWield", art = "nagrand",
        stages = { { id = "s1", name = "Sign-up" }, { id = "s2", name = "Bracket" }, { id = "s3", name = "Finals" },
                   { id = "s4", name = "Prizes" } },
        vars = { { n = "Biggest upset", t = "player" } },
        badges = {
            champ = { n = "Duel champion", i = "Interface\\Icons\\Ability_Warrior_Challange", f = "gold", ti = "the Duelist" },
            second = { n = "Runner-up", i = "Interface\\Icons\\Ability_Parry", f = "silver" },
            third = { n = "Third place", i = "Interface\\Icons\\INV_Jewelry_Talisman_07", f = "bronze" },
            upset = { n = "Giant slayer", i = "Interface\\Icons\\INV_Misc_Head_Dragon_01", f = "blood" },
        },
        blocks = {
            b1 = { kind = "signup", stage = "s1", x = 20, y = 20, set = { spots = 16, closes = "start", lvl70 = true } },
            b2 = { kind = "bracket", stage = "s2", x = 362, y = 22, set = { fmt = "single", bo = 3, fbo = 5, seed = "season",
                   noshow = 300, atonce = 2, bronze = true } },
        },
        notes = {},
    }
    local BRK = "b2"
    d.scripts = {
        { id = "c1", st = "s1", x = 362, y = 20, top = B:Stack(
            N("su.join", "b1"),
            N("ch.wh", C("player"), J("You're in the Friday duel cup. Seeds are set when sign-up closes."))) },
        { id = "c2", st = "s1", x = 362, y = 140, top = B:Stack(
            N("su.close", "b1"),
            IfElse(N("lo.lt", N("su.count", "b1"), 4),
                N("sg.cancel", "Not enough duelists"),
                N("sg.go", "s2"))) },
        { id = "c3", st = "*", x = 20, y = 22, top = B:Stack(
            N("bk.start", BRK),
            N("ch.wh", C("both"), J("You're up vs ", C("opponent"), ". Duel at the Ring of Trials."))) },
        { id = "c4", st = "*", x = 20, y = 150, top = B:Stack(
            N("bk.end", BRK),
            N("pt.add", 5, B.SEASON, C("winner")),
            N("ch.say", J(C("winner"), " beats ", C("loser"), " ", C("score")), "GUILD"),
            If(N("pl.below", C("winner"), 4, C("loser")),
                N("ch.rw", J("Upset! ", C("winner"), " knocks out ", C("loser"))),
                N("ch.moment", J("Upset: ", C("winner"), " knocked out ", C("loser"))),
                N("pt.vset", "Biggest upset", C("winner")))) },
        { id = "c5", st = "s2", x = 362, y = 300, top = B:Stack(
            N("bk.final", BRK),
            N("sg.go", "s3")) },
        { id = "c6", st = "s3", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("ch.rw", J("Final: ", N("bk.fin1", BRK), " vs ", N("bk.fin2", BRK))),
            N("tm.count", 10, N("pl.all"))) },
        { id = "c7", st = "*", x = 362, y = 22, top = B:Stack(
            N("bk.done", BRK),
            N("sg.go", "s4")) },
        { id = "c8", st = "s4", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("pt.badge", "champ", N("bk.champ", BRK)),
            N("pt.add", 50, B.SEASON, N("bk.champ", BRK)),
            N("pt.badge", "second", N("bk.second", BRK)),
            N("pt.add", 30, B.SEASON, N("bk.second", BRK)),
            N("pt.badge", "third", N("bk.third", BRK)),
            N("pt.add", 20, B.SEASON, N("bk.third", BRK)),
            -- the Giant slayer: only when there was an upset
            If(N("lo.not", N("lo.eq", V("Biggest upset"), "")),
                N("pt.badge", "upset", V("Biggest upset")),
                N("pt.add", 10, B.SEASON, V("Biggest upset"))),
            N("ch.say", J("GG! ", N("bk.champ", BRK), " wins the Friday duel cup"), "GUILD"),
            N("sg.end")) },
        { id = "c9", st = "s1", x = 20, y = 300, top = B:Stack(
            N("ev.start"),
            N("ch.say", J("Sign-up for the Friday duel cup is open: 16 spots"), "GUILD")) },
    }
    -- everyone who plays gets 5 when the bracket starts
    local each = N("lo.each", N("pl.all"))
    each.c1 = N("pt.add", 5, B.SEASON, C("each"))
    tinsert(d.scripts, { id = "c10", st = "s2", x = 362, y = 140, top = B:Stack(N("ev.start"), each) })
    return d
end

-- An empty event: the four default stages and nothing in them.
function B:Blank(name)
    return {
        name = name or "New event", icon = "Interface\\Icons\\INV_Misc_QuestionMark", art = "nagrand",
        stages = { { id = "s1", name = "Sign-up" }, { id = "s2", name = "Main" } },
        scripts = {}, blocks = {}, vars = {}, badges = {}, notes = {},
    }
end

---------------------------------------------------------------------------
-- Lookups on a def
---------------------------------------------------------------------------

function B:Stage(d, id)
    for i, s in ipairs(d and d.stages or {}) do
        if s.id == id then return s, i end
    end
    return nil
end

function B:StageName(d, id)
    if id == "*" then return "Always" end
    local s = self:Stage(d, id)
    return s and s.name or "?"
end

function B:BlocksOf(d, kind)
    local out = {}
    for id, b in pairs(d and d.blocks or {}) do
        if not kind or b.kind == kind then out[#out + 1] = id end
    end
    tsort(out)
    return out
end

function B:BlockLabel(d, id)
    local b = d and d.blocks and d.blocks[id]
    if not b then return "?" end
    local s = self.SMART[b.kind]
    local label = s and s.label or b.kind
    -- two of a kind: number them
    local same = self:BlocksOf(d, b.kind)
    if #same > 1 then
        for i, x in ipairs(same) do
            if x == id then return label .. " " .. i end
        end
    end
    return label
end

function B:Var(d, name)
    for _, v in ipairs(d and d.vars or {}) do
        if v.n == name then return v end
    end
    return nil
end

-- Timer names used anywhere in the event (the timer dropdown's choices).
function B:Timers(d)
    local seen, out = {}, {}
    local function add(n)
        if type(n) == "string" and n ~= "" and not seen[n] then seen[n] = true; out[#out + 1] = n end
    end
    for _, s in ipairs(d and d.scripts or {}) do
        self:Walk(s.top, function(p)
            local pd = P[p.k]
            for i, a in ipairs(pd and pd.args or {}) do
                if a.t == "timer" then add(p.a[i]) end
            end
        end)
    end
    add("no-show")
    tsort(out)
    return out
end

---------------------------------------------------------------------------
-- Checks
---------------------------------------------------------------------------

-- The values a script's hat gives (and loops / asks inside it add). scope[name] = true.
function B:Scope(top)
    local scope = {}
    local d = top and P[top.k]
    if d and d.shape == "hat" then
        for _, g in ipairs(d.gives or {}) do scope[g] = true end
    end
    return scope
end

local NEED = { player = true, players = true, bool = true, stage = true, var = true, badge = true, block = true,
    num = true, timer = true }

-- Every problem in the event: { script = scriptId | nil, piece = piece, slot = n, text } (in script order). A problem
-- stops hosting: the piece would not know what to do. (Pieces with nothing on top never run; not a problem.)
function B:Problems(d, opts)
    local out = {}
    if type(d) ~= "table" then return out end
    local function add(sid, p, slot, text) out[#out + 1] = { script = sid, piece = p, slot = slot, text = text } end
    local stagesById = {}
    for _, s in ipairs(d.stages or {}) do stagesById[s.id] = true end
    local function check(sid, top, inner)
        local scope = self:Scope(top)
        self:Walk(top, function(p)
            local pd = P[p.k]
            if not pd then add(sid, p, nil, "This piece is from a newer version of DisasterZone."); return end
            if pd.gives and pd.shape ~= "hat" then for _, g in ipairs(pd.gives) do scope[g] = true end end
            if pd.inner and pd.inner ~= inner then add(sid, p, nil, "This piece only works inside its smart block.") end
            for i, a in ipairs(pd.args or {}) do
                local v = p.a and p.a[i]
                local empty = v == nil or v == "" and a.t ~= "text"
                if empty and NEED[a.t] then
                    local what = (a.t == "player" and "a player") or (a.t == "players" and "players")
                        or (a.t == "bool" and "a yes / no piece") or (a.t == "stage" and "a stage")
                        or (a.t == "block" and "a smart block") or (a.t == "badge" and "a badge")
                        or (a.t == "var" and "a variable") or (a.t == "num" and "a number") or "a value"
                    add(sid, p, i, "Needs " .. what .. " here.")
                elseif a.t == "stage" and v and not stagesById[v] then
                    add(sid, p, i, "That stage is gone.")
                elseif a.t == "block" and v and not (d.blocks and d.blocks[v] and d.blocks[v].kind == a.kind) then
                    add(sid, p, i, "That smart block is gone.")
                elseif a.t == "badge" and v and not (d.badges and d.badges[v]) then
                    add(sid, p, i, "That badge is gone.")
                elseif a.t == "var" and v and not self:Var(d, v) then
                    add(sid, p, i, "That variable is gone.")
                end
            end
            if p.k == "ctx" then
                local name = p.a and p.a[1]
                if not scope[name] then
                    local c = self.CTX[name]
                    add(sid, p, nil, "\"" .. (c and c.label or tostring(name)) .. "\" isn't known in this script.")
                end
            elseif p.k == "var" and not self:Var(d, p.a and p.a[1]) then
                add(sid, p, nil, "That variable is gone.")
            end
        end)
    end
    for _, s in ipairs(d.scripts or {}) do
        local hd = s.top and P[s.top.k]
        if hd and hd.shape == "hat" then check(s.id, s.top, nil) end
        if s.st ~= "*" and not stagesById[s.st] then add(s.id, s.top, nil, "This script's stage is gone.") end
    end
    for bid, b in pairs(d.blocks or {}) do
        for _, s in ipairs(b.inner or {}) do
            local hd = s.top and P[s.top.k]
            if hd and hd.shape == "hat" then check(bid .. "/" .. s.id, s.top, b.kind) end
        end
        if not stagesById[b.stage] then add(nil, nil, nil, (self:BlockLabel(d, bid)) .. "'s stage is gone.") end
    end
    if not d.stages or #d.stages == 0 then add(nil, nil, nil, "An event needs a stage.") end
    return out
end

-- Problems keyed by piece (for the warning badges): [piece] = text of its first problem.
function B:ProblemsByPiece(d)
    local by = {}
    for _, pr in ipairs(self:Problems(d)) do
        if pr.piece and not by[pr.piece] then by[pr.piece] = pr.text end
    end
    return by
end

---------------------------------------------------------------------------
-- Plain words (the event's page)
---------------------------------------------------------------------------

local function choiceLabel(list, v)
    for _, c in ipairs(list or {}) do
        if c[1] == v then return c[2] end
    end
    return tostring(v)
end

local function settingLabel(kind, key, v)
    local s = B.SMART[kind]
    for _, o in ipairs(s and s.settings or {}) do
        if o.key == key then
            if o.kind == "choice" then return choiceLabel(o.choices, v) end
            if o.kind == "dur" then return B:DurationText(v) end
            return tostring(v)
        end
    end
    return tostring(v)
end

-- What the pieces of a stage do, as rules: { { g = glyph key, t = text } ... }, and a sentence when the stage has no
-- description of its own. opts.closesAt: the sign-up's closing time (a run's), for its rule.
function B:DescribeStage(d, stage, opts)
    local rules, words = {}, {}
    local seen = {}
    local function rule(g, t) if not seen[t] then seen[t] = true; rules[#rules + 1] = { g = g, t = t } end end
    for _, bid in ipairs(self:BlocksOf(d)) do
        local b = d.blocks[bid]
        if b.stage == stage.id then
            if b.kind == "signup" then
                local spots = self:SmartSetting(b, "spots")
                rule("group", spots .. " spots")
                local closes = self:SmartSetting(b, "closes")
                if opts and opts.closesAt then
                    rule("clock", "closes " .. date("%H:%M", opts.closesAt))
                elseif closes == "host" then
                    rule("clock", "the host closes it")
                end
                words[#words + 1] = spots .. " spots" .. (self:SmartSetting(b, "lvl70") and ". Level 70 characters of the guild." or ".")
            elseif b.kind == "bracket" then
                local fmt = settingLabel("bracket", "fmt", self:SmartSetting(b, "fmt"))
                local bo, fbo = self:SmartSetting(b, "bo"), self:SmartSetting(b, "fbo")
                local seed = self:SmartSetting(b, "seed")
                rule("swords", "best of " .. bo)
                rule("clock", self:DurationText(self:SmartSetting(b, "noshow")) .. " no-show")
                rule("rank", "seeded by " .. string.lower(settingLabel("bracket", "seed", seed)))
                words[#words + 1] = fmt .. ", best of " .. bo .. (fbo ~= bo and (", the final best of " .. fbo) or "")
                    .. ", seeded by " .. string.lower(settingLabel("bracket", "seed", seed)) .. "."
            end
        end
    end
    local badges, season, rw, say, count = 0, false, false, false, false
    for _, s in ipairs(d.scripts or {}) do
        if s.st == stage.id then
            self:Walk(s.top, function(p)
                if p.k == "pt.badge" then badges = badges + 1
                elseif p.k == "pt.add" and p.a[2] == self.SEASON then season = true
                elseif p.k == "ch.rw" then rw = true
                elseif p.k == "ch.say" then say = true
                elseif p.k == "tm.count" then count = true
                end
            end)
        end
    end
    if badges > 0 then rule("trophy", badges == 1 and "a badge" or (badges .. " badges")) end
    if season then rule("rank", "season points") end
    if rw then rule("eyeo", "raid warning") end
    if count then rule("clock", "countdown") end
    if badges > 0 then words[#words + 1] = "Badges" .. (season and " and season points" or "") .. " are given out." end
    if say then words[#words + 1] = "Results post to guild chat." end
    local text = stage.desc
    if not text or text == "" then text = tconcat(words, " ") end
    return { id = stage.id, name = stage.name, text = text, rules = rules }
end

function B:Describe(d, opts)
    local out = {}
    for _, s in ipairs(d and d.stages or {}) do out[#out + 1] = self:DescribeStage(d, s, opts) end
    return out
end

-- The kind of event, from its smart blocks ("Bracket", "Sign-up"...): the library card's chips.
function B:Kinds(d)
    local kinds = {}
    for _, k in ipairs(self.SMART_ORDER) do
        if #self:BlocksOf(d, k) > 0 then kinds[#kinds + 1] = k end
    end
    return kinds
end

-- The badges an event can give, in their def order (sorted by name).
function B:BadgeList(d)
    local out = {}
    for id, bd in pairs(d and d.badges or {}) do out[#out + 1] = { id = id, b = bd } end
    tsort(out, function(x, y) return (x.b.n or "") < (y.b.n or "") end)
    return out
end

-- Season points an event can hand one player at most (the review's check): the biggest "add n Season points" sum on
-- any one path is hard to know, so this adds every season grant of the event's ends (Prizes-like stages) and the
-- largest per-match grant. Good enough to spot a typo of 5000.
function B:MaxSeasonGrant(d)
    local top = 0
    for _, s in ipairs(d and d.scripts or {}) do
        self:Walk(s.top, function(p)
            if p.k == "pt.add" and p.a[2] == self.SEASON and type(p.a[1]) == "number" and p.a[1] > top then top = p.a[1] end
        end)
    end
    return top
end

B.SEASON_CAP = 100   -- one grant of more than this is refused by the review check

---------------------------------------------------------------------------
-- What changed between two revisions (the review)
---------------------------------------------------------------------------

-- A piece's own words and blanks (not what follows it or sits inside it): its signature for the diff.
local function Sig(p)
    local parts = { p.k }
    for i = 1, 8 do
        local a = p.a and p.a[i]
        if type(a) == "table" then
            if a.k then parts[#parts + 1] = "(" .. Sig(a) .. ")"
            elseif a.j then
                local j = {}
                for _, x in ipairs(a.j) do j[#j + 1] = type(x) == "table" and ("(" .. Sig(x) .. ")") or tostring(x) end
                parts[#parts + 1] = "[" .. tconcat(j) .. "]"
            end
        elseif a ~= nil then
            parts[#parts + 1] = tostring(a)
        else
            parts[#parts + 1] = "_"
        end
    end
    return tconcat(parts, "|")
end

-- The stack pieces of a script in order (a C piece's insides after it).
local function Flatten(p, out)
    out = out or {}
    while p do
        out[#out + 1] = p
        if p.c1 then Flatten(p.c1, out) end
        if p.c2 then Flatten(p.c2, out) end
        p = p.n
    end
    return out
end

-- The changes from `old` to `new`: { { kind = "add" | "del" | "chg", stage = name, piece = piece | nil, text } ... }
-- and how many pieces are the same.
function B:Diff(old, new)
    local out, same = {}, 0
    if not (old and new) then return out, 0 end
    local function stageOf(d, sid) return self:StageName(d, sid) end
    local byId = {}
    for _, s in ipairs(old.scripts or {}) do byId[s.id] = s end
    local seen = {}
    for _, s in ipairs(new.scripts or {}) do
        local o = byId[s.id]
        seen[s.id] = true
        local a, b = o and Flatten(o.top) or {}, Flatten(s.top)
        -- longest common subsequence of the two scripts' piece signatures
        local n, m = #a, #b
        local L = {}
        for i = 0, n do L[i] = {}; for j = 0, m do L[i][j] = 0 end end
        for i = n - 1, 0, -1 do
            for j = m - 1, 0, -1 do
                if Sig(a[i + 1]) == Sig(b[j + 1]) then L[i][j] = L[i + 1][j + 1] + 1
                else L[i][j] = max(L[i + 1][j], L[i][j + 1]) end
            end
        end
        local i, j = 0, 0
        local pendDel = {}
        while i < n or j < m do
            if i < n and j < m and Sig(a[i + 1]) == Sig(b[j + 1]) then
                same = same + 1
                i, j = i + 1, j + 1
            elseif j < m and (i >= n or L[i][j + 1] >= L[i + 1][j]) then
                -- an added piece right where one was dropped is a change of that piece
                local d = tremove(pendDel, 1)
                out[#out + 1] = { kind = d and (d.k == b[j + 1].k and "chg" or "add") or "add", stage = stageOf(new, s.st),
                    piece = b[j + 1], old = d }
                if d and d.k ~= b[j + 1].k then
                    out[#out + 1] = { kind = "del", stage = stageOf(old, o.st), piece = d }
                end
                j = j + 1
            else
                pendDel[#pendDel + 1] = a[i + 1]
                i = i + 1
            end
        end
        for _, d in ipairs(pendDel) do out[#out + 1] = { kind = "del", stage = stageOf(old, o and o.st or s.st), piece = d } end
    end
    for _, s in ipairs(old.scripts or {}) do
        if not seen[s.id] then
            for _, p in ipairs(Flatten(s.top)) do out[#out + 1] = { kind = "del", stage = stageOf(old, s.st), piece = p } end
        end
    end
    -- smart blocks' settings, badges
    for bid, b in pairs(new.blocks or {}) do
        local o = old.blocks and old.blocks[bid]
        local sm = self.SMART[b.kind]
        if not o then
            out[#out + 1] = { kind = "add", stage = stageOf(new, b.stage), text = "New smart block: " .. (sm and sm.label or b.kind) }
        else
            for _, opt in ipairs(sm and sm.settings or {}) do
                local x, y = self:SmartSetting(o, opt.key), self:SmartSetting(b, opt.key)
                if x ~= y then
                    out[#out + 1] = { kind = "chg", stage = stageOf(new, b.stage), text = (sm.label .. ": " .. string.lower(opt.label)
                        .. " " .. settingLabel(b.kind, opt.key, x) .. " → " .. settingLabel(b.kind, opt.key, y)) }
                end
            end
        end
    end
    for bid, b in pairs(old.blocks or {}) do
        if not (new.blocks and new.blocks[bid]) then
            local sm = self.SMART[b.kind]
            out[#out + 1] = { kind = "del", stage = stageOf(old, b.stage), text = "Smart block: " .. (sm and sm.label or b.kind) }
        end
    end
    for id, bd in pairs(new.badges or {}) do
        local o = old.badges and old.badges[id]
        if not o then
            out[#out + 1] = { kind = "add", text = "New badge: " .. (bd.n or "?"), badge = bd }
        elseif o.n ~= bd.n or o.i ~= bd.i or o.f ~= bd.f or o.ti ~= bd.ti then
            out[#out + 1] = { kind = "chg", text = "Badge: " .. (bd.n or "?"), badge = bd }
        end
    end
    return out, same
end

function B:OnInit() end
