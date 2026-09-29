-- CDLoot Games/Azeromon/Game.lua
-- ns.Azero: the game controller, frame-free so the tests can drive it. The UI renders its state and
-- forwards input:
--   G:Update(dt)                 advance movement / waits (call every frame)
--   G.input.dir = "up"|...|nil   held direction;  G.input.run = bool (hold B to run)
--   G:PressA()                   interact / advance text
--   G.pending                    what the UI must show: text, choice, battle, shop, wait (nil = free roam)
--   G:Advance(value)             answer the pending prompt (choice index, battle result, ...)
-- Story scripts (Maps.lua) run as coroutines: G:Say / G:YesNo / G:Battle pause until answered.
-- The save lives in CDLootDB.games.azeromon.save and is written live (SavedVariables flush at logout).
local addonName, ns = ...

local G = ns:NewModule("Azero")
local D = ns.AzeroData
local M = ns.AzeroMon
local Maps = ns.AzeroMaps
local A = ns.AzeroAtlas

G.GAME_ID = "azeromon"
G.STEP_TIME = 0.24
G.RUN_TIME = 0.13
G.TURN_DELAY = 0.09         -- a tap turns in place; holding longer walks
G.ENCOUNTER_PCT = 12

local DIRS = {
    up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 },
}
local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }
G.DIRS, G.OPPOSITE = DIRS, OPPOSITE

G.rng = math.random
G.input = { dir = nil, run = false, held = 0 }

---------------------------------------------------------------------------
-- Map compilation (tile layers + collision), cached per map
---------------------------------------------------------------------------

local SOLID_CHARS = { T = true, w = true, W = true, X = true, b = true, d = true, p = true, t = true, C = true, c = true,
                      ["#"] = true, h = true, o = true, i = true }
local OVER_CHARS = { T = "tree", b = "bed", d = "dresser", p = "pot", t = "table", C = "chest", c = "counter",
                     ["#"] = "fence", h = "hay", o = "pumpkin", i = "torch1" }
local STAMP_SIZE = { house = { 5, 6 }, farmhouse = { 5, 6 }, stonehouse = { 5, 6 }, bigtree = { 3, 3 },
                     wbigtree = { 3, 3 }, mailbox = { 1, 2 }, scarecrow = { 1, 2 }, windmill = { 2, 3 }, tent = { 2, 2 } }
local HOUSES = { house = true, farmhouse = true, stonehouse = true }
-- Map themes swap the outdoor tile set. Westfall: dry golden grass, wheat for tall grass, olive trees.
local THEMES = {
    elwynn = { grass1 = "grass1", grass2 = "grass2", tall = "tall_", path = "path_", tree = "tree" },
    westfall = { grass1 = "wgrass1", grass2 = "wgrass2", tall = "wtall_", path = "wpath_", tree = "wtree" },
}
G.THEMES = THEMES

local compiled = {}

local function Autotile(rows, w, h, x, y, ch, prefix, inner)
    local function same(xx, yy)
        if xx < 0 or yy < 0 or xx >= w or yy >= h then return true end
        return rows[yy + 1]:sub(xx + 1, xx + 1) == ch
    end
    local n, s, e, wv = same(x, y - 1), same(x, y + 1), same(x + 1, y), same(x - 1, y)
    if n and s and e and wv then
        if inner then
            if not same(x - 1, y - 1) then return prefix .. "inw" end
            if not same(x + 1, y - 1) then return prefix .. "ine" end
            if not same(x - 1, y + 1) then return prefix .. "isw" end
            if not same(x + 1, y + 1) then return prefix .. "ise" end
        end
        return prefix .. "c"
    end
    if not n and not wv then return prefix .. "tl" end
    if not n and not e then return prefix .. "tr" end
    if not s and not wv then return prefix .. "bl" end
    if not s and not e then return prefix .. "br" end
    if not n then return prefix .. "t" end
    if not s then return prefix .. "b" end
    if not wv then return prefix .. "l" end
    if not e then return prefix .. "r" end
    return prefix .. "c"
end

function G.Compile(id)
    if compiled[id] then return compiled[id] end
    local def = Maps[id]
    if type(def) ~= "table" or not def.rows then return nil end
    local rows = def.rows
    local h, w = #rows, #rows[1]
    local m = { id = id, def = def, w = w, h = h, base = {}, over = {}, solid = {}, tall = {}, water = {},
                sign = {}, warp = {}, chest = {}, object = {}, trigger = {} }
    local function key(x, y) return y * w + x end
    m.key = key
    local th = THEMES[def.theme or "elwynn"] or THEMES.elwynn
    m.theme = th
    for y = 0, h - 1 do
        local row = rows[y + 1]
        for x = 0, w - 1 do
            local ch = row:sub(x + 1, x + 1)
            local k = key(x, y)
            local base
            if ch == "\"" or ch == ";" then
                -- tall grass / wheat; ";" is shore grass with its own encounter table (def.coastEncounters)
                -- shore grass is green scrub (the Elwynn bush), so it reads apart from the wheat
                base = Autotile(rows, w, h, x, y, ch, (ch == ";") and "tall_" or th.tall, false)
                m.tall[k] = (ch == ";") and "coast" or "main"
            elseif ch == "=" then
                base = Autotile(rows, w, h, x, y, ch, th.path, true)
            elseif ch == "s" then
                base = "sand"
            elseif ch == "w" then
                base = "water1"
                m.water[k] = true
            elseif ch == "W" then base = "wall"
            elseif ch == "r" then base = "rug"
            elseif ch == "X" then base = "void"
            elseif def.outdoor then
                base = ((x * 7 + y * 13) % 5 == 0) and th.grass2 or th.grass1
            else
                base = "floor"
            end
            m.base[k] = base
            m.over[k] = (ch == "T") and th.tree or OVER_CHARS[ch]
            if SOLID_CHARS[ch] then m.solid[k] = true end
        end
    end
    for _, st in ipairs(def.stamps or {}) do
        local size = STAMP_SIZE[st.kind]
        for dy = 0, size[2] - 1 do
            for dx = 0, size[1] - 1 do
                local k = key(st.x + dx, st.y + dy)
                m.over[k] = string.format("%s_%d_%d", st.kind, dx, dy)
                local door = HOUSES[st.kind] and dx == 3 and dy == 5
                if not door then m.solid[k] = true end
            end
        end
    end
    for _, s in ipairs(def.signs or {}) do
        local k = key(s.x, s.y)
        m.sign[k] = s
        m.over[k] = "sign"
        m.solid[k] = true
    end
    for _, c in ipairs(def.chests or {}) do
        local k = key(c.x, c.y)
        m.chest[k] = c
        m.solid[k] = true
    end
    for _, o in ipairs(def.objects or {}) do
        local k = key(o.x, o.y)
        m.object[k] = o
        m.over[k] = o.tile
        m.solid[k] = true
    end
    for _, wp in ipairs(def.warps or {}) do m.warp[key(wp.x, wp.y)] = wp end
    for _, tr in ipairs(def.triggers or {}) do m.trigger[key(tr.x, tr.y)] = tr end
    compiled[id] = m
    return m
end

---------------------------------------------------------------------------
-- Save
---------------------------------------------------------------------------

function G:Data() return ns.Games:GetData(G.GAME_ID) end

function G:HasSave()
    local s = self:Data().save
    return type(s) == "table" and s.v == D.SAVE_VERSION and Maps[s.map] ~= nil
end

function G:PlayerName()
    local n = UnitName and UnitName("player")
    return (n and n ~= "") and n or "Tamer"
end

function G:NewGame()
    local data = self:Data()
    data.save = {
        v = D.SAVE_VERSION,
        map = Maps.START.map, x = Maps.START.x, y = Maps.START.y, face = Maps.START.face,
        party = {}, box = {}, bag = {}, money = D.START_MONEY,
        flags = {}, seen = {}, caught = {}, steps = 0, time = 0,
    }
    self:Load()
end

-- Validates the save (unknown species / maps are dropped), then enters the saved map.
function G:Load()
    local s = self:Data().save
    self.save = s
    local function clean(list)
        local out = {}
        if type(list) == "table" then
            for _, mon in ipairs(list) do
                local ok = M.Sanitize(mon)
                if ok then out[#out + 1] = ok end
            end
        end
        return out
    end
    s.party = clean(s.party)
    s.box = clean(s.box)
    while #s.party > D.MAX_PARTY do table.insert(s.box, table.remove(s.party)) end
    if type(s.bag) ~= "table" then s.bag = {} end
    for item, n in pairs(s.bag) do
        if not D.items[item] or type(n) ~= "number" or n <= 0 then s.bag[item] = nil end
    end
    for _, k in ipairs({ "flags", "seen", "caught" }) do
        if type(s[k]) ~= "table" then s[k] = {} end
    end
    s.money = math.max(0, math.floor(tonumber(s.money) or 0))
    if not Maps[s.map] then s.map, s.x, s.y, s.face = Maps.START.map, Maps.START.x, Maps.START.y, Maps.START.face end
    self.co, self.pending, self.moving, self.fade = nil, nil, nil, nil
    self.input.dir, self.input.held = nil, 0
    self:EnterMap(s.map, s.x, s.y, s.face, true)
    self.started = true
end

function G:Flag(name) return self.save and self.save.flags[name] end
function G:SetFlag(name, v) if v == nil then v = true end self.save.flags[name] = v end

---------------------------------------------------------------------------
-- Map state
---------------------------------------------------------------------------

function G:EnterMap(id, x, y, face, silent)
    local m = G.Compile(id)
    self.map = m
    local s = self.save
    s.map, s.x, s.y, s.face = id, x, y, face or s.face or "down"
    self.moving = nil
    self.npcs = {}
    for _, def in ipairs(m.def.npcs or {}) do
        local hidden = def.hidden and def.hidden(self)
        self.npcs[#self.npcs + 1] = { def = def, id = def.id, x = def.x, y = def.y, face = def.face or "down",
            homeX = def.x, homeY = def.y, hidden = hidden, wanderIn = 2 + self.rng(0, 30) / 10 }
    end
    if not silent then
        self.fade = 0.3
        if m.def.outdoor then self.banner = { text = m.def.name, t = 2.2 } end
    end
    ns:Fire("AZERO_MAP", id)
end

function G:NpcAt(x, y)
    for _, n in ipairs(self.npcs or {}) do
        if not n.hidden and ((n.x == x and n.y == y) or (n.moving and n.fromX == x and n.fromY == y)) then return n end
    end
end

function G:Blocked(x, y)
    local m = self.map
    if x < 0 or y < 0 or x >= m.w or y >= m.h then return true end
    if m.solid[m.key(x, y)] then return true end
    if self:NpcAt(x, y) then return true end
    if self.save.x == x and self.save.y == y then return true end
    return false
end

function G:IsFree()
    return self.started and not self.pending and not self.co and not self.moving
end

---------------------------------------------------------------------------
-- Script runner
---------------------------------------------------------------------------

function G:Run(fn, ...)
    if self.co then return false end
    local args = { ... }
    local n = select("#", ...)
    self.co = coroutine.create(function() fn(self, unpack(args, 1, n)) end)
    self:Resume()
    return true
end

function G:Resume(...)
    local co = self.co
    if not co then return end
    local ok, err = coroutine.resume(co, ...)
    if not ok then
        self.co, self.pending = nil, nil
        local handler = geterrorhandler and geterrorhandler()
        if handler then handler(err) else error(err) end
        return
    end
    if coroutine.status(co) == "dead" and self.co == co then
        self.co, self.pending = nil, nil
        self.showSpecies = nil
    end
end

-- Pauses the running script until G:Advance(value).
function G:Wait(p)
    self.pending = p
    return coroutine.yield()
end

function G:Advance(value)
    if not self.pending then return end
    self.pending = nil
    self:Resume(value)
end

function G:Fmt(text)
    text = tostring(text or "")
    text = text:gsub("{PLAYER}", self:PlayerName()):gsub("{RIVAL}", D.RIVAL_NAME)
    return text
end

function G:Say(text) return self:Wait({ kind = "text", text = self:Fmt(text) }) end

function G:YesNo(text)
    return self:Wait({ kind = "choice", text = self:Fmt(text), options = { "Yes", "No" }, cancel = 2 }) == 1
end

-- Returns the chosen index, or nil when cancelled.
function G:Choose(text, options)
    local i = self:Wait({ kind = "choice", text = self:Fmt(text), options = options, cancel = #options + 1 })
    if i and i >= 1 and i <= #options then return i end
end

function G:Sleep(secs) return self:Wait({ kind = "wait", t = secs }) end

function G:ShowSpecies(sp) self.showSpecies = sp end

function G:Shop() return self:Wait({ kind = "shop" }) end

function G:HealParty()
    for _, mon in ipairs(self.save.party) do M.Heal(mon) end
end

function G:Give(item, n)
    n = n or 1
    local bag = self.save.bag
    bag[item] = (bag[item] or 0) + n
    local name = D.items[item].name
    self:Say(n > 1 and string.format("{PLAYER} received %d %ss!", n, name) or string.format("{PLAYER} received a %s!", name))
end

function G:AddMon(mon)
    self.save.seen[mon.sp] = true
    self.save.caught[mon.sp] = true
    if #self.save.party < D.MAX_PARTY then
        table.insert(self.save.party, mon)
        return "party"
    end
    table.insert(self.save.box, mon)
    return "box"
end

function G:GiveMon(sp, lvl, silent)
    local mon = M.New(sp, lvl, self.rng)
    self:AddMon(mon)
    self:Say(string.format("{PLAYER} received %s!", D.species[sp].name))
    return mon
end

function G:ShowDexSummary()
    local seen, caught = 0, 0
    for _ in pairs(self.save.seen) do seen = seen + 1 end
    for _ in pairs(self.save.caught) do caught = caught + 1 end
    self:Say(string.format("Bestiary: %d seen, %d tamed, out of %d known beasts.", seen, caught, #D.dexOrder))
end

-- Player walks one tile under script control.
function G:PushPlayer(dir)
    self.save.face = dir
    local d = DIRS[dir]
    local nx, ny = self.save.x + d[1], self.save.y + d[2]
    if self:Blocked(nx, ny) then return end
    self:StartStep(dir, false, true)
    self:Wait({ kind = "walk" })
end

function G:StopAtGuard()
    self:Say("Marshal Dughan: Hold it! The forest is no place to wander without a beast at your side.")
    self:Say("Marshal Dughan: Huntmaster Aldric's lodge is to the east. Go see him first.")
    self:PushPlayer("down")
end

---------------------------------------------------------------------------
-- Battles
---------------------------------------------------------------------------

function G:TrainerDef(id)
    local def = D.trainers[id]
    local t = {}
    for k, v in pairs(def) do t[k] = v end
    t.name = self:Fmt(def.name)
    t.intro = def.intro and self:Fmt(def.intro)
    t.lose = def.lose and self:Fmt(def.lose)
    t.win = def.win and self:Fmt(def.win)
    return t
end

function G:TrainerTeam(id)
    local def = D.trainers[id]
    local team = {}
    if def.team == "rival" then
        team[1] = M.New(self:Flag("rivalStarter") or "murkling", 5, self.rng)
    else
        for i, e in ipairs(def.team) do team[i] = M.New(e[1], e[2], self.rng) end
    end
    return team
end

-- Runs a battle to the end; returns "win" | "lose" | "run" | "caught".
-- opts.noBlackout: a loss does not send the player back (the first rival battle).
function G:RunBattle(foes, trainerId, opts)
    local s = self.save
    local b = ns.AzeroBattle.New({
        party = s.party, foes = foes, wild = trainerId == nil,
        trainer = trainerId and self:TrainerDef(trainerId), bag = s.bag, rng = self.rng,
        onSeen = function(sp) s.seen[sp] = true end,
        onCaught = function(mon) return self:AddMon(mon) end,
    })
    self.battle = b
    local result = self:Wait({ kind = "battle", battle = b }) or b.result
    self.battle = nil
    for _, mon in ipairs(s.party) do          -- volatile state ends with the battle
        if mon.status == "slp" and mon.hp <= 0 then mon.status, mon.sleep = nil, nil end
    end
    if result == "win" and b.prize then s.money = s.money + b.prize end
    if result == "lose" and not (opts and opts.noBlackout) then
        self:Blackout()
        return result
    end
    self:Evolutions(b)
    return result
end

function G:Evolutions(b)
    for _, mon in ipairs(self.save.party) do
        if b.leveled[mon] and mon.hp > 0 then
            local into = M.EvolutionTarget(mon)
            if into then
                local old = M.Name(mon)
                self:ShowSpecies(mon.sp)
                self:Say(string.format("What? %s is evolving!", old))
                M.Evolve(mon, into)
                self.save.seen[into], self.save.caught[into] = true, true
                self:ShowSpecies(into)
                self:Say(string.format("Congratulations! Your %s evolved into %s!", old, D.species[into].name))
                self:ShowSpecies(nil)
            end
        end
    end
end

function G:Battle(trainerId)
    local opts = trainerId == "rival1" and { noBlackout = true } or nil
    return self:RunBattle(self:TrainerTeam(trainerId), trainerId, opts)
end

function G:WildBattle(sp, lvl)
    return self:RunBattle({ M.New(sp, lvl, self.rng) }, nil)
end

function G:Blackout()
    local s = self.save
    local lost = math.floor(s.money / 2)
    s.money = s.money - lost
    self:HealParty()
    local r = s.respawn
    if type(r) ~= "table" or not Maps[r.map] then r = Maps.RESPAWN end
    self:EnterMap(r.map, r.x, r.y, r.face)
    self:Say(string.format("{PLAYER} dropped %s in the scramble and fled back to %s...", D.Money(lost),
        r.name or "the Lion's Pride Inn"))
    self:Say("Your beasts have been rested. Be more careful out there!")
end

-- Where a blackout sends you: the last inn you rested at.
function G:SetRespawn(map, x, y, face, name)
    self.save.respawn = { map = map, x = x, y = y, face = face, name = name }
end

-- Deputy Rainer keeps the Westfall road closed until Hogger is beaten.
function G:HoggerGate()
    self:Say("Deputy Rainer: Hold on! Hogger's gnolls have been raiding this road. Nobody goes to Westfall until he's dealt with.")
    self:Say("Deputy Rainer: His camp is at Forest's Edge, just west of here. Bring me proof you've bested him!")
    self:PushPlayer("down")
end

-- Trainer NPC spots the player (or is talked to): walk over, talk, battle.
function G:TrainerEncounter(npc, spotted)
    local id = npc.def.trainer
    if spotted then
        npc.exclaim = 0.8
        self:Sleep(0.8)
        local d = DIRS[npc.face]
        local path = {}
        local x, y = npc.x, npc.y
        while true do
            local nx, ny = x + d[1], y + d[2]
            if nx == self.save.x and ny == self.save.y then break end
            path[#path + 1] = npc.face
            x, y = nx, ny
            if #path > 10 then break end
        end
        if #path > 0 then
            npc.path = path
            self:Wait({ kind = "walk", npc = npc })
        end
        self.save.face = OPPOSITE[npc.face]
    end
    local def = D.trainers[id]
    self:Say(self:TrainerDef(id).name .. ": " .. self:Fmt(def.intro))
    local result = self:Battle(id)
    if result == "win" then
        self:SetFlag("beat_" .. id)
        local badge = def.badge and D.badges[def.badge]
        if badge and not self:Flag("badge_" .. def.badge) then
            self:SetFlag("badge_" .. def.badge)
            self:Say(string.format("{PLAYER} received %s!", badge.name))
            if badge.text then self:Say(badge.text) end
        end
    end
end

function G:BadgeCount()
    local n = 0
    for id in pairs(D.badges) do if self:Flag("badge_" .. id) then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------
-- Movement
---------------------------------------------------------------------------

function G:StartStep(dir, run, forced)
    local s = self.save
    local d = DIRS[dir]
    self.moving = { fromX = s.x, fromY = s.y, t = 0, dur = run and G.RUN_TIME or G.STEP_TIME, forced = forced }
    s.x, s.y = s.x + d[1], s.y + d[2]
    s.face = dir
    self.stepParity = not self.stepParity
    if ns.AzeroNet then ns.AzeroNet:NoteStep(dir) end
end

-- Tries to walk toward `dir`. Returns "moved" | "turned" | "blocked" | "edge".
function G:TryStep(dir, run)
    if not self:IsFree() then return nil end
    local s = self.save
    local d = DIRS[dir]
    if not d then return nil end
    s.face = dir
    local nx, ny = s.x + d[1], s.y + d[2]
    local m = self.map
    if nx < 0 or ny < 0 or nx >= m.w or ny >= m.h then
        local side = ({ up = "north", down = "south", left = "west", right = "east" })[dir]
        local edge = m.def.edges and m.def.edges[side]
        if edge then
            -- north / south keep x (shifted by dx); west / east keep y (shifted by dy)
            local target = G.Compile(edge.map)
            local tx, ty
            if dir == "up" or dir == "down" then
                tx, ty = nx + (edge.dx or 0), (dir == "up") and (target.h - 1) or 0
            else
                tx, ty = (dir == "left") and (target.w - 1) or 0, ny + (edge.dy or 0)
            end
            self:EnterMap(edge.map, tx, ty, dir)
            return "edge"
        end
        self.bump = 0.2
        return "blocked"
    end
    if m.solid[m.key(nx, ny)] or self:NpcAt(nx, ny) then
        self.bump = 0.2
        return "blocked"
    end
    self:StartStep(dir, run)
    return "moved"
end

function G:OnArrive(forced)
    local s = self.save
    local m = self.map
    local k = m.key(s.x, s.y)
    s.steps = (s.steps or 0) + 1
    if forced then return end
    local wp = m.warp[k]
    if wp then
        self:EnterMap(wp.map, wp.tx, wp.ty, wp.face)
        return
    end
    local tr = m.trigger[k]
    if tr and (not tr.cond or tr.cond(self)) then
        self:Run(tr.script)
        return
    end
    if self:CheckTrainers() then return end
    local list = (m.tall[k] == "coast") and m.def.coastEncounters or m.def.encounters
    if m.tall[k] and list and M.FirstUsable(s.party) and self.rng(1, 100) <= G.ENCOUNTER_PCT then
        local sp, lvl = self:RollEncounter(list)
        self:Run(function(g) g:WildBattle(sp, lvl) end)
    end
end

function G:RollEncounter(list)
    local total = 0
    for _, e in ipairs(list) do total = total + e.weight end
    local r = self.rng(1, total)
    for _, e in ipairs(list) do
        r = r - e.weight
        if r <= 0 then return e.sp, self.rng(e.min, e.max) end
    end
    local e = list[#list]
    return e.sp, e.min
end

-- A trainer who can see the player starts a battle. Returns true when one did.
function G:CheckTrainers()
    if not M.FirstUsable(self.save.party) then return false end
    local s = self.save
    for _, n in ipairs(self.npcs) do
        local id = n.def.trainer
        if id and not n.hidden and not self:Flag("beat_" .. id) then
            local d = DIRS[n.face]
            local x, y = n.x, n.y
            for _ = 1, n.def.sight or 3 do
                x, y = x + d[1], y + d[2]
                if x == s.x and y == s.y then
                    self:Run(function(g) g:TrainerEncounter(n, true) end)
                    return true
                end
                if self.map.solid[self.map.key(x, y)] or self:NpcAt(x, y) then break end
            end
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Interaction
---------------------------------------------------------------------------

function G:PressA()
    if self.pending then
        if self.pending.kind == "text" then self:Advance() end
        return
    end
    if not self:IsFree() then return end
    local s = self.save
    local m = self.map
    local d = DIRS[s.face]
    local x, y = s.x + d[1], s.y + d[2]
    local k = m.key(x, y)
    local peer = ns.AzeroNet and ns.AzeroNet:PeerAt(m.id, x, y)
    if peer and not self:NpcAt(x, y) then            -- another player (guildmate)
        self:Run(function(g) ns.AzeroPvP:Challenge(g, peer) end)
        return
    end
    local npc = self:NpcAt(x, y)
    if not npc and m.over[k] == "counter" then        -- talk across a counter
        npc = self:NpcAt(x + d[1], y + d[2])
    end
    if npc then
        npc.face = OPPOSITE[s.face]
        local id = npc.def.trainer
        if id and not self:Flag("beat_" .. id) then
            self:Run(function(g) g:TrainerEncounter(npc, false) end)
        elseif id then
            local def = D.trainers[id]
            self:Run(function(g) g:Say(g:TrainerDef(id).name .. ": " .. g:Fmt(def.lose)) end)
        elseif npc.def.script then
            self:Run(npc.def.script, npc)
        end
        return
    end
    if m.sign[k] then
        local text = m.sign[k].text
        self:Run(function(g) g:Say(text) end)
        return
    end
    local chest = m.chest[k]
    if chest then
        if self:Flag("chest_" .. chest.id) then
            self:Run(function(g) g:Say("It's empty.") end)
        else
            self:Run(function(g)
                g:SetFlag("chest_" .. chest.id)
                g:Give(chest.item, chest.n)
            end)
        end
        return
    end
    local obj = m.object[k]
    if obj and obj.script then
        self:Run(obj.script)
    end
end

---------------------------------------------------------------------------
-- Frame update
---------------------------------------------------------------------------

function G:UpdateNpcs(dt)
    for _, n in ipairs(self.npcs or {}) do
        if n.exclaim then
            n.exclaim = n.exclaim - dt
            if n.exclaim <= 0 then n.exclaim = nil end
        end
        if n.moving then
            n.moving.t = n.moving.t + dt
            if n.moving.t >= n.moving.dur then n.moving = nil end
        end
        if not n.moving and n.path and #n.path > 0 then
            local dir = table.remove(n.path, 1)
            local d = DIRS[dir]
            n.face = dir
            n.moving = { fromX = n.x, fromY = n.y, t = 0, dur = G.STEP_TIME }
            n.fromX, n.fromY = n.x, n.y
            n.x, n.y = n.x + d[1], n.y + d[2]
        elseif not n.moving and n.path and #n.path == 0 then
            n.path = nil
            if self.pending and self.pending.kind == "walk" and self.pending.npc == n then self:Advance() end
        elseif not n.moving and n.def.wander and not n.hidden and not self.pending and not self.co then
            n.wanderIn = n.wanderIn - dt
            if n.wanderIn <= 0 then
                n.wanderIn = 1.5 + self.rng(0, 30) / 10
                local dirs = { "up", "down", "left", "right" }
                local dir = dirs[self.rng(1, 4)]
                local d = DIRS[dir]
                local nx, ny = n.x + d[1], n.y + d[2]
                n.face = dir
                if math.abs(nx - n.homeX) <= 2 and math.abs(ny - n.homeY) <= 2 and not self:Blocked(nx, ny)
                    and not self.map.warp[self.map.key(nx, ny)] and not self.map.trigger[self.map.key(nx, ny)] then
                    n.moving = { t = 0, dur = G.STEP_TIME * 1.5 }
                    n.fromX, n.fromY = n.x, n.y
                    n.x, n.y = nx, ny
                end
            end
        end
    end
end

function G:Update(dt)
    if not self.started then return end
    self.save.time = (self.save.time or 0) + dt
    if self.fade then
        self.fade = self.fade - dt
        if self.fade <= 0 then self.fade = nil end
    end
    if self.banner then
        self.banner.t = self.banner.t - dt
        if self.banner.t <= 0 then self.banner = nil end
    end
    if self.bump then
        self.bump = self.bump - dt
        if self.bump <= 0 then self.bump = nil end
    end
    self:UpdateNpcs(dt)

    local p = self.pending
    if p and p.kind == "wait" then
        p.t = p.t - dt
        if p.t <= 0 then self:Advance() end
    end

    if self.moving then
        local mv = self.moving
        mv.t = mv.t + dt
        if mv.t >= mv.dur then
            self.moving = nil
            self:OnArrive(mv.forced)
            if self.pending and self.pending.kind == "walk" and not self.pending.npc then self:Advance() end
        end
    end

    local inp = self.input
    if inp.dir then
        inp.held = (inp.held or 0) + dt
        if self:IsFree() and not self.bump then
            if self.save.face ~= inp.dir and inp.held < G.TURN_DELAY and not self.justWalked then
                self.save.face = inp.dir
            elseif inp.held >= G.TURN_DELAY or self.justWalked or self.save.face == inp.dir then
                local r = self:TryStep(inp.dir, inp.run)
                self.justWalked = (r == "moved" or r == "edge")
            end
        end
    else
        inp.held = 0
        if self:IsFree() then self.justWalked = false end
    end
end

-- Direction press / release from the UI.
function G:SetDir(dir)
    if dir ~= self.input.dir then
        self.input.dir = dir
        self.input.held = 0
    end
end

---------------------------------------------------------------------------
-- Menus (called by the UI while free)
---------------------------------------------------------------------------

-- Uses a bag item on a party creature outside battle. Returns a message.
function G:UseItemOutside(item, idx)
    local def = D.items[item]
    local mon = self.save.party[idx]
    local bag = self.save.bag
    if not def or not mon or (bag[item] or 0) <= 0 then return "It won't have any effect." end
    if def.use == "heal" then
        if mon.hp <= 0 or mon.hp >= M.MaxHP(mon) then return "It won't have any effect." end
        local before = mon.hp
        mon.hp = math.min(M.MaxHP(mon), mon.hp + def.heal)
        bag[item] = bag[item] - 1
        if bag[item] <= 0 then bag[item] = nil end
        return string.format("%s's HP was restored by %d points.", M.Name(mon), mon.hp - before)
    elseif def.use == "cure" then
        if mon.status ~= def.cures then return "It won't have any effect." end
        mon.status = nil
        bag[item] = bag[item] - 1
        if bag[item] <= 0 then bag[item] = nil end
        return string.format("%s was cured!", M.Name(mon))
    end
    return "You can't use that here."
end

function G:SwapParty(i, j)
    local p = self.save.party
    if p[i] and p[j] and i ~= j then p[i], p[j] = p[j], p[i] return true end
    return false
end

-- Returns ok, message.
function G:Buy(item, qty)
    local def = D.items[item]
    qty = math.max(1, math.floor(qty or 1))
    if not def then return false, "?" end
    local cost = def.price * qty
    if self.save.money < cost then return false, "You don't have enough money." end
    self.save.money = self.save.money - cost
    self.save.bag[item] = (self.save.bag[item] or 0) + qty
    return true, string.format("Here you go! %d %s%s.", qty, def.name, qty > 1 and "s" or "")
end

function G:CleanBag()
    for item, n in pairs(self.save.bag) do if n <= 0 then self.save.bag[item] = nil end end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function G:OnInit()
    ns.Games:Register(G.GAME_ID, {
        name = "Azeromon",
        desc = "Tame, train and battle the beasts of Elwynn Forest, Pokemon style. Arrow keys / WASD to move, Space to interact.",
        icon = "Interface\\Icons\\Ability_Hunter_BeastTaming",
        order = 20,
        create = function(parent) return ns.AzeroUI:CreatePanel(parent) end,
    })
end
