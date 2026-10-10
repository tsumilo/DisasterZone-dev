-- DisasterZone_Rooms Load.lua
-- DisasterZone's 3D room data as an addon of its own, loaded on demand: every encounter room the strategy board's
-- 3D view draws (Rooms/<Raid>_<Boss>.lua), the Raid Trainer's floors (Rooms/<Name>Floor.lua) and the rooms'
-- stand-ins (Standins/). That is about 18 MB of packed text in Lua memory, so it stays on disk until a 3D view or the
-- Raid Trainer first needs a room (DisasterZone's Render3D/Rooms.lua R3.LoadData), and is only read then.
--
-- The data files write into DisasterZone's namespace (ns.RoomFloors, ns.TrainerFloors, ns.RoomStandins,
-- ns.RoomStandinGaps, ns.RoomDepthModes), as they did while they were part of it. The client hands this addon a
-- namespace of its own: here it passes every read and write through to DisasterZone's (the global DisasterZone,
-- Core/Init.lua). The files are not patched in game: a changed room ships with a full release (dev/tools/release.py).
local _, ns = ...
local main = DisasterZone
if type(ns) == "table" and type(main) == "table" and main ~= ns then
    setmetatable(ns, { __index = main, __newindex = main })
end
