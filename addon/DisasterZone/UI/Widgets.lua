if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Widgets.lua", ...) then return end -- DisasterZone UI/Widgets.lua
-- ns.UI: shared widget factory (windows, item buttons, scroll lists, dropdowns, menus, tabs) and
-- small colour / tooltip / chat helpers. The flat look (see "The flat style" below); every frame is created on demand.
local addonName, ns = ...

local UI = ns:NewModule("UI")

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local UIParent = UIParent
local floor = math.floor
local format = string.format
local tinsert = table.insert

-- Fallbacks in case Constants did not load (keeps the UI alive instead of erroring).
local DEFAULT_TEX = {
    check      = "Interface\\RaidFrame\\ReadyCheck-Ready",
    cross      = "Interface\\RaidFrame\\ReadyCheck-NotReady",
    waiting    = "Interface\\RaidFrame\\ReadyCheck-Waiting",
    slotBg     = "Interface\\Buttons\\UI-Quickslot2",
    border     = "Interface\\Common\\WhiteIconFrame",
    hilight    = "Interface\\Buttons\\ButtonHilight-Square",
    rowHilight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
    star       = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1",
    classIcons = "Interface\\TargetingFrame\\UI-Classes-Circles",
}
local QUESTION_MARK_ICON = 134400

local function Tex(key)
    return (ns.TEX and ns.TEX[key]) or DEFAULT_TEX[key]
end
UI.Tex = function(_, key) return Tex(key) end

-- Human labels for BiS:GetObtainedState() results (shared by the doll, picker and others).
UI.OBTAINED_LABELS = {
    equipped = "Equipped",
    bags     = "In bags",
    bank     = "In bank",
    token    = "Have token",
    manual   = "Marked obtained",
}

function UI:OnInit() end
function UI:OnLogin() end

---------------------------------------------------------------------------
-- Small private helpers
---------------------------------------------------------------------------

local localTimers = {}
local function Debounce(key, sec, fn)
    if ns.Util and ns.Util.Debounce then
        ns.Util.Debounce(key, sec, fn)
        return
    end
    if localTimers[key] then localTimers[key]:Cancel() end
    localTimers[key] = C_Timer.NewTimer(sec, function()
        localTimers[key] = nil
        fn()
    end)
end

local function ShortName(key)
    if not key then return "?" end
    if ns.Util and ns.Util.ShortName then
        return ns.Util.ShortName(key) or key
    end
    return (key:gsub("%-.*$", ""))
end

local function Hex(r, g, b)
    return format("ff%02x%02x%02x", floor((r or 1) * 255 + 0.5), floor((g or 1) * 255 + 0.5), floor((b or 1) * 255 + 0.5))
end

function UI:ColorHex(r, g, b)
    return Hex(r, g, b)
end

-- Wraps text in a colour escape from an {r,g,b} table (ns.COLORS entries).
function UI:Colorize(text, color)
    if not text then return "" end
    if type(color) ~= "table" then return text end
    return "|c" .. Hex(color[1], color[2], color[3]) .. text .. "|r"
end

function UI:Color(key)
    local c = ns.COLORS and ns.COLORS[key]
    if c then return c[1], c[2], c[3] end
    return 1, 1, 1
end

local function GetLink(itemID)
    if not itemID then return nil end
    local link
    if ns.ItemDB and ns.ItemDB.GetLink then link = ns.ItemDB:GetLink(itemID) end
    if not link and C_Item and C_Item.GetItemInfo then
        local _
        _, link = C_Item.GetItemInfo(itemID)
    end
    return link
end
UI.GetItemLink = function(_, itemID) return GetLink(itemID) end

-- Replace glyphs the default game font may not have with inline textures / ASCII.
local GLYPHS = {
    ["\226\156\147"] = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t",          -- check mark
    ["\226\156\148"] = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t",          -- heavy check mark
    ["\226\152\133"] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t", -- black star
    ["\226\128\166"] = "...",                                                    -- ellipsis
}
function UI:SafeText(text)
    if type(text) ~= "string" then return text end
    for glyph, rep in pairs(GLYPHS) do
        if text:find(glyph, 1, true) then
            text = text:gsub(glyph, rep)
        end
    end
    return text
end

---------------------------------------------------------------------------
-- Chat links (with a flag so the Picker's InsertLink hook can ignore our own links)
---------------------------------------------------------------------------

local ownLinkDepth = 0
local function WithOwnLink(fn, ...)
    ownLinkDepth = ownLinkDepth + 1
    local ok, result = pcall(fn, ...)
    ownLinkDepth = ownLinkDepth - 1
    if not ok then
        geterrorhandler()(result)
        return nil
    end
    return result
end

function UI:IsOwnLinkClick()
    return ownLinkDepth > 0
end

-- Insert an item link into the active chat edit box (opens chat if none is active).
function UI:InsertLink(itemID)
    local link = GetLink(itemID)
    if not link then return false end
    local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
    if insert and WithOwnLink(insert, link) then return true end
    return false
end

function UI:LinkInChat(itemID)
    if self:InsertLink(itemID) then return true end
    local link = GetLink(itemID)
    if not link then
        ns:Print("Item information is still loading, try again in a moment.")
        return false
    end
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if open then
        WithOwnLink(open, link)
        return true
    end
    return false
end

-- Standard modified-click handling for anything that shows an item.
-- Returns true when the click was consumed (shift = link, ctrl = dress up, ...).
function UI:HandleModifiedItemClick(itemID)
    if not itemID then return false end
    local shift = IsShiftKeyDown()
    if not shift and not IsModifiedClick() then return false end
    local link = GetLink(itemID)
    if link and IsModifiedClick() and HandleModifiedItemClick then
        if WithOwnLink(HandleModifiedItemClick, link) then return true end
    end
    if shift then
        if link then self:InsertLink(itemID) end
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Colours, names, icons
---------------------------------------------------------------------------

function UI:ClassColor(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function ClassHex(classFile)
    if classFile and ns.Util and ns.Util.ClassColorHex then
        local hex = ns.Util.ClassColorHex(classFile)
        if type(hex) == "string" and #hex == 8 then return hex end
    end
    return Hex(UI:ClassColor(classFile))
end

function UI:ColoredName(key, classFile)
    if not classFile and key and ns.Guild and ns.Guild.GetClass then
        classFile = ns.Guild:GetClass(key)
    end
    -- (a player from another realm: "Name*", the realm is long and the tooltips say it)
    local name = (ns.Util and ns.Util.DisplayName) and ns.Util.DisplayName(key) or ShortName(key)
    return "|c" .. ClassHex(classFile) .. name .. "|r"
end

-- Is that player a guest: someone outside my guild (pugs in a raid, guests on a planned raid)? False while the
-- guild roster is not known, and for my own character.
function UI:IsGuest(key)
    local G = ns.Guild
    if type(key) ~= "string" or not (G and G.IsReady and G:IsReady()) then return false end
    if ns.Util.IsMe(key) or G:IsInGuild(key) then return false end
    return true
end

-- " (guest)" after the name of a player outside my guild, else "".
function UI:GuestTag(key)
    return self:IsGuest(key) and " |cff66ccff(guest)|r" or ""
end

-- The LFG role icons: tank, healer, anything else = damage. Interface\LFGFrame\UI-LFG-ICON-ROLES is 256x256 with
-- 67x67 cells on this client (GetTexCoordsForRole's grid, used when the client has it).
UI.ROLE_TEX = "Interface\\LFGFrame\\UI-LFG-ICON-ROLES"
local ROLE_TOKEN = { tank = "TANK", healer = "HEALER", TANK = "TANK", HEALER = "HEALER" }
local ROLE_CELL = { TANK = { 0, 1 }, HEALER = { 1, 0 }, DAMAGER = { 1, 1 } }
function UI:RoleCoords(role)
    local token = ROLE_TOKEN[role] or "DAMAGER"
    if GetTexCoordsForRole then
        local l, r, t, b = GetTexCoordsForRole(token)
        if l then return l, r, t, b end
    end
    local c, k = ROLE_CELL[token], 67 / 256
    return c[1] * k, (c[1] + 1) * k, c[2] * k, (c[2] + 1) * k
end

-- The ranged role (the game has none): the damage icon's disc with a bow and arrow (dev/generators/gen_ranged_role.py).
-- Melee keeps the damage icon's sword; casters count as ranged.
UI.RANGED_TEX = "Interface\\AddOns\\DisasterZone\\Media\\Roles\\ranged"
local RANGED_ROLE = { ranged = true, caster = true }

-- Points a texture at a role's icon: tank, healer, ranged (casters too), anything else the damage icon.
function UI:SetRoleIcon(tex, role)
    if RANGED_ROLE[role] then
        tex:SetTexture(UI.RANGED_TEX)
        tex:SetTexCoord(0, 1, 0, 1)
    else
        tex:SetTexture(UI.ROLE_TEX)
        tex:SetTexCoord(self:RoleCoords(role))
    end
end

-- A role icon inside text.
function UI:RoleIconText(role, size)
    if RANGED_ROLE[role] then return ("|T%s:%d:%d|t"):format(UI.RANGED_TEX, size or 13, size or 13) end
    local l, r, t, b = self:RoleCoords(role)
    size = size or 13
    local function px(v) return math.floor(v * 256 + 0.5) end
    return ("|T%s:%d:%d:0:0:256:256:%d:%d:%d:%d|t"):format(UI.ROLE_TEX, size, size, px(l), px(r), px(t), px(b))
end

function UI:ClassIcon(texture, classFile)
    if not texture then return end
    local coords = classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
    if coords then
        texture:SetTexture(Tex("classIcons"))
        texture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        texture:Show()
    else
        texture:Hide()
    end
end

function UI:QualityColor(q)
    q = tonumber(q)
    if not q then return 1, 1, 1 end
    if C_Item and C_Item.GetItemQualityColor then
        local r, g, b = C_Item.GetItemQualityColor(q)
        if r then return r, g, b end
    end
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function ItemNameQuality(itemID)
    if not itemID then return nil end
    if ns.ItemDB and ns.ItemDB.GetInfo then
        local name, _, quality = ns.ItemDB:GetInfo(itemID)
        return name, quality
    end
    if C_Item and C_Item.GetItemInfo then
        local name, _, quality = C_Item.GetItemInfo(itemID)
        return name, quality
    end
    return nil
end

-- Quality-coloured item name, or a grey "Loading..." placeholder (item load is requested).
function UI:ItemText(itemID)
    local name, quality = ItemNameQuality(itemID)
    if not name then
        return "|cff808080Loading...|r", true
    end
    return "|c" .. Hex(self:QualityColor(quality)) .. name .. "|r", false
end

local emptySlotCache = {}
function UI:EmptySlotTexture(sid)
    if not sid then return Tex("slotBg") end
    local cached = emptySlotCache[sid]
    if cached then return cached end
    local slot = ns.SLOTS and ns.SLOTS[sid]
    local tex
    if slot and slot.slotName and GetInventorySlotInfo then
        local ok, _, texture = pcall(GetInventorySlotInfo, slot.slotName)
        if ok then tex = texture end
    end
    tex = tex or Tex("slotBg")
    emptySlotCache[sid] = tex
    return tex
end

---------------------------------------------------------------------------
-- Tooltips & glow
---------------------------------------------------------------------------

function UI:SetItemTooltip(owner, itemID, extraFn)
    if not owner then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if itemID then GameTooltip:SetItemByID(itemID) end
    if extraFn then extraFn(GameTooltip) end
    if GameTooltip:NumLines() > 0 then
        GameTooltip:Show()
    else
        GameTooltip:Hide()
    end
end

function UI:HideTooltip()
    GameTooltip:Hide()
end

-- Simple text tooltip helper: lines = { "title", "line", {text, r, g, b}, ... }
function UI:SetTextTooltip(owner, lines, anchor)
    if not owner or type(lines) ~= "table" then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    for i, line in ipairs(lines) do
        if type(line) == "table" then
            GameTooltip:AddLine(line[1], line[2] or 1, line[3] or 1, line[4] or 1, line.wrap)
        elseif i == 1 then
            GameTooltip:AddLine(line, 1, 0.82, 0)
        else
            GameTooltip:AddLine(line, 1, 1, 1, true)
        end
    end
    GameTooltip:Show()
end

function UI:Glow(frame, on)
    if not frame then return end
    local glow = LibStub and LibStub("LibCustomGlow-1.0", true)
    if not glow then return end
    if on then
        if not frame.__cdlGlow then
            glow.ButtonGlow_Start(frame)
            frame.__cdlGlow = true
        end
    elseif frame.__cdlGlow then
        glow.ButtonGlow_Stop(frame)
        frame.__cdlGlow = nil
    end
end

---------------------------------------------------------------------------
-- Drag & drop from bags
---------------------------------------------------------------------------

function UI:GetCursorItem()
    local kind, itemID = GetCursorInfo()
    if kind == "item" and tonumber(itemID) then
        return tonumber(itemID)
    end
    return nil
end

-- Makes `frame` accept items dropped from the cursor: fn(frame, itemID).
-- Sets frame.__cdlDropTime so an OnClick in the same frame can be ignored.
function UI:AttachItemDrop(frame, fn)
    if not frame or not fn then return end
    local function handler(self)
        local itemID = UI:GetCursorItem()
        if not itemID then return end
        ClearCursor()
        self.__cdlDropTime = GetTime()
        fn(self, itemID)
    end
    frame:HookScript("OnReceiveDrag", handler)
    frame:HookScript("OnMouseUp", handler)
end

---------------------------------------------------------------------------
-- Windows & panels
---------------------------------------------------------------------------

local function SavePosition(f)
    local name = f.cdlName
    if not name or f.noSavePosition or not (ns.db and ns.db.settings) then return end
    local point, _, relPoint, x, y = f:GetPoint(1)
    if not point then return end
    ns.db.settings.windows = ns.db.settings.windows or {}
    ns.db.settings.windows[name] = { point, relPoint or point, floor((x or 0) + 0.5), floor((y or 0) + 0.5) }
end

function UI:RestorePosition(f)
    f:ClearAllPoints()
    local name = f.cdlName
    local windows = ns.db and ns.db.settings and ns.db.settings.windows
    local pos = name and not f.noSavePosition and type(windows) == "table" and windows[name]
    if type(pos) == "table" and type(pos[1]) == "string" then
        local ok = pcall(f.SetPoint, f, pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
        if ok then return end
        f:ClearAllPoints()
    end
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

-- opts (optional, DisasterZone extension): { noSavePosition = true }
function UI:CreateWindow(name, title, width, height, opts)
    local f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
    f.cdlName = name
    f.noSavePosition = opts and opts.noSavePosition or nil
    f:SetSize(width or 400, height or 300)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    if name and UISpecialFrames then
        tinsert(UISpecialFrames, name)
    end

    local titleText = f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)
    if not titleText then
        titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        titleText:SetPoint("TOP", f, "TOP", 0, -5)
    end
    titleText:SetText(title or "")
    f.titleText = titleText
    f.SetWindowTitle = function(self, text) self.titleText:SetText(text or "") end

    local content = CreateFrame("Frame", nil, f)
    if f.Inset then
        content:SetPoint("TOPLEFT", f.Inset, "TOPLEFT", 3, -3)
        content:SetPoint("BOTTOMRIGHT", f.Inset, "BOTTOMRIGHT", -3, 3)
    else
        content:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -26)
        content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
    end
    f.content = content

    UI:RestorePosition(f)
    return f
end

local PANEL_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

---------------------------------------------------------------------------
-- The slim in-raid style (session bar, encounter reminder): a dark translucent tooltip frame, flat tinted buttons,
-- small status pills.
---------------------------------------------------------------------------

UI.HUD_BG = { 0.04, 0.04, 0.05, 0.82 }
UI.HUD_BORDER = { 0.4, 0.4, 0.4, 0.9 }

function UI:StyleHud(f)
    if not f.SetBackdrop then return end
    f:SetBackdrop(PANEL_BACKDROP)
    f:SetBackdropColor(unpack(UI.HUD_BG))
    f:SetBackdropBorderColor(unpack(UI.HUD_BORDER))
end

-- A flat button: tinted background, brighter on hover. tint = { r, g, b } (default grey).
function UI:CreateFlatButton(parent, text, width, height, onClick, tint)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width or 70, height or 18)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.12)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("CENTER")
    b:SetFontString(fs)
    b:SetText(text or "")
    function b:SetTint(t)
        t = t or { 0.6, 0.6, 0.6 }
        self.bg:SetColorTexture(t[1], t[2], t[3], 0.35)
    end
    b:SetTint(tint)
    b:RegisterForClicks("LeftButtonUp")
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

---------------------------------------------------------------------------
-- The flat style: one meaning per look, on every page.
--   where you are     gold text + gold underline (CreateUnderlineTab, the main window's navigation)
--   main action       "primary": gold fill, one per page
--   chosen option     "chosen": light grey fill, the picked one of a set (P1-P5, Main / Off spec, a toggle)
--   other actions     "secondary": dark grey
--   can't undo        "danger": red
---------------------------------------------------------------------------

local SLEEK = {
    primary   = { bg = { 0.42, 0.30, 0.04, 0.95 }, hover = { 0.55, 0.40, 0.06, 1 }, edge = { 1, 0.82, 0, 0.9 },
                  text = { 1, 0.95, 0.8 } },
    secondary = { bg = { 0.10, 0.10, 0.12, 0.92 }, hover = { 0.18, 0.18, 0.21, 0.95 }, edge = { 0.34, 0.34, 0.38, 0.9 },
                  text = { 0.88, 0.88, 0.88 } },
    danger    = { bg = { 0.30, 0.06, 0.06, 0.92 }, hover = { 0.45, 0.09, 0.09, 0.95 }, edge = { 0.75, 0.25, 0.25, 0.9 },
                  text = { 1, 0.85, 0.85 } },
    chosen    = { bg = { 0.27, 0.27, 0.30, 0.95 }, hover = { 0.32, 0.32, 0.36, 0.95 }, edge = { 0.72, 0.72, 0.76, 0.9 },
                  text = { 1, 1, 1 } },
}
SLEEK.active = SLEEK.chosen   -- the older name of "chosen"
UI.SLEEK = SLEEK

-- A 1px border of four textures around frame f: f.edges, recoloured by UI:SetEdgeColor(f, r, g, b, a).
function UI:AddEdges(f, layer)
    f.edges = {}
    local function edge(p1, p2, horiz)
        local t = f:CreateTexture(nil, layer or "BORDER")
        t:SetPoint(p1)
        t:SetPoint(p2)
        if horiz then t:SetHeight(1) else t:SetWidth(1) end
        f.edges[#f.edges + 1] = t
    end
    edge("TOPLEFT", "TOPRIGHT", true)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
    edge("TOPLEFT", "BOTTOMLEFT", false)
    edge("TOPRIGHT", "BOTTOMRIGHT", false)
end

function UI:SetEdgeColor(f, r, g, b, a)
    for _, t in ipairs(f.edges or {}) do t:SetColorTexture(r, g, b, a or 1) end
end

-- A flat button. kind = "primary" | "secondary" (default) | "danger" | "chosen" ("active" is the same as "chosen");
-- b:SetKind(kind) restyles it.
-- b:SetTint(r, g, b) paints it in that colour instead (a chosen answer); b:SetTint(nil) goes back to its kind.
function UI:CreateSleekButton(parent, text, width, height, onClick, kind)
    local b = CreateFrame("Button", nil, parent)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    UI:AddEdges(b)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("CENTER", 0, 0)
    b:SetFontString(fs)
    b:SetText(text or "")
    b:SetSize(width or ((fs:GetStringWidth() or 40) + 24), height or 22)
    local function paint(self)
        local enabled = self:IsEnabled()
        -- a disabled button is plain grey whatever its kind (a Save with nothing to save is not gold)
        local s = enabled and (SLEEK[self.kind] or SLEEK.secondary) or SLEEK.secondary
        local c = (enabled and self.hovered) and s.hover or s.bg
        local e, t = s.edge, s.text
        local tint = self.tint
        if tint then
            local k = (enabled and self.hovered) and 0.4 or 0.3
            c = { tint[1] * k, tint[2] * k, tint[3] * k, 0.95 }
            e = { tint[1], tint[2], tint[3], 0.9 }
            t = tint
        end
        self.bg:SetColorTexture(c[1], c[2], c[3], c[4])
        UI:SetEdgeColor(self, e[1], e[2], e[3], enabled and e[4] or e[4] * 0.4)
        if enabled then fs:SetTextColor(t[1], t[2], t[3]) else fs:SetTextColor(0.45, 0.45, 0.45) end
    end
    function b:SetKind(k)
        self.kind = k or "secondary"
        paint(self)
    end
    function b:SetTint(r, g, bl)
        self.tint = r and { r, g, bl } or nil
        paint(self)
    end
    b:SetScript("OnEnter", function(self) self.hovered = true; paint(self) end)
    b:SetScript("OnLeave", function(self) self.hovered = false; paint(self) end)
    -- a caller's own OnEnter / OnLeave (a tooltip) keeps the hover look
    local setScript = b.SetScript
    function b:SetScript(name, fn)
        if (name == "OnEnter" or name == "OnLeave") and type(fn) == "function" then
            local hover = name == "OnEnter"
            return setScript(self, name, function(f, ...)
                f.hovered = hover
                paint(f)
                return fn(f, ...)
            end)
        end
        return setScript(self, name, fn)
    end
    b:SetScript("OnEnable", paint)
    b:SetScript("OnDisable", paint)
    b:SetScript("OnMouseDown", function(self) if self:IsEnabled() then fs:SetPoint("CENTER", 1, -1) end end)
    b:SetScript("OnMouseUp", function() fs:SetPoint("CENTER", 0, 0) end)
    b:RegisterForClicks("LeftButtonUp")
    if onClick then b:SetScript("OnClick", function(self, mouseButton) onClick(self, mouseButton) end) end
    b:SetKind(kind)
    return b
end

-- A square icon button for toolbars: texture + texcoords (l, r, t, b). b:SetActive(on) marks the current tool (the
-- "chosen" look).
function UI:CreateIconButton(parent, size, texture, coords, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    UI:AddEdges(b)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 5, -5)
    b.icon:SetPoint("BOTTOMRIGHT", -5, 5)
    b.icon:SetTexture(texture)
    if coords then b.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4]) end
    local function paint(self)
        local enabled = self:IsEnabled()
        if self.active then
            local s = SLEEK.chosen
            local c = (enabled and self.hovered) and s.hover or s.bg
            self.bg:SetColorTexture(c[1], c[2], c[3], c[4])
            UI:SetEdgeColor(self, s.edge[1], s.edge[2], s.edge[3], s.edge[4])
            self.icon:SetVertexColor(1, 1, 1)
        else
            local v = (enabled and self.hovered) and 0.2 or 0.1
            self.bg:SetColorTexture(v, v, v + 0.02, 0.92)
            UI:SetEdgeColor(self, 0.34, 0.34, 0.38, enabled and 0.9 or 0.35)
            local ic = enabled and (self.hovered and 1 or 0.82) or 0.35
            self.icon:SetVertexColor(ic, ic, ic)
        end
    end
    function b:SetActive(on)
        self.active = on and true or false
        paint(self)
    end
    b:SetScript("OnEnter", function(self) self.hovered = true; paint(self) end)
    b:SetScript("OnLeave", function(self) self.hovered = false; paint(self) end)
    b:SetScript("OnEnable", paint)
    b:SetScript("OnDisable", paint)
    b:RegisterForClicks("LeftButtonUp")
    if onClick then b:SetScript("OnClick", function(self, mouseButton) onClick(self, mouseButton) end) end
    paint(b)
    return b
end

-- The editor icons: a 4x8 atlas of 64px cells drawn by dev/generators/gen_strategy_media.py, in this order:
-- 1 select, 2 pan, 3 circle, 4 rectangle, 5 arrow, 6 line, 7 pin, 8 text, 9 undo, 10 redo, 11 help, 12 delete,
-- 13 gear, 14 chevron down, 15 eye (open), 16 pencil (edit), 17 copy, 18 share, 19 invite (player +),
-- 20 call off (calendar x), 21 dice (games), 22 sparkles (disenchant), 23 bank, 24 three dots (more actions),
-- 25 page with lines (what's new), 26 crown (raid leader), and the strategy board's 3D view (UI/StrategyMap3D.lua):
-- 27 turn left, 28 turn right, 29 from above, 30 house (the whole room), 31 small map; 32 import (arrow into a
-- tray), 33 export (arrow out of a tray), 34 a model's turn knob (two curved arrows), 35 its size knob (a
-- two-headed diagonal arrow), 36 walk (a figure striding over a ring). The atlas is 4 columns by UI.ICON_ROWS rows
-- of 64px cells.
UI.ICON_ATLAS = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\tools"
UI.ICON_ROWS = 16
UI.ICON = { trash = 12, gear = 13, chevron = 14, games = 21, disenchant = 22, bank = 23, more = 24, notes = 25,
            crown = 26, import = 32, export = 33, knobTurn = 34, knobSize = 35, walk = 36 }
-- (the strategy board's chrome: 37 a target (Practice), 38 a keyboard (Keyboard and mouse), 39 a plus (New strategy))
UI.ICON.practice, UI.ICON.keys, UI.ICON.plus = 37, 38, 39
-- (the Atlas shopping list: 40 a bag, 41 a bag with a plus (add to it), 42 a speech bubble (whisper))
UI.ICON.bag, UI.ICON.bagAdd, UI.ICON.whisper = 40, 41, 42
-- (the Group Finder, art pack 4: 43 an eye's lids, 44 its iris, drawn over the lids and moved while listed; check
-- ns:HasAssets(4) first, else UI.ICON.eye)
UI.ICON.finder, UI.ICON.finderIris, UI.ICON.eye = 43, 44, 15
-- (art pack 4 too: 45 a calendar, the New raid sheet's calendar button)
UI.ICON.calendar = 45
function UI:IconCoords(i)
    local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
    return { col / 4, (col + 1) / 4, row / UI.ICON_ROWS, (row + 1) / UI.ICON_ROWS }
end

-- An atlas icon inside text ("|T...|t"), e.g. in front of a menu entry. color: { r, g, b } 0..1 (default white).
function UI:AtlasIconText(i, size, color)
    size = tonumber(size) or 14
    local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
    local c = color or { 1, 1, 1 }
    local function byte(v) return math.floor((tonumber(v) or 1) * 255 + 0.5) end
    return ("|T%s:%d:%d:0:0:256:%d:%d:%d:%d:%d:%d:%d:%d|t"):format(UI.ICON_ATLAS, size, size, 64 * UI.ICON_ROWS,
        col * 64, (col + 1) * 64, row * 64, (row + 1) * 64, byte(c[1]), byte(c[2]), byte(c[3]))
end

-- The atlas chevron (it points down) on a texture, turned to point left (right = false) or right.
function UI:SetChevron(tex, right)
    local c = UI:IconCoords(UI.ICON.chevron)
    local l, r, t, b = c[1], c[2], c[3], c[4]
    tex:SetTexture(UI.ICON_ATLAS)
    if right then tex:SetTexCoord(l, t, r, t, l, b, r, b) else tex:SetTexCoord(l, b, r, b, l, t, r, t) end
end

-- A small flat arrow (a chevron, no frame): back / on in a strip, a stepper or a calendar. b.icon is the chevron;
-- disabled it fades.
function UI:CreateArrowButton(parent, right, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(12, 12)
    b.icon:SetPoint("CENTER")
    UI:SetChevron(b.icon, right)
    b.icon:SetVertexColor(0.75, 0.75, 0.78)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnable", function(self) self.icon:SetAlpha(1) end)
    b:SetScript("OnDisable", function(self) self.icon:SetAlpha(0.25) end)
    return b
end

-- An icon button (UI.ICON_ATLAS index) that says what it does in a tooltip: title, then text.
function UI:CreateTipIconButton(parent, size, icon, title, text, onClick)
    local b = UI:CreateIconButton(parent, size, UI.ICON_ATLAS, UI:IconCoords(icon), onClick)
    b.tipTitle, b.tipText = title, text
    b:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(self.tipTitle)
        if self.tipText then GameTooltip:AddLine(self.tipText, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-- The small bin at the end of a list row that takes the entry off the list (tooltip: title). The caller sets the
-- position and the OnClick.
function UI:CreateRemoveButton(parent, title)
    local b = UI:CreateTipIconButton(parent, 18, UI.ICON.trash, title or "Remove", nil)
    b.icon:ClearAllPoints()
    b.icon:SetPoint("TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    return b
end

-- A flat dropdown: a sleek button with a chevron that opens build(root) as a context menu. Same surface as
-- CreateMenuButton (SetDefaultText, Refresh).
function UI:CreateSleekMenuButton(parent, text, width, build, height)
    local b = UI:CreateSleekButton(parent, "", width or 120, height or 22, function(self)
        UI:ContextMenu(self, build)
    end)
    local fs = b:GetFontString()
    fs:SetFontObject("GameFontHighlightSmall")
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", 8, 0)
    fs:SetPoint("RIGHT", -20, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    b:SetScript("OnMouseDown", nil)
    b:SetScript("OnMouseUp", nil)
    b.chevron = b:CreateTexture(nil, "ARTWORK")
    b.chevron:SetSize(12, 12)
    b.chevron:SetPoint("RIGHT", -6, 0)
    b.chevron:SetTexture(UI.ICON_ATLAS)
    b.chevron:SetTexCoord(unpack(UI:IconCoords(14)))
    b.chevron:SetVertexColor(1, 0.82, 0)
    b:SetText(text or "")
    function b:SetDefaultText(t) self:SetText(t or "") end
    function b:Refresh() end
    function b:OpenMenu() UI:ContextMenu(self, build) end
    return b
end

-- A dropdown that reads as text, not as a box: the value (an icon in front of it if wanted) and a small gold chevron
-- after it (the strategy board's strategy switch and map, like the raid page's spec / character pickers). opts = {
--   font (default "GameFontHighlight"), size (a font size), color { r, g, b } (the text; white while hovered),
--   icon (a UI.ICON_ATLAS index or a texture), iconSize (12), iconAlpha (0.65), chevSize (10), height (18),
--   build = function(root) (the menu), or options() -> { { text =, value = } }, selected(), select(value) (radios),
--   display(value) -> text (optional), title, tip (a text, or function(tooltip) that fills it) }
-- b:SetLabel(text) sets the text and fits the width; b:Refresh() shows selected(); b:OpenMenu(). b.fs, b.icon, b.chev.
-- The caller anchors it (by its RIGHT for a link that ends at an edge).
function UI:CreateLinkDropdown(parent, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(opts.height or 18)
    b.fs = b:CreateFontString(nil, "OVERLAY", opts.font or "GameFontHighlight")
    b.fs:SetJustifyH("LEFT")
    b.fs:SetWordWrap(false)
    if opts.size then
        local path, _, flags = b.fs:GetFont()
        if path then b.fs:SetFont(path, opts.size, flags) end
    end
    local base = opts.color or { 1, 1, 1 }
    local iconW = 0
    if opts.icon then
        local s = opts.iconSize or 12
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(s, s)
        b.icon:SetPoint("LEFT", 0, 0)
        if type(opts.icon) == "number" then
            b.icon:SetTexture(UI.ICON_ATLAS)
            b.icon:SetTexCoord(unpack(UI:IconCoords(opts.icon)))
        else
            b.icon:SetTexture(opts.icon)
        end
        b.icon:SetAlpha(opts.iconAlpha or 0.65)
        iconW = s + 5
    end
    b.fs:SetPoint("LEFT", iconW, 0)
    local cs = opts.chevSize or 10
    b.chev = b:CreateTexture(nil, "ARTWORK")
    b.chev:SetSize(cs, cs)
    b.chev:SetTexture(UI.ICON_ATLAS)
    b.chev:SetTexCoord(unpack(UI:IconCoords(UI.ICON.chevron)))
    b.chev:SetPoint("LEFT", b.fs, "RIGHT", 4, -1)
    local function paint(self)
        if self.hovered then
            self.fs:SetTextColor(1, 1, 1)
            self.chev:SetVertexColor(1, 1, 1)
        else
            self.fs:SetTextColor(base[1], base[2], base[3])
            self.chev:SetVertexColor(1, 0.82, 0)
        end
    end
    function b:SetLabel(text)
        self.fs:SetText(text or "")
        self:SetWidth(floor(iconW + (self.fs:GetStringWidth() or 40) + 4 + cs + 0.5))
    end
    function b:Refresh()
        if not opts.selected then return end
        local sel, text = opts.selected(), nil
        if opts.display and sel ~= nil then text = opts.display(sel) end
        if not text and opts.options then
            for _, o in ipairs(opts.options() or {}) do if o.value == sel then text = o.text end end
        end
        self:SetLabel(text or "|cff808080pick|r")
    end
    function b:OpenMenu()
        if opts.build then return UI:ContextMenu(self, opts.build) end
        return UI:ContextMenu(self, function(root)
            for _, o in ipairs(opts.options and opts.options() or {}) do
                root:CreateRadio(o.text, function(data) return opts.selected() == data end, function(data)
                    opts.select(data)
                    b:Refresh()
                end, o.value)
            end
        end)
    end
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function(self) self:OpenMenu() end)
    b:SetScript("OnEnter", function(self)
        self.hovered = true
        paint(self)
        if not (opts.title or opts.tip) then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if opts.title then GameTooltip:AddLine(opts.title) end
        if type(opts.tip) == "function" then opts.tip(GameTooltip)
        elseif opts.tip then GameTooltip:AddLine(opts.tip, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        self.hovered = false
        paint(self)
        GameTooltip:Hide()
    end)
    paint(b)
    b:SetLabel("")
    return b
end

-- A one-line text field in the flat style: dark fill, grey 1px edges that turn gold while typing. Enter and Escape
-- drop the focus.
function UI:CreateSleekEditBox(parent, width, height, fontObject)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetSize(width or 150, height or 22)
    eb:SetFontObject(fontObject or "GameFontHighlight")
    eb:SetTextInsets(6, 6, 0, 0)
    eb:SetAutoFocus(false)
    eb.bg = eb:CreateTexture(nil, "BACKGROUND")
    eb.bg:SetAllPoints()
    eb.bg:SetColorTexture(0.10, 0.10, 0.12, 0.92)
    UI:AddEdges(eb)
    local function paint(self)
        if self:HasFocus() then UI:SetEdgeColor(self, 1, 0.82, 0, 0.75) else UI:SetEdgeColor(self, 0.34, 0.34, 0.38, 0.9) end
    end
    eb:SetScript("OnEditFocusGained", paint)
    eb:SetScript("OnEditFocusLost", paint)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    paint(eb)
    return eb
end

-- A grey hint inside an edit box while it is empty ("Note for the organizers..."). Hooks the box's scripts, so call
-- it after the caller's own SetScript calls.
function UI:SetEditPlaceholder(eb, text, fontObject)
    if not eb.cdlHint then
        local hint = eb:CreateFontString(nil, "ARTWORK", fontObject or "GameFontDisableSmall")
        hint:SetPoint("LEFT", eb, "LEFT", 6, 0)
        hint:SetPoint("RIGHT", eb, "RIGHT", -6, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(false)
        eb.cdlHint = hint
        eb:HookScript("OnTextChanged", function(self) self.cdlHint:SetShown((self:GetText() or "") == "") end)
    end
    eb.cdlHint:SetText(text or "")
    eb.cdlHint:SetShown((eb:GetText() or "") == "")
end

-- Every tab of the addon is a text tab: grey text, gold with a gold underline while it is the open one.
-- size: "nav" (the main window's navigation), nil (a page's views: Upcoming / Teams / ...), "small" (views inside a
-- view: Sign-ups / Groups / Assignments). b:SetActive(on); b:SetLabel(text) also refits the width.
local TAB_SIZES = {
    nav   = { font = "GameFontHighlightMedium", fallback = "GameFontHighlight", height = 26, pad = 18 },
    page  = { font = "GameFontHighlight", height = 22, pad = 16 },
    small = { font = "GameFontHighlightSmall", height = 18, pad = 12 },
}
function UI:CreateUnderlineTab(parent, text, onClick, size)
    local s = TAB_SIZES[size or "page"] or TAB_SIZES.page
    local font = s.font
    if s.fallback and not _G[font] then font = s.fallback end
    local b = CreateFrame("Button", nil, parent)
    local fs = b:CreateFontString(nil, "OVERLAY", font)
    fs:SetPoint("CENTER", 0, 1)
    b:SetFontString(fs)
    b:SetText(text or "")
    b:SetSize((fs:GetStringWidth() or 40) + s.pad, s.height)
    function b:SetLabel(t)
        self:SetText(t or "")
        self:SetWidth((fs:GetStringWidth() or 40) + s.pad)
    end
    b.line = b:CreateTexture(nil, "ARTWORK")
    b.line:SetPoint("BOTTOMLEFT", 4, 0)
    b.line:SetPoint("BOTTOMRIGHT", -4, 0)
    b.line:SetHeight(2)
    b.line:SetColorTexture(1, 0.82, 0, 0.9)
    local function paint(self)
        self.line:SetShown(self.active and true or false)
        if self.active then
            fs:SetTextColor(1, 0.82, 0)
        elseif self.hovered then
            fs:SetTextColor(1, 1, 1)
        else
            fs:SetTextColor(0.62, 0.62, 0.62)
        end
    end
    function b:SetActive(on)
        self.active = on and true or false
        paint(self)
    end
    b:SetScript("OnEnter", function(self) self.hovered = true; paint(self) end)
    b:SetScript("OnLeave", function(self) self.hovered = false; paint(self) end)
    b:RegisterForClicks("LeftButtonUp")
    if onClick then b:SetScript("OnClick", function(self, mouseButton) onClick(self, mouseButton) end) end
    paint(b)
    return b
end

-- A small status pill ("ENGAGED", "BIS LOCKED"): pill:Set(text, { r, g, b }).
function UI:CreatePill(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetHeight(14)
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    p.fs = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.fs:SetPoint("CENTER")
    function p:Set(text, color)
        color = color or { 0.55, 0.55, 0.55 }
        self.fs:SetText(text or "")
        self:SetWidth((self.fs:GetStringWidth() or 40) + 10)
        self.bg:SetColorTexture(color[1], color[2], color[3], 0.35)
    end
    return p
end

-- A rounded pill look for frame f, h high (a 1px edge and a fill, drawn from half discs and a bar that don't overlap,
-- so a see-through fill stays even): f:SetPillColors(fill, edge) with { r, g, b, a } each. The caller sizes f (its
-- height = h) and puts its own texts / icons on it.
function UI:AddPillShape(f, h)
    local disc = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
    local function part(sub, inset)
        local l = f:CreateTexture(nil, "BACKGROUND", nil, sub)
        l:SetTexture(disc)
        l:SetTexCoord(0, 0.5, 0, 1)
        l:SetSize(h / 2 - inset, h - 2 * inset)
        l:SetPoint("LEFT", inset, 0)
        local r = f:CreateTexture(nil, "BACKGROUND", nil, sub)
        r:SetTexture(disc)
        r:SetTexCoord(0.5, 1, 0, 1)
        r:SetSize(h / 2 - inset, h - 2 * inset)
        r:SetPoint("RIGHT", -inset, 0)
        local m = f:CreateTexture(nil, "BACKGROUND", nil, sub)
        m:SetColorTexture(1, 1, 1, 1)
        m:SetPoint("TOPLEFT", f, "TOPLEFT", h / 2, -inset)
        m:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -h / 2, inset)
        return { l, r, m }
    end
    f.pillEdge = part(1, 0)
    f.pillFill = part(2, 1)
    function f:SetPillColors(fill, edge)
        for _, t in ipairs(self.pillFill) do t:SetVertexColor(fill[1], fill[2], fill[3], fill[4] or 1) end
        for _, t in ipairs(self.pillEdge) do t:SetVertexColor(edge[1], edge[2], edge[3], edge[4] or 1) end
    end
end

-- A small rounded tag in a row or a bar: "BiS", "Alt P2", "OS", "BiS locked". A tinted fill, a 1px edge and text in
-- the tag's colour. p:Set(text, kind, icon): kind = "bis" | "alt" | "os" | "ok" | "warn" | "mute" (default); icon
-- (optional) = a texture path in front of the text. It sizes itself to its text. The fill is mixed with the colour
-- it sits on (p:SetBase(r, g, b), default the flat card fill) so the edge never shows through it.
UI.TAG_LOOK = {
    bis  = { text = { 1, 0.82, 0 },       tint = { 1, 0.82, 0 },       edge = { 1, 0.82, 0, 0.5 } },
    alt  = { text = { 0.56, 0.78, 1 },    tint = { 0.31, 0.63, 1 },    edge = { 0.43, 0.71, 1, 0.5 } },
    os   = { text = { 0.79, 0.65, 1 },    tint = { 0.63, 0.43, 1 },    edge = { 0.67, 0.51, 1, 0.5 } },
    ok   = { text = { 0.62, 0.94, 0.69 }, tint = { 0.24, 0.71, 0.35 }, edge = { 0.35, 0.86, 0.47, 0.5 } },
    warn = { text = { 1, 0.69, 0.40 },    tint = { 1, 0.55, 0.10 },    edge = { 1, 0.55, 0.10, 0.55 } },
    mute = { text = { 0.72, 0.72, 0.72 }, tint = { 1, 1, 1 },          edge = { 1, 1, 1, 0.2 } },
}
function UI:CreateTagPill(parent, h)
    h = h or 16
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(30, h)
    UI:AddPillShape(p, h)
    p.base = { 0.10, 0.10, 0.12 }
    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(h - 6, h - 6)
    p.icon:SetPoint("LEFT", 6, 0)
    p.icon:Hide()
    p.fs = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.fs:SetWordWrap(false)
    function p:SetBase(r, g, b) self.base = { r, g, b } end
    function p:Set(text, kind, icon)
        local look = UI.TAG_LOOK[kind] or UI.TAG_LOOK.mute
        local a, base, t = 0.12, self.base, look.tint
        self:SetPillColors({ base[1] + (t[1] - base[1]) * a, base[2] + (t[2] - base[2]) * a,
            base[3] + (t[3] - base[3]) * a, 1 }, look.edge)
        self.fs:SetText(text or "")
        self.fs:SetTextColor(look.text[1], look.text[2], look.text[3])
        local x = 7
        if icon then
            self.icon:SetTexture(icon)
            self.icon:Show()
            x = 6 + (h - 6) + 3
        else
            self.icon:Hide()
        end
        self.fs:ClearAllPoints()
        self.fs:SetPoint("LEFT", x, 0)
        self:SetWidth(floor(x + (self.fs:GetStringWidth() or 16) + 7 + 0.5))
    end
    return p
end

-- An on / off switch, the look of the Dungeons tab's "I'm up for a run": a 34x18 pill with a knob, green with the knob
-- on the right while on. It is a CheckButton: a click flips it and calls setter(checked); s:Refresh() reads getter();
-- s:SetChecked(on) / s:SetOn(on) set it from code and repaint, s:IsOn() reads it. label (optional): a text to its right
-- that is part of the click area (s.label); a caller that draws its own text for it may point s.label at that.
-- s:SetHover(on) gives it the hover look while the mouse is over something else that clicks it (a settings row).
-- It moves: the knob slides over with its front edge a little ahead (it stretches and settles round again), the
-- green follows it along the track, a soft ring goes out when it comes on, and a held mouse button squeezes the
-- knob toward the other side. A change from code while it is on screen moves the same way; one made in the frame it
-- appears (a page filling its fields as it opens) is set at once.
local SWITCH_DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SWITCH_LOOK = {
    on  = { fill = { 0.11, 0.47, 0.20, 0.95 }, edge = { 0.30, 0.71, 0.39, 1 }, hover = { 0.55, 1, 0.66, 1 },
            knob = { 0.92, 1, 0.94, 1 }, ring = { 0.35, 0.86, 0.47 } },
    off = { fill = { 0.16, 0.16, 0.18, 0.95 }, edge = { 0.34, 0.34, 0.38, 0.9 }, hover = { 0.62, 0.62, 0.68, 1 },
            knob = { 0.54, 0.54, 0.56, 1 } },
}
local SWITCH_W, SWITCH_H, KNOB, KNOB_IN = 34, 18, 12, 3
local SWITCH_SLIDE, SWITCH_RING, SWITCH_PRESS = 0.26, 0.55, 0.09     -- seconds
local SWITCH_LEAD = 0.12                                             -- how far the front edge runs ahead (of 1)
local SWITCH_SQUEEZE, SWITCH_RING_OUT = 4, 6                         -- px

local function EaseInOut(t)
    if t <= 0 then return 0 elseif t >= 1 then return 1 end
    if t < 0.5 then return 4 * t * t * t end
    t = 2 - 2 * t
    return 1 - t * t * t / 2
end

local function EaseOut(t)
    if t <= 0 then return 0 elseif t >= 1 then return 1 end
    t = 1 - t
    return 1 - t * t * t
end

-- A pill painted with three textures on f that can be moved and stretched every frame: p:Lay(left, right, h, y)
-- (px from f's left edge; y up from its middle), p:SetColor(r, g, b, a), p:SetShown(on).
local function NewPillPaint(f, layer, sub)
    local p = {}
    for i = 1, 3 do
        local t = f:CreateTexture(nil, layer, nil, sub)
        if i < 3 then
            t:SetTexture(SWITCH_DISC)
            t:SetTexCoord(i == 1 and 0 or 0.5, i == 1 and 0.5 or 1, 0, 1)
        else
            t:SetColorTexture(1, 1, 1, 1)
        end
        p[i] = t
    end
    function p:Lay(l, r, h, y)
        y = y or 0
        if r - l < h then r = l + h end
        local half = h / 2
        local a, b, m = self[1], self[2], self[3]
        a:SetSize(half, h)
        a:ClearAllPoints()
        a:SetPoint("LEFT", f, "LEFT", l, y)
        b:SetSize(half, h)
        b:ClearAllPoints()
        b:SetPoint("RIGHT", f, "LEFT", r, y)
        m:ClearAllPoints()
        m:SetPoint("TOPLEFT", f, "LEFT", l + half, y + half)
        m:SetPoint("BOTTOMRIGHT", f, "LEFT", r - half, y - half)
        m:SetShown(r - l > h + 0.01)
    end
    function p:SetColor(r, g, b, a)
        for i = 1, 3 do self[i]:SetVertexColor(r, g, b, a or 1) end
    end
    function p:SetShown(on)
        for i = 1, 2 do self[i]:SetShown(on) end
        if not on then self[3]:Hide() end
    end
    return p
end

local function Mix(a, b, t, i) return a[i] + (b[i] - a[i]) * t end

-- The switch as it is this frame: s.kl / s.kr = the knob's edges, s.mix = 0 (off) .. 1 (on) for the colours,
-- s.press = 0 .. 1 (a held button), s.ringT = seconds into the ring.
local function DrawSwitch(s)
    local off, on = SWITCH_LOOK.off, SWITCH_LOOK.on
    local enabled = s:IsEnabled()
    local hov = enabled and (s.hovered or s.rowHovered)
    local c = s.mix
    s:SetPillColors(off.fill, hov and off.hover or off.edge)
    local l, r = s.kl, s.kr
    local sq = s.press * SWITCH_SQUEEZE
    if (l + r) / 2 < SWITCH_W / 2 then r = r + sq else l = l - sq end
    -- the green: from the track's left end to just past the knob, faded in with the colour
    local gr = math.max(SWITCH_H, r + KNOB_IN)
    local ge = hov and on.hover or on.edge
    s.greenEdge:Lay(0, gr, SWITCH_H)
    s.greenEdge:SetColor(ge[1], ge[2], ge[3], ge[4] * c)
    s.greenFill:Lay(1, gr - 1, SWITCH_H - 2)
    s.greenFill:SetColor(on.fill[1], on.fill[2], on.fill[3], on.fill[4] * c)
    local shown = c > 0.001
    s.greenEdge:SetShown(shown)
    s.greenFill:SetShown(shown)
    s.knobShadow:Lay(l - 0.5, r + 0.5, KNOB + 1, -1)
    s.knobShadow:SetColor(0, 0, 0, 0.35)
    s.knobPaint:Lay(l, r, KNOB)
    s.knobPaint:SetColor(Mix(off.knob, on.knob, c, 1), Mix(off.knob, on.knob, c, 2), Mix(off.knob, on.knob, c, 3), 1)
    if s.ringT then
        local g = s.ringT / SWITCH_RING
        local out = SWITCH_RING_OUT * EaseOut(g)
        s.ring:Lay(-out, SWITCH_W + out, SWITCH_H + 2 * out)
        s.ring:SetColor(on.ring[1], on.ring[2], on.ring[3], 0.42 * (1 - g) * (1 - g))
        s.ring:SetShown(true)
    else
        s.ring:SetShown(false)
    end
    s:SetAlpha(enabled and 1 or 0.45)
end

local function StepSwitch(s, elapsed)
    local busy = false
    local a = s.anim
    if a then
        a.t = a.t + (elapsed or 0)
        local u = math.min(1, a.t / SWITCH_SLIDE)
        local lead = EaseInOut(u / (1 - SWITCH_LEAD))
        local trail = EaseInOut((u - SWITCH_LEAD) / (1 - SWITCH_LEAD))
        if a.right then
            s.kl, s.kr = a.fl + (a.tl - a.fl) * trail, a.fr + (a.tr - a.fr) * lead
        else
            s.kl, s.kr = a.fl + (a.tl - a.fl) * lead, a.fr + (a.tr - a.fr) * trail
        end
        s.mix = a.fm + (a.tm - a.fm) * EaseOut(u)
        if u >= 1 then s.anim = nil else busy = true end
    end
    if s.press ~= s.pressTo then
        local step = (elapsed or 0) / SWITCH_PRESS
        if s.press < s.pressTo then s.press = math.min(s.pressTo, s.press + step)
        else s.press = math.max(s.pressTo, s.press - step) end
        busy = busy or s.press ~= s.pressTo
    end
    if s.ringT then
        s.ringT = s.ringT + (elapsed or 0)
        if s.ringT >= SWITCH_RING then s.ringT = nil else busy = true end
    end
    DrawSwitch(s)
    if not busy then s:SetScript("OnUpdate", nil) end
end

-- Moves the knob to on / off: slid from where it is now (a squeeze included), or (animate false) set at once.
local function GoSwitch(s, on, animate)
    s.target = on
    local tl = on and (SWITCH_W - KNOB_IN - KNOB) or KNOB_IN
    if not animate then
        s.anim, s.ringT, s.press, s.pressTo = nil, nil, 0, 0
        s.kl, s.kr, s.mix = tl, tl + KNOB, on and 1 or 0
        s:SetScript("OnUpdate", nil)
        DrawSwitch(s)
        return
    end
    local l, r = s.kl, s.kr
    local sq = s.press * SWITCH_SQUEEZE
    if (l + r) / 2 < SWITCH_W / 2 then r = r + sq else l = l - sq end
    s.press, s.pressTo = 0, 0
    s.anim = { t = 0, right = on, fl = l, fr = r, tl = tl, tr = tl + KNOB, fm = s.mix, tm = on and 1 or 0 }
    if on then s.ringT = 0 end
    s:SetScript("OnUpdate", StepSwitch)
    DrawSwitch(s)
end

function UI:CreateSwitch(parent, getter, setter, label)
    local s = CreateFrame("CheckButton", nil, parent)
    s:SetSize(SWITCH_W, SWITCH_H)
    UI:AddPillShape(s, SWITCH_H)
    s.ring = NewPillPaint(s, "BACKGROUND", -1)
    s.greenEdge = NewPillPaint(s, "BACKGROUND", 3)
    s.greenFill = NewPillPaint(s, "BACKGROUND", 4)
    s.knobShadow = NewPillPaint(s, "ARTWORK", 0)
    s.knobPaint = NewPillPaint(s, "ARTWORK", 1)
    s.press, s.pressTo, s.mix = 0, 0, 0
    s.kl, s.kr = KNOB_IN, KNOB_IN + KNOB
    s.shownAt = GetTime()
    local setChecked = s.SetChecked
    function s:SetChecked(on)
        on = on and true or false
        setChecked(self, on)
        if on ~= self.target then
            -- (on screen since an earlier frame: it moves)
            GoSwitch(self, on, self.target ~= nil and self:IsVisible() and GetTime() > (self.shownAt or 0))
        else
            DrawSwitch(self)
        end
    end
    function s:SetOn(on) self:SetChecked(on) end
    function s:IsOn() return self:GetChecked() and true or false end
    function s:Refresh()
        if getter then self:SetChecked(getter()) else self:SetChecked(self:GetChecked()) end
    end
    function s:SetHover(on)
        self.rowHovered = on and true or false
        DrawSwitch(self)
    end
    if label then
        s.label = s:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        s.label:SetPoint("LEFT", s, "RIGHT", 9, 0)
        s.label:SetJustifyH("LEFT")
        s.label:SetWordWrap(false)
        s.label:SetText(label)
        s:SetHitRectInsets(-2, -((s.label:GetStringWidth() or 0) + 11), -3, -3)
    else
        s:SetHitRectInsets(-4, -4, -4, -4)
    end
    s:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        GoSwitch(self, on, self:IsVisible())
        if setter then setter(on) end
    end)
    s:SetScript("OnEnable", DrawSwitch)
    s:SetScript("OnDisable", function(self)
        self.pressTo = 0
        DrawSwitch(self)
    end)
    s:HookScript("OnEnter", function(self) self.hovered = true; DrawSwitch(self) end)
    s:HookScript("OnLeave", function(self)
        self.hovered = false
        DrawSwitch(self)
    end)
    -- a held button squeezes the knob toward the other side
    s:HookScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or not self:IsEnabled() then return end
        self.pressTo = 1
        self:SetScript("OnUpdate", StepSwitch)
    end)
    s:HookScript("OnMouseUp", function(self)
        self.pressTo = 0
        if self.press > 0 then self:SetScript("OnUpdate", StepSwitch) end
    end)
    s:HookScript("OnShow", function(self) self.shownAt = GetTime() end)
    s:HookScript("OnHide", function(self)
        if self.target ~= nil then GoSwitch(self, self.target, false) end
    end)
    s:Refresh()
    return s
end

function UI:CreatePanel(parent)
    local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    p:SetBackdrop(PANEL_BACKDROP)
    p:SetBackdropColor(0, 0, 0, 0.6)
    p:SetBackdropBorderColor(0.45, 0.45, 0.45, 0.9)
    return p
end

function UI:CreateLabel(parent, text, fontObject)
    local fs = parent:CreateFontString(nil, "OVERLAY", fontObject or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    return fs
end

-- The column titles over a list (small gold text). h:AddColumn(text, x, width, opts) adds one and returns its button
-- (b.label is the text); opts = { justify = "LEFT" | "CENTER" | "RIGHT", onClick = fn(b), tip = fn(b) (fills
-- GameTooltip) }. A title is never cut off: its button grows to fit the text.
function UI:CreateColumnHeader(parent, height)
    local h = CreateFrame("Frame", nil, parent)
    h:SetHeight(height or 18)
    h.columns = {}
    function h:AddColumn(text, x, width, opts)
        opts = opts or {}
        local justify = opts.justify or "LEFT"
        local b = CreateFrame("Button", nil, self)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetWordWrap(false)
        fs:SetText(text or "")
        fs:SetPoint(justify, b, justify, 0, 0)
        b.label = fs
        -- a wider title grows around the column's own anchor (a centred one stays centred over its values)
        width = width or 0
        b:SetSize(math.max(width, (fs:GetStringWidth() or 0) + 6), self:GetHeight())
        local ax = (x or 0) + (justify == "CENTER" and width / 2 or (justify == "RIGHT" and width or 0))
        b:SetPoint(justify, self, "LEFT", ax, 0)
        if opts.onClick then b:SetScript("OnClick", function(btn) opts.onClick(btn) end) end
        if opts.tip then
            b:SetScript("OnEnter", function(btn)
                GameTooltip:SetOwner(btn, "ANCHOR_TOP")
                opts.tip(btn)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        if not (opts.onClick or opts.tip) then b:EnableMouse(false) end
        self.columns[#self.columns + 1] = b
        return b
    end
    return h
end

---------------------------------------------------------------------------
-- Item button
---------------------------------------------------------------------------

-- Buttons whose item quality is not cached yet; re-coloured on ITEMINFO_READY.
local pendingButtons = setmetatable({}, { __mode = "k" })

local function SetDesat(texture, amount)
    if texture.SetDesaturation then
        texture:SetDesaturation(amount)
    else
        texture:SetDesaturated(amount > 0)
    end
end

local function ApplyQuality(b)
    local id = b.itemID
    if not id then
        pendingButtons[b] = nil
        b.border:Hide()
        return
    end
    local q
    if ns.ItemDB and ns.ItemDB.GetQuality then
        q = ns.ItemDB:GetQuality(id)
    elseif C_Item and C_Item.GetItemQualityByID then
        q = C_Item.GetItemQualityByID(id)
    end
    if q == nil then
        pendingButtons[b] = true
        b.border:Hide()
        return
    end
    pendingButtons[b] = nil
    if q >= 2 then
        local r, g, bl = UI:QualityColor(q)
        b.border:SetVertexColor(r, g, bl, 0.9)
        b.border:Show()
    else
        b.border:Hide()
    end
end

local function ApplyState(b)
    local state = b.state
    local icon = b.icon
    b:SetAlpha(1)
    b.overlay:Hide()
    if not b.itemID then
        SetDesat(icon, 1)
        icon:SetAlpha(0.6)
        if state == "dim" then b:SetAlpha(0.35) end
        return
    end
    icon:SetAlpha(1)
    SetDesat(icon, 0)
    if state == "obtained" then
        SetDesat(icon, 0.6)
        b.overlay:SetTexture(Tex("check"))
        b.overlay:Show()
    elseif state == "equipped" then
        b.overlay:SetTexture(Tex("check"))
        b.overlay:Show()
    elseif state == "awarded" then
        b.overlay:SetTexture(Tex("star"))
        b.overlay:Show()
    elseif state == "dim" then
        b:SetAlpha(0.35)
    end
end

local ItemButtonMethods = {}

-- Sets the item (nil = empty slot look). Resets the state to normal; call SetState afterwards.
function ItemButtonMethods:SetItem(itemID, emptyTexture)
    itemID = tonumber(itemID)
    if itemID and itemID <= 0 then itemID = nil end
    self.itemID = itemID
    self.state = nil
    if itemID then
        local icon = (ns.ItemDB and ns.ItemDB.GetIcon and ns.ItemDB:GetIcon(itemID))
            or (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID))
            or QUESTION_MARK_ICON
        self.icon:SetTexture(icon)
    else
        self.icon:SetTexture(emptyTexture or Tex("slotBg"))
    end
    ApplyQuality(self)
    ApplyState(self)
end

function ItemButtonMethods:SetState(state)
    self.state = state
    ApplyState(self)
end

function ItemButtonMethods:SetBadge(text, r, g, b)
    if text == nil or text == "" then
        self.badge:Hide()
        return
    end
    self.badge:SetText(text)
    self.badge:SetTextColor(r or 1, g or 0.82, b or 0)
    self.badge:Show()
end

local function ItemButton_OnEnter(self)
    if not self.itemID and not self.onTooltip then return end
    local owner = self
    UI:SetItemTooltip(owner, self.itemID, self.onTooltip and function(tt) self.onTooltip(self, tt) end)
end

local function ItemButton_OnLeave()
    GameTooltip:Hide()
end

local function ItemButton_OnClick(self, mouseButton)
    if self.__cdlDropTime and self.__cdlDropTime == GetTime() then return end
    if self.itemID and UI:HandleModifiedItemClick(self.itemID) then return end
    if self.onClick then self.onClick(self, mouseButton) end
end

function UI:CreateItemButton(parent, size)
    size = size or 36
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetTexture(Tex("slotBg"))
    b.bg:SetVertexColor(0.25, 0.25, 0.25, 1)

    local inset = size >= 24 and 2 or 1
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", inset, -inset)
    b.icon:SetPoint("BOTTOMRIGHT", -inset, inset)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetAllPoints()
    b.border:SetTexture(Tex("border"))
    b.border:Hide()

    local ov = math.max(8, floor(size * 0.4 + 0.5))
    b.overlay = b:CreateTexture(nil, "OVERLAY", nil, 2)
    b.overlay:SetSize(ov, ov)
    b.overlay:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, -2)
    b.overlay:Hide()

    b.badge = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.badge:SetPoint("TOPRIGHT", b, "TOPRIGHT", 2, 1)
    b.badge:SetJustifyH("RIGHT")
    b.badge:Hide()

    b:SetHighlightTexture(Tex("hilight"), "ADD")

    for k, fn in pairs(ItemButtonMethods) do b[k] = fn end

    b:SetScript("OnEnter", ItemButton_OnEnter)
    b:SetScript("OnLeave", ItemButton_OnLeave)
    b:SetScript("OnClick", ItemButton_OnClick)
    UI:AttachItemDrop(b, function(self, itemID)
        if self.onReceiveItem then self.onReceiveItem(self, itemID) end
    end)

    b:SetItem(nil)
    return b
end

ns:On("ITEMINFO_READY", function()
    for b in pairs(pendingButtons) do
        if b.itemID then
            ApplyQuality(b)
        else
            pendingButtons[b] = nil
        end
    end
end)

---------------------------------------------------------------------------
-- Flat scroll bar: a thin dark track and a grey thumb (lighter on hover, gold while dragged), only shown when there
-- is something to scroll. It drives a ScrollBox (CreateScrollList) or a plain ScrollFrame (CreateScrollFrame)
-- through an adapter a = { get = fn -> 0..1, visible = fn -> visible fraction 0..1 (1: nothing to scroll),
-- set = fn(0..1), step = fn(dir) (dir 1: one wheel step down, -1: up) }.
---------------------------------------------------------------------------

local BAR_W = 6

local function Clamp01(v)
    if v < 0 then return 0 elseif v > 1 then return 1 end
    return v
end

local function CreateFlatScrollBar(parent, a)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(BAR_W)
    bar.track = bar:CreateTexture(nil, "BACKGROUND")
    bar.track:SetAllPoints()
    bar.track:SetColorTexture(1, 1, 1, 0.06)
    local thumb = CreateFrame("Button", nil, bar)
    thumb:SetWidth(BAR_W)
    thumb:SetPoint("TOP")
    thumb:SetHeight(20)
    thumb.tex = thumb:CreateTexture(nil, "ARTWORK")
    thumb.tex:SetAllPoints()
    bar.thumb = thumb
    local function paint()
        if thumb.dragging then
            thumb.tex:SetColorTexture(1, 0.82, 0, 0.85)
        elseif thumb.hovered then
            thumb.tex:SetColorTexture(0.75, 0.75, 0.78, 0.9)
        else
            thumb.tex:SetColorTexture(0.45, 0.45, 0.49, 0.85)
        end
    end
    function bar:Update()
        local vis = a.visible() or 1
        if vis >= 0.999 then
            self:Hide()
            return
        end
        self:Show()
        local h = self:GetHeight() or 0
        local th = math.min(h, math.max(18, h * vis))
        thumb:SetHeight(th)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", self, "TOP", 0, -(h - th) * Clamp01(a.get() or 0))
    end
    function bar:Page(dir)
        local vis = a.visible() or 1
        if vis >= 0.999 then return end
        a.set(Clamp01((a.get() or 0) + dir * vis / (1 - vis)))
    end
    local function cursorY(f)
        local _, y = GetCursorPosition()
        return y / (f:GetEffectiveScale() or 1)
    end
    thumb:SetScript("OnEnter", function() thumb.hovered = true; paint() end)
    thumb:SetScript("OnLeave", function() thumb.hovered = false; paint() end)
    thumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self.dragging, self.startY, self.startAt = true, cursorY(self), a.get() or 0
        paint()
        self:SetScript("OnUpdate", function(s)
            local free = (bar:GetHeight() or 0) - (s:GetHeight() or 0)
            if free > 0 then a.set(Clamp01(s.startAt + (s.startY - cursorY(s)) / free)) end
        end)
    end)
    thumb:SetScript("OnMouseUp", function(self)
        self.dragging = false
        self:SetScript("OnUpdate", nil)
        paint()
    end)
    -- a click on the track pages towards it; the wheel scrolls as over the list
    bar:SetScript("OnMouseDown", function(self)
        local top = thumb:GetTop()
        self:Page((top and cursorY(self) > top) and -1 or 1)
    end)
    bar:EnableMouseWheel(true)
    bar:SetScript("OnMouseWheel", function(_, delta) a.step(delta > 0 and -1 or 1) end)
    bar:SetScript("OnSizeChanged", function(self) self:Update() end)
    paint()
    return bar
end

-- A ScrollFrame with the flat scroll bar to the right of it (outside its right edge, like the old template's bar:
-- leave about 12px for it) and mouse wheel scrolling. sf.ScrollBar is the bar.
function UI:CreateScrollFrame(parent, name)
    local sf = CreateFrame("ScrollFrame", name, parent)
    local function range() return sf:GetVerticalScrollRange() or 0 end
    local bar
    bar = CreateFlatScrollBar(parent, {
        get = function()
            local r = range()
            return r > 0 and (sf:GetVerticalScroll() or 0) / r or 0
        end,
        visible = function()
            local h, r = sf:GetHeight() or 0, range()
            if r <= 0 or h <= 0 then return 1 end
            return h / (h + r)
        end,
        set = function(p) sf:SetVerticalScroll(p * range()) end,
        step = function(dir)
            local r = range()
            sf:SetVerticalScroll(math.max(0, math.min(r, (sf:GetVerticalScroll() or 0) + dir * 40)))
        end,
    })
    bar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 4, 0)
    sf.ScrollBar = bar
    local function update()
        local r = range()
        if (sf:GetVerticalScroll() or 0) > r then sf:SetVerticalScroll(r) end   -- the content got shorter
        bar:Update()
    end
    sf:HookScript("OnScrollRangeChanged", update)
    sf:HookScript("OnVerticalScroll", function() bar:Update() end)
    sf:HookScript("OnSizeChanged", update)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(_, delta)
        local r = range()
        sf:SetVerticalScroll(math.max(0, math.min(r, (sf:GetVerticalScroll() or 0) - delta * 40)))
    end)
    return sf
end

---------------------------------------------------------------------------
-- Scroll list (modern ScrollBox; call shapes as in Auctionator RecentsContainer/ListsContainer)
---------------------------------------------------------------------------

-- extentFn (optional, DisasterZone extension): function(data) -> row height, for mixed-height rows.
function UI:CreateScrollList(parent, rowHeight, initRow, extentFn)
    rowHeight = rowHeight or 20
    local list = { data = {} }

    local frame = CreateFrame("Frame", nil, parent)
    list.frame = frame

    local box = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    box:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 0)
    list.box = box

    local function scrollable() return box.HasScrollableExtent and box:HasScrollableExtent() end
    local bar = CreateFlatScrollBar(frame, {
        get = function() return box:GetScrollPercentage() or 0 end,
        visible = function()
            if not scrollable() then return 1 end
            return box.GetVisibleExtentPercentage and box:GetVisibleExtentPercentage() or 1
        end,
        set = function(p) box:SetScrollPercentage(p, ScrollBoxConstants and ScrollBoxConstants.NoScrollInterpolation) end,
        step = function(dir)
            if dir > 0 then box:ScrollIncrease() else box:ScrollDecrease() end
        end,
    })
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 8, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 8, 0)
    list.bar = bar

    local view = CreateScrollBoxListLinearView(0, 0, 0, 0)
    view:SetElementExtent(rowHeight)
    if extentFn and view.SetElementExtentCalculator then
        view:SetElementExtentCalculator(function(_, data)
            return extentFn(data) or rowHeight
        end)
    end
    view:SetElementInitializer("Button", function(row, data)
        row.__cdlData = data
        initRow(row, data)
    end)
    if view.SetPanExtent then view:SetPanExtent(rowHeight * 2) end
    box:Init(view)
    list.view = view
    -- the bar follows the list (and only shows when there is something to scroll)
    if box.RegisterCallback and BaseScrollBoxEvents then
        box:RegisterCallback(BaseScrollBoxEvents.OnScroll, function() bar:Update() end, bar)
        box:RegisterCallback(BaseScrollBoxEvents.OnLayout, function() bar:Update() end, list)
    end
    bar:Update()

    list.emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    list.emptyText:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -24)
    list.emptyText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -36, -24)
    list.emptyText:SetJustifyH("CENTER")
    list.emptyText:Hide()

    -- resetScroll (optional): true jumps back to the top instead of keeping the position.
    function list:SetData(array, resetScroll)
        self.data = type(array) == "table" and array or {}
        self.box:SetDataProvider(CreateDataProvider(self.data), not resetScroll)
        self.emptyText:SetShown(#self.data == 0 and (self.emptyText:GetText() or "") ~= "")
    end

    -- Re-runs initRow on every visible row (e.g. after item info arrived).
    function list:Refresh()
        self.box:ForEachFrame(function(row)
            local data = row.__cdlData
            if data == nil and row.GetElementData then data = row:GetElementData() end
            if data ~= nil then initRow(row, data) end
        end)
    end

    function list:GetData()
        return self.data
    end

    function list:SetEmptyText(text)
        self.emptyText:SetText(text or "")
        self.emptyText:SetShown(#self.data == 0 and (text or "") ~= "")
    end

    function list:ScrollToTop()
        if self.box.ScrollToBegin then self.box:ScrollToBegin() end
    end

    return list
end

---------------------------------------------------------------------------
-- Buttons, checkboxes, search box
---------------------------------------------------------------------------

-- A text button in the flat style (every text button of the addon; b:SetKind("primary") marks a view's main action,
-- "danger" a destructive one). Without a width it fits its label.
function UI:CreateButton(parent, text, width, height, onClick)
    return UI:CreateSleekButton(parent, text, width, height or 22, onClick)
end

-- A checkbox in the flat style: a dark 14px box with a 1px edge (gold while hovered) and a gold check; the label
-- to its right is part of the click area. The frame keeps the old 24x24 size, so callers' anchors still fit.
local CHECK_MARK = "Interface\\Buttons\\UI-CheckBox-Check"
function UI:CreateCheckbox(parent, label, getter, setter)
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(24, 24)
    -- the box is drawn on the button itself (a child frame would cover the check mark)
    local box = cb:CreateTexture(nil, "BACKGROUND")
    box:SetSize(14, 14)
    box:SetPoint("LEFT", 4, 0)
    box:SetColorTexture(0.10, 0.10, 0.12, 0.92)
    box.edges = {}
    for _, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
                         { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local t = cb:CreateTexture(nil, "BORDER")
        t:SetPoint(e[1], box, e[1])
        t:SetPoint(e[2], box, e[2])
        if e[3] then t:SetHeight(1) else t:SetWidth(1) end
        box.edges[#box.edges + 1] = t
    end
    cb.box = box
    local check = cb:CreateTexture(nil, "ARTWORK")
    check:SetPoint("CENTER", box, "CENTER", 1, 1)
    check:SetSize(20, 20)
    check:SetTexture(CHECK_MARK)
    cb:SetCheckedTexture(check)
    local dimCheck = cb:CreateTexture(nil, "ARTWORK")
    dimCheck:SetPoint("CENTER", box, "CENTER", 1, 1)
    dimCheck:SetSize(20, 20)
    dimCheck:SetTexture(CHECK_MARK)
    dimCheck:SetDesaturated(true)
    dimCheck:SetAlpha(0.5)
    cb:SetDisabledCheckedTexture(dimCheck)
    cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cb.label:SetPoint("LEFT", box, "RIGHT", 6, 0)
    cb.label:SetJustifyH("LEFT")
    cb.label:SetText(label or "")
    cb:SetHitRectInsets(0, -(cb.label:GetStringWidth() + 4), 0, 0)

    local function paint(self)
        local enabled = self:IsEnabled()
        if enabled and self.hovered then
            UI:SetEdgeColor(box, 1, 0.82, 0, 0.75)
        else
            UI:SetEdgeColor(box, 0.45, 0.45, 0.50, enabled and 0.95 or 0.4)
        end
    end
    -- the label greys out only while disabled (callers may give it their own font object otherwise)
    local function enableChanged(self)
        if self:IsEnabled() then self.label:SetTextColor(1, 1, 1) else self.label:SetTextColor(0.5, 0.5, 0.5) end
        paint(self)
    end
    function cb:Refresh()
        self:SetChecked(getter and getter() and true or false)
    end
    function cb:SetLabel(text)
        self.label:SetText(text or "")
        self:SetHitRectInsets(0, -(self.label:GetStringWidth() + 4), 0, 0)
    end
    cb:SetScript("OnClick", function(self)
        if setter then setter(self:GetChecked() and true or false) end
    end)
    cb:SetScript("OnEnable", enableChanged)
    cb:SetScript("OnDisable", enableChanged)
    cb:HookScript("OnEnter", function(self) self.hovered = true; paint(self) end)
    cb:HookScript("OnLeave", function(self) self.hovered = false; paint(self) end)
    paint(cb)
    cb:HookScript("OnEnter", function(self)
        if self.tooltipText then
            UI:SetTextTooltip(self, { self.label:GetText() or "", self.tooltipText })
        end
    end)
    cb:HookScript("OnLeave", function() GameTooltip:Hide() end)
    cb:Refresh()
    return cb
end

local searchBoxCount = 0
local SEARCH_ICON = "Interface\\Common\\UI-Searchbox-Icon"
local CLEAR_ICON = "Interface\\FriendsFrame\\ClearBroadcastIcon"
-- A search field in the flat style: a magnifier, a grey hint while empty (placeholder, default "Search"), and a clear
-- button while there is text. onChanged(text) runs 0.2s after typing stops. eb.Instructions is the hint (as on
-- Blizzard's SearchBoxTemplate).
function UI:CreateSearchBox(parent, width, onChanged, placeholder)
    searchBoxCount = searchBoxCount + 1
    local key = "ui-search-" .. searchBoxCount
    local eb = UI:CreateSleekEditBox(parent, width or 200, 22, "GameFontHighlightSmall")
    eb:SetMaxLetters(60)
    eb:SetTextInsets(20, 20, 0, 0)
    local icon = eb:CreateTexture(nil, "OVERLAY")
    icon:SetSize(12, 12)
    icon:SetPoint("LEFT", 5, -1)
    icon:SetTexture(SEARCH_ICON)
    icon:SetVertexColor(0.7, 0.7, 0.7)
    local clear = CreateFrame("Button", nil, eb)
    clear:SetSize(14, 14)
    clear:SetPoint("RIGHT", -4, 0)
    clear.tex = clear:CreateTexture(nil, "ARTWORK")
    clear.tex:SetAllPoints()
    clear.tex:SetTexture(CLEAR_ICON)
    clear.tex:SetAlpha(0.6)
    clear:SetScript("OnEnter", function(self) self.tex:SetAlpha(1) end)
    clear:SetScript("OnLeave", function(self) self.tex:SetAlpha(0.6) end)
    clear:SetScript("OnClick", function()
        eb:SetText("")
        eb:ClearFocus()
    end)
    clear:Hide()
    eb.clearButton = clear
    eb:HookScript("OnTextChanged", function(self)
        clear:SetShown((self:GetText() or "") ~= "")
        if not onChanged then return end
        Debounce(key, 0.2, function() onChanged(self:GetText() or "") end)
    end)
    UI:SetEditPlaceholder(eb, placeholder or "Search")
    eb.cdlHint:ClearAllPoints()
    eb.cdlHint:SetPoint("LEFT", eb, "LEFT", 20, 0)
    eb.cdlHint:SetPoint("RIGHT", eb, "RIGHT", -20, 0)
    eb.Instructions = eb.cdlHint
    eb.cdlSearch = true
    return eb
end

---------------------------------------------------------------------------
-- Dropdowns & menus: flat buttons that open a MenuUtil context menu
---------------------------------------------------------------------------

local NIL_VALUE = {}   -- stands in for option values that are nil (radio data can't be nil)

local function FindOption(options, value)
    for _, opt in ipairs(options) do
        if opt.value == value then return opt end
    end
    return nil
end

-- A dropdown in the flat style (every dropdown of the addon): the button shows the selected option, its menu picks
-- one. getOptions() -> { { value =, text =, tooltip =, disabled = } | { isTitle = true, text = } }; nil values work.
function UI:CreateDropdown(parent, width, getOptions, getSelected, onSelect)
    return UI:CreateSleekDropdown(parent, width, getOptions, getSelected, onSelect)
end

function UI:CreateSleekDropdown(parent, width, getOptions, getSelected, onSelect)
    local b
    local function IsSelected(data)
        if data == NIL_VALUE then data = nil end
        return getSelected() == data
    end
    b = UI:CreateSleekMenuButton(parent, "-", width or 150, function(root)
        for _, opt in ipairs(getOptions() or {}) do
            if opt.isTitle then
                root:CreateTitle(opt.text or "")
            else
                local value = opt.value
                if value == nil then value = NIL_VALUE end
                local radio = root:CreateRadio(opt.text or tostring(opt.value), IsSelected, function(v)
                    if v == NIL_VALUE then v = nil end
                    onSelect(v)
                    b:Refresh()
                    return MenuResponse and MenuResponse.Close or nil
                end, value)
                if opt.disabled and radio and radio.SetEnabled then radio:SetEnabled(false) end
                if opt.tooltip and radio and radio.SetTooltip then
                    radio:SetTooltip(function(tooltip)
                        tooltip:AddLine(opt.text or "", 1, 0.82, 0)
                        tooltip:AddLine(opt.tooltip, 1, 1, 1, true)
                    end)
                end
            end
        end
    end)
    b.defaultText = "-"
    function b:SetDefaultText(t)
        self.defaultText = t or "-"
        self:Refresh()
    end
    function b:Refresh()
        local opt = FindOption(getOptions() or {}, getSelected())
        self:SetText(opt and opt.text or self.defaultText)
    end
    b:Refresh()
    return b
end

function UI:ContextMenu(owner, build)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        if ns.Debug then ns:Debug("MenuUtil unavailable; context menu skipped") end
        return nil
    end
    return MenuUtil.CreateContextMenu(owner, function(_, root) build(root) end)
end

-- DisasterZone extension: a dropdown-looking button whose menu holds actions (build(root) as in ContextMenu), in the
-- flat style. The menu is built when it opens, so it always reflects the current state.
function UI:CreateMenuButton(parent, text, width, build)
    return UI:CreateSleekMenuButton(parent, text, width, build)
end

---------------------------------------------------------------------------
-- Searchable dropdown (DisasterZone extension, ADDENDUM E §30)
-- A flat search field with a list panel below it (ScrollBox, at most ~10 visible rows).
-- Typing filters (case-insensitive substring), Up/Down (or Tab) move the highlight, Enter toggles the
-- highlighted (top) match, Escape closes. A click outside (GLOBAL_MOUSE_DOWN, as GudaBags does on this
-- client) also closes it. Each row: checkbox, class icon, class-coloured name, grey note on the right.
--
-- opts = {
--   getItems    = function() -> array of entries (required). An entry is
--                 { key=, text= (plain name; searched), classFile=, note= (grey, right side),
--                   dim= (offline look), fixed= (text; shown checked, cannot be toggled), search= (extra
--                   searchable text), role= ("tank" | "healer" | anything else = damage: a role icon at the row's
--                   end; roleFaint= true draws it faint) } or a section header { header = "text" }, or an action
--                   row { key= (unique), text=, note= (right side), action = function(entry), tip= (tooltip text) }:
--                   a gold "+" instead of the box, listed only while nothing is typed, run by a click.
--   footerText  = function() -> the footer's right text (optional; default "n matches")
--   isChecked   = function(key, entry) -> bool
--   onToggle    = function(key, entry)      (the rows are repainted afterwards)
--   onTooltip   = function(tooltip, entry)  (optional extra tooltip lines)
--   placeholder = "Search...", emptyText = "No matches.", maxRows = 10, rowHeight = 20,
--   panelWidth  = width of the list panel (default: the widget width),
--   toggle      = { label =, get = function() -> bool, set = function(bool) }  (optional footer checkbox)
-- }
-- Returns { frame, editBox, panel, list, Open, Close, Toggle, IsOpen, Refresh, RefreshRows, GetShown,
--           GetMatches, GetActive, MoveActive, ToggleActive, ToggleEntry, SetEnabled, IsEnabled, SetText }.
---------------------------------------------------------------------------

local SD_PAD = 5
local SD_FOOTER_H = 22
local SD_CHECK_MARK = "Interface\\Buttons\\UI-CheckBox-Check"
local SD_SEARCH_ICON = "Interface\\Common\\UI-Searchbox-Icon"
local SD_CLEAR_ICON = "Interface\\FriendsFrame\\ClearBroadcastIcon"
local SD_EDGE = { 0.34, 0.34, 0.38, 0.9 }
local SD_EDGE_FOCUS = { 1, 0.82, 0, 0.75 }

local function SDTrim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function SDEventValid(event)
    if C_EventUtils and C_EventUtils.IsEventValid then
        return C_EventUtils.IsEventValid(event) and true or false
    end
    return true
end

function UI:CreateSearchDropdown(parent, width, opts)
    opts = type(opts) == "table" and opts or {}
    width = tonumber(width) or 220
    local rowHeight = tonumber(opts.rowHeight) or 20
    local maxRows = math.max(1, tonumber(opts.maxRows) or 10)
    local sd = { items = {}, shown = {}, matches = {}, active = 1, enabled = true }

    -- The field, in the flat style: search icon, edit box, placeholder, clear (x) and the list chevron.
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(width, 22)
    holder:EnableMouse(true)
    holder.bg = holder:CreateTexture(nil, "BACKGROUND")
    holder.bg:SetAllPoints()
    holder.bg:SetColorTexture(0.10, 0.10, 0.12, 0.92)
    UI:AddEdges(holder)
    UI:SetEdgeColor(holder, unpack(SD_EDGE))
    sd.frame = holder

    local icon = holder:CreateTexture(nil, "ARTWORK")
    icon:SetSize(12, 12)
    icon:SetPoint("LEFT", holder, "LEFT", 6, 0)
    icon:SetTexture(SD_SEARCH_ICON)
    icon:SetVertexColor(0.7, 0.7, 0.7)

    local arrow = CreateFrame("Button", nil, holder)
    arrow:SetPoint("TOPRIGHT", holder, "TOPRIGHT", -1, -1)
    arrow:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -1, 1)
    arrow:SetWidth(20)
    arrow.hl = arrow:CreateTexture(nil, "HIGHLIGHT")
    arrow.hl:SetAllPoints()
    arrow.hl:SetColorTexture(1, 1, 1, 0.08)
    arrow.icon = arrow:CreateTexture(nil, "ARTWORK")
    arrow.icon:SetSize(12, 12)
    arrow.icon:SetPoint("CENTER")
    arrow.icon:SetTexture(UI.ICON_ATLAS)
    arrow.icon:SetTexCoord(unpack(UI:IconCoords(14)))
    arrow.icon:SetVertexColor(1, 0.82, 0)
    arrow:SetScript("OnEnable", function(self) self.icon:SetVertexColor(1, 0.82, 0) end)
    arrow:SetScript("OnDisable", function(self) self.icon:SetVertexColor(0.4, 0.4, 0.4) end)
    sd.arrow = arrow

    local clear = CreateFrame("Button", nil, holder)
    clear:SetSize(16, 16)
    clear:SetPoint("RIGHT", arrow, "LEFT", -1, 0)
    clear.icon = clear:CreateTexture(nil, "ARTWORK")
    clear.icon:SetAllPoints()
    clear.icon:SetTexture(SD_CLEAR_ICON)
    clear.icon:SetAlpha(0.5)
    clear:SetScript("OnEnter", function(self) self.icon:SetAlpha(1) end)
    clear:SetScript("OnLeave", function(self) self.icon:SetAlpha(0.5) end)
    clear:Hide()
    sd.clearButton = clear

    local eb = CreateFrame("EditBox", nil, holder)
    eb:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    eb:SetPoint("RIGHT", clear, "LEFT", -2, 0)
    eb:SetHeight(20)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetTextInsets(0, 0, 0, 0)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(48)
    sd.editBox = eb

    local hint = eb:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("LEFT", eb, "LEFT", 0, 0)
    hint:SetPoint("RIGHT", eb, "RIGHT", 0, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(false)
    hint:SetText(opts.placeholder or "Search...")
    eb.Instructions = hint

    local panel = CreateFrame("Frame", nil, holder)
    panel.bg = panel:CreateTexture(nil, "BACKGROUND")
    panel.bg:SetAllPoints()
    panel.bg:SetColorTexture(0.06, 0.06, 0.07, 1)
    UI:AddEdges(panel)
    UI:SetEdgeColor(panel, 0.45, 0.45, 0.5, 1)
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:SetToplevel(true)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", 0, -2)
    panel:SetWidth(tonumber(opts.panelWidth) or width)
    panel:SetHeight(SD_PAD + rowHeight + 4 + SD_FOOTER_H + 6)
    panel:Hide()
    sd.panel = panel
    local PaintField -- the field's look (below)

    local function RowChecked(e)
        if e.fixed then return true end
        return (opts.isChecked and opts.isChecked(e.key, e)) and true or false
    end

    local function RowClick(row)
        local e = row.cdlEntry
        if not e or e.header then return end
        if e.action then
            sd:ToggleEntry(e)
            return
        end
        for i, m in ipairs(sd.matches) do
            if m == e then sd.active = i break end
        end
        sd:ToggleEntry(e)
        if sd.enabled and eb:IsVisible() then eb:SetFocus() end
    end

    local function RowEnter(row)
        local e = row.cdlEntry
        if not e or e.header then return end
        if e.action then
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:AddLine(e.text or "")
            if e.tip then GameTooltip:AddLine(e.tip, 1, 1, 1, true) end
            GameTooltip:Show()
            return
        end
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:AddLine(UI:ColoredName(e.key, e.classFile))
        if e.note and e.note ~= "" then GameTooltip:AddLine(e.note, 0.8, 0.8, 0.8) end
        if e.dim then GameTooltip:AddLine("Offline", 0.6, 0.6, 0.6) end
        if opts.onTooltip then opts.onTooltip(GameTooltip, e) end
        if e.fixed then
            GameTooltip:AddLine(e.fixed .. ": always on the council", 0.6, 0.6, 0.6, true)
        else
            GameTooltip:AddLine(RowChecked(e) and "Click to remove" or "Click to add", 0.5, 0.5, 0.5)
        end
        GameTooltip:Show()
    end

    local function SetupRow(row)
        row.cdlSD = true
        row:RegisterForClicks("LeftButtonUp")
        row.activeTex = row:CreateTexture(nil, "BACKGROUND")
        row.activeTex:SetAllPoints()
        row.activeTex:SetColorTexture(1, 0.82, 0, 0.14)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetTexture(Tex("rowHilight"))
        row.hl:SetBlendMode("ADD")
        row.hl:SetAlpha(0.45)
        -- a flat check box: a 1px frame (box) around a dark square (boxIn)
        row.box = row:CreateTexture(nil, "BORDER")
        row.box:SetSize(12, 12)
        row.box:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.box:SetColorTexture(0.45, 0.45, 0.5, 1)
        row.boxIn = row:CreateTexture(nil, "ARTWORK")
        row.boxIn:SetPoint("TOPLEFT", row.box, "TOPLEFT", 1, -1)
        row.boxIn:SetPoint("BOTTOMRIGHT", row.box, "BOTTOMRIGHT", -1, 1)
        row.boxIn:SetColorTexture(0.03, 0.03, 0.04, 1)
        row.check = row:CreateTexture(nil, "OVERLAY")
        row.check:SetSize(16, 16)
        row.check:SetPoint("CENTER", row.box, "CENTER", 0, 0)
        row.check:SetTexture(SD_CHECK_MARK)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(14, 14)
        row.icon:SetPoint("LEFT", row, "LEFT", 22, 0)
        row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.note:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.note:SetJustifyH("RIGHT")
        row.note:SetWordWrap(false)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row, "LEFT", 40, 0)
        row.name:SetPoint("RIGHT", row.note, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.header = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.header:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.header:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.header:SetJustifyH("LEFT")
        -- an action row's gold "+" (in the box's place) and a member's role icon at the row's end
        row.plus = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.plus:SetPoint("CENTER", row.box, "CENTER", 0, 0)
        row.plus:SetText("+")
        row.plus:Hide()
        row.role = row:CreateTexture(nil, "ARTWORK")
        row.role:SetSize(12, 12)
        row.role:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.role:SetTexture(UI.ROLE_TEX)
        row.role:Hide()
        row:SetScript("OnClick", RowClick)
        row:SetScript("OnEnter", RowEnter)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local function InitRow(row, e)
        if not row.cdlSD then SetupRow(row) end
        row.cdlEntry = e
        row.plus:Hide()
        row.role:Hide()
        -- (rows are reused: the name and the note go back to their usual places)
        row.note:ClearAllPoints()
        row.note:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", row, "LEFT", 40, 0)
        row.name:SetPoint("RIGHT", row.note, "LEFT", -6, 0)
        if e.header then
            row.header:SetText(e.header)
            row.header:Show()
            row.box:Hide()
            row.boxIn:Hide()
            row.check:Hide()
            row.icon:Hide()
            row.name:SetText("")
            row.note:SetText("")
            row.hl:SetAlpha(0)
            row.activeTex:Hide()
            return
        end
        row.header:Hide()
        row.hl:SetAlpha(0.45)
        if e.action then
            row.box:Hide()
            row.boxIn:Hide()
            row.check:Hide()
            row.icon:Hide()
            row.plus:Show()
            row.name:ClearAllPoints()
            row.name:SetPoint("LEFT", row, "LEFT", 22, 0)
            row.name:SetPoint("RIGHT", row.note, "LEFT", -6, 0)
            row.name:SetText("|cffffffff" .. (e.text or "") .. "|r")
            row.note:SetText("|cffbdbdbd" .. (e.note or "") .. "|r")
            row.activeTex:Hide()
            return
        end
        if e.role then
            row.role:SetTexCoord(UI:RoleCoords(e.role))
            row.role:SetAlpha((e.roleFaint or e.dim) and 0.45 or 1)
            row.role:Show()
            row.note:ClearAllPoints()
            row.note:SetPoint("RIGHT", row.role, "LEFT", -6, 0)
        end
        row.box:Show()
        row.boxIn:Show()
        row.check:SetShown(RowChecked(e))
        row.check:SetDesaturated(e.fixed and true or false)
        row.box:SetAlpha(e.fixed and 0.5 or 1)
        row.boxIn:SetAlpha(e.fixed and 0.5 or 1)
        UI:ClassIcon(row.icon, e.classFile)
        row.icon:SetAlpha(e.dim and 0.5 or 1)
        local text = e.text or ShortName(e.key)
        if e.dim then
            row.name:SetText("|cff808080" .. text .. "|r")
        else
            row.name:SetText("|c" .. ClassHex(e.classFile) .. text .. "|r")
        end
        row.note:SetText(e.fixed or e.note or "")
        row.activeTex:SetShown(e == sd.matches[sd.active])
    end

    local list = UI:CreateScrollList(panel, rowHeight, InitRow)
    list.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", SD_PAD, -SD_PAD)
    list.frame:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -SD_PAD, -SD_PAD)
    list.frame:SetHeight(rowHeight)
    sd.list = list

    local empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empty:SetPoint("TOPLEFT", panel, "TOPLEFT", SD_PAD + 4, -SD_PAD - 4)
    empty:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -SD_PAD, -SD_PAD - 4)
    empty:SetJustifyH("LEFT")
    empty:SetText(opts.emptyText or "No matches.")
    empty:Hide()
    sd.emptyText = empty

    local footer = CreateFrame("Frame", nil, panel)
    footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", SD_PAD, 5)
    footer:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -SD_PAD, 5)
    footer:SetHeight(SD_FOOTER_H)
    footer.line = footer:CreateTexture(nil, "BORDER")
    footer.line:SetPoint("TOPLEFT", footer, "TOPLEFT", 0, 2)
    footer.line:SetPoint("TOPRIGHT", footer, "TOPRIGHT", 0, 2)
    footer.line:SetHeight(1)
    footer.line:SetColorTexture(1, 1, 1, 0.08)
    footer.count = footer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer.count:SetPoint("RIGHT", footer, "RIGHT", -2, 0)
    footer.count:SetJustifyH("RIGHT")
    sd.footer = footer
    if type(opts.toggle) == "table" then
        local t = opts.toggle
        footer.check = UI:CreateCheckbox(footer, t.label or "", t.get, function(value)
            if t.set then t.set(value and true or false) end
            sd:Refresh(true)
            if sd.enabled and eb:IsVisible() then eb:SetFocus() end
        end)
        footer.check:SetPoint("LEFT", footer, "LEFT", -4, 0)
        sd.toggleCheck = footer.check
    end

    -- Sizes the panel to the shown rows (1..maxRows) and hides the scroll bar when everything fits.
    local function Layout()
        local n = #sd.shown
        local visible = math.max(1, math.min(maxRows, n))
        local listH = visible * rowHeight
        list.frame:SetHeight(listH)
        local scroll = n > maxRows
        list.bar:SetShown(scroll)
        list.box:ClearAllPoints()
        list.box:SetPoint("TOPLEFT", list.frame, "TOPLEFT", 0, 0)
        list.box:SetPoint("BOTTOMRIGHT", list.frame, "BOTTOMRIGHT", scroll and -20 or 0, 0)
        empty:SetShown(n == 0)
        local m = #sd.matches
        if opts.footerText then
            footer.count:SetText(opts.footerText() or "")
        else
            footer.count:SetText(n == 0 and "" or (m == 1 and "1 match" or (m .. " matches")))
        end
        panel:SetHeight(SD_PAD + listH + 4 + SD_FOOTER_H + 6)
    end

    -- Re-reads the items, applies the search text. keepActive: keep the highlighted row and scroll.
    function sd:Refresh(keepActive)
        local items = opts.getItems and opts.getItems() or {}
        self.items = type(items) == "table" and items or {}
        local q = SDTrim(eb:GetText() or ""):lower()
        local shown, matches, header = {}, {}, nil
        for _, e in ipairs(self.items) do
            if type(e) == "table" then
                if e.header then
                    header = e
                elseif e.action then
                    -- (shortcuts while nothing is typed; a click runs them, the keys leave them alone)
                    if q == "" then
                        if header then
                            shown[#shown + 1] = header
                            header = nil
                        end
                        shown[#shown + 1] = e
                    end
                elseif e.key ~= nil then
                    local hay = ((e.text or ShortName(e.key)) .. " " .. (e.search or "")):lower()
                    if q == "" or hay:find(q, 1, true) then
                        if header then
                            shown[#shown + 1] = header
                            header = nil
                        end
                        shown[#shown + 1] = e
                        if not e.fixed then matches[#matches + 1] = e end
                    end
                end
            end
        end
        self.shown, self.matches = shown, matches
        if not keepActive or self.active > #matches then self.active = 1 end
        if panel:IsShown() then
            Layout()
            list:SetData(shown, not keepActive)
        end
    end

    function sd:RefreshRows()
        if panel:IsShown() then list:Refresh() end
    end

    function sd:IsOpen()
        return panel:IsShown() and true or false
    end

    function sd:Open()
        if not self.enabled or not holder:IsVisible() then return false end
        if not panel:IsShown() then panel:Show() end
        self:Refresh()
        return true
    end

    function sd:Close()
        if not panel:IsShown() then return end
        panel:Hide()
        if not opts.keepText and (eb:GetText() or "") ~= "" then eb:SetText("") end
        -- The client does not drop EditBox focus on a click elsewhere: without this, W/A/S/D after a mouse-only
        -- pick would type into the search box (and reopen the list) instead of moving.
        eb:ClearFocus()
    end

    function sd:Toggle()
        if self:IsOpen() then
            self:Close()
        elseif self:Open() then
            eb:SetFocus()
        end
    end

    function sd:GetShown() return self.shown end
    function sd:GetMatches() return self.matches end
    function sd:GetActive() return self.matches[self.active] end

    -- Toggles one entry through opts.onToggle (fixed entries and headers are ignored).
    function sd:ToggleEntry(e)
        if type(e) ~= "table" or e.header or e.fixed or not self.enabled then return false end
        if e.action then
            e.action(e)
            if panel:IsShown() then self:Refresh(true) end
            return true
        end
        if opts.onToggle then opts.onToggle(e.key, e) end
        self:RefreshRows()
        return true
    end

    function sd:ToggleActive()
        return self:ToggleEntry(self.matches[self.active] or self.matches[1])
    end

    function sd:MoveActive(delta)
        local n = #self.matches
        if n == 0 then return end
        if not panel:IsShown() then self:Open() end
        self.active = ((self.active - 1 + (tonumber(delta) or 1)) % n) + 1
        self:RefreshRows()
        local target = self.matches[self.active]
        local box = list.box
        if target and box.FindElementDataIndexByPredicate and box.ScrollToElementDataIndex then
            local index = box:FindElementDataIndexByPredicate(function(d) return d == target end)
            if index then box:ScrollToElementDataIndex(index) end
        end
    end

    function sd:SetEnabled(on)
        on = on and true or false
        self.enabled = on
        if eb.SetEnabled then eb:SetEnabled(on) end
        arrow:SetEnabled(on)
        holder:SetAlpha(on and 1 or 0.5)
        if not on then
            self:Close()
            eb:ClearFocus()
        end
        PaintField()
    end

    function sd:IsEnabled()
        return self.enabled
    end

    function sd:SetText(text)
        eb:SetText(text or "")
        if panel:IsShown() then self:Refresh() end
    end

    -- The field's look: gold edges while typing or open, the placeholder and the clear button follow the text.
    PaintField = function()
        local hasText = (eb:GetText() or "") ~= ""
        hint:SetShown(not hasText)
        clear:SetShown(hasText and sd.enabled)
        UI:SetEdgeColor(holder, unpack((eb:HasFocus() or panel:IsShown()) and SD_EDGE_FOCUS or SD_EDGE))
    end

    -- Keyboard: typing filters, Enter toggles the highlighted match, Up/Down/Tab move, Escape closes.
    eb:HookScript("OnTextChanged", function(_, userInput)
        PaintField()
        if userInput and not panel:IsShown() then
            sd:Open()
        elseif panel:IsShown() then
            sd:Refresh()
        end
    end)
    eb:HookScript("OnEditFocusGained", function()
        if not panel:IsShown() then sd:Open() end
        PaintField()
    end)
    eb:HookScript("OnEditFocusLost", function()
        PaintField()
        C_Timer.After(0.2, function()
            if panel:IsShown() and not eb:HasFocus() and not panel:IsMouseOver() and not holder:IsMouseOver() then
                sd:Close()
            end
        end)
    end)
    eb:SetScript("OnEnterPressed", function(self)
        if not panel:IsShown() then
            sd:Open()
            return
        end
        if sd:ToggleActive() then self:HighlightText() end
    end)
    eb:SetScript("OnEscapePressed", function(self)
        sd:Close()
        self:ClearFocus()
    end)
    eb:SetScript("OnArrowPressed", function(_, key)
        if key == "UP" then
            sd:MoveActive(-1)
        elseif key == "DOWN" then
            sd:MoveActive(1)
        end
    end)
    eb:SetScript("OnTabPressed", function()
        sd:MoveActive(IsShiftKeyDown() and -1 or 1)
    end)

    arrow:SetScript("OnClick", function() sd:Toggle() end)
    clear:SetScript("OnClick", function()
        eb:SetText("")
        if sd.enabled then eb:SetFocus() end
    end)
    -- a click on the field's padding (around the edit box) types into it too
    holder:SetScript("OnMouseDown", function()
        if sd.enabled then eb:SetFocus() end
    end)

    -- A click anywhere outside the widget closes the list.
    panel:SetScript("OnShow", function(self)
        if SDEventValid("GLOBAL_MOUSE_DOWN") then self:RegisterEvent("GLOBAL_MOUSE_DOWN") end
        PaintField()
    end)
    panel:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        PaintField()
    end)
    panel:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" and not self:IsMouseOver() and not holder:IsMouseOver() then
            sd:Close()
        end
    end)
    holder:SetScript("OnHide", function() sd:Close() end)
    PaintField()

    return sd
end

---------------------------------------------------------------------------
-- The main window's navigation: a flat strip of text tabs on the left and icon tabs on the right (Games,
-- Settings), with a hairline under it. defs = { { key =, label =, icon = UI.ICON_ATLAS index, tip = { title,
-- text } } } in order; a def with icon becomes an icon tab. Pages can be selected without a tab (obj:Select(key)
-- works for any key). parent.Tabs lists the tab buttons (b.cdlKey).
---------------------------------------------------------------------------

local NAV_ICON = 16

local function CreateNavIcon(parent, def, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(NAV_ICON + 14, 26)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(NAV_ICON, NAV_ICON)
    b.icon:SetPoint("CENTER", 0, 1)
    b.icon:SetTexture(UI.ICON_ATLAS)
    b.icon:SetTexCoord(unpack(UI:IconCoords(def.icon)))
    b.line = b:CreateTexture(nil, "ARTWORK")
    b.line:SetPoint("BOTTOMLEFT", 4, 0)
    b.line:SetPoint("BOTTOMRIGHT", -4, 0)
    b.line:SetHeight(2)
    b.line:SetColorTexture(1, 0.82, 0, 0.9)
    local function paint(self)
        self.line:SetShown(self.active and true or false)
        if self.active then
            self.icon:SetVertexColor(1, 0.82, 0)
        elseif self.hovered then
            self.icon:SetVertexColor(1, 1, 1)
        else
            self.icon:SetVertexColor(0.62, 0.62, 0.62)
        end
    end
    function b:SetActive(on)
        self.active = on and true or false
        paint(self)
    end
    local tip = def.tip or { def.label }
    b:SetScript("OnEnter", function(self)
        self.hovered = true
        paint(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(tip[1] or def.label or "")
        if tip[2] then GameTooltip:AddLine(tip[2], 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        self.hovered = false
        paint(self)
        GameTooltip:Hide()
    end)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", onClick)
    paint(b)
    return b
end

function UI:CreateNavStrip(parent, defs, onSelect)
    local strip = CreateFrame("Frame", nil, parent)
    strip:SetHeight(28)
    local rule = strip:CreateTexture(nil, "BORDER")
    rule:SetPoint("BOTTOMLEFT")
    rule:SetPoint("BOTTOMRIGHT")
    rule:SetHeight(1)
    rule:SetColorTexture(1, 1, 1, 0.12)
    -- other widgets (the sync status) anchor their RIGHT to this: just left of the icon tabs
    local rightAnchor = CreateFrame("Frame", nil, strip)
    rightAnchor:SetSize(1, 1)

    local obj = { frame = strip, buttons = {}, byKey = {}, selected = nil, rightAnchor = rightAnchor }
    parent.Tabs = {}

    for i, def in ipairs(defs or {}) do
        local function click(self)
            if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
            obj:Select(self.cdlKey)
        end
        local tab
        if def.icon then
            tab = CreateNavIcon(strip, def, click)
            tab.cdlIcon = true
        else
            tab = UI:CreateUnderlineTab(strip, def.label or def.key, click, "nav")
        end
        tab.cdlKey = def.key
        tab.cdlShown = true
        obj.buttons[i] = tab
        obj.byKey[def.key] = tab
        parent.Tabs[i] = tab
    end

    function obj:Layout()
        local prevLeft, prevRight
        for _, tab in ipairs(self.buttons) do
            tab:ClearAllPoints()
            if tab.cdlShown and not tab.cdlIcon then
                if prevLeft then
                    tab:SetPoint("BOTTOMLEFT", prevLeft, "BOTTOMRIGHT", 2, 0)
                else
                    tab:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 2, 0)
                end
                prevLeft = tab
            end
        end
        for i = #self.buttons, 1, -1 do
            local tab = self.buttons[i]
            if tab.cdlShown and tab.cdlIcon then
                if prevRight then
                    tab:SetPoint("BOTTOMRIGHT", prevRight, "BOTTOMLEFT", -2, 0)
                else
                    tab:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -2, 0)
                end
                prevRight = tab
            end
        end
        for _, tab in ipairs(self.buttons) do tab:SetShown(tab.cdlShown and true or false) end
        rightAnchor:ClearAllPoints()
        if prevRight then
            rightAnchor:SetPoint("RIGHT", prevRight, "LEFT", -8, 0)
        else
            rightAnchor:SetPoint("RIGHT", self.frame, "RIGHT", -8, 0)
        end
    end

    function obj:Select(key)
        self.selected = key
        for k, tab in pairs(self.byKey) do tab:SetActive(k == key) end
        if onSelect then onSelect(key) end
    end

    function obj:SetTabShown(key, shown)
        local tab = self.byKey[key]
        if not tab then return end
        shown = shown and true or false
        if tab.cdlShown ~= shown then
            tab.cdlShown = shown
            self:Layout()
        end
    end

    function obj:IsTabShown(key)
        local tab = self.byKey[key]
        return tab and tab.cdlShown or false
    end

    function obj:GetSelected()
        return self.selected
    end

    obj:Layout()
    return obj
end

---------------------------------------------------------------------------
-- Chat announce
---------------------------------------------------------------------------

local MAX_CHAT = 255

-- Splits text into <=255-byte chunks without breaking item links.
local function SplitChunks(text)
    local links = {}
    local function keep(l)
        links[#links + 1] = l
        return "\001" .. #links .. "\001"
    end
    local masked = text:gsub("|c[^|]*|H.-|h.-|h|r", keep)
    masked = masked:gsub("|H.-|h.-|h", keep)

    local chunks, cur = {}, ""
    for word in masked:gmatch("%S+") do
        word = word:gsub("\001(%d+)\001", function(i) return links[tonumber(i)] or "" end)
        if cur == "" then
            cur = word
        elseif #cur + 1 + #word <= MAX_CHAT then
            cur = cur .. " " .. word
        else
            chunks[#chunks + 1] = cur
            cur = word
        end
        while #cur > MAX_CHAT do
            chunks[#chunks + 1] = cur:sub(1, MAX_CHAT)
            cur = cur:sub(MAX_CHAT + 1)
        end
    end
    if cur ~= "" then chunks[#chunks + 1] = cur end
    return chunks
end

function UI:AnnounceLine(text)
    if type(text) ~= "string" or text == "" then return false end
    local channel = ns.db and ns.db.settings and ns.db.settings.announceChannel or "RAID"
    if IsInRaid() then
        if channel == "RAID_WARNING" and not (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then
            channel = "RAID"
        elseif channel ~= "RAID_WARNING" then
            channel = "RAID"
        end
    elseif IsInGroup() then
        channel = "PARTY"
    else
        ns:Print(text)
        return false
    end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if not send then return false end
    for _, chunk in ipairs(SplitChunks(text)) do
        send(chunk, channel)
    end
    return true
end

---------------------------------------------------------------------------
-- Multi-select dropdown (DisasterZone extension, ADDENDUM F §35): a flat dropdown whose menu holds
-- checkboxes (MenuUtil CreateCheckbox: the menu stays open while toggling). The button shows summary().
--   getOptions() -> array of { value =, text =, tooltip = } | { isTitle = true, text = } | { isDivider = true }
--                   | { isButton = true, text =, onClick = fn } (a button closes the menu)
--   isChecked(value) -> bool;  onToggle(value, newChecked);  summary() -> button text (optional)
---------------------------------------------------------------------------

function UI:CreateMultiDropdown(parent, width, getOptions, isChecked, onToggle, summary)
    local b
    local function IsSelected(value) return isChecked(value) and true or false end
    local function Toggle(value)
        onToggle(value, not IsSelected(value))
        if b then b:Refresh() end   -- the summary follows every tick (the menu stays open)
    end
    local function Build(root)
        for _, opt in ipairs(getOptions() or {}) do
            if opt.isTitle then
                root:CreateTitle(opt.text or "")
            elseif opt.isDivider then
                if root.CreateDivider then root:CreateDivider() end
            elseif opt.isButton then
                local btn = root:CreateButton(opt.text or "", function() if opt.onClick then opt.onClick() end end)
                if opt.disabled and btn and btn.SetEnabled then btn:SetEnabled(false) end
            else
                local cb = root:CreateCheckbox(opt.text or tostring(opt.value), IsSelected, Toggle, opt.value)
                if opt.disabled and cb and cb.SetEnabled then cb:SetEnabled(false) end
                if opt.tooltip and cb and cb.SetTooltip then
                    cb:SetTooltip(function(tooltip)
                        tooltip:AddLine(opt.text or "", 1, 0.82, 0)
                        tooltip:AddLine(opt.tooltip, 1, 1, 1, true)
                    end)
                end
            end
        end
    end
    b = UI:CreateSleekMenuButton(parent, "", width or 150, Build)
    b.multi = true
    function b:Refresh() self:SetText(summary and summary() or "-") end
    b:Refresh()
    return b
end

---------------------------------------------------------------------------
-- Raid BiS lock and "changed during lock" markers (DisasterZone extension, ADDENDUM F §38). Every call into
-- GroupRules / BiS / Store is guarded: an older core simply has no lock.
---------------------------------------------------------------------------

UI.ICON_WARN = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"   -- the game fonts have no U+26A0 glyph
UI.ICON_LOCK = "Interface\\PetBattles\\PetBattle-LockIcon"

function UI:IconText(path, size)
    size = tonumber(size) or 0
    return "|T" .. tostring(path) .. ":" .. size .. ":" .. size .. "|t"
end

function UI:WarnIcon(size) return self:IconText(UI.ICON_WARN, size or 12) end
function UI:LockIcon(size) return self:IconText(UI.ICON_LOCK, size or 12) end

local function LockInfoCopy(info)
    if type(info) ~= "table" then return nil end
    return { by = type(info.by) == "string" and info.by or nil, at = tonumber(info.at) }
end

-- The group's BiS lock (GroupRules): locked, { by = key, at = serverTime } | nil.
function UI:GetBiSLock()
    local GR = ns.GroupRules
    if type(GR) ~= "table" or type(GR.IsLocked) ~= "function" then return false, nil end
    if not GR:IsLocked() then return false, nil end
    local info = type(GR.GetLockInfo) == "function" and GR:GetLockInfo() or nil
    return true, LockInfoCopy(info)
end

-- My own list is locked (BiS:IsLocked): the editing APIs refuse. locked, { by, at } | nil.
function UI:IsMyListLocked()
    local B = ns.BiS
    if type(B) ~= "table" or type(B.IsLocked) ~= "function" then return false, nil end
    local locked, info = B:IsLocked()
    if not locked then return false, nil end
    info = LockInfoCopy(info)
    if not info then
        local _, grInfo = self:GetBiSLock()
        info = grInfo
    end
    return true, info
end

-- I may lock / unlock: the raid's loot authority (raid leader first) with a core that has the lock. The lock
-- only exists in raids; 1.3: only while the raid runs with the loot council (GroupRules:CanLock; a held lock can
-- always be undone).
function UI:CanSetBiSLock()
    local GR = ns.GroupRules
    if type(GR) ~= "table" or type(GR.SetLocked) ~= "function" then return false end
    if not (IsInRaid and IsInRaid()) then return false end
    if type(GR.CanLock) == "function" then return (GR:CanLock()) and true or false end
    return (type(GR.IsAuthority) == "function" and GR:IsAuthority()) and true or false
end

function UI:SetBiSLock(locked)
    local GR = ns.GroupRules
    if type(GR) ~= "table" or type(GR.SetLocked) ~= "function" then
        ns:Print("This DisasterZone core can't lock BiS lists.")
        return false
    end
    local ok, err = GR:SetLocked(locked and true or false)
    if not ok and err then ns:Print("%s", tostring(err)) end
    return ok and true or false
end

-- "Lee" / "you" / "Lee (since 20:14)" for a lock info table (nil-safe).
function UI:LockByText(info, withTime)
    local key = type(info) == "table" and type(info.by) == "string" and info.by or nil
    local by = key and ShortName(key) or "the raid leader"
    if key and ns.Util and ns.Util.IsMe and ns.Util.IsMe(key) then by = "you" end
    local at = type(info) == "table" and tonumber(info.at)
    if withTime and at and at > 1000000000 and date then
        return by .. " (since " .. date("%H:%M", at) .. ")"
    end
    return by
end

-- "changed during lock" flag of a player (Store:GetLockFlag): serverTime or nil.
function UI:LockChangedAt(key)
    local S = ns.Store
    if type(key) ~= "string" or type(S) ~= "table" or type(S.GetLockFlag) ~= "function" then return nil end
    return tonumber((S:GetLockFlag(key)))
end

-- Tooltip line for a flagged player (ts = when the changed list arrived).
function UI:AddLockChangedLine(tt, ts, extra)
    if not tt then return end
    local when = ""
    if tonumber(ts) and ns.Util and ns.Util.FormatAgo then when = " (" .. ns.Util.FormatAgo(tonumber(ts)) .. ")" end
    tt:AddLine(self:WarnIcon(12) .. " Changed their BiS list while lists were locked" .. when, 1, 0.55, 0.2, true)
    if extra then tt:AddLine(extra, 0.8, 0.8, 0.8, true) end
end

-- "Lock BiS lists" / "Unlock BiS lists" button for the group's loot authority. opts.short: "Lock lists" /
-- "Unlock lists". :Refresh() updates the label and hides the button for everyone else (opts.keepShown:
-- shown but disabled instead).
function UI:CreateBiSLockButton(parent, width, height, opts)
    opts = opts or {}
    local b = UI:CreateButton(parent, "", width or 120, height or 22, function()
        local locked = UI:GetBiSLock()
        UI:SetBiSLock(not locked)
    end)
    if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
    function b:Refresh()
        local locked = UI:GetBiSLock()
        local word = opts.short and " lists" or " BiS lists"
        self:SetText((locked and "Unlock" or "Lock") .. word)
        local can = UI:CanSetBiSLock()
        self:SetShown(can or opts.keepShown and true or false)
        self:SetEnabled(can)
    end
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local locked, info = UI:GetBiSLock()
        if locked then
            GameTooltip:AddLine("Unlock BiS lists", 1, 0.82, 0)
            GameTooltip:AddLine("Locked by " .. UI:LockByText(info, true) .. ". Unlocking lets everyone in "
                .. "the group edit their BiS list again.", 1, 1, 1, true)
        else
            GameTooltip:AddLine("Lock BiS lists", 1, 0.82, 0)
            GameTooltip:AddLine("Stops everyone in the raid from editing their BiS list until you unlock it "
                .. "or the raid ends. Obtained items still update. Council members see who changes "
                .. "their list anyway.", 1, 1, 1, true)
        end
        if not UI:CanSetBiSLock() then
            -- why not (GroupRules:CanLock: not the raid's loot authority, no started raid, no loot council)
            local GR, why = ns.GroupRules, nil
            if type(GR) == "table" and type(GR.CanLock) == "function" then
                local _, reason = GR:CanLock()
                why = reason
            end
            why = type(why) == "string" and why ~= "" and (why:sub(1, 1):upper() .. why:sub(2))
                or "Only the raid leader can lock or unlock the lists."
            GameTooltip:AddLine(why, 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:Refresh()
    return b
end

---------------------------------------------------------------------------
-- BiS model: a unit's character model wearing BiS picks (My BiS centre, Council member view)
---------------------------------------------------------------------------

-- Full-body camera that fits the frame (a model keeps a stale, zoomed-in camera after SetUnit / TryOn
-- otherwise and draws outside its box).
local function FitModelCamera(m)
    pcall(m.SetPortraitZoom, m, 0)
    pcall(m.SetCamDistanceScale, m, 1)
    pcall(m.SetPosition, m, 0, 0, 0)
    pcall(m.SetFacing, m, m.facing or 0)
end

local function IsWearable(itemID)
    if C_Item and C_Item.IsEquippableItem then return C_Item.IsEquippableItem(itemID) and true or false end
    return IsEquippableItem and IsEquippableItem(itemID) and true or false
end

-- m:DressBiS(unit, pickFn): shows `unit` in its current gear, then tries on pickFn(sid) (an itemID or nil)
-- for every slot. Slots without a wearable pick (empty, disabled, tier tokens) keep the equipped item.
-- Drag to rotate. Returns false when the unit can't be shown (not visible to the client).
function UI:CreateBiSModel(parent)
    local ok, m = pcall(CreateFrame, "DressUpModel", nil, parent)
    if not ok or not m then m = CreateFrame("PlayerModel", nil, parent) end
    m.facing = 0
    pcall(m.SetScript, m, "OnModelLoaded", FitModelCamera)
    m:EnableMouse(true)
    m:SetScript("OnMouseDown", function(self) self.dragX = GetCursorPosition() end)
    m:SetScript("OnMouseUp", function(self) self.dragX = nil end)
    m:SetScript("OnUpdate", function(self)
        if not self.dragX then return end
        local x = GetCursorPosition()
        self.facing = (self.facing or 0) + (x - self.dragX) * 0.02
        self.dragX = x
        pcall(self.SetFacing, self, self.facing)
    end)
    function m:DressBiS(unit, pickFn)
        if not (unit and UnitExists(unit) and (unit == "player" or UnitIsVisible(unit))) then
            pcall(self.ClearModel, self)
            return false
        end
        pcall(self.SetUnit, self, unit)
        FitModelCamera(self)
        if not self.TryOn then return true end
        for sid = 1, #(ns.SLOTS or {}) do
            local slot = ns.SLOTS[sid]
            local itemID = pickFn(sid)
            if itemID and slot and IsWearable(itemID) then
                pcall(self.TryOn, self, "item:" .. itemID, slot.slotName)
            end
        end
        return true
    end
    return m
end
