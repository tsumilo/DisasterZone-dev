if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Portal/Hub.lua", ...) then return end -- DisasterZone Games/Portal/Hub.lua
-- The Portal's hub (PROTOTYPE 2026-10-09): the Stair of Destiny, the platform where the Dark Portal lets out in
-- Outland. You arrive here, pick a Portal level (the toolbar's second list) and walk into the Portal: a dungeon from
-- the pool opens at that level (today the pool is Hellfire Ramparts' first room). A finished run, kept or void,
-- brings you back here. Grouping up with your real party is the next step; for now a tank and a healer wait with you.
--
-- Where things come from:
--   the Dark Portal faces west (Hellfire Peninsula); its whole WMO (file 115769, 46k faces) is far over the room
--     renderer's budget, so its front is a pre-rendered backdrop standing in the gate's plane (world y 946.8):
--     generators/gen_portal_facade.py renders it straight-on with the client's textures into Media/Portal/
--     Facade_Low.blp and Facade_High.blp (world x -385..-105 across, height 82..362); Games/Portal/UI.lua DrawFacade
--     puts it in the scene, under the live floor and every model;
--   the live floor: the platform and the Stair of Destiny in front of the gate (generators/gen_dungeon_proto.py hub ->
--     Render3D/Rooms/Portal_StairOfDestiny.lua: map 530, world x -320..-170 by y 948..1078, walls cut 8 yd up; height
--     0 = the platform, the stair's foot 30 yd under it);
--   the Portal's swirl: painted into the backdrop's mouth from the swirl model's own textures (Hellfire_DarkPortal_FX,
--     model 192920, the WMO's only doodad): the live model is a 160 yd see-through volume that models draw over
--     the backdrop, so in game (2026-10-09) it covered the whole gate;
--   the camera: behind you, looking east up at the gate from the foot of its stair (camera.lift, fov: Portal UI).
-- NOT verified in game: the backdrop's seams against the live floor, the mouth's box.
local addonName, ns = ...

local T = ns.Trainer
local pi = math.pi

local ROOM = "Portal_StairOfDestiny"
-- room coordinates (gen_dungeon_proto.py hub: box world x -320..-170, y 948..1078): room x = 1078 - world y (east),
-- room y = world x + 320 (north), height 0 = the platform (world 84.35)
local GATE_X = 131.2                                   -- the gate's plane (world y 946.8), facing west
local ARRIVE_X, ARRIVE_Y = 50, 74.3                    -- at the foot of the Stair of Destiny, facing the gate
local MOUTH = { x = GATE_X - 4, y0 = 45, y1 = 104 }    -- walk up to the plane between these to go through
-- the Dark Portal's front, pre-rendered (generators/gen_portal_facade.py: world x -385..-105 across, height 82..362)
local FACADE_DIR = "Interface\\AddOns\\DisasterZone\\Media\\Portal\\"
local FACADE = {
    { file = FACADE_DIR .. "Facade_Low", x = GATE_X, yl = 215, yr = -65, z0 = -2.35, z1 = 137.65, cols = 7, rows = 7 },
    { file = FACADE_DIR .. "Facade_High", x = GATE_X, yl = 215, yr = -65, z0 = 137.65, z1 = 277.65, cols = 7, rows = 4 },
}
local DISPLAY_TANK, DISPLAY_HEALER = 22931, 22973

local arena = { w = 130, h = 150 }
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

local DISPLAYS = {
    [DISPLAY_TANK] = { scale = 1, chest = 1.50, head = 2.19, hand = 1.03, name = 2.22 },
    [DISPLAY_HEALER] = { scale = 1, chest = 1.35, head = 2.04, hand = 0.93, name = 2.08 },
}

local function Start(sim)
    local p = sim.player
    p.hp, p.hpMax = 9000, 9000
    sim:Spawn({ kind = "party", name = "Tank", x = ARRIVE_X - 3, y = ARRIVE_Y + 3, hp = 14000, radius = 0.9,
                color = { 0.3, 0.6, 1 }, display = DISPLAY_TANK, selectable = true, facing = 0,
                plate = DISPLAYS[DISPLAY_TANK].name + 0.4 })
    sim:Spawn({ kind = "party", name = "Healer", x = ARRIVE_X - 3, y = ARRIVE_Y - 3, hp = 7000, radius = 0.9,
                color = { 0.3, 1, 0.6 }, display = DISPLAY_HEALER, selectable = true, facing = 0,
                plate = DISPLAYS[DISPLAY_HEALER].name + 0.4 })
    sim.marks = nil
    sim.objective = "Pick a Portal level above, then walk into the Dark Portal."
    sim:Banner("The Stair of Destiny", 3, 1, 0.8, 0.35)
end

local function Update(sim)
    local p = sim.player
    if p.x >= MOUTH.x and p.y >= MOUTH.y0 and p.y <= MOUTH.y1 and not sim.goto then
        sim.goto, sim.gotoDiff = "ramparts", sim.diff.id      -- (the pool has one dungeon so far)
    end
end

T:RegisterEncounter("hub", {
    game = "portal",
    name = "The Stair of Destiny",
    desc = "The Portal's hub: pick a Portal level and walk into the Dark Portal.",
    icon = "Interface\\Icons\\Spell_Arcane_PortalShattrath",
    order = 10,
    displays = DISPLAYS,
    arena = arena,
    -- behind you, aimed 10 yd over your head and tilted slightly up through a wide lens: you stay in the lower third
    -- and the gate fills the rest, from the stair's foot to its mouth (checked with dev/art/crawler/hub_paint.py,
    -- 2026-10-10; the old 22 yd lift / -0.25 pitch left you off the bottom of the screen)
    camera = { pitch = -0.05, dist = 40, yaw = 0, lift = 10, fov = 1.35, zoom = false },  -- (zooming out would sink it)
    facade = FACADE,
    sky = 130593,                         -- the twisting nether (environments/stars/netherstormskybox.m2)
    difficulties = {
        { id = "p0", name = "Portal level 0" },
        { id = "p5", name = "Portal level 5" },
        { id = "p10", name = "Portal level 10" },
    },
    player = { x = ARRIVE_X, y = ARRIVE_Y, speed = 7, facing = 0 },
    abilities = {},
    howTo = { "WASD moves you; the camera looks at the Portal.", "Pick a Portal level, then walk into the Portal." },
    start = Start,
    update = Update,
    score = function() return 0 end,
    summary = function() return {} end,
})
