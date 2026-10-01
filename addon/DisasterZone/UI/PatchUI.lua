if DisasterZoneBoot and DisasterZoneBoot.Run("UI/PatchUI.lua", ...) then return end -- DisasterZone: in-game update notices: the "update is ready, reload?" popup and the login lines.
-- The popup is shown once per update and session, never in combat or during an encounter.
local addonName, ns = ...

local PatchUI = ns:NewModule("PatchUI")
local Util = ns.Util

local POPUP = "DISASTERZONE_PATCH_READY"
local offered = {}       -- [seq] = true: the popup was shown this session
local inEncounter = false
local waiting = false    -- a popup is due once combat / the encounter ends

local function Busy()
    return inEncounter or (InCombatLockdown and InCombatLockdown()) and true or false
end

local function Offer()
    local Patch = ns.Patch
    local ready = Patch and Patch.ready
    if not ready or offered[ready.seq] then return end
    if Busy() then
        waiting = true
        return
    end
    waiting = false
    offered[ready.seq] = true
    if not (StaticPopupDialogs and StaticPopup_Show) then return end
    if not StaticPopupDialogs[POPUP] then
        StaticPopupDialogs[POPUP] = {
            text = "DisasterZone %s is ready.\n\nReload the interface now to use it?",
            button1 = "Reload",
            button2 = "Later",
            OnAccept = function()
                if ReloadUI then ReloadUI() end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    StaticPopup_Show(POPUP, tostring(ready.version))
end

function PatchUI:OnInit()
    ns:On("PATCH_UPDATED", Offer)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if waiting then Util.After(1, Offer) end
    end)
    ns:RegisterEvent("ENCOUNTER_START", function() inEncounter = true end)
    ns:RegisterEvent("ENCOUNTER_END", function()
        inEncounter = false
        if waiting then Util.After(3, Offer) end
    end)
end

function PatchUI:OnLogin()
    local Boot = ns.Boot
    if not Boot then return end
    local applied = Boot.applied
    if applied and (applied.files or 0) > 0 then     -- (an update without files is a revoke: the installed version)
        ns:Print("running %s (in-game update on top of the installed %s).", tostring(applied.version), tostring(ns.diskVersion))
        if (applied.pack or 0) > Boot.assetPack then
            ns:Print("this update has new art you do not have yet. Download the full DisasterZone %s to see it.",
                tostring(applied.version))
        end
    end
    Util.After(4, Offer)
end
