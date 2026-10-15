if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Profiles.lua", ...) then return end -- DisasterZone Core/Profiles.lua
-- UI profiles (ns.Profiles), built 2026-10-15 from the approved mockup (claude.ai/artifact/WpLrGBdDo6LW2GA3RqwCz3,
-- direction A "Profile cards"): Layout's profiles (Core/Layout.lua) grew into the whole UI, one list. A profile holds
-- three parts, each switched on or off per profile:
--   looks   every look and theme (the settings under ui.*, the meters' / class bars' / swing and shot timers' themes)
--   layout  where every frame goes (Layout's own frames / mirror / meters: unchanged)
--   keys    the keys on every button Key binds shows (the action bars, stance, pet, the addon's buttons)
-- Profile fields added: parts = { looks, layout, keys } (nil: an old layout-only profile = { layout = true }), looks
-- = { [setting path] = value }, keys = { [binding command] = { key, ... } }. A part switched off is left as it is when
-- the profile comes on.
-- In use: ns.db.layouts.uses[character] = the profile this character uses; chars[character] stays the profile its
-- frames' places come from (Layout:ActiveId): the one in use when it holds a layout, else the last one that did.
-- Changes save into the profile in use by themselves (the user's pick): a look picked, a key bound (Key binds, or the
-- game's own key bindings: UPDATE_BINDINGS), a frame moved (Layout, as before).
-- Characters: every character of the account that logs in with the addon is noted (ns.db.layouts.seen[character] =
-- { c = class file }); a profile can be given to any of them from its card (the user, 2026-10-15: "different between
-- our main and alts"). Each character puts its own profile on at login (looks are the account's settings, so an alt
-- would otherwise wear the main's).
-- Specs: ns.db.layouts.specs[character] = { [spec label] = profile id }; a respec to a spec with a profile switches to
-- it (a spec without one keeps what you have). Looks that replace whole frames need a reload: a toast asks (Reload
-- now / Later). In a fight the switch waits for its end (keys and frames can't change in combat).
-- Sharing (Layout:Export / Import) sends the whole profile; the receiver gets it with its parts as they were and picks
-- which to use on its card before Use now.
-- Demo mode: the Profiles page shows made-up profiles kept in memory; Use now only shows the toast.
local addonName, ns = ...

local Profiles = ns:NewModule("Profiles")

local pairs, ipairs, type, tostring, next = pairs, ipairs, type, tostring, next
local tsort = table.sort

Profiles.PARTS = { "looks", "layout", "keys" }
-- the themed parts outside ui.* (Look.THEMED's settings)
local THEMED = { "meters.theme", "classbar.theme", "swing.theme", "shot.theme" }

local applying = false     -- (our own changes don't save back while a profile is put on)
local pending              -- a switch waiting for the fight's end: { id, spec }
local lastSpec

local function L() return ns.Layout end
local function Store() return ns.Layout and ns.Layout.Store() end
local function Me() return ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey() or nil end
local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end
local function Copy(t) return ns.Layout.Copy(t) end
local function Demo() return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() and true or false end
local function MyClass() return UnitClass and select(2, UnitClass("player")) or nil end

---------------------------------------------------------------------------
-- Parts
---------------------------------------------------------------------------

-- A profile's parts: { looks, layout, keys } (an old layout-only profile: layout).
function Profiles.Parts(p)
    if type(p) ~= "table" then return { layout = true } end
    if type(p.parts) ~= "table" then return { layout = true } end
    return p.parts
end

function Profiles:Has(p, part) return self.Parts(p)[part] and true or false end

---------------------------------------------------------------------------
-- Looks: a snapshot of the look settings
---------------------------------------------------------------------------

local function Flatten(node, prefix, out)
    for k, v in pairs(node) do
        if type(k) == "string" then
            local path = prefix .. "." .. k
            if type(v) == "table" then Flatten(v, path, out) else out[path] = v end
        end
    end
end

function Profiles:ReadLooks()
    local out = {}
    local DB = ns.DB
    if not DB then return out end
    local ui = DB:GetSetting("ui")
    if type(ui) == "table" then Flatten(ui, "ui", out) end
    for _, path in ipairs(THEMED) do
        local v = DB:GetSetting(path)
        if v ~= nil and type(v) ~= "table" then out[path] = v end
    end
    return out
end

-- Puts a looks snapshot on: every look setting it has, and the ones it hasn't back to their defaults. Returns the
-- parts' names that wait for a reload.
function Profiles:ApplyLooks(snap)
    local DB = ns.DB
    if not DB or type(snap) ~= "table" then return {} end
    local now = self:ReadLooks()
    local Look = ns.Look
    if Look then Look.quietReload = true end
    for path in pairs(now) do
        if snap[path] == nil then DB:SetSetting(path, nil) end
    end
    for path, v in pairs(snap) do
        if now[path] ~= v then DB:SetSetting(path, v) end
    end
    if Look then Look.quietReload = nil end
    local reload = {}
    if Look and Look.PARTS then
        for _, part in ipairs(Look.PARTS) do
            if Look:NeedsReload(part.key) then reload[#reload + 1] = part.name end
        end
    end
    return reload
end

-- How a profile's looks read: "Halo · Unit frames Flat" (the look on everything, then the parts that differ).
function Profiles:LooksText(p)
    local Look = ns.Look
    local snap = type(p) == "table" and p.looks
    if not (Look and type(snap) == "table") then return "Saved when it is in use" end
    local by = Look.BY_KEY or {}
    local all = snap["ui.look"] or "blizzard"
    local function name(k) return by[k] and by[k].name or tostring(k) end
    local out = { name(all) }
    for _, part in ipairs(Look.PARTS or {}) do
        local own = snap["ui." .. part.key .. ".look"]
        if own and own ~= "inherit" and own ~= all and #out < 3 then out[#out + 1] = part.name .. " " .. name(own) end
    end
    return table.concat(out, " \194\183 ")
end

function Profiles:LooksKey(p)
    local snap = type(p) == "table" and p.looks
    return type(snap) == "table" and snap["ui.look"] or "blizzard"
end

---------------------------------------------------------------------------
-- Keys: a snapshot of the keys on every button Key binds shows
---------------------------------------------------------------------------

local function Commands() return ns.KeyBinds and ns.KeyBinds.Commands and ns.KeyBinds:Commands() or {} end

function Profiles:ReadKeys()
    local out = {}
    if not GetBindingKey then return out end
    for _, cmd in ipairs(Commands()) do
        local keys = { GetBindingKey(cmd) }
        if #keys > 0 then out[cmd] = keys end
    end
    return out
end

function Profiles:CountKeys(snap)
    local n = 0
    for _, keys in pairs(type(snap) == "table" and snap or {}) do n = n + #keys end
    return n
end

-- Puts a keys snapshot on: every managed button's keys off, then the snapshot's on; saved in the binding set in use.
function Profiles:ApplyKeys(snap)
    if type(snap) ~= "table" or InCombat() or not SetBinding then return false end
    for _, cmd in ipairs(Commands()) do
        for _, k in ipairs({ GetBindingKey(cmd) }) do SetBinding(k) end
    end
    for cmd, keys in pairs(snap) do
        for _, k in ipairs(keys) do SetBinding(k, cmd) end
    end
    if SaveBindings then pcall(SaveBindings, GetCurrentBindingSet and GetCurrentBindingSet() or 1) end
    return true
end

---------------------------------------------------------------------------
-- In use
---------------------------------------------------------------------------

function Profiles:InUseId()
    local S = Store()
    if not S then return "default" end
    if type(S.uses) ~= "table" then S.uses = {} end
    local me = Me()
    local id = me and S.uses[me]
    if id and S.profiles[id] then return id end
    return L():ActiveId()
end

function Profiles:InUse() return L():Profile(self:InUseId()) end

-- Saves what is on the screen into the profile in use (the parts it holds): its looks and its keys.
function Profiles:Capture(part)
    if applying or Demo() then return end
    local p = self:InUse()
    if not p then return end
    if (part == nil or part == "looks") and self:Has(p, "looks") then p.looks = self:ReadLooks() end
    if (part == nil or part == "keys") and self:Has(p, "keys") and not InCombat() then p.keys = self:ReadKeys() end
end

-- This character uses profile id: the parts it holds come on (the ones it doesn't stay as they are). spec: the spec
-- that asked for it (the toast says so). In a fight it waits for the end. Returns true when it switched (or will).
function Profiles:Use(id, spec)
    local p = L():Profile(id)
    local me = Me()
    if not p or not me then return false end
    if InCombat() then
        pending = { id = id, spec = spec }
        return true
    end
    local S = Store()
    -- what the profile in use holds now is kept first
    self:Capture()
    applying = true
    local parts = self.Parts(p)
    -- (a part never saved yet starts from what is on now)
    if parts.looks and type(p.looks) ~= "table" then p.looks = self:ReadLooks() end
    if parts.keys and type(p.keys) ~= "table" then p.keys = self:ReadKeys() end
    S.uses = type(S.uses) == "table" and S.uses or {}
    S.uses[me] = id ~= "default" and id or nil
    if parts.layout and L():ActiveId() ~= id then
        L():UseLayout(id)
    end
    local reload = {}
    if parts.looks then reload = self:ApplyLooks(p.looks) end
    if parts.keys then self:ApplyKeys(p.keys) end
    applying = false
    ns:Fire("PROFILE_CHANGED", id)
    self:Toast(p, spec, reload)
    return true
end

-- The toast after a switch: what came on; looks that wait for a reload ask for it.
function Profiles:Toast(p, spec, reload, demo)
    local UI = ns.UI
    if not (UI and UI.Toast) then return end
    local parts = self.Parts(p)
    local on = {}
    if parts.looks then on[#on + 1] = "looks" end
    if parts.layout then on[#on + 1] = "layout" end
    if parts.keys then on[#on + 1] = "key binds" end
    local text = #on > 0 and ("Switched: " .. table.concat(on, ", ") .. ".") or "It holds nothing to switch."
    local icon = spec and ns.SpecIcon and ns.SpecIcon(MyClass(), spec) or nil
    local o = { key = "profile", kicker = spec and ("Spec changed: " .. spec) or "Profile", title = p.name or "Profile",
                icon = icon, text = text, duration = 6 }
    if reload and #reload > 0 then
        o.text = text .. " " .. table.concat(reload, ", ") .. " switch between the game's frames and ours after a reload."
        o.duration = 30
        o.buttons = {
            { text = "Reload now", kind = "primary", onClick = function() if not demo and ReloadUI then ReloadUI() end end },
            { text = "Later" },
        }
    end
    if demo then o.kicker = "Demo: " .. o.kicker end
    UI:Toast(o)
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

-- { profile, ... } Default first, then by name.
function Profiles:List()
    if self.demo then return self.demo end
    local out = {}
    for _, e in ipairs(L():Profiles()) do
        local p = L():Profile(e.id)
        if p then out[#out + 1] = p end
    end
    return out
end

function Profiles:Get(id)
    if self.demo then
        for _, p in ipairs(self.demo) do if p.id == id then return p end end
        return nil
    end
    return L():Profile(id)
end

function Profiles:CurrentId()
    if self.demo then return self.demoUsing end
    return self:InUseId()
end

-- A new profile (every part on), a copy of the one in use as it is now. Returns its id.
function Profiles:New(name)
    if self.demo then
        local id = "demo" .. (#self.demo + 1)
        self.demo[#self.demo + 1] = { id = id, name = name or "New profile", parts = { looks = true, layout = true, keys = true },
            looks = { ["ui.look"] = "flat" }, keys = {}, frames = {} }
        return id
    end
    self:Capture()
    return L():NewProfile(name)
end

-- A copy of any profile, parts and all. Returns its id.
function Profiles:Copy(id)
    local src = self:Get(id)
    if not src then return nil end
    if self.demo then
        local c = Copy(src)
        c.id = "demo" .. (#self.demo + 1)
        c.name = src.name .. " copy"
        self.demo[#self.demo + 1] = c
        return c.id
    end
    if id == self:InUseId() then self:Capture() end
    return L():NewProfile((src.name or "Profile") .. " copy", id)
end

function Profiles:Delete(id)
    if self.demo then
        for i, p in ipairs(self.demo) do if p.id == id and id ~= "default" then table.remove(self.demo, i) return true end end
        return false
    end
    local S = Store()
    local ok = L():Delete(id)
    if ok and S then
        for who, pid in pairs(S.uses or {}) do if pid == id then S.uses[who] = nil end end
        for _, map in pairs(S.specs or {}) do
            for spec, pid in pairs(map) do if pid == id then map[spec] = nil end end
        end
    end
    return ok
end

-- A part on or off. Turning one on in the profile in use saves what is on now into it.
function Profiles:SetPart(id, part, on)
    local p = self:Get(id)
    if not p then return end
    p.parts = Copy(self.Parts(p))
    p.parts[part] = on and true or nil
    if on and not self.demo and id == self:InUseId() then
        if part == "looks" then p.looks = self:ReadLooks() end
        if part == "keys" then p.keys = self:ReadKeys() end
        if part == "layout" and L():ActiveId() ~= id then L():UseLayout(id) end
    end
    ns:Fire("PROFILE_CHANGED", id)
end

---------------------------------------------------------------------------
-- Characters
---------------------------------------------------------------------------

-- My characters: { { key, class }, ... } me first, then by name (the ones seen with the addon, and my guild alts).
function Profiles:MyCharacters()
    if self.demo then return self.demoChars or {} end
    local S = Store()
    local me = Me()
    local seen = {}
    local out = {}
    local function add(key, class)
        if key and not seen[key] then
            seen[key] = true
            out[#out + 1] = { key = key, class = class }
        end
    end
    add(me, MyClass())
    local rest = {}
    for key, e in pairs(S and type(S.seen) == "table" and S.seen or {}) do
        if key ~= me then rest[#rest + 1] = { key = key, class = type(e) == "table" and e.c or nil } end
    end
    local guildAlts = ns.Guild and ns.Guild.GetMyCharacters and ns.Guild:GetMyCharacters() or {}
    for _, key in ipairs(guildAlts) do
        local known = false
        for _, e in ipairs(rest) do if e.key == key then known = true end end
        if not known and key ~= me then rest[#rest + 1] = { key = key } end
    end
    tsort(rest, function(a, b) return tostring(a.key) < tostring(b.key) end)
    -- (a guild alt that hasn't logged in with the addon yet: its class from the guild roster)
    for _, e in ipairs(rest) do add(e.key, e.class or (ns.UI and ns.UI.ClassOf and ns.UI:ClassOf(e.key)) or nil) end
    return out
end

-- The profile a character uses (its own pick, else its layout's, else Default).
function Profiles:ProfileOfChar(key)
    if self.demo then return self.demoCharUse and self.demoCharUse[key] or "default" end
    local S = Store()
    if not S then return "default" end
    if key == Me() then return self:InUseId() end
    local id = type(S.uses) == "table" and S.uses[key] or nil
    if id and S.profiles[id] then return id end
    id = type(S.chars) == "table" and S.chars[key] or nil
    if id and S.profiles[id] then return id end
    return "default"
end

-- The characters that use a profile.
function Profiles:CharsOf(id)
    local out = {}
    for _, c in ipairs(self:MyCharacters()) do
        if self:ProfileOfChar(c.key) == id then out[#out + 1] = c end
    end
    return out
end

-- Gives a character a profile (nil: back to Default). Me: it comes on now; another: at its next login.
function Profiles:SetCharacter(key, id)
    id = id or "default"
    if self.demo then
        self.demoCharUse = self.demoCharUse or {}
        self.demoCharUse[key] = id
        if key == Me() then self.demoUsing = id end
        ns:Fire("PROFILE_CHANGED", id)
        return
    end
    if key == Me() then self:Use(id) return end
    local S = Store()
    local p = L():Profile(id)
    if not S or not p then return end
    S.uses = type(S.uses) == "table" and S.uses or {}
    S.uses[key] = id ~= "default" and id or nil
    if self:Has(p, "layout") then S.chars[key] = id ~= "default" and id or nil end
    ns:Fire("PROFILE_CHANGED", id)
end

-- At login: my profile's looks and keys on, before the looks' parts build their frames (no reload needed then).
function Profiles:PutOnAtLogin()
    if Demo() or InCombat() then return end
    local p = self:InUse()
    if not p then return end
    applying = true
    if self:Has(p, "looks") and type(p.looks) == "table" then
        local now = self:ReadLooks()
        local same = true
        for k, v in pairs(p.looks) do if now[k] ~= v then same = false end end
        for k in pairs(now) do if p.looks[k] == nil then same = false end end
        if not same then self:ApplyLooks(p.looks) end
    end
    if self:Has(p, "keys") and type(p.keys) == "table" then
        local now = self:ReadKeys()
        local same = true
        for cmd, keys in pairs(p.keys) do if table.concat(now[cmd] or {}, ",") ~= table.concat(keys, ",") then same = false end end
        for cmd in pairs(now) do if not p.keys[cmd] then same = false end end
        if not same then self:ApplyKeys(p.keys) end
    end
    applying = false
end

---------------------------------------------------------------------------
-- Specs
---------------------------------------------------------------------------

local function SpecMap(make)
    if Profiles.demo then
        Profiles.demoSpecs = Profiles.demoSpecs or {}
        return Profiles.demoSpecs
    end
    local S = Store()
    local me = Me()
    if not S or not me then return {} end
    if type(S.specs) ~= "table" then S.specs = {} end
    if make and type(S.specs[me]) ~= "table" then S.specs[me] = {} end
    return S.specs[me] or {}
end

-- My class's specs: { { label, icon }, ... }.
function Profiles:MySpecs()
    local class = MyClass()
    local out = {}
    for _, s in ipairs(ns.SPECS and class and ns.SPECS[class] or {}) do
        out[#out + 1] = { label = s.label, icon = s.icon }
    end
    return out
end

function Profiles:ProfileOfSpec(spec) return SpecMap()[spec] end

-- The specs that use a profile, in the class's order.
function Profiles:SpecsOf(id)
    local map, out = SpecMap(), {}
    for _, s in ipairs(self:MySpecs()) do if map[s.label] == id then out[#out + 1] = s end end
    return out
end

-- Gives a spec to a profile (a spec has one profile: it leaves the one it had); id nil: none.
function Profiles:SetSpec(spec, id)
    local map = SpecMap(true)
    map[spec] = id
    ns:Fire("PROFILE_CHANGED", id)
end

-- A respec (debounced, as Wardrobe's): the new spec's profile comes on.
function Profiles:CheckSpec()
    local spec = ns.BiS and ns.BiS.DetectSpec and ns.BiS:DetectSpec() or ""
    if spec == "" then return end
    local was = lastSpec
    lastSpec = spec
    if was == nil or was == spec or Demo() then return end
    local id = SpecMap()[spec]
    if id and L():Profile(id) and id ~= self:InUseId() then self:Use(id, spec) end
end

---------------------------------------------------------------------------
-- Demo: made-up profiles on the page, in memory only
---------------------------------------------------------------------------

function Profiles:SetDemo(on)
    if not on then self.demo, self.demoUsing, self.demoSpecs, self.demoChars, self.demoCharUse = nil, nil, nil, nil, nil return end
    local specs = self:MySpecs()
    self.demo = {
        { id = "default", name = "Default", parts = { looks = true, layout = true }, looks = { ["ui.look"] = "blizzard" },
          frames = {} },
        { id = "dhealer", name = "Raid healer", art = "SerpentshrineCavern", parts = { looks = true, layout = true, keys = true },
          looks = { ["ui.look"] = "halo", ["ui.group.look"] = "flat" }, keys = { a = { "1", "2", "3" } }, frames = { a = {}, b = {} } },
        { id = "dtank", name = "Tanking", art = "BlackTemple", parts = { layout = true, keys = true }, looks = { ["ui.look"] = "slate" },
          keys = { a = { "1" }, b = { "Q", "E" } }, frames = { a = {} } },
        { id = "dquest", name = "Questing", art = "HyjalSummit", parts = { looks = true, layout = true, keys = true },
          looks = { ["ui.look"] = "flat" }, keys = { a = { "1" } }, frames = {} },
    }
    self.demoUsing = "dhealer"
    local me = Me() or "Me"
    local realm = me:match("%-(.+)$") or "Realm"
    self.demoChars = { { key = me, class = MyClass() }, { key = "Shadowbank-" .. realm, class = "WARLOCK" },
                       { key = "Mendalot-" .. realm, class = "PRIEST" } }
    self.demoCharUse = { [me] = "dhealer", ["Mendalot-" .. realm] = "dhealer", ["Shadowbank-" .. realm] = "dquest" }
    self.demoSpecs = {}
    if specs[1] then self.demoSpecs[specs[1].label] = "dhealer" end
    if specs[2] then self.demoSpecs[specs[2].label] = "dtank" end
    if specs[3] then self.demoSpecs[specs[3].label] = "dquest" end
end

-- Use now in demo mode: the toast and the card, nothing put on.
function Profiles:UseDemo(id, spec)
    local p = self:Get(id)
    if not p then return end
    self.demoUsing = id
    if self.demoCharUse then self.demoCharUse[Me() or "Me"] = id end
    self:Toast(p, spec, self:Has(p, "looks") and { "Unit frames" } or nil, true)
    ns:Fire("PROFILE_CHANGED", id)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Profiles:OnLogin()
    local U = ns.Util
    -- (this character is noted, then its own profile goes on)
    local S, me = Store(), Me()
    if S and me then
        S.seen = type(S.seen) == "table" and S.seen or {}
        S.seen[me] = { c = MyClass() }
    end
    self:PutOnAtLogin()
    ns:On("SETTINGS_CHANGED", function(path)
        if applying or type(path) ~= "string" then return end
        local looks = path:sub(1, 3) == "ui." or path == "ui"
        for _, t in ipairs(THEMED) do if path == t then looks = true end end
        if looks then U.Debounce("profiles-looks", 0.5, function() Profiles:Capture("looks") end) end
    end)
    ns:RegisterEvent("UPDATE_BINDINGS", function()
        if applying then return end
        U.Debounce("profiles-keys", 0.5, function() Profiles:Capture("keys") end)
    end)
    ns:On("KEY_BINDS", function(open) if not open then Profiles:Capture("keys") end end)
    local function spec() U.Debounce("profiles-spec", 1, function() Profiles:CheckSpec() end) end
    ns:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", spec)   -- (skipped where the client has no dual spec)
    ns:RegisterEvent("PLAYER_TALENT_UPDATE", spec)
    ns:RegisterEvent("CHARACTER_POINTS_CHANGED", spec)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if pending then
            local p = pending
            pending = nil
            U.After(0.3, function() Profiles:Use(p.id, p.spec) end)
        end
    end)
    ns:On("DEMO_TOGGLED", function(on) Profiles:SetDemo(on) end)
    if Demo() then self:SetDemo(true) end
    -- (the spec at login: a later change is a respec)
    U.After(2, function() Profiles:CheckSpec() end)
end

-- For tests
function Profiles:Pending() return pending end
function Profiles:ResetSpec() lastSpec = nil end
