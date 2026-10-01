if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Members.lua", ...) then return end -- DisasterZone: "Members" tab (everyone).
-- The guild's members with what their DisasterZone shares (Core/Professions.lua): professions and recipes, main and off
-- spec (primary / secondary talents), and which characters belong to one player. Two views:
--   Roster  - every guild member: online state, level, specs, professions; alts sit under their main. A member's
--             detail lists their characters, professions and recipes, and for officers the officer note
--             (Core/OfficerNotes.lua)
--   Recipes - every recipe somebody knows, searchable; a recipe's detail lists who can make it, online first
-- The profession icons on top filter both views (and show how many members have each profession).
local addonName, ns = ...

local MembersUI = ns:NewModule("MembersUI")

local LIST_W = 392
local TOP = 74                  -- the lists start below the toolbar and the profession icons
local CHIP = 28
local NOTE_H = 66               -- the officer note under a member's detail
local GOLD = { 1, 0.82, 0 }
local STATUS_COLOR = {
    online = { 0.2, 0.9, 0.2 }, afk = { 1, 0.8, 0.1 }, dnd = { 1, 0.5, 0.1 }, offline = { 0.75, 0.2, 0.2 },
}
local STATUS_TEXT = { online = "|cff33ff33Online|r", afk = "|cffffcc1aAway|r", dnd = "|cffff801aDo not disturb|r",
                      offline = "|cff808080Offline|r" }

local state = { mode = "roster", prof = nil, search = "", member = nil, recipe = nil, open = {} }
local panel

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

local function P() return ns.Professions end
local function G() return ns.Guild end
local function N() return ns.OfficerNotes end

local function grey(text) return "|cff808080" .. tostring(text) .. "|r" end
local function gold(text) return "|cffffd100" .. tostring(text) .. "|r" end

local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

local function isOnline(key)
    local g = G()
    return (g and g:IsOnline(key)) and true or false
end

-- "online" | "afk" | "dnd" | "offline"
local function statusOf(key)
    if not isOnline(key) then return "offline" end
    if ns.Util.IsMe(key) then
        if UnitIsAFK and UnitIsAFK("player") then return "afk" end
        if UnitIsDND and UnitIsDND("player") then return "dnd" end
        return "online"
    end
    local m = G() and G():GetMember(key)
    local s = m and m.status
    return s == 1 and "afk" or (s == 2 and "dnd" or "online")
end

local function setDot(texture, status)
    local c = STATUS_COLOR[status] or STATUS_COLOR.offline
    texture:SetColorTexture(c[1], c[2], c[3])
end

local function classOf(key)
    local g = G()
    local classFile = g and g:GetClass(key)
    if not classFile and ns.Util.IsMe(key) and UnitClass then classFile = select(2, UnitClass("player")) end
    return classFile
end

local function levelOf(key)
    local m = G() and G():GetMember(key)
    local level = m and tonumber(m.level)
    if not level and ns.Util.IsMe(key) and UnitLevel then level = tonumber(UnitLevel("player")) end
    return level
end

-- Name and icon of a class's talent tab ("Feral" for both druid feral specs).
local function tabInfo(classFile, tab)
    for i, sp in ipairs(ns.SPECS and classFile and ns.SPECS[classFile] or {}) do
        if sp.tab == tab then
            local label = sp.label:gsub(" %(.-%)$", "")
            return label, ns.RaidComp and ns.RaidComp.SpecIcon and ns.RaidComp:SpecIcon(classFile, i) or nil
        end
    end
    return "Tab " .. tostring(tab), nil
end

-- Name and icon of a spec from Professions:GetSpecs: the spec picked in My BiS, else the talent tab.
local function specInfo(classFile, spec)
    local def = spec.sp and ns.SPECS and classFile and ns.SPECS[classFile] and ns.SPECS[classFile][spec.sp]
    if def then
        return def.label, ns.RaidComp and ns.RaidComp.SpecIcon and ns.RaidComp:SpecIcon(classFile, spec.sp) or nil
    end
    return tabInfo(classFile, spec.tab)
end

-- "Combat 0/42/19" (the points when a talent set of theirs is in that tab)
local function specText(classFile, spec)
    local label = specInfo(classFile, spec)
    return spec.points and ("%s %s"):format(label, grey(table.concat(spec.points, "/"))) or label
end

local function specName(spell)
    local name = spell and GetSpellInfo and GetSpellInfo(spell)
    return type(name) == "string" and name or nil
end

local function profEntry(profs, id)
    for _, e in ipairs(profs or {}) do
        if e.id == id then return e end
    end
    return nil
end

local function recipeCountText(e)
    local def = P():GetProfession(e.id)
    if not (def and def.crafts) then return "" end
    if e.total == 0 then return grey("recipes not shared yet") end
    if not e.synced then return grey(("%d / %d recipes arriving"):format(e.recipes, e.total)) end
    return e.recipes .. (e.recipes == 1 and " recipe" or " recipes")
end

-- The player's character that is online right now: `key` itself, else one of their other characters, else nil.
local function onlineCharacter(key)
    if isOnline(key) then return key end
    for _, other in ipairs(P():GetOtherCharacters(key)) do
        if isOnline(other) then return other end
    end
    return nil
end

local function whisper(key, recipe)
    local name = (Ambiguate and Ambiguate(key, "none")) or shortName(key)
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if not open then return end
    open("/w " .. name .. " " .. (recipe and (P():GetRecipeLink(recipe) .. " ") or ""))
end

local function linkRecipe(recipe)
    local link = P():GetRecipeLink(recipe)
    local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
    if insert and insert(link) then return end
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if open then open(link) end
end

-- Crafters of a recipe: reachable now first (online, or their player is on another character), then by skill.
local function sortedCrafters(recipe)
    local out = {}
    for _, key in ipairs(recipe.crafters) do
        local e = profEntry(P():GetMember(key), recipe.prof)
        local on = onlineCharacter(key)
        out[#out + 1] = { key = key, online = on ~= nil, via = on ~= key and on or nil, rank = e and e.rank or 0,
                          spec = e and e.spec }
    end
    table.sort(out, function(a, b)
        if a.online ~= b.online then return a.online end
        if (a.via == nil) ~= (b.via == nil) then return a.via == nil end
        if a.rank ~= b.rank then return a.rank > b.rank end
        return shortName(a.key):lower() < shortName(b.key):lower()
    end)
    return out
end

-- The recipe's own tooltip (name, reagents) on tt. Returns true when it has lines.
local function setRecipeSpell(tt, spell)
    if pcall(tt.SetHyperlink, tt, "enchant:" .. spell) and tt:NumLines() > 0 then return true end
    if tt.SetSpellByID and pcall(tt.SetSpellByID, tt, spell) and tt:NumLines() > 0 then return true end
    return false
end

-- The item (or enchant) tooltip, the reagents next to it for an item, and who makes it.
local reagentTip
local function showRecipeTooltip(owner, recipe)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if recipe.item > 0 then
        if ns.Tooltip then ns.Tooltip.skipCrafters = true end   -- the crafters are listed below
        GameTooltip:SetItemByID(recipe.item)
        if ns.Tooltip then ns.Tooltip.skipCrafters = nil end
    elseif not setRecipeSpell(GameTooltip, recipe.spell) then
        GameTooltip:AddLine(recipe.name, 1, 0.82, 0)
    end
    local names, online = {}, 0
    for i, c in ipairs(sortedCrafters(recipe)) do
        if c.online then online = online + 1 end
        if i <= 6 then names[#names + 1] = c.online and ns.UI:ColoredName(c.key) or grey(shortName(c.key)) end
    end
    local more = #recipe.crafters - #names
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("Made by %d in the guild (%d online)"):format(#recipe.crafters, online), 1, 0.82, 0)
    GameTooltip:AddLine(table.concat(names, ", ") .. (more > 0 and grey(" +" .. more) or ""), 1, 1, 1, true)
    GameTooltip:Show()
    if recipe.item > 0 then
        if not reagentTip then
            reagentTip = CreateFrame("GameTooltip", "DisasterZoneRecipeTooltip", UIParent, "GameTooltipTemplate")
        end
        reagentTip:SetOwner(GameTooltip, "ANCHOR_NONE")
        reagentTip:ClearAllPoints()
        reagentTip:SetPoint("TOPLEFT", GameTooltip, "TOPRIGHT", 2, 0)
        if setRecipeSpell(reagentTip, recipe.spell) then
            reagentTip:Show()
        else
            reagentTip:Hide()
        end
    end
end

local function hideRecipeTooltip()
    GameTooltip:Hide()
    if reagentTip then reagentTip:Hide() end
end

local function addRowTextures(row)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.4)
    row.hl = hl
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(1, 0.82, 0, 0.12)
end

local function rowText(row, font, x, width)
    local fs = row:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("LEFT", x or 6, 0)
    if width then fs:SetWidth(width) end
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function rowIcon(row, size, x)
    local t = row:CreateTexture(nil, "ARTWORK")
    t:SetSize(size, size)
    t:SetPoint("LEFT", x, 0)
    t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    return t
end

----------------------------------------------------------------------------
-- Roster list (left, Roster view)
----------------------------------------------------------------------------

local NAME_X, ALT_INDENT = 20, 12
local LEVEL_X, SPEC_X = 130, 154
local PRIMARY_X = { 196, 246 }
local SECONDARY_X = { 298, 320, 342 }

local function rosterTooltip(row)
    local d = row.__cdlData
    if not d or not d.key then return end
    local level = levelOf(d.key)
    local lines = { ns.UI:ColoredName(d.key, d.classFile) .. (level and grey("  " .. level) or "") }
    lines[#lines + 1] = { STATUS_TEXT[d.status] or "", 1, 1, 1 }
    local main = P():GetMain(d.key)
    if main ~= d.key then
        lines[#lines + 1] = { "Alt of " .. ns.UI:ColoredName(main), 0.8, 0.8, 0.8 }
    end
    local on = onlineCharacter(d.key)
    if on and on ~= d.key then lines[#lines + 1] = { "Playing " .. ns.UI:ColoredName(on) .. " now", 0.2, 1, 0.2 } end
    for i, spec in ipairs(d.specs or {}) do
        lines[#lines + 1] = { (i == 1 and "Main spec: " or "Off spec: ") .. specText(d.classFile, spec), 1, 1, 1 }
    end
    if d.profs then
        for _, e in ipairs(d.profs) do
            local spec = specName(e.spec)
            lines[#lines + 1] = { ("%s  %d / %d%s"):format(P():GetName(e.id), e.rank, e.max, spec and ("  ·  " .. spec) or ""), 1, 1, 1 }
        end
        if #d.profs == 0 then lines[#lines + 1] = { "No professions.", 0.6, 0.6, 0.6 } end
    else
        lines[#lines + 1] = { "Nothing shared: this character has not logged in with a DisasterZone that shares it.",
                              0.6, 0.6, 0.6, wrap = true }
    end
    local note = N() and N():Get(d.key)
    if note then
        lines[#lines + 1] = { " " }
        lines[#lines + 1] = { "Officer note", 1, 0.82, 0 }
        lines[#lines + 1] = { note.text, 1, 1, 1, wrap = true }
    end
    ns.UI:SetTextTooltip(row, lines)
end

local function initRosterRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        addRowTextures(row)
        row.dot = row:CreateTexture(nil, "ARTWORK")
        row.dot:SetSize(8, 8)
        row.dot:SetPoint("LEFT", 6, 0)
        row.name = rowText(row, "GameFontHighlight", NAME_X, 108)
        row.level = rowText(row, "GameFontDisableSmall", LEVEL_X, 20)
        row.note = rowText(row, "GameFontDisableSmall", SPEC_X)
        row.sep = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.sep:SetPoint("CENTER")
        row.specs = { rowIcon(row, 16, SPEC_X), rowIcon(row, 14, SPEC_X + 19) }
        row.specs[2]:SetAlpha(0.75)
        row.slots = {}
        local function slot(x, withRank)
            local s = { icon = rowIcon(row, 18, x) }
            if withRank then
                s.rank = rowText(row, "GameFontHighlightSmall", x + 21, 28)
            end
            row.slots[#row.slots + 1] = s
            return s
        end
        row.primary = { slot(PRIMARY_X[1], true), slot(PRIMARY_X[2], true) }
        row.secondary = { slot(SECONDARY_X[1]), slot(SECONDARY_X[2]), slot(SECONDARY_X[3]) }
        row:SetScript("OnClick", function(self)
            local data = self.__cdlData
            if data and data.key then MembersUI:SelectMember(data.key) end
        end)
        row:SetScript("OnEnter", rosterTooltip)
        row:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    end
    for _, s in ipairs(row.slots) do
        s.icon:Hide()
        if s.rank then s.rank:SetText("") end
    end
    row.specs[1]:Hide()
    row.specs[2]:Hide()
    local isSep = d.kind == "sep"
    row.sep:SetText(isSep and d.text or "")
    row.hl:SetAlpha(isSep and 0 or 0.4)
    row.sel:SetShown(not isSep and d.key == state.member)
    row.dot:SetShown(not isSep)
    row.note:SetText("")
    row.level:SetText("")
    if isSep then
        row.name:SetText("")
        row:SetAlpha(1)
        return
    end
    setDot(row.dot, d.status)
    -- an alt sits indented under its main
    local indent = d.alt and ALT_INDENT or 0
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", NAME_X + indent, 0)
    row.name:SetWidth(108 - indent)
    row.name:SetText(ns.UI:ColoredName(d.key, d.classFile))
    row.level:SetText(d.level and tostring(d.level) or "")
    row:SetAlpha(d.status == "offline" and 0.6 or 1)
    for i, spec in ipairs(d.specs or {}) do
        local tex = row.specs[i]
        local _, icon = specInfo(d.classFile, spec)
        if tex and icon then
            tex:SetTexture(icon)
            tex:Show()
        end
    end
    if not d.profs then
        row.note:SetText("nothing shared yet")
        return
    end
    local pi, si = 0, 0
    for _, e in ipairs(d.profs) do
        local def = P():GetProfession(e.id)
        local s
        if def.primary then
            pi = pi + 1
            s = row.primary[pi]
        else
            si = si + 1
            s = row.secondary[si]
        end
        if s then
            s.icon:SetTexture(def.icon)
            s.icon:Show()
            if s.rank then
                s.rank:SetText(e.id == state.prof and gold(e.rank) or tostring(e.rank))
            end
        end
    end
end

local function memberRow(key)
    return { kind = "member", key = key, profs = P():GetMember(key), specs = P():GetSpecs(key), status = statusOf(key),
             classFile = classOf(key), level = levelOf(key), lower = shortName(key):lower() }
end

local function rosterRows()
    local g, prof = G(), P()
    local needle = state.search:lower()
    local with, without = {}, {}
    local keys = g and g.GetMembers and g:GetMembers() or {}
    local me = ns.Util.PlayerKey()
    local seen = {}
    for _, key in ipairs(keys) do seen[key] = true end
    if me and not seen[me] then keys[#keys + 1] = me end
    local flat = needle ~= "" or state.prof ~= nil
    for _, key in ipairs(keys) do
        if needle == "" or shortName(key):lower():find(needle, 1, true) then
            local d = memberRow(key)
            if not d.profs then
                if not state.prof then without[#without + 1] = d end
            elseif not state.prof then
                with[#with + 1] = d
            else
                local e = profEntry(d.profs, state.prof)
                if e then
                    d.sortRank = e.rank
                    with[#with + 1] = d
                end
            end
        end
    end
    local function byOnlineThenName(a, b)
        local ao, bo = a.status ~= "offline", b.status ~= "offline"
        if ao ~= bo then return ao end
        return a.lower < b.lower
    end
    local rows = {}
    if flat then
        table.sort(with, function(a, b)
            if state.prof and a.sortRank ~= b.sortRank then return a.sortRank > b.sortRank end
            return byOnlineThenName(a, b)
        end)
        rows = with
    else
        -- players: the main (or a character on its own) with its alts under it; a player counts as online while
        -- any of their characters is
        local groups, byMain = {}, {}
        for _, d in ipairs(with) do
            local main = prof:GetMain(d.key)
            local grp = byMain[main]
            if not grp then
                grp = { alts = {}, lower = shortName(main):lower(), online = false }
                byMain[main] = grp
                groups[#groups + 1] = grp
            end
            if d.key == main then grp.main = d else grp.alts[#grp.alts + 1] = d end
            if d.status ~= "offline" then grp.online = true end
        end
        table.sort(groups, function(a, b)
            if a.online ~= b.online then return a.online end
            return a.lower < b.lower
        end)
        for _, grp in ipairs(groups) do
            if grp.main then rows[#rows + 1] = grp.main end
            table.sort(grp.alts, byOnlineThenName)
            for _, d in ipairs(grp.alts) do
                d.alt = grp.main ~= nil
                rows[#rows + 1] = d
            end
        end
    end
    table.sort(without, byOnlineThenName)
    if #without > 0 then
        rows[#rows + 1] = { kind = "sep", text = ("%d without shared data"):format(#without) }
        for _, d in ipairs(without) do rows[#rows + 1] = d end
    end
    return rows
end

----------------------------------------------------------------------------
-- Recipe list (left, Recipes view)
----------------------------------------------------------------------------

local function initRecipeRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        addRowTextures(row)
        row.icon = rowIcon(row, 18, 6)
        row.name = rowText(row, "GameFontHighlightSmall", 30, 256)
        row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.count:SetPoint("RIGHT", -6, 0)
        row.count:SetJustifyH("RIGHT")
        row:SetScript("OnClick", function(self)
            local r = self.__cdlData and self.__cdlData.r
            if not r then return end
            if IsShiftKeyDown() then linkRecipe(r) else MembersUI:SelectRecipe(r.spell) end
        end)
        row:SetScript("OnEnter", function(self)
            local r = self.__cdlData and self.__cdlData.r
            if r then showRecipeTooltip(self, r) end
        end)
        row:SetScript("OnLeave", hideRecipeTooltip)
    end
    local r = d.r
    row.icon:SetTexture(P():GetRecipeIcon(r))
    row.name:SetText(r.name)
    local n = #r.crafters
    -- a recipe only one member knows is worth noticing
    row.count:SetText(n == 1 and gold("1 crafter") or grey(n .. " crafters"))
    row.sel:SetShown(r.spell == state.recipe)
end

local function recipeRows()
    local needle = state.search:lower()
    local rows = {}
    for _, r in ipairs(P():GetRecipes()) do
        if (not state.prof or r.prof == state.prof) and (needle == "" or r.lower:find(needle, 1, true)) then
            rows[#rows + 1] = { r = r }
        end
    end
    return rows
end

----------------------------------------------------------------------------
-- Detail list (right): one list with mixed rows
----------------------------------------------------------------------------

local ROW_H = { prof = 46, group = 20, recipe = 20, head = 26, note = 40, crafter = 28, char = 24, main = 30 }

local function detailExtent(d)
    return ROW_H[d.kind] or 20
end

-- "Which of my characters is my main": every character of this account that DisasterZone has seen in the guild.
local function mainMenu(owner)
    ns.UI:ContextMenu(owner, function(root)
        root:CreateTitle("My main character")
        local own = P():GetOwnCharacters()
        local current
        for _, key in ipairs(own) do
            if P():GetMain(key) ~= key then current = P():GetMain(key) end
        end
        for _, key in ipairs(own) do
            root:CreateRadio(shortName(key), function() return current == key end, function() P():SetMain(key) end)
        end
        root:CreateRadio("None: they are separate characters", function() return current == nil end,
            function() P():SetMain(nil) end)
    end)
end

local function detailWidgets(row)
    row.cdlInit = true
    addRowTextures(row)
    row.w = {}
    local w = row.w

    -- profession block
    w.profIcon = rowIcon(row, 30, 8)
    w.profName = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    w.profName:SetPoint("TOPLEFT", 46, -7)
    w.profSpec = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.profSpec:SetPoint("LEFT", w.profName, "RIGHT", 8, 0)
    w.bar = CreateFrame("StatusBar", nil, row)
    w.bar:SetSize(150, 8)
    w.bar:SetPoint("TOPLEFT", 46, -27)
    w.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    w.bar.bg = w.bar:CreateTexture(nil, "BACKGROUND")
    w.bar.bg:SetAllPoints()
    w.bar.bg:SetColorTexture(0, 0, 0, 0.5)
    w.barText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.barText:SetPoint("LEFT", w.bar, "RIGHT", 8, 0)
    w.chevron = row:CreateTexture(nil, "ARTWORK")
    w.chevron:SetSize(14, 14)
    w.chevron:SetPoint("RIGHT", -8, 0)
    w.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.right:SetPoint("RIGHT", -28, 0)
    w.right:SetJustifyH("RIGHT")

    -- recipe / group / heading / note lines
    w.icon = rowIcon(row, 16, 46)
    w.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.text:SetJustifyH("LEFT")
    w.text:SetJustifyV("MIDDLE")

    -- crafter / character line
    w.dot = row:CreateTexture(nil, "ARTWORK")
    w.dot:SetSize(8, 8)
    w.dot:SetPoint("LEFT", 10, 0)
    w.who = rowText(row, "GameFontHighlight", 26, 110)
    w.info = rowText(row, "GameFontHighlightSmall", 140)
    w.info:SetPoint("RIGHT", -84, 0)
    w.whisper = ns.UI:CreateSleekButton(row, "Whisper", 72, 20, function(self)
        local d = self:GetParent().__cdlData
        if d and d.key then whisper(d.via or d.key, d.recipe) end
    end)
    w.whisper:SetPoint("RIGHT", -6, 0)

    -- "my main" line
    w.mainBtn = ns.UI:CreateSleekButton(row, "Change", 72, 20, function(self) mainMenu(self) end)
    w.mainBtn:SetPoint("RIGHT", -6, 0)

    row:SetScript("OnClick", function(self)
        local d = self.__cdlData
        if not d then return end
        if d.kind == "prof" then
            if d.canOpen then
                state.open[d.id] = not state.open[d.id] or nil
                MembersUI:Refresh()
            end
        elseif d.kind == "recipe" then
            if IsShiftKeyDown() then linkRecipe(d.r) else MembersUI:ShowRecipe(d.r.spell) end
        elseif d.kind == "crafter" then
            MembersUI:ShowMember(d.key, d.recipe and d.recipe.prof)
        elseif d.kind == "char" then
            MembersUI:ShowMember(d.key)
        end
    end)
    row:SetScript("OnEnter", function(self)
        local d = self.__cdlData
        if d and d.kind == "recipe" then showRecipeTooltip(self, d.r) end
    end)
    row:SetScript("OnLeave", hideRecipeTooltip)
end

local function initDetailRow(row, d)
    if not row.cdlInit then detailWidgets(row) end
    local w = row.w
    local kind = d.kind
    local isProf, isPerson = kind == "prof", kind == "crafter" or kind == "char"
    w.profIcon:SetShown(isProf)
    w.profName:SetShown(isProf)
    w.profSpec:SetShown(isProf)
    w.bar:SetShown(isProf)
    w.barText:SetShown(isProf)
    w.chevron:SetShown(isProf and d.canOpen and true or false)
    w.right:SetShown(isProf)
    w.icon:SetShown(kind == "recipe")
    w.text:SetShown(not isProf and not isPerson)
    w.dot:SetShown(isPerson)
    w.who:SetShown(isPerson)
    w.info:SetShown(isPerson)
    w.whisper:SetShown(kind == "crafter" and d.canWhisper and true or false)
    w.mainBtn:SetShown(kind == "main" and d.canChange and true or false)
    row.sel:Hide()
    row.hl:SetAlpha((kind == "recipe" or isPerson or (isProf and d.canOpen)) and 0.4 or 0)

    if isProf then
        local def = P():GetProfession(d.id)
        local e = d.e
        w.profIcon:SetTexture(def.icon)
        w.profName:SetText(P():GetName(d.id))
        w.profSpec:SetText(specName(e.spec) or "")
        w.bar:SetMinMaxValues(0, math.max(e.max, 1))
        w.bar:SetValue(e.rank)
        if e.rank >= e.max and e.max > 0 then
            w.bar:SetStatusBarColor(1, 0.82, 0)
        else
            w.bar:SetStatusBarColor(0.75, 0.6, 0.15)
        end
        w.barText:SetText(("%d / %d"):format(e.rank, e.max))
        w.right:SetText(recipeCountText(e))
        w.chevron:SetTexture(state.open[d.id] and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
    elseif kind == "crafter" then
        setDot(w.dot, d.via and "afk" or d.status)
        w.who:SetText(ns.UI:ColoredName(d.key))
        local parts = {}
        if d.rank > 0 then parts[#parts + 1] = tostring(d.rank) end
        local spec = specName(d.spec)
        if spec then parts[#parts + 1] = spec end
        if d.via then
            parts[#parts + 1] = "|cff33ff33on " .. shortName(d.via) .. " now|r"
        elseif d.status == "offline" then
            parts[#parts + 1] = grey("offline")
        elseif d.status ~= "online" then
            parts[#parts + 1] = STATUS_TEXT[d.status]
        end
        w.info:SetText(table.concat(parts, "  ·  "))
    elseif kind == "char" then
        setDot(w.dot, d.status)
        w.who:SetText(ns.UI:ColoredName(d.key, d.classFile))
        local parts = { d.isMain and gold("Main") or "Alt" }
        if d.level then parts[#parts + 1] = "Level " .. d.level end
        for _, spec in ipairs(d.specs or {}) do parts[#parts + 1] = (specInfo(d.classFile, spec)) end
        w.info:SetText(table.concat(parts, "  ·  "))
    else
        w.text:ClearAllPoints()
        if kind == "recipe" then
            w.icon:SetTexture(P():GetRecipeIcon(d.r))
            w.text:SetFontObject("GameFontHighlightSmall")
            w.text:SetPoint("LEFT", 68, 0)
            w.text:SetPoint("RIGHT", -8, 0)
            w.text:SetWordWrap(false)
            w.text:SetText(d.r.name .. (#d.r.crafters == 1 and gold("   only crafter") or ""))
        elseif kind == "group" then
            w.text:SetFontObject("GameFontDisableSmall")
            w.text:SetPoint("LEFT", 46, 0)
            w.text:SetPoint("RIGHT", -8, 0)
            w.text:SetWordWrap(false)
            w.text:SetText(d.text)
        elseif kind == "head" then
            w.text:SetFontObject("GameFontNormal")
            w.text:SetPoint("LEFT", 10, 0)
            w.text:SetPoint("RIGHT", -8, 0)
            w.text:SetWordWrap(false)
            w.text:SetText(d.text)
        elseif kind == "main" then
            w.text:SetFontObject("GameFontHighlightSmall")
            w.text:SetPoint("LEFT", 10, 0)
            w.text:SetPoint("RIGHT", -84, 0)
            w.text:SetWordWrap(false)
            w.text:SetText(d.text)
        else
            w.text:SetFontObject("GameFontDisableSmall")
            w.text:SetPoint("TOPLEFT", 10, -4)
            w.text:SetPoint("BOTTOMRIGHT", -10, 4)
            w.text:SetWordWrap(true)
            w.text:SetText(d.text)
        end
    end
end

local function isOwn(key)
    for _, own in ipairs(P():GetOwnCharacters()) do
        if own == key then return true end
    end
    return false
end

local function memberDetailRows(key)
    local rows = {}
    -- the player's characters
    local others = P():GetOtherCharacters(key)
    local main = P():GetMain(key)
    if #others > 0 then
        rows[#rows + 1] = { kind = "head", text = "Characters" }
        table.sort(others, function(a, b)
            if (a == main) ~= (b == main) then return a == main end
            return shortName(a):lower() < shortName(b):lower()
        end)
        for _, c in ipairs(others) do
            rows[#rows + 1] = { kind = "char", key = c, isMain = c == main, status = statusOf(c), classFile = classOf(c),
                                level = levelOf(c), specs = P():GetSpecs(c) }
        end
    end
    if isOwn(key) then
        local own = P():GetOwnCharacters()
        if #own > 1 then
            rows[#rows + 1] = { kind = "main", canChange = true, text = main ~= key
                and ("This is an alt of your main, " .. ns.UI:ColoredName(main) .. ".")
                or (#others > 0 and "This is your main." or "Your characters are not linked: pick your main.") }
        elseif ns.Util.IsMe(key) then
            rows[#rows + 1] = { kind = "note", text = "Alts: log in once on each of your other characters in the guild, "
                .. "then pick your main here. The guild then sees them as one player." }
        end
    end

    local profs = P():GetMember(key)
    if not profs then
        rows[#rows + 1] = { kind = "note", text = shortName(key) .. " has not shared anything yet. Professions and specs "
            .. "appear here once this character logs in with DisasterZone " .. tostring(ns.version) .. " or newer." }
        return rows
    end
    if #profs == 0 then
        rows[#rows + 1] = { kind = "note", text = shortName(key) .. " has no professions." }
        return rows
    end
    rows[#rows + 1] = { kind = "head", text = "Professions" }
    for _, e in ipairs(profs) do
        local def = P():GetProfession(e.id)
        local canOpen = def.crafts and e.recipes > 0
        rows[#rows + 1] = { kind = "prof", id = e.id, e = e, canOpen = canOpen }
        if canOpen and state.open[e.id] then
            local groups, order = {}, {}
            for _, r in ipairs(P():GetMemberRecipes(key, e.id)) do
                local name = P():GetRecipeGroup(r)
                if not groups[name] then
                    groups[name] = {}
                    order[#order + 1] = name
                end
                local list = groups[name]
                list[#list + 1] = r
            end
            table.sort(order)
            for _, name in ipairs(order) do
                rows[#rows + 1] = { kind = "group", text = ("%s (%d)"):format(name, #groups[name]) }
                for _, r in ipairs(groups[name]) do rows[#rows + 1] = { kind = "recipe", r = r } end
            end
        end
    end
    if ns.Util.IsMe(key) then
        local names = {}
        for _, id in ipairs(P():GetUnscanned()) do names[#names + 1] = P():GetName(id) end
        if #names > 0 then
            rows[#rows + 1] = { kind = "note", text = "Open your " .. table.concat(names, " / ")
                .. " window once: DisasterZone reads your recipes from it and shares them with the guild." }
        end
    end
    return rows
end

local function recipeDetailRows(recipe)
    local rows = {}
    local crafters = sortedCrafters(recipe)
    local online = 0
    for _, c in ipairs(crafters) do
        if c.online then online = online + 1 end
    end
    rows[1] = { kind = "head", text = ("Crafters (%d)"):format(#crafters) .. "  " .. grey(online .. " online") }
    for _, c in ipairs(crafters) do
        local target = c.via or c.key
        rows[#rows + 1] = { kind = "crafter", key = c.key, via = c.via, status = statusOf(c.key), rank = c.rank,
                            spec = c.spec, recipe = recipe, canWhisper = c.online and not ns.Util.IsMe(target) }
    end
    if online == 0 then
        rows[#rows + 1] = { kind = "note", text = "Nobody who can make this is online right now." }
    end
    rows[#rows + 1] = { kind = "note", text = "Whisper opens a message with the recipe linked. Click a crafter to see "
        .. "everything they can make." }
    return rows
end

----------------------------------------------------------------------------
-- Detail header and the officer note (right)
----------------------------------------------------------------------------

local function editNote(key)
    local notes, board = N(), ns.StrategyBoard
    if not (notes and notes:CanUse() and board and board.Prompt) then return end
    local cur = notes:Get(key)
    board:Prompt("Officer note for " .. shortName(key) .. " (officers only; empty removes it)", cur and cur.text or "",
        function(text)
            local ok, err = notes:Set(key, text or "")
            if not ok then ns:Print("The officer note was not saved: %s", tostring(err)) end
        end, true, notes.MAX_LEN)
end

local function updateNote(right, member)
    local notes = N()
    local show = member ~= nil and notes ~= nil and notes:CanUse()
    right.note:SetShown(show)
    right.list.frame:ClearAllPoints()
    right.list.frame:SetPoint("TOPLEFT", 4, -78)
    right.list.frame:SetPoint("BOTTOMRIGHT", -4, show and (NOTE_H + 8) or 6)
    if not show then return end
    local rec = notes:Get(member)
    right.note.key = member
    if rec then
        right.note.text:SetText(rec.text)
        right.note.meta:SetText(grey(("%s, %s"):format(rec.by and shortName(rec.by) or "?", date("%d %b %Y", rec.rev))))
    else
        right.note.text:SetText(grey("No note. Officers and the Guild Master can write one; only they see it."))
        right.note.meta:SetText("")
    end
    if notes:IsLocalOnly() then
        right.note.meta:SetText("|cffff9933debug role: test notes, kept on this PC only|r")
    end
    right.note.edit:SetText(rec and "Edit" or "Add")
end

local function updateDetail(p)
    local right = p.right
    local recipe = state.mode == "recipes" and state.recipe and P():GetRecipe(state.recipe) or nil
    local member = state.mode == "roster" and state.member or nil
    right.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    right.whisper:Hide()
    right.link:Hide()
    right.sub2:SetText("")
    updateNote(right, member)
    if recipe then
        right.icon:SetTexture(P():GetRecipeIcon(recipe))
        right.icon:Show()
        right.title:SetText(recipe.name)
        right.sub:SetText(P():GetName(recipe.prof) .. "  ·  " .. P():GetRecipeGroup(recipe))
        right.link:Show()
        right.list:SetEmptyText("")
        right.list:SetData(recipeDetailRows(recipe))
    elseif member then
        local g = G()
        local m = g and g:GetMember(member)
        local classFile = classOf(member)
        ns.UI:ClassIcon(right.icon, classFile)
        right.title:SetText(ns.UI:ColoredName(member, classFile))
        local parts = {}
        if m and m.rankName then parts[#parts + 1] = m.rankName end
        local level = levelOf(member)
        if level then parts[#parts + 1] = "Level " .. level end
        parts[#parts + 1] = STATUS_TEXT[statusOf(member)]
        right.sub:SetText(table.concat(parts, "  ·  "))
        local specs = {}
        for i, spec in ipairs(P():GetSpecs(member) or {}) do
            local _, icon = specInfo(classFile, spec)
            specs[#specs + 1] = grey(i == 1 and "Main spec " or "Off spec ") .. (icon and (ns.UI:IconText(icon, 14) .. " ") or "")
                .. specText(classFile, spec)
        end
        right.sub2:SetText(table.concat(specs, "     "))
        local on = onlineCharacter(member)
        right.whisperTarget = on
        right.whisper:SetText(on and on ~= member and ("Whisper " .. shortName(on)) or "Whisper")
        right.whisper:SetWidth(on and on ~= member and 130 or 84)
        right.whisper:SetShown(on ~= nil and not ns.Util.IsMe(on))
        right.list:SetEmptyText("")
        right.list:SetData(memberDetailRows(member))
    else
        right.icon:Hide()
        right.title:SetText("")
        right.sub:SetText("")
        right.list:SetEmptyText(state.mode == "recipes"
            and "Pick a recipe to see who can make it.\n\nType in the search box to find one, or click a profession above."
            or "Pick a member to see their characters, specs and professions.")
        right.list:SetData({})
    end
end

----------------------------------------------------------------------------
-- Toolbar: view buttons, search, profession icons
----------------------------------------------------------------------------

local function createChip(p, def)
    local b = CreateFrame("Button", nil, p)
    b:SetSize(CHIP, CHIP)
    b.def = def
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 1, -1)
    b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    b.icon:SetTexture(def.icon)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    ns.UI:AddEdges(b, "OVERLAY")
    b.count = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.count:SetPoint("BOTTOMRIGHT", 1, 1)
    b.count:SetJustifyH("RIGHT")
    if b.count.SetShadowOffset then b.count:SetShadowOffset(1, -1) end
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnClick", function(self)
        MembersUI:SetProfession(state.prof ~= self.def.id and self.def.id or nil)
    end)
    b:SetScript("OnEnter", function(self)
        local n = self.n or 0
        ns.UI:SetTextTooltip(self, { P():GetName(self.def.id),
            n == 1 and "1 member" or (n .. " members"),
            { state.prof == self.def.id and "Click to show every profession again." or "Click to show only this profession.",
              0.6, 0.6, 0.6 } }, "ANCHOR_BOTTOMRIGHT")
    end)
    b:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    return b
end

local function updateToolbar(p)
    p.rosterBtn:SetKind(state.mode == "roster" and "primary" or "secondary")
    p.recipesBtn:SetKind(state.mode == "recipes" and "primary" or "secondary")
    if p.search.Instructions then
        p.search.Instructions:SetText(state.mode == "recipes" and "Search recipes..." or "Search members...")
    end
    local counts = P():GetCounts()
    for _, chip in ipairs(p.chips) do
        local n = counts[chip.def.id] or 0
        chip.n = n
        chip.count:SetText(n > 0 and tostring(n) or "")
        local selected = state.prof == chip.def.id
        if selected then
            ns.UI:SetEdgeColor(chip, GOLD[1], GOLD[2], GOLD[3], 1)
        else
            ns.UI:SetEdgeColor(chip, 0.3, 0.3, 0.33, 0.9)
        end
        local dim = (state.prof and not selected) or n == 0
        chip.icon:SetDesaturated(n == 0)
        chip.icon:SetAlpha(dim and 0.45 or 1)
    end
    local s = P():GetStats()
    local text = ("%d %s  ·  %d recipes"):format(s.members, s.members == 1 and "member" or "members", s.recipes)
    if s.missing > 0 then text = text .. "  ·  " .. gold("receiving recipes...") end
    p.status:SetText(text)
    if state.prof then
        local n = counts[state.prof] or 0
        p.filter:SetText(gold(P():GetName(state.prof)) .. "  " .. grey(n == 1 and "1 member" or (n .. " members")))
    else
        p.filter:SetText(grey("Click a profession to filter"))
    end
end

----------------------------------------------------------------------------
-- Panel
----------------------------------------------------------------------------

function MembersUI:CreatePanel(parent)
    if panel then return panel end
    local UI = ns.UI
    local p = CreateFrame("Frame", "DisasterZoneMembersPanel", parent)
    p:SetAllPoints(parent)
    panel = p

    p.rosterBtn = UI:CreateSleekButton(p, "Roster", 84, 22, function() MembersUI:SetMode("roster") end)
    p.rosterBtn:SetPoint("TOPLEFT", 8, -8)
    p.recipesBtn = UI:CreateSleekButton(p, "Recipes", 84, 22, function() MembersUI:SetMode("recipes") end)
    p.recipesBtn:SetPoint("LEFT", p.rosterBtn, "RIGHT", -1, 0)
    p.search = UI:CreateSearchBox(p, 200, function(text)
        text = ns.Util.Trim(text or "")
        if text == state.search then return end
        state.search = text
        MembersUI:Refresh(true)
    end, "Search members...")
    p.search:SetPoint("LEFT", p.recipesBtn, "RIGHT", 16, 0)
    p.status = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.status:SetPoint("TOPRIGHT", -10, -13)
    p.status:SetJustifyH("RIGHT")

    p.chips = {}
    local x, prevPrimary = 8, true
    for _, def in ipairs(P():GetProfessions()) do
        if prevPrimary and not def.primary then x = x + 10 end   -- a gap before the secondary professions
        prevPrimary = def.primary
        local chip = createChip(p, def)
        chip:SetPoint("TOPLEFT", x, -38)
        x = x + CHIP + 4
        p.chips[#p.chips + 1] = chip
    end
    p.filter = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.filter:SetPoint("TOPLEFT", x + 8, -46)
    p.filter:SetJustifyH("LEFT")

    p.roster = UI:CreateScrollList(p, 26, initRosterRow, function(d) return d.kind == "sep" and 22 or 26 end)
    p.roster.frame:SetPoint("TOPLEFT", 0, -TOP)
    p.roster.frame:SetPoint("BOTTOMLEFT", 0, 4)
    p.roster.frame:SetWidth(LIST_W)

    p.recipes = UI:CreateScrollList(p, 22, initRecipeRow)
    p.recipes.frame:SetPoint("TOPLEFT", 0, -TOP)
    p.recipes.frame:SetPoint("BOTTOMLEFT", 0, 4)
    p.recipes.frame:SetWidth(LIST_W)

    local right = UI:CreatePanel(p)
    right:SetPoint("TOPLEFT", LIST_W + 8, -TOP)
    right:SetPoint("BOTTOMRIGHT", -4, 4)
    p.right = right
    right.icon = right:CreateTexture(nil, "ARTWORK")
    right.icon:SetSize(36, 36)
    right.icon:SetPoint("TOPLEFT", 12, -12)
    right.iconHit = CreateFrame("Frame", nil, right)
    right.iconHit:SetAllPoints(right.icon)
    right.iconHit:EnableMouse(true)
    right.iconHit:SetScript("OnEnter", function(self)
        local r = state.mode == "recipes" and state.recipe and P():GetRecipe(state.recipe)
        if r then showRecipeTooltip(self, r) end
    end)
    right.iconHit:SetScript("OnLeave", hideRecipeTooltip)
    right.title = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    right.title:SetPoint("TOPLEFT", 58, -13)
    right.title:SetPoint("RIGHT", -150, 0)
    right.title:SetJustifyH("LEFT")
    right.title:SetWordWrap(false)
    right.sub = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    right.sub:SetPoint("TOPLEFT", 58, -33)
    right.sub:SetJustifyH("LEFT")
    right.sub2 = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    right.sub2:SetPoint("TOPLEFT", 12, -55)
    right.sub2:SetPoint("RIGHT", -8, 0)
    right.sub2:SetJustifyH("LEFT")
    right.sub2:SetWordWrap(false)
    right.whisper = UI:CreateSleekButton(right, "Whisper", 84, 22, function()
        if right.whisperTarget then whisper(right.whisperTarget) end
    end, "primary")
    right.whisper:SetPoint("TOPRIGHT", -12, -14)
    right.link = UI:CreateSleekButton(right, "Link in chat", 96, 22, function()
        local r = state.recipe and P():GetRecipe(state.recipe)
        if r then linkRecipe(r) end
    end)
    right.link:SetPoint("TOPRIGHT", -12, -14)
    right.line = right:CreateTexture(nil, "ARTWORK")
    right.line:SetColorTexture(1, 1, 1, 0.08)
    right.line:SetHeight(1)
    right.line:SetPoint("TOPLEFT", 8, -74)
    right.line:SetPoint("TOPRIGHT", -8, -74)
    right.list = UI:CreateScrollList(right, 20, initDetailRow, detailExtent)
    right.list.frame:SetPoint("TOPLEFT", 4, -78)
    right.list.frame:SetPoint("BOTTOMRIGHT", -4, 6)

    -- the officer note (officers only): the text, who wrote it, Edit
    local note = CreateFrame("Frame", nil, right)
    note:SetPoint("BOTTOMLEFT", 6, 6)
    note:SetPoint("BOTTOMRIGHT", -6, 6)
    note:SetHeight(NOTE_H)
    note:EnableMouse(true)
    right.note = note
    note.bg = note:CreateTexture(nil, "BACKGROUND")
    note.bg:SetAllPoints()
    note.bg:SetColorTexture(1, 0.82, 0, 0.06)
    note.label = note:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note.label:SetPoint("TOPLEFT", 8, -6)
    note.label:SetText("Officer note")
    note.meta = note:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note.meta:SetPoint("LEFT", note.label, "RIGHT", 8, 0)
    note.edit = UI:CreateSleekButton(note, "Edit", 52, 18, function()
        if note.key then editNote(note.key) end
    end)
    note.edit:SetPoint("TOPRIGHT", -6, -4)
    note.text = note:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note.text:SetPoint("TOPLEFT", 8, -22)
    note.text:SetPoint("BOTTOMRIGHT", -8, 4)
    note.text:SetJustifyH("LEFT")
    note.text:SetJustifyV("TOP")
    note.text:SetWordWrap(true)
    -- a long note shows whole in the tooltip
    note:SetScript("OnEnter", function(self)
        local rec = self.key and N() and N():Get(self.key)
        if rec then
            UI:SetTextTooltip(self, { "Officer note: " .. shortName(self.key), { rec.text, 1, 1, 1, wrap = true },
                { "Only officers and the Guild Master see this.", 0.6, 0.6, 0.6 } }, "ANCHOR_TOPLEFT")
        end
    end)
    note:SetScript("OnLeave", function() UI:HideTooltip() end)
    note:Hide()

    p:SetScript("OnShow", function() MembersUI:Refresh() end)
    function p:OnPanelShown() MembersUI:Refresh() end
    C_Timer.After(0, function() MembersUI:Refresh() end)
    return p
end

-- resetScroll: the left list jumps back to the top (a new search / filter).
function MembersUI:Refresh(resetScroll)
    if not panel or not panel:IsVisible() then return end
    local p = panel
    local roster = state.mode == "roster"
    p.roster.frame:SetShown(roster)
    p.recipes.frame:SetShown(not roster)
    if roster then
        local rows = rosterRows()
        -- keep the selection while it is listed; else me, else the first member
        local found = false
        for _, d in ipairs(rows) do
            if d.key and d.key == state.member then found = true end
        end
        if not found then
            local me = ns.Util.PlayerKey()
            state.member = nil
            for _, d in ipairs(rows) do
                if d.key == me then state.member = me end
            end
            if not state.member and rows[1] and rows[1].key then state.member = rows[1].key end
        end
        p.roster:SetEmptyText(state.search ~= "" and "No member matches your search."
            or (state.prof and "Nobody has shared this profession yet." or "The guild roster has not loaded yet."))
        p.roster:SetData(rows, resetScroll)
    else
        local rows = recipeRows()
        if state.recipe and not P():GetRecipe(state.recipe) then state.recipe = nil end
        p.recipes:SetEmptyText((state.search ~= "" or state.prof) and "No recipe matches."
            or "No recipes shared yet.\n\nYours appear after you open each of your profession windows once; the "
                .. "guild's arrive as members log in.")
        p.recipes:SetData(rows, resetScroll)
    end
    updateToolbar(p)
    updateDetail(p)
end

function MembersUI:RequestRefresh()
    if panel and panel:IsVisible() then ns.Util.Debounce("members-ui", 0.2, function() MembersUI:Refresh() end) end
end

-- "roster" | "recipes"
function MembersUI:SetMode(mode)
    mode = mode == "recipes" and "recipes" or "roster"
    if state.mode == mode then return end
    state.mode = mode
    state.search = ""
    if panel then panel.search:SetText("") end
    self:Refresh(true)
end

function MembersUI:GetMode() return state.mode end

-- A profession id, or nil for all.
function MembersUI:SetProfession(id)
    state.prof = (id and P():GetProfession(id)) and id or nil
    if state.prof then state.open = { [state.prof] = true } end
    self:Refresh(true)
end

function MembersUI:SelectMember(key)
    state.member = key
    if state.prof then state.open[state.prof] = true end
    self:Refresh()
end

function MembersUI:SelectRecipe(spell)
    state.recipe = spell
    self:Refresh()
end

-- Jumps to a member in the Roster view (profId: that profession opened).
function MembersUI:ShowMember(key, profId)
    state.mode, state.member, state.search = "roster", key, ""
    state.prof = nil
    state.open = profId and { [profId] = true } or {}
    if panel then panel.search:SetText("") end
    self:Refresh(true)
end

-- Jumps to a recipe in the Recipes view.
function MembersUI:ShowRecipe(spell)
    local r = P():GetRecipe(spell)
    if not r then return end
    state.mode, state.recipe, state.search = "recipes", spell, ""
    state.prof = r.prof
    if panel then panel.search:SetText("") end
    self:Refresh(true)
end

-- Opens the officer note editor for a member (officers).
function MembersUI:EditNote(key) editNote(key) end

function MembersUI:GetPanel() return panel end
function MembersUI:GetState() return state end

function MembersUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("members", "Members", 3.6, function(parent) return MembersUI:CreatePanel(parent) end)
    end
    local function refresh() MembersUI:RequestRefresh() end
    for _, msg in ipairs({ "PROFESSIONS_UPDATED", "ROSTER_UPDATED", "DEMO_TOGGLED", "OFFICER_NOTES_UPDATED" }) do
        ns:On(msg, refresh)
    end
    ns:RegisterSlash("members", function() ns.MainFrame:Open("members") end,
        "open the Members tab: the guild's professions and who can craft what")
end
