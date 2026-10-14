if DisasterZoneBoot and DisasterZoneBoot.Run("Core/BridgeKey.lua", ...) then return end -- DisasterZone: public key Discord bridge records are verified with (written by dz-server keygen).
-- The private half lives only on the bot's server. Core/Bridge.lua explains the scheme.
local addonName, ns = ...

ns.BridgeKey = {
    seed = "70378262db287423a33d63222fc7456a",
    root = "93ed344536965f6d3a9fb3e10f8972406bf14af6284a1313f2a0da94ec6ff106",
    h = 16,
}
