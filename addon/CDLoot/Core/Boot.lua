-- CDLoot: boot loader for in-game updates. The first CDLoot file to run.
--
-- An in-game update ("patch") is the full text of every file that changed since the release on disk, stored in
-- the saved variable CDLootPatchDB by Core/Patch.lua once it has been downloaded and its signature checked.
-- Every other CDLoot file starts with a guard,
--     if CDLootBoot and CDLootBoot.Run("Core/Util.lua", ...) then return end
-- and Run() executes the patched text instead of the file on disk when a patch applies. That needs the saved
-- variables BEFORE the files run: "## LoadSavedVariablesFirst: 1" in the TOC.
--
-- This file is the part that can never be updated in game, so it does as little as possible and trusts nothing:
--  * a patch applies only to the exact build it was made for (CDLootBuild.id from Core/BuildInfo.lua);
--  * every patched file is checksummed and compiled before the first one runs: one bad file rejects the patch;
--  * an error while a patched file runs puts the addon in safe mode for the session (nothing else loads, saved
--    data is not touched), marks the patch bad and offers a reload, after which the files on disk run;
--  * /cdlpatch (registered here) keeps working whatever state the rest of the addon is in.
-- Nothing here reloads the interface by itself.
local addonName, ns = ...

local Boot = {}
CDLootBoot = Boot
if type(ns) == "table" then ns.Boot = Boot end

local type, tostring, tonumber, pairs, ipairs = type, tostring, tonumber, pairs, ipairs
local byte = string.byte

local CHAT_PREFIX = "|cffff8000CDLoot|r: "

local build = type(CDLootBuild) == "table" and CDLootBuild or {}
Boot.buildId = type(build.id) == "string" and build.id or "dev"
Boot.isDev = Boot.buildId == "dev"            -- the source tree, not a packaged release: patches never apply
Boot.assetPack = tonumber(build.assetPack) or 0

---------------------------------------------------------------------------
-- Saved state
---------------------------------------------------------------------------

-- With LoadSavedVariablesFirst the saved table exists now. Without it (first run, or a client that ignores
-- the directive) it does not, and the client assigns it after the files ran: DB() notices and adopts that table.
local svAtFileTime = type(CDLootPatchDB) == "table"
if not svAtFileTime then CDLootPatchDB = {} end
local db = CDLootPatchDB

-- true: saved variables were readable at file time (in-game updates work). false: the client loaded them after
-- the files (the directive is not honoured). nil: not known yet (no saved data before this session).
Boot.svFirst = svAtFileTime or nil

function Boot.DB()
    local current = CDLootPatchDB
    if current ~= db then
        if type(current) == "table" then
            db = current
            if not svAtFileTime then Boot.svFirst = false end
        else
            CDLootPatchDB = db
        end
    end
    db.probe = true
    return db
end

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

Boot.state = "none"    -- none | off | base | bad | malformed | rejected | applied | safemode
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

do
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

-- The guard on line 1 of every CDLoot file. True: the caller must return (its patched text ran instead, the
-- patch deleted it, or the addon is in safe mode). False: the file on disk runs.
function Boot.Run(path, ...)
    if Boot.safeMode then return true end
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
    if Boot.safeMode or not plan then return end
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
        local f = CreateFrame("Frame", "CDLootBootDialog", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
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
        f.title:SetText("|cffff8000CD|rLoot")
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
        .. "CDLoot is not running right now. Reload the interface to go back to the version you have installed.",
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
            .. " error(s) while starting. |cffffd100/cdlpatch rollback|r goes back to the installed version.")
        ShowDialog("CDLoot " .. tostring(a.version) .. " (in-game update) had " .. Boot.startupErrors
            .. " error(s) while starting.\n\nYou can go back to the version you have installed. "
            .. "That needs a reload of the interface.",
            "Roll back + reload", function()
                Boot.Rollback("errors while starting")
                Reload()
            end, "Keep it")
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
            if Boot.safeMode then ShowSafeMode() end
        end
    end)
end

---------------------------------------------------------------------------
-- /cdlpatch
---------------------------------------------------------------------------

local STATE_TEXT = {
    none = "no in-game update is stored",
    off = "in-game updates are switched off (/cdlpatch on)",
    base = "the stored update is for another build and is ignored",
    bad = "the stored update is marked bad and is ignored",
    malformed = "the stored update is damaged and is ignored",
    rejected = "the stored update was rejected",
    applied = "running an in-game update",
    safemode = "SAFE MODE: an in-game update failed to load",
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
    if sub == "off" then
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
            Output("nothing is stored. Publish first (/cdl publish).")
        else
            db.tryOnce = true
            Output("the stored update will run once on the next reload, whatever build it was made for.")
        end
    else
        for _, line in ipairs(Boot.StatusLines()) do Output(line) end
        Output("|cffffd100/cdlpatch off|r, |cffffd100on|r, |cffffd100rollback|r, |cffffd100retry|r")
    end
end

SLASH_CDLOOTPATCH1 = "/cdlpatch"
if SlashCmdList then
    SlashCmdList["CDLOOTPATCH"] = HandleSlash
end
