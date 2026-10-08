if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Npc.lua", ...) then return end -- DisasterZone Games/Disastercraft/Npc.lua
-- Craft.Npc: what NPCs offer when you talk to them - the gossip window's lines (their real greeting, their quests,
-- "I want to browse your goods", "I seek training"), class trainers (each spell rank at its real level and price),
-- vendors (their real stock), the spirit healer. The spellbook's view of what you know lives here too.
local addonName, ns = ...

local Craft = ns.Craft
local D = Craft.D
local Combat = Craft.Combat
local Npc = {}
Craft.Npc = Npc

local floor, max, min = math.floor, math.max, math.min

local function C() return Craft.char end

local function HasRole(u, role)
    for _, r in ipairs(u.cr and u.cr.roles or {}) do if r == role then return true end end
    return false
end
Npc.HasRole = HasRole

-- the gossip window: { text = greeting, quests = { { q, kind = "done"|"going"|"offer" } }, options = { { text,
-- icon, action } } }
function Npc.Gossip(u)
    local cr = u.cr or {}
    local g = { npc = u, text = cr.say and Craft.Quests.Text(cr.say) or nil, quests = {}, options = {} }
    local done, going, offer = Craft.Quests.ForNpc(u.entry)
    for _, q in ipairs(done) do g.quests[#g.quests + 1] = { q = q, kind = "done" } end
    for _, q in ipairs(offer) do g.quests[#g.quests + 1] = { q = q, kind = "offer" } end
    for _, q in ipairs(going) do g.quests[#g.quests + 1] = { q = q, kind = "going" } end
    if HasRole(u, "vendor") and D.vendors[u.entry] then
        g.options[#g.options + 1] = { text = "I want to browse your goods.", icon = "Vendor", action = "vendor" }
    end
    if cr.trainer then
        if cr.tcls == C().class then
            g.options[#g.options + 1] = { text = "I seek training.", icon = "Trainer", action = "trainer" }
        elseif not g.text then
            g.text = string.format("I can only train %ss, %s.", (Craft.CLASS_NAMES[cr.tcls] or "?"):lower(),
                                   Craft.CLASS_NAMES[C().class]:lower())
        end
    end
    if HasRole(u, "inn") then
        g.options[#g.options + 1] = { text = "Make this inn your home.", icon = "Binder", action = "bind" }
    end
    if not g.text then
        g.text = (u.title and ("Greetings, " .. C().name .. ".")) or "Light be with you."
    end
    return g
end

-- talking skips the gossip window when there is only one thing to do (like WoW): returns that thing or nil
function Npc.Direct(g)
    if #g.quests == 0 and #g.options == 1 and not (g.npc.cr and g.npc.cr.say) then return g.options[1].action end
    return nil
end

function Npc.Bind(u)
    local c = C()
    c.bind = { map = u.map, x = u.x, y = u.y + 1, name = Craft.World.MapName(u.map, u.x, u.y) }
    Craft:Msg(c.bind.name .. " is now your home.", "system")
end

---------------------------------------------------------------------------
-- Trainers
---------------------------------------------------------------------------

-- the trainer's list: { { spell, cost, level, state = "available"|"unavailable"|"used", why } }
function Npc.TrainerList(u)
    local c = C()
    local list = {}
    local rows = D.trainers[u.cr.trainer] or {}
    for _, r in ipairs(rows) do
        local id, cost, lvl, req = r[1], r[2], r[3], r[4]
        local sp = D.spells[id]
        if sp then
            local state = "available"
            local why
            if c.spells[id] then state = "used"
            elseif lvl > c.level then state = "unavailable" why = "Requires level " .. lvl
            elseif sp.prev and not c.spells[sp.prev] then state = "unavailable" why = "Requires " .. sp.n .. " (" .. (D.spells[sp.prev] and D.spells[sp.prev].r or "Rank 1") .. ")"
            elseif req and not c.spells[req] then state = "unavailable" why = "Requires " .. (D.spells[req] and D.spells[req].n or "?") end
            list[#list + 1] = { spell = id, cost = cost, level = lvl, state = state, why = why }
        end
    end
    table.sort(list, function(a, b)
        local order = { available = 1, unavailable = 2, used = 3 }
        if order[a.state] ~= order[b.state] then return order[a.state] < order[b.state] end
        if a.level ~= b.level then return a.level < b.level end
        return a.spell < b.spell
    end)
    return list
end

function Npc.Learn(id, cost)
    local c = C()
    local sp = D.spells[id]
    if not sp or c.spells[id] then return false end
    if Craft:Money() < cost then Craft:Error("You don't have enough money.") return false end
    Craft:AddMoney(-cost, "silent")
    c.spells[id] = true
    Craft:Msg(string.format("You have learned a new %s: %s.", Combat.IsPassive(sp) and "ability" or "spell",
                            sp.n .. (sp.r and (" (" .. sp.r .. ")") or "")), "system")
    -- a higher rank takes the place of the lower on the action bar
    if sp.prev then
        for slot, a in pairs(c.bar) do
            if a[1] == "spell" then
                local cur = D.spells[a[2]]
                if cur and (cur.first or a[2]) == (sp.first or id) and (cur.rank or 1) < (sp.rank or 1) then a[2] = id end
            end
        end
    end
    if Craft.player then Combat.Recalc(Craft.player) end
    Craft:Emit("spell", id)
    return true
end

---------------------------------------------------------------------------
-- The spellbook: the highest known rank of each spell, by tab
---------------------------------------------------------------------------

local HIDDEN = { [81] = true, [6603] = false }
-- the spellbook's tabs like WoW's: General, then the class's skill lines (Arcane, Fire, Frost ...), each { name,
-- icon, list of spell ids } in level order; the highest rank of each spell only, unless allRanks
function Npc.Spellbook(allRanks)
    local c = C()
    local best = {}
    for id in pairs(c.spells) do
        local sp = D.spells[id]
        if sp and not HIDDEN[id] then
            local key = allRanks and id or (sp.first or id)
            local cur = best[key]
            if not cur or (sp.rank or 1) > (D.spells[cur].rank or 1) then best[key] = id end
        end
    end
    local tabs, byLine = {}, {}
    local general = { name = "General", icon = "Interface\\Icons\\INV_Misc_Book_09", list = {} }
    for _, id in pairs(best) do
        local sp = D.spells[id]
        local line = (id ~= 6603 and id ~= 5019) and (sp.line or Craft.CLASS_NAMES[c.class]) or nil
        if not line then
            table.insert(general.list, id)
        else
            if not byLine[line] then
                byLine[line] = { name = line, icon = D.skillLines and D.skillLines[line], list = {} }
                tabs[#tabs + 1] = byLine[line]
            end
            table.insert(byLine[line].list, id)
        end
    end
    local function byLevel(a, b)
        local la, lb = D.spells[a].lvl or 1, D.spells[b].lvl or 1
        if la ~= lb then return la < lb end
        if D.spells[a].n ~= D.spells[b].n then return D.spells[a].n < D.spells[b].n end
        return (D.spells[a].rank or 1) < (D.spells[b].rank or 1)
    end
    table.sort(tabs, function(x, y) return x.name < y.name end)
    table.insert(tabs, 1, general)
    for _, t in ipairs(tabs) do table.sort(t.list, byLevel) end
    return tabs
end


---------------------------------------------------------------------------
-- Vendors
---------------------------------------------------------------------------

-- the stock: { { id, price (for its stack), count (per purchase) } }
function Npc.Stock(u)
    local out = {}
    for _, r in ipairs(D.vendors[u.entry] or {}) do
        local it = D.items[r[1]]
        if it then out[#out + 1] = { id = r[1], price = it.buy or 0, count = it.bc or 1, limited = r[2] } end
    end
    return out
end

---------------------------------------------------------------------------
-- The action bar (char.bar[1..24] = { "spell" | "item", id })
---------------------------------------------------------------------------

function Npc.UseAction(slot)
    local c = C()
    local a = c and c.bar[slot]
    local p = Craft.player
    if not a or not p then return end
    if p.ghost then Craft:Error("You can't do that while dead.") return end
    if a[1] == "spell" then
        local id = a[2]
        if not c.spells[id] then return end
        if id == 6603 then                                -- Attack toggles
            if p.attacking then Combat.StopAttack(p) else Combat.StartAttack(p) end
            return
        end
        if p.sitting then Craft.World.StandUp(p) end
        Combat.CastSpell(p, id)
    elseif a[1] == "item" then
        Craft.Items.UseById(a[2])
    end
end

function Npc.PlaceAction(slot, kind, id)
    local c = C()
    local old = c.bar[slot]
    c.bar[slot] = kind and { kind, id } or nil
    Craft:Emit("bar")
    return old
end
