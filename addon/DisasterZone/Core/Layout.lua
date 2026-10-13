if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Layout.lua", ...) then return end -- DisasterZone Core/Layout.lua
-- Where every on-screen frame sits (ns.Layout): one store for the places that used to live in each feature (a
-- window key, swing.pos, the class bars' pos, meters.layout), the profiles that hold them, and the bridge to the
-- game's own Edit Mode for Blizzard's frames. UI/EditMode.lua is the overlay that moves them (/dz edit).
--
-- Items: a feature registers what it puts on the screen:
--   Layout:Register(id, def)  def = {
--     name, group ("Game frames" | "Raid" | "Loot" | "Class tools"), order (inside the group),
--     frame = function() -> frame (nil until it is built),
--     kind = "dz" (default) | "blizzard" (a frame of the game's Edit Mode: placed through C_EditMode) | "meters",
--     default = { point, x, y } (UIParent units; where it goes without a saved place) or a function returning one,
--     legacy = function() -> point, relPoint, x, y (its place from before the layouts, read until it is moved),
--     variant = function() -> string (one place per variant: a class bar's "vertical" / "horizontal"),
--     mine = function() -> bool (shown under "My character"; default true), when = "while loot is open" (the
--     label's note when it is usually hidden), preview = function(on) (show it with made-up content while editing),
--     scale = { get = fn, set = fn(s) } (a feature's own size setting; else the profile keeps a scale),
--     stretch = { x = { min, max }, y = { min, max }, apply = fn() } (a frame that lays itself out at any width /
--       height: Edit layout's side handles stretch it; the feature reads Layout:Size(id) in its own units, nil = its
--       natural size, and apply() lays it out again),
--     box = function() -> the frame to measure (when `frame` itself may be hidden, e.g. a unit watch's button),
--     protected (secure buttons inside: never moved in combat), noHide (no eye toggle) }
-- Blizzard frames scale through their own Edit Mode size setting (Frame Size, Icon Size, ...: Layout.BLIZZ_SIZE).
--
-- Places are kept in UIParent units from the nearest corner, side or centre of the screen (Layout.AnchorOf), so they
-- hold on another resolution or UI scale. A profile: { id, name, by, frames = { [key] = { p, x, y, s, w, h, hide } },
-- mirror = { [id] = partner id }, meters = (a copy of meters.layout) }. ns.db.layouts = { v, profiles = { [id] =
-- profile }, chars = { [character key] = profile id } }: profiles are the account's, each character uses its own.
-- Blizzard's frames are moved by writing the active Edit Mode layout (C_EditMode.SaveLayouts) and letting the game
-- apply it (its Edit Mode panel opened and closed), never by SetPoint from here: their SetPoint runs the Edit Mode
-- manager's code, and doing that from an addon taints it.
local addonName, ns = ...

local Layout = ns:NewModule("Layout")

local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local pairs, ipairs, type, tonumber, tostring, next = pairs, ipairs, type, tonumber, tostring, next
local tsort, tinsert = table.sort, table.insert

Layout.GROUPS = { "Game frames", "Raid", "Loot", "Class tools" }
local GROUP_ORDER = {}
for i, g in ipairs(Layout.GROUPS) do GROUP_ORDER[g] = i end

local items, list = {}, {}
Layout.items = items

local function Copy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = Copy(v) end
    return o
end
Layout.Copy = Copy

local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end
local function Me() return ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey() or nil end

---------------------------------------------------------------------------
-- Screen maths (UIParent units)
---------------------------------------------------------------------------

function Layout.Screen()
    local w, h = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
    if w <= 0 or h <= 0 then w, h = 1920, 1080 end
    return w, h
end

-- How many UIParent units one unit of f is (its scale chain against UIParent's).
function Layout.Ratio(f)
    local a, b = f and f.GetEffectiveScale and f:GetEffectiveScale() or 1, UIParent:GetEffectiveScale() or 1
    if not a or a <= 0 or not b or b <= 0 then return 1 end
    return a / b
end

-- The point of the screen a box belongs to (its centre in the left / middle / right third and the top / middle /
-- bottom third) and its offset from there: p, x, y with SetPoint(p, UIParent, p, x, y) putting it back.
function Layout.AnchorOf(l, b, w, h)
    local W, H = Layout.Screen()
    local cx, cy = l + w / 2, b + h / 2
    local hz = cx < W / 3 and "LEFT" or (cx > W * 2 / 3 and "RIGHT" or "")
    local vt = cy > H * 2 / 3 and "TOP" or (cy < H / 3 and "BOTTOM" or "")
    local x = hz == "LEFT" and l or (hz == "RIGHT" and (l + w - W) or (cx - W / 2))
    local y = vt == "BOTTOM" and b or (vt == "TOP" and (b + h - H) or (cy - H / 2))
    local p = vt .. hz
    if p == "" then p = "CENTER" end
    return p, floor(x * 10 + 0.5) / 10, floor(y * 10 + 0.5) / 10
end

-- The box (l, b) of a w x h frame placed at p, x, y (the reverse of AnchorOf).
function Layout.BoxAt(p, x, y, w, h)
    local W, H = Layout.Screen()
    p = p or "CENTER"
    local l, b
    if p:find("LEFT") then l = x elseif p:find("RIGHT") then l = W + x - w else l = W / 2 + x - w / 2 end
    if p:find("BOTTOM") then b = y elseif p:find("TOP") then b = H + y - h else b = H / 2 + y - h / 2 end
    return l, b
end

---------------------------------------------------------------------------
-- Saved data and profiles
---------------------------------------------------------------------------

local function NewId()
    local t = (time and time()) or 0
    return ("%x%03x"):format(t % 0xffffff, floor((math.random() or 0) * 4095))
end

local function Store()
    local db = ns.db
    if not db then return nil end
    local L = db.layouts
    if type(L) ~= "table" then
        L = { v = 1, profiles = {}, chars = {} }
        db.layouts = L
    end
    if type(L.profiles) ~= "table" then L.profiles = {} end
    if type(L.chars) ~= "table" then L.chars = {} end
    if not L.profiles.default then
        L.profiles.default = { id = "default", name = "Default", frames = {}, mirror = {} }
    end
    return L
end
Layout.Store = Store

local function Clean(p)
    if type(p.frames) ~= "table" then p.frames = {} end
    if type(p.mirror) ~= "table" then p.mirror = {} end
    return p
end

function Layout:ActiveId()
    local L = Store()
    if not L then return "default" end
    local me = Me()
    local id = me and L.chars[me]
    if not id or not L.profiles[id] then id = "default" end
    return id
end

function Layout:Active()
    local L = Store()
    if not L then return Clean({ id = "default", name = "Default" }) end
    return Clean(L.profiles[self:ActiveId()])
end

function Layout:Profile(pid)
    local L = Store()
    local p = L and L.profiles[pid]
    return p and Clean(p) or nil
end

-- { { id, name, by }, ... } by name, Default first.
function Layout:Profiles()
    local L = Store()
    local out = {}
    if not L then return out end
    for id, p in pairs(L.profiles) do out[#out + 1] = { id = id, name = p.name or id, by = p.by } end
    tsort(out, function(a, b)
        if (a.id == "default") ~= (b.id == "default") then return a.id == "default" end
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return out
end

function Layout:NameTaken(name, except)
    local L = Store()
    if not L then return false end
    local n = tostring(name or ""):lower()
    for id, p in pairs(L.profiles) do
        if id ~= except and tostring(p.name or ""):lower() == n then return true end
    end
    return false
end

local function UniqueName(base)
    local name, i = base, 2
    while Layout:NameTaken(name) do name = ("%s %d"):format(base, i); i = i + 1 end
    return name
end
Layout.UniqueName = UniqueName

-- A new profile: a copy of `from` (a profile id; default the one in use, with every frame's place as it is now),
-- or empty with fromEmpty. Returns its id.
function Layout:NewProfile(name, from, fromEmpty)
    local L = Store()
    if not L then return nil end
    if not fromEmpty then self:Capture() end
    local src = not fromEmpty and self:Profile(from or self:ActiveId()) or nil
    local id = NewId()
    while L.profiles[id] do id = NewId() end
    L.profiles[id] = {
        id = id, name = UniqueName(name and name ~= "" and name or "Layout"), by = Me(),
        frames = src and Copy(src.frames) or {}, mirror = src and Copy(src.mirror) or {},
        meters = src and Copy(src.meters) or nil,
    }
    ns:Fire("LAYOUT_CHANGED", "profiles")
    return id
end

function Layout:Rename(pid, name)
    local p = self:Profile(pid)
    if not p or type(name) ~= "string" or name == "" or self:NameTaken(name, pid) then return false end
    p.name = name
    ns:Fire("LAYOUT_CHANGED", "profiles")
    return true
end

-- Deletes a profile (never Default); characters on it go back to Default.
function Layout:Delete(pid)
    local L = Store()
    if not L or pid == "default" or not L.profiles[pid] then return false end
    local wasMine = self:ActiveId() == pid
    L.profiles[pid] = nil
    for who, id in pairs(L.chars) do if id == pid then L.chars[who] = nil end end
    if wasMine then self:ApplyAll() end
    ns:Fire("LAYOUT_CHANGED", "profiles")
    return true
end

-- This character uses profile pid: the frames move to its places.
function Layout:Use(pid)
    local L = Store()
    if not L or not L.profiles[pid] then return false end
    local me = Me()
    if not me then return false end
    if self:ActiveId() == pid then return true end
    self:Capture()
    L.chars[me] = pid ~= "default" and pid or nil
    self:ApplyAll()
    ns:Fire("LAYOUT_CHANGED", "profile")
    return true
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------

function Layout:Register(id, def)
    if type(id) ~= "string" or type(def) ~= "table" then error("Layout:Register(id, def): bad arguments", 2) end
    def.id = id
    def.kind = def.kind or "dz"
    def.group = def.group or "Raid"
    if not items[id] then list[#list + 1] = def end
    for i, d in ipairs(list) do if d.id == id then list[i] = def end end
    items[id] = def
    tsort(list, function(a, b)
        local ga, gb = GROUP_ORDER[a.group] or 9, GROUP_ORDER[b.group] or 9
        if ga ~= gb then return ga < gb end
        if (a.order or 50) ~= (b.order or 50) then return (a.order or 50) < (b.order or 50) end
        return tostring(a.name) < tostring(b.name)
    end)
    if ns.loggedIn and def.kind == "dz" then self:Place(id) end
    ns:Fire("LAYOUT_CHANGED", "items")
    return def
end

function Layout:Item(id) return items[id] end

-- Takes an item off the list (a game frame that a replaced part retired: ours stand in its place).
function Layout:Unregister(id)
    if not items[id] then return end
    items[id] = nil
    for i = #list, 1, -1 do if list[i].id == id then table.remove(list, i) end end
    ns:Fire("LAYOUT_CHANGED", "items")
end
function Layout:Items() return list end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
    return nil
end

function Layout:Frame(id)
    local def = items[id]
    if not def then return nil end
    if type(def.frame) == "function" then return Call(def.frame) end
    return def.frame
end

function Layout:IsMine(id)
    local def = items[id]
    if not def then return false end
    if def.mine == nil then return true end
    if type(def.mine) == "function" then return Call(def.mine) and true or false end
    return def.mine and true or false
end

-- The key its place is kept under (one per variant).
function Layout:Key(id)
    local def = items[id]
    local v = def and def.variant and Call(def.variant)
    if v and v ~= "" then return id .. "." .. tostring(v) end
    return id
end

function Layout:Entry(id)
    return self:Active().frames[self:Key(id)]
end

-- The box of an item on the screen (l, b, w, h in UIParent units), or nil when it isn't shown.
function Layout:Rect(id)
    local def = items[id]
    local f = self:Frame(id)
    if not def or not f then return nil end
    if def.kind == "blizzard" then return self.Blizz:Rect(f) end
    -- (a secure frame hidden by the game's unit watch is measured by its preview, which sits on it: def.box)
    if def.box then
        local b = Call(def.box)
        if b == false then return nil end
        f = b or f
    end
    if not f:IsVisible() then return nil end
    local l, b, w, h = f:GetLeft(), f:GetBottom(), f:GetWidth(), f:GetHeight()
    if not l or not b or not w or not h then return nil end
    local r = Layout.Ratio(f)
    return l * r, b * r, w * r, h * r
end

function Layout:Scale(id)
    local def = items[id]
    if not def then return 1 end
    if def.kind == "blizzard" then
        local pct = self.Blizz:Size(self:Frame(id))
        return pct and pct / 100 or 1
    end
    if def.scale and def.scale.get then return tonumber(Call(def.scale.get)) or 1 end
    local e = self:Entry(id)
    return e and tonumber(e.s) or 1
end

-- How far an item scales: lo, hi, step (nil: it doesn't). Blizzard frames: their Edit Mode slider's range.
function Layout:ScaleRange(id)
    local def = items[id]
    if not def or def.kind == "meters" then return nil end
    if def.kind == "blizzard" then
        local pct, lo, hi, step = self.Blizz:Size(self:Frame(id))
        if not pct then return nil end
        return lo / 100, hi / 100, step / 100
    end
    return 0.5, 2, 0.01
end

-- A stretchable item's own width and height (its units, before scale; nil = its natural size).
function Layout:Size(id)
    local e = self:Entry(id)
    if not e then return nil, nil end
    return tonumber(e.w), tonumber(e.h)
end

-- Which axes an item stretches on: canX, canY.
function Layout:CanStretch(id)
    local def = items[id]
    local st = def and def.kind == "dz" and def.stretch
    if type(st) ~= "table" then return false, false end
    return st.x and true or false, st.y and true or false
end

-- Sets a stretchable item's width / height (its own units; nil leaves that axis as it is, false = natural again).
function Layout:SetSize(id, w, h)
    local def = items[id]
    local st = def and def.kind == "dz" and def.stretch
    if type(st) ~= "table" then return false end
    local key = self:Key(id)
    local e = self:Active().frames[key] or {}
    if w == false then e.w = nil
    elseif w and st.x then e.w = floor(max(st.x[1] or 1, min(st.x[2] or 4000, w)) + 0.5) end
    if h == false then e.h = nil
    elseif h and st.y then e.h = floor(max(st.y[1] or 1, min(st.y[2] or 4000, h)) + 0.5) end
    self:Active().frames[key] = e
    Call(st.apply)
    return true
end

local function SetFrameScale(def, f, s)
    if def.scale and def.scale.set then Call(def.scale.set, s)
    elseif f and def.kind == "dz" then f:SetScale(s) end
end

-- Puts a frame at its place: the profile's, else its old one (legacy), else its default.
local pendingPlace = {}
function Layout:Place(id)
    local def = items[id]
    if not def or def.kind ~= "dz" then return false end
    local f = self:Frame(id)
    if not f then return false end
    if def.protected and InCombat() then pendingPlace[id] = true return false end
    local e = self:Entry(id)
    if e and e.s and not def.scale then f:SetScale(tonumber(e.s) or 1) end
    if e and e.p then
        local r = Layout.Ratio(f)
        f:ClearAllPoints()
        f:SetPoint(e.p, UIParent, e.p, (tonumber(e.x) or 0) / r, (tonumber(e.y) or 0) / r)
        return true
    end
    local p, rp, x, y = Call(def.legacy)
    if type(p) == "string" then
        f:ClearAllPoints()
        if pcall(f.SetPoint, f, p, UIParent, rp or p, tonumber(x) or 0, tonumber(y) or 0) then return true end
    end
    local d = type(def.default) == "function" and Call(def.default) or def.default
    if type(d) == "table" and d[1] then
        local r = Layout.Ratio(f)
        f:ClearAllPoints()
        f:SetPoint(d[1], UIParent, d[1], (d[2] or 0) / r, (d[3] or 0) / r)
        return true
    end
    return false
end

-- Moves an item so its box's bottom-left is (l, b), in UIParent units, and keeps that place in the profile.
-- Blizzard frames: written to the game's Edit Mode layout (Commit applies it).
-- (w, h: the size it will have, when that isn't the size on the screen yet: a Blizzard frame being resized)
function Layout:MoveTo(id, l, b, noCommit, w, h)
    local def = items[id]
    if not def then return false end
    if not w or not h then local _; _, _, w, h = self:Rect(id) end
    if not w then return false end
    local p, x, y = Layout.AnchorOf(l, b, w, h)
    local e = self:Active().frames[self:Key(id)] or {}
    e.p, e.x, e.y = p, x, y
    self:Active().frames[self:Key(id)] = e
    if def.kind == "blizzard" then
        self.Blizz:SetAnchor(self:Frame(id), p, x, y)
        if not noCommit then self.Blizz:Commit() end
        return true
    end
    return self:Place(id)
end

-- stay: leave its place to the caller (Edit layout's handles place it themselves); else its top-left stays put.
-- Blizzard frames: written to the game's Edit Mode layout (in its slider's steps; Commit applies it).
function Layout:SetScale(id, s, stay, noCommit)
    local def = items[id]
    if not def then return false end
    local lo, hi, step = self:ScaleRange(id)
    if not lo then return false end
    s = max(lo, min(hi, tonumber(s) or 1))
    if def.kind == "blizzard" then
        local pct = floor(s * 100 / (step * 100) + 0.5) * (step * 100)
        local e = self:Active().frames[self:Key(id)] or {}
        e.s = pct / 100
        self:Active().frames[self:Key(id)] = e
        self.Blizz:SetSize(self:Frame(id), pct)
        if not noCommit then self.Blizz:Commit() end
        return true
    end
    local f = self:Frame(id)
    local l, b, w, h = self:Rect(id)
    local e = self:Active().frames[self:Key(id)] or {}
    e.s = s
    self:Active().frames[self:Key(id)] = e
    SetFrameScale(def, f, s)
    -- (keep its top-left corner where it was)
    if l and f and not stay then
        local _, _, nw, nh = self:Rect(id)
        if nw then self:MoveTo(id, l, b + h - nh) end
    end
    return true
end

function Layout:IsHidden(id)
    local def = items[id]
    if not def or def.noHide or def.kind ~= "dz" then return false end
    local e = self:Entry(id)
    return e and e.hide and true or false
end

function Layout:SetHidden(id, on)
    local def = items[id]
    if not def or def.noHide or def.kind ~= "dz" then return false end
    local key = self:Key(id)
    local e = self:Active().frames[key] or {}
    e.hide = on and true or nil
    self:Active().frames[key] = e
    ns:Fire("LAYOUT_CHANGED", "hidden", id)
    return true
end

-- A frame hidden in the layout stays hidden (it is shown again while editing, to be moved or brought back).
function Layout:HookHide(id, f)
    if not f or f.cdlLayoutHook then return end
    f.cdlLayoutHook = true
    f:HookScript("OnShow", function(self)
        if Layout:IsHidden(id) and not (ns.EditMode and ns.EditMode:IsActive()) then self:Hide() end
    end)
end

-- Reset: forget the item's place (and scale) in this profile.
function Layout:Reset(id)
    local def = items[id]
    if not def then return end
    self:Active().frames[self:Key(id)] = nil
    if def.kind == "blizzard" then
        self.Blizz:ResetAnchor(self:Frame(id))
        self.Blizz:SetSize(self:Frame(id), 100)
        self.Blizz:Commit()
    else
        if not def.scale then local f = self:Frame(id); if f then f:SetScale(1) end
        elseif def.scale.set then Call(def.scale.set, 1) end
        if def.stretch then Call(def.stretch.apply) end
        self:Place(id)
    end
end

-- Mirrored pairs: b sits where a is, mirrored across the screen's vertical centre.
function Layout:Partner(id) return self:Active().mirror[id] end

function Layout:SetMirror(a, b)
    local m = self:Active().mirror
    if not items[a] or not items[b] or a == b then return false end
    for _, id in ipairs({ a, b }) do
        local o = m[id]
        if o then m[o], m[id] = nil, nil end
    end
    m[a], m[b] = b, a
    self:FollowMirror(a)
    return true
end

function Layout:ClearMirror(a)
    local m = self:Active().mirror
    local b = m[a]
    if b then m[b] = nil end
    m[a] = nil
end

-- Moves a's partner to the mirrored place (same height, same size).
function Layout:FollowMirror(a, noCommit)
    local b = self:Partner(a)
    if not b then return false end
    local l, bt, w, h = self:Rect(a)
    local _, _, bw = self:Rect(b)
    if not l or not bw then return false end
    local W = Layout.Screen()
    local sa = self:Scale(a)
    if items[b].kind == "dz" and items[a].kind == "dz" and abs(self:Scale(b) - sa) > 0.001 then
        self:SetScale(b, sa)
        _, _, bw = self:Rect(b)
    end
    -- (a stretched pair: the same width and height)
    local ax, ay = self:CanStretch(a)
    local bx2, by2 = self:CanStretch(b)
    if (ax and bx2) or (ay and by2) then
        local wa, ha = self:Size(a)
        local wb, hb = self:Size(b)
        if wa ~= wb or ha ~= hb then
            local nw, nh = nil, nil
            if ax and bx2 then nw = wa or false end
            if ay and by2 then nh = ha or false end
            self:SetSize(b, nw, nh)
            _, _, bw = self:Rect(b)
        end
    end
    local _, _, _, bh = self:Rect(b)
    return self:MoveTo(b, W - l - bw, bt + h - (bh or h), noCommit)
end

---------------------------------------------------------------------------
-- Applying a whole profile; capturing the live places into it
---------------------------------------------------------------------------

function Layout:ApplyAll()
    local p = self:Active()
    local blizz = false
    for _, def in ipairs(list) do
        if def.kind == "dz" then
            if def.scale and def.scale.set then
                local e = p.frames[self:Key(def.id)]
                if e and e.s then Call(def.scale.set, e.s) end
            end
            if def.stretch then Call(def.stretch.apply) end
            self:Place(def.id)
        elseif def.kind == "blizzard" then
            local e = p.frames[self:Key(def.id)]
            local f = self:Frame(def.id)
            if e and e.p and f then self.Blizz:SetAnchor(f, e.p, e.x, e.y); blizz = true end
            if e and e.s and f then self.Blizz:SetSize(f, e.s * 100); blizz = true end
        end
    end
    if blizz then self.Blizz:Commit() end
    if type(p.meters) == "table" and ns.DB then
        ns.DB:SetSetting("meters.layout", Copy(p.meters))
        if ns.MeterPanels and ns.MeterPanels.Rebuild then pcall(ns.MeterPanels.Rebuild, ns.MeterPanels) end
    end
    ns:Fire("LAYOUT_CHANGED", "applied")
end

-- Writes what is on the screen into the profile: the game's frames (moved in its own Edit Mode too), the meters'
-- stacks, and (all) every shown DisasterZone frame that has no place of its own yet (before sharing).
function Layout:Capture(all)
    local p = self:Active()
    for _, def in ipairs(list) do
        local key = self:Key(def.id)
        if def.kind == "blizzard" or (all and def.kind == "dz" and not (p.frames[key] and p.frames[key].p)) then
            local l, b, w, h = self:Rect(def.id)
            if l then
                local e = p.frames[key] or {}
                e.p, e.x, e.y = Layout.AnchorOf(l, b, w, h)
                p.frames[key] = e
            end
        end
    end
    if ns.DB then
        local m = ns.DB:GetSetting("meters.layout")
        if type(m) == "table" and type(m.stacks) == "table" then p.meters = Copy(m) end
    end
end

-- Undo: the profile's places as they are now, and back.
function Layout:Snapshot()
    local p = self:Active()
    return { frames = Copy(p.frames), mirror = Copy(p.mirror) }
end

function Layout:Restore(snap)
    if type(snap) ~= "table" then return end
    local p = self:Active()
    p.frames, p.mirror = Copy(snap.frames) or {}, Copy(snap.mirror) or {}
    for _, def in ipairs(list) do
        if def.kind == "dz" and not def.scale then
            local f = self:Frame(def.id)
            local e = p.frames[self:Key(def.id)]
            if f then f:SetScale(e and tonumber(e.s) or 1) end
        elseif def.kind == "dz" and def.scale.set then
            local e = p.frames[self:Key(def.id)]
            if not (e and e.s) and abs(self:Scale(def.id) - 1) > 0.001 then Call(def.scale.set, 1) end
        end
        if def.kind == "blizzard" then
            local e = p.frames[self:Key(def.id)]
            local f = self:Frame(def.id)
            if f then
                if e and e.s then self.Blizz:SetSize(f, e.s * 100) end
                if e and e.p then self.Blizz:SetAnchor(f, e.p, e.x, e.y) else self.Blizz:ResetAnchor(f) end
            end
        end
    end
    self:ApplyAll()
end

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    for id in pairs(pendingPlace) do pendingPlace[id] = nil; Layout:Place(id) end
    if Layout.Blizz.pending then Layout.Blizz:Commit() end
end)

---------------------------------------------------------------------------
-- Blizzard's frames: through the game's Edit Mode layouts
---------------------------------------------------------------------------

local Blizz = { pending = false }
Layout.Blizz = Blizz

-- The frames of the game's Edit Mode that the layout moves (each only if this client has it).
Layout.BLIZZARD = {
    { "PlayerFrame", "Player frame", 1 }, { "TargetFrame", "Target frame", 2 }, { "FocusFrame", "Focus frame", 3 },
    { "PartyFrame", "Party frames", 4 }, { "PlayerCastingBarFrame", "Cast bar", 5 },
    { "MainActionBar", "Action bar 1", 6 }, { "MultiBarBottomLeft", "Action bar 2", 7 },
    { "MultiBarBottomRight", "Action bar 3", 8 }, { "MultiBarRight", "Action bar 4", 9 },
    { "MultiBarLeft", "Action bar 5", 10 }, { "StanceBar", "Stance bar", 11 }, { "PetActionBar", "Pet bar", 12 },
    { "MinimapCluster", "Minimap", 13 }, { "BuffFrame", "Buffs", 14 },
    { "MicroMenuContainer", "Menu", 15 }, { "BagsBar", "Bags", 16 },
}

function Blizz:Available()
    return C_EditMode and C_EditMode.GetLayouts and C_EditMode.SaveLayouts and EditModeManagerFrame and true or false
end

-- The game's layouts with its presets in front (activeLayout counts them), as its Edit Mode keeps them.
function Blizz:Load()
    if self.info then return self.info end
    if not self:Available() then return nil end
    local ok, li = pcall(C_EditMode.GetLayouts)
    if not ok or type(li) ~= "table" or type(li.layouts) ~= "table" then return nil end
    local P = EditModePresetLayoutManager
    if P and P.GetCopyOfPresetLayouts then
        local ok2, presets = pcall(P.GetCopyOfPresetLayouts, P)
        if ok2 and type(presets) == "table" then
            for _, l in ipairs(li.layouts) do presets[#presets + 1] = l end
            li.layouts = presets
        end
    end
    self.info = li
    return li
end

local function PresetType() return Enum and Enum.EditModeLayoutType and Enum.EditModeLayoutType.Preset or 0 end
local function CharType() return Enum and Enum.EditModeLayoutType and Enum.EditModeLayoutType.Character or 2 end

-- The active layout, made editable: on a preset (Modern / Classic) a character layout "DisasterZone" is made from it.
function Blizz:Editable()
    local li = self:Load()
    if not li then return nil end
    local a = li.layouts[li.activeLayout]
    if not a then return nil end
    if a.layoutType ~= PresetType() then return a end
    local copy = Copy(a)
    copy.layoutType = CharType()
    local taken = {}
    for _, l in ipairs(li.layouts) do taken[tostring(l.layoutName)] = true end
    local name, i = "DisasterZone", 2
    while taken[name] do name = "DisasterZone " .. i; i = i + 1 end
    copy.layoutName = name
    local at = 1
    for i2, l in ipairs(li.layouts) do if l.layoutType ~= nil then at = i2 + 1 end end
    tinsert(li.layouts, at, copy)
    li.activeLayout = at
    self.newActive = true
    return copy
end

local function SystemOf(layout, f)
    if not layout or not f or f.system == nil then return nil end
    for _, s in ipairs(layout.systems or {}) do
        if s.system == f.system and s.systemIndex == f.systemIndex then return s end
    end
    return nil
end

function Blizz:SetAnchor(f, p, x, y)
    local s = SystemOf(self:Editable(), f)
    if not s then return false end
    s.anchorInfo = { point = p, relativeTo = "UIParent", relativePoint = p, offsetX = x, offsetY = y }
    s.anchorInfo2 = nil
    s.isInDefaultPosition = false
    self.dirty = true
    return true
end

-- The size setting of each Edit Mode system (its slider: Frame Size, Icon Size, Bar Size, Size).
local function SizeSetting(system)
    local E = Enum
    if not E or not E.EditModeSystem or system == nil then return nil end
    local S = E.EditModeSystem
    local map = {
        { S.UnitFrame, E.EditModeUnitFrameSetting, "FrameSize" },
        { S.ActionBar, E.EditModeActionBarSetting, "IconSize" },
        { S.CastBar, E.EditModeCastBarSetting, "BarSize" },
        { S.Minimap, E.EditModeMinimapSetting, "Size" },
        { S.AuraFrame, E.EditModeAuraFrameSetting, "IconSize" },
        { S.MicroMenu, E.EditModeMicroMenuSetting, "Size" },
        { S.Bags, E.EditModeBagsSetting, "Size" },
    }
    for _, m in ipairs(map) do
        if m[1] ~= nil and m[1] == system and m[2] and m[2][m[3]] ~= nil then return m[2][m[3]] end
    end
    return nil
end
Layout.SizeSetting = SizeSetting

-- The slider of f's size setting: setting, min, max, step (the game's own display info).
local function SizeInfo(f)
    local setting = f and SizeSetting(f.system)
    if setting == nil then return nil end
    local M = EditModeSettingDisplayInfoManager
    local infos = M and M.systemSettingDisplayInfo and M.systemSettingDisplayInfo[f.system]
    for _, d in ipairs(infos or {}) do
        if d.setting == setting and d.minValue and d.maxValue then
            return setting, d.minValue, d.maxValue, d.stepSize or 1
        end
    end
    return nil
end

-- f's size in % and its slider's range: pct, min, max, step (nil when its system has no size).
function Blizz:Size(f)
    local setting, lo, hi, step = SizeInfo(f)
    if setting == nil then return nil end
    local pct = 100
    local li = self:Load()
    local s = li and SystemOf(li.layouts[li.activeLayout], f)
    for _, v in ipairs(s and s.settings or {}) do
        if v.setting == setting then pct = lo + (tonumber(v.value) or 0) * step end
    end
    return max(lo, min(hi, pct)), lo, hi, step
end

-- Writes f's size (in %, to its slider's step) into the layout (Commit applies it).
function Blizz:SetSize(f, pct)
    local setting, lo, hi, step = SizeInfo(f)
    if setting == nil then return false end
    local s = SystemOf(self:Editable(), f)
    if not s then return false end
    pct = max(lo, min(hi, floor((tonumber(pct) or 100) / step + 0.5) * step))
    local raw = floor((pct - lo) / step + 0.5)
    if type(s.settings) ~= "table" then s.settings = {} end
    for _, v in ipairs(s.settings) do
        if v.setting == setting then
            if v.value ~= raw then v.value = raw; self.dirty = true end
            return true
        end
    end
    s.settings[#s.settings + 1] = { setting = setting, value = raw }
    self.dirty = true
    return true
end

function Blizz:ResetAnchor(f)
    local s = SystemOf(self:Editable(), f)
    local P = EditModePresetLayoutManager
    if not s or not (P and P.GetDefaultSystemAnchorInfo) then return false end
    local ok, a = pcall(P.GetDefaultSystemAnchorInfo, P, f.system, f.systemIndex)
    if not ok or type(a) ~= "table" then return false end
    s.anchorInfo, s.anchorInfo2, s.isInDefaultPosition = Copy(a), nil, true
    self.dirty = true
    return true
end

-- Saves the layouts and has the game apply them (out of combat; in combat it waits for the fight to end).
function Blizz:Commit()
    if not self.dirty and not self.pending then return false end
    if InCombat() then self.pending = true return false end
    self.pending = false
    local li = self.info
    if not li or not self:Available() then self.dirty = false return false end
    local ok = pcall(C_EditMode.SaveLayouts, li)
    if ok and self.newActive and C_EditMode.SetActiveLayout then
        pcall(C_EditMode.SetActiveLayout, li.activeLayout)
        self.newActive = false
    end
    -- (as LibEditModeOverride does: a menu list left insecure would spread to the Edit Mode panel)
    if DropDownList1 and issecurevariable and not issecurevariable(DropDownList1, "numButtons") and AddonList then
        pcall(ShowUIPanel, AddonList); pcall(HideUIPanel, AddonList)
    end
    if ShowUIPanel and HideUIPanel then
        pcall(ShowUIPanel, EditModeManagerFrame)
        pcall(HideUIPanel, EditModeManagerFrame)
    end
    self.dirty = false
    self.info = nil                   -- (read the game's copy again next time)
    return ok
end

-- A Blizzard frame's box (UIParent units): where it is, or where its layout puts it while it is hidden.
function Blizz:Rect(f)
    if not f then return nil end
    local r = Layout.Ratio(f)
    local w, h = (f:GetWidth() or 0) * r, (f:GetHeight() or 0) * r
    if w <= 0 or h <= 0 then return nil end
    if f:IsShown() and f:GetLeft() then return f:GetLeft() * r, f:GetBottom() * r, w, h end
    local a = f.systemInfo and f.systemInfo.anchorInfo
    if type(a) == "table" and a.relativeTo == "UIParent" and a.point == a.relativePoint then
        local l, b = Layout.BoxAt(a.point, a.offsetX or 0, a.offsetY or 0, w, h)
        return l, b, w, h
    end
    return nil
end

function Layout:RegisterBlizzard()
    if not Blizz:Available() then return end
    for _, t in ipairs(Layout.BLIZZARD) do
        local name = t[1]
        local f = _G[name]
        if f and f.system ~= nil and not items["blizz:" .. name] then
            self:Register("blizz:" .. name, { name = t[2], group = "Game frames", order = t[3], kind = "blizzard",
                frame = function() return _G[name] end, noHide = true })
        end
    end
end

---------------------------------------------------------------------------
-- Sharing a profile (UI/Share.lua: "layout:<owner>:<id>"; the profile comes over a whisper from its owner)
---------------------------------------------------------------------------

function Layout:ShareRef(pid)
    local me = Me()
    pid = pid or self:ActiveId()
    if not me or not self:Profile(pid) then return nil end
    return "layout:" .. me .. ":" .. pid
end

function Layout.ParseRef(arg)
    if type(arg) ~= "string" then return nil end
    local owner, pid = arg:match("^(.+):([%w_]+)$")
    return owner, pid
end

-- What a profile sends: its places, pairs and meters, with every shown frame's place filled in.
function Layout:Export(pid)
    if pid == self:ActiveId() then self:Capture(true) end
    local p = self:Profile(pid)
    if not p then return nil end
    return { n = p.name, f = Copy(p.frames), m = Copy(p.mirror), me = Copy(p.meters) }
end

-- Adds a received profile under a free name; returns its id.
function Layout:Import(data, owner)
    if type(data) ~= "table" or type(data.f) ~= "table" then return nil end
    local L = Store()
    if not L then return nil end
    local id = NewId()
    while L.profiles[id] do id = NewId() end
    local who = owner and ns.Util and ns.Util.ShortName and ns.Util.ShortName(owner) or owner
    local name = tostring(data.n or "Layout")
    if who and who ~= "" then name = ("%s (%s)"):format(name, who) end
    local frames = {}
    for k, e in pairs(data.f) do
        if type(k) == "string" and type(e) == "table" then
            frames[k] = { p = type(e.p) == "string" and e.p or nil, x = tonumber(e.x), y = tonumber(e.y),
                          s = tonumber(e.s), hide = e.hide and true or nil }
        end
    end
    local mirror = {}
    for a, b in pairs(type(data.m) == "table" and data.m or {}) do
        if type(a) == "string" and type(b) == "string" then mirror[a] = b end
    end
    L.profiles[id] = { id = id, name = UniqueName(name), by = owner, frames = frames, mirror = mirror,
                       meters = type(data.me) == "table" and Copy(data.me) or nil }
    ns:Fire("LAYOUT_CHANGED", "profiles")
    return id
end

local asked = {}       -- [owner .. ":" .. pid] = time asked (a reply nobody asked for is dropped)

function Layout:Request(owner, pid)
    local Comm = ns.Comm
    if not Comm or not owner or not pid then return false end
    if ns.Util.IsMe(owner) then return false end
    if not Comm:RateLimit("layout:" .. owner, 3) then return true end
    asked[owner .. ":" .. pid] = GetTime and GetTime() or 0
    return Comm:Send({ t = "LAYQ", id = pid }, "WHISPER", owner, "ctrl")
end

local function OnAsk(sender, msg)
    if type(msg.id) ~= "string" or not Layout:Profile(msg.id) then
        ns.Comm:Send({ t = "LAYP", id = tostring(msg.id), gone = true }, "WHISPER", sender, "data")
        return
    end
    if not ns.Comm:RateLimit("layq:" .. tostring(sender), 2) then return end
    local data = Layout:Export(msg.id)
    local reply = { t = "LAYP", id = msg.id, p = data }
    if not ns.Comm:Fits(reply) then data.me = nil end        -- (too big with the meters: places only)
    ns.Comm:Send(reply, "WHISPER", sender, "data")
end

local function OnProfile(sender, msg)
    local key = tostring(sender) .. ":" .. tostring(msg.id)
    if not asked[key] then return end
    asked[key] = nil
    ns:Fire("LAYOUT_RECEIVED", sender, msg.id, not msg.gone and msg.p or nil)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Layout:OnLogin()
    Store()
    if ns.Comm then
        ns.Comm:Register("LAYQ", OnAsk)
        ns.Comm:Register("LAYP", OnProfile)
    end
    self:RegisterBlizzard()
    for _, def in ipairs(list) do if def.kind == "dz" then self:Place(def.id) end end
end

ns:RegisterSlash("edit", function()
    if ns.EditMode then ns.EditMode:Toggle() end
end, "move, line up and mirror every DisasterZone frame and the game's own (Edit layout)")

-- The key binding (Bindings.xml; its header is set in UI/BlessingsBar.lua).
BINDING_HEADER_DISASTERZONE = BINDING_HEADER_DISASTERZONE or "DisasterZone"
BINDING_NAME_DISASTERZONE_EDITLAYOUT = "Edit layout (move every frame)"
function DisasterZone_ToggleEditLayout()
    if ns.EditMode then ns.EditMode:Toggle() end
end
