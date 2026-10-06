if DisasterZoneBoot and DisasterZoneBoot.Run("Core/EventBlocks.lua", ...) then return end -- DisasterZone: the event builder's pieces.
-- The catalogue of pieces an event is built from (Scratch's shapes, WC3's words): the categories and their colours,
-- every piece's shape, words and blanks, what each "when" piece gives its script (winner, loser, ...), the smart blocks
-- (Sign-up, Matches) with their settings, the definitions an event names once (tags, scores, places, lists, asks),
-- the eight examples ("Start from"), the checks (a blank left empty, a stage or a definition that is gone), the plain
-- words an event's page shows for each stage, and Migrate (part 1's pieces turned into these). Data and pure functions
-- only: Core/EventEngine.lua runs the pieces, UI/EventPieces.lua draws them, Core/Events.lua stores and syncs events.
--
-- An event (a "def"):
--   { id, rev, by, at, name, icon, art, stages = { { id, name, desc } ... }, scripts = { script ... },
--     blocks = { [bid] = { kind, stage, x, y, set = { ... }, inner = { script ... } | nil } },
--     vars = { { n = name, t = "player" | "num" | "text" } ... }, badges = { [badgeId] = { n, i, f, ti } },
--     tags = { [tid] = { n, c, shown } }, scores = { [sid] = { n, high, fmt, board, cap } },
--     places = { [pid] = { n, map, x, y, r, z, sz } }, lists = { [lid] = { n, kind, items } },
--     asks = { [aid] = { n, q, kind, choices, from, votes, self, time, secret } },
--     notes = { { st, x, y, text } ... }, review = { rev, at, note } | nil }
-- A script: { id, st = stageId | "*" (Always), x, y, top = piece }.
-- A piece: { k = key, a = { arg ... }, n = next piece, c1 = first piece inside, c2 = first piece of "else" }.
-- An arg is nil (an empty blank), a number, a string (typed text or a dropdown's choice), a piece (a value dropped in)
-- or { j = { "text", piece, "text" ... } } (text with values in it).
local addonName, ns = ...

local B = ns:NewModule("EventBlocks")

local type, pairs, ipairs, tostring, tonumber, next, select = type, pairs, ipairs, tostring, tonumber, next, select
local tinsert, tremove, tconcat, tsort = table.insert, table.remove, table.concat, table.sort
local strformat, strlower, strupper, floor, max, min = string.format, string.lower, string.upper, math.floor, math.max, math.min

---------------------------------------------------------------------------
-- Categories (the palette's circles) and their colours: fill (bottom), fill (top), edge
---------------------------------------------------------------------------

local function rgb(hex) return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255 } end

-- (the keys "pt" and "ch" are part 1's Points and Chat: their pieces are Scores and Messages now)
B.CATS = {
    { key = "ev", label = "Events", f = rgb("6b4f0f"), f2 = rgb("8c6914"), e = rgb("f0be40") },
    { key = "sg", label = "Stages", f = rgb("6a1e22"), f2 = rgb("87282c"), e = rgb("f27468") },
    { key = "lo", label = "Logic", f = rgb("74390f"), f2 = rgb("924a16"), e = rgb("f08e48") },
    { key = "pl", label = "Players", f = rgb("183f6e"), f2 = rgb("22548f"), e = rgb("6cb6ff") },
    { key = "pt", label = "Scores", f = rgb("62204a"), f2 = rgb("7d2c5f"), e = rgb("e67cba") },
    { key = "pc", label = "Places", f = rgb("09535d"), f2 = rgb("0c6b78"), e = rgb("56d6f0") },
    { key = "as", label = "Ask", f = rgb("843853"), f2 = rgb("a8486a"), e = rgb("f592b6") },
    { key = "ch", label = "Messages", f = rgb("382f78"), f2 = rgb("463c94"), e = rgb("a094ff") },
    { key = "tm", label = "Timers", f = rgb("0d554b"), f2 = rgb("136d60"), e = rgb("50d6ba") },
    { key = "wo", label = "World", f = rgb("285317"), f2 = rgb("336a1e"), e = rgb("94d96b") },
    { key = "sm", label = "Smart", f = rgb("26262d"), f2 = rgb("32323a"), e = rgb("d6ae42") },
}
B.CAT = {}
for i, c in ipairs(B.CATS) do c.order = i; B.CAT[c.key] = c end

---------------------------------------------------------------------------
-- Value types and the dropdowns' choices
---------------------------------------------------------------------------

-- What a blank takes (args[i].t):
--   player (a round player piece), players (a player or a list), num, text (anything, shown as text), any, bool (a
--   hexagon); place (one of the event's places, or a place value: a list item, "place" of a hat), where (a place or a
--   player: "yards from ... to ..."); the definitions tag, score, list, ask (dropdowns of the event's own plus "+ New");
--   label (a button's label, typed), what (the "happen" choice), how (the touch choice), sound, state (World's "is ...")
--   since (this stage / a timer), item (an item id or name, typed), creature (a name, typed), emote (an emote token),
--   filter (the second blank of a choice: its type is the choice's `filter`, see B:ArgType; not shown without one);
--   part 1's stage, var, varname, ctxname, badge, block, channel, marker, dur, timer.
-- args[i].opt: may stay empty (it then means "any").
B.CHANNELS = { { "GUILD", "Guild" }, { "RAID", "Raid" }, { "PARTY", "Party" }, { "SAY", "Say" } }
B.MARKERS = { { 1, "star" }, { 2, "circle" }, { 3, "diamond" }, { 4, "triangle" }, { 5, "moon" }, { 6, "square" },
    { 7, "cross" }, { 8, "skull" } }
B.DURATIONS = { 10, 30, 60, 120, 180, 300, 600, 900, 1200, 1800, 3600 }
B.STATS = { "Season points", "Wins", "Points", "Upsets", "Laps", "Fish caught", "Kills" }   -- (part 1's stat names)
B.SEASON = "Season points"   -- the built-in score that counts for the season (ranked events only)
B.ENTRANTS = "entrants"      -- the built-in tag: everyone in the event

-- "when an entrant {what}": key, the dropdown's words, what it gives, the type of its second blank (empty = any) and
-- the words around that blank ("kills" {Hogger} / "kills a creature" when empty).
B.HAPPEN = {
    { key = "duel", label = "wins a duel", gives = { "player", "other" } },
    { key = "lose", label = "loses a duel", gives = { "player", "other" } },
    { key = "kill", label = "kills a creature", gives = { "player", "creature" }, filter = "creature", verb = "kills",
      any = "a creature" },
    { key = "loot", label = "loots an item", gives = { "player", "item", "count" }, filter = "item", verb = "loots",
      any = "an item" },
    { key = "fish", label = "catches a fish", gives = { "player", "item", "count" }, filter = "item", verb = "catches",
      any = "a fish" },
    { key = "die", label = "dies", gives = { "player" } },
    { key = "mount", label = "mounts", gives = { "player" } },
    { key = "dismount", label = "dismounts", gives = { "player" } },
    { key = "move", label = "starts moving", gives = { "player" } },
    { key = "stop", label = "stops moving", gives = { "player" } },
    { key = "off", label = "goes offline", gives = { "player" } },
    { key = "on", label = "comes back", gives = { "player" } },
    { key = "ready", label = "is ready", gives = { "player" } },
    { key = "emote", label = "does an emote", gives = { "player", "emote", "other" }, filter = "emote", verb = "does",
      any = "an emote" },
}
B.HAPPEN_BY = {}
for i, h in ipairs(B.HAPPEN) do h.order = i; B.HAPPEN_BY[h.key] = h end

-- "touches ... by {how}"
B.TOUCH = {
    { key = "click", label = "a click" },
    { key = "point", label = "/point" },
    { key = "emote", label = "an emote", filter = "emote" },
}
B.TOUCH_BY = {}
for _, t in ipairs(B.TOUCH) do B.TOUCH_BY[t.key] = t end

-- Emotes a blank offers (the token CHAT_MSG_TEXT_EMOTE's sender's /emote has; any token may be typed).
B.EMOTES = { { "WAVE", "wave" }, { "POINT", "point" }, { "HUG", "hug" }, { "BOW", "bow" }, { "CHEER", "cheer" },
    { "DANCE", "dance" }, { "SALUTE", "salute" }, { "ROAR", "roar" }, { "CHICKEN", "chicken" }, { "KISS", "kiss" },
    { "LAUGH", "laugh" }, { "APPLAUD", "applaud" } }

-- "play {sound} for ...": key, words, the client's SOUNDKIT name and its id when the table lacks it (unverified ids).
B.SOUNDS = {
    { "warning", "Raid warning", "RAID_WARNING", 8959 },
    { "ready", "Ready check", "READY_CHECK", 8960 },
    { "alarm", "Alarm clock", "ALARM_CLOCK_WARNING_3", 12889 },
    { "quest", "Quest done", "IG_QUEST_LIST_COMPLETE", 878 },
    { "levelup", "Level up", "LEVELUPSOUND", 888 },
    { "coins", "Coins", "LOOT_WINDOW_COIN_SOUND", 120 },
}
B.SOUND_BY = {}
for _, s in ipairs(B.SOUNDS) do B.SOUND_BY[s[1]] = s end

-- World's "{player} is {state}"
B.STATES = { { "mounted", "mounted" }, { "flying", "flying" }, { "swimming", "swimming" }, { "dead", "dead" },
    { "combat", "in combat" }, { "moving", "moving" } }

-- A tag's colours (the mockups' swatches)
B.TAG_COLORS = {
    { "red", "Red", rgb("ff6a4d") }, { "orange", "Orange", rgb("ff9a3a") }, { "yellow", "Yellow", rgb("ffd84a") },
    { "green", "Green", rgb("62d65a") }, { "teal", "Teal", rgb("46d6c8") }, { "blue", "Blue", rgb("5aa8ff") },
    { "purple", "Purple", rgb("c9a2ff") }, { "pink", "Pink", rgb("ff8ac8") }, { "grey", "Grey", rgb("d8d8d8") },
}
B.TAG_COLOR = {}
for _, c in ipairs(B.TAG_COLORS) do B.TAG_COLOR[c[1]] = c[3] end

-- Who sees who has a tag, a score's look, how an ask is answered (the editors' choices)
B.TAG_SHOWN = { { "all", "Everyone" }, { "self", "Them" }, { "host", "The host" } }
B.SCORE_FMT = { { "num", "Number" }, { "time", "Time" }, { "gold", "Gold" } }
B.ASK_KINDS = { { "player", "A player" }, { "choice", "A choice" }, { "text", "Typed" }, { "yesno", "Yes or no" },
    { "number", "1 to 10" } }
B.LIST_KINDS = { { "text", "Texts" }, { "place", "Places" }, { "question", "Questions" } }

-- The limits a definition is held to (as Events.lua's CleanDef keeps them)
B.LIMITS = { name = 24, question = 120, answers = 6, answer = 40, items = 40, allItems = 80, places = 24, choices = 6,
    choice = 40, label = 24, defs = 24 }

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
    finalist1 = { label = "finalist 1", t = "player" },   -- (part 1's; "final is set" gives player 1 and 2 now)
    finalist2 = { label = "finalist 2", t = "player" },
    champion = { label = "champion", t = "player" },
    runnerup = { label = "second", t = "player" },
    third = { label = "third", t = "player" },
    player = { label = "player", t = "player" },
    each = { label = "each player", t = "player" },
    answer = { label = "the answer", t = "any" },
    other = { label = "other player", t = "player" },
    creature = { label = "creature", t = "text" },
    item = { label = "item", t = "any" },
    count = { label = "count", t = "num" },
    emote = { label = "emote", t = "text" },
    toucher = { label = "toucher", t = "player" },
    touched = { label = "touched", t = "player" },
    who = { label = "who", t = "player" },
    whom = { label = "whom", t = "player" },
    place = { label = "place", t = "place" },
}
B.CTX_ORDER = { "winner", "loser", "player1", "player2", "both", "opponent", "score", "game", "match", "round",
    "champion", "runnerup", "third", "player", "other", "toucher", "touched", "who", "whom", "each", "item", "place",
    "creature", "count", "emote", "answer" }

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
    -- (the kind is still "bracket": part 1's name for it)
    bracket = {
        label = "Matches", icon = "Interface\\Icons\\INV_BannerPVP_01", order = 2,
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
            -- duel: a duel between the two counts (part 1); pieces: duels don't count, "award the match to" decides
            { key = "win", label = "Won by", kind = "choice", d = "duel",
              choices = { { "duel", "A duel" }, { "pieces", "The pieces" } } },
        },
        gives = { "match starts", "game ends", "match ends", "final is set", "is done" },
    },
}
B.SMART_ORDER = { "signup", "bracket" }

function B:SmartDefaults(kind)
    local s = self.SMART[kind]
    local out = {}
    for _, o in ipairs(s and s.settings or {}) do out[o.key] = o.d end
    return out
end

-- A block's setting (its default when unset). A value of the wrong kind or out of range (an event from the wire: any
-- number, yes / no or short text gets through) reads as the default, a number as the nearest it may be.
function B:SmartSetting(block, key)
    local v = block and block.set and block.set[key]
    local s = block and self.SMART[block.kind]
    local opt
    for _, o in ipairs(s and s.settings or {}) do
        if o.key == key then opt = o end
    end
    if not opt then return v end
    if v == nil then return opt.d end
    if opt.kind == "bool" then
        if type(v) == "boolean" then return v end
    elseif opt.kind == "num" then
        if type(v) == "number" and v == v then return floor(min(opt.max or v, max(opt.min or v, v))) end
    elseif opt.kind == "dur" then
        if type(v) == "number" and v > 0 and v <= 3600 then return v end
    elseif opt.kind == "choice" then
        for _, c in ipairs(opt.choices or {}) do
            if c[1] == v then return v end
        end
    else
        return v
    end
    return opt.d
end

---------------------------------------------------------------------------
-- The pieces
---------------------------------------------------------------------------

-- shape: hat (starts a script), stack, cap (ends one), c (holds pieces), c2 (if / else), bool (a hexagon), value
-- (round). text: the words, {n} = blank n (in any order). args[n]: { t = type, d = default, kind = smart block kind,
-- of = the blank whose choice gives a "filter" blank its type, opt = may stay empty }. gives: values a hat gives its
-- script (B:Gives: "happen" gives by its choice). vt: what a value / bool piece gives. inner: shown only inside that
-- smart block (its own pieces). hide: never in the palette (internal, or kept for events made before).
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
def("ev.happen", { cat = "ev", shape = "hat", text = "when an entrant {1} {2}",
    args = { { t = "what", d = "duel" }, { t = "filter", of = 1, opt = true } }, gives = { "player" } })
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
def("bk.final", { cat = "ev", shape = "hat", text = "when {1} final is set", args = { BR },
    gives = { "player1", "player2", "both" } })
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
def("lo.set", { cat = "lo", shape = "bool", text = "{1} is set", args = { { t = "any" } } })
def("lo.add", { cat = "lo", shape = "value", vt = "num", text = "{1} + {2}", args = { { t = "num", d = 1 }, { t = "num", d = 1 } } })
def("lo.sub", { cat = "lo", shape = "value", vt = "num", text = "{1} - {2}", args = { { t = "num", d = 1 }, { t = "num", d = 1 } } })
def("lo.rand", { cat = "lo", shape = "value", vt = "num", text = "pick random {1} to {2}",
    args = { { t = "num", d = 1 }, { t = "num", d = 10 } } })
def("lo.vset", { cat = "lo", shape = "stack", text = "set {1} to {2}", args = { { t = "var" }, { t = "any" } } })
def("var", { cat = "lo", shape = "value", text = "{1}", args = { { t = "varname" } }, hide = true })
-- lists
def("lo.lfor", { cat = "lo", shape = "c", text = "for each item in {1}", args = { { t = "list" } }, gives = { "item" } })
def("lo.litem", { cat = "lo", shape = "value", vt = "any", text = "item {1} of {2}", args = { { t = "num", d = 1 }, { t = "list" } } })
def("lo.lrand", { cat = "lo", shape = "value", vt = "any", text = "a random item of {1}", args = { { t = "list" } } })
def("lo.lcount", { cat = "lo", shape = "value", vt = "num", text = "how many in {1}", args = { { t = "list" } } })
-- a list walked per player (a route, a riddle chain, a quiz at one's own pace)
def("lo.lnext", { cat = "lo", shape = "stack", text = "move {1} on in {2}", args = { { t = "players" }, { t = "list" } } })
def("lo.lmine", { cat = "lo", shape = "value", vt = "any", text = "{1}'s item in {2}", args = { { t = "player" }, { t = "list" } } })
def("lo.lpos", { cat = "lo", shape = "value", vt = "num", text = "{1}'s place in {2}", args = { { t = "player" }, { t = "list" } } })
def("lo.lend", { cat = "lo", shape = "hat", text = "when someone reaches the end of {1}", args = { { t = "list" } },
    gives = { "player" } })
def("lo.match", { cat = "lo", shape = "bool", text = "{1} matches {2}", args = { { t = "text" }, { t = "any" } } })

-- Players
def("pl.host", { cat = "pl", shape = "value", vt = "player", text = "the host", args = {} })
def("pl.all", { cat = "pl", shape = "value", vt = "players", text = "every entrant", args = {} })
def("pl.rand", { cat = "pl", shape = "value", vt = "player", text = "a random entrant", args = {} })
def("pl.count", { cat = "pl", shape = "value", vt = "num", text = "number of entrants", args = {}, hide = true })
def("pl.seed", { cat = "pl", shape = "value", vt = "player", text = "entrant #{1}", args = { { t = "num", d = 1 } } })
def("pl.tagged", { cat = "pl", shape = "value", vt = "players", text = "players with tag {1}", args = { { t = "tag" } } })
def("pl.top", { cat = "pl", shape = "value", vt = "players", text = "top {1} by {2}", args = { { t = "num", d = 3 }, { t = "score" } } })
def("pl.howmany", { cat = "pl", shape = "value", vt = "num", text = "how many in {1}", args = { { t = "players" } } })
def("pl.online", { cat = "pl", shape = "bool", text = "{1} is online", args = { { t = "player" } } })
def("pl.ready", { cat = "pl", shape = "bool", text = "{1} is ready", args = { { t = "player" } } })
def("pl.notready", { cat = "pl", shape = "bool", text = "{1} isn't ready", args = { { t = "player" } } })
def("pl.is", { cat = "pl", shape = "bool", text = "{1} is {2}", args = { { t = "player" }, { t = "player" } } })
def("pl.in", { cat = "pl", shape = "bool", text = "{1} is one of {2}", args = { { t = "player" }, { t = "players" } } })
def("pl.has", { cat = "pl", shape = "bool", text = "{1} has tag {2}", args = { { t = "player" }, { t = "tag" } } })
def("pl.tag", { cat = "pl", shape = "stack", text = "tag {1} as {2}", args = { { t = "players" }, { t = "tag" } } })
def("pl.untag", { cat = "pl", shape = "stack", text = "untag {1} from {2}", args = { { t = "players" }, { t = "tag" } } })
def("pl.split", { cat = "pl", shape = "stack", text = "split {1} into {2} and {3}",
    args = { { t = "players" }, { t = "tag" }, { t = "tag" } } })
def("pl.touch", { cat = "pl", shape = "hat", text = "when one of {1} touches one of {2} by {3} {4}",
    args = { { t = "players", opt = true }, { t = "players", opt = true }, { t = "how", d = "click" },
             { t = "filter", of = 3, opt = true } }, gives = { "toucher", "touched" } })
def("pl.radar", { cat = "pl", shape = "hat", text = "when one of {1} targets one of {2} without clicking",
    args = { { t = "players", opt = true }, { t = "players", opt = true } }, gives = { "who", "whom" } })
def("pl.gettag", { cat = "pl", shape = "hat", text = "when someone gets tag {1}", args = { { t = "tag" } }, gives = { "player" } })
def("pl.notag", { cat = "pl", shape = "hat", text = "when no one has tag {1}", args = { { t = "tag" } }, gives = {} })
def("ctx", { cat = "pl", shape = "value", text = "{1}", args = { { t = "ctxname" } }, hide = true })

-- Scores (one player or many: part 1's form; the keys are part 1's Points pieces)
def("pt.add", { cat = "pt", shape = "stack", text = "add {1} {2} to {3}",
    args = { { t = "num", d = 1 }, { t = "score" }, { t = "players" } } })
def("pt.set", { cat = "pt", shape = "stack", text = "set {1} of {2} to {3}",
    args = { { t = "score" }, { t = "players" }, { t = "num", d = 0 } } })
def("pt.badge", { cat = "pt", shape = "stack", text = "give {2} the badge {1}", args = { { t = "badge" }, { t = "players" } } })
def("pt.get", { cat = "pt", shape = "value", vt = "num", text = "{1}'s {2}", args = { { t = "player" }, { t = "score" } } })
def("pt.place", { cat = "pt", shape = "value", vt = "num", text = "{1}'s place by {2}", args = { { t = "player" }, { t = "score" } } })
def("pt.total", { cat = "pt", shape = "value", vt = "num", text = "the total {1} of {2}", args = { { t = "score" }, { t = "players" } } })
def("pt.reach", { cat = "pt", shape = "hat", text = "when someone's {1} reaches {2}", args = { { t = "score" }, { t = "num", d = 10 } },
    gives = { "player" } })
def("pt.lead", { cat = "pt", shape = "hat", text = "when the lead in {1} changes", args = { { t = "score" } }, gives = { "player" } })
def("pl.below", { cat = "sm", shape = "bool", text = "{1} was seeded {2} or more below {3}",
    args = { { t = "player" }, { t = "num", d = 4 }, { t = "player" } } })

-- Places
def("pc.enter", { cat = "pc", shape = "hat", text = "when an entrant enters {1}", args = { { t = "place", opt = true } },
    gives = { "player", "place" } })
def("pc.leave", { cat = "pc", shape = "hat", text = "when an entrant leaves {1}", args = { { t = "place", opt = true } },
    gives = { "player", "place" } })
def("pc.in", { cat = "pc", shape = "bool", text = "{1} is in {2}", args = { { t = "player" }, { t = "place" } } })
def("pc.yards", { cat = "pc", shape = "value", vt = "num", text = "yards from {1} to {2}", args = { { t = "player" }, { t = "where" } } })
def("pc.near", { cat = "pc", shape = "value", vt = "player", text = "the nearest of {1} to {2}",
    args = { { t = "players" }, { t = "player" } } })
def("pc.sub", { cat = "pc", shape = "value", vt = "text", text = "{1}'s subzone", args = { { t = "player" } } })
def("pc.zone", { cat = "pc", shape = "value", vt = "text", text = "{1}'s zone", args = { { t = "player" } } })
def("pc.warm", { cat = "pc", shape = "value", vt = "text", text = "{1} is warmer or colder to {2}",
    args = { { t = "player" }, { t = "where" } } })
def("pc.point", { cat = "pc", shape = "stack", text = "point {1} to {2}", args = { { t = "players" }, { t = "place" } } })
def("pc.unpoint", { cat = "pc", shape = "stack", text = "stop pointing {1}", args = { { t = "players" } } })

-- Ask (asks and buttons)
def("as.ask", { cat = "as", shape = "stack", text = "ask {1} {2}", args = { { t = "players" }, { t = "ask" } } })
def("as.askq", { cat = "as", shape = "stack", text = "ask {1} {2} with {3}", args = { { t = "players" }, { t = "ask" }, { t = "text" } } })
def("as.close", { cat = "as", shape = "stack", text = "close {1}", args = { { t = "ask" } } })
def("as.answer", { cat = "as", shape = "value", vt = "any", text = "{1}'s answer to {2}", args = { { t = "player" }, { t = "ask" } } })
def("as.top", { cat = "as", shape = "value", vt = "any", text = "the most picked answer to {1}", args = { { t = "ask" } } })
def("as.count", { cat = "as", shape = "value", vt = "num", text = "how many picked {1} in {2}", args = { { t = "any" }, { t = "ask" } } })
def("as.on", { cat = "as", shape = "hat", text = "when someone answers {1}", args = { { t = "ask" } }, gives = { "player", "answer" } })
def("as.closed", { cat = "as", shape = "hat", text = "when {1} closes", args = { { t = "ask" } }, gives = {} })
def("as.give", { cat = "as", shape = "stack", text = "give {1} the button {2}", args = { { t = "players" }, { t = "label", d = "Hint" } } })
def("as.take", { cat = "as", shape = "stack", text = "take the button {1} from {2}", args = { { t = "label", d = "Hint" }, { t = "players" } } })
def("as.press", { cat = "as", shape = "hat", text = "when someone presses {1}", args = { { t = "label", d = "Hint" } },
    gives = { "player" } })

-- Messages (the addon shows them; guild chat is the exception)
def("ch.show", { cat = "ch", shape = "stack", text = "show {1} {2}", args = { { t = "players" }, { t = "text", d = "" } } })
def("ch.tell", { cat = "ch", shape = "stack", text = "tell {1} {2}", args = { { t = "players" }, { t = "text", d = "" } } })
def("ch.moment", { cat = "ch", shape = "stack", text = "add a moment: {1}", args = { { t = "text", d = "" } } })
def("ch.sound", { cat = "ch", shape = "stack", text = "play {1} for {2}", args = { { t = "sound", d = "warning" }, { t = "players" } } })
def("ch.guild", { cat = "ch", shape = "stack", text = "post in guild chat: {1}", args = { { t = "text", d = "" } } })

-- Timers
def("tm.wait", { cat = "tm", shape = "stack", text = "wait {1}", args = { { t = "dur", d = 30 } } })
def("tm.start", { cat = "tm", shape = "stack", text = "start timer {1} named {2}",
    args = { { t = "dur", d = 300 }, { t = "timer", d = "timer" } } })
def("tm.startp", { cat = "tm", shape = "stack", text = "start timer {1} named {2} for {3}",
    args = { { t = "dur", d = 300 }, { t = "timer", d = "timer" }, { t = "player" } } })
def("tm.stop", { cat = "tm", shape = "stack", text = "stop timer {1}", args = { { t = "timer", d = "timer" } } })
def("tm.count", { cat = "tm", shape = "stack", text = "count down {1} for {2}", args = { { t = "num", d = 10 }, { t = "players" } } })
def("tm.since", { cat = "tm", shape = "value", vt = "num", text = "seconds since {1}", args = { { t = "since", d = "stage" } } })
def("tm.left", { cat = "tm", shape = "value", vt = "num", text = "seconds left on {1}", args = { { t = "timer", d = "timer" } } })
def("tm.show", { cat = "tm", shape = "stack", text = "show timer {1} on the board", args = { { t = "timer", d = "timer" } } })

-- World
def("wo.is", { cat = "wo", shape = "bool", text = "{1} is {2}", args = { { t = "player" }, { t = "state", d = "mounted" } } })
def("wo.items", { cat = "wo", shape = "value", vt = "num", text = "how many {1} {2} has", args = { { t = "item" }, { t = "player" } } })
def("wo.gold", { cat = "wo", shape = "value", vt = "num", text = "{1}'s gold gained", args = { { t = "player" } } })
def("wo.inv", { cat = "wo", shape = "stack", text = "invite {1} to a group", args = { { t = "players" } } })
def("wo.mark", { cat = "wo", shape = "stack", text = "mark {1} with {2}", args = { { t = "player" }, { t = "marker", d = 8 } } })
def("wo.plates", { cat = "wo", shape = "stack", text = "hide friendly nameplates for {1}", args = { { t = "players" } } })
-- (part 1's zone check from the guild roster: kept for the events that have it; "{player}'s zone" replaces it)
def("wo.zone", { cat = "wo", shape = "bool", text = "{1} is in zone {2}", args = { { t = "player" }, { t = "text", d = "Nagrand" } },
    hide = true })

-- Smart blocks: their values and actions
def("su.list", { cat = "sm", shape = "value", vt = "players", text = "{1} list", args = { SU } })
def("su.count", { cat = "sm", shape = "value", vt = "num", text = "number in {1}", args = { SU } })
def("su.closeit", { cat = "sm", shape = "stack", text = "close {1}", args = { SU } })
def("bk.award", { cat = "sm", shape = "stack", text = "award the match to {1}", args = { { t = "player" } } })
def("bk.out", { cat = "sm", shape = "stack", text = "take {1} out of the matches", args = { { t = "player" } } })
def("bk.champ", { cat = "sm", shape = "value", vt = "player", text = "{1} champion", args = { BR } })
def("bk.second", { cat = "sm", shape = "value", vt = "player", text = "{1} second", args = { BR } })
def("bk.third", { cat = "sm", shape = "value", vt = "player", text = "{1} third", args = { BR } })
def("bk.fin1", { cat = "sm", shape = "value", vt = "player", text = "{1} finalist 1", args = { BR } })
def("bk.fin2", { cat = "sm", shape = "value", vt = "player", text = "{1} finalist 2", args = { BR } })
def("bk.left", { cat = "sm", shape = "value", vt = "players", text = "players still in {1}", args = { BR } })
def("bk.round", { cat = "sm", shape = "value", vt = "num", text = "{1} round", args = { BR } })
def("bk.still", { cat = "sm", shape = "bool", text = "{1} is still in {2}", args = { { t = "player" }, BR } })

-- Matches' own pieces (inside it): how a duel becomes a game win, a game win a match, a round the next one
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
def("bk.close", { cat = "sm", shape = "cap", text = "finish the matches", args = {}, inner = "bracket" })

-- The palette's order per category (pieces not listed here are not in the palette). Each category's definitions (the
-- event's tags, scores, places, lists, asks) are listed above its pieces by the builder: B.CAT_DEFS.
B.PALETTE = {
    ev = { "ev.start", "ev.happen", "ev.timer", "ev.every" },
    sg = { "sg.go", "sg.next", "sg.end", "sg.cancel" },
    lo = { "lo.if", "lo.ifelse", "lo.rep", "lo.each", "lo.stop", "lo.and", "lo.or", "lo.not", "lo.gt", "lo.lt", "lo.eq",
           "lo.set", "lo.add", "lo.sub", "lo.rand", "lo.vset", "lo.lfor", "lo.litem", "lo.lrand", "lo.lcount", "lo.lnext",
           "lo.lmine", "lo.lpos", "lo.lend", "lo.match" },
    pl = { "pl.host", "pl.all", "pl.rand", "pl.seed", "pl.tagged", "pl.top", "pl.howmany", "pl.online", "pl.ready",
           "pl.notready", "pl.is", "pl.in", "pl.has", "pl.tag", "pl.untag", "pl.split", "pl.touch", "pl.radar",
           "pl.gettag", "pl.notag" },
    pt = { "pt.add", "pt.set", "pt.badge", "pt.get", "pt.place", "pt.total", "pt.reach", "pt.lead" },
    pc = { "pc.enter", "pc.leave", "pc.in", "pc.yards", "pc.near", "pc.sub", "pc.zone", "pc.warm", "pc.point", "pc.unpoint" },
    as = { "as.ask", "as.askq", "as.close", "as.answer", "as.top", "as.count", "as.on", "as.closed", "as.give", "as.take",
           "as.press" },
    ch = { "ch.show", "ch.tell", "ch.moment", "ch.sound", "ch.guild" },
    tm = { "tm.wait", "tm.start", "tm.startp", "tm.stop", "tm.count", "tm.since", "tm.left", "tm.show" },
    wo = { "wo.is", "wo.items", "wo.gold", "wo.inv", "wo.mark", "wo.plates" },
    sm = { "su.join", "su.leave", "su.close", "su.list", "su.count", "su.closeit", "bk.start", "bk.game", "bk.end",
           "bk.final", "bk.done", "bk.award", "bk.out", "bk.champ", "bk.second", "bk.third", "bk.fin1", "bk.fin2", "bk.left",
           "bk.round", "bk.still", "pl.below" },
}
-- The definitions a category lists first (its "+ Add ..."): kind per category. Variables are listed in Logic.
B.CAT_DEFS = { pl = "tags", pt = "scores", pc = "places", lo = "lists", as = "asks" }
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

-- May a piece giving type `vt` go into a blank of type `t`? (A value of no fixed type, "any" - a variable, an answer,
-- a list's item - goes anywhere but a yes / no blank: the engine reads it as what the blank needs.)
function B:Fits(t, vt)
    if not vt then return false end
    if t == "any" or t == "text" then return vt ~= "bool" or t == "any" end
    if vt == "any" then return t ~= "bool" end
    if t == "players" then return vt == "player" or vt == "players" end
    if t == "num" then return vt == "num" end
    if t == "where" then return vt == "place" or vt == "player" end
    return t == vt
end

-- Blanks that take a dropped-in value (the rest are dropdowns / fields only).
local DROP_TYPES = { player = true, players = true, num = true, text = true, any = true, bool = true, place = true, where = true }
function B:TakesPieces(t) return DROP_TYPES[t] == true end

-- The type of blank i of piece p: a "filter" blank takes its type from the choice in the blank it belongs to (nil:
-- that choice has none, the blank isn't there).
function B:ArgType(p, i)
    local pd = type(p) == "table" and P[p.k]
    local a = pd and pd.args and pd.args[i]
    if not a then return nil end
    if a.t ~= "filter" then return a.t end
    local choice = p.a and p.a[a.of]
    local list = (p.k == "pl.touch") and self.TOUCH_BY or self.HAPPEN_BY
    local c = list[choice]
    return c and c.filter or nil
end

-- What a hat gives its script: names of B.CTX ("when an entrant ..." gives what its choice gives).
function B:Gives(p)
    local pd = type(p) == "table" and P[p.k]
    if not pd then return {} end
    if p.k == "ev.happen" then
        local h = self.HAPPEN_BY[p.a and p.a[1]]
        return h and h.gives or pd.gives
    end
    return pd.gives or {}
end

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

-- Every script of a def, the event's and its smart blocks' own: fn(script, list, blockId | nil).
function B:EachScript(d, fn)
    for _, s in ipairs(d and d.scripts or {}) do fn(s, d.scripts, nil) end
    for _, bid in ipairs(self:BlocksOf(d)) do
        local b = d.blocks[bid]
        for _, s in ipairs(b.inner or {}) do fn(s, b.inner, bid) end
    end
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
-- Definitions: tags, scores, places, lists, asks
---------------------------------------------------------------------------

B.DEF_KINDS = {
    tags = { prefix = "tg", label = "tag", t = "tag" },
    scores = { prefix = "sc", label = "score", t = "score" },
    places = { prefix = "pc", label = "place", t = "place" },
    lists = { prefix = "ls", label = "list", t = "list" },
    asks = { prefix = "ak", label = "ask", t = "ask" },
}
B.DEF_ORDER = { "tags", "scores", "places", "lists", "asks" }
local DEF_OF_TYPE = { tag = "tags", score = "scores", place = "places", list = "lists", ask = "asks" }
B.DEF_OF_TYPE = DEF_OF_TYPE

-- The built-in ones (every event has them; not stored in the def)
B.BUILTIN = {
    tags = { [B.ENTRANTS] = { n = "Entrants", c = "grey", shown = "all", builtin = true } },
    scores = { [B.SEASON] = { n = "Season points", high = true, fmt = "num", builtin = true } },
}

-- A definition (built-in ones too) or nil.
function B:Definition(d, kind, id)
    if id == nil then return nil end
    local bi = self.BUILTIN[kind]
    if bi and bi[id] then return bi[id] end
    local t = d and d[kind]
    local x = type(t) == "table" and t[id]
    return type(x) == "table" and x or nil
end

function B:DefinitionName(d, kind, id)
    local x = self:Definition(d, kind, id)
    return x and x.n or tostring(id or "?")
end

-- The event's definitions of a kind, built-in ones first (own: only the event's): { { id = id, builtin, n, ... } }.
function B:Defs(d, kind, own)
    local out = {}
    if not own then
        for id, x in pairs(self.BUILTIN[kind] or {}) do
            local e = Copy(x)
            e.id = id
            out[#out + 1] = e
        end
    end
    local list = {}
    for id, x in pairs(type(d) == "table" and type(d[kind]) == "table" and d[kind] or {}) do
        if type(x) == "table" then
            local e = Copy(x)
            e.id = id
            list[#list + 1] = e
        end
    end
    tsort(list, function(a, b)
        local na, nb = strlower(tostring(a.n or "")), strlower(tostring(b.n or ""))
        if na ~= nb then return na < nb end
        return tostring(a.id) < tostring(b.id)
    end)
    for _, e in ipairs(list) do out[#out + 1] = e end
    return out
end

local DEF_DEFAULTS = {
    tags = { c = "blue", shown = "all" },
    scores = { high = true, fmt = "num", board = true },
    places = { r = 30 },
    lists = { kind = "text" },
    asks = { kind = "player", from = "entrants", votes = 1, self = false, time = 60, secret = false },
}

-- A new definition in the def (fields: its own, defaults for the rest): its id (tg1, sc2, ...), or nil when the event
-- has as many as it may.
function B:NewDefinition(d, kind, fields)
    local dk = self.DEF_KINDS[kind]
    if not (dk and type(d) == "table") then return nil end
    d[kind] = type(d[kind]) == "table" and d[kind] or {}
    local n = 0
    for _ in pairs(d[kind]) do n = n + 1 end
    if n >= (kind == "places" and self.LIMITS.places or self.LIMITS.defs) then return nil end
    local i = 1
    while d[kind][dk.prefix .. i] do i = i + 1 end
    local id = dk.prefix .. i
    local x = Copy(DEF_DEFAULTS[kind] or {})
    for k, v in pairs(fields or {}) do x[k] = Copy(v) end
    x.n = tostring(x.n or (dk.label:gsub("^%l", strupper) .. " " .. i)):sub(1, self.LIMITS.name)
    if kind == "lists" and type(x.items) ~= "table" then x.items = {} end
    d[kind][id] = x
    return id
end

-- Takes a definition out (the pieces that use it then say so).
function B:RemoveDefinition(d, kind, id)
    if type(d) == "table" and type(d[kind]) == "table" then d[kind][id] = nil end
end

-- How many pieces use a definition ("3 pieces use it").
function B:DefinitionUses(d, kind, id)
    local n = 0
    local t = self.DEF_KINDS[kind] and self.DEF_KINDS[kind].t
    self:EachScript(d, function(s)
        self:Walk(s.top, function(p)
            local pd = P[p.k]
            for i, a in ipairs(pd and pd.args or {}) do
                if a.t == t and p.a and p.a[i] == id then n = n + 1 end
                if t == "place" and a.t == "where" and p.a and p.a[i] == id then n = n + 1 end
            end
        end)
    end)
    -- a list of places uses them too
    if kind == "places" then
        for _, l in pairs(type(d) == "table" and type(d.lists) == "table" and d.lists or {}) do
            if type(l) == "table" and l.kind == "place" then
                for _, it in ipairs(type(l.items) == "table" and l.items or {}) do
                    if it == id then n = n + 1 end
                end
            end
        end
    end
    return n
end

-- A score's number as its look says: a time (m:ss), gold (copper as 1g 20s 5c) or a number.
function B:FormatScore(d, sid, n)
    n = tonumber(n)
    if not n then return "" end
    local sc = self:Definition(d, "scores", sid)
    local fmt = sc and sc.fmt
    if fmt == "time" then
        n = floor(n + 0.5)
        if n >= 3600 then return strformat("%d:%02d:%02d", floor(n / 3600), floor(n / 60) % 60, n % 60) end
        return strformat("%d:%02d", floor(n / 60), n % 60)
    elseif fmt == "gold" then
        n = floor(n)
        local g, s, c = floor(n / 10000), floor(n / 100) % 100, n % 100
        if g > 0 then return s > 0 and strformat("%dg %ds", g, s) or (g .. "g") end
        if s > 0 then return c > 0 and strformat("%ds %dc", s, c) or (s .. "s") end
        return c .. "c"
    end
    if n == floor(n) then return tostring(n) end
    return strformat("%.1f", n)
end

function B:TagColor(c) return self.TAG_COLOR[c] or self.TAG_COLOR.grey end

---------------------------------------------------------------------------
-- Building pieces in code (the examples, Matches' own scripts, demo data)
---------------------------------------------------------------------------

local function N(key, ...)
    local p = B:New(key)
    if not p then error("no piece " .. tostring(key), 2) end
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
local function Each(list, ...) local p = N("lo.each", list); p.c1 = B:Stack(...); return p end
local function ForItems(list, ...) local p = N("lo.lfor", list); p.c1 = B:Stack(...); return p end
local function T(tid) return N("pl.tagged", tid) end
B.Build = { N = N, C = C, V = V, J = J, If = If, IfElse = IfElse, Each = Each, ForItems = ForItems, T = T }

-- Matches' own scripts: what "Open" shows, and what runs unless the event has its own copy.
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

---------------------------------------------------------------------------
-- The examples ("Start from"): one def each, every one a few general blocks at work
---------------------------------------------------------------------------

local ICON = "Interface\\Icons\\"
local NAGRAND, TEROKKAR = 1951, 1952   -- the zones' map ids (uiMapID)
local SEASON, ENTR = B.SEASON, B.ENTRANTS
local function All() return T(ENTR) end

local function Signup(spots, lvl70, closes)
    return { kind = "signup", stage = "s1", x = 20, y = 20, set = { spots = spots, closes = closes or "start", lvl70 = lvl70 } }
end

-- Everyone to the start (when the sign-up stays open until the host closes it: they gather first), and who joins late.
local function Gather(id, pid, words)
    return { id = id, st = "s1", x = 20, y = 22, top = B:Stack(
        N("ev.start"),
        N("pc.point", N("pl.all"), pid),
        N("ch.tell", N("pl.all"), J(words))) },
        { id = id .. "j", st = "s1", x = 20, y = 160, top = B:Stack(
        N("su.join", "b1"),
        N("pc.point", C("player"), pid),
        N("ch.tell", C("player"), J(words))) }
end

-- "when sign-up closes": too few cancels, else the next stage
local function CloseOrCancel(id, least, why)
    return { id = id, st = "s1", x = 370, y = 20, top = B:Stack(
        N("su.close", "b1"),
        IfElse(N("lo.lt", N("su.count", "b1"), least), N("sg.cancel", why), N("sg.next"))) }
end

-- Badges and season points for the top three by a score (ties share a place), then the event's one guild post.
local function Podium(score, gold, silver, bronze, pts, post)
    local place = function(n, badge, p)
        return If(N("lo.eq", N("pt.place", C("each"), score), n), N("pt.badge", badge, C("each")), N("pt.add", p, SEASON, C("each")))
    end
    return B:Stack(
        Each(N("pl.top", 3, score), place(1, gold, pts[1]), place(2, silver, pts[2]), place(3, bronze, pts[3])),
        If(N("lo.set", N("pl.top", 1, score)), N("ch.guild", post)),
        N("sg.end"))
end

-- A badge and season points for whoever is first by a score (all of them on a tie).
local function Firsts(score, badge, pts)
    return Each(N("pl.all"),
        If(N("lo.eq", N("pt.place", C("each"), score), 1), N("pt.badge", badge, C("each")), N("pt.add", pts, SEASON, C("each"))))
end

local EX = {}

-- The Friday duel cup (part 1's starter, rebuilt): a 16-player single elimination, won by duels. No whispers or raid
-- warnings: the match card tells players when they're up; matches end as moments, an upset is shown on screen, the
-- champion gets the one post in guild chat.
EX[1] = { key = "duel", name = "Friday duel cup", icon = ICON .. "Ability_DualWield", art = "nagrand",
    desc = "Sign-up, Matches won by a duel, moments and one guild post", make = function()
    local d = {
        name = "Friday duel cup", icon = ICON .. "Ability_DualWield", art = "nagrand",
        stages = { { id = "s1", name = "Sign-up" }, { id = "s2", name = "Bracket" }, { id = "s3", name = "Finals" },
                   { id = "s4", name = "Prizes" } },
        vars = { { n = "Biggest upset", t = "player" } },
        badges = {
            champ = { n = "Duel champion", i = ICON .. "Ability_Warrior_Challange", f = "gold", ti = "the Duelist" },
            second = { n = "Runner-up", i = ICON .. "Ability_Parry", f = "silver" },
            third = { n = "Third place", i = ICON .. "INV_Jewelry_Talisman_07", f = "bronze" },
            upset = { n = "Giant slayer", i = ICON .. "INV_Misc_Head_Dragon_01", f = "blood" },
        },
        blocks = {
            b1 = Signup(16, true),
            b2 = { kind = "bracket", stage = "s2", x = 20, y = 22, set = { fmt = "single", bo = 3, fbo = 5, seed = "season",
                   noshow = 300, atonce = 2, bronze = true, win = "duel" } },
        },
        notes = {},
    }
    local BRK = "b2"
    d.scripts = {
        { id = "c1", st = "s1", x = 370, y = 20, top = B:Stack(
            N("su.join", "b1"),
            N("ch.tell", C("player"), J("You're in the Friday duel cup. Seeds are set when sign-up closes."))) },
        { id = "c2", st = "s1", x = 370, y = 150, top = B:Stack(
            N("su.close", "b1"),
            IfElse(N("lo.lt", N("su.count", "b1"), 4),
                N("sg.cancel", "Not enough duelists"),
                N("sg.go", "s2"))) },
        { id = "c3", st = "*", x = 20, y = 22, top = B:Stack(
            N("bk.final", BRK),
            N("ch.show", All(), J("Final: ", C("player1"), " vs ", C("player2"))),
            N("sg.go", "s3")) },
        { id = "c4", st = "*", x = 20, y = 150, top = B:Stack(
            N("bk.end", BRK),
            N("pt.add", 5, SEASON, C("winner")),
            N("ch.moment", J(C("winner"), " beats ", C("loser"), " ", C("score"))),
            If(N("pl.below", C("winner"), 4, C("loser")),
                N("ch.show", All(), J("Upset! ", C("winner"), " knocks out ", C("loser"))),
                N("lo.vset", "Biggest upset", C("winner")))) },
        { id = "c5", st = "*", x = 520, y = 22, top = B:Stack(
            N("ev.happen", "off"),
            If(N("bk.still", C("player"), BRK), N("ch.tell", N("pl.host"), J(C("player"), " went offline")))) },
        { id = "c6", st = "s3", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("tm.count", 10, N("pl.all"))) },
        { id = "c7", st = "*", x = 20, y = 370, top = B:Stack(
            N("bk.done", BRK),
            If(N("lo.set", C("champion")), N("ch.guild", J(C("champion"), " wins the Friday duel cup!"))),
            N("sg.go", "s4")) },
        { id = "c8", st = "s4", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("pt.badge", "champ", N("bk.champ", BRK)),
            N("pt.add", 50, SEASON, N("bk.champ", BRK)),
            N("pt.badge", "second", N("bk.second", BRK)),
            N("pt.add", 30, SEASON, N("bk.second", BRK)),
            N("pt.badge", "third", N("bk.third", BRK)),
            N("pt.add", 20, SEASON, N("bk.third", BRK)),
            -- the Giant slayer: only when there was an upset
            If(N("lo.set", V("Biggest upset")),
                N("pt.badge", "upset", V("Biggest upset")),
                N("pt.add", 10, SEASON, V("Biggest upset"))),
            N("sg.end")) },
        -- everyone who plays gets 5 when the bracket starts
        { id = "c9", st = "s2", x = 370, y = 22, top = B:Stack(
            N("ev.start"),
            Each(N("pl.all"), N("pt.add", 5, SEASON, C("each")))) },
    }
    return d
end }

-- Hide and seek: tags move a found Hider to Found, a touch finds, a play area keeps Hiders in, a Hint button.
local PLAY_AREA = { n = "Play area", map = NAGRAND, x = 0.415, y = 0.47, r = 600, z = "Nagrand", sz = "Halaa" }
local function GoBack(tag)   -- a player of `tag` who leaves the play area is told and pointed back
    return B:Stack(N("pc.leave", "pc1"),
        If(N("pl.has", C("player"), tag),
            N("ch.tell", C("player"), J("Go back to the play area")),
            N("pc.point", C("player"), "pc1")))
end
EX[2] = { key = "hide", name = "Hide and seek in Nagrand", icon = ICON .. "Ability_Stealth", art = "eots",
    desc = "Tags, a touch, a play area and a Hint button", make = function()
    local d = {
        name = "Hide and seek in Nagrand", icon = ICON .. "Ability_Stealth", art = "eots",
        stages = { { id = "s1", name = "Sign-up" }, { id = "s2", name = "Hide" }, { id = "s3", name = "Seek" },
                   { id = "s4", name = "Prizes" } },
        tags = { tg1 = { n = "Hiders", c = "green", shown = "all" }, tg2 = { n = "Seekers", c = "red", shown = "all" },
                 tg3 = { n = "Found", c = "purple", shown = "all" } },
        scores = { sc1 = { n = "Finds", high = true, fmt = "num", board = true },
                   sc2 = { n = "Hidden", high = true, fmt = "time", board = true } },
        places = { pc1 = Copy(PLAY_AREA) },
        vars = { { n = "Clue", t = "text" } },
        badges = {
            seeker = { n = "Sharp eyes", i = ICON .. "Ability_Hunter_SniperShot", f = "gold", ti = "the Seeker" },
            hider = { n = "Last one found", i = ICON .. "Ability_Stealth", f = "arcane", ti = "the Unseen" },
        },
        blocks = { b1 = Signup(20, false) },
        notes = {},
    }
    d.scripts = {
        CloseOrCancel("h1", 3, "Not enough players"),
        -- one seeker, everyone else hides
        { id = "h2", st = "s2", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("pl.tag", All(), "tg1"),
            N("pl.tag", N("pl.rand"), "tg2"),
            N("pl.untag", T("tg2"), "tg1"),
            N("ch.show", T("tg1"), J("Hide in the play area! The seekers come in 3 minutes.")),
            N("ch.show", T("tg2"), J("You seek. Wait for the timer, then click the hiders you find.")),
            N("pc.point", T("tg1"), "pc1"),
            N("tm.start", 180, "Hide"),
            N("tm.show", "Hide")) },
        { id = "h3", st = "s2", x = 444, y = 22, top = B:Stack(N("ev.timer", "Hide"), N("sg.next")) },
        { id = "h4", st = "*", x = 444, y = 206, top = GoBack("tg1") },
        { id = "h5", st = "s3", x = 444, y = 22, top = B:Stack(
            N("ev.start"),
            N("as.give", T("tg2"), "Hint"),
            N("wo.plates", T("tg2")),
            N("tm.start", 1200, "Seek"),
            N("tm.show", "Seek"),
            N("ch.show", All(), J("Seek! 20 minutes."))) },
        -- a Seeker touching a Hider finds them
        { id = "h6", st = "s3", x = 20, y = 22, top = B:Stack(
            N("pl.touch", T("tg2"), T("tg1"), "click"),
            N("pl.untag", C("touched"), "tg1"),
            N("pl.tag", C("touched"), "tg3"),
            N("pt.add", 1, "sc1", C("toucher")),
            N("pt.set", "sc2", C("touched"), N("tm.since", "Seek")),
            N("ch.tell", T("tg1"), J(C("touched"), " was found")),
            N("ch.moment", J(C("toucher"), " found ", C("touched")))) },
        -- the Hint: the nearest hider's subzone, then a minute without it
        { id = "h7", st = "s3", x = 20, y = 262, top = B:Stack(
            N("as.press", "Hint"),
            N("lo.vset", "Clue", N("pc.sub", N("pc.near", T("tg1"), C("player")))),
            IfElse(N("lo.set", V("Clue")),
                N("ch.tell", C("player"), J("Nearest hider: ", V("Clue"))),
                N("ch.tell", C("player"), J("No hint yet: try again in a minute"))),
            N("as.take", "Hint", C("player")),
            N("tm.wait", 60),
            N("as.give", C("player"), "Hint")) },
        { id = "h8", st = "s3", x = 20, y = 474, top = B:Stack(
            N("pl.radar", T("tg2"), T("tg1")),
            N("ch.tell", C("who"), J("Click them to find them. Macros don't count"))) },
        { id = "h9", st = "s3", x = 444, y = 380, top = B:Stack(N("pl.notag", "tg1"), N("sg.go", "s4")) },
        -- time's up: the ones still hidden were hidden all along
        { id = "h10", st = "s3", x = 444, y = 470, top = B:Stack(
            N("ev.timer", "Seek"),
            N("pt.set", "sc2", T("tg1"), N("tm.since", "Seek")),
            N("sg.go", "s4")) },
        { id = "h11", st = "s4", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            Firsts("sc1", "seeker", 20),
            Firsts("sc2", "hider", 20),
            Each(N("pl.all"), N("pt.add", 5, SEASON, C("each"))),
            If(N("lo.set", N("pl.top", 1, "sc2")),
                N("ch.guild", J(N("pl.top", 1, "sc2"), " stayed hidden the longest in hide and seek!"))),
            N("sg.end")) },
    }
    return d
end }

-- Infection: hide and seek's blocks, but a touched Hider turns Seeker; it ends when no one has Hiders.
EX[3] = { key = "infect", name = "Infection", icon = ICON .. "INV_Misc_Bone_ElfSkull_01", art = "ruins",
    desc = "Tags: whoever is touched turns seeker", make = function()
    local d = {
        name = "Infection", icon = ICON .. "INV_Misc_Bone_ElfSkull_01", art = "ruins",
        stages = { { id = "s1", name = "Sign-up" }, { id = "s2", name = "Run" }, { id = "s3", name = "Infect" },
                   { id = "s4", name = "Prizes" } },
        tags = { tg1 = { n = "Hiders", c = "green", shown = "all" }, tg2 = { n = "Infected", c = "red", shown = "all" } },
        scores = { sc1 = { n = "Infections", high = true, fmt = "num", board = true },
                   sc2 = { n = "Survived", high = true, fmt = "time", board = true } },
        places = { pc1 = Copy(PLAY_AREA) },
        badges = {
            zero = { n = "Patient zero", i = ICON .. "Spell_Shadow_PlagueCloud", f = "fel" },
            last = { n = "Last one standing", i = ICON .. "INV_Misc_Bone_ElfSkull_01", f = "gold", ti = "the Immune" },
        },
        blocks = { b1 = Signup(24, false) },
        notes = {},
    }
    d.scripts = {
        CloseOrCancel("i1", 3, "Not enough players"),
        { id = "i2", st = "s2", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("pl.tag", All(), "tg1"),
            N("pl.tag", N("pl.rand"), "tg2"),
            N("pl.untag", T("tg2"), "tg1"),
            N("ch.show", T("tg1"), J("Run and hide in the play area: the infection starts in 2 minutes.")),
            N("ch.show", T("tg2"), J("You're infected. In 2 minutes, click the others to infect them.")),
            N("tm.start", 120, "Run"),
            N("tm.show", "Run")) },
        { id = "i3", st = "s2", x = 444, y = 22, top = B:Stack(N("ev.timer", "Run"), N("sg.next")) },
        { id = "i4", st = "s3", x = 444, y = 120, top = B:Stack(
            N("ev.start"),
            N("tm.start", 900, "Infect"),
            N("tm.show", "Infect"),
            N("ch.show", All(), J("The infection spreads!"))) },
        { id = "i5", st = "s3", x = 20, y = 22, top = B:Stack(
            N("pl.touch", T("tg2"), T("tg1"), "click"),
            N("pl.untag", C("touched"), "tg1"),
            N("pl.tag", C("touched"), "tg2"),
            N("pt.add", 1, "sc1", C("toucher")),
            N("pt.set", "sc2", C("touched"), N("tm.since", "Infect")),
            N("ch.show", C("touched"), J("You're infected! Now catch the others.")),
            N("ch.moment", J(C("toucher"), " infected ", C("touched"))),
            If(N("lo.eq", N("pl.howmany", T("tg1")), 1), N("ch.show", All(), J("Last one standing: ", T("tg1"))))) },
        { id = "i6", st = "*", x = 444, y = 260, top = GoBack("tg1") },
        { id = "i7", st = "s3", x = 444, y = 400, top = B:Stack(N("pl.notag", "tg1"), N("sg.go", "s4")) },
        { id = "i8", st = "s3", x = 444, y = 480, top = B:Stack(
            N("ev.timer", "Infect"),
            N("pt.set", "sc2", T("tg1"), N("tm.since", "Infect")),
            N("sg.go", "s4")) },
        { id = "i9", st = "s4", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            Firsts("sc1", "zero", 15),
            Firsts("sc2", "last", 25),
            Each(N("pl.all"), N("pt.add", 5, SEASON, C("each"))),
            If(N("lo.set", N("pl.top", 1, "sc2")),
                N("ch.guild", J(N("pl.top", 1, "sc2"), " held out the longest against the infection!"))),
            N("sg.end")) },
    }
    return d
end }

-- Mount race: a Route of places walked by each racer, the arrow to the next one, a Time score (lower wins).
local ROUTE = {
    { "Garadar", 0.555, 0.37 }, { "Throne of the Elements", 0.605, 0.232 }, { "Ring of Trials", 0.43, 0.212 },
    { "Halaa", 0.42, 0.452 }, { "Sunspring Post", 0.322, 0.43 }, { "Oshu'gun", 0.35, 0.722 }, { "Clan Watch", 0.62, 0.62 },
    { "Burning Blade Ruins", 0.735, 0.39 },
}
EX[4] = { key = "race", name = "Mount race", icon = ICON .. "Ability_Mount_RidingHorse", art = "kalimdor",
    desc = "A Route of places, a Time score and the arrow", make = function()
    local d = {
        name = "Mount race", icon = ICON .. "Ability_Mount_RidingHorse", art = "kalimdor",
        stages = { { id = "s1", name = "Sign-up", desc = "Meet at Garadar on a ground mount." },
                   { id = "s2", name = "Race" }, { id = "s3", name = "Prizes" } },
        tags = { tg1 = { n = "Racing", c = "blue", shown = "all" }, tg2 = { n = "Out", c = "grey", shown = "all" } },
        scores = { sc1 = { n = "Time", high = false, fmt = "time", board = true } },
        places = {},
        lists = { ls1 = { n = "Route", kind = "place", items = {} } },
        badges = {
            gold = { n = "Fastest rider", i = ICON .. "Ability_Mount_RidingHorse", f = "gold", ti = "the Swift" },
            silver = { n = "Second rider", i = ICON .. "Ability_Mount_WhiteTiger", f = "silver" },
            bronze = { n = "Third rider", i = ICON .. "Ability_Mount_Raptor", f = "bronze" },
        },
        blocks = { b1 = Signup(20, false, "host") },
        notes = {},
    }
    for i, r in ipairs(ROUTE) do
        d.places["pc" .. i] = { n = r[1], map = NAGRAND, x = r[2], y = r[3], r = 40, z = "Nagrand" }
    end
    -- Garadar is the start and the finish: the route goes round and back
    for i = 2, #ROUTE do d.lists.ls1.items[#d.lists.ls1.items + 1] = "pc" .. i end
    d.lists.ls1.items[#d.lists.ls1.items + 1] = "pc1"
    local mine = function() return N("lo.lmine", C("player"), "ls1") end
    local meet, late = Gather("r1", "pc1", "Meet at Garadar on a ground mount. The race starts when the host closes the sign-up.")
    d.scripts = {
        meet, late,
        CloseOrCancel("r2", 2, "Not enough racers"),
        { id = "r3", st = "s2", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("pl.tag", All(), "tg1"),
            N("tm.count", 10, N("pl.all")),
            N("tm.wait", 10),
            Each(N("pl.all"), N("pc.point", C("each"), N("lo.lmine", C("each"), "ls1"))),
            N("ch.show", All(), J("Go! Follow the arrow round Nagrand.")),
            N("tm.start", 1800, "Race"),
            N("tm.show", "Race")) },
        -- the next place on my route: on to the one after
        { id = "r4", st = "s2", x = 444, y = 22, top = B:Stack(
            N("pc.enter"),
            If(N("lo.and", N("pl.has", C("player"), "tg1"), N("lo.eq", C("place"), mine())),
                N("lo.lnext", C("player"), "ls1"),
                N("pc.point", C("player"), mine()))) },
        { id = "r5", st = "s2", x = 444, y = 200, top = B:Stack(
            N("lo.lend", "ls1"),
            N("pt.set", "sc1", C("player"), N("tm.since", "Race")),
            N("pl.untag", C("player"), "tg1"),
            N("ch.moment", J(C("player"), " crosses the finish line")),
            N("ch.tell", C("player"), J("You finish in place ", N("pt.place", C("player"), "sc1")))) },
        -- off the mount: out of the race
        { id = "r6", st = "s2", x = 20, y = 300, top = B:Stack(
            N("ev.happen", "dismount"),
            If(N("pl.has", C("player"), "tg1"),
                N("pl.untag", C("player"), "tg1"),
                N("pl.tag", C("player"), "tg2"),
                N("pc.unpoint", C("player")),
                N("ch.tell", C("player"), J("You got off your mount: you're out of the race")),
                N("ch.moment", J(C("player"), " is out: off the mount")))) },
        { id = "r7", st = "s2", x = 444, y = 360, top = B:Stack(N("pl.notag", "tg1"), N("sg.next")) },
        { id = "r8", st = "s2", x = 444, y = 440, top = B:Stack(N("ev.timer", "Race"), N("sg.next")) },
        { id = "r9", st = "s3", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("pc.unpoint", N("pl.all")),
            Podium("sc1", "gold", "silver", "bronze", { 30, 20, 10 }, J(N("pl.top", 1, "sc1"), " wins the mount race!"))) },
    }
    return d
end }

-- Fishing derby: "catches a fish" adds to a Fish score, 30 minutes on a timer the board shows, the top 3 get badges.
EX[5] = { key = "fish", name = "Fishing derby", icon = ICON .. "Trade_Fishing", art = "ek",
    desc = "Catches a fish, a Fish score and a 30 min timer", make = function()
    local d = {
        name = "Fishing derby", icon = ICON .. "Trade_Fishing", art = "ek",
        stages = { { id = "s1", name = "Sign-up" }, { id = "s2", name = "Fishing" }, { id = "s3", name = "Prizes" } },
        scores = { sc1 = { n = "Fish", high = true, fmt = "num", board = true } },
        badges = {
            gold = { n = "Angler of the night", i = ICON .. "Trade_Fishing", f = "gold", ti = "the Angler" },
            silver = { n = "Runner-up", i = ICON .. "INV_Fishingpole_02", f = "silver" },
            bronze = { n = "Third place", i = ICON .. "INV_Misc_Fish_37", f = "bronze" },
        },
        blocks = { b1 = Signup(40, false) },
        notes = {},
    }
    d.scripts = {
        CloseOrCancel("f1", 2, "Not enough anglers"),
        { id = "f2", st = "s2", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("ch.show", All(), J("Fish! 30 minutes: every fish counts.")),
            N("tm.start", 1800, "Derby"),
            N("tm.show", "Derby")) },
        { id = "f3", st = "s2", x = 20, y = 180, top = B:Stack(
            N("ev.happen", "fish"),
            N("pt.add", 1, "sc1", C("player"))) },
        { id = "f4", st = "s2", x = 20, y = 280, top = B:Stack(
            N("ev.happen", "fish", "Mr. Pinchy"),
            N("ch.moment", J(C("player"), " fished up Mr. Pinchy"))) },
        { id = "f5", st = "s2", x = 444, y = 22, top = B:Stack(
            N("pt.lead", "sc1"),
            N("ch.tell", All(), J(C("player"), " leads with ", N("pt.get", C("player"), "sc1"), " fish"))) },
        { id = "f6", st = "s2", x = 444, y = 140, top = B:Stack(N("ev.timer", "Derby"), N("sg.next")) },
        { id = "f7", st = "s3", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            Each(N("pl.all"), If(N("lo.gt", N("pt.get", C("each"), "sc1"), 0), N("pt.add", 5, SEASON, C("each")))),
            Podium("sc1", "gold", "silver", "bronze", { 30, 20, 10 },
                J(N("pl.top", 1, "sc1"), " wins the fishing derby with ", N("pt.get", N("pl.top", 1, "sc1"), "sc1"), " fish!"))) },
    }
    return d
end }

-- Transmog contest: the host picks judges; every entrant on show while the judges score 1 to 10; a vote for the best.
EX[6] = { key = "tmog", name = "Transmog contest", icon = ICON .. "INV_Misc_Bandana_03", art = "outland",
    desc = "Each entrant on show, judges score 1 to 10", make = function()
    local d = {
        name = "Transmog contest", icon = ICON .. "INV_Misc_Bandana_03", art = "outland",
        stages = { { id = "s1", name = "Sign-up" }, { id = "s2", name = "Judges" }, { id = "s3", name = "Catwalk" },
                   { id = "s4", name = "Vote" }, { id = "s5", name = "Prizes" } },
        tags = { tg1 = { n = "Judges", c = "orange", shown = "all" } },
        scores = { sc1 = { n = "Votes", high = true, fmt = "num", board = true } },
        asks = {
            ak1 = { n = "Pick judges", q = "Who judges? Pick up to 3", kind = "player", from = "entrants", votes = 3,
                    self = true, time = 120, secret = false },
            ak2 = { n = "Judges' score", q = "Score this outfit", kind = "number", from = "entrants", votes = 1, self = false,
                    time = 45, secret = true },
            ak3 = { n = "Best outfit", q = "Who wore it best?", kind = "player", from = "entrants", votes = 3, self = false,
                    time = 120, secret = true },
        },
        vars = { { n = "Model", t = "player" } },
        badges = {
            gold = { n = "Best dressed", i = ICON .. "INV_Misc_Bandana_03", f = "gold", ti = "the Fabulous" },
            silver = { n = "Runner-up", i = ICON .. "INV_Helmet_66", f = "silver" },
            bronze = { n = "Third place", i = ICON .. "INV_Shirt_Black_01", f = "bronze" },
        },
        blocks = { b1 = Signup(20, false) },
        notes = {},
    }
    d.scripts = {
        CloseOrCancel("t1", 3, "Not enough models"),
        -- the host picks the judges (nobody picked: the host judges)
        { id = "t2", st = "s2", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("as.ask", N("pl.host"), "ak1"),
            N("pl.tag", N("as.answer", N("pl.host"), "ak1"), "tg1"),
            If(N("lo.eq", N("pl.howmany", T("tg1")), 0), N("pl.tag", N("pl.host"), "tg1")),
            N("ch.show", All(), J("The judges: ", T("tg1"))),
            N("sg.next")) },
        -- the catwalk: each entrant in turn, scored by the judges
        { id = "t3", st = "s3", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            Each(N("pl.all"),
                N("lo.vset", "Model", C("each")),
                N("ch.show", All(), J(C("each"), " is on the catwalk")),
                N("as.askq", T("tg1"), "ak2", J("Score ", C("each"), "'s outfit, 1 to 10"))),
            N("sg.next")) },
        -- (a judge on the catwalk doesn't score their own outfit)
        { id = "t4", st = "*", x = 444, y = 22, top = B:Stack(
            N("as.on", "ak2"),
            If(N("lo.not", N("pl.is", C("player"), V("Model"))), N("pt.add", C("answer"), "sc1", V("Model")))) },
        -- everyone votes for the best outfit: the most picked gets 5 more
        { id = "t5", st = "s4", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("as.ask", N("pl.all"), "ak3"),
            If(N("lo.set", N("as.top", "ak3")),
                N("pt.add", 5, "sc1", N("as.top", "ak3")),
                N("ch.show", All(), J(N("as.top", "ak3"), " wore it best"))),
            N("sg.next")) },
        { id = "t6", st = "s5", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            Podium("sc1", "gold", "silver", "bronze", { 30, 20, 10 }, J(N("pl.top", 1, "sc1"), " wins the transmog contest!"))) },
    }
    return d
end }

-- Trivia night: a list of questions, each asked to everyone with a typed answer; a right one adds to Right.
local QUESTIONS = {
    { "Which zone is Halaa in?", { "Nagrand" } },
    { "What's the highest level in The Burning Crusade?", { "70", "seventy" } },
    { "Who leads the Mag'har at Garadar?", { "Garrosh", "Garrosh Hellscream" } },
    { "Which boss drops the Ashes of Al'ar?", { "Kael'thas", "Kael'thas Sunstrider", "Kael", "Kaelthas" } },
    { "Who is the last boss of Karazhan?", { "Prince Malchezaar", "Malchezaar", "Malchezar" } },
    { "Which city do the Aldor and the Scryers share?", { "Shattrath", "Shattrath City" } },
    { "Which naaru leads the Sha'tar?", { "A'dal", "Adal" } },
    { "What do you fish up in Skettis that grants wishes?", { "Mr. Pinchy", "Mr Pinchy", "Pinchy" } },
    { "Which faction gives the Cenarion War Hippogryph?", { "Cenarion Expedition", "Cenarion" } },
    { "Which zone has the Ring of Blood?", { "Nagrand" } },
}
EX[7] = { key = "quiz", name = "Trivia night", icon = ICON .. "INV_Misc_Book_11", art = "kalimdor",
    desc = "A Questions list and a typed answer for each", make = function()
    local d = {
        name = "Trivia night", icon = ICON .. "INV_Misc_Book_11", art = "kalimdor",
        stages = { { id = "s1", name = "Sign-up" }, { id = "s2", name = "Quiz" }, { id = "s3", name = "Prizes" } },
        scores = { sc1 = { n = "Right", high = true, fmt = "num", board = true } },
        lists = { ls1 = { n = "Questions", kind = "question", items = {} } },
        asks = { ak1 = { n = "Answer", q = "", kind = "text", from = "entrants", votes = 1, self = false, time = 30,
                         secret = true } },
        vars = { { n = "Question", t = "text" } },
        badges = {
            gold = { n = "Know-it-all", i = ICON .. "INV_Misc_Book_11", f = "gold", ti = "the Wise" },
            silver = { n = "Runner-up", i = ICON .. "INV_Misc_Book_09", f = "silver" },
            bronze = { n = "Third place", i = ICON .. "INV_Misc_Note_02", f = "bronze" },
        },
        blocks = { b1 = Signup(40, false) },
        notes = {},
    }
    for _, q in ipairs(QUESTIONS) do d.lists.ls1.items[#d.lists.ls1.items + 1] = { q = q[1], a = Copy(q[2]), pts = 1 } end
    d.scripts = {
        CloseOrCancel("q1", 2, "Not enough players"),
        { id = "q2", st = "s2", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("ch.show", All(), J("Trivia night: 10 questions, 30 seconds each. Type your answers.")),
            N("tm.wait", 5),
            ForItems("ls1",
                N("lo.vset", "Question", C("item")),
                N("as.askq", N("pl.all"), "ak1", C("item")),
                N("tm.wait", 3)),
            N("sg.next")) },
        { id = "q3", st = "s2", x = 444, y = 22, top = B:Stack(
            N("as.on", "ak1"),
            If(N("lo.match", C("answer"), V("Question")),
                N("pt.add", 1, "sc1", C("player")),
                N("ch.tell", C("player"), J("Right!")))) },
        { id = "q4", st = "s3", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            Each(N("pl.all"), If(N("lo.gt", N("pt.get", C("each"), "sc1"), 0), N("pt.add", 5, SEASON, C("each")))),
            Podium("sc1", "gold", "silver", "bronze", { 30, 20, 10 }, J(N("pl.top", 1, "sc1"), " wins trivia night!"))) },
    }
    return d
end }

-- Red light, green light: a Light variable a timer flips; whoever starts moving on red is out; first to the line wins.
EX[8] = { key = "redlight", name = "Red light, green light", icon = ICON .. "Spell_ChargeNegative", art = "wsg",
    desc = "A Light that flips on a timer; move on red and you're out", make = function()
    local d = {
        name = "Red light, green light", icon = ICON .. "Spell_ChargeNegative", art = "wsg",
        stages = { { id = "s1", name = "Sign-up", desc = "Line up at the start line." }, { id = "s2", name = "Play" },
                   { id = "s3", name = "Prizes" } },
        tags = { tg1 = { n = "Playing", c = "blue", shown = "all" }, tg2 = { n = "Out", c = "red", shown = "all" },
                 tg3 = { n = "Made it", c = "green", shown = "all" } },
        scores = { sc1 = { n = "Finish", high = false, fmt = "time", board = true } },
        places = {
            pc1 = { n = "Start line", map = NAGRAND, x = 0.405, y = 0.44, r = 30, z = "Nagrand", sz = "Halaa" },
            pc2 = { n = "Finish line", map = NAGRAND, x = 0.43, y = 0.47, r = 25, z = "Nagrand", sz = "Halaa" },
        },
        vars = { { n = "Light", t = "text" } },
        badges = {
            gold = { n = "Green machine", i = ICON .. "Spell_ChargePositive", f = "gold", ti = "the Unstoppable" },
            silver = { n = "Runner-up", i = ICON .. "Spell_Nature_Slow", f = "silver" },
            bronze = { n = "Third place", i = ICON .. "Spell_ChargeNegative", f = "bronze" },
        },
        blocks = { b1 = Signup(30, false, "host") },
        notes = {},
    }
    local Out = function(why)
        return If(N("pl.has", C("player"), "tg1"),
            N("pl.untag", C("player"), "tg1"),
            N("pl.tag", C("player"), "tg2"),
            N("pc.unpoint", C("player")),
            N("ch.tell", C("player"), J(why)),
            N("ch.moment", J(C("player"), " moved on red")))
    end
    local meet, late = Gather("g1", "pc1", "Line up at the start line. The game starts when the host closes the sign-up.")
    d.scripts = {
        meet, late,
        CloseOrCancel("g2", 2, "Not enough players"),
        { id = "g3", st = "s2", x = 20, y = 160, top = B:Stack(
            N("ev.start"),
            N("pl.tag", All(), "tg1"),
            N("lo.vset", "Light", "green"),
            N("pc.point", N("pl.all"), "pc2"),
            N("ch.show", All(), J("Green light: go!")),
            N("tm.start", N("lo.rand", 5, 12), "Flip"),
            N("tm.start", 600, "Game"),
            N("tm.show", "Game")) },
        -- the light flips: red (after a second to stop), then green again
        { id = "g4", st = "s2", x = 444, y = 22, top = B:Stack(
            N("ev.timer", "Flip"),
            IfElse(N("lo.eq", V("Light"), "green"),
                B:Stack(
                    N("lo.vset", "Light", "turning"),
                    N("ch.show", All(), J("Red light! Stop!")),
                    N("ch.sound", "warning", T("tg1")),
                    N("tm.wait", 1),
                    N("lo.vset", "Light", "red"),
                    Each(T("tg1"), If(N("wo.is", C("each"), "moving"),
                        N("pl.untag", C("each"), "tg1"),
                        N("pl.tag", C("each"), "tg2"),
                        N("pc.unpoint", C("each")),
                        N("ch.tell", C("each"), J("You kept moving on red: you're out")),
                        N("ch.moment", J(C("each"), " kept moving on red")))),
                    N("tm.start", N("lo.rand", 3, 6), "Flip")),
                B:Stack(
                    N("lo.vset", "Light", "green"),
                    N("ch.show", All(), J("Green light: go!")),
                    N("tm.start", N("lo.rand", 4, 10), "Flip")))) },
        { id = "g5", st = "s2", x = 20, y = 330, top = B:Stack(
            N("ev.happen", "move"),
            If(N("lo.eq", V("Light"), "red"), Out("You moved on red: you're out"))) },
        { id = "g6", st = "s2", x = 444, y = 330, top = B:Stack(
            N("pc.enter", "pc2"),
            If(N("pl.has", C("player"), "tg1"),
                N("pl.untag", C("player"), "tg1"),
                N("pl.tag", C("player"), "tg3"),
                N("pt.set", "sc1", C("player"), N("tm.since", "Game")),
                N("pc.unpoint", C("player")),
                N("ch.moment", J(C("player"), " made it to the finish line")),
                N("ch.tell", C("player"), J("You made it! Place ", N("pt.place", C("player"), "sc1"))))) },
        { id = "g7", st = "s2", x = 444, y = 520, top = B:Stack(N("pl.notag", "tg1"), N("sg.next")) },
        { id = "g8", st = "s2", x = 20, y = 520, top = B:Stack(N("ev.timer", "Game"), N("sg.next")) },
        { id = "g9", st = "s3", x = 20, y = 22, top = B:Stack(
            N("ev.start"),
            N("pc.unpoint", N("pl.all")),
            Podium("sc1", "gold", "silver", "bronze", { 30, 20, 10 }, J(N("pl.top", 1, "sc1"), " wins red light, green light!"))) },
    }
    return d
end }

-- The examples, each a new copy: { { key, name, icon, art, desc, def } } in the list's order.
-- Where each example's scripts sit on the canvas (two columns a stage, none on top of another: measured in the
-- builder; a stage with a smart block's card has its scripts to the card's right).
local LAYOUT = {
    hide = { h1 = { 370, 22 }, h2 = { 20, 22 }, h3 = { 647, 22 }, h4 = { 20, 22 }, h5 = { 20, 22 }, h6 = { 588, 22 },
             h7 = { 20, 240 }, h8 = { 588, 268 }, h9 = { 588, 374 }, h10 = { 588, 480 }, h11 = { 20, 22 } },
    infect = { i1 = { 370, 22 }, i2 = { 20, 22 }, i3 = { 671, 22 }, i4 = { 20, 22 }, i5 = { 483, 22 }, i6 = { 20, 22 },
               i7 = { 20, 184 }, i8 = { 20, 290 }, i9 = { 20, 22 } },
    race = { r1 = { 370, 22 }, r1j = { 370, 156 }, r2 = { 370, 290 }, r3 = { 20, 22 }, r4 = { 521, 22 }, r5 = { 521, 199 },
             r6 = { 20, 339 }, r7 = { 521, 389 }, r8 = { 521, 495 }, r9 = { 20, 22 } },
    fish = { f1 = { 370, 22 }, f2 = { 20, 22 }, f3 = { 583, 22 }, f4 = { 583, 128 }, f5 = { 20, 184 }, f6 = { 583, 234 },
             f7 = { 20, 22 } },
    tmog = { t1 = { 370, 22 }, t2 = { 20, 22 }, t3 = { 20, 22 }, t4 = { 20, 22 }, t5 = { 20, 22 }, t6 = { 20, 22 } },
    quiz = { q1 = { 370, 22 }, q2 = { 20, 22 }, q3 = { 689, 22 }, q4 = { 20, 22 } },
    redlight = { g1 = { 370, 22 }, g1j = { 370, 156 }, g2 = { 370, 290 }, g3 = { 20, 22 }, g4 = { 487, 22 }, g5 = { 20, 296 },
                 g6 = { 20, 600 }, g7 = { 487, 645 }, g8 = { 487, 751 }, g9 = { 20, 22 } },
}

local function Make(e)
    local d = e.make()
    local at = LAYOUT[e.key]
    for _, s in ipairs(at and d.scripts or {}) do
        local p = at[s.id]
        if p then s.x, s.y = p[1], p[2] end
    end
    return d
end

function B:Examples()
    local out = {}
    for _, e in ipairs(EX) do
        out[#out + 1] = { key = e.key, name = e.name, icon = e.icon, art = e.art, desc = e.desc, def = Make(e) }
    end
    return out
end

-- One example's def by its key (nil: none).
function B:Example(key)
    for _, e in ipairs(EX) do
        if e.key == key then return Make(e) end
    end
    return nil
end

-- The starter event: the Friday duel cup (the first example).
function B:Starter() return Make(EX[1]) end

-- An empty event: the default stages and nothing in them.
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
    for id, b in pairs(d and type(d.blocks) == "table" and d.blocks or {}) do
        if type(b) == "table" and (not kind or b.kind == kind) then out[#out + 1] = id end
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
                if a.t == "timer" or (a.t == "since" and p.a[i] ~= "stage") then add(p.a[i]) end
            end
        end)
    end
    add("no-show")
    tsort(out)
    return out
end

-- Button labels used anywhere in the event (the label dropdown's choices).
function B:Labels(d)
    local seen, out = {}, {}
    for _, s in ipairs(d and d.scripts or {}) do
        self:Walk(s.top, function(p)
            local pd = P[p.k]
            for i, a in ipairs(pd and pd.args or {}) do
                local v = p.a[i]
                if a.t == "label" and type(v) == "string" and v ~= "" and not seen[v] then seen[v] = true; out[#out + 1] = v end
            end
        end)
    end
    tsort(out)
    return out
end

---------------------------------------------------------------------------
-- Migrate: part 1's pieces as these (an event made before, the demo data, another member's copy)
---------------------------------------------------------------------------

-- part 1's say: guild chat for Guild (and any channel it didn't know), else shown on everyone's screen
local SAY_SHOWN = { RAID = true, PARTY = true, SAY = true }
local OLD_HATS = { ["ev.duel"] = "duel", ["ev.off"] = "off", ["ev.on"] = "on", ["ev.ready"] = "ready" }
-- a hat's values that have new names: ctx renames in its script
local CTX_RENAMES = { duel = { winner = "player", loser = "other" }, ["bk.final"] = { finalist1 = "player1", finalist2 = "player2" } }
local STAT_ARG = { ["pt.add"] = 2, ["pt.set"] = 1, ["pt.get"] = 2, ["pl.top"] = 2 }

local function ScoreFor(d, name, made)
    if type(name) ~= "string" or name == "" or name == B.SEASON then return name end
    if type(d.scores) == "table" and d.scores[name] then return name end   -- a score's id already
    if name:find("^sc%d+$") then return name end                           -- one that is gone: the checks say so
    for id, sc in pairs(type(d.scores) == "table" and d.scores or {}) do
        if type(sc) == "table" and sc.n == name then return id end
    end
    local id = B:NewDefinition(d, "scores", { n = name, high = true, fmt = "num", board = false })
    if id then made.n = made.n + 1 end
    return id or name
end

-- Rewrites a def's old pieces in place (idempotent: a migrated def is left as it is). Returns true when it changed it.
function B:Migrate(d)
    if type(d) ~= "table" then return false end
    local changed = false
    local made = { n = 0 }
    local function migrate(s)
        local top = s and s.top
        if type(top) ~= "table" then return end
        -- the hat
        local renames
        if OLD_HATS[top.k] then
            local what = OLD_HATS[top.k]
            top.k, top.a = "ev.happen", { what }
            renames = CTX_RENAMES[what]
            changed = true
        elseif top.k == "bk.final" then
            renames = CTX_RENAMES["bk.final"]
        end
        self:Walk(top, function(p)
            local k = p.k
            local a = type(p.a) == "table" and p.a or {}   -- (read only: a piece left as it is isn't touched)
            if renames and k == "ctx" and renames[a[1]] then
                p.a = a
                a[1] = renames[a[1]]
                changed = true
            elseif k == "ch.say" then
                local text, ch = a[1], a[2]
                if SAY_SHOWN[ch] then p.k, p.a = "ch.show", { { k = "pl.all", a = {} }, text }
                else p.k, p.a = "ch.guild", { text } end
                changed = true
            elseif k == "ch.wh" then
                p.k, p.a = "ch.tell", a
                changed = true
            elseif k == "ch.rw" then
                p.k, p.a = "ch.show", { { k = "pl.all", a = {} }, a[1] }
                changed = true
            elseif k == "pt.vset" then
                p.k, p.a = "lo.vset", a
                changed = true
            end
            local si = STAT_ARG[p.k]
            if si and type(p.a) == "table" and type(p.a[si]) == "string" then
                local id = ScoreFor(d, p.a[si], made)
                if id ~= p.a[si] then p.a[si] = id; changed = true end
            end
        end)
    end
    for _, s in ipairs(type(d.scripts) == "table" and d.scripts or {}) do migrate(s) end
    for _, b in pairs(type(d.blocks) == "table" and d.blocks or {}) do
        if type(b) == "table" then
            for _, s in ipairs(type(b.inner) == "table" and b.inner or {}) do migrate(s) end
        end
    end
    return changed or made.n > 0
end

-- Migrated, with nothing to mutate when there is nothing old (the checks below call it on whatever they're given).
local function Fresh(d)
    if type(d) == "table" then B:Migrate(d) end
    return d
end

---------------------------------------------------------------------------
-- What an entrant's client must watch while the event runs (Core/EventSensors.lua)
---------------------------------------------------------------------------

-- { happen = { [what] = true }, places = { [pid] = true }, touch = { [how] = true }, radar, pos (positions: yards,
--   nearest, warmer), zone (zone / subzone), flags (flying / swimming / in combat), items = { [item] = true }, gold,
--   asks, buttons }. (Duels, ready and online come from part 1's paths, not from the sensors.)
local SENSED_BY_PART1 = { duel = true, lose = true, off = true, on = true, ready = true }
function B:Senses(d)
    Fresh(d)
    local s = { happen = {}, places = {}, touch = {}, radar = false, pos = false, zone = false, flags = false, items = {},
        gold = false, asks = false, buttons = false }
    local function allPlaces()
        for pid in pairs(type(d) == "table" and type(d.places) == "table" and d.places or {}) do s.places[pid] = true end
    end
    local function place(v)
        if type(v) == "string" and v ~= "" then s.places[v] = true
        elseif v ~= nil then allPlaces() end
    end
    self:EachScript(d, function(sc)
        self:Walk(sc.top, function(p)
            local k, a = p.k, p.a or {}
            if k == "ev.happen" then
                if self.HAPPEN_BY[a[1]] and not SENSED_BY_PART1[a[1]] then s.happen[a[1]] = true end
            elseif k == "pc.enter" or k == "pc.leave" then
                if a[1] == nil or a[1] == "" then allPlaces() else place(a[1]) end
            elseif k == "pc.in" or k == "pc.point" then
                place(a[2])
            elseif k == "pc.yards" or k == "pc.near" or k == "pc.warm" then
                s.pos = true
            elseif k == "pc.sub" or k == "pc.zone" then
                s.zone = true
            elseif k == "pl.touch" then
                if self.TOUCH_BY[a[3] or "click"] then s.touch[a[3] or "click"] = true end
            elseif k == "pl.radar" then
                s.radar = true
            elseif k == "wo.is" then
                local st = a[2] or "mounted"
                if st == "mounted" then s.happen.mount, s.happen.dismount = true, true
                elseif st == "moving" then s.happen.move, s.happen.stop = true, true
                elseif st == "dead" then s.happen.die = true; s.flags = true
                else s.flags = true end
            elseif k == "wo.items" then
                if a[1] ~= nil and type(a[1]) ~= "table" then s.items[a[1]] = true end
            elseif k == "wo.gold" then
                s.gold = true
            elseif k:find("^as%.") then
                if k == "as.give" or k == "as.take" or k == "as.press" then s.buttons = true else s.asks = true end
            end
        end)
    end)
    return s
end

---------------------------------------------------------------------------
-- Checks
---------------------------------------------------------------------------

-- The values a script's hat gives (and loops / asks inside it add). scope[name] = true. A timer carries what the
-- script that started it knew, so "when timer X runs out" also knows what every script starting X knows (list = the
-- scripts beside it: the event's, or a smart block's own).
function B:Scope(top, list)
    local scope = {}
    local d = top and P[top.k]
    if d and d.shape == "hat" then
        for _, g in ipairs(self:Gives(top)) do scope[g] = true end
    end
    if top and top.k == "ev.timer" and list then
        local name = top.a and top.a[1]
        local common
        for _, s in ipairs(list) do
            local hd = s.top and s.top ~= top and P[s.top.k]
            if hd and hd.shape == "hat" then
                self:Walk(s.top, function(p)
                    if (p.k == "tm.start" or p.k == "tm.startp") and p.a and p.a[2] == name then
                        local here = {}
                        for _, g in ipairs(self:Gives(s.top)) do here[g] = true end
                        if common then
                            for g in pairs(common) do if not here[g] then common[g] = nil end end
                        else
                            common = here
                        end
                    end
                end)
            end
        end
        for g in pairs(common or {}) do scope[g] = true end
    end
    return scope
end

local NEED = { player = true, players = true, bool = true, stage = true, var = true, badge = true, block = true,
    num = true, timer = true, tag = true, score = true, place = true, where = true, list = true, ask = true, label = true,
    what = true, how = true, sound = true, state = true, item = true, since = true }
local NEED_WORDS = { player = "a player", players = "players", bool = "a yes / no piece", stage = "a stage",
    block = "a smart block", badge = "a badge", var = "a variable", num = "a number", tag = "a tag", score = "a score",
    place = "a place", where = "a place or a player", list = "a list", ask = "an ask", label = "the button's name",
    what = "what happens", how = "how", sound = "a sound", state = "a choice", item = "an item", since = "a timer" }
local GONE_WORDS = { tag = "That tag is gone.", score = "That score is gone.", place = "That place is gone.",
    list = "That list is gone.", ask = "That ask is gone." }
-- pieces that walk a list: an empty one has nothing to walk
local WALKS = { ["lo.lfor"] = 1, ["lo.litem"] = 2, ["lo.lrand"] = 1, ["lo.lnext"] = 2, ["lo.lmine"] = 2, ["lo.lpos"] = 2,
    ["lo.lend"] = 1 }
local TAGS_GIVEN = { ["pl.tag"] = { 2 }, ["pl.untag"] = { 2 }, ["pl.split"] = { 2, 3 } }

-- Every problem in the event: { script = scriptId | nil, piece = piece, slot = n, text } (in script order). A problem
-- stops hosting: the piece would not know what to do. (Pieces with nothing on top never run; not a problem.)
function B:Problems(d, opts)
    local out = {}
    if type(d) ~= "table" then return out end
    Fresh(d)
    local function add(sid, p, slot, text) out[#out + 1] = { script = sid, piece = p, slot = slot, text = text } end
    local stagesById = {}
    for _, s in ipairs(d.stages or {}) do stagesById[s.id] = true end
    local function check(sid, top, inner, list)
        local scope = self:Scope(top, list)
        self:Walk(top, function(p)
            local pd = P[p.k]
            if not pd then add(sid, p, nil, "This piece is from a newer version of DisasterZone."); return end
            if pd.gives and pd.shape ~= "hat" then for _, g in ipairs(pd.gives) do scope[g] = true end end
            if pd.inner and pd.inner ~= inner then add(sid, p, nil, "This piece only works inside its smart block.") end
            for i, a in ipairs(pd.args or {}) do
                local v = p.a and p.a[i]
                local t = self:ArgType(p, i)
                local empty = v == nil or v == "" and t ~= "text"
                if t == nil then
                    -- a "filter" blank its choice doesn't have: not there
                elseif empty and NEED[t] and not a.opt then
                    add(sid, p, i, "Needs " .. (NEED_WORDS[t] or "a value") .. " here.")
                elseif t == "stage" and v and not stagesById[v] then
                    add(sid, p, i, "That stage is gone.")
                elseif t == "block" and v and not (d.blocks and d.blocks[v] and d.blocks[v].kind == a.kind) then
                    add(sid, p, i, "That smart block is gone.")
                elseif t == "badge" and v and not (d.badges and d.badges[v]) then
                    add(sid, p, i, "That badge is gone.")
                elseif t == "var" and v and not self:Var(d, v) then
                    add(sid, p, i, "That variable is gone.")
                elseif GONE_WORDS[t] and type(v) == "string" and v ~= "" and not self:Definition(d, DEF_OF_TYPE[t], v) then
                    add(sid, p, i, GONE_WORDS[t])
                elseif t == "where" and type(v) == "string" and v ~= "" and not self:Definition(d, "places", v) then
                    add(sid, p, i, GONE_WORDS.place)
                elseif t == "what" and type(v) == "string" and not self.HAPPEN_BY[v] then
                    add(sid, p, i, "That choice is from a newer version of DisasterZone.")
                elseif t == "how" and type(v) == "string" and not self.TOUCH_BY[v] then
                    add(sid, p, i, "That choice is from a newer version of DisasterZone.")
                elseif t == "label" and type(v) == "string" and not v:find("%S") then
                    add(sid, p, i, "Needs the button's name here.")
                end
            end
            -- definitions that can't do what the piece asks
            local walks = WALKS[p.k]
            local lid = walks and p.a and p.a[walks]
            local list = type(lid) == "string" and self:Definition(d, "lists", lid)
            if list and (type(list.items) ~= "table" or #list.items == 0) then
                add(sid, p, walks, "That list is empty.")
            end
            for _, i in ipairs(TAGS_GIVEN[p.k] or {}) do
                if p.a and p.a[i] == self.ENTRANTS then
                    add(sid, p, i, "Everyone in the event has Entrants: it can't be given or taken.")
                end
            end
            if p.k == "as.ask" or p.k == "as.askq" then
                local ask = type(p.a and p.a[2]) == "string" and self:Definition(d, "asks", p.a[2])
                if ask and p.k == "as.ask" and not (type(ask.q) == "string" and ask.q:find("%S")) then
                    add(sid, p, 2, "This ask has no question: type one in the ask, or use \"ask ... with\".")
                elseif p.k == "as.askq" and (p.a[3] == nil or p.a[3] == "") then
                    add(sid, p, 3, "Needs the question here.")
                end
                if ask and ask.kind == "choice" and not (type(ask.choices) == "table" and #ask.choices > 0) then
                    add(sid, p, 2, "That ask has no choices to pick from.")
                end
            end
            -- (a place set by its subzone alone still knows who is in it, not where it is)
            if p.k == "pc.point" or p.k == "pc.yards" or p.k == "pc.warm" then
                local pid = p.a and p.a[2]
                local pl = type(pid) == "string" and self:Definition(d, "places", pid)
                if pl and not (tonumber(pl.map) and tonumber(pl.x) and tonumber(pl.y)) then
                    add(sid, p, 2, "That place isn't on a map yet.")
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
    -- a script's top piece from a newer version: it may be a "when" piece this version can't run
    local function newer(sid, top)
        if type(top) == "table" and top.k and not P[top.k] then
            add(sid, top, nil, "This piece is from a newer version of DisasterZone.")
        end
    end
    for _, s in ipairs(d.scripts or {}) do
        local hd = s.top and P[s.top.k]
        if hd and hd.shape == "hat" then check(s.id, s.top, nil, d.scripts) end
        newer(s.id, s.top)
        if s.st ~= "*" and not stagesById[s.st] then add(s.id, s.top, nil, "This script's stage is gone.") end
    end
    for _, bid in ipairs(self:BlocksOf(d)) do
        local b = d.blocks[bid]
        for _, s in ipairs(b.inner or {}) do
            local hd = s.top and P[s.top.k]
            if hd and hd.shape == "hat" then
                check(bid .. "/" .. s.id, s.top, b.kind, b.inner)
                -- inside, only the block's own "when" pieces (and timers) ever run
                if hd.inner ~= b.kind and s.top.k ~= "ev.timer" and s.top.k ~= "ev.every" then
                    add(bid .. "/" .. s.id, s.top, nil, "This piece only works outside the smart block.")
                end
            end
            newer(bid .. "/" .. s.id, s.top)
        end
        if not stagesById[b.stage] then add(nil, nil, nil, "The stage of " .. self:BlockLabel(d, bid) .. " is gone.") end
    end
    -- a list of places naming one that's gone
    for _, l in ipairs(self:Defs(d, "lists", true)) do
        if l.kind == "place" then
            for _, it in ipairs(type(l.items) == "table" and l.items or {}) do
                if not self:Definition(d, "places", it) then
                    add(nil, nil, nil, "The list " .. tostring(l.n) .. " has a place that's gone.")
                    break
                end
            end
        end
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

local function names(list)
    if #list == 0 then return "" end
    if #list == 1 then return list[1] end
    return tconcat(list, ", ", 1, #list - 1) .. " and " .. list[#list]
end

local SCORE_WAY = { num = { "most", "fewest" }, time = { "longest", "fastest" }, gold = { "most", "least" } }
local ASK_WORDS = { player = "A vote.", choice = "A vote.", text = "Questions to answer.", yesno = "A yes or no question.",
    number = "Scores from 1 to 10." }
local ASK_RULE = { player = "a vote", choice = "a vote", text = "typed answers", yesno = "a yes or no", number = "scores 1 to 10" }
local HAPPEN_RULE = { kill = "kills count", loot = "loot counts", fish = "every fish counts", die = "don't die",
    dismount = "stay mounted", move = "don't move", emote = "emotes count" }

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
                local pieces = self:SmartSetting(b, "win") == "pieces"
                if pieces then rule("swords", "1 v 1 matches") else rule("swords", "best of " .. bo) end
                rule("clock", self:DurationText(self:SmartSetting(b, "noshow")) .. " no-show")
                rule("rank", "seeded by " .. strlower(settingLabel("bracket", "seed", seed)))
                if pieces then
                    words[#words + 1] = fmt .. ", seeded by " .. strlower(settingLabel("bracket", "seed", seed))
                        .. ". The event's rules decide each match."
                else
                    words[#words + 1] = fmt .. ", best of " .. bo .. (fbo ~= bo and (", the final best of " .. fbo) or "")
                        .. ", seeded by " .. strlower(settingLabel("bracket", "seed", seed)) .. "."
                end
            end
        end
    end
    local badges, season, show, post, count = 0, false, false, false, false
    local tags, tagSeen, scores, scoreSeen = {}, {}, {}, {}
    local asks, places, buttons, timers, askWords, walks = {}, {}, {}, {}, {}, {}
    local once = {}
    local function add(list, v) if not once[v] then once[v] = true; list[#list + 1] = v end end
    for _, s in ipairs(d.scripts or {}) do
        if s.st == stage.id then
            if s.top and s.top.k == "ev.happen" and HAPPEN_RULE[s.top.a and s.top.a[1]] then
                rule("swords", HAPPEN_RULE[s.top.a[1]])
            end
            self:Walk(s.top, function(p)
                local a = p.a or {}
                if p.k == "pt.badge" then badges = badges + 1
                elseif p.k == "pt.add" and a[2] == self.SEASON then season = true
                elseif p.k == "ch.show" then show = true
                elseif p.k == "ch.guild" then post = true
                elseif p.k == "tm.count" then count = true
                elseif (p.k == "pl.tag" or p.k == "pl.split") then
                    for i = 2, (p.k == "pl.split") and 3 or 2 do
                        local tid = a[i]
                        local tg = type(tid) == "string" and tid ~= self.ENTRANTS and self:Definition(d, "tags", tid)
                        if tg and not tagSeen[tid] then tagSeen[tid] = true; tags[#tags + 1] = tg.n end
                    end
                elseif (p.k == "pt.add" or p.k == "pt.set") then
                    local sid = p.k == "pt.add" and a[2] or a[1]
                    local sc = type(sid) == "string" and sid ~= self.SEASON and self:Definition(d, "scores", sid)
                    if sc and sc.board and not scoreSeen[sid] then
                        scoreSeen[sid] = true
                        local way = SCORE_WAY[sc.fmt] or SCORE_WAY.num
                        scores[#scores + 1] = way[sc.high == false and 2 or 1] .. " " .. sc.n .. " wins"
                    end
                elseif p.k == "as.ask" or p.k == "as.askq" then
                    local ak = type(a[2]) == "string" and self:Definition(d, "asks", a[2])
                    if ak and ASK_RULE[ak.kind] then
                        asks[#asks + 1] = ASK_RULE[ak.kind]
                        askWords[#askWords + 1] = ASK_WORDS[ak.kind]
                    end
                elseif p.k == "pc.enter" or p.k == "pc.leave" or p.k == "pc.point" then
                    local pid = p.k == "pc.point" and a[2] or a[1]
                    local pl = type(pid) == "string" and self:Definition(d, "places", pid)
                    if pl then add(places, pl.n) end
                elseif p.k == "as.give" and type(a[2]) == "string" and a[2] ~= "" then
                    add(buttons, "a " .. a[2] .. " button")
                elseif p.k == "lo.lnext" or p.k == "lo.lfor" then
                    -- a list walked or gone through: "Route: 8 places", "Questions: 10"
                    local lid = p.k == "lo.lnext" and a[2] or a[1]
                    local l = type(lid) == "string" and self:Definition(d, "lists", lid)
                    local n = l and type(l.items) == "table" and #l.items or 0
                    if l and n > 0 then
                        add(walks, l.n .. ": " .. n .. (l.kind == "place" and (n == 1 and " place" or " places") or ""))
                    end
                elseif p.k == "tm.start" and type(a[1]) == "number" and a[1] >= 60 then
                    timers[#timers + 1] = self:DurationText(a[1])
                end
            end)
        end
    end
    if #tags > 0 then rule("group", names(tags)) end
    for _, t in ipairs(scores) do rule("rank", t) end
    for _, t in ipairs(asks) do rule("eyeo", t) end
    for _, t in ipairs(walks) do rule("eyeo", t) end
    for _, name in ipairs(places) do rule("eyeo", name) end
    for _, t in ipairs(buttons) do rule("eyeo", t) end
    for _, t in ipairs(timers) do rule("clock", t) end
    if badges > 0 then rule("trophy", badges == 1 and "a badge" or (badges .. " badges")) end
    if season then rule("rank", "season points") end
    if count then rule("clock", "countdown") end
    if #tags > 0 then words[#words + 1] = "Tags: " .. names(tags) .. "." end
    if #scores > 0 then words[#words + 1] = (scores[1]:gsub("^%l", strupper)) .. "." end
    if askWords[1] then words[#words + 1] = askWords[1] end
    if badges > 0 then words[#words + 1] = "Badges" .. (season and " and season points" or "") .. " are given out." end
    if post then words[#words + 1] = "The winner is posted to guild chat." end
    local text = stage.desc
    if not text or text == "" then text = tconcat(words, " ") end
    return { id = stage.id, name = stage.name, text = text, rules = rules }
end

function B:Describe(d, opts)
    Fresh(d)
    local out = {}
    for _, s in ipairs(d and d.stages or {}) do out[#out + 1] = self:DescribeStage(d, s, opts) end
    return out
end

-- The kind of event, from its smart blocks ("bracket", "signup"...): the library card's chips. all: also the
-- definitions it has ("tags", "scores", "places", "lists", "asks"; B:KindLabel names them).
B.KIND_LABEL = { signup = "Sign-up", bracket = "Matches", tags = "Tags", scores = "Scores", places = "Places",
    lists = "Lists", asks = "Asks" }
function B:Kinds(d, all)
    Fresh(d)
    local kinds = {}
    for _, k in ipairs(self.SMART_ORDER) do
        if #self:BlocksOf(d, k) > 0 then kinds[#kinds + 1] = k end
    end
    if all then
        for _, k in ipairs(self.DEF_ORDER) do
            if #self:Defs(d, k, true) > 0 then kinds[#kinds + 1] = k end
        end
    end
    return kinds
end

function B:KindLabel(k) return self.KIND_LABEL[k] or tostring(k) end

-- The badges an event can give, in their def order (sorted by name).
function B:BadgeList(d)
    local out = {}
    for id, bd in pairs(d and d.badges or {}) do out[#out + 1] = { id = id, b = bd } end
    tsort(out, function(x, y) return (x.b.n or "") < (y.b.n or "") end)
    return out
end

-- Season points an event can hand one player at most (the review's check): the biggest "add n Season points" sum on
-- any one path is hard to know, so this is the largest typed grant (add or set, taken or given, the smart blocks' own
-- pieces too). Good enough to spot a typo of 5000. A grant worked out while the event runs (a value piece) is held to
-- SEASON_CAP by the engine.
function B:MaxSeasonGrant(d)
    Fresh(d)
    local top = 0
    self:EachScript(d, function(s)
        self:Walk(s.top, function(p)
            local n
            if p.k == "pt.add" and p.a and p.a[2] == self.SEASON then n = p.a[1]
            elseif p.k == "pt.set" and p.a and p.a[1] == self.SEASON then n = p.a[3] end
            if type(n) == "number" and math.abs(n) > top then top = math.abs(n) end
        end)
    end)
    return top
end

B.SEASON_CAP = 100   -- one grant of more than this is refused by the review check (and held to it in a run)

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

-- The words a typed or picked blank shows (a definition's name, a choice's words), nil for a value piece.
function B:BlankWords(d, p, i)
    local v = p and p.a and p.a[i]
    if v == nil then return nil end
    if type(v) == "table" then return nil end
    local t = self:ArgType(p, i)
    if t == "block" and d and d.blocks and d.blocks[v] then return self:BlockLabel(d, v) end
    if t == "stage" then return self:StageName(d, v) end
    if t == "badge" then return d and d.badges and d.badges[v] and d.badges[v].n or tostring(v) end
    if DEF_OF_TYPE[t] then return self:DefinitionName(d, DEF_OF_TYPE[t], v) end
    if t == "where" then return self:DefinitionName(d, "places", v) end
    if t == "what" then local h = self.HAPPEN_BY[v]; return h and h.label or tostring(v) end
    if t == "how" then local h = self.TOUCH_BY[v]; return h and h.label or tostring(v) end
    if t == "sound" then local s = self.SOUND_BY[v]; return s and s[2] or tostring(v) end
    if t == "state" then return choiceLabel(self.STATES, v) end
    if t == "since" then return v == "stage" and "this stage started" or tostring(v) end
    if t == "dur" then return self:DurationText(v) end
    if t == "marker" then return choiceLabel(self.MARKERS, tonumber(v)) end
    if t == "channel" then return choiceLabel(self.CHANNELS, v) end
    if t == "ctxname" then local c = self.CTX[v]; return c and c.label or tostring(v) end
    return tostring(v)
end

-- A piece's words with its typed blanks filled in ("when Matches match starts"): a change the diff can't draw.
local function Words(d, p)
    local pd = type(p) == "table" and P[p.k]
    if not pd then return "?" end
    return ((pd.text:gsub("{(%d)}", function(i)
        i = tonumber(i)
        local pa = pd.args and pd.args[i]
        if pa and pa.t == "filter" and B:ArgType(p, i) == nil then return "" end
        return B:BlankWords(d, p, i) or "..."
    end)):gsub("%s+$", ""))
end
B.Words = function(_, d, p) return Words(d, p) end

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

-- A definition's own fields (for the diff): a stable text of them.
local function DefSig(x)
    if type(x) ~= "table" then return tostring(x) end
    local keys = {}
    for k in pairs(x) do keys[#keys + 1] = tostring(k) end
    tsort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = x[k]
        parts[#parts + 1] = k .. "=" .. (type(v) == "table" and ("{" .. DefSig(v) .. "}") or tostring(v))
    end
    return tconcat(parts, ",")
end

-- The changes from `old` to `new`: { { kind = "add" | "del" | "chg", stage = name, piece = piece | nil, text } ... }
-- and how many pieces are the same.
function B:Diff(old, new)
    local out, same = {}, 0
    if not (old and new) then return out, 0 end
    Fresh(old)
    Fresh(new)
    local function stageOf(d, sid) return self:StageName(d, sid) end
    local byId = {}
    for _, s in ipairs(old.scripts or {}) do byId[s.id] = s end
    local seen = {}
    for _, s in ipairs(new.scripts or {}) do
        local o = byId[s.id]
        seen[s.id] = true
        if o and (o.st or "*") ~= (s.st or "*") then
            -- the same pieces, run in another stage
            out[#out + 1] = { kind = "chg", stage = stageOf(new, s.st), text = "Moved here from " .. stageOf(old, o.st) .. ": "
                .. Words(new, s.top) }
        end
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
                    out[#out + 1] = { kind = "chg", stage = stageOf(new, b.stage), text = (sm.label .. ": " .. strlower(opt.label)
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
    for id, bd in pairs(old.badges or {}) do
        if not (new.badges and new.badges[id]) then
            out[#out + 1] = { kind = "del", text = "Badge taken out: " .. (bd.n or "?"), badge = bd }
        end
    end
    -- definitions: new, taken out, changed (a list's items, a place's spot, an ask's question...)
    for _, kind in ipairs(self.DEF_ORDER) do
        local label = self.DEF_KINDS[kind].label
        local Label = label:gsub("^%l", strupper)
        local was = type(old[kind]) == "table" and old[kind] or {}
        local now = type(new[kind]) == "table" and new[kind] or {}
        for _, x in ipairs(self:Defs(new, kind, true)) do
            local o = was[x.id]
            if not o then
                out[#out + 1] = { kind = "add", text = "New " .. label .. ": " .. tostring(x.n), def = kind, id = x.id }
            elseif DefSig(o) ~= DefSig(now[x.id]) then
                out[#out + 1] = { kind = "chg", text = Label .. ": " .. tostring(x.n)
                    .. ((o.n ~= x.n) and (" (was " .. tostring(o.n) .. ")") or ""), def = kind, id = x.id }
            end
        end
        for _, x in ipairs(self:Defs(old, kind, true)) do
            if not now[x.id] then
                out[#out + 1] = { kind = "del", text = Label .. " taken out: " .. tostring(x.n), def = kind, id = x.id }
            end
        end
    end
    -- stages: new, taken out, renamed, in another order (the event goes through them in order)
    local was, kept = {}, {}
    for _, s in ipairs(old.stages or {}) do was[s.id] = s end
    for _, s in ipairs(new.stages or {}) do
        local o = was[s.id]
        if not o then
            out[#out + 1] = { kind = "add", stage = s.name, text = "New stage" }
        else
            kept[#kept + 1] = s.id
            if o.name ~= s.name then
                out[#out + 1] = { kind = "chg", stage = s.name, text = "Stage renamed (was " .. tostring(o.name) .. ")" }
            end
        end
    end
    local k = 0
    for _, s in ipairs(old.stages or {}) do
        if not self:Stage(new, s.id) then
            out[#out + 1] = { kind = "del", stage = s.name, text = "Stage taken out" }
        else
            k = k + 1
            if kept[k] ~= s.id then kept.moved = true end
        end
    end
    if kept.moved then out[#out + 1] = { kind = "chg", text = "The stages are in a new order" } end
    return out, same
end

function B:OnInit() end
