if DisasterZoneBoot and DisasterZoneBoot.Run("Core/PatchKey.lua", ...) then return end -- DisasterZone: public key in-game updates are verified with (written by dev/tools/release.py keygen).
-- The private half lives only on the publisher's machine. Core/Patch.lua explains the scheme.
local addonName, ns = ...

ns.PatchKey = {
    seed = "64e4a22b3db0f56045a329c3aec1769d",
    root = "9b703655eeb0f04ab4c8da1bdbc16cb8dbaa5fe4e0afd1dac7fa179dce7d605d",
    h = 10,
}
