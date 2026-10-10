if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SimNerd.lua", ...) then return end -- DisasterZone: UI/SimNerd.lua
local _, ns = ...

local Nerd = {}
ns.SimNerd = Nerd

function Nerd:Open() end
function Nerd:Close() end
function Nerd:Refresh() end
