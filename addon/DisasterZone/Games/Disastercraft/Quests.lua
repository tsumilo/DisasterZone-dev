if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Quests.lua", ...) then return end -- DisasterZone Games/Disastercraft/Quests.lua
-- Craft.Quests: WoW's quests of the built zones (texts and objectives: Games/Azeromon/World/Quests.lua; rewards and
-- experience: Data.lua). Kill objectives count kills (yours and your party's nearby); item objectives count the
-- real items in your bags (quest drops come from the loot tables, crates from the objects in the world); a quest
-- without objectives is done when you reach the one who takes it. Turning in: the reward text, one item of the
-- choices, the money, the experience. The log holds 20 quests, like WoW's.
-- State: char.quests[id] = { k = { [entry] = kills } }, char.done[id] = true.
local addonName, ns = ...

local Craft = ns.Craft
local D = Craft.D
local Items = Craft.Items
local Quests = {}
Craft.Quests = Quests

local floor, max, min = math.floor, math.max, math.min
local Q = (ns.AzeroWorldData and ns.AzeroWorldData.quests) or {}
Quests.Q = Q
Quests.MAX_LOG = 20

function Quests.Get(id) return Q[id] end
function Quests.Extra(id) return D.quests[id] or {} end

local function C() return Craft.char end

-- WoW's placeholders: $N name, $C class, $R race, $G male:female; $B a line break
function Quests.Text(s)
    if not s then return "" end
    local c = C()
    local name = c and c.name or "adventurer"
    local class = c and Craft.CLASS_NAMES[c.class] or "adventurer"
    local female = c and c.sex == 1
    s = s:gsub("%$[Bb]", "\n"):gsub("%$[Nn]", name):gsub("%$[Cc]", class:lower()):gsub("%$[Rr]", "human")
    s = s:gsub("%$[Gg]%s*([^:;]*):([^;]*);", function(m, f) return female and f or m end)
    return s
end

function Quests.State(id) local c = C() return c and c.quests[id] end
function Quests.IsDone(id) local c = C() return c and c.done[id] or false end

function Quests.Count()
    local n = 0
    for _ in pairs(C().quests) do n = n + 1 end
    return n
end

local function ClassOk(q)
    if not q.classes then return true end
    local m = Craft.CLASS_MASK[C().class] or 0
    return Craft.Combat.band(q.classes, m) ~= 0
end

-- can be taken now (prerequisites, class); low = it needs a higher level
function Quests.Available(q)
    local c = C()
    if c.quests[q.id] or c.done[q.id] then return false end
    if q.prev and q.prev > 0 and not c.done[q.prev] then return false end
    if q.prev and q.prev < 0 and not c.quests[-q.prev] then return false end
    if not ClassOk(q) then return false end
    return true, (q.min or 1) > c.level
end

function Quests.ItemCount(it) return Items.Count(it.id) end

function Quests.Complete(id)
    local q, st = Q[id], Quests.State(id)
    if not q or not st then return false end
    for _, k in ipairs(q.kill or {}) do
        if (st.k[k.entry] or 0) < k.count then return false end
    end
    for _, it in ipairs(q.items or {}) do
        local src = Quests.Extra(id).src
        local need = it.count
        -- (an item the quest giver hands you to carry - a letter - is not something to collect)
        if not (src and src[1] == it.id and #(it.from or {}) == 0) then
            if Items.Count(it.id) < need then return false end
        end
    end
    return true
end

-- "Kobold Vermin slain: 3/10" lines
function Quests.Progress(id)
    local q, st = Q[id], Quests.State(id)
    local out = {}
    if not q then return out end
    for _, k in ipairs(q.kill or {}) do
        local n = st and st.k[k.entry] or 0
        out[#out + 1] = { text = string.format("%s slain: %d/%d", k.name, min(n, k.count), k.count), done = n >= k.count }
    end
    local src = Quests.Extra(id).src
    for _, it in ipairs(q.items or {}) do
        if not (src and src[1] == it.id and #(it.from or {}) == 0) then
            local n = Items.Count(it.id)
            out[#out + 1] = { text = string.format("%s: %d/%d", it.name, min(n, it.count), it.count), done = n >= it.count }
        end
    end
    return out
end

-- what an NPC (by entry) has for you: done (to hand in), going (under way), offer (to take), low (too low)
function Quests.ForNpc(entry)
    local c = C()
    local done, going, offer, low = {}, {}, {}, {}
    for id, q in pairs(Q) do
        if c.quests[id] and q.ender == entry then
            if Quests.Complete(id) then done[#done + 1] = q else going[#going + 1] = q end
        elseif q.giver == entry then
            local ok, tooLow = Quests.Available(q)
            if ok then if tooLow then low[#low + 1] = q else offer[#offer + 1] = q end end
        end
    end
    local function byId(a, b) return a.id < b.id end
    table.sort(done, byId) table.sort(going, byId) table.sort(offer, byId) table.sort(low, byId)
    return done, going, offer, low
end

-- the marker over an NPC: "?" yellow (hand in), "!" yellow (offer), "?" grey (under way), "!" grey (too low)
function Quests.Marker(entry)
    if not C() then return nil end
    local done, going, offer, low = Quests.ForNpc(entry)
    if #done > 0 then return "?", false end
    if #offer > 0 then return "!", false end
    if #going > 0 then return "?", true end
    if #low > 0 and low[1].min and low[1].min <= C().level + 1 then return "!", true end
    return nil
end

function Quests.Accept(id)
    local q = Q[id]
    local c = C()
    if not q or c.quests[id] then return false end
    if Quests.Count() >= Quests.MAX_LOG then Craft:Error("Your quest log is full.") return false end
    local x = Quests.Extra(id)
    if x.src then
        if Items.Add(x.src[1], x.src[2] or 1, "quest") > 0 then return false end
    end
    c.quests[id] = { k = {}, at = Craft.Time() }
    Craft:Msg("Quest accepted: " .. q.title, "system")
    Craft:Emit("quest", id, "accepted")
    Quests.CheckDone(id)
    return true
end

function Quests.Abandon(id)
    local c = C()
    local q = Q[id]
    if not c.quests[id] then return end
    c.quests[id] = nil
    -- (the quest's own items leave with it)
    local x = Quests.Extra(id)
    if x.src then Items.Remove(x.src[1], Items.Count(x.src[1])) end
    for _, it in ipairs(q and q.items or {}) do
        local other = false
        for oid in pairs(c.quests) do
            for _, oi in ipairs(Q[oid] and Q[oid].items or {}) do if oi.id == it.id then other = true end end
        end
        local itd = D.items[it.id]
        if not other and itd and itd.c == 12 then Items.Remove(it.id, Items.Count(it.id)) end
    end
    Craft:Msg((q and q.title or "Quest") .. " abandoned.", "system")
    Craft:Emit("quest", id, "abandoned")
end

-- turns in id, with reward choice index `choice` (1..n) when the quest offers a choice
function Quests.TurnIn(id, choice)
    local q, c = Q[id], C()
    if not q or not c.quests[id] or not Quests.Complete(id) then return false end
    local x = Quests.Extra(id)
    if x.choice and #x.choice > 0 and not (choice and x.choice[choice]) then
        Craft:Error("You must choose a reward.")
        return false
    end
    -- room for the rewards
    local need = (x.choice and 1 or 0) + #(x.rew or {})
    local free = Items.FreeSlots()
    -- (the quest items handed back free their slots first)
    for _, it in ipairs(q.items or {}) do if Items.Count(it.id) > 0 then free = free + 1 end end
    if need > free then Craft:Error("Inventory is full.") return false end
    for _, it in ipairs(q.items or {}) do Items.Remove(it.id, it.count) end
    if x.src then Items.Remove(x.src[1], Items.Count(x.src[1])) end
    c.quests[id] = nil
    c.done[id] = true
    Craft:Msg(q.title .. " completed.", "system")
    local xp = Craft.QuestXP(c.level, x.lvl or q.lvl or 1, x.xpm)
    if c.level >= D.MAX_LEVEL then
        -- (at the cap the experience is paid in money, like WoW)
        if (x.xpm or 0) > 0 then Craft:AddMoney(floor(x.xpm), "silent") end
        xp = 0
    end
    if xp > 0 then Craft:GiveXP(xp, "Experience gained: " .. xp .. ".") end
    if x.money and x.money > 0 then Craft:AddMoney(x.money) end
    if x.choice and choice then
        local r = x.choice[choice]
        Items.Add(r[1], r[2] or 1, "quest")
    end
    for _, r in ipairs(x.rew or {}) do Items.Add(r[1], r[2] or 1, "quest") end
    if x.spell and Craft.Combat then
        -- (a spell the quest teaches or casts on you)
        local sp = D.spells[x.spell]
        if sp then Craft.Combat.CastSpell(Craft.player, x.spell, Craft.player, { triggered = true }) end
    end
    Craft:Emit("quest", id, "done")
    return true
end

-- "Kobold Vermin slain: 4/10"
local announced = {}
function Quests.CheckDone(id)
    if Quests.Complete(id) and not announced[id] then
        announced[id] = true
        local q = Q[id]
        Craft:Notice(q.title .. " (Complete)")
        Craft:Msg(q.title .. " (Complete)", "quest")
        Craft:Emit("quest", id, "complete")
    elseif not Quests.Complete(id) then
        announced[id] = nil
    end
end

function Quests.OnKill(u)
    local c = C()
    if not c then return end
    local entry = u.entry
    local credit = u.cr and u.cr.credit
    for id, st in pairs(c.quests) do
        local q = Q[id]
        for _, k in ipairs(q and q.kill or {}) do
            if (k.entry == entry or k.entry == credit) and (st.k[k.entry] or 0) < k.count then
                st.k[k.entry] = (st.k[k.entry] or 0) + 1
                Craft:Notice(string.format("%s slain: %d/%d", k.name, st.k[k.entry], k.count))
                Craft:Emit("quest", id, "progress")
                Quests.CheckDone(id)
            end
        end
    end
end

-- does any quest still need this item?
function Quests.NeedsItem(item)
    local c = C()
    if not c then return false end
    for id in pairs(c.quests) do
        local q = Q[id]
        for _, it in ipairs(q and q.items or {}) do
            if it.id == item and Items.Count(item) < it.count then return true end
        end
    end
    return false
end

Craft:On("item", function(id, n)
    local c = C()
    if not c or not id or not n then return end
    for qid in pairs(c.quests) do
        local q = Q[qid]
        for _, it in ipairs(q and q.items or {}) do
            if it.id == id and #(it.from or {}) > 0 then
                if n > 0 then
                    Craft:Notice(string.format("%s: %d/%d", it.name, min(Items.Count(id), it.count), it.count))
                end
                Craft:Emit("quest", qid, "progress")
                Quests.CheckDone(qid)
            end
        end
    end
end)

-- objects that give quest items (Milly's Harvest crates): `from` = { -objectEntry, chance }
function Quests.ObjectWanted(o)
    local c = C()
    if not c then return false end
    if o.usedUntil and Craft.World.Clock() < o.usedUntil then return false end
    for id in pairs(c.quests) do
        local q = Q[id]
        for _, it in ipairs(q and q.items or {}) do
            for _, src in ipairs(it.from or {}) do
                if src[1] == -o.e.e and Items.Count(it.id) < it.count then return it end
            end
        end
    end
    return false
end

function Quests.UseObject(o)
    local it = Quests.ObjectWanted(o)
    if not it then return false end
    local p = Craft.player
    -- a short "opening" cast, then the crate is yours (and gone for a while)
    p.casting = { spell = 0, opening = o, start = Craft.Now(), ends = Craft.Now() + 1.5, name = "Opening",
                  target = p, push = 0 }
    Craft:Emit("cast", p, 0, "start", p)
    return true
end

-- the opening cast finished (Combat's clock knows no spell 0: the World's tick finishes it)
function Quests.FinishOpening(p)
    local o = p.casting and p.casting.opening
    p.casting = nil
    if not o then return end
    local it = Quests.ObjectWanted(o)
    if not it then return end
    if Items.Add(it.id, 1, "loot") == 0 then
        o.usedUntil = Craft.World.Clock() + 120
    end
    Craft:Emit("cast", p, 0, "done", p)
end

-- an item that starts a quest (right-click it in the bags)
function Quests.OfferFromItem(itemId)
    local it = D.items[itemId]
    local q = it and it.quest and Q[it.quest]
    if not q then Craft:Error("You can't use that item.") return false end
    Craft:Emit("questoffer", q, nil)
    return true
end

-- the quest log: { { id, title, level, done, lines } } by level
function Quests.Log()
    local c = C()
    local out = {}
    for id in pairs(c.quests) do
        local q = Q[id]
        if q then
            out[#out + 1] = { id = id, title = q.title, level = q.lvl or 1, done = Quests.Complete(id),
                              lines = Quests.Progress(id), goal = Quests.Text(q.goal) }
        end
    end
    table.sort(out, function(a, b) if a.level ~= b.level then return a.level < b.level end return a.id < b.id end)
    return out
end

-- WoW's quest difficulty colours by the level difference
function Quests.Color(qlvl, plvl)
    local d = (qlvl or 1) - (plvl or 1)
    if d >= 5 then return 1, 0.1, 0.1 end
    if d >= 3 then return 1, 0.5, 0.25 end
    if d >= -2 then return 1, 0.82, 0 end
    if qlvl > Craft.GrayLevel(plvl) then return 0.25, 0.75, 0.25 end
    return 0.5, 0.5, 0.5
end

Craft:On("login", function() announced = {} end)
