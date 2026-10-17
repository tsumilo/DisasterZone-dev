if DisasterZoneBoot and DisasterZoneBoot.Run("Core/RecruitMessage.lua", ...) then return end -- DisasterZone: Core/RecruitMessage.lua
-- Recruitment > Message (1.6): the guild's recruitment message, built by the officers from parts (like the LFG
-- message), and where it goes.
--   Parts, in their order, each on or off: the officers' own words, and helpers that only fill in facts: the guild's
--   name, the classes a team's comp still needs (one team or every team; as specs, short names or classes; any of them
--   left out),
--   a team's raid nights, a raid icon ({rt1}: chat draws it). Nothing is written for them: the message starts empty. The parts are joined with a space
--   (or " - ", ", ", " / "); one chat line, 255 bytes at most.
--   Places: Say, Yell, or a chat channel by name (Trade, LookingForGroup, GuildRecruitment, General, LocalDefense, or
--   any channel I'm in), each with its own interval (30 seconds to 12 hours) and an optional "major cities only" tick.
-- Posting needs a click or a key (the game sends to channels, Say and Yell only inside a hardware event): Post now
-- sends it to every place that's on (and allowed where I stand); with Reminders on, a place that is due (its interval
-- since the last post there, by any officer) brings a toast whose click posts to every place that is due; the bound
-- key (Key Bindings > AddOns) does the same. Posts are told to the recruiters online (RCP, with the place), so
-- officers take turns per place instead of posting twice.
-- Saved (per guild): db.recruitMsg[guildKey] = { v = 3, parts = { { id, k = "text" | "tag" | "need" | "nights" |
-- "icon", t, team, by = "spec" | "short" | "class", m (an icon part's raid icon 1..8), skip = { [entry] = true }, off },
-- ... }, nid, sep, rep, places = { { id, kind = "SAY" | "YELL" | "CHANNEL", name, every = seconds, u = "s" | "m", on,
-- city }, ... }, posts = { [place id] = { at, ... } } }.
-- Saved messages (1.5.5, feedback #51): msgs = { { id, name, parts, sep }, ... } in the order made, cur = the id in
-- use. The one in use keeps its parts and separator at the top (parts, sep: everything above works on those); the
-- others hold their own (parts, sep) until they're put in use. Places and posts belong to the guild, not a message.
local addonName, ns = ...

local Msg = ns:NewModule("RecruitMessage")
local Util = ns.Util

local floor, max, min = math.floor, math.max, math.min
local tconcat, tsort = table.concat, table.sort

local MAX_LEN = 255
local MAX_PLACES = 12
local MAX_PARTS = 24
local MAX_WORDS = 200
local MAX_MESSAGES, MAX_NAME = 8, 24
local MIN_EVERY, MAX_EVERY = 30, 12 * 3600   -- seconds
local DAY = 86400
Msg.MAX_LEN = MAX_LEN
Msg.MAX_PARTS = MAX_PARTS
Msg.MAX_MESSAGES, Msg.MAX_NAME = MAX_MESSAGES, MAX_NAME
Msg.MIN_EVERY, Msg.MAX_EVERY = MIN_EVERY, MAX_EVERY

-- What joins the parts.
Msg.SEPS = { { key = " ", label = "Space" }, { key = " - ", label = "-" }, { key = ", ", label = "," },
             { key = " / ", label = "/" } }
local SEP_OK = {}
for _, s in ipairs(Msg.SEPS) do SEP_OK[s.key] = true end

-- The kinds of parts, for the "+ Add" menu and the chips.
Msg.KINDS = {
    text = { label = "Your words", tip = "Anything you want to say, in your own words." },
    tag = { label = "Guild name", tip = "The guild's name in < >." },
    need = { label = "Classes we need", tip = "What a team's comp still has open: specs or classes, filled in as the "
        .. "comp changes. Leave any of them out." },
    nights = { label = "Raid nights", tip = "A team's raid nights and their start time, e.g. Thu + Sun 19:30." },
    icon = { label = "Raid icon", tip = "A raid target icon (star, skull...): the game shows it in chat." },
}

-- The raid target icons, as chat writes them: {rt1} .. {rt8} (5 bytes, any client language; {star} etc. work too).
Msg.ICONS = { { m = 1, name = "Star" }, { m = 2, name = "Circle" }, { m = 3, name = "Diamond" },
              { m = 4, name = "Triangle" }, { m = 5, name = "Moon" }, { m = 6, name = "Square" },
              { m = 7, name = "Cross" }, { m = 8, name = "Skull" } }
local ICON_BY_NAME = { x = 7, rt1 = 1, rt2 = 2, rt3 = 3, rt4 = 4, rt5 = 5, rt6 = 6, rt7 = 7, rt8 = 8 }
for _, i in ipairs(Msg.ICONS) do ICON_BY_NAME[i.name:lower()] = i.m end

function Msg:IconTexture(m) return "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. m end
function Msg:IconCode(m) return "{rt" .. m .. "}" end

-- The text as chat shows it: the icon codes ({rt1}, {star}, ...) drawn as the icons (size: the icons' height).
function Msg:Render(text, size)
    if not text then return text end
    size = size or 14
    return (text:gsub("{([%w]+)}", function(word)
        local m = ICON_BY_NAME[word:lower()]
        return m and ("|T" .. self:IconTexture(m) .. ":" .. size .. ":" .. size .. "|t") or nil
    end))
end

-- The places offered in "Add a place" (custom channels I'm in are added to the menu as they are).
Msg.SUGGESTED = {
    { kind = "CHANNEL", name = "Trade" }, { kind = "CHANNEL", name = "LookingForGroup" },
    { kind = "CHANNEL", name = "GuildRecruitment" }, { kind = "CHANNEL", name = "General" },
    { kind = "CHANNEL", name = "LocalDefense" }, { kind = "YELL", name = "Yell" }, { kind = "SAY", name = "Say" },
}

-- The capitals (uiMapID, and the zone name as a fallback): Stormwind, Ironforge, Darnassus, The Exodar, Orgrimmar,
-- Thunder Bluff, Undercity, Silvermoon, Shattrath.
local CITY_MAPS = { [1453] = true, [1455] = true, [1457] = true, [1947] = true, [1454] = true, [1456] = true,
                    [1458] = true, [1954] = true, [1955] = true }
local CITY_NAMES = { ["Stormwind City"] = true, ["Ironforge"] = true, ["Darnassus"] = true, ["The Exodar"] = true,
                     ["Orgrimmar"] = true, ["Thunder Bluff"] = true, ["Undercity"] = true, ["Silvermoon City"] = true,
                     ["Shattrath City"] = true }

local DAY_SHORT = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

-- "Short": the names chat uses, to save the budget (by spec, in ns.SPECS order; a class alone).
Msg.SHORT_SPEC = {
    WARRIOR = { "Arms War", "Fury War", "Prot War" }, PALADIN = { "Holy Pala", "Prot Pala", "Ret Pala" },
    HUNTER = { "BM Hunter", "MM Hunter", "Surv Hunter" }, ROGUE = { "Assa Rogue", "Combat Rogue", "Sub Rogue" },
    PRIEST = { "Disc Priest", "Holy Priest", "Shadow Priest" }, SHAMAN = { "Ele Sham", "Enh Sham", "Resto Sham" },
    MAGE = { "Arcane Mage", "Fire Mage", "Frost Mage" }, WARLOCK = { "Affli Lock", "Demo Lock", "Destro Lock" },
    DRUID = { "Boomkin", "Cat Druid", "Bear Druid", "Resto Druid" },
}
Msg.SHORT_CLASS = { WARRIOR = "War", PALADIN = "Pala", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
                    SHAMAN = "Sham", MAGE = "Mage", WARLOCK = "Lock", DRUID = "Druid" }

local function R() return ns.Recruit end
local Now = Util.Now

local function PlaceId(kind, name) return kind == "CHANNEL" and ("ch:" .. tostring(name):lower()) or kind:lower() end

local function DefaultPlaces()
    return { { id = "ch:trade", kind = "CHANNEL", name = "Trade", every = 3600, u = "m", on = true, city = true },
             { id = "ch:guildrecruitment", kind = "CHANNEL", name = "GuildRecruitment", every = 3600, u = "m", on = true,
               city = true } }
end

local function Words(s)
    s = tostring(s or ""):gsub("[\r\n]+", " "):gsub("[%c|]", "")
    return s:sub(1, MAX_WORDS)
end

local demoStore
local function DemoStore()
    local now = Now()
    return { v = 3, nid = 8, sep = " ",
        parts = { { id = 8, k = "icon", m = 8 }, { id = 1, k = "tag" }, { id = 2, k = "text", t = "chill guild for new, returning and raiding players." },
                  { id = 3, k = "text", t = "SSC/TK on" }, { id = 4, k = "nights", team = "demo-main" },
                  { id = 5, k = "text", t = "- looking for" }, { id = 6, k = "need", team = "demo-main", by = "spec" },
                  { id = 7, k = "text", t = "/w me for a chat!" } },
        cur = 1, mid = 3,
        msgs = { { id = 1, name = "Raiders for SSC/TK" },
                 { id = 2, name = "Levellers welcome", sep = " ",
                   parts = { { id = 9, k = "tag" }, { id = 10, k = "text", t = "is a friendly guild for levellers and returning players." },
                             { id = 11, k = "text", t = "Dungeon groups most nights, help with quests. /w me!" } } },
                 { id = 3, name = "Weekend pugs", sep = " - ",
                   parts = { { id = 12, k = "icon", m = 1 }, { id = 13, k = "text", t = "Karazhan pug Sunday" },
                             { id = 14, k = "nights", team = "demo-main" }, { id = 15, k = "text", t = "/w for a spot" } } } },
        places = { { id = "ch:trade", kind = "CHANNEL", name = "Trade", every = 3600, u = "m", on = true, city = true },
                   { id = "ch:guildrecruitment", kind = "CHANNEL", name = "GuildRecruitment", every = 1800, u = "m",
                     on = true, city = true },
                   { id = "yell", kind = "YELL", name = "Yell", every = 90, u = "s", on = false, city = true } },
        posts = { ["ch:trade"] = { now - 2400, now - 2 * DAY - 1800 }, ["ch:guildrecruitment"] = { now - 4 * DAY - 600 } } }
end

local function DB()
    local d
    if Util.DemoOn() then
        demoStore = demoStore or DemoStore()
        d = demoStore
    else
        d = ns.DB:GuildBucket("recruitMsg", true) or {}
    end
    if d.v == 2 then                       -- (1.6 beta: one text, minutes) -> parts, seconds
        local text = Util.Trim(Words(d.text)) or ""
        d.parts = text ~= "" and { { id = 1, k = "text", t = text } } or {}
        d.nid = #d.parts
        d.text = nil
        for _, p in ipairs(type(d.places) == "table" and d.places or {}) do
            p.every, p.u = (tonumber(p.every) or 60) * 60, "m"
        end
        d.v = 3
    elseif d.v ~= 3 then                   -- (the first, block-built message: started over)
        for k in pairs(d) do d[k] = nil end
        d.v = 3
    end
    if type(d.parts) ~= "table" then d.parts = {} end
    if type(d.nid) ~= "number" then d.nid = 0 end
    if not SEP_OK[d.sep] then d.sep = " " end
    if type(d.places) ~= "table" then d.places = DefaultPlaces() end
    if type(d.posts) ~= "table" then d.posts = {} end
    -- (saved messages: the one there was before is the first)
    if type(d.msgs) ~= "table" or #d.msgs == 0 then d.msgs, d.cur, d.mid = { { id = 1, name = "Message 1" } }, 1, 1 end
    if type(d.mid) ~= "number" then d.mid = #d.msgs end
    local found = false
    for _, m in ipairs(d.msgs) do if m.id == d.cur then found = true end end
    if not found then d.cur = d.msgs[1].id; d.msgs[1].parts, d.msgs[1].sep = nil, nil end
    return d
end

---------------------------------------------------------------------------
-- Saved messages (feedback #51): several, one in use
---------------------------------------------------------------------------

local function Named(s)
    s = Util.Trim(Words(s)) or ""
    if #s > MAX_NAME then s = s:sub(1, MAX_NAME) end
    return s ~= "" and s or nil
end

local function FindMsg(d, id)
    for i, m in ipairs(d.msgs) do if m.id == id then return m, i end end
end

-- The saved messages in their order: { { id, name, cur (in use), n (parts), text (what it says now) }, ... }.
function Msg:GetMessages()
    local d = DB()
    local out = {}
    for _, m in ipairs(d.msgs) do
        local cur = m.id == d.cur
        local parts = cur and d.parts or m.parts or {}
        local bits = {}
        for _, p in ipairs(parts) do
            if not p.off then
                local t = self:PartText(p)
                if t and t ~= "" then bits[#bits + 1] = t end
            end
        end
        out[#out + 1] = { id = m.id, name = m.name, cur = cur, n = #parts,
                          text = tconcat(bits, (cur and d.sep) or m.sep or " ") }
    end
    return out
end

-- The message in use: id, name.
function Msg:Current()
    local d = DB()
    local m = FindMsg(d, d.cur)
    return d.cur, m and m.name or ""
end

-- Puts another saved message in use (the one in use keeps what it has). Returns ok.
function Msg:Use(id)
    local d = DB()
    local to = FindMsg(d, id)
    if not to then return false end
    if id == d.cur then return true end
    local from = FindMsg(d, d.cur)
    if from then from.parts, from.sep = d.parts, d.sep end
    d.parts, d.sep = to.parts or {}, SEP_OK[to.sep] and to.sep or " "
    to.parts, to.sep = nil, nil
    d.cur = id
    ns:Fire("RECRUIT_MSG_CHANGED")
    return true
end

-- A new message (copy: starting from the one in use, else empty), put in use. Returns ok, id | why.
function Msg:NewMessage(name, copy)
    local d = DB()
    if #d.msgs >= MAX_MESSAGES then return false, "that's " .. MAX_MESSAGES .. " messages: delete one first" end
    name = Named(name)
    if not name then return false, "give it a name" end
    d.mid = d.mid + 1
    local m = { id = d.mid, name = name, sep = copy and d.sep or " ", parts = {} }
    if copy then
        for _, p in ipairs(d.parts) do
            local q = Util.CopyTable(p)
            d.nid = d.nid + 1
            q.id = d.nid
            m.parts[#m.parts + 1] = q
        end
    end
    d.msgs[#d.msgs + 1] = m
    self:Use(m.id)
    return true, m.id
end

function Msg:RenameMessage(id, name)
    local m = FindMsg(DB(), id)
    name = Named(name)
    if not m then return false, "no such message" end
    if not name then return false, "give it a name" end
    m.name = name
    ns:Fire("RECRUIT_MSG_CHANGED")
    return true
end

-- Deletes a saved message (never the last one); deleting the one in use puts the next in use.
function Msg:DeleteMessage(id)
    local d = DB()
    local m, i = FindMsg(d, id)
    if not m then return false, "no such message" end
    if #d.msgs <= 1 then return false, "it's the only message" end
    if id == d.cur then
        local next = d.msgs[i + 1] or d.msgs[i - 1]
        self:Use(next.id)
    end
    table.remove(d.msgs, (select(2, FindMsg(d, id))))
    ns:Fire("RECRUIT_MSG_CHANGED")
    return true
end

---------------------------------------------------------------------------
-- The helpers' facts
---------------------------------------------------------------------------

local function HM(w)
    local m = floor(w) % 1440
    return ("%d:%02d"):format(floor(m / 60), m % 60)
end

-- A team's nights: "Thu + Sun 19:30" (one start time), "Thu 19:30 + Sun 20:00" (more); nil without nights.
function Msg:NightsText(team)
    local list = {}
    for _, n in ipairs(team and team.nights or {}) do
        local w = tonumber(n.w)
        if w and w >= 0 and w < 7 * 1440 then list[#list + 1] = w end
    end
    if #list == 0 then return nil end
    tsort(list)
    local same = true
    for _, w in ipairs(list) do if HM(w) ~= HM(list[1]) then same = false end end
    local out = {}
    for _, w in ipairs(list) do
        local d = DAY_SHORT[floor(w / 1440) + 1]
        out[#out + 1] = same and d or (d .. " " .. HM(w))
    end
    return tconcat(out, " + ") .. (same and (" " .. HM(list[1])) or "")
end

local function SlotName(o, by)
    if o.c and by == "short" then
        local name = o.sp and Msg.SHORT_SPEC[o.c] and Msg.SHORT_SPEC[o.c][o.sp] or Msg.SHORT_CLASS[o.c] or o.c
        return name, o.c .. ":" .. (o.sp or 0)
    end
    if o.c then
        local cls = ns.ClassName(o.c) or o.c
        local spec = by ~= "class" and o.sp and ns.SPECS[o.c] and ns.SPECS[o.c][o.sp]
        return spec and (spec.label .. " " .. cls) or cls, by == "class" and o.c or (o.c .. ":" .. (o.sp or 0))
    end
    local role = o.role and tostring(o.role) or nil
    if not role then return nil end
    return role:sub(1, 1):upper() .. role:sub(2), "role:" .. role
end

-- The open places of one team ("all": every team, each once): { { key, name, c, sp, skip }, ... } in comp order.
function Msg:NeedList(part)
    local teams = {}
    if part.team == "all" then
        teams = R():GetTeams()
    else
        local t = R():GetTeam(part.team)
        if t then teams[1] = t end
    end
    local out, seen = {}, {}
    local RP = ns.RaidPlan
    for _, team in ipairs(teams) do
        local open = team.demoOpen or (RP and RP.GetTeamOpenSlots and (RP:GetTeamOpenSlots(team))) or {}
        for _, o in ipairs(open) do
            local name, key = SlotName(o, part.by)
            if name and not seen[key] then
                seen[key] = true
                out[#out + 1] = { key = key, name = name, c = o.c, sp = o.sp,
                                  skip = (part.skip and part.skip[key]) and true or false }
            end
        end
    end
    return out
end

local function GuildName()
    if Util.DemoOn() then return "Casual Disaster" end
    local name = GetGuildInfo and GetGuildInfo("player")
    return name
end

-- What one part says now (nil: nothing, e.g. a team without nights or without open places).
function Msg:PartText(p)
    if p.k == "text" then
        local t = Util.Trim(p.t or "")
        return (t and t ~= "") and t or nil
    elseif p.k == "tag" then
        local g = GuildName()
        return g and ("<" .. g .. ">") or nil
    elseif p.k == "icon" then
        return self:IconCode(p.m or 1)
    elseif p.k == "nights" then
        return self:NightsText(R():GetTeam(p.team))
    elseif p.k == "need" then
        local names = {}
        for _, e in ipairs(self:NeedList(p)) do if not e.skip then names[#names + 1] = e.name end end
        return #names > 0 and tconcat(names, ", ") or nil
    end
end

-- The team a part is about, by name ("every team" / nil).
function Msg:PartTeamName(p)
    if p.team == "all" then return "every team" end
    local t = p.team and R():GetTeam(p.team)
    return t and t.name or nil
end

---------------------------------------------------------------------------
-- The parts
---------------------------------------------------------------------------

-- The parts in their order (copies, with label and what they say now).
function Msg:GetParts()
    local out = {}
    for _, p in ipairs(DB().parts) do
        local skip = {}
        for k in pairs(p.skip or {}) do skip[k] = true end
        out[#out + 1] = { id = p.id, k = p.k, t = p.t, m = p.m, team = p.team, by = p.by or "spec", skip = skip,
                          on = not p.off, label = Msg.KINDS[p.k] and Msg.KINDS[p.k].label or p.k,
                          teamName = self:PartTeamName(p), text = self:PartText(p) }
    end
    return out
end

function Msg:GetPart(id)
    for i, p in ipairs(DB().parts) do if p.id == id then return p, i end end
end

-- Adds a part (kind: "text" | "tag" | "need" | "nights" | "icon"; opts: t, team, by, m (icon 1..8), after (a part's
-- id: put it right after that one)). Returns ok, id | why.
function Msg:AddPart(kind, opts)
    if not Msg.KINDS[kind] then return false, "not a part" end
    local d = DB()
    if #d.parts >= MAX_PARTS then return false, "that's enough parts" end
    opts = opts or {}
    local p = { k = kind }
    if kind == "text" then p.t = Words(opts.t)
    elseif kind == "icon" then p.m = Util.IsInt(opts.m, 1, 8) and opts.m or 1
    elseif kind == "need" or kind == "nights" then
        local team = opts.team
        if kind == "need" and team == "all" then p.team = "all"
        elseif team and R():GetTeam(team) then p.team = team
        else
            local first = R():GetTeams()[1]
            if not first then return false, "no team yet: make one in Raids > Teams" end
            p.team = first.id
        end
        if kind == "need" then p.by = (opts.by == "class" or opts.by == "short") and opts.by or "spec" end
    end
    d.nid = d.nid + 1
    p.id = d.nid
    local at
    if opts.after then at = select(2, self:GetPart(opts.after)) end
    table.insert(d.parts, at and (at + 1) or (#d.parts + 1), p)
    ns:Fire("RECRUIT_MSG_CHANGED")
    return true, p.id
end

-- Changes a part: t (words), m (an icon's 1..8), team, by, on, skip = entry (switches that entry).
function Msg:SetPart(id, f)
    local p = self:GetPart(id)
    if not p then return false end
    if f.t ~= nil and p.k == "text" then p.t = Words(f.t) end
    if f.m ~= nil and p.k == "icon" and Util.IsInt(f.m, 1, 8) then p.m = f.m end
    if f.team ~= nil and (p.k == "need" or p.k == "nights") then
        if (f.team == "all" and p.k == "need") or R():GetTeam(f.team) then
            if p.team ~= f.team then p.skip = nil end
            p.team = f.team
        end
    end
    if f.by ~= nil and p.k == "need" then
        local by = (f.by == "class" or f.by == "short") and f.by or "spec"
        if (by == "class") ~= (p.by == "class") then p.skip = nil end      -- (specs and short share what's left out)
        p.by = by
    end
    if f.on ~= nil then p.off = (not f.on) or nil end
    if f.skip ~= nil and p.k == "need" then
        p.skip = p.skip or {}
        p.skip[f.skip] = (not p.skip[f.skip]) or nil
        if not next(p.skip) then p.skip = nil end
    end
    ns:Fire("RECRUIT_MSG_CHANGED")
    return true
end

function Msg:RemovePart(id)
    local _, i = self:GetPart(id)
    if not i then return false end
    table.remove(DB().parts, i)
    ns:Fire("RECRUIT_MSG_CHANGED")
    return true
end

-- Moves a part to position `to` (1 = first).
function Msg:MovePart(id, to)
    local d = DB()
    local p, i = self:GetPart(id)
    if not p then return false end
    table.remove(d.parts, i)
    to = max(1, min(#d.parts + 1, floor(tonumber(to) or i)))
    table.insert(d.parts, to, p)
    ns:Fire("RECRUIT_MSG_CHANGED")
    return true
end

function Msg:GetSep() return DB().sep end
function Msg:SetSep(sep)
    if not SEP_OK[sep] then return false end
    DB().sep = sep
    ns:Fire("RECRUIT_MSG_CHANGED")
    return true
end

-- The message: text (nil when nothing is said), its length in bytes, too long?
function Msg:Compose()
    local bits = {}
    for _, p in ipairs(DB().parts) do
        if not p.off then
            local t = self:PartText(p)
            if t then bits[#bits + 1] = t end
        end
    end
    if #bits == 0 then return nil, 0, false end
    local text = tconcat(bits, DB().sep)
    return text, #text, #text > MAX_LEN
end

---------------------------------------------------------------------------
-- Places
---------------------------------------------------------------------------

-- The places, in their order (copies).
function Msg:GetPlaces()
    local out = {}
    for _, p in ipairs(DB().places) do
        out[#out + 1] = { id = p.id, kind = p.kind, name = p.name, every = p.every, u = p.u or "m",
                          on = p.on and true or false, city = p.city and true or false }
    end
    return out
end

function Msg:GetPlace(id)
    for _, p in ipairs(DB().places) do if p.id == id then return p end end
end

-- Seconds, kept between 30 seconds and 12 hours.
function Msg:CleanEvery(v)
    v = floor(tonumber(v) or 3600)
    return min(MAX_EVERY, max(MIN_EVERY, v))
end

-- Adds a place (kind "SAY" | "YELL" | "CHANNEL" and a channel's name; every in seconds). Returns ok, err / id.
function Msg:AddPlace(kind, name, every)
    if kind ~= "SAY" and kind ~= "YELL" and kind ~= "CHANNEL" then return false, "not a place" end
    if kind == "CHANNEL" then
        name = Util.Trim((tostring(name or ""):gsub("[%c|]", ""))) or ""
        if name == "" or #name > 32 then return false, "a channel needs a name" end
    else
        name = kind == "YELL" and "Yell" or "Say"
    end
    local d = DB()
    local id = PlaceId(kind, name)
    if self:GetPlace(id) then return false, "already in the list" end
    if #d.places >= MAX_PLACES then return false, "that's enough places" end
    local lower = name:lower()
    every = self:CleanEvery(every or 3600)
    d.places[#d.places + 1] = { id = id, kind = kind, name = name, every = every, u = every % 60 == 0 and "m" or "s",
                                on = true, city = kind ~= "CHANNEL" or lower == "trade" or lower == "guildrecruitment" }
    ns:Fire("RECRUIT_MSG_CHANGED")
    return true, id
end

function Msg:RemovePlace(id)
    local d = DB()
    for i, p in ipairs(d.places) do
        if p.id == id then
            table.remove(d.places, i)
            ns:Fire("RECRUIT_MSG_CHANGED")
            return true
        end
    end
    return false
end

-- Changes a place: fields on, city, every (seconds), u (the unit it's shown in: "s" | "m").
function Msg:SetPlace(id, f)
    local p = self:GetPlace(id)
    if not p then return false end
    if f.on ~= nil then p.on = f.on and true or false end
    if f.city ~= nil then p.city = f.city and true or false end
    if f.every ~= nil then p.every = self:CleanEvery(f.every) end
    if f.u == "s" or f.u == "m" then p.u = f.u end
    ns:Fire("RECRUIT_MSG_CHANGED")
    return true
end

-- The channels I'm in now (for "Add a place"): their names, without the numbers.
function Msg:JoinedChannels()
    local out = {}
    if not GetChannelList then return out end
    local list = { GetChannelList() }
    for i = 1, #list, 3 do
        local name = list[i + 1]
        if type(name) == "string" and name ~= "" then out[#out + 1] = (name:gsub(" %- .*$", "")) end
    end
    return out
end

function Msg:InMajorCity()
    if Util.DemoOn() then return true end
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if map and CITY_MAPS[map] then return true end
    local z = GetRealZoneText and GetRealZoneText()
    return (z and CITY_NAMES[z]) and true or false
end

-- Why I can't post there now ("only in major cities", "you're not in <channel>"), or nil.
function Msg:Blocker(p)
    if p.city and not self:InMajorCity() then return "only in major cities" end
    if p.kind == "CHANNEL" and not Util.DemoOn() then
        local id = GetChannelName and tonumber((GetChannelName(p.name)))
        if not (id and id > 0) then return "you're not in " .. p.name end
    end
    return nil
end

---------------------------------------------------------------------------
-- Posting, turns, reminders
---------------------------------------------------------------------------

function Msg:LastPost(id)
    local best
    for _, at in ipairs(DB().posts[id] or {}) do if not best or at > best then best = at end end
    return best
end

function Msg:NextDue(id)
    local p = self:GetPlace(id)
    if not p then return nil end
    local last = self:LastPost(id)
    return last and (last + p.every) or Now()
end

function Msg:Record(id, at)
    local d = DB()
    local list = d.posts[id] or {}
    list[#list + 1] = at
    tsort(list, function(a, b) return a > b end)
    for i = #list, 1, -1 do
        if i > 60 or list[i] < Now() - 14 * DAY then table.remove(list, i) end
    end
    d.posts[id] = list
    ns:Fire("RECRUIT_MSG_CHANGED")
end

-- The places that are on, due now and allowed where I stand (ids).
function Msg:DuePlaces()
    local out = {}
    for _, p in ipairs(DB().places) do
        if p.on and Now() >= (self:NextDue(p.id) or 0) and not self:Blocker(p) then out[#out + 1] = p.id end
    end
    return out
end

-- The next place to come due (that is on): its place and when; nil when none is on.
function Msg:NextUp()
    local best, at
    for _, p in ipairs(DB().places) do
        if p.on then
            local due = self:NextDue(p.id)
            if not at or due < at then best, at = p, due end
        end
    end
    return best, at
end

local function SendTo(p, text)
    if p.kind == "CHANNEL" then
        local id = GetChannelName and tonumber((GetChannelName(p.name)))
        if id and id > 0 then SendChatMessage(text, "CHANNEL", nil, id) end
        return
    end
    SendChatMessage(text, p.kind)
end

-- Posts (from a click or a key) to the places given (ids), or to every place that is on. Returns ok, why | the places'
-- names, the ones skipped ("Trade: only in major cities").
function Msg:Post(ids)
    if not (R() and R():CanUse()) then return false, "only the Guild Master and officers post it" end
    local text, _, long = self:Compose()
    if not text then return false, "Build the message first." end
    if long then return false, "The message is longer than 255: shorten it first." end
    local want = {}
    for _, id in ipairs(ids or {}) do want[id] = true end
    local sent, skipped = {}, {}
    for _, p in ipairs(DB().places) do
        if (ids and want[p.id]) or (not ids and p.on) then
            local why = self:Blocker(p)
            if why then
                skipped[#skipped + 1] = p.name .. ": " .. why
            else
                if Util.DemoOn() then ns:Print("Demo mode, not sent to %s: %s", p.name, text) else SendTo(p, text) end
                sent[#sent + 1] = p
            end
        end
    end
    if #sent == 0 then return false, #skipped > 0 and tconcat(skipped, "; ") or "No place is on." end
    local at = Now()
    local names = {}
    for _, p in ipairs(sent) do
        self:Record(p.id, at)
        names[#names + 1] = p.name
    end
    self.ready, self.readyKey = nil, nil
    if not Util.DemoOn() then
        local G = ns.Guild
        for _, k in ipairs(G and G.GetOnlineMembers and G:GetOnlineMembers() or {}) do
            if not Util.IsMe(k) and R():IsRecruiter(k) then
                for _, p in ipairs(sent) do ns.Comm:Send({ t = "RCP", at = at, p = p.id }, "WHISPER", k, "data") end
            end
        end
    end
    ns:Fire("RECRUIT_MSG_POSTED")
    return true, names, skipped
end

-- The key binding's post: the places that are due; with the reminders off, every place that is on. Returns as Post,
-- or false, "nothing is due ..." while the reminders are on and nothing is due.
function Msg:PostByKey()
    if not (R() and R():CanUse()) then return false, "only the Guild Master and officers post it" end
    if not self:IsRepeating() then return self:Post() end
    local due = self:Ready() or self:DuePlaces()
    if #due == 0 then
        local p, at = self:NextUp()
        if not p then return false, "No place is on." end
        return false, ("Nothing is due yet: %s in %d s."):format(p.name, max(1, at - Now()))
    end
    return self:Post(due)
end

function Msg:IsRepeating() return DB().rep == true end
function Msg:SetRepeat(on)
    DB().rep = on and true or nil
    self.ready, self.readyKey = nil, nil
    ns:Fire("RECRUIT_MSG_CHANGED")
end
-- The places waiting for a click (the toast's), or nil.
function Msg:Ready() return self.ready end

local function OnPost(sender, msg, dist)
    if dist ~= "WHISPER" or not (R() and R():IsRecruiter(sender) and R():CanUse()) then return end
    local at = tonumber(msg.at)
    if not Util.IsInt(at, Now() - DAY, Now() + 60) or type(msg.p) ~= "string" or #msg.p > 40 then return end
    Msg:Record(msg.p, at)
end

local function Tick()
    if not Msg:IsRepeating() or not (R() and R():CanUse()) then return end
    local due = Msg:DuePlaces()
    if #due == 0 then
        Msg.ready, Msg.readyKey = nil, nil
        return
    end
    local key = tconcat(due, ",")
    if Msg.readyKey ~= key then
        Msg.ready, Msg.readyKey = due, key
        ns:Fire("RECRUIT_MSG_READY", due)
    end
end

-- Lately: posts this week (every place), and the people who whispered within 2 hours of a post.
function Msg:Lately()
    local all = {}
    for _, list in pairs(DB().posts) do for _, at in ipairs(list) do all[#all + 1] = at end end
    tsort(all, function(a, b) return a > b end)
    local week = 0
    for _, at in ipairs(all) do if at >= Now() - 7 * DAY then week = week + 1 end end
    local came, joined = {}, 0
    for _, r in ipairs(R():GetPeople()) do
        if (r.src == "whisper" or r.src == "trade") and r.at then
            for _, at in ipairs(all) do
                if r.at >= at and r.at <= at + 7200 then
                    came[#came + 1] = r
                    if r.st == "joined" or r.st == "gone" then joined = joined + 1 end
                    break
                end
            end
        end
    end
    tsort(came, function(a, b) return a.at > b.at end)
    return { week = week, last = all[1], came = came, joined = joined }
end

function Msg:OnInit()
    if ns.Comm and ns.Comm.Register then ns.Comm:Register("RCP", OnPost) end
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(1, Tick) end
    ns:On("DEMO_TOGGLED", function() demoStore = nil; Msg.ready, Msg.readyKey = nil, nil end)
end

-- (tests) check now
function Msg:_Tick() Tick() end
