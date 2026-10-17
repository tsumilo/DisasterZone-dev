if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Battle.lua", ...) then return end -- DisasterZone Games/Azeromon/Battle.lua
-- ns.AzeroBattle: a pure single battle (no frames). The UI plays back `b.events` one by one and asks
-- for input whenever `b.need` is set:
--   "action"  pick Fight / Bag / Party / Run      -> b:Act{ kind = "move", idx } | { kind = "item", item, target }
--                                                    | { kind = "switch", idx } | { kind = "run" }
--   "switch"  the active creature fainted         -> b:Act{ kind = "switch", idx }
--   "learn"   a creature wants a 5th move         -> b:ResolveLearn(slot or nil)
--   "done"    b.result = "win" | "lose" | "run" | "caught"
-- Events: { t = "text", text } { t = "send", side, mon } { t = "recall", side } { t = "attack", side, move }
--         { t = "sfx", sound } (a Sound.lua effect at that point of the playback)
--         { t = "hp", side, from, to, max } { t = "faint", side } { t = "status", side } { t = "exp", mon }
--         { t = "level", mon } { t = "throw", shakes, caught } { t = "end", result }
--         0.39: { t = "tamed", sp, lvl, shiny, fresh (new in the Bestiary), where = "party" | "box" } (after the catch)
--         0.37: { t = "cast", side, move } (announced, lands next turn) { t = "castend", side, interrupted }
--         { t = "interrupt", side } { t = "unstoppable", side } { t = "mark", side, mark, turns } { t = "guard", side }
--         { t = "combo", side } (a payoff hit while its mark was up)
-- Sides: "ally" (the player) and "foe".
-- 0.37 rules (Data.lua "0.37 battles"): moves rest `cd` turns after use; setups leave timed marks that payoffs cash
-- in; big moves are casts that land a turn later and can be guarded or interrupted; every hit does 1 / D.BATTLE_HP of
-- the Gen III damage (a boss: its own D.BOSS_HP), so fights last ~5 turns. A side: cd[slot], marks[id], cast, guard.
local addonName, ns = ...

local B = {}
B.__index = B
ns.AzeroBattle = B
local D = ns.AzeroData
local M = ns.AzeroMon

local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt

local STRUGGLE = { name = "Struggle", type = "NONE", power = 50, acc = 0, pp = 1, recoil = 4 }

local function Stage(s)
    if s >= 0 then return (2 + s) / 2 end
    return 2 / (2 - s)
end

local function NewSide(mon)
    return { mon = mon, stages = { atk = 0, def = 0, spa = 0, spd = 0, spe = 0 }, cd = {}, marks = {}, guard = 0, guardT = 0 }
end

-- opts = { party, foes = { mon, ... }, wild = bool, trainer = def|nil, bag = { item = n }, rng = fn,
--          onSeen = fn(sp), onCaught = fn(mon) -> "party"|"box" }
function B.New(opts)
    local b = setmetatable({}, B)
    b.party = opts.party
    b.foes = opts.foes
    b.wild = opts.wild and true or false
    b.trainer = opts.trainer
    b.bag = opts.bag or {}
    b.rng = opts.rng or math.random
    b.onSeen, b.onCaught = opts.onSeen, opts.onCaught
    b.isNew = opts.isNew           -- fn(sp): true when this species was never tamed before (the tamed card)
    b.catchMult, b.expMult = opts.catchMult or 1, opts.expMult or 1     -- class perks (never in player battles)
    b.prizeMult, b.perk = opts.prizeMult or 1, opts.perk
    b.events = {}
    b.learnQueue = {}
    b.runs = 0
    b.turn = 0
    b.leveled = {}             -- [mon] = true (evolution checks after the battle)
    b.foeIdx = 1
    b.foe = NewSide(b.foes[1])
    b.foe.participants = {}
    local lead = M.FirstUsable(b.party) or 1
    b.allyIdx = lead
    b.ally = NewSide(b.party[lead])

    local foeName = M.Name(b.foe.mon)
    b.pvp = opts.pvp          -- { host = bool, name = opponent, onAction = fn(action), onResolve = fn(a1, a2),
                              --   watch = { ally = p1's name, foe = p2's name } when only watching } for player battles
    if b.pvp and b.pvp.watch then
        -- a spectator's copy: p1 on the ally side, p2 on the foe side; the intro comes from WatchIntro
        b.trainer = { name = b.pvp.name }
        b.used = {}
        b.need = "watch"
        return b
    elseif b.pvp then
        b.trainer = { name = b.pvp.name }
        b:Say("%s wants to battle!", b.pvp.name)
        b:Emit({ t = "send", side = "foe", mon = b.foe.mon })
        b:Say("%s sent out %s!", b.pvp.name, foeName)
    elseif b.wild then
        b.legendary = opts.legendary and true or nil
        if opts.legendary then
            b:Say("The legendary %s blocks the way!", foeName)
        else
            b:Say(opts.rare and "A rare %s appeared!" or "A wild %s appeared!", foeName)
        end
        b:Emit({ t = "send", side = "foe", mon = b.foe.mon })
    else
        b:Say("%s would like to battle!", b.trainer.name)
        b:Emit({ t = "send", side = "foe", mon = b.foe.mon })
        b:Say(foeName == b.trainer.name and "%s joins the fight!" or "%s sent out %s!", b.trainer.name, foeName)
    end
    if b.onSeen then b.onSeen(b.foe.mon.sp) end
    b:Say("Go! %s!", M.Name(b.ally.mon))
    b:Emit({ t = "send", side = "ally", mon = b.ally.mon })
    if opts.startAtk and not b.wild and not b.pvp then                 -- warrior: Battle Shout
        b.ally.stages.atk = math.min(6, b.ally.stages.atk + opts.startAtk)
        b:Say("Battle Shout! %s's Attack rose!", M.Name(b.ally.mon))
    end
    b.foe.participants[lead] = true
    b.used = { [lead] = true }         -- party slots that fought (achievements: "without a Fire type")
    b.need = "action"
    return b
end

-- Every event carries a snapshot of both sides as they are right after it, so the UI shows the state
-- of the moment being played back, not the end of the turn the engine already resolved.
local STAGE_STATS = { "atk", "def", "spa", "spd", "spe" }

local function Snap(s)
    if not s or not s.mon then return nil end
    local m = s.mon
    local stages
    for _, st in ipairs(STAGE_STATS) do
        local v = s.stages and s.stages[st]
        if v and v ~= 0 then
            stages = stages or {}
            stages[st] = v
        end
    end
    local marks
    for id, n in pairs(s.marks or {}) do
        if n > 0 then marks = marks or {} marks[id] = n end
    end
    local cast = s.cast and { name = s.cast.mv.name, unstoppable = s.cast.mv.unstoppable and true or nil,
                              power = s.cast.mv.power or 0 } or nil
    return { sp = m.sp, name = M.Name(m), lvl = m.lvl, hp = m.hp, max = M.MaxHP(m), status = m.status, exp = M.ExpProgress(m),
             shiny = m.shiny, stages = stages, sleep = (m.status == "slp") and m.sleep or nil,
             flask = m.flask and { id = m.flask.id, n = m.flask.n } or nil,
             marks = marks, cast = cast, guard = ((s.guardT or 0) > 0) and s.guardT or nil }
end

function B:Emit(e)
    e.snap = { ally = Snap(self.ally), foe = Snap(self.foe) }
    self.events[#self.events + 1] = e
end

function B:Say(fmt, ...)
    self:Emit({ t = "text", text = select("#", ...) > 0 and string.format(fmt, ...) or fmt })
end

-- Next event for the UI (nil when drained).
function B:Pop()
    return table.remove(self.events, 1)
end

function B:SideName(side)
    local mon = self[side].mon
    if side == "foe" and self.pvp then return self.pvp.name .. "'s " .. M.Name(mon) end
    if self.pvp and self.pvp.watch then return self.pvp.watch.ally .. "'s " .. M.Name(mon) end
    if side == "foe" then return (self.wild and "Wild " or "Foe ") .. M.Name(mon) end
    return M.Name(mon)
end

---------------------------------------------------------------------------
-- Stats and damage
---------------------------------------------------------------------------

function B:EffStat(side, stat, crit, attacking)
    local s = self[side]
    local v = M.Stat(s.mon, stat)
    local st = s.stages[stat] or 0
    if crit then
        if attacking and st < 0 then st = 0 end
        if not attacking and st > 0 then st = 0 end
    end
    v = v * Stage(st)
    if stat == "spe" and s.mon.status == "par" then v = v / 4 end
    if stat == "spe" and (s.marks.chill or 0) > 0 then v = v * D.MARKS.chill.speed end
    if stat == "atk" and s.mon.status == "brn" and attacking then v = v / 2 end
    return max(1, v)
end

-- A payoff move's mark (or status) is up: on the target, or on the user itself (Mech's charge).
function B:PayoffActive(side, mv)
    local p = mv.payoff
    if not p then return false end
    local t = self[p.self and side or (side == "ally" and "foe" or "ally")]
    if p.mark then return (t.marks[p.mark] or 0) > 0 end
    return p.status ~= nil and t.mon.status == p.status
end

-- What a hit on `side` is divided by: battles last ~5 turns (D.BATTLE_HP). A boss beast can have its own number
-- (D.BOSS_HP), and so can a whole boss team led by an ordinary beast (D.TEAM_HP, by trainer id).
function B:HpScale(side)
    local t = side == "foe" and not self.pvp and not self.wild and self.trainer      -- (never the player's own beasts)
    if t then
        local sp = self[side].mon.sp
        if D.BOSS_HP and D.BOSS_HP[sp] then return D.BOSS_HP[sp] end
        if t.id and D.TEAM_HP and D.TEAM_HP[t.id] then return D.TEAM_HP[t.id] end
    end
    return D.BATTLE_HP or 1
end

-- Returns damage, effectiveness, crit, combo (a payoff hit while its mark was up).
function B:Damage(atkSide, defSide, mv, forceCrit)
    local attacker, defender = self[atkSide].mon, self[defSide].mon
    local physical = mv.type == "NONE" or (D.types[mv.type] and D.types[mv.type].physical)
    local crit = forceCrit
    if crit == nil then crit = self.rng(1, 16) == 1 end
    local A = self:EffStat(atkSide, physical and "atk" or "spa", crit, true)
    local Dv = self:EffStat(defSide, physical and "def" or "spd", crit, false)
    local power, e = mv.power, mv.effect
    if e and (e.kind == "vsstatus" or e.kind == "consume") and defender.status == e.status then
        power = floor(power * e.mult)                   -- Lava Burst on a burn, Conflagrate
    end
    local combo = self:PayoffActive(atkSide, mv)
    if combo then power = floor(power * mv.payoff.mult) end
    local base = floor(floor(floor(2 * attacker.lvl / 5 + 2) * power * A / Dv) / 50) + 2
    local eff = mv.type == "NONE" and 1 or D.Effectiveness(mv.type, D.species[defender.sp].type)
    if e and e.kind == "noresist" and eff > 0 and eff < 1 then eff = 1 end          -- Steam Jet
    if mv.noImmune and eff == 0 then eff = 0.5 end                                 -- Rock Throw reaches fliers
    local stab = (mv.type == D.species[attacker.sp].type) and 1.5 or 1
    local roll = mv.tick and 92 or self.rng(85, 100)    -- a mark's tick is fixed when it lands: no dice
    local dmg = base * (crit and 2 or 1) * stab * eff * roll / 100
    -- gear and flasks: a Fiery Chain Girdle takes the edge off fire, a Flask of Flowing Water sharpens water
    dmg = dmg * M.TypeMult(attacker, "typePower", mv.type) * M.TypeMult(defender, "resist", mv.type)
    dmg = dmg / self:HpScale(defSide)
    local ds = self[defSide]
    if (ds.guardT or 0) > 0 and not mv.tick then dmg = dmg * (ds.guard or 1) end
    dmg = floor(dmg)
    if eff > 0 then dmg = max(1, dmg) else dmg = 0 end
    return dmg, eff, crit, combo
end

function B:SetHP(side, hp)
    local mon = self[side].mon
    local from = mon.hp
    mon.hp = max(0, min(M.MaxHP(mon), floor(hp)))
    if mon.hp ~= from then
        self:Emit({ t = "hp", side = side, from = from, to = mon.hp, max = M.MaxHP(mon) })
    end
end

---------------------------------------------------------------------------
-- Moves
---------------------------------------------------------------------------

local function Other(side) return side == "ally" and "foe" or "ally" end

-- pierce: burns even a FIRE type (Shadow Flame); otherwise FIRE types can't be burned (Gen III).
function B:ApplyStatus(side, status, pierce)
    local mon = self[side].mon
    if mon.status or mon.hp <= 0 then return false end
    if status == "brn" and not pierce and D.species[mon.sp].type == "FIRE" then return false end
    mon.status = status
    if status == "slp" then mon.sleep = self.rng(1, 3) end
    self:Emit({ t = "status", side = side })
    self:Emit({ t = "sfx", sound = status })
    self:Say("%s is %s!", self:SideName(side), D.status[status].name)
    return true
end

function B:StatChange(target, stat, stages, damaged)
    local s = self[target]
    local cur = s.stages[stat]
    local nxt = max(-6, min(6, cur + stages))
    if nxt == cur then
        if not damaged then
            self:Say("%s's %s won't go any %s!", self:SideName(target), D.statNames[stat], stages > 0 and "higher" or "lower")
        end
        return
    end
    s.stages[stat] = nxt
    self:Emit({ t = "sfx", sound = stages > 0 and "statup" or "statdown" })
    self:Say("%s's %s %s!", self:SideName(target), D.statNames[stat], stages > 0 and "rose" or "fell")
end

-- Is `side` held by Magma Shackles / a Burning Web? Only while the beast that trapped it is still out.
function B:Trapped(side)
    local s, o = self[side], self[Other(side)]
    return s.trappedBy ~= nil and s.trappedBy == o.mon and o.mon.hp > 0
end

-- A timed mark on `side` (D.MARKS): bleed, chill, corrupt, ... (refreshed when it is already there)
-- src/mv: who put it there and with what; a damage-over-time mark fixes its tick from them now.
function B:Mark(side, mk, src, mv)
    local s = self[side]
    if not s or s.mon.hp <= 0 or not D.MARKS[mk.id] then return end
    local again = (s.marks[mk.id] or 0) > 0
    s.marks[mk.id] = mk.turns or 2
    s.tick = s.tick or {}
    s.tick[mk.id] = nil
    if D.MARKS[mk.id].dot and src and src ~= side and mv then
        s.tick[mk.id] = self:Damage(src, side, { power = D.MARK_DOT_POWER or 22, type = mv.type, tick = true }, false)
    end
    self:Emit({ t = "mark", side = side, mark = mk.id, turns = s.marks[mk.id] })
    self:Emit({ t = "sfx", sound = mk.who == "self" and "statup" or "statdown" })
    self:Say(again and "%s is %s again!" or "%s is %s!", self:SideName(side), D.MARKS[mk.id].name:lower())
end

-- The cast on `side` breaks (an interrupt, sleep, a flinch, fear): its move rests its cooldown, as if used.
function B:BreakCast(side, why)
    local s = self[side]
    local c = s.cast
    if not c then return end
    s.cast = nil
    if c.slot then s.cd[c.slot] = (c.mv.cd or 0) + 1 end
    self:Emit({ t = "castend", side = side, interrupted = true })
    self:Say("%s's %s fizzles%s!", self:SideName(side), c.mv.name, why and (" (" .. why .. ")") or "")
end

-- An interrupting hit on `side`: breaks its cast, unless the cast can't be interrupted.
function B:Interrupt(side)
    local c = self[side].cast
    if not c or self[side].mon.hp <= 0 then return end
    if c.mv.unstoppable then
        self:Emit({ t = "unstoppable", side = side })
        self:Say("%s can't be interrupted!", c.mv.name)
        return
    end
    self:Emit({ t = "interrupt", side = side })
    self:Emit({ t = "sfx", sound = "immune" })
    self:BreakCast(side, "interrupted")
end

-- A flinch: the beast on `side` loses its move if it has not moved yet this turn (cleared at the end of the turn).
function B:Flinch(side)
    self.flinch = self.flinch or {}
    self.flinch[side] = true
end

function B:ApplyEffect(side, mv, damaged)
    local e = mv.effect
    if not e then return end
    if e.kind == "armor" then                       -- Molten Armor: on the user
        self[side].armor = e.turns
        self:Emit({ t = "sfx", sound = "statup" })
        self:Say("%s is sheathed in molten armor!", self:SideName(side))
        return
    end
    local target = (e.who == "self") and side or Other(side)
    local s = self[target]
    if s.mon.hp <= 0 then return end
    if e.kind == "trap" then
        if not self:Trapped(target) then
            s.trappedBy = self[side].mon
            self:Say("%s can't escape now!", self:SideName(target))
        elseif not damaged and not e.stat then
            self:Say("But it failed!")
        end
        if e.stat then self:StatChange(target, e.stat, e.stages, damaged) end
        if e.status and (not e.chance or self.rng(1, 100) <= e.chance) then self:ApplyStatus(target, e.status, e.pierce) end
        return
    elseif e.kind == "fear" then
        s.fear, s.fearChance = e.turns, e.chance
        self:Emit({ t = "sfx", sound = "statdown" })
        self:Say("%s cowers before the roar!", self:SideName(target))
        return
    elseif e.kind == "panic" then
        if s.free then
            self:Say("%s's Free Action keeps it calm!", self:SideName(target))
        elseif s.panicked then
            self:Say("But it failed!")
        else
            s.panic, s.panicked = true, true
            self:Emit({ t = "sfx", sound = "statdown" })
            self:Say("%s panics!", self:SideName(target))
        end
        return
    elseif e.kind == "consume" then                 -- Conflagrate: the burn it fed on is gone
        if s.mon.status == e.status then
            s.mon.status = nil
            self:Emit({ t = "status", side = target })
            self:Say("%s's burn flared out!", self:SideName(target))
        end
        return
    elseif e.kind ~= "stat" and e.kind ~= "status" and e.kind ~= "flinch" then
        return                                      -- vsstatus / noresist / drain: done in the damage
    end
    local chance = e.chance or 100
    if chance < 100 and self.rng(1, 100) > chance then return end
    if e.kind == "stat" then
        self:StatChange(target, e.stat, e.stages, damaged)
    elseif e.kind == "status" then
        if not self:ApplyStatus(target, e.status, e.pierce) and not damaged then
            self:Say("But it failed!")
        end
    elseif e.kind == "flinch" then
        self:Flinch(target)
    end
end

-- Uses move `mv` from party slot `slot` (nil: Struggle). released: a cast announced last turn lands now.
-- PP is paid by the caller when a move is chosen (a cast pays when it is announced).
function B:UseMove(side, mv, slot, released)
    local user = self[side].mon
    local me = self[side]
    local target = Other(side)
    local name = self:SideName(side)
    if released and not me.cast then return end            -- broken earlier this turn (it already fizzled)

    -- status that can stop the turn (and breaks a cast)
    if user.status == "slp" then
        user.sleep = (user.sleep or 1) - 1
        if user.sleep <= 0 then
            user.status, user.sleep = nil, nil
            self:Emit({ t = "status", side = side })
            self:Emit({ t = "sfx", sound = "wake" })
            self:Say("%s woke up!", name)
        else
            self:Emit({ t = "sfx", sound = "slp" })
            self:Say("%s is fast asleep.", name)
            self:BreakCast(side, "asleep")
            return
        end
    elseif user.status == "par" and self.rng(1, 4) == 1 then
        self:Emit({ t = "sfx", sound = "par" })
        self:Say("%s is paralyzed! It can't move!", name)
        self:BreakCast(side)
        return
    end
    if self.flinch and self.flinch[side] then
        self.flinch[side] = nil
        self:Say("%s flinched and couldn't move!", name)
        self:BreakCast(side, "flinched")
        return
    end
    if me.panic then
        me.panic = nil
        self:Say("%s is panicking and can't move!", name)
        self:BreakCast(side)
        return
    end
    if (me.fear or 0) > 0 then
        me.fear = me.fear - 1
        if self.rng(1, 100) <= (me.fearChance or 50) then
            self:Say("%s is too afraid to move!", name)
            self:BreakCast(side, "afraid")
            return
        end
    end

    -- a cast: announced now, lands next turn (it can be guarded, or interrupted unless it is unstoppable)
    if mv.cast and not released then
        me.cast = { slot = slot, mv = mv }
        self:Emit({ t = "cast", side = side, move = mv })
        self:Emit({ t = "sfx", sound = "statup" })
        self:Say("%s begins %s %s!", name, mv.castVerb or "casting", mv.name)
        return
    end
    if released then
        me.cast = nil
        self:Emit({ t = "castend", side = side })
    end
    if slot and (mv.cd or 0) > 0 then me.cd[slot] = mv.cd + 1 end       -- (counted down at the end of this turn)

    self:Say(released and "%s unleashes %s!" or "%s used %s!", name, mv.name)
    self:Emit({ t = "attack", side = side, move = mv })

    if mv.acc > 0 and self.rng(1, 100) > mv.acc then
        self:Emit({ t = "sfx", sound = "miss" })
        self:Say("%s's attack missed!", name)
        return
    end

    if mv.guard then
        me.guard, me.guardT = mv.guard, mv.guardTurns or 1
        self:Emit({ t = "guard", side = side })
        self:Emit({ t = "sfx", sound = "statup" })
        self:Say("%s braces behind %s!", name, mv.name)
        return
    end
    if mv.heal then
        local before = user.hp
        self:SetHP(side, user.hp + max(1, floor(M.MaxHP(user) * mv.heal)))
        if user.hp > before then
            self:Emit({ t = "sfx", sound = "heal" })
            self:Say("%s is restored!", name)
        end
        if mv.mark then self:Mark(mv.mark.who == "self" and side or target, mv.mark, side, mv) end
        return
    end

    if mv.power > 0 then
        local dmg, eff, crit, combo = self:Damage(side, target, mv)
        if eff == 0 then
            self:Emit({ t = "sfx", sound = "immune" })
            self:Say("It doesn't affect %s...", self:SideName(target))
            return
        end
        local before = self[target].mon.hp
        self:SetHP(target, before - dmg)
        local dealt = before - self[target].mon.hp
        if combo then self:Emit({ t = "combo", side = side }) self:Say("Combo! %s hits hard!", mv.name) end
        if crit then self:Emit({ t = "sfx", sound = "crit" }) self:Say("A critical hit!") end
        if eff > 1 then
            self:Emit({ t = "sfx", sound = "super" })
            self:Say("It's super effective!")
        elseif eff < 1 then
            self:Emit({ t = "sfx", sound = "weak" })
            self:Say("It's not very effective...")
        end
        if (self[target].guardT or 0) > 0 and dealt > 0 then self:Say("%s's guard soaks most of it!", self:SideName(target)) end
        if combo and mv.payoff.consume then
            local who = mv.payoff.self and side or target
            if mv.payoff.mark and self[who].marks[mv.payoff.mark] then
                self[who].marks[mv.payoff.mark] = nil
                self:Emit({ t = "mark", side = who, mark = mv.payoff.mark, turns = 0 })
            end
        end
        if mv.interrupt then self:Interrupt(target) end
        if mv.effect and mv.effect.kind == "drain" and dealt > 0 then
            local heal = max(1, floor(dealt * mv.effect.pct / 100))
            if user.hp < M.MaxHP(user) then
                self:SetHP(side, user.hp + heal)
                self:Emit({ t = "sfx", sound = "drain" })
                self:Say("%s had its energy drained!", self:SideName(target))
            end
        elseif mv.effect then
            self:ApplyEffect(side, mv, true)
        end
        if mv.mark and self[target].mon.hp > 0 then self:Mark(mv.mark.who == "self" and side or target, mv.mark, side, mv) end
        if dealt > 0 then self:AfterHit(side, target, mv) end
        if mv.recoil and dealt > 0 then
            self:SetHP(side, user.hp - max(1, floor(dealt / mv.recoil)))
            self:Emit({ t = "sfx", sound = "recoil" })
            self:Say("%s is hit with recoil!", name)
        end
    else
        self:ApplyEffect(side, mv, false)
        if mv.mark then self:Mark(mv.mark.who == "self" and side or target, mv.mark, side, mv) end
    end
end

-- After a hit that did damage: the target's Molten Armor burns a physical attacker; a stunning weapon (Dark Iron
-- Pulverizer) may make the target flinch.
function B:AfterHit(side, target, mv)
    local user = self[side].mon
    local physical = mv.type == "NONE" or (D.types[mv.type] and D.types[mv.type].physical)
    if (self[target].armor or 0) > 0 and physical and user.hp > 0 and not user.status then
        if self:ApplyStatus(side, "brn") then
            self:Say("%s was scorched by the molten armor!", self:SideName(side))
        end
    end
    local stun = M.GearValue(user, "stun")
    if stun and self[target].mon.hp > 0 and self.rng(1, 100) <= stun then self:Flinch(target) end
end

-- End of every turn (before burn and poison), in `order`: Molten Armor cools, a regenerating piece of gear
-- (Truesilver Breastplate) heals; flinches end.
function B:TurnExtras(order)
    self.flinch = nil
    for _, side in ipairs(order) do
        local s = self[side]
        if s.armor and s.armor > 0 then
            s.armor = s.armor - 1
            if s.armor == 0 and s.mon.hp > 0 then self:Say("%s's molten armor cooled.", self:SideName(side)) end
        end
        local regen, item = M.GearValue(s.mon, "regen")
        if regen and s.mon.hp > 0 and s.mon.hp < M.MaxHP(s.mon) then
            self:SetHP(side, s.mon.hp + max(1, floor(M.MaxHP(s.mon) / regen)))
            self:Say("%s's %s restored a little HP.", self:SideName(side), item.name)
        end
    end
end

function B:HasPP(mon)
    for _, m in ipairs(mon.moves) do if m.pp > 0 then return true end end
    return false
end

-- Can `side` use the move in party slot i now (PP left, not resting)?
function B:Usable(side, i)
    local slot = self[side].mon.moves[i]
    return slot ~= nil and slot.pp > 0 and (self[side].cd[i] or 0) <= 0 and D.moves[slot.id] ~= nil
end

-- Any move `side` can use now (else it struggles).
function B:CanFight(side)
    for i in ipairs(self[side].mon.moves) do if self:Usable(side, i) then return true end end
    return false
end

-- Priority of a chosen move: a guard goes first (2), an interrupt next (1); a cast landing has none.
local function Prio(mv, released)
    if released then return 0 end
    return mv.prio or 0
end

-- End of turn for one side still standing: burn / poison, then its marks' damage or healing over time.
-- Returns true when it took damage (callers check faints).
function B:SideTicks(side)
    local mon = self[side].mon
    if mon.hp <= 0 then return false end
    local hurt = false
    if mon.status == "brn" or mon.status == "psn" then
        self:SetHP(side, mon.hp - max(1, floor(M.MaxHP(mon) / 8)))
        self:Emit({ t = "sfx", sound = mon.status })
        self:Say("%s is hurt by its %s!", self:SideName(side), mon.status == "brn" and "burn" or "poison")
        hurt = true
    end
    for _, id in ipairs({ "bleed", "immolate", "corrupt", "regrowth" }) do
        local mk = D.MARKS[id]
        if mon.hp > 0 and (self[side].marks[id] or 0) > 0 then
            if mk.dot then
                local tick = self[side].tick and self[side].tick[id]
                self:SetHP(side, mon.hp - max(1, tick or floor(M.MaxHP(mon) / (D.MARK_DOT or 12))))
                self:Emit({ t = "sfx", sound = "psn" })
                self:Say("%s suffers from %s!", self:SideName(side), mk.name:lower())
                hurt = true
            elseif mk.hot and mon.hp < M.MaxHP(mon) then
                self:SetHP(side, mon.hp + max(1, floor(M.MaxHP(mon) / mk.hot)))
                self:Say("%s is healed by %s.", self:SideName(side), mk.name)
            end
        end
    end
    return hurt
end

-- End of turn: cooldowns, marks and guards count down.
function B:Countdown(side)
    local s = self[side]
    for i, n in pairs(s.cd) do if n > 0 then s.cd[i] = n - 1 end end
    for id, n in pairs(s.marks) do
        if n > 1 then
            s.marks[id] = n - 1
        else
            s.marks[id] = nil
            if s.mon.hp > 0 then self:Emit({ t = "mark", side = side, mark = id, turns = 0 }) end
        end
    end
    if (s.guardT or 0) > 0 then
        s.guardT = s.guardT - 1
        if s.guardT <= 0 then s.guard = 0 end
    end
end

---------------------------------------------------------------------------
-- AI
---------------------------------------------------------------------------

-- The rule list a good player follows (and the foe AI, with some slop): answer a cast (interrupt it, or guard it),
-- cash in a mark, set one up, heal when low, cast big, raise a stat, else the hardest hit. Returns a party slot.
function B:Rotation(side, usable)
    local me, op = self[side], self[Other(side)]
    local moves = me.mon.moves
    local function find(f)
        for _, i in ipairs(usable) do
            local mv = D.moves[moves[i].id]
            if f(mv, i) then return i end
        end
    end
    if op.cast then
        local cm = op.cast.mv
        local i = (not cm.unstoppable) and find(function(mv) return mv.interrupt end)
        if i then return i end
        if (cm.power or 0) > 0 then
            i = find(function(mv) return mv.guard end)
            if i then return i end
        end
    end
    local i = find(function(mv) return mv.payoff and self:PayoffActive(side, mv) end)
    if i then return i end
    i = find(function(mv)
        if mv.role ~= "setup" then return false end
        if mv.mark then
            local holder = (mv.mark.who == "self") and me or op
            return (holder.marks[mv.mark.id] or 0) <= 0
        end
        if mv.effect and mv.effect.kind == "stat" then return (op.stages[mv.effect.stat] or 0) > -2 end
        return true
    end)
    if i then return i end
    if me.mon.hp < M.MaxHP(me.mon) * 0.55 then
        i = find(function(mv) return mv.heal end)
        if i then return i end
    end
    i = find(function(mv) return mv.cast and (mv.power or 0) > 0 end)
    if i then return i end
    i = find(function(mv) return mv.role == "buff" and mv.effect and (me.stages[mv.effect.stat] or 0) < 2 end)
    if i then return i end
    local best, bestScore = nil, -1
    local defType = D.species[op.mon.sp].type
    for _, k in ipairs(usable) do
        local mv = D.moves[moves[k].id]
        local score
        if mv.guard or mv.interrupt or mv.heal then
            score = 1
        elseif mv.power > 0 then
            score = mv.power * D.Effectiveness(mv.type, defType) * (mv.type == D.species[me.mon.sp].type and 1.5 or 1)
                * ((mv.acc > 0) and mv.acc / 100 or 1)
            if mv.payoff then score = score * 0.6 end              -- keep the payoff for its mark
        else
            local e = mv.effect
            score = (e and (e.kind ~= "status" or not op.mon.status)) and 25 or 0
        end
        if score > bestScore then best, bestScore = k, score end
    end
    return best or usable[1]
end

-- The foe's action: (move, slot, released). A cast it announced lands; wild beasts pick at random; trainers follow
-- the rule list, with a random pick 25 % of the time (bosses 10 %). nil move: it struggles.
function B:FoeAction()
    local s = self.foe
    if s.cast then return s.cast.mv, s.cast.slot, true end      -- (it stays up until it lands: UseMove)
    local mon = s.mon
    local usable = {}
    for i in ipairs(mon.moves) do if self:Usable("foe", i) then usable[#usable + 1] = i end end
    if #usable == 0 then return STRUGGLE, nil, false end
    local i
    local slop = (self.trainer and self.trainer.class == "boss") and 10 or 25
    if self.wild or self.rng(1, 100) <= slop then
        i = usable[self.rng(1, #usable)]
    else
        i = self:Rotation("foe", usable)
    end
    local slot = mon.moves[i]
    slot.pp = slot.pp - 1
    return D.moves[slot.id], i, false
end

-- (old name, kept for anything that still asks: the slot the foe would pick, without spending PP)
function B:FoeMoveIdx()
    local usable = {}
    for i in ipairs(self.foe.mon.moves) do if self:Usable("foe", i) then usable[#usable + 1] = i end end
    if #usable == 0 then return nil end
    if self.wild then return usable[self.rng(1, #usable)] end
    return self:Rotation("foe", usable)
end

---------------------------------------------------------------------------
-- Turn
---------------------------------------------------------------------------

function B:Act(a)
    if self.pvp then return self:ActPvP(a) end
    if self.need == "switch" then
        if a.kind ~= "switch" then return false end
        return self:ForcedSwitch(a.idx)
    end
    if self.need ~= "action" or type(a) ~= "table" then return false end
    -- a beast mid-cast is committed: its cast lands this turn, whatever was picked
    if self.ally.cast then
        if a.kind ~= "move" and a.kind ~= "release" then return false end
        a = { kind = "release" }
    end

    if a.kind == "run" then
        if not self.wild then
            self:Say("No! There's no running from a trainer battle!")
            return true
        end
        if self:Trapped("ally") then
            self:Say("%s is trapped and can't get away!", M.Name(self.ally.mon))
            return true
        end
        self.runs = self.runs + 1
        local mine, theirs = self:EffStat("ally", "spe"), self:EffStat("foe", "spe")
        local odds = floor(mine * 128 / theirs + 30 * self.runs)       -- past 255 it always works (Gen III)
        if mine >= theirs or odds > 255 or self.rng(0, 255) < odds then
            self:Emit({ t = "sfx", sound = "run" })
            self:Say("Got away safely!")
            return self:Finish("run")
        end
        self:Say("Can't escape!")
        self:FoeTurnOnly()
        return self:EndTurn()
    elseif a.kind == "item" then
        if not self:UseItem(a.item, a.target) then return false end
        if self.need == "done" then return true end
        self:FoeTurnOnly()
        return self:EndTurn()
    elseif a.kind == "switch" then
        local mon = self.party[a.idx]
        if not mon or mon.hp <= 0 or a.idx == self.allyIdx then return false end
        if self:Trapped("ally") then
            self:Say("%s is trapped and can't be recalled!", M.Name(self.ally.mon))
            return true
        end
        self:Say("%s, come back!", M.Name(self.ally.mon))
        self:Emit({ t = "recall", side = "ally" })
        self:SendAlly(a.idx)
        self:FoeTurnOnly()
        return self:EndTurn()
    elseif a.kind == "move" or a.kind == "release" then
        local mine, mySlot, myRelease
        if a.kind == "release" then
            local c = self.ally.cast
            mine, mySlot, myRelease = c.mv, c.slot, true
        elseif not self:CanFight("ally") then
            mine = STRUGGLE
        else
            local slot = self.ally.mon.moves[a.idx]
            if not slot or not self:Usable("ally", a.idx) then return false end
            slot.pp = slot.pp - 1
            mine, mySlot = D.moves[slot.id], a.idx
        end
        local theirs, theirSlot, theirRelease = self:FoeAction()
        local allyFirst
        local pa, pf = Prio(mine, myRelease), Prio(theirs, theirRelease)
        if pa ~= pf then
            allyFirst = pa > pf
        else
            local sa, sf = self:EffStat("ally", "spe"), self:EffStat("foe", "spe")
            if sa ~= sf then allyFirst = sa > sf else allyFirst = self.rng(1, 2) == 1 end
        end
        local order = allyFirst and { { "ally", mine, mySlot, myRelease }, { "foe", theirs, theirSlot, theirRelease } }
            or { { "foe", theirs, theirSlot, theirRelease }, { "ally", mine, mySlot, myRelease } }
        for _, step in ipairs(order) do
            if self.ally.mon.hp <= 0 or self.foe.mon.hp <= 0 then break end
            self:UseMove(step[1], step[2], step[3], step[4])
            if self:CheckFaints() then break end
        end
        return self:EndTurn()
    end
    return false
end

function B:FoeTurnOnly()
    if self.foe.mon.hp <= 0 or self.ally.mon.hp <= 0 then return end
    local mv, slot, released = self:FoeAction()
    self:UseMove("foe", mv, slot, released)
    self:CheckFaints()
end

-- End of turn: burn / poison on every beast still standing - also when the other one fainted this turn.
-- Returns true (the action was accepted).
function B:EndTurn()
    if self.need ~= "done" then self:TurnExtras({ "ally", "foe" }) end
    for _, side in ipairs({ "ally", "foe" }) do
        if self.need == "done" then break end
        if self:SideTicks(side) then self:CheckFaints() end
    end
    if self.need ~= "done" then
        self:Countdown("ally")
        self:Countdown("foe")
    end
    self.turn = self.turn + 1
    self:FlushLearn()
    return true
end

-- Handles fainted creatures. Returns true when the turn must stop (someone fainted).
function B:CheckFaints()
    local stop = false
    if self.foe.mon.hp <= 0 and not self.foe.fainted then
        self.foe.fainted = true
        stop = true
        self:Emit({ t = "faint", side = "foe" })
        self:Say("%s fainted!", self:SideName("foe"))
        self:AwardExp()
        if self.ally.mon.hp > 0 or M.FirstUsable(self.party) then
            local nextIdx = self.foeIdx + 1
            if not self.wild and self.foes[nextIdx] then
                self.foeIdx = nextIdx
                self.foe = NewSide(self.foes[nextIdx])
                self.foe.participants = {}
                if self.ally.mon.hp > 0 then self.foe.participants[self.allyIdx] = true end
                local nm = M.Name(self.foe.mon)
                if nm == self.trainer.name then self:Say("%s joins the fight!", nm)
                else self:Say("%s sent out %s!", self.trainer.name, nm) end
                self:Emit({ t = "send", side = "foe", mon = self.foe.mon })
                if self.onSeen then self.onSeen(self.foe.mon.sp) end
            else
                if self.wild then
                    self:Finish("win")
                else
                    local prize = math.floor((self.trainer.prize or 20) * self.foes[#self.foes].lvl * (self.prizeMult or 1))
                    self.prize = prize
                    self:Say("You defeated %s!", self.trainer.name)
                    if self.trainer.lose then self:Say("%s", self.trainer.lose) end
                    local perk = (self.prizeMult or 1) > 1 and self.perk and (" (" .. self.perk.name .. ")") or ""
                    self:Say("You got %s for winning!%s", D.Money(prize), perk)
                    self:Finish("win")
                end
                return true
            end
        end
    end
    if self.ally.mon.hp <= 0 and not self.ally.fainted then
        self.ally.fainted = true
        stop = true
        self:Emit({ t = "faint", side = "ally" })
        self:Say("%s fainted!", M.Name(self.ally.mon))
        if M.FirstUsable(self.party) then
            if self.need ~= "done" then self.need = "switch" end
        else
            self:Say("You have no beasts left that can fight!")
            self:Say("You blacked out!")
            self:Finish("lose")
        end
    end
    return stop
end

function B:AwardExp()
    local foe = self.foe.mon
    local s = D.species[foe.sp]
    local total = floor(s.exp * foe.lvl / 7 * (self.wild and 1 or 1.5) * (self.expMult or 1))
    local winners = {}
    for idx in pairs(self.foe.participants or {}) do
        local mon = self.party[idx]
        if mon and mon.hp > 0 then winners[#winners + 1] = idx end
    end
    table.sort(winners)
    if #winners == 0 then return end
    local each = max(1, floor(total / #winners))
    for _, idx in ipairs(winners) do
        local mon = self.party[idx]
        if mon.lvl < D.MAX_LEVEL then
            local gain = mon.traded and math.floor(each * 1.5) or each      -- a traded beast: boosted, like the games
            local perk = (self.expMult or 1) > 1 and self.perk and (" (" .. self.perk.name .. ")") or ""
            self:Say((mon.traded and "%s gained a boosted %d Exp. Points!" or "%s gained %d Exp. Points!") .. "%s",
                M.Name(mon), gain, perk)
            local levels = M.AddExp(mon, gain)
            self:Emit({ t = "exp", mon = mon })
            for _, lvl in ipairs(levels) do
                self.leveled[mon] = true
                self:Emit({ t = "level", mon = mon })
                self:Say("%s grew to level %d!", M.Name(mon), lvl)
                for _, id in ipairs(M.NewMovesAt(mon, lvl)) do
                    if M.TryLearn(mon, id) then
                        self:Say("%s learned %s!", M.Name(mon), D.moves[id].name)
                    else
                        self.learnQueue[#self.learnQueue + 1] = { mon = mon, move = id }
                    end
                end
            end
        end
    end
end

-- Pauses for pending "learn a 5th move" choices, keeping what comes after.
function B:FlushLearn()
    if #self.learnQueue == 0 or self.need == "learn" then return end
    self.afterLearn = self.need
    local q = self.learnQueue[1]
    self:Say("%s wants to learn %s. But %s already knows four moves.", M.Name(q.mon), D.moves[q.move].name, M.Name(q.mon))
    self:Say("Which move should be forgotten?")
    self.need = "learn"
    self.learning = q
end

function B:ResolveLearn(slot)
    if self.need ~= "learn" then return false end
    local q = table.remove(self.learnQueue, 1)
    local mon, id = q.mon, q.move
    if slot and mon.moves[slot] then
        local old = D.moves[mon.moves[slot].id].name
        M.Replace(mon, slot, id)
        self:Say("1, 2 and... Poof! %s forgot %s. And... %s learned %s!", M.Name(mon), old, M.Name(mon), D.moves[id].name)
    else
        self:Say("%s did not learn %s.", M.Name(mon), D.moves[id].name)
    end
    self.need = self.afterLearn
    self.learning = nil
    if #self.learnQueue > 0 then self:FlushLearn() end
    return true
end

function B:SendAlly(idx)
    if self.used then self.used[idx] = true end
    self.allyIdx = idx
    self.ally = NewSide(self.party[idx])
    if self.foe.participants then self.foe.participants[idx] = true end
    if self.pvp and self.pvp.watch then
        self:Say("%s sent out %s!", self.pvp.watch.ally, M.Name(self.ally.mon))
    else
        self:Say("Go! %s!", M.Name(self.ally.mon))
    end
    self:Emit({ t = "send", side = "ally", mon = self.ally.mon })
end

function B:ForcedSwitch(idx)
    local mon = self.party[idx]
    if not mon or mon.hp <= 0 then return false end
    self:SendAlly(idx)
    self.need = "action"
    self:FlushLearn()
    return true
end

function B:Finish(result)
    self.result = result
    self.need = "done"
    self:Emit({ t = "end", result = result })
    return true
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------

function B:UseItem(item, target)
    local def = D.items[item]
    if not def or (self.bag[item] or 0) <= 0 then return false end
    if def.use == "ball" then
        if not self.wild then
            self.bag[item] = self.bag[item] - 1
            self:Say("You threw a %s!", def.name)
            self:Say("%s swatted the rod away! That beast is already tamed!", self.trainer.name)
            return true
        end
        self.bag[item] = self.bag[item] - 1
        self:Say("You threw a %s!", def.name)
        return self:Catch(def.ball * (self.catchMult or 1))
    elseif def.use == "heal" or def.use == "cure" then
        local mon = self.party[target or self.allyIdx]
        if not mon or mon.hp <= 0 then return false end
        if def.use == "heal" then
            if mon.hp >= M.MaxHP(mon) then return false end
            self.bag[item] = self.bag[item] - 1
            local before = mon.hp
            if mon == self.ally.mon then
                self:SetHP("ally", mon.hp + def.heal)
            else
                mon.hp = min(M.MaxHP(mon), mon.hp + def.heal)
            end
            self:Emit({ t = "sfx", sound = "heal" })
            self:Say("%s's HP was restored by %d points.", M.Name(mon), mon.hp - before)
        else
            if mon.status ~= def.cures then return false end
            self.bag[item] = self.bag[item] - 1
            mon.status = nil
            if mon == self.ally.mon then self:Emit({ t = "status", side = "ally" }) end
            self:Emit({ t = "sfx", sound = "cure" })
            self:Say("%s was cured!", M.Name(mon))
        end
        return true
    elseif def.use == "boost" then                      -- an elixir: a stage up (or def.stages) for the beast fighting
        local s = self.ally
        local cur = s.stages[def.stat] or 0
        if cur >= 6 then return false end
        self.bag[item] = self.bag[item] - 1
        local up = (def.typeStages and def.typeStages[D.species[s.mon.sp].type]) or def.stages or 1
        s.stages[def.stat] = min(6, cur + up)
        self:Emit({ t = "sfx", sound = "drink" })
        self:Say("%s drank the %s.", M.Name(s.mon), def.name)
        self:Emit({ t = "sfx", sound = "statup" })
        self:Say("%s's %s rose!", M.Name(s.mon), D.statNames[def.stat])
        return true
    elseif def.use == "freeaction" then                 -- cures paralysis; the beast fighting can't be panicked
        local mon = self.party[target or self.allyIdx]
        if not mon or mon.hp <= 0 then return false end
        local active = mon == self.ally.mon
        if mon.status ~= "par" and not (active and not self.ally.free) then return false end
        self.bag[item] = self.bag[item] - 1
        self:Emit({ t = "sfx", sound = "drink" })
        self:Say("%s drank the %s.", M.Name(mon), def.name)
        if mon.status == "par" then
            mon.status = nil
            if active then self:Emit({ t = "status", side = "ally" }) end
            self:Emit({ t = "sfx", sound = "cure" })
            self:Say("%s was cured of paralysis!", M.Name(mon))
        end
        if active then
            self.ally.free, self.ally.panic = true, nil
            self:Say("%s moves freely. Nothing can panic it now!", M.Name(mon))
        end
        return true
    elseif def.use == "rejuv" then
        local mon = self.party[target or self.allyIdx]
        if not mon or mon.hp <= 0 or (mon.hp >= M.MaxHP(mon) and not mon.status) then return false end
        self.bag[item] = self.bag[item] - 1
        if mon == self.ally.mon then
            self:SetHP("ally", mon.hp + def.heal)
        else
            mon.hp = min(M.MaxHP(mon), mon.hp + def.heal)
        end
        mon.status, mon.sleep = nil, nil
        if mon == self.ally.mon then self:Emit({ t = "status", side = "ally" }) end
        self:Emit({ t = "sfx", sound = "heal" })
        self:Say("%s was rejuvenated!", M.Name(mon))
        return true
    end
    return false
end

-- Gen III catch values for the foe right now: a (>= 255 always tames) and bb, the bar each of the four checks
-- (a roll of 0..65535) must stay under.
function B:CatchValues(ballMult)
    local mon = self.foe.mon
    local maxhp = M.MaxHP(mon)
    local rate = D.species[mon.sp].catch
    local bonus = (mon.status == "slp") and 2 or ((mon.status and 1.5) or 1)
    local a = floor((3 * maxhp - 2 * mon.hp) * rate * ballMult / (3 * maxhp)) * bonus
    if a >= 255 then return a, 65536 end
    return a, floor(1048560 / sqrt(sqrt(16711680 / max(1, a))))
end

-- The chance (0..1) that a rod tames the foe this turn: all four checks hold. No dice are rolled.
function B:TameOdds(item)
    local def = D.items[item]
    if not (def and def.use == "ball") or not self.wild then return 0 end
    local a, bb = self:CatchValues(def.ball * (self.catchMult or 1))
    if a >= 255 then return 1 end
    return min(1, bb / 65536) ^ 4
end

-- Gen III catch: returns true.
function B:Catch(ballMult)
    local mon = self.foe.mon
    local a, bb = self:CatchValues(ballMult)
    local shakes = 0
    if a >= 255 then
        shakes = 4
    else
        while shakes < 4 and self.rng(0, 65535) < bb do shakes = shakes + 1 end
    end
    local caught = shakes >= 4
    self:Emit({ t = "throw", shakes = min(3, shakes), caught = caught, shiny = mon.shiny and true or false })
    if not caught then
        local lines = { [0] = "Oh no! The beast broke free!", "Aww! It was almost tamed!",
                        "Aargh! So close!", "Shoot! It was nearly yours!" }
        self:Say(lines[shakes])
        return true
    end
    self:Emit({ t = "sfx", sound = "catch" })
    self:Say("Gotcha! %s was tamed!", M.Name(mon))
    local fresh = (self.isNew and self.isNew(mon.sp)) and true or false        -- (before onCaught records it)
    local where = self.onCaught and self.onCaught(mon)
    self:Emit({ t = "tamed", sp = mon.sp, lvl = mon.lvl, shiny = mon.shiny and true or false, fresh = fresh,
                where = where or "party" })
    if where == "box" then self:Say("%s was sent to the Stable Master.", M.Name(mon)) end
    return self:Finish("caught")
end

---------------------------------------------------------------------------
-- Player battles (lockstep). Both clients run this same battle from the same seed; each only sends its own
-- action. A turn resolves once both actions are known, always in the same canonical order (the challenger,
-- "p1", first on ties), so both screens stay identical. Differences from trainer battles: no items, no
-- running (RUN = forfeit), no exp or money, and a fainted creature is replaced by the next usable one
-- automatically on both sides (no extra round-trip for a choice).
---------------------------------------------------------------------------

function B:PvPSides()
    local p1 = self.pvp.host and "ally" or "foe"
    return p1, Other(p1)
end

local function TeamOf(b, side) return side == "ally" and b.party or b.foes end
local function IdxOf(b, side) return side == "ally" and b.allyIdx or b.foeIdx end

-- Normalises an action for `side`: anything invalid becomes "use a move" (struggle when out of PP).
-- Both clients validate each action the same way, so a bad message cannot split the two battles.
function B:ValidPvP(side, a)
    if type(a) ~= "table" then a = {} end
    if a.kind == "forfeit" then return { kind = "forfeit" } end
    if self[side].cast then return { kind = "release" } end              -- a cast lands, whatever was sent
    if a.kind == "switch" then
        local idx = tonumber(a.idx)                  -- (a string "2" from the wire is a number here, or nothing)
        idx = idx and idx == floor(idx) and idx or 0
        local mon = TeamOf(self, side)[idx]
        if mon and mon.hp > 0 and idx ~= IdxOf(self, side) and not self:Trapped(side) then
            return { kind = "switch", idx = idx }
        end
    end
    local mon = self[side].mon
    local idx = tonumber(a.idx)
    if a.kind == "move" and idx and self:Usable(side, idx) then return { kind = "move", idx = idx } end
    for i in ipairs(mon.moves) do
        if self:Usable(side, i) then return { kind = "move", idx = i } end
    end
    return { kind = "move", idx = 0 }         -- struggle
end

-- My action: validated, handed to the network (pvp.onAction) and held until the opponent's arrives.
function B:ActPvP(a)
    if self.need ~= "action" then return false end
    if self.ally.cast and a.kind ~= "forfeit" then
        a = { kind = "release" }
    elseif a.kind == "move" then
        if self:CanFight("ally") and not self:Usable("ally", a.idx) then return false end
    elseif a.kind == "switch" then
        local mon = self.party[a.idx]
        if not mon or mon.hp <= 0 or a.idx == self.allyIdx or self:Trapped("ally") then return false end
    elseif a.kind ~= "forfeit" then
        return false
    end
    self.mine = self:ValidPvP("ally", a)
    self.need = "wait"
    if self.pvp.onAction then self.pvp.onAction(self.mine) end
    if self.theirs then self:ResolvePvP() end
    return true
end

-- The opponent's action for this turn (from the network).
function B:ReceivePvP(a)
    if self.need == "done" or self.theirs then return false end
    self.theirs = self:ValidPvP("foe", a)
    if self.mine then self:ResolvePvP() end
    return true
end

function B:SendFoe(idx)
    self.foeIdx = idx
    self.foe = NewSide(self.foes[idx])
    self.foe.participants = {}
    self:Say("%s sent out %s!", self.pvp.name, M.Name(self.foe.mon))
    self:Emit({ t = "send", side = "foe", mon = self.foe.mon })
end

function B:PvPSwitch(side, idx)
    if side == "ally" then
        if self.pvp.watch then
            self:Say("%s withdrew %s!", self.pvp.watch.ally, M.Name(self.ally.mon))
        else
            self:Say("%s, come back!", M.Name(self.ally.mon))
        end
        self:Emit({ t = "recall", side = "ally" })
        self:SendAlly(idx)
    else
        self:Say("%s withdrew %s!", self.pvp.name, M.Name(self.foe.mon))
        self:Emit({ t = "recall", side = "foe" })
        self:SendFoe(idx)
    end
end

-- Faints in canonical order; replaces them or ends the battle. Returns true when anyone fainted.
function B:PvPFaints()
    local p1, p2 = self:PvPSides()
    local down, out = {}, {}
    for _, side in ipairs({ p1, p2 }) do
        local s = self[side]
        if s.mon.hp <= 0 and not s.fainted then
            s.fainted = true
            down[#down + 1] = side
            self:Emit({ t = "faint", side = side })
            self:Say("%s fainted!", self:SideName(side))
            if not M.FirstUsable(TeamOf(self, side)) then out[side] = true end
        end
    end
    if #down == 0 then return false end
    local watch = self.pvp.watch
    if out.ally and out.foe then
        self:Say("Both sides are out of beasts. It's a draw!")
        self:Finish("draw")
    elseif watch and (out.ally or out.foe) then
        local loser, winner = watch.ally, watch.foe
        if out.foe then loser, winner = winner, loser end
        self:Say("%s has no beasts left! %s wins the match.", loser, winner)
        self:Finish(out.foe and "win" or "lose")
    elseif out.ally then
        self:Say("You have no beasts left! %s wins the match.", self.pvp.name)
        self:Finish("lose")
    elseif out.foe then
        self:Say("You defeated %s!", self.pvp.name)
        self:Finish("win")
    else
        for _, side in ipairs(down) do
            local nextIdx = M.FirstUsable(TeamOf(self, side))
            if side == "ally" then self:SendAlly(nextIdx) else self:SendFoe(nextIdx) end
        end
    end
    return true
end

-- (move, slot, released) for a validated action
function B:PvPMove(side, a)
    if a.kind == "release" then
        local c = self[side].cast
        if c then return c.mv, c.slot, true end
        return STRUGGLE, nil, false
    end
    if a.idx == 0 then return STRUGGLE, nil, false end
    local slot = self[side].mon.moves[a.idx]
    slot.pp = slot.pp - 1
    return D.moves[slot.id], a.idx, false
end

function B:ResolvePvP()
    local acts = { ally = self.mine, foe = self.theirs }
    self.mine, self.theirs = nil, nil
    self.turn = self.turn + 1
    local p1, p2 = self:PvPSides()
    if self.pvp.onResolve then self.pvp.onResolve(acts[p1], acts[p2]) end       -- for spectators

    if acts.ally.kind == "forfeit" or acts.foe.kind == "forfeit" then
        if acts.ally.kind == "forfeit" and acts.foe.kind == "forfeit" then
            self:Say("Both players gave up. It's a draw!")
            return self:Finish("draw")
        elseif self.pvp.watch then
            local quitter = acts.ally.kind == "forfeit" and self.pvp.watch.ally or self.pvp.watch.foe
            self:Say("%s forfeited the match!", quitter)
            return self:Finish(acts.ally.kind == "forfeit" and "lose" or "win")
        elseif acts.ally.kind == "forfeit" then
            self:Say("You forfeited the match.")
            return self:Finish("lose")
        end
        self:Say("%s forfeited the match!", self.pvp.name)
        return self:Finish("win")
    end

    for _, side in ipairs({ p1, p2 }) do
        if acts[side].kind == "switch" then self:PvPSwitch(side, acts[side].idx) end
    end

    local movers = {}
    for _, side in ipairs({ p1, p2 }) do
        local k = acts[side].kind
        if k == "move" or k == "release" then
            local mv, slot, released = self:PvPMove(side, acts[side])
            movers[#movers + 1] = { side = side, mv = mv, slot = slot, released = released }
        end
    end
    if #movers == 2 then
        local a, b = movers[1], movers[2]          -- a is p1
        local pa, pb = Prio(a.mv, a.released), Prio(b.mv, b.released)
        local bFirst
        if pa ~= pb then
            bFirst = pb > pa
        else
            local sa, sb = self:EffStat(a.side, "spe"), self:EffStat(b.side, "spe")
            if sa ~= sb then bFirst = sb > sa else bFirst = self.rng(1, 2) == 2 end
        end
        if bFirst then movers[1], movers[2] = b, a end
    end
    local fainted = false
    for _, m in ipairs(movers) do
        if self.ally.mon.hp <= 0 or self.foe.mon.hp <= 0 then break end
        self:UseMove(m.side, m.mv, m.slot, m.released)
        if self:PvPFaints() then fainted = true break end
    end
    if self.need == "done" then return end
    self:TurnExtras({ p1, p2 })

    -- end of turn: burn / poison and marks, challenger first; then everything counts down
    for _, side in ipairs({ p1, p2 }) do self:SideTicks(side) end
    self:PvPFaints()
    if self.need ~= "done" then
        self:Countdown(p1)
        self:Countdown(p2)
    end
    if self.need ~= "done" then self.need = self.pvp.watch and "watch" or "action" end
end

---------------------------------------------------------------------------
-- Watching a player battle (Watch.lua). The spectator runs the same battle from the same seed and teams, seen
-- from p1's side, and is fed both actions of every turn once the players have resolved it.
---------------------------------------------------------------------------

-- Both actions of one turn (p1's, p2's). false when the battle is not waiting for one.
function B:WatchTurn(a1, a2)
    if not (self.pvp and self.pvp.watch) or self.need ~= "watch" then return false end
    self.mine, self.theirs = self:ValidPvP("ally", a1), self:ValidPvP("foe", a2)
    self:ResolvePvP()
    return true
end

-- Replaces whatever the catch-up produced with a short "you're watching" intro showing the current state.
function B:WatchIntro()
    local w = self.pvp.watch
    self.events = {}
    self:Say("You're watching %s and %s battle!", w.ally, w.foe)
    if self.need == "done" then return end
    if self.turn > 0 then self:Say("It's turn %d.", self.turn + 1) end
    self:Emit({ t = "send", side = "foe", mon = self.foe.mon })
    self:Emit({ t = "send", side = "ally", mon = self.ally.mon })
end

-- Stops watching: drops what hasn't been shown yet, says why, and ends ("left" or "lost").
function B:EndWatch(result, text)
    if self.need == "done" then return end
    self.events = {}
    if text then self:Say("%s", text) end
    self:Finish(result)
end
