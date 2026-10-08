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
-- Sides: "ally" (the player) and "foe".
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
    return { mon = mon, stages = { atk = 0, def = 0, spa = 0, spd = 0, spe = 0 } }
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
        local fsp = D.species[b.foe.mon.sp]
        if fsp and fsp.untameable then
            b:Say("%s attacks!", foeName)                  -- (a Defias Thug: no beast of his, he fights himself)
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
    return { sp = m.sp, name = M.Name(m), lvl = m.lvl, hp = m.hp, max = M.MaxHP(m), status = m.status, exp = M.ExpProgress(m),
             shiny = m.shiny, stages = stages, sleep = (m.status == "slp") and m.sleep or nil,
             flask = m.flask and { id = m.flask.id, n = m.flask.n } or nil }
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
    if side == "foe" then
        local sp = D.species[mon.sp]
        if self.wild and sp and sp.untameable then return M.Name(mon) end
        return (self.wild and "Wild " or "Foe ") .. M.Name(mon)
    end
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
    if stat == "atk" and s.mon.status == "brn" and attacking then v = v / 2 end
    return max(1, v)
end

-- Returns damage, effectiveness, crit.
function B:Damage(atkSide, defSide, mv, forceCrit)
    local attacker, defender = self[atkSide].mon, self[defSide].mon
    local physical = mv.type == "NONE" or (D.types[mv.type] and D.types[mv.type].physical)
    local crit = forceCrit
    if crit == nil then crit = self.rng(1, 16) == 1 end
    local A = self:EffStat(atkSide, physical and "atk" or "spa", crit, true)
    local Dv = self:EffStat(defSide, physical and "def" or "spd", crit, false)
    local base = floor(floor(floor(2 * attacker.lvl / 5 + 2) * mv.power * A / Dv) / 50) + 2
    local eff = mv.type == "NONE" and 1 or D.Effectiveness(mv.type, D.species[defender.sp].type)
    local stab = (mv.type == D.species[attacker.sp].type) and 1.5 or 1
    local dmg = base * (crit and 2 or 1) * stab * eff * self.rng(85, 100) / 100
    dmg = floor(dmg)
    if eff > 0 then dmg = max(1, dmg) else dmg = 0 end
    return dmg, eff, crit
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

function B:ApplyStatus(side, status)
    local mon = self[side].mon
    if mon.status or mon.hp <= 0 then return false end
    mon.status = status
    if status == "slp" then mon.sleep = self.rng(1, 3) end
    self:Emit({ t = "status", side = side })
    self:Emit({ t = "sfx", sound = status })
    self:Say("%s is %s!", self:SideName(side), D.status[status].name)
    return true
end

function B:ApplyEffect(side, mv, damaged)
    local e = mv.effect
    if not e then return end
    local target = (e.who == "self") and side or Other(side)
    if self[target].mon.hp <= 0 then return end
    local chance = e.chance or 100
    if chance < 100 and self.rng(1, 100) > chance then return end
    if e.kind == "stat" then
        local s = self[target]
        local cur = s.stages[e.stat]
        local nxt = max(-6, min(6, cur + e.stages))
        if nxt == cur then
            if not damaged then
                self:Say("%s's %s won't go any %s!", self:SideName(target), D.statNames[e.stat],
                    e.stages > 0 and "higher" or "lower")
            end
            return
        end
        s.stages[e.stat] = nxt
        self:Emit({ t = "sfx", sound = e.stages > 0 and "statup" or "statdown" })
        self:Say("%s's %s %s!", self:SideName(target), D.statNames[e.stat], e.stages > 0 and "rose" or "fell")
    elseif e.kind == "status" then
        if not self:ApplyStatus(target, e.status) and not damaged then
            self:Say("But it failed!")
        end
    end
end

-- Returns true when the move went off (for PP accounting the caller already paid).
function B:UseMove(side, mv)
    local user = self[side].mon
    local target = Other(side)
    local name = self:SideName(side)

    -- status that can stop the turn
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
            return
        end
    elseif user.status == "par" and self.rng(1, 4) == 1 then
        self:Emit({ t = "sfx", sound = "par" })
        self:Say("%s is paralyzed! It can't move!", name)
        return
    end

    self:Say("%s used %s!", name, mv.name)
    self:Emit({ t = "attack", side = side, move = mv })

    if mv.acc > 0 and self.rng(1, 100) > mv.acc then
        self:Emit({ t = "sfx", sound = "miss" })
        self:Say("%s's attack missed!", name)
        return
    end

    if mv.power > 0 then
        local dmg, eff, crit = self:Damage(side, target, mv)
        if eff == 0 then
            self:Emit({ t = "sfx", sound = "immune" })
            self:Say("It doesn't affect %s...", self:SideName(target))
            return
        end
        local before = self[target].mon.hp
        self:SetHP(target, before - dmg)
        local dealt = before - self[target].mon.hp
        if crit then self:Emit({ t = "sfx", sound = "crit" }) self:Say("A critical hit!") end
        if eff > 1 then
            self:Emit({ t = "sfx", sound = "super" })
            self:Say("It's super effective!")
        elseif eff < 1 then
            self:Emit({ t = "sfx", sound = "weak" })
            self:Say("It's not very effective...")
        end
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
        if mv.recoil and dealt > 0 then
            self:SetHP(side, user.hp - max(1, floor(dealt / mv.recoil)))
            self:Emit({ t = "sfx", sound = "recoil" })
            self:Say("%s is hit with recoil!", name)
        end
    else
        self:ApplyEffect(side, mv, false)
    end
end

function B:HasPP(mon)
    for _, m in ipairs(mon.moves) do if m.pp > 0 then return true end end
    return false
end

---------------------------------------------------------------------------
-- AI
---------------------------------------------------------------------------

function B:FoeMoveIdx()
    local mon = self.foe.mon
    local usable = {}
    for i, m in ipairs(mon.moves) do if m.pp > 0 then usable[#usable + 1] = i end end
    if #usable == 0 then return nil end
    if self.wild or self.rng(1, 100) > 70 then return usable[self.rng(1, #usable)] end
    -- trainers: the hardest-hitting move, a status move now and then while the target is healthy
    local best, bestScore = usable[1], -1
    local defType = D.species[self.ally.mon.sp].type
    for _, i in ipairs(usable) do
        local mv = D.moves[mon.moves[i].id]
        local score
        if mv.power > 0 then
            score = mv.power * D.Effectiveness(mv.type, defType) * (mv.type == D.species[mon.sp].type and 1.5 or 1)
        else
            local e = mv.effect
            local useful = e and (e.kind ~= "status" or not self.ally.mon.status)
            score = useful and 25 or 0
        end
        if score > bestScore then best, bestScore = i, score end
    end
    return best
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

    if a.kind == "run" then
        if not self.wild then
            self:Say("No! There's no running from a trainer battle!")
            return true
        end
        self.runs = self.runs + 1
        local mine, theirs = self:EffStat("ally", "spe"), self:EffStat("foe", "spe")
        local odds = floor(mine * 128 / theirs + 30 * self.runs) % 256
        if mine >= theirs or self.rng(0, 255) < odds then
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
        self:Say("%s, come back!", M.Name(self.ally.mon))
        self:Emit({ t = "recall", side = "ally" })
        self:SendAlly(a.idx)
        self:FoeTurnOnly()
        return self:EndTurn()
    elseif a.kind == "move" then
        local slot = self.ally.mon.moves[a.idx]
        local mine
        if not self:HasPP(self.ally.mon) then
            mine = STRUGGLE
        else
            if not slot or slot.pp <= 0 then return false end
            slot.pp = slot.pp - 1
            mine = D.moves[slot.id]
        end
        local fi = self:FoeMoveIdx()
        local theirs = STRUGGLE
        if fi then
            local fs = self.foe.mon.moves[fi]
            fs.pp = fs.pp - 1
            theirs = D.moves[fs.id]
        end
        local allyFirst
        local pa, pf = mine.prio or 0, theirs.prio or 0
        if pa ~= pf then
            allyFirst = pa > pf
        else
            local sa, sf = self:EffStat("ally", "spe"), self:EffStat("foe", "spe")
            if sa ~= sf then allyFirst = sa > sf else allyFirst = self.rng(1, 2) == 1 end
        end
        local order = allyFirst and { { "ally", mine }, { "foe", theirs } } or { { "foe", theirs }, { "ally", mine } }
        for _, step in ipairs(order) do
            if self.ally.mon.hp <= 0 or self.foe.mon.hp <= 0 then break end
            self:UseMove(step[1], step[2])
            if self:CheckFaints() then break end
        end
        return self:EndTurn()
    end
    return false
end

function B:FoeTurnOnly()
    if self.foe.mon.hp <= 0 or self.ally.mon.hp <= 0 then return end
    local fi = self:FoeMoveIdx()
    local mv = STRUGGLE
    if fi then
        local fs = self.foe.mon.moves[fi]
        fs.pp = fs.pp - 1
        mv = D.moves[fs.id]
    end
    self:UseMove("foe", mv)
    self:CheckFaints()
end

-- End of turn: burn / poison. Returns true (the action was accepted).
function B:EndTurn()
    if self.need == "action" then
        for _, side in ipairs({ "ally", "foe" }) do
            local mon = self[side].mon
            if mon.hp > 0 and (mon.status == "brn" or mon.status == "psn") then
                self:SetHP(side, mon.hp - max(1, floor(M.MaxHP(mon) / 8)))
                self:Emit({ t = "sfx", sound = mon.status })
                self:Say("%s is hurt by its %s!", self:SideName(side), mon.status == "brn" and "burn" or "poison")
                if self:CheckFaints() then break end
            end
        end
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
        local sp = D.species[self.foe.mon.sp]
        if sp and sp.untameable then                   -- people (Defias, guards...) are fought, never tamed
            self:Say("%s can't be tamed! Only beasts and wild creatures answer a Taming Rod.", M.Name(self.foe.mon))
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
    elseif def.use == "boost" then                      -- an elixir: one stage up for the beast fighting
        local s = self.ally
        local cur = s.stages[def.stat] or 0
        if cur >= 6 then return false end
        self.bag[item] = self.bag[item] - 1
        s.stages[def.stat] = min(6, cur + 1)
        self:Emit({ t = "sfx", sound = "drink" })
        self:Say("%s drank the %s.", M.Name(s.mon), def.name)
        self:Emit({ t = "sfx", sound = "statup" })
        self:Say("%s's %s rose!", M.Name(s.mon), D.statNames[def.stat])
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

-- Gen III catch: returns true.
function B:Catch(ballMult)
    local mon = self.foe.mon
    local maxhp = M.MaxHP(mon)
    local rate = D.species[mon.sp].catch
    local bonus = (mon.status == "slp") and 2 or ((mon.status and 1.5) or 1)
    local a = floor((3 * maxhp - 2 * mon.hp) * rate * ballMult / (3 * maxhp)) * bonus
    local shakes = 0
    if a >= 255 then
        shakes = 4
    else
        local bb = floor(1048560 / sqrt(sqrt(16711680 / max(1, a))))
        while shakes < 4 and self.rng(0, 65535) < bb do shakes = shakes + 1 end
    end
    local caught = shakes >= 4
    self:Emit({ t = "throw", shakes = min(3, shakes), caught = caught })
    if not caught then
        local lines = { [0] = "Oh no! The beast broke free!", "Aww! It was almost tamed!",
                        "Aargh! So close!", "Shoot! It was nearly yours!" }
        self:Say(lines[shakes])
        return true
    end
    self:Emit({ t = "sfx", sound = "catch" })
    self:Say("Gotcha! %s was tamed!", M.Name(mon))
    local where = self.onCaught and self.onCaught(mon)
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
    if a.kind == "switch" then
        local mon = TeamOf(self, side)[tonumber(a.idx) or 0]
        if mon and mon.hp > 0 and a.idx ~= IdxOf(self, side) then return { kind = "switch", idx = a.idx } end
    end
    local mon = self[side].mon
    local idx = tonumber(a.idx)
    if a.kind == "move" and idx and mon.moves[idx] and mon.moves[idx].pp > 0 then return { kind = "move", idx = idx } end
    for i, mv in ipairs(mon.moves) do
        if mv.pp > 0 then return { kind = "move", idx = i } end
    end
    return { kind = "move", idx = 0 }         -- struggle
end

-- My action: validated, handed to the network (pvp.onAction) and held until the opponent's arrives.
function B:ActPvP(a)
    if self.need ~= "action" then return false end
    if a.kind == "move" then
        local slot = self.ally.mon.moves[a.idx]
        if self:HasPP(self.ally.mon) and (not slot or slot.pp <= 0) then return false end
    elseif a.kind == "switch" then
        local mon = self.party[a.idx]
        if not mon or mon.hp <= 0 or a.idx == self.allyIdx then return false end
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

function B:PvPMove(side, a)
    if a.idx == 0 then return STRUGGLE end
    local slot = self[side].mon.moves[a.idx]
    slot.pp = slot.pp - 1
    return D.moves[slot.id]
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
        if acts[side].kind == "move" then movers[#movers + 1] = { side = side, mv = self:PvPMove(side, acts[side]) } end
    end
    if #movers == 2 then
        local a, b = movers[1], movers[2]          -- a is p1
        local pa, pb = a.mv.prio or 0, b.mv.prio or 0
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
        self:UseMove(m.side, m.mv)
        if self:PvPFaints() then fainted = true break end
    end
    if self.need == "done" then return end

    -- end of turn: burn / poison, challenger first
    for _, side in ipairs({ p1, p2 }) do
        local mon = self[side].mon
        if mon.hp > 0 and (mon.status == "brn" or mon.status == "psn") then
            self:SetHP(side, mon.hp - math.max(1, math.floor(M.MaxHP(mon) / 8)))
            self:Emit({ t = "sfx", sound = mon.status })
            self:Say("%s is hurt by its %s!", self:SideName(side), mon.status == "brn" and "burn" or "poison")
        end
    end
    self:PvPFaints()
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
