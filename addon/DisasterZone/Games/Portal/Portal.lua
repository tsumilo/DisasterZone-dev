if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Portal/Portal.lua", ...) then return end -- DisasterZone Games/Portal/Portal.lua
-- The Portal (working title; PROTOTYPE 2026-10-09): a 3D dungeon crawler that is to replace Disastercraft. From a
-- hub at the Stair of Destiny you go through the Dark Portal, alone or with your party, into a random dungeon from a
-- pool, at a Portal level that scales without end; levels and gear grow with you. Clear the run and what you earned
-- is kept; die (the whole party) or leave on purpose and the run is void. Real Blizzard dungeon layouts, the game's
-- own models and effects (nothing drawn by us). Today: one room of Hellfire Ramparts (Games/Portal/Dungeons/).
-- The panel is Games/Portal/UI.lua; the sim engine is the Raid Trainer's (Games/Trainer/Engine.lua).
local addonName, ns = ...

local Portal = ns:NewModule("Portal")
Portal.GAME_ID = "portal"

function Portal:OnInit()
    if not ns.Games or not ns.PortalUI then return end
    ns.Games:Register(Portal.GAME_ID, {
        name = "Portal",
        desc = "Through the Dark Portal into a real dungeon, in 3D, alone or with your party. Prototype: one room of "
            .. "Hellfire Ramparts. WASD to move, Tab to target, number keys to fight.",
        tagline = "Through the Dark Portal: endless dungeons in 3D.",
        icon = "Interface\\Icons\\Spell_Fire_FelFlameRing",
        order = 100,                     -- (last in the hub until it replaces Disastercraft)
        create = function(parent) return ns.PortalUI:CreatePanel(parent) end,
    })
end
