local Sim, D = ns.RPGSim, ns.RPGData
local function choose(S, p)
    local h = S.party[p]
    local enemy
    for i, e in ipairs(S.enemies) do
        if not e.dead and (not enemy or (e.intent and e.intent.k == 'cast' and e.intent.interruptible)) then enemy = i end
    end
    local hurt, pct = p, 1001
    for q = 1, S.players do
        local x = S.party[q]
        if not x.dead and x.hp * 1000 / x.max < pct then hurt, pct = q, x.hp * 1000 / x.max end
    end
    for a = D.ABILITIES, 1, -1 do
        local ab = D.kits[h.role][a]
        local t = ab.tgt == 'ally' and hurt or (ab.tgt == 'enemy' and enemy or p)
        local useful = true
        if ab.kind == 'potion' then useful = h.hp * 100 < h.max * 35 end
        if ab.kind == 'heal' or ab.kind == 'hot' or ab.kind == 'shield' then useful = pct < 800 end
        if ab.kind == 'interrupt' then useful = enemy and S.enemies[enemy].intent and S.enemies[enemy].intent.k == 'cast' and S.enemies[enemy].intent.interruptible end
        if ab.kind == 'taunt' then
            useful = false
            for i, e in ipairs(S.enemies) do if not e.dead and Sim.EnemyTarget(S, e) ~= p then useful = true t = i end end
        end
        if ab.kind == 'selfdr' then useful = h.hp * 100 < h.max * 50 end
        if useful and t and Sim.CanUse(S, p, a, t) then return { a = a, b = t } end
    end
end
local function run(seed, heroes, heroic)
    local S = Sim.New(seed, heroes, { heroic = heroic })
    local guard = 0
    while not S.over and guard < 2000 do
        guard = guard + 1
        for p = 1, S.players do
            local h = S.party[p]
            if h.talentOffer then Sim.Apply(S, { p = p, k = 't', a = 1 }) end
        end
        if S.phase == 'combat' then
            local ch = {}
            for p = 1, S.players do ch[p] = choose(S, p) end
            Sim.ResolveRound(S, ch)
        elseif S.phase == 'loot' then
            for p = 1, S.players do if not S.party[p].lootTaken then Sim.Apply(S, { p = p, k = 'l', a = 1 }) end end
        elseif S.phase == 'path' then
            for p = 1, S.players do if S.party[p].vote == 0 then Sim.Apply(S, { p = p, k = 'v', a = 1 }) end end
        end
    end
    return { hash = Sim.Hash(S), depth = S.depth, won = S.won, over = S.over, rounds = guard, level = S.party[1].level,
             loot = #S.party[1].loot, kills = #S.bossKills, interrupts = S.interrupts }
end
