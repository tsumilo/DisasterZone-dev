if DisasterZoneBoot and DisasterZoneBoot.Run("UI/GuestBook.lua", ...) then return end -- DisasterZone: UI/GuestBook.lua
-- The Guests window (1.3; the GM, officers and the raid leaders), two tabs:
--   Guest book - the players outside the guild who raided with us (Core/GuestBook.lua): raids, items, no-shows, an
--                upcoming guest seat, a note and a Recruit mark. Right-click: add to a raid, recruit, note,
--                blacklist, whisper.
--   Blacklist  - players who can't sign up for raids, be added as a guest or be invited (it was its own window).
-- And wherever a player shows up in the game:
--   the player tooltip says when they are on the raid blacklist (players outside the guild for everyone, guild
--   members only for the roster managers; the reason only for them), and what the guest book knows (roster managers);
--   the player right-click menus (unit frames, raid frames, chat names) get "Blacklist..." and "Guest book..." for
--   the roster managers (Menu.ModifyMenu, when the client has it).
local addonName, ns = ...

local GuestUI = ns:NewModule("GuestBookUI")

local tsort, tconcat = table.sort, table.concat

local DAY = 86400
local ADD_AHEAD = 14 * DAY         -- the raids a guest can be added to from the book: the next two weeks
local MENU_TAGS = { "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_RAID",
                    "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS", "MENU_UNIT_FRIEND", "MENU_UNIT_ENEMY_PLAYER" }

local state = { tab = "book", search = "", recruits = false }
local win

local function UI() return ns.UI end
local function RP() return ns.RaidPlan end
local function GB() return ns.GuestBook end
local function Util() return ns.Util end

local function Print(...) ns:Print(...) end

local function grey(text) return "|cff808080" .. tostring(text) .. "|r" end

local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

local function nameLess(a, b) return shortName(a):lower() < shortName(b):lower() end

local function hideTooltip() GameTooltip:Hide() end

local function isManager()
    local R = RP()
    return (R and R.CanManageRoster and R:CanManageRoster()) and true or false
end

-- Awarded items are loot council data (the GM and the guild council), as in the Raid log.
local function seesItems()
    local G = ns.Guild
    local demo = ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
    return (demo or (G and G.IsGuildCouncil and G:IsGuildCouncil(ns.Util.PlayerKey()))) and true or false
end

local function specText(c, sp)
    local spec = c and sp and ns.SPECS and ns.SPECS[c] and ns.SPECS[c][sp]
    local cls = c and ns.CLASS_NAMES and ns.CLASS_NAMES[c] or ""
    return spec and (spec.label .. " " .. cls) or cls
end

local function whisper(key)
    local name = (Ambiguate and Ambiguate(key, "none")) or shortName(key)
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if open then open("/w " .. name .. " ") end
end

---------------------------------------------------------------------------
-- Guest book: rows, tooltip, menu
---------------------------------------------------------------------------

local function bookTooltip(owner, e)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(UI():ColoredName(e.key, e.c))
    local st = specText(e.c, e.sp)
    if st ~= "" then GameTooltip:AddLine(st, 0.8, 0.8, 0.8) end
    if e.blacklisted then
        local b = e.blacklist or {}
        GameTooltip:AddLine("On the raid blacklist" .. (b.reason and (": " .. b.reason) or ""), 1, 0.25, 0.25, true)
    end
    if e.recruit then GameTooltip:AddLine("Recruit", 0.2, 1, 0.2) end
    if e.note then
        GameTooltip:AddLine('"' .. e.note .. '"', 1, 1, 1, true)
        if e.noteBy then
            GameTooltip:AddLine(("Note by %s%s"):format(shortName(e.noteBy),
                e.noteAt and (" on " .. date("%d %b", e.noteAt)) or ""), 0.6, 0.6, 0.6)
        end
    end
    if e.next then
        GameTooltip:AddLine(("Guest of %s, %s"):format(e.next.name, date("%a %d %b %H:%M", e.next.t)), 0.4, 0.8, 1)
    end
    if e.raids > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(("%d raid%s with us, %d boss kill%s"):format(e.raids, e.raids == 1 and "" or "s", e.kills,
            e.kills == 1 and "" or "s"), 1, 0.82, 0)
        for _, z in ipairs(e.zones) do
            GameTooltip:AddDoubleLine(date("%a %d %b", z.at) .. "  " .. (z.zone or "?"),
                ("%d/%d bosses%s"):format(z.kills or 0, z.bosses or 0, z.bench and ", bench" or ""), 1, 1, 1, 0.7, 0.7, 0.7)
        end
        if e.raids > #e.zones then GameTooltip:AddLine(("... and %d more"):format(e.raids - #e.zones), 0.6, 0.6, 0.6) end
    end
    if e.noShows > 0 then
        GameTooltip:AddLine(("Signed up and did not come: %d time%s"):format(e.noShows, e.noShows == 1 and "" or "s"),
            1, 0.5, 0.5)
    end
    if seesItems() and e.items > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(("%d item%s received"):format(e.items, e.items == 1 and "" or "s"), 1, 0.82, 0)
        for i, it in ipairs(e.itemList) do
            if i > 6 then break end
            GameTooltip:AddDoubleLine(UI():ItemText(it.i), date("%d %b", it.ts), 1, 1, 1, 0.7, 0.7, 0.7)
        end
    end
    GameTooltip:AddLine("Right-click for options", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

-- The raids of the next two weeks I may add guests to (locked ones too: they are listed for the roster managers),
-- with the player not on them yet.
local function addableRaids(key)
    local R = RP()
    local out = {}
    if not (R and R.GetRaids and R.CanManageRoster and R:CanManageRoster()) then return out end
    local now = GetServerTime()
    local signups
    for _, v in ipairs(R:GetRaids(now - 6 * 3600, now + ADD_AHEAD)) do
        if not v.cancelled and R:CanManageRoster(v) then
            signups = R:GetSignups(v.id)
            if not signups[key] then out[#out + 1] = v end
        end
    end
    return out
end

function GuestUI:OpenEntryMenu(owner, e)
    if type(e) ~= "table" then return end
    local key = e.key
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(shortName(key))
        local raids = addableRaids(key)
        if #raids > 0 and not e.blacklisted then
            local sub = root:CreateButton("Add as a guest to")
            for _, v in ipairs(raids) do
                local id = v.id
                local label = ("%s  %s"):format(date("%a %d %b %H:%M", v.t), RP():GetRaidName(v))
                if e.c then
                    sub:CreateButton(label, function() GuestUI:AddToRaid(key, id) end)
                else
                    local b = sub:CreateButton(label .. grey(" (class unknown)"), function() end)
                    if b and b.SetEnabled then b:SetEnabled(false) end
                end
            end
        end
        root:CreateButton(e.recruit and "Not a recruit" or "Mark as recruit", function()
            local ok, err = GB():SetNote(key, nil, not e.recruit)
            if not ok then Print("%s", tostring(err)) end
        end)
        root:CreateButton(e.note and "Change the note..." or "Add a note...", function() GuestUI:EditNote(key) end)
        if e.note then
            root:CreateButton("Clear the note", function()
                local ok, err = GB():SetNote(key, false)
                if not ok then Print("%s", tostring(err)) end
            end)
        end
        if e.blacklisted then
            root:CreateButton("On the blacklist...", function() GuestUI:OpenBlacklist(e.blacklist and e.blacklist.key or key) end)
        else
            root:CreateButton("Blacklist...", function() GuestUI:OpenBlacklist(key) end)
        end
        root:CreateButton("Whisper", function() whisper(key) end)
    end)
end

-- Adds the player as a guest of a planned raid with the class / spec the guest book knows.
function GuestUI:AddToRaid(key, occId)
    local e = GB():GetEntry(key)
    local c, sp = GB():GetSpec(key)
    if e and e.c and c ~= e.c then c, sp = e.c, nil end   -- (the class last seen in a raid wins)
    local ok, err = RP():AddGuest(occId, key, c, sp)
    if not ok then
        Print("%s", tostring(err))
        return false
    end
    local v = RP():GetRaid(occId)
    Print("%s is a guest of %s.", shortName(key), v and RP():GetRaidName(v) or "the raid")
    return true
end

-- One line per player, in columns: the name (class colour; the spec is in the tooltip), what we know (blacklisted,
-- Recruit, a note, their next guest seat), raids with us, the last one, items (loot council) and no-shows. The
-- tooltip has the details (the note itself, every raid, the items).
local BOOK_ROW_H = 22
local COL = { name = 6, status = 160, raids = 366, last = 412, items = 482, noShows = 530 }
local COL_W = { name = 150, status = 200, raids = 40, last = 64, items = 40, noShows = 60 }

local function statusText(e)
    local parts = {}
    if e.blacklisted then parts[#parts + 1] = "|cffff4040Blacklisted|r" end
    if e.recruit then parts[#parts + 1] = "|cff33ff33Recruit|r" end
    if e.note then parts[#parts + 1] = grey("Note") end
    if e.next then parts[#parts + 1] = "|cff66ccffGuest " .. date("%a %d %b", e.next.t) .. "|r" end
    return tconcat(parts, grey(" · "))
end

local function initBookRow(row, e)
    if not row.cdlInit then
        row.cdlInit = true
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.06)
        local function cell(key, font, justify)
            local fs = row:CreateFontString(nil, "OVERLAY", font)
            fs:SetPoint("LEFT", COL[key], 0)
            fs:SetWidth(COL_W[key])
            fs:SetJustifyH(justify or "LEFT")
            fs:SetWordWrap(false)
            return fs
        end
        row.name = cell("name", "GameFontHighlight")
        row.status = cell("status", "GameFontHighlightSmall")
        row.raids = cell("raids", "GameFontHighlightSmall", "CENTER")
        row.last = cell("last", "GameFontHighlightSmall")
        row.items = cell("items", "GameFontHighlightSmall", "CENTER")
        row.noShows = cell("noShows", "GameFontHighlightSmall", "CENTER")
        row:SetScript("OnEnter", function(self) if self.__cdlData then bookTooltip(self, self.__cdlData) end end)
        row:SetScript("OnLeave", hideTooltip)
        row:SetScript("OnClick", function(self)
            if self.__cdlData then GuestUI:OpenEntryMenu(self, self.__cdlData) end
        end)
    end
    row.name:SetText(UI():ColoredName(e.key, e.c))
    row.status:SetText(statusText(e))
    row.raids:SetText(e.raids > 0 and tostring(e.raids) or grey("-"))
    row.last:SetText(e.raids > 0 and date("%d %b", e.last) or "")
    row.items:SetShown(seesItems())
    row.items:SetText(e.items > 0 and tostring(e.items) or "")
    row.noShows:SetText(e.noShows > 0 and ("|cffff8080" .. e.noShows .. "|r") or "")
end

---------------------------------------------------------------------------
-- Blacklist page
---------------------------------------------------------------------------

local function initBlackRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row.fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.fs:SetPoint("LEFT", 6, 0)
        row.fs:SetWidth(130)
        row.fs:SetJustifyH("LEFT")
        row.fs:SetWordWrap(false)
        row.remove = UI():CreateRemoveButton(row, "Take off the blacklist")
        row.remove:SetPoint("RIGHT", -4, 0)
        row.remove:SetScript("OnClick", function(self)
            local data = self:GetParent().__cdlData
            if data then GuestUI:Unblacklist(data.key) end
        end)
        row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.note:SetPoint("LEFT", 140, 0)
        row.note:SetPoint("RIGHT", row.remove, "LEFT", -4, 0)
        row.note:SetJustifyH("LEFT")
        row.note:SetWordWrap(false)
        row:SetScript("OnEnter", function(self)
            local data = self.__cdlData
            if not data then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(UI():ColoredName(data.key))
            GameTooltip:AddLine(data.reason or "No reason given.", 1, 1, 1, true)
            if data.by then
                GameTooltip:AddLine(("Added by %s%s"):format(shortName(data.by),
                    data.at and (" on " .. date("%d %b %Y", data.at)) or ""), 0.7, 0.7, 0.7)
            end
            if data.alts and #data.alts > 0 then
                GameTooltip:AddLine("Also blocked: " .. tconcat(data.alts, ", "), 0.7, 0.7, 0.7, true)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", hideTooltip)
    end
    row.fs:SetText(UI():ColoredName(d.key))
    row.note:SetText(d.reason or grey("no reason given"))
end

local function createBlackPage(parent)
    local w = CreateFrame("Frame", nil, parent)
    w:SetAllPoints(parent)
    w.info = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.info:SetPoint("TOPLEFT", 10, -4)
    w.info:SetPoint("RIGHT", -10, 0)
    w.info:SetJustifyH("LEFT")
    w.info:SetText("Players on this list can't sign up for raids, can't be added as a guest and are not invited. "
        .. "For a guild member it covers all their characters.")
    w.nameBox = UI():CreateSleekEditBox(w)
    w.nameBox:SetSize(110, 20)
    w.nameBox:SetAutoFocus(false)
    w.nameBox:SetMaxLetters(48)
    w.nameBox:SetPoint("TOPLEFT", 14, -52)
    w.nameBox:SetScript("OnEnterPressed", function() w.reasonBox:SetFocus() end)
    w.nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local nameHint = w:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    nameHint:SetPoint("BOTTOMLEFT", w.nameBox, "TOPLEFT", 0, 2)
    nameHint:SetText("Character name")
    w.reasonBox = UI():CreateSleekEditBox(w)
    w.reasonBox:SetSize(260, 20)
    w.reasonBox:SetAutoFocus(false)
    w.reasonBox:SetMaxLetters(80)
    w.reasonBox:SetPoint("LEFT", w.nameBox, "RIGHT", 10, 0)
    w.reasonBox:SetScript("OnEnterPressed", function() GuestUI:AddBlacklist() end)
    w.reasonBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local reasonHint = w:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    reasonHint:SetPoint("BOTTOMLEFT", w.reasonBox, "TOPLEFT", 0, 2)
    reasonHint:SetText("Reason (only the raid leaders and officers see it)")
    w.addBtn = UI():CreateSleekButton(w, "Add", 48, 22, function() GuestUI:AddBlacklist() end, "primary")
    w.addBtn:SetPoint("LEFT", w.reasonBox, "RIGHT", 6, 0)
    w.err = w:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    w.err:SetPoint("TOPLEFT", 12, -78)
    w.err:SetPoint("RIGHT", -10, 0)
    w.err:SetJustifyH("LEFT")
    w.list = UI():CreateScrollList(w, 22, initBlackRow)
    w.list.frame:SetPoint("TOPLEFT", 4, -96)
    w.list.frame:SetPoint("BOTTOMRIGHT", -4, 4)
    w.list:SetEmptyText("Nobody is blacklisted.")
    return w
end

---------------------------------------------------------------------------
-- Guest book page
---------------------------------------------------------------------------

local function createBookPage(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    p.search = UI():CreateSearchBox(p, 170, function(text)
        state.search = text or ""
        GuestUI:Refresh()
    end, "Search names")
    p.search:SetPoint("TOPLEFT", 14, -4)
    p.recruits = UI():CreateCheckbox(p, "Recruits only", function() return state.recruits end, function(on)
        state.recruits = on and true or false
        GuestUI:Refresh()
    end)
    p.recruits:SetPoint("LEFT", p.search, "RIGHT", 10, 0)
    -- a player not in the book yet (met in trade chat, a friend of a member): a note or a Recruit mark adds them
    p.nameBox = UI():CreateSleekEditBox(p)
    p.nameBox:SetSize(120, 22)
    p.nameBox:SetMaxLetters(48)
    p.nameBox:SetPoint("TOPRIGHT", -58, -4)
    p.nameBox:SetScript("OnEnterPressed", function(self) GuestUI:EditNote(self:GetText()) end)
    UI():SetEditPlaceholder(p.nameBox, "Add a player")
    p.addBtn = UI():CreateSleekButton(p, "Add", 48, 22, function() GuestUI:EditNote(p.nameBox:GetText()) end)
    p.addBtn:SetPoint("LEFT", p.nameBox, "RIGHT", 4, 0)
    p.addBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Add a player")
        GameTooltip:AddLine("A player outside the guild who has not raided with us yet: write a note on them (or "
            .. "mark them as a recruit from the list afterwards).", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    p.addBtn:HookScript("OnLeave", hideTooltip)

    p.header = UI():CreateColumnHeader(p, 18)
    p.header:SetPoint("TOPLEFT", 4, -34)
    p.header:SetPoint("TOPRIGHT", -24, -34)
    p.header:AddColumn("Player", COL.name, COL_W.name)
    p.header:AddColumn("Status", COL.status, COL_W.status)
    p.header:AddColumn("Raids", COL.raids, COL_W.raids, { justify = "CENTER" })
    p.header:AddColumn("Last raid", COL.last, COL_W.last)
    p.itemsHeader = p.header:AddColumn("Items", COL.items, COL_W.items, { justify = "CENTER" })
    p.header:AddColumn("No-shows", COL.noShows, COL_W.noShows, { justify = "CENTER" })
    p.list = UI():CreateScrollList(p, BOOK_ROW_H, initBookRow)
    p.list.frame:SetPoint("TOPLEFT", 4, -54)
    p.list.frame:SetPoint("BOTTOMRIGHT", -4, 22)
    p.list:SetEmptyText("Nobody yet. Players outside the guild who raid with us show up here, with their raids.")
    p.count = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.count:SetPoint("BOTTOMLEFT", 10, 6)
    p.count:SetJustifyH("LEFT")
    return p
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local function create()
    local w = UI():CreateWindow("DisasterZoneGuests", "Guests", 640, 440)
    win = w
    local c = w.content
    local function tab(label, key)
        return UI():CreateUnderlineTab(c, label, function() GuestUI:SetTab(key) end)
    end
    w.bookTab = tab("Guest book", "book")
    w.bookTab:SetPoint("TOPLEFT", 4, -6)
    w.blackTab = tab("Blacklist", "black")
    w.blackTab:SetPoint("LEFT", w.bookTab, "RIGHT", 4, 0)
    w.pages = CreateFrame("Frame", nil, c)
    w.pages:SetPoint("TOPLEFT", 0, -34)
    w.pages:SetPoint("BOTTOMRIGHT", 0, 0)
    w.book = createBookPage(w.pages)
    w.black = createBlackPage(w.pages)
    w:Hide()
    return w
end

local function ensure()
    return win or create()
end

function GuestUI:GetWindow() return win end
function GuestUI:GetBlacklistPage() return win and win.black or nil end
function GuestUI:GetBookPage() return win and win.book or nil end

function GuestUI:SetTab(tab)
    state.tab = tab == "black" and "black" or "book"
    self:Refresh()
end

-- Opens the window on its last tab (the Raids tab's Guests button). Roster managers only.
function GuestUI:Open(tab)
    if not isManager() then
        Print("Only the Guild Master, officers and the raid leaders keep the guest book and the "
            .. "blacklist.")
        return false
    end
    local w = ensure()
    if tab then state.tab = tab end
    w:Show()
    w:Raise()
    self:Refresh()
    return true
end

-- The guest book filtered to one player (a player menu's "Guest book..."); not in the book yet: their note.
function GuestUI:OpenGuest(key)
    if not self:Open("book") then return false end
    key = type(key) == "string" and ns.Util.NormalizeName(key) or nil
    if not key then return true end
    state.search = shortName(key)
    win.book.search:SetText(state.search)
    self:Refresh()
    if not GB():GetEntry(key) then self:EditNote(key) end
    return true
end

-- The Blacklist tab; key (optional) = a player to put in the name box.
function GuestUI:OpenBlacklist(key)
    if not self:Open("black") then return false end
    local b = win.black
    b.err:SetText("")
    b.nameBox:SetText(key and shortName(key) or "")
    b.fullKey = key
    b.reasonBox:SetText("")
    if key then b.reasonBox:SetFocus() end
    self:Refresh()
    return true
end

-- Blacklists the player typed on the Blacklist tab (or the one given), with the reason.
function GuestUI:AddBlacklist(name, reason)
    local b = win and win.black
    if not b then return false end
    name = name or b.nameBox:GetText()
    -- the name box shows the short name of a player picked from a roster: keep their realm
    if b.fullKey and shortName(b.fullKey) == ns.Util.Trim(name or "") then name = b.fullKey end
    local ok, err = RP():SetBlacklisted(name, reason or b.reasonBox:GetText())
    if not ok then
        b.err:SetText(err or "Could not blacklist that player.")
        return false
    end
    b.err:SetText("")
    b.nameBox:SetText("")
    b.reasonBox:SetText("")
    b.fullKey = nil
    b.nameBox:ClearFocus()
    b.reasonBox:ClearFocus()
    self:Refresh()
    return true
end

function GuestUI:Unblacklist(key)
    local ok, err = RP():RemoveBlacklisted(key)
    if not ok then Print(err or "Could not take that player off the blacklist.") end
    self:Refresh()
    return ok and true or false
end

-- The note popup for a player (a key, or a name typed in the window).
function GuestUI:EditNote(name)
    if type(name) ~= "string" or ns.Util.Trim(name) == "" then
        Print("Type the character name first.")
        return false
    end
    local key = ns.Util.NormalizeName(ns.Util.Trim(name))
    if not key then return false end
    local G = ns.Guild
    if G and G.IsInGuild and G:IsInGuild(key, true) then
        Print("%s is in the guild: the guest book is for players outside it.", shortName(key))
        return false
    end
    if type(StaticPopup_Show) ~= "function" then return false end
    local cur = GB():GetNote(key)
    StaticPopup_Show("DISASTERZONE_GUEST_NOTE", shortName(key), nil, { key = key, note = cur and cur.note or "" })
    return true
end

local function saveNote(data, text)
    if type(data) ~= "table" or not data.key then return end
    local ok, err = GB():SetNote(data.key, text or false)
    if not ok then Print("%s", tostring(err)) return end
    if win and win.book then
        win.book.nameBox:SetText("")
        win.book.nameBox:ClearFocus()
    end
end

local function bookRows()
    local out = {}
    local q = ns.Util.Trim(state.search or ""):lower()
    for _, e in ipairs(GB():GetEntries()) do
        if (not state.recruits or e.recruit) and (q == "" or shortName(e.key):lower():find(q, 1, true)) then
            out[#out + 1] = e
        end
    end
    return out
end

function GuestUI:Refresh()
    if not win or not win:IsShown() then return end
    if not isManager() then
        win:Hide()
        return
    end
    local book = state.tab ~= "black"
    win.bookTab:SetActive(book)
    win.blackTab:SetActive(not book)
    win.book:SetShown(book)
    win.black:SetShown(not book)
    if book then
        local rows = bookRows()
        local all = GB():GetEntries()
        local recruits = 0
        for _, e in ipairs(all) do if e.recruit then recruits = recruits + 1 end end
        win.book.itemsHeader:SetShown(seesItems())
        win.book.count:SetText(("%d player%s · %d recruit%s · newest first; hover for their raids, right-click for "
            .. "options"):format(#all, #all == 1 and "" or "s", recruits, recruits == 1 and "" or "s"))
        win.book.list:SetData(rows)
        if win.book.recruits.Refresh then win.book.recruits:Refresh() end
    else
        local G = ns.Guild
        local rows = RP():GetBlacklist()
        for _, d in ipairs(rows) do
            d.alts = {}
            for _, alt in ipairs(G and G.GetLinkedCharacters and G:GetLinkedCharacters(d.key) or {}) do
                d.alts[#d.alts + 1] = shortName(alt)
            end
        end
        tsort(rows, function(a, b) return nameLess(a.key, b.key) end)
        win.black.list:SetData(rows)
    end
end

function GuestUI:RequestRefresh()
    if win and win:IsShown() then ns.Util.Debounce("guestbook-ui", 0.2, function() GuestUI:Refresh() end) end
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
                           "ROSTER_UPDATED", "RAIDLOG_CHANGED", "LEDGER_UPDATED" }) do
        ns:On(msg, function() GuestUI:RequestRefresh() end)
    end
    if StaticPopupDialogs then
        local function editBox(popup) return (popup.GetEditBox and popup:GetEditBox()) or popup.editBox end
        StaticPopupDialogs["DISASTERZONE_GUEST_NOTE"] = {
            text = "Note on %s (the raid leaders and officers see it; empty clears it):",
            button1 = SAVE or "Save",
            button2 = CANCEL or "Cancel",
            hasEditBox = 1,
            maxLetters = 60,
            OnShow = function(self, data)
                local eb = editBox(self)
                data = data or self.data
                if eb then
                    eb:SetText(type(data) == "table" and data.note or "")
                    eb:SetFocus()
                end
            end,
            OnAccept = function(self, data)
                local eb = editBox(self)
                saveNote(data or self.data, eb and eb:GetText())
            end,
            EditBoxOnEnterPressed = function(eb)
                local popup = eb:GetParent()
                saveNote(popup and popup.data, eb:GetText())
                if popup then popup:Hide() end
            end,
            EditBoxOnEscapePressed = function(eb)
                local popup = eb:GetParent()
                if popup then popup:Hide() end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    if GameTooltip and GameTooltip.HookScript then GameTooltip:HookScript("OnTooltipSetUnit", OnTooltipSetUnit) end
    if Menu and type(Menu.ModifyMenu) == "function" then
        for _, tag in ipairs(MENU_TAGS) do
            Menu.ModifyMenu(tag, function(_, root, contextData) GuestUI:ModifyPlayerMenu(root, contextData) end)
        end
    end
end
