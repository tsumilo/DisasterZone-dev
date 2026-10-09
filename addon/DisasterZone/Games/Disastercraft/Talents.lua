if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Talents.lua", ...) then return end -- DisasterZone Games/Disastercraft/Talents.lua
-- Craft.Talents: talent rows (the user's pick, 2026-10-09) instead of WoW's trees, which at a level-10 cap gave one
-- point. Every second level opens a row of three choices, one per spec of the class (Arms / Fury / Protection,
-- Fire / Frost / Arcane, Holy / Shadow / Discipline); each choice is a real TBC talent at its top rank (a passive
-- puts its aura on the hero - Combat's spell modifiers and stat auras do the rest) or a talent ability (into the
-- spellbook and onto a free action button). A row's choice changes for free, out of combat, like MoP's rows.
-- State: char.trow[row] = choice (1..3).
local addonName, ns = ...

local Craft = ns.Craft
local D = Craft.D
local Combat = Craft.Combat

local Talents = {}
Craft.Talents = Talents

-- level the row opens at, the three talent spells (top rank) in spec order
Talents.ROWS = {
    [1] = {                                                    -- Warrior: Arms, Fury, Protection
        { level = 2, spells = { 12664, 12856, 16466 } },       -- Improved Heroic Strike, Cruelty, Deflection
        { level = 4, spells = { 12697, 12666, 12753 } },       -- Improved Charge, Improved Thunder Clap, Anticipation
        { level = 6, spells = { 12659, 13002, 16492 } },       -- Improved Rend, Unbridled Wrath, Blood Craze
        { level = 8, spells = { 12296, 13048, 12764 } },       -- Anger Management, Enrage, Toughness
        { level = 10, spells = { 12294, 23881, 12809 } },      -- Mortal Strike, Bloodthirst, Concussion Blow
    },
    [8] = {                                                    -- Mage: Fire, Frost, Arcane
        { level = 2, spells = { 12341, 16766, 12503 } },       -- Improved Fireball, Improved Frostbolt, Arcane Mind
        { level = 4, spells = { 11368, 12953, 15060 } },       -- Critical Mass, Piercing Ice, Arcane Instability
        { level = 6, spells = { 12360, 12475, 28574 } },       -- Impact, Improved Frost Nova, Arcane Fortitude
        { level = 8, spells = { 11366, 11426, 12042 } },       -- Pyroblast, Ice Barrier, Arcane Power
        { level = 10, spells = { 11113, 12472, 31589 } },      -- Blast Wave, Icy Veins, Slow
    },
    [5] = {                                                    -- Priest: Holy, Shadow, Discipline
        { level = 2, spells = { 15011, 15338, 18555 } },       -- Holy Specialization, Spirit Tap, Mental Strength
        { level = 4, spells = { 18535, 15317, 14769 } },       -- Divine Fury, Improved SW: Pain, Improved PW: Shield
        { level = 6, spells = { 15017, 15310, 15356 } },       -- Searing Light, Darkness, Spiritual Healing
        { level = 8, spells = { 15237, 15407, 14752 } },       -- Holy Nova, Mind Flay, Divine Spirit
        { level = 10, spells = { 34861, 15473, 10060 } },      -- Circle of Healing, Shadowform, Power Infusion
    },
}
Talents.SPECS = { [1] = { "Arms", "Fury", "Protection" }, [8] = { "Fire", "Frost", "Arcane" },
                  [5] = { "Holy", "Shadow", "Discipline" } }

local bySpell
local function Index()
    if bySpell then return end
    bySpell = {}
    for cls, rows in pairs(Talents.ROWS) do
        for ri, row in ipairs(rows) do
            for ci, id in ipairs(row.spells) do bySpell[id] = { cls = cls, row = ri, choice = ci } end
        end
    end
end

local function C() return Craft.char end

function Talents.Rows(cls) return Talents.ROWS[cls or (C() and C().class)] or {} end
function Talents.OfSpell(spellId) Index() return bySpell[spellId] end
function Talents.Choice(c, row) c = c or C() return c and c.trow and c.trow[row] or nil end
function Talents.Open(c, row)
    c = c or C()
    local r = Talents.Rows(c and c.class)[row]
    return r ~= nil and (c.level or 1) >= r.level
end

-- -> rows open without a choice, rows chosen, rows open
function Talents.Points(c)
    c = c or C()
    local open, chosen = 0, 0
    for ri in ipairs(Talents.Rows(c and c.class)) do
        if Talents.Open(c, ri) then
            open = open + 1
            if Talents.Choice(c, ri) then chosen = chosen + 1 end
        end
    end
    return open - chosen, chosen, open
end
function Talents.Spent(c) local _, n = Talents.Points(c) return n end

-- can c pick choice ci in row ri? -> ok, why ("level" | "combat" | "same" | "unknown")
function Talents.CanChoose(c, ri, ci)
    c = c or C()
    local row = Talents.Rows(c and c.class)[ri]
    if not (row and row.spells[ci]) then return false, "unknown" end
    if not Talents.Open(c, ri) then return false, "level" end
    if Talents.Choice(c, ri) == ci then return false, "same" end
    local p = Craft.player
    if p and p.inCombat then return false, "combat" end
    return true
end

local function Drop(c, u, id)
    c.spells[id] = nil
    local a = u and Combat.FindAura(u, id)
    if a then Combat.RemoveAura(u, a, "talent") end
    for slot, act in pairs(c.bar or {}) do
        if act[1] == "spell" and act[2] == id then c.bar[slot] = nil end
    end
end

local function Take(c, u, id)
    local sp = D.spells[id]
    if not sp then return end
    c.spells[id] = true
    if Combat.IsPassive(sp) then
        if u and not Combat.FindAura(u, id) then Combat.ApplyAura(u, u, id, true) end
        return
    end
    -- an ability: onto the first free button of the main bar, as the client does with a new spell
    for _, act in pairs(c.bar or {}) do if act[1] == "spell" and act[2] == id then return end end
    c.bar = c.bar or {}
    for slot = 1, 12 do
        if not c.bar[slot] then c.bar[slot] = { "spell", id } Craft:Emit("bar") return end
    end
end

-- picks choice ci in row ri (the old choice of the row goes)
function Talents.Choose(ri, ci)
    local c = C()
    local ok, why = Talents.CanChoose(c, ri, ci)
    if not ok then
        if why == "combat" then Craft:Error("You can't change talents in combat.") end
        return false, why
    end
    local u = Craft.player
    c.trow = c.trow or {}
    local row = Talents.Rows(c.class)[ri]
    local old = c.trow[ri]
    if old then Drop(c, u, row.spells[old]) end
    c.trow[ri] = ci
    Take(c, u, row.spells[ci])
    if u then Combat.Recalc(u) end
    local sp = D.spells[row.spells[ci]]
    Craft:Msg(string.format("You have learned %s.", sp and sp.n or "?"), "system")
    Craft:Emit("talent", ri, ci)
    Craft:Emit("spell", row.spells[ci])
    return true
end

-- the hero's chosen talents on its unit (logging in, coming back to life); rows above the level are dropped
-- (a level lost to a debug command), and the old trees' points of earlier saves are taken back
function Talents.ApplyAll(u)
    local c = u and u.char
    if not c then return end
    if c.talents then
        for _, tree in ipairs((D.talents or {})[c.class] or {}) do
            for _, t in ipairs(tree.talents) do
                for _, id in ipairs(t.ranks) do
                    if c.spells[id] then
                        c.spells[id] = nil
                        local a = Combat.FindAura(u, id)
                        if a then Combat.RemoveAura(u, a, "talent") end
                    end
                end
            end
        end
        c.talents = nil
    end
    for ri, ci in pairs(c.trow or {}) do
        local row = Talents.Rows(c.class)[ri]
        local id = row and row.spells[ci]
        if id and Talents.Open(c, ri) then
            c.spells[id] = true
            local sp = D.spells[id]
            if sp and Combat.IsPassive(sp) and not Combat.FindAura(u, id) then Combat.ApplyAura(u, u, id, true) end
        elseif id then
            c.trow[ri] = nil
            c.spells[id] = nil
        end
    end
    Combat.Recalc(u)
end

-- a passive talent (kept out of the spellbook, like WoW)
function Talents.IsPassiveTalent(spellId)
    local sp = D.spells[spellId]
    return Talents.OfSpell(spellId) ~= nil and sp ~= nil and Combat.IsPassive(sp)
end

-- a new level may open a row
Craft:On("level", function() Craft:Emit("talent") end)
