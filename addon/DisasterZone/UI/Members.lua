if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Members.lua", ...) then return end -- DisasterZone: "Members" tab (everyone).
-- The guild's members with what their DisasterZone shares (Core/Professions.lua): professions and recipes, main and off
-- spec (primary / secondary talents), and which characters belong to one player. Two views:
--   Roster  - every guild member: class circle (a dot while online), name, professions; alts sit under their main.
--             The picked member's card: specs, the officer note (officers, Core/OfficerNotes.lua), then Characters /
--             Professions (the recipes fold out under their profession) / Equipment
--   Recipes - every recipe somebody knows, searchable; a recipe's card lists who can make it, online first
-- The profession dropdown (top right) filters both views.
-- Layout: the Raids / Atlas grid (PAD at the page's sides, GAP between blocks), flat: whitespace and type; the only
-- box is the officer note.
local addonName, ns = ...

local MembersUI = ns:NewModule("MembersUI")

local PAD, GAP = 10, 8
local CTRL_H = 22                       -- the tabs / search / profession row
-- the roster / recipe list: its rows, then its scroll bar BAR_GAP right of them and as far again from the card, so the
-- bar sits in a margin like the page's own (PAD)
local ROWS_W = 356
local BAR_GAP, BAR_W = PAD, 6
local LIST_W = ROWS_W + BAR_GAP + BAR_W
local CARD_X = PAD + LIST_W + BAR_GAP   -- the card on the right, to PAD from the page's right edge
local CARD_W = 790 - PAD - CARD_X       -- (its width in an 800 wide window: for measuring before it is laid out)
local PROF_DD_W = 180
local TOP = 6 + CTRL_H + GAP + 2        -- the lists and the card
local BOTTOM = 8
local ROW_H, SEP_H, RECIPE_H = 30, 26, 24
local MAX_LEVEL = 70
-- the card: header (class circle or recipe icon), spec chips, the officer note, Characters / Professions / Equipment
local HEAD_H = 44
local HEAD_BTN_Y = 2                    -- the header's buttons: on the name's row (22 high), above the meta line
local SPECS_Y = HEAD_H + 10
local SPEC_H = 22
local CARDTABS_H = 26
-- a person's row: the class circle, the name; on the right two professions (icon, the rank while below max)
local NAME_DX = 28
local NUM_W = 22                        -- a skill rank, right-aligned in its column
local SLOT_W, SLOT_GAP = 16 + 4 + NUM_W, 12
local GEAR_X = 82                       -- an equipment row: the slot's name, then the item from here
local NOTE_LINE = 13
local NOTE_MAX_LINES = 8

local NUM_FONT = "Fonts\\ARIALN.TTF"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local TEAM_ICON = "Interface\\Icons\\INV_Shirt_GuildTabard_01"
-- the dot on a class circle: online green, away yellow, busy orange; offline has none
local STATUS_COLOR = { online = { 0.24, 0.81, 0.36 }, afk = { 0.91, 0.77, 0.23 }, dnd = { 1, 0.5, 0.1 } }
local STATUS_TEXT = { online = "|cff33ff33Online|r", afk = "|cffffcc1aAway|r", dnd = "|cffff801aDo not disturb|r",
                      offline = "|cff808080Offline|r" }
local STATUS_WORD = { online = "Online", afk = "Away", dnd = "Do not disturb", offline = "Offline" }
local CARD_BG = { 0.10, 0.10, 0.12, 0.92 }
local EDGE = { 0.34, 0.34, 0.38, 0.5 }

local state = { mode = "roster", prof = nil, search = "", member = nil, recipe = nil, open = {}, card = "profs" }
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

local function sized(fs, size, flags)
    local path, _, f = fs:GetFont()
    if path then fs:SetFont(path, size, flags or f) end
    return fs
end

local function text(parent, font, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then sized(fs, size) end
    return fs
end

-- Numbers (skill ranks) in the game's narrow number font.
local function numText(parent, size)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetFont(NUM_FONT, size or 12, "")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function icon(parent, size, layer)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetSize(size, size)
    t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    return t
end

local function disc(parent, layer, sub, size, c)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(DISC)
    t:SetSize(size, size)
    if c then t:SetVertexColor(c[1], c[2], c[3], c[4] or 1) end
    return t
end

local function flatCard(f)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(CARD_BG[1], CARD_BG[2], CARD_BG[3], CARD_BG[4])
    ns.UI:AddEdges(f, "BORDER")
    ns.UI:SetEdgeColor(f, EDGE[1], EDGE[2], EDGE[3], EDGE[4])
end

-- The atlas chevron (it points down), or turned a quarter to the left to point right.
local function setChevron(tex, right)
    local c = ns.UI:IconCoords(ns.UI.ICON.chevron)
    local l, r, t, b = c[1], c[2], c[3], c[4]
    tex:SetTexture(ns.UI.ICON_ATLAS)
    if right then
        tex:SetTexCoord(r, t, l, t, r, b, l, b)
    else
        tex:SetTexCoord(l, r, t, b)
    end
end

-- roster order: online, away / do not disturb, offline
local STATUS_RANK = { online = 1, afk = 2, dnd = 2, offline = 3 }

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

-- A profession specialisation without its profession's name ("Spellfire Tailoring" -> "Spellfire").
local function shortSpecName(e)
    local name = specName(e.spec)
    if not name then return nil end
    local prof = P():GetName(e.id) or ""
    local short = name:gsub(" " .. prof:gsub("%p", "%%%0") .. "$", "")
    return short ~= "" and short or name
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
                          spec = e and e.spec, e = e }
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

-- A craft's materials on tt while Shift is held (UI/Tooltip.lua), then the hints. Returns the first hint (nil: no
-- craft makes id).
local function addMaterials(tt, id)
    if not ns.Tooltip then return nil end
    local matsHint, stepHint = ns.Tooltip:AddMaterials(tt, id)
    if matsHint then
        tt:AddLine(" ")
        tt:AddLine(matsHint, 0.7, 0.7, 0.7)
        if stepHint then tt:AddLine(stepHint, 0.7, 0.7, 0.7) end
    end
    return matsHint
end

-- Worn gear: the item's tooltip, a crafted piece's materials under it.
local function showGearTooltip(owner, item)
    local T = ns.Tooltip
    if T then T.noMats = true end
    ns.UI:SetItemTooltip(owner, item, function(tt) addMaterials(tt, item) end)
    if T then T.noMats = nil end
end

-- The item (or enchant) tooltip, the reagents next to it for an item, and who makes it.
local reagentTip
local function showRecipeTooltip(owner, recipe)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local T = ns.Tooltip
    if recipe.item > 0 then
        -- the crafters and the materials are listed below
        if T then T.skipCrafters, T.noMats = true, true end
        GameTooltip:SetItemByID(recipe.item)
        if T then T.skipCrafters, T.noMats = nil, nil end
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
    -- Shift: the materials (Shift + mouse wheel: how many, Shift + clicks: break down), in place of the recipe's
    -- tooltip at the side
    local matsHint = addMaterials(GameTooltip, -recipe.spell)
    GameTooltip:Show()
    if recipe.item > 0 and not (matsHint and IsShiftKeyDown()) then
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
    elseif reagentTip then
        reagentTip:Hide()
    end
end

local function hideRecipeTooltip()
    GameTooltip:Hide()
    if reagentTip then reagentTip:Hide() end
end

-- A row's hover tint (and, for a pickable row, the picked look: a gold tint with a gold bar on its left).
local function rowLooks(row, pickable)
    row.hl = row:CreateTexture(nil, "HIGHLIGHT")
    row.hl:SetAllPoints()
    row.hl:SetColorTexture(1, 1, 1, 0.05)
    if not pickable then return end
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetColorTexture(1, 0.82, 0, 0.08)
    row.selBar = row:CreateTexture(nil, "BORDER")
    row.selBar:SetPoint("TOPLEFT")
    row.selBar:SetPoint("BOTTOMLEFT")
    row.selBar:SetWidth(2)
    row.selBar:SetColorTexture(1, 0.82, 0, 0.9)
end

local function setPicked(row, on)
    row.sel:SetShown(on and true or false)
    row.selBar:SetShown(on and true or false)
end

-- A small rounded tag ("only crafter", "Main"): f:Set(text) sizes it.
local function goldTag(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(16)
    ns.UI:AddPillShape(f, 16)
    f:SetPillColors({ 1, 0.82, 0, 0.09 }, { 1, 0.82, 0, 0.45 })
    f.fs = text(f, "GameFontHighlightSmall", 10)
    f.fs:SetPoint("CENTER", 0, 0)
    f.fs:SetTextColor(1, 0.82, 0)
    function f:Set(t)
        self.fs:SetText(t or "")
        self:SetWidth(math.floor((self.fs:GetStringWidth() or 40) + 14.5))
    end
    return f
end

----------------------------------------------------------------------------
-- A person's row: class circle (with a dot while online), name (the level below max), two professions on the right
-- (the roster, a member's other characters, a recipe's crafters)
----------------------------------------------------------------------------

local function personWidgets(row)
    local c = {}
    c.icon = row:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(20, 20)
    -- the dot sits on the circle's lower right, in a ring of the page's colour
    c.ring = disc(row, "OVERLAY", 1, 11, { 0.045, 0.045, 0.05, 1 })
    c.ring:SetPoint("CENTER", c.icon, "BOTTOMRIGHT", -2, 2)
    c.dot = disc(row, "OVERLAY", 2, 8)
    c.dot:SetPoint("CENTER", c.ring, "CENTER")
    row.circle = c
    row.name = text(row, "GameFontHighlight")
    row.level = text(row, "GameFontDisableSmall")
    row.level:SetPoint("LEFT", row.name, "RIGHT", 5, -1)
    row.tag = goldTag(row)
    row.slots = {}
    for i = 1, 2 do
        -- the icon, then the rank right-aligned in its own column (every row reads icon + number, icon + number)
        local s = { icon = icon(row, 16) }
        s.rank = numText(row, 12)
        s.rank:SetWidth(NUM_W)
        s.rank:SetJustifyH("RIGHT")
        s.rank:SetPoint("RIGHT", s.icon, "RIGHT", 4 + NUM_W, 0)
        s.rank:SetTextColor(0.72, 0.72, 0.74)
        row.slots[i] = s
    end
end

local function hidePerson(row)
    local c = row.circle
    c.icon:Hide()
    c.ring:Hide()
    c.dot:Hide()
    row.name:Hide()
    row.level:Hide()
    row.tag:Hide()
    for _, s in ipairs(row.slots) do
        s.icon:Hide()
        s.rank:Hide()
    end
end

-- x: the circle's left; width: the row's (the professions sit at its right end); d: { key, classFile, status, level,
-- profs, tag }. noProfs: leave the professions out (a crafter's row says its skill instead).
local function fillPerson(row, x, width, d, noProfs)
    local c = row.circle
    c.icon:ClearAllPoints()
    c.icon:SetPoint("LEFT", x, 0)
    c.icon:Show()
    if d.classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[d.classFile] then
        c.icon:SetVertexColor(1, 1, 1)
        ns.UI:ClassIcon(c.icon, d.classFile)
    else
        c.icon:SetTexture(DISC)
        c.icon:SetTexCoord(0, 1, 0, 1)
        c.icon:SetVertexColor(0.3, 0.3, 0.33)
    end
    local col = STATUS_COLOR[d.status]
    c.ring:SetShown(col ~= nil)
    c.dot:SetShown(col ~= nil)
    if col then c.dot:SetVertexColor(col[1], col[2], col[3], 1) end
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", x + NAME_DX, 0)
    row.name:SetText(ns.UI:ColoredName(d.key, d.classFile))
    row.name:Show()
    -- the level only below the cap (an alt on its way)
    row.level:SetText((d.level and d.level < MAX_LEVEL) and tostring(d.level) or "")
    row.level:Show()
    row.tag:SetShown(d.tag ~= nil)
    if d.tag then
        row.tag:Set(d.tag)
        row.tag:ClearAllPoints()
        row.tag:SetPoint("LEFT", row.level:GetText() ~= "" and row.level or row.name, "RIGHT", 6, 0)
    end
    -- two professions: the one the dropdown filters by first, then the primary ones
    local shown = {}
    local picked
    if not noProfs then
        picked = state.prof and profEntry(d.profs, state.prof)
        if picked then shown[1] = picked end
        for _, e in ipairs(d.profs or {}) do
            if #shown >= 2 then break end
            local def = P():GetProfession(e.id)
            if e ~= picked and def and def.primary then shown[#shown + 1] = e end
        end
    end
    -- (a roster row keeps 8 inside its tint; the card's rows end on the card's edge)
    local right = width - (row.cardRow and 0 or 8)
    for i, s in ipairs(row.slots) do
        local e = shown[i]
        s.icon:ClearAllPoints()
        s.icon:SetPoint("LEFT", right - (3 - i) * SLOT_W - (2 - i) * SLOT_GAP, 0)
        if e then
            s.icon:SetTexture(P():GetProfession(e.id).icon)
            s.icon:Show()
            -- (a rank not known yet: the column stays, empty)
            s.rank:SetText((tonumber(e.rank) or 0) > 0 and tostring(e.rank) or "")
            s.rank:Show()
        else
            s.icon:Hide()
            s.rank:Hide()
        end
    end
end

----------------------------------------------------------------------------
-- Roster list (left, Roster view)
----------------------------------------------------------------------------

-- The DisasterZone a member runs, as their last addon message said: state ("same" | "older" | "newer" | "none"),
-- version, when it was last heard.
local function versionOf(key)
    local Sync = ns.Sync
    local p = Sync and Sync.GetPeer and Sync:GetPeer(key)
    if not p or not p.v then return "none" end
    local cmp = ns.Util.CompareVersions(p.v, ns.version)
    return (cmp < 0 and "older") or (cmp > 0 and "newer") or "same", p.v, p.lastSeen
end

-- The version lines of a member's tooltip.
local function versionLines(key, lines)
    local st, v, seen = versionOf(key)
    if st == "none" then
        lines[#lines + 1] = { "DisasterZone not seen", 1, 0.82, 0 }
        lines[#lines + 1] = { "This character has not been online with the addon since you installed it (or does "
            .. "not have it).", 0.7, 0.7, 0.7, wrap = true }
        return lines
    end
    lines[#lines + 1] = { "DisasterZone " .. tostring(v), 1, 0.82, 0 }
    if st == "same" then
        lines[#lines + 1] = { "The same version as yours.", 0.2, 1, 0.2 }
    elseif st == "older" then
        lines[#lines + 1] = { "Older than your " .. tostring(ns.version) .. ".", 1, 0.4, 0.3 }
    else
        lines[#lines + 1] = { "Newer than your " .. tostring(ns.version) .. ": you are behind.", 1, 0.6, 0.2 }
    end
    if not ns.Util.IsMe(key) and seen then
        lines[#lines + 1] = { "Last heard with it " .. ns.Util.FormatAgo(seen) .. ".", 0.7, 0.7, 0.7 }
    end
    return lines
end

-- The raid teams of the player behind `key` (this character or another of theirs), sorted by name.
local function teamsOf(key)
    local RP = ns.RaidPlan
    if not (RP and RP.GetTeams) then return {} end
    local mine = { [key] = true }
    for _, c in ipairs(P():GetOtherCharacters(key)) do mine[c] = true end
    local out = {}
    for _, t in ipairs(RP:GetTeams()) do
        for _, m in ipairs(t.members) do
            if mine[m] then out[#out + 1] = t break end
        end
    end
    return out
end

-- The Raids tab's Teams view with that team selected.
local function openTeam(id)
    if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open("raids") end
    if not (ns.RaidsUI and ns.RaidsUI.SetView) then return end
    ns.RaidsUI:SetView("teams")
    if ns.RaidsUI:GetView() == "teams" and ns.RaidPlanUI and ns.RaidPlanUI.SelectTeam then
        ns.RaidPlanUI:SelectTeam(id)
    end
end

-- Everything about a member on hover (a roster row, the card's header): rank, status, alt of / playing now, team, specs,
-- professions, the DisasterZone they run, the officer note. d: { key, classFile, status, specs, profs }.
local function memberTooltip(owner, d)
    if not d or not d.key then return end
    local level = levelOf(d.key)
    local lines = { ns.UI:ColoredName(d.key, d.classFile) .. (level and grey("  " .. level) or "") }
    local m = G() and G():GetMember(d.key)
    lines[#lines + 1] = { (m and m.rankName and (m.rankName .. "  ·  ") or "") .. (STATUS_TEXT[d.status] or ""), 1, 1, 1 }
    local main = P():GetMain(d.key)
    if main ~= d.key then
        lines[#lines + 1] = { "Alt of " .. ns.UI:ColoredName(main), 0.8, 0.8, 0.8 }
    end
    local on = onlineCharacter(d.key)
    if on and on ~= d.key then lines[#lines + 1] = { "Playing " .. ns.UI:ColoredName(on) .. " now", 0.2, 1, 0.2 } end
    local teams = teamsOf(d.key)
    if #teams > 0 then
        local names = {}
        for _, t in ipairs(teams) do names[#names + 1] = t.name end
        lines[#lines + 1] = { "Team: " .. table.concat(names, ", "), 1, 0.82, 0, wrap = true }
    end
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
    lines[#lines + 1] = { " " }
    versionLines(d.key, lines)
    local note = N() and N():Get(d.key)
    if note then
        lines[#lines + 1] = { " " }
        lines[#lines + 1] = { "Officer note", 1, 0.82, 0 }
        lines[#lines + 1] = { note.text, 1, 1, 1, wrap = true }
    end
    ns.UI:SetTextTooltip(owner, lines)
end

local function rosterTooltip(row) memberTooltip(row, row.__cdlData) end

local function initRosterRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        rowLooks(row, true)
        personWidgets(row)
        row.sepText = text(row, "GameFontHighlightSmall", 10)
        row.sepText:SetTextColor(0.55, 0.55, 0.57)
        row.sepText:SetPoint("BOTTOMLEFT", 6, 5)
        row:SetScript("OnClick", function(self)
            local data = self.__cdlData
            if data and data.key then MembersUI:SelectMember(data.key) end
        end)
        row:SetScript("OnEnter", rosterTooltip)
        row:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    end
    local isSep = d.kind == "sep"
    row.sepText:SetText(isSep and d.text or "")
    row.hl:SetAlpha(isSep and 0 or 1)
    setPicked(row, not isSep and d.key == state.member)
    if isSep then
        hidePerson(row)
        row:SetAlpha(1)
        return
    end
    fillPerson(row, 6 + (d.alt and 14 or 0), ROWS_W, d)
    row:SetAlpha(d.status == "offline" and 0.55 or 1)
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
    -- online, then away / busy, then offline; within each the highest level first, then by name
    local function byOnlineThenName(a, b)
        local ar, br = STATUS_RANK[a.status] or 3, STATUS_RANK[b.status] or 3
        if ar ~= br then return ar < br end
        local al, bl = a.level or 0, b.level or 0
        if al ~= bl then return al > bl end
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
                grp = { alts = {}, lower = shortName(main):lower(), rank = 3, level = 0 }
                byMain[main] = grp
                groups[#groups + 1] = grp
            end
            if d.key == main then grp.main = d else grp.alts[#grp.alts + 1] = d end
            -- the player's best status among their characters, and their highest level
            grp.rank = math.min(grp.rank, STATUS_RANK[d.status] or 3)
            grp.level = math.max(grp.level, d.level or 0)
        end
        table.sort(groups, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            if a.level ~= b.level then return a.level > b.level end
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
        rows[#rows + 1] = { kind = "sep", text = "Without DisasterZone" }
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
        rowLooks(row, true)
        row.icon = icon(row, 18)
        row.icon:SetPoint("LEFT", 6, 0)
        row.name = text(row, "GameFontHighlight")
        row.name:SetPoint("LEFT", 32, 0)
        row.count = text(row, "GameFontHighlightSmall", 10)
        row.count:SetPoint("RIGHT", -8, 0)
        row.count:SetJustifyH("RIGHT")
        row:SetScript("OnClick", function(self)
            local r = self.__cdlData and self.__cdlData.r
            if not r then return end
            if IsShiftKeyDown() then linkRecipe(r) else MembersUI:SelectRecipe(r.spell) end
        end)
        local function onEnter(self)
            local r = self.__cdlData and self.__cdlData.r
            if r then showRecipeTooltip(self, r) end
        end
        row:SetScript("OnEnter", onEnter)
        row:SetScript("OnLeave", hideRecipeTooltip)
        -- Shift: materials, + mouse wheel: how many, + click / right-click: break down / back up
        if ns.Tooltip then ns.Tooltip:CraftRow(row, onEnter) end
        -- hover: a bag (in place of the crafter count) that puts the craft on my Atlas shopping list
        local function craftId()
            local r = row.__cdlData and row.__cdlData.r
            return r and (r.item > 0 and r.item or -r.spell)
        end
        local function shopHover(on)
            local id = craftId()
            local show = on and id ~= nil and ns.AtlasShopUI ~= nil and ns.Shop:CanAdd(id)
            row.shop:SetShown(show)
            row.count:SetShown(not show)
        end
        row.shop = ns.UI:CreateIconButton(row, 18, ns.UI.ICON_ATLAS, ns.UI:IconCoords(ns.UI.ICON.bagAdd), function(self)
            local id = craftId()
            if id and ns.AtlasShopUI:AddCraft(id) then ns.AtlasShopUI:AddTooltip(self, id) end
        end)
        row.shop:SetPoint("RIGHT", -6, 0)
        row.shop:Hide()
        row.shop:HookScript("OnEnter", function(self)
            shopHover(true)
            local id = craftId()
            if id then ns.AtlasShopUI:AddTooltip(self, id) end
        end)
        row.shop:HookScript("OnLeave", function()
            GameTooltip:Hide()
            if not row:IsMouseOver() then shopHover(false) end
        end)
        row:HookScript("OnEnter", function() shopHover(true) end)
        row:HookScript("OnLeave", function() if not row:IsMouseOver() then shopHover(false) end end)
    end
    local r = d.r
    row.icon:SetTexture(P():GetRecipeIcon(r))
    local n = #r.crafters
    -- a recipe only one member knows is worth noticing
    row.count:SetText(n == 1 and gold("1 crafter") or ("|cff8a8a8e%d crafters|r"):format(n))
    if not row:IsMouseOver() then
        row.shop:Hide()
        row.count:Show()
    end
    row.name:SetText(r.name)
    local room = ROWS_W - 32 - 16 - (row.count:GetStringWidth() or 50)
    sized(row.name, 12)
    if (row.name:GetStringWidth() or 0) > room then sized(row.name, 11) end
    row.name:SetWidth(room)
    setPicked(row, r.spell == state.recipe)
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
-- The card's list (right): one list with mixed rows
----------------------------------------------------------------------------

local ROW_EXTENT = { prof = 46, group = 22, recipe = 20, head = 32, crafter = ROW_H, char = ROW_H, main = 30, gear = 22,
                     source = 26, team = ROW_H }
-- a member's card: Characters / Professions / Equipment
local CARDS = { { key = "chars", label = "Characters" }, { key = "profs", label = "Professions" },
                { key = "gear", label = "Equipment" } }

local function cardWidth()
    local w = panel and panel.right and panel.right:GetWidth() or 0
    return w > 0 and w or CARD_W
end

local measure   -- a hidden FontString that measures wrapped notes
local function detailExtent(d)
    if d.kind == "note" then
        if not (measure and d.text) then return 40 end
        measure:SetWidth(cardWidth() - 4)
        measure:SetText(d.text)
        return math.max(28, math.ceil(measure:GetStringHeight() or 12) + 14)
    end
    return ROW_EXTENT[d.kind] or 20
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

local function smallButton(row, label, onClick)
    local b = ns.UI:CreateSleekButton(row, label, 64, 20, onClick)
    b:GetFontString():SetFontObject("GameFontHighlightSmall")
    b:SetWidth(math.floor((b:GetFontString():GetStringWidth() or 40) + 20.5))
    b:SetPoint("RIGHT", 0, 0)
    return b
end

local function detailWidgets(row)
    row.cdlInit = true
    row.cardRow = true
    rowLooks(row, false)
    row.w = {}
    local w = row.w

    -- a profession: icon, name and specialisation, the skill bar, the recipes it folds out
    w.profIcon = icon(row, 30)
    w.profIcon:SetPoint("LEFT", 0, 0)
    w.profName = text(row, "GameFontNormal", 13)
    w.profName:SetPoint("TOPLEFT", 40, -8)
    w.profSpec = text(row, "GameFontHighlightSmall", 10)
    w.profSpec:SetTextColor(0.62, 0.62, 0.62)
    w.profSpec:SetPoint("BOTTOMLEFT", w.profName, "BOTTOMRIGHT", 6, 1)
    w.track = row:CreateTexture(nil, "ARTWORK")
    w.track:SetSize(150, 6)
    w.track:SetPoint("TOPLEFT", 40, -29)
    w.track:SetColorTexture(1, 1, 1, 0.08)
    w.fill = row:CreateTexture(nil, "ARTWORK", nil, 1)
    w.fill:SetHeight(6)
    w.fill:SetPoint("LEFT", w.track, "LEFT", 0, 0)
    w.barText = numText(row, 12)
    w.barText:SetPoint("LEFT", w.track, "RIGHT", 8, 0)
    w.barText:SetTextColor(0.84, 0.84, 0.84)
    w.chevron = row:CreateTexture(nil, "ARTWORK")
    w.chevron:SetSize(10, 10)
    w.chevron:SetPoint("RIGHT", 0, 0)
    w.chevron:SetVertexColor(0.75, 0.75, 0.75)
    w.right = text(row, "GameFontHighlightSmall", 11)
    w.right:SetJustifyH("RIGHT")

    -- a recipe line, a recipe group, a heading, a note, my main
    w.icon = icon(row, 14)
    w.icon:SetPoint("LEFT", 40, 0)
    w.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.text:SetJustifyH("LEFT")
    w.text:SetJustifyV("MIDDLE")
    w.value = text(row, "GameFontHighlight", 12)
    w.value:SetPoint("LEFT", 120, 0)
    w.tag = goldTag(row)
    w.tag:SetPoint("RIGHT", 0, 0)
    w.rule = row:CreateTexture(nil, "BORDER")
    w.rule:SetPoint("BOTTOMLEFT", 0, 0)
    w.rule:SetPoint("BOTTOMRIGHT", 0, 0)
    w.rule:SetHeight(1)
    w.rule:SetColorTexture(1, 1, 1, 0.1)

    -- a person (a crafter, another character of this player); a raid team in the same columns
    personWidgets(row)
    w.info = text(row, "GameFontHighlightSmall", 11)
    w.info:SetTextColor(0.62, 0.62, 0.62)
    w.teamIcon = icon(row, 20)
    w.teamIcon:SetPoint("LEFT", 0, 0)
    w.teamIcon:SetTexture(TEAM_ICON)
    w.whisper = smallButton(row, "Whisper", function(self)
        local d = self:GetParent().__cdlData
        if d and d.key then whisper(d.via or d.key, d.recipe) end
    end)
    w.whisper:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Whisper")
        GameTooltip:AddLine("Opens a message with the recipe linked.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    w.whisper:HookScript("OnLeave", function() GameTooltip:Hide() end)
    w.mainBtn = smallButton(row, "Change", function(self) mainMenu(self) end)

    -- an equipment slot: slot name, item icon, item name (quality colour)
    w.slot = text(row, "GameFontHighlightSmall", 10)
    w.slot:SetTextColor(0.55, 0.55, 0.57)
    w.slot:SetPoint("LEFT", 0, 0)
    w.itemIcon = icon(row, 16)
    w.itemIcon:SetPoint("LEFT", GEAR_X, 0)
    w.item = text(row, "GameFontHighlightSmall", 11)

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
        elseif d.kind == "team" then
            openTeam(d.id)
        elseif d.kind == "gear" and d.item then
            ns.UI:HandleModifiedItemClick(d.item)
        end
    end)
    row:SetScript("OnEnter", function(self)
        local d = self.__cdlData
        if not d then return end
        if d.kind == "recipe" then showRecipeTooltip(self, d.r) end
        if d.kind == "gear" and d.item then showGearTooltip(self, d.item) end
        if d.kind == "crafter" or d.kind == "char" then
            ns.UI:SetTextTooltip(self, { ns.UI:ColoredName(d.key, d.classFile),
                { d.kind == "crafter" and "Click to see everything they can make." or "Click to open their card.",
                  0.7, 0.7, 0.7 } })
        end
        if d.kind == "team" then
            ns.UI:SetTextTooltip(self, { d.name, { "Click to open the team in the Raids tab.", 0.7, 0.7, 0.7 } })
        end
    end)
    row:SetScript("OnLeave", function(self)
        local d = self.__cdlData
        if d and d.kind ~= "recipe" then ns.UI:HideTooltip() else hideRecipeTooltip() end
    end)
    -- Shift: a recipe's (or crafted gear's) materials, + mouse wheel: how many, + clicks: break down / back up
    if ns.Tooltip then
        ns.Tooltip:CraftRow(row, function(self)
            local d = self.__cdlData
            if d and (d.kind == "recipe" or d.kind == "gear") then self:GetScript("OnEnter")(self) end
        end)
    end
end

-- A recipe's name under its group, without the group's words ("Enchant Bracer - Spellpower" under "Enchant Bracer").
local function recipeLabel(r)
    local group = P():GetRecipeGroup(r)
    local rest = r.name:sub(1, #group + 3) == group .. " - " and r.name:sub(#group + 4) or nil
    return (rest and rest ~= "") and rest or r.name
end

-- One line of text in the row: font size, left inset, right inset; foot: on the row's foot (a heading).
local function placeText(w, size, left, right, foot)
    w.text:ClearAllPoints()
    w.text:SetFontObject("GameFontHighlightSmall")
    sized(w.text, size)
    w.text:SetTextColor(1, 1, 1)
    if foot then
        w.text:SetPoint("BOTTOMLEFT", left, 7)
        w.text:SetPoint("BOTTOMRIGHT", -right, 7)
    else
        w.text:SetPoint("LEFT", left, 0)
        w.text:SetPoint("RIGHT", -right, 0)
    end
    w.text:SetWordWrap(false)
    w.text:SetJustifyV("MIDDLE")
end

local function initDetailRow(row, d)
    if not row.cdlInit then detailWidgets(row) end
    local w = row.w
    local kind = d.kind
    local isProf, isPerson, isGear = kind == "prof", kind == "crafter" or kind == "char", kind == "gear"
    for _, r in ipairs({ w.profIcon, w.profName, w.profSpec, w.track, w.fill, w.barText }) do r:SetShown(isProf) end
    w.chevron:SetShown((isProf and d.canOpen or kind == "team") and true or false)
    w.right:SetShown(isProf)
    w.icon:SetShown(kind == "recipe")
    w.tag:Hide()
    w.rule:SetShown(kind == "head")
    w.value:SetShown(kind == "main")
    if not isPerson then hidePerson(row) end
    w.info:SetShown(isPerson or kind == "team")
    w.teamIcon:SetShown(kind == "team")
    w.whisper:SetShown(kind == "crafter" and d.canWhisper and true or false)
    w.mainBtn:SetShown(kind == "main" and d.canChange and true or false)
    w.slot:SetShown(isGear)
    w.itemIcon:SetShown(isGear and d.item ~= nil)
    w.item:SetShown(isGear)
    w.text:SetShown(not isProf and not isPerson and not isGear)
    local clickable = kind == "recipe" or kind == "team" or isPerson or (isProf and d.canOpen) or (isGear and d.item)
    row.hl:SetAlpha(clickable and 1 or 0)
    row:SetAlpha(1)
    local width = cardWidth()

    if isProf then
        local def = P():GetProfession(d.id)
        local e = d.e
        w.profIcon:SetTexture(def.icon)
        w.profName:SetText(P():GetName(d.id))
        w.profSpec:SetText(shortSpecName(e) or "")
        local share = e.max > 0 and math.min(1, e.rank / e.max) or 0
        w.fill:SetWidth(math.max(1, math.floor(150 * share + 0.5)))
        w.fill:SetShown(e.rank > 0)
        if e.rank >= e.max and e.max > 0 then
            -- (maxed: a soft gold; the skill still climbing: a quiet blue)
            w.fill:SetColorTexture(1, 1, 1, 1)
            if w.fill.SetGradient and CreateColor then
                w.fill:SetGradient("HORIZONTAL", CreateColor(0.45, 0.35, 0.06, 1), CreateColor(0.8, 0.64, 0.1, 1))
            else
                w.fill:SetColorTexture(0.7, 0.56, 0.08, 1)
            end
        else
            w.fill:SetColorTexture(0.42, 0.5, 0.69, 1)
        end
        w.barText:SetText(("%d / %d"):format(e.rank, e.max))
        -- (my own unread ones: the line under the professions says what to do, once)
        w.right:SetText((d.mine and e.total == 0) and "" or recipeCountText(e))
        w.right:ClearAllPoints()
        w.right:SetPoint("RIGHT", d.canOpen and -16 or 0, 0)
        setChevron(w.chevron, not state.open[d.id])
        w.chevron:ClearAllPoints()
        w.chevron:SetPoint("RIGHT", 0, 0)
    elseif isPerson then
        if kind == "char" then
            d.tag = d.isMain and "Main" or nil
            fillPerson(row, 0, width, d)
            w.info:SetText("")
        else
            -- a crafter: the skill and specialisation instead of the professions
            fillPerson(row, 0, width, d, true)
            local parts = {}
            if d.rank > 0 then parts[#parts + 1] = tostring(d.rank) end
            local spec = d.e and shortSpecName(d.e) or specName(d.spec)
            if spec then parts[#parts + 1] = spec end
            if d.via then
                parts[#parts + 1] = "|cff3ccf5con " .. shortName(d.via) .. " now|r"
            elseif d.status ~= "online" then
                parts[#parts + 1] = STATUS_WORD[d.status]
            end
            -- (on the right like the roster's professions, before Whisper)
            w.info:SetText(table.concat(parts, " · "))
            w.info:ClearAllPoints()
            w.info:SetPoint("LEFT", 150, 0)
            w.info:SetPoint("RIGHT", w.whisper:IsShown() and -(w.whisper:GetWidth() + 12) or 0, 0)
            w.info:SetJustifyH("RIGHT")
        end
        row:SetAlpha((d.status == "offline" and not d.via) and 0.55 or 1)
    elseif isGear then
        w.slot:SetText(d.label)
        w.item:ClearAllPoints()
        w.item:SetPoint("RIGHT", 0, 0)
        if d.item then
            w.itemIcon:SetTexture((C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(d.item))
                or (GetItemIcon and GetItemIcon(d.item)) or 134400)
            w.item:SetText(ns.UI:ItemText(d.item))
            w.item:SetPoint("LEFT", GEAR_X + 22, 0)
        else
            w.item:SetText("|cff5a5a5e-|r")
            w.item:SetPoint("LEFT", GEAR_X, 0)
        end
    elseif kind == "recipe" then
        w.icon:SetTexture(P():GetRecipeIcon(d.r))
        local only = #d.r.crafters == 1
        w.tag:SetShown(only)
        if only then w.tag:Set("only crafter") end
        placeText(w, 11, 61, only and (w.tag:GetWidth() + 8) or 0)
        w.text:SetTextColor(0.9, 0.9, 0.9)
        w.text:SetText(recipeLabel(d.r))
    elseif kind == "group" then
        placeText(w, 10, 40, 0, true)
        w.text:SetTextColor(0.55, 0.55, 0.57)
        w.text:SetText(d.text)
    elseif kind == "head" then
        placeText(w, 11, 0, 0, true)
        w.text:SetTextColor(1, 0.82, 0)
        w.text:SetText(d.text)
    elseif kind == "source" then
        placeText(w, 10, 0, 0)
        w.text:SetTextColor(0.55, 0.55, 0.57)
        w.text:SetText(d.text)
    elseif kind == "team" then
        placeText(w, 12, NAME_DX, 90)
        w.text:SetText(d.name)
        w.info:SetText(("%d members"):format(d.size))
        w.info:ClearAllPoints()
        w.info:SetPoint("RIGHT", -18, 0)
        w.info:SetJustifyH("RIGHT")
        setChevron(w.chevron, true)
        w.chevron:ClearAllPoints()
        w.chevron:SetPoint("RIGHT", 0, 0)
    elseif kind == "main" then
        -- my main: a label, the character, Change
        placeText(w, 11, 0, 0)
        w.text:SetTextColor(0.62, 0.62, 0.62)
        w.text:SetText("Main character")
        w.value:SetText(d.main and ns.UI:ColoredName(d.main) or "|cff8a8a8enot picked|r")
    else
        w.text:ClearAllPoints()
        w.text:SetFontObject("GameFontHighlightSmall")
        sized(w.text, 10)
        w.text:SetTextColor(0.55, 0.55, 0.57)
        w.text:SetPoint("TOPLEFT", 0, -7)
        w.text:SetPoint("BOTTOMRIGHT", -4, 7)
        w.text:SetWordWrap(true)
        w.text:SetJustifyV("TOP")
        w.text:SetText(d.text)
    end
end

local function isOwn(key)
    for _, own in ipairs(P():GetOwnCharacters()) do
        if own == key then return true end
    end
    return false
end

-- Characters: the player's other characters (main first, tagged), on my own characters which one is my main (Change),
-- then the player's raid teams.
local function characterRows(key)
    local rows = {}
    local others = P():GetOtherCharacters(key)
    local main = P():GetMain(key)
    table.sort(others, function(a, b)
        if (a == main) ~= (b == main) then return a == main end
        return shortName(a):lower() < shortName(b):lower()
    end)
    for _, c in ipairs(others) do
        rows[#rows + 1] = { kind = "char", key = c, isMain = c == main, status = statusOf(c), classFile = classOf(c),
                            level = levelOf(c), specs = P():GetSpecs(c), profs = P():GetMember(c) }
    end
    if isOwn(key) then
        local own = P():GetOwnCharacters()
        if #own > 1 then
            local linked = main ~= key or #others > 0
            rows[#rows + 1] = { kind = "main", canChange = true, main = linked and main or nil,
                                text = linked and ("your main: " .. shortName(main)) or "your main: not picked" }
        elseif ns.Util.IsMe(key) then
            rows[#rows + 1] = { kind = "note", text = "Alts: log in once on each of your other characters in the guild, "
                .. "then pick your main here. The guild then sees them as one player." }
        end
    elseif #others == 0 then
        rows[#rows + 1] = { kind = "note", text = shortName(key) .. " has no other characters linked to this one." }
    end
    -- the player's raid teams (any of their characters): click one to open it in the Raids tab
    local teams = teamsOf(key)
    if #teams > 0 then
        rows[#rows + 1] = { kind = "head", text = #teams == 1 and "Raid team" or "Raid teams" }
        for _, t in ipairs(teams) do
            rows[#rows + 1] = { kind = "team", id = t.id, name = t.name, size = #t.members, text = t.name }
        end
    end
    return rows
end

local function professionRows(key)
    local rows = {}
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
    local mine = ns.Util.IsMe(key)
    for _, e in ipairs(profs) do
        local def = P():GetProfession(e.id)
        local canOpen = def.crafts and e.recipes > 0
        rows[#rows + 1] = { kind = "prof", id = e.id, e = e, canOpen = canOpen, mine = mine }
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
                rows[#rows + 1] = { kind = "group", text = name }
                for _, r in ipairs(groups[name]) do rows[#rows + 1] = { kind = "recipe", r = r } end
            end
        end
    end
    if mine then
        local names = {}
        for _, id in ipairs(P():GetUnscanned()) do names[#names + 1] = P():GetName(id) end
        if #names > 0 then
            rows[#rows + 1] = { kind = "note", text = "Open your " .. table.concat(names, " / ")
                .. " window once: DisasterZone reads your recipes from it and shares them with the guild." }
        end
    end
    return rows
end

-- Equipment: what the character wears, mine live, the others' as they last shared it with the guild (their BiS
-- lists stay with the loot council).
local function gearRows(key)
    local rows = {}
    local gear, at
    if ns.Util.IsMe(key) then
        gear = {}
        for sid, slot in ipairs(ns.SLOTS or {}) do
            local id = GetInventoryItemID("player", slot.invSlot)
            if type(id) == "number" and id > 0 then gear[sid] = id end
        end
        rows[1] = { kind = "source", text = "What you wear now. The guild sees it as you last logged it." }
    else
        gear, at = P():GetGear(key)
        if not gear then
            rows[1] = { kind = "note", text = shortName(key) .. " has not shared their gear yet. It appears once they "
                .. "log in with DisasterZone 1.3 or newer." }
            return rows
        end
        rows[1] = { kind = "source", text = "Worn when " .. shortName(key) .. " last shared it, "
            .. (ns.Util.FormatAgo and ns.Util.FormatAgo(at) or date("%d %b", at)) .. "." }
    end
    if not next(gear) then
        -- (not a column of dashes: one line)
        rows[1].text = ns.Util.IsMe(key) and "You wear nothing right now."
            or rows[1].text:gsub("^Worn when", "Nothing worn when")
        return rows
    end
    for sid, slot in ipairs(ns.SLOTS or {}) do
        rows[#rows + 1] = { kind = "gear", label = slot.label, item = gear[sid] }
    end
    return rows
end

local function memberDetailRows(key)
    if state.card == "chars" then return characterRows(key) end
    if state.card == "gear" then return gearRows(key) end
    return professionRows(key)
end

local function recipeDetailRows(recipe)
    local rows = {}
    local crafters = sortedCrafters(recipe)
    local online = 0
    for _, c in ipairs(crafters) do
        if c.online then online = online + 1 end
    end
    rows[1] = { kind = "head", text = "Crafters" }
    for _, c in ipairs(crafters) do
        local target = c.via or c.key
        rows[#rows + 1] = { kind = "crafter", key = c.key, via = c.via, status = statusOf(c.key), rank = c.rank,
                            spec = c.spec, e = c.e, recipe = recipe, classFile = classOf(c.key), level = levelOf(c.key),
                            canWhisper = c.online and not ns.Util.IsMe(target) }
    end
    if online == 0 then
        rows[#rows + 1] = { kind = "note", text = "Nobody who can make this is online right now." }
    end
    return rows
end

----------------------------------------------------------------------------
-- The card's header, spec chips and the officer note (right)
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

-- The officer note (officers only, when there is one): a quiet flat card sized to its text, under the specs. The
-- header's note icon adds one. Returns the card's height (0: none).
local function updateNote(right, member)
    local notes = N()
    local note = right.note
    local officer = member ~= nil and notes ~= nil and notes:CanUse()
    local rec = officer and notes:Get(member) or nil
    note:SetShown(rec ~= nil)
    right.addNote:SetShown(officer and rec == nil)
    right.addNote.key = member
    if not rec then return 0 end
    note.key = member
    local day = (date("%d %b", rec.rev):gsub("^0", ""))
    note.meta:SetText(notes:IsLocalOnly() and "|cffff9933debug role: test notes, kept on this PC only|r"
        or ("%s · %s"):format(rec.by and shortName(rec.by) or "?", day))
    local tw = cardWidth() - 24
    note.text:SetWidth(tw)
    note.text:SetText(rec.text)
    -- its lines from the text's width (a wrap measure needs a laid out frame, which a first show may not have yet)
    local wide = note.text.GetUnboundedStringWidth and note.text:GetUnboundedStringWidth() or note.text:GetStringWidth()
    local _, breaks = rec.text:gsub("\n", "")
    local lines = math.max(1, math.min(NOTE_MAX_LINES, math.ceil((wide or 0) * 1.12 / tw) + breaks))
    note.text:SetHeight(lines * NOTE_LINE)
    local h = 26 + lines * NOTE_LINE + 9
    note:SetHeight(h)
    return h
end

-- The spec chips under a member's header: main (its talent points), then the off spec. Returns how many.
local function updateSpecs(right, member)
    local classFile = member and classOf(member)
    local specs = member and P():GetSpecs(member) or {}
    local x, n = 0, 0
    for i, chip in ipairs(right.specChips) do
        local spec = specs[i]
        chip:SetShown(spec ~= nil)
        if spec then
            n = n + 1
            local label, path = specInfo(classFile, spec)
            chip.icon:SetTexture(path or 134400)
            chip.label:SetText(label)
            local emText = i == 1 and (spec.points and table.concat(spec.points, "/") or "") or "off spec"
            chip.em:SetText(emText)
            local w = 25 + (chip.label:GetStringWidth() or 60)
            local em = emText ~= "" and ((chip.em:GetStringWidth() or 30) + 5) or 0
            chip:SetWidth(math.floor(w + em + 9.5))
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", x, -SPECS_Y)
            x = x + chip:GetWidth() + 6
        end
    end
    return n
end

local function fitTitle(fs, t, room)
    fs:SetText(t)
    for _, size in ipairs({ 18, 16, 14 }) do
        sized(fs, size)
        if (fs:GetStringWidth() or 0) <= room then return end
    end
end

-- One line from parts in priority order (" · " between them): the lowest ones are dropped until it fits `room`
-- (never "..."; the header's tooltip has them all).
local function fitParts(fs, parts, room)
    local n = #parts
    while true do
        fs:SetText(table.concat(parts, " · ", 1, n))
        local w = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
        if n <= 1 or (w or 0) <= room then return end
        n = n - 1
    end
end

-- The header's icon buttons (right to left after Whisper / Link in chat): share, add an officer note; all on the
-- name's row, top-aligned with the avatar, so the meta line under the name has the card's whole width. Returns the
-- width they take.
local function placeHeaderButtons(right, btn)
    local prev = btn
    for _, b in ipairs({ right.onMap, right.share, right.addNote }) do
        b:ClearAllPoints()
        if b:IsShown() then
            if prev then b:SetPoint("RIGHT", prev, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", 0, -HEAD_BTN_Y) end
            prev = b
        end
    end
    local used = 0
    for _, b in ipairs({ btn, right.onMap, right.share, right.addNote }) do
        if b and b:IsShown() then used = used + b:GetWidth() + 6 end
    end
    return used
end

local function updateDetail(p)
    local right = p.right
    local recipe = state.mode == "recipes" and state.recipe and P():GetRecipe(state.recipe) or nil
    local member = state.mode == "roster" and state.member or nil
    right.whisper:Hide()
    right.link:Hide()
    right.ring:SetShown(member ~= nil)
    right.ringIn:SetShown(member ~= nil)
    right.iconEdge:SetShown(recipe ~= nil)
    right.dot:Hide()
    -- a member: header, the specs, the note, the card's tabs, the list (each step only when it has something); a
    -- recipe: header, the list
    local y = (updateSpecs(right, member) > 0) and (SPECS_Y + SPEC_H + 8) or SPECS_Y
    right.note:ClearAllPoints()
    right.note:SetPoint("TOPLEFT", 0, -y)
    right.note:SetPoint("TOPRIGHT", 0, -y)
    local noteH = updateNote(right, member)
    if noteH > 0 then y = y + noteH + 8 end
    for key, b in pairs(right.cards) do
        b:SetShown(member ~= nil)
        b:SetActive(key == state.card)
    end
    right.cards.chars:ClearAllPoints()
    right.cards.chars:SetPoint("BOTTOMLEFT", right, "TOPLEFT", -4, -(y + CARDTABS_H))
    right.tabLine:SetShown(member ~= nil)
    right.tabLine:ClearAllPoints()
    right.tabLine:SetPoint("TOPLEFT", 0, -(y + CARDTABS_H))
    right.tabLine:SetPoint("TOPRIGHT", 0, -(y + CARDTABS_H))
    local listTop = member and (y + CARDTABS_H + 4) or (HEAD_H + 10)
    right.list.frame:ClearAllPoints()
    right.list.frame:SetPoint("TOPLEFT", 0, -listTop)
    right.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    right.list:SetEmptyText("")
    local btn
    local metaX = 56
    if recipe then
        right.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        right.icon:SetVertexColor(1, 1, 1)
        right.icon:SetTexture(P():GetRecipeIcon(recipe))
        right.icon:Show()
        right.title:SetTextColor(1, 0.82, 0)
        if recipe.item > 0 and ns.ItemDB and ns.ItemDB.GetInfo then
            local _, _, q = ns.ItemDB:GetInfo(recipe.item)
            if q then right.title:SetTextColor(ns.UI:QualityColor(q)) end
        end
        right.sub:SetText(P():GetName(recipe.prof) .. " · " .. P():GetRecipeGroup(recipe))
        right.link:Show()
        btn = right.link
        right.list:SetData(recipeDetailRows(recipe))
    elseif member then
        local g = G()
        local m = g and g:GetMember(member)
        local classFile = classOf(member)
        right.icon:SetVertexColor(1, 1, 1)
        ns.UI:ClassIcon(right.icon, classFile)
        local cr, cg, cb = ns.UI:ClassColor(classFile)
        right.ring:SetVertexColor(cr, cg, cb, 0.55)
        right.title:SetTextColor(cr, cg, cb)
        local status = statusOf(member)
        local col = STATUS_COLOR[status]
        if col then
            right.dot:SetVertexColor(col[1], col[2], col[3], 1)
            right.dot:Show()
            metaX = 69
        end
        -- the meta line, most important first: rank (or whose alt), level, presence, their DisasterZone when it is
        -- not the one I run
        local parts = {}
        local main = P():GetMain(member)
        if main ~= member then
            parts[#parts + 1] = "Alt of " .. ns.UI:ColoredName(main)
        elseif m and m.rankName then
            parts[#parts + 1] = m.rankName
        end
        local level = levelOf(member)
        if level then parts[#parts + 1] = "Level " .. level end
        parts[#parts + 1] = STATUS_WORD[status]
        -- where they are (Guild > Map, while we both share): "In Halaa, Nagrand", else "Last seen in Nagrand, 2h ago"
        local where = ns.GuildMap and ns.GuildMap:GetWhere(member)
        if where and not ns.Util.IsMe(member) then
            local place = where.inst or (where.sub and where.zone and (where.sub .. ", " .. where.zone)) or where.zone
            if place and where.live then
                parts[#parts + 1] = "In " .. place
            elseif place then
                parts[#parts + 1] = "Last seen in " .. place .. ", " .. ns.Util.FormatAgo(where.t)
            end
        end
        right.onMap.key = (where and where.live and not ns.Util.IsMe(member)) and member or nil
        local vst, v = versionOf(member)
        if vst == "older" or vst == "newer" then parts[#parts + 1] = "|cff8a8a8eDisasterZone|r " .. tostring(v) end
        right.metaParts = parts
        local on = onlineCharacter(member)
        right.whisperTarget = on
        right.whisper:SetText(on and on ~= member and ("Whisper " .. shortName(on)) or "Whisper")
        right.whisper:SetWidth(math.floor((right.whisper:GetFontString():GetStringWidth() or 50) + 28.5))
        right.whisper:SetShown(on ~= nil and not ns.Util.IsMe(on))
        if right.whisper:IsShown() then btn = right.whisper end
        right.list:SetData(memberDetailRows(member))
    else
        right.icon:Hide()
        right.title:SetText("")
        right.sub:SetText("")
        right.list:SetData({})
    end
    right.sub:ClearAllPoints()
    right.sub:SetPoint("TOPLEFT", metaX, -28)
    right.share:SetShown(recipe ~= nil or member ~= nil)
    right.onMap:SetShown(member ~= nil and right.onMap.key ~= nil)
    local used = placeHeaderButtons(right, btn)
    right.headHit:SetShown(recipe ~= nil or member ~= nil)
    if recipe or member then
        -- the name up to the buttons; the meta line under them has the card's whole width
        local room = cardWidth() - 56 - 8 - used
        local name = recipe and recipe.name or ns.UI:ColoredName(member, classOf(member))
        fitTitle(right.title, name, room)
        right.title:SetWidth(room)
        right.sub:SetWidth(cardWidth() - metaX)
        if member then fitParts(right.sub, right.metaParts, cardWidth() - metaX) end
        right.headHit:SetWidth(56 + room)
    end
end

----------------------------------------------------------------------------
-- Toolbar: view tabs, search, the profession filter
----------------------------------------------------------------------------

-- The professions somebody in the guild has (a filter that finds nobody is left out), in the game's order.
local function professionOptions()
    local counts = P():GetCounts()
    local out = { { value = nil, text = "All professions" } }
    for _, def in ipairs(P():GetProfessions()) do
        if (counts[def.id] or 0) > 0 or state.prof == def.id then
            out[#out + 1] = { value = def.id, text = ns.UI:IconText(def.icon, 14) .. " " .. P():GetName(def.id) }
        end
    end
    return out
end

local function updateToolbar(p)
    p.rosterBtn:SetActive(state.mode == "roster")
    p.recipesBtn:SetActive(state.mode == "recipes")
    if p.search.Instructions then
        p.search.Instructions:SetText(state.mode == "recipes" and "Search recipes" or "Search members")
    end
    p.profDD:Refresh()
    -- (no counts of members or recipes: the lists show them; only a sync still running is worth a word)
    p.status:SetText(P():GetStats().missing > 0 and "Receiving recipes" or "")
end

----------------------------------------------------------------------------
-- Panel
----------------------------------------------------------------------------

-- A scroll list: its rows run the frame's width less `reserve` (the bar's lane), the bar barX right of the rows.
local function scrollList(parent, rowHeight, initRow, extentFn, barX, reserve)
    local list = ns.UI:CreateScrollList(parent, rowHeight, initRow, extentFn)
    list.box:ClearAllPoints()
    list.box:SetPoint("TOPLEFT", list.frame, "TOPLEFT", 0, 0)
    list.box:SetPoint("BOTTOMRIGHT", list.frame, "BOTTOMRIGHT", -(reserve or 0), 0)
    list.bar:ClearAllPoints()
    list.bar:SetPoint("TOPLEFT", list.box, "TOPRIGHT", barX or 1, 0)
    list.bar:SetPoint("BOTTOMLEFT", list.box, "BOTTOMRIGHT", barX or 1, 0)
    list.emptyText:ClearAllPoints()
    list.emptyText:SetPoint("TOPLEFT", list.frame, "TOPLEFT", 8, -24)
    list.emptyText:SetPoint("TOPRIGHT", list.frame, "TOPRIGHT", -8, -24)
    return list
end

local function createCard(p)
    local UI = ns.UI
    local right = CreateFrame("Frame", nil, p)
    right:SetPoint("TOPLEFT", CARD_X, -TOP)
    right:SetPoint("BOTTOMRIGHT", -PAD, BOTTOM)
    p.right = right

    -- the header: the class circle in a ring of the class colour (or the recipe's icon), the name, a meta line
    right.ring = disc(right, "BACKGROUND", 1, 48)
    right.ring:SetPoint("TOPLEFT", -2, 2)
    right.ringIn = disc(right, "BACKGROUND", 2, 46, { 0, 0, 0, 1 })
    right.ringIn:SetPoint("TOPLEFT", -1, 1)
    right.iconEdge = right:CreateTexture(nil, "BACKGROUND", nil, 2)
    right.iconEdge:SetColorTexture(0, 0, 0, 1)
    right.iconEdge:SetSize(HEAD_H + 2, HEAD_H + 2)
    right.iconEdge:SetPoint("TOPLEFT", -1, 1)
    right.icon = right:CreateTexture(nil, "ARTWORK")
    right.icon:SetSize(HEAD_H, HEAD_H)
    right.icon:SetPoint("TOPLEFT", 0, 0)
    -- hovering the icon and name: the recipe's tooltip, or everything about the member (the meta line may have
    -- dropped parts to fit)
    right.headHit = CreateFrame("Frame", nil, right)
    right.headHit:SetPoint("TOPLEFT", 0, 0)
    right.headHit:SetSize(HEAD_H, HEAD_H)
    right.headHit:EnableMouse(true)
    right.headHit:SetScript("OnEnter", function(self)
        if state.mode == "recipes" then
            local r = state.recipe and P():GetRecipe(state.recipe)
            if r then showRecipeTooltip(self, r) end
        elseif state.member then
            memberTooltip(self, memberRow(state.member))
        end
    end)
    right.headHit:SetScript("OnLeave", hideRecipeTooltip)
    if ns.Tooltip then
        ns.Tooltip:CraftRow(right.headHit, function(self)
            if state.mode == "recipes" then self:GetScript("OnEnter")(self) end
        end)
    end
    right.title = text(right, "GameFontNormalLarge", 18)
    right.title:SetPoint("TOPLEFT", 56, -5)
    right.dot = disc(right, "ARTWORK", 0, 7)
    right.dot:SetPoint("TOPLEFT", 56, -30)
    right.sub = text(right, "GameFontHighlightSmall", 11)
    right.sub:SetTextColor(0.75, 0.75, 0.77)
    right.whisper = UI:CreateSleekButton(right, "Whisper", 84, 22, function()
        if right.whisperTarget then whisper(right.whisperTarget) end
    end, "primary")
    right.whisper:SetPoint("TOPRIGHT", 0, -HEAD_BTN_Y)
    right.link = UI:CreateSleekButton(right, "Link in chat", 96, 22, function()
        local r = state.recipe and P():GetRecipe(state.recipe)
        if r then linkRecipe(r) end
    end)
    right.link:SetPoint("TOPRIGHT", 0, -HEAD_BTN_Y)
    -- a link to this member's card or this recipe's crafters for the chat (UI/Share.lua)
    right.share = ns.Share:CreateButton(right, 22, function()
        if state.mode == "recipes" then return state.recipe and ns.Share:RecipeRef(state.recipe) or nil end
        return state.member and ns.Share:MemberRef(state.member) or nil
    end)
    -- officers: add an officer note (one there: the note's own pencil edits it)
    right.addNote = UI:CreateTipIconButton(right, 22, UI.ICON.notes, "Add an officer note",
        "Only officers and the Guild Master see it.", function(self)
            if self.key then editNote(self.key) end
        end)
    right.addNote:Hide()
    -- where they stand now, on Guild > Map (shown while they share with me)
    right.onMap = UI:CreateTipIconButton(right, 22, 7, "Show on the map", "Guild > Map, zoomed into where they are.",
        function(self)
            if self.key and ns.GuildMapUI then ns.GuildMapUI:ShowPerson(self.key) end
        end)
    right.onMap:Hide()

    -- the specs as chips: a round icon, the name, the talent points (main) or "off spec"
    right.specChips = {}
    for i = 1, 2 do
        local chip = CreateFrame("Frame", nil, right)
        chip:SetHeight(SPEC_H)
        UI:AddPillShape(chip, SPEC_H)
        chip:SetPillColors({ 0.10, 0.10, 0.12, 0.92 }, { 0.34, 0.34, 0.38, 0.6 })
        chip.icon = chip:CreateTexture(nil, "ARTWORK")
        chip.icon:SetSize(16, 16)
        chip.icon:SetPoint("LEFT", 3, 0)
        if chip.CreateMaskTexture and chip.icon.AddMaskTexture then
            local mask = chip:CreateMaskTexture()
            mask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(chip.icon)
            chip.icon:AddMaskTexture(mask)
        end
        chip.label = text(chip, "GameFontHighlightSmall", 11)
        chip.label:SetPoint("LEFT", 25, 0)
        chip.label:SetTextColor(0.88, 0.88, 0.88)
        chip.em = text(chip, "GameFontHighlightSmall", 10)
        chip.em:SetPoint("LEFT", chip.label, "RIGHT", 5, 0)
        chip.em:SetTextColor(0.62, 0.62, 0.62)
        chip:Hide()
        right.specChips[i] = chip
    end

    -- the officer note: a quiet flat card, sized to its text
    local note = CreateFrame("Frame", nil, right)
    note:SetHeight(48)
    note:EnableMouse(true)
    flatCard(note)
    right.note = note
    note.label = text(note, "GameFontNormalSmall", 11)
    note.label:SetPoint("TOPLEFT", 12, -9)
    note.label:SetText("Officer note")
    note.meta = text(note, "GameFontHighlightSmall", 10)
    note.meta:SetPoint("LEFT", note.label, "RIGHT", 8, 0)
    note.meta:SetTextColor(0.55, 0.55, 0.57)
    -- edit: a bare pencil (grey, white under the mouse), not a boxed button inside the card
    note.edit = CreateFrame("Button", nil, note)
    note.edit:SetSize(18, 18)
    note.edit:SetPoint("TOPRIGHT", -6, -6)
    note.edit.icon = note.edit:CreateTexture(nil, "ARTWORK")
    note.edit.icon:SetSize(12, 12)
    note.edit.icon:SetPoint("CENTER")
    note.edit.icon:SetTexture(UI.ICON_ATLAS)
    note.edit.icon:SetTexCoord(unpack(UI:IconCoords(16)))
    note.edit.icon:SetVertexColor(0.62, 0.62, 0.62)
    note.edit:RegisterForClicks("LeftButtonUp")
    note.edit:SetScript("OnClick", function() if note.key then editNote(note.key) end end)
    note.edit:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(1, 1, 1)
        UI:SetTextTooltip(self, { "Edit the officer note", "Only officers and the Guild Master see it." }, "ANCHOR_TOP")
    end)
    note.edit:SetScript("OnLeave", function(self)
        self.icon:SetVertexColor(0.62, 0.62, 0.62)
        UI:HideTooltip()
    end)
    note.text = note:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sized(note.text, 11)
    note.text:SetTextColor(0.88, 0.88, 0.88)
    note.text:SetPoint("TOPLEFT", 12, -27)
    note.text:SetJustifyH("LEFT")
    note.text:SetJustifyV("TOP")
    note.text:SetWordWrap(true)
    if note.text.SetMaxLines then note.text:SetMaxLines(NOTE_MAX_LINES) end
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

    -- a member's card: small text tabs over the list, on a hairline (placed under the note by updateDetail)
    right.cards = {}
    local prevCard
    for _, c in ipairs(CARDS) do
        local key = c.key
        local b = UI:CreateUnderlineTab(right, c.label, function() MembersUI:SetCard(key) end, "small")
        if prevCard then b:SetPoint("LEFT", prevCard, "RIGHT", 4, 0) end
        right.cards[key] = b
        prevCard = b
    end
    right.tabLine = right:CreateTexture(nil, "BORDER")
    right.tabLine:SetColorTexture(1, 1, 1, 0.1)
    right.tabLine:SetHeight(1)

    right.list = scrollList(right, 20, initDetailRow, detailExtent, 3)
    measure = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sized(measure, 10)
    measure:SetWordWrap(true)
    measure:Hide()
    return right
end

function MembersUI:CreatePanel(parent)
    if panel then return panel end
    local UI = ns.UI
    local p = CreateFrame("Frame", "DisasterZoneMembersPanel", parent)
    p:SetAllPoints(parent)
    panel = p

    -- Roster / Recipes and the search box over the list; the profession filter over the card's right end
    p.rosterBtn = UI:CreateUnderlineTab(p, "Roster", function() MembersUI:SetMode("roster") end)
    p.rosterBtn:SetPoint("TOPLEFT", PAD - 4, -6)
    p.recipesBtn = UI:CreateUnderlineTab(p, "Recipes", function() MembersUI:SetMode("recipes") end)
    p.recipesBtn:SetPoint("LEFT", p.rosterBtn, "RIGHT", 4, 0)
    p.search = UI:CreateSearchBox(p, 190, function(text)
        text = ns.Util.Trim(text or "")
        if text == state.search then return end
        state.search = text
        MembersUI:Refresh(true)
    end, "Search members")
    p.search:SetPoint("LEFT", p.recipesBtn, "RIGHT", 12, 0)
    p.search:SetPoint("RIGHT", p, "TOPLEFT", PAD + ROWS_W, -(6 + CTRL_H / 2))
    p.profDD = UI:CreateSleekDropdown(p, PROF_DD_W, professionOptions, function() return state.prof end, function(v)
        MembersUI:SetProfession(v)
    end)
    p.profDD:SetHeight(CTRL_H)
    p.profDD:SetPoint("TOPRIGHT", -PAD, -6)
    p.status = text(p, "GameFontNormalSmall", 11)
    p.status:SetPoint("RIGHT", p.profDD, "LEFT", -12, 0)
    p.status:SetJustifyH("RIGHT")

    -- the lists: rows ROWS_W wide, their bar in the lane after them (BAR_GAP from the rows and from the card)
    p.roster = scrollList(p, ROW_H, initRosterRow, function(d) return d.kind == "sep" and SEP_H or ROW_H end,
        BAR_GAP, BAR_GAP + BAR_W)
    p.roster.frame:SetPoint("TOPLEFT", PAD, -TOP)
    p.roster.frame:SetPoint("BOTTOMLEFT", PAD, BOTTOM)
    p.roster.frame:SetWidth(LIST_W)

    p.recipes = scrollList(p, RECIPE_H, initRecipeRow, nil, BAR_GAP, BAR_GAP + BAR_W)
    p.recipes.frame:SetPoint("TOPLEFT", PAD, -TOP)
    p.recipes.frame:SetPoint("BOTTOMLEFT", PAD, BOTTOM)
    p.recipes.frame:SetWidth(LIST_W)

    createCard(p)

    -- (a page switch shows the panel, then calls OnPanelShown: one refresh per frame is enough)
    p:SetScript("OnShow", function(self)
        self.shownAt = GetTime()
        MembersUI:Refresh()
    end)
    function p:OnPanelShown()
        if self.shownAt ~= GetTime() then MembersUI:Refresh() end
    end
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
        -- keep the selection while it is listed; else the first recipe (the card is never left empty)
        local found = false
        for _, d in ipairs(rows) do
            if d.r.spell == state.recipe then found = true end
        end
        if not found then state.recipe = rows[1] and rows[1].r.spell or nil end
        p.recipes:SetEmptyText((state.search ~= "" or state.prof) and "No recipe matches."
            or "No recipes shared yet. Open your profession windows once to share yours.")
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

-- "chars" | "profs" | "gear": what a member's card shows.
function MembersUI:SetCard(card)
    state.card = (card == "chars" or card == "gear") and card or "profs"
    self:Refresh()
end

function MembersUI:GetCard() return state.card end

-- Jumps to a member in the Roster view (profId: that profession opened, on the Professions card).
function MembersUI:ShowMember(key, profId)
    state.mode, state.member, state.search = "roster", key, ""
    state.prof = nil
    state.open = profId and { [profId] = true } or {}
    if profId then state.card = "profs" end
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

-- The DisasterZone a member runs: state ("same" | "older" | "newer" | "none"), version, last heard.
function MembersUI:GetVersion(key) return versionOf(key) end

function MembersUI:GetPanel() return panel end
function MembersUI:GetState() return state end

function MembersUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("members", "Members", 3.6, function(parent) return MembersUI:CreatePanel(parent) end)
    end
    local function refresh() MembersUI:RequestRefresh() end
    for _, msg in ipairs({ "PROFESSIONS_UPDATED", "ROSTER_UPDATED", "DEMO_TOGGLED", "OFFICER_NOTES_UPDATED",
                           "PEERS_UPDATED", "ITEMINFO_READY", "GUILDMAP_UPDATED" }) do
        ns:On(msg, refresh)
    end
    ns:RegisterSlash("members", function() ns.MainFrame:Open("members") end,
        "open the Members tab: the guild's professions and who can craft what")
end
