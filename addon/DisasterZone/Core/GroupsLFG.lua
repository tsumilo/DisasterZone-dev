if DisasterZoneBoot and DisasterZoneBoot.Run("Core/GroupsLFG.lua", ...) then return end -- DisasterZone: Core/GroupsLFG.lua
-- (1.5, feedback #8) My group's message for the LookingForGroup channel, built from blocks: LFM, the guild tag, the
-- group's name, how full it is, what it needs (tanks / healers / melee / ranged, from the open places and my split of
-- the damage places), the specs I'm after, the buffs it lacks, when, the loot, the bosses, my note, my own words,
-- "/w me". Each block can be switched off and the blocks reordered; the text is what the channel gets (255 at most).
-- Posting needs a click or a key press (the client sends to public channels only inside a hardware event), so the
-- repeat doesn't post by itself: every N seconds the message is ready again (GROUPS_LFG_READY) and the poster's
-- button, or its key binding, sends it. The repeat stops when the group is full or gone.
-- Saved: db.groupsLfg = { order, off = { [key] = true }, custom, every, want = { [run id] = { melee, ranged,
-- specs = { ["CLASS:sp"] = n } } } } (account-wide; a group's targets are dropped with the group).
local addonName, ns = ...

local LFG = ns:NewModule("GroupsLFG")

local floor, max, min = math.floor, math.max, math.min
local tconcat, tsort = table.concat, table.sort

local MAX_LEN = 255
local EVERY = { 30, 60, 120 }

-- The blocks in their first order: key, the chip's name, on at first.
local BLOCKS = {
    { key = "lfm", label = "LFM", on = true },
    { key = "tag", label = "Guild tag", on = false },
    { key = "name", label = "Raid name", on = true },
    { key = "count", label = "18/25", on = true },
    { key = "need", label = "What we need", on = true },
    { key = "specs", label = "Specs wanted", on = true },
    { key = "lacks", label = "Missing buffs", on = false },
    { key = "time", label = "When", on = true },
    { key = "loot", label = "Loot", on = true },
    { key = "bosses", label = "Bosses", on = false },
    { key = "note", label = "Your note", on = false },
    { key = "custom", label = "Your words", on = false },
    { key = "whisper", label = "/w me", on = true },
}
local BLOCK = {}
for _, b in ipairs(BLOCKS) do BLOCK[b.key] = b end

local SHORT_SPEC = { Restoration = "Resto", Discipline = "Disc", Protection = "Prot", Retribution = "Ret",
                     ["Beast Mastery"] = "BM", Marksmanship = "MM", Survival = "SV", Elemental = "Ele",
                     Enhancement = "Enh", Assassination = "Assa", Subtlety = "Sub", Affliction = "Affli",
                     Demonology = "Demo", Destruction = "Destro", ["Feral (Cat)"] = "Feral", ["Feral (Bear)"] = "Bear" }

local function R() return ns.DungeonRuns end
local function Util() return ns.Util end

local function DB()
    local db = ns.db
    if not db then return { order = {}, off = {}, want = {} } end
    db.groupsLfg = db.groupsLfg or {}
    local d = db.groupsLfg
    d.off = d.off or {}
    d.want = d.want or {}
    if type(d.order) ~= "table" then d.order = {} end
    -- every block once, the saved order first, new blocks where they belong
    local seen, order = {}, {}
    for _, k in ipairs(d.order) do
        if BLOCK[k] and not seen[k] then order[#order + 1], seen[k] = k, true end
    end
    for i, b in ipairs(BLOCKS) do
        if not seen[b.key] then
            table.insert(order, min(i, #order + 1), b.key)
            if not b.on and d.off[b.key] == nil then d.off[b.key] = true end
        end
    end
    d.order = order
    d.every = (d.every == 60 or d.every == 120) and d.every or 30
    return d
end

---------------------------------------------------------------------------
-- What the group is looking for: the open places, the damage split, the specs
---------------------------------------------------------------------------

local function MyGroup() return R() and R():GetMyGroup() end

local function Want(run)
    local d = DB()
    local w = d.want[run.id]
    if not w then
        w = { specs = {} }
        d.want[run.id] = w
    end
    w.specs = w.specs or {}
    return w
end

-- What my group needs: { tank, healer, dps (unsplit), melee, ranged } from its open places and my split.
function LFG:GetNeed(run)
    run = run or MyGroup()
    local out = { tank = 0, healer = 0, dps = 0, melee = 0, ranged = 0 }
    if not run then return out end
    local open = R():GetOpenRoles(run)
    out.tank, out.healer = open.tank or 0, open.healer or 0
    local dps = open.dps or 0
    local w = Want(run)
    out.melee = min(w.melee or 0, dps)
    out.ranged = min(w.ranged or 0, dps - out.melee)
    out.dps = dps - out.melee - out.ranged
    return out
end

-- Moves damage places between melee / ranged / any: role "melee" | "ranged", dir +1 / -1.
function LFG:StepSplit(role, dir, run)
    run = run or MyGroup()
    if not run or (role ~= "melee" and role ~= "ranged") then return false end
    local w = Want(run)
    local need = self:GetNeed(run)
    local v = (w[role] or 0) + dir
    if v < 0 or (dir > 0 and need.dps <= 0) then return false end
    w[role] = v
    ns:Fire("GROUPS_LFG_CHANGED")
    return true
end

-- The specs I'm after: { { c, sp, n, key } } in class order.
function LFG:GetSpecs(run)
    run = run or MyGroup()
    local out = {}
    if not run then return out end
    for key, n in pairs(Want(run).specs) do
        local c, sp = key:match("^(%u+):(%d+)$")
        sp = tonumber(sp)
        if c and sp and n > 0 then out[#out + 1] = { c = c, sp = sp, n = n, key = key } end
    end
    tsort(out, function(a, b)
        if a.c ~= b.c then return a.c < b.c end
        return a.sp < b.sp
    end)
    return out
end

function LFG:SetSpec(classFile, sp, n, run)
    run = run or MyGroup()
    if not run or not (ns.SPECS[classFile] and ns.SPECS[classFile][sp]) then return false end
    Want(run).specs[classFile .. ":" .. sp] = (n and n > 0) and min(n, 10) or nil
    ns:Fire("GROUPS_LFG_CHANGED")
    return true
end

-- "Resto Shaman", "Holy Paladin" (short spec names, the class's name).
function LFG:SpecName(classFile, sp)
    local spec = ns.SPECS[classFile] and ns.SPECS[classFile][sp]
    local label = spec and (SHORT_SPEC[spec.label] or spec.label) or "?"
    local cls = ns.ClassName and ns.ClassName(classFile) or classFile
    return label .. " " .. cls
end

---------------------------------------------------------------------------
-- The blocks and the text
---------------------------------------------------------------------------

local function Plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

-- One block's text for my group, or nil when it has nothing to say.
local function BlockText(key, run)
    if key == "lfm" then return "LFM" end
    if key == "tag" then
        local g = GetGuildInfo and GetGuildInfo("player")
        return g and ("<" .. g .. ">") or nil
    end
    if key == "name" then
        -- (short: "Gruul + Mag"; several quests: the first one's name and "+1")
        local name = R():GetName(run)
        local IDB = ns.ItemDB
        if run.k == "raid" and IDB and IDB.RaidShort then
            local parts = {}
            for _, rk in ipairs(run.a or {}) do parts[#parts + 1] = IDB:RaidShort(rk) or rk end
            name = tconcat(parts, " + ")
        elseif run.k == "quest" and ns.GroupQuests and run.a and #run.a > 1 then
            name = (ns.GroupQuests:GetName(run.a[1]) or name) .. " +" .. (#run.a - 1)
        end
        if R():GetKind(run) == "dungeon" and run.h then name = "H " .. name end
        return name
    end
    if key == "count" then
        local filled = 0
        for _, d in ipairs(R():GetSlots(run)) do if not d.empty then filled = filled + 1 end end
        return filled .. "/" .. R():GetSize(run)
    end
    if key == "need" then
        local n = LFG:GetNeed(run)
        local parts = {}
        if n.tank > 0 then parts[#parts + 1] = Plural(n.tank, "tank", "tanks") end
        if n.healer > 0 then parts[#parts + 1] = Plural(n.healer, "healer", "healers") end
        if n.melee > 0 then parts[#parts + 1] = n.melee .. " melee" end
        if n.ranged > 0 then parts[#parts + 1] = n.ranged .. " ranged" end
        if n.dps > 0 then parts[#parts + 1] = n.dps .. ((n.melee + n.ranged > 0) and " more DPS" or " DPS") end
        return #parts > 0 and ("need " .. tconcat(parts, ", ")) or nil
    end
    if key == "specs" then
        local list = {}
        for _, s in ipairs(LFG:GetSpecs(run)) do
            list[#list + 1] = LFG:SpecName(s.c, s.sp) .. (s.n > 1 and (" x" .. s.n) or "")
        end
        return #list > 0 and tconcat(list, ", ") or nil
    end
    if key == "lacks" then
        local Comp = ns.RaidComp
        if run.k ~= "raid" or not (Comp and Comp.Coverage) then return nil end
        local members, names = {}, {}
        for _, d in ipairs(R():GetSlots(run)) do
            if not d.empty and d.class then members[#members + 1] = { key = d.key, c = d.class } end
        end
        for _, e in ipairs(Comp:Coverage(members, "raid")) do
            if #e.providers == 0 and #names < 2 then names[#names + 1] = e.buff.name end
        end
        return #names > 0 and ("no " .. tconcat(names, " or ") .. " yet") or nil
    end
    if key == "time" then
        if (run.at or 0) > Util().Now() + 60 then return "at " .. date("%H:%M", run.at) .. " server" end
        return "now"
    end
    if key == "loot" then
        if run.k ~= "raid" then return nil end
        if run.lo == "sr" then return "SR " .. (run.lr or 1) end
        if run.lo == "lc" then return "loot council" end
        return "rolls"
    end
    if key == "bosses" then
        if run.k ~= "raid" then return nil end
        if not run.bo then return "full clear" end
        local names = {}
        for _, b in ipairs(R():GetGroupBosses(run)) do names[#names + 1] = b.name end
        return #names > 0 and tconcat(names, " + ") or nil
    end
    if key == "note" then return run.no end
    if key == "custom" then
        local t = DB().custom
        return (type(t) == "string" and Util().Trim(t) ~= "") and Util().Trim(t) or nil
    end
    if key == "whisper" then
        local me = Util().PlayerKey()
        return me and ("/w " .. (Util().ShortName(me) or me)) or nil
    end
    return nil
end

-- The blocks in my order: { { key, label, on, text } } (text nil: nothing to say for this group).
function LFG:GetBlocks(run)
    run = run or MyGroup()
    local d = DB()
    local out = {}
    for _, k in ipairs(d.order) do
        out[#out + 1] = { key = k, label = BLOCK[k].label, on = not d.off[k], text = run and BlockText(k, run) or nil }
    end
    return out
end

function LFG:SetBlockOn(key, on)
    if not BLOCK[key] then return false end
    DB().off[key] = (not on) or nil
    ns:Fire("GROUPS_LFG_CHANGED")
    return true
end

-- Moves a block to position `to` (1 = first).
function LFG:MoveBlock(key, to)
    local d = DB()
    local from
    for i, k in ipairs(d.order) do if k == key then from = i end end
    if not from then return false end
    table.remove(d.order, from)
    to = max(1, min(tonumber(to) or from, #d.order + 1))
    table.insert(d.order, to, key)
    ns:Fire("GROUPS_LFG_CHANGED")
    return true
end

function LFG:GetCustom() return DB().custom or "" end
function LFG:SetCustom(text)
    DB().custom = type(text) == "string" and text:sub(1, 120) or nil
    ns:Fire("GROUPS_LFG_CHANGED")
end

-- Back to the first order and switches.
function LFG:Reset()
    local d = DB()
    d.order, d.off = {}, {}
    DB()
    ns:Fire("GROUPS_LFG_CHANGED")
end

-- The message for my group: text (nil when there is no group or nothing to say), its length, too long?
function LFG:Compose(run)
    run = run or MyGroup()
    if not run then return nil, 0, false end
    local parts = {}
    local lead
    for _, b in ipairs(self:GetBlocks(run)) do
        if b.on and b.text and b.text ~= "" then
            if b.key == "lfm" and #parts == 0 then lead = b.text else parts[#parts + 1] = b.text end
        end
    end
    local text = tconcat(parts, " · ")
    if lead then text = lead .. (text ~= "" and (" " .. text) or "") end
    if text == "" then return nil, 0, false end
    return text, #text, #text > MAX_LEN
end
LFG.MAX_LEN = MAX_LEN

---------------------------------------------------------------------------
-- Posting and the repeat
---------------------------------------------------------------------------

local rep = { on = false, nextAt = 0, ready = false, lastAt = nil }

local function ChannelId()
    local id = GetChannelName and GetChannelName("LookingForGroup")
    id = tonumber(id)
    return (id and id > 0) and id or nil
end

-- Sends the message to the LookingForGroup channel (call it from a click or a key: the client needs one).
-- Returns ok, why.
function LFG:Post()
    local run = MyGroup()
    if not run then return false, "You have no group listed." end
    local text, _, long = self:Compose(run)
    if not text then return false, "The message is empty: switch a block on." end
    if long then text = text:sub(1, MAX_LEN) end
    local open = R():GetOpenRoles(run)
    if not next(open) then return false, "Your group is full." end
    if Util().DemoOn() then
        ns:Print("Demo mode, not sent: %s", text)
    else
        local id = ChannelId()
        if not id then return false, "Join the LookingForGroup channel first: /join LookingForGroup" end
        SendChatMessage(text, "CHANNEL", nil, id)
    end
    rep.lastAt = Util().Now()
    rep.ready = false
    rep.nextAt = Util().Now() + DB().every
    ns:Fire("GROUPS_LFG_POSTED")
    return true
end

function LFG:IsRepeating() return rep.on end
function LFG:IsReady() return rep.on and rep.ready end
-- Seconds until the message is ready again (0 when it is), nil when not repeating.
function LFG:GetWait()
    if not rep.on then return nil end
    return max(0, rep.nextAt - Util().Now())
end
function LFG:GetEvery() return DB().every end
function LFG:GetEveryChoices() return EVERY end
function LFG:SetEvery(sec)
    local d = DB()
    d.every = (sec == 60 or sec == 120) and sec or 30
    if rep.on and rep.nextAt > Util().Now() + d.every then rep.nextAt = Util().Now() + d.every end
    ns:Fire("GROUPS_LFG_CHANGED")
end
function LFG:GetLastPost() return rep.lastAt end

-- The repeat: on = the message is ready now, and again every N seconds after each post.
function LFG:SetRepeat(on)
    on = on and true or false
    if on and not MyGroup() then return false, "You have no group listed." end
    rep.on = on
    rep.ready = on
    rep.nextAt = Util().Now()
    ns:Fire("GROUPS_LFG_REPEAT", on)
    if on then ns:Fire("GROUPS_LFG_READY") end
    return true
end

local function Tick()
    if not rep.on then return end
    local run = MyGroup()
    if not run or not next(R():GetOpenRoles(run)) then
        rep.on, rep.ready = false, false
        ns:Fire("GROUPS_LFG_REPEAT", false)
        if run then ns:Print("Your group is full: the LFG message stops.") end
        return
    end
    if not rep.ready and Util().Now() >= rep.nextAt then
        rep.ready = true
        ns:Fire("GROUPS_LFG_READY")
    end
end

-- (tests) the repeat's clock: due now.
function LFG:_Due() rep.nextAt = Util().Now() - 1; Tick() end

-- Old groups' targets go (the group is gone).
local function Prune()
    local d = ns.db and ns.db.groupsLfg
    if not (d and d.want and R()) then return end
    local mine = MyGroup()
    for id in pairs(d.want) do
        if not (mine and mine.id == id) then d.want[id] = nil end
    end
end

function LFG:OnInit()
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(1, Tick) end
    ns:On("DUNGEON_RUNS_UPDATED", function()
        Util().Debounce("groups-lfg-prune", 5, Prune)
        Tick()
    end)
end
