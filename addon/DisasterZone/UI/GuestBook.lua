if DisasterZoneBoot and DisasterZoneBoot.Run("UI/GuestBook.lua", ...) then return end -- DisasterZone: UI/GuestBook.lua
-- Raids > Guests (1.3.2; the GM, officers and the raid leaders): the guest book and the raid blacklist in one view of
-- the Raids tab.
--   Left:  one search box that also adds: a name the book doesn't have becomes the row "Add <name>" (on the Blacklist
--          filter "Blacklist <name>"); the filters Everyone / Recruits / Blacklist with their counts; the players with
--          their class circle, name, one line (their next guest seat, raids and the last one, a no-show, when they
--          were blacklisted) and marks (recruit star, note, blacklisted). Right-click: the quick actions.
--   Right: the picked player's profile. A banner with the loading screen of their last raid, their spec and realm,
--          the numbers (raids, boss kills, no-shows, items for the loot council), Recruit and Add to a raid (the next
--          two weeks' raids, a check where they have a seat), Whisper and More; the note under it with who wrote it
--          (the pencil turns it into a field in place: Enter or a click away saves, Escape restores); their raids from
--          the next one down (the kills they were there for, bench, no-shows) and the items they received (loot
--          council). A blacklisted player: a red banner, the reason in the note's place, Take off the blacklist. A
--          name typed in: a fresh profile with the note field, the class (+ spec) and Add; on the Blacklist filter the
--          reason and Blacklist.
-- And wherever a player shows up in the game:
--   the player tooltip says when they are on the raid blacklist (players outside the guild for everyone, guild
--   members only for the roster managers; the reason only for them), and what the guest book knows (roster managers);
--   the player right-click menus (unit frames, raid frames, chat names) get "Blacklist..." and "Guest book..." for
--   the roster managers (Menu.ModifyMenu, when the client has it).
local addonName, ns = ...

local GuestUI = ns:NewModule("GuestBookUI")

local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local DAY = 86400
local ADD_AHEAD = 14 * DAY         -- the raids a guest can be added to from the book: the next two weeks
local MENU_TAGS = { "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_RAID",
                    "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS", "MENU_UNIT_FRIEND", "MENU_UNIT_ENEMY_PLAYER" }

-- The view on the Raids tab's grid: PAD at the sides, GAP between blocks (the Raid log's numbers).
local PAD, GAP = 10, 8
local LIST_W = 250                 -- the players column
local DETAIL_W = 770 - LIST_W - GAP
local VIEW_H = 501                 -- the view's height inside its bottom margin (the mock's anchored frames have none)
local SEARCH_H = 24
local TABS_Y = SEARCH_H + 6        -- the filters under the search box
local LIST_Y = TABS_Y + 18 + 6
local ROW_H = 38                   -- a player in the list
local BAN_H = 128                  -- the profile's banner
local HIST_ROW_H = 34              -- a raid / an item in the profile
local SECT_H = 27                  -- a section title and its rule
local COL_GAP = 16                 -- Raids | Items
local FIELD_X = 52                 -- the fresh profile's fields, after their labels
local ART_TOP = 0.29               -- a loading screen's picture starts under the game's logo
local EDGE = { 0.34, 0.34, 0.38, 0.7 }
local RED_EDGE = { 0.89, 0.36, 0.31, 0.6 }
local MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\"
local STAR_TEX, STAR_COORDS = "Interface\\Common\\ReputationStar", { 0, 0.5, 0, 0.5 }
local BLOCK_TEX = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"

-- state.filter: "all" | "recruits" | "black"; state.sel + state.selKind: the picked row (selKind nil = a player of the
-- book or the blacklist, "add" = a name typed in (a fresh profile), "black" = a name typed in on the Blacklist filter);
-- state.draft: the fresh profile's picks { key, recruit, c, sp }; state.editing: the note / reason field is open.
local state = { filter = "all", search = "", draft = {} }
local view

local function UI() return ns.UI end
local function RP() return ns.RaidPlan end
local function GB() return ns.GuestBook end

local function Print(...) ns:Print(...) end

local function grey(text) return "|cff808080" .. tostring(text) .. "|r" end

local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

local function hideTooltip() GameTooltip:Hide() end

local function isManager()
    local R = RP()
    return (R and R.CanManageRoster and R:CanManageRoster()) and true or false
end

local function demoOn()
    return (ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()) and true or false
end

-- Awarded items are loot council data (the GM and the guild council), as in the Raid log.
local function seesItems()
    local G = ns.Guild
    return (demoOn() or (G and G.IsGuildCouncil and G:IsGuildCouncil(ns.Util.PlayerKey()))) and true or false
end

-- The Raid log (a raid row opens it) is for its members.
local function seesRaidLog()
    local G = ns.Guild
    return (demoOn() or (G and G.AmIRaidLogMember and G:AmIRaidLogMember())) and true or false
end

local function inGuild(key)
    local G = ns.Guild
    return (G and G.IsInGuild and G:IsInGuild(key, true)) and true or false
end

local function specText(c, sp)
    local spec = c and sp and ns.SPECS and ns.SPECS[c] and ns.SPECS[c][sp]
    local cls = c and ns.CLASS_NAMES and ns.CLASS_NAMES[c] or ""
    return spec and (spec.label .. " " .. cls) or cls
end

-- "Pyrewood Village" for a player from another realm (their key keeps it without spaces), else nil.
local function realmText(key)
    local realm = ns.Util.RealmOf and ns.Util.RealmOf(key)
    if not realm then return nil end
    return (realm:gsub("(%l)(%u)", "%1 %2"))
end

local function plural(n, one, many) return n == 1 and ("1 " .. one) or (n .. " " .. (many or (one .. "s"))) end

local function whisper(key)
    local name = (Ambiguate and Ambiguate(key, "none")) or shortName(key)
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if open then open("/w " .. name .. " ") end
end

local function newText(parent, font, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
    end
    return fs
end

local function gradient(tex, orient, r, g, b, a1, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if tex.SetGradient and CreateColor then tex:SetGradient(orient, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2)) end
end

-- The first of the texts that fits in `room` (the last one when none does): never cut off with "...".
local function fitText(fs, variants, room)
    for i, text in ipairs(variants) do
        fs:SetText((text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
        local fits = (fs:GetStringWidth() or 0) <= room
        fs:SetText(text)
        if i == #variants or fits then return text end
    end
end

local function atlasTex(tex, icon, r, g, b)
    tex:SetTexture(UI().ICON_ATLAS)
    tex:SetTexCoord(unpack(UI():IconCoords(icon)))
    tex:SetVertexColor(r or 1, g or 1, b or 1)
end

local function starTex(tex, on)
    tex:SetTexture(STAR_TEX)
    tex:SetTexCoord(unpack(STAR_COORDS))
    tex:SetDesaturated(not on)
    if on then tex:SetVertexColor(1, 1, 1) else tex:SetVertexColor(0.75, 0.75, 0.75) end
end

local function starText(size) return ("|T%s:%d:%d:0:0:32:32:0:16:0:16|t"):format(STAR_TEX, size or 14, size or 14) end
local function blockText(size) return ("|T%s:%d:%d|t"):format(BLOCK_TEX, size or 14, size or 14) end
local function iconText(i) return UI():AtlasIconText(i, 14) end

-- A raid's loading screen on a texture, cropped for w x h (under the game's logo).
local function setArt(tex, inst, w, h, fw)
    local PlanUI = ns.RaidPlanUI
    if not (inst and PlanUI and PlanUI.RaidArt) then
        tex:Hide()
        return false
    end
    local file, l, r, t, b = PlanUI:RaidArt(inst, w, h, fw)
    if t < ART_TOP then t, b = ART_TOP, b + ART_TOP - t end
    tex:SetTexture(file)
    tex:SetTexCoord(l, r, t, b)
    tex:Show()
    return true
end

-- The same crop inside text (a menu entry): a small thumbnail.
local function artText(inst, w, h)
    local PlanUI = ns.RaidPlanUI
    if not (inst and PlanUI and PlanUI.RaidArt) then return "" end
    local file, l, r, t, b = PlanUI:RaidArt(inst, w, h, 0.5)
    if t < ART_TOP then t, b = ART_TOP, b + ART_TOP - t end
    local function px(v) return floor(v * 1024 + 0.5) end
    return ("|T%s:%d:%d:0:0:1024:1024:%d:%d:%d:%d|t"):format(tostring(file), h, w, px(l), px(r), px(t), px(b))
end

---------------------------------------------------------------------------
-- Data: the list's rows, the picked player
---------------------------------------------------------------------------

-- The class (and spec) the book knows for a player: a guest entry, their notes, the spec memory, the guild roster.
local function classOf(key, e)
    if e and e.c then return e.c, e.sp end
    local c, sp = GB():GetSpec(key)
    if c then return c, sp end
    local G = ns.Guild
    return G and G.GetClass and G:GetClass(key) or nil, nil
end

local function blacklistByDate()
    local out = RP():GetBlacklist()
    tsort(out, function(a, b)
        local x, y = tonumber(a.at) or 0, tonumber(b.at) or 0
        if x ~= y then return x > y end
        return a.key < b.key
    end)
    return out
end

-- A name typed in the search box that could be a character: "Name" or "Name-Realm" (no digits, spaces, symbols).
local function typedKey(text)
    text = ns.Util.Trim(text or "")
    local base = text:match("^([^%-]+)")
    if not base or #base < 2 or base:find("[%s%d%p]") then return nil end
    -- (1.3.3: in the game's case: the guest book's own players first, then the guild's, else capitalized)
    local known = {}
    for _, e in ipairs(GB() and GB().GetEntries and GB():GetEntries() or {}) do
        if type(e) == "table" and e.key then known[#known + 1] = e.key end
    end
    local key = ns.Util.TypedPlayerKey(text, known)
    if not key or ns.Util.IsMe(key) then return nil end
    return key
end

local function filterRows(filter)
    local out = {}
    if filter == "black" then
        for _, bl in ipairs(blacklistByDate()) do
            out[#out + 1] = { key = bl.key, e = GB():GetEntry(bl.key), bl = bl }
        end
    else
        for _, e in ipairs(GB():GetEntries()) do
            if filter ~= "recruits" or e.recruit then out[#out + 1] = { key = e.key, e = e, bl = e.blacklist } end
        end
    end
    return out
end

-- The rows the list shows: the filter's players matching the search, then (a name nobody matches exactly) the row
-- that adds it. Also returns the empty list's line.
local function buildRows()
    local q = ns.Util.Trim(state.search or ""):lower()
    local out, exact = {}, false
    for _, r in ipairs(filterRows(state.filter)) do
        local name = shortName(r.key):lower()
        if q == "" or name:find(q, 1, true) then
            out[#out + 1] = r
            if name == q then exact = true end
        end
    end
    local empty
    if q ~= "" and not exact then
        local key = typedKey(state.search)
        if key and state.filter == "black" then
            if not RP():IsBlacklisted(key) then out[#out + 1] = { key = key, add = "black" } end
        elseif key and inGuild(key) then
            empty = shortName(key) .. " is in the guild."
        elseif key and not GB():GetEntry(key) then
            out[#out + 1] = { key = key, add = "add" }
        end
    end
    if #out == 0 and not empty then
        if q ~= "" then
            empty = "Nobody by that name."
        elseif state.filter == "recruits" then
            empty = "No recruits yet. Mark a guest as a recruit on their page."
        elseif state.filter == "black" then
            empty = "Nobody is blacklisted."
        else
            empty = "Nobody yet. Players from outside the guild who raid with you show up here."
        end
    end
    return out, empty
end

local function isPicked(d)
    return d.key == state.sel and d.add == state.selKind
end

-- The picked player: kind = "guest" | "black" (on the blacklist) | "fresh" (a name typed in) | "draftBlack" (a name
-- typed in on the Blacklist filter), key, their guest book entry (or nil), their blacklist entry (or nil).
local function picked()
    local key = state.sel
    if not key then return nil end
    if state.selKind == "add" then return "fresh", key end
    if state.selKind == "black" then return "draftBlack", key end
    local e = GB():GetEntry(key)
    local bl = RP():GetBlacklistEntry(key)
    if bl then return "black", key, e, bl end
    if e then return "guest", key, e end
    return nil
end

-- The raids of the next two weeks I may add guests to (locked ones too: they are listed for the roster managers).
local function upcomingRaids()
    local R = RP()
    local out = {}
    if not (R and R.GetRaids and isManager()) then return out end
    local now = GetServerTime()
    for _, v in ipairs(R:GetRaids(now - 6 * 3600, now + ADD_AHEAD)) do
        if not v.cancelled and R:CanManageRoster(v) then out[#out + 1] = v end
    end
    return out
end

local function hasSeat(occId, key)
    local v = RP():GetRaid(occId)
    return (v and type(v.gu) == "table" and v.gu[key]) and true or false
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Adds the player as a guest of a planned raid with the class / spec the guest book knows (or the class picked in
-- the menu, which the book then keeps).
function GuestUI:AddToRaid(key, occId, classFile)
    local e = GB():GetEntry(key)
    local c, sp = GB():GetSpec(key)
    if e and e.c and c ~= e.c then c, sp = e.c, e.sp end   -- (the class last seen in a raid wins)
    if classFile and classFile ~= c then
        c, sp = classFile, nil
        GB():SetNote(key, nil, nil, classFile)
    end
    local ok, err = RP():AddGuest(occId, key, c, sp)
    if not ok then
        Print("%s", tostring(err))
        return false
    end
    local v = RP():GetRaid(occId)
    Print("%s is a guest of %s.", shortName(key), v and RP():GetRaidName(v) or "the raid")
    return true
end

local function raidLabel(v)
    local R = RP()
    local inst = R.GetRaidInstances and R:GetRaidInstances(v)[1] or v.i
    return artText(inst, 28, 15) .. "  " .. date("%a %d %b %H:%M", v.t) .. "   " .. R:GetRaidName(v)
end

-- The raids menu (Add to a raid): a check where they have a seat (clicking takes it back). A player whose class the
-- book doesn't know: their class first, then the raid.
function GuestUI:BuildRaidMenu(root, key, e)
    local raids = upcomingRaids()
    if #raids == 0 then
        root:CreateTitle("No raids in the next two weeks")
        return
    end
    local c = classOf(key, e)
    if not c then
        root:CreateTitle("Their class")
        for _, cls in ipairs(ns.CLASSES or {}) do
            local sub = root:CreateButton((ns.CLASS_NAMES and ns.CLASS_NAMES[cls]) or cls)
            for _, v in ipairs(raids) do
                local id = v.id
                sub:CreateButton(raidLabel(v), function() GuestUI:AddToRaid(key, id, cls) end)
            end
        end
        return
    end
    for _, v in ipairs(raids) do
        local id = v.id
        root:CreateCheckbox(raidLabel(v), function() return hasSeat(id, key) end, function()
            if hasSeat(id, key) then
                local ok, err = RP():RemoveGuest(id, key)
                if not ok then Print("%s", tostring(err)) end
            else
                GuestUI:AddToRaid(key, id)
            end
        end)
    end
end

local function toggleRecruit(key, e)
    local ok, err = GB():SetNote(key, nil, not (e and e.recruit))
    if not ok then Print("%s", tostring(err)) end
end

local function clearNote(key)
    local ok, err = GB():SetNote(key, false)
    if not ok then Print("%s", tostring(err)) end
end

-- Takes a player out of the book (after a yes): their note, mark and class go; they come back if they raid with us
-- again.
function GuestUI:ConfirmRemove(key)
    local function remove()
        local ok, err = GB():Remove(key)
        if not ok then Print("%s", tostring(err)) end
    end
    local PlanUI = ns.RaidPlanUI
    if not (PlanUI and PlanUI.Confirm) then return remove() end
    PlanUI:Confirm(("Remove %s from the guest book?\n\nTheir note and Recruit mark are deleted for every organizer. "
        .. "They come back if they raid with you again."):format(shortName(key)), remove)
end

-- The class submenus (More > Class): the class, then its spec.
local function classMenu(root, key, e)
    local cur, curSp = classOf(key, e)
    local sub = root:CreateButton("Class")
    for _, cls in ipairs(ns.CLASSES or {}) do
        local name = (ns.CLASS_NAMES and ns.CLASS_NAMES[cls]) or cls
        local cs = sub:CreateButton(cls == cur and ("|cffffd100" .. name .. "|r") or name)
        cs:CreateRadio("Any spec", function() return cls == cur and curSp == nil end, function()
            local ok, err = GB():SetNote(key, nil, nil, cls)
            if not ok then Print("%s", tostring(err)) end
        end)
        for i, spec in ipairs(ns.SPECS and ns.SPECS[cls] or {}) do
            cs:CreateRadio(spec.label, function() return cls == cur and curSp == i end, function()
                local ok, err = GB():SetNote(key, nil, nil, cls, i)
                if not ok then Print("%s", tostring(err)) end
            end)
        end
    end
end

-- A row's right-click menu: the quick actions, icon + one word. e = a guest book entry (or a row of the list).
function GuestUI:OpenEntryMenu(owner, e)
    if type(e) ~= "table" or type(e.key) ~= "string" then return end
    local key = e.key
    local entry = (e.e ~= nil or e.bl ~= nil) and e.e or (e.raids and e) or GB():GetEntry(key)
    local bl = RP():GetBlacklistEntry(key)
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(shortName(key))
        if not inGuild(key) then
            if not bl and #upcomingRaids() > 0 then
                local sub = root:CreateButton(iconText(UI().ICON.invite or 19) .. "  Add to a raid")
                GuestUI:BuildRaidMenu(sub, key, entry)
            end
            root:CreateButton(starText(14) .. "  " .. ((entry and entry.recruit) and "Not a recruit" or "Recruit"),
                function() toggleRecruit(key, entry) end)
            root:CreateButton(iconText(16) .. "  Note", function() GuestUI:EditNote(key) end)
            if entry and entry.note then
                root:CreateButton(iconText(UI().ICON.trash) .. "  Clear note", function() clearNote(key) end)
            end
        end
        root:CreateButton(iconText(UI().ICON.whisper) .. "  Whisper", function() whisper(key) end)
        root:CreateDivider()
        if entry and not inGuild(key) then
            root:CreateButton(iconText(UI().ICON.trash) .. "  Remove", function() GuestUI:ConfirmRemove(key) end)
        end
        if bl then
            root:CreateButton(blockText(14) .. "  Take off the blacklist", function() GuestUI:Unblacklist(bl.key) end)
        else
            root:CreateButton(blockText(14) .. "  |cffff8d80Blacklist|r", function() GuestUI:OpenBlacklist(key) end)
        end
    end)
end

-- The banner's More menu: the occasional actions.
local function moreMenu(owner)
    local kind, key, e, bl = picked()
    if not kind then return end
    UI():ContextMenu(owner, function(root)
        if kind == "guest" then
            classMenu(root, key, e)
            root:CreateButton(iconText(16) .. "  Note", function() GuestUI:EditNote(key) end)
            if e and e.note then
                root:CreateButton(iconText(UI().ICON.trash) .. "  Clear note", function() clearNote(key) end)
            end
            root:CreateDivider()
            root:CreateButton(iconText(UI().ICON.trash) .. "  Remove", function() GuestUI:ConfirmRemove(key) end)
            root:CreateButton(blockText(14) .. "  |cffff8d80Blacklist|r", function() GuestUI:OpenBlacklist(key) end)
        elseif kind == "black" then
            root:CreateButton(iconText(16) .. "  Reason", function() GuestUI:EditNote(key) end)
            if e then
                classMenu(root, key, e)
                root:CreateDivider()
                root:CreateButton(iconText(UI().ICON.trash) .. "  Remove from the book",
                    function() GuestUI:ConfirmRemove(key) end)
            end
        end
    end)
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

local function rowLine(d)
    local e, bl = d.e, d.bl
    if d.add == "add" then return { "Not in the guest book yet" } end
    if d.add == "black" then return { "Not on the blacklist yet" } end
    if state.filter == "black" and bl then
        local when = bl.at and date("%d %b", bl.at) or nil
        if not e and inGuild(d.key) then
            local n = 1 + #(ns.Guild and ns.Guild.GetLinkedCharacters and ns.Guild:GetLinkedCharacters(d.key) or {})
            return { n > 1 and ("Guild member · all " .. n .. " characters") or "Guild member" }
        end
        local by = bl.by and shortName(bl.by)
        local full = "Guest" .. (when and (" · " .. when) or "") .. (by and (", " .. by) or "")
        return { full, "Guest" .. (when and (" · " .. when) or "") }
    end
    if bl then
        return { "|cffff8a7aBlacklisted" .. (bl.at and (" " .. date("%d %b", bl.at)) or "") .. "|r" }
    end
    if e and e.next then
        local v = RP():GetRaid(e.next.id)
        local short = v and ns.RaidComp and ns.RaidComp.ShortInstanceNames
            and ns.RaidComp:ShortInstanceNames(RP():GetRaidInstances(v)) or e.next.name
        local day = date("%a %d %b", e.next.t)
        return { "|cff66b8ffGuest " .. day .. " · " .. tostring(short) .. "|r", "|cff66b8ffGuest " .. day .. "|r" }
    end
    if e and e.raids > 0 then
        local raids = plural(e.raids, "raid")
        if e.noShows > 0 then return { raids .. " · |cffff8a7a" .. plural(e.noShows, "no-show") .. "|r" } end
        return { raids .. " · last " .. date("%a %d %b", e.last), raids .. " · last " .. date("%d %b", e.last) }
    end
    if e and e.noShows > 0 then return { "|cffff8a7a" .. plural(e.noShows, "no-show") .. "|r" } end
    return { "Not raided yet" }
end

local function rowMarks(d)
    local out = {}
    if d.add then return out end
    local e = d.e
    if e and e.recruit then out[#out + 1] = "star" end
    if e and e.note then out[#out + 1] = "note" end
    if d.bl and state.filter ~= "black" then out[#out + 1] = "block" end
    return out
end

local function paintRow(row)
    local d = row.__cdlData
    local on = d and isPicked(d)
    row.sel:SetShown(on and true or false)
    row.bar:SetShown(on and true or false)
    if d and d.add == "black" then
        row.sel:SetColorTexture(0.89, 0.36, 0.31, 0.10)
        row.bar:SetColorTexture(0.89, 0.36, 0.31, 1)
    else
        row.sel:SetColorTexture(1, 0.82, 0, 0.10)
        row.bar:SetColorTexture(1, 0.82, 0, 1)
    end
end

local function initRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.bar = row:CreateTexture(nil, "BORDER")
        row.bar:SetPoint("TOPLEFT")
        row.bar:SetPoint("BOTTOMLEFT")
        row.bar:SetWidth(3)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.05)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(24, 24)
        row.icon:SetPoint("LEFT", 10, 0)
        -- a player whose class the book doesn't know; the add rows' circle
        row.disc = row:CreateTexture(nil, "ARTWORK", nil, -1)
        row.disc:SetTexture(MEDIA .. "disc")
        row.disc:SetSize(24, 24)
        row.disc:SetPoint("CENTER", row.icon)
        row.ring = row:CreateTexture(nil, "ARTWORK", nil, 1)
        row.ring:SetTexture(MEDIA .. "ring")
        row.ring:SetSize(24, 24)
        row.ring:SetPoint("CENTER", row.icon)
        row.glyph = row:CreateTexture(nil, "ARTWORK", nil, 2)
        row.glyph:SetPoint("CENTER", row.icon)
        row.q = newText(row, "GameFontDisable", 13)
        row.q:SetPoint("CENTER", row.icon, "CENTER", 0, 0)
        row.q:SetText("?")
        row.name = newText(row, "GameFontHighlight", 12)
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 9, 1)
        row.line = newText(row, "GameFontHighlightSmall", 10)
        row.line:SetTextColor(0.62, 0.62, 0.62)
        row.line:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
        row.marks = {}
        for i = 1, 3 do
            local t = row:CreateTexture(nil, "OVERLAY")
            t:SetSize(13, 13)
            t:SetPoint("RIGHT", -8 - (i - 1) * 18, 0)
            row.marks[i] = t
        end
        row:SetScript("OnClick", function(self, button)
            local data = self.__cdlData
            if not data then return end
            if button == "RightButton" then
                if not data.add then GuestUI:OpenEntryMenu(self, data) end
                return
            end
            GuestUI:Select(data.key, data.add, data.add ~= nil)
        end)
    end
    local add = d.add
    local c = not add and classOf(d.key, d.e) or nil
    row.icon:SetShown(c ~= nil)
    if c then UI():ClassIcon(row.icon, c) end
    row.disc:SetShown(c == nil)
    row.ring:SetShown(add ~= nil)
    row.glyph:SetShown(add ~= nil)
    row.q:SetShown(c == nil and add == nil)
    if add == "black" then
        row.disc:SetVertexColor(0.89, 0.36, 0.31, 0.14)
        row.ring:SetVertexColor(0.89, 0.36, 0.31, 0.75)
        row.glyph:SetTexture(BLOCK_TEX)
        row.glyph:SetTexCoord(0, 1, 0, 1)
        row.glyph:SetVertexColor(1, 1, 1)
        row.glyph:SetSize(16, 16)
    elseif add == "add" then
        row.disc:SetVertexColor(1, 0.82, 0, 0.12)
        row.ring:SetVertexColor(1, 0.82, 0, 0.7)
        atlasTex(row.glyph, UI().ICON.plus, 1, 0.82, 0)
        row.glyph:SetSize(12, 12)
    else
        row.disc:SetVertexColor(0.16, 0.16, 0.19, 1)
    end
    if add == "add" then
        row.name:SetText("|cffffd100Add " .. shortName(d.key) .. "|r")
    elseif add == "black" then
        row.name:SetText("|cffff9a8aBlacklist " .. shortName(d.key) .. "|r")
    else
        row.name:SetText(UI():ColoredName(d.key, c))
    end
    local marks = rowMarks(d)
    for i, t in ipairs(row.marks) do
        local m = marks[i]
        t:SetShown(m ~= nil)
        if m == "star" then
            starTex(t, true)
        elseif m == "note" then
            t:SetDesaturated(false)
            atlasTex(t, UI().ICON.notes, 0.6, 0.6, 0.63)
        elseif m == "block" then
            t:SetDesaturated(false)
            t:SetTexture(BLOCK_TEX)
            t:SetTexCoord(0, 1, 0, 1)
            t:SetVertexColor(1, 1, 1)
        end
    end
    fitText(row.line, rowLine(d), LIST_W - 43 - 8 - #marks * 18 - 4)
    paintRow(row)
end

---------------------------------------------------------------------------
-- The profile
---------------------------------------------------------------------------

local function newButtonIcon(b, size)
    b.glyph = b:CreateTexture(nil, "ARTWORK")
    b.glyph:SetSize(size or 13, size or 13)
    return b
end

-- A sleek button with an icon in front of its text, sized to fit.
local function iconButton(parent, text, kind, onClick)
    local b = UI():CreateSleekButton(parent, text, 80, 24, onClick, kind)
    newButtonIcon(b)
    local fs = b:GetFontString()
    function b:Fit()
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", 8, 0)
        self.glyph:ClearAllPoints()
        self.glyph:SetPoint("RIGHT", fs, "LEFT", -6, 0)
        self:SetWidth(floor((fs:GetStringWidth() or 40) + 13 + 6 + 26 + 0.5))
    end
    b:SetScript("OnMouseDown", nil)
    b:SetScript("OnMouseUp", nil)
    return b
end

-- The gold "Add to a raid" with its chevron: drops the raids menu.
local function raidButton(parent)
    local b = UI():CreateSleekButton(parent, "Add to a raid", 120, 24, function(self)
        local _, key, e = picked()
        if key then UI():ContextMenu(self, function(root) GuestUI:BuildRaidMenu(root, key, e) end) end
    end, "primary")
    b.cdlDrop = true
    local fs = b:GetFontString()
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", -7, 0)
    b.chevron = b:CreateTexture(nil, "ARTWORK")
    b.chevron:SetSize(11, 11)
    b.chevron:SetPoint("LEFT", fs, "RIGHT", 6, -1)
    atlasTex(b.chevron, UI().ICON.chevron, 1, 0.95, 0.8)
    b:SetWidth(floor((fs:GetStringWidth() or 70) + 17 + 26 + 0.5))
    b:SetScript("OnMouseDown", nil)
    b:SetScript("OnMouseUp", nil)
    function b:OnMenuShown(open) UI():SetChevronUp(self.chevron, open) end
    return b
end

local function createBanner(dc)
    local b = CreateFrame("Frame", nil, dc)
    b:SetPoint("TOPLEFT")
    b:SetSize(DETAIL_W, BAN_H)
    b.art = b:CreateTexture(nil, "BACKGROUND", nil, 0)
    b.art:SetPoint("TOPLEFT", 1, -1)
    b.art:SetPoint("BOTTOMRIGHT", -1, 1)
    -- no art (a player who hasn't raided with us): a dark card with a little gold light from the top left
    b.plain = b:CreateTexture(nil, "BACKGROUND", nil, 0)
    b.plain:SetPoint("TOPLEFT", 1, -1)
    b.plain:SetPoint("BOTTOMRIGHT", -1, 1)
    b.plain:SetColorTexture(0.105, 0.105, 0.125, 1)
    b.glow = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.glow:SetPoint("TOPLEFT", 1, -1)
    b.glow:SetPoint("BOTTOMLEFT", 1, 1)
    b.glow:SetWidth(300)
    gradient(b.glow, "HORIZONTAL", 1, 0.82, 0, 0.06, 0)
    b.shadeB = b:CreateTexture(nil, "BACKGROUND", nil, 2)
    b.shadeB:SetAllPoints(b.art)
    gradient(b.shadeB, "VERTICAL", 0.035, 0.035, 0.043, 0.9, 0.12)
    b.shadeL = b:CreateTexture(nil, "BACKGROUND", nil, 3)
    b.shadeL:SetPoint("TOPLEFT", b.art)
    b.shadeL:SetPoint("BOTTOMLEFT", b.art)
    b.shadeL:SetWidth(330)
    gradient(b.shadeL, "HORIZONTAL", 0.035, 0.035, 0.043, 0.82, 0)
    -- a blacklisted player: the art greyed under a red veil
    b.red = b:CreateTexture(nil, "BACKGROUND", nil, 4)
    b.red:SetAllPoints(b.art)
    gradient(b.red, "HORIZONTAL", 0.42, 0.05, 0.03, 0.18, 0.42)
    UI():AddEdges(b, "BORDER")

    b.disc = b:CreateTexture(nil, "ARTWORK", nil, 0)
    b.disc:SetTexture(MEDIA .. "disc")
    b.disc:SetVertexColor(0, 0, 0, 0.85)
    b.disc:SetSize(48, 48)
    b.disc:SetPoint("TOPLEFT", 10, -10)
    b.icon = b:CreateTexture(nil, "ARTWORK", nil, 1)
    b.icon:SetSize(44, 44)
    b.icon:SetPoint("CENTER", b.disc)
    b.q = newText(b, "GameFontDisableLarge", 20)
    b.q:SetPoint("CENTER", b.disc, "CENTER", 0, 0)
    b.q:SetText("?")
    b.name = newText(b, "GameFontHighlightLarge", 19)
    b.name:SetPoint("TOPLEFT", b.disc, "TOPRIGHT", 10, -4)
    -- (the red pill beside a blacklisted player's name)
    b.pill = CreateFrame("Frame", nil, b)
    b.pill:SetSize(70, 16)
    b.pill:SetPoint("LEFT", b.name, "RIGHT", 9, 1)
    UI():AddPillShape(b.pill, 16)
    b.pill:SetPillColors({ 0.27, 0.08, 0.07, 0.95 }, { 0.89, 0.36, 0.31, 0.75 })
    b.pill.fs = newText(b.pill, "GameFontHighlightSmall", 10)
    b.pill.fs:SetPoint("CENTER", 0, 0)
    b.pill.fs:SetTextColor(1, 0.69, 0.64)
    b.pill.fs:SetText("Blacklisted")
    b.pill:SetWidth(floor((b.pill.fs:GetStringWidth() or 50) + 16 + 0.5))
    b.sub = newText(b, "GameFontHighlightSmall", 11)
    b.sub:SetTextColor(0.82, 0.82, 0.82)
    b.sub:SetPoint("TOPLEFT", b.name, "BOTTOMLEFT", 0, -4)

    b.moreBtn = UI():CreateTipIconButton(b, 22, UI().ICON.more, "More", "Class, the note, remove from the book, the blacklist.",
        function(self) moreMenu(self) end)
    b.moreBtn:SetPoint("TOPRIGHT", -12, -12)
    b.whisperBtn = UI():CreateTipIconButton(b, 22, UI().ICON.whisper, "Whisper", nil, function()
        if state.sel then whisper(state.sel) end
    end)

    -- the numbers, bottom left: a big number over a small word
    b.stats = {}
    for i = 1, 4 do
        local s = CreateFrame("Frame", nil, b)
        s:SetSize(40, 34)
        s.num = newText(s, "GameFontHighlightLarge", 18)
        s.num:SetPoint("TOPLEFT", 0, 0)
        s.label = newText(s, "GameFontHighlightSmall", 10)
        s.label:SetTextColor(0.66, 0.66, 0.68)
        s.label:SetPoint("TOPLEFT", s.num, "BOTTOMLEFT", 0, -3)
        b.stats[i] = s
    end

    -- the actions, bottom right (one gold per context)
    b.raidBtn = raidButton(b)
    b.raidBtn:SetPoint("BOTTOMRIGHT", -12, 12)
    b.recruitBtn = iconButton(b, "Recruit", "secondary", function()
        local kind, key, e = picked()
        if kind == "fresh" then
            state.draft.recruit = not state.draft.recruit
            GuestUI:Refresh()
        elseif key then
            toggleRecruit(key, e)
        end
    end)
    b.recruitBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Recruit")
        GameTooltip:AddLine("A player you'd like in the guild: the Recruits filter lists them, and the raid leaders "
            .. "and officers see the star.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b.recruitBtn:HookScript("OnLeave", hideTooltip)
    b.addBtn = UI():CreateSleekButton(b, "Add", 56, 24, function() GuestUI:SaveFresh() end, "primary")
    b.unblackBtn = UI():CreateSleekButton(b, "Take off the blacklist", 150, 24, function()
        local _, _, _, bl = picked()
        if bl then GuestUI:Unblacklist(bl.key) end
    end)
    b.unblackBtn:SetWidth(floor((b.unblackBtn:GetFontString():GetStringWidth() or 120) + 28 + 0.5))
    b.blackBtn = iconButton(b, "Blacklist", "danger", function() GuestUI:AddBlacklist() end)
    b.blackBtn.glyph:SetTexture(BLOCK_TEX)
    b.blackBtn:Fit()
    return b
end

-- The note (or the reason) under the banner: the text, who wrote it and when, a pencil; clicked, it becomes a field.
local function createNote(dc)
    local n = CreateFrame("Button", nil, dc)
    n:SetPoint("TOPLEFT", 0, -(BAN_H + GAP))
    n:SetSize(DETAIL_W, 34)
    n.bg = n:CreateTexture(nil, "BACKGROUND")
    n.bg:SetAllPoints()
    n.bar = n:CreateTexture(nil, "BORDER")
    n.bar:SetPoint("TOPLEFT")
    n.bar:SetPoint("BOTTOMLEFT")
    n.bar:SetWidth(2)
    local hl = n:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.03)
    n.pencil = n:CreateTexture(nil, "ARTWORK")
    n.pencil:SetSize(13, 13)
    atlasTex(n.pencil, 16, 0.62, 0.62, 0.66)
    n.text = newText(n, "GameFontHighlight", 12)
    n.text:SetWordWrap(true)
    n.text:SetJustifyV("TOP")
    n.by = newText(n, "GameFontHighlightSmall", 10)
    n.by:SetTextColor(0.55, 0.55, 0.58)
    n.by:SetJustifyH("RIGHT")
    n.alts = newText(n, "GameFontHighlightSmall", 10)
    n.alts:SetTextColor(0.62, 0.62, 0.62)
    n:SetScript("OnClick", function() GuestUI:StartEdit() end)
    -- the field it turns into (Enter or a click away saves, Escape restores)
    n.box = UI():CreateSleekEditBox(dc, DETAIL_W, 26, "GameFontHighlight")
    n.box:SetPoint("TOPLEFT", 0, -(BAN_H + GAP))
    n.box:Hide()
    n.box:SetScript("OnEnterPressed", function() GuestUI:FinishEdit(true) end)
    n.box:SetScript("OnEscapePressed", function() GuestUI:FinishEdit(false) end)
    n.box:HookScript("OnEditFocusLost", function() if state.editing then GuestUI:FinishEdit(true) end end)
    return n
end

-- A section title (gold) with a word on the right and a thin rule under it.
local function newSection(parent, title)
    local s = CreateFrame("Frame", nil, parent)
    s:SetHeight(SECT_H)
    s.title = newText(s, "GameFontNormal", 12)
    s.title:SetPoint("TOPLEFT", 2, -6)
    s.title:SetText(title)
    s.right = newText(s, "GameFontHighlightSmall", 10)
    s.right:SetTextColor(0.62, 0.62, 0.62)
    s.right:SetJustifyH("RIGHT")
    s.right:SetPoint("TOPRIGHT", -2, -7)
    s.rule = s:CreateTexture(nil, "BORDER")
    s.rule:SetPoint("BOTTOMLEFT", 0, 3)
    s.rule:SetPoint("BOTTOMRIGHT", 0, 3)
    s.rule:SetHeight(1)
    s.rule:SetColorTexture(1, 1, 1, 0.08)
    return s
end

local function newRaidRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(HIST_ROW_H)
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.04)
    r.hl = hl
    r.thumb = r:CreateTexture(nil, "ARTWORK")
    r.thumb:SetSize(48, 26)
    r.thumb:SetPoint("LEFT", 2, 0)
    r.title = newText(r, "GameFontHighlight", 12)
    r.title:SetPoint("TOPLEFT", r.thumb, "TOPRIGHT", 10, 0)
    r.line = newText(r, "GameFontHighlightSmall", 10)
    r.line:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -2)
    r.kills = newText(r, "GameFontHighlightSmall", 11)
    r.kills:SetJustifyH("RIGHT")
    r.kills:SetPoint("TOPRIGHT", -2, -6)
    r.barBg = r:CreateTexture(nil, "ARTWORK")
    r.barBg:SetSize(36, 3)
    r.barBg:SetPoint("TOPRIGHT", r.kills, "BOTTOMRIGHT", 0, -4)
    r.barBg:SetColorTexture(1, 1, 1, 0.09)
    r.bar = r:CreateTexture(nil, "OVERLAY")
    r.bar:SetHeight(3)
    r.bar:SetPoint("LEFT", r.barBg, "LEFT")
    gradient(r.bar, "HORIZONTAL", 0.24, 0.81, 0.36, 1, 1)
    r.pill = UI():CreateTagPill(r, 16)
    r.pill:SetPoint("RIGHT", -2, 0)
    if r.pill.SetBase then r.pill:SetBase(0.035, 0.035, 0.043) end
    r:SetScript("OnClick", function(self)
        local z = self.cdlZone
        if not z then return end
        if z.next then
            ns.RaidsUI:SetView("upcoming")
            ns.RaidPlanUI:SelectRaid(z.id)
        elseif z.id and seesRaidLog() then
            ns.RaidsUI:Select(z.id)
        end
    end)
    r:SetScript("OnEnter", function(self)
        local z = self.cdlZone
        if not z then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(z.title)
        GameTooltip:AddLine(date("%A %d %B, %H:%M", z.at), 0.8, 0.8, 0.8)
        if z.next then
            GameTooltip:AddLine("A guest seat on this raid. Click to open it.", 0.4, 0.72, 1, true)
        elseif z.noShow then
            GameTooltip:AddLine("Signed up and didn't come.", 1, 0.55, 0.48)
        elseif z.bench then
            GameTooltip:AddLine("On the bench.", 0.8, 0.8, 0.8)
        elseif (z.bosses or 0) > 0 then
            GameTooltip:AddLine(("There for %d of the %d boss kills."):format(z.kills or 0, z.bosses), 1, 1, 1)
        end
        if not z.next and seesRaidLog() then GameTooltip:AddLine("Click to open it in the Raid log.", 0.5, 0.5, 0.5) end
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", hideTooltip)
    return r
end

local function newItemRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(HIST_ROW_H)
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.04)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(26, 26)
    r.icon:SetPoint("LEFT", 2, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.title = newText(r, "GameFontHighlight", 12)
    r.title:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 10, 0)
    r.line = newText(r, "GameFontHighlightSmall", 10)
    r.line:SetTextColor(0.62, 0.62, 0.62)
    r.line:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -2)
    r:SetScript("OnEnter", function(self) if self.cdlItem then UI():SetItemTooltip(self, self.cdlItem) end end)
    r:SetScript("OnLeave", hideTooltip)
    r:SetScript("OnClick", function(self) if self.cdlItem then UI():HandleModifiedItemClick(self.cdlItem) end end)
    return r
end

local function createHistory(dc)
    local h = CreateFrame("Frame", nil, dc)
    h:SetPoint("TOPLEFT", 0, -(BAN_H + GAP + 34 + GAP))
    h:SetSize(DETAIL_W, 300)
    h.raidCol = CreateFrame("Frame", nil, h)
    h.raidCol:SetPoint("TOPLEFT")
    h.raidSect = newSection(h.raidCol, "Raids")
    h.raidSect:SetPoint("TOPLEFT")
    h.raidSect:SetPoint("TOPRIGHT")
    h.itemCol = CreateFrame("Frame", nil, h)
    h.itemSect = newSection(h.itemCol, "Items")
    h.itemSect:SetPoint("TOPLEFT")
    h.itemSect:SetPoint("TOPRIGHT")
    h.raidRows, h.itemRows = {}, {}
    return h
end

-- The fresh profile (a name typed in): the note (or, on the Blacklist filter, the reason), the class and spec.
local function createForm(dc)
    local f = CreateFrame("Frame", nil, dc)
    f:SetPoint("TOPLEFT", 0, -(BAN_H + 12))
    f:SetSize(DETAIL_W, 120)
    local function label(text, y)
        local fs = newText(f, "GameFontHighlightSmall", 11)
        fs:SetTextColor(0.62, 0.62, 0.62)
        fs:SetPoint("TOPLEFT", 0, y)
        fs:SetText(text)
        return fs
    end
    f.noteLabel = label("Note", -7)
    f.noteBox = UI():CreateSleekEditBox(f, DETAIL_W - FIELD_X, 26, "GameFontHighlight")
    f.noteBox:SetPoint("TOPLEFT", FIELD_X, 0)
    f.noteBox:SetMaxLetters(60)
    f.noteBox:SetScript("OnEnterPressed", function() GuestUI:SaveFresh() end)
    f.noteBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    UI():SetEditPlaceholder(f.noteBox, "A note the raid leaders and officers see")
    f.reasonBox = UI():CreateSleekEditBox(f, DETAIL_W - FIELD_X, 26, "GameFontHighlight")
    f.reasonBox:SetPoint("TOPLEFT", FIELD_X, 0)
    f.reasonBox:SetMaxLetters(80)
    f.reasonBox:SetScript("OnEnterPressed", function() GuestUI:AddBlacklist() end)
    f.reasonBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    UI():SetEditPlaceholder(f.reasonBox, "Why (only the raid leaders and officers see it)")
    f.classLabel = label("Class", -43)
    f.classBtns = {}
    for i, cls in ipairs(ns.CLASSES or {}) do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(22, 22)
        b:SetPoint("TOPLEFT", FIELD_X + (i - 1) * 29, -36)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        UI():ClassIcon(b.icon, cls)
        b.ring = b:CreateTexture(nil, "OVERLAY")
        b.ring:SetTexture(MEDIA .. "ring")
        b.ring:SetSize(28, 28)
        b.ring:SetPoint("CENTER")
        b.ring:SetVertexColor(1, 0.82, 0, 0.95)
        b.cls = cls
        b:SetScript("OnClick", function(self)
            local d = state.draft
            if d.c == self.cls then d.c, d.sp = nil, nil else d.c, d.sp = self.cls, nil end
            GuestUI:Refresh()
        end)
        b:SetScript("OnEnter", function(self)
            self.icon:SetDesaturated(false)
            self.icon:SetAlpha(1)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine((ns.CLASS_NAMES and ns.CLASS_NAMES[self.cls]) or self.cls)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function(self)
            hideTooltip()
            local on = state.draft.c == self.cls
            self.icon:SetDesaturated(not on)
            self.icon:SetAlpha(on and 1 or 0.55)
        end)
        f.classBtns[i] = b
    end
    f.specDD = UI():CreateLinkDropdown(f, {
        font = "GameFontHighlight", size = 12,
        options = function()
            local out = { { text = "Any spec", value = 0 } }
            for i, spec in ipairs(state.draft.c and ns.SPECS and ns.SPECS[state.draft.c] or {}) do
                out[#out + 1] = { text = spec.label, value = i }
            end
            return out
        end,
        selected = function() return state.draft.sp or 0 end,
        select = function(v)
            state.draft.sp = (v ~= 0) and v or nil
            GuestUI:Refresh()
        end,
    })
    f.specDD:SetPoint("LEFT", f.classBtns[#f.classBtns] or f, "RIGHT", 14, 0)
    f.err = newText(f, "GameFontRedSmall", 11)
    f.err:SetPoint("TOPLEFT", FIELD_X, -70)
    return f
end

---------------------------------------------------------------------------
-- The view
---------------------------------------------------------------------------

local FILTERS = { { key = "all", label = "Everyone" }, { key = "recruits", label = "Recruits" },
                  { key = "black", label = "Blacklist" } }

function GuestUI:CreateView(parent)
    if view then return view end
    local v = CreateFrame("Frame", nil, parent)
    view = v

    -- the players column
    local lc = CreateFrame("Frame", nil, v)
    lc:SetPoint("TOPLEFT", PAD, 0)
    lc:SetPoint("BOTTOMLEFT", PAD, 6)
    lc:SetWidth(LIST_W)
    v.left = lc
    v.search = UI():CreateSearchBox(lc, LIST_W, function(text)
        state.search = text or ""
        GuestUI:Refresh()
    end, "Search or add a player")
    v.search:SetHeight(SEARCH_H)
    v.search:SetPoint("TOPLEFT")
    v.search:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        state.search = self:GetText() or ""
        local rows = buildRows()
        if #rows == 1 then GuestUI:Select(rows[1].key, rows[1].add, rows[1].add ~= nil) end
    end)
    v.tabs = {}
    local prev
    for _, f in ipairs(FILTERS) do
        local key = f.key
        local t = UI():CreateUnderlineTab(lc, f.label, function() GuestUI:SetFilter(key) end, "small")
        if prev then t:SetPoint("LEFT", prev, "RIGHT", 2, 0) else t:SetPoint("TOPLEFT", -4, -TABS_Y) end
        t.cdlLabel = f.label
        v.tabs[key] = t
        prev = t
    end
    v.recruitsTab, v.blackTab, v.bookTab = v.tabs.recruits, v.tabs.black, v.tabs.all
    v.tabRule = lc:CreateTexture(nil, "BORDER")
    v.tabRule:SetPoint("TOPLEFT", 0, -(TABS_Y + 18))
    v.tabRule:SetPoint("TOPRIGHT", 0, -(TABS_Y + 18))
    v.tabRule:SetHeight(1)
    v.tabRule:SetColorTexture(1, 1, 1, 0.1)
    v.list = UI():CreateScrollList(lc, ROW_H, initRow)
    v.list.frame:SetPoint("TOPLEFT", 0, -LIST_Y)
    v.list.frame:SetPoint("BOTTOMLEFT", 0, 0)
    v.list.frame:SetWidth(LIST_W + 20)
    -- (its bar in the gap beside the column)
    v.list.bar:ClearAllPoints()
    v.list.bar:SetPoint("TOPLEFT", v.list.box, "TOPRIGHT", 1, 0)
    v.list.bar:SetPoint("BOTTOMLEFT", v.list.box, "BOTTOMRIGHT", 1, 0)
    v.list.emptyText:ClearAllPoints()
    v.list.emptyText:SetPoint("TOPLEFT", v.list.frame, "TOPLEFT", 10, -8)
    v.list.emptyText:SetWidth(LIST_W - 20)
    v.list.emptyText:SetJustifyH("LEFT")
    v.list.emptyText:SetWordWrap(true)

    -- the profile
    local dc = CreateFrame("Frame", nil, v)
    dc:SetPoint("TOPLEFT", PAD + LIST_W + GAP, 0)
    dc:SetPoint("BOTTOMLEFT", PAD + LIST_W + GAP, 6)
    dc:SetWidth(DETAIL_W)
    v.detail = dc
    v.banner = createBanner(dc)
    v.note = createNote(dc)
    v.history = createHistory(dc)
    v.form = createForm(dc)
    -- (old names, for the pages that open the blacklist with a name)
    v.reasonBox, v.noteBox = v.form.reasonBox, v.form.noteBox
    v:SetScript("OnShow", function() GuestUI:Refresh() end)
    return v
end

local function fillStats(b, e)
    local stats = {}
    if e and (e.raids > 0 or e.noShows > 0) then
        stats[#stats + 1] = { e.raids, e.raids == 1 and "raid" or "raids" }
        stats[#stats + 1] = { e.kills, e.kills == 1 and "boss kill" or "boss kills" }
        if e.noShows > 0 then stats[#stats + 1] = { e.noShows, e.noShows == 1 and "no-show" or "no-shows", true } end
        if seesItems() and e.items > 0 then stats[#stats + 1] = { e.items, e.items == 1 and "item" or "items" } end
    end
    local prev
    for i, s in ipairs(b.stats) do
        local d = stats[i]
        s:SetShown(d ~= nil)
        if d then
            s.num:SetText(tostring(d[1]))
            if d[3] then s.num:SetTextColor(1, 0.54, 0.48) else s.num:SetTextColor(1, 1, 1) end
            s.label:SetText(d[2])
            s:SetWidth(floor(max(s.num:GetStringWidth() or 10, s.label:GetStringWidth() or 10) + 0.5))
            s:ClearAllPoints()
            if prev then s:SetPoint("BOTTOMLEFT", prev, "BOTTOMRIGHT", 20, 0) else s:SetPoint("BOTTOMLEFT", 12, 11) end
            prev = s
        end
    end
end

-- The loading screen behind a player: their last raid with us (one they missed when that is all), else their next.
local function artInst(e)
    if not e then return nil end
    for _, z in ipairs(e.zones or {}) do if not z.noShow and z.inst then return z.inst end end
    for _, z in ipairs(e.zones or {}) do if z.inst then return z.inst end end
    return e.next and e.next.inst or nil
end

local function subText(kind, key, e, c, sp)
    if kind == "draftBlack" or (kind == "black" and not e) then
        if inGuild(key) then
            local alts = {}
            for _, alt in ipairs(ns.Guild and ns.Guild.GetLinkedCharacters and ns.Guild:GetLinkedCharacters(key) or {}) do
                alts[#alts + 1] = shortName(alt)
            end
            if #alts > 0 then
                return { "Guild member · also " .. tconcat(alts, ", "), "Guild member · all " .. (#alts + 1) .. " characters" }
            end
            return { "Guild member" }
        end
        local st = specText(c, sp)
        return { (st ~= "" and (st .. " · ") or "") .. "not in the guild" }
    end
    local st = specText(c, sp)
    local tail
    if kind == "fresh" then
        tail = "not in the guest book yet"
    elseif e and e.raids == 0 and not e.next then
        tail = "no raids with us yet"
    end
    local realm = realmText(key)
    local function join(withRealm)
        local parts = {}
        if st ~= "" then parts[#parts + 1] = st end
        if withRealm and realm then parts[#parts + 1] = realm end
        if tail then parts[#parts + 1] = tail end
        if #parts == 0 then parts[1] = "Class unknown" end
        return tconcat(parts, " · ")
    end
    return { join(true), join(false) }
end

local function fillBanner(kind, key, e, bl)
    local b = view.banner
    local black = kind == "black" or kind == "draftBlack"
    local art = (kind == "guest" or kind == "black") and setArt(b.art, artInst(e), DETAIL_W, BAN_H, 0.98)
    if not art then b.art:Hide() end
    b.art:SetDesaturated(black)
    b.plain:SetShown(not art)
    b.glow:SetShown(not art and not black)
    b.shadeB:SetShown(art and true or false)
    b.shadeL:SetShown(art and true or false)
    b.red:SetShown(black)
    local edge = black and RED_EDGE or EDGE
    UI():SetEdgeColor(b, edge[1], edge[2], edge[3], edge[4])
    local c, sp
    if kind == "fresh" then c, sp = state.draft.c, state.draft.sp else c, sp = classOf(key, e) end
    b.icon:SetShown(c ~= nil)
    if c then UI():ClassIcon(b.icon, c) end
    b.q:SetShown(c == nil)
    b.disc:SetVertexColor(c and 0 or 0.16, c and 0 or 0.16, c and 0 or 0.19, c and 0.85 or 1)
    local nameRoom = DETAIL_W - 70 - 70 - (kind == "black" and 90 or 0)
    b.name:SetText(UI():ColoredName(key, c))
    for _, size in ipairs({ 19, 17, 15 }) do
        local path, _, flags = b.name:GetFont()
        if path then b.name:SetFont(path, size, flags) end
        if (b.name:GetStringWidth() or 0) <= nameRoom then break end
    end
    b.pill:SetShown(kind == "black")
    local subs = subText(kind, key, e, c, sp)
    for i, text in ipairs(subs) do subs[i] = (text:gsub("^%l", string.upper)) end
    fitText(b.sub, subs, DETAIL_W - 70 - 70)
    b.whisperBtn:SetShown(true)
    b.moreBtn:SetShown(kind == "guest" or kind == "black")
    b.whisperBtn:ClearAllPoints()
    if b.moreBtn:IsShown() then
        b.whisperBtn:SetPoint("RIGHT", b.moreBtn, "LEFT", -6, 0)
    else
        b.whisperBtn:SetPoint("TOPRIGHT", -12, -12)
    end
    fillStats(b, (kind == "guest" or kind == "black") and e or nil)
    -- the actions: Recruit + Add to a raid (a guest), Recruit + Add (a fresh profile), Take off the blacklist,
    -- Blacklist (a name typed in on the Blacklist filter)
    local recruitOn
    if kind == "fresh" then recruitOn = state.draft.recruit else recruitOn = e and e.recruit end
    local showRaid = kind == "guest" and #upcomingRaids() > 0
    b.raidBtn:SetShown(showRaid)
    b.addBtn:SetShown(kind == "fresh")
    b.unblackBtn:SetShown(kind == "black")
    b.blackBtn:SetShown(kind == "draftBlack")
    b.recruitBtn:SetShown(kind == "guest" or kind == "fresh")
    b.recruitBtn:SetKind(recruitOn and "chosen" or "secondary")
    starTex(b.recruitBtn.glyph, recruitOn)
    b.recruitBtn:Fit()
    local last
    for _, btn in ipairs({ b.raidBtn, b.addBtn, b.unblackBtn, b.blackBtn }) do
        if btn:IsShown() then last = btn end
    end
    for _, btn in ipairs({ b.addBtn, b.unblackBtn, b.blackBtn }) do
        btn:ClearAllPoints()
        btn:SetPoint("BOTTOMRIGHT", -12, 12)
    end
    b.recruitBtn:ClearAllPoints()
    if last then b.recruitBtn:SetPoint("RIGHT", last, "LEFT", -6, 0) else b.recruitBtn:SetPoint("BOTTOMRIGHT", -12, 12) end
end

-- The note line: returns its height (0 when hidden).
local function fillNote(kind, key, e, bl)
    local n = view.note
    local editing = state.editing and state.editKey == key
    if kind == "fresh" or kind == "draftBlack" then
        n:Hide()
        n.box:Hide()
        return 0
    end
    local black = kind == "black"
    local text, by, at
    if black then
        text, by, at = bl.reason, bl.by, bl.at
    else
        text, by, at = e and e.note, e and e.noteBy, e and e.noteAt
    end
    if editing then
        n:Hide()
        n.box:Show()
        return 26
    end
    n.box:Hide()
    n:Show()
    n.pencil:ClearAllPoints()
    n.text:ClearAllPoints()
    n.by:ClearAllPoints()
    n.alts:Hide()
    if not text and not black then
        -- quiet: one grey link
        n.bg:SetColorTexture(0, 0, 0, 0)
        n.bar:Hide()
        n.pencil:SetPoint("LEFT", 2, 0)
        n.text:SetPoint("LEFT", n.pencil, "RIGHT", 7, 0)
        n.text:SetWidth(DETAIL_W - 30)
        n.text:SetText("Add a note")
        n.text:SetTextColor(0.55, 0.55, 0.58)
        n.by:SetText("")
        n:SetHeight(24)
        return 24
    end
    n.bar:Show()
    if black then
        n.bg:SetColorTexture(0.89, 0.36, 0.31, 0.06)
        n.bar:SetColorTexture(0.89, 0.36, 0.31, 0.85)
    else
        n.bg:SetColorTexture(1, 1, 1, 0.035)
        n.bar:SetColorTexture(1, 0.82, 0, 0.6)
    end
    n.pencil:SetPoint("TOPRIGHT", -12, -11)
    local byText = by and (shortName(by) .. (at and (" · " .. date("%d %b", at)) or "")) or ""
    n.by:SetText(byText)
    n.by:SetPoint("TOPRIGHT", n.pencil, "TOPLEFT", -10, 0)
    local room = DETAIL_W - 12 - 12 - 13 - 10 - (n.by:GetStringWidth() or 0) - 14
    n.text:SetPoint("TOPLEFT", 12, -9)
    n.text:SetWidth(room)
    n.text:SetText(text or "No reason given.")
    if text then n.text:SetTextColor(0.93, 0.93, 0.93) else n.text:SetTextColor(0.55, 0.55, 0.58) end
    local h = max(16, floor((n.text:GetStringHeight() or 16) + 0.5))
    local total = h + 18
    -- a guild member's other characters: covered too
    if black and inGuild(key) then
        local alts = {}
        for _, alt in ipairs(ns.Guild and ns.Guild.GetLinkedCharacters and ns.Guild:GetLinkedCharacters(bl.key) or {}) do
            alts[#alts + 1] = shortName(alt)
        end
        if #alts > 0 then
            n.alts:SetPoint("TOPLEFT", n.text, "BOTTOMLEFT", 0, -3)
            n.alts:SetWidth(room)
            fitText(n.alts, { "Also blocked: " .. tconcat(alts, ", "), "Also blocks " .. #alts .. " other characters" }, room)
            n.alts:Show()
            total = total + 14
        end
    end
    n:SetHeight(total)
    return total
end

local function viewHeight()
    local h = view.detail:GetHeight()
    if not h or h < 100 then h = VIEW_H end
    return h
end

-- Their raids (the next one first) and the items they received, in two columns (one when there are no items to show).
local function fillHistory(kind, key, e, top)
    local h = view.history
    if not ((kind == "guest" or kind == "black") and e) then
        h:Hide()
        return
    end
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", 0, -top)
    local room = viewHeight() - top
    h:SetHeight(max(room, 1))
    local fits = max(0, floor((room - SECT_H) / HIST_ROW_H))
    local zones = {}
    if e.next then
        local v = RP():GetRaid(e.next.id)
        zones[1] = { next = true, id = e.next.id, at = e.next.t, inst = e.next.inst,
                     title = v and RP():GetRaidName(v) or e.next.name }
    end
    for _, z in ipairs(e.zones or {}) do
        local inst = z.inst and RP():GetInstance(z.inst)
        zones[#zones + 1] = { id = z.id, at = z.at, inst = z.inst, title = z.zone or (inst and inst.name) or "Raid",
                              kills = z.kills, bosses = z.bosses, bench = z.bench, noShow = z.noShow }
    end
    local items = (seesItems() and e.itemList) or {}
    local showItems = #items > 0
    local colW = showItems and floor((DETAIL_W - COL_GAP) / 2) or DETAIL_W
    h:Show()
    h.raidCol:SetSize(colW, room)
    h.raidCol:SetShown(#zones > 0)
    h.itemCol:ClearAllPoints()
    h.itemCol:SetPoint("TOPLEFT", #zones > 0 and (colW + COL_GAP) or 0, 0)
    h.itemCol:SetSize(colW, room)
    h.itemCol:SetShown(showItems)
    local oldest
    for _, z in ipairs(zones) do if not z.next and (not oldest or z.at < oldest) then oldest = z.at end end
    h.raidSect.right:SetText(oldest and ("since " .. date("%d %b", oldest)) or "")
    for i = 1, max(#zones, #h.raidRows) do
        local z = i <= fits and zones[i] or nil
        local r = h.raidRows[i]
        if z and not r then
            r = newRaidRow(h.raidCol)
            h.raidRows[i] = r
        end
        if r then
            r:SetShown(z ~= nil)
            if z then
                r.cdlZone = z
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", 0, -(SECT_H + (i - 1) * HIST_ROW_H))
                r:SetWidth(colW)
                setArt(r.thumb, z.inst or "other", 48, 26, 0.5)
                r.thumb:SetDesaturated(z.noShow and true or false)
                r.thumb:SetAlpha(z.noShow and 0.6 or 1)
                local titleRoom = colW - 60 - 70
                fitText(r.title, { z.title, (z.title:gsub("^The ", "")) }, titleRoom)
                if z.noShow then r.title:SetTextColor(0.66, 0.66, 0.68) else r.title:SetTextColor(1, 1, 1) end
                if z.next then
                    r.line:SetText(date("%a %d %b · %H:%M", z.at))
                    r.line:SetTextColor(0.4, 0.72, 1)
                else
                    r.line:SetText(date("%a %d %b", z.at))
                    r.line:SetTextColor(0.62, 0.62, 0.62)
                end
                local pill = (z.next and { "Next", "alt" }) or (z.noShow and { "No-show", "warn" })
                    or (z.bench and { "Bench", "mute" }) or nil
                r.pill:SetShown(pill ~= nil)
                if pill then r.pill:Set(pill[1], pill[2]) end
                local showKills = not pill and (z.bosses or 0) > 0
                r.kills:SetShown(showKills)
                r.barBg:SetShown(showKills)
                r.bar:SetShown(showKills and (z.kills or 0) > 0)
                if showKills then
                    r.kills:SetText(("%d/%d"):format(z.kills or 0, z.bosses))
                    r.bar:SetWidth(max(1, floor(36 * min(1, (z.kills or 0) / z.bosses) + 0.5)))
                end
                r.hl:SetShown(z.next or seesRaidLog())
            end
        end
    end
    h.itemSect.right:SetText("")
    for i = 1, max(#items, #h.itemRows) do
        local it = i <= fits and items[i] or nil
        local r = h.itemRows[i]
        if it and not r then
            r = newItemRow(h.itemCol)
            h.itemRows[i] = r
        end
        if r then
            r:SetShown(it ~= nil)
            if it then
                r.cdlItem = it.i
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", 0, -(SECT_H + (i - 1) * HIST_ROW_H))
                r:SetWidth(colW)
                r.icon:SetTexture((C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(it.i))
                    or (GetItemIcon and GetItemIcon(it.i)) or 134400)
                local name = UI():ItemText(it.i)
                fitText(r.title, { name }, colW - 40)
                local boss = type(it.b) == "string" and it.b:match("[^:]+$") or nil
                local day = it.ts and date("%a %d %b", it.ts) or ""
                fitText(r.line, { (boss and boss ~= "" and (boss .. " · ") or "") .. day, day }, colW - 40)
            end
        end
    end
end

local function fillForm(kind, key)
    local f = view.form
    local fresh, draftBlack = kind == "fresh", kind == "draftBlack"
    f:SetShown(fresh or draftBlack)
    if not (fresh or draftBlack) then return end
    f.noteLabel:SetText(fresh and "Note" or "Reason")
    f.noteBox:SetShown(fresh)
    f.reasonBox:SetShown(draftBlack)
    f.classLabel:SetShown(fresh)
    local d = state.draft
    for _, b in ipairs(f.classBtns) do
        b:SetShown(fresh)
        local on = d.c == b.cls
        b.ring:SetShown(on)
        b.icon:SetDesaturated(not on)
        b.icon:SetAlpha(on and 1 or 0.55)
    end
    f.specDD:SetShown(fresh and d.c ~= nil)
    if fresh and d.c then f.specDD:Refresh() end
    f.err:ClearAllPoints()
    f.err:SetPoint("TOPLEFT", FIELD_X, fresh and -70 or -34)
end

local function fillProfile()
    local kind, key, e, bl = picked()
    view.detail:SetShown(kind ~= nil)
    if not kind then return end
    if state.draft.key ~= key then state.draft = { key = key } end
    fillBanner(kind, key, e, bl)
    local noteH = fillNote(kind, key, e, bl)
    fillHistory(kind, key, e, BAN_H + GAP + (noteH > 0 and (noteH + GAP) or 0))
    fillForm(kind, key)
end

-- Picks a row: key + kind (nil, "add", "black"); focus = put the cursor in the fresh profile's field; reveal = scroll
-- the list to it (picked from elsewhere).
function GuestUI:Select(key, kind, focus, reveal)
    if reveal then state.reveal = true end
    if state.sel ~= key or state.selKind ~= kind then
        state.editing = nil
        if view then view.form.err:SetText("") end
    end
    state.sel, state.selKind = key, kind
    self:Refresh()
    if focus and view then
        if kind == "add" then view.form.noteBox:SetFocus() elseif kind == "black" then view.form.reasonBox:SetFocus() end
    end
end

function GuestUI:GetSelected() return state.sel, state.selKind end

function GuestUI:SetFilter(filter)
    state.filter = (filter == "recruits" or filter == "black") and filter or "all"
    state.editing = nil
    self:Refresh()
end

function GuestUI:GetFilter() return state.filter end

-- The pencil / More > Note: the note (or a blacklisted player's reason) as a field in place.
function GuestUI:StartEdit()
    local kind, key, e, bl = picked()
    if kind ~= "guest" and kind ~= "black" then return end
    state.editing, state.editKey = kind == "black" and "reason" or "note", key
    local box = view.note.box
    box:SetMaxLetters(kind == "black" and 80 or 60)
    box:SetText((kind == "black" and bl.reason) or (e and e.note) or "")
    self:Refresh()
    box:SetFocus()
    if box.HighlightText then box:HighlightText() end
end

function GuestUI:FinishEdit(save)
    local what, key = state.editing, state.editKey
    if not what then return end
    state.editing = nil
    local box = view.note.box
    local text = box:GetText() or ""
    box:ClearFocus()
    if save and key then
        if what == "reason" then
            local bl = RP():GetBlacklistEntry(key)
            if bl and ns.Util.Trim(text) ~= (bl.reason or "") then
                local ok, err = RP():SetBlacklisted(bl.key, text)
                if not ok then Print("%s", tostring(err)) end
            end
        else
            local e = GB():GetEntry(key)
            if ns.Util.Trim(text) ~= ((e and e.note) or "") then
                local ok, err = GB():SetNote(key, text)
                if not ok then Print("%s", tostring(err)) end
            end
        end
    end
    self:Refresh()
end

-- Add on a fresh profile: the note, the Recruit mark and the class go into the book.
function GuestUI:SaveFresh()
    local kind, key = picked()
    if kind ~= "fresh" then return false end
    local d = state.draft
    local note = ns.Util.Trim(view.form.noteBox:GetText() or "")
    if note == "" and not d.recruit and not d.c then
        view.form.err:SetText("Write a note, mark them as a recruit or pick their class.")
        view.form.noteBox:SetFocus()
        return false
    end
    local ok, err = GB():SetNote(key, note ~= "" and note or nil, d.recruit and true or nil, d.c or nil, d.c and d.sp or nil)
    if not ok then
        view.form.err:SetText(err or "Could not add that player.")
        return false
    end
    view.form.err:SetText("")
    view.form.noteBox:SetText("")
    view.form.noteBox:ClearFocus()
    state.draft = {}
    state.search = ""
    view.search:SetText("")
    view.search:ClearFocus()
    if state.filter == "recruits" and not d.recruit then state.filter = "all" end
    state.sel, state.selKind, state.reveal = key, nil, true
    self:Refresh()
    return true
end

function GuestUI:Refresh()
    if not view or not view:IsVisible() then return end
    if not isManager() then return end
    local rows, empty = buildRows()
    local counts = { all = #filterRows("all"), recruits = #filterRows("recruits"), black = #RP():GetBlacklist() }
    for key, t in pairs(view.tabs) do
        t:SetLabel(t.cdlLabel .. "  |cff77777d" .. counts[key] .. "|r")
        t:SetActive(state.filter == key)
    end
    -- keep the picked row; else the first one
    local found = false
    for _, d in ipairs(rows) do if isPicked(d) then found = true end end
    if not found then
        local first = rows[1]
        if state.editing then state.editing = nil end
        state.sel, state.selKind = first and first.key or nil, first and first.add or nil
    end
    view.list:SetEmptyText(empty or "")
    view.list:SetData(rows)
    view.list.box:ForEachFrame(paintRow)
    -- a player opened from elsewhere (a menu, a link): their row in sight
    if state.reveal then
        state.reveal = nil
        local box = view.list.box
        for i, d in ipairs(rows) do
            if isPicked(d) and box.ScrollToElementDataIndex then
                box:ScrollToElementDataIndex(i, ScrollBoxConstants and ScrollBoxConstants.AlignCenter)
                break
            end
        end
    end
    fillProfile()
end

function GuestUI:RequestRefresh()
    if view and view:IsVisible() then ns.Util.Debounce("guestbook-ui", 0.2, function() GuestUI:Refresh() end) end
end

---------------------------------------------------------------------------
-- Opening it (the Raids tab's Guests view)
---------------------------------------------------------------------------

function GuestUI:GetWindow() return view end
function GuestUI:GetBlacklistPage() return view end
function GuestUI:GetBookPage() return view end

-- Opens Raids > Guests; tab "black" = the Blacklist filter, "book" = Everyone. Roster managers only.
function GuestUI:Open(tab)
    if not isManager() then
        Print("Only the Guild Master, officers and the raid leaders keep the guest book and the "
            .. "blacklist.")
        return false
    end
    if tab == "black" then
        state.filter = "black"
    elseif tab == "book" and state.filter == "black" then
        state.filter = "all"
    end
    if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open("raids") end
    if ns.RaidsUI and ns.RaidsUI.SetView then ns.RaidsUI:SetView("guests") end
    self:Refresh()
    return view ~= nil
end

local function setSearch(text)
    state.search = text or ""
    if view then view.search:SetText(state.search) end
end

-- The guest book on one player (a player menu's "Guest book..."); not in the book yet: a fresh profile for them.
function GuestUI:OpenGuest(key)
    if not self:Open("book") then return false end
    key = type(key) == "string" and ns.Util.NormalizeName(key) or nil
    if not key then return true end
    if GB():GetEntry(key) then
        if state.filter == "recruits" and not GB():GetEntry(key).recruit then state.filter = "all" end
        setSearch("")
        self:Select(key, nil, false, true)
    else
        state.filter = "all"
        setSearch(shortName(key))
        self:Select(key, "add", true, true)
    end
    return true
end

-- The Blacklist filter; key (optional) = a player: their entry when they are on it, else a fresh one to blacklist.
function GuestUI:OpenBlacklist(key)
    if not self:Open("black") then return false end
    view.form.err:SetText("")
    if type(key) ~= "string" then return true end
    key = ns.Util.NormalizeName(key) or key
    local bl = RP():GetBlacklistEntry(key)
    if bl then
        setSearch("")
        self:Select(bl.key, nil, false, true)
    else
        view.form.reasonBox:SetText("")
        setSearch(shortName(key))
        self:Select(key, "black", true, true)
    end
    return true
end

-- Blacklists the player of the fresh Blacklist profile (or the one given), with the reason typed there (or given).
function GuestUI:AddBlacklist(name, reason)
    if not view then return false end
    local kind, key = picked()
    name = name or (kind == "draftBlack" and key) or nil
    if not name then return false end
    reason = reason or view.form.reasonBox:GetText()
    local ok, keyOrErr = RP():SetBlacklisted(name, reason)
    if not ok then
        view.form.err:SetText(keyOrErr or "Could not blacklist that player.")
        return false
    end
    view.form.err:SetText("")
    view.form.reasonBox:SetText("")
    view.form.reasonBox:ClearFocus()
    setSearch("")
    state.filter = "black"
    state.sel, state.selKind, state.reveal = keyOrErr, nil, true
    self:Refresh()
    return true
end

function GuestUI:Unblacklist(key)
    local ok, err = RP():RemoveBlacklisted(key)
    if not ok then Print(err or "Could not take that player off the blacklist.") end
    self:Refresh()
    return ok and true or false
end

-- The note of a player (a key, or a name typed somewhere): the field in place on their profile; a player the book
-- doesn't have yet gets a fresh profile with the note field.
function GuestUI:EditNote(name)
    if type(name) ~= "string" or ns.Util.Trim(name) == "" then
        Print("Type the character name first.")
        return false
    end
    local key = ns.Util.NormalizeName(ns.Util.Trim(name))
    if not key then return false end
    if inGuild(key) then
        Print("%s is in the guild: the guest book is for players outside it.", shortName(key))
        return false
    end
    if not GB():GetEntry(key) and not RP():GetBlacklistEntry(key) then return self:OpenGuest(key) end
    if not self:Open() then return false end
    local bl = RP():GetBlacklistEntry(key)
    if bl then state.filter = "black" elseif state.filter ~= "all" then state.filter = "all" end
    setSearch("")
    self:Select(bl and bl.key or key, nil, false, true)
    self:StartEdit()
    return true
end

---------------------------------------------------------------------------
-- The player tooltip and the player right-click menus
---------------------------------------------------------------------------

-- Adds the DisasterZone lines for a player to a unit tooltip. Returns true when it added any.
function GuestUI:AddUnitLines(tt, key)
    if type(key) ~= "string" or ns.Util.IsMe(key) then return false end
    local R = RP()
    if not R then return false end
    local manager = isManager()
    local outsider = UI() and UI().IsGuest and UI():IsGuest(key)
    local e = R.GetBlacklistEntry and R:GetBlacklistEntry(key)
    if e and (outsider or manager) then
        tt:AddLine("DisasterZone: on the raid blacklist", 1, 0.25, 0.25)
        if manager then
            if e.reason then tt:AddLine(e.reason, 1, 0.65, 0.65, true) end
            if e.by then
                tt:AddLine(("Added by %s%s"):format(shortName(e.by), e.at and (" on " .. date("%d %b", e.at)) or ""),
                    0.6, 0.6, 0.6)
            end
        end
        return true
    end
    if manager and outsider then
        local s = GB() and GB().Summary and GB():Summary(key)
        if s then
            tt:AddLine("DisasterZone guest: " .. s, 0.4, 0.8, 1, true)
            return true
        end
    end
    return false
end

local function OnTooltipSetUnit(tt)
    if not (tt and tt.GetUnit) then return end
    local _, unit = tt:GetUnit()
    if not unit or not (UnitIsPlayer and UnitIsPlayer(unit)) then return end
    local key = ns.Util.UnitKey and ns.Util.UnitKey(unit)
    if key and GuestUI:AddUnitLines(tt, key) then tt:Show() end
end

-- The player a right-click menu is for: its unit, or (chat names) its name and realm.
local function MenuPlayer(contextData)
    if type(contextData) ~= "table" then return nil end
    local unit = contextData.unit
    if unit and UnitIsPlayer and UnitIsPlayer(unit) then return ns.Util.UnitKey(unit) end
    local name = contextData.name
    if type(name) ~= "string" or name == "" or name:find("[%c|]") then return nil end
    local server = contextData.server
    return ns.Util.NormalizeName((type(server) == "string" and server ~= "") and (name .. "-" .. server) or name)
end

function GuestUI:ModifyPlayerMenu(root, contextData)
    if not root or not isManager() then return end
    local key = MenuPlayer(contextData)
    if not key or ns.Util.IsMe(key) then return end
    if root.CreateDivider then root:CreateDivider() end
    if root.CreateTitle then root:CreateTitle("DisasterZone") end
    local R = RP()
    if R and R.IsBlacklisted and R:IsBlacklisted(key) then
        root:CreateButton("On the raid blacklist...", function() GuestUI:OpenBlacklist(key) end)
    else
        root:CreateButton("Blacklist...", function() GuestUI:OpenBlacklist(key) end)
    end
    if UI():IsGuest(key) then
        root:CreateButton("Guest book...", function() GuestUI:OpenGuest(key) end)
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function GuestUI:OnInit()
    for _, msg in ipairs({ "GUESTBOOK_CHANGED", "RAID_BLACKLIST_CHANGED", "RAIDPLAN_CHANGED", "CONFIG_UPDATED",
                           "ROSTER_UPDATED", "RAIDLOG_CHANGED", "LEDGER_UPDATED", "ITEMINFO_READY" }) do
        ns:On(msg, function() GuestUI:RequestRefresh() end)
    end
    if GameTooltip and GameTooltip.HookScript then GameTooltip:HookScript("OnTooltipSetUnit", OnTooltipSetUnit) end
    if Menu and type(Menu.ModifyMenu) == "function" then
        for _, tag in ipairs(MENU_TAGS) do
            Menu.ModifyMenu(tag, function(_, root, contextData) GuestUI:ModifyPlayerMenu(root, contextData) end)
        end
    end
end
