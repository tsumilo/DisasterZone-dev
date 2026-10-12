if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Notify.lua", ...) then return end -- DisasterZone Core/Notify.lua
-- ns.Notify: the notification center. Every section tells it what waits for the player or what happened; it keeps
-- one feed per character and the counts, and the surfaces (UI/Notify.lua: the bell and its tray, the Notifications
-- page, the pop-ups, the counts on the nav strip and the minimap; Home's chips) read only from it.
--
-- A section registers a kind once:
--   Notify:RegisterKind("raidAnswer", { section = "Raids", page = "raids", icon = 45, label = "Raid answers",
--       desc = "Raids you're invited to and haven't answered", needsYou = true, popup = true, sound = true,
--       chat = false, home = true, open = function(item) ... end, actions = function(item) return { ... } end,
--       chip = function(item) return { text, kind, icon } end,
--       chipGroup = function(items) return { text, title } end, openGroup = function(items) ... end })
-- (Home folds several items of one kind into one chip: chipGroup words it, openGroup or the kind's page opens them.)
-- and either lists what is there now (a source: the feed follows it, items gone from it leave by themselves)
--   Notify:RegisterSource("raidAnswer", function() return { { key, title, text, from, time, expires, short, data } }
--       end, { "RAIDPLAN_CHANGED" })   -- messages that make it look again (also every 30 s and at login)
-- or posts one-off happenings (kept 7 days) and resolves them:
--   Notify:Post("lootWon", { key = entryId, title = ..., text = ..., from = ... });  Notify:Resolve(kind, key)
--
-- needsYou items (answer, approve, vote) make the gold count and stay until handled; the others are news to read
-- (a grey dot until the bell is opened). A new item fires NOTIFY_NEW (id) once per character (remembered across
-- reloads) unless it is older than the kind's first look on this character, so installing or a first sync never
-- floods. Kinds are named without dots (they are settings paths: settings.notify.kinds.<kind>.popup).
local addonName, ns = ...

local Notify = ns:NewModule("Notify")

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local tsort, floor = table.sort, math.floor

local DAY = 86400
Notify.KEEP_INFO = 7 * DAY        -- news and handled items stay in the feed this long
Notify.KEEP_MEMORY = 30 * DAY     -- seen / shown marks of items that are gone
Notify.TICK = 30                  -- seconds between the sources' regular look

local kinds, kindOrder = {}, {}   -- [kind] = def; kinds in registration order
local sources = {}                -- [kind] = fn
local live = {}                   -- [id] = item (from sources and posts, not done)
local loaded = false
local Revive               -- (below: saved posts back in the feed)
local dirtyKinds, refreshQueued = {}, false

local Now = ns.Util.Now
local function Me() return ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey() end
local function IdOf(kind, key) return kind .. "\1" .. tostring(key) end

-- This character's saved part: { seen = {[id]=t}, shown = {[id]=t}, items = {[id]=posted / done item},
-- base = {[kind]=t (first look)} }.
-- Demo mode (the fake guild): the feed lives in memory only, so no demo names or ids reach SavedVariables; switching
-- demo on or off starts the feed afresh (DEMO_TOGGLED below).
local demoStore
local IsDemo = ns.Util.DemoOn

local function Store()
    local db, me = ns.db, Me()
    if not (db and me) then return nil end
    if IsDemo() then
        demoStore = demoStore or { seen = {}, shown = {}, items = {}, base = {} }
        return demoStore
    end
    db.notify = type(db.notify) == "table" and db.notify or {}
    local s = db.notify[me]
    if type(s) ~= "table" then
        s = {}
        db.notify[me] = s
    end
    for _, f in ipairs({ "seen", "shown", "items", "base" }) do
        if type(s[f]) ~= "table" then s[f] = {} end
    end
    return s
end

-- settings.notify: { kinds = { [kind] = { popup, sound, chat } }, quietCombat (nil = on), quietOpen, dndUntil }.
-- Reading never writes (an untouched profile saves nothing); write = true makes the table to change it.
local EMPTY = { kinds = {} }
local function Settings(write)
    local st = ns.db and ns.db.settings
    if not st then return nil end
    if type(st.notify) ~= "table" then
        if not write then return EMPTY end
        st.notify = {}
    end
    if type(st.notify.kinds) ~= "table" then
        if not write then return { kinds = {}, quietCombat = st.notify.quietCombat, quietOpen = st.notify.quietOpen,
                                   dndUntil = st.notify.dndUntil } end
        st.notify.kinds = {}
    end
    return st.notify
end
Notify.Settings = Settings

local changeQueued = false
local function Changed()
    if changeQueued then return end
    changeQueued = true
    C_Timer.After(0, function()
        changeQueued = false
        ns:Fire("NOTIFY_CHANGED")
    end)
end

---------------------------------------------------------------------------
-- Kinds
---------------------------------------------------------------------------

function Notify:RegisterKind(kind, def)
    if type(kind) ~= "string" or kind:find("[%.%s]") or type(def) ~= "table" then
        error("Notify:RegisterKind(kind, def): a kind without dots or spaces and a table", 2)
    end
    if not kinds[kind] then kindOrder[#kindOrder + 1] = kind end
    def.kind = kind
    def.section = def.section or "DisasterZone"
    def.label = def.label or kind
    kinds[kind] = def
    if loaded then Revive(kind) end
    Changed()
end

function Notify:GetKind(kind) return kinds[kind] end

-- Every kind in registration order (Settings > Notifications).
function Notify:GetKinds()
    local out = {}
    for _, k in ipairs(kindOrder) do out[#out + 1] = kinds[k] end
    return out
end

-- The player's choice for a kind's way to reach them: what = "popup" | "sound" | "chat" (the bell always shows it).
function Notify:Wants(kind, what)
    local def = kinds[kind]
    if not def then return false end
    local n = Settings()
    local mine = n and n.kinds[kind]
    if type(mine) == "table" and mine[what] ~= nil then return mine[what] and true or false end
    return def[what] and true or false
end

function Notify:SetWants(kind, what, on)
    local n = Settings(true)
    if not (n and kinds[kind]) then return end
    n.kinds[kind] = type(n.kinds[kind]) == "table" and n.kinds[kind] or {}
    n.kinds[kind][what] = on and true or false
    ns:Fire("SETTINGS_CHANGED", "notify")
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------

-- A new item: seen / shown marks from earlier, older than the kind's first look = nothing new about it.
local function Arrive(it, quiet)
    local s = Store()
    local def = kinds[it.kind]
    if not (s and def) then return end
    local base = s.base[it.kind]
    if quiet or (base and it.time and it.time < base) then
        s.seen[it.id] = s.seen[it.id] or Now()
        s.shown[it.id] = s.shown[it.id] or Now()
    end
    if not s.seen[it.id] or it.renotify then
        if it.renotify then
            s.seen[it.id], s.shown[it.id] = nil, nil
        end
        C_Timer.After(0, function() ns:Fire("NOTIFY_NEW", it.id) end)
    end
end

local function Normalize(kind, src)
    local def = kinds[kind]
    local it = {
        id = IdOf(kind, src.key), kind = kind, key = src.key, title = src.title or def.label, text = src.text,
        from = src.from, time = tonumber(src.time) or Now(), expires = tonumber(src.expires), data = src.data,
        short = src.short, n = tonumber(src.n), renotify = src.renotify,
    }
    if src.needsYou ~= nil then it.needsYou = src.needsYou and true or false else it.needsYou = def.needsYou and true or false end
    return it
end

-- An item handled or gone: needs-you items go to the handled list (the Notifications page, 7 days).
local function Retire(it, how)
    live[it.id] = nil
    local s = Store()
    if not s then return end
    if it.needsYou then
        s.items[it.id] = { kind = it.kind, key = it.key, title = it.title, text = it.text, from = it.from, time = it.time,
            done = Now(), how = how }
    else
        s.items[it.id] = nil
    end
end

-- One kind's source looked at again.
local function RefreshKind(kind)
    local fn, def = sources[kind], kinds[kind]
    if not (fn and def and Store()) then return end
    local ok, list = pcall(fn)
    if not ok then
        ns:Debug("Notify source %s failed: %s", kind, tostring(list))
        return
    end
    local now, have, changed = Now(), {}, false
    -- the kind's first look on this character: what is there already is not news
    local s0 = Store()
    local first = not s0.base[kind]
    if first then s0.base[kind] = now end
    for _, src in ipairs(type(list) == "table" and list or {}) do
        if src.key ~= nil and not (src.expires and src.expires <= now) then
            local it = Normalize(kind, src)
            have[it.id] = true
            local old = live[it.id]
            if old then
                -- (fields follow the source; a growing stack is news again; no time of its own keeps the first)
                if src.time == nil then it.time = old.time end
                local grew = it.n and old.n and it.n > old.n
                for k, v in pairs(it) do old[k] = v end
                if grew then
                    old.renotify = true
                    Arrive(old)
                    old.renotify = nil
                    changed = true
                end
            else
                live[it.id] = it
                local s = Store()
                if s.items[it.id] and s.items[it.id].done then s.items[it.id] = nil end   -- (back again)
                Arrive(it, first)
                changed = true
            end
        end
    end
    for id, it in pairs(live) do
        if it.kind == kind and not have[id] and not it.posted then
            Retire(it, "gone")
            changed = true
        end
    end
    if changed then Changed() end
end

local function RefreshDirty()
    refreshQueued = false
    for kind in pairs(dirtyKinds) do
        dirtyKinds[kind] = nil
        RefreshKind(kind)
    end
end

-- Looks at a kind's source again (all of them without a kind), batched to the next frame.
function Notify:Refresh(kind)
    if not loaded then return end
    if kind then
        dirtyKinds[kind] = true
    else
        for k in pairs(sources) do dirtyKinds[k] = true end
    end
    if not refreshQueued then
        refreshQueued = true
        C_Timer.After(0, RefreshDirty)
    end
end

-- fn() returns what is there now; messages (optional) are ns messages that make the kind look again.
function Notify:RegisterSource(kind, fn, messages)
    if type(fn) ~= "function" then error("Notify:RegisterSource(kind, fn, messages)", 2) end
    sources[kind] = fn
    for _, msg in ipairs(type(messages) == "table" and messages or {}) do
        ns:On(msg, function() Notify:Refresh(kind) end)
    end
    self:Refresh(kind)
end

-- A one-off happening (or something that waits for the player until Resolve). src as a source's item; it stays
-- until resolved, until src.expires, or KEEP_INFO after its time when it is news. Posting the same key again
-- updates it (src.renotify = true: news again, a pop-up again).
function Notify:Post(kind, src)
    if not (kinds[kind] and type(src) == "table" and src.key ~= nil) then return nil end
    local s = Store()
    if not s then return nil end
    local it = Normalize(kind, src)
    it.posted = true
    if not s.base[kind] then s.base[kind] = it.time end   -- (a post is news: it happened now)
    local old = live[it.id]
    live[it.id] = it
    s.items[it.id] = { kind = kind, key = it.key, title = it.title, text = it.text, from = it.from, time = it.time,
        expires = it.expires, data = it.data, short = it.short, n = it.n, needsYou = it.needsYou, posted = true }
    if not old or it.renotify then Arrive(it, src.quiet) end
    it.renotify = nil
    Changed()
    return it.id
end

-- Handled (here, on the page, on another alt): it leaves the counts.
function Notify:Resolve(kind, key)
    local it = live[IdOf(kind, key)]
    if it then
        Retire(it, "handled")
        Changed()
    end
end

-- News again (a reminder: the asker nudged): unseen, and its pop-up shows again.
function Notify:Renotify(kind, key)
    local it = live[IdOf(kind, key)]
    if not it then return end
    it.renotify = true
    Arrive(it)
    it.renotify = nil
    Changed()
end

-- The player read it / acted on it.
function Notify:MarkSeen(id)
    local s = Store()
    if s and live[id] and not s.seen[id] then
        s.seen[id] = Now()
        Changed()
    end
end

function Notify:MarkAllSeen(filter)
    local s = Store()
    if not s then return end
    local any = false
    for id, it in pairs(live) do
        if not s.seen[id] and self:Matches(it, filter) then
            s.seen[id] = Now()
            any = true
        end
    end
    if any then Changed() end
end

-- The pop-up for it was shown (or skipped for good): no pop-up again for it.
function Notify:MarkShown(id)
    local s = Store()
    if s then s.shown[id] = Now() end
end

function Notify:WasShown(id)
    local s = Store()
    return s and s.shown[id] ~= nil or false
end

function Notify:IsSeen(id)
    local s = Store()
    return s and s.seen[id] ~= nil or false
end

function Notify:Get(id) return live[id] end

-- filter: { needsYou = true|false, section = "Raids", page = "raids", kind = "x", unseen = true, home = true }
function Notify:Matches(it, filter)
    if not filter then return true end
    local def = kinds[it.kind]
    if not def then return false end
    if filter.needsYou ~= nil and (it.needsYou and true or false) ~= filter.needsYou then return false end
    if filter.kind and it.kind ~= filter.kind then return false end
    if filter.section and def.section ~= filter.section then return false end
    if filter.page and def.page ~= filter.page then return false end
    if filter.home and not def.home then return false end
    if filter.unseen and self:IsSeen(it.id) then return false end
    return true
end

-- The live feed (needs you first, then the newest first), filtered.
function Notify:List(filter)
    local out, now = {}, Now()
    for _, it in pairs(live) do
        if not (it.expires and it.expires <= now) and self:Matches(it, filter) then out[#out + 1] = it end
    end
    tsort(out, function(a, b)
        if (a.needsYou and 1 or 0) ~= (b.needsYou and 1 or 0) then return a.needsYou and true or false end
        if a.time ~= b.time then return a.time > b.time end
        return a.id < b.id
    end)
    return out
end

-- Items handled or gone in the last KEEP_INFO (the Notifications page's "Handled").
function Notify:ListDone(filter)
    local s, out = Store(), {}
    if not s then return out end
    for id, d in pairs(s.items) do
        if d.done and kinds[d.kind] then
            local it = { id = id, kind = d.kind, key = d.key, title = d.title, text = d.text, from = d.from, time = d.time,
                done = d.done, how = d.how, needsYou = true }
            if self:Matches(it, filter) then out[#out + 1] = it end
        end
    end
    tsort(out, function(a, b) return (a.done or 0) > (b.done or 0) end)
    return out
end

function Notify:Count(filter)
    local f = {}
    for k, v in pairs(filter or {}) do f[k] = v end
    if f.needsYou == nil then f.needsYou = true end
    return #self:List(f)
end

-- News not read yet (the bell's grey dot).
function Notify:UnseenCount(filter)
    local f = { needsYou = false, unseen = true }
    for k, v in pairs(filter or {}) do f[k] = v end
    return #self:List(f)
end

-- Clicking an item: its kind's open, and it is seen.
function Notify:Open(id)
    local it = live[id]
    local def = it and kinds[it.kind]
    if not def then return end
    self:MarkSeen(id)
    self:MarkShown(id)
    if def.open then
        local ok, err = pcall(def.open, it)
        if not ok then ns:Debug("Notify open %s failed: %s", it.kind, tostring(err)) end
    end
end

-- The buttons for an item: { { text, primary, fn } } (at most two are shown).
function Notify:GetActions(id)
    local it = live[id]
    local def = it and kinds[it.kind]
    if not (def and def.actions) then return {} end
    local ok, list = pcall(def.actions, it)
    return ok and type(list) == "table" and list or {}
end

function Notify:RunAction(id, index)
    local it = live[id]
    local a = self:GetActions(id)[index]
    if not (it and a and a.fn) then return end
    self:MarkSeen(id)
    self:MarkShown(id)
    local ok, err = pcall(a.fn, it)
    if not ok then ns:Debug("Notify action %s failed: %s", it.kind, tostring(err)) end
    self:Refresh(it.kind)
end

-- How long ago, short ("now", "4m", "2h", "yesterday", "3d").
function Notify:Ago(t)
    local d = Now() - (tonumber(t) or Now())
    if d < 60 then return "now" end
    if d < 3600 then return floor(d / 60) .. "m" end
    if d < DAY then return floor(d / 3600) .. "h" end
    if d < 2 * DAY then return "yesterday" end
    return floor(d / DAY) .. "d"
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- A kind's saved posts back in the feed (after a reload; a kind registered after login gets them then).
function Revive(kind)
    local s = Store()
    if not s then return end
    for id, d in pairs(s.items) do
        if d.posted and not d.done and (not kind or d.kind == kind) and kinds[d.kind] and not live[id] then
            live[id] = { id = id, kind = d.kind, key = d.key, title = d.title, text = d.text, from = d.from,
                time = d.time, expires = d.expires, data = d.data, short = d.short, n = d.n,
                needsYou = d.needsYou, posted = true }
        end
    end
end

-- Posted items come back after a reload; old memory is dropped.
local function Load()
    local s = Store()
    if not s then return false end
    local now = Now()
    for id, d in pairs(s.items) do
        local keep
        if d.done then
            keep = now - d.done < Notify.KEEP_INFO
        elseif d.posted then
            keep = not (d.expires and d.expires <= now) and (d.needsYou or now - (d.time or 0) < Notify.KEEP_INFO)
        end
        if not keep then s.items[id] = nil end
    end
    Revive()
    for _, f in ipairs({ "seen", "shown" }) do
        for id, t in pairs(s[f]) do
            if not live[id] and not s.items[id] and now - (tonumber(t) or 0) > Notify.KEEP_MEMORY then s[f][id] = nil end
        end
    end
    return true
end

local ticker
function Notify:OnLogin()
    local function start()
        if loaded then return end
        if not Load() then
            C_Timer.After(1, start)
            return
        end
        loaded = true
        self:Refresh()
        Changed()
        if not ticker and C_Timer.NewTicker then
            ticker = C_Timer.NewTicker(self.TICK, function()
                -- (expired posts leave; time-bound sources move on)
                local now = Now()
                for id, it in pairs(live) do
                    if it.expires and it.expires <= now then
                        Retire(it, "expired")
                        Changed()
                    elseif it.posted and not it.needsYou and now - (it.time or 0) >= Notify.KEEP_INFO then
                        live[id] = nil
                        Changed()
                    end
                end
                Notify:Refresh()
            end)
        end
    end
    start()
end

function Notify:IsLoaded() return loaded end

ns:On("DEMO_TOGGLED", function()
    demoStore = nil
    wipe(live)
    if not loaded then return end
    Revive()
    Notify:Refresh()
    Changed()
end)

-- (tests) forget everything in memory and load again
function Notify:Reload()
    wipe(live)
    loaded = false
    self:OnLogin()
end
