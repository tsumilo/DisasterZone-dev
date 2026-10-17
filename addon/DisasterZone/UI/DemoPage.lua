if DisasterZoneBoot and DisasterZoneBoot.Run("UI/DemoPage.lua", ...) then return end -- DisasterZone UI/DemoPage.lua
-- Settings > Help > Demo mode (the card UI/Settings.lua lists as "demo"; the picker of Core/DemoParts.lua, mockup
-- claude.ai/artifact/TDAHyoxc54tzx3zTcFDHzn): a line that says what plays (Again, Stop all), the quick picks, then
-- three tabs: On screen (a switch per part, by group; class tools of your class, other classes a click away; Combat
-- plays: one pull or a loop), Pages (the demo guild's switch and the pages it fills) and Moments (scenes played once:
-- Play / Stop). /dz demo opens it.
local addonName, ns = ...

local SettingsUI = ns.SettingsUI
local UI, S = ns.UI, ns.Style

local floor, max = math.floor, math.max
local ipairs, pairs, type, format, tostring = ipairs, pairs, type, string.format, tostring

local STATUS_H, CHIP_H, TAB_H = 48, 22, 26
local HEAD_H, ROW_H, TILE = 28, 42, 28
local PICK_H = 30
local GUILD_H, TILE_H, TILE_GAP = 72, 48, 6
local LINE2 = 13                    -- a row's line on two lines: this much taller
local PAD = 12

local function D() return ns.Demo end

local view = { tab = "screen" }      -- the open tab (this session)
local page                          -- the built page (BuildDemo): its frames
local function Grey(t) return S:Wrap("SUB", t) end

local function AddTooltip(frame, title, text)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, S:RGB("GOLD"))
        if text and text ~= "" then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- The tile's picture: an atlas glyph (a number under 1000), a class tool's spell icon, an item's icon, a texture.
local function SetTile(tile, d)
    local icon = d.icon
    if d.kit then
        local kit = ns.ClassKit and ns.ClassKit:Get(d.kit)
        icon = kit and (kit.iconPath or kit.icon)
        if type(icon) == "number" and GetSpellTexture then icon = GetSpellTexture(icon) end
    elseif d.item then
        icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(d.item))
            or (GetItemIcon and GetItemIcon(d.item)) or icon
    end
    tile.tex:ClearAllPoints()
    if type(icon) == "number" and icon < 1000 then
        UI:SetGlyph(tile.tex, icon, "TEXT")
        tile.tex:SetPoint("CENTER")
        tile.tex:SetSize(16, 16)
        tile.glyph = true
    else
        tile.tex:SetAllPoints()
        tile.tex:SetTexture(icon)
        tile.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        tile.tex:SetVertexColor(1, 1, 1)
        tile.glyph = false
    end
    tile:Show()
end

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------

-- A group's head: its name (gold), a hairline, a count and All / None.
local function NewHead(parent, label, onAll)
    local h = CreateFrame("Frame", nil, parent)
    h:SetHeight(HEAD_H)
    h.title = UI:Text(h, "emph", "GOLD")
    h.title:SetPoint("BOTTOMLEFT", h, "BOTTOMLEFT", 0, 6)
    h.title:SetText(label)
    h.rule = h:CreateTexture(nil, "ARTWORK")
    h.rule:SetHeight(1)
    h.rule:SetColorTexture(S:Color("HAIRLINE"))
    h.count = UI:Text(h, "small", "SUB")
    if onAll then
        h.all = UI:CreateTextLink(h, "All", onAll)
        h.all:SetPoint("RIGHT", h, "BOTTOMRIGHT", 0, 12)
        h.count:SetPoint("RIGHT", h.all, "LEFT", -10, 0)
    else
        h.count:SetPoint("RIGHT", h, "BOTTOMRIGHT", 0, 12)
    end
    h.rule:SetPoint("LEFT", h.title, "RIGHT", 10, 0)
    h.rule:SetPoint("RIGHT", h.count, "LEFT", -10, 0)
    return h
end

-- A part's or a moment's row: its tile, name (and a "demo guild" pill), its line, and a switch or Play.
local function NewRow(parent, d)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(ROW_H)
    r.d = d
    r:EnableMouse(true)
    UI:DecorateRow(r)
    r.tile = UI:CreateIconTile(r, TILE)
    r.tile:SetPoint("LEFT", r, "LEFT", 6, 0)
    SetTile(r.tile, d)
    r.name = UI:Text(r, "emph", "TEXT")
    r.name:SetPoint("TOPLEFT", r, "TOPLEFT", 6 + TILE + 12, -6)
    r.name:SetText(d.label)
    r.line = UI:Text(r, "small", "SUB")
    r.line:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
    r.line:SetJustifyH("LEFT")
    r.line:SetWordWrap(true)
    if r.line.SetMaxLines then r.line:SetMaxLines(2) end
    if d.guild then
        r.pill = UI:CreatePill(r, 16)
        r.pill:Set("demo guild", (UI:PillKind("mute")))
        r.pill:SetPoint("LEFT", r.name, "RIGHT", 8, 0)
        AddTooltip(r.pill, "Uses the demo guild", "It runs on the made-up guild: switching it on turns the demo guild on too.")
    end
    if d.kind == "moment" then
        r.play = ns.UI:CreateSleekButton(r, "", 76, 22, function(self)
            local Dm = D()
            if Dm:GetMoment() == d.key then Dm:StopMoment() return end
            local ok, why = Dm:Play(d.key, self)
            if not ok then ns:Print("Demo not started: %s", tostring(why)) end
        end)
        r.play:SetPoint("RIGHT", r, "RIGHT", -6, 0)
        r.ctrlW = 76 + 6
        r.bar = r:CreateTexture(nil, "ARTWORK", nil, 3)
        r.bar:SetHeight(2)
        r.bar:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
        r.bar:SetColorTexture(S:Color("GOLD"))
        r.bar:Hide()
    else
        r.switch = ns.UI:CreateSwitch(r, function() return D():IsOn(d.key) end, function(on)
            D():SetOn(d.key, on)
        end)
        r.switch:SetPoint("RIGHT", r, "RIGHT", -6, 0)
        r.switch.label = r.name
        r.ctrlW = 40
        SettingsUI.refreshers[#SettingsUI.refreshers + 1] = r.switch
    end
    r.line:SetPoint("RIGHT", r, "RIGHT", -(r.ctrlW + 12), 0)
    AddTooltip(r, d.label, (d.desc or "") .. "\n\n" .. Grey("/dz demo " .. d.word))
    return r
end

local function NewPageTile(parent, p)
    local t = UI:CreateCard(parent, { tone = "card", pad = 0, onClick = function()
        if not D():IsEnabled() then return end
        if ns.MainFrame then ns.MainFrame:Open(p.key) end
    end })
    t:SetHeight(TILE_H)
    t.glyph = t:CreateTexture(nil, "ARTWORK")
    t.glyph:SetSize(13, 13)
    t.glyph:SetPoint("TOPLEFT", t, "TOPLEFT", 9, -9)
    UI:SetGlyph(t.glyph, p.icon, "SUB")
    t.name = UI:Text(t, "body", "TEXT")
    t.name:SetPoint("TOPLEFT", t, "TOPLEFT", 30, -8)
    t.name:SetText(p.label)
    t.line = UI:Text(t, "small", "SUB")
    t.line:SetPoint("TOPLEFT", t.name, "BOTTOMLEFT", 0, -3)
    t.line:SetPoint("RIGHT", t, "RIGHT", -8, 0)
    t.line:SetWordWrap(false)
    t.line:SetText(p.line)
    t.go = UI:Text(t, "small", "GOLD")
    t.go:SetPoint("TOPRIGHT", t, "TOPRIGHT", -8, -9)
    t.go:SetText("Open \226\128\186")
    t.go:Hide()
    t:HookScript("OnEnter", function(self) self.go:SetShown(D():IsEnabled()) end)
    t:HookScript("OnLeave", function(self) self.go:Hide() end)
    t.p = p
    return t
end

-- The pages the demo guild fills (MainFrame keys), their glyph and a line.
local PAGES = {
    { key = "home", label = "Home", icon = 45, line = "Calendar, the next raid" },
    { key = "council", label = "Council", icon = 64, line = "18 BiS lists, votes, loot log" },
    { key = "raids", label = "Raids", icon = 46, line = "Past raids, attendance" },
    { key = "members", label = "Members", icon = 61, line = "Ranks, professions, notes" },
    { key = "map", label = "Guild map", icon = 7, line = "Who is where right now" },
    { key = "events", label = "Events", icon = 51, line = "Library, duel cup, season" },
    { key = "polls", label = "Polls", icon = 55, line = "Open and closed polls" },
    { key = "dungeons", label = "Groups", icon = 46, line = "Dungeon runs, quests" },
    { key = "recruit", label = "Recruitment", icon = 39, line = "Recruits at each stage" },
    { key = "feedback", label = "Feedback", icon = 42, line = "Bugs and ideas, the plan" },
    { key = "mylog", label = "My Log", icon = 58, line = "Six weeks of your pulls" },
    { key = "wardrobe", label = "Wardrobe", icon = 40, line = "Four Retribution outfits" },
}

-- The classes that have class tools, in the parts' order.
local function ToolClasses()
    local out, seen = {}, {}
    for _, d in ipairs(D():Parts("screen", "class")) do
        if d.class and not seen[d.class] then seen[d.class] = true; out[#out + 1] = d.class end
    end
    return out
end

local function MyClass() local _, c = UnitClass("player"); return c end

function SettingsUI:BuildDemo(sec)
    local Dm = D()
    if not (Dm and Dm.Parts) then sec.height = 0 return end
    local p = { sec = sec, heads = {}, rows = {}, tiles = {}, chips = {}, classChips = {} }
    page = p
    self.demo = p

    -- the line that says what plays
    local st = UI:CreateCard(sec, { tone = "card", pad = 0 })
    st:SetHeight(STATUS_H)
    st.orb = st:CreateTexture(nil, "ARTWORK")
    st.orb:SetSize(10, 10)
    st.orb:SetTexture("Interface\\AddOns\\DisasterZone\\Media\\Strategy\\disc")
    st.orb:SetPoint("LEFT", st, "LEFT", 16, 0)
    st.title = UI:Text(st, "emph", "TEXT")
    st.title:SetPoint("TOPLEFT", st, "TOPLEFT", 38, -9)
    st.line = UI:Text(st, "small", "SUB")
    st.line:SetPoint("TOPLEFT", st.title, "BOTTOMLEFT", 0, -4)
    st.line:SetWordWrap(false)
    st.stop = ns.UI:CreateSleekButton(st, "Stop all", 80, 22, function()
        Dm:StopAll(true)
    end)
    st.stop:SetPoint("RIGHT", st, "RIGHT", -12, 0)
    AddTooltip(st.stop, "Stop all", "Every part off the screen, the moment stopped and the demo guild off. Your picks are kept for Play my picks.")
    st.again = ns.UI:CreateSleekButton(st, "Again", 64, 22, function() Dm:StartPull() end)
    st.again:SetPoint("RIGHT", st.stop, "LEFT", -6, 0)
    AddTooltip(st.again, "Play the pull again", "The combat parts play their made-up pull from the start.")
    st.mine = ns.UI:CreateSleekButton(st, UI:AtlasIconText(47, 10, S.C.GOLD) .. " Play my picks", 116, 22, function()
        Dm:PlayPicks()
    end, "primary")
    st.mine:SetPoint("RIGHT", st, "RIGHT", -12, 0)
    AddTooltip(st.mine, "Play my picks", "Starts the parts you had on last time. Nothing starts by itself after a /reload.")
    st:SetScript("OnUpdate", function(f, el)
        f.acc = (f.acc or 0) + el
        if f.acc < 0.25 then return end
        f.acc = 0
        if f.live then SettingsUI:PaintDemoStatus() end
    end)
    p.status = st

    -- quick picks
    local qp = CreateFrame("Frame", nil, sec)
    qp:SetHeight(CHIP_H)
    qp.label = UI:Text(qp, "caps", "DIM")
    qp.label:SetPoint("LEFT", qp, "LEFT", 0, 0)
    qp.label:SetText("Quick picks")
    local last = qp.label
    for _, pr in ipairs(Dm.PRESETS) do
        local chip = UI:CreateChip(qp, { kind = "plain", text = pr.label, onClick = function()
            Dm:Preset(pr.key)
            SettingsUI:SetDemoTab(pr.key == "pages" and "pages" or "screen")
        end })
        chip:SetPoint("LEFT", last, "RIGHT", last == qp.label and 10 or 6, 0)
        AddTooltip(chip, pr.label, pr.tip)
        chip.key = pr.key
        p.chips[#p.chips + 1] = chip
        last = chip
    end
    p.quick = qp

    -- the tabs (and Combat plays on the first)
    local tabs = CreateFrame("Frame", nil, sec)
    tabs:SetHeight(TAB_H)
    tabs.rule = tabs:CreateTexture(nil, "BORDER")
    tabs.rule:SetHeight(1)
    tabs.rule:SetPoint("BOTTOMLEFT")
    tabs.rule:SetPoint("BOTTOMRIGHT")
    tabs.rule:SetColorTexture(S:Color("HAIRLINE"))
    tabs.list = {}
    local prev
    for _, t in ipairs({ { "screen", "On screen" }, { "pages", "Pages" }, { "moments", "Moments" } }) do
        local b = UI:CreateUnderlineTab(tabs, t[2], function() SettingsUI:SetDemoTab(t[1]) end, "page")
        b:SetPoint("BOTTOMLEFT", prev or tabs, prev and "BOTTOMRIGHT" or "BOTTOMLEFT", prev and 14 or 0, 0)
        b.key = t[1]
        tabs.list[#tabs.list + 1] = b
        prev = b
    end
    tabs.mode = UI:CreateSegments(tabs, { { key = "once", label = "One pull" }, { key = "loop", label = "Loop" } },
        function(key) Dm:SetMode(key) end, { h = 20, selected = Dm:GetMode() })
    tabs.mode:SetPoint("BOTTOMRIGHT", tabs, "BOTTOMRIGHT", 0, 4)
    tabs.modeLabel = UI:Text(tabs, "small", "SUB")
    tabs.modeLabel:SetPoint("RIGHT", tabs.mode, "LEFT", -8, 0)
    tabs.modeLabel:SetText("Combat plays")
    AddTooltip(tabs.mode, "Combat plays", "One pull: the combat parts play a made-up 30-second pull, then stop (Again plays "
        .. "it once more). Loop: they play until you switch them off.")
    p.tabs = tabs

    -- On screen: a head per group, the class picker in Class tools, a row per part
    for _, g in ipairs(Dm.GROUPS.screen) do
        local key = g[1]
        local h = NewHead(sec, g[2], function() SettingsUI:DemoGroupAll(key) end)
        h.group, h.tab = key, "screen"
        p.heads[#p.heads + 1] = h
        if key == "class" then
            local pick = CreateFrame("Frame", nil, sec)
            pick:SetHeight(PICK_H)
            pick.label = UI:Text(pick, "small", "SUB")
            pick.label:SetPoint("LEFT", pick, "LEFT", 6, 0)
            pick.label:SetText("Whose tools")
            local lastChip = pick.label
            for _, cls in ipairs(ToolClasses()) do
                local name = (ns.ClassName and ns.ClassName(cls, true)) or cls
                local chip = UI:CreateChip(pick, { kind = "plain", key = cls,
                    text = name .. (cls == MyClass() and Grey(" (you)") or ""),
                    onClick = function()
                        if cls == MyClass() then return end
                        Dm:SetClassPicked(cls, not Dm:IsClassPicked(cls))
                    end })
                chip:SetPoint("LEFT", lastChip, "RIGHT", lastChip == pick.label and 10 or 6, 0)
                chip.cls = cls
                p.classChips[#p.classChips + 1] = chip
                lastChip = chip
            end
            pick.tab = "screen"
            p.picker = pick
            p.pickHint = UI:Text(sec, "small", "DIM")
            p.pickHint.tab = "screen"
        end
        for _, d in ipairs(Dm:Parts("screen", key)) do
            local r = NewRow(sec, d)
            r.tab, r.group = "screen", key
            p.rows[#p.rows + 1] = r
        end
    end

    -- Pages: the demo guild's card and the pages it fills
    local gc = UI:CreateCard(sec, { tone = "card", pad = 0 })
    gc:SetHeight(GUILD_H)
    gc.art = gc:CreateTexture(nil, "BACKGROUND", nil, 1)
    gc.art:SetPoint("TOPLEFT", 1, -1)
    gc.art:SetPoint("BOTTOMRIGHT", -1, 1)
    UI:SetArtTexture(gc.art, "Karazhan", 544, GUILD_H - 2)
    gc.shade = gc:CreateTexture(nil, "BACKGROUND", nil, 2)
    gc.shade:SetPoint("TOPLEFT", 1, -1)
    gc.shade:SetPoint("BOTTOMRIGHT", -1, 1)
    gc.shade:SetColorTexture(0.04, 0.04, 0.05, 0.78)
    gc.kick = UI:Text(gc, "caps", "GOLD")
    gc.kick:SetPoint("TOPLEFT", gc, "TOPLEFT", PAD, -10)
    gc.kick:SetText("The demo guild")
    gc.title = UI:Text(gc, "title", "TEXT")
    gc.title:SetPoint("TOPLEFT", gc.kick, "BOTTOMLEFT", 0, -3)
    gc.title:SetText(format("%d made-up members", #Dm.GetFakeNames(Dm)))
    gc.line = UI:Text(gc, "small", "SUB")
    gc.line:SetPoint("TOPLEFT", gc.title, "BOTTOMLEFT", 0, -3)
    gc.line:SetText("Ten of them in a demo raid with you · ten past raids · BiS lists, professions, notes")
    gc.switch = ns.UI:CreateSwitch(gc, function() return Dm:IsEnabled() end, function(on) Dm:SetEnabled(on) end)
    gc.switch:SetPoint("TOPRIGHT", gc, "TOPRIGHT", -PAD, -12)
    gc.switch.label = gc.title
    gc.state = UI:Text(gc, "small", "TEXT")
    gc.state:SetPoint("RIGHT", gc.switch, "LEFT", -8, 0)
    SettingsUI.refreshers[#SettingsUI.refreshers + 1] = gc.switch
    AddTooltip(gc.switch, "The demo guild", "Made-up members, lists and raids on every page while you look. Never saved "
        .. "or sent. /dz demo guild")
    gc.tab = "pages"
    p.guild = gc
    p.pagesHead = NewHead(sec, "Pages it fills")
    p.pagesHead.tab = "pages"
    for _, pg in ipairs(PAGES) do
        local t = NewPageTile(sec, pg)
        t.tab = "pages"
        p.tiles[#p.tiles + 1] = t
    end

    -- Moments: a head per group, a row per moment
    for _, g in ipairs(Dm.GROUPS.moment) do
        local list = Dm:Parts("moment", g[1])
        if #list > 0 then
            local h = NewHead(sec, g[2])
            h.tab, h.group = "moments", g[1]
            h.count:SetText(g[1] == "loot" and "the demo raid rolls and votes" or g[1] == "rules"
                and "each shows one of the guild's loot rules" or "")
            p.heads[#p.heads + 1] = h
            for _, d in ipairs(list) do
                local r = NewRow(sec, d)
                r.tab = "moments"
                p.rows[#p.rows + 1] = r
            end
        end
    end

    self:LayoutDemo()
end

---------------------------------------------------------------------------
-- Painting and laying out
---------------------------------------------------------------------------

function SettingsUI:SetDemoTab(tab)
    view.tab = tab
    self:LayoutDemo()
end

function SettingsUI:GetDemoTab() return view.tab end

-- All on, or (when they all are) all off, in one group.
function SettingsUI:DemoGroupAll(group)
    local Dm = D()
    local list, all = {}, true
    for _, d in ipairs(Dm:Parts("screen", group)) do
        if not d.class or Dm:IsClassPicked(d.class) then
            list[#list + 1] = d
            if not Dm:IsOn(d.key) then all = false end
        end
    end
    for _, d in ipairs(list) do
        if all then Dm:SetOn(d.key, false) elseif Dm:Ready(d.key) then Dm:SetOn(d.key, true) end
    end
end

local function Plural(n, one, many) return n == 1 and one or many end

function SettingsUI:PaintDemoStatus()
    local p = page
    if not p then return end
    local Dm, st = D(), p.status
    local onList = Dm:OnList()
    local mKey = Dm:GetMoment()
    local live = #onList > 0 or mKey ~= nil
    local guild = Dm:IsEnabled()
    local title, line
    if not live and not guild then
        title = "Nothing playing"
        line = "Pick what to try below. Made-up data only: nothing is saved, sent or cast."
    else
        local bits = {}
        if #onList > 0 then bits[#bits + 1] = format("%d on screen", #onList) end
        if mKey then
            local md = Dm:GetPart(mKey)
            bits[#bits + 1] = "playing " .. (md and md.label or mKey)
        end
        if guild then bits[#bits + 1] = "demo guild on" end
        title = table.concat(bits, " · ")
        title = title:sub(1, 1):upper() .. title:sub(2)
        if #onList > 0 then
            local names = {}
            for i = 1, math.min(3, #onList) do names[#names + 1] = onList[i].label end
            line = S:Wrap("TEXT", table.concat(names, ", "))
                .. (#onList > 3 and Grey(format(" and %d more", #onList - 3)) or "")
            if Dm:AnyPull() then
                local left = Dm:PullLeft()
                if Dm:IsLooping() then line = line .. Grey(" · on a loop")
                elseif left and left > 0 then line = line .. Grey(format(" · one pull, %d s left", floor(left + 0.5)))
                else line = line .. Grey(" · the pull is over") end
            end
        elseif mKey then
            local t, dur = Dm:MomentTime()
            line = dur and format("Ends by itself in %d s", max(0, floor(dur - (t or 0) + 0.5)))
                or "Ends when you close it"
        else
            line = "The demo guild fills every page. Nothing plays on screen."
        end
    end
    st.title:SetText(title)
    st.line:SetText(line)
    local on = live or guild
    st.orb:SetVertexColor(S:Color(on and "GOLD" or "DIM"))
    if st.edges then
        local r, g, b = S:Color(on and "GOLD" or "EDGE")
        UI:SetEdgeColor(st, r, g, b, 0.55)
    end
    st.stop:SetShown(on)
    st.again:SetShown(Dm:AnyPull())
    local hasPicks = #Dm:SavedPicks() > 0
    st.mine:SetShown(not on and hasPicks)
    local right = 12
    for _, b in ipairs({ st.stop, st.again, st.mine }) do
        if b:IsShown() then right = right + (b:GetWidth() or 80) + 6 end
    end
    st.line:SetPoint("RIGHT", st, "RIGHT", -right, 0)
    st.live = live
    -- the moments' rows: Play / Stop and how far they are
    for _, r in ipairs(p.rows) do
        if r.play then
            local playing = mKey == r.d.key
            r.play:SetText(playing and "Stop" or (UI:AtlasIconText(47, 10, S.C.GOLD) .. " Play"))
            r.play:SetKind(playing and "primary" or "secondary")
            if playing then
                local t, dur = Dm:MomentTime()
                if dur and dur > 0 then
                    r.bar:SetWidth(max(1, floor((r:GetWidth() or 0) * math.min(1, (t or 0) / dur) + 0.5)))
                    r.bar:Show()
                else
                    r.bar:Hide()
                end
                r:SetSelected(true)
            else
                r.bar:Hide()
                r:SetSelected(false)
            end
        end
    end
end

-- A row's height: one line, or two when its line is wider than the room it has.
local function RowH(r)
    local w = ((SettingsUI.BodyWidth and SettingsUI:BodyWidth()) or 546) - (6 + TILE + 12) - (r.ctrlW + 12)
    return (UI:TextWidth(r.line) > w) and (ROW_H + LINE2) or ROW_H
end

local function PaintRow(r)
    local Dm, d = D(), r.d
    if r.switch then
        local on = Dm:IsOn(d.key)
        local ready, why = Dm:Ready(d.key)
        r.switch:SetChecked(on)
        r.switch:SetEnabled(on or ready)
        if not ready and why then
            r.line:SetText(S:Wrap("WARN", why))
        else
            r.line:SetText(d.desc or "")
        end
        r.name:SetTextColor(S:Color((ready or on) and "TEXT" or "SUB"))
        r.tile.tex:SetVertexColor(S:Color(r.tile.glyph and ((on and "GOLD") or "TEXT") or "TEXT"))
        if not r.tile.glyph then r.tile.tex:SetDesaturated(not (ready or on)) end
    else
        r.line:SetText(d.desc or "")
    end
end

function SettingsUI:LayoutDemo()
    local p = page
    if not p then return end
    local Dm, sec = D(), p.sec
    local tab = view.tab
    local y = 6
    local function put(f, h, gap, x, right)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", sec, "TOPLEFT", x or 0, -(y + (gap or 0)))
        f:SetPoint("TOPRIGHT", sec, "TOPRIGHT", -(right or 0), -(y + (gap or 0)))
        f:Show()
        y = y + (gap or 0) + h
    end
    put(p.status, STATUS_H)
    put(p.quick, CHIP_H, 10)
    local cur = Dm:CurrentPreset()
    for _, chip in ipairs(p.chips) do chip:SetSelected(chip.key == cur) end
    put(p.tabs, TAB_H, 12)
    local n = #Dm:OnList()
    for _, b in ipairs(p.tabs.list) do
        b:SetActive(b.key == tab)
        if b.key == "screen" then UI:SetTabCount(b, n, "muted") end
    end
    p.tabs.mode:SetShown(tab == "screen")
    p.tabs.modeLabel:SetShown(tab == "screen")
    if p.tabs.mode:GetSelected() ~= Dm:GetMode() then p.tabs.mode:Select(Dm:GetMode()) end
    y = y + 4

    -- hide everything of the other tabs
    for _, h in ipairs(p.heads) do h:SetShown(h.tab == tab) end
    for _, r in ipairs(p.rows) do r:SetShown(r.tab == tab) end
    p.picker:SetShown(tab == "screen")
    p.pickHint:SetShown(tab == "screen")
    p.guild:SetShown(tab == "pages")
    p.pagesHead:SetShown(tab == "pages")
    for _, t in ipairs(p.tiles) do t:SetShown(tab == "pages") end

    if tab == "screen" then
        for _, h in ipairs(p.heads) do
            if h.tab == "screen" then
                local group = h.group
                local shown, on = 0, 0
                put(h, HEAD_H, 4)
                if group == "class" then
                    put(p.picker, PICK_H, 2)
                    for _, chip in ipairs(p.classChips) do chip:SetSelected(Dm:IsClassPicked(chip.cls)) end
                end
                for _, r in ipairs(p.rows) do
                    if r.tab == "screen" and r.group == group then
                        if r.d.class and not Dm:IsClassPicked(r.d.class) then
                            r:Hide()
                        else
                            PaintRow(r)
                            local h = RowH(r)
                            r:SetHeight(h)
                            put(r, h, 0)
                            shown = shown + 1
                            if Dm:IsOn(r.d.key) then on = on + 1 end
                        end
                    end
                end
                if group == "class" then
                    if shown == 0 then
                        p.pickHint:SetText("Your class has no class tools. Pick a class above to try theirs.")
                        put(p.pickHint, 18, 2, 46)
                    else
                        p.pickHint:Hide()
                    end
                end
                h.count:SetText(on > 0 and format("%d on", on) or "")
                if h.all then
                    h.all:SetLabel((shown > 0 and on == shown) and "None" or "All")
                    h.all:SetShown(shown > 0)
                end
            end
        end
    elseif tab == "pages" then
        put(p.guild, GUILD_H, 4)
        local g = p.guild
        local gon = Dm:IsEnabled()
        g.switch:SetChecked(gon)
        g.state:SetText(gon and "On" or "Off")
        g.state:SetTextColor(S:Color(gon and "OK" or "SUB"))
        if g.edges then
            local r, gg, b = S:Color(gon and "GOLD" or "EDGE")
            UI:SetEdgeColor(g, r, gg, b, 0.55)
        end
        put(p.pagesHead, HEAD_H, 6)
        p.pagesHead.count:SetText(gon and "click one to open it" or "switch the guild on to fill them")
        local w = (SettingsUI.BodyWidth and SettingsUI:BodyWidth()) or 546
        local tw = floor((w - 2 * TILE_GAP) / 3)
        for i, t in ipairs(p.tiles) do
            local col, row = (i - 1) % 3, floor((i - 1) / 3)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", sec, "TOPLEFT", col * (tw + TILE_GAP), -(y + 6 + row * (TILE_H + TILE_GAP)))
            t:SetWidth(tw)
            t:SetAlpha(gon and 1 or 0.45)
            t:Show()
        end
        y = y + 6 + math.ceil(#p.tiles / 3) * (TILE_H + TILE_GAP)
    else
        for _, h in ipairs(p.heads) do
            if h.tab == "moments" then
                put(h, HEAD_H, 4)
                for _, r in ipairs(p.rows) do
                    if r.tab == "moments" and r.d.group == h.group then
                        PaintRow(r)
                        local h = RowH(r)
                        r:SetHeight(h)
                        put(r, h, 0)
                    end
                end
            end
        end
    end
    self:PaintDemoStatus()
    sec.height = y + 8
    if self.cards and self.cards.demo and self.cards.demo:IsShown() then self:LayoutCards() end
end

-- (a part, a class, the mode, the guild or a moment changed: the page follows while it is built)
local function Changed()
    if page then SettingsUI:LayoutDemo() end
end
ns:On("DEMO_PARTS_CHANGED", Changed)
ns:On("DEMO_TOGGLED", Changed)
ns:On("DEMO_MOMENT", Changed)
ns:On("DEMO_PULL", Changed)
ns:On("SETTINGS_CHANGED", function(path)
    -- (a feature switched on or off: its part's "switch it on first" line)
    if page and type(path) == "string" and (path:find("^meters") or path:find("^ui%.") or path:find("^guildmap")) then
        Changed()
    end
end)
