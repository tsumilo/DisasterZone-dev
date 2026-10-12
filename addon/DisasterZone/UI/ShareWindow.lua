if DisasterZoneBoot and DisasterZoneBoot.Run("UI/ShareWindow.lua", ...) then return end -- DisasterZone: UI/ShareWindow.lua
-- ns.ShareWindow: the small window a Share icon opens (UI/Share.lua makes the links). From the top: the link as guild
-- members will see it in chat (its tooltip: how it reads without DisasterZone), an optional message to go before it,
-- the chats to post it in (one click sends; the gold one is what Enter in the message sends to), the guild members
-- online to whisper it to (the search narrows them; a name that isn't in the guild whispers that player), and Put in
-- chat box to write more around it and pick the chat yourself. Escape closes it.
-- A tool window (UI:CreateWindow + the "tool" layout): a strip banner naming what is shared, the tool row with Put in
-- chat box, then the body's sections under caps headers.
local addonName, ns = ...

local Win = ns:NewModule("ShareWindow")
local S = ns.Style

local W, H = 380, 446
local ROW_H = S.ROW.compact
local LIST_ROWS = 5
local GAP = 4

local CHANNELS = {
    { key = "GUILD", label = "Guild" },
    { key = "OFFICER", label = "Officer" },
    { key = "RAID", label = "Raid" },
    { key = "PARTY", label = "Party" },
    { key = "SAY", label = "Say" },
}

local win
local state = { ref = nil, fallback = nil }

local function UI() return ns.UI end
local function Share() return ns.Share end
local function Util() return ns.Util end

local function IsOfficer()
    if C_GuildInfo and C_GuildInfo.IsGuildOfficer then return C_GuildInfo.IsGuildOfficer() and true or false end
    local g = ns.Guild
    return (g and g.IsOfficer and g:IsOfficer(Util().PlayerKey(), true)) and true or false
end

-- Can I post in this chat now? ok, why not.
local function Available(key)
    if key == "GUILD" then return IsInGuild() and true or false, "You are not in a guild." end
    if key == "OFFICER" then return IsInGuild() and IsOfficer(), "For the guild's officers." end
    if key == "RAID" then return IsInRaid() and true or false, "You are not in a raid group." end
    if key == "PARTY" then return IsInGroup() and true or false, "You are not in a group." end
    return true
end

-- The chat Enter sends to (the gold button): the raid while in one, else the guild.
local function DefaultChannel()
    if IsInRaid() then return "RAID" end
    if IsInGuild() then return "GUILD" end
    return "SAY"
end

---------------------------------------------------------------------------
-- Whisper list
---------------------------------------------------------------------------

local function WhisperRows()
    local g = ns.Guild
    local typed = Util().Trim(win and win.search:GetText() or "") or ""
    local q = Util().FoldCase(typed)
    local rows = {}
    for _, key in ipairs(g and g.GetOnlineMembers and g:GetOnlineMembers() or {}) do
        if not Util().IsMe(key) then
            local name = Util().ShortName(key)
            if q == "" or Util().FoldCase(name):find(q, 1, true) then rows[#rows + 1] = { key = key, name = name } end
        end
    end
    table.sort(rows, function(a, b) return Util().FoldCase(a.name) < Util().FoldCase(b.name) end)
    -- a name that is no guild member online: whisper that player anyway (a pug)
    if #rows == 0 and typed ~= "" and not typed:find("[%s%d%p]") then
        local name = Util().CapitalizeName(typed)
        rows[1] = { key = name, name = name, outsider = true }
    end
    return rows
end

local function InitRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        UI():DecorateRow(row, { rule = true })
        row.note = UI():Text(row, "small", "SUB", { justify = "RIGHT" })
        row.note:SetPoint("RIGHT", -8, 0)
        row.name = UI():Text(row, "body", "TEXT")
        row.name:SetPoint("LEFT", 8, 0)
        row.name:SetPoint("RIGHT", row.note, "LEFT", -8, 0)
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function(self)
            local data = self.__cdlData
            if data then Win:Whisper(data.key) end
        end)
    end
    if d.outsider then
        row.name:SetText("Whisper " .. d.name)
        row.note:SetText("not in the guild")
    else
        row.name:SetText(UI():ColoredName(d.key))
        local g = ns.Guild
        row.note:SetText(g and g.GetRankName and g:GetRankName(d.key) or "")
    end
end

local function RefreshList()
    if not win then return end
    win.list:SetData(WhisperRows(), true)
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local function ContentWidth()
    local w = win.sendRow:GetWidth()
    if not w or w < 100 then w = W - 26 end
    return w
end

local function LayoutChannels()
    local shown = {}
    for _, ch in ipairs(CHANNELS) do
        local b = win.channels[ch.key]
        local ok, why = Available(ch.key)
        -- the officers' chat only for the officers; the others always, greyed out while they don't apply
        b:SetShown(ch.key ~= "OFFICER" or ok)
        b:SetEnabled(ok)
        b.why = (not ok) and why or nil
        b:SetKind(ch.key == DefaultChannel() and "primary" or "secondary")
        if b:IsShown() then shown[#shown + 1] = b end
    end
    local each = math.floor((ContentWidth() - GAP * (#shown - 1)) / #shown)
    for i, b in ipairs(shown) do
        b:ClearAllPoints()
        b:SetWidth(each)
        if i == 1 then
            b:SetPoint("TOPLEFT", win.sendRow, "TOPLEFT", 0, -(18 + GAP))
        else
            b:SetPoint("LEFT", shown[i - 1], "RIGHT", GAP, 0)
        end
    end
end

-- The preview's tooltip lines: how the link reads without DisasterZone.
local function PreviewTip()
    local ref = state.ref
    if not ref then return {} end
    return { "Guild members with DisasterZone see this link; a click opens it. Without DisasterZone it reads:",
        { Share():Text(ref, state.fallback) or "", "SUB", wrap = true } }
end

local function Create()
    local w = UI():CreateWindow("DisasterZoneShareWindow", "Share", W, H, { noSavePosition = true })
    w:SetFrameStrata("DIALOG")
    w.content:SetFrameStrata("DIALOG")       -- (what is made in it climbs from there, in the game and the renders)
    win = w
    local L = UI():CreateLayout("tool", w.content, { width = W - 10, toolbar = true,
        banner = { size = "strip", icon = 18, title = "Share", sub = "A link in chat that opens it in DisasterZone" } })
    w.layout, w.banner = L, L.banner
    local c = L.body

    -- the tool row: Put in chat box (write around the link, pick the chat yourself)
    w.chatBtn = L.toolbar:SetPrimary({ text = "Put in chat box", kind = "secondary", onClick = function() Win:PutInChat() end,
        tip = "Adds the link to your chat box: write more around it and post it in any chat." })
    L.toolbar:SetText("Or post it in one click below")

    -- the link as it will look in chat (an inset card; its tooltip: how it reads without DisasterZone)
    w.previewHead = UI():CreateSectionHeader(c, "In chat", { style = "caps" })
    w.previewHead:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
    w.previewHead:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, 0)
    local pv = UI():CreateCard(c, { tone = "inset", height = 28 })
    pv:SetPoint("TOPLEFT", w.previewHead, "BOTTOMLEFT", 0, -GAP)
    pv:SetPoint("TOPRIGHT", w.previewHead, "BOTTOMRIGHT", 0, -GAP)
    pv.text = UI():Text(pv, "body", "TEXT", { wrap = true })
    pv.text:SetPoint("TOPLEFT", 8, -7)
    pv.text:SetPoint("TOPRIGHT", -8, -7)
    UI():AttachTooltip(pv, "How it looks in chat", PreviewTip, { anchor = "ANCHOR_TOP" })
    w.preview = pv

    -- an optional message before the link
    w.msg = UI():CreateSleekEditBox(c, 100, S.BTN_H, "GameFontHighlightSmall")
    w.msg:SetPoint("TOPLEFT", pv, "BOTTOMLEFT", 0, -S.GAP)
    w.msg:SetPoint("TOPRIGHT", pv, "BOTTOMRIGHT", 0, -S.GAP)
    w.msg:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        Win:Send(DefaultChannel())
    end)
    UI():SetEditPlaceholder(w.msg, "Add a message (optional)")

    -- the chats: one click posts
    local sendRow = CreateFrame("Frame", nil, c)
    sendRow:SetPoint("TOPLEFT", w.msg, "BOTTOMLEFT", 0, -S.PAD)
    sendRow:SetPoint("TOPRIGHT", w.msg, "BOTTOMRIGHT", 0, -S.PAD)
    sendRow:SetHeight(18 + GAP + S.BTN_H)
    w.sendRow = sendRow
    w.sendHead = UI():CreateSectionHeader(sendRow, "Post in", { style = "caps" })
    w.sendHead:SetPoint("TOPLEFT", 0, 0)
    w.sendHead:SetPoint("TOPRIGHT", 0, 0)
    w.sendLabel = w.sendHead.title
    w.channels = {}
    for _, ch in ipairs(CHANNELS) do
        local key = ch.key
        local b = UI():CreateSleekButton(sendRow, ch.label, 60, S.BTN_H, function() Win:Send(key) end)
        b:SetMotionScriptsWhileDisabled(true)
        UI():AttachTooltip(b, function(self, tt)
            if not self.why then return false end
            tt:AddLine(ch.label, S:RGB("GOLD"))
            tt:AddLine(self.why, 1, 1, 1, true)
        end, nil, { anchor = "ANCHOR_TOP" })
        w.channels[key] = b
    end

    -- whisper a guild member
    local whisperRow = CreateFrame("Frame", nil, c)
    whisperRow:SetPoint("TOPLEFT", sendRow, "BOTTOMLEFT", 0, -S.PAD)
    whisperRow:SetPoint("TOPRIGHT", sendRow, "BOTTOMRIGHT", 0, -S.PAD)
    whisperRow:SetHeight(18 + GAP + S.BTN_H)
    w.whisperHead = UI():CreateSectionHeader(whisperRow, "Whisper", { style = "caps" })
    w.whisperHead:SetPoint("TOPLEFT", 0, 0)
    w.whisperHead:SetPoint("TOPRIGHT", 0, 0)
    w.whisperLabel = w.whisperHead.title
    w.search = UI():CreateSearchBox(whisperRow, 100, nil, "Find a guild member online")
    w.search:SetPoint("TOPLEFT", 0, -(18 + GAP))
    w.search:SetPoint("TOPRIGHT", 0, -(18 + GAP))
    w.search:HookScript("OnTextChanged", RefreshList)
    w.search:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local first = WhisperRows()[1]
        if first then Win:Whisper(first.key) end
    end)
    w.list = UI():CreateScrollList(c, ROW_H, InitRow)
    w.list.frame:SetPoint("TOPLEFT", whisperRow, "BOTTOMLEFT", 0, -GAP)
    w.list.frame:SetPoint("TOPRIGHT", whisperRow, "BOTTOMRIGHT", 0, -GAP)
    w.list.frame:SetHeight(ROW_H * LIST_ROWS)
    w.list:SetEmptyText("No guild members online.")

    w:SetScript("OnHide", function()
        w.msg:SetText("")
        w.msg:ClearFocus()
        w.search:SetText("")
        w.search:ClearFocus()
    end)
    w:RegisterEvent("GROUP_ROSTER_UPDATE")
    w:SetScript("OnEvent", function(self) if self:IsShown() then LayoutChannels() end end)
    w:Hide()
    return w
end

-- Places the window under the share icon that opened it (right edges lined up; it moves with that window until
-- dragged), else at the cursor.
local function Place(anchor)
    win:ClearAllPoints()
    if anchor and anchor.GetObjectType then
        win:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 8, -2)
        return
    end
    local ui = UIParent:GetEffectiveScale()
    local x, y = GetCursorPosition()
    if x and y and (x > 0 or y > 0) then
        win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / ui - 20, y / ui + 20)
        return
    end
    win:SetPoint("CENTER")
end

local function Render()
    local ref = state.ref
    local link = Share():ChatLink(ref, state.fallback) or ""
    local d = Share():Describe(ref)
    win.banner:SetTitle(d and d.label or "Share")
    win.preview.text:SetText(link)
    -- a long name takes a second line; everything under it moves down with it
    local extra = math.max(0, math.ceil((win.preview.text:GetStringHeight() or 14) - 16))
    win.preview:SetHeight(28 + extra)
    win:SetHeight(H + extra)
    win.msg:SetMaxBytes(Share():MaxMessageBytes(ref) + 1)
    LayoutChannels()
    RefreshList()
end

-- Opens the window for a reference. anchor: the icon clicked (the window drops down from it); fallback: the link's
-- own label, for a link passed on from chat that this client can't name itself.
function Win:Open(ref, anchor, fallback)
    if not ref or not Share():Text(ref, fallback) then return false end
    if not win then Create() end
    state.ref, state.fallback = ref, fallback
    Place(anchor)
    win:Show()
    win:Raise()
    Render()
    return true
end

function Win:Close()
    if win then win:Hide() end
end

function Win:GetWindow() return win end
function Win:GetRef() return win and win:IsShown() and state.ref or nil end

local function Message()
    return win.msg:GetText() or ""
end

-- Posts the link (and the message) in a chat, then closes.
function Win:Send(channel)
    if not win or not state.ref then return false end
    local ok, why = Available(channel)
    if not ok then
        if why then ns:Print("%s", why) end
        return false
    end
    local sent = Share():Send(state.ref, channel, nil, Message())
    if sent then win:Hide() end
    return sent
end

function Win:Whisper(target)
    if not win or not state.ref or type(target) ~= "string" or target == "" then return false end
    local sent = Share():Send(state.ref, "WHISPER", target, Message())
    if sent then win:Hide() end
    return sent
end

function Win:PutInChat()
    if not win or not state.ref then return false end
    local ref, fallback, msg = state.ref, state.fallback, Util().Trim(Message()) or ""
    win:Hide()
    local token = Share():Text(ref, fallback)
    if msg ~= "" then token = msg:gsub("|", "") .. " " .. token end
    local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
    if insert and insert(token) then return true end
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if open then open(token) end
    return true
end
