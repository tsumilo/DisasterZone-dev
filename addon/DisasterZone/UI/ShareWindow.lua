if DisasterZoneBoot and DisasterZoneBoot.Run("UI/ShareWindow.lua", ...) then return end -- DisasterZone: UI/ShareWindow.lua
-- ns.ShareWindow: the small window a Share icon opens (UI/Share.lua makes the links). From the top: the link as guild
-- members will see it in chat (its tooltip: how it reads without DisasterZone), an optional message to go before it,
-- the chats to post it in (one click sends; the gold one is what Enter in the message sends to), the guild members
-- online to whisper it to (the search narrows them; a name that isn't in the guild whispers that player), and Put in
-- chat box to write more around it and pick the chat yourself. Escape closes it.
local addonName, ns = ...

local Win = ns:NewModule("ShareWindow")

local W, H = 340, 340
local ROW_H = 20
local LIST_ROWS = 5
local GAP = 3

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
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 1, 1, 0.08)
        row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.note:SetPoint("RIGHT", -8, 0)
        row.note:SetJustifyH("RIGHT")
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 8, 0)
        row.name:SetPoint("RIGHT", row.note, "LEFT", -8, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
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
            b:SetPoint("TOPLEFT", win.sendRow, "TOPLEFT", 0, -18)
        else
            b:SetPoint("LEFT", shown[i - 1], "RIGHT", GAP, 0)
        end
    end
end

local function PreviewTip(self)
    local ref = state.ref
    if not ref then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("How it looks in chat")
    GameTooltip:AddLine("Guild members with DisasterZone see this link; a click opens it. Without DisasterZone it reads:",
        1, 1, 1, true)
    GameTooltip:AddLine(Share():Text(ref, state.fallback) or "", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
end

local function Create()
    local w = UI():CreateWindow("DisasterZoneShareWindow", "Share", W, H, { noSavePosition = true })
    w:SetFrameStrata("DIALOG")
    win = w
    local c = w.content

    -- the link as it will look in chat
    local pv = CreateFrame("Frame", nil, c)
    pv:SetPoint("TOPLEFT", 0, -4)
    pv:SetPoint("TOPRIGHT", 0, -4)
    pv:SetHeight(28)
    pv.bg = pv:CreateTexture(nil, "BACKGROUND")
    pv.bg:SetAllPoints()
    pv.bg:SetColorTexture(0.05, 0.05, 0.06, 0.9)
    UI():AddEdges(pv)
    UI():SetEdgeColor(pv, 0.3, 0.3, 0.34, 0.8)
    pv.text = pv:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    pv.text:SetPoint("TOPLEFT", 8, -7)
    pv.text:SetPoint("TOPRIGHT", -8, -7)
    pv.text:SetJustifyH("LEFT")
    pv.text:SetWordWrap(true)
    pv:EnableMouse(true)
    pv:SetScript("OnEnter", PreviewTip)
    pv:SetScript("OnLeave", function() GameTooltip:Hide() end)
    w.preview = pv

    -- an optional message before the link
    w.msg = UI():CreateSleekEditBox(c, 100, 24, "GameFontHighlightSmall")
    w.msg:SetPoint("TOPLEFT", pv, "BOTTOMLEFT", 0, -8)
    w.msg:SetPoint("TOPRIGHT", pv, "BOTTOMRIGHT", 0, -8)
    w.msg:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        Win:Send(DefaultChannel())
    end)
    UI():SetEditPlaceholder(w.msg, "Add a message (optional)")

    -- the chats: one click posts
    local sendRow = CreateFrame("Frame", nil, c)
    sendRow:SetPoint("TOPLEFT", w.msg, "BOTTOMLEFT", 0, -10)
    sendRow:SetPoint("TOPRIGHT", w.msg, "BOTTOMRIGHT", 0, -10)
    sendRow:SetHeight(42)
    w.sendRow = sendRow
    w.sendLabel = sendRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    w.sendLabel:SetPoint("TOPLEFT", 0, 0)
    w.sendLabel:SetText("Post in")
    w.channels = {}
    for _, ch in ipairs(CHANNELS) do
        local key = ch.key
        local b = UI():CreateSleekButton(sendRow, ch.label, 60, 24, function() Win:Send(key) end)
        b:SetMotionScriptsWhileDisabled(true)
        b:HookScript("OnEnter", function(self)
            if not self.why then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(ch.label)
            GameTooltip:AddLine(self.why, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:HookScript("OnLeave", function() GameTooltip:Hide() end)
        w.channels[key] = b
    end

    -- whisper a guild member
    local whisperRow = CreateFrame("Frame", nil, c)
    whisperRow:SetPoint("TOPLEFT", sendRow, "BOTTOMLEFT", 0, -10)
    whisperRow:SetPoint("TOPRIGHT", sendRow, "BOTTOMRIGHT", 0, -10)
    whisperRow:SetHeight(40)
    w.whisperLabel = whisperRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    w.whisperLabel:SetPoint("TOPLEFT", 0, 0)
    w.whisperLabel:SetText("Whisper")
    w.search = UI():CreateSearchBox(whisperRow, 100, nil, "Find a guild member online")
    w.search:SetPoint("TOPLEFT", 0, -18)
    w.search:SetPoint("TOPRIGHT", 0, -18)
    w.search:HookScript("OnTextChanged", RefreshList)
    w.search:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local first = WhisperRows()[1]
        if first then Win:Whisper(first.key) end
    end)
    w.list = UI():CreateScrollList(c, ROW_H, InitRow)
    w.list.frame:SetPoint("TOPLEFT", whisperRow, "BOTTOMLEFT", 0, -4)
    w.list.frame:SetPoint("TOPRIGHT", whisperRow, "BOTTOMRIGHT", 0, -4)
    w.list.frame:SetHeight(ROW_H * LIST_ROWS)
    w.list:SetEmptyText("No guild members online.")

    -- or into the chat box, to write around it
    w.chatBtn = UI():CreateSleekButton(c, "Put in chat box", 124, 22, function() Win:PutInChat() end)
    w.chatBtn:SetPoint("BOTTOMLEFT", 0, 2)
    w.chatBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Put in chat box")
        GameTooltip:AddLine("Adds the link to your chat box: write more around it and post it in any chat.", 1, 1, 1,
            true)
        GameTooltip:Show()
    end)
    w.chatBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

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
