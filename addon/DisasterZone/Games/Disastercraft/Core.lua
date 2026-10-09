if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Core.lua", ...) then return end -- DisasterZone Games/Disastercraft/Core.lua
-- ns.Craft: Disastercraft, a little World of Warcraft on the real map of Azeroth (Games/Azeromon/World: the ground,
-- the scenery, every NPC and creature where it stands in WoW). This file: the namespace, the event feed, the saved
-- characters, experience and levels, money, and the messages the UI shows (the chat box, the red error line).
--
-- Units of measure everywhere: positions in map tiles (floats, x east, y south; one tile = 4.17 yards, the real
-- ADT grid), distances and ranges in yards, times in seconds (the data's ms are converted where they are read),
-- money in copper.
--
-- Files: Data.lua (generated) - Core - Items (bags, gear) - Combat (units, stats, auras, spells) - World (the map,
-- movement, NPCs and creatures and their AI) - Loot - Quests - Party (groups, the network) - UI*.lua.
local addonName, ns = ...

local Craft = ns:NewModule("Craft")
local D = ns.CraftData
Craft.D = D

local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt

Craft.SAVE_VERSION = 1
Craft.YARDS = 533.3333 / 128              -- yards in one map tile
Craft.RUN_SPEED = 7                       -- yards per second (WoW's run speed)
Craft.WALK_SPEED = 2.5
Craft.MELEE_RANGE = 5                     -- yards (WoW's melee reach between two normal-sized units)
Craft.INTERACT_RANGE = 6                  -- yards to talk to an NPC or loot a corpse
Craft.GCD = 1.5
-- Faster than WoW (the user's pick, 2026-10-09): kills, quests and exploring give XP_RATE times WoW's experience,
-- kill / collect objectives need QUEST_COUNT of WoW's count, creatures come back after RESPAWN_RATE of their time
Craft.XP_RATE = 3
Craft.QUEST_COUNT = 0.5
Craft.RESPAWN_RATE = 0.4
Craft.CLASS_NAMES = { [1] = "Warrior", [2] = "Paladin", [3] = "Hunter", [4] = "Rogue", [5] = "Priest",
                      [7] = "Shaman", [8] = "Mage", [9] = "Warlock", [11] = "Druid" }
Craft.CLASS_TOKENS = { [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST",
                       [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [11] = "DRUID" }
Craft.CLASS_MASK = { [1] = 1, [2] = 2, [3] = 4, [4] = 8, [5] = 16, [7] = 64, [8] = 128, [9] = 256, [11] = 1024 }
Craft.PLAYABLE = { 1, 8, 5 }              -- the classes of the first build (Warrior, Mage, Priest)
Craft.POWER_MANA, Craft.POWER_RAGE, Craft.POWER_ENERGY = 0, 1, 3

function Craft.Now() return GetTime and GetTime() or 0 end
function Craft.Time() return (GetServerTime and GetServerTime()) or (time and time()) or 0 end

function Craft.Dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy) * Craft.YARDS
end

-- (in a building walked in place a unit has a height: someone on the floor above is that much farther away)
function Craft.UnitDist(a, b)
    if not a or not b or a.map ~= b.map then return 1e9 end
    local d = Craft.Dist(a.x, a.y, b.x, b.y)
    if a.bld or b.bld then
        local dz = (a.bld and a.e or 0) - (b.bld and b.e or 0)
        if dz > 1 or dz < -1 then d = sqrt(d * d + dz * dz) end
    end
    return d
end

function Craft.Clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

-- Facings: the eight ways a body can face (the sprite sheets' rows, in this order; sheets drawn before the
-- diagonals have only the first four, and a diagonal there shows as its up / down)
Craft.FACES = { "down", "left", "right", "up", "downleft", "downright", "upleft", "upright" }
Craft.FACE_ROW = { down = 0, left = 1, right = 2, up = 3, downleft = 4, downright = 5, upleft = 6, upright = 7 }
local FACE4 = { downleft = 0, downright = 0, upleft = 3, upright = 3 }
-- the map rotation of a facing (0 = north, counter-clockwise)
Craft.FACE_ANGLE = { up = 0, upleft = math.pi / 4, left = math.pi / 2, downleft = 3 * math.pi / 4, down = math.pi,
                     downright = -3 * math.pi / 4, right = -math.pi / 2, upright = -math.pi / 4 }

-- the row of facing `face` on a sheet with `faces` rows a body (4 or 8)
function Craft.FaceRow(face, faces)
    local r = Craft.FACE_ROW[face] or 0
    if r > 3 and (faces or 8) < 8 then return FACE4[face] end
    return r
end

-- the way a body faces moving (dx, dy) (x east, y south): one of the eight, a diagonal within 22.5 degrees of one
function Craft.FaceOf(dx, dy)
    local ax, ay = abs(dx), abs(dy)
    if ax < 1e-9 and ay < 1e-9 then return "down" end
    if ay <= ax * 0.4142 then return dx > 0 and "right" or "left" end
    if ax <= ay * 0.4142 then return dy > 0 and "down" or "up" end
    return (dy > 0 and "down" or "up") .. (dx > 0 and "right" or "left")
end

Craft.rng = math.random                   -- (tests swap in a seeded one)
function Craft.Roll(lo, hi)
    if hi <= lo then return lo end
    return Craft.rng(lo, hi)
end
function Craft.Chance(pct)                -- true pct % of the time (pct may be fractional)
    if pct <= 0 then return false end
    if pct >= 100 then return true end
    return Craft.rng() * 100 < pct
end

---------------------------------------------------------------------------
-- The event feed: Craft:On("event", fn) / Craft:Emit("event", ...)
-- level, xp, money, item, equip, spell (learned), cast, damage, death, kill, quest, loot, party, target, area,
-- login, logout, msg
---------------------------------------------------------------------------

local listeners = {}
function Craft:On(event, fn)
    local list = listeners[event]
    if not list then list = {} listeners[event] = list end
    list[#list + 1] = fn
end

function Craft:Emit(event, ...)
    local list = listeners[event]
    if list then
        for i = 1, #list do
            local ok, err = pcall(list[i], ...)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end
    end
    local any = listeners["*"]
    if any then
        for i = 1, #any do pcall(any[i], event, ...) end
    end
end

---------------------------------------------------------------------------
-- Messages: the chat box (system / loot / combat / say / party lines) and the red error line
---------------------------------------------------------------------------

Craft.log = {}                            -- { { text, kind, t } } newest last
local LOG_MAX = 120
Craft.CHAT_COLORS = {
    system = { 1, 1, 0 }, loot = { 0, 0.67, 0 }, xp = { 0.44, 0.44, 1 }, money = { 1, 1, 0 },
    combat = { 1, 1, 1 }, say = { 1, 1, 1 }, party = { 0.67, 0.67, 1 }, monster = { 1, 1, 0.62 },
    quest = { 1, 0.82, 0 }, error = { 1, 0.1, 0.1 }, skill = { 0.33, 0.33, 1 }, whisper = { 1, 0.5, 1 },
    emote = { 1, 0.5, 0.25 },
}

function Craft:Msg(text, kind)
    kind = kind or "system"
    local log = self.log
    log[#log + 1] = { text = text, kind = kind, t = Craft.Now() }
    if #log > LOG_MAX then table.remove(log, 1) end
    self:Emit("msg", text, kind)
end

-- The red text in the middle of the screen ("Not enough mana", "Out of range"); repeats are throttled.
local lastError, lastErrorAt = nil, 0
function Craft:Error(text)
    local now = Craft.Now()
    if text == lastError and now - lastErrorAt < 0.6 then return end
    lastError, lastErrorAt = text, now
    self:Emit("error", text)
end

-- The yellow text in the middle ("Kobold Vermin slain: 3/10", "Quest completed")
function Craft:Notice(text)
    self:Emit("notice", text)
end

---------------------------------------------------------------------------
-- Money: 12345 copper -> "1g 23s 45c" (or with the coin icons for the UI)
---------------------------------------------------------------------------

function Craft.MoneyText(c, icons)
    c = floor(c or 0)
    local g, s, cp = floor(c / 10000), floor(c / 100) % 100, c % 100
    local parts = {}
    local function add(n, tex, letter, color)
        if icons then
            parts[#parts + 1] = n .. "|T" .. tex .. ":0:0:2:0|t"
        else
            parts[#parts + 1] = "|cff" .. color .. n .. letter .. "|r"
        end
    end
    if g > 0 then add(g, "Interface\\MoneyFrame\\UI-GoldIcon", "g", "ffd700") end
    if s > 0 or (g > 0 and cp > 0) then add(s, "Interface\\MoneyFrame\\UI-SilverIcon", "s", "c7c7cf") end
    if cp > 0 or (g == 0 and s == 0) then add(cp, "Interface\\MoneyFrame\\UI-CopperIcon", "c", "eda55f") end
    return table.concat(parts, " ")
end

function Craft:AddMoney(c, why)
    local s = self.char
    if not s or c == 0 then return end
    s.money = max(0, (s.money or 0) + c)
    if c > 0 and why ~= "silent" then
        self:Msg("You receive " .. Craft.MoneyText(c) .. (why == "loot" and "" or "."), why == "loot" and "money" or "money")
    end
    self:Emit("money", s.money, c)
end

function Craft:Money() return self.char and self.char.money or 0 end

---------------------------------------------------------------------------
-- Saved data: DisasterZoneDB.games.disastercraft = { chars = { [class] = char }, last = class, keys = {...} }
-- One character per class for each of your WoW characters (it carries your name).
---------------------------------------------------------------------------

function Craft:Data()
    return ns.Games and ns.Games:GetData("disastercraft") or {}
end

function Craft:PlayerName()
    local n = UnitName and UnitName("player")
    return (n and n ~= "") and n or "Adventurer"
end

function Craft:Characters()
    local data = self:Data()
    data.chars = data.chars or {}
    local out = {}
    for cls, c in pairs(data.chars) do
        if type(c) == "table" and c.v == Craft.SAVE_VERSION then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return (a.created or 0) < (b.created or 0) end)
    return out
end

local START_BAGS = 16

function Craft:NewCharacter(cls, sex)
    local cd = D.classes[cls]
    if not cd then return nil end
    local data = self:Data()
    data.chars = data.chars or {}
    local c = {
        v = Craft.SAVE_VERSION, class = cls, sex = sex or 0, name = self:PlayerName(), level = 1, xp = 0,
        money = 0, map = "world", x = cd.pos[1], y = cd.pos[2], face = "up",
        bags = { [0] = { size = START_BAGS } }, equip = {}, spells = {}, bar = {}, quests = {}, done = {},
        created = Craft.Time(), played = 0, bind = { map = "world", x = cd.pos[1], y = cd.pos[2],
                                                      name = "Northshire Abbey" },
    }
    for _, id in ipairs(cd.start) do c.spells[id] = true end
    data.chars[cls] = c
    data.last = cls
    return c
end

function Craft:DeleteCharacter(cls)
    local data = self:Data()
    if data.chars then data.chars[cls] = nil end
    if data.last == cls then data.last = nil end
end

-- Enter the world as this character (the first time: put on the start gear and fill the action bar)
function Craft:Login(cls)
    local data = self:Data()
    local c = data.chars and data.chars[cls]
    if not c then return false end
    data.last = cls
    self.char = c
    self.loginAt = Craft.Now()
    local cd = D.classes[cls]
    if not c.started then
        c.started = true
        for _, id in ipairs(cd.gear) do
            local it = D.items[id]
            if it then
                local slot = self.Items and self.Items.SlotFor(it, c)
                if slot and not c.equip[slot] then c.equip[slot] = id
                else self.Items.Add(id, it.stack and 4 or 1, "silent") end     -- (4 of the food and water)
            end
        end
        for slot, a in pairs(cd.bar) do
            c.bar[slot] = { a[1] == 128 and "item" or "spell", a[2] }
        end
    end
    self:Emit("login", c)
    return true
end

function Craft:Logout()
    if not self.char then return end
    self:Emit("logout", self.char)
    self.char = nil
end

---------------------------------------------------------------------------
-- Experience (WoW's formulas: cMaNGOS Formulas.h, TBC)
---------------------------------------------------------------------------

-- the level under which a mob gives nothing
function Craft.GrayLevel(pl)
    if pl <= 5 then return 0 end
    if pl <= 39 then return pl - 5 - floor(pl / 10) end
    if pl <= 59 then return pl - 1 - floor(pl / 5) end
    return pl - 9
end

local function ZeroDifference(pl)
    if pl < 8 then return 5 end
    if pl < 10 then return 6 end
    if pl < 12 then return 7 end
    if pl < 16 then return 8 end
    if pl < 20 then return 9 end
    if pl < 30 then return 11 end
    if pl < 40 then return 12 end
    if pl < 45 then return 13 end
    if pl < 50 then return 14 end
    if pl < 55 then return 15 end
    if pl < 60 then return 16 end
    return 17
end

-- the experience for killing a creature of level ml (elite x2) at level pl
function Craft.KillXP(pl, ml, elite, mult)
    local base
    if ml >= pl then
        local diff = min(4, ml - pl)
        base = floor(((pl * 5 + 45) * (20 + diff) / 10 + 1) / 2)
    elseif ml > Craft.GrayLevel(pl) then
        local zd = ZeroDifference(pl)
        base = floor((pl * 5 + 45) * (zd + ml - pl) / zd)
    else
        return 0
    end
    if elite then base = base * 2 end
    return floor(base * (mult or 1))
end

-- the group bonus: 2 = 1.0, 3 = 1.166, 4 = 1.3, 5 = 1.4 (each member gets its share by level)
Craft.GROUP_RATE = { 1, 1, 1.166, 1.3, 1.4 }

-- a quest's experience at level pl (RewMoneyMaxLevel based, cMaNGOS Quest::XPValue)
function Craft.QuestXP(pl, qlvl, xpm)
    if not xpm or xpm <= 0 then return 0 end
    local full
    if qlvl >= 65 then full = xpm / 6
    elseif qlvl == 64 then full = xpm / 4.8
    elseif qlvl == 63 then full = xpm / 3.6
    elseif qlvl == 62 then full = xpm / 2.4
    elseif qlvl == 61 then full = xpm / 1.2
    else full = xpm / 0.6 end
    local d = pl - qlvl
    local f = 1
    if d >= 10 then f = 0.1 elseif d == 9 then f = 0.2 elseif d == 8 then f = 0.4 elseif d == 7 then f = 0.6
    elseif d == 6 then f = 0.8 end
    -- (rounded to the next 5 like the client shows it; whole numbers below 100)
    local xp = math.ceil(full * f)
    return xp
end

function Craft:XPToLevel(level)
    return D.xp[level or (self.char and self.char.level) or 1] or 0
end

function Craft:GiveXP(amount, why)
    local c = self.char
    if not c or amount <= 0 then return end
    if c.level >= D.MAX_LEVEL then return end
    c.xp = c.xp + amount
    if why then self:Msg(why, "xp") end
    while c.level < D.MAX_LEVEL and c.xp >= self:XPToLevel(c.level) do
        c.xp = c.xp - self:XPToLevel(c.level)
        self:LevelUp()
    end
    if c.level >= D.MAX_LEVEL then c.xp = 0 end
    self:Emit("xp", c.xp, amount)
end

function Craft:LevelUp()
    local c = self.char
    local p = self.player
    local before = p and { hp = p.hpMax, mana = p.powerMax, st = { p.str, p.agi, p.sta, p.int, p.spi } }
    c.level = c.level + 1
    if p then
        p.level = c.level
        self.Combat.Recalc(p)
        p.hp = p.hpMax
        if p.powerType == Craft.POWER_MANA then p.power = p.powerMax end
    end
    self:Msg(string.format("Congratulations, you have reached level %d!", c.level), "system")
    if before and p then
        local lines = {}
        if p.hpMax > before.hp then lines[#lines + 1] = string.format("%d hit points", p.hpMax - before.hp) end
        if p.powerType == Craft.POWER_MANA and p.powerMax > before.mana then
            lines[#lines + 1] = string.format("%d mana", p.powerMax - before.mana)
        end
        if #lines > 0 then self:Msg("You have gained " .. table.concat(lines, " and ") .. ".", "system") end
        local names = { "Strength", "Agility", "Stamina", "Intellect", "Spirit" }
        local now = { p.str, p.agi, p.sta, p.int, p.spi }
        for i = 1, 5 do
            if now[i] > before.st[i] then
                self:Msg(string.format("Your %s increases by %d.", names[i], now[i] - before.st[i]), "system")
            end
        end
    end
    self:Emit("level", c.level)
end

---------------------------------------------------------------------------
-- Lifecycle: the hub registration and the per-frame update order
---------------------------------------------------------------------------

function Craft:Update(dt)
    if not self.char then return end
    self.char.played = (self.char.played or 0) + dt
    if self.World then self.World.Update(dt) end
    if self.Combat then self.Combat.Update(dt) end
    if self.Party then self.Party.Update(dt) end
end

function Craft:OnInit()
    if not ns.Games then return end
    if not ns:HasAssets(5) then return end            -- (its world, sprites and frames' art came in art set 5)
    ns.Games:Register("disastercraft", {
        name = "Disastercraft",
        desc = "A little World of Warcraft on the real map: pick a class, level up in Northshire, quest and "
            .. "fight with your guild.",
        tagline = "Your own World of Warcraft, in the guild window.",
        icon = "Interface\\Icons\\INV_Sword_04",
        order = 20,
        create = function(parent) return ns.CraftUI:CreatePanel(parent) end,
        status = function()
            local n = ns.Craft.Party and ns.Craft.Party.PlayingCount and ns.Craft.Party.PlayingCount() or 0
            if n > 0 then return string.format("%d playing now", n) end
            local chars = ns.Craft:Characters()
            local best
            for _, c in ipairs(chars) do if not best or c.level > best.level then best = c end end
            return best and string.format("Level %d %s", best.level, Craft.CLASS_NAMES[best.class] or "") or nil
        end,
    })
end
