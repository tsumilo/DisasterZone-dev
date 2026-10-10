if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Portal/Hub.lua", ...) then return end -- DisasterZone Games/Portal/Hub.lua
-- The Portal's hub (2026-10-10): the World's End Tavern in Shattrath's Lower City, the crawler's tavern between runs.
-- You come in by the north door with your party; in the tavern:
--   the portal (east hall): step in and a ready check asks the party; when everyone is ready you all go through into
--     a dungeon from the pool (today Hellfire Ramparts' first room) at the Portal level the pedestal is set to;
--   the Portal level pedestal (beside the portal): pick the level runs are entered at;
--   the Wanted board (west wall): your best runs per Portal level (the guild's ladder comes with party sync);
--   the stash (a chest by the barrels): the gear runs give is kept here (empty until runs give gear);
--   the practice dummy (west hall): try your abilities, damage per second on the job card.
-- F uses the nearest of them (the prompt at the bottom says which). A finished run, kept or void, brings you back.
-- Two earlier hubs were dropped after looking at them: the Stair of Destiny (a fixed shot of a painted gate, "a
-- cutscene") and the Caverns of Time (160 yd tall: from the follow camera, sand and the hourglass's feet).
--
-- Where things come from:
--   the room: Blizzard's tavern (generators/gen_dungeon_proto.py tavern -> Render3D/Rooms/Portal_WorldsEndTavern.lua:
--     map 530, world x -1785..-1721 by y 5116..5180, walls cut 6 yd up and closed with lids so the follow camera looks
--     in as Diablo shows a building; height 0 = the bar's floor, world -37.2); room x = 5180 - world y (east),
--     y = world x + 1785 (north); its furniture (tables, chairs, benches, barrels, rugs, a keg) is the WMO's own M2
--     doodads baked in as faces (generators/doodad_faces.py);
--   the regulars: their spawns in the TBC database (creature table), displays (creature_template) and the client's
--     CreatureDisplayInfo scales;
--   the stations' models: the mage portal to Karazhan (gameobject 181146, model 197045), a standing wanted board
--     (NewWantedPoster02, model 199475), the Heart of Fury pedestal (gameobject 185146 at its size 0.45, model
--     190025), Marvon's chest (gameobject 149036 at 1.5, model 197063), the Practice Dummy (creature 25225,
--     display 3019);
--   the camera: the dungeons' follow camera (Portal UI FixedCam), here looking south from the door; right-drag turns
--     it up to 60 degrees either way, the wheel zooms.
-- NOT verified in game: the baked furniture's look and the frame rate with it, the regulars' name heights, the
-- portal model's facing.
local addonName, ns = ...

local T = ns.Trainer
local K = ns.PortalKit
local Dist = T.Dist
local floor, min, max, pi = math.floor, math.min, math.max, math.pi

local ROOM = "Portal_WorldsEndTavern"
local ARRIVE_X, ARRIVE_Y = 33, 49                       -- inside the north door, facing into the tavern (south)
local PORTAL = { x = 48, y = 33, r = 1.8 }             -- on the east hall's rug: step in for the ready check
local PEDESTAL = { x = 42.5, y = 36.5 }
local BOARD = { x = 14, y = 23.5 }
local STASH = { x = 11.5, y = 36 }
local DUMMY = { x = 21, y = 24 }
-- (the stations' models stand along their x: facing north, pi / 2, they face the camera, which looks south)

local DISPLAY_TANK, DISPLAY_HEALER, DISPLAY_DUMMY = 22931, 22973, 3019
local FDID_PORTAL, FDID_BOARD, FDID_PEDESTAL, FDID_CHEST = 197045, 199475, 190025, 197063

-- The tavern's regulars where the database puts them: name, display, x, y, facing (room angle), scale, title.
local REGULARS = {
    { "Shaarubo", 18626, 27.5, 16.0, 1.73, 1.00, "Bartender" },
    { "Kylene", 18629, 44.6, 17.9, 5.07, 1.00, "Barmaid" },
    { "Haris Pilton", 18148, 30.1, 45.6, 5.79, 1.00, "Socialite" },
    { "Tinkerbell", 18156, 35.8, 44.1, 5.74, 0.40, "Haris Pilton's Pet" },
    { "Ricole Nichie", 19155, 29.9, 44.0, 1.49, 1.00, "Ex-Socialite" },
    { "Raliq the Drunk", 11548, 22.6, 37.1, 2.13, 1.75, nil },
    { "Zephyr", 19282, 19.7, 37.2, 1.50, 1.00, nil },
    { "Shattrath Saul", 18689, 13.0, 33.6, 0.02, 1.00, nil },
    { "Lonika Stillblade", 21022, 29.8, 19.9, 2.81, 1.00, nil },
    { "Apprentice Tasserel", 17645, 27.5, 19.6, 4.82, 1.00, nil },
    { "Leatei", 18496, 38.4, 18.7, 4.05, 1.00, nil },
    { "Albert Quarksprocket", 18691, 40.3, 47.1, 3.61, 1.00, nil },
    { "Sal'salabim", 18405, 54.0, 7.6, 5.15, 0.75, nil },
}

local DISPLAYS = {
    [DISPLAY_TANK] = { scale = 1, chest = 1.50, head = 2.19, hand = 1.03, name = 2.22 },
    [DISPLAY_HEALER] = { scale = 1, chest = 1.35, head = 2.04, hand = 0.93, name = 2.08 },
    [DISPLAY_DUMMY] = { scale = 1, chest = 1.2, head = 1.8, hand = 1.0, name = 2.0 },
}
for _, r in ipairs(REGULARS) do DISPLAYS[r[2]] = DISPLAYS[r[2]] or { scale = r[6] } end

local arena = { w = 64, h = 64 }
setmetatable(arena, { __index = function(t, k)
    if k ~= "mesh" and k ~= "ground" and k ~= "height" then return nil end
    local R3 = ns.Render3D
    local f = R3 and R3.Floor and R3.Floor({ floor = ROOM })
    if not f then return nil end
    rawset(t, "mesh", f.mesh)
    rawset(t, "ground", T.GroundFn(f.walk))
    rawset(t, "height", T.HeightFn(f))
    return rawget(t, k)
end })

-- Units cannot walk through the regulars, the stations nor the dummy: pushed back out to a circle round each.
local SOLID = {}
local function KeepOut(u)
    local pad = u.radius or 0.6
    for _, s in ipairs(SOLID) do
        local r = s.r + pad
        local dx, dy = u.x - s.x, u.y - s.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < r then
            if d < 1e-3 then dx, dy, d = 0, -1, 1 end
            u.x, u.y = s.x + dx / d * r, s.y + dy / d * r
        end
    end
end

---------------------------------------------------------------------------
-- The cards the stations open (sim.card, drawn by Games/Portal/UI.lua: title, lines, buttons { text, fn(sim),
-- disabled }); sim.wantLevel asks the panel to set the Portal level (it starts the hub again where you stand)
---------------------------------------------------------------------------

local function Data() return ns.Games and ns.Games.GetData and ns.Games:GetData("portal") or {} end

local function LevelCard(sim)
    local lines = { "Runs are entered at this level: the monsters grow stronger with each one.", "" }
    local buttons = {}
    for _, d in ipairs(sim.enc.difficulties) do
        local here = d.id == sim.diff.id
        buttons[#buttons + 1] = { text = (here and "> " or "") .. d.name, disabled = here,
                                  fn = function(s) s.wantLevel = d.id end }
    end
    lines[#lines + 1] = "Now: |cffffd100" .. sim.diff.name .. "|r"
    sim.card = { title = "Portal level", lines = lines, buttons = buttons, station = "level" }
end

local function BoardCard(sim)
    local rec = Data().enc and Data().enc.ramparts or {}
    local lines = {}
    for _, d in ipairs(sim.enc.difficulties) do
        local r = rec[d.id]
        if r and r.bestScore then
            lines[#lines + 1] = string.format("%s:  best |cffffd100%d|r, fastest %.0f sec, %d of %d runs cleared",
                d.name, r.bestScore, r.bestTime or 0, r.clears or 0, r.tries or 0)
        else
            lines[#lines + 1] = d.name .. ":  |cff888888no clear yet|r"
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cff888888The guild's ladder comes with party play.|r"
    sim.card = { title = "Wanted: your best runs", lines = lines, buttons = {}, station = "board" }
end

local function StashCard(sim)
    sim.card = { title = "Stash", station = "stash", buttons = {},
                 lines = { "Empty.", "", "Gear you win in runs waits here between runs. A void run gives nothing." } }
end

-- The ready check: you and every party member; the AI members answer after a moment.
local function ReadyLines(sim)
    local rc = sim.ready
    local lines = { "Into the portal at |cffffd100" .. sim.diff.name .. "|r. A wipe voids the run.", "" }
    for _, m in ipairs(rc.members) do
        lines[#lines + 1] = (m.ok and "|cff5fd35fReady|r   " or "|cff888888Waiting|r   ") .. m.name
    end
    return lines
end

local function ReadyCard(sim)
    local rc = sim.ready
    local you = rc.members[1]
    local all = true
    for _, m in ipairs(rc.members) do all = all and m.ok end
    sim.card = { title = "Ready check", lines = ReadyLines(sim), station = "ready", keep = true, buttons = {
        { text = you.ok and "Ready" or "Ready  (F)", disabled = you.ok, fn = function(s) s.ready.members[1].ok = true end },
        { text = "Cancel", fn = function(s)
            s.ready, s.card = nil, nil
            local p = s.player                                  -- (a step back out of the portal)
            local dx, dy = p.x - PORTAL.x, p.y - PORTAL.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d < 1e-3 then dx, dy, d = -1, 0, 1 end
            p.x, p.y = PORTAL.x + dx / d * (PORTAL.r + 1.5), PORTAL.y + dy / d * (PORTAL.r + 1.5)
        end },
    } }
    return all
end

local function StartReady(sim)
    local members = { { name = "You", ok = false } }
    for i, u in ipairs(sim:Alive("party")) do
        members[#members + 1] = { name = u.name, ok = false, okAt = sim.time + 0.7 + 0.6 * i }
    end
    sim.ready = { at = sim.time, members = members }
end

---------------------------------------------------------------------------
-- The practice dummy: every hit counts; damage per second since the first hit, reset after 6 s without one
---------------------------------------------------------------------------

local function DummyHit(sim, attacker, u, amount)
    if u.dead then return end
    amount = floor(amount)
    sim:Damage(u, amount)
    if u.dummy then
        u.hp = u.hpMax                                          -- (it never falls)
        local m = sim.meter
        if not m or sim.time - m.last > 6 then m = { first = sim.time, total = 0 } sim.meter = m end
        m.total, m.last = m.total + amount, sim.time
        if not K.Busy(sim, u) then K.Anim(sim, u, K.ANIM_WOUND, 0.35) end
    end
end

local abilities = K.Abilities(DummyHit)

---------------------------------------------------------------------------

local function Station(sim, def)
    local u = sim:Spawn(def)
    u.interactRange = def.interactRange or 4
    SOLID[#SOLID + 1] = { x = u.x, y = u.y, r = def.solid or 0.8 }
    return u
end

local function Start(sim)
    local p = sim.player
    p.hp, p.hpMax, p.swingAt = 9000, 9000, 0
    SOLID = {}
    sim.ready, sim.card, sim.meter, sim.wantLevel = nil, nil, nil, nil
    sim:Spawn({ kind = "prop", name = "Portal", x = PORTAL.x, y = PORTAL.y, fdid = FDID_PORTAL, radius = 1,
                facing = pi / 2, label = true, plate = 4.2 })
    Station(sim, { kind = "prop", name = "Portal level", x = PEDESTAL.x, y = PEDESTAL.y, fdid = FDID_PEDESTAL,
                   scale = 0.45, facing = pi / 2, label = true, plate = 2.8, verb = "Set", interact = LevelCard })
    Station(sim, { kind = "prop", name = "Wanted board", x = BOARD.x, y = BOARD.y, fdid = FDID_BOARD,
                   facing = pi / 2, label = true, plate = 2.8, verb = "Read", interact = BoardCard, solid = 1.3 })
    Station(sim, { kind = "prop", name = "Stash", x = STASH.x, y = STASH.y, fdid = FDID_CHEST, scale = 1.5,
                   facing = 0, label = true, plate = 1.5, verb = "Open", interact = StashCard })
    local dummy = sim:Spawn({ kind = "mob", name = "Practice Dummy", x = DUMMY.x, y = DUMMY.y, hp = 1000000,
                              display = DISPLAY_DUMMY, radius = 0.8, targetable = true, dummy = true,
                              facing = pi / 2, plate = 2.4, level = 70 })
    SOLID[#SOLID + 1] = { x = dummy.x, y = dummy.y, r = 0.7 }
    for _, r in ipairs(REGULARS) do
        local npc = sim:Spawn({ kind = "npc", name = r[1], x = r[3], y = r[4], display = r[2], facing = r[5],
                                radius = 0.5, friendly = true, label = true, plate = 2.4 * r[6] + 0.3 })
        SOLID[#SOLID + 1] = { x = npc.x, y = npc.y, r = 0.6 * r[6] }
    end
    sim:Spawn({ kind = "party", name = "Tank", x = ARRIVE_X + 2, y = ARRIVE_Y + 2, hp = 14000, speed = 7,
                radius = 0.9, color = { 0.3, 0.6, 1 }, display = DISPLAY_TANK, selectable = true, facing = -pi / 2,
                plate = DISPLAYS[DISPLAY_TANK].name + 0.4 })
    sim:Spawn({ kind = "party", name = "Healer", x = ARRIVE_X - 2, y = ARRIVE_Y + 2, hp = 7000, speed = 7,
                radius = 0.9, color = { 0.3, 1, 0.6 }, display = DISPLAY_HEALER, selectable = true,
                facing = -pi / 2, plate = DISPLAYS[DISPLAY_HEALER].name + 0.4 })
    sim.marks = nil
    sim.objective = "Set the Portal level at the pedestal, then step into the portal in the east hall."
    sim:Banner("The World's End Tavern", 3, 1, 0.8, 0.35)
end

local function Update(sim)
    local p = sim.player
    KeepOut(p)
    -- the party trails you (and stands by the portal while you wait in it)
    for _, u in ipairs(sim:Alive("party")) do
        KeepOut(u)
        local side = (u.name == "Tank") and 2.5 or -2.5
        u.goal = { x = p.x + side, y = p.y + 2, stop = 1.2 }
    end
    -- your auto attack on the dummy
    local tgt = sim.target
    local inReach = tgt and not tgt.dead and tgt.dummy and Dist(p.x, p.y, tgt.x, tgt.y) <= K.MELEE + 1
    p.act = inReach and "ready" or nil
    if inReach then
        if not p.moving then p.facing = math.atan2(tgt.y - p.y, tgt.x - p.x) end
        if sim.time >= (p.swingAt or 0) then
            p.swingAt = sim.time + 2.6
            if not K.Busy(sim, p) then K.Anim(sim, p, K.ANIM_2H, 0.9) end
            DummyHit(sim, p, tgt, sim:Random(260, 340))
        end
    end
    local m = sim.meter
    if m and sim.time - m.last <= 6 then
        local secs = max(1, m.last - m.first)
        sim.status = { string.format("Practice Dummy: |cffffd100%d|r damage a second (%d in %d sec)",
                                     floor(m.total / secs + 0.5), m.total, floor(secs + 0.5)) }
    else
        sim.status = nil
    end
    -- a station's card closes when you walk away from it
    local c = sim.card
    if c and not c.keep then
        local near = false
        for _, u in ipairs(sim.units) do
            if u.interact and Dist(p.x, p.y, u.x, u.y) <= (u.interactRange or 4) + 1.5 then near = true end
        end
        if not near then sim.card = nil end
    end
    -- the portal: step in and the party is asked; everyone ready, you all go
    local inPortal = Dist(p.x, p.y, PORTAL.x, PORTAL.y) <= PORTAL.r
    if inPortal and not sim.ready and not sim.goto then StartReady(sim) end
    if sim.ready then
        for _, mb in ipairs(sim.ready.members) do
            if mb.okAt and sim.time >= mb.okAt then mb.ok = true end
        end
        if ReadyCard(sim) and not sim.goto then
            sim.goto, sim.gotoDiff = "ramparts", sim.diff.id      -- (the pool has one dungeon so far)
        end
    end
end

-- F: in the portal it answers the ready check; else the nearest station in reach (Sim:Interact).
local function Interact(sim)
    if sim.ready then
        sim.ready.members[1].ok = true
        return true
    end
    return sim:Interact()
end

T:RegisterEncounter("hub", {
    game = "portal",
    name = "The World's End Tavern",
    desc = "The Portal's hub: set the Portal level, then step through the portal with your party.",
    icon = "Interface\\Icons\\INV_Drink_05",
    order = 10,
    displays = DISPLAYS,
    arena = arena,
    -- the dungeons' follow camera, here looking south into the tavern from its door; right-drag turns it up to 60
    -- degrees either way
    camera = { pitch = 0.9, dist = 26, yaw = -pi / 2, turn = pi / 3 },
    interactKey = "F",
    interact = Interact,
    cards = { level = LevelCard },            -- (the panel shows the level card again after a change)
    difficulties = {
        { id = "p0", name = "Portal level 0" },
        { id = "p5", name = "Portal level 5" },
        { id = "p10", name = "Portal level 10" },
    },
    player = { x = ARRIVE_X, y = ARRIVE_Y, speed = 7, facing = -pi / 2 },
    abilities = abilities,
    howTo = { "WASD moves you; hold the right mouse button to turn the camera, wheel to zoom. F uses what is near.",
              "Set the Portal level at the pedestal, then step into the portal in the east hall.",
              "|cffffd1001|r Heroic Strike, |cffffd1002|r Cleave, |cffffd1003|r Bandage: try them on the practice dummy." },
    start = Start,
    update = Update,
    score = function() return 0 end,
    summary = function() return {} end,
})
