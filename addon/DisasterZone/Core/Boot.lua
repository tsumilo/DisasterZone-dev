-- DisasterZone: boot loader for in-game updates. The first DisasterZone file to run.
--
-- An in-game update ("patch") is the full text of every file that changed since the release on disk, stored in
-- the saved variable DisasterZonePatchDB by Core/Patch.lua once it has been downloaded and its signature checked.
-- Every other DisasterZone file starts with a guard,
--     if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Util.lua", ...) then return end
-- and Run() executes the patched text instead of the file on disk when a patch applies. That needs the saved
-- variables BEFORE the files run: "## LoadSavedVariablesFirst: 1" in the TOC.
--
-- This file is the part that can never be updated in game, so it does as little as possible and trusts nothing:
--  * a patch applies only to the exact build it was made for (DisasterZoneBuild.id from Core/BuildInfo.lua);
--  * every patched file is checksummed and compiled before the first one runs: one bad file rejects the patch;
--  * an error while a patched file runs puts the addon in safe mode for the session (nothing else loads, saved
--    data is not touched), marks the patch bad and offers a reload, after which the files on disk run;
--  * /dzpatch (registered here) keeps working whatever state the rest of the addon is in.
--
-- It also handles the move from CDLoot, the addon's name before 0.12 ("Moving from CDLoot" below): while the
-- old addon is loaded nothing of DisasterZone runs, and a dialog offers to copy its saved data over.
-- Nothing here reloads the interface by itself.
local addonName, ns = ...

local Boot = {}
DisasterZoneBoot = Boot
if type(ns) == "table" then ns.Boot = Boot end

local type, tostring, tonumber, pairs, ipairs, next, pcall = type, tostring, tonumber, pairs, ipairs, next, pcall
local byte = string.byte

local CHAT_PREFIX = "|cffff8000DisasterZone|r: "

local build = type(DisasterZoneBuild) == "table" and DisasterZoneBuild or {}
Boot.buildId = type(build.id) == "string" and build.id or "dev"
Boot.isDev = Boot.buildId == "dev"            -- the source tree, not a packaged release: patches never apply
Boot.assetPack = tonumber(build.assetPack) or 0

---------------------------------------------------------------------------
-- Saved state
---------------------------------------------------------------------------

-- With LoadSavedVariablesFirst the saved table exists now. Without it (first run, or a client that ignores
-- the directive) it does not, and the client assigns it after the files ran: DB() notices and adopts that table.
local svAtFileTime = type(DisasterZonePatchDB) == "table"
if not svAtFileTime then DisasterZonePatchDB = {} end
local db = DisasterZonePatchDB

-- true: saved variables were readable at file time (in-game updates work). false: the client loaded them after
-- the files (the directive is not honoured). nil: not known yet (no saved data before this session).
Boot.svFirst = svAtFileTime or nil

function Boot.DB()
    local current = DisasterZonePatchDB
    if current ~= db then
        if type(current) == "table" then
            db = current
            if not svAtFileTime then Boot.svFirst = false end
        else
            DisasterZonePatchDB = db
        end
    end
    db.probe = true
    return db
end

-- The addon was called CDLoot before 0.12. Both would use the same addon-message prefixes, so they never run
-- together: with the old addon loaded (it loads first: OptionalDeps in the TOC) every DisasterZone file is skipped.
local OLD_ADDON, OLD_DB = "CDLoot", "CDLootDB"

local function OldIsLoaded()
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if isLoaded then
        local ok, loadedOrLoading = pcall(isLoaded, OLD_ADDON)
        if ok and loadedOrLoading then return true end
    end
    return type(_G[OLD_ADDON .. "Boot"]) == "table" or type(_G[OLD_ADDON]) == "table"
end

Boot.dormant = OldIsLoaded() or nil
local noDataAtFileTime = type(DisasterZoneDB) ~= "table"

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Output(text)
    local frame = DEFAULT_CHAT_FRAME
    if frame and frame.AddMessage then
        frame:AddMessage(CHAT_PREFIX .. text)
    elseif print then
        print(CHAT_PREFIX .. text)
    end
end

-- Adler-32 of a string (the checksum the patch manifest carries for every file).
local function Adler32(s)
    local a, b = 1, 0
    local n = #s
    local i = 1
    while i + 7 <= n do
        local x1, x2, x3, x4, x5, x6, x7, x8 = byte(s, i, i + 7)
        a = a + x1; b = b + a
        a = a + x2; b = b + a
        a = a + x3; b = b + a
        a = a + x4; b = b + a
        a = a + x5; b = b + a
        a = a + x6; b = b + a
        a = a + x7; b = b + a
        a = a + x8; b = b + a
        a = a % 65521
        b = b % 65521
        i = i + 8
    end
    while i <= n do
        a = (a + byte(s, i)) % 65521
        b = (b + a) % 65521
        i = i + 1
    end
    return b * 65536 + a
end
Boot.Adler32 = Adler32

local function MarkBad(seq, reason)
    if type(db.bad) ~= "table" then db.bad = {} end
    db.bad[seq] = tostring(reason)
end

---------------------------------------------------------------------------
-- Decide whether the stored patch applies, and compile it
---------------------------------------------------------------------------

local SKIP = {}        -- plan value: the file was deleted by the patch
local plan             -- [path] = compiled chunk | SKIP   (nil: no patch applies, every file runs from disk)
local extras           -- [path] = { { path =, fn = } ... }: new files that run right before that disk file
local tail             -- new files that run after the last disk file (Boot.End)
local running          -- path of the patched file being executed (its own guard must not recurse)
local lastError

Boot.state = "none"    -- none | off | base | bad | malformed | rejected | applied | safemode | dormant
Boot.detail = nil      -- why (rejected / safemode)
Boot.applied = nil     -- { seq =, version =, pack =, files = n } while a patch is running
Boot.safeMode = nil    -- { seq =, version =, path =, err = } after a patched file failed to load
Boot.startupErrors = 0

local function Decide()
    local p = db.active
    if type(p) ~= "table" then return "none" end
    local try = db.tryOnce
    db.tryOnce = nil
    if db.off then return "off" end
    if type(p.seq) ~= "number" or type(p.version) ~= "string" or type(p.files) ~= "table"
        or type(p.sums) ~= "table" or type(p.list) ~= "table" then
        return "malformed"
    end
    if type(db.bad) == "table" and db.bad[p.seq] then return "bad", db.bad[p.seq] end
    if p.base ~= Boot.buildId and not (try and Boot.isDev) then return "base" end
    if not loadstring then return "rejected", "loadstring is not available" end

    local newPlan, newExtras, newTail = {}, {}, {}
    local count = 0
    for _, e in ipairs(p.list) do
        local kind, path = type(e) == "table" and e.k, type(e) == "table" and e.p
        if type(path) ~= "string" or newPlan[path] ~= nil then
            return "rejected", "malformed file list"
        end
        if kind == "D" then
            newPlan[path] = SKIP
        elseif kind == "F" or kind == "N" then
            local src = p.files[path]
            if type(src) ~= "string" then
                return "rejected", "missing text of " .. path
            end
            if Adler32(src) ~= p.sums[path] then
                return "rejected", "checksum mismatch in " .. path
            end
            local fn, err = loadstring(src, "@Interface/AddOns/" .. tostring(addonName) .. "/" .. path)
            if not fn then
                return "rejected", "syntax error: " .. tostring(err)
            end
            count = count + 1
            if kind == "F" then
                newPlan[path] = fn
            else
                newPlan[path] = false   -- reserves the path (duplicate check); never looked up by a disk file
                local before = e.b
                if type(before) == "string" and before ~= "" then
                    local list = newExtras[before]
                    if not list then list = {}; newExtras[before] = list end
                    list[#list + 1] = { path = path, fn = fn }
                else
                    newTail[#newTail + 1] = { path = path, fn = fn }
                end
            end
        else
            return "rejected", "malformed file list"
        end
    end
    plan, extras, tail = newPlan, newExtras, newTail
    Boot.applied = { seq = p.seq, version = p.version, pack = tonumber(p.pack) or 0, files = count }
    return "applied"
end

if Boot.dormant then
    Boot.state = "dormant"
else
    local ok, state, detail = pcall(Decide)
    if not ok then
        state, detail = "rejected", tostring(state)
        plan, extras, tail = nil, nil, nil
        Boot.applied = nil
    end
    Boot.state, Boot.detail = state, detail
    if state == "rejected" and type(db.active) == "table" and type(db.active.seq) == "number" then
        MarkBad(db.active.seq, detail)
    end
end

---------------------------------------------------------------------------
-- Running files
---------------------------------------------------------------------------

local function OnLoadError(err)
    lastError = tostring(err)
    local handler = geterrorhandler and geterrorhandler()
    if handler then pcall(handler, err) end
    return err
end

local function EnterSafeMode(path)
    local a = Boot.applied or {}
    Boot.safeMode = { seq = a.seq, version = a.version, path = path, err = lastError or "?" }
    Boot.state, Boot.detail = "safemode", path .. ": " .. tostring(lastError)
    Boot.applied = nil
    if a.seq then MarkBad(a.seq, "load error in " .. path .. ": " .. tostring(lastError)) end
end

local function Exec(path, fn, a1, a2)
    running = path
    lastError = nil
    local ok = xpcall(function() return fn(a1, a2) end, OnLoadError)
    running = nil
    if not ok then EnterSafeMode(path) end
    return ok
end

-- The guard on line 1 of every DisasterZone file. True: the caller must return (its patched text ran instead, the
-- patch deleted it, the addon is in safe mode, or CDLoot is still loaded). False: the file on disk runs.
function Boot.Run(path, ...)
    if Boot.safeMode or Boot.dormant then return true end
    if not plan then return false end
    if running == path then return false end
    local before = extras[path]
    if before then
        extras[path] = nil
        for i = 1, #before do
            if not Exec(before[i].path, before[i].fn, ...) then return true end
        end
    end
    local entry = plan[path]
    if not entry then return false end
    if entry == SKIP then return true end
    Exec(path, entry, ...)
    return true
end

-- Called by Core/BootEnd.lua, the last file in the TOC: runs the new files that go after everything else.
function Boot.End(...)
    if Boot.safeMode or Boot.dormant or not plan then return end
    local rest = tail
    for _, list in pairs(extras) do     -- slots whose anchor file never ran (should not happen)
        for i = 1, #list do rest[#rest + 1] = list[i] end
    end
    extras, tail = {}, {}
    for i = 1, #rest do
        if not Exec(rest[i].path, rest[i].fn, ...) then return end
    end
end

---------------------------------------------------------------------------
-- Startup health (Core/Init.lua reports lifecycle errors while a patch is running)
---------------------------------------------------------------------------

function Boot.NoteStartupError()
    Boot.startupErrors = Boot.startupErrors + 1
end

-- Marks the running patch bad (it is skipped from the next load on). The caller reloads.
function Boot.Rollback(reason)
    local a = Boot.applied
    if not a then return false end
    Boot.DB()
    MarkBad(a.seq, reason or "rolled back by the player")
    return true
end

---------------------------------------------------------------------------
-- Dialog (self-contained: usable when the rest of the addon did not load)
---------------------------------------------------------------------------

local dialog

local function ShowDialog(text, acceptText, onAccept, cancelText)
    if not CreateFrame or not UIParent then return end
    if not dialog then
        local f = CreateFrame("Frame", "DisasterZoneBootDialog", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        f:SetSize(420, 170)
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
        f:SetFrameStrata("DIALOG")
        if f.SetBackdrop then
            f:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 24,
                insets = { left = 6, right = 6, top = 6, bottom = 6 },
            })
        end
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f.title:SetPoint("TOP", f, "TOP", 0, -16)
        f.title:SetText("|cffff8000Disaster|rZone")
        f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        f.text:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -44)
        f.text:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -44)
        f.text:SetJustifyH("LEFT")
        f.accept = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        f.accept:SetSize(150, 24)
        f.accept:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 16)
        f.cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        f.cancel:SetSize(150, 24)
        f.cancel:SetPoint("BOTTOMLEFT", f, "BOTTOM", 6, 16)
        f.cancel:SetScript("OnClick", function() f:Hide() end)
        dialog = f
    end
    dialog.text:SetText(text)
    dialog.accept:SetText(acceptText)
    dialog.accept:SetScript("OnClick", function()
        dialog:Hide()
        if onAccept then onAccept() end
    end)
    dialog.cancel:SetText(cancelText or "Later")
    dialog:Show()
end
Boot.ShowDialog = ShowDialog

local function Reload()
    if ReloadUI then ReloadUI() end
end

local function ShowSafeMode()
    local s = Boot.safeMode
    Output("|cffff3333the in-game update " .. tostring(s.version) .. " failed to load|r (" .. tostring(s.path)
        .. ") and was switched off. Reload to go back to the installed version.")
    ShowDialog("The in-game update " .. tostring(s.version) .. " failed to load and has been switched off.\n\n"
        .. "DisasterZone is not running right now. Reload the interface to go back to the version you have installed.",
        "Reload", Reload, "Not now")
end

-- Core/Init.lua calls this after the login stage of every module ran.
function Boot.LifecycleDone()
    local a = Boot.applied
    if not a then return end
    Boot.DB()
    db.lastLoad = { seq = a.seq, version = a.version, errors = Boot.startupErrors }
    if Boot.startupErrors > 0 then
        Output("the in-game update " .. tostring(a.version) .. " had " .. Boot.startupErrors
            .. " error(s) while starting. |cffffd100/dzpatch rollback|r goes back to the installed version.")
        ShowDialog("DisasterZone " .. tostring(a.version) .. " (in-game update) had " .. Boot.startupErrors
            .. " error(s) while starting.\n\nYou can go back to the version you have installed. "
            .. "That needs a reload of the interface.",
            "Roll back + reload", function()
                Boot.Rollback("errors while starting")
                Reload()
            end, "Keep it")
    end
end

---------------------------------------------------------------------------
-- Moving from CDLoot
---------------------------------------------------------------------------
-- DisasterZone is a new addon folder, so the client gives it a new, empty saved-variables file; the old data
-- is only in memory while the old addon is loaded. With both installed the old one runs for that session, this
-- one stays dormant and offers to copy CDLootDB into DisasterZoneDB, switch CDLoot off and reload.
--  * the copy is made at the click, never before: CDLoot keeps writing to its data until the reload;
--  * it only fills an empty DisasterZoneDB (/dzpatch import replaces existing data, on request);
--  * CDLootDB is copied, not moved: its file stays on disk untouched;
--  * the old stored in-game update (CDLootPatchDB) is for a CDLoot build and is not taken over.

local function IsFresh(t)
    return type(t) ~= "table" or (t.schema == nil and next(t) == nil)
end

local function CopyValue(v, seen)
    if type(v) ~= "table" then return v end
    local out = seen[v]
    if out then return out end
    out = {}
    seen[v] = out
    for k, val in pairs(v) do
        local tk, tv = type(k), type(val)
        if (tk == "string" or tk == "number" or tk == "boolean")
            and (tv == "string" or tv == "number" or tv == "boolean" or tv == "table") then
            out[k] = CopyValue(val, seen)
        end
    end
    return out
end

-- Copies the old addon's saved data. force: also when DisasterZone already has data (it is replaced).
-- Returns true, or false and "running" (DisasterZone is running: the old addon is not loaded), "nodata" or
-- "hasdata".
function Boot.ImportOld(force)
    if not Boot.dormant then return false, "running" end
    local old = _G[OLD_DB]
    if type(old) ~= "table" then return false, "nodata" end
    if not force and not IsFresh(DisasterZoneDB) then return false, "hasdata" end
    local copy = CopyValue(old, {})
    copy.migratedFrom = { addon = OLD_ADDON, at = time and time() or 0 }
    DisasterZoneDB = copy
    Boot.imported = true
    return true
end

-- Unticks the old addon for every character. The client applies it at the next reload.
local function DisableOld()
    local ok = false
    if C_AddOns and C_AddOns.DisableAddOn then
        ok = pcall(C_AddOns.DisableAddOn, OLD_ADDON)
    elseif DisableAddOn then
        ok = pcall(DisableAddOn, OLD_ADDON, true)
    end
    return ok
end

local STILL_ON_HINT = "\n\nIf " .. OLD_ADDON .. " is still on after the reload, untick it in the AddOns list "
    .. "(Esc > AddOns)."

local function SwitchOver()
    DisableOld()
    Reload()
end

local function ShowMove()
    if Boot.imported then
        ShowDialog("Your " .. OLD_ADDON .. " data is copied. Next: " .. OLD_ADDON .. " is switched off and the "
            .. "interface reloads. After that DisasterZone runs." .. STILL_ON_HINT, "Switch off + reload", SwitchOver)
    elseif type(_G[OLD_DB]) == "table" and IsFresh(DisasterZoneDB) then
        Output(OLD_ADDON .. " is now called DisasterZone. It stays off until your " .. OLD_ADDON
            .. " data is copied over (|cffffd100/dzpatch|r shows the question again).")
        ShowDialog(OLD_ADDON .. " is now called DisasterZone.\n\nImport copies your " .. OLD_ADDON
            .. " data (BiS lists, loot log, settings, games), switches " .. OLD_ADDON .. " off and reloads. The "
            .. OLD_ADDON .. " data stays on disk as a backup.", "Import + reload", function()
                if Boot.ImportOld() then SwitchOver() end
            end)
    else
        Output("|cffff3333" .. OLD_ADDON .. " is still switched on|r, so DisasterZone is not running "
            .. "(|cffffd100/dzpatch|r shows the question again).")
        ShowDialog(OLD_ADDON .. " is still switched on. DisasterZone replaces it and the two cannot run together, "
            .. "so DisasterZone is not running right now." .. STILL_ON_HINT, "Switch off + reload", SwitchOver)
    end
end

-- A login without the old addon loaded: says once what happened to the old data.
local function MoveNotes()
    local m = type(DisasterZoneDB) == "table" and DisasterZoneDB.migratedFrom
    if type(m) == "table" then
        if not m.told then
            m.told = true
            Output("your " .. OLD_ADDON .. " data was imported. The " .. OLD_ADDON .. " folder can be deleted now. "
                .. "|cffffd100/dz|r opens the window (/cdl still works).")
        end
    elseif noDataAtFileTime and not db.oldHint and C_AddOns and C_AddOns.DoesAddOnExist then
        local ok, exists = pcall(C_AddOns.DoesAddOnExist, OLD_ADDON)
        if ok and exists then
            db.oldHint = true
            Output(OLD_ADDON .. " is installed but switched off, so its data was not imported. To bring it over: "
                .. "tick " .. OLD_ADDON .. " in the AddOns list, reload, then type |cffffd100/dzpatch import|r.")
        end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

if CreateFrame then
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("ADDON_LOADED")
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:SetScript("OnEvent", function(_, event, name)
        if event == "ADDON_LOADED" then
            if name == addonName then Boot.DB() end
        elseif event == "PLAYER_LOGIN" then
            Boot.DB()
            if Boot.dormant then
                ShowMove()
            else
                MoveNotes()
                if Boot.safeMode then ShowSafeMode() end
            end
        end
    end)
end

---------------------------------------------------------------------------
-- /dzpatch
---------------------------------------------------------------------------

local STATE_TEXT = {
    none = "no in-game update is stored",
    off = "in-game updates are switched off (/dzpatch on)",
    base = "the stored update is for another build and is ignored",
    bad = "the stored update is marked bad and is ignored",
    malformed = "the stored update is damaged and is ignored",
    rejected = "the stored update was rejected",
    applied = "running an in-game update",
    safemode = "SAFE MODE: an in-game update failed to load",
    dormant = "DisasterZone is not running: CDLoot (its old name) is still switched on",
}

function Boot.StatusLines()
    Boot.DB()
    local lines = {}
    lines[#lines + 1] = "installed build " .. Boot.buildId .. ", art pack " .. Boot.assetPack
        .. (Boot.isDev and " (development copy: updates never apply here)" or "")
    local sv = Boot.svFirst
    lines[#lines + 1] = "saved variables before files: "
        .. (sv == true and "|cff33ff33yes|r" or (sv == false and "|cffff3333no (in-game updates cannot apply on this client)|r")
            or "not known yet (reload once)")
    local text = STATE_TEXT[Boot.state] or tostring(Boot.state)
    if Boot.applied then
        text = text .. ": " .. tostring(Boot.applied.version) .. " (#" .. tostring(Boot.applied.seq) .. ", "
            .. tostring(Boot.applied.files) .. " file(s))"
    end
    if Boot.detail then text = text .. " - " .. tostring(Boot.detail) end
    lines[#lines + 1] = text
    local p = db.active
    if type(p) == "table" and not Boot.applied then
        lines[#lines + 1] = "stored: " .. tostring(p.version) .. " (#" .. tostring(p.seq) .. ") for build " .. tostring(p.base)
    end
    return lines
end

local function HandleSlash(input)
    Boot.DB()
    local sub = type(input) == "string" and input:match("^%s*(%S*)") or ""
    sub = sub:lower()
    if sub == "import" then
        local ok, why = Boot.ImportOld(true)
        if ok then
            Output("copied your " .. OLD_ADDON .. " data. It replaces DisasterZone's data at the reload.")
            ShowMove()
        elseif why == "running" then
            Output("import needs " .. OLD_ADDON .. " switched on: tick it in the AddOns list, reload, and type this again.")
        else
            Output(OLD_ADDON .. " has no saved data to import.")
        end
    elseif Boot.dormant and sub == "" then
        for _, line in ipairs(Boot.StatusLines()) do Output(line) end
        ShowMove()
    elseif sub == "off" then
        db.off = true
        Output("in-game updates are switched off. Reload to run the installed version.")
    elseif sub == "on" then
        db.off = nil
        Output("in-game updates are switched on.")
    elseif sub == "rollback" then
        if Boot.Rollback() then
            Output("the in-game update is marked bad. Reload to go back to the installed version.")
            ShowDialog("The in-game update will be skipped from now on.\n\nReload the interface to go back to the "
                .. "version you have installed.", "Reload", Reload)
        else
            Output("no in-game update is running.")
        end
    elseif sub == "retry" then
        db.bad = nil
        Output("forgot which updates were marked bad. A stored update runs again after a reload; one that was "
            .. "dropped is downloaded again when a guild member offers it.")
    elseif sub == "try" then
        if not Boot.isDev then
            Output("'try' only exists in the development copy.")
        elseif type(db.active) ~= "table" then
            Output("nothing is stored. Publish first (/dz publish).")
        else
            db.tryOnce = true
            Output("the stored update will run once on the next reload, whatever build it was made for.")
        end
    else
        for _, line in ipairs(Boot.StatusLines()) do Output(line) end
        Output("|cffffd100/dzpatch off|r, |cffffd100on|r, |cffffd100rollback|r, |cffffd100retry|r")
    end
end

SLASH_DISASTERZONEPATCH1 = "/dzpatch"
if SlashCmdList then
    SlashCmdList["DISASTERZONEPATCH"] = HandleSlash
end
