if DisasterZoneBoot and DisasterZoneBoot.Run("UI/BossModSettings.lua", ...) then return end -- DisasterZone UI/BossModSettings.lua
-- Settings > Combat > Boss mods (the card UI/Settings.lua lists as "bossmods"): the main switch (off until turned on;
-- the rows under it grey while it is off), bars, warnings, sounds, the range frame, my role, other roles' alerts,
-- DBM / BigWigs timers, the look (Interface > Looks > Boss mods), Try it, where it sits (Edit layout); then every
-- raid as a row that opens its bosses' alerts, each with its own switch and a tag for what it is (Bar, Warn, You,
-- Range; Tank / Healer).
local addonName, ns = ...

local SettingsUI = ns.SettingsUI
local UI, S = ns.UI, ns.Style

local floor, max = math.floor, math.max
local ipairs, pairs, type = ipairs, pairs, type

local RAIDS = { "Karazhan", "GruulsLair", "MagtheridonsLair", "SerpentshrineCavern", "TempestKeep", "HyjalSummit",
                "BlackTemple", "ZulAman", "SunwellPlateau" }
local KIND = { bar = { "Bar", { 0.56, 0.76, 1 } }, warn = { "Warn", { 1, 0.72, 0.36 } },
               you = { "You", { 1, 0.49, 0.44 } }, range = { "Range", { 0.5, 0.83, 0.56 } } }
local RAID_H, ALERT_H, BOSS_H, RAID_GAP = 40, 24, 22, 0
local open = {}                   -- [raid key] = true: its bosses' alerts show (this session)

local function BM() return ns.BossMod end
local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting(path)
    if v == nil then return default end
    return v
end

-- The bosses of a raid that have boss mods, in the raid's order (Data/Items.lua).
local function Bosses(raidKey)
    local out = {}
    local raid
    for _, r in ipairs(ns.Data and ns.Data.Raids or {}) do if r.key == raidKey then raid = r break end end
    local seen = {}
    for _, b in ipairs(raid and raid.bosses or {}) do
        local d = BM():Mod(raidKey .. ":" .. b.key)
        if d and not seen[d] then seen[d] = true; out[#out + 1] = d end
    end
    for _, d in ipairs(BM():Mods()) do      -- (and the ones Items doesn't list: Hyjal's waves)
        if d.key:match("^" .. raidKey .. ":") and not seen[d] then seen[d] = true; table.insert(out, 1, d) end
    end
    return out
end

local function RaidName(raidKey)
    for _, r in ipairs(ns.Data and ns.Data.Raids or {}) do if r.key == raidKey then return r.name end end
    return raidKey
end

local function BossName(d)
    if d.name then return d.name end
    local k = d.key:match(":(%w+)$") or d.key
    if k == "Waves" then return "Trash waves" end
    return k
end

local function AlertText(d, a)
    local t = a.text or (a.spell and GetSpellInfo and GetSpellInfo(a.spell)) or a.key
    if a.kind == "range" then t = "Range frame" .. (a.yd and (" · " .. a.yd .. " yd") or "") .. (a.text and (": " .. a.text) or "") end
    t = t:gsub("%s*%(%%n%)", ""):gsub("%%n", "#"):gsub("%%t", "someone"):gsub("%%s", (a.spell and GetSpellInfo and GetSpellInfo(a.spell)) or "")
    return t
end

local function Tag(parent, kind)
    local k = KIND[kind] or KIND.bar
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(42, 15)
    local c = k[2]
    local edges = {}
    for i = 1, 4 do edges[i] = f:CreateTexture(nil, "BORDER"); edges[i]:SetColorTexture(c[1], c[2], c[3], 0.45) end
    edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(1)
    edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(1)
    edges[3]:SetPoint("TOPLEFT"); edges[3]:SetPoint("BOTTOMLEFT"); edges[3]:SetWidth(1)
    edges[4]:SetPoint("TOPRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(1)
    f.text = UI:Text(f, "small", nil, { justify = "CENTER" })
    f.text:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.text:SetText(k[1]:upper())
    f.text:SetTextColor(c[1], c[2], c[3])
    return f
end

-- One alert: its tag, its words, Tank / Healer, its switch.
local function AlertRow(body, d, a, y)
    local row = CreateFrame("Button", nil, body)
    row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    row:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -y)
    row:SetHeight(ALERT_H)
    UI:DecorateRow(row)
    local tag = Tag(row, a.kind)
    tag:SetPoint("LEFT", row, "LEFT", 0, 0)
    local sw = ns.UI:CreateSwitch(row, function() return BM():AlertOn(d.key, a.key) end,
        function(v, b) local on = v; if type(b) == "boolean" then on = b end; BM():SetAlertOn(d.key, a.key, on and true or false) end)
    sw:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    sw:SetScale(0.85)
    sw:Refresh()
    row.switch = sw
    local role
    if a.role then
        role = UI:Text(row, "small", "SUB")
        role:SetText(a.role == "T" and "Tank" or "Healer")
        role:SetPoint("RIGHT", sw, "LEFT", -12, 0)
    end
    local text = UI:Text(row, "body", "TEXT")
    text:SetPoint("LEFT", tag, "RIGHT", 8, 0)
    text:SetPoint("RIGHT", role or sw, "LEFT", -10, 0)
    text:SetText(AlertText(d, a))
    row:SetScript("OnClick", function() sw:Click() end)
    return row
end

function SettingsUI:BuildBossMods(sec)
    sec.y = sec.y - 4
    local dims = {}
    local function Dim(_, row) dims[#dims + 1] = row; return row end
    self:SwitchSetting(sec, "Boss mods", "Timers, warnings and the range frame for every TBC raid boss. Off until you switch it on.",
        "bossmods.on", false, "Running DBM or BigWigs too? Turn one of them off, or every warning comes twice.")
    Dim(self:SwitchSetting(sec, "Timer bars", "Casts and phases counting down.", "bossmods.bars", true))
    Dim(self:SwitchSetting(sec, "Warnings", "Text in the middle of the screen when something happens.", "bossmods.warns", true))
    Dim(self:SwitchSetting(sec, "Sounds", "The raid warning sound, and an alarm when it's on you.", "bossmods.sounds", true))
    local sizes = {}
    for _, v in ipairs({ 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.2 }) do sizes[#sizes + 1] = { value = v, text = floor(v * 100 + 0.5) .. "%" } end
    Dim(self:DropdownSetting(sec, "Size", "The timer bars, the pull countdown and the range frame.", "bossmods.size",
        ns.BossModUI and ns.BossModUI.SIZE or 0.7, sizes, "Edit layout sizes each one on its own on top of this."))
    Dim(self:DropdownSetting(sec, "Warning size", "The warnings in the middle, and the last seconds under them.",
        "bossmods.warnSize", ns.BossModUI and ns.BossModUI.WARN_SIZE or 0.8, sizes))
    Dim(self:DropdownSetting(sec, "Range frame", "Who is too close, on the fights where you spread out.", "bossmods.range",
        "auto", { { value = "auto", text = "When the fight needs it" }, { value = "never", text = "Never" } },
        "It opens by itself for the part of a fight that needs it and closes after. The game hides where raiders "
            .. "stand inside raids; when it can't measure, the frame stays away."))
    Dim(self:DropdownSetting(sec, "My role", "Tank and healer alerts only go to that role.", "bossmods.role", "auto",
        { { value = "auto", text = "From my talents" }, { value = "tank", text = "Tank" }, { value = "healer", text = "Healer" },
          { value = "dps", text = "Damage" } }, "From my talents: the raid's main tank flag first, then the tree "
            .. "with the most points (Feral druids by form)."))
    Dim(self:SwitchSetting(sec, "Alerts for other roles", "Also show the tank and healer alerts when they're not yours.",
        "bossmods.roles", false))
    if ns.BossLearnUI then ns.BossLearnUI:AddSettingsRows(self, sec, Dim) end     -- (learning: UI/BossLearnUI.lua)
    Dim(self:SwitchSetting(sec, "DBM and BigWigs timers", "See their break timers, and they see yours.", "bossmods.dbm", true,
        "Pull timers are the game's own countdown: everyone sees them whatever they run. Breaks travel in DBM's and "
            .. "BigWigs' own messages."))
    local pr = self:Row(sec, "Pull and break", "Leader and assists: /dz pull 10 and /dz break 5. They work with boss mods off.")
    Dim(nil, pr)
    local lr = self:Row(sec, "Look", "Boss mods wear your UI look. Give them one of their own in Interface > Looks.")
    local lb = ns.UI:CreateSleekButton(lr, "Looks", 90, 22, function() SettingsUI:SelectSection("look.bossmods") end)
    lb:SetPoint("RIGHT", lr, "RIGHT", 0, 0)
    lr.control = lb
    SettingsUI.PlaceText(lr, 90)
    Dim(nil, lr)
    local tr = self:Row(sec, "Try it", "A made-up Gruul pull plays on your screen. Nothing is read or sent.")
    local tb = ns.UI:CreateSleekButton(tr, "Try it", 80, 22, function() if ns.BossModUI then ns.BossModUI:TryIt() end end, "primary")
    tb:SetPoint("RIGHT", tr, "RIGHT", 0, 0)
    tr.control = tb
    SettingsUI.PlaceText(tr, 80)
    Dim(nil, select(2, self:EditLayoutRow(sec, "Position", "The bars, the warnings, the countdown and the range frame move in Edit layout.")))
    -- the raids
    sec.y = sec.y - 10
    local head = UI:Text(sec, "emph", "GOLD")
    head:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y)
    head:SetText("Bosses")
    local hint = UI:Text(sec, "small", "SUB", { justify = "RIGHT" })
    hint:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y - 2)
    hint:SetText("Switch off any alert you don't want")
    sec.y = sec.y - 22
    sec.top = -sec.y
    sec.raids = {}
    for _, rk in ipairs(RAIDS) do
        local bosses = Bosses(rk)
        if #bosses > 0 then
            local card = CreateFrame("Frame", nil, sec)
            local rh = CreateFrame("Button", nil, card)
            rh:SetPoint("TOPLEFT"); rh:SetPoint("TOPRIGHT")
            rh:SetHeight(RAID_H)
            UI:DecorateRow(rh, { rule = true })
            local art = rh:CreateTexture(nil, "ARTWORK")
            art:SetSize(52, 26)
            art:SetPoint("LEFT", rh, "LEFT", 0, 0)
            local meta = ns.Data and ns.Data.RaidMeta and ns.Data.RaidMeta[rk]
            if meta and meta.art then
                local a = meta.art
                local cx, cy = a.cx or 0.5, a.cy or 0.5
                art:SetTexture(a[1])
                art:SetTexCoord(cx - 0.2, cx + 0.2, cy - 0.075, cy + 0.075)
            else
                art:SetColorTexture(0.1, 0.1, 0.12, 1)
            end
            local name = UI:Text(rh, "emph", "TEXT")
            name:SetPoint("LEFT", art, "RIGHT", 10, 0)
            name:SetText(RaidName(rk))
            local n = 0
            for _, d in ipairs(bosses) do n = n + #(d.alerts or {}) end
            local sub = UI:Text(rh, "small", "SUB", { justify = "RIGHT" })
            sub:SetPoint("RIGHT", rh, "RIGHT", -24, 0)
            sub:SetText(#bosses .. (#bosses == 1 and " fight" or " fights") .. "  ·  " .. n .. " alerts")
            local chev = rh:CreateTexture(nil, "ARTWORK")
            chev:SetSize(12, 12)
            chev:SetPoint("RIGHT", rh, "RIGHT", -4, 0)
            chev:SetTexture(UI.ICON_ATLAS)
            chev:SetVertexColor(S:Color("SUB"))
            rh.chev = chev
            rh:SetScript("OnClick", function()
                open[rk] = not open[rk] or nil
                SettingsUI:LayoutBossMods()
            end)
            card.head = rh
            -- (the alerts, made when the raid first opens)
            card.body = CreateFrame("Frame", nil, card)
            card.body:SetPoint("TOPLEFT", rh, "BOTTOMLEFT", 62, -4)
            card.body:SetPoint("TOPRIGHT", rh, "BOTTOMRIGHT", 0, -4)
            card.raid, card.bosses = rk, bosses
            sec.raids[#sec.raids + 1] = card
        end
    end
    sec.dims = dims
    self.refreshers[#self.refreshers + 1] = { Refresh = function()
        local on = Get("bossmods.on", false)
        for _, r in ipairs(dims) do if r then r:SetAlpha(on and 1 or 0.42) end end
        for _, card in ipairs(sec.raids) do card:SetAlpha(on and 1 or 0.42) end
    end }
    self:LayoutBossMods(true)
end

local function Fill(card)
    if card.filled then return end
    card.filled = true
    local y = 0
    for _, d in ipairs(card.bosses) do
        -- the boss: its name, and Try it (a short pull made from its own alerts, UI/BossModUI.lua TryBoss)
        local head = CreateFrame("Frame", nil, card.body)
        head:SetPoint("TOPLEFT", card.body, "TOPLEFT", 0, -y - 2)
        head:SetPoint("TOPRIGHT", card.body, "TOPRIGHT", 0, -y - 2)
        head:SetHeight(BOSS_H)
        local bn = UI:Text(head, "small", "GOLD")
        bn:SetPoint("LEFT", head, "LEFT", 0, 0)
        bn:SetText(BossName(d))
        local key = d.key
        local try = ns.UI:CreateSleekButton(head, "Try it", 64, 18, function()
            if ns.BossModUI then ns.BossModUI:TryBoss(key) end
        end)
        try:SetPoint("RIGHT", head, "RIGHT", 0, 0)
        head.try = try
        if ns.BossLearnUI then ns.BossLearnUI:DecorateBossHead(head, d) end     -- (its learning pill and page)
        card.tries = card.tries or {}
        card.tries[key] = try
        y = y + BOSS_H + 6
        for _, a in ipairs(d.alerts or {}) do
            AlertRow(card.body, d, a, y)
            y = y + ALERT_H
        end
        y = y + 4
    end
    card.bodyH = y
    card.body:SetHeight(max(1, y))
end

-- Stacks the raid rows (an open one shows its alerts) and sizes the section.
function SettingsUI:LayoutBossMods(building)
    local sec = self.sections and self.sections.bossmods
    if not sec or not sec.raids then return end
    local y = sec.top
    for _, card in ipairs(sec.raids) do
        local isOpen = open[card.raid] and true or false
        if isOpen then Fill(card) end
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, -y)
        card:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, -y)
        local h = RAID_H + (isOpen and ((card.bodyH or 0) + 8) or 0)
        card:SetHeight(h)
        card.body:SetShown(isOpen)
        UI:SetChevronUp(card.head.chev, isOpen)
        y = y + h + RAID_GAP
    end
    sec.height = y + 4
    if not building and self.cards and self.cards.bossmods and self.cards.bossmods:IsShown() then self:LayoutCards() end
end

-- Opens Combat > Boss mods with a raid's alerts showing (tests, links).
function SettingsUI:OpenBossMods(raidKey)
    if raidKey then open[raidKey] = true end
    self:SelectSection("bossmods")
    self:LayoutBossMods()
end
