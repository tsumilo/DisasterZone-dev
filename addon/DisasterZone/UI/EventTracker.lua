if DisasterZoneBoot and DisasterZoneBoot.Run("UI/EventTracker.lua", ...) then return end -- DisasterZone: UI/EventTracker.lua (being built)
local addonName, ns = ...

local M = ns:NewModule("EventTracker")

function M:OnInit() end
