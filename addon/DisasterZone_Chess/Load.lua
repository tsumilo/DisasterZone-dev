-- DisasterZone game pack: the first file in the TOC (dev/docs/GAME_PACKS.md). Gives the pack's files the main addon's
-- namespace (what they read and the modules they make are DisasterZone's), then has the boot loader check that this
-- pack belongs to the installed release (Core/Boot.lua CheckPack: a pack from another release is skipped whole).
-- Never part of an in-game update.
local folder, ns = ...
local main = DisasterZone
if type(ns) == "table" and type(main) == "table" and main ~= ns then
    setmetatable(ns, { __index = main, __newindex = main })
end
if DisasterZoneBoot and DisasterZoneBoot.CheckPack then DisasterZoneBoot.CheckPack(folder) end
