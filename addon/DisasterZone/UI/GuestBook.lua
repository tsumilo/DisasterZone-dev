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
-- 1.4: a list + detail layout (UI:CreateLayout). The players are art rows (UI:CreateArtRow: their last raid's picture,
-- the class in the icon tile, the marks at the right); the profile's banner is the page banner (the numbers in its
-- kicker, its actions and tools), Raids / Items are the block tabs on its foot, each an art-row list under a section
-- header; the note is a notice strip (UI:CreateNotice), the fresh profile's classes are chips.
local addonName, ns = ...

local GuestUI = ns:NewModule("GuestBookUI")

local S = ns.Style
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local DAY = 86400
local ADD_AHEAD = 14 * DAY         -- the raids a guest can be added to from the book: the next two weeks
local MENU_TAGS = { "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_RAID",
                    "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS", "MENU_UNIT_FRIEND", "MENU_UNIT_ENEMY_PLAYER" }

-- The view on the Raids tab's grid: S.PAD at the sides, S.GAP between blocks (the Raid log's numbers).
local GAP = S.GAP
local LIST_W = 250                 -- the players column
local DETAIL_W = S.INNER_W - LIST_W - GAP
local SEARCH_H = 24
local TABS_Y = SEARCH_H + 6        -- the filters under the search box
local LIST_Y = TABS_Y + 18 + 6
local ROW_H = S.ROW.art            -- a player in the list, a raid / an item of the profile: art rows
local TEXT_X = 80                  -- where an art row's text starts (its picture, the gap)
local SECT_H = 24                  -- a section header (title style)
local FIELD_X = 52                 -- the fresh profile's fields, after their labels
local STAR_TEX = "Interface\\Common\\ReputationStar"
local BLOCK_TEX = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
local CLASS_TILE = "Interface\\Icons\\INV_Misc_QuestionMark"  -- (an icon tile; ClassIcon paints the class over it)

-- state.filter: "all" | "recruits" | "black"; state.sel + state.selKind: the picked row (selKind nil = a player of the
-- book or the blacklist, "add" = a name typed in (a fresh profile), "black" = a name typed in on the Blacklist filter);
-- state.draft: the fresh profile's picks { key, recruit, c, sp }; state.editing: the note / reason field is open;
-- state.tab: the profile's open tab, "raids" | "items".
local state = { filter = "all", search = "", draft = {}, tab = "raids" }
local view

-- (the file's small helpers in one table: the main chunk keeps few locals)
local H = {}

local function UI() return ns.UI end
local function RP() return ns.RaidPlan end
local function GB() return ns.GuestBook end

local function Print(...) ns:Print(...) end

function H.Dim(text) return S:Wrap("DIM", text) end

function H.Short(key) return ns.Util.ShortName(key) or tostring(key) end

local function isManager()
    local R = RP()
    return (R and R.CanManageRoster and R:CanManageRoster()) and true or false
end

-- Awarded items are loot council data (the GM and the guild council), as in the Raid log.
local function seesItems()
    local G = ns.Guild
    return (ns.Util.DemoOn() or (G and G.IsGuildCouncil and G:IsGuildCouncil(ns.Util.PlayerKey()))) and true or false
end

-- The Raid log (a raid row opens it) is for its members.
local function seesRaidLog()
    local G = ns.Guild
    return (ns.Util.DemoOn() or (G and G.AmIRaidLogMember and G:AmIRaidLogMember())) and true or false
end

local function inGuild(key)
    local G = ns.Guild
    return (G and G.IsInGuild and G:IsInGuild(key, true)) and true or false
end

local function specText(c, sp)
    local spec = c and sp and ns.SPECS and ns.SPECS[c] and ns.SPECS[c][sp]
    local cls = c and ns.ClassName(c) or ""
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
    local name = (Ambiguate and Ambiguate(key, "none")) or H.Short(key)
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if open then open("/w " .. name .. " ") end
end

-- The same, measured in a text style (for a component that sets the text itself).
function H.PickVariant(variants, room, style)
    for i, text in ipairs(variants) do
        local plain = (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
        if i == #variants or UI():TextWidth(plain, style) <= room then return text end
    end
end

-- The recruit star inside a text (dim: greyed, a star that isn't lit).
local function starText(size, dim)
    return ("|T%s:%d:%d:0:0:32:32:0:16:0:16%s|t"):format(STAR_TEX, size or 14, size or 14, dim and ":150:150:150" or "")
end
local function blockText(size) return ("|T%s:%d:%d|t"):format(BLOCK_TEX, size or 14, size or 14) end
local function iconText(i) return UI():AtlasIconText(i, 14) end

-- A raid's loading screen on a texture, cropped for w x h (under the game's logo).
function H.SetArt(tex, inst, w, h, fw)
    if not inst then
        tex:Hide()
        return false
    end
    local file, l, r, t, b = ns.ItemDB:RaidArt(inst, w, h, fw, true)
    tex:SetTexture(file)
    tex:SetTexCoord(l or 0, r or 1, t or 0, b or 1)
    tex:Show()
    return true
end

-- The same crop inside text (a menu entry): a small thumbnail.
local function artText(inst, w, h)
    if not inst then return "" end
    local file, l, r, t, b = ns.ItemDB:RaidArt(inst, w, h, 0.5, true)
    local function px(v) return floor(v * 1024 + 0.5) end
    return ("|T%s:%d:%d:0:0:1024:1024:%d:%d:%d:%d|t"):format(tostring(file), h, w, px(l), px(r), px(t), px(b))
end

---------------------------------------------------------------------------
-- Data: the list's rows, the picked player
---------------------------------------------------------------------------

-- The class (and spec) the book knows for a player: a guest entry, their notes, the spec memory, the guild roster.
local function bookClass(key, e)
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
        local name = H.Short(r.key):lower()
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
            empty = H.Short(key) .. " is in the guild."
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
    Print("%s is a guest of %s.", H.Short(key), v and RP():GetRaidName(v) or "the raid")
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
    local c = bookClass(key, e)
    if not c then
        root:CreateTitle("Their class")
        for _, cls in ipairs(ns.CLASSES or {}) do
            local sub = root:CreateButton(ns.ClassName(cls))
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
    if not (ns.Popup and ns.Popup.Confirm) then return remove() end
    ns.Popup:Confirm({ title = "Remove a guest", ok = "Remove", danger = true, onAccept = function() remove() end,
        text = ("Remove %s from the guest book?\n\nTheir note and Recruit mark are deleted for every organizer. "
            .. "They come back if they raid with you again."):format(H.Short(key)) })
end

-- The class submenus (More > Class): the class, then its spec.
local function classMenu(root, key, e)
    local cur, curSp = bookClass(key, e)
    local sub = root:CreateButton("Class")
    for _, cls in ipairs(ns.CLASSES or {}) do
        local name = ns.ClassName(cls)
        local cs = sub:CreateButton(cls == cur and (S:Wrap("GOLD", name)) or name)
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
        root:CreateTitle(H.Short(key))
        if not inGuild(key) then
            if not bl and #upcomingRaids() > 0 then
                local sub = root:CreateButton(iconText(UI().ICON.invite or 19) .. "  Add to a raid")
                GuestUI:BuildRaidMenu(sub, key, entry)
            end
            root:CreateButton(starText(14) .. "  " .. ((entry and entry.recruit) and "Not a recruit" or "Recruit"),
                function() toggleRecruit(key, entry) end)
            H.RecruitButton(root, key)
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
            root:CreateButton(blockText(14) .. "  " .. S:Wrap("BAD", "Blacklist"), function() GuestUI:OpenBlacklist(key) end)
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
            root:CreateButton(blockText(14) .. "  " .. S:Wrap("BAD", "Blacklist"), function() GuestUI:OpenBlacklist(key) end)
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
        local by = bl.by and H.Short(bl.by)
        local full = "Guest" .. (when and (" · " .. when) or "") .. (by and (", " .. by) or "")
        return { full, "Guest" .. (when and (" · " .. when) or "") }
    end
    if bl then
        return { S:Wrap("BAD", "Blacklisted" .. (bl.at and (" " .. date("%d %b", bl.at)) or "")) }
    end
    if e and e.next then
        local v = RP():GetRaid(e.next.id)
        local short = v and ns.RaidComp and ns.RaidComp.ShortInstanceNames
            and ns.RaidComp:ShortInstanceNames(RP():GetRaidInstances(v)) or e.next.name
        local day = date("%a %d %b", e.next.t)
        return { S:Wrap("YOU", "Guest " .. day .. " · " .. tostring(short)), S:Wrap("YOU", "Guest " .. day) }
    end
    if e and e.raids > 0 then
        local raids = plural(e.raids, "raid")
        if e.noShows > 0 then return { raids .. " · " .. S:Wrap("BAD", plural(e.noShows, "no-show")) } end
        return { raids .. " · last " .. date("%a %d %b", e.last), raids .. " · last " .. date("%d %b", e.last) }
    end
    if e and e.noShows > 0 then return { S:Wrap("BAD", plural(e.noShows, "no-show")) } end
    return { "Not raided yet" }
end

-- The marks at a row's right (icons inside the text): recruit star, note, blacklisted. Returns the text and how many.
function H.MarksText(d)
    if d.add then return nil, 0 end
    local out = {}
    local e = d.e
    if e and e.recruit then out[#out + 1] = starText(13) end
    if e and e.note then out[#out + 1] = UI():AtlasIconText(UI().ICON.notes, 13, S.C.SUB) end
    if d.bl and state.filter ~= "black" then out[#out + 1] = blockText(13) end
    if #out == 0 then return nil, 0 end
    return tconcat(out, " "), #out
end

-- A raid's loading screen as an art row's picture (greyed: a raid they missed, a blacklisted player).
function H.Art(inst, grey)
    return function(tex, w, h)
        H.SetArt(tex, inst or "other", w, h, 0.5)
        tex:SetDesaturated(grey and true or false)
        tex:SetAlpha(grey and 0.6 or 1)
    end
end

-- An art row's icon tile: a class circle (cls), an atlas glyph on the tile's dark ground (glyph: a UI.ICON name or
-- index, drawn glyphColor, gold by default: the "Add <name>" row's +, a grey ? while the class is unknown), an icon (a
-- texture), or none.
H.HELP = 11                                     -- (the icon atlas's ?: a player whose class is unknown)
function H.Tile(row, icon, cls, glyph, glyphColor)
    local tile = row.icon
    local tex = tile.tex
    -- (rows are reused: no tint, inset or hidden texture left over from a glyph or a class ClassIcon didn't know)
    tex:SetVertexColor(1, 1, 1, 1)
    tex:ClearAllPoints()
    tex:SetAllPoints()
    tex:Show()
    if cls then
        tile:Set(CLASS_TILE)
        UI():ClassIcon(tex, cls)
    elseif glyph then
        tile:Set(UI().ICON_ATLAS)
        UI():SetGlyph(tex, glyph, glyphColor or "GOLD")
        local size = floor((tile:GetWidth() or 20) * 0.7 + 0.5)
        tex:ClearAllPoints()
        tex:SetPoint("CENTER")
        tex:SetSize(size, size)
    elseif icon then
        tile:Set(icon)
        tile.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    else
        tile:Set(nil)
    end
end

-- The loading screen behind a player: their last raid with us (one they missed when that is all), else their next.
local function artInst(e)
    if not e then return nil end
    for _, z in ipairs(e.zones or {}) do if not z.noShow and z.inst then return z.inst end end
    for _, z in ipairs(e.zones or {}) do if z.inst then return z.inst end end
    return e.next and e.next.inst or nil
end

-- The picked row: the shared selected look.
local function paintRow(row)
    local d = row.cdlData
    if row.ar then row.ar:SetSelected(d ~= nil and isPicked(d)) end
end

function H.RowClick(self, button)
    local data = self:GetParent().cdlData
    if not data then return end
    if button == "RightButton" then
        if not data.add then GuestUI:OpenEntryMenu(self, data) end
        return
    end
    GuestUI:Select(data.key, data.add, data.add ~= nil)
end

-- A player of the list: an art row (their last raid's picture, the class in the icon tile, the name, one line, the
-- marks at the right); the add rows ("Add <name>", "Blacklist <name>") the same with the plain picture.
local function initRow(row, d)
    row.cdlData = d
    if not row.ar then
        row.ar = UI():CreateArtRow(row, { selectable = true, onClick = H.RowClick })
        row.ar:SetAllPoints(row)
    end
    local add = d.add
    local c = not add and bookClass(d.key, d.e) or nil
    local title
    if add == "add" then
        title = S:Wrap("GOLD", "Add " .. H.Short(d.key))
    elseif add == "black" then
        title = S:Wrap("BAD", "Blacklist " .. H.Short(d.key))
    else
        title = UI():ColoredName(d.key, c)
    end
    local marks, n = H.MarksText(d)
    local room = LIST_W - TEXT_X - 8 - n * 17
    row.ar:SetData({ art = H.Art(not add and artInst(d.e) or nil, d.bl ~= nil and state.filter ~= "black"),
        title = title, sub = H.PickVariant(rowLine(d), room, "sub"), right = marks, selected = isPicked(d) })
    -- the tile: the class; a gold + (Add); the block sign (Blacklist); a ? while the class is unknown (1.3.5's marks)
    if add == "add" then
        H.Tile(row.ar, nil, nil, "plus")
    elseif add == "black" then
        H.Tile(row.ar, BLOCK_TEX)
    elseif c then
        H.Tile(row.ar, nil, c)
    else
        H.Tile(row.ar, nil, nil, H.HELP, "SUB")
    end
end

---------------------------------------------------------------------------
-- The profile
---------------------------------------------------------------------------

-- The profile's banner is the layout's page banner: the raid's art (greyed for a blacklisted player), the class in its
-- icon tile, the name with Blacklisted, the numbers in its kicker, the spec / realm line, Whisper and More at the top
-- right, the actions at the bottom right (one gold per context: b.acts, the shown ones b.raidBtn, b.recruitBtn ...).
local function decorateBanner(b)
    b.whisperTool = { icon = "whisper", title = "Whisper", onClick = function()
        if state.sel then whisper(state.sel) end
    end }
    b.moreTool = { icon = "more", title = "More", text = "Class, the note, remove from the book, the blacklist.",
        onClick = function(self) moreMenu(self) end }
    local function iconW(text) return floor(UI():TextWidth(text, "body") + 13 + 6 + 28 + 0.5) end
    b.acts = {
        raid = { text = "Add to a raid", kind = "primary", menu = function(root)
            local _, key, e = picked()
            if key then GuestUI:BuildRaidMenu(root, key, e) end
        end },
        recruit = { text = starText(13) .. "  Recruit", width = iconW("Recruit"), onClick = function()
            local kind, key, e = picked()
            if kind == "fresh" then
                state.draft.recruit = not state.draft.recruit
                GuestUI:Refresh()
            elseif key then
                toggleRecruit(key, e)
            end
        end, tip = { "Recruit", "A player you'd like in the guild: the Recruits filter lists them, and the raid leaders "
            .. "and officers see the star." } },
        add = { text = "Add", kind = "primary", onClick = function() GuestUI:SaveFresh() end },
        unblack = { text = "Take off the blacklist", onClick = function()
            local _, _, _, bl = picked()
            if bl then GuestUI:Unblacklist(bl.key) end
        end },
        black = { text = blockText(13) .. "  Blacklist", kind = "danger", width = iconW("Blacklist"),
            onClick = function() GuestUI:AddBlacklist() end },
    }
    return b
end

-- The numbers of a player's raids with us (the banner's kicker): "3 raids · 12 boss kills · 1 no-show · 2 items".
function H.StatsText(e)
    if not (e and (e.raids > 0 or e.noShows > 0)) then return nil end
    local parts = { plural(e.raids, "raid"), plural(e.kills, "boss kill") }
    if e.noShows > 0 then parts[#parts + 1] = S:Wrap("BAD", plural(e.noShows, "no-show")) end
    if seesItems() and e.items > 0 then parts[#parts + 1] = plural(e.items, "item") end
    return tconcat(parts, " · ")
end

local function subText(kind, key, e, c, sp)
    if kind == "draftBlack" or (kind == "black" and not e) then
        if inGuild(key) then
            local alts = {}
            for _, alt in ipairs(ns.Guild and ns.Guild.GetLinkedCharacters and ns.Guild:GetLinkedCharacters(key) or {}) do
                alts[#alts + 1] = H.Short(alt)
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
    local inst = (kind == "guest" or kind == "black") and artInst(e) or nil
    b:SetArt(inst, black)
    if not inst and black then b.glow:Hide() end
    -- a blacklisted player: the art greyed under a red veil (over the banner's shade, under its words) and a red edge
    if black and not b.redWash then
        b.redWash = b:CreateTexture(nil, "BORDER", nil, 4)
        b.redWash:SetPoint("TOPLEFT", 1, -1)
        b.redWash:SetPoint("BOTTOMRIGHT", -1, 1)
        UI():GradientRGBA(b.redWash, "HORIZONTAL", 0.42, 0.05, 0.03, 0.18, 0.42, 0.05, 0.03, 0.42)
    end
    if b.redWash then b.redWash:SetShown(black) end
    if black then
        local r, g, bb = S:Color("BAD")
        UI():SetEdgeColor(b, r, g, bb, 0.6)
    else
        UI():SetEdgeColor(b, S:Color("EDGE"))
    end
    local c, sp
    if kind == "fresh" then c, sp = state.draft.c, state.draft.sp else c, sp = bookClass(key, e) end
    -- the class circle in the icon tile (a grey ? while the class is unknown, as the list's rows)
    if c then
        b:SetIcon(CLASS_TILE)
        b.icon.tex:Show()
        UI():ClassIcon(b.icon.tex, c)
    else
        b:SetIcon(H.HELP, { glyph = "SUB" })
        b.icon.tex:Show()
    end
    b:SetTitle(UI():ColoredName(key, c))
    if kind == "black" then b:SetPill("live", "Blacklisted") else b:SetPill(nil, nil) end
    b:SetKicker((kind == "guest" or kind == "black") and H.StatsText(e) or nil)
    local subs = subText(kind, key, e, c, sp)
    for i, text in ipairs(subs) do subs[i] = (text:gsub("^%l", string.upper)) end
    b:SetSub(H.PickVariant(subs, DETAIL_W - 70 - 70, "body"))
    -- Whisper always; More for a player of the book or the blacklist
    if kind == "guest" or kind == "black" then
        b:SetTools({ b.moreTool, b.whisperTool })
    else
        b:SetTools({ b.whisperTool })
    end
    -- the actions (the first at the far right): Add to a raid + Recruit (a guest), Add + Recruit (a fresh profile),
    -- Take off the blacklist, Blacklist (a name typed in on the Blacklist filter)
    local A = b.acts
    local list = {}
    if kind == "guest" and #upcomingRaids() > 0 then list[#list + 1] = A.raid end
    if kind == "fresh" then list[#list + 1] = A.add end
    if kind == "black" then list[#list + 1] = A.unblack end
    if kind == "draftBlack" then list[#list + 1] = A.black end
    if kind == "guest" or kind == "fresh" then
        local on
        if kind == "fresh" then on = state.draft.recruit else on = e and e.recruit end
        A.recruit.text = starText(13, not on) .. "  Recruit"
        A.recruit.kind = on and "chosen" or nil
        list[#list + 1] = A.recruit
    end
    b:SetActions(list)
    for name in pairs(A) do b[name .. "Btn"] = nil end
    for _, f in ipairs(b.actions) do
        for name, a in pairs(A) do
            if f.ppAction == a then b[name .. "Btn"] = f end
        end
    end
end

-- The note (or the reason) under the banner: a notice strip (a note: info; the blacklist's reason: locked) with who
-- wrote it and when and a pencil; clicked, it becomes a field in place (Enter or a click away saves, Escape restores).
local function createNote(body)
    local n = CreateFrame("Button", nil, body)
    n:SetPoint("TOPLEFT", 0, 0)
    n:SetSize(DETAIL_W, 26)
    n.strip = UI():CreateNotice(n, "info", "")
    n.strip:SetPoint("TOPLEFT", 0, 0)
    n.strip:SetWidth(DETAIL_W)
    n:SetScript("OnClick", function() GuestUI:StartEdit() end)
    UI():AttachTooltip(n, function(_, tt)
        tt:AddLine(state.selKind == nil and RP():GetBlacklistEntry(state.sel or "") and "Reason" or "Note")
        tt:AddLine("Click to change it.", 1, 1, 1)
    end, nil, { anchor = "ANCHOR_TOP" })
    n.box = UI():CreateSleekEditBox(body, DETAIL_W, 26, "GameFontHighlight")
    n.box:SetPoint("TOPLEFT", 0, 0)
    n.box:Hide()
    n.box:SetScript("OnEnterPressed", function() GuestUI:FinishEdit(true) end)
    n.box:SetScript("OnEscapePressed", function() GuestUI:FinishEdit(false) end)
    n.box:HookScript("OnEditFocusLost", function() if state.editing then GuestUI:FinishEdit(true) end end)
    return n
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
    local pencil = "  " .. UI():AtlasIconText(16, 12, S.C.SUB)
    local line
    if not text and not black then
        line = H.Dim("Add a note") .. pencil
    else
        line = text or H.Dim("No reason given.")
        if by then line = line .. "   " .. H.Dim(H.Short(by) .. (at and (" · " .. date("%d %b", at)) or "")) end
        line = line .. pencil
        -- a guild member's other characters: covered too
        if black and inGuild(key) then
            local alts = {}
            for _, alt in ipairs(ns.Guild and ns.Guild.GetLinkedCharacters and ns.Guild:GetLinkedCharacters(bl.key) or {}) do
                alts[#alts + 1] = H.Short(alt)
            end
            if #alts > 0 then line = line .. "\n" .. S:Wrap("SUB", "Also blocked: " .. tconcat(alts, ", ")) end
        end
    end
    n.strip:SetNotice(black and "locked" or "info", line)
    local h = floor((n.strip:GetHeight() or 26) + 0.5)
    n:SetHeight(h)
    return h
end

-- The profile's tab: a raid of theirs (the next one first) or an item they received, as an art row.
function H.HistTip(self, tt)
    local d = self:GetParent().cdlData
    if not d then return false end
    if d.item then
        UI():SetItemTooltip(self, d.item.i)     -- (it owns and shows the tooltip itself)
        return
    end
    local z = d.zone
    tt:AddLine(z.title)
    tt:AddLine(date("%A %d %B, %H:%M", z.at), S:RGB("SUB"))
    if z.next then
        tt:AddLine("A guest seat on this raid. Click to open it.", S.C.YOU[1], S.C.YOU[2], S.C.YOU[3], true)
    elseif z.noShow then
        tt:AddLine("Signed up and didn't come.", S:RGB("BAD"))
    elseif z.bench then
        tt:AddLine("On the bench.", S:RGB("SUB"))
    elseif (z.bosses or 0) > 0 then
        tt:AddLine(("There for %d of the %d boss kills."):format(z.kills or 0, z.bosses), 1, 1, 1)
    end
    if not z.next and seesRaidLog() then tt:AddLine("Click to open it in the Raid log.", S:RGB("DIM")) end
end

function H.HistClick(self)
    local d = self:GetParent().cdlData
    if not d then return end
    if d.item then
        UI():HandleModifiedItemClick(d.item.i)
        return
    end
    local z = d.zone
    if z.next then
        ns.RaidsUI:SetView("upcoming")
        ns.RaidPlanUI:SelectRaid(z.id)
    elseif z.id and seesRaidLog() then
        ns.RaidsUI:Select(z.id)
    end
end

local function initHistRow(row, d)
    row.cdlData = d
    if not row.ar then
        row.ar = UI():CreateArtRow(row, { onClick = H.HistClick })
        row.ar:SetAllPoints(row)
        UI():AttachTooltip(row.ar, H.HistTip)
    end
    local it = d.item
    if it then
        local b = type(it.b) == "string" and it.b or ""
        local boss, raid = b:match("[^:]+$"), b:match("^([^:]+):")
        local day = it.ts and date("%a %d %b", it.ts) or ""
        row.ar:SetData({ art = H.Art(raid), title = UI():ItemText(it.i),
            sub = (boss and boss ~= "" and (boss .. " · ") or "") .. day })
        H.Tile(row.ar, UI():ItemIcon(it.i))
        return
    end
    local z = d.zone
    local pill = (z.next and { "alt", "Next" }) or (z.noShow and { "warn", "No-show" })
        or (z.bench and { "mute", "Bench" }) or nil
    row.ar:SetData({ art = H.Art(z.inst, z.noShow), title = z.noShow and S:Wrap("SUB", z.title) or z.title,
        sub = z.next and S:Wrap("YOU", date("%a %d %b · %H:%M", z.at)) or date("%a %d %b", z.at),
        right = not pill and (z.bosses or 0) > 0 and ("%d/%d"):format(z.kills or 0, z.bosses) or nil, pill = pill })
    H.Tile(row.ar, nil)
end

-- The open tab's section header and its list (an art row per raid / item).
local function createHistory(body)
    local h = {}
    h.head = UI():CreateSectionHeader(body, "Raids")
    h.list = UI():CreateScrollList(body, ROW_H, initHistRow)
    -- (its bar in the margin beside the detail)
    h.list.bar:ClearAllPoints()
    h.list.bar:SetPoint("TOPLEFT", h.list.box, "TOPRIGHT", 4, 0)
    h.list.bar:SetPoint("BOTTOMLEFT", h.list.box, "BOTTOMRIGHT", 4, 0)
    return h
end

-- (a fresh profile has no tabs: the strip gives its room back)
function H.SetTabsShown(on)
    view.layout:SetTabsShown(on)
end

-- Their raids (the next one first) or the items they received (the loot council), the open tab's list.
local function fillHistory(kind, key, e, top)
    local h = view.hist
    local show = (kind == "guest" or kind == "black") and e ~= nil
    H.SetTabsShown(show)
    h.head:SetShown(show)
    h.list.frame:SetShown(show)
    if not show then return end
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
    local items = seesItems() and (e.itemList or {}) or nil
    local tabs = view.tabStrip
    tabs:SetTabCount("raids", #zones)
    tabs:SetTabShown("items", items ~= nil)
    if items then tabs:SetTabCount("items", #items) end
    if state.tab == "items" and not items then state.tab = "raids" end
    tabs:SelectTab(state.tab)
    h.head:ClearAllPoints()
    h.head:SetPoint("TOPLEFT", 0, -top)
    h.head:SetPoint("TOPRIGHT", 0, -top)
    h.list.frame:ClearAllPoints()
    h.list.frame:SetPoint("TOPLEFT", 0, -(top + SECT_H + 4))
    h.list.frame:SetPoint("BOTTOMRIGHT", 20, 0)
    local rows = {}
    if state.tab == "items" then
        h.head:SetTitle("Items")
        h.head:SetRight(nil)
        for i, it in ipairs(items) do rows[i] = { item = it } end
        h.list:SetEmptyText("No items from the Loot Log.")
    else
        local oldest
        for _, z in ipairs(zones) do if not z.next and (not oldest or z.at < oldest) then oldest = z.at end end
        h.head:SetTitle("Raids")
        h.head:SetRight(oldest and ("since " .. date("%d %b", oldest)) or nil)
        for i, z in ipairs(zones) do rows[i] = { zone = z } end
        h.list:SetEmptyText("No raids with us yet.")
    end
    h.list:SetData(rows)
end

-- The fresh profile (a name typed in): the note (or, on the Blacklist filter, the reason), the class (chips) and spec.
local function createForm(dc)
    local f = CreateFrame("Frame", nil, dc)
    f:SetPoint("TOPLEFT", 0, -(12 - GAP))
    f:SetSize(DETAIL_W, 120)
    local function label(text, y)
        local fs = UI():Text(f, "body", "SUB")
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
    f.classLabel = label("Class", -40)
    -- the classes as chips (a class circle and the name; the picked one gold), in rows that fit the field
    f.classBtns = {}
    local x, y = FIELD_X, -38
    for i, cls in ipairs(ns.CLASSES or {}) do
        local b = UI():CreateChip(f, { onClick = function(self)
            local d = state.draft
            if d.c == self.cls then d.c, d.sp = nil, nil else d.c, d.sp = self.cls, nil end
            GuestUI:Refresh()
        end })
        b:Set(ns.ClassName(cls), nil, cls)
        UI():ClassIcon(b.cls, cls)          -- (the chip's circle is a player's: paint the class itself)
        b.cls:SetVertexColor(1, 1, 1, 1)
        if x + b:GetWidth() > DETAIL_W then x, y = FIELD_X, y - 24 end
        b:SetPoint("TOPLEFT", x, y)
        x = x + b:GetWidth() + 6
        b.cls = cls
        f.classBtns[i] = b
    end
    f.classY = y
    f.specDD = UI():CreateLinkDropdown(f, {
        font = "GameFontHighlight", size = S.FONT.emph,
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
    f.err = UI():Text(f, "body", "BAD")
    f.err:SetPoint("TOPLEFT", FIELD_X, f.classY - 32)
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
    -- a list + detail page: the players column, the profile (its banner with the Raids / Items tabs on its foot, then
    -- the note and the open tab, or the fresh profile's form)
    local L = UI():CreateLayout("listdetail", v, { toolbar = false, listWidth = LIST_W, width = S.PAGE_W,
        banner = { size = "hero", artFw = 0.98, artUnder = true },
        tabs = { { key = "raids", text = "Raids" }, { key = "items", text = "Items" } },
        onTab = function(key) GuestUI:SetTab(key) end })
    v.layout = L

    -- the players column: the search box (it adds too), the filters, the list
    local lc = L.list
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
    v.tabRule = UI():Rule(lc, { top = TABS_Y + 18, alpha = 0.1, layer = "BORDER" })
    v.list = UI():CreateScrollList(lc, ROW_H, initRow)
    v.list.frame:SetPoint("TOPLEFT", 0, -LIST_Y)
    v.list.frame:SetPoint("BOTTOMLEFT", 0, 0)
    v.list.frame:SetWidth(LIST_W + 20)
    -- (its bar in the gap beside the column)
    v.list.bar:ClearAllPoints()
    v.list.bar:SetPoint("TOPLEFT", v.list.box, "TOPRIGHT", 1, 0)
    v.list.bar:SetPoint("BOTTOMLEFT", v.list.box, "BOTTOMRIGHT", 1, 0)

    -- the profile
    v.detail = L.detail
    v.banner = decorateBanner(L.banner)
    v.tabStrip = L.tabs
    v.note = createNote(L.body)
    v.hist = createHistory(L.body)
    v.form = createForm(L.body)
    -- (old names, for the pages that open the blacklist with a name)
    v.reasonBox, v.noteBox = v.form.reasonBox, v.form.noteBox
    v:SetScript("OnShow", function() GuestUI:Refresh() end)
    return v
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
        b:SetSelected(d.c == b.cls)
    end
    f.specDD:SetShown(fresh and d.c ~= nil)
    if fresh and d.c then f.specDD:Refresh() end
    f.err:ClearAllPoints()
    f.err:SetPoint("TOPLEFT", FIELD_X, fresh and (f.classY - 32) or -34)
end

local function fillProfile()
    local kind, key, e, bl = picked()
    view.detail:SetShown(kind ~= nil)
    if not kind then return end
    if state.draft.key ~= key then state.draft = { key = key } end
    fillBanner(kind, key, e, bl)
    local noteH = fillNote(kind, key, e, bl)
    fillHistory(kind, key, e, noteH > 0 and (noteH + GAP) or 0)
    fillForm(kind, key)
end

-- The profile's open tab: "raids" | "items" (the loot council's).
function GuestUI:SetTab(tab)
    state.tab = tab == "items" and "items" or "raids"
    self:Refresh()
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
        t:SetLabel(t.cdlLabel .. "  " .. S:Wrap("DIM", counts[key]))
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
    -- (an empty list: what to do next, illustrated)
    if empty then
        view.list:SetEmptyState({ glyph = UI().ICON.team or UI().ICON.notes, text = empty })
    else
        view.list:SetEmptyState(nil)
    end
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
        setSearch(H.Short(key))
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
        setSearch(H.Short(key))
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
        Print("%s is in the guild: the guest book is for players outside it.", H.Short(key))
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
        tt:AddLine("DisasterZone: on the raid blacklist", S:RGB("BAD"))
        if manager then
            if e.reason then tt:AddLine(e.reason, 1, 0.65, 0.65, true) end
            if e.by then
                tt:AddLine(("Added by %s%s"):format(H.Short(e.by), e.at and (" on " .. date("%d %b", e.at)) or ""),
                    S:Color("SUB"))
            end
        end
        return true
    end
    if manager and outsider then
        local s = GB() and GB().Summary and GB():Summary(key)
        if s then
            tt:AddLine("DisasterZone guest: " .. s, S.C.YOU[1], S.C.YOU[2], S.C.YOU[3], true)
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

-- "Add to Recruitment" (or "Recruitment..." for someone already there) for the GM and officers, for players outside
-- the guild (UI/Recruit.lua). unit: the menu's unit, for the class and level.
function H.RecruitButton(root, key, unit)
    local Rc = ns.Recruit
    if not (Rc and Rc.CanUse and Rc:CanUse()) or inGuild(key) or not ns.RecruitUI then return end
    if Rc:Get(key) then
        root:CreateButton(iconText(UI().ICON.team or 46) .. "  Recruitment...", function() ns.RecruitUI:Open(key) end)
    else
        root:CreateButton(iconText(UI().ICON.team or 46) .. "  " .. S:Wrap("GOLD", "Add to Recruitment"),
            function() ns.RecruitUI:AddFrom(key, "whisper", unit) end)
    end
end

function GuestUI:ModifyPlayerMenu(root, contextData)
    local recruiter = ns.Recruit and ns.Recruit.CanUse and ns.Recruit:CanUse()
    if not root or not (isManager() or recruiter) then return end
    local key = MenuPlayer(contextData)
    if not key or ns.Util.IsMe(key) then return end
    if root.CreateDivider then root:CreateDivider() end
    if root.CreateTitle then root:CreateTitle("DisasterZone") end
    if isManager() then
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
    H.RecruitButton(root, key, type(contextData) == "table" and contextData.unit or nil)
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
